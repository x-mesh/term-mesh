import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class DelegateDedupP1Tests: XCTestCase {
    private let store = TeamDataStore.shared
    private var teamNames: [String] = []

    override func tearDown() {
        for teamName in teamNames {
            store.unregisterTeam(teamName)
        }
        teamNames.removeAll()
        super.tearDown()
    }

    private func registerTeam() -> String {
        let name = "delegate-dedup-\(UUID().uuidString)"
        store.registerTeam(name, agentNames: ["executor"])
        teamNames.append(name)
        return name
    }

    func testSameRequestIdCreatesExactlyOneTask() throws {
        let team = registerTeam()

        let first = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: "request-1"
        ))
        let retry = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work retry", assignee: "executor",
            requestId: "request-1"
        ))

        XCTAssertEqual(retry.id, first.id)
        XCTAssertEqual(store.listTasks(teamName: team).count, 1)
    }

    func testDispositionDistinguishesFirstDeliveryFromIdempotentReplay() throws {
        let team = registerTeam()

        let first = try XCTUnwrap(store.createTaskWithDisposition(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: "request-disposition"
        ))
        let retry = try XCTUnwrap(store.createTaskWithDisposition(
            teamName: team, title: "must not be delivered", assignee: "executor",
            requestId: "request-disposition"
        ))

        XCTAssertTrue(first.created)
        XCTAssertFalse(retry.created)
        XCTAssertEqual(retry.task.id, first.task.id)
        XCTAssertEqual(store.listTasks(teamName: team).count, 1)
    }

    func testNilRequestIdPreservesNonDeduplicatedCreation() throws {
        let team = registerTeam()

        let first = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: nil
        ))
        let second = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: nil
        ))

        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(store.listTasks(teamName: team).count, 2)
    }

    /// The replay must be resolvable *precisely while* the instance is
    /// blocked by the task it is replaying.
    ///
    /// `createTaskWithDisposition` dedupes on request_id, but `delegate`
    /// selected its target first and the pool gate rejects any instance
    /// holding a non-terminal task. So a retry sent while the first attempt
    /// was still running never reached the dedup branch — it was answered
    /// `.allInstancesBusy` naming the very task it was replaying, and the
    /// dedup only became reachable once that task had completed, which is the
    /// case where a second paste would have been least harmful. `delegate`
    /// now resolves the request id through `task(teamName:requestId:)` before
    /// target selection, so this asserts both halves at once: the lookup
    /// succeeds AND `hasActiveTask` is true for the same instance.
    func testRequestIdResolvesWhileItsOwnTaskStillBlocksTheInstance() throws {
        let team = "delegate-replay-\(UUID().uuidString)"
        store.registerTeam(team, agents: [
            TeamDataStore.AgentRegistration(name: "executor", instanceId: "inst-1"),
        ])
        teamNames.append(team)

        let created = try XCTUnwrap(store.createTaskWithDisposition(
            teamName: team, title: "long running work", assignee: "executor",
            assigneeInstanceId: "inst-1", requestId: "request-inflight"
        ))
        XCTAssertTrue(created.created)
        _ = store.updateTask(
            teamName: team, taskId: created.task.id, status: "in_progress"
        )

        XCTAssertTrue(
            store.hasActiveTask(teamName: team, agentInstanceId: "inst-1"),
            "precondition: the running task must be holding the instance"
        )
        let replayed = try XCTUnwrap(
            store.task(teamName: team, requestId: "request-inflight"),
            "a retry must resolve to the in-flight task, not be refused as busy"
        )
        XCTAssertEqual(replayed.id, created.task.id)
        XCTAssertEqual(replayed.status, "in_progress")
        XCTAssertEqual(store.listTasks(teamName: team).count, 1)
    }

    func testRequestIdLookupIsScopedAndBlankSafe() throws {
        let team = registerTeam()
        let other = registerTeam()

        let created = try XCTUnwrap(store.createTask(
            teamName: team, title: "work", assignee: "executor",
            requestId: "scoped-request"
        ))

        XCTAssertEqual(
            store.task(teamName: team, requestId: "scoped-request")?.id,
            created.id
        )
        XCTAssertNil(
            store.task(teamName: other, requestId: "scoped-request"),
            "request ids must not resolve across teams"
        )
        XCTAssertNil(store.task(teamName: team, requestId: "unknown-request"))
        // A blank id must never match a task that simply has none, which
        // would hand an unrelated caller someone else's task.
        XCTAssertNil(store.task(teamName: team, requestId: ""))
        XCTAssertNil(store.task(teamName: team, requestId: "   "))
    }

    func testSameRequestIdDoesNotDeduplicateAcrossTeams() throws {
        let firstTeam = registerTeam()
        let secondTeam = registerTeam()

        let first = try XCTUnwrap(store.createTask(
            teamName: firstTeam, title: "delegate work", assignee: "executor",
            requestId: "shared-request"
        ))
        let second = try XCTUnwrap(store.createTask(
            teamName: secondTeam, title: "delegate work", assignee: "executor",
            requestId: "shared-request"
        ))

        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(store.listTasks(teamName: firstTeam).count, 1)
        XCTAssertEqual(store.listTasks(teamName: secondTeam).count, 1)
    }
}
