import AppKit
import Bonsplit

/// The user's space between pane cards, the sidebar card, and the window edges.
enum PaneGapSettings {
    static let key = "paneCardGap"
    static let defaultValue = Double(BonsplitCardMetrics.gap)
    static let range = Double(BonsplitCardMetrics.gapRange.lowerBound)...Double(BonsplitCardMetrics.gapRange.upperBound)

    static func clamped(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, range.lowerBound), range.upperBound))
    }

    static var current: CGFloat {
        let stored = UserDefaults.standard.object(forKey: key) as? Double ?? defaultValue
        return clamped(stored)
    }
}

/// Whether pane splits and zooms slide, and whether the pane they leave in
/// focus glows.
///
/// On by default. The slide resizes the terminal while it moves, the same as
/// dragging a divider, so a full-screen TUI repaints on every resize; turning
/// it off in Settings avoids that.
enum PaneTransitionAnimationSettings {
    static let key = "paneTransitionAnimations"
    static let defaultValue = true

    /// Length of one split or zoom slide, in seconds.
    static let durationKey = "paneTransitionAnimationDuration"
    /// Rex Natural-style landing: fast enough for terminal work while leaving
    /// room for source, destination, and divider to settle as one motion.
    static let defaultDuration: Double = 0.28
    static let durationRange: ClosedRange<Double> = 0.1...0.6

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    static func clampedDuration(_ value: Double) -> Double {
        min(max(value, durationRange.lowerBound), durationRange.upperBound)
    }

    static var duration: Double {
        clampedDuration(UserDefaults.standard.object(forKey: durationKey) as? Double ?? defaultDuration)
    }
}

/// Space between a pane card's edge and the terminal grid.
///
/// Applied by the app around the surface view rather than through Ghostty's
/// `window-padding-*`: Ghostty computes that padding only when a surface is
/// created, so a config reload leaves open terminals unchanged.
///
/// A pane is rarely a whole number of rows tall. The bottom is held at its
/// setting and the leftover goes above the first row, because the prompt sits
/// on the last row and that edge is the one people read.
enum PanePaddingSettings {
    static let horizontalKey = "paneContentPaddingX"
    static let topKey = "paneContentPaddingTop"
    static let bottomKey = "paneContentPaddingBottom"
    static let defaultHorizontal = Double(BonsplitCardMetrics.gap)
    static let defaultTop: Double = 2
    static let defaultBottom: Double = 6
    static let range: ClosedRange<Double> = 0...24

    static func clamped(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, range.lowerBound), range.upperBound))
    }

    static var currentHorizontal: CGFloat { stored(horizontalKey, default: defaultHorizontal) }
    static var currentTop: CGFloat { stored(topKey, default: defaultTop) }
    static var currentBottom: CGFloat { stored(bottomKey, default: defaultBottom) }

    private static func stored(_ key: String, default fallback: Double) -> CGFloat {
        clamped(UserDefaults.standard.object(forKey: key) as? Double ?? fallback)
    }

    /// The rect the terminal grid may use inside `bounds` (not flipped: y grows
    /// upward). Never negative: padding larger than a tiny pane leaves an
    /// empty rect.
    static func contentRect(in bounds: NSRect, horizontal: CGFloat, top: CGFloat, bottom: CGFloat) -> NSRect {
        let dx = max(0, min(horizontal, bounds.width / 2))
        let bottomInset = max(0, min(bottom, bounds.height))
        let topInset = max(0, min(top, bounds.height - bottomInset))
        return NSRect(
            x: bounds.minX + dx,
            y: bounds.minY + bottomInset,
            width: max(0, bounds.width - dx * 2),
            height: max(0, bounds.height - bottomInset - topInset)
        )
    }

    /// Trims `rect` to a whole number of rows, keeping its bottom edge, so the
    /// row remainder becomes space above the grid instead of under the prompt.
    /// Heights are compared in device pixels because that is how Ghostty
    /// counts rows.
    static func gridSnapped(_ rect: NSRect, cellHeightPx: CGFloat, scale: CGFloat) -> NSRect {
        guard cellHeightPx > 0, scale > 0, rect.height > 0 else { return rect }
        let heightPx = (rect.height * scale).rounded(.down)
        let rows = (heightPx / cellHeightPx).rounded(.down)
        guard rows >= 1 else { return rect }
        var snapped = rect
        snapped.size.height = rows * cellHeightPx / scale
        return snapped
    }
}
