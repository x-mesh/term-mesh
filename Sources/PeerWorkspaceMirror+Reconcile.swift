//  Reconcile engine for the live workspace mirror (Phase 2B).
//
//  Every host push is a FULL layout snapshot; this engine reshapes the
//  local bonsplit tree to match while preserving TerminalPanel /
//  TerminalSurface identity (PTY continuity) for every surviving leaf.
//
//  Strategy: two fast paths, then collapse+rebuild.
//   fast 0  no-op        — layout equivalent to last applied (covers our
//                          own forwarded-op echoes once converged)
//   fast 1  divider-only — same shape/leaves, only ratios changed →
//                          setDividerPosition(fromExternal:) via the
//                          hostSplitToLocal map
//   full    structural   — Phase A (async, NO tree mutation): attach
//                          sessions for missing leaves. Phase B (sync,
//                          MainActor, remote-application flag set):
//                          B1 move every surviving tab into one anchor
//                             pane (emptied panes auto-collapse —
//                             bonsplit closes them without delegate
//                             round-trips)
//                          B2 spawn missing leaves as fresh remote-pane
//                             tabs in the anchor
//                          B3 close stale panels (spawn-before-close
//                             keeps the workspace non-empty throughout)
//                          B4 pre-order rebuild: each split pulls the
//                             second subtree's first-leaf tab out with
//                             splitPane(movingTab:) — the anchor holds
//                             N tabs and suffers N−1 pulls, so it can
//                             never empty mid-rebuild
//                          B5 divider ratios (fromExternal) + rebuild
//                             the hostSplitID → local split UUID map
//
//  Idempotence: reconcile always starts from the ACTUAL current tree,
//  so a dropped host push (Rust try_send) self-heals on the next one.

import AppKit
import Bonsplit
import PeerProto

extension PeerWorkspaceMirrorController {

    // MARK: - Entry point

    func reconcile(target: Termmesh_Peer_V1_WorkspaceLayout) async throws {
        guard let workspace, !isTornDown else { return }

        // Fast paths below must only fire once every target leaf is
        // actually mirrored — see `allTargetLeavesMapped`.
        let targetLeaves = Self.preorderLeaves(target)
        let allLeavesMapped = Self.allTargetLeavesMapped(targetLeaves, panelBySurfaceID: panelBySurfaceID)

        if let last = lastAppliedLayout, allLeavesMapped {
            if Self.layoutsEquivalent(last, target) {
                recordApplied(target)
                return
            }
            if Self.isDividerOnlyDelta(last, target), !hostSplitToLocal.isEmpty {
                applyDividerFastPath(target: target, workspace: workspace)
                recordApplied(target)
                return
            }
        }

        // ── Phase A (async, no tree mutation): sessions for new leaves.
        guard !targetLeaves.isEmpty else { return }
        let activeIDs = Set(targetLeaves.map(\.surfaceID))
        let missing = targetLeaves.filter { panelBySurfaceID[$0.surfaceID] == nil }
        var newSessions: [Data: PeerPaneSession] = [:]
        for leaf in missing {
            do {
                let session = try await PeerPaneSession.attach(
                    lease: lease,
                    surface: Self.surfaceInfo(fromLeaf: leaf),
                    title: leaf.title,
                    spec: spec
                )
                newSessions[leaf.surfaceID] = session
            } catch {
                NSLog("[peer-mirror] leaf attach failed (skipping until next push): %@",
                      String(describing: error))
            }
        }
        do {
            try Task.checkCancellation()
        } catch {
            // A newer push superseded us — release what we attached.
            for (_, session) in newSessions { session.teardown() }
            throw error
        }
        guard let workspace2 = self.workspace, !isTornDown else {
            for (_, session) in newSessions { session.teardown() }
            return
        }

        // ── Phase B (synchronous, MainActor — atomic wrt user events).
        let focusedBefore = workspace2.focusedPanelId
        withRemoteApplication {
            workspace2.isProgrammaticSplit = true
            defer { workspace2.isProgrammaticSplit = false }

            let controller = workspace2.bonsplitController

            // Anchor: pane holding the first target leaf's tab, else first pane.
            let anchor = anchorPane(for: targetLeaves, in: workspace2) ?? controller.allPaneIds.first
            guard let anchor else { return }

            // B1 — collapse: everything into the anchor.
            for pane in controller.allPaneIds where pane != anchor {
                for tab in controller.tabs(inPane: pane) {
                    _ = controller.moveTab(tab.id, toPane: anchor)
                }
            }

            // B2 — spawn missing leaves as remote-pane tabs in the anchor.
            for leaf in missing {
                guard let session = newSessions[leaf.surfaceID] else { continue }
                guard let panel = workspace2.newRemoteTerminalTab(
                    inPane: anchor,
                    command: session.relayLaunchCommand,
                    environment: session.relayEnvironment
                ) else {
                    session.teardown()
                    continue
                }
                workspace2.bindRemotePane(session: session, to: panel)
                panelBySurfaceID[leaf.surfaceID] = panel.id
            }

            // B3 — close stale panels (their sessions tear down via
            // TerminalPanel.close()).
            for (sid, panelId) in panelBySurfaceID where !activeIDs.contains(sid) {
                _ = workspace2.closePanel(panelId, force: true)
                panelBySurfaceID.removeValue(forKey: sid)
            }
            // Defensive: drop any tab with no panel mapping (bonsplit
            // "Empty" placeholders can only appear through future code
            // paths — sweep them so the rebuild math stays exact).
            for tab in controller.tabs(inPane: anchor)
                where workspace2.panelIdFromSurfaceId(tab.id) == nil
            {
                _ = controller.closeTab(tab.id, inPane: anchor)
            }

            // B3b — reap panels displaced by markAllPanesStale() (resync /
            // reconnect). That wiped panelBySurfaceID before this reconcile,
            // so the loop above never sees them; closing here — after B2
            // spawned their replacements — preserves spawn-before-close and
            // frees each old pane's relay helper process (v0.159 relay leak).
            for panelId in pendingStalePanelIds {
                _ = workspace2.closePanel(panelId, force: true)
            }
            pendingStalePanelIds.removeAll()

            // B4 — pre-order rebuild.
            buildSplits(node: target, currentPane: anchor, workspace: workspace2)

            // B5 — divider ratios + host→local split map.
            hostSplitToLocal.removeAll()
            Self.walkParallel(host: target, local: controller.treeSnapshot()) { hostSplit, localSplitId in
                self.hostSplitToLocal[hostSplit.splitID] = localSplitId
                if hostSplit.dividerPosition > 0, hostSplit.dividerPosition < 1 {
                    _ = controller.setDividerPosition(
                        CGFloat(hostSplit.dividerPosition),
                        forSplit: localSplitId,
                        fromExternal: true
                    )
                }
            }
        }

        // Post-reconcile healing: reparented portal views + focus.
        for (_, panelId) in panelBySurfaceID {
            workspace2.terminalPanel(for: panelId)?.requestViewReattach()
        }
        if let focusedBefore, workspace2.panels[focusedBefore] != nil {
            workspace2.focusPanel(focusedBefore)
        } else if let first = targetLeaves.first,
                  let panelId = panelBySurfaceID[first.surfaceID]
        {
            workspace2.focusPanel(panelId)
        }

        recordApplied(target)
        #if DEBUG
        dlog("peer.mirror.reconcile leaves=\(targetLeaves.count) spawned=\(newSessions.count) shape=\(Self.shapeHash(target))")
        #endif
        // The shape hash is what makes this readable as a sequence: two
        // reconciles with the same hash mean the layout settled, and a hash
        // that keeps changing with nothing spawned means it is flapping.
        RemoteWorkLog.debugOffMain(
            "Layout synced — \(targetLeaves.count) pane(s), \(newSessions.count) spawned, shape \(Self.shapeHash(target))"
        )
    }

    // MARK: - Divider fast path

    private func applyDividerFastPath(
        target: Termmesh_Peer_V1_WorkspaceLayout,
        workspace: Workspace
    ) {
        withRemoteApplication {
            Self.walkHostSplits(target) { hostSplit in
                guard let localId = hostSplitToLocal[hostSplit.splitID],
                      hostSplit.dividerPosition > 0, hostSplit.dividerPosition < 1
                else { return }
                _ = workspace.bonsplitController.setDividerPosition(
                    CGFloat(hostSplit.dividerPosition),
                    forSplit: localId,
                    fromExternal: true
                )
            }
        }
    }

    // MARK: - Rebuild recursion

    private func buildSplits(
        node: Termmesh_Peer_V1_WorkspaceLayout,
        currentPane: PaneID,
        workspace: Workspace
    ) {
        guard case .split(let split) = node.node else { return }
        guard let secondLeaf = Self.firstLeaf(split.second),
              let panelId = panelBySurfaceID[secondLeaf.surfaceID],
              let tabId = workspace.surfaceIdFromPanelId(panelId)
        else {
            // Second subtree's seed leaf failed to attach — flatten:
            // keep first subtree in the current pane, skip the split.
            buildSplits(node: split.first, currentPane: currentPane, workspace: workspace)
            return
        }
        let orientation = SplitOrientation(rawValue: split.orientation) ?? .horizontal
        guard let newPane = workspace.bonsplitController.splitPane(
            currentPane,
            orientation: orientation,
            movingTab: tabId,
            insertFirst: false
        ) else {
            buildSplits(node: split.first, currentPane: currentPane, workspace: workspace)
            return
        }
        buildSplits(node: split.first, currentPane: currentPane, workspace: workspace)
        buildSplits(node: split.second, currentPane: newPane, workspace: workspace)
    }

    private func anchorPane(
        for leaves: [Termmesh_Peer_V1_WorkspacePane],
        in workspace: Workspace
    ) -> PaneID? {
        guard let first = leaves.first,
              let panelId = panelBySurfaceID[first.surfaceID],
              let tabId = workspace.surfaceIdFromPanelId(panelId)
        else { return nil }
        for pane in workspace.bonsplitController.allPaneIds {
            if workspace.bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }) {
                return pane
            }
        }
        return nil
    }

    // MARK: - Pure helpers (unit-tested)

    nonisolated static func preorderLeaves(
        _ node: Termmesh_Peer_V1_WorkspaceLayout
    ) -> [Termmesh_Peer_V1_WorkspacePane] {
        switch node.node {
        case .pane(let pane): return [pane]
        case .split(let split):
            return preorderLeaves(split.first) + preorderLeaves(split.second)
        case .none: return []
        }
    }

    nonisolated static func firstLeaf(
        _ node: Termmesh_Peer_V1_WorkspaceLayout
    ) -> Termmesh_Peer_V1_WorkspacePane? {
        preorderLeaves(node).first
    }

    /// True when every target leaf already has a mirrored local panel.
    /// The no-op/divider-only fast paths in `reconcile` must only fire
    /// when this holds — otherwise a leaf whose attach failed on a
    /// prior pass (see the `missing` loop above) would never get
    /// retried, because an identical subsequent host push would keep
    /// short-circuiting before Phase A/B ever runs again.
    nonisolated static func allTargetLeavesMapped(
        _ leaves: [Termmesh_Peer_V1_WorkspacePane],
        panelBySurfaceID: [Data: UUID]
    ) -> Bool {
        leaves.allSatisfy { panelBySurfaceID[$0.surfaceID] != nil }
    }

    /// Structure + leaf surfaceIDs + divider ratios (ε) all match —
    /// nothing to do. Title-only changes are equivalent (pane titles
    /// flow through the relay byte stream, not the layout).
    nonisolated static func layoutsEquivalent(
        _ a: Termmesh_Peer_V1_WorkspaceLayout,
        _ b: Termmesh_Peer_V1_WorkspaceLayout,
        epsilon: Double = 0.005
    ) -> Bool {
        switch (a.node, b.node) {
        case (.pane(let pa), .pane(let pb)):
            return pa.surfaceID == pb.surfaceID
        case (.split(let sa), .split(let sb)):
            return sa.orientation == sb.orientation
                && abs(sa.dividerPosition - sb.dividerPosition) <= epsilon
                && layoutsEquivalent(sa.first, sb.first, epsilon: epsilon)
                && layoutsEquivalent(sa.second, sb.second, epsilon: epsilon)
        default:
            return false
        }
    }

    /// Same shape + same leaves (+ stable split ids); only divider
    /// ratios may differ. Ported from the relay window's
    /// isDividerOnlyDelta, minus tab/title comparisons (v1 mirrors the
    /// active tab only, and titles ride the byte stream).
    nonisolated static func isDividerOnlyDelta(
        _ a: Termmesh_Peer_V1_WorkspaceLayout,
        _ b: Termmesh_Peer_V1_WorkspaceLayout
    ) -> Bool {
        switch (a.node, b.node) {
        case (.pane(let pa), .pane(let pb)):
            return pa.surfaceID == pb.surfaceID
        case (.split(let sa), .split(let sb)):
            return sa.orientation == sb.orientation
                && !sa.splitID.isEmpty
                && sa.splitID == sb.splitID
                && isDividerOnlyDelta(sa.first, sb.first)
                && isDividerOnlyDelta(sa.second, sb.second)
        default:
            return false
        }
    }

    /// Lockstep walk of the host layout and the freshly-rebuilt local
    /// tree (shape-isomorphic by construction). Mismatched shapes just
    /// stop descending — the next reconcile self-heals.
    nonisolated static func walkParallel(
        host: Termmesh_Peer_V1_WorkspaceLayout,
        local: ExternalTreeNode,
        visit: (Termmesh_Peer_V1_WorkspaceSplit, UUID) -> Void
    ) {
        guard case .split(let hostSplit) = host.node,
              case .split(let localSplit) = local,
              let localId = UUID(uuidString: localSplit.id)
        else { return }
        visit(hostSplit, localId)
        walkParallel(host: hostSplit.first, local: localSplit.first, visit: visit)
        walkParallel(host: hostSplit.second, local: localSplit.second, visit: visit)
    }

    /// Outbound divider diff: walk the last host layout against the
    /// live local tree; visit every shape-matched split pair, flag any
    /// shape divergence (someone mutated the tree outside the
    /// reconciler → caller resyncs).
    nonisolated static func walkParallelSplits(
        host: Termmesh_Peer_V1_WorkspaceLayout,
        local: ExternalTreeNode,
        visit: (Termmesh_Peer_V1_WorkspaceSplit, ExternalSplitNode) -> Void,
        onMismatch: () -> Void
    ) {
        switch (host.node, local) {
        case (.pane, .pane):
            return
        case (.split(let hostSplit), .split(let localSplit)):
            visit(hostSplit, localSplit)
            walkParallelSplits(host: hostSplit.first, local: localSplit.first,
                               visit: visit, onMismatch: onMismatch)
            walkParallelSplits(host: hostSplit.second, local: localSplit.second,
                               visit: visit, onMismatch: onMismatch)
        default:
            onMismatch()
        }
    }

    nonisolated static func walkHostSplits(
        _ node: Termmesh_Peer_V1_WorkspaceLayout,
        visit: (Termmesh_Peer_V1_WorkspaceSplit) -> Void
    ) {
        guard case .split(let split) = node.node else { return }
        visit(split)
        walkHostSplits(split.first, visit: visit)
        walkHostSplits(split.second, visit: visit)
    }

    /// Compact structural fingerprint for debug/e2e assertions.
    nonisolated static func shapeHash(_ node: Termmesh_Peer_V1_WorkspaceLayout) -> String {
        switch node.node {
        case .pane(let pane):
            return "p[\(pane.surfaceID.prefix(4).map { String(format: "%02x", $0) }.joined())]"
        case .split(let split):
            let o = split.orientation.hasPrefix("h") ? "h" : "v"
            return "\(o)(\(shapeHash(split.first)),\(shapeHash(split.second)))"
        case .none:
            return "∅"
        }
    }

    nonisolated static func surfaceInfo(
        fromLeaf leaf: Termmesh_Peer_V1_WorkspacePane
    ) -> Termmesh_Peer_V1_SurfaceInfo {
        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = leaf.surfaceID
        info.title = leaf.title
        info.cols = leaf.cols
        info.rows = leaf.rows
        info.attachable = true
        return info
    }
}
