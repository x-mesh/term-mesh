import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class PeerAgentCorrelationCarryTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var timers: [(fireAt: Date, work: @MainActor () -> Void)] = []
    private var lost: [String] = []

    private let key = "team/instance-1"
    private let surface = Data([1, 2, 3])
    private let carry = AgentSession.CarriedTaskCorrelation(taskId: "a1b2c3d4", turnWasInFlight: true)

    private func makeStore() -> PeerAgentCorrelationCarryStore {
        PeerAgentCorrelationCarryStore(
            now: { [unowned self] in self.clock },
            schedule: { [unowned self] delay, work in
                self.timers.append((self.clock.addingTimeInterval(delay), work))
            }
        )
    }

    private func put(_ store: PeerAgentCorrelationCarryStore, cause: String = "stream rewound") {
        store.store(key: key, surfaceID: surface, boundarySeq: 4_096, carry: carry, cause: cause) {
            [unowned self] reason in self.lost.append(reason)
        }
    }

    private func advance(by interval: TimeInterval) {
        clock = clock.addingTimeInterval(interval)
        let due = timers.filter { $0.fireAt <= clock }
        timers.removeAll { $0.fireAt <= clock }
        due.forEach { $0.work() }
    }

    func testACarryIsClaimedOnce() {
        let store = makeStore()
        put(store)

        let claimed = store.claim(key: key, surfaceID: surface)
        XCTAssertEqual(claimed?.carry, carry)
        XCTAssertEqual(claimed?.boundarySeq, 4_096)
        XCTAssertNil(store.claim(key: key, surfaceID: surface))

        advance(by: PeerAgentCorrelationCarryStore.carryDeadline)
        XCTAssertTrue(lost.isEmpty, "a claimed carry belongs to the rebuilt session")
    }

    func testAnotherSurfaceCannotClaimTheCarry() {
        let store = makeStore()
        put(store)

        XCTAssertNil(store.claim(key: key, surfaceID: Data([9])))
        XCTAssertNil(store.claim(key: "team/instance-2", surfaceID: surface))
        XCTAssertNotNil(store.claim(key: key, surfaceID: surface))
    }

    func testAnUnclaimedCarryBlocksOnceAtTheDeadline() {
        let store = makeStore()
        put(store)

        advance(by: PeerAgentCorrelationCarryStore.carryDeadline - 1)
        XCTAssertTrue(lost.isEmpty)
        advance(by: 1)
        advance(by: PeerAgentCorrelationCarryStore.carryDeadline)

        XCTAssertEqual(lost, [AgentSession.paneRebuildLossReason(cause: "stream rewound")])
        XCTAssertNil(store.claim(key: key, surfaceID: surface))
    }

    func testAnAuthoritativelyMissingSurfaceBlocksOnce() {
        let store = makeStore()
        put(store, cause: "disconnected")

        store.fail(key: key, surfaceID: surface)
        store.fail(key: key, surfaceID: surface)
        advance(by: PeerAgentCorrelationCarryStore.carryDeadline)

        XCTAssertEqual(lost, [AgentSession.paneRebuildLossReason(cause: "disconnected")])
    }

    func testARestoredCarryKeepsItsOriginalDeadline() throws {
        let store = makeStore()
        put(store)
        advance(by: 100)

        store.restore(try XCTUnwrap(store.claim(key: key, surfaceID: surface)))
        advance(by: 20)

        XCTAssertEqual(lost.count, 1)
    }

    /// The rebuilt pane is dropped again after its carry was claimed: the
    /// re-taken correlation is stored afresh, and the first deadline no longer
    /// applies to it.
    func testARedropStoresTheCarryAgainUnderItsOwnDeadline() throws {
        let store = makeStore()
        put(store)
        _ = try XCTUnwrap(store.claim(key: key, surfaceID: surface))
        advance(by: 100)

        put(store, cause: "disconnected")
        advance(by: 20)
        XCTAssertTrue(lost.isEmpty, "the first drop's deadline must not fire on the re-drop")
        XCTAssertNotNil(store.claim(key: key, surfaceID: surface))
        advance(by: PeerAgentCorrelationCarryStore.carryDeadline)
        XCTAssertTrue(lost.isEmpty)
    }

    func testReplacingAnUnclaimedCarryBlocksTheOneItReplaces() {
        let store = makeStore()
        put(store, cause: "stream rewound")
        put(store, cause: "disconnected")

        XCTAssertEqual(lost, [AgentSession.paneRebuildLossReason(cause: "stream rewound")])
        advance(by: PeerAgentCorrelationCarryStore.carryDeadline)
        XCTAssertEqual(lost.count, 2)
    }
}
