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
    let hostWorkspaceID: Data
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
        self.hostWorkspaceTitle = hostWorkspaceTitle
    }

    // MARK: - Subscription lifecycle

    /// Connect the subscription session, reconcile to the freshest host
    /// layout, and start the receive loop. RPCs here run BEFORE the loop
    /// exists, so the single-reader invariant holds.
    func start() async throws {
        let transport = try await UnixSocketTransport.connect(socketPath: lease.hostSockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()
        subscriptionTransport = transport
        subscriptionSession = session
        subscriptionAlive = true

        // Hung-connection detection: a dead transport unblocks the
        // receive loop's read with an error, entering the reconnect path.
        let weakTransport = transport
        await session.startHeartbeat(intervalSeconds: 10, deadAfterSeconds: 30) {
            Task { await weakTransport.close() }
        }

        let workspaces = try await session.listWorkspaces()
        guard let target = Self.matchWorkspace(workspaces, id: hostWorkspaceID) else {
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
            _ = try await oneShot.handshake()
            let workspaces = try await oneShot.listWorkspaces()
            try? await oneShot.sendGoodbye(reason: "resync probe")
            await transport.close()
            guard !isTornDown else { return }
            guard let target = Self.matchWorkspace(workspaces, id: hostWorkspaceID) else {
                markHostWorkspaceGone()
                return
            }
            markAllPanesStale()
            try await reconcile(target: target.layout)
        } catch {
            NSLog("[peer-mirror] forceResync failed: %@", String(describing: error))
        }
    }

    func markAllPanesStale() {
        // Leaving panelBySurfaceID intact but flagging respawn is more
        // complex than it's worth: dropping the map makes every target
        // leaf "missing" (fresh spawn) and every mapped panel unmatched
        // (stale close) in one reconcile pass.
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
        markWorkspaceTitle(suffix: "reconnecting…")
        Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        var attempt = 0
        while !isTornDown, workspace != nil {
            attempt += 1
            let delaySeconds = min(30.0, pow(2.0, Double(min(attempt, 5))))
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if isTornDown { return }
            do {
                let transport = try await UnixSocketTransport.connect(socketPath: lease.hostSockPath)
                let session = PeerSession(
                    read: { try await transport.read() },
                    write: { try await transport.write($0) }
                )
                _ = try await session.handshake()
                let workspaces = try await session.listWorkspaces()
                guard let target = Self.matchWorkspace(workspaces, id: hostWorkspaceID) else {
                    await transport.close()
                    markHostWorkspaceGone()
                    return
                }
                subscriptionTransport = transport
                subscriptionSession = session
                subscriptionAlive = true
                let weakTransport = transport
                await session.startHeartbeat(intervalSeconds: 10, deadAfterSeconds: 30) {
                    Task { await weakTransport.close() }
                }
                markAllPanesStale()
                try await reconcile(target: target.layout)
                startReceiveLoop(session: session)
                markWorkspaceTitle(suffix: nil)
                #if DEBUG
                dlog("peer.mirror.reconnected attempt=\(attempt)")
                #endif
                return
            } catch {
                #if DEBUG
                dlog("peer.mirror.reconnect.failed attempt=\(attempt) err=\(error)")
                #endif
            }
        }
    }

    private func markHostWorkspaceGone() {
        markWorkspaceTitle(suffix: "host workspace closed")
        #if DEBUG
        dlog("peer.mirror.host_workspace_gone")
        #endif
    }

    private func markWorkspaceTitle(suffix: String?) {
        guard let workspace else { return }
        let base = "\(hostWorkspaceTitle.isEmpty ? "Workspace" : hostWorkspaceTitle) ⌁ \(spec.hostKey.shortLabel)"
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
    }
}
