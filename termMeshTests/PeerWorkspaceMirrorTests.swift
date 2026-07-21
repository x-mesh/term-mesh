import XCTest
import Bonsplit
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerWorkspaceMirrorTests: XCTestCase {

    // MARK: - Layout builders

    private func leaf(_ id: UInt8, title: String = "") -> Termmesh_Peer_V1_WorkspaceLayout {
        var pane = Termmesh_Peer_V1_WorkspacePane()
        pane.surfaceID = Data([id])
        pane.title = title
        pane.cols = 80
        pane.rows = 24
        var node = Termmesh_Peer_V1_WorkspaceLayout()
        node.pane = pane
        return node
    }

    private func split(
        _ orientation: String,
        _ ratio: Double,
        id: UInt8,
        _ first: Termmesh_Peer_V1_WorkspaceLayout,
        _ second: Termmesh_Peer_V1_WorkspaceLayout
    ) -> Termmesh_Peer_V1_WorkspaceLayout {
        var s = Termmesh_Peer_V1_WorkspaceSplit()
        s.orientation = orientation
        s.dividerPosition = ratio
        s.splitID = Data([id])
        s.first = first
        s.second = second
        var node = Termmesh_Peer_V1_WorkspaceLayout()
        node.split = s
        return node
    }

    // MARK: - preorderLeaves / shapeHash

    func test_preorderLeaves_ordersDepthFirst() {
        let layout = split("horizontal", 0.5, id: 9,
                           leaf(1),
                           split("vertical", 0.3, id: 8, leaf(2), leaf(3)))
        let leaves = PeerWorkspaceMirrorController.preorderLeaves(layout)
        XCTAssertEqual(leaves.map { $0.surfaceID }, [Data([1]), Data([2]), Data([3])])
        XCTAssertEqual(
            PeerWorkspaceMirrorController.shapeHash(layout),
            "h(p[01],v(p[02],p[03]))"
        )
    }

    // MARK: - layoutsEquivalent

    func test_layoutsEquivalent_titleChangesAreEquivalent() {
        let a = split("horizontal", 0.5, id: 9, leaf(1, title: "old"), leaf(2))
        let b = split("horizontal", 0.5, id: 9, leaf(1, title: "new"), leaf(2))
        XCTAssertTrue(PeerWorkspaceMirrorController.layoutsEquivalent(a, b))
    }

    func test_layoutsEquivalent_dividerBeyondEpsilonDiffers() {
        let a = split("horizontal", 0.50, id: 9, leaf(1), leaf(2))
        let b = split("horizontal", 0.60, id: 9, leaf(1), leaf(2))
        XCTAssertFalse(PeerWorkspaceMirrorController.layoutsEquivalent(a, b))
        let c = split("horizontal", 0.501, id: 9, leaf(1), leaf(2))
        XCTAssertTrue(PeerWorkspaceMirrorController.layoutsEquivalent(a, c))
    }

    func test_layoutsEquivalent_leafSwapDiffers() {
        let a = split("horizontal", 0.5, id: 9, leaf(1), leaf(2))
        let b = split("horizontal", 0.5, id: 9, leaf(2), leaf(1))
        XCTAssertFalse(PeerWorkspaceMirrorController.layoutsEquivalent(a, b))
    }

    // MARK: - isDividerOnlyDelta

    func test_dividerOnlyDelta_positive() {
        let a = split("horizontal", 0.5, id: 9, leaf(1), split("vertical", 0.5, id: 8, leaf(2), leaf(3)))
        let b = split("horizontal", 0.7, id: 9, leaf(1), split("vertical", 0.2, id: 8, leaf(2), leaf(3)))
        XCTAssertTrue(PeerWorkspaceMirrorController.isDividerOnlyDelta(a, b))
    }

    func test_dividerOnlyDelta_structuralChangeIsNot() {
        let a = split("horizontal", 0.5, id: 9, leaf(1), leaf(2))
        let b = split("horizontal", 0.5, id: 9, leaf(1), split("vertical", 0.5, id: 8, leaf(2), leaf(3)))
        XCTAssertFalse(PeerWorkspaceMirrorController.isDividerOnlyDelta(a, b))
    }

    func test_dividerOnlyDelta_activeTabChangeIsNot() {
        // Active-tab switch rewrites the leaf's surface_id — must take
        // the structural path (old panel out, new panel in).
        let a = split("horizontal", 0.5, id: 9, leaf(1), leaf(2))
        let b = split("horizontal", 0.5, id: 9, leaf(1), leaf(4))
        XCTAssertFalse(PeerWorkspaceMirrorController.isDividerOnlyDelta(a, b))
    }

    func test_dividerOnlyDelta_requiresStableSplitIds() {
        // Empty split ids can't drive the fast path's split map.
        var a = split("horizontal", 0.5, id: 9, leaf(1), leaf(2))
        var b = split("horizontal", 0.7, id: 9, leaf(1), leaf(2))
        a.split.splitID = Data()
        b.split.splitID = Data()
        XCTAssertFalse(PeerWorkspaceMirrorController.isDividerOnlyDelta(a, b))
    }

    // MARK: - allTargetLeavesMapped (P2-1: fast-path retry guard)

    func test_allTargetLeavesMapped_trueWhenEveryLeafHasAPanel() {
        let layout = split("horizontal", 0.5, id: 9, leaf(1), leaf(2))
        let leaves = PeerWorkspaceMirrorController.preorderLeaves(layout)
        let panelBySurfaceID: [Data: UUID] = [
            Data([1]): UUID(),
            Data([2]): UUID(),
        ]
        XCTAssertTrue(
            PeerWorkspaceMirrorController.allTargetLeavesMapped(leaves, panelBySurfaceID: panelBySurfaceID)
        )
    }

    func test_allTargetLeavesMapped_falseWhenALeafAttachIsMissing() {
        // Mirrors a leaf whose PeerPaneSession.attach() failed on a
        // prior reconcile pass: it never made it into panelBySurfaceID,
        // so the fast paths must not treat this layout as fully applied.
        let layout = split("horizontal", 0.5, id: 9, leaf(1), leaf(2))
        let leaves = PeerWorkspaceMirrorController.preorderLeaves(layout)
        let panelBySurfaceID: [Data: UUID] = [Data([1]): UUID()]
        XCTAssertFalse(
            PeerWorkspaceMirrorController.allTargetLeavesMapped(leaves, panelBySurfaceID: panelBySurfaceID)
        )
    }

    func test_allTargetLeavesMapped_trueForEmptyLeaves() {
        XCTAssertTrue(
            PeerWorkspaceMirrorController.allTargetLeavesMapped([], panelBySurfaceID: [:])
        )
    }

    // MARK: - walkParallelSplits mismatch detection

    func test_walkParallelSplits_flagsShapeMismatch() {
        let host = split("horizontal", 0.5, id: 9, leaf(1), leaf(2))
        // Local tree is a bare pane — shape diverged.
        let local = ExternalTreeNode.pane(
            ExternalPaneNode(
                id: UUID().uuidString,
                frame: PixelRect(x: 0, y: 0, width: 100, height: 100),
                tabs: [],
                selectedTabId: nil
            )
        )
        var mismatch = false
        var visited = 0
        PeerWorkspaceMirrorController.walkParallelSplits(
            host: host, local: local,
            visit: { _, _ in visited += 1 },
            onMismatch: { mismatch = true }
        )
        XCTAssertTrue(mismatch)
        XCTAssertEqual(visited, 0)
    }

    // MARK: - receiveLoopAction (t5: WorkspaceRemoved mirror routing)

    func test_receiveLoopAction_appliesLayoutForOwnWorkspace() {
        let hostID = Data([1])
        let layout = leaf(1)
        let action = PeerWorkspaceMirrorController.receiveLoopAction(
            for: .workspaceLayoutChanged(workspaceID: hostID, layout: layout),
            hostWorkspaceID: hostID
        )
        XCTAssertEqual(action, .applyLayout(layout))
    }

    func test_receiveLoopAction_ignoresLayoutForForeignWorkspace() {
        let hostID = Data([1])
        let action = PeerWorkspaceMirrorController.receiveLoopAction(
            for: .workspaceLayoutChanged(workspaceID: Data([2]), layout: leaf(1)),
            hostWorkspaceID: hostID
        )
        XCTAssertEqual(action, .ignore)
    }

    func test_receiveLoopAction_marksHostGoneForOwnWorkspaceRemoved() {
        let hostID = Data([1])
        let action = PeerWorkspaceMirrorController.receiveLoopAction(
            for: .workspaceRemoved(workspaceID: hostID),
            hostWorkspaceID: hostID
        )
        XCTAssertEqual(action, .hostGone)
    }

    func test_receiveLoopAction_ignoresForeignWorkspaceRemoved() {
        // A DeleteWorkspaceRequest against some OTHER workspace on the same
        // host must not tear down this mirror.
        let hostID = Data([1])
        let action = PeerWorkspaceMirrorController.receiveLoopAction(
            for: .workspaceRemoved(workspaceID: Data([9])),
            hostWorkspaceID: hostID
        )
        XCTAssertEqual(action, .ignore)
    }

    func test_receiveLoopAction_goodbyeIsAlwaysLost() {
        let action = PeerWorkspaceMirrorController.receiveLoopAction(
            for: .goodbye(reason: "bye"),
            hostWorkspaceID: Data([1])
        )
        XCTAssertEqual(action, .lost(reason: "host closed connection: bye"))
    }

    func test_receiveLoopAction_ignoresOtherMessages() {
        let action = PeerWorkspaceMirrorController.receiveLoopAction(
            for: .other,
            hostWorkspaceID: Data([1])
        )
        XCTAssertEqual(action, .ignore)
    }
}

/// Deterministic coverage for the P9.2 gap heal's debounce/throttle timing
/// in `RelayResizeCoalescer`.
///
/// R3 (peer-relay-bulk-loss) moved the heal *action* out of this actor: it
/// used to nudge the remote terminal size directly (shrink one column, then
/// restore, so the host SIGWINCHes the child and it redraws); now it invokes
/// the `onHeal` closure supplied by `PeerRelaySession`, which performs a
/// resume re-attach instead. This actor still owns exactly when a heal
/// fires — one trailing-debounce heal once a burst settles, or periodic
/// throttle heals while drops stream with no lull (the slow-network case) —
/// which stays impractical to verify through the flaky live workspace-mirror
/// path, so it's exercised directly here via the `onHeal` callback rather
/// than by counting `Resize` frames.
final class RelayResizeCoalescerHealTests: XCTestCase {

    /// Accumulates the `cols` of every `Resize` frame the coalescer sends
    /// (still exercised by `submit`/`flushNow` — the ordinary resize path is
    /// untouched by R3, only the heal action moved out).
    private actor ResizeColsCollector {
        private var pending = Data()
        private var collected: [UInt32] = []

        func add(_ data: Data) {
            pending.append(data)
            while let env = try? decodeFrame(from: &pending) {
                if case .resize(let r)? = env.payload {
                    collected.append(r.cols)
                }
            }
        }

        func cols() -> [UInt32] { collected }
    }

    /// Records every `onHeal(reason)` invocation.
    private actor HealRecorder {
        private var reasons: [String] = []

        func record(_ reason: String) { reasons.append(reason) }
        func all() -> [String] { reasons }
    }

    /// A `PeerSession` whose writes flow to `collector`; its read never
    /// completes (these tests only ever write, via `submit`/`flushNow`).
    private func makeSession(_ collector: ResizeColsCollector) -> PeerSession {
        PeerSession(
            read: {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
                return Data()
            },
            write: { await collector.add($0) }
        )
    }

    /// A single gap, then quiet: the trailing debounce must fire `onHeal`
    /// exactly once, with reason "settle", after the burst settles.
    func testSettleDebounceFiresHealOnceAfterBurstSettles() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let healed = HealRecorder()
        // Short debounce; throttle effectively disabled so ONLY the trailing
        // debounce can fire.
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC0, count: 16),
            initialCols: 80,
            initialRows: 24,
            healDebounceMs: 40,
            healMaxWaitSeconds: 1000,
            onHeal: { reason in await healed.record(reason) }
        )

        await coalescer.noteGapForHeal()
        try await Task.sleep(nanoseconds: 300_000_000)  // well past the 40ms debounce

        let reasons = await healed.all()
        XCTAssertEqual(reasons, ["settle"], "settle heal must fire onHeal exactly once")
        await coalescer.cancel()
    }

    /// Continuous drops with no lull: the trailing debounce never gets to fire,
    /// so the throttle must keep invoking `onHeal` periodically — the
    /// slow-network case a single trailing debounce would otherwise miss.
    func testThrottleFiresHealRepeatedlyUnderContinuousDrops() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let healed = HealRecorder()
        // Short throttle; debounce effectively disabled so the trailing path
        // CANNOT fire during the test — every heal here is a throttle heal.
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC1, count: 16),
            initialCols: 80,
            initialRows: 24,
            healDebounceMs: 1_000_000,
            healMaxWaitSeconds: 0.1,
            onHeal: { reason in await healed.record(reason) }
        )

        // Stream gaps every ~15ms for ~0.5s — never a 100ms lull.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            await coalescer.noteGapForHeal()
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)  // let the final throttle land

        let reasons = await healed.all()
        // ~0.5s at a 0.1s throttle → several heals.
        XCTAssertGreaterThanOrEqual(
            reasons.count, 2,
            "throttle must fire onHeal repeatedly under continuous drops; got \(reasons)"
        )
        XCTAssertTrue(reasons.allSatisfy { $0 == "throttle" }, "expected only throttle heals; got \(reasons)")
        await coalescer.cancel()
    }

    /// No known size (nil seed) must not crash or invoke `onHeal` — the
    /// heal simply no-ops until a size is available.
    func testHealNoOpsWithoutAKnownSize() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let healed = HealRecorder()
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC2, count: 16),
            initialCols: 0,      // invalid → no seed
            initialRows: 0,
            healDebounceMs: 40,
            healMaxWaitSeconds: 1000,
            onHeal: { reason in await healed.record(reason) }
        )

        await coalescer.noteGapForHeal()
        try await Task.sleep(nanoseconds: 300_000_000)

        let reasons = await healed.all()
        XCTAssertTrue(reasons.isEmpty, "no size known → onHeal must not fire; got \(reasons)")
        await coalescer.cancel()
    }

    /// Regression: a 0-column size (e.g. a transient 0-col resize from the
    /// relay) must not invoke `onHeal` — a resume re-attach still needs a
    /// sane size to send as client_cols/client_rows.
    func testHealDoesNotFireOnZeroColumnSize() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let healed = HealRecorder()
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC3, count: 16),
            initialCols: 80,
            initialRows: 24,
            healDebounceMs: 40,
            healMaxWaitSeconds: 1000,
            onHeal: { reason in await healed.record(reason) }
        )
        await coalescer.submit(cols: 0, rows: 24)  // 0-col size — must not fire the heal
        await coalescer.noteGapForHeal()
        try await Task.sleep(nanoseconds: 300_000_000)

        let reasons = await healed.all()
        XCTAssertTrue(reasons.isEmpty, "a 0-col size must not fire onHeal; got \(reasons)")
        await coalescer.cancel()
    }
}
