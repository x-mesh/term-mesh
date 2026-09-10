
extension SplitDividerOverlayView {
    fileprivate func hiddenAcceptanceVisibleSegmentCount(forceOcclusion: Bool) -> Int {
        guard let window, let rootView = window.contentView else { return 0 }
        var segments: [DividerSegment] = []
        collectDividerSegments(in: rootView, into: &segments)
        var hostedFrames = hostedFramesLikelyToOccludeDividers()
        if forceOcclusion, let segment = segments.first {
            hostedFrames.append(segment.rect.insetBy(dx: -2, dy: -2))
        }
        return segments.filter { shouldRenderOverlay(for: $0, hostedFrames: hostedFrames) }.count
    }
}

@MainActor
func hiddenAcceptanceVisibleDividerSegmentCount(
    in window: NSWindow, forceOcclusion: Bool = false
) -> Int {
    func findOverlay(in view: NSView) -> SplitDividerOverlayView? {
        if let overlay = view as? SplitDividerOverlayView { return overlay }
        for child in view.subviews {
            if let overlay = findOverlay(in: child) { return overlay }
        }
        return nil
    }
    guard let content = window.contentView,
          let root = content.superview,
          let overlay = findOverlay(in: root) else {
        return 0
    }
    return overlay.hiddenAcceptanceVisibleSegmentCount(forceOcclusion: forceOcclusion)
}
