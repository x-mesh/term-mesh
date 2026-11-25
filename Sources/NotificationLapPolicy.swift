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
