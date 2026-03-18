import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit
import WebKit

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    static let shared = TerminalController()

    /// PID of the daemon process, trusted as an ancestor for headless agents.
    /// Set after daemon spawn or orphan reuse so isDescendant() grants access.
    nonisolated(unsafe) var trustedDaemonPid: pid_t = 0

    nonisolated(unsafe) var socketPath = "/tmp/term-mesh.sock"
    nonisolated(unsafe) var serverSocket: Int32 = -1
    nonisolated(unsafe) var isRunning = false
    nonisolated(unsafe) var acceptLoopAlive = false
    private var clientHandlers: [Int32: Thread] = [:]
    /// Injected notification service (defaults to singleton for backward compatibility).
    var notifications: any NotificationService = TerminalNotificationStore.shared
    var tabManager: TabManager?
    var accessMode: SocketControlMode = .termMeshOnly
    let myPid = getpid()

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
        var pending = ""
        var authenticated = false

        while isRunning {
            let bytesRead = read(socket, &buffer, buffer.count - 1)
            guard bytesRead > 0 else { break }

            let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newlineIndex])
                pending = String(pending[pending.index(after: newlineIndex)...])
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

        // ── Approach D: Async Team Dispatch ─────────────────────────────
        // ALL team commands are handled via async path. Data-only commands
        // use TeamDataStore directly (no main thread). UI commands use
        // cooperative `await MainActor.run` instead of blocking `DispatchQueue.main.sync`.
        // This eliminates deadlocks and minimizes main-thread hold time.
        if method.hasPrefix("team.") {
            return dispatchTeamCommandAsync(method: method, params: params, id: id)
        }

        v2MainSync { self.v2RefreshKnownRefs() }


        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif

        let response = withSocketCommandPolicy(commandKey: method, isV2: true) {
            switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: id, result: v2Capabilities())

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
        case "debug.command_palette.toggle":
            return v2Result(id: id, self.v2DebugToggleCommandPalette(params: params))
        case "debug.command_palette.rename_tab.open":
            return v2Result(id: id, self.v2DebugOpenCommandPaletteRenameTabInput(params: params))
        case "debug.command_palette.visible":
            return v2Result(id: id, self.v2DebugCommandPaletteVisible(params: params))
        case "debug.command_palette.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteSelection(params: params))
        case "debug.command_palette.results":
            return v2Result(id: id, self.v2DebugCommandPaletteResults(params: params))
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
        case "debug.flash.count":
            return v2Result(id: id, self.v2DebugFlashCount(params: params))
        case "debug.flash.reset":
            return v2Result(id: id, self.v2DebugResetFlashCounts())
        case "debug.panel_snapshot":
            return v2Result(id: id, self.v2DebugPanelSnapshot(params: params))
        case "debug.panel_snapshot.reset":
            return v2Result(id: id, self.v2DebugPanelSnapshotReset(params: params))
        case "debug.window.screenshot":
            return v2Result(id: id, self.v2DebugScreenshot(params: params))
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
            "surface.health",
            "surface.send_text",
            "surface.send_key",
            "surface.read_text",
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
            "debug.command_palette.toggle",
            "debug.command_palette.rename_tab.open",
            "debug.command_palette.visible",
            "debug.command_palette.selection",
            "debug.command_palette.results",
            "debug.command_palette.rename_input.interact",
            "debug.command_palette.rename_input.delete_backward",
            "debug.command_palette.rename_input.selection",
            "debug.command_palette.rename_input.select_all",
            "debug.sidebar.visible",
            "debug.terminal.is_focused",
            "debug.terminal.read_text",
            "debug.terminal.render_stats",
            "debug.layout",
            "debug.bonsplit_underflow.count",
            "debug.bonsplit_underflow.reset",
            "debug.empty_panel.count",
            "debug.empty_panel.reset",
            "debug.notification.focus",
            "debug.flash.count",
            "debug.flash.reset",
            "debug.panel_snapshot",
            "debug.panel_snapshot.reset",
            "debug.window.screenshot",
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
    ]

    /// Dispatch ALL team commands via async path.
    /// - Data-only commands: handled on teamDataQueue (no main thread)
    /// - UI commands: use cooperative `await MainActor.run` (no deadlock)
    ///
    /// Bridge: sync socket thread waits on semaphore while Task runs cooperatively.
    /// Unlike DispatchQueue.main.sync, `await MainActor.run` is cooperative —
    /// it doesn't block the main thread's run loop, preventing IME deadlocks.
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

        Task {
            defer { semaphore.signal() }
            response = await self.processTeamUICommandAsync(method: method, params: params, id: id)
        }

        if semaphore.wait(timeout: .now() + 5) == .timedOut {
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
        case "team.delegate":
            return await asyncTeamDelegate(params: params, id: id)
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
        guard let agentsParam = params["agents"] as? [[String: Any]], !agentsParam.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing or empty agents array")
        }
        // Parse all params off-main
        let workingDirectory = params["working_directory"] as? String ?? FileManager.default.currentDirectoryPath
        let leaderSessionId = params["leader_session_id"] as? String ?? UUID().uuidString
        let leaderMode = params["leader_mode"] as? String ?? "repl"
        let leaderModel = params["leader_model"] as? String ?? "sonnet"
        // Adopted mode: caller's terminal IS the leader; surface_id identifies it.
        let adoptedLeaderSurfaceId: UUID? = leaderMode == "adopted"
            ? (params["surface_id"] as? String).flatMap(UUID.init(uuidString:))
            : nil
        if leaderMode == "adopted" && adoptedLeaderSurfaceId == nil {
            return v2Error(id: id, code: "invalid_params", message: "adopted mode requires a valid surface_id")
        }
        let agents = agentsParam.map { dict -> (name: String, cli: String, model: String, agentType: String, color: String, instructions: String) in
            (
                name: dict["name"] as? String ?? "agent",
                cli: dict["cli"] as? String ?? "claude",
                model: dict["model"] as? String ?? "sonnet",
                agentType: dict["agent_type"] as? String ?? "",
                color: dict["color"] as? String ?? "green",
                instructions: dict["instructions"] as? String ?? ""
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
                adoptedLeaderSurfaceId: adoptedLeaderSurfaceId,
                tabManager: tabManager
            ) {
                return V2CallResult.ok([
                    "team_name": team.id,
                    "agent_count": team.agents.count,
                    "workspace_id": team.workspaceId.uuidString,
                    "agents": team.agents.map { [
                        "id": $0.id, "name": $0.name,
                        "model": $0.model,
                        "workspace_id": $0.workspaceId.uuidString,
                        "panel_id": $0.panelId.uuidString,
                    ] as [String: Any] },
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
        // Resolve the correct tabManager from the team's workspace, not self.tabManager
        var success = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return false }
            return TeamOrchestrator.shared.sendToAgent(
                teamName: teamName, agentName: agentName, text: text, tabManager: tabManager
            )
        }
        // Progressive retry: 150ms then 400ms
        if !success {
            try? await Task.sleep(nanoseconds: 150_000_000)
            success = await MainActor.run {
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { return false }
                return TeamOrchestrator.shared.sendToAgent(
                    teamName: teamName, agentName: agentName, text: text, tabManager: tabManager
                )
            }
        }
        if !success {
            try? await Task.sleep(nanoseconds: 400_000_000)
            success = await MainActor.run {
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { return false }
                return TeamOrchestrator.shared.sendToAgent(
                    teamName: teamName, agentName: agentName, text: text, tabManager: tabManager
                )
            }
        }
        return success
            ? v2Ok(id: id, result: ["sent": true, "text_delivered": true, "team_name": teamName, "agent_name": agentName])
            : v2Error(id: id, code: "not_found", message: "Agent or team not found")
    }

    private func asyncTeamLeaderSend(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let text = params["text"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing text")
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
        let count = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return 0 }
            return TeamOrchestrator.shared.broadcast(teamName: teamName, text: text, tabManager: tabManager)
        }
        return v2Ok(id: id, result: ["sent_count": count, "team_name": teamName])
    }

    private func asyncTeamRead(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let agentName = params["agent_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing agent_name")
        }
        let lineLimit = params["lines"] as? Int

        // Minimal MainActor hold: only read terminal raw bytes, decode base64 off-main
        let (response, errResult): (String?, V2CallResult?) = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else {
                return (nil, .err(code: "unavailable", message: "TabManager not available", data: nil))
            }
            guard let panel = TeamOrchestrator.shared.agentPanel(
                teamName: teamName, agentName: agentName, tabManager: tabManager
            ) else {
                return (nil, .err(code: "not_found", message: "Agent not found", data: nil))
            }
            return (self.readTerminalTextBase64(
                terminalPanel: panel, includeScrollback: true, lineLimit: lineLimit
            ), nil)
        }

        // Base64 decode off-main
        if let errResult {
            return v2Result(id: id, errResult)
        }
        guard let response, response.hasPrefix("OK ") else {
            return v2Result(id: id, .err(code: "internal_error", message: response ?? "No response", data: nil))
        }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return v2Ok(id: id, result: ["text": text, "agent_name": agentName, "team_name": teamName])
    }

    private func asyncTeamCollect(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let lineLimit = params["lines"] as? Int

        // Get panel references with minimal MainActor hold time
        let panels: [(name: String, panel: TerminalPanel)] = await MainActor.run {
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
            for (index, (name, panel)) in panels.enumerated() {
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
                    return (index, ["agent_name": name, "text": text] as [String: Any])
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
        let teamInfo: (leaderSessionId: String, workspaceId: String, agents: [(name: String, id: String, cli: String, model: String, agentType: String, color: String, workspaceId: String, panelId: String, worktreeBranch: String?, worktreePath: String?)], createdAt: String)? = await MainActor.run {
            guard let team = TeamOrchestrator.shared.teamStruct(name: teamName) else { return nil }
            return (
                leaderSessionId: team.leaderSessionId,
                workspaceId: team.workspaceId.uuidString,
                agents: team.agents.map { a in
                    (name: a.name, id: a.id, cli: a.cli, model: a.model, agentType: a.agentType, color: a.color,
                     workspaceId: a.workspaceId.uuidString, panelId: a.panelId.uuidString,
                     worktreeBranch: a.worktreeBranch, worktreePath: a.worktreePath)
                },
                createdAt: ISO8601DateFormatter().string(from: team.createdAt)
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
            let enrichment = store.agentDataEnrichment(teamName: teamName, agentName: agent.name)
            var info: [String: Any] = [
                "id": agent.id,
                "name": agent.name,
                "cli": agent.cli,
                "model": agent.model,
                "agent_type": agent.agentType,
                "workspace_id": agent.workspaceId,
                "panel_id": agent.panelId,
            ]
            // Merge data enrichment (task, heartbeat, agent_state)
            for (key, value) in enrichment { info[key] = value }
            if let branch = agent.worktreeBranch { info["worktree_branch"] = branch }
            if let path = agent.worktreePath { info["worktree_path"] = path }
            return info
        }

        return v2Ok(id: id, result: [
            "team_name": teamName,
            "leader_session_id": teamInfo.leaderSessionId,
            "workspace_id": teamInfo.workspaceId,
            "agent_count": teamInfo.agents.count,
            "agents": agents,
            "attention_count": inboxCount,
            "task_count": taskTotal,
            "created_at": teamInfo.createdAt,
        ] as [String: Any])
    }

    private func asyncTeamInbox(params: [String: Any], id: Any?) async -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let topOnly = params["top_only"] as? Bool ?? false
        let items: [[String: Any]] = await MainActor.run {
            TeamOrchestrator.shared.inboxItems(teamName: teamName, topOnly: topOnly)
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
        let agentInfo: (id: String, name: String, cli: String, model: String, agentType: String, color: String, workspaceId: String, panelId: String, worktreeBranch: String?, worktreePath: String?)? = await MainActor.run {
            guard let team = TeamOrchestrator.shared.teamStruct(name: teamName),
                  let agent = team.agents.first(where: { $0.name == agentName }) else { return nil }
            return (id: agent.id, name: agent.name, cli: agent.cli, model: agent.model,
                    agentType: agent.agentType, color: agent.color,
                    workspaceId: agent.workspaceId.uuidString, panelId: agent.panelId.uuidString,
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
            "workspace_id": agentInfo.workspaceId, "panel_id": agentInfo.panelId,
        ]
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
        let assignee = params["assignee"] as? String
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
        let store = TeamDataStore.shared

        guard let task = store.reassignTask(
            teamName: teamName, taskId: taskId, assignee: assignee
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

        // Validate agent exists in the team before creating task
        let agentExists: Bool = await MainActor.run {
            guard let team = TeamOrchestrator.shared.teams[teamName] else { return false }
            return team.agents.contains(where: { $0.name == agentName })
        }
        guard agentExists else {
            return v2Error(id: id, code: "not_found", message: "Agent '\(agentName)' not found in team '\(teamName)'")
        }

        let taskTitle = params["task_title"] as? String
        let priority = params["priority"] as? Int
        let store = TeamDataStore.shared

        // Create task + send instruction on MainActor (sendToAgent requires main thread).
        // Resolve the correct tabManager from the team's actual workspace first — self.tabManager
        // may point to a different window (e.g., after window switch or adopted leader mode).
        let delegateResult: TeamOrchestrator.DelegateResult? = await MainActor.run {
            let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
            guard let tabManager else { return nil }
            return TeamOrchestrator.shared.delegateToAgent(
                teamName: teamName,
                agentName: agentName,
                text: text,
                taskTitle: taskTitle,
                priority: priority,
                tabManager: tabManager
            )
        }

        guard let delegateResult else {
            return v2Error(id: id, code: "internal_error", message: "Task creation failed for agent '\(agentName)'")
        }

        // Retry text delivery if initial send failed (panel routing race).
        // Use progressive backoff: 150ms first (catches fast panel init races), 400ms second.
        var textDelivered = delegateResult.textDelivered
        if !textDelivered {
            #if DEBUG
            dlog("[asyncTeamDelegate] initial send failed for \(agentName), retrying in 150ms")
            #endif
            try? await Task.sleep(nanoseconds: 150_000_000)
            textDelivered = await MainActor.run {
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { return false }
                return TeamOrchestrator.shared.sendToAgent(
                    teamName: teamName, agentName: agentName,
                    text: delegateResult.instruction + "\n", tabManager: tabManager
                )
            }
        }
        if !textDelivered {
            #if DEBUG
            dlog("[asyncTeamDelegate] 1st retry failed for \(agentName), retrying in 400ms")
            #endif
            try? await Task.sleep(nanoseconds: 400_000_000)
            textDelivered = await MainActor.run {
                let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName) ?? self.tabManager
                guard let tabManager else { return false }
                return TeamOrchestrator.shared.sendToAgent(
                    teamName: teamName, agentName: agentName,
                    text: delegateResult.instruction + "\n", tabManager: tabManager
                )
            }
            #if DEBUG
            dlog("[asyncTeamDelegate] 2nd retry result for \(agentName): \(textDelivered)")
            #endif
        }

        return v2Ok(id: id, result: [
            "task": store.taskDictionary(delegateResult.task),
            "sent": true,
            "text_delivered": textDelivered,
        ])
    }

    // MARK: - V2 Team Data Dispatch (Approach C: Dual Queue)

    /// Data-only team commands that are safe to run off the main thread.
    private static let teamDataCommands: Set<String> = [
        "team.message.post",
        "team.message.list",
        "team.message.clear",
        "team.report",
        "team.result.status",
        "team.result.collect",
        "team.agent.heartbeat",
        "team.inbox",
        "team.task.get",
        "team.task.list",
        "team.task.dependents",
        "team.task.clear",
        "team.task.create",
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
            case "team.task.update":
                return teamDataTaskUpdate(params: params, id: id, store: store)
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
        let topOnly = params["top_only"] as? Bool ?? false
        let items = store.inboxItems(teamName: teamName, topOnly: topOnly)
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
        if let msg = store.postMessage(teamName: teamName, from: from, to: to, content: content, type: type) {
            return v2Ok(id: id, result: store.messageDictionary(msg))
        }
        return v2Error(id: id, code: "internal_error", message: "Failed to post message")
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
        let wrote = store.writeResult(teamName: teamName, agentName: agentName, content: content)
        store.postMessage(teamName: teamName, from: agentName, content: content, type: "report")
        return v2Ok(id: id, result: ["reported": wrote, "team_name": teamName, "agent_name": agentName])
    }

    private func teamDataResultStatus(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        let status = store.resultStatus(teamName: teamName)
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

    private func teamDataTaskCreate(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
        guard let teamName = params["team_name"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
        }
        guard let title = params["title"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing title")
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

        if let task = store.createTask(
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
            createdBy: createdBy
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
        let assignee = params["assignee"] as? String
        let blockedReason = params["blocked_reason"] as? String
        let reviewSummary = params["review_summary"] as? String
        let progressNote = params["progress_note"] as? String

        if let task = store.updateTask(
            teamName: teamName,
            taskId: taskId,
            status: status,
            result: taskResult,
            assignee: assignee,
            blockedReason: blockedReason,
            reviewSummary: reviewSummary,
            progressNote: progressNote
        ) {
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

    // MARK: - Team Preset Handlers (off-main-thread safe)

    /// List all built-in smart team presets with their agent definitions.
    private func teamDataPresetList(params: [String: Any], id: Any?) -> String {
        let detector = ProviderDetector.shared
        let presets: [[String: Any]] = SmartTeamPreset.builtIn.map { preset in
            let resolved = preset.resolve(with: detector)
            return [
                "id": preset.id,
                "name": preset.name,
                "icon": preset.icon,
                "description": preset.description,
                "leader_mode": preset.leaderMode,
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
        return v2Ok(id: id, result: ["presets": presets, "count": presets.count])
    }

    /// Resolve a preset or a list of roles into a concrete agents array ready for team.create.
    private func teamDataPresetResolve(params: [String: Any], id: Any?) -> String {
        let detector = ProviderDetector.shared
        let presetManager = AgentRolePresetManager.shared
        let defaultColors = ["green", "blue", "yellow", "magenta", "cyan", "red"]

        // Mode 1: Resolve by preset_id
        if let presetId = params["preset_id"] as? String {
            guard let preset = SmartTeamPreset.builtIn.first(where: { $0.id == presetId }) else {
                return v2Error(id: id, code: "not_found", message: "Unknown preset_id: \(presetId)")
            }
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
                "leader_mode": preset.leaderMode,
                "agents": agents,
                "count": agents.count,
            ])
        }

        // Mode 2: Resolve by roles array
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
            return v2Ok(id: id, result: ["agents": agents, "count": agents.count])
        }

        return v2Error(id: id, code: "invalid_params", message: "Missing preset_id or roles param")
    }

    // MARK: - V2 Agent Team Methods

    private func v2TeamCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let teamName = params["team_name"] as? String, !teamName.isEmpty else {
            return .err(code: "invalid_params", message: "Missing team_name", data: nil)
        }
        guard let agentsParam = params["agents"] as? [[String: Any]], !agentsParam.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or empty agents array", data: nil)
        }

        let workingDirectory = params["working_directory"] as? String ?? FileManager.default.currentDirectoryPath
        let leaderSessionId = params["leader_session_id"] as? String ?? UUID().uuidString

        let agents = agentsParam.map { dict -> (name: String, cli: String, model: String, agentType: String, color: String, instructions: String) in
            (
                name: dict["name"] as? String ?? "agent",
                cli: dict["cli"] as? String ?? "claude",
                model: dict["model"] as? String ?? "sonnet",
                agentType: dict["agent_type"] as? String ?? "general",
                color: dict["color"] as? String ?? "",
                instructions: dict["instructions"] as? String ?? ""
            )
        }

        let leaderMode = params["leader_mode"] as? String ?? "repl"
        let leaderModel = params["leader_model"] as? String ?? "sonnet"
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
                adoptedLeaderSurfaceId: adoptedLeaderSurfaceId,
                tabManager: tabManager
            ) {
                result = .ok([
                    "team_name": team.id,
                    "agent_count": team.agents.count,
                    "workspace_id": team.workspaceId.uuidString,
                    "agents": team.agents.map { [
                        "id": $0.id,
                        "name": $0.name,
                        "model": $0.model,
                        "workspace_id": $0.workspaceId.uuidString,
                        "panel_id": $0.panelId.uuidString
                    ] as [String: Any] }
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
            let text = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
            for (name, panel) in panels {
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
                agentTexts.append(["agent_name": name, "text": text])
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

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to report", data: nil)
        v2MainSync {
            let wrote = TeamOrchestrator.shared.writeResult(teamName: teamName, agentName: agentName, content: content)
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
        let topOnly = params["top_only"] as? Bool ?? false
        var result: V2CallResult = .ok([] as [[String: Any]])
        v2MainSync {
            let items = TeamOrchestrator.shared.inboxItems(teamName: teamName, topOnly: topOnly)
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
        let tabManager = v2ResolveTabManager(params: params)

        var result: V2CallResult = .err(code: "not_found", message: "Task not found", data: nil)
        v2MainSync {
            guard let task = TeamOrchestrator.shared.reassignTask(
                teamName: teamName,
                taskId: taskId,
                assignee: assignee
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
                createdBy: createdBy
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
                progressNote: progressNote
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
        DispatchQueue.main.sync {
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
        DispatchQueue.main.sync {
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
