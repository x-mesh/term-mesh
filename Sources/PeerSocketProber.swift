//  PeerSocketProber: resolves the remote peer socket path over ssh when
//  the user leaves the "Remote peer socket" field empty in the connect
//  dialog.
//
//  One short-lived `ssh <target> sh -c '…'` invocation runs a FIXED
//  probe script (zero string interpolation — user input never reaches
//  the remote shell; the target is a separate, validated argv element
//  behind `--`). The script checks candidate socket paths in priority
//  order and prints the first live one:
//
//   1. TERMMESH_PEER_SOCKET from ~/.config/term-mesh/peer.env — the
//      config written by scripts/install-linux.sh and read by the
//      systemd --user unit (last assignment wins, matching systemd
//      EnvironmentFile semantics).
//   2. TERMMESH_PEER_SOCKET from /etc/term-mesh/peer.env — the same
//      config for a SYSTEM-scope install. install-linux.sh picks that
//      scope whenever it runs as root, and then nothing below matches:
//      the unit sets `RuntimeDirectory=term-mesh`, so the socket lives
//      at /run/term-mesh, not under /run/user/<uid>. Leaving this out
//      made "leave empty to auto-detect" permanently unable to find a
//      root-installed host (observed on jwserver69).
//   3. $XDG_RUNTIME_DIR/tm-peer.sock — distros where the runtime dir
//      is not /run/user/<uid>.
//   4. /run/user/<uid>/tm-peer.sock — the Linux installer default.
//   5. /run/term-mesh/tm-peer.sock — the system-scope RuntimeDirectory,
//      probed directly so a host whose peer.env is unreadable (it is
//      mode 0640 root:term-mesh) is still found.
//   6. /tmp/term-mesh-peer-<uid>/peer.sock — the macOS host default
//      (PeerFederationSettings.defaultSocketPath).
//
//  A path read out of a peer.env is still `[ -S ]`-tested, so a stale
//  entry left by an earlier install of the other scope loses to the
//  live socket further down the list instead of poisoning discovery.
//
//  A stale socket file (daemon dead, file left behind) still matches
//  `[ -S ]`; discovery deliberately leaves that distinction to
//  PeerHostDoctor's subsequent tunnel + protocol-handshake check.

import Bonsplit
import Darwin
import Foundation

enum PeerSocketProbeError: Error, CustomStringConvertible {
    /// ssh itself failed (transport, auth, no remote sh, …).
    case sshFailed(exit: Int32, stderr: String)
    /// ssh + remote shell worked but no candidate socket exists.
    case noSocketFound
    /// The probe did not finish within the watchdog budget.
    case timedOut
    /// The probe printed something that fails local path validation.
    case invalidResult(String)
    /// The ssh subprocess could not be spawned at all.
    case spawnFailed(String)

    var description: String {
        switch self {
        case .sshFailed(let exit, let stderr):
            let detail = stderr.isEmpty ? "(no stderr)" : stderr
            return "ssh failed (exit \(exit)): \(detail)"
        case .noSocketFound:
            return "no peer socket found at any of the default locations"
        case .timedOut:
            return "the probe timed out"
        case .invalidResult(let raw):
            return "the probe returned an unusable path: \(raw)"
        case .spawnFailed(let detail):
            return "could not spawn ssh: \(detail)"
        }
    }
}

enum PeerSocketProber {
    /// Human-readable candidate list, in probe order, for failure alerts.
    static let candidateSummary: [String] = [
        "TERMMESH_PEER_SOCKET in ~/.config/term-mesh/peer.env",
        "TERMMESH_PEER_SOCKET in /etc/term-mesh/peer.env",
        "$XDG_RUNTIME_DIR/tm-peer.sock",
        "/run/user/<uid>/tm-peer.sock",
        "/run/term-mesh/tm-peer.sock",
        "/tmp/term-mesh-peer-<uid>/peer.sock",
    ]

    /// The script's "no socket found" sentinel. Distinct from ssh's own
    /// exit codes (255 = transport/auth failure, 127 = no `sh`) so the
    /// two failure classes stay distinguishable.
    static let noSocketExitCode: Int32 = 43

    /// The complete remote command, passed as ONE argv element after
    /// `-- <target>`. The outer `sh -c '…'` makes the probe independent
    /// of the remote login shell (fish/csh pass the single-quoted body
    /// through verbatim). Constraint: the body must contain NO single
    /// quotes, or the wrapping breaks — asserted by unit test.
    static let remoteCommand: String =
        #"sh -c 'tmsock() { sed -n "s/^TERMMESH_PEER_SOCKET=//p" "$1" 2>/dev/null | tail -n 1 | sed "s/^[[:space:]]*//;s/[[:space:]]*$//;s/^\"//;s/\"$//"; }; p=$(tmsock "$HOME/.config/term-mesh/peer.env"); q=$(tmsock /etc/term-mesh/peer.env); for c in "$p" "$q" "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/tm-peer.sock}" "/run/user/$(id -u)/tm-peer.sock" "/run/term-mesh/tm-peer.sock" "/tmp/term-mesh-peer-$(id -u)/peer.sock"; do [ -n "$c" ] && [ -S "$c" ] && { printf "%s" "$c"; exit 0; }; done; exit 43'"#

    /// Pure classification of a finished (or killed) discovery run.
    ///
    /// Success only proves that a socket-shaped filesystem entry exists.
    /// `PeerHostDoctor.test` follows this with an SSH forward + peer
    /// handshake before presenting the route as connected.
    /// Factored out of `probe` so the exit-code/output matrix is
    /// unit-testable without ssh.
    static func classify(
        exitCode: Int32,
        timedOut: Bool,
        stdout: Data,
        stderr: Data
    ) -> Result<String, PeerSocketProbeError> {
        if timedOut { return .failure(.timedOut) }
        let err = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch exitCode {
        case 0:
            let path = String(data: stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do {
                try PeerSSHTunnel.validateRemoteSockPath(path)
            } catch {
                return .failure(.invalidResult(path.isEmpty ? "(empty)" : path))
            }
            return .success(path)
        case noSocketExitCode:
            return .failure(.noSocketFound)
        default:
            return .failure(.sshFailed(exit: exitCode, stderr: err))
        }
    }

    /// Runs the probe against `sshTarget`. Static async → executes on
    /// the global executor, keeping the blocking-ish Process babysitting
    /// off the main thread (socket threading policy). The caller resumes
    /// on its own actor after `await`.
    static func probe(
        sshTarget: String,
        port: Int? = nil,
        identityFile: String? = nil,
        timeoutSeconds: TimeInterval = 15.0
    ) async throws -> String {
        try PeerSSHTunnel.validateSshTarget(sshTarget)
        if let port { try PeerSSHTunnel.validatePort(port) }
        if let identityFile { try PeerSSHTunnel.validateIdentityFile(identityFile) }

        // Same optional auth surface as PeerSSHTunnel.spawnAttempt so
        // auto-detect works on hosts reachable only with an explicit
        // port or identity file.
        var authArgs: [String] = []
        if let port { authArgs += ["-p", String(port)] }
        if let identityFile {
            authArgs += ["-i", (identityFile as NSString).expandingTildeInPath]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-T", "-x",
            // Same multiplexing/auth posture as PeerSSHTunnel.spawnAttempt:
            // never hand this invocation to a ControlMaster, same key/agent
            // auth surface as the tunnel that follows.
            "-S", "none",
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "LogLevel=ERROR",
            // A user's ssh_config LocalForward/RemoteForward for this host
            // must not open forwards (or fail and sink the probe) here.
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=no",
        ] + authArgs + [
            "--",
            sshTarget,
            remoteCommand,
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = nil

        // Outside the DEBUG gate: the elapsed time is reported to the Remote
        // Work log in every build, because "cannot reach the host" and "took
        // 9 seconds to say so" are different problems.
        let startedAt = Date()
        #if DEBUG
        dlog("peer.probe start target=\(sshTarget)")
        #endif

        do {
            try proc.run()
        } catch {
            throw PeerSocketProbeError.spawnFailed(String(describing: error))
        }
        // Whatever path exits this function, never leak a live ssh.
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }

        // Deadline poll instead of waitUntilExit() — the latter blocks
        // indefinitely when ssh ignores SIGTERM (documented hazard in
        // PeerSSHTunnel).
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning {
            if Date() > deadline {
                timedOut = true
                proc.terminate()
                if await !waitForExit(proc, timeout: 2.0) {
                    kill(proc.processIdentifier, SIGKILL)
                    _ = await waitForExit(proc, timeout: 1.0)
                }
                break
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        // Output is tiny (LogLevel=ERROR + a single path), far below
        // pipe capacity, so reading after exit cannot deadlock.
        let stdout = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        let exitCode = proc.isRunning ? Int32(-1) : proc.terminationStatus

        let result = classify(
            exitCode: exitCode, timedOut: timedOut,
            stdout: stdout, stderr: stderr
        )

        let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
        switch result {
        case .success(let path):
            #if DEBUG
            dlog("peer.probe ok target=\(sshTarget) path=\(path) elapsed=\(elapsed)s")
            #endif
            RemoteWorkLog.debugOffMain("Probed \(sshTarget) — daemon at \(path) (\(elapsed)s)")
        case .failure(let error):
            #if DEBUG
            dlog("peer.probe fail target=\(sshTarget) exit=\(exitCode) timedOut=\(timedOut) error=\(error) elapsed=\(elapsed)s")
            #endif
            // The exit code and the timeout flag separate the three ways this
            // fails — SSH could not connect, it connected and found no daemon,
            // or it never answered — which look identical from the UI.
            RemoteWorkLog.infoOffMain(
                "Cannot reach \(sshTarget): \(error) (exit \(exitCode)\(timedOut ? ", timed out" : ""), \(elapsed)s)"
            )
        }

        switch result {
        case .success(let path): return path
        case .failure(let error): throw error
        }
    }

    /// Async twin of PeerSSHTunnel.waitForExit — polls `isRunning`
    /// without blocking a thread.
    private static func waitForExit(_ proc: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}
