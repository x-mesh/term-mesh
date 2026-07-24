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
        XCTAssertEqual(model.digest(for: task).mergeQueue, "No merge queue entry reported")
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
