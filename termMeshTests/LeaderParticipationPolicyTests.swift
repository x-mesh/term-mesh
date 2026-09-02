import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class LeaderParticipationPolicyTests: XCTestCase {
    func testEvaluatorIsDeterministicAndConservativeForUnknownInput() {
        let input = LeaderParticipationPolicy.Input(taskShape: "multi_unit", availableWorkers: 2)
        XCTAssertEqual(LeaderParticipationPolicy.evaluate(input), LeaderParticipationPolicy.evaluate(input))
        let unknown = LeaderParticipationPolicy.evaluate(.init(taskShape: "multi_unit"))
        XCTAssertEqual(unknown.participation, .handsOn)
        XCTAssertEqual(unknown.route, .direct)
        XCTAssertEqual(unknown.reasons, [.unsupportedInput])
    }

    func testEvaluatorMapsRiskAndParallelWorkToObservableBounds() {
        let risky = LeaderParticipationPolicy.evaluate(.init(taskShape: "multi_unit", riskReasons: ["release"], availableWorkers: 3))
        XCTAssertEqual(risky.route, .probe)
        XCTAssertEqual(risky.observableDispatchBounds, "at most one read-only probe")
        let parallel = LeaderParticipationPolicy.evaluate(.init(taskShape: "multi_unit", availableWorkers: 2))
        XCTAssertEqual(parallel.participation, .coordinator)
        XCTAssertEqual(parallel.route, .parallel)
    }

    /// Per-Project execution options are keyed by name, and the key used to
    /// drop every character it could not spell. A fully Korean name left
    /// nothing behind, so every such Project shared one entry and overwrote
    /// the others' settings.
    func testExecutionOptionsDoNotShareStorageBetweenNonASCIIProjectNames() {
        let defaults = UserDefaults(suiteName: "execution-options.\(UUID().uuidString)")!
        ProjectExecutionOptions(maxParallelWorkers: 2, injectDirective: false)
            .save(teamName: "번역팀", to: defaults)
        ProjectExecutionOptions(maxParallelWorkers: 5, injectDirective: true)
            .save(teamName: "검수팀", to: defaults)

        let first = ProjectExecutionOptions.load(teamName: "번역팀", from: defaults)
        let second = ProjectExecutionOptions.load(teamName: "검수팀", from: defaults)
        XCTAssertEqual(first.maxParallelWorkers, 2)
        XCTAssertFalse(first.injectDirective)
        XCTAssertEqual(second.maxParallelWorkers, 5)
        XCTAssertTrue(second.injectDirective)
        // A name the sanitizer never touched must keep the key it already
        // stored, or every existing preference silently reverts to the default.
        ProjectExecutionOptions(maxParallelWorkers: 4, injectDirective: false)
            .save(teamName: "aic", to: defaults)
        XCTAssertEqual(defaults.object(forKey: "team.aic.maxParallelWorkers") as? Int, 4)
    }

    func testFreshSettingsAreShadowWithNoCanaryAndRoundTripAdditively() {
        let defaults = UserDefaults(suiteName: "leader-participation.\(UUID().uuidString)")!
        XCTAssertEqual(LeaderParticipationSettings.load(from: defaults), .default)
        let saved = LeaderParticipationSettings(mode: .canary, canaryPercent: 17, killSwitch: false, optInProjects: ["project-a"])
        saved.save(to: defaults)
        XCTAssertEqual(LeaderParticipationSettings.load(from: defaults), saved)
    }

    func testCohortsAreStableAndKillSwitchRollsBackImmediately() {
        let health = LeaderParticipationSettings.Health(supportedTurns: 500, observedDays: 0, coverage: 0.95, linkage: 0.95, unknownRate: 0.02)
        var settings = LeaderParticipationSettings(mode: .canary, canaryPercent: 100, killSwitch: false, optInProjects: ["project"])
        XCTAssertEqual(settings.resolve(projectID: "project", sessionID: "session", supportedLeader: true, health: health), .canary(.canary))
        XCTAssertEqual(LeaderParticipationSettings.cohort(projectID: "project", sessionID: "session", percent: 50), LeaderParticipationSettings.cohort(projectID: "project", sessionID: "session", percent: 50))
        settings.killSwitch = true
        XCTAssertEqual(settings.resolve(projectID: "project", sessionID: "session", supportedLeader: true, health: health), .staticPolicy(.staticPolicy))
    }

    func testShadowNeverAppliesAndUnhealthyCanaryIsStaticHoldout() {
        let unhealthy = LeaderParticipationSettings.Health(supportedTurns: 1, observedDays: 0, coverage: 1, linkage: 1, unknownRate: 0)
        let shadow = LeaderParticipationSettings.default
        XCTAssertEqual(shadow.resolve(projectID: "p", sessionID: "s", supportedLeader: true, health: unhealthy), .shadow(.shadow))
        let canary = LeaderParticipationSettings(mode: .canary, canaryPercent: 100, killSwitch: false, optInProjects: ["p"])
        XCTAssertEqual(canary.resolve(projectID: "p", sessionID: "s", supportedLeader: true, health: unhealthy), .staticPolicy(.staticPolicy))
    }

    func testControlPayloadFailsClosedAndCarriesImmediateKillSwitch() {
        let healthy = LeaderParticipationSettings.Health(
            supportedTurns: 500, observedDays: 0, coverage: 0.95, linkage: 0.95, unknownRate: 0.02
        )
        let settings = LeaderParticipationSettings(
            mode: .canary, canaryPercent: 100, killSwitch: true, optInProjects: ["p"]
        )
        let payload = settings.controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: true, health: healthy
        )
        XCTAssertEqual(payload["mode"] as? String, "canary")
        XCTAssertEqual(payload["percent"] as? Int, 100)
        XCTAssertEqual(payload["kill_switch"] as? Bool, true)
        XCTAssertEqual(payload["healthy"] as? Bool, true)
        XCTAssertEqual(payload["opt_in"] as? Bool, true)
    }

    func testControlFileIsOwnerOnlyAndRemovedWithProjectCleanupPath() throws {
        let suite = "leader-control.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(LeaderParticipationSettings.Mode.canary.rawValue,
                     forKey: LeaderParticipationSettings.modeKey)
        defaults.set(true, forKey: LeaderParticipationSettings.killSwitchKey)
        let team = "test/../\(UUID().uuidString)"
        let path = TeamOrchestrator.leaderParticipationControlFile(teamName: team)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
            defaults.removePersistentDomain(forName: suite)
        }

        TeamOrchestrator.writeLeaderParticipationControl(
            teamName: team, sessionID: "session", supportedLeader: true, defaults: defaults
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(payload["kill_switch"] as? Bool, true)
        XCTAssertEqual(payload["health_scope"] as? String, "control_host")
        XCTAssertFalse((path as NSString).lastPathComponent.contains("/"))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testRemoteControlPayloadDelegatesHealthToExecutionHost() throws {
        let suite = "leader-remote-control.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(LeaderParticipationSettings.Mode.canary.rawValue,
                     forKey: LeaderParticipationSettings.modeKey)
        defaults.set(100, forKey: LeaderParticipationSettings.canaryPercentKey)
        defaults.set(["p"], forKey: LeaderParticipationSettings.optInProjectsKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let data = try XCTUnwrap(TeamOrchestrator.leaderParticipationControlData(
            teamName: "p", sessionID: "s", supportedLeader: true,
            healthScope: .executionHost, defaults: defaults
        ))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(payload["health_scope"] as? String, "execution_host")
    }

    /// The turn hook runs on the execution host with no socket, so the roster
    /// and the Project's level have to travel in this file or the hook cannot
    /// state a floor at all.
    func testControlDataCarriesRosterAndConfiguredLevelForTheHook() throws {
        let team = "control-roster-\(UUID().uuidString)"
        TeamDataStore.shared.registerTeam(team, agentNames: ["executor", "reviewer"])
        addTeardownBlock { TeamDataStore.shared.unregisterTeam(team) }

        let suite = "leader-roster-control.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let data = try XCTUnwrap(TeamOrchestrator.leaderParticipationControlData(
            teamName: team, sessionID: "s", supportedLeader: true,
            delegationState: ProjectDelegationState(configured: .delegated, effective: .delegated),
            healthScope: .executionHost, defaults: defaults
        ))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(payload["available_workers"] as? Int, 2)
        XCTAssertEqual(payload["worker_names"] as? [String], ["executor", "reviewer"])
        XCTAssertEqual(payload["delegation_effective"] as? String, "delegated")
    }

    func testUnsupportedLeaderControlPayloadCannotApplyCanary() {
        let settings = LeaderParticipationSettings(
            mode: .canary, canaryPercent: 100, killSwitch: false, optInProjects: ["p"]
        )
        let healthy = LeaderParticipationSettings.Health(
            supportedTurns: 500, observedDays: 0, coverage: 1, linkage: 1, unknownRate: 0
        )
        let payload = settings.controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: false, health: healthy
        )
        XCTAssertEqual(payload["supported"] as? Bool, false)
        XCTAssertEqual(
            settings.resolve(
                projectID: "p", sessionID: "s", supportedLeader: false, health: healthy
            ),
            .staticPolicy(.staticPolicy)
        )
    }
}
