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
/// Small NSButton subclass used by the relay window's per-pane tab
/// strip. Carries the host paneID + tab's surfaceID so a click can
/// dispatch ActivateTab without hunting for context.
final class TabStripButton: NSButton {
    var paneID: Data = Data()
    var tabSurfaceID: Data = Data()
    var isActive: Bool = false {
        didSet { applyActiveStyle() }
    }

    convenience init(title: String) {
        self.init(frame: .zero)
        self.title = title
        self.bezelStyle = .recessed
        self.controlSize = .small
        self.font = NSFont.systemFont(ofSize: 11)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.setButtonType(.toggle)
        self.lineBreakMode = .byTruncatingTail
        applyActiveStyle()
    }

    private func applyActiveStyle() {
        // Map "is the host's active tab" onto NSButton state so the
        // built-in recessed style draws the highlighted appearance for
        // the active tab and the muted appearance for others.
        self.state = isActive ? .on : .off
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

    let hostSockPath: String
    /// Held strongly while the controller is alive so the tunnel
    /// auto-restart loop keeps running. nil for non-SSH (direct
    /// unix-socket) sessions.
    private var sshTunnel: PeerSSHTunnel?
    var sshTarget: String? { sshTunnel?.sshTarget }
    /// Wall-clock time the relay window first opened. Used by the
    /// Connections panel to show "Attached <duration>".
    let connectedAt: Date = Date()
    /// Workspace title shown to the host. Mirrors `baseTitle` minus
    /// the "Peer Workspace · " prefix so it can be displayed in lists
    /// without redundancy.
    let workspaceTitle: String
    private var workspaceID: Data
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
    private var isClosing = false

    /// In-window status / error banner. Lives at the top of the content
    /// view; the split tree sits below it. Created lazily on the first
    /// `show*` call so non-SSH sessions never allocate it.
    private var banner: PeerRelayBanner?
    /// True once `ensureBodyStack` has installed the banner and
    /// splitRoot container into the window's contentView.
    private var bodyInstalled = false
    private var splitRootContainer: NSView?

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
            banner?.show(
                kind: .error,
                message: "Disconnected: \(reason)",
                actionTitle: nil,
                dismissable: false
            )
            tearDownPeerSessions(keepWindow: true)
        case .reconnecting(let attempt):
            banner?.show(
                kind: .warning,
                message: "Reconnecting to host (try \(attempt))…",
                actionTitle: nil,
                dismissable: false
            )
        case .up:
            banner?.show(
                kind: .info,
                message: "Re-attaching panes…",
                actionTitle: nil,
                dismissable: false
            )
            // Tunnel just came back. Re-run the initial-attach flow
            // from the same hostSockPath.
            startTask?.cancel()
            startTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.applyLayout(self.currentLayout)
                    await self.startSubscription()
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.banner?.show(
                            kind: .success,
                            message: "Reconnected",
                            actionTitle: nil,
                            dismissable: true
                        )
                        // Auto-dismiss the success banner after 3 s.
                        Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            await MainActor.run { self?.banner?.hide() }
                        }
                    }
                } catch {
                    let detail = String(describing: error)
                    await MainActor.run { [weak self] in
                        self?.banner?.show(
                            kind: .error,
                            message: "Reconnect failed: \(detail)",
                            actionTitle: "Retry",
                            dismissable: false,
                            action: { [weak self] in
                                self?.handleTunnelStateChange(.up)
                            }
                        )
                    }
                }
            }
        case .stopped, .starting:
            break
        }
    }

    private func tearDownPeerSessions(keepWindow: Bool) {
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

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.applyLayout(self.currentLayout)
                await self.startSubscription()
            } catch {
                let detail = String(describing: error)
                NSLog("[peer-ws] initial layout failed: %@", detail)
                await MainActor.run { [weak self] in
                    self?.banner?.show(
                        kind: .error,
                        message: "Failed to attach: \(detail)",
                        actionTitle: "Close",
                        dismissable: false,
                        action: { [weak self] in
                            self?.window?.performClose(nil)
                        }
                    )
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
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
        subscriptionTransport = nil
        let toStop = Array(panesBySurfaceID.values)
        panesBySurfaceID.removeAll()
        Task {
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
            await MainActor.run { self.installKeyMonitor() }

            subscriptionTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    let msg: PeerIncomingMessage
                    do {
                        msg = try await session.receiveNextMessage()
                    } catch {
                        return
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
                    if case .goodbye = msg { return }
                }
            }
        } catch {
            NSLog("[peer-ws] subscription connect failed: %@", String(describing: error))
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
        else { return }
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

    private func applyLayout(_ layout: Termmesh_Peer_V1_WorkspaceLayout) async throws {
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

        // Tear down slots that fell out of the tree.
        let toRemove = Set(panesBySurfaceID.keys).subtracting(newSurfaceIDs)
        for sid in toRemove {
            if let slot = panesBySurfaceID.removeValue(forKey: sid) {
                Task { await slot.session.stop() }
            }
        }
    }

    private func swapRootView(_ newRoot: NSView, dividers: [(NSSplitView, CGFloat)]) {
        guard let window = self.window else { return }
        ensureBodyStack(in: window)
        guard let splitContainer = splitRootContainer else { return }

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
        let split = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        self.splitRootContainer = split

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
            let isActive = tab.surfaceID == pane.surfaceID
            let title = tab.title.isEmpty ? "Terminal" : tab.title
            let btn = TabStripButton(title: title)
            btn.isActive = isActive
            btn.paneID = pane.surfaceID
            btn.tabSurfaceID = tab.surfaceID
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

    private func collectSurfaceIDs(_ layout: Termmesh_Peer_V1_WorkspaceLayout) -> Set<Data> {
        switch layout.node {
        case .pane(let p): return [p.surfaceID]
        case .split(let s):
            return collectSurfaceIDs(s.first).union(collectSurfaceIDs(s.second))
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
