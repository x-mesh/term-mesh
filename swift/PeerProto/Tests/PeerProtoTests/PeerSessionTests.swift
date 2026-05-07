import XCTest
@testable import PeerProto

/// In-memory paired channel: one side's writes appear on the other side's
/// reads. Used to run a "server" coroutine alongside the `PeerSession`
/// client in a single test process, no Unix socket required.
actor MockTransport {
    private var clientToServer: [Data] = []
    private var serverToClient: [Data] = []
    private var clientToServerWaiter: CheckedContinuation<Data, Never>?
    private var serverToClientWaiter: CheckedContinuation<Data, Never>?

    func clientWrite(_ data: Data) {
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
