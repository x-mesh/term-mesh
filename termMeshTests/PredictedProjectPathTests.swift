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
    func testNewProjectLeaderDefaultsToClaudeOpus() {
        XCTAssertEqual(NewProjectView.defaultLeaderModel(for: "claude"), "opus")
        XCTAssertEqual(
            NewProjectView.defaultLeaderModel(for: "codex"),
            AgentRolePreset.defaultModel(for: "codex")
        )
    }

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

    func testRemoteBranchesParseDefaultAndSortItFirst() {
        let result = RepositoryBranchLookup.parse(
            """
            ref: refs/heads/main\tHEAD
            aaaaaaaa\tHEAD
            bbbbbbbb\trefs/heads/release/v2
            aaaaaaaa\trefs/heads/main
            cccccccc\trefs/heads/develop
            """
        )

        XCTAssertEqual(result.defaultBranch, "main")
        XCTAssertEqual(result.branches, ["main", "develop", "release/v2"])
    }

    func testBranchSearchSupportsPartialNamesAndExcludesSelection() {
        XCTAssertEqual(
            RepositoryBranchLookup.matches(
                ["main", "feature/auth", "feature/search", "release/v2"],
                query: "feature",
                excluding: "feature/auth",
                limit: 8
            ),
            ["feature/search"]
        )
        XCTAssertEqual(
            RepositoryBranchLookup.singleLine("release/v2\nmain"),
            "release/v2"
        )
    }

    /// Tab completes only as far as every candidate agrees. Completing to the
    /// first match would pick one of several valid branches for the person,
    /// and the wrong branch is not a visible typo — it is a clone of the
    /// wrong code.
    func testBranchTabCompletionStopsAtTheSharedPrefix() {
        let branches = ["main", "feature/auth", "feature/search", "release/v2"]
        XCTAssertEqual(
            RepositoryBranchLookup.completion(for: "fea", in: branches),
            "feature/",
            "two candidates agree up to the slash and no further"
        )
        XCTAssertEqual(
            RepositoryBranchLookup.completion(for: "feature/s", in: branches),
            "feature/search",
            "one candidate completes fully"
        )
        XCTAssertEqual(
            RepositoryBranchLookup.completion(for: "rel", in: branches),
            "release/v2"
        )
    }

    /// Nothing to add means Tab keeps its normal job of moving focus.
    func testBranchTabCompletionYieldsWhenItCannotAdd() {
        let branches = ["main", "feature/auth", "feature/search"]
        XCTAssertNil(RepositoryBranchLookup.completion(for: "main", in: branches),
                     "already complete")
        XCTAssertNil(RepositoryBranchLookup.completion(for: "nope", in: branches),
                     "no candidate")
        XCTAssertNil(RepositoryBranchLookup.completion(for: "feature/", in: branches),
                     "candidates diverge immediately")
        XCTAssertNil(RepositoryBranchLookup.completion(for: "", in: ["main", "dev"]),
                     "an empty field has no shared prefix to offer")
    }

    /// Matching ignores case; the result keeps the branch's own spelling, so a
    /// completed name is one git will accept.
    func testBranchTabCompletionCorrectsCase() {
        XCTAssertEqual(
            RepositoryBranchLookup.completion(for: "MAI", in: ["main", "release"]),
            "main"
        )
    }

    /// The caption that separates "this branch exists" from "this will fail
    /// inside git clone".
    func testBranchPresenceIsCaseInsensitive() {
        let branches = ["main", "develop"]
        XCTAssertTrue(RepositoryBranchLookup.contains("DEVELOP", in: branches))
        XCTAssertTrue(RepositoryBranchLookup.contains("develop", in: branches))
        XCTAssertFalse(RepositoryBranchLookup.contains("dev", in: branches),
                       "a prefix is not the branch")
        XCTAssertFalse(RepositoryBranchLookup.contains("", in: branches))
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

    func testRemoteDirectoryCompletionUsesTheTypedParentAndLeafPrefix() {
        XCTAssertEqual(
            RemoteDirectoryLookup.completionQuery(for: "/app/tm-pro"),
            .init(parentPath: "/app", prefix: "tm-pro")
        )
        XCTAssertEqual(
            RemoteDirectoryLookup.completionQuery(for: "/app/projects/"),
            .init(parentPath: "/app/projects", prefix: "")
        )
        XCTAssertEqual(
            RemoteDirectoryLookup.completionQuery(for: "~/work"),
            .init(parentPath: "~", prefix: "work")
        )
        XCTAssertEqual(
            RemoteDirectoryLookup.completionQuery(for: ""),
            .init(parentPath: "~", prefix: "")
        )
    }

    func testRemoteDirectoryListingParsesNulSeparatedPathsAndSortsFolders() throws {
        let listing = try RemoteDirectoryLookup.parse(
            "/srv/projects\u{0}./Zulu\u{0}./alpha\u{0}./Beta\u{0}"
        )
        XCTAssertEqual(listing.path, "/srv/projects")
        XCTAssertEqual(listing.parentPath, "/srv")
        XCTAssertEqual(
            listing.directories,
            ["/srv/projects/alpha", "/srv/projects/Beta", "/srv/projects/Zulu"]
        )
    }

    func testRemoteDirectoryLookupQuotesThePathAndBoundsTheScanDepth() {
        let script = RemoteDirectoryLookup.script(for: "/srv/team's projects")
        XCTAssertTrue(script.contains("p='/srv/team'\\''s projects'"))
        XCTAssertTrue(script.contains("-mindepth 1 -maxdepth 1"))
        XCTAssertTrue(script.contains("-print0"))
    }

    func testRemoteDirectoryLookupScriptListsImmediateVisibleFoldersInSh() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh team's projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("alpha/nested"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Beta"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".hidden"),
            withIntermediateDirectories: true
        )

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteDirectoryLookup.script(for: root.path)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let listing = try RemoteDirectoryLookup.parse(
            String(data: data, encoding: .utf8) ?? ""
        )
        XCTAssertEqual(
            listing.directories.map { ($0 as NSString).lastPathComponent },
            ["alpha", "Beta"]
        )
    }

    /// A host that reaches its checkout through a link (/srv/app ->
    /// /mnt/data/app) must still see the folder. A link to a file, and one to
    /// nothing at all, are not folders and stay out.
    func testRemoteDirectoryLookupListsSymlinkedFoldersButNotOtherLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh links-\(UUID().uuidString)")
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh target-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try FileManager.default.createDirectory(
            at: elsewhere, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("real"), withIntermediateDirectories: true
        )
        let plainFile = root.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: plainFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("shared"), withDestinationURL: elsewhere
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("file-link"), withDestinationURL: plainFile
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling"),
            withDestinationURL: root.appendingPathComponent("gone")
        )

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteDirectoryLookup.script(for: root.path)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let listing = try RemoteDirectoryLookup.parse(
            String(data: data, encoding: .utf8) ?? ""
        )
        XCTAssertEqual(
            listing.directories.map { ($0 as NSString).lastPathComponent },
            ["real", "shared"]
        )
    }

    func testRemoteDirectoryMatchesArePrefixFilteredAndBounded() {
        XCTAssertEqual(
            RemoteDirectoryLookup.matches(
                ["/srv/demo", "/srv/Delta", "/srv/other"],
                prefix: "de",
                limit: 1
            ),
            ["/srv/demo"]
        )
    }

    func testRemoteDirectorySelectionMeaningMatchesEveryProjectSource() {
        XCTAssertEqual(
            RemoteDirectoryLookup.selectedPath(
                sourceKind: .existingFolder,
                folder: "/srv/projects/existing",
                projectName: "ignored"
            ),
            "/srv/projects/existing"
        )
        for sourceKind in [ProjectSourceKind.clone, .empty] {
            XCTAssertEqual(
                RemoteDirectoryLookup.selectedPath(
                    sourceKind: sourceKind,
                    folder: "/srv/projects",
                    projectName: "demo"
                ),
                "/srv/projects/demo"
            )
        }
    }
}
