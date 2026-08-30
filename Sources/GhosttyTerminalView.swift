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

enum TerminalAutoBlankRecoveryDecision: Equatable {
    case healthy
    case confirm
    case cooldown
    case rebuild
}

/// Device identity of a terminal special file. `FileAttributeKey.systemNumber`
/// is the containing filesystem's `st_dev`, not the terminal's `st_rdev`.
nonisolated func terminalDeviceNumber(at path: String) -> UInt32? {
    guard path.hasPrefix("/dev/") else { return nil }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else { return nil }
    return UInt32(truncatingIfNeeded: info.st_rdev)
}

/// Pure policy for the timing-sensitive blank-pane recovery state machine.
/// Keeping the decision separate from AppKit/renderer side effects lets tests
/// pin the healthy, confirmation, cooldown, and rebuild paths deterministically.
func terminalAutoBlankRecoveryDecision(
    hasProblem: Bool,
    confirmed: Bool,
    elapsedSinceLastRebuild: TimeInterval?,
    cooldown: TimeInterval = 30.0
) -> TerminalAutoBlankRecoveryDecision {
    guard hasProblem else { return .healthy }
    guard confirmed else { return .confirm }
    if let elapsedSinceLastRebuild, elapsedSinceLastRebuild < cooldown {
        return .cooldown
    }
    return .rebuild
}

#if os(macOS)
func termMeshShouldUseTransparentBackgroundWindow() -> Bool {
    let defaults = UserDefaults.standard
    let sidebarBlendMode = defaults.string(forKey: "sidebarBlendMode") ?? "withinWindow"
    let bgGlassEnabled = defaults.object(forKey: "bgGlassEnabled") as? Bool ?? true
    return sidebarBlendMode == "behindWindow" && bgGlassEnabled && !WindowGlassEffect.isAvailable
}

func terminalBackgroundLayerNeedsUpdate(
    currentColor: CGColor?,
    currentOpaque: Bool,
    targetColor: CGColor,
    targetOpaque: Bool
) -> Bool {
    guard let currentColor else { return true }
    return currentColor != targetColor || currentOpaque != targetOpaque
}

func terminalWindowBackgroundNeedsUpdate(
    currentColor: NSColor,
    currentOpaque: Bool,
    targetColor: NSColor,
    targetOpaque: Bool
) -> Bool {
    !currentColor.isEqual(targetColor) || currentOpaque != targetOpaque
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

func terminalSurfaceCreationRetryDelay(afterFailureCount failureCount: Int) -> TimeInterval {
    let delays: [TimeInterval] = [0.25, 1, 2, 5, 10, 30]
    let index = min(max(failureCount - 1, 0), delays.count - 1)
    return delays[index]
}

func terminalSurfaceShouldStartSynchronously(
    creationInProgress: Bool,
    backgroundStartQueued: Bool,
    now: TimeInterval,
    retryNotBefore: TimeInterval
) -> Bool {
    !creationInProgress && !backgroundStartQueued && now >= retryNotBefore
}

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

/// Token shared across async Return retry closures.
/// Once a retry succeeds (`delivered = true`), subsequent closures skip sending.
/// Safe because all closures run on MainActor (DispatchQueue.main.asyncAfter).
private class ReturnDeliveryToken { var delivered = false }
final class KeyDeliveryToken { var delivered = false }

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

    private(set) var attachGeneration: UInt64 = 0
    private(set) var surface: ghostty_surface_t? {
        didSet {
            guard oldValue != surface else { return }
            attachGeneration &+= 1
            #if DEBUG
            dlog("surface.attachGeneration panel=\(id.uuidString.prefix(8)) gen=\(attachGeneration)")
            #endif
        }
    }
    private weak var attachedView: GhosttyNSView?
    /// When true, setFocus(true) calls are ignored to keep CVDisplayLink suspended.
    /// Set by TeamOrchestrator.setAgentSurfaceFocus() when pausing/resuming agent rendering.
    var renderingPaused = false

    /// Whether the renderer's GPU resources (Metal swap chain / IOSurface, ~40MB) are
    /// currently allocated. Toggled via `setRendererRealized` to reclaim GPU memory for
    /// surfaces that have been invisible (e.g. background workspace) for a while.
    /// Starts true: a freshly created surface is realized.
    private var rendererRealized = true
    @MainActor var isRendererReadyForImmediateVisibility: Bool {
        surface != nil && rendererRealized
    }

    /// Kernel device identity of this surface's PTY. Adopted leaders cannot
    /// receive a new environment capability after their shell has started, so
    /// this gives the socket boundary a non-forgeable identity to compare with
    /// the connecting process's controlling TTY.
    @MainActor var controllingTTYDevice: UInt32? {
        guard let surface else { return nil }
        let value = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(value) }
        guard let ptr = value.ptr, value.len > 0 else { return nil }
        let raw = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let path = String(decoding: UnsafeBufferPointer(start: raw, count: Int(value.len)), as: UTF8.self)
        return terminalDeviceNumber(at: path)
    }
    /// Debounced unrealize work item, so transient reparent/workspace flaps don't
    /// thrash the swap chain (recreate cost) when a surface briefly goes invisible.
    private var rendererUnrealizeWork: DispatchWorkItem?
    /// Last requested renderer visibility. SwiftUI may re-apply the same workspace state
    /// many times; preserving this state prevents every update from restarting the debounce.
    private var rendererVisibilityRequested = true
    #if DEBUG
    private var rendererUnrealizeScheduleCount = 0
    #endif
    /// How long a surface must stay invisible before its GPU resources are released.
    private static let rendererUnrealizeDebounce: TimeInterval = 5.0
    /// Whether the terminal surface view is currently attached to a window.
    ///
    /// Use the hosted view rather than the inner surface view, since the surface can be
    /// temporarily unattached (surface not yet created / reparenting) even while the panel
    /// is already in the window.
    var isViewInWindow: Bool { hostedView.window != nil }
    /// Fired when this terminal's view lands in a window.
    ///
    /// A remote pane needs an edge here, not a sample. `TerminalPanelView`'s
    /// `onAppear` can run before `bindRemotePane` assigns `peerPaneSession`,
    /// in which case its optional chain starts nothing; `bindRemotePane`'s own
    /// start is skipped when the view has not reached a window yet. Either
    /// side can be last, so both must be able to arm the relay.
    var onDidEnterWindow: (() -> Void)?
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
    /// What the local pane's own layout last asked for, kept even when a
    /// viewer is currently winning, so the surface can return to it the moment
    /// the viewer detaches.
    private var localPixelSize: (w: UInt32, h: UInt32)?
    /// What an attached remote viewer asked for, nil when nobody is attached.
    private var remoteViewerPixelSize: (w: UInt32, h: UInt32)?
    /// Which side typed most recently, nil until either does. The min rule
    /// alone locks the PTY at the smaller party's size with nothing the party
    /// actually working in it can do — enlarging just re-loses the min. Whoever
    /// is typing is the one reading, so they get the grid.
    private var remoteViewerTypedLast: Bool?
    private var lastXScale: CGFloat = 0
    private var lastYScale: CGFloat = 0
    private var pendingTextQueue: [Data] = []
    private var pendingTextBytes: Int = 0
    private let maxPendingTextBytes = 1_048_576
    private var backgroundSurfaceStartQueued = false
    private var backgroundSurfaceStartToken: UUID?
    private var surfaceCreationInProgress = false
    /// A panel close is terminal. Once set, late SwiftUI/AppKit updates must
    /// not interpret `surface == nil` as permission to create another PTY.
    private var permanentlyClosed = false
    private var surfaceCreationFailureCount = 0
    private var surfaceCreationRetryNotBefore: TimeInterval = 0
    private var surfaceCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    /// Coordinates deferred ghostty_surface_free with active read leases.
    /// Created once per TerminalSurface; outlives the object when leases are held.
    let surfaceFreeCoordinator = SurfaceFreeCoordinator()
    /// True while the viewport sits far enough above the bottom that a
    /// scroll-to-bottom affordance is worth showing (see
    /// `GhosttySurfaceScrollView.scrollToBottomRowThreshold`).
    ///
    /// Deliberately a Bool rather than the raw `GhosttyScrollbar`: the scrollbar
    /// action arrives on every scroll tick with no throttling, and publishing the
    /// raw value would re-render the overlay on each one. Only assign when the
    /// value actually changes — see `handleScrollbarUpdate`.
    @Published var shouldShowScrollToBottom: Bool = false {
        didSet {
            guard oldValue != shouldShowScrollToBottom else { return }
            // Drive the overlay straight from here rather than through SwiftUI.
            // The button carries no state the view layer owns, so a round trip
            // through `updateNSView` would only add re-render churn on a signal
            // that fires on every scroll tick. `updateNSView` still re-applies
            // this (portal reattach), which is what repairs the mount.
            hostedView.setScrollToBottomOverlay(visible: shouldShowScrollToBottom)
        }
    }
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

    var hasMarkedTextForInput: Bool {
        surfaceView.markedText.length > 0
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

    func attachToView(_ view: GhosttyNSView, deferCreation: Bool = true) {
#if DEBUG
        dlog(
            "surface.attach surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque()) " +
            "attached=\(attachedView != nil ? 1 : 0) hasSurface=\(surface != nil ? 1 : 0) " +
            "inWindow=\(view.window != nil ? 1 : 0) defer=\(deferCreation ? 1 : 0)"
        )
#endif
        guard !permanentlyClosed else {
            #if DEBUG
            dlog("surface.attach.skip surface=\(id.uuidString.prefix(5)) reason=permanentlyClosed")
            #endif
            return
        }

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
                sentryBreadcrumb("surface.attach.defer", category: "terminal", data: [
                    "surface": id.uuidString,
                    "workspace": tabId.uuidString,
                    "reason": "noWindow",
                    "width": Double(view.bounds.width),
                    "height": Double(view.bounds.height)
                ])
                return
            }
            if deferCreation {
                requestBackgroundSurfaceStartIfNeeded(reason: "attachToWindow")
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard terminalSurfaceShouldStartSynchronously(
                creationInProgress: surfaceCreationInProgress,
                backgroundStartQueued: backgroundSurfaceStartQueued,
                now: now,
                retryNotBefore: surfaceCreationRetryNotBefore
            ) else {
                requestBackgroundSurfaceStartIfNeeded(reason: "attachBackoff")
                return
            }
            #if DEBUG
            dlog("surface.attach.create surface=\(id.uuidString.prefix(5))")
            #endif
            sentryBreadcrumb("surface.attach.create", category: "terminal", data: [
                "surface": id.uuidString,
                "workspace": tabId.uuidString,
                "width": Double(view.bounds.width),
                "height": Double(view.bounds.height),
                "windowCount": NSApp.windows.count,
                "deferred": false
            ])
            createSurface(for: view)
#if DEBUG
            dlog("surface.attach.create.done surface=\(id.uuidString.prefix(5)) hasSurface=\(surface != nil ? 1 : 0)")
#endif
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

    /// Quick, timeout-bounded reachability probe for a filesystem path.
    ///
    /// Runs `access(path, F_OK)` on a background queue so the stall of a
    /// broken mount (or similar stuck VFS path) cannot block the main
    /// thread for more than `timeout` seconds. Used by `createSurface` to
    /// avoid feeding a stale working directory to ghostty, whose internal
    /// `openat` on that path would otherwise block main and trigger the
    /// App Hanging watchdog (Sentry TERM-MESH-17).
    ///
    /// Returns `true` only when the probe completes within the timeout
    /// AND reports the path as accessible. Timeout and errors both map to
    /// `false`, causing the caller to fall back to a default directory.
    private static func probeDirectoryReachable(_ path: String, timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var accessible = false
        DispatchQueue.global(qos: .userInitiated).async {
            accessible = (access(path, F_OK) == 0)
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .success && accessible
    }

    private func createSurface(for view: GhosttyNSView) {
        guard !permanentlyClosed else { return }
        guard !surfaceCreationInProgress else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now >= surfaceCreationRetryNotBefore else {
            requestBackgroundSurfaceStartIfNeeded(reason: "creationBackoff")
            return
        }

        backgroundSurfaceStartToken = nil
        backgroundSurfaceStartQueued = false
        surfaceCreationInProgress = true
        defer {
            surfaceCreationInProgress = false
            if surface != nil {
                surfaceCreationFailureCount = 0
                surfaceCreationRetryNotBefore = 0
            } else {
                surfaceCreationFailureCount += 1
                surfaceCreationRetryNotBefore = ProcessInfo.processInfo.systemUptime
                    + terminalSurfaceCreationRetryDelay(afterFailureCount: surfaceCreationFailureCount)
                if view.window != nil {
                    requestBackgroundSurfaceStartIfNeeded(reason: "creationRetry")
                }
            }
        }

        let createSurfaceStartedAt = CACurrentMediaTime()
        #if DEBUG
        let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap { String(cString: $0) } ?? "(unset)"
        let terminfo = getenv("TERMINFO").flatMap { String(cString: $0) } ?? "(unset)"
        let xdg = getenv("XDG_DATA_DIRS").flatMap { String(cString: $0) } ?? "(unset)"
        let manpath = getenv("MANPATH").flatMap { String(cString: $0) } ?? "(unset)"
        Self.surfaceLog("createSurface start surface=\(id.uuidString) tab=\(tabId.uuidString) bounds=\(view.bounds) inWindow=\(view.window != nil) resources=\(resourcesDir) terminfo=\(terminfo) xdg=\(xdg) manpath=\(manpath)")
        #endif
        sentryBreadcrumb("surface.create.start", category: "terminal", data: [
            "surface": id.uuidString,
            "workspace": tabId.uuidString,
            "context": termMeshSurfaceContextName(surfaceContext),
            "width": Double(view.bounds.width),
            "height": Double(view.bounds.height),
            "inWindow": view.window != nil
        ])

        guard let app = GhosttyApp.shared.app else {
            Logger.ui.error("Ghostty app not initialized")
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty app not initialized")
            #endif
            sentryBreadcrumb("surface.create.fail", category: "terminal", data: [
                "surface": id.uuidString,
                "workspace": tabId.uuidString,
                "reason": "ghosttyAppNil"
            ])
            return
        }

        let scaleFactors = scaleFactors(for: view)

        var surfaceConfig = configTemplate ?? ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        let displayID = (view.window?.screen ?? NSScreen.main)?.displayID ?? 0
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque(),
            display_id: displayID
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
        // A parent agent CLI exports its own conversation identity. Carrying
        // that into a fresh terminal makes `$rc on` expose the parent's JSONL
        // as if it belonged to the child pane. Only the CLI running inside the
        // pane may add its session identity to tool subprocesses.
        env = Self.removingInheritedCLISessionIdentity(from: env)
        // P15: expose THIS instance's term-meshd daemon socket so `tm-agent watch
        // on/off/status` (which target the daemon's `watch.*` RPC) reach this app's
        // own daemon — tagged/isolated builds included — without the user setting
        // TERMMESH_DAEMON_UNIX_PATH by hand. Per-instance by construction: each app
        // injects its own daemon path, so a tagged pane never routes to the live
        // daemon. Non-watch tm-agent commands are unaffected (detect_socket keys off
        // TERMMESH_SOCKET, not this var).
        let daemonSocketPath = TermMeshDaemon.shared.socketPath
        env["TERMMESH_DAEMON_UNIX_PATH"] = daemonSocketPath
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

        func appendEnvPath(_ key: String, path: String, defaultValue: String? = nil) {
            guard !path.isEmpty else { return }
            var current = env[key]
                ?? getenv(key).map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment[key]
                ?? ""
            if current.isEmpty, let defaultValue {
                current = defaultValue
            }
            if current.split(separator: ":").contains(Substring(path)) {
                env[key] = current
                return
            }
            env[key] = current.isEmpty ? path : "\(current):\(path)"
        }

        if let resourceURL = Bundle.main.resourceURL {
            let resourcePath = resourceURL.path
            let overlayTerminfo = resourceURL.appendingPathComponent("terminfo-overlay").path
            let bundledGhostty = resourceURL.appendingPathComponent("ghostty").path
            // Where this app's own CLIs live (tm-agent, term-mesh, term-meshd).
            // PATH may still resolve `tm-agent` to an older release from brew,
            // and a tagged development app lives outside /Applications, so
            // skills such as /rc run "$TERMMESH_APP_BIN/tm-agent" first.
            env["TERMMESH_APP_BIN"] = resourceURL.appendingPathComponent("bin").path
            let resolvedTerminfo = (env["TERMINFO"]?.isEmpty == false ? env["TERMINFO"] : nil)
                ?? getenv("TERMINFO").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["TERMINFO"]
                ?? (FileManager.default.fileExists(atPath: overlayTerminfo) ? overlayTerminfo : nil)

            if let resolvedTerminfo, !resolvedTerminfo.isEmpty {
                env["TERMINFO"] = resolvedTerminfo
                appendEnvPath(
                    "XDG_DATA_DIRS",
                    path: URL(fileURLWithPath: resolvedTerminfo).deletingLastPathComponent().path,
                    defaultValue: "/usr/local/share:/usr/share"
                )
            } else {
                appendEnvPath("XDG_DATA_DIRS", path: resourcePath, defaultValue: "/usr/local/share:/usr/share")
            }

            if env["GHOSTTY_RESOURCES_DIR"]?.isEmpty != false,
               getenv("GHOSTTY_RESOURCES_DIR") == nil,
               FileManager.default.fileExists(atPath: bundledGhostty) {
                env["GHOSTTY_RESOURCES_DIR"] = bundledGhostty
            }
            appendEnvPath("MANPATH", path: resourceURL.appendingPathComponent("man").path)
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

        var ghosttySurfaceNewMs: Double?
        let createSurface = { [self] in
            let ghosttySurfaceNewStartedAt = CACurrentMediaTime()
            defer {
                ghosttySurfaceNewMs = (CACurrentMediaTime() - ghosttySurfaceNewStartedAt) * 1000.0
            }
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
            if additionalEnvironment["TERMMESH_PEER_RELAY_SOCKET"] != nil {
                return command
            }
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

        // Drop the working directory if it doesn't respond to a quick reachability
        // probe. A stale path (unmounted network share, spun-down external drive,
        // broken SSHFS, …) will otherwise cause ghostty's internal openat on this
        // path to block the main thread, tripping the App Hanging watchdog
        // (Sentry TERM-MESH-17). Passing nil lets ghostty fall back to HOME.
        let usableWorkingDirectory: String? = {
            guard let dir = workingDirectory, !dir.isEmpty else { return nil }
            return Self.probeDirectoryReachable(dir, timeout: 0.3) ? dir : nil
        }()
        #if DEBUG
        if let dir = workingDirectory, !dir.isEmpty, usableWorkingDirectory == nil {
            Self.surfaceLog("createSurface workingDirectory unreachable, falling back to HOME surface=\(id.uuidString) dir=\(dir)")
        }
        #endif

        if let usableWorkingDirectory {
            if let resolvedCommand {
                usableWorkingDirectory.withCString { cWorkingDir in
                    resolvedCommand.withCString { cCmd in
                        surfaceConfig.working_directory = cWorkingDir
                        surfaceConfig.command = cCmd
                        createSurface()
                    }
                }
            } else {
                usableWorkingDirectory.withCString { cWorkingDir in
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
            sentryBreadcrumb("surface.create.fail", category: "terminal", data: [
                "surface": id.uuidString,
                "workspace": tabId.uuidString,
                "reason": "surfaceNil",
                "totalMs": (CACurrentMediaTime() - createSurfaceStartedAt) * 1000.0,
                "ghosttySurfaceNewMs": ghosttySurfaceNewMs ?? -1.0,
                "hasWorkingDirectory": usableWorkingDirectory != nil,
                "hasCommand": resolvedCommand != nil,
                "envCount": env.count
            ])
            return
        }
        guard let createdSurface = surface else { return }
        // A newly-created Ghostty surface always starts with a realized renderer. If the
        // owning workspace was hidden while creation/retry completed, apply that state now;
        // the visibility setter will arrange the delayed GPU release without extending it
        // on later identical SwiftUI updates.
        rendererRealized = true
        let visibleInUI = surfaceView.isVisibleInUI
        ghostty_surface_set_occlusion(createdSurface, visibleInUI)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.surface == createdSurface else { return }
            self.setSurfaceVisibleForRenderer(self.surfaceView.isVisibleInUI)
        }

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

        // Register the PTY data callback so we can detect when the child
        // process (claude / codex / shell) starts writing output — that's
        // our cleanest signal that its stdin reader is alive. Used by
        // processPaste to gate cold-start pastes. The callback fires on
        // ghostty's IO thread and must be non-blocking; we only flip a
        // single Bool flag (the surface ref is retained for the lifetime
        // of this surface, so a raw unmanaged pointer is safe).
        let surfaceRef = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_pty_data_callback(createdSurface, { userdata, _, len in
            guard let userdata else { return }
            let surface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
            surface.recordPtyOutput(byteCount: Int(len))
        }, surfaceRef)

#if DEBUG
        let runtimeFontText = termMeshCurrentSurfaceFontSizePoints(createdSurface).map {
            String(format: "%.2f", $0)
        } ?? "nil"
        dlog(
            "zoom.create.done surface=\(id.uuidString.prefix(5)) context=\(termMeshSurfaceContextName(surfaceContext)) " +
            "runtimeFont=\(runtimeFontText)"
        )
#endif
        sentryBreadcrumb("surface.create.done", category: "terminal", data: [
            "surface": id.uuidString,
            "workspace": tabId.uuidString,
            "context": termMeshSurfaceContextName(surfaceContext),
            "totalMs": (CACurrentMediaTime() - createSurfaceStartedAt) * 1000.0,
            "ghosttySurfaceNewMs": ghosttySurfaceNewMs ?? -1.0,
            "hasWorkingDirectory": usableWorkingDirectory != nil,
            "hasCommand": resolvedCommand != nil,
            "envCount": env.count,
            "widthPx": Int(lastPixelWidth),
            "heightPx": Int(lastPixelHeight)
        ])
    }

    nonisolated static func removingInheritedCLISessionIdentity(
        from environment: [String: String]
    ) -> [String: String] {
        var environment = environment
        for key in ["CODEX_SESSION_ID", "CODEX_THREAD_ID", "CLAUDE_CODE_SESSION_ID"] {
            // Omitting the key lets Ghostty inherit it again from the app.
            environment[key] = ""
        }
        return environment
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

        localPixelSize = (wpx, hpx)
        let resolved = resolvedPixelSize()
        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = resolved.w != lastPixelWidth || resolved.h != lastPixelHeight

        #if DEBUG
        Self.sizeLog("updateSize-call surface=\(id.uuidString.prefix(8)) size=\(resolved.w)x\(resolved.h) prev=\(lastPixelWidth)x\(lastPixelHeight) changed=\((scaleChanged || sizeChanged) ? 1 : 0)")
        #endif

        guard scaleChanged || sizeChanged else { return }

        #if DEBUG
        if sizeChanged {
            let win = attachedView?.window != nil ? "1" : "0"
            Self.sizeLog("updateSize surface=\(id.uuidString.prefix(8)) size=\(resolved.w)x\(resolved.h) prev=\(lastPixelWidth)x\(lastPixelHeight) win=\(win)")
        }
        #endif

        if scaleChanged {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if sizeChanged {
            applyResolvedSize(resolved, to: surface)
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
    }

    /// Adopt the size a remote viewer asked for. Returns whether the surface
    /// actually changed, which the caller needs: a viewer only has to be sent
    /// a fresh screen when it did.
    ///
    /// Routed through here rather than calling `ghostty_surface_set_size`
    /// directly so the local pane's cache stays true. When the two paths each
    /// set the size behind the other's back, `updateSize` compares against a
    /// value the surface no longer has, concludes nothing changed, and the
    /// two views drift apart silently.
    @discardableResult
    func applyRemoteViewerPixelSize(width: UInt32, height: UInt32) -> Bool {
        guard let surface = surface, width > 0, height > 0 else { return false }
        remoteViewerPixelSize = (width, height)
        let resolved = resolvedPixelSize()
        guard resolved.w != lastPixelWidth || resolved.h != lastPixelHeight else { return false }
        #if DEBUG
        Self.sizeLog(
            "viewerSize surface=\(id.uuidString.prefix(8)) asked=\(width)x\(height) "
                + "resolved=\(resolved.w)x\(resolved.h) prev=\(lastPixelWidth)x\(lastPixelHeight) "
                + "localOnScreen=\(isLocallyOnScreen ? 1 : 0)"
        )
        #endif
        applyResolvedSize(resolved, to: surface)
        return true
    }

    /// Record that this pane's own keyboard produced input, and re-arbitrate.
    ///
    /// Called from the local key path rather than from every write to the PTY:
    /// a `tm-agent send` or a socket-driven paste is not somebody sitting in
    /// front of this pane, and treating it as one would hand the grid to a
    /// window nobody is reading.
    func noteLocalInput() { noteTypist(remote: false) }

    /// Record that an attached remote viewer produced input, and re-arbitrate.
    func noteRemoteInput() { noteTypist(remote: true) }

    /// Re-arbitrate the shared PTY size when the host pane enters or leaves
    /// the visible workspace. Visibility is one of `resolvedPixelSize`'s
    /// inputs, but changing it previously only toggled the renderer: the PTY
    /// kept the size chosen while the pane was hidden until another resize or
    /// keystroke happened to arrive. In particular, opening a locally-hosted
    /// workspace that was already visible through a relay left the host pane
    /// drawing a relay-sized grid into local bounds.
    ///
    /// A remote-input preference established while the local pane was hidden
    /// is stale once that pane becomes visible. Return to the neutral
    /// smaller-grid rule so both windows render a valid grid until either side
    /// produces fresh input.
    func localPaneVisibilityDidChange(becameVisible: Bool) {
        guard remoteViewerPixelSize != nil else { return }
        remoteViewerTypedLast = Self.remoteTypistPreference(
            remoteViewerTypedLast,
            afterLocalVisibilityChangeTo: becameVisible
        )
        guard let surface else { return }
        let resolved = resolvedPixelSize()
        guard resolved.w != lastPixelWidth || resolved.h != lastPixelHeight else { return }
        applyResolvedSize(resolved, to: surface)
    }

    static func remoteTypistPreference(
        _ current: Bool?,
        afterLocalVisibilityChangeTo visible: Bool
    ) -> Bool? {
        visible ? nil : current
    }

    private func noteTypist(remote: Bool) {
        // Called per keystroke, so it costs a comparison on all but the first
        // press after the other side was typing.
        guard remoteViewerTypedLast != remote else { return }
        remoteViewerTypedLast = remote
        guard let surface else { return }
        let resolved = resolvedPixelSize()
        guard resolved.w != lastPixelWidth || resolved.h != lastPixelHeight else { return }
        applyResolvedSize(resolved, to: surface)
    }

    /// The viewer is gone; the local pane gets its own size back.
    func clearRemoteViewerPixelSize() {
        guard remoteViewerPixelSize != nil else { return }
        remoteViewerPixelSize = nil
        // The arbitration this recorded is over with the viewer that caused it.
        remoteViewerTypedLast = nil
        guard let surface = surface else { return }
        let resolved = resolvedPixelSize()
        guard resolved.w != lastPixelWidth || resolved.h != lastPixelHeight else { return }
        applyResolvedSize(resolved, to: surface)
    }

    private func applyResolvedSize(_ size: (w: UInt32, h: UInt32), to surface: ghostty_surface_t) {
        ghostty_surface_set_size(surface, size.w, size.h)
        lastPixelWidth = size.w
        lastPixelHeight = size.h
    }

    /// One PTY, two windows onto it — so one size has to win.
    ///
    /// Whoever loses renders a grid that does not match what the shell drew
    /// into it: lines wrapped at a column that is no longer the edge, and a
    /// cursor the shell believes is somewhere the screen does not show. That
    /// last part is not cosmetic — it is where the next typed character
    /// lands, which is how a keystroke ends up in the middle of the prompt.
    ///
    /// So the smaller of the two wins while both are on screen. A short line
    /// never has to be re-wrapped to fit a narrow grid; it just leaves margin,
    /// and margin is the one failure mode here that loses nothing. When the
    /// local pane is not on screen there is nobody to shortchange, and the
    /// viewer gets exactly what it asked for.
    ///
    /// Except that min alone has no way out: the party that wants more room
    /// cannot get it by asking, because asking is what re-loses the min. A
    /// remote viewer maximized to full screen stayed pinned to the host pane's
    /// width forever. So once either side types, that side is the one being
    /// read and it takes the grid — the same rule the Rust peer host reaches
    /// through `SizeArbiter::note_input`. Until anyone types, min still holds.
    private func resolvedPixelSize() -> (w: UInt32, h: UInt32) {
        Self.resolvePixelSize(
            local: localPixelSize,
            remote: remoteViewerPixelSize,
            localOnScreen: isLocallyOnScreen,
            remoteTypedLast: remoteViewerTypedLast,
            fallback: (lastPixelWidth, lastPixelHeight)
        )
    }

    /// The rule itself, separated from the surface so it can be tested
    /// without one.
    static func resolvePixelSize(
        local: (w: UInt32, h: UInt32)?,
        remote: (w: UInt32, h: UInt32)?,
        localOnScreen: Bool,
        remoteTypedLast: Bool?,
        fallback: (w: UInt32, h: UInt32)
    ) -> (w: UInt32, h: UInt32) {
        guard let remote else { return local ?? fallback }
        guard let local, localOnScreen else { return remote }
        switch remoteTypedLast {
        case .some(true): return remote
        case .some(false): return local
        case .none: return (min(local.w, remote.w), min(local.h, remote.h))
        }
    }

    /// Whether a person could actually be looking at the local pane. A pane
    /// parked in an unselected workspace has a view but no window, and one
    /// hidden behind a portal swap is marked not-visible; neither is somebody
    /// whose reading the viewer has to accommodate.
    private var isLocallyOnScreen: Bool {
        guard let view = attachedView else { return false }
        return view.isVisibleInUI && view.window != nil
    }

    /// Force a full size recalculation and surface redraw.
    func forceRefresh() {
        guard let view = attachedView,
              view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }
        guard let surface = surface else { return }

        view.forceRefreshSurface()
        ghostty_surface_refresh(surface)
    }

    func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    func setFocus(_ focused: Bool) {
#if DEBUG
        dlog("surface.setFocus paused=\(renderingPaused) focused=\(focused)")
#endif
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
            Task { @MainActor [weak self] in
                self?.scheduleAutoBlankRecovery(reason: "focus")
            }
        }
    }

    func setOcclusion(_ visible: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// Release or recreate the renderer's GPU resources (Metal swap chain / IOSurface,
    /// ~40MB) without freeing the surface. libghostty requires strict realize/unrealize
    /// alternation (displayRealized asserts the swap chain was previously deinited), so
    /// redundant calls are dropped here. Safe to call after the surface is freed (no-op).
    @MainActor func setRendererRealized(_ realized: Bool) {
        guard let surface = surface else { return }
        guard realized != rendererRealized else { return }  // enforce alternation
        rendererRealized = realized
        ghostty_surface_set_renderer_realized(surface, realized)
        #if DEBUG
        dlog("surface.renderer.realized=\(realized) surface=\(id.uuidString.prefix(8))")
        #endif
    }

    /// Hard recovery for a blank/stuck pane: force one unrealize/realize transaction on
    /// the renderer thread, rebuilding the Metal swap chain / IOSurface without freeing
    /// the surface, PTY, terminal state, or scrollback. Unlike `forceRefresh()` (a size
    /// recalc + redraw poke) this replaces the render target itself, so it also recovers
    /// panes whose backing IOSurface went stale after display/reparent churn. Skipped
    /// while the renderer is intentionally unrealized (hidden workspace) — rebuilding
    /// would realize GPU resources the visibility controller has released.
    @discardableResult
    @MainActor func rebuildRenderer() -> Bool {
        guard let surface = surface else { return false }
        guard rendererRealized else { return false }
        let accepted = ghostty_surface_rebuild_renderer(surface)
        #if DEBUG
        dlog("surface.renderer.rebuild accepted=\(accepted) surface=\(id.uuidString.prefix(8))")
        #endif
        return accepted
    }

    // MARK: - Automatic blank-pane recovery

    /// Structural render-backing problems that may trigger an automatic renderer
    /// rebuild. Pixel content is deliberately ignored: a cleared terminal is
    /// legitimately uniform, so only a broken render target qualifies.
    enum RenderBackingProblem: String {
        /// Visible, realized surface whose layer has no contents at all.
        case noContents = "no_contents"
        /// Layer contents is an IOSurface whose pixel size is far from the
        /// layer's expected backing size (stale target after display churn).
        case staleSize = "stale_size"
    }

    private static let autoBlankCheckDelay: TimeInterval = 1.5
    private static let autoBlankConfirmDelay: TimeInterval = 0.6
    private static let autoBlankCooldown: TimeInterval = 30.0
    /// Divergence allowed between the IOSurface and the layer's expected pixel
    /// size before it counts as stale — generous so a trailing live-resize
    /// frame never qualifies.
    private static let autoBlankSizeTolerancePx = 64

    private var autoBlankCheckWork: DispatchWorkItem?
    private var lastAutoBlankRebuildAt: Date?
    private(set) var autoBlankChecksRan = 0
    private(set) var autoBlankRebuilds = 0
    private(set) var lastAutoBlankReason: String?

    /// Escape hatch: `defaults write <bundle> disableAutoBlankRecovery -bool YES`.
    private var autoBlankRecoveryDisabled: Bool {
        UserDefaults.standard.bool(forKey: "disableAutoBlankRecovery")
    }

    /// Inspect the attached view's layer for a structurally broken render
    /// target. Returns nil when healthy or indeterminate (detached, zero-size,
    /// snapshot-mitigation contents) — indeterminate must never trigger.
    @MainActor private func renderBackingProblem() -> RenderBackingProblem? {
        guard let view = attachedView,
              view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0,
              let layer = view.layer else { return nil }
        guard let contents = layer.contents else { return .noContents }
        let cf = contents as CFTypeRef
        // During blank-flash mitigation contents can be a CGImage snapshot —
        // that machinery owns the layer then; treat as healthy.
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else { return nil }
        let ioSurface = contents as! IOSurfaceRef
        let width = Int(IOSurfaceGetWidth(ioSurface))
        let height = Int(IOSurfaceGetHeight(ioSurface))
        if width <= 0 || height <= 0 { return .noContents }
        let scale = max(1.0, layer.contentsScale)
        let expectedWidth = Int((view.bounds.width * scale).rounded())
        let expectedHeight = Int((view.bounds.height * scale).rounded())
        if abs(width - expectedWidth) > Self.autoBlankSizeTolerancePx ||
            abs(height - expectedHeight) > Self.autoBlankSizeTolerancePx {
            return .staleSize
        }
        return nil
    }

    /// Schedule a structural blank check shortly after the surface (re)becomes
    /// visible or focused — the windows where stuck render targets historically
    /// appear. A detection is double-confirmed and rate-limited before acting.
    @MainActor func scheduleAutoBlankRecovery(reason: String) {
        guard !autoBlankRecoveryDisabled else { return }
        autoBlankCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoBlankCheckWork = nil
            self.runAutoBlankCheck(trigger: reason, confirmed: false)
        }
        autoBlankCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoBlankCheckDelay, execute: work)
    }

    @MainActor func cancelAutoBlankRecovery() {
        autoBlankCheckWork?.cancel()
        autoBlankCheckWork = nil
    }

    @MainActor private func runAutoBlankCheck(trigger: String, confirmed: Bool) {
        guard surface != nil, rendererRealized, rendererVisibilityRequested,
              !renderingPaused else { return }
        if !confirmed { autoBlankChecksRan += 1 }
        let problem = renderBackingProblem()
        let elapsedSinceLastRebuild = lastAutoBlankRebuildAt.map { Date().timeIntervalSince($0) }
        switch terminalAutoBlankRecoveryDecision(
            hasProblem: problem != nil,
            confirmed: confirmed,
            elapsedSinceLastRebuild: elapsedSinceLastRebuild,
            cooldown: Self.autoBlankCooldown
        ) {
        case .healthy:
            return
        case .confirm:
            // Double-confirm: transient states (first frame not yet presented,
            // live resize trailing) must not trigger a GPU rebuild.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.autoBlankCheckWork = nil
                self.runAutoBlankCheck(trigger: trigger, confirmed: true)
            }
            autoBlankCheckWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoBlankConfirmDelay, execute: work)
            return
        case .cooldown:
            #if DEBUG
            dlog("surface.renderer.autoRebuild.skip cooldown problem=\(problem?.rawValue ?? "unknown") surface=\(id.uuidString.prefix(8))")
            #endif
            return
        case .rebuild:
            guard let problem else { return }
            performAutoBlankRebuild(problem: problem.rawValue, trigger: trigger)
        }
    }

    /// Act path shared by the detector and the debug simulate probe.
    @MainActor @discardableResult
    func performAutoBlankRebuild(problem: String, trigger: String) -> Bool {
        lastAutoBlankRebuildAt = Date()
        autoBlankRebuilds += 1
        lastAutoBlankReason = "\(problem)/\(trigger)"
        #if DEBUG
        dlog("surface.renderer.autoRebuild problem=\(problem) trigger=\(trigger) surface=\(id.uuidString.prefix(8))")
        #endif
        let accepted = rebuildRenderer()
        if accepted { forceRefresh() }
        return accepted
    }

    @MainActor func autoBlankRecoveryState() -> (checks: Int, rebuilds: Int, lastReason: String?, pending: Bool, currentProblem: String?) {
        (autoBlankChecksRan, autoBlankRebuilds, lastAutoBlankReason, autoBlankCheckWork != nil,
         renderBackingProblem()?.rawValue)
    }

    #if DEBUG
    /// Fault injection for e2e: unrealize the renderer through the REAL C-API
    /// teardown path while deliberately leaving the `rendererRealized` mirror
    /// at true — reproducing the "renderer released its GPU resources but the
    /// UI believes the pane is live" blank-pane failure mode that automatic
    /// recovery exists to fix. Debug builds only; never call outside tests.
    @MainActor func debugInjectRendererUnrealize() -> Bool {
        guard let surface = surface, rendererRealized else { return false }
        _ = ghostty_surface_set_renderer_realized(surface, false)
        dlog("surface.renderer.debugInjectUnrealize surface=\(id.uuidString.prefix(8))")
        return true
    }
    #endif

    /// Drive renderer GPU realization from UI visibility (workspace selection). A surface
    /// that becomes visible realizes immediately so it can draw; one that becomes invisible
    /// unrealizes only after `rendererUnrealizeDebounce` of sustained invisibility, so brief
    /// reparent/workspace flaps don't churn the swap chain.
    @MainActor func setSurfaceVisibleForRenderer(_ visible: Bool) {
        rendererVisibilityRequested = visible
        if visible {
            rendererUnrealizeWork?.cancel()
            rendererUnrealizeWork = nil
            setRendererRealized(true)
            scheduleAutoBlankRecovery(reason: "visible")
        } else {
            cancelAutoBlankRecovery()
            // Do not restart the five-second countdown for repeated hidden-state updates.
            // A nil-surface timer may have elapsed before a delayed creation, so schedule
            // again whenever the renderer is realized and no pending release remains.
            guard rendererRealized, rendererUnrealizeWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.rendererUnrealizeWork = nil
                guard !self.rendererVisibilityRequested else { return }
                self.setRendererRealized(false)
            }
            rendererUnrealizeWork = work
            #if DEBUG
            rendererUnrealizeScheduleCount += 1
            #endif
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.rendererUnrealizeDebounce,
                execute: work
            )
        }
    }

    #if DEBUG
    @MainActor func debugRendererVisibilityState() -> (
        requested: Bool,
        realized: Bool,
        unrealizePending: Bool,
        unrealizeScheduleCount: Int
    ) {
        (rendererVisibilityRequested, rendererRealized,
         rendererUnrealizeWork != nil, rendererUnrealizeScheduleCount)
    }
    #endif

    func needsConfirmClose() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    @MainActor func closeGhosttySurface() {
        permanentlyClosed = true
        // Invalidate creation work queued while the panel was still mounted.
        // The deferred closure also checks `permanentlyClosed`; clearing the
        // token makes cancellation explicit and prevents stale retries.
        backgroundSurfaceStartToken = nil
        backgroundSurfaceStartQueued = false
        releaseGhosttySurfaceAsync(reason: "panelClose")
    }

    // MARK: - Surface read lease API (Phase 1 infrastructure)

    /// Obtain a scoped read-access token for the underlying surface pointer.
    ///
    /// Must be called on the MainActor. Returns nil if the surface is absent or
    /// is already being torn down (releaseGhosttySurfaceAsync in flight).
    /// The caller must call lease.release() when done; deinit is a safety-net.
    @MainActor
    func beginReadLease() -> SurfaceReadLease? {
        guard let surf = surface else { return nil }
        surfaceFreeCoordinator.beginLease()
        return SurfaceReadLease(
            surface: surf,
            generation: attachGeneration,
            coordinator: surfaceFreeCoordinator
        )
    }

    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        guard let surface = surface else {
            enqueuePendingText(data)
            return
        }
        writeTextData(data, to: surface)
    }

    /// Paste a local Shelf image into this terminal. Remote panes use the same
    /// one-shot transfer implementation as a normal Ghostty clipboard image;
    /// text and local images remain on the fast, bracketed-paste path.
    @MainActor
    func pasteShelfImage(at localPath: String) {
        guard FileManager.default.fileExists(atPath: localPath) else { return }
        guard let callbackContext = surfaceCallbackContext?.takeUnretainedValue(),
              let target = RemotePasteTransfer.destination(for: callbackContext)
        else {
            sendText(localPath)
            return
        }

        hostedView.beginRemotePasteTransfer()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let remotePath = RemotePasteTransfer.send(localPath: localPath, to: target) ?? localPath
            DispatchQueue.main.async {
                self?.hostedView.endRemotePasteTransfer()
                self?.sendText(remotePath)
            }
        }
    }

    /// Swap each Shelf attachment's local path for the copy that landed on the
    /// peer. Longest local path first, so an attachment path that prefixes
    /// another one cannot corrupt it mid-rewrite. Pure and nonisolated so the
    /// rewrite can run on the transfer queue.
    nonisolated static func rewritingShelfPaths(
        in text: String,
        with resolved: [(local: String, remote: String)]
    ) -> String {
        resolved
            .sorted { $0.local.count > $1.local.count }
            .reduce(text) { $0.replacingOccurrences(of: $1.local, with: $1.remote) }
    }

    /// IME submission keeps its surrounding text, but replaces every Shelf
    /// image's local path with its remote path after the transfers complete.
    @MainActor
    func sendShelfIMEText(_ text: String, replacing localPaths: [String]) {
        var seen = Set<String>()
        let transferable = localPaths.filter { path in
            seen.insert(path).inserted && FileManager.default.fileExists(atPath: path)
        }
        guard !transferable.isEmpty else {
            sendText(text)
            sendSurfaceKeyPress(keycode: 0x24, text: "\r")
            return
        }
        guard let callbackContext = surfaceCallbackContext?.takeUnretainedValue(),
              let target = RemotePasteTransfer.destination(for: callbackContext)
        else {
            sendText(text)
            sendSurfaceKeyPress(keycode: 0x24, text: "\r")
            return
        }

        hostedView.beginRemotePasteTransfer()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Every attachment has to be transferred, not just the first: a
            // path left pointing at the viewer's disk resolves to nothing on
            // the peer.
            let resolved = transferable.map { localPath in
                (local: localPath, remote: RemotePasteTransfer.send(localPath: localPath, to: target) ?? localPath)
            }
            let rewritten = Self.rewritingShelfPaths(in: text, with: resolved)
            DispatchQueue.main.async {
                self?.hostedView.endRemotePasteTransfer()
                self?.sendText(rewritten)
                self?.sendSurfaceKeyPress(keycode: 0x24, text: "\r")
            }
        }
    }

    /// Send text + Enter using the same approach as the socket `send_surface` command.
    /// This is the most reliable text delivery path — proven to work for team agent delivery.
    /// Control characters (\r, \n, \t, ESC, DEL) are sent as proper key events.
    /// All other characters are sent as text key events.
    @discardableResult
    func sendSocketStyleText(_ text: String, withReturn: Bool = true) -> Bool {
        guard let surface = surface else { return false }
        let payload = withReturn ? text + "\r" : text
        InputInjectionLog.record(site: "sendSocketStyleText", surface: id, text: payload)
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
        InputInjectionLog.recordKey(
            site: "sendSurfaceKeyPress", surface: id, keycode: keycode, text: text
        )
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
            InputInjectionLog.record(site: "sendInputText.flush", surface: id, text: buffered)
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

    // MARK: - Paste Queue

    enum PasteSendError: Error {
        case queueOverflow
        case surfaceUnavailable
        case returnRetryExhausted
    }

    private struct PendingPaste {
        let text: String
        let needsReturn: Bool
        let enqueuedAt: TimeInterval
        let completion: ((Result<Void, PasteSendError>) -> Void)?
        /// Number of times this paste has been deferred while waiting for
        /// the TUI's PTY output to confirm it's ready to read input. Capped
        /// inside processPaste so a never-output child doesn't stall forever.
        var tuiReadyDeferCount: Int = 0
    }
    private var pasteQueue: [PendingPaste] = []
    private var pasteInFlight: Bool = false
    private var pasteWatchdog: DispatchSourceTimer?
    private var pasteGeneration: Int = 0
    /// True once this surface has completed at least one paste. Used to detect
    /// the "cold start" case where ghostty's IO thread + the TUI's input
    /// pipeline aren't yet warm — first long paste needs extra drain time
    /// before we can safely fire the text_delivered ack.
    private var hasCompletedPaste: Bool = false
    /// Flipped to true the first time ghostty's pty_data_callback fires —
    /// i.e., the child process (claude / codex / shell) has written its
    /// first byte to the PTY. This is the cleanest available proxy for
    /// "the TUI's stdin reader loop is alive and ready to receive input."
    ///
    /// Used by processPaste to defer the first paste on a cold surface
    /// until the TUI has started outputting; without this gate the paste
    /// truncates at exactly the same byte position every run, because
    /// the TUI's input buffer hasn't been allocated yet.
    ///
    /// Atomic / lock-free read from main thread is safe because:
    /// - The callback runs on ghostty's IO reader thread
    /// - We only ever transition false → true (never back)
    /// - Bool reads/writes are atomic on supported architectures
    /// Marked @atomic via NSLock for strict ordering on weakly-ordered hosts.
    private var _hasReceivedPtyOutput: Bool = false
    private var _ptyOutputFirstAt: TimeInterval = 0
    private var _ptyOutputLastAt: TimeInterval = 0
    private var _ptyOutputTotalBytes: Int = 0
    private let ptyOutputLock = NSLock()
    var hasReceivedPtyOutput: Bool {
        ptyOutputLock.lock(); defer { ptyOutputLock.unlock() }
        return _hasReceivedPtyOutput
    }
    /// Time elapsed (in seconds) since the first pty_data_callback fire.
    /// Returns nil when no output has been observed yet.
    var ptyOutputAge: TimeInterval? {
        ptyOutputLock.lock(); defer { ptyOutputLock.unlock() }
        guard _hasReceivedPtyOutput else { return nil }
        return ProcessInfo.processInfo.systemUptime - _ptyOutputFirstAt
    }
    /// Total bytes observed via pty_data_callback so far. Used in combination
    /// with ptyOutputAge as the cold-start ready signal — Claude TUI streams
    /// its banner/prompt over several hundred bytes before its stdin reader
    /// loop activates, so a byte threshold catches the case where the timer
    /// alone is too generous.
    var ptyOutputBytes: Int {
        ptyOutputLock.lock(); defer { ptyOutputLock.unlock() }
        return _ptyOutputTotalBytes
    }
    /// How long the pty has been silent, in seconds. A TUI that has finished
    /// painting its startup screen and is sitting at its prompt stops writing;
    /// one still booting does not. Returns nil before any output.
    var ptyOutputQuietFor: TimeInterval? {
        ptyOutputLock.lock(); defer { ptyOutputLock.unlock() }
        guard _hasReceivedPtyOutput else { return nil }
        return ProcessInfo.processInfo.systemUptime - _ptyOutputLastAt
    }
    fileprivate func recordPtyOutput(byteCount: Int) {
        ptyOutputLock.lock(); defer { ptyOutputLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if !_hasReceivedPtyOutput {
            _hasReceivedPtyOutput = true
            _ptyOutputFirstAt = now
        }
        _ptyOutputLastAt = now
        _ptyOutputTotalBytes &+= byteCount
    }
    private static let maxPasteQueueDepth = 16

    /// Enqueues text+Return for serialized delivery via the paste queue,
    /// eliminating the paste→Return race. Returns true immediately (enqueue succeeds).
    @discardableResult
    func sendIMEText(_ text: String, withReturn: Bool = true) -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in _ = self?.sendIMEText(text, withReturn: withReturn) }
            return true
        }
        let normalized = text.contains("\n") ? text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            : text
        enqueuePaste(PendingPaste(text: normalized, needsReturn: withReturn,
                                  enqueuedAt: ProcessInfo.processInfo.systemUptime, completion: nil))
        drainPasteQueue()
        return true
    }

    /// Chat turns preserve embedded newlines. Existing terminal automation
    /// keeps its historical single-line normalization through `sendIMEText`.
    @discardableResult
    func sendIMETextPreservingNewlines(_ text: String, withReturn: Bool = true) -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                _ = self?.sendIMETextPreservingNewlines(text, withReturn: withReturn)
            }
            return true
        }
        let normalized = Self.normalizedChatTurn(text)
        enqueuePaste(PendingPaste(
            text: normalized, needsReturn: withReturn,
            enqueuedAt: ProcessInfo.processInfo.systemUptime, completion: nil
        ))
        drainPasteQueue()
        return true
    }

    nonisolated static func normalizedChatTurn(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Result-based variant for callers that want structured error feedback.
    /// Existing Bool-returning callers are unaffected; migrate to this in a follow-up PR.
    func sendIMETextResult(_ text: String, withReturn: Bool = true,
                           completion: @escaping (Result<Void, PasteSendError>) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.sendIMETextResult(text, withReturn: withReturn, completion: completion)
            }
            return
        }
        let normalized = text.contains("\n") ? text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            : text
        enqueuePaste(PendingPaste(text: normalized, needsReturn: withReturn,
                                  enqueuedAt: ProcessInfo.processInfo.systemUptime, completion: completion))
        drainPasteQueue()
    }

    private func enqueuePaste(_ p: PendingPaste) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.enqueuePaste(p) }
            return
        }
        if pasteQueue.count >= TerminalSurface.maxPasteQueueDepth {
            let dropped = pasteQueue.removeFirst()
            dropped.completion?(.failure(.queueOverflow))
            sentryBreadcrumb("paste.queue.overflow", category: "terminal", data: [
                "surface": id.uuidString,
                "dropped_text_prefix": String(dropped.text.prefix(40))
            ])
            #if DEBUG
            dlog("paste.drop reason=queue_overflow panel=\(id.uuidString.prefix(8)) gen=\(pasteGeneration) needsReturn=\(dropped.needsReturn) textLen=\(dropped.text.count)")
            dlog("paste.queue.overflow surface=\(id.uuidString.prefix(8)) dropped=\(dropped.text.prefix(40))")
            #endif
        }
        pasteQueue.append(p)
        #if DEBUG
        dlog("paste.enqueue panel=\(id.uuidString.prefix(8)) gen=\(pasteGeneration) needsReturn=\(p.needsReturn) textLen=\(p.text.count)")
        #endif
    }

    private func drainPasteQueue() {
        guard !pasteInFlight, !pasteQueue.isEmpty else { return }
        let next = pasteQueue.removeFirst()
        #if DEBUG
        dlog("paste.drain.start gen=\(pasteGeneration + 1)")
        #endif
        processPaste(next)
    }

    private func finalizePaste(result: Result<Void, PasteSendError>,
                               completion: ((Result<Void, PasteSendError>) -> Void)?) {
        cancelPasteWatchdog()
        pasteInFlight = false
        completion?(result)
        drainPasteQueue()
    }

    private func startPasteWatchdog(generation: Int,
                                    instructionLength: Int,
                                    completion: ((Result<Void, PasteSendError>) -> Void)?) {
        pasteWatchdog?.cancel()
        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + 8.0)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.pasteGeneration == generation else {
                #if DEBUG
                dlog("paste.drop reason=token_stale gen=\(generation) currentGen=\(self.pasteGeneration)")
                #endif
                return
            }
            self.pasteWatchdog = nil
            self.pasteGeneration &+= 1  // invalidate stale async retry callbacks
            self.pasteInFlight = false
            completion?(.failure(.returnRetryExhausted))
            self.drainPasteQueue()
            #if DEBUG
            dlog("paste.watchdog.fire surface=\(self.id.uuidString.prefix(8)) instruction_len=\(instructionLength)")
            dlog("[paste.watchdog] 8s timeout forced surface=\(self.id.uuidString.prefix(8))")
            #endif
        }
        src.resume()
        pasteWatchdog = src
    }

    private func cancelPasteWatchdog() {
        pasteWatchdog?.cancel()
        pasteWatchdog = nil
    }

    private func processPaste(_ p: PendingPaste) {
        guard let surface = surface else {
            #if DEBUG
            dlog("paste.drop reason=surface_nil panel=\(id.uuidString.prefix(8)) gen=\(pasteGeneration) needsReturn=\(p.needsReturn) textLen=\(p.text.count)")
            #endif
            pasteInFlight = false  // surface 복귀 후 drainPasteQueue가 즉시 재시도할 수 있도록 해제
            pasteQueue.insert(p, at: 0)
            return
        }

        // Cold-start gate: before the very first paste on this surface,
        // require ALL THREE conditions:
        //   1. pty_data_callback has fired (TUI started outputting)
        //   2. At least 1500 ms have elapsed since the first fire
        //   3. At least 500 bytes have been observed via the callback
        //
        // Why all three: empirically, neither (1) alone nor (1)+(2) caught
        // the case where Claude TUI's stdin reader activates noticeably
        // after the banner has started streaming. Byte threshold catches
        // the slow-init case (fast streams the banner in chunks while the
        // input loop is still booting); age threshold catches the
        // small-banner case. AND-combining is intentional.
        //
        // Cadence: 100 ms polls, capped at 40 attempts (~4 s) so a silent
        // startup doesn't deadlock paste forever — but the cap is rare;
        // typical Claude/Codex hits 500 bytes well within 1.5 s.
        // Fourth condition: the pty has gone quiet. Age and bytes both measure
        // that a TUI *started* talking, and Claude Code clears both within a
        // second or so of launch — its banner streams immediately while the
        // composer is still coming up. Pasting into that window put the text
        // in the prompt and let the Return fall on the floor: ghostty reports
        // the key as handled, so every retry below sees success while nothing
        // was submitted. A TUI that has finished painting and is waiting on
        // input stops writing, and that silence is the part that actually
        // means ready.
        // The byte threshold assumes a CLI booting into this pane: Claude
        // streams a banner over several hundred bytes before its stdin reader
        // is up, so "a lot has been printed and then it stopped" is what ready
        // looks like. A pane attached to a shell that is ALREADY running —
        // every peer agent pane — never looks like that. It prints one prompt,
        // about 170 bytes, and waits, which is as ready as anything gets. The
        // gate could only ever time out on it, and a paste that goes out on a
        // timer rather than a signal is the enter-swallow this exists to
        // prevent, just with the odds moved.
        //
        // So a long enough silence stands in for the volume. It cannot fire
        // early on a booting CLI that is mid-banner, because mid-banner is not
        // silent; and it is still well inside the deferral cap, so the worst
        // it can do is send what the cap would have sent anyway, sooner.
        let coldSettleSeconds: TimeInterval = 1.5
        let coldByteThreshold = 500
        let coldQuietSeconds: TimeInterval = 0.6
        let coldQuietStandsInAfter: TimeInterval = 2.0
        let coldDeferCap = 40
        let coldReady: Bool = {
            guard let age = ptyOutputAge else { return false }
            guard let quiet = ptyOutputQuietFor else { return false }
            guard age >= coldSettleSeconds, quiet >= coldQuietSeconds else { return false }
            return ptyOutputBytes >= coldByteThreshold || quiet >= coldQuietStandsInAfter
        }()
        if !hasCompletedPaste, !coldReady, p.tuiReadyDeferCount < coldDeferCap {
            pasteInFlight = false  // unlock the queue so drain can re-enter
            pasteQueue.insert(p, at: 0)  // put this paste back at the head
            var deferred = p
            deferred.tuiReadyDeferCount += 1
            pasteQueue[0] = deferred
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.drainPasteQueue()
            }
            #if DEBUG
            if deferred.tuiReadyDeferCount == 1 {
                dlog("paste.defer.tui_cold panel=\(id.uuidString.prefix(8)) textLen=\(p.text.count) (waiting for age≥1.5s AND bytes≥500)")
            }
            #endif
            return
        }
        #if DEBUG
        if !hasCompletedPaste {
            let ageMs = (ptyOutputAge ?? 0) * 1000
            let bytes = ptyOutputBytes
            if coldReady {
                dlog("paste.cold.ready panel=\(id.uuidString.prefix(8)) defers=\(p.tuiReadyDeferCount) ptyAgeMs=\(Int(ageMs)) ptyBytes=\(bytes) quietMs=\(Int((ptyOutputQuietFor ?? 0) * 1000)) textLen=\(p.text.count)")
            } else {
                dlog("paste.cold.fallback panel=\(id.uuidString.prefix(8)) defers=\(p.tuiReadyDeferCount) ptyAgeMs=\(Int(ageMs)) ptyBytes=\(bytes) quietMs=\(Int((ptyOutputQuietFor ?? 0) * 1000)) textLen=\(p.text.count) (deadline reached, proceeding)")
            }
        }
        #endif

        pasteInFlight = true
        pasteGeneration &+= 1
        let gen = pasteGeneration
        startPasteWatchdog(generation: gen, instructionLength: p.text.count, completion: p.completion)

        if !p.text.isEmpty {
            // Chunked paste: ghostty_surface_text appears to have an internal
            // input buffer that truncates large single-shot pastes (observed:
            // ~700-char cutoff at exactly the same position regardless of
            // timing, ruling out a Swift-side race). Splitting into 256-char
            // chunks with a 2ms yield between each lets ghostty's IO thread
            // drain the buffer between calls, removing the size ceiling.
            // Side effect: removes the need for the large drain wait + cold
            // bonus that earlier attempts piled on.
            //
            // Char-based chunking (not byte) so we never split a multi-byte
            // UTF-8 codepoint mid-sequence.
            let chunkChars = 256
            let chars = Array(p.text)
            var idx = 0
            while idx < chars.count {
                let end = min(idx + chunkChars, chars.count)
                let chunk = String(chars[idx..<end])
                InputInjectionLog.record(site: "processPaste", surface: id, text: chunk)
                let data = chunk.utf8
                let len = UInt(data.count)
                data.withContiguousStorageIfAvailable { buf in
                    ghostty_surface_text(surface, buf.baseAddress, len)
                } ?? chunk.withCString { cstr in
                    ghostty_surface_text(surface, cstr, len)
                }
                idx = end
                if idx < chars.count {
                    usleep(2_000) // 2ms yield per chunk for ghostty IO thread
                }
            }
            #if DEBUG
            dlog("paste.text.sent gen=\(gen) textLen=\(p.text.count) chunks=\((chars.count + chunkChars - 1) / chunkChars)")
            #endif
            if p.needsReturn {
                usleep(5_000) // 5ms — let IO thread flush final chunk before Return
            }
        }

        guard p.needsReturn else {
            #if DEBUG
            dlog("paste.return.skipped reason=no_need_return gen=\(gen)")
            #endif
            // Even without Return, the ghostty IO thread may still be flushing
            // paste bytes to the PTY when ghostty_surface_text returns. Firing
            // finalizePaste synchronously here is a lie: the Rust CLI uses our
            // ack to decide when to send Enter via team.send_key, and if it
            // fires Enter too early the paste truncates mid-stream (observed
            // with the ~2000-char agent init prompt — first ~700 chars submit,
            // the rest is discarded).
            //
            // Drain wait after the (chunked) paste finishes. Cold-start is
            // now handled by the pty_data_callback ready gate at the top of
            // processPaste, so we no longer need a "cold bonus" here — the
            // gate guarantees the TUI was alive when we started the paste.
            // Keep a small base so the last chunk has time to land in PTY
            // before the Rust CLI fires Enter via team.send_key.
            let baseMs = max(15, min(120, p.text.count / 32))
            let coldBonusMs = 0
            let waitMs = baseMs + coldBonusMs
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(waitMs) / 1000.0) { [weak self] in
                guard let self else { return }
                // Generation check: if a later paste was already queued and
                // bumped the generation, this paste's window has closed.
                // finalizePaste still has to run so the queue can drain, but
                // we don't want to ack a paste that's been superseded.
                guard self.pasteGeneration == gen else {
                    #if DEBUG
                    dlog("paste.return.skipped.drain.stale gen=\(gen) currentGen=\(self.pasteGeneration)")
                    #endif
                    return
                }
                self.hasCompletedPaste = true
                #if DEBUG
                dlog("paste.return.skipped.drain.complete gen=\(gen) waitMs=\(waitMs) baseMs=\(baseMs) coldBonusMs=\(coldBonusMs) textLen=\(p.text.count)")
                #endif
                self.finalizePaste(result: .success(()), completion: p.completion)
            }
            return
        }

        let delivered = sendReturnKey(to: surface)
        #if DEBUG
        dlog("paste.return.sent gen=\(gen) handled=\(delivered)")
        #endif
        if delivered {
            hasCompletedPaste = true
            finalizePaste(result: .success(()), completion: p.completion)
            return
        }
        #if DEBUG
        dlog("[processPaste.Return] PRESS not handled, sync retry in 10ms surface=\(id.uuidString.prefix(8))")
        #endif
        usleep(10_000)
        let retryDelivered = sendReturnKey(to: surface)
        #if DEBUG
        dlog("paste.return.sent gen=\(gen) handled=\(retryDelivered) retry=sync")
        #endif
        if retryDelivered {
            hasCompletedPaste = true
            finalizePaste(result: .success(()), completion: p.completion)
            return
        }
        #if DEBUG
        dlog("[processPaste.Return] sync retry failed, scheduling async retries surface=\(id.uuidString.prefix(8))")
        #endif

        let token = ReturnDeliveryToken()
        let asyncDelays: [Double] = [0.2, 0.5, 1.0, 2.0, 3.0]
        for (i, delay) in asyncDelays.enumerated() {
            let isLast = i == asyncDelays.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, token] in
                guard let self else { return }
                guard !token.delivered else {
                    #if DEBUG
                    dlog("paste.drop reason=token_stale gen=\(gen) retry=async\(i + 1)")
                    #endif
                    return
                }
                guard self.pasteGeneration == gen else {
                    #if DEBUG
                    dlog("paste.drop reason=token_stale gen=\(gen) currentGen=\(self.pasteGeneration) retry=async\(i + 1)")
                    #endif
                    return
                }
                guard let surf = self.surface else {
                    #if DEBUG
                    dlog("paste.drop reason=surface_nil gen=\(gen) retry=async\(i + 1)")
                    #endif
                    if isLast {
                        self.finalizePaste(result: .failure(.surfaceUnavailable), completion: p.completion)
                    }
                    return
                }
                let ok = self.sendReturnKey(to: surf)
                if ok { token.delivered = true }
                #if DEBUG
                dlog("paste.return.sent gen=\(gen) handled=\(ok) retry=async\(i + 1)")
                dlog("[processPaste.Return] async retry \(i + 1)/\(asyncDelays.count) delay=\(delay)s handled=\(ok) token.delivered=\(token.delivered) surface=\(self.id.uuidString.prefix(8))")
                #endif
                if ok {
                    self.finalizePaste(result: .success(()), completion: p.completion)
                } else if isLast {
                    self.finalizePaste(result: .failure(.returnRetryExhausted), completion: p.completion)
                }
            }
        }
    }

    /// Send a single Return key (PRESS+RELEASE) to the given surface.
    /// Returns true if ghostty reported the key press as handled.
    /// Internal visibility for TeamOrchestrator's per-surface drain queue.
    ///
    /// Note: `unshifted_codepoint` must be 0 (not 13/CR). Setting it to 13
    /// causes ghostty's key encoder to treat Return as a "text" key rather than
    /// a "functional" key, which can be silently dropped by TUI apps in certain
    /// states (e.g., Claude Code's "thinking" mode returning to idle).
    func sendReturnKey(to surface: ghostty_surface_t) -> Bool {
        InputInjectionLog.recordKey(
            site: "sendReturnKey", surface: id, keycode: 36, text: "\r"
        )
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 36 // kVK_Return
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0 // Must be 0, not 13 — see comment above
        keyEvent.composing = false
        var pressHandled = false
        "\r".withCString { ptr in
            keyEvent.text = ptr
            pressHandled = ghostty_surface_key(surface, keyEvent)
        }
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
        forceRefresh()
        return pressHandled
    }

    func requestBackgroundSurfaceStartIfNeeded(reason: String = "background") {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestBackgroundSurfaceStartIfNeeded(reason: reason)
            }
            return
        }

        guard !permanentlyClosed else { return }
        guard surface == nil, attachedView != nil else { return }
        guard !surfaceCreationInProgress else { return }
        guard !backgroundSurfaceStartQueued else { return }
        backgroundSurfaceStartQueued = true

        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, surfaceCreationRetryNotBefore - now)
        let token = UUID()
        backgroundSurfaceStartToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.backgroundSurfaceStartToken == token else { return }
            self.backgroundSurfaceStartToken = nil
            self.backgroundSurfaceStartQueued = false
            guard !self.permanentlyClosed else { return }
            guard self.surface == nil, let view = self.attachedView, view.window != nil else { return }
            sentryBreadcrumb("surface.create.deferredStart", category: "terminal", data: [
                "surface": self.id.uuidString,
                "workspace": self.tabId.uuidString,
                "reason": reason,
                "inWindow": view.window != nil,
                "width": Double(view.bounds.width),
                "height": Double(view.bounds.height)
            ])
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
        InputInjectionLog.record(
            site: "writeTextData", surface: id, text: String(decoding: data, as: UTF8.self)
        )
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

    /// Put a terminal left in a program's modes back to a plain one.
    ///
    /// A TUI turns on mouse reporting, the alternate screen and bracketed
    /// paste, and turns them off again when it exits. A program that does not
    /// exit — a crash, a `kill -9`, a link dropped mid-run — never gets to ask,
    /// and the request stands. What is left on a peer pane is a plain shell at
    /// the far end and a terminal here still reporting: every movement of the
    /// pointer across the pane is sent over as `ESC [ < 35;47;44M`, the far
    /// shell's line editor swallows the escape it does not know and keeps the
    /// digits, and a mouse dragged across the pane arrives there as commands.
    /// `35: command not found`, once per sample, for as long as it is stuck.
    ///
    /// The modes are held *here*, so this is a local repair — nothing is sent
    /// to the far end, which has its own state and is not the thing that is
    /// wrong. Ghostty's own action, the one behind the `reset` command: it
    /// clears the mode set along with the screen, which is what makes it safe
    /// to run more than once.
    @discardableResult
    func resetTerminal() -> Bool {
        performBindingAction("reset")
    }

    func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    @MainActor private func releaseGhosttySurfaceAsync(reason: String) {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surface else {
            callbackContext?.release()
            return
        }

        self.surface = nil
        pendingTextQueue.removeAll(keepingCapacity: false)
        pendingTextBytes = 0
        #if DEBUG
        dlog("surface.free.request surface=\(id.uuidString.prefix(8)) reason=\(reason)")
        #endif

        // Clear the pty_data_callback synchronously here — before the async free
        // Task and before `self` finishes deallocating. The callback's userdata
        // is an unmanaged pointer to `self` (passUnretained); deferring the
        // clear into the Task left a window where the IO thread could fire the
        // callback into a dangling `self` between deinit and the Task running
        // (observed as an objc_retain crash in recordPtyOutput on the io-reader
        // thread during rapid pane close). clear is mutex-guarded in ghostty and
        // serialized with callback dispatch, so once it returns no further
        // callback can run.
        ghostty_surface_clear_pty_data_callback(surface)

        // Keep the actual free asynchronous to avoid re-entrant close/deinit loops.
        // Route through the coordinator so that ghostty_surface_free() is deferred
        // until all active SurfaceReadLeases have been released — preventing
        // use-after-free in async readers (e.g. AutoReplyPoller Phase 2).
        let surfaceId = id
        let coordinator = surfaceFreeCoordinator  // strong ref survives TerminalSurface deinit
        Task { @MainActor in
            #if DEBUG
            dlog("surface.free.schedule surface=\(surfaceId.uuidString.prefix(8)) reason=\(reason)")
            #endif
            coordinator.scheduleClose {
                #if DEBUG
                dlog("surface.free.perform surface=\(surfaceId.uuidString.prefix(8)) reason=\(reason)")
                #endif
                freeGhosttySurface(surface, id: surfaceId)
                callbackContext?.release()
            }
        }
    }

    deinit {
        #if DEBUG
        dlog("deinit \(Self.self)")
        #endif
        // TerminalSurface is always owned by @MainActor types (TerminalPanel, Workspace),
        // so deinit effectively runs on the main actor. Swift cannot verify this statically,
        // so we cannot call @MainActor-isolated releaseGhosttySurfaceAsync directly.
        //
        // Instead: capture all needed state now (before self deallocates), clear the
        // pty_data_callback synchronously (critical — userdata is an unmanaged self pointer
        // and the IO thread can fire after deinit without this), then schedule the
        // deferred free through the coordinator via Task. Self must NOT be captured
        // in the Task closure.
        let coordinator = surfaceFreeCoordinator
        let capturedSurface = surface
        let capturedContext = surfaceCallbackContext
        let capturedId = id

        if let s = capturedSurface {
            ghostty_surface_clear_pty_data_callback(s)
        }

        Task { @MainActor in
            #if DEBUG
            dlog("surface.free.schedule.deinit surface=\(capturedId.uuidString.prefix(8))")
            #endif
            coordinator.scheduleClose {
                #if DEBUG
                dlog("surface.free.perform.deinit surface=\(capturedId.uuidString.prefix(8))")
                #endif
                if let s = capturedSurface {
                    freeGhosttySurface(s, id: capturedId)
                }
                capturedContext?.release()
            }
        }
    }
}

/// Single entry point for the synchronous free so both teardown paths — the
/// explicit release above and `deinit` — are timed identically. Routing them
/// through one function is what keeps the started and completed counts paired;
/// incrementing at each call site invites a path that reports a start it never
/// finishes.
///
/// This call blocks the caller until Ghostty joins the surface's renderer and IO
/// threads, and the caller here is the MainActor. That is the block the
/// telemetry exists to measure.
private func freeGhosttySurface(_ surface: ghostty_surface_t, id: UUID) {
    #if DEBUG
    SurfaceFreeTelemetry.shared.recordStarted(surfaceId: id)
    #endif
    ghostty_surface_free(surface)
    #if DEBUG
    SurfaceFreeTelemetry.shared.recordCompleted(surfaceId: id)
    #endif
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
        guard visibleInUI != visible else { return }
        visibleInUI = visible
        terminalSurface?.localPaneVisibilityDidChange(becameVisible: visible)
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
        let targetOpaque = color.alphaComponent >= 1.0
        if let layer,
           terminalBackgroundLayerNeedsUpdate(
               currentColor: layer.backgroundColor,
               currentOpaque: layer.isOpaque,
               targetColor: color.cgColor,
               targetOpaque: targetOpaque
           ) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = color.cgColor
            layer.isOpaque = targetOpaque
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
        let usesTransparentWindow = termMeshShouldUseTransparentBackgroundWindow()
        let targetColor = usesTransparentWindow ? NSColor.clear : color
        let targetOpaque = !usesTransparentWindow && color.alphaComponent >= 1.0
        if terminalWindowBackgroundNeedsUpdate(
            currentColor: window.backgroundColor,
            currentOpaque: window.isOpaque,
            targetColor: targetColor,
            targetOpaque: targetOpaque
        ) {
            window.backgroundColor = targetColor
            window.isOpaque = targetOpaque
        }
        if configProvider.backgroundLogEnabled {
            let signature = "\(usesTransparentWindow ? "transparent" : color.hexString()):\(String(format: "%.3f", color.alphaComponent))"
            if signature != lastLoggedWindowBackgroundSignature {
                lastLoggedWindowBackgroundSignature = signature
                configProvider.logBackground(
                    "window background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") transparent=\(usesTransparentWindow) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
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
        // SwiftUI can call updateNSView repeatedly for visibility/focus changes.
        // The existing surface is already attached to this view; window moves
        // and geometry changes have their own callbacks, so re-running the full
        // attach/size/background/color pipeline here only adds switch-time work.
        guard terminalSurface !== surface else { return }
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
        terminalSurface?.onDidEnterWindow?()

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

        // Use the bounds AppKit has already assigned for this move. Forcing the
        // hosting hierarchy to lay out from viewDidMoveToWindow can re-enter an
        // active SwiftUI layout pass during workspace switches. The normal
        // layout() callback applies the settled size afterward. Pending size is
        // only a fallback for detached/off-window transitions.
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
        terminalSurface?.attachToView(self, deferCreation: false)
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
        guard performBindingAction("copy_to_clipboard") else { return }
        DispatchQueue.main.async {
            // Copy is the explicit capture gesture for Shelf. This deliberately
            // avoids observing arbitrary clipboard changes from other apps.
            _ = PasteShelfStore.shared.capture()
        }
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
            dlog("ime.becomeFirstResponder hasMarkedText=\(markedText.length > 0) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
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
        #if DEBUG
        dlog("ime.resignFirstResponder hadMarkedText=\(hadMarkedText) resigned=\(result) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        #endif
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

    @discardableResult
    func sendIMEText(_ text: String, withReturn: Bool = true) -> Bool {
        terminalSurface?.sendIMEText(text, withReturn: withReturn) ?? false
    }

    @discardableResult
    func sendIMETextPreservingNewlines(_ text: String, withReturn: Bool = true) -> Bool {
        terminalSurface?.sendIMETextPreservingNewlines(text, withReturn: withReturn) ?? false
    }

    func sendIMETextResult(_ text: String, withReturn: Bool = true,
                           completion: @escaping (Result<Void, TerminalSurface.PasteSendError>) -> Void) {
        guard let ts = terminalSurface else { completion(.failure(.surfaceUnavailable)); return }
        ts.sendIMETextResult(text, withReturn: withReturn, completion: completion)
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
        // Somebody is sitting in front of this pane, so it — not a remote
        // viewer that typed earlier — owns the PTY's grid from here on. Placed
        // before the IME redirect so composing counts as typing too.
        terminalSurface?.noteLocalInput()
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
        //
        // ESC (keyCode 53) is never a composing event — it *cancels* composition.
        // Marking it composing causes Ghostty to suppress the 0x1B byte, which
        // breaks vim normal-mode switching over SSH even when no IME box is open.
        let accumulatedTextIsEmpty = keyTextAccumulator == nil || keyTextAccumulator!.isEmpty
        keyEvent.composing = GhosttyNSView.computeComposingFlag(
            keyCode: event.keyCode,
            markedTextBefore: markedTextBefore,
            hasMarkedTextAfter: markedText.length > 0,
            accumulatedTextIsEmpty: accumulatedTextIsEmpty
        )
        #if DEBUG
        if event.keyCode == 36 && markedTextBefore && markedText.length == 0 && accumulatedTextIsEmpty {
            dlog("key.return.clearingIME markedTextBefore=true accumulator=empty → composing=false")
        }
        if event.keyCode == 36 && (markedTextBefore || markedText.length > 0) {
            dlog("ime.return_with_markedText markedTextBefore=\(markedTextBefore) hasMarkedText=\(markedText.length > 0) composing=\(keyEvent.composing) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        }
        #endif

        // Use accumulated text from insertText (for IME), or compute text for key
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            var sentAccumulatedText = false

            // Step 1: Send accumulated IME-committed text as keycode-free text events.
            // keycode=0 (.unidentified) activates the ghostty fdfc9fea2 UTF-8 fallback,
            // which sends the text bytes directly without keycode-based encoding.
            // This prevents the physical trigger key's keycode (e.g. left-arrow=123) from
            // corrupting the encoded output.
            for text in accumulated {
                if shouldSendText(text) {
                    var textEvent = ghostty_input_key_s()
                    textEvent.action = GHOSTTY_ACTION_PRESS
                    textEvent.keycode = 0
                    textEvent.mods = GHOSTTY_MODS_NONE
                    textEvent.consumed_mods = GHOSTTY_MODS_NONE
                    textEvent.unshifted_codepoint = 0
                    textEvent.composing = false
                    text.withCString { ptr in
                        textEvent.text = ptr
                        #if DEBUG
                        let scalars = text.unicodeScalars.map { "U+\(String($0.value, radix: 16, uppercase: true))" }.joined(separator: " ")
                        dlog("ime.ghosttyKey path=accumulated.text keycode=0 text=\(scalars)")
                        #endif
                        _ = ghostty_surface_key(surface, textEvent)
                    }
                    sentAccumulatedText = true
                }
            }

            if Self.shouldReplayPhysicalKeyAfterAccumulatedText(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                markedTextBefore: markedTextBefore,
                hasMarkedTextAfter: markedText.length > 0,
                sentAccumulatedText: sentAccumulatedText,
                physicalKeyAlreadyInsertedByTextInput: Self.accumulatedTextIncludesPhysicalKey(
                    accumulated,
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags
                )
            ) {
                keyEvent.composing = false
                keyEvent.text = nil
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                _ = ghostty_surface_key(surface, keyEvent)
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

    /// Decide whether a key event should be flagged as composing (= part of an
    /// active IME composition) when handed to Ghostty.
    ///
    /// Ghostty key_encode.zig early-returns on composing=true (suppressing the
    /// byte), so this decision is the single point that prevents Enter/Tab/Esc
    /// swallow when an IME ends composition without committing text.
    ///
    /// Pure function — no AppKit / Ghostty side effects. Trivially unit-testable.
    ///
    /// Decision matrix:
    /// | keyCode | markedTextBefore | hasMarkedTextAfter | accumulatedTextIsEmpty | result |
    /// |---------|------------------|--------------------|------------------------|--------|
    /// | 53 (Esc)| any              | any                | any                    | false  |
    /// | 36 (Ret)| true             | false              | true                   | false  |
    /// | any     | true or false    | true               | any                    | true   |
    /// | any     | true             | false              | any                    | true   |
    /// | any     | false            | false              | any                    | false  |
    static func computeComposingFlag(
        keyCode: UInt16,
        markedTextBefore: Bool,
        hasMarkedTextAfter: Bool,
        accumulatedTextIsEmpty: Bool
    ) -> Bool {
        // ESC cancels composition — never composing.
        guard keyCode != 53 else { return false }
        // Return that clears composition without committing text is not composing:
        // accumulator empty means no text was sent via insertText, so Ghostty must
        // receive the physical "\r" or the Enter is permanently swallowed.
        if keyCode == 36 && markedTextBefore && !hasMarkedTextAfter && accumulatedTextIsEmpty {
            return false
        }
        return markedTextBefore || hasMarkedTextAfter
    }

    static func shouldReplayPhysicalKeyAfterAccumulatedText(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        markedTextBefore: Bool,
        hasMarkedTextAfter: Bool,
        sentAccumulatedText: Bool,
        physicalKeyAlreadyInsertedByTextInput: Bool = false
    ) -> Bool {
        let wasComposing = markedTextBefore || hasMarkedTextAfter
        if wasComposing {
            // CJK IMEs (notably Korean 2-set) can commit the previous syllable
            // while starting the next marked syllable in the same keyDown. The
            // physical key was consumed by the IME in that case; replaying it
            // duplicates the leading jamo as a raw character in TUI apps that
            // don't honor the preedit overlay (e.g. codex, kiro-cli).
            if hasMarkedTextAfter && sentAccumulatedText {
                #if DEBUG
                dlog("ime.replay_skipped reason=commit_and_restart keycode=\(keyCode)")
                #endif
                return false
            }

            let userMods = modifierFlags.intersection([.command, .shift, .option, .control])
            let isPlainLeftArrow = keyCode == 123 && userMods.isEmpty
            return !isPlainLeftArrow && !physicalKeyAlreadyInsertedByTextInput
        }

        return !sentAccumulatedText
    }

    static func accumulatedTextIncludesPhysicalKey(
        _ accumulated: [String],
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let nonTextMods = modifierFlags.intersection([.command, .option, .control])
        guard nonTextMods.isEmpty else { return false }

        let shifted = modifierFlags.contains(.shift)
        let insertedTexts = physicalTextsInsertedByTextInput(keyCode: keyCode, shifted: shifted)
        guard !insertedTexts.isEmpty else {
            return false
        }

        guard let last = accumulated.last else { return false }
        return insertedTexts.contains { insertedText in
            last == insertedText || last.hasSuffix(insertedText)
        }
    }

    private static func physicalTextsInsertedByTextInput(keyCode: UInt16, shifted: Bool) -> [String] {
        switch keyCode {
        case 18: // kVK_ANSI_1
            return [shifted ? "!" : "1"]
        case 19: // kVK_ANSI_2
            return [shifted ? "@" : "2"]
        case 20: // kVK_ANSI_3
            return [shifted ? "#" : "3"]
        case 21: // kVK_ANSI_4
            return [shifted ? "$" : "4"]
        case 22: // kVK_ANSI_6
            return [shifted ? "^" : "6"]
        case 23: // kVK_ANSI_5
            return [shifted ? "%" : "5"]
        case 24: // kVK_ANSI_Equal
            return [shifted ? "+" : "="]
        case 25: // kVK_ANSI_9
            return [shifted ? "(" : "9"]
        case 26: // kVK_ANSI_7
            return [shifted ? "&" : "7"]
        case 27: // kVK_ANSI_Minus
            return [shifted ? "_" : "-"]
        case 28: // kVK_ANSI_8
            return [shifted ? "*" : "8"]
        case 29: // kVK_ANSI_0
            return [shifted ? ")" : "0"]
        case 30: // kVK_ANSI_RightBracket
            return [shifted ? "}" : "]"]
        case 33: // kVK_ANSI_LeftBracket
            return [shifted ? "{" : "["]
        case 39: // kVK_ANSI_Quote
            return [shifted ? "\"" : "'"]
        case 41: // kVK_ANSI_Semicolon
            return [shifted ? ":" : ";"]
        case 42: // kVK_ANSI_Backslash
            return [shifted ? "|" : "\\"]
        case 43: // kVK_ANSI_Comma
            return [shifted ? "<" : ","]
        case 44: // kVK_ANSI_Slash
            return [shifted ? "?" : "/"]
        case 47: // kVK_ANSI_Period
            return [shifted ? ">" : "."]
        case 49: // kVK_Space
            return [" "]
        case 50: // kVK_ANSI_Grave: US ` / ~, Korean ₩ / ~
            return shifted ? ["~"] : ["`", "₩"]
        default:
            return []
        }
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
        if let surfaceId = terminalSurface?.id,
           let identity = TeamOrchestrator.shared.agentIdentity(forPanelId: surfaceId) {
            menu.addItem(.separator())
            let recycleItem = NSMenuItem(title: "Recycle Agent",
                                         action: #selector(recycleAgentAction(_:)),
                                         keyEquivalent: "")
            recycleItem.representedObject = RecycleAgentPayload(teamName: identity.teamName, agentName: identity.agentName, force: false)
            recycleItem.target = self
            menu.addItem(recycleItem)
            let recycleForceItem = NSMenuItem(title: "Recycle Agent (Force)",
                                              action: #selector(recycleAgentAction(_:)),
                                              keyEquivalent: "")
            recycleForceItem.representedObject = RecycleAgentPayload(teamName: identity.teamName, agentName: identity.agentName, force: true)
            recycleForceItem.target = self
            menu.addItem(recycleForceItem)
        }
        return menu
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    @objc private func recycleAgentAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? RecycleAgentPayload else { return }
        TeamOrchestrator.shared.recycleAgent(teamName: payload.teamName, agentName: payload.agentName, force: payload.force)
    }

    private struct RecycleAgentPayload {
        let teamName: String
        let agentName: String
        let force: Bool
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
        #if DEBUG
        dlog("deinit \(Self.self)")
        #endif
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
#if DEBUG
        let dispID = (notification.object as? NSWindow)?.screen?.displayID ?? 0
        dlog("surface.didChangeScreen displayID=\(dispID)")
#endif
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

struct TerminalPortalAnchorGeometry {
    let windowID: ObjectIdentifier?
    let superviewID: ObjectIdentifier?
    let frameInWindow: NSRect

    func isApproximatelyEqual(
        to other: TerminalPortalAnchorGeometry,
        epsilon: CGFloat = 0.25
    ) -> Bool {
        guard windowID == other.windowID,
              superviewID == other.superviewID else {
            return false
        }
        return abs(frameInWindow.minX - other.frameInWindow.minX) <= epsilon
            && abs(frameInWindow.minY - other.frameInWindow.minY) <= epsilon
            && abs(frameInWindow.width - other.frameInWindow.width) <= epsilon
            && abs(frameInWindow.height - other.frameInWindow.height) <= epsilon
    }
}

func terminalPortalAnchorNeedsSynchronization(
    previous: TerminalPortalAnchorGeometry?,
    current: TerminalPortalAnchorGeometry,
    force: Bool
) -> Bool {
    force || previous?.isApproximatelyEqual(to: current) != true
}

func terminalPortalAnchorNeedsFullReconciliation(
    previous: TerminalPortalAnchorGeometry?,
    current: TerminalPortalAnchorGeometry
) -> Bool {
    guard let previous else { return true }
    return previous.windowID != current.windowID
        || previous.superviewID != current.superviewID
}

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
        var onGeometryChanged: ((_ needsFullReconciliation: Bool) -> Void)?
        private var hasScheduledGeometryCallback = false
        private var scheduledGeometryCallbackIsForced = false
        private var lastReportedGeometry: TerminalPortalAnchorGeometry?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onDidMoveToWindow?()
            scheduleGeometryCallback(force: true)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleGeometryCallback(force: true)
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
        private func scheduleGeometryCallback(force: Bool = false) {
            scheduledGeometryCallbackIsForced =
                scheduledGeometryCallbackIsForced || force
            guard !hasScheduledGeometryCallback else { return }
            hasScheduledGeometryCallback = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledGeometryCallback = false
                let isForced = self.scheduledGeometryCallbackIsForced
                self.scheduledGeometryCallbackIsForced = false
                let currentGeometry = self.currentGeometry()
                let previousGeometry = self.lastReportedGeometry
                guard terminalPortalAnchorNeedsSynchronization(
                    previous: previousGeometry,
                    current: currentGeometry,
                    force: isForced
                ) else {
                    return
                }
                self.lastReportedGeometry = currentGeometry
                self.onGeometryChanged?(
                    terminalPortalAnchorNeedsFullReconciliation(
                        previous: previousGeometry,
                        current: currentGeometry
                    )
                )
            }
        }

        private func currentGeometry() -> TerminalPortalAnchorGeometry {
            TerminalPortalAnchorGeometry(
                windowID: window.map(ObjectIdentifier.init),
                superviewID: superview.map(ObjectIdentifier.init),
                frameInWindow: convert(bounds, to: nil)
            )
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
        // Re-applied on every update so a portal reattach (which rebinds the
        // hosted view without touching the surface) restores the button.
        hostedView.setScrollToBottomOverlay(visible: terminalSurface.shouldShowScrollToBottom)
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
            host.onGeometryChanged = { [weak host, weak coordinator] needsFullReconciliation in
                guard let host, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard coordinator.lastBoundHostId == ObjectIdentifier(host) else { return }
                TerminalWindowPortalRegistry.synchronizeForAnchor(
                    host,
                    needsFullReconciliation: needsFullReconciliation
                )
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
