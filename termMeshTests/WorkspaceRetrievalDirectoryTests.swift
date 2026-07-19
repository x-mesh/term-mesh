import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Where a remote pane's shell is cannot be learned from the terminal stream —
/// a terminal refuses an OSC 7 whose hostname is not local, and a hosted pane
/// always names its own host — so it is asked of the host that runs the pane.
/// These cover the client half of that: what gets remembered, what gets used
/// when the host cannot answer, and which value wins in the binding sheet.
@MainActor
final class WorkspaceRetrievalDirectoryTests: XCTestCase {

    private let spawnDirectory = "/home/user/project"

    private func pane(remoteRoot: String) -> WorkspaceRemotePaneRecord {
        WorkspaceRemotePaneRecord(
            id: RemotePaneID(),
            panelID: UUID(),
            sessionID: RemoteSessionID(),
            hostLabel: "test-host",
            sshTarget: "user@test-host",
            title: "Remote Terminal",
            remoteRoot: remoteRoot,
            lifetime: .keepAlive,
            bindingRole: .owned,
            state: .running,
            hasUncollectedChanges: false
        )
    }

    /// Answers whatever it is told to, and counts how often it was asked so a
    /// test can prove a value came from the host rather than from a cache.
    private func store(
        answering answers: [String?],
        asked: @escaping (Int) -> Void = { _ in }
    ) -> WorkspaceRetrievalStore {
        // Isolated defaults: the store persists panel settings, and a test has
        // no business writing into the ones a real run reads.
        let defaults = UserDefaults(suiteName: "WorkspaceRetrievalDirectoryTests-\(UUID().uuidString)")!
        let store = WorkspaceRetrievalStore(workspaceID: UUID(), defaults: defaults)
        var remaining = answers
        var count = 0
        store.remoteDirectoryProvider = { _ in
            count += 1
            asked(count)
            return remaining.isEmpty ? nil : remaining.removeFirst()
        }
        return store
    }

    // MARK: - What the host says

    func testAdoptsAndRemembersTheDirectoryTheHostReports() async {
        let store = store(answering: ["/home/user/project/src"])
        let pane = pane(remoteRoot: spawnDirectory)

        let fresh = await store.refreshedDirectory(of: pane)
        XCTAssertEqual(fresh, "/home/user/project/src")

        // Remembered, so a second look needs no round trip.
        XCTAssertEqual(store.currentDirectory(of: pane), "/home/user/project/src")
    }

    func testFallsBackToTheSpawnDirectoryWhenTheHostCannotAnswer() async {
        let store = store(answering: [nil])
        let pane = pane(remoteRoot: spawnDirectory)

        let value = await store.refreshedDirectory(of: pane)

        // A binding sheet with a stale suggestion beats one with an empty
        // field, so an unreachable host must not erase what is known.
        XCTAssertEqual(value, spawnDirectory)
    }

    func testRejectsAnAnswerThatIsNotAnAbsolutePath() async {
        let store = store(answering: ["src"])
        let pane = pane(remoteRoot: spawnDirectory)

        let value = await store.refreshedDirectory(of: pane)

        // A relative path names nothing on its own and would be pasted into
        // remote commands as if it did.
        XCTAssertEqual(value, spawnDirectory)
        XCTAssertEqual(store.currentDirectory(of: pane), spawnDirectory)
    }

    func testAsksTheHostEvenAfterADirectoryHasBeenRemembered() async {
        var timesAsked = 0
        let store = store(
            answering: ["/home/user/project/src", "/home/user/project/tests"],
            asked: { timesAsked = $0 }
        )
        let pane = pane(remoteRoot: spawnDirectory)

        _ = await store.refreshedDirectory(of: pane)
        let second = await store.refreshedDirectory(of: pane)

        // The remembered value is a fallback, never a substitute for asking:
        // a shell moves, and the whole point of this path is to follow it.
        XCTAssertEqual(timesAsked, 2)
        XCTAssertEqual(second, "/home/user/project/tests")
    }

    // MARK: - Which value the binding sheet keeps

    /// The regression this file exists for.
    ///
    /// The sheet used to accept the host's answer only while the field still
    /// held the pane's *spawn* directory. That looks equivalent and is not:
    /// after one look the field is seeded with the *remembered* directory, the
    /// spawn test fails, and the freshly fetched answer is discarded — so a
    /// pane that had moved kept suggesting where it used to be.
    func testAdoptsTheHostAnswerWhenTheFieldStillHoldsARememberedDirectory() {
        let remembered = "/home/user/project/src"

        XCTAssertTrue(
            WorkspaceRetrievalStore.shouldAdoptHostAnswer(field: remembered, seed: remembered),
            "a field left as seeded must accept the host's answer, however it was seeded"
        )
    }

    func testAdoptsTheHostAnswerWhenTheFieldWasSeededFromTheSpawnDirectory() {
        XCTAssertTrue(
            WorkspaceRetrievalStore.shouldAdoptHostAnswer(field: spawnDirectory, seed: spawnDirectory)
        )
    }

    func testKeepsWhatTheUserTypedWhileTheHostWasBeingAsked() {
        XCTAssertFalse(
            WorkspaceRetrievalStore.shouldAdoptHostAnswer(
                field: "/home/user/somewhere-else",
                seed: spawnDirectory
            ),
            "a typed path is the user's answer, not a placeholder to correct"
        )
    }

    // MARK: - Lifetime

    func testForgetsARememberedDirectoryWhenThePaneGoes() async {
        let store = store(answering: ["/home/user/project/src"])
        let pane = pane(remoteRoot: spawnDirectory)
        store.registerPane(pane, localOrigin: "/local/origin")

        _ = await store.refreshedDirectory(of: pane)
        XCTAssertEqual(store.currentDirectory(of: pane), "/home/user/project/src")

        store.removeBinding(panelID: pane.panelID)

        // Nothing can ask for it again, so keeping it only grows the table.
        XCTAssertEqual(store.currentDirectory(of: pane), spawnDirectory)
    }
}
