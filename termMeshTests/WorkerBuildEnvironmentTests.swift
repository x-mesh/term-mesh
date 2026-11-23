import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Workers get the Cargo trim only when the setting is on, never at the
/// expense of a value someone set on purpose or of the app-owned routing keys.
final class WorkerBuildEnvironmentTests: XCTestCase {

    func testOffAddsNothing() {
        XCTAssertEqual(WorkerBuildEnvironment.environment(enabled: false, inherited: [:]), [:])
    }

    func testOnAddsAllThreeVariables() {
        XCTAssertEqual(
            WorkerBuildEnvironment.environment(enabled: true, inherited: [:]),
            [
                "CARGO_INCREMENTAL": "0",
                "CARGO_PROFILE_DEV_DEBUG": "line-tables-only",
                "CARGO_PROFILE_TEST_DEBUG": "line-tables-only",
            ]
        )
    }

    func testAnInheritedValueIsNotOverridden() {
        let env = WorkerBuildEnvironment.environment(
            enabled: true,
            inherited: ["CARGO_INCREMENTAL": "1"]
        )
        XCTAssertNil(env["CARGO_INCREMENTAL"])
        XCTAssertEqual(env["CARGO_PROFILE_DEV_DEBUG"], "line-tables-only")
    }

    func testReadsTheStoredSetting() throws {
        let suite = "WorkerBuildEnvironmentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(WorkerBuildEnvironment.current(defaults: defaults, inherited: [:]), [:])
        defaults.set(true, forKey: WorkerBuildEnvironment.enabledKey)
        XCTAssertEqual(
            WorkerBuildEnvironment.current(defaults: defaults, inherited: [:]),
            [
                "CARGO_INCREMENTAL": "0",
                "CARGO_PROFILE_DEV_DEBUG": "line-tables-only",
                "CARGO_PROFILE_TEST_DEBUG": "line-tables-only",
            ]
        )
        XCTAssertEqual(
            WorkerBuildEnvironment.current(
                defaults: defaults, inherited: ["CARGO_INCREMENTAL": "1"]
            ),
            [
                "CARGO_PROFILE_DEV_DEBUG": "line-tables-only",
                "CARGO_PROFILE_TEST_DEBUG": "line-tables-only",
            ]
        )
    }

    func testHeadlessProfileValueWins() {
        let build = WorkerBuildEnvironment.environment(enabled: true, inherited: [:])
        let env = WorkerBuildEnvironment.headlessExtraEnv(
            profile: ["CARGO_INCREMENTAL": "1", "ANTHROPIC_BASE_URL": "https://gw"],
            build: build
        )
        XCTAssertEqual(env["CARGO_INCREMENTAL"], "1")
        XCTAssertEqual(env["CARGO_PROFILE_TEST_DEBUG"], "line-tables-only")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://gw")
    }

    func testHeadlessWithSettingOffKeepsOnlyTheProfile() {
        let env = WorkerBuildEnvironment.headlessExtraEnv(
            profile: ["ANTHROPIC_BASE_URL": "https://gw"],
            build: [:]
        )
        XCTAssertEqual(env, ["ANTHROPIC_BASE_URL": "https://gw"])
    }

    /// The pane path: build defaults under the routing keys, then the CLI
    /// profile on top through the existing `applyAgentProfileEnvironment`.
    @MainActor
    func testPaneProfileValueWinsAndRoutingIsKept() {
        let required = [
            "TERMMESH_TEAM_NAME": "team-a",
            "PATH": "/app/bin:/usr/bin",
        ]
        let build = WorkerBuildEnvironment.environment(enabled: true, inherited: [:])
        let withBuild = WorkerBuildEnvironment.paneEnvironment(required: required, build: build)
        XCTAssertEqual(withBuild["TERMMESH_TEAM_NAME"], "team-a")
        XCTAssertEqual(withBuild["CARGO_INCREMENTAL"], "0")

        let env = TeamOrchestrator.applyAgentProfileEnvironment(
            ["CARGO_PROFILE_DEV_DEBUG": "full", "TERMMESH_TEAM_NAME": "spoofed"],
            to: withBuild
        )
        XCTAssertEqual(env["CARGO_PROFILE_DEV_DEBUG"], "full")
        XCTAssertEqual(env["CARGO_INCREMENTAL"], "0")
        XCTAssertEqual(env["TERMMESH_TEAM_NAME"], "team-a")
    }
}
