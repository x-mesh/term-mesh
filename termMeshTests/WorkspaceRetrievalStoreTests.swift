import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class WorkspaceRetrievalStoreTests: XCTestCase {
    func test_liveActivityPreservesErrorSeverity() {
        let suite = "WorkspaceRetrievalStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            RemoteWorkLog.sink = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let store = WorkspaceRetrievalStore(workspaceID: UUID(), defaults: defaults)

        RemoteWorkLog.error("provider authentication failed")

        XCTAssertEqual(store.activity.first?.message, "provider authentication failed")
        XCTAssertEqual(store.activity.first?.severity, .error)
    }

    func test_registerPane_createsOneProjectBindingAndSharedSelection() {
        let suite = "WorkspaceRetrievalStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceRetrievalStore(workspaceID: UUID(), defaults: defaults)
        let pane = makePane()

        store.registerPane(pane, localOrigin: "/tmp/local")
        store.registerPane(pane, localOrigin: "/tmp/local")

        XCTAssertEqual(store.panes.count, 1)
        XCTAssertEqual(store.projectBindings.count, 1)
        XCTAssertEqual(store.selectedPaneID, pane.id)
    }

    func test_presentations_supportABCAtTheSameTimeAndPersist() {
        let suite = "WorkspaceRetrievalStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspaceID = UUID()
        let store = WorkspaceRetrievalStore(workspaceID: workspaceID, defaults: defaults)

        store.visiblePresentations = [.sidebar, .drawer, .inspector]
        let restored = WorkspaceRetrievalStore(workspaceID: workspaceID, defaults: defaults)

        XCTAssertEqual(restored.visiblePresentations, [.sidebar, .drawer, .inspector])
    }

    func test_checkpointMovesPaneToReadyAndCreatesIncoming() {
        let store = WorkspaceRetrievalStore(workspaceID: UUID(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let pane = makePane()
        store.registerPane(pane, localOrigin: "/tmp/local")
        let binding = store.projectBindings[0]
        let checkpoint = RemoteCheckpointRecord(
            id: CheckpointID(), paneID: pane.id, revision: String(repeating: "a", count: 40),
            remoteRef: "refs/term-mesh/checkpoints/a", boundary: .checkpointNow, createdAt: Date()
        )
        let changeset = IncomingChangeset(
            id: ChangesetID(), paneID: pane.id, projectBindingID: binding.id,
            baseRevision: String(repeating: "b", count: 40), checkpointRevision: checkpoint.revision,
            localRef: "refs/term-mesh/incoming/a", boundary: .checkpointNow,
            changedPaths: ["README.md"], diffSummary: "1 file changed", createdAt: Date(), state: .incoming
        )

        store.completeCheckpoint(panelID: pane.panelID, result: .init(checkpoint: checkpoint, changeset: changeset))

        XCTAssertEqual(store.pane(panelID: pane.panelID)?.state, .readyToClose)
        XCTAssertEqual(store.incomingCount, 1)
        XCTAssertFalse(store.pane(panelID: pane.panelID)!.hasUncollectedChanges)
    }

    func test_recoveryStatePersistsAndUnverifiedRequiresExplicitApproval() {
        let suite = "WorkspaceRetrievalStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspaceID = UUID()
        let store = WorkspaceRetrievalStore(workspaceID: workspaceID, defaults: defaults)
        let pane = makePane()
        store.registerPane(pane, localOrigin: "/tmp/local")
        let binding = store.projectBindings[0]
        let checkpoint = RemoteCheckpointRecord(
            id: CheckpointID(), paneID: pane.id, revision: String(repeating: "a", count: 40),
            remoteRef: "refs/term-mesh/checkpoints/a", boundary: .checkpointNow, createdAt: Date()
        )
        let changeset = IncomingChangeset(
            id: ChangesetID(), paneID: pane.id, projectBindingID: binding.id,
            baseRevision: String(repeating: "b", count: 40), checkpointRevision: checkpoint.revision,
            localRef: "refs/term-mesh/incoming/a", boundary: .checkpointNow,
            changedPaths: ["README.md"], diffSummary: "1 file changed", createdAt: Date(), state: .unverified
        )
        store.completeCheckpoint(panelID: pane.panelID, result: .init(checkpoint: checkpoint, changeset: changeset))

        let restored = WorkspaceRetrievalStore(workspaceID: workspaceID, defaults: defaults)
        XCTAssertEqual(restored.projectBindings, [binding])
        XCTAssertEqual(restored.checkpoints, [checkpoint])
        XCTAssertEqual(restored.incoming, [changeset])
        XCTAssertTrue(restored.approveUnverifiedChangeset(changeset.id))
        XCTAssertEqual(restored.incoming[0].state, .validated)
        XCTAssertFalse(restored.approveUnverifiedChangeset(changeset.id))
    }

    func test_gitValidationAndApply_fastForwardsOnlyExpectedBase() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieval-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try runGit(repository, ["init", "-b", "main"])
        try runGit(repository, ["config", "user.name", "term-mesh test"])
        try runGit(repository, ["config", "user.email", "test@term-mesh.local"])
        try "base\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(repository, ["add", "file.txt"])
        try runGit(repository, ["commit", "-m", "base"])
        let base = try runGit(repository, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try "remote\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(repository, ["commit", "-am", "remote checkpoint"])
        let checkpoint = try runGit(repository, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(repository, ["reset", "--hard", base])
        try runGit(repository, ["update-ref", "refs/term-mesh/incoming/test", checkpoint])

        let changeset = IncomingChangeset(
            id: ChangesetID(), paneID: RemotePaneID(), projectBindingID: ProjectBindingID(),
            baseRevision: base, checkpointRevision: checkpoint,
            localRef: "refs/term-mesh/incoming/test", boundary: .checkpointNow,
            changedPaths: ["file.txt"], diffSummary: "1 file changed", createdAt: Date(), state: .incoming
        )
        try await RemoteGitCheckpointService.shared.validate(changeset, localOrigin: repository.path)
        try await RemoteGitCheckpointService.shared.apply(changeset, localOrigin: repository.path)

        let head = try runGit(repository, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, checkpoint)
        XCTAssertEqual(try String(contentsOf: repository.appendingPathComponent("file.txt"), encoding: .utf8), "remote\n")
    }

    func test_gitApply_rejectsDirtyOrigin() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieval-dirty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try runGit(repository, ["init", "-b", "main"])
        try runGit(repository, ["config", "user.name", "term-mesh test"])
        try runGit(repository, ["config", "user.email", "test@term-mesh.local"])
        try "base\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(repository, ["add", "file.txt"])
        try runGit(repository, ["commit", "-m", "base"])
        let base = try runGit(repository, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try "dirty\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let changeset = IncomingChangeset(
            id: ChangesetID(), paneID: RemotePaneID(), projectBindingID: ProjectBindingID(),
            baseRevision: base, checkpointRevision: base,
            localRef: "refs/term-mesh/incoming/test", boundary: .checkpointNow,
            changedPaths: ["file.txt"], diffSummary: "", createdAt: Date(), state: .validated
        )
        try runGit(repository, ["update-ref", changeset.localRef, base])

        do {
            try await RemoteGitCheckpointService.shared.apply(changeset, localOrigin: repository.path)
            XCTFail("dirty origin must not be applied")
        } catch let error as RemoteGitCheckpointError {
            XCTAssertEqual(error, .dirtyOrigin)
        }
    }

    private func makePane() -> WorkspaceRemotePaneRecord {
        WorkspaceRemotePaneRecord(
            id: RemotePaneID(), panelID: UUID(), sessionID: RemoteSessionID(),
            hostLabel: "jw-server", sshTarget: "root@jw-server", title: "executor",
            remoteRoot: "/srv/project", lifetime: .temporary, bindingRole: .owned,
            state: .running, hasUncollectedChanges: true
        )
    }

    @discardableResult
    private func runGit(_ repository: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "git failed"
            throw RemoteGitCheckpointError.commandFailed(message)
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
