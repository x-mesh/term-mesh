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

    /// Client sending a post-handshake payload we haven't wired yet
    /// (Attach) receives an explicit error frame rather than a hang.
    /// Guards against future regressions when we do wire Attach.
    func testUnsupportedPayloadReturnsError() async throws {
        let sockPath = "/tmp/tm-peer-swift-srv-err-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let provider = StaticSurfaceProvider(surfaces: [])
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer {
            Task { await server.stop() }
        }

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

        // AttachSurface is intentionally not handled yet.
        do {
            _ = try await session.attachSurface(
                id: Data(count: 16),
                mode: .coWrite,
                cols: 80,
                rows: 24
            )
            XCTFail("expected attach to fail — Phase C-3c.3.1 server doesn't implement Attach")
        } catch PeerSessionError.unexpectedMessage(let msg) {
            // Server emits an Error envelope; PeerSession sees it where it
            // expected AttachResult and throws unexpectedMessage.
            XCTAssertTrue(msg.contains("error") || msg.contains("Error"), "got: \(msg)")
        } catch {
            XCTFail("wrong error: \(error)")
        }

        await transport.close()
        await server.stop()
    }
}
