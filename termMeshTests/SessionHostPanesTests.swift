import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A session the daemon owns outlives the app, which is the point of it — but
/// until something attaches, the machine holding the work is the one place you
/// cannot see it. A project placed on a peer looked exactly like that: the
/// leader's own machine showed a workspace and no team.
///
/// Mirroring the daemon's workspace does not solve it. The daemon places
/// ensured sessions as *tabs* in one pane, deliberately, and
/// `PeerWorkspaceMirror` renders a pane's active surface with no notion of a
/// tab strip — measured against a live daemon holding three sessions, the
/// mirror showed one. These tests cover the per-surface decision instead.
@MainActor
final class SessionHostPanesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SessionHostPanes.forgetAll()
    }

    override func tearDown() {
        SessionHostPanes.forgetAll()
        super.tearDown()
    }

    private func sid(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

    // MARK: - Which sessions get a pane

    /// Everything the daemon holds deserves a window here: it owns it, so it
    /// outlives this app, which is exactly what has nowhere else to be seen.
    func test_everyHeldSessionWithoutAPaneGetsOne() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [(sid(1), true), (sid(2), true), (sid(3), true)],
            alreadyShown: []
        )
        XCTAssertEqual(wanted, [sid(1), sid(2), sid(3)])
    }

    /// Idempotent by the *peer's* surface id. The local panel id is minted per
    /// attach, so comparing those would open a second pane for one session
    /// every time this runs.
    func test_aSessionAlreadyOnScreenIsNotOpenedTwice() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [(sid(1), true), (sid(2), true)],
            alreadyShown: [sid(1)]
        )
        XCTAssertEqual(wanted, [sid(2)])
    }

    /// Attaching to an unattachable surface fails at the far end, and a
    /// failure per pass is a log full of one line.
    func test_anUnattachableSessionIsSkippedRatherThanAttempted() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [(sid(1), false), (sid(2), true)],
            alreadyShown: []
        )
        XCTAssertEqual(wanted, [sid(2)])
    }

    func test_nothingHeldMeansNothingToOpen() {
        XCTAssertTrue(
            SessionHostPanes.sessionsNeedingPanes(daemonSurfaces: [], alreadyShown: [sid(1)]).isEmpty
        )
    }

    // MARK: - Bookkeeping

    func test_markingShownAndClosedTracksWhatIsOnScreen() {
        SessionHostPanes.markShown(sid(7))
        XCTAssertEqual(
            SessionHostPanes.sessionsNeedingPanes(
                daemonSurfaces: [(sid(7), true)],
                alreadyShown: SessionHostPanes.shownSurfaceIDs
            ),
            []
        )
        SessionHostPanes.markClosed(sid(7))
        XCTAssertEqual(
            SessionHostPanes.sessionsNeedingPanes(
                daemonSurfaces: [(sid(7), true)],
                alreadyShown: SessionHostPanes.shownSurfaceIDs
            ),
            [sid(7)]
        )
    }

    /// A daemon that went away and came back brings the same ids with it —
    /// they are derived from keys — so a session returning under an id we
    /// remember must be re-shown, not mistaken for one already up.
    func test_aRestartedDaemonsSessionsAreShownAgain() {
        SessionHostPanes.markShown(sid(9))
        SessionHostPanes.forgetAll()
        XCTAssertEqual(
            SessionHostPanes.sessionsNeedingPanes(
                daemonSurfaces: [(sid(9), true)],
                alreadyShown: SessionHostPanes.shownSurfaceIDs
            ),
            [sid(9)]
        )
    }

    // MARK: - Whether to look at all

    /// Empty is a host saying it has no owner. Polling one is asking a
    /// question already answered.
    func test_aMachineWithNoSessionHostIsNotPolled() {
        XCTAssertFalse(SessionHostPanes.hasSessionHost(socketPath: ""))
    }

    /// A relative path would resolve against whatever directory this process
    /// happens to be in, which is not where the socket is.
    func test_aRelativePathIsNotASessionHost() {
        XCTAssertFalse(SessionHostPanes.hasSessionHost(socketPath: "term-meshd-peer.sock"))
        XCTAssertTrue(SessionHostPanes.hasSessionHost(socketPath: "/tmp/term-meshd-peer.sock"))
    }
}

extension SessionHostPanesTests {
    /// The app starts its daemon and its own peer server at about the same
    /// moment, and the daemon binds a little after being spawned. One attempt
    /// at server-start found nothing and returned silently, so sessions that
    /// had outlived the app stayed invisible until something asked again --
    /// and nothing did. Panes restored from the previous run made that look
    /// like it had worked.
    func test_startupWaitsLongEnoughForADaemonToBind() {
        let window = SessionHostPanes.startupSettleInterval * SessionHostPanes.startupSettleAttempts
        XCTAssertGreaterThanOrEqual(
            window, .seconds(3),
            "a shorter window is the single-attempt bug with extra steps"
        )
        XCTAssertLessThanOrEqual(
            window, .seconds(30),
            "a machine with no daemon serving is ordinary, not something to wait on"
        )
    }
}
