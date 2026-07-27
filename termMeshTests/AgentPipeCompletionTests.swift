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

    /// The failure a real codex turn produced.
    ///
    /// It answered `STATUS: DONE|FILES: none|VERIFY: n/a|NEXT: NONE|
    /// FULL_REPORT: n/a` on one line, and a line-based parser reads that status
    /// as everything after "DONE". The cause was the template writing
    /// `DONE|BLOCKED|NEEDS_REVIEW`, where the bar means "pick one" — codex read
    /// it as the separator. That wording is fixed; this is the safety net,
    /// because models improvise.
    func testAHeaderPackedOntoOneLineStillParses() {
        let event = AgentPipeCompletion.headerEvent(
            from: "내 CLI는 Codex CLI입니다.\n\nSTATUS: DONE|FILES: none|VERIFY: n/a|NEXT: NONE|FULL_REPORT: n/a")
        XCTAssertEqual(event.status, "DONE")
        XCTAssertEqual(event.files, "none")
        XCTAssertEqual(event.next, "NONE")
    }

    /// A pipeline in a VERIFY command is not a packed header. Splitting on
    /// every bar would cut the command in half.
    func testAPipeInsideAFieldIsNotASeparator() {
        let event = AgentPipeCompletion.headerEvent(from: """
            STATUS: DONE
            FILES: none
            VERIFY: swift build 2>&1 | grep error
            NEXT: NONE
            FULL_REPORT: n/a
            """)
        XCTAssertEqual(event.verify, "swift build 2>&1 | grep error")
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

    /// Taking the channel took the keyboard with it.
    ///
    /// On the typing path the pane *was* the agent's stdin, so a person could
    /// always break in mid-session — half of what makes a running agent
    /// watchable. On the pipe the agent reads a FIFO and nothing reads the
    /// terminal, so that goes unless something gives it back. The renderer is
    /// the last stage of the pipeline and `/dev/tty` is reachable from there
    /// regardless of redirection, so it reads the keys and writes them into the
    /// same FIFO — measured live: a typed question answered from the context of
    /// a turn the leader had sent.
    func testTheRendererIsGivenThePipeSoAPersonCanBreakIn() {
        let cmd = AgentPipeTransport.launchCommand(
            claudePath: "/usr/local/bin/claude",
            fifoPath: "/tmp/pipes/executor@team.stdin",
            model: "sonnet",
            instructions: "",
            extraArgs: [],
            rendererPath: "/repo/scripts/spike/tm-render-claude.py"
        )
        XCTAssertTrue(cmd.contains("tm-render-claude.py'\'' --fifo")
                      || cmd.contains("tm-render-claude.py") && cmd.contains("--fifo"),
                      "without the pipe the renderer has nowhere to put what is typed")
    }

    // MARK: - Which agents are on a pipe

    /// The regression this replaces.
    ///
    /// Delivery used to ask whether the FIFO existed. A team's first
    /// instruction goes out while the panes are still starting, so for the
    /// first second the answer is no — and the code read that as "not on a
    /// pipe" and typed instead. Typing at a `--print` process reaches nobody:
    /// it reads its stdin and never the terminal. The text vanished and the
    /// send reported success. Measured: `explorer` never received its init
    /// prompt while `executor`, launched four seconds later, did.
    func testAnAgentIsOnAPipeFromLaunch_notFromWhetherItsFifoExistsYet() {
        let id = "explorer@pipe-test"
        AgentPipeTransport.forgetDriven(agentId: id)
        XCTAssertFalse(AgentPipeTransport.isDriven(agentId: id))

        AgentPipeTransport.markDriven(agentId: id)
        XCTAssertTrue(AgentPipeTransport.isDriven(agentId: id),
                      "the pane is on the pipe before it has made the pipe")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AgentPipeTransport.fifoPath(agentId: id)),
            "and that is exactly the window the old check got wrong")

        AgentPipeTransport.discard(agentId: id)
        XCTAssertFalse(AgentPipeTransport.isDriven(agentId: id),
                       "a torn-down agent is not still on a pipe")
    }

    // MARK: - Which shapes the bridge covers

    /// Three shapes, one vocabulary.
    ///
    /// Claude writes NDJSON to stdin, so a FIFO is the whole delivery. Codex
    /// and kiro are request/response — an id comes back that every later turn
    /// must carry — so delivering means reading the replies, which a one-way
    /// pipe cannot do. Cursor and agy have no stdin channel at all: a turn is a
    /// process, resumed by an id handed back in the answer (cursor) or
    /// announced in a log file (agy). Everything but claude goes behind the
    /// bridge, so upstream only ever sees claude's events.
    func testEveryCliBehindTheBridgeIsStillSupported() {
        for cli in ["codex", "kiro", "cursor", "agy"] {
            XCTAssertTrue(AgentPipeTransport.needsBridge(cli: cli), cli)
            XCTAssertTrue(AgentPipeTransport.supports(cli: cli), cli)
        }
        XCTAssertTrue(AgentPipeTransport.supports(cli: "claude"))
        XCTAssertFalse(AgentPipeTransport.needsBridge(cli: "claude"),
                       "a FIFO is claude's whole delivery")
    }

    /// A turn-per-process CLI has no interactive UI to host and no stdin to
    /// type into, so the pane path cannot run one at all.
    func testTurnPerProcessClisExistOnlyOnThePipe() {
        XCTAssertTrue(AgentPipeTransport.isPipeOnly(cli: "cursor"))
        XCTAssertTrue(AgentPipeTransport.isPipeOnly(cli: "agy"))
        for cli in ["claude", "codex", "kiro", "gemini"] {
            XCTAssertFalse(AgentPipeTransport.isPipeOnly(cli: cli),
                           "\(cli) has a pane path and must keep it")
        }
    }

    func testAgentsAreTrackedApart() {
        AgentPipeTransport.markDriven(agentId: "a@t")
        AgentPipeTransport.forgetDriven(agentId: "b@t")
        XCTAssertTrue(AgentPipeTransport.isDriven(agentId: "a@t"))
        XCTAssertFalse(AgentPipeTransport.isDriven(agentId: "b@t"))
        AgentPipeTransport.forgetDriven(agentId: "a@t")
    }

    func testTaskResultsKeepDuplicateAgentInstancesSeparateAndRejectMismatch() throws {
        let team = "result-instance-test-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let first = TeamDataStore.AgentRegistration(name: "executor", instanceId: "instance-a")
        let second = TeamDataStore.AgentRegistration(name: "executor", instanceId: "instance-b")
        store.registerTeam(team, agents: [first, second])
        defer {
            store.clearResults(teamName: team)
            store.unregisterTeam(team)
        }

        let taskA = try XCTUnwrap(store.createTask(teamName: team, title: "A", assignee: "executor"))
        // Re-register with the second duplicate first, mirroring panel-targeted
        // assignment selection for the next task.
        store.registerTeam(team, agents: [second, first])
        let taskB = try XCTUnwrap(store.createTask(teamName: team, title: "B", assignee: "executor"))
        XCTAssertEqual(taskA.assigneeInstanceId, "instance-a")
        XCTAssertEqual(taskB.assigneeInstanceId, "instance-b")

        XCTAssertTrue(store.writeResult(teamName: team, agentName: "executor",
                                        agentInstanceId: "instance-a", taskId: taskA.id,
                                        content: "A done"))
        XCTAssertTrue(store.writeResult(teamName: team, agentName: "executor",
                                        agentInstanceId: "instance-b", taskId: taskB.id,
                                        content: "B done"))
        XCTAssertFalse(store.writeResult(teamName: team, agentName: "executor",
                                         agentInstanceId: "instance-a", taskId: taskB.id,
                                         content: "wrong pane"))

        let results = store.collectResults(teamName: team)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.compactMap { $0["task_id"] as? String }), Set([taskA.id, taskB.id]))
    }

    func testExactInstanceClaimSkipsBusySiblingAndCompensatesOnlyItsOwnDelivery() throws {
        let team = "claim-instance-test-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let first = TeamDataStore.AgentRegistration(name: "executor", instanceId: "instance-a")
        let second = TeamDataStore.AgentRegistration(name: "executor", instanceId: "instance-b")
        store.registerTeam(team, agents: [first, second])
        defer { store.unregisterTeam(team) }

        let task = try XCTUnwrap(store.createTask(teamName: team, title: "pooled"))
        store.setAgentBusy(teamName: team, agentName: "executor", agentInstanceId: "instance-b", busy: true)
        XCTAssertNil(
            store.claimTask(teamName: team, agentName: "executor", agentInstanceId: "instance-b"),
            "a busy duplicate must not be selected for auto-claim"
        )

        let claimed = try XCTUnwrap(
            store.claimTask(teamName: team, agentName: "executor", agentInstanceId: "instance-a")
        )
        XCTAssertEqual(claimed.id, task.id)
        XCTAssertEqual(claimed.assigneeInstanceId, "instance-a")

        // A stale completion for the sibling cannot release this exact claim.
        XCTAssertNil(store.releaseClaim(
            teamName: team, taskId: task.id, assigneeInstanceId: "instance-b"
        ))
        let released = try XCTUnwrap(store.releaseClaim(
            teamName: team, taskId: task.id, assigneeInstanceId: "instance-a"
        ))
        XCTAssertNil(released.assignee)
        XCTAssertNil(released.assigneeInstanceId)
        XCTAssertEqual(released.status, "queued")
    }

    func testStatusAndResultRowsPreserveDuplicateInstanceTaskAttribution() throws {
        let team = "status-instance-test-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [
            .init(name: "executor", instanceId: "instance-a"),
            .init(name: "executor", instanceId: "instance-b"),
        ])
        defer { store.unregisterTeam(team) }

        let first = try XCTUnwrap(store.createTask(
            teamName: team, title: "A", assignee: "executor", assigneeInstanceId: "instance-a"
        ))
        let second = try XCTUnwrap(store.createTask(
            teamName: team, title: "B", assignee: "executor", assigneeInstanceId: "instance-b"
        ))
        XCTAssertEqual(
            store.agentDataEnrichment(teamName: team, agentName: "executor", agentInstanceId: "instance-a")["active_task_id"] as? String,
            first.id
        )
        XCTAssertEqual(
            store.agentDataEnrichment(teamName: team, agentName: "executor", agentInstanceId: "instance-b")["active_task_id"] as? String,
            second.id
        )

        let rows = store.resultStatus(teamName: team)["agents"] as? [[String: Any]]
        XCTAssertEqual(Set(rows?.compactMap { $0["agent_instance_id"] as? String } ?? []), Set(["instance-a", "instance-b"]))
        XCTAssertEqual(Set(rows?.compactMap { $0["task_id"] as? String } ?? []), Set([first.id, second.id]))
    }

    func testTaskTelemetryIsAdditiveAndContainsNoPromptOrResultBody() throws {
        let team = "telemetry-test-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [.init(name: "executor", instanceId: "instance-a")])
        defer { store.unregisterTeam(team) }

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "secret title", details: "secret prompt",
            assignee: "executor", assigneeInstanceId: "instance-a"
        ))
        let row = store.taskDictionary(task)
        let telemetry = try XCTUnwrap(row["parallel_telemetry"] as? [String: Any])
        XCTAssertEqual(telemetry["task_id"] as? String, task.id)
        XCTAssertEqual(telemetry["agent_instance_id"] as? String, "instance-a")
        XCTAssertNotNil(telemetry["wave_id"])
        XCTAssertNotNil(telemetry["host"])
        XCTAssertFalse(telemetry.values.contains { "\($0)".contains("secret") })
    }

    /// The bug this pins: the plain pipe/bridge completion path (claude
    /// without a native panel, or codex/kiro/cursor/agy behind the bridge)
    /// read a turn's end off `.events` and called `AutoReplyEmit.emit`
    /// without an `agentInstanceId` at all — unlike the native-panel and
    /// remote-agent paths, which always pass theirs. For a duplicate-role
    /// task carrying a real `assigneeInstanceId`, that `nil` can never equal
    /// the expected instance, so the completion is silently dropped: the
    /// task sits open forever even though the agent finished and said so.
    func testPipeCompletionWithoutInstanceIdIsRejectedAgainstADuplicateTask() throws {
        let team = "mixed-transport-test-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [
            .init(name: "executor", instanceId: "instance-a"),
            .init(name: "executor", instanceId: "instance-b"),
        ])
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "pooled", assignee: "executor", assigneeInstanceId: "instance-a"
        ))

        // What the buggy pipe path did: no agentInstanceId at all.
        let droppedByMissingInstance = AutoReplyEmit.emit(
            teamName: team, agentName: "executor",
            event: AutoReplyEvent(status: "DONE", files: "none", verify: "n/a",
                                   next: "NONE", fullReport: "n/a", body: "", raw: ""),
            preferredTaskId: task.id, agentInstanceId: nil, store: store
        )
        XCTAssertFalse(droppedByMissingInstance,
                       "a completion with no instance must not close a task that names one")
        XCTAssertEqual(store.collectResults(teamName: team).count, 0,
                       "the missing-instance turn must not have filed a result either")

        // The fixed path: the watch now carries the instance it was opened for.
        let closedByMatchingInstance = AutoReplyEmit.emit(
            teamName: team, agentName: "executor",
            event: AutoReplyEvent(status: "DONE", files: "none", verify: "n/a",
                                   next: "NONE", fullReport: "n/a", body: "", raw: ""),
            preferredTaskId: task.id, agentInstanceId: "instance-a", store: store
        )
        XCTAssertTrue(closedByMatchingInstance)
    }

    /// Backward compatibility for the common case: a team with no duplicate
    /// role names never populates `assigneeInstanceId`, and the pipe
    /// completion path must keep closing those tasks exactly as it did
    /// before instance tracking existed — a `nil` reported against a `nil`
    /// expectation is still a match, not a mismatch.
    func testPipeCompletionStillClosesUniqueNameTasksWithNoInstanceTracking() throws {
        let team = "unique-name-test-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [.init(name: "executor", instanceId: nil)])
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }

        let task = try XCTUnwrap(store.createTask(teamName: team, title: "solo", assignee: "executor"))
        XCTAssertNil(task.assigneeInstanceId, "a non-duplicate assignment tracks no instance")

        let closed = AutoReplyEmit.emit(
            teamName: team, agentName: "executor",
            event: AutoReplyEvent(status: "DONE", files: "none", verify: "n/a",
                                   next: "NONE", fullReport: "n/a", body: "", raw: ""),
            preferredTaskId: task.id, agentInstanceId: nil, store: store
        )
        XCTAssertTrue(closed, "no duplicates in play means nil vs nil is a legitimate match")
    }

    /// The unsafe half of the same legacy allowance: two siblings sharing a
    /// name with neither tracking an instance id are exactly as
    /// indistinguishable from each other as they would be with tracking
    /// turned off entirely. Letting a `nil` report clear a `nil` expectation
    /// here would let either duplicate close the other's task, so the
    /// shared attribution gate must refuse it rather than guess.
    func testNilIdentityIsRejectedWhenTheNameHasDuplicates() throws {
        let team = "duplicate-nil-test-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [
            .init(name: "executor", instanceId: nil),
            .init(name: "executor", instanceId: nil),
        ])
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }

        let task = try XCTUnwrap(store.createTask(teamName: team, title: "ambiguous", assignee: "executor"))
        XCTAssertNil(task.assigneeInstanceId, "auto-resolution finds no single instance to pin among duplicates")

        let closed = AutoReplyEmit.emit(
            teamName: team, agentName: "executor",
            event: AutoReplyEvent(status: "DONE", files: "none", verify: "n/a",
                                   next: "NONE", fullReport: "n/a", body: "", raw: ""),
            preferredTaskId: task.id, agentInstanceId: nil, store: store
        )
        XCTAssertFalse(closed, "nil cannot be trusted to mean 'the same one' when two siblings share it")
        XCTAssertEqual(store.collectResults(teamName: team).count, 0)
    }

    func testDuplicateRolePoolPrefersIdleThenAdvancesDeterministically() {
        // Instance 0 is busy, so cursor 0 must skip it and select instance 1.
        let first = try! XCTUnwrap(TeamOrchestrator.nextEligiblePoolIndex(
            candidateCount: 3, cursor: 0, isEligible: { $0 != 0 }
        ))
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.nextCursor, 2)

        // After assigning instance 1, it becomes ineligible in the same
        // serial scheduling turn. The next request cannot duplicate it.
        let second = try! XCTUnwrap(TeamOrchestrator.nextEligiblePoolIndex(
            candidateCount: 3, cursor: first.nextCursor, isEligible: { $0 == 2 }
        ))
        XCTAssertEqual(second.index, 2)
        XCTAssertEqual(second.nextCursor, 0)

        // A wrap returns to the original idle instance in stable roster order.
        let third = try! XCTUnwrap(TeamOrchestrator.nextEligiblePoolIndex(
            candidateCount: 3, cursor: second.nextCursor, isEligible: { $0 == 1 }
        ))
        XCTAssertEqual(third.index, 1)
    }
}
