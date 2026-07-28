import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class AutoPilotRunnerTests: XCTestCase {
    private var journalURL: URL!

    override func setUp() {
        super.setUp()
        journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-\(UUID().uuidString)/audit.json")
    }

    private func journal() -> AutoPilotJournal<AutoPilotAudit> {
        AutoPilotJournal<AutoPilotAudit>(url: journalURL)
    }

    private func task(
        _ id: String = "tsk_1",
        status: String = "review_ready",
        parent: String? = "develop",
        verify: String = "xcodebuild test"
    ) -> ReviewBoardTask {
        ReviewBoardTask(
            id: id, teamName: "ws", title: "Do the thing", status: status,
            result: """
            STATUS: DONE
            FILES: a.swift
            VERIFY: \(verify)
            NEXT: NONE
            FULL_REPORT: n/a
            """,
            worktreeParent: parent,
            worktreePath: "/tmp/wt"
        )
    }

    private func review(head: String = "abc1234567890") -> ReviewBoardReview {
        ReviewBoardReview(
            taskID: "tsk_1",
            detail: ReviewBoardReviewDetail(
                status: "review_ready", attemptID: "att_1", fencingToken: "fen_1",
                worktreePath: "/tmp/wt", hostID: nil, snapshot: nil,
                queueID: nil, queueStatus: nil, queueLastError: nil
            ),
            patch: ReviewBoardEvidence.Patch(
                baseSHA: "base", headSHA: head, digest: "sha256:cafe",
                text: "diff", isTruncated: false,
                files: [.init(path: "a.swift", kind: "modified", add: 1, del: 0)]
            ),
            blocker: nil
        )
    }

    private func evidence(
        passed: Bool = true, head: String = "abc1234567890", command: String = "xcodebuild test"
    ) -> AutoPilotCheckEvidence {
        AutoPilotCheckEvidence(command: command, passed: passed, headSHA: head, recordedAtMS: 1)
    }

    private func runner(
        policy: AutoPilotPolicy = AutoPilotPolicy(
            isEnabled: true, ceilingBranch: "develop",
            protectedBranches: AutoPilotPolicy.defaultProtectedBranches, maxAutoMerges: 10
        ),
        review: ReviewBoardReview? = nil,
        evidence: AutoPilotCheckEvidence? = nil,
        approve: @escaping AutoPilotRunner.Approver = { _, _ in }
    ) -> AutoPilotRunner {
        let fixedReview = review ?? self.review()
        let fixedEvidence = evidence
        return AutoPilotRunner(
            policy: { policy },
            reviewer: { _ in fixedReview },
            approver: approve,
            checker: { _ in fixedEvidence },
            audit: journal(),
            now: { 1_784_882_974_390 }
        )
    }

    // MARK: - Happy path

    func testAPassingCheckAtTheMergingHeadIsApprovedWithoutAPerson() async {
        var approvals: [String] = []
        let runner = runner(evidence: evidence(), approve: { review, summary in
            approvals.append("\(review.taskID)|\(summary)")
        })

        let outcomes = await runner.sweep([task()])

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].approved)
        XCTAssertEqual(approvals.count, 1)
        // The summary tells the next reader what was run and where it is going.
        XCTAssertTrue(approvals[0].contains("xcodebuild test"), approvals[0])
        XCTAssertTrue(approvals[0].contains("abc12345"), approvals[0])
        XCTAssertTrue(approvals[0].contains("develop"), approvals[0])

        let logged = journal().entries()
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].wasApproved)
        XCTAssertEqual(logged[0].checkCommand, "xcodebuild test")
        XCTAssertEqual(logged[0].headSHA, "abc1234567890")
    }

    // MARK: - The gate

    /// `STATUS: DONE` is a claim. Without an exit code at a known head there is
    /// nothing to approve on.
    func testATaskWhoseCheckDidNotRunIsHeldRatherThanTrusted() async {
        var approved = false
        let runner = runner(evidence: nil, approve: { _, _ in approved = true })

        let outcomes = await runner.sweep([task()])

        XCTAssertFalse(approved)
        XCTAssertEqual(outcomes[0].reason, "Nothing has verified this task's build or tests.")
        XCTAssertEqual(journal().entries().first?.decision, "held")
    }

    func testAFailingCheckIsHeldAndNamesTheCommand() async {
        let runner = runner(evidence: evidence(passed: false), approve: { _, _ in
            XCTFail("must not approve on a failed check")
        })
        let outcomes = await runner.sweep([task()])
        XCTAssertEqual(outcomes[0].reason, "The last check failed: xcodebuild test")
    }

    /// An agent verifies, commits one more fix, reports done. The check still
    /// says passed and describes a commit that is not the one merging.
    func testACheckFromBeforeTheLastCommitIsHeld() async {
        let runner = runner(
            review: review(head: "newhead0000"),
            evidence: evidence(head: "oldhead0000"),
            approve: { _, _ in XCTFail("must not approve across a moved head") }
        )
        let outcomes = await runner.sweep([task()])
        XCTAssertTrue(outcomes[0].reason.contains("oldhead0"), outcomes[0].reason)
        XCTAssertTrue(outcomes[0].reason.contains("newhead0"), outcomes[0].reason)
    }

    // MARK: - The boundary

    func testATaskTargetingMainIsRefusedWithoutPayingForATestRun() async {
        var checksRun = 0
        let runner = AutoPilotRunner(
            policy: {
                AutoPilotPolicy(
                    isEnabled: true, ceilingBranch: "develop",
                    protectedBranches: AutoPilotPolicy.defaultProtectedBranches, maxAutoMerges: 10
                )
            },
            reviewer: { _ in self.review() },
            approver: { _, _ in XCTFail("must not approve into main") },
            checker: { _ in checksRun += 1; return self.evidence() },
            audit: journal(),
            now: { 1 }
        )

        let outcomes = await runner.sweep([task(parent: "main")])

        XCTAssertEqual(outcomes[0].reason, "main is never merged automatically.")
        // Refusing should not cost a full test run.
        XCTAssertEqual(checksRun, 0)
    }

    func testATaskWithNoRecordedParentIsHeld() async {
        let runner = runner(evidence: evidence(), approve: { _, _ in XCTFail("no target") })
        let outcomes = await runner.sweep([task(parent: nil)])
        XCTAssertEqual(outcomes[0].reason, "This task does not record where it would merge to.")
    }

    func testTheBudgetCountsApprovalsAcrossTasks() async {
        var approvals = 0
        let runner = runner(
            policy: AutoPilotPolicy(
                isEnabled: true, ceilingBranch: "develop",
                protectedBranches: AutoPilotPolicy.defaultProtectedBranches, maxAutoMerges: 2
            ),
            evidence: evidence(),
            approve: { _, _ in approvals += 1 }
        )

        let outcomes = await runner.sweep([task("a"), task("b"), task("c")])

        XCTAssertEqual(approvals, 2)
        XCTAssertEqual(outcomes.map(\.approved), [true, true, false])
        XCTAssertTrue(outcomes[2].reason.contains("limit 2"), outcomes[2].reason)
    }

    // MARK: - Turned off, and other states

    func testNothingHappensWhileAutoPilotIsOff() async {
        let runner = runner(
            policy: AutoPilotPolicy(
                isEnabled: false, ceilingBranch: "develop",
                protectedBranches: AutoPilotPolicy.defaultProtectedBranches, maxAutoMerges: 10
            ),
            evidence: evidence(),
            approve: { _, _ in XCTFail("must not act while off") }
        )
        let outcomes = await runner.sweep([task()])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(journal().entries().isEmpty, "an off runner writes no audit noise")
    }

    /// A task that is not up for a decision is not a refusal, and auditing it
    /// would bury the ones that are.
    func testTasksThatAreNotReviewReadyAreNotConsideredAtAll() async {
        let runner = runner(evidence: evidence(), approve: { _, _ in XCTFail("not ready") })
        let outcomes = await runner.sweep([
            task("a", status: "assigned"),
            task("b", status: "queued_for_merge"),
            task("c", status: "completed"),
        ])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(journal().entries().isEmpty)
    }

    // MARK: - Audit volume

    /// The board refreshes every two seconds. Without deduplication the log
    /// would be one sentence ten thousand times.
    func testARepeatedHoldIsRecordedOnceUntilTheReasonChanges() async {
        var currentEvidence: AutoPilotCheckEvidence?
        let runner = AutoPilotRunner(
            policy: {
                AutoPilotPolicy(
                    isEnabled: true, ceilingBranch: "develop",
                    protectedBranches: AutoPilotPolicy.defaultProtectedBranches, maxAutoMerges: 10
                )
            },
            reviewer: { _ in self.review() },
            approver: { _, _ in },
            checker: { _ in currentEvidence },
            audit: journal(),
            now: { 1 }
        )

        for _ in 0..<5 { _ = await runner.sweep([task()]) }
        XCTAssertEqual(journal().entries().count, 1)

        // The reason changes: now there is a check, and it failed.
        currentEvidence = evidence(passed: false)
        for _ in 0..<5 { _ = await runner.sweep([task()]) }
        let entries = journal().entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.reason, "The last check failed: xcodebuild test")
    }

    /// A coordinator that refused is a transient failure, not a decision — the
    /// next sweep must try again rather than stay quiet.
    func testARefusedApprovalIsRetriedOnTheNextSweep() async {
        var attempts = 0
        let runner = AutoPilotRunner(
            policy: {
                AutoPilotPolicy(
                    isEnabled: true, ceilingBranch: "develop",
                    protectedBranches: AutoPilotPolicy.defaultProtectedBranches, maxAutoMerges: 10
                )
            },
            reviewer: { _ in self.review() },
            approver: { _, _ in
                attempts += 1
                if attempts == 1 {
                    throw ReviewBoardCoordinatorError.jsonRPCError(
                        code: -32000, message: "stale_fencing_token"
                    )
                }
            },
            checker: { _ in self.evidence() },
            audit: journal(),
            now: { 1 }
        )

        let first = await runner.sweep([task()])
        XCTAssertFalse(first[0].approved)
        XCTAssertTrue(first[0].reason.contains("refused"), first[0].reason)

        let second = await runner.sweep([task()])
        XCTAssertTrue(second[0].approved)
        XCTAssertEqual(attempts, 2)
    }

    // MARK: - Reading the VERIFY line

    func testAnAgentSayingThereIsNoCheckIsNotTreatedAsAPassingCheck() {
        for value in ["n/a", "N/A", "none", "-", "  "] {
            XCTAssertNil(
                AutoPilotCheck.verifyCommand(in: task(verify: value)),
                "\(value) must not become a command"
            )
        }
        XCTAssertEqual(
            AutoPilotCheck.verifyCommand(in: task(verify: "  cargo test  ")),
            "cargo test"
        )
    }

    func testATaskWithNoReplyHasNoCheckCommand() {
        let bare = ReviewBoardTask(id: "t", teamName: "ws", title: "T", status: "review_ready")
        XCTAssertNil(AutoPilotCheck.verifyCommand(in: bare))
    }
}
