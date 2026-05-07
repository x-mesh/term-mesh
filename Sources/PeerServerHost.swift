//  Phase C-3c.3.3b: DEBUG-only hook that starts a Swift PeerServer inside
//  term-mesh.app. The provider enumerates the app's live Ghostty terminal
//  panes (GhosttyPaneSurfaceProvider) so remote clients can list and attach
//  to real PTYs via `tm-agent peer list / peer attach`.

import AppKit
import PeerProto

@MainActor
enum PeerServerMenu {
    static func startItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Start Peer Server…",
            action: #selector(PeerServerCoordinator.startServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerServerCoordinator.shared
        return item
    }

    static func stopItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Stop Peer Server",
            action: #selector(PeerServerCoordinator.stopServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerServerCoordinator.shared
        return item
    }
}

@MainActor
final class PeerServerCoordinator: NSObject {
    static let shared = PeerServerCoordinator()

    private var server: PeerServer?
    private var socketPath: String?
    private var provider: GhosttyPaneSurfaceProvider?
    private var layoutObserver: NSObjectProtocol?
    private var bonjour: PeerBonjourPublisher?

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
        Task { await PeerServerCoordinator.shared.bringUp(at: path, silent: true) }
    }

    /// Toggle the server on/off without showing any UI. Used by the
    /// Settings pane and by `autoStartIfConfigured`.
    @discardableResult
    func setRunning(_ shouldRun: Bool) async -> Bool {
        if shouldRun {
            guard server == nil else { return true } // already up
            await bringUp(at: PeerFederationSettings.socketPath, silent: false)
            postStateChange()
            return server != nil
        } else {
            guard let server else { return true }
            self.server = nil
            self.provider = nil
            socketPath = nil
            uninstallLayoutChangeBridge()
            bonjour?.stop()
            bonjour = nil
            await server.stop()
            postStateChange()
            return true
        }
    }

    private func postStateChange() {
        NotificationCenter.default.post(name: .peerServerStateDidChange, object: nil)
    }

    /// `true` while the server is listening. Lets Settings reflect
    /// state without polling.
    var isRunning: Bool { server != nil }

    @objc func startServer(_ sender: Any?) {
        if let existing = socketPath {
            let alert = NSAlert()
            alert.messageText = "Peer server is already running."
            alert.informativeText = "Listening at \(existing). Stop it first if you want a new path."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Start peer server"
        alert.informativeText = "term-mesh.app will listen on this Unix socket. Existing file at the path will be overwritten."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = PeerFederationSettings.socketPath
        alert.accessoryView = input
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }

        Task { await self.bringUp(at: path) }
    }

    @objc func stopServer(_ sender: Any?) {
        guard let server = self.server else {
            showInfo(title: "No server running", body: "Start one first via Start Peer Server…")
            return
        }
        self.server = nil
        self.provider = nil
        let oldPath = socketPath
        socketPath = nil
        uninstallLayoutChangeBridge()
        bonjour?.stop()
        bonjour = nil
        Task {
            await server.stop()
            await MainActor.run {
                self.postStateChange()
                self.showInfo(
                    title: "Peer server stopped",
                    body: oldPath.map { "Socket \($0) is gone." } ?? "Socket removed."
                )
            }
        }
    }

    private func bringUp(at path: String, silent: Bool = false) async {
        let provider = GhosttyPaneSurfaceProvider()

        var config = PeerServerConfig()
        config.hostDisplayName = PeerFederationSettings.displayName
        config.hostAppVersion = "debug-server"

        let server = PeerServer(socketPath: path, provider: provider, config: config)
        do {
            try await server.start()
            self.server = server
            self.socketPath = path
            self.provider = provider
            installLayoutChangeBridge(server: server, provider: provider)
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
            NSLog("[peer-debug] server listening on %@", path)
            postStateChange()
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
        ) { [weak server, weak provider] note in
            guard let server, let provider,
                  let workspaceID = note.userInfo?["workspaceID"] as? UUID
            else { return }
            let idBytes = withUnsafeBytes(of: workspaceID.uuid) { Data($0) }
            Task {
                let workspaces = await provider.listWorkspaces()
                guard let updated = workspaces.first(where: { $0.workspaceID == idBytes })
                else { return }
                await server.broadcastWorkspaceLayoutChanged(
                    workspaceID: idBytes,
                    layout: updated.layout
                )
            }
        }
    }

    private func uninstallLayoutChangeBridge() {
        if let observer = layoutObserver {
            NotificationCenter.default.removeObserver(observer)
            layoutObserver = nil
        }
    }

    private func showInfo(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension Notification.Name {
    /// Posted by `Workspace` when bonsplit reports a layout change
    /// (split add/remove, divider drag). userInfo carries
    /// `["workspaceID": UUID]`. Observed by
    /// `PeerServerCoordinator` which pushes the refreshed layout
    /// to attached peer clients.
    static let peerWorkspaceLayoutDidChange = Notification.Name("PeerWorkspaceLayoutDidChange")

    /// Posted by `PeerServerCoordinator` whenever the local peer
    /// server starts or stops. Observed by the status-bar icon to
    /// toggle the activity dot.
    static let peerServerStateDidChange = Notification.Name("PeerServerStateDidChange")
}
