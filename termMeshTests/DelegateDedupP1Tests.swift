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

    /// A task is created before its paste is attempted, so existence alone
    /// says nothing about delivery.
    ///
    /// The replay path may skip pasting only when the instruction is known to
    /// have landed. A task whose paste failed looks identical to one whose
    /// reply was merely lost — both leave a non-terminal task on the instance
    /// — and answering the first as "already delivered" drops the turn in
    /// silence. `textDeliveredAt` is what separates them.
    func testDeliveryMarkSeparatesALostReplyFromAPasteThatNeverLanded() throws {
        let team = registerTeam()
        let created = try XCTUnwrap(store.createTask(
            teamName: team, title: "work", assignee: "executor",
            requestId: "request-undelivered"
        ))

        // As created: nothing has been pasted yet.
        XCTAssertNil(
            store.getTask(teamName: team, taskId: created.id)?.textDeliveredAt,
            "a freshly created task must not claim delivery"
        )

        XCTAssertTrue(store.markTextDelivered(teamName: team, taskId: created.id))
        let delivered = try XCTUnwrap(store.getTask(teamName: team, taskId: created.id))
        XCTAssertNotNil(delivered.textDeliveredAt)
    }

    /// First delivery wins. The mark answers "has this ever landed", not
    /// "when did it last land", so a re-paste after a failed one must not move
    /// it — otherwise the record of the original delivery is lost.
    func testDeliveryMarkIsNotMovedByALaterDelivery() throws {
        let team = registerTeam()
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "work", assignee: "executor"
        ))
        let first = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(store.markTextDelivered(teamName: team, taskId: task.id, at: first))
        XCTAssertFalse(
            store.markTextDelivered(
                teamName: team, taskId: task.id, at: first.addingTimeInterval(60)),
            "a second delivery must report that it changed nothing"
        )
        XCTAssertEqual(
            store.getTask(teamName: team, taskId: task.id)?.textDeliveredAt, first
        )
    }

    /// The rule both delegate decision points share.
    ///
    /// `delegate` needs a `TabManager` and live panes, so its wiring cannot be
    /// built in a unit test (#135). The decision it makes can be, and this is
    /// the one that matters: a retry may skip the paste only when the earlier
    /// one is known to have landed.
    func testOnlyAKnownDeliveryLetsARetrySkipThePaste() {
        let landed = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            TeamOrchestrator.delegateMaySkipPaste(
                taskAlreadyExisted: true, textDeliveredAt: landed),
            "a replay of a delivered instruction must not paste twice"
        )
        XCTAssertFalse(
            TeamOrchestrator.delegateMaySkipPaste(
                taskAlreadyExisted: true, textDeliveredAt: nil),
            "a task whose paste never landed must be pasted, not acknowledged"
        )
        XCTAssertFalse(
            TeamOrchestrator.delegateMaySkipPaste(
                taskAlreadyExisted: false, textDeliveredAt: nil),
            "a task created by this very call always pastes"
        )
        // Cannot occur through `delegate` — a task it just created has never
        // been pasted — but the rule must not depend on that being true.
        XCTAssertFalse(
            TeamOrchestrator.delegateMaySkipPaste(
                taskAlreadyExisted: false, textDeliveredAt: landed),
            "a newly created task must paste regardless of any stale mark"
        )
    }

    func testDeliveryMarkRejectsAnUnknownTask() throws {
        let team = registerTeam()
        XCTAssertFalse(store.markTextDelivered(teamName: team, taskId: "nope"))
    }

    /// Boards written before this field must decode with the safe reading:
    /// not known to have been delivered.
    func testABoardWithoutTheFieldDecodesAsUndelivered() throws {
        let json = Data("""
        {"id":"abcd1234","title":"legacy","acceptanceCriteria":[],"labels":[],
         "status":"assigned","priority":2,"dependsOn":[],"childTaskIds":[],
         "reassignmentCount":0,"createdBy":"leader",
         "createdAt":0,"updatedAt":0}
        """.utf8)
        let decoder = JSONDecoder()
        let task = try decoder.decode(TeamOrchestrator.TeamTask.self, from: json)

        XCTAssertNil(
            task.textDeliveredAt,
            "an old board must not be read as having delivered anything"
        )
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
