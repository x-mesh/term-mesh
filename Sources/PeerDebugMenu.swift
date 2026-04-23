//  Phase C-3b-β: DEBUG-only hook that lets a developer exercise the
//  Swift peer-federation client from inside term-mesh.app without
//  touching any terminal UI yet.
//
//  Entry point: the NSMenuItem returned by `PeerDebugMenu.item()`,
//  inserted into the status-bar menu (see MenuBarExtra.swift). Clicking
//  it pops an NSAlert with a socket path field; on OK, the coordinator
//  connects via `UnixSocketTransport`, runs `PeerSession.handshake()` +
//  `listSurfaces()`, and displays the results in a second NSAlert.
//
//  This is intentionally stub-grade: it doesn't attach to a surface or
//  render any output. Its purpose is to prove that the Swift side can
//  reach a running term-meshd from a real app-bundle context (entitlements,
//  sandbox behavior, MainActor isolation) before Phase C-3c wires remote
//  surfaces into actual panes.

#if DEBUG
import AppKit
import PeerProto

@MainActor
enum PeerDebugMenu {
    static func item() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Peer… (debug)",
            action: #selector(PeerDebugCoordinator.promptAndRun(_:)),
            keyEquivalent: ""
        )
        item.target = PeerDebugCoordinator.shared
        return item
    }
}

@MainActor
final class PeerDebugCoordinator: NSObject {
    static let shared = PeerDebugCoordinator()

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

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }

        Task { await self.connect(to: path) }
    }

    private func connect(to path: String) async {
        do {
            let transport = try await UnixSocketTransport.connect(socketPath: path)
            let session = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            let info = try await session.handshake()
            let surfaces = try await session.listSurfaces()
            try? await session.sendGoodbye(reason: "debug menu test")
            await transport.close()

            let summary: String
            if surfaces.isEmpty {
                summary = "(host reports no surfaces)"
            } else {
                summary = surfaces.map { surface in
                    let branch = surface.branch.isEmpty ? "-" : "@\(surface.branch)"
                    let live = surface.attachable ? "live" : "dead"
                    return "• \(surface.title)  \(surface.cols)x\(surface.rows)  \(live)  \(branch)"
                }.joined(separator: "\n")
            }
            showResult(
                title: "Connected to \(info.hostDisplayName)",
                body: "protocol \(info.hostProtocolVersion)\napp \(info.hostAppVersion)\n\n\(summary)"
            )
        } catch {
            showResult(title: "Peer connection failed", body: String(describing: error))
        }
    }

    private func showResult(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func defaultSocketPath() -> String {
        // If the developer has TERMMESH_PEER_SOCKET set, preseed with it.
        if let env = ProcessInfo.processInfo.environment["TERMMESH_PEER_SOCKET"],
           !env.isEmpty
        {
            return env
        }
        return "/tmp/termmesh-peer.sock"
    }
}
#endif
