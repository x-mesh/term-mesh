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
import SwiftUI
import Bonsplit
import PeerProto

/// Marker NSWindow subclass for peer-relay workspace windows. Lets the
/// app-level NSEvent shortcut monitor (`AppDelegate.handleCustomShortcut`)
/// short-circuit before consuming Cmd+D / Cmd+Shift+D / Cmd+W, so those
/// keystrokes flow through to this controller's local monitor and are
/// forwarded to the remote host instead of triggering a local split.
final class PeerRelayWorkspaceWindow: NSWindow {}

// PeerTitlebarGradientView + installPeerTitlebarGradientAccent moved to
// PeerTitlebarAccent.swift (parameterized by host color so the main
// window can share the accent for focused remote panes).

/// Minimum extent (pt) for any pane inside a peer-workspace split, so a
/// divider drag (or a remote layout pushing a near-edge ratio) can never
/// shrink a pane down to an invisible sliver. Mirrors bonsplit's default
/// 100 pt min pane size. Relaxed to half the container when the window is
/// too small to honor it for both panes, so both stay visible.
private let peerWorkspaceMinPaneExtent: CGFloat = 100

/// Resolve the effective per-pane minimum for a split of the given extent:
/// the configured minimum, capped at half the container so two panes can
/// always coexist even in a tiny window.
private func peerWorkspaceMinPane(forExtent extent: CGFloat) -> CGFloat {
    guard extent > 0 else { return 0 }
    return min(peerWorkspaceMinPaneExtent, extent / 2)
}

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

    // Enforce a minimum extent on user divider drags. Without these the
    // NSSplitView lets a divider travel to the very edge, collapsing the
    // opposite pane to 0 pt — the "hidden pane" the user hit.
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return max(proposedMinimumPosition, peerWorkspaceMinPane(forExtent: extent))
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposedMaximumPosition, extent - peerWorkspaceMinPane(forExtent: extent))
    }

    // Never let a double-click / drag collapse a pane out of sight.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
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
/// Read-only snapshot of one active peer-relay connection's
/// connection metadata. Surfaced through
/// `connectionInfo` properties so views like the Connections panel can
/// render rows without holding references to AppKit controllers.
struct PeerRelayConnectionInfo: Sendable {
    enum Kind: String, Sendable {
        case console = "Console"
        case pane = "Pane"
        case workspace = "Workspace"
    }

    /// Stable identity for the underlying controller. Use with
    /// `PeerClientCoordinator.disconnect(id:)` to act on this connection
    /// safely even after the roster has been re-rendered.
    let id: ObjectIdentifier
    let kind: Kind
    let hostSockPath: String
    let hostDisplayName: String?
    /// SSH target if the relay was opened over an `ssh -L` tunnel,
    /// otherwise nil (direct Unix-socket connection).
    let sshTarget: String?
    /// Remote (host-side) socket path when reached over SSH; nil for direct.
    /// Paired with `sshTarget` so the sidebar can re-derive an `.ssh` spec
    /// that owns its own tunnel instead of borrowing this connection's
    /// reconnect-ephemeral local socket.
    let remoteSockPath: String?
    let targetTitle: String
    let connectedAt: Date

    /// Best display string for the host: SSH target if available,
    /// otherwise the host's peer name, otherwise the local socket path.
    var hostDisplay: String {
        if let sshTarget, !sshTarget.isEmpty { return "SSH · \(sshTarget)" }
        if let hostDisplayName, !hostDisplayName.isEmpty { return hostDisplayName }
        return hostSockPath
    }
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
    private let hostDisplayName: String?
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
    private var workspaceTitle: String
    private var workspaceID: Data

    /// Snapshot of the controller's connection-level metadata for
    /// external observers (the Connections panel, future CLI/headless
    /// listings). Returns the values actually shown in the UI rather
    /// than the underlying `let` storage so callers don't grow a
    /// dependency on the controller's internals.
    var connectionInfo: PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(self),
            kind: .workspace,
            hostSockPath: hostSockPath,
            hostDisplayName: hostDisplayName,
            sshTarget: sshTunnel?.sshTarget,
            remoteSockPath: sshTunnel?.remoteSockPath,
            targetTitle: workspaceTitle,
            connectedAt: connectedAt
        )
    }
    private var baseTitle: String
    private var currentLayout: Termmesh_Peer_V1_WorkspaceLayout
    private var panesBySurfaceID: [Data: PaneSlot] = [:]
    /// Registry mirroring `panesBySurfaceID` 1:1 (populated/cleared at the
    /// same call sites: `spawnAndStore`, and all three removal sites —
    /// `close()`/`invalidate()`-style teardown ×2 plus the stale-pane
    /// sweep), keyed by the same wire surfaceID `Data` but holding only the
    /// `TerminalSurface`. Lets debug/test tooling (e.g. `debug.peer.read_grid`,
    /// P5) resolve "the local surface currently rendering peer surface X"
    /// without reaching into window-controller internals or a wire round
    /// trip — "reading a remote pane's grid" really is just reading this
    /// surface like any other local pane. `static` (not per-instance) since
    /// surfaceIDs are globally unique (derived from the remote host's own
    /// panel UUID) and a debug caller has no window-controller handle to
    /// scope the lookup to.
    private static var relaySurfacesByID: [Data: TerminalSurface] = [:]

    /// Test/debug accessor for `relaySurfacesByID` — see its declaration.
    static func debugRelaySurface(forSurfaceID surfaceID: Data) -> TerminalSurface? {
        relaySurfacesByID[surfaceID]
    }

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
    /// P1 narrow session sharing: fans this workspace's single receive
    /// loop (the subscription loop below) out to the panes by surface_id.
    /// Non-nil once `startSubscription` succeeds; panes attach on
    /// `subscriptionSession` and consume their PtyData through here
    /// instead of each opening their own session + handshake. nil forces
    /// the per-pane fallback in `spawnPaneSlot`.
    private var subscriptionDemux: PeerSessionDemux?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// P2: reclaims GPU resources (~40MB Metal swap chain per pane) for
    /// every owned `TerminalSurface` while this window is occluded
    /// (minimized, covered, another Space). Mirrors the workspace-
    /// selection-driven pattern in `GhosttySurfaceScrollView.setVisibleInUI`,
    /// which this window's panes bypass since they're created directly
    /// rather than mounted through that portal.
    private var occlusionObserver: NSObjectProtocol?
    /// surfaceID of the most recently mouse-down'd pane in this
    /// window. NSWindow.firstResponder doesn't always swing reliably
    /// when Ghostty surfaces sit inside an NSSplitView we built ourselves,
    /// so we track focus explicitly instead.
    private var lastClickedSurfaceID: Data?
    /// Non-nil when the user has zoomed one pane to fill the window
    /// (Cmd+Shift+Enter). Mirrors Bonsplit's local zoom: the split tree
    /// stays unchanged in `currentLayout`; only the relay's render swaps
    /// to a single-pane view. Cleared by any `applyLayout` rebuild.
    private var zoomedSurfaceID: Data?
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
    private var sidebarModel: PeerRelayWorkspaceSidebarModel?
    private var sidebarHostingView: NSHostingView<PeerRelayWorkspaceSidebarView>?
    private var workspaceFetchTask: Task<Void, Never>?

    var onClose: (@MainActor () -> Void)?

    // MARK: - Init

    init(hostSockPath: String,
         workspace: Termmesh_Peer_V1_Workspace,
         hostDisplayName: String? = nil) {
        self.hostSockPath = hostSockPath
        self.hostDisplayName = hostDisplayName
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
        window.installPeerTitlebarGradientAccent()
        // Disable AppKit's automatic Cmd+T window tabbing so Cmd+T
        // flows through to our keyMonitor and forwards to the remote
        // host instead of merging this window into a tab group.
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)
        window.delegate = self

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateRendererRealizedForOcclusion()
        }

        let model = PeerRelayWorkspaceSidebarModel()
        model.workspaces = [PeerRelayWorkspaceSummary(
            id: self.workspaceID,
            title: self.workspaceTitle,
            windowID: workspace.windowID,
            windowTitle: workspace.windowTitle
        )]
        model.selectedID = self.workspaceID
        model.onSelect = { [weak self] ws in self?.switchToWorkspace(ws) }
        self.sidebarModel = model
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    /// P2: toggle every owned pane's renderer realization to match window
    /// occlusion. Uses the debounced `setSurfaceVisibleForRenderer` (not
    /// `setRendererRealized` directly) so a brief occlusion flap doesn't
    /// thrash each pane's swap chain; becoming visible still realizes
    /// immediately. Panes spawned while the window is already occluded
    /// start realized (a fresh `TerminalSurface` defaults to realized) and
    /// only reclaim on the next occlusion transition — acceptable for this
    /// pass since it matches the existing workspace-selection pattern's
    /// same characteristic.
    private func updateRendererRealizedForOcclusion() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible)
        for slot in panesBySurfaceID.values {
            slot.surface.setSurfaceVisibleForRenderer(visible)
        }
        #if DEBUG
        dlog("relay.occlusion realized=\(visible ? 1 : 0) panes=\(panesBySurfaceID.count) kind=workspace")
        #endif
    }

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
        let demux = subscriptionDemux
        subscriptionDemux = nil
        let toStop = Array(panesBySurfaceID.values)
        panesBySurfaceID.removeAll()
        for slot in toStop { Self.relaySurfacesByID.removeValue(forKey: slot.surfaceID) }
        Task {
            // Finish the demux streams first so each shared pane's pump
            // loop exits, then stop the slots and close the transport.
            await demux?.finishAll()
            for slot in toStop { await slot.session.stop() }
            await transport?.close()
        }
    }

    func show() {
        window?.installPeerTitlebarGradientAccent()
        window?.makeKeyAndOrderFront(nil)
        // Force the body stack (and thus the banner) to exist before
        // the first layout pass, so initial-attach errors can land in
        // the banner instead of an immediate window close.
        if let window { ensureBodyStack(in: window) }
        fetchWorkspaces()
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
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        startTask?.cancel()
        startTask = nil
        workspaceFetchTask?.cancel()
        workspaceFetchTask = nil
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
        let demux = subscriptionDemux
        subscriptionDemux = nil
        let toStop = Array(panesBySurfaceID.values)
        panesBySurfaceID.removeAll()
        for slot in toStop { Self.relaySurfacesByID.removeValue(forKey: slot.surfaceID) }
        Task {
            await demux?.finishAll()
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
            // P1: this authenticated session is now shared by every pane.
            // The single receive loop below routes PtyData to panes via the
            // demux; panes attach on `session` instead of each dialing a new
            // connection + handshake.
            let demux = PeerSessionDemux()
            #if DEBUG
            // Measurement: app-side truncation source for the shared path —
            // a slow pane's stream drops its oldest chunks under output load.
            await demux.setOnDrop { surfaceID, total in
                dlog("peer.relay.demux.drop surface=\(surfaceID.map { String(format: "%02x", $0) }.joined().prefix(8)) totalDropped=\(total)")
            }
            #endif
            subscriptionDemux = demux
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
                deadAfterSeconds: 30,
                onFirstMiss: { [weak self] in
                    // P6: optimistic early warning — a Pong is overdue by
                    // one interval (~10-15s), well before the 30s dead
                    // threshold that drives the existing tunnel-restart
                    // chain below. Soft "reconnecting" banner only; does
                    // not touch the tunnel or tearDownPeerSessions.
                    Task { await MainActor.run { [weak self] in
                        guard let self, !self.isClosing else { return }
                        #if DEBUG
                        dlog("peer.heartbeat.first_miss")
                        #endif
                        self.bannerPresenter?.showReconnecting(attempt: 0)
                    } }
                },
                onMissRecovered: { [weak self] in
                    // The outage resolved on its own (a fresh Pong landed
                    // before `deadAfter`), so `onDead` never fires and
                    // nothing else would clear the banner above. Reuse
                    // the existing success presentation instead of
                    // adding a new banner kind.
                    Task { await MainActor.run { [weak self] in
                        guard let self, !self.isClosing else { return }
                        #if DEBUG
                        dlog("peer.heartbeat.recovered")
                        #endif
                        self.bannerPresenter?.showReconnected()
                    } }
                }
            ) {
                Task { await weakTransport.close() }
            }
            await MainActor.run {
                self.installKeyMonitor()
                self.restoreRelayFocus(after: self.currentLayout, forwardToHost: false)
            }

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
                    // P1 shared-session fan-out: deliver each pane's PtyData to
                    // its own demux consumer. Because this is the *only* loop
                    // reading the session, no pane can steal or silently drop a
                    // sibling's frame (a naive per-pane surface_id filter on a
                    // shared session would do both). Non-PtyData messages fall
                    // through to the existing layout/goodbye handling.
                    if case .ptyData(let sid, let seq, let payload) = msg {
                        await demux.route(surfaceID: sid, byteSeq: seq, payload: payload)
                        continue
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
            // Cmd+Shift+Return: zoom focused pane to fill the relay window.
            // Matches the local Cmd+Shift+Enter "Zoom Pane" shortcut, but
            // applies only to the relay's render — the host workspace is
            // not informed.
            if shift, event.keyCode == 36 /* kVK_Return */ {
                self.toggleRelayPaneZoom()
                return nil
            }
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
            guard let contentView = window.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            guard let hitView = contentView.hitTest(point) else { return event }
            for (sid, slot) in self.panesBySurfaceID
                where hitView === slot.view || hitView.isDescendant(of: slot.view)
            {
                self.focusRelayPane(surfaceID: sid, forwardToHost: false)
                break
            }
            return event
        }
    }

    @MainActor
    private func focusRelayPane(surfaceID: Data, forwardToHost: Bool) {
        guard let slot = panesBySurfaceID[surfaceID] else { return }
        lastClickedSurfaceID = surfaceID
        updatePaneFocusDecorations()
        slot.surface.hostedView.moveFocus()
        #if DEBUG
        dlog("relay.focus surface=\(Self.shortSurfaceID(surfaceID)) forward=\(forwardToHost ? 1 : 0)")
        #endif
        if forwardToHost {
            dispatchFocus(surfaceID: surfaceID)
        }
    }

    /// Toggle a Bonsplit-style "zoom one pane to fill the window" mode.
    /// Local-only — the host workspace stays untouched. Any subsequent
    /// `applyLayout` push restores the split tree (clearing the zoom).
    @MainActor
    private func toggleRelayPaneZoom() {
        if let prev = zoomedSurfaceID {
            // Exit zoom: rebuild the split tree from `currentLayout`. We
            // can't re-enter `applyLayout` here because its fast path
            // skips the rebuild when `currentLayout == currentLayout`
            // (the divider-only delta check returns true), leaving the
            // zoomed single-pane view in place. Materialize the tree
            // synchronously and swap it in instead.
            zoomedSurfaceID = nil
            #if DEBUG
            dlog("relay.zoom exit prev=\(Self.shortSurfaceID(prev))")
            #endif
            pendingDividerSetters.removeAll()
            splitsByID.removeAll()
            splitIDByObject.removeAll()
            let newRoot = materializeLayout(currentLayout)
            let dividers = pendingDividerSetters
            swapRootView(newRoot, dividers: dividers)
            restoreRelayFocus(after: currentLayout, forwardToHost: false)
            return
        }
        // Enter zoom: pick the focused pane (or the first available one
        // when nothing has been clicked yet) and reparent its view into
        // the split content container as the sole child.
        let target = lastClickedSurfaceID.flatMap { panesBySurfaceID[$0] != nil ? $0 : nil }
            ?? firstSurfaceID(in: currentLayout)
        guard let surfaceID = target,
              let slot = panesBySurfaceID[surfaceID],
              let container = splitContentContainer
        else {
            #if DEBUG
            dlog("relay.zoom enter no-target")
            #endif
            return
        }
        zoomedSurfaceID = surfaceID
        #if DEBUG
        dlog("relay.zoom enter surface=\(Self.shortSurfaceID(surfaceID))")
        #endif
        for sub in container.subviews { sub.removeFromSuperview() }
        let paneView = slot.view
        paneView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: container.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            paneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        focusRelayPane(surfaceID: surfaceID, forwardToHost: false)
    }

    @MainActor
    private func restoreRelayFocus(after layout: Termmesh_Peer_V1_WorkspaceLayout,
                                   forwardToHost: Bool) {
        let mounted = collectSurfaceIDs(layout)
        let target = lastClickedSurfaceID.flatMap { mounted.contains($0) ? $0 : nil }
            ?? firstSurfaceID(in: layout)
        guard let target else {
            lastClickedSurfaceID = nil
            updatePaneFocusDecorations()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.focusRelayPane(surfaceID: target, forwardToHost: forwardToHost)
        }
    }

    @MainActor
    private func updatePaneFocusDecorations() {
        for (sid, slot) in panesBySurfaceID {
            slot.view.wantsLayer = true
            if sid == lastClickedSurfaceID {
                slot.view.layer?.borderWidth = 2
                slot.view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            } else {
                slot.view.layer?.borderWidth = 0
                slot.view.layer?.borderColor = NSColor.clear.cgColor
            }
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
        return firstSurfaceID(in: currentLayout)
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
        // Resolve each missing leaf's spawn inputs on the actor before
        // fanning out (findPane / makeEmptyPaneStub read controller state).
        let spawnInputs: [(Data, Termmesh_Peer_V1_WorkspacePane, Termmesh_Peer_V1_SurfaceInfo?)] =
            missingSurfaceIDs.map { sid in
                (sid,
                 findPane(for: sid, in: layout) ?? makeEmptyPaneStub(surfaceID: sid),
                 surfaceInfoByID[sid])
            }

        // P1: spawn missing slots in parallel with a small concurrency cap
        // so an N-pane workspace pays ~max(per-pane) instead of the
        // sequential sum (the slow per-pane handshake/attach/accept
        // round-trips overlap at their await points). Partial-failure
        // tolerant: a single pane's failure is logged + that leaf left
        // unspawned (the next layout push retries it), never rolling back
        // the panes that did come up. Each child stores its slot on the
        // MainActor via `spawnAndStore`, so no non-Sendable PaneSlot
        // crosses a task boundary.
        if !spawnInputs.isEmpty {
            let maxConcurrent = min(4, spawnInputs.count)
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func submitNext() {
                    let (sid, pane, info) = spawnInputs[next]
                    next += 1
                    group.addTask {
                        await self.spawnAndStore(surfaceID: sid, pane: pane, surfaceInfo: info)
                    }
                }
                while next < maxConcurrent { submitNext() }
                for await _ in group {
                    if next < spawnInputs.count { submitNext() }
                }
            }
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
        await MainActor.run { self.restoreRelayFocus(after: layout, forwardToHost: false) }

        // Tear down slots only when the surface is gone from EVERY
        // pane's tab list — keeping cached slots for inactive tabs of
        // the same bonsplit pane lets a tab-switch reuse the existing
        // PeerRelaySession + ghostty surface instead of paying the
        // handshake / fork / snapshot cost on every click.
        let liveSurfaceIDs = collectAllLiveSurfaceIDs(layout)
        let toRemove = Set(panesBySurfaceID.keys).subtracting(liveSurfaceIDs)
        for sid in toRemove {
            if let slot = panesBySurfaceID.removeValue(forKey: sid) {
                Self.relaySurfacesByID.removeValue(forKey: sid)
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
                let m = peerWorkspaceMinPane(forExtent: extent)
                let position = max(m, min(extent - m, extent * CGFloat(split.dividerPosition)))
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

        // Any layout swap implicitly restores the split tree. Drop any
        // stale zoom marker so a subsequent Cmd+Shift+Enter zooms-in
        // again from a clean state instead of trying to "exit zoom".
        zoomedSurfaceID = nil
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
            let m = peerWorkspaceMinPane(forExtent: extent)
            let position = max(m, min(extent - m, extent * fraction))
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

        // Sidebar — 160 pt left column, 1 pt separator, then split tree.
        let model = sidebarModel ?? PeerRelayWorkspaceSidebarModel()
        if sidebarModel == nil { sidebarModel = model }
        let sidebarView = PeerRelayWorkspaceSidebarView(model: model)
        let hosting = NSHostingView(rootView: sidebarView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.sidebarHostingView = hosting

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

        split.addSubview(hosting)
        split.addSubview(separator)
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

            // Sidebar column.
            hosting.topAnchor.constraint(equalTo: split.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            hosting.widthAnchor.constraint(equalToConstant: 160),

            // 1 pt separator.
            separator.topAnchor.constraint(equalTo: split.topAnchor),
            separator.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: hosting.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            // Terminal area.
            splitContent.topAnchor.constraint(equalTo: split.topAnchor),
            splitContent.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            splitContent.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            splitContent.trailingAnchor.constraint(equalTo: split.trailingAnchor),

            // Overlay covers the whole split area (including sidebar).
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
        try? await session.requestSetDivider(workspaceID: workspaceID, splitID: splitID, ratio: ratio)
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

    // MARK: - Sidebar workspace list

    private func fetchWorkspaces() {
        workspaceFetchTask?.cancel()
        workspaceFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: self.hostSockPath)
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    workspaces = try await conn.session.listWorkspaces()
                } catch {
                    await conn.cancel()
                    return
                }
                await conn.cancel()
                let summaries = workspaces.map {
                    PeerRelayWorkspaceSummary(
                        id: $0.workspaceID,
                        title: $0.title.isEmpty ? "<workspace>" : $0.title,
                        windowID: $0.windowID,
                        windowTitle: $0.windowTitle
                    )
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.sidebarModel?.workspaces = summaries
                    self.sidebarModel?.selectedID = self.workspaceID
                }
            } catch {
                // Host not reachable — sidebar stays with initial entry.
            }
        }
    }

    private func switchToWorkspace(_ ws: PeerRelayWorkspaceSummary) {
        guard ws.id != workspaceID else { return }
        sidebarModel?.selectedID = ws.id
        workspaceTitle = ws.title
        baseTitle = "Peer Workspace · \(ws.title)"
        window?.title = baseTitle
        workspaceID = ws.id
        tearDownPeerSessions(keepWindow: true)
        showRelayOverlay(title: "Switching workspace", detail: ws.title)
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
                await MainActor.run { self.hideRelayOverlay() }
            } catch {
                let detail = String(describing: error)
                await MainActor.run { [weak self] in
                    self?.showRelayOverlay(
                        title: "Switch failed",
                        detail: detail,
                        actionTitle: "Close"
                    ) { self?.window?.performClose(nil) }
                }
            }
        }
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

    /// Build the relay session for one pane. Prefers the shared
    /// subscription session (P1 — one handshake per workspace, PtyData
    /// de-multiplexed by surface_id); on ANY shared-path failure it falls
    /// back to the classic per-pane connect + attach so a single flaky
    /// attach never blocks the pane from coming up and the proven
    /// single-session path stays intact. The shared session only exists
    /// after `startSubscription` runs, so the initial layout's panes take
    /// the fallback while later splits share.
    private func makePaneSession(
        for surface: Termmesh_Peer_V1_SurfaceInfo
    ) async throws -> PeerRelaySession {
        if let sharedSession = subscriptionSession, let demux = subscriptionDemux {
            do {
                return try await PeerRelaySession.attachShared(
                    sharedSession: sharedSession,
                    demux: demux,
                    hostSockPath: hostSockPath,
                    hostDisplayName: hostDisplayName ?? "",
                    surface: surface
                )
            } catch {
                NSLog("[peer-ws] shared attach failed, falling back to per-pane: %@",
                      String(describing: error))
            }
        }
        let conn = try await PeerRelaySession.connect(hostSockPath: hostSockPath)
        do {
            return try await PeerRelaySession.attach(conn, surface: surface)
        } catch {
            await conn.cancel()
            throw error
        }
    }

    /// Fan-out child body: spawn a pane's slot (tolerant) and, on success,
    /// store it. Runs on the MainActor (inherited isolation), so the
    /// `panesBySurfaceID` mutation is serialised with its siblings and the
    /// PaneSlot never crosses a task boundary.
    private func spawnAndStore(
        surfaceID: Data,
        pane: Termmesh_Peer_V1_WorkspacePane,
        surfaceInfo: Termmesh_Peer_V1_SurfaceInfo?
    ) async {
        if let slot = await spawnPaneSlotTolerant(pane, surfaceInfo: surfaceInfo) {
            panesBySurfaceID[surfaceID] = slot
            Self.relaySurfacesByID[surfaceID] = slot.surface
        }
    }

    /// `spawnPaneSlot` wrapped for parallel fan-out: retry once, then log
    /// and give up (returns nil) so one failed pane cannot abort its
    /// siblings' spawns or the layout pass. `spawnPaneSlot` only throws
    /// before it creates the TerminalSurface (from `makePaneSession` /
    /// `prepareListener`), and cleans up the session it built on that
    /// path, so a retry starts from a clean slate with nothing leaked.
    private func spawnPaneSlotTolerant(
        _ pane: Termmesh_Peer_V1_WorkspacePane,
        surfaceInfo: Termmesh_Peer_V1_SurfaceInfo?
    ) async -> PaneSlot? {
        do {
            return try await spawnPaneSlot(pane, surfaceInfo: surfaceInfo)
        } catch {
            NSLog("[peer-ws] pane spawn failed, retrying once: %@", String(describing: error))
        }
        do {
            return try await spawnPaneSlot(pane, surfaceInfo: surfaceInfo)
        } catch {
            NSLog("[peer-ws] pane spawn failed after retry, leaving leaf unspawned: %@",
                  String(describing: error))
            return nil
        }
    }

    private func spawnPaneSlot(
        _ pane: Termmesh_Peer_V1_WorkspacePane,
        surfaceInfo: Termmesh_Peer_V1_SurfaceInfo?
    ) async throws -> PaneSlot {
        let chosen = surfaceInfo ?? makeFallbackSurfaceInfo(from: pane)
        let session = try await makePaneSession(for: chosen)
        // P6 (Q2): on the workspace path `onDisconnect` was an orphan
        // callback — nothing assigned it, so a per-pane relay hiccup
        // (this pane's local relay socket/pump failing while the shared
        // subscription session and sibling panes stay healthy) left zero
        // trace. dlog-only ground truth; deliberately NOT wired to
        // `bannerPresenter` — that banner is tunnel/workspace-scoped, and
        // firing it for one pane's local relay failure would misreport a
        // full disconnect.
        #if DEBUG
        session.onDisconnect = {
            dlog("relay.pane.disconnect surface=\(Self.shortSurfaceID(pane.surfaceID)) kind=workspace")
        }
        #endif
        do {
            try session.prepareListener()
        } catch {
            // Clean up the session we just built so a shared attach doesn't
            // leave a dangling demux registration (or an owned session its
            // heartbeat/transport) behind on a listener-setup failure.
            await session.stop()
            throw error
        }

        let surface = await MainActor.run {
            TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
                configTemplate: nil,
                command: session.relayLaunchCommand,
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

    private func firstSurfaceID(in layout: Termmesh_Peer_V1_WorkspaceLayout) -> Data? {
        switch layout.node {
        case .pane(let p): return p.surfaceID
        case .split(let s):
            return firstSurfaceID(in: s.first) ?? firstSurfaceID(in: s.second)
        case .none: return nil
        }
    }

    private static func shortSurfaceID(_ id: Data) -> String {
        id.prefix(5).map { String(format: "%02x", $0) }.joined()
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
