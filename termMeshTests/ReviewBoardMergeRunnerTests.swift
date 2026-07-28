import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ReviewBoardMergeRunnerTests: XCTestCase {
    /// Everything the coordinator was told, in order.
    private actor Reports {
        private(set) var entries: [(queue: String, status: String, error: String?)] = []
        func add(_ queue: String, _ status: String, _ error: String?) {
            entries.append((queue, status, error))
        }
        var statuses: [String] { entries.map(\.status) }
        var lastError: String? { entries.last?.error }
    }

    private func envelope(_ object: [String: Any]) -> ProcessRun.Output {
        ProcessRun.Output(
            status: 0,
            stdout: try! JSONSerialization.data(withJSONObject: object),
            stderr: Data(),
            timedOut: false
        )
    }

    private func runner(
        reports: Reports,
        pathExists: @escaping (String) -> Bool = { _ in true },
        timeout: TimeInterval = 300,
        command: @escaping ReviewBoardMergeRunner.Command
    ) -> ReviewBoardMergeRunner {
        ReviewBoardMergeRunner(
            timeout: timeout,
            command: command,
            pathExists: pathExists,
            report: { queue, status, error in await reports.add(queue, status, error) }
        )
    }

    private let job = ReviewBoardMergeRunner.Job(
        queueID: "mrq_1", taskID: "tsk_1", worktreePath: "/tmp/wt", target: "develop"
    )

    // MARK: - Happy path

    func testASuccessfulFinishReportsMergedAndNamesTheBranch() async {
        let reports = Reports()
        var seen: [String] = []
        let runner = runner(reports: reports) { arguments, _ in
            seen = arguments
            return self.envelope([
                "state": "ok", "ok": true,
                "result": ["mode": "promote", "branch": "feat/thing", "to": "develop"],
            ])
        }

        let outcome = await runner.process(job)

        XCTAssertEqual(outcome, .merged(branch: "feat/thing"))
        // The target is passed, never inferred — a merge that lands somewhere
        // nobody expected is what guessing buys.
        XCTAssertEqual(
            seen,
            ["worktree", "finish", "--repo", "/tmp/wt", "--to", "develop", "--cleanup"]
        )
        let statuses = await reports.statuses
        XCTAssertEqual(statuses, ["running", "merged"])
    }

    // MARK: - F6 — a paused merge is not retried

    /// git-kit pauses on conflict rather than failing. Running finish again on
    /// top of a paused rebase compounds it, so a pause is reported as failed
    /// and carries the way out.
    func testAPausedMergeIsReportedFailedWithTheResumeCommandAndNeverRerun() async {
        let reports = Reports()
        var invocations = 0
        let runner = runner(reports: reports) { _, _ in
            invocations += 1
            return self.envelope([
                "state": "paused", "ok": false,
                "result": [
                    "message": "merge stopped on conflicts in 2 files.",
                    "resume": "git-kit resolve --ai",
                ],
            ])
        }

        let outcome = await runner.process(job)

        XCTAssertEqual(invocations, 1, "a pause must not trigger a second finish")
        guard case .failed(let reason) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("conflicts in 2 files"), reason)
        XCTAssertTrue(reason.contains("not retried"), reason)
        XCTAssertTrue(reason.contains("git-kit resolve --ai"), reason)

        let statuses = await reports.statuses
        XCTAssertEqual(statuses, ["running", "failed"])
        let recorded = await reports.lastError
        XCTAssertEqual(recorded, reason, "the reason a person reads is the one stored")
    }

    /// A pause with nothing to resume still has to say it stopped.
    func testAPauseWithNoResumeCommandStillSaysItWasNotRetried() async {
        let reports = Reports()
        let runner = runner(reports: reports) { _, _ in
            self.envelope(["state": "paused", "ok": false, "result": [:]])
        }
        guard case .failed(let reason) = await runner.process(job) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(reason.contains("paused"), reason)
        XCTAssertTrue(reason.contains("by hand"), reason)
    }

    // MARK: - F7 — a missing worktree is filtered before running

    func testATaskWithNoWorktreeIsRefusedWithoutRunningAnything() async {
        let reports = Reports()
        var invocations = 0
        let runner = runner(reports: reports) { _, _ in
            invocations += 1
            return self.envelope(["state": "ok", "ok": true])
        }

        let outcome = await runner.process(ReviewBoardMergeRunner.Job(
            queueID: "mrq_1", taskID: "tsk_1", worktreePath: nil, target: "develop"
        ))

        XCTAssertEqual(invocations, 0)
        XCTAssertEqual(outcome, .failed("This task has no worktree recorded, so there is nothing to merge."))
        // Never reported as running: it never ran.
        let statuses = await reports.statuses
        XCTAssertEqual(statuses, ["failed"])
    }

    func testAWorktreeThatIsGoneIsRefusedWithTheDirectoryNamed() async {
        let reports = Reports()
        var invocations = 0
        let runner = runner(reports: reports, pathExists: { _ in false }) { _, _ in
            invocations += 1
            return self.envelope(["state": "ok", "ok": true])
        }

        let outcome = await runner.process(job)

        XCTAssertEqual(invocations, 0)
        guard case .failed(let reason) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("/tmp/wt"), reason)
        XCTAssertTrue(reason.contains("gone"), reason)
    }

    func testAWhitespaceOnlyWorktreePathCountsAsNoWorktree() async {
        let reports = Reports()
        let runner = runner(reports: reports) { _, _ in
            XCTFail("must not run")
            return self.envelope([:])
        }
        let outcome = await runner.process(ReviewBoardMergeRunner.Job(
            queueID: "q", taskID: "t", worktreePath: "   ", target: "develop"
        ))
        XCTAssertEqual(outcome, .failed("This task has no worktree recorded, so there is nothing to merge."))
    }

    // MARK: - F9 — the same item is never merged twice at once

    func testTwoCallsForTheSameQueueItemProduceOneMerge() async {
        let reports = Reports()
        let started = expectation(description: "first finish entered")
        let release = expectation(description: "first finish released")
        var invocations = 0

        let runner = runner(reports: reports) { _, _ in
            invocations += 1
            if invocations == 1 {
                started.fulfill()
                await self.fulfillment(of: [release], timeout: 5)
            }
            return self.envelope(["state": "ok", "ok": true, "result": ["branch": "b"]])
        }

        async let first = runner.process(job)
        await fulfillment(of: [started], timeout: 5)
        // While the first merge is still in git-kit, a second arrives.
        let second = await runner.process(job)
        release.fulfill()
        let firstOutcome = await first

        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertEqual(firstOutcome, .merged(branch: "b"))
        XCTAssertEqual(invocations, 1)

        // And once it is done the item can be retried deliberately.
        let after = await runner.process(job)
        XCTAssertEqual(after, .merged(branch: "b"))
        XCTAssertEqual(invocations, 2)
    }

    /// A different item is not blocked by the one in flight.
    func testADifferentQueueItemIsNotBlocked() async {
        let reports = Reports()
        let runner = runner(reports: reports) { _, _ in
            self.envelope(["state": "ok", "ok": true, "result": ["branch": "b"]])
        }
        let other = ReviewBoardMergeRunner.Job(
            queueID: "mrq_2", taskID: "tsk_2", worktreePath: "/tmp/wt2", target: "develop"
        )
        let outcomes = await runner.processAll([job, other])
        XCTAssertEqual(outcomes.map(\.1), [.merged(branch: "b"), .merged(branch: "b")])
    }

    // MARK: - Timeout and unreadable answers

    func testAFinishThatNeverAnswersIsStoppedAndReportedFailed() async {
        let reports = Reports()
        let runner = runner(reports: reports, timeout: 90) { _, _ in
            ProcessRun.Output(status: 15, stdout: Data(), stderr: Data(), timedOut: true)
        }

        guard case .failed(let reason) = await runner.process(job) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(reason.contains("90s"), reason)
        let statuses = await reports.statuses
        XCTAssertEqual(statuses, ["running", "failed"])
    }

    func testAnErrorEnvelopeCarriesItsMessageAndFirstRemedy() async {
        let reports = Reports()
        let runner = runner(reports: reports) { _, _ in
            self.envelope([
                "state": "error", "ok": false,
                "error": [
                    "code": "DIRTY_TREE",
                    "message": "the worktree has uncommitted changes",
                    "remedies": [["command": "git-kit commit -f", "safety": "safe"]],
                ],
            ])
        }
        guard case .failed(let reason) = await runner.process(job) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(
            reason,
            "the worktree has uncommitted changes Suggested: git-kit commit -f"
        )
    }

    /// Prose instead of JSON means GK_AGENT did not take effect. Guessing at
    /// the words would be worse than saying it could not be read.
    func testANonJSONAnswerIsAFailureNotASuccess() async {
        let reports = Reports()
        let runner = runner(reports: reports) { _, _ in
            ProcessRun.Output(
                status: 1,
                stdout: Data("Everything up to date.\n".utf8),
                stderr: Data("fatal: not a git repository".utf8),
                timedOut: false
            )
        }
        guard case .failed(let reason) = await runner.process(job) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(reason.contains("unreadable"), reason)
        XCTAssertTrue(reason.contains("not a git repository"), reason)
    }

    func testAMissingExecutableIsReportedRatherThanThrown() async {
        let reports = Reports()
        let runner = runner(reports: reports) { _, _ in
            throw ProcessRun.Failure.couldNotStart("No such file or directory")
        }
        guard case .failed(let reason) = await runner.process(job) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(reason.contains("git-kit could not be started"), reason)
    }

    // MARK: - Joining a queue entry to its task

    func testAQueueEntryWithoutItsTaskProducesNoJob() throws {
        let item = try XCTUnwrap(ReviewBoardMergeQueueItem(dictionary: [
            "queue_id": "mrq_1", "task_id": "tsk_1", "attempt_id": "att_1",
            "status": "queued", "approved_by": "reviewer",
        ]))
        // The worktree path lives on the task; without it there is no directory
        // to merge in, and picking one would be a guess.
        XCTAssertNil(ReviewBoardMergeRunner.Job(item: item, tasks: []))

        let task = ReviewBoardTask(
            id: "tsk_1", teamName: "ws", title: "Do it", status: "queued_for_merge",
            worktreePath: "/tmp/wt"
        )
        let built = try XCTUnwrap(
            ReviewBoardMergeRunner.Job(item: item, tasks: [task], target: "develop")
        )
        XCTAssertEqual(built.worktreePath, "/tmp/wt")
        XCTAssertEqual(built.target, "develop")
    }
}
