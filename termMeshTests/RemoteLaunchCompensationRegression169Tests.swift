import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Giving back a checkout whose agent never started.
///
/// `attachRemoteAgent` types the CLI's launch line from a detached task, after
/// it has already returned its member — so a failure there fell outside the
/// `catch` that compensates everything else, and the worktree stayed on the
/// peer with a location record still pointing at it.
///
/// What is pinned here is the part that decides *which* checkout goes back,
/// not the ssh call that reclaims it. The reclaim is one best-effort script
/// that already has its own guards and tests — it deletes only a clean linked
/// worktree (`PeerProjectBootstrapTests.test_reap_script_only_deletes_a_clean_linked_worktree`),
/// so an agent that did get going and wrote something keeps its checkout
/// whatever this code decides. What has no test anywhere else is the location
/// bookkeeping, and that is what makes the cleanup happen exactly once.
@MainActor
final class RemoteLaunchCompensationRegression169Tests: XCTestCase {

    private typealias Location = TeamOrchestrator.Team.RemoteProjectLocation

    private let host = "ssh:root@jw-server"
    private let other = "ssh:root@build-box"

    // MARK: - The detach interlock

    /// Abandoning drops exactly the one entry. That is what keeps the cleanup
    /// single: `reapDetachedAgentWorktree` gates on the path still being in
    /// `remoteProjectLocations`, so once this entry is gone, detaching the
    /// half-attached member later cannot reap the same path a second time.
    func testAbandoningRemovesExactlyThatCheckoutsLocation() {
        let locations = [
            Location(hostKey: host, path: "/srv/proj"),
            Location(hostKey: host, path: "/srv/proj-worker-1"),
            Location(hostKey: host, path: "/srv/proj-worker-2"),
        ]

        let remaining = TeamOrchestrator.remoteProjectLocations(
            locations, abandoning: "/srv/proj-worker-1", onHost: host
        )

        XCTAssertEqual(
            remaining,
            [
                Location(hostKey: host, path: "/srv/proj"),
                Location(hostKey: host, path: "/srv/proj-worker-2"),
            ]
        )
        XCTAssertFalse(
            remaining.contains(Location(hostKey: host, path: "/srv/proj-worker-1")),
            "the detach-time reap gates on this entry; leaving it means a second reap"
        )
    }

    /// Two machines routinely lay the same project out at the same path.
    /// Matching on the path alone would disarm the detach-time reap for a
    /// member on another host that is still running.
    func testAbandoningLeavesTheSamePathOnAnotherHostAlone() {
        let locations = [
            Location(hostKey: host, path: "/srv/proj-worker-1"),
            Location(hostKey: other, path: "/srv/proj-worker-1"),
        ]

        let remaining = TeamOrchestrator.remoteProjectLocations(
            locations, abandoning: "/srv/proj-worker-1", onHost: host
        )

        XCTAssertEqual(remaining, [Location(hostKey: other, path: "/srv/proj-worker-1")])
    }

    func testAbandoningLeavesOtherCheckoutsOnTheSameHostAlone() {
        let locations = [
            Location(hostKey: host, path: "/srv/proj-worker-1"),
            Location(hostKey: host, path: "/srv/proj-worker-10"),
        ]

        let remaining = TeamOrchestrator.remoteProjectLocations(
            locations, abandoning: "/srv/proj-worker-1", onHost: host
        )

        // A prefix match would have taken `-worker-10` with it.
        XCTAssertEqual(remaining, [Location(hostKey: host, path: "/srv/proj-worker-10")])
    }

    /// Running twice is the same as running once, which is what lets the
    /// caller compensate without first proving nobody else did.
    func testAbandoningTwiceIsTheSameAsOnce() {
        let locations = [
            Location(hostKey: host, path: "/srv/proj"),
            Location(hostKey: host, path: "/srv/proj-worker-1"),
        ]

        let once = TeamOrchestrator.remoteProjectLocations(
            locations, abandoning: "/srv/proj-worker-1", onHost: host
        )
        let twice = TeamOrchestrator.remoteProjectLocations(
            once, abandoning: "/srv/proj-worker-1", onHost: host
        )

        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice, [Location(hostKey: host, path: "/srv/proj")])
    }

    /// A path this attach did not create is not in the list, and nothing is
    /// disturbed. This is the shared-directory case: a caller who named their
    /// own `--dir` owns it, and a failed launch must not take it away.
    func testAbandoningAPathTheTeamDoesNotOwnChangesNothing() {
        let locations = [Location(hostKey: host, path: "/srv/proj")]

        let remaining = TeamOrchestrator.remoteProjectLocations(
            locations, abandoning: "/home/someone/scratch", onHost: host
        )

        XCTAssertEqual(remaining, locations)
    }

    func testDeleteProjectNeverOwnsAUserSelectedSourceCheckout() {
        let source = Location(hostKey: host, path: "/srv/existing-project", owned: false)
        let leaderWorktree = Location(
            hostKey: host, path: "/srv/existing-project-leader-260820-abcd", owned: true
        )
        let workerWorktree = Location(
            hostKey: host, path: "/srv/existing-project-executor-260820-ef01", owned: true
        )

        XCTAssertEqual(
            TeamOrchestrator.ownedRemoteProjectLocations([
                source, leaderWorktree, workerWorktree,
            ]),
            [leaderWorktree, workerWorktree],
            "Delete Project may remove only paths this Project created"
        )
    }

    func testLegacyRemoteLocationRecordDecodesAsUnowned() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "teamName": "legacy", "hostKey": host, "path": "/srv/user-checkout",
        ])
        let record = try JSONDecoder().decode(
            RemoteProjectLocationStore.Record.self, from: data
        )

        XCTAssertFalse(
            record.owned,
            "old records predate ownership evidence and must fail safe"
        )
    }

    func testRuntimeCloseRecoversOnlyThePeerLeaderInItsOwningWorkspace() {
        let leader = UUID()
        let workspace = UUID()

        XCTAssertTrue(TeamOrchestrator.shouldRecoverRemoteLeaderRuntimeClose(
            closedPanelID: leader,
            leaderPanelID: leader,
            workspaceID: workspace,
            teamWorkspaceID: workspace,
            isPeerLeader: true
        ))
        XCTAssertFalse(TeamOrchestrator.shouldRecoverRemoteLeaderRuntimeClose(
            closedPanelID: UUID(),
            leaderPanelID: leader,
            workspaceID: workspace,
            teamWorkspaceID: workspace,
            isPeerLeader: true
        ))
        XCTAssertFalse(TeamOrchestrator.shouldRecoverRemoteLeaderRuntimeClose(
            closedPanelID: leader,
            leaderPanelID: leader,
            workspaceID: workspace,
            teamWorkspaceID: workspace,
            isPeerLeader: false
        ))
    }

    func testRecoveryOpensPaneWhenTheDeadAnchorWasAlreadyRemoved() {
        XCTAssertEqual(
            TeamOrchestrator.remoteLeaderRecoveryPresentation(anchorExists: true),
            .replaceAnchor
        )
        XCTAssertEqual(
            TeamOrchestrator.remoteLeaderRecoveryPresentation(anchorExists: false),
            .openPane
        )
    }

}

/// Findings from the cross-model review of the remote project lifecycle work.
/// Each one is a defect the change itself introduced, verified in the code
/// before being fixed.
final class RemoteProjectLifecycleReviewFixTests: XCTestCase {
    private typealias Location = TeamOrchestrator.Team.RemoteProjectLocation

    /// A location is a directory on a host. Folding `owned` into equality made
    /// every membership probe build its key with the default value and miss
    /// any record that disagreed, which silently switched off late-agent
    /// checkout isolation and detached-worktree reaping.
    func testLocationIdentityIgnoresOwnership() {
        let ours = Location(hostKey: "ssh:h", path: "/srv/p", owned: true)
        let theirs = Location(hostKey: "ssh:h", path: "/srv/p", owned: false)

        XCTAssertEqual(ours, theirs, "one directory is one location")
        XCTAssertEqual(Set([ours, theirs]).count, 1)
        XCTAssertNotEqual(ours, Location(hostKey: "ssh:h", path: "/srv/q", owned: true))
        XCTAssertNotEqual(ours, Location(hostKey: "ssh:i", path: "/srv/p", owned: true))
    }

    /// The probe both call sites needed: "is work already routed here?" has to
    /// answer yes for a directory the user owns, because that is exactly the
    /// case that needs an isolated checkout instead of a second writer.
    func testContainsLocationFindsAnUnownedDirectory() {
        let recorded = [
            Location(hostKey: "ssh:h", path: "/srv/theirs", owned: false),
            Location(hostKey: "ssh:h", path: "/srv/ours", owned: true),
        ]

        XCTAssertTrue(recorded.containsLocation(hostKey: "ssh:h", path: "/srv/theirs"))
        XCTAssertTrue(recorded.containsLocation(hostKey: "ssh:h", path: "/srv/ours"))
        XCTAssertFalse(recorded.containsLocation(hostKey: "ssh:h", path: "/srv/other"))
        XCTAssertFalse(recorded.containsLocation(hostKey: "ssh:other", path: "/srv/ours"))
    }

    /// Forgetting the parameter must not hand Delete Project a directory.
    func testOwnershipDefaultsToTheSideThatKeepsTheDirectory() {
        XCTAssertFalse(Location(hostKey: "ssh:h", path: "/srv/p").owned)
        XCTAssertTrue(
            TeamOrchestrator.ownedRemoteProjectLocations([
                Location(hostKey: "ssh:h", path: "/srv/ours", owned: true),
                Location(hostKey: "ssh:h", path: "/srv/theirs", owned: false),
            ]).map(\.path) == ["/srv/ours"]
        )
    }

    /// An unanswered session-owner question must stay unanswered.
    ///
    /// `teamRouteResolved` reads any non-nil value as resolved, and
    /// `teamHostSpec` then falls back to the serving GUI socket. Storing the
    /// empty string after the retries ran out therefore pinned team work to
    /// the endpoint that cannot do it, which is the failure the retry loop was
    /// added to prevent.
    func testEmptySessionOwnerRouteIsNotAResolvedRoute() {
        var host = HostEntry(
            id: "ssh:root@mac-sub",
            displayName: "mac-sub",
            connectionState: .connected,
            workspaces: [],
            activeSockPath: "/tmp/term-mesh-peer-501/mac-sub.sock",
            sshTarget: "root@mac-sub",
            remoteSockPath: "/run/user/0/tm-peer.sock"
        )

        host.sessionHostRemoteSockPath = nil
        XCTAssertFalse(host.teamRouteResolved, "no answer yet is not an answer")
        XCTAssertNil(host.teamHostSpec)

        // "" remains the real answer for a host that owns its own sessions.
        host.sessionHostRemoteSockPath = ""
        XCTAssertTrue(host.teamRouteResolved)
        XCTAssertEqual(host.teamHostSpec?.hostKey, host.paneHostSpec.hostKey)
        XCTAssertFalse(host.redirectsTeamWorkToSessionHost)

        host.sessionHostRemoteSockPath = "/run/user/501/term-meshd.sock"
        XCTAssertTrue(host.teamRouteResolved)
        XCTAssertTrue(host.redirectsTeamWorkToSessionHost)
    }
}
