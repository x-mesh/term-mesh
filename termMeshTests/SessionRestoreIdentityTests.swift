import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// `session.json` restored a workspace's panes, title, and directory but not
/// its identity, so every relaunch handed the same workspace a new UUID. Every
/// sidecar keyed by that UUID — the project declaration that decides where a
/// hosted session's pane belongs, first among them — was therefore unreachable
/// after a restart, and the code reading it concluded the state had never
/// existed.
///
/// The feature that shipped the bug had passing tests: they fed
/// `declaredProjects` in as an argument, so no assertion could reach the state
/// a restart produces. These tests therefore drive the real
/// `savedSessionState()` / `restoreSessionForTests(_:)` round trip rather than
/// a hand-built struct, which is the only place the defect was ever visible.
@MainActor
final class SessionRestoreIdentityTests: XCTestCase {
    private func manager() -> TabManager {
        TabManager(persistsSessionState: false)
    }

    private func savedWorkspace(
        id: UUID?,
        title: String = "Terminal 1",
        customTitle: String? = nil
    ) -> SavedWorkspaceState {
        SavedWorkspaceState(
            id: id,
            title: title,
            customTitle: customTitle,
            directory: NSTemporaryDirectory(),
            isPinned: false,
            customColor: nil,
            paneDirectories: nil,
            splitTree: nil,
            focusedPaneId: nil
        )
    }

    private func session(_ workspaces: [SavedWorkspaceState]) -> SavedSessionState {
        SavedSessionState(
            version: 2, workspaces: workspaces, selectedIndex: 0, windowFrame: nil
        )
    }

    // MARK: - The round trip the bug lived in

    func test_theSavedStateCarriesEachWorkspaceIdentity() {
        let tabs = manager()
        let live = tabs.tabs.map(\.id)
        XCTAssertFalse(live.isEmpty, "a fresh manager owns at least one workspace")

        let saved = tabs.savedSessionState()
        XCTAssertEqual(
            saved.workspaces.compactMap(\.id), live,
            "a workspace whose ID is not written cannot be restored under it"
        )
    }

    func test_theRestoreKeepsEachSavedIdentity() {
        let tabs = manager()
        let first = UUID()
        let second = UUID()

        tabs.restoreSessionForTests(session([
            savedWorkspace(id: first),
            savedWorkspace(id: second, title: "Terminal 2"),
        ]))

        XCTAssertEqual(tabs.tabs.map(\.id), [first, second])
    }

    /// The whole point of persisting the ID: a UUID-keyed sidecar written
    /// before the restart is still reachable after it.
    func test_aDeclarationSurvivesTheRoundTrip() {
        let tabs = manager()
        let workspace = tabs.tabs[0]
        WorkspaceProjectNames.shared.declare(
            workspaceId: workspace.id, projectName: "term-mesh"
        )
        defer { WorkspaceProjectNames.shared.forget(workspaceId: workspace.id) }

        let saved = tabs.savedSessionState()
        let relaunched = manager()
        relaunched.restoreSessionForTests(saved)

        XCTAssertEqual(
            relaunched.tabs.compactMap {
                WorkspaceProjectNames.shared.projectName(for: $0.id)
            },
            ["term-mesh"],
            "the declaration is unreachable again if the restore mints a new ID"
        )
    }

    /// Two workspaces under one ID would share every UUID-keyed sidecar, so a
    /// file that repeats one — hand-edited, or merged from two installs — must
    /// not be taken at face value.
    func test_aRepeatedIdentityIsNotHandedToTwoWorkspaces() {
        let tabs = manager()
        let shared = UUID()

        tabs.restoreSessionForTests(session([
            savedWorkspace(id: shared),
            savedWorkspace(id: shared, title: "Terminal 2"),
        ]))

        XCTAssertEqual(tabs.tabs.count, 2)
        XCTAssertEqual(tabs.tabs[0].id, shared, "the first claim keeps the saved ID")
        XCTAssertNotEqual(tabs.tabs[1].id, shared, "the second gets a fresh one")
    }

    /// A session written before this field existed still has to load. `id` is an
    /// additive optional rather than a version bump for the same reason:
    /// `loadSavedSession` accepts only versions it knows, so bumping would make
    /// a downgrade drop every workspace instead of just the IDs.
    func test_aSessionWrittenWithoutIdentitiesStillLoads() throws {
        let legacy = Data("""
        {
          "version": 2,
          "selectedIndex": 0,
          "workspaces": [
            {"title": "Terminal 1", "directory": "/tmp", "isPinned": false}
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(SavedSessionState.self, from: legacy)
        XCTAssertNil(decoded.workspaces.first?.id)
        XCTAssertEqual(decoded.version, 2, "the added field must not require a new version")

        let tabs = manager()
        tabs.restoreSessionForTests(decoded)
        XCTAssertEqual(tabs.tabs.count, 1, "an ID-less session restores as it always did")
    }

    /// `loadSavedSession` decodes before it version-gates and turns any thrown
    /// error into "no session", so a malformed `id` must not be allowed to
    /// throw — one bad string would drop every saved workspace.
    func test_aMalformedIdentityCostsOnlyTheIdentity() throws {
        let corrupt = Data("""
        {
          "version": 2,
          "selectedIndex": 0,
          "workspaces": [
            {"id": "", "title": "Terminal 1", "directory": "/tmp", "isPinned": false},
            {"id": "not-a-uuid", "title": "Terminal 2", "directory": "/tmp", "isPinned": false}
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(SavedSessionState.self, from: corrupt)
        XCTAssertEqual(decoded.workspaces.count, 2, "the session survives a bad ID")
        XCTAssertNil(decoded.workspaces[0].id)
        XCTAssertNil(decoded.workspaces[1].id)
        XCTAssertEqual(decoded.workspaces[1].title, "Terminal 2", "the rest still decodes")
    }

    // MARK: - Whose identities these are

    /// `sessionFilePath` is shared across Debug and Release on purpose, so a
    /// tagged Debug app running beside the release one restores the same file.
    /// Adopting the other build's IDs would give two live processes workspaces
    /// under identical UUIDs, and that UUID is how a socket command addresses a
    /// workspace.
    func test_anotherBuildsIdentitiesAreNotAdopted() {
        let foreign = UUID()
        let written = SavedSessionState(
            version: 2,
            workspaces: [savedWorkspace(id: foreign, customTitle: "[term-mesh]")],
            selectedIndex: 0,
            windowFrame: nil,
            writerBundleID: "com.termmesh.app.some-other-build"
        )
        XCTAssertFalse(written.identitiesBelongToThisBuild)

        let tabs = manager()
        tabs.restoreSessionForTests(written)

        XCTAssertEqual(tabs.tabs.count, 1, "the layout still restores")
        XCTAssertNotEqual(tabs.tabs[0].id, foreign)
        XCTAssertEqual(
            tabs.tabs[0].customTitle, "[term-mesh]",
            "the title carries the project, so routing still recognizes it"
        )
    }

    func test_aSessionWithNoWriterKeepsItsIdentitiesToItself() {
        let orphan = SavedSessionState(
            version: 2,
            workspaces: [savedWorkspace(id: UUID())],
            selectedIndex: 0,
            windowFrame: nil,
            writerBundleID: nil
        )
        XCTAssertFalse(
            orphan.identitiesBelongToThisBuild,
            "a session written before the field existed names no owner"
        )
    }

    func test_thisBuildAdoptsWhatItWrote() {
        let tabs = manager()
        let saved = tabs.savedSessionState()
        XCTAssertEqual(saved.writerBundleID, Bundle.main.bundleIdentifier)
        XCTAssertTrue(saved.identitiesBelongToThisBuild)
    }

    // MARK: - Forgetting

    func test_closingAWorkspaceForgetsItsProjectDeclaration() {
        let tabs = manager()
        let workspace = tabs.addWorkspace(select: false)
        WorkspaceProjectNames.shared.declare(
            workspaceId: workspace.id, projectName: "term-mesh"
        )
        defer { WorkspaceProjectNames.shared.forget(workspaceId: workspace.id) }

        tabs.closeWorkspace(workspace)

        XCTAssertNil(
            WorkspaceProjectNames.shared.projectName(for: workspace.id),
            "a declaration the workspace can no longer own is never revoked otherwise"
        )
    }

    /// Team and peer-mirror workspaces are excluded from the saved session and
    /// end with the process rather than through a close, so `forget` never sees
    /// them. Their declarations named an ID no launch can produce again.
    func test_theRestoreDropsDeclarationsNoWorkspaceCanClaim() {
        let dead = UUID()
        WorkspaceProjectNames.shared.declare(workspaceId: dead, projectName: "gone")
        defer { WorkspaceProjectNames.shared.forget(workspaceId: dead) }

        let survivor = UUID()
        WorkspaceProjectNames.shared.declare(workspaceId: survivor, projectName: "term-mesh")
        defer { WorkspaceProjectNames.shared.forget(workspaceId: survivor) }

        let tabs = manager()
        tabs.restoreSessionForTests(session([savedWorkspace(id: survivor)]))

        XCTAssertNil(WorkspaceProjectNames.shared.projectName(for: dead))
        XCTAssertEqual(
            WorkspaceProjectNames.shared.projectName(for: survivor), "term-mesh",
            "a restored workspace keeps the declaration it is about to need"
        )
    }
}
