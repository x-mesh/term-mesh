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
            "/Applications/term-mesh.app/Contents/Resources/bin"
        )
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

    func test_remote_leader_hex_route_decodes_exact_width_only() {
        XCTAssertEqual(
            TerminalController.decodeFixedHex("0011aaff", byteCount: 4),
            Data([0x00, 0x11, 0xAA, 0xFF])
        )
        XCTAssertNil(TerminalController.decodeFixedHex("0011aa", byteCount: 4))
        XCTAssertNil(TerminalController.decodeFixedHex("0011zzff", byteCount: 4))
    }
}
