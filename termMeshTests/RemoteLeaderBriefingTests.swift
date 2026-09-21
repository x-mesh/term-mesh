import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A peer leader that was not Claude used to receive
/// `LeaderParallelPolicy.renderedInstructions` and nothing else: how to
/// schedule work, with no team name, no roster, and no mention of
/// `tm-agent`. A codex leader came up on a peer unable to name a single
/// teammate while four of them sat idle beside it.
///
/// The tell was that placement was not the variable. A Claude leader on the
/// same host, in the same project, got the whole briefing. These tests hold
/// the two prompts to the same floor so the CLI cannot decide again what a
/// leader is told.
@MainActor
final class RemoteLeaderBriefingTests: XCTestCase {
    func test_localTUILeaderIsNotReadyUntilAComposerExists() {
        XCTAssertTrue(TeamOrchestrator.localLeaderNeedsReadinessProbe(
            launchLeaderLocally: true, leaderMode: "claude"
        ))
        XCTAssertTrue(TeamOrchestrator.localLeaderNeedsReadinessProbe(
            launchLeaderLocally: true, leaderMode: "codex"
        ))
        XCTAssertFalse(TeamOrchestrator.localLeaderNeedsReadinessProbe(
            launchLeaderLocally: true, leaderMode: "repl"
        ))
        XCTAssertFalse(TeamOrchestrator.localLeaderNeedsReadinessProbe(
            launchLeaderLocally: false, leaderMode: "claude"
        ))

        XCTAssertFalse(TeamOrchestrator.localLeaderPaneLooksReady(
            "Claude Code v2\nInitializing MCP servers…"
        ))
        XCTAssertTrue(TeamOrchestrator.localLeaderPaneLooksReady(
            "Claude Code v2\n────────\n❯ \n────────", leaderMode: "claude"
        ))
        XCTAssertTrue(TeamOrchestrator.localLeaderPaneLooksReady(
            "Codex CLI\n› Ask anything", leaderMode: "codex"
        ))
        XCTAssertTrue(TeamOrchestrator.localLeaderPaneLooksReady(
            "Codex CLI\n› Type @ to mention files", leaderMode: "codex"
        ))
        XCTAssertFalse(TeamOrchestrator.localLeaderPaneLooksReady(
            "Do you trust the contents of this directory?\n"
                + "› 1. Yes, continue\n  2. No, quit\nPress enter to continue",
            leaderMode: "codex"
        ))
        XCTAssertFalse(TeamOrchestrator.localLeaderPaneLooksReady(
            "OpenAI Codex\n› New durable request req-1\n❯ ent/any",
            leaderMode: "codex"
        ))
        XCTAssertFalse(TeamOrchestrator.localLeaderPaneLooksReady(
            "Starting tools\n> initialization detail"
        ))
        XCTAssertFalse(TeamOrchestrator.localLeaderPaneLooksReady(
            "Not logged in · Run /login\n❯ "
        ))
    }

    func test_durableWakeUsesTheExactLeaderCLIPath() {
        XCTAssertEqual(
            TeamOrchestrator.leaderRequestWake(
                requestId: "req-1", tmAgent: "'/Applications/term mesh/bin/tm-agent'"
            ),
            "New durable request req-1. First run exactly: '/Applications/term mesh/bin/tm-agent' leader request take req-1. "
                + "After the requested work succeeds, run exactly: '/Applications/term mesh/bin/tm-agent' leader request complete req-1 immediately before your final response."
        )
    }

    private func row(_ name: String, cli: String, summary: String = "") -> TeamAgentRow {
        TeamAgentRow(
            preset: AgentRolePreset(
                id: UUID(),
                name: name,
                displayName: name.capitalized,
                cli: cli,
                model: "sonnet",
                color: "blue",
                instructions: summary,
                isBuiltIn: false
            ),
            customInstructions: "",
            hostKey: "ssh:peer",
            hostDirectory: "/Users/jinwoo/work/tm-projects/xm"
        )
    }

    private var rows: [TeamAgentRow] {
        [
            row("executor", cli: "codex", summary: "Implement changes."),
            row("architect", cli: "codex", summary: "Design before code."),
            row("reviewer", cli: "codex", summary: "Review diffs."),
        ]
    }

    private func nonClaudePrompt() -> String {
        TeamOrchestrator.remoteLeaderNonClaudeSystemPrompt(
            teamName: "xm",
            rows: rows,
            remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
            remoteSocketPath: "/tmp/term-mesh.sock"
        )
    }

    // MARK: - What the leader must be told

    /// The team name is how every `tm-agent` result file is addressed. Without
    /// it the leader cannot read a single reply back.
    func test_theLeaderIsToldWhichTeamItLeads() {
        XCTAssertTrue(nonClaudePrompt().contains("'xm'"))
    }

    /// The roster is the whole difference between a leader and a lone CLI.
    func test_theLeaderIsToldWhoItsAgentsAre() {
        let exactRows = rows
        let prompt = TeamOrchestrator.remoteLeaderNonClaudeSystemPrompt(
            teamName: "xm", rows: exactRows,
            remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
            remoteSocketPath: "/tmp/term-mesh.sock"
        )
        for name in ["executor", "architect", "reviewer"] {
            XCTAssertTrue(
                prompt.contains(name),
                "the leader was never told about \(name), so it cannot delegate to it"
            )
        }
        XCTAssertTrue(prompt.contains("instance="))
        XCTAssertTrue(prompt.contains("cli=codex"))
        XCTAssertTrue(prompt.contains("model=sonnet"))
        XCTAssertTrue(prompt.contains("host=ssh:peer"))
        XCTAssertTrue(prompt.contains("mode=read-only-default"))
        XCTAssertTrue(prompt.contains("--agent-instance-id"))
        for row in exactRows {
            XCTAssertTrue(prompt.contains(row.id.uuidString), "roster lost the preallocated instance id")
        }
    }

    /// Knowing the names is useless without the verb that reaches them.
    func test_theLeaderIsToldHowToReachThem() {
        let prompt = nonClaudePrompt()
        XCTAssertTrue(prompt.contains("tm-agent delegate"))
        XCTAssertTrue(prompt.contains("tm-agent status"))
        XCTAssertTrue(prompt.contains("tm-agent wait"))
    }

    /// The peer's socket, not this machine's — the leader runs over there.
    func test_theLeaderIsToldThePeersSocket() {
        XCTAssertTrue(nonClaudePrompt().contains("TERMMESH_SOCKET=/tmp/term-mesh.sock"))
    }

    /// The routing policy was the one thing that did arrive before, and it
    /// must keep arriving — the renderer embeds it rather than replacing it.
    func test_theRoutingPolicyIsStillIncluded() {
        let prompt = nonClaudePrompt()
        XCTAssertTrue(prompt.contains("policy_version"))
        XCTAssertTrue(
            prompt.contains(LeaderParallelPolicy.renderedInstructions),
            "the fix must add the team around the policy, not swap one for the other"
        )
    }

    func test_bothLeaderKindsDecomposeFirstAndKeepDirectAsAnExplicitException() {
        let claude = TeamOrchestrator.remoteLeaderClaudeSystemPrompt(
            teamName: "xm",
            rows: rows,
            remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
            remoteSocketPath: "/tmp/term-mesh.sock"
        )
        for prompt in [claude, nonClaudePrompt()] {
            XCTAssertTrue(prompt.contains("coordinator and integration owner"))
            XCTAssertTrue(prompt.contains("begin each non-trivial request by finding independently completable units"))
            XCTAssertTrue(prompt.contains("assign eligible"))
            XCTAssertTrue(prompt.contains("before doing that work yourself"))
            XCTAssertTrue(prompt.contains("Direct execution is the explicit exception"))
            XCTAssertTrue(prompt.contains("State the concrete constraint when choosing it"))
            XCTAssertTrue(prompt.contains("at least two units are"))
            XCTAssertTrue(prompt.contains("direct, probe, or parallel"))
            XCTAssertTrue(prompt.contains("\"route\": \"direct|probe|parallel\""))
            XCTAssertTrue(prompt.contains("--worktree always --from <base_ref>"))
            XCTAssertTrue(prompt.contains("wait --mode any --tasks"))
            XCTAssertTrue(prompt.contains("at most once more"))
            XCTAssertTrue(prompt.contains("actual diff is integrated"))
            XCTAssertTrue(prompt.contains("security plus tester"))
            XCTAssertTrue(prompt.contains("differs from every implementation owner"))
            XCTAssertFalse(prompt.contains("When in doubt, DELEGATE"))
            XCTAssertFalse(prompt.contains("An idle agent is a wasted resource"))
            XCTAssertFalse(prompt.contains("Delegate IMMEDIATELY to idle agents"))
            XCTAssertFalse(prompt.contains("Always parallel when possible"))
            XCTAssertFalse(prompt.contains("do NOT analyze the problem yourself first"))
            XCTAssertFalse(prompt.contains("After each user message, check: are any agents idle?"))
            XCTAssertFalse(prompt.contains("Start single-agent"))
            XCTAssertFalse(prompt.contains("default executor"))
        }
    }

    // MARK: - The asymmetry itself

    /// The regression, stated directly: a peer leader's briefing must not
    /// depend on which CLI runs it. Comparing the two prompts is what makes
    /// this fail if either side is changed alone.
    func test_aNonClaudeLeaderIsBriefedAsWellAsAClaudeOne() {
        let claude = TeamOrchestrator.remoteLeaderClaudeSystemPrompt(
            teamName: "xm",
            rows: rows,
            remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
            remoteSocketPath: "/tmp/term-mesh.sock"
        )
        let other = nonClaudePrompt()

        for essential in ["'xm'", "executor", "architect", "reviewer",
                          "tm-agent delegate", "TERMMESH_SOCKET=/tmp/term-mesh.sock"] {
            XCTAssertTrue(claude.contains(essential), "claude prompt lost \(essential)")
            XCTAssertTrue(other.contains(essential), "non-claude prompt lost \(essential)")
        }

        // Not equality — the Claude prompt also bans Claude Code's built-in
        // team tools, which mean nothing to codex. Assert the surrounding
        // briefing sections directly instead of comparing lengths: the policy
        // includes a structured JSON schema and can legitimately be more than
        // half of a complete prompt.
        for section in ["## Your Agents", "## How to Command Agents",
                        "## Reading Agent Results", "## Task Board",
                        "## Your Workflow", "## Use Available Capacity Deliberately"] {
            XCTAssertTrue(other.contains(section), "non-claude prompt lost \(section)")
        }
    }

    func test_bothLeaderKindsUseTheSingleCallAgentAddFastPath() {
        let claude = TeamOrchestrator.remoteLeaderClaudeSystemPrompt(
            teamName: "xm",
            rows: rows,
            remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
            remoteSocketPath: "/tmp/term-mesh.sock"
        )
        let other = nonClaudePrompt()

        for prompt in [claude, other] {
            XCTAssertTrue(prompt.contains("tm-agent add <role> --cli <cli> --name <name> --warmup"))
            XCTAssertTrue(prompt.contains("Do not probe `status`, `--help`, presets, or runbooks first."))
            XCTAssertTrue(prompt.contains("Do not run a second `status` or `warmup`"))
        }
    }

    func test_bothLeaderKindsTreatDurableRequestCommandsAsAClosedProtocol() {
        let claude = TeamOrchestrator.remoteLeaderClaudeSystemPrompt(
            teamName: "xm",
            rows: rows,
            remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
            remoteSocketPath: "/tmp/term-mesh.sock"
        )
        let other = nonClaudePrompt()

        for prompt in [claude, other] {
            XCTAssertTrue(prompt.contains("durable-request command set is CLOSED"), prompt)
            XCTAssertTrue(prompt.contains("leader request take <id>` once"), prompt)
            XCTAssertTrue(prompt.contains("leader request complete <id>` once"), prompt)
            XCTAssertTrue(prompt.contains("Specifically forbidden: `--help`, `list`, `recover`, `get`, `status`")
                || prompt.contains("In particular, do not run `--help`, `list`, `recover`, `get`, `status`"), prompt)
            XCTAssertTrue(prompt.contains("no verification command afterward"), prompt)
        }
    }

    /// Recovery restarts a leader whose team already exists, so it reads the
    /// durable roster instead of the creation rows — and had the same hole.
    private func recoveryAgents() -> [TeamOrchestrator.AgentMember] {
        ["executor", "reviewer"].map { name in
            TeamOrchestrator.AgentMember(
                id: "\(name)@xm",
                name: name,
                teamName: "xm",
                cli: "codex",
                launchCommand: "codex",
                model: "gpt-5.6-sol",
                agentType: name,
                color: "blue",
                instructions: "",
                workspaceId: UUID(),
                panelId: nil,
                createdAt: Date(),
                hostKey: "ssh:peer"
            )
        }
    }

    func test_recoveryBriefsANonClaudeLeaderToo() {
        let agents = recoveryAgents()
        let prompt = TeamOrchestrator.remoteLeaderNonClaudeRecoverySystemPrompt(
            teamName: "xm",
            agents: agents,
            remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
            remoteSocketPath: "/tmp/term-mesh.sock"
        )

        XCTAssertTrue(prompt.contains("'xm'"))
        XCTAssertTrue(prompt.contains("executor"))
        XCTAssertTrue(prompt.contains("reviewer"))
        XCTAssertTrue(prompt.contains("tm-agent delegate"))
    }

    /// `PeerProjectBootstrap` runs before this prompt is built, so the real
    /// checkout layout is already on the rows. The renderer used to print a
    /// hardcoded `unknown` instead, and `same-checkout-isolation` reads that
    /// as a reason to serialize every write — for the life of the leader,
    /// because a system prompt is injected once and never rebuilt.
    func test_creationPromptReportsTheIsolationTheBootstrapMade() {
        var isolated = rows
        for index in isolated.indices {
            let name = isolated[index].preset.name
            isolated[index].hostDirectory = "/Users/jinwoo/work/tm-projects/xm-\(name)-a1b2"
            isolated[index].hostBranch = "agent/\(name)-a1b2"
        }
        let prompts = [
            TeamOrchestrator.remoteLeaderClaudeSystemPrompt(
                teamName: "xm",
                rows: isolated,
                remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
                remoteSocketPath: "/tmp/term-mesh.sock"
            ),
            TeamOrchestrator.remoteLeaderNonClaudeSystemPrompt(
                teamName: "xm",
                rows: isolated,
                remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
                remoteSocketPath: "/tmp/term-mesh.sock"
            ),
        ]
        for prompt in prompts {
            XCTAssertTrue(prompt.contains("TEAM_CHECKOUT_MODE: isolated"))
            XCTAssertFalse(prompt.contains("TEAM_CHECKOUT_MODE: unknown"))
            XCTAssertTrue(prompt.contains("branch=agent/executor-a1b2"))
            XCTAssertFalse(prompt.contains("branch=shared-or-unknown"))
            XCTAssertTrue(prompt.contains("ownership-disjoint write tasks may run concurrently"))
        }
    }

    /// The same derivation must not promote a shared checkout to isolated.
    /// With `isolateAgents` off every member's path is the leader's own, and
    /// concurrent writes there land in one working tree.
    func test_creationPromptStillWarnsWhenEveryoneSharesOneCheckout() {
        let prompt = nonClaudePrompt()
        XCTAssertTrue(prompt.contains("TEAM_CHECKOUT_MODE: shared"))
        XCTAssertTrue(prompt.contains("Serialize writes unless the paths are proven disjoint"))
    }

    /// A recovered peer member carries its bootstrap checkout in
    /// `originalAgentWorkDir`; `worktreePath` is set only when a task made a
    /// worktree. Recovery reads the same layout the creation prompt does.
    func test_recoveryPromptReportsIsolationFromTheMembersOwnCheckouts() {
        var agents = recoveryAgents()
        for index in agents.indices {
            agents[index].originalAgentWorkDir =
                "/Users/jinwoo/work/tm-projects/xm-\(agents[index].name)-a1b2"
            agents[index].worktreeBranch = "agent/\(agents[index].name)-a1b2"
        }
        let prompts = [
            TeamOrchestrator.remoteLeaderNonClaudeRecoverySystemPrompt(
                teamName: "xm",
                agents: agents,
                remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
                remoteSocketPath: "/tmp/term-mesh.sock"
            ),
            TeamOrchestrator.remoteLeaderClaudeRecoverySystemPrompt(
                teamName: "xm",
                agents: agents,
                remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
                remoteSocketPath: "/tmp/term-mesh.sock"
            ),
        ]
        for prompt in prompts {
            XCTAssertTrue(prompt.contains("TEAM_CHECKOUT_MODE: isolated"))
            XCTAssertFalse(prompt.contains("TEAM_CHECKOUT_MODE: unknown"))
            XCTAssertTrue(prompt.contains("branch=agent/executor-a1b2"))
        }
    }
}
