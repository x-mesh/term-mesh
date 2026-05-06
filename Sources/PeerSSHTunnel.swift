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
}

enum PeerSSHTunnelState: Sendable, Equatable {
    case stopped
    case starting
    case up
    case down(reason: String)
    case reconnecting(attempt: Int)
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

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-N", "-T",
            "-o", "LogLevel=ERROR",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-L", "\(localSockPath):\(remoteSockPath)",
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

    /// Backoff loop: 1s, 2s, 4s, 8s, 16s, 30s, 30s … capped. Stops
    /// when `wantsRunning` flips false (caller stopped explicitly) or
    /// when a respawn succeeds.
    private func scheduleReconnect() {
        lock.lock()
        if !wantsRunning || restartTask != nil {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            var attempt = 1
            while !Task.isCancelled {
                self.emit(.down(reason: "ssh exited"))
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
                    attempt += 1
                }
            }
            self.lock.lock()
            self.restartTask = nil
            self.lock.unlock()
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
}
