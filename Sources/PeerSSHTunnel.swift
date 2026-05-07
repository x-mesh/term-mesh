// Phase D-4 + E-1: SSH transport for peer federation, with auto-restart.
//
// Manages an `ssh -N -T -L local.sock:remote.sock <target>` subprocess
// so the existing UnixSocketTransport / PeerRelaySession path keeps
// working unchanged — they connect to the local end of the tunnel
// and the SSH client forwards bytes to the remote peer server.
//
// Lifecycle:
//   - start(): spawn ssh, wait for the local socket to appear.
//   - stop():  terminate ssh, remove the local socket file.
//   - The process is held strongly until the relay window closes;
//     dropping the tunnel before its sessions are torn down would
//     yank the rug out from under PeerRelaySession.
//
// Auto-restart (E-1):
//   - When ssh exits unexpectedly (sleep/wake, server reboot, network
//     blip), the tunnel keeps trying to bring itself back up with
//     exponential backoff capped at 30 s. Observers register
//     `onStateChange` to react: tear down per-pane sessions on
//     `down`, re-attach on `up`.

import Foundation

enum PeerSSHTunnelError: Error {
    case spawnFailed(String)
    case socketNeverAppeared(String)
    case alreadyRunning
    /// Caller-supplied SSH target / remote socket failed validation.
    /// Surfaced before spawning ssh so option-injection inputs never
    /// reach `Process`.
    case invalidArgument(String)
}

enum PeerSSHTunnelState: Sendable, Equatable {
    case stopped
    case starting
    case up
    case down(reason: String)
    case reconnecting(attempt: Int)
    /// Auto-reconnect gave up after the configured cap. The tunnel
    /// is no longer trying. Caller must explicitly invoke
    /// `retry()` (e.g. via the in-window banner's "Retry" button)
    /// to resume attempts.
    case failed(reason: String)
}

final class PeerSSHTunnel: @unchecked Sendable {
    let sshTarget: String
    let remoteSockPath: String
    let localSockPath: String

    private var process: Process?
    private let lock = NSLock()
    /// Caller wants the tunnel running. Cleared by `stop()` so the
    /// auto-restart loop knows when to give up.
    private var wantsRunning = false
    private var state: PeerSSHTunnelState = .stopped
    private var restartTask: Task<Void, Never>?

    /// Fired on every state transition. Always invoked on the main
    /// actor; observers can safely touch UI state directly.
    var onStateChange: (@MainActor (PeerSSHTunnelState) -> Void)?

    init(sshTarget: String, remoteSockPath: String) {
        self.sshTarget = sshTarget
        self.remoteSockPath = remoteSockPath
        let uuid = UUID().uuidString.lowercased().prefix(8)
        self.localSockPath = "/tmp/tm-peer-ssh-\(uuid).sock"
    }

    var currentState: PeerSSHTunnelState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Spawns `ssh -N -T -L local:remote target` and waits up to 10s
    /// for the local socket to materialise. Throws on spawn failure or
    /// timeout (and tears the ssh process down on timeout). On a
    /// successful return, the auto-restart loop is armed.
    func start() async throws {
        lock.lock()
        if process != nil {
            lock.unlock()
            throw PeerSSHTunnelError.alreadyRunning
        }
        wantsRunning = true
        lock.unlock()
        emit(.starting)
        try await spawnOnce()
        emit(.up)
    }

    /// Re-arm the auto-restart loop after a `.failed` transition. The
    /// controller's banner "Retry" action wires through here so the
    /// user can ask for another round of attempts after the cap was
    /// hit (e.g. once they've fixed the SSH config / brought the
    /// remote server back up). No-op if the tunnel is currently
    /// stopped or already running.
    func retry() {
        lock.lock()
        if process != nil || restartTask != nil {
            lock.unlock()
            return
        }
        wantsRunning = true
        lock.unlock()
        scheduleReconnect(reason: "user retry")
    }

    /// Tears the ssh subprocess down and disarms auto-restart. Safe to
    /// call repeatedly.
    func stop() {
        lock.lock()
        wantsRunning = false
        let p = process
        process = nil
        let task = restartTask
        restartTask = nil
        lock.unlock()
        task?.cancel()
        if let p, p.isRunning {
            p.terminate()
            // Reap; ssh -N exits within a few hundred ms of SIGTERM.
            p.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: localSockPath)
        emit(.stopped)
    }

    deinit {
        stop()
    }

    // MARK: - Internals

    private func spawnOnce() async throws {
        try? FileManager.default.removeItem(atPath: localSockPath)

        // Reject inputs that could be reinterpreted as ssh options.
        // `sshTarget` is appended unquoted at the end of argv, so a
        // value starting with `-` (e.g. `-oProxyCommand=…`) would let
        // a malicious dialog entry execute arbitrary local commands.
        // `remoteSockPath` lives inside the `-L` value where colons
        // are field separators; an embedded colon silently rewrites
        // the forward target.
        try Self.validateSshTarget(sshTarget)
        try Self.validateRemoteSockPath(remoteSockPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-N", "-T",
            "-o", "LogLevel=ERROR",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindMask=0177",
            "-L", "\(localSockPath):\(remoteSockPath)",
            // `--` ends ssh option parsing so the trailing target is
            // always treated positionally, even if it sneaks past the
            // validator above.
            "--",
            sshTarget,
        ]
        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe
        proc.standardInput = nil

        // ssh exited — schedule reconnect if the caller still wants
        // the tunnel up. Runs on a background thread; we hop to main
        // for state changes.
        proc.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.lock.lock()
            // If `process` no longer points at this proc, somebody
            // else (stop / new spawn) already handled the transition.
            if self.process !== terminated {
                self.lock.unlock()
                return
            }
            self.process = nil
            let stillWants = self.wantsRunning
            self.lock.unlock()
            if stillWants {
                self.scheduleReconnect()
            }
        }

        do {
            try proc.run()
        } catch {
            throw PeerSSHTunnelError.spawnFailed(String(describing: error))
        }

        lock.lock()
        process = proc
        lock.unlock()

        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: localSockPath) {
            if Date() > deadline {
                terminateCurrentProcess()
                let stderrData = errPipe.fileHandleForReading.availableData
                let detail = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
                throw PeerSSHTunnelError.socketNeverAppeared(
                    "ssh forward never created \(localSockPath); ssh stderr: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            if !proc.isRunning {
                let stderrData = errPipe.fileHandleForReading.availableData
                let detail = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
                throw PeerSSHTunnelError.spawnFailed(
                    "ssh exited with code \(proc.terminationStatus); stderr: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func terminateCurrentProcess() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
    }

    /// Maximum number of consecutive reconnect attempts before the
    /// tunnel transitions to `.failed` and stops trying. The user
    /// surfaces a "Retry" banner action from the controller to
    /// re-arm reconnection — important for permanent-failure cases
    /// (server uninstalled, target user deleted, DNS gone) where the
    /// previous unbounded loop kept spawning ssh forever.
    private static let maxReconnectAttempts = 12

    /// Backoff loop: 1s, 2s, 4s, 8s, 16s, 30s, 30s … capped. Stops
    /// when `wantsRunning` flips false (caller stopped explicitly),
    /// when a respawn succeeds, or when the cap is reached.
    ///
    /// Emits `.down` exactly once when the loop arms, then only
    /// `.reconnecting(attempt:)` per iteration. The previous version
    /// re-emitted `.down` on every retry, which made the controller
    /// re-run `tearDownPeerSessions` for an already-torn-down state
    /// and raced with any work that had started in response to a
    /// transient `.up`. Initial reason carries through to the listener
    /// for richer diagnostics; per-attempt errors are folded into the
    /// `.reconnecting` count rather than re-flapped through `.down`.
    private func scheduleReconnect(reason initialReason: String = "ssh exited") {
        lock.lock()
        if !wantsRunning || restartTask != nil {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            // One-shot down emission so the controller tears down its
            // per-pane sessions exactly once before we start retrying.
            self.emit(.down(reason: initialReason))
            var attempt = 1
            var lastError: String = initialReason
            while !Task.isCancelled, attempt <= Self.maxReconnectAttempts {
                self.emit(.reconnecting(attempt: attempt))
                let delaySec = min(30, 1 << min(attempt - 1, 5))
                try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
                if Task.isCancelled { break }
                self.lock.lock()
                let stillWants = self.wantsRunning
                self.lock.unlock()
                if !stillWants { break }
                do {
                    try await self.spawnOnce()
                    self.emit(.up)
                    self.lock.lock()
                    self.restartTask = nil
                    self.lock.unlock()
                    return
                } catch {
                    lastError = String(describing: error)
                    attempt += 1
                }
            }
            // Retries exhausted (or cancelled). Move to a terminal
            // state so the UI can offer an explicit Retry rather than
            // showing "Reconnecting (try N)…" forever.
            self.lock.lock()
            self.restartTask = nil
            let stillWants = self.wantsRunning
            self.lock.unlock()
            if stillWants && !Task.isCancelled {
                self.emit(.failed(
                    reason: "gave up after \(Self.maxReconnectAttempts) attempts: \(lastError)"
                ))
            }
        }
        restartTask = task
        lock.unlock()
    }

    private func emit(_ newState: PeerSSHTunnelState) {
        lock.lock()
        state = newState
        let cb = onStateChange
        lock.unlock()
        guard let cb else { return }
        Task { @MainActor in
            cb(newState)
        }
    }

    // MARK: - Argument validation

    /// Reject SSH targets that would slip past the `--` separator into
    /// option position. Keeps the input in the union of {ssh-config
    /// alias, `user@host`, `host`, `host:port`-style hostnames}.
    static func validateSshTarget(_ value: String) throws {
        guard !value.isEmpty else {
            throw PeerSSHTunnelError.invalidArgument("SSH target is empty")
        }
        if value.hasPrefix("-") {
            throw PeerSSHTunnelError.invalidArgument(
                "SSH target may not start with '-' (would be parsed as an ssh option)"
            )
        }
        // Newlines / NUL would let a future logging or argv path
        // misinterpret the value. Whitespace inside is suspicious in
        // any standard ssh target.
        let banned: Set<Character> = ["\n", "\r", "\0", " ", "\t"]
        if value.contains(where: { banned.contains($0) }) {
            throw PeerSSHTunnelError.invalidArgument(
                "SSH target contains whitespace or control characters"
            )
        }
    }

    /// Reject remote socket paths that contain the colon delimiter
    /// used inside `-L local:remote` (or that try to escape via a
    /// leading `-`). A path with a colon would silently rewrite the
    /// forward semantics and route bytes to a different destination.
    static func validateRemoteSockPath(_ value: String) throws {
        guard !value.isEmpty else {
            throw PeerSSHTunnelError.invalidArgument("Remote socket path is empty")
        }
        if value.contains(":") {
            throw PeerSSHTunnelError.invalidArgument(
                "Remote socket path may not contain ':' (collides with -L delimiter)"
            )
        }
        if value.hasPrefix("-") {
            throw PeerSSHTunnelError.invalidArgument(
                "Remote socket path may not start with '-'"
            )
        }
        if value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            throw PeerSSHTunnelError.invalidArgument(
                "Remote socket path contains control characters"
            )
        }
    }
}
