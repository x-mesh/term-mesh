import XCTest
import AppKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The palette is on screen for ~47ms (96ms at worst, measured) before it owns
/// input. Keys arriving in that window are held for it instead of going to
/// whatever had focus before — but only the ones that are text.
@MainActor
final class CommandPaletteKeyAbsorptionTests: XCTestCase {
    private func absorbs(_ characters: String?, _ flags: NSEvent.ModifierFlags = []) -> Bool {
        AppDelegate.commandPaletteAbsorbsKey(characters: characters, flags: flags)
    }

    func testPlainTextIsHeldForThePalette() {
        XCTAssertTrue(absorbs("a"))
        XCTAssertTrue(absorbs("Z"))
        XCTAssertTrue(absorbs("7"))
        XCTAssertTrue(absorbs(" "))
        XCTAssertTrue(absorbs("한"))
        XCTAssertTrue(absorbs("é"))
    }

    func testShiftedTextIsStillText() {
        XCTAssertTrue(absorbs("A", [.shift]))
    }

    /// A chord is a shortcut, not something to type into the query.
    func testChordsAreLeftAlone() {
        XCTAssertFalse(absorbs("p", [.command, .shift]))
        XCTAssertFalse(absorbs("n", [.control]))
        XCTAssertFalse(absorbs("a", [.option]))
        XCTAssertFalse(absorbs("w", [.command]))
    }

    /// Escape, Return and Tab each have a handler that must still see them.
    func testControlKeysAreLeftAlone() {
        XCTAssertFalse(absorbs("\u{1B}"))
        XCTAssertFalse(absorbs("\r"))
        XCTAssertFalse(absorbs("\t"))
        XCTAssertFalse(absorbs("\u{7F}"))
    }

    /// Arrows and function keys live in the private-use range AppKit reserves
    /// for them; absorbing those would put junk in the query.
    func testFunctionKeyRangeIsLeftAlone() {
        XCTAssertFalse(absorbs(String(UnicodeScalar(0xF700)!)))  // up arrow
        XCTAssertFalse(absorbs(String(UnicodeScalar(0xF701)!)))  // down arrow
        XCTAssertFalse(absorbs(String(UnicodeScalar(0xF704)!)))  // F1
    }

    func testEmptyAndMissingCharactersAreLeftAlone() {
        XCTAssertFalse(absorbs(nil))
        XCTAssertFalse(absorbs(""))
    }

    /// A string that mixes text with a control character is not text.
    func testMixedSequencesAreLeftAlone() {
        XCTAssertFalse(absorbs("a\u{1B}"))
    }
}
