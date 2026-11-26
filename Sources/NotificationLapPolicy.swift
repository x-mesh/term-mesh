import Foundation

enum NotificationRingState: Equatable {
    case hidden
    case faint
}

struct NotificationLapDecision: Equatable {
    let ring: NotificationRingState
    let playLap: Bool
    let lastLappedID: UUID?
}

/// Decides whether the unread-notification light sweeps once around a pane.
///
/// The hosted surface re-applies its ring state on every SwiftUI update and
/// portal re-attach, so the sweep is keyed to the notification itself: one
/// notification sweeps at most once, and only while the pane is on screen.
enum NotificationLapPolicy {
    static func decide(
        hasUnread: Bool,
        latestUnreadID: UUID?,
        lastLappedID: UUID?,
        isVisibleInUI: Bool,
        reduceMotion: Bool
    ) -> NotificationLapDecision {
        guard hasUnread else {
            return NotificationLapDecision(ring: .hidden, playLap: false, lastLappedID: lastLappedID)
        }
        guard let latestUnreadID, latestUnreadID != lastLappedID, isVisibleInUI else {
            return NotificationLapDecision(ring: .faint, playLap: false, lastLappedID: lastLappedID)
        }
        return NotificationLapDecision(ring: .faint, playLap: !reduceMotion, lastLappedID: latestUnreadID)
    }
}

/// Caps how many card rings sweep at once. Each sweep animates blurred
/// layers: on a 120 Hz display seven at once held WindowServer at 85% of a
/// core against 67% for two. A sweep that finds no free slot is skipped and
/// the ring stays faint.
struct NotificationLapSlots {
    static let limit = 2

    private(set) var active = 0
    private let limit: Int

    init(limit: Int = NotificationLapSlots.limit) {
        self.limit = limit
    }

    /// Takes a slot for a ring that is not sweeping yet. A ring that already
    /// holds one keeps it when its sweep restarts.
    mutating func acquire(alreadyHeld: Bool) -> Bool {
        if alreadyHeld { return true }
        guard active < limit else { return false }
        active += 1
        return true
    }

    mutating func release() {
        active = max(0, active - 1)
    }
}
