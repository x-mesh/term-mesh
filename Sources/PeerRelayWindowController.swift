// Phase C-4: DEBUG-only NSWindow that hosts a Ghostty surface rendering
// a remote peer pane via the term-mesh-peer-relay binary.
//
// Flow (when opened):
//   1. PeerRelaySession connects to the remote host and attaches a surface.
//   2. prepareListener() creates a temp Unix socket the relay binary will connect to.
//   3. TerminalSurface is created with command=<relay binary> and
//      TERMMESH_PEER_RELAY_SOCKET env var pointing to the socket.
//   4. Ghostty spawns the relay binary as the "shell".
//   5. session.start() accepts the relay connection and starts pumping:
//        PeerSession PtyData → relay socket → relay stdout → Ghostty renders.
//        relay stdin (user keystrokes) → relay socket → PeerSession Input → host.
//        relay SIGWINCH → relay socket → PeerSession Resize → host.

#if DEBUG
import AppKit
import SwiftUI

@MainActor
final class PeerRelayWindowController: NSWindowController, NSWindowDelegate {
    private let relaySession: PeerRelaySession
    private let terminalSurface: TerminalSurface
    private var startTask: Task<Void, Never>?
    private var isClosing = false

    var onClose: (@MainActor () -> Void)?

    // ── Init ─────────────────────────────────────────────────────────

    init(session: PeerRelaySession) {
        self.relaySession = session

        // Create a TerminalSurface configured to run the relay binary.
        // Ghostty will spawn it as the "shell" for this pane.
        self.terminalSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: nil,
            command: session.relayBinaryPath,
            environment: ["TERMMESH_PEER_RELAY_SOCKET": session.relaySockPath]
        )

        // Build the window around the Ghostty surface view.
        let hostView = session.relaySockPath   // used only for title
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Peer (Ghostty) · \(hostView)"
        window.isReleasedWhenClosed = false
        window.center()

        // Embed the Ghostty surface's hosted NSView as the content view.
        let surfaceView = session.relaySockPath  // unused here, just for binding
        _ = surfaceView  // suppress unused warning
        let hostedView = terminalSurface.hostedView
        hostedView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        container.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.contentView = container

        super.init(window: window)
        window.delegate = self

        // Relay errors/disconnects close the window.
        session.onDisconnect = { [weak self] in
            guard let self, !self.isClosing else { return }
            self.isClosing = true
            self.window?.performClose(nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // ── Show ─────────────────────────────────────────────────────────

    func show() {
        window?.makeKeyAndOrderFront(nil)
        // Accept the relay connection and begin pumping after the
        // Ghostty surface has been created (hostedView is now on screen).
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.relaySession.start()
                NSLog("[peer-relay] relay connected; streaming")
            } catch {
                NSLog("[peer-relay] start failed: %@", String(describing: error))
                self.window?.performClose(nil)
            }
        }
    }

    // ── NSWindowDelegate ─────────────────────────────────────────────

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        startTask?.cancel()
        startTask = nil
        let s = relaySession
        Task { await s.stop() }
        onClose?()
    }
}
#endif
