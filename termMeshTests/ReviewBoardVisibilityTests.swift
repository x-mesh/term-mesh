import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Closing the board and getting it back.
///
/// Two keys decide whether it is on screen and they disagree easily: `enabled`
/// is "this window has a board", `isClosed` is "I dismissed it". The close
/// button set only the second and nothing ever cleared it, so the board was a
/// one-way door — no menu item, no shortcut, and the Settings switch wrote the
/// other key, which changed nothing.
final class ReviewBoardVisibilityTests: XCTestCase {
    private var savedEnabled = false
    private var savedClosed = false

    override func setUp() {
        super.setUp()
        savedEnabled = UserDefaults.standard.bool(forKey: ReviewBoardSettings.enabledKey)
        savedClosed = UserDefaults.standard.bool(forKey: ReviewBoardSettings.isClosedKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedEnabled, forKey: ReviewBoardSettings.enabledKey)
        UserDefaults.standard.set(savedClosed, forKey: ReviewBoardSettings.isClosedKey)
        super.tearDown()
    }

    func testShowingAfterClosingBringsItBack() {
        ReviewBoardSettings.setVisible(true)
        XCTAssertTrue(ReviewBoardSettings.isVisible)

        ReviewBoardSettings.setVisible(false)
        XCTAssertFalse(ReviewBoardSettings.isVisible)

        ReviewBoardSettings.setVisible(true)
        XCTAssertTrue(ReviewBoardSettings.isVisible, "closing must not be a one-way door")
    }

    func testToggleAlternates() {
        ReviewBoardSettings.setVisible(false)
        ReviewBoardSettings.toggleVisible()
        XCTAssertTrue(ReviewBoardSettings.isVisible)
        ReviewBoardSettings.toggleVisible()
        XCTAssertFalse(ReviewBoardSettings.isVisible)
    }

    /// The exact stuck state users could reach: dismissed, then switched on.
    func testEnablingClearsAPriorDismissal() {
        UserDefaults.standard.set(true, forKey: ReviewBoardSettings.enabledKey)
        UserDefaults.standard.set(true, forKey: ReviewBoardSettings.isClosedKey)
        XCTAssertFalse(ReviewBoardSettings.isVisible, "this is the stuck state")

        ReviewBoardSettings.setVisible(true)
        XCTAssertTrue(ReviewBoardSettings.isVisible)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: ReviewBoardSettings.isClosedKey))
    }
}
