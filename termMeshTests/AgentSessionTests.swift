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

    /// Measured on kiro: five tool rows left spinning, because the bridge
    /// dropped the `toolCallId` its results carried and a row with no id can
    /// never be closed by one. The id is carried now — and a CLI that simply
    /// never reports a result is still possible, so the turn being over is
    /// taken as proof that nothing is still running.
    func testATurnEndingClosesToolRowsThatNeverReported() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Read",
                 "input": ["file_path": "/tmp/x"]]]]]),
            event(["type": "result", "stop_reason": "end_turn"]),
        ])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertFalse(call.isRunning, "the turn is over; nothing is still running")
        XCTAssertFalse(call.failed, "and not reporting is not the same as failing")
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

    // MARK: - The header is a value, not prose

    /// Measured on a real transcript: an answer was six lines, five of them
    /// this header. And the app was already parsing it to close the task — so
    /// it was shown raw *and* read structurally, and only one of those is
    /// necessary.
    func testTheHeaderLeavesTheProseAndBecomesAVerdict() throws {
        var ended: AgentSession.TurnEnd?
        let s = AgentSession()
        s.onTurnEnd = { _, end, _ in ended = end }
        s.ingestForTesting(event(["type": "assistant", "message": ["content": [
            ["type": "text", "text": """
                OK3

                STATUS: DONE
                FILES: none
                VERIFY: n/a
                NEXT: NONE
                FULL_REPORT: n/a
                """]]]]))
        s.ingestForTesting(event(["type": "result", "stop_reason": "end_turn"]))

        guard case .answered(_, let body) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(body, "OK3", "five of six lines were protocol")
        let verdict = try XCTUnwrap(ended?.verdict)
        XCTAssertEqual(verdict.status, "DONE")
        XCTAssertTrue(verdict.isDone)
    }

    /// Four "none"s in a row is worse than no detail at all.
    func testOnlyTheFieldsTheAgentFilledInAreWorthShowing() {
        let (_, v) = AgentSession.splitVerdict(from: """
            STATUS: DONE
            FILES: none
            VERIFY: swift build
            NEXT: NONE
            FULL_REPORT: n/a
            """)
        XCTAssertEqual(v?.details.map(\.0), ["VERIFY"])
    }

    /// An answer that was only a header leaves an empty row behind.
    func testAnAnswerThatWasOnlyAHeaderLeavesNoEmptyRow() {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "text", "text": "STATUS: DONE\nFILES: none"]]]]),
            event(["type": "result", "stop_reason": "end_turn"]),
        ])
        XCTAssertFalse(s.entries.contains { if case .answered = $0 { return true } else { return false } })
    }

    /// Prose with no header is left exactly as it is.
    func testAnAnswerWithNoHeaderIsUntouched() {
        let (body, v) = AgentSession.splitVerdict(from: "just some prose\nover two lines")
        XCTAssertEqual(body, "just some prose\nover two lines")
        XCTAssertNil(v)
    }

    // MARK: - An instruction is not its envelope

    /// Measured: sixteen lines, nine of them scaffold, the intent one line
    /// inside `[GOAL]`. The bubble was showing the envelope and burying the
    /// letter.
    func testTheGoalIsWhatTheBubbleShows() {
        let capsule = """
            [FINAL LINE — end your reply with this header, one field per line]
            STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>
            FILES: <changed paths or none>

            ## Task Capsule
            TASK_ID: cca01f9c
            TASK_TITLE: Reply with exactly: OK1.
            PROTOCOL: TM-PROTOCOL-v1
            OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus concise summary

            [GOAL]
            Reply with exactly: OK1. Nothing else, no tools.
            [/GOAL]
            """
        let read = AgentSession.read(instruction: capsule)
        XCTAssertEqual(read.headline, "Reply with exactly: OK1. Nothing else, no tools.")
        XCTAssertEqual(read.taskId, "cca01f9c")
        XCTAssertTrue(read.hasMore, "the envelope is still reachable")
        XCTAssertEqual(read.full, capsule)
    }

    /// A plain message has no envelope to fold, so nothing is hidden and no
    /// disclosure appears.
    func testAPlainMessageShowsWholeAndOffersNothingToUnfold() {
        let read = AgentSession.read(instruction: "have a look at the build")
        XCTAssertEqual(read.headline, "have a look at the build")
        XCTAssertFalse(read.hasMore)
        XCTAssertNil(read.taskId)
    }

    /// Without a capsule the protocol lines still go, and what a person wrote
    /// stays.
    func testProtocolLinesGoEvenWithoutAGoalBlock() {
        let read = AgentSession.read(instruction: """
            Reply with the word TANGO.

            [FINAL LINE — end your reply with this header, one field per line]
            STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>
            FULL_REPORT: <result file path or n/a>
            """)
        XCTAssertEqual(read.headline, "Reply with the word TANGO.")
    }

    /// The bug the screenshot caught.
    ///
    /// Filtering by line prefix alone ate two real lines out of a runbook
    /// digest — its `VERIFY:` and `OUTPUT:` rows, which say what the role must
    /// do — because those prefixes are also header keys. Only a capsule is
    /// folded now; anything else is shown exactly as sent.
    func testARunbookIsNotMistakenForAnEnvelope() {
        let digest = """
            ## Runbook Digest
            ROLE: explorer
            WHEN: The task asks where something is defined.
            VERIFY: Include the exact search command you used.
            OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT
            FULL: /repo/.agent-runbooks/explorer.md
            """
        let read = AgentSession.read(instruction: digest)
        XCTAssertEqual(read.headline, digest, "nothing the leader sent may vanish")
        XCTAssertFalse(read.hasMore)
    }

    // MARK: - Markdown

    /// The pane was showing `## Heading` and `**bold**` as literal characters,
    /// because agents write markdown whether or not anything renders it.
    func testBlocksComeApartTheWayTheyWereWritten() {
        let blocks = AgentMarkdown.blocks("""
            ## What I found

            The parser lives in `Foo.swift`.

            - first
            - second
            1. step one

            ```swift
            let x = 1
            ```
            """)
        guard case .heading(let level, let title) = blocks[0] else {
            return XCTFail("expected a heading, got \(blocks[0])")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(title, "What I found")
        XCTAssertEqual(blocks.count, 6)
        guard case .bullet(let marker, _) = blocks[2] else { return XCTFail("expected a bullet") }
        XCTAssertEqual(marker, "•")
        // An agent quoting "step 3" means 3, so the number it wrote survives.
        guard case .bullet(let ordinal, _) = blocks[4] else { return XCTFail("expected an ordinal") }
        XCTAssertEqual(ordinal, "1.")
        guard case .code(let language, let body) = blocks[5] else { return XCTFail("expected code") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(body, "let x = 1")
    }

    /// While a turn streams the closing fence has not arrived. Treating the
    /// opening line as a paragraph until it does makes the block flicker into
    /// existence.
    func testAnUnclosedFenceIsAlreadyCode() {
        let blocks = AgentMarkdown.blocks(#"here:\#n```json\#n{\#n  "a": 1"#)
        guard case .code(let language, let body) = blocks.last else {
            return XCTFail("expected code, got \(String(describing: blocks.last))")
        }
        XCTAssertEqual(language, "json")
        XCTAssertTrue(body.contains("\"a\""))
    }

    /// `#hashtag` and `#!/bin/sh` are not headings.
    func testAHashWithoutASpaceIsNotAHeading() {
        guard case .paragraph = AgentMarkdown.blocks("#!/bin/sh")[0] else {
            return XCTFail("expected a paragraph")
        }
    }

    /// In JSON the interesting strings are the keys, and a key is a string
    /// with a colon after it.
    func testJsonKeysReadDifferentlyFromValues() {
        let tokens = AgentMarkdown.tokenize("{\"name\": \"term-mesh\", \"n\": 42}",
                                            language: "json")
        XCTAssertTrue(tokens.contains { $0.0 == "\"name\"" && $0.1 == .key })
        XCTAssertTrue(tokens.contains { $0.0 == "\"term-mesh\"" && $0.1 == .string })
        XCTAssertTrue(tokens.contains { $0.0 == "42" && $0.1 == .number })
    }

    func testCommentsAndKeywordsAreFound() {
        let tokens = AgentMarkdown.tokenize("// note\nlet x = 1", language: "swift")
        XCTAssertTrue(tokens.contains { $0.0 == "// note" && $0.1 == .comment })
        XCTAssertTrue(tokens.contains { $0.0 == "let" && $0.1 == .keyword })
    }

    /// Guessing keywords for an unknown language colours the wrong words,
    /// which is worse than colouring none.
    func testAnUnknownLanguageGetsNoInventedKeywords() {
        let tokens = AgentMarkdown.tokenize("let x = \"hi\"", language: "brainfuck")
        XCTAssertFalse(tokens.contains { $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "\"hi\"" && $0.1 == .string })
    }

    /// Nothing may be dropped: highlighting is colour over the same characters.
    func testTokenizingLosesNothing() {
        for (code, lang) in [("let a = 1 // x", "swift"),
                             ("{\"k\": [1, 2]}", "json"),
                             ("echo $HOME # hi", "bash")] {
            let joined = AgentMarkdown.tokenize(code, language: lang).map(\.0).joined()
            XCTAssertEqual(joined, code, lang)
        }
    }

    // MARK: - Following the bottom

    /// A view that follows the bottom cannot key on `entries.count`.
    ///
    /// A streamed answer grows a row that is already there, so the count sits
    /// still while the text runs off the bottom of the pane — which is exactly
    /// what it did: auto-scroll only moved when a *new* row appeared.
    func testEveryMutationMovesTheRevision() {
        let s = AgentSession()
        s.ingestForTesting(blockStart(0, "text"))
        let afterStart = s.revision

        s.ingestForTesting(delta(0, "half a sen"))
        XCTAssertGreaterThan(s.revision, afterStart, "a delta changed the text")
        let afterDelta = s.revision
        XCTAssertEqual(s.entries.count, 1, "and did not change the count")

        s.ingestForTesting(delta(0, "tence"))
        XCTAssertGreaterThan(s.revision, afterDelta)
    }

    /// A tool result closes a row without adding one, and that changes what is
    /// on screen too.
    func testAToolResultMovesTheRevision() {
        let s = session([event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t1", "name": "Bash",
             "input": ["command": "swift build"]]]]])])
        let before = s.revision
        s.ingestForTesting(event(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "done"]]]]))
        XCTAssertGreaterThan(s.revision, before)
        XCTAssertEqual(s.entries.count, 1)
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

    // MARK: - The instruction the agent is given

    /// The block exists for one reason, and its own comment in the CLI says
    /// so: the pane path cannot detect completion, so the agent is told to
    /// announce it by running a shell command. Held natively the turn
    /// announces its own end and the task is closed before the agent could run
    /// anything — measured, it ran the command anyway and got `no_active_task`
    /// back, a guaranteed-failing tool call on every turn.
    func testTheShellCommandDemandIsDroppedForANativeAgent() {
        let instruction = """
            Write about 150 words on tangerines.

            [REQUIRED FINAL STEP — you MUST run this shell command before stopping]
            ```
            tm-agent reply 'STATUS: DONE|BLOCKED|NEEDS_REVIEW
            FILES: <changed paths or none>

            <concise summary body>'
            ```
            Without running this shell command the leader cannot detect completion — the task hangs and wait times out.

            ## Task Capsule
            TASK_ID: e82188a0
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(instruction)

        XCTAssertFalse(cleaned.contains("tm-agent reply"),
                       "the command cannot succeed and its failure is noise")
        XCTAssertFalse(cleaned.contains("cannot detect completion"),
                       "and it is not true here")
        // What the header is for still matters — the verdict is the agent's
        // and nothing else can supply it — so the block is replaced, not cut.
        XCTAssertTrue(cleaned.contains("STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>"))
        XCTAssertTrue(cleaned.contains("FULL_REPORT:"))
        // Not `DONE|BLOCKED|NEEDS_REVIEW`: measured, codex read the alternation
        // bar as a field separator and packed the whole header onto one line.
        XCTAssertFalse(cleaned.contains("DONE|BLOCKED"),
                       "a bar meaning \"pick one\" gets read as \"separator\"")
        // Everything around it survives, including the capsule that names the
        // task the reply will close.
        XCTAssertTrue(cleaned.contains("Write about 150 words on tangerines."))
        XCTAssertTrue(cleaned.contains("TASK_ID: e82188a0"))
    }

    /// The capsule closes by repeating the demand, and its wording — "not by
    /// printing the header in your reply" — is now the exact opposite of what
    /// this path wants, since printing it is the only thing that is read.
    func testTheClosingReminderGoesToo() {
        let instruction = """
            [REQUIRED FINAL STEP — you MUST run this shell command before stopping]
            ```
            tm-agent reply 'STATUS: DONE'
            ```
            Without running this shell command the leader cannot detect completion.

            ## Task Capsule
            TASK_ID: e82188a0

            [REMINDER] Finish by actually running the `tm-agent reply '...'` shell command shown at the top — not by printing the header in your reply.
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(instruction)
        XCTAssertFalse(cleaned.contains("[REMINDER]"))
        XCTAssertFalse(cleaned.contains("tm-agent reply"))
        XCTAssertTrue(cleaned.contains("TASK_ID: e82188a0"))
        XCTAssertTrue(cleaned.contains("STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>"))
    }

    /// The runbook says the same thing in prose, and it reaches the agent in
    /// its very first turn — before any task exists. Same falsehood, different
    /// shape.
    func testTheRunbookProseIsCorrectedToo() {
        let initPrompt = """
            You are a team agent named "explorer".

            CRITICAL: When tasks complete you MUST invoke `tm-agent reply '<5-line header plus result>'` as a shell command. Printing the header text in your response is NOT enough — the leader cannot detect completion and the team stalls.
            Respond with "Agent explorer ready." to confirm.
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(initPrompt)
        XCTAssertFalse(cleaned.contains("tm-agent reply"))
        XCTAssertFalse(cleaned.contains("cannot detect completion"))
        // The requirement is real even though the shell command is not.
        XCTAssertTrue(cleaned.contains("STATUS/FILES/VERIFY/NEXT/FULL_REPORT"))
        XCTAssertTrue(cleaned.contains("Respond with \"Agent explorer ready.\""),
                      "everything else in the prompt survives")
        XCTAssertTrue(cleaned.contains("You are a team agent"))
    }

    /// The digest mandates the command in three more places. An agent told both
    /// "run it" and "do not run it" will do both — which is how the failing
    /// call got measured in the first place.
    func testNoLineIsLeftMandatingTheCommand() {
        let digest = """
            ## Runbook Digest
            5. When done: `tm-agent reply '<full result>'` — this auto-reports and completes your active task.
            - Finish with one `tm-agent reply '<5-line header plus concise result>'`; it auto-reports and completes your active task.
            Begin every `tm-agent reply` body with this 5-line header (use n/a when not applicable):
            STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(digest)
        for line in cleaned.components(separatedBy: "\n") {
            XCTAssertFalse(line.contains("tm-agent reply"), "still mandated: \(line)")
        }
        // What the header is and where it goes survives.
        XCTAssertTrue(cleaned.contains("Begin every reply with this 5-line header"))
        XCTAssertTrue(cleaned.contains("STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>"))
        XCTAssertTrue(cleaned.contains("## Runbook Digest"))
    }

    /// The runbook prints the alternation too, in its own fenced example.
    /// Correcting only the delegate template left the runbook still teaching
    /// the bar that codex read as a field separator.
    func testTheRunbooksOwnAlternationIsSpelledOutToo() {
        let digest = """
            Begin every reply with this 5-line header:
            ```
            STATUS: DONE|BLOCKED|NEEDS_REVIEW
            FILES: <changed paths or "none">
            ```
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(digest)
        XCTAssertFalse(cleaned.contains("DONE|BLOCKED"))
        XCTAssertTrue(cleaned.contains("STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>"))
    }

    /// The CLI has three copies of this block and they do not agree word for
    /// word, so it is read by shape. This is the `broadcast` wording.
    func testEveryWordingOfTheBlockIsRecognised() {
        let broadcast = """
            do the thing

            [REQUIRED FINAL STEP — every recipient MUST run this shell command before stopping]
            ```
            tm-agent reply 'STATUS: DONE'
            ```
            Without running this shell command the leader cannot detect completion.

            tail
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(broadcast)
        XCTAssertFalse(cleaned.contains("tm-agent reply"))
        XCTAssertTrue(cleaned.contains("do the thing"))
        XCTAssertTrue(cleaned.contains("tail"))
    }

    /// A plain instruction is untouched — most turns never carry the block.
    func testAnInstructionWithoutTheBlockIsUnchanged() {
        let plain = "have a look at the build and tell me what broke"
        XCTAssertEqual(TeamOrchestrator.withoutTerminalProtocol(plain), plain)
    }

    /// A truncated block is left alone rather than half-removed. Cutting from
    /// a marker to the end of the text would take the task capsule with it.
    func testAnUnterminatedBlockIsLeftAlone() {
        let broken = """
            do the thing

            [REQUIRED FINAL STEP — you MUST run this shell command before stopping]
            ```
            tm-agent reply 'STATUS: DONE
            """
        XCTAssertEqual(TeamOrchestrator.withoutTerminalProtocol(broken), broken)
    }

    // MARK: - Which colour an agent gets

    /// It was the slot, not the agent: `colorList[agents.count % 6]`. So
    /// `reviewer` was blue in one team and yellow in the next, which makes a
    /// colour something to re-learn per team rather than something to
    /// recognise.
    func testARoleKeepsItsColourAcrossTeams() {
        let first = TeamOrchestrator.agentColor(forRole: "reviewer", taken: [])
        let second = TeamOrchestrator.agentColor(forRole: "reviewer", taken: [])
        XCTAssertEqual(first, second)
        // And it does not depend on who else is in the team, only on what is
        // already taken.
        XCTAssertEqual(TeamOrchestrator.agentColor(forRole: "explorer", taken: []),
                       TeamOrchestrator.agentColor(forRole: "explorer", taken: []))
    }

    func testDifferentRolesGetDifferentColoursWhereTheyCan() {
        var taken: Set<String> = []
        var seen: [String] = []
        for role in ["explorer", "executor", "reviewer", "planner", "tester", "writer"] {
            let colour = TeamOrchestrator.agentColor(forRole: role, taken: taken)
            taken.insert(colour)
            seen.append(colour)
        }
        XCTAssertEqual(Set(seen).count, 6, "six roles, six colours: \(seen)")
    }

    /// Six colours and more roles than that, so a colour already in use steps
    /// to the next free one — stability across teams for the common case,
    /// never a duplicate within one.
    func testATakenColourStepsAside() {
        let alone = TeamOrchestrator.agentColor(forRole: "reviewer", taken: [])
        let crowded = TeamOrchestrator.agentColor(forRole: "reviewer", taken: [alone])
        XCTAssertNotEqual(crowded, alone)
    }

    /// Deliberately not per CLI. Which provider is behind a pane is already
    /// said twice — the chip and the mascot — and spending the colour on it too
    /// would leave two agents of the same role indistinguishable, which is the
    /// thing you actually need to tell apart.
    func testTheColourIsTheRolesNotTheProviders() {
        // Same role, same colour — whatever CLI happens to be behind it, since
        // the CLI is not an input here at all.
        XCTAssertEqual(TeamOrchestrator.agentColor(forRole: "reviewer", taken: []),
                       TeamOrchestrator.agentColor(forRole: "reviewer", taken: []))
        // Two roles can hash to the same colour — six colours, more roles —
        // and that is what the taken set is for. Asserting they differ with an
        // empty set was asserting the absence of collisions, which is not a
        // property this has or needs; `reviewer` and `explorer` both land on
        // green.
        var taken: Set<String> = []
        let first = TeamOrchestrator.agentColor(forRole: "reviewer", taken: taken)
        taken.insert(first)
        XCTAssertNotEqual(TeamOrchestrator.agentColor(forRole: "explorer", taken: taken),
                          first, "within one team they must differ")
    }

    // MARK: - The mascots

    /// They only read as one family if they line up, and a stray space is the
    /// easiest thing in the world to leave in.
    func testEveryMascotIsThreeRowsOfTheSameWidth() {
        for cli in ["claude", "codex", "kiro", "cursor", "agy", "gemini", "unknown"] {
            let rows = AgentPanelView.mascot(for: cli)
            XCTAssertEqual(rows.count, 3, cli)
            for row in rows {
                XCTAssertEqual(row.count, 9, "\(cli): \(row)")
            }
        }
    }

    /// Each CLI gets its own; a repeat would defeat the whole point of drawing
    /// them.
    func testNoTwoCliShareAMascot() {
        let clis = ["claude", "codex", "kiro", "cursor", "agy", "gemini"]
        let drawn = Set(clis.map { AgentPanelView.mascot(for: $0).joined() })
        XCTAssertEqual(drawn.count, clis.count)
    }

    // MARK: - Which CLIs a picker may offer

    private func withNativePanel(_ on: Bool, _ body: () -> Void) {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: AgentPipeTransport.enabledKey)
        let native = d.object(forKey: AgentPipeTransport.nativePanelKey)
        d.set(on, forKey: AgentPipeTransport.enabledKey)
        d.set(on, forKey: AgentPipeTransport.nativePanelKey)
        body()
        d.set(enabled, forKey: AgentPipeTransport.enabledKey)
        d.set(native, forKey: AgentPipeTransport.nativePanelKey)
    }

    /// Not a policy choice: cursor and agy have no interactive UI to host and
    /// no stdin to type into, so a terminal pane has nothing to run. Offering
    /// them there would be offering a pane that opens empty.
    func testTurnPerProcessClisAreOfferedOnlyWhereTheyCanRun() {
        withNativePanel(false) {
            XCTAssertFalse(AgentRolePreset.supportedCLIs.contains("cursor"))
            XCTAssertFalse(AgentRolePreset.supportedCLIs.contains("agy"))
            XCTAssertTrue(AgentRolePreset.supportedCLIs.contains("claude"))
        }
        withNativePanel(true) {
            XCTAssertTrue(AgentRolePreset.supportedCLIs.contains("cursor"))
            XCTAssertTrue(AgentRolePreset.supportedCLIs.contains("agy"))
        }
    }

    /// Settings lists a path for every CLI the app knows, so one can be set
    /// before the option that makes it selectable is turned on.
    func testEveryKnownCliCanHaveAPathSetForIt() {
        for cli in ["claude", "kiro", "codex", "gemini", "cursor", "agy"] {
            XCTAssertTrue(AgentRolePreset.knownCLIs.contains(cli), cli)
        }
    }

    /// Neither knows claude's tiers, and a name a CLI does not recognise is
    /// worse than none — measured on codex, which took `--model sonnet`,
    /// accepted the turn, and said nothing. Empty means the flag is not passed.
    func testATierNameIsDroppedRatherThanHandedToACliThatCannotReadIt() {
        for cli in ["cursor", "agy"] {
            XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: cli, model: "sonnet"), "", cli)
            XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: cli, model: "haiku"), "", cli)
            // A real model name is the user's own and passes through.
            XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: cli, model: "gpt-5"), "gpt-5", cli)
        }
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "cursor"), "")
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "agy"), "")
    }

    // MARK: - The model a bridged CLI will take

    /// Team models are stored as claude's tiers, because that is what the
    /// picker offers for every CLI. Measured: codex took `--model sonnet`,
    /// accepted the turn, and ended it having said nothing — the empty-turn
    /// guard caught it, but the cause was here.
    func testATierNameIsTranslatedBeforeItReachesCodex() {
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "sonnet"),
                       "gpt-5.5")
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "haiku"),
                       "gpt-5.5")
        // A name the user typed themselves is theirs, not a tier to remap.
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "gpt-5.2-codex"),
                       "gpt-5.2-codex")
    }

    /// Kiro's picker offers the same tier names and its CLI takes them.
    func testACliThatTakesTierNamesIsLeftAlone() {
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "kiro", model: "sonnet"),
                       "sonnet")
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
