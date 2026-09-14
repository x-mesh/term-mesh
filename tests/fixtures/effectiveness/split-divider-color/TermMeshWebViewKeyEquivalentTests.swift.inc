
@MainActor
final class HiddenSplitDividerPortalAcceptanceTests: XCTestCase {
    private let canvasColor = NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.25, alpha: 1)
    private let opaqueDividerColor = NSColor(calibratedRed: 0.88, green: 0.25, blue: 0.98, alpha: 1)
    private let nativeSentinelColor = NSColor(calibratedRed: 0.95, green: 0.50, blue: 0.08, alpha: 1)
    private let surfaceSentinelColor = NSColor(calibratedRed: 0.04, green: 0.48, blue: 0.21, alpha: 1)
    private let translucentAlpha: CGFloat = 0.36

    private final class DividerSplitView: NSSplitView {
        let acceptanceDividerColor: NSColor

        init(dividerColor: NSColor) {
            acceptanceDividerColor = dividerColor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }
        override var dividerColor: NSColor { acceptanceDividerColor }
    }

    private struct RenderedPortal {
        let window: NSWindow
        let dividerPoint: NSPoint
        let controlPoint: NSPoint
        let bitmap: NSBitmapImageRep
        let captureBounds: NSRect
    }

    private func makeRenderedPortal(
        dividerColor: NSColor,
        surfaceFrame: NSRect,
        nativeDividerSentinelColor: NSColor? = nil
    ) throws -> RenderedPortal {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = canvasColor
        let content = try XCTUnwrap(window.contentView)
        content.wantsLayer = true
        content.layer?.backgroundColor = canvasColor.cgColor
        let split = DividerSplitView(dividerColor: dividerColor)
        split.frame = content.bounds
        split.isVertical = true
        split.dividerStyle = .thin
        split.wantsLayer = true
        split.layer?.backgroundColor = canvasColor.cgColor
        for _ in 0..<2 {
            let pane = NSView(frame: .zero)
            pane.wantsLayer = true
            pane.layer?.backgroundColor = canvasColor.cgColor
            split.addArrangedSubview(pane)
        }
        content.addSubview(split)
        let anchor = NSView(frame: surfaceFrame)
        content.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(origin: .zero, size: surfaceFrame.size))
        )
        let sentinel = NSView(frame: NSRect(origin: .zero, size: surfaceFrame.size))
        sentinel.autoresizingMask = [.width, .height]
        sentinel.wantsLayer = true
        sentinel.layer?.backgroundColor = surfaceSentinelColor.cgColor
        hosted.addSubview(sentinel, positioned: .above, relativeTo: nil)
        let portal = WindowTerminalPortal(window: window)
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        content.layoutSubtreeIfNeeded()
        split.setPosition(80, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let dividerX = split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2
        if let nativeDividerSentinelColor {
            // This view covers the split view's native divider but stays below the portal host.
            // It makes a rendered portal overlay observable without a terminal surface overlap.
            let nativeSentinel = NSView(
                frame: NSRect(x: dividerX - 3, y: 20, width: 20, height: 60)
            )
            nativeSentinel.wantsLayer = true
            nativeSentinel.layer?.backgroundColor = nativeDividerSentinelColor.cgColor
            content.addSubview(nativeSentinel)
        }
        portal.synchronizeHostedViewForAnchor(anchor)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        window.displayIfNeeded()

        let captureView = try XCTUnwrap(content.superview)
        captureView.layoutSubtreeIfNeeded()
        let dividerPoint = split.convert(
            NSPoint(x: dividerX, y: split.bounds.midY),
            to: captureView
        )
        let controlPoint: NSPoint
        if nativeDividerSentinelColor != nil {
            controlPoint = split.convert(
                NSPoint(x: dividerX + 8, y: split.bounds.midY), to: captureView
            )
        } else {
            controlPoint = anchor.convert(
                NSPoint(x: anchor.bounds.midX - 6, y: anchor.bounds.midY), to: captureView
            )
        }
        let bitmap = try XCTUnwrap(
            captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds)
        )
        XCTAssertGreaterThan(captureView.bounds.width, 0)
        XCTAssertGreaterThan(captureView.bounds.height, 0)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
        return RenderedPortal(
            window: window,
            dividerPoint: dividerPoint,
            controlPoint: controlPoint,
            bitmap: bitmap,
            captureBounds: captureView.bounds
        )
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let b = rhs.usingColorSpace(.deviceRGB) ?? rhs
        return max(
            abs(a.redComponent - b.redComponent),
            abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent)
        )
    }

    private func sampledColors(
        in rendered: RenderedPortal,
        around windowPoint: NSPoint,
        radius: Int = 2
    ) -> [NSColor] {
        let capturePoint = NSPoint(
            x: windowPoint.x - rendered.captureBounds.minX,
            y: windowPoint.y - rendered.captureBounds.minY
        )
        let scaleX = CGFloat(rendered.bitmap.pixelsWide) / rendered.captureBounds.width
        let scaleY = CGFloat(rendered.bitmap.pixelsHigh) / rendered.captureBounds.height
        let centerX = Int((capturePoint.x * scaleX).rounded())
        let centerY = Int((capturePoint.y * scaleY).rounded())
        var colors: [NSColor] = []
        for dx in -radius...radius {
            for dy in -radius...radius {
                let x = centerX + dx
                let y = centerY + dy
                guard x >= 0, x < rendered.bitmap.pixelsWide else { continue }
                guard y >= 0, y < rendered.bitmap.pixelsHigh else { continue }
                if let color = rendered.bitmap.colorAt(x: x, y: y) {
                    colors.append(color)
                }
            }
        }
        return colors
    }

    private func stripeDistance(
        in rendered: RenderedPortal,
        dividerRadius: Int = 2
    ) -> CGFloat {
        let divider = sampledColors(
            in: rendered, around: rendered.dividerPoint, radius: dividerRadius
        )
        let control = sampledColors(in: rendered, around: rendered.controlPoint, radius: 1)
        XCTAssertFalse(divider.isEmpty)
        XCTAssertFalse(control.isEmpty)
        return divider.flatMap { lhs in control.map { rhs in colorDistance(lhs, rhs) } }.max()
            ?? .infinity
    }

    func testOpaqueDividerRendersWithoutSurfaceOcclusion() throws {
        let rendered = try makeRenderedPortal(
            dividerColor: opaqueDividerColor,
            surfaceFrame: NSRect(x: 8, y: 8, width: 24, height: 24),
            nativeDividerSentinelColor: nativeSentinelColor
        )
        defer { rendered.window.orderOut(nil) }
        XCTAssertGreaterThan(
            stripeDistance(in: rendered), 0.15,
            "Opaque overlay must differ from the adjacent occluder control"
        )
    }

    func testTranslucentDividerWithoutOcclusionUsesNativeRenderedColor() throws {
        let rendered = try makeRenderedPortal(
            dividerColor: NSColor.white.withAlphaComponent(translucentAlpha),
            surfaceFrame: NSRect(x: 8, y: 8, width: 24, height: 24),
            nativeDividerSentinelColor: nativeSentinelColor
        )
        defer { rendered.window.orderOut(nil) }
        XCTAssertLessThan(
            stripeDistance(in: rendered), 0.08,
            "Translucent no-cross stripe must preserve the occluder control"
        )
    }

    func testTranslucentDividerOverActualSurfaceUsesOverlayComposite() throws {
        let rendered = try makeRenderedPortal(
            dividerColor: NSColor.white.withAlphaComponent(translucentAlpha),
            surfaceFrame: NSRect(x: 68, y: 28, width: 24, height: 44)
        )
        defer { rendered.window.orderOut(nil) }
        XCTAssertGreaterThan(
            stripeDistance(in: rendered), 0.10,
            "Translucent cross stripe must differ from the adjacent surface control"
        )
    }
}
