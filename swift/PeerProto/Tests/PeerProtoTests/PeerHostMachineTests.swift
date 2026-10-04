import XCTest
@testable import PeerProto

/// Readable scenarios for the behaviors the explorer protects. The explorer
/// covers every interleaving within its bounds; these name the ones PR B's
/// shell and the relay tests depend on.
final class PeerHostMachineTests: XCTestCase {
    private typealias M = PeerHostMachine<String, Int>

    private func request(_ id: UInt64, _ origin: M.Origin, generation: UInt64 = 0, spec: String? = nil, token: Int? = nil) -> M.AcquireRequest {
        M.AcquireRequest(waiter: PeerHostWaiterID(id), origin: origin, generation: generation, spec: spec, token: token)
    }

    private func run(_ state: M.State, _ events: [M.Event]) -> (M.State, [M.Effect]) {
        var current = state
        var all: [M.Effect] = []
        for event in events {
            let (next, effects) = M.reduce(current, event)
            current = next
            all += effects
        }
        return (current, all)
    }

    private func pooled(refs: Int) -> (M.State, PeerHostLeaseID) {
        let lease = PeerHostLeaseID(1)
        var events: [M.Event] = [.acquire(request(1, .user, spec: "host"), .usable)]
        events.append(.startFinished(PeerHostAttemptID(1), .lease(lease)))
        for index in 1..<max(refs, 1) {
            events.append(.acquire(request(UInt64(index + 1), .user, spec: "host"), .usable))
        }
        let (state, _) = run(M.State(), events)
        XCTAssertEqual(state.phase, .up(lease, "host", refs: refs))
        return (state, lease)
    }

    func test_postWakeSweepFindingTheLeaseDeadStartsAReplacementForItsPanes() {
        let (state, lease) = pooled(refs: 2)
        let (after, effects) = M.reduce(state, .acquire(request(9, .sweep, spec: "stale"), .dead))

        XCTAssertTrue(effects.contains(.armWaiterDeadline(PeerHostWaiterID(9))), "the sweep joins the replacement as a waiter")
        XCTAssertTrue(effects.contains(.fireWillRetire(lease)))
        XCTAssertTrue(effects.contains(.stopTunnel(lease)))
        guard case let .starting(attempt, spec, .replacement) = after.phase else {
            return XCTFail("expected a replacement start, got \(after.phase)")
        }
        XCTAssertEqual(spec, "host", "a replacement uses the retired lease's spec, never the sweep's")
        XCTAssertTrue(effects.contains(.startTunnel(attempt, "host")))
        XCTAssertEqual(after.park, .died)
    }

    func test_reconnectHostCarriesAPaneReconnectButResolvesBackgroundWaiters() {
        var (state, _) = pooled(refs: 1)
        (state, _) = M.reduce(state, .acquire(request(5, .user, spec: "host"), .restarting))
        (state, _) = M.reduce(state, .acquire(request(6, .sweep), .restarting))

        let (after, effects) = M.reduce(state, .disconnect(.reconnect(7)))

        XCTAssertEqual(after.phase, .awaitingReconnect(7))
        XCTAssertEqual(after.waiters.map(\.id), [PeerHostWaiterID(5)])
        XCTAssertTrue(effects.contains(.resume(PeerHostWaiterID(6), .failure(.replacementUnavailable))))
        XCTAssertEqual(after.park, .reconnect)
        XCTAssertEqual(after.generation, state.generation, "Reconnect gates on its token, not on the generation")
    }

    func test_anAcquireCarryingASupersededTokenIsResolvedAndStartsNothing() {
        var (state, _) = pooled(refs: 1)
        (state, _) = M.reduce(state, .disconnect(.reconnect(1)))
        (state, _) = M.reduce(state, .disconnect(.reconnect(2)))

        let (after, effects) = M.reduce(state, .acquire(request(8, .user, spec: "probed-1", token: 1), .usable))

        XCTAssertEqual(effects, [.resume(PeerHostWaiterID(8), .failure(.reconnectSuperseded))])
        XCTAssertEqual(after.phase, .awaitingReconnect(2))
    }

    func test_anAcquireRaisedBeforeADisconnectIsResolvedHostDisconnected() {
        var (state, _) = pooled(refs: 1)
        (state, _) = M.reduce(state, .disconnect(.plain))
        XCTAssertEqual(state.park, .userDisconnected)

        let (after, effects) = M.reduce(state, .acquire(request(4, .user, generation: 0, spec: "host"), .usable))

        XCTAssertEqual(effects, [.resume(PeerHostWaiterID(4), .failure(.hostDisconnected))])
        XCTAssertEqual(after.phase, .idle)
    }

    /// The layer 2 finding: a release raised while the new lease is handed
    /// out reached zero before the retargeted pane's retain was dequeued, and
    /// stopped the lease under that pane.
    func test_releasingTheLastReferenceWaitsForARetargetRetainAlreadyQueued() {
        var (state, _) = pooled(refs: 1)
        (state, _) = M.reduce(state, .disconnect(.plain))
        (state, _) = M.reduce(state, .acquire(request(2, .user, generation: 1, spec: "host"), .usable))
        guard case let .starting(attempt, _, .fresh) = state.phase else {
            return XCTFail("expected Connect to start, got \(state.phase)")
        }
        let replacement = PeerHostLeaseID(2)
        var stopped: [PeerHostLeaseID] = []
        var core: PeerHostShellCore<String, Int>!
        core = PeerHostShellCore(
            state: state,
            sampleVerdict: { _ in .usable },
            perform: { effect, _ in
                switch effect {
                case .resume(_, .lease(replacement)):
                    core.release(replacement)
                case .fireDidReplace(replacement):
                    core.retain(replacement)
                case let .stopTunnel(lease):
                    stopped.append(lease)
                default:
                    break
                }
            },
            shellOnlyReference: { lease, _ in XCTFail("\(lease) left the pool under a retargeted pane") }
        )

        core.deliver(.startFinished(attempt, .lease(replacement)))

        XCTAssertEqual(stopped, [])
        XCTAssertEqual(core.state.phase, .up(replacement, "host", refs: 1))
        XCTAssertNil(core.state.park)
    }

    func test_aDeadlineResolvesItsWaiterButNeverCancelsTheStart() {
        let (state, effects) = M.reduce(M.State(), .acquire(request(1, .user, spec: "host"), .usable))
        guard case let .starting(attempt, _, .fresh) = state.phase else {
            return XCTFail("expected a fresh start")
        }
        XCTAssertTrue(effects.contains(.armWaiterDeadline(PeerHostWaiterID(1))))

        let (after, deadlineEffects) = M.reduce(state, .waiterDeadline(PeerHostWaiterID(1)))

        XCTAssertEqual(deadlineEffects, [.resume(PeerHostWaiterID(1), .failure(.timedOut))])
        XCTAssertEqual(after.phase, .starting(attempt, "host", .fresh))

        let (landed, landedEffects) = M.reduce(after, .startFinished(attempt, .lease(PeerHostLeaseID(3))))
        XCTAssertEqual(landed.phase, .up(PeerHostLeaseID(3), "host", refs: 0))
        XCTAssertEqual(landedEffects, [.queueUnusedCheck(PeerHostLeaseID(3))])
        let (stoppedState, stopEffects) = M.reduce(landed, .unusedCheck(PeerHostLeaseID(3)))
        XCTAssertEqual(stoppedState.phase, .idle)
        XCTAssertEqual(stopEffects, [.stopTunnel(PeerHostLeaseID(3))])
    }
}
