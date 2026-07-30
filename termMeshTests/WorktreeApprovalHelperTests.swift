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
