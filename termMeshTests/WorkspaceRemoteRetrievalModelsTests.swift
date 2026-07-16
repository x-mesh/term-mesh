import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class WorkspaceRemoteRetrievalModelsTests: XCTestCase {
    func test_typedID_roundTripsWithoutLosingIdentity() throws {
        let id = RemoteSessionID(rawValue: UUID(uuidString: "6E4B5423-EAA7-448A-85FD-2BB8B7842E22")!)

        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(RemoteSessionID.self, from: data)

        XCTAssertEqual(decoded, id)
    }

    func test_temporaryDirtyOwnedPane_requiresCheckpointBeforeClose() {
        let action = RemotePaneSafetyPolicy.closeAction(
            lifetime: .temporary,
            bindingRole: .owned,
            hasUncollectedChanges: true,
            state: .running
        )

        XCTAssertEqual(action, .requireCheckpoint)
    }

    func test_cleanTemporaryOwnedPane_canTerminate() {
        let action = RemotePaneSafetyPolicy.closeAction(
            lifetime: .temporary,
            bindingRole: .owned,
            hasUncollectedChanges: false,
            state: .readyToClose
        )

        XCTAssertEqual(action, .terminateSession)
    }

    func test_keepAliveOrLinkedPane_closeOnlyDetachesBinding() {
        XCTAssertEqual(
            RemotePaneSafetyPolicy.closeAction(
                lifetime: .keepAlive,
                bindingRole: .owned,
                hasUncollectedChanges: true,
                state: .running
            ),
            .detachBinding
        )
        XCTAssertEqual(
            RemotePaneSafetyPolicy.closeAction(
                lifetime: .temporary,
                bindingRole: .linked,
                hasUncollectedChanges: true,
                state: .running
            ),
            .detachBinding
        )
    }

    func test_recoveryRequiredPane_cannotBeClosed() {
        let action = RemotePaneSafetyPolicy.closeAction(
            lifetime: .temporary,
            bindingRole: .owned,
            hasUncollectedChanges: false,
            state: .recoveryRequired
        )

        XCTAssertEqual(action, .blockForRecovery)
    }

    func test_crossWorkspaceTemporaryLink_requiresKeepAlivePromotion() {
        let source = UUID()
        let destination = UUID()

        XCTAssertEqual(
            RemotePaneSafetyPolicy.linkDecision(
                lifetime: .temporary,
                sourceWorkspaceID: source,
                destinationWorkspaceID: destination
            ),
            .promoteToKeepAlive
        )
        XCTAssertEqual(
            RemotePaneSafetyPolicy.linkDecision(
                lifetime: .keepAlive,
                sourceWorkspaceID: source,
                destinationWorkspaceID: destination
            ),
            .link
        )
    }

    func test_lifecycle_allowsCheckpointFlowButNotUnsafeClose() {
        XCTAssertTrue(RemotePaneLifecycleState.running.canTransition(to: .checkpointing))
        XCTAssertTrue(RemotePaneLifecycleState.checkpointing.canTransition(to: .readyToClose))
        XCTAssertTrue(RemotePaneLifecycleState.readyToClose.canTransition(to: .closed))
        XCTAssertFalse(RemotePaneLifecycleState.running.canTransition(to: .closed))
        XCTAssertFalse(RemotePaneLifecycleState.closed.canTransition(to: .running))
    }

    func test_defaultPresentation_isBottomDrawer() {
        XCTAssertEqual(WorkspaceRetrievalPresentation.defaultPresentation, .drawer)
        XCTAssertEqual(Set(WorkspaceRetrievalPresentation.allCases), [.sidebar, .drawer, .inspector])
    }
}
