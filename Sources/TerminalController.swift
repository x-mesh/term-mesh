import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import os
import Bonsplit
import PeerProto
import WebKit

// The worktree-lock helpers below return `Result<_, String>`, using a String
// message as the Failure type. `Result`'s Failure must be an `Error`, so this
// retroactive conformance lets those `.failure("…")` sites compile.
extension String: Error {}

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    static let shared = TerminalController()

    /// PID of the daemon process, trusted as an ancestor for headless agents.
    /// Set after daemon spawn or orphan reuse so isDescendant() grants access.
    nonisolated(unsafe) var trustedDaemonPid: pid_t = 0

    nonisolated(unsafe) var socketPath = SocketControlSettings.socketPath()
    nonisolated(unsafe) var serverSocket: Int32 = -1
    nonisolated(unsafe) var isRunning = false
    nonisolated(unsafe) var acceptLoopAlive = false
    /// Periodic timer that polls `socketPath` for existence. Fires
    /// `recoverSocket()` when the path is unlinked out from under us
    /// (external `unlink()`, partial cleanup race, `/tmp` reaper). The
    /// listener FD stays alive on unlink, but client `connect()` does a
    /// path lookup and would otherwise get ENOENT until app relaunch.
    ///
    /// Polling instead of `DispatchSourceFileSystemObject`: macOS rejects
    /// `open(O_EVTONLY)` on Unix socket files with `EOPNOTSUPP` (errno 102),
    /// so the vnode-source path is unavailable for sockets specifically.
    nonisolated(unsafe) var socketPathWatcher: DispatchSourceTimer?
    /// Monotonic ns timestamp of the last `installSocketPathWatcher` call.
    /// Throttles watcher-triggered recoveries — events within this window
    /// of a fresh install are ignored so a pathological re-unlink loop
    /// can't spin `recoverSocket()`.
    nonisolated(unsafe) var socketPathWatcherInstalledNs: UInt64 = 0
    private var clientHandlers: [Int32: Thread] = [:]
    /// Injected notification service (defaults to singleton for backward compatibility).
    var notifications: any NotificationService = TerminalNotificationStore.shared
    var tabManager: TabManager?
    var accessMode: SocketControlMode = .termMeshOnly
    let myPid = getpid()
    #if DEBUG
    var debugPeerShellInspection: [String: Any]?
    #endif

    /// Dedicated queue for team data commands that don't need MainActor.
    /// Approach C (dual queue): data-only team operations bypass v2MainSync entirely.
    private let teamDataQueue = DispatchQueue(label: "term-mesh.team-data", qos: .userInitiated)

    private nonisolated(unsafe) static var socketCommandPolicyDepth: Int = 0
    private nonisolated(unsafe) static var socketCommandFocusAllowanceStack: [Bool] = []
    private nonisolated static let socketCommandPolicyLock = NSLock()

    private static let focusIntentV1Commands: Set<String> = [
        "focus_window",
        "select_workspace",
        "focus_surface",
        "focus_pane",
        "focus_surface_by_panel",
        "focus_webview",
        "focus_notification",
        "activate_app"
    ]

    private static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "surface.focus",
        "pane.focus",
        "pane.last",
        "browser.focus_webview",
        "browser.focus",
        "browser.tab.switch",
        "debug.command_palette.toggle",
        "debug.notification.focus",
        "debug.app.activate"
    ]

    enum V2HandleKind: String, CaseIterable {
        case window
        case workspace
        case pane
        case surface
    }

    var v2NextHandleOrdinal: [V2HandleKind: Int] = [
        .window: 1,
        .workspace: 1,
        .pane: 1,
        .surface: 1,
    ]
    var v2RefByUUID: [V2HandleKind: [UUID: String]] = [
        .window: [:],
        .workspace: [:],
        .pane: [:],
        .surface: [:],
    ]
    var v2UUIDByRef: [V2HandleKind: [String: UUID]] = [
        .window: [:],
        .workspace: [:],
        .pane: [:],
        .surface: [:],
    ]

    struct V2BrowserElementRefEntry {
        let surfaceId: UUID
        let selector: String
    }

    struct V2BrowserPendingDialog {
        let type: String
        let message: String
        let defaultText: String?
        let responder: (_ accept: Bool, _ text: String?) -> Void
    }

    var v2BrowserNextElementOrdinal: Int = 1
    var v2BrowserElementRefs: [String: V2BrowserElementRefEntry] = [:]
    var v2BrowserFrameSelectorBySurface: [UUID: String] = [:]
    var v2BrowserInitScriptsBySurface: [UUID: [String]] = [:]
    var v2BrowserInitStylesBySurface: [UUID: [String]] = [:]
    var v2BrowserDialogQueueBySurface: [UUID: [V2BrowserPendingDialog]] = [:]
    var v2BrowserDownloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    var v2BrowserUnsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]

    private init() {}

    // MARK: - Surface Cleanup

    /// Remove all v2 browser state associated with a closed surface.
    /// Called from Workspace.didCloseTab to prevent unbounded dictionary growth.
    func v2CleanupSurface(_ surfaceId: UUID) {
        // SP1: Remove surfaceId-keyed browser dictionaries
        v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
        v2BrowserInitScriptsBySurface.removeValue(forKey: surfaceId)
        v2BrowserInitStylesBySurface.removeValue(forKey: surfaceId)
        v2BrowserDialogQueueBySurface.removeValue(forKey: surfaceId)
        v2BrowserDownloadEventsBySurface.removeValue(forKey: surfaceId)
        v2BrowserUnsupportedNetworkRequestsBySurface.removeValue(forKey: surfaceId)

        // SP3: Remove element refs belonging to this surface
        let refsToRemove = v2BrowserElementRefs.filter { $0.value.surfaceId == surfaceId }.map(\.key)
        for ref in refsToRemove {
            v2BrowserElementRefs.removeValue(forKey: ref)
        }

        // SP2: Remove handle mappings for this surface UUID
        for kind in V2HandleKind.allCases {
            if let ref = v2RefByUUID[kind]?.removeValue(forKey: surfaceId) {
                v2UUIDByRef[kind]?.removeValue(forKey: ref)
            }
        }
    }

    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        socketCommandPolicyLock.lock()
        defer { socketCommandPolicyLock.unlock() }
        return socketCommandPolicyDepth > 0
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        socketCommandPolicyLock.lock()
        defer { socketCommandPolicyLock.unlock() }
        return socketCommandFocusAllowanceStack.last ?? false
    }

    private static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool) -> Bool {
        if isV2 {
            return focusIntentV2Methods.contains(commandKey)
        }
        return focusIntentV1Commands.contains(commandKey)
    }

    func withSocketCommandPolicy<T>(commandKey: String, isV2: Bool, _ body: () -> T) -> T {
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(commandKey: commandKey, isV2: isV2)
        Self.socketCommandPolicyLock.lock()
        Self.socketCommandPolicyDepth += 1
        Self.socketCommandFocusAllowanceStack.append(allowsFocusMutation)
        Self.socketCommandPolicyLock.unlock()
        defer {
            Self.socketCommandPolicyLock.lock()
            if !Self.socketCommandFocusAllowanceStack.isEmpty {
                _ = Self.socketCommandFocusAllowanceStack.popLast()
            }
            Self.socketCommandPolicyDepth = max(0, Self.socketCommandPolicyDepth - 1)
            Self.socketCommandPolicyLock.unlock()
        }
        return body()
    }

    func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.value != value || current.icon != icon || current.color != color
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    nonisolated static func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    struct SocketSurfaceKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    final class SocketFastPathState: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.termmesh.socket-fast-path")
        private var lastReportedDirectories: [SocketSurfaceKey: String] = [:]
        private let maxTrackedDirectories = 4096

        func shouldPublishDirectory(workspaceId: UUID, panelId: UUID, directory: String) -> Bool {
            let key = SocketSurfaceKey(workspaceId: workspaceId, panelId: panelId)
            return queue.sync {
                if lastReportedDirectories[key] == directory {
                    return false
                }
                if lastReportedDirectories.count >= maxTrackedDirectories {
                    lastReportedDirectories.removeAll(keepingCapacity: true)
                }
                lastReportedDirectories[key] = directory
                return true
            }
        }
    }

    static let socketFastPathState = SocketFastPathState()

    nonisolated static func explicitSocketScope(
        options: [String: String]
    ) -> (workspaceId: UUID, panelId: UUID)? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    nonisolated static func normalizeReportedDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return url.path
        }
        return trimmed
    }

    nonisolated static func remoteAgentHostKey(
        for input: String,
        candidates: [(key: String, displayName: String, sshTarget: String?)]
    ) -> String? {
        let needle = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exactKey = candidates.first(where: { $0.key == needle }) {
            return exactKey.key
        }
        if let displayName = candidates.first(where: {
            $0.displayName.caseInsensitiveCompare(needle) == .orderedSame
        }) {
            return displayName.key
        }
        if let fullTarget = candidates.first(where: {
            $0.sshTarget?.caseInsensitiveCompare(needle) == .orderedSame
        }) {
            return fullTarget.key
        }
        return candidates.first { candidate in
            guard var hostname = candidate.sshTarget?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !hostname.isEmpty
            else { return false }
            if let at = hostname.lastIndex(of: "@") {
                hostname = String(hostname[hostname.index(after: at)...])
            }
            return hostname.caseInsensitiveCompare(needle) == .orderedSame
        }?.key
    }

    nonisolated static func remoteAgentResponseWorkingDirectory(
        requested: String,
        memberWorkingDirectory: String?
    ) -> (directory: String, reused: Bool) {
        let requested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let member = memberWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actual = member.isEmpty ? requested : member
        return (directory: actual, reused: actual == requested)
    }

    nonisolated static func remoteAgentHostNotFoundMessage(
        input: String,
        connectedKeys: [String]
    ) -> String {
        let available = connectedKeys.isEmpty
            ? "no hosts are connected"
            : "connected host keys: \(connectedKeys.joined(separator: ", "))"
        return "no connected host named \(input); \(available)"
    }

    /// Update which window's TabManager receives socket commands.
    /// This is used when the user switches between multiple terminal windows.
    func setActiveTabManager(_ tabManager: TabManager?) {
        self.tabManager = tabManager
    }

    func handleClient(_ socket: Int32, peerPid: pid_t? = nil) {
        defer { close(socket) }

        // In termMeshOnly mode, verify the connecting process is a descendant of term-mesh.
        // Other modes allow external clients and apply separate auth controls.
        if accessMode == .termMeshOnly {
            // Use pre-captured peer PID if available (captured in accept loop before
            // the peer can disconnect), falling back to live lookup.
            let pid = peerPid ?? getPeerPid(socket)
            if let pid {
                guard isDescendant(pid) else {
                    let msg = "ERROR: Access denied — only processes started inside term-mesh can connect\n"
                    msg.withCString { ptr in _ = write(socket, ptr, strlen(ptr)) }
                    return
                }
            }
            // If pid is nil, LOCAL_PEERPID failed (peer disconnected before we
            // could read it — common with ncat --send-only). We still verify the
            // peer runs as the same user via LOCAL_PEERCRED. This is the same
            // security boundary as the socket file permissions (0600), so it does
            // not widen the attack surface. We also require that the peer actually
            // sent data (checked in the read loop below) — a connect-only probe
            // with no data is harmless.
            if pid == nil {
                guard peerHasSameUID(socket) else {
                    let msg = "ERROR: Unable to verify client process\n"
                    msg.withCString { ptr in _ = write(socket, ptr, strlen(ptr)) }
                    return
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        var authenticated = false

        while isRunning {
            let bytesRead = Self.readControlSocketBytes(socket, into: &buffer)
            if bytesRead < 0 {
                let readErrno = errno
                Logger.socket.warning(
                    "handleClient: read failed errno=\(readErrno) (\(String(cString: strerror(readErrno))))"
                )
                break
            }
            if bytesRead == 0 { break }

            guard let frames = Self.appendControlSocketChunk(
                Data(buffer[0..<bytesRead]),
                to: &pending
            ) else {
                Logger.socket.warning("handleClient: pending buffer exceeded 1 MB, closing connection")
                break
            }

            for line in frames {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if let authResponse = authResponseIfNeeded(for: trimmed, authenticated: &authenticated) {
                    writeSocketResponse(authResponse, to: socket)
                    continue
                }

                let response = processCommand(trimmed)
                writeSocketResponse(response, to: socket)
            }
        }
    }

    /// Reads one socket chunk, retrying an interrupted syscall without losing
    /// the caller's partial frame. Other errors are returned to the read loop
    /// so it can log the final errno and close the connection.
    nonisolated static func readControlSocketBytes(
        _ socket: Int32,
        into buffer: inout [UInt8],
        readOperation: (Int32, UnsafeMutableRawPointer?, Int) -> Int = {
            Darwin.read($0, $1, $2)
        }
    ) -> Int {
        buffer.withUnsafeMutableBytes { bytes in
            while true {
                let result = readOperation(socket, bytes.baseAddress, max(0, bytes.count - 1))
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
    }

    /// Appends raw socket bytes and decodes only complete LF-delimited frames.
    /// Keeping the pending buffer as bytes prevents a split UTF-8 scalar from
    /// invalidating either read chunk. Each completed frame and the remaining
    /// unterminated suffix have independent byte limits.
    ///
    /// Bounding the accumulated buffer instead conflated the case worth
    /// killing a connection over — one writer flooding us without ever
    /// sending a newline — with two legitimate shapes: a batch of complete
    /// frames whose total happens to exceed the limit, and a frame that lands
    /// exactly on it, pushed one byte past by its own trailing LF.
    nonisolated static func appendControlSocketChunk(
        _ chunk: Data,
        to pending: inout Data,
        maxPendingBytes: Int = 1_048_576
    ) -> [String]? {
        pending.append(chunk)

        var frames: [String] = []
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            // A terminated frame past the limit is still a flood; it just
            // arrived with its newline attached. `Data` resets `startIndex` on
            // every mutation, so this index is the frame's length.
            guard newlineIndex <= maxPendingBytes else { return nil }
            let frame = Data(pending[..<newlineIndex])
            pending.removeSubrange(...newlineIndex)
            if let line = String(data: frame, encoding: .utf8) {
                frames.append(line)
            }
        }
        guard pending.count <= maxPendingBytes else { return nil }
        return frames
    }

    private func processCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Empty command" }

        // v2 protocol: newline-delimited JSON.
        if trimmed.hasPrefix("{") {
            return processV2Command(trimmed)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""

        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif

        let response = withSocketCommandPolicy(commandKey: cmd, isV2: false) {
            switch cmd {
        case "ping":
            return "PONG"

        case "auth":
            return "OK: Authentication not required"

        case "list_windows":
            return listWindows()

        case "current_window":
            return currentWindow()

        case "focus_window":
            return focusWindow(args)

        case "new_window":
            return newWindow()

        case "close_window":
            return closeWindow(args)

        case "move_workspace_to_window":
            return moveWorkspaceToWindow(args)

        case "list_workspaces":
            return listWorkspaces()

	        case "new_workspace":
	            return newWorkspace()

	        case "new_split":
	            return newSplit(args)

        case "list_surfaces":
            return listSurfaces(args)

        case "focus_surface":
            return focusSurface(args)

        case "close_workspace":
            return closeWorkspace(args)

        case "select_workspace":
            return selectWorkspace(args)

        case "current_workspace":
            return currentWorkspace()

        case "send":
            return sendInput(args)

        case "send_key":
            return sendKey(args)

        case "send_surface":
            return sendInputToSurface(args)

        case "send_key_surface":
            return sendKeyToSurface(args)

        case "notify":
            return notifyCurrent(args)

        case "notify_surface":
            return notifySurface(args)

        case "notify_target":
            return notifyTarget(args)

        case "rainbow_banner":
            return triggerRainbowBanner(args)

        case "list_notifications":
            return listNotifications()

        case "clear_notifications":
            return clearNotifications()

        case "set_app_focus":
            return setAppFocusOverride(args)

        case "simulate_app_active":
            return simulateAppDidBecomeActive()

        case "set_status":
            return setStatus(args)

        case "clear_status":
            return clearStatus(args)

        case "list_status":
            return listStatus(args)

        case "log":
            return appendLog(args)

        case "clear_log":
            return clearLog(args)

        case "list_log":
            return listLog(args)

        case "set_progress":
            return setProgress(args)

        case "clear_progress":
            return clearProgress(args)

        case "report_git_branch":
            return reportGitBranch(args)

        case "clear_git_branch":
            return clearGitBranch(args)

        case "report_ports":
            return reportPorts(args)

        case "clear_ports":
            return clearPorts(args)

        case "report_tty":
            return reportTTY(args)

        case "ports_kick":
            return portsKick(args)

        case "report_pwd":
            return reportPwd(args)

        case "shell_integration_status":
            return shellIntegrationStatus(args)

        case "workspace_tag":
            return workspaceTag(args)

        case "sidebar_state":
            return sidebarState(args)

        case "reset_sidebar":
            return resetSidebar(args)

        case "read_screen":
            return readScreenText(args)


#if DEBUG
        case "set_shortcut":
            return setShortcut(args)

        case "simulate_shortcut":
            return simulateShortcut(args)

        case "simulate_type":
            return simulateType(args)

        case "simulate_file_drop":
            return simulateFileDrop(args)

        case "seed_drag_pasteboard_fileurl":
            return seedDragPasteboardFileURL()

        case "seed_drag_pasteboard_tabtransfer":
            return seedDragPasteboardTabTransfer()

        case "seed_drag_pasteboard_sidebar_reorder":
            return seedDragPasteboardSidebarReorder()

        case "seed_drag_pasteboard_types":
            return seedDragPasteboardTypes(args)

        case "clear_drag_pasteboard":
            return clearDragPasteboard()

        case "drop_hit_test":
            return dropHitTest(args)

        case "drag_hit_chain":
            return dragHitChain(args)

        case "overlay_hit_gate":
            return overlayHitGate(args)

        case "overlay_drop_gate":
            return overlayDropGate(args)

        case "portal_hit_gate":
            return portalHitGate(args)

        case "sidebar_overlay_gate":
            return sidebarOverlayGate(args)

        case "terminal_drop_overlay_probe":
            return terminalDropOverlayProbe(args)

        case "activate_app":
            return activateApp()

        case "is_terminal_focused":
            return isTerminalFocused(args)

        case "read_terminal_text":
            return readTerminalText(args)

        case "render_stats":
            return renderStats(args)

        case "layout_debug":
            return layoutDebug()

        case "bonsplit_underflow_count":
            return bonsplitUnderflowCount()

        case "reset_bonsplit_underflow_count":
            return resetBonsplitUnderflowCount()

        case "empty_panel_count":
            return emptyPanelCount()

        case "reset_empty_panel_count":
            return resetEmptyPanelCount()

        case "focus_notification":
            return focusFromNotification(args)

        case "flash_count":
            return flashCount(args)

        case "reset_flash_counts":
            return resetFlashCounts()

        case "panel_snapshot":
            return panelSnapshot(args)

        case "panel_snapshot_reset":
            return panelSnapshotReset(args)

        case "screenshot":
            return captureScreenshot(args)
#endif

        case "help":
            return helpText()

        // Browser panel commands
        case "open_browser":
            return openBrowser(args)

        case "navigate":
            return navigateBrowser(args)

        case "browser_back":
            return browserBack(args)

        case "browser_forward":
            return browserForward(args)

        case "browser_reload":
            return browserReload(args)

        case "get_url":
            return getUrl(args)

        case "focus_webview":
            return focusWebView(args)

        case "is_webview_focused":
            return isWebViewFocused(args)

        case "list_panes":
            return listPanes()

        case "list_pane_surfaces":
            return listPaneSurfaces(args)

	        case "focus_pane":
	            return focusPane(args)

	        case "focus_surface_by_panel":
	            return focusSurfaceByPanel(args)

	        case "drag_surface_to_split":
	            return dragSurfaceToSplit(args)

	        case "new_pane":
	            return newPane(args)

        case "new_surface":
            return newSurface(args)

        case "close_surface":
            return closeSurface(args)

        case "refresh_surfaces":
            return refreshSurfaces()

        case "surface_health":
            return surfaceHealth(args)

        default:
            return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
        }
        }

        #if DEBUG
        if cmd == "new_workspace" || cmd == "send" || cmd == "send_surface" {
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
            let status = response.hasPrefix("OK") ? "ok" : "err"
            dlog(
                "socket.v1 cmd=\(cmd) status=\(status) ms=\(String(format: "%.2f", elapsedMs)) main=\(Thread.isMainThread ? 1 : 0)"
            )
        }
        #endif

        return response
    }

    // MARK: - V2 JSON Socket Protocol

    private func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.

        guard let data = jsonLine.data(using: .utf8) else {
            return v2Encode(["ok": false, "error": ["code": "invalid_utf8", "message": "Invalid UTF-8"]])
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return v2Encode(["ok": false, "error": ["code": "parse_error", "message": "Invalid JSON"]])
        }

        guard let dict = object as? [String: Any] else {
            return v2Encode(["ok": false, "error": ["code": "invalid_request", "message": "Expected JSON object"]])
        }

        let id: Any? = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let params = dict["params"] as? [String: Any] ?? [:]

        guard !method.isEmpty else {
            return v2Error(id: id, code: "invalid_request", message: "Missing method")
        }

        // A remote leader process lives beside this app but its authoritative
        // team lives on the connected viewer. Route the scoped reverse RPC
        // before the generic team dispatcher; `peer.leader.call` is not a
        // local team mutation.
        if method == "peer.leader.call" {
            return dispatchPeerLeaderCall(params: params, id: id)
        }

        // ── Approach D: Async Team Dispatch ─────────────────────────────
        // ALL team commands are handled via async path. Data-only commands
        // use TeamDataStore directly (no main thread). UI commands use
        // cooperative `await MainActor.run` instead of blocking `DispatchQueue.main.sync`.
        // This eliminates deadlocks and minimizes main-thread hold time.
        if method.hasPrefix("team.") {
            return dispatchTeamCommandAsync(method: method, params: params, id: id)
        }

        // Refresh handle refs asynchronously to avoid blocking the socket thread.
        // Refs are also created lazily by v2EnsureHandleRef in each command's response,
        // so a stale cache only affects handle-based lookups (e.g., "window:1") — raw
        // UUID parameters always resolve immediately.
        DispatchQueue.main.async { self.v2RefreshKnownRefs() }


        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif

        let response = withSocketCommandPolicy(commandKey: method, isV2: true) {
            switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: id, result: v2Capabilities())

        case "system.info":
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "?"
            let build = info["CFBundleVersion"] as? String ?? "?"
            // The build phase stamps TermMeshCommit into the built plist
            // after compilation. BuildInfo.swift is therefore a one-build
            // fallback, not the runtime source of truth.
            let gitSHA = info["TermMeshCommit"] as? String ?? BuildInfo.gitSHA
            return v2Ok(id: id, result: [
                "app_version": version,
                "build_number": build,
                "git_sha": gitSHA,
            ])
        case "system.identify":
            return v2Ok(id: id, result: v2Identify(params: params))
        case "auth.login":
            return v2Ok(
                id: id,
                result: [
                    "authenticated": true,
                    "required": accessMode.requiresPasswordAuth
                ]
            )

        // Mission Control — one-shot fleet aggregate (teams × agents × tasks
        // × attention × approvals). Read-only synchronous snapshot, so
        // main-actor execution is allowed per the socket threading policy.
        case "fleet.state":
            return v2Ok(id: id, result: TeamOrchestrator.shared.fleetState())

        // Windows
        case "window.list":
            return v2Result(id: id, self.v2WindowList(params: params))
        case "window.current":
            return v2Result(id: id, self.v2WindowCurrent(params: params))
        case "window.focus":
            return v2Result(id: id, self.v2WindowFocus(params: params))
        case "window.create":
            return v2Result(id: id, self.v2WindowCreate(params: params))
        case "window.close":
            return v2Result(id: id, self.v2WindowClose(params: params))

        // Workspaces
        case "workspace.list":
            return v2Result(id: id, self.v2WorkspaceList(params: params))
        case "workspace.create":
            return v2Result(id: id, self.v2WorkspaceCreate(params: params))
        case "workspace.select":
            return v2Result(id: id, self.v2WorkspaceSelect(params: params))
        case "workspace.current":
            return v2Result(id: id, self.v2WorkspaceCurrent(params: params))
        case "workspace.close":
            return v2Result(id: id, self.v2WorkspaceClose(params: params))
        case "workspace.move_to_window":
            return v2Result(id: id, self.v2WorkspaceMoveToWindow(params: params))
        case "workspace.reorder":
            return v2Result(id: id, self.v2WorkspaceReorder(params: params))
        case "workspace.rename":
            return v2Result(id: id, self.v2WorkspaceRename(params: params))
        case "workspace.action":
            return v2Result(id: id, self.v2WorkspaceAction(params: params))
        case "workspace.next":
            return v2Result(id: id, self.v2WorkspaceNext(params: params))
        case "workspace.previous":
            return v2Result(id: id, self.v2WorkspacePrevious(params: params))
        case "workspace.last":
            return v2Result(id: id, self.v2WorkspaceLast(params: params))
        case "workspace.sidebar_state":
            return v2Result(id: id, self.v2WorkspaceSidebarState(params: params))


        // Surfaces / input
        case "surface.list":
            return v2Result(id: id, self.v2SurfaceList(params: params))
        case "surface.current":
            return v2Result(id: id, self.v2SurfaceCurrent(params: params))
        case "surface.focus":
            return v2Result(id: id, self.v2SurfaceFocus(params: params))
        case "surface.split":
            return v2Result(id: id, self.v2SurfaceSplit(params: params))
        case "surface.create":
            return v2Result(id: id, self.v2SurfaceCreate(params: params))
        case "surface.close":
            return v2Result(id: id, self.v2SurfaceClose(params: params))
        case "surface.move":
            return v2Result(id: id, self.v2SurfaceMove(params: params))
        case "surface.reorder":
            return v2Result(id: id, self.v2SurfaceReorder(params: params))
        case "surface.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "tab.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "surface.drag_to_split":
            return v2Result(id: id, self.v2SurfaceDragToSplit(params: params))
        case "surface.refresh":
            return v2Result(id: id, self.v2SurfaceRefresh(params: params))
        case "surface.rebuild_renderer":
            return v2Result(id: id, self.v2SurfaceRebuildRenderer(params: params))
        case "surface.health":
            return v2Result(id: id, self.v2SurfaceHealth(params: params))
        case "surface.send_text":
            return v2Result(id: id, self.v2SurfaceSendText(params: params))
        case "surface.send_key":
            return v2Result(id: id, self.v2SurfaceSendKey(params: params))
        case "surface.clear_history":
            return v2Result(id: id, self.v2SurfaceClearHistory(params: params))
        case "surface.trigger_flash":
            return v2Result(id: id, self.v2SurfaceTriggerFlash(params: params))

        // Panes
        case "pane.list":
            return v2Result(id: id, self.v2PaneList(params: params))
        case "pane.focus":
            return v2Result(id: id, self.v2PaneFocus(params: params))
        case "pane.surfaces":
            return v2Result(id: id, self.v2PaneSurfaces(params: params))
        case "pane.create":
            return v2Result(id: id, self.v2PaneCreate(params: params))
        case "pane.resize":
            return v2Result(id: id, self.v2PaneResize(params: params))
        case "pane.swap":
            return v2Result(id: id, self.v2PaneSwap(params: params))
        case "pane.break":
            return v2Result(id: id, self.v2PaneBreak(params: params))
        case "pane.join":
            return v2Result(id: id, self.v2PaneJoin(params: params))
        case "pane.last":
            return v2Result(id: id, self.v2PaneLast(params: params))

        // Agent Teams
        case "team.create":
            return v2Result(id: id, self.v2TeamCreate(params: params))
        case "team.list":
            return v2Result(id: id, self.v2TeamList(params: params))
        case "team.status":
            return v2Result(id: id, self.v2TeamStatus(params: params))
        case "team.leader.send":
            return v2Result(id: id, self.v2TeamLeaderSend(params: params))
        case "team.send":
            return v2Result(id: id, self.v2TeamSend(params: params))
        case "team.broadcast":
            return v2Result(id: id, self.v2TeamBroadcast(params: params))
        case "team.destroy":
            return v2Result(id: id, self.v2TeamDestroy(params: params))

        // Agent Team Bidirectional Communication
        case "team.read":
            return v2Result(id: id, self.v2TeamRead(params: params))
        case "team.collect":
            return v2Result(id: id, self.v2TeamCollect(params: params))
        case "team.report":
            return v2Result(id: id, self.v2TeamReport(params: params))
        case "team.result.status":
            return v2Result(id: id, self.v2TeamResultStatus(params: params))
        case "team.result.collect":
            return v2Result(id: id, self.v2TeamResultCollect(params: params))
        case "team.message.post":
            return v2Result(id: id, self.v2TeamMessagePost(params: params))
        case "team.message.list":
            return v2Result(id: id, self.v2TeamMessageList(params: params))
        case "team.message.clear":
            return v2Result(id: id, self.v2TeamMessageClear(params: params))
        case "team.inbox":
            return v2Result(id: id, self.v2TeamInbox(params: params))
        case "team.agent.heartbeat":
            return v2Result(id: id, self.v2TeamAgentHeartbeat(params: params))
        case "team.agent.status":
            return v2Result(id: id, self.v2TeamAgentStatus(params: params))
        case "team.task.get":
            return v2Result(id: id, self.v2TeamTaskGet(params: params))
        case "team.task.start":
            return v2Result(id: id, self.v2TeamTaskStart(params: params))
        case "team.task.block":
            return v2Result(id: id, self.v2TeamTaskBlock(params: params))
        case "team.task.review":
            return v2Result(id: id, self.v2TeamTaskReview(params: params))
        case "team.task.done":
            return v2Result(id: id, self.v2TeamTaskDone(params: params))
        case "team.task.reassign":
            return v2Result(id: id, self.v2TeamTaskReassign(params: params))
        case "team.task.unblock":
            return v2Result(id: id, self.v2TeamTaskUnblock(params: params))
        case "team.task.split":
            return v2Result(id: id, self.v2TeamTaskSplit(params: params))
        case "team.task.dependents":
            return v2Result(id: id, self.v2TeamTaskDependents(params: params))
        case "team.task.create":
            return v2Result(id: id, self.v2TeamTaskCreate(params: params))
        case "team.task.update":
            return v2Result(id: id, self.v2TeamTaskUpdate(params: params))
        case "team.task.list":
            return v2Result(id: id, self.v2TeamTaskList(params: params))
        case "team.task.clear":
            return v2Result(id: id, self.v2TeamTaskClear(params: params))
        case "team.context.set":
            return v2Result(id: id, self.v2TeamContextSet(params: params))
        case "team.context.get":
            return v2Result(id: id, self.v2TeamContextGet(params: params))
        case "team.context.list":
            return v2Result(id: id, self.v2TeamContextList(params: params))

        // Notifications
        case "notification.create":
            return v2Result(id: id, self.v2NotificationCreate(params: params))
        case "notification.create_for_surface":
            return v2Result(id: id, self.v2NotificationCreateForSurface(params: params))
        case "notification.create_for_target":
            return v2Result(id: id, self.v2NotificationCreateForTarget(params: params))
        case "notification.list":
            return v2Ok(id: id, result: self.v2NotificationList())
        case "notification.clear":
            return v2Result(id: id, self.v2NotificationClear())

        // App focus
        case "app.focus_override.set":
            return v2Result(id: id, self.v2AppFocusOverride(params: params))
        case "app.simulate_active":
            return v2Result(id: id, self.v2AppSimulateActive())

        // Browser
        case "browser.open_split":
            return v2Result(id: id, self.v2BrowserOpenSplit(params: params))
        case "browser.navigate":
            return v2Result(id: id, self.v2BrowserNavigate(params: params))
        case "browser.back":
            return v2Result(id: id, self.v2BrowserBack(params: params))
        case "browser.forward":
            return v2Result(id: id, self.v2BrowserForward(params: params))
        case "browser.reload":
            return v2Result(id: id, self.v2BrowserReload(params: params))
        case "browser.url.get":
            return v2Result(id: id, self.v2BrowserGetURL(params: params))
        case "browser.focus_webview":
            return v2Result(id: id, self.v2BrowserFocusWebView(params: params))
        case "browser.is_webview_focused":
            return v2Result(id: id, self.v2BrowserIsWebViewFocused(params: params))
        case "browser.snapshot":
            return v2Result(id: id, self.v2BrowserSnapshot(params: params))
        case "browser.eval":
            return v2Result(id: id, self.v2BrowserEval(params: params))
        case "browser.wait":
            return v2Result(id: id, self.v2BrowserWait(params: params))
        case "browser.click":
            return v2Result(id: id, self.v2BrowserClick(params: params))
        case "browser.dblclick":
            return v2Result(id: id, self.v2BrowserDblClick(params: params))
        case "browser.hover":
            return v2Result(id: id, self.v2BrowserHover(params: params))
        case "browser.focus":
            return v2Result(id: id, self.v2BrowserFocusElement(params: params))
        case "browser.type":
            return v2Result(id: id, self.v2BrowserType(params: params))
        case "browser.fill":
            return v2Result(id: id, self.v2BrowserFill(params: params))
        case "browser.press":
            return v2Result(id: id, self.v2BrowserPress(params: params))
        case "browser.keydown":
            return v2Result(id: id, self.v2BrowserKeyDown(params: params))
        case "browser.keyup":
            return v2Result(id: id, self.v2BrowserKeyUp(params: params))
        case "browser.check":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: true))
        case "browser.uncheck":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: false))
        case "browser.select":
            return v2Result(id: id, self.v2BrowserSelect(params: params))
        case "browser.scroll":
            return v2Result(id: id, self.v2BrowserScroll(params: params))
        case "browser.scroll_into_view":
            return v2Result(id: id, self.v2BrowserScrollIntoView(params: params))
        case "browser.screenshot":
            return v2Result(id: id, self.v2BrowserScreenshot(params: params))
        case "browser.get.text":
            return v2Result(id: id, self.v2BrowserGetText(params: params))
        case "browser.get.html":
            return v2Result(id: id, self.v2BrowserGetHTML(params: params))
        case "browser.get.value":
            return v2Result(id: id, self.v2BrowserGetValue(params: params))
        case "browser.get.attr":
            return v2Result(id: id, self.v2BrowserGetAttr(params: params))
        case "browser.get.title":
            return v2Result(id: id, self.v2BrowserGetTitle(params: params))
        case "browser.get.count":
            return v2Result(id: id, self.v2BrowserGetCount(params: params))
        case "browser.get.box":
            return v2Result(id: id, self.v2BrowserGetBox(params: params))
        case "browser.get.styles":
            return v2Result(id: id, self.v2BrowserGetStyles(params: params))
        case "browser.is.visible":
            return v2Result(id: id, self.v2BrowserIsVisible(params: params))
        case "browser.is.enabled":
            return v2Result(id: id, self.v2BrowserIsEnabled(params: params))
        case "browser.is.checked":
            return v2Result(id: id, self.v2BrowserIsChecked(params: params))
        case "browser.find.role":
            return v2Result(id: id, self.v2BrowserFindRole(params: params))
        case "browser.find.text":
            return v2Result(id: id, self.v2BrowserFindText(params: params))
        case "browser.find.label":
            return v2Result(id: id, self.v2BrowserFindLabel(params: params))
        case "browser.find.placeholder":
            return v2Result(id: id, self.v2BrowserFindPlaceholder(params: params))
        case "browser.find.alt":
            return v2Result(id: id, self.v2BrowserFindAlt(params: params))
        case "browser.find.title":
            return v2Result(id: id, self.v2BrowserFindTitle(params: params))
        case "browser.find.testid":
            return v2Result(id: id, self.v2BrowserFindTestId(params: params))
        case "browser.find.first":
            return v2Result(id: id, self.v2BrowserFindFirst(params: params))
        case "browser.find.last":
            return v2Result(id: id, self.v2BrowserFindLast(params: params))
        case "browser.find.nth":
            return v2Result(id: id, self.v2BrowserFindNth(params: params))
        case "browser.frame.select":
            return v2Result(id: id, self.v2BrowserFrameSelect(params: params))
        case "browser.frame.main":
            return v2Result(id: id, self.v2BrowserFrameMain(params: params))
        case "browser.dialog.accept":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: true))
        case "browser.dialog.dismiss":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: false))
        case "browser.download.wait":
            return v2Result(id: id, self.v2BrowserDownloadWait(params: params))
        case "browser.cookies.get":
            return v2Result(id: id, self.v2BrowserCookiesGet(params: params))
        case "browser.cookies.set":
            return v2Result(id: id, self.v2BrowserCookiesSet(params: params))
        case "browser.cookies.clear":
            return v2Result(id: id, self.v2BrowserCookiesClear(params: params))
        case "browser.storage.get":
            return v2Result(id: id, self.v2BrowserStorageGet(params: params))
        case "browser.storage.set":
            return v2Result(id: id, self.v2BrowserStorageSet(params: params))
        case "browser.storage.clear":
            return v2Result(id: id, self.v2BrowserStorageClear(params: params))
        case "browser.tab.new":
            return v2Result(id: id, self.v2BrowserTabNew(params: params))
        case "browser.tab.list":
            return v2Result(id: id, self.v2BrowserTabList(params: params))
        case "browser.tab.switch":
            return v2Result(id: id, self.v2BrowserTabSwitch(params: params))
        case "browser.tab.close":
            return v2Result(id: id, self.v2BrowserTabClose(params: params))
        case "browser.console.list":
            return v2Result(id: id, self.v2BrowserConsoleList(params: params))
        case "browser.console.clear":
            return v2Result(id: id, self.v2BrowserConsoleClear(params: params))
        case "browser.errors.list":
            return v2Result(id: id, self.v2BrowserErrorsList(params: params))
        case "browser.highlight":
            return v2Result(id: id, self.v2BrowserHighlight(params: params))
        case "browser.state.save":
            return v2Result(id: id, self.v2BrowserStateSave(params: params))
        case "browser.state.load":
            return v2Result(id: id, self.v2BrowserStateLoad(params: params))
        case "browser.addinitscript":
            return v2Result(id: id, self.v2BrowserAddInitScript(params: params))
        case "browser.addscript":
            return v2Result(id: id, self.v2BrowserAddScript(params: params))
        case "browser.addstyle":
            return v2Result(id: id, self.v2BrowserAddStyle(params: params))
        case "browser.viewport.set":
            return v2Result(id: id, self.v2BrowserViewportSet(params: params))
        case "browser.geolocation.set":
            return v2Result(id: id, self.v2BrowserGeolocationSet(params: params))
        case "browser.offline.set":
            return v2Result(id: id, self.v2BrowserOfflineSet(params: params))
        case "browser.trace.start":
            return v2Result(id: id, self.v2BrowserTraceStart(params: params))
        case "browser.trace.stop":
            return v2Result(id: id, self.v2BrowserTraceStop(params: params))
        case "browser.network.route":
            return v2Result(id: id, self.v2BrowserNetworkRoute(params: params))
        case "browser.network.unroute":
            return v2Result(id: id, self.v2BrowserNetworkUnroute(params: params))
        case "browser.network.requests":
            return v2Result(id: id, self.v2BrowserNetworkRequests(params: params))
        case "browser.screencast.start":
            return v2Result(id: id, self.v2BrowserScreencastStart(params: params))
        case "browser.screencast.stop":
            return v2Result(id: id, self.v2BrowserScreencastStop(params: params))
        case "browser.input_mouse":
            return v2Result(id: id, self.v2BrowserInputMouse(params: params))
        case "browser.input_keyboard":
            return v2Result(id: id, self.v2BrowserInputKeyboard(params: params))
        case "browser.input_touch":
            return v2Result(id: id, self.v2BrowserInputTouch(params: params))
        case "surface.read_text":
            return v2Result(id: id, self.v2SurfaceReadText(params: params))

        // Peer-federation saved hosts. Not DEBUG-gated: unlike the
        // `debug.peer.*` family below (raw socket paths, bypassing
        // RemoteHostStore), these drive the same store the sidebar does, so
        // they are the supported way to script a peer host.
        case "peer.host.list":
            return v2Result(id: id, self.v2PeerHostList(params: params))
        case "peer.host.connect":
            return v2Result(id: id, self.v2PeerHostConnect(params: params))
        case "peer.host.retry":
            return v2Result(id: id, self.v2PeerHostRetry(params: params))
        case "peer.host.cancel":
            return v2Result(id: id, self.v2PeerHostCancel(params: params))
        case "peer.host.disconnect":
            return v2Result(id: id, self.v2PeerHostDisconnect(params: params))
        case "peer.host.force_disconnect":
            return v2Result(id: id, self.v2PeerHostForceDisconnect(params: params))
        case "peer.surface.open_pane":
            return v2Result(id: id, self.v2PeerSurfaceOpenPane(params: params))
        case "peer.pane.status":
            return v2Result(id: id, self.v2PeerPaneStatus(params: params))
        case "peer.workspace.open_mirror":
            return v2Result(id: id, self.v2PeerWorkspaceOpenMirror(params: params))
        case "peer.mirror.status":
            return v2Result(id: id, self.v2PeerMirrorStatus(params: params))

#if DEBUG
        // Debug / test-only
        case "debug.shortcut.set":
            return v2Result(id: id, self.v2DebugShortcutSet(params: params))
        case "debug.shortcut.simulate":
            return v2Result(id: id, self.v2DebugShortcutSimulate(params: params))
        case "debug.type":
            return v2Result(id: id, self.v2DebugType(params: params))
        case "debug.app.activate":
            return v2Result(id: id, self.v2DebugActivateApp())
        case "debug.app.build":
            return v2Result(id: id, self.v2DebugAppBuild())
        case "debug.command_palette.toggle":
            return v2Result(id: id, self.v2DebugToggleCommandPalette(params: params))
        case "debug.agent.transcript":
            return v2Result(id: id, self.v2DebugAgentTranscript(params: params))
        case "debug.agent.render_stats":
            return v2Result(id: id, self.v2DebugAgentRenderStats(params: params))
        case "debug.terminal.renderer_states":
            return v2Result(id: id, self.v2DebugTerminalRendererStates())
        case "debug.command_palette.rename_tab.open":
            return v2Result(id: id, self.v2DebugOpenCommandPaletteRenameTabInput(params: params))
        case "debug.command_palette.visible":
            return v2Result(id: id, self.v2DebugCommandPaletteVisible(params: params))
        case "debug.command_palette.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteSelection(params: params))
        case "debug.command_palette.results":
            return v2Result(id: id, self.v2DebugCommandPaletteResults(params: params))
        case "debug.command_palette.set_query":
            return v2Result(id: id, self.v2DebugCommandPaletteSetQuery(params: params))
        case "debug.blank_recovery.state":
            return v2Result(id: id, self.v2DebugBlankRecoveryState(params: params))
        case "debug.command_palette.rename_input.interact":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputInteraction(params: params))
        case "debug.command_palette.rename_input.delete_backward":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputDeleteBackward(params: params))
        case "debug.command_palette.rename_input.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelection(params: params))
        case "debug.command_palette.rename_input.select_all":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelectAll(params: params))
        case "debug.sidebar.visible":
            return v2Result(id: id, self.v2DebugSidebarVisible(params: params))
        case "debug.terminal.is_focused":
            return v2Result(id: id, self.v2DebugIsTerminalFocused(params: params))
        case "debug.terminal.read_text":
            return v2Result(id: id, self.v2DebugReadTerminalText(params: params))
        case "debug.terminal.render_stats":
            return v2Result(id: id, self.v2DebugRenderStats(params: params))
        case "debug.terminal.drop_overlay_probe":
            return v2Result(id: id, self.v2DebugTerminalDropOverlayProbe(params: params))
        case "debug.layout":
            return v2Result(id: id, self.v2DebugLayout())
        case "debug.bonsplit_underflow.count":
            return v2Result(id: id, self.v2DebugBonsplitUnderflowCount())
        case "debug.bonsplit_underflow.reset":
            return v2Result(id: id, self.v2DebugResetBonsplitUnderflowCount())
        case "debug.empty_panel.count":
            return v2Result(id: id, self.v2DebugEmptyPanelCount())
        case "debug.empty_panel.reset":
            return v2Result(id: id, self.v2DebugResetEmptyPanelCount())
        case "debug.notification.focus":
            return v2Result(id: id, self.v2DebugFocusNotification(params: params))
        // The delegate sheet is a SwiftUI action, so calling what the sheet
        // calls is the only way to exercise the whole path — team, capsule,
        // coordinator registration, placement — without a person clicking.
        case "debug.team.attach_remote":
            return v2Result(id: id, self.v2DebugTeamAttachRemote(params: params))
        case "debug.project.create":
            return v2Result(id: id, self.v2DebugProjectCreate(params: params))
        case "debug.project.delete":
            return v2Result(id: id, self.v2DebugProjectDelete(params: params))
        case "debug.project.reattach_leader":
            return v2Result(id: id, self.v2DebugProjectReattachLeader(params: params))
        case "debug.project.restore_presentation":
            return v2Result(id: id, self.v2DebugProjectRestorePresentation(params: params))
        case "debug.peer.shells.inspect":
            return v2Result(id: id, self.v2DebugPeerShellInspect(params: params))
        case "debug.peer.shells.close":
            return v2Result(id: id, self.v2DebugPeerShellClose(params: params))
        case "debug.peer.shells.status":
            return v2Result(id: id, self.v2DebugPeerShellStatus())
        case "debug.reviewboard.delegate":
            return v2Result(id: id, self.v2DebugReviewBoardDelegate(params: params))
        case "debug.reviewboard.reveal":
            return v2Result(id: id, self.v2DebugReviewBoardReveal(params: params))
        case "debug.flash.count":
            return v2Result(id: id, self.v2DebugFlashCount(params: params))
        case "debug.flash.reset":
            return v2Result(id: id, self.v2DebugResetFlashCounts())
        case "debug.peer.browse_wheel":
            return v2Result(id: id, self.v2DebugPeerBrowseWheel(params: params))
        case "debug.peer.inject_input":
            return v2Result(id: id, self.v2DebugPeerInjectInput(params: params))
        case "debug.peer.demux_probe":
            return v2Result(id: id, self.v2DebugPeerDemuxProbe(params: params))
        case "debug.peer.read_grid":
            return v2Result(id: id, self.v2DebugPeerReadGrid(params: params))
        case "debug.peer.replay_probe":
            return v2Result(id: id, self.v2DebugPeerReplayProbe(params: params))
        case "debug.peer.coalesce_probe":
            return v2Result(id: id, self.v2DebugPeerCoalesceProbe(params: params))
        case "debug.peer.capabilities_probe":
            return v2Result(id: id, self.v2DebugPeerCapabilitiesProbe(params: params))
        case "debug.peer.open_remote_pane":
            return v2Result(id: id, self.v2DebugPeerOpenRemotePane(params: params))
        case "debug.session_host.reconcile":
            return v2Result(id: id, self.v2DebugSessionHostReconcile())
        case "debug.peer.open_workspace_mirror":
            return v2Result(id: id, self.v2DebugPeerOpenWorkspaceMirror(params: params))
        case "debug.peer.mirror_status":
            return v2Result(id: id, self.v2DebugPeerMirrorStatus(params: params))
        case "debug.peer.pane_status":
            return v2Result(id: id, self.v2DebugPeerPaneStatus(params: params))
        case "debug.panel_snapshot":
            return v2Result(id: id, self.v2DebugPanelSnapshot(params: params))
        case "debug.panel_snapshot.reset":
            return v2Result(id: id, self.v2DebugPanelSnapshotReset(params: params))
        case "debug.window.screenshot":
            return v2Result(id: id, self.v2DebugScreenshot(params: params))
        case "debug.drag.simulate_file_drop":
            return v2Result(id: id, self.v2DebugDragSimulateFileDrop(params: params))
        case "debug.drag.seed_pasteboard", "debug.drag_pasteboard.seed":
            return v2Result(id: id, self.v2DebugDragSeedPasteboard(params: params))
        case "debug.drag.clear_pasteboard", "debug.drag_pasteboard.clear":
            return v2Result(id: id, self.v2DebugDragClearPasteboard())
        case "debug.drag.overlay_hit_gate":
            return v2Result(id: id, self.v2DebugDragOverlayHitGate(params: params))
        case "debug.drag.overlay_drop_gate":
            return v2Result(id: id, self.v2DebugDragOverlayDropGate(params: params))
        case "debug.drag.portal_hit_gate":
            return v2Result(id: id, self.v2DebugDragPortalHitGate(params: params))
        case "debug.drag.sidebar_overlay_gate":
            return v2Result(id: id, self.v2DebugDragSidebarOverlayGate(params: params))
        case "debug.drag.drop_hit_test":
            return v2Result(id: id, self.v2DebugDragDropHitTest(params: params))
        case "debug.drag.drag_hit_chain":
            return v2Result(id: id, self.v2DebugDragHitChain(params: params))
#endif

        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
        }

        #if DEBUG
        if method == "workspace.create" || method == "surface.send_text" {
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
            let status = response.contains("\"ok\":true") ? "ok" : "err"
            dlog(
                "socket.v2 method=\(method) status=\(status) ms=\(String(format: "%.2f", elapsedMs)) main=\(Thread.isMainThread ? 1 : 0)"
            )
        }
        #endif

        return response
    }

    private func v2Capabilities() -> [String: Any] {
        var methods: [String] = [
            "system.ping",
            "system.capabilities",
            "system.identify",
            "auth.login",
            "fleet.state",
            "window.list",
            "window.current",
            "window.focus",
            "window.create",
            "window.close",
            "workspace.list",
            "workspace.create",
            "workspace.select",
            "workspace.current",
            "workspace.close",
            "workspace.move_to_window",
            "workspace.reorder",
            "workspace.rename",
            "workspace.action",
            "workspace.next",
            "workspace.previous",
            "workspace.last",
            "workspace.sidebar_state",
            "surface.list",
            "surface.current",
            "surface.focus",
            "surface.split",
            "surface.create",
            "surface.close",
            "surface.drag_to_split",
            "surface.move",
            "surface.reorder",
            "surface.action",
            "tab.action",
            "surface.refresh",
            "surface.rebuild_renderer",
            "surface.health",
            "surface.send_text",
            "surface.send_key",
            "surface.read_text",
            "peer.host.list",
            "peer.host.connect",
            "peer.host.retry",
            "peer.host.cancel",
            "peer.host.disconnect",
            "peer.host.force_disconnect",
            "peer.surface.open_pane",
            "peer.pane.status",
            "peer.workspace.open_mirror",
            "peer.mirror.status",
            "surface.clear_history",
            "surface.trigger_flash",
            "pane.list",
            "pane.focus",
            "pane.surfaces",
            "pane.create",
            "pane.resize",
            "pane.swap",
            "pane.break",
            "pane.join",
            "pane.last",
            "notification.create",
            "notification.create_for_surface",
            "notification.create_for_target",
            "notification.list",
            "notification.clear",
            "app.focus_override.set",
            "app.simulate_active",
            "browser.open_split",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
            "browser.url.get",
            "browser.snapshot",
            "browser.eval",
            "browser.wait",
            "browser.click",
            "browser.dblclick",
            "browser.hover",
            "browser.focus",
            "browser.type",
            "browser.fill",
            "browser.press",
            "browser.keydown",
            "browser.keyup",
            "browser.check",
            "browser.uncheck",
            "browser.select",
            "browser.scroll",
            "browser.scroll_into_view",
            "browser.screenshot",
            "browser.get.text",
            "browser.get.html",
            "browser.get.value",
            "browser.get.attr",
            "browser.get.title",
            "browser.get.count",
            "browser.get.box",
            "browser.get.styles",
            "browser.is.visible",
            "browser.is.enabled",
            "browser.is.checked",
            "browser.focus_webview",
            "browser.is_webview_focused",
            "browser.find.role",
            "browser.find.text",
            "browser.find.label",
            "browser.find.placeholder",
            "browser.find.alt",
            "browser.find.title",
            "browser.find.testid",
            "browser.find.first",
            "browser.find.last",
            "browser.find.nth",
            "browser.frame.select",
            "browser.frame.main",
            "browser.dialog.accept",
            "browser.dialog.dismiss",
            "browser.download.wait",
            "browser.cookies.get",
            "browser.cookies.set",
            "browser.cookies.clear",
            "browser.storage.get",
            "browser.storage.set",
            "browser.storage.clear",
            "browser.tab.new",
            "browser.tab.list",
            "browser.tab.switch",
            "browser.tab.close",
            "browser.console.list",
            "browser.console.clear",
            "browser.errors.list",
            "browser.highlight",
            "browser.state.save",
            "browser.state.load",
            "browser.addinitscript",
            "browser.addscript",
            "browser.addstyle",
            "browser.viewport.set",
            "browser.geolocation.set",
            "browser.offline.set",
            "browser.trace.start",
            "browser.trace.stop",
            "browser.network.route",
            "browser.network.unroute",
            "browser.network.requests",
            "browser.screencast.start",
            "browser.screencast.stop",
            "browser.input_mouse",
            "browser.input_keyboard",
            "browser.input_touch",
        ]
#if DEBUG
        methods.append(contentsOf: [
            "debug.shortcut.set",
            "debug.shortcut.simulate",
            "debug.type",
            "debug.app.activate",
            "debug.app.build",
            "debug.command_palette.toggle",
            "debug.agent.transcript",
            "debug.agent.render_stats",
            "debug.terminal.renderer_states",
            "debug.command_palette.rename_tab.open",
            "debug.command_palette.visible",
            "debug.command_palette.selection",
            "debug.command_palette.results",
            "debug.command_palette.set_query",
            "debug.blank_recovery.state",
            "debug.command_palette.rename_input.interact",
            "debug.command_palette.rename_input.delete_backward",
            "debug.command_palette.rename_input.selection",
            "debug.command_palette.rename_input.select_all",
            "debug.sidebar.visible",
            "debug.terminal.is_focused",
            "debug.terminal.read_text",
            "debug.terminal.render_stats",
            "debug.terminal.drop_overlay_probe",
            "debug.layout",
            "debug.bonsplit_underflow.count",
            "debug.bonsplit_underflow.reset",
            "debug.empty_panel.count",
            "debug.empty_panel.reset",
            "debug.notification.focus",
            "debug.flash.count",
            "debug.flash.reset",
            "debug.peer.inject_input",
            "debug.peer.read_grid",
            "debug.peer.replay_probe",
            "debug.peer.coalesce_probe",
            "debug.peer.capabilities_probe",
            "debug.panel_snapshot",
            "debug.panel_snapshot.reset",
            "debug.window.screenshot",
            "debug.drag.simulate_file_drop",
            "debug.drag.seed_pasteboard",
            "debug.drag.clear_pasteboard",
            "debug.drag.overlay_hit_gate",
            "debug.drag.overlay_drop_gate",
            "debug.drag.portal_hit_gate",
            "debug.drag.sidebar_overlay_gate",
            "debug.drag.drop_hit_test",
            "debug.drag.drag_hit_chain",
            "debug.drag_pasteboard.seed",
            "debug.drag_pasteboard.clear",
        ])
#endif

        return [
            "protocol": "term-mesh-socket",
            "version": 2,
            "socket_path": socketPath,
            "access_mode": accessMode.rawValue,
            "methods": methods.sorted()
        ]
    }

    private func v2Identify(params: [String: Any]) -> [String: Any] {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return [
                "socket_path": socketPath,
                "focused": NSNull(),
                "caller": NSNull()
            ]
        }

        var focused: [String: Any] = [:]
        v2MainSync {
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            if let wsId = tabManager.selectedTabId,
               let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                let paneUUID = ws.bonsplitController.focusedPaneId?.id
                let surfaceUUID = ws.focusedPanelId
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": wsId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "surface_id": v2OrNull(surfaceUUID?.uuidString),
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceUUID),
                    "tab_id": v2OrNull(surfaceUUID?.uuidString),
                    "tab_ref": v2TabRef(uuid: surfaceUUID),
                    "surface_type": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType.rawValue }),
                    "is_browser_surface": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType == .browser })
                ]
            } else {
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
            }
        }

        // Optionally validate a caller-provided location (useful for agents calling from inside a surface).
        var resolvedCaller: [String: Any]? = nil
        if let callerObj = params["caller"] as? [String: Any],
           let wsId = v2UUIDAny(callerObj["workspace_id"]) {
            let surfaceId = v2UUIDAny(callerObj["surface_id"]) ?? v2UUIDAny(callerObj["tab_id"])
            v2MainSync {
                let callerTabManager = AppDelegate.shared?.tabManagerFor(tabId: wsId) ?? tabManager
                if let ws = callerTabManager.tabs.first(where: { $0.id == wsId }) {
                    let callerWindowId = v2ResolveWindowId(tabManager: callerTabManager)
                    var payload: [String: Any] = [
                        "window_id": v2OrNull(callerWindowId?.uuidString),
                        "window_ref": v2Ref(kind: .window, uuid: callerWindowId),
                        "workspace_id": wsId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
                    ]

                    if let surfaceId, ws.panels[surfaceId] != nil {
                        let paneUUID = ws.paneId(forPanelId: surfaceId)?.id
                        payload["surface_id"] = surfaceId.uuidString
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        payload["tab_id"] = surfaceId.uuidString
                        payload["tab_ref"] = v2TabRef(uuid: surfaceId)
                        payload["surface_type"] = v2OrNull(ws.panels[surfaceId]?.panelType.rawValue)
                        payload["is_browser_surface"] = v2OrNull(ws.panels[surfaceId]?.panelType == .browser)
                        payload["pane_id"] = v2OrNull(paneUUID?.uuidString)
                        payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneUUID)
                    } else {
                        payload["surface_id"] = NSNull()
                        payload["surface_ref"] = NSNull()
                        payload["tab_id"] = NSNull()
                        payload["tab_ref"] = NSNull()
                        payload["surface_type"] = NSNull()
                        payload["is_browser_surface"] = NSNull()
                        payload["pane_id"] = NSNull()
                        payload["pane_ref"] = NSNull()
                    }
                    resolvedCaller = payload
                }
            }
        }

        return [
            "socket_path": socketPath,
            "focused": focused.isEmpty ? NSNull() : focused,
            "caller": v2OrNull(resolvedCaller)
        ]
    }

    // MARK: - V2 Helpers (encoding + result plumbing)

    func v2OrNull(_ value: Any?) -> Any {
        // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
        if let value { return value }
        return NSNull()
    }

    func v2MainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    /// Like v2MainSync but with a timeout to prevent deadlocks when the main thread
    /// is blocked by IME composition or modal event loops.
    ///
    /// Returns `true` if `body` executed and completed within the timeout.
    /// Returns `false` if the main thread did not respond in time — in this case
    /// `body` is guaranteed **not** to have run (safe to ignore captured results).
    ///
    /// Use for high-frequency socket commands (send_text, send_key, read_text) that
    /// may contend with user input on the main thread.
    func v2MainExec(timeout: TimeInterval = 2.0, _ body: @escaping () -> Void) -> Bool {
        if Thread.isMainThread {
            body()
            return true
        }
        let state = NSLock()
        var cancelled = false
        var started = false
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            state.lock()
            let skip = cancelled
            if !skip { started = true }
            state.unlock()
            if !skip { body() }
            sema.signal()
        }
        if sema.wait(timeout: .now() + timeout) == .timedOut {
            state.lock()
            cancelled = true
            let didStart = started
            state.unlock()
            if didStart {
                // body() already started before we could cancel — wait for it
                // to finish so the caller can safely read captured results.
                // Use a generous secondary timeout so a hanging body() can't
                // block this thread indefinitely.
                _ = sema.wait(timeout: .now() + timeout * 4)
                return true
            }
            return false
        }
        return true
    }

    func v2Ok(id: Any?, result: Any) -> String {
        return v2Encode([
            "id": v2OrNull(id),
            "ok": true,
            "result": result
        ])
    }

    func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        var err: [String: Any] = ["code": code, "message": message]
        if let data {
            err["data"] = data
        }
        return v2Encode([
            "id": v2OrNull(id),
            "ok": false,
            "error": err
        ])
    }

    enum V2CallResult {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }

    func v2Result(id: Any?, _ res: V2CallResult) -> String {
        switch res {
        case .ok(let payload):
            return v2Ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    func v2Encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var s = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }

        // Ensure single-line responses for the line-oriented socket protocol.
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        return s
    }

    private func dispatchPeerLeaderCall(
        params: [String: Any],
        id: Any?
    ) -> String {
        guard let grantID = Self.decodeFixedHex(
            params["grant_id_hex"] as? String,
            byteCount: PeerTeamLeader.grantIDBytes
        ),
        let targetPeerID = Self.decodeFixedHex(
            params["target_peer_id_hex"] as? String,
            byteCount: PeerIdentity.byteCount
        ),
        let requestID = Self.decodeFixedHex(
            params["request_id_hex"] as? String,
            byteCount: PeerTeamLeader.requestIDBytes
        ),
        let projectID = params["project_id"] as? String,
        let teamUUID = params["team_uuid"] as? String,
        let method = params["method"] as? String,
        let paramsJSON = params["params_json"] as? String,
        let expiresNumber = params["expires_at_unix_secs"] as? NSNumber else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: "invalid remote leader route"
            )
        }

        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = grantID
        grant.projectID = projectID
        grant.teamUuid = teamUUID
        grant.role = .leader
        grant.expiresAtUnixSecs = expiresNumber.uint64Value
        var request = Termmesh_Peer_V1_TeamLeaderCommandRequest()
        request.grant = grant
        request.teamUuid = teamUUID
        request.requestID = requestID
        request.method = method
        request.paramsJson = paramsJSON

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome:
            Result<Termmesh_Peer_V1_TeamLeaderCommandResponse, Error>?
        let task = Task {
            defer { semaphore.signal() }
            do {
                outcome = .success(
                    try await PeerHostCoordinator.shared.callTeamLeader(
                        request,
                        targetPeerID: targetPeerID,
                        timeoutSeconds: 10
                    )
                )
            } catch {
                outcome = .failure(error)
            }
        }
        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "remote leader proxy timed out"
            )
        }
        guard let outcome else {
            return v2Error(
                id: id,
                code: "internal_error",
                message: "remote leader proxy produced no result"
            )
        }
        switch outcome {
        case .failure(let error):
            return v2Error(
                id: id,
                code: "peer_leader_unavailable",
                message: String(describing: error)
            )
        case .success(let response):
            let result: Any
            if let data = response.resultJson.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) {
                result = decoded
            } else {
                result = [:]
            }
            return v2Ok(id: id, result: [
                "ok": response.ok,
                "cached": response.cached,
                "result": result,
                "error_code": response.errorCode,
                "error_message": response.errorMessage,
            ])
        }
    }

    /// Read a fixed-width hex string off the wire, refusing anything else.
    ///
    /// Measured in units of UTF-8 rather than `Character` on purpose, and both
    /// the length check and the walk use the same unit. They did not: the
    /// guard counted `value.utf8.count` while the loop advanced by
    /// `index(_:offsetBy: 2)` over graphemes, so any non-ASCII byte made the
    /// two disagree and the walk ran off the end. `String.index(_:offsetBy:)`
    /// traps past `endIndex` — this returned `nil` for bad input everywhere
    /// except the one shape that killed the process instead.
    ///
    /// `peer.leader.call` hands its three id parameters straight here, so the
    /// input is whatever a socket client typed. `"0" * 62 + "é"` is 64 UTF-8
    /// bytes and 63 characters, and every pair before the last parses as hex.
    nonisolated static func decodeFixedHex(
        _ value: String?,
        byteCount: Int
    ) -> Data? {
        guard let value else { return nil }
        // A hex string is ASCII by definition, so its UTF-8 view is also its
        // list of digits: one unit per character, no grapheme boundary to
        // disagree about, and no index arithmetic that can leave the buffer.
        let digits = Array(value.utf8)
        guard digits.count == byteCount * 2 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for pair in stride(from: 0, to: digits.count, by: 2) {
            guard let high = hexNibble(digits[pair]),
                  let low = hexNibble(digits[pair + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return Data(bytes)
    }

    /// One hex digit's value, or nil for anything that is not one. Rejects the
    /// non-ASCII bytes `UInt8(_:radix:)` would have rejected anyway, one byte
    /// earlier and without a `String` in between.
    nonisolated private static func hexNibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case 0x30...0x39: return digit - 0x30            // 0-9
        case 0x61...0x66: return digit - 0x61 + 10       // a-f
        case 0x41...0x46: return digit - 0x41 + 10       // A-F
        default: return nil
        }
    }

    func v2EnsureHandleRef(kind: V2HandleKind, uuid: UUID) -> String {
        if let existing = v2RefByUUID[kind]?[uuid] {
            return existing
        }
        let next = v2NextHandleOrdinal[kind] ?? 1
        let ref = "\(kind.rawValue):\(next)"
        var byUUID = v2RefByUUID[kind] ?? [:]
        var byRef = v2UUIDByRef[kind] ?? [:]
        byUUID[uuid] = ref
        byRef[ref] = uuid
        v2RefByUUID[kind] = byUUID
        v2UUIDByRef[kind] = byRef
        v2NextHandleOrdinal[kind] = next + 1
        return ref
    }

    func v2ResolveHandleRef(_ handle: String) -> UUID? {
        for kind in V2HandleKind.allCases {
            if let id = v2UUIDByRef[kind]?[handle] {
                return id
            }
        }
        // Tab refs are aliases for surface refs in tab-facing APIs.
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("tab:"),
           let ordinal = Int(trimmed.replacingOccurrences(of: "tab:", with: "")),
           let id = v2UUIDByRef[.surface]?["surface:\(ordinal)"] {
            return id
        }
        return nil
    }

    func v2Ref(kind: V2HandleKind, uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        return v2EnsureHandleRef(kind: kind, uuid: uuid)
    }

    func v2TabRef(uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: uuid)
        return surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
    }

    func v2RefreshKnownRefs() {
        guard let app = AppDelegate.shared else { return }

        let windows = app.listMainWindowSummaries()
        for item in windows {
            _ = v2EnsureHandleRef(kind: .window, uuid: item.windowId)
            if let tm = app.tabManagerFor(windowId: item.windowId) {
                for ws in tm.tabs {
                    _ = v2EnsureHandleRef(kind: .workspace, uuid: ws.id)
                    for paneId in ws.bonsplitController.allPaneIds {
                        _ = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
                    }
                    for panelId in ws.panels.keys {
                        _ = v2EnsureHandleRef(kind: .surface, uuid: panelId)
                    }
                }
            }
        }
    }

    // MARK: - V2 Param Parsing

    func v2String(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func v2ActionKey(_ params: [String: Any], _ key: String = "action") -> String? {
        guard let action = v2String(params, key) else { return nil }
        return action.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    func v2RawString(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    func v2UUID(_ params: [String: Any], _ key: String) -> UUID? {
        guard let s = v2String(params, key) else { return nil }
        if let uuid = UUID(uuidString: s) {
            return uuid
        }
        return v2ResolveHandleRef(s)
    }

    func v2UUIDAny(_ raw: Any?) -> UUID? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid
        }
        return v2ResolveHandleRef(trimmed)
    }
    func v2Bool(_ params: [String: Any], _ key: String) -> Bool? {
        if let b = params[key] as? Bool { return b }
        if let n = params[key] as? NSNumber { return n.boolValue }
        if let s = params[key] as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func v2LocatePane(_ paneUUID: UUID) -> (windowId: UUID, tabManager: TabManager, workspace: Workspace, paneId: PaneID)? {
        guard let app = AppDelegate.shared else { return nil }
        let windows = app.listMainWindowSummaries()
        for item in windows {
            guard let tm = app.tabManagerFor(windowId: item.windowId) else { continue }
            for ws in tm.tabs {
                if let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) {
                    return (item.windowId, tm, ws, paneId)
                }
            }
        }
        return nil
    }
    func v2Int(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }

    func v2PanelType(_ params: [String: Any], _ key: String) -> PanelType? {
        guard let s = v2String(params, key) else { return nil }
        return PanelType(rawValue: s.lowercased())
    }

    // MARK: - V2 Context Resolution

    func v2ResolveTabManager(params: [String: Any]) -> TabManager? {
        // Prefer explicit window_id routing. Fall back to global lookup by workspace_id/surface_id/tab_id,
        // and finally to the active window's TabManager.
        if let windowId = v2UUID(params, "window_id") {
            return v2MainSync { AppDelegate.shared?.tabManagerFor(windowId: windowId) }
        }
        if let wsId = v2UUID(params, "workspace_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(tabId: wsId) }) {
                return tm
            }
        }
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager }) {
                return tm
            }
        }
        return tabManager
    }

    func v2ResolveWindowId(tabManager: TabManager?) -> UUID? {
        guard let tabManager else { return nil }
        return v2MainSync { AppDelegate.shared?.windowId(for: tabManager) }
    }

    // MARK: - V2 Window Methods

    private func v2WindowList(params _: [String: Any]) -> V2CallResult {
        let windows = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        let payload: [[String: Any]] = windows.enumerated().map { index, item in
            return [
                "id": item.windowId.uuidString,
                "ref": v2Ref(kind: .window, uuid: item.windowId),
                "index": index,
                "key": item.isKeyWindow,
                "visible": item.isVisible,
                "workspace_count": item.workspaceCount,
                "selected_workspace_id": v2OrNull(item.selectedWorkspaceId?.uuidString),
                "selected_workspace_ref": v2Ref(kind: .workspace, uuid: item.selectedWorkspaceId)
            ]
        }
        return .ok(["windows": payload])
    }

    private func v2WindowCurrent(params _: [String: Any]) -> V2CallResult {
        guard let tabManager else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let windowId = v2ResolveWindowId(tabManager: tabManager) else {
            return .err(code: "not_found", message: "Current window not found", data: nil)
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    private func v2WindowFocus(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        return ok
            ? .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
            : .err(code: "not_found", message: "Window not found", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
    }

    private func v2WindowCreate(params _: [String: Any]) -> V2CallResult {
        guard let windowId = v2MainSync({ AppDelegate.shared?.createMainWindow() }) else {
            return .err(code: "internal_error", message: "Failed to create window", data: nil)
        }
        // Keep active routing stable unless this command is explicitly focus-intent.
        if socketCommandAllowsInAppFocusMutations(),
           let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    private func v2WindowClose(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
        return ok
            ? .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
            : .err(code: "not_found", message: "Window not found", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
    }

    // MARK: - V2 Team Async Dispatch (Approach D: Swift Concurrency)

    /// Team commands that require MainActor (UI interaction: panels, key events, terminal reads).
    private static let teamUICommands: Set<String> = [
        "team.create",
        "team.destroy",
        "team.send",
        "team.leader.send",
        "team.broadcast",
        "team.read",
        "team.collect",
        // Status/list/inbox need team struct with panel UUIDs
        "team.list",
        "team.status",
        "team.inbox",
        "team.agent.status",
        // Task lifecycle commands that dispatch/notify via panel text
        "team.task.start",
        "team.task.block",
        "team.task.review",
        "team.task.done",
        "team.task.reassign",
        "team.task.unblock",
        "team.task.split",
        // Unified delegate: task creation + instruction send in one RPC
        "team.delegate",
        // Send named key (return, ctrl-c, etc.) to an agent's terminal
        "team.send_key",
        // Soft-restart an agent CLI inside its existing pane
        "team.restart",
        // Workspace-local attach/detach (no new workspace spawned)
        "team.attach",
        "team.detach",
    ]

    /// Dispatch ALL team commands via async path.
    /// - Data-only commands: handled on teamDataQueue (no main thread)
    /// - UI commands: use cooperative `await MainActor.run` (no deadlock)
    ///
    /// Bridge: sync socket thread waits on semaphore while Task runs cooperatively.
    /// Unlike DispatchQueue.main.sync, `await MainActor.run` is cooperative —
    /// it doesn't block the main thread's run loop, preventing IME deadlocks.
    /// Run one `team.*` method for a peer and return the JSON-RPC response
    /// string, exactly as the local socket would produce it.
    ///
    /// Deliberately the SAME dispatcher: a second path would be a second
    /// place for the team surface to drift, and a peer must never reach
    /// something the local caller cannot. The allow-list that decides which
    /// methods get here lives in `PeerTeamCall` and is enforced by the peer
    /// server before this is called.
    func peerTeamCommand(method: String, params: [String: Any]) -> String {
        dispatchTeamCommandAsync(method: method, params: params, id: 1)
    }

    /// Async peer entry point used by the scoped remote-leader control
    /// plane. Unlike the legacy synchronous bridge above, this never blocks
    /// MainActor on a semaphore: data-only work stays on `teamDataQueue`,
    /// and UI methods cooperatively hop only inside their existing handlers.
    func peerTeamCommandAsync(method: String, params: [String: Any]) async -> String {
        if Self.teamDataCommands.contains(method) {
            return teamDataQueue.sync {
                dispatchTeamDataCommandDirect(method: method, params: params, id: 1)
            }
        }
        return await processTeamUICommandAsync(method: method, params: params, id: 1)
    }

    private func dispatchTeamCommandAsync(method: String, params: [String: Any], id: Any?) -> String {
        // Fast path: data-only commands don't need async bridge at all
        if Self.teamDataCommands.contains(method) {
            return teamDataQueue.sync {
                dispatchTeamDataCommandDirect(method: method, params: params, id: id)
            }
        }

        // UI commands: bridge sync → async via semaphore + Task
        let semaphore = DispatchSemaphore(value: 0)
        // nonisolated(unsafe) is fine here — only accessed sequentially
        // (written inside Task, read after semaphore.wait)
        nonisolated(unsafe) var response = ""

        let task = Task {
            defer { semaphore.signal() }
            response = await self.processTeamUICommandAsync(method: method, params: params, id: id)
        }

        // Dynamic timeout: scale with team size for fan-out scenarios.
        // Base 5s + 0.5s per agent beyond 1, so 10 agents → 9.5s timeout.
        let teamName = (params["team"] ?? params["team_name"]) as? String
        let agentCount = teamName.flatMap { TeamOrchestrator.shared.teams[$0]?.agents.count } ?? 1
        let timeoutSec = max(5.0, 5.0 + Double(agentCount - 1) * 0.5)
        if semaphore.wait(timeout: .now() + timeoutSec) == .timedOut {
            // Cancel the still-running Task so delayed retries inside
            // asyncTeamSend/asyncTeamDelegate don't fire after we've already
            // returned a timeout error to the caller.  Without cancellation the
            // Task's progressive-backoff retries (150ms / 400ms) can succeed
            // long after the socket caller has given up, causing a stale Enter
            // delivery to land in the wrong agent pane or doubling up a send.
            task.cancel()
            #if DEBUG
            dlog("[dispatchTeamCommandAsync] TIMEOUT: cancelling stale task method=\(method) timeout=\(timeoutSec)s agents=\(agentCount)")
            #endif
            return "{\"ok\":false,\"error\":{\"code\":\"timeout\",\"message\":\"team command timed out\"}}"
        }
        return response
    }

    /// Direct dispatch for data-only team commands (called within teamDataQueue).
    private func dispatchTeamDataCommandDirect(method: String, params: [String: Any], id: Any?) -> String {
        let store = TeamDataStore.shared
        switch method {
        case "team.message.post":
            return teamDataMessagePost(params: params, id: id, store: store)
        case "team.message.list":
            return teamDataMessageList(params: params, id: id, store: store)
        case "team.message.clear":
            return teamDataMessageClear(params: params, id: id, store: store)
        case "team.correlation.register":
            return teamDataCorrelationRegister(params: params, id: id, store: store)
        case "team.correlation.get":
            return teamDataCorrelationGet(params: params, id: id, store: store)
        case "team.correlation.cancel":
            return teamDataCorrelationCancel(params: params, id: id, store: store)
        case "team.report":
            return teamDataReport(params: params, id: id, store: store)
        case "team.result.status":
            return teamDataResultStatus(params: params, id: id, store: store)
        case "team.result.collect":
            return teamDataResultCollect(params: params, id: id, store: store)
        case "team.agent.heartbeat":
            return teamDataAgentHeartbeat(params: params, id: id, store: store)
        case "team.inbox":
            return teamDataInbox(params: params, id: id, store: store)
        case "team.task.get":
            return teamDataTaskGet(params: params, id: id, store: store)
        case "team.task.list":
            return teamDataTaskList(params: params, id: id, store: store)
        case "team.task.dependents":
            return teamDataTaskDependents(params: params, id: id, store: store)
        case "team.task.clear":
            return teamDataTaskClear(params: params, id: id, store: store)
        case "team.task.claim":
            return teamDataTaskClaim(params: params, id: id, store: store)
        case "team.task.timebox":
            return teamDataTaskTimebox(params: params, id: id, store: store)
        case "team.task.create":
            return teamDataTaskCreate(params: params, id: id, store: store)
        case "team.task.update":
            return teamDataTaskUpdate(params: params, id: id, store: store)
        case "team.context.set":
            return teamDataContextSet(params: params, id: id, store: store)
        case "team.context.get":
            return teamDataContextGet(params: params, id: id, store: store)
        case "team.context.list":
            return teamDataContextList(params: params, id: id, store: store)
        case "team.watch_drift.post":
            return teamDataWatchDriftPost(params: params, id: id, store: store)
        case "team.preset.list":
            return teamDataPresetList(params: params, id: id)
        case "team.preset.resolve":
            return teamDataPresetResolve(params: params, id: id)
        default:
            return v2Error(id: id, code: "unknown_method", message: "Unknown team data method: \(method)")
        }
    }

    /// Async handler for team UI commands. Uses `await MainActor.run` for
    /// cooperative main-thread access instead of blocking `DispatchQueue.main.sync`.
    private func processTeamUICommandAsync(method: String, params: [String: Any], id: Any?) async -> String {
        // Each UI command: parse params off-main, then `await MainActor.run` for minimal UI work
        switch method {
        case "team.create":
            return await asyncTeamCreate(params: params, id: id)
        case "team.destroy":
            return await asyncTeamDestroy(params: params, id: id)
        case "team.send":
            return await asyncTeamSend(params: params, id: id)
        case "team.leader.send":
            return await asyncTeamLeaderSend(params: params, id: id)
        case "team.broadcast":
            return await asyncTeamBroadcast(params: params, id: id)
        case "team.read":
            return await asyncTeamRead(params: params, id: id)
        case "team.collect":
            return await asyncTeamCollect(params: params, id: id)
        case "team.list":
            return await asyncTeamList(params: params, id: id)
        case "team.status":
            return await asyncTeamStatus(params: params, id: id)
        case "team.inbox":
            return await asyncTeamInbox(params: params, id: id)
        case "team.agent.status":
            return await asyncTeamAgentStatus(params: params, id: id)
        case "team.task.start":
            return await asyncTeamTaskStart(params: params, id: id)
        case "team.task.block":
            return await asyncTeamTaskBlock(params: params, id: id)
        case "team.task.review":
            return await asyncTeamTaskReview(params: params, id: id)
        case "team.task.done":
            return await asyncTeamTaskDone(params: params, id: id)
        case "team.task.reassign":
            return await asyncTeamTaskReassign(params: params, id: id)
        case "team.task.unblock":
            return await asyncTeamTaskUnblock(params: params, id: id)
        case "team.task.split":
            return await asyncTeamTaskSplit(params: params, id: id)
        case "team.task.approve":
            return await asyncTeamTaskApprove(params: params, id: id)
        case "team.task.reject":
            return await asyncTeamTaskReject(params: params, id: id)
        case "team.delegate":
            return await asyncTeamDelegate(params: params, id: id)
        case "team.send_key":
            return await asyncTeamSendKey(params: params, id: id)
        case "team.restart":
            return await asyncTeamRestart(params: params, id: id)
        case "team.interrupt":
            return await asyncTeamInterrupt(params: params, id: id)
        case "team.interrupt_all":
            return await asyncTeamInterruptAll(params: params, id: id)
        case "team.attach":
            return await asyncTeamAttach(params: params, id: id)
        case "team.detach":
            return await asyncTeamDetach(params: params, id: id)
        case "team.add_agent":
            return await asyncTeamAddAgent(params: params, id: id)
        default:
            return v2Error(id: id, code: "unknown_method", message: "Unknown team command: \(method)")
        }
    }

    // MARK: - Async Team UI Handlers

    /// Pattern: parse params off-main → await MainActor.run { minimal UI work } → format response off-main
    /// This minimizes main-thread hold time vs the old v2MainSync { entire method } pattern.

    private func asyncTeamCreate(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String, !teamName.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        // Empty means a team of its leader alone; missing means the caller
        // forgot the parameter. Same distinction as the sync path above.
        guard let agentsParam = params["agents"] as? [[String: Any]] else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agents array")
        }
        // Parse all params off-main
        let workingDirectory = params["working_directory"] as? String ?? FileManager.default.currentDirectoryPath
        let leaderSessionId = params["leader_session_id"] as? String ?? UUID().uuidString
        let leaderMode = params["leader_mode"] as? String ?? "repl"
        let leaderModel = params["leader_model"] as? String ?? "sonnet"
        let leaderCli = params["leader_cli"] as? String ?? "claude"
        let resumeSessionId = params["resume_session_id"] as? String
        // F2 fix: socket param `runbook_init_prompt: true` means "DO inject
        // the runbook into the agent init prompt" (CLI sends `true` for that
        // intent). The orchestrator parameter is the inverse — *skip* the
        // runbook — so invert before passing through. Default behaviour
        // (param absent → include) is preserved by reading default `true`.
        let includeRunbookInitPrompt = params["runbook_init_prompt"] as? Bool ?? true
        let skipRunbookInitPrompt = !includeRunbookInitPrompt
        // Adopted mode: caller's terminal IS the leader; surface_id identifies it.
        let adoptedLeaderSurfaceId: UUID? = leaderMode == "adopted"
            ? (params["surface_id"] as? String).flatMap(UUID.init(uuidString:))
            : nil
        if leaderMode == "adopted" && adoptedLeaderSurfaceId == nil {
            return v2Error(id: id, code: "invalid_params", message: "adopted mode requires a valid surface_id")
        }
        let agents = agentsParam.map { dict -> (name: String, cli: String, model: String, agentType: String, color: String, instructions: String, customInstructions: String) in
            (
                name: dict["name"] as? String ?? "agent",
                cli: dict["cli"] as? String ?? "claude",
                model: dict["model"] as? String ?? "sonnet",
                agentType: dict["agent_type"] as? String ?? "",
                color: dict["color"] as? String ?? "green",
                instructions: dict["instructions"] as? String ?? "",
                // R7: only the watcher carries custom_instructions (the CLI
                // attaches `--spec` to the watcher dict only). composeInstructions
                // appends it verbatim as `## Team Custom Instructions`.
                customInstructions: dict["custom_instructions"] as? String ?? ""
            )
        }
        // Only the actual team creation needs MainActor
        let result: V2CallResult = await MainActor.run {
            // File-based debug log for team.create routing (works in Release)
            func teamLog(_ msg: String) {
                let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
                let path = "/tmp/term-mesh-team-routing.log"
                if let fh = FileHandle(forWritingAtPath: path) {
                    fh.seekToEndOfFile()
                    fh.write(Data(line.utf8))
                    fh.closeFile()
                } else {
                    FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
                }
            }
            let surfaceParam = params["surface_id"] as? String ?? "nil"
            let windowParam = params["window_id"] as? String ?? "nil"
            let wsParam = params["workspace_id"] as? String ?? "nil"
            teamLog("params: window_id=\(windowParam) surface_id=\(surfaceParam) workspace_id=\(wsParam)")

            // Resolve TabManager from params (window_id > surface_id > workspace_id > key window > fallback).
            // We're already on MainActor, so call AppDelegate directly without v2MainSync.
            let tabManager: TabManager? = {
                let appDelegate = AppDelegate.shared
                let ctxCount = appDelegate?.mainWindowContexts.count ?? 0
                teamLog("mainWindowContexts count=\(ctxCount)")
                // List all windows for debugging
                if let appDelegate {
                    for (i, ctx) in appDelegate.mainWindowContexts.values.enumerated() {
                        let wid = ctx.windowId.uuidString
                        let tabCount = ctx.tabManager.tabs.count
                        let tabIds = ctx.tabManager.tabs.map { $0.id.uuidString.prefix(8) }.joined(separator: ",")
                        teamLog("  window[\(i)]: id=\(wid) tabs=\(tabCount) tabIds=[\(tabIds)]")
                    }
                }
                // 1. Explicit window_id (from TERMMESH_WINDOW_ID env var)
                if let windowIdStr = params["window_id"] as? String,
                   let windowId = UUID(uuidString: windowIdStr),
                   let tm = appDelegate?.tabManagerFor(windowId: windowId) {
                    teamLog("RESOLVED via window_id=\(windowIdStr)")
                    return tm
                }
                // 2. surface_id from caller's pane (TERMMESH_PANEL_ID)
                if let surfaceIdStr = params["surface_id"] as? String,
                   let surfaceId = UUID(uuidString: surfaceIdStr) {
                    if let tm = appDelegate?.locateSurface(surfaceId: surfaceId)?.tabManager {
                        let resolvedWid = appDelegate?.windowId(for: tm)?.uuidString ?? "?"
                        teamLog("RESOLVED via surface_id=\(surfaceIdStr) → window=\(resolvedWid)")
                        return tm
                    }
                    teamLog("surface_id=\(surfaceIdStr) NOT FOUND in any window")
                }
                // 2.5. workspace_id from caller's workspace (TERMMESH_WORKSPACE_ID)
                if let wsIdStr = params["workspace_id"] as? String,
                   let wsId = UUID(uuidString: wsIdStr),
                   let tm = appDelegate?.tabManagerFor(tabId: wsId) {
                    let resolvedWid = appDelegate?.windowId(for: tm)?.uuidString ?? "?"
                    teamLog("RESOLVED via workspace_id=\(wsIdStr) → window=\(resolvedWid)")
                    return tm
                }
                if let wsIdStr = params["workspace_id"] as? String {
                    teamLog("workspace_id=\(wsIdStr) NOT FOUND in any window")
                }
                // 3. Current key window — most reliable for "which window is the user in"
                if let appDelegate,
                   let keyWindow = NSApp.keyWindow,
                   let ctx = appDelegate.contextForMainWindow(keyWindow) {
                    let windowId = appDelegate.windowId(for: ctx.tabManager)?.uuidString ?? "?"
                    teamLog("RESOLVED via keyWindow windowId=\(windowId)")
                    return ctx.tabManager
                }
                // 4. Fallback to last active tabManager
                let selfWindowId = self.v2ResolveWindowId(tabManager: self.tabManager)?.uuidString ?? "?"
                teamLog("FALLBACK to self.tabManager windowId=\(selfWindowId) (contexts=\(ctxCount))")
                return self.tabManager
            }()
            teamLog("final: resolved=\(tabManager != nil)")
            guard let tabManager else {
                return V2CallResult.err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            if let team = TeamOrchestrator.shared.createTeam(
                name: teamName,
                agents: agents,
                workingDirectory: workingDirectory,
                leaderSessionId: leaderSessionId,
                leaderMode: leaderMode,
                leaderModel: leaderModel,
                leaderCli: leaderCli,
                resumeSessionId: resumeSessionId,
                adoptedLeaderSurfaceId: adoptedLeaderSurfaceId,
                skipRunbookPromptForInteractiveAgents: skipRunbookInitPrompt,
                tabManager: tabManager
            ) {
                // Apply auto-recycle settings post-creation (Phase 1: CLI-only)
                if let recycleEvery = params["default_auto_recycle_every"] as? Int {
                    TeamOrchestrator.shared.setTeamDefaultAutoRecycle(teamName: teamName, every: recycleEvery)
                }
                if let perAgent = params["per_agent_auto_recycle"] as? [String: Int] {
                    for (agentName, count) in perAgent {
                        TeamOrchestrator.shared.setAgentAutoRecycleByName(teamName: teamName, agentName: agentName, every: count)
                    }
                }
                return V2CallResult.ok([
                    "team_name": team.id,
                    "agent_count": team.agents.count,
                    "workspace_id": team.workspaceId.uuidString,
                    "agents": team.agents.map { agent -> [String: Any] in
                        var info: [String: Any] = [
                            "id": agent.id, "name": agent.name,
                            "agent_instance_id": agent.agentInstanceId,
                            "model": agent.model,
                            "workspace_id": agent.workspaceId.uuidString,
                        ]
                        if let pid = agent.panelId {
                            info["panel_id"] = pid.uuidString
                        }
                        return info
                    },
                ] as [String: Any])
            }
            return V2CallResult.err(code: "internal_error", message: "Failed to create team", data: nil)
        }
        return v2Result(id: id, result)
    }

    private func asyncTeamDestroy(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let success = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.destroyTeam(name: teamName, tabManager: tabManager)
        }
        return success
            ? v2Ok(id: id, result: ["destroyed": true, "team_name": teamName])
            : v2Error(id: id, code: "not_found", message: "Team not found")
    }

    /// Attach a single agent pane to the caller's existing workspace.
    ///
    /// Params:
    ///   - agent_type (required)  : e.g. "executor", "reviewer"
    ///   - agent_name (required)  : unique within the workspace-local team
    ///   - agent_cli              : "claude" (default), "codex", "kiro", "gemini"
    ///   - agent_model            : "sonnet" (default), "opus", "haiku"
    ///   - instructions           : optional system-prompt/role description
    ///   - window_id / surface_id / workspace_id : same routing params as team.create
    ///
    /// Reuses `asyncTeamCreate`'s TabManager resolution path (R11 — 2026-03-17 regression guard).
    private func asyncTeamAttach(params: [String: Any], id: Any?) async -> String {
        // Parse off-main
        guard let agentType = params["agent_type"] as? String, !agentType.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_type")
        }
        guard let agentName = params["agent_name"] as? String, !agentName.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        let agentCli = (params["agent_cli"] as? String) ?? "claude"
        let agentModel = (params["agent_model"] as? String) ?? "sonnet"
        let instructions = (params["instructions"] as? String) ?? ""
        // R7: spec is carried as custom_instructions (watcher only via the CLI).
        let customInstructions = params["custom_instructions"] as? String

        // MainActor-bound resolution + attach
        let result: V2CallResult = await MainActor.run {
            // Resolve TabManager using the same precedence as asyncTeamCreate (R11).
            let appDelegate = AppDelegate.shared
            let resolved: (tabManager: TabManager, workspaceId: UUID, callerPanelId: UUID)? = {
                // 1. Explicit window_id — locate tabManager, then derive workspace from workspace_id or surface_id.
                if let windowIdStr = params["window_id"] as? String,
                   let windowId = UUID(uuidString: windowIdStr),
                   let tm = appDelegate?.tabManagerFor(windowId: windowId) {
                    if let surfaceIdStr = params["surface_id"] as? String,
                       let surfaceId = UUID(uuidString: surfaceIdStr),
                       let located = appDelegate?.locateSurface(surfaceId: surfaceId) {
                        return (tm, located.workspaceId, surfaceId)
                    }
                    if let wsIdStr = params["workspace_id"] as? String,
                       let wsId = UUID(uuidString: wsIdStr),
                       let panelIdStr = params["surface_id"] as? String,
                       let panelId = UUID(uuidString: panelIdStr) {
                        return (tm, wsId, panelId)
                    }
                }
                // 2. surface_id alone — derives both tabManager and workspace.
                if let surfaceIdStr = params["surface_id"] as? String,
                   let surfaceId = UUID(uuidString: surfaceIdStr),
                   let located = appDelegate?.locateSurface(surfaceId: surfaceId) {
                    return (located.tabManager, located.workspaceId, surfaceId)
                }
                // 3. workspace_id alone — tabManager via workspace lookup; caller pane unknown → reject
                //    (attach requires a caller pane to adopt as leader).
                return nil
            }()

            guard let resolved else {
                return V2CallResult.err(
                    code: "not_in_workspace",
                    message: "team.attach requires surface_id (caller pane) to adopt as leader. Run tm-agent attach from inside a term-mesh pane.",
                    data: nil
                )
            }

            let outcome = TeamOrchestrator.shared.attachToWorkspace(
                workspaceId: resolved.workspaceId,
                callerPanelId: resolved.callerPanelId,
                agentName: agentName,
                agentCli: agentCli,
                agentModel: agentModel,
                agentType: agentType,
                instructions: instructions,
                customInstructions: customInstructions,
                tabManager: resolved.tabManager
            )

            switch outcome {
            case .success(let (team, newAgent)):
                var payload: [String: Any] = [
                    "team_name": team.id,
                    "agent_name": newAgent.name,
                    "agent_id": newAgent.id,
                    "agent_instance_id": newAgent.agentInstanceId,
                    "workspace_id": team.workspaceId.uuidString,
                    "agent_count": team.agents.count,
                    "model": newAgent.model,
                    "cli": newAgent.cli,
                ]
                if let pid = newAgent.panelId {
                    payload["panel_id"] = pid.uuidString
                }
                return V2CallResult.ok(payload)
            case .failure(let err):
                return V2CallResult.err(code: err.code, message: err.description, data: nil)
            }
        }
        return v2Result(id: id, result)
    }

    /// Detach a single agent from the caller's workspace-local team.
    ///
    /// Params:
    ///   - agent_name (required) : agent to remove
    ///   - team_name              : optional explicit override (defaults to ws-<hex> for caller's workspace)
    ///   - window_id / surface_id / workspace_id : same routing params as team.create
    private func asyncTeamDetach(params: [String: Any], id: Any?) async -> String {
        guard let agentName = params["agent_name"] as? String, !agentName.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        let explicitTeamName = params["team_name"] as? String
        let force = (params["force"] as? Bool) ?? true
        // When true (watch doctor create-branch repair), a last-agent detach
        // preserves the empty team record so the following add_agent can rebuild
        // the watcher pane. Defaults false → original destroy-on-last behavior.
        let keepTeamIfEmpty = (params["keep_team_if_empty"] as? Bool) ?? false

        let result: V2CallResult = await MainActor.run {
            let appDelegate = AppDelegate.shared
            // Resolution priority:
            // 1. explicit team_name → look up stored team, resolve tabManager from team.workspaceId
            //    (used by `tm-agent remove` against GUI teams — no caller env required)
            // 2. caller-env params (window_id / surface_id / workspace_id)
            //    (used by `tm-agent detach` from inside a workspace pane)
            let resolved: (tabManager: TabManager, workspaceId: UUID)? = {
                // Path 1: team_name-scoped resolution (mirrors asyncTeamAddAgent)
                if let tn = explicitTeamName,
                   let team = TeamOrchestrator.shared.teams[tn],
                   let tm = appDelegate?.tabManagerFor(tabId: team.workspaceId) {
                    return (tm, team.workspaceId)
                }
                // Path 2: caller-env resolution (workspace-adopt path)
                if let windowIdStr = params["window_id"] as? String,
                   let windowId = UUID(uuidString: windowIdStr),
                   let tm = appDelegate?.tabManagerFor(windowId: windowId) {
                    if let wsIdStr = params["workspace_id"] as? String,
                       let wsId = UUID(uuidString: wsIdStr) {
                        return (tm, wsId)
                    }
                    if let surfaceIdStr = params["surface_id"] as? String,
                       let surfaceId = UUID(uuidString: surfaceIdStr),
                       let located = appDelegate?.locateSurface(surfaceId: surfaceId) {
                        return (tm, located.workspaceId)
                    }
                }
                if let surfaceIdStr = params["surface_id"] as? String,
                   let surfaceId = UUID(uuidString: surfaceIdStr),
                   let located = appDelegate?.locateSurface(surfaceId: surfaceId) {
                    return (located.tabManager, located.workspaceId)
                }
                if let wsIdStr = params["workspace_id"] as? String,
                   let wsId = UUID(uuidString: wsIdStr),
                   let tm = appDelegate?.tabManagerFor(tabId: wsId) {
                    return (tm, wsId)
                }
                return nil
            }()

            guard let resolved else {
                return V2CallResult.err(
                    code: "not_in_workspace",
                    message: "team.detach requires team_name, workspace_id, or surface_id.",
                    data: nil
                )
            }

            let teamName = explicitTeamName
                ?? TeamOrchestrator.workspaceTeamName(for: resolved.workspaceId)

            let selection = TeamOrchestrator.shared.resolveAgentForRPC(
                teamName: teamName,
                agentName: agentName,
                agentInstanceId: params["agent_instance_id"] as? String
            )
            guard let agent = selection.agent else {
                if selection.candidates.count > 1 && (params["agent_instance_id"] as? String)?.nilIfBlankTC == nil {
                    let candidates = selection.candidates.map { ["agent_name": $0.name, "agent_instance_id": $0.agentInstanceId] }
                    return V2CallResult.err(code: "ambiguous_agent", message: "Agent name '\(agentName)' has multiple instances; pass agent_instance_id", data: ["candidates": candidates])
                }
                return V2CallResult.err(code: "not_found", message: "Agent not found", data: nil)
            }

            let outcome = TeamOrchestrator.shared.detachAgent(
                teamName: teamName,
                agentName: agentName,
                agentInstanceId: agent.agentInstanceId,
                tabManager: resolved.tabManager,
                force: force,
                keepTeamIfEmpty: keepTeamIfEmpty
            )

            switch outcome {
            case .success(let detachResult):
                return V2CallResult.ok([
                    "detached": true,
                    "team_name": detachResult.teamName,
                    "agent_name": detachResult.agentName,
                    "agent_instance_id": agent.agentInstanceId,
                    "remaining_agents": detachResult.remainingAgents,
                    "team_destroyed": detachResult.teamDestroyed,
                ] as [String: Any])
            case .failure(let err):
                return V2CallResult.err(code: err.code, message: err.description, data: nil)
            }
        }
        return v2Result(id: id, result)
    }

    /// Add a new agent pane to an existing GUI team by team name.
    /// Unlike team.attach, this does not require a caller surface_id — the workspace
    /// is resolved from the stored team record, mirroring team.detach's routing.
    ///
    /// Params:
    ///   - team_name  (required): target team name
    ///   - agent_type (required): role type (e.g. "executor", "reviewer")
    ///   - name       (optional): display name; defaults to agent_type if omitted
    ///   - model      (optional): CLI model string; defaults to "sonnet"
    ///   - cli        (optional): CLI binary; defaults to "claude"
    /// `team.add_agent` with a `host`: the member runs on a peer.
    ///
    /// Named by whatever the person would say — the sidebar's label
    /// (`jw-server`) as readily as the key it is stored under
    /// (`ssh:root@jw-server`), because one of those is what they see and the
    /// other is what the config holds.
    private func asyncTeamAddRemoteAgent(
        teamName: String,
        agentType: String,
        agentName: String,
        agentModel: String,
        agentCli: String,
        host: String,
        directory: String?,
        id: Any?
    ) async -> String {
        enum Resolution {
            case ok(key: String, directory: String)
            case noSuchHost(connectedKeys: [String])
            case noDirectory(host: String)
        }
        let resolution: Resolution = await MainActor.run {
            let hosts = RemoteHostStore.selectableLaunchHosts(
                in: RemoteHostStore.shared.sortedHosts
            )
            let candidates = hosts.map {
                (key: $0.id, displayName: $0.displayName, sshTarget: $0.sshTarget)
            }
            guard let hostKey = Self.remoteAgentHostKey(for: host, candidates: candidates),
                  let match = hosts.first(where: { $0.id == hostKey })
            else { return .noSuchHost(connectedKeys: hosts.map(\.id)) }
            // An explicit directory wins, because the caller is the only one
            // who can know where a project lives on a machine that has not
            // said. Two machines rarely lay a checkout out the same way, so
            // reusing the team's own path would be a guess dressed as a fact.
            if let directory, !directory.isEmpty {
                return .ok(key: match.id, directory: directory)
            }
            // What worked last time this project ran on that machine. Asked
            // once, then never again — the field existed to be told, not to be
            // asked.
            let teamRoot = TeamOrchestrator.shared.teams[teamName]?.workingDirectory ?? ""
            if let remembered = RemoteProjectPaths.shared.path(
                host: match.id, localRoot: teamRoot
            ) {
                return .ok(key: match.id, directory: remembered)
            }
            // Otherwise take what the host reports, preferring the project the
            // team is already in — matched by folder name, which is all two
            // machines are likely to agree on.
            let leafName = URL(fileURLWithPath: teamRoot).lastPathComponent
            var roots = match.workspaces
                .flatMap(\.panes)
                .compactMap(\.projectRootPath)
                .filter { !$0.isEmpty }
            roots.append(contentsOf: match.teams.compactMap(\.projectRootPath).filter { !$0.isEmpty })
            let byName = roots.first { URL(fileURLWithPath: $0).lastPathComponent == leafName }
            let predicted = PeerHostProfileStore.shared.profiles
                .first { $0.stableKey == match.id }?
                .predictedProjectPath(forProjectNamed: leafName)
            guard let picked = byName ?? predicted ?? roots.first else {
                return .noDirectory(host: match.displayName)
            }
            return .ok(key: match.id, directory: picked)
        }
        let resolved: (key: String, directory: String)
        switch resolution {
        case .ok(let key, let dir):
            resolved = (key, dir)
        case .noSuchHost(let connectedKeys):
            return v2Error(
                id: id,
                code: "not_found",
                message: Self.remoteAgentHostNotFoundMessage(
                    input: host,
                    connectedKeys: connectedKeys
                )
            )
        case .noDirectory(let name):
            return v2Error(
                id: id,
                code: "invalid_params",
                message: "\(name) reports no project to work in — pass a directory to say where"
            )
        }
        do {
            let member = try await TeamOrchestrator.shared.attachRemoteAgent(
                teamName: teamName,
                agentName: agentName,
                hostKey: resolved.key,
                workingDirectory: resolved.directory,
                agentType: agentType,
                model: agentModel,
                cli: agentCli
            )
            let checkout = Self.remoteAgentResponseWorkingDirectory(
                requested: resolved.directory,
                memberWorkingDirectory: member.originalAgentWorkDir
            )
            var payload: [String: Any] = [
                "team_name": teamName,
                "agent_name": member.name,
                "agent_id": member.id,
                "agent_type": member.agentType,
                "cli": member.cli,
                "model": member.model,
                "host": resolved.key,
                "working_directory": checkout.directory,
                "checkout_reused": checkout.reused,
            ]
            if let pid = member.panelId { payload["panel_id"] = pid.uuidString }
            return v2Result(id: id, .ok(payload))
        } catch {
            return v2Error(id: id, code: "add_failed", message: String(describing: error))
        }
    }

    private func asyncTeamAddAgent(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String, !teamName.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentType = params["agent_type"] as? String, !agentType.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_type")
        }
        let rawName = params["name"] as? String ?? ""
        let agentName = rawName.isEmpty ? agentType : rawName
        let agentModel = (params["model"] as? String) ?? "sonnet"
        let agentCli = (params["cli"] as? String) ?? "claude"
        // R7: spec is carried as custom_instructions (watcher only via the CLI).
        let customInstructions = params["custom_instructions"] as? String

        let autoRecycleEvery = params["auto_recycle_every"] as? Int

        // `--host` sends the agent somewhere else. The pane is still opened
        // here, beside its team; only the shell behind it belongs to the peer.
        let hostParam = (params["host"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hostParam.isEmpty {
            return await asyncTeamAddRemoteAgent(
                teamName: teamName,
                agentType: agentType,
                agentName: agentName,
                agentModel: agentModel,
                agentCli: agentCli,
                host: hostParam,
                directory: (params["directory"] as? String)
                    ?? (params["working_directory"] as? String),
                id: id
            )
        }

        let result: V2CallResult = await MainActor.run {
            let outcome = TeamOrchestrator.shared.addAgentToTeam(
                teamName: teamName,
                agentType: agentType,
                agentName: agentName,
                agentModel: agentModel,
                agentCli: agentCli,
                customInstructions: customInstructions
            )
            switch outcome {
            case .success(let member):
                if let recycleEvery = autoRecycleEvery {
                    TeamOrchestrator.shared.setAgentAutoRecycle(teamName: teamName, agentId: member.id, every: recycleEvery)
                }
                var payload: [String: Any] = [
                    "team_name": teamName,
                    "agent_name": member.name,
                    "agent_id": member.id,
                    "agent_instance_id": member.agentInstanceId,
                    "agent_type": member.agentType,
                    "cli": member.cli,
                    "model": member.model,
                ]
                if let pid = member.panelId {
                    payload["panel_id"] = pid.uuidString
                }
                return V2CallResult.ok(payload)
            case .failure(let err):
                return V2CallResult.err(code: err.code, message: err.description, data: nil)
            }
        }
        return v2Result(id: id, result)
    }

    /// Resolves the additive `agent_instance_id` selector before any RPC side
    /// effect.  A legacy name is accepted only when it has exactly one match.
    private func resolveTeamAgentInstance(
        params: [String: Any],
        teamName: String,
        agentName: String
    ) async -> (instanceId: String?, failure: V2CallResult?) {
        let requestedInstanceId = params["agent_instance_id"] as? String
        return await MainActor.run {
            let resolution = TeamOrchestrator.shared.resolveAgentForRPC(
                teamName: teamName,
                agentName: agentName,
                agentInstanceId: requestedInstanceId
            )
            if let agent = resolution.agent {
                return (agent.agentInstanceId, nil)
            }
            guard !resolution.candidates.isEmpty else {
                return (nil, .err(code: "not_found", message: "Agent '\(agentName)' not found in team '\(teamName)'", data: nil))
            }
            if requestedInstanceId?.isEmpty == false {
                return (nil, .err(
                    code: "not_found",
                    message: "Agent instance '\(requestedInstanceId!)' not found for '\(agentName)'",
                    data: ["team_name": teamName, "agent_name": agentName]
                ))
            }
            let candidates = resolution.candidates.map { agent -> [String: Any] in
                var candidate: [String: Any] = [
                    "agent_name": agent.name,
                    "agent_instance_id": agent.agentInstanceId,
                ]
                if let panelId = agent.panelId { candidate["panel_id"] = panelId.uuidString }
                return candidate
            }
            return (nil, .err(
                code: "ambiguous_agent",
                message: "Agent name '\(agentName)' has multiple instances; pass agent_instance_id",
                data: ["team_name": teamName, "agent_name": agentName, "candidates": candidates]
            ))
        }
    }

    private func asyncTeamSend(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = params["agent_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        guard let text = params["text"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing text")
        }
        let selection = await resolveTeamAgentInstance(
            params: params, teamName: teamName, agentName: agentName
        )
        if let failure = selection.failure { return v2Result(id: id, failure) }
        guard let agentInstanceId = selection.instanceId else {
            return v2Error(id: id, code: "not_found", message: "Agent not found")
        }
        let sendSequenceAware = params["send_sequence_aware"] as? Bool ?? false
        // Per-agent send serialization: wait for the preceding paste+Return cycle to
        // finish (including 250 ms post-Return cooldown) before pasting new text.
        // This prevents rapid consecutive sends from racing inside the codex TUI
        // submit window and dropping every other message.
        let agentKey = "\(teamName)/\(agentInstanceId)"
        let (prevGate, sendGate): (SendGate?, SendGate) = await MainActor.run {
            TerminalController.enqueueSendGate(
                agentKey: agentKey,
                sequenceAware: sendSequenceAware
            )
        }
        if let prev = prevGate { await prev.wait() }
        // The watchdog belongs to the active sequence, not time spent queued
        // behind an earlier paste+Return cycle.
        TerminalController.startSendGateWatchdog(sendGate, agentKey: agentKey)

        // Stagger: dynamic gap based on team size to prevent GCD main-queue saturation
        // when the CLI sends to 10+ agents in rapid succession.
        let staggerNs = await MainActor.run {
            let count = TeamOrchestrator.shared.teams[teamName]?.agents.count ?? 1
            return TerminalController.reserveTeamSendSlot(agentCount: count)
        }
        if staggerNs > 0 {
            try? await Task.sleep(nanoseconds: staggerNs)
        }
        // Resolve the correct tabManager from the team's workspace, not self.tabManager.
        // Use the same finalizePaste-ack pattern as asyncTeamDelegate so the caller
        // (Rust CLI) doesn't fire Enter until the paste has fully landed in the agent's
        // input field. Previously this returned text_delivered=true unconditionally,
        // which let send_return_key_with_retry race the paste mid-stream and truncated
        // long init prompts to whatever had been pasted before Enter arrived.
        //
        // 12s last-resort timeout mirrors asyncTeamDelegate: it must exceed the paste
        // watchdog (8s) + max retry backoff (~2s) so it doesn't trip a still-live paste.
        var dispatched = false
        let textDelivered: Bool = await withCheckedContinuation { cont in
            var resumed = false
            let resume: (Bool) -> Void = { ok in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: ok)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { resume(false) }
            Task { @MainActor in
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { resume(false); return }
                // Keep only the durable instance across the stagger/queue wait.
                // sendToAgent resolves its current panel, transport and host here,
                // immediately before delivery, so a restarted sibling is never used.
                let ok = TeamOrchestrator.shared.sendToAgent(
                    teamName: teamName,
                    agentName: agentName,
                    agentInstanceId: agentInstanceId,
                    text: text,
                    tabManager: tabManager,
                    withReturn: false, // Return is sent separately by Rust CLI via team.send_key
                    completion: { ack in resume(ack) }
                )
                dispatched = ok
                if !ok { resume(false) }
            }
        }
        if dispatched && textDelivered {
            sendGate.markAwaitingReturn()
        } else {
            // No team.send_key follows a failed paste acknowledgement, so remove
            // this send's gate instead of leaving the FIFO queue one entry behind.
            await MainActor.run {
                TerminalController.discardSendGate(sendGate, agentKey: agentKey)
            }
        }
        return teamSendDeliveryResponse(
            id: id,
            dispatched: dispatched,
            textDelivered: textDelivered,
            teamName: teamName,
            agentName: agentName,
            agentInstanceId: agentInstanceId,
            sendSequenceID: sendSequenceAware ? sendGate.sequenceID : nil
        )
    }

    /// Formats the `team.send` delivery contract. `transport_write` means only
    /// that the complete text reached the target transport/input field; it does
    /// not claim that the agent consumed the text or produced a reply.
    func teamSendDeliveryResponse(
        id: Any?,
        dispatched: Bool,
        textDelivered: Bool,
        teamName: String,
        agentName: String,
        agentInstanceId: String,
        sendSequenceID: String? = nil
    ) -> String {
        guard dispatched else {
            return v2Error(id: id, code: "not_found", message: "Agent or team not found")
        }
        var delivery: [String: Any] = [
            "sent": textDelivered,
            "text_delivered": textDelivered,
            "delivery_scope": "transport_write",
            "transport_dispatched": true,
            "team_name": teamName,
            "agent_name": agentName,
            "agent_instance_id": agentInstanceId,
        ]
        if textDelivered, let sendSequenceID {
            delivery["send_sequence_id"] = sendSequenceID
        }
        guard textDelivered else {
            return v2Error(
                id: id,
                code: "delivery_failed",
                message: "Agent transport was dispatched but text delivery was not acknowledged",
                data: delivery
            )
        }
        return v2Ok(id: id, result: delivery)
    }

    private func asyncTeamLeaderSend(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let text = params["text"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing text")
        }
        // Stagger: dynamic gap based on team size to prevent GCD main-queue saturation.
        let staggerNs = await MainActor.run {
            let count = TeamOrchestrator.shared.teams[teamName]?.agents.count ?? 1
            return TerminalController.reserveTeamSendSlot(agentCount: count)
        }
        if staggerNs > 0 {
            try? await Task.sleep(nanoseconds: staggerNs)
        }
        let success = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.sendToLeader(teamName: teamName, text: text, tabManager: tabManager)
        }
        return success
            ? v2Ok(id: id, result: ["sent": true, "team_name": teamName, "target": "leader"])
            : v2Error(id: id, code: "not_found", message: "Leader or team not found")
    }

    private func asyncTeamBroadcast(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let text = params["text"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing text")
        }
        // Stagger sends: 100ms between each agent to avoid main-thread congestion
        // that causes text/Enter key drops. 10 agents × 100ms = 1s total (acceptable).
        // Use (workspaceId, panelId) pairs — not names — so duplicate-named agents each
        // receive the broadcast instead of collapsing to a single recipient.
        let agentPanels: [(workspaceId: UUID, panelId: UUID)] = await MainActor.run {
            guard let team = TeamOrchestrator.shared.teams[teamName] else { return [] }
            return team.agents.compactMap { agent -> (workspaceId: UUID, panelId: UUID)? in
                guard let pid = agent.panelId else { return nil }
                return (workspaceId: agent.workspaceId, panelId: pid)
            }
        }
        var count = 0
        for (index, panel) in agentPanels.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            let success = await MainActor.run {
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { return false }
                return TeamOrchestrator.shared.sendToAgentByPanel(
                    teamName: teamName, panelId: panel.panelId, workspaceId: panel.workspaceId,
                    text: text, tabManager: tabManager
                )
            }
            if success { count += 1 }
        }
        return v2Ok(id: id, result: ["sent_count": count, "team_name": teamName])
    }

    /// Remove routing-only correlation credentials from pane snapshots without
    /// touching the surrounding instruction or the agent's response body.
    static func sanitizedTeamReadOutput(_ text: String) -> String {
        var sanitized = text
        // `ghostty_surface_read_text` returns the rectangular terminal grid,
        // so a soft wrap becomes whitespace/newlines even in the middle of a
        // command or token. The generated bearer is exactly 64 hex digits:
        // constrain the wrap-tolerant patterns to that signature and known
        // protocol literals so an unrelated digest in the response survives.
        let generatedToken = #"[0-9A-Fa-f](?:[ \t\r\n]*[0-9A-Fa-f]){63}"#
        let wrappedIdentity = #"(?:[A-Za-z0-9_-][ \t\r\n]*){1,128}"#
        let wrappedCommand = softWrappedLiteralPattern("tm-agent reply --reply-to")
        let wrappedMarker = softWrappedLiteralPattern("[tm-agent-reply:")
        let wrappedRequired = softWrappedLiteralPattern("[REQUIRED CORRELATED REPLY for instance")
        let redactions = [
            (#"(?i)(\b\#(wrappedCommand))\#(generatedToken)"#, "$1[REDACTED]"),
            (#"(?i)\#(wrappedMarker)\#(generatedToken)[ \t\r\n]*:[ \t\r\n]*\#(wrappedIdentity)\]"#, "[tm-agent-reply:[REDACTED]]"),
            (#"(?i)(\#(wrappedRequired))\#(wrappedIdentity)\]"#, "$1[REDACTED]]"),
            (#"(?i)(\btm-agent\s+reply\b[^\r\n]*?\s--reply-to(?:=|\s+))(?:\"[A-Za-z0-9_-]{1,128}\"|'[A-Za-z0-9_-]{1,128}'|[A-Za-z0-9_-]{1,128})"#, "$1[REDACTED]"),
            (#"(?i)\[tm-agent-reply:[A-Za-z0-9_-]{1,128}:[A-Za-z0-9_-]{1,128}\]"#, "[tm-agent-reply:[REDACTED]]"),
            (#"(?i)(\[REQUIRED CORRELATED REPLY for instance\s+)[A-Za-z0-9_-]{1,128}(\])"#, "$1[REDACTED]$2"),
        ]
        for (pattern, template) in redactions {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized),
                withTemplate: template
            )
        }
        return sanitized
    }

    private static func softWrappedLiteralPattern(_ literal: String) -> String {
        literal.compactMap { character -> String? in
            guard !character.isWhitespace else { return nil }
            return NSRegularExpression.escapedPattern(for: String(character)) + #"[ \t\r\n]*"#
        }.joined()
    }

    private func asyncTeamRead(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = params["agent_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        let selection = await resolveTeamAgentInstance(params: params, teamName: teamName, agentName: agentName)
        if let failure = selection.failure { return v2Result(id: id, failure) }
        guard let agentInstanceId = selection.instanceId else {
            return v2Error(id: id, code: "not_found", message: "Agent not found")
        }
        let lineLimit = params["lines"] as? Int

        // Minimal MainActor hold: snapshot either native transcript rows or
        // terminal raw bytes. Terminal base64 decoding remains off-main.
        let (response, isNative, errResult): (String?, Bool, V2CallResult?) = await MainActor.run {
            if let session = TeamOrchestrator.shared.nativeAgentSession(
                teamName: teamName,
                agentName: agentName,
                agentInstanceId: agentInstanceId
            ) {
                return (session.visibleTranscriptText(lineLimit: lineLimit), true, nil)
            }
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else {
                return (nil, false, .err(code: "unavailable", message: "TabManager not available", data: nil))
            }
            if let panel = TeamOrchestrator.shared.agentPanel(
                teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId, tabManager: tabManager
            ) else {
                return (nil, false, .err(code: "not_found", message: "Agent not found", data: nil))
            }
            return (self.readTerminalTextBase64(
                terminalPanel: panel, includeScrollback: true, lineLimit: lineLimit
            ), false, nil)
        }

        if let errResult {
            return v2Result(id: id, errResult)
        }
        if isNative {
            let text = Self.sanitizedTeamReadOutput(response ?? "")
            return v2Ok(id: id, result: ["text": text, "agent_name": agentName,
                                        "agent_instance_id": agentInstanceId, "team_name": teamName])
        }
        // Base64 decode off-main.
        guard let response, response.hasPrefix("OK ") else {
            return v2Result(id: id, .err(code: "internal_error", message: response ?? "No response", data: nil))
        }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let text = Self.sanitizedTeamReadOutput(decoded)
        return v2Ok(id: id, result: ["text": text, "agent_name": agentName,
                                    "agent_instance_id": agentInstanceId, "team_name": teamName])
    }

    private func asyncTeamCollect(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let lineLimit = params["lines"] as? Int

        // Get panel references with minimal MainActor hold time
        let panels: [(name: String, instanceId: String, panel: TerminalPanel)] = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return [] }
            return TeamOrchestrator.shared.allAgentPanels(teamName: teamName, tabManager: tabManager)
        }

        // Parallel per-agent reads using TaskGroup.
        // Each child task does: MainActor.run (read raw bytes) → base64 decode off-main.
        // Since MainActor is serial, reads still execute one-at-a-time on main,
        // but base64 decoding of agent N overlaps with the MainActor read of agent N+1.
        let agentTexts: [(Int, [String: Any])] = await withTaskGroup(
            of: (Int, [String: Any]).self
        ) { group in
            for (index, (name, instanceId, panel)) in panels.enumerated() {
                let taskId = TeamDataStore.shared.agentDataEnrichment(
                    teamName: teamName, agentName: name, agentInstanceId: instanceId
                )["active_task_id"] as? String
                group.addTask {
                    let base64Str: String = await MainActor.run {
                        self.readTerminalTextBase64(
                            terminalPanel: panel, includeScrollback: true, lineLimit: lineLimit
                        )
                    }
                    // Decode base64 off-main
                    var text = ""
                    if base64Str.hasPrefix("OK ") {
                        let raw = String(base64Str.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                        text = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    }
                    return (index, [
                        "agent_name": name,
                        "agent_instance_id": instanceId,
                        "task_id": taskId as Any? ?? NSNull(),
                        "text": text,
                    ] as [String: Any])
                }
            }
            var results: [(Int, [String: Any])] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        // Restore original agent order
        let sorted = agentTexts.sorted { $0.0 < $1.0 }.map(\.1)
        return v2Ok(id: id, result: ["team_name": teamName, "agents": sorted])
    }

    private func asyncTeamList(params: [String: Any], id: Any?) async -> String {
        let teams: [[String: Any]] = await MainActor.run {
            TeamOrchestrator.shared.listTeams()
        }
        return v2Ok(id: id, result: teams)
    }

    private func asyncTeamStatus(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }

        // Minimal MainActor hold: get team struct (agent names, UUIDs, team metadata) only
        // `workingDirectory` is carried because the snapshot used to drop
        // `originalAgentWorkDir`, leaving this path with no real cwd to report
        // and `checkout` falling back to a workspace UUID. Derived here, on the
        // actor that owns the member, so both status implementations answer
        // with the same value.
        let teamInfo: (leaderSessionId: String, workspaceId: String, agents: [(name: String, id: String, instanceId: String, cli: String, model: String, agentType: String, color: String, workspaceId: String, panelId: String?, completedTaskCount: Int, worktreeBranch: String?, worktreePath: String?, hostKey: String?, workingDirectory: String?)], createdAt: String, policyState: String, policyFailure: String?)? = await MainActor.run {
            guard let team = TeamOrchestrator.shared.teamStruct(name: teamName) else { return nil }
            return (
                leaderSessionId: team.leaderSessionId,
                workspaceId: team.workspaceId.uuidString,
                agents: team.agents.map { a in
                    (name: a.name, id: a.id, instanceId: a.agentInstanceId, cli: a.cli, model: a.model, agentType: a.agentType, color: a.color,
                     workspaceId: a.workspaceId.uuidString, panelId: a.panelId?.uuidString,
                     completedTaskCount: a.completedTaskCount, worktreeBranch: a.worktreeBranch, worktreePath: a.worktreePath,
                     hostKey: a.hostKey,
                     workingDirectory: TeamOrchestrator.agentWorkingDirectory(
                        worktreePath: a.worktreePath,
                        originalAgentWorkDir: a.originalAgentWorkDir,
                        teamWorkingDirectory: team.workingDirectory
                     ))
                },
                createdAt: ISO8601DateFormatter().string(from: team.createdAt),
                policyState: team.leaderPolicyState,
                policyFailure: team.leaderPolicyFailureDescription
            )
        }
        guard let teamInfo else {
            return v2Error(id: id, code: "not_found", message: "Team not found")
        }

        // Enrich with data from TeamDataStore (off-main, lock-protected)
        let store = TeamDataStore.shared
        let inboxCount = store.inboxItems(teamName: teamName).count
        let taskTotal = store.taskCount(teamName: teamName)

        let agents: [[String: Any]] = teamInfo.agents.map { agent in
            let enrichment = store.agentDataEnrichment(
                teamName: teamName, agentName: agent.name, agentInstanceId: agent.instanceId
            )
            var info: [String: Any] = [
                "id": agent.id,
                "name": agent.name,
                "agent_instance_id": agent.instanceId,
                "cli": agent.cli,
                "model": agent.model,
                "agent_type": agent.agentType,
                "workspace_id": agent.workspaceId,
                "completed_task_count": agent.completedTaskCount,
            ]
            if let pid = agent.panelId {
                info["panel_id"] = pid
            }
            // Merge data enrichment (task, heartbeat, agent_state)
            for (key, value) in enrichment { info[key] = value }
            if let branch = agent.worktreeBranch { info["worktree_branch"] = branch }
            // Worktree lifecycle only — present when a task created one.
            // `working_directory` is where the pane is, and is always answered.
            if let path = agent.worktreePath { info["worktree_path"] = path }
            info["working_directory"] = agent.workingDirectory as Any? ?? NSNull()
            info["locality"] = TeamOrchestrator.agentLocality(hostKey: agent.hostKey)
            info["parallel_telemetry"] = [
                "wave_id": (enrichment["active_task_id"] as? String) ?? agent.instanceId,
                "task_id": enrichment["active_task_id"] ?? NSNull(),
                "agent_instance_id": agent.instanceId,
                "host": agent.hostKey ?? NSNull(),
                "locality": TeamOrchestrator.agentLocality(hostKey: agent.hostKey),
                // The pane's real cwd. A workspace UUID here reads like a
                // machine identifier and was taken for one.
                "checkout": agent.workingDirectory as Any? ?? NSNull(),
                "delivery": (enrichment["agent_state"] as? String) ?? "unknown",
                "synthesis": "pending",
            ]
            return info
        }.sorted { ($0["agent_instance_id"] as? String ?? "") < ($1["agent_instance_id"] as? String ?? "") }

        return v2Ok(id: id, result: [
            "team_name": teamName,
            "leader_session_id": teamInfo.leaderSessionId,
            "workspace_id": teamInfo.workspaceId,
            "agent_count": teamInfo.agents.count,
            "agents": agents,
            "attention_count": inboxCount,
            "task_count": taskTotal,
            "created_at": teamInfo.createdAt,
            "leader_policy_version": LeaderParallelPolicy.version,
            "leader_policy_digest": LeaderParallelPolicy.digest,
            "leader_policy_source": "LeaderParallelPolicy",
            "leader_policy_state": teamInfo.policyState,
            "leader_policy_failure": teamInfo.policyFailure as Any? ?? NSNull(),
        ] as [String: Any])
    }

    private func asyncTeamInbox(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let agentName = params["agent_name"] as? String
        let topOnly = params["top_only"] as? Bool ?? false
        let items: [[String: Any]] = await MainActor.run {
            TeamOrchestrator.shared.inboxItems(teamName: teamName, agentName: agentName, topOnly: topOnly)
        }
        return v2Ok(id: id, result: ["team_name": teamName, "items": items, "count": items.count])
    }

    private func asyncTeamAgentStatus(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = params["agent_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        // Minimal MainActor hold: get agent struct only
        let selection = await resolveTeamAgentInstance(params: params, teamName: teamName, agentName: agentName)
        if let failure = selection.failure { return v2Result(id: id, failure) }
        guard let agentInstanceId = selection.instanceId else {
            return v2Error(id: id, code: "not_found", message: "Agent not found")
        }
        let agentInfo: (id: String, name: String, cli: String, model: String, agentType: String, color: String, workspaceId: String, panelId: String?, worktreeBranch: String?, worktreePath: String?)? = await MainActor.run {
            guard let agent = TeamOrchestrator.shared.resolveAgentForRPC(
                teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId
            ).agent else { return nil }
            return (id: agent.id, name: agent.name, cli: agent.cli, model: agent.model,
                    agentType: agent.agentType, color: agent.color,
                    workspaceId: agent.workspaceId.uuidString, panelId: agent.panelId?.uuidString,
                    worktreeBranch: agent.worktreeBranch, worktreePath: agent.worktreePath)
        }
        guard let agentInfo else {
            return v2Error(id: id, code: "not_found", message: "Agent not found")
        }
        // Enrich off-main
        let enrichment = TeamDataStore.shared.agentDataEnrichment(teamName: teamName, agentName: agentName)
        var info: [String: Any] = [
            "id": agentInfo.id, "name": agentInfo.name, "cli": agentInfo.cli,
            "model": agentInfo.model, "agent_type": agentInfo.agentType,
            "workspace_id": agentInfo.workspaceId,
            "agent_instance_id": agentInstanceId,
        ]
        if let pid = agentInfo.panelId {
            info["panel_id"] = pid
        }
        for (key, value) in enrichment { info[key] = value }
        if let branch = agentInfo.worktreeBranch { info["worktree_branch"] = branch }
        if let path = agentInfo.worktreePath { info["worktree_path"] = path }
        return v2Ok(id: id, result: info)
    }

    // MARK: - Async Task Lifecycle Handlers (data change + UI notification)

    /// Pattern: data mutation via TeamDataStore (off-main) → UI notification via MainActor.run (cooperative)

    private func asyncTeamTaskStart(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let assignee = (params["assignee"] as? String) ?? (params["assign"] as? String)
        let progressNote = params["progress_note"] as? String
        let store = TeamDataStore.shared

        // Data mutation off-main
        guard let task = store.updateTask(
            teamName: teamName, taskId: taskId,
            status: "in_progress", assignee: assignee, progressNote: progressNote
        ) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }

        // Dispatch to assignee via MainActor (cooperative) — pass task directly
        // to avoid reading from TeamOrchestrator.taskBoards (stale data source)
        let dispatched = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.dispatchTaskToAssignee(
                teamName: teamName, task: task, tabManager: tabManager
            )
        }
        return v2Ok(id: id, result: ["task": store.taskDictionary(task), "dispatched": dispatched])
    }

    private func asyncTeamTaskBlock(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let reason = params["blocked_reason"] as? String
        let store = TeamDataStore.shared

        guard let task = store.updateTask(
            teamName: teamName, taskId: taskId,
            status: "blocked", blockedReason: reason
        ) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }

        let notified = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.notifyTaskLifecycleEvent(
                teamName: teamName, task: task, event: "blocked", note: reason, tabManager: tabManager
            )
        }
        return v2Ok(id: id, result: ["task": store.taskDictionary(task), "notified": notified])
    }

    private func asyncTeamTaskReview(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let summary = params["review_summary"] as? String
        let store = TeamDataStore.shared

        guard let task = store.updateTask(
            teamName: teamName, taskId: taskId,
            status: "review_ready", reviewSummary: summary
        ) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }

        let notified = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.notifyTaskLifecycleEvent(
                teamName: teamName, task: task, event: "review_ready", note: summary, tabManager: tabManager
            )
        }
        return v2Ok(id: id, result: ["task": store.taskDictionary(task), "notified": notified])
    }

    private func asyncTeamTaskDone(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let taskResult = params["result"] as? String
        let resultPath = params["result_path"] as? String
        let store = TeamDataStore.shared

        guard let task = store.updateTask(
            teamName: teamName, taskId: taskId,
            status: "completed", result: taskResult, resultPath: resultPath
        ) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }

        let notified = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.notifyTaskLifecycleEvent(
                teamName: teamName, task: task, event: "completed", note: taskResult, tabManager: tabManager
            )
        }
        return v2Ok(id: id, result: ["task": store.taskDictionary(task), "notified": notified])
    }

    private func asyncTeamTaskReassign(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let assignee = params["assignee"] as? String
        let assigneeInstanceId = params["agent_instance_id"] as? String
        let store = TeamDataStore.shared

        guard let task = store.reassignTask(
            teamName: teamName, taskId: taskId, assignee: assignee,
            assigneeInstanceId: assigneeInstanceId
        ) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }

        let dispatched = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.dispatchTaskToAssignee(
                teamName: teamName, task: task, tabManager: tabManager
            )
        }
        var result: [String: Any] = [
            "task": store.taskDictionary(task), "dispatched": dispatched,
        ]
        // Assigning by name when several agents answer to it picks the first.
        // The caller asked for a role and got an instance, and this is the only
        // place that can say so before they act on the answer.
        if assigneeInstanceId?.nilIfBlankTC == nil,
           let warning = store.duplicateNameWarning(teamName: teamName, assignee: assignee) {
            result["duplicate_name_warning"] = warning
        }
        return v2Ok(id: id, result: result)
    }

    private func asyncTeamTaskUnblock(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let store = TeamDataStore.shared

        guard let task = store.unblockTask(
            teamName: teamName, taskId: taskId
        ) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }

        let dispatched = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.dispatchTaskToAssignee(
                teamName: teamName, task: task, tabManager: tabManager
            )
        }
        return v2Ok(id: id, result: ["task": store.taskDictionary(task), "dispatched": dispatched])
    }

    /// Mission Control approval queue — Approve. Mirrors `tm-agent task
    /// finish-worktree --to parent` (`tm_agent.rs:8673`): same lock file
    /// protocol (mutual exclusion with the CLI), same stale-worktree guard,
    /// same `git-kit wt finish` contract. Design:
    /// docs/design/mission-control-approval-queue.md §6.4.
    ///
    /// `push`/`cleanup` default to `false`/`true` (matching the CLI's
    /// `finish-worktree` flag defaults). On success the task transitions to
    /// `completed` exactly like `team.task.done`; on failure it transitions
    /// to `blocked` with the git-kit error as `blocked_reason` (never left in
    /// `review_ready` — that would strand it in the approval queue forever).
    /// Not `private`: called directly (in-process) by
    /// `DashboardController.handleTeamTaskApprove` for the Mission Control
    /// Review Queue's Approve button, in addition to the v2 socket path.
    func asyncTeamTaskApprove(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let push = params["push"] as? Bool ?? false
        let cleanup = params["cleanup"] as? Bool ?? true
        let store = TeamDataStore.shared

        guard let task = store.getTask(teamName: teamName, taskId: taskId) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }
        guard let worktreePath = task.worktreePath?.nilIfBlankTC else {
            return v2Error(
                id: id, code: "invalid_state",
                message: "Task has no worktree — nothing to finish. Use team.task.done for non-worktree tasks."
            )
        }

        let outcome = await WorktreeApprovalHelper.finish(
            teamName: teamName, taskId: taskId, worktreePath: worktreePath,
            baseRef: task.worktreeParent, push: push, cleanup: cleanup
        )

        switch outcome {
        case .success(let mode, let removed):
            guard let updated = store.updateTask(
                teamName: teamName, taskId: taskId, status: "completed",
                worktreeFinishedAt: Date(), worktreeFinishMode: mode, worktreeRemoved: removed
            ) else {
                return v2Error(id: id, code: "not_found", message: "Task not found (race during finish)")
            }
            let notified = await MainActor.run {
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { return false }
                return TeamOrchestrator.shared.notifyTaskLifecycleEvent(
                    teamName: teamName, task: updated, event: "completed",
                    note: "Approved and merged to \(task.worktreeParent ?? "parent")", tabManager: tabManager
                )
            }
            return v2Ok(id: id, result: ["task": store.taskDictionary(updated), "notified": notified])
        case .failure(let reason):
            let blocked = store.updateTask(
                teamName: teamName, taskId: taskId, status: "blocked", blockedReason: reason
            )
            return v2Error(
                id: id, code: "approve_failed", message: reason,
                data: blocked.map { ["task": store.taskDictionary($0)] }
            )
        }
    }

    /// Mission Control approval queue — Reject. With `reassign_to`, routes
    /// the task to a different agent (reuses the existing reassign +
    /// dispatch path, same as `team.task.reassign`). Without it, bounces the
    /// task back to its current assignee as `assigned` with the rejection
    /// reason delivered as a pane message — no new persisted field, since the
    /// worker's next `tm-agent task review` overwrites `review_summary`
    /// anyway. The worktree (if any) is left untouched for rework.
    /// Not `private`: called directly (in-process) by
    /// `DashboardController.handleTeamTaskReject` for the Mission Control
    /// Review Queue's Reject button, in addition to the v2 socket path.
    func asyncTeamTaskReject(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let reason = (params["reason"] as? String)?.nilIfBlankTC ?? "Changes requested"
        let reassignTo = (params["reassign_to"] as? String)?.nilIfBlankTC
        let store = TeamDataStore.shared

        if let reassignTo {
            guard let task = store.reassignTask(
                teamName: teamName, taskId: taskId, assignee: reassignTo
            ) else {
                return v2Error(id: id, code: "not_found", message: "Task not found")
            }
            let dispatched = await MainActor.run {
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { return false }
                return TeamOrchestrator.shared.dispatchTaskToAssignee(
                    teamName: teamName, task: task, tabManager: tabManager
                )
            }
            // Follow-up so the new assignee sees *why* this landed on them —
            // dispatchTaskToAssignee only sends the task capsule, not the
            // rejection reason.
            if dispatched {
                _ = await asyncTeamSend(
                    params: [
                        "team_name": teamName, "agent_name": reassignTo,
                        "text": "This task was reassigned to you after review rejection: \(reason)",
                    ],
                    id: nil
                )
            }
            var result: [String: Any] = [
                "task": store.taskDictionary(task), "dispatched": dispatched,
            ]
            // `reassign_to` is a name — the Reject button has nothing else to
            // give — so the same first-match choice applies and the same
            // warning is owed.
            if let warning = store.duplicateNameWarning(teamName: teamName, assignee: reassignTo) {
                result["duplicate_name_warning"] = warning
            }
            return v2Ok(id: id, result: result)
        }

        guard let task = store.updateTask(
            teamName: teamName, taskId: taskId, status: "assigned"
        ) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }
        let notified: Bool
        if let assignee = task.assignee?.nilIfBlankTC {
            let sendResult = await asyncTeamSend(
                params: [
                    "team_name": teamName, "agent_name": assignee,
                    "text": "Review feedback on task '\(task.title)': \(reason)\n\nPlease address and resubmit with `tm-agent task review \(taskId) '<summary>'`.",
                ],
                id: nil
            )
            notified = sendResult.contains("\"ok\":true")
        } else {
            notified = false
        }
        return v2Ok(id: id, result: ["task": store.taskDictionary(task), "notified": notified])
    }

    private func asyncTeamTaskSplit(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        guard let title = params["title"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing title")
        }
        let assignee = params["assignee"] as? String
        let createdBy = params["created_by"] as? String ?? "leader"
        let store = TeamDataStore.shared

        guard let task = store.splitTask(
            teamName: teamName, parentTaskId: taskId,
            title: title, assignee: assignee, createdBy: createdBy
        ) else {
            return v2Error(id: id, code: "not_found", message: "Task not found")
        }
        return v2Ok(id: id, result: store.taskDictionary(task))
    }

    // MARK: - Team Interrupt Handlers

    /// Send Ctrl+C (ETX) to a single agent, interrupting its current operation.
    private func asyncTeamInterrupt(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = params["agent_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        let selection = await resolveTeamAgentInstance(params: params, teamName: teamName, agentName: agentName)
        if let failure = selection.failure { return v2Result(id: id, failure) }
        guard let agentInstanceId = selection.instanceId else {
            return v2Error(id: id, code: "not_found", message: "Agent not found")
        }
        let success = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.interruptAgent(
                teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId, tabManager: tabManager
            )
        }
        return success
            ? v2Ok(id: id, result: ["interrupted": true, "team_name": teamName,
                                    "agent_name": agentName, "agent_instance_id": agentInstanceId])
            : v2Error(id: id, code: "not_found", message: "Agent or team not found")
    }

    /// Send Ctrl+C (ETX) to ALL agents in a team (or all teams if team_name is "__all__").
    private func asyncTeamInterruptAll(params: [String: Any], id: Any?) async -> String {
        let teamName = params["team_name"] as? String ?? "__all__"
        let count = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return 0 }
            if teamName == "__all__" {
                return TeamOrchestrator.shared.interruptAllTeams(tabManager: tabManager)
            }
            return TeamOrchestrator.shared.interruptAll(teamName: teamName, tabManager: tabManager)
        }
        return v2Ok(id: id, result: ["interrupted_count": count, "team_name": teamName])
    }

    /// Soft-restart an agent CLI in-place: Ctrl-C, wait briefly for the shell prompt,
    /// then type the agent's original launch command and Return into the same pane.
    private func asyncTeamRestart(params: [String: Any], id: Any?) async -> String {
        guard let teamName = (params["team"] ?? params["team_name"]) as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = (params["agent"] ?? params["agent_name"]) as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        let selection = await resolveTeamAgentInstance(params: params, teamName: teamName, agentName: agentName)
        if let failure = selection.failure { return v2Result(id: id, failure) }
        guard let agentInstanceId = selection.instanceId else {
            return v2Error(id: id, code: "not_found", message: "Agent not found")
        }
        // Dispatch on mode: "soft" (default, in-place ETX+retype) | "hard" (close + respawn)
        let mode = ((params["mode"] as? String) ?? "soft").lowercased()
        if mode == "hard" {
            return await asyncTeamRestartHard(teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId, id: id)
        }

        let result: (sent: Bool, targetMissing: Bool, reason: String, launchCommand: String) = await withCheckedContinuation { continuation in
            Task { @MainActor in
                @MainActor func resume(sent: Bool, targetMissing: Bool, reason: String, launchCommand: String) {
                    continuation.resume(returning: (sent, targetMissing, reason, launchCommand))
                }
                guard let identity = TeamOrchestrator.shared.agentIdentity(teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId) else {
                    resume(sent: false, targetMissing: true, reason: "agent_not_found", launchCommand: "")
                    return
                }
                // Preview shows the invocation that will actually be retyped (full original
                // when captured, bare binary name otherwise) so callers can verify recovery.
                let previewCommand: String = {
                    if let original = identity.originalSpawnCommand, !original.isEmpty {
                        return original
                    }
                    return identity.launchCommand
                }()
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                let scheduled = TeamOrchestrator.shared.restartAgentPane(
                    panelId: identity.panelId,
                    tabManager: tabManager
                ) { sent in
                    Task { @MainActor in
                        resume(
                            sent: sent,
                            targetMissing: false,
                            reason: sent ? "ok" : "launch_delivery_failed",
                            launchCommand: previewCommand
                        )
                    }
                }
                if !scheduled {
                    resume(sent: false, targetMissing: true, reason: "surface_not_found", launchCommand: previewCommand)
                    return
                }
            }
        }

        return result.sent
            ? v2Ok(id: id, result: [
                "restarted": true,
                "team_name": teamName,
                "agent_name": agentName,
                "agent_instance_id": agentInstanceId,
                "launch_command_preview": String(result.launchCommand.prefix(120)),
                "launch_command_len": result.launchCommand.count,
            ])
            : v2Error(
                id: id,
                code: result.targetMissing ? "not_found" : "delivery_failed",
                message: result.targetMissing ? "Agent or surface not found" : "Agent restart failed: \(result.reason)",
                data: [
                    "restarted": false,
                    "delivery_failed": !result.targetMissing,
                    "reason": result.reason,
                    "team_name": teamName,
                    "agent_name": agentName,
                    "launch_command_preview": String(result.launchCommand.prefix(120)),
                    "launch_command_len": result.launchCommand.count,
                ]
            )
    }

    /// Hard restart — close the agent pane and respawn it in the same slot.
    /// Routing (name → panelId) updates in Swift in-memory teams; daemon mirror
    /// follows via syncTeamStateToDaemon. No dedicated RPC on the daemon side.
    private func asyncTeamRestartHard(teamName: String, agentName: String, agentInstanceId: String, id: Any?) async -> String {
        let outcome: Result<(old: UUID, new: UUID), TeamOrchestrator.RestartHardError>
            = await MainActor.run {
                Task { @MainActor in
                    guard let panelId = TeamOrchestrator.shared.resolveAgentForRPC(
                        teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId
                    ).agent?.panelId else { return .failure(.agentNotFound) }
                    return await TeamOrchestrator.shared.restartAgentPaneHard(panelId: panelId)
                }
            }.value
        switch outcome {
        case .success(let r):
            return v2Ok(id: id, result: [
                "restarted": true,
                "mode": "hard",
                "team_name": teamName,
                "agent_name": agentName,
                "agent_instance_id": agentInstanceId,
                "old_panel_id": r.old.uuidString,
                "new_panel_id": r.new.uuidString,
            ])
        case .failure(let err):
            return v2Error(id: id, code: err.code, message: err.message, data: [
                "restarted": false,
                "mode": "hard",
                "team_name": teamName,
                "agent_name": agentName,
            ])
        }
    }

    /// The delegate idempotency key as it arrives on the wire.
    ///
    /// Static and pure so the wiring is pinned by a test: the store has deduped
    /// on this since 5c95ab10 and the CLI has sent it since d168ad61, and the
    /// only thing that was ever missing was somebody reading it here.
    nonisolated static func delegateRequestID(from params: [String: Any]) -> String? {
        guard let raw = params["request_id"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What is holding the pool, phrased so the next command is obvious.
    ///
    /// `review_ready` is the common one and the reason this exists: it is not a
    /// terminal status, so the agent stays out of the pool until someone closes
    /// the task — and the old message said "Task creation failed", which sent
    /// the reader looking at the store instead.
    ///
    /// Pure and static so the wording is pinned by a test rather than by
    /// reading it off a running app.
    nonisolated static func delegateBlockerSummary(
        _ blockers: [TeamOrchestrator.DelegateBlocker]
    ) -> String {
        guard !blockers.isEmpty else {
            // Every instance was ineligible for a reason other than a task:
            // parked, migrating, no pane, or still thinking.
            return "every instance is parked, migrating or still working. "
                + "Retry shortly, or pass --agent-instance-id to target one exactly."
        }
        let listed = blockers
            .map { "\($0.taskID) (\($0.status))" }
            .joined(separator: ", ")
        return "blocked by active task(s): \(listed). "
            + "Close one with `tm-agent task done <id>`, or pass --agent-instance-id "
            + "to target an instance exactly."
    }

    /// Unified delegate handler: atomically creates a task and dispatches the formatted
    /// instruction to the agent in a single RPC. Replaces the 2-step team.task.create +
    /// team.send pattern used by `tm-agent delegate` as fallback.
    /// Rust sends "team"/"agent" keys (not "team_name"/"agent_name").
    private func asyncTeamDelegate(params: [String: Any], id: Any?) async -> String {
        guard let teamName = (params["team"] ?? params["team_name"]) as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team")
        }
        guard let agentName = (params["agent"] ?? params["agent_name"]) as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent")
        }
        guard let text = params["text"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing text")
        }

        // Reject comma-separated agent names — fan-out should be handled client-side
        if agentName.contains(",") {
            return v2Error(id: id, code: "invalid_params",
                           message: "agent name must not contain commas; use fan-out for multiple agents")
        }

        // An explicit instance stays exact. Without it, scheduling happens on
        // the main actor inside `delegateToAgent`, where idle-state check,
        // cursor advance, task assignment and delivery share one serial turn.
        var requestedInstanceId = params["agent_instance_id"] as? String
        if let requestedInstanceId, !requestedInstanceId.isEmpty {
            let selection = await resolveTeamAgentInstance(
                params: params, teamName: teamName, agentName: agentName
            )
            if let failure = selection.failure { return v2Result(id: id, failure) }
        } else if let rawPanelID = (params["panel_id"] as? String)?.nilIfBlankTC {
            // A caller that named a pane has already chosen; honouring only
            // `agent_instance_id` threw that away and fell through to the pool,
            // where `resolveAssigneeUnsafe`'s name-only auto-pin hands the work
            // to whichever same-named sibling happens to be first. Silent, and
            // wrong exactly when duplicate names make it matter.
            guard let panelID = UUID(uuidString: rawPanelID) else {
                return v2Error(
                    id: id, code: "invalid_params",
                    message: "panel_id '\(rawPanelID)' is not a UUID"
                )
            }
            let resolved = await MainActor.run {
                TeamOrchestrator.shared.agentInstanceID(
                    teamName: teamName, agentName: agentName, panelID: panelID
                )
            }
            guard let resolved else {
                // Refused rather than guessed: the caller pointed at one pane,
                // and picking a different one is not a smaller failure.
                return v2Error(
                    id: id, code: "not_found",
                    message: "No pane \(rawPanelID) belongs to agent '\(agentName)' in team "
                        + "'\(teamName)'. Pass agent_instance_id, or omit panel_id to use the pool."
                )
            }
            requestedInstanceId = resolved
        }

        let taskTitle = params["task_title"] as? String
        let priority = params["priority"] as? Int
        let context = params["context"] as? String
        // The CLI has sent a stable id per delegate since d168ad61, and
        // `TeamDataStore.createTask` has deduped on it since 5c95ab10 — but
        // nothing in between read it, so a retried delegate still created a
        // second task. This is the missing wire.
        let requestId = TerminalController.delegateRequestID(from: params)
        let store = TeamDataStore.shared

        // Stagger: dynamic gap based on team size to prevent main-queue saturation
        // when many team.delegate commands arrive in rapid succession (fan-out).
        let delegateStaggerNs = await MainActor.run {
            let count = TeamOrchestrator.shared.teams[teamName]?.agents.count ?? 1
            return TerminalController.reserveTeamSendSlot(agentCount: count)
        }
        if delegateStaggerNs > 0 {
            try? await Task.sleep(nanoseconds: delegateStaggerNs)
        }

        // Create task + send instruction on MainActor, then await paste-completion ack.
        // Continuation resumes when finalizePaste fires (via sendIMETextResult callback)
        // or after a 12s last-resort timeout. Timeout must exceed paste watchdog (8s)
        // plus max retry backoff (~2s) to avoid racing a still-live paste in the queue.
        // Primary completion path is the watchdog's finalizePaste; 12s is a dead-man switch
        // for cases where completion is never called due to a deeper bug.
        // The Rust CLI sends Return via team.send_key only after receiving this ack,
        // eliminating the race between paste flush and the previous 150ms fixed sleep.
        var capturedOutcome: TeamOrchestrator.DelegateOutcome? = nil
        let textDelivered: Bool = await withCheckedContinuation { cont in
            var resumed = false
            let resume: (Bool) -> Void = { ok in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: ok)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { resume(false) }
            Task { @MainActor in
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { resume(false); return }
                let outcome = TeamOrchestrator.shared.delegate(
                    teamName: teamName,
                    agentName: agentName,
                    agentInstanceId: requestedInstanceId,
                    text: text,
                    taskTitle: taskTitle,
                    priority: priority,
                    context: context,
                    requestId: requestId,
                    tabManager: tabManager,
                    completion: { ok in resume(ok) }
                )
                capturedOutcome = outcome
                if case .delivered = outcome {} else { resume(false) }
            }
        }

        let delegateResult: TeamOrchestrator.DelegateResult
        switch capturedOutcome {
        case .delivered(let result):
            delegateResult = result
        case .noSuchAgent:
            return v2Error(
                id: id, code: "not_found",
                message: "No agent named '\(agentName)' in team '\(teamName)'"
            )
        case .allInstancesBusy(let blockers):
            // The id is the actionable half: without it the leader is told an
            // agent is busy and has to go find out what with.
            return v2Error(
                id: id, code: "agent_busy",
                message: "Agent '\(agentName)' has no idle instance — "
                    + TerminalController.delegateBlockerSummary(blockers)
            )
        case .taskCreateFailed:
            return v2Error(
                id: id, code: "internal_error",
                message: "Task creation failed for agent '\(agentName)'"
            )
        case nil:
            // The 12s dead-man switch fired before the main-actor block ran.
            return v2Error(
                id: id, code: "timeout",
                message: "Delegate to '\(agentName)' did not complete in time"
            )
        }

        var returnSubmitted = false
        if delegateResult.requestReplayed {
            // The original idempotent operation already owned text delivery.
            // A remote-leader retry also committed Return in that operation;
            // submitting it again would execute an empty or duplicate turn.
            returnSubmitted = params["submit_return"] as? Bool == true
        } else if textDelivered, params["submit_return"] as? Bool == true {
            let keyParams: [String: Any] = [
                "team": teamName,
                "agent": agentName,
                "key": "return",
                "agent_instance_id": delegateResult.task.assigneeInstanceId ?? NSNull(),
            ]
            let keyResponse = await asyncTeamSendKey(params: keyParams, id: id)
            if let data = keyResponse.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = object["result"] as? [String: Any] {
                returnSubmitted = result["sent"] as? Bool == true
            }
            guard returnSubmitted else {
                return v2Error(
                    id: id,
                    code: "delivery_failed",
                    message: "Instruction text was delivered but Return submission failed"
                )
            }
        }

        // delegateToAgent sends text WITHOUT Return (withReturn: false).
        // The Rust CLI sends Return separately via team.send_key RPC after this ack.
        return v2Ok(id: id, result: [
            "task": store.taskDictionary(delegateResult.task),
            "sent": true,
            "text_delivered": textDelivered,
            "return_submitted": returnSubmitted,
            "request_replayed": delegateResult.requestReplayed,
            "agent_instance_id": delegateResult.task.assigneeInstanceId ?? NSNull(),
        ])
    }

    /// Send a named key (return, ctrl-c, etc.) to an agent's terminal surface.
    /// Uses the same `sendNamedKey` path as `surface.send_key` RPC — proven reliable
    /// for Return delivery to TUI apps (Claude Code).
    private func asyncTeamSendKey(params: [String: Any], id: Any?) async -> String {
        guard let teamName = (params["team"] ?? params["team_name"]) as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = (params["agent"] ?? params["agent_name"]) as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        guard let key = params["key"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing key")
        }
        let sendSequenceID = params["send_sequence_id"] as? String
        let selection = await resolveTeamAgentInstance(
            params: params, teamName: teamName, agentName: agentName
        )
        if let failure = selection.failure { return v2Result(id: id, failure) }
        guard let agentInstanceId = selection.instanceId else {
            return v2Error(id: id, code: "not_found", message: "Agent not found")
        }
        let agentKey = "\(teamName)/\(agentInstanceId)"
        // Claim ownership before touching the keyboard. Merely using the token
        // during cleanup is too late: a stale Return could already have
        // submitted a newer sequence's pasted text.
        let claimedGate: SendGate? = key.lowercased() == "return"
            ? await MainActor.run {
                TerminalController.takeAcknowledgedSendGate(
                    agentKey: agentKey,
                    sequenceID: sendSequenceID
                )
            }
            : nil
        if key.lowercased() == "return", let sendSequenceID, claimedGate == nil {
            return v2Error(
                id: id,
                code: "stale_send_sequence",
                message: "Return delivery does not own an active send sequence",
                data: ["sent": false, "send_sequence_id": sendSequenceID]
            )
        }
        // An agent held natively has no keyboard to press Return on, and needs
        // none: the write to its stdin was already a whole turn, submitted the
        // moment it landed. The caller is asking "is this turn in?", and the
        // answer is yes — so it is answered here rather than left to a ladder
        // that can only fail, eight times, over eleven seconds, ending in a
        // warning about a Return nothing was waiting for.
        if key.lowercased() == "return",
           await MainActor.run(body: {
               !TeamOrchestrator.shared.agentNeedsReturn(
                   teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId
               )
           }) {
            if let claimedGate {
                await MainActor.run {
                    TerminalController.discardSendGate(claimedGate, agentKey: agentKey)
                }
            }
            return v2Ok(id: id, result: ["sent": true, "no_keyboard": true,
                                         "team_name": teamName, "agent_name": agentName])
        }

        let result: (sent: Bool, targetMissing: Bool, reason: String) = await withCheckedContinuation { continuation in
            Task { @MainActor in
                @MainActor func resume(sent: Bool, targetMissing: Bool, reason: String) {
                    continuation.resume(returning: (sent, targetMissing, reason))
                }
                @MainActor func deliver(to terminalSurface: TerminalSurface) {
                    self.sendNamedKeyWithRetry(on: terminalSurface, keyName: key) { sent, reason in
                        if sent {
                            terminalSurface.forceRefresh()
                        }
                        resume(sent: sent, targetMissing: false, reason: reason)
                    }
                }

                // Resolve the instance at key-delivery time. Do not reuse a
                // panel_id captured before a restart/migration async gap.
                let liveAgent = TeamOrchestrator.shared.resolveAgentForRPC(
                    teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId
                ).agent
                let pid: UUID
                let workspaceId: UUID
                guard let liveAgent else {
                    resume(sent: false, targetMissing: true, reason: "agent_not_found")
                    return
                }
                guard let agentPanelId = liveAgent.panelId else {
                    resume(sent: false, targetMissing: true, reason: "headless_no_pane")
                    return
                }
                pid = agentPanelId
                workspaceId = liveAgent.workspaceId
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager,
                      let ws = tabManager.tabs.first(where: { $0.id == workspaceId }),
                      let panel = ws.terminalPanel(for: pid) else {
                    // Fallback: try global surface lookup
                    if let located = AppDelegate.shared?.locateSurface(surfaceId: pid),
                       let ws2 = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                       let panel2 = ws2.terminalPanel(for: pid) {
                        deliver(to: panel2.surface)
                        return
                    }
                    resume(sent: false, targetMissing: true, reason: "surface_not_found")
                    return
                }
                deliver(to: panel.surface)
            }
        }

        // After Return delivery: wait 250 ms cooldown then open the per-agent gate
        // so the next paste+Return sequence can proceed. This is the companion to the
        // gate enqueued in asyncTeamSend; together they serialize consecutive sends to
        // the same codex/agent pane and prevent TUI submit-window drops.
        if result.sent && key.lowercased() == "return" {
            await MainActor.run {
                TeamOrchestrator.shared.clearPendingReturnTarget(
                    teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId
                )
            }
            try? await Task.sleep(nanoseconds: TerminalController.kPostReturnCooldownNs)
            if let claimedGate {
                await MainActor.run {
                    TerminalController.discardSendGate(claimedGate, agentKey: agentKey)
                }
            }
        } else if key.lowercased() == "return", let claimedGate {
            // The CLI may retry the same sequence after a transient key-send
            // failure. Restore its ownership without opening the next paste.
            await MainActor.run {
                TerminalController.restoreClaimedSendGate(claimedGate, agentKey: agentKey)
            }
        }

        return result.sent
            ? v2Ok(id: id, result: ["sent": true, "team_name": teamName, "agent_name": agentName,
                                    "agent_instance_id": agentInstanceId, "key": key])
            : v2Error(
                id: id,
                code: result.targetMissing ? "not_found" : "delivery_failed",
                message: result.targetMissing ? "Agent or surface not found" : "Key delivery failed: \(result.reason)",
                data: [
                    "sent": false,
                    "delivery_failed": !result.targetMissing,
                    "reason": result.reason,
                    "team_name": teamName,
                    "agent_name": agentName,
                    "key": key,
                ]
            )
    }

    // MARK: - Per-Agent Send Serialization

    /// One-shot async gate used to serialize paste+Return sequences per agent.
    /// asyncTeamSend enqueues a gate; asyncTeamSendKey opens it after the post-Return
    /// cooldown. A watchdog removes this exact sequence by identity before
    /// opening it, so a stale Return can never dequeue a newer queue head.
    final class SendGate: @unchecked Sendable {
        let sequenceID = UUID().uuidString
        let sequenceAware: Bool
        private var cont: CheckedContinuation<Void, Never>?
        private var opened = false
        private var awaitingReturn = false
        private let lock = NSLock()

        init(sequenceAware: Bool = true) {
            self.sequenceAware = sequenceAware
        }

        func markAwaitingReturn() {
            lock.withLock { awaitingReturn = true }
        }

        var isAwaitingReturn: Bool {
            lock.withLock { awaitingReturn }
        }

        var isOpen: Bool {
            lock.withLock { opened }
        }

        func wait() async {
            await withCheckedContinuation { c in
                lock.withLock {
                    if opened { c.resume() } else { cont = c }
                }
            }
        }

        func open() {
            lock.withLock {
                guard !opened else { return }
                opened = true
                cont?.resume()
                cont = nil
            }
        }
    }

    /// All protocol generations share one serialization order, while Return
    /// ownership is indexed separately. A tokenless legacy Return can therefore
    /// release only a legacy send and can never guess at a sequence-aware gate.
    @MainActor private static var perAgentSerializationQueue: [String: [SendGate]] = [:]
    @MainActor private static var perAgentGateQueue: [String: [SendGate]] = [:]
    @MainActor private static var perAgentLegacyGateQueue: [String: [SendGate]] = [:]

    @MainActor static func enqueueSendGate(
        agentKey: String,
        sequenceAware: Bool = true
    ) -> (SendGate?, SendGate) {
        let previous = perAgentSerializationQueue[agentKey]?.last
        let gate = SendGate(sequenceAware: sequenceAware)
        perAgentSerializationQueue[agentKey, default: []].append(gate)
        if sequenceAware {
            perAgentGateQueue[agentKey, default: []].append(gate)
        } else {
            perAgentLegacyGateQueue[agentKey, default: []].append(gate)
        }
        return (previous, gate)
    }

    /// Covers the 12 s paste acknowledgement window plus the CLI's ~11 s
    /// Return retry ladder and cooldown. Starting it only after the gate becomes
    /// active prevents a queued send from expiring behind a slow predecessor.
    private static let kSendGateWatchdogNs: UInt64 = 30_000_000_000

    private static func startSendGateWatchdog(_ gate: SendGate, agentKey: String) {
        Task.detached {
            try? await Task.sleep(nanoseconds: kSendGateWatchdogNs)
            await MainActor.run {
                discardSendGate(gate, agentKey: agentKey)
            }
        }
    }

    /// A token-aware Return owns exactly one new-protocol sequence. A tokenless
    /// Return can claim only the oldest acknowledged legacy send; delegate and
    /// native compatibility Returns see nil when no such legacy send exists.
    /// Claim removes only the Return-ownership index: the shared serialization
    /// entry remains until successful delivery plus cooldown (or watchdog), so
    /// a concurrently arriving paste cannot overtake the Return in progress.
    @MainActor static func takeAcknowledgedSendGate(
        agentKey: String,
        sequenceID: String?
    ) -> SendGate? {
        var queue: [SendGate]
        let index: Array<SendGate>.Index?
        if let sequenceID {
            guard let awareQueue = perAgentGateQueue[agentKey] else { return nil }
            queue = awareQueue
            index = queue.firstIndex {
                $0.sequenceID == sequenceID && $0.isAwaitingReturn
            }
        } else {
            guard let legacyQueue = perAgentLegacyGateQueue[agentKey] else { return nil }
            queue = legacyQueue
            index = queue.firstIndex { $0.isAwaitingReturn }
        }
        guard let index else { return nil }
        let gate = queue.remove(at: index)
        if sequenceID == nil {
            perAgentLegacyGateQueue[agentKey] = queue.isEmpty ? nil : queue
        } else {
            perAgentGateQueue[agentKey] = queue.isEmpty ? nil : queue
        }
        return gate
    }

    @MainActor static func restoreClaimedSendGate(_ gate: SendGate, agentKey: String) {
        guard !gate.isOpen else { return }
        if gate.sequenceAware {
            guard !(perAgentGateQueue[agentKey]?.contains(where: { $0 === gate }) ?? false) else { return }
            perAgentGateQueue[agentKey, default: []].insert(gate, at: 0)
        } else {
            guard !(perAgentLegacyGateQueue[agentKey]?.contains(where: { $0 === gate }) ?? false) else { return }
            perAgentLegacyGateQueue[agentKey, default: []].insert(gate, at: 0)
        }
    }

    /// Removes a send that will never receive the companion `team.send_key`.
    /// Identity matching keeps an earlier/later in-flight send's gate intact.
    @MainActor static func discardSendGate(_ gate: SendGate, agentKey: String) {
        removeGateIdentity(gate, from: &perAgentSerializationQueue, agentKey: agentKey)
        removeGateIdentity(gate, from: &perAgentGateQueue, agentKey: agentKey)
        removeGateIdentity(gate, from: &perAgentLegacyGateQueue, agentKey: agentKey)
        gate.open()
    }

    @MainActor private static func removeGateIdentity(
        _ gate: SendGate,
        from queues: inout [String: [SendGate]],
        agentKey: String
    ) {
        guard var queue = queues[agentKey],
              let index = queue.firstIndex(where: { $0 === gate }) else { return }
        queue.remove(at: index)
        queues[agentKey] = queue.isEmpty ? nil : queue
    }

    /// Cooldown after Return delivery before the next paste is allowed (ms → ns).
    private static let kPostReturnCooldownNs: UInt64 = 250_000_000 // 250 ms

    // MARK: - Team Send Stagger

    /// Minimum gap (nanoseconds) between consecutive team.send/team.delegate MainActor dispatches.
    /// Mirrors the 100ms stagger used in asyncTeamBroadcast to prevent GCD main-queue
    /// saturation when the CLI targets many agents in rapid succession.
    private static let kTeamSendStaggerNs: UInt64 = 100_000_000 // 100ms

    /// Monotonic dispatch clock for stagger bookkeeping. Protected by @MainActor.
    /// Each team.send/team.delegate call atomically reads and advances this value so
    /// concurrent callers spread their main-thread work across 100ms windows.
    @MainActor private static var teamSendLastDispatchNs: UInt64 = 0

    /// Computes how long to sleep before the next team.send/team.delegate dispatch so
    /// that successive sends are staggered by at least a dynamic interval.
    /// When `agentCount` > 1, the per-agent stagger shrinks so total fan-out stays
    /// within a ~5s budget: `max(30ms, 5s / agentCount)`, capped at 100ms.
    /// Must be called on the MainActor; atomically reserves the next dispatch slot.
    @MainActor private static func reserveTeamSendSlot(agentCount: Int = 1) -> UInt64 {
        let count = UInt64(max(agentCount, 1))
        // Dynamic stagger: 5s budget / agentCount, floor 30ms, cap 100ms
        let dynamicStagger = min(kTeamSendStaggerNs, max(30_000_000, 5_000_000_000 / count))
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = teamSendLastDispatchNs > 0 ? now &- teamSendLastDispatchNs : dynamicStagger
        let delay = elapsed < dynamicStagger ? dynamicStagger - elapsed : 0
        // Reserve the slot: advance the expected-next-dispatch cursor atomically
        teamSendLastDispatchNs = now + delay
        return delay
    }

    // MARK: - V2 Team Data Dispatch (Approach C: Dual Queue)

    /// Data-only team commands that are safe to run off the main thread.
    private static let teamDataCommands: Set<String> = [
        "team.message.post",
        "team.message.list",
        "team.message.clear",
        "team.correlation.register",
        "team.correlation.get",
        "team.correlation.cancel",
        "team.report",
        "team.result.status",
        "team.result.collect",
        "team.agent.heartbeat",
        "team.inbox",
        "team.watch_drift.post",
        "team.task.get",
        "team.task.list",
        "team.task.dependents",
        "team.task.clear",
        "team.task.create",
        // Route claim to dispatchTeamDataCommandDirect → teamDataTaskClaim
        // (dependency-aware store.claimTask + main-dispatched push). Without
        // this entry `tm-agent claim` fell through to unknown_method — the
        // handler at `case "team.task.claim"` was dead code, breaking the
        // documented work-pool / manual-claim pattern.
        "team.task.claim",
        "team.task.timebox",
        "team.task.update",
        "team.context.set",
        "team.context.get",
        "team.context.list",
        "team.preset.list",
        "team.preset.resolve",
    ]

    /// Dispatch data-only team commands to teamDataQueue, bypassing v2MainSync.
    /// Returns nil if the command should fall through to the normal (main-thread) path.
    private func dispatchTeamDataCommand(method: String, params: [String: Any], id: Any?) -> String? {
        guard Self.teamDataCommands.contains(method) else { return nil }

        let store = TeamDataStore.shared

        return teamDataQueue.sync {
            switch method {
            case "team.message.post":
                return teamDataMessagePost(params: params, id: id, store: store)
            case "team.message.list":
                return teamDataMessageList(params: params, id: id, store: store)
            case "team.message.clear":
                return teamDataMessageClear(params: params, id: id, store: store)
            case "team.correlation.register":
                return teamDataCorrelationRegister(params: params, id: id, store: store)
            case "team.correlation.get":
                return teamDataCorrelationGet(params: params, id: id, store: store)
            case "team.correlation.cancel":
                return teamDataCorrelationCancel(params: params, id: id, store: store)
            case "team.report":
                return teamDataReport(params: params, id: id, store: store)
            case "team.result.status":
                return teamDataResultStatus(params: params, id: id, store: store)
            case "team.result.collect":
                return teamDataResultCollect(params: params, id: id, store: store)
            case "team.agent.heartbeat":
                return teamDataAgentHeartbeat(params: params, id: id, store: store)
            case "team.task.get":
                return teamDataTaskGet(params: params, id: id, store: store)
            case "team.task.list":
                return teamDataTaskList(params: params, id: id, store: store)
            case "team.task.dependents":
                return teamDataTaskDependents(params: params, id: id, store: store)
            case "team.task.clear":
                return teamDataTaskClear(params: params, id: id, store: store)
            case "team.task.create":
                return teamDataTaskCreate(params: params, id: id, store: store)
            case "team.task.claim":
                return teamDataTaskClaim(params: params, id: id, store: store)
            case "team.task.update":
                return teamDataTaskUpdate(params: params, id: id, store: store)
            case "team.task.timebox":
                return teamDataTaskTimebox(params: params, id: id, store: store)
            case "team.context.set":
                return teamDataContextSet(params: params, id: id, store: store)
            case "team.context.get":
                return teamDataContextGet(params: params, id: id, store: store)
            case "team.context.list":
                return teamDataContextList(params: params, id: id, store: store)
            case "team.preset.list":
                return teamDataPresetList(params: params, id: id)
            case "team.preset.resolve":
                return teamDataPresetResolve(params: params, id: id)
            default:
                return nil
            }
        }
    }

    // MARK: - Team Data Command Handlers (off-main-thread safe)

    private func teamDataInbox(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let agentName = params["agent_name"] as? String
        let topOnly = params["top_only"] as? Bool ?? false
        let items = store.inboxItems(teamName: teamName, agentName: agentName, topOnly: topOnly)
        return v2Ok(id: id, result: ["team_name": teamName, "items": items, "count": items.count])
    }

    private func teamDataMessagePost(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let from = params["from"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing from")
        }
        guard let content = params["content"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing content")
        }
        let type = params["type"] as? String ?? "report"
        let to = params["to"] as? String
        if let correlationToken = params["correlation_token"] as? String {
            guard Self.isValidCorrelationToken(correlationToken) else {
                return v2Error(id: id, code: "invalid_params", message: "Invalid correlation_token")
            }
            guard type == "note", to == "leader" else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: "Correlated replies require type=note and to=leader"
                )
            }
            guard let agentInstanceId = params["agent_instance_id"] as? String,
                  !agentInstanceId.isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: "Correlated replies require agent_instance_id"
                )
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  content.utf8.count <= 1_048_576 else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: "Correlated reply content must be non-empty and at most 1 MiB"
                )
            }
            switch store.completeCorrelation(
                teamName: teamName,
                token: correlationToken,
                agentName: from,
                agentInstanceId: agentInstanceId,
                content: content
            ) {
            case .completed(let messageId):
                return v2Ok(id: id, result: ["posted": true, "message_id": messageId])
            case .notFound:
                return v2Error(
                    id: id,
                    code: "correlation_not_found",
                    message: "Correlation is unknown or expired"
                )
            case .identityMismatch:
                return v2Error(
                    id: id,
                    code: "correlation_mismatch",
                    message: "Reply identity does not own this correlation"
                )
            case .alreadyCompleted:
                return v2Error(
                    id: id,
                    code: "correlation_already_completed",
                    message: "Correlation already has a reply"
                )
            }
        }
        if let msg = store.postMessage(teamName: teamName, from: from, to: to, content: content, type: type) {
            // Auto-push notification to the recipient agent's terminal.
            // This eliminates the need for agents to poll inbox — messages arrive instantly.
            // Fire-and-forget on main thread (DispatchQueue.main.async, NOT sync).
            if let recipient = to, recipient != "leader" {
                let notificationText = "[MSG from \(from)]: \(content)"
                DispatchQueue.main.async {
                    TeamOrchestrator.shared.sendToAgentAutoLocate(
                        teamName: teamName, agentName: recipient, text: notificationText
                    )
                }
            }
            return v2Ok(id: id, result: store.messageDictionary(msg))
        }
        return v2Error(id: id, code: "internal_error", message: "Failed to post message")
    }

    private static func isValidCorrelationToken(_ token: String) -> Bool {
        (24...128).contains(token.utf8.count)
            && token.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
    }

    private func teamDataCorrelationRegister(
        params: [String: Any], id: Any?, store: TeamDataStore
    ) -> String {
        guard let teamName = params["team_name"] as? String,
              let token = params["correlation_token"] as? String,
              let agentName = params["expected_agent_name"] as? String,
              let agentInstanceId = params["expected_agent_instance_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing correlation registration fields")
        }
        guard Self.isValidCorrelationToken(token) else {
            return v2Error(id: id, code: "invalid_params", message: "Invalid correlation_token")
        }
        guard let expiresInSeconds = params["expires_in_seconds"] as? Int,
              (1...86_400).contains(expiresInSeconds) else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: "expires_in_seconds must be between 1 and 86400"
            )
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresInSeconds))
        guard store.registerCorrelation(
            teamName: teamName,
            token: token,
            expectedAgentName: agentName,
            expectedAgentInstanceId: agentInstanceId,
            expiresAt: expiresAt
        ) else {
            return v2Error(
                id: id,
                code: "correlation_registration_refused",
                message: "Correlation token already exists or target identity is not registered"
            )
        }
        return v2Ok(id: id, result: [
            "registered": true,
            "expires_at": ISO8601DateFormatter().string(from: expiresAt),
        ])
    }

    private func teamDataCorrelationGet(
        params: [String: Any], id: Any?, store: TeamDataStore
    ) -> String {
        guard let teamName = params["team_name"] as? String,
              let token = params["correlation_token"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing correlation lookup fields")
        }
        guard Self.isValidCorrelationToken(token) else {
            return v2Error(id: id, code: "invalid_params", message: "Invalid correlation_token")
        }
        let consume = params["consume"] as? Bool ?? true
        switch store.correlation(teamName: teamName, token: token, consume: consume) {
        case .pending:
            return v2Ok(id: id, result: ["ready": false])
        case .ready(let reply):
            return v2Ok(id: id, result: [
                "ready": true,
                "content": reply.content,
                "message_id": reply.messageId,
                "agent_name": reply.agentName,
                "agent_instance_id": reply.agentInstanceId,
            ])
        case .notFound:
            return v2Error(
                id: id,
                code: "correlation_not_found",
                message: "Correlation is unknown, expired, or already consumed"
            )
        }
    }

    private func teamDataCorrelationCancel(
        params: [String: Any], id: Any?, store: TeamDataStore
    ) -> String {
        guard let teamName = params["team_name"] as? String,
              let token = params["correlation_token"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing correlation cancellation fields")
        }
        guard Self.isValidCorrelationToken(token) else {
            return v2Error(id: id, code: "invalid_params", message: "Invalid correlation_token")
        }
        return v2Ok(id: id, result: [
            "cancelled": store.cancelCorrelation(teamName: teamName, token: token),
        ])
    }

    private func teamDataMessageList(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let from = params["from"] as? String
        let to = params["to"] as? String
        let type = params["type"] as? String
        let limit = params["limit"] as? Int
        let msgs = store.getMessages(teamName: teamName, from: from, to: to, type: type, limit: limit)
        let formatted = msgs.map { store.messageDictionary($0) }
        return v2Ok(id: id, result: ["team_name": teamName, "messages": formatted, "count": formatted.count])
    }

    private func teamDataMessageClear(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        store.clearMessages(teamName: teamName)
        return v2Ok(id: id, result: ["cleared": true, "team_name": teamName])
    }

    private func teamDataReport(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = params["agent_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        guard let content = params["content"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing content")
        }
        let resultPath = params["result_path"] as? String
        let taskId = params["task_id"] as? String
        let agentInstanceId = params["agent_instance_id"] as? String
        let wrote = store.writeResult(teamName: teamName, agentName: agentName,
                                      agentInstanceId: agentInstanceId, taskId: taskId,
                                      content: content, resultPath: resultPath)
        guard wrote else {
            return v2Error(id: id, code: "result_identity_mismatch",
                           message: "Result task assignment does not match agent_instance_id")
        }
        store.postMessage(teamName: teamName, from: agentName, content: content, type: "report")

        // Publish reply event best-effort so tm-agent wait push subscribers are woken.
        let headerPreview = String(content.prefix(200))
        _ = TermMeshDaemon.shared.rpcCallRaw(method: "events.publish", params: [
            "kind": "reply",
            "team": teamName,
            "agent": agentName,
            "task_id": taskId ?? "",
            "header": headerPreview
        ])

        return v2Ok(id: id, result: ["reported": wrote, "team_name": teamName, "agent_name": agentName, "task_id": taskId ?? NSNull()])
    }

    private func teamDataResultStatus(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let agentFilter = params["agents"] as? [String]
        let activeOnly = params["active_only"] as? Bool ?? false
        let status = store.resultStatus(
            teamName: teamName,
            agentFilter: agentFilter,
            activeOnly: activeOnly
        )
        if status.isEmpty {
            return v2Error(id: id, code: "not_found", message: "Team not found")
        }
        return v2Ok(id: id, result: status)
    }

    private func teamDataResultCollect(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        return v2Ok(id: id, result: ["team_name": teamName, "results": store.collectResults(teamName: teamName)])
    }

    private func teamDataAgentHeartbeat(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = params["agent_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        let summary = params["summary"] as? String
        store.postHeartbeat(teamName: teamName, agentName: agentName, summary: summary)
        return v2Ok(id: id, result: ["team_name": teamName, "agent_name": agentName, "summary": summary as Any])
    }

    private func teamDataTaskGet(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        if let task = store.getTask(teamName: teamName, taskId: taskId) {
            return v2Ok(id: id, result: store.taskDictionary(task))
        }
        return v2Error(id: id, code: "not_found", message: "Task not found")
    }

    private func teamDataTaskList(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let status = params["status"] as? String
        let assignee = params["assignee"] as? String
        let needsAttention = params["needs_attention"] as? Bool ?? false
        let priority = params["priority"] as? Int
        let staleOnly = params["stale"] as? Bool ?? false
        let dependsOn = params["depends_on"] as? String
        let tasks = store.listTasks(
            teamName: teamName,
            status: status,
            assignee: assignee,
            needsAttention: needsAttention,
            priority: priority,
            staleOnly: staleOnly,
            dependsOn: dependsOn
        )
        return v2Ok(id: id, result: [
            "team_name": teamName,
            "tasks": tasks.map { store.taskDictionary($0) },
            "count": tasks.count,
        ])
    }

    private func teamDataTaskDependents(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let tasks = store.dependentTasks(teamName: teamName, taskId: taskId)
        return v2Ok(id: id, result: [
            "team_name": teamName,
            "task_id": taskId,
            "tasks": tasks.map { store.taskDictionary($0) },
            "count": tasks.count,
        ])
    }

    private func teamDataTaskClear(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        store.clearTasks(teamName: teamName)
        return v2Ok(id: id, result: ["cleared": true, "team_name": teamName])
    }

    private func teamDataTaskClaim(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = params["agent_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        let agentInstanceId = params["agent_instance_id"] as? String
        let shouldPush = params["push"] as? Bool ?? true
        if let task = store.claimTask(
            teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId
        ) {
            let claimedTask = task
            let fallbackTabManager = self.tabManager
            // Push task instruction to the claiming agent after a short delay to let
            // the RPC response land first, so the agent's terminal is ready to receive.
            // Pass task directly to avoid re-reading taskBoards (claimed task lives in
            // TeamDataStore, not TeamOrchestrator.taskBoards — re-read would miss it).
            if shouldPush {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard self != nil else { return }
                    let tm = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? fallbackTabManager
                    guard let tm else { return }
                    TeamOrchestrator.shared.notifyTaskCreated(teamName: teamName, task: claimedTask, tabManager: tm)
                }
            }
            return v2Ok(id: id, result: store.taskDictionary(task))
        }
        return v2Ok(id: id, result: NSNull())
    }

    private func teamDataTaskTimebox(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let changed = store.convergeTimebox(
            teamName: teamName,
            taskIds: params["task_ids"] as? [String],
            reason: params["reason"] as? String
                ?? "Timebox hard deadline reached; converge on completed evidence."
        )
        return v2Ok(id: id, result: [
            "team_name": teamName,
            "tasks": changed.map(store.taskDictionary),
            "count": changed.count,
            "outcome": "converged_not_success",
        ])
    }

    private func teamDataTaskCreate(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let title = params["title"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing title")
        }
        let details = params["description"] as? String
        let assignee = (params["assignee"] as? String) ?? (params["assign"] as? String)
        let assigneeInstanceId = params["agent_instance_id"] as? String
        let acceptanceCriteria = params["acceptance_criteria"] as? [String] ?? []
        let labels = params["labels"] as? [String] ?? []
        let estimatedSize = params["estimated_size"] as? Int
        let priority = params["priority"] as? Int ?? 2
        let dependsOn = params["depends_on"] as? [String] ?? []
        let parentTaskId = params["parent_task_id"] as? String
        let createdBy = params["created_by"] as? String ?? "leader"
        let worktreePolicy = params["worktree_policy"] as? String

        if let task = store.createTask(
            teamName: teamName,
            title: title,
            details: details,
            assignee: assignee,
            assigneeInstanceId: assigneeInstanceId,
            acceptanceCriteria: acceptanceCriteria,
            labels: labels,
            estimatedSize: estimatedSize,
            priority: priority,
            dependsOn: dependsOn,
            parentTaskId: parentTaskId,
            createdBy: createdBy,
            worktreePolicy: worktreePolicy
        ) {
            // Note: task notification (sendTextToPanel to leader/assignee) is skipped
            // in the off-main data path. The caller already receives the task data
            // in the RPC response. The `delegate` command in tm-agent handles sending
            // instructions to agents separately via team.send.
            return v2Ok(id: id, result: store.taskDictionary(task))
        }
        return v2Error(id: id, code: "internal_error", message: "Failed to create task")
    }

    private func teamDataTaskUpdate(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let taskId = params["task_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing task_id")
        }
        let status = params["status"] as? String
        let taskResult = params["result"] as? String
        let resultPath = params["result_path"] as? String
        let assignee = params["assignee"] as? String
        let blockedReason = params["blocked_reason"] as? String
        let reviewSummary = params["review_summary"] as? String
        let progressNote = params["progress_note"] as? String
        let worktreePolicy = params["worktree_policy"] as? String
        let worktreePath = params["worktree_path"] as? String
        let worktreeBranch = params["worktree_branch"] as? String
        let worktreeParent = params["worktree_parent"] as? String
        let worktreeCreated = params["worktree_created"] as? Bool
        let worktreeReused = params["worktree_reused"] as? Bool
        let worktreeInit = params["worktree_init"] as? String
        let worktreeFinishedAt = (params["worktree_finished_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let worktreeFinishMode = params["worktree_finish_mode"] as? String
        let worktreeRemoved = params["worktree_removed"] as? Bool
        let agentInstanceId = params["agent_instance_id"] as? String

        // A caller that names an instance is asserting which one holds this
        // task, and being told "Task not found" when the assertion fails says
        // the wrong thing entirely — the task is there, it is somebody else's.
        // Kept ahead of the update so the refusal has its own code even when
        // `assignee` is absent and the store would only answer nil.
        if let agentInstanceId = agentInstanceId?.nilIfBlankTC,
           let task = store.getTask(teamName: teamName, taskId: taskId),
           task.assigneeInstanceId != agentInstanceId {
            return v2Error(id: id, code: "task_identity_mismatch",
                           message: "Task assignment does not match agent_instance_id")
        }

        // Snapshot prev status before update so events.publish can include it.
        let prevStatus = store.getTask(teamName: teamName, taskId: taskId)?.status ?? ""

        if let task = store.updateTask(
            teamName: teamName,
            taskId: taskId,
            status: status,
            result: taskResult,
            resultPath: resultPath,
            assignee: assignee,
            assigneeInstanceId: agentInstanceId,
            blockedReason: blockedReason,
            reviewSummary: reviewSummary,
            progressNote: progressNote,
            worktreePolicy: worktreePolicy,
            worktreePath: worktreePath,
            worktreeBranch: worktreeBranch,
            worktreeParent: worktreeParent,
            worktreeCreated: worktreeCreated,
            worktreeReused: worktreeReused,
            worktreeInit: worktreeInit,
            worktreeFinishedAt: worktreeFinishedAt,
            worktreeFinishMode: worktreeFinishMode,
            worktreeRemoved: worktreeRemoved
        ) {
            // Publish task_status event to daemon broadcast channel best-effort
            // so tm-agent wait push subscribers receive a real-time signal.
            if let newStatus = status, newStatus != prevStatus {
                _ = TermMeshDaemon.shared.rpcCallRaw(method: "events.publish", params: [
                    "kind": "task_status",
                    "team": teamName,
                    "agent": task.assignee ?? "",
                    "task_id": task.id,
                    "status": newStatus,
                    "prev_status": prevStatus
                ])
                if newStatus == "completed", let assignee = task.assignee, !assignee.isEmpty {
                    let tn = teamName, an = assignee, ai = task.assigneeInstanceId
                    Task { @MainActor in
                        TeamOrchestrator.shared.handleTaskCompletionForAutoRecycle(
                            teamName: tn, agentName: an, agentInstanceId: ai
                        )
                    }
                }
            }
            return v2Ok(id: id, result: store.taskDictionary(task))
        }
        return v2Error(id: id, code: "not_found", message: "Task not found")
    }

    // MARK: - Team Context Handlers (off-main-thread safe)

    private func teamDataContextSet(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String,
              let key = params["key"] as? String,
              let value = params["value"] as? String,
              let setBy = params["set_by"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing required params: team_name, key, value, set_by")
        }
        let result = store.contextSet(teamName: teamName, key: key, value: value, setBy: setBy)
        return v2Ok(id: id, result: result)
    }

    private func teamDataContextGet(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String,
              let key = params["key"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing required params: team_name, key")
        }
        guard let result = store.contextGet(teamName: teamName, key: key) else {
            return v2Error(id: id, code: "not_found", message: "Key not found: \(key)")
        }
        return v2Ok(id: id, result: result)
    }

    private func teamDataContextList(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing required param: team_name")
        }
        let entries = store.contextList(teamName: teamName)
        return v2Ok(id: id, result: ["entries": entries, "count": entries.count])
    }

    private func teamDataWatchDriftPost(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        let result = v2TeamWatchDriftPost(params: params)
        return v2Result(id: id, result)
    }

    // MARK: - Team Preset Handlers (off-main-thread safe)

    /// List all built-in smart and workflow team presets with their agent definitions.
    private func teamDataPresetList(params: [String: Any], id: Any?) -> String {
        let detector = ProviderDetector.shared
        let presetManager = AgentRolePresetManager.shared
        let smartPresets: [[String: Any]] = SmartTeamPreset.builtIn.map { preset in
            let resolved = preset.resolve(with: detector)
            return [
                "type": "smart",
                "id": preset.id,
                "name": preset.name,
                "icon": preset.icon,
                "description": preset.description,
                "leader_mode": preset.leaderMode,
                "roles": preset.agents.map(\.role),
                "task_templates": [],
                "review_checkpoints": [],
                "agent_count": resolved.count,
                "agents": resolved.map { agent -> [String: Any] in
                    [
                        "role": agent.role,
                        "cli": agent.cli,
                        "model": agent.model,
                        "status": {
                            switch agent.status {
                            case .normal: return "normal"
                            case .best: return "best"
                            case .fallback: return "fallback"
                            }
                        }() as String,
                        "reason": agent.reason,
                    ]
                },
            ]
        }
        let workflowPresets: [[String: Any]] = WorkflowPresetDefinition.builtIn.map { preset in
            let resolved = resolvedWorkflowAgents(
                for: preset,
                detector: detector,
                presetManager: presetManager
            )
            return [
                "type": "workflow",
                "id": preset.id,
                "name": preset.name,
                "icon": preset.icon,
                "description": "Workflow preset with \(preset.roles.count) roles and \(preset.taskTemplates.count) task templates",
                "leader_mode": preset.leaderMode,
                "roles": preset.roles,
                "task_templates": preset.taskTemplates,
                "review_checkpoints": preset.reviewCheckpoints,
                "agent_count": resolved.count,
                "agents": resolved,
            ]
        }
        let presets = smartPresets + workflowPresets
        return v2Ok(id: id, result: ["presets": presets, "count": presets.count])
    }

    /// Resolve a preset or a list of roles into a concrete agents array ready for team.create.
    private func teamDataPresetResolve(params: [String: Any], id: Any?) -> String {
        let detector = ProviderDetector.shared
        let presetManager = AgentRolePresetManager.shared
        let defaultColors = ["green", "blue", "yellow", "magenta", "cyan", "red"]

        // Mode 1: Resolve by preset_id (smart preset or workflow preset)
        if let presetId = params["preset_id"] as? String {
            if let preset = SmartTeamPreset.builtIn.first(where: { $0.id == presetId }) {
                let resolved = preset.resolve(with: detector)
                let agents: [[String: Any]] = resolved.enumerated().map { i, agent in
                    let rolePreset = presetManager.presets.first(where: { $0.name == agent.role })
                    return [
                        "name": agent.role,
                        "cli": agent.cli,
                        "model": agent.model,
                        "agent_type": agent.role,
                        "color": rolePreset?.color ?? defaultColors[i % defaultColors.count],
                        "instructions": rolePreset?.instructions ?? "",
                    ]
                }
                return v2Ok(id: id, result: [
                    "preset_id": presetId,
                    "preset_type": "smart",
                    "preset_name": preset.name,
                    "leader_mode": preset.leaderMode,
                    "agents": agents,
                    "task_templates": [],
                    "review_checkpoints": [],
                    "count": agents.count,
                ])
            }

            if let workflow = WorkflowPresetDefinition.builtIn.first(where: { $0.id == presetId }) {
                let agents = resolvedWorkflowAgents(
                    for: workflow,
                    detector: detector,
                    presetManager: presetManager
                )
                let unknownRoles = Set(workflow.roles).subtracting(Set(agents.compactMap { $0["name"] as? String }))
                if !unknownRoles.isEmpty {
                    return v2Error(id: id, code: "unknown_roles", message: "Unknown workflow role(s): \(unknownRoles.sorted().joined(separator: ", "))")
                }
                return v2Ok(id: id, result: [
                    "preset_id": presetId,
                    "preset_type": "workflow",
                    "preset_name": workflow.name,
                    "leader_mode": workflow.leaderMode,
                    "agents": agents,
                    "task_templates": workflow.taskTemplates,
                    "review_checkpoints": workflow.reviewCheckpoints,
                    "count": agents.count,
                ])
            }

            return v2Error(id: id, code: "not_found", message: "Unknown preset_id: \(presetId)")
        }

        // Mode 2: Resolve by workflow_id alias.
        if let workflowId = params["workflow_id"] as? String {
            guard let workflow = WorkflowPresetDefinition.builtIn.first(where: { $0.id == workflowId }) else {
                return v2Error(id: id, code: "not_found", message: "Unknown workflow_id: \(workflowId)")
            }
            let agents = resolvedWorkflowAgents(
                for: workflow,
                detector: detector,
                presetManager: presetManager
            )
            return v2Ok(id: id, result: [
                "preset_id": workflowId,
                "preset_type": "workflow",
                "preset_name": workflow.name,
                "leader_mode": workflow.leaderMode,
                "agents": agents,
                "task_templates": workflow.taskTemplates,
                "review_checkpoints": workflow.reviewCheckpoints,
                "count": agents.count,
            ])
        }

        // Mode 3: Resolve by roles array
        if let roles = params["roles"] as? [String] {
            guard !roles.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "Empty roles array")
            }
            var unknownRoles: [String] = []
            let agents: [[String: Any]] = roles.enumerated().compactMap { i, roleName in
                guard let rolePreset = presetManager.presets.first(where: { $0.name == roleName }) else {
                    unknownRoles.append(roleName)
                    return nil
                }
                let cli = detector.isAvailable(rolePreset.cli) ? rolePreset.cli : "claude"
                let model = rolePreset.model.isEmpty ? AgentRolePreset.defaultModel(for: cli) : rolePreset.model
                return [
                    "name": rolePreset.name,
                    "cli": cli,
                    "model": model,
                    "agent_type": rolePreset.name,
                    "color": rolePreset.color.isEmpty ? defaultColors[i % defaultColors.count] : rolePreset.color,
                    "instructions": rolePreset.instructions,
                ]
            }
            if !unknownRoles.isEmpty {
                return v2Error(id: id, code: "unknown_roles", message: "Unknown role(s): \(unknownRoles.joined(separator: ", ")). Use team.preset.list to see available roles.")
            }
            return v2Ok(id: id, result: [
                "preset_type": "roles",
                "agents": agents,
                "task_templates": [],
                "review_checkpoints": [],
                "count": agents.count,
            ])
        }

        return v2Error(id: id, code: "invalid_params", message: "Missing preset_id, workflow_id, or roles param")
    }

    private func resolvedWorkflowAgents(
        for workflow: WorkflowPresetDefinition,
        detector: ProviderDetector,
        presetManager: AgentRolePresetManager
    ) -> [[String: Any]] {
        let defaultColors = ["green", "blue", "yellow", "magenta", "cyan", "red"]
        return workflow.roles.enumerated().compactMap { i, roleName in
            guard let rolePreset = presetManager.presets.first(where: { $0.name == roleName }) else {
                return nil
            }
            let cli = detector.isAvailable(rolePreset.cli) ? rolePreset.cli : "claude"
            let model = rolePreset.model.isEmpty ? AgentRolePreset.defaultModel(for: cli) : rolePreset.model
            return [
                "role": rolePreset.name,
                "name": rolePreset.name,
                "cli": cli,
                "model": model,
                "agent_type": rolePreset.name,
                "color": rolePreset.color.isEmpty ? defaultColors[i % defaultColors.count] : rolePreset.color,
                "instructions": rolePreset.instructions,
                "status": detector.isAvailable(rolePreset.cli) ? "normal" : "fallback",
                "reason": "Workflow role",
            ]
        }
    }

    // MARK: - V2 Agent Team Methods

    private func v2TeamCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String, !teamName.isEmpty else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        // An empty array is a team of its leader alone — the normal opening
        // state for someone entering a project, who then adds whoever the work
        // turns out to need. A missing array is still an error: that is a
        // caller who forgot the parameter, not one who meant none.
        guard let agentsParam = params["agents"] as? [[String: Any]] else {
            return .err(code: "invalid_params", message: "Missing agents array", data: nil)
        }

        let workingDirectory = params["working_directory"] as? String ?? FileManager.default.currentDirectoryPath
        let leaderSessionId = params["leader_session_id"] as? String ?? UUID().uuidString

        let agents = agentsParam.map { dict -> (name: String, cli: String, model: String, agentType: String, color: String, instructions: String, customInstructions: String) in
            (
                name: dict["name"] as? String ?? "agent",
                cli: dict["cli"] as? String ?? "claude",
                model: dict["model"] as? String ?? "sonnet",
                agentType: dict["agent_type"] as? String ?? "general",
                color: dict["color"] as? String ?? "",
                instructions: dict["instructions"] as? String ?? "",
                // R7: only the watcher carries custom_instructions (the CLI
                // attaches `--spec` to the watcher dict only). composeInstructions
                // appends it verbatim as `## Team Custom Instructions`.
                customInstructions: dict["custom_instructions"] as? String ?? ""
            )
        }

        let leaderMode = params["leader_mode"] as? String ?? "repl"
        let leaderModel = params["leader_model"] as? String ?? "sonnet"
        let resumeSessionId = params["resume_session_id"] as? String
        // F2 fix: see TerminalController.swift:2031 — socket flag means
        // "include runbook"; orchestrator wants the inverse.
        let includeRunbookInitPrompt = params["runbook_init_prompt"] as? Bool ?? true
        let skipRunbookInitPrompt = !includeRunbookInitPrompt
        let adoptedLeaderSurfaceId: UUID? = leaderMode == "adopted"
            ? (params["surface_id"] as? String).flatMap(UUID.init(uuidString:))
            : nil
        if leaderMode == "adopted" && adoptedLeaderSurfaceId == nil {
            return .err(code: "invalid_params", message: "adopted mode requires a valid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create team", data: nil)
        v2MainSync {
            if let team = TeamOrchestrator.shared.createTeam(
                name: teamName,
                agents: agents,
                workingDirectory: workingDirectory,
                leaderSessionId: leaderSessionId,
                leaderMode: leaderMode,
                leaderModel: leaderModel,
                resumeSessionId: resumeSessionId,
                adoptedLeaderSurfaceId: adoptedLeaderSurfaceId,
                skipRunbookPromptForInteractiveAgents: skipRunbookInitPrompt,
                tabManager: tabManager
            ) {
                result = .ok([
                    "team_name": team.id,
                    "agent_count": team.agents.count,
                    "workspace_id": team.workspaceId.uuidString,
                    "agents": team.agents.map { agent -> [String: Any] in
                        var info: [String: Any] = [
                            "id": agent.id,
                            "name": agent.name,
                            "model": agent.model,
                            "workspace_id": agent.workspaceId.uuidString,
                        ]
                        if let pid = agent.panelId {
                            info["panel_id"] = pid.uuidString
                        }
                        return info
                    }
                ] as [String: Any])
            }
        }
        return result
    }

    private func v2TeamList(params: [String: Any]) -> V2CallResult {
        var result: V2CallResult = .ok([] as [[String: Any]])
        v2MainSync {
            result = .ok(TeamOrchestrator.shared.listTeams())
        }
        return result
    }

    private func v2TeamStatus(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        var result: V2CallResult = .err(code: "not_found", message: "Team not found", data: nil)
        v2MainSync {
            if let status = TeamOrchestrator.shared.teamStatus(name: teamName) {
                result = .ok(status)
            }
        }
        return result
    }

    private func v2TeamLeaderSend(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var success = false
        v2MainSync {
            success = TeamOrchestrator.shared.sendToLeader(
                teamName: teamName,
                text: text,
                tabManager: tabManager
            )
        }
        return success
            ? .ok(["sent": true, "team_name": teamName, "target": "leader"])
            : .err(code: "not_found", message: "Leader or team not found", data: nil)
    }

    private func v2TeamSend(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let agentName = params["agent_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing agent_name", data: nil)
        }
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var success = false
        v2MainSync {
            success = TeamOrchestrator.shared.sendToAgent(
                teamName: teamName,
                agentName: agentName,
                text: text,
                tabManager: tabManager
            )
        }
        return success
            ? .ok(["sent": true, "team_name": teamName, "agent_name": agentName])
            : .err(code: "not_found", message: "Agent or team not found", data: nil)
    }

    private func v2TeamBroadcast(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var count = 0
        v2MainSync {
            count = TeamOrchestrator.shared.broadcast(
                teamName: teamName,
                text: text,
                tabManager: tabManager
            )
        }
        return .ok(["sent_count": count, "team_name": teamName])
    }

    private func v2TeamDestroy(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }

        var success = false
        v2MainSync {
            success = TeamOrchestrator.shared.destroyTeam(name: teamName, tabManager: tabManager)
        }
        return success
            ? .ok(["destroyed": true, "team_name": teamName])
            : .err(code: "not_found", message: "Team not found", data: nil)
    }

    // MARK: - V2 Agent Team Bidirectional Communication

    // Feature A: Read agent pane screen
    private func v2TeamRead(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let agentName = params["agent_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing agent_name", data: nil)
        }
        let lineLimit = params["lines"] as? Int

        var result: V2CallResult = .err(code: "not_found", message: "Agent not found", data: nil)
        v2MainSync {
            guard let panel = TeamOrchestrator.shared.agentPanel(
                teamName: teamName, agentName: agentName, tabManager: tabManager
            ) else { return }

            let response = readTerminalTextBase64(
                terminalPanel: panel,
                includeScrollback: true,
                lineLimit: lineLimit
            )
            guard response.hasPrefix("OK ") else {
                result = .err(code: "internal_error", message: response, data: nil)
                return
            }
            let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let text = Self.sanitizedTeamReadOutput(decoded)
            result = .ok([
                "text": text,
                "agent_name": agentName,
                "team_name": teamName
            ])
        }
        return result
    }

    // Feature A: Read all agent pane screens
    private func v2TeamCollect(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        let lineLimit = params["lines"] as? Int

        var agentTexts: [[String: Any]] = []
        v2MainSync {
            let panels = TeamOrchestrator.shared.allAgentPanels(teamName: teamName, tabManager: tabManager)
            for (name, instanceId, panel) in panels {
                let response = readTerminalTextBase64(
                    terminalPanel: panel,
                    includeScrollback: true,
                    lineLimit: lineLimit
                )
                var text = ""
                if response.hasPrefix("OK ") {
                    let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    text = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                }
                let taskId = TeamDataStore.shared.agentDataEnrichment(
                    teamName: teamName, agentName: name, agentInstanceId: instanceId
                )["active_task_id"] as? String
                agentTexts.append([
                    "agent_name": name,
                    "agent_instance_id": instanceId,
                    "task_id": taskId as Any? ?? NSNull(),
                    "text": text,
                ])
            }
        }
        return .ok(["team_name": teamName, "agents": agentTexts])
    }

    // Feature B: Agent posts a result (file-based + message)
    private func v2TeamReport(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let agentName = params["agent_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing agent_name", data: nil)
        }
        guard let content = params["content"] as? String else {
            return .err(code: "invalid_params", message: "Missing content", data: nil)
        }
        let resultPath = params["result_path"] as? String

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to report", data: nil)
        v2MainSync {
            let wrote = TeamOrchestrator.shared.writeResult(teamName: teamName, agentName: agentName, content: content, resultPath: resultPath)
            // Also post to message queue for real-time access
            TeamOrchestrator.shared.postMessage(teamName: teamName, from: agentName, content: content, type: "report")
            result = .ok(["reported": wrote, "team_name": teamName, "agent_name": agentName])
        }
        return result
    }

    // Feature B: Check result status
    private func v2TeamResultStatus(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        var result: V2CallResult = .err(code: "not_found", message: "Team not found", data: nil)
        v2MainSync {
            let status = TeamOrchestrator.shared.resultStatus(teamName: teamName)
            if !status.isEmpty {
                result = .ok(status)
            }
        }
        return result
    }

    // Feature B: Collect all file-based results
    private func v2TeamResultCollect(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        var result: V2CallResult = .ok([] as [[String: Any]])
        v2MainSync {
            result = .ok(["team_name": teamName, "results": TeamOrchestrator.shared.collectResults(teamName: teamName)])
        }
        return result
    }

    // Feature C: Post a message
    private func v2TeamMessagePost(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let from = params["from"] as? String else {
            return .err(code: "invalid_params", message: "Missing from", data: nil)
        }
        guard let content = params["content"] as? String else {
            return .err(code: "invalid_params", message: "Missing content", data: nil)
        }
        let type = params["type"] as? String ?? "report"
        let to = params["to"] as? String

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to post message", data: nil)
        v2MainSync {
            if let msg = TeamOrchestrator.shared.postMessage(teamName: teamName, from: from, to: to, content: content, type: type) {
                var dict: [String: Any] = [
                    "id": msg.id,
                    "from": msg.from,
                    "type": msg.type,
                    "team_name": teamName,
                    "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
                ]
                if let to = msg.to { dict["to"] = to }
                result = .ok(dict)
            }
        }
        return result
    }

    // Feature C: List messages
    private func v2TeamMessageList(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        let from = params["from"] as? String
        let to = params["to"] as? String
        let type = params["type"] as? String
        let limit = params["limit"] as? Int

        var result: V2CallResult = .ok([] as [[String: Any]])
        v2MainSync {
            let msgs = TeamOrchestrator.shared.getMessages(teamName: teamName, from: from, to: to, type: type, limit: limit)
            let formatted = msgs.map { msg -> [String: Any] in
                var dict: [String: Any] = [
                    "id": msg.id,
                    "from": msg.from,
                    "type": msg.type,
                    "content": msg.content,
                    "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
                ]
                if let to = msg.to { dict["to"] = to }
                return dict
            }
            result = .ok(["team_name": teamName, "messages": formatted, "count": formatted.count])
        }
        return result
    }

    // Feature C: Clear messages
    private func v2TeamMessageClear(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        v2MainSync {
            TeamOrchestrator.shared.clearMessages(teamName: teamName)
        }
        return .ok(["cleared": true, "team_name": teamName])
    }

    private func v2TeamInbox(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        let agentName = params["agent_name"] as? String
        let topOnly = params["top_only"] as? Bool ?? false
        var result: V2CallResult = .ok([] as [[String: Any]])
        v2MainSync {
            let items = TeamOrchestrator.shared.inboxItems(teamName: teamName, agentName: agentName, topOnly: topOnly)
            result = .ok(["team_name": teamName, "items": items, "count": items.count])
        }
        return result
    }

    private func v2TeamAgentHeartbeat(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let agentName = params["agent_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing agent_name", data: nil)
        }
        let summary = params["summary"] as? String
        var result: V2CallResult = .ok([:])
        v2MainSync {
            TeamOrchestrator.shared.postHeartbeat(teamName: teamName, agentName: agentName, summary: summary)
            result = .ok(["team_name": teamName, "agent_name": agentName, "summary": summary as Any])
        }
        return result
    }

    private func v2TeamAgentStatus(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let agentName = params["agent_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing agent_name", data: nil)
        }
        var result: V2CallResult = .err(code: "not_found", message: "Agent not found", data: nil)
        v2MainSync {
            guard let status = TeamOrchestrator.shared.teamStatus(name: teamName),
                  let agents = status["agents"] as? [[String: Any]],
                  let agent = agents.first(where: { ($0["name"] as? String) == agentName }) else { return }
            result = .ok(agent)
        }
        return result
    }

    private func v2TeamTaskGet(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            if let task = TeamOrchestrator.shared.getTask(teamName: teamName, taskId: taskId) {
                result = .ok(TeamOrchestrator.shared.taskDictionary(task))
            }
        }
        return result
    }

    private func v2TeamTaskStart(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        let assignee = params["assignee"] as? String
        let progressNote = params["progress_note"] as? String

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            guard let task = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: "in_progress",
                assignee: assignee,
                progressNote: progressNote
            ) else { return }
            let dispatched = TeamOrchestrator.shared.dispatchTaskToAssignee(
                teamName: teamName,
                taskId: taskId,
                tabManager: tabManager
            )
            result = .ok([
                "task": TeamOrchestrator.shared.taskDictionary(task),
                "dispatched": dispatched,
            ])
        }
        return result
    }

    private func v2TeamTaskBlock(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        let reason = params["blocked_reason"] as? String

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            guard let task = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: "blocked",
                blockedReason: reason
            ) else { return }
            let notified = TeamOrchestrator.shared.notifyTaskLifecycleEvent(
                teamName: teamName,
                taskId: taskId,
                event: "blocked",
                note: reason,
                tabManager: tabManager
            )
            result = .ok([
                "task": TeamOrchestrator.shared.taskDictionary(task),
                "notified": notified,
            ])
        }
        return result
    }

    private func v2TeamTaskReview(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        let summary = params["review_summary"] as? String

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            guard let task = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: "review_ready",
                reviewSummary: summary
            ) else { return }
            let notified = TeamOrchestrator.shared.notifyTaskLifecycleEvent(
                teamName: teamName,
                taskId: taskId,
                event: "review_ready",
                note: summary,
                tabManager: tabManager
            )
            result = .ok([
                "task": TeamOrchestrator.shared.taskDictionary(task),
                "notified": notified,
            ])
        }
        return result
    }

    private func v2TeamTaskDone(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        let taskResult = params["result"] as? String
        let resultPath = params["result_path"] as? String

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            guard let task = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: "completed",
                result: taskResult,
                resultPath: resultPath
            ) else { return }
            let notified = TeamOrchestrator.shared.notifyTaskLifecycleEvent(
                teamName: teamName,
                taskId: taskId,
                event: "completed",
                note: taskResult,
                tabManager: tabManager
            )
            result = .ok([
                "task": TeamOrchestrator.shared.taskDictionary(task),
                "notified": notified,
            ])
        }
        return result
    }

    private func v2TeamTaskReassign(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        let assignee = params["assignee"] as? String
        let assigneeInstanceId = params["agent_instance_id"] as? String
        let tabManager = v2ResolveTabManager(params: params)

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            guard let task = TeamDataStore.shared.reassignTask(
                teamName: teamName,
                taskId: taskId,
                assignee: assignee,
                assigneeInstanceId: assigneeInstanceId
            ) else { return }
            let dispatched = tabManager.flatMap {
                TeamOrchestrator.shared.dispatchTaskToAssignee(
                    teamName: teamName,
                    taskId: taskId,
                    tabManager: $0
                )
            } ?? false
            result = .ok([
                "task": TeamOrchestrator.shared.taskDictionary(task),
                "dispatched": dispatched,
            ])
        }
        return result
    }

    private func v2TeamTaskUnblock(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            guard let task = TeamOrchestrator.shared.unblockTask(
                teamName: teamName,
                taskId: taskId
            ) else { return }
            let dispatched = TeamOrchestrator.shared.dispatchTaskToAssignee(
                teamName: teamName,
                taskId: taskId,
                tabManager: tabManager
            )
            result = .ok([
                "task": TeamOrchestrator.shared.taskDictionary(task),
                "dispatched": dispatched,
            ])
        }
        return result
    }

    private func v2TeamTaskSplit(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        guard let title = params["title"] as? String else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let assignee = params["assignee"] as? String
        let createdBy = params["created_by"] as? String ?? "leader"
        let tabManager = v2ResolveTabManager(params: params)

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            guard let task = TeamOrchestrator.shared.splitTask(
                teamName: teamName,
                parentTaskId: taskId,
                title: title,
                assignee: assignee,
                createdBy: createdBy
            ) else { return }
            if let tabManager {
                _ = TeamOrchestrator.shared.notifyTaskCreated(
                    teamName: teamName,
                    taskId: task.id,
                    tabManager: tabManager
                )
            }
            result = .ok(TeamOrchestrator.shared.taskDictionary(task))
        }
        return result
    }

    private func v2TeamTaskDependents(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        var result: V2CallResult = .ok([] as [[String: Any]])
        v2MainSync {
            let tasks = TeamOrchestrator.shared.dependentTasks(teamName: teamName, taskId: taskId)
            result = .ok([
                "team_name": teamName,
                "task_id": taskId,
                "tasks": tasks.map { TeamOrchestrator.shared.taskDictionary($0) },
                "count": tasks.count,
            ])
        }
        return result
    }

    // Feature D: Create task
    private func v2TeamTaskCreate(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let title = params["title"] as? String else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let details = params["description"] as? String
        let assignee = params["assignee"] as? String
        let acceptanceCriteria = params["acceptance_criteria"] as? [String] ?? []
        let labels = params["labels"] as? [String] ?? []
        let estimatedSize = params["estimated_size"] as? Int
        let priority = params["priority"] as? Int ?? 2
        let dependsOn = params["depends_on"] as? [String] ?? []
        let parentTaskId = params["parent_task_id"] as? String
        let createdBy = params["created_by"] as? String ?? "leader"
        let worktreePolicy = params["worktree_policy"] as? String
        let tabManager = v2ResolveTabManager(params: params)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create task", data: nil)
        v2MainSync {
            if let task = TeamOrchestrator.shared.createTask(
                teamName: teamName,
                title: title,
                details: details,
                assignee: assignee,
                acceptanceCriteria: acceptanceCriteria,
                labels: labels,
                estimatedSize: estimatedSize,
                priority: priority,
                dependsOn: dependsOn,
                parentTaskId: parentTaskId,
                createdBy: createdBy,
                worktreePolicy: worktreePolicy
            ) {
                if let tabManager {
                    _ = TeamOrchestrator.shared.notifyTaskCreated(
                        teamName: teamName,
                        taskId: task.id,
                        tabManager: tabManager
                    )
                }
                result = .ok(TeamOrchestrator.shared.taskDictionary(task))
            }
        }
        return result
    }

    // Feature D: Update task
    private func v2TeamTaskUpdate(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let taskId = params["task_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing task_id", data: nil)
        }
        let status = params["status"] as? String
        let taskResult = params["result"] as? String
        let assignee = params["assignee"] as? String
        let blockedReason = params["blocked_reason"] as? String
        let reviewSummary = params["review_summary"] as? String
        let progressNote = params["progress_note"] as? String
        let worktreePolicy = params["worktree_policy"] as? String
        let worktreePath = params["worktree_path"] as? String
        let worktreeBranch = params["worktree_branch"] as? String
        let worktreeParent = params["worktree_parent"] as? String
        let worktreeCreated = params["worktree_created"] as? Bool
        let worktreeReused = params["worktree_reused"] as? Bool
        let worktreeInit = params["worktree_init"] as? String
        let worktreeFinishedAt = (params["worktree_finished_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let worktreeFinishMode = params["worktree_finish_mode"] as? String
        let worktreeRemoved = params["worktree_removed"] as? Bool

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            if let task = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: status,
                result: taskResult,
                assignee: assignee,
                blockedReason: blockedReason,
                reviewSummary: reviewSummary,
                progressNote: progressNote,
                worktreePolicy: worktreePolicy,
                worktreePath: worktreePath,
                worktreeBranch: worktreeBranch,
                worktreeParent: worktreeParent,
                worktreeCreated: worktreeCreated,
                worktreeReused: worktreeReused,
                worktreeInit: worktreeInit,
                worktreeFinishedAt: worktreeFinishedAt,
                worktreeFinishMode: worktreeFinishMode,
                worktreeRemoved: worktreeRemoved
            ) {
                result = .ok(TeamOrchestrator.shared.taskDictionary(task))
            }
        }
        return result
    }

    // Feature D: List tasks
    private func v2TeamTaskList(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        let status = params["status"] as? String
        let assignee = params["assignee"] as? String

        let needsAttention = params["needs_attention"] as? Bool ?? false
        let priority = params["priority"] as? Int
        let staleOnly = params["stale"] as? Bool ?? false
        let dependsOn = params["depends_on"] as? String
        var result: V2CallResult = .ok([] as [[String: Any]])
        v2MainSync {
            let tasks = TeamOrchestrator.shared.listTasks(
                teamName: teamName,
                status: status,
                assignee: assignee,
                needsAttention: needsAttention,
                priority: priority,
                staleOnly: staleOnly,
                dependsOn: dependsOn
            )
            let formatted = tasks.map { TeamOrchestrator.shared.taskDictionary($0) }
            result = .ok(["team_name": teamName, "tasks": formatted, "count": formatted.count])
        }
        return result
    }

    // Feature D: Clear tasks
    private func v2TeamTaskClear(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        v2MainSync {
            TeamOrchestrator.shared.clearTasks(teamName: teamName)
        }
        return .ok(["cleared": true, "team_name": teamName])
    }

    // MARK: - V2 Context Methods (sync fallback)

    private func v2TeamContextSet(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String,
              let key = params["key"] as? String,
              let value = params["value"] as? String,
              let setBy = params["set_by"] as? String else {
            return .err(code: "invalid_params", message: "Missing required params: team_name, key, value, set_by", data: nil)
        }
        let result = TeamDataStore.shared.contextSet(teamName: teamName, key: key, value: value, setBy: setBy)
        return .ok(result)
    }

    private func v2TeamContextGet(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String,
              let key = params["key"] as? String else {
            return .err(code: "invalid_params", message: "Missing required params: team_name, key", data: nil)
        }
        guard let result = TeamDataStore.shared.contextGet(teamName: teamName, key: key) else {
            return .err(code: "not_found", message: "Key not found: \(key)", data: nil)
        }
        return .ok(result)
    }

    private func v2TeamContextList(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing required param: team_name", data: nil)
        }
        let entries = TeamDataStore.shared.contextList(teamName: teamName)
        return .ok(["entries": entries, "count": entries.count])
    }

    // MARK: - Watch Drift Posting

    /// Data-only RPC: post a watch drift item to the leader inbox.
    /// Focus-safe: no window.focus, send_key, or app activation (data mutation only).
    private func v2TeamWatchDriftPost(params: [String: Any]) -> V2CallResult {
        guard let teamName = params["team_name"] as? String else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let checkId = params["check_id"] as? String else {
            return .err(code: "invalid_params", message: "Missing check_id", data: nil)
        }
        guard let target = params["target"] as? String else {
            return .err(code: "invalid_params", message: "Missing target", data: nil)
        }
        // Read drift_type (daemon convention), with fallback to drift_kind for backward compat
        let driftKind = (params["drift_type"] as? String) ?? (params["drift_kind"] as? String)
        guard let driftKind else {
            return .err(code: "invalid_params", message: "Missing drift_type", data: nil)
        }
        guard let severity = params["severity"] as? String else {
            return .err(code: "invalid_params", message: "Missing severity", data: nil)
        }
        guard let finding = params["finding"] as? String else {
            return .err(code: "invalid_params", message: "Missing finding", data: nil)
        }
        guard let specClause = params["spec_clause"] as? String else {
            return .err(code: "invalid_params", message: "Missing spec_clause", data: nil)
        }

        let success = TeamDataStore.shared.postWatchDrift(
            teamName: teamName,
            checkId: checkId,
            target: target,
            driftKind: driftKind,
            severity: severity,
            finding: finding,
            specClause: specClause
        )

        if success {
            return .ok([
                "team_name": teamName,
                "check_id": checkId,
                "posted": true
            ])
        } else {
            return .err(code: "not_found", message: "Team not found", data: nil)
        }
    }

    // MARK: - V2 Notification Methods

    private func v2NotificationCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = ws.focusedPanelId
            notifications.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "surface_id": v2OrNull(surfaceId?.uuidString)])
        }
        return result
    }

    private func v2NotificationCreateForSurface(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            notifications.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2NotificationCreateForTarget(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = tabManager.tabs.first(where: { $0.id == wsId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            notifications.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2NotificationList() -> [String: Any] {
        var items: [[String: Any]] = []
        v2MainSync {
            items = notifications.notifications.map { n in
                return [
                    "id": n.id.uuidString,
                    "workspace_id": n.tabId.uuidString,
                    "surface_id": v2OrNull(n.surfaceId?.uuidString),
                    "is_read": n.isRead,
                    "title": n.title,
                    "subtitle": n.subtitle,
                    "body": n.body
                ]
            }
        }
        return ["notifications": items]
    }

    private func v2NotificationClear() -> V2CallResult {
        v2MainSync {
            notifications.clearAll()
        }
        return .ok([:])
    }

    // MARK: - V2 App Focus Methods

    private func v2AppFocusOverride(params: [String: Any]) -> V2CallResult {
        // Accept either:
        // - state: "active" | "inactive" | "clear"
        // - focused: true/false/null
        if let state = v2String(params, "state")?.lowercased() {
            switch state {
            case "active":
                AppFocusState.overrideIsFocused = true
            case "inactive":
                AppFocusState.overrideIsFocused = false
            case "clear", "none":
                AppFocusState.overrideIsFocused = nil
            default:
                return .err(code: "invalid_params", message: "Invalid state (active|inactive|clear)", data: ["state": state])
            }
        } else if params.keys.contains("focused") {
            if let focused = v2Bool(params, "focused") {
                AppFocusState.overrideIsFocused = focused
            } else {
                AppFocusState.overrideIsFocused = nil
            }
        } else {
            return .err(code: "invalid_params", message: "Missing state or focused", data: nil)
        }

        let overrideVal: Any = v2OrNull(AppFocusState.overrideIsFocused.map { $0 as Any })
        return .ok(["override": overrideVal])
    }

    private func v2AppSimulateActive() -> V2CallResult {
        v2MainSync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return .ok([:])
    }


    deinit {
        stop()
    }
}

// MARK: - Mission Control approval queue — worktree finish helper

/// Off-main helper backing `team.task.approve`. Mirrors `tm-agent task
/// finish-worktree` (`daemon/term-mesh-cli/src/tm_agent.rs:8673`) exactly —
/// same lock file protocol (mutual exclusion with the CLI, so a leader
/// running the CLI command and clicking Approve in the same second can't
/// double-finish a worktree), same dirty-worktree guard, same `git-kit wt
/// finish` contract. See docs/design/mission-control-approval-queue.md §6.4.
enum WorktreeApprovalHelper {
    enum Outcome {
        case success(mode: String?, removed: Bool?)
        case failure(String)
    }

    /// Acquire the cross-process lock, verify the worktree isn't dirty (via
    /// the daemon's git2 `worktree.diff_summary`), run `git-kit wt finish`,
    /// release the lock. Runs entirely off the calling actor — this may take
    /// real wall-clock time (subprocess exec + a socket round-trip).
    static func finish(
        teamName: String, taskId: String, worktreePath: String,
        baseRef: String?, push: Bool, cleanup: Bool
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: finishSync(
                    teamName: teamName, taskId: taskId, worktreePath: worktreePath,
                    baseRef: baseRef, push: push, cleanup: cleanup
                ))
            }
        }
    }

    private static func finishSync(
        teamName: String, taskId: String, worktreePath: String,
        baseRef: String?, push: Bool, cleanup: Bool
    ) -> Outcome {
        let lock: TaskWorktreeLock
        switch acquireLock(teamName: teamName, taskId: taskId) {
        case .success(let l): lock = l
        case .failure(let e): return .failure(e)
        }
        defer { lock.release() }

        // Stale-worktree guard: refuse to finish with uncommitted changes.
        // Best-effort — if base_ref is missing/unresolvable, skip straight to
        // git-kit (which gates on a clean tree itself as the final backstop).
        if let baseRef = baseRef?.nilIfBlankTC {
            let diffParams: [String: Any] = ["path": worktreePath, "base_ref": baseRef]
            if let raw = TermMeshDaemon.shared.rpcCallRaw(method: "worktree.diff_summary", params: diffParams),
               let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let result = obj["result"] as? [String: Any] {
                    if (result["dirty"] as? Bool) == true {
                        return .failure("Worktree has uncommitted changes — ask the agent to commit before approving.")
                    }
                } else if let err = obj["error"] as? String {
                    Logger.team.warning("[task.approve] diff_summary check skipped: \(err, privacy: .public)")
                }
            }
        }

        guard let gitKitPath = resolveGitKitPath() else {
            return .failure("git-kit not found on PATH — install it or set its location in Settings > CLI Paths.")
        }

        var args = ["wt", "finish", "--to", "parent", "--json"]
        if cleanup { args.append("--cleanup") }
        if push { args.append("--push") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitKitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: worktreePath)
        var env = ProcessInfo.processInfo.environment
        env["GK_AGENT"] = "1"
        env["NO_COLOR"] = "1"
        process.environment = env
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return .failure("failed to launch git-kit: \(error.localizedDescription)")
        }
        let (outData, errData) = runToCompletion(process, stdout: stdoutPipe, stderr: stderrPipe)
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        guard let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            return .failure("git-kit wt finish produced no parseable output. stderr: \(String(errStr.prefix(500)))")
        }

        // GK_AGENT envelope: {ok, result} or {ok:false, error:{code,message}}.
        if (obj["ok"] as? Bool) == false {
            let message = ((obj["error"] as? [String: Any])?["message"] as? String)?.nilIfBlankTC
                ?? errStr.nilIfBlankTC
                ?? "git-kit wt finish failed"
            return .failure(message)
        }
        let result = (obj["result"] as? [String: Any]) ?? obj
        return .success(mode: result["mode"] as? String, removed: result["removed"] as? Bool)
    }

    /// Runs `process` to completion, draining `stdout`/`stderr` concurrently
    /// with execution rather than after `waitUntilExit()`. Once either pipe's
    /// kernel buffer (commonly 64KB) fills, a child blocked in `write()`
    /// while this caller blocks in `waitUntilExit()` first is a deadlock, not
    /// a slow return — and git-kit output on a large repository can reach
    /// that in practice. Caller must already have called `process.run()`.
    static func runToCompletion(
        _ process: Process, stdout: Pipe, stderr: Pipe
    ) -> (stdout: Data, stderr: Data) {
        let drainQueue = DispatchQueue(label: "com.termmesh.process-drain")
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()

        func drain(_ pipe: Pipe, into accumulate: @escaping (Data) -> Void) {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                // Read in the Foundation readiness callback itself — never on
                // `drainQueue` — so this call never blocks waiting for bytes.
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil }
                drainQueue.async {
                    if chunk.isEmpty {
                        group.leave()
                    } else {
                        accumulate(chunk)
                    }
                }
            }
        }
        drain(stdout) { outData.append($0) }
        drain(stderr) { errData.append($0) }

        process.waitUntilExit()
        group.wait()
        return (outData, errData)
    }

    private static func acquireLock(teamName: String, taskId: String) -> Result<TaskWorktreeLock, String> {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("term-mesh-worktree-locks")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let team = sanitizeBranchComponent(teamName)
        let task = sanitizeBranchComponent(taskId)
        let path = (dir as NSString).appendingPathComponent("\(team)-\(task).lock")
        // O_EXCL: atomic exclusive create, matching Rust's
        // `OpenOptions::create_new(true)` — the same primitive the CLI uses,
        // so the two processes truly contend on one lock.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            return .failure("another worktree finish is already running for task \(taskId)")
        }
        let content = "pid=\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = content.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        return .success(TaskWorktreeLock(path: path))
    }

    /// Same normalization as the Rust CLI's `sanitize_branch_component`
    /// (`tm_agent.rs:8481`) so both sides derive the identical lock filename
    /// for the same `(team, task)` pair.
    private static func sanitizeBranchComponent(_ raw: String) -> String {
        var out = ""
        var lastDash = false
        for ch in raw {
            let keep = (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "_" || ch == "-"
            if keep {
                out.append(contentsOf: ch.lowercased())
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(48))
    }

    /// Resolve the `git-kit` binary: PATH first (`which`, respects
    /// Homebrew/cargo installs and any shell profile PATH additions), then
    /// common install locations as a fallback — the same two-tier pattern
    /// `AgentRolePreset.ProviderDetector` uses for CLI discovery.
    private static func resolveGitKitPath() -> String? {
        if let fromPath = whichGitKit() { return fromPath }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/git-kit",
            "/usr/local/bin/git-kit",
            (home as NSString).appendingPathComponent(".cargo/bin/git-kit"),
            (home as NSString).appendingPathComponent(".local/bin/git-kit"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func whichGitKit() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["git-kit"]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch { return nil }
        let (data, _) = runToCompletion(process, stdout: pipe, stderr: errPipe)
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlankTC
    }
}

/// Guards the exclusive lock file for the lifetime of a worktree-finish
/// operation; removes it on release (mirrors Rust's `Drop for
/// TaskWorktreeLock`, `tm_agent.rs:8572`).
private final class TaskWorktreeLock {
    private let path: String
    private var released = false
    init(path: String) { self.path = path }
    func release() {
        guard !released else { return }
        released = true
        try? FileManager.default.removeItem(atPath: path)
    }
    deinit { release() }
}

private extension String {
    var nilIfBlankTC: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
