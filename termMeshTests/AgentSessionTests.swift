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

    func testLeaderParallelPolicyRendersStableVersionAndDigest() {
        let first = LeaderParallelPolicy.renderedInstructions
        let second = LeaderParallelPolicy.renderedInstructions

        XCTAssertEqual(LeaderParallelPolicy.version, "3")
        XCTAssertEqual(LeaderParallelPolicy.activation, "runtime-enforced")
        XCTAssertEqual(first, second)
        XCTAssertEqual(LeaderParallelPolicy.digest.count, 64)
        XCTAssertTrue(LeaderParallelPolicy.digest.allSatisfy { $0.isHexDigit })
        XCTAssertTrue(first.contains("policy_version: 3"))
        XCTAssertTrue(first.contains("policy_digest: \(LeaderParallelPolicy.digest)"))
        XCTAssertTrue(first.contains("policy_activation: runtime-enforced"))
    }

    func testLeaderParallelPolicyContainsEveryRequiredRoutingRule() {
        let policy = LeaderParallelPolicy.renderedInstructions

        [
            "parallel-default",
            "dag-readiness",
            "unified-placement-pool",
            "same-checkout-isolation",
            "branch-merge-boundary",
            "isolated-checkout-ref-contract",
            "policy-parity",
            "timebox-convergence",
        ].forEach { XCTAssertTrue(policy.contains("[\($0)]"), "missing \($0)") }
        XCTAssertTrue(policy.contains("This policy is active."))
    }

    func testLeaderParallelPolicyUsesOneCanonicalLaunchDirective() {
        let directive = LeaderParallelPolicy.launchDirective(promptFile: "/tmp/policy.md")

        XCTAssertTrue(directive.contains("/tmp/policy.md"))
        XCTAssertTrue(directive.contains("version \(LeaderParallelPolicy.version)"))
        XCTAssertTrue(directive.contains("digest \(LeaderParallelPolicy.digest)"))
        XCTAssertTrue(directive.contains("canonical Leader Parallel Routing Policy"))
    }

    /// Two same-named instances used to both write `<agent>-reply.md`,
    /// silently losing whichever one finished first.
    func testFileReportWritesPerInstanceAliasWhenInstanceIDIsKnown() {
        let team = "fileReport-test-\(UUID().uuidString.prefix(8))"
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".term-mesh/results", isDirectory: true)
            .appendingPathComponent(team, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        TeamOrchestrator.fileReport(teamName: team, agentName: "reviewer",
                                     agentInstanceId: "inst-1", taskId: nil, text: "first")
        TeamOrchestrator.fileReport(teamName: team, agentName: "reviewer",
                                     agentInstanceId: "inst-2", taskId: nil, text: "second")

        let first = try? String(contentsOf: dir.appendingPathComponent("reviewer-inst-1-reply.md"), encoding: .utf8)
        let second = try? String(contentsOf: dir.appendingPathComponent("reviewer-inst-2-reply.md"), encoding: .utf8)
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")

        let nameOnlyExists = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("reviewer-reply.md").path)
        XCTAssertFalse(nameOnlyExists,
                       "an instance-identified report must not also write the collidable name-only file")
    }

    /// The name-only file remains the legacy path for an agent with no
    /// instance ID to disambiguate — nothing else writes there to collide.
    func testFileReportFallsBackToNameOnlyWithoutAnInstanceID() {
        let team = "fileReport-test-\(UUID().uuidString.prefix(8))"
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".term-mesh/results", isDirectory: true)
            .appendingPathComponent(team, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        TeamOrchestrator.fileReport(teamName: team, agentName: "solo",
                                     taskId: "task-123", text: "legacy")

        let legacy = try? String(contentsOf: dir.appendingPathComponent("solo-reply.md"), encoding: .utf8)
        let task = try? String(contentsOf: dir.appendingPathComponent("task-123.md"), encoding: .utf8)
        XCTAssertEqual(legacy, "legacy")
        XCTAssertEqual(task, "legacy")
    }

    private func agentMember(name: String = "executor") -> TeamOrchestrator.AgentMember {
        TeamOrchestrator.AgentMember(
            id: "\(name)@identity-test",
            name: name,
            teamName: "identity-test",
            cli: "claude",
            launchCommand: "claude",
            model: "sonnet",
            agentType: "executor",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: nil,
            parentSessionId: nil,
            claudeSessionId: nil,
            claudeSessionIdCapturedAt: nil,
            createdAt: Date(),
            worktreeName: nil,
            worktreePath: nil,
            worktreeBranch: nil,
            remoteSurfaceID: nil,
            remoteSurfaceSpawned: false,
            hostKey: nil,
            originalSpawnCommand: nil,
            originalAgentWorkDir: nil,
            autoRecycleEvery: nil,
            completedTaskCount: 0
        )
    }

    /// A duplicate role is a valid pool. Runtime resources cannot use
    /// `role@team`: pane recreation changes panelId, while two live instances
    /// need distinct transport paths at the same time.
    func testDuplicateNameCandidatesReceiveDistinctNonEmptyInstanceIDs() {
        let first = agentMember()
        let duplicate = agentMember()

        XCTAssertEqual(first.name, duplicate.name)
        XCTAssertFalse(first.agentInstanceId.isEmpty)
        XCTAssertFalse(duplicate.agentInstanceId.isEmpty)
        XCTAssertNotEqual(first.agentInstanceId, duplicate.agentInstanceId)
        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertNotEqual(first.transportId, duplicate.transportId)
        XCTAssertNotEqual(
            AgentPipeTransport.fifoPath(agentId: first.transportId),
            AgentPipeTransport.fifoPath(agentId: duplicate.transportId)
        )
        XCTAssertNotNil(UUID(uuidString: first.agentInstanceId))
        XCTAssertNotNil(UUID(uuidString: duplicate.agentInstanceId))
    }

    func testRecycleKeepsInstanceIDButReattachGetsANewOne() {
        let original = agentMember()
        var recycled = agentMember()
        recycled.agentInstanceId = original.agentInstanceId // hard restart swap contract
        let reattached = agentMember() // detach removes the old member first

        XCTAssertEqual(recycled.agentInstanceId, original.agentInstanceId)
        XCTAssertNotEqual(reattached.agentInstanceId, original.agentInstanceId)
    }

    func testCheckoutContractUsesRefsWithoutRejectingIsolatedBranch() {
        let lines = TeamOrchestrator.checkoutContractLines(
            targetBranch: "feat/distributed-workspaces",
            checkoutBranch: "agent/reviewer-260729",
            checkoutPath: "/app/tm-projects/term-mesh-reviewer-260729"
        )
        let contract = lines.joined(separator: "\n")

        XCTAssertTrue(contract.contains("PROJECT_TARGET_REF: origin/feat/distributed-workspaces"))
        XCTAssertTrue(contract.contains("AGENT_CHECKOUT_BRANCH: agent/reviewer-260729"))
        XCTAssertTrue(contract.contains("Never block solely because"))
        XCTAssertTrue(contract.contains("inspect explicit refs directly"))
        XCTAssertTrue(contract.contains("Do not checkout, reset, merge, or rebase"))
    }

    func testRemoteClaudeLaunchUsesSSHAndKeepsRemoteDirectoryOutOfLocalProcess() {
        let launch = AgentSession.remoteClaudeLaunch(
            sshTarget: "root@jw-server",
            port: 2222,
            identityFile: "/tmp/key file",
            model: "sonnet",
            instructions: "review 'carefully'",
            workingDirectory: "/app/project with space",
            remoteEnvironment: [
                "TERMMESH_SOCKET": "/run/user/0/tm-peer.sock",
                "TERMMESH_AGENT_NAME": "executor",
            ]
        )

        XCTAssertEqual(launch.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(launch.arguments.prefix(4)),
                       ["-T", "-o", "BatchMode=yes", "-o"])
        XCTAssertTrue(launch.arguments.contains("2222"))
        XCTAssertTrue(launch.arguments.contains("/tmp/key file"))
        XCTAssertEqual(launch.arguments.dropLast().last, "root@jw-server")
        XCTAssertTrue(launch.arguments.last?.contains("mkdir -p '/app/project with space'") == true)
        XCTAssertTrue(launch.arguments.last?.contains("claude") == true)
        XCTAssertTrue(launch.arguments.last?.contains("--print") == true)
        XCTAssertTrue(launch.arguments.last?.contains("IS_SANDBOX=1") == true)
        XCTAssertTrue(launch.arguments.last?.contains(
            "TERMMESH_SOCKET=/run/user/0/tm-peer.sock"
        ) == true)
        XCTAssertTrue(launch.arguments.last?.contains(
            "TERMMESH_AGENT_NAME=executor"
        ) == true)
        XCTAssertTrue(launch.arguments.last?.contains(
            "$HOME/.local/bin:/opt/homebrew/bin"
        ) == true)
        XCTAssertTrue(launch.arguments.last?.contains("review") == true)
        XCTAssertNotEqual(launch.workingDirectory, "/app/project with space")
    }

    func testRemoteBridgeLaunchDescribesSSHChildWithoutMovingLocalBridgeCwd() throws {
        let launch = AgentSession.remoteBridgeLaunch(
            cli: "codex",
            bridgePath: "/bundle/tm-agent-bridge.py",
            model: "gpt-5",
            sshTarget: "root@peer",
            port: nil,
            identityFile: nil,
            workingDirectory: "/remote/repo",
            remoteEnvironment: [
                "TERMMESH_SOCKET": "/tmp/peer.sock",
                "TERMMESH_AGENT_NAME": "reviewer",
            ],
            environment: [:]
        )

        XCTAssertEqual(launch.executable, "/usr/bin/env")
        XCTAssertEqual(launch.environment["TERMMESH_REMOTE_NATIVE_CWD"], "/remote/repo")
        let encoded = try XCTUnwrap(
            launch.environment["TERMMESH_REMOTE_NATIVE_SSH_ARGS"]?.data(using: .utf8)
        )
        let ssh = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String]
        )
        XCTAssertEqual(ssh.first, "/usr/bin/ssh")
        XCTAssertEqual(ssh.last, "root@peer")
        let envData = try XCTUnwrap(
            launch.environment["TERMMESH_REMOTE_NATIVE_ENV"]?.data(using: .utf8)
        )
        let remoteEnv = try XCTUnwrap(
            JSONSerialization.jsonObject(with: envData) as? [String: String]
        )
        XCTAssertEqual(remoteEnv["TERMMESH_SOCKET"], "/tmp/peer.sock")
        XCTAssertEqual(remoteEnv["TERMMESH_AGENT_NAME"], "reviewer")
        XCTAssertNotEqual(launch.workingDirectory, "/remote/repo")
    }

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

    // MARK: - What the review found

    /// A pipe read ends wherever the kernel handed the buffer over, which can
    /// be the middle of a multi-byte character. Decoding each chunk on arrival
    /// and dropping it when that fails loses the whole chunk — and if the line
    /// it lands in is `result`, the turn never ends at all.
    func testALineSplitMidCharacterStillArrivesWhole() throws {
        var ended: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { text, _, _ in ended.append(text) }
        let line = event(["type": "result", "stop_reason": "end_turn",
                          "result": "감귤류 재배의 역사는 길다"])
        var bytes = Array(Data((line + "\n").utf8))
        // Cut inside the first Korean character.
        let cut = bytes.firstIndex(of: 0xEA) ?? (bytes.count / 2)
        let head = Data(bytes[..<(cut + 1)])
        let tail = Data(bytes[(cut + 1)...])
        s.consumeForTesting(head)
        XCTAssertTrue(ended.isEmpty, "half a character is not a line")
        s.consumeForTesting(tail)
        XCTAssertEqual(ended, ["감귤류 재배의 역사는 길다"])
    }

    /// Several lines in one read, and a trailing partial that waits.
    func testWholeLinesArriveEvenWhenTheLastOneIsPartial() {
        let s = AgentSession()
        let a = event(["type": "assistant", "message": ["content": [["type": "text", "text": "one"]]]])
        let b = event(["type": "assistant", "message": ["content": [["type": "text", "text": "two"]]]])
        s.consumeForTesting(Data((a + "\n" + b + "\n" + "{\"partial").utf8))
        XCTAssertEqual(s.entries.count, 2)
    }

    /// A person typing in the composer opens a turn too. This used to be set
    /// only for leader writes, so a task arriving during a person's turn went
    /// straight into the same stdin and took `currentTaskId` with it — the
    /// person's result would then close the leader's task.
    func testALeaderTaskWaitsBehindAPersonsTurn() throws {
        var answered: [String?] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, task in answered.append(task) }
        s.openTurnForTesting(from: .person)
        s.queueForTesting("TASK_ID: abc12345\ndo the thing")

        // The person's turn ends first, and it answers no task.
        s.ingestForTesting(event(["type": "result", "result": "person answer"]))
        XCTAssertEqual(answered, [nil], "a person's turn carries no task")
    }

    /// If the process dies mid-turn its task would sit `in_progress` forever
    /// and everything queued behind it would never be delivered.
    func testAProcessThatDiesMidTurnEndsTheTurn() {
        var reported: [(String, String?)] = []
        let s = AgentSession()
        s.onTurnEnd = { text, _, task in reported.append((text, task)) }
        s.openTurnForTesting(from: .leader, taskId: "e82188a0")
        s.finishForTesting(code: 1)

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.1, "e82188a0")
        // No STATUS in that text, so it reads as NEEDS_REVIEW rather than a
        // success: nobody said it worked and the agent is not there to say.
        XCTAssertEqual(AgentPipeCompletion.headerEvent(from: reported.first!.0).status,
                       "NEEDS_REVIEW")
    }

    /// Process termination and the last readability callback are independent.
    /// The result must be consumed before exit is classified, exactly once.
    func testNaturalExitDrainsTheFinalResultBeforeFinishing() async {
        var reported: [(String, String, Bool)] = []
        let s = AgentSession()
        s.onTurnEnd = { text, end, _ in
            reported.append((text, end.stop, end.failed))
        }
        s.openTurnForTesting(from: .leader, taskId: "drain-final-result")
        s.start(shortProcess(output: event([
            "type": "result", "stop_reason": "end_turn",
            "result": "the final frame survived",
        ])))

        let stopped = await waitUntil { !s.isRunning }
        XCTAssertTrue(stopped)
        XCTAssertEqual(reported.count, 1, "exit must not emit a second turn end")
        XCTAssertEqual(reported.first?.0, "the final frame survived")
        XCTAssertEqual(reported.first?.1, "end_turn")
        XCTAssertEqual(reported.first?.2, false)
    }

    /// Both natural finish and deliberate stop release `process`, so one model
    /// can start another process instead of remaining permanently stopped.
    func testFinishedAndStoppedSessionsCanRestart() async {
        var answers: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { text, _, _ in answers.append(text) }

        s.openTurnForTesting(from: .person)
        s.start(shortProcess(output: event([
            "type": "result", "stop_reason": "end_turn", "result": "first",
        ])))
        let firstStopped = await waitUntil { !s.isRunning }
        XCTAssertTrue(firstStopped)

        s.start(.init(
            executable: "/bin/sleep", arguments: ["30"],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))
        XCTAssertTrue(s.isRunning)
        s.stop()
        s.stop() // teardown is intentionally idempotent
        XCTAssertFalse(s.isRunning)

        // A synchronous launch error uses the same teardown and must not leave
        // the session's process guard occupied either.
        s.start(.init(
            executable: "/definitely/not/a/real/agent", arguments: [],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))
        XCTAssertFalse(s.isRunning)

        s.openTurnForTesting(from: .person)
        s.start(shortProcess(output: event([
            "type": "result", "stop_reason": "end_turn", "result": "second",
        ])))
        let secondStopped = await waitUntil { !s.isRunning }
        XCTAssertTrue(secondStopped)
        XCTAssertEqual(answers, ["first", "second"])
    }

    /// If a spawned process leaves a grandchild holding the write end of
    /// stdout open, natural EOF never arrives. A blocking tail read on
    /// termination would then wedge the stream queue, and a `stop()` that
    /// synchronously waits on that queue would freeze MainActor forever.
    func testStopDoesNotWaitForInheritedStdoutWriter() async {
        let s = AgentSession()
        s.start(.init(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' HUP; sleep 5 & exec /usr/bin/true"],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))

        // The owned process has exited; its descendant still owns stdout.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let began = Date()
        s.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
        XCTAssertFalse(s.isRunning)

        // Teardown stays idempotent and actor-visible restart is immediate.
        s.stop()
        s.openTurnForTesting(from: .person)
        s.start(shortProcess(output: event([
            "type": "result", "stop_reason": "end_turn", "result": "restarted",
        ])))
        let stopped = await waitUntil { !s.isRunning }
        XCTAssertTrue(stopped)
    }

    private func shortProcess(output: String) -> AgentSession.Launch {
        .init(
            executable: "/bin/echo", arguments: [output],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// The bridge command the terminal path builds had neither.
    func testTheTerminalBridgeCarriesTheModelAndThePath() {
        let cmd = AgentPipeTransport.bridgeLaunchCommand(
            cli: "codex", fifoPath: "/tmp/p/x.stdin",
            model: TeamOrchestrator.bridgeModelArg(cli: "codex", model: "sonnet"),
            cliPath: "/opt/homebrew/bin/codex",
            bridgePath: "/repo/bridge.py", rendererPath: nil,
            workingDirectory: "/tmp")
        XCTAssertTrue(cmd.contains("gpt-5.6-sol"), "a tier is not a model codex knows")
        XCTAssertFalse(cmd.contains("sonnet"))
        XCTAssertTrue(cmd.contains("--exe"))
        XCTAssertTrue(cmd.contains("/opt/homebrew/bin/codex"))
    }

    /// `markDriven` had no counterpart, so a name kept its pipe registration
    /// after its pane was gone and a later terminal-hosted agent of the same
    /// name had every send routed to a FIFO that no longer existed.
    func testReleasingAnAgentUndoesItsRegistration() {
        let id = "reviewer@release-test"
        AgentPipeTransport.markDriven(agentId: id)
        XCTAssertTrue(AgentPipeTransport.isDriven(agentId: id))
        TeamOrchestrator.releaseTransport(agentId: id)
        XCTAssertFalse(AgentPipeTransport.isDriven(agentId: id))
    }

    // MARK: - A turn is one thing

    private var say: AgentSession.Entry { .said(id: UUID(), .leader, "do it") }
    private var think: AgentSession.Entry { .thought(id: UUID(), "hm") }
    private var toolRow: AgentSession.Entry {
        .tool(id: UUID(), .init(name: "Bash", headline: "ls"))
    }
    private var answer: AgentSession.Entry { .answered(id: UUID(), "done") }
    private var footer: AgentSession.Entry {
        .turnEnded(id: UUID(), .init(stop: "end_turn", failed: false, cost: nil,
                                     duration: nil, tokensIn: nil, tokensOut: nil))
    }

    /// At one gap for everything, a turn's five parts read as five unrelated
    /// rows. Tight inside a turn, open between them.
    func testATurnIsSpacedAsOneThing() {
        let inside = AgentSession.topGap(before: answer, after: think)
        let footerGap = AgentSession.topGap(before: footer, after: answer)
        let between = AgentSession.topGap(before: say, after: footer)

        XCTAssertLessThan(footerGap, inside, "a footer closes the answer above it")
        XCTAssertGreaterThan(between, inside, "a new turn needs room")
        // Reasoning and the tools it drives are one train of thought.
        XCTAssertLessThanOrEqual(AgentSession.topGap(before: toolRow, after: think), 4)
        XCTAssertLessThanOrEqual(AgentSession.topGap(before: toolRow, after: toolRow), 4)
    }

    /// A new instruction starts a turn wherever it lands, even mid-stream.
    func testAnInstructionAlwaysStartsATurn() {
        XCTAssertEqual(AgentSession.topGap(before: say, after: answer),
                       AgentSession.topGap(before: say, after: footer))
    }

    /// The view must not have to look at a row's neighbour, nor read identity
    /// through the enum, to lay a transcript out.
    ///
    /// Deriving either during layout is what let a `LazyVStack` placement pass
    /// re-enter itself and spin the main thread at 100% with the view graph
    /// never converging.
    func testRowsCarryTheirOwnIdentityAndSpacing() {
        let entries = [say, think, toolRow, answer, footer]
        let rows = AgentSession.rows(for: entries)

        XCTAssertEqual(rows.map(\.id), entries.map(\.id))
        // Each row's gap is the one the neighbour rule gives it, already applied.
        var previous: AgentSession.Entry?
        for (row, entry) in zip(rows, entries) {
            XCTAssertEqual(row.topGap, AgentSession.topGap(before: entry, after: previous))
            previous = entry
        }
        // The first row has no neighbour to depend on.
        XCTAssertEqual(rows.first?.topGap, AgentSession.topGap(before: say, after: nil))
        XCTAssertTrue(AgentSession.rows(for: []).isEmpty)
    }

    /// The panel uses a regular VStack to avoid SwiftUI's non-converging lazy
    /// placement path. Keep its mounted view tree bounded independently from
    /// the longer model transcript.
    func testDisplayedRowsKeepOnlyTheRecentBoundedWindow() {
        let entries = (0..<(AgentSession.maxRenderedEntries + 17)).map { index in
            AgentSession.Entry.said(id: UUID(), .leader, "instruction \(index)")
        }

        let display = AgentSession.displayRows(for: entries)

        XCTAssertEqual(display.omitted, 17)
        XCTAssertEqual(display.rows.count, AgentSession.maxRenderedEntries)
        XCTAssertEqual(display.rows.map(\.id),
                       Array(entries.suffix(AgentSession.maxRenderedEntries)).map(\.id))
        XCTAssertEqual(display.rows.first?.topGap,
                       AgentSession.topGap(before: entries[17], after: nil))
    }

    /// A streamed delta must announce itself once. `AgentPanel` forwards every
    /// `objectWillChange` the session sends, so publishing both `entries` and
    /// `revision` for one mutation rebuilt the whole transcript twice per
    /// character that arrived.
    func testAStreamedDeltaAnnouncesItselfOnce() {
        let s = session([blockStart(0, "text")])
        var announcements = 0
        let token = s.objectWillChange.sink { _ in announcements += 1 }
        defer { token.cancel() }

        s.ingestForTesting(delta(0, "half a sen"))

        XCTAssertEqual(announcements, 1, "one mutation, one announcement")
        // And the rows the view reads are already the new ones — they are
        // rebuilt before the announcement, not after it.
        XCTAssertEqual(s.rows.map(\.id), s.entries.map(\.id))
    }

    // MARK: - Stopping a turn

    /// Not a signal and not a restart. Measured: claude reads
    /// `control_request`/`interrupt` on the same stdin its turns arrive on,
    /// the turn ends in half a second, the process lives, and the next turn
    /// answers with its context intact.
    func testOnlyAMeasuredCliOffersToStopATurn() {
        let claude = AgentSession.claudeLaunch(
            claudePath: "/usr/local/bin/claude", model: "haiku",
            instructions: "", extraArgs: [], workingDirectory: "/tmp")
        XCTAssertTrue(claude.interruptible)

        // The bridged CLIs have their own cancel verbs and none of them have
        // been measured, so their panes do not offer a button that might do
        // something else.
        let bridged = AgentSession.bridgeLaunch(
            cli: "codex", bridgePath: "/repo/bridge.py", model: "gpt-5.5",
            workingDirectory: "/tmp")
        XCTAssertFalse(bridged.interruptible)
    }

    /// A turn stopped on purpose is not a failure, and should not be labelled
    /// with claude's own word for it, `error_during_execution`.
    func testAStoppedTurnReadsAsStoppedRatherThanFailed() {
        let s = session([event(["type": "result", "subtype": "error_during_execution",
                                "is_error": true, "result": ""])])
        guard case .turnEnded(_, let end) = try? XCTUnwrap(s.entries.last) else {
            return XCTFail("expected a turn end")
        }
        // Without a stop request it is exactly what claude called it.
        XCTAssertEqual(end.stop, "error_during_execution")
        XCTAssertTrue(end.failed)
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

    func testTableBecomesOneQuietStructuredBlock() {
        let blocks = AgentMarkdown.blocks("""
            | Host | Status |
            | --- | --- |
            | Mac | Ready |
            | Linux | Offline |
            """)
        guard case .table(let headers, let rows) = try? XCTUnwrap(blocks.first) else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(headers, ["Host", "Status"])
        XCTAssertEqual(rows, [["Mac", "Ready"], ["Linux", "Offline"]])
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

    // MARK: - Incremental agent pane placement

    func testFirstAgentSplitsToTheRightOfLeader() {
        let leader = UUID()
        let placement = TeamOrchestrator.nextAgentSplitPlacement(
            leaderPanelId: leader,
            candidates: []
        )

        XCTAssertEqual(placement.panelId, leader)
        XCTAssertEqual(placement.orientation.rawValue, "horizontal")
    }

    func testLateAgentSplitsLargestPaneAlongItsLongestAxis() {
        let smaller = UUID()
        let largest = UUID()
        let placement = TeamOrchestrator.nextAgentSplitPlacement(
            leaderPanelId: UUID(),
            candidates: [
                .init(panelId: smaller, width: 300, height: 300),
                .init(panelId: largest, width: 420, height: 700),
            ]
        )

        XCTAssertEqual(placement.panelId, largest)
        XCTAssertEqual(placement.orientation.rawValue, "vertical")
    }

    func testWideAgentPaneSplitsSideBySide() {
        let wide = UUID()
        let placement = TeamOrchestrator.nextAgentSplitPlacement(
            leaderPanelId: UUID(),
            candidates: [
                .init(panelId: wide, width: 700, height: 350),
            ]
        )

        XCTAssertEqual(placement.panelId, wide)
        XCTAssertEqual(placement.orientation.rawValue, "horizontal")
    }

    func testEqualAreaPlacementKeepsTeamOrderStable() {
        let first = UUID()
        let second = UUID()
        let placement = TeamOrchestrator.nextAgentSplitPlacement(
            leaderPanelId: UUID(),
            candidates: [
                .init(panelId: first, width: 400, height: 300),
                .init(panelId: second, width: 300, height: 400),
            ]
        )

        XCTAssertEqual(placement.panelId, first)
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

    /// The Claude CLI resolves its own tiers, so passing one through is what
    /// keeps an agent on the current model. Rewriting `opus` to a pinned id
    /// held every agent on the previous Opus after Opus 5 shipped — and because
    /// the pin still launched, nothing surfaced it.
    func testAClaudeTierIsLeftForTheCliToResolve() {
        for tier in ["sonnet", "opus", "fable", "haiku"] {
            XCTAssertEqual(TeamOrchestrator.resolveClaudeModelArg(tier), tier)
            XCTAssertFalse(
                AgentRolePreset.models(for: "claude").firstIndex(of: tier) == nil,
                "\(tier) must be offered by the picker"
            )
        }
        // No pinned id anywhere in what the picker offers — a version written
        // down here is one that has to be edited on every model release.
        for model in AgentRolePreset.models(for: "claude") {
            XCTAssertFalse(model.hasPrefix("claude-"), model)
        }
        // Stored before the tier list settled.
        XCTAssertEqual(TeamOrchestrator.resolveClaudeModelArg("opus-1m"), "opus")
        XCTAssertEqual(AgentRolePreset.normalizeModel("opus-1m", for: "claude"), "opus")
    }

    /// Codex takes exact ids, so the list has to match its own catalog —
    /// including the two entries in that catalog it will not run from a
    /// `--model` flag.
    func testCodexIsOfferedOnlyModelsItStillRuns() {
        let models = AgentRolePreset.models(for: "codex")
        XCTAssertTrue(models.contains("gpt-5.6-sol"))
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "codex"), "gpt-5.6-sol")
        // `supported_in_api: false` and `visibility: hide` respectively.
        XCTAssertFalse(models.contains("gpt-5.3-codex-spark"))
        XCTAssertFalse(models.contains("codex-auto-review"))
        // Gone from the catalog entirely.
        for retired in ["gpt-5.3-codex", "gpt-5.2-codex", "gpt-5.2",
                        "gpt-5.1-codex-max", "gpt-5.1-codex-mini"] {
            XCTAssertFalse(models.contains(retired), retired)
        }
    }

    /// kiro takes exact ids, so a tier only reaches the right model if this
    /// side names it — there is no family for the CLI to resolve.
    func testAKiroTierNamesAModelKiroLists() {
        let listed = AgentRolePreset.models(for: "kiro")
        for id in ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4.5", "auto"] {
            XCTAssertTrue(listed.contains(id), id)
        }
        // fable is absent because kiro does not carry it — offering a tier the
        // CLI has no model for is a launch that fails at the flag.
        XCTAssertFalse(listed.contains("fable"))
    }

    /// cursor and agy spell the reasoning level into the id rather than taking
    /// a separate flag, so every entry has to name one.
    func testTheIdBasedCliesAreOfferedNamesTheyPublish() {
        let cursor = AgentRolePreset.models(for: "cursor")
        XCTAssertTrue(cursor.contains("claude-opus-5-thinking-high"))
        XCTAssertTrue(cursor.contains("claude-fable-5-thinking-high"))
        XCTAssertTrue(cursor.contains("auto"))
        // Neither was ever in cursor's list — `gpt-5-mini` and
        // `claude-4-sonnet-thinking` are the names it actually publishes.
        XCTAssertFalse(cursor.contains("gpt-5"))
        XCTAssertFalse(cursor.contains("sonnet-4-thinking"))

        let agy = AgentRolePreset.models(for: "agy")
        XCTAssertTrue(agy.contains("gemini-3.1-pro-high"))
        XCTAssertFalse(agy.isEmpty, "agy publishes a list now — empty hid it")

        // Both still default to not passing the flag at all, which is what was
        // measured working; the list is for picking, not for a default.
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "cursor"), "")
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "agy"), "")
        // And a claude tier still never reaches either.
        for cli in ["cursor", "agy"] {
            XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: cli, model: "opus"), "", cli)
        }
    }

    // MARK: - The model a bridged CLI will take

    /// Team models are stored as claude's tiers, because that is what the
    /// picker offers for every CLI. Measured: codex took `--model sonnet`,
    /// accepted the turn, and ended it having said nothing — the empty-turn
    /// guard caught it, but the cause was here.
    func testATierNameIsTranslatedBeforeItReachesCodex() {
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "sonnet"),
                       "gpt-5.6-sol")
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "haiku"),
                       "gpt-5.6-sol")
        // A name the user typed themselves is theirs, not a tier to remap.
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "gpt-5.6-luna"),
                       "gpt-5.6-luna")
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

    /// A late result does not land on somebody else's tool row.
    ///
    /// `openTools` holds absolute indices into `entries`, so trimming from the
    /// front moves every row an equal number of places earlier. A stale index
    /// still points *somewhere*, and `closeTool`'s only guard is that the row
    /// it finds is a tool — so when the rows are tools, as they are during a
    /// long run, the result is written into an unrelated call with nothing to
    /// reject it. Every row here is a tool for exactly that reason: it is what
    /// makes the mistake silent rather than caught.
    func testAToolResultDoesNotLandOnAnotherRowAfterATrim() throws {
        let s = AgentSession()
        s.ingestForTesting(event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t1", "name": "Read",
             "input": ["file_path": "/first"]]]]]))
        for i in 0..<2_100 {
            s.ingestForTesting(event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "later-\(i)", "name": "Read",
                 "input": ["file_path": "/later/\(i)"]]]]]))
        }
        s.ingestForTesting(event(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "t1 output"]]]]))

        XCTAssertLessThanOrEqual(s.entries.count, 2_000)
        let misplaced = s.entries.contains { entry in
            guard case .tool(_, let call) = entry else { return false }
            return call.result == "t1 output" && call.headline != "/first"
        }
        XCTAssertFalse(misplaced, "a trimmed-away call's result must not be written into another row")
    }

    // MARK: - A change is a diff

    private func change(_ tool: String, _ input: [String: Any]) -> AgentDiff.Change? {
        AgentDiff.change(tool: tool, input: input)
    }

    private func edit(_ old: String, _ new: String,
                      replaceAll: Bool = false) -> AgentDiff.Change? {
        change("Edit", ["file_path": "/repo/a.swift", "old_string": old,
                        "new_string": new, "replace_all": replaceAll])
    }

    private func texts(_ change: AgentDiff.Change) -> [String] {
        change.lines.compactMap { line in
            switch line {
            case .added(_, let text): return "+" + text
            case .removed(_, let text): return "-" + text
            case .context(_, _, let text): return " " + text
            case .gap, .site: return nil
            }
        }
    }

    func testAnEditCarriesBothSidesOfWhatItChanged() throws {
        let change = try XCTUnwrap(edit("one\ntwo\n", "one\nTWO\n"))

        XCTAssertEqual(change.path, "/repo/a.swift")
        XCTAssertEqual(change.kind, .edit)
        XCTAssertEqual(texts(change), [" one", "-two", "+TWO"])
    }

    /// Painting the whole of `old_string` red and the whole of `new_string`
    /// green is wrong in the ordinary case, not the rare one: it reports a
    /// five-line change where one line moved, and hands the reader the job of
    /// finding it.
    func testOnlyTheLinesThatMovedAreCounted() throws {
        let old = "a\nb\nc\nd\ne\n"
        let new = "a\nb\nCHANGED\nd\ne\n"

        let change = try XCTUnwrap(edit(old, new))

        XCTAssertEqual(change.added, 1)
        XCTAssertEqual(change.removed, 1)
    }

    func testAWriteIsAllAddition() throws {
        let change = try XCTUnwrap(
            self.change("Write", ["file_path": "/repo/new.swift",
                                  "content": "one\ntwo\nthree\n"]))

        XCTAssertEqual(change.added, 3)
        XCTAssertEqual(change.removed, 0)
        XCTAssertEqual(change.kind, .write(created: nil))
    }

    /// Nearly every file ends in a newline, and splitting on "\n" alone gives
    /// it one line more than it has.
    func testATrailingNewlineDoesNotGainAPhantomLine() throws {
        let change = try XCTUnwrap(
            self.change("Write", ["file_path": "/repo/a.swift", "content": "a\nb\n"]))

        XCTAssertEqual(change.added, 2)
    }

    func testCrlfDoesNotLeaveACarriageReturnInTheDiff() throws {
        let change = try XCTUnwrap(edit("a\r\nb\r\n", "a\r\nB\r\n"))

        XCTAssertEqual(texts(change), [" a", "-b", "+B"])
    }

    func testMultiEditIsOneRowWithEverySiteInIt() throws {
        let change = try XCTUnwrap(self.change("MultiEdit", [
            "file_path": "/repo/a.swift",
            "edits": [["old_string": "one\n", "new_string": "ONE\n"],
                      ["old_string": "two\n", "new_string": "TWO\n"]]]))

        XCTAssertEqual(change.kind, .multiEdit(sites: 2))
        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 2)
        XCTAssertTrue(change.lines.contains(.site(1)))
    }

    /// Once the per-call budget trips, walking a diff on the rest of the
    /// edits is what the budget forbids — but counting their raw sizes is
    /// not, so a bailout row must still add every edit still to come rather
    /// than stopping at the one that tripped it.
    func testMultiEditBailoutStillCountsEveryRemainingEdit() throws {
        let big = (0..<3000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let bigChanged = (0..<3000).map { "changed \($0)" }.joined(separator: "\n") + "\n"

        let change = try XCTUnwrap(self.change("MultiEdit", [
            "file_path": "/repo/a.swift",
            "edits": [["old_string": big, "new_string": bigChanged],
                      ["old_string": "two\n", "new_string": "TWO\n"]]]))

        XCTAssertEqual(change.kind, .multiEdit(sites: 2))
        XCTAssertEqual(change.added, 3001)
        XCTAssertEqual(change.removed, 3001)
        XCTAssertTrue(change.lines.isEmpty)
        XCTAssertGreaterThan(change.elided, 0)
    }

    /// Applied everywhere, any single line number is a fiction — and so is the
    /// total, which is the per-site count times a number nobody reported.
    func testReplaceAllRefusesToClaimALineNumber() throws {
        let change = try XCTUnwrap(edit("x\n", "y\n", replaceAll: true))

        XCTAssertTrue(change.everywhere)
        for line in change.lines {
            switch line {
            case .added(let new, _): XCTAssertNil(new)
            case .removed(let old, _): XCTAssertNil(old)
            case .context(let old, let new, _):
                XCTAssertNil(old)
                XCTAssertNil(new)
            case .gap, .site: break
            }
        }
    }

    func testAToolThatEditsNothingCarriesNoChange() {
        XCTAssertNil(change("Bash", ["command": "ls -l"]))
        XCTAssertNil(change("Read", ["file_path": "/repo/a.swift"]))
        XCTAssertNil(change("Grep", ["pattern": "foo", "path": "/repo"]))
    }

    func testAnEditThatChangedNothingIsNotDrawnAsADiff() {
        XCTAssertNil(edit("same\n", "same\n"))
    }

    /// The body is cut; the counts are not. A clipped diff that also under-
    /// reports its size is worse than no diff, because it looks complete.
    func testAHugeDiffIsCutButItsCountIsNot() throws {
        let content = (0..<5000).map { "line \($0)" }.joined(separator: "\n") + "\n"

        let change = try XCTUnwrap(
            self.change("Write", ["file_path": "/repo/big.txt", "content": content]))

        XCTAssertEqual(change.added, 5000)
        XCTAssertLessThanOrEqual(change.lines.count, AgentDiff.maxLines)
        XCTAssertEqual(change.lines.count + change.elided, 5000)
    }

    func testAVeryLongLineIsCutAtItsEnd() throws {
        let long = String(repeating: "x", count: 50_000)

        let change = try XCTUnwrap(
            self.change("Write", ["file_path": "/repo/min.js", "content": long + "\n"]))

        guard case .added(_, let text) = try XCTUnwrap(change.lines.first) else {
            return XCTFail("expected an added line")
        }
        XCTAssertEqual(text.count, AgentDiff.maxLineLength)
    }

    func testAUnifiedDiffFromTheBridgeKeepsItsLineNumbers() throws {
        let patch = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -241,3 +241,4 @@ func peerRow
         before
        -let label = host.name
        +let label = host.displayName
        +let badge = "●"
        """

        let change = try XCTUnwrap(self.change("edit", [
            "file_path": "/repo/Sources/Foo.swift", "kind": "update",
            "unified_diff": patch]))

        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 1)
        guard case .context(let old, let new, _) = try XCTUnwrap(change.lines.first) else {
            return XCTFail("expected the hunk to open on context")
        }
        XCTAssertEqual(old, 241)
        XCTAssertEqual(new, 241)
    }

    /// A hunk header is a claim by a subprocess, not a measurement. Reading it
    /// as one is how a printed number becomes an allocation.
    func testAHunkHeaderIsNotTrusted() throws {
        let patch = "@@ -1,99999999 +1,99999999 @@\n-a\n+b\n"

        let change = try XCTUnwrap(self.change("edit", [
            "file_path": "/repo/a.swift", "unified_diff": patch]))

        XCTAssertEqual(change.lines.count, 2)
        XCTAssertEqual(change.added, 1)
    }

    func testAUnifiedDiffWithoutAHunkHeaderIsRefused() {
        XCTAssertNil(change("edit", ["file_path": "/repo/a.swift",
                                     "unified_diff": "not a patch at all\n"]))
        XCTAssertNil(change("edit", ["file_path": "/repo/a.swift",
                                     "unified_diff": "+orphan line\n"]))
    }

    func testADeleteFromTheBridgeIsNamedAsOne() throws {
        let change = try XCTUnwrap(self.change("delete", [
            "file_path": "/repo/gone.swift", "kind": "delete",
            "unified_diff": "@@ -1,2 +0,0 @@\n-one\n-two\n"]))

        XCTAssertEqual(change.kind, .delete)
        XCTAssertEqual(change.removed, 2)
        XCTAssertEqual(change.added, 0)
    }

    /// The contract between the bridge and this side: the same edit described
    /// either way has to come out saying the same thing happened.
    func testTheBridgeShapeAndTheClaudeShapeAgree() throws {
        let claude = try XCTUnwrap(edit("one\ntwo\nthree\n", "one\nTWO\nthree\n"))
        let bridged = try XCTUnwrap(self.change("edit", [
            "file_path": "/repo/a.swift",
            "unified_diff": "@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"]))

        XCTAssertEqual(claude.added, bridged.added)
        XCTAssertEqual(claude.removed, bridged.removed)
        XCTAssertEqual(texts(claude), texts(bridged))
    }

    func testAPathIsShownRelativeToWhereTheAgentIsWorking() {
        XCTAssertEqual(AgentDiff.short("/repo/Sources/A.swift", relativeTo: "/repo"),
                       "Sources/A.swift")
        XCTAssertEqual(AgentDiff.short("/elsewhere/A.swift", relativeTo: "/repo"),
                       "/elsewhere/A.swift")
        XCTAssertEqual(AgentDiff.short("/repo/A.swift", relativeTo: ""), "/repo/A.swift")
    }

    /// The row exists as soon as the call does. Waiting for the result meant a
    /// long edit showed nothing at all while it was being made.
    func testADiffIsVisibleBeforeTheToolHasFinished() throws {
        let s = session([event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t1", "name": "Edit",
             "input": ["file_path": "/repo/a.swift",
                       "old_string": "a\n", "new_string": "b\n"]]]]])])

        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool row")
        }
        XCTAssertTrue(call.isRunning)
        XCTAssertEqual(call.change?.added, 1)
        XCTAssertTrue(call.canExpand)
    }

    func testAWriteThatOverwroteSaysSo() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Write",
                 "input": ["file_path": "/repo/a.swift", "content": "one\n"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "The file /repo/a.swift has been updated successfully."]]]]),
        ])

        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool row")
        }
        XCTAssertEqual(call.change?.kind, .write(created: false))
    }

    func testAWriteThatCreatedSaysSo() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Write",
                 "input": ["file_path": "/repo/a.swift", "content": "one\n"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "File created successfully at: /repo/a.swift"]]]]),
        ])

        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool row")
        }
        XCTAssertEqual(call.change?.kind, .write(created: true))
    }

    /// A turn that ends with a call still open closes it with an empty result,
    /// and testing that alone took the disclosure control off rows holding a
    /// whole diff.
    func testAnEditRowStillOffersItsBodyWhenTheResultIsEmpty() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Edit",
                 "input": ["file_path": "/repo/a.swift",
                           "old_string": "a\n", "new_string": "b\n"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": ""]]]]),
        ])

        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool row")
        }
        XCTAssertFalse(call.isRunning)
        XCTAssertTrue(call.canExpand)
        XCTAssertNotNil(call.change)
    }

    func testACallWithNeitherDiffNorResultOffersNothing() {
        let call = AgentSession.ToolCall(name: "Bash", headline: "ls", result: "")

        XCTAssertFalse(call.canExpand)
    }
}
