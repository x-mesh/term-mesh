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

@MainActor
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
    private var workspaceID: Data
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
    private var startTask: Task<Void, Never>?
    private var isClosing = false

    var onClose: (@MainActor () -> Void)?

    // MARK: - Init

    init(hostSockPath: String, workspace: Termmesh_Peer_V1_Workspace) {
        self.hostSockPath = hostSockPath
        self.workspaceID = workspace.workspaceID
        self.currentLayout = workspace.layout

        let initialSize = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let window = PeerRelayWorkspaceWindow(
            contentRect: initialSize,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let title = workspace.title.isEmpty ? "<workspace>" : workspace.title
        window.title = "Peer Workspace · \(title)"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.applyLayout(self.currentLayout)
                await self.startSubscription()
            } catch {
                NSLog("[peer-ws] initial layout failed: %@", String(describing: error))
                await MainActor.run { self.window?.performClose(nil) }
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
            default:
                return event
            }
        }

        // Track which pane the user last clicked. Ghostty surfaces
        // embedded in our NSSplitView don't always promote themselves
        // to firstResponder reliably, so we record focus on mouse
        // down and consult that first when dispatching shortcuts.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window
            else { return event }
            let point = event.locationInWindow
            for (sid, slot) in self.panesBySurfaceID {
                let frameInWindow = slot.view.convert(slot.view.bounds, to: nil)
                if frameInWindow.contains(point) {
                    self.lastClickedSurfaceID = sid
                    break
                }
            }
            return event
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
        // Spawn missing slots first (async, may take time per pane).
        for surfaceID in newSurfaceIDs where panesBySurfaceID[surfaceID] == nil {
            let pane = findPane(for: surfaceID, in: layout) ?? makeEmptyPaneStub(surfaceID: surfaceID)
            let slot = try await spawnPaneSlot(pane)
            panesBySurfaceID[surfaceID] = slot
        }

        // Build the new view tree on the main actor.
        let (newRoot, dividers) = await MainActor.run { () -> (NSView, [(NSSplitView, CGFloat)]) in
            self.pendingDividerSetters.removeAll()
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
        let container = window.contentView ?? NSView(frame: window.contentLayoutRect)
        for sub in container.subviews { sub.removeFromSuperview() }
        newRoot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(newRoot)
        NSLayoutConstraint.activate([
            newRoot.topAnchor.constraint(equalTo: container.topAnchor),
            newRoot.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            newRoot.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            newRoot.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        if window.contentView == nil {
            window.contentView = container
        }
        container.layoutSubtreeIfNeeded()
        for (split, fraction) in dividers {
            let extent: CGFloat = split.isVertical ? split.bounds.width : split.bounds.height
            guard extent > 0 else { continue }
            let position = max(20, min(extent - 20, extent * fraction))
            split.setPosition(position, ofDividerAt: 0)
        }
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
            return nsSplit
        case .none:
            return NSView()
        }
    }

    // MARK: - Slot factory

    private func spawnPaneSlot(_ pane: Termmesh_Peer_V1_WorkspacePane) async throws -> PaneSlot {
        let conn = try await PeerRelaySession.connectAndList(hostSockPath: hostSockPath)
        let chosen = conn.surfaces.first(where: { $0.surfaceID == pane.surfaceID })
                        ?? makeFallbackSurfaceInfo(from: pane)
        let session = try await PeerRelaySession.attach(conn, surface: chosen)
        try session.prepareListener()

        let surface = await MainActor.run {
            TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
                configTemplate: nil,
                command: session.relayBinaryPath,
                environment: ["TERMMESH_PEER_RELAY_SOCKET": session.relaySockPath]
            )
        }

        let wrapper = await MainActor.run { () -> NSView in
            let host = surface.hostedView
            host.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: wrap.topAnchor),
                host.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            ])
            return wrap
        }

        Task {
            do { try await session.start() }
            catch { NSLog("[peer-relay] workspace pane start failed: %@", String(describing: error)) }
        }

        return PaneSlot(surfaceID: pane.surfaceID, session: session, surface: surface, view: wrapper)
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
