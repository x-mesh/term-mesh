// Phase W: layout-preserving relay window. Hosts N PeerRelaySessions
// inside a single NSWindow, arranged in NSSplitViews that mirror the
// host workspace's bonsplit tree.
//
// Phase W' adds live layout sync: a dedicated subscription PeerSession
// listens for `WorkspaceLayoutChanged` push messages from the host and
// applies them to the local NSSplitView tree. Pane reuse is keyed by
// surfaceID — existing panes keep their PTY stream when the host
// reshuffles the layout, and new/removed panes spawn / tear down their
// PeerRelaySession on the fly.

import AppKit
import Bonsplit
import PeerProto

/// Marker NSWindow subclass for peer-relay workspace windows. Lets the
/// app-level NSEvent shortcut monitor (`AppDelegate.handleCustomShortcut`)
/// short-circuit before consuming Cmd+D / Cmd+Shift+D / Cmd+W, so those
/// keystrokes flow through to this controller's local monitor and are
/// forwarded to the remote host instead of triggering a local split.
final class PeerRelayWorkspaceWindow: NSWindow {}

/// Adapter that forwards NSSplitView delegate callbacks back to the
/// owning controller. Lives separately because NSSplitView holds its
/// `delegate` weakly.
@MainActor
private final class WorkspaceSplitWatcher: NSObject, NSSplitViewDelegate {
    weak var controller: PeerRelayWorkspaceWindowController?
    init(controller: PeerRelayWorkspaceWindowController) {
        self.controller = controller
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView else { return }
        controller?.dividerDidResize(splitView)
    }
}

@MainActor
private final class PeerRelayStatusOverlay: NSView {
    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var actionHandler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.84).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 1

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.preferredMaxLayoutWidth = 520

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.isHidden = true

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(actionButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }

    func show(title: String,
              detail: String,
              actionTitle: String? = nil,
              action: (() -> Void)? = nil) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        if let actionTitle, !actionTitle.isEmpty {
            actionButton.title = actionTitle
            actionButton.isHidden = false
            actionHandler = action
        } else {
            actionButton.isHidden = true
            actionHandler = nil
        }
        isHidden = false
    }

    func hide() {
        isHidden = true
        actionHandler = nil
    }

    @objc private func actionTapped() {
        actionHandler?()
    }
}

@MainActor
/// Read-only snapshot of one peer-relay workspace window's
/// connection metadata. Surfaced through
/// `PeerRelayWorkspaceWindowController.connectionInfo` so views like
/// the Connections panel can render rows without holding a reference
/// to (and reaching into) the controller itself.
struct PeerRelayConnectionInfo: Sendable {
    /// Stable identity for the underlying controller. Use with
    /// `PeerClientCoordinator.disconnect(id:)` to act on this connection
    /// safely even after the roster has been re-rendered.
    let id: ObjectIdentifier
    let hostSockPath: String
    /// SSH target if the relay was opened over an `ssh -L` tunnel,
    /// otherwise nil (direct Unix-socket connection).
    let sshTarget: String?
    let workspaceTitle: String
    let connectedAt: Date

    /// Best display string for the host: SSH target if available,
    /// otherwise the local socket path.
    var hostDisplay: String { sshTarget ?? hostSockPath }
}

final class PeerRelayWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    // MARK: - Pane bookkeeping

    /// Per-leaf state. We keep these alive across layout updates so a
    /// host-side resize / split reshuffle doesn't flicker the relay
    /// window's PTY streams.
    private final class PaneSlot {
        let surfaceID: Data
        let session: PeerRelaySession
        let surface: TerminalSurface
        let view: NSView
        init(surfaceID: Data, session: PeerRelaySession, surface: TerminalSurface, view: NSView) {
            self.surfaceID = surfaceID
            self.session = session
            self.surface = surface
            self.view = view
        }
    }

    private let hostSockPath: String
    /// Held strongly while the controller is alive so the tunnel
    /// auto-restart loop keeps running. nil for non-SSH (direct
    /// unix-socket) sessions.
    private var sshTunnel: PeerSSHTunnel?
    /// Wall-clock time the relay window first opened. Captured at
    /// init so the connections panel can compute "Attached Ns ago".
    private let connectedAt: Date = Date()
    /// Workspace title shown to the host. Mirrors `baseTitle` minus
    /// the "Peer Workspace · " prefix so display lists can show it
    /// without redundancy.
    private let workspaceTitle: String
    private var workspaceID: Data

    /// Snapshot of the controller's connection-level metadata for
    /// external observers (the Connections panel, future CLI/headless
    /// listings). Returns the values actually shown in the UI rather
    /// than the underlying `let` storage so callers don't grow a
    /// dependency on the controller's internals.
    var connectionInfo: PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(self),
            hostSockPath: hostSockPath,
            sshTarget: sshTunnel?.sshTarget,
            workspaceTitle: workspaceTitle,
            connectedAt: connectedAt
        )
    }
    private let baseTitle: String
    private var currentLayout: Termmesh_Peer_V1_WorkspaceLayout
    private var panesBySurfaceID: [Data: PaneSlot] = [:]
    /// Splits the renderer needs to apply divider positions to after
    /// the next layout pass. Cleared after each `applyPendingDividerPositions`.
    private var pendingDividerSetters: [(NSSplitView, CGFloat)] = []
    private var subscriptionTask: Task<Void, Never>?
    private var subscriptionTransport: UnixSocketTransport?
    /// Open peer session held alive for the lifetime of the controller.
    /// Used both to receive `WorkspaceLayoutChanged` pushes and to
    /// send fire-and-forget `WorkspaceControl` requests (Cmd+D split,
    /// Cmd+W close, …) back to the host.
    private var subscriptionSession: PeerSession?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// surfaceID of the most recently mouse-down'd pane in this
    /// window. NSWindow.firstResponder doesn't always swing reliably
    /// when Ghostty surfaces sit inside an NSSplitView we built ourselves,
    /// so we track focus explicitly instead.
    private var lastClickedSurfaceID: Data?
    /// Bonsplit split-id (16-byte UUID) keyed to the NSSplitView that
    /// renders it. Used by the divider-drag delegate to identify which
    /// host-side split to update.
    private var splitsByID: [Data: NSSplitView] = [:]
    private var splitIDByObject: [ObjectIdentifier: Data] = [:]
    /// Per-split debounce — drag fires `splitViewDidResizeSubviews` on
    /// every pixel; coalesce to one push per ~150 ms idle window.
    private var dividerDebounce: [Data: Task<Void, Never>] = [:]
    /// Set non-zero while we apply layout updates programmatically so
    /// the resulting `splitViewDidResizeSubviews` callbacks don't echo
    /// the value back to the host (would cause infinite ping-pong).
    private var applyingLayoutDepth: Int = 0
    /// Watcher that converts NSSplitView delegate callbacks back into
    /// controller-side notifications. Stored separately so the split
    /// view's weak `delegate` reference doesn't drop it.
    private var splitWatcher: WorkspaceSplitWatcher?
    private var startTask: Task<Void, Never>?
    /// Serialises `applyLayout` calls so a layout-changed push can't
    /// interleave with an in-flight initial-attach (each can suspend
    /// on `spawnPaneSlot`, leaving `panesBySurfaceID` mutated by both
    /// at unpredictable points). Each call awaits the previous one's
    /// completion before mutating the slot dictionary.
    private var applyLayoutTask: Task<Void, Error>?
    private var isClosing = false

    /// In-window status / error banner. Lives at the top of the content
    /// view; the split tree sits below it. Created lazily on the first
    /// `show*` call so non-SSH sessions never allocate it.
    private var banner: PeerRelayBanner?
    /// Owns banner copy / kind / auto-dismiss timing. Created lazily
    /// alongside the banner inside `ensureBodyStack`. Controller code
    /// forwards tunnel-state transitions to this presenter and never
    /// touches `banner.show(...)` directly.
    private var bannerPresenter: PeerRelayBannerPresenter?
    /// True once `ensureBodyStack` has installed the banner and
    /// splitRoot container into the window's contentView.
    private var bodyInstalled = false
    private var splitRootContainer: NSView?
    private var splitContentContainer: NSView?
    private var statusOverlay: PeerRelayStatusOverlay?

    var onClose: (@MainActor () -> Void)?

    // MARK: - Init

    init(hostSockPath: String, workspace: Termmesh_Peer_V1_Workspace) {
        self.hostSockPath = hostSockPath
        self.workspaceID = workspace.workspaceID
        self.currentLayout = workspace.layout
        let title = workspace.title.isEmpty ? "<workspace>" : workspace.title
        self.workspaceTitle = title
        self.baseTitle = "Peer Workspace · \(title)"

        let initialSize = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let window = PeerRelayWorkspaceWindow(
            contentRect: initialSize,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = self.baseTitle
        window.isReleasedWhenClosed = false
        // Disable AppKit's automatic Cmd+T window tabbing so Cmd+T
        // flows through to our keyMonitor and forwards to the remote
        // host instead of merging this window into a tab group.
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Attach an `PeerSSHTunnel` so the window observes its state and
    /// re-establishes the relay when the tunnel auto-restarts. Must be
    /// called before `show()` if the host is reached over SSH.
    func attachTunnel(_ tunnel: PeerSSHTunnel) {
        self.sshTunnel = tunnel
        tunnel.onStateChange = { [weak self] state in
            self?.handleTunnelStateChange(state)
        }
    }

    @MainActor
    private func handleTunnelStateChange(_ state: PeerSSHTunnelState) {
        switch state {
        case .down(let reason):
            markWindowDisconnected(reason: reason)
            bannerPresenter?.showDisconnected(reason: reason)
            showRelayOverlay(
                title: "Connection lost",
                detail: "Waiting for SSH to reconnect. Pane controls are paused."
            )
            tearDownPeerSessions(keepWindow: true)
        case .reconnecting(let attempt):
            markWindowReconnecting(attempt: attempt)
            bannerPresenter?.showReconnecting(attempt: attempt)
            showRelayOverlay(
                title: "Reconnecting",
                detail: "Attempt \(attempt). Pane controls will resume when the host is reachable."
            )
        case .up:
            markWindowConnected()
            bannerPresenter?.showReattaching()
            showRelayOverlay(
                title: "Re-attaching panes",
                detail: "Refreshing the host layout and rebuilding the relay view."
            )
            // Tunnel just came back. Re-run the initial-attach flow
            // from the same hostSockPath.
            startTask?.cancel()
            startTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let latest = try await self.fetchLatestWorkspace()
                    await MainActor.run {
                        self.workspaceID = latest.workspaceID
                        self.currentLayout = latest.layout
                    }
                    try await self.applyLayout(latest.layout)
                    await self.startSubscription()
                    await MainActor.run { [weak self] in
                        self?.hideRelayOverlay()
                        self?.bannerPresenter?.showReconnected()
                    }
                } catch {
                    let detail = String(describing: error)
                    await MainActor.run { [weak self] in
                        self?.showRelayOverlay(
                            title: "Reconnect failed",
                            detail: detail,
                            actionTitle: "Retry"
                        ) {
                            self?.handleTunnelStateChange(.up)
                        }
                        self?.bannerPresenter?.showReconnectFailed(detail: detail) {
                            // Re-enter `.up` to redrive applyLayout.
                            self?.handleTunnelStateChange(.up)
                        }
                    }
                }
            }
        case .failed(let reason):
            // Auto-retry gave up. Surface a Retry button so the user
            // can re-arm the loop without closing the window.
            markWindowDisconnected(reason: "gave up retrying")
            bannerPresenter?.showFailedTerminal(reason: reason) { [weak self] in
                self?.sshTunnel?.retry()
            }
            showRelayOverlay(
                title: "Reconnect failed",
                detail: reason,
                actionTitle: "Retry"
            ) { [weak self] in
                self?.sshTunnel?.retry()
            }
            tearDownPeerSessions(keepWindow: true)
        case .stopped, .starting:
            break
        }
    }

    // MARK: - Disconnect indicator (window title prefix)

    /// Update the window title with a clear visual disconnect marker.
    /// Idempotent — safe to call repeatedly. Shown for both SSH-tunnel
    /// `.down` / `.failed` and the direct-socket EOF case so all
    /// disconnects produce the same UI affordance.
    @MainActor
    private func markWindowDisconnected(reason: String) {
        let suffix = " — 🔌 Disconnected"
        let detail = reason.isEmpty ? "" : " (\(reason))"
        window?.title = baseTitle + suffix + detail
    }

    @MainActor
    private func markWindowReconnecting(attempt: Int) {
        window?.title = baseTitle + " — Reconnecting (try \(attempt))…"
    }

    @MainActor
    private func markWindowConnected() {
        window?.title = baseTitle
    }

    @MainActor
    private func showRelayOverlay(title: String,
                                  detail: String,
                                  actionTitle: String? = nil,
                                  action: (() -> Void)? = nil) {
        guard let window else { return }
        ensureBodyStack(in: window)
        statusOverlay?.show(
            title: title,
            detail: detail,
            actionTitle: actionTitle,
            action: action
        )
    }

    @MainActor
    private func hideRelayOverlay() {
        statusOverlay?.hide()
    }

    private func tearDownPeerSessions(keepWindow: Bool) {
        startTask?.cancel()
        startTask = nil
        applyLayoutTask?.cancel()
        applyLayoutTask = nil
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscriptionSession = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        for (_, task) in dividerDebounce { task.cancel() }
        dividerDebounce.removeAll()
        splitsByID.removeAll()
        splitIDByObject.removeAll()
        lastClickedSurfaceID = nil
        splitWatcher = nil
        splitContentContainer?.subviews.forEach { $0.removeFromSuperview() }
        let transport = subscriptionTransport
        subscriptionTransport = nil
        let toStop = Array(panesBySurfaceID.values)
        panesBySurfaceID.removeAll()
        Task {
            for slot in toStop { await slot.session.stop() }
            await transport?.close()
        }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        // Force the body stack (and thus the banner) to exist before
        // the first layout pass, so initial-attach errors can land in
        // the banner instead of an immediate window close.
        if let window { ensureBodyStack(in: window) }
        // Install the key monitor immediately so Cmd+D/W/T are
        // intercepted from the moment the window appears, not just
        // after startSubscription completes. dispatchSplit et al.
        // already guard on subscriptionSession being non-nil and will
        // log+no-op if the session isn't ready yet (Fix 1).
        installKeyMonitor()

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.applyLayout(self.currentLayout)
                await self.startSubscription()
            } catch {
                let detail = String(describing: error)
                NSLog("[peer-ws] initial layout failed: %@", detail)
                await MainActor.run { [weak self] in
                    self?.showRelayOverlay(
                        title: "Attach failed",
                        detail: detail,
                        actionTitle: "Close"
                    ) {
                        self?.window?.performClose(nil)
                    }
                    self?.bannerPresenter?.showAttachFailed(detail: detail) {
                        self?.window?.performClose(nil)
                    }
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        // Detach from the tunnel before kicking off async drains so a
        // concurrent ssh exit doesn't fire `.down` into a half-torn
        // controller. Stop the tunnel synchronously here too — the
        // coordinator's onClose also stops it as a fallback, but
        // doing it directly closes the race where the tunnel emits
        // a state change between this method and onClose running.
        if let tunnel = sshTunnel {
            tunnel.onStateChange = nil
            tunnel.stop()
            sshTunnel = nil
        }
        startTask?.cancel()
        startTask = nil
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscriptionSession = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        for (_, task) in dividerDebounce { task.cancel() }
        dividerDebounce.removeAll()
        splitsByID.removeAll()
        splitIDByObject.removeAll()
        splitWatcher = nil
        let transport = subscriptionTransport
        let session = subscriptionSession
        subscriptionTransport = nil
        let toStop = Array(panesBySurfaceID.values)
        panesBySurfaceID.removeAll()
        Task {
            await session?.stopHeartbeat()
            for slot in toStop { await slot.session.stop() }
            await transport?.close()
        }
        onClose?()
    }

    // MARK: - Subscription channel
    //
    // The probe connection used by PeerMenu has been cancelled by
    // the time the controller starts, and per-pane connections silently
    // ignore non-PtyData messages. To receive `WorkspaceLayoutChanged`
    // pushes we open one extra session that does nothing else.

    private func startSubscription() async {
        do {
            let transport = try await UnixSocketTransport.connect(socketPath: hostSockPath)
            let session = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            _ = try await session.handshake()
            subscriptionTransport = transport
            subscriptionSession = session
            // App-level heartbeat. SSH ServerAliveInterval (15s × 3)
            // catches a dead tunnel within ~45s, but it can't catch a
            // remote daemon that's paused while its kernel still
            // answers TCP keepalives (the laptop-sleep / hibernation
            // failure mode the user reported). 10s ping cadence with
            // a 30s "no Pong" deadline closes the hung-tunnel detection
            // gap; on dead, we close the subscription transport so the
            // pump's `receiveNextMessage()` unblocks with an error and
            // the existing disconnect/reconnect path runs.
            let weakTransport = transport
            await session.startHeartbeat(
                intervalSeconds: 10,
                deadAfterSeconds: 30
            ) {
                Task { await weakTransport.close() }
            }
            await MainActor.run { self.installKeyMonitor() }

            subscriptionTask = Task { [weak self] in
                var disconnectReason: String? = nil
                while let self, !Task.isCancelled {
                    let msg: PeerIncomingMessage
                    do {
                        msg = try await session.receiveNextMessage()
                    } catch {
                        // Transport read failed — the host went away.
                        // For SSH-backed sessions the tunnel's own
                        // .down state usually arrives first; for
                        // direct unix-socket sessions this is the
                        // only signal.
                        disconnectReason = String(describing: error)
                        break
                    }
                    if case .workspaceLayoutChanged(let wid, let layout) = msg {
                        guard wid == self.workspaceID else { continue }
                        do {
                            try await self.applyLayout(layout)
                            await MainActor.run { self.currentLayout = layout }
                        } catch {
                            NSLog("[peer-ws] applyLayout error: %@", String(describing: error))
                        }
                    }
                    if case .goodbye = msg {
                        disconnectReason = "host closed connection"
                        break
                    }
                }
                // Announce the loss if we exited unexpectedly. Skip
                // when the controller is mid-shutdown (`isClosing`)
                // or when a tunnel is already driving the disconnect
                // banner — `bannerPresenter.showDisconnected` is
                // idempotent so a duplicate is harmless, but
                // surfacing it from both sides clutters logs.
                if let reason = disconnectReason {
                    await MainActor.run { [weak self] in
                        guard let self, !self.isClosing else { return }
                        self.markWindowDisconnected(reason: reason)
                        self.bannerPresenter?.showDisconnected(reason: reason)
                        self.showRelayOverlay(
                            title: "Connection lost",
                            detail: "The peer session closed. Reconnecting the SSH tunnel."
                        )
                        self.tearDownPeerSessions(keepWindow: true)
                        if let tunnel = self.sshTunnel {
                            Task.detached {
                                tunnel.forceReconnect(reason: "peer session closed: \(reason)")
                            }
                        }
                    }
                }
            }
        } catch {
            NSLog("[peer-ws] subscription connect failed: %@", String(describing: error))
            await MainActor.run { [weak self] in
                guard let self, !self.isClosing else { return }
                let detail = String(describing: error)
                self.markWindowDisconnected(reason: detail)
                self.bannerPresenter?.showDisconnected(reason: detail)
            }
        }
    }

    // MARK: - Workspace control (Cmd+D / Cmd+Shift+D / Cmd+W)
    //
    // Local NSEvent monitor scoped to this window. When the user
    // presses a known split / close shortcut while this relay window
    // is key, intercept it and forward to the host via the
    // subscription session. The host applies the change with bonsplit
    // and the resulting WorkspaceLayoutChanged push patches our local
    // NSSplitView tree (Phase W'). Without interception the shortcut
    // would either no-op (no local bonsplit) or worse, target the
    // app's main window.

    private func installKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  event.modifierFlags.contains(.command)
            else { return event }
            let chars = event.charactersIgnoringModifiers ?? ""
            let shift = event.modifierFlags.contains(.shift)
            switch chars.lowercased() {
            case "d":
                self.dispatchSplit(orientation: shift ? "vertical" : "horizontal")
                return nil
            case "w":
                self.dispatchClose()
                return nil
            case "t":
                self.dispatchNewTab()
                return nil
            default:
                return event
            }
        }

        // Track which pane the user last clicked. Ghostty surfaces
        // embedded in our NSSplitView don't always promote themselves
        // to firstResponder reliably, so we record focus on mouse
        // down and consult that first when dispatching shortcuts. We
        // also forward the focus to the host so its bonsplit follows
        // the click — keeps the two windows in sync visually.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window
            else { return event }
            let point = event.locationInWindow
            for (sid, slot) in self.panesBySurfaceID {
                let frameInWindow = slot.view.convert(slot.view.bounds, to: nil)
                if frameInWindow.contains(point) {
                    if self.lastClickedSurfaceID != sid {
                        self.lastClickedSurfaceID = sid
                        self.dispatchFocus(surfaceID: sid)
                    }
                    break
                }
            }
            return event
        }
    }

    private func dispatchFocus(surfaceID: Data) {
        guard let session = subscriptionSession else { return }
        Task {
            try? await session.requestFocusPane(paneID: surfaceID)
        }
    }

    private func dispatchSplit(orientation: String) {
        guard let surfaceID = focusedPaneSurfaceID(),
              let session = subscriptionSession
        else {
            #if DEBUG
            dlog("relay.split.skip reason=no-subscription window=\(String(format: "%08x", UInt(bitPattern: ObjectIdentifier(self))))")
            #endif
            return
        }
        Task {
            try? await session.requestSplitPane(paneID: surfaceID, orientation: orientation)
        }
    }

    private func dispatchClose() {
        guard let surfaceID = focusedPaneSurfaceID(),
              let session = subscriptionSession
        else { return }
        Task {
            try? await session.requestClosePane(paneID: surfaceID)
        }
    }

    private func dispatchNewTab() {
        guard let surfaceID = focusedPaneSurfaceID(),
              let session = subscriptionSession
        else { return }
        Task {
            try? await session.requestNewTab(paneID: surfaceID)
        }
    }

    /// Resolve the active pane in priority order:
    ///   1. The most recently mouse-down'd pane (tracked by
    ///      `clickMonitor`) — most reliable in our embedded NSSplitView
    ///      where Ghostty doesn't always claim firstResponder.
    ///   2. NSWindow.firstResponder walked up to its enclosing slot.
    ///   3. Fallback to the first slot in the dictionary so the
    ///      shortcut at least targets *something* the host can split.
    private func focusedPaneSurfaceID() -> Data? {
        if let sid = lastClickedSurfaceID, panesBySurfaceID[sid] != nil {
            return sid
        }
        if let window = self.window,
           var view = window.firstResponder as? NSView {
            while true {
                for (sid, slot) in panesBySurfaceID where view === slot.view || view.isDescendant(of: slot.view) {
                    return sid
                }
                guard let parent = view.superview else { break }
                view = parent
            }
        }
        return panesBySurfaceID.keys.first
    }

    // MARK: - Layout application
    //
    // applyLayout(_:) is the single entry point used by both the
    // initial show() and every subsequent layout update push. It:
    //   1. Walks the new layout, ensuring `panesBySurfaceID` has a
    //      slot per leaf — new ones spawn a PeerRelaySession.
    //   2. Builds a fresh NSView hierarchy that reuses existing slot
    //      views, so PTY streams stay alive across reshuffles.
    //   3. Replaces the window content view's child with the new tree.
    //   4. Tears down slots whose surfaces are no longer in the tree.

    /// Serialised entry point. Awaits any in-flight `applyLayout` to
    /// finish before starting the next one, so concurrent calls
    /// (initial attach + layout-changed push, two layout-changed
    /// pushes back-to-back) can't interleave their `panesBySurfaceID`
    /// mutations across `await spawnPaneSlot` suspensions. Cancellation
    /// of the previous task is honoured — a stale apply that's still
    /// in `spawnPaneSlot` when a newer one arrives gets cancelled and
    /// the new one proceeds without waiting.
    @MainActor
    private func applyLayout(_ layout: Termmesh_Peer_V1_WorkspaceLayout) async throws {
        let previous = applyLayoutTask
        let myTask = Task<Void, Error> { [weak self] in
            // Wait for whatever was running before us, ignoring its
            // result (errors there were already handled by their
            // caller's catch).
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await self?.applyLayoutBody(layout)
        }
        applyLayoutTask = myTask
        do {
            try await myTask.value
        } catch {
            // Surface the original error to our caller; the wrapper
            // ref is cleared either way (a newer task may already
            // have replaced it, in which case we leave that alone).
            if applyLayoutTask == myTask { applyLayoutTask = nil }
            throw error
        }
        if applyLayoutTask == myTask { applyLayoutTask = nil }
    }

    /// Actual layout-application logic. Annotated `@MainActor` so all
    /// `panesBySurfaceID` mutations across the various `await` points
    /// happen on a single actor — `windowWillClose` /
    /// `tearDownPeerSessions` (also MainActor-bound) won't observe
    /// torn intermediate state.
    @MainActor
    private func applyLayoutBody(_ layout: Termmesh_Peer_V1_WorkspaceLayout) async throws {
        // Fast path: if the only thing that changed since the last
        // applied layout is divider positions, just push positions
        // into the existing NSSplitView tree. Saves a full
        // teardown / rebuild + Auto Layout pass per host divider
        // drag tick — the dominant cost during a drag.
        //
        // Gated on `!panesBySurfaceID.isEmpty` because the controller
        // initialises `currentLayout = workspace.layout` in `init`,
        // so on the very first call to applyLayout the proto values
        // already match — without this guard we'd skip the initial
        // spawn / mount and the relay window would render blank.
        if !panesBySurfaceID.isEmpty,
           Self.isDividerOnlyDelta(from: currentLayout, to: layout)
        {
            await MainActor.run { self.applyDividerPositions(from: layout) }
            return
        }

        let newSurfaceIDs = collectSurfaceIDs(layout)
        let missingSurfaceIDs = newSurfaceIDs.filter { panesBySurfaceID[$0] == nil }
        let surfaceInfoByID = try await fetchSurfaceInfoByIDIfNeeded(for: Array(missingSurfaceIDs))
        // Spawn missing slots first (async, may take time per pane).
        for surfaceID in missingSurfaceIDs {
            let pane = findPane(for: surfaceID, in: layout) ?? makeEmptyPaneStub(surfaceID: surfaceID)
            let slot = try await spawnPaneSlot(pane, surfaceInfo: surfaceInfoByID[surfaceID])
            panesBySurfaceID[surfaceID] = slot
        }

        // Build the new view tree on the main actor.
        let (newRoot, dividers) = await MainActor.run { () -> (NSView, [(NSSplitView, CGFloat)]) in
            self.pendingDividerSetters.removeAll()
            self.splitsByID.removeAll()
            self.splitIDByObject.removeAll()
            let view = self.materializeLayout(layout)
            return (view, self.pendingDividerSetters)
        }
        await MainActor.run { self.swapRootView(newRoot, dividers: dividers) }

        // Tear down slots only when the surface is gone from EVERY
        // pane's tab list — keeping cached slots for inactive tabs of
        // the same bonsplit pane lets a tab-switch reuse the existing
        // PeerRelaySession + ghostty surface instead of paying the
        // handshake / fork / snapshot cost on every click.
        let liveSurfaceIDs = collectAllLiveSurfaceIDs(layout)
        let toRemove = Set(panesBySurfaceID.keys).subtracting(liveSurfaceIDs)
        for sid in toRemove {
            if let slot = panesBySurfaceID.removeValue(forKey: sid) {
                Task { await slot.session.stop() }
            }
        }
    }

    /// Walk old + new layouts in lockstep. Same topology means: same
    /// tree shape, same surface IDs at every leaf with identical tab
    /// metadata, and same split IDs / orientations at every internal
    /// node. Only `divider_position` is allowed to differ. Anything
    /// else falls back to the full-rebuild path.
    private static func isDividerOnlyDelta(
        from old: Termmesh_Peer_V1_WorkspaceLayout,
        to new: Termmesh_Peer_V1_WorkspaceLayout
    ) -> Bool {
        switch (old.node, new.node) {
        case (.pane(let pa), .pane(let pb)):
            return pa.surfaceID == pb.surfaceID
                && pa.tabs == pb.tabs
                && pa.title == pb.title
        case (.split(let sa), .split(let sb)):
            guard sa.orientation == sb.orientation,
                  sa.splitID == sb.splitID,
                  !sa.splitID.isEmpty
            else { return false }
            return isDividerOnlyDelta(from: sa.first, to: sb.first)
                && isDividerOnlyDelta(from: sa.second, to: sb.second)
        default:
            return false
        }
    }

    /// Walk the layout and call `setPosition` on every NSSplitView
    /// that has a stable splitID. `applyingLayoutDepth` gates the
    /// divider-watcher so these programmatic moves don't echo back to
    /// the host as another `requestSetDivider`.
    @MainActor
    private func applyDividerPositions(from layout: Termmesh_Peer_V1_WorkspaceLayout) {
        applyingLayoutDepth += 1
        applyDividerPositionsRecursive(layout)
        DispatchQueue.main.async { [weak self] in
            self?.applyingLayoutDepth = max(0, (self?.applyingLayoutDepth ?? 1) - 1)
        }
    }

    @MainActor
    private func applyDividerPositionsRecursive(_ layout: Termmesh_Peer_V1_WorkspaceLayout) {
        guard case .split(let split) = layout.node else { return }
        if let nsSplit = splitsByID[split.splitID] {
            let extent: CGFloat = nsSplit.isVertical ? nsSplit.bounds.width : nsSplit.bounds.height
            if extent > 0 {
                let position = max(20, min(extent - 20, extent * CGFloat(split.dividerPosition)))
                nsSplit.setPosition(position, ofDividerAt: 0)
            }
        }
        applyDividerPositionsRecursive(split.first)
        applyDividerPositionsRecursive(split.second)
    }

    private func swapRootView(_ newRoot: NSView, dividers: [(NSSplitView, CGFloat)]) {
        guard let window = self.window else { return }
        ensureBodyStack(in: window)
        guard let splitContainer = splitContentContainer else { return }

        for sub in splitContainer.subviews { sub.removeFromSuperview() }
        newRoot.translatesAutoresizingMaskIntoConstraints = false
        splitContainer.addSubview(newRoot)
        NSLayoutConstraint.activate([
            newRoot.topAnchor.constraint(equalTo: splitContainer.topAnchor),
            newRoot.bottomAnchor.constraint(equalTo: splitContainer.bottomAnchor),
            newRoot.leadingAnchor.constraint(equalTo: splitContainer.leadingAnchor),
            newRoot.trailingAnchor.constraint(equalTo: splitContainer.trailingAnchor),
        ])
        // Programmatic divider apply — silence the divider-watcher
        // callbacks so we don't bounce the position straight back to
        // the host.
        applyingLayoutDepth += 1
        splitContainer.layoutSubtreeIfNeeded()
        for (split, fraction) in dividers {
            let extent: CGFloat = split.isVertical ? split.bounds.width : split.bounds.height
            guard extent > 0 else { continue }
            let position = max(20, min(extent - 20, extent * fraction))
            split.setPosition(position, ofDividerAt: 0)
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyingLayoutDepth = max(0, (self?.applyingLayoutDepth ?? 1) - 1)
        }
    }

    /// Install banner (top, height 0 when hidden) and splitRoot
    /// container (under banner, fills remainder) into the window's
    /// contentView. Idempotent.
    private func ensureBodyStack(in window: NSWindow) {
        if bodyInstalled { return }
        let container = window.contentView ?? NSView(frame: window.contentLayoutRect)
        if window.contentView == nil { window.contentView = container }
        for sub in container.subviews { sub.removeFromSuperview() }

        let bannerView = PeerRelayBanner(frame: .zero)
        self.banner = bannerView
        self.bannerPresenter = PeerRelayBannerPresenter(banner: bannerView)
        let split = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        self.splitRootContainer = split

        let splitContent = NSView()
        splitContent.translatesAutoresizingMaskIntoConstraints = false
        self.splitContentContainer = splitContent
        let overlay = PeerRelayStatusOverlay(frame: .zero)
        self.statusOverlay = overlay
        split.addSubview(splitContent)
        split.addSubview(overlay)

        container.addSubview(bannerView)
        container.addSubview(split)
        NSLayoutConstraint.activate([
            bannerView.topAnchor.constraint(equalTo: container.topAnchor),
            bannerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bannerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            split.topAnchor.constraint(equalTo: bannerView.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            splitContent.topAnchor.constraint(equalTo: split.topAnchor),
            splitContent.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            splitContent.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            splitContent.trailingAnchor.constraint(equalTo: split.trailingAnchor),

            overlay.topAnchor.constraint(equalTo: split.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: split.trailingAnchor),
        ])
        bodyInstalled = true
    }

    /// Called by `WorkspaceSplitWatcher` whenever an NSSplitView posts
    /// a resize event. Skips events triggered by our own
    /// `swapRootView` apply, debounces the rest by ~150 ms so a drag
    /// becomes a single push, then forwards the new ratio to the host.
    fileprivate func dividerDidResize(_ splitView: NSSplitView) {
        guard applyingLayoutDepth == 0 else { return }
        guard let splitID = splitIDByObject[ObjectIdentifier(splitView)] else { return }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard extent > 0, splitView.subviews.count >= 2 else { return }
        let firstExtent = splitView.isVertical
            ? splitView.subviews[0].frame.width
            : splitView.subviews[0].frame.height
        let ratio = Double(max(0.0, min(1.0, firstExtent / extent)))

        dividerDebounce[splitID]?.cancel()
        dividerDebounce[splitID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            await self?.sendDividerUpdate(splitID: splitID, ratio: ratio)
        }
    }

    private func sendDividerUpdate(splitID: Data, ratio: Double) async {
        guard let session = subscriptionSession else { return }
        try? await session.requestSetDivider(splitID: splitID, ratio: ratio)
    }

    /// Recursively builds an NSView hierarchy from a layout proto,
    /// reusing existing PaneSlot views by surfaceID.
    private func materializeLayout(_ layout: Termmesh_Peer_V1_WorkspaceLayout) -> NSView {
        switch layout.node {
        case .pane(let pane):
            if let slot = panesBySurfaceID[pane.surfaceID] {
                slot.view.removeFromSuperview()
                return slot.view
            }
            // Should never happen since spawnPaneSlot ran for every
            // missing leaf before this method is called.
            return NSView()
        case .split(let split):
            let first = materializeLayout(split.first)
            let second = materializeLayout(split.second)
            let nsSplit = NSSplitView()
            nsSplit.isVertical = (split.orientation == "horizontal")
            nsSplit.dividerStyle = .thin
            nsSplit.translatesAutoresizingMaskIntoConstraints = false
            nsSplit.addSubview(first)
            nsSplit.addSubview(second)
            pendingDividerSetters.append((nsSplit, CGFloat(split.dividerPosition)))
            // Register split for divider-drag forwarding when the host
            // gave us a stable id.
            if !split.splitID.isEmpty {
                splitsByID[split.splitID] = nsSplit
                splitIDByObject[ObjectIdentifier(nsSplit)] = split.splitID
                if splitWatcher == nil {
                    splitWatcher = WorkspaceSplitWatcher(controller: self)
                }
                nsSplit.delegate = splitWatcher
            }
            return nsSplit
        case .none:
            return NSView()
        }
    }

    // MARK: - Slot factory

    private func fetchLatestWorkspace() async throws -> Termmesh_Peer_V1_Workspace {
        let conn = try await PeerRelaySession.connect(hostSockPath: hostSockPath)
        defer { Task { await conn.cancel() } }
        let workspaces = try await conn.session.listWorkspaces()
        if let same = workspaces.first(where: { $0.workspaceID == workspaceID }) {
            return same
        }
        if workspaces.count == 1, let only = workspaces.first {
            return only
        }
        throw RelayError.ioError("workspace disappeared from host")
    }

    private func fetchSurfaceInfoByIDIfNeeded(
        for surfaceIDs: [Data]
    ) async throws -> [Data: Termmesh_Peer_V1_SurfaceInfo] {
        guard !surfaceIDs.isEmpty else { return [:] }
        let conn = try await PeerRelaySession.connectAndList(hostSockPath: hostSockPath)
        defer { Task { await conn.cancel() } }
        let wanted = Set(surfaceIDs)
        return Dictionary(uniqueKeysWithValues: conn.surfaces
            .filter { wanted.contains($0.surfaceID) }
            .map { ($0.surfaceID, $0) })
    }

    private func spawnPaneSlot(
        _ pane: Termmesh_Peer_V1_WorkspacePane,
        surfaceInfo: Termmesh_Peer_V1_SurfaceInfo?
    ) async throws -> PaneSlot {
        let conn = try await PeerRelaySession.connect(hostSockPath: hostSockPath)
        let chosen = surfaceInfo ?? makeFallbackSurfaceInfo(from: pane)
        let session = try await PeerRelaySession.attach(conn, surface: chosen)
        try session.prepareListener()

        let surface = await MainActor.run {
            TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
                configTemplate: nil,
                command: session.relayBinaryPath,
                environment: [
                    "TERMMESH_PEER_RELAY_SOCKET": session.relaySockPath,
                    "TERMMESH_PEER_RELAY_SECRET": session.relaySecret,
                ]
            )
        }

        let paneCopy = pane
        let wrapper = await MainActor.run { () -> NSView in
            let host = surface.hostedView
            host.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(host)

            // Phase E-4: tab strip across the top when the host pane
            // has 2+ tabs. Click → requestActivateTab → host swaps the
            // active tab → relay receives a layout-changed push and
            // respawns the slot for the new active surface.
            if let tabBar = self.buildTabBar(for: paneCopy) {
                wrap.addSubview(tabBar)
                NSLayoutConstraint.activate([
                    tabBar.topAnchor.constraint(equalTo: wrap.topAnchor),
                    tabBar.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                    tabBar.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                    host.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                    host.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                    host.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    host.topAnchor.constraint(equalTo: wrap.topAnchor),
                    host.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                    host.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                ])
            }
            return wrap
        }

        Task {
            do { try await session.start() }
            catch { NSLog("[peer-relay] workspace pane start failed: %@", String(describing: error)) }
        }

        return PaneSlot(surfaceID: pane.surfaceID, session: session, surface: surface, view: wrapper)
    }

    // MARK: - Tab strip (Phase E-4)

    /// Per-pane tab strip button. Carries the host pane's active
    /// surfaceID + the tab's own surfaceID so a click can dispatch
    /// `ActivateTab` without hunting for context. Nested inside the
    /// controller so nothing in `Sources/` accidentally instantiates
    /// it from the global namespace.
    @MainActor
    final class TabStripButton: NSButton {
        let paneID: Data
        let tabSurfaceID: Data
        let isActive: Bool

        init(title: String, paneID: Data, tabSurfaceID: Data, isActive: Bool) {
            self.paneID = paneID
            self.tabSurfaceID = tabSurfaceID
            self.isActive = isActive
            super.init(frame: .zero)
            self.title = title
            self.bezelStyle = .recessed
            self.controlSize = .small
            self.font = NSFont.systemFont(ofSize: 11)
            self.translatesAutoresizingMaskIntoConstraints = false
            self.setButtonType(.toggle)
            self.lineBreakMode = .byTruncatingTail
            // Map "is the host's active tab" onto NSButton state so
            // the built-in recessed style draws the highlighted look
            // for the active tab and the muted look for others.
            self.state = isActive ? .on : .off
        }

        required init?(coder: NSCoder) { fatalError("not used") }
    }

    /// Build a tab strip for a pane, or nil if there's nothing useful
    /// to show (0 or 1 tab). Each tab becomes an NSButton wired to
    /// `tabButtonClicked(_:)` so a click sends ActivateTab to the host.
    @MainActor
    fileprivate func buildTabBar(for pane: Termmesh_Peer_V1_WorkspacePane) -> NSView? {
        guard pane.tabs.count >= 2 else { return nil }
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 2
        strip.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor

        for tab in pane.tabs {
            let title = tab.title.isEmpty ? "Terminal" : tab.title
            let btn = TabStripButton(
                title: title,
                paneID: pane.surfaceID,
                tabSurfaceID: tab.surfaceID,
                isActive: tab.surfaceID == pane.surfaceID
            )
            btn.target = self
            btn.action = #selector(tabButtonClicked(_:))
            strip.addArrangedSubview(btn)
        }
        // Trailing flexible spacer so tabs left-align even when the
        // pane is wide.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        strip.addArrangedSubview(spacer)

        NSLayoutConstraint.activate([
            strip.heightAnchor.constraint(equalToConstant: 24),
        ])
        return strip
    }

    @MainActor
    @objc private func tabButtonClicked(_ sender: TabStripButton) {
        guard let session = subscriptionSession else { return }
        let paneID = sender.paneID
        let tabID = sender.tabSurfaceID
        Task {
            try? await session.requestActivateTab(paneID: paneID, surfaceID: tabID)
        }
    }

    // MARK: - Helpers

    /// Surface IDs of every leaf currently *mounted* in the layout
    /// (one per bonsplit pane, the active tab). Used by the spawn /
    /// mount path.
    private func collectSurfaceIDs(_ layout: Termmesh_Peer_V1_WorkspaceLayout) -> Set<Data> {
        switch layout.node {
        case .pane(let p): return [p.surfaceID]
        case .split(let s):
            return collectSurfaceIDs(s.first).union(collectSurfaceIDs(s.second))
        case .none: return []
        }
    }

    /// Active surface IDs PLUS every inactive tab's surface ID — the
    /// full set of surfaces the user might switch back to without a
    /// fresh attach. The teardown gate compares against this so a
    /// PaneSlot for a pane the user just clicked away from stays
    /// alive while the host still lists that tab.
    private func collectAllLiveSurfaceIDs(_ layout: Termmesh_Peer_V1_WorkspaceLayout) -> Set<Data> {
        switch layout.node {
        case .pane(let p):
            var ids: Set<Data> = [p.surfaceID]
            for tab in p.tabs {
                ids.insert(tab.surfaceID)
            }
            return ids
        case .split(let s):
            return collectAllLiveSurfaceIDs(s.first).union(collectAllLiveSurfaceIDs(s.second))
        case .none: return []
        }
    }

    private func findPane(for surfaceID: Data, in layout: Termmesh_Peer_V1_WorkspaceLayout) -> Termmesh_Peer_V1_WorkspacePane? {
        switch layout.node {
        case .pane(let p):
            return p.surfaceID == surfaceID ? p : nil
        case .split(let s):
            return findPane(for: surfaceID, in: s.first) ?? findPane(for: surfaceID, in: s.second)
        case .none: return nil
        }
    }

    private func makeEmptyPaneStub(surfaceID: Data) -> Termmesh_Peer_V1_WorkspacePane {
        var p = Termmesh_Peer_V1_WorkspacePane()
        p.surfaceID = surfaceID
        p.cols = 80
        p.rows = 24
        return p
    }

    private func makeFallbackSurfaceInfo(from pane: Termmesh_Peer_V1_WorkspacePane) -> Termmesh_Peer_V1_SurfaceInfo {
        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = pane.surfaceID
        info.title = pane.title
        info.cols = pane.cols
        info.rows = pane.rows
        info.cwd = pane.cwd
        info.surfaceType = "terminal"
        info.attachable = true
        return info
    }
}
