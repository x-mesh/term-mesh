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

    func testHostObservationParamsNeverClaimCapacity() {
        let params = CoordinatorHostObservation(
            hostKey: "ssh:root@jw-server",
            projectRoots: ["/root/x-kit", "/root/demo-project"],
            isLive: true
        ).rpcParams

        XCTAssertEqual(params["total_slots"] as? Int, 0)
        XCTAssertEqual(params["used_slots"] as? Int, 0)
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
        let task = try server.start(expectedRequests: 3)
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
        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.id, "task-123")
        XCTAssertEqual(snapshot.tasks.first?.resultPath, "…/secret.txt")
        XCTAssertFalse(snapshot.tasks.first?.result?.contains("/Users/jinwoo") ?? true)
        XCTAssertEqual(snapshot.panelRuns.first?.title, "Review run")
    }

    func testRequestThrowsForJSONRPCErrorBeforeResult() async throws {
        let socketPath = "/tmp/tm-coordinator-error-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeCoordinatorServer(socketPath: socketPath, errorMethods: ["orchestration.status"])
        let task = try server.start(expectedRequests: 3)
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
        case "orchestration.status":
            result = [
                "mem_mesh_available": false,
                "suspect_host": true,
                "fenced_zombie": true,
                "panel_runs": [
                    ["run": "abcdefabcdefabcdefabcdefabcdefab", "title": "Review run", "phase": "checks", "terminal": false],
                ],
            ]
        case "task.list":
            result = [
                "tasks": [
                    [
                        "id": "task-123",
                        "team_name": "ws",
                        "title": "Review /Users/jinwoo/private/repo",
                        "status": "review_ready",
                        "priority": 1,
                        "labels": ["merge-failed"],
                        "result": "see /Users/jinwoo/private/repo/token.txt abcdefabcdefabcdefabcdefabcdefabcdef",
                        "result_path": "/Users/jinwoo/private/repo/secret.txt",
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
