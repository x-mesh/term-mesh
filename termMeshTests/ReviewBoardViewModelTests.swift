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
}
