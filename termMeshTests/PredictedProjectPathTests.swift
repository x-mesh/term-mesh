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

    func testRepositoryURLInputKeepsOnlyOneLine() {
        XCTAssertEqual(
            RepositoryURLAutocomplete.singleLine(
                "\n  git@github.com:org/term-mesh.git  \nextra clipboard text"
            ),
            "git@github.com:org/term-mesh.git"
        )
        XCTAssertEqual(
            RepositoryURLAutocomplete.singleLine(
                "Copied from chat https://github.com/org/term-mesh.git ignored second line"
            ),
            "https://github.com/org/term-mesh.git"
        )
        XCTAssertEqual(
            RepositoryURLAutocomplete.singleLine("git@github.com:org/term-mesh.git"),
            "git@github.com:org/term-mesh.git"
        )
    }

    func testRepositoryURLSuggestionsFilterAndHideExactValue() {
        let suggestions = [
            "git@github.com:org/term-mesh.git",
            "https://github.com/org/other.git",
            "https://gitlab.com/org/term-tools.git"
        ]
        XCTAssertEqual(
            RepositoryURLAutocomplete.matches(suggestions, query: "term", limit: 6),
            [
                "git@github.com:org/term-mesh.git",
                "https://gitlab.com/org/term-tools.git"
            ]
        )
        XCTAssertEqual(
            RepositoryURLAutocomplete.matches(
                suggestions,
                query: "git@github.com:org/term-mesh.git",
                limit: 6
            ),
            []
        )
    }

    func testRepositoryDiscoveryFindsProjectsBelowConfiguredRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let direct = root.appendingPathComponent("direct")
        let grouped = root.appendingPathComponent("group/nested")
        let ignored = root.appendingPathComponent(".hidden/project")
        for repository in [direct, grouped, ignored] {
            try FileManager.default.createDirectory(
                at: repository.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
        }

        XCTAssertEqual(
            Set(RepositoryURLAutocomplete.discoverRepositories(under: [root.path])),
            Set([direct.path, grouped.path])
        )
    }

    func testRepositoryOriginIsReadDirectlyFromGitConfig() throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryOrigin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repository) }
        let gitDirectory = repository.appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            at: gitDirectory,
            withIntermediateDirectories: true
        )
        try """
        [core]
            bare = false
        [remote "origin"]
            url = https://token@example.com/org/project.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        """.write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            RepositoryURLAutocomplete.originURLFromConfig(in: repository.path),
            "https://example.com/org/project.git"
        )
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

    func testAgentPlacementCanFollowTheLeader() {
        XCTAssertEqual(
            NewProjectView.resolvedAgentHostKey(
                mode: .sameAsLeader,
                leaderHostKey: "leader-host",
                allAgentsHostKey: "other-host",
                explicitHostKey: "explicit-host",
                inheritsDefault: false
            ),
            "leader-host"
        )
    }

    func testAgentPlacementCanPutEveryoneOnOneMachine() {
        XCTAssertEqual(
            NewProjectView.resolvedAgentHostKey(
                mode: .allOnOneMachine,
                leaderHostKey: "leader-host",
                allAgentsHostKey: "agent-host",
                explicitHostKey: "explicit-host",
                inheritsDefault: false
            ),
            "agent-host"
        )
    }

    func testPerAgentPlacementPreservesOverridesAndLeaderInheritance() {
        XCTAssertEqual(
            NewProjectView.resolvedAgentHostKey(
                mode: .perAgent,
                leaderHostKey: "leader-host",
                allAgentsHostKey: "agent-host",
                explicitHostKey: "explicit-host",
                inheritsDefault: false
            ),
            "explicit-host"
        )
        XCTAssertEqual(
            NewProjectView.resolvedAgentHostKey(
                mode: .perAgent,
                leaderHostKey: "leader-host",
                allAgentsHostKey: "agent-host",
                explicitHostKey: "explicit-host",
                inheritsDefault: true
            ),
            "leader-host"
        )
    }

    func testBootProgressMovesAPlannedStepThroughRunningAndCompleted() {
        let planned = ProjectBootStep(
            id: "leader",
            order: 1_000,
            title: "Start leader",
            detail: "Claude · This Mac",
            command: "claude --model sonnet",
            status: .pending
        )
        var steps = NewProjectView.applying(.planned(planned), to: [])
        XCTAssertEqual(steps.first?.status, .pending)

        steps = NewProjectView.applying(.started(planned), to: steps)
        XCTAssertEqual(steps.first?.status, .running)

        steps = NewProjectView.applying(
            .completed(id: "leader", detail: "Claude launched on This Mac"),
            to: steps
        )
        XCTAssertEqual(steps.first?.status, .completed)
        XCTAssertEqual(steps.first?.detail, "Claude launched on This Mac")
    }

    func testBootProgressKeepsCheckoutBeforeLeaderAndAgents() {
        let leader = ProjectBootStep(
            id: "leader",
            order: 1_000,
            title: "Start leader",
            detail: "",
            command: nil,
            status: .pending
        )
        let checkout = ProjectBootStep(
            id: "checkout:local:/tmp/demo",
            order: 0,
            title: "Clone repository",
            detail: "",
            command: nil,
            status: .running
        )
        let steps = NewProjectView.applying(
            .started(checkout),
            to: [leader]
        )
        XCTAssertEqual(steps.map(\.id), ["checkout:local:/tmp/demo", "leader"])
    }

    func testBootCommandRemovesRepositoryCredentials() {
        XCTAssertEqual(
            ProjectCreationFlow.sanitizedRepositoryURL(
                "https://token:secret@example.com/org/demo.git"
            ),
            "https://example.com/org/demo.git"
        )
    }
}
