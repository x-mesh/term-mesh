import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class DelegateDiskGateTests: XCTestCase {

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "DelegateDiskGateTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testMinimumDefaultsToFiveGBWhenUnset() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DelegateDiskGate.minimumFreeGB(defaults: defaults), 5)
    }

    /// `UserDefaults.integer` reads an unset key as 0, which here means "off";
    /// only an explicitly stored 0 may turn the gate off.
    func testStoredValuesAreReadAsIs() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: DelegateDiskGate.minimumFreeGBKey)
        XCTAssertEqual(DelegateDiskGate.minimumFreeGB(defaults: defaults), 0)
        defaults.set(20, forKey: DelegateDiskGate.minimumFreeGBKey)
        XCTAssertEqual(DelegateDiskGate.minimumFreeGB(defaults: defaults), 20)
        defaults.set(-3, forKey: DelegateDiskGate.minimumFreeGBKey)
        XCTAssertEqual(DelegateDiskGate.minimumFreeGB(defaults: defaults), 0)
    }

    func testRefusesOnlyBelowTheMinimum() {
        XCTAssertEqual(
            DelegateDiskGate.refusal(availableBytes: 4_999_999_999, minimumGB: 5),
            DelegateDiskGate.Refusal(availableBytes: 4_999_999_999, minimumBytes: 5_000_000_000)
        )
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: 5_000_000_000, minimumGB: 5))
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: 120_000_000_000, minimumGB: 5))
    }

    func testOffOrUnmeasuredNeverRefuses() {
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: 1, minimumGB: 0))
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: nil, minimumGB: 5))
    }

    /// Defaults accept any integer; the byte product must saturate, not trap.
    func testAHugeMinimumSaturatesInsteadOfOverflowing() {
        let refusal = DelegateDiskGate.refusal(availableBytes: 1, minimumGB: Int.max)
        XCTAssertEqual(refusal?.minimumBytes, UInt64.max)
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: UInt64.max, minimumGB: Int.max))
    }

    /// The gate inside `delegate`: a worker on this Mac with too little free
    /// space is refused before any task exists. The minimum is raised past
    /// any real disk so the result does not depend on this machine.
    @MainActor
    func testDelegateRefusesALowDiskWithoutCreatingATask() throws {
        let teamName = "disk-gate-\(UUID().uuidString)"
        let teamUUID = UUID().uuidString
        let worker = "worker-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let previousMinimum = defaults.object(forKey: DelegateDiskGate.minimumFreeGBKey)
        defer {
            if let previousMinimum {
                defaults.set(previousMinimum, forKey: DelegateDiskGate.minimumFreeGBKey)
            } else {
                defaults.removeObject(forKey: DelegateDiskGate.minimumFreeGBKey)
            }
            TeamOrchestrator.shared.teams.removeValue(forKey: teamName)
            TeamDataStore.shared.unregisterTeam(teamName)
            TeamDataStore.shared.drainBoardIOForTests()
            try? FileManager.default.removeItem(
                at: TeamDataStore.boardFileURL(teamUuid: teamUUID).deletingLastPathComponent()
            )
        }

        let remote = RemoteTeamSummary(
            name: teamName, teamUUID: teamUUID, workingDirectory: "/work/\(teamUUID)",
            projectRootPath: nil, agentNames: ["executor"],
            projectID: "team:\(teamUUID)",
            leaderSurfaceID: Data(repeating: 0x55, count: 16),
            members: [.init(
                name: "executor", agentInstanceID: worker, cli: "claude",
                model: "sonnet", agentType: "executor", color: "blue",
                workingDirectory: "/work/\(teamUUID)",
                surfaceID: Data(repeating: 0x56, count: 16), surfaceType: "agent"
            )], presentationOwnedByRequester: true,
            leaderProcessActive: false, leaderProcessActiveKnown: true
        )
        var team = try XCTUnwrap(
            TeamOrchestrator.remoteProjectRepairPlaceholder(remote: remote, hostKey: "ssh:fixture")
        )
        // A local leader and a local worker: presentation is ready and the
        // worker's disk is this Mac's home volume.
        team.leaderEndpoint = .local
        for index in team.agents.indices { team.agents[index].hostKey = nil }
        TeamOrchestrator.shared.teams[teamName] = team
        TeamDataStore.shared.registerTeam(
            teamName, agents: team.agents.map { .init(name: $0.name, instanceId: $0.agentInstanceId) },
            delegationState: team.delegationState
        )
        defaults.set(Int.max, forKey: DelegateDiskGate.minimumFreeGBKey)

        let outcome = TeamOrchestrator.shared.delegate(
            teamName: teamName,
            agentName: "executor",
            agentInstanceId: worker,
            text: "build it",
            tabManager: TabManager()
        )

        guard case .diskLow(let refusal, let hostName) = outcome else {
            return XCTFail("expected .diskLow, got \(outcome)")
        }
        XCTAssertNil(hostName)
        XCTAssertEqual(refusal.minimumBytes, UInt64.max)
        XCTAssertTrue(TeamDataStore.shared.listTasks(teamName: teamName).isEmpty)
    }

    func testMessageNamesTheDiskAndHowToReclaim() {
        let refusal = DelegateDiskGate.Refusal(availableBytes: 3_200_000_000, minimumBytes: 5_000_000_000)
        let local = DelegateDiskGate.message(agentName: "backend", hostName: nil, refusal: refusal)
        XCTAssertTrue(local.contains("'backend'"))
        XCTAssertTrue(local.contains("on this Mac"))
        XCTAssertTrue(local.contains("3.2GB free"))
        XCTAssertTrue(local.contains("5.0GB minimum"))
        XCTAssertTrue(local.contains("Settings › Worktrees"))

        let remote = DelegateDiskGate.message(agentName: "backend", hostName: "jw-server", refusal: refusal)
        XCTAssertTrue(remote.contains("on jw-server"))
        XCTAssertTrue(remote.contains("on that host"))
    }
}
