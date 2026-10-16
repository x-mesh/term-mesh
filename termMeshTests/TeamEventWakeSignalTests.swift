import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class TeamEventWakeSignalTests: XCTestCase {
    private typealias Signal = TeamEventWakeSignal

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testFirstCallArmsWithoutWaiting() async {
        let signal = Signal(epoch: "e1")
        signal.bump(team: "alpha")
        let outcome = await signal.wait(team: "alpha", since: nil, timeoutMs: 7000)
        XCTAssertEqual(outcome, .init(cursor: .init(epoch: "e1", revision: 1), changed: false))
    }

    func testHigherRevisionAnswersImmediately() async {
        let signal = Signal(epoch: "e1")
        let armed = await signal.wait(team: "alpha", since: nil, timeoutMs: 7000)
        signal.bump(team: "alpha")
        let started = Date()
        let outcome = await signal.wait(team: "alpha", since: armed.cursor, timeoutMs: 7000)
        XCTAssertEqual(outcome, .init(cursor: .init(epoch: "e1", revision: 1), changed: true))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testEpochMismatchAnswersImmediately() async {
        let signal = Signal(epoch: "restarted")
        let started = Date()
        let outcome = await signal.wait(
            team: "alpha",
            since: .init(epoch: "before", revision: 0),
            timeoutMs: 7000
        )
        XCTAssertEqual(outcome, .init(cursor: .init(epoch: "restarted", revision: 0), changed: true))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testBumpWakesOnlyTheSameTeam() async {
        let signal = Signal(epoch: "e1")
        let cursor = Signal.Cursor(epoch: "e1", revision: 0)
        let alpha = Task { await signal.wait(team: "alpha", since: cursor, timeoutMs: 7000) }
        let beta = Task { await signal.wait(team: "beta", since: cursor, timeoutMs: 7000) }
        await waitUntil { signal.waiterCount == 2 }
        XCTAssertEqual(signal.waiterCount, 2)

        DispatchQueue.global().async { signal.bump(team: "alpha") }
        let woken = await alpha.value
        XCTAssertEqual(woken, .init(cursor: .init(epoch: "e1", revision: 1), changed: true))
        XCTAssertEqual(signal.waiterCount, 1, "beta must still be held")

        signal.interruptAll()
        let other = await beta.value
        XCTAssertEqual(other, .init(cursor: .init(epoch: "e1", revision: 0), changed: false))
    }

    func testTimeoutIsClampedToTheHopBudget() async {
        let signal = Signal(epoch: "e1")
        let cursor = Signal.Cursor(epoch: "e1", revision: 0)
        let started = Date()
        let short = await signal.wait(team: "alpha", since: cursor, timeoutMs: 0)
        XCTAssertFalse(short.changed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        if case .success(let request) = Signal.parse(["team_name": "alpha", "timeout_ms": 600_000]) {
            XCTAssertEqual(request.timeoutMs, 7000)
        } else {
            XCTFail("a large timeout is valid input")
        }
        if case .success(let request) = Signal.parse(["team_name": "alpha", "timeout_ms": 0]) {
            XCTAssertEqual(request.timeoutMs, 1)
        } else {
            XCTFail("a zero timeout is valid input")
        }
        XCTAssertEqual(Signal.timeoutRangeMs, 1...7000)

        let longStarted = Date()
        let held = Task { await signal.wait(team: "alpha", since: cursor, timeoutMs: 600_000) }
        let outcome = await held.value
        let elapsed = Date().timeIntervalSince(longStarted)
        XCTAssertFalse(outcome.changed)
        XCTAssertGreaterThanOrEqual(elapsed, 6.5)
        XCTAssertLessThan(elapsed, 8.5)
    }

    func testInterruptAllReleasesHeldWaits() async {
        let signal = Signal(epoch: "e1")
        let cursor = Signal.Cursor(epoch: "e1", revision: 0)
        let held = (0..<3).map { _ in
            Task { await signal.wait(team: "alpha", since: cursor, timeoutMs: 7000) }
        }
        await waitUntil { signal.waiterCount == 3 }
        XCTAssertEqual(signal.waiterCount, 3)
        let started = Date()
        signal.interruptAll()
        for task in held {
            let outcome = await task.value
            XCTAssertFalse(outcome.changed)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(signal.waiterCount, 0)
    }

    func testWaitersBeyondTheCapAnswerAtOnce() async throws {
        let signal = Signal(epoch: "e1")
        let cursor = Signal.Cursor(epoch: "e1", revision: 0)
        let held = (0..<Signal.maxWaiters).map { _ in
            Task { await signal.wait(team: "alpha", since: cursor, timeoutMs: 7000) }
        }
        await waitUntil { signal.waiterCount == Signal.maxWaiters }
        XCTAssertEqual(signal.waiterCount, Signal.maxWaiters)

        let started = Date()
        let overflow = await signal.wait(team: "alpha", since: cursor, timeoutMs: 7000)
        XCTAssertFalse(overflow.changed)
        XCTAssertTrue(overflow.busy)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(signal.waiterCount, Signal.maxWaiters)

        guard case .success(let json) = await signal.respond(params: [
            "team_name": "alpha",
            "since": ["epoch": "e1", "revision": 0],
        ]) else {
            return XCTFail("respond failed")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["busy"] as? Bool, true)
        XCTAssertEqual(object["retry_after_ms"] as? Int, Signal.busyRetryAfterMs)
        XCTAssertEqual(signal.waiterCount, Signal.maxWaiters)

        signal.interruptAll()
        for task in held { _ = await task.value }
    }

    func testCancellationReleasesTheWaiter() async {
        let signal = Signal(epoch: "e1")
        let held = Task {
            await signal.wait(team: "alpha", since: .init(epoch: "e1", revision: 0), timeoutMs: 7000)
        }
        await waitUntil { signal.waiterCount == 1 }
        held.cancel()
        let outcome = await held.value
        XCTAssertFalse(outcome.changed)
        XCTAssertEqual(signal.waiterCount, 0)
    }

    func testAHealWaitingOnACommandReleasesHeldWaits() async {
        let signal = Signal.shared
        let team = "heal-\(UUID().uuidString)"
        let armed = await signal.wait(team: team, since: nil, timeoutMs: 7000)
        let gate = RelayLeaderSessionGate()
        let acquired = await gate.acquireCommand()
        XCTAssertTrue(acquired)

        let held = Task { await signal.wait(team: team, since: armed.cursor, timeoutMs: 7000) }
        await waitUntil { signal.waiterCount >= 1 }
        let started = Date()
        let heal = Task {
            guard await gate.acquireHeal() else { return }
            await gate.releaseHeal()
        }
        let outcome = await held.value
        XCTAssertFalse(outcome.changed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        await gate.releaseCommand()
        await heal.value
    }

    func testParseRejectsMalformedParams() {
        let malformed: [[String: Any]] = [
            [:],
            ["team_name": "alpha", "since": "e1:3"],
            ["team_name": "alpha", "since": ["epoch": "e1"]],
            ["team_name": "alpha", "since": ["epoch": "e1", "revision": -1]],
            ["team_name": "alpha", "since": ["epoch": "e1", "revision": 1.5]],
            ["team_name": "alpha", "since": ["epoch": "e1", "revision": true]],
            ["team_name": "alpha", "timeout_ms": "7000"],
            ["team_name": "alpha", "timeout_ms": -5],
        ]
        for params in malformed {
            guard case .failure(let failure) = Signal.parse(params) else {
                XCTFail("accepted \(params)")
                continue
            }
            XCTAssertEqual(failure.code, "invalid_params")
        }

        let parsed = Signal.parse([
            "team_name": "alpha",
            "since": ["epoch": "e1", "revision": 3],
            "timeout_ms": 2500,
        ])
        XCTAssertEqual(parsed, .success(.init(
            team: "alpha",
            since: .init(epoch: "e1", revision: 3),
            timeoutMs: 2500
        )))
        XCTAssertEqual(
            Signal.parse(["team_name": "alpha", "since": NSNull()]),
            .success(.init(team: "alpha", since: nil, timeoutMs: 7000))
        )
    }

    private func revision(_ team: String) async -> UInt64 {
        await Signal.shared.wait(team: team, since: nil, timeoutMs: 1).cursor.revision
    }

    private func storeTeam(_ label: String) -> String {
        let team = "\(label)-\(UUID().uuidString)"
        TeamDataStore.shared.registerTeam(team, agents: [.init(name: "executor", instanceId: "i-1")])
        return team
    }

    func testCompletingATaskInTheStoreWakesOnlyItsTeam() async throws {
        let store = TeamDataStore.shared
        let signal = Signal.shared
        let team = storeTeam("wake-done")
        let other = storeTeam("wake-other")
        defer {
            store.unregisterTeam(team)
            store.unregisterTeam(other)
        }
        let task = try XCTUnwrap(store.createTask(teamName: team, title: "work", assignee: "executor"))
        let armed = await signal.wait(team: team, since: nil, timeoutMs: 1)
        let otherArmed = await signal.wait(team: other, since: nil, timeoutMs: 1)
        let held = Task { await signal.wait(team: team, since: armed.cursor, timeoutMs: 7000) }
        let otherHeld = Task { await signal.wait(team: other, since: otherArmed.cursor, timeoutMs: 7000) }
        await waitUntil { signal.waiterCount >= 2 }

        let started = Date()
        XCTAssertNotNil(store.updateTask(
            teamName: team, taskId: task.id, status: "completed", result: "done"
        ))
        let woken = await held.value
        XCTAssertEqual(woken, .init(
            cursor: .init(epoch: signal.epoch, revision: armed.cursor.revision + 1), changed: true
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        let otherRevision = await revision(other)
        XCTAssertEqual(otherRevision, otherArmed.cursor.revision)
        signal.interruptAll()
        let otherOutcome = await otherHeld.value
        XCTAssertFalse(otherOutcome.changed, "an unrelated team's waiter must not be woken")
    }

    func testEveryStoreStatusTransitionBumpsAndOtherWritesDoNot() async throws {
        let store = TeamDataStore.shared
        let team = storeTeam("wake-table")
        defer { store.unregisterTeam(team) }
        let base = await revision(team)
        var expected: UInt64 = 0

        let task = try XCTUnwrap(store.createTask(teamName: team, title: "work", assignee: "executor"))
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: task.id, progressNote: "still going"))
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: task.id, status: "in_progress"))
        expected += 1
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: task.id, status: "in_progress"))
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: task.id, status: "blocked"))
        expected += 1
        XCTAssertEqual(store.unblockTask(teamName: team, taskId: task.id)?.status, "in_progress")
        expected += 1
        XCTAssertEqual(store.reassignTask(teamName: team, taskId: task.id, assignee: "executor")?.status, "assigned")
        expected += 1
        XCTAssertEqual(store.convergeTimebox(teamName: team, taskIds: [task.id]).count, 1)
        expected += 1
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: task.id, status: "completed"))
        expected += 1

        let queued = try XCTUnwrap(store.createTask(teamName: team, title: "pool"))
        XCTAssertEqual(store.claimTask(teamName: team, agentName: "executor", agentInstanceId: "i-1")?.id, queued.id)
        expected += 1
        XCTAssertEqual(
            store.releaseClaim(teamName: team, taskId: queued.id, assigneeInstanceId: "i-1")?.status, "queued"
        )
        expected += 1

        let deadline = Date().addingTimeInterval(2)
        var observed = await revision(team)
        while observed < base + expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
            observed = await revision(team)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        observed = await revision(team)
        XCTAssertEqual(observed, base + expected)
    }

    func testRespondEncodesTheCursor() async throws {
        let signal = Signal(epoch: "e1")
        signal.bump(team: "alpha")
        guard case .success(let json) = await signal.respond(params: ["team_name": "alpha"]) else {
            return XCTFail("respond failed")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["epoch"] as? String, "e1")
        XCTAssertEqual((object["revision"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(object["changed"] as? Bool, false)
        XCTAssertNil(object["busy"])
        XCTAssertNil(object["retry_after_ms"])
    }
}
