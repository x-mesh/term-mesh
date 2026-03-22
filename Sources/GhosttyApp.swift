import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import Darwin
import Sentry
import Bonsplit
import IOSurface
import os

enum TerminalOpenURLTarget: Equatable {
    case embeddedBrowser(URL)
    case external(URL)

    var url: URL {
        switch self {
        case let .embeddedBrowser(url), let .external(url):
            return url
        }
    }
}

enum GhosttyDefaultBackgroundUpdateScope: Int {
    case unscoped = 0
    case app = 1
    case surface = 2

    var logLabel: String {
        switch self {
        case .unscoped: return "unscoped"
        case .app: return "app"
        case .surface: return "surface"
        }
    }
}

/// Coalesces Ghostty background notifications so consumers only observe
/// the latest runtime background for a burst of updates.
final class GhosttyDefaultBackgroundNotificationDispatcher {
    private let coalescer: NotificationBurstCoalescer
    private let postNotification: ([AnyHashable: Any]) -> Void
    private var pendingUserInfo: [AnyHashable: Any]?
    private var pendingEventId: UInt64 = 0
    private var pendingSource: String = "unspecified"
    private let logEvent: ((String) -> Void)?

    init(
        delay: TimeInterval = 1.0 / 30.0,
        logEvent: ((String) -> Void)? = nil,
        postNotification: @escaping ([AnyHashable: Any]) -> Void = { userInfo in
            NotificationCenter.default.post(
                name: .ghosttyDefaultBackgroundDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
    ) {
        coalescer = NotificationBurstCoalescer(delay: delay)
        self.logEvent = logEvent
        self.postNotification = postNotification
    }

    func signal(backgroundColor: NSColor, opacity: Double, eventId: UInt64, source: String) {
        let signalOnMain = { [self] in
            pendingEventId = eventId
            pendingSource = source
            pendingUserInfo = [
                GhosttyNotificationKey.backgroundColor: backgroundColor,
                GhosttyNotificationKey.backgroundOpacity: opacity,
                GhosttyNotificationKey.backgroundEventId: NSNumber(value: eventId),
                GhosttyNotificationKey.backgroundSource: source
            ]
            logEvent?(
                "bg notify queued id=\(eventId) source=\(source) color=\(backgroundColor.hexString()) opacity=\(String(format: "%.3f", opacity))"
            )
            coalescer.signal { [self] in
                guard let userInfo = pendingUserInfo else { return }
                let eventId = pendingEventId
                let source = pendingSource
                pendingUserInfo = nil
                logEvent?("bg notify flushed id=\(eventId) source=\(source)")
                logEvent?("bg notify posting id=\(eventId) source=\(source)")
                postNotification(userInfo)
                logEvent?("bg notify posted id=\(eventId) source=\(source)")
            }
        }

        if Thread.isMainThread {
            signalOnMain()
        } else {
            DispatchQueue.main.async(execute: signalOnMain)
        }
    }
}

func resolveTerminalOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if NSString(string: trimmed).isAbsolutePath {
        return .external(URL(fileURLWithPath: trimmed))
    }

    if let parsed = URL(string: trimmed),
       let scheme = parsed.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            guard BrowserInsecureHTTPSettings.normalizeHost(parsed.host ?? "") != nil else {
                return .external(parsed)
            }
            return .embeddedBrowser(parsed)
        }
        return .external(parsed)
    }

    if let webURL = resolveBrowserNavigableURL(trimmed) {
        guard BrowserInsecureHTTPSettings.normalizeHost(webURL.host ?? "") != nil else {
            return .external(webURL)
        }
        return .embeddedBrowser(webURL)
    }

    guard let fallback = URL(string: trimmed) else { return nil }
    return .external(fallback)
}

final class GhosttySurfaceCallbackContext {
    weak var surfaceView: GhosttyNSView?
    weak var terminalSurface: TerminalSurface?
    let surfaceId: UUID

    init(surfaceView: GhosttyNSView, terminalSurface: TerminalSurface) {
        self.surfaceView = surfaceView
        self.terminalSurface = terminalSurface
        self.surfaceId = terminalSurface.id
    }

    var tabId: UUID? {
        terminalSurface?.tabId ?? surfaceView?.tabId
    }

    var runtimeSurface: ghostty_surface_t? {
        terminalSurface?.surface ?? surfaceView?.terminalSurface?.surface
    }
}

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    static let shared = GhosttyApp()
    private static let backgroundLogTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Injected notification service (defaults to singleton for backward compatibility).
    var notifications: any NotificationService = TerminalNotificationStore.shared

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    private static func resolveBackgroundLogURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicitPath = environment["TERMMESH_DEBUG_BG_LOG"] ?? environment["CMUX_DEBUG_BG_LOG"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        if let debugLogPath = environment["TERMMESH_DEBUG_LOG"] ?? environment["CMUX_DEBUG_LOG"],
           !debugLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let baseURL = URL(fileURLWithPath: debugLogPath)
            let extensionSeparatorIndex = baseURL.lastPathComponent.lastIndex(of: ".")
            let stem = extensionSeparatorIndex.map { String(baseURL.lastPathComponent[..<$0]) } ?? baseURL.lastPathComponent
            let bgName = "\(stem)-bg.log"
            return baseURL.deletingLastPathComponent().appendingPathComponent(bgName)
        }

        return URL(fileURLWithPath: "/tmp/term-mesh-bg.log")
    }

    let backgroundLogEnabled = {
        if termMeshEnv("DEBUG_BG") == "1" {
            return true
        }
        if termMeshEnv("DEBUG_LOG") != nil {
            return true
        }
        if ProcessInfo.processInfo.environment["GHOSTTYTABS_DEBUG_BG"] == "1" {
            return true
        }
        if UserDefaults.standard.bool(forKey: "termMeshDebugBG") {
            return true
        }
        return UserDefaults.standard.bool(forKey: "GhosttyTabsDebugBG")
    }()
    private let backgroundLogURL = GhosttyApp.resolveBackgroundLogURL()
    private let backgroundLogStartUptime = ProcessInfo.processInfo.systemUptime
    private let backgroundLogLock = NSLock()
    private var backgroundLogSequence: UInt64 = 0
    private var appObservers: [NSObjectProtocol] = []
    private var backgroundEventCounter: UInt64 = 0
    private var defaultBackgroundUpdateScope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    private var defaultBackgroundScopeSource: String = "initialize"
    private lazy var defaultBackgroundNotificationDispatcher: GhosttyDefaultBackgroundNotificationDispatcher =
        // Theme chrome should track terminal theme changes in the same frame.
        // Keep coalescing semantics, but flush in the next main turn instead of waiting ~1 frame.
        GhosttyDefaultBackgroundNotificationDispatcher(delay: 0, logEvent: { [weak self] message in
            guard let self, self.backgroundLogEnabled else { return }
            self.logBackground(message)
        })

    // Scroll lag tracking
    private(set) var isScrolling = false
    private var scrollLagSampleCount = 0
    private var scrollLagTotalMs: Double = 0
    private var scrollLagMaxMs: Double = 0
    private let scrollLagThresholdMs: Double = 25  // Alert if tick takes >25ms during scroll
    private var scrollEndTimer: DispatchWorkItem?

    func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        // Cancel any pending scroll-end timer
        scrollEndTimer?.cancel()
        scrollEndTimer = nil

        if momentumEnded {
            // Trackpad momentum ended - scrolling is done
            endScrollSession()
        } else if hasMomentum {
            // Trackpad scrolling with momentum - wait for momentum to end
            isScrolling = true
        } else {
            // Mouse wheel or non-momentum scroll - use timeout
            isScrolling = true
            let timer = DispatchWorkItem { [weak self] in
                self?.endScrollSession()
            }
            scrollEndTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: timer)
        }
    }

    private func endScrollSession() {
        guard isScrolling else { return }
        isScrolling = false

        // Report accumulated lag stats if any exceeded threshold
        if scrollLagSampleCount > 0 {
            let avgLag = scrollLagTotalMs / Double(scrollLagSampleCount)
            let maxLag = scrollLagMaxMs
            let samples = scrollLagSampleCount
            let threshold = scrollLagThresholdMs
            if maxLag > threshold {
                SentrySDK.capture(message: "Scroll lag detected") { scope in
                    scope.setLevel(.warning)
                    scope.setContext(value: [
                        "samples": samples,
                        "avg_ms": String(format: "%.2f", avgLag),
                        "max_ms": String(format: "%.2f", maxLag),
                        "threshold_ms": threshold
                    ], key: "scroll_lag")
                }
            }
            // Reset stats
            scrollLagSampleCount = 0
            scrollLagTotalMs = 0
            scrollLagMaxMs = 0
        }
    }

    private init() {
        initializeGhostty()
    }

    #if DEBUG
    private static let initLogPath = "/tmp/term-mesh-ghostty-init.log"

    private static func initLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: initLogPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: initLogPath, contents: line.data(using: .utf8))
        }
    }

    private static func dumpConfigDiagnostics(_ config: ghostty_config_t, label: String) {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else {
            initLog("ghostty diagnostics (\(label)): none")
            return
        }
        initLog("ghostty diagnostics (\(label)): count=\(count)")
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(config, UInt32(i))
            let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
            initLog("  [\(i)] \(msg)")
        }
    }
    #endif

    private func initializeGhostty() {
        // Ensure TUI apps can use colors even if NO_COLOR is set in the launcher env.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }
        // Clear CLAUDECODE so terminals spawned by term-mesh don't inherit it
        // from a parent Claude Code session (Claude Code refuses to start
        // inside another CLAUDECODE session).
        if getenv("CLAUDECODE") != nil {
            unsetenv("CLAUDECODE")
        }

        // Initialize Ghostty library first
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != GHOSTTY_SUCCESS {
            Logger.ui.error("Failed to initialize ghostty: \(result, privacy: .public)")
            return
        }

        // Load config
        guard let primaryConfig = ghostty_config_new() else {
            Logger.ui.error("Failed to create ghostty config")
            return
        }

        // Load default config (includes user config). If this fails hard (e.g. due to
        // invalid user config), ghostty_app_new may return nil; we fall back below.
        loadDefaultConfigFilesWithLegacyFallback(primaryConfig)
        updateDefaultBackground(from: primaryConfig, source: "initialize.primaryConfig")

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
        }
        runtimeConfig.action_cb = { app, target, action in
            return GhosttyApp.shared.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            // Read clipboard
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata),
                  let surface = callbackContext.runtimeSurface else { return }

            let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location)
            let value = pasteboard.flatMap { GhosttyPasteboardHelper.stringContents(from: $0) } ?? ""

            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content else { return }
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata),
                  let surface = callbackContext.runtimeSurface else { return }

            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }
        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            // Write clipboard
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))

            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)

                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyPasteboardHelper.writeString(value, to: location)
                        return
                    }
                }

                if fallback == nil {
                    fallback = value
                }
            }

            if let fallback {
                GhosttyPasteboardHelper.writeString(fallback, to: location)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, needsConfirmClose in
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata) else { return }
            let callbackSurfaceId = callbackContext.surfaceId
            let callbackTabId = callbackContext.tabId

#if DEBUG
            termMeshWriteChildExitProbe(
                [
                    "probeCloseSurfaceNeedsConfirm": needsConfirmClose ? "1" : "0",
                    "probeCloseSurfaceTabId": callbackTabId?.uuidString ?? "",
                    "probeCloseSurfaceSurfaceId": callbackSurfaceId.uuidString,
                ],
                increments: ["probeCloseSurfaceCbCount": 1]
            )
#endif

            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                // Close requests must be resolved by the callback's workspace/surface IDs only.
                // If the mapping is already gone (duplicate/stale callback), ignore it.
                if let callbackTabId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    if needsConfirmClose {
                        manager.closeRuntimeSurfaceWithConfirmation(
                            tabId: callbackTabId,
                            surfaceId: callbackSurfaceId
                        )
                    } else {
                        manager.closeRuntimeSurface(
                            tabId: callbackTabId,
                            surfaceId: callbackSurfaceId
                        )
                    }
                }
            }
        }

        // Create app
        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = created
            self.config = primaryConfig
        } else {
            #if DEBUG
            Self.initLog("ghostty_app_new(primary) failed; attempting fallback config")
            Self.dumpConfigDiagnostics(primaryConfig, label: "primary")
            #endif

            // If the user config is invalid, prefer a minimal fallback configuration so
            // term-mesh still launches with working terminals.
            ghostty_config_free(primaryConfig)

            guard let fallbackConfig = ghostty_config_new() else {
                Logger.ui.error("Failed to create ghostty fallback config")
                return
            }

            ghostty_config_finalize(fallbackConfig)
            updateDefaultBackground(from: fallbackConfig, source: "initialize.fallbackConfig")

            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                #if DEBUG
                Self.initLog("ghostty_app_new(fallback) failed")
                Self.dumpConfigDiagnostics(fallbackConfig, label: "fallback")
                #endif
                Logger.ui.error("Failed to create ghostty app")
                ghostty_config_free(fallbackConfig)
                return
            }

            self.app = created
            self.config = fallbackConfig
        }

        // Notify observers that a usable config is available (initial load).
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)

        #if os(macOS)
        if let app, let nsApp = NSApp {
            ghostty_app_set_focus(app, nsApp.isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })

        #endif
    }

    private func loadDefaultConfigFilesWithLegacyFallback(_ config: ghostty_config_t) {
        ghostty_config_load_default_files(config)
        loadLegacyGhosttyConfigIfNeeded(config)
        loadTermMeshThemeOverride(config)
        loadTermMeshSettingsOverride(config)
        ghostty_config_finalize(config)
    }



    /// Load the term-mesh terminal theme override file (if present).
    /// This file is written by TerminalThemeOverride when the user toggles light/dark mode.
    private func loadTermMeshThemeOverride(_ config: ghostty_config_t) {
        guard let url = TerminalThemeOverride.overrideURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        url.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
        #if DEBUG
        Self.initLog("loaded term-mesh theme override: \(url.path)")
        #endif
    }

    /// Load the term-mesh terminal settings override file (if present).
    /// This file is written by TerminalSettingsOverride when the user changes font/size/theme in Settings.
    private func loadTermMeshSettingsOverride(_ config: ghostty_config_t) {
        guard let url = TerminalSettingsOverride.overrideURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        url.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
        #if DEBUG
        Self.initLog("loaded term-mesh settings override: \(url.path)")
        #endif
    }

    static func shouldLoadLegacyGhosttyConfig(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let newConfigFileSize, newConfigFileSize == 0 else { return false }
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        return true
    }

    static func shouldApplyDefaultBackgroundUpdate(
        currentScope: GhosttyDefaultBackgroundUpdateScope,
        incomingScope: GhosttyDefaultBackgroundUpdateScope
    ) -> Bool {
        incomingScope.rawValue >= currentScope.rawValue
    }

    private func loadLegacyGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        // Ghostty 1.3+ prefers `config.ghostty`, but some users still have their real
        // settings in the legacy `config` file. If the new file exists but is empty,
        // load the legacy file as a compatibility fallback.
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let configNew = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        let configLegacy = ghosttyDir.appendingPathComponent("config", isDirectory: false)

        func fileSize(_ url: URL) -> Int? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return nil }
            return size.intValue
        }

        guard Self.shouldLoadLegacyGhosttyConfig(
            newConfigFileSize: fileSize(configNew),
            legacyConfigFileSize: fileSize(configLegacy)
        ) else { return }

        configLegacy.path.withCString { path in
            ghostty_config_load_file(config, path)
        }

        #if DEBUG
        Self.initLog("loaded legacy ghostty config because config.ghostty was empty: \(configLegacy.path)")
        #endif
        #endif
    }

    func tick() {
        guard let app = app else { return }

        let start = CACurrentMediaTime()
        ghostty_app_tick(app)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000

        // Track lag during scrolling
        if isScrolling {
            scrollLagSampleCount += 1
            scrollLagTotalMs += elapsedMs
            scrollLagMaxMs = max(scrollLagMaxMs, elapsedMs)
        }
    }

    func reloadConfiguration(soft: Bool = false, source: String = "unspecified") {
        guard let app else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=no_app")
            return
        }
        logThemeAction("reload begin source=\(source) soft=\(soft)")
        resetDefaultBackgroundUpdateScope(source: "reloadConfiguration(source=\(source))")
        if soft, let config {
            ghostty_app_update_config(app, config)
            NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
            logThemeAction("reload end source=\(source) soft=\(soft) mode=soft")
            return
        }

        guard let newConfig = ghostty_config_new() else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=config_alloc_failed")
            return
        }
        loadDefaultConfigFilesWithLegacyFallback(newConfig)
        ghostty_app_update_config(app, newConfig)
        updateDefaultBackground(
            from: newConfig,
            source: "reloadConfiguration(source=\(source))",
            scope: .unscoped
        )
        DispatchQueue.main.async {
            self.applyBackgroundToKeyWindow()
        }
        if let oldConfig = config {
            ghostty_config_free(oldConfig)
        }
        config = newConfig
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
        logThemeAction("reload end source=\(source) soft=\(soft) mode=full")
    }

    func openConfigurationInTextEdit() {
        #if os(macOS)
        let path = ghosttyStringValue(ghostty_config_open_path())
        guard !path.isEmpty else { return }
        let fileURL = URL(fileURLWithPath: path)
        let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: configuration)
        #endif
    }

    private func ghosttyStringValue(_ value: ghostty_string_s) -> String {
        defer { ghostty_string_free(value) }
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        let rawPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: rawPtr, count: Int(value.len))
        return String(decoding: buffer, as: UTF8.self)
    }

    private func resetDefaultBackgroundUpdateScope(source: String) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        defaultBackgroundUpdateScope = .unscoped
        defaultBackgroundScopeSource = "reset:\(source)"
        if backgroundLogEnabled {
            logBackground(
                "default background scope reset source=\(source) previousScope=\(previousScope.logLabel) previousSource=\(previousScopeSource)"
            )
        }
    }

    private func updateDefaultBackground(
        from config: ghostty_config_t?,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    ) {
        guard let config else { return }

        var resolvedColor = defaultBackgroundColor
        var color = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &color, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            resolvedColor = NSColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1.0
            )
        }

        var opacity = defaultBackgroundOpacity
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        applyDefaultBackground(
            color: resolvedColor,
            opacity: opacity,
            source: source,
            scope: scope
        )
    }

    private func applyDefaultBackground(
        color: NSColor,
        opacity: Double,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope
    ) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        guard Self.shouldApplyDefaultBackgroundUpdate(currentScope: previousScope, incomingScope: scope) else {
            if backgroundLogEnabled {
                logBackground(
                    "default background skipped source=\(source) incomingScope=\(scope.logLabel) currentScope=\(previousScope.logLabel) currentSource=\(previousScopeSource) color=\(color.hexString()) opacity=\(String(format: "%.3f", opacity))"
                )
            }
            return
        }

        defaultBackgroundUpdateScope = scope
        defaultBackgroundScopeSource = source

        let previousHex = defaultBackgroundColor.hexString()
        let previousOpacity = defaultBackgroundOpacity
        defaultBackgroundColor = color
        defaultBackgroundOpacity = opacity
        let hasChanged = previousHex != defaultBackgroundColor.hexString() ||
            abs(previousOpacity - defaultBackgroundOpacity) > 0.0001
        if hasChanged {
            notifyDefaultBackgroundDidChange(source: source)
        }
        if backgroundLogEnabled {
            logBackground(
                "default background updated source=\(source) scope=\(scope.logLabel) previousScope=\(previousScope.logLabel) previousScopeSource=\(previousScopeSource) previousColor=\(previousHex) previousOpacity=\(String(format: "%.3f", previousOpacity)) color=\(defaultBackgroundColor) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) changed=\(hasChanged)"
            )
        }
    }

    private func nextBackgroundEventId() -> UInt64 {
        precondition(Thread.isMainThread, "Background event IDs must be generated on main thread")
        backgroundEventCounter &+= 1
        return backgroundEventCounter
    }

    private func notifyDefaultBackgroundDidChange(source: String) {
        let signal = { [self] in
            let eventId = nextBackgroundEventId()
            defaultBackgroundNotificationDispatcher.signal(
                backgroundColor: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                eventId: eventId,
                source: source
            )
        }
        if Thread.isMainThread {
            signal()
        } else {
            DispatchQueue.main.async(execute: signal)
        }
    }

    private func logThemeAction(_ message: String) {
        guard backgroundLogEnabled else { return }
        logBackground("theme action \(message)")
    }

    private func actionLabel(for action: ghostty_action_s) -> String {
        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return "reload_config"
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return "config_change"
        case GHOSTTY_ACTION_COLOR_CHANGE:
            return "color_change"
        default:
            return String(describing: action.tag)
        }
    }

    private func logAction(_ action: ghostty_action_s, target: ghostty_target_s, tabId: UUID?, surfaceId: UUID?) {
        guard backgroundLogEnabled else { return }
        let targetLabel = target.tag == GHOSTTY_TARGET_SURFACE ? "surface" : "app"
        logBackground(
            "action event target=\(targetLabel) action=\(actionLabel(for: action)) tab=\(tabId?.uuidString ?? "nil") surface=\(surfaceId?.uuidString ?? "nil")"
        )
    }

    private func performOnMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
    }

    private func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    private func focusDirection(from direction: ghostty_action_goto_split_e) -> NavigationDirection? {
        switch direction {
        // For previous/next, we use left/right as a reasonable default
        // Bonsplit doesn't have cycle-based navigation
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .left
        case GHOSTTY_GOTO_SPLIT_NEXT: return .right
        case GHOSTTY_GOTO_SPLIT_UP: return .up
        case GHOSTTY_GOTO_SPLIT_DOWN: return .down
        case GHOSTTY_GOTO_SPLIT_LEFT: return .left
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> ResizeDirection? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private static func callbackContext(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag != GHOSTTY_TARGET_SURFACE {
            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
                action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
                action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
                logAction(action, target: target, tabId: nil, surfaceId: nil)
            }

            if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION {
                let actionTitle = action.action.desktop_notification.title
                    .flatMap { String(cString: $0) } ?? ""
                let actionBody = action.action.desktop_notification.body
                    .flatMap { String(cString: $0) } ?? ""
                DispatchQueue.main.async { [self] in
                    guard let tabManager = AppDelegate.shared?.tabManager,
                          let tabId = tabManager.selectedTabId else {
                        return
                    }
                    let tabTitle = tabManager.titleForTab(tabId) ?? "Terminal"
                    let command = actionTitle.isEmpty ? tabTitle : actionTitle
                    let body = actionBody
                    let surfaceId = tabManager.focusedSurfaceId(for: tabId)
                    notifications.addNotification(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: command,
                        subtitle: "",
                        body: body
                    )
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                let soft = action.action.reload_config.soft
                logThemeAction("reload request target=app soft=\(soft)")
                DispatchQueue.main.async {
                    GhosttyApp.shared.reloadConfiguration(soft: soft, source: "action.reload_config.app")
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_COLOR_CHANGE,
               action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                let resolvedColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                applyDefaultBackground(
                    color: resolvedColor,
                    opacity: defaultBackgroundOpacity,
                    source: "action.color_change.app",
                    scope: .app
                )
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                updateDefaultBackground(
                    from: action.action.config_change.config,
                    source: "action.config_change.app",
                    scope: .app
                )
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            return false
        }
        let callbackContext = Self.callbackContext(from: ghostty_surface_userdata(target.target.surface))
        let callbackTabId = callbackContext?.tabId
        let callbackSurfaceId = callbackContext?.surfaceId

        if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
            // The child (shell) exited. Ghostty will fall back to printing
            // "Process exited. Press any key..." into the terminal unless the host
            // handles this action. For term-mesh, the correct behavior is to close
            // the panel immediately (no prompt).
#if DEBUG
            dlog(
                "surface.action.showChildExited tab=\(callbackTabId?.uuidString.prefix(5) ?? "nil") " +
                "surface=\(callbackSurfaceId?.uuidString.prefix(5) ?? "nil")"
            )
#endif
#if DEBUG
            termMeshWriteChildExitProbe(
                [
                    "probeShowChildExitedTabId": callbackTabId?.uuidString ?? "",
                    "probeShowChildExitedSurfaceId": callbackSurfaceId?.uuidString ?? "",
                ],
                increments: ["probeShowChildExitedCount": 1]
            )
#endif
            // Keep host-close async to avoid re-entrant close/deinit while Ghostty is still
            // dispatching this action callback.
            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                if let callbackTabId,
                   let callbackSurfaceId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    manager.closePanelAfterChildExited(tabId: callbackTabId, surfaceId: callbackSurfaceId)
                }
            }
            // Always report handled so Ghostty doesn't print the fallback prompt.
            return true
        }

        guard let surfaceView = callbackContext?.surfaceView else { return false }
        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
            action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
            action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
            logAction(
                action,
                target: target,
                tabId: callbackTabId ?? surfaceView.tabId,
                surfaceId: callbackSurfaceId ?? surfaceView.terminalSurface?.id
            )
        }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = splitDirection(from: action.action.new_split) else {
                return false
            }
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManager else { return }
                _ = tabManager.newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
            return true
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = focusDirection(from: action.action.goto_split) else {
                return false
            }
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManager else { return }
                _ = tabManager.moveSplitFocus(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
            return true
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = resizeDirection(from: action.action.resize_split.direction) else {
                return false
            }
            let amount = action.action.resize_split.amount
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManager else { return }
                _ = tabManager.resizeSplit(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    direction: direction,
                    amount: amount
                )
            }
            return true
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let tabId = surfaceView.tabId else {
                return false
            }
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManager else { return }
                _ = tabManager.equalizeSplits(tabId: tabId)
            }
            return true
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else {
                return false
            }
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManager else { return }
                _ = tabManager.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            surfaceView.scrollbar = scrollbar
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: surfaceView,
                userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
            )
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            surfaceView.cellSize = cellSize
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateCellSize,
                object: surfaceView,
                userInfo: [GhosttyNotificationKey.cellSize: cellSize]
            )
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async {
                if let searchState = terminalSurface.searchState {
                    if let needle, !needle.isEmpty {
                        searchState.needle = needle
                    }
                } else {
                    terminalSurface.searchState = TerminalSurface.SearchState(needle: needle ?? "")
                }
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            DispatchQueue.main.async {
                terminalSurface.searchState = nil
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawTotal = action.action.search_total.total
            let total: UInt? = rawTotal >= 0 ? UInt(rawTotal) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.total = total
            }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawSelected = action.action.search_selected.selected
            let selected: UInt? = rawSelected >= 0 ? UInt(rawSelected) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.selected = selected
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            if let tabId = surfaceView.tabId,
               let surfaceId = surfaceView.terminalSurface?.id {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyDidSetTitle,
                        object: surfaceView,
                        userInfo: [
                            GhosttyNotificationKey.tabId: tabId,
                            GhosttyNotificationKey.surfaceId: surfaceId,
                            GhosttyNotificationKey.title: title,
                        ]
                    )
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else { return true }
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManager?.updateSurfaceDirectory(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    directory: pwd
                )
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let tabId = surfaceView.tabId else { return true }
            let surfaceId = surfaceView.terminalSurface?.id
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async { [self] in
                let tabTitle = AppDelegate.shared?.tabManager?.titleForTab(tabId) ?? "Terminal"
                let command = actionTitle.isEmpty ? tabTitle : actionTitle
                let body = actionBody
                notifications.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: command,
                    subtitle: "",
                    body: body
                )
            }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            if action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                surfaceView.backgroundColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                surfaceView.applySurfaceBackground()
                if backgroundLogEnabled {
                    logBackground("OSC background change tab=\(surfaceView.tabId?.uuidString ?? "unknown") color=\(surfaceView.backgroundColor?.description ?? "nil")")
                }
                DispatchQueue.main.async {
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            updateDefaultBackground(
                from: action.action.config_change.config,
                source: "action.config_change.surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil")",
                scope: .surface
            )
            if backgroundLogEnabled {
                logBackground(
                    "surface config change deferred terminal bg apply tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil")"
                )
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            logThemeAction(
                "reload request target=surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") soft=\(soft)"
            )
            DispatchQueue.main.async {
                // Keep all runtime theme/default-background state in the same path.
                GhosttyApp.shared.reloadConfiguration(
                    soft: soft,
                    source: "action.reload_config.surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil")"
                )
            }
            return true
        case GHOSTTY_ACTION_KEY_SEQUENCE:
            DispatchQueue.main.async {
                surfaceView.updateKeySequence(action.action.key_sequence)
            }
            return true
        case GHOSTTY_ACTION_KEY_TABLE:
            DispatchQueue.main.async {
                surfaceView.updateKeyTable(action.action.key_table)
            }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let openUrl = action.action.open_url
            guard let cstr = openUrl.url else { return false }
            let urlString = String(cString: cstr)
            guard let target = resolveTerminalOpenURLTarget(urlString) else { return false }
            if !BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowser() {
                let urlToOpen = target.url
                DispatchQueue.main.async { NSWorkspace.shared.open(urlToOpen) }
                return true
            }
            switch target {
            case let .external(url):
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                return true
            case let .embeddedBrowser(url):
                guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    return true
                }

                // If a host whitelist is configured and this host isn't in it, open externally.
                if !BrowserLinkOpenSettings.hostMatchesWhitelist(host) {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    return true
                }
                guard let tabId = surfaceView.tabId,
                      let surfaceId = surfaceView.terminalSurface?.id else { return false }
                return performOnMain {
                    guard let app = AppDelegate.shared,
                          let tabManager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
                          let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                        return false
                    }
                    if let targetPane = workspace.preferredBrowserTargetPane(fromPanelId: surfaceId) {
                        return workspace.newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil
                    } else {
                        return workspace.newBrowserSplit(from: surfaceId, orientation: .horizontal, url: url) != nil
                    }
                }
            }
        default:
            return false
        }
    }

    private func applyBackgroundToKeyWindow() {
        guard let window = activeMainWindow() else { return }
        if termMeshShouldUseTransparentBackgroundWindow() {
            window.backgroundColor = .clear
            window.isOpaque = false
            if backgroundLogEnabled {
                logBackground("applied transparent window for behindWindow blur")
            }
        } else {
            let color = defaultBackgroundColor.withAlphaComponent(defaultBackgroundOpacity)
            window.backgroundColor = color
            window.isOpaque = color.alphaComponent >= 1.0
            if backgroundLogEnabled {
                logBackground("applied default window background color=\(color) opacity=\(String(format: "%.3f", color.alphaComponent))")
            }
        }
    }

    private func activeMainWindow() -> NSWindow? {
        let keyWindow = NSApp.keyWindow
        if let raw = keyWindow?.identifier?.rawValue,
           raw == "term-mesh.main" || raw.hasPrefix("term-mesh.main.") {
            return keyWindow
        }
        return NSApp.windows.first(where: { window in
            guard let raw = window.identifier?.rawValue else { return false }
            return raw == "term-mesh.main" || raw.hasPrefix("term-mesh.main.")
        })
    }

    func logBackground(_ message: String) {
        let timestamp = Self.backgroundLogTimestampFormatter.string(from: Date())
        let uptimeMs = (ProcessInfo.processInfo.systemUptime - backgroundLogStartUptime) * 1000
        let frame60 = Int((CACurrentMediaTime() * 60.0).rounded(.down))
        let frame120 = Int((CACurrentMediaTime() * 120.0).rounded(.down))
        let threadLabel = Thread.isMainThread ? "main" : "background"
        backgroundLogLock.lock()
        defer { backgroundLogLock.unlock() }
        backgroundLogSequence &+= 1
        let sequence = backgroundLogSequence
        let line =
            "\(timestamp) seq=\(sequence) t+\(String(format: "%.3f", uptimeMs))ms thread=\(threadLabel) frame60=\(frame60) frame120=\(frame120) term-mesh bg: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: backgroundLogURL.path) == false {
                FileManager.default.createFile(atPath: backgroundLogURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: backgroundLogURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
