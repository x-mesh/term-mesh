import XCTest
import Bonsplit
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerWorkspaceMirrorTests: XCTestCase {

    func test_workspaceMirrorPrunePolicy_keepsOwnedWorkspace() {
        let workspaceID = UUID()
        XCTAssertFalse(
            PeerClientCoordinator.WorkspaceMirrorPrunePolicy.shouldPrune(
                isTornDown: false,
                workspaceID: workspaceID,
                contextContainsWorkspace: { $0 == workspaceID }
            )
        )
    }

    func test_workspaceMirrorPrunePolicy_prunesMissingWorkspaceAndOrphan() {
        XCTAssertTrue(
            PeerClientCoordinator.WorkspaceMirrorPrunePolicy.shouldPrune(
                isTornDown: false,
                workspaceID: nil,
                contextContainsWorkspace: { _ in false }
            )
        )

        XCTAssertTrue(
            PeerClientCoordinator.WorkspaceMirrorPrunePolicy.shouldPrune(
                isTornDown: false,
                workspaceID: UUID(),
                contextContainsWorkspace: { _ in false }
            )
        )
    }

    func test_workspaceMirrorPrunePolicy_ignoresAlreadyTornDownMirror() {
        XCTAssertFalse(
            PeerClientCoordinator.WorkspaceMirrorPrunePolicy.shouldPrune(
                isTornDown: true,
                workspaceID: nil,
                contextContainsWorkspace: { _ in false }
            )
        )
    }

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

    private func workspace(_ id: UInt8) -> Termmesh_Peer_V1_Workspace {
        var workspace = Termmesh_Peer_V1_Workspace()
        workspace.workspaceID = Data([id])
        workspace.layout = leaf(id)
        return workspace
    }

    private func remotePane(
        _ id: UInt8,
        cwd: String?,
        projectRoot: String? = nil
    ) -> RemotePaneSummary {
        RemotePaneSummary(
            id: Data([id]),
            title: "pane-\(id)",
            workingDirectoryPath: cwd,
            workingDirectoryName: cwd.flatMap { ($0 as NSString).lastPathComponent },
            projectRootPath: projectRoot,
            tabCount: 1,
            columns: 80,
            rows: 24,
            isBusy: false
        )
    }

    // MARK: - peerProjectIdentity

    func test_peerProjectIdentity_usesCommonAncestorForSiblingPaneDirectories() {
        let identity = peerProjectIdentity(for: [
            remotePane(1, cwd: "/Users/jinwoo/work/project/term-mesh/Sources"),
            remotePane(2, cwd: "/Users/jinwoo/work/project/term-mesh/termMeshTests"),
        ])

        XCTAssertEqual(identity.label, "term-mesh")
        XCTAssertFalse(identity.isUnknown)
    }

    func test_peerProjectIdentity_normalizesTrailingSlashesAndCaseForKey() {
        let a = peerProjectIdentity(for: [
            remotePane(1, cwd: "/Users/jinwoo/work/project/Term-Mesh///Sources"),
            remotePane(2, cwd: "/Users/jinwoo/work/project/Term-Mesh/Tests"),
        ])
        let b = peerProjectIdentity(for: [
            remotePane(3, cwd: "/users/jinwoo/work/project/term-mesh/src"),
            remotePane(4, cwd: "/users/jinwoo/work/project/term-mesh/tests"),
        ])

        XCTAssertEqual(a.key, b.key)
        XCTAssertEqual(a.label, "Term-Mesh")
    }

    func test_peerProjectIdentity_fallsBackToUnknownWithoutCwd() {
        let identity = peerProjectIdentity(for: [
            remotePane(1, cwd: nil),
            remotePane(2, cwd: ""),
        ])

        XCTAssertEqual(identity, .unknown)
    }

    func test_peerProjectIdentity_homeDirectoryIsNotAProject() {
        // A peer shelling in `/root` used to surface a "root" project.
        XCTAssertEqual(peerProjectIdentity(for: [remotePane(1, cwd: "/root")]), .unknown)
        XCTAssertEqual(peerProjectIdentity(for: [remotePane(2, cwd: "/Users/jinwoo")]), .unknown)
        XCTAssertEqual(peerProjectIdentity(for: [remotePane(3, cwd: "/home/ubuntu")]), .unknown)
        XCTAssertEqual(peerProjectIdentity(for: [remotePane(4, cwd: "/")]), .unknown)
    }

    func test_peerProjectIdentity_unrelatedPanesCollapseToUnknownNotTheHome() {
        let identity = peerProjectIdentity(for: [
            remotePane(1, cwd: "/root/term-mesh"),
            remotePane(2, cwd: "/root/x-kit"),
        ])

        XCTAssertEqual(identity, .unknown)
    }

    func test_peerProjectIdentity_homeChildIsAProject() {
        let identity = peerProjectIdentity(for: [remotePane(1, cwd: "/root/term-mesh")])

        XCTAssertEqual(identity.label, "term-mesh")
        XCTAssertFalse(identity.isUnknown)
    }

    /// Without a reported root, cwd alone cannot locate the project, so a
    /// lone pane in a subdirectory names that subdirectory. This is the
    /// fallback path for hosts predating `project_root`.
    func test_peerProjectIdentity_loneSubdirectoryPaneNamesTheSubdirectory() {
        let identity = peerProjectIdentity(for: [remotePane(1, cwd: "/root/term-mesh/daemon")])

        XCTAssertEqual(identity.label, "daemon")
    }

    func test_peerProjectIdentity_reportedRootBeatsTheCwdGuess() {
        let identity = peerProjectIdentity(for: [
            remotePane(1, cwd: "/root/term-mesh/daemon", projectRoot: "/root/term-mesh"),
        ])

        XCTAssertEqual(identity.label, "term-mesh")
        XCTAssertFalse(identity.isUnknown)
    }

    func test_peerProjectIdentity_rootedPanesInUnrelatedTreesDoNotCollapse() {
        // Without roots these two would share only `/root` and go unassigned.
        let identity = peerProjectIdentity(for: [
            remotePane(1, cwd: "/root/term-mesh/Sources", projectRoot: "/root/term-mesh"),
            remotePane(2, cwd: "/root/term-mesh/daemon", projectRoot: "/root/term-mesh"),
            remotePane(3, cwd: "/root/x-kit", projectRoot: "/root/x-kit"),
        ])

        XCTAssertEqual(identity.label, "term-mesh")
    }

    func test_peerProjectIdentity_rootTieGoesToTheFirstPane() {
        let identity = peerProjectIdentity(for: [
            remotePane(1, cwd: "/root/x-kit", projectRoot: "/root/x-kit"),
            remotePane(2, cwd: "/root/term-mesh", projectRoot: "/root/term-mesh"),
        ])

        XCTAssertEqual(identity.label, "x-kit")
    }

    func test_peerProjectIdentity_paneOutsideARepoFallsBackToCwd() {
        // Host reported no root for this pane (empty → nil), so the cwd
        // heuristic still applies and a bare home stays unassigned.
        XCTAssertEqual(peerProjectIdentity(for: [remotePane(1, cwd: "/root")]), .unknown)
    }

    /// The local axis feeds raw panel directories through the same entry
    /// point, so both sides must agree on what counts as a project.
    func test_projectIdentity_localPanelDirectoriesUseTheSameRules() {
        let local = projectIdentity(forWorkingDirectories: [
            "/Users/jinwoo/work/project/term-mesh",
            "/Users/jinwoo/work/project/term-mesh/daemon",
        ])
        let peer = peerProjectIdentity(for: [remotePane(1, cwd: "/root/term-mesh")])

        XCTAssertEqual(local.label, "term-mesh")
        XCTAssertEqual(local.key, peer.key)
        XCTAssertEqual(projectIdentity(forWorkingDirectories: ["/Users/jinwoo"]), .unknown)
        XCTAssertEqual(projectIdentity(forWorkingDirectories: []), .unknown)
    }

    func test_peerProjectIdentity_sameProjectAcrossHostsSharesKey() {
        // Local checkout and a peer checkout of one project must land in the
        // same group even though their absolute paths differ.
        let local = peerProjectIdentity(for: [
            remotePane(1, cwd: "/Users/jinwoo/work/project/term-mesh/Sources"),
            remotePane(2, cwd: "/Users/jinwoo/work/project/term-mesh/daemon"),
        ])
        let peer = peerProjectIdentity(for: [remotePane(3, cwd: "/root/term-mesh")])

        XCTAssertEqual(local.key, peer.key)
        XCTAssertFalse(local.isUnknown)
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

    // MARK: - reconnect workspace identity adoption

    @MainActor
    func test_matchedWorkspaceIdentity_adoptsChangedIDForSingleWorkspaceReconnect() {
        let match = PeerWorkspaceMirrorController.matchedWorkspaceIdentity(
            [workspace(9)],
            currentID: Data([1])
        )

        XCTAssertEqual(match?.workspace.workspaceID, Data([9]))
        XCTAssertEqual(match?.adoptedID, Data([9]))
    }

    @MainActor
    func test_matchedWorkspaceIdentity_doesNotAdoptForeignIDWithMultipleWorkspaces() {
        let match = PeerWorkspaceMirrorController.matchedWorkspaceIdentity(
            [workspace(8), workspace(9)],
            currentID: Data([1])
        )

        XCTAssertNil(match)
    }

    @MainActor
    func test_workspaceIDAliases_preservesOldIDWhenAdoptingReconnectID() {
        let oldID = Data([1])
        let newID = Data([9])

        let aliases = PeerWorkspaceMirrorController.workspaceIDAliases(
            [oldID],
            adopting: newID
        )

        XCTAssertEqual(aliases, [oldID, newID])
    }

    @MainActor
    func test_matchesHostWorkspaceID_acceptsCachedAndCurrentIDsForDedupe() {
        let oldID = Data([1])
        let currentID = Data([9])
        let aliases: Set<Data> = [oldID, currentID]

        XCTAssertTrue(
            PeerWorkspaceMirrorController.matchesHostWorkspaceID(oldID, aliases: aliases)
        )
        XCTAssertTrue(
            PeerWorkspaceMirrorController.matchesHostWorkspaceID(currentID, aliases: aliases)
        )
        XCTAssertFalse(
            PeerWorkspaceMirrorController.matchesHostWorkspaceID(Data([8]), aliases: aliases)
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

    // MARK: - partitionForReconnect (keeping panes whose relay recovered)

    /// A pane's own relay reconnects independently of the mirror's layout
    /// subscription and usually finishes first, so a mirror reconnect used to
    /// discard panes that were already working — a fresh helper process and
    /// Ghostty surface for each, and the live one closed. These pin which
    /// side of the split each pane lands on.

    func test_partitionForReconnect_keepsOnlyRecoveredPanes() {
        let recovered = UUID()
        let notRecovered = UUID()
        let split = PeerWorkspaceMirrorController.partitionForReconnect(
            panelBySurfaceID: [Data([1]): recovered, Data([2]): notRecovered],
            isRecovered: { $0 == recovered }
        )
        XCTAssertEqual(split.keep, [Data([1]): recovered])
        XCTAssertEqual(split.respawn, [Data([2]): notRecovered])
    }

    func test_partitionForReconnect_allRecoveredRespawnsNothing() {
        // The case the change exists for: every pane came back on its own,
        // so the reconnect should cost nothing at all.
        let a = UUID(), b = UUID()
        let split = PeerWorkspaceMirrorController.partitionForReconnect(
            panelBySurfaceID: [Data([1]): a, Data([2]): b],
            isRecovered: { _ in true }
        )
        XCTAssertEqual(split.keep.count, 2)
        XCTAssertTrue(split.respawn.isEmpty)
    }

    func test_partitionForReconnect_noneRecoveredKeepsNothing() {
        // Degenerate case, and the caller reads it as its signal to fall back
        // to the full wipe. A pane still `.pending` or `.starting` lands here
        // on purpose: respawning it wastes work, whereas keeping one that
        // never comes up leaves the user a pane that does nothing.
        let split = PeerWorkspaceMirrorController.partitionForReconnect(
            panelBySurfaceID: [Data([1]): UUID(), Data([2]): UUID()],
            isRecovered: { _ in false }
        )
        XCTAssertTrue(split.keep.isEmpty)
        XCTAssertEqual(split.respawn.count, 2)
    }

    func test_partitionForReconnect_everyPaneLandsOnExactlyOneSide() {
        // No mapping may be dropped on the floor: one lost here is a pane
        // that is never respawned and never closed — a ghost tab holding a
        // relay helper process open.
        let panels = (0..<6).map { _ in UUID() }
        var map: [Data: UUID] = [:]
        for (index, panel) in panels.enumerated() {
            map[Data([UInt8(index)])] = panel
        }
        let split = PeerWorkspaceMirrorController.partitionForReconnect(
            panelBySurfaceID: map,
            isRecovered: { panelId in panels.firstIndex(of: panelId)! % 2 == 0 }
        )
        XCTAssertEqual(split.keep.count + split.respawn.count, map.count)
        XCTAssertTrue(Set(split.keep.keys).isDisjoint(with: Set(split.respawn.keys)))
    }

    func test_partitionForReconnect_emptyMapIsEmptyOnBothSides() {
        let split = PeerWorkspaceMirrorController.partitionForReconnect(
            panelBySurfaceID: [:],
            isRecovered: { _ in true }
        )
        XCTAssertTrue(split.keep.isEmpty)
        XCTAssertTrue(split.respawn.isEmpty)
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
final class RelayResumeTransitionGateTests: XCTestCase {

    /// Reconnect replaces the session wholesale, so a transition that was in
    /// flight when the transport died must not keep suppressing output — the
    /// bytes it was holding for belong to a stream that no longer exists.
    func testResetClearsAnInFlightTransition() {
        let gate = RelayResumeTransitionGate()
        let transition = gate.begin()
        XCTAssertEqual(gate.route(endWireSeq: 5, data: Data("held".utf8)), .suppress)

        gate.reset()

        XCTAssertEqual(gate.route(endWireSeq: 1, data: Data("new".utf8)), .forward(Data("new".utf8)))
        XCTAssertEqual(gate.currentWireSeq(), 1)
        XCTAssertNil(gate.abort(transition), "the stale transition must no longer control the gate")
        XCTAssertFalse(gate.commit(transition))
    }

    func testResetClearsACommittedTransition() {
        let gate = RelayResumeTransitionGate()
        let transition = gate.begin()
        XCTAssertTrue(gate.commit(transition))
        XCTAssertEqual(gate.route(endWireSeq: 2, data: Data("x".utf8)), .suppress)

        gate.reset()

        XCTAssertEqual(gate.route(endWireSeq: 3, data: Data("y".utf8)), .forward(Data("y".utf8)))
    }

    /// `begin()` reports the wire position as a side effect of starting to
    /// buffer; reconnect needs the value without that.
    func testCurrentWireSeqDoesNotOpenATransition() {
        let gate = RelayResumeTransitionGate()
        _ = gate.route(endWireSeq: 9, data: Data("a".utf8))

        XCTAssertEqual(gate.currentWireSeq(), 9)
        XCTAssertEqual(gate.route(endWireSeq: 10, data: Data("b".utf8)), .forward(Data("b".utf8)))
    }

    /// `.buffering` is capped; `.draining` must be too, or a busy stream grows
    /// it without limit while the abort flush is in flight.
    func testDrainingIsBoundedLikeBuffering() {
        let gate = RelayResumeTransitionGate(maxBufferedBytes: 4)
        let transition = gate.begin()
        XCTAssertEqual(gate.route(endWireSeq: 1, data: Data("ab".utf8)), .suppress)
        XCTAssertEqual(gate.abort(transition), Data("ab".utf8))

        // `abort` emptied the buffer, so the cap applies to what accumulates
        // after it: 2 bytes fit, the next 3 do not.
        XCTAssertEqual(gate.route(endWireSeq: 2, data: Data("cd".utf8)), .suppress)
        XCTAssertEqual(
            gate.route(endWireSeq: 3, data: Data("efg".utf8)),
            .overflowFlush(Data("cdefg".utf8)),
            "an over-cap drain must flush in order instead of growing"
        )
        XCTAssertEqual(gate.route(endWireSeq: 4, data: Data("h".utf8)), .forward(Data("h".utf8)))
        XCTAssertNil(gate.finishDrain(transition))
    }


    func testOldOutputBeforeBoundaryPassesAndLaterOutputBuffers() {
        let gate = RelayResumeTransitionGate()
        XCTAssertEqual(gate.route(endWireSeq: 3, data: Data("old".utf8)), .forward(Data("old".utf8)))

        let transition = gate.begin()
        XCTAssertEqual(transition.resumeWireSeq, 3)
        XCTAssertEqual(gate.route(endWireSeq: 7, data: Data("held".utf8)), .suppress)
    }

    func testSuccessfulAttachDiscardsOldBytesAndForwardsReplayOnce() {
        let gate = RelayResumeTransitionGate()
        var displayed = Data()
        if case .forward(let data) = gate.route(endWireSeq: 3, data: Data("one".utf8)) {
            displayed.append(data)
        }

        let transition = gate.begin()
        XCTAssertEqual(gate.route(endWireSeq: 6, data: Data("two".utf8)), .suppress)
        XCTAssertTrue(gate.commit(transition))
        XCTAssertEqual(gate.route(endWireSeq: 9, data: Data("old".utf8)), .suppress)

        gate.adoptCommittedSession()
        if case .forward(let replay) = gate.route(endWireSeq: 6, data: Data("two".utf8)) {
            displayed.append(replay)
        }
        XCTAssertEqual(displayed, Data("onetwo".utf8), "old live bytes and replay must not both render")
    }

    func testFailedAttachFlushesBufferedOutputInOrder() {
        let gate = RelayResumeTransitionGate()
        _ = gate.route(endWireSeq: 1, data: Data("0".utf8))
        let transition = gate.begin()
        XCTAssertEqual(gate.route(endWireSeq: 2, data: Data("1".utf8)), .suppress)

        XCTAssertEqual(gate.abort(transition), Data("1".utf8))
        XCTAssertEqual(gate.route(endWireSeq: 3, data: Data("2".utf8)), .suppress)
        XCTAssertEqual(gate.finishDrain(transition), Data("2".utf8))
        XCTAssertNil(gate.finishDrain(transition))
        XCTAssertEqual(gate.route(endWireSeq: 4, data: Data("3".utf8)), .forward(Data("3".utf8)))
    }

    func testOverflowRestoresOldStreamAndInvalidatesAttach() {
        let gate = RelayResumeTransitionGate(maxBufferedBytes: 3)
        let transition = gate.begin()
        XCTAssertEqual(gate.route(endWireSeq: 2, data: Data("12".utf8)), .suppress)
        XCTAssertEqual(
            gate.route(endWireSeq: 4, data: Data("34".utf8)),
            .overflowFlush(Data("1234".utf8))
        )
        XCTAssertFalse(gate.commit(transition))
        XCTAssertEqual(gate.route(endWireSeq: 5, data: Data("5".utf8)), .forward(Data("5".utf8)))
    }
}

final class PeerTerminalReplayBufferTests: XCTestCase {
    func testFreshAttachAllowsAnEmptyViewport() {
        var replay = PeerTerminalReplayBuffer()

        XCTAssertEqual(
            replay.freshInitialBytes(snapshot: nil, capturedAt: 0, tapSeqAtCall: 0),
            Data(),
            "a fresh empty pane is an attachable empty surface"
        )
    }

    func testFreshAttachReconcilesOutputAfterAnEmptyViewportRead() {
        var replay = PeerTerminalReplayBuffer()
        replay.push(Data("late".utf8))

        XCTAssertEqual(
            replay.freshInitialBytes(snapshot: nil, capturedAt: 0, tapSeqAtCall: 4),
            Data("late".utf8)
        )
    }

    func testBusySnapshotFallsBackToLastCaptureAndItsEarlierBoundary() {
        var boundaries: [UInt64] = [0, 1, 2, 3, 4, 5, 6]
        var captures = [Data("first".utf8), Data("second".utf8), Data("last".utf8)]

        let result = PtyTapHub.stableSnapshot(
            attempts: 3,
            boundary: { boundaries.removeFirst() },
            capture: { captures.removeFirst() }
        )

        XCTAssertEqual(result.bytes, Data("last".utf8))
        XCTAssertEqual(result.seq, 5)
    }

    func testStableSnapshotUsesQuietPostCaptureBoundary() {
        var boundaries: [UInt64] = [7, 8, 8]

        let result = PtyTapHub.stableSnapshot(
            attempts: 3,
            boundary: { boundaries.removeFirst() },
            capture: { Data("screen".utf8) }
        )

        XCTAssertEqual(result.bytes, Data("screen".utf8))
        XCTAssertEqual(result.seq, 8)
    }

    func testExactResumeReturnsOnlyUnseenTail() {
        var replay = PeerTerminalReplayBuffer()
        replay.push(Data("hello".utf8))
        replay.push(Data(" world".utf8))

        XCTAssertEqual(
            replay.exactBytes(from: 6, tapSeqAtCall: 11),
            Data("world".utf8)
        )
        XCTAssertEqual(
            replay.exactBytes(from: 11, tapSeqAtCall: 11),
            Data(),
            "a caught-up viewer has an exact empty continuation"
        )
    }

    func testEvictedResumeNeverFallsBackToOldTailReplay() {
        var replay = PeerTerminalReplayBuffer()
        replay.push(Data(repeating: 0x41, count: PtyTapHub.replayCapacityBytes))
        replay.push(Data("new".utf8))

        XCTAssertTrue(replay.hasEvicted)
        XCTAssertNil(
            replay.exactBytes(
                from: 0,
                tapSeqAtCall: UInt64(PtyTapHub.replayCapacityBytes + 3)
            ),
            "an evicted resume must repaint the viewport, not replay retained PTY history"
        )
    }

    func testSnapshotReconciliationAppendsOutputBeforeRegistration() {
        var replay = PeerTerminalReplayBuffer()
        replay.push(Data("old".utf8))
        let snapshotSeq: UInt64 = 3
        replay.push(Data("new".utf8))

        XCTAssertEqual(
            replay.snapshotBytes(
                Data("screen".utf8),
                capturedAt: snapshotSeq,
                tapSeqAtCall: 6
            ),
            Data("screennew".utf8)
        )
    }

    func testSnapshotReconciliationFailsAfterInterveningTailEviction() {
        var replay = PeerTerminalReplayBuffer()
        replay.push(Data(repeating: 0x41, count: PtyTapHub.replayCapacityBytes + 1))

        XCTAssertNil(
            replay.snapshotBytes(
                Data("stale".utf8),
                capturedAt: 0,
                tapSeqAtCall: UInt64(PtyTapHub.replayCapacityBytes + 1)
            )
        )
    }
}

final class RelayResizeCoalescerHealTests: XCTestCase {

    /// Accumulates the `cols` of every `Resize` frame the coalescer sends
    /// (still exercised by `submit`/`flushNow` — the ordinary resize path is
    /// untouched by R3, only the heal action moved out).
    private actor ResizeColsCollector {
        private var pending = Data()
        private var collected: [UInt32] = []
        private var authorityClaims: [Bool] = []

        func add(_ data: Data) {
            pending.append(data)
            while let env = try? decodeFrame(from: &pending) {
                if case .resize(let r)? = env.payload {
                    collected.append(r.cols)
                    authorityClaims.append(r.claimAuthority)
                }
            }
        }

        func cols() -> [UInt32] { collected }
        func claims() -> [Bool] { authorityClaims }
    }

    func testInitialResizeIsPassiveThenFocusedResizeClaimsAuthority() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC4, count: 16),
            initialCols: 80,
            initialRows: 24,
            authorityEligible: true,
            delayMs: 1,
            onHeal: { _ in }
        )

        await coalescer.submit(cols: 80, rows: 24)
        await coalescer.flushNow()
        await coalescer.submit(cols: 120, rows: 36)
        await coalescer.flushNow()

        let cols = await collector.cols()
        let claims = await collector.claims()
        XCTAssertEqual(cols, [80, 120])
        XCTAssertEqual(claims, [false, true])
        await coalescer.cancel()
    }

    /// A resize held for the coalescing delay must not claim authority if
    /// focus left the pane before it went out.
    ///
    /// The claim used to be decided in `submit` and carried in `pending`, so a
    /// resize that started while focused still asserted authority ~24ms later
    /// even though `setAuthorityEligible(false)` had run in between. The host
    /// arbitrates PTY size by most recent activity, so that late claim landed
    /// after the newly focused pane's own resize and took the size back — the
    /// remote TUI ended up sized for the pane the person had just left.
    func testAResizeDoesNotClaimAuthorityAfterFocusLeavesDuringTheDelay() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC5, count: 16),
            initialCols: 80,
            initialRows: 24,
            authorityEligible: true,
            delayMs: 1,
            onHeal: { _ in }
        )

        // Get past the initial geometry reconcile, which is passive by design.
        await coalescer.submit(cols: 80, rows: 24)
        await coalescer.flushNow()

        // A focused resize starts…
        await coalescer.submit(cols: 120, rows: 36)
        // …focus moves away before it is written…
        await coalescer.setAuthorityEligible(false)
        // …and only then does it go out.
        await coalescer.flushNow()

        let claims = await collector.claims()
        XCTAssertEqual(claims, [false, false],
                       "a resize flushed after focus left must not claim authority")
        let cols = await collector.cols()
        XCTAssertEqual(cols, [80, 120], "the size itself is still sent")
        await coalescer.cancel()
    }

    /// The mirror of the above: focus arriving during the delay should let the
    /// resize claim authority. Deciding at flush has to work both ways, or the
    /// fix would simply have moved the bug.
    func testAResizeClaimsAuthorityWhenFocusArrivesDuringTheDelay() async throws {
        let collector = ResizeColsCollector()
        let session = makeSession(collector)
        let coalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: Data(repeating: 0xC6, count: 16),
            initialCols: 80,
            initialRows: 24,
            authorityEligible: false,
            delayMs: 1,
            onHeal: { _ in }
        )

        await coalescer.submit(cols: 80, rows: 24)
        await coalescer.flushNow()

        await coalescer.submit(cols: 120, rows: 36)
        await coalescer.setAuthorityEligible(true)
        await coalescer.flushNow()

        let claims = await collector.claims()
        XCTAssertEqual(claims, [false, true],
                       "a resize flushed after focus arrived may claim authority")
        await coalescer.cancel()
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

    // MARK: - Orphaned mapping sweep

    private func sid(_ byte: UInt8) -> Data { Data([byte]) }

    /// The condition behind a host reporting 7 panes while 2 render: the
    /// mapping survives, so `missing` skips the leaf and `buildSplits` cannot
    /// seed its split.
    func testOrphanedSurfaceIDsFindsMappingWhosePanelIsGone() {
        let alive = UUID()
        let dead = UUID()
        let orphaned = PeerWorkspaceMirrorController.orphanedSurfaceIDs(
            panelBySurfaceID: [sid(1): alive, sid(2): dead],
            livePanelIDs: [alive]
        )
        XCTAssertEqual(orphaned, [sid(2)])
    }

    /// A healthy mirror must sweep nothing — this runs on every reconcile.
    func testOrphanedSurfaceIDsIsEmptyWhenEveryPanelIsLive() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(
            PeerWorkspaceMirrorController.orphanedSurfaceIDs(
                panelBySurfaceID: [sid(1): a, sid(2): b],
                livePanelIDs: [a, b]
            ).isEmpty
        )
    }

    /// After `markAllPanesStale()` the map is already empty; the sweep must not
    /// invent work for a workspace that legitimately has no panels yet.
    func testOrphanedSurfaceIDsHandlesEmptyInputs() {
        XCTAssertTrue(
            PeerWorkspaceMirrorController.orphanedSurfaceIDs(panelBySurfaceID: [:], livePanelIDs: []).isEmpty
        )
        let only = UUID()
        XCTAssertEqual(
            PeerWorkspaceMirrorController.orphanedSurfaceIDs(
                panelBySurfaceID: [sid(9): only], livePanelIDs: []
            ),
            [sid(9)]
        )
    }

    // MARK: - reconnectStep (F2: post-await cancellation/teardown guard)

    /// The one case where `reconnectLoop` may cross a suspension point (the
    /// transport refresh, the backoff sleep, or the connect/handshake
    /// window) and keep going: the mirror is still live, still has a
    /// workspace, and nothing cancelled it.
    func test_reconnectStep_proceedsWhenLiveWorkspaceUncancelled() {
        XCTAssertEqual(
            PeerWorkspaceMirrorController.reconnectStep(
                isTornDown: false, hasWorkspace: true, isCancelled: false
            ),
            .proceed
        )
    }

    func test_reconnectStep_abandonsWhenTornDown() {
        XCTAssertEqual(
            PeerWorkspaceMirrorController.reconnectStep(
                isTornDown: true, hasWorkspace: true, isCancelled: false
            ),
            .abandon
        )
    }

    func test_reconnectStep_abandonsWhenWorkspaceIsGone() {
        XCTAssertEqual(
            PeerWorkspaceMirrorController.reconnectStep(
                isTornDown: false, hasWorkspace: false, isCancelled: false
            ),
            .abandon
        )
    }

    /// The supersede path: `handleConnectionLost` cancels the prior
    /// `reconnectTask` before starting a fresh one, and `Task.isCancelled`
    /// becoming true inside the superseded loop is how that cancellation
    /// actually reaches it. Every checkpoint in `reconnectLoop` — the entry
    /// guard, the post-refresh guard, the retry `while`, and the
    /// post-handshake guard — must abandon once that happens, or a newer
    /// `handleConnectionLost` would race the old loop into installing a
    /// duplicate subscription (the exact leak the post-handshake guard's
    /// comment warns about: a socket plus a 10s heartbeat alive for the
    /// rest of the process).
    func test_reconnectStep_abandonsWhenSupersedingReconnectCancelledThisTask() {
        XCTAssertEqual(
            PeerWorkspaceMirrorController.reconnectStep(
                isTornDown: false, hasWorkspace: true, isCancelled: true
            ),
            .abandon
        )
    }

    func test_reconnectStep_abandonsWhenEveryConditionFails() {
        XCTAssertEqual(
            PeerWorkspaceMirrorController.reconnectStep(
                isTornDown: true, hasWorkspace: false, isCancelled: true
            ),
            .abandon
        )
    }

    func test_reconnectStep_abandonsWhenHostLeaseWasRetired() {
        XCTAssertEqual(
            PeerWorkspaceMirrorController.reconnectStep(
                isTornDown: false, hasWorkspace: true, isCancelled: false,
                hostLeaseIsActive: false
            ),
            .abandon
        )
    }

    /// A resume that was superseded — cancelled by a newer resume, or whose
    /// lease has moved on — must stay silent: reporting its failure used to
    /// clear the replacement's fresh subscription and cancel its reconnect
    /// task (the clobber both panel review runs flagged).
    func test_supersededResumeNeverReportsItsOutcome() {
        XCTAssertTrue(PeerWorkspaceMirrorController.resumeOutcomeMayReport(
            isCancelled: false, leaseIsCurrent: true
        ))
        XCTAssertFalse(PeerWorkspaceMirrorController.resumeOutcomeMayReport(
            isCancelled: true, leaseIsCurrent: true
        ), "cancellation means a newer resume owns the controller now")
        XCTAssertFalse(PeerWorkspaceMirrorController.resumeOutcomeMayReport(
            isCancelled: false, leaseIsCurrent: false
        ), "a moved lease means this resume's observation is about dead state")
    }

    /// The deeper half of the superseded-resume defense: the outcome gate
    /// stops the REPORT, but the mutations happen inside `start()` itself —
    /// installing the session and cancelling the current receive task. These
    /// pin the commit-point contract: a start attempt that was torn down,
    /// whose dialed lease moved, or whose task was cancelled must not commit
    /// what it acquired (it closes its own transport instead).
    func test_supersededStartAttemptMayNotCommit() {
        XCTAssertTrue(PeerWorkspaceMirrorController.startAttemptMayCommit(
            isTornDown: false, dialedLeaseIsCurrent: true, isCancelled: false
        ))
        XCTAssertFalse(PeerWorkspaceMirrorController.startAttemptMayCommit(
            isTornDown: true, dialedLeaseIsCurrent: true, isCancelled: false
        ), "a torn-down controller must not be given a live session back")
        XCTAssertFalse(PeerWorkspaceMirrorController.startAttemptMayCommit(
            isTornDown: false, dialedLeaseIsCurrent: false, isCancelled: false
        ), "the replacement's fresh state is not this attempt's to overwrite")
        XCTAssertFalse(PeerWorkspaceMirrorController.startAttemptMayCommit(
            isTornDown: false, dialedLeaseIsCurrent: true, isCancelled: true
        ))
    }
}
