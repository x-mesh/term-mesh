import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class GhosttyTerminalViewComposingTests: XCTestCase {
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
