import Foundation

public protocol PeerHostIDTag {
    static var prefix: String { get }
}

public struct PeerHostID<Tag: PeerHostIDTag>: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        "\(Tag.prefix)\(rawValue)"
    }
}

public enum PeerHostLeaseTag: PeerHostIDTag { public static let prefix = "L" }
public enum PeerHostWaiterTag: PeerHostIDTag { public static let prefix = "w" }
public enum PeerHostAttemptTag: PeerHostIDTag { public static let prefix = "a" }
public enum PeerHostRestartTag: PeerHostIDTag { public static let prefix = "r" }

public typealias PeerHostLeaseID = PeerHostID<PeerHostLeaseTag>
public typealias PeerHostWaiterID = PeerHostID<PeerHostWaiterTag>
public typealias PeerHostAttemptID = PeerHostID<PeerHostAttemptTag>
public typealias PeerHostRestartID = PeerHostID<PeerHostRestartTag>

/// One host key's tunnel lifecycle as a pure reducer.
///
/// Specified in `docs/peer-host-registry-redesign.md`, against the contract in
/// `docs/peer-host-registry-invariants.md`. `reduce` never waits; anything
/// that takes time is an `Effect` whose completion comes back as an `Event`.
public enum PeerHostMachine<Spec: Hashable & Sendable, Token: Hashable & Sendable> {
    public enum Origin: Hashable, Sendable {
        case user
        case sweep
        case waiter
    }

    public enum StartPurpose: Hashable, Sendable {
        case fresh
        case replacement
        case reconnect
    }

    public enum ParkReason: Hashable, Sendable {
        case died
        case reconnect
        case userDisconnected
    }

    public enum Verdict: Hashable, Sendable {
        case usable
        case restarting
        case dead
    }

    public enum Failure: Error, Hashable, Sendable {
        case hostDisconnected
        case reconnectSuperseded
        case replacementUnavailable
        case cancelled
        case timedOut
        case startFailed
    }

    public enum Outcome: Hashable, Sendable {
        case lease(PeerHostLeaseID)
        case failure(Failure)
    }

    public enum DisconnectKind: Hashable, Sendable {
        case plain
        case force
        case reconnect(Token)
    }

    public enum StartResult: Hashable, Sendable {
        case lease(PeerHostLeaseID)
        case failure
    }

    public struct Waiter: Hashable, Sendable {
        public let id: PeerHostWaiterID
        public let origin: Origin
    }

    public enum Phase: Hashable, Sendable {
        case idle
        case starting(PeerHostAttemptID, Spec, StartPurpose)
        case up(PeerHostLeaseID, Spec, refs: Int)
        case restarting(PeerHostLeaseID, Spec, PeerHostRestartID, refs: Int)
        case awaitingReconnect(Token)
    }

    public struct State: Hashable, Sendable {
        public fileprivate(set) var generation: UInt64 = 0
        public fileprivate(set) var phase: Phase = .idle
        public fileprivate(set) var waiters: [Waiter] = []
        public fileprivate(set) var park: ParkReason?
        public fileprivate(set) var reconnectToken: Token?
        fileprivate var nextSerial: UInt64 = 0

        public init() {}

        public var pooledLease: PeerHostLeaseID? {
            switch phase {
            case let .up(lease, _, _), let .restarting(lease, _, _, _):
                return lease
            case .idle, .starting, .awaitingReconnect:
                return nil
            }
        }
    }

    /// What a caller asked for. `generation` and `token` are stamped when the
    /// caller raises the request; the verdict is sampled later, at dequeue.
    public struct AcquireRequest: Hashable, Sendable {
        public let waiter: PeerHostWaiterID
        public let origin: Origin
        public let generation: UInt64
        public let spec: Spec?
        public let token: Token?

        public init(waiter: PeerHostWaiterID, origin: Origin, generation: UInt64, spec: Spec?, token: Token?) {
            self.waiter = waiter
            self.origin = origin
            self.generation = generation
            self.spec = spec
            self.token = token
        }
    }

    public enum Event: Hashable, Sendable {
        case acquire(AcquireRequest, Verdict)
        case retain(PeerHostLeaseID)
        case release(PeerHostLeaseID)
        case startFinished(PeerHostAttemptID, StartResult)
        case restartFinished(PeerHostLeaseID, PeerHostRestartID, cameBack: Bool)
        case disconnect(DisconnectKind)
        case reconnectAbandoned(Token, moved: Bool)
        case cancel(PeerHostWaiterID)
        case waiterDeadline(PeerHostWaiterID)
        case reconnectDeadline(Token)
        case unusedCheck(PeerHostLeaseID)
    }

    public enum Effect: Hashable, Sendable {
        case startTunnel(PeerHostAttemptID, Spec)
        case cancelStart(PeerHostAttemptID)
        case stopTunnel(PeerHostLeaseID)
        case resume(PeerHostWaiterID, Outcome)
        case fireWillRetire(PeerHostLeaseID)
        case fireDidReplace(PeerHostLeaseID)
        case fireAbandoned
        case armWaiterDeadline(PeerHostWaiterID)
        case armReconnectDeadline(Token)
        case waitRestart(PeerHostLeaseID, PeerHostRestartID)
        case queueUnusedCheck(PeerHostLeaseID)
    }

    public static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var transition = Transition(state: state)
        transition.apply(event)
        transition.enforceParkInvariant()
        return (transition.state, transition.effects)
    }
}

extension PeerHostMachine {
    fileprivate struct Transition {
        var state: State
        var effects: [Effect] = []

        mutating func apply(_ event: Event) {
            switch event {
            case let .acquire(request, verdict):
                acquire(request, verdict)
            case let .retain(lease):
                adjustReferences(on: lease, by: 1)
            case let .release(lease):
                adjustReferences(on: lease, by: -1)
            case let .startFinished(attempt, result):
                startFinished(attempt, result)
            case let .restartFinished(lease, restart, cameBack):
                restartFinished(lease, restart, cameBack: cameBack)
            case let .disconnect(kind):
                disconnect(kind)
            case let .reconnectAbandoned(token, moved):
                if case let .awaitingReconnect(current) = state.phase, current == token {
                    endReconnectWait(abandoningPark: moved)
                }
            case let .cancel(waiter):
                cancel(waiter)
            case let .waiterDeadline(waiter):
                if removeWaiter(waiter) {
                    resume(waiter, .failure(.timedOut))
                }
            case let .reconnectDeadline(token):
                if case let .awaitingReconnect(current) = state.phase, current == token {
                    endReconnectWait(abandoningPark: false)
                }
            case let .unusedCheck(lease):
                unusedCheck(lease)
            }
        }

        /// A `died` or `reconnect` debt that nothing outstanding could pay is
        /// abandoned here, so no transition can leave panes parked forever.
        mutating func enforceParkInvariant() {
            guard let park = state.park, park != .userDisconnected else { return }
            switch state.phase {
            case .starting, .awaitingReconnect:
                return
            case .idle, .up, .restarting:
                state.park = nil
                effects.append(.fireAbandoned)
            }
        }

        private mutating func acquire(_ request: AcquireRequest, _ verdict: Verdict) {
            let id = request.waiter
            // A waiter submitted again while it waits is the same acquire.
            // Checked first so the resubmission cannot resolve it a second time.
            guard !state.waiters.contains(where: { $0.id == id }) else { return }
            guard request.generation == state.generation else {
                return resume(id, .failure(.hostDisconnected))
            }
            if let token = request.token, token != state.reconnectToken {
                return resume(id, .failure(.reconnectSuperseded))
            }
            let waiter = Waiter(id: id, origin: request.origin)

            switch state.phase {
            case .idle:
                guard request.origin == .user, let spec = request.spec else {
                    return resume(id, .failure(.replacementUnavailable))
                }
                admit(waiter)
                start(spec, .fresh)
            case .starting(_, _, .reconnect) where request.origin != .user:
                resume(id, .failure(.replacementUnavailable))
            case .starting:
                admit(waiter)
            case let .up(lease, spec, refs):
                switch verdict {
                case .usable:
                    state.phase = .up(lease, spec, refs: refs + 1)
                    resume(id, .lease(lease))
                case .restarting:
                    let restart = PeerHostRestartID(mintSerial())
                    state.phase = .restarting(lease, spec, restart, refs: refs)
                    admit(waiter)
                    effects.append(.waitRestart(lease, restart))
                case .dead:
                    admit(waiter)
                    retirePooledLease()
                }
            case .restarting:
                admit(waiter)
                if verdict == .dead {
                    retirePooledLease()
                }
            case let .awaitingReconnect(token):
                guard request.origin == .user else {
                    return resume(id, .failure(.replacementUnavailable))
                }
                admit(waiter)
                if request.token == token, let spec = request.spec {
                    start(spec, .reconnect)
                }
            }
        }

        /// Reaching zero only queues a check. A retarget's `retain` can already
        /// be queued when this release is reduced, and stopping now would strand
        /// that pane on a stopped lease.
        private mutating func adjustReferences(on lease: PeerHostLeaseID, by delta: Int) {
            switch state.phase {
            case let .up(current, spec, refs) where current == lease:
                let remaining = refs + delta
                guard remaining >= 0 else { return }
                state.phase = .up(lease, spec, refs: remaining)
                if remaining == 0 {
                    effects.append(.queueUnusedCheck(lease))
                }
            case let .restarting(current, spec, restart, refs) where current == lease:
                let remaining = refs + delta
                guard remaining >= 0 else { return }
                state.phase = .restarting(lease, spec, restart, refs: remaining)
                if remaining == 0 {
                    effects.append(.queueUnusedCheck(lease))
                }
            default:
                return
            }
        }

        private mutating func unusedCheck(_ lease: PeerHostLeaseID) {
            switch state.phase {
            case .up(lease, _, 0), .restarting(lease, _, _, 0):
                if state.waiters.isEmpty {
                    state.phase = .idle
                    effects.append(.stopTunnel(lease))
                } else {
                    retirePooledLease()
                }
            default:
                return
            }
        }

        private mutating func startFinished(_ attempt: PeerHostAttemptID, _ result: StartResult) {
            guard case let .starting(current, spec, purpose) = state.phase, current == attempt else {
                if case let .lease(lease) = result {
                    effects.append(.stopTunnel(lease))
                }
                return
            }
            if purpose == .reconnect {
                state.reconnectToken = nil
            }
            switch result {
            case let .lease(lease):
                let waiters = state.waiters
                state.waiters = []
                state.phase = .up(lease, spec, refs: waiters.count)
                for waiter in waiters {
                    resume(waiter.id, .lease(lease))
                }
                if state.park != nil {
                    state.park = nil
                    effects.append(.fireDidReplace(lease))
                }
                effects.append(.queueUnusedCheck(lease))
            case .failure:
                state.phase = .idle
                resolveAllWaiters(.startFailed)
            }
        }

        private mutating func restartFinished(_ lease: PeerHostLeaseID, _ restart: PeerHostRestartID, cameBack: Bool) {
            guard case let .restarting(current, spec, currentRestart, refs) = state.phase,
                  current == lease, currentRestart == restart else { return }
            guard cameBack else {
                return retirePooledLease()
            }
            let waiters = state.waiters
            state.waiters = []
            state.phase = .up(lease, spec, refs: refs + waiters.count)
            for waiter in waiters {
                resume(waiter.id, .lease(lease))
            }
        }

        private mutating func disconnect(_ kind: DisconnectKind) {
            if case let .starting(attempt, _, _) = state.phase {
                effects.append(.cancelStart(attempt))
            }
            var pooledReferences = 0
            switch state.phase {
            case let .up(lease, _, refs), let .restarting(lease, _, _, refs):
                pooledReferences = refs
                effects.append(.stopTunnel(lease))
            case .idle, .starting, .awaitingReconnect:
                break
            }
            let leavesDebt = pooledReferences > 0 || state.park != nil

            switch kind {
            case .plain, .force:
                state.generation += 1
                state.phase = .idle
                state.reconnectToken = nil
                resolveAllWaiters(.hostDisconnected)
                if leavesDebt {
                    state.park = .userDisconnected
                }
                if kind == .force, state.park != nil {
                    state.park = nil
                    effects.append(.fireAbandoned)
                }
            case let .reconnect(token):
                state.phase = .awaitingReconnect(token)
                state.reconnectToken = token
                let dropped = state.waiters.filter { $0.origin != .user }
                state.waiters.removeAll { $0.origin != .user }
                for waiter in dropped {
                    resume(waiter.id, .failure(.replacementUnavailable))
                }
                effects.append(.armReconnectDeadline(token))
                if leavesDebt {
                    raisePark(to: .reconnect)
                }
            }
        }

        private mutating func endReconnectWait(abandoningPark: Bool) {
            state.phase = .idle
            state.reconnectToken = nil
            resolveAllWaiters(.replacementUnavailable)
            if abandoningPark, state.park != nil {
                state.park = nil
                effects.append(.fireAbandoned)
            }
        }

        private mutating func cancel(_ id: PeerHostWaiterID) {
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return }
            if case let .starting(attempt, _, purpose) = state.phase,
               purpose != .replacement, state.waiters.count == 1 {
                state.waiters = []
                state.phase = .idle
                if purpose == .reconnect {
                    state.reconnectToken = nil
                }
                effects.append(.cancelStart(attempt))
            } else {
                state.waiters.remove(at: index)
            }
            resume(id, .failure(.cancelled))
        }

        /// `references` is captured from the phase before it is replaced. In a
        /// post-wake retire those references are the only dependents: the
        /// panes about to park, which need the replacement.
        private mutating func retirePooledLease() {
            let lease: PeerHostLeaseID
            let spec: Spec
            let references: Int
            switch state.phase {
            case let .up(current, currentSpec, refs), let .restarting(current, currentSpec, _, refs):
                (lease, spec, references) = (current, currentSpec, refs)
            case .idle, .starting, .awaitingReconnect:
                return
            }
            let dependents = references > 0 || !state.waiters.isEmpty
            effects.append(.fireWillRetire(lease))
            effects.append(.stopTunnel(lease))
            if references > 0 {
                raisePark(to: .died)
            }
            if dependents {
                start(spec, .replacement)
            } else {
                state.phase = .idle
            }
        }

        private mutating func raisePark(to reason: ParkReason) {
            if state.park != .userDisconnected {
                state.park = reason
            }
        }

        private mutating func admit(_ waiter: Waiter) {
            state.waiters.append(waiter)
            effects.append(.armWaiterDeadline(waiter.id))
        }

        private mutating func start(_ spec: Spec, _ purpose: StartPurpose) {
            let attempt = PeerHostAttemptID(mintSerial())
            state.phase = .starting(attempt, spec, purpose)
            effects.append(.startTunnel(attempt, spec))
        }

        private mutating func removeWaiter(_ id: PeerHostWaiterID) -> Bool {
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return false }
            state.waiters.remove(at: index)
            return true
        }

        private mutating func resolveAllWaiters(_ failure: Failure) {
            let waiters = state.waiters
            state.waiters = []
            for waiter in waiters {
                resume(waiter.id, .failure(failure))
            }
        }

        private mutating func resume(_ id: PeerHostWaiterID, _ outcome: Outcome) {
            effects.append(.resume(id, outcome))
        }

        private mutating func mintSerial() -> UInt64 {
            state.nextSerial += 1
            return state.nextSerial
        }
    }
}
