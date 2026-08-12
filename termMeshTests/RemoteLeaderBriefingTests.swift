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

/// A peer leader's whole job is `tm-agent`, and `tm-agent` reaches the app
/// over a Unix socket. Codex's default sandbox denies that connect with
/// EPERM, so `detect_socket` finds nothing and every team command answers
/// "no socket found": the leader can name its teammates and cannot reach one.
///
/// Verified on a live peer before the fix — the leader reported
/// `PermissionError: [Errno 1] Operation not permitted` connecting to
/// `/tmp/term-mesh.sock`, while the same flags on the local launch path had
/// carried a comment naming this exact failure since it was written.
@MainActor
final class RemoteLeaderAutonomyFlagsTests: XCTestCase {

    private func command(cli: String, isLeader: Bool = true) -> String {
        TeamOrchestrator.remoteAgentCommand(
            cli: cli,
            model: "gpt-5.6-sol",
            agentName: isLeader ? "leader" : "executor",
            teamName: "selftest",
            workingDirectory: "/Users/jinwoo/work/tm-projects/selftest",
            systemPromptFile: "/tmp/term-mesh-leader-prompt-TEST.txt",
            needsSocketAccess: isLeader
        )
    }

    /// The two that matter, and why: without the sandbox flag the socket is
    /// unreachable; without the approval flag the first tool call waits for a
    /// keypress in a pane nobody is watching.
    func test_aCodexLeaderMayReachTheSocketAndActUnattended() {
        let cmd = command(cli: "codex")
        XCTAssertTrue(
            cmd.contains("--sandbox danger-full-access"),
            "codex's sandbox denies the tm-agent socket connect: \(cmd)"
        )
        XCTAssertTrue(
            cmd.contains("--ask-for-approval never"),
            "an unattended pane cannot answer an approval prompt: \(cmd)"
        )
    }

    func test_aGeminiLeaderActsUnattended() {
        XCTAssertTrue(command(cli: "gemini").contains("--yolo"))
    }

    /// Claude carries its own equivalent and must keep it.
    func test_aClaudeLeaderKeepsItsPermissionBypass() {
        XCTAssertTrue(command(cli: "claude").contains("--dangerously-skip-permissions"))
    }

    /// kiro has no such flag. Inventing one would fail at launch instead of
    /// at the first socket call, which is strictly worse.
    func test_kiroIsNotGivenAFlagItDoesNotHave() {
        XCTAssertTrue(TeamOrchestrator.leaderAutonomyFlags(cli: "kiro").isEmpty)
    }

    /// The flags must precede the launch directive: codex reads the first
    /// non-flag argument as the prompt, so a flag after it becomes prompt text.
    func test_flagsComeBeforeTheLaunchDirective() {
        let cmd = command(cli: "codex")
        guard let sandbox = cmd.range(of: "--sandbox"),
              let directive = cmd.range(of: "term-mesh-leader-prompt-TEST.txt")
        else { return XCTFail("command lost a required part: \(cmd)") }
        XCTAssertLessThan(
            sandbox.lowerBound, directive.lowerBound,
            "a flag after the prompt argument is prompt text, not a flag: \(cmd)"
        )
    }
}

extension RemoteLeaderAutonomyFlagsTests {
    /// Workers keep their CLI's own sandbox. Their results come back through
    /// pane output, so they never needed the socket, and opening every peer
    /// worker to full access without a failure asking for it is not a change
    /// to make as a side effect of fixing the leader.
    func test_aWorkerIsNotGivenTheLeadersAccess() {
        let worker = command(cli: "codex", isLeader: false)
        XCTAssertFalse(worker.contains("danger-full-access"), worker)
        XCTAssertTrue(worker.contains("--model"), "the worker still launches: \(worker)")
    }
}

extension RemoteLeaderBriefingTests {
    /// term-mesh puts the peer's bundled bin directory first on PATH, and that
    /// ordering does not survive every CLI: codex runs its shell tool through a
    /// fresh login shell, which rebuilt PATH with `$HOME/bin` ahead of it. A
    /// leader then silently used an 0.175.1 `tm-agent` against a 0.176.1 app
    /// and failed in that generation's ways. Observed on a live peer:
    /// `command -v tm-agent` answered `/Users/jinwoo/bin/tm-agent`.
    func test_theBriefingNamesAnAbsoluteTMAgentWhenTheHostReportsOne() {
        let prompt = TeamOrchestrator.remoteLeaderNonClaudeSystemPrompt(
            teamName: "xm",
            rows: rows,
            remoteWorkingDirectory: "/Users/jinwoo/work/tm-projects/xm",
            remoteSocketPath: "/tmp/term-mesh.sock",
            hostCLIBinDirs: ["/Applications/term-mesh.app/Contents/Resources/bin"]
        )
        XCTAssertTrue(
            prompt.contains("/Applications/term-mesh.app/Contents/Resources/bin/tm-agent delegate"),
            "a bare name is whatever the CLI's own shell resolves it to"
        )
    }

    /// A host that reports no bin directory keeps working exactly as before,
    /// rather than being pointed at a path that may not exist there.
    func test_aHostThatReportsNoBinDirKeepsTheBareName() {
        XCTAssertEqual(TeamOrchestrator.remoteTMAgentCommand(hostCLIBinDirs: []), "tm-agent")
        XCTAssertEqual(TeamOrchestrator.remoteTMAgentCommand(hostCLIBinDirs: ["  "]), "tm-agent")
    }

    /// Claude leaders were never broken by this, but they read the same field,
    /// so the two must not drift apart again.
    func test_bothLeaderKindsGetTheSameAbsolutePath() {
        let dirs = ["/opt/term-mesh/bin"]
        let claude = TeamOrchestrator.remoteLeaderClaudeSystemPrompt(
            teamName: "xm", rows: rows,
            remoteWorkingDirectory: "/w", remoteSocketPath: "/s", hostCLIBinDirs: dirs
        )
        let other = TeamOrchestrator.remoteLeaderNonClaudeSystemPrompt(
            teamName: "xm", rows: rows,
            remoteWorkingDirectory: "/w", remoteSocketPath: "/s", hostCLIBinDirs: dirs
        )
        for prompt in [claude, other] {
            XCTAssertTrue(prompt.contains("/opt/term-mesh/bin/tm-agent status"), prompt.prefix(200).description)
        }
    }
}

/// A native remote member exists only on the machine that started it: its
/// process is a child of that app's ssh, its stdio is that pipe, and nothing
/// is created on the peer. The peer's own window then shows a project with a
/// leader and no team — nothing there to continue the work with.
@MainActor
final class RemoteAgentPlacementTests: XCTestCase {

    /// The CLIs that can hold a terminal go to the peer's project workspace,
    /// where both machines can see and drive them.
    func test_aTerminalCapableRemoteAgentDoesNotTakeTheNativePath() {
        for cli in ["claude", "codex", "kiro"] {
            XCTAssertTrue(
                AgentPipeTransport.supports(cli: cli),
                "\(cli) is a native-capable CLI, which is what makes this a choice"
            )
            XCTAssertFalse(
                AgentPipeTransport.isPipeOnly(cli: cli),
                "\(cli) can hold a terminal, so a remote one belongs on the peer"
            )
        }
    }

    /// A turn-per-process CLI has no interactive UI and no stdin channel, so a
    /// terminal pane would open empty. Those keep the native path — a property
    /// of the CLI, not a placement choice.
    func test_aPipeOnlyRemoteAgentKeepsTheNativePath() {
        for cli in ["cursor", "agy"] {
            XCTAssertTrue(AgentPipeTransport.isPipeOnly(cli: cli))
            XCTAssertTrue(
                AgentPipeTransport.supports(cli: cli),
                "if the native path stopped supporting these they would have no path at all"
            )
        }
    }

    /// Local members are untouched: the whole point is that only the remote
    /// case had a peer with nothing in it.
    func test_theTerminalCapableSetIsExactlyWhatTheRemotePathRedirects() {
        let redirected = AgentRolePreset.knownCLIs.filter {
            AgentPipeTransport.supports(cli: $0) && !AgentPipeTransport.isPipeOnly(cli: $0)
        }
        XCTAssertEqual(Set(redirected), ["claude", "codex", "kiro"])
    }
}
