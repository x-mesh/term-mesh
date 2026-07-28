import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class AutoPilotUndoTests: XCTestCase {
    private let point = AutoPilotUndoPoint(
        branch: "develop",
        sha: "deadbeef1234",
        taskID: "tsk_1",
        repositoryPath: "/repo",
        recordedAtMS: 1
    )

    // MARK: - Choosing how to put it back

    /// Nothing has the branch: moving the ref is safe and leaves no working
    /// tree disagreeing with HEAD.
    func testABranchNobodyHasCheckedOutIsMovedByRef() {
        let plan = AutoPilotUndo.plan(for: point, placement: .notCheckedOut)
        XCTAssertEqual(
            plan,
            .updateRef(repository: "/repo", branch: "develop", sha: "deadbeef1234")
        )
        XCTAssertEqual(
            plan.displayCommand,
            "git -C '/repo' update-ref refs/heads/develop deadbeef1234"
        )
    }

    /// The case the whole type exists for. Moving the ref here would leave HEAD
    /// at one commit and the index at another, and git would report the entire
    /// merge as staged deletions — an undo that makes things worse.
    func testACheckedOutBranchIsResetInItsOwnWorktree() {
        let plan = AutoPilotUndo.plan(
            for: point,
            placement: .init(checkedOutAt: "/work/develop", isDirty: false)
        )
        XCTAssertEqual(plan, .resetWorktree(path: "/work/develop", sha: "deadbeef1234"))
        XCTAssertEqual(
            plan.displayCommand,
            "git -C '/work/develop' reset --hard deadbeef1234"
        )
    }

    /// Undoing auto pilot must never cost someone their own edits.
    func testUncommittedWorkStopsTheUndoInsteadOfBeingDiscarded() {
        let plan = AutoPilotUndo.plan(
            for: point,
            placement: .init(checkedOutAt: "/work/develop", isDirty: true)
        )
        guard case .refuse(let reason) = plan else { return XCTFail("expected a refusal") }
        XCTAssertTrue(reason.contains("/work/develop"), reason)
        XCTAssertTrue(reason.contains("uncommitted"), reason)
        XCTAssertNil(plan.displayCommand, "nothing is offered to run")
    }

    func testAnUndoPointWithNoCommitIsRefused() {
        let empty = AutoPilotUndoPoint(
            branch: "develop", sha: "", taskID: "t", repositoryPath: "/repo", recordedAtMS: 1
        )
        guard case .refuse(let reason) = AutoPilotUndo.plan(for: empty, placement: .notCheckedOut)
        else { return XCTFail("expected a refusal") }
        XCTAssertTrue(reason.contains("nowhere to go back to"), reason)
    }

    // MARK: - Reading where the branch lives

    /// Parsed as stanzas, not grepped: a path containing "branch" must not be
    /// mistaken for a branch line.
    func testTheCheckoutIsFoundByStanzaNotBySubstring() {
        let porcelain = """
        worktree /repo
        HEAD aaaa
        branch refs/heads/main

        worktree /work/branch refs/heads/develop
        HEAD bbbb
        detached

        worktree /work/dev
        HEAD cccc
        branch refs/heads/develop
        """
        XCTAssertEqual(
            AutoPilotUndo.checkoutPath(of: "develop", inPorcelain: porcelain),
            "/work/dev"
        )
        XCTAssertEqual(AutoPilotUndo.checkoutPath(of: "main", inPorcelain: porcelain), "/repo")
        XCTAssertNil(AutoPilotUndo.checkoutPath(of: "nothing", inPorcelain: porcelain))
    }

    func testABranchNamePrefixDoesNotMatchALongerBranch() {
        let porcelain = """
        worktree /work/dev
        HEAD cccc
        branch refs/heads/develop-2
        """
        XCTAssertNil(AutoPilotUndo.checkoutPath(of: "develop", inPorcelain: porcelain))
    }

    func testPlacementReadsDirtinessFromTheCheckoutItFound() async {
        var seen: [[String]] = []
        let placement = await AutoPilotUndo.placement(of: "develop", in: "/repo") { arguments in
            seen.append(arguments)
            if arguments.contains("worktree") {
                return ProcessRun.Output(
                    status: 0,
                    stdout: Data("worktree /work/dev\nbranch refs/heads/develop\n".utf8),
                    stderr: Data(), timedOut: false
                )
            }
            return ProcessRun.Output(
                status: 0, stdout: Data(" M a.swift\n".utf8), stderr: Data(), timedOut: false
            )
        }
        XCTAssertEqual(placement, .init(checkedOutAt: "/work/dev", isDirty: true))
        // Dirtiness is asked of the worktree that has the branch, not the
        // repository the merge was recorded against.
        XCTAssertEqual(
            seen.last,
            ["-C", "/work/dev", "status", "--porcelain", "--untracked-files=no"],
            "untracked files cannot be destroyed by reset --hard, so they must not block an undo"
        )
    }

    /// A git that cannot answer must not be read as "not checked out" and then
    /// have its ref moved — so the listing failing means no checkout is
    /// claimed, and the caller still runs update-ref. That is the one place
    /// this degrades, and it degrades to what git itself would refuse loudly.
    func testAFailedListingDoesNotInventACheckout() async {
        let placement = await AutoPilotUndo.placement(of: "develop", in: "/repo") { _ in
            ProcessRun.Output(status: 128, stdout: Data(), stderr: Data(), timedOut: false)
        }
        XCTAssertEqual(placement, .notCheckedOut)
    }

    // MARK: - Applying

    func testApplyingRunsTheChosenCommandAndReportsWhereItLanded() async {
        var ran: [String] = []
        let result = await AutoPilotUndo.apply(
            .resetWorktree(path: "/work/dev", sha: "deadbeef1234")
        ) { arguments in
            ran = arguments
            return ProcessRun.Output(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
        }
        XCTAssertEqual(ran, ["-C", "/work/dev", "reset", "--hard", "deadbeef1234"])
        XCTAssertEqual(result, .done("/work/dev is back at deadbeef."))
    }

    func testAFailureCarriesGitsOwnWords() async {
        let result = await AutoPilotUndo.apply(
            .updateRef(repository: "/repo", branch: "develop", sha: "abc")
        ) { _ in
            ProcessRun.Output(
                status: 1, stdout: Data(),
                stderr: Data("fatal: update_ref failed for ref 'refs/heads/develop'".utf8),
                timedOut: false
            )
        }
        XCTAssertEqual(
            result,
            .failed("fatal: update_ref failed for ref 'refs/heads/develop'")
        )
    }

    func testARefusalNeverRunsGit() async {
        let result = await AutoPilotUndo.apply(.refuse("nope")) { _ in
            XCTFail("must not run git for a refusal")
            return nil
        }
        XCTAssertEqual(result, .failed("nope"))
    }
}
