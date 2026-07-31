import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// "Task creation failed" was almost always a lie.
///
/// `delegateToAgent` had two failure points — no such agent, and no instance
/// free — and returned `nil` for both, so the RPC layer reported the one thing
/// that had NOT happened: `TeamDataStore.createTask` only refuses an
/// unregistered team or an unresolvable assignee, and delegate has established
/// both before it calls. The real cause is almost always the pool gate, and the
/// commonest reason for that is a `review_ready` task: it is not terminal, so
/// the agent stays out of the pool until somebody closes it.
///
/// These pin the diagnosis, not the plumbing. The selection path needs a team,
/// a pane and a tab manager; the decision it makes is pure, and that is the
/// part that was wrong.
final class DelegateDiagnosisP1Tests: XCTestCase {

    private let store = TeamDataStore.shared
    private var teamNames: [String] = []

    override func tearDown() {
        for teamName in teamNames {
            store.unregisterTeam(teamName)
        }
        teamNames.removeAll()
        super.tearDown()
    }

    private func registerTeam(agents: [String] = ["executor"]) -> String {
        let name = "delegate-diagnosis-\(UUID().uuidString)"
        store.registerTeam(name, agentNames: agents)
        teamNames.append(name)
        return name
    }

    // MARK: - (1) A review_ready task is named, not hidden behind "creation failed"

    /// The reported symptom, end to end at the level that decides it: an agent
    /// whose only task is `review_ready` is out of the pool, and what comes
    /// back has to say which task and what state.
    func testAReviewReadyTaskIsReportedAsTheBlockerWithItsID() throws {
        let team = registerTeam()
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "earlier work", assignee: "executor"
        ))
        _ = store.updateTask(teamName: team, taskId: task.id, status: "review_ready")
        let instance = try XCTUnwrap(task.assigneeInstanceId)

        let blockers = TeamOrchestrator.delegateBlockers(
            in: store.listTasks(teamName: team, assignee: "executor"),
            agentInstanceIds: [instance]
        )

        XCTAssertEqual(
            blockers,
            [TeamOrchestrator.DelegateBlocker(taskID: task.id, status: "review_ready")],
            "review_ready is not terminal, so it holds the pool — and must be named"
        )

        let message = TerminalController.delegateBlockerSummary(blockers)
        XCTAssertTrue(
            message.contains(task.id),
            "the id is the actionable half; without it the leader has to go find it. got: \(message)"
        )
        XCTAssertTrue(message.contains("review_ready"), "got: \(message)")
        XCTAssertFalse(
            message.lowercased().contains("task creation failed"),
            "creation was never attempted; saying so sent the reader to the store"
        )
    }

    /// The gate this mirrors lives in `TeamDataStore.hasActiveTask`. If the two
    /// sets drift, the explanation names a task that is not the one blocking.
    func testTheTerminalSetMatchesTheGateAndExcludesReviewReady() {
        XCTAssertEqual(
            TeamOrchestrator.delegateTerminalStatuses,
            ["completed", "failed", "abandoned", "cancelled"],
            "must equal the set in TeamDataStore.hasActiveTask"
        )
        XCTAssertFalse(
            TeamOrchestrator.delegateTerminalStatuses.contains("review_ready"),
            "moving review_ready here would drop it out of taskNeedsAttention "
                + "and the review queue would empty silently"
        )
    }

    /// A finished task releases the agent. Otherwise the fix would trade one
    /// permanent block for another.
    func testACompletedTaskDoesNotBlockTheNextDelegate() throws {
        let team = registerTeam()
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "earlier work", assignee: "executor"
        ))
        _ = store.updateTask(teamName: team, taskId: task.id, status: "completed")
        let instance = try XCTUnwrap(task.assigneeInstanceId)

        XCTAssertTrue(
            TeamOrchestrator.delegateBlockers(
                in: store.listTasks(teamName: team, assignee: "executor"),
                agentInstanceIds: [instance]
            ).isEmpty
        )
    }

    /// Another instance's task is not this one's problem. Matching on name
    /// alone would report a sibling's work as the blocker.
    func testAnotherInstancesTaskIsNotReportedAsABlocker() throws {
        let team = registerTeam()
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "earlier work", assignee: "executor"
        ))
        _ = store.updateTask(teamName: team, taskId: task.id, status: "review_ready")

        XCTAssertTrue(
            TeamOrchestrator.delegateBlockers(
                in: store.listTasks(teamName: team, assignee: "executor"),
                agentInstanceIds: [UUID().uuidString]
            ).isEmpty
        )
    }

    /// Ineligible for a reason that is not a task — parked, migrating, no pane,
    /// still thinking. There is no id to name, so the message must not pretend
    /// there is one.
    func testAnEmptyBlockerListStillExplainsItselfAndOffersAWayOut() {
        let message = TerminalController.delegateBlockerSummary([])

        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(
            message.contains("--agent-instance-id"),
            "the exact-instance escape hatch is the way past a pool that will not open"
        )
    }

    // MARK: - (2) An unknown agent is not_found, not a creation failure

    func testAnUnknownAgentNameHasNoBlockersToReport() throws {
        let team = registerTeam(agents: ["executor"])

        XCTAssertTrue(
            TeamOrchestrator.delegateBlockers(
                in: store.listTasks(teamName: team, assignee: "reviewer"),
                agentInstanceIds: []
            ).isEmpty,
            "a name with no instances yields no blockers — the caller maps that to not_found"
        )
    }

    // MARK: - (3) The request id is actually read off the wire

    /// Defect A. The store has deduped on `request_id` since 5c95ab10 and the
    /// CLI has sent one since d168ad61; nothing in between read it, so a
    /// retried delegate still created a second task.
    func testTheDelegateRequestIDIsReadFromTheWireField() {
        XCTAssertEqual(
            TerminalController.delegateRequestID(from: ["request_id": "delegate-stable-1"]),
            "delegate-stable-1"
        )
        XCTAssertNil(TerminalController.delegateRequestID(from: [:]))
        XCTAssertNil(
            TerminalController.delegateRequestID(from: ["request_id": "   "]),
            "a blank id must not become a dedup key that matches every other blank"
        )
        XCTAssertNil(TerminalController.delegateRequestID(from: ["request_id": 42]))
    }

    /// And the id the handler now forwards is the one the store dedups on, so
    /// two delegates carrying it produce one task.
    func testTheSameWireRequestIDYieldsExactlyOneTask() throws {
        let team = registerTeam()
        let params: [String: Any] = ["request_id": "delegate-stable-1"]
        let requestID = TerminalController.delegateRequestID(from: params)

        let first = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: requestID
        ))
        let retry = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: requestID
        ))

        XCTAssertEqual(retry.id, first.id)
        XCTAssertEqual(store.listTasks(teamName: team).count, 1)
    }
}
