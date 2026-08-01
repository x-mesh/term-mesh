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

    /// Runs whatever this test just scheduled on the main queue.
    private func settleMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    /// Waits out the debounce window inside `notifyChanged`, so an earlier
    /// notification cannot swallow the one a test is about to observe.
    private func settleStoreNotifications() {
        let settled = expectation(description: "store notifications settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }

    /// The mark has to leave this dictionary.
    ///
    /// What a replay reads after a restart is the board snapshot on disk, and
    /// `notifyChanged` is what schedules writing it; `noteTasksChanged`
    /// republishes it to the views. Marking without either kept the delivery
    /// only until the app quit, and the next retry then saw an undelivered
    /// task and pasted the same instruction a second time.
    func testDeliveryMarkPublishesTheBoardChange() throws {
        let team = registerTeam()
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "work", assignee: "executor"
        ))
        let previousHandler = store.onDataChanged
        defer { store.onDataChanged = previousHandler }
        settleStoreNotifications()

        let published = expectation(description: "board change published")
        published.assertForOverFulfill = false
        store.onDataChanged = { published.fulfill() }
        let revisionBefore = store.taskRevision

        XCTAssertTrue(store.markTextDelivered(teamName: team, taskId: task.id))

        wait(for: [published], timeout: 2)
        settleMainQueue()
        XCTAssertGreaterThan(
            store.taskRevision, revisionBefore,
            "the mark must republish the board to the views reading it"
        )
    }

    /// A mark that changed nothing must stay silent, or every retry of an
    /// already-delivered turn rewrites the board snapshot for no reason.
    ///
    /// Characterization, not a guard on the notify that was added: the second
    /// call returns at the `textDeliveredAt == nil` guard, before it could
    /// reach any notification, so this passes with or without that change. What
    /// it does pin is the ordering — move the notify above the guard and this
    /// starts failing.
    func testARepeatedDeliveryMarkPublishesNothing() throws {
        let team = registerTeam()
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "work", assignee: "executor"
        ))
        XCTAssertTrue(store.markTextDelivered(teamName: team, taskId: task.id))
        settleMainQueue()
        let revisionAfterFirst = store.taskRevision

        XCTAssertFalse(store.markTextDelivered(teamName: team, taskId: task.id))

        settleMainQueue()
        XCTAssertEqual(
            store.taskRevision, revisionAfterFirst,
            "a mark that changed nothing must not publish a change"
        )
    }

    /// The dedup branch hands back the task exactly as it was created — the
    /// assignee included, even when that instance is gone. Moving it is the
    /// caller's job, so this pins the half the store is responsible for and
    /// documents why `delegate` has to reassign at all.
    func testReplayDedupeReturnsTheTaskWithoutMovingItsAssignee() throws {
        let team = "delegate-replay-move-\(UUID().uuidString)"
        store.registerTeam(team, agents: [
            TeamDataStore.AgentRegistration(name: "executor", instanceId: "inst-gone"),
            TeamDataStore.AgentRegistration(name: "executor", instanceId: "inst-live"),
        ])
        teamNames.append(team)

        let created = try XCTUnwrap(store.createTaskWithDisposition(
            teamName: team, title: "work", assignee: "executor",
            assigneeInstanceId: "inst-gone", requestId: "request-move"
        ))
        XCTAssertTrue(created.created)

        let replay = try XCTUnwrap(store.createTaskWithDisposition(
            teamName: team, title: "work", assignee: "executor",
            assigneeInstanceId: "inst-live", requestId: "request-move"
        ))

        XCTAssertFalse(replay.created)
        XCTAssertEqual(replay.task.id, created.task.id)
        XCTAssertEqual(
            replay.task.assigneeInstanceId, "inst-gone",
            "dedupe returns the original owner — the caller is what moves it"
        )
    }

    /// The rule `delegate` applies before it pastes a replay.
    ///
    /// The store-level tests below prove the pieces; this is the decision
    /// itself, which used to live inline in `delegate` where — like the
    /// skip-paste rule before it — no test could reach it.
    func testOnlyAnUndeliveredReplayOnAnotherInstanceIsMoved() {
        // The case that motivated it: the task's instance is gone, the paste is
        // about to go somewhere else, so ownership has to follow the work.
        XCTAssertTrue(
            TeamOrchestrator.delegateMustReassignReplay(
                taskAlreadyExisted: true, maySkipPaste: false,
                taskInstanceId: "inst-gone", targetInstanceId: "inst-live"),
            "a replay pasted into a different instance must move its task"
        )
        XCTAssertFalse(
            TeamOrchestrator.delegateMustReassignReplay(
                taskAlreadyExisted: true, maySkipPaste: false,
                taskInstanceId: "inst-live", targetInstanceId: "inst-live"),
            "the same instance is not a move"
        )
        // Nothing is pasted, so nothing moves — the board would otherwise claim
        // a pane received an instruction it never saw.
        XCTAssertFalse(
            TeamOrchestrator.delegateMustReassignReplay(
                taskAlreadyExisted: true, maySkipPaste: true,
                taskInstanceId: "inst-gone", targetInstanceId: "inst-live"),
            "an already-delivered replay is acknowledged, not moved"
        )
        // A task this call just created is already assigned to the target.
        XCTAssertFalse(
            TeamOrchestrator.delegateMustReassignReplay(
                taskAlreadyExisted: false, maySkipPaste: false,
                taskInstanceId: nil, targetInstanceId: "inst-live"),
            "a newly created task is not a replay"
        )
    }

    /// `delegate` reassigns a replayed task to the live instance before it
    /// pastes. That must leave the delivery mark alone: the mark answers "has
    /// this instruction ever landed", and clearing it here would let the retry
    /// after this one paste the same turn a third time.
    func testReassignPreservesTheDeliveryMark() throws {
        let team = "delegate-reassign-mark-\(UUID().uuidString)"
        store.registerTeam(team, agents: [
            TeamDataStore.AgentRegistration(name: "executor", instanceId: "inst-gone"),
            TeamDataStore.AgentRegistration(name: "executor", instanceId: "inst-live"),
        ])
        teamNames.append(team)

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "work", assignee: "executor",
            assigneeInstanceId: "inst-gone"
        ))
        let landed = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.markTextDelivered(teamName: team, taskId: task.id, at: landed))

        let moved = try XCTUnwrap(store.reassignTask(
            teamName: team, taskId: task.id,
            assignee: "executor", assigneeInstanceId: "inst-live"
        ))

        XCTAssertEqual(moved.assigneeInstanceId, "inst-live")
        XCTAssertEqual(
            moved.textDeliveredAt, landed,
            "moving a task must not erase what already reached a pane"
        )
    }
}
