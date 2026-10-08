import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class CodexLeaderWakeTests: XCTestCase {

    func testIsOffUnlessTheUserTurnsItOn() throws {
        let suite = "CodexLeaderWakeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(CodexLeaderWake.isEnabled(defaults: defaults))
        defaults.set(true, forKey: CodexLeaderWake.enabledKey)
        XCTAssertTrue(CodexLeaderWake.isEnabled(defaults: defaults))
    }

    func testWakesCodexLeadersOnlyNeverClaude() {
        XCTAssertTrue(CodexLeaderWake.isCodexLeader(leaderMode: "codex", leaderCli: nil))
        XCTAssertTrue(CodexLeaderWake.isCodexLeader(leaderMode: "adopted", leaderCli: "Codex"))
        XCTAssertFalse(CodexLeaderWake.isCodexLeader(leaderMode: "claude", leaderCli: nil))
        XCTAssertFalse(CodexLeaderWake.isCodexLeader(leaderMode: "adopted", leaderCli: "claude"))
        XCTAssertFalse(CodexLeaderWake.isCodexLeader(leaderMode: "adopted", leaderCli: nil))
        XCTAssertFalse(CodexLeaderWake.isCodexLeader(leaderMode: "repl", leaderCli: "codex"))
    }

    func testATeamWakesOnlyWhenItsLeaderWasToldSoAtCreation() throws {
        let suite = "CodexLeaderWakeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func wakes(_ injected: Bool, _ mode: String, _ cli: String? = nil) -> Bool {
            CodexLeaderWake.newTeamWakes(
                leaderPromptInjected: injected, leaderMode: mode, leaderCli: cli, defaults: defaults
            )
        }
        XCTAssertFalse(wakes(true, "codex"), "setting off at creation")
        defaults.set(true, forKey: CodexLeaderWake.enabledKey)
        XCTAssertTrue(wakes(true, "codex"))
        XCTAssertFalse(wakes(false, "codex"), "no prompt was written, so no wake was promised")
        XCTAssertFalse(wakes(true, "claude"))
        XCTAssertFalse(wakes(false, "adopted", "codex"))
    }

    func testDeliveryFollowsTheTeamSnapshotNotTheLiveSetting() {
        XCTAssertTrue(CodexLeaderWake.shouldDeliver(
            teamWakes: true, leaderReady: true, leaderMode: "codex", leaderCli: nil
        ))
        XCTAssertFalse(CodexLeaderWake.shouldDeliver(
            teamWakes: false, leaderReady: true, leaderMode: "codex", leaderCli: nil
        ))
        XCTAssertFalse(CodexLeaderWake.shouldDeliver(
            teamWakes: true, leaderReady: false, leaderMode: "codex", leaderCli: nil
        ))
        XCTAssertFalse(CodexLeaderWake.shouldDeliver(
            teamWakes: true, leaderReady: true, leaderMode: "claude", leaderCli: nil
        ))
    }

    func testOnlyTeamsWithTheSnapshotCollectWakes() {
        var state = CodexLeaderWakeState()
        XCTAssertFalse(state.note(teamName: "mine", taskId: "ab12", status: "completed"))
        state.setTeamWakes("mine", true)
        XCTAssertTrue(state.note(teamName: "mine", taskId: "ab12", status: "completed"))
        XCTAssertFalse(state.note(teamName: "other", taskId: "cd34", status: "completed"))
        XCTAssertEqual(
            state.flushLine(teamName: "mine"),
            "[term-mesh] task ab12 completed — run tm-agent collect --headers"
        )
        XCTAssertNil(state.flushLine(teamName: "other"))
    }

    func testFlushRechecksTheTeamAfterTheCoalesceWindow() {
        var state = CodexLeaderWakeState()
        state.setTeamWakes("mine", true)
        XCTAssertTrue(state.note(teamName: "mine", taskId: "ab12", status: "completed"))
        state.setTeamWakes("mine", false)
        XCTAssertNil(state.flushLine(teamName: "mine"))
        state.setTeamWakes("mine", true)
        XCTAssertTrue(
            state.note(teamName: "mine", taskId: "ab12", status: "completed"),
            "a recreated team starts with fresh dedupe"
        )
    }

    func testAnnouncesEachTaskStatusOnce() {
        var batch = CodexLeaderWakeBatch()
        XCTAssertTrue(batch.admit(taskId: "ab12", status: "completed"))
        XCTAssertFalse(batch.admit(taskId: "ab12", status: "completed"))
        XCTAssertEqual(batch.drain(), [.init(taskId: "ab12", status: "completed")])
        XCTAssertFalse(batch.admit(taskId: "ab12", status: "completed"), "a drained pair stays announced")
        XCTAssertTrue(batch.admit(taskId: "ab12", status: "review_ready"))
    }

    func testIgnoresStatusesThatNeedNoCollection() {
        var batch = CodexLeaderWakeBatch()
        for status in ["pending", "in_progress", "delivered", "assigned"] {
            XCTAssertFalse(batch.admit(taskId: "ab12", status: status), status)
        }
        for status in ["completed", "review_ready", "blocked", "failed", "cancelled"] {
            XCTAssertTrue(batch.admit(taskId: "t-\(status)", status: status), status)
        }
        XCTAssertFalse(batch.admit(taskId: "", status: "completed"))
    }

    func testCoalescesCompletionsIntoOneLine() {
        var batch = CodexLeaderWakeBatch()
        _ = batch.admit(taskId: "ab12", status: "completed")
        _ = batch.admit(taskId: "cd34", status: "review_ready")
        let events = batch.drain()
        XCTAssertEqual(
            CodexLeaderWakeBatch.wakeLine(for: events),
            "[term-mesh] tasks ab12 completed, cd34 review_ready — run tm-agent collect --headers"
        )
        XCTAssertTrue(batch.drain().isEmpty)
        XCTAssertEqual(
            CodexLeaderWakeBatch.wakeLine(for: [.init(taskId: "ef56", status: "failed")]),
            "[term-mesh] task ef56 failed — run tm-agent collect --headers"
        )
        XCTAssertNil(CodexLeaderWakeBatch.wakeLine(for: []))
    }

    func testWakeLineCannotCarryANewlineFromATaskId() {
        let line = CodexLeaderWakeBatch.wakeLine(for: [.init(taskId: "ab\n12", status: "completed")])
        XCTAssertEqual(line, "[term-mesh] task ab12 completed — run tm-agent collect --headers")
    }

    func testForgetsTheOldestPairBeyondItsBound() {
        var batch = CodexLeaderWakeBatch(rememberLimit: 2)
        XCTAssertTrue(batch.admit(taskId: "a", status: "completed"))
        XCTAssertTrue(batch.admit(taskId: "b", status: "completed"))
        XCTAssertTrue(batch.admit(taskId: "c", status: "completed"))
        XCTAssertTrue(batch.admit(taskId: "a", status: "completed"), "evicted pair is admitted again")
        XCTAssertFalse(batch.admit(taskId: "c", status: "completed"))
    }

    func testACancelledTaskWakesTheLeader() {
        var state = CodexLeaderWakeState()
        state.setTeamWakes("mine", true)
        XCTAssertTrue(state.note(teamName: "mine", taskId: "ab12", status: "cancelled"))
        XCTAssertEqual(
            state.flushLine(teamName: "mine"),
            "[term-mesh] task ab12 cancelled — run tm-agent collect --headers"
        )
    }

    func testAFailedDeliveryComesBackOnTheNextFlushWithoutBreakingDedupe() throws {
        var state = CodexLeaderWakeState()
        state.setTeamWakes("mine", true)
        XCTAssertTrue(state.note(teamName: "mine", taskId: "ab12", status: "completed"))
        let first = try XCTUnwrap(state.flush(teamName: "mine"))
        XCTAssertNil(state.flush(teamName: "mine"))
        XCTAssertEqual(state.retry(teamName: "mine", flush: first), .scheduled(attempt: 1))
        XCTAssertFalse(
            state.note(teamName: "mine", taskId: "ab12", status: "completed"),
            "the retried pair is still announced once"
        )
        XCTAssertTrue(state.note(teamName: "mine", taskId: "cd34", status: "failed"))
        XCTAssertEqual(
            state.flushLine(teamName: "mine"),
            "[term-mesh] tasks ab12 completed, cd34 failed — run tm-agent collect --headers"
        )
    }

    func testRetriesStopAfterTheBoundAndStartAgainAfterADelivery() throws {
        var state = CodexLeaderWakeState()
        state.setTeamWakes("mine", true)
        _ = state.note(teamName: "mine", taskId: "ab12", status: "completed")
        for attempt in 1...CodexLeaderWakeBatch.maxRetries {
            let flush = try XCTUnwrap(state.flush(teamName: "mine"))
            XCTAssertEqual(state.retry(teamName: "mine", flush: flush), .scheduled(attempt: attempt))
        }
        let last = try XCTUnwrap(state.flush(teamName: "mine"))
        XCTAssertEqual(state.retry(teamName: "mine", flush: last), .gaveUp)
        XCTAssertNil(state.flush(teamName: "mine"), "a dropped wake is not retried again")

        _ = state.note(teamName: "mine", taskId: "cd34", status: "completed")
        let next = try XCTUnwrap(state.flush(teamName: "mine"))
        XCTAssertEqual(state.retry(teamName: "mine", flush: next), .scheduled(attempt: 1))
        let again = try XCTUnwrap(state.flush(teamName: "mine"))
        state.delivered(teamName: "mine", flush: again)
        XCTAssertEqual(
            state.retry(teamName: "mine", flush: again), .scheduled(attempt: 1),
            "a delivery resets the count"
        )
    }

    func testARetryForATeamThatStoppedWakingOrWasRecreatedIsDiscarded() throws {
        var state = CodexLeaderWakeState()
        state.setTeamWakes("mine", true)
        _ = state.note(teamName: "mine", taskId: "ab12", status: "completed")
        let stale = try XCTUnwrap(state.flush(teamName: "mine"))
        state.setTeamWakes("mine", true)
        _ = state.note(teamName: "mine", taskId: "cd34", status: "completed")
        XCTAssertEqual(state.retry(teamName: "mine", flush: stale), .discarded)
        XCTAssertEqual(
            state.flushLine(teamName: "mine"),
            "[term-mesh] task cd34 completed — run tm-agent collect --headers"
        )
        state.setTeamWakes("mine", false)
        XCTAssertEqual(state.retry(teamName: "mine", flush: stale), .discarded)
        XCTAssertEqual(state.retry(teamName: "other", flush: stale), .discarded)
    }

    func testRetryBacksOffAndKeepsAheadOfTheCoalesceWindow() {
        XCTAssertGreaterThan(CodexLeaderWakeBatch.retryDelay(attempt: 1), CodexLeaderWake.coalesceWindow)
        XCTAssertGreaterThan(
            CodexLeaderWakeBatch.retryDelay(attempt: 2), CodexLeaderWakeBatch.retryDelay(attempt: 1)
        )
    }

    func testFindsTheThreadFromItsWriterLock() {
        let thread = "01a1165f-02ce-7e70-b34d-4c3989f2f163"
        let ids = CodexLeaderThreadLocator.threadIds(inOpenPaths: [
            "/dev/ttys004",
            "/Users/me/.codex/sessions/2026/10/07/rollout.jsonl",
            "/Users/me/.codex/thread-writer-locks/\(thread).lock",
            "/Users/me/.codex/thread-writer-locks/\(thread.uppercased()).lock",
            "/Users/me/.codex/thread-writer-locks/not-a-uuid.lock",
            "/Users/me/.codex/other/\(thread).lock",
        ])
        XCTAssertEqual(ids, [thread])
    }

    func testTellsTheInteractiveSessionFromCodexServices() {
        XCTAssertFalse(CodexLeaderThreadLocator.isCodexService(arguments: ["codex"]))
        XCTAssertFalse(CodexLeaderThreadLocator.isCodexService(
            arguments: ["codex", "--model", "gpt-5", "-c", "model_reasoning_effort=high", "fix it"]
        ))
        XCTAssertTrue(CodexLeaderThreadLocator.isCodexService(arguments: ["codex", "app-server"]))
        XCTAssertTrue(CodexLeaderThreadLocator.isCodexService(
            arguments: ["codex", "-m", "gpt-5", "queue", "--thread", "x"]
        ))
        XCTAssertFalse(CodexLeaderThreadLocator.isCodexService(arguments: ["codex", "--", "queue"]))
        for subcommand in ["exec", "e", "review", "mcp-server", "exec-server", "apply"] {
            XCTAssertTrue(
                CodexLeaderThreadLocator.isCodexService(arguments: ["codex", "-m", "gpt-5", subcommand, "x"]),
                subcommand
            )
        }
        XCTAssertFalse(CodexLeaderThreadLocator.isCodexService(arguments: ["codex", "resume", "--last"]))
        XCTAssertFalse(CodexLeaderThreadLocator.isCodexService(arguments: ["codex", "fork", "--last"]))
        XCTAssertFalse(CodexLeaderThreadLocator.isCodexService(arguments: ["codex", "explain the exec path"]))
        XCTAssertFalse(CodexLeaderThreadLocator.isCodexService(arguments: ["codex", "--unknown", "queue"]))
    }

    func testParsesAProcessImage() throws {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buffer.append(contentsOf: $0) }
        func append(_ string: String) { buffer.append(contentsOf: Array(string.utf8)); buffer.append(0) }
        append("/opt/homebrew/bin/codex")
        buffer.append(contentsOf: [0, 0, 0])
        append("codex")
        append("--model")
        append("TERMMESH_SURFACE_ID=B27AC5D4-815A-435F-93F8-1283021CF521")
        append("CODEX_HOME=/tmp/codex=home")
        buffer.append(0)
        append("ignored-after-terminator=1")

        let image = try XCTUnwrap(CodexLeaderThreadLocator.parseProcArgs(buffer))
        XCTAssertEqual(image.executable, "/opt/homebrew/bin/codex")
        XCTAssertEqual(image.arguments, ["codex", "--model"])
        XCTAssertEqual(image.environment["TERMMESH_SURFACE_ID"], "B27AC5D4-815A-435F-93F8-1283021CF521")
        XCTAssertEqual(image.environment["CODEX_HOME"], "/tmp/codex=home")
        XCTAssertNil(image.environment["ignored-after-terminator"])
    }

    func testRejectsATruncatedProcessImage() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/bin/codex".utf8) + [0, 0] + Array("codex".utf8) + [0])
        XCTAssertNil(CodexLeaderThreadLocator.parseProcArgs(buffer))
        XCTAssertNil(CodexLeaderThreadLocator.parseProcArgs([1, 0]))
    }
}
