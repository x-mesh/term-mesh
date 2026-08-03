import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif

private var termMeshWindowTerminalPortalKey: UInt8 = 0
private var termMeshWindowTerminalPortalCloseObserverKey: UInt8 = 0

struct TerminalPortalExternalGeometrySnapshot {
    /// Keeps an `ObjectIdentifier` in this snapshot honest.
    ///
    /// Every id here is the address of a view the snapshot does not retain.
    /// Once that view is deallocated the address can be handed to the next
    /// allocation, and during pane churn SwiftUI rebuilds NSViews at the same
    /// size — so a *different* anchor could compare equal on both identity and
    /// frame, and the sync it needed would be skipped as redundant. That is
    /// the failure this whole file exists to avoid: the snapshot agrees while
    /// the pixels are stale.
    ///
    /// Holding the views weakly does not stop address reuse. It does something
    /// better: it tells us the identities we recorded are no longer the ones
    /// we meant, and a snapshot that cannot vouch for its own ids is simply
    /// not equal to anything.
    final class LiveReferences {
        private let boxes: [WeakViewBox]

        init(_ views: [AnyObject?]) {
            boxes = views.compactMap { $0 }.map(WeakViewBox.init)
        }

        var allStillAlive: Bool {
            boxes.allSatisfy { $0.view != nil }
        }

        private final class WeakViewBox {
            weak var view: AnyObject?
            init(_ view: AnyObject) { self.view = view }
        }
    }

    let hostSuperviewID: ObjectIdentifier?
    let hostFrame: NSRect
    let hostBounds: NSRect
    let referenceGeometry: TerminalPortalAnchorGeometry?
    let anchorGeometries: [ObjectIdentifier: TerminalPortalAnchorGeometry]
    /// The views whose addresses the ids above came from.
    let liveReferences: LiveReferences

    func isApproximatelyEqual(
        to other: TerminalPortalExternalGeometrySnapshot,
        epsilon: CGFloat = 0.25
    ) -> Bool {
        // Checked on both sides rather than just the stored one: neither
        // snapshot's ids mean anything once a view behind them is gone.
        guard liveReferences.allStillAlive,
              other.liveReferences.allStillAlive,
              hostSuperviewID == other.hostSuperviewID,
              Self.rectApproximatelyEqual(hostFrame, other.hostFrame, epsilon: epsilon),
              Self.rectApproximatelyEqual(hostBounds, other.hostBounds, epsilon: epsilon),
              Self.optionalGeometryApproximatelyEqual(
                  referenceGeometry,
                  other.referenceGeometry,
                  epsilon: epsilon
              ),
              anchorGeometries.count == other.anchorGeometries.count else {
            return false
        }

        for (anchorID, geometry) in anchorGeometries {
            guard let otherGeometry = other.anchorGeometries[anchorID],
                  geometry.isApproximatelyEqual(to: otherGeometry, epsilon: epsilon) else {
                return false
            }
        }
        return true
    }

    private static func optionalGeometryApproximatelyEqual(
        _ lhs: TerminalPortalAnchorGeometry?,
        _ rhs: TerminalPortalAnchorGeometry?,
        epsilon: CGFloat
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.isApproximatelyEqual(to: rhs, epsilon: epsilon)
        default:
            return false
        }
    }

    private static func rectApproximatelyEqual(
        _ lhs: NSRect,
        _ rhs: NSRect,
        epsilon: CGFloat
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon
            && abs(lhs.origin.y - rhs.origin.y) <= epsilon
            && abs(lhs.size.width - rhs.size.width) <= epsilon
            && abs(lhs.size.height - rhs.size.height) <= epsilon
    }
}

func terminalPortalExternalGeometryNeedsSynchronization(
    previous: TerminalPortalExternalGeometrySnapshot?,
    current: TerminalPortalExternalGeometrySnapshot,
    force: Bool
) -> Bool {
    force || previous?.isApproximatelyEqual(to: current) != true
}

#if DEBUG
private func portalDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

private func portalDebugFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}

private func portalDebugFrameInWindow(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    guard view.window != nil else { return "no-window" }
    return portalDebugFrame(view.convert(view.bounds, to: nil))
}
#endif

final class WindowTerminalHostView: NSView {
    private struct DividerRegion {
        let rectInWindow: NSRect
        let isVertical: Bool
    }

    private enum DividerCursorKind: Equatable {
        case vertical
        case horizontal

        var cursor: NSCursor {
            switch self {
            case .vertical: return .resizeLeftRight
            case .horizontal: return .resizeUpDown
            }
        }
    }

    // Compositor-level z-order: terminal portal (zPosition 100) always renders below browser portal (zPosition 200).
    // CALayer.zPosition survives NSView reordering, layout passes, and deferred portal sync races.
    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.masksToBounds = true
        layer.zPosition = 100
        return layer
    }

    override var isOpaque: Bool { false }
    private static let sidebarLeadingEdgeEpsilon: CGFloat = 1
    private static let minimumVisibleLeadingContentWidth: CGFloat = 24
    private var cachedSidebarDividerX: CGFloat?
    private var sidebarDividerMissCount = 0
    private var trackingArea: NSTrackingArea?
    private var activeDividerCursorKind: DividerCursorKind?
#if DEBUG
    private var lastDragRouteSignature: String?
#endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clearActiveDividerCursor(restoreArrow: false)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let window, let rootView = window.contentView else { return }
        var regions: [DividerRegion] = []
        Self.collectSplitDividerRegions(in: rootView, into: &regions)
        let expansion: CGFloat = 4
        for region in regions {
            var rectInHost = convert(region.rectInWindow, from: nil)
            rectInHost = rectInHost.insetBy(
                dx: region.isVertical ? -expansion : 0,
                dy: region.isVertical ? 0 : -expansion
            )
            let clipped = rectInHost.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            addCursorRect(clipped, cursor: region.isVertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .inVisibleRect,
            .activeAlways,
            .cursorUpdate,
            .mouseMoved,
            .mouseEnteredAndExited,
            .enabledDuringMouseDrag,
        ]
        let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateDividerCursor(at: point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateDividerCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        clearActiveDividerCursor(restoreArrow: true)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        updateDividerCursor(at: point)

        if shouldPassThroughToSidebarResizer(at: point) {
            return nil
        }

        if shouldPassThroughToSplitDivider(at: point) {
            return nil
        }

        let dragPasteboardTypes = NSPasteboard(name: .drag).types
        let eventType = NSApp.currentEvent?.type
        let shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
            pasteboardTypes: dragPasteboardTypes,
            eventType: eventType
        )
        if shouldPassThrough {
#if DEBUG
            logDragRouteDecision(
                passThrough: true,
                eventType: eventType,
                pasteboardTypes: dragPasteboardTypes,
                hitView: nil
            )
#endif
            return nil
        }

        let hitView = super.hitTest(point)
#if DEBUG
        logDragRouteDecision(
            passThrough: false,
            eventType: eventType,
            pasteboardTypes: dragPasteboardTypes,
            hitView: hitView
        )
#endif
        return hitView === self ? nil : hitView
    }

    private func shouldPassThroughToSidebarResizer(at point: NSPoint) -> Bool {
        // The sidebar resizer handle is implemented in SwiftUI. When terminals
        // are portal-hosted, this AppKit host can otherwise sit above the handle
        // and steal hover/mouse events.
        let visibleHostedViews = subviews.compactMap { $0 as? GhosttySurfaceScrollView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }

        // If content is flush to the leading edge, sidebar is effectively hidden.
        // In that state, treating any internal split edge as a sidebar divider
        // steals split-divider cursor/drag behavior.
        let hasLeadingContent = visibleHostedViews.contains {
            $0.frame.minX <= Self.sidebarLeadingEdgeEpsilon
                && $0.frame.maxX > Self.minimumVisibleLeadingContentWidth
        }
        if hasLeadingContent {
            if cachedSidebarDividerX != nil {
                sidebarDividerMissCount += 1
                if sidebarDividerMissCount >= 2 {
                    cachedSidebarDividerX = nil
                    sidebarDividerMissCount = 0
                }
            }
            return false
        }

        // Ignore transient 0-origin hosts while layouts churn (e.g. workspace
        // creation/switching). They can temporarily report minX=0 and would
        // otherwise clear divider pass-through, causing hover flicker.
        let dividerCandidates = visibleHostedViews
            .map(\.frame.minX)
            .filter { $0 > Self.sidebarLeadingEdgeEpsilon }
        if let leftMostEdge = dividerCandidates.min() {
            cachedSidebarDividerX = leftMostEdge
            sidebarDividerMissCount = 0
        } else if cachedSidebarDividerX != nil {
            // Keep cache briefly for layout churn, but clear if we miss repeatedly
            // so stale divider positions don't steal pointer routing.
            sidebarDividerMissCount += 1
            if sidebarDividerMissCount >= 4 {
                cachedSidebarDividerX = nil
                sidebarDividerMissCount = 0
            }
        }

        guard let dividerX = cachedSidebarDividerX else {
            return false
        }

        let regionMinX = dividerX - SidebarResizeInteraction.hitWidthPerSide
        let regionMaxX = dividerX + SidebarResizeInteraction.hitWidthPerSide
        return point.x >= regionMinX && point.x <= regionMaxX
    }

    private func updateDividerCursor(at point: NSPoint) {
        if shouldPassThroughToSidebarResizer(at: point) {
            clearActiveDividerCursor(restoreArrow: false)
            return
        }

        guard let nextKind = splitDividerCursorKind(at: point) else {
            clearActiveDividerCursor(restoreArrow: true)
            return
        }
        activeDividerCursorKind = nextKind
        nextKind.cursor.set()
    }

    private func clearActiveDividerCursor(restoreArrow: Bool) {
        guard activeDividerCursorKind != nil else { return }
        window?.invalidateCursorRects(for: self)
        activeDividerCursorKind = nil
        if restoreArrow {
            NSCursor.arrow.set()
        }
    }

    private func splitDividerCursorKind(at point: NSPoint) -> DividerCursorKind? {
        guard let window else { return nil }
        let windowPoint = convert(point, to: nil)
        guard let rootView = window.contentView else { return nil }
        return Self.dividerCursorKind(at: windowPoint, in: rootView)
    }

    private func shouldPassThroughToSplitDivider(at point: NSPoint) -> Bool {
        splitDividerCursorKind(at: point) != nil
    }

    private static func dividerCursorKind(at windowPoint: NSPoint, in view: NSView) -> DividerCursorKind? {
        guard !view.isHidden else { return nil }

        if let splitView = view as? NSSplitView {
            let pointInSplit = splitView.convert(windowPoint, from: nil)
            if splitView.bounds.contains(pointInSplit) {
                // Keep divider interactions reliable even when portal-hosted terminal frames
                // temporarily overlap divider edges during rapid layout churn.
                let expansion: CGFloat = 5
                let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
                for dividerIndex in 0..<dividerCount {
                    let first = splitView.arrangedSubviews[dividerIndex].frame
                    let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                    let thickness = splitView.dividerThickness
                    let dividerRect: NSRect
                    if splitView.isVertical {
                        // Keep divider hit-testing active even when one side is nearly collapsed,
                        // so users can drag the divider back out from the border.
                        // But ignore transient states where both panes are effectively 0-width.
                        guard first.width > 1 || second.width > 1 else { continue }
                        let x = max(0, first.maxX)
                        dividerRect = NSRect(
                            x: x,
                            y: 0,
                            width: thickness,
                            height: splitView.bounds.height
                        )
                    } else {
                        // Same behavior for horizontal splits with a near-zero-height pane.
                        guard first.height > 1 || second.height > 1 else { continue }
                        let y = max(0, first.maxY)
                        dividerRect = NSRect(
                            x: 0,
                            y: y,
                            width: splitView.bounds.width,
                            height: thickness
                        )
                    }
                    let expandedDividerRect = dividerRect.insetBy(dx: -expansion, dy: -expansion)
                    if expandedDividerRect.contains(pointInSplit) {
                        return splitView.isVertical ? .vertical : .horizontal
                    }
                }
            }
        }

        for subview in view.subviews.reversed() {
            if let kind = dividerCursorKind(at: windowPoint, in: subview) {
                return kind
            }
        }

        return nil
    }

    private static func collectSplitDividerRegions(in view: NSView, into result: inout [DividerRegion]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                let thickness = splitView.dividerThickness
                let dividerRect: NSRect
                if splitView.isVertical {
                    guard first.width > 1 || second.width > 1 else { continue }
                    let x = max(0, first.maxX)
                    dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
                } else {
                    guard first.height > 1 || second.height > 1 else { continue }
                    let y = max(0, first.maxY)
                    dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
                }
                let dividerRectInWindow = splitView.convert(dividerRect, to: nil)
                guard dividerRectInWindow.width > 0, dividerRectInWindow.height > 0 else { continue }
                result.append(
                    DividerRegion(
                        rectInWindow: dividerRectInWindow,
                        isVertical: splitView.isVertical
                    )
                )
            }
        }

        for subview in view.subviews {
            collectSplitDividerRegions(in: subview, into: &result)
        }
    }

#if DEBUG
    private func logDragRouteDecision(
        passThrough: Bool,
        eventType: NSEvent.EventType?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hitView: NSView?
    ) {
        let hasRelevantTypes = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasSidebarTabReorder(pasteboardTypes)
        guard passThrough || hasRelevantTypes else { return }

        let targetClass = hitView.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let signature = [
            passThrough ? "1" : "0",
            debugEventName(eventType),
            debugPasteboardTypes(pasteboardTypes),
            targetClass,
        ].joined(separator: "|")
        guard lastDragRouteSignature != signature else { return }
        lastDragRouteSignature = signature

        dlog(
            "portal.dragRoute passThrough=\(passThrough ? 1 : 0) " +
            "event=\(debugEventName(eventType)) target=\(targetClass) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }

    private func debugPasteboardTypes(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
    }

    private func debugEventName(_ eventType: NSEvent.EventType?) -> String {
        guard let eventType else { return "none" }
        switch eventType {
        case .cursorUpdate: return "cursorUpdate"
        case .appKitDefined: return "appKitDefined"
        case .systemDefined: return "systemDefined"
        case .applicationDefined: return "applicationDefined"
        case .periodic: return "periodic"
        case .mouseMoved: return "mouseMoved"
        case .mouseEntered: return "mouseEntered"
        case .mouseExited: return "mouseExited"
        case .flagsChanged: return "flagsChanged"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDragged: return "otherMouseDragged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        default: return "other(\(eventType.rawValue))"
        }
    }
#endif
}

private final class SplitDividerOverlayView: NSView {
    private struct DividerSegment {
        let rect: NSRect
        let color: NSColor
        let isVertical: Bool
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let window, let rootView = window.contentView else { return }

        var dividerSegments: [DividerSegment] = []
        collectDividerSegments(in: rootView, into: &dividerSegments)
        guard !dividerSegments.isEmpty else { return }
        let hostedFrames = hostedFramesLikelyToOccludeDividers()
        let visibleSegments = dividerSegments.filter { shouldRenderOverlay(for: $0, hostedFrames: hostedFrames) }
        guard !visibleSegments.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Keep separators visible above portal-hosted surfaces while matching each split view's
        // native divider color (avoids visible color shifts at tiny pane sizes).
        for segment in visibleSegments where segment.rect.intersects(dirtyRect) {
            segment.color.setFill()
            let rect = segment.rect
            let pixelAligned = NSRect(
                x: floor(rect.origin.x),
                y: floor(rect.origin.y),
                width: max(1, round(rect.size.width)),
                height: max(1, round(rect.size.height))
            )
            NSBezierPath(rect: pixelAligned).fill()
        }
    }

    private func collectDividerSegments(in view: NSView, into result: inout [DividerSegment]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            let dividerColor = overlayDividerColor(for: splitView)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let thickness = max(splitView.dividerThickness, 1)
                let dividerRectInSplit: NSRect
                if splitView.isVertical {
                    dividerRectInSplit = NSRect(
                        x: first.maxX,
                        y: 0,
                        width: thickness,
                        height: splitView.bounds.height
                    )
                } else {
                    dividerRectInSplit = NSRect(
                        x: 0,
                        y: first.maxY,
                        width: splitView.bounds.width,
                        height: thickness
                    )
                }

                let dividerRectInWindow = splitView.convert(dividerRectInSplit, to: nil)
                let dividerRectInOverlay = convert(dividerRectInWindow, from: nil)
                if dividerRectInOverlay.intersects(bounds) {
                    result.append(
                        DividerSegment(
                            rect: dividerRectInOverlay,
                            color: dividerColor,
                            isVertical: splitView.isVertical
                        )
                    )
                }
            }
        }

        for subview in view.subviews {
            collectDividerSegments(in: subview, into: &result)
        }
    }

    private func hostedFramesLikelyToOccludeDividers() -> [NSRect] {
        guard let hostView = superview else { return [] }
        return hostView.subviews.compactMap { subview -> NSRect? in
            guard let hosted = subview as? GhosttySurfaceScrollView else { return nil }
            guard !hosted.isHidden, hosted.window != nil else { return nil }
            return hosted.frame
        }
    }

    private func shouldRenderOverlay(for segment: DividerSegment, hostedFrames: [NSRect]) -> Bool {
        // Draw only when a hosted surface actually intrudes across the divider centerline.
        // This preserves tiny-pane visibility fixes without darkening regular dividers.
        let axisEpsilon: CGFloat = 0.01
        let axis = segment.isVertical ? segment.rect.midX : segment.rect.midY
        let extentRect = segment.rect.insetBy(
            dx: segment.isVertical ? 0 : -1,
            dy: segment.isVertical ? -1 : 0
        )

        for frame in hostedFrames where frame.intersects(extentRect) {
            if segment.isVertical {
                if frame.minX < axis - axisEpsilon && frame.maxX > axis + axisEpsilon {
                    return true
                }
            } else if frame.minY < axis - axisEpsilon && frame.maxY > axis + axisEpsilon {
                return true
            }
        }
        return false
    }

    private func overlayDividerColor(for splitView: NSSplitView) -> NSColor {
        let divider = splitView.dividerColor.usingColorSpace(.deviceRGB) ?? splitView.dividerColor
        let alpha = divider.alphaComponent
        guard alpha < 0.999 else { return divider }

        guard let bgColor = splitView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
              let bgRGB = bgColor.usingColorSpace(.deviceRGB) else {
            return divider
        }

        let opaqueBG = bgRGB.withAlphaComponent(1)
        let opaqueDivider = divider.withAlphaComponent(1)
        return opaqueBG.blended(withFraction: alpha, of: opaqueDivider) ?? divider
    }
}

@MainActor
final class WindowTerminalPortal: NSObject {
    private static let tinyHideThreshold: CGFloat = 1
    private static let minimumRevealWidth: CGFloat = 24
    private static let minimumRevealHeight: CGFloat = 18

    private weak var window: NSWindow?
    private let hostView = WindowTerminalHostView(frame: .zero)
    private let dividerOverlayView = SplitDividerOverlayView(frame: .zero)
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var installConstraints: [NSLayoutConstraint] = []
    private var hasDeferredFullSyncScheduled = false
    private var hasExternalGeometrySyncScheduled = false
    private var scheduledExternalGeometrySyncIsForced = false
    private var geometrySyncDeferredForSheet = false
    private var deferredSheetGeometrySyncIsForced = false
    private var lastExternalGeometrySnapshot: TerminalPortalExternalGeometrySnapshot?
    private var geometryObservers: [NSObjectProtocol] = []
#if DEBUG
    private var lastLoggedBonsplitContainerSignature: String?
#endif

    private struct Entry {
        weak var hostedView: GhosttySurfaceScrollView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
    }

    private var entriesByHostedId: [ObjectIdentifier: Entry] = [:]
    private var hostedByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]
    /// One observer per anchor, so a SwiftUI layout change reaches the
    /// terminals hosted on top of it. See `observeAnchorGeometry`.
    private var anchorObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    init(window: NSWindow) {
        self.window = window
        super.init()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.layer?.zPosition = 100  // best-effort early set; makeBackingLayer is the reliable path
        hostView.postsFrameChangedNotifications = true
        hostView.postsBoundsChangedNotifications = true
        hostView.translatesAutoresizingMaskIntoConstraints = false
        dividerOverlayView.translatesAutoresizingMaskIntoConstraints = true
        dividerOverlayView.autoresizingMask = [.width, .height]
        installGeometryObservers(for: window)
        _ = ensureInstalled()
    }

    private func installGeometryObservers(for window: NSWindow) {
        guard geometryObservers.isEmpty else { return }

        let center = NotificationCenter.default
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize(force: true)
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didEndSheetNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.geometrySyncDeferredForSheet else { return }
                let force = self.deferredSheetGeometrySyncIsForced
                self.geometrySyncDeferredForSheet = false
                self.deferredSheetGeometrySyncIsForced = false
                self.scheduleExternalGeometrySynchronize(force: force)
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window,
                      splitView.window === window else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
    }

    /// Follow the SwiftUI view a terminal is pinned to.
    ///
    /// The portal's own reference is the window's content view, so its host
    /// frame only changes when the window does. Everything inside is placed
    /// from each entry's anchor — and the anchors move for reasons the window
    /// never hears about: a side panel opening, a sidebar widening, any
    /// SwiftUI relayout at a fixed window size. Nothing was watching them, so
    /// the hosted terminals stayed at their old frames and were left sitting
    /// over whatever had taken their space.
    ///
    /// Cheap to keep: one observer per anchor, dropped when the entry goes,
    /// and the sync it triggers is already coalesced to one pass per runloop
    /// turn by `scheduleExternalGeometrySynchronize`.
    private func observeAnchorGeometry(_ anchorView: NSView, id anchorId: ObjectIdentifier) {
        guard anchorObservers[anchorId] == nil else { return }
        anchorView.postsFrameChangedNotifications = true
        anchorObservers[anchorId] = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: anchorView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        }
    }

    private func stopObservingAnchor(id anchorId: ObjectIdentifier) {
        guard let observer = anchorObservers.removeValue(forKey: anchorId) else { return }
        NotificationCenter.default.removeObserver(observer)
    }

    private func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
        for observer in anchorObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        anchorObservers.removeAll()
    }

    private func scheduleExternalGeometrySynchronize(
        after delay: TimeInterval = 0,
        force: Bool = false
    ) {
        scheduledExternalGeometrySyncIsForced =
            scheduledExternalGeometrySyncIsForced || force
        guard !hasExternalGeometrySyncScheduled else { return }
        hasExternalGeometrySyncScheduled = true
        let work = { [weak self] in
            guard let self else { return }
            self.hasExternalGeometrySyncScheduled = false
            let isForced = self.scheduledExternalGeometrySyncIsForced
            self.scheduledExternalGeometrySyncIsForced = false
            self.synchronizeAllEntriesFromExternalGeometryChange(force: isForced)
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func synchronizeLayoutHierarchy() {
        // Limit layout to the portal host subtree only. Forcing layoutSubtreeIfNeeded()
        // on installedContainerView (window themeFrame) or installedReferenceView
        // (contentView) triggers a full-window AutoLayout/NSISEngine pass that can
        // compete with NSSheet animations and cause 2 s+ main-thread hangs (TERM-MESH-2).
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        _ = synchronizeHostFrameToReference()
    }

    @discardableResult
    private func synchronizeHostFrameToReference() -> Bool {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return false
        }
        let frameInContainer = container.convert(reference.bounds, from: reference)
        let hasFiniteFrame =
            frameInContainer.origin.x.isFinite &&
            frameInContainer.origin.y.isFinite &&
            frameInContainer.size.width.isFinite &&
            frameInContainer.size.height.isFinite
        guard hasFiniteFrame else { return false }

        if !Self.rectApproximatelyEqual(hostView.frame, frameInContainer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostView.frame = frameInContainer
            CATransaction.commit()
#if DEBUG
            dlog(
                "portal.hostFrame.update host=\(portalDebugToken(hostView)) " +
                "frame=\(portalDebugFrame(frameInContainer))"
            )
#endif
        }
        return frameInContainer.width > 1 && frameInContainer.height > 1
    }

    private func synchronizeAllEntriesFromExternalGeometryChange(force: Bool) {
        // Defer geometry sync while a sheet is animating. NSSheetMoveHelper fires window
        // resize notifications during its animation frames; running layoutSubtreeIfNeeded()
        // and _setWindow: propagation concurrently with the sheet's constraint engine causes
        // 2 s+ main-thread hangs (TERM-MESH-2, getMethodNoSuper_nolock pattern).
        if let window = self.window, window.attachedSheet != nil {
            let wasAlreadyDeferred = geometrySyncDeferredForSheet
            geometrySyncDeferredForSheet = true
            deferredSheetGeometrySyncIsForced = deferredSheetGeometrySyncIsForced || force
#if DEBUG
            if !wasAlreadyDeferred {
                dlog("portal.sync.deferSheet reason=attachedSheetActive")
            }
#endif
            return
        }
        let beforeLayout = externalGeometrySnapshot()
        guard terminalPortalExternalGeometryNeedsSynchronization(
            previous: lastExternalGeometrySnapshot,
            current: beforeLayout,
            force: force
        ) else {
            return
        }
        // Record the event geometry before forcing AppKit layout. Notifications
        // emitted by our own pass are queued for the next runloop turn; the
        // post-layout snapshot below makes those self-induced callbacks no-ops
        // once geometry has converged.
        lastExternalGeometrySnapshot = beforeLayout
        guard ensureInstalled() else {
            // Installation can be transiently unavailable while AppKit swaps
            // the content hierarchy. Do not let that failed attempt suppress
            // the next notification carrying the same geometry.
            lastExternalGeometrySnapshot = nil
            return
        }
        synchronizeAllHostedViews(excluding: nil)

        // During live resize, AppKit can deliver frame churn where host/container geometry
        // settles a tick before the terminal's own scroll/surface hierarchy. Force a final
        // in-place geometry + surface refresh once at the explicit final pass.
        // Ordinary anchor notifications already refresh inside synchronizeHostedView
        // when the applied frame actually changes; forcing every notification made
        // scrolling compete with redundant renderer wakeups.
        if force {
            for entry in entriesByHostedId.values {
                guard let hostedView = entry.hostedView, !hostedView.isHidden else { continue }
                hostedView.reconcileGeometryNow()
                hostedView.refreshSurfaceNow()
            }
        }
        lastExternalGeometrySnapshot = externalGeometrySnapshot()
    }

    private func externalGeometrySnapshot() -> TerminalPortalExternalGeometrySnapshot {
        let referenceGeometry = installedReferenceView.map { view in
            TerminalPortalAnchorGeometry(
                windowID: view.window.map(ObjectIdentifier.init),
                superviewID: view.superview.map(ObjectIdentifier.init),
                frameInWindow: view.convert(view.bounds, to: nil)
            )
        }
        var anchors: [ObjectIdentifier: TerminalPortalAnchorGeometry] = [:]
        // Every view an id was taken from, so the snapshot can later say
        // whether those ids still refer to what it meant.
        var identified: [AnyObject?] = [
            hostView.superview,
            installedReferenceView,
            installedReferenceView?.superview,
        ]
        for entry in entriesByHostedId.values {
            guard let anchor = entry.anchorView else { continue }
            anchors[ObjectIdentifier(anchor)] = TerminalPortalAnchorGeometry(
                windowID: anchor.window.map(ObjectIdentifier.init),
                superviewID: anchor.superview.map(ObjectIdentifier.init),
                frameInWindow: anchor.convert(anchor.bounds, to: nil)
            )
            identified.append(anchor)
            identified.append(anchor.superview)
        }
        return TerminalPortalExternalGeometrySnapshot(
            hostSuperviewID: hostView.superview.map(ObjectIdentifier.init),
            hostFrame: hostView.frame,
            hostBounds: hostView.bounds,
            referenceGeometry: referenceGeometry,
            anchorGeometries: anchors,
            liveReferences: .init(identified)
        )
    }

    private func ensureDividerOverlayOnTop() {
        if dividerOverlayView.superview !== hostView {
            dividerOverlayView.frame = hostView.bounds
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        } else if hostView.subviews.last !== dividerOverlayView {
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        }

        if !Self.rectApproximatelyEqual(dividerOverlayView.frame, hostView.bounds) {
            dividerOverlayView.frame = hostView.bounds
        }
        dividerOverlayView.needsDisplay = true
    }

    @discardableResult
    private func ensureInstalled(forceLayout: Bool = true) -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installationTarget(for: window) else { return false }
        var installationChanged = false

        if hostView.superview !== container || installedContainerView !== container {
            // Container changed (or host view is not yet installed): full re-insertion.
            // This triggers -[NSView _setWindow:] propagation, so only do it when necessary.
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()

            hostView.removeFromSuperview()
            container.addSubview(hostView, positioned: .above, relativeTo: reference)

            installConstraints = [
                hostView.leadingAnchor.constraint(equalTo: reference.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: reference.trailingAnchor),
                hostView.topAnchor.constraint(equalTo: reference.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: reference.bottomAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainerView = container
            installedReferenceView = reference
            installationChanged = true
        } else if installedReferenceView !== reference {
            // Container is unchanged but reference view changed (e.g. NSGlassEffectView
            // child swap on theme change). Update constraints without removing the host view
            // to avoid spurious _setWindow: propagation across all portal-hosted terminals.
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints = [
                hostView.leadingAnchor.constraint(equalTo: reference.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: reference.trailingAnchor),
                hostView.topAnchor.constraint(equalTo: reference.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: reference.bottomAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedReferenceView = reference
            installationChanged = true
        } else if !Self.isView(hostView, above: reference, in: container) {
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
            installationChanged = true
        }

        // Z-order contract: terminal portal must render below browser portal.
        // This mirrors the enforcement in BrowserWindowPortal.ensureInstalled().
        if let browserHost = container.subviews.first(where: { $0 is WindowBrowserHostView }),
           Self.isView(hostView, above: browserHost, in: container) {
            container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            installationChanged = true
        }

        // The command palette installs into this same container with `.above`,
        // so the last of the two to run wins — and a portal sync runs many
        // times a second. Opening the palette over a terminal therefore buried
        // it behind that terminal within a frame or two, leaving only the strip
        // that happened to fall between two panes visible.
        if let palette = container.subviews.first(where: { $0 is CommandPaletteOverlayContainerView }),
           !Self.isView(palette, above: hostView, in: container) {
            container.addSubview(palette, positioned: .above, relativeTo: hostView)
            installationChanged = true
        }

        // Keep the drag/mouse forwarding overlay above portal-hosted terminal views.
        if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView,
           overlay.superview === container,
           !Self.isView(overlay, above: hostView, in: container) {
            container.addSubview(overlay, positioned: .above, relativeTo: hostView)
            installationChanged = true
        }
        // Ensure file drop overlay renders above both portal hosts at compositor level.
        if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView,
           overlay.superview === container {
            overlay.wantsLayer = true
            overlay.layer?.zPosition = 300
        }

        // A steady-state SwiftUI representable update already runs inside AppKit's
        // layout pass. Re-entering layoutSubtreeIfNeeded() from every bind walks the
        // whole hosting hierarchy again during workspace switches. Installation and
        // z-order mutations still need an immediate pass; geometry-driven callers keep
        // the default forceLayout=true so resize/sidebar changes retain their contract.
        if forceLayout || installationChanged {
            synchronizeLayoutHierarchy()
        } else {
            _ = synchronizeHostFrameToReference()
        }
        ensureDividerOverlayOnTop()

        return true
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let contentView = window.contentView else { return nil }

        // If NSGlassEffectView wraps the original content view, install inside the glass view
        // so terminals are above the glass background but below SwiftUI content.
        if contentView.className == "NSGlassEffectView",
           let foreground = contentView.subviews.first(where: { $0 !== hostView }) {
            return (contentView, foreground)
        }

        guard let themeFrame = contentView.superview else { return nil }
        return (themeFrame, contentView)
    }

    private static func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        var current = view.superview
        while let v = current {
            if v.isHidden { return true }
            current = v.superview
        }
        return false
    }

    private static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    private static func pixelSnappedRect(_ rect: NSRect, in view: NSView) -> NSRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return rect
        }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return NSRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: max(0, snap(rect.size.width)),
            height: max(0, snap(rect.size.height))
        )
    }

    private static func isView(_ view: NSView, above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: view),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

#if DEBUG
    private func nearestBonsplitContainer(from anchorView: NSView) -> NSView? {
        var current: NSView? = anchorView
        while let view = current {
            let className = NSStringFromClass(type(of: view))
            if className.contains("PaneDragContainerView") || className.contains("Bonsplit") {
                return view
            }
            current = view.superview
        }
        return installedReferenceView
    }

    private func logBonsplitContainerFrameIfNeeded(anchorView: NSView, hostedView: GhosttySurfaceScrollView) {
        guard let container = nearestBonsplitContainer(from: anchorView) else { return }
        let containerFrame = container.convert(container.bounds, to: nil)
        let signature = "\(ObjectIdentifier(container)):\(portalDebugFrame(containerFrame))"
        guard signature != lastLoggedBonsplitContainerSignature else { return }
        lastLoggedBonsplitContainerSignature = signature

        let containerClass = NSStringFromClass(type(of: container))
        dlog(
            "portal.bonsplit.container hosted=\(portalDebugToken(hostedView)) " +
            "class=\(containerClass) frame=\(portalDebugFrame(containerFrame)) " +
            "host=\(portalDebugFrameInWindow(hostView)) anchor=\(portalDebugFrameInWindow(anchorView))"
        )
    }
#endif

    /// Convert an anchor view's bounds to window coordinates while honoring ancestor clipping.
    /// SwiftUI/AppKit hosting layers can report an anchor bounds wider than its split pane when
    /// intrinsic-size content overflows; intersecting through ancestor bounds gives the effective
    /// visible rect that should drive portal geometry.
    private func effectiveAnchorFrameInWindow(for anchorView: NSView) -> NSRect {
        var frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        var current = anchorView.superview
        while let ancestor = current {
            let ancestorBoundsInWindow = ancestor.convert(ancestor.bounds, to: nil)
            let finiteAncestorBounds =
                ancestorBoundsInWindow.origin.x.isFinite &&
                ancestorBoundsInWindow.origin.y.isFinite &&
                ancestorBoundsInWindow.size.width.isFinite &&
                ancestorBoundsInWindow.size.height.isFinite
            if finiteAncestorBounds {
                frameInWindow = frameInWindow.intersection(ancestorBoundsInWindow)
                if frameInWindow.isNull { return .zero }
            }
            if ancestor === installedReferenceView { break }
            current = ancestor.superview
        }
        return frameInWindow
    }

    private func seededFrameInHost(for anchorView: NSView) -> NSRect? {
        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        guard hasFiniteFrame else { return nil }

        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        if hasFiniteHostBounds {
            let clampedFrame = frameInHost.intersection(hostBounds)
            if !clampedFrame.isNull, clampedFrame.width > 1, clampedFrame.height > 1 {
                return clampedFrame
            }
        }

        return frameInHost
    }

    func detachHostedView(withId hostedId: ObjectIdentifier) {
        guard let entry = entriesByHostedId.removeValue(forKey: hostedId) else { return }
        if let anchor = entry.anchorView {
            let anchorId = ObjectIdentifier(anchor)
            hostedByAnchorId.removeValue(forKey: anchorId)
            stopObservingAnchor(id: anchorId)
        }
#if DEBUG
        let hadSuperview = (entry.hostedView?.superview === hostView) ? 1 : 0
        dlog(
            "portal.detach hosted=\(portalDebugToken(entry.hostedView)) " +
            "anchor=\(portalDebugToken(entry.anchorView)) hadSuperview=\(hadSuperview)"
        )
#endif
        if let hostedView = entry.hostedView, hostedView.superview === hostView {
            hostedView.removeFromSuperview()
        }
        updateHostViewVisibility()
    }

    /// Hide a portal entry without detaching it. Updates visibleInUI to false and
    /// sets isHidden = true so subsequent synchronizeHostedView calls keep it hidden.
    /// Used when a workspace is permanently unmounted (vs. transient bonsplit dismantles).
    func hideEntry(forHostedId hostedId: ObjectIdentifier) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        guard entry.visibleInUI else { return }
        entry.visibleInUI = false
        entriesByHostedId[hostedId] = entry
        entry.hostedView?.isHidden = true
#if DEBUG
        dlog("portal.hideEntry hosted=\(portalDebugToken(entry.hostedView)) reason=workspaceUnmount")
#endif
        updateHostViewVisibility()
    }

    /// Update the visibleInUI flag on an existing entry without rebinding.
    /// Used when a deferred bind is pending — this ensures synchronizeHostedView
    /// won't hide a view that updateNSView has already marked as visible.
    /// When setting to false, also immediately hides the hosted view and updates
    /// host visibility to remove Metal/IOSurface content from the compositor.
    func updateEntryVisibility(forHostedId hostedId: ObjectIdentifier, visibleInUI: Bool) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        entry.visibleInUI = visibleInUI
        entriesByHostedId[hostedId] = entry

        // When marking invisible, immediately hide the view so the Metal surface
        // stops compositing. Safe for transient SwiftUI dismantles because the
        // subsequent bind() in the same run loop will unhide before display.
        if !visibleInUI {
            entry.hostedView?.isHidden = true
#if DEBUG
            dlog("portal.hideEntry hosted=\(portalDebugToken(entry.hostedView)) reason=visibilityUpdate")
#endif
            updateHostViewVisibility()
        }
    }

    func bind(hostedView: GhosttySurfaceScrollView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard ensureInstalled(forceLayout: false) else { return }

        // Unhide host view before adding content so the first frame renders correctly.
        if hostView.isHidden {
            hostView.isHidden = false
#if DEBUG
            dlog("portal.hostView.hidden value=0 reason=bind")
#endif
        }

        let hostedId = ObjectIdentifier(hostedView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByHostedId[hostedId]

        if let previousHostedId = hostedByAnchorId[anchorId], previousHostedId != hostedId {
#if DEBUG
            let previousToken = entriesByHostedId[previousHostedId]
                .map { portalDebugToken($0.hostedView) }
                ?? String(describing: previousHostedId)
            dlog(
                "portal.bind.replace anchor=\(portalDebugToken(anchorView)) " +
                "oldHosted=\(previousToken) newHosted=\(portalDebugToken(hostedView))"
            )
#endif
            detachHostedView(withId: previousHostedId)
        }

        if let oldEntry = entriesByHostedId[hostedId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            let oldAnchorId = ObjectIdentifier(oldAnchor)
            hostedByAnchorId.removeValue(forKey: oldAnchorId)
            stopObservingAnchor(id: oldAnchorId)
        }

        hostedByAnchorId[anchorId] = hostedId
        entriesByHostedId[hostedId] = Entry(
            hostedView: hostedView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)
#if DEBUG
        if previousEntry == nil || didChangeAnchor || becameVisible || priorityIncreased || hostedView.superview !== hostView {
            dlog(
                "portal.bind hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) prevAnchor=\(portalDebugToken(previousEntry?.anchorView)) " +
                "visible=\(visibleInUI ? 1 : 0) prevVisible=\((previousEntry?.visibleInUI ?? false) ? 1 : 0) " +
                "z=\(zPriority) prevZ=\(previousEntry?.zPriority ?? Int.min)"
            )
        }
#endif

        observeAnchorGeometry(anchorView, id: anchorId)
        _ = synchronizeHostFrameToReference()

        // Seed frame/bounds before entering the window so a freshly reparented
        // surface doesn't do a transient 800x600 size update on viewDidMoveToWindow.
        if let seededFrame = seededFrameInHost(for: anchorView),
           seededFrame.width > 0,
           seededFrame.height > 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = seededFrame
            hostedView.bounds = NSRect(origin: .zero, size: seededFrame.size)
            CATransaction.commit()
        } else {
            // If anchor geometry is still unsettled, keep this hidden/zero-sized until
            // synchronizeHostedView resolves a valid target frame on the next layout tick.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = .zero
            hostedView.bounds = .zero
            CATransaction.commit()
            hostedView.isHidden = true
        }
        // Keep inner scroll/surface geometry in sync with the seeded outer frame
        // before the hosted view enters a window.
        hostedView.reconcileGeometryNow()

        if hostedView.superview !== hostView {
#if DEBUG
            dlog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) " +
                "reason=attach super=\(portalDebugToken(hostedView.superview))"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        } else if (becameVisible || priorityIncreased), hostView.subviews.last !== hostedView {
            // Refresh z-order only when a view becomes visible or gets a higher priority.
            // Anchor-only churn is common during split tree updates; forcing remove/add there
            // causes transient inWindow=0 -> 1 bounces that can flash black.
#if DEBUG
            dlog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) reason=raise " +
                "didChangeAnchor=\(didChangeAnchor ? 1 : 0) becameVisible=\(becameVisible ? 1 : 0) " +
                "priorityIncreased=\(priorityIncreased ? 1 : 0)"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        }

        ensureDividerOverlayOnTop()

        synchronizeHostedView(withId: hostedId, installationPrepared: true)
        scheduleDeferredFullSynchronizeAll()
        pruneDeadEntries()
    }

    func synchronizeHostedViewForAnchor(_ anchorView: NSView) {
        guard ensureInstalled() else { return }
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryHostedId = hostedByAnchorId[anchorId]
        if let primaryHostedId {
            synchronizeHostedView(withId: primaryHostedId, installationPrepared: true)
        }

        // Failsafe: during aggressive divider drags/structural churn, one anchor can miss a
        // geometry callback while another fires. Reconcile all mapped hosted views once on the
        // next runloop turn. Do not also synchronize the remaining entries synchronously here:
        // every anchor callback would otherwise walk the whole portal twice, and workspace
        // switches commonly deliver one callback per terminal in the same turn.
        scheduleDeferredFullSynchronizeAll()
    }

    private func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
            self.synchronizeAllHostedViews(excluding: nil)
        }
    }

    private func synchronizeAllHostedViews(
        excluding hostedIdToSkip: ObjectIdentifier?,
        installationPrepared: Bool = false
    ) {
        if !installationPrepared {
            guard ensureInstalled() else { return }
        }
        pruneDeadEntries()
        let hostedIds = Array(entriesByHostedId.keys)
        for hostedId in hostedIds {
            if hostedId == hostedIdToSkip { continue }
            synchronizeHostedView(withId: hostedId, installationPrepared: true)
        }
        updateHostViewVisibility()
    }

    private func synchronizeHostedView(
        withId hostedId: ObjectIdentifier,
        installationPrepared: Bool = false
    ) {
        if !installationPrepared {
            guard ensureInstalled() else { return }
        }
        guard let entry = entriesByHostedId[hostedId] else { return }
        guard let hostedView = entry.hostedView else {
            entriesByHostedId.removeValue(forKey: hostedId)
            return
        }
        guard let anchorView = entry.anchorView, let window else {
            // Only hide if the entry is not marked visibleInUI. When a workspace is
            // remounting, updateNSView sets visibleInUI=true before the deferred bind
            // provides an anchor — hiding here would race with that and cause a flash.
            if !entry.visibleInUI {
#if DEBUG
                if !hostedView.isHidden {
                    dlog("portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 reason=missingAnchorOrWindow")
                }
#endif
                hostedView.isHidden = true
            }
            return
        }
        guard anchorView.window === window else {
#if DEBUG
            if !hostedView.isHidden {
                dlog(
                    "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(portalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            hostedView.isHidden = true
            return
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
#if DEBUG
        logBonsplitContainerFrameIfNeeded(anchorView: anchorView, hostedView: hostedView)
#endif
        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        let hostBoundsReady = hasFiniteHostBounds && hostBounds.width > 1 && hostBounds.height > 1
        if !hostBoundsReady {
#if DEBUG
            dlog(
                "portal.sync.defer hosted=\(portalDebugToken(hostedView)) " +
                "reason=hostBoundsNotReady host=\(portalDebugFrame(hostBounds)) " +
                "anchor=\(portalDebugFrame(frameInHost)) visibleInUI=\(entry.visibleInUI ? 1 : 0)"
            )
#endif
            hostedView.isHidden = true
            scheduleDeferredFullSynchronizeAll()
            return
        }
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        let clampedFrame = frameInHost.intersection(hostBounds)
        let hasVisibleIntersection =
            !clampedFrame.isNull &&
            clampedFrame.width > 1 &&
            clampedFrame.height > 1
        let targetFrame = (hasFiniteFrame && hasVisibleIntersection) ? clampedFrame : frameInHost
        let anchorHidden = Self.isHiddenOrAncestorHidden(anchorView)
        let tinyFrame =
            targetFrame.width <= Self.tinyHideThreshold ||
            targetFrame.height <= Self.tinyHideThreshold
        let revealReadyForDisplay =
            targetFrame.width >= Self.minimumRevealWidth &&
            targetFrame.height >= Self.minimumRevealHeight
        let outsideHostBounds = !hasVisibleIntersection
        let shouldHide =
            !entry.visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        let shouldDeferReveal = !shouldHide && hostedView.isHidden && !revealReadyForDisplay

        let oldFrame = hostedView.frame
        let wasHidden = hostedView.isHidden
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !Self.rectApproximatelyEqual(frameInHost, targetFrame)
        if frameWasClamped {
            dlog(
                "portal.frame.clamp hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) " +
                "raw=\(portalDebugFrame(frameInHost)) clamped=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
        }
        let collapsedToTiny = oldFrame.width > 1 && oldFrame.height > 1 && tinyFrame
        let restoredFromTiny = (oldFrame.width <= 1 || oldFrame.height <= 1) && !tinyFrame
        if collapsedToTiny {
            dlog(
                "portal.frame.collapse hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        } else if restoredFromTiny {
            dlog(
                "portal.frame.restore hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        }
#endif

        // Hide before updating the frame when this entry should not be visible.
        // This avoids a one-frame flash of unrendered terminal background when a portal
        // briefly transitions through offscreen/tiny geometry during rapid split churn.
        if shouldHide, !hostedView.isHidden {
#if DEBUG
            dlog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = true
        }

        if hasFiniteFrame && !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = targetFrame
            CATransaction.commit()
            hostedView.reconcileGeometryNow()
            hostedView.refreshSurfaceNow()
        }

        if hasFiniteFrame {
            let expectedBounds = NSRect(origin: .zero, size: targetFrame.size)
            if !Self.rectApproximatelyEqual(hostedView.bounds, expectedBounds) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hostedView.bounds = expectedBounds
                CATransaction.commit()
            }
        }

        if shouldDeferReveal {
#if DEBUG
            if !Self.rectApproximatelyEqual(oldFrame, frameInHost) {
                dlog(
                    "portal.hidden.deferReveal hosted=\(portalDebugToken(hostedView)) " +
                    "frame=\(portalDebugFrame(frameInHost)) min=\(Int(Self.minimumRevealWidth))x\(Int(Self.minimumRevealHeight))"
                )
            }
#endif
        }

        if !shouldHide, hostedView.isHidden, revealReadyForDisplay {
#if DEBUG
            dlog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=0 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = false
        }

#if DEBUG
        if !Self.rectApproximatelyEqual(oldFrame, hostedView.frame) || wasHidden != hostedView.isHidden {
            dlog(
                "portal.sync.result hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) host=\(portalDebugToken(hostView)) " +
                "hostWin=\(hostView.window?.windowNumber ?? -1) " +
                "old=\(portalDebugFrame(oldFrame)) raw=\(portalDebugFrame(frameInHost)) " +
                "target=\(portalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
                "entryVisible=\(entry.visibleInUI ? 1 : 0) hostedHidden=\(hostedView.isHidden ? 1 : 0) " +
                "hostBounds=\(portalDebugFrame(hostBounds))"
            )
        }
#endif

        ensureDividerOverlayOnTop()
    }

    /// Hide/unhide the entire host view based on whether any entry is currently visible.
    /// When all entries are hidden (e.g. during browser pane zoom), this removes the host
    /// from the macOS compositor pipeline — the only reliable way to prevent Metal/IOSurface
    /// content from painting over sibling views regardless of zPosition.
    private func updateHostViewVisibility() {
        let hasAnyVisibleEntry = entriesByHostedId.values.contains { entry in
            guard let hostedView = entry.hostedView else { return false }
            return !hostedView.isHidden
        }

        if hostView.isHidden == hasAnyVisibleEntry {
            hostView.isHidden = !hasAnyVisibleEntry
#if DEBUG
            dlog("portal.hostView.hidden value=\(hostView.isHidden ? 1 : 0) visibleEntries=\(hasAnyVisibleEntry ? 1 : 0)")
#endif
        }
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadHostedIds = entriesByHostedId.compactMap { hostedId, entry -> ObjectIdentifier? in
            guard entry.hostedView != nil else { return hostedId }
            guard let anchor = entry.anchorView else { return hostedId }
            if anchor.window !== currentWindow || anchor.superview == nil {
                return hostedId
            }
            if let reference = installedReferenceView,
               !anchor.isDescendant(of: reference) {
                return hostedId
            }
            return nil
        }

        for hostedId in deadHostedIds {
            detachHostedView(withId: hostedId)
        }

        let validAnchorIds = Set(entriesByHostedId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        hostedByAnchorId = hostedByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

    func hostedIds() -> Set<ObjectIdentifier> {
        Set(entriesByHostedId.keys)
    }

    func tearDown() {
        removeGeometryObservers()
        for hostedId in Array(entriesByHostedId.keys) {
            detachHostedView(withId: hostedId)
        }
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

#if DEBUG
    func debugEntryCount() -> Int {
        entriesByHostedId.count
    }

    func debugHostedSubviewCount() -> Int {
        // Hosted surfaces only. hostView also carries the split-divider
        // overlay, so a raw subview count reads one higher than the number of
        // terminals — which made a correct prune look like a leaked view.
        hostView.subviews.filter { !($0 is SplitDividerOverlayView) }.count
    }
#endif

    func viewAtWindowPoint(_ windowPoint: NSPoint) -> NSView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        // Restrict hit-testing to currently mapped entries so stale detached views
        // can't steal file-drop/mouse routing.
        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView else { continue }
            let hostedId = ObjectIdentifier(hostedView)
            guard entriesByHostedId[hostedId] != nil else { continue }
            guard !hostedView.isHidden else { continue }
            guard hostedView.frame.contains(point) else { continue }
            let localPoint = hostedView.convert(point, from: hostView)
            return hostedView.hitTest(localPoint) ?? hostedView
        }

        return nil
    }

    func terminalViewAtWindowPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView else { continue }
            let hostedId = ObjectIdentifier(hostedView)
            guard entriesByHostedId[hostedId] != nil else { continue }
            guard !hostedView.isHidden else { continue }
            guard hostedView.frame.contains(point) else { continue }
            let localPoint = hostedView.convert(point, from: hostView)
            if let terminal = hostedView.terminalViewForDrop(at: localPoint) {
                return terminal
            }
        }

        return nil
    }
}

@MainActor
enum TerminalWindowPortalRegistry {
    private static var portalsByWindowId: [ObjectIdentifier: WindowTerminalPortal] = [:]
    private static var hostedToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]

    private static func installWindowCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &termMeshWindowTerminalPortalCloseObserverKey) == nil else { return }
        let windowId = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    removePortal(for: window)
                } else {
                    removePortal(windowId: windowId, window: nil)
                }
            }
        }
        objc_setAssociatedObject(
            window,
            &termMeshWindowTerminalPortalCloseObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func removePortal(for window: NSWindow) {
        removePortal(windowId: ObjectIdentifier(window), window: window)
    }

    private static func removePortal(windowId: ObjectIdentifier, window: NSWindow?) {
        if let portal = portalsByWindowId.removeValue(forKey: windowId) {
            portal.tearDown()
        }
        hostedToWindowId = hostedToWindowId.filter { $0.value != windowId }

        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &termMeshWindowTerminalPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &termMeshWindowTerminalPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &termMeshWindowTerminalPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func pruneHostedMappings(for windowId: ObjectIdentifier, validHostedIds: Set<ObjectIdentifier>) {
        hostedToWindowId = hostedToWindowId.filter { hostedId, mappedWindowId in
            mappedWindowId != windowId || validHostedIds.contains(hostedId)
        }
    }

    private static func portal(for window: NSWindow) -> WindowTerminalPortal {
        if let existing = objc_getAssociatedObject(window, &termMeshWindowTerminalPortalKey) as? WindowTerminalPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }

        let portal = WindowTerminalPortal(window: window)
        objc_setAssociatedObject(window, &termMeshWindowTerminalPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installWindowCloseObserverIfNeeded(for: window)
        return portal
    }

    static func bind(hostedView: GhosttySurfaceScrollView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard let window = anchorView.window else { return }

        let windowId = ObjectIdentifier(window)
        let hostedId = ObjectIdentifier(hostedView)
        let nextPortal = portal(for: window)

        if let oldWindowId = hostedToWindowId[hostedId],
           oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detachHostedView(withId: hostedId)
        }

        nextPortal.bind(hostedView: hostedView, to: anchorView, visibleInUI: visibleInUI, zPriority: zPriority)
        hostedToWindowId[hostedId] = windowId
        pruneHostedMappings(for: windowId, validHostedIds: nextPortal.hostedIds())
    }

    static func synchronizeForAnchor(_ anchorView: NSView) {
        guard let window = anchorView.window else { return }
        let portal = portal(for: window)
        portal.synchronizeHostedViewForAnchor(anchorView)
    }

    static func hideHostedView(_ hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.hideEntry(forHostedId: hostedId)
    }

    /// Update the visibleInUI flag on an existing portal entry without rebinding.
    /// Called when a bind is deferred (host not yet in window) to prevent stale
    /// portal syncs from hiding a view that is about to become visible.
    static func updateEntryVisibility(for hostedView: GhosttySurfaceScrollView, visibleInUI: Bool) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateEntryVisibility(forHostedId: hostedId, visibleInUI: visibleInUI)
    }

    static func viewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> NSView? {
        let portal = portal(for: window)
        return portal.viewAtWindowPoint(windowPoint)
    }

    static func terminalViewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> GhosttyNSView? {
        let portal = portal(for: window)
        return portal.terminalViewAtWindowPoint(windowPoint)
    }

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }
#endif
}
