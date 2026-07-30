import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A project that names itself, and the sidebar grouping it has to agree with.
@MainActor
final class WorkspaceProjectNamesTests: XCTestCase {
    private let workspace = UUID()

    override func tearDown() {
        WorkspaceProjectNames.shared.forget(workspaceId: workspace)
        super.tearDown()
    }

    /// The invariant that matters: a declared project and one inferred from a
    /// checkout of the same name are ONE group. Different keys would list the
    /// same project twice — once for the machine that declared it, once for
    /// the machine whose paths gave it away.
    func testDeclaredAndInferredIdentitiesMatch() {
        WorkspaceProjectNames.shared.declare(workspaceId: workspace, projectName: "git-catcher")
        let declared = WorkspaceProjectNames.shared.identity(for: workspace)
        let inferred = projectIdentity(forWorkingDirectories: ["/app/tm-projects/git-catcher"])
        XCTAssertEqual(declared?.key, inferred.key)
        XCTAssertFalse(declared?.isUnknown ?? true)
    }

    /// Case is not identity — the key is lowercased on both paths.
    func testNameCaseDoesNotSplitTheGroup() {
        WorkspaceProjectNames.shared.declare(workspaceId: workspace, projectName: "Git-Catcher")
        XCTAssertEqual(
            WorkspaceProjectNames.shared.identity(for: workspace)?.key,
            projectIdentity(forWorkingDirectories: ["/app/tm-projects/git-catcher"]).key
        )
    }

    func testUndeclaredWorkspacesStayOutOfIt() {
        XCTAssertNil(WorkspaceProjectNames.shared.identity(for: UUID()))
    }

    func testAnEmptyNameDeclaresNothing() {
        WorkspaceProjectNames.shared.declare(workspaceId: workspace, projectName: "   ")
        XCTAssertNil(WorkspaceProjectNames.shared.identity(for: workspace))
    }

    /// The case that sent the project to Unassigned: a remote project's local
    /// panes sit in a home directory, which names no project at all. Declaring
    /// is what rescues it.
    func testDeclaringRescuesAWorkspaceWhosePathsNameNothing() {
        XCTAssertTrue(
            projectIdentity(forWorkingDirectories: ["/Users/jinwoo"]).isUnknown,
            "a home directory is not a project"
        )
        WorkspaceProjectNames.shared.declare(workspaceId: workspace, projectName: "git-catcher")
        XCTAssertEqual(WorkspaceProjectNames.shared.identity(for: workspace)?.label, "git-catcher")
    }

    /// Per-member checkouts are separate folders on purpose, so the path rule
    /// reads them as separate projects. Only the declared name holds the
    /// project together.
    func testMemberCheckoutsWouldOtherwiseSplitTheProject() {
        let executor = projectIdentity(forWorkingDirectories: ["/app/tm-projects/git-catcher-executor"])
        let architect = projectIdentity(forWorkingDirectories: ["/app/tm-projects/git-catcher-architect"])
        XCTAssertNotEqual(executor.key, architect.key)
        WorkspaceProjectNames.shared.declare(workspaceId: workspace, projectName: "git-catcher")
        let declared = WorkspaceProjectNames.shared.identity(for: workspace)
        XCTAssertNotEqual(declared?.key, executor.key)
        XCTAssertNotEqual(declared?.key, architect.key)
    }
}
