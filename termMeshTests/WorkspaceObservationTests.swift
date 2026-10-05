import XCTest
import Observation

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// What `Workspace` announces, and what it deliberately does not.
///
/// Moving to `@Observable` changed the unit of invalidation from the object to
/// the property, which is the point — but it also changed two things that are
/// easy to get wrong and impossible to see by reading the diff:
///
/// 1. Properties that were never `@Published` become observed by default. Three
///    of them were unpublished on purpose, because terminal titles change on
///    every prompt and waking the sidebar for each one was measurably
///    expensive. `@ObservationIgnored` restores that silence; these tests hold
///    it in place.
/// 2. A lazily-filled cache that is itself unobserved leaves a *cache hit*
///    with no registered dependency at all. The row draws once and then never
///    hears about the change that emptied the cache. Version counters carry
///    that dependency, and the tests below fail without them.
@MainActor
final class WorkspaceObservationTests: XCTestCase {

    private func workspace(directory: String = "/tmp") -> Workspace {
        Workspace(title: "Terminal", workingDirectory: directory)
    }

    // MARK: - Silence that has to be preserved

    /// A terminal rewrites `processTitle` continuously. Publishing that stream
    /// woke every sidebar subscriber for a string most of them never draw, so
    /// it was kept off `@Published` — and has to stay off observation.
    func testTerminalTitleChurnDoesNotWakeSidebarReaders() {
        let ws = workspace()
        let woke = expectation(description: "sidebar readers must stay asleep")
        woke.isInverted = true
        withObservationTracking {
            _ = ws.title
            _ = ws.panels.count
            _ = ws.gitBranch
        } onChange: { woke.fulfill() }

        ws.processTitle = "vim ~/.zshrc"
        ws.surfaceTTYNames[UUID()] = "ttys004"
        ws.manualUnreadMarkedAt[UUID()] = Date()

        wait(for: [woke], timeout: 0.2)
    }

    // MARK: - Freshness the caches would otherwise lose

    /// The regression this exists for: a row drawn from a warm cache reads only
    /// `@ObservationIgnored` storage, so without a version counter it registers
    /// no dependency and stops redrawing. Change a branch, and the sidebar
    /// keeps showing the old one forever.
    ///
    /// Delete the `_ = sidebarBranchDataVersion` reads in `Workspace` and this
    /// fails — that is what makes it worth keeping.
    func testABranchChangeReachesRowsDrawnFromAWarmCache() {
        let ws = workspace()
        // Warm both caches, so the tracked read below is a pure cache hit.
        _ = ws.sidebarBranchDirectoryEntriesInDisplayOrder()
        _ = ws.sidebarBranchDirectoryDisplayLines(showGitBranch: true)

        let redrew = expectation(description: "row must be invalidated")
        withObservationTracking {
            _ = ws.sidebarBranchDirectoryDisplayLines(showGitBranch: true)
        } onChange: { redrew.fulfill() }

        ws.gitBranch = SidebarGitBranchState(branch: "feature/x", isDirty: false)

        wait(for: [redrew], timeout: 1)
    }

    /// Same shape for the remote-host chip, which caches on the focused panel.
    func testAPanelChangeReachesTheHostChipDrawnFromAWarmCache() {
        let ws = workspace()
        _ = ws.dominantRemoteHostKey

        let redrew = expectation(description: "host chip must be invalidated")
        withObservationTracking {
            _ = ws.dominantRemoteHostKey
        } onChange: { redrew.fulfill() }

        ws.panels[UUID()] = AgentPanel(agentName: "probe", teamName: "t", workingDirectory: "/tmp")

        wait(for: [redrew], timeout: 1)
    }

    // MARK: - Peer viewers

    /// A peer viewer's sidebar named a pane by the folder it was attached in,
    /// long after the shell had moved: a directory change never reached the
    /// host's workspace broadcast. Repeated prompts in one folder must not
    /// rebroadcast it.
    func testADirectoryChangeIsAnnouncedToPeerViewersOnlyWhenItChanges() throws {
        let ws = workspace()
        let panelId = try XCTUnwrap(ws.focusedPanelId)
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .peerWorkspaceLayoutDidChange, object: nil, queue: nil
        ) { note in
            if note.userInfo?["workspaceID"] as? UUID == ws.id { announcements += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        ws.updatePanelDirectory(panelId: panelId, directory: "/tmp/peer-cwd-a")
        let afterFirst = announcements
        ws.updatePanelDirectory(panelId: panelId, directory: "/tmp/peer-cwd-a")
        XCTAssertEqual(announcements, afterFirst, "the same folder again must not rebroadcast")
        ws.updatePanelDirectory(panelId: panelId, directory: "/tmp/peer-cwd-b")

        XCTAssertGreaterThanOrEqual(afterFirst, 1)
        XCTAssertEqual(announcements, afterFirst + 1)
    }

    /// Only a pane's selected tab has its folder on the wire, so a background
    /// tab moving must not make the host rebroadcast.
    func testABackgroundTabsDirectoryChangeIsNotAnnounced() throws {
        let ws = workspace()
        let firstPanel = try XCTUnwrap(ws.focusedPanelId)
        let pane = try XCTUnwrap(ws.paneId(forPanelId: firstPanel))
        let second = try XCTUnwrap(ws.newTerminalSurface(inPane: pane, focus: true))
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .peerWorkspaceLayoutDidChange, object: nil, queue: nil
        ) { note in
            if note.userInfo?["workspaceID"] as? UUID == ws.id { announcements += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        ws.updatePanelDirectory(panelId: firstPanel, directory: "/tmp/peer-cwd-background")
        XCTAssertEqual(announcements, 0, "the first tab is in the background")
        ws.updatePanelDirectory(panelId: second.id, directory: "/tmp/peer-cwd-selected")
        XCTAssertEqual(announcements, 1)
    }

    // MARK: - The callback that replaced a Combine publisher

    /// `TabManager` used to reach this through
    /// `$currentDirectory.dropFirst().removeDuplicates()`. `@Observable` has no
    /// publisher, so the workspace calls back — and the callback has to carry
    /// both operators, or session state is written on every launch and on
    /// every no-op assignment.
    func testDirectoryCallbackCarriesDropFirstAndRemoveDuplicates() {
        var calls = 0
        let ws = workspace(directory: "/tmp")
        ws.onCurrentDirectoryChange = { calls += 1 }

        // dropFirst: the value set during init must not have fired. The
        // callback is attached after init, so this asserts the shape rather
        // than the timing — an eager publisher would have replayed it here.
        XCTAssertEqual(calls, 0, "initial value must not fire")

        // removeDuplicates: assigning the same path is not a change.
        ws.currentDirectory = "/tmp"
        XCTAssertEqual(calls, 0, "unchanged path must not fire")

        ws.currentDirectory = "/tmp/elsewhere"
        XCTAssertEqual(calls, 1, "a real change fires exactly once")

        ws.currentDirectory = "/tmp/elsewhere"
        XCTAssertEqual(calls, 1, "and does not fire again for the same value")
    }

    /// The UI-test harnesses wait on a pane closing from outside SwiftUI, and
    /// they may attach *after* the close they are waiting for. `$panels`
    /// delivered the current value on subscribe; `CurrentValueSubject` keeps
    /// that, `PassthroughSubject` would hang until a second change.
    func testPanelCountSubjectReplaysTheCurrentValueOnSubscribe() {
        let ws = workspace()
        // A workspace opens with a pane already in it, so count from what is
        // there rather than from zero.
        let base = ws.panels.count
        ws.panels[UUID()] = AgentPanel(agentName: "probe", teamName: "t", workingDirectory: "/tmp")

        var seen: [Int] = []
        let token = ws.panelsCountSubject.sink { seen.append($0) }
        defer { token.cancel() }

        XCTAssertEqual(seen, [base + 1], "a late subscriber still learns the current count")

        ws.panels[UUID()] = AgentPanel(agentName: "probe", teamName: "t", workingDirectory: "/tmp")
        XCTAssertEqual(seen, [base + 1, base + 2], "and subsequent changes arrive")
    }
}
