import XCTest
@testable import PeerProto

final class PeerServerTests: XCTestCase {
    /// End-to-end: Swift `PeerServer` accepts a Swift `PeerSession`
    /// client over a real Unix socket, completes the handshake, and
    /// answers ListSurfaces with the static set we seeded. Exercises
    /// the full Swift server path that will later back term-mesh.app's
    /// peer exposure.
    func testHandshakeAndListViaSwiftServer() async throws {
        let sockPath = "/tmp/tm-peer-swift-srv-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

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
        bravo.attachable = true

        let provider = StaticSurfaceProvider(surfaces: [alpha, bravo])
        var config = PeerServerConfig()
        config.hostDisplayName = "swift-itest-server"
        config.hostAppVersion = "c3c3.1"
        let server = PeerServer(socketPath: sockPath, provider: provider, config: config)
        try await server.start()
        defer {
            Task { await server.stop() }
        }

        // Wait briefly for the socket to be reported ready by the kernel.
        // (POSIX bind+listen is synchronous, so the file already exists; this
        // just races the NWConnection's connectability check.)
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline {
                XCTFail("listener never created socket file at \(sockPath)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )

        var options = PeerSessionOptions()
        options.displayName = "swift-itest-client"
        let info = try await session.handshake(options: options)
        XCTAssertEqual(info.hostDisplayName, "swift-itest-server")
        XCTAssertEqual(info.hostAppVersion, "c3c3.1")
        XCTAssertEqual(info.hostProtocolVersion, "1.0.0")

        let surfaces = try await session.listSurfaces()
        XCTAssertEqual(surfaces.count, 2)
        XCTAssertEqual(surfaces.map(\.title), ["alpha", "bravo"])
        XCTAssertEqual(surfaces[0].branch, "main")

        try await session.sendGoodbye(reason: "c3c3.1-itest done")
        await transport.close()
        await server.stop()
    }

    /// Static provider returns no attachment → server replies
    /// `AttachResult(accepted: false)` → PeerSession throws
    /// `attachRejected`.
    func testStaticProviderRejectsAttach() async throws {
        let sockPath = "/tmp/tm-peer-swift-srv-err-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = Data(repeating: 0x77, count: 16)
        info.title = "listed-but-not-attachable"
        info.cols = 80
        info.rows = 24

        let provider = StaticSurfaceProvider(surfaces: [info])
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()

        do {
            _ = try await session.attachSurface(
                id: info.surfaceID,
                mode: .coWrite,
                cols: 80,
                rows: 24
            )
            XCTFail("expected attachRejected for static provider")
        } catch PeerSessionError.attachRejected(let reason) {
            XCTAssertEqual(reason, "surface not found")
        } catch {
            XCTFail("wrong error: \(error)")
        }

        await transport.close()
        await server.stop()
    }

    /// End-to-end attach round trip through an `EchoSurfaceProvider`:
    /// client attaches, writes Input, receives the same bytes back as
    /// PtyData on the same surface. Exercises `PeerServerSession`'s
    /// attach handler, relay task, and Input routing.
    func testEchoAttachRoundTrip() async throws {
        let sockPath = "/tmp/tm-peer-swift-echo-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = Data(repeating: 0xE1, count: 16)
        info.title = "echo"
        info.cols = 80
        info.rows = 24
        info.attachable = true

        let provider = EchoSurfaceProvider(surfaces: [info])
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()

        let outcome = try await session.attachSurface(
            id: info.surfaceID,
            mode: .coWrite,
            cols: 80,
            rows: 24
        )
        XCTAssertEqual(outcome.surfaceID, info.surfaceID)

        let marker = "ECHO-VIA-SWIFT-SERVER"
        try await session.sendInput(
            surfaceID: info.surfaceID,
            keys: Data(marker.utf8)
        )

        var aggregated = Data()
        let sawMarker = try await Task {
            let hardDeadline = Date().addingTimeInterval(3)
            while Date() < hardDeadline {
                let msg = try await session.receiveNextMessage()
                switch msg {
                case .ptyData(_, _, let payload):
                    aggregated.append(payload)
                    if aggregated.range(of: Data(marker.utf8)) != nil {
                        return true
                    }
                case .goodbye, .error:
                    return false
                default:
                    continue
                }
            }
            return false
        }.value
        XCTAssertTrue(
            sawMarker,
            "never observed echo of MARKER; aggregated=\(String(data: aggregated, encoding: .utf8) ?? "")"
        )

        try await session.sendGoodbye(reason: "c3c3.2 done")
        await transport.close()
        await server.stop()
    }
}
