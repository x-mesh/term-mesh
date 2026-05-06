// Phase D-4: SSH transport for peer federation.
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

import Foundation

enum PeerSSHTunnelError: Error {
    case spawnFailed(String)
    case socketNeverAppeared(String)
    case alreadyRunning
}

final class PeerSSHTunnel: @unchecked Sendable {
    let sshTarget: String
    let remoteSockPath: String
    let localSockPath: String

    private var process: Process?
    private let lock = NSLock()

    init(sshTarget: String, remoteSockPath: String) {
        self.sshTarget = sshTarget
        self.remoteSockPath = remoteSockPath
        let uuid = UUID().uuidString.lowercased().prefix(8)
        self.localSockPath = "/tmp/tm-peer-ssh-\(uuid).sock"
    }

    /// Spawns `ssh -N -T -L local:remote target` and waits up to 10s
    /// for the local socket to materialise. Throws on spawn failure or
    /// timeout (and tears the ssh process down on timeout).
    func start() async throws {
        lock.lock()
        if process != nil {
            lock.unlock()
            throw PeerSSHTunnelError.alreadyRunning
        }
        lock.unlock()

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
        // Drop stderr/stdout into pipes so ssh banners don't leak into
        // the parent process's terminal output. We surface errors via
        // socketNeverAppeared rather than parsing ssh diagnostics.
        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe
        proc.standardInput = nil

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
                stop()
                let stderrData = errPipe.fileHandleForReading.availableData
                let detail = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
                throw PeerSSHTunnelError.socketNeverAppeared(
                    "ssh forward never created \(localSockPath); ssh stderr: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            // Also bail early if ssh died on us (auth failure, etc.)
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

    /// Tears the ssh subprocess down. Safe to call repeatedly.
    func stop() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            // Reap; ssh -N exits within a few hundred ms of SIGTERM.
            p.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: localSockPath)
    }

    deinit {
        stop()
    }
}
