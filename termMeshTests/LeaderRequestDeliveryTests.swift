import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class LeaderRequestDeliveryTests: XCTestCase {
    private let store = TeamDataStore.shared
    private var teamNames: [String] = []
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        for teamName in teamNames { store.unregisterTeam(teamName) }
        teamNames.removeAll()
        super.tearDown()
    }

    private func registerTeam() -> String {
        let name = "leader-delivery-\(UUID().uuidString)"
        store.registerTeam(name, agentNames: ["executor"])
        store.updateBoardUuids([name: UUID().uuidString])
        teamNames.append(name)
        return name
    }

    private func enqueue(_ team: String, _ id: String, at offset: TimeInterval, content: String = "work") throws {
        guard case .created = store.enqueueLeaderRequest(
            teamName: team, content: content, requestId: id, now: t0.addingTimeInterval(offset)
        ) else { return XCTFail("request \(id) was not created") }
    }

    func testSweepPicksOldestEligibleQueuedRequest() throws {
        let team = registerTeam()
        try enqueue(team, "first", at: 0)
        try enqueue(team, "second", at: 10)
        XCTAssertEqual(
            store.nextLeaderRequestForWake(teamName: team, now: t0.addingTimeInterval(20))?.id,
            "first"
        )
    }

    func testSweepSkipsWhileARequestIsClaimed() throws {
        let team = registerTeam()
        try enqueue(team, "first", at: 0)
        try enqueue(team, "second", at: 10)
        guard case .succeeded = store.takeLeaderRequest(teamName: team, requestId: "first") else {
            return XCTFail("first was not claimed")
        }
        XCTAssertNil(store.nextLeaderRequestForWake(teamName: team, now: t0.addingTimeInterval(20)))
    }

    func testSweepRespectsCooldownBetweenWakes() throws {
        let team = registerTeam()
        try enqueue(team, "only", at: 0)
        XCTAssertTrue(store.recordLeaderRequestWake(teamName: team, requestId: "only", now: t0.addingTimeInterval(20)))
        XCTAssertNil(store.nextLeaderRequestForWake(teamName: team, now: t0.addingTimeInterval(50)))
        XCTAssertEqual(
            store.nextLeaderRequestForWake(teamName: team, now: t0.addingTimeInterval(81))?.id,
            "only"
        )
    }

    func testSweepStopsAfterMaxAttemptsAndMovesToTheNextRequest() throws {
        let team = registerTeam()
        try enqueue(team, "stuck", at: 0)
        for attempt in 0..<TeamDataStore.leaderRequestMaxWakeAttempts {
            store.recordLeaderRequestWake(
                teamName: team, requestId: "stuck", now: t0.addingTimeInterval(Double(attempt) * 61)
            )
        }
        let later = t0.addingTimeInterval(400)
        XCTAssertNil(store.nextLeaderRequestForWake(teamName: team, now: later))
        try enqueue(team, "fresh", at: 300)
        XCTAssertEqual(store.nextLeaderRequestForWake(teamName: team, now: later)?.id, "fresh")
    }

    func testQueuedRequestExpiresAfterAutoWakeMaxAge() throws {
        let team = registerTeam()
        try enqueue(team, "old", at: 0)
        let limit = TeamDataStore.leaderRequestAutoWakeMaxAge
        let request = try XCTUnwrap(store.listLeaderRequests(teamName: team)?.first)
        XCTAssertEqual(request.effectiveStatus(now: t0.addingTimeInterval(limit)), "queued")
        XCTAssertEqual(request.effectiveStatus(now: t0.addingTimeInterval(limit + 1)), "expired")
        let expiredAt = t0.addingTimeInterval(limit + 1)
        XCTAssertNil(store.nextLeaderRequestForWake(teamName: team, now: expiredAt))
        XCTAssertEqual(
            store.leaderRequestDictionary(request, includeContent: false, now: expiredAt)["status"] as? String,
            "expired"
        )
        guard case .succeeded(let taken) = store.takeLeaderRequest(
            teamName: team, requestId: "old", now: expiredAt
        ) else { return XCTFail("an explicit take of an expired request must still work") }
        XCTAssertEqual(taken.status, "claimed")
    }

    func testRequestsWrittenBeforeWakeTrackingStillDecode() throws {
        let original = TeamDataStore.LeaderRequest(
            id: "legacy", content: "work", contentSHA256: "x", contentBytes: 4,
            status: "queued", createdAt: t0, claimedAt: nil, completedAt: nil
        )
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["wakeAttempts"])
        let decoded = try JSONDecoder().decode(TeamDataStore.LeaderRequest.self, from: data)
        XCTAssertNil(decoded.wakeAttempts)
        XCTAssertNil(decoded.lastWakeAt)

        var tracked = original
        tracked.wakeAttempts = 2
        tracked.lastWakeAt = t0
        let roundTrip = try JSONDecoder().decode(
            TeamDataStore.LeaderRequest.self, from: JSONEncoder().encode(tracked)
        )
        XCTAssertEqual(roundTrip, tracked)
    }

    func testListPayloadCarriesPreviewButNotContent() throws {
        let team = registerTeam()
        let long = String(repeating: "x", count: 200)
        try enqueue(team, "preview", at: 0, content: "line one\nline two\r\n" + long)
        let request = try XCTUnwrap(store.listLeaderRequests(teamName: team)?.first)
        let payload = store.leaderRequestDictionary(request, includeContent: false, now: t0)
        let preview = try XCTUnwrap(payload["preview"] as? String)
        XCTAssertEqual(preview.count, TeamDataStore.leaderRequestPreviewLength)
        XCTAssertTrue(preview.hasPrefix("line one line two "))
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertNil(payload["content"])
        XCTAssertEqual(payload["wake_attempts"] as? Int, 0)
    }

    func testCompletingARequestMakesTheNextQueuedOneEligible() throws {
        let team = registerTeam()
        try enqueue(team, "a", at: 0)
        try enqueue(team, "b", at: 5)
        guard case .succeeded = store.takeLeaderRequest(teamName: team, requestId: "a"),
              case .succeeded = store.completeLeaderRequest(teamName: team, requestId: "a")
        else { return XCTFail("a was not completed") }
        XCTAssertEqual(store.nextLeaderRequestForWake(teamName: team, now: t0.addingTimeInterval(10))?.id, "b")
    }

    // MARK: - Retry gate

    private func turn(
        inProgress: Bool = false, lastEnd: TimeInterval? = nil, telemetry: Bool = true
    ) -> TeamDataStore.LeaderTurnState {
        .init(hasTelemetry: telemetry, inProgress: inProgress, lastEndAt: lastEnd.map { t0.addingTimeInterval($0) })
    }

    func testNoRetryWhileALeaderTurnIsInProgress() {
        XCTAssertFalse(TeamDataStore.LeaderRequestWakeGate.mayWake(
            turn: turn(inProgress: true, lastEnd: 100), paneActive: false, lastWakeAt: t0
        ))
        XCTAssertFalse(TeamDataStore.LeaderRequestWakeGate.mayWake(
            turn: turn(inProgress: true), paneActive: false, lastWakeAt: nil
        ))
    }

    func testNoRetryUntilATurnEndedAfterTheLastWake() {
        let wake = t0.addingTimeInterval(50.4)
        XCTAssertFalse(TeamDataStore.LeaderRequestWakeGate.mayWake(
            turn: turn(lastEnd: 10), paneActive: false, lastWakeAt: wake
        ), "the only turn ended before the wake, so the wake was never taken up")
        XCTAssertFalse(TeamDataStore.LeaderRequestWakeGate.mayWake(
            turn: turn(), paneActive: false, lastWakeAt: wake
        ))
        XCTAssertTrue(TeamDataStore.LeaderRequestWakeGate.mayWake(
            turn: turn(lastEnd: 50), paneActive: false, lastWakeAt: wake
        ), "hook timestamps are whole seconds, so a turn ending in the wake's second counts")
        XCTAssertTrue(TeamDataStore.LeaderRequestWakeGate.mayWake(
            turn: turn(lastEnd: 120), paneActive: false, lastWakeAt: wake
        ))
    }

    func testFirstWakeOfAnIdleLeaderNeedsNoEarlierTurn() {
        XCTAssertTrue(TeamDataStore.LeaderRequestWakeGate.mayWake(
            turn: turn(), paneActive: false, lastWakeAt: nil
        ))
    }

    func testTerminalLeaderWithoutTelemetryFallsBackToPaneActivity() {
        let silent = turn(telemetry: false)
        XCTAssertFalse(TeamDataStore.LeaderRequestWakeGate.mayWake(turn: silent, paneActive: true, lastWakeAt: t0))
        XCTAssertTrue(TeamDataStore.LeaderRequestWakeGate.mayWake(turn: silent, paneActive: false, lastWakeAt: t0))
        XCTAssertFalse(TeamDataStore.LeaderRequestWakeGate.mayWake(
            turn: turn(lastEnd: 100), paneActive: true, lastWakeAt: t0
        ), "a printing pane is busy whatever the hooks say")
    }

    private func record(_ event: LeaderTurnLog.Event, at offset: TimeInterval) -> LeaderTurnLog.Record {
        let at = t0.addingTimeInterval(offset)
        return event == .turnStart
            ? .turnStart(team: "t", surfaceID: "s", prompt: "p", timestamp: at)
            : .turnEnd(team: "t", surfaceID: "s", prompt: "p", timestamp: at)
    }

    func testTurnStateFollowsStartAndEndRecords() {
        let now = t0.addingTimeInterval(1000)
        let running = TeamDataStore.LeaderTurnState(
            records: [record(.turnStart, at: 10), record(.turnEnd, at: 20), record(.turnStart, at: 30)], now: now
        )
        XCTAssertTrue(running.inProgress)
        XCTAssertEqual(running.lastEndAt, t0.addingTimeInterval(20))
        let idle = TeamDataStore.LeaderTurnState(
            records: [record(.turnStart, at: 10), record(.turnEnd, at: 20)], now: now
        )
        XCTAssertFalse(idle.inProgress)
        XCTAssertTrue(idle.hasTelemetry)
        XCTAssertFalse(TeamDataStore.LeaderTurnState(records: [], now: now).hasTelemetry)
    }

    func testAnUnfinishedTurnOlderThanTheStaleAgeIsNotATurn() {
        let now = t0.addingTimeInterval(TeamDataStore.LeaderTurnState.staleTurnAge + 100)
        let state = TeamDataStore.LeaderTurnState(records: [record(.turnStart, at: 0)], now: now)
        XCTAssertFalse(state.inProgress)
        XCTAssertFalse(state.hasTelemetry)
    }
}
