import Foundation

/// Client for communicating with the term-meshd Rust daemon over Unix socket.
/// Uses JSON-RPC 2.0 (line-delimited) protocol.
final class TermMeshDaemon {
    static let shared = TermMeshDaemon()

    private var daemonProcess: Process?
    private let queue = DispatchQueue(label: "term-mesh.daemon", qos: .utility)
    private var nextId: Int = 1

    /// Whether worktree sandboxing is enabled for new tabs.
    var worktreeEnabled: Bool = false

    // MARK: - Socket Path

    var socketPath: String {
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return (tmpDir as NSString).appendingPathComponent("term-meshd.sock")
    }

    // MARK: - Daemon Lifecycle

    /// Spawn the term-meshd daemon process if not already running.
    func startDaemon() {
        queue.async { [weak self] in
            guard let self else { return }

            // Already running (tracked process)?
            if let proc = self.daemonProcess, proc.isRunning { return }

            // Already running (orphaned from previous app launch)? Reuse it.
            if self.ping() {
                print("[term-mesh] daemon already running on socket, reusing")
                return
            }

            // Clean up stale socket before starting
            try? FileManager.default.removeItem(atPath: self.socketPath)

            // Find the daemon binary next to the app bundle, or in the daemon build dir
            let binaryPath = self.daemonBinaryPath()
            guard let binaryPath, FileManager.default.fileExists(atPath: binaryPath) else {
                print("[term-mesh] daemon binary not found, skipping launch")
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.environment = ProcessInfo.processInfo.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                self.daemonProcess = process
                print("[term-mesh] daemon started (pid: \(process.processIdentifier))")
            } catch {
                print("[term-mesh] failed to start daemon: \(error)")
            }
        }
    }

    /// Stop the daemon process.
    func stopDaemon() {
        queue.sync {
            guard let proc = daemonProcess, proc.isRunning else { return }
            proc.terminate()
            proc.waitUntilExit()
            daemonProcess = nil
            print("[term-mesh] daemon stopped")

            // Clean up socket file
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    // MARK: - RPC Calls

    /// Create a worktree sandbox for the given repo path.
    /// Returns the worktree path on success, nil on failure.
    func createWorktree(repoPath: String, branch: String? = nil) -> WorktreeInfo? {
        var params: [String: Any] = ["repo_path": repoPath]
        if let branch { params["branch"] = branch }
        guard let response = rpcCall(method: "worktree.create", params: params) else { return nil }
        return parseWorktreeInfo(response)
    }

    /// Remove a worktree by name.
    func removeWorktree(repoPath: String, name: String) -> Bool {
        let params: [String: Any] = ["repo_path": repoPath, "name": name]
        return rpcCall(method: "worktree.remove", params: params) != nil
    }

    /// List all term-mesh worktrees for a repo.
    func listWorktrees(repoPath: String) -> [WorktreeInfo] {
        let params: [String: Any] = ["repo_path": repoPath]
        guard let response = rpcCall(method: "worktree.list", params: params),
              let array = response as? [[String: Any]] else { return [] }
        return array.compactMap { parseWorktreeInfo($0) }
    }

    // MARK: - Monitor (F-03/F-04)

    /// Track a process by PID for resource monitoring.
    func trackPID(_ pid: Int32) {
        let _ = rpcCall(method: "monitor.track", params: ["pid": pid])
    }

    /// Untrack a process.
    func untrackPID(_ pid: Int32) {
        let _ = rpcCall(method: "monitor.untrack", params: ["pid": pid])
    }

    // MARK: - Budget Guard (F-03/F-04)

    /// Send SIGSTOP to a process via the daemon.
    func stopProcess(pid: Int32) -> Bool {
        guard let response = rpcCall(method: "process.stop", params: ["pid": pid]) as? [String: Any] else { return false }
        return response["stopped"] as? Bool ?? false
    }

    /// Send SIGCONT to resume a stopped process via the daemon.
    func resumeProcess(pid: Int32) -> Bool {
        guard let response = rpcCall(method: "process.resume", params: ["pid": pid]) as? [String: Any] else { return false }
        return response["resumed"] as? Bool ?? false
    }

    /// Enable/disable auto-stop when budget thresholds are exceeded.
    func setAutoStop(enabled: Bool) {
        let _ = rpcCall(method: "budget.auto_stop", params: ["enabled": enabled])
    }

    // MARK: - Token Tracking (F-03/F-04)

    /// Report terminal output text for token counting.
    /// Accumulates tokens for the given PID.
    func reportTokens(pid: Int32, text: String) {
        let _ = rpcCall(method: "tokens.report", params: ["pid": pid, "text": text])
    }

    /// Get token snapshot for all tracked PIDs.
    func tokenSnapshot() -> [[String: Any]] {
        guard let response = rpcCall(method: "tokens.snapshot", params: [:]) as? [[String: Any]] else { return [] }
        return response
    }

    // MARK: - Watcher (F-05)

    /// Start watching a directory for file events.
    func watchPath(_ path: String) {
        let _ = rpcCall(method: "watcher.watch", params: ["path": path])
    }

    /// Stop watching a directory.
    func unwatchPath(_ path: String) {
        let _ = rpcCall(method: "watcher.unwatch", params: ["path": path])
    }

    // MARK: - Sessions

    /// Sync terminal sessions with the daemon (for remote dashboard).
    func syncSessions(_ sessions: [[String: Any]]) {
        let _ = rpcCall(method: "session.sync", params: ["sessions": sessions])
    }

    // MARK: - General

    /// Ping the daemon to check connectivity.
    func ping() -> Bool {
        guard let response = rpcCall(method: "ping", params: [:]) else { return false }
        return (response as? String) == "pong"
    }

    /// Raw RPC call that returns the result as a JSON string (for injecting into WKWebView).
    func rpcCallRaw(method: String, params: [String: Any]) -> String? {
        guard let response = rpcCall(method: method, params: params) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Private

    private func rpcCall(method: String, params: [String: Any]) -> Any? {
        let id = nextId
        nextId += 1

        let request: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              var jsonString = String(data: data, encoding: .utf8) else { return nil }
        jsonString += "\n"

        // Connect to Unix socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        // Set timeout
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Send request
        let sent = jsonString.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
        guard sent > 0 else { return nil }

        // Read response (line-delimited)
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(UInt8(ascii: "\n")) { break }
        }

        guard !responseData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }

        if let error = json["error"] as? [String: Any] {
            print("[term-mesh] RPC error: \(error["message"] ?? "unknown")")
            return nil
        }

        return json["result"]
    }

    private func daemonBinaryPath() -> String? {
        // Option 1: Built in the daemon/ directory (development)
        let devPath = (ProcessInfo.processInfo.environment["CMUX_PROJECT_DIR"] ?? "")
            + "/daemon/target/debug/term-meshd"
        if FileManager.default.fileExists(atPath: devPath) { return devPath }

        // Option 2: Next to the app bundle
        if let bundlePath = Bundle.main.executablePath {
            let dir = (bundlePath as NSString).deletingLastPathComponent
            let bundledPath = (dir as NSString).appendingPathComponent("term-meshd")
            if FileManager.default.fileExists(atPath: bundledPath) { return bundledPath }
        }

        // Option 3: Hardcoded project path (development fallback)
        let fallback = "/Users/jinwoo/work/cmux-term-mesh/daemon/target/debug/term-meshd"
        if FileManager.default.fileExists(atPath: fallback) { return fallback }

        return nil
    }

    private func parseWorktreeInfo(_ obj: Any?) -> WorktreeInfo? {
        guard let dict = obj as? [String: Any],
              let name = dict["name"] as? String,
              let path = dict["path"] as? String,
              let branch = dict["branch"] as? String else { return nil }
        return WorktreeInfo(name: name, path: path, branch: branch)
    }
}

// MARK: - Data Models

struct WorktreeInfo {
    let name: String
    let path: String
    let branch: String
}
