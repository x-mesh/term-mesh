import XCTest
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerProjectBootstrapTests: XCTestCase {
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

    func test_clones_each_agent_from_the_copy_on_that_machine() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let script = PeerProjectBootstrap.script(for: plan, gitURL: "git@github.com:org/x.git")
        let text = try! XCTUnwrap(script)
        XCTAssertTrue(text.contains("git clone 'git@github.com:org/x.git' '/app/p/x'"))
        // The member's copy comes from the one already here — the network and
        // any credentials are needed once, for the project.
        XCTAssertTrue(text.contains("git clone '/app/p/x' '/app/p/x-a'"))
        XCTAssertFalse(text.contains("--shared"), "borrowed objects break when the source is gc'd")
    }

    func test_running_it_twice_is_running_it_once() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: true
        )
        let text = try! XCTUnwrap(PeerProjectBootstrap.script(for: plan, gitURL: "u"))
        // Every step is guarded on its own result already existing.
        XCTAssertTrue(text.contains("test -d '/app/p/x'/.git ||"))
        XCTAssertTrue(text.contains("test -d '/app/p/x-a'/.git ||"))
        // A branch left over from a previous run is the normal second visit.
        XCTAssertTrue(text.contains("switch 'agent/a' 2>/dev/null || "))
    }

    func test_a_plain_shared_folder_needs_no_script() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/p", projectName: "x", agents: ["a"], isolateAgents: false
        )
        XCTAssertNil(PeerProjectBootstrap.script(for: plan, gitURL: nil))
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
}
