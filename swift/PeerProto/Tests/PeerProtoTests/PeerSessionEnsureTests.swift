import XCTest
@testable import PeerProto

private actor EnsureMockHost {
    private let transport: MockTransport
    private var pendingInbound = Data()
    private var seq: UInt64 = 0

    init(transport: MockTransport) {
        self.transport = transport
    }

    func readRequest() async throws -> Termmesh_Peer_V1_EnsureSurfaceRequest {
        while true {
            if let envelope = try decodeFrame(from: &pendingInbound) {
                guard case .ensureSurfaceRequest(let request) = envelope.payload else {
                    throw PeerSessionError.unexpectedMessage("expected EnsureSurfaceRequest")
                }
                return request
            }
            pendingInbound.append(await transport.serverRead())
        }
    }

    func sendResponse(
        requestID: Data,
        result: Termmesh_Peer_V1_EnsureSurfaceResult = .created,
        surfaceByte: UInt8 = 0xA1
    ) async throws {
        var response = Termmesh_Peer_V1_EnsureSurfaceResponse()
        response.requestID = requestID
        response.result = result
        response.surfaceID = Data(repeating: surfaceByte, count: 16)
        response.instanceID = Data(repeating: surfaceByte &+ 1, count: 16)
        response.generation = 1
        response.pid = 123
        response.specHash = Data(repeating: surfaceByte &+ 2, count: 32)
        var envelope = Termmesh_Peer_V1_Envelope()
        seq &+= 1
        envelope.seq = seq
        envelope.ensureSurfaceResponse = response
        await transport.serverWrite(try encodeFrame(envelope))
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor CloseCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor BlockingTestTransport {
    enum TransportError: Error { case closed }

    private var writeWaiters: [CheckedContinuation<Void, Error>] = []
    private var readWaiter: CheckedContinuation<Data, Error>?
    private(set) var writeStarted = false
    private(set) var closeCount = 0
    private(set) var writeCount = 0

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { readWaiter = $0 }
    }

    func write(_: Data) async throws {
        writeStarted = true
        writeCount += 1
        try await withCheckedThrowingContinuation { writeWaiters.append($0) }
    }

    func close() {
        closeCount += 1
        let writes = writeWaiters
        writeWaiters.removeAll()
        for waiter in writes { waiter.resume(throwing: TransportError.closed) }
        readWaiter?.resume(throwing: TransportError.closed)
        readWaiter = nil
    }

    func waitForWriteStart() async {
        while !writeStarted { await Task.yield() }
    }

    func waitForWriteCount(_ count: Int) async {
        while writeCount < count { await Task.yield() }
    }
}

final class PeerSessionEnsureTests: XCTestCase {
    private enum TestWriteError: Error, Equatable {
        case rejected
    }

    func testEnsureCarriesExplicitEnvironmentMap() async throws {
        let transport = MockTransport()
        let host = EnsureMockHost(transport: transport)
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        let requestID = Data(repeating: 0x31, count: 16)
        let pending = Task {
            try await session.ensureSurface(
                requestID: requestID,
                key: "agent-env",
                cwd: "/tmp",
                executable: "/bin/sh",
                kind: "agent",
                environment: [
                    "HTTPS_PROXY": "http://proxy.example:8080",
                    "TERMMESH_AGENT_NAME": "reviewer",
                ]
            )
        }

        let request = try await host.readRequest()
        XCTAssertEqual(request.env["HTTPS_PROXY"], "http://proxy.example:8080")
        XCTAssertEqual(request.env["TERMMESH_AGENT_NAME"], "reviewer")
        try await host.sendResponse(requestID: requestID)
        _ = try await pending.value
    }

    func testEnsureEnvironmentUsesPortableBoundedValidationBeforeWriting() async throws {
        let invalid: [[String: String]] = [
            ["한글": "value"],
            ["9STARTS_WITH_DIGIT": "value"],
            ["OK": String(repeating: "x", count: PeerEnsureEnvironment.maximumValueUTF8Bytes + 1)],
            ["OK": "bad\0value"],
            Dictionary(uniqueKeysWithValues: (0...PeerEnsureEnvironment.maximumCount).map {
                ("K\($0)", "v")
            }),
        ]
        for environment in invalid {
            let writes = CloseCounter()
            let session = PeerSession(
                read: { Data() },
                write: { _ in await writes.increment() }
            )
            do {
                _ = try await session.ensureSurface(
                    key: "invalid-env",
                    cwd: "/tmp",
                    executable: "/bin/sh",
                    environment: environment
                )
                XCTFail("invalid environment must fail before writing")
            } catch {
                XCTAssertTrue(String(describing: error).contains("Environment"))
            }
            let writeCount = await writes.value
            XCTAssertEqual(writeCount, 0)
        }
    }

    func testSurfaceExitedIsClassifiedWithExactStatus() async throws {
        let transport = MockTransport()
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        let surfaceID = Data(repeating: 0x52, count: 16)
        var exited = Termmesh_Peer_V1_SurfaceExited()
        exited.surfaceID = surfaceID
        exited.exitCode = 17
        exited.signal = 0
        exited.reason = "exited"
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.seq = 1
        envelope.surfaceExited = exited

        let waiting = Task { try await session.receiveNextMessage() }
        await transport.serverWrite(try encodeFrame(envelope))

        guard case .surfaceExited(let actualID, let code, let signal, let reason) =
            try await waiting.value else {
            return XCTFail("expected SurfaceExited")
        }
        XCTAssertEqual(actualID, surfaceID)
        XCTAssertEqual(code, 17)
        XCTAssertEqual(signal, 0)
        XCTAssertEqual(reason, "exited")
    }

    func testConcurrentEnsureCorrelatesOutOfOrderResponses() async throws {
        let transport = MockTransport()
        let host = EnsureMockHost(transport: transport)
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        let firstID = Data(repeating: 0x01, count: 16)
        let secondID = Data(repeating: 0x02, count: 16)

        async let first = session.ensureSurface(
            requestID: firstID, key: "first", cwd: "/tmp", executable: "/bin/sh"
        )
        async let second = session.ensureSurface(
            requestID: secondID, key: "second", cwd: "/tmp", executable: "/bin/sh"
        )

        let requestA = try await host.readRequest()
        let requestB = try await host.readRequest()
        let byteForRequest: (Data) -> UInt8 = { requestID in
            requestID == firstID ? 0xA1 : 0xB1
        }
        try await host.sendResponse(
            requestID: requestB.requestID,
            surfaceByte: byteForRequest(requestB.requestID)
        )
        try await host.sendResponse(
            requestID: requestA.requestID,
            surfaceByte: byteForRequest(requestA.requestID)
        )

        let outcomes = try await [first, second]
        XCTAssertEqual(outcomes[0].requestID, firstID)
        XCTAssertEqual(outcomes[0].surfaceID, Data(repeating: 0xA1, count: 16))
        XCTAssertEqual(outcomes[1].requestID, secondID)
        XCTAssertEqual(outcomes[1].surfaceID, Data(repeating: 0xB1, count: 16))
    }

    func testLastWaiterCancellationClosesTransportAndReleasesSession() async throws {
        let transport = MockTransport()
        let host = EnsureMockHost(transport: transport)
        let closeCounter = CloseCounter()
        var session: PeerSession? = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) },
            close: {
                await closeCounter.increment()
                await transport.serverWrite(Data())
            }
        )
        weak let weakSession = session
        let cancelledID = Data(repeating: 0x11, count: 16)

        let cancelled = Task { [weak session] in
            guard let session else { throw CancellationError() }
            return try await session.ensureSurface(
                requestID: cancelledID, key: "cancel", cwd: "/tmp", executable: "/bin/sh"
            )
        }
        _ = try await host.readRequest()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled ensure must throw")
        } catch is CancellationError {
            // Expected.
        }
        let closeCount = await closeCounter.value
        XCTAssertEqual(closeCount, 1)
        do {
            _ = try await session?.ensureSurface(
                requestID: Data(repeating: 0x12, count: 16),
                key: "after-cancel",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
            XCTFail("cancelled session must reject future ensure")
        } catch PeerSessionError.sessionClosed(reason: "request cancelled") {
            // Expected.
        }
        session = nil
        for _ in 0..<100 where weakSession != nil { await Task.yield() }
        XCTAssertNil(weakSession, "closed read pump must not retain PeerSession")
    }

    func testCancellationBeforeRegistrationDoesNotWriteOrLeak() async throws {
        let gate = TestGate()
        let transport = BlockingTestTransport()
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) },
            close: { await transport.close() }
        )
        let request = Task {
            await gate.wait()
            return try await session.ensureSurface(
                requestID: Data(repeating: 0x13, count: 16),
                key: "cancel-before",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
        }
        request.cancel()
        await gate.open()
        do {
            _ = try await request.value
            XCTFail("pre-cancelled ensure must throw")
        } catch is CancellationError {
            // Expected.
        }
        for _ in 0..<100 where await transport.closeCount == 0 { await Task.yield() }
        let writeStarted = await transport.writeStarted
        let closeCount = await transport.closeCount
        XCTAssertFalse(writeStarted)
        XCTAssertEqual(closeCount, 1)
    }

    func testCancellationDuringSuspendedWriteClosesTransport() async throws {
        let transport = BlockingTestTransport()
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) },
            close: { await transport.close() }
        )
        let request = Task {
            try await session.ensureSurface(
                requestID: Data(repeating: 0x14, count: 16),
                key: "cancel-write",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
        }
        await transport.waitForWriteStart()
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("cancelled blocked write must throw")
        } catch is CancellationError {
            // Expected.
        }
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testCancelledSuspendedWriteClosesSiblingEnsure() async throws {
        let transport = BlockingTestTransport()
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) },
            close: { await transport.close() }
        )
        let first = Task {
            try await session.ensureSurface(
                requestID: Data(repeating: 0x15, count: 16),
                key: "first-write",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
        }
        await transport.waitForWriteCount(1)
        let second = Task {
            try await session.ensureSurface(
                requestID: Data(repeating: 0x16, count: 16),
                key: "second-write",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
        }
        await transport.waitForWriteCount(2)
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("cancelled write must throw")
        } catch is CancellationError {
            // Expected.
        }
        do {
            _ = try await second.value
            XCTFail("sibling must terminate when shared transport closes")
        } catch BlockingTestTransport.TransportError.closed {
            // Expected: close unblocked the suspended write directly.
        } catch PeerSessionError.sessionClosed {
            // Also valid if terminal teardown reaches its waiter first.
        }
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testDirectRPCOverlapWithEnsureIsRejectedBeforeSend() async throws {
        let transport = MockTransport()
        let host = EnsureMockHost(transport: transport)
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        let requestID = Data(repeating: 0x17, count: 16)
        let ensure = Task {
            try await session.ensureSurface(
                requestID: requestID,
                key: "overlap",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
        }
        _ = try await host.readRequest()

        do {
            _ = try await session.listSurfaces()
            XCTFail("direct response RPC must reject overlap with inbound pump")
        } catch PeerSessionError.concurrentReceiveOperation {
            // Rejected before ListSurfaces is written.
        }
        try await host.sendResponse(requestID: requestID, surfaceByte: 0x17)
        let outcome = try await ensure.value
        XCTAssertEqual(outcome.requestID, requestID)
    }

    func testNonEnsureFrameRemainsAvailableDuringEnsure() async throws {
        let transport = MockTransport()
        let host = EnsureMockHost(transport: transport)
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        let requestID = Data(repeating: 0x18, count: 16)
        let request = Task {
            try await session.ensureSurface(
                requestID: requestID, key: "buffer", cwd: "/tmp", executable: "/bin/sh"
            )
        }
        _ = try await host.readRequest()

        var pty = Termmesh_Peer_V1_PtyData()
        pty.surfaceID = Data(repeating: 0x19, count: 16)
        pty.byteSeq = 7
        pty.payload = Data("kept".utf8)
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.seq = 1
        envelope.ptyData = pty
        await transport.serverWrite(try encodeFrame(envelope))
        try await host.sendResponse(requestID: requestID, surfaceByte: 0x1A)

        _ = try await request.value
        let incoming = try await session.receiveNextMessage()
        guard case .ptyData(let surfaceID, let byteSeq, let payload) = incoming else {
            XCTFail("PTY frame must remain available; ensure response must not surface as .other")
            return
        }
        XCTAssertEqual(surfaceID, pty.surfaceID)
        XCTAssertEqual(byteSeq, 7)
        XCTAssertEqual(payload, Data("kept".utf8))
    }

    func testSendFailureRemovesPendingWaiter() async throws {
        let requestID = Data(repeating: 0x1B, count: 16)
        let session = PeerSession(
            read: { Data() },
            write: { _ in throw TestWriteError.rejected }
        )

        for _ in 0..<2 {
            do {
                _ = try await session.ensureSurface(
                    requestID: requestID, key: "send-fail", cwd: "/tmp", executable: "/bin/sh"
                )
                XCTFail("send failure must be returned")
            } catch TestWriteError.rejected {
                // A second use of the same id reaches write again instead of
                // seeing a leaked local waiter/duplicate-id error.
            }
        }
    }

    func testSessionEofFailsPendingEnsureAndFutureCalls() async throws {
        let transport = MockTransport()
        let host = EnsureMockHost(transport: transport)
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        let request = Task {
            try await session.ensureSurface(
                requestID: Data(repeating: 0x1C, count: 16),
                key: "eof",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
        }
        _ = try await host.readRequest()
        await transport.serverWrite(Data())

        do {
            _ = try await request.value
            XCTFail("EOF must fail pending ensure")
        } catch PeerSessionError.unexpectedEof {
            // Expected.
        }
        do {
            _ = try await session.ensureSurface(
                requestID: Data(repeating: 0x1D, count: 16),
                key: "after-eof",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
            XCTFail("closed session must reject future ensure")
        } catch PeerSessionError.unexpectedEof {
            // Expected.
        }
    }

    func testInboundGoodbyeIsDeliveredThenSessionBecomesTerminal() async throws {
        let transport = MockTransport()
        let host = EnsureMockHost(transport: transport)
        let closeCounter = CloseCounter()
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) },
            close: {
                await closeCounter.increment()
                await transport.serverWrite(Data())
            }
        )
        let ensure = Task {
            try await session.ensureSurface(
                requestID: Data(repeating: 0x1E, count: 16),
                key: "goodbye",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
        }
        _ = try await host.readRequest()
        let receive = Task { try await session.receiveNextMessage() }

        var goodbye = Termmesh_Peer_V1_Goodbye()
        goodbye.reason = "maintenance"
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.seq = 9
        envelope.goodbye = goodbye
        await transport.serverWrite(try encodeFrame(envelope))

        guard case .goodbye(let reason) = try await receive.value else {
            XCTFail("Goodbye must be delivered before terminal error")
            return
        }
        XCTAssertEqual(reason, "maintenance")
        do {
            _ = try await ensure.value
            XCTFail("Goodbye must fail pending ensure")
        } catch PeerSessionError.sessionClosed(reason: "maintenance") {
            // Expected.
        }
        do {
            _ = try await session.receiveNextMessage()
            XCTFail("future receive must fail after Goodbye")
        } catch PeerSessionError.sessionClosed(reason: "maintenance") {
            // Expected.
        }
        do {
            _ = try await session.ensureSurface(
                requestID: Data(repeating: 0x1F, count: 16),
                key: "after-goodbye",
                cwd: "/tmp",
                executable: "/bin/sh"
            )
            XCTFail("future ensure must fail after Goodbye")
        } catch PeerSessionError.sessionClosed(reason: "maintenance") {
            // Expected.
        }
        let closeCount = await closeCounter.value
        XCTAssertEqual(closeCount, 1)
    }

    func testDuplicateResponseResumesContinuationOnlyOnce() async throws {
        let demux = PeerSessionDemux()
        let requestID = Data(repeating: 0x21, count: 16)
        let stream = try await demux.registerEnsure(requestID: requestID)
        let waiter = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        var response = validResponse(requestID: requestID)
        await demux.routeEnsureResponse(response)
        response.pid = 999
        await demux.routeEnsureResponse(response)

        let waiterValue = try await waiter.value
        let received = try XCTUnwrap(waiterValue)
        XCTAssertEqual(received.pid, 123)
        let pendingCount = await demux.pendingEnsureCount
        XCTAssertEqual(pendingCount, 0)
    }

    func testMalformedResponseFailsAllPendingWithoutLeak() async throws {
        let demux = PeerSessionDemux()
        let firstID = Data(repeating: 0x31, count: 16)
        let secondID = Data(repeating: 0x32, count: 16)
        let firstStream = try await demux.registerEnsure(requestID: firstID)
        let secondStream = try await demux.registerEnsure(requestID: secondID)
        let first = Task {
            var iterator = firstStream.makeAsyncIterator()
            return try await iterator.next()
        }
        let second = Task {
            var iterator = secondStream.makeAsyncIterator()
            return try await iterator.next()
        }

        var malformed = validResponse(requestID: Data())
        malformed.requestID = Data()
        await demux.routeEnsureResponse(malformed)

        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("malformed response must fail pending ensure")
            } catch PeerSessionError.malformedEnsureResponse {
                // Expected.
            }
        }
        let pendingCount = await demux.pendingEnsureCount
        XCTAssertEqual(pendingCount, 0)
    }

    func testOversizedResponseFailsPendingRequest() async throws {
        let transport = MockTransport()
        let host = EnsureMockHost(transport: transport)
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        let requestID = Data(repeating: 0x41, count: 16)
        let request = Task {
            try await session.ensureSurface(
                requestID: requestID, key: "oversized", cwd: "/tmp", executable: "/bin/sh"
            )
        }
        _ = try await host.readRequest()

        var oversizedLength = (maxFrameBytes + 1).littleEndian
        let prefix = withUnsafeBytes(of: &oversizedLength) { Data($0) }
        await transport.serverWrite(prefix)

        do {
            _ = try await request.value
            XCTFail("oversized response must fail")
        } catch PeerSessionError.framing(.frameTooLarge(let size)) {
            XCTAssertEqual(size, maxFrameBytes + 1)
        }
    }

    func testMalformedKnownResponseFailsOnlyItsWaiter() async throws {
        let demux = PeerSessionDemux()
        let requestID = Data(repeating: 0x51, count: 16)
        let stream = try await demux.registerEnsure(requestID: requestID)
        let waiter = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        var response = validResponse(requestID: requestID)
        response.surfaceID = Data()
        await demux.routeEnsureResponse(response)
        do {
            _ = try await waiter.value
            XCTFail("invalid successful response must fail")
        } catch PeerSessionError.malformedEnsureResponse(let reason) {
            XCTAssertEqual(reason, "surface_id must be 16 bytes")
        }
        let pendingCount = await demux.pendingEnsureCount
        XCTAssertEqual(pendingCount, 0)
    }

    private func validResponse(requestID: Data) -> Termmesh_Peer_V1_EnsureSurfaceResponse {
        var response = Termmesh_Peer_V1_EnsureSurfaceResponse()
        response.requestID = requestID
        response.result = .created
        response.surfaceID = Data(repeating: 0x61, count: 16)
        response.instanceID = Data(repeating: 0x62, count: 16)
        response.generation = 1
        response.pid = 123
        response.specHash = Data(repeating: 0x63, count: 32)
        return response
    }
}
