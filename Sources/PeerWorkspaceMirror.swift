//  PeerWorkspaceMirrorController: Phase 2B live workspace mirror.
//
//  One controller per mirrored workspace. The HOST owns the layout: local
//  structural actions (split/close/new-tab/divider) are forwarded as
//  fire-and-forget WorkspaceControl requests and NOT applied locally; the
//  host broadcasts the resulting `WorkspaceLayoutChanged` full snapshot
//  (to every session, including us — the echo IS the application), and the
//  reconciler reshapes the local bonsplit tree to match.
//
//  Data plane stays Phase 1: every mirrored leaf is a normal remote pane
//  (`PeerPaneSession`, owned relay session, lease-refcounted). This
//  controller adds only the layout-sync plane:
//    subscription session  — layout pushes in, control requests out,
//                            heartbeat (10s/30s). Control requests are
//                            pure writes, safe to send outside the
//                            receive loop; RPCs (handshake/listWorkspaces)
//                            happen only before the loop starts or after
//                            it exits (D1: no response correlation).
//    reconciler            — PeerWorkspaceMirror+Reconcile.swift.
//
//  Reconnect is driven by the receive loop exiting / heartbeat death —
//  NOT by `lease.tunnel.onStateChange`, which is a single-slot closure on
//  a POOLED tunnel that other consumers may need.

import AppKit
import Bonsplit
import PeerProto

@MainActor
final class PeerWorkspaceMirrorController {
    weak var workspace: Workspace?
    private(set) var lease: PeerPaneHostLease
    let spec: PeerPaneHostSpec
    /// Current host-owned identity. A single-workspace host may mint a new ID
    /// after daemon restart; reconnect adoption updates this value so inbound
    /// routing, outbound controls, sidebar state, and open dedupe stay aligned.
    private(set) var hostWorkspaceID: Data
    /// Every host-owned identity observed for this mirror. A direct host keeps
    /// the same socket path across daemon restarts, so RemoteHostStore may
    /// temporarily rebuild the sidebar from a cached summary carrying an older
    /// workspace ID. Keep those IDs as lookup aliases while wire routing uses
    /// only `hostWorkspaceID` above.
    private(set) var hostWorkspaceIDAliases: Set<Data>
    let hostWorkspaceTitle: String
    let connectedAt = Date()
    /// Pooled SSH generation used by the current subscription. A dead mirror
    /// must refresh this generation before dialing again; otherwise the local
    /// Unix socket still accepts connections while its stopped ssh process can
    /// never answer the handshake.
    private var subscriptionTransportGeneration: UInt64 = 0

    /// Last layout we reconciled to — the baseline for no-op/divider-only
    /// fast paths and for outbound divider diffs.
    private(set) var lastAppliedLayout: Termmesh_Peer_V1_WorkspaceLayout?
    /// `lastAppliedLayout` as it stood when a reconnect cleared it to force
    /// the full reconcile path. Only reconcile's drop diagnostics read it:
    /// naming the panes a host push removed needs a baseline, and the
    /// reconnect is the very path that has to clear the real one.
    var dropDiagnosticsBaseline: Termmesh_Peer_V1_WorkspaceLayout?
    /// Wire surfaceID → local TerminalPanel.id for every mirrored leaf.
    var panelBySurfaceID: [Data: UUID] = [:]
    /// Host split id bytes → local bonsplit split UUID. Rebuilt on every
    /// structural reconcile; consumed by divider fast path + outbound diff.
    var hostSplitToLocal: [Data: UUID] = [:]
    /// Panels displaced by `markAllPanesStale()` (resync / reconnect),
    /// captured before the map is wiped so `reconcile` can reap them AFTER
    /// spawning their replacements (spawn-before-close). Without this,
    /// wiping the map leaves B3's stale-close loop nothing to iterate, so
    /// the old panels survive as orphaned ghost tabs — each retaining a
    /// dead `term-mesh-peer-relay` helper process (the v0.159 relay leak).
    /// Internal (not private): reaped by `reconcile` in the +Reconcile file.
    var pendingStalePanelIds: [UUID] = []

    private var subscriptionTransport: UnixSocketTransport?
    private var subscriptionSession: PeerSession?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Apply serialization (relay-window pattern): one reconcile at a
    /// time; a newer push cancels a stale queued one.
    private var applyTask: Task<Void, Never>?
    /// True while the reconciler mutates the bonsplit tree — gates every
    /// veto/forwarding hook so remote application never echoes back out.
    private(set) var isApplyingRemoteLayout = false
    /// Outbound divider debounce, keyed by HOST split id.
    private var dividerDebounce: [Data: Task<Void, Never>] = [:]
    private var resyncScheduled = false
    private(set) var isTornDown = false
    private(set) var subscriptionAlive = false

    var connectionInfo: PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(self),
            kind: .workspace,
            hostSockPath: lease.hostSockPath,
            hostDisplayName: lease.hostDisplayName,
            sshTarget: lease.key.sshTarget,
            sshPort: lease.tunnel?.port,
            identityFile: lease.tunnel?.identityFile,
            remoteSockPath: lease.key.remoteSockPath,
            targetTitle: hostWorkspaceTitle.isEmpty ? "<workspace>" : hostWorkspaceTitle,
            connectedAt: connectedAt
        )
    }

    init(
        workspace: Workspace,
        lease: PeerPaneHostLease,
        spec: PeerPaneHostSpec,
        hostWorkspaceID: Data,
        hostWorkspaceTitle: String
    ) {
        self.workspace = workspace
        self.lease = lease
        self.spec = spec
        self.hostWorkspaceID = hostWorkspaceID
        self.hostWorkspaceIDAliases = [hostWorkspaceID]
        self.hostWorkspaceTitle = hostWorkspaceTitle
    }

    // MARK: - Subscription lifecycle

    /// Connect the subscription session, reconcile to the freshest host
    /// layout, and start the receive loop. RPCs here run BEFORE the loop
    /// exists, so the single-reader invariant holds.
    /// Handshake options for every mirror-side session: everything this
    /// build supports EXCEPT grid.snapshot.v1. The mirror's PtyData reaches
    /// panes through `PeerSessionDemux`, which carries `PeerPtyChunk` only —
    /// a typed GridSnapshot would be classified and then dropped on the
    /// demux floor, leaving every mirrored pane's initial screen blank.
    /// Not advertising keeps the host on the untyped PtyData snapshot path,
    /// which the demux forwards like any other bytes. Lift this only
    /// together with a demux channel for typed frames.
    ///
    /// `surface.agent.v1` is also withheld: the mirror path renders agent
    /// surfaces nowhere (attachShared has no callback delivery), so not
    /// advertising keeps the host's demotion (attachable=false + attach
    /// refusal) as the protocol-level guard, independent of the daemon's
    /// layout-side agent exclusion. Lift together with mirror agent panes.
    private static var mirrorHandshakeOptions: PeerSessionOptions {
        PeerSessionOptions(
            capabilities: PeerCapability.supported.filter {
                $0 != PeerCapability.gridSnapshotV1 && $0 != PeerCapability.surfaceAgentV1
            }
        )
    }

    func start() async throws {
        // Capture the lease this attempt dials. Every await below is a
        // window for a newer resume to cancel this task and move the
        // controller onto a replacement lease, or for teardown to retire
        // it — and the outcome gate at the call sites runs only AFTER the
        // assignments here. The commit-point guards below are therefore
        // the only thing standing between a late-resuming attempt and
        // overwriting the replacement's fresh session (or re-installing
        // one on a torn-down controller).
        let dialedLease = lease
        subscriptionTransportGeneration = dialedLease.transportGeneration
        let transport = try await UnixSocketTransport.connect(socketPath: dialedLease.hostSockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake(options: Self.mirrorHandshakeOptions)
        guard Self.startAttemptMayCommit(
            isTornDown: isTornDown,
            dialedLeaseIsCurrent: lease === dialedLease,
            isCancelled: Task.isCancelled
        ) else {
            // Resources this attempt acquired are its own to release: a
            // superseded or torn-down controller must not inherit an
            // orphan connection.
            await transport.close()
            throw CancellationError()
        }
        subscriptionTransport = transport
        subscriptionSession = session
        subscriptionAlive = true

        // Hung-connection detection: a dead transport unblocks the
        // receive loop's read with an error, entering the reconnect path.
        let weakTransport = transport
        await session.startHeartbeat(
            intervalSeconds: 10,
            deadAfterSeconds: 30,
            onFirstMiss: {
                #if DEBUG
                dlog("peer.mirror.heartbeat.firstMiss — subscription pong overdue (output backpressure starving the shared receive loop?)")
                #endif
            },
            onMissRecovered: {
                #if DEBUG
                dlog("peer.mirror.heartbeat.recovered")
                #endif
            }
        ) {
            #if DEBUG
            dlog("peer.mirror.heartbeat.dead — no pong for 30s, closing subscription transport (ALL mirrored panes in this workspace will drop)")
            #endif
            Task { await weakTransport.close() }
        }

        let workspaces = try await session.listWorkspaces()
        // Guarded BEFORE matchAndAdoptWorkspace and reconcile, not only
        // after: matchAndAdoptWorkspace stamps the mirrored identity
        // (hostWorkspaceID + aliases, plus an identity-change notification)
        // and reconcile mutates panes and the split tree — stale writes the
        // final guard cannot roll back. A supersede landing DURING
        // reconcile's own awaits still slips through; that residue is
        // corrected by the replacement's reconcile converging the same
        // workspace, and the initial call site treats this refusal as
        // supersession rather than failure.
        guard Self.startAttemptMayCommit(
            isTornDown: isTornDown,
            dialedLeaseIsCurrent: lease === dialedLease,
            isCancelled: Task.isCancelled
        ) else {
            await session.stopHeartbeat()
            await transport.close()
            throw CancellationError()
        }
        guard let target = matchAndAdoptWorkspace(workspaces) else {
            throw RelayError.ioError("host workspace not found")
        }
        try await reconcile(target: target.layout)
        // Re-checked after the last awaits: `startReceiveLoop` CANCELS the
        // current receive task, so a superseded attempt reaching it would
        // kill the replacement's loop even though its own session is no
        // longer installed. Stop only what this attempt owns.
        guard Self.startAttemptMayCommit(
            isTornDown: isTornDown,
            dialedLeaseIsCurrent: lease === dialedLease,
            isCancelled: Task.isCancelled
        ) else {
            await session.stopHeartbeat()
            await transport.close()
            throw CancellationError()
        }
        startReceiveLoop(session: session)
    }

    /// Whether an in-flight `start()` may still commit state it acquired.
    /// Pure so the commit-point contract is pinned by a test rather than by
    /// whoever edits the suspension points next.
    nonisolated static func startAttemptMayCommit(
        isTornDown: Bool,
        dialedLeaseIsCurrent: Bool,
        isCancelled: Bool
    ) -> Bool {
        !isTornDown && dialedLeaseIsCurrent && !isCancelled
    }

    /// Pure routing decision for one incoming message, keyed against the
    /// workspace this controller mirrors. Extracted from the receive loop
    /// below so `PeerWorkspaceMirrorTests` can exercise the branching
    /// (including "foreign workspace removed is ignored") without a live
    /// `PeerSession` + `Workspace` + AppKit stack.
    enum ReceiveLoopAction: Equatable {
        case applyLayout(Termmesh_Peer_V1_WorkspaceLayout)
        /// Our own mirrored workspace was deleted on the host. Must NOT
        /// route through `handleConnectionLost`/`reconnectLoop` — the
        /// workspace is gone for good, so reconnecting would just
        /// rediscover the same absence. Reuses the `markHostWorkspaceGone()`
        /// path that `reconnectLoop`/`forceResync` already use for that
        /// same "workspace not found" outcome.
        case hostGone
        case lost(reason: String)
        case ignore
    }

    nonisolated static func receiveLoopAction(
        for msg: PeerIncomingMessage,
        hostWorkspaceID: Data
    ) -> ReceiveLoopAction {
        switch msg {
        case .workspaceLayoutChanged(let wid, let layout) where wid == hostWorkspaceID:
            return .applyLayout(layout)
        case .workspaceRemoved(let wid) where wid == hostWorkspaceID:
            return .hostGone
        case .goodbye(let reason):
            return .lost(reason: "host closed connection: \(reason)")
        default:
            return .ignore
        }
    }

    private func startReceiveLoop(session: PeerSession) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            var lostReason: String?
            var hostGone = false
            while let self, !Task.isCancelled, !self.isTornDown {
                let msg: PeerIncomingMessage
                do {
                    msg = try await session.receiveNextMessage()
                } catch {
                    lostReason = String(describing: error)
                    break
                }
                if case .error(let code, let message) = msg {
                    #if DEBUG
                    dlog("peer.mirror.error code=\(code) msg=\(message)")
                    #endif
                    // The host refusing something is its own event: the loop
                    // carries on afterwards, so without a line here the only
                    // evidence is whatever silently failed to happen.
                    RemoteWorkLog.infoOffMain("Host refused a workspace request (\(code)): \(message)")
                }
                switch Self.receiveLoopAction(for: msg, hostWorkspaceID: self.hostWorkspaceID) {
                case .applyLayout(let layout):
                    self.scheduleApply(layout)
                case .hostGone:
                    hostGone = true
                case .lost(let reason):
                    lostReason = reason
                case .ignore:
                    break
                }
                if hostGone || lostReason != nil { break }
            }
            guard let self, !self.isTornDown, self.subscriptionSession === session else { return }
            if hostGone {
                self.markHostWorkspaceGone()
            } else if let reason = lostReason {
                self.handleConnectionLost(reason: reason)
            }
        }
    }

    private func scheduleApply(_ layout: Termmesh_Peer_V1_WorkspaceLayout) {
        let previous = applyTask
        previous?.cancel()
        applyTask = Task { [weak self] in
            await previous?.value
            guard let self, !self.isTornDown, !Task.isCancelled else { return }
            do {
                try await self.reconcile(target: layout)
            } catch is CancellationError {
                // superseded by a newer push
            } catch {
                NSLog("[peer-mirror] reconcile failed: %@", String(describing: error))
                RemoteWorkLog.infoOffMain("Workspace layout sync failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Local → host forwarding (fire-and-forget writes)

    /// Wire surface id for a local panel, from its Phase-1 session.
    func wireSurfaceID(forPanelId panelId: UUID) -> Data? {
        guard let workspace,
              let panel = workspace.terminalPanel(for: panelId),
              let session = panel.peerPaneSession
        else { return nil }
        return session.originSurface.surfaceID
    }

    func forwardSplit(panelId: UUID, orientation: SplitOrientation) {
        guard let sid = wireSurfaceID(forPanelId: panelId),
              let session = subscriptionSession else { return }
        #if DEBUG
        dlog("peer.mirror.forward split panel=\(panelId.uuidString.prefix(5)) orient=\(orientation.rawValue)")
        #endif
        Task { try? await session.requestSplitPane(paneID: sid, orientation: orientation.rawValue) }
    }

    func forwardClose(panelId: UUID) {
        guard let sid = wireSurfaceID(forPanelId: panelId),
              let session = subscriptionSession else { return }
        #if DEBUG
        dlog("peer.mirror.forward close panel=\(panelId.uuidString.prefix(5))")
        #endif
        Task { try? await session.requestClosePane(paneID: sid) }
    }

    func forwardNewTab(panelId: UUID) {
        guard let sid = wireSurfaceID(forPanelId: panelId),
              let session = subscriptionSession else { return }
        Task { try? await session.requestNewTab(paneID: sid) }
    }

    /// Debounced (150ms per host split) so a whole drag coalesces into
    /// one request — mirrors the relay window's cadence against the
    /// host's own 120ms broadcast debounce.
    func forwardDivider(hostSplitID: Data, ratio: Double) {
        guard subscriptionSession != nil else { return }
        dividerDebounce[hostSplitID]?.cancel()
        dividerDebounce[hostSplitID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, !self.isTornDown,
                  let session = self.subscriptionSession else { return }
            #if DEBUG
            dlog("peer.mirror.forward divider ratio=\(String(format: "%.3f", ratio))")
            #endif
            try? await session.requestSetDivider(workspaceID: self.hostWorkspaceID, splitID: hostSplitID, ratio: ratio)
        }
    }

    /// Called from didChangeGeometry when the user (not the reconciler)
    /// changed geometry: forward divider ratios that diverged from the
    /// last host layout; resync on shape divergence.
    func handleLocalGeometryChange() {
        guard !isApplyingRemoteLayout, !isTornDown,
              let workspace, let last = lastAppliedLayout else { return }
        var mismatch = false
        Self.walkParallelSplits(
            host: last,
            local: workspace.bonsplitController.treeSnapshot(),
            visit: { hostSplit, localSplit in
                guard !hostSplit.splitID.isEmpty else { return }
                let delta = abs(hostSplit.dividerPosition - localSplit.dividerPosition)
                if delta > 0.005 {
                    self.forwardDivider(
                        hostSplitID: hostSplit.splitID,
                        ratio: localSplit.dividerPosition
                    )
                }
            },
            onMismatch: { mismatch = true }
        )
        if mismatch { scheduleResync() }
    }

    // MARK: - Resync

    /// Snap the local tree back to the last authoritative layout — used
    /// when an un-vetoable local mutation slips through (tab drag) or an
    /// outbound diff finds a shape mismatch.
    func scheduleResync() {
        guard !isApplyingRemoteLayout, !isTornDown, !resyncScheduled,
              let layout = lastAppliedLayout else { return }
        resyncScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.resyncScheduled = false
            self.scheduleApply(layout)
        }
    }

    /// Full respawn: every pane session is presumed dead (reconnect) —
    /// clear the leaf map so the reconciler treats all target leaves as
    /// missing and all current panels as stale.
    ///
    /// Runs `listWorkspaces()` on a throwaway one-shot connection rather
    /// than the live `subscriptionSession`. This can fire while that
    /// session's receive loop is still running (e.g. a single mirrored
    /// pane's own disconnect banner "Reconnect", independent of the
    /// layout-sync subscription's health), and `listWorkspaces()` is a
    /// response-waiting RPC — sharing the session with `readFrame()` in
    /// `startReceiveLoop` would let the two reads consume each other's
    /// frames (single-reader invariant, see file header / D1). A fresh
    /// connection sidesteps that by construction: it never starts a
    /// receive loop of its own.
    func forceResync() async {
        guard !isTornDown, subscriptionSession != nil else { return }
        do {
            let transport = try await UnixSocketTransport.connect(socketPath: lease.hostSockPath)
            let oneShot = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            _ = try await oneShot.handshake(options: Self.mirrorHandshakeOptions)
            let workspaces = try await oneShot.listWorkspaces()
            try? await oneShot.sendGoodbye(reason: "resync probe")
            await transport.close()
            guard !isTornDown else { return }
            guard let target = matchAndAdoptWorkspace(workspaces) else {
                markHostWorkspaceGone()
                return
            }
            markAllPanesStale()
            try await reconcile(target: target.layout)
        } catch {
            NSLog("[peer-mirror] forceResync failed: %@", String(describing: error))
            RemoteWorkLog.infoOffMain("Workspace resync failed: \(error.localizedDescription)")
        }
    }

    func markAllPanesStale() {
        // Leaving panelBySurfaceID intact but flagging respawn is more
        // complex than it's worth: dropping the map makes every target
        // leaf "missing" (fresh spawn) and every mapped panel unmatched
        // (stale close) in one reconcile pass.
        //
        // But dropping the map also erases B3's only handle to these
        // panels, so snapshot them first — `reconcile` closes them once
        // it has spawned their replacements (B3b), reaping each old pane's
        // relay helper process instead of orphaning it as a ghost tab.
        //
        // Measure what the wipe costs before deciding it is cheap. Pane
        // relay recovery (`PeerRelaySession`'s "Remote pane reconnected on
        // attempt N") runs independently of this mirror-level reconnect and
        // frequently WINS it — the panes are back, and then this runs and
        // discards them anyway, respawning a helper process and a Ghostty
        // surface for each while closing the working one. That is invisible
        // today: the log shows a respawn either way, so a reconnect that
        // threw away four healthy panes reads exactly like one that
        // recovered four dead ones.
        let live = liveMirroredPaneCount()
        if live > 0 {
            RemoteWorkLog.debugOffMain(
                "Mirror resync discards \(live) live pane(s) of \(panelBySurfaceID.count)"
                    + " — each is respawned even though its relay had recovered"
            )
        }
        // Everything is being respawned, so any pane this deadline was still
        // waiting on is already handled — and its mapping is gone, which is
        // the exact staleness `respawnPanesThatNeverRecovered` guards against.
        recoveringPaneWatchdog?.cancel()
        recoveringPaneWatchdog = nil
        lastResyncKept = 0
        lastResyncWatching = 0
        lastResyncRespawned = panelBySurfaceID.count
        pendingStalePanelIds.append(contentsOf: panelBySurfaceID.values)
        panelBySurfaceID.removeAll()
        hostSplitToLocal.removeAll()
    }

    /// Mirrored panes whose transport is up right now.
    ///
    /// Reads `isRelayLive`, not `isRelayStarted`: the latter latches at the
    /// first successful start, so counting it would report every pane that
    /// EVER worked as live and make this measurement — whose whole job is to
    /// say what the wipe costs — read the same whether the wipe cost four
    /// working panes or nothing at all.
    private func liveMirroredPaneCount() -> Int {
        guard let workspace else { return 0 }
        return panelBySurfaceID.values.reduce(into: 0) { count, panelId in
            if workspace.terminalPanel(for: panelId)?.peerPaneSession?.isRelayLive == true {
                count += 1
            }
        }
    }

    /// Reconnect-only variant of `markAllPanesStale`: a pane whose own relay
    /// is up keeps its panel, its helper process, and its scrollback.
    ///
    /// The two recoveries are independent. `PeerRelaySession` reconnects a
    /// pane's own transport and logs "Remote pane reconnected on attempt N";
    /// this mirror reconnects only the layout subscription. The pane one
    /// routinely finishes FIRST — observed four panes back at 23:05:51 and
    /// all four discarded by the mirror four seconds later — so wiping here
    /// respawns a helper process and a Ghostty surface for panes that were
    /// already working, and closes the working ones.
    ///
    /// The classification is three-way, and it has to be. `isRelayStarted`
    /// looks like the right test and is not: it latches at the first
    /// successful start and is never written again, so a pane whose transport
    /// died reports `.started` for the rest of its life. Keeping on that test
    /// keeps dead panes as readily as live ones, prints the same
    /// "respawning 0" either way, and — because the mapping now survives a
    /// reconnect — leaves the dead one mapped, blank, and never retried,
    /// where every reconnect used to hand it a fresh attach.
    ///
    ///   `.live`         keep, nothing owed
    ///   `.reconnecting` keep, but under `recoveringPaneGraceSeconds`: its
    ///                   own retry loop is uncapped, so without a deadline
    ///                   "it is recovering" is indistinguishable from "it
    ///                   will never come back"
    ///   `.ended`, or still `.pending`/`.starting`
    ///                   respawn. Keeping a pane that never came up leaves
    ///                   the user something that does nothing and no event
    ///                   to explain it.
    ///
    /// RECONNECT ONLY. `forceResync` (the user pressing Retry) and
    /// `resumeAfterHostReconnect` (a new lease, so every pane's transport is
    /// gone anyway) still wipe everything — there, distrusting what is on
    /// screen is the entire point.
    func markPanesStaleKeepingRecovered() {
        guard let workspace else {
            markAllPanesStale()
            return
        }
        let split = Self.partitionForReconnect(
            panelBySurfaceID: panelBySurfaceID,
            classify: { panelId in
                guard let session = workspace.terminalPanel(for: panelId)?.peerPaneSession
                else { return .respawn }
                if session.isRelayLive { return .keep }
                if session.isRelayRecovering { return .watch }
                return .respawn
            }
        )
        let kept = split.keep.merging(split.watch) { first, _ in first }
        guard !kept.isEmpty else {
            markAllPanesStale()
            return
        }
        lastResyncKept = split.keep.count
        lastResyncWatching = split.watch.count
        lastResyncRespawned = split.respawn.count
        pendingStalePanelIds.append(contentsOf: split.respawn.values)
        panelBySurfaceID = kept
        // Keyed by host split ids from a layout that is no longer
        // authoritative. Keeping panes does not make the split map valid;
        // reconcile's B5 rebuilds it.
        hostSplitToLocal.removeAll()
        // Force the FULL reconcile path. With panes kept, the no-op and
        // divider-only fast paths can both match the incoming layout and
        // return without touching the tree — which would skip the portal
        // reattach every kept pane needs after its transport was replaced,
        // leaving correct state behind a blank view.
        //
        // Hand the layout to `dropDiagnosticsBaseline` on the way out rather
        // than dropping it: reconcile names the panes a host push removed by
        // diffing against the last layout this viewer applied, and clearing
        // that here would make the reconnect — the exact path the pane-loss
        // incident took — the one path unable to say what the host dropped.
        dropDiagnosticsBaseline = lastAppliedLayout
        lastAppliedLayout = nil
        RemoteWorkLog.infoOffMain(
            "Mirror resync kept \(split.keep.count) live pane(s)"
                + ", watching \(split.watch.count) still reconnecting"
                + ", respawning \(split.respawn.count)"
        )
        watchRecoveringPanes(split.watch)
    }

    /// What a reconnect owes each mirrored pane.
    enum ReconnectDisposition {
        /// Transport up: keep it and owe it nothing.
        case keep
        /// Mid-reconnect: keep it, but only until the grace deadline.
        case watch
        /// Finished, or never started: respawn it.
        case respawn
    }

    /// Which mirrored panes a reconnect may keep, which it must watch, and
    /// which it must respawn.
    ///
    /// Pure so the rule survives review and regression without a workspace,
    /// a host, or a live relay behind it.
    nonisolated static func partitionForReconnect(
        panelBySurfaceID: [Data: UUID],
        classify: (UUID) -> ReconnectDisposition
    ) -> (keep: [Data: UUID], watch: [Data: UUID], respawn: [Data: UUID]) {
        var keep: [Data: UUID] = [:]
        var watch: [Data: UUID] = [:]
        var respawn: [Data: UUID] = [:]
        for (surfaceID, panelId) in panelBySurfaceID {
            switch classify(panelId) {
            case .keep: keep[surfaceID] = panelId
            case .watch: watch[surfaceID] = panelId
            case .respawn: respawn[surfaceID] = panelId
            }
        }
        return (keep, watch, respawn)
    }

    // MARK: - Kept-pane grace deadline

    /// How long a pane kept mid-reconnect has to finish before the mirror
    /// stops believing it and respawns it.
    ///
    /// A number is needed because `PeerRelaySession`'s owned retry loop has
    /// no cap: it backs off and retries for the life of the pane, so
    /// "reconnecting" is a state a pane can hold forever. Without a deadline,
    /// keeping such a pane trades the old cost (a needless respawn) for a
    /// worse one — a permanently blank pane that no later push can fix,
    /// because the host still reports its surface and the mapping still
    /// points at a panel that exists.
    ///
    /// 20s is past the first few backoff attempts, and far short of the
    /// subscription's own 30s reconnect cadence, so a mirror that keeps
    /// flapping cannot starve this.
    static let recoveringPaneGraceSeconds: UInt64 = 20

    /// Panes kept mid-reconnect by the last resync, awaiting the deadline.
    private var recoveringPaneWatchdog: Task<Void, Never>?
    /// Set once the deadline actually respawned something, so an e2e can
    /// assert the net was needed and caught it rather than inferring from
    /// pane counts.
    private(set) var strandedPaneRespawnCount = 0

    /// How the last resync classified the panes it found.
    ///
    /// Pane counts alone cannot witness this: keeping four live panes and
    /// respawning four dead ones both end at four panes. The counts are what
    /// separate "the reconnect cost nothing" from "the reconnect rebuilt
    /// everything", which is the entire claim under test.
    private(set) var lastResyncKept = 0
    private(set) var lastResyncWatching = 0
    private(set) var lastResyncRespawned = 0
    /// Titles/markers named by the last host push that removed a leaf, so an
    /// e2e can assert the diagnostic fired without scraping a log file.
    var lastDroppedPaneNames: [String] = []

    private func watchRecoveringPanes(_ watched: [Data: UUID]) {
        recoveringPaneWatchdog?.cancel()
        recoveringPaneWatchdog = nil
        guard !watched.isEmpty else { return }
        let graceNs = Self.recoveringPaneGraceSeconds * 1_000_000_000
        recoveringPaneWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: graceNs)
            guard let self, !Task.isCancelled, !self.isTornDown else { return }
            self.respawnPanesThatNeverRecovered(watched)
        }
    }

    /// Give up on the panes that were kept mid-reconnect and never came back.
    ///
    /// Only panes whose mapping is still the one this deadline was armed for
    /// are touched: a later reconcile may have respawned or closed the panel
    /// already, and respawning against a stale mapping would close a pane that
    /// is now somebody else's.
    private func respawnPanesThatNeverRecovered(_ watched: [Data: UUID]) {
        guard let workspace, let layout = lastAppliedLayout else { return }
        var stranded: [Data: UUID] = [:]
        for (surfaceID, panelId) in watched where panelBySurfaceID[surfaceID] == panelId {
            guard let session = workspace.terminalPanel(for: panelId)?.peerPaneSession
            else { continue }
            if session.isRelayLive { continue }
            stranded[surfaceID] = panelId
        }
        guard !stranded.isEmpty else { return }
        for (surfaceID, panelId) in stranded {
            panelBySurfaceID.removeValue(forKey: surfaceID)
            pendingStalePanelIds.append(panelId)
        }
        strandedPaneRespawnCount += stranded.count
        RemoteWorkLog.infoOffMain(
            "\(stranded.count) kept pane(s) never finished reconnecting within "
                + "\(Self.recoveringPaneGraceSeconds)s — respawning"
        )
        // Same reason as the resync itself: with panes still mapped, the
        // no-op fast path would match and return without spawning anything.
        dropDiagnosticsBaseline = layout
        lastAppliedLayout = nil
        scheduleApply(layout)
    }

    // MARK: - Connection loss / reconnect

    private func handleConnectionLost(reason: String) {
        guard !isTornDown else { return }
        subscriptionAlive = false
        subscriptionSession = nil
        let staleTransport = subscriptionTransport
        subscriptionTransport = nil
        Task { await staleTransport?.close() }
        #if DEBUG
        dlog("peer.mirror.lost reason=\(reason)")
        #endif
        if !lease.canReconnectTransport {
            reconnectTask?.cancel()
            reconnectTask = nil
            markWorkspaceTitle(suffix: "disconnected")
            RemoteWorkLog.infoOffMain(
                "Workspace mirror disconnected with its host transport; waiting for the host to reconnect"
            )
            return
        }
        RemoteWorkLog.infoOffMain("Workspace mirror lost its host: \(reason) — reconnecting")
        markWorkspaceTitle(suffix: "reconnecting…")
        let failedGeneration = subscriptionTransportGeneration
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(after: failedGeneration)
        }
    }

    /// Deadline for the setup RPCs of a reconnect attempt, matching
    /// `PeerRelaySession`'s own.
    private static let setupReadTimeoutSeconds: TimeInterval = 10

    /// Whether a reconnect attempt may proceed past a suspension point (the
    /// transport refresh, the backoff sleep, or the connect/handshake
    /// window) or must abandon. Shared by every guard in `reconnectLoop`,
    /// including the one a superseding `handleConnectionLost` trips: it
    /// cancels the prior `reconnectTask`, and `isCancelled` becoming true is
    /// exactly how that supersede reaches this loop.
    enum ReconnectStep: Equatable {
        case proceed
        case abandon
    }

    nonisolated static func reconnectStep(
        isTornDown: Bool,
        hasWorkspace: Bool,
        isCancelled: Bool,
        hostLeaseIsActive: Bool = true
    ) -> ReconnectStep {
        (!isTornDown && hasWorkspace && !isCancelled && hostLeaseIsActive)
            ? .proceed : .abandon
    }

    private func reconnectLoop(after failedGeneration: UInt64) async {
        var attempt = 0
        // "lost its host — reconnecting" is a promise, and this loop can exit
        // without keeping it: when the last pane goes the workspace is torn
        // down, the condition below is false on the first pass, and not one
        // attempt is ever made. Saying so is the difference between "gave up"
        // and "there was nothing left to reconnect to". A loop a newer
        // handleConnectionLost cancelled is a third thing again, so name the
        // cause that actually fired rather than blaming a teardown that never
        // happened. Registered before the first guard so that exit is
        // diagnosable too.
        defer {
            if attempt == 0 {
                let cause = (isTornDown || workspace == nil)
                    ? "the workspace was already gone"
                    : "a newer reconnect superseded it"
                RemoteWorkLog.debugOffMain(
                    "Workspace mirror stopped reconnecting before the first attempt — \(cause)"
                )
            }
        }
        guard Self.reconnectStep(
            isTornDown: isTornDown, hasWorkspace: workspace != nil,
            isCancelled: Task.isCancelled, hostLeaseIsActive: lease.canReconnectTransport
        ) == .proceed else { return }
        // Refresh once per failed generation. Pane, mirror and sidebar
        // consumers share this gate, so simultaneous heartbeat failures join
        // one SSH restart instead of repeatedly killing each other's fresh
        // tunnel. Direct sockets intentionally no-op here.
        subscriptionTransportGeneration = await lease.refreshTransport(
            after: failedGeneration,
            reason: "workspace mirror subscription stopped responding"
        )
        guard Self.reconnectStep(
            isTornDown: isTornDown, hasWorkspace: workspace != nil,
            isCancelled: Task.isCancelled, hostLeaseIsActive: lease.canReconnectTransport
        ) == .proceed else { return }
        while Self.reconnectStep(
            isTornDown: isTornDown, hasWorkspace: workspace != nil,
            isCancelled: Task.isCancelled, hostLeaseIsActive: lease.canReconnectTransport
        ) == .proceed {
            attempt += 1
            let delaySeconds = min(30.0, pow(2.0, Double(min(attempt, 5))))
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }
            if isTornDown || Task.isCancelled { return }
            do {
                let transport = try await UnixSocketTransport.connect(socketPath: lease.hostSockPath)
                // A host that is frozen rather than gone — asleep, behind a
                // blackholed network — still has a listening socket, so
                // connect() succeeds and the handshake then waits for a
                // HostHello that never arrives. With no deadline this loop
                // stopped inside its first attempt and never retried, never
                // gave up and never said a word: the workspace title just read
                // "reconnecting…" for as long as the app stayed open. Same
                // budget the primary connect path puts around its setup.
                await transport.setReadTimeoutSeconds(Self.setupReadTimeoutSeconds)
                let session = PeerSession(
                    read: { try await transport.read() },
                    write: { try await transport.write($0) }
                )
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    _ = try await session.handshake(options: Self.mirrorHandshakeOptions)
                    workspaces = try await session.listWorkspaces()
                } catch {
                    // Now that a failed attempt can actually fail instead of
                    // hanging, every retry would otherwise leave its socket
                    // behind.
                    await transport.close()
                    throw error
                }
                // Cancellation is only honored where it is checked, and the
                // connect/handshake/listWorkspaces awaits above are a window
                // the peer host controls (the setup budget is 10s). A teardown
                // or a newer handleConnectionLost that lands inside it cannot
                // undo what happens after it: `teardown()` is isTornDown-guarded
                // and never runs twice, so a subscription installed here would
                // keep its socket and 10s heartbeat alive for the rest of the
                // process — on a host the user explicitly disconnected.
                guard Self.reconnectStep(
                    isTornDown: isTornDown, hasWorkspace: workspace != nil,
                    isCancelled: Task.isCancelled, hostLeaseIsActive: lease.canReconnectTransport
                ) == .proceed else {
                    await transport.close()
                    return
                }
                guard let target = matchAndAdoptWorkspace(workspaces) else {
                    await transport.close()
                    markHostWorkspaceGone()
                    return
                }
                // Cleared before the receive loop: a subscription is idle most
                // of the time and a read deadline there would kill it.
                await transport.setReadTimeoutSeconds(nil)
                subscriptionTransport = transport
                subscriptionSession = session
                subscriptionAlive = true
                subscriptionTransportGeneration = lease.transportGeneration
                let weakTransport = transport
                await session.startHeartbeat(
                    intervalSeconds: 10,
                    deadAfterSeconds: 30,
                    onFirstMiss: {
                        #if DEBUG
                        dlog("peer.mirror.heartbeat.firstMiss (post-reconnect) — subscription pong overdue")
                        #endif
                    },
                    onMissRecovered: {
                        #if DEBUG
                        dlog("peer.mirror.heartbeat.recovered (post-reconnect)")
                        #endif
                    }
                ) {
                    #if DEBUG
                    dlog("peer.mirror.heartbeat.dead (post-reconnect) — closing subscription transport (ALL mirrored panes drop)")
                    #endif
                    // Every mirrored pane dies with this one transport, so it is
                    // the loudest failure the mirror has and was the quietest.
                    RemoteWorkLog.infoOffMain(
                        "Host stopped answering the workspace subscription for 30s — every mirrored pane drops"
                    )
                    Task { await weakTransport.close() }
                }
                // Only the SUBSCRIPTION was lost here; each pane's own relay
                // has its own reconnect and may already be back. Keep the
                // ones that are.
                markPanesStaleKeepingRecovered()
                try await reconcile(target: target.layout)
                startReceiveLoop(session: session)
                markWorkspaceTitle(suffix: nil)
                #if DEBUG
                dlog("peer.mirror.reconnected attempt=\(attempt)")
                #endif
                RemoteWorkLog.infoOffMain("Workspace mirror reconnected on attempt \(attempt)")
                return
            } catch {
                #if DEBUG
                dlog("peer.mirror.reconnect.failed attempt=\(attempt) err=\(error)")
                #endif
                // This loop has no cap — it retries every 30s forever. Logging
                // the first few and then one in ten keeps "still trying" answerable
                // without a line every half minute for the rest of the session.
                // Without any line, one "lost its host" and then permanent silence
                // is indistinguishable from having quietly given up.
                if attempt <= 3 || attempt % 10 == 0 {
                    RemoteWorkLog.debugOffMain(
                        "Workspace mirror reconnect attempt \(attempt) failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Move a mirror preserved by Disconnect Host onto the replacement lease
    /// created by Connect. Starting a fresh subscription also rebuilds every
    /// mirrored pane from the host's current layout.
    @discardableResult
    func resumeAfterHostReconnect(using replacement: PeerPaneHostLease) -> Bool {
        guard !isTornDown, lease.key == replacement.key, lease !== replacement else {
            return false
        }

        let previousLease = lease
        let previousSession = subscriptionSession
        let previousTransport = subscriptionTransport
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        subscriptionSession = nil
        subscriptionTransport = nil
        subscriptionAlive = false

        PeerPaneHostRegistry.shared.retain(replacement)
        lease = replacement
        PeerPaneHostRegistry.shared.release(previousLease)
        markAllPanesStale()
        markWorkspaceTitle(suffix: "reconnecting…")

        reconnectTask = Task { [weak self] in
            if let previousSession {
                await previousSession.stopHeartbeat()
                try? await previousSession.sendGoodbye(reason: "host reconnected")
            }
            await previousTransport?.close()
            guard let self, !self.isTornDown, !Task.isCancelled else { return }
            var startError: Error?
            do {
                try await self.start()
            } catch {
                startError = error
            }
            // A superseded resume owns nothing. A newer resume cancels this
            // task and moves the lease before starting its own subscription,
            // so whatever THIS task observed — success or failure — would
            // speak for controller state the newer resume now owns. The
            // failure side was the observed hazard: a cancelled `start()`
            // throwing into an unconditional `handleConnectionLost` cleared
            // the replacement's fresh session and cancelled its reconnect
            // task. Only the resume still holding the current lease reports.
            guard Self.resumeOutcomeMayReport(
                isCancelled: Task.isCancelled,
                leaseIsCurrent: self.lease === replacement
            ) else { return }
            if let startError {
                self.handleConnectionLost(reason: String(describing: startError))
            } else {
                self.markWorkspaceTitle(suffix: nil)
                RemoteWorkLog.infoOffMain(
                    "Workspace mirror reconnected through the replacement host transport"
                )
            }
        }
        return true
    }

    /// Whether a finished resume attempt may report its outcome to the
    /// controller. Pure so the superseded-resume contract is pinned by a
    /// test rather than by whoever edits the task body next.
    nonisolated static func resumeOutcomeMayReport(
        isCancelled: Bool,
        leaseIsCurrent: Bool
    ) -> Bool {
        !isCancelled && leaseIsCurrent
    }

    /// The mirrored workspace was deleted on the host. Auto-close the
    /// local mirror to match: with the host gone every structural action
    /// just forwards upstream and silently no-ops (`mirrorForwardsLocalActions`),
    /// so leaving the tab open would only produce an unresponsive zombie.
    ///
    /// Idempotent/re-entrant-safe: gated on `isTornDown`, which
    /// `TabManager.closeWorkspace` below sets synchronously (via
    /// `workspace.peerMirror?.teardown()`) before this method could ever
    /// be re-entered — the receive loop, `reconnectLoop`, and
    /// `forceResync` all re-check `isTornDown` around their own calls
    /// into this method too, so a stale/duplicate hostGone signal is a
    /// no-op here rather than a double close or double notification.
    private func markHostWorkspaceGone() {
        guard !isTornDown else { return }
        let title = hostWorkspaceTitle.isEmpty ? "Workspace" : hostWorkspaceTitle
        let hostLabel = PeerHostProfileStore.shared.displayLabel(for: spec.hostKey)
        #if DEBUG
        dlog("peer.mirror.hostGone action=autoclose host=\(spec.hostKey) workspace=\(title)")
        #endif
        RemoteWorkLog.infoOffMain("Host deleted the workspace \"\(title)\" on \(spec.hostKey) — closing the mirror here")
        // Route by owner, not by whichever window happens to be frontmost:
        // `closeWorkspace` tears down panes, so aiming it at the wrong
        // manager would kill another window's surfaces.
        guard let workspace,
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspace.id) else {
            // No window/TabManager context (headless/test) — just release
            // the layout-sync plane; there's no tab to close or notify.
            teardown()
            return
        }
        // Same path the roster's manual disconnect uses (PeerMenu.swift)
        // to close a mirror workspace: TabManager owns tab removal, and
        // cascades into `teardown()` via `workspace.peerMirror?.teardown()`
        // (idempotent), releasing the subscription/heartbeat/lease as
        // part of the same close.
        tabManager.closeWorkspace(workspace)
        tabManager.notifications.addNotification(
            tabId: workspace.id,
            surfaceId: nil,
            title: "Workspace closed",
            subtitle: hostLabel,
            body: "“\(title)” was deleted on \(hostLabel)."
        )
    }

    private func markWorkspaceTitle(suffix: String?) {
        guard let workspace else { return }
        let base = "\(hostWorkspaceTitle.isEmpty ? "Workspace" : hostWorkspaceTitle) ⌁ \(PeerHostProfileStore.shared.displayLabel(for: spec.hostKey))"
        workspace.title = suffix.map { "\(base) — \($0)" } ?? base
    }

    // MARK: - Test actuators

    #if DEBUG
    /// Drop ONLY the layout subscription, leaving every pane's own relay
    /// transport untouched.
    ///
    /// This is the shape of the real incident and the one a test cannot
    /// otherwise produce: killing the tunnel takes the panes down with it, so
    /// "the mirror resynced while the panes were fine" would never occur.
    /// Closing the subscription transport makes `startReceiveLoop`'s read
    /// fail, which is the same door a host-side drop comes through.
    func debugDropSubscription() {
        guard !isTornDown, let transport = subscriptionTransport else { return }
        Task { await transport.close() }
    }

    /// End one mirrored pane's relay WITHOUT tearing down its `PeerPaneSession`.
    ///
    /// That combination — relay finished, pane session not torn down — is
    /// exactly what a heartbeat death or an exhausted reconnect leaves
    /// behind, and it is the state in which `relayStartupState` still reads
    /// `.started`. No production path can be asked for it on demand, so the
    /// regression it causes was only ever visible in the field.
    @discardableResult
    func debugEndPaneRelay(surfaceID: Data) -> Bool {
        guard let workspace, let panelId = panelBySurfaceID[surfaceID],
              let session = workspace.terminalPanel(for: panelId)?.peerPaneSession
        else { return false }
        Task { await session.relaySession.stop() }
        return true
    }

    /// Surface ids currently mirrored, in a stable order, so a test can name
    /// one without guessing at dictionary iteration order.
    func debugMirroredSurfaceIDs() -> [Data] {
        panelBySurfaceID.keys.sorted { $0.lexicographicallyPrecedes($1) }
    }
    #endif

    // MARK: - Teardown

    /// Idempotent. Pane sessions are torn down by TerminalPanel.close()
    /// (workspace close walks every panel) — this releases only the
    /// layout-sync plane + the controller's own lease ref.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        subscriptionAlive = false
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        applyTask?.cancel()
        applyTask = nil
        recoveringPaneWatchdog?.cancel()
        recoveringPaneWatchdog = nil
        for (_, task) in dividerDebounce { task.cancel() }
        dividerDebounce.removeAll()
        let session = subscriptionSession
        let transport = subscriptionTransport
        subscriptionSession = nil
        subscriptionTransport = nil
        Task {
            if let session {
                await session.stopHeartbeat()
                try? await session.sendGoodbye(reason: "mirror closed")
            }
            await transport?.close()
        }
        PeerPaneHostRegistry.shared.release(lease)
        PeerClientCoordinator.shared.deregisterWorkspaceMirror(self)
        #if DEBUG
        dlog("peer.mirror.teardown host=\(spec.hostKey)")
        #endif
    }

    // MARK: - Helpers

    static func matchWorkspace(
        _ workspaces: [Termmesh_Peer_V1_Workspace],
        id: Data
    ) -> Termmesh_Peer_V1_Workspace? {
        // Exact id first; a single-workspace host (Rust daemon) is
        // adopted even if its id changed across a daemon restart.
        workspaces.first { $0.workspaceID == id }
            ?? (workspaces.count == 1 ? workspaces[0] : nil)
    }

    static func matchedWorkspaceIdentity(
        _ workspaces: [Termmesh_Peer_V1_Workspace],
        currentID: Data
    ) -> (workspace: Termmesh_Peer_V1_Workspace, adoptedID: Data)? {
        guard let workspace = matchWorkspace(workspaces, id: currentID) else { return nil }
        return (workspace, workspace.workspaceID)
    }

    func matchesHostWorkspaceID(_ candidateID: Data) -> Bool {
        Self.matchesHostWorkspaceID(candidateID, aliases: hostWorkspaceIDAliases)
    }

    static func matchesHostWorkspaceID(_ candidateID: Data, aliases: Set<Data>) -> Bool {
        aliases.contains(candidateID)
    }

    static func workspaceIDAliases(_ aliases: Set<Data>, adopting adoptedID: Data) -> Set<Data> {
        aliases.union([adoptedID])
    }

    private func matchAndAdoptWorkspace(
        _ workspaces: [Termmesh_Peer_V1_Workspace]
    ) -> Termmesh_Peer_V1_Workspace? {
        guard let match = Self.matchedWorkspaceIdentity(
            workspaces,
            currentID: hostWorkspaceID
        ) else { return nil }
        if hostWorkspaceID != match.adoptedID {
            hostWorkspaceIDAliases = Self.workspaceIDAliases(
                hostWorkspaceIDAliases,
                adopting: match.adoptedID
            )
            hostWorkspaceID = match.adoptedID
            PeerClientCoordinator.shared.workspaceMirrorIdentityDidChange()
        }
        return match.workspace
    }

    /// Run `body` with the remote-application flag set; used by the
    /// reconciler so every delegate hook can tell "remote apply" from
    /// "local user action".
    func withRemoteApplication<T>(_ body: () throws -> T) rethrows -> T {
        isApplyingRemoteLayout = true
        defer {
            // Cleared on the next runloop tick: bonsplit settles some
            // geometry callbacks asynchronously, and those must still
            // see the flag (same rationale as the relay window's
            // applyingLayoutDepth decrement hop).
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingRemoteLayout = false
            }
        }
        return try body()
    }

    func recordApplied(_ layout: Termmesh_Peer_V1_WorkspaceLayout) {
        lastAppliedLayout = layout
        // Consumed: the real baseline is back, and leaving the reconnect's
        // copy behind would let a later push diff against a layout two
        // reconciles old and name panes that were replaced, not dropped.
        dropDiagnosticsBaseline = nil
        RemoteHostStore.shared.recordLiveMirrorLayout(
            layout,
            hostKey: lease.key,
            workspaceIDs: hostWorkspaceIDAliases
        )
    }
}
