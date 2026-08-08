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
        let prompt = nonClaudePrompt()
        for name in ["executor", "architect", "reviewer"] {
            XCTAssertTrue(
                prompt.contains(name),
                "the leader was never told about \(name), so it cannot delegate to it"
            )
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
        // team tools, which mean nothing to codex. Length is the crude proxy
        // for "a briefing, not a policy sheet": the old failure produced a
        // string a fraction of this size.
        XCTAssertGreaterThan(
            other.count,
            LeaderParallelPolicy.renderedInstructions.count * 2,
            "a prompt barely longer than the policy is the bug this test exists for"
        )
    }

    /// Recovery restarts a leader whose team already exists, so it reads the
    /// durable roster instead of the creation rows — and had the same hole.
    func test_recoveryBriefsANonClaudeLeaderToo() {
        let agents = ["executor", "reviewer"].map { name in
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
}
