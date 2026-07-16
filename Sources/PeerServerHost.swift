//  Phase C-3c.3.3b: DEBUG-only hook that starts a Swift PeerServer inside
//  term-mesh.app. The provider enumerates the app's live Ghostty terminal
//  panes (GhosttyPaneSurfaceProvider) so remote clients can list and attach
//  to real PTYs via `tm-agent peer list / peer attach`.

import AppKit
import Bonsplit
import PeerProto

@MainActor
enum PeerServerMenu {
    static func startItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Start Peer Server…",
            action: #selector(PeerHostCoordinator.startServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerHostCoordinator.shared
        return item
    }

    static func stopItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Stop Peer Server",
            action: #selector(PeerHostCoordinator.stopServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerHostCoordinator.shared
        return item
    }
}

@MainActor
final class PeerHostCoordinator: NSObject {
    static let shared = PeerHostCoordinator()

    private enum Lifecycle {
        case stopped
        case starting(String)
        case running(String)
        case stopping(String?)
    }

    private var server: PeerServer?
    private var socketPath: String?
    private var provider: GhosttyPaneSurfaceProvider?
    private var layoutObserver: NSObjectProtocol?
    private var workspaceClosedObserver: NSObjectProtocol?
    private var bonjour: PeerBonjourPublisher?
    private var lifecycle: Lifecycle = .stopped
    private var startDialogOpen = false
    private var infoAlertOpen = false
    /// Per-workspace debounce of `WorkspaceLayoutChanged` broadcasts.
    /// `bonsplit.didChangeGeometry` fires on every intermediate
    /// position during a divider drag (~60Hz); coalescing here keeps
    /// the network/CPU cost proportional to "drag ended" rather than
    /// "frame settled."
    private var layoutBroadcastDebounce: [UUID: Task<Void, Never>] = [:]

    /// Launch-time hook. Start the peer server when either the
    /// `TERMMESH_PEER_SERVER_PATH` (or legacy
    /// `TERMMESH_DEBUG_PEER_SERVER_PATH`) env var is set or the
    /// "Auto-start" preference is on. Env wins on path conflict.
    static func autoStartIfConfigured() {
        let env = ProcessInfo.processInfo.environment
        let envPath = env["TERMMESH_PEER_SERVER_PATH"]
            ?? env["TERMMESH_DEBUG_PEER_SERVER_PATH"]
        let path: String?
        if let envPath, !envPath.isEmpty {
            path = envPath
        } else if PeerFederationSettings.autoStart {
            path = PeerFederationSettings.socketPath
        } else {
            path = nil
        }
        guard let path else { return }
        Task { await PeerHostCoordinator.shared.bringUp(at: path, silent: true) }
    }

    /// Toggle the server on/off without showing any UI. Used by the
    /// Settings pane and by `autoStartIfConfigured`.
    @discardableResult
    func setRunning(_ shouldRun: Bool) async -> Bool {
        if shouldRun {
            guard case .stopped = lifecycle else { return server != nil }
            await bringUp(at: PeerFederationSettings.socketPath, silent: false)
            postStateChange()
            return server != nil
        } else {
            return await tearDown(showStoppedAlert: false)
        }
    }

    private func postStateChange() {
        NotificationCenter.default.post(name: .peerServerStateDidChange, object: nil)
    }

    /// `true` while the server is listening. Lets Settings reflect
    /// state without polling.
    var isRunning: Bool { server != nil }
    var currentSocketPath: String? { socketPath }

    @objc func startServer(_ sender: Any?) {
        switch lifecycle {
        case .running(let existing):
            showInfo(
                title: "Peer server is already running.",
                body: "Listening at \(existing). Stop it first if you want a new path."
            )
            return
        case .starting(let path):
            showInfo(
                title: "Peer server is starting",
                body: "Already starting at \(path)."
            )
            return
        case .stopping:
            showInfo(
                title: "Peer server is stopping",
                body: "Wait for the current stop operation to finish before starting it again."
            )
            return
        case .stopped:
            break
        }
        guard !startDialogOpen else { return }

        let alert = NSAlert()
        alert.messageText = "Start peer server"
        alert.informativeText = "term-mesh.app will listen on this Unix socket. Existing file at the path will be overwritten."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = PeerFederationSettings.socketPath
        alert.accessoryView = input
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        startDialogOpen = true
        presentAlert(alert) { [weak self] response in
            self?.startDialogOpen = false
            guard response == .alertFirstButtonReturn else { return }
            let path = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return }
            Task { await self?.bringUp(at: path, persistPath: true) }
        }
    }

    /// Forward to the provider so TabManager / Workspace can release stale tapHubs
    /// without a direct dependency on GhosttyPaneSurfaceProvider.
    func invalidateTapHub(forSurfaceId surfaceId: UUID) {
        provider?.invalidateTapHub(forSurfaceId: surfaceId)
    }

    @objc func stopServer(_ sender: Any?) {
        switch lifecycle {
        case .starting(let path):
            showInfo(
                title: "Peer server is starting",
                body: "Already starting at \(path). Wait for startup to finish before stopping it."
            )
            return
        case .stopping:
            return
        case .stopped:
            showInfo(title: "No server running", body: "Start one first via Start Peer Server…")
            return
        case .running:
            break
        }
        Task { await self.tearDown(showStoppedAlert: true) }
    }

    @discardableResult
    private func tearDown(showStoppedAlert: Bool) async -> Bool {
        guard let server = self.server else {
            if case .starting = lifecycle {
                return false
            }
            lifecycle = .stopped
            return true
        }
        lifecycle = .stopping(socketPath)
        self.server = nil
        self.provider = nil
        let oldPath = socketPath
        socketPath = nil
        uninstallPeerBridges()
        bonjour?.stop()
        bonjour = nil
        await server.stop()
        lifecycle = .stopped
        postStateChange()
        if showStoppedAlert {
            showInfo(
                title: "Peer server stopped",
                body: oldPath.map { "Socket \($0) is gone." } ?? "Socket removed."
            )
        }
        return true
    }

    private func canStartServer(at path: String, silent: Bool) -> Bool {
        switch lifecycle {
        case .stopped:
            lifecycle = .starting(path)
            postStateChange()
            return true
        case .running(let existing):
            if !silent {
                showInfo(
                    title: "Peer server is already running.",
                    body: "Listening at \(existing). Stop it first if you want a new path."
                )
            }
            return false
        case .starting, .stopping:
            return false
        }
    }

    private func markStartFailed() {
        server = nil
        provider = nil
        socketPath = nil
        uninstallPeerBridges()
        bonjour?.stop()
        bonjour = nil
        lifecycle = .stopped
        postStateChange()
    }

    private func markStartSucceeded(server: PeerServer,
                                    path: String,
                                    provider: GhosttyPaneSurfaceProvider,
                                    persistPath: Bool) {
        self.server = server
        self.socketPath = path
        self.provider = provider
        if persistPath {
            UserDefaults.standard.set(path, forKey: PeerFederationSettings.socketPathKey)
        }
        lifecycle = .running(path)
        installLayoutChangeBridge(server: server, provider: provider)
        installWorkspaceClosedBridge(server: server)
        // LAN discovery: advertise via Bonjour so other macs on
        // the same network can pick this host out of a list
        // instead of typing an SSH alias by hand. The TXT record
        // carries the socket path; the actual data path remains
        // SSH (clients connect with `ssh -L`).
        let publisher = PeerBonjourPublisher(
            serviceName: PeerFederationSettings.displayName,
            socketPath: path
        )
        publisher.start()
        self.bonjour = publisher
        postStateChange()
    }

    private func bringUp(at path: String, silent: Bool = false, persistPath: Bool = false) async {
        guard canStartServer(at: path, silent: silent) else { return }
        let provider = GhosttyPaneSurfaceProvider()

        var config = PeerServerConfig()
        config.hostDisplayName = PeerFederationSettings.displayName
        config.hostAppVersion = "debug-server"

        let server = PeerServer(socketPath: path, provider: provider, config: config)
        do {
            try await server.start()
            markStartSucceeded(server: server, path: path, provider: provider, persistPath: persistPath)
            NSLog("[peer-debug] server listening on %@", path)
            if !silent {
                showInfo(
                    title: "Peer server listening",
                    body: """
                        Socket: \(path)

                        Try from a terminal:
                          tm-agent peer list \(path)
                          tm-agent peer attach \(path) --name echo
                        """
                )
            }
        } catch {
            markStartFailed()
            NSLog("[peer-debug] server failed to start at %@: %@", path, String(describing: error))
            if !silent {
                showInfo(
                    title: "Failed to start peer server",
                    body: String(describing: error)
                )
            }
        }
    }

    /// Bridge from `Workspace+BonsplitDelegate.didChangeGeometry`'s
    /// NotificationCenter post to the peer server's broadcast API.
    /// Each notification carries a `workspaceID`; we fetch the latest
    /// `WorkspaceLayout` from the provider and push it to all
    /// connected sessions.
    private func installLayoutChangeBridge(server: PeerServer,
                                           provider: GhosttyPaneSurfaceProvider) {
        layoutObserver = NotificationCenter.default.addObserver(
            forName: .peerWorkspaceLayoutDidChange,
            object: nil,
            queue: .main
        ) { [weak self, weak server, weak provider] note in
            guard let self, let server, let provider,
                  let workspaceID = note.userInfo?["workspaceID"] as? UUID
            else { return }
            // Coalesce a flurry of layout-change notifications (e.g. a
            // divider drag posts one per pixel of motion) into a single
            // broadcast so attached relays don't thrash.
            self.scheduleLayoutBroadcast(
                workspaceID: workspaceID,
                server: server,
                provider: provider
            )
        }
    }

    /// Debounce window for divider-drag-style flurries. 120 ms balances
    /// "feels live" against "don't broadcast every intermediate frame."
    private static let layoutBroadcastDebounceInterval: UInt64 = 120_000_000

    private func scheduleLayoutBroadcast(workspaceID: UUID,
                                         server: PeerServer,
                                         provider: GhosttyPaneSurfaceProvider) {
        layoutBroadcastDebounce[workspaceID]?.cancel()
        let idBytes = withUnsafeBytes(of: workspaceID.uuid) { Data($0) }
        let debounceNs = Self.layoutBroadcastDebounceInterval
        let task = Task { [weak self, weak server, weak provider] in
            try? await Task.sleep(nanoseconds: debounceNs)
            if Task.isCancelled { return }
            guard let server, let provider else { return }
            let workspaces = await provider.listWorkspaces()
            guard let updated = workspaces.first(where: { $0.workspaceID == idBytes })
            else { return }
            await server.broadcastWorkspaceLayoutChanged(
                workspaceID: idBytes,
                layout: updated.layout
            )
            await MainActor.run { [weak self] in
                self?.layoutBroadcastDebounce.removeValue(forKey: workspaceID)
            }
        }
        layoutBroadcastDebounce[workspaceID] = task
    }

    /// Bridge from `TabManager.closeWorkspace`'s `.peerWorkspaceDidClose`
    /// post to the peer server's `WorkspaceRemoved` broadcast. Covers
    /// both a peer-initiated `DeleteWorkspaceRequest`
    /// (`GhosttyPaneSurfaceProvider.deleteWorkspace` calls
    /// `closeWorkspace` directly) and a host-local close (Cmd+W,
    /// sidebar, tab-bar) — `closeWorkspace` is the single choke point
    /// for both, so one observer covers the whole contract described
    /// on `WorkspaceRemoved` in peer.proto ("via DeleteWorkspaceRequest
    /// or a host-local UI action").
    private func installWorkspaceClosedBridge(server: PeerServer) {
        workspaceClosedObserver = NotificationCenter.default.addObserver(
            forName: .peerWorkspaceDidClose,
            object: nil,
            queue: .main
        ) { [weak server] note in
            guard let server,
                  let workspaceID = note.userInfo?["workspaceID"] as? UUID
            else { return }
            let idBytes = withUnsafeBytes(of: workspaceID.uuid) { Data($0) }
            #if DEBUG
            dlog("peer.host.broadcastWorkspaceRemoved id=\(workspaceID.uuidString.prefix(8))")
            #endif
            Task { await server.broadcastWorkspaceRemoved(workspaceID: idBytes) }
        }
    }

    private func uninstallPeerBridges() {
        if let observer = layoutObserver {
            NotificationCenter.default.removeObserver(observer)
            layoutObserver = nil
        }
        if let observer = workspaceClosedObserver {
            NotificationCenter.default.removeObserver(observer)
            workspaceClosedObserver = nil
        }
        for (_, task) in layoutBroadcastDebounce { task.cancel() }
        layoutBroadcastDebounce.removeAll()
    }

    private func presentAlert(_ alert: NSAlert,
                              completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        guard targetWindow?.attachedSheet == nil else {
            completion?(.abort)
            return
        }
        alert.presentAsSheet(for: targetWindow, completion: completion)
    }

    private func showInfo(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        guard !infoAlertOpen else { return }
        infoAlertOpen = true
        presentAlert(alert) { [weak self] _ in
            self?.infoAlertOpen = false
        }
    }
}

extension Notification.Name {
    /// Posted by `Workspace` when bonsplit reports a layout change
    /// (split add/remove, divider drag). userInfo carries
    /// `["workspaceID": UUID]`. Observed by
    /// `PeerHostCoordinator` which pushes the refreshed layout
    /// to attached peer clients.
    static let peerWorkspaceLayoutDidChange = Notification.Name("PeerWorkspaceLayoutDidChange")

    /// Posted by `TabManager.closeWorkspace` whenever a workspace
    /// itself (not a pane inside one) is torn down — via a peer
    /// `DeleteWorkspaceRequest` (`GhosttyPaneSurfaceProvider
    /// .deleteWorkspace`) or a host-local UI close (Cmd+W, sidebar,
    /// tab-bar close). userInfo carries `["workspaceID": UUID]` — the
    /// id of the workspace that was actually removed (for the
    /// "closed the window's last tab" case, this is the ORIGINAL
    /// workspace's id, not its blank replacement). Observed by
    /// `PeerHostCoordinator`, which broadcasts `WorkspaceRemoved` to
    /// every attached peer session so viewers drop it from their
    /// roster without polling `ListWorkspaces`.
    static let peerWorkspaceDidClose = Notification.Name("PeerWorkspaceDidClose")

    /// Posted by `PeerHostCoordinator` whenever the local peer
    /// server starts or stops. Observed by the status-bar icon to
    /// toggle the activity dot.
    static let peerServerStateDidChange = Notification.Name("PeerServerStateDidChange")
}
