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

    /// Explicit SSH port (`-p`). nil = ssh default / ssh-config value.
    let port: Int?
    /// Identity file (`-i`). nil = default key chain / ssh-config value.
    let identityFile: String?

    /// Remote HTTP dashboard port to forward alongside the peer socket.
    /// `nil` disables the forward entirely.
    let dashboardRemotePort: Int?

    private var process: Process?
    private let lock = NSLock()
    /// Local port the remote dashboard is reachable on while the tunnel
    /// is up. `nil` whenever the forward is disabled or was skipped.
    private var dashboardPort: Int?
    /// Caller wants the tunnel running. Cleared by `stop()` so the
    /// auto-restart loop knows when to give up.
    private var wantsRunning = false
    private var state: PeerSSHTunnelState = .stopped
    private var restartTask: Task<Void, Never>?

    /// Fired on every state transition. Always invoked on the main
    /// actor; observers can safely touch UI state directly.
    var onStateChange: (@MainActor (PeerSSHTunnelState) -> Void)?

    init(
        sshTarget: String,
        remoteSockPath: String,
        dashboardRemotePort: Int? = nil,
        port: Int? = nil,
        identityFile: String? = nil
    ) {
        self.sshTarget = sshTarget
        self.remoteSockPath = remoteSockPath
        self.dashboardRemotePort = dashboardRemotePort
        self.port = port
        self.identityFile = identityFile
        let uuid = UUID().uuidString.lowercased().prefix(8)
        // Embed the owning app's PID in the filename so the startup
        // sweep can distinguish "left over from a dead app instance"
        // from "currently held by a sibling app instance" (DEV vs
        // STAGING vs Release running side-by-side, or a tagged debug
        // build alongside the main app — see CLAUDE.md). Without the
        // PID, sweep would PPID-only-classify a sibling's healthy
        // tunnel as an orphan and SIGTERM it.
        let owner = ProcessInfo.processInfo.processIdentifier
        self.localSockPath = "/tmp/tm-peer-ssh-\(owner)-\(uuid).sock"
    }

    var currentState: PeerSSHTunnelState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Local port serving the remote dashboard, or `nil` when the
    /// forward is off or could not be established.
    var dashboardLocalPort: Int? {
        lock.lock(); defer { lock.unlock() }
        return dashboardPort
    }

    /// Loopback URL for the remote host's dashboard while the tunnel is
    /// up. `nil` when the forward is off or was skipped.
    var dashboardURL: URL? {
        dashboardLocalPort.flatMap { URL(string: "http://127.0.0.1:\($0)/") }
    }

    /// First loopback port at or above `Self.dashboardPortBase` that
    /// nothing is bound to, preferring `preferred` so the dashboard URL
    /// survives a reconnect. Falls back to a `target`-derived slot before
    /// scanning sequentially, so a given host consistently prefers "its
    /// own" port across reconnects and across separate `PeerSSHTunnel`
    /// instances — a stale browser tab left open on a freed port is far
    /// less likely to silently start driving a *different* host's
    /// dashboard the next time that port comes free. This narrows the
    /// window rather than closing it (the scan range is finite and hash
    /// collisions are possible), which is why `dashboardURL` is still
    /// best-effort, not a durable per-host identity.
    ///
    /// Returns `nil` when the whole scan range is taken — the caller then
    /// drops the forward rather than risk `ExitOnForwardFailure` taking
    /// the peer tunnel down with it.
    ///
    /// This is a bind probe, so it races anything that grabs the port in
    /// the window between the probe and ssh's own bind. That race is why
    /// `spawnOnce` retries without the forward instead of trusting it.
    private static func claimLocalPort(preferring preferred: Int?, target: String) -> Int? {
        var candidates: [Int] = []
        if let preferred { candidates.append(preferred) }
        let hashed = preferredPort(for: target)
        if hashed != preferred { candidates.append(hashed) }
        candidates += (dashboardPortBase..<(dashboardPortBase + dashboardPortScanRange))
            .filter { $0 != preferred && $0 != hashed }
        return candidates.first(where: isLoopbackPortFree)
    }

    /// Stable-within-this-process-launch starting slot for `target`.
    /// `Hasher` reseeds every launch (hash-flooding protection), so this
    /// intentionally does not persist across app restarts — a restart
    /// already invalidates any tab left open on an old dashboard URL.
    private static func preferredPort(for target: String) -> Int {
        var hasher = Hasher()
        hasher.combine(target)
        let offset = abs(hasher.finalize()) % dashboardPortScanRange
        return dashboardPortBase + offset
    }

    private static func isLoopbackPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// Local dashboard ports start here rather than at the remote's 9876:
    /// the app's own term-meshd already holds 9876 on this machine, and
    /// several peer hosts can be connected at once.
    private static let dashboardPortBase = 19876
    private static let dashboardPortScanRange = 100

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

    /// Force the current ssh subprocess through the normal reconnect
    /// loop. Used when the Unix-socket peer session closes while ssh
    /// itself is still alive, which can happen across sleep/wake or
    /// remote peer-server restarts. In that state `Process`
    /// termination will not fire, but every pane session is already
    /// dead from the relay's perspective.
    func forceReconnect(reason: String) {
        lock.lock()
        if restartTask != nil {
            lock.unlock()
            return
        }
        wantsRunning = true
        let p = process
        process = nil
        lock.unlock()

        var sshActuallyExited = (p == nil)
        if let p, p.isRunning {
            p.terminate()
            sshActuallyExited = waitForExit(p, timeout: 2.0)
            if !sshActuallyExited {
                kill(p.processIdentifier, SIGKILL)
                sshActuallyExited = waitForExit(p, timeout: 1.0)
            }
        }
        if sshActuallyExited {
            try? FileManager.default.removeItem(atPath: localSockPath)
        }
        scheduleReconnect(reason: reason)
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
        dashboardPort = nil
        lock.unlock()
        task?.cancel()
        // Only unlink the local socket once we've actually reaped ssh.
        // If `p` is nil here, the terminationHandler already fired —
        // ssh has exited and unlinking the path is safe. If `p` is
        // alive but `terminate()` doesn't kill it within the grace
        // window, we escalate to SIGKILL rather than blocking forever
        // and we leave the socket file alone so a still-running ssh
        // doesn't end up as a "ghost socket" (kernel-bound but path
        // gone), which is exactly the corruption a mid-stop crash
        // used to leave behind.
        var sshActuallyExited = (p == nil)
        if let p, p.isRunning {
            p.terminate()
            sshActuallyExited = waitForExit(p, timeout: 2.0)
            if !sshActuallyExited {
                kill(p.processIdentifier, SIGKILL)
                sshActuallyExited = waitForExit(p, timeout: 1.0)
            }
        } else {
            sshActuallyExited = true
        }
        if sshActuallyExited {
            try? FileManager.default.removeItem(atPath: localSockPath)
            emit(.stopped)
        } else {
            // SIGKILL didn't reap ssh (rare — typically a kernel-level
            // hang or PID reuse). The socket file is intentionally not
            // unlinked above so we don't ghost-socket a still-running
            // process. Emit `.failed` instead of `.stopped` so UI
            // listeners can surface the leak (banner, telemetry) and
            // the next-launch sweep can clean up via owner-PID gating.
            emit(.failed(reason: "ssh did not exit after SIGTERM+SIGKILL; tunnel state leaked"))
        }
    }

    /// Polls `Process.isRunning` up to `timeout` seconds. Returns
    /// `true` if the process exited within the budget, `false`
    /// otherwise. Avoids `waitUntilExit()` which blocks indefinitely
    /// when ssh ignores SIGTERM (rare but observed during sleep/wake
    /// or with mis-configured ProxyCommand chains).
    private func waitForExit(_ proc: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    deinit {
        stop()
    }

    // MARK: - Internals

    /// Brings the tunnel up, forwarding the remote dashboard when one is
    /// configured. The dashboard forward is strictly best-effort: the peer
    /// socket is the reason this tunnel exists, and `ExitOnForwardFailure=yes`
    /// means a dashboard bind that loses a race would take the peer forward
    /// down with it. So a spawn carrying the dashboard that fails is retried
    /// once without it.
    private func spawnOnce() async throws {
        guard dashboardRemotePort != nil else {
            try await spawnAttempt(dashboardLocalPort: nil)
            return
        }

        lock.lock()
        let previous = dashboardPort
        lock.unlock()

        if let port = Self.claimLocalPort(preferring: previous, target: sshTarget) {
            do {
                try await spawnAttempt(dashboardLocalPort: port)
                return
            } catch {
                // A caller-initiated stop/cancel racing this attempt must
                // propagate immediately rather than spawn a second,
                // unowned ssh: `stop()` already reaped the first process
                // and nothing is left to kill the retry. Check
                // Task.isCancelled (covers cancellation from any source,
                // not just our own restartTask) and wantsRunning (covers
                // stop() clearing intent without the cancellation token
                // reaching this frame, e.g. during the first start()).
                if Task.isCancelled { throw error }
                lock.lock()
                let stillWants = wantsRunning
                lock.unlock()
                guard stillWants else { throw error }

                // Only retry without the dashboard when the failure looks
                // like the dashboard forward itself losing its bind race
                // (ExitOnForwardFailure kills ssh, which stderr reports as
                // a listen/bind/forwarding failure). Anything else — bad
                // target, auth failure, ssh missing, the generic 10s
                // socket-wait timeout — is not a dashboard problem, and
                // retrying it would just pay the same timeout twice.
                guard Self.looksLikeForwardBindFailure(error) else { throw error }
                RemoteWorkLog.debugOffMain(
                    "Dashboard port forward lost its bind race on \(sshTarget) — respawning the tunnel without it"
                )
            }
        }
        try await spawnAttempt(dashboardLocalPort: nil)
    }

    /// Best-effort classifier for "ssh exited because a `-L` forward
    /// couldn't bind" vs. every other `spawnAttempt` failure (missing
    /// binary, bad target, auth failure, generic timeout). Matches the
    /// stderr substrings OpenSSH actually emits for `ExitOnForwardFailure`
    /// rejections. False negatives just skip the retry (safe: the caller
    /// still gets a connection attempt, minus the redundant one); this is
    /// deliberately not exhaustive across OpenSSH versions/locales.
    private static func looksLikeForwardBindFailure(_ error: Error) -> Bool {
        let message: String
        switch error {
        case PeerSSHTunnelError.spawnFailed(let detail): message = detail
        default: return false
        }
        let signals = ["cannot listen", "address already in use", "could not request local forwarding", "bind:"]
        let lowered = message.lowercased()
        return signals.contains { lowered.contains($0) }
    }

    private func spawnAttempt(dashboardLocalPort: Int?) async throws {
        lock.lock()
        dashboardPort = dashboardLocalPort
        lock.unlock()

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
        if let port { try Self.validatePort(port) }
        if let identityFile { try Self.validateIdentityFile(identityFile) }

        // Optional auth parameters from a saved host profile. Values are
        // validated above and formatted here (Int → String, tilde
        // expansion), so nothing user-controlled can reach option
        // position unchecked.
        var authArgs: [String] = []
        if let port { authArgs += ["-p", String(port)] }
        if let identityFile {
            authArgs += ["-i", (identityFile as NSString).expandingTildeInPath]
        }

        // Forward the remote dashboard onto a loopback port here. Both
        // ends stay on 127.0.0.1: term-meshd binds its dashboard to
        // loopback, and so does this end of the forward, so nothing is
        // exposed off-box that was not already. The local bind address is
        // explicit (`127.0.0.1:<port>:...`) rather than left to ssh's
        // default for two reasons: (1) an unqualified `-L port:...` lets
        // ssh bind `::1` as well as `127.0.0.1`, so `isLoopbackPortFree`'s
        // v4-only probe could pass on a port that's actually taken on v6
        // and kill the whole tunnel via ExitOnForwardFailure; (2) per
        // ssh_config(5), `GatewayPorts` governs the bind address of local
        // (`-L`) forwards, not only remote ones — a user whose own
        // ~/.ssh/config sets `GatewayPorts yes` for unrelated reasons
        // would otherwise have this specific forward bind 0.0.0.0.
        var dashboardArgs: [String] = []
        if let dashboardLocalPort, let remotePort = dashboardRemotePort {
            dashboardArgs = ["-L", "127.0.0.1:\(dashboardLocalPort):127.0.0.1:\(remotePort)"]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-N", "-T",
            // Managed relay tunnels must be owned by this subprocess.
            // If the user's ssh_config has ControlMaster/ControlPath
            // enabled, ssh can hand the forward to an existing master
            // connection and exit immediately; the forward may work,
            // but our Process lifetime then looks "down" and the UI
            // shows a false reconnect banner. `-S none` disables
            // multiplexing for this invocation.
            "-S", "none",
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "LogLevel=ERROR",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindMask=0177",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=no",
        ] + authArgs + [
            "-L", "\(localSockPath):\(remoteSockPath)",
        ] + dashboardArgs + [
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

        if !proc.isRunning {
            let stderrData = errPipe.fileHandleForReading.availableData
            let detail = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
            throw PeerSSHTunnelError.spawnFailed(
                "ssh exited after creating \(localSockPath); stderr: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
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
        report(newState)
        guard let cb else { return }
        Task { @MainActor in
            cb(newState)
        }
    }

    /// Put every tunnel transition in the Remote Work log.
    ///
    /// This is the one place all of them pass through, and until now the only
    /// trace of a tunnel dying was a banner that a workspace window had to be
    /// open to show and that erased itself three seconds later. A relay that
    /// dropped at 2am and came back left nothing to read in the morning.
    private func report(_ newState: PeerSSHTunnelState) {
        switch newState {
        case .starting:
            RemoteWorkLog.debugOffMain("Tunnel starting → \(sshTarget) (\(remoteSockPath))")
        case .up:
            RemoteWorkLog.infoOffMain("Tunnel up → \(sshTarget)")
        case .down(let reason):
            RemoteWorkLog.infoOffMain("Tunnel down → \(sshTarget): \(reason)")
        case .reconnecting(let attempt):
            RemoteWorkLog.infoOffMain(
                "Reconnecting to \(sshTarget) — attempt \(attempt) of \(Self.maxReconnectAttempts)"
            )
        case .failed(let reason):
            RemoteWorkLog.infoOffMain("Tunnel failed → \(sshTarget): \(reason)")
        case .stopped:
            RemoteWorkLog.debugOffMain("Tunnel stopped → \(sshTarget)")
        }
    }

    // MARK: - Stale-tunnel sweep

    /// Reap leftover SSH tunnels from a previous crashed app run.
    /// Two failure modes show up after an abnormal exit:
    ///
    /// 1. The local listen socket file is left at `/tmp/tm-peer-ssh-<pid>-<uuid>.sock`
    ///    but its owning ssh subprocess is gone — connect() would fail
    ///    with ECONNREFUSED forever.
    /// 2. The ssh subprocess survives (reparented to launchd) but its
    ///    bind path was already unlinked by a partial `stop()`. lsof
    ///    sees the unix socket, but `connect(path)` returns ENOENT
    ///    because the directory entry is gone — the "ghost socket"
    ///    failure that motivated this sweep.
    ///
    /// Mode 1 we fix by unlinking the orphaned file. Mode 2 we fix by
    /// killing the orphaned ssh PID; the kernel then drops the socket
    /// inode automatically.
    ///
    /// Multi-instance safety: the sweep must NOT touch a sibling
    /// term-mesh app's live tunnels (DEV/STAGING/Release running
    /// side-by-side, tagged debug builds, etc.). The classifier is
    /// "owner PID embedded in the socket filename / argv is no longer
    /// alive" — not just PPID. A sibling's ssh has PPID = sibling's
    /// app PID (alive), so it's preserved. A leftover ssh has PPID =
    /// 1 (launchd) AND its embedded owner PID is dead, so it's
    /// reaped. The owner-PID gate also covers the case where a
    /// sibling's app PID happens to match `getppid()` for our ssh
    /// (impossible in practice — Process.run is a direct fork — but
    /// the owner-PID check is independent of ancestry).
    static func sweepStaleTunnels() {
        // (a) Files on disk: unlink only if its embedded owner PID is
        //     no longer alive AND no ssh currently holds the path.
        //     Files whose owner is alive (our run, or a sibling
        //     instance's run) are preserved even if we can't read
        //     the lsof state.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") {
            for name in entries
                where name.hasPrefix("tm-peer-ssh-") && name.hasSuffix(".sock")
            {
                let path = "/tmp/\(name)"
                if let owner = ownerPidFromSockName(name), isPidAlive(owner) {
                    continue
                }
                if pidsHoldingPath(path).isEmpty {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }

        // (b) Orphaned ssh subprocesses: any ssh whose -L argv references
        //     /tmp/tm-peer-ssh-<owner>-<uuid>.sock where <owner> is a
        //     dead PID. PPID is intentionally NOT in the predicate — it
        //     would false-positive a sibling app's child after that
        //     sibling exits (PPID becomes 1) AND mis-classify our own
        //     children if they're enumerated mid-fork.
        let pids = orphanedTunnelPids()
        for pid in pids {
            kill(pid, SIGTERM)
        }
        // SIGKILL escalation: ssh that ignores SIGTERM (sleep/wake,
        // mis-configured ProxyCommand, etc.) would otherwise persist
        // across launches because the next-launch sweep just sends
        // another ineffectual SIGTERM. We mirror `stop()`'s 2s grace
        // budget here. Sweep runs on a background queue (see
        // AppDelegate), so Thread.sleep is safe.
        if !pids.isEmpty {
            Thread.sleep(forTimeInterval: 1.5)
            for pid in pids where isPidAlive(pid) {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Extracts `<owner>` from a basename like
    /// `tm-peer-ssh-<owner>-<uuid>.sock`. Returns nil for legacy
    /// names (`tm-peer-ssh-<uuid>.sock` from older builds) — those
    /// have no owner gate and fall through to the lsof check.
    private static func ownerPidFromSockName(_ name: String) -> pid_t? {
        // "tm-peer-ssh-".count == 12
        let body = name.dropFirst("tm-peer-ssh-".count).dropLast(".sock".count)
        guard let dash = body.firstIndex(of: "-") else { return nil }
        return pid_t(body[body.startIndex..<dash])
    }

    /// Extracts `<owner>` from a `-L` argv field of the form
    /// `/tmp/tm-peer-ssh-<owner>-<uuid>.sock:<remote>`. Returns nil
    /// if the path doesn't match the expected layout.
    private static func ownerPidFromArgv(_ cmd: String) -> pid_t? {
        guard let range = cmd.range(of: "/tmp/tm-peer-ssh-") else { return nil }
        let after = cmd[range.upperBound...]
        guard let dash = after.firstIndex(of: "-") else { return nil }
        return pid_t(after[after.startIndex..<dash])
    }

    /// True iff a process with `pid` exists. Uses signal 0 which
    /// performs the permission/existence check without delivering a
    /// signal. EPERM means the process exists but belongs to another
    /// uid (we still treat it as alive — leave it alone).
    private static func isPidAlive(_ pid: pid_t) -> Bool {
        if pid <= 1 { return false }   // 0/1 are sentinel; never an owner
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Returns PIDs that have the given path open (any fd type),
    /// using `lsof -t -- <path>`. Empty array on lookup failure or
    /// when nothing holds the path.
    private static func pidsHoldingPath(_ path: String) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-t", "--", path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        guard let data = try? out.fileHandleForReading.readToEnd(),
              let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: { $0.isNewline })
            .compactMap { pid_t($0) }
    }

    /// Scan all running ssh processes; return PIDs whose -L argv
    /// references a `/tmp/tm-peer-ssh-<owner>-<uuid>.sock` path where
    /// `<owner>` is a dead PID. Live owners (our run or a sibling
    /// term-mesh app instance) are preserved. ssh procs whose argv
    /// uses the legacy unowned filename (no embedded PID) are also
    /// preserved — there's no safe way to attribute them, and they
    /// will eventually be cleaned by `pidsHoldingPath` once they die
    /// on their own.
    private static func orphanedTunnelPids() -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "pid=,command="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        guard let data = try? out.fileHandleForReading.readToEnd(),
              let s = String(data: data, encoding: .utf8) else { return [] }

        var result: [pid_t] = []
        for line in s.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1,
                                      omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let pid = pid_t(parts[0])
            else { continue }
            let cmd = String(parts[1])
            // Require both the ssh executable path AND a tm-peer-ssh-
            // socket path that we know is ours (owner-prefixed). The
            // owner-prefixed match keeps us from ever SIGTERMing a
            // benign ssh whose argv merely contains the substring.
            guard cmd.contains("/usr/bin/ssh"),
                  let owner = ownerPidFromArgv(cmd)
            else { continue }
            if isPidAlive(owner) { continue }   // sibling or self
            result.append(pid)
        }
        return result
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

    /// Reject ports outside the TCP range. The value is always
    /// formatted via `String(_: Int)` so it can never carry an
    /// option-injection payload; the range check fails fast on
    /// nonsense saved-profile values.
    static func validatePort(_ value: Int) throws {
        guard (1...65535).contains(value) else {
            throw PeerSSHTunnelError.invalidArgument(
                "SSH port must be 1-65535 (got \(value))"
            )
        }
    }

    /// Reject identity-file paths that could be reinterpreted as ssh
    /// options or that don't point at an existing file. `-i`'s value
    /// position makes injection unlikely, but the same posture as the
    /// other argv inputs is kept: no leading '-', no control
    /// characters, absolute after tilde expansion, must exist.
    static func validateIdentityFile(_ value: String) throws {
        guard !value.isEmpty else {
            throw PeerSSHTunnelError.invalidArgument("Identity file path is empty")
        }
        if value.hasPrefix("-") {
            throw PeerSSHTunnelError.invalidArgument(
                "Identity file path may not start with '-'"
            )
        }
        if value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            throw PeerSSHTunnelError.invalidArgument(
                "Identity file path contains control characters"
            )
        }
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw PeerSSHTunnelError.invalidArgument(
                "Identity file path must be absolute (or ~-relative)"
            )
        }
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw PeerSSHTunnelError.invalidArgument(
                "Identity file not found: \(expanded)"
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
