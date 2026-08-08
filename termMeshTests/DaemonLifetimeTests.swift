import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A daemon that dies with its app cannot hold a session for anybody, which is
/// why quitting term-mesh on a peer ends a project placed there: the work
/// exists only inside that app's process tree.
///
/// The mechanism to decouple already existed — omit `TERMMESH_OWNER_PID` and
/// the daemon's `wait_for_owner_exit` waits forever — so what was missing was
/// deciding when to use it. These tests hold that decision still, because both
/// answers are wrong somewhere: a daemon that always survives is the leak
/// `TERMMESH_OWNER_PID` was added to stop, and one that never does cannot serve.
final class DaemonLifetimeTests: XCTestCase {

    /// Serving peers is the case where another machine may come back to a
    /// session, so it is the case that decouples.
    func test_aMachineServingPeersKeepsItsDaemon() {
        XCTAssertTrue(TermMeshDaemon.daemonShouldOutliveApp(peerServingEnabled: true))
    }

    /// With nobody to serve, a daemon outliving a crash or a forced reload is
    /// exactly the leak the owner-pid tie was added to prevent — not a feature.
    func test_aMachineServingNobodyKeepsTheOldContract() {
        XCTAssertFalse(TermMeshDaemon.daemonShouldOutliveApp(peerServingEnabled: false))
    }

    /// The decision must come from the argument alone. Reading the live setting
    /// inside would make it untestable and would couple the answer to whatever
    /// this machine happens to have configured while a test runs.
    func test_theDecisionIsAFunctionOfItsInputOnly() {
        for _ in 0..<3 {
            XCTAssertTrue(TermMeshDaemon.daemonShouldOutliveApp(peerServingEnabled: true))
            XCTAssertFalse(TermMeshDaemon.daemonShouldOutliveApp(peerServingEnabled: false))
        }
    }
}
