import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ReviewBoardViewModelTests: XCTestCase {
    @MainActor
    func testStatusBadgesCoverRequiredReviewStates() {
        let task = ReviewBoardTask(
            id: "1234567890abcdef",
            teamName: "ws",
            title: "Merge failed on fenced host",
            status: "failed",
            labels: ["fenced-zombie", "merge-failed"],
            isStale: true
        )
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [task],
            panelRuns: [],
            coordinatorOnline: false,
            memMeshAvailable: false,
            suspectHost: true,
            fencedZombie: true
        ))

        XCTAssertEqual(
            model.statusBadges(for: task),
            [.coordinatorOffline, .memMeshUnavailable, .suspectHost, .fencedZombie, .mergeFailed]
        )
    }

    /// A real queue entry replaces the guessing. The task below carries none
    /// of the hints the old path relied on — its status is not `failed` and
    /// it has no `merge-failed` label — so the badge can only come from the
    /// coordinator's own record.
    @MainActor
    func testMergeFailedBadgeComesFromTheQueueEntryNotTaskProse() throws {
        let task = ReviewBoardTask(
            id: "tsk_8d144b235ec342019a6d2bf39ef65296",
            teamName: "prj_819413b3",
            title: "Wire the merge queue",
            status: "queued_for_merge"
        )
        let entry = try XCTUnwrap(ReviewBoardMergeQueueItem(dictionary: [
            "queue_id": "mrq_2f1c4d5e6a7b8c9d0e1f2a3b4c5d6e7f",
            "task_id": "tsk_8d144b235ec342019a6d2bf39ef65296",
            "attempt_id": "att_9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d",
            "status": "failed",
            "approved_by": "reviewer",
            "approved_at_ms": 1_784_882_974_390,
            "last_error": "rebase conflict",
        ]))
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [task],
            panelRuns: [],
            mergeQueue: [entry],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertEqual(model.statusBadges(for: task), [.mergeFailed])
        XCTAssertEqual(model.pendingMergeQueue.map(\.id), [entry.id])
        XCTAssertEqual(model.taskTitle(forMergeQueueItem: entry), "Wire the merge queue")

        // The Merge Queue fact is the record, not a panel run or a keyword.
        let digest = model.digest(for: task)
        let mergeQueue = try XCTUnwrap(digest.mergeQueue)
        XCTAssertTrue(mergeQueue.contains("failed"), mergeQueue)
        XCTAssertTrue(mergeQueue.contains("reviewer"), mergeQueue)
        XCTAssertTrue(mergeQueue.contains("rebase conflict"), mergeQueue)

        // And it is the only thing known, so it is the only row drawn. Facts
        // with nothing to report used to render as "not reported" — eight of
        // them, burying the one line that had something to say.
        XCTAssertEqual(digest.presentFacts.map(\.title), ["Merge Queue"])
    }

    /// A task nobody has reported on yet draws no fact rows at all.
    @MainActor
    func testATaskWithNothingReportedHasNoFacts() {
        let task = ReviewBoardTask(
            id: "tsk_quiet",
            teamName: "x-backup",
            title: "이 저장소를 요약",
            status: "assigned"
        )
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [task],
            panelRuns: [],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertTrue(model.digest(for: task).presentFacts.isEmpty)
    }

    /// Merged and cancelled entries are history; the panel lists what still
    /// needs a person. Failures stay, because they need one most.
    @MainActor
    func testPendingMergeQueueDropsSettledEntriesButKeepsFailures() {
        func entry(_ queueID: String, _ status: String) -> ReviewBoardMergeQueueItem {
            ReviewBoardMergeQueueItem(dictionary: [
                "queue_id": queueID,
                "task_id": "tsk_\(queueID)",
                "status": status,
                "approved_by": "reviewer",
            ])!
        }
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [],
            panelRuns: [],
            mergeQueue: [
                entry("queued01", "queued"),
                entry("running1", "running"),
                entry("merged01", "merged"),
                entry("failed01", "failed"),
                entry("cancel01", "cancelled"),
            ],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertEqual(
            Set(model.pendingMergeQueue.map(\.taskRawID)),
            ["tsk_queued01", "tsk_running1", "tsk_failed01"]
        )
    }

    /// Without a queue entry the board still has to say something, and the
    /// old text-scanning path is what a locally-backed board falls back to.
    @MainActor
    func testWithoutAQueueEntryTheOldTaskProsePathStillApplies() {
        let task = ReviewBoardTask(
            id: "task-123",
            teamName: "ws",
            title: "Merge failed on host",
            status: "failed",
            labels: ["merge-failed"]
        )
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [task],
            panelRuns: [],
            mergeQueue: [],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertEqual(model.statusBadges(for: task), [.mergeFailed])
        // No entry and no panel run means nothing to say about the queue, and
        // nothing to say is now said by drawing no row rather than by a row
        // that says nothing.
        XCTAssertNil(model.digest(for: task).mergeQueue)
    }

    @MainActor
    func testReviewReadyAndBlockedTaskStates() {
        let blocked = ReviewBoardTask(id: "blocked", teamName: "ws", title: "Blocked", status: "blocked")
        let reviewReady = ReviewBoardTask(id: "ready", teamName: "ws", title: "Ready", status: "review_ready")
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [blocked, reviewReady],
            panelRuns: [],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertEqual(model.statusBadges(for: blocked), [.blocked])
        XCTAssertEqual(model.statusBadges(for: reviewReady), [.reviewReady])
    }

    @MainActor
    func testSnapshotRefreshPreservesValidSelectionAndDropsInvalidSelection() {
        let first = ReviewBoardTask(id: "first", teamName: "ws", title: "First", status: "queued")
        let second = ReviewBoardTask(id: "second", teamName: "ws", title: "Second", status: "review_ready")
        var snapshot = ReviewBoardSnapshot(
            tasks: [first, second],
            panelRuns: [],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        )
        let model = ReviewBoardViewModel(initialSnapshot: snapshot, selectedTaskID: "first") {
            snapshot
        }

        model.refresh()
        XCTAssertEqual(model.selectedTask?.id, "first")

        snapshot.tasks = [second]
        model.refresh()
        XCTAssertEqual(model.selectedTask?.id, "second")
    }

    func testTextRedactionHidesRawPathsAndTokens() {
        let text = ReviewBoardText.safeBody(
            "Report at /Users/jinwoo/work/project/term-mesh/Sources/App.swift token abcdefabcdefabcdefabcdefabcdefabcdef uuid 01234567-89ab-cdef-0123-456789abcdef"
        )

        XCTAssertFalse(text.contains("/Users/jinwoo"))
        XCTAssertFalse(text.contains("abcdefabcdefabcdefabcdefabcdefabcdef"))
        XCTAssertFalse(text.contains("01234567-89ab-cdef-0123-456789abcdef"))
        XCTAssertTrue(text.contains("…/App.swift"))
        XCTAssertTrue(text.contains("<token>"))
        XCTAssertTrue(text.contains("<uuid>"))
    }

    func testWidthPersistenceClampsBounds() {
        let defaults = UserDefaults(suiteName: "ReviewBoardViewModelTests.\(UUID().uuidString)")!
        ReviewBoardSettings.saveWidth(100, defaults: defaults)
        XCTAssertEqual(ReviewBoardSettings.loadWidth(defaults: defaults), ReviewBoardSettings.minimumWidth)

        ReviewBoardSettings.saveWidth(1_000, defaults: defaults)
        XCTAssertEqual(ReviewBoardSettings.loadWidth(defaults: defaults), ReviewBoardSettings.maximumWidth)
    }

    // MARK: - Approving from the board

    private func review(
        taskID: String = "tsk_1",
        approvable: Bool = true,
        blocker: String? = nil
    ) -> ReviewBoardReview {
        ReviewBoardReview(
            taskID: taskID,
            detail: ReviewBoardReviewDetail(
                status: approvable ? "review_ready" : "assigned",
                attemptID: approvable ? "att_1" : nil,
                fencingToken: approvable ? "fen_1" : nil,
                worktreePath: "/tmp/wt", hostID: nil, snapshot: nil,
                queueID: nil, queueStatus: nil, queueLastError: nil
            ),
            patch: ReviewBoardEvidence.Patch(
                baseSHA: "aaa", headSHA: "bbb", digest: "sha256:cafe",
                text: "diff", isTruncated: false,
                files: [.init(path: "a.swift", kind: "modified", add: 1, del: 0)]
            ),
            blocker: blocker
        )
    }

    private func task(_ id: String = "tsk_1", status: String = "review_ready") -> ReviewBoardTask {
        ReviewBoardTask(id: id, teamName: "ws", title: "Fix it", status: status)
    }

    /// The write path is injected the way the read path is, so a decision can
    /// be exercised without a coordinator socket.
    @MainActor
    func test_approving_calls_through_and_clears_what_was_read() async {
        var approved: [String] = []
        let model = ReviewBoardViewModel(
            initialSnapshot: ReviewBoardSnapshot(
                tasks: [task()], panelRuns: [], coordinatorOnline: true,
                memMeshAvailable: true, suspectHost: false, fencedZombie: false
            ),
            selectedTaskID: nil,
            snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in self.review() },
            approve: { approved.append($0.taskID) },
            reject: { _, _ in XCTFail("not this one") }
        ))

        await model.loadReview(for: task())
        XCTAssertEqual(model.review?.taskID, "tsk_1")
        XCTAssertTrue(model.review?.canAct == true)

        let landed = await model.approve()
        XCTAssertTrue(landed)
        XCTAssertEqual(approved, ["tsk_1"])
        // The task has moved on, so what was read no longer describes it —
        // leaving it would offer a second decision on a decided task.
        XCTAssertNil(model.review)
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.actionInFlight)
    }

    /// The coordinator's own words survive. `snapshot evidence mismatch` and
    /// `stale_fencing_token` are the two a reviewer has to tell apart, and
    /// "Approval failed" hides which happened.
    @MainActor
    func test_a_refusal_keeps_the_coordinators_wording_and_the_review() async {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in self.review() },
            approve: { _ in
                throw ReviewBoardCoordinatorError.jsonRPCError(
                    code: -32000, message: "snapshot evidence mismatch"
                )
            },
            reject: { _, _ in }
        ))

        await model.loadReview(for: task())
        let landed = await model.approve()

        XCTAssertFalse(landed)
        XCTAssertEqual(model.actionError, "snapshot evidence mismatch")
        XCTAssertNotNil(model.review, "a refused approval leaves the review to retry")
        XCTAssertFalse(model.actionInFlight)
    }

    /// A task the coordinator cannot act on still renders — with the reason.
    /// A board that just omits the buttons leaves the reader guessing whether
    /// the feature is missing or the task is.
    @MainActor
    func test_a_task_with_no_attempt_reports_why_rather_than_offering_a_button() async {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in
                self.review(approvable: false, blocker: "This task has no coordinator attempt")
            },
            approve: { _ in XCTFail("must not be reachable") },
            reject: { _, _ in }
        ))

        await model.loadReview(for: task())
        XCTAssertFalse(model.review?.canAct == true)
        XCTAssertEqual(model.review?.blocker, "This task has no coordinator attempt")

        // And acting anyway is refused by the model, not by the coordinator —
        // the reason shown is the one already read off the task.
        let landed = await model.approve()
        XCTAssertFalse(landed)
        XCTAssertEqual(model.actionError, "This task has no coordinator attempt")
        XCTAssertFalse(model.actionInFlight)
    }

    /// Reading a patch is a subprocess, not a property: the 2-second refresh
    /// tick must not re-run git for a task already in hand.
    @MainActor
    func test_a_task_already_read_is_not_read_again() async {
        var reads = 0
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in reads += 1; return self.review() },
            approve: { _ in }, reject: { _, _ in }
        ))

        await model.loadReview(for: task())
        await model.loadReview(for: task())
        XCTAssertEqual(reads, 1)

        await model.loadReview(for: task(), force: true)
        XCTAssertEqual(reads, 2, "an explicit re-read still works")

        // A different task is a different read.
        await model.loadReview(for: task("tsk_2"))
        XCTAssertEqual(reads, 3)
    }

    /// Rejecting needs a reason, and the model passes it through untouched —
    /// the client is what trims and refuses an empty one.
    @MainActor
    func test_rejecting_passes_the_reason_through() async {
        var sent: String?
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in self.review() },
            approve: { _ in XCTFail("not this one") },
            reject: { _, reason in sent = reason }
        ))

        await model.loadReview(for: task())
        let landed = await model.reject(reason: "범위가 넘쳤다")

        XCTAssertTrue(landed)
        XCTAssertEqual(sent, "범위가 넘쳤다")
        XCTAssertNil(model.review)
    }

    /// The panel starts a read from `.task(id: task.rawID)`, which fires once
    /// per id. A read refused because another was still out therefore had
    /// nothing left to retrigger it, and the newly selected task sat with no
    /// review and no spinner until the selection moved twice.
    @MainActor
    func test_reading_another_task_supersedes_a_read_still_in_flight() async {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        var releaseFirst: CheckedContinuation<Void, Never>?
        model.setActions(ReviewBoardActions(
            review: { task in
                if task.rawID == "tsk_1" {
                    await withCheckedContinuation { releaseFirst = $0 }
                }
                return self.review(taskID: task.rawID)
            },
            approve: { _ in XCTFail("no decision here") },
            reject: { _, _ in XCTFail("no decision here") }
        ))

        async let firstRead: Void = model.loadReview(for: task("tsk_1"))
        // Let the first read reach its suspension point.
        for _ in 0..<1000 where releaseFirst == nil { await Task.yield() }
        XCTAssertNotNil(releaseFirst, "the first read should be parked at its continuation")

        // This is the whole point: it must not be refused.
        await model.loadReview(for: task("tsk_2"))
        XCTAssertEqual(model.review?.taskID, "tsk_2")

        releaseFirst?.resume()
        await firstRead
        XCTAssertEqual(
            model.review?.taskID, "tsk_2",
            "the superseded read must not land on top of the newer one"
        )
        XCTAssertFalse(model.actionInFlight)
    }

    /// What was read belongs to the task that was selected. Both the review and
    /// the "already read this one" marker go, or the next read is refused as
    /// redundant and the panel stays blank.
    @MainActor
    func test_selecting_a_different_task_drops_what_was_read() async {
        var reads = 0
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { task in reads += 1; return self.review(taskID: task.rawID) },
            approve: { _ in }, reject: { _, _ in }
        ))

        await model.loadReview(for: task("tsk_1"))
        XCTAssertEqual(model.review?.taskID, "tsk_1")

        model.selectTask(id: "tsk_2")
        XCTAssertNil(model.review, "a stale review must not sit under a new header")

        // And coming back re-reads rather than being refused as already in hand.
        model.selectTask(id: "tsk_1")
        await model.loadReview(for: task("tsk_1"))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.review?.taskID, "tsk_1")
    }

    /// Nothing wired: the board says so instead of throwing an opaque error.
    @MainActor
    func test_an_unwired_board_reports_that_the_coordinator_is_off() async {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        await model.loadReview(for: task())
        XCTAssertFalse(model.review?.canAct == true)
        XCTAssertNotNil(model.review?.blocker)

        let landed = await model.approve()
        XCTAssertFalse(landed)
        XCTAssertEqual(model.actionError, model.review?.blocker)
    }


    // MARK: - Auto pilot from the board

    /// The toggle writes through to settings, because the runner reads the
    /// policy fresh on every sweep — a toggle that only moved a published
    /// property would look on and act off.
    @MainActor
    func test_the_toggle_writes_through_to_what_the_runner_reads() {
        let defaults = UserDefaults(suiteName: "board.autopilot.\(UUID().uuidString)")!
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil,
            snapshotProvider: { .empty }, defaults: defaults
        )

        XCTAssertFalse(model.autoPilot.isEnabled, "off until someone turns it on")

        model.setAutoPilotEnabled(true)
        XCTAssertTrue(model.autoPilot.isEnabled)
        XCTAssertTrue(AutoPilotPolicy.load(from: defaults).isEnabled)

        model.setAutoPilotCeiling("integration")
        XCTAssertEqual(AutoPilotPolicy.load(from: defaults).ceilingBranch, "integration")

        // An emptied field is a mistake, not a request to merge into nothing.
        model.setAutoPilotCeiling("   ")
        XCTAssertEqual(model.autoPilot.ceilingBranch, "develop")
        XCTAssertEqual(AutoPilotPolicy.load(from: defaults).ceilingBranch, "develop")
    }

    /// The board reads whatever the runner already wrote, so the log survives
    /// a restart — and holds are in it, since "why is this still sitting here"
    /// is the usual question.
    @MainActor
    func test_the_board_reads_back_what_auto_pilot_recorded() {
        let team = "ws-\(UUID().uuidString.prefix(8))"
        let audit = AutoPilotJournal<AutoPilotAudit>(teamName: team, kind: "audit")
        audit.record(AutoPilotAudit(
            taskID: "tsk_1", title: "Wire the queue", decision: "held",
            reason: "Nothing has verified this task's build or tests.",
            headSHA: "abc", checkCommand: nil, atMS: 1
        ))
        AutoPilotUndoLog(teamName: team).record(AutoPilotUndoPoint(
            branch: "develop", sha: "deadbeef", taskID: "tsk_1",
            repositoryPath: "/repo", recordedAtMS: 2
        ))
        defer {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".term-mesh/autopilot", isDirectory: true)
            try? FileManager.default.removeItem(at: base.appendingPathComponent("\(team)-audit.json"))
            try? FileManager.default.removeItem(at: base.appendingPathComponent("\(team)-undo.json"))
        }

        let snapshot = ReviewBoardSnapshot(
            tasks: [ReviewBoardTask(id: "tsk_1", teamName: team, title: "T", status: "review_ready")],
            panelRuns: [], coordinatorOnline: true, memMeshAvailable: true,
            suspectHost: false, fencedZombie: false
        )
        let model = ReviewBoardViewModel(
            initialSnapshot: snapshot, selectedTaskID: nil, snapshotProvider: { snapshot },
            defaults: UserDefaults(suiteName: "board.autopilot.\(UUID().uuidString)")!
        )
        model.reloadAutoPilotJournals()

        XCTAssertEqual(model.autoPilotAudit.count, 1)
        XCTAssertFalse(model.autoPilotAudit[0].wasApproved)
        XCTAssertEqual(model.autoPilotUndoPoints.map(\.sha), ["deadbeef"])
    }

    /// With no team there is no journal to read, and inventing one would show
    /// another project's decisions.
    @MainActor
    func test_an_empty_board_has_no_auto_pilot_history() {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty },
            defaults: UserDefaults(suiteName: "board.autopilot.\(UUID().uuidString)")!
        )
        model.reloadAutoPilotJournals()
        XCTAssertTrue(model.autoPilotAudit.isEmpty)
        XCTAssertTrue(model.autoPilotUndoPoints.isEmpty)
    }

}

final class ReviewBoardTaskMergeTests: XCTestCase {
    private func team(status: String, blockedReason: String? = nil) -> ReviewBoardTask {
        ReviewBoardTask(
            id: "c259ab1f",
            teamName: "x-backup",
            title: "이 저장소를 요약",
            status: status,
            assignee: "executor",
            blockedReason: blockedReason,
            updatedAt: "2026-07-24T13:00:00Z"
        )
    }

    private func coordinator(status: String, reason: String? = nil) -> ReviewBoardTask {
        ReviewBoardTask(
            id: "c259ab1f",
            teamName: "Unknown team",
            title: "이 저장소를 요약",
            status: status,
            assignee: "jw-server",
            blockedReason: reason,
            updatedAt: "2026-07-24T13:05:00Z"
        )
    }

    /// Execution is the team's to describe. The coordinator saying `placed`
    /// is what it knew before the agent had the work at all.
    func testExecutionStatusComesFromTheTeam() {
        let merged = team(status: "in_progress").merging(coordinator: coordinator(status: "placed"))
        XCTAssertEqual(merged.status, "in_progress")
    }

    /// Completion ends execution locally; the coordinator's review phase is
    /// the next state and must remain visible on the Review Board.
    func testCoordinatorReviewReadyAdvancesACompletedTeamTask() {
        let merged = team(status: "completed")
            .merging(coordinator: coordinator(status: "review_ready"))
        XCTAssertEqual(merged.status, "review_ready")
    }

    /// A stale coordinator update must not erase a local stop that still needs
    /// attention.
    func testCoordinatorReviewReadyDoesNotOverwriteALocalBlock() {
        let merged = team(status: "blocked", blockedReason: "build failed")
            .merging(coordinator: coordinator(status: "review_ready"))
        XCTAssertEqual(merged.status, "blocked")
        XCTAssertEqual(merged.blockedReason, "build failed")
    }

    /// Review and merge are phases the team vocabulary cannot express, so
    /// when the coordinator reports one it is saying something new.
    func testMergePhaseComesFromTheCoordinator() {
        for phase in ["queued_for_merge", "approved", "merged", "quarantined", "suspect"] {
            let merged = team(status: "completed").merging(coordinator: coordinator(status: phase))
            XCTAssertEqual(merged.status, phase, "\(phase) should win over a team status")
        }
    }

    /// Facts either side holds alone are filled in, not dropped — the whole
    /// point of one id was that the two accounts describe the same work.
    func testEachSideFillsTheOthersGaps() {
        let merged = team(status: "blocked")
            .merging(coordinator: coordinator(status: "suspect", reason: "no team is running in x-backup"))

        XCTAssertEqual(merged.blockedReason, "no team is running in x-backup")
        XCTAssertEqual(merged.assignee, "executor", "the agent holding it beats the host it runs on")
        XCTAssertEqual(merged.teamName, "x-backup")
        XCTAssertEqual(merged.updatedAt, "2026-07-24T13:05:00Z", "the later of the two")
    }

    /// A reason the team already recorded is not overwritten by the
    /// coordinator's.
    func testTheTeamsOwnReasonWins() {
        let merged = team(status: "blocked", blockedReason: "build failed")
            .merging(coordinator: coordinator(status: "suspect", reason: "heartbeat stale"))
        XCTAssertEqual(merged.blockedReason, "build failed")
    }

    /// Merging rebuilds a task out of two already-parsed ones, so it is the
    /// one place where the raw reply could be quietly replaced by the scrubbed
    /// copy — which is what auto pilot reads its VERIFY command out of.
    func testMergingKeepsTheRawReplyRatherThanTheScrubbedCopy() {
        let reply = """
        STATUS: DONE
        FILES: a.swift
        VERIFY: /Users/agent/bin/check.sh
        NEXT: NONE
        FULL_REPORT: n/a
        """
        let local = ReviewBoardTask(
            id: "c259ab1f", teamName: "x-backup", title: "T", status: "completed",
            result: reply
        )
        let merged = local.merging(
            coordinator: ReviewBoardTask(
                id: "c259ab1f", teamName: "Unknown team", title: "T", status: "review_ready"
            )
        )
        XCTAssertEqual(merged.rawResult, reply)
        XCTAssertTrue(
            merged.result?.contains("…/check.sh") == true,
            "the display copy stays scrubbed: \(merged.result ?? "nil")"
        )
    }

    /// The merge target and the diff base are both git refs. `safeLabel`
    /// rewrites a long enough word run to `<token>`, so the shown parent is not
    /// a branch anyone can merge into.
    func testTheRecordedParentSurvivesTheScrubberThatTheShownOneDoesNot() {
        let branch = "feat/distributed-workspaces-review-followups"
        let task = ReviewBoardTask(
            id: "c259ab1f", teamName: "x-backup", title: "T", status: "review_ready",
            worktreeParent: branch
        )
        XCTAssertEqual(task.rawWorktreeParent, branch)
        XCTAssertTrue(
            task.worktreeParent?.contains("<token>") == true,
            "the display copy is expected to be scrubbed: \(task.worktreeParent ?? "nil")"
        )
    }

    /// Merging rebuilds the task from an already-scrubbed parent, so it has to
    /// carry the recorded one across rather than re-derive it.
    func testMergingKeepsTheRecordedParent() {
        let branch = "feat/distributed-workspaces-review-followups"
        let merged = ReviewBoardTask(
            id: "c259ab1f", teamName: "x-backup", title: "T", status: "completed",
            worktreeParent: branch
        ).merging(
            coordinator: ReviewBoardTask(
                id: "c259ab1f", teamName: "Unknown team", title: "T", status: "review_ready"
            )
        )
        XCTAssertEqual(merged.rawWorktreeParent, branch)
    }

    /// The raw copy follows whichever side's reply won, so the two never
    /// describe different replies.
    func testMergingTakesTheRawReplyFromTheSideWhoseResultWon() {
        let coordinatorReply = "STATUS: DONE\nVERIFY: /Users/agent/bin/peer.sh\nNEXT: NONE"
        let merged = ReviewBoardTask(
            id: "c259ab1f", teamName: "x-backup", title: "T", status: "completed"
        ).merging(
            coordinator: ReviewBoardTask(
                id: "c259ab1f", teamName: "Unknown team", title: "T", status: "review_ready",
                result: coordinatorReply
            )
        )
        XCTAssertEqual(merged.rawResult, coordinatorReply)
    }
}

final class ReviewBoardAgentReportTests: XCTestCase {
    func test_reads_the_five_fields_and_the_summary_under_them() {
        let report = ReviewBoardAgentReport(result: """
        STATUS: DONE
        FILES: none
        VERIFY: find . -maxdepth 1 -type f | wc -l
        NEXT: NONE
        FULL_REPORT: n/a

        저장소 최상위 파일은 9개입니다.
        ✻ Crunched for 6s
        """)
        XCTAssertEqual(report?.status, "DONE")
        XCTAssertEqual(report?.verify, "find . -maxdepth 1 -type f | wc -l")
        // `none`, `NONE` and `n/a` are the protocol saying "nothing here".
        XCTAssertNil(report?.files)
        XCTAssertNil(report?.next)
        XCTAssertNil(report?.fullReport)
        // The spinner line is the agent's decoration, not its answer.
        XCTAssertEqual(report?.body, "저장소 최상위 파일은 9개입니다.")
    }

    func test_no_header_means_no_report() {
        XCTAssertNil(ReviewBoardAgentReport(result: "just some output\n"))
        XCTAssertNil(ReviewBoardAgentReport(result: nil))
    }

    func test_a_report_of_only_chrome_is_empty_not_shown() {
        let report = ReviewBoardAgentReport(result: "STATUS: DONE\nFILES: none\nNEXT: NONE\n✻ Brewed for 6s\n")
        XCTAssertNotNil(report)
        XCTAssertTrue(report?.isEmpty == true, "nothing worth showing must not push out the empty-state line")
    }

    func test_no_summary_shows_nothing_rather_than_the_pane() {
        // The agent answered above the header, which is not captured, so there
        // is no summary. What follows the header is all terminal.
        let report = ReviewBoardAgentReport(result: """
        STATUS: DONE
        VERIFY: ls

        ✻ Cogitated for 9s

        ──────────────────────────── @executor ──
        ❯
        """)
        XCTAssertNil(report?.body, "a rule with an agent name in it is not a result")
        XCTAssertEqual(report?.verify, "ls")
    }

    func test_stops_at_the_pane_below_the_reply() {
        // What the poller captures runs to the bottom of the screen: the
        // status bar, a rule, the prompt. None of it is the agent's answer.
        let report = ReviewBoardAgentReport(result: """
        STATUS: DONE
        NEXT: NONE

        최상위 파일 개수는 9개.

        ✻ Crunched for 5s


        ◉ xhigh · /effort
        ──────────────────────────── @executor ──
        ❯
        jinwoo@host:~/work/project/x-backup (main)
        """)
        XCTAssertEqual(report?.body, "최상위 파일 개수는 9개.")
    }

    func test_an_asterisk_sentence_survives() {
        let report = ReviewBoardAgentReport(result: "STATUS: DONE\nNEXT: NONE\n\n* rebuilt the xcframework\n")
        XCTAssertEqual(report?.body, "* rebuilt the xcframework")
    }

    // MARK: - When a task finished

    /// Neither board writes a `completed_at`, so a terminal status is what
    /// turns the last `updated_at` into a finish. Reading it off a running
    /// task would label a heartbeat as a completion.
    func test_a_finish_time_belongs_only_to_a_task_that_finished() {
        func task(_ status: String) -> ReviewBoardTask {
            ReviewBoardTask(id: "t", teamName: "ws", title: "Fix the parser",
                            status: status, updatedAt: "2026-07-28T08:32:11Z")
        }
        for done in ["completed", "review_ready", "approved", "merged"] {
            XCTAssertEqual(task(done).finishedAt, "2026-07-28T08:32:11Z", done)
        }
        for running in ["queued", "assigned", "in_progress", "blocked", "failed"] {
            XCTAssertNil(task(running).finishedAt, running)
        }
        // Terminal but never stamped — nothing to show rather than a guess.
        XCTAssertNil(
            ReviewBoardTask(id: "t", teamName: "ws", title: "x", status: "completed").finishedAt
        )
    }

    /// Both stamp shapes reach this board: the coordinator's plain ISO-8601 and
    /// the team board's with fractional seconds. One parser dropped half of
    /// them, and a dropped stamp is a row with no time at all.
    func test_both_stamp_shapes_read_as_a_clock_time() {
        XCTAssertNotNil(ReviewBoardText.clockTime("2026-07-28T08:32:11Z"))
        XCTAssertNotNil(ReviewBoardText.clockTime("2026-07-28T08:32:11.482Z"))
        XCTAssertNil(ReviewBoardText.clockTime("whenever"))
        // A day other than today keeps its date — otherwise a week-old row
        // reads as if it just happened.
        let old = ReviewBoardText.clockTime("2020-01-02T03:04:05Z")
        XCTAssertEqual(old?.contains("1/2"), true, String(describing: old))
    }

    // MARK: - The directive a delegated title opens with

    /// The instruction is used verbatim as the title, so the constraint handed
    /// to the agent became the headline of the card and pushed the actual work
    /// out of the two lines a row has.
    func test_a_leading_directive_is_lifted_out_of_the_title() {
        let parts = ReviewBoardText.splitDirective("READ-ONLY 설계 검토. 파일 수정 절대 금지")
        XCTAssertEqual(parts.directive, "READ-ONLY")
        XCTAssertEqual(parts.rest, "설계 검토. 파일 수정 절대 금지")

        // Spelling and separator vary; the mark does not.
        XCTAssertEqual(ReviewBoardText.splitDirective("read only: check the plan").directive,
                       "READ ONLY")
        XCTAssertEqual(ReviewBoardText.splitDirective("READ-ONLY — audit").rest, "audit")

        // A title that merely starts with the same letters is not a directive.
        let plain = ReviewBoardText.splitDirective("Read-only mode is broken")
        XCTAssertEqual(plain.directive, "READ-ONLY")
        XCTAssertEqual(plain.rest, "mode is broken")

        // Nothing to lift.
        XCTAssertNil(ReviewBoardText.splitDirective("수정 작업. gk pull 로그").directive)
        XCTAssertEqual(ReviewBoardText.splitDirective("수정 작업. gk pull 로그").rest,
                       "수정 작업. gk pull 로그")
        // Directive with nothing behind it still has to say something.
        XCTAssertEqual(ReviewBoardText.splitDirective("READ-ONLY").rest, "READ-ONLY")
        XCTAssertNil(ReviewBoardText.splitDirective("READ-ONLY").directive)
    }

}
