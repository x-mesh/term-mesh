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
    let lease: PeerPaneHostLease
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

    /// Last layout we reconciled to — the baseline for no-op/divider-only
    /// fast paths and for outbound divider diffs.
    private(set) var lastAppliedLayout: Termmesh_Peer_V1_WorkspaceLayout?
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
    private static var mirrorHandshakeOptions: PeerSessionOptions {
        PeerSessionOptions(
            capabilities: PeerCapability.supported.filter { $0 != PeerCapability.gridSnapshotV1 }
        )
    }

    func start() async throws {
        let transport = try await UnixSocketTransport.connect(socketPath: lease.hostSockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake(options: Self.mirrorHandshakeOptions)
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
        guard let target = matchAndAdoptWorkspace(workspaces) else {
            throw RelayError.ioError("host workspace not found")
        }
        try await reconcile(target: target.layout)
        startReceiveLoop(session: session)
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
            guard let self, !self.isTornDown else { return }
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
        pendingStalePanelIds.append(contentsOf: panelBySurfaceID.values)
        panelBySurfaceID.removeAll()
        hostSplitToLocal.removeAll()
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
        RemoteWorkLog.infoOffMain("Workspace mirror lost its host: \(reason) — reconnecting")
        markWorkspaceTitle(suffix: "reconnecting…")
        Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    /// Deadline for the setup RPCs of a reconnect attempt, matching
    /// `PeerRelaySession`'s own.
    private static let setupReadTimeoutSeconds: TimeInterval = 10

    private func reconnectLoop() async {
        var attempt = 0
        // "lost its host — reconnecting" is a promise, and this loop can exit
        // without keeping it: when the last pane goes the workspace is torn
        // down, the condition below is false on the first pass, and not one
        // attempt is ever made. Saying so is the difference between "gave up"
        // and "there was nothing left to reconnect to".
        defer {
            if attempt == 0 {
                RemoteWorkLog.debugOffMain(
                    "Workspace mirror stopped reconnecting before the first attempt — the workspace was already gone"
                )
            }
        }
        while !isTornDown, workspace != nil {
            attempt += 1
            let delaySeconds = min(30.0, pow(2.0, Double(min(attempt, 5))))
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if isTornDown { return }
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
                markAllPanesStale()
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
        applyTask?.cancel()
        applyTask = nil
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
        RemoteHostStore.shared.recordLiveMirrorLayout(
            layout,
            hostKey: lease.key,
            workspaceIDs: hostWorkspaceIDAliases
        )
    }
}
