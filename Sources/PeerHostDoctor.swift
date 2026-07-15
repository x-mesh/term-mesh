//  PeerHostDoctor: connection test + remote install + diagnosis for
//  saved host profiles (the editor sheet's "Test" / "Install" buttons).
//
//  Security posture matches PeerSocketProber: every remote command is a
//  FIXED string (zero interpolation — user input never reaches the
//  remote shell), the target rides behind `--` as a validated positional
//  argv element, and optional port/identity go through the same
//  validators as the tunnel.

import Foundation

enum PeerHostTestResult: Equatable {
    /// SSH + daemon socket both reachable.
    case ok(socketPath: String)
    /// SSH reached the host but no live peer socket was found —
    /// term-meshd is likely not installed/running. Install is offered.
    case daemonMissing
    /// SSH itself failed (auth, DNS, timeout…).
    case sshFailed(String)
}

enum PeerHostDoctor {
    /// Pinned to the repo's install entrypoint. Fixed constant — never
    /// built from user input.
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/x-mesh/term-mesh/main/scripts/install-linux.sh | bash"

    /// Fixed diagnosis command: service state + recent journal lines.
    /// No single quotes in the body (same constraint as the prober's
    /// remoteCommand — the sh -c wrapper must survive fish/csh).
    static let diagnoseCommand =
        #"sh -c 'systemctl --user is-active term-meshd 2>&1; journalctl --user -u term-meshd --no-pager -n 6 2>&1 | tail -n 6'"#

    /// Test reachability: SSH + peer-socket presence. An explicit
    /// `remoteSocket` is NOT trusted blindly — the probe checks the
    /// default candidates, which covers the explicit path's host too;
    /// what matters here is "is a daemon listening", not path equality.
    static func test(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> PeerHostTestResult {
        do {
            let path = try await PeerSocketProber.probe(
                sshTarget: sshTarget, port: port, identityFile: identityFile
            )
            return .ok(socketPath: path)
        } catch PeerSocketProbeError.noSocketFound {
            return .daemonMissing
        } catch {
            return .sshFailed(String(describing: error))
        }
    }

    /// Run the pinned install script on the host. Returns the last log
    /// lines on success; throws with stderr on failure. 3-minute budget
    /// (download + systemd setup on a slow box).
    static func install(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async throws -> String {
        try await runRemote(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            command: installCommand, timeoutSeconds: 180
        )
    }

    /// Post-install health check: service state + journal tail. Used
    /// when a test still fails after install (e.g. a binary built
    /// against a newer glibc than the host ships).
    static func diagnose(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> String {
        (try? await runRemote(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            command: diagnoseCommand, timeoutSeconds: 20
        )) ?? "diagnosis unavailable"
    }

    /// Compact human line out of a diagnosis dump — surfaces the known
    /// failure signatures first, else the last journal line.
    static func summarizeDiagnosis(_ raw: String) -> String {
        let lines = raw.split(separator: "\n").map(String.init)
        if let glibc = lines.first(where: { $0.contains("GLIBC_") }) {
            return "binary incompatible with this host's glibc — " +
                (glibc.split(separator: ":").last.map(String.init) ?? glibc)
                .trimmingCharacters(in: .whitespaces)
        }
        if let failed = lines.first(where: { $0.contains("Failed with result") }) {
            return failed.trimmingCharacters(in: .whitespaces)
        }
        return lines.last?.trimmingCharacters(in: .whitespaces) ?? raw
    }

    // MARK: - Fixed-command ssh runner

    private static func runRemote(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        command: String,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try PeerSSHTunnel.validateSshTarget(sshTarget)
        if let port { try PeerSSHTunnel.validatePort(port) }
        if let identityFile { try PeerSSHTunnel.validateIdentityFile(identityFile) }
        var authArgs: [String] = []
        if let port { authArgs += ["-p", String(port)] }
        if let identityFile {
            authArgs += ["-i", (identityFile as NSString).expandingTildeInPath]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-T", "-x",
            "-S", "none",
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "LogLevel=ERROR",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=no",
        ] + authArgs + [
            "--",
            sshTarget,
            command,
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = nil

        do {
            try proc.run()
        } catch {
            throw PeerSocketProbeError.spawnFailed(String(describing: error))
        }
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }

        // Drain pipes concurrently — install output exceeds pipe capacity,
        // so reading only after exit could deadlock the child.
        async let outData = readAll(outPipe)
        async let errData = readAll(errPipe)

        var timedOut = false
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning {
            if Date() > deadline {
                timedOut = true
                proc.terminate()
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let stdout = String(data: await outData, encoding: .utf8) ?? ""
        let stderr = String(data: await errData, encoding: .utf8) ?? ""
        if timedOut { throw PeerSocketProbeError.timedOut }
        let exit = proc.isRunning ? Int32(-1) : proc.terminationStatus
        guard exit == 0 else {
            throw PeerSocketProbeError.sshFailed(
                exit: exit,
                stderr: stderr.isEmpty ? String(stdout.suffix(300)) : String(stderr.suffix(300))
            )
        }
        return stdout
    }

    private static func readAll(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}
