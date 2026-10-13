import Combine
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class ReviewBoardPresentationTests: XCTestCase {
    private func task(_ id: String, staleSeconds: Int? = nil, updatedAt: String? = "2026-10-13T01:00:00Z") -> ReviewBoardTask {
        ReviewBoardTask(
            id: id, teamName: "team", title: "work \(id)", status: "in_progress",
            isStale: staleSeconds != nil, staleSeconds: staleSeconds, updatedAt: updatedAt
        )
    }

    private func run(_ id: String, tail: String? = "tail") -> ReviewBoardPanelRun {
        ReviewBoardPanelRun(dictionary: ["run": id, "title": "panel", "phase": "running", "tail": tail as Any])!
    }

    private func snapshot(staleSeconds: Int?, runs: [ReviewBoardPanelRun] = []) -> ReviewBoardSnapshot {
        ReviewBoardSnapshot(
            tasks: [task("task-a", staleSeconds: staleSeconds)], panelRuns: runs,
            coordinatorOnline: false, memMeshAvailable: true, suspectHost: false, fencedZombie: false
        )
    }

    private func defaultsSuite() -> UserDefaults {
        UserDefaults(suiteName: "ReviewBoardPresentationTests.\(UUID().uuidString)")!
    }

    private func model(
        calls: @escaping () -> Void, snapshot: ReviewBoardSnapshot
    ) -> ReviewBoardViewModel {
        ReviewBoardViewModel(
            initialSnapshot: snapshot, selectedTaskID: nil,
            snapshotProvider: { calls(); return snapshot }, defaults: defaultsSuite()
        )
    }

    func testHiddenBoardNeverCallsTheProvider() {
        var calls = 0
        let board = model(calls: { calls += 1 }, snapshot: snapshot(staleSeconds: 1, runs: [run("r1")]))
        board.setPresented(false)
        board.activityTick()
        board.refreshIfPresented()
        board.setSnapshotProvider { calls += 1; return ReviewBoardSnapshot.empty }
        XCTAssertEqual(calls, 0)
    }

    func testShowingTheBoardRefreshesAtOnceAndTicksResume() {
        var calls = 0
        let board = model(calls: { calls += 1 }, snapshot: snapshot(staleSeconds: 1, runs: [run("r1")]))
        board.setPresented(false)
        board.setPresented(true)
        XCTAssertEqual(calls, 1, "reopening must not wait for the next tick")
        board.activityTick()
        XCTAssertEqual(calls, 2, "a visible board with panel runs refreshes on its beat")
        board.setPresented(true)
        XCTAssertEqual(calls, 2, "showing an already visible board is not a refresh")
    }

    func testOnlyTheWindowShowingItsBoardRefreshes() {
        var visibleCalls = 0
        var hiddenCalls = 0
        let shared = snapshot(staleSeconds: 1, runs: [run("r1")])
        let visible = model(calls: { visibleCalls += 1 }, snapshot: shared)
        let hidden = model(calls: { hiddenCalls += 1 }, snapshot: shared)
        hidden.setPresented(false)
        visible.activityTick()
        hidden.activityTick()
        XCTAssertEqual(visibleCalls, 1)
        XCTAssertEqual(hiddenCalls, 0)
    }

    func testStaleSecondsDoNotMakeTwoSnapshotsDiffer() {
        XCTAssertEqual(task("a", staleSeconds: 5), task("a", staleSeconds: 99))
        XCTAssertEqual(task("a", staleSeconds: 5).staleSeconds, 5)
        XCTAssertNotEqual(task("a", staleSeconds: 5), task("b", staleSeconds: 5))
        XCTAssertNotEqual(task("a", staleSeconds: nil), task("a", staleSeconds: 5), "isStale still counts")
    }

    func testIdenticalRefreshesPublishNothingEvenWithPanelRunsAndAgingTasks() {
        var tick = 10
        let runs = [run("r1")]
        let board = ReviewBoardViewModel(
            initialSnapshot: snapshot(staleSeconds: 10, runs: runs), selectedTaskID: nil,
            snapshotProvider: { tick += 3; return self.snapshot(staleSeconds: tick, runs: runs) },
            defaults: defaultsSuite()
        )
        var published = 0
        let cancellable = board.$snapshot.dropFirst().sink { _ in published += 1 }
        board.refresh()
        board.activityTick()
        board.refresh()
        XCTAssertEqual(published, 0)
        cancellable.cancel()
    }

    func testARealChangeStillPublishesOnce() {
        var current = snapshot(staleSeconds: 1, runs: [run("r1", tail: "one")])
        let board = ReviewBoardViewModel(
            initialSnapshot: current, selectedTaskID: nil,
            snapshotProvider: { current }, defaults: defaultsSuite()
        )
        var published = 0
        let cancellable = board.$snapshot.dropFirst().sink { _ in published += 1 }
        current = snapshot(staleSeconds: 2, runs: [run("r1", tail: "two")])
        board.refresh()
        board.refresh()
        XCTAssertEqual(published, 1)
        cancellable.cancel()
    }

    func testCachedDateParsingMatchesTheParserForHitsAndMisses() {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let stamp = "2026-10-13T01:02:03Z"
        XCTAssertEqual(ReviewBoardText.date(stamp), plain.date(from: stamp))
        XCTAssertEqual(ReviewBoardText.date(stamp), plain.date(from: stamp), "second read comes from the cache")
        XCTAssertNotNil(ReviewBoardText.date("2026-10-13T01:02:03.456Z"))
        XCTAssertNil(ReviewBoardText.date("not a date"))
        XCTAssertNil(ReviewBoardText.date("not a date"), "a miss is remembered as a miss")
    }

    func testCachedGroupingEqualsFreshGroupingAndFollowsChanges() {
        let tasks = (0..<5).map { task("t\($0)", updatedAt: "2026-10-13T01:0\($0):00Z") }
        XCTAssertEqual(ReviewBoardTask.groupedCached(tasks), ReviewBoardTask.grouped(tasks))
        XCTAssertEqual(ReviewBoardTask.groupedCached(tasks), ReviewBoardTask.grouped(tasks))
        let more = tasks + [task("t9", updatedAt: "2026-10-13T05:00:00Z")]
        XCTAssertEqual(ReviewBoardTask.groupedCached(more), ReviewBoardTask.grouped(more))
        XCTAssertNotEqual(ReviewBoardTask.groupedCached(more), ReviewBoardTask.groupedCached(tasks))
        XCTAssertEqual(ReviewBoardTask.groupedCached(tasks, window: 1), ReviewBoardTask.grouped(tasks, window: 1))
    }
}
