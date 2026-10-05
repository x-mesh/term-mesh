import XCTest
import AppKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

// Keycode constants (mirroring IMETextView's private VK enum)
private enum TestVK {
    static let upArrow: UInt16    = 0x7E  // 126
    static let downArrow: UInt16  = 0x7D  // 125
    static let leftArrow: UInt16  = 0x7B  // 123
    static let rightArrow: UInt16 = 0x7C  // 124
}

/// GHOSTTY_MODS_ALT raw value (1 << 2 = 4).
/// Test target has no bridging header, so we use the raw value directly.
private let ghosttyModsAlt: UInt32 = 4

private final class CopyRoutingTerminalView: GhosttyNSView {
    var selectionPresent = false
    var copied = false
    override func hasSelection() -> Bool { selectionPresent }
    var copyAccepted = true
    override func copySelectionToLocalClipboard() -> Bool { copied = true; return copyAccepted }
}

private final class UnpublishedCopyTerminalView: GhosttyNSView {
    override func hasSelection() -> Bool { true }
    override func performBindingAction(_ action: String) -> Bool { true }
}

/// Tests that IMETextView correctly routes arrow key events:
/// - Option+↑↓ → plain arrows to terminal (Claude Code selection)
/// - Option+←→ → Alt-modified arrows to terminal (word movement)
/// - Empty IME + plain ↑↓ → forwards to terminal
/// - Non-empty IME + plain ↑↓ → history navigation
/// - During IME composition (marked text) → does not forward
final class IMEArrowKeyTests: XCTestCase {

    private var sut: IMETextView!
    private var capturedKeys: [(keycode: UInt16, mods: UInt32)] = []
    private var historyUpCalled = false
    private var historyDownCalled = false

    override func setUp() {
        super.setUp()
        sut = IMETextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        capturedKeys = []
        historyUpCalled = false
        historyDownCalled = false

        sut.sendKeyHandler = { [weak self] keycode, mods in
            self?.capturedKeys.append((keycode: keycode, mods: mods))
        }
        sut.historyUpHandler = { [weak self] in
            self?.historyUpCalled = true
        }
        sut.historyDownHandler = { [weak self] in
            self?.historyDownCalled = true
        }
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeKeyDownEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: keyCode == 8 ? "c" : "",
            charactersIgnoringModifiers: keyCode == 8 ? "c" : "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    @MainActor
    func testCopyUsesTheIMEPaneInsteadOfAnotherPaneSelection() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = CopyRoutingTerminalView(frame: .zero)
        other.selectionPresent = true
        let current = CopyRoutingTerminalView(frame: .zero)
        current.selectionPresent = true
        let otherPane = GhosttySurfaceScrollView(surfaceView: other)
        let currentPane = GhosttySurfaceScrollView(surfaceView: current)
        window.contentView?.addSubview(otherPane)
        window.contentView?.addSubview(currentPane)
        currentPane.addSubview(sut)
        window.makeFirstResponder(sut)
        guard let event = makeKeyDownEvent(keyCode: 8, modifiers: .command) else {
            XCTFail("Expected copy event")
            return
        }
        _ = sut.performKeyEquivalent(with: event)
        XCTAssertTrue(current.copied)
        XCTAssertFalse(other.copied)
        window.orderOut(nil)
    }

    @MainActor
    func testCopyDoesNotBorrowAnotherPaneSelectionWhenItsOwnIsEmpty() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = CopyRoutingTerminalView(frame: .zero)
        other.selectionPresent = true
        let current = CopyRoutingTerminalView(frame: .zero)
        let otherPane = GhosttySurfaceScrollView(surfaceView: other)
        let currentPane = GhosttySurfaceScrollView(surfaceView: current)
        window.contentView?.addSubview(otherPane)
        window.contentView?.addSubview(currentPane)
        currentPane.addSubview(sut)
        window.makeFirstResponder(sut)
        guard let event = makeKeyDownEvent(keyCode: 8, modifiers: .command) else {
            XCTFail("Expected copy event")
            return
        }
        _ = sut.performKeyEquivalent(with: event)
        XCTAssertFalse(current.copied)
        XCTAssertFalse(other.copied)
        window.orderOut(nil)
    }

    @MainActor
    func testInactivePaneDoesNotInterceptTheFocusedIMECopyGesture() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = CopyRoutingTerminalView(frame: .zero)
        other.selectionPresent = true
        let otherPane = GhosttySurfaceScrollView(surfaceView: other)
        otherPane.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        let currentPane = GhosttySurfaceScrollView(surfaceView: CopyRoutingTerminalView(frame: .zero))
        currentPane.frame = NSRect(x: 300, y: 0, width: 300, height: 300)
        currentPane.addSubview(sut)
        window.contentView?.addSubview(otherPane)
        window.contentView?.addSubview(currentPane)
        otherPane.toggleIMEInputBar()
        otherPane.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let inactiveIME = try XCTUnwrap(otherPane.findIMETextView())
        window.makeFirstResponder(sut)
        guard let event = makeKeyDownEvent(keyCode: 8, modifiers: .command) else {
            XCTFail("Expected copy event")
            return
        }
        XCTAssertFalse(inactiveIME.performKeyEquivalent(with: event))
        XCTAssertFalse(other.performKeyEquivalent(with: event))
        XCTAssertFalse(other.copied)
        window.orderOut(nil)
    }

    @MainActor
    func testCopyFailureDoesNotReportTheGestureAsHandled() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = CopyRoutingTerminalView(frame: .zero)
        terminal.selectionPresent = true
        terminal.copyAccepted = false
        let pane = GhosttySurfaceScrollView(surfaceView: terminal)
        pane.addSubview(sut)
        window.contentView?.addSubview(pane)
        window.makeFirstResponder(sut)
        guard let event = makeKeyDownEvent(keyCode: 8, modifiers: .command) else {
            XCTFail("Expected copy event")
            return
        }
        XCTAssertFalse(sut.performKeyEquivalent(with: event))
        XCTAssertTrue(terminal.copied)
        window.orderOut(nil)
    }

    @MainActor
    func testCopyWithoutAClipboardUpdateIsNotReportedAsSuccess() {
        let terminal = UnpublishedCopyTerminalView(frame: .zero)
        XCTAssertFalse(terminal.copySelectionToLocalClipboard())
    }

    // MARK: - Option+Arrow tests (Claude Code selection)

    func testOptionUpSendsPlainUpArrowToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: TestVK.upArrow, modifiers: [.option]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1, "sendKeyHandler should be called once")
        XCTAssertEqual(capturedKeys.first?.keycode, TestVK.upArrow, "Should send Up arrow keycode")
        XCTAssertEqual(capturedKeys.first?.mods, 0, "Should send zero mods (plain arrow, NOT Alt-modified)")
    }

    func testOptionDownSendsPlainDownArrowToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: TestVK.downArrow, modifiers: [.option]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1)
        XCTAssertEqual(capturedKeys.first?.keycode, TestVK.downArrow)
        XCTAssertEqual(capturedKeys.first?.mods, 0, "Should send zero mods (plain arrow, NOT Alt-modified)")
    }

    // MARK: - Option+Left/Right preserves Alt modifier (word movement)

    func testOptionLeftSendsAltLeftToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: TestVK.leftArrow, modifiers: [.option]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1)
        XCTAssertEqual(capturedKeys.first?.keycode, TestVK.leftArrow)
        XCTAssertEqual(capturedKeys.first?.mods, ghosttyModsAlt,
                       "Should preserve Alt modifier for word-level cursor movement")
    }

    func testOptionRightSendsAltRightToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: TestVK.rightArrow, modifiers: [.option]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1)
        XCTAssertEqual(capturedKeys.first?.keycode, TestVK.rightArrow)
        XCTAssertEqual(capturedKeys.first?.mods, ghosttyModsAlt,
                       "Should preserve Alt modifier for word-level cursor movement")
    }

    // MARK: - Empty IME forwards plain arrows to terminal

    func testEmptyIMEPlainUpForwardsToTerminal() {
        XCTAssertTrue(sut.string.isEmpty, "Precondition: IME text should be empty")

        guard let event = makeKeyDownEvent(keyCode: TestVK.upArrow) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1)
        XCTAssertEqual(capturedKeys.first?.keycode, TestVK.upArrow)
        XCTAssertEqual(capturedKeys.first?.mods, 0)
        XCTAssertFalse(historyUpCalled, "Should forward to terminal, not trigger history")
    }

    func testEmptyIMEPlainDownForwardsToTerminal() {
        XCTAssertTrue(sut.string.isEmpty, "Precondition: IME text should be empty")

        guard let event = makeKeyDownEvent(keyCode: TestVK.downArrow) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1)
        XCTAssertEqual(capturedKeys.first?.keycode, TestVK.downArrow)
        XCTAssertEqual(capturedKeys.first?.mods, 0)
        XCTAssertFalse(historyDownCalled, "Should forward to terminal, not trigger history")
    }

    // MARK: - Non-empty IME routes plain arrows to history

    func testNonEmptyIMEPlainUpTriggersHistory() {
        sut.string = "some text"

        guard let event = makeKeyDownEvent(keyCode: TestVK.upArrow) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertTrue(capturedKeys.isEmpty, "Should NOT forward to terminal when IME has text")
        XCTAssertTrue(historyUpCalled, "Should trigger history navigation")
    }

    func testNonEmptyIMEPlainDownTriggersHistory() {
        sut.string = "some text"

        guard let event = makeKeyDownEvent(keyCode: TestVK.downArrow) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertTrue(capturedKeys.isEmpty, "Should NOT forward to terminal when IME has text")
        XCTAssertTrue(historyDownCalled, "Should trigger history navigation")
    }

    // MARK: - Marked text (IME composing) blocks forwarding

    func testOptionUpDuringMarkedTextDoesNotForwardToTerminal() {
        sut.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(sut.hasMarkedText(), "Precondition: should have marked text")

        guard let event = makeKeyDownEvent(keyCode: TestVK.upArrow, modifiers: [.option]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertTrue(capturedKeys.isEmpty, "Should NOT send to terminal during IME composition")
    }
}
