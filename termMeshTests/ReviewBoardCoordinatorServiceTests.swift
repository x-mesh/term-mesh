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
