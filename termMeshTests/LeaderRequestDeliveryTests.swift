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

    func testNextWakePicksOldestQueuedRequest() throws {
        let team = registerTeam()
        try enqueue(team, "first", at: 0)
        try enqueue(team, "second", at: 10)
        XCTAssertEqual(
            store.nextLeaderRequestForWake(teamName: team, now: t0.addingTimeInterval(20))?.id,
            "first"
        )
    }

    func testNextWakeSkipsWhileARequestIsClaimed() throws {
        let team = registerTeam()
        try enqueue(team, "first", at: 0)
        try enqueue(team, "second", at: 10)
        guard case .succeeded = store.takeLeaderRequest(teamName: team, requestId: "first") else {
            return XCTFail("first was not claimed")
        }
        XCTAssertNil(store.nextLeaderRequestForWake(teamName: team, now: t0.addingTimeInterval(20)))
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

    func testNextWakeSkipsExpiredRequestsForYoungerOnes() throws {
        let team = registerTeam()
        try enqueue(team, "old", at: 0)
        try enqueue(team, "fresh", at: TeamDataStore.leaderRequestAutoWakeMaxAge - 10)
        let later = t0.addingTimeInterval(TeamDataStore.leaderRequestAutoWakeMaxAge + 1)
        XCTAssertEqual(store.nextLeaderRequestForWake(teamName: team, now: later)?.id, "fresh")
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

    func testCompleteThenWakeSkipsRequestsAlreadyWokenAtEnqueue() throws {
        let team = registerTeam()
        try enqueue(team, "a", at: 0)
        try enqueue(team, "b", at: 5)
        try enqueue(team, "c", at: 6)
        guard case .succeeded = store.takeLeaderRequest(teamName: team, requestId: "a") else {
            return XCTFail("a was not claimed")
        }
        XCTAssertTrue(store.recordLeaderRequestWake(teamName: team, requestId: "b", now: t0.addingTimeInterval(7)))
        guard case .succeeded = store.completeLeaderRequest(teamName: team, requestId: "a") else {
            return XCTFail("a was not completed")
        }
        let next = t0.addingTimeInterval(10)
        XCTAssertEqual(
            store.nextLeaderRequestForWake(teamName: team, now: next)?.id, "c",
            "b already has a prompt waiting in the leader's input"
        )
        XCTAssertTrue(store.recordLeaderRequestWake(teamName: team, requestId: "c", now: next))
        let recorded = try XCTUnwrap(store.listLeaderRequests(teamName: team)?.first { $0.id == "c" })
        XCTAssertEqual(recorded.wakeAttempts, 1)
        XCTAssertEqual(recorded.lastWakeAt, next)
    }

    func testLeaderReadyWakeRewakesTheOldestRequestAfterARestart() throws {
        let team = registerTeam()
        try enqueue(team, "a", at: 0)
        try enqueue(team, "b", at: 5)
        XCTAssertTrue(store.recordLeaderRequestWake(teamName: team, requestId: "a", now: t0.addingTimeInterval(1)))
        let ready = t0.addingTimeInterval(10)
        XCTAssertEqual(
            store.nextLeaderRequestForWake(teamName: team, now: ready, neverWokenOnly: false)?.id, "a",
            "the restarted leader has an empty input, so the woken-but-unprocessed request is woken again"
        )
        XCTAssertEqual(
            store.nextLeaderRequestForWake(teamName: team, now: ready)?.id, "b",
            "the wake after a completion still leaves an already-woken request alone"
        )
    }

    func testLeaderReadyWakeStillSkipsExpiredAndClaimedRequests() throws {
        let team = registerTeam()
        try enqueue(team, "old", at: 0)
        let expired = t0.addingTimeInterval(TeamDataStore.leaderRequestAutoWakeMaxAge + 1)
        XCTAssertNil(store.nextLeaderRequestForWake(teamName: team, now: expired, neverWokenOnly: false))
        try enqueue(team, "fresh", at: TeamDataStore.leaderRequestAutoWakeMaxAge)
        XCTAssertEqual(
            store.nextLeaderRequestForWake(teamName: team, now: expired, neverWokenOnly: false)?.id, "fresh"
        )
        guard case .succeeded = store.takeLeaderRequest(teamName: team, requestId: "fresh") else {
            return XCTFail("fresh was not claimed")
        }
        XCTAssertNil(store.nextLeaderRequestForWake(teamName: team, now: expired, neverWokenOnly: false))
    }

    func testCompleteThenWakeFindsNothingWhenEveryQueuedRequestWasWoken() throws {
        let team = registerTeam()
        try enqueue(team, "a", at: 0)
        try enqueue(team, "b", at: 5)
        guard case .succeeded = store.takeLeaderRequest(teamName: team, requestId: "a") else {
            return XCTFail("a was not claimed")
        }
        XCTAssertTrue(store.recordLeaderRequestWake(teamName: team, requestId: "b", now: t0.addingTimeInterval(6)))
        guard case .succeeded = store.completeLeaderRequest(teamName: team, requestId: "a") else {
            return XCTFail("a was not completed")
        }
        XCTAssertNil(store.nextLeaderRequestForWake(teamName: team, now: t0.addingTimeInterval(10)))
    }
}
