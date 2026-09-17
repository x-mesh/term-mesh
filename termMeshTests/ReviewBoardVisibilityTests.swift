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

    /// How narrow the board may get.
    ///
    /// The bound is the whole feature here: a board that will not go below a
    /// second column's width is a board you close instead of keeping.
    func testTheBoardCanBeDraggedNarrow() {
        XCTAssertEqual(ReviewBoardSettings.clampedWidth(200), 200)
        XCTAssertEqual(ReviewBoardSettings.clampedWidth(120), ReviewBoardSettings.minimumWidth)
        XCTAssertLessThanOrEqual(ReviewBoardSettings.minimumWidth, 200)
        XCTAssertLessThanOrEqual(ReviewBoardSettings.defaultWidth, 320)
    }

    /// A width saved under the old, wider floor is not forced back up.
    func testAStoredNarrowWidthSurvivesAReload() {
        let defaults = UserDefaults.standard
        let saved = defaults.double(forKey: ReviewBoardSettings.widthKey)
        defer { defaults.set(saved, forKey: ReviewBoardSettings.widthKey) }

        ReviewBoardSettings.saveWidth(210, defaults: defaults)
        XCTAssertEqual(ReviewBoardSettings.loadWidth(defaults: defaults), 210)
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

    /// Dismissing the panel must not switch a feature off.
    ///
    /// `enabledKey` is the review-board half of the coordinator gate, so a
    /// close that wrote it false turned distributed workspaces off with no
    /// notice and no visible way back.
    func testClosingKeepsTheCoordinatorGateUp() {
        ReviewBoardSettings.setVisible(true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: ReviewBoardSettings.enabledKey))

        ReviewBoardSettings.setVisible(false)

        XCTAssertFalse(ReviewBoardSettings.isVisible)
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: ReviewBoardSettings.enabledKey),
            "closing the panel must leave the coordinator gate alone"
        )
    }
}

/// Getting back a gate an older build lowered on close.
final class ReviewBoardLegacyCloseRepairTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "term-mesh.tests.reviewBoardRepair.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRepairRaisesAGateThatOnlyACloseCouldHaveLowered() {
        defaults.set(false, forKey: ReviewBoardSettings.enabledKey)
        defaults.set(true, forKey: ReviewBoardSettings.isClosedKey)

        ReviewBoardSettings.repairLegacyCloseState(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: ReviewBoardSettings.enabledKey))
        XCTAssertTrue(
            defaults.bool(forKey: ReviewBoardSettings.isClosedKey),
            "repair restores the gate, not the panel the user dismissed"
        )
    }

    /// A user who switched the feature off in Settings stays switched off.
    func testRepairLeavesADeliberateOptOutAlone() {
        defaults.set(false, forKey: ReviewBoardSettings.enabledKey)
        defaults.set(false, forKey: ReviewBoardCoordinatorSettings.distributedFeatureKey)

        ReviewBoardSettings.repairLegacyCloseState(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: ReviewBoardSettings.enabledKey))
    }

    /// Repair is a migration, not a policy: a later close stays closed.
    func testRepairRunsOnlyOnce() {
        defaults.set(false, forKey: ReviewBoardSettings.enabledKey)
        ReviewBoardSettings.repairLegacyCloseState(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: ReviewBoardSettings.enabledKey))

        defaults.set(false, forKey: ReviewBoardSettings.enabledKey)
        ReviewBoardSettings.repairLegacyCloseState(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: ReviewBoardSettings.enabledKey))
    }

    func testRepairDoesNothingWhenTheGateWasNeverWritten() {
        ReviewBoardSettings.repairLegacyCloseState(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: ReviewBoardSettings.enabledKey))
    }
}
