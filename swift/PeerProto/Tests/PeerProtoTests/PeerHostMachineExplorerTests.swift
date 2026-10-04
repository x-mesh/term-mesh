import XCTest
@testable import PeerProto

/// Exhaustive check of `PeerHostMachine` through `PeerHostShellCore`, as
/// specified in `docs/peer-host-registry-redesign.md` ("Exhaustive check").
///
/// Layer 1 drives the core with no re-entrant calls, so it explores the
/// reducer plus the queue order its own effects rely on. Layer 2 also injects
/// a call into the middle of an effect list. Both check every reached state,
/// and every quiescent state for liveness. A failure prints the shortest event
/// sequence that reaches it.
final class PeerHostMachineExplorerTests: XCTestCase {
    func test_layer1_everyStateWithinBoundsHoldsTheInvariants() {
        let report = Explorer(bounds: .layer1, reentrant: false).run()
        print(report.summary(title: "layer 1"))
        XCTAssertTrue(report.violations.isEmpty, report.failureText)
        XCTAssertEqual(report.uncovered(ExplorerCoverage.layer1), [], "rows the search never reached")
    }

    func test_layer2_reentrantCallsDuringEffectsHoldTheInvariants() {
        let report = Explorer(bounds: .layer2, reentrant: true).run()
        print(report.summary(title: "layer 2"))
        XCTAssertTrue(report.violations.isEmpty, report.failureText)
        XCTAssertEqual(report.uncovered(ExplorerCoverage.layer2), [], "rows the search never reached")
    }
}

// MARK: - Model

enum ExplorerSpec: Hashable, Sendable, CustomStringConvertible {
    case user
    case stale
    case probed(Int)

    var description: String {
        switch self {
        case .user: return "user"
        case .stale: return "stale"
        case let .probed(token): return "probed(t\(token))"
        }
    }
}

typealias XM = PeerHostMachine<ExplorerSpec, Int>
typealias XCore = PeerHostShellCore<ExplorerSpec, Int>

enum LeaseHealth: Hashable {
    case usable
    case restarting
    case dead
}

struct RestartKey: Hashable, Comparable, CustomStringConvertible {
    let lease: PeerHostLeaseID
    let restart: PeerHostRestartID

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.lease, lhs.restart) < (rhs.lease, rhs.restart)
    }

    var description: String { "\(lease)/\(restart)" }
}

enum TokenChoice: Hashable {
    case none
    case current
    case stale(Int)
}

enum DisconnectChoice: Hashable {
    case plain
    case force
    case reconnect
}

indirect enum ExplorerAction: Hashable, CustomStringConvertible {
    case acquire(XM.Origin, TokenChoice, raiseOnly: Bool)
    case deliverRaised
    case release
    case closeParked(PeerHostLeaseID)
    case health(LeaseHealth)
    case disconnect(DisconnectChoice)
    case reconnectAbandoned(Int, moved: Bool)
    case cancel(PeerHostWaiterID)
    case startFinished(PeerHostAttemptID, success: Bool)
    case restartFinished(RestartKey, cameBack: Bool)
    case waiterDeadline(PeerHostWaiterID)
    case reconnectDeadline(Int)
    case reentrant(ExplorerAction, atEffect: Int, inject: ExplorerAction)
    case sequence([ExplorerAction])

    var description: String {
        switch self {
        case let .acquire(origin, token, raiseOnly):
            let tokenText: String
            switch token {
            case .none: tokenText = ""
            case .current: tokenText = " token=current"
            case let .stale(value): tokenText = " token=t\(value)(stale)"
            }
            return "\(raiseOnly ? "raise" : "acquire")(\(origin)\(tokenText))"
        case .deliverRaised: return "deliver raised acquire"
        case .release: return "a pane releases the pooled lease"
        case let .closeParked(lease): return "a parked pane on \(lease) closes"
        case let .health(health): return "pooled lease becomes \(health)"
        case let .disconnect(kind): return "disconnect(.\(kind))"
        case let .reconnectAbandoned(token, moved): return "reconnectAbandoned(t\(token), moved: \(moved))"
        case let .cancel(waiter): return "cancel(\(waiter))"
        case let .startFinished(attempt, success): return "startFinished(\(attempt), \(success ? "lease" : "failure"))"
        case let .restartFinished(key, cameBack): return "restartFinished(\(key), cameBack: \(cameBack))"
        case let .waiterDeadline(waiter): return "deadline(\(waiter))"
        case let .reconnectDeadline(token): return "deadline(t\(token))"
        case let .reentrant(base, index, inject): return "\(base), and during its effect #\(index): \(inject)"
        case let .sequence(actions): return actions.map(\.description).joined(separator: " then ")
        }
    }
}

struct ExplorerWorld: Hashable {
    var machine = XM.State()
    var pendingStarts: Set<PeerHostAttemptID> = []
    var pendingRestarts: Set<RestartKey> = []
    var armedWaiters: Set<PeerHostWaiterID> = []
    var armedTokens: Set<Int> = []
    var inFlight: [XM.AcquireRequest] = []
    /// Waiters asked and not yet resolved, with the generation they were raised under.
    var outstanding: [PeerHostWaiterID: UInt64] = [:]
    /// Panes holding a lease they use; for the pooled lease this must equal the machine's refs.
    var holders: [PeerHostLeaseID: Int] = [:]
    /// Panes holding a stopped lease while they wait to be reattached.
    var parked: [PeerHostLeaseID: Int] = [:]
    var health: [PeerHostLeaseID: LeaseHealth] = [:]
    var mintedWaiters = 0
    var mintedLeases = 0
    var tokens = 0
    var plainDisconnects = 0
    var forceDisconnects = 0

    var isQuiescent: Bool {
        pendingStarts.isEmpty && pendingRestarts.isEmpty && armedWaiters.isEmpty
            && armedTokens.isEmpty && inFlight.isEmpty
    }
}

struct ExplorerBounds {
    var waiters: Int
    var inFlight: Int
    var disconnectsPerKind: Int
    var depth: Int

    static let layer1 = ExplorerBounds(waiters: 3, inFlight: 1, disconnectsPerKind: 2, depth: depth("PEER_HOST_EXPLORER_L1_DEPTH", 1000))
    static let layer2 = ExplorerBounds(waiters: 2, inFlight: 1, disconnectsPerKind: 2, depth: depth("PEER_HOST_EXPLORER_L2_DEPTH", 1000))

    private static func depth(_ name: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? fallback
    }
}

struct ExplorerViolation: Hashable {
    let rule: String
    let detail: String
}

// MARK: - Harness

/// Applies one action to a world through a real `PeerHostShellCore`, keeping
/// the ghost ledger in step with every effect and recording violations.
final class ExplorerHarness {
    private(set) var world: ExplorerWorld
    private(set) var violations: [ExplorerViolation] = []
    private(set) var covered: Set<String> = []
    private(set) var performed = 0
    private var core: XCore!
    private var injection: (index: Int, action: ExplorerAction)?

    private let initialPark: XM.ParkReason?

    init(world: ExplorerWorld) {
        self.world = world
        initialPark = world.machine.park
        core = XCore(
            state: world.machine,
            sampleVerdict: { [unowned self] lease in self.verdict(for: lease) },
            perform: { [unowned self] effect, context in self.perform(effect, context) },
            shellOnlyReference: { [unowned self] lease, delta in self.shellOnly(lease, delta) }
        )
    }

    func finish() -> ExplorerWorld {
        world.machine = core.state
        if initialPark != world.machine.park {
            covered.insert("park \(describe(initialPark)) -> \(describe(world.machine.park))")
        }
        checkEveryState()
        if world.isQuiescent {
            checkQuiescent()
        }
        return world
    }

    func execute(_ action: ExplorerAction) {
        switch action {
        case let .acquire(origin, choice, raiseOnly):
            guard let request = makeRequest(origin, choice) else { return }
            if raiseOnly {
                world.inFlight.append(request)
            } else {
                submit(request)
            }
        case .deliverRaised:
            guard !world.inFlight.isEmpty else { return }
            submit(world.inFlight.removeFirst())
        case .release:
            guard let lease = core.state.pooledLease, (world.holders[lease] ?? 0) > 0 else { return }
            adjust(&world.holders, lease, by: -1)
            core.release(lease)
        case let .closeParked(lease):
            guard (world.parked[lease] ?? 0) > 0 else { return }
            adjust(&world.parked, lease, by: -1)
            let before = core.state
            core.release(lease)
            if core.state != before {
                record("rule 8", "a parked pane's release on \(lease) reached the machine")
            }
        case let .health(health):
            guard let lease = core.state.pooledLease else { return }
            world.health[lease] = health
        case let .disconnect(choice):
            switch choice {
            case .plain:
                world.plainDisconnects += 1
                core.deliver(.disconnect(.plain))
            case .force:
                world.forceDisconnects += 1
                core.deliver(.disconnect(.force))
            case .reconnect:
                world.tokens += 1
                core.deliver(.disconnect(.reconnect(world.tokens)))
            }
        case let .reconnectAbandoned(token, moved):
            core.deliver(.reconnectAbandoned(token, moved: moved))
        case let .cancel(waiter):
            core.deliver(.cancel(waiter))
        case let .startFinished(attempt, success):
            world.pendingStarts.remove(attempt)
            if success {
                world.mintedLeases += 1
                let lease = PeerHostLeaseID(UInt64(world.mintedLeases))
                world.health[lease] = .usable
                core.deliver(.startFinished(attempt, .lease(lease)))
            } else {
                core.deliver(.startFinished(attempt, .failure))
            }
        case let .restartFinished(key, cameBack):
            world.pendingRestarts.remove(key)
            if world.health[key.lease] != nil {
                world.health[key.lease] = cameBack ? .usable : .dead
            }
            core.deliver(.restartFinished(key.lease, key.restart, cameBack: cameBack))
        case let .waiterDeadline(waiter):
            world.armedWaiters.remove(waiter)
            core.deliver(.waiterDeadline(waiter))
        case let .reconnectDeadline(token):
            world.armedTokens.remove(token)
            core.deliver(.reconnectDeadline(token))
        case let .reentrant(base, index, inject):
            injection = (index, inject)
            execute(base)
            if injection == nil {
                covered.insert("reentrant \(inject.kind)")
            }
            injection = nil
        case let .sequence(actions):
            for step in actions {
                execute(step)
            }
        }
    }

    private func makeRequest(_ origin: XM.Origin, _ choice: TokenChoice) -> XM.AcquireRequest? {
        let spec: ExplorerSpec
        let token: Int?
        switch (origin, choice) {
        case (.user, .none):
            (spec, token) = (.user, nil)
        case (.user, .current):
            guard let current = core.state.reconnectToken else { return nil }
            (spec, token) = (.probed(current), current)
        case let (.user, .stale(value)):
            (spec, token) = (.probed(value), value)
        case (.sweep, _), (.waiter, _):
            (spec, token) = (.stale, nil)
        }
        world.mintedWaiters += 1
        return XM.AcquireRequest(
            waiter: PeerHostWaiterID(UInt64(world.mintedWaiters)),
            origin: origin,
            generation: core.state.generation,
            spec: spec,
            token: token
        )
    }

    private func submit(_ request: XM.AcquireRequest) {
        world.outstanding[request.waiter] = request.generation
        core.acquire(request)
    }

    private func verdict(for lease: PeerHostLeaseID) -> XM.Verdict {
        switch world.health[lease] ?? .usable {
        case .usable: return .usable
        case .restarting: return .restarting
        case .dead: return .dead
        }
    }

    /// A retarget `retain` can land after a disconnect raised earlier in the
    /// same drain stopped the lease. That pane is then parked under the new
    /// debt, which the every-state check verifies; it is not a defect here.
    private func shellOnly(_ lease: PeerHostLeaseID, _ delta: Int) {
        covered.insert(delta > 0 ? "shell-only retain" : "shell-only release")
    }

    private func perform(_ effect: XM.Effect, _ context: XCore.EffectContext) {
        performed += 1
        defer {
            if let pending = injection, pending.index == performed {
                injection = nil
                execute(pending.action)
            }
        }
        switch effect {
        case let .startTunnel(attempt, spec):
            if case let .starting(_, _, purpose) = core.state.phase {
                covered.insert("start \(purpose)")
            }
            checkStartSpec(spec, context)
            world.pendingStarts.insert(attempt)
        case .cancelStart:
            covered.insert("cancelStart on \(context.cause.kind)")
            switch context.cause {
            case .cancel, .disconnect:
                break
            default:
                record("rule 7", "a start was cancelled by \(context.cause), not by a Cancel or a disconnect")
            }
        case let .stopTunnel(lease):
            covered.insert("stopTunnel on \(context.cause.kind)")
            if core.state.pooledLease == lease {
                record("rule 2", "stopTunnel reached \(lease) while it is still pooled")
            }
            if let panes = world.holders.removeValue(forKey: lease) {
                world.parked[lease, default: 0] += panes
            }
            world.health.removeValue(forKey: lease)
        case let .resume(waiter, outcome):
            resume(waiter, outcome, context)
        case .fireWillRetire:
            covered.insert("retire on \(context.cause.kind)")
        case let .fireDidReplace(lease):
            covered.insert(world.parked.isEmpty ? "fireDidReplace, no panes left" : "fireDidReplace, panes retargeted")
            if context.before.park == nil {
                record("I7", "fireDidReplace(\(lease)) with no debt to pay")
            }
            let parked = world.parked
            world.parked = [:]
            for (old, panes) in parked.sorted(by: { $0.key < $1.key }) {
                for _ in 0..<panes {
                    world.holders[lease, default: 0] += 1
                    core.retain(lease)
                    core.release(old)
                }
            }
        case .fireAbandoned:
            covered.insert("abandon on \(context.cause.kind)")
            switch context.cause {
            case .startFinished(_, .failure), .cancel, .reconnectAbandoned, .reconnectDeadline, .disconnect(.force):
                break
            default:
                record("rule 6", "parked panes abandoned on \(context.cause), where no replacement had failed")
            }
            let parked = world.parked
            world.parked = [:]
            for (old, panes) in parked.sorted(by: { $0.key < $1.key }) {
                for _ in 0..<panes {
                    core.release(old)
                }
            }
        case let .armWaiterDeadline(waiter):
            world.armedWaiters.insert(waiter)
        case let .armReconnectDeadline(token):
            world.armedTokens.insert(token)
        case let .waitRestart(lease, restart):
            covered.insert("waitRestart")
            world.pendingRestarts.insert(RestartKey(lease: lease, restart: restart))
        case .queueUnusedCheck:
            record("rule 2", "the core passed queueUnusedCheck to the shell instead of queueing it")
        }
    }

    private func resume(_ waiter: PeerHostWaiterID, _ outcome: XM.Outcome, _ context: XCore.EffectContext) {
        guard let generation = world.outstanding.removeValue(forKey: waiter) else {
            return record("rule 4", "\(waiter) was resolved twice, or was never asked")
        }
        world.armedWaiters.remove(waiter)
        guard case let .lease(lease) = outcome else {
            if case let .failure(failure) = outcome {
                covered.insert("resume \(failure) on \(context.cause.kind)")
            }
            return
        }
        covered.insert("resume lease on \(context.cause.kind)")
        if core.state.pooledLease != lease {
            record("I1", "\(waiter) received \(lease), which is not pooled")
        }
        if generation != core.state.generation {
            record("I3", "\(waiter), raised before a disconnect, received \(lease)")
        }
        if case let .acquire(request, _) = context.cause, request.waiter == waiter, world.health[lease] == .dead {
            record("rule 3", "\(waiter) received \(lease), which was already dead when its acquire was dequeued")
        }
        world.holders[lease, default: 0] += 1
    }

    private func checkStartSpec(_ spec: ExplorerSpec, _ context: XCore.EffectContext) {
        if spec == .stale {
            return record("rule 5", "a waiter's spec started a tunnel on \(context.cause)")
        }
        let before = context.before
        var pooledSpec: ExplorerSpec?
        switch before.phase {
        case let .up(_, current, _), let .restarting(_, current, _, _):
            pooledSpec = current
        case .idle, .starting, .awaitingReconnect:
            pooledSpec = nil
        }
        let allowed: Bool
        switch context.cause {
        case let .acquire(request, _):
            switch before.phase {
            case .idle:
                allowed = request.origin == .user && request.spec == spec
                    && (request.token == nil || request.token == before.reconnectToken)
            case let .awaitingReconnect(token):
                allowed = request.token == token && request.spec == spec
            case .up, .restarting:
                allowed = spec == pooledSpec
            case .starting:
                allowed = false
            }
        case .restartFinished, .unusedCheck:
            allowed = spec == pooledSpec
        default:
            allowed = false
        }
        if !allowed {
            record("rule 5", "startTunnel(\(spec)) on \(context.cause) from \(before.phase)")
        }
    }

    private func checkEveryState() {
        let machine = world.machine
        let pooled = machine.pooledLease
        if case let .up(lease, _, refs) = machine.phase, (world.holders[lease] ?? 0) != refs {
            record("rule 8", "\(lease) has refs \(refs) but \(world.holders[lease] ?? 0) panes hold it")
        }
        if case let .restarting(lease, _, _, refs) = machine.phase, (world.holders[lease] ?? 0) != refs {
            record("rule 8", "\(lease) has refs \(refs) but \(world.holders[lease] ?? 0) panes hold it")
        }
        for (lease, panes) in world.holders where lease != pooled {
            record("I1", "\(panes) panes use \(lease), which is neither pooled nor parked")
        }
        if world.parked.values.reduce(0, +) > 0, machine.park == nil {
            record("parked forever", "panes are parked on \(world.parked.keys.sorted()) with no debt to reattach them")
        }
        switch machine.park {
        case .died?, .reconnect?:
            switch machine.phase {
            case .starting:
                break
            case let .awaitingReconnect(token) where world.armedTokens.contains(token):
                break
            default:
                record("parked forever", "a \(machine.park!) debt in \(machine.phase) that nothing outstanding can pay")
            }
        case .userDisconnected?, nil:
            break
        }
        let waiting = Set(machine.waiters.map(\.id))
        if waiting != Set(world.outstanding.keys) {
            record("rule 4", "waiting \(waiting.sorted()) but asked and unresolved \(world.outstanding.keys.sorted())")
        }
        for waiter in machine.waiters {
            if !world.armedWaiters.contains(waiter.id) {
                record("rule 7", "\(waiter.id) waits with no deadline")
            }
            if let generation = world.outstanding[waiter.id], generation != machine.generation {
                record("I3", "\(waiter.id), raised before a disconnect, still waits")
            }
        }
        switch machine.phase {
        case let .starting(attempt, _, _) where !world.pendingStarts.contains(attempt):
            record("I6", "\(attempt) is current but no completion is pending")
        case let .restarting(lease, _, restart, _) where !world.pendingRestarts.contains(RestartKey(lease: lease, restart: restart)):
            record("I6", "restart \(restart) on \(lease) is current but no completion is pending")
        case let .awaitingReconnect(token) where !world.armedTokens.contains(token):
            record("I6", "awaiting t\(token) with no deadline armed")
        default:
            break
        }
    }

    private func checkQuiescent() {
        let machine = world.machine
        if !machine.waiters.isEmpty {
            record("I6", "quiescent with waiters \(machine.waiters.map(\.id))")
        }
        if case let .up(lease, _, 0) = machine.phase {
            record("I1", "quiescent with \(lease) pooled and no references: an orphan tunnel")
        }
        if case let .restarting(lease, _, _, 0) = machine.phase {
            record("I1", "quiescent with \(lease) restarting and no references: an orphan tunnel")
        }
    }

    private func describe(_ park: XM.ParkReason?) -> String {
        park.map { "\($0)" } ?? "nil"
    }

    private func record(_ rule: String, _ detail: String) {
        violations.append(ExplorerViolation(rule: rule, detail: detail))
    }

    private func adjust(_ counts: inout [PeerHostLeaseID: Int], _ lease: PeerHostLeaseID, by delta: Int) {
        let value = (counts[lease] ?? 0) + delta
        counts[lease] = value == 0 ? nil : value
    }
}

// MARK: - Search

struct ExplorerReport {
    var states = 0
    var transitions = 0
    var maxDepthReached = 0
    var quiescentStates = 0
    var seconds = 0.0
    var violations: [String: (detail: String, path: [ExplorerAction])] = [:]
    var coverage: [String: Int] = [:]

    func uncovered(_ required: [String]) -> [String] {
        required.filter { coverage[$0] == nil }
    }

    func summary(title: String) -> String {
        let rules = violations.keys.sorted().joined(separator: ", ")
        return "[explorer] \(title): \(states) states, \(transitions) transitions, \(quiescentStates) quiescent, "
            + "depth \(maxDepthReached), \(String(format: "%.1f", seconds))s, "
            + "violations: \(violations.isEmpty ? "none" : rules)"
    }

    var failureText: String {
        violations.keys.sorted().map { rule in
            let entry = violations[rule]!
            let steps = entry.path.enumerated().map { "    \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            return "[\(rule)] \(entry.detail)\n\(steps)"
        }.joined(separator: "\n\n")
    }
}

struct Explorer {
    let bounds: ExplorerBounds
    let reentrant: Bool

    func run() -> ExplorerReport {
        let started = Date()
        var report = ExplorerReport()
        var worlds: [ExplorerWorld] = []
        var parents: [Int] = []
        var via: [ExplorerAction?] = []
        var depths: [Int] = []
        var index: [ExplorerWorld: Int] = [:]

        func path(to node: Int, then action: ExplorerAction) -> [ExplorerAction] {
            var steps = [action]
            var cursor = node
            while let step = via[cursor] {
                steps.append(step)
                cursor = parents[cursor]
            }
            return steps.reversed()
        }

        let root = ExplorerHarness(world: ExplorerWorld()).finish()
        worlds.append(root)
        parents.append(-1)
        via.append(nil)
        depths.append(0)
        index[root] = 0

        var cursor = 0
        while cursor < worlds.count {
            let node = cursor
            cursor += 1
            let world = worlds[node]
            if world.isQuiescent {
                report.quiescentStates += 1
            }
            report.maxDepthReached = max(report.maxDepthReached, depths[node])
            guard depths[node] < bounds.depth else { continue }

            for action in actions(from: world) {
                report.transitions += 1
                let harness = ExplorerHarness(world: world)
                harness.execute(action)
                let next = harness.finish()
                for row in harness.covered {
                    report.coverage[row, default: 0] += 1
                }
                if !harness.violations.isEmpty {
                    for violation in harness.violations where report.violations[violation.rule] == nil {
                        report.violations[violation.rule] = (violation.detail, path(to: node, then: action))
                    }
                    continue
                }
                guard index[next] == nil else { continue }
                index[next] = worlds.count
                worlds.append(next)
                parents.append(node)
                via.append(action)
                depths.append(depths[node] + 1)
            }
        }
        report.states = worlds.count
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    private func actions(from world: ExplorerWorld) -> [ExplorerAction] {
        let base = baseActions(from: world)
        guard reentrant else { return base }
        var out = base
        let injections = injectable(from: world)
        for action in base {
            let probe = ExplorerHarness(world: world)
            probe.execute(action)
            guard probe.performed > 0 else { continue }
            for effectIndex in 1...probe.performed {
                for inject in injections {
                    out.append(.reentrant(action, atEffect: effectIndex, inject: inject))
                }
            }
        }
        return out
    }

    private func baseActions(from world: ExplorerWorld) -> [ExplorerAction] {
        var out: [ExplorerAction] = []
        let machine = world.machine
        for attempt in world.pendingStarts.sorted() {
            out.append(.startFinished(attempt, success: true))
            out.append(.startFinished(attempt, success: false))
        }
        for key in world.pendingRestarts.sorted() {
            if world.health[key.lease] != .dead {
                out.append(.restartFinished(key, cameBack: true))
            }
            out.append(.restartFinished(key, cameBack: false))
        }
        for waiter in world.armedWaiters.sorted() {
            out.append(.waiterDeadline(waiter))
        }
        for token in world.armedTokens.sorted() {
            out.append(.reconnectDeadline(token))
        }
        if world.mintedWaiters < bounds.waiters {
            let canRaise = world.inFlight.count < bounds.inFlight
            for origin in [XM.Origin.user, .sweep, .waiter] {
                out.append(.acquire(origin, .none, raiseOnly: false))
                if canRaise {
                    out.append(.acquire(origin, .none, raiseOnly: true))
                }
            }
            if machine.reconnectToken != nil {
                out.append(.acquire(.user, .current, raiseOnly: false))
                if canRaise {
                    out.append(.acquire(.user, .current, raiseOnly: true))
                }
            }
            if world.tokens > 0 {
                for token in 1...world.tokens where token != machine.reconnectToken {
                    out.append(.acquire(.user, .stale(token), raiseOnly: false))
                }
            }
        }
        if !world.inFlight.isEmpty {
            out.append(.deliverRaised)
        }
        if let lease = machine.pooledLease {
            if (world.holders[lease] ?? 0) > 0 {
                out.append(.release)
            }
            switch world.health[lease] ?? .usable {
            case .usable:
                out.append(.health(.restarting))
                out.append(.health(.dead))
            case .restarting:
                out.append(.health(.dead))
            case .dead:
                break
            }
        }
        for lease in world.parked.keys.sorted() {
            out.append(.closeParked(lease))
        }
        if world.plainDisconnects < bounds.disconnectsPerKind {
            out.append(.disconnect(.plain))
        }
        if world.forceDisconnects < bounds.disconnectsPerKind {
            out.append(.disconnect(.force))
        }
        if world.tokens < bounds.disconnectsPerKind {
            out.append(.disconnect(.reconnect))
        }
        if world.tokens > 0 {
            for token in 1...world.tokens {
                out.append(.reconnectAbandoned(token, moved: false))
                out.append(.reconnectAbandoned(token, moved: true))
            }
        }
        for waiter in machine.waiters {
            out.append(.cancel(waiter.id))
        }
        return out
    }

    private func injectable(from world: ExplorerWorld) -> [ExplorerAction] {
        var out: [ExplorerAction] = [.health(.dead), .release]
        if world.mintedWaiters < bounds.waiters {
            out.append(.acquire(.user, .none, raiseOnly: false))
            out.append(.acquire(.sweep, .none, raiseOnly: false))
            out.append(.sequence([.acquire(.sweep, .none, raiseOnly: false), .health(.dead)]))
        }
        if world.plainDisconnects < bounds.disconnectsPerKind {
            out.append(.disconnect(.plain))
        }
        if world.tokens < bounds.disconnectsPerKind {
            out.append(.disconnect(.reconnect))
        }
        return out
    }
}

// MARK: - Coverage

extension XM.Event {
    var kind: String {
        switch self {
        case .acquire: return "acquire"
        case .retain: return "retain"
        case .release: return "release"
        case .startFinished(_, .failure): return "startFinished(failure)"
        case .startFinished: return "startFinished(lease)"
        case .restartFinished(_, _, true): return "restartFinished(back)"
        case .restartFinished: return "restartFinished(gone)"
        case .disconnect(.plain): return "disconnect(plain)"
        case .disconnect(.force): return "disconnect(force)"
        case .disconnect(.reconnect): return "disconnect(reconnect)"
        case .reconnectAbandoned(_, true): return "reconnectAbandoned(moved)"
        case .reconnectAbandoned: return "reconnectAbandoned"
        case .cancel: return "cancel"
        case .waiterDeadline: return "waiterDeadline"
        case .reconnectDeadline: return "reconnectDeadline"
        case .unusedCheck: return "unusedCheck"
        }
    }
}

extension ExplorerAction {
    var kind: String {
        switch self {
        case .acquire: return "acquire"
        case .release: return "release"
        case .health: return "health"
        case .disconnect(.plain): return "disconnect(plain)"
        case .disconnect(.reconnect): return "disconnect(reconnect)"
        case .sequence: return "acquire, then the lease dies"
        default: return "\(self)"
        }
    }
}

/// Rows each layer must reach. A bound that stops reaching one fails the test
/// instead of passing on a smaller search.
enum ExplorerCoverage {
    static let layer1 = [
        "start fresh", "start replacement", "start reconnect",
        "resume lease on acquire", "resume lease on startFinished(lease)", "resume lease on restartFinished(back)",
        "resume hostDisconnected on acquire", "resume hostDisconnected on disconnect(plain)",
        "resume hostDisconnected on disconnect(force)",
        "resume reconnectSuperseded on acquire",
        "resume replacementUnavailable on acquire", "resume replacementUnavailable on disconnect(reconnect)",
        "resume replacementUnavailable on reconnectAbandoned", "resume replacementUnavailable on reconnectDeadline",
        "resume cancelled on cancel", "resume timedOut on waiterDeadline", "resume startFailed on startFinished(failure)",
        "retire on acquire", "retire on restartFinished(gone)", "retire on unusedCheck",
        "waitRestart",
        "stopTunnel on startFinished(lease)", "stopTunnel on unusedCheck",
        "stopTunnel on disconnect(plain)", "stopTunnel on disconnect(reconnect)",
        "cancelStart on cancel", "cancelStart on disconnect(plain)", "cancelStart on disconnect(reconnect)",
        "fireDidReplace, panes retargeted", "fireDidReplace, no panes left",
        "abandon on startFinished(failure)", "abandon on cancel", "abandon on reconnectAbandoned",
        "abandon on reconnectAbandoned(moved)", "abandon on reconnectDeadline", "abandon on disconnect(force)",
        "park nil -> died", "park nil -> reconnect", "park nil -> userDisconnected",
        "park died -> userDisconnected", "park died -> reconnect", "park reconnect -> userDisconnected",
        "park died -> nil", "park reconnect -> nil", "park userDisconnected -> nil",
    ]

    static let layer2 = [
        "reentrant health", "reentrant release", "reentrant acquire",
        "reentrant disconnect(plain)", "reentrant disconnect(reconnect)", "reentrant acquire, then the lease dies",
        "fireDidReplace, panes retargeted", "shell-only retain",
    ]
}
