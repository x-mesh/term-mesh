import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Reading a finished turn off the pipe.
///
/// These pin two things that were measured going wrong, and one that could not
/// be measured at all because the agent refused to cooperate — which is exactly
/// why it needs a test rather than another run.
@MainActor
final class AgentPipeCompletionTests: XCTestCase {

    // MARK: - The verdict

    func testReadsTheHeaderTheAgentWrote() {
        let event = AgentPipeCompletion.headerEvent(from: """
            STATUS: BLOCKED
            FILES: none
            VERIFY: n/a
            NEXT: ask the leader
            FULL_REPORT: n/a
            """)
        XCTAssertEqual(event.status, "BLOCKED")
        XCTAssertEqual(event.next, "ask the leader")
    }

    /// Observed live: the agent ended a turn with `STATUS: BLOCKED` alone.
    func testOneHeaderLineIsEnough() {
        XCTAssertEqual(AgentPipeCompletion.headerEvent(from: "STATUS: BLOCKED").status, "BLOCKED")
    }

    /// The failure this exists to prevent.
    ///
    /// Defaulting a missing STATUS to DONE was measured turning
    /// "I could not do this because the file is missing" into a completed
    /// task. The turn did end — the task should not sit open — but nobody said
    /// it worked, and inventing the good verdict is the worst guess available.
    ///
    /// Live reproduction is not possible: told to answer without the protocol,
    /// the agent read the instruction as a prompt injection against its
    /// runbook and called `tm-agent reply` anyway. Correct of it, and the
    /// reason this is pinned here instead.
    func testATurnWithNoVerdictIsNotASuccess() {
        let event = AgentPipeCompletion.headerEvent(
            from: "I could not do this because the file is missing.")
        XCTAssertNotEqual(event.status, "DONE", "a failure must not become a completed task")
        XCTAssertEqual(event.status, "NEEDS_REVIEW")
        XCTAssertTrue(event.body.contains("file is missing"),
                      "what the agent actually said has to survive")
    }

    func testHeaderWinsOverProseAroundIt() {
        let event = AgentPipeCompletion.headerEvent(from: """
            Ran the build and it passed.

            STATUS: DONE
            FILES: Sources/Thing.swift
            VERIFY: xcodebuild -scheme term-mesh build
            NEXT: NONE
            FULL_REPORT: n/a
            """)
        XCTAssertEqual(event.status, "DONE")
        XCTAssertEqual(event.files, "Sources/Thing.swift")
        XCTAssertEqual(event.verify, "xcodebuild -scheme term-mesh build")
    }

    /// First occurrence wins, so a header quoted later in a summary cannot
    /// overwrite the one the agent actually meant.
    func testTheFirstStatusIsTheAnswer() {
        let event = AgentPipeCompletion.headerEvent(from: """
            STATUS: BLOCKED
            NEXT: ask the leader

            (earlier I had written STATUS: DONE by mistake)
            """)
        XCTAssertEqual(event.status, "BLOCKED")
    }

    // MARK: - Which task the answer belongs to

    /// The correlation the scrollback path can never make.
    ///
    /// An answer appearing on a screen has nothing tying it to a request, so
    /// that path guesses: first `in_progress`, else the first non-terminal
    /// task. `blocked` is not in its terminal set, and an unrelated turn was
    /// measured walking up and marking a blocked task completed while leaving
    /// its own task untouched. The capsule names the task, and this side is
    /// the one writing the capsule.
    func testFindsTheTaskTheCapsuleNames() {
        let capsule = """
            ## Task Capsule
            TASK_ID: e82188a0
            PROTOCOL: TM-PROTOCOL-v1
            [GOAL] do the thing [/GOAL]
            """
        XCTAssertEqual(AgentPipeCompletion.taskId(in: capsule), "e82188a0")
    }

    func testPlainInstructionsCarryNoTask() {
        XCTAssertNil(AgentPipeCompletion.taskId(in: "just have a look at the build"))
        XCTAssertNil(AgentPipeCompletion.taskId(in: "TASK_ID:"))
    }

    // MARK: - The wire format

    func testEncodesOneUserTurnPerLine() throws {
        let data = try AgentPipeTransport.encode(text: "line one\nline two")
        XCTAssertEqual(data.last, 0x0A, "stream-json is newline delimited")
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "user")
        let message = try XCTUnwrap(obj["message"] as? [String: Any])
        // Newlines survive: nothing here has a composer that would submit on
        // one, which is why the terminal path flattens instructions and this
        // one does not.
        XCTAssertEqual(message["content"] as? String, "line one\nline two")
    }

    // MARK: - Which task a reply closes

    private func task(_ id: String, _ status: String, minutesAgo: Int) -> TeamOrchestrator.TeamTask {
        TeamOrchestrator.TeamTask(
            id: id, title: id, details: nil, acceptanceCriteria: [], labels: [],
            estimatedSize: nil, assignee: "executor", status: status, priority: 2,
            dependsOn: [], parentTaskId: nil, childTaskIds: [],
            reassignmentCount: 0,
            createdBy: "leader", result: nil,
            createdAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)),
            updatedAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
        )
    }

    /// The one that was measured going wrong.
    ///
    /// A turn parked task A as blocked. An unrelated turn then finished, and
    /// the old rule — first non-terminal in list order, with `blocked` counted
    /// as non-terminal — handed it task A. A was marked completed, its block
    /// reason lost, and B's own task was left untouched.
    func testAReplyDoesNotCompleteSomebodyElsesBlockedTask() {
        let tasks = [task("A", "blocked", minutesAgo: 10),
                     task("B", "assigned", minutesAgo: 1)]
        let picked = AutoReplyEmit.selectTask(from: tasks, preferredTaskId: nil)
        XCTAssertEqual(picked?.id, "B", "the reply belongs to the open task, not the parked one")
    }

    /// Parking is a decision. Only a reply that names the task may undo one.
    func testABlockedTaskCanStillBeClosedWhenNamed() {
        let tasks = [task("A", "blocked", minutesAgo: 10)]
        XCTAssertNil(AutoReplyEmit.selectTask(from: tasks, preferredTaskId: nil))
        XCTAssertEqual(AutoReplyEmit.selectTask(from: tasks, preferredTaskId: "A")?.id, "A")
    }

    func testTheNamedTaskWinsOverEverything() {
        let tasks = [task("A", "in_progress", minutesAgo: 5),
                     task("B", "assigned", minutesAgo: 1)]
        XCTAssertEqual(AutoReplyEmit.selectTask(from: tasks, preferredTaskId: "B")?.id, "B")
    }

    /// Without a name, a reply is likelier to answer the instruction just
    /// given than the oldest one still open.
    func testTheMostRecentOpenTaskIsTheBetterGuess() {
        let tasks = [task("old", "assigned", minutesAgo: 30),
                     task("new", "assigned", minutesAgo: 1)]
        XCTAssertEqual(AutoReplyEmit.selectTask(from: tasks, preferredTaskId: nil)?.id, "new")
    }

    func testRunningWorkBeatsMerelyAssignedWork() {
        let tasks = [task("assigned-newer", "assigned", minutesAgo: 1),
                     task("running", "in_progress", minutesAgo: 20)]
        XCTAssertEqual(AutoReplyEmit.selectTask(from: tasks, preferredTaskId: nil)?.id, "running")
    }

    func testFinishedWorkIsNeverReopened() {
        let tasks = [task("done", "completed", minutesAgo: 1),
                     task("gone", "abandoned", minutesAgo: 2)]
        XCTAssertNil(AutoReplyEmit.selectTask(from: tasks, preferredTaskId: nil))
    }

    /// `exec` takes only the first word, and the caller prefixes the launch
    /// line with it when the agent works in a worktree. Handing back a bare
    /// `rm -f … && …` chain replaced the pane's shell with `rm`, which did its
    /// one job and left — the pane closed half a second after opening.
    func testLaunchesAsOneCommandSoExecCannotSwallowIt() {
        let cmd = AgentPipeTransport.launchCommand(
            claudePath: "/usr/local/bin/claude",
            fifoPath: "/tmp/pipes/executor@team.stdin",
            model: "sonnet",
            instructions: "",
            extraArgs: []
        )
        XCTAssertFalse(cmd.hasPrefix("rm "),
                       "`exec` would consume only this and drop the rest")
        XCTAssertTrue(cmd.contains(" -c "), "the chain travels as one command's argument")
        XCTAssertTrue(cmd.contains("mkfifo"))
        XCTAssertTrue(cmd.contains("--input-format stream-json"))
        XCTAssertTrue(cmd.contains("--replay-user-messages"),
                      "the receipt is what makes delivery verifiable")
    }
}
