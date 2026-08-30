import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The two timeouts that decide what a slow link looks like in the log.
///
/// Their order is the whole contract. When this side's deadline expires
/// first it kills ssh mid-handshake, before ssh has written a word, and the
/// failure reads `socketNeverAppeared(… ssh stderr: )` with an empty tail —
/// which is how the most common tunnel failure on a flaky link became the
/// only one that never said why. Letting ssh time out first makes it report
/// its own reason and exit, which the spawn path turns into a
/// `spawnFailed(exitReason)`.
///
/// Nothing in the type system enforces the ordering, and either constant is
/// an easy thing to "tune" back into a tie. Hence this test.
final class PeerSSHTunnelBudgetTests: XCTestCase {

    func test_forwardSocketDeadlineOutlivesSSHConnectTimeout() {
        XCTAssertLessThan(
            TimeInterval(PeerSSHTunnel.sshConnectTimeoutSeconds),
            PeerSSHTunnel.forwardSocketDeadlineSeconds,
            "ssh must exhaust its own connect budget FIRST, so it reports the "
                + "reason instead of being killed silently mid-handshake."
        )
    }

    func test_deadlineLeavesRoomForSSHToReportAndExit() {
        // A one-second gap would satisfy the ordering above and still lose the
        // race in practice: ssh has to notice the timeout, write to stderr,
        // and exit, and the poll that observes it only runs every 150 ms.
        // Require a margin wide enough that the reporting path actually wins.
        let margin = PeerSSHTunnel.forwardSocketDeadlineSeconds
            - TimeInterval(PeerSSHTunnel.sshConnectTimeoutSeconds)
        XCTAssertGreaterThanOrEqual(
            margin,
            2,
            "Leave ssh room to report and exit before this side gives up."
        )
    }

    func test_connectTimeoutIsBoundedAtAll() {
        // The regression this whole pair exists for: the tunnel's ssh had no
        // ConnectTimeout, so it waited out the system TCP timeout (tens of
        // seconds) while our deadline fired first, every time.
        XCTAssertGreaterThan(PeerSSHTunnel.sshConnectTimeoutSeconds, 0)
        XCTAssertLessThanOrEqual(
            PeerSSHTunnel.sshConnectTimeoutSeconds,
            30,
            "An unbounded-in-practice connect budget defeats the ordering."
        )
    }
}
