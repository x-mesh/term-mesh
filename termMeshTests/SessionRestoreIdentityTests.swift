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
/// These tests cover the saved shape rather than the restore call, because the
/// compatibility question is entirely about what a file written by another
/// build decodes to.
final class SessionRestoreIdentityTests: XCTestCase {
    func test_theWorkspaceIDSurvivesTheSavedForm() throws {
        let id = UUID()
        let saved = SavedSessionState(
            version: 2,
            workspaces: [
                SavedWorkspaceState(
                    id: id,
                    title: "Terminal 1",
                    customTitle: "[term-mesh]",
                    directory: "/tmp",
                    isPinned: false,
                    customColor: nil,
                    paneDirectories: nil,
                    splitTree: nil,
                    focusedPaneId: nil
                )
            ],
            selectedIndex: 0,
            windowFrame: nil
        )

        let round = try JSONDecoder().decode(
            SavedSessionState.self, from: JSONEncoder().encode(saved)
        )
        XCTAssertEqual(round.workspaces.first?.id, id)
        XCTAssertEqual(round.workspaces.first?.customTitle, "[term-mesh]")
    }

    /// A session written before this field existed still has to load. `id` is an
    /// additive optional rather than a version bump for the same reason:
    /// `loadSession` accepts only versions it knows, so bumping would make a
    /// downgrade drop every workspace instead of just the IDs.
    func test_aSessionWrittenWithoutIDsStillLoads() throws {
        let legacy = Data("""
        {
          "version": 2,
          "selectedIndex": 0,
          "workspaces": [
            {"title": "Terminal 1", "directory": "/tmp", "isPinned": false}
          ]
        }
        """.utf8)

        let session = try JSONDecoder().decode(SavedSessionState.self, from: legacy)
        XCTAssertEqual(session.workspaces.count, 1)
        XCTAssertNil(session.workspaces.first?.id)
        XCTAssertEqual(session.version, 2, "the added field must not require a new version")
    }

    /// The restore honors a saved ID, which makes a file listing one ID twice a
    /// way to give two workspaces the same sidecar state. `Workspace` has to
    /// accept an explicit identity for that check to have anything to compare.
    func test_workspaceAcceptsAnExplicitIdentity() async {
        let id = UUID()
        let workspace = await Workspace(id: id, title: "Terminal", workingDirectory: "/tmp")
        let restored = await workspace.id
        XCTAssertEqual(restored, id)
    }
}
