import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A daemon that answers from a script rather than a socket.
///
/// Only `rpcCallRaw` is exercised; every other member of the protocol is a
/// stub, because the store is deliberately the one place that talks to the
/// daemon and it uses exactly one call.
private final class ScriptedDaemon: DaemonService, @unchecked Sendable {
    var replies: [String: String] = [:]
    private(set) var calls: [(method: String, params: [String: Any])] = []

    func rpcCallRaw(method: String, params: [String: Any]) -> String? {
        calls.append((method, params))
        return replies[method]
    }

    // MARK: - Unused protocol surface
    var worktreeEnabled = false
    var worktreeBaseDir = ""
    var worktreeAutoCleanup = false
    var isLocalhostOnly: Bool { true }
    var isDashboardEnabled: Bool { false }
    var dashboardPort: Int { 0 }
    func startDaemon() {}
    func stopDaemon() {}
    func restartDaemon(completion: @escaping () -> Void) { completion() }
    func ping() -> Bool { true }
    static let idleStatus = TermMeshDaemon.DaemonStatus(
        connected: false, pid: nil, uptimeSecs: nil, binaryPath: nil,
        binaryExists: false, socketPath: "", socketExists: false,
        logPath: "", logExists: false, appVariant: "Debug",
        bundleIdentifier: "test", subsystems: []
    )
    func daemonStatus() -> TermMeshDaemon.DaemonStatus { Self.idleStatus }
    func createWorktree(repoPath: String, branch: String?, baseBranch: String?) -> WorktreeInfo? { nil }
    func createWorktreeWithError(repoPath: String, branch: String?, baseBranch: String?) -> Result<WorktreeInfo, WorktreeCreateError> { .failure(.daemonNotConnected) }
    func findGitRoot(from path: String) -> String? { nil }
    func removeWorktree(repoPath: String, name: String, force: Bool) -> Bool { false }
    func rollbackCreatedWorktree(repoPath: String, name: String) -> Bool { false }
    func listWorktrees(repoPath: String) -> [WorktreeInfo] { [] }
    func listBranches(repoPath: String) -> [String] { [] }
    func worktreeStatus(repoPath: String, name: String) -> TermMeshDaemon.WorktreeStatusResult {
        TermMeshDaemon.WorktreeStatusResult(dirty: false, unpushed: false)
    }
    func cleanupStaleWorktrees(repoPath: String) -> (removed: Int, skippedDirty: Int) { (0, 0) }
    func cleanupAllStaleWorktrees() -> (removed: Int, skippedDirty: Int) { (0, 0) }
    func trackPID(_ pid: Int32) -> Bool { false }
    func untrackPID(_ pid: Int32) {}
    func stopProcess(pid: Int32) -> Bool { false }
    func resumeProcess(pid: Int32) -> Bool { false }
    func syncSessions(_ sessions: [[String: Any]]) {}
    func syncTeams(_ payload: [String: Any]) {}
    func watchPath(_ path: String) {}
    func unwatchPath(_ path: String) {}
    func spawnAgents(repoPath: String, count: Int, name: String?, command: String?) -> [AgentSessionInfo] { [] }
    func listAgents(includeTerminated: Bool) -> [AgentSessionInfo] { [] }
    func getAgent(id: String) -> AgentSessionInfo? { nil }
    func bindAgentPanel(sessionId: String, panelId: String) -> Bool { false }
    func unbindAgentPanel(sessionId: String) -> Bool { false }
    func terminateAgent(id: String, force: Bool) -> Bool { false }
    func setAutoStop(enabled: Bool) {}
}

@MainActor
final class RemoteExposureStoreTests: XCTestCase {
    private let surface = "27C5ACD0-0719-463F-9B8B-DDC6287B0903"

    private func entry(_ id: String, expiresAt: TimeInterval, kind: String = "pane") -> String {
        """
        {"status":"ok","entries":[{"surface_id":"\(id)","kind":"\(kind)",\
        "title":"executor","expires_at":\(Int(expiresAt))}],"pruned":0,"now":0}
        """
    }

    /// The pane header draws from this cache between refreshes, and the daemon
    /// prunes only when it is read. An entry that outlived its expiry must not
    /// be drawn as reachable in that window.
    func testAnExpiredEntryIsNotExposedEvenWhileTheCacheStillNamesIt() async {
        let daemon = ScriptedDaemon()
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = RemoteExposureStore(daemon: daemon, now: { clock })
        daemon.replies["remote.list"] = entry(surface, expiresAt: 1_100)

        store.refresh()
        await store.settle()
        XCTAssertTrue(store.isExposed(surface))

        clock = Date(timeIntervalSince1970: 1_101)
        XCTAssertFalse(store.isExposed(surface), "past expires_at the cache is stale, not authoritative")
        XCTAssertNil(store.exposure(surface))
    }

    /// The reply is what gets stored. Deriving the expiry from the requested
    /// TTL would disagree with the daemon, which clamps TTL to 60s-7d.
    func testExposeAdoptsTheDaemonsEntryRatherThanTheRequestedTTL() async {
        let daemon = ScriptedDaemon()
        let store = RemoteExposureStore(daemon: daemon, now: { Date(timeIntervalSince1970: 1_000) })
        daemon.replies["remote.on"] = """
        {"status":"ok","entry":{"surface_id":"\(surface)","kind":"agent",\
        "title":"executor","expires_at":1600},"url":"http://127.0.0.1:9877/t/\(surface)",\
        "listener_enabled":true}
        """

        let result = await store.expose(["surface_id": surface, "ttl_secs": 999_999])
        guard case .success(let value) = result else { return XCTFail("expected success") }
        XCTAssertTrue(value.isReachable)
        XCTAssertEqual(value.url, "http://127.0.0.1:9877/t/\(surface)")
        XCTAssertEqual(store.exposure(surface)?.expiresAt, 1_600, "clamped by the daemon, not by us")
        XCTAssertEqual(store.exposure(surface)?.kind, "agent")
    }

    /// Registering an exposure and reaching it are separate outcomes. With the
    /// listener off the entry is real and the phone cannot open it, and the
    /// caller has to be able to say so.
    func testExposeReportsARegisteredButUnreachableExposure() async {
        let daemon = ScriptedDaemon()
        let store = RemoteExposureStore(daemon: daemon, now: { Date(timeIntervalSince1970: 1_000) })
        daemon.replies["remote.on"] = """
        {"status":"ok","entry":{"surface_id":"\(surface)","kind":"pane",\
        "title":"shell","expires_at":1600},"listener_enabled":false,\
        "listener_error":"listener disabled"}
        """

        let result = await store.expose(["surface_id": surface])
        guard case .success(let value) = result else { return XCTFail("expected success") }
        XCTAssertFalse(value.isReachable)
        XCTAssertEqual(value.listenerError, "listener disabled")
        XCTAssertTrue(store.isExposed(surface), "the entry exists even though nothing can reach it")
    }

    /// `removed: false` means it was already gone, which is the state the
    /// caller asked for. Treating that as a failure would leave a stale icon.
    func testUnexposeClearsTheEntryEvenWhenTheDaemonHadNone() async {
        let daemon = ScriptedDaemon()
        let store = RemoteExposureStore(daemon: daemon, now: { Date(timeIntervalSince1970: 1_000) })
        daemon.replies["remote.list"] = entry(surface, expiresAt: 9_999)
        store.refresh()
        await store.settle()
        XCTAssertTrue(store.isExposed(surface))

        daemon.replies["remote.off"] = #"{"status":"ok","surface_id":"x","removed":false}"#
        let result = await store.unexpose(surface)
        guard case .success = result else { return XCTFail("expected success") }
        XCTAssertFalse(store.isExposed(surface))
    }

    /// A daemon that is not answering must not read as "nothing is exposed":
    /// that would flip every icon off and invite a second expose.
    func testAnUnreachableDaemonLeavesTheCacheAlone() async {
        let daemon = ScriptedDaemon()
        let store = RemoteExposureStore(daemon: daemon, now: { Date(timeIntervalSince1970: 1_000) })
        daemon.replies["remote.list"] = entry(surface, expiresAt: 9_999)
        store.refresh()
        await store.settle()
        XCTAssertTrue(store.isExposed(surface))

        daemon.replies["remote.list"] = nil
        store.refresh()
        await store.settle()
        XCTAssertTrue(store.isExposed(surface), "silence is not evidence of removal")

        daemon.replies["remote.on"] = nil
        let result = await store.expose(["surface_id": surface])
        XCTAssertEqual(result, .failure(.unavailable))
    }

    /// The header cannot observe a dictionary, so it depends on one value that
    /// changes whenever the map does — and does not change when it does not.
    func testRevisionAdvancesOnlyWhenTheExposureSetChanges() async {
        let daemon = ScriptedDaemon()
        let store = RemoteExposureStore(daemon: daemon, now: { Date(timeIntervalSince1970: 1_000) })
        daemon.replies["remote.list"] = entry(surface, expiresAt: 9_999)

        store.refresh(); await store.settle()
        let afterFirst = store.revision
        XCTAssertGreaterThan(afterFirst, 0)

        store.refresh(); await store.settle()
        XCTAssertEqual(store.revision, afterFirst, "an identical registry is not a change")

        daemon.replies["remote.list"] = #"{"status":"ok","entries":[],"pruned":1,"now":0}"#
        store.refresh(); await store.settle()
        XCTAssertGreaterThan(store.revision, afterFirst)
    }

    /// A row the app cannot place in time is not a row it can draw.
    func testARowWithoutAnExpiryIsRejected() {
        XCTAssertNil(RemoteExposureStore.exposure(from: ["surface_id": surface, "kind": "pane"]))
        XCTAssertNil(RemoteExposureStore.exposure(from: ["expires_at": 10]))
        XCTAssertNil(RemoteExposureStore.exposure(from: ["surface_id": "", "expires_at": 10]))
        XCTAssertEqual(
            RemoteExposureStore.exposure(from: ["surface_id": surface, "expires_at": 10])?.kind,
            "pane",
            "a row with no kind is a plain pane, which is the daemon's own default"
        )
    }
}

private extension RemoteExposureStore {
    /// Let the in-flight refresh finish. `refresh()` is fire-and-forget by
    /// design — the header never awaits it — so tests need a join point.
    func settle() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }
}
