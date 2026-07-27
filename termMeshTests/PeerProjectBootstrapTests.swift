import XCTest
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerProjectBootstrapTests: XCTestCase {
    private func row(
        _ name: String,
        hostKey: String?,
        directory: String = ""
    ) -> TeamAgentRow {
        TeamAgentRow(
            preset: AgentRolePreset(
                id: UUID(),
                name: name,
                displayName: name.capitalized,
                cli: "claude",
                model: "sonnet",
                color: "blue",
                instructions: "",
                isBuiltIn: false
            ),
            customInstructions: "",
            hostKey: hostKey,
            hostDirectory: directory
        )
    }

    func test_isolated_agents_each_get_their_own_checkout_and_branch() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/tm-projects",
            projectName: "myproj",
            agents: ["executor", "architect"],
            isolateAgents: true
        )
        XCTAssertEqual(plan.primaryPath, "/app/tm-projects/myproj")
        XCTAssertEqual(
            plan.agentCheckouts.map(\.path),
            ["/app/tm-projects/myproj-executor", "/app/tm-projects/myproj-architect"]
        )
        // Distinct branches, because two agents starting from the same one is
        // the collision this exists to prevent.
        XCTAssertEqual(plan.agentCheckouts.map(\.branch), ["agent/executor", "agent/architect"])
    }

    func test_sharing_puts_everyone_in_the_project_itself() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/tm-projects",
            projectName: "myproj",
            agents: ["executor", "architect"],
            isolateAgents: false
        )
        XCTAssertEqual(Set(plan.agentCheckouts.map(\.path)), ["/app/tm-projects/myproj"])
    }

    func test_placements_group_source_local_member_and_remote_leader() throws {
        let source = ProjectSource(
            hostKey: "ssh:jw-server",
            projectPath: "/app/tm-projects/bloom",
            gitURL: "git@github.com:org/bloom.git",
            isolateAgents: true,
            kind: .clone
        )
        let rows = [
            row("executor", hostKey: "ssh:jw-server", directory: "/app/tm-projects/bloom"),
            row("architect", hostKey: nil),
        ]

        let placements = try PeerProjectBootstrap.placements(
            source: source,
            rows: rows,
            leaderHostKey: "ssh:mac-sub",
            localProjectsRoot: "/Users/me/work"
        ) { hostKey in
            hostKey == "ssh:mac-sub" ? "/Users/sub/work/bloom" : nil
        }

        XCTAssertEqual(placements, [
            .init(
                hostKey: "ssh:jw-server",
                projectPath: "/app/tm-projects/bloom",
                agentIndices: [0],
                includesLeader: false,
                isSource: true
            ),
            .init(
                hostKey: nil,
                projectPath: "/Users/me/work/bloom",
                agentIndices: [1],
                includesLeader: false,
                isSource: false
            ),
            .init(
                hostKey: "ssh:mac-sub",
                projectPath: "/Users/sub/work/bloom",
                agentIndices: [],
                includesLeader: true,
                isSource: false
            ),
        ])
    }

    func test_placements_keep_explicit_agent_folders_on_each_host() throws {
        let source = ProjectSource(
            hostKey: nil,
            projectPath: "/Users/me/work/bloom",
            gitURL: "git@github.com:org/bloom.git",
            isolateAgents: true,
            kind: .clone
        )
        let rows = [
            row("executor", hostKey: "ssh:a", directory: "/srv/a/bloom"),
            row("architect", hostKey: "ssh:b", directory: "/opt/projects/bloom"),
        ]

        let placements = try PeerProjectBootstrap.placements(
            source: source,
            rows: rows,
            leaderHostKey: nil,
            localProjectsRoot: "/Users/me/work",
            additionalRemoteProjectPath: { _ in nil }
        )

        XCTAssertEqual(placements.map(\.hostKey), [nil, "ssh:a", "ssh:b"])
        XCTAssertEqual(
            placements.map(\.projectPath),
            ["/Users/me/work/bloom", "/srv/a/bloom", "/opt/projects/bloom"]
        )
        XCTAssertEqual(placements.map(\.agentIndices), [[], [0], [1]])
        XCTAssertTrue(placements[0].includesLeader)
    }

    func test_placements_group_multiple_agents_on_the_same_peer() throws {
        let source = ProjectSource(
            hostKey: nil,
            projectPath: "/Users/me/work/bloom",
            gitURL: "git@github.com:org/bloom.git",
            isolateAgents: true,
            kind: .clone
        )
        let rows = [
            row("executor", hostKey: "ssh:jw-server", directory: "/app/tm-projects/bloom"),
            row("architect", hostKey: "ssh:jw-server", directory: "/app/tm-projects/bloom"),
        ]

        let placements = try PeerProjectBootstrap.placements(
            source: source,
            rows: rows,
            leaderHostKey: nil,
            localProjectsRoot: "/Users/me/work",
            additionalRemoteProjectPath: { _ in nil }
        )

        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(placements[1].hostKey, "ssh:jw-server")
        XCTAssertEqual(placements[1].projectPath, "/app/tm-projects/bloom")
        XCTAssertEqual(placements[1].agentIndices, [0, 1])
    }

    func test_placements_require_a_folder_for_an_additional_peer() {
        let source = ProjectSource(
            hostKey: nil,
            projectPath: "/Users/me/work/bloom",
            gitURL: "",
            isolateAgents: false,
            kind: .empty
        )

        XCTAssertThrowsError(
            try PeerProjectBootstrap.placements(
                source: source,
                rows: [row("executor", hostKey: "ssh:unknown")],
                leaderHostKey: nil,
                localProjectsRoot: "/Users/me/work",
                additionalRemoteProjectPath: { _ in nil }
            )
        ) { error in
            XCTAssertEqual(
                error as? PeerProjectBootstrap.PlacementError,
                .missingProjectPath(hostKey: "ssh:unknown")
            )
        }
    }

    func test_creates_each_agent_as_a_worktree_of_the_primary_copy() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let script = PeerProjectBootstrap.script(for: plan, gitURL: "git@github.com:org/x.git")
        let text = try! XCTUnwrap(script)
        XCTAssertTrue(text.contains("git clone 'git@github.com:org/x.git' '/app/p/x'"))
        // The network and credentials are needed once; agent checkouts share
        // objects safely through Git's first-class worktree mechanism.
        XCTAssertTrue(
            text.contains(
                "git -C '/app/p/x' worktree add -b 'agent/a' '/app/p/x-a' HEAD"
            )
        )
        XCTAssertFalse(text.contains("git clone '/app/p/x'"))
    }

    func test_running_it_twice_is_running_it_once() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let text = try! XCTUnwrap(PeerProjectBootstrap.script(for: plan, gitURL: "u"))
        // Every step is guarded on its own result already existing.
        XCTAssertTrue(text.contains("test -d '/app/p/x'/.git ||"))
        XCTAssertTrue(text.contains("git -C '/app/p/x-a' rev-parse --git-dir"))
        // A branch left over from a previous run is the normal second visit.
        XCTAssertTrue(text.contains("show-ref --verify --quiet refs/heads/'agent/a'"))
        XCTAssertTrue(text.contains("worktree add '/app/p/x-a' 'agent/a'"))
    }

    func test_empty_project_initializes_and_commits_before_adding_worktrees() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let text = try! XCTUnwrap(
            PeerProjectBootstrap.script(for: plan, gitURL: nil, sourceKind: .empty)
        )

        let initRange = try! XCTUnwrap(text.range(of: "git -C '/app/p/x' init"))
        let commitRange = try! XCTUnwrap(text.range(of: "commit --allow-empty"))
        let worktreeRange = try! XCTUnwrap(text.range(of: "worktree add"))
        XCTAssertLessThan(initRange.lowerBound, commitRange.lowerBound)
        XCTAssertLessThan(commitRange.lowerBound, worktreeRange.lowerBound)
    }

    func test_duplicate_agent_roles_receive_unique_paths_and_branches() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p",
            projectName: "x",
            agents: ["executor", "executor"],
            isolateAgents: true
        )

        XCTAssertEqual(
            plan.agentCheckouts.map(\.path),
            ["/app/p/x-executor", "/app/p/x-executor-2"]
        )
        XCTAssertEqual(
            plan.agentCheckouts.map(\.branch),
            ["agent/executor", "agent/executor-2"]
        )
    }

    func test_existing_shared_folder_is_validated_without_modifying_it() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: false
        )
        XCTAssertEqual(
            PeerProjectBootstrap.script(
                for: plan, gitURL: nil, sourceKind: .existingFolder
            ),
            "test -d '/app/p/x'"
        )
    }

    func test_a_plain_legacy_shared_folder_needs_no_script() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: false
        )
        XCTAssertNil(PeerProjectBootstrap.script(for: plan, gitURL: nil))
    }

    func test_project_deletion_quotes_deduplicates_and_removes_only_exact_paths() throws {
        let script = try PeerProjectBootstrap.deletionScript(paths: [
            "/app/projects/demo-agent",
            "/app/projects/demo",
            "/app/projects/demo",
        ])

        XCTAssertEqual(
            script,
            "rm -rf -- '/app/projects/demo' '/app/projects/demo-agent'"
        )
    }

    func test_project_deletion_rejects_broad_or_relative_paths() {
        for path in ["/", "/tmp", "tmp/demo", ".", ""] {
            XCTAssertThrowsError(try PeerProjectBootstrap.deletionScript(paths: [path]))
        }
    }

    func test_project_deletion_standardizes_before_validation() {
        XCTAssertThrowsError(
            try PeerProjectBootstrap.deletionScript(paths: ["/tmp/project/../.."])
        )
    }

    func test_remote_git_ssh_auth_failure_has_an_actionable_message() {
        let error = PeerHostReadinessError.sshFailed(
            """
            Cloning into '/app/tm-projects/bloom'...
            git@github.com: Permission denied (publickey).
            fatal: Could not read from remote repository.
            """
        )

        XCTAssertEqual(
            PeerProjectBootstrap.remoteFailureDescription(
                error,
                gitURL: "git@github.com:JINWOO-J/bloom.git"
            ),
            "Git SSH authentication failed. Add an SSH key with access to this repository on this machine, then try again."
        )
        XCTAssertEqual(
            error.localizedDescription,
            """
            Cloning into '/app/tm-projects/bloom'...
            git@github.com: Permission denied (publickey).
            fatal: Could not read from remote repository.
            """
        )
    }

    func test_remote_git_network_failure_has_an_actionable_message() {
        XCTAssertEqual(
            PeerProjectBootstrap.remoteFailureDescription(
                PeerHostReadinessError.sshFailed(
                    "ssh: Could not resolve hostname github.com: Name or service not known"
                ),
                gitURL: "git@github.com:org/repo.git"
            ),
            "This machine could not reach the Git host. Check its network and DNS settings."
        )
    }

    func test_remote_ref_keeps_peer_namespace_with_optional_surface() {
        let workspace = UUID()
        let surface = UUID()
        let ref = RemoteRef(hostPeerID: "peer-a", workspaceID: workspace, surfaceID: surface)

        XCTAssertEqual(ref.hostPeerID, "peer-a")
        XCTAssertEqual(ref.workspaceID, workspace)
        XCTAssertEqual(ref.surfaceID, surface)
        XCTAssertEqual(SelectionTarget.remote(ref).workspaceID, workspace)
        XCTAssertEqual(SelectionTarget.remote(ref).surfaceID, surface)
    }

    func test_local_selection_has_no_peer_namespace() {
        let workspace = UUID()
        let surface = UUID()
        let target = SelectionTarget.local(workspaceID: workspace, surfaceID: surface)

        XCTAssertEqual(target.workspaceID, workspace)
        XCTAssertEqual(target.surfaceID, surface)
        XCTAssertNotEqual(target, .remote(RemoteRef(hostPeerID: "peer-a", workspaceID: workspace, surfaceID: surface)))
    }

    func test_leader_endpoint_round_trips_remote_host_without_a_pane_uuid() throws {
        let endpoint = LeaderEndpoint.peer(hostKey: "peer-jw-server")
        let decoded = try JSONDecoder().decode(
            LeaderEndpoint.self,
            from: JSONEncoder().encode(endpoint)
        )

        XCTAssertEqual(decoded, endpoint)
        XCTAssertEqual(decoded.hostKey, "peer-jw-server")
    }

    func test_project_leader_defaults_to_local_for_legacy_callers() {
        let leader = ProjectLeader(mode: "codex", model: "gpt-5")

        XCTAssertEqual(leader.endpoint, .local)
        XCTAssertNil(leader.endpoint.hostKey)
    }

    @MainActor
    func test_remote_leader_keeps_requested_identity_with_inert_local_anchor() {
        XCTAssertEqual(
            TeamOrchestrator.initialLeaderEndpoint(
                forRequestedEndpoint: .peer(hostKey: "peer-jw-server")
            ),
            .peer(hostKey: "peer-jw-server")
        )
        XCTAssertEqual(
            TeamOrchestrator.initialLeaderEndpoint(forRequestedEndpoint: .local),
            .local
        )
        XCTAssertFalse(
            TeamOrchestrator.shouldLaunchLeaderLocally(
                forRequestedEndpoint: .peer(hostKey: "peer-jw-server")
            )
        )
        XCTAssertTrue(
            TeamOrchestrator.shouldLaunchLeaderLocally(forRequestedEndpoint: .local)
        )
    }

    func test_direct_local_peer_endpoint_is_rejected_before_attach() {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: PeerFederationSettings.socketPathKey)
        defer {
            if let old { defaults.set(old, forKey: PeerFederationSettings.socketPathKey) }
            else { defaults.removeObject(forKey: PeerFederationSettings.socketPathKey) }
        }
        defaults.set("/tmp/term-mesh-test-peer.sock", forKey: PeerFederationSettings.socketPathKey)

        XCTAssertTrue(PeerPaneHostSpec.direct(sockPath: "/tmp/./term-mesh-test-peer.sock").targetsLocalPeerServer)
        XCTAssertFalse(PeerPaneHostSpec.direct(sockPath: "/tmp/other-peer.sock").targetsLocalPeerServer)
        XCTAssertFalse(PeerPaneHostSpec.ssh(target: "peer", remoteSockPath: "/tmp/peer.sock", port: nil, identityFile: nil).targetsLocalPeerServer)
    }

    @MainActor
    func test_remote_leader_launch_exports_route_to_final_cli_without_visible_grant_stage() {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 0xab, count: 32)
        grant.projectID = "name:demo"
        grant.teamUuid = "team-uuid"
        grant.expiresAtUnixSecs = 123

        let prepare = TeamOrchestrator.remoteLeaderPrepareCommand()
        let launch = TeamOrchestrator.remoteLeaderCommand(
            cli: "codex",
            model: "gpt-5",
            teamName: "demo",
            workingDirectory: "/srv/demo",
            grant: grant
        )

        XCTAssertFalse(prepare.contains("abab"), "the visible preparation must contain no grant")
        XCTAssertEqual(prepare, "unset HISTFILE; stty -echo")
        XCTAssertTrue(launch.hasPrefix("export TERMMESH_LEADER_GRANT_ID="))
        XCTAssertTrue(launch.contains("; exec /bin/sh -lc "))
        XCTAssertTrue(launch.contains("codex --model gpt-5"))
    }

    @MainActor
    func test_remote_claude_leader_launch_injects_term_mesh_prompt() {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 0xcd, count: 32)
        grant.projectID = "name:demo"
        grant.teamUuid = "team-uuid"
        grant.expiresAtUnixSecs = 123

        let launch = TeamOrchestrator.remoteLeaderCommand(
            cli: "claude",
            model: "sonnet",
            teamName: "demo",
            workingDirectory: "/srv/demo",
            grant: grant,
            systemPromptFile: "/tmp/term-mesh-leader-prompt-team-uuid.txt"
        )

        XCTAssertTrue(launch.contains("claude --model sonnet"))
        XCTAssertTrue(launch.contains("--system-prompt"))
        XCTAssertTrue(launch.contains("TERMMESH_LEADER_PROMPT=$(cat"))
        XCTAssertTrue(launch.contains("rm -f"))
        XCTAssertTrue(launch.contains("--dangerously-skip-permissions"))
    }

    /// The launch looks where the CLI was actually installed.
    ///
    /// A host whose only `claude` sits in `~/.local/bin` — where the official
    /// installer puts it — read back as "not installed", because the PATH line
    /// installers add lives in `~/.bashrc` below its non-interactive guard, and
    /// every shell this app opens is non-interactive.
    @MainActor
    func test_remote_launch_puts_user_bin_dirs_on_path() {
        let launch = TeamOrchestrator.remoteAgentCommand(
            cli: "claude",
            model: "sonnet",
            agentName: "worker",
            teamName: "demo",
            workingDirectory: "/srv/demo"
        )

        XCTAssertTrue(launch.hasPrefix("export PATH="), "PATH has to be set before anything runs")
        XCTAssertTrue(launch.contains("$HOME/.local/bin"))
        XCTAssertTrue(launch.contains(":$PATH\""), "the host's own PATH must survive, last")
        // Ordering matters as much as membership: a cd into the project before
        // PATH is set would run the CLI lookup with the old PATH.
        let pathEnd = try? XCTUnwrap(launch.range(of: ":$PATH\";"))
        let cd = try? XCTUnwrap(launch.range(of: "cd '"))
        if let pathEnd, let cd {
            XCTAssertLessThan(pathEnd.lowerBound, cd.lowerBound)
        }
    }

    /// The probe and the launch have to agree on where to look. Finding a CLI
    /// and then starting a shell that cannot is the worst of both outcomes:
    /// the guard passes and the pane dies with "command not found".
    @MainActor
    func test_probe_and_launch_share_one_path_rule() {
        let launch = TeamOrchestrator.remoteAgentCommand(
            cli: "claude", model: "sonnet", agentName: "worker",
            teamName: "demo", workingDirectory: "/srv/demo"
        )
        XCTAssertTrue(launch.hasPrefix(RemoteShellPath.prologue))
        XCTAssertTrue(RemoteShellPath.binDirs.contains("$HOME/.local/bin"))
    }

    /// A directory with a quote in it stays one argument.
    @MainActor
    func test_remote_launch_escapes_a_quote_in_the_working_directory() {
        let launch = TeamOrchestrator.remoteAgentCommand(
            cli: "claude", model: "sonnet", agentName: "worker",
            teamName: "demo", workingDirectory: "/srv/it's here"
        )

        XCTAssertTrue(launch.contains("'/srv/it'\\''s here'"))
        XCTAssertFalse(launch.contains("cd '/srv/it's here'"), "an unescaped quote would end the argument early")
    }
}
