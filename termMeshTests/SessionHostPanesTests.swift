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

    // MARK: - Where "already shown" comes from

    /// The shown set is read off the panes, not remembered.
    ///
    /// It used to be a `Set` this type maintained, and each way it could drift
    /// from the screen was its own bug: closing an auto-opened pane left the id
    /// marked forever, because nothing ever called the release, so that session
    /// could never come back. A brief loss of the daemon cleared the whole set
    /// while the panes were still up, so the next pass opened a duplicate for
    /// every one. With no window at all there is nothing on screen, and the
    /// honest answer is the empty set rather than a remembered one.
    func test_nothingIsShownWhenThereIsNoWindow() {
        XCTAssertTrue(SessionHostPanes.shownSurfaceIDs().isEmpty)
    }

    /// Whatever the screen says, feeding it back in is what makes a second pass
    /// a no-op — the property the removed bookkeeping was there to provide.
    func test_whatIsOnScreenIsNotOpenedAgain() {
        let onScreen = SessionHostPanes.shownSurfaceIDs().union([sid(7)])
        XCTAssertEqual(
            SessionHostPanes.sessionsNeedingPanes(
                daemonSurfaces: [(sid(7), true), (sid(8), true)],
                alreadyShown: onScreen
            ),
            [sid(8)]
        )
    }

    // MARK: - A closed pane stays closed

    /// Reading "already shown" off the screen is also what undoes a close: the
    /// daemon still holds the session, so the next pass finds it missing and
    /// opens it again. Measured on a live app before this existed — a pane
    /// closed at 23:02:15 was back at 23:02:25.
    func test_aClosedPaneIsNotReopenedByTheNextPass() {
        SessionHostPanes.forgetDismissalsForTests()
        defer { SessionHostPanes.forgetDismissalsForTests() }

        SessionHostPanes.noteClosedByUser(surfaceID: sid(4))
        XCTAssertEqual(
            SessionHostPanes.sessionsNeedingPanes(
                daemonSurfaces: [(sid(4), true), (sid(5), true)],
                alreadyShown: SessionHostPanes.dismissedSurfaceIDsForTests
            ),
            [sid(5)]
        )
    }

    /// A dismissal is safe to remember where the old "shown" bookkeeping was
    /// not, because a close is its own owner — but only if the set cannot grow
    /// for the life of the process.
    func test_dismissalsAreDroppedOnceTheSessionIsGone() {
        SessionHostPanes.forgetDismissalsForTests()
        defer { SessionHostPanes.forgetDismissalsForTests() }

        SessionHostPanes.noteClosedByUser(surfaceID: sid(4))
        SessionHostPanes.noteClosedByUser(surfaceID: sid(5))
        XCTAssertEqual(SessionHostPanes.dismissedSurfaceIDsForTests.count, 2)

        SessionHostPanes.pruneDismissalsForTests(stillHeld: [sid(5)])
        XCTAssertEqual(SessionHostPanes.dismissedSurfaceIDsForTests, [sid(5)])
    }

    /// Panes that were never a session get no entry — a remote pane on another
    /// machine closes through the same funnel.
    func test_aPaneWithNoSurfaceIdIsNotRecorded() {
        SessionHostPanes.forgetDismissalsForTests()
        defer { SessionHostPanes.forgetDismissalsForTests() }

        SessionHostPanes.noteClosedByUser(surfaceID: Data())
        XCTAssertTrue(SessionHostPanes.dismissedSurfaceIDsForTests.isEmpty)
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
        let window = SessionHostPanes.startupSettleWindow
        XCTAssertGreaterThanOrEqual(
            window, .seconds(3),
            "a shorter window is the single-attempt bug with extra steps"
        )
        XCTAssertLessThanOrEqual(
            window, .seconds(30),
            "a machine with no daemon serving is ordinary, not something to wait on"
        )
    }

    /// The last attempt does not sleep after itself, so `attempts × interval`
    /// overstates the wait by one interval. Asserting the overstated number
    /// would let the real window shrink below the floor above without any test
    /// noticing.
    func test_theStatedWindowIsTheOneActuallyWaited() {
        XCTAssertEqual(
            SessionHostPanes.startupSettleWindow,
            SessionHostPanes.startupSettleInterval * (SessionHostPanes.startupSettleAttempts - 1)
        )
    }

    /// Sessions appear after startup — a peer-placed project creates one
    /// minutes or hours in — so a single pass at server-start covered the case
    /// this type exists for worst of all. Slow on purpose: a pass walks the
    /// window list and opens a connection.
    func test_itKeepsLookingAfterStartupRatherThanAskingOnce() {
        XCTAssertGreaterThanOrEqual(
            SessionHostPanes.pollInterval, .seconds(5),
            "a pass is not free; noticing a minutes-old session within a second buys nothing"
        )
        XCTAssertLessThanOrEqual(
            SessionHostPanes.pollInterval, .seconds(60),
            "longer than this and a session created now feels like it was dropped"
        )
    }
}
