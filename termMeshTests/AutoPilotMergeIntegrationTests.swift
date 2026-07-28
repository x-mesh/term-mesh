import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Merging, then putting it back, against a real repository.
///
/// The unit tests fake git-kit's envelope, which is the right seam for the
/// failure modes — a conflicted rebase is very hard to arrange on demand. What
/// they cannot check is whether the invocation is right, and the first live run
/// found a bug none of them could: `finish --cleanup` deletes the worktree it
/// merged from, so an undo point recorded against that path names a directory
/// that is gone by the time anyone wants it.
final class AutoPilotMergeIntegrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessRun.locate("git-kit") == nil, "git-kit is not installed here")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private var repository: String { root.path }

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

    private func gitKit(_ arguments: [String], in directory: String) async throws -> ProcessRun.Output {
        var environment = ProcessInfo.processInfo.environment
        environment["GK_AGENT"] = "1"
        return try await ProcessRun.capture(
            executable: ProcessRun.locate("git-kit")!,
            arguments: arguments,
            environment: environment,
            currentDirectory: directory,
            timeout: 180
        )
    }

    /// A repository with `develop` checked out and a worktree branched off it
    /// holding one commit — the shape auto pilot merges.
    private func makeWorkToMerge() async throws -> (worktree: String, head: String) {
        try await git(["init", "-q", "-b", "main", "."])
        try await git(["commit", "-q", "--allow-empty", "-m", "base"])
        try await git(["branch", "develop"])
        try await git(["checkout", "-q", "develop"])
        try await git(["commit", "-q", "--allow-empty", "-m", "develop moves"])

        let worktree = root.appendingPathComponent("wt").path
        // Through git-kit so the branch records its gk-parent, which is what
        // `finish --to` resolves against.
        let created = try await gitKit(
            ["worktree", "add", worktree, "-b", "feat/thing", "--from", "develop"],
            in: repository
        )
        XCTAssertEqual(created.status, 0, created.stderrText)

        try await git(["commit", "-q", "--allow-empty", "-m", "the work"], in: worktree)
        return (worktree, try await git(["rev-parse", "HEAD"], in: worktree))
    }

    // MARK: - Merging

    func testTheRunnersOwnInvocationMergesAndRemovesTheWorktree() async throws {
        let (worktree, head) = try await makeWorkToMerge()
        let developBefore = try await git(["rev-parse", "develop"])
        XCTAssertNotEqual(developBefore, head)

        var reported: [(String, String, String?)] = []
        let runner = ReviewBoardMergeRunner(
            command: { arguments, _ in try await self.gitKit(arguments, in: self.repository) },
            report: { queue, status, error in reported.append((queue, status, error)) }
        )

        let outcome = await runner.process(ReviewBoardMergeRunner.Job(
            queueID: "mrq_1", taskID: "tsk_1", worktreePath: worktree, target: "develop"
        ))

        guard case .merged = outcome else {
            return XCTFail("expected a merge, got \(outcome) — reported \(reported)")
        }
        let developAfter = try await git(["rev-parse", "develop"])
        XCTAssertEqual(developAfter, head, "develop should now be at the work's commit")
        XCTAssertEqual(reported.map(\.1), ["running", "merged"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: worktree),
            "--cleanup removes the worktree, which is what breaks a naive undo point"
        )
    }

    // MARK: - Undoing

    /// End to end: record where develop stood, merge, put it back. develop is
    /// checked out here, which is the case where moving the ref would leave
    /// HEAD and the index disagreeing.
    func testAMergeIntoACheckedOutBranchIsUndoneByResettingThatCheckout() async throws {
        let (worktree, head) = try await makeWorkToMerge()
        let developBefore = try await git(["rev-parse", "develop"])

        // Recorded before the merge, against the repository that survives it.
        let repositoryRoot = await AutoPilotUndo.repositoryRoot(containing: worktree)
        XCTAssertEqual(
            repositoryRoot.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            URL(fileURLWithPath: repository).resolvingSymlinksInPath().path,
            "the undo point must name the checkout that outlives --cleanup"
        )
        let point = AutoPilotUndoPoint(
            branch: "develop", sha: developBefore, taskID: "tsk_1",
            repositoryPath: repositoryRoot!, recordedAtMS: 1
        )

        let runner = ReviewBoardMergeRunner(
            command: { arguments, _ in try await self.gitKit(arguments, in: self.repository) },
            report: { _, _, _ in }
        )
        _ = await runner.process(ReviewBoardMergeRunner.Job(
            queueID: "mrq_1", taskID: "tsk_1", worktreePath: worktree, target: "develop"
        ))
        let afterMerge = try await git(["rev-parse", "develop"])
        XCTAssertEqual(afterMerge, head)

        let placement = await AutoPilotUndo.placement(of: "develop", in: point.repositoryPath)
        XCTAssertNotNil(placement.checkedOutAt, "develop is checked out in the main worktree")
        XCTAssertFalse(placement.isDirty)

        let plan = AutoPilotUndo.plan(for: point, placement: placement)
        guard case .resetWorktree = plan else {
            return XCTFail("a checked-out branch must be reset, not ref-moved: \(plan)")
        }
        let result = await AutoPilotUndo.apply(plan)
        guard case .done = result else { return XCTFail("undo failed: \(result)") }

        let restored = try await git(["rev-parse", "develop"])
        XCTAssertEqual(restored, developBefore)
        // And the checkout agrees with HEAD, which is the whole point of
        // resetting rather than moving the ref.
        let dirt = try await git(["status", "--porcelain"])
        XCTAssertEqual(dirt, "")
    }

    /// Uncommitted work in the checkout stops the undo. Discarding it would
    /// make undoing auto pilot cost someone their own edits.
    func testUncommittedWorkInTheCheckoutRefusesTheUndo() async throws {
        let (worktree, _) = try await makeWorkToMerge()
        let developBefore = try await git(["rev-parse", "develop"])

        let runner = ReviewBoardMergeRunner(
            command: { arguments, _ in try await self.gitKit(arguments, in: self.repository) },
            report: { _, _, _ in }
        )
        _ = await runner.process(ReviewBoardMergeRunner.Job(
            queueID: "mrq_1", taskID: "tsk_1", worktreePath: worktree, target: "develop"
        ))

        try "mine".write(
            to: root.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8
        )
        let point = AutoPilotUndoPoint(
            branch: "develop", sha: developBefore, taskID: "tsk_1",
            repositoryPath: repository, recordedAtMS: 1
        )
        let placement = await AutoPilotUndo.placement(of: "develop", in: repository)
        XCTAssertTrue(placement.isDirty)

        let result = await AutoPilotUndo.apply(
            AutoPilotUndo.plan(for: point, placement: placement)
        )
        guard case .failed(let reason) = result else {
            return XCTFail("a dirty checkout must refuse: \(result)")
        }
        XCTAssertTrue(reason.contains("uncommitted"), reason)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("mine.txt").path),
            "the refusal must leave the edits alone"
        )
    }

    /// A worktree that no longer exists is refused before git-kit is asked to
    /// do anything with it.
    func testAWorktreeRemovedBeforeTheMergeIsRefusedNotAttempted() async throws {
        let (worktree, _) = try await makeWorkToMerge()
        let developBefore = try await git(["rev-parse", "develop"])
        try await gitKit(["worktree", "remove", "--force", worktree], in: repository)

        var invocations = 0
        let runner = ReviewBoardMergeRunner(
            command: { arguments, _ in
                invocations += 1
                return try await self.gitKit(arguments, in: self.repository)
            },
            report: { _, _, _ in }
        )
        let outcome = await runner.process(ReviewBoardMergeRunner.Job(
            queueID: "mrq_1", taskID: "tsk_1", worktreePath: worktree, target: "develop"
        ))

        guard case .failed(let reason) = outcome else { return XCTFail("expected a refusal") }
        XCTAssertTrue(reason.contains("gone"), reason)
        XCTAssertEqual(invocations, 0)
        let unchanged = try await git(["rev-parse", "develop"])
        XCTAssertEqual(unchanged, developBefore)
    }
}
