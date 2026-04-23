import XCTest
@testable import PeerProto

/// End-to-end: spawn the real Rust `term-meshd` binary, connect to its
/// peer socket from Swift, run the handshake, verify the surface list
/// matches what we configured via TERMMESH_PEER_SURFACES.
///
/// Skipped gracefully when the daemon binary isn't built — that keeps
/// `swift test` from failing on a fresh checkout where the Rust
/// workspace hasn't been compiled yet.
final class UnixSocketTransportTests: XCTestCase {
    /// Locate repo root by walking up from this test's source file.
    /// swift/PeerProto/Tests/PeerProtoTests/UnixSocketTransportTests.swift
    /// → PeerProtoTests → Tests → PeerProto → swift → repo root.
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private static var daemonPath: String {
        repoRoot
            .appendingPathComponent("daemon/target/debug/term-meshd")
            .path
    }

    func testHandshakeAndListAgainstRealDaemon() async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.daemonPath) else {
            throw XCTSkip(
                "daemon not built at \(Self.daemonPath); run `cargo build -p term-meshd`"
            )
        }

        // Temp socket path — unique per test run.
        let sockPath = "/tmp/tm-peer-swift-itest-\(UUID().uuidString.prefix(8)).sock"
        defer {
            try? fm.removeItem(atPath: sockPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.daemonPath)
        process.arguments = []
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "TERM_MESH_HTTP_DISABLED": "1",
            "TERMMESH_PEER_SOCKET": sockPath,
            "TERMMESH_PEER_DISPLAY_NAME": "swift-itest-host",
            "TERMMESH_PEER_SURFACES": """
                alpha=while :; do printf A; sleep 1; done
                bravo=while :; do printf B; sleep 1; done
                """,
        ]
        // Capture output so failures come with diagnostics.
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        // Wait for the socket to appear. 3 seconds is plenty; the daemon
        // binds the peer listener near the start of main.
        let deadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: sockPath) {
            if Date() > deadline {
                let stderrData = stderrPipe.fileHandleForReading.availableData
                let stderrText = String(data: stderrData, encoding: .utf8) ?? "<binary>"
                XCTFail("peer socket \(sockPath) never appeared within 5s; daemon stderr:\n\(stderrText)")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )

        var options = PeerSessionOptions()
        options.displayName = "swift-itest-client"
        let info = try await session.handshake(options: options)
        XCTAssertEqual(info.hostDisplayName, "swift-itest-host")
        XCTAssertEqual(info.hostProtocolVersion, "1.0.0")

        let surfaces = try await session.listSurfaces()
        let titles = Set(surfaces.map(\.title))
        XCTAssertEqual(
            titles,
            ["alpha", "bravo"],
            "real daemon returned unexpected surface list: \(titles)"
        )

        try await session.sendGoodbye(reason: "swift-itest done")
        await transport.close()
    }
}
