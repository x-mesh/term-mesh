import XCTest
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerProjectBootstrapTests: XCTestCase {
    func test_lateRemoteAgentCheckoutPlanIsDistinctFromRequestedCheckout() {
        let requested = "/app/tm-projects/term-mesh-reviewer-260729-c741"
        let plan = TeamOrchestrator.lateRemoteAgentCheckoutPlan(
            primaryRepository: "/app/tm-projects/term-mesh",
            agentName: "fixer",
            instanceTag: "260729-b4c7"
        )

        XCTAssertEqual(plan.agentCheckouts.count, 1)
        XCTAssertNotEqual(plan.agentCheckouts[0].path, requested)
        XCTAssertEqual(plan.agentCheckouts[0].path, "/app/tm-projects/term-mesh-fixer-260729-b4c7")
        XCTAssertEqual(plan.agentCheckouts[0].branch, "agent/fixer-260729-b4c7")
    }

    func test_remoteWorkingDirectoryRequiresHostResolvedPath() throws {
        XCTAssertEqual(
            try TeamOrchestrator.requiredRemoteWorkingDirectory(
                "  /srv/project  ",
                hostKey: "ssh:builder"
            ),
            "/srv/project"
        )

        for path: String? in [nil, "", "   "] {
            XCTAssertThrowsError(
                try TeamOrchestrator.requiredRemoteWorkingDirectory(
                    path,
                    hostKey: "ssh:builder"
                )
            ) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("ssh:builder"))
                XCTAssertTrue(message.contains("path"))
                XCTAssertTrue(message.contains("--dir <remote-path>"))
            }
        }
    }

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
        XCTAssertTrue(
            text.contains(
                "GIT_SSH_COMMAND='ssh -o BatchMode=yes "
                    + "-o StrictHostKeyChecking=accept-new' "
                    + "git clone 'git@github.com:org/x.git' '/app/p/x'"
            )
        )
        // The network and credentials are needed once; agent checkouts share
        // objects safely through Git's first-class worktree mechanism.
        XCTAssertTrue(
            text.contains(
                "git -C '/app/p/x' worktree add -b 'agent/a' '/app/p/x-a' HEAD"
            )
        )
        XCTAssertFalse(text.contains("git clone '/app/p/x'"))
    }

    func test_selected_repository_branch_is_cloned_before_worktrees_are_created() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let text = try! XCTUnwrap(
            PeerProjectBootstrap.script(
                for: plan,
                gitURL: "git@github.com:org/x.git",
                gitBranch: "release/v2"
            )
        )

        XCTAssertTrue(
            text.contains(
                "git clone --branch 'release/v2' "
                    + "'git@github.com:org/x.git' '/app/p/x'"
            )
        )
        XCTAssertTrue(
            text.contains(
                "git -C '/app/p/x' worktree add -b 'agent/a' '/app/p/x-a' HEAD"
            )
        )
    }

    func test_running_it_twice_is_running_it_once() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let text = try! XCTUnwrap(PeerProjectBootstrap.script(for: plan, gitURL: "u"))
        // Every step is guarded on its own result already existing.
        XCTAssertTrue(text.contains("if test -d '/app/p/x'/.git; then :; else"))
        XCTAssertTrue(text.contains("git -C '/app/p/x-a' rev-parse --git-dir"))
        // A branch left over from a previous run is the normal second visit.
        XCTAssertTrue(text.contains("show-ref --verify --quiet refs/heads/'agent/a'"))
        XCTAssertTrue(text.contains("worktree add '/app/p/x-a' 'agent/a'"))
    }

    func test_failed_bootstrap_rolls_back_owned_artifacts_and_preserves_existing_targets() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let primary = (root as NSString).appendingPathComponent("x")
        let first = (root as NSString).appendingPathComponent("x-a")
        let existing = (root as NSString).appendingPathComponent("x-b")
        try FileManager.default.createDirectory(
            atPath: primary,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: existing,
            withIntermediateDirectories: true
        )
        let marker = (existing as NSString).appendingPathComponent("keep.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: marker, contents: Data("keep".utf8)))
        XCTAssertEqual(Self.shellStatus("git -C \(Self.quoted(primary)) init -q"), 0)
        XCTAssertEqual(
            Self.shellStatus(
                "git -C \(Self.quoted(primary)) -c user.name=test "
                    + "-c user.email=test@example.invalid commit --allow-empty -qm initial"
            ),
            0
        )

        let plan = PeerProjectBootstrap.Plan(
            primaryPath: primary,
            agentCheckouts: [
                (agent: "a", path: first, branch: "agent/a"),
                (agent: "b", path: existing, branch: "agent/b"),
            ]
        )
        let text = try XCTUnwrap(
            PeerProjectBootstrap.script(for: plan, gitURL: nil, sourceKind: .existingFolder)
        )
        XCTAssertTrue(text.contains("trap tm_rollback EXIT"))
        XCTAssertNotEqual(Self.shellStatus(text), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (primary as NSString).appendingPathComponent(".git")))
        XCTAssertNotEqual(
            Self.shellStatus(
                "git -C \(Self.quoted(primary)) show-ref --verify --quiet refs/heads/\(Self.quoted("agent/a"))"
            ),
            0
        )
    }

    func test_bootstrap_rollback_is_emitted_in_reverse_creation_order() throws {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p",
            projectName: "x",
            agents: ["a", "b"],
            isolateAgents: true
        )
        let text = try XCTUnwrap(PeerProjectBootstrap.script(for: plan, gitURL: "u"))
        let second = try XCTUnwrap(text.range(of: "worktree remove --force '/app/p/x-b'"))
        let first = try XCTUnwrap(text.range(of: "worktree remove --force '/app/p/x-a'"))
        let primary = try XCTUnwrap(text.range(of: "else rm -rf -- '/app/p/x'; fi; fi"))
        XCTAssertLessThan(second.lowerBound, first.lowerBound)
        XCTAssertLessThan(first.lowerBound, primary.lowerBound)
    }

    func test_failed_bootstrap_restores_a_preexisting_unborn_repository() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let primary = (root as NSString).appendingPathComponent("x")
        let blockedWorktree = (root as NSString).appendingPathComponent("x-a")
        try FileManager.default.createDirectory(
            atPath: primary,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: blockedWorktree,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: (blockedWorktree as NSString).appendingPathComponent("keep.txt"),
            contents: Data("keep".utf8)
        ))
        XCTAssertEqual(Self.shellStatus("git -C \(Self.quoted(primary)) init -q"), 0)

        let plan = PeerProjectBootstrap.Plan(
            primaryPath: primary,
            agentCheckouts: [(agent: "a", path: blockedWorktree, branch: "agent/a")]
        )
        let text = try XCTUnwrap(
            PeerProjectBootstrap.script(for: plan, gitURL: nil, sourceKind: .empty)
        )
        XCTAssertNotEqual(Self.shellStatus(text), 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (primary as NSString).appendingPathComponent(".git")
        ))
        XCTAssertNotEqual(
            Self.shellStatus("git -C \(Self.quoted(primary)) rev-parse --verify HEAD"),
            0,
            "the initial commit created by the failed run must be removed"
        )
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

    func test_instance_tag_makes_each_creations_checkouts_unique() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p",
            projectName: "x",
            agents: ["executor", "executor"],
            isolateAgents: true,
            instanceTag: "260728-a3f2"
        )

        XCTAssertEqual(
            plan.agentCheckouts.map(\.path),
            ["/app/p/x-executor-260728-a3f2", "/app/p/x-executor-2-260728-a3f2"]
        )
        XCTAssertEqual(
            plan.agentCheckouts.map(\.branch),
            ["agent/executor-260728-a3f2", "agent/executor-2-260728-a3f2"]
        )
        // The primary is the project itself — instance tags are for the
        // temporary stations only.
        XCTAssertEqual(plan.primaryPath, "/app/p/x")
    }

    func test_instance_tag_format_is_date_dash_hex() {
        let tag = PeerProjectBootstrap.makeInstanceTag(
            now: Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-25 UTC
        )
        // yyMMdd-xxxx: 6 digits, dash, 4 hex. The date half depends on the
        // machine's zone, so assert shape rather than the exact day.
        XCTAssertEqual(tag.count, 11)
        let parts = tag.split(separator: "-")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].allSatisfy(\.isNumber))
        XCTAssertTrue(parts[1].allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    func test_bootstrap_prunes_stale_worktree_registrations_when_isolating() throws {
        let isolated = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"],
            isolateAgents: true, instanceTag: "260728-ffff"
        )
        let text = try XCTUnwrap(PeerProjectBootstrap.script(for: isolated, gitURL: "u"))
        let prune = try XCTUnwrap(text.range(of: "git -C '/app/p/x' worktree prune"))
        let add = try XCTUnwrap(text.range(of: "worktree add"))
        XCTAssertLessThan(prune.lowerBound, add.lowerBound, "reclaim before adding more")

        // A shared plan has no worktrees to prune.
        let shared = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: false
        )
        let sharedText = PeerProjectBootstrap.script(for: shared, gitURL: "u")
        XCTAssertFalse(sharedText?.contains("worktree prune") ?? false)
    }

    func test_reap_script_only_deletes_a_clean_linked_worktree() throws {
        let script = try PeerProjectBootstrap.reapWorktreeScript(
            path: "/app/p/x-executor-260728-a3f2"
        )
        // Structural guards, in the script itself: linked worktree only
        // (git-dir differs from git-common-dir; a primary checkout fails
        // this), and clean only (porcelain empty).
        XCTAssertTrue(script.contains("--absolute-git-dir"))
        XCTAssertTrue(script.contains("--git-common-dir"))
        XCTAssertTrue(script.contains(#"[ "$GD" != "$CD" ]"#))
        XCTAssertTrue(script.contains("status --porcelain"))
        XCTAssertTrue(script.contains("worktree prune"))
        XCTAssertTrue(script.contains("rm -rf -- \"$WT\""))
    }

    func test_reap_script_refuses_unsafe_paths() {
        XCTAssertThrowsError(try PeerProjectBootstrap.reapWorktreeScript(path: "/"))
        XCTAssertThrowsError(try PeerProjectBootstrap.reapWorktreeScript(path: "relative/path"))
        XCTAssertThrowsError(try PeerProjectBootstrap.reapWorktreeScript(path: "/app"))
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
        // The whole-script form is the only guard against a step being added
        // that nobody declared, so the named variant is spelled out too — the
        // unscoped `|| true` that used to end this script was invisible to
        // every substring assertion in this file.
        XCTAssertEqual(
            PeerProjectBootstrap.script(
                for: plan, gitURL: nil, sourceKind: .existingFolder, memMeshProjectID: "demo"
            ),
            "test -d '/app/p/x' && "
                + "( top=$(git -C '/app/p/x' rev-parse --show-toplevel 2>/dev/null) "
                + "&& here=$(cd '/app/p/x' 2>/dev/null && pwd -P) "
                + "&& [ -n \"$top\" ] && [ \"$top\" = \"$here\" ] "
                + "&& { git -C '/app/p/x' config --local --get mem-mesh.project-id >/dev/null 2>&1 "
                + "|| git -C '/app/p/x' config --local mem-mesh.project-id 'demo'; } "
                + "|| true )"
        )
    }

    func test_a_plain_legacy_shared_folder_needs_no_script() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: false
        )
        XCTAssertNil(PeerProjectBootstrap.script(for: plan, gitURL: nil))
        // Naming a project that is not being set up would resurrect a script
        // for the one case that deliberately has none.
        XCTAssertNil(
            PeerProjectBootstrap.script(for: plan, gitURL: nil, memMeshProjectID: "demo")
        )
    }

    func test_project_name_is_pinned_as_the_mem_mesh_identity_once() throws {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let text = try XCTUnwrap(
            PeerProjectBootstrap.script(
                for: plan, gitURL: nil, sourceKind: .empty, memMeshProjectID: "demo"
            )
        )
        // Written on the primary copy only: worktrees share one local config,
        // so naming each checkout separately would be the drift, not the fix.
        XCTAssertTrue(
            text.contains("git -C '/app/p/x' config --local mem-mesh.project-id 'demo'")
        )
        XCTAssertFalse(text.contains("git -C '/app/p/x-a' config --local mem-mesh.project-id"))
        // An id the repository already carries is the user's, not ours.
        XCTAssertTrue(
            text.contains("config --local --get mem-mesh.project-id >/dev/null 2>&1 ||")
        )
        // The repository has to exist before it can be named.
        let initRange = try XCTUnwrap(text.range(of: "git -C '/app/p/x' init"))
        let idRange = try XCTUnwrap(text.range(of: "config --local mem-mesh.project-id"))
        XCTAssertLessThan(initRange.lowerBound, idRange.lowerBound)
    }

    /// Every setup shape, not just the one the feature was written against —
    /// moving the append inside `sourceKind == .empty` would leave the whole
    /// suite green while cloned and existing-folder projects lost their id.
    func test_identity_is_pinned_for_every_kind_of_project_setup() throws {
        let isolated = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let shared = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: false
        )
        let cases: [(String, String?)] = [
            ("clone-isolated", PeerProjectBootstrap.script(
                for: isolated, gitURL: "u", memMeshProjectID: "demo")),
            ("clone-shared", PeerProjectBootstrap.script(
                for: shared, gitURL: "u", memMeshProjectID: "demo")),
            ("new-folder-isolated", PeerProjectBootstrap.script(
                for: isolated, gitURL: nil, memMeshProjectID: "demo")),
            ("existing-isolated", PeerProjectBootstrap.script(
                for: isolated, gitURL: nil, sourceKind: .existingFolder, memMeshProjectID: "demo")),
            ("existing-shared", PeerProjectBootstrap.script(
                for: shared, gitURL: nil, sourceKind: .existingFolder, memMeshProjectID: "demo")),
            ("empty-isolated", PeerProjectBootstrap.script(
                for: isolated, gitURL: nil, sourceKind: .empty, memMeshProjectID: "demo")),
            ("empty-shared", PeerProjectBootstrap.script(
                for: shared, gitURL: nil, sourceKind: .empty, memMeshProjectID: "demo")),
        ]
        for (label, script) in cases {
            let text = try XCTUnwrap(script, label)
            XCTAssertTrue(
                text.contains("git -C '/app/p/x' config --local mem-mesh.project-id 'demo'"),
                "\(label) lost the pinned identity"
            )
        }
    }

    func test_mem_mesh_identity_omitted_when_the_caller_names_nothing() throws {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let text = try XCTUnwrap(
            PeerProjectBootstrap.script(for: plan, gitURL: nil, sourceKind: .empty)
        )
        XCTAssertFalse(text.contains("mem-mesh.project-id"))
    }

    /// The composed script is one `&&` chain, so a naming step that ends in a
    /// bare `|| true` reports a failed clone as a success. Asserted by running
    /// it, because the shape alone is what fooled the substring assertions.
    func test_pinning_an_identity_does_not_swallow_a_failed_setup_step() throws {
        let missing = "/app/definitely-not-here-\(UUID().uuidString)"
        let plan = PeerProjectBootstrap.plan(
            projectRoot: (missing as NSString).deletingLastPathComponent,
            projectName: (missing as NSString).lastPathComponent,
            agents: ["a"],
            isolateAgents: false
        )
        let text = try XCTUnwrap(
            PeerProjectBootstrap.script(
                for: plan, gitURL: nil, sourceKind: .existingFolder, memMeshProjectID: "demo"
            )
        )
        XCTAssertNotEqual(
            Self.shellStatus(text), 0,
            "an absent existing folder must still fail the script"
        )
    }

    /// `rev-parse --git-dir` answers for any ancestor repository, so naming a
    /// project folder that merely sits inside somebody else's checkout would
    /// rename that checkout instead.
    func test_identity_is_not_written_into_a_repository_that_merely_contains_it() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let outer = (root as NSString).appendingPathComponent("outer")
        let inner = (outer as NSString).appendingPathComponent("packages/proj")
        try FileManager.default.createDirectory(
            atPath: inner, withIntermediateDirectories: true
        )
        XCTAssertEqual(Self.shellStatus("git -C \(Self.quoted(outer)) init -q"), 0)

        let plan = PeerProjectBootstrap.Plan(primaryPath: inner, agentCheckouts: [])
        let text = try XCTUnwrap(
            PeerProjectBootstrap.script(
                for: plan, gitURL: nil, sourceKind: .existingFolder, memMeshProjectID: "proj"
            )
        )
        XCTAssertEqual(Self.shellStatus(text), 0, "naming must stay non-fatal")
        XCTAssertEqual(
            Self.shellStatus(
                "git -C \(Self.quoted(outer)) config --local --get mem-mesh.project-id"
            ),
            1,
            "the surrounding repository must be left alone"
        )

        // The project's own repository, by contrast, is named — including when
        // the caller's path is unresolved (/var vs /private/var on macOS).
        XCTAssertEqual(Self.shellStatus("git -C \(Self.quoted(inner)) init -q"), 0)
        XCTAssertEqual(Self.shellStatus(text), 0)
        XCTAssertEqual(
            Self.shellStatus(
                "test \"$(git -C \(Self.quoted(inner)) config --local "
                    + "--get mem-mesh.project-id)\" = proj"
            ),
            0
        )
    }

    func test_mem_mesh_project_id_meets_the_id_charset() {
        XCTAssertEqual(PeerProjectBootstrap.memMeshProjectID(for: "term-mesh"), "term-mesh")
        XCTAssertEqual(PeerProjectBootstrap.memMeshProjectID(for: " my project "), "my-project")
        XCTAssertEqual(PeerProjectBootstrap.memMeshProjectID(for: "under_score"), "under_score")
        // Lowercased like the repo's other slugs, so a project is not `My-App`
        // to mem-mesh and `my-app` to its own team.
        XCTAssertEqual(PeerProjectBootstrap.memMeshProjectID(for: "My App"), "my-app")
        // Runs collapse and edges are trimmed, so the id never starts, ends or
        // doubles up on the separator the substitution introduces.
        XCTAssertEqual(PeerProjectBootstrap.memMeshProjectID(for: "--a  b--"), "a-b")
        XCTAssertNil(PeerProjectBootstrap.memMeshProjectID(for: "   "))
    }

    /// A name the charset cannot render is the common case here, not the
    /// exotic one — and collapsing it silently is how two projects end up
    /// sharing one memory namespace.
    func test_a_name_the_charset_cannot_render_stays_distinct_and_still_pins() throws {
        let payment = try XCTUnwrap(PeerProjectBootstrap.memMeshProjectID(for: "결제-api"))
        let auth = try XCTUnwrap(PeerProjectBootstrap.memMeshProjectID(for: "인증-api"))
        XCTAssertTrue(payment.hasPrefix("api-"), payment)
        XCTAssertTrue(auth.hasPrefix("api-"), auth)
        XCTAssertNotEqual(payment, auth, "two projects must not share one identity")

        // Nothing renderable at all is still pinned: unpinned is the
        // per-directory drift this exists to prevent.
        let korean = try XCTUnwrap(PeerProjectBootstrap.memMeshProjectID(for: "한글"))
        XCTAssertNotEqual(korean, PeerProjectBootstrap.memMeshProjectID(for: "가나"))
        // Separator-only names have nothing to render either.
        XCTAssertNotNil(PeerProjectBootstrap.memMeshProjectID(for: "..."))

        for name in ["결제-api", "한글", "...", String(repeating: "a-", count: 60), "a/b.c"] {
            let id = try XCTUnwrap(PeerProjectBootstrap.memMeshProjectID(for: name), name)
            XCTAssertLessThanOrEqual(id.count, 100, name)
            XCTAssertFalse(id.hasPrefix("-"), name)
            XCTAssertFalse(id.hasSuffix("-"), name)
            XCTAssertNil(id.rangeOfCharacter(from: Self.forbiddenInProjectID), name)
        }
        // Truncation happens after the collapse, so it must not put the
        // separator back at the edge it just removed.
        let long = try XCTUnwrap(
            PeerProjectBootstrap.memMeshProjectID(for: String(repeating: "a-", count: 60))
        )
        XCTAssertEqual(long.count, 100)
        XCTAssertFalse(long.hasSuffix("-"))
    }

    private static let forbiddenInProjectID =
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-").inverted

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func makeTemporaryDirectory() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tm-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )
        return path
    }

    private static func shellStatus(_ script: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
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

    /// The tilde belongs to the peer's account, so the host expands it. The
    /// word stays one word: `"$HOME"` unquoted, the remainder quoted.
    func test_project_deletion_leaves_home_relative_paths_for_the_host_to_expand() throws {
        let script = try PeerProjectBootstrap.deletionScript(paths: [
            "~/work/tm-projects/demo",
        ])

        XCTAssertEqual(script, "rm -rf -- \"$HOME\"'/work/tm-projects/demo'")
    }

    /// A project recorded with one home-relative path among its absolute ones
    /// used to fail every path in the batch, leaving the whole project on the
    /// peer. Each path now stands on its own.
    func test_project_deletion_keeps_absolute_paths_when_one_is_home_relative() throws {
        let script = try PeerProjectBootstrap.deletionScript(paths: [
            "/Users/peer/work/tm-projects/demo",
            "/Users/peer/work/tm-projects/demo-executor-260803-8bdf",
            "~/work/tm-projects/demo",
        ])

        XCTAssertEqual(
            script,
            "rm -rf -- '/Users/peer/work/tm-projects/demo' "
                + "'/Users/peer/work/tm-projects/demo-executor-260803-8bdf' "
                + "\"$HOME\"'/work/tm-projects/demo'"
        )
    }

    func test_project_deletion_confines_home_relative_paths_to_the_home_directory() throws {
        let script = try PeerProjectBootstrap.deletionScript(paths: ["~/../demo/./work"])

        XCTAssertEqual(script, "rm -rf -- \"$HOME\"'/demo/work'")
    }

    func test_project_deletion_rejects_the_home_directory_itself() {
        for path in ["~", "~/", "~/.", "~/..", "~/../.."] {
            XCTAssertThrowsError(
                try PeerProjectBootstrap.deletionScript(paths: [path]),
                "expected \(path) to be refused"
            )
        }
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

    func test_remote_git_changed_host_key_has_an_actionable_message() {
        XCTAssertEqual(
            PeerProjectBootstrap.remoteFailureDescription(
                PeerHostReadinessError.sshFailed("Host key verification failed."),
                gitURL: "git@github.com:org/repo.git"
            ),
            "The Git host identity could not be verified. Check this machine's SSH known_hosts entry, then try again."
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

    @MainActor
    func test_remote_project_workspace_title_is_distinct_and_single_line() {
        XCTAssertEqual(
            TeamOrchestrator.remoteProjectWorkspaceTitle(teamName: "term-mesh"),
            "Project · term-mesh"
        )
        XCTAssertEqual(
            TeamOrchestrator.remoteProjectWorkspaceTitle(teamName: "line one\nline two"),
            "Project · line one line two"
        )
        XCTAssertLessThanOrEqual(
            TeamOrchestrator.remoteProjectWorkspaceTitle(
                teamName: String(repeating: "x", count: 100)
            ).count,
            "Project · ".count + 72
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
        // The model is shell-quoted, and this whole launch is then quoted again
        // for `sh -lc` — so the inner quotes arrive escaped. One level is
        // consumed by that shell, leaving the CLI with `--model gpt-5`.
        XCTAssertTrue(launch.contains(#"codex --model '\''gpt-5'\''"#))
    }

    @MainActor
    func test_remote_leader_stages_prompt_in_bounded_commands_from_attached_shell() throws {
        let prompt = String(repeating: "leader 정책\n", count: 500)
        let promptFile = "/tmp/term-mesh-leader-prompt-team-uuid.txt"
        let commands = TeamOrchestrator.remoteLeaderPromptStageCommands(
            systemPrompt: prompt,
            promptFile: promptFile
        )

        XCTAssertGreaterThan(commands.count, 2)
        XCTAssertTrue(commands[0].contains(": > '\(promptFile)'"))
        XCTAssertTrue(commands[0].contains("TERMMESH_B64_FLAG"))
        XCTAssertTrue(
            commands.allSatisfy { $0.utf8.count < 1_024 },
            "prompt staging must stay below conservative PTY canonical-line limits"
        )
        XCTAssertFalse(commands.joined().contains(prompt))
        let decoded = commands.dropFirst().reduce(into: Data()) { result, command in
            let prefix = "printf %s '"
            let suffix = "' | base64"
            guard let start = command.range(of: prefix)?.upperBound,
                  let end = command.range(of: suffix, range: start..<command.endIndex)?.lowerBound,
                  let chunk = Data(base64Encoded: String(command[start..<end]))
            else {
                return XCTFail("invalid prompt chunk command: \(command)")
            }
            result.append(chunk)
        }
        XCTAssertEqual(decoded, Data(prompt.utf8))

        for shell in ["/bin/sh", "/bin/zsh"] {
            let actualFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("term-mesh-prompt-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: actualFile) }
            let actualCommands = TeamOrchestrator.remoteLeaderPromptStageCommands(
                systemPrompt: prompt,
                promptFile: actualFile.path
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-f", "-c", actualCommands.joined(separator: "; ")]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(shell) staging failed")
            XCTAssertEqual(try Data(contentsOf: actualFile), Data(prompt.utf8), shell)
        }

        let checked = TeamOrchestrator.remoteLeaderCommandCheckingPrompt(
            launch: "exec claude",
            systemPrompt: prompt,
            promptFile: promptFile
        )
        XCTAssertTrue(checked.contains("wc -c"))
        XCTAssertTrue(checked.contains("-ne \(Data(prompt.utf8).count)"))
        XCTAssertTrue(checked.contains("stty echo"))
        XCTAssertTrue(checked.contains("else exec claude; fi"))
    }

    func test_remote_paste_directory_is_shared_home_cache_in_sh_and_zsh() throws {
        XCTAssertFalse(RemotePasteTransfer.remoteDirectoryCommand.contains("/tmp"))
        XCTAssertTrue(RemotePasteTransfer.remoteDirectoryCommand.contains("XDG_CACHE_HOME"))
        XCTAssertTrue(RemotePasteTransfer.remoteDirectoryCommand.contains("$HOME/.cache"))
        XCTAssertTrue(RemotePasteTransfer.remoteDirectoryCommand.contains("systemctl show -p User"))
        XCTAssertTrue(RemotePasteTransfer.remoteDirectoryCommand.contains("runuser -u"))

        for shell in ["/bin/sh", "/bin/zsh"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("term-mesh-paste-\(UUID().uuidString)")
            let cache = root.appendingPathComponent("cache")
            defer { try? FileManager.default.removeItem(at: root) }
            let output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-f", "-c", RemotePasteTransfer.remoteDirectoryCommand]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HOME": root.path,
                "XDG_CACHE_HOME": cache.path,
            ]) { _, override in override }
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let expected = cache.appendingPathComponent("term-mesh/paste")
            XCTAssertEqual(process.terminationStatus, 0, shell)
            XCTAssertEqual(String(data: data, encoding: .utf8), expected.path, shell)
            let attributes = try FileManager.default.attributesOfItem(atPath: expected.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    @MainActor
    func test_remote_leader_prompt_streams_to_shared_cache_atomically() throws {
        let prompt = Data(String(repeating: "leader 정책\n", count: 1_500).utf8)
        let fileName = "term-mesh-leader-prompt-team-uuid.txt"

        for shell in ["/bin/sh", "/bin/zsh"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("term-mesh-leader-cache-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [
                "-f", "-c",
                TeamOrchestrator.remoteLeaderPromptSSHStageCommand(fileName: fileName),
            ]
            process.environment = [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin",
                "XDG_CACHE_HOME": "",
            ]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: prompt)
            try input.fileHandleForWriting.close()
            let path = String(
                data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0, shell)
            let expected = root.appendingPathComponent(
                ".cache/term-mesh/leader-prompts/\(fileName)"
            ).path
            XCTAssertEqual(path, expected, shell)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: expected)), prompt, shell)
            let entries = try FileManager.default.contentsOfDirectory(
                atPath: (expected as NSString).deletingLastPathComponent
            )
            XCTAssertFalse(entries.contains { $0.contains(".tmp.") }, shell)
        }
    }

    @MainActor
    func test_remote_leader_does_not_inject_policy_into_local_anchor_shell() {
        XCTAssertTrue(
            TeamOrchestrator.shouldInjectLocalLeaderPrompt(
                launchLeaderLocally: true,
                leaderMode: "codex"
            )
        )
        XCTAssertFalse(
            TeamOrchestrator.shouldInjectLocalLeaderPrompt(
                launchLeaderLocally: false,
                leaderMode: "codex"
            )
        )
        XCTAssertFalse(
            TeamOrchestrator.shouldInjectLocalLeaderPrompt(
                launchLeaderLocally: true,
                leaderMode: "claude"
            )
        )
    }

    @MainActor
    func test_remote_leader_restore_selects_latest_exact_managed_surface() {
        let older = ManagedPeerSurfaceStore.Record(
            hostKey: "ssh:mac-sub",
            surfaceIDBase64: Data([0x01]).base64EncodedString(),
            teamName: "term-mesh",
            role: "leader",
            workingDirectory: "/old",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let latest = ManagedPeerSurfaceStore.Record(
            hostKey: "ssh:mac-sub",
            surfaceIDBase64: Data([0x02]).base64EncodedString(),
            teamName: "term-mesh",
            role: "leader",
            workingDirectory: "/current",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let otherRole = ManagedPeerSurfaceStore.Record(
            hostKey: "ssh:mac-sub",
            surfaceIDBase64: Data([0x03]).base64EncodedString(),
            teamName: "term-mesh",
            role: "executor",
            workingDirectory: "/agent",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let otherTeam = ManagedPeerSurfaceStore.Record(
            hostKey: "ssh:mac-sub",
            surfaceIDBase64: Data([0x04]).base64EncodedString(),
            teamName: "other",
            role: "leader",
            workingDirectory: "/other",
            createdAt: Date(timeIntervalSince1970: 40)
        )

        let selected = ManagedPeerSurfaceStore.leaderRecord(
            in: [older, latest, otherRole, otherTeam],
            hostKey: "ssh:mac-sub",
            teamName: "term-mesh"
        )

        XCTAssertEqual(selected?.surfaceID, Data([0x02]))
        XCTAssertEqual(selected?.workingDirectory, "/current")
    }

    @MainActor
    func test_project_presentation_move_preserves_remote_identity_and_clears_old_viewers() {
        let oldWorkspaceID = UUID()
        let newWorkspaceID = UUID()
        let oldPanelID = UUID()
        let instanceID = UUID().uuidString
        let surfaceID = Data([0xaa, 0xbb])
        let member = TeamOrchestrator.AgentMember(
            id: "reviewer@term-mesh",
            agentInstanceId: instanceID,
            name: "reviewer",
            teamName: "term-mesh",
            cli: "claude",
            launchCommand: "claude",
            model: "opus",
            agentType: "reviewer",
            color: "blue",
            instructions: "",
            workspaceId: oldWorkspaceID,
            panelId: oldPanelID,
            createdAt: Date(),
            remoteSurfaceID: surfaceID,
            remoteSurfaceSpawned: true,
            hostKey: "ssh:mac-sub"
        )
        let team = TeamOrchestrator.Team(
            id: "term-mesh",
            leaderSessionId: UUID().uuidString,
            leaderMode: "claude",
            leaderModel: "opus",
            leaderCli: "claude",
            leaderPanelId: UUID(),
            leaderWorkspaceId: oldWorkspaceID,
            leaderEndpoint: .peer(hostKey: "ssh:mac-sub"),
            workingDirectory: "/project/term-mesh",
            workspaceId: oldWorkspaceID,
            agents: [member],
            createdAt: Date(),
            worktreeMode: "isolated"
        )

        let moved = TeamOrchestrator.projectPresentationTeam(
            team,
            movedTo: newWorkspaceID
        )

        XCTAssertEqual(moved.workspaceId, newWorkspaceID)
        XCTAssertNil(moved.leaderWorkspaceId)
        XCTAssertEqual(moved.agents[0].workspaceId, newWorkspaceID)
        XCTAssertNil(moved.agents[0].panelId)
        XCTAssertEqual(moved.agents[0].agentInstanceId, instanceID)
        XCTAssertEqual(moved.agents[0].remoteSurfaceID, surfaceID)
        XCTAssertEqual(moved.agents[0].hostKey, "ssh:mac-sub")
    }

    @MainActor
    func test_window_close_preserves_and_re_adopts_exact_project_workspace() {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "preserve-\(UUID().uuidString)"
        let source = TabManager()
        let destination = TabManager()
        let workspace = source.addWorkspace(
            workingDirectory: "/tmp/\(teamName)",
            select: true
        )
        guard let anchorPanelID = workspace.focusedPanelId,
              let nativeAgent = workspace.newAgentSplit(
                  from: anchorPanelID,
                  orientation: .horizontal,
                  agentName: "executor",
                  teamName: teamName,
                  workingDirectory: "/tmp/\(teamName)"
              )
        else {
            XCTFail("expected native agent panel")
            return
        }
        let nativeSession = nativeAgent.session
        defer {
            _ = orchestrator.takePreservedProjectPresentation(teamName: teamName)
        }

        let panelIDs = Set(workspace.panels.keys)
        let detached = source.detachWorkspace(tabId: workspace.id)
        XCTAssertTrue(detached === workspace)
        orchestrator.rememberPreservedProjectPresentation(
            teamName: teamName,
            workspace: workspace
        )

        XCTAssertFalse(source.tabs.contains(where: { $0.id == workspace.id }))
        XCTAssertTrue(orchestrator.hasPreservedProjectPresentation(teamName: teamName))

        let adopted = orchestrator.takePreservedProjectPresentation(teamName: teamName)
        XCTAssertTrue(adopted === workspace)
        guard let adopted else {
            XCTFail("expected preserved workspace")
            return
        }
        destination.attachWorkspace(adopted, select: true)

        XCTAssertTrue(destination.tabs.contains(where: { $0 === workspace }))
        XCTAssertEqual(Set(adopted.panels.keys), panelIDs)
        XCTAssertTrue(adopted.agentPanel(for: nativeAgent.id) === nativeAgent)
        XCTAssertTrue(adopted.agentPanel(for: nativeAgent.id)?.session === nativeSession)
    }

    @MainActor
    func test_sidebar_window_mover_relocates_exact_workspace_and_reobserves_directory() {
        let source = TabManager()
        let destination = TabManager()
        let workspace = source.addWorkspace(
            workingDirectory: "/tmp/window-move-source",
            select: true
        )
        let sourceCount = source.tabs.count
        let destinationCount = destination.tabs.count

        XCTAssertTrue(
            SidebarWorkspaceWindowMover.move(
                tabId: workspace.id,
                from: source,
                to: destination
            )
        )
        XCTAssertFalse(source.tabs.contains(where: { $0 === workspace }))
        XCTAssertTrue(destination.tabs.contains(where: { $0 === workspace }))
        XCTAssertEqual(source.tabs.count, sourceCount - 1)
        XCTAssertEqual(destination.tabs.count, destinationCount + 1)
        XCTAssertEqual(destination.selectedTabId, workspace.id)

        let saveRequestsBeforeDirectoryChange = destination.debugSessionSaveRequestCount
        workspace.currentDirectory = "/tmp/window-move-destination"
        XCTAssertEqual(
            destination.debugSessionSaveRequestCount,
            saveRequestsBeforeDirectoryChange + 1,
            "attachWorkspace must reinstall the directory observer removed by detachWorkspace"
        )
    }

    @MainActor
    func test_sidebar_window_mover_rejectsSameWindowAndUnknownWorkspace() {
        let source = TabManager()
        let workspace = source.tabs[0]

        XCTAssertFalse(
            SidebarWorkspaceWindowMover.move(
                tabId: workspace.id,
                from: source,
                to: source
            )
        )
        XCTAssertFalse(
            SidebarWorkspaceWindowMover.move(
                tabId: UUID(),
                from: source,
                to: TabManager()
            )
        )
        XCTAssertTrue(source.tabs.contains(where: { $0 === workspace }))
    }

    @MainActor
    func test_window_close_does_not_tombstone_preserved_project_workspace() {
        let preserved = UUID()
        let ordinaryWorkspace = UUID()

        let closed = AppDelegate.workspaceIDsClosedWithWindow(
            preserved: [preserved],
            remaining: [ordinaryWorkspace, preserved]
        )

        XCTAssertEqual(closed, [ordinaryWorkspace])
        XCTAssertFalse(closed.contains(preserved))
    }

    @MainActor
    func test_window_close_notification_cleanup_uses_only_closed_workspaces() {
        let preserved = UUID()
        let closed = UUID()

        let notificationCleanup = AppDelegate.workspaceIDsClosedWithWindow(
            preserved: [preserved],
            remaining: [preserved, closed]
        )

        XCTAssertEqual(notificationCleanup, [closed])
        XCTAssertFalse(
            notificationCleanup.contains(preserved),
            "a preserved live project still owns notifications that can be opened later"
        )
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

        // Escaped for the same reason as the codex leader above: quoted once
        // for the CLI, then again by `exec /bin/sh -lc`.
        XCTAssertTrue(launch.contains(#"claude --model '\''sonnet'\''"#))
        XCTAssertTrue(launch.contains("--system-prompt"))
        XCTAssertTrue(launch.contains("TERMMESH_LEADER_PROMPT=$(cat"))
        XCTAssertTrue(launch.contains("rm -f"))
        XCTAssertTrue(launch.contains("--dangerously-skip-permissions"))
    }

    @MainActor
    func test_all_peer_leader_clis_receive_the_canonical_policy_directive() {
        let promptFile = "/tmp/term-mesh-leader-policy.md"
        let directive = LeaderParallelPolicy.launchDirective(promptFile: promptFile)
        XCTAssertTrue(directive.contains("version \(LeaderParallelPolicy.version)"))
        XCTAssertTrue(directive.contains("digest \(LeaderParallelPolicy.digest)"))

        for (cli, expectedLaunch) in [
            // Read straight off `remoteAgentCommand`, so the model carries the
            // single level of quoting it is built with — no `sh -lc` wrapper
            // here to escape it a second time.
            ("codex", "codex --model 'gpt-5'"),
            ("kiro", "kiro chat --model 'gpt-5'"),
            ("gemini", "gemini --model 'gpt-5'"),
        ] {
            let launch = TeamOrchestrator.remoteAgentCommand(
                cli: cli,
                model: "gpt-5",
                agentName: "leader",
                teamName: "demo",
                workingDirectory: "/srv/demo",
                systemPromptFile: promptFile
            )
            XCTAssertTrue(launch.contains(expectedLaunch), "\(cli) launch missing")
            XCTAssertTrue(launch.contains(promptFile), "\(cli) policy file missing")
            XCTAssertTrue(launch.contains(LeaderParallelPolicy.digest), "\(cli) policy digest missing")
        }
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
        XCTAssertEqual(
            RemoteShellPath.binDirs.first,
            "$HOME/.local/bin"
        )
        XCTAssertTrue(launch.contains("$HOME/.local/bin"))
        XCTAssertTrue(launch.contains(":\"$PATH\""), "the host's own PATH must survive, last")
        // Ordering matters as much as membership: a cd into the project before
        // PATH is set would run the CLI lookup with the old PATH.
        let pathEnd = try? XCTUnwrap(launch.range(of: ":\"$PATH\";"))
        let cd = try? XCTUnwrap(launch.range(of: "cd '"))
        if let pathEnd, let cd {
            XCTAssertLessThan(pathEnd.lowerBound, cd.lowerBound)
        }
    }

    /// The host profile's environment reaches a typed launch as an
    /// assignment prefix on the CLI itself, values quoted, keys validated.
    @MainActor
    func test_remote_launch_carries_the_hosts_environment() {
        let launch = TeamOrchestrator.remoteAgentCommand(
            cli: "claude",
            model: "sonnet",
            agentName: "worker",
            teamName: "demo",
            workingDirectory: "/srv/demo",
            environment: [
                "IS_SANDBOX": "1",
                "HTTP_PROXY": "http://proxy:3128",
                "bad-key": "dropped",
                "QUOTED": "it's",
            ]
        )
        XCTAssertTrue(
            launch.contains(
                "HTTP_PROXY='http://proxy:3128' IS_SANDBOX='1' QUOTED='it'\\''s' claude"
            ),
            "sorted assignments, quoted values, directly before the CLI: \(launch)"
        )
        XCTAssertFalse(launch.contains("bad-key"), "invalid names never reach the shell")
    }

    /// The exact field-paste failure: a chat block with a URL inside it must
    /// die in the form, not as `fatal: protocol 'available skills\n https'`
    /// from a remote git.
    func test_repository_url_rejects_pasted_prose() {
        XCTAssertNotNil(PeerProjectBootstrap.repositoryURLProblem(
            "available skills\n https://github.com/org/repo.git"
        ))
        XCTAssertNotNil(PeerProjectBootstrap.repositoryURLProblem("two words"))
        XCTAssertNotNil(PeerProjectBootstrap.repositoryURLProblem("no-colon-no-path"))
        XCTAssertNotNil(PeerProjectBootstrap.repositoryURLProblem("bad scheme://x"))
    }

    func test_repository_url_accepts_the_shapes_git_does() {
        XCTAssertNil(PeerProjectBootstrap.repositoryURLProblem(""))
        XCTAssertNil(PeerProjectBootstrap.repositoryURLProblem("  \n"))
        XCTAssertNil(PeerProjectBootstrap.repositoryURLProblem(
            "https://github.com/org/repo.git"
        ))
        XCTAssertNil(PeerProjectBootstrap.repositoryURLProblem(
            "git@github.com:org/repo.git"
        ))
        XCTAssertNil(PeerProjectBootstrap.repositoryURLProblem(
            "ssh://git@host:2222/org/repo.git"
        ))
        XCTAssertNil(PeerProjectBootstrap.repositoryURLProblem("/srv/git/repo.git"))
        XCTAssertNil(PeerProjectBootstrap.repositoryURLProblem("~/repos/demo"))
        // Leading/trailing paste debris is forgiven; interior junk is not.
        XCTAssertNil(PeerProjectBootstrap.repositoryURLProblem(
            "  https://github.com/org/repo.git\n"
        ))
    }

    func test_inline_assignments_are_empty_for_no_valid_variables() {
        XCTAssertEqual(PeerHostEnvironment.inlineAssignments([:]), "")
        XCTAssertEqual(PeerHostEnvironment.inlineAssignments(["2bad": "x", "a-b": "y"]), "")
        XCTAssertEqual(
            PeerHostEnvironment.inlineAssignments(["GOOD": "kept", "한글": "dropped"]),
            "GOOD='kept'",
            "legacy shell callers keep valid siblings; typed ensure validates the whole map"
        )
        XCTAssertEqual(
            PeerHostEnvironment.inlineAssignments(["_OK": "v"]),
            "_OK='v'"
        )
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
        XCTAssertTrue(launch.hasPrefix(RemoteShellPath.prologue()))
        XCTAssertTrue(RemoteShellPath.binDirs.contains("$HOME/.local/bin"))
    }

    @MainActor
    func test_remote_launch_prepends_authenticated_shell_quoted_host_bin_dirs() {
        let hostBinDirs = [
            "/Applications/Term Mesh.app/Contents/Resources/bin",
            "/opt/it's-here/bin",
        ]
        let launch = TeamOrchestrator.remoteAgentCommand(
            cli: "codex",
            model: "gpt-5",
            agentName: "executor",
            teamName: "quoted-path",
            workingDirectory: "/tmp/project",
            hostBinDirs: hostBinDirs
        )

        XCTAssertTrue(launch.hasPrefix(RemoteShellPath.prologue(hostBinDirs: hostBinDirs)))
        XCTAssertTrue(launch.contains("'/Applications/Term Mesh.app/Contents/Resources/bin'"))
        XCTAssertTrue(launch.contains("'/opt/it'\\''s-here/bin'"))
        XCTAssertTrue(launch.contains("\"$HOME/.local/bin\""))
        XCTAssertTrue(launch.contains(":\"$PATH\"; mkdir -p"))
    }

    func test_readiness_bin_dirs_match_exact_saved_profile_identity() {
        let wantedID = UUID()
        let hosts = [
            HostEntry(
                id: "ssh:stale",
                displayName: "stale",
                connectionState: .connected,
                workspaces: [],
                activeSockPath: "/tmp/stale.sock",
                sshTarget: "shared",
                remoteSockPath: "/tmp/shared.sock",
                profileID: UUID(),
                hostCLIBinDirs: ["/stale/bin"],
                hostCLIBinDirsResolved: true,
                configuredEndpoint: PeerHostEndpointProvenance(
                    sshTarget: "shared", port: nil, identityFile: nil,
                    remoteSocket: "/tmp/shared.sock"
                ),
                hostCLIBinDirsProvenance: PeerHostEndpointProvenance(
                    sshTarget: "shared", port: nil, identityFile: nil,
                    remoteSocket: "/tmp/shared.sock"
                )
            ),
            HostEntry(
                id: "ssh:saved",
                displayName: "saved",
                connectionState: .connected,
                workspaces: [],
                activeSockPath: "/tmp/saved.sock",
                sshTarget: "shared",
                remoteSockPath: "/tmp/shared.sock",
                sshPort: 22,
                identityFile: "/Users/x/.ssh/id_ed25519",
                profileID: wantedID,
                hostCLIBinDirs: ["/exact/bin"],
                hostCLIBinDirsResolved: true,
                configuredEndpoint: PeerHostEndpointProvenance(
                    sshTarget: "shared", port: 22,
                    identityFile: "/Users/x/.ssh/id_ed25519",
                    remoteSocket: "/tmp/shared.sock"
                ),
                hostCLIBinDirsProvenance: PeerHostEndpointProvenance(
                    sshTarget: "shared", port: 22,
                    identityFile: "/Users/x/.ssh/id_ed25519",
                    remoteSocket: "/tmp/shared.sock"
                )
            ),
        ]

        XCTAssertEqual(
            RemoteHostStore.hostCLIBinDirs(
                forProfileID: wantedID,
                sshTarget: "shared",
                port: 22,
                identityFile: "/Users/x/.ssh/id_ed25519",
                remoteSocket: "/tmp/shared.sock",
                in: hosts
            ),
            ["/exact/bin"]
        )
        XCTAssertEqual(
            RemoteHostStore.hostCLIBinDirs(
                forProfileID: UUID(),
                sshTarget: "shared",
                port: 22,
                identityFile: "/Users/x/.ssh/id_ed25519",
                remoteSocket: "/tmp/shared.sock",
                in: hosts
            ),
            []
        )
    }

    /// The stale-cache leak the exact-SHA review flagged: a profile keeps
    /// its id across an edit to sshTarget/port/identityFile/remoteSocket,
    /// so matching on `profileID` alone (the pre-fix behavior) would still
    /// return a still-`.connected` host's authenticated bin dirs even
    /// though that connection was never authenticated against the
    /// endpoint the caller is now asking about.
    func test_readiness_bin_dirs_reject_stale_endpoint_on_the_same_profile_id() {
        let wantedID = UUID()
        let connectedUnderOldEndpoint = HostEntry(
            id: "ssh:old",
            displayName: "old",
            connectionState: .connected,
            workspaces: [],
            activeSockPath: "/tmp/old.sock",
            sshTarget: "old-target",
            remoteSockPath: "/tmp/old.sock",
            sshPort: 22,
            identityFile: "/Users/x/.ssh/id_old",
            profileID: wantedID,
            hostCLIBinDirs: ["/old/bin"],
            hostCLIBinDirsResolved: true,
            configuredEndpoint: PeerHostEndpointProvenance(
                sshTarget: "old-target", port: 22,
                identityFile: "/Users/x/.ssh/id_old",
                remoteSocket: "/tmp/old.sock"
            ),
            hostCLIBinDirsProvenance: PeerHostEndpointProvenance(
                sshTarget: "old-target", port: 22,
                identityFile: "/Users/x/.ssh/id_old",
                remoteSocket: "/tmp/old.sock"
            )
        )

        // sshTarget changed since that connection was authenticated.
        XCTAssertEqual(
            RemoteHostStore.hostCLIBinDirs(
                forProfileID: wantedID,
                sshTarget: "new-target",
                port: 22,
                identityFile: "/Users/x/.ssh/id_old",
                remoteSocket: "/tmp/old.sock",
                in: [connectedUnderOldEndpoint]
            ),
            []
        )
        // port changed.
        XCTAssertEqual(
            RemoteHostStore.hostCLIBinDirs(
                forProfileID: wantedID,
                sshTarget: "old-target",
                port: 2222,
                identityFile: "/Users/x/.ssh/id_old",
                remoteSocket: "/tmp/old.sock",
                in: [connectedUnderOldEndpoint]
            ),
            []
        )
        // identityFile changed.
        XCTAssertEqual(
            RemoteHostStore.hostCLIBinDirs(
                forProfileID: wantedID,
                sshTarget: "old-target",
                port: 22,
                identityFile: "/Users/x/.ssh/id_new",
                remoteSocket: "/tmp/old.sock",
                in: [connectedUnderOldEndpoint]
            ),
            []
        )
        // pinned remote socket changed.
        XCTAssertEqual(
            RemoteHostStore.hostCLIBinDirs(
                forProfileID: wantedID,
                sshTarget: "old-target",
                port: 22,
                identityFile: "/Users/x/.ssh/id_old",
                remoteSocket: "/tmp/new.sock",
                in: [connectedUnderOldEndpoint]
            ),
            []
        )
        // Unchanged tuple still matches — the guard isn't overzealous.
        XCTAssertEqual(
            RemoteHostStore.hostCLIBinDirs(
                forProfileID: wantedID,
                sshTarget: "old-target",
                port: 22,
                identityFile: "/Users/x/.ssh/id_old",
                remoteSocket: "/tmp/old.sock",
                in: [connectedUnderOldEndpoint]
            ),
            ["/old/bin"]
        )
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

    @MainActor
    func test_remote_launch_shell_quotes_the_model() {
        let launch = TeamOrchestrator.remoteAgentCommand(
            cli: "claude",
            model: "sonnet; touch /tmp/term-mesh-injected #",
            agentName: "worker",
            teamName: "demo",
            workingDirectory: "/srv/demo"
        )

        XCTAssertTrue(launch.contains("--model 'sonnet; touch /tmp/term-mesh-injected #'"))
        XCTAssertFalse(launch.contains("--model sonnet;"))
    }

    func test_process_run_timeout_escalates_to_sigkill() async throws {
        let started = Date()
        let output = try await ProcessRun.capture(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 0.05
        )

        XCTAssertTrue(output.timedOut)
        XCTAssertNotEqual(output.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func test_process_run_timeout_kills_descendant_after_parent_exits_on_term() async throws {
        let pidFile = "/tmp/term-mesh-processrun-child-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let script = """
        trap 'exit 0' TERM
        /bin/sh -c 'trap "" TERM; exec >/dev/null 2>&1; echo $$ > \(pidFile); while :; do sleep 1; done' &
        wait
        """

        let output = try await ProcessRun.capture(
            executable: "/bin/sh",
            arguments: ["-c", script],
            timeout: 0.2
        )

        XCTAssertTrue(output.timedOut)
        let childPID = try XCTUnwrap(
            Int32(
                String(contentsOfFile: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        defer { Darwin.kill(childPID, SIGKILL) }
        let deadline = Date().addingTimeInterval(1)
        while Darwin.kill(childPID, 0) == 0, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(
            Darwin.kill(childPID, 0),
            -1,
            "timeout must not leave a TERM-ignoring descendant alive"
        )
    }

    /// A local bootstrap whose script floods stderr must finish, not time out.
    ///
    /// `runLocalScript` used to attach stderr to a pipe and read it only once
    /// the process had already exited. A `git clone` that emits enough
    /// progress fills the 64 KiB pipe buffer, the child blocks in `write`,
    /// the parent keeps polling `isRunning`, and a perfectly healthy
    /// bootstrap is reported as `.timedOut`. Driving `runLocal` for real is
    /// what makes this a regression test for *that* function: a version that
    /// reintroduces a bespoke `Process` loop fails here even though the
    /// `ProcessRun` tests above still pass.
    func test_local_bootstrap_survives_a_stderr_flood_from_git() async throws {
        let root = NSTemporaryDirectory() + "tm-bootstrap-\(UUID().uuidString)"
        let source = root + "/source"
        try FileManager.default.createDirectory(
            atPath: source, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        // A source repo with enough objects that clone/checkout chatter is
        // real rather than a single quiet line.
        let seed = """
        set -e
        cd \(source)
        git init -q .
        git config user.email t@example.com
        git config user.name t
        for i in $(seq 1 400); do
          mkdir -p "dir$((i % 20))"
          printf 'content %s\\n' "$i" > "dir$((i % 20))/file$i.txt"
        done
        git add -A
        git commit -qm seed
        """
        let seeded = try await ProcessRun.capture(
            executable: "/bin/sh", arguments: ["-lc", seed], timeout: 60
        )
        try XCTSkipUnless(seeded.status == 0, "git unavailable: \(seeded.stderrText)")

        let plan = PeerProjectBootstrap.plan(
            projectRoot: root,
            projectName: "checkout",
            agents: ["executor", "reviewer"],
            isolateAgents: true
        )
        let started = Date()
        try await PeerProjectBootstrap.runLocal(
            plan: plan,
            gitURL: source,
            sourceKind: .clone,
            memMeshProjectID: nil,
            timeoutSeconds: 120
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 120,
            "a healthy bootstrap must not be reported as a timeout"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plan.primaryPath),
            "the project checkout must exist after a successful bootstrap"
        )
        for checkout in plan.agentCheckouts {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: checkout.path),
                "agent checkout missing: \(checkout.path)"
            )
        }
    }

    /// The actual deadlock: a script that writes past the pipe buffer.
    ///
    /// The old `runLocalScript` attached stderr to a pipe and read it only
    /// after the process exited. Once the child has written 64 KiB with
    /// nobody draining, it blocks in `write` forever, the parent keeps
    /// polling `isRunning`, and a script that would have finished instantly
    /// is reported as `.timedOut`. This drives the function directly because
    /// `runLocal` cannot reach the condition — git emits progress only to a
    /// TTY, so a piped clone never fills the buffer.
    func test_run_local_script_does_not_deadlock_on_large_stderr() async throws {
        let started = Date()
        try await PeerProjectBootstrap.runLocalScript(
            // ~1 MiB of stderr, well past the 64 KiB pipe buffer.
            "i=0; while [ $i -lt 8192 ]; do "
                + "printf '%0128d\\n' $i >&2; i=$((i+1)); done; exit 0",
            timeoutSeconds: 30
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 30,
            "an undrained stderr pipe must not turn a fast script into a timeout"
        )
    }

    /// The same flood on a failing script must still surface its message
    /// rather than a bare exit code — the drain has to survive the error path
    /// too, and the message the user sees comes out of it.
    func test_run_local_script_reports_stderr_from_a_failing_flood() async throws {
        do {
            try await PeerProjectBootstrap.runLocalScript(
                "i=0; while [ $i -lt 8192 ]; do "
                    + "printf '%0128d\\n' $i >&2; i=$((i+1)); done; "
                    + "echo 'fatal: could not read Username' >&2; exit 128",
                timeoutSeconds: 30
            )
            XCTFail("a non-zero exit must be reported as a failure")
        } catch let error as PeerProjectBootstrap.ProjectBootstrapError {
            guard case .commandFailed(let message) = error else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(
                message.contains("could not read Username"),
                "the real diagnostic must survive the flood, got: \(message.suffix(120))"
            )
        }
    }

    /// The timeout path must not leave a descendant mutating the checkout.
    ///
    /// The old implementation sent `terminate()` to `/bin/sh` alone and
    /// resumed its continuation immediately, so a `git` still running under
    /// that shell kept writing while the caller had already started
    /// transaction rollback or a retry — two writers in one directory.
    /// `ProcessRun.capture` kills the whole process group and waits for it.
    func test_run_local_script_timeout_kills_a_term_ignoring_descendant() async throws {
        let pidFile = NSTemporaryDirectory() + "tm-bootstrap-child-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let started = Date()
        do {
            try await PeerProjectBootstrap.runLocalScript(
                """
                trap 'exit 0' TERM
                /bin/sh -c 'trap "" TERM; exec >/dev/null 2>&1; \
                echo $$ > \(pidFile); while :; do sleep 1; done' &
                wait
                """,
                timeoutSeconds: 0.3
            )
            XCTFail("a script that never finishes must report a timeout")
        } catch let error as PeerProjectBootstrap.ProjectBootstrapError {
            guard case .timedOut = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)

        let childPID = try XCTUnwrap(
            Int32(
                String(contentsOfFile: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        defer { Darwin.kill(childPID, SIGKILL) }
        let deadline = Date().addingTimeInterval(2)
        while Darwin.kill(childPID, 0) == 0, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(
            Darwin.kill(childPID, 0), -1,
            "rollback must not race a surviving descendant of the timed-out script"
        )
    }

    func test_remote_leader_hex_route_decodes_exact_width_only() {
        XCTAssertEqual(
            TerminalController.decodeFixedHex("0011aaff", byteCount: 4),
            Data([0x00, 0x11, 0xAA, 0xFF])
        )
        XCTAssertNil(TerminalController.decodeFixedHex("0011aa", byteCount: 4))
        XCTAssertNil(TerminalController.decodeFixedHex("0011zzff", byteCount: 4))
    }

    // MARK: - Who the creation sheet waits for
    //
    // `createTeam` returns as soon as the team record exists while the peer
    // attaches run on behind it, so the sheet used to close on a success that
    // had not happened. A leader could then fail to start with nothing left on
    // screen to say so — the only report was a log line and a pane title set on
    // a pane the failure had prevented from existing. These fix who is expected
    // to report, which is what the wait is measured against.

    @MainActor
    func test_onlyPeerParticipantsAreWaitedFor() {
        let participants = ProjectCreationFlow.remoteParticipantLabels(
            leaderEndpoint: .peer(hostKey: "ssh:mac-sub"),
            rows: [
                row("executor", hostKey: "ssh:mac-sub", directory: "/w/e"),
                row("reviewer", hostKey: nil)
            ]
        )
        XCTAssertEqual(participants.map(\.label), ["leader", "Executor"],
                       "a local agent has no attach to wait on")
        XCTAssertEqual(participants.first?.stepID, "leader")
    }

    @MainActor
    func test_aLocalLeaderIsNotWaitedFor() {
        let participants = ProjectCreationFlow.remoteParticipantLabels(
            leaderEndpoint: .local,
            rows: [row("executor", hostKey: "ssh:mac-sub", directory: "/w/e")]
        )
        XCTAssertEqual(participants.map(\.label), ["Executor"])
    }

    @MainActor
    func test_anAllLocalTeamWaitsForNobody() {
        XCTAssertTrue(
            ProjectCreationFlow.remoteParticipantLabels(
                leaderEndpoint: .local,
                rows: [row("executor", hostKey: nil)]
            ).isEmpty,
            "waiting on a settle that will never be reported would hang the sheet"
        )
    }

    // MARK: - Seeding a pane into a freshly created peer workspace
    //
    // The leader is placed by creating a workspace on the peer and then asking
    // it to open a tab. That ask carries an empty `pane_id` — the workspace has
    // no pane to name yet — and a `workspace_id`, which is the field the proto
    // added for exactly this. The Rust host reads both. The Mac host read only
    // `pane_id`, so the empty id failed its guard and the request did nothing:
    // the placement loop then waited fifteen polls for a pane nobody was going
    // to open, and the project came up with every agent running and no leader.

    func test_anEmptyPaneIDFallsBackToTheNamedWorkspace() {
        XCTAssertEqual(
            GhosttyPaneSurfaceProvider.newTabTarget(
                paneResolved: false,
                hasWorkspaceID: true,
                workspaceFound: true,
                workspaceHasPanels: false
            ),
            .seedWorkspace
        )
    }

    func test_aResolvablePaneWins() {
        XCTAssertEqual(
            GhosttyPaneSurfaceProvider.newTabTarget(
                paneResolved: true,
                hasWorkspaceID: true,
                workspaceFound: true,
                workspaceHasPanels: false
            ),
            .besidePane,
            "workspace_id is the empty-workspace fallback, not an override"
        )
    }

    /// Once the workspace has a panel, an unresolvable pane id is a stale
    /// locator — seeding another terminal off it would be a second, unasked-for
    /// tab every time a client retried with an old id.
    ///
    /// The condition counts *panels*, not surfaces, and the difference is the
    /// whole second half of this bug: `createWorkspace` leaves a workspace with
    /// one panel and no surface, so this correctly declines to seed while the
    /// asking machine still reports an empty workspace. Realizing that panel is
    /// a separate job (`TabManager.surfaceRealizationPins`) — reading this
    /// parameter as "has surfaces" sends you to seed a pane that already exists.
    func test_aWorkspaceThatAlreadyHasAPanelIsNotSeededAgain() {
        XCTAssertEqual(
            GhosttyPaneSurfaceProvider.newTabTarget(
                paneResolved: false,
                hasWorkspaceID: true,
                workspaceFound: true,
                workspaceHasPanels: true
            ),
            .ignore
        )
    }

    func test_nothingToActOnIsIgnored() {
        XCTAssertEqual(
            GhosttyPaneSurfaceProvider.newTabTarget(
                paneResolved: false,
                hasWorkspaceID: false,
                workspaceFound: false,
                workspaceHasPanels: false
            ),
            .ignore,
            "the pre-fix behaviour for every request, which is why it was silent"
        )
        XCTAssertEqual(
            GhosttyPaneSurfaceProvider.newTabTarget(
                paneResolved: false,
                hasWorkspaceID: true,
                workspaceFound: false,
                workspaceHasPanels: false
            ),
            .ignore,
            "a workspace id this host does not know is not a licence to guess one"
        )
    }

    /// The failure that started this carried only a host name, so the sheet had
    /// nothing to show and Troubleshoot had nothing to open.
    func test_workspaceUnavailableSaysWhatItWaitedForAndWhetherItAsked() {
        let asked = TeamOrchestrator.RemoteAgentError.projectWorkspaceUnavailable(
            host: "mac-sub",
            workspaceID: "a1b2c3d4",
            attempts: 15,
            seedRequested: true
        ).description
        XCTAssertTrue(asked.contains("15 time(s)"), asked)
        XCTAssertTrue(asked.contains("a1b2c3d4"), asked)
        XCTAssertTrue(asked.contains("after asking it to open one"), asked)

        let neverAsked = TeamOrchestrator.RemoteAgentError.projectWorkspaceUnavailable(
            host: "mac-sub",
            workspaceID: "a1b2c3d4",
            attempts: 3,
            seedRequested: false
        ).description
        XCTAssertTrue(neverAsked.contains("without getting as far as asking"), neverAsked)

        let noWorkspace = TeamOrchestrator.RemoteAgentError.projectWorkspaceUnavailable(
            host: "mac-sub",
            workspaceID: nil,
            attempts: 0,
            seedRequested: false
        ).description
        XCTAssertTrue(noWorkspace.contains("never reported a workspace"), noWorkspace)
    }
}

/// Findings from the adversarial review of #196, each verified in the code
/// before being fixed. Two of the three were introduced by that PR itself:
/// keeping the sheet up on failure is what leaves a team behind for `Retry`
/// to trip over, and letting `auto` step aside is what made a run without
/// isolation indistinguishable from one with it.
@MainActor
final class ProjectCreationRecoveryTests: XCTestCase {

    /// `leaderReady` is documented as "false while a requested peer leader is
    /// still connecting or failed to launch" — the one field that separates a
    /// project that is open from the wreckage of an attempt that was not.
    /// Without consulting it, `Retry project` selected the half-built
    /// workspace and returned success: the recovery button closing the sheet
    /// without recovering anything.
    func test_theFieldThatSeparatesAnOpenProjectFromAFailedAttempt() {
        var team = TeamOrchestrator.Team(
            id: "xm",
            leaderSessionId: UUID().uuidString,
            leaderMode: "codex",
            leaderModel: "gpt-5.6-sol",
            leaderCli: "codex",
            leaderPanelId: UUID(),
            workingDirectory: "/w",
            workspaceId: UUID(),
            agents: [],
            createdAt: Date(),
            worktreeMode: "off"
        )
        XCTAssertTrue(team.leaderReady, "a team is usable until something says otherwise")

        team.leaderReady = false
        team.leaderFailureDescription = "could not prepare the project workspace"
        XCTAssertFalse(
            team.leaderReady,
            "Retry must see this and repair rather than select and report success"
        )
    }

    /// The leader is not the only thing that can be missing, and `leaderReady`
    /// says nothing about the rest: an agent failure appends to the sheet's own
    /// list and writes nothing to the team. Retry checking only the leader
    /// still reported success for a project with no executor in it.
    func test_aMissingMemberIsNoticedEvenWhenTheLeaderIsFine() {
        let requested = ["executor", "reviewer"]
        let joined: Set<String> = ["reviewer"]
        let missing = requested.filter { !joined.contains($0) }
        XCTAssertEqual(
            missing, ["executor"],
            "a healthy leader must not make a half-empty team read as complete"
        )
    }

    /// Local members are left out on purpose: they are created by the local
    /// engine under names this comparison does not own, and reporting them as
    /// missing would block Retry on a project that is fine.
    func test_onlyRemoteMembersAreComparedAgainstTheRoster() {
        let rows: [(name: String, remote: Bool)] = [
            ("executor", true), ("planner", false), ("reviewer", true),
        ]
        let joined: Set<String> = ["reviewer"]
        let missing = rows.filter { $0.remote && !joined.contains($0.name) }.map(\.name)
        XCTAssertEqual(missing, ["executor"])
    }

    /// Deletion tears down against a snapshot taken when it starts. An attach
    /// still in flight commits by writing a surface record and a checkout, so
    /// one that lands after that snapshot leaves a remote process running with
    /// nothing pointing at it. Retiring the generation makes the attach fail
    /// its next `ensureCurrent` instead.
    func test_retiringTheGenerationStopsAnAttachThatIsStillInFlight() {
        let gate = TeamOrchestrator.LeaderAttachGenerationGate.shared
        let inFlight = gate.begin(teamName: "xm-race")
        XCTAssertTrue(gate.isCurrent(inFlight))

        gate.invalidateAll(teamName: "xm-race")
        XCTAssertFalse(
            gate.isCurrent(inFlight),
            "an attach past this point must compensate rather than register anything"
        )
    }

    /// An agent attach is not the leader and carries no attempt, so it notices
    /// a retirement by snapshotting the value instead. Without this it commits
    /// a surface record and a team member into a roster the deletion has
    /// already walked past, and the remote process outlives both.
    func test_anAgentAttachNoticesARetirementWithoutHoldingAGeneration() {
        let gate = TeamOrchestrator.LeaderAttachGenerationGate.shared
        let snapshot = gate.current(teamName: "xm-agents")
        XCTAssertTrue(gate.isCurrent(teamName: "xm-agents", value: snapshot))

        gate.invalidateAll(teamName: "xm-agents")
        XCTAssertFalse(
            gate.isCurrent(teamName: "xm-agents", value: snapshot),
            "the attach must refuse to commit from here"
        )
    }

    /// The leader's own gate and an agent's snapshot read the same counter, so
    /// one deletion retires both rather than only whichever mechanism the
    /// caller happened to use.
    func test_oneRetirementCoversTheLeaderAndItsAgents() {
        let gate = TeamOrchestrator.LeaderAttachGenerationGate.shared
        let leader = gate.begin(teamName: "xm-both")
        let agentSnapshot = gate.current(teamName: "xm-both")

        gate.invalidateAll(teamName: "xm-both")
        XCTAssertFalse(gate.isCurrent(leader))
        XCTAssertFalse(gate.isCurrent(teamName: "xm-both", value: agentSnapshot))
    }

    /// A caller holding no generation is exactly the deletion case, and it
    /// must still retire one that was never begun — a team whose first attach
    /// has not started yet is not a team that may be raced later.
    func test_retiringWorksForATeamThatNeverBeganAnAttach() {
        let gate = TeamOrchestrator.LeaderAttachGenerationGate.shared
        gate.invalidateAll(teamName: "xm-never-began")
        let after = gate.begin(teamName: "xm-never-began")
        XCTAssertTrue(gate.isCurrent(after), "a later attach starts clean")
    }

    func test_scopedLeaderAddCannotChooseAnotherHostOrDirectory() {
        let params = GhosttyPaneSurfaceProvider.canonicalizeScopedLeaderParameters(
            [
                "team_name": "forged-team",
                "host": "ssh:attacker",
                "directory": "/etc",
                "cli": "codex",
            ],
            method: "team.add_agent",
            teamName: "xm",
            leaderHostKey: "ssh:root@131.186.23.19",
            leaderDirectory: "/app/tm-prj/xm"
        )

        XCTAssertEqual(params["team"] as? String, "xm")
        XCTAssertEqual(params["team_name"] as? String, "xm")
        XCTAssertEqual(params["host"] as? String, "ssh:root@131.186.23.19")
        XCTAssertEqual(params["directory"] as? String, "/app/tm-prj/xm")
        XCTAssertEqual(params["cli"] as? String, "codex")
    }
}
