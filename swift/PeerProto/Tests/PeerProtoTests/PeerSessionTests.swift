import XCTest
@testable import PeerProto

/// One-shot flag that a `Sendable` callback can fire and an async test
/// body can wait on. Polls a few times per the timeout — simple and
/// avoids `CheckedContinuation` cancellation footguns when the timeout
/// branch wins inside a `TaskGroup`.
actor AsyncFlag {
    private var fired = false

    func signal() { fired = true }

    func wait(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if fired { return true }
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }
        return fired
    }
}

/// Thread-safe counter a `Sendable` callback can increment and an async
/// test body can read back. Used to assert exactly-once firing of
/// `onFirstMiss` / `onMissRecovered`.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Toggle used by heartbeat tests that need to simulate a transient Pong
/// outage (pause replies, then resume) without tearing down the mock
/// transport. See `testHeartbeatFirstMissThenRecovers`.
actor PongGate {
    private var replying = true
    func setReplying(_ value: Bool) { replying = value }
    func shouldReply() -> Bool { replying }
}

/// In-memory paired channel: one side's writes appear on the other side's
/// reads. Used to run a "server" coroutine alongside the `PeerSession`
/// client in a single test process, no Unix socket required.
actor MockTransport {
    private var clientToServer: [Data] = []
    private var serverToClient: [Data] = []
    private var clientToServerWaiter: CheckedContinuation<Data, Never>?
    private var serverToClientWaiter: CheckedContinuation<Data, Never>?
    private var clientWriteCount = 0

    func clientWrite(_ data: Data) {
        clientWriteCount += 1
        if let waiter = serverToClientWaiter {
            // unused path
            _ = waiter
        }
        if let waiter = clientToServerWaiter {
            clientToServerWaiter = nil
            waiter.resume(returning: data)
        } else {
            clientToServer.append(data)
        }
    }

    func serverWrite(_ data: Data) {
        if let waiter = serverToClientWaiter {
            serverToClientWaiter = nil
            waiter.resume(returning: data)
        } else {
            serverToClient.append(data)
        }
    }

    func clientRead() async -> Data {
        if !serverToClient.isEmpty {
            return serverToClient.removeFirst()
        }
        return await withCheckedContinuation { cont in
            serverToClientWaiter = cont
        }
    }

    func serverRead() async -> Data {
        if !clientToServer.isEmpty {
            return clientToServer.removeFirst()
        }
        return await withCheckedContinuation { cont in
            clientToServerWaiter = cont
        }
    }

    func closeClientRead() {
        if let waiter = serverToClientWaiter {
            serverToClientWaiter = nil
            waiter.resume(returning: Data())
        } else {
            serverToClient.append(Data())
        }
    }

    func writtenFrameCount() -> Int { clientWriteCount }
}

/// Minimal server-side role for tests. Drives the opposite half of the
/// handshake defined in `docs/peer-federation-protocol.md`, then answers
/// ListSurfaces with a canned surface list.
actor MockHost {
    let transport: MockTransport
    var pendingInbound = Data()
    var seq: UInt64 = 0
    let surfaces: [Termmesh_Peer_V1_SurfaceInfo]

    init(transport: MockTransport, surfaces: [Termmesh_Peer_V1_SurfaceInfo]) {
        self.transport = transport
        self.surfaces = surfaces
    }

    func run() async throws {
        // 1. Read client Hello
        _ = try await readExpecting { env in
            if case .hello = env.payload { return true } else { return false }
        }

        // 2. Send host Hello
        var hostHello = Termmesh_Peer_V1_Hello()
        hostHello.protocolVersion = "1.0.0"
        hostHello.displayName = "mock-host"
        hostHello.peerID = Data(count: 16)
        hostHello.appVersion = "test"
        try await sendEnvelope { $0.hello = hostHello }

        // 3. Send AuthChallenge
        var challenge = Termmesh_Peer_V1_AuthChallenge()
        challenge.nonce = Data(count: 32)
        challenge.supportedMethods = ["ssh-passthrough"]
        try await sendEnvelope { $0.authChallenge = challenge }

        // 4. Read client Auth
        _ = try await readExpecting { env in
            if case .auth = env.payload { return true } else { return false }
        }

        // 5. Send AuthResult
        var result = Termmesh_Peer_V1_AuthResult()
        result.accepted = true
        result.sessionID = Data(count: 16)
        try await sendEnvelope { $0.authResult = result }

        // 6. Handle ListSurfaces
        _ = try await readExpecting { env in
            if case .listSurfaces = env.payload { return true } else { return false }
        }
        var list = Termmesh_Peer_V1_SurfaceList()
        list.surfaces = surfaces
        try await sendEnvelope { $0.surfaceList = list }
    }

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    private func sendEnvelope(configure: (inout Termmesh_Peer_V1_Envelope) -> Void) async throws {
        var env = Termmesh_Peer_V1_Envelope()
        env.seq = nextSeq()
        configure(&env)
        let data = try encodeFrame(env)
        await transport.serverWrite(data)
    }

    private func readFrame() async throws -> Termmesh_Peer_V1_Envelope {
        while true {
            if let env = try decodeFrame(from: &pendingInbound) {
                return env
            }
            let chunk = await transport.serverRead()
            if chunk.isEmpty { throw PeerSessionError.unexpectedEof }
            pendingInbound.append(chunk)
        }
    }

    private func readExpecting(_ match: (Termmesh_Peer_V1_Envelope) -> Bool) async throws -> Termmesh_Peer_V1_Envelope {
        let env = try await readFrame()
        if !match(env) {
            throw PeerSessionError.unexpectedMessage(String(describing: env.payload))
        }
        return env
    }
}

/// Drives the handshake plus the create → rename → delete → WorkspaceRemoved-push
/// sequence for `testWorkspaceLifecycleRPCs` / `testCreateWorkspaceRejected`.
/// Handshake steps are duplicated from `MockHost` rather than shared, since this
/// host's post-handshake behavior (workspace-lifecycle RPCs) has nothing to do
/// with `ListSurfaces`.
actor LifecycleMockHost {
    let transport: MockTransport
    var pendingInbound = Data()
    var seq: UInt64 = 0
    let assignedWorkspaceID: Data
    let createAccepted: Bool
    let createRejectReason: String

    private(set) var receivedCreateTitle: String?
    private(set) var receivedRename: (workspaceID: Data, title: String)?
    private(set) var receivedDeleteWorkspaceID: Data?

    init(
        transport: MockTransport,
        assignedWorkspaceID: Data,
        createAccepted: Bool = true,
        createRejectReason: String = ""
    ) {
        self.transport = transport
        self.assignedWorkspaceID = assignedWorkspaceID
        self.createAccepted = createAccepted
        self.createRejectReason = createRejectReason
    }

    func run() async throws {
        // 1-5: same handshake as MockHost.run().
        _ = try await readExpecting { env in
            if case .hello = env.payload { return true } else { return false }
        }
        var hostHello = Termmesh_Peer_V1_Hello()
        hostHello.protocolVersion = "1.0.0"
        hostHello.displayName = "mock-host"
        hostHello.peerID = Data(count: 16)
        hostHello.appVersion = "test"
        try await sendEnvelope { $0.hello = hostHello }

        var challenge = Termmesh_Peer_V1_AuthChallenge()
        challenge.nonce = Data(count: 32)
        challenge.supportedMethods = ["ssh-passthrough"]
        try await sendEnvelope { $0.authChallenge = challenge }

        _ = try await readExpecting { env in
            if case .auth = env.payload { return true } else { return false }
        }
        var result = Termmesh_Peer_V1_AuthResult()
        result.accepted = true
        result.sessionID = Data(count: 16)
        try await sendEnvelope { $0.authResult = result }

        // CreateWorkspaceRequest -> CreateWorkspaceResponse
        let createEnv = try await readExpecting { env in
            if case .createWorkspaceRequest = env.payload { return true } else { return false }
        }
        guard case .createWorkspaceRequest(let createReq) = createEnv.payload else {
            throw PeerSessionError.unexpectedMessage("expected CreateWorkspaceRequest")
        }
        receivedCreateTitle = createReq.title
        var resp = Termmesh_Peer_V1_CreateWorkspaceResponse()
        resp.accepted = createAccepted
        if createAccepted {
            resp.workspaceID = assignedWorkspaceID
        } else {
            resp.reason = createRejectReason
        }
        try await sendEnvelope { $0.createWorkspaceResponse = resp }
        guard createAccepted else { return }

        // RenameWorkspaceRequest (fire-and-forget)
        let renameEnv = try await readExpecting { env in
            if case .renameWorkspaceRequest = env.payload { return true } else { return false }
        }
        guard case .renameWorkspaceRequest(let renameReq) = renameEnv.payload else {
            throw PeerSessionError.unexpectedMessage("expected RenameWorkspaceRequest")
        }
        receivedRename = (renameReq.workspaceID, renameReq.title)

        // DeleteWorkspaceRequest (fire-and-forget)
        let deleteEnv = try await readExpecting { env in
            if case .deleteWorkspaceRequest = env.payload { return true } else { return false }
        }
        guard case .deleteWorkspaceRequest(let deleteReq) = deleteEnv.payload else {
            throw PeerSessionError.unexpectedMessage("expected DeleteWorkspaceRequest")
        }
        receivedDeleteWorkspaceID = deleteReq.workspaceID

        // Push WorkspaceRemoved for the deleted workspace, as the real host does.
        var removed = Termmesh_Peer_V1_WorkspaceRemoved()
        removed.workspaceID = deleteReq.workspaceID
        var update = Termmesh_Peer_V1_WorkspaceUpdate()
        update.workspaceRemoved = removed
        try await sendEnvelope { $0.workspaceUpdate = update }
    }

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    private func sendEnvelope(configure: (inout Termmesh_Peer_V1_Envelope) -> Void) async throws {
        var env = Termmesh_Peer_V1_Envelope()
        env.seq = nextSeq()
        configure(&env)
        let data = try encodeFrame(env)
        await transport.serverWrite(data)
    }

    private func readFrame() async throws -> Termmesh_Peer_V1_Envelope {
        while true {
            if let env = try decodeFrame(from: &pendingInbound) {
                return env
            }
            let chunk = await transport.serverRead()
            if chunk.isEmpty { throw PeerSessionError.unexpectedEof }
            pendingInbound.append(chunk)
        }
    }

    private func readExpecting(_ match: (Termmesh_Peer_V1_Envelope) -> Bool) async throws -> Termmesh_Peer_V1_Envelope {
        let env = try await readFrame()
        if !match(env) {
            throw PeerSessionError.unexpectedMessage(String(describing: env.payload))
        }
        return env
    }
}

/// Handshakes with a selectable capability set and optionally consumes one
/// post-handshake request without answering it. This models an older host and
/// a mixed-version host that advertises an RPC but silently drops its payload.
actor TeamRPCMockHost {
    let transport: MockTransport
    let capabilities: [String]
    let consumeRequest: Bool
    private var pendingInbound = Data()
    private var seq: UInt64 = 0

    init(
        transport: MockTransport,
        capabilities: [String],
        consumeRequest: Bool = false
    ) {
        self.transport = transport
        self.capabilities = capabilities
        self.consumeRequest = consumeRequest
    }

    func run() async throws {
        _ = try await readFrame() // client Hello
        var hello = Termmesh_Peer_V1_Hello()
        hello.protocolVersion = "1.0.0"
        hello.displayName = "team-rpc-host"
        hello.peerID = Data(count: 16)
        hello.appVersion = "test"
        hello.capabilities = capabilities
        try await sendEnvelope { $0.hello = hello }

        var challenge = Termmesh_Peer_V1_AuthChallenge()
        challenge.nonce = Data(count: 32)
        challenge.supportedMethods = ["ssh-passthrough"]
        try await sendEnvelope { $0.authChallenge = challenge }
        _ = try await readFrame() // client Auth

        var result = Termmesh_Peer_V1_AuthResult()
        result.accepted = true
        result.sessionID = Data(count: 16)
        try await sendEnvelope { $0.authResult = result }
        if consumeRequest { _ = try await readFrame() }
    }

    private func sendEnvelope(
        configure: (inout Termmesh_Peer_V1_Envelope) -> Void
    ) async throws {
        var envelope = Termmesh_Peer_V1_Envelope()
        seq += 1
        envelope.seq = seq
        configure(&envelope)
        await transport.serverWrite(try encodeFrame(envelope))
    }

    private func readFrame() async throws -> Termmesh_Peer_V1_Envelope {
        while true {
            if let envelope = try decodeFrame(from: &pendingInbound) { return envelope }
            let chunk = await transport.serverRead()
            if chunk.isEmpty { throw PeerSessionError.unexpectedEof }
            pendingInbound.append(chunk)
        }
    }
}

final class PeerSessionTests: XCTestCase {
    func testHandshakeAndListRoundTrip() async throws {
        let transport = MockTransport()

        var alpha = Termmesh_Peer_V1_SurfaceInfo()
        alpha.surfaceID = Data(repeating: 0xA1, count: 16)
        alpha.title = "alpha"
        alpha.cols = 80
        alpha.rows = 24
        alpha.attachable = true
        alpha.cwd = "/tmp"
        alpha.branch = "main"

        var bravo = Termmesh_Peer_V1_SurfaceInfo()
        bravo.surfaceID = Data(repeating: 0xB1, count: 16)
        bravo.title = "bravo"
        bravo.cols = 132
        bravo.rows = 43
        bravo.attachable = false
        bravo.cwd = "/var"
        bravo.branch = ""

        let host = MockHost(transport: transport, surfaces: [alpha, bravo])
        let hostTask = Task {
            try await host.run()
        }

        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )

        let info = try await session.handshake()
        XCTAssertEqual(info.hostDisplayName, "mock-host")
        XCTAssertEqual(info.hostProtocolVersion, "1.0.0")

        let surfaces = try await session.listSurfaces()
        XCTAssertEqual(surfaces.count, 2)
        XCTAssertEqual(surfaces[0].title, "alpha")
        XCTAssertEqual(surfaces[0].cwd, "/tmp")
        XCTAssertEqual(surfaces[0].branch, "main")
        XCTAssertTrue(surfaces[0].attachable)
        XCTAssertEqual(surfaces[1].title, "bravo")
        XCTAssertFalse(surfaces[1].attachable)

        try await hostTask.value
    }

    /// Round-trips the three workspace-lifecycle RPCs added for t5:
    /// `createWorkspace` (response-waiting), `renameWorkspace` /
    /// `deleteWorkspace` (fire-and-forget), and confirms the resulting
    /// `WorkspaceUpdate.workspaceRemoved` push decodes to
    /// `.workspaceRemoved(workspaceID:)` via `receiveNextMessage()`.
    func testWorkspaceLifecycleRPCs() async throws {
        let transport = MockTransport()
        let assignedID = Data(repeating: 0xC1, count: 16)
        let host = LifecycleMockHost(transport: transport, assignedWorkspaceID: assignedID)
        let hostTask = Task { try await host.run() }

        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        _ = try await session.handshake()

        let workspaceID = try await session.createWorkspace(title: "scratch")
        XCTAssertEqual(workspaceID, assignedID)

        try await session.renameWorkspace(workspaceID: workspaceID, title: "renamed")
        try await session.deleteWorkspace(workspaceID: workspaceID)

        let msg = try await session.receiveNextMessage()
        guard case .workspaceRemoved(let removedID) = msg else {
            XCTFail("expected .workspaceRemoved, got \(msg)")
            return
        }
        XCTAssertEqual(removedID, workspaceID)

        try await hostTask.value
        let receivedCreateTitle = await host.receivedCreateTitle
        XCTAssertEqual(receivedCreateTitle, "scratch")
        let receivedRename = await host.receivedRename
        XCTAssertEqual(receivedRename?.workspaceID, workspaceID)
        XCTAssertEqual(receivedRename?.title, "renamed")
        let receivedDeleteWorkspaceID = await host.receivedDeleteWorkspaceID
        XCTAssertEqual(receivedDeleteWorkspaceID, workspaceID)
    }

    /// `createWorkspace` must surface a host rejection (`accepted == false`)
    /// as `PeerSessionError.createWorkspaceRejected`, not silently return an
    /// empty id.
    func testCreateWorkspaceRejected() async throws {
        let transport = MockTransport()
        let host = LifecycleMockHost(
            transport: transport,
            assignedWorkspaceID: Data(),
            createAccepted: false,
            createRejectReason: "quota exceeded"
        )
        let hostTask = Task { try await host.run() }

        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        _ = try await session.handshake()

        do {
            _ = try await session.createWorkspace(title: "scratch")
            XCTFail("expected createWorkspaceRejected")
        } catch PeerSessionError.createWorkspaceRejected(let reason) {
            XCTAssertEqual(reason, "quota exceeded")
        }

        try await hostTask.value
    }

    func testTeamRPCsRequireNegotiatedCapabilitiesBeforeWriting() async throws {
        let transport = MockTransport()
        let host = TeamRPCMockHost(transport: transport, capabilities: [])
        let hostTask = Task { try await host.run() }
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )
        _ = try await session.handshake()
        try await hostTask.value
        var writtenFrameCount = await transport.writtenFrameCount()
        XCTAssertEqual(writtenFrameCount, 2)

        do {
            _ = try await session.listTeams()
            XCTFail("listTeams must reject an old host")
        } catch PeerSessionError.capabilityNotNegotiated(let capability) {
            XCTAssertEqual(capability, PeerCapability.teamRosterV1)
        }
        do {
            _ = try await session.callTeam(method: "team.list", paramsJSON: "{}")
            XCTFail("callTeam must reject an old host")
        } catch PeerSessionError.capabilityNotNegotiated(let capability) {
            XCTAssertEqual(capability, PeerCapability.teamCallV1)
        }
        do {
            _ = try await session.bootstrapTeamLeader(
                projectID: "name:demo",
                placement: .local,
                requestID: Data(count: PeerTeamLeader.requestIDBytes)
            )
            XCTFail("bootstrapTeamLeader must reject an old host")
        } catch PeerSessionError.capabilityNotNegotiated(let capability) {
            XCTAssertEqual(capability, PeerCapability.teamLeaderV1)
        }
        do {
            _ = try await session.callTeamLeader(
                grant: Termmesh_Peer_V1_TeamLeaderGrant(),
                teamUUID: "team",
                requestID: Data(count: PeerTeamLeader.requestIDBytes),
                method: "team.delegate",
                paramsJSON: "{}"
            )
            XCTFail("callTeamLeader must reject an old host")
        } catch PeerSessionError.capabilityNotNegotiated(let capability) {
            XCTAssertEqual(capability, PeerCapability.teamLeaderV1)
        }
        writtenFrameCount = await transport.writtenFrameCount()
        XCTAssertEqual(writtenFrameCount, 2)
    }

    func testAdvertisedTeamRPCThatNeverRepliesTimesOut() async throws {
        let transport = MockTransport()
        let host = TeamRPCMockHost(
            transport: transport,
            capabilities: [PeerCapability.teamRosterV1],
            consumeRequest: true
        )
        let hostTask = Task { try await host.run() }
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) },
            close: { await transport.closeClientRead() }
        )
        _ = try await session.handshake()

        do {
            _ = try await session.listTeams(timeoutSeconds: 0.05)
            XCTFail("silent host must time out")
        } catch PeerSessionError.rpcTimedOut(let operation) {
            XCTAssertEqual(operation, "listTeams")
        }
        try await hostTask.value
        let writtenFrameCount = await transport.writtenFrameCount()
        XCTAssertEqual(writtenFrameCount, 3)
    }

    /// Heartbeat must fire `onDead` when the remote stops sending Pong.
    /// Reproduces the laptop-sleep / hung-daemon failure mode where the
    /// transport read blocks forever without an OS-level disconnect.
    func testHeartbeatDeclaresDeadOnSilentRemote() async throws {
        let transport = MockTransport()
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )

        let deadFlag = AsyncFlag()
        await session.startHeartbeat(intervalSeconds: 0.05, deadAfterSeconds: 0.3) {
            Task { await deadFlag.signal() }
        }

        let fired = await deadFlag.wait(timeoutSeconds: 2.0)
        XCTAssertTrue(fired, "heartbeat should have called onDead within 2s")

        await session.stopHeartbeat()
    }

    /// Heartbeat must NOT fire `onDead` while the remote is replying
    /// with Pong frames. Guards against false-positive disconnects.
    func testHeartbeatStaysAliveWhilePongsArrive() async throws {
        let transport = MockTransport()
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )

        let pongTask = Task<Void, Never> {
            var pending = Data()
            var serverSeq: UInt64 = 0
            while !Task.isCancelled {
                let chunk = await transport.serverRead()
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let env = try? decodeFrame(from: &pending) {
                    if case .ping(let p) = env.payload {
                        var reply = Termmesh_Peer_V1_Envelope()
                        serverSeq += 1
                        reply.seq = serverSeq
                        var pong = Termmesh_Peer_V1_Pong()
                        pong.nonce = p.nonce
                        reply.pong = pong
                        if let frame = try? encodeFrame(reply) {
                            await transport.serverWrite(frame)
                        }
                    }
                }
            }
        }

        // Drain Pongs on the client side so receiveNextMessage updates
        // lastPongAt — without a drain the actor's internal timestamp
        // never refreshes and the deadline trips even with replies in
        // flight.
        let drainTask = Task<Void, Never> {
            while !Task.isCancelled {
                _ = try? await session.receiveNextMessage()
            }
        }

        let deadFlag = AsyncFlag()
        await session.startHeartbeat(intervalSeconds: 0.05, deadAfterSeconds: 0.3) {
            Task { await deadFlag.signal() }
        }

        let fired = await deadFlag.wait(timeoutSeconds: 0.7)
        XCTAssertFalse(fired, "heartbeat must not declare dead while Pongs are arriving")

        await session.stopHeartbeat()
        drainTask.cancel()
        pongTask.cancel()
    }

    /// Regression for the measured pane-close root cause: under a sustained
    /// host→client output flood the pump loop is too backpressured to
    /// *process* the Pong within `deadAfterSeconds`, yet the connection is
    /// plainly alive — bytes keep arriving. The heartbeat must key liveness
    /// off inbound bytes (`lastInboundAt`), not only processed Pongs, so it
    /// does NOT false-positive as dead and close a healthy relay pane.
    ///
    /// Here the server replies to every Ping with a PtyData frame but NEVER a
    /// Pong: `lastPongAt` goes stale past the deadline while inbound bytes
    /// stay fresh. Before the fix this declared dead; after it, it stays alive.
    func testHeartbeatStaysAliveWhileBytesFlowWithoutPong() async throws {
        let transport = MockTransport()
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )

        let floodTask = Task<Void, Never> {
            var pending = Data()
            var serverSeq: UInt64 = 0
            let surfaceID = Data(repeating: 0xAB, count: 16)
            while !Task.isCancelled {
                let chunk = await transport.serverRead()
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let env = try? decodeFrame(from: &pending) {
                    // Reply to each Ping with bytes (PtyData) but no Pong.
                    if case .ping = env.payload {
                        var reply = Termmesh_Peer_V1_Envelope()
                        serverSeq += 1
                        reply.seq = serverSeq
                        var pty = Termmesh_Peer_V1_PtyData()
                        pty.surfaceID = surfaceID
                        pty.byteSeq = serverSeq * 8
                        pty.payload = Data(repeating: 0x2E, count: 8)
                        reply.ptyData = pty
                        if let frame = try? encodeFrame(reply) {
                            await transport.serverWrite(frame)
                        }
                    }
                }
            }
        }

        // Client drains frames so reads happen (refreshing lastInboundAt),
        // but no Pong ever arrives so lastPongAt stays stale.
        let drainTask = Task<Void, Never> {
            while !Task.isCancelled {
                _ = try? await session.receiveNextMessage()
            }
        }

        let deadFlag = AsyncFlag()
        await session.startHeartbeat(intervalSeconds: 0.05, deadAfterSeconds: 0.3) {
            Task { await deadFlag.signal() }
        }

        // Wait well beyond deadAfterSeconds. Without the inbound-liveness fix
        // the heartbeat would declare dead (no Pong ever); with it, the steady
        // inbound bytes keep it alive.
        let fired = await deadFlag.wait(timeoutSeconds: 1.0)
        XCTAssertFalse(
            fired,
            "heartbeat must not declare dead while inbound bytes flow, even without a processed Pong"
        )

        await session.stopHeartbeat()
        drainTask.cancel()
        floodTask.cancel()
    }

    /// P6: `onFirstMiss` must fire exactly once when a Pong is skipped for
    /// longer than one ping interval, and `onMissRecovered` must fire
    /// exactly once when Pongs resume — all without ever declaring the
    /// session dead. Guards the early-warning banner hook: no firing
    /// during healthy traffic, no re-firing while a single outage
    /// persists across several ticks, and no stuck banner once the
    /// outage clears on its own.
    func testHeartbeatFirstMissThenRecovers() async throws {
        let transport = MockTransport()
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )

        let gate = PongGate()
        let pongTask = Task<Void, Never> {
            var pending = Data()
            var serverSeq: UInt64 = 0
            while !Task.isCancelled {
                let chunk = await transport.serverRead()
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let env = try? decodeFrame(from: &pending) {
                    if case .ping(let p) = env.payload {
                        guard await gate.shouldReply() else { continue }
                        var reply = Termmesh_Peer_V1_Envelope()
                        serverSeq += 1
                        reply.seq = serverSeq
                        var pong = Termmesh_Peer_V1_Pong()
                        pong.nonce = p.nonce
                        reply.pong = pong
                        if let frame = try? encodeFrame(reply) {
                            await transport.serverWrite(frame)
                        }
                    }
                }
            }
        }

        // Drain Pongs on the client side so receiveNextMessage updates
        // lastPongAt — same reasoning as testHeartbeatStaysAliveWhilePongsArrive.
        let drainTask = Task<Void, Never> {
            while !Task.isCancelled {
                _ = try? await session.receiveNextMessage()
            }
        }

        let firstMissCount = Counter()
        let recoveredCount = Counter()
        let deadFlag = AsyncFlag()

        // Interval/dead-after are scaled up from the other heartbeat tests
        // (0.1s / 1.0s instead of 0.05s / 0.3s) to leave a wide margin
        // between "one miss episode" and "declared dead" — this test
        // exercises a transient outage that must NOT cross the dead
        // threshold, so it needs more headroom against scheduler jitter.
        await session.startHeartbeat(
            intervalSeconds: 0.1,
            deadAfterSeconds: 1.0,
            onFirstMiss: { Task { await firstMissCount.increment() } },
            onMissRecovered: { Task { await recoveredCount.increment() } }
        ) {
            Task { await deadFlag.signal() }
        }

        // Healthy traffic: no miss should be reported.
        try await Task.sleep(nanoseconds: 250_000_000) // 0.25s
        var misses = await firstMissCount.value
        XCTAssertEqual(misses, 0, "must not fire while Pongs are flowing normally")

        // Pause Pongs for several ping intervals (well under the 1.0s dead
        // threshold) to force exactly one first-miss detection.
        await gate.setReplying(false)
        try await Task.sleep(nanoseconds: 350_000_000) // 0.35s ≈ 3-4 ticks
        misses = await firstMissCount.value
        var recoveries = await recoveredCount.value
        XCTAssertEqual(misses, 1, "must fire exactly once per miss episode, not once per tick")
        XCTAssertEqual(recoveries, 0)

        // Resume — the outage must resolve on its own without ever
        // declaring the session dead.
        await gate.setReplying(true)
        try await Task.sleep(nanoseconds: 350_000_000) // 0.35s

        misses = await firstMissCount.value
        recoveries = await recoveredCount.value
        XCTAssertEqual(misses, 1, "must not refire while recovering from the same episode")
        XCTAssertEqual(recoveries, 1, "must fire once a fresh Pong arrives after a miss")
        let declaredDead = await deadFlag.wait(timeoutSeconds: 0.05)
        XCTAssertFalse(declaredDead, "a transient miss that recovers must never reach onDead")

        await session.stopHeartbeat()
        drainTask.cancel()
        pongTask.cancel()
    }

    func testHandshakeRejectsMismatchedProtocol() async throws {
        let transport = MockTransport()

        let hostTask = Task {
            // Host insists on protocol 2.x.
            let host = MockHost(transport: transport, surfaces: [])

            // Read client Hello
            _ = await transport.serverRead()
            var mismatch = Termmesh_Peer_V1_Hello()
            mismatch.protocolVersion = "2.0.0"
            mismatch.displayName = "mock-v2"
            var env = Termmesh_Peer_V1_Envelope()
            env.seq = 1
            env.hello = mismatch
            await transport.serverWrite(try encodeFrame(env))
            _ = host  // silence unused
        }

        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )

        do {
            _ = try await session.handshake()
            XCTFail("expected protocolVersionMismatch")
        } catch PeerSessionError.protocolVersionMismatch(let h, let c) {
            XCTAssertEqual(h, "2.0.0")
            XCTAssertEqual(c, "1.0.0")
        }

        _ = try? await hostTask.value
    }
}
