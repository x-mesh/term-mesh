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

/// Deterministic coverage for the P9.2 gap heal in `RelayResizeCoalescer`.
///
/// The heal nudges the remote terminal size (shrink one column, then restore)
/// so the host SIGWINCHes the child and it redraws state a broadcast-Lag drop
/// truncated. Its two firing paths — a trailing debounce (one heal once a burst
/// settles) and a maxWait throttle (periodic heals while drops stream with no
/// lull, the slow-network case) — are impractical to verify through the flaky
/// live workspace-mirror path, so they are exercised directly here. Each heal
/// emits exactly two `Resize` frames: `cols-1` then `cols`.
final class RelayResizeCoalescerHealTests: XCTestCase {

    /// Accumulates the `cols` of every `Resize` frame the coalescer sends.
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

    /// A `PeerSession` whose writes flow to `collector`; its read never
    /// completes (the heal path only ever writes).
    private func makeSession(_ collector: ResizeColsCollector) -> PeerSession {
        PeerSession(
            read: {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
                return Data()
            },
            write: { await collector.add($0) }
        )
    }

    /// A single gap, then quiet: the trailing debounce must fire exactly one
    /// heal — a `cols-1` → `cols` nudge — after the burst settles.
    func testSettleDebounceNudgesOnceAfterBurstSettles() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        // Short debounce; throttle effectively disabled so ONLY the trailing
        // debounce can fire.
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC0, count: 16),
            initialCols: 80,
            initialRows: 24,
            healDebounceMs: 40,
            healMaxWaitSeconds: 1000
        )

        await coalescer.noteGapForHeal()
        try await Task.sleep(nanoseconds: 300_000_000)  // well past the 40ms debounce

        let cols = await collector.cols()
        XCTAssertEqual(cols, [79, 80], "settle heal must nudge cols 79→80 exactly once")
        await coalescer.cancel()
    }

    /// Continuous drops with no lull: the trailing debounce never gets to fire,
    /// so the throttle must keep issuing periodic heals — the slow-network case
    /// a single trailing debounce would otherwise miss entirely.
    func testThrottleNudgesRepeatedlyUnderContinuousDrops() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        // Short throttle; debounce effectively disabled so the trailing path
        // CANNOT fire during the test — every heal here is a throttle heal.
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC1, count: 16),
            initialCols: 80,
            initialRows: 24,
            healDebounceMs: 1_000_000,
            healMaxWaitSeconds: 0.1
        )

        // Stream gaps every ~15ms for ~0.5s — never a 100ms lull.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            await coalescer.noteGapForHeal()
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)  // let the final throttle land

        let cols = await collector.cols()
        // ~0.5s at a 0.1s throttle → several heals, each a 2-frame nudge.
        XCTAssertGreaterThanOrEqual(
            cols.count, 4,
            "throttle must fire repeatedly under continuous drops; got \(cols)"
        )
        XCTAssertEqual(cols.count % 2, 0, "heals come in resize pairs; got \(cols)")
        for i in stride(from: 0, to: cols.count, by: 2) {
            XCTAssertEqual(cols[i], 79, "nudge shrink frame; got \(cols)")
            XCTAssertEqual(cols[i + 1], 80, "nudge restore frame; got \(cols)")
        }
        await coalescer.cancel()
    }

    /// No known size (nil seed) must not crash or emit a bogus resize — the
    /// heal simply no-ops until a size is available.
    func testHealNoOpsWithoutAKnownSize() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC2, count: 16),
            initialCols: 0,      // invalid → no seed
            initialRows: 0,
            healDebounceMs: 40,
            healMaxWaitSeconds: 1000
        )

        await coalescer.noteGapForHeal()
        try await Task.sleep(nanoseconds: 300_000_000)

        let cols = await collector.cols()
        XCTAssertTrue(cols.isEmpty, "no size known → no resize nudge; got \(cols)")
        await coalescer.cancel()
    }

    /// Regression: a 0-column size (e.g. a transient 0-col resize from the
    /// relay) must not trap `size.cols - 1` (UInt32 underflow) — the heal
    /// simply no-ops. Test completing without a crash is half the assertion.
    func testHealDoesNotCrashOnZeroColumnSize() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC3, count: 16),
            initialCols: 80,
            initialRows: 24,
            healDebounceMs: 40,
            healMaxWaitSeconds: 1000
        )
        await coalescer.submit(cols: 0, rows: 24)  // 0-col size — must not trap the heal
        await coalescer.noteGapForHeal()
        try await Task.sleep(nanoseconds: 300_000_000)

        let cols = await collector.cols()
        XCTAssertFalse(cols.contains(79), "a 0-col size must produce no nudge; got \(cols)")
        await coalescer.cancel()
    }
}
