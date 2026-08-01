import Foundation
import PeerProto

/// What a machine can actually do, asked before anyone depends on it.
///
/// A host is configured long before it is used, and everything that could be
/// wrong about it — the projects directory does not exist, the CLI an agent
/// was going to run is not installed — only shows up later as an agent pane
/// that opens and dies, or a path that resolves to nothing. The answers are
/// one ssh away and worth having while the person is still looking at the
/// settings for that host.
///
/// Nothing here changes the machine on its own. Creating the directory is a
/// separate, explicit call: this side may be wrong about which machine it is
/// talking to, and mkdir is not the kind of thing to do on a hunch.
struct PeerHostReadiness: Equatable {
    /// Whether the configured projects directory exists.
    var projectRootExists: Bool
    /// The directory that was checked, as it was written.
    var projectRoot: String
    /// Agent CLIs found on the remote PATH, in the order asked about.
    var installedCLIs: [String]
    /// CLIs asked about and not found.
    var missingCLIs: [String]

    var isReady: Bool { projectRootExists && !installedCLIs.isEmpty }
}

enum PeerHostReadinessError: LocalizedError, CustomStringConvertible {
    case noProjectRoot
    case sshFailed(String)

    var description: String {
        switch self {
        case .noProjectRoot:
            return "set a projects directory first"
        case .sshFailed(let detail):
            return detail
        }
    }

    var errorDescription: String? { description }
}

/// Where a CLI actually lives on a host, as opposed to where a non-interactive
/// shell will look for it.
///
/// Every shell this app opens on a host is non-interactive, and `-lc` does not
/// rescue that: installers write their PATH line into `~/.bashrc`, which opens
/// with a guard that returns immediately when the shell is not interactive —
/// so a line 100 lines below it never runs. The effect is that the directory
/// the official installer chose (`~/.local/bin`, for Claude Code) is invisible
/// in exactly the shells this app uses, and a host with a perfectly working
/// CLI reads back as "not installed".
///
/// The same directories are already listed in the Rust daemon's
/// `user_bin_dirs()`; both halves of the app should look in the same places.
enum RemoteShellPath {
    /// Ordered most-specific first. A macOS peer running the app must use the
    /// CLI shipped with that same app before a stale user install; otherwise
    /// the Swift peer protocol and `tm-agent` routing policy can disagree
    /// after an app-only upgrade. The path is harmless on Linux.
    static let binDirs = [
        "$HOME/.local/bin",
        "$HOME/.cargo/bin",
        "$HOME/bin",
        "$HOME/go/bin",
        "$HOME/.bun/bin",
        "$HOME/.npm-global/bin",
        "$HOME/.npm-packages/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// Prefix for every script this app runs on a host — both the probes that
    /// ask whether a CLI exists and the command that launches it, which have
    /// to agree or a CLI is found and then fails to start.
    ///
    /// Deliberately unquoted: `$HOME` has to expand on the far side. The
    /// inherited `$PATH` stays last so a host that has already arranged things
    /// keeps its own precedence.
    static func prologue(hostBinDirs: [String] = []) -> String {
        let authenticated = PeerHostCLIBinDirs.validated(hostBinDirs)
        let reported = authenticated.map(shellQuote)
        let fixed = binDirs.map { dir -> String in
            if dir.hasPrefix("$HOME/") {
                return "\"$HOME/\(dir.dropFirst(6))\""
            }
            return shellQuote(dir)
        }
        let value = (reported + fixed + ["\"$PATH\""]).joined(separator: ":")
        return "export PATH=\(value); "
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum PeerHostReadinessChecker {
    /// The CLIs term-mesh knows how to run as an agent.
    static let knownCLIs = ["claude", "codex", "kiro", "gemini"]

    /// Ask the machine what it has.
    ///
    /// One round trip for both questions: a second ssh would double the wait
    /// for an answer nobody reads separately.
    static func check(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        projectRoot: String,
        hostBinDirs: [String] = [],
        timeoutSeconds: TimeInterval = 20
    ) async throws -> PeerHostReadiness {
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw PeerHostReadinessError.noProjectRoot }

        // Quoted so a directory with a space in it is one argument, and
        // `command -v` rather than `which` because it is the one every shell
        // agrees on.
        let quotedRoot = "'" + root.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let probes = knownCLIs
            .map { "command -v \($0) >/dev/null 2>&1 && echo 'cli \($0)'" }
            .joined(separator: "; ")
        let script = RemoteShellPath.prologue(hostBinDirs: hostBinDirs)
            + "test -d \(quotedRoot) && echo 'root yes' || echo 'root no'; \(probes)"

        let output = try await run(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            script: script, timeoutSeconds: timeoutSeconds
        )
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let found = lines.compactMap { line -> String? in
            line.hasPrefix("cli ") ? String(line.dropFirst(4)) : nil
        }
        return PeerHostReadiness(
            projectRootExists: lines.contains("root yes"),
            projectRoot: root,
            installedCLIs: knownCLIs.filter { found.contains($0) },
            missingCLIs: knownCLIs.filter { !found.contains($0) }
        )
    }

    /// Create the projects directory. Explicit, never a side effect of asking.
    static func createProjectRoot(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        projectRoot: String,
        timeoutSeconds: TimeInterval = 20
    ) async throws {
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw PeerHostReadinessError.noProjectRoot }
        let quotedRoot = "'" + root.replacingOccurrences(of: "'", with: "'\\''") + "'"
        _ = try await run(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            script: "mkdir -p \(quotedRoot)", timeoutSeconds: timeoutSeconds
        )
    }

    /// One shell command on the far machine, for callers outside this file.
    @discardableResult
    static func runScript(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        script: String,
        timeoutSeconds: TimeInterval = 60
    ) async throws -> String {
        try await run(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            script: script, timeoutSeconds: timeoutSeconds
        )
    }

    /// One shell command on the far machine.
    ///
    /// The ssh posture mirrors `PeerSocketProber`: no ControlMaster, no
    /// forwards, the same auth surface — so a host reachable by the prober is
    /// reachable by this and a host that is not fails the same way.
    private static func run(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        script: String,
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
        ] + authArgs + ["--", sshTarget, script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = nil

        do {
            try proc.run()
        } catch {
            throw PeerHostReadinessError.sshFailed(String(describing: error))
        }
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !proc.isRunning else {
            throw PeerHostReadinessError.sshFailed("timed out after \(Int(timeoutSeconds))s")
        }
        let out = String(
            data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        guard proc.terminationStatus == 0 else {
            let detail = [out, err]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw PeerHostReadinessError.sshFailed(
                detail.isEmpty
                    ? "exited \(proc.terminationStatus)"
                    : detail
            )
        }
        return out
    }
}
