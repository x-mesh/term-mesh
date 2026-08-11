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

    /// A direct connection to this app's own peer server would attach the
    /// viewer to itself.  SSH endpoints deliberately return false: their
    /// local socket is a tunnel and cannot identify the far peer without a
    /// completed handshake.
    var targetsLocalPeerServer: Bool {
        guard case let .direct(sockPath) = self else { return false }
        return (sockPath as NSString).standardizingPath
            == (PeerFederationSettings.socketPath as NSString).standardizingPath
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
    /// A user-initiated host disconnect can stop this lease while pane refs
    /// still exist. Their later releases must not stop it a second time (or,
    /// more importantly, disturb a replacement lease for the same host).
    fileprivate var isTornDown = false

    fileprivate init(key: PeerPaneHostKey, tunnel: PeerSSHTunnel?) {
        self.key = key
        self.tunnel = tunnel
    }

    fileprivate func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
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
    /// Returns false when a pending start exists but could not be cancelled
    /// because other panes are waiting on it. Callers that promise the user a
    /// fresh attempt (sidebar Retry, `peer.host.retry`) must not claim to have
    /// restarted anything in that case — `connectSavedHost` would simply
    /// rejoin the same hung task and add one more waiter.
    @discardableResult
    func cancelPendingAcquire(for key: PeerPaneHostKey) -> Bool {
        guard let startingLease = starting[key] else { return true }
        guard startingLease.waiters <= 1 else {
            #if DEBUG
            dlog("peer.pane.acquire.cancel.shared key=\(key) waiters=\(startingLease.waiters)")
            #endif
            return false
        }
        starting[key] = nil
        startingLease.task.cancel()
        return true
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
        // A host disconnect removes a still-referenced lease from the pool so
        // Reconnect can create a fresh tunnel. Releasing that retired lease
        // later must not evict the replacement.
        if leases[lease.key] === lease {
            leases[lease.key] = nil
        }
        teardown(lease)
        #if DEBUG
        dlog("peer.pane.lease.down key=\(lease.key)")
        #endif
    }

    /// End this host's pooled transport without releasing pane/mirror refs.
    /// Existing views keep their session objects and receive ordinary EOF,
    /// which drives their disconnected UI. A later acquire creates a fresh
    /// lease instead of reviving this stopped tunnel.
    @discardableResult
    func disconnectTransport(for key: PeerPaneHostKey) -> String? {
        guard let lease = leases[key] else { return nil }
        leases[key] = nil
        let sockPath = lease.hostSockPath
        teardown(lease)
        #if DEBUG
        dlog("peer.pane.lease.disconnect key=\(key) refs=\(lease.refCount)")
        #endif
        return sockPath
    }

    /// Single teardown funnel so every path that stops a tunnel is counted.
    private func teardown(_ lease: PeerPaneHostLease) {
        let wasTornDown = lease.isTornDown
        lease.teardown()
        #if DEBUG
        if !wasTornDown { teardownCountForTests += 1 }
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
    /// Distinguishes an explicit host-level transport stop from an accidental
    /// relay failure. Agent panes normally recreate themselves on failure;
    /// an intentional disconnect must keep the visible pane in place instead.
    private(set) var hostTransportWasDisconnected = false

    /// Reattach recipe for the disconnect banner's Reconnect action:
    /// how this pane's host was reached and which surface it mirrored.
    let originSpec: PeerPaneHostSpec
    let originSurface: Termmesh_Peer_V1_SurfaceInfo

    /// Set by the pane host (Workspace.openRemotePane) so roster-driven
    /// disconnects can close the hosting pane instead of leaving a dead
    /// relay shell behind.
    var requestPaneClose: (@MainActor () -> Void)?

    /// Set by `Workspace.bindRemoteAgentPane` for a native agent pane that an
    /// intentional disconnect preserves. Preserving it keeps the transcript on
    /// screen but leaves a pane whose transport is gone, so the host coming
    /// back is what turns it live again — the pane is rebuilt against the same
    /// surface and the peer's daemon replays what was said meanwhile. A
    /// terminal pane leaves this nil: it has a Reconnect banner of its own.
    var requestHostReconnectReattach: (@MainActor () -> Void)?

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

    /// Ask the host for one more shell, and return it once it exists.
    ///
    /// A host publishes a fixed roster of surfaces (`TERMMESH_PEER_SURFACES`),
    /// and a surface can be attached once, so that roster is a hard ceiling on
    /// how many agents can run there — usually one. The host can already make
    /// more: splitting a pane forks a login shell in the source pane's
    /// directory, which is how a person adds one from a mirrored window. This
    /// asks for the same thing without the window.
    ///
    /// The request is fire-and-forget, so the new surface is waited for rather
    /// than returned. `source` is the pane to split — an existing surface on
    /// that host, whose directory the new shell inherits.
    static func spawnSurface(
        on lease: PeerPaneHostLease,
        splitting source: Data,
        timeout: TimeInterval = 10
    ) async throws -> Termmesh_Peer_V1_SurfaceInfo? {
        let before = Set(try await listSurfaces(on: lease).map(\.surfaceID))
        let conn = try await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
        do {
            try await conn.session.requestSplitPane(paneID: source, orientation: "vertical")
        } catch {
            await conn.cancel()
            throw error
        }
        await conn.cancel()

        let deadline = Date().addingTimeInterval(timeout)
        // Enough to tell the two failures apart on the next occurrence:
        // nothing was ever added (the split did not happen, or its pane never
        // realized) versus something was added and the filter rejected it.
        var lastCount = before.count
        var everAdded = 0
        var sourceStillListed = true
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let now = try await listSurfaces(on: lease)
            lastCount = now.count
            everAdded = max(everAdded, now.filter { !before.contains($0.surfaceID) }.count)
            sourceStillListed = now.contains { $0.surfaceID == source }
            // "New since the split request" is the whole detection, so an
            // agent surface someone ensured concurrently would match too —
            // and the caller is waiting for a SHELL to type a launch
            // command into. Only a terminal-typed surface counts as the
            // split this asked for.
            if let fresh = now.first(where: {
                !before.contains($0.surfaceID) && $0.attachable
                    && !SessionHostPanes.isAgentSurfaceType($0.surfaceType)
            }) {
                return fresh
            }
        }
        // Nothing appeared. The request cannot fail loudly — it is
        // fire-and-forget — so record what was asked of whom; the host logs
        // its own refusal (`peer.host.splitPane rejected`), and the two lines
        // together name a cause that neither has alone. The commonest one is a
        // source pane the host lists but no longer holds.
        #if DEBUG
        dlog("peer.pane.spawnSurface timeout "
            + "source=\(source.map { String(format: "%02x", $0) }.joined().prefix(8)) "
            + "before=\(before.count) last=\(lastCount) added=\(everAdded) "
            + "sourceListed=\(sourceStillListed)")
        #endif
        return nil
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
            // Agent surfaces carry NDJSON, not a terminal byte stream: route
            // their PtyData to the in-process callback (AgentSession.consume)
            // instead of spawning the relay binary as a pane shell.
            relay = try await PeerRelaySession.attach(
                conn,
                surface: surface,
                ptyDelivery: SessionHostPanes.isAgentSurfaceType(surface.surfaceType)
                    ? .callback : .relaySocket
            )
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
    ///
    /// `agentCli` labels an agent-kind ensure for the renderer. It is not a
    /// second wire field: the daemon reads the same label out of the spec's
    /// own `--cli <name>` argument, and `EnsureSurfaceResponse` carries no
    /// `SurfaceInfo` to read it back from — so the exact surface synthesised
    /// here has to be told. Ignored for a terminal kind.
    static func ensureAndAttach(
        lease: PeerPaneHostLease,
        surfaceSpec: PeerRunnerSurfaceSpec,
        attachment: PeerRunnerAttachment,
        hostSpec: PeerPaneHostSpec,
        agentCli: String = "",
        environment: [String: String] = [:],
        onEnsured: () -> Void = {},
        onAgentPostEnsureFailure: ((Data) -> Void)? = nil
    ) async throws -> (session: PeerPaneSession, outcome: PeerEnsureSurfaceOutcome) {
        // Validate before opening a transport or issuing EnsureSurface. Keeping
        // the typed local error intact gives callers an actionable key/limit
        // diagnosis instead of misreporting invalid saved/profile data as a
        // generic refusal by the host. Validation errors never include values.
        try PeerEnsureEnvironment.validate(environment)
        let conn = try await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
        if lease.hostDisplayName.isEmpty {
            lease.hostDisplayName = conn.hostDisplayName
        }

        let outcome: PeerEnsureSurfaceOutcome
        do {
            outcome = try await PeerRelaySession.ensureSurface(
                conn,
                spec: surfaceSpec,
                environment: environment
            )
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
        // The ensured kind IS the surface type; an empty kind is the terminal
        // that predates the field. Getting this wrong is not cosmetic — it is
        // what `Workspace.openRemoteAgentPane` gates on, so a mislabelled
        // agent surface renders as a terminal full of raw NDJSON.
        exactSurface.surfaceType = surfaceSpec.kind.isEmpty
            ? "terminal" : surfaceSpec.kind
        let isAgent = SessionHostPanes.isAgentSurfaceType(exactSurface.surfaceType)
        if isAgent {
            exactSurface.agentCli = agentCli
        }
        exactSurface.attachable = true
        exactSurface.cwd = surfaceSpec.cwd

        // The ensure is the point of no return on the host: a child is running
        // there now and `outcome.surfaceID` is the only thing that can name it.
        // Everything below can still fail, and a plain `throw` would drop that
        // id on the floor — leaving a bridge nobody can address, in no
        // workspace tree, in no `ManagedPeerSurfaceStore`, reachable by no
        // cleanup UI. So the failure pays for the ensure first.
        //
        // Agent kinds only, and the distinction is not caution: a terminal
        // runner surface is keyed to a saved profile the user re-launches, and
        // reusing that exact surface is the contract
        // (`test_savedRunnerRepeatedLaunchReusesExactEnsuredSurfaceID`).
        // Terminating one because an attach blipped would throw away the
        // session it exists to preserve. An agent surface is keyed to a
        // single agent instance that no longer exists once this throws.
        func compensateEnsure() async {
            guard isAgent else { return }
            if let onAgentPostEnsureFailure {
                onAgentPostEnsureFailure(outcome.surfaceID)
                return
            }
            await terminateSurface(
                hostSockPath: lease.hostSockPath,
                surfaceID: outcome.surfaceID
            )
        }

        let relay: PeerRelaySession
        do {
            // Same rule as the roster path above: an agent surface carries
            // NDJSON for `AgentSession.consume`, not a terminal byte stream
            // for the relay helper.
            relay = try await PeerRelaySession.attach(
                conn,
                surface: exactSurface,
                ptyDelivery: isAgent ? .callback : .relaySocket
            )
        } catch {
            await conn.cancel()
            await compensateEnsure()
            throw error
        }
        do {
            try relay.prepareListener()
        } catch {
            await relay.stop()
            await compensateEnsure()
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

    /// Stop one ensured surface on its host, on a connection opened for the
    /// purpose.
    ///
    /// The right verb for an *agent* surface and the only one that works:
    /// such a surface is deliberately never placed in the workspace tree, so
    /// a close-by-pane-id finds nothing and reports success while the bridge
    /// keeps running. TerminateSurface addresses the host's registry.
    ///
    /// Best effort by design. Every caller is already unwinding something, and
    /// a host that cannot be reached to clean up is not a second error to
    /// report on top of the first. A fresh connection is required rather than
    /// convenient: this is a direct-response RPC, so it cannot share a
    /// connection that has an ensure in flight or an inbound pump running.
    static func terminateSurface(hostSockPath: String, surfaceID: Data) async {
        guard !hostSockPath.isEmpty, !surfaceID.isEmpty,
              let connection = try? await PeerRelaySession.connect(hostSockPath: hostSockPath)
        else { return }
        do {
            try await connection.session.terminateSurface(surfaceID: surfaceID)
        } catch {
            RemoteWorkLog.infoOffMain(
                "Could not terminate the peer agent surface: \(String(describing: error))"
            )
        }
        await connection.cancel()
    }

    // ── Lifecycle ────────────────────────────────────────────────────

    /// Accept the relay binary's connection and start pumping. Call
    /// after the pane's Ghostty surface exists (the relay binary has
    /// been spawned as its shell).
    func start() async throws {
        try await relaySession.start()
    }

    /// Preserve this pane while its host transport is intentionally ended.
    /// SSH panes will receive EOF when the pooled tunnel stops. Direct-socket
    /// panes have no tunnel to stop, so their owned relay is stopped here.
    func prepareForHostTransportDisconnect(stopRelay: Bool) {
        hostTransportWasDisconnected = true
        guard stopRelay else { return }
        Task { await relaySession.stop() }
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
