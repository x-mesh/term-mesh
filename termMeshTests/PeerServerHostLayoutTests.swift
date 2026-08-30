import XCTest
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Host-side layout-broadcast diagnostics.
///
/// A broadcast that REMOVES a leaf is the only layout change that costs an
/// attached viewer a pane — the pane and its scrollback go with it — and the
/// host used to say nothing about it, leaving the viewer's "Remote pane
/// closed" line as the whole record. That line cannot tell a host-side
/// removal from the viewer's own teardown, which is exactly the ambiguity
/// that made a real pane-loss incident unanswerable from logs alone. These
/// tests pin the two rules the new host-side line rests on.
final class PeerServerHostLayoutTests: XCTestCase {

    // MARK: - Fixtures

    private func leaf(_ id: UInt8, title: String = "") -> Termmesh_Peer_V1_WorkspaceLayout {
        var pane = Termmesh_Peer_V1_WorkspacePane()
        pane.surfaceID = Data([id])
        pane.title = title
        var node = Termmesh_Peer_V1_WorkspaceLayout()
        node.pane = pane
        return node
    }

    private func split(
        _ first: Termmesh_Peer_V1_WorkspaceLayout,
        _ second: Termmesh_Peer_V1_WorkspaceLayout
    ) -> Termmesh_Peer_V1_WorkspaceLayout {
        var s = Termmesh_Peer_V1_WorkspaceSplit()
        s.orientation = "horizontal"
        s.dividerPosition = 0.5
        s.splitID = Data([99])
        s.first = first
        s.second = second
        var node = Termmesh_Peer_V1_WorkspaceLayout()
        node.split = s
        return node
    }

    // MARK: - leafTitles

    func test_leafTitles_collectsEveryLeafOfANestedTree() {
        // The shape that actually lost panes in the field:
        // h(v(a,b), v(c,d)) — a nested split on both sides.
        let layout = split(
            split(leaf(1, title: "one"), leaf(2, title: "two")),
            split(leaf(3, title: "three"), leaf(4, title: "four"))
        )
        let titles = PeerHostCoordinator.leafTitles(layout)
        XCTAssertEqual(titles.count, 4)
        XCTAssertEqual(titles[Data([1])], "one")
        XCTAssertEqual(titles[Data([4])], "four")
    }

    func test_leafTitles_singlePaneTreeHasOneLeaf() {
        XCTAssertEqual(
            PeerHostCoordinator.leafTitles(leaf(7, title: "solo")),
            [Data([7]): "solo"]
        )
    }

    func test_leafTitles_emptyNodeHasNoLeaves() {
        // A layout with no node set at all: the wire allows it, and a
        // recursion that assumed a pane or a split would trap here.
        XCTAssertTrue(
            PeerHostCoordinator.leafTitles(Termmesh_Peer_V1_WorkspaceLayout()).isEmpty
        )
    }

    func test_leafTitles_keepsUntitledLeaves() {
        // An untitled leaf must still appear: it is the one a removal line
        // has to name by surface marker, and dropping it here would make
        // that removal invisible instead of merely unnamed.
        let titles = PeerHostCoordinator.leafTitles(split(leaf(1), leaf(2, title: "named")))
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(titles[Data([1])], "")
    }

    // MARK: - droppedLeaves

    func test_droppedLeaves_namesTheSurfacesThatLeft() {
        let previous = [Data([1]): "one", Data([2]): "two", Data([3]): "three"]
        let current = [Data([3]): "three"]
        let dropped = PeerHostCoordinator.droppedLeaves(previous: previous, current: current)
        XCTAssertEqual(Set(dropped.keys), [Data([1]), Data([2])])
        XCTAssertEqual(dropped[Data([1])], "one")
    }

    func test_droppedLeaves_pureAdditionDropsNothing() {
        // Splitting a pane grows the tree. That must stay silent — only
        // removals cost the viewer anything.
        let previous = [Data([1]): "one"]
        let current = [Data([1]): "one", Data([2]): "two"]
        XCTAssertTrue(
            PeerHostCoordinator.droppedLeaves(previous: previous, current: current).isEmpty
        )
    }

    func test_droppedLeaves_renameIsNotARemoval() {
        // Identity is the surface id, never the title: a tab rename changes
        // every title on the wire, and keying off titles would report the
        // whole workspace as dropped on each rename.
        let previous = [Data([1]): "before"]
        let current = [Data([1]): "after"]
        XCTAssertTrue(
            PeerHostCoordinator.droppedLeaves(previous: previous, current: current).isEmpty
        )
    }

    func test_droppedLeaves_reportsEveryLeafWhenTheTreeEmpties() {
        let previous = [Data([1]): "one", Data([2]): "two"]
        XCTAssertEqual(
            PeerHostCoordinator.droppedLeaves(previous: previous, current: [:]).count,
            2
        )
    }
}
