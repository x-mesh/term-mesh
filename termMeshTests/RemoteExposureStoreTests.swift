import XCTest
import Bonsplit

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
    var handlers: [String: @Sendable ([String: Any]) -> String?] = [:]
    private let lock = NSLock()
    private var recordedCalls: [(method: String, params: [String: Any])] = []

    var calls: [(method: String, params: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    func rpcCallRaw(method: String, params: [String: Any]) -> String? {
        lock.lock()
        recordedCalls.append((method, params))
        let handler = handlers[method]
        let reply = replies[method]
        lock.unlock()
        if let handler { return handler(params) }
        return reply
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

    func testPruningExpiryPublishesRemovalForHeaderInvalidation() async {
        let daemon = ScriptedDaemon()
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = RemoteExposureStore(daemon: daemon, now: { clock })
        daemon.replies["remote.list"] = entry(surface, expiresAt: 1_100)
        store.refresh()
        await store.settle()
        let before = store.revision

        clock = Date(timeIntervalSince1970: 1_101)
        store.pruneExpired()

        XCTAssertNil(store.exposures[surface])
        XCTAssertEqual(store.revision, before + 1)
    }

    func testStaleRefreshCannotOverwriteNewerExposeMutation() async {
        let daemon = ScriptedDaemon()
        let releaseRefresh = DispatchSemaphore(value: 0)
        daemon.handlers["remote.list"] = { _ in
            releaseRefresh.wait()
            return "{\"status\":\"ok\",\"entries\":[],\"pruned\":0,\"now\":0}"
        }
        daemon.replies["remote.on"] = """
        {"status":"ok","entry":{"surface_id":"\(surface)","kind":"pane",\
        "title":"executor","expires_at":1600},"listener_enabled":true}
        """
        let store = RemoteExposureStore(
            daemon: daemon, now: { Date(timeIntervalSince1970: 1_000) }
        )

        store.refresh()
        for _ in 0..<200 where !daemon.calls.contains(where: { $0.method == "remote.list" }) {
            await Task.yield()
        }
        XCTAssertTrue(daemon.calls.contains(where: { $0.method == "remote.list" }))
        _ = await store.expose(["surface_id": surface])
        releaseRefresh.signal()
        await store.settle()

        XCTAssertTrue(store.isExposed(surface), "older list result must not erase newer on")
    }

    func testMonitoringStartsOnlyOneAppWidePoller() {
        let daemon = ScriptedDaemon()
        let store = RemoteExposureStore(daemon: daemon)
        store.startMonitoring()
        store.startMonitoring()
        XCTAssertTrue(store.monitoringForTesting)
        store.stopMonitoringForTesting()
        XCTAssertFalse(store.monitoringForTesting)
    }

    func testMonitoringObservesExternalCurrentPaneChangesWithoutRefocus() async {
        let daemon = ScriptedDaemon()
        daemon.replies["remote.list"] = "{\"status\":\"ok\",\"entries\":[]}"
        let store = RemoteExposureStore(
            daemon: daemon,
            now: { Date(timeIntervalSince1970: 1_000) },
            pollNanoseconds: 10_000_000
        )
        store.startMonitoring()
        await store.settle()
        daemon.replies["remote.list"] = entry(surface, expiresAt: 1_100)

        for _ in 0..<200 where !store.isExposed(surface) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertTrue(store.isExposed(surface))
        store.stopMonitoringForTesting()
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

// MARK: - EnableSpec

@MainActor
final class RemoteExposureSpecTests: XCTestCase {
    private let surface = "27C5ACD0-0719-463F-9B8B-DDC6287B0903"

    private func pane(
        _ type: PanelType,
        leader: String? = nil,
        agentTeam: String? = nil,
        agent: String? = nil,
        cli: String = ""
    ) -> RemoteExposureStore.PaneIdentity {
        RemoteExposureStore.PaneIdentity(
            surfaceID: surface, panelType: type, title: "t", cwd: "/tmp",
            leaderTeamName: leader, agentTeamName: agentTeam,
            agentName: agent, agentCLI: cli
        )
    }

    private func spec(_ identity: RemoteExposureStore.PaneIdentity) -> [String: Any]? {
        RemoteExposureStore.enableSpec(
            for: identity, appSocket: "/tmp/app.sock", keys: .safe,
            ttlSeconds: 86_400, owner: "jinwoo",
            leaderRequestToken: "tok"
        )
    }

    /// A native agent pane is the one case the page shows as a chat without
    /// needing a session id, which is the daemon's own rule.
    func testANativeAgentPaneIsAChatTarget() {
        let s = spec(pane(.agent, agentTeam: "aic", agent: "executor", cli: "claude"))
        XCTAssertEqual(s?["kind"] as? String, "agent")
        XCTAssertEqual(s?["chat_capable"] as? Bool, true)
        XCTAssertEqual(s?["team_name"] as? String, "aic")
        XCTAssertEqual(s?["agent_name"] as? String, "executor")
        XCTAssertNil(s?["leader_request_token"], "only a leader can spend it")
    }

    /// The leader routes through the durable request board, so it carries the
    /// team and the capability token. The app knows both; `tm-agent` needs
    /// `--leader --team ws-<hex>` spelled out for an adopted leader.
    func testALeaderPaneCarriesItsTeamAndToken() {
        let s = spec(pane(.terminal, leader: "aic"))
        XCTAssertEqual(s?["kind"] as? String, "leader")
        XCTAssertEqual(s?["chat_capable"] as? Bool, true)
        XCTAssertEqual(s?["team_name"] as? String, "aic")
        XCTAssertEqual(s?["leader_request_token"] as? String, "tok")
    }

    /// Leader wins over agent: a pane can be both in the roster's eyes, and
    /// the request board is the one that must receive the text.
    func testLeaderWinsWhenAPaneIsBoth() {
        let s = spec(pane(.agent, leader: "aic", agentTeam: "aic", agent: "executor"))
        XCTAssertEqual(s?["kind"] as? String, "leader")
        XCTAssertEqual(s?["team_name"] as? String, "aic")
    }

    /// The app clears CLAUDE_CODE_SESSION_ID / CODEX_THREAD_ID when it builds a
    /// pane, so a hand-run CLI's session is not the app's to know. Claiming
    /// chat here would show the phone an empty transcript; a terminal mirror is
    /// what the app can actually back.
    func testATerminalBackedAgentIsAMirrorNotAChat() {
        let s = spec(pane(.terminal, agentTeam: "aic", agent: "reviewer", cli: "claude"))
        XCTAssertEqual(s?["kind"] as? String, "pane")
        XCTAssertEqual(s?["chat_capable"] as? Bool, false)
        XCTAssertEqual(s?["agent_name"] as? String, "reviewer", "it still names itself")
    }

    func testAPlainShellIsAPlainPane() {
        let s = spec(pane(.terminal))
        XCTAssertEqual(s?["kind"] as? String, "pane")
        XCTAssertEqual(s?["chat_capable"] as? Bool, false)
        XCTAssertNil(s?["team_name"])
        XCTAssertNil(s?["agent_name"])
    }

    /// No surface to mirror and no transcript to follow.
    func testABrowserPaneYieldsNoSpec() {
        XCTAssertNil(spec(pane(.browser)))
        XCTAssertNil(spec(pane(.browser, agentTeam: "aic", agent: "executor")))
    }

    func testAPaneWithNoSurfaceIdYieldsNoSpec() {
        var identity = pane(.terminal)
        identity = RemoteExposureStore.PaneIdentity(
            surfaceID: "", panelType: identity.panelType, title: identity.title,
            cwd: identity.cwd
        )
        XCTAssertNil(spec(identity))
    }

    /// The keys policy and TTL travel as the daemon spells them, and an absent
    /// TTL leaves the daemon's own default alone rather than inventing one.
    func testKeysAndTTLTravelInTheDaemonsSpelling() {
        let restricted = RemoteExposureStore.enableSpec(
            for: pane(.terminal), appSocket: "/tmp/app.sock", keys: .none,
            ttlSeconds: nil, owner: nil
        )
        XCTAssertEqual(restricted?["keys"] as? String, "none")
        XCTAssertNil(restricted?["ttl_secs"])
        XCTAssertNil(restricted?["owner"])
        XCTAssertEqual(restricted?["app_socket"] as? String, "/tmp/app.sock")
        XCTAssertEqual(spec(pane(.terminal))?["ttl_secs"] as? Int, 86_400)
    }
}

// MARK: - Render cost

@MainActor
final class PaneHeaderInvalidationTests: XCTestCase {
    func testStopPresentationKeepsStopIntentWhenClockLaterExpires() {
        let presentation = Workspace.mobileExposurePresentation(isExposed: true)
        XCTAssertFalse(presentation.shouldExpose)
        XCTAssertEqual(presentation.systemImage, "iphone.radiowaves.left.and.right")
        XCTAssertTrue(presentation.help.hasPrefix("Stop"))
    }

    func testPaneDirectoryWinsOverWorkspaceDirectoryForExposure() {
        XCTAssertEqual(
            Workspace.mobileExposureCWD(
                panelDirectory: "/repo/pane", workspaceDirectory: "/repo/workspace"
            ),
            "/repo/pane"
        )
        XCTAssertEqual(
            Workspace.mobileExposureCWD(
                panelDirectory: nil, workspaceDirectory: "/repo/workspace"
            ),
            "/repo/workspace"
        )
    }

    func testClosingPaneRequestsBestEffortUnexpose() async {
        let daemon = ScriptedDaemon()
        daemon.replies["remote.off"] = "{\"status\":\"ok\",\"removed\":true}"
        let store = RemoteExposureStore(daemon: daemon)
        let workspace = Workspace(title: "close-unexpose")
        workspace.remoteExposureStore = store
        let panelID = try! XCTUnwrap(workspace.panels.keys.first)

        workspace.unexposeForClosingPanel(panelID)
        for _ in 0..<200 where !daemon.calls.contains(where: { $0.method == "remote.off" }) {
            await Task.yield()
        }

        let call = daemon.calls.first(where: { $0.method == "remote.off" })
        XCTAssertEqual(call?.params["surface_id"] as? String, panelID.uuidString)
    }

    /// One pane's exposure change must redraw one header.
    ///
    /// The signal lives on PaneState rather than on the controller precisely
    /// so this holds: a controller-wide revision would be read by every
    /// TabBarView, and toggling one pane would redraw every open tab bar.
    func testInvalidatingOnePaneLeavesTheOthersUntouched() {
        let controller = BonsplitController()
        guard let first = controller.allPaneIds.first else {
            return XCTFail("expected a root pane")
        }
        guard let second = controller.splitPane(first, orientation: .horizontal) else {
            return XCTFail("expected a second pane")
        }

        let before = (controller.headerActionsRevision(inPane: first) ?? -1,
                      controller.headerActionsRevision(inPane: second) ?? -1)
        controller.invalidatePaneHeaderActions(inPane: first)

        XCTAssertEqual(controller.headerActionsRevision(inPane: first), before.0 + 1)
        XCTAssertEqual(
            controller.headerActionsRevision(inPane: second), before.1,
            "the pane nobody touched must not redraw"
        )
    }

    /// The store is the only thing the header reads, and reading it is a
    /// dictionary lookup — no daemon call on the draw path.
    func testReadingExposureStateNeverCallsTheDaemon() async {
        let daemon = ScriptedDaemon()
        let store = RemoteExposureStore(daemon: daemon, now: { Date(timeIntervalSince1970: 1_000) })
        daemon.replies["remote.list"] = """
        {"status":"ok","entries":[{"surface_id":"A","kind":"pane","title":"t",        "expires_at":9999}],"pruned":0,"now":0}
        """
        store.refresh()
        await store.settle()
        let afterRefresh = daemon.calls.count

        for _ in 0..<500 {
            _ = store.isExposed("A")
            _ = store.isExposed("B")
            _ = store.exposure("A")
        }
        XCTAssertEqual(
            daemon.calls.count, afterRefresh,
            "1500 header reads must cost zero RPCs"
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
