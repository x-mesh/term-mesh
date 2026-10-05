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
enum PeerPaneHostSpec: Hashable, Sendable {
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

enum PeerPaneHostKey: Hashable, CustomStringConvertible, Sendable {
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

/// What `PeerPaneHostRegistry.acquire` may do with a lease it finds pooled.
enum PeerPaneHostLeaseVerdict: Equatable {
    /// Hand it out as-is.
    case usable
    /// The tunnel is restarting on its own; join that restart before deciding.
    case waitForRestart
    /// The tunnel gave up or was stopped. Retire it and build a replacement.
    case dead
}

/// Shared per-host resources leased by remote panes. Created/pooled by
/// `PeerPaneHostRegistry`; holders must balance every `acquire`/`retain`
/// with a `release`.
@MainActor
final class PeerPaneHostLease {
    let key: PeerPaneHostKey
    /// Everything needed to build a replacement tunnel to the same host. The
    /// key drops `identityFile` on purpose (it does not change which host is
    /// reached), so a re-acquire cannot be derived from the key alone.
    let spec: PeerPaneHostSpec
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
    fileprivate var registryID: PeerHostLeaseID?
    /// Whether consumers may still recover through this lease. Exposes the
    /// lifecycle fact without allowing another file to mutate ownership.
    var canReconnectTransport: Bool { !isTornDown }
    /// Coordinates transport resets across every pane sharing this host.
    /// Each relay remembers the generation it attached through; the first
    /// relay that reports that generation dead restarts SSH, while siblings
    /// wait for the same restart instead of killing the replacement again.
    private let transportRecovery = PeerPaneTransportRecovery()

    fileprivate init(spec: PeerPaneHostSpec, tunnel: PeerSSHTunnel?) {
        self.spec = spec
        self.key = spec.hostKey
        self.tunnel = tunnel
    }

    fileprivate func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        transportRecovery.cancel()
        tunnel?.stop()
    }

    var transportGeneration: UInt64 { transportRecovery.generation }

    #if DEBUG
    var transportRecoveryForTests: PeerPaneTransportRecovery { transportRecovery }
    #endif

    /// Replace a half-alive SSH forward and wait until its replacement is up.
    /// Direct Unix sockets have no owned transport to refresh.
    func refreshTransport(after observedGeneration: UInt64, reason: String) async -> UInt64 {
        guard !isTornDown, let tunnel else { return transportGeneration }
        RemoteWorkLog.infoOffMain(
            "Peer tunnel refresh start host=\(key) observedGen=\(observedGeneration) transportGen=\(transportGeneration) reason=\(reason)"
        )
        PeerFederationSettings.logInputLatencyLifecycle(
            "event=tunnel_refresh_start host=\(key) observed_gen=\(observedGeneration) transport_gen=\(transportGeneration) reason=\(reason)"
        )
        let generation = await transportRecovery.refresh(after: observedGeneration) {
            guard !self.isTornDown, !Task.isCancelled else { return false }
            // `forceReconnect` may spend up to three seconds reaping a stuck
            // ssh process. Never make that wait on the main actor.
            let scheduled = await Task.detached {
                tunnel.forceReconnect(reason: reason)
            }.value
            guard scheduled, !self.isTornDown, !Task.isCancelled else { return false }

            // `forceReconnect` schedules its replacement asynchronously. Its
            // state can still read `.up` for one turn, so require observing a
            // non-up transition before accepting the replacement `.up` — or,
            // failing that, a tunnel that is still up when the budget expires.
            let deadline = Date().addingTimeInterval(15)
            var sawRestart = false
            while true {
                let state = tunnel.currentState
                if state != .up { sawRestart = true }
                if let result = Self.recoveryResult(
                    for: state, sawRestart: sawRestart, timedOut: Date() >= deadline
                ) {
                    return result
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return false
                }
            }
        }
        RemoteWorkLog.infoOffMain(
            "Peer tunnel refresh end host=\(key) observedGen=\(observedGeneration) transportGen=\(generation) reason=\(reason)"
        )
        PeerFederationSettings.logInputLatencyLifecycle(
            "event=tunnel_refresh_end host=\(key) observed_gen=\(observedGeneration) transport_gen=\(generation) reason=\(reason)"
        )
        return generation
    }

    /// Whether a pooled lease is still worth handing out.
    ///
    /// A direct lease has no process to replace, so it is always usable: its
    /// daemon being down is for the consumer's own connect to discover, and a
    /// replacement would be the same object. For an SSH lease the tunnel
    /// state is the verdict, with one refinement — `.up` whose local socket
    /// refuses is in flight, not dead: ssh just exited and the `.down` emit
    /// has not landed yet, or the socket file is a ghost, and the restart the
    /// tunnel is about to run settles both.
    nonisolated static func leaseVerdict(
        state: PeerSSHTunnelState?,
        isTornDown: Bool,
        localSocketAccepts: Bool
    ) -> PeerPaneHostLeaseVerdict {
        if isTornDown { return .dead }
        guard let state else { return .usable }
        switch state {
        case .failed, .stopped: return .dead
        case .starting, .down, .reconnecting: return .waitForRestart
        case .up: return localSocketAccepts ? .usable : .waitForRestart
        }
    }

    nonisolated static func recoveryResult(
        for state: PeerSSHTunnelState,
        sawRestart: Bool,
        timedOut: Bool
    ) -> Bool? {
        if sawRestart, state == .up { return true }
        if case .failed = state { return false }
        if case .stopped = state { return false }
        // `forceReconnect` also returns true when it only joined a restart
        // that was already in flight, and that restart can finish before the
        // first poll — the tunnel then never leaves `.up` and the transition
        // this loop waits for never arrives. Calling that healthy tunnel a
        // failed recovery leaves the generation stale, so the next sibling
        // failure at the same observed generation runs a real forceReconnect
        // and SIGKILLs a working replacement. A tunnel that is up when the
        // budget expires is the outcome recovery asked for; take it.
        if timedOut { return state == .up }
        return nil
    }
}

/// Generation gate for pooled transport recovery. Kept separate from the SSH
/// implementation so the exactly-once rule is deterministic in unit tests.
@MainActor
final class PeerPaneTransportRecovery {
    private(set) var generation: UInt64 = 0
    private struct InFlightRefresh {
        let id: UUID
        let nextGeneration: UInt64
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UInt64, Never>]
    }
    private var inFlight: InFlightRefresh?

    func refresh(
        after observedGeneration: UInt64,
        action: @escaping @MainActor () async -> Bool
    ) async -> UInt64 {
        if observedGeneration < generation { return generation }

        let refreshID: UUID
        if let inFlight {
            refreshID = inFlight.id
        } else {
            let id = UUID()
            let nextGeneration = generation &+ 1
            let task = Task { [weak self] in
                let succeeded = await action()
                self?.finish(id: id, succeeded: succeeded)
            }
            inFlight = InFlightRefresh(
                id: id, nextGeneration: nextGeneration, task: task, waiters: [:]
            )
            refreshID = id
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, var refresh = inFlight, refresh.id == refreshID else {
                    continuation.resume(returning: generation)
                    return
                }
                refresh.waiters[waiterID] = continuation
                inFlight = refresh
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID, refreshID: refreshID)
            }
        }
    }

    func cancel() {
        guard let refresh = inFlight else { return }
        inFlight = nil
        refresh.task.cancel()
        for continuation in refresh.waiters.values {
            continuation.resume(returning: generation)
        }
    }

    private func cancelWaiter(id: UUID, refreshID: UUID) {
        guard var refresh = inFlight, refresh.id == refreshID,
              let continuation = refresh.waiters.removeValue(forKey: id)
        else { return }
        continuation.resume(returning: generation)
        if refresh.waiters.isEmpty {
            inFlight = nil
            refresh.task.cancel()
        } else {
            inFlight = refresh
        }
    }

    private func finish(id: UUID, succeeded: Bool) {
        guard let refresh = inFlight, refresh.id == id else { return }
        inFlight = nil
        if succeeded { generation = refresh.nextGeneration }
        for continuation in refresh.waiters.values {
            continuation.resume(returning: generation)
        }
    }
}

// MARK: - Registry

enum PeerPaneHostAcquireError: Error, CustomStringConvertible {
    /// Disconnect Host ended this host while this acquire was waiting on it.
    case hostDisconnected(PeerPaneHostKey)
    /// The lease this acquire waited on was retired and no replacement was
    /// started for it to join in time.
    case replacementUnavailable(PeerPaneHostKey)
    /// The replacement this acquire joined was dead by the time it got there.
    case replacementDied(PeerPaneHostKey)

    var description: String {
        switch self {
        case .hostDisconnected(let key):
            return "\(key.shortLabel) was disconnected while this connection was waiting on it"
        case .replacementUnavailable(let key):
            return "\(key.shortLabel)'s tunnel was replaced and no new connection came up to join"
        case .replacementDied(let key):
            return "\(key.shortLabel)'s replacement tunnel died before this connection could use it"
        }
    }
}

@MainActor
final class PeerPaneHostRegistry {
    static let shared = PeerPaneHostRegistry()

    private typealias Machine = PeerHostMachine<PeerPaneHostSpec, UUID>
    private typealias Core = PeerHostShellCore<PeerPaneHostSpec, UUID>

    private final class HostShell {
        let key: PeerPaneHostKey
        var core: Core!
        var leases: [PeerHostLeaseID: PeerPaneHostLease] = [:]
        var starts: [PeerHostAttemptID: Task<Void, Never>] = [:]
        var restarts: [PeerHostRestartID: Task<Void, Never>] = [:]
        var deadlines: [PeerHostWaiterID: Task<Void, Never>] = [:]
        var reconnectDeadline: Task<Void, Never>?
        var continuations: [PeerHostWaiterID: CheckedContinuation<PeerPaneHostLease, Error>] = [:]
        var waiterIDs: [UUID: PeerHostWaiterID] = [:]
        var startError: Error?

        init(key: PeerPaneHostKey) { self.key = key }
    }

    private var hosts: [PeerPaneHostKey: HostShell] = [:]
    private var nextSerial: UInt64 = 0
    static let replacementJoinDeadlineSeconds: TimeInterval = 15

    #if DEBUG
    private(set) var teardownCountForTests = 0
    var livenessOverrideForTests: ((PeerPaneHostLease) -> PeerPaneHostLeaseVerdict)?
    var restartWaitOverrideForTests: ((PeerPaneHostLease) async -> Bool)?
    var restartDelayForTests: ((PeerPaneHostLease) async -> Void)?
    private(set) var replacementCountForTests = 0
    var startDelayForTests: ((PeerPaneHostSpec) async -> Void)?
    var replacementJoinDeadlineForTests: TimeInterval?
    var leaseMadeForTests: ((PeerPaneHostLease) -> Void)?
    var deadLeaseObservedForTests: ((PeerPaneHostLease) -> Void)?
    #endif

    var hostTransportWillRetire: (@MainActor (PeerPaneHostKey) -> Void)?
    var hostTransportDidReplace: (@MainActor (PeerPaneHostKey, PeerPaneHostLease) -> Void)?
    var hostTransportReplacementAbandoned: (@MainActor (PeerPaneHostKey) -> Void)?

    private func serial() -> UInt64 {
        nextSerial += 1
        return nextSerial
    }

    private func shell(for key: PeerPaneHostKey) -> HostShell {
        if let shell = hosts[key] { return shell }
        let shell = HostShell(key: key)
        shell.core = Core(
            sampleVerdict: { [weak self, weak shell] id in
                guard let self, let lease = shell?.leases[id] else { return .dead }
                switch self.liveness(of: lease) {
                case .usable: return .usable
                case .waitForRestart: return .restarting
                case .dead:
                    #if DEBUG
                    self.deadLeaseObservedForTests?(lease)
                    #endif
                    return .dead
                }
            },
            perform: { [weak self, weak shell] effect, context in
                guard let self, let shell else { return }
                self.perform(effect, context: context, shell: shell)
            },
            shellOnlyReference: { [weak shell] id, delta in
                guard let shell, let lease = shell.leases[id] else { return }
                lease.refCount += delta
                if lease.refCount == 0, lease.isTornDown { shell.leases[id] = nil }
            }
        )
        hosts[key] = shell
        return shell
    }

    func liveness(of lease: PeerPaneHostLease) -> PeerPaneHostLeaseVerdict {
        #if DEBUG
        if let override = livenessOverrideForTests { return override(lease) }
        #endif
        let state = lease.tunnel?.currentState
        let accepts = state == .up
            && TermMeshDaemon.isListening(atUnixSocketPath: lease.hostSockPath)
        return PeerPaneHostLease.leaseVerdict(
            state: state, isTornDown: lease.isTornDown, localSocketAccepts: accepts
        )
    }

    func existingLocalSockPath(for key: PeerPaneHostKey) -> String? {
        guard let path = activeLease(forKey: key)?.hostSockPath, !path.isEmpty else { return nil }
        return path
    }

    func acquire(_ spec: PeerPaneHostSpec) async throws -> PeerPaneHostLease {
        try await acquire(spec, waiter: UUID())
    }

    func acquire(
        _ spec: PeerPaneHostSpec,
        waiter: UUID,
        token: UUID? = nil,
        background: Bool = false
    ) async throws -> PeerPaneHostLease {
        let shell = shell(for: spec.hostKey)
        precondition(shell.waiterIDs[waiter] == nil, "each acquire must use its own waiter ID")
        let generation = shell.core.state.generation
        var origin: Machine.Origin = background ? .sweep : .user
        var requestToken = token
        while true {
            let id = PeerHostWaiterID(serial())
            let request = Machine.AcquireRequest(
                waiter: id, origin: origin, generation: generation, spec: spec, token: requestToken
            )
            let lease = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    shell.continuations[id] = continuation
                    shell.waiterIDs[waiter] = id
                    shell.core.acquire(request)
                }
            } onCancel: {
                Task { @MainActor in shell.core.deliver(.cancel(id)) }
            }
            if Task.isCancelled {
                release(lease)
                throw CancellationError()
            }
            guard shell.core.state.generation == generation else {
                release(lease)
                throw PeerPaneHostAcquireError.hostDisconnected(spec.hostKey)
            }
            if !lease.isTornDown { return lease }
            release(lease)
            origin = .waiter
            requestToken = nil
        }
    }

    private func perform(_ effect: Machine.Effect, context: Core.EffectContext, shell: HostShell) {
        switch effect {
        case let .startTunnel(attempt, spec):
            shell.starts[attempt] = Task { [self] in
                do {
                    #if DEBUG
                    if let delay = startDelayForTests { await delay(spec) }
                    #endif
                    try Task.checkCancellation()
                    let lease = try await Self.makeLease(spec: spec)
                    let id = PeerHostLeaseID(serial())
                    lease.registryID = id
                    shell.leases[id] = lease
                    #if DEBUG
                    leaseMadeForTests?(lease)
                    #endif
                    shell.starts[attempt] = nil
                    shell.core.deliver(.startFinished(attempt, .lease(id)))
                } catch {
                    shell.starts[attempt] = nil
                    shell.startError = error
                    shell.core.deliver(.startFinished(attempt, .failure))
                    shell.startError = nil
                }
            }
        case let .cancelStart(attempt):
            shell.starts.removeValue(forKey: attempt)?.cancel()
        case let .stopTunnel(id):
            guard let lease = shell.leases[id] else { return }
            switch context.before.phase {
            case let .up(current, _, refs) where current == id,
                 let .restarting(current, _, _, refs) where current == id:
                lease.refCount = refs
            default: break
            }
            teardown(lease)
            if lease.refCount == 0 { shell.leases[id] = nil }
        case let .resume(id, outcome):
            shell.deadlines.removeValue(forKey: id)?.cancel()
            shell.waiterIDs = shell.waiterIDs.filter { $0.value != id }
            guard let continuation = shell.continuations.removeValue(forKey: id) else { return }
            switch outcome {
            case let .lease(leaseID):
                guard let lease = shell.leases[leaseID] else {
                    preconditionFailure("machine resumed a lease that the shell does not own")
                }
                continuation.resume(returning: lease)
            case let .failure(failure):
                let error: Error
                switch failure {
                case .cancelled: error = CancellationError()
                case .hostDisconnected: error = PeerPaneHostAcquireError.hostDisconnected(shell.key)
                case .replacementUnavailable, .timedOut:
                    error = PeerPaneHostAcquireError.replacementUnavailable(shell.key)
                case .startFailed:
                    guard let underlying = shell.startError else {
                        preconditionFailure("startFinished failure must carry the tunnel error")
                    }
                    error = underlying
                case .reconnectSuperseded: error = failure
                }
                continuation.resume(throwing: error)
            }
        case let .fireWillRetire(id):
            if let lease = shell.leases[id] {
                #if DEBUG
                deadLeaseObservedForTests?(lease)
                #endif
            }
            hostTransportWillRetire?(shell.key)
        case let .fireDidReplace(id):
            guard let lease = shell.leases[id] else { return }
            #if DEBUG
            replacementCountForTests += 1
            #endif
            hostTransportDidReplace?(shell.key, lease)
        case .fireAbandoned:
            hostTransportReplacementAbandoned?(shell.key)
        case let .armWaiterDeadline(id):
            let budget = deadlineSeconds
            shell.deadlines[id] = Task {
                do { try await Task.sleep(for: .seconds(budget)) } catch { return }
                shell.core.deliver(.waiterDeadline(id))
            }
        case let .armReconnectDeadline(token):
            shell.reconnectDeadline?.cancel()
            let budget = deadlineSeconds
            shell.reconnectDeadline = Task {
                do { try await Task.sleep(for: .seconds(budget)) } catch { return }
                shell.core.deliver(.reconnectDeadline(token))
            }
        case let .waitRestart(id, restart):
            guard let lease = shell.leases[id] else { return }
            let observed = lease.transportGeneration
            shell.restarts[restart] = Task { [self] in
                #if DEBUG
                if let delay = restartDelayForTests { await delay(lease) }
                #endif
                let cameBack = await waitForRestart(of: lease, after: observed)
                shell.restarts[restart] = nil
                shell.core.deliver(.restartFinished(id, restart, cameBack: cameBack))
            }
        case .queueUnusedCheck:
            preconditionFailure("unusedCheck is owned by PeerHostShellCore")
        }
    }

    private var deadlineSeconds: TimeInterval {
        #if DEBUG
        if let override = replacementJoinDeadlineForTests { return override }
        #endif
        return Self.replacementJoinDeadlineSeconds
    }

    private func waitForRestart(of lease: PeerPaneHostLease, after observed: UInt64) async -> Bool {
        #if DEBUG
        if let override = restartWaitOverrideForTests { return await override(lease) }
        #endif
        let after = await lease.refreshTransport(
            after: observed, reason: "acquire found the tunnel restarting"
        )
        return after > observed
    }

    func pendingReplacementToken(for key: PeerPaneHostKey) -> UUID? {
        hosts[key]?.core.state.reconnectToken
    }

    func abandonPendingReplacement(for key: PeerPaneHostKey, token: UUID? = nil, moved: Bool = false) {
        guard let shell = hosts[key], let current = shell.core.state.reconnectToken,
              token == nil || token == current else { return }
        shell.core.deliver(.reconnectAbandoned(current, moved: moved))
    }

    @discardableResult
    func cancelPendingAcquire(for key: PeerPaneHostKey, waiter: UUID? = nil) -> Bool {
        guard let shell = hosts[key] else { return true }
        let id: PeerHostWaiterID
        if let waiter {
            guard let current = shell.waiterIDs[waiter] else { return true }
            id = current
        } else {
            guard shell.core.state.waiters.count <= 1 else { return false }
            guard let current = shell.core.state.waiters.first else { return true }
            id = current.id
        }
        shell.core.deliver(.cancel(id))
        return true
    }

    func endTransportForForceDisconnect(for key: PeerPaneHostKey) {
        shell(for: key).core.deliver(.disconnect(.force))
    }

    #if DEBUG
    func pendingWaiterCountForTests(for key: PeerPaneHostKey) -> Int {
        hosts[key]?.core.state.waiters.count ?? 0
    }
    #endif

    func retain(_ lease: PeerPaneHostLease) {
        guard let id = lease.registryID else { return }
        shell(for: lease.key).core.retain(id)
    }

    func release(_ lease: PeerPaneHostLease) {
        guard let id = lease.registryID else { return }
        shell(for: lease.key).core.release(id)
    }

    @discardableResult
    func disconnectTransport(for key: PeerPaneHostKey, replacementFollows: Bool = false) -> String? {
        let path = activeLease(forKey: key)?.hostSockPath
        shell(for: key).core.deliver(.disconnect(replacementFollows ? .reconnect(UUID()) : .plain))
        return path
    }

    private func teardown(_ lease: PeerPaneHostLease) {
        let wasTornDown = lease.isTornDown
        lease.teardown()
        #if DEBUG
        if !wasTornDown { teardownCountForTests += 1 }
        #endif
    }

    func pooledLeases() -> [(key: PeerPaneHostKey, lease: PeerPaneHostLease)] {
        hosts.compactMap { key, _ in
            activeLease(forKey: key).map { (key: key, lease: $0) }
        }
    }

    func activeLease(forKey key: PeerPaneHostKey) -> PeerPaneHostLease? {
        guard let shell = hosts[key], let id = shell.core.state.pooledLease else { return nil }
        return shell.leases[id]
    }
    var activeLeaseCount: Int { pooledLeases().count }

    private static func makeLease(spec: PeerPaneHostSpec) async throws -> PeerPaneHostLease {
        switch spec {
        case .direct:
            return PeerPaneHostLease(spec: spec, tunnel: nil)
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
            return PeerPaneHostLease(spec: spec, tunnel: tunnel)
        }
    }
}

// MARK: - Per-pane session

/// The session bundle a remote pane's TerminalPanel owns: the pane's
/// relay session plus the host lease it holds a ref on.
@MainActor
final class PeerPaneSession {
    enum RelayStartupState: String, Equatable, Sendable {
        case pending
        case starting
        case started
        case failed
    }

    /// User-facing aggregate state for a pane. `relayLiveness` deliberately
    /// describes only the attached transport and therefore reads `.live`
    /// before the local relay helper has even been requested. Keep that
    /// transport contract intact, but never expose it as the pane's overall
    /// health without folding in startup and teardown.
    enum PaneHealth: String, Equatable, Sendable {
        case pending
        case starting
        case live
        case reconnecting
        case ended
        case failed
    }

    /// Replaced only by `retarget(to:)`, when the host's tunnel is replaced
    /// under a pane that keeps its relay helper.
    private(set) var lease: PeerPaneHostLease
    let relaySession: PeerRelaySession
    let surfaceTitle: String
    let connectedAt = Date()
    private(set) var isTorndown = false
    /// Distinguishes an explicit host-level transport stop from an accidental
    /// relay failure. Agent panes normally recreate themselves on failure;
    /// an intentional disconnect must keep the visible pane in place instead.
    private(set) var hostTransportWasDisconnected = false
    private(set) var relayStartupState: RelayStartupState = .pending
    var relayStartupFailure: (@MainActor (Error) -> Void)?
    var relayStartupSucceeded: (@MainActor () -> Void)?

    /// Reattach recipe for the disconnect banner's Reconnect action:
    /// how this pane's host was reached and which surface it mirrored.
    let originSpec: PeerPaneHostSpec
    let originSurface: Termmesh_Peer_V1_SurfaceInfo
    private(set) var usesLivePresentation = false

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
            sshPort: lease.tunnel?.port,
            identityFile: lease.tunnel?.identityFile,
            remoteSockPath: lease.key.remoteSockPath,
            targetTitle: surfaceTitle.isEmpty ? "<surface>" : surfaceTitle,
            connectedAt: connectedAt
        )
    }

    // Pane-command plumbing for TerminalPanel creation (t2).
    var relayLaunchCommand: String { relaySession.relayLaunchCommand }
    var relayEnvironment: [String: String] { relaySession.relayEnvironment }
    var isRelayStarted: Bool { relayStartupState == .started && !isTorndown }

    /// Where this pane's transport stands RIGHT NOW.
    ///
    /// `isRelayStarted` above cannot answer that and must not be changed to
    /// try: `relayStartupState` is a start latch — written once when the
    /// first `start()` returns and never again — and `TeamOrchestrator`'s
    /// remote-leader recovery depends on exactly that latching. A pane whose
    /// relay died and whose uncapped retry loop will never succeed still
    /// reports `.started` forever, which is why "keep the panes that
    /// recovered" cannot be spelled with it.
    var relayLiveness: PeerRelaySession.TransportLiveness {
        isTorndown ? .ended : relaySession.transportLiveness
    }

    var paneHealth: PaneHealth {
        Self.derivePaneHealth(
            startupState: relayStartupState,
            relayLiveness: relayLiveness,
            isTorndown: isTorndown,
            requiresRelayStartup: relaySession.usesRelayHelper
        )
    }

    /// Pure form used by status surfaces and regression tests. Teardown wins
    /// over every latched state; otherwise startup must complete before the
    /// transport is allowed to call the whole pane live.
    nonisolated static func derivePaneHealth(
        startupState: RelayStartupState,
        relayLiveness: PeerRelaySession.TransportLiveness,
        isTorndown: Bool,
        requiresRelayStartup: Bool = true
    ) -> PaneHealth {
        if isTorndown { return .ended }
        if !requiresRelayStartup {
            switch relayLiveness {
            case .live: return .live
            case .reconnecting: return .reconnecting
            case .ended: return .ended
            }
        }
        switch startupState {
        case .pending: return .pending
        case .starting: return .starting
        case .failed: return .failed
        case .started:
            switch relayLiveness {
            case .live: return .live
            case .reconnecting: return .reconnecting
            case .ended: return .ended
            }
        }
    }

    /// Started, and its transport is up. The only state in which a mirrored
    /// pane may be kept across a reconnect with nothing further owed to it.
    var isRelayLive: Bool { relayStartupState == .started && relayLiveness == .live }

    /// Started, and its own retry loop currently holds it. Worth keeping —
    /// respawning would throw away a recovery already in progress — but only
    /// under a deadline, because that loop is uncapped.
    var isRelayRecovering: Bool {
        relayStartupState == .started && relayLiveness == .reconnecting
    }

    /// The relay is finished: it renders nothing and never will again,
    /// whether this pane session was torn down or only its relay was.
    var isRelayEnded: Bool { relayLiveness == .ended }

    /// Start only after SwiftUI has mounted this panel. Background Project
    /// restoration creates pane models before their Ghostty views exist;
    /// starting here at model creation used to arm a 10s accept timeout that
    /// could never succeed. Multiple onAppear/update passes remain idempotent.
    func startRelayIfNeeded() {
        #if DEBUG
        // "Never asked to start" and "asked, but the accept never resolved"
        // leave identical outside state — a pane stuck on `.pending`/`.starting`
        // with no relay. Name which one happened.
        dlog(
            "peer.pane.relay.request surface=\(surfaceTitle) "
                + "state=\(relayStartupState) torndown=\(isTorndown)"
        )
        #endif
        guard !isTorndown, relayStartupState == .pending else { return }
        relayStartupState = .starting
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.start()
                guard !self.isTorndown else { return }
                self.relayStartupState = .started
                #if DEBUG
                dlog("peer.pane.relay.started surface=\(self.surfaceTitle)")
                #endif
                self.relayStartupSucceeded?()
            } catch {
                guard !self.isTorndown else { return }
                self.relayStartupState = .failed
                #if DEBUG
                dlog(
                    "peer.pane.relay.failed surface=\(self.surfaceTitle) error=\(error)"
                )
                #endif
                self.relayStartupFailure?(error)
            }
        }
    }

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

    /// Read the daemon's live surface roster and its project manifests on one
    /// authenticated connection. SessionHostPanes needs both answers from the
    /// same endpoint: a surface id without its project identity is how a
    /// term-mesh worker was opened in whichever unrelated workspace happened
    /// to be selected (for example `xm`).
    static func listSessionHostSnapshot(
        on lease: PeerPaneHostLease
    ) async throws -> (surfaces: [Termmesh_Peer_V1_SurfaceInfo], teams: [Termmesh_Peer_V1_Team]) {
        let connection = try await PeerRelaySession.connectAndList(
            hostSockPath: lease.hostSockPath
        )
        if lease.hostDisplayName.isEmpty {
            lease.hostDisplayName = connection.hostDisplayName
        }
        let teams: [Termmesh_Peer_V1_Team]
        if connection.hostCapabilities.has(PeerCapability.teamRosterV1) {
            do {
                teams = try await connection.session.listTeams()
            } catch {
                await connection.cancel()
                throw error
            }
        } else {
            teams = []
        }
        let surfaces = connection.surfaces
        await connection.cancel()
        return (surfaces, teams)
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
        let transportGeneration = lease.transportGeneration
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
        installOwnedTransportRecovery(on: relay, lease: lease, generation: transportGeneration)
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
        paneSession.usesLivePresentation = surface.surfaceType == "agent"
            && conn.hostCapabilities.has(PeerCapability.agentPresentationV1)
        // Roster registration keeps the sidebar's Remote Hosts section
        // and the Connections panel in sync with pane-based connections;
        // teardown() balances it.
        PeerClientCoordinator.shared.registerPaneSession(paneSession)
        #if DEBUG
        dlog("peer.pane.attach key=\(lease.key) surface=\(title)")
        #endif
        RemoteWorkLog.infoOffMain(
            "Remote pane attached: \(title) "
                + "surface=\(surface.surfaceID.map { String(format: "%02x", $0) }.joined()) "
                + "on \(lease.key)"
        )
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
        let transportGeneration = lease.transportGeneration
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
        relay.hostKey = lease.key
        installOwnedTransportRecovery(on: relay, lease: lease, generation: transportGeneration)
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
    private static func installOwnedTransportRecovery(
        on relay: PeerRelaySession,
        lease: PeerPaneHostLease,
        generation: UInt64
    ) {
        relay.configureOwnedTransportRecovery(
            generation: generation,
            mayReconnect: { [weak lease] in lease?.canReconnectTransport == true },
            handler: { [weak lease] generation in
                guard let lease else { return generation }
                return await lease.refreshTransport(
                    after: generation,
                    reason: "owned peer session stopped responding"
                )
            }
        )
    }

    /// Move this pane onto the lease that replaced the one it attached
    /// through, keeping its relay helper, Ghostty surface, and scrollback.
    /// False when the pane cannot move — torn down, a different host, or a
    /// relay that already ended — and only a respawn brings it back.
    @discardableResult
    func retarget(to replacement: PeerPaneHostLease) -> Bool {
        guard Self.mayRetarget(
            isTorndown: isTorndown,
            sameHost: replacement.key == lease.key,
            sameLease: replacement === lease,
            replacementIsActive: replacement.canReconnectTransport
        ) else { return false }
        let moved = relaySession.retargetOwnedTransport(
            hostSockPath: replacement.hostSockPath,
            hostKey: replacement.key,
            generation: replacement.transportGeneration,
            mayReconnect: { [weak replacement] in replacement?.canReconnectTransport == true },
            handler: { [weak replacement] generation in
                guard let replacement else { return generation }
                return await replacement.refreshTransport(
                    after: generation,
                    reason: "owned peer session stopped responding"
                )
            }
        )
        guard moved else { return false }
        PeerPaneHostRegistry.shared.retain(replacement)
        let previous = lease
        lease = replacement
        PeerPaneHostRegistry.shared.release(previous)
        hostTransportWasDisconnected = false
        return true
    }

    enum HostReconnectReattach: Equatable {
        /// Moved onto the replacement; nothing else to do.
        case moved
        /// Rebuild the pane against the replacement, finding its surface again.
        case rebuild
        /// Leave the pane on its banner for the user's own Reconnect.
        case leaveBanner
    }

    /// What a host reconnect does for a pane that Disconnect Host preserved.
    /// A pane whose surface the host already refused stays on its banner: a
    /// rebuild nobody watches would pick a surface by title, and several such
    /// panes could land on one unrelated shell.
    nonisolated static func hostReconnectReattach(
        retargeted: Bool,
        surfaceWasRejected: Bool
    ) -> HostReconnectReattach {
        if retargeted { return .moved }
        if surfaceWasRejected { return .leaveBanner }
        return .rebuild
    }

    nonisolated static func mayRetarget(
        isTorndown: Bool,
        sameHost: Bool,
        sameLease: Bool,
        replacementIsActive: Bool
    ) -> Bool {
        !isTorndown && sameHost && !sameLease && replacementIsActive
    }

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

    /// Explicit pane Retry uses the same pooled reset as automatic heartbeat
    /// recovery, so it cannot immediately redial a known half-alive socket.
    func refreshHostTransportForReconnect() async {
        await relaySession.refreshOwnedTransportForReconnect(
            reason: "remote pane reconnect requested"
        )
    }

    /// Preserve this pane while its host transport is intentionally ended.
    /// SSH panes will receive EOF when the pooled tunnel stops. Direct-socket
    /// panes have no tunnel to stop, so their owned relay is stopped here.
    func prepareForHostTransportDisconnect(stopRelay: Bool) {
        hostTransportWasDisconnected = true
        guard stopRelay else {
            // The tunnel's EOF is about to reach this relay. Parking it keeps
            // the helper (the pane's shell) alive for `retarget(to:)`.
            relaySession.awaitTransportReplacement()
            return
        }
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
