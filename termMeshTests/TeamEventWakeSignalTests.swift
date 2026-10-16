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
            XCTAssertEqual(request.timeoutMs, 600_000)
        } else {
            XCTFail("a large timeout is valid input")
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

    func testWaitersBeyondTheCapAnswerAtOnce() async {
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
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

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
    }
}
