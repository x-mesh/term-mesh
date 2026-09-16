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
        XCTAssertEqual(
            parallel.observableDispatchBounds,
            "two to ten dependency-ready, ownership-disjoint tasks within the configured limit"
        )
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
        ProjectExecutionOptions(maxParallelWorkers: 12, injectDirective: true)
            .save(teamName: "upper-bound", to: defaults)
        XCTAssertEqual(
            ProjectExecutionOptions.load(teamName: "upper-bound", from: defaults).maxParallelWorkers,
            10
        )
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
            delegationState: ProjectDelegationState(configured: .delegated, effective: .delegated),
            healthScope: .executionHost, defaults: defaults
        ))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(payload["health_scope"] as? String, "execution_host")
        // executionHost scope never reads this Mac's aggregate health, so
        // a delegated, supported, non-killed state resolves true regardless of
        // whatever this test host's own turns.log currently holds.
        XCTAssertEqual(payload["delegated_overlap_resolution"] as? Bool, true)
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
        // Overlap follows the participation mode, so the hook fixture names the
        // one a Project running the canary would have.
        defaults.set(LeaderParticipationSettings.Mode.canary.rawValue,
                     forKey: LeaderParticipationSettings.modeKey)
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
        XCTAssertEqual(payload["overlap_canary_capability"] as? Bool, true)
        // executionHost scope drops this Mac's aggregate health from the gate
        // because the remote re-checks it. The old `false` here encoded the peer gate contradiction,
        // where a peer-only Mac with no local turns could never reach Ready.
        XCTAssertEqual(payload["delegated_overlap_resolution"] as? Bool, true)
        XCTAssertEqual(
            payload["overlap_canary_capability_version"] as? Int,
            LeaderParticipationSettings.overlapCanaryCapabilityVersion
        )
    }

    func testOverlapCanaryCapabilityIsDisabledOutsideDelegatedMode() {
        let health = LeaderParticipationSettings.Health(
            supportedTurns: 500, observedDays: 0, coverage: 1, linkage: 1, unknownRate: 0
        )
        let payload = LeaderParticipationSettings.default.controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: true, health: health,
            delegationState: ProjectDelegationState(configured: .leaderFirst, effective: .leaderFirst)
        )
        XCTAssertEqual(payload["overlap_canary_capability"] as? Bool, false)
        XCTAssertEqual(payload["delegated_overlap_resolution"] as? Bool, false)
        XCTAssertEqual(
            payload["overlap_canary_capability_version"] as? Int,
            LeaderParticipationSettings.overlapCanaryCapabilityVersion
        )
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
        XCTAssertEqual(payload["delegated_overlap_resolution"] as? Bool, false)
        XCTAssertEqual(
            settings.resolve(
                projectID: "p", sessionID: "s", supportedLeader: false, health: healthy
            ),
            .staticPolicy(.staticPolicy)
        )
    }

    /// Overlap ignores the cohort — the percent bucket and the opt-in set
    /// decide the ordinary canary, not this one — but it does follow the mode.
    /// A leader the user switched off, or left in shadow, runs no experiment.
    func testDelegatedOverlapIgnoresCohortSettingsButFollowsTheMode() {
        let healthy = LeaderParticipationSettings.Health(
            supportedTurns: 500, observedDays: 0, coverage: 1, linkage: 1, unknownRate: 0
        )
        let canary = LeaderParticipationSettings(
            mode: .canary, canaryPercent: 0, killSwitch: false, optInProjects: []
        )
        let delegationState = ProjectDelegationState(configured: .delegated, effective: .delegated)
        let delegated = canary.controlPayload(
            projectID: "review-board", sessionID: "s", supportedLeader: true, health: healthy,
            delegationState: delegationState
        )
        XCTAssertEqual(delegated["percent"] as? Int, 0)
        XCTAssertEqual(delegated["opt_in"] as? Bool, false)
        XCTAssertEqual(delegated["delegated_overlap_resolution"] as? Bool, true)

        for stopped in [LeaderParticipationSettings.Mode.off, .shadow] {
            var settings = canary
            settings.mode = stopped
            let payload = settings.controlPayload(
                projectID: "review-board", sessionID: "s", supportedLeader: true, health: healthy,
                delegationState: delegationState
            )
            XCTAssertEqual(
                payload["delegated_overlap_resolution"] as? Bool, false,
                "mode \(stopped.rawValue) kept overlap resolving"
            )
        }

        let unhealthy = canary.controlPayload(
            projectID: "review-board", sessionID: "s", supportedLeader: true,
            health: .init(supportedTurns: 1, observedDays: 0, coverage: 1, linkage: 1, unknownRate: 0),
            delegationState: delegationState
        )
        XCTAssertEqual(unhealthy["delegated_overlap_resolution"] as? Bool, false)

        let unsupported = canary.controlPayload(
            projectID: "review-board", sessionID: "s", supportedLeader: false, health: healthy,
            delegationState: delegationState
        )
        XCTAssertEqual(unsupported["delegated_overlap_resolution"] as? Bool, false)

        let killed = LeaderParticipationSettings(
            mode: .canary, canaryPercent: 0, killSwitch: true, optInProjects: []
        ).controlPayload(
            projectID: "review-board", sessionID: "s", supportedLeader: true, health: healthy,
            delegationState: delegationState
        )
        XCTAssertEqual(killed["delegated_overlap_resolution"] as? Bool, false)
    }

    /// An executionHost payload must not fail closed on this Mac's own
    /// aggregate turns.log — the remote tm-agent re-checks health per Project
    /// once it receives the payload (apply_participation_health_scope).
    /// controlHost payloads keep failing closed on `health.passesPromotionGate`.
    func testExecutionHostScopeDropsThisMacsHealthFromOverlapGate() {
        let failingHealth = LeaderParticipationSettings.Health(
            supportedTurns: 0, observedDays: 0, coverage: 0, linkage: 0, unknownRate: 1
        )
        // Overlap runs only in canary mode; this test is about the health
        // scope, so it names the mode that lets the gate be reached at all.
        let settings = LeaderParticipationSettings(
            mode: .canary, canaryPercent: 0, killSwitch: false, optInProjects: []
        )
        let delegated = ProjectDelegationState(configured: .delegated, effective: .delegated)

        let executionHostReady = settings.controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: true, health: failingHealth,
            delegationState: delegated, healthScope: .executionHost
        )
        XCTAssertEqual(executionHostReady["delegated_overlap_resolution"] as? Bool, true)
        XCTAssertEqual(executionHostReady["healthy"] as? Bool, false)

        let notDelegated = settings.controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: true, health: failingHealth,
            delegationState: ProjectDelegationState(configured: .leaderFirst, effective: .leaderFirst),
            healthScope: .executionHost
        )
        XCTAssertEqual(notDelegated["delegated_overlap_resolution"] as? Bool, false)

        let unsupported = settings.controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: false, health: failingHealth,
            delegationState: delegated, healthScope: .executionHost
        )
        XCTAssertEqual(unsupported["delegated_overlap_resolution"] as? Bool, false)

        let killed = LeaderParticipationSettings(
            mode: .shadow, canaryPercent: 0, killSwitch: true, optInProjects: []
        ).controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: true, health: failingHealth,
            delegationState: delegated, healthScope: .executionHost
        )
        XCTAssertEqual(killed["delegated_overlap_resolution"] as? Bool, false)

        let controlHostFailing = settings.controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: true, health: failingHealth,
            delegationState: delegated, healthScope: .controlHost
        )
        XCTAssertEqual(controlHostFailing["delegated_overlap_resolution"] as? Bool, false)

        let passingHealth = LeaderParticipationSettings.Health(
            supportedTurns: 500, observedDays: 0, coverage: 0.95, linkage: 0.95, unknownRate: 0.02
        )
        let controlHostPassing = settings.controlPayload(
            projectID: "p", sessionID: "s", supportedLeader: true, health: passingHealth,
            delegationState: delegated, healthScope: .controlHost
        )
        XCTAssertEqual(controlHostPassing["delegated_overlap_resolution"] as? Bool, true)
    }

    func testUpdateLeaderParticipationSettingsRoundTripsAllFieldsThroughOneSharedPath() {
        XCTAssertTrue(TeamOrchestrator.shared.teams.isEmpty)
        let suite = "leader-update.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let saved = TeamOrchestrator.shared.updateLeaderParticipationSettings(defaults: defaults) { settings in
            settings.mode = .canary
            settings.canaryPercent = 42
            settings.killSwitch = true
            settings.optInProjects = ["p1", "p2"]
        }
        XCTAssertEqual(saved.mode, .canary)
        XCTAssertEqual(saved.canaryPercent, 42)
        XCTAssertTrue(saved.killSwitch)
        XCTAssertEqual(saved.optInProjects, ["p1", "p2"])
        XCTAssertEqual(LeaderParticipationSettings.load(from: defaults), saved)

        // Both the array key and the CSV key round-trip: an older reader that
        // only knows one of them must still see the opt-in.
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: LeaderParticipationSettings.optInProjectsKey) ?? []),
            ["p1", "p2"]
        )
        let csvProjects = Set(
            (defaults.string(forKey: LeaderParticipationSettings.optInProjectsCSVKey) ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        XCTAssertEqual(csvProjects, ["p1", "p2"])
    }

    func testUpdateLeaderParticipationSettingsModeOnlyMutationKeepsPriorOptIn() {
        XCTAssertTrue(TeamOrchestrator.shared.teams.isEmpty)
        let suite = "leader-update-partial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        TeamOrchestrator.shared.updateLeaderParticipationSettings(defaults: defaults) { settings in
            settings.optInProjects = ["kept"]
        }
        let after = TeamOrchestrator.shared.updateLeaderParticipationSettings(defaults: defaults) { settings in
            settings.mode = .shadow
        }
        XCTAssertEqual(after.optInProjects, ["kept"])
        XCTAssertEqual(LeaderParticipationSettings.load(from: defaults).optInProjects, ["kept"])
    }

    func testHealthMeasurementInitMatchesGateMathForZeroAndNonzeroSupportedTurns() {
        let empty = LeaderTurnLog.Health(
            supportedTurns: 0, linkedTurns: 0, statedTurns: 0, unstatedTurns: 0,
            unsupportedTurns: 0, degradedTurns: 0, malformedLines: 0, observedDays: 0
        )
        XCTAssertEqual(LeaderParticipationSettings.Health(measurement: empty).unknownRate, 1)

        let measured = LeaderTurnLog.Health(
            supportedTurns: 500, linkedTurns: 480, statedTurns: 400, unstatedTurns: 50,
            unsupportedTurns: 10, degradedTurns: 5, malformedLines: 0, observedDays: 8
        )
        let health = LeaderParticipationSettings.Health(measurement: measured)
        XCTAssertEqual(health.supportedTurns, measured.supportedTurns)
        XCTAssertEqual(health.observedDays, measured.observedDays)
        XCTAssertEqual(health.coverage, measured.coverage)
        XCTAssertEqual(health.linkage, measured.linkage)
        let unknown = max(0, measured.supportedTurns - measured.statedTurns)
        XCTAssertEqual(health.unknownRate, Double(unknown) / Double(measured.supportedTurns))
    }
}
