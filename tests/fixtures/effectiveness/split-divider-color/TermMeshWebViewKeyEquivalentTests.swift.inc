
@MainActor
final class HiddenSplitDividerPortalAcceptanceTests: XCTestCase {
    private final class OpaqueDividerSplitView: NSSplitView {
        override var dividerColor: NSColor { NSColor(hex: "#E040FB")! }
    }
    private final class TranslucentDividerSplitView: NSSplitView {
        override var dividerColor: NSColor { NSColor.white.withAlphaComponent(0.36) }
    }

    private func makeWindowAndPortal(
        split: NSSplitView, anchorFrame: NSRect
    ) throws -> (NSWindow, WindowTerminalPortal) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let content = try XCTUnwrap(window.contentView)
        split.frame = content.bounds
        split.isVertical = true
        split.addArrangedSubview(NSView(frame: .zero))
        split.addArrangedSubview(NSView(frame: .zero))
        content.addSubview(split)
        split.setPosition(80, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()

        let anchor = NSView(frame: anchorFrame)
        content.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        )
        let portal = WindowTerminalPortal(window: window)
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        content.layoutSubtreeIfNeeded()
        portal.synchronizeHostedViewForAnchor(anchor)
        return (window, portal)
    }

    func testOpaqueDividerRendersWithoutSurfaceOcclusion() throws {
        let (window, _) = try makeWindowAndPortal(
            split: OpaqueDividerSplitView(),
            anchorFrame: NSRect(x: 8, y: 8, width: 24, height: 24)
        )
        defer { window.orderOut(nil) }
        XCTAssertGreaterThan(hiddenAcceptanceVisibleDividerSegmentCount(in: window), 0)
    }

    func testTranslucentDividerKeepsOcclusionPolicy() throws {
        let (clearWindow, _) = try makeWindowAndPortal(
            split: TranslucentDividerSplitView(),
            anchorFrame: NSRect(x: 8, y: 8, width: 24, height: 24)
        )
        defer { clearWindow.orderOut(nil) }
        XCTAssertEqual(hiddenAcceptanceVisibleDividerSegmentCount(in: clearWindow), 0)

        let (occludedWindow, _) = try makeWindowAndPortal(
            split: TranslucentDividerSplitView(),
            anchorFrame: NSRect(x: 8, y: 8, width: 24, height: 24)
        )
        defer { occludedWindow.orderOut(nil) }
        XCTAssertGreaterThan(
            hiddenAcceptanceVisibleDividerSegmentCount(
                in: occludedWindow, forceOcclusion: true
            ),
            0
        )
    }
}
