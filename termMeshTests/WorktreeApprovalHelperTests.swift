import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// `WorktreeApprovalHelper.runToCompletion` backs the `git-kit wt finish`
/// call behind Mission Control's Approve button (and `whichGitKit`'s PATH
/// lookup). It used to call `waitUntilExit()` before reading either pipe —
/// once a child writes more than one kernel pipe buffer (commonly 64KB)
/// before exiting, it blocks in `write()` while the parent blocks in
/// `waitUntilExit()`, and neither side ever moves again.
final class WorktreeApprovalHelperTests: XCTestCase {

    /// `head -c 200000` writes well past a 64KB pipe buffer before `sh`
    /// (the process this test actually spawns) exits. The old
    /// wait-then-read implementation deadlocks on this and would hang the
    /// test until CI's own timeout killed it; concurrent draining returns
    /// promptly with every byte intact.
    func testDrainsOutputLargerThanAPipeBuffer() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "yes | head -c 200000"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let began = Date()
        let (out, _) = WorktreeApprovalHelper.runToCompletion(
            process, stdout: stdoutPipe, stderr: stderrPipe
        )
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertEqual(out.count, 200_000,
                       "every byte must be drained, not just the first pipe buffer's worth")
        XCTAssertLessThan(elapsed, 5,
                          "draining concurrently with execution must not wait on a full pipe")
    }
}

/// Worktree reclamation has to go through the repository that registered the
/// worktree — deleting the directory alone leaves git holding a `prunable`
/// entry. All the caller has is the worktree path, so resolving its owner is
/// the step everything else depends on.
final class WorktreeOwnerResolutionTests: XCTestCase {

    private func makeWorktree(gitdir: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wt-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "gitdir: \(gitdir)\n".write(
            to: dir.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        return dir
    }

    func testResolvesTheRepositoryThreeLevelsAboveTheLinkedGitdir() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("owner-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let gitdir = repo.appendingPathComponent(".git/worktrees/term-mesh_wt_0011aabb").path
        let worktree = try makeWorktree(gitdir: gitdir)
        defer { try? FileManager.default.removeItem(at: worktree) }

        XCTAssertEqual(
            TermMeshDaemon.primaryRepoPath(ofWorktreeAt: worktree),
            repo.path
        )
    }

    /// The leaked worktrees on a developer's machine point at temp
    /// directories that were cleaned up long ago. Reporting a repository that
    /// is not there would send the caller off to open a path that cannot
    /// exist, so this has to come back nil.
    func testReturnsNilWhenTheOwningRepositoryIsGone() throws {
        let worktree = try makeWorktree(
            gitdir: "/nonexistent/repo/.git/worktrees/term-mesh_wt_deadbeef"
        )
        defer { try? FileManager.default.removeItem(at: worktree) }

        XCTAssertNil(TermMeshDaemon.primaryRepoPath(ofWorktreeAt: worktree))
    }

    /// A primary checkout has a `.git` directory, not a pointer file. It owns
    /// nothing and must never be treated as a reclaimable worktree.
    func testReturnsNilForAPrimaryCheckout() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("primary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        XCTAssertNil(TermMeshDaemon.primaryRepoPath(ofWorktreeAt: repo))
    }
}
