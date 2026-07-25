import XCTest

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
}
