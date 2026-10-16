import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Three ways a turn stopped being answerable, each found by reading the
/// v0.170 diff rather than by a run that failed.
///
/// They share a shape worth naming: every one of them is a guard that looks
/// correct in isolation and is wrong about who else reaches it. A length check
/// in the wrong unit, an expectation cleared by a caller nobody pictured, and a
/// cleanup racing the process it was cleaning up after.
@MainActor
final class PipeCompletionP1Regression170Tests: XCTestCase {

    // MARK: - Reading ids off the socket

    /// The crash.
    ///
    /// `decodeFixedHex` counted UTF-8 bytes and walked graphemes. Any non-ASCII
    /// byte makes those two disagree, and `String.index(_:offsetBy:)` traps
    /// past `endIndex` rather than returning nil like every other rejection in
    /// this function. `peer.leader.call` hands socket input straight to it, so
    /// the trap was reachable by anyone who could open the socket — which,
    /// under `reload.sh --allow-all`, is every process on the machine.
    ///
    /// 62 ASCII digits plus one `é` is 64 UTF-8 bytes and 63 characters, and
    /// the 31 pairs before the last one all parse. The 32nd read runs off the
    /// end. If this test hangs or aborts rather than failing, the trap is back.
    func testNonASCIIOfTheRightByteLengthIsRejectedRatherThanFatal() {
        let poisoned = String(repeating: "0", count: 62) + "é"
        XCTAssertEqual(poisoned.utf8.count, 64, "the length guard must be satisfied")
        XCTAssertLessThan(poisoned.count, 64, "…while the grapheme walk runs short")

        XCTAssertNil(TerminalController.decodeFixedHex(poisoned, byteCount: 32))
    }

    /// The same disagreement from the other side: a combining mark makes one
    /// `Character` out of several UTF-8 units, so the walk overruns by more
    /// than one.
    func testCombiningMarksAreRejectedRatherThanFatal() {
        let poisoned = String(repeating: "0", count: 61) + "0\u{0301}"  // 0 + combining acute
        XCTAssertEqual(poisoned.utf8.count, 64)
        XCTAssertNil(TerminalController.decodeFixedHex(poisoned, byteCount: 32))
    }

    func testWellFormedHexStillDecodesBothCases() throws {
        let decoded = try XCTUnwrap(TerminalController.decodeFixedHex("00FfaB10", byteCount: 4))
        XCTAssertEqual(Array(decoded), [0x00, 0xFF, 0xAB, 0x10])
    }

    func testWrongLengthAndNonHexAreStillRejected() {
        XCTAssertNil(TerminalController.decodeFixedHex(nil, byteCount: 4))
        XCTAssertNil(TerminalController.decodeFixedHex("00ff", byteCount: 4), "too short")
        XCTAssertNil(TerminalController.decodeFixedHex("00ffaB1000", byteCount: 4), "too long")
        XCTAssertNil(TerminalController.decodeFixedHex("00ffaBzz", byteCount: 4), "not hex")
        XCTAssertNil(TerminalController.decodeFixedHex("00ffaB1 ", byteCount: 4), "space is not hex")
    }

    // MARK: - Which task a turn is answering

    /// The dropped completion.
    ///
    /// `expect` reads as a delegate-only entry point and is not one: every
    /// delivery calls it, so `send` and `broadcast` arrive here too carrying no
    /// `TASK_ID`. Writing their nil over a delegate's pending id erased the one
    /// thing `consume` will now accept, so the delegated turn's result was
    /// dropped and its task sat `in_progress` until a leader's `wait` timed
    /// out. A turn with no task to answer says nothing about the turn already
    /// waiting for one.
    func testABroadcastDoesNotErasePendingDelegateWork() {
        let agentId = "expect-\(UUID().uuidString)"
        AgentPipeCompletion.shared.watch(
            agentId: agentId, teamName: "t", agentName: "executor", agentInstanceId: "i1")
        defer { AgentPipeCompletion.shared.forget(agentId: agentId) }

        AgentPipeCompletion.shared.expect(
            agentId: agentId, instruction: "TM-PROTOCOL-v1\nTASK_ID: T1\ndo the thing")
        XCTAssertEqual(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId), "T1")

        AgentPipeCompletion.shared.expect(agentId: agentId, instruction: "진행 상황 알려줘")
        XCTAssertEqual(
            AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId), "T1",
            "a broadcast has no task of its own; it does not cancel one already in flight")
    }

    /// The expectation still moves when a real one arrives — the fix must not
    /// pin the first task forever.
    func testANewCapsuleTakesOverTheExpectation() {
        let agentId = "expect-\(UUID().uuidString)"
        AgentPipeCompletion.shared.watch(
            agentId: agentId, teamName: "t", agentName: "executor")
        defer { AgentPipeCompletion.shared.forget(agentId: agentId) }

        AgentPipeCompletion.shared.expect(agentId: agentId, instruction: "TASK_ID: T1")
        AgentPipeCompletion.shared.expect(agentId: agentId, instruction: "TASK_ID: T2")
        XCTAssertEqual(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId), "T2")
    }

    private struct WatchedPipeTask {
        let team: String
        let taskId: String
        let agentId: String
        let path: String
    }

    private func watchedPipeTask(_ label: String) throws -> WatchedPipeTask {
        let team = "\(label)-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [.init(name: "executor", instanceId: nil)])
        addTeardownBlock {
            TeamDataStore.shared.clearResults(teamName: team)
            TeamDataStore.shared.unregisterTeam(team)
        }
        let task = try XCTUnwrap(store.createTask(teamName: team, title: "long job", assignee: "executor"))
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: task.id, status: "in_progress"))

        let agentId = "\(label)-\(UUID().uuidString)"
        let path = AgentPipeCompletion.eventsPath(agentId: agentId)
        AgentPipeTransport.prepareDirectory()
        try Data().write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        AgentPipeCompletion.shared.watch(agentId: agentId, teamName: team, agentName: "executor")
        addTeardownBlock { @MainActor in AgentPipeCompletion.shared.forget(agentId: agentId) }
        AgentPipeCompletion.shared.expect(agentId: agentId, instruction: "TASK_ID: \(task.id)\ngo")
        return WatchedPipeTask(team: team, taskId: task.id, agentId: agentId, path: path)
    }

    private func appendResult(_ text: String, to watched: WatchedPipeTask) throws {
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "result", "stop_reason": "end_turn", "result": text,
        ]) + Data("\n".utf8)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: watched.path))
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()
        AgentPipeCompletion.shared.tickForTesting()
    }

    private func reports(_ watched: WatchedPipeTask) -> Int {
        TeamDataStore.shared.getMessages(teamName: watched.team, type: "report").count
    }

    private func storedResult(_ watched: WatchedPipeTask) -> String? {
        TeamDataStore.shared.readResult(
            teamName: watched.team, taskId: watched.taskId, agentName: "executor")?["content"] as? String
    }

    /// A verdict-less result still settles a pipe task as review_ready, but it
    /// is not the agent's last word: the expectation stays so a later explicit
    /// STATUS closes the same task instead of being dropped as untracked.
    func testAVerdictlessResultKeepsTheExpectationForTheExplicitOne() throws {
        let watched = try watchedPipeTask("pipe-verdictless")
        let store = TeamDataStore.shared

        try appendResult("Started the build in the background; it will take a while.", to: watched)
        XCTAssertEqual(store.getTask(teamName: watched.team, taskId: watched.taskId)?.status, "review_ready")
        XCTAssertEqual(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: watched.agentId), watched.taskId)

        try appendResult("STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a", to: watched)
        XCTAssertEqual(store.getTask(teamName: watched.team, taskId: watched.taskId)?.status, "completed")
        XCTAssertNil(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: watched.agentId))
    }

    /// Keeping the expectation must not turn every later verdict-less turn
    /// into another filing of the same default over the first one.
    func testARepeatedVerdictlessResultDoesNotRefileTheDefault() throws {
        let watched = try watchedPipeTask("pipe-refile")
        let store = TeamDataStore.shared

        try appendResult("Started the build in the background.", to: watched)
        XCTAssertEqual(reports(watched), 1)
        let firstResult = try XCTUnwrap(storedResult(watched))

        try appendResult("Still waiting on the build.", to: watched)
        XCTAssertEqual(reports(watched), 1, "no second report for no new verdict")
        XCTAssertEqual(storedResult(watched), firstResult, "the filed result is not overwritten")
        XCTAssertEqual(store.getTask(teamName: watched.team, taskId: watched.taskId)?.status, "review_ready")

        try appendResult("STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a", to: watched)
        XCTAssertEqual(store.getTask(teamName: watched.team, taskId: watched.taskId)?.status, "completed")
        XCTAssertEqual(reports(watched), 2)
    }

    /// A NEEDS_REVIEW the agent actually wrote is a verdict, even against a
    /// task the default already left review_ready.
    func testAnExplicitNeedsReviewIsStillFiled() throws {
        let watched = try watchedPipeTask("pipe-explicit-review")

        try appendResult("Started the build in the background.", to: watched)
        try appendResult("STATUS: NEEDS_REVIEW\nFILES: a.swift\nVERIFY: n/a\nNEXT: review\nFULL_REPORT: n/a", to: watched)

        XCTAssertEqual(reports(watched), 2)
        XCTAssertTrue(storedResult(watched)?.contains("FILES: a.swift") == true)
        XCTAssertNil(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: watched.agentId))
    }

    func testAnUnwatchedAgentIsStillIgnored() {
        let agentId = "expect-unwatched-\(UUID().uuidString)"
        AgentPipeCompletion.shared.expect(agentId: agentId, instruction: "TASK_ID: T1")
        XCTAssertNil(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId))
    }

    // MARK: - Which bytes belong to this process

    /// The unlink race.
    ///
    /// `watch` is called *after* the pane's shell is launched, and the tail of
    /// that command is `| tee <fifo>.events`. Deleting the file to stop a
    /// restart replaying it could therefore unlink the inode tee had already
    /// opened: tee keeps writing to a file with no name, every later
    /// `FileHandle(forReadingAtPath:)` returns nil, and the agent's completions
    /// are lost for the life of the pane. Seeding the offset to the current end
    /// skips the same stale bytes and touches nothing the writer holds.
    func testWatchLeavesTheEventsFileAloneAndStartsAfterWhatIsInIt() throws {
        let agentId = "watch-\(UUID().uuidString)"
        let path = AgentPipeCompletion.eventsPath(agentId: agentId)
        AgentPipeTransport.prepareDirectory()

        let stale = #"{"type":"result","result":"STATUS: DONE","stop_reason":"end_turn"}"# + "\n"
        try Data(stale.utf8).write(to: URL(fileURLWithPath: path))
        let openedByTee = try XCTUnwrap(
            FileHandle(forWritingAtPath: path), "stand in for the tee that already opened it")
        defer {
            try? openedByTee.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        AgentPipeCompletion.shared.watch(agentId: agentId, teamName: "t", agentName: "executor")
        defer { AgentPipeCompletion.shared.forget(agentId: agentId) }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "the writer's file must survive the watch that reads it")
        XCTAssertEqual(
            AgentPipeCompletion.shared.offsetForTesting(agentId: agentId),
            UInt64(stale.utf8.count),
            "a previous process's turns are skipped by starting past them, not by deleting them")
    }

    /// The offset seeded above belongs to the file that existed at the time.
    /// When tee replaces it, that mark is meaningless — and if the replacement
    /// grows past it before the first tick, size alone cannot say so. Identity
    /// can, so the watch restarts from the top of the new file.
    func testAReplacedEventsFileIsReadFromItsBeginning() throws {
        let agentId = "watch-\(UUID().uuidString)"
        let path = AgentPipeCompletion.eventsPath(agentId: agentId)
        AgentPipeTransport.prepareDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let stale = String(repeating: "x", count: 200) + "\n"
        try Data(stale.utf8).write(to: URL(fileURLWithPath: path))

        AgentPipeCompletion.shared.watch(agentId: agentId, teamName: "t", agentName: "executor")
        defer { AgentPipeCompletion.shared.forget(agentId: agentId) }
        XCTAssertEqual(
            AgentPipeCompletion.shared.offsetForTesting(agentId: agentId), UInt64(stale.utf8.count))

        // A new inode that is *longer* than the offset seeded from the old one:
        // the shrink check alone would read this from the middle.
        try FileManager.default.removeItem(atPath: path)
        let fresh = String(repeating: "y", count: 400) + "\n"
        try Data(fresh.utf8).write(to: URL(fileURLWithPath: path))

        AgentPipeCompletion.shared.tickForTesting()
        XCTAssertEqual(
            AgentPipeCompletion.shared.offsetForTesting(agentId: agentId),
            UInt64(fresh.utf8.count),
            "the whole replacement is read, not the tail of it")
    }

    /// The case the shrink check was written for still works: same file, made
    /// shorter under a live watch.
    func testATruncatedEventsFileIsReadFromItsBeginning() throws {
        let agentId = "watch-\(UUID().uuidString)"
        let path = AgentPipeCompletion.eventsPath(agentId: agentId)
        AgentPipeTransport.prepareDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try Data(String(repeating: "x", count: 500).utf8).write(to: URL(fileURLWithPath: path))
        AgentPipeCompletion.shared.watch(agentId: agentId, teamName: "t", agentName: "executor")
        defer { AgentPipeCompletion.shared.forget(agentId: agentId) }

        // Truncate in place — same inode, fewer bytes.
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 0)
        let fresh = String(repeating: "y", count: 50) + "\n"
        try handle.write(contentsOf: Data(fresh.utf8))
        try handle.close()

        AgentPipeCompletion.shared.tickForTesting()
        XCTAssertEqual(
            AgentPipeCompletion.shared.offsetForTesting(agentId: agentId),
            UInt64(fresh.utf8.count))
    }
}
