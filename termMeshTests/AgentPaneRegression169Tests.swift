import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The 0.168 review's findings, pinned so they cannot come back.
///
/// Three of them share a shape: something the app reads was written by a model,
/// a bridge or a previous process, and the reader trusted it — a hunk header
/// trusted to have numbers in it, an events file trusted to belong to the pane
/// watching it, an exit trusted to be followed by EOF. The fourth is the same
/// mistake in the other direction: a deliberate stop trusted to need no ending.
@MainActor
final class AgentPaneRegression169Tests: XCTestCase {

    // MARK: - A damaged hunk header

    /// The crash. `Int(part.dropFirst().split(separator: ",")[0])` indexed an
    /// array that is empty whenever the marker has nothing after it, and the
    /// string it was reading came from a subprocess: codex hands its own patch
    /// text through the bridge verbatim, so a header damaged to `@@ - @@` took
    /// the whole app down.
    func testADamagedHunkHeaderIsSkippedRatherThanCrashing() {
        for header in ["@@ - @@", "@@ -, +, @@", "@@ - +1,1 @@", "@@ -1,1 + @@",
                       "@@ -+ @@", "@@ @@", "@@"] {
            let patch = header + "\n-before\n+after\n"
            XCTAssertNil(
                AgentDiff.change(tool: "edit", input: ["file_path": "/repo/a.swift",
                                                       "unified_diff": patch]),
                "\(header) names no position, so it opens no hunk"
            )
        }
    }

    /// A header that parses is still read the way it always was — the fix must
    /// not turn "unreadable" into "everything is unreadable".
    func testAHeaderWithoutCountsStillCarriesItsLineNumbers() throws {
        let change = try XCTUnwrap(AgentDiff.change(tool: "edit", input: [
            "file_path": "/repo/a.swift",
            "unified_diff": "@@ -12 +12 @@\n-old\n+new\n"]))

        guard case .removed(let old, _) = try XCTUnwrap(change.lines.first) else {
            return XCTFail("expected the hunk to open on a removal")
        }
        XCTAssertEqual(old, 12)
    }

    /// The degrade has to be local. Carrying the previous hunk's cursors into a
    /// hunk whose own header could not be read would number those lines wrongly
    /// — a diff that is quietly in the wrong place is worse than one that is
    /// missing, because nothing about it looks wrong.
    func testADamagedSecondHunkIsDroppedAndTheFirstIsKept() throws {
        let patch = """
        @@ -10,2 +10,2 @@
        -one
        +ONE
        @@ -, +, @@
        -two
        +TWO
        """

        let change = try XCTUnwrap(AgentDiff.change(tool: "edit", input: [
            "file_path": "/repo/a.swift", "unified_diff": patch]))

        XCTAssertEqual(change.added, 1, "only the hunk that said where it was")
        XCTAssertEqual(change.removed, 1)
        for line in change.lines {
            if case .added(let new, let text) = line {
                XCTAssertEqual(text, "ONE")
                XCTAssertEqual(new, 10)
            }
        }
    }

    // MARK: - What is diffed before it is capped

    /// `maxLines` bounds what is shown and is applied after the walk, so two
    /// large sides that mostly differ were compared in full — O(N·D), on the
    /// main actor, inside the stream reader.
    func testAnOversizedEditIsReportedWithoutWalkingIt() throws {
        let old = (0..<4_000).map { "old \($0)" }.joined(separator: "\n") + "\n"
        let new = (0..<4_000).map { "new \($0)" }.joined(separator: "\n") + "\n"

        let change = try XCTUnwrap(AgentDiff.change(tool: "Edit", input: [
            "file_path": "/repo/big.swift", "old_string": old, "new_string": new]))

        XCTAssertTrue(change.lines.isEmpty, "nothing was walked, so nothing is shown")
        XCTAssertEqual(change.added, 4_000)
        XCTAssertEqual(change.removed, 4_000)
        XCTAssertEqual(change.elided, 8_000, "the row still says how much it is not showing")
    }

    /// The budget belongs to the call: fifty edits of a hundred lines cost what
    /// one edit of five thousand does.
    func testAnOversizedMultiEditIsReportedWithoutWalkingIt() throws {
        let block = (0..<200).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let edits: [[String: Any]] = (0..<20).map { index in
            ["old_string": block, "new_string": block + "extra \(index)\n"]
        }

        let change = try XCTUnwrap(AgentDiff.change(tool: "MultiEdit", input: [
            "file_path": "/repo/big.swift", "edits": edits]))

        XCTAssertTrue(change.lines.isEmpty)
        XCTAssertGreaterThan(change.elided, AgentDiff.maxDiffInputLines)
    }

    /// An ordinary edit is still diffed line by line, and the cap must not have
    /// moved the line at which that stops being true.
    func testAnOrdinaryEditIsStillWalked() throws {
        let change = try XCTUnwrap(AgentDiff.change(tool: "Edit", input: [
            "file_path": "/repo/a.swift",
            "old_string": "a\nb\nc\n", "new_string": "a\nB\nc\n"]))

        XCTAssertEqual(change.added, 1)
        XCTAssertEqual(change.removed, 1)
        XCTAssertFalse(change.lines.isEmpty)
    }

    /// One side empty is the whole answer already, and a `Write` is the case
    /// where the other side is a whole file. It keeps its exact per-line
    /// counts — the shortcut is about what it costs to say so, not about
    /// saying less.
    func testAWholeFileIsStillCountedAndNumberedLineByLine() throws {
        let content = (0..<5_000).map { "line \($0)" }.joined(separator: "\n") + "\n"

        let change = try XCTUnwrap(AgentDiff.change(
            tool: "Write", input: ["file_path": "/repo/new.txt", "content": content]))

        XCTAssertEqual(change.added, 5_000)
        XCTAssertEqual(change.removed, 0)
        XCTAssertEqual(change.lines.count + change.elided, 5_000)
        guard case .added(_, let first) = try XCTUnwrap(change.lines.first) else {
            return XCTFail("a write is all addition")
        }
        XCTAssertEqual(first, "line 0")
    }

    // MARK: - Stopping a session

    /// A deliberate stop is still the end of the turn it interrupted. Closing
    /// an agent pane mid-turn left its task `in_progress` for a pane that no
    /// longer existed, and `tm-agent wait` waiting on it forever — the exact
    /// thing `finishAfterDrain` was written for, on the one path that did not
    /// call it.
    func testStoppingASessionEndsTheTurnItWasHolding() {
        var reported: [(text: String, task: String?, stop: String)] = []
        let session = AgentSession()
        session.onTurnEnd = { text, end, task in
            reported.append((text: text, task: task, stop: end.stop))
        }
        session.start(.init(
            executable: "/bin/sleep", arguments: ["30"],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))
        XCTAssertTrue(session.isRunning)
        session.openTurnForTesting(from: .leader, taskId: "69f02ac3")

        session.stop()

        XCTAssertEqual(reported.count, 1, "the interrupted turn is closed exactly once")
        XCTAssertEqual(reported.first?.task, "69f02ac3")
        XCTAssertEqual(reported.first?.stop, "session_stopped")
        // Nobody said the work succeeded, so it must not read as one.
        XCTAssertEqual(
            AgentPipeCompletion.headerEvent(from: reported.first?.text ?? "").status,
            "NEEDS_REVIEW")
        XCTAssertFalse(session.isThinking)
        XCTAssertFalse(session.isRunning)

        session.stop()
        XCTAssertEqual(reported.count, 1, "a second stop has no turn left to end")
    }

    /// And a stop with nothing running invents nothing: a pane closed between
    /// turns has no task to report on.
    func testStoppingBetweenTurnsReportsNothing() {
        var ends = 0
        let session = AgentSession()
        session.onTurnEnd = { _, _, _ in ends += 1 }
        session.start(.init(
            executable: "/bin/sleep", arguments: ["30"],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))

        session.stop()

        XCTAssertEqual(ends, 0)
        XCTAssertFalse(session.isRunning)
    }

    /// The grace that ends a wait for an EOF that may never come must not end
    /// one that arrives normally: a process that exits cleanly still finishes
    /// exactly once, and the fallback that fires later finds the work done.
    func testANormalExitStillFinishesExactlyOnceUnderTheDrainGrace() async {
        var ends: [String?] = []
        let session = AgentSession()
        session.onTurnEnd = { _, _, task in ends.append(task) }
        session.openTurnForTesting(from: .leader, taskId: "grace-once")
        session.start(.init(
            executable: "/bin/echo", arguments: ["done"],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))

        // Past the fallback's deadline, so both it and the real EOF have run.
        try? await Task.sleep(nanoseconds: UInt64((AgentSession.drainGrace + 1) * 1_000_000_000))

        XCTAssertEqual(ends, ["grace-once"])
        XCTAssertFalse(session.isRunning)
    }

    /// A descendant holding the write end of stdout means EOF never arrives.
    /// Waiting for it unconditionally left the turn open forever: the task sat
    /// `in_progress`, the pane said "working", and every instruction behind it
    /// queued against a turn that could not end.
    func testAnInheritedStdoutWriterCannotHoldTheTurnOpenForever() async {
        var ends: [String?] = []
        let session = AgentSession()
        session.onTurnEnd = { _, _, task in ends.append(task) }
        session.openTurnForTesting(from: .leader, taskId: "held-open")
        session.start(.init(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' HUP; sleep 30 & exec /usr/bin/true"],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))

        try? await Task.sleep(nanoseconds: UInt64((AgentSession.drainGrace + 2) * 1_000_000_000))

        XCTAssertEqual(ends, ["held-open"], "the grace ended the turn the exit could not")
        XCTAssertFalse(session.isRunning)
        session.stop()
    }

    // MARK: - A watch that outlived its pane

    /// A hard restart reuses the agent's transport id, so the events file the
    /// dead pane left is the file the new watch opens — and it opens it at byte
    /// 0. Every finished turn in it replayed, each `result` arriving with no
    /// task to answer, and `AutoReplyEmit` then guessed the newest open one.
    func testAReplayedResultDoesNotCloseATaskItNeverAnswered() throws {
        let team = "replay-test-\(UUID().uuidString)"
        let agentId = "executor@\(team)"
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [.init(name: "executor", instanceId: nil)])
        defer {
            AgentPipeCompletion.shared.forget(agentId: agentId)
            store.clearResults(teamName: team)
            store.unregisterTeam(team)
        }

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "still being worked on", assignee: "executor"))

        AgentPipeTransport.prepareDirectory()
        AgentPipeCompletion.shared.watch(agentId: agentId, teamName: team,
                                         agentName: "executor")
        // What the dead pane had already written, arriving with no expectation
        // against it.
        try Self.write(finishedTurn(status: "DONE"),
                       to: AgentPipeCompletion.eventsPath(agentId: agentId))
        AgentPipeCompletion.shared.tickForTesting()

        let after = try XCTUnwrap(store.getTask(teamName: team, taskId: task.id))
        XCTAssertEqual(after.status, task.status,
                       "a turn that answers no task must not close one")
        XCTAssertEqual(store.collectResults(teamName: team).count, 0)
    }

    /// The file belongs to the process that writes it, so a new watch starts it
    /// empty rather than inheriting a transcript it cannot attribute.
    func testWatchingAgainDropsTheEventsFileTheDeadPaneLeft() throws {
        let agentId = "executor@stale-file-test"
        defer { AgentPipeCompletion.shared.forget(agentId: agentId) }

        AgentPipeTransport.prepareDirectory()
        let path = AgentPipeCompletion.eventsPath(agentId: agentId)
        try Self.write(finishedTurn(status: "DONE"), to: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        AgentPipeCompletion.shared.watch(agentId: agentId, teamName: "stale-file-test",
                                         agentName: "executor")

        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "the previous pane's turns are not this pane's to replay")
    }

    /// `tee` truncates this file at launch and the bridge appends to whatever
    /// is there, so an offset carried over from a previous process sits past
    /// the new end. Seeking past EOF is legal and reads nothing — the watch
    /// went permanently deaf, and every real completion after it was missed.
    func testATruncatedEventsFileIsReadFromItsStartAgain() throws {
        let team = "truncation-test-\(UUID().uuidString)"
        let agentId = "executor@\(team)"
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [.init(name: "executor", instanceId: nil)])
        defer {
            AgentPipeCompletion.shared.forget(agentId: agentId)
            store.clearResults(teamName: team)
            store.unregisterTeam(team)
        }

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "the real work", assignee: "executor"))

        AgentPipeTransport.prepareDirectory()
        AgentPipeCompletion.shared.watch(agentId: agentId, teamName: team,
                                         agentName: "executor")
        let path = AgentPipeCompletion.eventsPath(agentId: agentId)

        // A session's worth of chatter, read and left behind as an offset.
        let chatter = (0..<80).map { _ in #"{"type":"system","subtype":"hook"}"# }
            .joined(separator: "\n") + "\n"
        try Self.write(chatter, to: path)
        AgentPipeCompletion.shared.tickForTesting()
        let carried = try XCTUnwrap(AgentPipeCompletion.shared.offsetForTesting(agentId: agentId))
        XCTAssertGreaterThan(carried, 0)

        // The pane restarts: the file is replaced by a much shorter one, and
        // this turn is the one the leader is waiting on.
        AgentPipeCompletion.shared.expect(agentId: agentId,
                                          instruction: "TASK_ID: \(task.id)\ndo the thing")
        try Self.write(finishedTurn(status: "BLOCKED"), to: path)
        let replaced = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        XCTAssertLessThan(replaced, Int(carried),
                          "the replacement has to be shorter for this to be the bug")

        AgentPipeCompletion.shared.tickForTesting()

        let after = try XCTUnwrap(store.getTask(teamName: team, taskId: task.id))
        XCTAssertEqual(after.status, "blocked", "the turn after a restart still lands")
        XCTAssertNil(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId))
    }

    // MARK: -

    private func finishedTurn(status: String) -> String {
        let final = """
        STATUS: \(status)
        FILES: none
        VERIFY: n/a
        NEXT: NONE
        FULL_REPORT: n/a
        """
        let frame: [String: Any] = ["type": "result", "stop_reason": "end_turn",
                                    "result": final]
        let data = try? JSONSerialization.data(withJSONObject: frame)
        return (data.flatMap { String(data: $0, encoding: .utf8) } ?? "") + "\n"
    }

    /// In place rather than atomically, the way `tee` and the bridge write it:
    /// the point of the truncation case is a file that got smaller, not a file
    /// that got replaced.
    private static func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }
}
