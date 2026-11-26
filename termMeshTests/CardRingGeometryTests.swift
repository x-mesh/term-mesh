import XCTest
import Bonsplit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class CardRingGeometryTests: XCTestCase {
    func testCardFrameAddsTheTabBarAboveAndTheBorderAroundTheSurface() {
        let surface = NSRect(x: 100, y: 50, width: 400, height: 300)
        let card = CardRingGeometry.cardFrame(forSurfaceFrame: surface)
        let border = BonsplitCardMetrics.borderWidth

        XCTAssertEqual(card.minX, surface.minX - border)
        XCTAssertEqual(card.maxX, surface.maxX + border)
        XCTAssertEqual(card.minY, surface.minY - border)
        XCTAssertEqual(card.maxY, surface.maxY + BonsplitCardMetrics.tabBarHeight)
    }

    func testRingViewGlowStaysInsideHalfTheGapSoNeighbouringCardsAreNotCovered() {
        let surface = NSRect(x: 0, y: 0, width: 200, height: 100)
        let card = CardRingGeometry.cardFrame(forSurfaceFrame: surface)
        let ring = CardRingGeometry.ringViewFrame(forSurfaceFrame: surface, gap: 12)

        XCTAssertEqual(card.minX - ring.minX, 6)
        XCTAssertEqual(ring.maxY - card.maxY, 6)
        XCTAssertEqual(CardRingGeometry.ringViewFrame(forSurfaceFrame: surface, gap: 0), card)
    }

    func testStrokeRangeCoversOneLoopOfTheDoubledOutline() {
        let length: CGFloat = 0.8
        let first = CardRingGeometry.strokeRange(headProgress: 0, length: length)
        let last = CardRingGeometry.strokeRange(headProgress: 1, length: length)

        XCTAssertEqual(first.start, 0, accuracy: 0.0001)
        XCTAssertEqual(first.end, 0.4, accuracy: 0.0001)
        XCTAssertEqual(last.start, 0.5, accuracy: 0.0001)
        XCTAssertEqual(last.end, 0.9, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(last.end, 1)
    }
}

@MainActor
final class CardRingTransitionGlowTests: XCTestCase {
    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testGlowShowsAHiddenRingOnlyUntilItEnds() {
        let ring = CardRingView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertTrue(ring.isHidden)

        ring.playTransitionGlow(delay: 0)
        XCTAssertFalse(ring.isHidden)
        // A notification ring turning off mid-glow must not cut the glow short.
        ring.apply(ring: .hidden)
        XCTAssertFalse(ring.isHidden)

        wait(1.1)
        XCTAssertTrue(ring.isHidden)
    }

    func testGlowLeavesAShownNotificationRingVisible() {
        let ring = CardRingView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        ring.apply(ring: .faint)
        ring.playTransitionGlow(delay: 0)
        wait(1.1)
        XCTAssertFalse(ring.isHidden)
    }

    func testARestartedGlowIsNotHiddenByTheEarlierOnesTimer() {
        let ring = CardRingView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        ring.playTransitionGlow(delay: 0)
        wait(0.6)
        ring.playTransitionGlow(delay: 0)
        wait(0.5)
        XCTAssertFalse(ring.isHidden, "the first glow's end must not hide the second")
        wait(0.6)
        XCTAssertTrue(ring.isHidden)
    }

    /// While another pane glows, only that pane may be outlined.
    func testHeldNotificationRingStaysHiddenUntilTheHoldEnds() {
        let ring = CardRingView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        ring.apply(ring: .faint)
        XCTAssertEqual(ring.notificationRingOpacity, 1)

        ring.holdNotificationRing(for: 0.3)
        XCTAssertEqual(ring.notificationRingOpacity, 0)
        // The surface re-applies its ring on every update; that must not end the hold.
        ring.apply(ring: .faint)
        XCTAssertEqual(ring.notificationRingOpacity, 0)

        wait(0.4)
        XCTAssertEqual(ring.notificationRingOpacity, 1)
    }

    func testHoldDoesNotBringBackARingReadDuringIt() {
        let ring = CardRingView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        ring.apply(ring: .faint)
        ring.holdNotificationRing(for: 0.2)
        ring.apply(ring: .hidden)
        wait(0.3)
        XCTAssertEqual(ring.notificationRingOpacity, 0)
    }

    func testARestartedHoldIsNotEndedByTheEarlierOnesTimer() {
        let ring = CardRingView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        ring.apply(ring: .faint)
        ring.holdNotificationRing(for: 0.3)
        wait(0.2)
        ring.holdNotificationRing(for: 0.3)
        wait(0.2)
        XCTAssertEqual(ring.notificationRingOpacity, 0, "the first hold's end must not show the ring")
        wait(0.2)
        XCTAssertEqual(ring.notificationRingOpacity, 1)
    }
}

/// The sweep slot pool is shared by every ring, so a ring that leaks its slot
/// stops sweeps in every pane for the rest of the session.
@MainActor
final class CardRingLapSlotTests: XCTestCase {
    private func makeRing() -> CardRingView {
        CardRingView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    }

    override func setUp() {
        super.setUp()
        CardRingView.debugSetLapLimit(1)
    }

    override func tearDown() {
        CardRingView.debugSetLapLimit(NotificationLapSlots.limit)
        super.tearDown()
    }

    func testARingReleasedMidSweepGivesItsSlotBack() {
        weak var released: CardRingView?
        autoreleasepool {
            let ring = makeRing()
            released = ring
            ring.playLap()
            XCTAssertEqual(CardRingView.debugActiveLaps, 1)
        }

        // No run loop turn in between, so the sweep's completion cannot have
        // returned the slot: only the ring's teardown can.
        XCTAssertNil(released, "the ring must be gone for this test to mean anything")
        XCTAssertEqual(CardRingView.debugActiveLaps, 0)

        let next = makeRing()
        next.playLap()
        XCTAssertEqual(CardRingView.debugActiveLaps, 1, "the freed slot must be usable by another ring")
    }

    func testASweepPastTheLimitIsSkipped() {
        let first = makeRing()
        let second = makeRing()
        first.playLap()
        second.playLap()
        XCTAssertEqual(CardRingView.debugActiveLaps, 1)
    }
}

final class PanePaddingSettingsTests: XCTestCase {
    func testContentRectInsetsSidesTopAndBottomSeparately() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(
            PanePaddingSettings.contentRect(in: bounds, horizontal: 10, top: 2, bottom: 12),
            NSRect(x: 10, y: 12, width: 380, height: 286)
        )
    }

    func testPaddingLargerThanATinyPaneLeavesAnEmptyRectNotANegativeOne() {
        let rect = PanePaddingSettings.contentRect(
            in: NSRect(x: 0, y: 0, width: 12, height: 30), horizontal: 24, top: 24, bottom: 24
        )
        XCTAssertGreaterThanOrEqual(rect.width, 0)
        XCTAssertGreaterThanOrEqual(rect.height, 0)
    }

    func testGridSnapKeepsTheBottomAndMovesTheRowRemainderAbove() {
        // 2x display, 28px rows: 300pt = 600px holds 21 rows (588px), 12px over.
        let rect = NSRect(x: 0, y: 10, width: 400, height: 300)
        let snapped = PanePaddingSettings.gridSnapped(rect, cellHeightPx: 28, scale: 2)
        XCTAssertEqual(snapped.minY, 10, "the bottom edge, under the prompt, stays put")
        XCTAssertEqual(snapped.height, 294, accuracy: 0.001)
    }

    func testGridSnapLeavesAnExactFitAndAnUnmeasuredSurfaceAlone() {
        let exact = NSRect(x: 0, y: 0, width: 100, height: 140)
        XCTAssertEqual(PanePaddingSettings.gridSnapped(exact, cellHeightPx: 28, scale: 2), exact)
        XCTAssertEqual(PanePaddingSettings.gridSnapped(exact, cellHeightPx: 0, scale: 2), exact)
    }

    func testClampedKeepsTheSettingInRange() {
        XCTAssertEqual(PanePaddingSettings.clamped(-5), 0)
        XCTAssertEqual(PanePaddingSettings.clamped(100), CGFloat(PanePaddingSettings.range.upperBound))
    }
}
