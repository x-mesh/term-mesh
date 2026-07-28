import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class AutoPilotDispatchTests: XCTestCase {
    private func task(
        _ id: String,
        status: String = "pending",
        deps: [String] = [],
        title: String? = nil
    ) -> ReviewBoardTask {
        ReviewBoardTask(
            id: id, teamName: "ws", title: title ?? "Task \(id)", status: status,
            dependsOn: deps
        )
    }

    // MARK: - The gate itself

    func testATaskWithNoDependenciesIsReady() {
        let result = AutoPilotDispatch.evaluate([task("a")])
        XCTAssertEqual(result.ready, ["a"])
        XCTAssertTrue(result.waiting.isEmpty)
        XCTAssertTrue(result.needsAPerson.isEmpty)
    }

    func testAChainReleasesOneHopAtATime() {
        // c ← b ← a, with a done.
        var tasks = [
            task("a", status: "completed"),
            task("b", deps: ["a"]),
            task("c", deps: ["b"]),
        ]
        var result = AutoPilotDispatch.evaluate(tasks)
        XCTAssertEqual(result.ready, ["b"])
        XCTAssertEqual(result.waiting["c"], "Waiting on Task b.")

        // b lands; c is released on this very evaluation — which is what makes
        // the chain run without anyone poking it.
        tasks[1] = task("b", status: "merged", deps: ["a"])
        result = AutoPilotDispatch.evaluate(tasks)
        XCTAssertEqual(result.ready, ["c"])
    }

    /// The agent is finished but the code has not merged. A child branching off
    /// now gets a tree without the code it depends on.
    func testAReviewReadyDependencyIsNotYetSatisfied() {
        let result = AutoPilotDispatch.evaluate([
            task("a", status: "review_ready"),
            task("b", deps: ["a"]),
        ])
        XCTAssertTrue(result.ready.isEmpty)
        XCTAssertEqual(result.waiting["b"], "Waiting on Task a.")
    }

    func testMultipleUnfinishedDependenciesAreCounted() {
        let result = AutoPilotDispatch.evaluate([
            task("a", status: "in_progress"),
            task("b", status: "pending"),
            task("c", deps: ["a", "b"]),
        ])
        let reason = result.waiting["c"] ?? ""
        XCTAssertTrue(reason.hasPrefix("Waiting on 2 tasks:"), reason)
        XCTAssertTrue(reason.contains("Task a"), reason)
        XCTAssertTrue(reason.contains("Task b"), reason)
    }

    // MARK: - Dead ends go to a person, never to another agent

    func testAFailedDependencyIsEscalatedRatherThanReassigned() {
        for status in ["failed", "blocked", "cancelled", "rejected", "quarantined"] {
            let result = AutoPilotDispatch.evaluate([
                task("a", status: status, title: "Build the thing"),
                task("b", deps: ["a"]),
            ])
            XCTAssertTrue(result.ready.isEmpty, status)
            XCTAssertNil(result.waiting["b"], "a dead end is not a delay (\(status))")
            XCTAssertEqual(
                result.needsAPerson["b"],
                "Build the thing is \(status); auto pilot does not reassign it."
            )
        }
    }

    func testADependencyTheBoardCannotSeeIsEscalated() {
        let result = AutoPilotDispatch.evaluate([task("b", deps: ["ghost"])])
        XCTAssertEqual(
            result.needsAPerson["b"],
            "Depends on ghost, which is not on this board."
        )
    }

    /// Without this every task in the loop just says "waiting on", forever,
    /// and nothing on the board says why nothing is happening.
    func testACycleIsReportedRatherThanWaitedOn() {
        let result = AutoPilotDispatch.evaluate([
            task("a", deps: ["b"]),
            task("b", deps: ["a"]),
        ])
        XCTAssertTrue(result.ready.isEmpty)
        XCTAssertEqual(result.needsAPerson.count, 2)
        XCTAssertTrue(
            result.needsAPerson["a"]?.contains("loop back") == true,
            result.needsAPerson["a"] ?? ""
        )
    }

    func testALongerCycleIsAlsoCaught() {
        let result = AutoPilotDispatch.evaluate([
            task("a", deps: ["c"]),
            task("b", deps: ["a"]),
            task("c", deps: ["b"]),
        ])
        XCTAssertEqual(result.needsAPerson.count, 3)
        XCTAssertTrue(result.ready.isEmpty)
    }

    // MARK: - What is even a candidate

    /// Re-sending work already in flight is how an agent gets the same task
    /// twice.
    func testOnlyWaitingTasksAreCandidates() {
        let result = AutoPilotDispatch.evaluate([
            task("running", status: "in_progress"),
            task("done", status: "completed"),
            task("stopped", status: "failed"),
            task("placed", status: "placed"),
            task("waiting", status: "pending"),
        ])
        XCTAssertEqual(result.ready, ["waiting"])
        XCTAssertTrue(result.waiting.isEmpty)
        XCTAssertTrue(result.needsAPerson.isEmpty)
    }

    // MARK: - The dispatch-point gate agrees with the board

    func testBlockingReasonMatchesWhatTheBoardWouldShow() {
        let tasks = [
            task("a", status: "in_progress", title: "Phase 1"),
            task("gone", status: "failed", title: "Phase 0"),
        ]
        XCTAssertNil(AutoPilotDispatch.blockingReason(dependsOn: [], in: tasks))
        XCTAssertEqual(
            AutoPilotDispatch.blockingReason(dependsOn: ["a"], in: tasks),
            "waiting on Phase 1"
        )
        XCTAssertEqual(
            AutoPilotDispatch.blockingReason(dependsOn: ["gone"], in: tasks),
            "Phase 0 is failed"
        )
        XCTAssertEqual(
            AutoPilotDispatch.blockingReason(dependsOn: ["nobody"], in: tasks),
            "depends on nobody, which is not on this board"
        )
        XCTAssertNil(
            AutoPilotDispatch.blockingReason(
                dependsOn: ["done"],
                in: tasks + [task("done", status: "merged")]
            )
        )
    }

    /// An empty board must not hold work that has no dependencies — the gate
    /// exists to stop premature starts, not all starts.
    func testNoDependenciesIsNeverBlockedEvenWithNoBoardKnowledge() {
        XCTAssertNil(AutoPilotDispatch.blockingReason(dependsOn: [], in: []))
    }
}
