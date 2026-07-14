import Darwin
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerSocketProberTests: XCTestCase {

    // MARK: - Script invariants

    /// The remote command rides inside `sh -c '…'`. A single quote in
    /// the body would end the quoting early on the remote side and
    /// break the probe on every host — this is the one structural
    /// property everything else depends on.
    func test_remoteCommand_hasNoSingleQuoteInsideBody() {
        let cmd = PeerSocketProber.remoteCommand
        XCTAssertTrue(cmd.hasPrefix("sh -c '"), "expected sh -c '…' wrapper")
        XCTAssertTrue(cmd.hasSuffix("'"), "expected closing single quote")
        let body = String(cmd.dropFirst("sh -c '".count).dropLast(1))
        XCTAssertFalse(body.contains("'"),
                       "probe body must not contain single quotes")
    }

    func test_remoteCommand_containsSentinelAndCandidates() {
        let cmd = PeerSocketProber.remoteCommand
        XCTAssertTrue(cmd.contains("exit 43"))
        XCTAssertTrue(cmd.contains("TERMMESH_PEER_SOCKET"))
        XCTAssertTrue(cmd.contains(".config/term-mesh/peer.env"))
        XCTAssertTrue(cmd.contains("XDG_RUNTIME_DIR"))
        XCTAssertTrue(cmd.contains("/run/user/$(id -u)/tm-peer.sock"))
        XCTAssertTrue(cmd.contains("/tmp/term-mesh-peer-$(id -u)/peer.sock"))
    }

    // MARK: - classify

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func test_classify_success() {
        let result = PeerSocketProber.classify(
            exitCode: 0, timedOut: false,
            stdout: data("/run/user/0/tm-peer.sock\n"), stderr: Data()
        )
        guard case .success(let path) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(path, "/run/user/0/tm-peer.sock")
    }

    func test_classify_pathWithColonIsRejected() {
        let result = PeerSocketProber.classify(
            exitCode: 0, timedOut: false,
            stdout: data("/tmp/evil:9999/x.sock"), stderr: Data()
        )
        guard case .failure(.invalidResult) = result else {
            return XCTFail("expected invalidResult, got \(result)")
        }
    }

    func test_classify_emptyStdoutIsRejected() {
        let result = PeerSocketProber.classify(
            exitCode: 0, timedOut: false, stdout: Data(), stderr: Data()
        )
        guard case .failure(.invalidResult) = result else {
            return XCTFail("expected invalidResult, got \(result)")
        }
    }

    func test_classify_sentinelMeansNoSocketFound() {
        let result = PeerSocketProber.classify(
            exitCode: PeerSocketProber.noSocketExitCode, timedOut: false,
            stdout: Data(), stderr: Data()
        )
        guard case .failure(.noSocketFound) = result else {
            return XCTFail("expected noSocketFound, got \(result)")
        }
    }

    func test_classify_sshTransportFailure() {
        let result = PeerSocketProber.classify(
            exitCode: 255, timedOut: false,
            stdout: Data(), stderr: data("ssh: connect to host x: timed out\n")
        )
        guard case .failure(.sshFailed(let exit, let stderr)) = result else {
            return XCTFail("expected sshFailed, got \(result)")
        }
        XCTAssertEqual(exit, 255)
        XCTAssertTrue(stderr.contains("timed out"))
    }

    func test_classify_unknownExitIsSshFailed() {
        let result = PeerSocketProber.classify(
            exitCode: 127, timedOut: false, stdout: Data(), stderr: Data()
        )
        guard case .failure(.sshFailed(let exit, _)) = result else {
            return XCTFail("expected sshFailed, got \(result)")
        }
        XCTAssertEqual(exit, 127)
    }

    func test_classify_timeoutWinsOverExitCode() {
        let result = PeerSocketProber.classify(
            exitCode: 0, timedOut: true,
            stdout: data("/tmp/x.sock"), stderr: Data()
        )
        guard case .failure(.timedOut) = result else {
            return XCTFail("expected timedOut, got \(result)")
        }
    }

    // MARK: - probe argument validation

    func test_probe_rejectsOptionInjectionTarget() async {
        do {
            _ = try await PeerSocketProber.probe(sshTarget: "-oProxyCommand=evil")
            XCTFail("expected validateSshTarget to throw")
        } catch {
            // PeerSSHTunnelError.invalidArgument — anything thrown before
            // a subprocess spawn is the correct behavior here.
            XCTAssertFalse(error is PeerSocketProbeError,
                           "must fail validation before spawning ssh")
        }
    }

    // MARK: - Local end-to-end of the probe script (no ssh)

    /// Runs the script body under /bin/sh exactly as a remote POSIX
    /// shell would, with HOME pointed at a scratch dir. Exercises the
    /// peer.env parsing (last assignment wins, quote/whitespace strip)
    /// and the `[ -S ]` liveness check against a real bound socket.
    func test_script_resolvesPeerEnvSocket_lastAssignmentWins() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let sockPath = scratch + "/s.sock"
        let fd = try bindUnixSocket(at: sockPath)
        defer { close(fd) }

        let configDir = scratch + "/.config/term-mesh"
        try FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true
        )
        // Stale first assignment + quoted-with-trailing-space last one:
        // systemd EnvironmentFile semantics say the last wins.
        let env = """
        TERMMESH_PEER_SOCKET=/nonexistent/stale.sock
        TERMMESH_PEER_SOCKET="\(sockPath)"
        """
        try env.write(toFile: configDir + "/peer.env", atomically: true, encoding: .utf8)

        let run = try runScriptBody(home: scratch, xdgRuntimeDir: nil)
        XCTAssertEqual(run.exit, 0, "stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, sockPath)
    }

    func test_script_fallsBackToXdgRuntimeDir() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        // No peer.env at all; socket lives in $XDG_RUNTIME_DIR.
        let sockPath = scratch + "/tm-peer.sock"
        let fd = try bindUnixSocket(at: sockPath)
        defer { close(fd) }

        let run = try runScriptBody(home: scratch, xdgRuntimeDir: scratch)
        XCTAssertEqual(run.exit, 0, "stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, sockPath)
    }

    func test_script_exits43WhenNothingExists() throws {
        // The script's last candidate is this machine's real macOS
        // default; a live local peer host would legitimately match it.
        let macDefault = "/tmp/term-mesh-peer-\(getuid())/peer.sock"
        try XCTSkipIf(FileManager.default.fileExists(atPath: macDefault),
                      "local peer host running — candidate would match")

        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let run = try runScriptBody(home: scratch, xdgRuntimeDir: nil)
        XCTAssertEqual(run.exit, PeerSocketProber.noSocketExitCode,
                       "stdout: \(run.stdout) stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, "")
    }

    // MARK: - Helpers

    /// Short path under /tmp — sockaddr_un.sun_path caps at 104 bytes
    /// on macOS and NSTemporaryDirectory() paths flirt with that limit.
    private func makeScratchDir() throws -> String {
        let path = "/tmp/psp-test-\(getpid())-\(UInt32.random(in: 0..<0xFFFF))"
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )
        return path
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: bytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size)
            }
        }
        guard rc == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return fd
    }

    private struct ScriptRun {
        let exit: Int32
        let stdout: String
        let stderr: String
    }

    private func runScriptBody(home: String, xdgRuntimeDir: String?) throws -> ScriptRun {
        let cmd = PeerSocketProber.remoteCommand
        let body = String(cmd.dropFirst("sh -c '".count).dropLast(1))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", body]
        var env = ["HOME": home, "PATH": "/usr/bin:/bin"]
        if let xdgRuntimeDir { env["XDG_RUNTIME_DIR"] = xdgRuntimeDir }
        proc.environment = env
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        return ScriptRun(
            exit: proc.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
