//  PeerPaneSession: session ownership for a remote peer surface hosted as
//  a NORMAL main-window pane (Bonsplit panel), instead of a separate relay
//  window. This is the Phase 1 "remote pane primitive" — layout stays
//  local (Bonsplit owns it); only the pane's bytes stream from the host.
//
//  Ownership model (decision D1, .xm/build/projects/peer-remote-pane-phase1):
//   - Per HOST:  one shared `PeerSSHTunnel` (ssh process + auth + forward
//     — the expensive part), pooled in `PeerPaneHostRegistry` by
//     `PeerPaneHostKey` and refcounted by the panes using it. Direct
//     (non-SSH) hosts get a trivial lease with no shared process.
//   - Per PANE:  one owned `PeerRelaySession` (fresh connect + handshake
//     over the tunnel's local socket — milliseconds on loopback). Owned
//     sessions sidestep the shared-session reader race: `PeerSession`
//     RPCs consume `readFrame()` without response correlation, so a
//     user-initiated attach may not share a session that a receive loop
//     is already reading (safe only when all attaches run inside that
//     loop, as the workspace relay window does). Narrow sharing returns
//     as a follow-up once a correlation layer exists.
//
//  The pane's TerminalPanel holds the PeerPaneSession; `teardown()` must
//  run on every close path (pane close, workspace close, app quit) —
//  it stops the relay session and releases the host lease; the LAST
//  release stops the shared tunnel.

import AppKit
import Bonsplit
import PeerProto

// MARK: - Host identity

/// How to reach a peer host. `hostKey` collapses reconnect-variant
/// details (an SSH tunnel's local socket path changes per reconnect)
/// into a stable pooling identity — same convention as
/// `RemoteHostStore.stableKey`.
enum PeerPaneHostSpec {
    case direct(sockPath: String)
    /// `port`/`identityFile` are optional auth parameters from a saved
    /// host profile (nil = ssh defaults / ssh-config). They ride the
    /// spec so tunnel creation sees them; only `port` joins the pooling
    /// key (see PeerPaneHostKey).
    case ssh(target: String, remoteSockPath: String, port: Int?, identityFile: String?)

    var hostKey: PeerPaneHostKey {
        switch self {
        case .direct(let sockPath): return .direct(sockPath: sockPath)
        case .ssh(let target, let remoteSockPath, let port, _):
            return .ssh(target: target, remoteSockPath: remoteSockPath, port: port)
        }
    }
}

enum PeerPaneHostKey: Hashable, CustomStringConvertible {
    case direct(sockPath: String)
    /// Keyed by target AND remote socket: one machine can host several
    /// daemons on different sockets, and pooling them onto one tunnel
    /// would silently connect a pane to the wrong peer. (The tunnel's
    /// *local* socket stays out of the key — it is reconnect-ephemeral.)
    /// `port` is part of the key (different sshd = different host);
    /// identityFile is NOT (it doesn't change which host is reached).
    case ssh(target: String, remoteSockPath: String, port: Int?)

    var sshTarget: String? {
        if case .ssh(let target, _, _) = self { return target }
        return nil
    }

    var remoteSockPath: String? {
        if case .ssh(_, let remoteSockPath, _) = self { return remoteSockPath }
        return nil
    }

    var description: String {
        switch self {
        case .direct(let sockPath): return sockPath
        case .ssh(let target, let remoteSockPath, let port):
            let portPart = port.map { "#\($0)" } ?? ""
            return "ssh:\(target)\(portPart):\(remoteSockPath)"
        }
    }

    /// Compact label for tab chips and pane strips: hostname for SSH
    /// targets (user@ stripped), socket basename for direct paths.
    var shortLabel: String {
        switch self {
        case .ssh(let target, _, _):
            return target.split(separator: "@").last.map(String.init) ?? target
        case .direct(let sockPath):
            return (sockPath as NSString).lastPathComponent
        }
    }
}

// MARK: - Per-host lease

/// Shared per-host resources leased by remote panes. Created/pooled by
/// `PeerPaneHostRegistry`; holders must balance every `acquire`/`retain`
/// with a `release`.
@MainActor
final class PeerPaneHostLease {
    let key: PeerPaneHostKey
    /// Local Unix socket to dial for this host: the tunnel's forwarded
    /// socket for SSH hosts, the host's own socket for direct ones.
    var hostSockPath: String {
        if let tunnel { return tunnel.localSockPath }
        if case .direct(let sockPath) = key { return sockPath }
        return ""
    }
    /// Non-nil for SSH hosts. Shared by every pane on this host; owned
    /// (started/stopped) exclusively by the lease.
    let tunnel: PeerSSHTunnel?
    /// Peer name from the first successful handshake, for display.
    /// Filled lazily by the first attach.
    var hostDisplayName: String = ""

    fileprivate var refCount = 0

    fileprivate init(key: PeerPaneHostKey, tunnel: PeerSSHTunnel?) {
        self.key = key
        self.tunnel = tunnel
    }

    fileprivate func teardown() {
        tunnel?.stop()
    }
}

// MARK: - Registry

@MainActor
final class PeerPaneHostRegistry {
    static let shared = PeerPaneHostRegistry()

    private var leases: [PeerPaneHostKey: PeerPaneHostLease] = [:]
    /// Coalesces concurrent first-acquires of the same host so exactly
    /// one tunnel is spawned (double-click, multi-pane open, …).
    private struct StartingLease {
        let id = UUID()
        let task: Task<PeerPaneHostLease, Error>
        /// Callers currently awaiting this coalesced start. Cancelling the task
        /// aborts it for all of them, so it may only be cancelled while this is
        /// the last waiter.
        var waiters = 0
    }

    private var starting: [PeerPaneHostKey: StartingLease] = [:]

    #if DEBUG
    /// Test-only: leases torn down so far. A unit test drives `.direct` specs,
    /// whose `teardown()` stops no real process, so this counter is the only
    /// way to tell a released lease from an orphaned one.
    private(set) var teardownCountForTests = 0
    #endif

    /// Acquire a lease for the host (+1 ref). Starts the SSH tunnel on
    /// first acquire; later acquires reuse the live lease.
    func acquire(_ spec: PeerPaneHostSpec) async throws -> PeerPaneHostLease {
        let key = spec.hostKey
        if let lease = leases[key] {
            lease.refCount += 1
            return lease
        }
        if let startingLease = starting[key] {
            starting[key]?.waiters += 1
            defer {
                if starting[key]?.id == startingLease.id {
                    starting[key]?.waiters -= 1
                }
            }
            let lease = try await startingLease.task.value
            return try adopt(lease, key: key)
        }
        var startingLease = StartingLease(task: Task { try await Self.makeLease(spec: spec) })
        startingLease.waiters = 1
        starting[key] = startingLease
        defer {
            if starting[key]?.id == startingLease.id {
                starting[key] = nil
            }
        }
        let lease = try await startingLease.task.value
        return try adopt(lease, key: key)
    }

    /// Pool the lease a coalesced start task produced and take one ref.
    ///
    /// Cancellation is honoured only *after* the lease is owned. Checking it
    /// before pooling orphans an already-spawned tunnel: the lease never
    /// reaches `leases`, so nothing ever releases it and the helper process
    /// outlives the pane that asked for it.
    private func adopt(_ lease: PeerPaneHostLease, key: PeerPaneHostKey) throws -> PeerPaneHostLease {
        // A racing acquire may have landed a lease already (both awaited the
        // same task); pool exactly one instance. A *different* pooled instance
        // makes ours an orphan whose tunnel nobody would ever stop.
        let pooled: PeerPaneHostLease
        if let existing = leases[key] {
            if existing !== lease { teardown(lease) }
            pooled = existing
        } else {
            leases[key] = lease
            pooled = lease
            #if DEBUG
            dlog("peer.pane.lease.up key=\(key)")
            #endif
        }
        pooled.refCount += 1
        if Task.isCancelled {
            release(pooled)
            throw CancellationError()
        }
        return pooled
    }

    /// Stop this caller's in-flight first acquire.
    ///
    /// The start task is shared by every pane that coalesced onto the same
    /// host, so it is only cancelled when this is the last waiter. With others
    /// still waiting the caller just stops waiting: its own task cancellation
    /// makes `adopt` pool the lease and release it again, which leaves the
    /// remaining panes' connect untouched.
    ///
    /// An already-live lease is never affected — it may be owned by another
    /// pane or workspace mirror.
    func cancelPendingAcquire(for key: PeerPaneHostKey) {
        guard let startingLease = starting[key] else { return }
        guard startingLease.waiters <= 1 else {
            #if DEBUG
            dlog("peer.pane.acquire.cancel.shared key=\(key) waiters=\(startingLease.waiters)")
            #endif
            return
        }
        starting[key] = nil
        startingLease.task.cancel()
    }

    #if DEBUG
    /// Test-only: callers currently awaiting a coalesced start for this host.
    func pendingWaiterCountForTests(for key: PeerPaneHostKey) -> Int {
        starting[key]?.waiters ?? 0
    }
    #endif

    /// Additional ref on an already-acquired lease (a new pane joining
    /// the host).
    func retain(_ lease: PeerPaneHostLease) {
        lease.refCount += 1
    }

    /// Balance one acquire/retain. The last release tears the lease
    /// down (stops the shared tunnel) and removes it from the pool.
    func release(_ lease: PeerPaneHostLease) {
        lease.refCount -= 1
        guard lease.refCount <= 0 else { return }
        leases[lease.key] = nil
        teardown(lease)
        #if DEBUG
        dlog("peer.pane.lease.down key=\(lease.key)")
        #endif
    }

    /// Single teardown funnel so every path that stops a tunnel is counted.
    private func teardown(_ lease: PeerPaneHostLease) {
        lease.teardown()
        #if DEBUG
        teardownCountForTests += 1
        #endif
    }

    /// Diagnostics/tests.
    func activeLease(forKey key: PeerPaneHostKey) -> PeerPaneHostLease? { leases[key] }
    var activeLeaseCount: Int { leases.count }

    private static func makeLease(spec: PeerPaneHostSpec) async throws -> PeerPaneHostLease {
        switch spec {
        case .direct:
            return PeerPaneHostLease(key: spec.hostKey, tunnel: nil)
        case .ssh(let target, let remoteSockPath, let port, let identityFile):
            let tunnel = PeerSSHTunnel(
                sshTarget: target,
                remoteSockPath: remoteSockPath,
                dashboardRemotePort: PeerFederationSettings.forwardDashboard
                    ? PeerFederationSettings.remoteDashboardPort
                    : nil,
                port: port,
                identityFile: identityFile
            )
            try await tunnel.start()
            return PeerPaneHostLease(key: spec.hostKey, tunnel: tunnel)
        }
    }
}

// MARK: - Per-pane session

/// The session bundle a remote pane's TerminalPanel owns: the pane's
/// relay session plus the host lease it holds a ref on.
@MainActor
final class PeerPaneSession {
    let lease: PeerPaneHostLease
    let relaySession: PeerRelaySession
    let surfaceTitle: String
    let connectedAt = Date()
    private(set) var isTorndown = false

    /// Reattach recipe for the disconnect banner's Reconnect action:
    /// how this pane's host was reached and which surface it mirrored.
    let originSpec: PeerPaneHostSpec
    let originSurface: Termmesh_Peer_V1_SurfaceInfo

    /// Set by the pane host (Workspace.openRemotePane) so roster-driven
    /// disconnects can close the hosting pane instead of leaving a dead
    /// relay shell behind.
    var requestPaneClose: (@MainActor () -> Void)?

    /// For the connections panel / sidebar roster (t7 wires this into
    /// `PeerClientCoordinator`).
    var connectionInfo: PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(self),
            kind: .pane,
            hostSockPath: relaySession.hostSockPath,
            hostDisplayName: relaySession.hostDisplayName,
            sshTarget: lease.key.sshTarget,
            remoteSockPath: lease.key.remoteSockPath,
            targetTitle: surfaceTitle.isEmpty ? "<surface>" : surfaceTitle,
            connectedAt: connectedAt
        )
    }

    // Pane-command plumbing for TerminalPanel creation (t2).
    var relayLaunchCommand: String { relaySession.relayLaunchCommand }
    var relayEnvironment: [String: String] { relaySession.relayEnvironment }

    private init(
        lease: PeerPaneHostLease,
        relaySession: PeerRelaySession,
        surfaceTitle: String,
        originSpec: PeerPaneHostSpec,
        originSurface: Termmesh_Peer_V1_SurfaceInfo
    ) {
        self.lease = lease
        self.relaySession = relaySession
        self.surfaceTitle = surfaceTitle
        self.originSpec = originSpec
        self.originSurface = originSurface
    }

    // ── Discovery ────────────────────────────────────────────────────

    /// List the host's attachable surfaces over a short-lived probe
    /// connection. The lease stays alive for the caller's picker UX;
    /// balance with `PeerPaneHostRegistry.shared.release(lease)` if no
    /// attach follows.
    static func listSurfaces(
        on lease: PeerPaneHostLease
    ) async throws -> [Termmesh_Peer_V1_SurfaceInfo] {
        let conn = try await PeerRelaySession.connectAndList(hostSockPath: lease.hostSockPath)
        if lease.hostDisplayName.isEmpty {
            lease.hostDisplayName = conn.hostDisplayName
        }
        let surfaces = conn.surfaces
        await conn.cancel()
        return surfaces
    }

    // ── Attach ───────────────────────────────────────────────────────

    /// Open one pane session on the host: fresh owned connection +
    /// handshake + AttachSurface (see D1 for why not shared). Takes an
    /// additional ref on the lease; `teardown()` releases it.
    static func attach(
        lease: PeerPaneHostLease,
        surface: Termmesh_Peer_V1_SurfaceInfo,
        title: String,
        spec: PeerPaneHostSpec
    ) async throws -> PeerPaneSession {
        let conn = try await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
        if lease.hostDisplayName.isEmpty {
            lease.hostDisplayName = conn.hostDisplayName
        }
        let relay: PeerRelaySession
        do {
            relay = try await PeerRelaySession.attach(conn, surface: surface)
        } catch {
            await conn.cancel()
            throw error
        }
        // The lease is the only thing that knows WHICH machine this reached;
        // the session itself holds a socket path that, over SSH, is a local
        // tunnel end. Host-scoped pushes need the real identity.
        relay.hostKey = lease.key
        do {
            // Bind the local relay socket BEFORE Ghostty spawns the relay
            // binary as the pane's shell — the binary connects immediately
            // on launch, and an unbound socket kills the session at start().
            try relay.prepareListener()
        } catch {
            await relay.stop()
            throw error
        }
        PeerPaneHostRegistry.shared.retain(lease)
        let paneSession = PeerPaneSession(
            lease: lease,
            relaySession: relay,
            surfaceTitle: title,
            originSpec: spec,
            originSurface: surface
        )
        // Roster registration keeps the sidebar's Remote Hosts section
        // and the Connections panel in sync with pane-based connections;
        // teardown() balances it.
        PeerClientCoordinator.shared.registerPaneSession(paneSession)
        #if DEBUG
        dlog("peer.pane.attach key=\(lease.key) surface=\(title)")
        #endif
        RemoteWorkLog.infoOffMain("Remote pane attached: \(title) on \(lease.key)")
        return paneSession
    }

    /// Saved-profile path: handshake → ensure → attach the exact returned id.
    /// The same open connection owns both RPCs, so no list/picker race can
    /// redirect the attachment to a different surface.
    static func ensureAndAttach(
        lease: PeerPaneHostLease,
        surfaceSpec: PeerRunnerSurfaceSpec,
        attachment: PeerRunnerAttachment,
        hostSpec: PeerPaneHostSpec,
        onEnsured: () -> Void = {}
    ) async throws -> (session: PeerPaneSession, outcome: PeerEnsureSurfaceOutcome) {
        let conn = try await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
        if lease.hostDisplayName.isEmpty {
            lease.hostDisplayName = conn.hostDisplayName
        }

        let outcome: PeerEnsureSurfaceOutcome
        do {
            outcome = try await PeerRelaySession.ensureSurface(conn, spec: surfaceSpec)
        } catch {
            await conn.cancel()
            throw error
        }
        onEnsured()

        var exactSurface = Termmesh_Peer_V1_SurfaceInfo()
        exactSurface.surfaceID = outcome.surfaceID
        // A logical key is control-plane identity and may be sensitive. Never
        // promote it into pane titles because connection-roster diagnostics
        // log titles. An empty display title gets a fixed safe fallback.
        exactSurface.title = attachment.title.isEmpty ? "Runner" : attachment.title
        exactSurface.cols = max(attachment.cols, 1)
        exactSurface.rows = max(attachment.rows, 1)
        exactSurface.surfaceType = "terminal"
        exactSurface.attachable = true
        exactSurface.cwd = surfaceSpec.cwd

        let relay: PeerRelaySession
        do {
            relay = try await PeerRelaySession.attach(conn, surface: exactSurface)
        } catch {
            await conn.cancel()
            throw error
        }
        do {
            try relay.prepareListener()
        } catch {
            await relay.stop()
            throw error
        }

        PeerPaneHostRegistry.shared.retain(lease)
        let paneSession = PeerPaneSession(
            lease: lease,
            relaySession: relay,
            surfaceTitle: exactSurface.title,
            originSpec: hostSpec,
            originSurface: exactSurface
        )
        PeerClientCoordinator.shared.registerPaneSession(paneSession)
        #if DEBUG
        let surfaceMarker = outcome.surfaceID.prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        dlog("peer.pane.ensureAttach surface=\(surfaceMarker) result=\(outcome.result) generation=\(outcome.generation)")
        #endif
        return (paneSession, outcome)
    }

    // ── Lifecycle ────────────────────────────────────────────────────

    /// Accept the relay binary's connection and start pumping. Call
    /// after the pane's Ghostty surface exists (the relay binary has
    /// been spawned as its shell).
    func start() async throws {
        try await relaySession.start()
    }

    /// Idempotent. Must run on every close path — stops the pane's
    /// relay session and drops the host-lease ref (last one stops the
    /// shared tunnel). The lease release is sequenced AFTER the relay
    /// session's own stop, so a last-pane teardown doesn't yank the
    /// tunnel out from under the session mid-shutdown (broken-pipe
    /// noise instead of an orderly Goodbye).
    func teardown() {
        guard !isTorndown else { return }
        isTorndown = true
        PeerClientCoordinator.shared.deregisterPaneSession(self)
        let session = relaySession
        let lease = lease
        Task { @MainActor in
            await session.stop()
            PeerPaneHostRegistry.shared.release(lease)
        }
        #if DEBUG
        dlog("peer.pane.teardown key=\(lease.key) surface=\(surfaceTitle)")
        #endif
        RemoteWorkLog.infoOffMain("Remote pane closed: \(surfaceTitle) on \(lease.key)")
    }
}
