import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Closing a window used to leave ordinary team panes running with no window.
///
/// `preserveProjectPresentations` filtered on nothing but "this team's
/// workspace is in the closing window", and `unregisterMainWindow` runs it on
/// every main-window close, app quit included. A plain `tm-agent attach` team
/// in an ordinary window was swept up with the projects: `detachWorkspace`
/// deliberately never calls `Panel.close`, so its local shells and native
/// AgentSession processes survived with nothing pointing at them, and because
/// the workspace id was then excluded from `closedWorkspaceIDs` the
/// `.peerWorkspaceDidClose` signal that block exists to post was skipped, so
/// attached peers kept the id in their roster. Only `destroyTeam` reclaimed it.
///
/// The predicate is pure, so the rule is tested here without windows or panes.
final class ProjectPresentationScopeP2Tests: XCTestCase {
    private func shouldPreserve(
        declaredName: Bool = false,
        dedicatedRemote: Bool = false,
        peerLeader: Bool = false
    ) -> Bool {
        TeamOrchestrator.shouldPreserveProjectPresentation(
            hasDeclaredProjectName: declaredName,
            usesDedicatedRemoteWorkspaces: dedicatedRemote,
            hasPeerLeader: peerLeader
        )
    }

    /// The regression itself: an attach-created team is not a project.
    func testPlainAttachTeamIsNotPreserved() {
        XCTAssertFalse(shouldPreserve())
    }

    /// A declared project name is what lets the Projects sidebar adopt the
    /// workspace again later, so it is exactly what makes preserving it
    /// meaningful rather than a leak.
    func testDeclaredProjectNameIsPreserved() {
        XCTAssertTrue(shouldPreserve(declaredName: true))
    }

    func testDedicatedRemoteWorkspacesArePreserved() {
        XCTAssertTrue(shouldPreserve(dedicatedRemote: true))
    }

    /// A peer-hosted leader outlives our window by construction — its panes
    /// are bindings to processes on another machine.
    func testPeerLeaderIsPreserved() {
        XCTAssertTrue(shouldPreserve(peerLeader: true))
    }

    /// Any one qualifying trait is enough; they are not required together.
    func testQualifyingTraitsAreIndependent() {
        XCTAssertTrue(shouldPreserve(declaredName: true, peerLeader: true))
        XCTAssertTrue(shouldPreserve(dedicatedRemote: true, peerLeader: true))
        XCTAssertTrue(
            shouldPreserve(declaredName: true, dedicatedRemote: true, peerLeader: true)
        )
    }

    func testAppQuitKeepsDurablePeerProjectAgentsAlive() {
        XCTAssertFalse(TeamOrchestrator.shouldReleaseRemoteAgentsOnQuit(
            ownsRemotePresentation: true,
            hasPeerLeader: true,
            teamUUID: "durable-team",
            agentSurfacePublished: true
        ))
        XCTAssertTrue(TeamOrchestrator.shouldReleaseRemoteAgentsOnQuit(
            ownsRemotePresentation: true,
            hasPeerLeader: true,
            teamUUID: "not-persisted",
            agentSurfacePublished: false
        ))
        XCTAssertTrue(TeamOrchestrator.shouldReleaseRemoteAgentsOnQuit(
            ownsRemotePresentation: true,
            hasPeerLeader: false,
            teamUUID: "local-team",
            agentSurfacePublished: true
        ))
        XCTAssertTrue(TeamOrchestrator.shouldReleaseRemoteAgentsOnQuit(
            ownsRemotePresentation: false,
            hasPeerLeader: true,
            teamUUID: "borrowed-team",
            agentSurfacePublished: true
        ))
        XCTAssertTrue(TeamOrchestrator.shouldReleaseRemoteAgentsOnQuit(
            ownsRemotePresentation: true,
            hasPeerLeader: true,
            teamUUID: nil,
            agentSurfacePublished: true
        ))
    }
}
