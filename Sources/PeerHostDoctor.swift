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

/// Which process is actually serving this peer. The version-probe
/// unification principle is "ask whoever is serving the peer, not
/// whichever binary the Linux install script would have dropped": a
/// Linux host runs the term-meshd systemd service, but a Mac host
/// serves peers from the term-mesh.app itself — there is no separate
/// daemon binary there, so a `command -v term-meshd` miss on a Mac is
/// not "not installed", it's "wrong question".
enum PeerHostKind: String, Equatable {
    case daemon
    case app
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

    /// Sentinel exit code for "no term-meshd binary found" — distinct
    /// from PeerSocketProber.noSocketExitCode (43) so the two probes'
    /// failure spaces never collide on the same wire.
    static let versionMissingExitCode: Int32 = 44

    /// Fixed, OS-aware version-probe command — asks whoever actually
    /// serves the peer on this host rather than always looking for
    /// term-meshd:
    /// - Darwin (Mac host): the peer is served by the term-mesh.app
    ///   bundle itself, so this reads its `CFBundleShortVersionString`
    ///   straight out of Info.plist and prints `term-mesh-app X.Y.Z`.
    /// - anything else (Linux host): resolves term-meshd off PATH
    ///   first, falling back to the installer's default
    ///   `~/.local/bin/term-meshd` (a non-login ssh session often has a
    ///   bare PATH that skips it), then prints `term-meshd X.Y.Z` via
    ///   `--version`.
    /// Either branch exits with `versionMissingExitCode` when it can't
    /// determine a version. No single quotes in the body (same sh -c
    /// '…' wrapper constraint as remoteCommand/diagnoseCommand).
    static let versionProbeCommand =
        #"sh -c 'if [ "$(uname -s)" = Darwin ]; then v=$(/usr/bin/defaults read /Applications/term-mesh.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null) && [ -n "$v" ] && echo "term-mesh-app $v" || exit 44; else b=$(command -v term-meshd 2>/dev/null); [ -x "$b" ] || b="$HOME/.local/bin/term-meshd"; [ -x "$b" ] && "$b" --version || exit 44; fi'"#

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

    /// Probes the remote host's version — term-meshd on Linux, the
    /// term-mesh.app bundle on a Mac (see `PeerHostKind`). Covers the
    /// "daemon down" case that a live-socket probe cannot: this shells
    /// out directly rather than going through the peer socket. Returns
    /// nil whenever no reliable version could be read — nothing found
    /// (exit 44), ssh/timeout failure, or output that doesn't match
    /// either expected shape. Never throws; the caller only cares about
    /// "known version" vs "unknown".
    static func checkVersion(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> (version: String, hostKind: PeerHostKind)? {
        do {
            let output = try await runRemote(
                sshTarget: sshTarget, port: port, identityFile: identityFile,
                command: versionProbeCommand, timeoutSeconds: 15
            )
            return classifyVersionOutput(exitCode: 0, timedOut: false, stdout: output)
        } catch PeerSocketProbeError.sshFailed(let exit, _) {
            return classifyVersionOutput(exitCode: exit, timedOut: false, stdout: "")
        } catch PeerSocketProbeError.timedOut {
            return classifyVersionOutput(exitCode: -1, timedOut: true, stdout: "")
        } catch {
            return nil
        }
    }

    /// Pure classification of a finished version-probe run — mirrors
    /// PeerSocketProber.classify so the exit-code handling (in
    /// particular versionMissingExitCode → nil) and the output parsing
    /// are unit-testable without spawning ssh.
    static func classifyVersionOutput(
        exitCode: Int32,
        timedOut: Bool,
        stdout: String
    ) -> (version: String, hostKind: PeerHostKind)? {
        guard !timedOut, exitCode == 0 else { return nil }
        return parseHostVersionLine(from: stdout)
    }

    /// Extracts (version, hostKind) from whichever probe line matched —
    /// `term-meshd X.Y.Z` (Linux daemon) or `term-mesh-app X.Y.Z` (Mac
    /// app bundle). A non-login shell can still print MOTD/banner text
    /// ahead of the real output, so this scans every line and keeps the
    /// LAST match rather than the first, regardless of which of the two
    /// prefixes it came from. Returns nil when no line matches either.
    static func parseHostVersionLine(from output: String) -> (version: String, hostKind: PeerHostKind)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(term-meshd|term-mesh-app)\s+(\S+)\s*$"#
        ) else { return nil }
        var found: (version: String, hostKind: PeerHostKind)?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let kindRange = Range(match.range(at: 1), in: line),
                  let versionRange = Range(match.range(at: 2), in: line) else { continue }
            let kind: PeerHostKind = line[kindRange] == "term-meshd" ? .daemon : .app
            found = (String(line[versionRange]), kind)
        }
        return found
    }

    /// Back-compat, daemon-only view of `parseHostVersionLine` — kept
    /// for call sites (and existing tests) that only ever fed it Linux
    /// `term-meshd X.Y.Z` output and don't care about `hostKind`.
    static func parseVersionLine(from output: String) -> String? {
        parseHostVersionLine(from: output)?.version
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
                // ssh can ignore SIGTERM outright (documented hazard —
                // see PeerSocketProber.probe's identical escalation).
                // Without this, a stuck child never closes its pipe
                // fds, so the `await outData`/`await errData` below
                // would block on EOF forever instead of honoring
                // timeoutSeconds — the top-of-function defer can't help
                // either, since it only runs once this call returns.
                if await !waitForExit(proc, timeout: 2.0) {
                    kill(proc.processIdentifier, SIGKILL)
                    _ = await waitForExit(proc, timeout: 1.0)
                }
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

    /// Async twin of PeerSSHTunnel.waitForExit / PeerSocketProber's
    /// private helper of the same name — polls `isRunning` without
    /// blocking a thread. Not `private` (unlike PeerSocketProber's
    /// copy) so the SIGTERM→SIGKILL escalation it enables is directly
    /// unit-testable against a real child process without going
    /// through ssh.
    static func waitForExit(_ proc: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}
