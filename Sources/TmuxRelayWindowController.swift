// Phase 1.1 — NSWindow that mirrors a remote tmux window's full pane tree.
//
// The controller is the orchestrator: it talks to term-meshd over JSON-RPC
// to attach + list panes + attach extras + get layout, then builds an
// NSSplitView tree where every leaf hosts one Ghostty surface driven by
// `term-meshd-tmux-relay` in secondary mode (`TERMMESH_TMUX_SURFACE_ID`).
//
// Cmd+D triggers a remote `split-pane` against the focused surface and
// polls the layout briefly so the new pane appears as soon as tmux acks.

import AppKit
#if DEBUG
import Bonsplit
#endif

@MainActor
final class TmuxRelayWindowController: NSWindowController, NSWindowDelegate {
    private let sshHost: String
    private let tmuxSession: String
    private let daemonSocket: String

    /// surface_id (primary or attach_pane result) → managed terminal surface.
    private var surfaces: [String: TerminalSurface] = [:]
    /// surface_id → tmux pane id (e.g. `%1`). Required so split/kill RPCs
    /// can target the focused pane without re-walking list_panes.
    private var paneIds: [String: String] = [:]
    /// pane_index (0-based within window, from `#{pane_index}`) →
    /// surface_id. Useful for "find a surface by its slot number"
    /// queries, but the LAYOUT TREE leaves do not key by this.
    private var paneIndexToSurface: [Int: String] = [:]
    /// tmux pane id NUMBER (the `N` in `%N`) → surface_id. This is
    /// what `LayoutNode::Pane.paneIndex` actually carries — the layout
    /// string from tmux encodes the pane's globally-unique id, not the
    /// per-window pane_index. Wiring leaf nodes goes through this map.
    private var paneIdNumberToSurface: [Int: String] = [:]
    /// Primary surface = the active pane at attach time. Anchors the
    /// SSH/tmux session lifecycle; closing the window detaches it.
    private var primarySurfaceId: String?

    /// Container that swaps between the spinner and the live layout.
    private let rootContainer = NSView()
    private var loadingLabel: NSTextField?
    private var statusLabel: NSTextField?
    /// Last applied layout signature — skips redundant rebuilds when
    /// poll-after-split arrives with identical content.
    private var layoutSignature: String?
    /// File descriptor of the long-lived `multiplexer.tmux.events` stream.
    /// Stored so `windowWillClose` can shutdown the socket from the main
    /// actor and unblock the reader task's `read(2)` call.
    private var eventStreamFd: Int32 = -1
    /// Window-scoped NSEvent monitors. Cmd+D / click tracking live here
    /// instead of `PaneHostView.performKeyEquivalent` because (a) the
    /// app-wide shortcut monitor in `AppDelegate` runs first and (b)
    /// depth-first responder traversal would hit the leftmost pane
    /// rather than the focused one.
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// surface_id of whichever pane the user last clicked. Trusted over
    /// `window.firstResponder` because Ghostty's surface view doesn't
    /// always propagate focus changes on first click.
    private var lastClickedSurfaceId: String?
    /// Debounce token for `windowDidResize` → `pushClientResize`. Replaced
    /// on every frame of an interactive drag so only the final pause
    /// reaches tmux.
    private var windowResizeWorkItem: DispatchWorkItem?
    private var layoutRefreshInFlight = false
    private var layoutRefreshPending = false

    init(host: String, session: String, daemonSocket: String) {
        self.sshHost = host
        self.tmuxSession = session
        self.daemonSocket = daemonSocket

        let window = TmuxRelayWindowController.makeWindow(
            title: "tmux · \(session) @ \(host)"
        )
        super.init(window: window)
        window.delegate = self
        window.contentView = rootContainer
        showLoading(message: "Connecting to \(host)…")
        Task { [weak self] in await self?.bootstrap() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: window)
        windowResizeWorkItem?.cancel()
        windowResizeWorkItem = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        // Tear down the event stream first so its reader task exits before
        // the controller is deallocated.
        if eventStreamFd >= 0 {
            Darwin.shutdown(eventStreamFd, SHUT_RDWR)
            Darwin.close(eventStreamFd)
            eventStreamFd = -1
        }
        // TerminalSurface.deinit owns PTY teardown; the relay process exits
        // when its stdin/stdout pipes close. Best-effort detach so the
        // daemon-side backend can release its SSH connection.
        if let primary = primarySurfaceId {
            Task.detached { [primary] in
                _ = TermMeshDaemon.shared.rpcCallRaw(
                    method: "multiplexer.tmux.detach",
                    params: ["surface_id": primary]
                )
            }
        }
    }

    // ── Bootstrap orchestration ───────────────────────────────────────────

    private func bootstrap() async {
        let host = sshHost
        let session = tmuxSession
        let initialSize = currentCellSize()

        // Heavy lifting (sync RPCs) goes off the main actor.
        let result: BootstrapResult = await Task.detached(priority: .userInitiated) {
            let daemon = TermMeshDaemon.shared
            guard let attach = daemon.tmuxAttach(
                host: host,
                session: session,
                cols: initialSize.cols,
                rows: initialSize.rows,
                createIfMissing: false
            ) else {
                return .failure("tmux attach failed — is the daemon running?")
            }
            let panes = daemon.tmuxListPanes(surfaceId: attach.surfaceId) ?? []
            guard !panes.isEmpty else {
                return .failure("session has no panes")
            }
            // Primary = whichever pane the daemon bound to attach.surfaceId.
            // attach_surface_with_options prefers the active pane, so we
            // mirror that choice here for the UI.
            let primaryPane = panes.first(where: { $0.active }) ?? panes[0]
            var paneBindings: [(pane: TermMeshDaemon.TmuxPaneInfo, surfaceId: String)] = [
                (primaryPane, attach.surfaceId)
            ]
            for pane in panes where pane.paneId != primaryPane.paneId {
                // Use the pane's actual width/height as reported by
                // list-panes — every secondary relay's first SIGWINCH will
                // refine it to the local Ghostty surface size, but starting
                // from each pane's real geometry avoids forcing tmux to
                // briefly resize every pane to the placeholder 220x50 and
                // then snap back. The mismatch window was the root cause
                // of the leftmost-column shift seen in the relay screenshot.
                if let newId = daemon.tmuxAttachPane(
                    surfaceId: attach.surfaceId,
                    paneId: pane.paneId,
                    cols: pane.width,
                    rows: pane.height
                ) {
                    paneBindings.append((pane, newId))
                }
            }
            let layout = daemon.tmuxGetLayout(surfaceId: attach.surfaceId)
            return .success(BootstrapData(
                primaryPaneId: primaryPane.paneId,
                bindings: paneBindings,
                layout: layout
            ))
        }.value

        switch result {
        case .failure(let message):
            showError(message: message)
        case .success(let data):
            applyBootstrap(data)
        }
    }

    private func applyBootstrap(_ data: BootstrapData) {
        // Mint surfaces for every binding (primary + extras).
        for binding in data.bindings {
            let surface = makeRelaySurface(surfaceId: binding.surfaceId)
            surfaces[binding.surfaceId] = surface
            paneIds[binding.surfaceId] = binding.pane.paneId
            paneIndexToSurface[binding.pane.paneIndex] = binding.surfaceId
            if let idNum = Self.paneIdNumber(from: binding.pane.paneId) {
                paneIdNumberToSurface[idNum] = binding.surfaceId
            }
        }
        primarySurfaceId = data.bindings.first?.surfaceId

        let liveView: NSView
        if let layout = data.layout {
            if let split = buildLayoutView(layout) {
                #if DEBUG
                dlog("tmux.relay.applyBootstrap path=split bindings=\(data.bindings.count) layout=\(layoutSignature(of: layout))")
                #endif
                liveView = split
            } else {
                #if DEBUG
                dlog("tmux.relay.applyBootstrap path=fallback reason=buildLayoutView-nil bindings=\(data.bindings.count) layout=\(layoutSignature(of: layout))")
                #endif
                liveView = fallbackStackView()
            }
        } else {
            #if DEBUG
            dlog("tmux.relay.applyBootstrap path=fallback reason=no-layout bindings=\(data.bindings.count)")
            #endif
            liveView = fallbackStackView()
        }
        swapContent(to: liveView)
        focusFirstAvailableSurface()
        installEventMonitors()
        installWindowResizeObserver()
        startEventStream()
        // Sync tmux to whatever cell size the window currently shows so
        // captured seed + live %output land at the same width as Ghostty
        // surfaces. Without this the per-pane relays paint pre-resize
        // content into post-resize PTYs and lose the leftmost column.
        pushClientResize()
        #if DEBUG
        // Dump the post-layout frame tree so we can diagnose split/
        // distribution issues without taking a screenshot. Wait one run
        // loop turn so autolayout finishes its first pass.
        DispatchQueue.main.async { [weak self] in
            self?.dumpLayoutFrames(liveView, depth: 0)
        }
        #endif
    }

    #if DEBUG
    private func dumpLayoutFrames(_ view: NSView, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let cls = String(describing: type(of: view))
        let frame = view.frame
        let frameStr = "\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
        var extra = ""
        if let pane = view as? PaneHostView { extra = " surface=\(pane.surfaceId.prefix(8))" }
        if let stack = view as? NSStackView {
            extra = " stack orient=\(stack.orientation == .horizontal ? "H" : "V") dist=\(stack.distribution.rawValue) spacing=\(stack.spacing) arranged=\(stack.arrangedSubviews.count)"
        }
        if let split = view as? NSSplitView {
            extra = " split vertical=\(split.isVertical) subviews=\(split.subviews.count)"
        }
        dlog("tmux.relay.frame \(indent)\(cls) \(frameStr)\(extra)")
        for sub in view.subviews {
            dumpLayoutFrames(sub, depth: depth + 1)
        }
    }
    #endif

    private func installWindowResizeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResizeNotification(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    @objc private func windowDidResizeNotification(_ note: Notification) {
        // Coalesce rapid drags: NSWindow fires didResize every frame
        // during a live drag. We only want to talk to tmux once when
        // the user pauses. A 60 ms debounce is short enough to feel
        // responsive but long enough to skip per-frame chatter.
        windowResizeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.pushClientResize() }
        windowResizeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.060, execute: item)
    }

    /// Compute the window's content area in tmux cells and push it to the
    /// daemon as a single `refresh-client -C cols x rows`. This is the
    /// only place that resizes tmux post-bootstrap — secondary relays
    /// intentionally no longer push their own PTY sizes (which raced in
    /// vertical layouts and caused per-pane mis-sizing).
    private func pushClientResize() {
        guard let primary = primarySurfaceId,
              let contentRect = window?.contentLayoutRect else { return }
        // Cell-size heuristic. Ghostty's default font (SF Mono 13pt at
        // 1.0 backing scale) measures ~8.0 × 17.0 pt per cell. Erring on
        // the slightly-smaller side leaves a couple of unused pixels on
        // the edges instead of clipping content.
        let cellW: CGFloat = 8.0
        let cellH: CGFloat = 17.0
        let cols = UInt16(max(20, Int(contentRect.width / cellW)))
        let rows = UInt16(max(5, Int(contentRect.height / cellH)))
        Task.detached { [primary, cols, rows] in
            _ = TermMeshDaemon.shared.tmuxResizeClient(
                surfaceId: primary,
                cols: cols,
                rows: rows
            )
        }
    }

    /// Install window-local NSEvent monitors for Cmd+D and click-focus
    /// tracking. Local monitors run only while this window is key, so
    /// shortcuts in other windows are unaffected.
    private func installEventMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  event.modifierFlags.contains(.command),
                  event.window === window
            else { return event }
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let shift = event.modifierFlags.contains(.shift)
            if chars == "d" {
                let direction = shift ? "vertical" : "horizontal"
                if let sid = self.focusedSurfaceId(),
                   self.handleSplitCommand(surfaceId: sid, direction: direction) {
                    return nil
                }
            }
            return event
        }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  let contentView = window.contentView
            else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            guard let hit = contentView.hitTest(point) else { return event }
            // Walk up to the nearest PaneHostView and remember its surface_id.
            var view: NSView? = hit
            while let v = view {
                if let host = v as? PaneHostView {
                    self.lastClickedSurfaceId = host.surfaceId
                    break
                }
                view = v.superview
            }
            return event
        }
    }

    /// Open the long-lived `multiplexer.tmux.events` JSONL stream and
    /// dispatch `layout-change` notifications to `refreshLayout` on the
    /// main actor. Replaces the 200 ms poll-after-Cmd-D fallback and
    /// also picks up splits triggered outside of term-mesh (e.g. the
    /// user running `tmux split-window` over plain SSH).
    private func startEventStream() {
        guard let primary = primarySurfaceId else { return }
        #if DEBUG
        dlog("tmux.relay.eventStream.open surfaceId=\(primary)")
        #endif
        let socketPath = daemonSocket
        Task.detached(priority: .userInitiated) { [weak self, primary, socketPath] in
            let fd = TmuxRelayWindowController.connectUnixSocket(path: socketPath)
            guard fd >= 0 else {
                #if DEBUG
                dlog("tmux.relay.eventStream.lagged reason=connect-failed")
                dlog("tmux.relay.eventStream.closed")
                #endif
                return
            }
            // Hand the fd back to the main actor so windowWillClose can
            // shutdown the socket and unblock our read loop.
            await MainActor.run { [weak self] in self?.eventStreamFd = fd }

            let request = "{\"id\":1,\"method\":\"multiplexer.tmux.events\",\"params\":{\"surface_id\":\"\(primary)\"}}\n"
            guard let reqData = request.data(using: .utf8),
                  TmuxRelayWindowController.writeFully(fd: fd, data: reqData) else {
                #if DEBUG
                dlog("tmux.relay.eventStream.lagged reason=write-failed")
                dlog("tmux.relay.eventStream.closed")
                #endif
                Darwin.close(fd)
                return
            }

            var buffer = Data()
            var tmp = [UInt8](repeating: 0, count: 4096)
            readLoop: while true {
                let n = tmp.withUnsafeMutableBufferPointer { ptr -> Int in
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { break }
                buffer.append(tmp, count: n)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        #if DEBUG
                        dlog("tmux.relay.eventStream.lagged reason=json-parse-failed")
                        #endif
                        continue
                    }
                    // The first line is the ACK from the daemon — { "id": 1, "result": { ... } }.
                    // Skip anything without a `kind` field.
                    guard let kind = obj["kind"] as? String else { continue }
                    if kind == "layout-change" {
                        let tree = obj["tree"]
                        let treeNonNil = tree != nil && !(tree is NSNull)
                        #if DEBUG
                        dlog("tmux.relay.layoutChange.received treeNonNil=\(treeNonNil)")
                        #endif
                        await MainActor.run { [weak self] in self?.refreshLayout() }
                    } else if kind == "warning" {
                        let reason = obj["msg"] as? String ?? "warning"
                        #if DEBUG
                        dlog("tmux.relay.eventStream.lagged reason=\(reason)")
                        #endif
                    }
                    // `keepalive` / `warning` frames are intentionally ignored.
                }
            }
            #if DEBUG
            dlog("tmux.relay.eventStream.closed")
            #endif
        }
    }

    /// Re-fetch the layout (after a split or any topology change) and
    /// rebuild the NSSplitView tree. Surfaces for newly discovered panes
    /// are attached via `tmuxAttachPane`; surfaces for now-missing panes
    /// are torn down. Called manually after Cmd+D; later tied to
    /// `%layout-change` (Phase 1.2).
    private func refreshLayout() {
        #if DEBUG
        dlog("tmux.relay.refresh.enter inFlight=\(layoutRefreshInFlight)")
        #endif
        if layoutRefreshInFlight {
            layoutRefreshPending = true
            #if DEBUG
            dlog("tmux.relay.refresh.exit reason=skipped-inflight pending=true")
            #endif
            return
        }
        guard let primary = primarySurfaceId else {
            #if DEBUG
            dlog("tmux.relay.refresh.exit reason=no-primary")
            #endif
            return
        }
        layoutRefreshInFlight = true
        let initialSize = currentCellSize()
        // Snapshot known pane ids on the main actor so the detached task
        // does not need to read `self`'s state mid-flight.
        let knownPaneIds = Set(paneIds.values)

        Task.detached(priority: .userInitiated) { [primary, initialSize, knownPaneIds, weak self] in
            let daemon = TermMeshDaemon.shared
            guard let panes = daemon.tmuxListPanes(surfaceId: primary) else {
                await MainActor.run { [weak self] in
                    self?.finishRefresh(reason: "list_panes-failed")
                }
                return
            }
            let layout = daemon.tmuxGetLayout(surfaceId: primary)
            var exitReason = layout == nil ? "get_layout-failed" : "success"
            var newBindings: [(pane: TermMeshDaemon.TmuxPaneInfo, surfaceId: String)] = []
            for pane in panes where !knownPaneIds.contains(pane.paneId) {
                #if DEBUG
                dlog("tmux.relay.attach.request paneId=\(pane.paneId) cells=\(initialSize.cols)x\(initialSize.rows)")
                #endif
                let newId = daemon.tmuxAttachPane(
                    surfaceId: primary,
                    paneId: pane.paneId,
                    cols: initialSize.cols,
                    rows: initialSize.rows
                )
                #if DEBUG
                let errorString = newId == nil ? "rpcCall-nil" : "none"
                dlog("tmux.relay.attach.response newSurfaceId=\(newId ?? "nil") error=\(errorString)")
                #endif
                if let newId {
                    newBindings.append((pane, newId))
                } else {
                    exitReason = "attach_pane-failed"
                }
            }
            let panesCopy = panes
            let layoutCopy = layout
            let bindingsCopy = newBindings
            let finalExitReason = exitReason
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyRefresh(
                    panes: panesCopy,
                    layout: layoutCopy,
                    newBindings: bindingsCopy
                )
                self.finishRefresh(reason: finalExitReason)
            }
        }
    }

    private func finishRefresh(reason: String) {
        #if DEBUG
        dlog("tmux.relay.refresh.exit reason=\(reason)")
        #endif
        layoutRefreshInFlight = false
        if layoutRefreshPending {
            layoutRefreshPending = false
            #if DEBUG
            dlog("tmux.relay.refresh.replay reason=pending-after-inflight")
            #endif
            refreshLayout()
        }
    }

    private func applyRefresh(
        panes: [TermMeshDaemon.TmuxPaneInfo],
        layout: TermMeshDaemon.TmuxLayoutNode?,
        newBindings: [(pane: TermMeshDaemon.TmuxPaneInfo, surfaceId: String)]
    ) {
        for binding in newBindings {
            let surface = makeRelaySurface(surfaceId: binding.surfaceId)
            surfaces[binding.surfaceId] = surface
            paneIds[binding.surfaceId] = binding.pane.paneId
            paneIndexToSurface[binding.pane.paneIndex] = binding.surfaceId
            if let idNum = Self.paneIdNumber(from: binding.pane.paneId) {
                paneIdNumberToSurface[idNum] = binding.surfaceId
            }
        }

        // Drop surfaces for panes that no longer exist remotely.
        let liveIndices = Set(panes.map { $0.paneIndex })
        let stalePaneIndices = paneIndexToSurface.keys.filter { !liveIndices.contains($0) }
        for idx in stalePaneIndices {
            if let sid = paneIndexToSurface.removeValue(forKey: idx) {
                surfaces.removeValue(forKey: sid)
                if let removedPaneId = paneIds.removeValue(forKey: sid),
                   let idNum = Self.paneIdNumber(from: removedPaneId) {
                    paneIdNumberToSurface.removeValue(forKey: idNum)
                }
            }
        }

        guard let layout else { return }
        let signature = layoutSignature(of: layout)
        if signature == layoutSignature {
            #if DEBUG
            dlog("tmux.relay.applyRefresh path=early-return-no-changes newPaneCount=\(panes.count) bindingsCount=\(newBindings.count)")
            #endif
            return
        }
        layoutSignature = signature

        let builtView = buildLayoutView(layout)
        let path = builtView == nil ? "buildLayoutView-nil-fallback" : "ok"
        #if DEBUG
        dlog("tmux.relay.applyRefresh path=\(path) newPaneCount=\(panes.count) bindingsCount=\(newBindings.count)")
        #endif
        let view = builtView ?? fallbackStackView()
        swapContent(to: view)
    }

    private func makeRelaySurface(surfaceId: String) -> TerminalSurface {
        let relayBinary = TmuxRelayWindowController.findRelayBinary() ?? "/bin/sh"
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: nil,
            command: relayBinary,
            environment: [
                "TERMMESH_DAEMON_UNIX_PATH": daemonSocket,
                "TERMMESH_TMUX_HOST": sshHost,
                "TERMMESH_TMUX_SESSION": tmuxSession,
                "TERMMESH_TMUX_SURFACE_ID": surfaceId,
            ]
        )
    }

    // ── Layout → NSSplitView ──────────────────────────────────────────────

    /// Extract `N` from a tmux pane id of the form `%N`. Returns nil if
    /// the input doesn't start with `%` or the suffix isn't an integer.
    /// The layout-string parser emits the same integer as `paneIndex` on
    /// leaf nodes (tmux encodes pane id, not pane_index, in its layout
    /// dump), so this is how we bridge the two namespaces.
    fileprivate static func paneIdNumber(from paneId: String) -> Int? {
        guard paneId.hasPrefix("%") else { return nil }
        return Int(paneId.dropFirst())
    }

    private func buildLayoutView(_ node: TermMeshDaemon.TmuxLayoutNode) -> NSView? {
        switch node.kind {
        case .pane:
            // `node.paneIndex` is misnamed — it actually carries the tmux
            // pane id NUMBER (the `N` in `%N`), not the per-window index.
            // Look up via the pane-id-number map populated at bootstrap.
            guard let idNum = node.paneIndex,
                  let sid = paneIdNumberToSurface[idNum],
                  let surface = surfaces[sid] else { return nil }
            return PaneHostView(surfaceId: sid, controller: self, content: surface.hostedView)
        case .horizontal:
            return makeSplit(isVertical: true, children: node.children)
        case .vertical:
            return makeSplit(isVertical: false, children: node.children)
        }
    }

    private func makeSplit(isVertical: Bool, children: [TermMeshDaemon.TmuxLayoutNode]) -> NSView? {
        let leaves = children.compactMap { buildLayoutView($0) }
        guard !leaves.isEmpty else { return nil }
        // Use NSStackView instead of NSSplitView. NSSplitView's behaviour
        // with programmatically-added subviews is brittle in nested layouts:
        // it inconsistently distributes space, especially when the inner
        // split is itself an arranged subview of an outer one (the user's
        // 4-column screenshot with a missing vertical-stacked column was
        // exactly this case). NSStackView with .fillEqually distributes
        // arranged subviews predictably via autolayout, supports nesting
        // cleanly, and gives us a non-zero `spacing` we can colour as a
        // divider via the PaneHostView border. Phase 1.1 does not need
        // interactive divider drag — that arrives in 1.2+.
        //
        // tmux `Horizontal` = panes side-by-side → NSStackView.horizontal
        // tmux `Vertical`   = panes top-to-bottom → NSStackView.vertical
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = isVertical ? .horizontal : .vertical
        stack.distribution = .fillEqually
        stack.spacing = 1
        for leaf in leaves {
            stack.addArrangedSubview(leaf)
            // `fillEqually` divides space along the stack's main axis only.
            // Without an explicit constraint, each arranged subview shrinks
            // along the perpendicular axis to its intrinsic content size —
            // which for PaneHostView is `noIntrinsicMetric`, i.e. 0. The
            // user-visible symptom is panes collapsing to the leading edge
            // and pretending to vanish. Pin both perpendicular edges so
            // every leaf fills the stack's cross axis.
            if isVertical {
                // horizontal stack: leaves stretch vertically
                NSLayoutConstraint.activate([
                    leaf.topAnchor.constraint(equalTo: stack.topAnchor),
                    leaf.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
                ])
            } else {
                // vertical stack: leaves stretch horizontally
                NSLayoutConstraint.activate([
                    leaf.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                    leaf.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                ])
            }
        }
        return stack
    }

    /// Used when the layout RPC fails — show every surface stacked
    /// vertically so the user at least gets I/O.
    private func fallbackStackView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (sid, surface) in surfaces {
            let host = PaneHostView(surfaceId: sid, controller: self, content: surface.hostedView)
            stack.addArrangedSubview(host)
        }
        return stack
    }

    /// Stable string that changes whenever the layout topology changes.
    private func layoutSignature(of node: TermMeshDaemon.TmuxLayoutNode) -> String {
        switch node.kind {
        case .pane:
            return "P\(node.paneIndex ?? -1)"
        case .horizontal:
            return "H[\(node.children.map(layoutSignature(of:)).joined(separator: ","))]"
        case .vertical:
            return "V[\(node.children.map(layoutSignature(of:)).joined(separator: ","))]"
        }
    }

    // ── Container view swapping ───────────────────────────────────────────

    private func showLoading(message: String) {
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13)
        loadingLabel = label
        swapContent(to: label, centered: true)
    }

    private func showError(message: String) {
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .systemRed
        statusLabel = label
        swapContent(to: label, centered: true)
    }

    private func swapContent(to view: NSView, centered: Bool = false) {
        for sub in rootContainer.subviews { sub.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(view)
        if centered {
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: rootContainer.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: rootContainer.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: rootContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            ])
        }
    }

    // ── Focus / Cmd+D ─────────────────────────────────────────────────────

    fileprivate func focusedSurfaceId() -> String? {
        // Click-tracked focus is the authoritative source — Ghostty surfaces
        // do not always promote themselves to firstResponder on first click
        // (NSView.window.firstResponder lags behind the user's intent).
        if let sid = lastClickedSurfaceId, surfaces[sid] != nil {
            return sid
        }
        if let responder = window?.firstResponder as? NSView {
            var view: NSView? = responder
            while let v = view {
                if let host = v as? PaneHostView { return host.surfaceId }
                view = v.superview
            }
        }
        return primarySurfaceId
    }

    fileprivate func surfaceIdFor(paneIndex: Int) -> String? {
        paneIndexToSurface[paneIndex]
    }

    /// Cmd+D entry point — called from `PaneHostView.performKeyEquivalent`.
    /// Returns true if the key was consumed.
    fileprivate func handleSplitCommand(surfaceId: String, direction: String) -> Bool {
        let targetPaneId = paneIds[surfaceId]
        #if DEBUG
        dlog("tmux.relay.split.dispatch dir=\(direction) focusedSurfaceId=\(focusedSurfaceId() ?? "nil") targetPaneId=\(targetPaneId ?? "nil")")
        #endif
        guard let primary = primarySurfaceId,
              let paneId = targetPaneId else {
            #if DEBUG
            dlog("tmux.relay.rpc.response ok=false error=missing-primary-or-pane")
            #endif
            return false
        }
        #if DEBUG
        dlog("tmux.relay.rpc.request method=control action=split-pane pane=\(paneId) dir=\(direction)")
        #endif
        let ok = TermMeshDaemon.shared.tmuxControl(
            surfaceId: primary,
            command: "split-pane",
            paneId: paneId,
            direction: direction
        )
        #if DEBUG
        let errorString = ok ? "none" : "rpcCall-nil"
        dlog("tmux.relay.rpc.response ok=\(ok) error=\(errorString)")
        #endif
        // Layout refresh is driven by the `multiplexer.tmux.events` stream:
        // tmux fires %layout-change right after split-window completes and
        // the daemon broadcasts it on `notify_tx`. No explicit polling.
        return ok
    }

    private func focusFirstAvailableSurface() {
        guard let sid = primarySurfaceId,
              let surface = surfaces[sid] else { return }
        window?.makeFirstResponder(surface.hostedView)
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private func currentCellSize() -> (cols: UInt16, rows: UInt16) {
        // Pre-bootstrap we don't have a Ghostty surface yet, so use a sane
        // initial size matched against the window's content rect (~80x24
        // cell baseline at 10pt). The first SIGWINCH from the relay
        // refines it instantly.
        return (220, 50)
    }

    private static func makeWindow(title: String) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    /// Search for term-meshd-tmux-relay binary in development and bundled locations.
    static func findRelayBinary() -> String? {
        let fm = FileManager.default

        // Development: daemon workspace relative to the Swift source file.
        let srcFile = URL(fileURLWithPath: #file)
        let devPath = srcFile
            .deletingLastPathComponent()          // Sources/
            .deletingLastPathComponent()          // project root
            .appendingPathComponent("daemon/target/release/term-meshd-tmux-relay")
            .path

        // Bundled locations (for app distribution).
        let bundlePath = Bundle.main.bundlePath
        let candidates = [
            devPath,
            bundlePath + "/Contents/Resources/bin/term-meshd-tmux-relay",
            bundlePath + "/Contents/MacOS/term-meshd-tmux-relay",
            "/usr/local/bin/term-meshd-tmux-relay",
        ]

        return candidates.first { fm.fileExists(atPath: $0) && fm.isExecutableFile(atPath: $0) }
    }

    /// Open an AF_UNIX SOCK_STREAM connection to the daemon socket.
    /// Returns the connected fd, or -1 on any failure (path too long,
    /// connect denied, etc.). Used by the event stream reader task.
    nonisolated static func connectUnixSocket(path: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let sunCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= sunCapacity else {
            Darwin.close(fd)
            return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    /// Write every byte of `data` to `fd`, retrying on partial writes.
    /// Returns false on any I/O failure. Matches the framing expectation
    /// of the JSON-RPC dispatcher (one full line per request).
    nonisolated static func writeFully(fd: Int32, data: Data) -> Bool {
        var written = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    /// Best-effort daemon socket path resolution. Same chain as before so
    /// tagged builds still find their isolated socket.
    static func detectDaemonSocket() -> String {
        if let p = ProcessInfo.processInfo.environment["TERMMESH_DAEMON_UNIX_PATH"], !p.isEmpty {
            return p
        }
        if let p = ProcessInfo.processInfo.environment["TERMMESH_DAEMON_SOCKET"], !p.isEmpty {
            return p
        }
        if let raw = getenv("TERMMESH_DAEMON_UNIX_PATH") {
            let s = String(cString: raw)
            if !s.isEmpty { return s }
        }

        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/term-mesh")
            .path
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: appSupport) {
            let socks = entries
                .filter { $0.hasPrefix("term-meshd-") && $0.hasSuffix(".sock") }
                .map { "\(appSupport)/\($0)" }
                .filter { FileManager.default.fileExists(atPath: $0) }
            if let tag = ProcessInfo.processInfo.environment["TERMMESH_TAG"], !tag.isEmpty {
                if let match = socks.first(where: { $0.contains("-\(tag).sock") }) {
                    return match
                }
            }
            let newest = socks.sorted { lhs, rhs in
                let l = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let r = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return l > r
            }.first
            if let s = newest { return s }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let standard = home + "/.local/share/term-mesh/term-meshd.sock"
        if FileManager.default.fileExists(atPath: standard) { return standard }
        return "/tmp/term-meshd.sock"
    }
}

// MARK: - Bootstrap data

private enum BootstrapResult {
    case success(BootstrapData)
    case failure(String)
}

private struct BootstrapData {
    let primaryPaneId: String
    let bindings: [(pane: TermMeshDaemon.TmuxPaneInfo, surfaceId: String)]
    let layout: TermMeshDaemon.TmuxLayoutNode?
}

// MARK: - PaneHostView (Cmd+D / focus tracking)

/// Thin NSView wrapper around each leaf. The wrapper itself is purely
/// structural — Cmd+D handling lives on the window-level NSEvent monitor
/// in `TmuxRelayWindowController.installEventMonitors`, and click-based
/// focus tracking inspects the responder chain looking for this view.
private final class PaneHostView: NSView {
    let surfaceId: String
    private weak var controller: TmuxRelayWindowController?

    init(surfaceId: String, controller: TmuxRelayWindowController, content: NSView) {
        self.surfaceId = surfaceId
        self.controller = controller
        super.init(frame: .zero)
        // Use autoresizing-mask sizing throughout so NSSplitView can drive
        // frames directly without fighting autolayout. The outer leaf in
        // makeSplit has the same policy. Mixing autolayout here would
        // re-introduce the divider-hiding regression.
        autoresizesSubviews = true
        // Always-on subtle border so the user can see pane boundaries
        // even when `.paneSplitter` draws a near-invisible thin grey
        // line on top of Ghostty's black background. Kept narrow (1px)
        // and dim so it doesn't compete with terminal content.
        wantsLayer = true
        layer?.borderColor = NSColor(white: 0.30, alpha: 1.0).cgColor
        layer?.borderWidth = 1.0
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - TmuxMenu

enum TmuxMenu {
    static func connectItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Linux Tmux…",
            action: #selector(TmuxMenuCoordinator.promptAndConnect(_:)),
            keyEquivalent: ""
        )
        item.target = TmuxMenuCoordinator.shared
        return item
    }
}

// MARK: - TmuxMenuCoordinator

/// Coordinates the "Connect to Linux Tmux…" menu action.
final class TmuxMenuCoordinator: NSObject {
    static let shared = TmuxMenuCoordinator()
    private static let lastHostKey = "termMeshTmuxLastHost"
    private static let lastSessionKey = "termMeshTmuxLastSession"
    private static let shellOptions = ["Default", "/bin/bash", "/bin/zsh", "/bin/sh"]

    private var openControllers: [TmuxRelayWindowController] = []

    @MainActor
    @objc func promptAndConnect(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Linux Tmux"
        alert.informativeText = "Enter the SSH host and tmux session name.\nRequires term-meshd to be running."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 100))
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.alignment = .leading

        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        hostField.placeholderString = "SSH host (e.g. ubuntu@192.168.1.10)"
        hostField.stringValue = Self.lastHostValue()

        let sessionField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        sessionField.placeholderString = "tmux session name (e.g. main)"
        sessionField.stringValue = Self.lastSessionValue()

        let createStack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        createStack.orientation = .horizontal
        createStack.spacing = 10
        createStack.alignment = .centerY

        let createSessionButton = NSButton(checkboxWithTitle: "Create if missing", target: nil, action: nil)
        createSessionButton.state = .on

        let shellPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 145, height: 26), pullsDown: false)
        shellPopup.addItems(withTitles: Self.shellOptions)
        shellPopup.selectItem(at: 0)

        createStack.addArrangedSubview(createSessionButton)
        createStack.addArrangedSubview(shellPopup)

        stackView.addArrangedSubview(hostField)
        stackView.addArrangedSubview(sessionField)
        stackView.addArrangedSubview(createStack)
        alert.accessoryView = stackView

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = sessionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !session.isEmpty else { return }
        let shouldCreateSession = createSessionButton.state == .on
        let selectedShell = Self.selectedShell(from: shellPopup)

        Task { [weak self] in
            if shouldCreateSession,
               let failure = await Self.ensureSessionExists(host: host, session: session, shell: selectedShell) {
                Self.showSessionCreateFailure(session: session, failure: failure)
                return
            }
            self?.openRelay(host: host, session: session)
        }
    }

    @MainActor
    private func openRelay(host: String, session: String) {
        UserDefaults.standard.set(host, forKey: Self.lastHostKey)
        UserDefaults.standard.set(session, forKey: Self.lastSessionKey)

        let daemonSocket = TermMeshDaemon.shared.socketPath
        let controller = TmuxRelayWindowController(host: host, session: session, daemonSocket: daemonSocket)
        openControllers.append(controller)
        controller.show()
    }

    private static func lastHostValue() -> String {
        UserDefaults.standard.string(forKey: lastHostKey)
            ?? ProcessInfo.processInfo.environment["TERMMESH_TMUX_HOST"]
            ?? ""
    }

    private static func lastSessionValue() -> String {
        UserDefaults.standard.string(forKey: lastSessionKey)
            ?? ProcessInfo.processInfo.environment["TERMMESH_TMUX_SESSION"]
            ?? ""
    }

    private static func selectedShell(from popup: NSPopUpButton) -> String? {
        guard popup.indexOfSelectedItem > 0 else { return nil }
        let title = popup.titleOfSelectedItem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    private static func ensureSessionExists(host: String, session: String, shell: String?) async -> SSHResult? {
        let check = await runSSHCommand(
            host: host,
            command: "tmux has-session -t \(shellQuote(session))",
            timeout: 6
        )
        if check.exitCode == 0 && !check.timedOut {
            return nil
        }

        var command = "tmux new-session -d -s \(shellQuote(session))"
        if let shell {
            command += " -- \(shellQuote(shell))"
        }
        let create = await runSSHCommand(host: host, command: command, timeout: 8)
        if create.exitCode == 0 && !create.timedOut {
            return nil
        }
        return create
    }

    @MainActor
    private static func showSessionCreateFailure(session: String, failure: SSHResult) {
        let detail = failure.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.messageText = "Could not create tmux session \(session)"
        alert.informativeText = detail.isEmpty
            ? "tmux new-session failed on the remote host."
            : detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private struct SSHResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static func runSSHCommand(host: String, command: String, timeout: TimeInterval) async -> SSHResult {
        await Task.detached(priority: .userInitiated) {
            guard !host.hasPrefix("-") else {
                return SSHResult(exitCode: 64, stdout: "", stderr: "invalid host", timedOut: false)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                host,
                command,
            ]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return SSHResult(exitCode: 127, stdout: "", stderr: String(describing: error), timedOut: false)
            }

            let deadline = Date().addingTimeInterval(timeout)
            var timedOut = false
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }

            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return SSHResult(
                exitCode: timedOut ? 124 : process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                timedOut: timedOut
            )
        }.value
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
