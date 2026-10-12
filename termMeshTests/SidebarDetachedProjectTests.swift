import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class SidebarDetachedProjectTests: XCTestCase {
    private func member(hostKey: String?, surface: Data?) -> TeamOrchestrator.AgentMember {
        TeamOrchestrator.AgentMember(
            id: "executor@detached-test",
            name: "executor",
            teamName: "detached-test",
            cli: "claude",
            launchCommand: "claude",
            model: "sonnet",
            agentType: "executor",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: nil,
            parentSessionId: nil,
            claudeSessionId: nil,
            claudeSessionIdCapturedAt: nil,
            createdAt: Date(),
            worktreeName: nil,
            worktreePath: nil,
            worktreeBranch: nil,
            remoteSurfaceID: surface,
            remoteSurfaceSpawned: false,
            hostKey: hostKey,
            originalSpawnCommand: nil,
            originalAgentWorkDir: nil,
            autoRecycleEvery: nil,
            completedTaskCount: 0
        )
    }

    func testPreservedPresentationIsRestorableEvenWithLocalAgents() {
        XCTAssertTrue(SidebarDetachedProject.isRestorable(
            hasPreservedPresentation: true,
            agents: [member(hostKey: nil, surface: nil)]
        ))
    }

    func testAllAgentsWithPeerSurfaceAreRestorable() {
        XCTAssertTrue(SidebarDetachedProject.isRestorable(
            hasPreservedPresentation: false,
            agents: [member(hostKey: "host", surface: Data([1]))]
        ))
    }

    func testLocalAgentWithoutPreservedPresentationIsNotRestorable() {
        XCTAssertFalse(SidebarDetachedProject.isRestorable(
            hasPreservedPresentation: false,
            agents: [
                member(hostKey: "host", surface: Data([1])),
                member(hostKey: nil, surface: nil),
            ]
        ))
    }
}
