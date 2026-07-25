import XCTest
import Darwin

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ReviewBoardCoordinatorServiceTests: XCTestCase {
    func testCoordinatorGateRequiresEnvironmentAndBothFeatureFlags() {
        let defaults = UserDefaults(suiteName: "ReviewBoardCoordinatorServiceTests.\(UUID().uuidString)")!
        let environment = [ReviewBoardCoordinatorSettings.enabledEnvironmentKey: "1"]

        XCTAssertFalse(ReviewBoardCoordinatorSettings.isIntegrationEnabled(environment: environment, defaults: defaults))

        defaults.set(true, forKey: ReviewBoardCoordinatorSettings.distributedFeatureKey)
        XCTAssertFalse(ReviewBoardCoordinatorSettings.isIntegrationEnabled(environment: environment, defaults: defaults))

        defaults.set(true, forKey: ReviewBoardSettings.enabledKey)
        XCTAssertTrue(ReviewBoardCoordinatorSettings.isIntegrationEnabled(environment: environment, defaults: defaults))
        XCTAssertFalse(ReviewBoardCoordinatorSettings.isIntegrationEnabled(environment: [:], defaults: defaults))
    }

    func testCoordinatorSocketPathFollowsOverrideAndTaggedConvention() {
        XCTAssertEqual(
            ReviewBoardCoordinatorSettings.socketPath(
                environment: [ReviewBoardCoordinatorSettings.socketPathEnvironmentKey: "/tmp/custom.sock"],
                bundleIdentifier: "com.termmesh.app.debug.review.board",
                isDebugBuild: true
            ),
            "/tmp/custom.sock"
        )

        XCTAssertEqual(
            ReviewBoardCoordinatorSettings.socketPath(
                environment: [:],
                bundleIdentifier: "com.termmesh.app.debug.review.board",
                isDebugBuild: true
            ),
            "/tmp/tm-coordinator-debug-review-board.sock"
        )
    }

    /// The experimental toggle owns both halves of the gate. It reads on only
    /// when both are set, writes both together, and a half-set state left by
    /// an older build reads as off.
    func testDistributedWorkspacesToggleMovesBothGateKeys() {
        let defaults = UserDefaults(suiteName: "DistributedToggleTests.\(UUID().uuidString)")!

        XCTAssertFalse(ReviewBoardCoordinatorSettings.distributedWorkspacesToggleOn(defaults: defaults))

        ReviewBoardCoordinatorSettings.setDistributedWorkspacesToggle(true, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: ReviewBoardCoordinatorSettings.distributedFeatureKey))
        XCTAssertTrue(defaults.bool(forKey: ReviewBoardSettings.enabledKey))
        XCTAssertTrue(ReviewBoardCoordinatorSettings.distributedWorkspacesToggleOn(defaults: defaults))

        ReviewBoardCoordinatorSettings.setDistributedWorkspacesToggle(false, defaults: defaults)
        XCTAssertFalse(ReviewBoardCoordinatorSettings.distributedWorkspacesToggleOn(defaults: defaults))

        // Half-set (one key on) must not read as on — the gate is an AND.
        defaults.set(true, forKey: ReviewBoardCoordinatorSettings.distributedFeatureKey)
        XCTAssertFalse(ReviewBoardCoordinatorSettings.distributedWorkspacesToggleOn(defaults: defaults))
    }

    /// A coordinator launched without a working event log exits immediately
    /// with `mem_mesh_unavailable`, which the app can only observe as "never
    /// online" — so the local journal has to be on by default.
    func testLaunchEnvironmentEnablesTheLocalJournalAndSocketPath() {
        let environment = ReviewBoardCoordinatorSettings.launchEnvironment(
            base: ["PATH": "/usr/bin"],
            socketPath: "/tmp/tm-coordinator-test.sock"
        )

        XCTAssertEqual(environment[ReviewBoardCoordinatorSettings.socketPathEnvironmentKey], "/tmp/tm-coordinator-test.sock")
        XCTAssertEqual(environment[ReviewBoardCoordinatorSettings.localJournalEnvironmentKey], "1")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testLaunchEnvironmentKeepsAnExplicitJournalChoice() {
        let environment = ReviewBoardCoordinatorSettings.launchEnvironment(
            base: [ReviewBoardCoordinatorSettings.localJournalEnvironmentKey: "0"],
            socketPath: "/tmp/tm-coordinator-test.sock"
        )

        XCTAssertEqual(environment[ReviewBoardCoordinatorSettings.localJournalEnvironmentKey], "0")
    }

    /// A dead coordinator leaves its socket path behind; treating that file as
    /// proof of life strands the app on a socket nothing listens to.
    func testSocketLivenessIgnoresLeftoverFiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coordinator-liveness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stalePath = directory.appendingPathComponent("stale.sock").path
        FileManager.default.createFile(atPath: stalePath, contents: Data())

        XCTAssertTrue(FileManager.default.fileExists(atPath: stalePath))
        XCTAssertFalse(ReviewBoardCoordinatorClient.isSocketAlive(stalePath))
        XCTAssertFalse(ReviewBoardCoordinatorClient.isSocketAlive(
            directory.appendingPathComponent("never-existed.sock").path
        ))
    }

    // MARK: - Host observations

    func testHostObservationIDIsStableAndRequestIDTracksContent() {
        let first = CoordinatorHostObservation(
            hostKey: "ssh:root@jw-server",
            projectRoots: ["/root/demo-project"],
            isLive: true
        )
        // Same host, roots reported in a different order — same observation.
        let reordered = CoordinatorHostObservation(
            hostKey: "ssh:root@jw-server",
            projectRoots: ["/root/demo-project"],
            isLive: true
        )
        let changed = CoordinatorHostObservation(
            hostKey: "ssh:root@jw-server",
            projectRoots: ["/root/demo-project", "/root/x-kit"],
            isLive: true
        )
        let otherHost = CoordinatorHostObservation(
            hostKey: "ssh:jinwoo-macmini",
            projectRoots: ["/root/demo-project"],
            isLive: true
        )

        XCTAssertTrue(first.coordinatorHostID.hasPrefix("hst_"))
        XCTAssertEqual(first.coordinatorHostID, reordered.coordinatorHostID)
        // The host id must survive a reconnect, so content changes must NOT
        // move it — only the request id may change.
        XCTAssertEqual(first.coordinatorHostID, changed.coordinatorHostID)
        XCTAssertNotEqual(first.coordinatorHostID, otherHost.coordinatorHostID)

        XCTAssertEqual(first.requestID, reordered.requestID)
        XCTAssertNotEqual(first.requestID, changed.requestID)
    }

    /// Omitting the slot counts is the point, and this test used to pin the
    /// opposite: it asserted the app sends `0/0`, which the coordinator reads
    /// as "this host is full" — so every host the app reported was refused
    /// for placement, by hand and automatically. Absent means unknown.
    func testHostObservationParamsOmitCapacityRatherThanClaimingZero() {
        let params = CoordinatorHostObservation(
            hostKey: "ssh:root@jw-server",
            projectRoots: ["/root/x-kit", "/root/demo-project"],
            isLive: true
        ).rpcParams

        XCTAssertNil(params["total_slots"], "a zero here reads as 'full', not 'unknown'")
        XCTAssertNil(params["used_slots"])
        XCTAssertEqual(params["live"] as? Bool, true)
        XCTAssertEqual(params["project_roots"] as? [String], ["/root/demo-project", "/root/x-kit"])
        XCTAssertEqual(params["host_id"] as? String, CoordinatorHostObservation(
            hostKey: "ssh:root@jw-server", projectRoots: [], isLive: true
        ).coordinatorHostID)
    }

    @MainActor
    func testOnlyConnectedHostsAreReportedAndRootsAreDeduped() {
        let connected = hostEntry(
            id: "ssh:root@jw-server",
            state: .connected,
            paneRoots: ["/root/demo-project", "/root/demo-project", nil]
        )
        let offline = hostEntry(id: "ssh:mac-sub", state: .saved, paneRoots: ["/srv/app"])

        let observations = ReviewBoardCoordinatorService.hostObservations(from: [connected, offline])

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.hostKey, "ssh:root@jw-server")
        XCTAssertEqual(observations.first?.projectRoots, ["/root/demo-project"])
    }

    // MARK: - Leader placement

    @MainActor
    func testLocalObservationCarriesLeaderProjectsAndPeersDoNot() {
        let peer = hostEntry(
            id: "ssh:root@jw-server", state: .connected, paneRoots: ["/root/demo-project"]
        )

        let observations = ReviewBoardCoordinatorService.hostObservations(
            from: [peer],
            localProjectRoots: ["/Users/jinwoo/work/term-mesh", "/Users/jinwoo/work/x-kit"],
            localLeaderProjectRoots: ["/Users/jinwoo/work/term-mesh"]
        )

        let local = observations.first { $0.hostKey == CoordinatorHostObservation.localHostKey }
        XCTAssertEqual(local?.leaderProjectRoots, ["/Users/jinwoo/work/term-mesh"])
        // The peer reported no team roster, so it contributes no leader.
        let remote = observations.first { $0.hostKey == "ssh:root@jw-server" }
        XCTAssertEqual(remote?.leaderProjectRoots, [])
    }

    /// A peer that DOES report a team roster is the only way a leader on
    /// another machine can ever be known.
    @MainActor
    func testPeerTeamRosterContributesRemoteLeaders() {
        var peer = hostEntry(
            id: "ssh:root@jw-server", state: .connected, paneRoots: ["/root/demo-project"]
        )
        peer.teams = [RemoteTeamSummary(
            name: "live-team",
            teamUUID: "uuid-1",
            workingDirectory: "/root/other-project/sub",
            projectRootPath: "/root/other-project",
            agentNames: ["explorer"]
        )]

        let observations = ReviewBoardCoordinatorService.hostObservations(from: [peer])
        let remote = observations.first { $0.hostKey == "ssh:root@jw-server" }

        XCTAssertEqual(remote?.leaderProjectRoots, ["/root/other-project"])
        // The team's project counts as hosted even though no pane sits in it,
        // or the coordinator would reject the leader as unhosted.
        XCTAssertEqual(
            remote?.projectRoots.sorted(),
            ["/root/demo-project", "/root/other-project"]
        )
    }

    func testLeaderProjectsAreAlwaysASubsetOfHostedProjects() {
        let params = CoordinatorHostObservation(
            hostKey: CoordinatorHostObservation.localHostKey,
            projectRoots: ["/repo/alpha"],
            leaderProjectRoots: ["/repo/alpha", "/repo/never-hosted"],
            isLive: true
        ).rpcParams

        XCTAssertEqual(params["leader_projects"] as? [String], ["/repo/alpha"])
    }

    func testLeaderRequestIDChangesWhenLeadershipMoves() {
        let withoutLeader = CoordinatorHostObservation(
            hostKey: "local:this-mac", projectRoots: ["/repo/alpha"], isLive: true
        )
        let withLeader = CoordinatorHostObservation(
            hostKey: "local:this-mac",
            projectRoots: ["/repo/alpha"],
            leaderProjectRoots: ["/repo/alpha"],
            isLive: true
        )

        XCTAssertNotEqual(withoutLeader.requestID, withLeader.requestID)
        XCTAssertEqual(withoutLeader.coordinatorHostID, withLeader.coordinatorHostID)
    }

    // MARK: - Remembered projects

    @MainActor
    func testRememberedProjectsCoverOfflineHostsOnly() {
        let offline = hostEntry(id: "ssh:mac-sub", state: .saved, paneRoots: [])
        let connected = hostEntry(
            id: "ssh:root@jw-server", state: .connected, paneRoots: ["/root/demo-project"]
        )
        let knownOffline = knownHost(for: "ssh:mac-sub", roots: ["/srv/app", "/srv/tools"])
        // The connected host speaks for itself through the peer roster.
        let knownConnected = knownHost(for: "ssh:root@jw-server", roots: ["/root/demo-project"])

        let remembered = ReviewBoardCoordinatorService.rememberedProjects(
            knownHosts: [knownOffline, knownConnected],
            sidebarHosts: [offline, connected],
            liveIdentities: []
        )

        XCTAssertEqual(remembered.map(\.identity.label), ["app", "tools"])
        XCTAssertEqual(remembered.first?.hostKey, "ssh:mac-sub")
    }

    @MainActor
    func testRememberedProjectsSkipOnesAlreadyLiveAndUnknownHosts() {
        let offline = hostEntry(id: "ssh:mac-sub", state: .saved, paneRoots: [])
        let live = projectIdentity(forWorkingDirectories: ["/srv/app"])

        let remembered = ReviewBoardCoordinatorService.rememberedProjects(
            knownHosts: [
                knownHost(for: "ssh:mac-sub", roots: ["/srv/app", "/srv/tools"]),
                // A host the sidebar no longer knows cannot be acted on.
                CoordinatorKnownHost(
                    hostID: "hst_forgotten", projectRoots: ["/srv/ghost"],
                    isLive: false, observedAtMilliseconds: 0
                ),
            ],
            sidebarHosts: [offline],
            liveIdentities: [live]
        )

        XCTAssertEqual(remembered.map(\.identity.label), ["tools"])
    }

    @MainActor
    func testRememberedProjectsIgnoreHomeAndSystemRoots() {
        let offline = hostEntry(id: "ssh:mac-sub", state: .saved, paneRoots: [])

        let remembered = ReviewBoardCoordinatorService.rememberedProjects(
            knownHosts: [knownHost(for: "ssh:mac-sub", roots: ["/root", "/Users/jinwoo", "/"])],
            sidebarHosts: [offline],
            liveIdentities: []
        )

        XCTAssertTrue(remembered.isEmpty)
    }

    private func knownHost(for hostKey: String, roots: [String]) -> CoordinatorKnownHost {
        CoordinatorKnownHost(
            hostID: CoordinatorHostObservation(
                hostKey: hostKey, projectRoots: [], isLive: true
            ).coordinatorHostID,
            projectRoots: roots,
            isLive: false,
            observedAtMilliseconds: 1_784_800_000_000
        )
    }

    private func hostEntry(
        id: String,
        state: HostConnectionState,
        paneRoots: [String?]
    ) -> HostEntry {
        let panes = paneRoots.enumerated().map { index, root in
            RemotePaneSummary(
                id: Data([UInt8(index)]),
                title: "pane",
                workingDirectoryPath: root,
                workingDirectoryName: nil,
                projectRootPath: root,
                tabCount: 1,
                columns: 80,
                rows: 24,
                isBusy: false
            )
        }
        let workspace = WorkspaceSummary(
            id: Data([1]),
            title: "default",
            hostSockPath: "/tmp/sock",
            windowID: Data(),
            windowTitle: "",
            isDefault: true,
            paneCount: panes.count,
            surfaceCount: panes.count,
            busyCount: 0,
            panes: panes
        )
        return HostEntry(
            id: id,
            displayName: id,
            connectionState: state,
            workspaces: [workspace],
            activeSockPath: "/tmp/sock"
        )
    }

    func testClientParsesFakeUDSSnapshotAndSanitizesDisplayData() async throws {
        let socketPath = "/tmp/tm-coordinator-test-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeCoordinatorServer(socketPath: socketPath)
        let task = try server.start(expectedRequests: 4)
        defer {
            server.stop()
            task.cancel()
        }

        let client = ReviewBoardCoordinatorClient(socketPath: socketPath)
        let snapshot = try await client.fetchSnapshot()

        XCTAssertTrue(snapshot.coordinatorOnline)
        XCTAssertFalse(snapshot.memMeshAvailable)
        XCTAssertTrue(snapshot.suspectHost)
        XCTAssertTrue(snapshot.fencedZombie)

        // A coordinator row has to survive parsing at all — every one of them
        // used to be dropped, leaving a board that reported "No review tasks"
        // no matter what the coordinator held.
        XCTAssertEqual(snapshot.tasks.count, 1)
        let parsed = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(parsed.rawID, "tsk_8d144b235ec342019a6d2bf39ef65296")
        XCTAssertEqual(parsed.id, "tsk_8d14", "display id is shortened")
        XCTAssertEqual(parsed.status, "queued_for_merge", "coordinator statuses are kept verbatim")
        XCTAssertFalse(parsed.title.contains("/Users/jinwoo"), "paths are still scrubbed")
        XCTAssertEqual(parsed.updatedAt, ReviewBoardText.timestamp(fromUnixMilliseconds: 1_784_882_974_390))

        XCTAssertEqual(snapshot.mergeQueue.count, 1)
        let entry = try XCTUnwrap(snapshot.mergeQueue.first)
        XCTAssertTrue(entry.isFailed)
        XCTAssertEqual(entry.approvedBy, "reviewer")
        XCTAssertFalse(entry.lastError?.contains("/Users/jinwoo") ?? true, "queue errors are scrubbed too")

        // The join is the point: an entry names a task by untruncated id.
        XCTAssertEqual(snapshot.mergeQueueItem(for: parsed)?.id, entry.id)

        XCTAssertEqual(snapshot.panelRuns.first?.title, "Review run")
    }

    /// The team board is the board's other producer and still speaks `id` /
    /// `result` / `result_path`. Its scrubbing used to be covered through the
    /// coordinator client, which never carried those fields — so the coverage
    /// moves here, to the parser that actually sees them.
    func testTeamBoardTaskParserKeepsScrubbingResultPaths() throws {
        let parsed = try XCTUnwrap(ReviewBoardTask(dictionary: [
            "id": "task-123",
            "team_name": "ws",
            "title": "Review /Users/jinwoo/private/repo",
            "status": "review_ready",
            "priority": 1,
            "labels": ["merge-failed"],
            "result": "see /Users/jinwoo/private/repo/token.txt abcdefabcdefabcdefabcdefabcdefabcdef",
            "result_path": "/Users/jinwoo/private/repo/secret.txt",
        ]))

        XCTAssertEqual(parsed.id, "task-123")
        XCTAssertEqual(parsed.rawID, "task-123", "short ids are not shortened further")
        XCTAssertEqual(parsed.resultPath, "…/secret.txt")
        XCTAssertFalse(parsed.result?.contains("/Users/jinwoo") ?? true)
    }

    /// A coordinator row read by the team board's parser is not a partial
    /// read, it is no read at all — the guard rejects it. Pinned so the two
    /// parsers cannot quietly be collapsed into one that guesses.
    func testTeamBoardParserRejectsACoordinatorRow() {
        XCTAssertNil(ReviewBoardTask(dictionary: [
            "task_id": "tsk_8d144b235ec342019a6d2bf39ef65296",
            "title": "Wire the merge queue",
        ]))
    }

    func testRequestThrowsForJSONRPCErrorBeforeResult() async throws {
        let socketPath = "/tmp/tm-coordinator-error-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeCoordinatorServer(socketPath: socketPath, errorMethods: ["orchestration.status"])
        let task = try server.start(expectedRequests: 4)
        defer {
            server.stop()
            task.cancel()
        }

        let client = ReviewBoardCoordinatorClient(socketPath: socketPath)
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("Expected JSON-RPC error")
        } catch ReviewBoardCoordinatorError.jsonRPCError(let code, let message) {
            XCTAssertEqual(code, -32001)
            XCTAssertEqual(message, "mem-mesh unavailable")
        }
    }

    func testEventFrameParserTreatsRawIntentEventsAndGapAsRelevant() {
        XCTAssertEqual(
            ReviewBoardCoordinatorClient.eventFrame(from: #"{"kind":"event_gap","missed":4}"#),
            .gap
        )
        XCTAssertEqual(
            ReviewBoardCoordinatorClient.eventFrame(from: #"{"kind":"error","code":"event_too_large","dropped":true}"#),
            .gap
        )
        XCTAssertEqual(
            ReviewBoardCoordinatorClient.eventFrame(from: #"{"kind":"task_created","task_id":"task-1"}"#),
            .relevant
        )
        XCTAssertEqual(
            ReviewBoardCoordinatorClient.eventFrame(from: #"{"kind":"review_snapshot_recorded","task_id":"task-1"}"#),
            .relevant
        )
        XCTAssertEqual(
            ReviewBoardCoordinatorClient.eventFrame(from: #"{"kind":"merge_queue_transitioned","task_id":"task-1","to":"ready"}"#),
            .relevant
        )
        XCTAssertEqual(
            ReviewBoardCoordinatorClient.eventFrame(from: #"{"jsonrpc":"2.0","id":1,"result":{"subscribed":true}}"#),
            .ack
        )
        XCTAssertEqual(
            ReviewBoardCoordinatorClient.eventFrame(from: #"{"kind":"keepalive"}"#),
            .keepalive
        )
        XCTAssertEqual(
            ReviewBoardCoordinatorClient.eventFrame(from: #"{"kind":"log_appended"}"#),
            .ignored
        )
    }

    /// The app spawns the coordinator and subscribes moments later, so the
    /// first connection routinely lands before it is listening. That used to
    /// end the subscription for the life of the process — silently, and with
    /// it everything the coordinator would have told the app. The subscription
    /// has to survive being early.
    func testSubscribeEventsKeepsTryingUntilTheCoordinatorIsListening() throws {
        let socketPath = "/tmp/tm-coordinator-late-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let client = ReviewBoardCoordinatorClient(socketPath: socketPath)
        defer { client.stopSubscribing() }

        let expectation = expectation(description: "events after a late start")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = false

        // Subscribe against nothing at all.
        client.subscribeEvents { expectation.fulfill() }

        // The coordinator turns up afterwards, as it does in practice.
        let server = FakeCoordinatorEventServer(socketPath: socketPath)
        var task: Task<Void, Error>?
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            task = try? server.start(lines: [
                #"{"jsonrpc":"2.0","id":1,"result":{"subscribed":true}}"#,
                #"{"kind":"task_created","task_id":"task-late"}"#,
            ])
        }
        defer {
            server.stop()
            task?.cancel()
        }

        wait(for: [expectation], timeout: 10)
    }

    func testSubscribeEventsConsumesRawJSONLStreamAndIgnoresAckKeepalive() throws {
        let socketPath = "/tmp/tm-coordinator-events-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeCoordinatorEventServer(socketPath: socketPath)
        let task = try server.start(lines: [
            #"{"jsonrpc":"2.0","id":1,"result":{"subscribed":true}}"#,
            #"{"kind":"keepalive"}"#,
            #"{"kind":"task_created","task_id":"task-1"}"#,
            #"{"kind":"event_gap","missed":9}"#,
            #"{"kind":"error","code":"event_too_large","dropped":true}"#,
            #"{"kind":"review_snapshot_recorded","task_id":"task-1"}"#,
            #"{"kind":"merge_queue_transitioned","task_id":"task-1","to":"ready"}"#,
            #"{"kind":"log_appended"}"#,
        ])
        defer {
            server.stop()
            task.cancel()
        }

        let expectation = expectation(description: "relevant coordinator events")
        expectation.expectedFulfillmentCount = 5
        expectation.assertForOverFulfill = true

        ReviewBoardCoordinatorClient(socketPath: socketPath).subscribeEvents {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }
}

private final class FakeCoordinatorServer: @unchecked Sendable {
    enum Failure: Error {
        case syscall(String, Int32)
        case invalidRequest
    }

    let socketPath: String
    let errorMethods: Set<String>
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFDs: Set<Int32> = []

    init(socketPath: String, errorMethods: Set<String> = []) {
        self.socketPath = socketPath
        self.errorMethods = errorMethods
    }

    func start(expectedRequests: Int) throws -> Task<Void, Error> {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.syscall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else {
            close(fd)
            throw Failure.syscall("socket path", ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                for (offset, byte) in path.enumerated() {
                    bytes[offset] = CChar(bitPattern: byte)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.syscall("bind", code)
        }
        guard listen(fd, Int32(expectedRequests)) == 0 else {
            let code = errno
            close(fd)
            throw Failure.syscall("listen", code)
        }
        listenerFD = fd

        return Task.detached { [self] in
            defer { stop() }
            for _ in 0..<expectedRequests {
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pollFD, 1, 10_000) > 0 else { throw Failure.syscall("poll", errno) }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { throw Failure.syscall("accept", errno) }
                register(client)
                defer {
                    unregister(client)
                    close(client)
                }
                try handle(client)
            }
        }
    }

    func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        let clients = clientFDs
        lock.unlock()
        for client in clients {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
    }

    private func register(_ fd: Int32) {
        lock.lock()
        clientFDs.insert(fd)
        lock.unlock()
    }

    private func unregister(_ fd: Int32) {
        lock.lock()
        clientFDs.remove(fd)
        lock.unlock()
    }

    private func handle(_ fd: Int32) throws {
        guard let line = ReviewBoardCoordinatorClient.readLine(fd: fd),
              let data = line.data(using: .utf8),
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = request["method"] as? String else {
            throw Failure.invalidRequest
        }
        let id = request["id"] as? Int ?? 1
        if errorMethods.contains(method) {
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32001, "message": "mem-mesh unavailable"],
                "result": ["ignored": true],
            ]
            let responseData = try JSONSerialization.data(withJSONObject: response)
            XCTAssertTrue(ReviewBoardCoordinatorClient.writeLine(fd: fd, data: responseData))
            return
        }
        let result: Any
        switch method {
        // These keys are a contract with the coordinator, not a fixture this
        // file is free to invent: a fake that answers whatever the parser
        // happens to read stays green while the real coordinator sends
        // something else, which is exactly how `mem_mesh_available` went
        // unsent for the whole of its life while both sides had tests. The
        // other half is pinned in daemon/tm-coordinator/tests/status.rs —
        // change one and change the other.
        case "orchestration.status":
            result = [
                "mem_mesh_available": false,
                "suspect_host": true,
                "fenced_zombie": true,
                "panel_runs": [
                    ["run": "abcdefabcdefabcdefabcdefabcdefab", "title": "Review run", "phase": "checks", "terminal": false],
                ],
            ]
        // Field-for-field what a live coordinator returns — captured from
        // `task.list` over its own socket, not from what the parser wanted to
        // see. The board reads `task_id`, `project_id` and `updated_at_ms`;
        // there is no `id`, no `team_name`, no `result`.
        case "task.list":
            result = [
                "tasks": [
                    [
                        "task_id": "tsk_8d144b235ec342019a6d2bf39ef65296",
                        "project_id": "prj_819413b3d02d4b319374d6004a68628d",
                        "title": "Review /Users/jinwoo/private/repo",
                        "body": "",
                        "status": "queued_for_merge",
                        "priority": 1,
                        "depends_on": [],
                        "created_by": "leader",
                        "created_at_ms": 1_784_882_974_390,
                        "updated_at_ms": 1_784_882_974_390,
                    ],
                ],
            ]
        case "merge.queue":
            result = [
                "items": [
                    [
                        "queue_id": "mrq_2f1c4d5e6a7b8c9d0e1f2a3b4c5d6e7f",
                        "project_id": "prj_819413b3d02d4b319374d6004a68628d",
                        "task_id": "tsk_8d144b235ec342019a6d2bf39ef65296",
                        "attempt_id": "att_9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d",
                        "status": "failed",
                        "approved_by": "reviewer",
                        "approved_at_ms": 1_784_882_974_390,
                        "last_error": "rebase onto /Users/jinwoo/private/repo failed",
                    ],
                ],
            ]
        case "events.subscribe":
            result = ["subscribed": true]
        default:
            result = [:]
        }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        let responseData = try JSONSerialization.data(withJSONObject: response)
        XCTAssertTrue(ReviewBoardCoordinatorClient.writeLine(fd: fd, data: responseData))
    }
}

private final class FakeCoordinatorEventServer: @unchecked Sendable {
    enum Failure: Error {
        case syscall(String, Int32)
        case invalidRequest
    }

    let socketPath: String
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFDs: Set<Int32> = []

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start(lines: [String]) throws -> Task<Void, Error> {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.syscall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else {
            close(fd)
            throw Failure.syscall("socket path", ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                for (offset, byte) in path.enumerated() {
                    bytes[offset] = CChar(bitPattern: byte)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.syscall("bind", code)
        }
        guard listen(fd, 1) == 0 else {
            let code = errno
            close(fd)
            throw Failure.syscall("listen", code)
        }
        listenerFD = fd

        return Task.detached { [self] in
            defer { stop() }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 10_000) > 0 else { throw Failure.syscall("poll", errno) }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { throw Failure.syscall("accept", errno) }
            register(client)
            defer {
                unregister(client)
                close(client)
            }
            guard ReviewBoardCoordinatorClient.readLine(fd: client) != nil else {
                throw Failure.invalidRequest
            }
            for line in lines {
                guard ReviewBoardCoordinatorClient.writeLine(fd: client, data: Data(line.utf8)) else {
                    throw Failure.syscall("write", errno)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        let clients = clientFDs
        lock.unlock()
        for client in clients {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
    }

    private func register(_ fd: Int32) {
        lock.lock()
        clientFDs.insert(fd)
        lock.unlock()
    }

    private func unregister(_ fd: Int32) {
        lock.lock()
        clientFDs.remove(fd)
        lock.unlock()
    }
}

@MainActor
final class CoordinatorRemoteReadbackTests: XCTestCase {
    func test_extracts_agent_text_from_stream_json() {
        let lines = [
            #"{"type":"system","subtype":"init","cwd":"/root/remote-demo"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"3\n\nSTATUS: DONE"}]}}"#,
            #"{"is_error":false,"num_turns":2}"#,
        ]
        let text = CoordinatorPlacementDispatcher.plainText(fromHostOutput: lines)
        XCTAssertEqual(text, "3\n\nSTATUS: DONE")
    }

    func test_passes_through_non_json_lines() {
        let text = CoordinatorPlacementDispatcher.plainText(fromHostOutput: ["STATUS: DONE", "answer"])
        XCTAssertEqual(text, "STATUS: DONE\nanswer")
    }

    func test_summary_keeps_an_answer_written_above_the_header() {
        // Agents put the answer first however the instruction is worded. A
        // remote reply is the agent's whole turn, so text above the header is
        // still the agent's — unlike a pane read, where it is scrollback.
        let summary = CoordinatorPlacementDispatcher.summary(fromRemoteReply: """
        3

        STATUS: DONE
        FILES: none
        VERIFY: wc -l < data.txt
        NEXT: NONE
        FULL_REPORT: n/a
        """)
        XCTAssertEqual(summary, "3")
    }

    func test_summary_is_nil_when_only_a_header_was_sent() {
        XCTAssertNil(CoordinatorPlacementDispatcher.summary(
            fromRemoteReply: "STATUS: DONE\nNEXT: NONE\n"
        ))
    }
}
