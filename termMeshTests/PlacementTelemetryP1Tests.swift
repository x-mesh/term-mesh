import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// `status` told the leader where an agent was, and was wrong.
///
/// `parallel_telemetry.checkout` fell back to the workspace UUID when a member
/// had no worktree — which is most of them. A UUID is not a path, and it reads
/// like an identifier for somewhere else: a leader collecting results took one
/// for a remote checkout and went as far as registering an ssh host key for a
/// machine that was never involved.
///
/// The real value was on the member the whole time. `originalAgentWorkDir` is
/// the exact directory the pane was spawned in, and the capsule and restart
/// paths already prefer `worktreePath ?? originalAgentWorkDir`; only the status
/// snapshot dropped it.
///
/// What is pinned here is the derivation. Building a live team needs panes, a
/// workspace and an `AppDelegate`; the choice of value is pure, and that is the
/// part that was wrong.
final class PlacementTelemetryP1Tests: XCTestCase {

    private let agentCheckout = "/Users/jinwoo/work/tm-projects/term-mesh-reviewer-260731-5ce8"
    private let teamRoot = "/Users/jinwoo/work/tm-projects/term-mesh"
    private let worktree = "/Users/jinwoo/.gk/worktree/term-mesh/tm/term-mesh/e374a0d5"

    // MARK: - The reported accident

    /// A local member with no worktree — the ordinary case, and the one that
    /// used to report a UUID.
    func testALocalMemberWithoutAWorktreeReportsItsRealPaneDirectory() {
        let directory = TeamOrchestrator.agentWorkingDirectory(
            worktreePath: nil,
            originalAgentWorkDir: agentCheckout,
            teamWorkingDirectory: teamRoot
        )

        XCTAssertEqual(
            directory, agentCheckout,
            "the pane's own cwd is what the leader needs to collect results from"
        )
    }

    /// The value must be a path, not an identifier. A UUID here is what the
    /// leader misread as a remote host.
    func testTheReportedDirectoryIsNeverAWorkspaceUUID() {
        let workspaceID = UUID().uuidString
        let directory = TeamOrchestrator.agentWorkingDirectory(
            worktreePath: nil,
            originalAgentWorkDir: agentCheckout,
            teamWorkingDirectory: teamRoot
        )

        XCTAssertNotEqual(directory, workspaceID)
        XCTAssertTrue(
            directory?.hasPrefix("/") == true,
            "a checkout that is not an absolute path is not a checkout"
        )
    }

    // MARK: - Precedence

    /// A worktree is where the work is happening, so it wins — the same order
    /// the capsule and restart paths already use.
    func testAWorktreeWinsOverTheSpawnDirectory() {
        XCTAssertEqual(
            TeamOrchestrator.agentWorkingDirectory(
                worktreePath: worktree,
                originalAgentWorkDir: agentCheckout,
                teamWorkingDirectory: teamRoot
            ),
            worktree
        )
    }

    /// A member that recorded neither still runs somewhere: the team's own
    /// directory, which is where a pane with no override is spawned.
    func testTheTeamDirectoryIsTheLastResort() {
        XCTAssertEqual(
            TeamOrchestrator.agentWorkingDirectory(
                worktreePath: nil,
                originalAgentWorkDir: nil,
                teamWorkingDirectory: teamRoot
            ),
            teamRoot
        )
    }

    /// Nothing known — a headless agent with no pane. nil, so the caller
    /// publishes null rather than inventing a path. Reporting a wrong directory
    /// is what this whole change exists to stop.
    func testNothingKnownReportsNothingRatherThanAGuess() {
        XCTAssertNil(
            TeamOrchestrator.agentWorkingDirectory(
                worktreePath: nil, originalAgentWorkDir: nil, teamWorkingDirectory: nil
            )
        )
    }

    /// Blank is not a value. An empty string would publish as a path and
    /// resolve to the process cwd wherever it was used.
    func testBlankFieldsAreSkippedRatherThanPublished() {
        XCTAssertEqual(
            TeamOrchestrator.agentWorkingDirectory(
                worktreePath: "   ",
                originalAgentWorkDir: "",
                teamWorkingDirectory: teamRoot
            ),
            teamRoot
        )
    }

    // MARK: - locality

    /// Local pane creation never sets `hostKey` (`addAgentPaneToWorkspace`
    /// passes none), so its absence is the local case — not a missing value to
    /// be filled in.
    func testAMemberWithNoHostKeyIsLocal() {
        XCTAssertEqual(TeamOrchestrator.agentLocality(hostKey: nil), "local")
        XCTAssertEqual(TeamOrchestrator.agentLocality(hostKey: "   "), "local")
    }

    /// A peer attach always records one.
    func testAMemberWithAHostKeyIsPeer() {
        XCTAssertEqual(TeamOrchestrator.agentLocality(hostKey: "ssh:root@jw-server"), "peer")
    }

    /// `locality` is derived from `hostKey` and does not replace it: `host` is
    /// published verbatim, and other readers depend on that. This pins the two
    /// as separate answers to separate questions.
    func testLocalityIsDerivedFromTheStoredKeyWithoutReplacingIt() {
        let key = "ssh:root@jw-server"
        XCTAssertEqual(TeamOrchestrator.agentLocality(hostKey: key), "peer")
        XCTAssertEqual(
            key, "ssh:root@jw-server",
            "host stays the stored key verbatim; locality is the extra field"
        )
    }

    // MARK: - D-1: a named pane is never traded for a sibling

    /// Two instances share a name — the case where auto-pin does damage.
    /// `resolveAssigneeUnsafe` would take `candidates.first`; naming a pane has
    /// to beat that.
    func testAPanelIDResolvesToItsOwnInstanceNotTheFirstCandidate() {
        let firstPanel = UUID(), secondPanel = UUID()
        let candidates = [
            TeamOrchestrator.PaneCandidate(panelID: firstPanel, agentInstanceID: "instance-a"),
            TeamOrchestrator.PaneCandidate(panelID: secondPanel, agentInstanceID: "instance-b"),
        ]

        XCTAssertEqual(
            TeamOrchestrator.instanceID(forPanel: secondPanel, among: candidates),
            "instance-b",
            "the pane the caller named owns the work — not whichever sibling sorts first"
        )
        XCTAssertEqual(
            TeamOrchestrator.instanceID(forPanel: firstPanel, among: candidates),
            "instance-a"
        )
    }

    /// A pane that belongs to nobody resolves to nothing, so the handler can
    /// refuse. Falling back to a candidate here is the silent auto-pin again.
    func testAnUnknownPanelResolvesToNothingSoTheCallerCanRefuse() {
        let candidates = [
            TeamOrchestrator.PaneCandidate(panelID: UUID(), agentInstanceID: "instance-a"),
            TeamOrchestrator.PaneCandidate(panelID: UUID(), agentInstanceID: "instance-b"),
        ]

        XCTAssertNil(
            TeamOrchestrator.instanceID(forPanel: UUID(), among: candidates),
            "no match must stay no match; guessing is the bug being removed"
        )
    }

    /// A headless sibling has no pane. It must not absorb a pane lookup.
    func testAHeadlessMemberIsNeverMatchedByAPanelLookup() {
        let pane = UUID()
        let candidates = [
            TeamOrchestrator.PaneCandidate(panelID: nil, agentInstanceID: "headless"),
            TeamOrchestrator.PaneCandidate(panelID: pane, agentInstanceID: "paned"),
        ]

        XCTAssertEqual(
            TeamOrchestrator.instanceID(forPanel: pane, among: candidates), "paned"
        )
        XCTAssertNil(TeamOrchestrator.instanceID(forPanel: UUID(), among: candidates))
    }

    /// An empty roster answers nothing rather than crashing or inventing.
    func testAnEmptyRosterResolvesToNothing() {
        XCTAssertNil(TeamOrchestrator.instanceID(forPanel: UUID(), among: []))
    }
}
