import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class GhosttyTerminalViewComposingTests: XCTestCase {
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
            anchorGeometries: [ObjectIdentifier(anchor): geometry]
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
