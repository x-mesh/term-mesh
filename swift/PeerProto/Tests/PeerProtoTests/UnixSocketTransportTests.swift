import XCTest
import Darwin
@testable import PeerProto

/// End-to-end: spawn the real Rust `term-meshd` binary, connect to its
/// peer socket from Swift, run the handshake, verify the surface list
/// matches what we configured via TERMMESH_PEER_SURFACES.
///
/// Skipped gracefully when the daemon binary isn't built — that keeps
/// `swift test` from failing on a fresh checkout where the Rust
/// workspace hasn't been compiled yet.
final class UnixSocketTransportTests: XCTestCase {
    func testReadTimeoutClosesSilentSocket() async throws {
        let fm = FileManager.default
        let sockPath = "/tmp/tm-peer-swift-timeout-\(UUID().uuidString.prefix(8)).sock"
        let listenerFd = try Self.makeUnixListener(socketPath: sockPath)
        defer {
            Darwin.close(listenerFd)
            try? fm.removeItem(atPath: sockPath)
        }

        let acceptTask = Task.detached {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenerFd, sockPtr, &len)
                }
            }
            guard clientFd >= 0 else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            Darwin.close(clientFd)
        }
        defer { acceptTask.cancel() }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath, timeoutSeconds: 1)
        await transport.setReadTimeoutSeconds(0.1)
        do {
            _ = try await transport.read()
            XCTFail("silent socket read should time out")
        } catch let error as UnixSocketTransportError {
            guard case .readTimedOut(let seconds) = error else {
                XCTFail("expected readTimedOut, got \(error)")
                return
            }
            XCTAssertEqual(seconds, 0.1, accuracy: 0.001)
        }
        await transport.close()
    }

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

    private static func makeUnixListener(socketPath: String) throws -> Int32 {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < maxPathLen else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPathLen) { cPtr in
                for (i, byte) in pathBytes.enumerated() {
                    cPtr[i] = CChar(bitPattern: byte)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        guard listen(fd, 1) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        return fd
    }

    /// Spawn a daemon with a `cat` surface, run handshake + attach, send
    /// a keystroke, and verify the echo comes back through PtyData.
    /// Exercises attachSurface + sendInput + receiveNextMessage
    /// end-to-end against the Rust host.
    func testAttachRoundTripAgainstRealDaemon() async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.daemonPath) else {
            throw XCTSkip(
                "daemon not built at \(Self.daemonPath); run `cargo build -p term-meshd`"
            )
        }

        let sockPath = "/tmp/tm-peer-swift-c3c-\(UUID().uuidString.prefix(8)).sock"
        defer { try? fm.removeItem(atPath: sockPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.daemonPath)
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "TERM_MESH_HTTP_DISABLED": "1",
            "TERMMESH_PEER_SOCKET": sockPath,
            "TERMMESH_PEER_DISPLAY_NAME": "swift-c3c-host",
            // /bin/cat echoes stdin → stdout; the PTY's default termios
            // also echoes typed characters, so MARKER arrives at least once.
            "TERMMESH_PEER_SURFACES": "echo=/bin/cat",
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: sockPath) {
            if Date() > deadline {
                let data = stderrPipe.fileHandleForReading.availableData
                XCTFail("socket never appeared; stderr:\n\(String(data: data, encoding: .utf8) ?? "")")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()
        let surfaces = try await session.listSurfaces()
        guard let echo = surfaces.first(where: { $0.title == "echo" }) else {
            XCTFail("daemon did not expose echo surface; got \(surfaces.map(\.title))")
            return
        }

        let outcome = try await session.attachSurface(
            id: echo.surfaceID,
            mode: .coWrite,
            cols: 80,
            rows: 24
        )
        XCTAssertEqual(outcome.surfaceID, echo.surfaceID)
        XCTAssertEqual(outcome.grantedMode, .coWrite)

        let marker = "MARKER-C3C\n"
        try await session.sendInput(surfaceID: echo.surfaceID, keys: Data(marker.utf8))

        // Drain messages until MARKER appears. Cat + PTY echo means MARKER
        // arrives twice (ECHO termios + cat), which is fine — we only need
        // to see it once.
        var aggregated = Data()
        let sawMarker = try await Task {
            let hardDeadline = Date().addingTimeInterval(5)
            while Date() < hardDeadline {
                let msg = try await session.receiveNextMessage()
                switch msg {
                case .ptyData(_, _, let payload):
                    aggregated.append(payload)
                    if aggregated.range(of: Data("MARKER-C3C".utf8)) != nil {
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
            "never observed MARKER in PtyData stream; aggregated=\(String(data: aggregated, encoding: .utf8) ?? "")"
        )

        try await session.sendGoodbye(reason: "c3c-roundtrip done")
        await transport.close()
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
