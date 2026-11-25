import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class NotificationLapPolicyTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()

    private func decide(
        hasUnread: Bool = true,
        latest: UUID?,
        lastLapped: UUID? = nil,
        visible: Bool = true,
        reduceMotion: Bool = false
    ) -> NotificationLapDecision {
        NotificationLapPolicy.decide(
            hasUnread: hasUnread,
            latestUnreadID: latest,
            lastLappedID: lastLapped,
            isVisibleInUI: visible,
            reduceMotion: reduceMotion
        )
    }

    func testNoUnreadHidesTheRingAndKeepsTheLapRecord() {
        let decision = decide(hasUnread: false, latest: nil, lastLapped: first)
        XCTAssertEqual(decision, NotificationLapDecision(ring: .hidden, playLap: false, lastLappedID: first))
    }

    func testNewVisibleNotificationSweepsOnceAndIsRecorded() {
        let decision = decide(latest: first)
        XCTAssertEqual(decision, NotificationLapDecision(ring: .faint, playLap: true, lastLappedID: first))
    }

    func testSameNotificationDoesNotSweepAgainOnLaterUpdates() {
        let decision = decide(latest: first, lastLapped: first)
        XCTAssertEqual(decision, NotificationLapDecision(ring: .faint, playLap: false, lastLappedID: first))
    }

    func testANewerNotificationSweepsAgain() {
        let decision = decide(latest: second, lastLapped: first)
        XCTAssertEqual(decision, NotificationLapDecision(ring: .faint, playLap: true, lastLappedID: second))
    }

    func testHiddenPaneWaitsAndSweepsWhenItFirstBecomesVisible() {
        let whileHidden = decide(latest: first, visible: false)
        XCTAssertEqual(whileHidden, NotificationLapDecision(ring: .faint, playLap: false, lastLappedID: nil))

        let onceVisible = decide(latest: first, lastLapped: whileHidden.lastLappedID)
        XCTAssertTrue(onceVisible.playLap)
    }

    func testReduceMotionShowsOnlyTheFaintRingAndConsumesTheNotification() {
        let decision = decide(latest: first, reduceMotion: true)
        XCTAssertEqual(decision, NotificationLapDecision(ring: .faint, playLap: false, lastLappedID: first))
    }

    func testManualUnreadShowsTheFaintRingWithoutSweeping() {
        let decision = decide(latest: nil, lastLapped: first)
        XCTAssertEqual(decision, NotificationLapDecision(ring: .faint, playLap: false, lastLappedID: first))
    }
}
