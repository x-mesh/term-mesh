//  Phase C-3b-β + C-3c.2α: DEBUG-only hook that lets a developer exercise
//  the Swift peer-federation client from inside term-mesh.app without
//  touching any terminal UI yet.
//
//  Flow:
//   1. Menu item → NSAlert prompt for socket path.
//   2. Connect + handshake + list (from C-3b-β).
//   3. Attach to the first surface (C-3c.2α).
//   4. Open a `PeerConsoleWindow`:
//        - NSTextView (read-only) streams raw PtyData bytes as UTF-8. No
//          ANSI escape processing — the user sees the raw tty stream,
//          which is the point: it proves bytes are flowing into the GUI
//          process and rendering on-screen.
//        - NSTextField below lets the developer type a line and hit
//          Enter; it gets sent as an Input frame, field clears.
//        - Closing the window sends Goodbye and tears down the transport.

import AppKit
import Bonsplit
import Darwin
import PeerProto

@MainActor
enum PeerMenu {
    static func item() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Peer…",
            action: #selector(PeerClientCoordinator.promptAndRun(_:)),
            keyEquivalent: ""
        )
        item.target = PeerClientCoordinator.shared
        return item
    }

    static func relayItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Peer via Ghostty Relay…",
            action: #selector(PeerClientCoordinator.promptAndRunRelay(_:)),
            keyEquivalent: ""
        )
        item.target = PeerClientCoordinator.shared
        return item
    }

    static func relayWorkspaceItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Peer Workspace via Ghostty Relay…",
            action: #selector(PeerClientCoordinator.promptAndRunRelayWorkspace(_:)),
            keyEquivalent: ""
        )
        item.target = PeerClientCoordinator.shared
        return item
    }

    static func relayWorkspaceSSHItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Remote Peer Workspace (SSH)…",
            action: #selector(PeerClientCoordinator.promptAndRunRelayWorkspaceSSH(_:)),
            keyEquivalent: ""
        )
        item.target = PeerClientCoordinator.shared
        return item
    }

    static func connectionsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Show Peer Connections…",
            action: #selector(PeerClientCoordinator.showConnections(_:)),
            keyEquivalent: ""
        )
        item.target = PeerClientCoordinator.shared
        return item
    }
}

@MainActor
final class PeerClientCoordinator: NSObject {
    static let shared = PeerClientCoordinator()
    private static let setupReadTimeoutSeconds: TimeInterval = 10

    /// Posted whenever the active-relays roster changes (open / close).
    /// `PeerConnectionsWindowController` listens to refresh its table.
    static let relaysDidChangeNotification = Notification.Name("PeerClientCoordinatorRelaysDidChange")

    /// Holding onto the window controllers here keeps their reader Tasks
    /// alive; dropping the reference would cancel the stream.
    private var openConsoles: [PeerConsoleWindowController] = []
    private var openRelays: [PeerRelayWindowController] = []
    private var openWorkspaceRelays: [PeerRelayWorkspaceWindowController] = []
    /// Active SSH tunnels keyed by the controller they back. The
    /// tunnel must outlive the relay window; dropped tunnels yank the
    /// forwarded socket out from under the relay sessions.
    private var sshTunnels: [ObjectIdentifier: PeerSSHTunnel] = [:]
    private var activeConnectionFlows: Set<ConnectionFlow> = []

    private enum ConnectionFlow: Hashable {
        case console(String)
        case relayPane(String)
        case workspace(String)
        case workspaceSSH(target: String, remote: String)

        var displayName: String {
            switch self {
            case .console(let path):
                return "peer console at \(path)"
            case .relayPane(let path):
                return "peer relay at \(path)"
            case .workspace(let path):
                return "peer workspace at \(path)"
            case .workspaceSSH(let target, let remote):
                return "SSH peer workspace \(target):\(remote)"
            }
        }
    }

    /// Snapshot of every active peer connection for the Connections
    /// panel. Returned in open-order. Exposes value types rather than
    /// controllers so external observers don't grow a dependency on
    /// AppKit window-controller internals.
    func activeConnections() -> [PeerRelayConnectionInfo] {
        let infos = (openConsoles.map { $0.connectionInfo }
            + openRelays.map { $0.connectionInfo }
            + openWorkspaceRelays.map { $0.connectionInfo })
            .sorted { $0.connectedAt < $1.connectedAt }
#if DEBUG
        dlog("peer.connections.active count=\(infos.count) consoles=\(openConsoles.count) relays=\(openRelays.count) workspaces=\(openWorkspaceRelays.count)")
        for info in infos {
            dlog("peer.connections.active row kind=\(info.kind.rawValue) host=\(info.hostDisplay) ssh=\(info.sshTarget ?? "nil") target=\(info.targetTitle)")
        }
#endif
        return infos
    }

    /// Disconnect (close) the relay window matching `id`. No-op when
    /// the controller has already been released or removed from the
    /// roster — safer than indexing by row position.
    func disconnect(id: ObjectIdentifier) {
        if let ctrl = openWorkspaceRelays.first(where: { ObjectIdentifier($0) == id }) {
            ctrl.window?.performClose(nil)
            return
        }
        if let ctrl = openRelays.first(where: { ObjectIdentifier($0) == id }) {
            ctrl.window?.performClose(nil)
            return
        }
        if let ctrl = openConsoles.first(where: { ObjectIdentifier($0) == id }) {
            ctrl.window?.performClose(nil)
        }
    }

    fileprivate func postRelaysChanged() {
#if DEBUG
        dlog("peer.connections.post consoles=\(openConsoles.count) relays=\(openRelays.count) workspaces=\(openWorkspaceRelays.count)")
#endif
        NotificationCenter.default.post(name: Self.relaysDidChangeNotification, object: self)
    }

    private func beginConnectionFlow(_ flow: ConnectionFlow) -> Bool {
        guard !activeConnectionFlows.contains(flow) else {
            showAlert(
                title: "Connection Already in Progress",
                body: "term-mesh is already connecting to \(flow.displayName)."
            )
            return false
        }
        activeConnectionFlows.insert(flow)
        return true
    }

    private func finishConnectionFlow(_ flow: ConnectionFlow) {
        activeConnectionFlows.remove(flow)
    }

    @objc func showConnections(_ sender: Any?) {
        PeerConnectionsWindowController.shared.showAndFocus()
    }

    /// Open a workspace relay window initiated from the sidebar.
    /// Registers the controller in the shared roster so the Connections
    /// panel and `RemoteHostStore` both see it.
    func openWorkspaceRelayForSidebar(
        hostSockPath: String,
        workspace: Termmesh_Peer_V1_Workspace,
        hostDisplayName: String?
    ) {
        let controller = PeerRelayWorkspaceWindowController(
            hostSockPath: hostSockPath,
            workspace: workspace,
            hostDisplayName: hostDisplayName
        )
        openWorkspaceRelays.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.openWorkspaceRelays.removeAll { $0 === controller }
            self.postRelaysChanged()
        }
        controller.show()
        postRelaysChanged()
    }

    @objc func promptAndRunRelayWorkspaceSSH(_ sender: Any?) {
        Task { @MainActor in
            await self.promptAndRunRelayWorkspaceSSHAsync()
        }
    }

    @MainActor
    private func promptAndRunRelayWorkspaceSSHAsync() async {
        let alert = NSAlert()
        alert.messageText = "Connect to Remote Peer Workspace via SSH"
        alert.informativeText = "Tunnels the host's peer socket through `ssh -L`. Pick a host advertised on this LAN, or type an SSH target (user@host or ssh-config alias) and the path of the remote peer server's Unix socket."

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 60))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        // Recent hosts (most recently successful connect bubbles to
        // the top). Pick fills target + remote fields.
        let recentLabel = NSTextField(labelWithString: "Recent:")
        let recentPopup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 380, height: 26),
            pullsDown: false
        )
        let recents = PeerFederationSettings.loadRecentHosts()
        let recentMenu = NSMenu()
        recentMenu.addItem(withTitle: recents.isEmpty ? "(no recent hosts)" : "(pick a recent host…)",
                           action: nil, keyEquivalent: "")
        for r in recents {
            let title = Self.menuSafeTitle("\(r.sshTarget)  ·  \(r.remoteSocket)", maxLength: 110)
            recentMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        recentPopup.menu = recentMenu

        // Bonjour-discovered hosts populate this popup live; selecting
        // one autofills the SSH target / remote socket fields.
        let discoveredLabel = NSTextField(labelWithString: "Discovered on LAN:")
        let discoveredPopup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 380, height: 26),
            pullsDown: false
        )
        discoveredPopup.menu?.addItem(withTitle: "(searching…)", action: nil, keyEquivalent: "")

        let targetLabel = NSTextField(labelWithString: "SSH target (user@host):")
        let targetField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        targetField.placeholderString = "user@mac-mini.local"
        let remoteLabel = NSTextField(labelWithString: "Remote peer socket:")
        let remoteField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        // Pre-fill with this machine's *effective* socketPath (the
        // value stored in UserDefaults when the user has overridden
        // it; otherwise the per-uid default). When the remote side is
        // the same user on a similarly-configured Mac, this will be
        // the correct remote path; the user can still edit it.
        remoteField.stringValue = PeerHostCoordinator.shared.currentSocketPath
            ?? PeerFederationSettings.socketPath

        // Pre-fill from the most recent host so a re-connect is
        // one-keystroke (Cmd+T → Cmd+Return).
        if let mostRecent = recents.first {
            targetField.stringValue = mostRecent.sshTarget
            remoteField.stringValue = mostRecent.remoteSocket
        }

        let arranged: [NSView] = [
            recentLabel, recentPopup,
            discoveredLabel, discoveredPopup,
            targetLabel, targetField,
            remoteLabel, remoteField,
        ]
        for v in arranged {
            stack.addArrangedSubview(v)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 230)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        // Live Bonjour browse: rebuild the popup as services arrive
        // and resolve. Strong ref kept until the dialog closes.
        var discoveredPeers: [DiscoveredPeer] = []
        let browser = PeerBonjourBrowser()
        browser.start { peers in
            discoveredPeers = peers
            let menu = discoveredPopup.menu ?? NSMenu()
            menu.removeAllItems()
            if peers.isEmpty {
                menu.addItem(withTitle: "(no LAN hosts found)", action: nil, keyEquivalent: "")
            } else {
                menu.addItem(withTitle: "(pick a host…)", action: nil, keyEquivalent: "")
                for p in peers {
                    let label = "\(p.serviceName)  ·  \(p.hostname)\(p.socketPath.map { "  ·  \($0)" } ?? "")"
                    menu.addItem(withTitle: Self.menuSafeTitle(label, maxLength: 110),
                                 action: nil, keyEquivalent: "")
                }
            }
            discoveredPopup.menu = menu
        }
        // Adapter target so the popup's action stays @objc-compatible.
        let proxy = SSHDialogPopupProxy(
            popup: discoveredPopup,
            target: targetField,
            remote: remoteField,
            peersProvider: { discoveredPeers }
        )
        discoveredPopup.target = proxy
        discoveredPopup.action = #selector(SSHDialogPopupProxy.didPick(_:))

        let recentProxy = RecentHostPopupProxy(
            popup: recentPopup,
            target: targetField,
            remote: remoteField,
            recents: recents
        )
        recentPopup.target = recentProxy
        recentPopup.action = #selector(RecentHostPopupProxy.didPick(_:))

        defer { browser.stop(); _ = proxy; _ = recentProxy } // tear down after modal dismissal

        let resp = await Self.runModalAsSheet(alert)
        guard resp == .alertFirstButtonReturn else { return }
        let target = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !remote.isEmpty else {
            self.showAlert(
                title: "Peer Socket Required",
                body: "Enter both an SSH target and the remote peer socket path."
            )
            return
        }

        let flow = ConnectionFlow.workspaceSSH(target: target, remote: remote)
        guard beginConnectionFlow(flow) else { return }
        defer { finishConnectionFlow(flow) }

        let tunnel = PeerSSHTunnel(
            sshTarget: target,
            remoteSockPath: remote,
            dashboardRemotePort: PeerFederationSettings.forwardDashboard
                ? PeerFederationSettings.remoteDashboardPort
                : nil
        )
        do {
            try await tunnel.start()
        } catch {
            self.showAlert(title: "SSH Tunnel Failed",
                           body: String(describing: error))
            return
        }
        // Tunnel is up — remember the host so the next connect
        // dialog has it ready in the recent picker.
        PeerFederationSettings.rememberRecentHost(
            .init(sshTarget: target, remoteSocket: remote)
        )
        await self.openWorkspaceRelay(
            hostSockPath: tunnel.localSockPath,
            titleSuffix: " · \(target)",
            tunnel: tunnel
        )
    }

    /// Shared workflow: enumerate workspaces over a `PeerRelayConnection`
    /// rooted at `hostSockPath`, prompt for one when there are multiple,
    /// open a `PeerRelayWorkspaceWindowController` and own its lifetime.
    /// `tunnel` (when non-nil) is held alive until the controller closes
    /// and torn down on close.
    private func openWorkspaceRelay(hostSockPath: String,
                                    titleSuffix: String = "",
                                    tunnel: PeerSSHTunnel? = nil) async {
        let probe: PeerRelayConnection
        do {
            probe = try await PeerRelaySession.connect(hostSockPath: hostSockPath)
        } catch {
            tunnel?.stop()
            await MainActor.run {
                self.showAlert(title: "Peer Workspace Failed",
                               body: String(describing: error))
            }
            return
        }
        let workspaces: [Termmesh_Peer_V1_Workspace]
        await probe.transport.setReadTimeoutSeconds(Self.setupReadTimeoutSeconds)
        do {
            workspaces = try await probe.session.listWorkspaces()
        } catch {
            await probe.transport.setReadTimeoutSeconds(nil)
            await probe.cancel()
            tunnel?.stop()
            await MainActor.run {
                self.showAlert(title: "Peer Workspace Failed",
                               body: "listWorkspaces failed: \(error)")
            }
            return
        }
        await probe.transport.setReadTimeoutSeconds(nil)
        await probe.cancel()

        guard !workspaces.isEmpty else {
            tunnel?.stop()
            await MainActor.run {
                self.showAlert(title: "Peer Workspace Failed",
                               body: "Host did not return any workspaces.")
            }
            return
        }

        let chosen: Termmesh_Peer_V1_Workspace?
        if workspaces.count == 1 {
            chosen = workspaces[0]
        } else {
            chosen = await self.promptForWorkspaceSelection(from: workspaces)
        }
        guard let chosen else {
            tunnel?.stop()
            return
        }

        await MainActor.run {
            let controller = PeerRelayWorkspaceWindowController(
                hostSockPath: hostSockPath,
                workspace: chosen,
                hostDisplayName: probe.hostDisplayName
            )
            self.openWorkspaceRelays.append(controller)
#if DEBUG
            dlog("peer.connections.openWorkspaceRelay appended hasTunnel=\(tunnel != nil) host=\(hostSockPath) hostDisplay=\(probe.hostDisplayName) workspace=\(controller.connectionInfo.targetTitle)")
#endif
            if let tunnel {
                self.sshTunnels[ObjectIdentifier(controller)] = tunnel
                controller.attachTunnel(tunnel)
#if DEBUG
                dlog("peer.connections.openWorkspaceRelay attached tunnel sshTarget=\(tunnel.sshTarget)")
#endif
                if !titleSuffix.isEmpty {
                    controller.window?.title += titleSuffix
                }
            }
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.openWorkspaceRelays.removeAll { $0 === controller }
                if let stale = self.sshTunnels.removeValue(forKey: ObjectIdentifier(controller)) {
                    stale.stop()
                }
                self.postRelaysChanged()
            }
            controller.show()
            self.postRelaysChanged()
        }
    }

    @objc func promptAndRunRelayWorkspace(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Peer Workspace via Ghostty Relay"
        alert.informativeText = "Path to a Swift peer server socket. Picks one of the host's workspaces and mirrors its split layout in a single window."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = ProcessInfo.processInfo.environment["TERMMESH_DEBUG_PEER_SERVER_PATH"]
            ?? PeerHostCoordinator.shared.currentSocketPath
            ?? PeerFederationSettings.socketPath
        alert.accessoryView = input
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        Task { @MainActor in
            let resp = await Self.runModalAsSheet(alert)
            guard resp == .alertFirstButtonReturn else { return }
            let path = self.normalizedSocketPath(from: input.stringValue)
            guard !path.isEmpty else {
                self.showAlert(title: "Peer Socket Required", body: "Enter a peer socket path.")
                return
            }
            guard self.validateLocalSocketPathForConnect(path) else { return }
            await self.runWorkspaceFlow(path: path)
        }
    }

    /// Body of the workspace-relay flow, extracted from
    /// promptAndRunRelayWorkspace so the sheet-based completion can
    /// call it cleanly.
    private func runWorkspaceFlow(path: String) async {
        let flow = ConnectionFlow.workspace(path)
        guard beginConnectionFlow(flow) else { return }
        defer { finishConnectionFlow(flow) }

        // Open a probe connection to enumerate workspaces, then
        // discard it — each pane in the chosen workspace will
        // open its own connection.
        let probe: PeerRelayConnection
        do {
            probe = try await PeerRelaySession.connect(hostSockPath: path)
        } catch {
            self.showAlert(title: "Peer Workspace Failed",
                           body: String(describing: error))
            return
        }
        let workspaces: [Termmesh_Peer_V1_Workspace]
        await probe.transport.setReadTimeoutSeconds(Self.setupReadTimeoutSeconds)
        do {
            workspaces = try await probe.session.listWorkspaces()
        } catch {
            await probe.transport.setReadTimeoutSeconds(nil)
            await probe.cancel()
            self.showAlert(title: "Peer Workspace Failed",
                           body: "listWorkspaces failed: \(error)")
            return
        }
        await probe.transport.setReadTimeoutSeconds(nil)
        await probe.cancel()

        guard !workspaces.isEmpty else {
            self.showAlert(title: "Peer Workspace Failed",
                           body: "Host did not return any workspaces.")
            return
        }

        let chosen: Termmesh_Peer_V1_Workspace?
        if workspaces.count == 1 {
            chosen = workspaces[0]
        } else {
            chosen = await self.promptForWorkspaceSelection(from: workspaces)
        }
        guard let chosen else { return }

        let controller = PeerRelayWorkspaceWindowController(
            hostSockPath: path,
            workspace: chosen,
            hostDisplayName: probe.hostDisplayName
        )
        self.openWorkspaceRelays.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.openWorkspaceRelays.removeAll { $0 === controller }
            self.postRelaysChanged()
        }
        controller.show()
        self.postRelaysChanged()
    }

    private func promptForWorkspaceSelection(
        from workspaces: [Termmesh_Peer_V1_Workspace]
    ) async -> Termmesh_Peer_V1_Workspace? {
        let alert = NSAlert()
        alert.messageText = "Choose a workspace"
        alert.informativeText = "Host has \(workspaces.count) workspaces. The chosen one will open in a single window with its host split layout."

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 360, height: 26),
            pullsDown: false
        )
        // Group the roster by owning host window. When the host reports more
        // than one window, insert a disabled section-header item per window
        // and indent its workspaces; a single-window host keeps the flat list.
        let windowGroups = groupWorkspacesByWindow(
            workspaces,
            windowID: { $0.windowID },
            windowTitle: { $0.windowTitle }
        )
        let multiWindow = windowGroups.count > 1
        for group in windowGroups {
            if multiWindow {
                let header = NSMenuItem(
                    title: Self.menuSafeTitle(
                        peerWindowLabel(title: group.windowTitle, id: group.windowID),
                        maxLength: 80
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                header.isEnabled = false
                popup.menu?.addItem(header)
            }
            for w in group.items {
                let title = Self.menuSafeTitle(
                    w.title.isEmpty ? "<untitled>" : w.title,
                    maxLength: 64
                )
                let count = countLeaves(w.layout)
                let idHex = w.workspaceID.prefix(4).map { String(format: "%02x", $0) }.joined()
                let item = NSMenuItem(title: "\(title)  ·  \(count) panes  [\(idHex)]",
                                      action: nil, keyEquivalent: "")
                // Stash the workspace itself so the index→workspace mapping
                // survives the interleaved (non-selectable) header rows.
                item.representedObject = w
                if multiWindow { item.indentationLevel = 1 }
                popup.menu?.addItem(item)
            }
        }
        // Default the popup to the first real workspace, not a header row.
        if let firstReal = popup.menu?.items.first(where: { $0.representedObject != nil }) {
            popup.select(firstReal)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let resp = await Self.runModalAsSheet(alert)
        guard resp == .alertFirstButtonReturn else { return nil }
        return popup.selectedItem?.representedObject as? Termmesh_Peer_V1_Workspace
    }

    private func countLeaves(_ layout: Termmesh_Peer_V1_WorkspaceLayout) -> Int {
        switch layout.node {
        case .pane: return 1
        case .split(let s): return countLeaves(s.first) + countLeaves(s.second)
        case .none: return 0
        }
    }

    @objc func promptAndRunRelay(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Peer via Ghostty Relay"
        alert.informativeText = "Path to a Swift peer server socket (e.g. TERMMESH_DEBUG_PEER_SERVER_PATH).\nOpens remote pane in a real Ghostty surface."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = ProcessInfo.processInfo.environment["TERMMESH_DEBUG_PEER_SERVER_PATH"]
            ?? PeerHostCoordinator.shared.currentSocketPath
            ?? PeerFederationSettings.socketPath
        alert.accessoryView = input
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        Task { @MainActor in
            let resp = await Self.runModalAsSheet(alert)
            guard resp == .alertFirstButtonReturn else { return }
            let path = self.normalizedSocketPath(from: input.stringValue)
            guard !path.isEmpty else {
                self.showAlert(title: "Peer Socket Required", body: "Enter a peer socket path.")
                return
            }
            guard self.validateLocalSocketPathForConnect(path) else { return }
            await self.runRelayFlow(path: path)
        }
    }

    /// Body of the legacy single-pane relay flow, extracted so the
    /// promptAndRunRelay sheet completion can call it cleanly.
    /// The body stays async end-to-end so duplicate-connect guards remain
    /// active until connect, list, selection, and attach have all finished.
    private func runRelayFlow(path: String) async {
        let flow = ConnectionFlow.relayPane(path)
        guard beginConnectionFlow(flow) else { return }
        defer { finishConnectionFlow(flow) }

        let connection: PeerRelayConnection
        do {
            connection = try await PeerRelaySession.connectAndList(hostSockPath: path)
        } catch {
            self.showAlert(title: "Peer Relay Failed", body: String(describing: error))
            return
        }

        // Pick a surface — auto-skip the dialog when there's nothing
        // to choose between.
        let attachable = connection.surfaces.filter { $0.attachable }
        let pickFrom = attachable.isEmpty ? connection.surfaces : attachable
        guard !pickFrom.isEmpty else {
            await connection.cancel()
            self.showAlert(title: "Peer Relay Failed",
                           body: "Host has no surfaces to attach to.")
            return
        }

        let chosen: Termmesh_Peer_V1_SurfaceInfo?
        if pickFrom.count == 1 {
            chosen = pickFrom[0]
        } else {
            chosen = await self.promptForSurfaceSelection(from: pickFrom)
        }
        guard let chosen else {
            await connection.cancel()
            return
        }

        do {
            let session = try await PeerRelaySession.attach(connection, surface: chosen)
            try session.prepareListener()
            let controller = PeerRelayWindowController(
                session: session,
                surfaceTitle: chosen.title
            )
            self.openRelays.append(controller)
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.openRelays.removeAll { $0 === controller }
                self.postRelaysChanged()
            }
            controller.show()
            self.postRelaysChanged()
        } catch {
            await connection.cancel()
            self.showAlert(title: "Peer Relay Failed", body: String(describing: error))
        }
    }

    /// Show an NSAlert with an NSPopUpButton listing the available
    /// surfaces. Returns the user's pick, or nil if Cancel was clicked.
    private func promptForSurfaceSelection(
        from surfaces: [Termmesh_Peer_V1_SurfaceInfo]
    ) async -> Termmesh_Peer_V1_SurfaceInfo? {
        let alert = NSAlert()
        alert.messageText = "Choose a remote surface"
        alert.informativeText = "Host exposes \(surfaces.count) surfaces. Pick which one this relay window should mirror."

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 360, height: 26),
            pullsDown: false
        )
        // NSPopUpButton dedupes items by visible title — when the host
        // has multiple panes with the same title/cwd (e.g. four splits
        // in the same workspace), they collapse into one entry. Stamp a
        // short surfaceID prefix on every label and add NSMenuItem
        // directly (rather than addItem(withTitle:)) so each row stays
        // distinct.
        for s in surfaces {
            let title = Self.menuSafeTitle(
                s.title.isEmpty ? "<untitled>" : s.title,
                maxLength: 48
            )
            let detail = s.cwd.isEmpty ? "" : "  ·  \(Self.abbreviatedMenuPath(s.cwd))"
            let dims = "  (\(s.cols)×\(s.rows))"
            let idHex = s.surfaceID.prefix(4).map { String(format: "%02x", $0) }.joined()
            let display = "\(title)\(detail)\(dims)  [\(idHex)]"
            let item = NSMenuItem(title: display, action: nil, keyEquivalent: "")
            popup.menu?.addItem(item)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let resp = await Self.runModalAsSheet(alert)
        guard resp == .alertFirstButtonReturn else { return nil }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < surfaces.count else { return nil }
        return surfaces[idx]
    }

    @objc func promptAndRun(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to peer socket"
        alert.informativeText = "Path to a term-meshd peer socket (see TERMMESH_PEER_SOCKET)."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = defaultSocketPath()
        input.placeholderString = "/tmp/termmesh-peer.sock"
        alert.accessoryView = input
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        Task { @MainActor in
            let resp = await Self.runModalAsSheet(alert)
            guard resp == .alertFirstButtonReturn else { return }
            let path = self.normalizedSocketPath(from: input.stringValue)
            guard !path.isEmpty else {
                self.showAlert(title: "Peer Socket Required", body: "Enter a peer socket path.")
                return
            }
            guard self.validateLocalSocketPathForConnect(path) else { return }
            await self.run(socketPath: path)
        }
    }

    private func run(socketPath: String) async {
        let flow = ConnectionFlow.console(socketPath)
        guard beginConnectionFlow(flow) else { return }
        defer { finishConnectionFlow(flow) }

        let transport: UnixSocketTransport
        do {
            transport = try await UnixSocketTransport.connect(socketPath: socketPath)
        } catch {
            showAlert(title: "Peer connection failed", body: String(describing: error))
            return
        }

        do {
            let session = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            await transport.setReadTimeoutSeconds(Self.setupReadTimeoutSeconds)
            let info = try await session.handshake()
            let surfaces = try await session.listSurfaces()
            guard let chosen = surfaces.first(where: { $0.attachable }) ?? surfaces.first else {
                await transport.close()
                showAlert(title: "No surfaces on host", body: "\(info.hostDisplayName) reports no exposable surfaces.")
                return
            }

            let outcome = try await session.attachSurface(
                id: chosen.surfaceID,
                mode: .coWrite,
                cols: 80,
                rows: 24
            )
            await transport.setReadTimeoutSeconds(nil)

            let controller = PeerConsoleWindowController(
                hostSockPath: socketPath,
                hostName: info.hostDisplayName,
                surfaceTitle: chosen.title,
                surfaceID: outcome.surfaceID,
                session: session,
                transport: transport
            )
            openConsoles.append(controller)
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.openConsoles.removeAll { $0 === controller }
                self.postRelaysChanged()
            }
            controller.show()
            self.postRelaysChanged()
        } catch {
            await transport.close()
            showAlert(title: "Peer connection failed", body: String(describing: error))
        }
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        Self.presentAsSheetIfPossible(alert) { _ in }
    }

    private func normalizedSocketPath(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private func validateLocalSocketPathForConnect(_ path: String) -> Bool {
        if let message = localSocketPathValidationMessage(path) {
            showAlert(title: "Peer Socket Unavailable", body: message)
            return false
        }
        return true
    }

    private func localSocketPathValidationMessage(_ path: String) -> String? {
        guard !path.isEmpty else {
            return "Enter a peer socket path."
        }
        if path.utf8.count >= 104 {
            return "Unix socket path is too long (\(path.utf8.count) bytes). Use a path under 104 bytes."
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "Socket path does not exist:\n\(path)"
        }
        if isDirectory.boolValue {
            return "Socket path points to a directory:\n\(path)"
        }
        var st = stat()
        guard stat(path, &st) == 0 else {
            return "Socket path is not accessible:\n\(path)"
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            return "Socket path is not a Unix socket:\n\(path)"
        }
        return nil
    }

    private static func menuSafeTitle(_ value: String, maxLength: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard singleLine.count > maxLength else { return singleLine }
        guard maxLength > 3 else { return String(singleLine.prefix(maxLength)) }
        return "..." + String(singleLine.suffix(maxLength - 3))
    }

    private static func abbreviatedMenuPath(_ path: String, maxLength: Int = 72) -> String {
        let singleLine = path
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard singleLine.count > maxLength else { return singleLine }

        let last = (singleLine as NSString).lastPathComponent
        guard !last.isEmpty else {
            return menuSafeTitle(singleLine, maxLength: maxLength)
        }

        let candidate = ".../\(last)"
        if candidate.count <= maxLength {
            return candidate
        }
        return menuSafeTitle(last, maxLength: maxLength)
    }

    /// Present `alert` as a window-attached sheet when possible so the
    /// main run loop isn't blocked on `mach_msg2_trap` for the
    /// duration the dialog is up — this is what `App Hanging` tickets
    /// trace back to. Falls back to the original modal flow only when
    /// no host window is reachable (status-bar-only invocation with
    /// no visible app window).
    @MainActor
    static func presentAsSheetIfPossible(
        _ alert: NSAlert,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let host: NSWindow? = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        guard let host else {
            alert.presentAsSheet(completion: completion)
            return
        }
        alert.beginSheetModal(for: host) { response in
            // beginSheetModal's completion runs on the main thread but
            // isn't @MainActor-annotated by the SDK; hop explicitly.
            Task { @MainActor in completion(response) }
        }
    }

    /// Async wrapper for `presentAsSheetIfPossible` — lets dialog
    /// flows keep their straight-line shape (`let resp = await
    /// runModalAsSheet(alert)`) instead of pyramiding completion
    /// blocks.
    @MainActor
    static func runModalAsSheet(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { cont in
            presentAsSheetIfPossible(alert) { resp in
                cont.resume(returning: resp)
            }
        }
    }

    private func defaultSocketPath() -> String {
        if let env = ProcessInfo.processInfo.environment["TERMMESH_PEER_SOCKET"],
           !env.isEmpty
        {
            return env
        }
        return "/tmp/termmesh-peer.sock"
    }
}

@MainActor
final class PeerConsoleWindowController: NSWindowController, NSWindowDelegate {
    private let hostSockPath: String
    private let hostName: String
    private let surfaceTitle: String
    private let surfaceID: Data
    private let session: PeerSession
    private let transport: UnixSocketTransport
    private let outputView: NSTextView
    private let inputField: NSTextField
    private let connectedAt = Date()
    private var readerTask: Task<Void, Never>?
    private var isClosing = false

    var onClose: (@MainActor () -> Void)?

    var connectionInfo: PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(self),
            kind: .console,
            hostSockPath: hostSockPath,
            hostDisplayName: hostName,
            sshTarget: nil,
            targetTitle: surfaceTitle.isEmpty ? "<surface>" : surfaceTitle,
            connectedAt: connectedAt
        )
    }

    init(
        hostSockPath: String,
        hostName: String,
        surfaceTitle: String,
        surfaceID: Data,
        session: PeerSession,
        transport: UnixSocketTransport
    ) {
        self.hostSockPath = hostSockPath
        self.hostName = hostName
        self.surfaceTitle = surfaceTitle
        self.surfaceID = surfaceID
        self.session = session
        self.transport = transport

        let outputView = Self.makeOutputView()
        let inputField = Self.makeInputField()
        self.outputView = outputView
        self.inputField = inputField

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = outputView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(inputField)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),
            inputField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            inputField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            inputField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(hostName) · \(surfaceTitle)  [peer-debug]"
        window.contentView = root
        window.installPeerTitlebarGradientAccent()
        window.center()

        super.init(window: window)
        window.delegate = self

        inputField.target = self
        inputField.action = #selector(sendInputLine(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show() {
        window?.installPeerTitlebarGradientAccent()
        window?.makeKeyAndOrderFront(nil)
        inputField.window?.makeFirstResponder(inputField)
        startReader()
        appendText("[connected]\n")
    }

    private func startReader() {
        readerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let msg: PeerIncomingMessage
                do {
                    msg = try await self.session.receiveNextMessage()
                } catch {
                    self.handleStreamError(error)
                    return
                }
                self.handle(msg)
                if case .goodbye = msg { return }
            }
        }
    }

    private func handle(_ msg: PeerIncomingMessage) {
        switch msg {
        case .ptyData(_, _, let payload):
            append(payload)
        case .workspaceMeta(let cwd, let branch, _, _):
            appendText("[workspace: cwd=\(cwd)\(branch.isEmpty ? "" : " @\(branch)")]\n")
        case .error(let code, let message):
            appendText("\n[peer error \(code)] \(message)\n")
        case .goodbye(let reason):
            appendText("\n[host goodbye: \(reason)]\n")
            closeWindow()
        default:
            break
        }
    }

    private func handleStreamError(_ error: Error) {
        appendText("\n[stream error] \(error)\n")
        closeWindow()
    }

    private func append(_ data: Data) {
        let text = String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>\n"
        appendText(text)
    }

    private func appendText(_ text: String) {
        guard let ts = outputView.textStorage else { return }
        let attr = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.textColor, .font: Self.monospaceFont]
        )
        ts.append(attr)
        outputView.scrollRangeToVisible(NSRange(location: ts.length, length: 0))
    }

    @objc private func sendInputLine(_ sender: NSTextField) {
        let line = sender.stringValue + "\n"
        sender.stringValue = ""
        let payload = Data(line.utf8)
        let surfaceID = self.surfaceID
        let session = self.session
        Task {
            try? await session.sendInput(surfaceID: surfaceID, keys: payload)
        }
    }

    private func closeWindow() {
        guard !isClosing else { return }
        isClosing = true
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        readerTask?.cancel()
        readerTask = nil
        let session = self.session
        let transport = self.transport
        let surfaceID = self.surfaceID
        _ = surfaceID  // silence
        Task {
            try? await session.sendGoodbye(reason: "debug console closed")
            await transport.close()
        }
        onClose?()
    }

    // MARK: - Helpers

    private static func makeOutputView() -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = false
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.font = monospaceFont
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        return tv
    }

    private static func makeInputField() -> NSTextField {
        let f = NSTextField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.placeholderString = "type here, Enter to send"
        f.font = monospaceFont
        f.focusRingType = .default
        return f
    }

    private static var monospaceFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }
}

/// Glue between the SSH-dialog Bonjour popup (NSPopUpButton, plain
/// NSObject target) and the surrounding text fields. Lives alongside
/// the dialog stack and rewrites the SSH target / remote-socket
/// fields whenever the user picks a discovered peer.
@MainActor
final class SSHDialogPopupProxy: NSObject {
    private weak var popup: NSPopUpButton?
    private weak var targetField: NSTextField?
    private weak var remoteField: NSTextField?
    private let peersProvider: () -> [DiscoveredPeer]

    init(popup: NSPopUpButton,
         target: NSTextField,
         remote: NSTextField,
         peersProvider: @escaping () -> [DiscoveredPeer]) {
        self.popup = popup
        self.targetField = target
        self.remoteField = remote
        self.peersProvider = peersProvider
        super.init()
    }

    @objc func didPick(_ sender: NSPopUpButton) {
        let peers = peersProvider()
        // Index 0 is the placeholder ("pick a host…" / "no hosts");
        // discovered entries start at 1.
        let idx = sender.indexOfSelectedItem - 1
        guard idx >= 0, idx < peers.count else { return }
        let peer = peers[idx]
        targetField?.stringValue = peer.hostname
        if let sock = peer.socketPath, !sock.isEmpty {
            remoteField?.stringValue = sock
        }
    }
}

/// Glue between the SSH-dialog "Recent" popup and the surrounding
/// fields. `recents` is captured at construction time — we don't
/// re-read defaults mid-modal so the menu items stay in sync with
/// the popup's index.
@MainActor
final class RecentHostPopupProxy: NSObject {
    private weak var popup: NSPopUpButton?
    private weak var targetField: NSTextField?
    private weak var remoteField: NSTextField?
    private let recents: [PeerFederationSettings.RecentHost]

    init(popup: NSPopUpButton,
         target: NSTextField,
         remote: NSTextField,
         recents: [PeerFederationSettings.RecentHost]) {
        self.popup = popup
        self.targetField = target
        self.remoteField = remote
        self.recents = recents
        super.init()
    }

    @objc func didPick(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem - 1
        guard idx >= 0, idx < recents.count else { return }
        let entry = recents[idx]
        targetField?.stringValue = entry.sshTarget
        remoteField?.stringValue = entry.remoteSocket
    }
}
