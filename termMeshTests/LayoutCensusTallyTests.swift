import AppKit
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class LayoutCensusTallyTests: XCTestCase {
    private final class FakeTerminalHost: NSView {}

    private func walk(
        _ root: NSView,
        windowKey: String = "1:NSWindow",
        budget: Int = 20_000,
        into tally: inout LayoutCensusTally
    ) -> Int {
        var remaining = budget
        LayoutCensusTally.walk(
            root: root,
            windowKey: windowKey,
            budget: &remaining,
            into: &tally,
            isTerminalHost: { $0 is FakeTerminalHost }
        )
        return remaining
    }

    func testCountsViewsDepthAndConstraints() {
        let root = NSView()
        let child = NSView()
        let grandchild = NSView()
        root.addSubview(child)
        child.addSubview(grandchild)
        child.addConstraint(grandchild.widthAnchor.constraint(equalToConstant: 10))
        child.addConstraint(grandchild.heightAnchor.constraint(equalToConstant: 10))

        var tally = LayoutCensusTally()
        _ = walk(root, into: &tally)

        XCTAssertEqual(tally.views, 3)
        XCTAssertEqual(tally.maxDepth, 2)
        XCTAssertEqual(tally.constraints, 2)
        XCTAssertEqual(tally.hiddenSubtreeViews, 0)
    }

    func testHiddenAncestorMarksWholeSubtreeAndItsTerminals() {
        let root = NSView()
        let hiddenContainer = NSView()
        hiddenContainer.isHidden = true
        let hiddenTerminal = FakeTerminalHost()
        let hiddenLeaf = NSView()
        hiddenTerminal.addSubview(hiddenLeaf)
        hiddenContainer.addSubview(hiddenTerminal)
        let visibleTerminal = FakeTerminalHost()
        root.addSubview(hiddenContainer)
        root.addSubview(visibleTerminal)

        var tally = LayoutCensusTally()
        _ = walk(root, into: &tally)

        XCTAssertEqual(tally.views, 5)
        // The hidden container, the terminal inside it, and that terminal's child.
        XCTAssertEqual(tally.hiddenSubtreeViews, 3)
        XCTAssertEqual(tally.terminalHosts, 2)
        XCTAssertEqual(tally.hiddenTerminalHosts, 1)
    }

    func testViewsAreCountedPerWindowKey() {
        let first = NSView()
        first.addSubview(NSView())
        let second = NSView()

        var tally = LayoutCensusTally()
        _ = walk(first, windowKey: "10:NSWindow", into: &tally)
        _ = walk(second, windowKey: "11:NSPanel", into: &tally)

        XCTAssertEqual(tally.viewsByWindow, ["10:NSWindow": 2, "11:NSPanel": 1])
        XCTAssertEqual(tally.contextFields()["views_by_window"] as? String, "10:NSWindow=2 11:NSPanel=1")
    }

    func testBudgetStopsTheWalk() {
        let root = NSView()
        for _ in 0..<10 { root.addSubview(NSView()) }

        var tally = LayoutCensusTally()
        let remaining = walk(root, budget: 4, into: &tally)

        XCTAssertEqual(tally.views, 4)
        XCTAssertEqual(remaining, 0)
    }

    func testTopEntriesOrderLargestFirstThenByKey() {
        let counts = ["b": 5, "a": 5, "c": 9, "d": 1]
        XCTAssertEqual(LayoutCensusTally.topEntries(counts, limit: 3), "c=9 a=5 b=5")
        XCTAssertEqual(LayoutCensusTally.topEntries([:], limit: 3), "")
    }

    func testContextFieldsReportNoneForEmptyTallies() {
        let fields = LayoutCensusTally().contextFields()
        XCTAssertEqual(fields["top_hosts"] as? String, "none")
        XCTAssertEqual(fields["views_by_window"] as? String, "none")
        XCTAssertEqual(fields["hidden_subtree_views"] as? Int, 0)
    }

    func testPortalFieldsCarryTerminalCounts() {
        let portalHost = NSView()
        let hidden = FakeTerminalHost()
        hidden.isHidden = true
        hidden.addSubview(NSView())
        portalHost.addSubview(hidden)
        portalHost.addSubview(FakeTerminalHost())

        var tally = LayoutCensusTally()
        _ = walk(portalHost, windowKey: "portal", into: &tally)
        let fields = tally.portalFields(entries: 3, truncated: false)

        XCTAssertEqual(fields["portal_entries"] as? Int, 3)
        XCTAssertEqual(fields["portal_views"] as? Int, 4)
        XCTAssertEqual(fields["portal_terminals"] as? Int, 2)
        XCTAssertEqual(fields["portal_terminals_hidden"] as? Int, 1)
        XCTAssertEqual(fields["portal_hidden_subtree_views"] as? Int, 2)
        XCTAssertEqual(fields["portal_truncated"] as? Bool, false)
    }

    func testScreenSummaryListsEachScale() {
        let summary = LayoutCensusTally.screenSummary(scales: [2, 1], appActive: false)
        XCTAssertEqual(summary["screens"] as? Int, 2)
        XCTAssertEqual(summary["scales"] as? String, "2.0,1.0")
        XCTAssertEqual(summary["app_active"] as? Bool, false)
    }

    func testWorkspaceCountsSumAcrossWindows() {
        var counts = LayoutCensusWorkspaceCounts()
        counts.add(workspaces: 3, mountedWorkspaces: 2, panes: 5, surfaces: 7)
        counts.add(workspaces: 1, mountedWorkspaces: 1, panes: 1, surfaces: 2)

        let fields = counts.contextFields()
        XCTAssertEqual(fields["workspaces"] as? Int, 4)
        XCTAssertEqual(fields["mounted_workspaces"] as? Int, 3)
        XCTAssertEqual(fields["panes"] as? Int, 6)
        XCTAssertEqual(fields["surfaces"] as? Int, 9)
    }
}
