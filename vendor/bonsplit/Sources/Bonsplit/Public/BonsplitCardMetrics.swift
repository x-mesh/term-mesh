import CoreGraphics

/// Geometry of the card-style pane chrome. Hosts that draw on top of a pane
/// (for example a ring around the whole card) read these to match it.
public enum BonsplitCardMetrics {
    public static let tabBarHeight: CGFloat = 36
    /// Default for `BonsplitConfiguration.Appearance.cardGap`, which hosts may
    /// override; it is both the gap between cards and their margin to the
    /// window edges.
    public static let gap: CGFloat = 8
    public static let gapRange: ClosedRange<CGFloat> = 0...20
    /// The titlebar strip above already separates the cards from the window
    /// edge, so the top margin is only a hairline gap below it.
    public static let outerTopMargin: CGFloat = 2
    public static let cornerRadius: CGFloat = 10
    public static let borderWidth: CGFloat = 1
    public static let tabPillHeight: CGFloat = 24
    public static let tabPillCornerRadius: CGFloat = 6
}
