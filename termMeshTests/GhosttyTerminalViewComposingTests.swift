import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class GhosttyTerminalViewComposingTests: XCTestCase {
    @MainActor
    func testRepeatedHiddenVisibilityDoesNotRestartRendererUnrealizeDebounce() {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil
        )

        surface.hostedView.setVisibleInUI(false)
        var state = surface.debugRendererVisibilityState()
        XCTAssertFalse(state.requested)
        XCTAssertTrue(state.unrealizePending)
        XCTAssertEqual(state.unrealizeScheduleCount, 1)

        surface.hostedView.setVisibleInUI(false)
        state = surface.debugRendererVisibilityState()
        XCTAssertTrue(state.unrealizePending)
        XCTAssertEqual(
            state.unrealizeScheduleCount,
            1,
            "Repeated SwiftUI updates must preserve the original five-second deadline"
        )

        surface.hostedView.setVisibleInUI(true)
        state = surface.debugRendererVisibilityState()
        XCTAssertTrue(state.requested)
        XCTAssertFalse(state.unrealizePending)
    }

    func testSurfaceCreationRetryDelayUsesBoundedBackoff() {
        XCTAssertEqual(terminalSurfaceCreationRetryDelay(afterFailureCount: 0), 0.25)
        XCTAssertEqual(terminalSurfaceCreationRetryDelay(afterFailureCount: 1), 0.25)
        XCTAssertEqual(terminalSurfaceCreationRetryDelay(afterFailureCount: 2), 1)
        XCTAssertEqual(terminalSurfaceCreationRetryDelay(afterFailureCount: 3), 2)
        XCTAssertEqual(terminalSurfaceCreationRetryDelay(afterFailureCount: 4), 5)
        XCTAssertEqual(terminalSurfaceCreationRetryDelay(afterFailureCount: 5), 10)
        XCTAssertEqual(terminalSurfaceCreationRetryDelay(afterFailureCount: 6), 30)
        XCTAssertEqual(terminalSurfaceCreationRetryDelay(afterFailureCount: 100), 30)
    }

    func testSurfaceCreationWaitsForQueuedBackgroundRetry() {
        XCTAssertFalse(terminalSurfaceShouldStartSynchronously(
            creationInProgress: false,
            backgroundStartQueued: true,
            now: 20,
            retryNotBefore: 10
        ))
    }

    func testSurfaceCreationStartsSynchronouslyOnlyWhenEligible() {
        XCTAssertTrue(terminalSurfaceShouldStartSynchronously(
            creationInProgress: false,
            backgroundStartQueued: false,
            now: 20,
            retryNotBefore: 10
        ))
        XCTAssertFalse(terminalSurfaceShouldStartSynchronously(
            creationInProgress: true,
            backgroundStartQueued: false,
            now: 20,
            retryNotBefore: 10
        ))
        XCTAssertFalse(terminalSurfaceShouldStartSynchronously(
            creationInProgress: false,
            backgroundStartQueued: false,
            now: 9,
            retryNotBefore: 10
        ))
    }

    private func externalSnapshot(
        hostFrame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600),
        anchorFrame: NSRect = NSRect(x: 10, y: 20, width: 300, height: 200),
        hostSuperview: NSObject,
        window: NSObject,
        anchor: NSObject,
        anchorSuperview: NSObject
    ) -> TerminalPortalExternalGeometrySnapshot {
        let geometry = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(window),
            superviewID: ObjectIdentifier(anchorSuperview),
            frameInWindow: anchorFrame
        )
        return TerminalPortalExternalGeometrySnapshot(
            hostSuperviewID: ObjectIdentifier(hostSuperview),
            hostFrame: hostFrame,
            hostBounds: NSRect(origin: .zero, size: hostFrame.size),
            referenceGeometry: TerminalPortalAnchorGeometry(
                windowID: ObjectIdentifier(window),
                superviewID: ObjectIdentifier(hostSuperview),
                frameInWindow: hostFrame
            ),
            anchorGeometries: [ObjectIdentifier(anchor): geometry],
            liveReferences: .init([hostSuperview, window, anchor, anchorSuperview])
        )
    }

    /// A snapshot whose views are gone cannot vouch for its own identities.
    ///
    /// Every id in the snapshot is the address of a view it does not retain.
    /// Once the view is deallocated that address can be reused by the next
    /// allocation, and pane churn rebuilds NSViews at the same size — so a
    /// *different* anchor could match on both identity and frame and the sync
    /// it needed would be skipped as redundant, leaving the portal stale while
    /// the snapshot agreed. Comparison now refuses a snapshot whose recorded
    /// views have died.
    func testSnapshotWithADeallocatedViewIsNeverConsideredEqual() {
        let hostSuperview = NSObject()
        let window = NSObject()
        let anchorSuperview = NSObject()

        // The anchor is owned only by this scope, so it is genuinely
        // deallocated on the way out — `previous` keeps its ObjectIdentifier,
        // which then names nothing, or worse whatever lands there next.
        let previous: TerminalPortalExternalGeometrySnapshot = {
            let anchor = NSObject()
            let snapshot = externalSnapshot(
                hostSuperview: hostSuperview,
                window: window,
                anchor: anchor,
                anchorSuperview: anchorSuperview
            )
            XCTAssertFalse(
                terminalPortalExternalGeometryNeedsSynchronization(
                    previous: snapshot, current: snapshot, force: false
                ),
                "precondition: an unchanged live snapshot still suppresses the sync"
            )
            return snapshot
        }()

        XCTAssertTrue(
            terminalPortalExternalGeometryNeedsSynchronization(
                previous: previous,
                current: externalSnapshot(
                    hostSuperview: hostSuperview,
                    window: window,
                    anchor: NSObject(),
                    anchorSuperview: anchorSuperview
                ),
                force: false
            ),
            "a snapshot holding a dead view must not suppress a sync"
        )
    }

    func testExternalPortalGeometrySkipsRepeatedNotificationsAfterConvergence() {
        let hostSuperview = NSObject()
        let window = NSObject()
        let anchor = NSObject()
        let anchorSuperview = NSObject()
        let snapshot = externalSnapshot(
            hostSuperview: hostSuperview,
            window: window,
            anchor: anchor,
            anchorSuperview: anchorSuperview
        )

        XCTAssertFalse(terminalPortalExternalGeometryNeedsSynchronization(
            previous: snapshot,
            current: snapshot,
            force: false
        ))
        XCTAssertTrue(terminalPortalExternalGeometryNeedsSynchronization(
            previous: snapshot,
            current: snapshot,
            force: true
        ))
    }

    func testPortalBindFullReconciliationOnlyForTopologyChanges() {
        XCTAssertFalse(terminalPortalBindNeedsFullReconciliation(
            hasPreviousEntry: true,
            didChangeAnchor: false,
            requiredHostedViewAttachment: false
        ), "Visibility-only warm rebinds are already handled by targeted synchronization")

        XCTAssertTrue(terminalPortalBindNeedsFullReconciliation(
            hasPreviousEntry: false,
            didChangeAnchor: false,
            requiredHostedViewAttachment: false
        ))
        XCTAssertTrue(terminalPortalBindNeedsFullReconciliation(
            hasPreviousEntry: true,
            didChangeAnchor: true,
            requiredHostedViewAttachment: false
        ))
        XCTAssertTrue(terminalPortalBindNeedsFullReconciliation(
            hasPreviousEntry: true,
            didChangeAnchor: false,
            requiredHostedViewAttachment: true
        ))
    }

    func testPortalBindSeedsGeometryOnlyForTopologyChanges() {
        XCTAssertFalse(terminalPortalBindNeedsGeometrySeed(
            hasPreviousEntry: true,
            didChangeAnchor: false,
            requiredHostedViewAttachment: false
        ), "Visibility-only warm rebinds keep their settled geometry")

        XCTAssertTrue(terminalPortalBindNeedsGeometrySeed(
            hasPreviousEntry: false,
            didChangeAnchor: false,
            requiredHostedViewAttachment: false
        ))
        XCTAssertTrue(terminalPortalBindNeedsGeometrySeed(
            hasPreviousEntry: true,
            didChangeAnchor: true,
            requiredHostedViewAttachment: false
        ))
        XCTAssertTrue(terminalPortalBindNeedsGeometrySeed(
            hasPreviousEntry: true,
            didChangeAnchor: false,
            requiredHostedViewAttachment: true
        ))
    }

    func testExternalPortalGeometryIgnoresNoiseButAcceptsRealResize() {
        let hostSuperview = NSObject()
        let window = NSObject()
        let anchor = NSObject()
        let anchorSuperview = NSObject()
        let previous = externalSnapshot(
            hostSuperview: hostSuperview,
            window: window,
            anchor: anchor,
            anchorSuperview: anchorSuperview
        )
        let noisy = externalSnapshot(
            anchorFrame: NSRect(x: 10.1, y: 19.9, width: 300.1, height: 199.9),
            hostSuperview: hostSuperview,
            window: window,
            anchor: anchor,
            anchorSuperview: anchorSuperview
        )
        let resized = externalSnapshot(
            anchorFrame: NSRect(x: 10, y: 20, width: 301, height: 200),
            hostSuperview: hostSuperview,
            window: window,
            anchor: anchor,
            anchorSuperview: anchorSuperview
        )

        XCTAssertFalse(terminalPortalExternalGeometryNeedsSynchronization(
            previous: previous,
            current: noisy,
            force: false
        ))
        XCTAssertTrue(terminalPortalExternalGeometryNeedsSynchronization(
            previous: previous,
            current: resized,
            force: false
        ))
    }

    func testPortalAnchorGeometrySkipsUnchangedLayoutCallbacks() {
        let window = NSObject()
        let superview = NSObject()
        let previous = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(window),
            superviewID: ObjectIdentifier(superview),
            frameInWindow: NSRect(x: 10, y: 20, width: 300, height: 200)
        )

        XCTAssertFalse(terminalPortalAnchorNeedsSynchronization(
            previous: previous,
            current: previous,
            force: false
        ))
    }

    func testPortalAnchorGeometryIgnoresSubpixelLayoutNoise() {
        let window = NSObject()
        let superview = NSObject()
        let previous = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(window),
            superviewID: ObjectIdentifier(superview),
            frameInWindow: NSRect(x: 10, y: 20, width: 300, height: 200)
        )
        let noisy = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(window),
            superviewID: ObjectIdentifier(superview),
            frameInWindow: NSRect(x: 10.1, y: 19.9, width: 300.1, height: 199.9)
        )

        XCTAssertFalse(terminalPortalAnchorNeedsSynchronization(
            previous: previous,
            current: noisy,
            force: false
        ))
    }

    func testPortalAnchorGeometryReportsMeaningfulAndForcedChanges() {
        let window = NSObject()
        let superview = NSObject()
        let previous = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(window),
            superviewID: ObjectIdentifier(superview),
            frameInWindow: NSRect(x: 10, y: 20, width: 300, height: 200)
        )
        let resized = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(window),
            superviewID: ObjectIdentifier(superview),
            frameInWindow: NSRect(x: 10, y: 20, width: 301, height: 200)
        )

        XCTAssertTrue(terminalPortalAnchorNeedsSynchronization(
            previous: previous,
            current: resized,
            force: false
        ))
        XCTAssertTrue(terminalPortalAnchorNeedsSynchronization(
            previous: previous,
            current: previous,
            force: true
        ))
    }

    func testPortalAnchorFullReconciliationOnlyForTopologyChanges() {
        let firstWindow = NSObject()
        let secondWindow = NSObject()
        let firstSuperview = NSObject()
        let secondSuperview = NSObject()
        let previous = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(firstWindow),
            superviewID: ObjectIdentifier(firstSuperview),
            frameInWindow: NSRect(x: 10, y: 20, width: 300, height: 200)
        )
        let frameOnlyChange = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(firstWindow),
            superviewID: ObjectIdentifier(firstSuperview),
            frameInWindow: NSRect(x: 40, y: 20, width: 280, height: 200)
        )
        let windowChange = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(secondWindow),
            superviewID: ObjectIdentifier(firstSuperview),
            frameInWindow: previous.frameInWindow
        )
        let superviewChange = TerminalPortalAnchorGeometry(
            windowID: ObjectIdentifier(firstWindow),
            superviewID: ObjectIdentifier(secondSuperview),
            frameInWindow: previous.frameInWindow
        )

        XCTAssertTrue(terminalPortalAnchorNeedsFullReconciliation(
            previous: nil,
            current: previous
        ), "The first geometry report must reconcile every portal entry")
        XCTAssertFalse(terminalPortalAnchorNeedsFullReconciliation(
            previous: previous,
            current: frameOnlyChange
        ), "Frame-only changes are handled by targeted and external geometry synchronization")
        XCTAssertFalse(terminalPortalAnchorNeedsFullReconciliation(
            previous: previous,
            current: previous
        ), "A forced callback on unchanged topology must remain targeted")
        XCTAssertTrue(terminalPortalAnchorNeedsFullReconciliation(
            previous: previous,
            current: windowChange
        ))
        XCTAssertTrue(terminalPortalAnchorNeedsFullReconciliation(
            previous: previous,
            current: superviewChange
        ))
    }

    func testEscapeNeverComposing() {
        XCTAssertFalse(
            GhosttyNSView.computeComposingFlag(
                keyCode: 53,
                markedTextBefore: true,
                hasMarkedTextAfter: true,
                accumulatedTextIsEmpty: false
            ),
            "Escape cancels composition and must never be marked composing"
        )
    }

    func testReturnClearingIME_returnsFalse() {
        XCTAssertFalse(
            GhosttyNSView.computeComposingFlag(
                keyCode: 36,
                markedTextBefore: true,
                hasMarkedTextAfter: false,
                accumulatedTextIsEmpty: true
            ),
            "Return that only clears IME composition must reach Ghostty as a real Return"
        )
    }

    func testReturnAfterIMECommit_stillComposingFlag() {
        XCTAssertTrue(
            GhosttyNSView.computeComposingFlag(
                keyCode: 36,
                markedTextBefore: true,
                hasMarkedTextAfter: false,
                accumulatedTextIsEmpty: false
            ),
            "Return after insertText commit stays composing; replay handling decides physical Return delivery"
        )
    }

    func testReturnNoIME_returnsFalse() {
        XCTAssertFalse(
            GhosttyNSView.computeComposingFlag(
                keyCode: 36,
                markedTextBefore: false,
                hasMarkedTextAfter: false,
                accumulatedTextIsEmpty: true
            )
        )
    }

    func testRegularKeyWhileComposing_returnsTrue() {
        XCTAssertTrue(
            GhosttyNSView.computeComposingFlag(
                keyCode: 0,
                markedTextBefore: false,
                hasMarkedTextAfter: true,
                accumulatedTextIsEmpty: true
            )
        )
    }

    func testRegularKeyNoIME_returnsFalse() {
        XCTAssertFalse(
            GhosttyNSView.computeComposingFlag(
                keyCode: 0,
                markedTextBefore: false,
                hasMarkedTextAfter: false,
                accumulatedTextIsEmpty: true
            )
        )
    }

    func testReturnStillComposing_returnsTrue() {
        XCTAssertTrue(
            GhosttyNSView.computeComposingFlag(
                keyCode: 36,
                markedTextBefore: true,
                hasMarkedTextAfter: true,
                accumulatedTextIsEmpty: true
            ),
            "Return while marked text is still visible belongs to the IME"
        )
    }

    func testReturnClearingIME_butAccumulatorNotEmpty_returnsTrue() {
        XCTAssertTrue(
            GhosttyNSView.computeComposingFlag(
                keyCode: 36,
                markedTextBefore: true,
                hasMarkedTextAfter: false,
                accumulatedTextIsEmpty: false
            ),
            "Committed IME text is handled by accumulated text plus replay logic"
        )
    }
}
