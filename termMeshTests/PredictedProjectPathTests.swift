import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Where a new project lands on another machine.
///
/// The folder is the host's project root plus the project's name, and the name
/// does not exist yet when the machine is chosen — nobody types a name before
/// saying where the project goes. What went wrong was letting the empty name
/// through: it arrived as "/", appending "/" to a path is a no-op, so the
/// predicted folder came out as the root itself. The name was then read back
/// off that folder, and every agent checkout became a sibling of the root
/// instead of living inside the project.
final class PredictedProjectPathTests: XCTestCase {
    private func profile(root: String?) -> PeerHostProfile {
        var p = PeerHostProfile(sshTarget: "root@example")
        p.projectRootPath = root
        return p
    }

    func testJoinsTheRootAndTheName() {
        XCTAssertEqual(
            profile(root: "/app/tm-projects").predictedProjectPath(forProjectNamed: "demo"),
            "/app/tm-projects/demo"
        )
    }

    /// The case that produced the bug: nothing rather than the bare root, so a
    /// caller cannot mistake "no answer" for "put it in the root".
    func testRefusesAnEmptyName() {
        XCTAssertNil(profile(root: "/app/tm-projects").predictedProjectPath(forProjectNamed: ""))
    }

    func testNeedsARoot() {
        XCTAssertNil(profile(root: nil).predictedProjectPath(forProjectNamed: "demo"))
        XCTAssertNil(profile(root: "   ").predictedProjectPath(forProjectNamed: "demo"))
    }

    /// The placeholder has to be a real path component, because it is what
    /// stands in until a name is typed.
    func testThePlaceholderProducesAFolderInsideTheRoot() {
        let predicted = profile(root: "/app/tm-projects")
            .predictedProjectPath(forProjectNamed: NewProjectView.placeholderProjectName)
        XCTAssertEqual(predicted, "/app/tm-projects/\(NewProjectView.placeholderProjectName)")
        XCTAssertNotEqual(predicted, "/app/tm-projects", "a placeholder that collapses is the bug")
    }

    /// Each member's checkout sits beside the project, not beside the root.
    func testAgentCheckoutsLiveNextToTheProject() {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/app/tm-projects",
            projectName: "demo",
            agents: ["executor"],
            isolateAgents: true
        )
        XCTAssertEqual(plan.primaryPath, "/app/tm-projects/demo")
        XCTAssertEqual(plan.agentCheckouts.first?.path, "/app/tm-projects/demo-executor")
    }

    func testRepositoryURLsInferAProjectName() {
        XCTAssertEqual(
            NewProjectView.projectName(fromRepositoryURL: "git@github.com:org/term-mesh.git"),
            "term-mesh"
        )
        XCTAssertEqual(
            NewProjectView.projectName(fromRepositoryURL: "https://github.com/org/term-mesh.git/"),
            "term-mesh"
        )
        XCTAssertEqual(
            NewProjectView.projectName(fromRepositoryURL: "ssh://git@example.com/org/my%20app.git"),
            "my app"
        )
    }

    func testIncompleteRepositoryURLsDoNotInventAName() {
        XCTAssertNil(NewProjectView.projectName(fromRepositoryURL: ""))
        XCTAssertNil(NewProjectView.projectName(fromRepositoryURL: "repository"))
        XCTAssertNil(NewProjectView.projectName(fromRepositoryURL: "https://github.com/"))
    }

    func testEmptyNameStillInfersWhenSwiftUIMarkedItEdited() {
        XCTAssertTrue(
            NewProjectView.shouldInferProjectName(
                currentName: "",
                nameWasEdited: true
            )
        )
        XCTAssertTrue(
            NewProjectView.shouldInferProjectName(
                currentName: "   ",
                nameWasEdited: true
            )
        )
    }

    func testExplicitNonEmptyNameIsPreserved() {
        XCTAssertFalse(
            NewProjectView.shouldInferProjectName(
                currentName: "my-custom-name",
                nameWasEdited: true
            )
        )
    }
}
