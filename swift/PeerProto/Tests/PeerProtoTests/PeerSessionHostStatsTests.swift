import XCTest
@testable import PeerProto

/// A host that pushes stats on its own schedule, the way a real daemon
/// does once a client advertises `host.stats.v1`.
private actor StatsMockHost {
    private let transport: MockTransport
    private var pendingInbound = Data()
    private var seq: UInt64 = 0

    init(transport: MockTransport) {
        self.transport = transport
    }

    /// Consume one client request, whatever it is.
    func readOneRequest() async throws -> Termmesh_Peer_V1_Envelope {
        while true {
            if let envelope = try decodeFrame(from: &pendingInbound) {
                return envelope
            }
            pendingInbound.append(await transport.serverRead())
        }
    }

    func pushHostStats(load: Double = 2.5) async throws {
        var stats = Termmesh_Peer_V1_HostStats()
        stats.load1M = load
        var envelope = Termmesh_Peer_V1_Envelope()
        seq &+= 1
        envelope.seq = seq
        envelope.hostStats = stats
        await transport.serverWrite(try encodeFrame(envelope))
    }

    func sendSurfaceList(count: Int) async throws {
        var list = Termmesh_Peer_V1_SurfaceList()
        list.surfaces = (0..<count).map { index in
            var info = Termmesh_Peer_V1_SurfaceInfo()
            info.surfaceID = Data(repeating: UInt8(index + 1), count: 16)
            info.title = "surface-\(index)"
            return info
        }
        var envelope = Termmesh_Peer_V1_Envelope()
        seq &+= 1
        envelope.seq = seq
        envelope.surfaceList = list
        await transport.serverWrite(try encodeFrame(envelope))
    }
}

final class PeerSessionHostStatsTests: XCTestCase {

    /// The regression this file exists for.
    ///
    /// A request/response call reads the next frame and rejects anything
    /// that is not the reply it wanted. That held only while the host spoke
    /// solely when spoken to — once it pushes stats on a timer, a sample
    /// landing mid-call made the call fail. In practice that took out the
    /// surface listing behind the pane picker, so a host that was connected
    /// and authenticated still appeared unreachable.
    func testStatsPushedMidRequestDoesNotBreakTheReply() async throws {
        let transport = MockTransport()
        let host = StatsMockHost(transport: transport)
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )

        async let surfaces = session.listSurfaces()

        _ = try await host.readOneRequest()
        // Arrives BEFORE the reply, which is what the client used to choke on.
        try await host.pushHostStats()
        try await host.pushHostStats(load: 3.0)
        try await host.sendSurfaceList(count: 2)

        let listed = try await surfaces
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.first?.title, "surface-0")
    }

    /// Skipping stats on the reply path must not hide them from the pump,
    /// which is the reader that exists to deliver pushes.
    func testPumpStillDeliversHostStats() async throws {
        let transport = MockTransport()
        let host = StatsMockHost(transport: transport)
        let session = PeerSession(
            read: { await transport.clientRead() },
            write: { await transport.clientWrite($0) }
        )

        async let incoming = session.receiveNextMessage()
        try await host.pushHostStats(load: 4.25)

        guard case .hostStats(let stats) = try await incoming else {
            return XCTFail("pump must surface HostStats, not swallow it")
        }
        XCTAssertEqual(stats.load1M, 4.25, accuracy: 0.001)
    }
}
