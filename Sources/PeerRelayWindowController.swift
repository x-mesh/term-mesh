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

import AppKit
import SwiftUI
import Bonsplit

@MainActor
final class PeerRelayWindowController: NSWindowController, NSWindowDelegate {
    private let relaySession: PeerRelaySession
    private let surfaceTitle: String
    private let connectedAt = Date()
    private let terminalSurface: TerminalSurface
    private let container: NSView
    private var startTask: Task<Void, Never>?
    private var isClosing = false
    private var disconnectOverlay: NSView?
    /// P2: reclaims the renderer's GPU resources (~40MB Metal swap chain)
    /// while this window is occluded (minimized, covered, another Space),
    /// mirroring the workspace-selection-driven pattern in
    /// `GhosttySurfaceScrollView.setVisibleInUI`. Without this the relay
    /// window's surface — created directly, not through the portal that
    /// drives that pattern — never releases GPU memory in the background.
    private var occlusionObserver: NSObjectProtocol?

    var onClose: (@MainActor () -> Void)?

    var connectionInfo: PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(self),
            kind: .pane,
            hostSockPath: relaySession.hostSockPath,
            hostDisplayName: relaySession.hostDisplayName,
            sshTarget: nil,
            remoteSockPath: nil,
            targetTitle: surfaceTitle.isEmpty ? "<surface>" : surfaceTitle,
            connectedAt: connectedAt
        )
    }

    // ── Init ─────────────────────────────────────────────────────────

    init(session: PeerRelaySession, surfaceTitle: String) {
        self.relaySession = session
        self.surfaceTitle = surfaceTitle

        // Create a TerminalSurface configured to run the relay binary.
        // Ghostty will spawn it as the "shell" for this pane.
        self.terminalSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: nil,
            command: session.relayLaunchCommand,
            environment: session.relayEnvironment
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
        window.installPeerTitlebarGradientAccent()
        window.center()

        // Embed the Ghostty surface's hosted NSView as the content view.
        let surfaceView = session.relaySockPath  // unused here, just for binding
        _ = surfaceView  // suppress unused warning
        let hostedView = terminalSurface.hostedView
        hostedView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        self.container = container
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

        // Relay errors/disconnects leave context visible and show an
        // explicit close affordance instead of making the window vanish.
        session.onDisconnect = { [weak self] in
            guard let self, !self.isClosing else { return }
            self.showDisconnectedOverlay(
                title: "Connection lost",
                detail: "The peer relay closed. Close this window and reconnect from Connect to Peer."
            )
        }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateRendererRealizedForOcclusion()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    /// P2: toggle the surface's renderer realization to match window
    /// occlusion. Uses the debounced `setSurfaceVisibleForRenderer` (not
    /// `setRendererRealized` directly) so a brief occlusion flap — Mission
    /// Control, a quick window drag over this one — doesn't thrash the
    /// swap chain; becoming visible still realizes immediately.
    private func updateRendererRealizedForOcclusion() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible)
        terminalSurface.setSurfaceVisibleForRenderer(visible)
        #if DEBUG
        dlog("relay.occlusion realized=\(visible ? 1 : 0) kind=pane")
        #endif
    }

    // ── Show ─────────────────────────────────────────────────────────

    func show() {
        relaySession.setResizeAuthorityEligible(true)
        window?.installPeerTitlebarGradientAccent()
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
                self.showDisconnectedOverlay(
                    title: "Relay failed",
                    detail: String(describing: error)
                )
            }
        }
    }

    private func showDisconnectedOverlay(title: String, detail: String) {
        guard disconnectOverlay == nil else { return }

        let overlay = NSVisualEffectView(frame: container.bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.blendingMode = .withinWindow
        overlay.material = .hudWindow
        overlay.state = .active

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .boldSystemFont(ofSize: 14)
        titleField.alignment = .center

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .center
        detailField.maximumNumberOfLines = 3

        let closeButton = NSButton(
            title: "Close",
            target: self,
            action: #selector(closeFromDisconnectOverlay(_:))
        )
        closeButton.bezelStyle = .rounded
        closeButton.setButtonType(.momentaryPushIn)

        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(detailField)
        stack.addArrangedSubview(closeButton)

        overlay.addSubview(stack)
        container.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
        ])

        disconnectOverlay = overlay
    }

    @objc private func closeFromDisconnectOverlay(_ sender: Any?) {
        window?.performClose(sender)
    }

    // ── NSWindowDelegate ─────────────────────────────────────────────

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        relaySession.setResizeAuthorityEligible(false)
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        startTask?.cancel()
        startTask = nil
        let s = relaySession
        Task { await s.stop() }
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        relaySession.setResizeAuthorityEligible(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        relaySession.setResizeAuthorityEligible(false)
    }
}
