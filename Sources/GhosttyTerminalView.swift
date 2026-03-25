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

#if os(macOS)
func termMeshShouldUseTransparentBackgroundWindow() -> Bool {
    let defaults = UserDefaults.standard
    let sidebarBlendMode = defaults.string(forKey: "sidebarBlendMode") ?? "withinWindow"
    let bgGlassEnabled = defaults.object(forKey: "bgGlassEnabled") as? Bool ?? true
    return sidebarBlendMode == "behindWindow" && bgGlassEnabled && !WindowGlassEffect.isAvailable
}
#endif

#if DEBUG
func termMeshChildExitProbePath() -> String? {
    let env = ProcessInfo.processInfo.environment
    guard (env["TERMMESH_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] ?? env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"]) == "1",
          let path = env["TERMMESH_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] ?? env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
          !path.isEmpty else {
        return nil
    }
    return path
}

func termMeshLoadChildExitProbe(at path: String) -> [String: String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return [:]
    }
    return object
}

func termMeshWriteChildExitProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
    guard let path = termMeshChildExitProbePath() else { return }
    var payload = termMeshLoadChildExitProbe(at: path)
    for (key, by) in increments {
        let current = Int(payload[key] ?? "") ?? 0
        payload[key] = String(current + by)
    }
    for (key, value) in updates {
        payload[key] = value
    }
    guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
    try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func termMeshScalarHex(_ value: String?) -> String {
    guard let value else { return "" }
    return value.unicodeScalars
        .map { String(format: "%04X", $0.value) }
        .joined(separator: ",")
}
#endif

enum GhosttyPasteboardHelper {
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )
    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func stringContents(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        if let value = pasteboard.string(forType: .string) {
            return value
        }

        if let text = pasteboard.string(forType: utf8PlainTextType) {
            return text
        }

        if let path = saveClipboardImageToTempFile(from: pasteboard) {
            return path
        }

        return nil
    }

    static func hasString(for location: ghostty_clipboard_e) -> Bool {
        guard let pasteboard = pasteboard(for: location) else { return false }
        return (stringContents(from: pasteboard) ?? "").isEmpty == false
    }

    static func writeString(_ string: String, to location: ghostty_clipboard_e) {
        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private static func escapeForShell(_ value: String) -> String {
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    // MARK: - Clipboard image support

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
    ]

    private static func readImageData(from pasteboard: NSPasteboard) -> Data? {
        for type in imageTypes {
            if let data = pasteboard.data(forType: type) {
                return data
            }
        }
        return nil
    }

    static func saveClipboardImageToTempFile(from pasteboard: NSPasteboard) -> String? {
        guard let imageData = readImageData(from: pasteboard) else { return nil }
        guard let image = NSImage(data: imageData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        cleanupOldClipboardImages()

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "clipboard-\(timestamp).png"
        let path = "/tmp/\(filename)"
        do {
            try pngData.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    private static func cleanupOldClipboardImages() {
        let fm = FileManager.default
        let tmpDir = "/tmp"
        let oneHourAgo = Date().addingTimeInterval(-3600)
        guard let files = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
        for file in files where file.hasPrefix("clipboard-") && file.hasSuffix(".png") {
            let fullPath = "\(tmpDir)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let created = attrs[.creationDate] as? Date,
                  created < oneHourAgo else { continue }
            try? fm.removeItem(atPath: fullPath)
        }
    }
}


// MARK: - Debug Render Instrumentation

/// Lightweight instrumentation to detect whether Ghostty is actually requesting Metal drawables.
/// This helps catch "frozen until refocus" regressions without relying on screenshots (which can
/// mask redraw issues by forcing a window server flush).
final class GhosttyMetalLayer: CAMetalLayer {
    private let lock = NSLock()
    private var drawableCount: Int = 0
    private var lastDrawableTime: CFTimeInterval = 0

    func debugStats() -> (count: Int, last: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (drawableCount, lastDrawableTime)
    }

    override func nextDrawable() -> CAMetalDrawable? {
        lock.lock()
        drawableCount += 1
        lastDrawableTime = CACurrentMediaTime()
        lock.unlock()
        return super.nextDrawable()
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

final class TerminalSurface: Identifiable, ObservableObject {
    final class SearchState: ObservableObject {
        @Published var needle: String
        @Published var selected: UInt?
        @Published var total: UInt?

        init(needle: String = "") {
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

    private(set) var surface: ghostty_surface_t?
    private weak var attachedView: GhosttyNSView?
    /// When true, setFocus(true) calls are ignored to keep CVDisplayLink suspended.
    /// Set by TeamOrchestrator.setAgentSurfaceFocus() when pausing/resuming agent rendering.
    var renderingPaused = false
    /// Whether the terminal surface view is currently attached to a window.
    ///
    /// Use the hosted view rather than the inner surface view, since the surface can be
    /// temporarily unattached (surface not yet created / reparenting) even while the panel
    /// is already in the window.
    var isViewInWindow: Bool { hostedView.window != nil }
    let id: UUID
    private(set) var tabId: UUID
    /// Port ordinal for TERMMESH_PORT range assignment
    var portOrdinal: Int = 0
    /// Snapshotted once per app session so all workspaces use consistent values
    private static let sessionPortBase: Int = {
        let val = UserDefaults.standard.integer(forKey: "termMeshPortBase")
        return val > 0 ? val : 9100
    }()
    private static let sessionPortRangeSize: Int = {
        let val = UserDefaults.standard.integer(forKey: "termMeshPortRange")
        return val > 0 ? val : 10
    }()
    private let surfaceContext: ghostty_surface_context_e
    private let configTemplate: ghostty_surface_config_s?
    private let workingDirectory: String?
    private let command: String?
    let additionalEnvironment: [String: String]
    let hostedView: GhosttySurfaceScrollView
    private let surfaceView: GhosttyNSView
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0
    private var lastXScale: CGFloat = 0
    private var lastYScale: CGFloat = 0
    private var pendingTextQueue: [Data] = []
    private var pendingTextBytes: Int = 0
    private let maxPendingTextBytes = 1_048_576
    private var backgroundSurfaceStartQueued = false
    private var surfaceCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    @Published var searchState: SearchState? = nil {
	        didSet {
	            if let searchState {
	                hostedView.cancelFocusRequest()
                NSLog("Find: search state created tab=%@ surface=%@", tabId.uuidString, id.uuidString)
                searchNeedleCancellable = searchState.$needle
                    .removeDuplicates()
                    .map { needle -> AnyPublisher<String, Never> in
                        if needle.isEmpty || needle.count >= 3 {
                            return Just(needle).eraseToAnyPublisher()
                        }

                        return Just(needle)
                            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .sink { [weak self] needle in
                        NSLog("Find: needle updated tab=%@ surface=%@ needle=%@", self?.tabId.uuidString ?? "unknown", self?.id.uuidString ?? "unknown", needle)
                        _ = self?.performBindingAction("search:\(needle)")
                    }
            } else if oldValue != nil {
                searchNeedleCancellable = nil
                NSLog("Find: search state cleared tab=%@ surface=%@", tabId.uuidString, id.uuidString)
                _ = performBindingAction("end_search")
            }
        }
    }
    private var searchNeedleCancellable: AnyCancellable?

    init(
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: ghostty_surface_config_s?,
        workingDirectory: String? = nil,
        command: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.id = UUID()
        self.tabId = tabId
        self.surfaceContext = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.command = command
        self.additionalEnvironment = environment
        // Match Ghostty's own SurfaceView: ensure a non-zero initial frame so the backing layer
        // has non-zero bounds and the renderer can initialize without presenting a blank/stretched
        // intermediate frame on the first real resize.
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.surfaceView = view
        self.hostedView = GhosttySurfaceScrollView(surfaceView: view)
        // Surface is created when attached to a view
        hostedView.attachSurface(self)
    }


    func updateWorkspaceId(_ newTabId: UUID) {
        tabId = newTabId
        attachedView?.tabId = newTabId
        surfaceView.tabId = newTabId
    }
    #if DEBUG
    private static let surfaceLogPath = "/tmp/term-mesh-ghostty-surface.log"
    private static let sizeLogPath = "/tmp/term-mesh-ghostty-size.log"

    private static func surfaceLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: surfaceLogPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: surfaceLogPath, contents: line.data(using: .utf8))
        }
    }

    private static func sizeLog(_ message: String) {
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] ?? env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"]) == "1" else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: sizeLogPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: sizeLogPath, contents: line.data(using: .utf8))
        }
    }
    #endif

    /// Convert a backing-space pixel dimension to UInt32 for Ghostty surface sizing.
    /// Uses round() (.toNearestOrAwayFromZero) rather than floor() to avoid off-by-one
    /// column loss when Bonsplit split panes produce fractional backing-pixel widths
    /// (e.g. 799.5 px floors to 799 but rounds to 800, preserving the correct column count).
    private func pixelDimension(from value: CGFloat) -> UInt32 {
        guard value.isFinite else { return 0 }
        let rounded = (max(0, value)).rounded(.toNearestOrAwayFromZero)
        if rounded >= CGFloat(UInt32.max) {
            return UInt32.max
        }
        return UInt32(rounded)
    }

    private func scaleFactors(for view: GhosttyNSView) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let scale = max(
            1.0,
            view.window?.backingScaleFactor
                ?? view.layer?.contentsScale
                ?? NSScreen.main?.backingScaleFactor
                ?? 1.0
        )
        return (scale, scale, scale)
    }

    private func scaleApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    func attachToView(_ view: GhosttyNSView) {
#if DEBUG
        dlog(
            "surface.attach surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque()) " +
            "attached=\(attachedView != nil ? 1 : 0) hasSurface=\(surface != nil ? 1 : 0) inWindow=\(view.window != nil ? 1 : 0)"
        )
#endif

        // If already attached to this view, nothing to do.
        // Still re-assert the display id: during split close tree restructuring, the view can be
        // removed/re-added (or briefly have window/screen nil) without recreating the surface.
        // Ghostty's vsync-driven renderer depends on having a valid display id; if it is missing
        // or stale, the surface can appear visually frozen until a focus/visibility change.
        if attachedView === view && surface != nil {
#if DEBUG
            dlog("surface.attach.reuse surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque())")
#endif
            if let screen = view.window?.screen ?? NSScreen.main,
               let displayID = screen.displayID,
               displayID != 0,
               let s = surface {
                ghostty_surface_set_display_id(s, displayID)
            }
            view.forceRefreshSurface()
            return
        }

        if let attachedView, attachedView !== view {
#if DEBUG
            dlog(
                "surface.attach.skip surface=\(id.uuidString.prefix(5)) reason=alreadyAttachedToDifferentView " +
                "current=\(Unmanaged.passUnretained(attachedView).toOpaque()) new=\(Unmanaged.passUnretained(view).toOpaque())"
            )
#endif
            return
        }

        attachedView = view

        // If surface doesn't exist yet, create it once the view is in a real window so
        // content scale and pixel geometry are derived from the actual backing context.
        if surface == nil {
            guard view.window != nil else {
#if DEBUG
                dlog(
                    "surface.attach.defer surface=\(id.uuidString.prefix(5)) reason=noWindow " +
                    "bounds=\(String(format: "%.1fx%.1f", view.bounds.width, view.bounds.height))"
                )
#endif
                return
            }
#if DEBUG
            dlog("surface.attach.create.queue surface=\(id.uuidString.prefix(5))")
#endif
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.attachedView else { return }
#if DEBUG
                dlog("surface.attach.create surface=\(self.id.uuidString.prefix(5))")
#endif
                self.createSurface(for: view)
#if DEBUG
                dlog("surface.attach.create.done surface=\(self.id.uuidString.prefix(5)) hasSurface=\(self.surface != nil ? 1 : 0)")
#endif
            }
        } else if let screen = view.window?.screen ?? NSScreen.main,
                  let displayID = screen.displayID,
                  displayID != 0,
                  let s = surface {
            // Surface exists but we're (re)attaching after a view hierarchy move; ensure display id.
            ghostty_surface_set_display_id(s, displayID)
#if DEBUG
            dlog("surface.attach.displayId surface=\(id.uuidString.prefix(5)) display=\(displayID)")
#endif
        }
    }

    private func createSurface(for view: GhosttyNSView) {
        #if DEBUG
        let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap { String(cString: $0) } ?? "(unset)"
        let terminfo = getenv("TERMINFO").flatMap { String(cString: $0) } ?? "(unset)"
        let xdg = getenv("XDG_DATA_DIRS").flatMap { String(cString: $0) } ?? "(unset)"
        let manpath = getenv("MANPATH").flatMap { String(cString: $0) } ?? "(unset)"
        Self.surfaceLog("createSurface start surface=\(id.uuidString) tab=\(tabId.uuidString) bounds=\(view.bounds) inWindow=\(view.window != nil) resources=\(resourcesDir) terminfo=\(terminfo) xdg=\(xdg) manpath=\(manpath)")
        #endif

        guard let app = GhosttyApp.shared.app else {
            Logger.ui.error("Ghostty app not initialized")
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty app not initialized")
            #endif
            return
        }

        let scaleFactors = scaleFactors(for: view)

        var surfaceConfig = configTemplate ?? ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(surfaceView: view, terminalSurface: self))
        surfaceConfig.userdata = callbackContext.toOpaque()
        surfaceCallbackContext?.release()
        surfaceCallbackContext = callbackContext
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
#if DEBUG
        let templateFontText = String(format: "%.2f", surfaceConfig.font_size)
        dlog(
            "zoom.create surface=\(id.uuidString.prefix(5)) context=\(termMeshSurfaceContextName(surfaceContext)) " +
            "templateFont=\(templateFontText)"
        )
#endif
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        var env: [String: String] = [:]
        if surfaceConfig.env_var_count > 0, let existingEnv = surfaceConfig.env_vars {
            let count = Int(surfaceConfig.env_var_count)
            if count > 0 {
                for i in 0..<count {
                    let item = existingEnv[i]
                    if let key = String(cString: item.key, encoding: .utf8),
                       let value = String(cString: item.value, encoding: .utf8) {
                        env[key] = value
                    }
                }
            }
        }

        // Merge caller-supplied environment (e.g. team agent vars)
        for (key, value) in additionalEnvironment {
            env[key] = value
        }

        env["TERMMESH_SURFACE_ID"] = id.uuidString
        env["CMUX_SURFACE_ID"] = id.uuidString
        env["TERMMESH_WORKSPACE_ID"] = tabId.uuidString
        env["CMUX_WORKSPACE_ID"] = tabId.uuidString
        // Backward-compatible shell integration keys used by existing scripts/tests.
        env["TERMMESH_PANEL_ID"] = id.uuidString
        env["CMUX_PANEL_ID"] = id.uuidString
        env["TERMMESH_TAB_ID"] = tabId.uuidString
        env["CMUX_TAB_ID"] = tabId.uuidString
        let socketPath = SocketControlSettings.socketPath()
        env["TERMMESH_SOCKET_PATH"] = socketPath
        env["CMUX_SOCKET_PATH"] = socketPath
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            env["TERMMESH_BUNDLE_ID"] = bundleId
            env["CMUX_BUNDLE_ID"] = bundleId
        }

        // Port range for this workspace (base/range snapshotted once per app session)
        do {
            let startPort = Self.sessionPortBase + portOrdinal * Self.sessionPortRangeSize
            let portStr = String(startPort)
            let portEndStr = String(startPort + Self.sessionPortRangeSize - 1)
            let portRangeStr = String(Self.sessionPortRangeSize)
            env["TERMMESH_PORT"] = portStr
            env["CMUX_PORT"] = portStr
            env["TERMMESH_PORT_END"] = portEndStr
            env["CMUX_PORT_END"] = portEndStr
            env["TERMMESH_PORT_RANGE"] = portRangeStr
            env["CMUX_PORT_RANGE"] = portRangeStr
        }

        let claudeHooksEnabled = ClaudeCodeIntegrationSettings.hooksEnabled()
        if !claudeHooksEnabled {
            env["TERMMESH_CLAUDE_HOOKS_DISABLED"] = "1"
            env["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
        }

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                let separator = currentPath.isEmpty ? "" : ":"
                env["PATH"] = "\(cliBinPath)\(separator)\(currentPath)"
            }
        }

        // Shell integration: inject ZDOTDIR wrapper for zsh shells.
        let shellIntegrationEnabled = UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true
        if shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path {
            env["TERMMESH_SHELL_INTEGRATION"] = "1"
            env["CMUX_SHELL_INTEGRATION"] = "1"
            env["TERMMESH_SHELL_INTEGRATION_DIR"] = integrationDir
            env["CMUX_SHELL_INTEGRATION_DIR"] = integrationDir

            let shell = (env["SHELL"]?.isEmpty == false ? env["SHELL"] : nil)
                ?? getenv("SHELL").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            if shellName == "zsh" {
                let candidateZdotdir = (env["ZDOTDIR"]?.isEmpty == false ? env["ZDOTDIR"] : nil)
                    ?? getenv("ZDOTDIR").map { String(cString: $0) }
                    ?? (ProcessInfo.processInfo.environment["ZDOTDIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["ZDOTDIR"] : nil)

                if let candidateZdotdir, !candidateZdotdir.isEmpty {
                    var isGhosttyInjected = false
                    let ghosttyResources = (env["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? env["GHOSTTY_RESOURCES_DIR"] : nil)
                        ?? getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) }
                        ?? (ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] : nil)
                    if let ghosttyResources {
                        let ghosttyZdotdir = URL(fileURLWithPath: ghosttyResources)
                            .appendingPathComponent("shell-integration/zsh").path
                        isGhosttyInjected = (candidateZdotdir == ghosttyZdotdir)
                    }
                    if !isGhosttyInjected {
                        env["TERMMESH_ZSH_ZDOTDIR"] = candidateZdotdir
                        env["CMUX_ZSH_ZDOTDIR"] = candidateZdotdir
                    }
                }

                env["ZDOTDIR"] = integrationDir
            }
        }

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createSurface = { [self] in
            if !envVars.isEmpty {
                let envVarsCount = envVars.count
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envVarsCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        // Apply optional working directory and command, then create the surface.
        // withCString keeps the C pointer alive during ghostty_surface_new.
        // ghostty handles login shell setup via login(1) on macOS when no command
        // is specified. When a command IS specified, it runs directly without a
        // login shell. The "forceLoginShell" preference wraps explicit commands
        // in `$SHELL -l -c '...'` so .profile/.zshrc are always sourced.
        let resolvedCommand: String? = {
            guard let command, !command.isEmpty else { return nil }
            let loginShellMode = UserDefaults.standard.string(forKey: "shellLoginMode") ?? "login"
            guard loginShellMode == "login" else { return command }
            // Already a login-shell invocation — don't double-wrap.
            if command.contains(" -l ") || command.contains(" --login") || command.hasSuffix(" -l") {
                return command
            }
            let shell = getenv("SHELL").map { String(cString: $0) } ?? "/bin/zsh"
            // Wrap in login shell: $SHELL -l -c 'exec <command>'
            let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
            return "\(shell) -l -c 'exec \(escaped)'"
        }()

        if let workingDirectory, !workingDirectory.isEmpty {
            if let resolvedCommand {
                workingDirectory.withCString { cWorkingDir in
                    resolvedCommand.withCString { cCmd in
                        surfaceConfig.working_directory = cWorkingDir
                        surfaceConfig.command = cCmd
                        createSurface()
                    }
                }
            } else {
                workingDirectory.withCString { cWorkingDir in
                    surfaceConfig.working_directory = cWorkingDir
                    createSurface()
                }
            }
        } else if let resolvedCommand {
            resolvedCommand.withCString { cCmd in
                surfaceConfig.command = cCmd
                createSurface()
            }
        } else {
            createSurface()
        }

        if surface == nil {
            surfaceCallbackContext?.release()
            surfaceCallbackContext = nil
            Logger.ui.error("Failed to create ghostty surface")
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty_surface_new returned nil")
            if let cfg = GhosttyApp.shared.config {
                let count = Int(ghostty_config_diagnostics_count(cfg))
                Self.surfaceLog("createSurface diagnostics count=\(count)")
                for i in 0..<count {
                    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                    let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
                    Self.surfaceLog("  [\(i)] \(msg)")
                }
            } else {
                Self.surfaceLog("createSurface diagnostics: config=nil")
            }
            #endif
            return
        }
        guard let createdSurface = surface else { return }

        // For vsync-driven rendering, Ghostty needs to know which display we're on so it can
        // start a CVDisplayLink with the right refresh rate. If we don't set this early, the
        // renderer can believe vsync is "running" but never deliver frames, which looks like a
        // frozen terminal until focus/visibility changes force a synchronous draw.
        //
        // `view.window?.screen` can be transiently nil during early attachment; fall back to the
        // primary screen so we always set *some* display ID, then update again on screen changes.
        if let screen = view.window?.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(createdSurface, displayID)
        }

        ghostty_surface_set_content_scale(createdSurface, scaleFactors.x, scaleFactors.y)
        let backingSize = view.convertToBacking(NSRect(origin: .zero, size: view.bounds.size)).size
        let wpx = pixelDimension(from: backingSize.width)
        let hpx = pixelDimension(from: backingSize.height)
        if wpx > 0, hpx > 0 {
            ghostty_surface_set_size(createdSurface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
            lastXScale = scaleFactors.x
            lastYScale = scaleFactors.y
        }

        // Some GhosttyKit builds can drop inherited font_size during post-create
        // config/scale reconciliation. If runtime points don't match the inherited
        // template points, re-apply via binding action so all creation paths
        // (new surface, split, new workspace) preserve zoom from the source terminal.
        if let inheritedFontPoints = configTemplate?.font_size,
           inheritedFontPoints > 0 {
            let currentFontPoints = termMeshCurrentSurfaceFontSizePoints(createdSurface)
            let shouldReapply = {
                guard let currentFontPoints else { return true }
                return abs(currentFontPoints - inheritedFontPoints) > 0.05
            }()
            if shouldReapply {
                let action = String(format: "set_font_size:%.3f", inheritedFontPoints)
                _ = performBindingAction(action)
            }
        }

        flushPendingTextIfNeeded()

#if DEBUG
        let runtimeFontText = termMeshCurrentSurfaceFontSizePoints(createdSurface).map {
            String(format: "%.2f", $0)
        } ?? "nil"
        dlog(
            "zoom.create.done surface=\(id.uuidString.prefix(5)) context=\(termMeshSurfaceContextName(surfaceContext)) " +
            "runtimeFont=\(runtimeFontText)"
        )
#endif
    }

    func updateSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        layerScale: CGFloat,
        backingSize: CGSize? = nil
    ) {
        guard let surface = surface else { return }
        _ = layerScale

        let resolvedBackingWidth = backingSize?.width ?? (width * xScale)
        let resolvedBackingHeight = backingSize?.height ?? (height * yScale)
        let wpx = pixelDimension(from: resolvedBackingWidth)
        let hpx = pixelDimension(from: resolvedBackingHeight)
        guard wpx > 0, hpx > 0 else { return }

        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight

        #if DEBUG
        Self.sizeLog("updateSize-call surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) changed=\((scaleChanged || sizeChanged) ? 1 : 0)")
        #endif

        guard scaleChanged || sizeChanged else { return }

        #if DEBUG
        if sizeChanged {
            let win = attachedView?.window != nil ? "1" : "0"
            Self.sizeLog("updateSize surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) win=\(win)")
        }
        #endif

        if scaleChanged {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if sizeChanged {
            ghostty_surface_set_size(surface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
    }

    /// Force a full size recalculation and surface redraw.
    func forceRefresh() {
	        let viewState: String
	        if let view = attachedView {
	            let inWindow = view.window != nil
	            let bounds = view.bounds
	            let metalOK = (view.layer as? CAMetalLayer) != nil
	            viewState = "inWindow=\(inWindow) bounds=\(bounds) metalOK=\(metalOK)"
	        } else {
	            viewState = "NO_ATTACHED_VIEW"
	        }
        #if DEBUG
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] forceRefresh: \(id) \(viewState)\n"
        let logPath = "/tmp/term-mesh-refresh-debug.log"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
	        #endif
        guard let view = attachedView,
              view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }

        view.forceRefreshSurface()
        ghostty_surface_refresh(surface)
    }

    func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    func setFocus(_ focused: Bool) {
        // If rendering is paused (agent pane suppressed), block re-focus attempts.
        // This prevents CVDisplayLink from restarting when panel.focus() or
        // becomeFirstResponder triggers setFocus(true) after pause.
        if renderingPaused && focused { return }
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)

        // If we focus a surface while it is being rapidly reparented (closing splits, etc),
        // Ghostty's CVDisplayLink can end up started before the display id is valid, leaving
        // hasVsync() true but with no callbacks ("stuck-vsync-no-frames"). Reasserting the
        // display id *after* focusing lets Ghostty restart the display link when needed.
        if focused {
            if let view = attachedView,
               let displayID = (view.window?.screen ?? NSScreen.main)?.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
    }

    func setOcclusion(_ visible: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func needsConfirmClose() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        guard let surface = surface else {
            enqueuePendingText(data)
            return
        }
        writeTextData(data, to: surface)
    }

    /// Send text + Enter using the same approach as the socket `send_surface` command.
    /// This is the most reliable text delivery path — proven to work for team agent delivery.
    /// Control characters (\r, \n, \t, ESC, DEL) are sent as proper key events.
    /// All other characters are sent as text key events.
    @discardableResult
    func sendSocketStyleText(_ text: String, withReturn: Bool = true) -> Bool {
        guard let surface = surface else { return false }
        let payload = withReturn ? text + "\r" : text
        for scalar in payload.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D:
                sendSurfaceKeyPress(keycode: 0x24, text: "\r") // kVK_Return
            case 0x09:
                sendSurfaceKeyPress(keycode: 0x30, text: "\t") // kVK_Tab
            case 0x1B:
                sendSurfaceKeyPress(keycode: 0x35, text: "\u{1b}") // kVK_Escape
            case 0x7F:
                sendSurfaceKeyPress(keycode: 0x33, text: "\u{7f}") // kVK_Delete
            default:
                let ch = String(scalar)
                ch.withCString { ptr in
                    var keyEvent = ghostty_input_key_s()
                    keyEvent.action = GHOSTTY_ACTION_PRESS
                    keyEvent.keycode = 0
                    keyEvent.mods = GHOSTTY_MODS_NONE
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.unshifted_codepoint = 0
                    keyEvent.text = ptr
                    keyEvent.composing = false
                    _ = ghostty_surface_key(surface, keyEvent)
                }
                var releaseEvent = ghostty_input_key_s()
                releaseEvent.action = GHOSTTY_ACTION_RELEASE
                releaseEvent.keycode = 0
                releaseEvent.mods = GHOSTTY_MODS_NONE
                releaseEvent.consumed_mods = GHOSTTY_MODS_NONE
                releaseEvent.unshifted_codepoint = 0
                releaseEvent.text = nil
                releaseEvent.composing = false
                _ = ghostty_surface_key(surface, releaseEvent)
            }
        }
        return true
    }

    /// Send a key press directly through the Ghostty surface API.
    /// Unlike sendSyntheticKeyPress (which creates an NSEvent and requires the view to be
    /// in a window), this works even when the surface view is not attached to a window —
    /// e.g. when the panel is in a non-active tab.
    func sendSurfaceKeyPress(keycode: UInt16, text: String? = nil) {
        guard let surface = surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(keycode)
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        if let text {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
        // Send matching RELEASE event — TUI apps (Claude Code, kiro-cli) may
        // track key state and ignore subsequent PRESS events if the previous
        // key was never released.
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
    }

    /// Send text as key events through the ghostty surface API.
    /// Unlike sendText (which writes raw bytes to PTY), this sends proper key events
    /// that work with TUI applications like Claude Code.
    func sendInputText(_ text: String) {
        guard let surface = surface else { return }
        var buffered = ""

        func flush() {
            guard !buffered.isEmpty else { return }
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = 0
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            buffered.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
            buffered.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D:
                flush()
                sendSurfaceKeyPress(keycode: 0x24, text: "\r") // kVK_Return
            case 0x09:
                flush()
                sendSurfaceKeyPress(keycode: 0x30, text: "\t") // kVK_Tab
            case 0x1B:
                flush()
                sendSurfaceKeyPress(keycode: 0x35, text: "\u{1b}") // kVK_Escape
            case 0x7F:
                flush()
                sendSurfaceKeyPress(keycode: 0x33, text: "\u{7f}") // kVK_Delete
            default:
                buffered.unicodeScalars.append(scalar)
            }
        }
        flush()
    }

    /// Send text via IME-style PRESS+RELEASE pairs for reliable key state tracking.
    /// Unlike sendInputText which sends PRESS-only for text chars (causing key state
    /// ambiguity), this sends proper PRESS+RELEASE pairs per chunk, then an atomic
    /// Return key event — all synchronously within one call.
    ///
    /// Multiline text (containing `\n`) is sent via `sendText` (bracketed paste) so the
    /// terminal treats newlines as content rather than per-line execution.
    @discardableResult
    func sendIMEText(_ text: String, withReturn: Bool = true) -> Bool {
        guard let surface = surface else {
            #if DEBUG
            dlog("ime.send.fail reason=surface_nil")
            #endif
            return false
        }

        // Multiline: collapse newlines to spaces so the text is sent as a single
        // line via key events. Bracketed paste + Return key event doesn't reliably
        // submit in TUI apps (Claude Code). Newlines in agent instructions are
        // formatting only — the LLM understands the instruction without them.
        let normalized: String
        if text.contains("\n") {
            normalized = text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        } else {
            normalized = text
        }

        if !normalized.isEmpty {
            // Use ghostty_surface_text for text delivery — it properly wraps
            // content in bracketed paste markers (\e[200~...\e[201~) when the
            // terminal has bracketed paste mode enabled. This ensures TUI apps
            // like Claude Code handle the text as an official paste event rather
            // than inferring paste from rapid keystroke arrival (which can cause
            // the subsequent Return key to be silently dropped).
            let data = normalized.utf8
            let len = UInt(data.count)
            data.withContiguousStorageIfAvailable { buf in
                ghostty_surface_text(surface, buf.baseAddress, len)
            } ?? normalized.withCString { cstr in
                ghostty_surface_text(surface, cstr, len)
            }
        }

        // When text was delivered and Return is requested, brief pause to let
        // the IO thread flush the paste to the PTY. Note: for team text delivery,
        // sendTextToPanel splits text and Return into separate MainActor turns,
        // so this delay is mainly for direct sendIMEText callers.
        if withReturn && !normalized.isEmpty {
            usleep(5_000) // 5ms — enough for IO thread to flush paste to PTY
        }

        // Send Return key (PRESS+RELEASE) with retry on failure
        if withReturn {
            let maxRetries = 3
            let retryDelayUs: [useconds_t] = [10_000, 30_000, 150_000] // 10ms, 30ms, 150ms
            var returnDelivered = false

            for attempt in 0..<maxRetries {
                var keyEvent = ghostty_input_key_s()
                keyEvent.action = GHOSTTY_ACTION_PRESS
                keyEvent.keycode = 36 // kVK_Return
                keyEvent.mods = GHOSTTY_MODS_NONE
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.unshifted_codepoint = 13 // CR codepoint for proper logical key mapping
                keyEvent.composing = false
                var pressHandled = false
                "\r".withCString { ptr in
                    keyEvent.text = ptr
                    pressHandled = ghostty_surface_key(surface, keyEvent)
                }
                keyEvent.action = GHOSTTY_ACTION_RELEASE
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)

                if pressHandled {
                    returnDelivered = true
                    break
                }

                #if DEBUG
                dlog("[sendIMEText.Return] PRESS not handled, retry \(attempt + 1)/\(maxRetries) surface=\(id.uuidString.prefix(8))")
                #endif

                if attempt < maxRetries - 1 {
                    // Use usleep to block MainActor — prevents other sendIMEText
                    // calls from interleaving (pasting into same prompt).
                    usleep(retryDelayUs[attempt])
                }
            }

            if !returnDelivered {
                #if DEBUG
                dlog("[sendIMEText.Return] FAIL: Return not delivered after \(maxRetries) retries surface=\(id.uuidString.prefix(8))")
                #endif
                return false
            }
        }
        return true
    }

    func requestBackgroundSurfaceStartIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        guard surface == nil, attachedView != nil else { return }
        guard !backgroundSurfaceStartQueued else { return }
        backgroundSurfaceStartQueued = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.backgroundSurfaceStartQueued = false
            guard self.surface == nil, let view = self.attachedView else { return }
            #if DEBUG
            let startedAt = ProcessInfo.processInfo.systemUptime
            #endif
            self.createSurface(for: view)
            #if DEBUG
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
            dlog(
                "surface.background_start surface=\(self.id.uuidString.prefix(8)) inWindow=\(view.window != nil ? 1 : 0) ready=\(self.surface != nil ? 1 : 0) ms=\(String(format: "%.2f", elapsedMs))"
            )
            #endif
        }
    }

    private func writeTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    private func enqueuePendingText(_ data: Data) {
        let incomingBytes = data.count
        while !pendingTextQueue.isEmpty && pendingTextBytes + incomingBytes > maxPendingTextBytes {
            let dropped = pendingTextQueue.removeFirst()
            pendingTextBytes -= dropped.count
        }

        pendingTextQueue.append(data)
        pendingTextBytes += incomingBytes
        #if DEBUG
        dlog(
            "surface.send_text.queue surface=\(id.uuidString.prefix(8)) chunks=\(pendingTextQueue.count) bytes=\(pendingTextBytes)"
        )
        #endif
    }

    private func flushPendingTextIfNeeded() {
        guard let surface = surface, !pendingTextQueue.isEmpty else { return }
        let queued = pendingTextQueue
        let queuedBytes = pendingTextBytes
        pendingTextQueue.removeAll(keepingCapacity: false)
        pendingTextBytes = 0

        for chunk in queued {
            writeTextData(chunk, to: surface)
        }
        #if DEBUG
        dlog(
            "surface.send_text.flush surface=\(id.uuidString.prefix(8)) chunks=\(queued.count) bytes=\(queuedBytes)"
        )
        #endif
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    deinit {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surface else {
            callbackContext?.release()
            return
        }

        // Keep teardown asynchronous to avoid re-entrant close/deinit loops, but retain
        // callback userdata until surface free completes so callbacks never dereference
        // a deallocated view pointer.
        Task { @MainActor in
            ghostty_surface_free(surface)
            callbackContext?.release()
        }
    }
}

// MARK: - Ghostty Surface View

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    private static let focusDebugEnabled: Bool = {
        if termMeshEnv("FOCUS_DEBUG") == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "termMeshFocusDebug")
    }()
    private static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL
    ]
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    // MARK: - TERM-MESH-1: Startup NSTextInputContext gate
    //
    // NSApplication.updateWindows fires on every run-loop cycle and calls
    // NSTextInputContext.currentInputContext_withFirstResponderSync for the
    // current first responder. If GhosttyNSView is the first responder during
    // the *first* updateWindows cycle (uptime ≈ 0 s), AppKit lazily initialises
    // NSKeyBindingManager, which synchronously reads DefaultKeyBinding.dict via
    // NSDictionary.dictionaryWithContentsOfFile: on the main thread — causing
    // 2 s+ App Hangs captured in Sentry (TERM-MESH-1, 44 events).
    //
    // Returning nil from inputContext during startup prevents AppKit from
    // activating NSTextInputContext at all, so NSKeyBindingManager is never
    // touched until we deliberately call enableInputContext() one run-loop
    // after applicationDidFinishLaunching.
    private static var inputContextReady = false

    override var inputContext: NSTextInputContext? {
#if DEBUG
        if !Self.inputContextReady {
            dlog("inputContext.deferred reason=startupGuard")
        }
#endif
        guard Self.inputContextReady else { return nil }
        return super.inputContext
    }

    /// Call once, after the first run-loop cycle post-launch, to allow
    /// NSTextInputContext (and therefore NSKeyBindingManager) to activate.
    static func enableInputContext() {
#if DEBUG
        dlog("inputContext.enabled reason=postStartup")
#endif
        inputContextReady = true
    }

static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        FocusLogStore.shared.append(message)
        NSLog("[FOCUSDBG] %@", message)
    }

    /// Injected config provider (defaults to singleton for backward compatibility).
    var configProvider: any GhosttyConfigProvider = GhosttyApp.shared

    weak var terminalSurface: TerminalSurface?
    var scrollbar: GhosttyScrollbar?
    var cellSize: CGSize = .zero
    var desiredFocus: Bool = false
    var suppressingReparentFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private var lastLoggedSurfaceBackgroundSignature: String?
    private var lastLoggedWindowBackgroundSignature: String?
    private var keySequence: [ghostty_input_trigger_s] = []
    private var keyTables: [String] = []
#if DEBUG
    private static let keyLatencyProbeEnabled: Bool = {
        if termMeshEnv("KEY_LATENCY_PROBE") == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "termMeshKeyLatencyProbe")
    }()
#endif
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
	    private var lastScrollEventTime: CFTimeInterval = 0
    private var visibleInUI: Bool = true
    private var pendingSurfaceSize: CGSize?
#if DEBUG
    private var lastSizeSkipSignature: String?
#endif

    private var hasUsableFocusGeometry: Bool {
        bounds.width > 1 && bounds.height > 1
    }

        // Visibility is used for focus gating, not for libghostty occlusion.
    var isVisibleInUI: Bool { visibleInUI }
    func setVisibleInUI(_ visible: Bool) {
            visibleInUI = visible
        }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Only enable our instrumented CAMetalLayer in targeted debug/test scenarios.
        // The lock in GhosttyMetalLayer.nextDrawable() adds overhead we don't want in normal runs.
        wantsLayer = true
        layer?.masksToBounds = true
        installEventMonitor()
        updateTrackingAreas()
        registerForDraggedTypes(Array(Self.dropTypes))

    }

    private func effectiveBackgroundColor() -> NSColor {
        let base = backgroundColor ?? configProvider.defaultBackgroundColor
        let opacity = configProvider.defaultBackgroundOpacity
        return base.withAlphaComponent(opacity)
    }

    func applySurfaceBackground() {
        let color = effectiveBackgroundColor()
        if let layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = color.cgColor
            layer.isOpaque = color.alphaComponent >= 1.0
            CATransaction.commit()
        }
        terminalSurface?.hostedView.setBackgroundColor(color)
        if configProvider.backgroundLogEnabled {
            let signature = "\(color.hexString()):\(String(format: "%.3f", color.alphaComponent))"
            if signature != lastLoggedSurfaceBackgroundSignature {
                lastLoggedSurfaceBackgroundSignature = signature
                configProvider.logBackground(
                    "surface background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
                )
            }
        }
    }

    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        if let tabId, let selectedId = AppDelegate.shared?.tabManager?.selectedTabId, tabId != selectedId {
            return
        }
        applySurfaceBackground()
        let color = effectiveBackgroundColor()
        if termMeshShouldUseTransparentBackgroundWindow() {
            window.backgroundColor = .clear
            window.isOpaque = false
        } else {
            window.backgroundColor = color
            window.isOpaque = color.alphaComponent >= 1.0
        }
        if configProvider.backgroundLogEnabled {
            let signature = "\(termMeshShouldUseTransparentBackgroundWindow() ? "transparent" : color.hexString()):\(String(format: "%.3f", color.alphaComponent))"
            if signature != lastLoggedWindowBackgroundSignature {
                lastLoggedWindowBackgroundSignature = signature
                configProvider.logBackground(
                    "window background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") transparent=\(termMeshShouldUseTransparentBackgroundWindow()) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
                )
            }
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        default:
            return event
        }
    }

    private func localEventScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        Self.focusLog("localEventScrollWheel: window=\(ObjectIdentifier(window)) firstResponder=\(String(describing: window.firstResponder))")
        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        appliedColorScheme = nil
        terminalSurface = surface
        tabId = surface.tabId
        surface.attachToView(self)
        updateSurfaceSize()
        applySurfaceBackground()
        applySurfaceColorScheme(force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
#if DEBUG
        dlog(
            "surface.view.windowMove surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) bounds=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
            "pending=\(String(format: "%.1fx%.1f", pendingSurfaceSize?.width ?? 0, pendingSurfaceSize?.height ?? 0))"
        )
#endif
        guard let window else { return }

        // If the surface creation was deferred while detached, create/attach it now.
        terminalSurface?.attachToView(self)

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            self?.windowDidChangeScreen(notification)
        }

        if let surface = terminalSurface?.surface,
           let displayID = window.screen?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        // Recompute from current bounds after layout. Pending size is only a fallback
        // when we don't have usable bounds (e.g. detached/off-window transitions).
        superview?.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateSurfaceSize()
        applySurfaceBackground()
        applySurfaceColorScheme(force: true)
        applyWindowBackgroundIfActive()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configProvider.logBackgroundIfEnabled(
            "surface appearance changed tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "nil")"
        )
        applySurfaceColorScheme()
    }

func updateOcclusionState() {
        // Intentionally no-op: we don't drive libghostty occlusion from AppKit occlusion state.
        // This avoids transient clears during reparenting and keeps rendering logic minimal.
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override var isOpaque: Bool { false }

    private func resolvedSurfaceSize(preferred size: CGSize?) -> CGSize {
        if let size,
           size.width > 0,
           size.height > 0 {
            return size
        }

        let currentBounds = bounds.size
        if currentBounds.width > 0, currentBounds.height > 0 {
            return currentBounds
        }

        if let pending = pendingSurfaceSize,
           pending.width > 0,
           pending.height > 0 {
            return pending
        }

        return currentBounds
    }

    private func updateSurfaceSize(size: CGSize? = nil) {
        guard let terminalSurface = terminalSurface else { return }
        let size = resolvedSurfaceSize(preferred: size)
        guard size.width > 0 && size.height > 0 else {
#if DEBUG
            let signature = "nonPositive-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                dlog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=nonPositive size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return
        }
        pendingSurfaceSize = size
        guard let window else {
#if DEBUG
            let signature = "noWindow-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                dlog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=noWindow " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return
        }

        // First principles: derive pixel size from AppKit's backing conversion for the current
        // window/screen. Avoid updating Ghostty while detached from a window.
        let backingSize = convertToBacking(NSRect(origin: .zero, size: size)).size
        guard backingSize.width > 0, backingSize.height > 0 else {
#if DEBUG
            let signature = "zeroBacking-\(Int(backingSize.width))x\(Int(backingSize.height))"
            if lastSizeSkipSignature != signature {
                dlog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=zeroBacking " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return
        }
#if DEBUG
        if lastSizeSkipSignature != nil {
            dlog(
                "surface.size.resume surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
            )
            lastSizeSkipSignature = nil
        }
#endif
        let xScale = backingSize.width / size.width
        let yScale = backingSize.height / size.height
        let layerScale = max(1.0, window.backingScaleFactor)
        let drawablePixelSize = CGSize(
            width: (max(0, backingSize.width)).rounded(.toNearestOrAwayFromZero),
            height: (max(0, backingSize.height)).rounded(.toNearestOrAwayFromZero)
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = layerScale
        layer?.masksToBounds = true
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = drawablePixelSize
        }
        CATransaction.commit()

        terminalSurface.updateSize(
            width: size.width,
            height: size.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale,
            backingSize: backingSize
        )
    }

func pushTargetSurfaceSize(_ size: CGSize) {
        updateSurfaceSize(size: size)
    }

    /// Force a full size recalculation and Metal layer refresh.
    /// Resets cached metrics so updateSurfaceSize() re-runs unconditionally.
    func forceRefreshSurface() {
        updateSurfaceSize()
    }


    func expectedPixelSize(for pointsSize: CGSize) -> CGSize {
        let backing = convertToBacking(NSRect(origin: .zero, size: pointsSize)).size
        if backing.width > 0, backing.height > 0 {
            return backing
        }
        let scale = max(1.0, window?.backingScaleFactor ?? layer?.contentsScale ?? 1.0)
        return CGSize(width: pointsSize.width * scale, height: pointsSize.height * scale)
    }

    // Convenience accessor for the ghostty surface
    var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    private func applySurfaceColorScheme(force: Bool = false) {
        guard let surface else { return }
        let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let scheme: ghostty_color_scheme_e = bestMatch == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        if !force, appliedColorScheme == scheme {
            configProvider.logBackgroundIfEnabled(
                "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") scheme=\(scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light") force=\(force) applied=false"
            )
            return
        }
        ghostty_surface_set_color_scheme(surface, scheme)
        appliedColorScheme = scheme
        configProvider.logBackgroundIfEnabled(
            "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") scheme=\(scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light") force=\(force) applied=true"
        )
    }

    @discardableResult
    private func ensureSurfaceReadyForInput() -> ghostty_surface_t? {
        if let surface = surface {
            return surface
        }
        guard window != nil else { return nil }
        terminalSurface?.attachToView(self)
        updateSurfaceSize(size: bounds.size)
        applySurfaceColorScheme(force: true)
        return surface
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        default:
            return true
        }
    }

    override var acceptsFirstResponder: Bool {
        // When the IME input bar is active, refuse first responder so all key events
        // go directly to IMETextView via AppKit's responder chain.
        if enclosingSurfaceScrollView?.findIMETextView() != nil {
            return false
        }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            // If we become first responder before the ghostty surface exists (e.g. during
            // split/tab creation while the surface is still being created), record the desired focus.
            desiredFocus = true

            // During programmatic splits, SwiftUI reparents the old NSView which triggers
            // becomeFirstResponder. Suppress onFocus + ghostty_surface_set_focus to prevent
            // the old view from stealing focus and creating model/surface divergence.
            if suppressingReparentFocus {
#if DEBUG
                dlog("focus.firstResponder SUPPRESSED (reparent) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                return result
            }

            // Always notify the host app that this pane became the first responder so bonsplit
            // focus/selection can converge. Previously this was gated on `surface != nil`, which
            // allowed a mismatch where AppKit focus moved but the UI focus indicator (bonsplit)
            // stayed behind.
            let hiddenInHierarchy = isHiddenOrHasHiddenAncestor
            if isVisibleInUI && hasUsableFocusGeometry && !hiddenInHierarchy {
                onFocus?()
            } else if isVisibleInUI && (!hasUsableFocusGeometry || hiddenInHierarchy) {
#if DEBUG
                dlog(
                    "focus.firstResponder SUPPRESSED (hidden_or_tiny) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) hidden=\(hiddenInHierarchy ? 1 : 0)"
                )
#endif
            }
        }
        if result, let surface = ensureSurfaceReadyForInput() {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("becomeFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
#if DEBUG
            dlog("focus.firstResponder surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
            if let terminalSurface {
                AppDelegate.shared?.recordJumpUnreadFocusIfExpected(
                    tabId: terminalSurface.tabId,
                    surfaceId: terminalSurface.id
                )
            }
#endif
            if let terminalSurface {
                NotificationCenter.default.post(
                    name: .ghosttyDidBecomeFirstResponderSurface,
                    object: nil,
                    userInfo: [
                        GhosttyNotificationKey.tabId: terminalSurface.tabId,
                        GhosttyNotificationKey.surfaceId: terminalSurface.id,
                    ]
                )
            }
            // Skip focus restoration if rendering is paused (agent pane suppressed).
            // Without this guard, becomeFirstResponder re-enables the CVDisplayLink
            // even after TeamOrchestrator has called setOcclusion(false)/setFocus(false).
            guard terminalSurface?.renderingPaused != true else { return result }
            ghostty_surface_set_focus(surface, true)

            // Ghostty only restarts its vsync display link on display-id changes while focused.
            // During rapid split close / SwiftUI reparenting, the view can reattach to a window
            // and get its display id set *before* it becomes first responder; in that case, the
            // renderer can remain stuck until some later screen/focus transition. Reassert the
            // display id now that we're focused to ensure the renderer is running.
            if let displayID = window?.screen?.displayID, displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let hadMarkedText = markedText.length > 0
        let result = super.resignFirstResponder()
        if result && hadMarkedText {
            // Clear IME composition after confirmed resign to prevent stale
            // markedText ranges causing NSRangeException (TERM-MESH-9 prevention).
            // Order: notify IME first, then clear internal state.
            inputContext?.discardMarkedText()
            unmarkText()
        }
        if result {
            desiredFocus = false
        }
        if result, let surface = surface {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("resignFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // For NSTextInputClient - accumulates text during key events
    var keyTextAccumulator: [String]? = nil
    var markedText = NSMutableAttributedString()
    private var lastPerformKeyEvent: TimeInterval?

#if DEBUG
    // Test-only accessors for keyTextAccumulator to verify CJK IME composition behavior.
    func setKeyTextAccumulatorForTesting(_ value: [String]?) {
        keyTextAccumulator = value
    }
    var keyTextAccumulatorForTesting: [String]? {
        keyTextAccumulator
    }

    // Test-only IME point override so firstRect behavior can be regression tested.
    var imePointOverrideForTesting: (x: Double, y: Double, width: Double, height: Double)?

    func setIMEPointForTesting(x: Double, y: Double, width: Double, height: Double) {
        imePointOverrideForTesting = (x, y, width, height)
    }

    func clearIMEPointForTesting() {
        imePointOverrideForTesting = nil
    }
#endif

#if DEBUG
    private func recordKeyLatency(path: String, event: NSEvent) {
        guard Self.keyLatencyProbeEnabled else { return }
        guard event.timestamp > 0 else { return }
        let delayMs = max(0, (CACurrentMediaTime() - event.timestamp) * 1000)
        let delayText = String(format: "%.2f", delayMs)
        dlog("key.latency path=\(path) ms=\(delayText) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat ? 1 : 0)")
    }
#endif

    /// Send a Return key press+release to the given surface.
    @discardableResult
    private func sendReturnKey(to surface: ghostty_surface_t) -> Bool {
        #if DEBUG
        dlog("[sendReturnKey] sending Return to surface \(terminalSurface?.id.uuidString.prefix(8) ?? "nil")")
        #endif
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 36
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        var pressHandled = false
        "\r".withCString { ptr in
            keyEvent.text = ptr
            pressHandled = ghostty_surface_key(surface, keyEvent)
        }
        #if DEBUG
        if !pressHandled {
            dlog("[sendReturnKey] WARN: Return key PRESS not handled by ghostty surface=\(terminalSurface?.id.uuidString.prefix(8) ?? "nil")")
        }
        #endif
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
        return pressHandled
    }

    /// Exponential backoff delays (ms) for surface-nil retry in sendIMEText.
    /// 4 attempts: 50 → 150 → 400 → 800 ms (total ~1.4 s before final failure).
    private static let sendIMETextRetryDelaysMs: [Double] = [50, 150, 400, 800]

    /// Send text from the IME Input Bar to the terminal surface as key input.
    ///
    /// Multiline: use bracketed paste so terminal treats newlines as content, not execution.
    /// The shell interprets each Return key event as "execute", so multiline text must be
    /// delivered via ghostty_surface_text (bracketed paste) rather than per-line key events.
    /// Single-line: use key events so TUI apps (Claude Code) receive proper press/release pairs.
    ///
    /// Returns true if text was delivered successfully, false if the surface was unavailable.
    /// If the surface is transiently nil (pane re-creation), retries up to 4 times with
    /// exponential backoff (50 → 150 → 400 → 800 ms) before giving up.
    @discardableResult
    func sendIMEText(_ text: String, withReturn: Bool = true, attempt: Int = 0) -> Bool {
        guard let surface = surface else {
            let delays = Self.sendIMETextRetryDelaysMs
            guard attempt < delays.count else {
#if DEBUG
                dlog("[sendIMEText] FAIL: surface nil after 4 retries, text+Enter dropped: \(text.prefix(50))")
#endif
                return false
            }
            let delayMs = delays[attempt]
#if DEBUG
            dlog("[sendIMEText] surface nil, retry \(attempt + 1)/\(delays.count) after \(Int(delayMs))ms surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
            DispatchQueue.main.asyncAfter(deadline: .now() + delayMs / 1000.0) { [weak self] in
                _ = self?.sendIMEText(text, withReturn: withReturn, attempt: attempt + 1)
            }
            return false
        }

        if text.contains("\n") {
            // Multiline: use bracketed paste so terminal treats newlines as content, not execution.
            // Sending Return key events between lines would cause the shell to execute each line
            // immediately instead of composing a multiline input.
            guard let ts = terminalSurface else {
#if DEBUG
                dlog("ime.send.fail reason=terminalSurface_nil path=multiline")
#endif
                return false
            }
            let payload = withReturn ? text + "\r" : text
            ts.sendText(payload)
            return true
        }

        // Single-line: use key events (PRESS+RELEASE) so TUI apps track key state correctly.
        if !text.isEmpty {
            // Chunk long text at UTF-8 safe boundaries (max 4096 bytes per event)
            // to prevent potential buffer issues in the Ghostty C/Zig layer.
            let segments = Self.chunkUTF8Safe(text, maxBytes: 4096)
            for segment in segments {
                // Send text as key event
                var handled = false
                segment.withCString { ptr in
                    var keyEvent = ghostty_input_key_s()
                    keyEvent.action = GHOSTTY_ACTION_PRESS
                    keyEvent.keycode = 0
                    keyEvent.mods = GHOSTTY_MODS_NONE
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.unshifted_codepoint = 0
                    keyEvent.text = ptr
                    keyEvent.composing = false
                    handled = ghostty_surface_key(surface, keyEvent)
                }
#if DEBUG
                if !handled {
                    dlog("ime.send.fail reason=key_not_handled segment=\(segment.prefix(20)) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
                }
#endif
                // Send matching RELEASE — TUI apps may track key state
                var releaseEvent = ghostty_input_key_s()
                releaseEvent.action = GHOSTTY_ACTION_RELEASE
                releaseEvent.keycode = 0
                releaseEvent.mods = GHOSTTY_MODS_NONE
                releaseEvent.consumed_mods = GHOSTTY_MODS_NONE
                releaseEvent.unshifted_codepoint = 0
                releaseEvent.text = nil
                releaseEvent.composing = false
                _ = ghostty_surface_key(surface, releaseEvent)
            }
        }
        // Send Enter to execute
        if withReturn {
            var returnDelivered = sendReturnKey(to: surface)
            if !returnDelivered {
                // Retry Return key delivery with small delays
                let retryDelaysUs: [useconds_t] = [10_000, 30_000, 150_000]
                for (i, delayUs) in retryDelaysUs.enumerated() {
                    usleep(delayUs)
                    returnDelivered = sendReturnKey(to: surface)
                    #if DEBUG
                    dlog("[sendIMEText] Return retry \(i + 1)/\(retryDelaysUs.count) handled=\(returnDelivered) surface=\(terminalSurface?.id.uuidString.prefix(8) ?? "nil")")
                    #endif
                    if returnDelivered { break }
                }
                if !returnDelivered {
                    #if DEBUG
                    dlog("[sendIMEText] FAIL: Return not delivered after all retries surface=\(terminalSurface?.id.uuidString.prefix(8) ?? "nil")")
                    #endif
                    return false
                }
            }
        }
        return true
    }

    /// Split a string into chunks where each chunk fits within `maxBytes` of UTF-8,
    /// never splitting in the middle of a character.
    private static func chunkUTF8Safe(_ text: String, maxBytes: Int) -> [String] {
        guard text.utf8.count > maxBytes else { return [text] }
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        for char in text {
            let charBytes = char.utf8.count
            if currentBytes + charBytes > maxBytes {
                chunks.append(current)
                current = String(char)
                currentBytes = charBytes
            } else {
                current.append(char)
                currentBytes += charBytes
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Intentionally empty - prevents system beep on unhandled key commands
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        // When the IME input bar is active, allow Cmd+C to copy terminal selection
        // even though IMETextView is the first responder. The mouse drag creates a
        // ghostty selection, but the first-responder guard below would block copy.
        if let imeTextView = enclosingSurfaceScrollView?.findIMETextView() {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 8 && flags == .command
                && imeTextView.selectedRange().length == 0,
               let surface = surface, ghostty_surface_has_selection(surface) {
                copy(nil)
                return true
            }
        }

        guard let fr = window?.firstResponder as? NSView,
              fr === self || fr.isDescendant(of: self) else { return false }

        // When the IME input bar is active, redirect focus there.
        // Let Cmd+Shift+I (keyCode 34) pass through so the menu can toggle it off.
        if let imeTextView = enclosingSurfaceScrollView?.findIMETextView() {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmdShiftI = event.keyCode == 34
                && flags.contains(.command)
                && flags.contains(.shift)
            if !isCmdShiftI {
                if window?.firstResponder !== imeTextView {
                    window?.makeFirstResponder(imeTextView)
                }
                return false
            }
        }

        guard let surface = ensureSurfaceReadyForInput() else { return false }

        // If the IME is composing (marked text present), don't intercept key
        // events for bindings — let them flow through to keyDown so the input
        // method can process them normally.
        if hasMarkedText() {
            return false
        }

#if DEBUG
        recordKeyLatency(path: "performKeyEquivalent", event: event)
#endif

#if DEBUG
        termMeshWriteChildExitProbe(
            [
                "probePerformCharsHex": termMeshScalarHex(event.characters),
                "probePerformCharsIgnoringHex": termMeshScalarHex(event.charactersIgnoringModifiers),
                "probePerformKeyCode": String(event.keyCode),
                "probePerformModsRaw": String(event.modifierFlags.rawValue),
                "probePerformSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probePerformKeyEquivalentCount": 1]
        )
#endif

        // Check if this event matches a Ghostty keybinding.
        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = event.characters ?? ""
            var flags = ghostty_binding_flags_e(0)
            let isBinding = text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            return isBinding ? flags : nil
        }()

        if let bindingFlags {
            let isConsumed = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
            let isAll = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0
            let isPerformable = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0

            // If the binding is consumed and not meant for the menu, allow menu first.
            if isConsumed && !isAll && !isPerformable && keySequence.isEmpty && keyTables.isEmpty {
                if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                    return true
                }
            }

            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass Ctrl+Return through verbatim (prevent context menu equivalent).
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // Treat Ctrl+/ as Ctrl+_ to avoid the system beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events.
            if event.timestamp == 0 {
                return false
            }

            // Match AppKit key-equivalent routing for menu-style shortcuts (Command-modified).
            // Control-only terminal input (e.g. Ctrl+D) should not participate in redispatch;
            // it must flow through the normal keyDown path exactly once.
            if !event.modifierFlags.contains(.command) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        // When the IME input bar is active, redirect all key events to its text view
        // so the user can keep typing without manually clicking the IME bar.
        if let imeTextView = enclosingSurfaceScrollView?.findIMETextView() {
            if window?.firstResponder !== imeTextView {
                window?.makeFirstResponder(imeTextView)
            }
            imeTextView.keyDown(with: event)
            return
        }

        guard let surface = ensureSurfaceReadyForInput() else {
            super.keyDown(with: event)
            return
        }
#if DEBUG
        recordKeyLatency(path: "keyDown", event: event)
#endif

#if DEBUG
        termMeshWriteChildExitProbe(
            [
                "probeKeyDownCharsHex": termMeshScalarHex(event.characters),
                "probeKeyDownCharsIgnoringHex": termMeshScalarHex(event.charactersIgnoringModifiers),
                "probeKeyDownKeyCode": String(event.keyCode),
                "probeKeyDownModsRaw": String(event.modifierFlags.rawValue),
                "probeKeyDownSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeKeyDownCount": 1]
        )
#endif

        // Fast path for control-modified terminal input (for example Ctrl+D).
        //
        // These keys are terminal control input, not text composition, so we bypass
        // AppKit text interpretation and send a single deterministic Ghostty key event.
        // This avoids intermittent drops after rapid split close/reparent transitions.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ctrl+Shift+C → Stop all agents (works with or without IME bar).
        // Must be checked before the Ctrl fast path which would send it to the
        // current terminal only.
        if flags.contains(.control) && flags.contains(.shift)
            && event.keyCode == 0x08 /* kVK_ANSI_C */
            && !flags.contains(.command) {
            NotificationCenter.default.post(name: .termMeshStopAllAgents, object: nil)
            return
        }

        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) {
            // Skip re-focus for paused agent surfaces to avoid restarting their CVDisplayLink.
            if terminalSurface?.renderingPaused != true {
                ghostty_surface_set_focus(surface, true)
            }
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

            // Don't send text for Ctrl key combos — the keycode + mods + unshifted_codepoint
            // are sufficient for Ghostty's KeyEncoder. Sending text causes double-encoding
            // that leaks raw CSI u sequences (e.g. "9;5u") as visible text.
            keyEvent.text = nil
            let handled = ghostty_surface_key(surface, keyEvent)
#if DEBUG
            dlog(
                "key.ctrl path=ghostty surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "handled=\(handled ? 1 : 0) keyCode=\(event.keyCode) chars=\(termMeshScalarHex(event.characters)) " +
                "ign=\(termMeshScalarHex(event.charactersIgnoringModifiers)) mods=\(event.modifierFlags.rawValue)"
            )
#endif
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Track whether we had marked text (IME preedit) before this event,
        // so we can detect when composition ends.
        let markedTextBefore = markedText.length > 0

        // Let the input system handle the event (for IME, dead keys, etc.)
        interpretKeyEvents([translationEvent])

        // Sync the preedit state with Ghostty so it can render the IME
        // composition overlay (e.g. for Korean, Japanese, Chinese input).
        syncPreedit(clearIfNeeded: markedTextBefore)

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // We're composing if we have preedit (the obvious case). But we're also
        // composing if we don't have preedit and we had marked text before,
        // because this input probably just reset the preedit state. It shouldn't
        // be encoded. Example: Japanese begin composing, then press backspace.
        // This should only cancel the composing state but not actually delete
        // the prior input characters (prior to the composing).
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        // Use accumulated text from insertText (for IME), or compute text for key
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            // Accumulated text comes from insertText (IME composition result).
            // These never have "composing" set to true because these are the
            // result of a composition.
            keyEvent.composing = false
            for text in accumulated {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            if let text = textForKeyEvent(translationEvent) {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }

        // Rendering is driven by Ghostty's wakeups/renderer.
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else {
            super.keyUp(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        return first >= 0x20
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    func updateKeySequence(_ action: ghostty_action_key_sequence_s) {
        if action.active {
            keySequence.append(action.trigger)
        } else {
            keySequence.removeAll()
        }
    }

    func updateKeyTable(_ action: ghostty_action_key_table_s) {
        switch action.tag {
        case GHOSTTY_KEY_TABLE_ACTIVATE:
            let namePtr = action.value.activate.name
            let nameLen = Int(action.value.activate.len)
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                if let name = String(data: data, encoding: .utf8) {
                    keyTables.append(name)
                }
            }
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        dlog("terminal.mouseDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        #endif
        if let imeTextView = enclosingSurfaceScrollView?.findIMETextView() {
            // IME input bar is active — keep focus on IMETextView, but ensure
            // the window is activated and this pane is recognized as focused.
            if let w = window {
                if !w.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    w.makeKeyAndOrderFront(nil)
                }
                w.makeFirstResponder(imeTextView)
            }
            // Trigger pane focus so bonsplit/tab highlights update even though
            // surfaceView isn't becoming first responder.
            onFocus?()
        } else {
            window?.makeFirstResponder(self)
        }
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(withTitle: "Trigger Flash", action: #selector(triggerFlash(_:)), keyEquivalent: "")
            flashItem.target = self
            menu.addItem(.separator())
        }
        if ghostty_surface_has_selection(surface) {
            let item = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            item.target = self
        }
        let pasteItem = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        return menu
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        lastScrollEventTime = CACurrentMediaTime()
        Self.focusLog("scrollWheel: surface=\(terminalSurface?.id.uuidString ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        // Track scroll state for lag detection
        let hasMomentum = event.momentumPhase != [] && event.momentumPhase != .mayBegin
        let momentumEnded = event.momentumPhase == .ended || event.momentumPhase == .cancelled
        configProvider.markScrollActivity(hasMomentum: hasMomentum, momentumEnded: momentumEnded)

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        terminalSurface = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    private func windowDidChangeScreen(_ notification: Notification) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow, window == object else { return }
        guard let screen = window.screen else { return }
        guard let surface = terminalSurface?.surface else { return }

        if let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

static func escapeDropForShell(_ value: String) -> String {
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    private func droppedContent(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls
                .map { Self.escapeDropForShell($0.path) }
                .joined(separator: " ")
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return Self.escapeDropForShell(rawURL)
        }

        if let str = pasteboard.string(forType: .string), !str.isEmpty {
            return str
        }

        return nil
    }

    @discardableResult
func insertDroppedPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard let content = droppedContent(from: pasteboard) else { return false }
        // Use the text/paste path (ghostty_surface_text) instead of the key event
        // path (ghostty_surface_key) so bracketed paste mode is triggered and the
        // insertion is instant, matching upstream Ghostty behaviour.
        terminalSurface?.sendText(content)
        return true
    }

#if DEBUG
    @discardableResult
func debugSimulateFileDrop(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        let pbName = NSPasteboard.Name("term-mesh.debug.drop.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pbName)
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
        return insertDroppedPasteboard(pasteboard)
    }

func debugRegisteredDropTypes() -> [String] {
        (registeredDraggedTypes ?? []).map(\.rawValue)
    }
#endif

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        dlog("terminal.draggingEntered surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        dlog("terminal.draggingUpdated surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        #if DEBUG
        dlog("terminal.fileDrop surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        #endif
        return insertDroppedPasteboard(sender.draggingPasteboard)
    }

    /// Walk the superview chain to find the enclosing `GhosttySurfaceScrollView`.
    var enclosingSurfaceScrollView: GhosttySurfaceScrollView? {
        var current: NSView? = superview
        while let view = current {
            if let scrollView = view as? GhosttySurfaceScrollView { return scrollView }
            current = view.superview
        }
        return nil
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let v = deviceDescription[key] as? UInt32 { return v }
        if let v = deviceDescription[key] as? Int { return UInt32(v) }
        if let v = deviceDescription[key] as? NSNumber { return v.uint32Value }
        return nil
    }
}


// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    @Environment(\.paneDropZone) var paneDropZone

    let terminalSurface: TerminalSurface
    var isActive: Bool = true
    var isVisibleInUI: Bool = true
    var portalZPriority: Int = 0
    var showsInactiveOverlay: Bool = false
    var showsUnreadNotificationRing: Bool = false
    var inactiveOverlayColor: NSColor = .clear
    var inactiveOverlayOpacity: Double = 0
    var searchState: TerminalSurface.SearchState? = nil
    var reattachToken: UInt64 = 0
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    private final class HostContainerView: NSView {
        var onDidMoveToWindow: (() -> Void)?
        var onGeometryChanged: (() -> Void)?
        private var hasScheduledGeometryCallback = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onDidMoveToWindow?()
            scheduleGeometryCallback()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleGeometryCallback()
        }

        override func layout() {
            super.layout()
            scheduleGeometryCallback()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            scheduleGeometryCallback()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleGeometryCallback()
        }

        /// Coalesce geometry callbacks to prevent re-entrant layout loops.
        /// Multiple layout/frame changes during a single AppKit layout pass
        /// are batched into one deferred synchronizeForAnchor call.
        private func scheduleGeometryCallback() {
            guard !hasScheduledGeometryCallback else { return }
            hasScheduledGeometryCallback = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledGeometryCallback = false
                self.onGeometryChanged?()
            }
        }
    }

    final class Coordinator {
        var attachGeneration: Int = 0
        // Track the latest desired state so attach retries can re-apply focus after re-parenting.
        var desiredIsActive: Bool = true
        var desiredIsVisibleInUI: Bool = true
        var desiredShowsUnreadNotificationRing: Bool = false
        var desiredPortalZPriority: Int = 0
        var lastBoundHostId: ObjectIdentifier?
        var lastPaneDropZone: DropZone?
        weak var hostedView: GhosttySurfaceScrollView?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView()
        container.wantsLayer = false
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hostedView = terminalSurface.hostedView
        let coordinator = context.coordinator
#if DEBUG
        let previousDesiredIsActive = coordinator.desiredIsActive
#endif
        let previousDesiredIsVisibleInUI = coordinator.desiredIsVisibleInUI
        let previousDesiredShowsUnreadNotificationRing = coordinator.desiredShowsUnreadNotificationRing
        let previousDesiredPortalZPriority = coordinator.desiredPortalZPriority
        coordinator.desiredIsActive = isActive
        coordinator.desiredIsVisibleInUI = isVisibleInUI
        coordinator.desiredShowsUnreadNotificationRing = showsUnreadNotificationRing
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.hostedView = hostedView
#if DEBUG
        if previousDesiredIsActive != isActive ||
            previousDesiredIsVisibleInUI != isVisibleInUI ||
            previousDesiredPortalZPriority != portalZPriority {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.swiftui.update id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(terminalSurface.id.uuidString.prefix(5)) visible=\(isVisibleInUI ? 1 : 0) " +
                    "active=\(isActive ? 1 : 0) z=\(portalZPriority)"
                )
            } else {
                dlog(
                    "ws.swiftui.update id=none surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0) z=\(portalZPriority)"
                )
            }
        }
#endif

        // Keep the surface lifecycle and handlers updated even if we defer re-parenting.
        hostedView.attachSurface(terminalSurface)
        hostedView.setVisibleInUI(isVisibleInUI)
        hostedView.setActive(isActive)
        hostedView.setInactiveOverlay(
            color: inactiveOverlayColor,
            opacity: CGFloat(inactiveOverlayOpacity),
            visible: showsInactiveOverlay
        )
        hostedView.setNotificationRing(visible: showsUnreadNotificationRing)
        hostedView.setSearchOverlay(searchState: searchState)
        hostedView.setFocusHandler { onFocus?(terminalSurface.id) }
        hostedView.setTriggerFlashHandler(onTriggerFlash)
        let forwardedDropZone = isVisibleInUI ? paneDropZone : nil
#if DEBUG
        if coordinator.lastPaneDropZone != paneDropZone {
            let oldZone = coordinator.lastPaneDropZone.map { String(describing: $0) } ?? "none"
            let newZone = paneDropZone.map { String(describing: $0) } ?? "none"
            dlog(
                "terminal.paneDropZone surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "old=\(oldZone) new=\(newZone) " +
                "active=\(isActive ? 1 : 0) visible=\(isVisibleInUI ? 1 : 0) " +
                "inWindow=\(hostedView.window != nil ? 1 : 0)"
            )
            coordinator.lastPaneDropZone = paneDropZone
        }
        if paneDropZone != nil, !isVisibleInUI {
            dlog(
                "terminal.paneDropZone.suppress surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "requested=\(String(describing: paneDropZone!)) visible=0 active=\(isActive ? 1 : 0)"
            )
        }
#endif
        hostedView.setDropZoneOverlay(zone: forwardedDropZone)

        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration

        if let host = nsView as? HostContainerView {
            host.onDidMoveToWindow = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard host.window != nil else { return }
                TerminalWindowPortalRegistry.bind(
                    hostedView: hostedView,
                    to: host,
                    visibleInUI: coordinator.desiredIsVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                coordinator.lastBoundHostId = ObjectIdentifier(host)
                hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                hostedView.setActive(coordinator.desiredIsActive)
                hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
            }
            host.onGeometryChanged = { [weak host, weak coordinator] in
                guard let host, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard coordinator.lastBoundHostId == ObjectIdentifier(host) else { return }
                TerminalWindowPortalRegistry.synchronizeForAnchor(host)
            }

            if host.window != nil {
                let hostId = ObjectIdentifier(host)
                let shouldBindNow =
                    coordinator.lastBoundHostId != hostId ||
                    hostedView.superview == nil ||
                    previousDesiredIsVisibleInUI != isVisibleInUI ||
                    previousDesiredShowsUnreadNotificationRing != showsUnreadNotificationRing ||
                    previousDesiredPortalZPriority != portalZPriority
                if shouldBindNow {
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority
                    )
                    coordinator.lastBoundHostId = hostId
                }
                TerminalWindowPortalRegistry.synchronizeForAnchor(host)
            } else {
                // Bind is deferred until host moves into a window. Update the
                // existing portal entry's visibleInUI now so that any portal sync
                // that runs before the deferred bind completes won't hide the view.
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: hostedView,
                    visibleInUI: coordinator.desiredIsVisibleInUI
                )
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        coordinator.desiredIsActive = false
        coordinator.desiredIsVisibleInUI = false
        coordinator.desiredShowsUnreadNotificationRing = false
        coordinator.desiredPortalZPriority = 0
        coordinator.lastBoundHostId = nil

        let hostedView = coordinator.hostedView
#if DEBUG
        if let hostedView {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.swiftui.dismantle id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            } else {
                dlog(
                    "ws.swiftui.dismantle id=none surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            }
        }
#endif

        if let host = nsView as? HostContainerView {
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
        }

        // SwiftUI can transiently dismantle/rebuild NSViewRepresentable instances during split
        // tree updates. Do not force visible/active false here; that causes avoidable blackouts
        // when the same hosted view is rebound moments later.
        hostedView?.setFocusHandler(nil)
        hostedView?.setTriggerFlashHandler(nil)
        hostedView?.setDropZoneOverlay(zone: nil)
        coordinator.hostedView = nil

        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
