// Phase C-3c.3.3b: bridges the app's live Ghostty terminal panes into the
// PeerServer's PeerSurfaceProvider abstraction.
//
// Surface enumeration: TabManager → Workspace.panels → TerminalPanel.surface
// (TerminalSurface) → ghostty_surface_t.
//
// Input forwarding: ghostty_surface_text() on MainActor.
// Output tapping:   ghostty_surface_set_pty_data_callback() registers a C
//                   callback that yields raw PTY bytes into an AsyncStream.
//                   The callback is invoked on Ghostty's IO reader thread
//                   under renderer_state.mutex, so it must be non-blocking.
//
// Memory contract:
//   • attach() retains a PtyTapContext (strong ref keeps TerminalSurface alive)
//   • detach() clears the C callback then releases the context
//   • If the surface is freed before detach: TerminalSurface.deinit clears the
//     C callback and then ghostty_surface_free proceeds safely; the context is
//     released by the detach closure when the PeerServer eventually calls it.

import AppKit
import Bonsplit
import PeerProto

// MARK: - C callback (top-level; @convention(c) cannot capture)

private func ptyTapCallback(
    userdata: UnsafeMutableRawPointer?,
    data: UnsafePointer<UInt8>?,
    len: UInt
) {
    guard let userdata, let data, len > 0 else { return }
    let hub = Unmanaged<PtyTapHub>.fromOpaque(userdata).takeUnretainedValue()
    hub.broadcast(Data(bytes: data, count: Int(len)))
}

// MARK: - PtyTapHub

/// One Ghostty PTY callback per surface, fan-out to bounded per-peer streams.
final class PtyTapHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    let surfaceID: UUID
    let surfacePtr: ghostty_surface_t
    // Strong reference prevents TerminalSurface.deinit during active relay.
    // Nulled by shutdown() when the panel closes to release the surface.
    private var surfaceRef: TerminalSurface?

    init(surfaceID: UUID, surfacePtr: ghostty_surface_t, surfaceRef: TerminalSurface) {
        self.surfaceID = surfaceID
        self.surfacePtr = surfacePtr
        self.surfaceRef = surfaceRef
    }

    /// Call when the backing panel closes (not on normal peer detach).
    /// Finishes all streams and drops the TerminalSurface strong reference.
    func shutdown() {
        finishAll()
        surfaceRef = nil
    }

    deinit {
        #if DEBUG
        dlog("deinit \(Self.self)")
        #endif
    }

    func makeStream(initialBytes: Data?) -> (UUID, AsyncStream<Data>) {
        let attachID = UUID()
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            lock.lock()
            continuations[attachID] = continuation
            lock.unlock()
            if let initialBytes {
                continuation.yield(initialBytes)
            }
        }
        return (attachID, stream)
    }

    func broadcast(_ bytes: Data) {
        // Yield directly under the lock — `AsyncStream.Continuation.yield`
        // with `bufferingNewest(256)` is a non-blocking enqueue into a
        // bounded ring buffer, so holding the lock for the duration is
        // bounded by N × O(1) rather than waiting on consumers. Avoids
        // the per-chunk `Array(continuations.values)` allocation that
        // showed up on tail-following workloads (cat /dev/urandom etc.)
        // where the PTY callback fires thousands of times per second.
        lock.lock()
        for continuation in continuations.values {
            continuation.yield(bytes)
        }
        lock.unlock()
    }

    @discardableResult
    func finish(attachID: UUID) -> Bool {
        lock.lock()
        let continuation = continuations.removeValue(forKey: attachID)
        let isEmpty = continuations.isEmpty
        lock.unlock()
        continuation?.finish()
        return isEmpty
    }

    func finishAll() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }
}

// MARK: - GhosttyPaneSurfaceProvider

/// PeerSurfaceProvider backed by the app's live terminal panes.
/// Conformance to PeerSurfaceProvider (which requires Sendable) is valid
/// because @MainActor isolation makes the class's state consistent.
@MainActor
final class GhosttyPaneSurfaceProvider: PeerSurfaceProvider {
    private var tapHubs: [UUID: PtyTapHub] = [:]

    /// Called when a terminal panel closes. Shuts down the hub (finishes all
    /// peer streams + drops TerminalSurface ref) without waiting for peer detach.
    func invalidateTapHub(forSurfaceId surfaceId: UUID) {
        guard let hub = tapHubs.removeValue(forKey: surfaceId) else { return }
        hub.shutdown()
        #if DEBUG
        dlog("tapHub.invalidate surfaceId=\(surfaceId.uuidString.prefix(8))")
        #endif
    }

    // MARK: PeerSurfaceProvider

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] {
        // Background panes have a lazy `ghostty_surface_t` — newly opened
        // splits / non-active tabs may not have one yet. Kick lazy init
        // for any unready pane and wait briefly so the next collect
        // picks them up. Without this the latest split is silently
        // dropped from the picker.
        await MainActor.run { kickLazySurfaceStarts() }
        for _ in 0..<10 {
            if await MainActor.run(body: { allSurfacesReady() }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms × 10 = ≤300 ms
        }
        return await MainActor.run { collectSurfaces() }
    }

    func listWorkspaces() async -> [Termmesh_Peer_V1_Workspace] {
        await MainActor.run { kickLazySurfaceStarts() }
        for _ in 0..<10 {
            if await MainActor.run(body: { allSurfacesReady() }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await MainActor.run { collectWorkspaces() }
    }

    func handleWorkspaceControl(_ control: Termmesh_Peer_V1_WorkspaceControl) async {
        await MainActor.run { applyWorkspaceControl(control) }
    }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32
    ) async -> PeerSurfaceAttachment? {
        guard let (sfcPtr, ts) = findSurface(id: surfaceID)
        else { return nil }

        // Send a snapshot of the current viewport so the relay window
        // shows existing content immediately instead of starting blank.
        // Yielded before the callback is registered so it's guaranteed
        // to land before any new PTY bytes. ANSI styling is lost (text
        // only); fullscreen TUIs (vim, less, htop) won't redraw without
        // SIGWINCH and require manual refresh.
        let snapshot = readPaneSnapshot(sfcPtr)

        let hub: PtyTapHub
        if let existing = tapHubs[ts.id] {
            hub = existing
        } else {
            hub = PtyTapHub(surfaceID: ts.id, surfacePtr: sfcPtr, surfaceRef: ts)
            tapHubs[ts.id] = hub
            // Register the C tap under renderer_state.mutex in Ghostty.
            let hubPtr = Unmanaged.passUnretained(hub).toOpaque()
            ghostty_surface_set_pty_data_callback(sfcPtr, ptyTapCallback, hubPtr)
        }
        let (attachID, stream) = hub.makeStream(initialBytes: snapshot)

        // Light up the peer-attached ring on the host pane and bump
        // the per-surface ref count so concurrent attaches all share
        // a single visible ring.
        let isFirstAttach = Self.incrementPeerAttach(for: ts)

        // Phase E-6: optional Ctrl-L injection so TUIs repaint with
        // full styling on attach. The plain-text snapshot path above
        // restores content but loses ANSI; sending Ctrl-L makes vim /
        // htop / less redraw correctly. Disabled by default because
        // the redraw is visible to the host's local viewer too.
        //
        // Gate on the 0→1 transition: clients 2..N attaching to the
        // same surface get the redraw bytes via the existing PTY tap
        // (broadcast from the first attach's redraw), so emitting
        // Ctrl-L on every attach would just stack form-feeds and
        // multiply the host's local flicker.
        if isFirstAttach && PeerFederationSettings.forceRedrawOnAttach {
            // Defer briefly so the snapshot lands first; the redraw
            // bytes that come back through the PTY tap will then
            // cleanly overwrite it.
            Task { @MainActor [weak ts] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let ptr = ts?.surface else { return }
                sendPeerInputBytes(ptr, bytes: Data([0x0c]))
            }
        }

        // Capture weak reference to TerminalSurface for input/resize closures;
        // the strong ref lives in PtyTapContext for the lifetime of the attach.
        let weakTS = WeakRef(ts)
        // FIX A: capture key at attach time so the detach closure can clean up
        // peerPendingInputTail even if the TerminalSurface is already freed.
        let sfcPtrKey = UInt(bitPattern: sfcPtr)

        let input: @Sendable (Data) async -> Void = { [weakTS] bytes in
            await MainActor.run {
                guard let ptr = weakTS.value?.surface else { return }
                // Track a weak surface ref so a deferred lone-Escape tail can be
                // flushed later without capturing the raw (non-Sendable) pointer.
                peerSurfaceRefForKey[UInt(bitPattern: ptr)] = weakTS
                sendPeerInputBytes(ptr, bytes: bytes)
            }
        }

        let detach: @Sendable () async -> Void = { [provider = WeakRef(self), weakTS, hub, sfcPtrKey] in
            await MainActor.run {
                let hubEmpty = hub.finish(attachID: attachID)
                if let ts = weakTS.value {
                    GhosttyPaneSurfaceProvider.decrementPeerAttach(for: ts)
                    if hubEmpty {
                        if let ptr = ts.surface {
                            ghostty_surface_clear_pty_data_callback(ptr)
                        }
                        provider.value?.tapHubs.removeValue(forKey: ts.id)
                    }
                }
                // FIX A: release pending escape-sequence tail on last client detach
                // to prevent stale bytes prepending to a future session at the same
                // surface pointer address (OS pointer reuse after surface free).
                if hubEmpty {
                    clearPeerPendingInputTail(surfaceKey: sfcPtrKey)
                }
            }
        }

        let meta: PeerWorkspaceMeta? = nil

        return PeerSurfaceAttachment(
            byteStream: stream,
            input: input,
            resize: { [weakTS] cols, rows in
                await MainActor.run {
                    guard let ptr = weakTS.value?.surface else { return }
                    // ghostty_surface_set_size takes pixel dimensions.
                    // Use current cell size to convert cols×rows → pixels.
                    let curSz = ghostty_surface_size(ptr)
                    if curSz.cell_width_px > 0 && curSz.cell_height_px > 0 {
                        let safeCols = min(cols, 1000)
                        let safeRows = min(rows, 1000)
                        let (w, wOverflow) = safeCols.multipliedReportingOverflow(by: UInt32(curSz.cell_width_px))
                        let (h, hOverflow) = safeRows.multipliedReportingOverflow(by: UInt32(curSz.cell_height_px))
                        guard !wOverflow, !hOverflow else { return }
                        ghostty_surface_set_size(ptr, w, h)
                    }
                }
            },
            workspaceMeta: meta,
            detach: detach
        )
    }

    // MARK: - Workspace control dispatch

    private func applyWorkspaceControl(_ control: Termmesh_Peer_V1_WorkspaceControl) {
        switch control.kind {
        case .splitPane(let req):
            performSplit(paneIDBytes: req.paneID, orientationString: req.orientation)
        case .closePane(let req):
            performClose(paneIDBytes: req.paneID)
        case .focusPane(let req):
            performFocus(paneIDBytes: req.paneID)
        case .setDivider(let req):
            performSetDivider(splitIDBytes: req.splitID, ratio: req.ratio)
        case .newTab(let req):
            performNewTab(paneIDBytes: req.paneID)
        case .activateTab(let req):
            performActivateTab(paneIDBytes: req.paneID, surfaceIDBytes: req.surfaceID)
        case .none:
            break
        }
    }

    /// Phase E-4: switch the active tab inside the bonsplit pane that
    /// hosts `paneIDBytes` to the tab whose surface is
    /// `surfaceIDBytes`. Both arguments are surface_ids; the pane id
    /// is the *current* active surface used as a locator.
    private func performActivateTab(paneIDBytes: Data, surfaceIDBytes: Data) {
        guard let currentSurfaceUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: currentSurfaceUUID),
              let targetSurfaceUUID = uuidFromSurfaceID(surfaceIDBytes),
              let currentTabID = workspace.surfaceIdFromPanelId(currentSurfaceUUID),
              let targetTabID = workspace.surfaceIdFromPanelId(targetSurfaceUUID)
        else { return }
        let targetPaneId = workspace.bonsplitController.allPaneIds.first { paneId in
            workspace.bonsplitController.tabs(inPane: paneId).contains { $0.id == currentTabID }
        }
        guard let targetPaneId,
              workspace.bonsplitController.tabs(inPane: targetPaneId).contains(where: { $0.id == targetTabID })
        else { return }
        workspace.bonsplitController.selectTab(targetTabID)
    }

    private func performNewTab(paneIDBytes: Data) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: panelUUID),
              let tabID = workspace.surfaceIdFromPanelId(panelUUID)
        else { return }
        let targetPaneId = workspace.bonsplitController.allPaneIds.first { paneId in
            workspace.bonsplitController.tabs(inPane: paneId).contains { $0.id == tabID }
        }
        guard let targetPaneId else { return }
        _ = workspace.newTerminalSurface(inPane: targetPaneId, focus: true)
    }

    private func performSetDivider(splitIDBytes: Data, ratio: Double) {
        guard let splitUUID = uuidFromSurfaceID(splitIDBytes) else { return }
        let clamped = CGFloat(max(0.05, min(0.95, ratio)))
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                if workspace.bonsplitController.findSplit(splitUUID) {
                    workspace.bonsplitController.setDividerPosition(
                        clamped,
                        forSplit: splitUUID,
                        fromExternal: false
                    )
                    return
                }
            }
        }
    }

    private func performFocus(paneIDBytes: Data) {
        // A peer client's local focus must not steal keyboard focus on
        // the host app. Split/close/new-tab requests carry their target
        // surface id explicitly, so host-side focus is not needed for
        // correctness.
        _ = paneIDBytes
    }

    private func performSplit(paneIDBytes: Data, orientationString: String) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: panelUUID)
        else { return }
        let orientation: SplitOrientation = (orientationString == "vertical") ? .vertical : .horizontal
        _ = workspace.newTerminalSplit(from: panelUUID, orientation: orientation)
    }

    private func performClose(paneIDBytes: Data) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: panelUUID),
              let panel = workspace.panels[panelUUID]
        else { return }
        // Use bonsplit's pane-id derivation: find the pane that holds
        // the tab whose ID matches this terminal surface, then close it.
        if let tabID = workspace.surfaceIdFromPanelId(panelUUID) {
            for paneId in workspace.bonsplitController.allPaneIds {
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                if tabs.contains(where: { $0.id == tabID }) {
                    _ = workspace.bonsplitController.closeTab(tabID, inPane: paneId)
                    return
                }
            }
        }
        _ = panel  // silence unused
    }

    private func uuidFromSurfaceID(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func workspaceContaining(panelUUID: UUID) -> Workspace? {
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                if workspace.panels[panelUUID] != nil {
                    return workspace
                }
            }
        }
        return nil
    }

    // MARK: - Peer attach indicator

    /// Per-surface attach counter. Lives on the @MainActor-isolated
    /// type so reads/writes serialize with the rest of provider state.
    private static var peerAttachCounts: [UUID: Int] = [:]

    /// Bump the attach counter and update the teal ring + count
    /// badge. Returns `true` when this attach transitioned the surface
    /// from 0 → 1 — i.e. it's the first peer attaching, used by the
    /// caller to decide whether to inject Ctrl-L for TUI redraw.
    @discardableResult
    static func incrementPeerAttach(for ts: TerminalSurface) -> Bool {
        let prev = peerAttachCounts[ts.id] ?? 0
        let next = prev + 1
        peerAttachCounts[ts.id] = next
        ts.hostedView.setPeerRing(visible: true, count: next)
        return prev == 0
    }

    static func decrementPeerAttach(for ts: TerminalSurface) {
        let prev = peerAttachCounts[ts.id] ?? 0
        let next = max(0, prev - 1)
        if next == 0 {
            peerAttachCounts.removeValue(forKey: ts.id)
            ts.hostedView.setPeerRing(visible: false, count: 0)
        } else {
            peerAttachCounts[ts.id] = next
            ts.hostedView.setPeerRing(visible: true, count: next)
        }
    }

    // MARK: - Private helpers

    /// All live main-window contexts, in a deterministic order.
    ///
    /// `AppDelegate.mainWindowContexts` is an unordered dictionary, so it is
    /// sorted by `windowId` to keep the workspace roster the host advertises
    /// to peers stable across repeated `listWorkspaces` fetches (a churning
    /// order would reshuffle the client's picker/sidebar on every refresh).
    /// Each entry carries the owning window's id + title so a workspace can
    /// be tagged with the window it belongs to — the host may have several
    /// top-level windows open, each with its own `TabManager`, and a peer
    /// client should see ALL of them, not just the active one.
    private func allWindowContexts()
        -> [(windowId: UUID, windowTitle: String, tabManager: TabManager)] {
        guard let appDelegate = AppDelegate.shared else { return [] }
        return appDelegate.mainWindowContexts.values
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .map { ctx in (ctx.windowId, windowLabel(for: ctx), ctx.tabManager) }
    }

    /// Best-effort human label for a host window, used by the client to head
    /// the window's section in the workspace picker/sidebar. Derived from the
    /// window's *selected* workspace title rather than `NSWindow.title`,
    /// because the title bar is only kept in sync for the key window — a
    /// background window's `.title` is often empty or stale. Falls back to the
    /// live title, then to "" so the client renders a short window-id suffix.
    /// Snapshot semantics match the other workspace fields: refreshed on each
    /// `listWorkspaces`/layout-change push, not on bare title edits.
    private func windowLabel(for ctx: AppDelegate.MainWindowContext) -> String {
        let mgr = ctx.tabManager
        if let selID = mgr.selectedTabId,
           let ws = mgr.tabs.first(where: { $0.id == selID }) {
            let title = (ws.customTitle ?? ws.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return (ctx.window?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wake up any pane whose `ghostty_surface_t` hasn't been created
    /// yet (newly opened splits, background tabs). Non-blocking — caller
    /// polls `allSurfacesReady` to know when init has settled.
    private func kickLazySurfaceStarts() {
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    let ts = terminal.surface
                    if ts.surface == nil {
                        ts.requestBackgroundSurfaceStartIfNeeded()
                    }
                }
            }
        }
    }

    /// True when every terminal pane has a non-nil `ghostty_surface_t`.
    private func allSurfacesReady() -> Bool {
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    if terminal.surface.surface == nil { return false }
                }
            }
        }
        return true
    }

    private func collectWorkspaces() -> [Termmesh_Peer_V1_Workspace] {
        var result: [Termmesh_Peer_V1_Workspace] = []
        for ctx in allWindowContexts() {
            let windowIDBytes = withUnsafeBytes(of: ctx.windowId.uuid) { Data($0) }
            for workspace in ctx.tabManager.tabs {
                let tree = workspace.bonsplitController.treeSnapshot()
                guard let layout = translateBonsplitNode(tree, workspace: workspace) else {
                    continue
                }
                var ws = Termmesh_Peer_V1_Workspace()
                ws.workspaceID = withUnsafeBytes(of: workspace.id.uuid) { Data($0) }
                ws.title = workspace.customTitle ?? workspace.title
                ws.layout = layout
                ws.windowID = windowIDBytes
                ws.windowTitle = ctx.windowTitle
                result.append(ws)
            }
        }
        return result
    }

    /// Walk a bonsplit `ExternalTreeNode` and produce the corresponding
    /// `WorkspaceLayout` proto. Pane leaves are dereferenced via
    /// `workspace.surfaceIdToPanelId` to find the underlying
    /// TerminalSurface ID — that's the value clients use for
    /// AttachSurface. Non-terminal panes (browsers, panes whose
    /// surface hasn't materialised yet) are dropped; if both children
    /// of a split drop, the split itself is folded out.
    private func translateBonsplitNode(
        _ node: ExternalTreeNode,
        workspace: Workspace
    ) -> Termmesh_Peer_V1_WorkspaceLayout? {
        switch node {
        case .pane(let pane):
            guard let selectedTabIDStr = pane.selectedTabId ?? pane.tabs.first?.id,
                  let tabUUID = UUID(uuidString: selectedTabIDStr),
                  let panelUUID = workspace.surfaceIdToPanelId[TabID(uuid: tabUUID)],
                  let terminal = workspace.panels[panelUUID] as? TerminalPanel,
                  let sfcPtr = terminal.surface.surface
            else { return nil }
            let ts = terminal.surface
            var paneMsg = Termmesh_Peer_V1_WorkspacePane()
            paneMsg.surfaceID = surfaceIDBytes(ts.id)
            paneMsg.title = workspace.panelTitles[terminal.id] ?? "Terminal"
            let sz = ghostty_surface_size(sfcPtr)
            paneMsg.cols = UInt32(sz.columns)
            paneMsg.rows = UInt32(sz.rows)
            if let cwd = workspace.panelDirectories[terminal.id] {
                paneMsg.cwd = cwd
            }
            // Phase E-4: include every tab in this bonsplit pane so
            // the relay window can render a tab strip and let the user
            // switch the active tab via WorkspaceControl.activate_tab.
            paneMsg.tabs = pane.tabs.compactMap { tab -> Termmesh_Peer_V1_PaneTab? in
                guard let tUUID = UUID(uuidString: tab.id),
                      let pUUID = workspace.surfaceIdToPanelId[TabID(uuid: tUUID)],
                      let term = workspace.panels[pUUID] as? TerminalPanel,
                      term.surface.surface != nil
                else { return nil }
                var t = Termmesh_Peer_V1_PaneTab()
                t.surfaceID = surfaceIDBytes(term.surface.id)
                t.title = workspace.panelTitles[term.id] ?? "Terminal"
                return t
            }
            var layout = Termmesh_Peer_V1_WorkspaceLayout()
            layout.pane = paneMsg
            return layout

        case .split(let split):
            let firstChild = translateBonsplitNode(split.first, workspace: workspace)
            let secondChild = translateBonsplitNode(split.second, workspace: workspace)
            // If one side has nothing attachable, fold the split out
            // and surface only the populated child.
            switch (firstChild, secondChild) {
            case (nil, nil):
                return nil
            case (let f?, nil):
                return f
            case (nil, let s?):
                return s
            case (let f?, let s?):
                var splitMsg = Termmesh_Peer_V1_WorkspaceSplit()
                splitMsg.orientation = split.orientation
                splitMsg.dividerPosition = split.dividerPosition
                splitMsg.first = f
                splitMsg.second = s
                if let splitUUID = UUID(uuidString: split.id) {
                    splitMsg.splitID = withUnsafeBytes(of: splitUUID.uuid) { Data($0) }
                }
                var layout = Termmesh_Peer_V1_WorkspaceLayout()
                layout.split = splitMsg
                return layout
            }
        }
    }

    private func collectSurfaces() -> [Termmesh_Peer_V1_SurfaceInfo] {
        var result: [Termmesh_Peer_V1_SurfaceInfo] = []
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    let ts = terminal.surface
                    guard let sfcPtr = ts.surface else { continue }
                    var info = Termmesh_Peer_V1_SurfaceInfo()
                    info.surfaceID = surfaceIDBytes(ts.id)
                    info.title = workspace.panelTitles[terminal.id] ?? "Terminal"
                    info.surfaceType = "terminal"
                    info.attachable = true
                    let sz = ghostty_surface_size(sfcPtr)
                    info.cols = UInt32(sz.columns)
                    info.rows = UInt32(sz.rows)
                    if let cwd = workspace.panelDirectories[terminal.id] {
                        info.cwd = cwd
                    }
                    result.append(info)
                }
            }
        }
        return result
    }

    private func findSurface(id: Data) -> (ghostty_surface_t, TerminalSurface)? {
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    let ts = terminal.surface
                    guard surfaceIDBytes(ts.id) == id else { continue }
                    guard let ptr = ts.surface else { continue }
                    return (ptr, ts)
                }
            }
        }
        return nil
    }
}

// MARK: - Helpers

/// Per-surface carry buffer for trailing incomplete escape sequences.
/// If a TYPE_KEY_INPUT chunk ends with a lone 0x1b (or partial CSI head),
/// we hold those bytes here and prepend them to the next chunk so the
/// sequence isn't split across frame boundaries.
/// Key = surface pointer identity (UInt(bitPattern:)). @MainActor — all
/// accesses happen on the main thread via sendPeerInputBytes.
/// Bound to ≤32 bytes per surface to prevent unbounded growth on malformed input.
@MainActor private var peerPendingInputTail: [UInt: [UInt8]] = [:]
private let peerPendingInputTailMax = 32

/// Generation token per surface for the deferred-tail flush timer. Bumped
/// whenever the pending tail is set or cleared so a stale timer (fired after
/// the tail was already consumed/replaced) becomes a no-op.
@MainActor private var peerPendingTailFlushGen: [UInt: Int] = [:]
/// Weak surface reference per surface key, so schedulePeerPendingTailFlush()
/// can re-fetch the live surface after its timeout WITHOUT capturing the raw
/// `ghostty_surface_t` (OpaquePointer, not Sendable) across an await. Mirrors
/// the attach-time `weakTS.value?.surface` re-fetch pattern.
@MainActor private var peerSurfaceRefForKey: [UInt: WeakRef<TerminalSurface>] = [:]
/// Deferred-tail flush delay. Mirrors the relay's ESC_FLUSH_TIMEOUT_MS (100 ms)
/// plus a little slack for socket jitter, so a lone Escape that has no
/// follow-up keystroke is still delivered promptly instead of hanging until
/// the next key.
private let peerPendingTailFlushDelayNanos: UInt64 = 120_000_000

/// FIX C: Multi-chunk bracketed paste accumulator. When `\e[200~` arrives
/// without a matching `\e[201~` in the same frame, we stash the body bytes
/// here and keep consuming subsequent frames as paste content until the
/// closing marker is seen. Then we flush the buffered body through
/// `ghostty_surface_text` so Ghostty re-wraps in bracketed paste markers
/// for the destination surface (vim/codex/claude see a real paste instead
/// of a stream of keystrokes that triggers autoindent and command-mode
/// shortcuts mid-paste).
///
/// Key = surface pointer identity (UInt(bitPattern:)). @MainActor.
@MainActor private var peerPendingPasteBody: [UInt: Data] = [:]
/// FIX C v2: timestamp of the last byte appended to `peerPendingPasteBody`.
/// Used to detect a stalled paste accumulator (close marker `\e[201~`
/// never arrived — relay dropped it, SSH stalled, user aborted, etc.).
/// Without this safety valve, every subsequent keystroke gets absorbed
/// as paste body and the destination surface becomes unresponsive: even
/// a bare ESC never reaches the next-hop vim, so the user can't escape
/// INSERT mode and `:q!` shows up as literal text. On a stale entry we
/// flush whatever was buffered and resume normal parsing.
@MainActor private var peerPendingPasteTimestamp: [UInt: Date] = [:]
/// Frame-to-frame idle window. Real pastes arrive as a burst (consecutive
/// frames within milliseconds); a gap of this size means the close
/// marker is gone and we should not keep eating keystrokes.
private let peerPendingPasteIdleTimeout: TimeInterval = 0.75
/// Hard cap on accumulated paste body. Exceeding this flushes whatever
/// has been collected so far and drops the rest of the paste; the
/// destination app sees a truncated paste rather than an unbounded buffer.
/// 8 MiB is well above any realistic clipboard payload.
private let peerPendingPasteBodyMax = 8 * 1024 * 1024

/// FIX A: Release any buffered incomplete-escape tail for a peer surface
/// when the last client detaches. Prevents stale bytes from being prepended
/// to a new session if the OS reuses the same surface pointer address.
@MainActor
private func clearPeerPendingInputTail(surfaceKey: UInt) {
    peerPendingInputTail.removeValue(forKey: surfaceKey)
    peerPendingPasteBody.removeValue(forKey: surfaceKey)
    peerPendingPasteTimestamp.removeValue(forKey: surfaceKey)
    // Drop the deferred-tail flush bookkeeping so nothing accumulates for a
    // torn-down surface. An in-flight timer captured its generation by value,
    // so after this removal its `peerPendingTailFlushGen[surfaceKey]` lookup is
    // nil (≠ the captured gen) and it no-ops; the tail-equality guard covers the
    // rare surface-pointer-reuse case.
    peerPendingTailFlushGen.removeValue(forKey: surfaceKey)
    peerSurfaceRefForKey.removeValue(forKey: surfaceKey)
}

/// Schedule a one-shot flush of a deferred lone-Escape / incomplete-escape
/// tail. If, after the timeout, the buffered bytes are unchanged (no follow-up
/// frame completed or replaced them) the tail is delivered as-is via a final
/// pass through `sendPeerInputBytes`. The surface is re-fetched from the weak
/// registry inside the closure, never captured raw across the await.
@MainActor
private func schedulePeerPendingTailFlush(surfaceKey: UInt, tail: [UInt8]) {
    let gen = (peerPendingTailFlushGen[surfaceKey] ?? 0) + 1
    peerPendingTailFlushGen[surfaceKey] = gen
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: peerPendingTailFlushDelayNanos)
        guard peerPendingTailFlushGen[surfaceKey] == gen,
              peerPendingInputTail[surfaceKey] == tail,
              let ptr = peerSurfaceRefForKey[surfaceKey]?.value?.surface else { return }
        sendPeerInputBytes(ptr, bytes: Data(), finalFlush: true)
    }
}

/// FIX C helper: flush accumulated paste body to the destination surface.
@MainActor
private func flushPeerPasteBody(_ surface: ghostty_surface_t, _ body: Data) {
    guard !body.isEmpty else { return }
    body.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress?
            .assumingMemoryBound(to: CChar.self) else { return }
        ghostty_surface_text(surface, base, UInt(rawBuffer.count))
    }
}

/// FIX C helper: consume bytes from `arr` while in paste-accumulate mode.
/// Returns the number of bytes consumed. If the close marker `\e[201~`
/// appears in this chunk, flushes the buffered body and returns the
/// position just past the marker; the caller should resume normal parsing
/// on the remainder. If no close marker is found, consumes the entire
/// chunk into the buffer and returns `arr.count`.
@MainActor
private func absorbPasteContinuation(
    surface: ghostty_surface_t,
    surfaceKey: UInt,
    arr: [UInt8]
) -> Int {
    var closeStart: Int? = nil
    var j = 0
    while j + 5 < arr.count {
        if arr[j] == 0x1b,
           arr[j + 1] == 0x5b,
           arr[j + 2] == 0x32,
           arr[j + 3] == 0x30,
           arr[j + 4] == 0x31,
           arr[j + 5] == 0x7e {
            closeStart = j
            break
        }
        j += 1
    }

    if let close = closeStart {
        var body = peerPendingPasteBody.removeValue(forKey: surfaceKey) ?? Data()
        peerPendingPasteTimestamp.removeValue(forKey: surfaceKey)
        if close > 0 {
            body.append(contentsOf: arr[0..<close])
        }
        flushPeerPasteBody(surface, body)
        return close + 6
    }

    var body = peerPendingPasteBody[surfaceKey] ?? Data()
    body.append(contentsOf: arr)
    if body.count > peerPendingPasteBodyMax {
        flushPeerPasteBody(surface, body)
        peerPendingPasteBody.removeValue(forKey: surfaceKey)
        peerPendingPasteTimestamp.removeValue(forKey: surfaceKey)
    } else {
        peerPendingPasteBody[surfaceKey] = body
        peerPendingPasteTimestamp[surfaceKey] = Date()
    }
    return arr.count
}

/// FIX B: Return the number of trailing bytes in `arr` that form an
/// incomplete ESC-introduced sequence (CSI/OSC/SS3 head split across a frame
/// boundary). Scans backward up to `bound` bytes from the end looking for
/// the rightmost 0x1b; if found and `peerEscapeSequenceLength` returns nil
/// (incomplete), returns the tail length — caller should buffer those bytes.
/// Returns 0 when no incomplete tail is detected.
///
/// Scenarios where tail > 0:
///   - Lone ESC at end            ("\e")        → tailLen 1
///   - Partial CSI head           ("\e[")        → tailLen 2
///   - Partial CSI with params    ("\e[<35")     → tailLen 4+
///   - SS3 missing final byte     ("\eO")        → tailLen 2
///   - OSC without BEL/ST         ("\e]0;txt")   → tailLen varies
///
/// Bound cap: ESC is only searched within the last `bound` bytes, so
/// tailLen ≤ bound. A giant OSC split across >32-byte frames falls through
/// with tailLen = 0 (the leading ESC is beyond the search window) — this
/// matches the pre-FIX-B behavior for that edge case.
private func trailingIncompleteEscape(_ arr: [UInt8], bound: Int) -> Int {
    let start = max(0, arr.count - bound)
    var i = arr.count - 1
    while i >= start {
        if arr[i] == 0x1b {
            let tail = Array(arr[i..<arr.count])
            return peerEscapePrefixCouldComplete(tail) ? arr.count - i : 0
        }
        i -= 1
    }
    return 0
}

/// True when `tail` (which begins with ESC) is a *prefix* of a still-
/// completable escape sequence — i.e. more bytes could turn it into a valid
/// CSI / OSC / SS3. This is the crucial distinction `peerEscapeSequenceLength`
/// alone cannot make: that helper returns nil for BOTH a genuinely incomplete
/// head ("\e[" waiting for a final byte) AND a complete ESC keypress followed
/// by literal input ("\e:" = Escape then ':'). Deferring the latter is the bug
/// behind vim ":wq!" after Escape: the host stashes ESC, then mis-reads
/// ESC+':' / ESC+'w' / … as "still incomplete" and buffers the whole string
/// into `peerPendingInputTail` until 32 bytes accumulate — the surface freezes
/// then releases in a burst. Only genuine prefixes may be deferred here.
private func peerEscapePrefixCouldComplete(_ tail: [UInt8]) -> Bool {
    guard tail.first == 0x1b else { return false }
    // Lone trailing ESC: ambiguous (could begin CSI/OSC/SS3, or be a bare
    // Escape key). Defer; schedulePeerPendingTailFlush() releases it after a
    // short timeout — mirroring the relay's ESC_FLUSH_TIMEOUT_MS — so a real
    // Escape never hangs the remote app in e.g. vim INSERT mode.
    guard tail.count >= 2 else { return true }
    switch tail[1] {
    case 0x5b: // '[' — CSI, completable while body bytes stay in 0x20...0x3f
        for k in 2..<tail.count {
            let b = tail[k]
            if (0x40...0x7e).contains(b) { return false }   // already terminated
            if !(0x20...0x3f).contains(b) { return false }  // invalid CSI body byte
        }
        return true                                          // valid, unterminated
    case 0x5d: // ']' — OSC, completable until BEL (0x07) or ST (ESC '\')
        var k = 2
        while k < tail.count {
            if tail[k] == 0x07 { return false }
            if tail[k] == 0x1b, k + 1 < tail.count, tail[k + 1] == 0x5c { return false }
            k += 1
        }
        return true
    case 0x4f: // 'O' — SS3, needs exactly one final byte
        return tail.count < 3
    default:
        // ESC + a byte that cannot introduce CSI/OSC/SS3 ⇒ a complete Escape
        // keypress immediately followed by literal input. Never defer.
        return false
    }
}

/// Route peer Input bytes into Ghostty as key events.
///
/// All bytes flow through `ghostty_surface_key()`; we deliberately avoid
/// `ghostty_surface_text()` because that path wraps content in bracketed
/// paste markers which (a) breaks Enter / Tab / Ctrl-C semantics in
/// readline-style shells and (b) eats some control bytes before they
/// reach the PTY. Mirroring `GhosttyTerminalView.sendSocketStyleText`:
///
/// - Enter (CR/LF), Tab, Backspace, Escape        → key event with keycode
/// - CSI/SS3 navigation keys and function keys    → key event with keycode
/// - Ctrl-letter control bytes (0x01-0x1A)        → key event + Ctrl mod
/// - Anything else                                 → key event (keycode=0)
///   with the Unicode scalar as text. Multi-byte UTF-8 sequences are
///   grouped into a single scalar before dispatch.
///
/// LF→Return mapping is needed because the relay binary's stdin is a PTY
/// slave with default ICRNL, so Ghostty writes CR but the relay reads
/// LF before forwarding over the peer socket.
#if DEBUG
/// Test-only entry point: route raw bytes through the host peer-relay
/// re-encode path exactly as a connected peer client's Input frame would,
/// without needing a live peer server/relay. Backs the
/// `debug.peer.inject_input` socket command used by the ESC-freeze
/// regression test (`tests_v2/test_peer_input_esc_freeze_regression.py`).
@MainActor
func debugInjectPeerInput(_ surface: ghostty_surface_t, bytes: Data) {
    sendPeerInputBytes(surface, bytes: bytes)
}
#endif

@MainActor
private func sendPeerInputBytes(_ surface: ghostty_surface_t, bytes: Data, finalFlush: Bool = false) {
    // FIX 2 / FIX B: prepend any bytes carried over from the previous chunk,
    // then trim any new incomplete ESC tail before the main parse loop so that
    // split CSI/OSC/SS3 heads ("\e[", "\e[<35", etc.) are also deferred — not
    // just lone trailing ESC (the old FIX 2 scope).
    let surfaceKey = UInt(bitPattern: surface)
    var arr: [UInt8]
    if let pending = peerPendingInputTail.removeValue(forKey: surfaceKey), !pending.isEmpty {
        arr = pending + Array(bytes)
    } else {
        arr = Array(bytes)
    }

    // FIX C: if a previous frame opened a bracketed paste that hasn't been
    // closed yet, this frame's bytes belong to the paste body (until the
    // closing `\e[201~`). Drain those bytes into the accumulator before the
    // normal parser runs. Bytes past the close marker (if any) fall through.
    if let body = peerPendingPasteBody[surfaceKey] {
        // FIX C v2 safety valve: if the previous paste burst ended without
        // ever delivering `\e[201~` and the next frame arrives after a
        // pause, treat the accumulator as stalled. Flush what we have so
        // the user at least gets the leading half of the paste, clear
        // state, and run this frame through the normal parser. Without
        // this, every subsequent keystroke (ESC, `:`, `q`, `!`) gets
        // absorbed into the paste body and the destination surface
        // becomes unresponsive.
        let lastTs = peerPendingPasteTimestamp[surfaceKey]
        let idle = lastTs.map { Date().timeIntervalSince($0) } ?? .infinity
        if idle > peerPendingPasteIdleTimeout {
            flushPeerPasteBody(surface, body)
            peerPendingPasteBody.removeValue(forKey: surfaceKey)
            peerPendingPasteTimestamp.removeValue(forKey: surfaceKey)
            // Fall through to normal parser on this frame.
        } else {
            let consumed = absorbPasteContinuation(
                surface: surface, surfaceKey: surfaceKey, arr: arr)
            if consumed >= arr.count {
                return
            }
            arr = Array(arr[consumed...])
        }
    }

    // FIX B prelude: detect any trailing incomplete escape sequence and buffer
    // it now, before the main loop, so the loop never sees a partial head.
    // On a final flush (timer-driven) treat every byte as processable so a
    // deferred lone Escape / stale escape head is delivered instead of being
    // re-buffered forever.
    let tailLen = finalFlush ? 0 : trailingIncompleteEscape(arr, bound: peerPendingInputTailMax)
    let processCount = arr.count - tailLen
    if tailLen > 0 {
        let tail = Array(arr[processCount...])
        peerPendingInputTail[surfaceKey] = tail
        schedulePeerPendingTailFlush(surfaceKey: surfaceKey, tail: tail)
    }
    var i = 0
    while i < processCount {
        let byte = arr[i]

        if byte == 0x1b,
           let sequence = peerEscapeKeySequence(arr, start: i) {
            sendPeerKeyEvent(surface, keycode: sequence.keycode, mods: sequence.mods, text: nil)
            i += sequence.consumed
            continue
        }

        // Bracketed-paste passthrough. `\e[200~…\e[201~` brackets paste
        // content from the client. The body must reach the next-hop
        // verbatim: raw `\n` / `\r` / ESC bytes get re-encoded as
        // `\e[13;2u` / `\e[27u` when funneled through the surface_key
        // path (kitty / modifyOtherKeys mode), and vim's paste decoder
        // then writes those bytes into the buffer as invisible
        // characters — the user sees only blank lines. Even sending
        // markers + body as a single surface_key text payload loses the
        // first few bytes of body (observed: `\e[200~⏺ R…` → vim sees
        // only `an…`), because Ghostty's text-key handler tries to
        // parse leading ESC sequences as input encodings.
        //
        // Fix: strip the markers and route the inner content through
        // `ghostty_surface_text`, the same API local paste uses. Ghostty
        // re-wraps with `\e[200~…\e[201~` automatically when the remote
        // surface has bracketed-paste mode enabled (set by the
        // next-hop app), so vim still sees a real paste.
        //
        // Stateless across Input frames: only handle the case where
        // both markers land in this chunk. Multi-chunk pastes fall
        // through to the legacy per-byte path — still imperfect but no
        // worse than before this fix.
        if byte == 0x1b,
           i + 5 < arr.count,
           arr[i + 1] == 0x5b,
           arr[i + 2] == 0x32,
           arr[i + 3] == 0x30,
           arr[i + 4] == 0x30,
           arr[i + 5] == 0x7e {
            var closeStart: Int? = nil
            var j = i + 6
            while j + 5 < arr.count {
                if arr[j] == 0x1b,
                   arr[j + 1] == 0x5b,
                   arr[j + 2] == 0x32,
                   arr[j + 3] == 0x30,
                   arr[j + 4] == 0x31,
                   arr[j + 5] == 0x7e {
                    closeStart = j
                    break
                }
                j += 1
            }
            if let close = closeStart {
                let body = Data(arr[(i + 6)..<close])
                if !body.isEmpty {
                    body.withUnsafeBytes { rawBuffer in
                        guard let base = rawBuffer.baseAddress?
                            .assumingMemoryBound(to: CChar.self) else { return }
                        ghostty_surface_text(surface, base, UInt(rawBuffer.count))
                    }
                }
                i = close + 6
                continue
            }
            // FIX C: no close marker in this frame — open the paste
            // accumulator. Everything from `i + 6` to end-of-frame becomes
            // the first slice of the paste body, including any bytes the
            // FIX B prelude stashed as `peerPendingInputTail` (they belong
            // to the paste body, not to a partial escape sequence). The
            // next frame(s) will be funneled through `absorbPasteContinuation`
            // until `\e[201~` arrives.
            var body = Data(arr[(i + 6)..<arr.count])
            if let tail = peerPendingInputTail.removeValue(forKey: surfaceKey),
               !tail.isEmpty {
                body.append(contentsOf: tail)
            }
            if body.count > peerPendingPasteBodyMax {
                flushPeerPasteBody(surface, body)
            } else {
                peerPendingPasteBody[surfaceKey] = body
                peerPendingPasteTimestamp[surfaceKey] = Date()
            }
            return
        }

        // Unrecognized CSI/OSC/SS3/SS2: DROP silently.
        //
        // Sending via sendPeerKeyEvent(text: ESC…) is broken for two reasons:
        //   1. ghostty_surface_key re-encodes the leading ESC byte (kitty mode
        //      → `\e[27u`, legacy → a separate PTY ESC write), corrupting the
        //      next-hop CSI parser and leaving bracketed-paste markers as
        //      literal visible characters in claude/codex/vim.
        //   2. ghostty_surface_text auto-wraps with bracketed-paste markers
        //      when the destination surface has bracketed-paste mode on —
        //      also wrong for arbitrary escape sequences.
        // Drop is the least-bad option until a verbatim-byte-injection API
        // exists in Ghostty. Bracketed-paste bodies are handled by the
        // peerPendingPasteBody path BEFORE this point and are never dropped.
        if byte == 0x1b,
           let consumed = peerEscapeSequenceLength(arr, start: i),
           consumed > 1 {
            i += consumed
            continue
        }

        if let mapping = peerSingleByteKeyMapping(byte) {
            sendPeerKeyEvent(surface, keycode: mapping.keycode, mods: mapping.mods, text: mapping.text)
            i += 1
            continue
        }

        if let kc = peerCtrlLetterKeycode(byte) {
            sendPeerCtrlLetterKey(surface, keycode: kc, byte: byte)
            i += 1
            continue
        }

        // Printable / UTF-8 path. Batch runs of consecutive printable
        // bytes (no escape, no mapped single byte, no Ctrl+letter)
        // into one ghostty_surface_key call rather than firing one
        // event per scalar. Pasting a 10KB chunk of plain text used
        // to walk the renderer state machine ~10000 times; with the
        // batch path it's ~one call per `tokTypeKeyInput` frame
        // sent by the relay.
        let runStart = i
        while i < processCount {
            let bb = arr[i]
            if bb == 0x1b { break }
            if peerSingleByteKeyMapping(bb) != nil { break }
            if peerCtrlLetterKeycode(bb) != nil { break }
            i += 1
        }
        if i > runStart {
            let chunkBytes = Array(arr[runStart..<i])
            if let str = String(bytes: chunkBytes, encoding: .utf8), !str.isEmpty {
                sendPeerKeyEvent(surface, keycode: 0, text: str)
            } else {
                // UTF-8 decode failed mid-paste (rare for typed input
                // but possible if a continuation byte was split
                // across two protocol frames). Fall back to per-scalar
                // best-effort recovery so partial bytes don't get
                // silently dropped.
                for j in runStart..<i {
                    sendPeerKeyEvent(surface, keycode: 0, text: String(UnicodeScalar(arr[j])))
                }
            }
        } else {
            // Defensive: shouldn't happen because at least one of the
            // earlier branches would have matched. Avoid an infinite
            // loop on a degenerate byte by advancing one position.
            i += 1
        }
    }
}

/// Special single bytes that map to a named macOS keycode.
private func peerSingleByteKeyMapping(_ byte: UInt8) -> (keycode: UInt32, mods: ghostty_input_mods_e, text: String)? {
    switch byte {
    // CR → unmodified Return (submit). The host surface's kitty-mode key
    // encoder turns this into a bare \r.
    case 0x0d:        return (36, GHOSTTY_MODS_NONE, "\r")   // kVK_Return
    // LF → Shift+Return (insert newline). The peer-relay binary translates a
    // kitty `CSI 13;2u` (shift+enter) into a bare LF; replaying it as a plain
    // Return would submit instead of inserting a newline. Synthesizing
    // Shift+Return lets the host's kitty-mode encoder regenerate `CSI 13;2u`,
    // which Claude/codex/jupyter interpret as a literal newline. See
    // term-mesh-peer-relay translate_terminal_csi_input (shift+enter → LF).
    case 0x0a:        return (36, GHOSTTY_MODS_SHIFT, "\r")  // kVK_Return + Shift
    case 0x09:        return (0x30, GHOSTTY_MODS_NONE, "\t")    // kVK_Tab
    case 0x7f, 0x08:  return (0x33, GHOSTTY_MODS_NONE, "\u{7f}")// kVK_Delete (Backspace)
    case 0x1b:        return (0x35, GHOSTTY_MODS_NONE, "\u{1b}")// kVK_Escape
    default:          return nil
    }
}

/// Map a Ctrl+letter control byte (0x01-0x1A, excluding bytes already
/// claimed by `peerSingleByteKeyMapping`) to its `kVK_ANSI_*` keycode.
private func peerCtrlLetterKeycode(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 0x01: return 0x00 // Ctrl-A → kVK_ANSI_A
    case 0x02: return 0x0B // Ctrl-B → kVK_ANSI_B
    case 0x03: return 0x08 // Ctrl-C → kVK_ANSI_C
    case 0x04: return 0x02 // Ctrl-D → kVK_ANSI_D
    case 0x05: return 0x0E // Ctrl-E → kVK_ANSI_E
    case 0x06: return 0x03 // Ctrl-F → kVK_ANSI_F
    case 0x07: return 0x05 // Ctrl-G → kVK_ANSI_G
    // 0x08 BS, 0x09 Tab, 0x0a LF — handled above
    case 0x0B: return 0x28 // Ctrl-K → kVK_ANSI_K
    case 0x0C: return 0x25 // Ctrl-L → kVK_ANSI_L
    // 0x0d CR — handled above
    case 0x0E: return 0x2D // Ctrl-N → kVK_ANSI_N
    case 0x0F: return 0x1F // Ctrl-O → kVK_ANSI_O
    case 0x10: return 0x23 // Ctrl-P → kVK_ANSI_P
    case 0x11: return 0x0C // Ctrl-Q → kVK_ANSI_Q
    case 0x12: return 0x0F // Ctrl-R → kVK_ANSI_R
    case 0x13: return 0x01 // Ctrl-S → kVK_ANSI_S
    case 0x14: return 0x11 // Ctrl-T → kVK_ANSI_T
    case 0x15: return 0x20 // Ctrl-U → kVK_ANSI_U
    case 0x16: return 0x09 // Ctrl-V → kVK_ANSI_V
    case 0x17: return 0x0D // Ctrl-W → kVK_ANSI_W
    case 0x18: return 0x07 // Ctrl-X → kVK_ANSI_X
    case 0x19: return 0x10 // Ctrl-Y → kVK_ANSI_Y
    case 0x1A: return 0x06 // Ctrl-Z → kVK_ANSI_Z
    // 0x1b Esc — handled above
    default:   return nil
    }
}

private func peerEscapeKeySequence(
    _ bytes: [UInt8],
    start: Int
) -> (keycode: UInt32, mods: ghostty_input_mods_e, consumed: Int)? {
    guard start + 2 < bytes.count, bytes[start] == 0x1b else { return nil }
    switch bytes[start + 1] {
    case 0x5b: // '[' — CSI
        return peerCsiKeySequence(bytes, start: start)
    case 0x4f: // 'O' — SS3, commonly F1-F4 and Home/End.
        guard let keycode = peerSs3Keycode(bytes[start + 2]) else { return nil }
        return (keycode, GHOSTTY_MODS_NONE, 3)
    default:
        return nil
    }
}

/// Length in bytes of a well-formed ESC-introduced control sequence that
/// begins at `start`. Returns nil when the sequence is incomplete or
/// malformed. Recognized shapes:
///   * CSI:  `\e[` parameters (0x20-0x3F) terminated by 0x40-0x7E
///   * OSC:  `\e]` body terminated by BEL (0x07) or ESC `\` (ST)
///   * SS3:  `\eO` + one final byte (3 bytes total)
/// Used to forward bracketed-paste markers and other unrecognized escape
/// sequences as a single contiguous text payload instead of splitting
/// them across a lone-ESC key event and a printable body.
private func peerEscapeSequenceLength(_ bytes: [UInt8], start: Int) -> Int? {
    guard start + 1 < bytes.count, bytes[start] == 0x1b else { return nil }
    switch bytes[start + 1] {
    case 0x5b: // '[' — CSI
        var i = start + 2
        while i < bytes.count {
            let b = bytes[i]
            if (0x40...0x7e).contains(b) {
                return i - start + 1
            }
            if !(0x20...0x3f).contains(b) {
                return nil
            }
            i += 1
        }
        return nil
    case 0x5d: // ']' — OSC
        var i = start + 2
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x07 {
                return i - start + 1
            }
            if b == 0x1b, i + 1 < bytes.count, bytes[i + 1] == 0x5c {
                return i - start + 2
            }
            i += 1
        }
        return nil
    case 0x4f: // 'O' — SS3
        guard start + 2 < bytes.count else { return nil }
        return 3
    default:
        return nil
    }
}

private func peerCsiKeySequence(
    _ bytes: [UInt8],
    start: Int
) -> (keycode: UInt32, mods: ghostty_input_mods_e, consumed: Int)? {
    let bodyStart = start + 2
    var finalIndex = bodyStart
    while finalIndex < bytes.count {
        let byte = bytes[finalIndex]
        if (0x40...0x7e).contains(byte) { break }
        finalIndex += 1
    }
    guard finalIndex < bytes.count else { return nil }

    let final = bytes[finalIndex]
    let params = peerCsiParams(Array(bytes[bodyStart..<finalIndex]))
    let keycode: UInt32?
    let modifierParam: Int?

    switch final {
    case 0x41, 0x42, 0x43, 0x44, 0x48, 0x46: // A/B/C/D/H/F
        keycode = peerCsiFinalKeycode(final)
        modifierParam = params.dropFirst().first
    case 0x7e: // '~'
        guard let first = params.first else { return nil }
        keycode = peerCsiTildeKeycode(first)
        modifierParam = params.dropFirst().first
    default:
        return nil
    }

    guard let keycode else { return nil }
    return (keycode, peerCsiModifier(modifierParam), finalIndex - start + 1)
}

private func peerCsiParams(_ body: [UInt8]) -> [Int] {
    guard !body.isEmpty else { return [] }
    return body.split(separator: 0x3b, omittingEmptySubsequences: false).compactMap { part in
        guard !part.isEmpty else { return nil }
        var value = 0
        for byte in part {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }
}

private func peerCsiModifier(_ encoded: Int?) -> ghostty_input_mods_e {
    guard let encoded, encoded > 1 else { return GHOSTTY_MODS_NONE }
    let flags = encoded - 1
    var raw = GHOSTTY_MODS_NONE.rawValue
    if (flags & 0b001) != 0 { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if (flags & 0b010) != 0 { raw |= GHOSTTY_MODS_ALT.rawValue }
    if (flags & 0b100) != 0 { raw |= GHOSTTY_MODS_CTRL.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
}

private func peerCsiFinalKeycode(_ final: UInt8) -> UInt32? {
    switch final {
    case 0x41: return 0x7e // Up
    case 0x42: return 0x7d // Down
    case 0x43: return 0x7c // Right
    case 0x44: return 0x7b // Left
    case 0x48: return 0x73 // Home
    case 0x46: return 0x77 // End
    default:   return nil
    }
}

private func peerSs3Keycode(_ final: UInt8) -> UInt32? {
    switch final {
    case 0x41: return 0x7e // Up
    case 0x42: return 0x7d // Down
    case 0x43: return 0x7c // Right
    case 0x44: return 0x7b // Left
    case 0x48: return 0x73 // Home
    case 0x46: return 0x77 // End
    case 0x50: return 0x7a // F1
    case 0x51: return 0x78 // F2
    case 0x52: return 0x63 // F3
    case 0x53: return 0x76 // F4
    default:   return nil
    }
}

private func peerCsiTildeKeycode(_ value: Int) -> UInt32? {
    switch value {
    case 1, 7: return 0x73 // Home
    case 2:    return 0x72 // Insert / Help
    case 3:    return 0x75 // Forward Delete
    case 4, 8: return 0x77 // End
    case 5:    return 0x74 // Page Up
    case 6:    return 0x79 // Page Down
    case 11:   return 0x7a // F1
    case 12:   return 0x78 // F2
    case 13:   return 0x63 // F3
    case 14:   return 0x76 // F4
    case 15:   return 0x60 // F5
    case 17:   return 0x61 // F6
    case 18:   return 0x62 // F7
    case 19:   return 0x64 // F8
    case 20:   return 0x65 // F9
    case 21:   return 0x6d // F10
    case 23:   return 0x67 // F11
    case 24:   return 0x6f // F12
    default:   return nil
    }
}

/// Number of bytes in the UTF-8 sequence whose lead byte is `byte`.
/// Returns 1 for ASCII and for stray continuation bytes.
private func peerUtf8Len(_ byte: UInt8) -> Int {
    if byte < 0x80 { return 1 }
    if byte < 0xC0 { return 1 }
    if byte < 0xE0 { return 2 }
    if byte < 0xF0 { return 3 }
    return 4
}

@MainActor
private func sendPeerKeyEvent(
    _ surface: ghostty_surface_t,
    keycode: UInt32,
    mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
    text: String?
) {
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = GHOSTTY_ACTION_PRESS
    keyEvent.keycode = keycode
    keyEvent.mods = mods
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = 0
    keyEvent.composing = false
    if let text {
        text.withCString { ptr in
            keyEvent.text = ptr
            _ = ghostty_surface_key(surface, keyEvent)
        }
    } else {
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
    }
    keyEvent.action = GHOSTTY_ACTION_RELEASE
    keyEvent.text = nil
    _ = ghostty_surface_key(surface, keyEvent)
}

@MainActor
private func sendPeerCtrlLetterKey(_ surface: ghostty_surface_t, keycode: UInt32, byte: UInt8) {
    // Don't send text for Ctrl+key combos — keycode + mods +
    // unshifted_codepoint are enough for Ghostty's KeyEncoder. Adding
    // the raw control byte as text triggers Kitty-protocol double
    // encoding that leaks CSI-u sequences (e.g. "9;5u") as visible
    // text. Mirrors the de5df7d fix in GhosttyTerminalView's Ctrl
    // fast path.
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = GHOSTTY_ACTION_PRESS
    keyEvent.keycode = keycode
    keyEvent.mods = GHOSTTY_MODS_CTRL
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = UInt32(byte) + 0x60 // 0x03 → 'c'
    keyEvent.composing = false
    keyEvent.text = nil
    _ = ghostty_surface_key(surface, keyEvent)

    keyEvent.action = GHOSTTY_ACTION_RELEASE
    _ = ghostty_surface_key(surface, keyEvent)
}

/// Read the current viewport text via ghostty_surface_read_text and
/// wrap it in an ANSI clear+home prefix so the attaching client sees
/// the host's current screen instead of a blank canvas.
@MainActor
private func readPaneSnapshot(_ surface: ghostty_surface_t) -> Data? {
    let topLeft = ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0, y: 0
    )
    let bottomRight = ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0, y: 0
    )
    let selection = ghostty_selection_s(
        top_left: topLeft,
        bottom_right: bottomRight,
        rectangle: true
    )
    var out = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
    defer { ghostty_surface_free_text(surface, &out) }
    guard let ptr = out.text, out.text_len > 0 else { return nil }

    let raw = Data(bytes: ptr, count: Int(out.text_len))
    // Convert bare LFs to CR+LF so each line lands on column 0 in the
    // remote terminal emulator. Already-CRLF input is left untouched.
    var body = Data()
    body.reserveCapacity(raw.count + 16)
    var prev: UInt8 = 0
    for b in raw {
        if b == 0x0a && prev != 0x0d {
            body.append(0x0d)
        }
        body.append(b)
        prev = b
    }

    var snapshot = Data()
    snapshot.append(contentsOf: [0x1b, 0x5b, 0x32, 0x4a]) // ESC [ 2 J — clear screen
    snapshot.append(contentsOf: [0x1b, 0x5b, 0x48])       // ESC [ H   — cursor home
    snapshot.append(body)
    return snapshot
}

private func surfaceIDBytes(_ id: UUID) -> Data {
    withUnsafeBytes(of: id.uuid) { Data($0) }
}

private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
