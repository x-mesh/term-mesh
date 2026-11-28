import XCTest
@testable import Bonsplit
import AppKit
import SwiftUI

final class BonsplitTests: XCTestCase {
#if DEBUG
    func testDebugEventLogReopensAClosedFileHandleInsteadOfCrashing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugEventLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("events.log")
        let log = DebugEventLog(outputPath: logURL.path, startsTimer: false)

        log.log("before invalidation")
        log.flushForTesting()
        log.invalidateFileHandleForTesting()
        log.log("after invalidation")
        log.flushForTesting()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("before invalidation"))
        XCTAssertTrue(contents.contains("after invalidation"))
    }
#endif

    @MainActor
    private final class LayoutProbeView: NSView {
        private(set) var sizeChangeCount = 0
        private(set) var originChangeCount = 0

        override func setFrameSize(_ newSize: NSSize) {
            if frame.size != newSize {
                sizeChangeCount += 1
            }
            super.setFrameSize(newSize)
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            if frame.origin != newOrigin {
                originChangeCount += 1
            }
            super.setFrameOrigin(newOrigin)
        }
    }

    @MainActor
    private struct LayoutProbeRepresentable: NSViewRepresentable {
        let probeView: LayoutProbeView

        func makeNSView(context: Context) -> LayoutProbeView {
            probeView
        }

        func updateNSView(_ nsView: LayoutProbeView, context: Context) {}
    }

    @MainActor
    private final class DropZoneModel: ObservableObject {
        @Published var zone: DropZone?
    }

    @MainActor
    private struct PaneDropInteractionHarness: View {
        @ObservedObject var model: DropZoneModel
        let probeView: LayoutProbeView

        var body: some View {
            PaneDropInteractionContainer(activeDropZone: model.zone) {
                LayoutProbeRepresentable(probeView: probeView)
            } dropLayer: { _ in
                Color.clear
            }
        }
    }

    private final class TabContextActionDelegateSpy: BonsplitDelegate {
        var action: TabContextAction?
        var tabId: TabID?
        var paneId: PaneID?

        func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
            self.action = action
            self.tabId = tab.id
            self.paneId = pane
        }
    }

    private final class CloseVetoDelegateSpy: BonsplitDelegate {
        private(set) var didClose = false

        func splitTabBar(
            _ controller: BonsplitController,
            shouldCloseTab tab: Bonsplit.Tab,
            inPane pane: PaneID
        ) -> Bool { false }

        func splitTabBar(
            _ controller: BonsplitController,
            didCloseTab tabId: TabID,
            fromPane pane: PaneID
        ) {
            didClose = true
        }
    }

    @MainActor
    func testControllerCreation() {
        let controller = BonsplitController()
        XCTAssertNotNil(controller.focusedPaneId)
    }

    @MainActor
    func testInteractiveStateSkipsRedundantInternalWrite() {
        let controller = BonsplitController()
        controller.internalController.isInteractive = false

        controller.isInteractive = true

        XCTAssertFalse(controller.internalController.isInteractive)

        controller.isInteractive = false

        XCTAssertFalse(controller.internalController.isInteractive)
    }

    @MainActor
    func testFocusPaneSkipsRedundantObservableWrite() async {
        let controller = BonsplitController()
        let paneId = try! XCTUnwrap(controller.internalController.focusedPaneId)
        let invalidated = expectation(description: "focusedPaneId invalidated")
        invalidated.isInverted = true

        withObservationTracking {
            _ = controller.internalController.focusedPaneId
        } onChange: {
            invalidated.fulfill()
        }

        controller.internalController.focusPane(paneId)
        await fulfillment(of: [invalidated], timeout: 0.05)
        XCTAssertEqual(controller.internalController.focusedPaneId, paneId)
    }

    @MainActor
    func testGeometryBookkeepingIsExcludedFromObservation() async {
        let controller = BonsplitController().internalController
        let invalidated = expectation(description: "bookkeeping state invalidated")
        invalidated.isInverted = true

        withObservationTracking {
            _ = controller.containerFrame
            _ = controller.isExternalUpdateInProgress
            _ = controller.lastGeometryNotificationTime
            _ = controller.dragGeneration
            _ = controller.onGeometryChange
        } onChange: {
            invalidated.fulfill()
        }

        controller.containerFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        controller.isExternalUpdateInProgress = true
        controller.lastGeometryNotificationTime = 123
        controller.dragGeneration += 1
        controller.onGeometryChange = {}

        await fulfillment(of: [invalidated], timeout: 0.05)
    }

    @MainActor
    func testPendingTabDropOperationCopiesExternalAndMovesLocalDrags() throws {
        let controller = BonsplitController().internalController

        XCTAssertEqual(controller.pendingTabDropOperation, .copy)

        let pane = try XCTUnwrap(controller.rootNode.allPanes.first)
        let tab = TabItem(title: "Dragged", icon: nil)
        pane.addTab(tab, select: true)
        XCTAssertEqual(
            controller.pendingTabDropOperation(
                for: TabTransferData(tab: tab, sourcePaneId: pane.id.id)
            ),
            .move
        )
        XCTAssertEqual(
            controller.pendingTabDropOperation(
                for: TabTransferData(
                    tab: tab,
                    sourcePaneId: pane.id.id,
                    copiesSource: true
                )
            ),
            .copy
        )

        controller.draggingTab = tab
        XCTAssertEqual(controller.pendingTabDropOperation, .move)
        XCTAssertEqual(controller.pendingTabDropOperation(for: nil), .move)

        controller.draggingTab = nil
        controller.activeDragTab = tab
        XCTAssertEqual(controller.pendingTabDropOperation, .move)
    }

    @MainActor
    func testTabCreation() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")
        XCTAssertNotNil(tabId)
    }

    @MainActor
    func testTabRetrieval() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")!
        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Test Tab")
        XCTAssertEqual(tab?.icon, "doc")
    }

    @MainActor
    func testTabUpdate() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Original", icon: "doc")!

        controller.updateTab(tabId, title: "Updated", isDirty: true)

        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Updated")
        XCTAssertEqual(tab?.isDirty, true)
    }

    @MainActor
    func testTabClose() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")!

        let closed = controller.closeTab(tabId)

        XCTAssertTrue(closed)
        XCTAssertNil(controller.tab(tabId))
    }

    @MainActor
    func testCloseSelectedTabKeepsIndexStableWhenPossible() {
        do {
            let config = BonsplitConfiguration(newTabPosition: .end)
            let controller = BonsplitController(configuration: config)

            let tab0 = controller.createTab(title: "0")!
            let tab1 = controller.createTab(title: "1")!
            let tab2 = controller.createTab(title: "2")!

            let pane = controller.focusedPaneId!

            controller.selectTab(tab1)
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab1)

            _ = controller.closeTab(tab1)

            // Order is [0,1,2] and 1 was selected; after close we should select 2 (same index).
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab2)
            XCTAssertNotNil(controller.tab(tab0))
        }

        do {
            let config = BonsplitConfiguration(newTabPosition: .end)
            let controller = BonsplitController(configuration: config)

            let tab0 = controller.createTab(title: "0")!
            let tab1 = controller.createTab(title: "1")!
            let tab2 = controller.createTab(title: "2")!

            let pane = controller.focusedPaneId!

            controller.selectTab(tab2)
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab2)

            _ = controller.closeTab(tab2)

            // Closing last should select previous.
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab1)
            XCTAssertNotNil(controller.tab(tab0))
        }
    }

    @MainActor
    func testConfiguration() {
        let config = BonsplitConfiguration(
            allowSplits: false,
            allowCloseTabs: true
        )
        let controller = BonsplitController(configuration: config)

        XCTAssertFalse(controller.configuration.allowSplits)
        XCTAssertTrue(controller.configuration.allowCloseTabs)
    }

    func testDefaultSplitButtonTooltips() {
        let defaults = BonsplitConfiguration.SplitButtonTooltips.default
        XCTAssertEqual(defaults.newTerminal, "New Terminal")
        XCTAssertEqual(defaults.newBrowser, "New Browser")
        XCTAssertEqual(defaults.splitRight, "Split Right")
        XCTAssertEqual(defaults.splitDown, "Split Down")
    }

    @MainActor
    func testConfigurationAcceptsCustomSplitButtonTooltips() {
        let customTooltips = BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: "Terminal (⌘T)",
            newBrowser: "Browser (⌘⇧L)",
            splitRight: "Split Right (⌘D)",
            splitDown: "Split Down (⌘⇧D)"
        )
        let config = BonsplitConfiguration(
            appearance: .init(
                splitButtonTooltips: customTooltips
            )
        )
        let controller = BonsplitController(configuration: config)

        XCTAssertEqual(controller.configuration.appearance.splitButtonTooltips, customTooltips)
    }

    func testChromeBackgroundHexOverrideParsesForPaneBackground() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#FDF6E3")
        )
        let color = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertEqual(Int(round(red * 255)), 253)
        XCTAssertEqual(Int(round(green * 255)), 246)
        XCTAssertEqual(Int(round(blue * 255)), 227)
        XCTAssertEqual(Int(round(alpha * 255)), 255)
    }

    func testChromeBorderHexOverrideParsesForSeparatorColor() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822", borderHex: "#112233")
        )
        let color = TabBarColors.nsColorSeparator(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertEqual(Int(round(red * 255)), 17)
        XCTAssertEqual(Int(round(green * 255)), 34)
        XCTAssertEqual(Int(round(blue * 255)), 51)
        XCTAssertEqual(Int(round(alpha * 255)), 255)
    }

    func testInvalidChromeBackgroundHexFallsBackToPaneDefaultColor() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#ZZZZZZ")
        )
        let resolved = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!
        let fallback = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        resolved.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        fallback.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)

        XCTAssertEqual(rr, fr, accuracy: 0.0001)
        XCTAssertEqual(rg, fg, accuracy: 0.0001)
        XCTAssertEqual(rb, fb, accuracy: 0.0001)
        XCTAssertEqual(ra, fa, accuracy: 0.0001)
    }

    func testPartiallyInvalidChromeBackgroundHexFallsBackToPaneDefaultColor() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#FF000G")
        )
        let resolved = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!
        let fallback = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        resolved.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        fallback.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)

        XCTAssertEqual(rr, fr, accuracy: 0.0001)
        XCTAssertEqual(rg, fg, accuracy: 0.0001)
        XCTAssertEqual(rb, fb, accuracy: 0.0001)
        XCTAssertEqual(ra, fa, accuracy: 0.0001)
    }

    func testInactiveTextUsesLightForegroundOnDarkCustomChromeBackground() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822")
        )
        let color = TabBarColors.nsColorInactiveText(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertGreaterThan(red, 0.5)
        XCTAssertGreaterThan(green, 0.5)
        XCTAssertGreaterThan(blue, 0.5)
        XCTAssertGreaterThan(alpha, 0.6)
    }

    func testSplitActionPressedStateUsesHigherContrast() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822")
        )

        let idleIcon = TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: false).usingColorSpace(.sRGB)!
        let pressedIcon = TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: true).usingColorSpace(.sRGB)!

        var idleAlpha: CGFloat = 0
        idleIcon.getRed(nil, green: nil, blue: nil, alpha: &idleAlpha)
        var pressedAlpha: CGFloat = 0
        pressedIcon.getRed(nil, green: nil, blue: nil, alpha: &pressedAlpha)

        XCTAssertGreaterThan(pressedAlpha, idleAlpha)
    }

    @MainActor
    func testMoveTabNoopAfterItself() {
        let t0 = TabItem(title: "0")
        let t1 = TabItem(title: "1")
        let pane = PaneState(tabs: [t0, t1], selectedTabId: t1.id)

        // Dragging the last tab to the right corresponds to moving it to `tabs.count`,
        // which should be treated as a no-op.
        pane.moveTab(from: 1, to: 2)
        XCTAssertEqual(pane.tabs.map(\.id), [t0.id, t1.id])
        XCTAssertEqual(pane.selectedTabId, t1.id)

        // Still allow real moves.
        pane.moveTab(from: 0, to: 2)
        XCTAssertEqual(pane.tabs.map(\.id), [t1.id, t0.id])
        XCTAssertEqual(pane.selectedTabId, t1.id)
    }

    @MainActor
    func testPinnedTabInsertionsStayAheadOfUnpinnedTabs() {
        let unpinnedA = TabItem(title: "A", isPinned: false)
        let unpinnedB = TabItem(title: "B", isPinned: false)
        let pinned = TabItem(title: "Pinned", isPinned: true)
        let pane = PaneState(tabs: [unpinnedA, unpinnedB], selectedTabId: unpinnedA.id)

        pane.insertTab(pinned, at: 2)

        XCTAssertEqual(pane.tabs.map(\.isPinned), [true, false, false])
        XCTAssertEqual(pane.tabs.first?.id, pinned.id)
    }

    @MainActor
    func testMovingUnpinnedTabCannotCrossPinnedBoundary() {
        let pinnedA = TabItem(title: "Pinned A", isPinned: true)
        let pinnedB = TabItem(title: "Pinned B", isPinned: true)
        let unpinnedA = TabItem(title: "A", isPinned: false)
        let unpinnedB = TabItem(title: "B", isPinned: false)
        let pane = PaneState(
            tabs: [pinnedA, pinnedB, unpinnedA, unpinnedB],
            selectedTabId: unpinnedB.id
        )

        // Attempt to move an unpinned tab ahead of pinned tabs; move should clamp to
        // the first unpinned position.
        pane.moveTab(from: 3, to: 0)

        XCTAssertEqual(pane.tabs.map(\.id), [pinnedA.id, pinnedB.id, unpinnedB.id, unpinnedA.id])
        XCTAssertEqual(pane.tabs.prefix(2).allSatisfy(\.isPinned), true)
        XCTAssertEqual(pane.tabs.suffix(2).allSatisfy { !$0.isPinned }, true)
    }

    @MainActor
    func testCreateTabStoresKindAndPinnedState() {
        let controller = BonsplitController()
        let tabId = controller.createTab(
            title: "Browser",
            icon: "globe",
            kind: "browser",
            isPinned: true
        )!

        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.kind, "browser")
        XCTAssertEqual(tab?.isPinned, true)
    }

    @MainActor
    func testForceCloseTabBypassesVetoAndStillNotifiesCleanup() throws {
        let controller = BonsplitController()
        let delegate = CloseVetoDelegateSpy()
        controller.delegate = delegate
        let tabID = try XCTUnwrap(controller.createTab(title: "rollback"))

        XCTAssertFalse(controller.closeTab(tabID))
        XCTAssertNotNil(controller.tab(tabID))
        XCTAssertTrue(controller.forceCloseTab(tabID))
        XCTAssertNil(controller.tab(tabID))
        XCTAssertTrue(delegate.didClose)
    }

    @MainActor
    func testCreateAndUpdateTabCustomTitleFlag() {
        let controller = BonsplitController()
        let tabId = controller.createTab(
            title: "Infra",
            hasCustomTitle: true
        )!

        XCTAssertEqual(controller.tab(tabId)?.hasCustomTitle, true)

        controller.updateTab(tabId, hasCustomTitle: false)
        XCTAssertEqual(controller.tab(tabId)?.hasCustomTitle, false)
    }

    @MainActor
    func testSplitEntryHoldSettlesOnlyAfterEveryOverlappingSlideEnds() {
        let controller = BonsplitController()
        var laidOut = 0
        var settled = 0
        controller.onSplitEntryTargetLaidOut = { laidOut += 1 }
        controller.onSplitEntrySettled = { settled += 1 }
        let internalController = controller.internalController
        let first = UUID()
        let second = UUID()

        internalController.splitEntryHoldBegan(first)
        internalController.splitEntryHoldBegan(second)
        internalController.splitEntryHoldEnded(first)
        XCTAssertEqual(settled, 0)

        internalController.splitEntryHoldEnded(second)
        internalController.splitEntryHoldEnded(second)
        internalController.splitEntryHoldEnded(UUID())
        XCTAssertEqual(laidOut, 2)
        XCTAssertEqual(settled, 1)
    }

    @MainActor
    func testDefaultSplitAnimatesNewSecondPaneFromEndEdge() throws {
        let controller = BonsplitController().internalController
        let source = try XCTUnwrap(controller.focusedPaneId)

        controller.splitPane(source, orientation: .horizontal)

        guard case .split(let split) = controller.rootNode else {
            return XCTFail("Expected a split root")
        }
        XCTAssertEqual(split.animationOrigin, .fromSecond)
    }

    @MainActor
    func testExplicitInsertionAnimatesNewFirstPaneFromStartEdge() throws {
        let controller = BonsplitController().internalController
        let source = try XCTUnwrap(controller.focusedPaneId)
        let tab = TabItem(title: "Inserted", icon: nil)

        controller.splitPaneWithTab(source, orientation: .vertical, tab: tab, insertFirst: true)

        guard case .split(let split) = controller.rootNode else {
            return XCTFail("Expected a split root")
        }
        XCTAssertEqual(split.animationOrigin, .fromFirst)
    }

    @MainActor
    func testSplitPaneWithOptionalTabPreservesCustomTitleFlag() {
        let controller = BonsplitController()
        _ = controller.createTab(title: "Base")
        let sourcePaneId = controller.focusedPaneId!
        let customTab = Bonsplit.Tab(title: "Custom", hasCustomTitle: true)

        guard let newPaneId = controller.splitPane(sourcePaneId, orientation: .horizontal, withTab: customTab) else {
            return XCTFail("Expected splitPane to return new pane")
        }
        let inserted = controller.tabs(inPane: newPaneId).first(where: { $0.id == customTab.id })
        XCTAssertEqual(inserted?.hasCustomTitle, true)
    }

    @MainActor
    func testSplitPaneWithInsertSidePreservesCustomTitleFlag() {
        let controller = BonsplitController()
        _ = controller.createTab(title: "Base")
        let sourcePaneId = controller.focusedPaneId!
        let customTab = Bonsplit.Tab(title: "Custom", hasCustomTitle: true)

        guard let newPaneId = controller.splitPane(
            sourcePaneId,
            orientation: .vertical,
            withTab: customTab,
            insertFirst: true
        ) else {
            return XCTFail("Expected splitPane(insertFirst:) to return new pane")
        }
        let inserted = controller.tabs(inPane: newPaneId).first(where: { $0.id == customTab.id })
        XCTAssertEqual(inserted?.hasCustomTitle, true)
    }

    @MainActor
    func testTabIconCacheNeverOutlivesTheDataItWasDecodedFrom() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let logo = try XCTUnwrap(image.tiffRepresentation)
        let other = try XCTUnwrap(NSImage(size: NSSize(width: 3, height: 3)).tiffRepresentation ?? Data([1]))
        let cached = try XCTUnwrap(NSImage(data: logo))

        // The cache matches the tab: it is used as is.
        XCTAssertTrue(TabItemStyling.displayedFaviconImage(cachedImage: cached, cachedData: logo, currentData: logo) === cached)
        // The logo was cleared but the cache still holds it: nothing is drawn.
        XCTAssertNil(TabItemStyling.displayedFaviconImage(cachedImage: cached, cachedData: logo, currentData: nil))
        // The cache caught a value from before the change: the current data wins.
        XCTAssertFalse(TabItemStyling.displayedFaviconImage(cachedImage: cached, cachedData: logo, currentData: other) === cached)
    }

    func testHostBadgeLabelIsLeftOutWhenTheTitleAlreadyNamesTheHost() {
        XCTAssertTrue(TabHostBadgeStyle.showsLabel(title: "Terminal 2", badgeLabel: "jwserver68"))
        XCTAssertFalse(TabHostBadgeStyle.showsLabel(title: "root@jwserver68: ~/fastgzip", badgeLabel: "jwserver68"))
        XCTAssertFalse(TabHostBadgeStyle.showsLabel(title: "root@JWSERVER68", badgeLabel: "jwserver68"))
        XCTAssertFalse(TabHostBadgeStyle.showsLabel(title: "Terminal 2", badgeLabel: "  "))
    }

    func testHostBadgeLabelColorMeetsTextContrastOnBothBackgrounds() {
        func luminance(_ c: (red: Double, green: Double, blue: Double)) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
        }
        func contrast(_ a: (red: Double, green: Double, blue: Double), _ b: (red: Double, green: Double, blue: Double)) -> Double {
            let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
            return (hi + 0.05) / (lo + 0.05)
        }
        func chip(_ c: TabHostBadge, over base: Double) -> (red: Double, green: Double, blue: Double) {
            let a = TabHostBadgeStyle.backgroundOpacity
            return (base * (1 - a) + c.red * a, base * (1 - a) + c.green * a, base * (1 - a) + c.blue * a)
        }
        // The host palette's primary colors (PeerHostAccent).
        let hosts = [(0.25, 0.60, 0.85), (0.95, 0.50, 0.35), (0.30, 0.70, 0.60), (0.70, 0.35, 0.95)]
        for (r, g, b) in hosts {
            let badge = TabHostBadge(label: "h", red: r, green: g, blue: b)
            XCTAssertGreaterThan(contrast(badge.labelRGB(onLightBackground: true), chip(badge, over: 0.945)), 4.5)
            XCTAssertGreaterThan(contrast(badge.labelRGB(onLightBackground: false), chip(badge, over: 0.15)), 4.5)
        }
    }

    @MainActor
    func testHostBadgeSurvivesUpdateSplitAndTransferEncoding() throws {
        let controller = BonsplitController()
        let badge = TabHostBadge(label: "jwserver68", red: 0.93, green: 0.5, blue: 0.35)
        let tabId = try XCTUnwrap(controller.createTab(title: "Terminal 2"))
        XCTAssertNil(controller.tab(tabId)?.hostBadge)

        controller.updateTab(tabId, hostBadge: .some(badge))
        XCTAssertEqual(controller.tab(tabId)?.hostBadge, badge)

        // A plain update leaves the badge alone; `.some(nil)` removes it.
        controller.updateTab(tabId, title: "renamed")
        XCTAssertEqual(controller.tab(tabId)?.hostBadge, badge)

        let tab = try XCTUnwrap(controller.tab(tabId))
        let newPane = try XCTUnwrap(controller.splitPane(orientation: .horizontal, withTab: tab))
        XCTAssertEqual(controller.tabs(inPane: newPane).first?.hostBadge, badge)

        let item = TabItem(id: UUID(), title: "Terminal 2", hostBadge: badge)
        let decoded = try JSONDecoder().decode(TabItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.hostBadge, badge)

        controller.updateTab(tabId, hostBadge: .some(nil))
        XCTAssertNil(controller.tab(tabId)?.hostBadge)
    }

    @MainActor
    func testTogglePaneZoomTracksState() {
        let controller = BonsplitController()
        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }

        // Single-pane layouts cannot be zoomed.
        XCTAssertFalse(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertNil(controller.zoomedPaneId)

        guard controller.splitPane(originalPane, orientation: .horizontal) != nil else {
            return XCTFail("Expected splitPane to create a new pane")
        }

        XCTAssertTrue(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertEqual(controller.zoomedPaneId, originalPane)
        XCTAssertTrue(controller.isSplitZoomed)

        XCTAssertTrue(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertNil(controller.zoomedPaneId)
        XCTAssertFalse(controller.isSplitZoomed)
    }

    @MainActor
    private final class ZoomMountProbe {
        var mounts = 0
        var views: [PaneID: NSView] = [:]
    }

    @MainActor
    private struct ZoomMountContent: NSViewRepresentable {
        let probe: ZoomMountProbe
        let pane: PaneID

        func makeNSView(context: Context) -> NSView {
            probe.mounts += 1
            let view = NSView()
            probe.views[pane] = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @MainActor
    func testPaneZoomRestoresWithoutRemountingContent() throws {
        let controller = BonsplitController()
        controller.configuration.appearance.enableAnimations = false
        let pane = try XCTUnwrap(controller.focusedPaneId)
        let second = try XCTUnwrap(controller.splitPane(pane, orientation: .horizontal))
        _ = try XCTUnwrap(controller.splitPane(second, orientation: .vertical))
        let probe = ZoomMountProbe()
        let host = NSHostingView(rootView: BonsplitView(controller: controller) { _, pane in
            ZoomMountContent(probe: probe, pane: pane)
        } emptyPane: { pane in
            ZoomMountContent(probe: probe, pane: pane)
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let originalMounts = probe.mounts
        XCTAssertEqual(originalMounts, 3)
        let originalFrames = probe.views.mapValues { $0.convert($0.bounds, to: host) }
        for target in controller.allPaneIds {
            XCTAssertTrue(controller.togglePaneZoom(inPane: target))
            settle()
            let targetView = try XCTUnwrap(probe.views[target])
            XCTAssertEqual(targetView.bounds.width, host.bounds.width - 2 * (BonsplitCardMetrics.gap + BonsplitCardMetrics.borderWidth), accuracy: 1)
            for (id, view) in probe.views {
                XCTAssertEqual(view.isHiddenOrHasHiddenAncestor, id != target)
            }
            let zoomedHeight = targetView.bounds.height
            window.setContentSize(NSSize(width: 960, height: 720))
            settle()
            XCTAssertEqual(targetView.bounds.width, host.bounds.width - 2 * (BonsplitCardMetrics.gap + BonsplitCardMetrics.borderWidth), accuracy: 1)
            XCTAssertEqual(targetView.bounds.height, zoomedHeight + 120, accuracy: 1)
            window.setContentSize(NSSize(width: 800, height: 600))
            settle()
            XCTAssertTrue(controller.togglePaneZoom(inPane: target))
            settle()
            XCTAssertEqual(probe.mounts, originalMounts,
                           "Zoom must retain pane content instead of rebuilding every transcript")
            for (id, view) in probe.views {
                XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
                let original = try XCTUnwrap(originalFrames[id])
                let restored = view.convert(view.bounds, to: host)
                XCTAssertEqual(restored.minX, original.minX, accuracy: 1)
                XCTAssertEqual(restored.minY, original.minY, accuracy: 1)
                XCTAssertEqual(restored.width, original.width, accuracy: 1)
                XCTAssertEqual(restored.height, original.height, accuracy: 1)
            }
        }
    }

    @MainActor
    func testPaneZoomDuringSplitEntryAnimationKeepsSiblingHidden() throws {
        let controller = BonsplitController()
        controller.configuration.appearance.enableAnimations = true
        let pane = try XCTUnwrap(controller.focusedPaneId)
        let probe = ZoomMountProbe()
        let host = NSHostingView(rootView: BonsplitView(controller: controller) { _, pane in
            ZoomMountContent(probe: probe, pane: pane)
        } emptyPane: { pane in
            ZoomMountContent(probe: probe, pane: pane)
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
        }
        settle()

        // Zoom before the split entry animation's pending callback reveals the new pane.
        let second = try XCTUnwrap(controller.splitPane(pane, orientation: .horizontal))
        XCTAssertTrue(controller.togglePaneZoom(inPane: second))
        settle()

        XCTAssertEqual(controller.zoomedPaneId, second)
        for (id, view) in probe.views {
            XCTAssertEqual(view.isHiddenOrHasHiddenAncestor, id != second,
                           "Entry animation must not reveal a sibling while zoom is active")
        }

        // Zoom exit still restores both panes.
        XCTAssertTrue(controller.togglePaneZoom(inPane: second))
        settle()
        for (_, view) in probe.views {
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        }
    }

    @MainActor
    func testPaneZoomSlideMovesThroughAndEndsWhereInstantZoomEnds() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion turns the slide off")
        let controller = BonsplitController()
        controller.configuration.appearance.enableAnimations = false
        let pane = try XCTUnwrap(controller.focusedPaneId)
        let second = try XCTUnwrap(controller.splitPane(pane, orientation: .horizontal))
        let third = try XCTUnwrap(controller.splitPane(second, orientation: .vertical))
        controller.configuration.appearance.enableAnimations = true
        controller.configuration.appearance.animationDuration = 0.2
        let probe = ZoomMountProbe()
        let host = NSHostingView(rootView: BonsplitView(controller: controller) { _, pane in
            ZoomMountContent(probe: probe, pane: pane)
        } emptyPane: { pane in
            ZoomMountContent(probe: probe, pane: pane)
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func settle(_ seconds: TimeInterval = 0.5) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
        }
        func frames() -> [PaneID: NSRect] {
            probe.views.mapValues { $0.convert($0.bounds, to: host) }
        }
        func assertFramesEqual(_ actual: [PaneID: NSRect], _ expected: [PaneID: NSRect], _ message: String) {
            for (id, rect) in expected {
                guard let got = actual[id] else { return XCTFail("missing pane: \(message)") }
                XCTAssertEqual(got.minX, rect.minX, accuracy: 1, message)
                XCTAssertEqual(got.minY, rect.minY, accuracy: 1, message)
                XCTAssertEqual(got.width, rect.width, accuracy: 1, message)
                XCTAssertEqual(got.height, rect.height, accuracy: 1, message)
            }
        }
        settle()
        let originalFrames = frames()
        let fullWidth = host.bounds.width - 2 * (BonsplitCardMetrics.gap + BonsplitCardMetrics.borderWidth)
        let target = third
        let targetView = try XCTUnwrap(probe.views[target])
        let originalWidth = targetView.bounds.width

        // Mid-slide the pane is between its own size and the full width.
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle(0.06)
        XCTAssertGreaterThan(targetView.bounds.width, originalWidth + 1)
        XCTAssertLessThan(targetView.bounds.width, fullWidth - 1)

        settle()
        XCTAssertEqual(targetView.bounds.width, fullWidth, accuracy: 1)
        for (id, view) in probe.views {
            XCTAssertEqual(view.isHiddenOrHasHiddenAncestor, id != target)
        }

        // Zoom out keeps the siblings hidden until the pane is back in place.
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle(0.06)
        XCTAssertLessThan(targetView.bounds.width, fullWidth - 1)
        for (id, view) in probe.views where id != target {
            XCTAssertTrue(view.isHiddenOrHasHiddenAncestor, "siblings appear only after the slide")
        }
        settle()
        for (_, view) in probe.views {
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        }
        assertFramesEqual(frames(), originalFrames, "after a full zoom in and out")

        // Reversing mid-slide still lands on the original layout.
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle(0.06)
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle()
        XCTAssertNil(controller.zoomedPaneId)
        for (_, view) in probe.views {
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        }
        assertFramesEqual(frames(), originalFrames, "after reversing mid-slide")
    }

    @MainActor
    func testZoomSlideSettlesOnceAndCountsFromItsFirstFrame() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion turns the slide off")
        let controller = BonsplitController()
        controller.configuration.appearance.enableAnimations = false
        let pane = try XCTUnwrap(controller.focusedPaneId)
        let second = try XCTUnwrap(controller.splitPane(pane, orientation: .horizontal))
        let target = try XCTUnwrap(controller.splitPane(second, orientation: .vertical))
        controller.configuration.appearance.enableAnimations = true
        controller.configuration.appearance.animationDuration = 0.2
        var settles = 0
        controller.onZoomSlideSettled = { settles += 1 }
        let probe = ZoomMountProbe()
        let host = NSHostingView(rootView: BonsplitView(controller: controller) { _, pane in
            ZoomMountContent(probe: probe, pane: pane)
        } emptyPane: { pane in
            ZoomMountContent(probe: probe, pane: pane)
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func settle(_ seconds: TimeInterval = 0.5) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let fullWidth = host.bounds.width - 2 * (BonsplitCardMetrics.gap + BonsplitCardMetrics.borderWidth)
        let targetView = try XCTUnwrap(probe.views[target])

        // Both nested levels slide; the host hears once, after the last one.
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle(0.06)
        XCTAssertEqual(settles, 0)
        settle()
        XCTAssertEqual(settles, 1)

        // A reversal cuts the first slide off; only the second one settles.
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle(0.06)
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle()
        XCTAssertEqual(settles, 2)

        // Time the main thread spends blocked right after the slide starts
        // must not count against its duration.
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle()
        XCTAssertNil(controller.zoomedPaneId)
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        host.layoutSubtreeIfNeeded()
        Thread.sleep(forTimeInterval: 0.25)
        settle(0.05)
        XCTAssertLessThan(targetView.bounds.width, fullWidth - 1, "the slide is still running")
        settle()
        XCTAssertEqual(targetView.bounds.width, fullWidth, accuracy: 1)

        // A nested pane zooming out heads for its own place in the split, not
        // for a layout guessed from the hidden siblings' stale frames.
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle()
        XCTAssertNil(controller.zoomedPaneId)
        controller.configuration.appearance.animationDuration = 2.0
        settle(0.05)
        let homeFrame = targetView.convert(targetView.bounds, to: host)
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle(2.5)
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        host.layoutSubtreeIfNeeded()
        // Late enough that the slide's ease-in-out curve is within a few
        // points of its end, early enough that it is still running.
        settle(1.9)
        let nearlyHome = targetView.convert(targetView.bounds, to: host)
        XCTAssertEqual(nearlyHome.minX, homeFrame.minX, accuracy: 10)
        XCTAssertEqual(nearlyHome.minY, homeFrame.minY, accuracy: 10)
        XCTAssertEqual(nearlyHome.width, homeFrame.width, accuracy: 10)
        XCTAssertEqual(nearlyHome.height, homeFrame.height, accuracy: 10)
        settle(1.5)
        controller.configuration.appearance.animationDuration = 0.2

        // With animations off nothing slides, so nothing settles.
        let before = settles
        controller.configuration.appearance.enableAnimations = false
        settle(0.05)
        XCTAssertTrue(controller.togglePaneZoom(inPane: target))
        settle()
        XCTAssertEqual(settles, before)
    }

    @MainActor
    func testSplitClearsExistingPaneZoom() {
        let controller = BonsplitController()
        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }

        guard let secondPane = controller.splitPane(originalPane, orientation: .horizontal) else {
            return XCTFail("Expected splitPane to create a new pane")
        }

        XCTAssertTrue(controller.togglePaneZoom(inPane: secondPane))
        XCTAssertEqual(controller.zoomedPaneId, secondPane)

        _ = controller.splitPane(secondPane, orientation: .vertical)
        XCTAssertNil(controller.zoomedPaneId, "Splitting should reset zoom state")
    }

    @MainActor
    func testRequestTabContextActionForwardsToDelegate() {
        let controller = BonsplitController()
        let pane = controller.focusedPaneId!
        let tabId = controller.createTab(title: "Test", kind: "browser")!
        let spy = TabContextActionDelegateSpy()
        controller.delegate = spy

        controller.requestTabContextAction(.reload, for: tabId, inPane: pane)

        XCTAssertEqual(spy.action, .reload)
        XCTAssertEqual(spy.tabId, tabId)
        XCTAssertEqual(spy.paneId, pane)
    }

    @MainActor
    func testRequestTabContextActionForwardsMarkAsReadToDelegate() {
        let controller = BonsplitController()
        let pane = controller.focusedPaneId!
        let tabId = controller.createTab(title: "Test", kind: "terminal")!
        let spy = TabContextActionDelegateSpy()
        controller.delegate = spy

        controller.requestTabContextAction(.markAsRead, for: tabId, inPane: pane)

        XCTAssertEqual(spy.action, .markAsRead)
        XCTAssertEqual(spy.tabId, tabId)
        XCTAssertEqual(spy.paneId, pane)
    }

    func testIconSaturationKeepsRasterFaviconInColorWhenInactive() {
        XCTAssertEqual(
            TabItemStyling.iconSaturation(hasRasterIcon: true, tabSaturation: 0.0),
            1.0
        )
    }

    func testIconSaturationStillDesaturatesSymbolIconsWhenInactive() {
        XCTAssertEqual(
            TabItemStyling.iconSaturation(hasRasterIcon: false, tabSaturation: 0.0),
            0.0
        )
    }

    func testResolvedFaviconImageUsesIncomingDataWhenDecodable() {
        let existing = NSImage(size: NSSize(width: 12, height: 12))
        let incoming = NSImage(size: NSSize(width: 16, height: 16))
        incoming.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        incoming.unlockFocus()
        let data = incoming.tiffRepresentation

        let resolved = TabItemStyling.resolvedFaviconImage(existing: existing, incomingData: data)
        XCTAssertNotNil(resolved)
        XCTAssertFalse(resolved === existing)
    }

    func testResolvedFaviconImageKeepsExistingImageWhenIncomingDataIsInvalid() {
        let existing = NSImage(size: NSSize(width: 16, height: 16))
        let invalidData = Data([0x00, 0x11, 0x22, 0x33])

        let resolved = TabItemStyling.resolvedFaviconImage(existing: existing, incomingData: invalidData)
        XCTAssertTrue(resolved === existing)
    }

    func testResolvedFaviconImageClearsWhenIncomingDataIsNil() {
        let existing = NSImage(size: NSSize(width: 16, height: 16))
        let resolved = TabItemStyling.resolvedFaviconImage(existing: existing, incomingData: nil)
        XCTAssertNil(resolved)
    }

    func testTabControlShortcutHintPolicyRequiresCommandOrControlOnly() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertNotNil(TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults))
            XCTAssertNotNil(TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.control, .shift], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.command, .option], defaults: defaults))
        }
    }

    func testTabControlShortcutHintPolicyCanDisableHoldHints() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(false, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults))
        }
    }

    func testTabControlShortcutHintPolicyDefaultsToShowingHoldHints() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.removeObject(forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertEqual(TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults), .command)
            XCTAssertEqual(TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults), .control)
        }
    }

    func testTabControlShortcutHintsAreScopedToCurrentKeyWindow() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertTrue(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: 42,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: 7,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: false,
                    eventWindowNumber: 42,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )
        }
    }

    func testTabControlShortcutHintsFallbackToKeyWindowWhenEventWindowMissing() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertTrue(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 7,
                    defaults: defaults
                )
            )
        }
    }

    func testSelectedTabNeverShowsHoverBackground() {
        XCTAssertFalse(
            TabItemStyling.shouldShowHoverBackground(isHovered: true, isSelected: true)
        )
        XCTAssertTrue(
            TabItemStyling.shouldShowHoverBackground(isHovered: true, isSelected: false)
        )
        XCTAssertFalse(
            TabItemStyling.shouldShowHoverBackground(isHovered: false, isSelected: false)
        )
    }

    @MainActor
    func testPaneDropOverlayDoesNotResizeHostedContentDuringHover() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let model = DropZoneModel()
        let probeView = LayoutProbeView(frame: .zero)
        let hostingView = NSHostingView(
            rootView: PaneDropInteractionHarness(
                model: model,
                probeView: probeView
            )
        )
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let initialFrame = probeView.frame
        let initialSizeChanges = probeView.sizeChangeCount
        let initialOriginChanges = probeView.originChangeCount

        model.zone = .left
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        XCTAssertEqual(probeView.frame, initialFrame)
        XCTAssertEqual(
            probeView.sizeChangeCount,
            initialSizeChanges,
            "Drag-hover overlays must not resize the hosted pane content"
        )
        XCTAssertEqual(
            probeView.originChangeCount,
            initialOriginChanges,
            "Drag-hover overlays must not move the hosted pane content"
        )

        model.zone = .bottom
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        XCTAssertEqual(probeView.frame, initialFrame)
        XCTAssertEqual(
            probeView.sizeChangeCount,
            initialSizeChanges,
            "Switching hover targets should keep the hosted pane geometry stable"
        )
        XCTAssertEqual(
            probeView.originChangeCount,
            initialOriginChanges,
            "Switching hover targets should not reposition the hosted pane content"
        )
    }

    @MainActor
    func testTranslucentSplitWrappersStayClear() {
        let appearance = BonsplitConfiguration.Appearance(
            enableAnimations: false,
            chromeColors: .init(backgroundHex: "#11223380")
        )
        let configuration = BonsplitConfiguration(appearance: appearance)
        let controller = BonsplitController(configuration: configuration)
        _ = controller.createTab(title: "Base")
        guard let sourcePane = controller.focusedPaneId else {
            XCTFail("Expected focused pane")
            return
        }
        guard controller.splitPane(sourcePane, orientation: .horizontal) != nil else {
            XCTFail("Expected splitPane to create a new pane")
            return
        }

        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: controller) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        guard let splitView = firstDescendant(ofType: NSSplitView.self, in: hostingView) else {
            XCTFail("Expected split view")
            return
        }
        XCTAssertEqual(splitView.arrangedSubviews.count, 2)

        let dividerBackground = splitView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        XCTAssertNotNil(dividerBackground, "Expected split view to be layer-backed")
        XCTAssertEqual(
            dividerBackground?.alphaComponent ?? 0,
            0,
            accuracy: 0.001,
            "Split root should stay clear so translucent pane chrome is painted only once"
        )

        for container in splitView.arrangedSubviews {
            let background = container.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
            XCTAssertNotNil(background, "Expected arranged subview to be layer-backed")
            XCTAssertEqual(
                background?.alphaComponent ?? -1,
                0,
                accuracy: 0.001,
                "Split-only wrapper containers should stay clear so translucent pane chrome is not composited twice"
            )
        }
    }

    @MainActor
    func testSplitContentAlphaMatchesSinglePane() {
        let appearance = BonsplitConfiguration.Appearance(
            enableAnimations: false,
            chromeColors: .init(backgroundHex: "#11223380")
        )
        let expectedAlpha = CGFloat(128.0 / 255.0)
        let samplePoint = NSPoint(x: 100, y: 100)

        let singlePaneController = BonsplitController(
            configuration: BonsplitConfiguration(appearance: appearance)
        )
        _ = singlePaneController.createTab(title: "Base")

        guard let singlePaneAlpha = renderedAlpha(
            for: singlePaneController,
            samplePoint: samplePoint
        ) else {
            XCTFail("Expected single-pane rendered alpha")
            return
        }
        XCTAssertEqual(
            singlePaneAlpha,
            expectedAlpha,
            accuracy: 0.03,
            "Single-pane content should preserve the configured translucent alpha"
        )

        let splitController = BonsplitController(
            configuration: BonsplitConfiguration(appearance: appearance)
        )
        _ = splitController.createTab(title: "Base")
        guard let sourcePane = splitController.focusedPaneId else {
            XCTFail("Expected focused pane")
            return
        }
        guard splitController.splitPane(sourcePane, orientation: .horizontal) != nil else {
            XCTFail("Expected splitPane to create a new pane")
            return
        }

        guard let splitAlpha = renderedAlpha(
            for: splitController,
            samplePoint: samplePoint
        ) else {
            XCTFail("Expected split rendered alpha")
            return
        }

        XCTAssertEqual(
            splitAlpha,
            singlePaneAlpha,
            accuracy: 0.03,
            "Split mode should render the same content alpha as single-pane mode"
        )
    }

    private func withShortcutHintDefaultsSuite(_ body: (UserDefaults) -> Void) {
        let suiteName = "BonsplitShortcutHintPolicyTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func firstDescendant<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T {
            return match
        }
        for subview in root.subviews {
            if let match = firstDescendant(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func renderedAlpha(
        for controller: BonsplitController,
        samplePoint: NSPoint,
        size: NSSize = NSSize(width: 800, height: 600)
    ) -> CGFloat? {
        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: controller) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            }
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else { return nil }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        return renderedColor(in: hostingView, at: samplePoint)?.alphaComponent
    }

    @MainActor
    private func renderedColor(in view: NSView, at point: NSPoint) -> NSColor? {
        let integralBounds = view.bounds.integral
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: integralBounds) else { return nil }
        bitmap.size = integralBounds.size
        view.cacheDisplay(in: integralBounds, to: bitmap)

        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        guard x >= 0,
              y >= 0,
              x < bitmap.pixelsWide,
              y < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: x, y: y)
    }
}
