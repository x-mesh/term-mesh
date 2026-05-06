//  Phase C-3c.3.3b: DEBUG-only hook that starts a Swift PeerServer inside
//  term-mesh.app. The provider enumerates the app's live Ghostty terminal
//  panes (GhosttyPaneSurfaceProvider) so remote clients can list and attach
//  to real PTYs via `tm-agent peer list / peer attach`.

import AppKit
import PeerProto

@MainActor
enum PeerDebugServerMenu {
    static func startItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Start Peer Server…",
            action: #selector(PeerDebugServerCoordinator.startServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerDebugServerCoordinator.shared
        return item
    }

    static func stopItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Stop Peer Server",
            action: #selector(PeerDebugServerCoordinator.stopServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerDebugServerCoordinator.shared
        return item
    }
}

@MainActor
final class PeerDebugServerCoordinator: NSObject {
    static let shared = PeerDebugServerCoordinator()

    private var server: PeerServer?
    private var socketPath: String?
    private var provider: GhosttyPaneSurfaceProvider?
    private var layoutObserver: NSObjectProtocol?

    /// Launch-time hook. If `TERMMESH_PEER_SERVER_PATH` (or legacy
    /// `TERMMESH_DEBUG_PEER_SERVER_PATH`) is set, start a peer server
    /// at that path. Without the env var the server stays off until
    /// the user clicks "Start Peer Server…" from the status bar menu.
    static func autoStartIfConfigured() {
        let env = ProcessInfo.processInfo.environment
        let path = env["TERMMESH_PEER_SERVER_PATH"]
            ?? env["TERMMESH_DEBUG_PEER_SERVER_PATH"]
        guard let path, !path.isEmpty else { return }
        Task { await PeerDebugServerCoordinator.shared.bringUp(at: path, silent: true) }
    }

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
        input.stringValue = "/tmp/termmesh-app-peer.sock"
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
        Task {
            await server.stop()
            await MainActor.run {
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
        config.hostDisplayName = ProcessInfo.processInfo.hostName
        config.hostAppVersion = "debug-server"

        let server = PeerServer(socketPath: path, provider: provider, config: config)
        do {
            try await server.start()
            self.server = server
            self.socketPath = path
            self.provider = provider
            installLayoutChangeBridge(server: server, provider: provider)
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
    /// `PeerDebugServerCoordinator` which pushes the refreshed layout
    /// to attached peer clients.
    static let peerWorkspaceLayoutDidChange = Notification.Name("PeerWorkspaceLayoutDidChange")
}
