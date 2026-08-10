import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Mirrors the daemon's `query_filter.rs` test set, minus the parts that only
/// apply there: `term-meshd` synthesizes replies because it faces a bare PTY,
/// while a Mac host has a real Ghostty already answering these locally. What
/// both must agree on is which sequences never reach a second terminal.
final class PeerTerminalQueryStripperTests: XCTestCase {

    private func strip(_ input: [UInt8], with stripper: inout PeerTerminalQueryStripper) -> [UInt8] {
        Array(stripper.strip(Data(input)))
    }

    private func stripOnce(_ input: [UInt8]) -> [UInt8] {
        var stripper = PeerTerminalQueryStripper()
        return strip(input, with: &stripper)
    }

    private func esc(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: - Ordinary output is untouched

    func testPlainTextPassesThrough() {
        XCTAssertEqual(stripOnce(esc("hello world\n")), esc("hello world\n"))
    }

    /// Cursor movement, not a question. Stripping this would move text.
    func testNonQueryCSIPassesThrough() {
        let cursorUp: [UInt8] = [0x1B] + esc("[2A")
        XCTAssertEqual(stripOnce(cursorUp), cursorUp)
    }

    /// `OSC 11 ; rgb:…` SETS the background; only `OSC 11 ; ?` asks. Dropping a
    /// set would change how the pane looks.
    func testOSCSetPassesThrough() {
        let setBackground: [UInt8] = [0x1B] + esc("]11;rgb:00/00/00") + [0x07]
        XCTAssertEqual(stripOnce(setBackground), setBackground)
    }

    /// A lone ESC is not a sequence and must not be eaten.
    func testLoneEscapeIsNotSwallowed() {
        let input: [UInt8] = [0x1B] + esc("M")
        XCTAssertEqual(stripOnce(input), input)
    }

    // MARK: - Queries are removed

    /// The one that put `P>|ghostty …` in a prompt.
    func testXTVERSIONIsStripped() {
        XCTAssertEqual(stripOnce([0x1B] + esc("[>q")), [])
    }

    func testXTVERSIONZeroParamIsStripped() {
        XCTAssertEqual(stripOnce([0x1B] + esc("[>0q")), [])
    }

    func testDeviceStatusReportIsStripped() {
        XCTAssertEqual(stripOnce([0x1B] + esc("[5n")), [])
    }

    func testCursorPositionReportIsStripped() {
        XCTAssertEqual(stripOnce([0x1B] + esc("[6n")), [])
    }

    func testDeviceAttributesQueriesAreStripped() {
        for body in ["[c", "[0c", "[>c", "[>0c", "[=c", "[=1c"] {
            XCTAssertEqual(stripOnce([0x1B] + esc(body)), [], "\(body) should be stripped")
        }
    }

    func testBackgroundColorQueryIsStrippedWithBELTerminator() {
        XCTAssertEqual(stripOnce([0x1B] + esc("]11;?") + [0x07]), [])
    }

    func testForegroundColorQueryIsStrippedWithSTTerminator() {
        XCTAssertEqual(stripOnce([0x1B] + esc("]10;?") + [0x1B] + esc("\\")), [])
    }

    /// `q` finals that are not XTVERSION — DECSCUSR sets the cursor shape.
    func testNonXTVERSIONFinalQPassesThrough() {
        let setCursorShape: [UInt8] = [0x1B] + esc("[2 q")
        XCTAssertEqual(stripOnce(setCursorShape), setCursorShape)
    }

    // MARK: - Reassembly across reads

    /// `broadcast` sees whatever one read returned, so a query can arrive in
    /// pieces. This is the case a plain substring search cannot handle.
    func testQuerySplitAcrossChunksIsStripped() {
        var stripper = PeerTerminalQueryStripper()
        XCTAssertEqual(strip([0x1B] + esc("[>"), with: &stripper), [])
        XCTAssertEqual(strip(esc("q"), with: &stripper), [])
    }

    func testOSCQuerySplitAcrossChunksIsStripped() {
        var stripper = PeerTerminalQueryStripper()
        XCTAssertEqual(strip([0x1B] + esc("]11"), with: &stripper), [])
        XCTAssertEqual(strip(esc(";?") + [0x07], with: &stripper), [])
    }

    func testDeviceAttributesQuerySplitAcrossChunksIsStripped() {
        var stripper = PeerTerminalQueryStripper()
        XCTAssertEqual(strip([0x1B] + esc("[>"), with: &stripper), [])
        XCTAssertEqual(strip(esc("0c"), with: &stripper), [])
    }

    /// Text on either side of a split query has to survive intact.
    func testTextAroundASplitQuerySurvives() {
        var stripper = PeerTerminalQueryStripper()
        XCTAssertEqual(strip(esc("ab") + [0x1B] + esc("[6"), with: &stripper), esc("ab"))
        XCTAssertEqual(strip(esc("n") + esc("cd"), with: &stripper), esc("cd"))
    }

    func testBackToBackQueriesAreBothStripped() {
        XCTAssertEqual(stripOnce([0x1B] + esc("[6n") + [0x1B] + esc("[>q")), [])
    }

    func testQueriesAreRemovedFromSurroundingOutput() {
        let input = esc("before") + [0x1B] + esc("[>q") + esc("after")
        XCTAssertEqual(stripOnce(input), esc("beforeafter"))
    }

    func testFreshQueryAfterInterruptedCSIIsStillStripped() {
        let interrupted = [UInt8]([0x1B]) + esc("[12")
        let query = [UInt8]([0x1B]) + esc("[6n")
        XCTAssertEqual(stripOnce(interrupted + query), interrupted + [0x18])
    }

    func testFreshQueryAfterInterruptedOSCIsStillStripped() {
        let interrupted = [UInt8]([0x1B]) + esc("]0;unfinished")
        let query = [UInt8]([0x1B]) + esc("[>q")
        XCTAssertEqual(stripOnce(interrupted + query), interrupted + [0x18])
    }

    func testFreshOSCQueryAfterInterruptedCSILeavesParserGrounded() {
        let interrupted = [UInt8]([0x1B]) + esc("[12")
        let query = [UInt8]([0x1B]) + esc("]11;?") + [0x07]
        XCTAssertEqual(stripOnce(interrupted + query), interrupted + [0x18])
    }

    /// Bytes 0x9B and 0x9D can occur as UTF-8 continuation bytes. The PTY
    /// stream decoder treats them as text, not raw C1 CSI/OSC introducers.
    func testUTF8ContainingC1ByteValuesPassesThrough() {
        let input = Array("ěĝ".utf8)
        XCTAssertTrue(input.contains(0x9B))
        XCTAssertTrue(input.contains(0x9D))
        XCTAssertEqual(stripOnce(input), input)
    }

    // MARK: - Malformed input is flushed, never swallowed

    /// A CSI that never terminates would otherwise hold bytes back forever.
    func testOverlongCSIIsFlushed() {
        let long: [UInt8] = [0x1B, UInt8(ascii: "[")] + Array(repeating: UInt8(ascii: "1"), count: 300)
        XCTAssertEqual(stripOnce(long), long)
    }

    /// An ESC inside an OSC that is not a String Terminator.
    func testOSCWithNonTerminatorEscapeIsFlushed() {
        let input: [UInt8] = [0x1B] + esc("]11;?") + [0x1B] + esc("X")
        XCTAssertEqual(stripOnce(input), input)
    }

    // MARK: - The set matches the daemon's

    func testCSIQueryPredicateMatchesTheDaemonSet() {
        for body in ["c", "0c", ">c", ">0c", "=c", "=1c", ">q", ">0q", "5n", "6n"] {
            XCTAssertTrue(
                PeerTerminalQueryStripper.isCSIQuery([0x1B, UInt8(ascii: "[")] + esc(body)),
                "\(body) should be recognised"
            )
        }
        for body in ["2A", "0m", "2 q", "?1000h"] {
            XCTAssertFalse(
                PeerTerminalQueryStripper.isCSIQuery([0x1B, UInt8(ascii: "[")] + esc(body)),
                "\(body) is not a query"
            )
        }
    }

    func testOSCQueryPredicateOnlyMatchesQuestions() {
        XCTAssertTrue(PeerTerminalQueryStripper.isOSCQuery([0x1B, UInt8(ascii: "]")] + esc("11;?")))
        XCTAssertTrue(PeerTerminalQueryStripper.isOSCQuery([0x1B, UInt8(ascii: "]")] + esc("10;?")))
        XCTAssertFalse(PeerTerminalQueryStripper.isOSCQuery([0x1B, UInt8(ascii: "]")] + esc("11;rgb:00/00/00")))
        XCTAssertFalse(PeerTerminalQueryStripper.isOSCQuery([0x1B, UInt8(ascii: "]")] + esc("0;title")))
        XCTAssertFalse(PeerTerminalQueryStripper.isOSCQuery([0x1B, UInt8(ascii: "]")] + esc("12;?")))
    }
}
