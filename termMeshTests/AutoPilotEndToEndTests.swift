import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Auto pilot, all the way through, with nothing faked but the coordinator.
///
/// Every other integration test here covers one piece. This is the claim the
/// feature actually makes: **a task that really builds gets really merged, and
/// can really be put back.** So the check is a real command in a real worktree,
/// the head it is bound to is read from real git, the merge is real `git-kit`,
/// and `develop` is inspected afterwards rather than inferred from a return
/// value.
///
/// Only the approval is a closure. Approving is a coordinator round-trip that
/// `ReviewBoardCoordinatorServiceTests` already exercises over a real socket;
/// repeating it here would test that suite rather than this path.
final class AutoPilotEndToEndTests: XCTestCase {
    private var root: URL!
    private var journalURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessRun.locate("git-kit") == nil, "git-kit is not installed here")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-e2e-\(UUID().uuidString)")
        // The repository is a subdirectory so the audit journal can sit beside
        // it rather than inside it — in production it lives under
        // ~/.term-mesh, and a journal written into the repo under test would
        // make every checkout look dirty.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("repo"), withIntermediateDirectories: true
        )
        journalURL = root.appendingPathComponent("audit.json")
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private var repositoryURL: URL { root.appendingPathComponent("repo") }
    private var repository: String { repositoryURL.path }

    @discardableResult
    private func git(_ arguments: [String], in directory: String? = nil) async throws -> String {
        let output = try await ProcessRun.capture(
            executable: "/usr/bin/git",
            arguments: ["-C", directory ?? repository] + arguments,
            environment: [
                "PATH": "/usr/bin:/bin",
                "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@t",
            ],
            timeout: 60
        )
        guard output.status == 0 else {
            throw NSError(domain: "git", code: Int(output.status), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(output.stderrText)",
            ])
        }
        return output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitKit(_ arguments: [String]) async throws -> ProcessRun.Output {
        var environment = ProcessInfo.processInfo.environment
        environment["GK_AGENT"] = "1"
        return try await ProcessRun.capture(
            executable: ProcessRun.locate("git-kit")!,
            arguments: arguments,
            environment: environment,
            currentDirectory: repository,
            timeout: 180
        )
    }

    /// A finished task: a worktree off `develop` with a commit in it, and an
    /// agent reply naming a command that verifies it.
    private func finishedTask(verify: String) async throws -> ReviewBoardTask {
        try await git(["init", "-q", "-b", "main", "."])
        try await git(["commit", "-q", "--allow-empty", "-m", "base"])
        try await git(["branch", "develop"])
        try await git(["checkout", "-q", "develop"])

        let worktree = root.appendingPathComponent("wt").path
        let created = try await gitKit(["worktree", "add", worktree, "-b", "feat/thing", "--from", "develop"])
        XCTAssertEqual(created.status, 0, created.stderrText)

        try "shipped\n".write(
            to: URL(fileURLWithPath: worktree).appendingPathComponent("done.txt"),
            atomically: true, encoding: .utf8
        )
        try await git(["add", "-A"], in: worktree)
        try await git(["commit", "-qm", "the work"], in: worktree)

        return ReviewBoardTask(
            id: "tsk_1", teamName: "ws", title: "Do the thing", status: "review_ready",
            result: """
            STATUS: DONE
            FILES: done.txt
            VERIFY: \(verify)
            NEXT: NONE
            FULL_REPORT: n/a
            """,
            worktreeParent: "develop",
            worktreePath: worktree
        )
    }

    private func policy(enabled: Bool = true, ceiling: String = "develop") -> AutoPilotPolicy {
        AutoPilotPolicy(
            isEnabled: enabled, ceilingBranch: ceiling,
            protectedBranches: AutoPilotPolicy.defaultProtectedBranches, maxAutoMerges: 10
        )
    }

    private func runner(
        policy: AutoPilotPolicy,
        approve: @escaping AutoPilotRunner.Approver
    ) -> AutoPilotRunner {
        AutoPilotRunner(
            policy: { policy },
            reviewer: { task in
                let patch = try? await ReviewBoardEvidence.read(
                    worktreePath: task.worktreePath ?? "",
                    parentRef: task.worktreeParent
                )
                return ReviewBoardReview(
                    taskID: task.rawID,
                    detail: ReviewBoardReviewDetail(
                        status: "review_ready", attemptID: "att_1", fencingToken: "fen_1",
                        worktreePath: task.worktreePath, hostID: nil, snapshot: nil,
                        queueID: nil, queueStatus: nil, queueLastError: nil
                    ),
                    patch: patch,
                    blocker: patch == nil ? "no patch" : nil
                )
            },
            approver: approve,
            // The real thing: a shell command in the worktree, and the head
            // read back out of git afterwards.
            checker: AutoPilotCheck.live(timeout: 60),
            audit: AutoPilotJournal<AutoPilotAudit>(url: journalURL),
            now: { 1 }
        )
    }

    // MARK: - The whole claim

    func testATaskThatReallyPassesItsCheckIsMergedAndCanBePutBack() async throws {
        let task = try await finishedTask(verify: "test -f done.txt")
        let developBefore = try await git(["rev-parse", "develop"])
        let worktreeHead = try await git(["rev-parse", "HEAD"], in: task.worktreePath!)

        var approved: [ReviewBoardReview] = []
        let outcomes = await runner(policy: policy(), approve: { review, _ in
            approved.append(review)
        }).sweep([task])

        // 1. It decided to approve — on evidence it produced itself.
        XCTAssertEqual(outcomes.map(\.approved), [true], outcomes.first?.reason ?? "")
        XCTAssertEqual(approved.count, 1)
        XCTAssertEqual(approved.first?.patch?.headSHA, worktreeHead)
        let entry = try XCTUnwrap(AutoPilotJournal<AutoPilotAudit>(url: journalURL).entries().first)
        XCTAssertTrue(entry.wasApproved)
        XCTAssertEqual(entry.checkCommand, "test -f done.txt")
        XCTAssertEqual(entry.headSHA, worktreeHead)

        // 2. The undo point is recorded against the checkout that survives the
        //    merge, before the merge happens.
        let resolvedRoot = await AutoPilotUndo.repositoryRoot(containing: task.worktreePath!)
        let repositoryRoot = try XCTUnwrap(resolvedRoot)
        let undoPoint = AutoPilotUndoPoint(
            branch: "develop", sha: developBefore, taskID: task.rawID,
            repositoryPath: repositoryRoot, recordedAtMS: 1
        )

        // 3. The merge really happens.
        let merged = await ReviewBoardMergeRunner(
            command: { arguments, _ in try await self.gitKit(arguments) },
            report: { _, _, _ in }
        ).process(ReviewBoardMergeRunner.Job(
            queueID: "mrq_1", taskID: task.rawID,
            worktreePath: task.worktreePath, target: "develop"
        ))
        guard case .merged = merged else { return XCTFail("merge failed: \(merged)") }

        let developAfterMerge = try await git(["rev-parse", "develop"])
        XCTAssertEqual(developAfterMerge, worktreeHead)
        let landed = try await git(["show", "--name-only", "--format=", "develop"])
        XCTAssertTrue(landed.contains("done.txt"), landed)

        // 4. And it really goes back.
        let placement = await AutoPilotUndo.placement(of: "develop", in: repositoryRoot)
        let undone = await AutoPilotUndo.apply(
            AutoPilotUndo.plan(for: undoPoint, placement: placement)
        )
        guard case .done = undone else { return XCTFail("undo failed: \(undone)") }

        let developAfterUndo = try await git(["rev-parse", "develop"])
        XCTAssertEqual(developAfterUndo, developBefore)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repositoryURL.appendingPathComponent("done.txt").path),
            "the merged file must be gone from the checkout, not just from the ref"
        )
        let dirt = try await git(["status", "--porcelain"])
        XCTAssertEqual(dirt, "", "the checkout has to agree with HEAD after an undo")
    }

    // MARK: - The gate, for real

    /// The agent said DONE. The command it named says otherwise, and the
    /// command is what counts.
    func testATaskWhoseCheckActuallyFailsIsNotMerged() async throws {
        let task = try await finishedTask(verify: "test -f never-written.txt")
        let developBefore = try await git(["rev-parse", "develop"])

        let outcomes = await runner(policy: policy(), approve: { _, _ in
            XCTFail("a failing check must not reach an approval")
        }).sweep([task])

        XCTAssertEqual(outcomes.map(\.approved), [false])
        XCTAssertEqual(
            outcomes.first?.reason,
            "The last check failed: test -f never-written.txt"
        )
        let unchanged = try await git(["rev-parse", "develop"])
        XCTAssertEqual(unchanged, developBefore)
    }

    /// The head is read after the command finishes, so work committed while
    /// the check ran voids it. Simulated by committing inside the check itself,
    /// which is the honest version of "the agent pushed one more fix".
    func testACommitLandingWhileTheCheckRunsVoidsTheEvidence() async throws {
        let task = try await finishedTask(
            verify: "git -c user.email=t@t -c user.name=T commit -q --allow-empty -m late"
        )

        let outcomes = await runner(policy: policy(), approve: { _, _ in
            XCTFail("evidence from before a new commit must not approve it")
        }).sweep([task])

        XCTAssertEqual(outcomes.map(\.approved), [false])
        let reason = outcomes.first?.reason ?? ""
        XCTAssertTrue(reason.contains("would be merged"), reason)
    }

    /// The ceiling is a real refusal, not a redirect: a task whose parent is
    /// `main` is handed back rather than merged somewhere else.
    func testATaskParentedOnMainIsNeverMergedAutomatically() async throws {
        var task = try await finishedTask(verify: "true")
        task = ReviewBoardTask(
            id: task.rawID, teamName: task.teamName, title: task.title, status: task.status,
            result: task.result, worktreeParent: "main", worktreePath: task.worktreePath
        )
        let developBefore = try await git(["rev-parse", "develop"])

        let outcomes = await runner(policy: policy(), approve: { _, _ in
            XCTFail("main is never merged automatically")
        }).sweep([task])

        XCTAssertEqual(outcomes.first?.reason, "main is never merged automatically.")
        let unchanged = try await git(["rev-parse", "develop"])
        XCTAssertEqual(unchanged, developBefore)
    }

    /// Off means off, all the way down: no check is run, so nothing is even
    /// executed in the worktree.
    func testNothingRunsWhileTheToggleIsOff() async throws {
        let marker = root.appendingPathComponent("check-ran.txt")
        let task = try await finishedTask(verify: "touch \(marker.path)")

        let outcomes = await runner(policy: policy(enabled: false), approve: { _, _ in
            XCTFail("must not act while off")
        }).sweep([task])

        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "an off auto pilot must not execute a task's VERIFY command"
        )
    }
}
