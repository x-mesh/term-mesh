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

}
