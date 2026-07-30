import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The three things the 0.168 review found wrong with landing an approval.
///
/// All three share a shape: a rule that was written down and then never
/// reached the code that needed it. The merge ran `worktree finish` without
/// ever asking what state the worktree was in; the undo point was written
/// without the field that makes an undo possible; the boundary re-check read a
/// set that was always empty by the time it mattered.
final class ReviewBoardMergeSafetyRegression169Tests: XCTestCase {

    // MARK: - Harness

    /// Everything the coordinator was told, in order.
    private actor Reports {
        private(set) var entries: [(queue: String, status: String, error: String?)] = []
        func add(_ queue: String, _ status: String, _ error: String?) {
            entries.append((queue, status, error))
        }
        var statuses: [String] { entries.map(\.status) }
        var lastError: String? { entries.last?.error }
    }

    /// What git-kit was asked to do, if anything. A merge that was refused
    /// must not have run it at all — reporting a failure after finishing is
    /// not a refusal.
    private actor Invocations {
        private(set) var all: [[String]] = []
        func add(_ arguments: [String]) { all.append(arguments) }
        var count: Int { all.count }
    }

    private func output(_ text: String, status: Int32 = 0) -> ProcessRun.Output {
        ProcessRun.Output(
            status: status,
            stdout: Data(text.utf8),
            stderr: Data(),
            timedOut: false
        )
    }

    private func envelope(_ object: [String: Any]) -> ProcessRun.Output {
        ProcessRun.Output(
            status: 0,
            stdout: try! JSONSerialization.data(withJSONObject: object),
            stderr: Data(),
            timedOut: false
        )
    }

    /// A runner whose git answers exactly what a test wants it to, so the
    /// worktree can be dirty or moved on without arranging either for real.
    private func runner(
        reports: Reports,
        invocations: Invocations,
        porcelain: String,
        head: String
    ) -> ReviewBoardMergeRunner {
        ReviewBoardMergeRunner(
            command: { arguments, _ in
                await invocations.add(arguments)
                return self.envelope([
                    "state": "ok", "ok": true,
                    "result": ["mode": "promote", "branch": "feat/thing", "to": "develop"],
                ])
            },
            git: { arguments in
                if arguments.contains("status") { return self.output(porcelain) }
                if arguments.contains("rev-parse") { return self.output(head) }
                return nil
            },
            pathExists: { _ in true },
            report: { queue, status, error in await reports.add(queue, status, error) }
        )
    }

    private func job(approvedHeadSHA: String? = nil) -> ReviewBoardMergeRunner.Job {
        ReviewBoardMergeRunner.Job(
            queueID: "mrq_1",
            taskID: "tsk_1",
            worktreePath: "/tmp/wt",
            target: "develop",
            approvedHeadSHA: approvedHeadSHA
        )
    }

    // MARK: - (a) A dirty worktree is not merged

    /// `worktree finish` runs `gk promote`, whose first step is `gk commit -f`
    /// — so an uncommitted edit is committed *by the merge* and lands with it,
    /// while the approval was recorded from `git diff <base>..<head>` and
    /// covers committed history only. An agent that commits half its work and
    /// reports DONE got the other half merged unreviewed.
    func testADirtyWorktreeIsRefusedBeforeGitKitIsEverRun() async {
        let reports = Reports()
        let invocations = Invocations()
        let runner = runner(
            reports: reports,
            invocations: invocations,
            porcelain: " M Sources/Unreviewed.swift\n",
            head: "cafebabecafebabecafebabecafebabecafebabe"
        )

        let outcome = await runner.process(job())

        guard case .failed(let reason) = outcome else {
            return XCTFail("a dirty worktree must not merge, got \(outcome)")
        }
        XCTAssertTrue(
            reason.contains("uncommitted changes"),
            "the reason has to say what to do about it, got: \(reason)"
        )
        // The refusal is the point: nothing ran, so nothing was committed.
        let ran = await invocations.count
        XCTAssertEqual(ran, 0, "git-kit must not run for a refused merge")
        let statuses = await reports.statuses
        XCTAssertEqual(statuses, ["failed"])
    }

    /// The same hole from the other side: an approval names a commit, and a
    /// worktree that has moved past it is no longer the thing approved.
    func testAWorktreeThatMovedPastTheApprovedCommitIsRefused() async {
        let reports = Reports()
        let invocations = Invocations()
        let runner = runner(
            reports: reports,
            invocations: invocations,
            porcelain: "",
            head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )

        let outcome = await runner.process(
            job(approvedHeadSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        )

        guard case .failed(let reason) = outcome else {
            return XCTFail("a moved worktree must not merge, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("aaaaaaaa"), "names what was approved: \(reason)")
        XCTAssertTrue(reason.contains("bbbbbbbb"), "names what is there now: \(reason)")
        let ran = await invocations.count
        XCTAssertEqual(ran, 0)
    }

    /// The guard must not refuse the ordinary case, or it would simply stop
    /// the feature instead of making it safe.
    func testACleanWorktreeAtTheApprovedCommitStillMerges() async {
        let reports = Reports()
        let invocations = Invocations()
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let runner = runner(
            reports: reports,
            invocations: invocations,
            porcelain: "",
            head: sha
        )

        let outcome = await runner.process(job(approvedHeadSHA: sha))

        XCTAssertEqual(outcome, .merged(branch: "feat/thing"))
        let ran = await invocations.count
        XCTAssertEqual(ran, 1)
        let statuses = await reports.statuses
        XCTAssertEqual(statuses, ["running", "merged"])
    }

    /// Untracked files are what `--porcelain` reports with `??`, and they are
    /// still uncommitted work `gk commit -f` would sweep in.
    func testAnUntrackedFileCountsAsDirty() async {
        let reports = Reports()
        let invocations = Invocations()
        let runner = runner(
            reports: reports,
            invocations: invocations,
            porcelain: "?? Sources/New.swift\n",
            head: "cafebabecafebabecafebabecafebabecafebabe"
        )

        guard case .failed = await runner.process(job()) else {
            return XCTFail("an untracked file is uncommitted work too")
        }
        let ran = await invocations.count
        XCTAssertEqual(ran, 0)
    }

    // MARK: - (b) A recorded undo point can actually be undone

    /// The 0.168 shape: the merge recorded a point with no `mergedSHA`,
    /// because the field was added to the guard and never to the write. Every
    /// "Put back" then refused, whatever state the branch was in.
    func testAnUndoPointWithoutTheMergedSHAIsRefused() {
        let point = AutoPilotUndoPoint(
            branch: "develop",
            sha: "1111111111111111111111111111111111111111",
            taskID: "tsk_1",
            repositoryPath: "/tmp/repo",
            recordedAtMS: 1
        )
        let placement = AutoPilotUndo.Placement(
            checkedOutAt: nil,
            isDirty: false,
            currentTip: "2222222222222222222222222222222222222222"
        )

        guard case .refuse(let reason) = AutoPilotUndo.plan(for: point, placement: placement) else {
            return XCTFail("a point without mergedSHA cannot prove the branch stood still")
        }
        XCTAssertTrue(reason.contains("No post-merge commit"))
    }

    /// What the merge now writes: both shas, read from the same repository
    /// either side of the merge. That is the shape an undo can act on.
    func testAnUndoPointCarryingBothSHAsIsActionable() {
        let before = "1111111111111111111111111111111111111111"
        let after = "2222222222222222222222222222222222222222"
        let point = AutoPilotUndoPoint(
            branch: "develop",
            sha: before,
            mergedSHA: after,
            taskID: "tsk_1",
            repositoryPath: "/tmp/repo",
            recordedAtMS: 1
        )

        XCTAssertFalse(
            point.mergedSHA?.isEmpty ?? true,
            "the merge must record where the branch landed, not only where it started"
        )
        let plan = AutoPilotUndo.plan(
            for: point,
            placement: AutoPilotUndo.Placement(
                checkedOutAt: nil, isDirty: false, currentTip: after
            )
        )
        XCTAssertEqual(
            plan,
            .updateRef(repository: "/tmp/repo", branch: "develop", sha: before)
        )
    }

    /// And the guard the field exists for still bites: a branch that moved on
    /// after the merge must keep its later commits.
    func testUndoStillRefusesWhenTheBranchAdvancedPastTheMerge() {
        let point = AutoPilotUndoPoint(
            branch: "develop",
            sha: "1111111111111111111111111111111111111111",
            mergedSHA: "2222222222222222222222222222222222222222",
            taskID: "tsk_1",
            repositoryPath: "/tmp/repo",
            recordedAtMS: 1
        )
        let placement = AutoPilotUndo.Placement(
            checkedOutAt: nil,
            isDirty: false,
            currentTip: "3333333333333333333333333333333333333333"
        )

        guard case .refuse(let reason) = AutoPilotUndo.plan(for: point, placement: placement) else {
            return XCTFail("undoing past someone else's commits would lose them")
        }
        XCTAssertTrue(reason.contains("advanced"))
    }

    // MARK: - (c) Auto pilot's boundary still holds at merge time

    private var ceiling: AutoPilotPolicy {
        AutoPilotPolicy(
            isEnabled: true,
            ceilingBranch: "develop",
            protectedBranches: AutoPilotPolicy.defaultProtectedBranches,
            maxAutoMerges: 10
        )
    }

    /// The rule was never wrong; it never ran. The mark saying "auto pilot
    /// approved this" lived only as long as one pass, and the merge landed in
    /// the next one, so the check always saw `false` and waved the entry
    /// through as a person's decision.
    func testAnAutoApprovedTaskThatMovedOffTheCeilingIsRefused() {
        let refusal = ReviewBoardCoordinatorService.autoPilotBoundaryRefusal(
            target: "main",
            policy: ceiling,
            wasAutoApproved: true
        )

        XCTAssertNotNil(refusal, "auto pilot must not land on a branch it never approved for")
        XCTAssertTrue(refusal?.contains("develop") ?? false)
        XCTAssertTrue(refusal?.contains("main") ?? false)
    }

    func testAnAutoApprovedTaskStillOnTheCeilingIsMerged() {
        XCTAssertNil(
            ReviewBoardCoordinatorService.autoPilotBoundaryRefusal(
                target: "develop",
                policy: ceiling,
                wasAutoApproved: true
            )
        )
    }

    /// A person's approval is a decision, and lands on its own task's parent
    /// whatever the ceiling happens to be set to.
    func testAPersonsApprovalIsNotHeldToTheCeiling() {
        XCTAssertNil(
            ReviewBoardCoordinatorService.autoPilotBoundaryRefusal(
                target: "feature/x",
                policy: ceiling,
                wasAutoApproved: false
            )
        )
    }
}
