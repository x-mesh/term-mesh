//  Phase C-3c.3.3b: DEBUG-only hook that starts a Swift PeerServer inside
//  term-mesh.app. The provider enumerates the app's live Ghostty terminal
//  panes (GhosttyPaneSurfaceProvider) so remote clients can list and attach
//  to real PTYs via `tm-agent peer list / peer attach`.

#if DEBUG
import AppKit
import PeerProto

@MainActor
enum PeerDebugServerMenu {
    static func startItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Start Peer Server… (debug)",
            action: #selector(PeerDebugServerCoordinator.startServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerDebugServerCoordinator.shared
        return item
    }

    static func stopItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Stop Peer Server (debug)",
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

    /// Launch-time hook. If `TERMMESH_DEBUG_PEER_SERVER_PATH` is set,
    /// start a peer server at that path with the Echo provider. Lets a
    /// terminal-driven integration test reach the app's Swift server
    /// without clicking through the menu.
    static func autoStartIfConfigured() {
        guard
            let path = ProcessInfo.processInfo.environment["TERMMESH_DEBUG_PEER_SERVER_PATH"],
            !path.isEmpty
        else { return }
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
        let oldPath = socketPath
        socketPath = nil
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

    private func showInfo(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
