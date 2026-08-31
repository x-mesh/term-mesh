import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The boundary that keeps an injection log from becoming a keylog.
///
/// The rule decides what content is written out, so both sides of it are
/// load-bearing in opposite directions: too permissive and the log records
/// every pasted secret and agent prompt; too strict and the stray `ÿ` this
/// exists to catch is filtered away with them. It is also a deliberate mirror
/// of `is_ordinary_typed_text` in `daemon/term-mesh-peer-relay/src/main.rs`,
/// so the local log and the relay log can be read against each other — a
/// divergence would make the same byte look different depending on which door
/// it came through.
final class InputInjectionLogTests: XCTestCase {

    private func ordinary(_ text: String) -> Bool {
        InputInjectionLog.isOrdinaryTypedText(Array(text.utf8))
    }

    // MARK: - Never recorded

    func test_ordinaryTypingIsNeverWrittenOut() {
        XCTAssertTrue(ordinary("ls -la"))
        XCTAssertTrue(ordinary("hello\n"))
        XCTAssertTrue(ordinary("a\tb\r\n"))
        XCTAssertTrue(ordinary(""))
    }

    func test_theEdgesOfPrintableASCIIAreOrdinary() {
        // Space (0x20) and `~` (0x7E) are the first and last printable bytes.
        // An off-by-one at either end would start logging ordinary text.
        XCTAssertTrue(InputInjectionLog.isOrdinaryTypedText([0x20]))
        XCTAssertTrue(InputInjectionLog.isOrdinaryTypedText([0x7E]))
    }

    // MARK: - Recorded

    func test_theStrayHighByteIsRecorded() {
        // The whole reason this log exists: 0xFF turning up in an idle pane.
        XCTAssertFalse(InputInjectionLog.isOrdinaryTypedText([0xFF]))
    }

    func test_controlAndDeleteBytesAreRecorded() {
        XCTAssertFalse(InputInjectionLog.isOrdinaryTypedText([0x00]))
        XCTAssertFalse(InputInjectionLog.isOrdinaryTypedText([0x1B, 0x5B, 0x41]))
        // 0x7F sits just past `~` and is DEL, not typing.
        XCTAssertFalse(InputInjectionLog.isOrdinaryTypedText([0x7F]))
    }

    func test_escapeSequencesAreRecordedEvenWhenTheirTailLooksTyped() {
        // `CSI 27;2;13~` — Shift+Enter under modifyOtherKeys, and the exact
        // shape whose tail (`;2;13~`) was found sitting in a prompt. Every
        // byte after the ESC is printable, so a rule that looked at the tail
        // alone would call this ordinary typing and drop the one record that
        // explains the symptom.
        XCTAssertFalse(
            InputInjectionLog.isOrdinaryTypedText(Array("\u{1b}[27;2;13~".utf8))
        )
    }

    func test_oneStrayByteTaintsAnOtherwiseOrdinaryChunk() {
        // Injections arrive as chunks, not single bytes. A chunk is recorded
        // whole or not at all, so a stray byte riding inside ordinary text has
        // to pull the chunk across the boundary — otherwise the interesting
        // case hides behind the text around it.
        XCTAssertFalse(InputInjectionLog.isOrdinaryTypedText(Array("ok".utf8) + [0xFF]))
    }

    func test_validNonASCIITextIsNotWrittenOut() {
        // Valid user text is not diagnostic evidence. Recording it would leak
        // pasted content while hiding invalid bytes among ordinary UTF-8.
        XCTAssertTrue(ordinary("한글"))
        XCTAssertTrue(ordinary("🙂"))
    }

    // MARK: - Enablement

    func test_recordingIsOffWithoutTheMarker() throws {
        // A release build carries this code, so "off unless asked" is the
        // property that makes shipping it safe. The env override is what the
        // test environment would trip over, so assert against the real
        // marker's absence rather than the cached flag.
        guard ProcessInfo.processInfo.environment["TERMMESH_INPUT_DEBUG"] == nil else {
            throw XCTSkip("TERMMESH_INPUT_DEBUG is set in this environment")
        }
        if !FileManager.default.fileExists(atPath: InputInjectionLog.markerPath) {
            XCTAssertFalse(InputInjectionLog.isEnabled)
        }
    }
}
