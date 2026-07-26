import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Reading a session without a terminal in it.
///
/// Measured before any of this was written: `claude --print` with plain pipes —
/// no PTY, no shell, no FIFO — takes turn after turn and keeps its context. So
/// the terminal was never load-bearing, and what is left to get right is the
/// parsing: turning the stream into things a view can draw as what they are.
@MainActor
final class AgentSessionTests: XCTestCase {

    private func session(_ lines: [String]) -> AgentSession {
        let s = AgentSession()
        for line in lines { s.ingestForTesting(line) }
        return s
    }

    private func event(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    // MARK: - Who spoke

    /// A leader's task and a person's question are identical on the wire —
    /// deliberately, so the agent cannot treat them differently. The label is
    /// this side's business, and it is the only thing the pane could not say
    /// before: every replay used to read as the same anonymous "sent".
    func testTheReceiptRemembersWhoSentIt() throws {
        let s = AgentSession()
        s.noteSenderForTesting(.person)
        s.ingestForTesting(event(["type": "user", "isReplay": true,
                                  "message": ["role": "user", "content": "what did you find?"]]))
        guard case .said(_, let speaker, let text) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a sent turn")
        }
        XCTAssertEqual(speaker, .person)
        XCTAssertEqual(text, "what did you find?")
    }

    /// Drawn from the replay, not from the send.
    ///
    /// The pane path had to assume delivery: it typed, pressed Return from
    /// another process, and hoped. Here the message comes back, so what appears
    /// on screen is what the agent confirmed receiving rather than what was
    /// hoped for.
    func testNothingIsDrawnUntilTheAgentConfirmsIt() {
        let s = AgentSession()
        s.noteSenderForTesting(.leader)
        XCTAssertTrue(s.entries.isEmpty, "a send is not yet an event")
    }

    // MARK: - Tool calls

    /// The pairing a terminal cannot make.
    ///
    /// On a screen a call and its result are two unrelated lines, minutes and a
    /// scroll apart. Here the result carries the id of the call it answers, so
    /// they are one row that can hold a spinner, then a verdict, then folded
    /// output.
    func testAResultLandsOnTheCallItAnswers() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "swift build"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "Compiling…", "is_error": false]]]]),
        ])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.headline, "swift build", "the field that says what it will do")
        XCTAssertEqual(call.result, "Compiling…")
        XCTAssertFalse(call.failed)
        XCTAssertFalse(call.isRunning)
        XCTAssertEqual(s.entries.count, 1, "a call and its result are one thing, not two")
    }

    func testACallWithNoResultYetIsStillRunning() throws {
        let s = session([event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t1", "name": "Read",
             "input": ["file_path": "/tmp/x.swift"]]]]])])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertTrue(call.isRunning)
        XCTAssertEqual(call.headline, "/tmp/x.swift")
    }

    func testAFailedToolSaysSo() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "false"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "exit 1", "is_error": true]]]]),
        ])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertTrue(call.failed)
    }

    /// A result for a call this session never saw must not attach itself to
    /// whichever call happens to be last.
    func testAnOrphanResultIsIgnoredRatherThanMisattributed() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "swift build"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "somebody-else",
                 "content": "nope", "is_error": true]]]]),
        ])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertTrue(call.isRunning)
        XCTAssertFalse(call.failed)
    }

    // MARK: - Streaming

    private func delta(_ index: Int, _ text: String, thinking: Bool = false) -> String {
        let key = thinking ? "thinking" : "text"
        return event(["type": "stream_event", "event": [
            "type": "content_block_delta", "index": index,
            "delta": ["type": "\(key)_delta", key: text]]])
    }

    private func blockStart(_ index: Int, _ type: String) -> String {
        event(["type": "stream_event", "event": [
            "type": "content_block_start", "index": index,
            "content_block": ["type": type]]])
    }

    private func blockStop(_ index: Int) -> String {
        event(["type": "stream_event",
               "event": ["type": "content_block_stop", "index": index]])
    }

    /// One row, grown. Not a row per fragment — measured on a real answer,
    /// codex sent 163 deltas for sixty words.
    func testDeltasBuildOneRowRatherThanMany() throws {
        let s = session([blockStart(0, "text"), delta(0, "Tange"),
                         delta(0, "rines "), delta(0, "are small."), blockStop(0)])
        XCTAssertEqual(s.entries.count, 1)
        guard case .answered(_, let text) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(text, "Tangerines are small.")
    }

    /// A message interleaves thinking and text, addressed by index. A delta
    /// that appended to whatever was last would put reasoning in the answer.
    func testADeltaFindsItsOwnRow() throws {
        let s = session([
            blockStart(0, "thinking"), blockStart(1, "text"),
            delta(1, "the answer"), delta(0, "the reasoning", thinking: true),
            blockStop(0), blockStop(1),
        ])
        XCTAssertEqual(s.entries.count, 2)
        guard case .thought(_, let thought) = s.entries[0],
              case .answered(_, let answer) = s.entries[1] else {
            return XCTFail("expected a thought then an answer")
        }
        XCTAssertEqual(thought, "the reasoning")
        XCTAssertEqual(answer, "the answer")
    }

    /// A delta whose type does not match its block is dropped rather than
    /// forced in — reasoning must not end up inside the answer.
    func testADeltaOfTheWrongKindIsDropped() throws {
        let s = session([blockStart(0, "thinking"), delta(0, "not reasoning")])
        guard case .thought(_, let body) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a thought")
        }
        XCTAssertEqual(body, "")
    }

    /// Under `--include-partial-messages` a message arrives twice: once as
    /// deltas, then whole. Both drawn is the same paragraph printed twice.
    func testAStreamedMessageIsNotDrawnAgainWhenItArrivesWhole() throws {
        let s = session([
            event(["type": "stream_event", "event": ["type": "message_start",
                                                     "message": ["role": "assistant"]]]),
            blockStart(0, "text"), delta(0, "hello"), blockStop(0),
            event(["type": "assistant", "message": ["content": [
                ["type": "text", "text": "hello"]]]]),
        ])
        XCTAssertEqual(s.entries.count, 1, "the whole copy is the same content")
    }

    /// And a message that was *not* streamed still draws — the bridge's CLIs
    /// stream, but a turn can end before a block ever opens.
    func testAMessageThatNeverStreamedIsStillDrawn() {
        let s = session([
            event(["type": "stream_event", "event": ["type": "message_start",
                                                     "message": ["role": "assistant"]]]),
            event(["type": "assistant", "message": ["content": [
                ["type": "text", "text": "hello"]]]]),
        ])
        XCTAssertEqual(s.entries.count, 1)
    }

    /// The caret is the only thing that says "still writing"; a terminal can
    /// only show characters arriving and leave the rest to be guessed.
    func testTheOpenRowIsMarkedWhileItIsWritten() throws {
        let s = session([blockStart(0, "text"), delta(0, "half a sen")])
        let id = try XCTUnwrap(s.entries.first).id
        XCTAssertTrue(s.streamingIds.contains(id))
        s.ingestForTesting(blockStop(0))
        XCTAssertFalse(s.streamingIds.contains(id))
    }

    /// A turn can end with a block still open — an error, a stop, a killed
    /// process. A caret left on says "still writing" forever.
    func testATurnEndingMidStreamStopsTheCaret() {
        let s = session([blockStart(0, "text"), delta(0, "cut off"),
                         event(["type": "result", "is_error": true, "result": ""])])
        XCTAssertTrue(s.streamingIds.isEmpty)
    }

    /// Streamed text is the turn's answer, so a CLI that sends no `result`
    /// text still reports what it said.
    func testStreamedTextCountsAsWhatWasSaid() throws {
        var final: String?
        let s = AgentSession()
        s.onTurnEnd = { text, _, _ in final = text }
        for line in [blockStart(0, "text"), delta(0, "streamed only"), blockStop(0),
                     event(["type": "result", "stop_reason": "end_turn"])] {
            s.ingestForTesting(line)
        }
        XCTAssertEqual(final, "streamed only")
    }

    /// The launch has to ask for deltas, or a turn appears all at once when it
    /// is already over.
    func testTheLaunchAsksForPartialMessages() {
        let launch = AgentSession.claudeLaunch(
            claudePath: "/usr/local/bin/claude", model: "haiku",
            instructions: "", extraArgs: [], workingDirectory: "/tmp")
        XCTAssertTrue(launch.arguments.contains("--include-partial-messages"))
    }

    // MARK: - The end of a turn

    /// Stated, not inferred.
    ///
    /// The pane path decided a turn was over when the screen had been still for
    /// half a second — a timer standing in for a fact. The fact is in the
    /// stream, along with what the turn cost.
    func testATurnEndsWithItsOwnFacts() throws {
        var reported: (String, AgentSession.TurnEnd)?
        let s = AgentSession()
        s.onTurnEnd = { text, end, _ in reported = (text, end) }
        s.ingestForTesting(event([
            "type": "result", "stop_reason": "end_turn", "is_error": false,
            "result": "STATUS: DONE", "total_cost_usd": 0.4096,
            "duration_ms": 2700, "usage": ["input_tokens": 2, "output_tokens": 8],
        ]))
        let (final, end) = try XCTUnwrap(reported)
        XCTAssertEqual(final, "STATUS: DONE")
        XCTAssertEqual(end.stop, "end_turn")
        XCTAssertEqual(end.cost ?? 0, 0.4096, accuracy: 0.0001)
        XCTAssertEqual(end.duration ?? 0, 2.7, accuracy: 0.001)
        XCTAssertEqual(end.tokensOut, 8)
        XCTAssertFalse(end.failed)
    }

    func testAFailedTurnIsMarkedFailed() throws {
        let s = session([event(["type": "result", "subtype": "error",
                                "is_error": true, "result": "refused"])])
        guard case .turnEnded(_, let end) = try XCTUnwrap(s.entries.last) else {
            return XCTFail("expected a turn end")
        }
        XCTAssertTrue(end.failed)
    }

    // MARK: - The session banner

    /// `system/init` arrives at the head of every turn, not once per session.
    /// Redrawing the banner each time buries the conversation in it.
    func testTheSessionIsAnnouncedOnce() {
        let init1 = event(["type": "system", "subtype": "init", "model": "claude-sonnet-5",
                           "tools": Array(repeating: "t", count: 63), "mcp_servers": ["a", "b"]])
        let s = session([init1, event(["type": "system", "subtype": "init",
                                       "model": "something-else", "tools": []])])
        XCTAssertEqual(s.summary, "claude-sonnet-5 · 63 tools · 2 mcp")
    }

    /// Twelve hook lines fire before an agent does anything. None of them is
    /// what a person is watching for.
    func testHookNoiseNeverReachesTheView() {
        let s = session([
            event(["type": "system", "subtype": "hook_started", "hook_name": "x"]),
            event(["type": "system", "subtype": "hook_response", "hook_name": "x"]),
            event(["type": "system", "subtype": "thinking_tokens", "count": 120]),
        ])
        XCTAssertTrue(s.entries.isEmpty)
    }

    /// A CLI may write a warning to stdout. Showing it beats swallowing it —
    /// the alternative is a pane that goes quiet for a reason nobody can see.
    func testALineThatIsNotAnEventIsStillShown() throws {
        let s = session(["npm warn: something"])
        guard case .notice(_, let text) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a notice")
        }
        XCTAssertEqual(text, "npm warn: something")
    }

    // MARK: - One instruction, one turn

    /// The behaviour this serialisation exists for, measured live.
    ///
    /// Five messages sent back to back arrived byte for byte — nothing was
    /// lost — and came out as **three** turns: claude queues whatever arrives
    /// mid-turn and joins it into the next one with a newline. For a person
    /// typing a follow-up that is right, and it is what Claude Code itself
    /// does. For the leader it is not: two delegated tasks merged into one turn
    /// produce one `result`, so the second task never gets its completion and
    /// the board waits on it forever.
    func testATurnCarriesTheTaskTheInstructionNamed() throws {
        let capsule = """
            ## Task Capsule
            TASK_ID: e82188a0
            [GOAL] do the thing [/GOAL]
            """
        XCTAssertEqual(AgentSession.taskId(in: capsule), "e82188a0")
        XCTAssertNil(AgentSession.taskId(in: "just have a look"))
        XCTAssertNil(AgentSession.taskId(in: "TASK_ID:"))
    }

    /// The correlation the screen path could never make. An answer on a screen
    /// has nothing tying it to a request, so that path guessed — and a reply
    /// was measured closing an unrelated blocked task.
    func testTheAnsweredTaskIsHandedToTheReply() throws {
        var answered: [String?] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, task in answered.append(task) }
        s.beginTurnForTesting(taskId: "e82188a0")
        s.ingestForTesting(event(["type": "result", "stop_reason": "end_turn",
                                  "result": "STATUS: DONE"]))
        XCTAssertEqual(answered, ["e82188a0"])
    }

    /// And it is cleared, so the next turn cannot inherit it.
    func testATaskIsAnsweredOnlyOnce() throws {
        var seen: [String?] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, task in seen.append(task) }
        s.beginTurnForTesting(taskId: "e82188a0")
        s.ingestForTesting(event(["type": "result", "result": "one"]))
        s.ingestForTesting(event(["type": "result", "result": "two"]))
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0], "e82188a0")
        XCTAssertNil(seen[1])
    }

    // MARK: - The wire

    func testATurnGoesOutAsOneLineOfNdjson() throws {
        let data = try AgentSession.encode(text: "line one\nline two")
        XCTAssertEqual(data.last, 0x0A)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "user")
        // Newlines survive. The terminal path had to flatten instructions so a
        // TUI composer would not submit on the first one — an instruction
        // reshaped to survive its own delivery.
        XCTAssertEqual((obj["message"] as? [String: Any])?["content"] as? String,
                       "line one\nline two")
    }

    /// Nothing in the arguments assumes a terminal: no shell, no FIFO, no
    /// `exec` wrapper — the things the pipe transport needed only because its
    /// host was one.
    func testTheLaunchNeedsNoTerminal() {
        let launch = AgentSession.claudeLaunch(
            claudePath: "/usr/local/bin/claude", model: "sonnet",
            instructions: "be brief", extraArgs: [], workingDirectory: "/tmp"
        )
        XCTAssertEqual(launch.executable, "/usr/local/bin/claude")
        XCTAssertTrue(launch.arguments.contains("--replay-user-messages"),
                      "the receipt is what makes delivery verifiable")
        XCTAssertTrue(launch.arguments.contains("--input-format"))
        for shellish in ["mkfifo", "exec", "-c", "&&", "|"] {
            XCTAssertFalse(launch.arguments.contains(shellish),
                           "\(shellish) belongs to a terminal host")
        }
    }

    /// A long session is a memory leak with a scrollbar.
    func testTheTranscriptIsBounded() {
        let s = AgentSession()
        for i in 0..<2_100 {
            s.ingestForTesting(event(["type": "assistant",
                                      "message": ["content": [["type": "text", "text": "\(i)"]]]]))
        }
        XCTAssertLessThanOrEqual(s.entries.count, 2_000)
        guard case .answered(_, let last) = s.entries.last else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(last, "2099", "the newest must survive, not the oldest")
    }
}
