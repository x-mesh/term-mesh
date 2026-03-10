import Foundation
import Combine

/// Client for communicating with the term-meshd Rust daemon over Unix socket.
/// Uses JSON-RPC 2.0 (line-delimited) protocol.
final class TermMeshDaemon: ObservableObject {
    static let shared = TermMeshDaemon()

    private var daemonProcess: Process?
    private let queue = DispatchQueue(label: "term-mesh.daemon", qos: .utility)
    private var nextId: Int = 1

    /// Whether worktree sandboxing is enabled for new tabs.
    @Published var worktreeEnabled: Bool = false

    // MARK: - Dashboard Settings (UserDefaults)

    /// Whether the HTTP dashboard is enabled.
    static let dashboardEnabledKey = "termMeshDashboardEnabled"
    /// Whether to bind to localhost only (true) or 0.0.0.0 (false).
    static let dashboardLocalhostOnlyKey = "termMeshDashboardLocalhostOnly"
    /// Dashboard port.
    static let dashboardPortKey = "termMeshDashboardPort"

    var isDashboardEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.dashboardEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.dashboardEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardEnabledKey) }
    }

    var isLocalhostOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.dashboardLocalhostOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardLocalhostOnlyKey) }
    }

    var dashboardPort: Int {
        get {
            let port = UserDefaults.standard.integer(forKey: Self.dashboardPortKey)
            return port > 0 ? port : 9876
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardPortKey) }
    }

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
            var env = ProcessInfo.processInfo.environment

            // Dashboard settings
            if !self.isDashboardEnabled {
                env["TERM_MESH_HTTP_DISABLED"] = "1"
            } else {
                let host = self.isLocalhostOnly ? "127.0.0.1" : "0.0.0.0"
                env["TERM_MESH_HTTP_ADDR"] = "\(host):\(self.dashboardPort)"
            }

            process.environment = env
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
            // Case 1: We spawned the daemon — terminate directly
            if let proc = daemonProcess, proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
                daemonProcess = nil
                print("[term-mesh] daemon stopped (tracked process)")
            } else {
                // Case 2: Daemon was started externally (nohup, make deploy, etc.)
                // Try graceful shutdown via RPC first
                daemonProcess = nil
                let shutdownSent = sendShutdownRPC()
                if shutdownSent {
                    print("[term-mesh] daemon shutdown RPC sent")
                    // Give it a moment to exit
                    Thread.sleep(forTimeInterval: 0.5)
                }

                // Fallback: kill by process name if still alive
                if ping() {
                    let kill = Process()
                    kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                    kill.arguments = ["-f", "term-meshd"]
                    try? kill.run()
                    kill.waitUntilExit()
                    print("[term-mesh] daemon killed via pkill")
                }
            }

            // Clean up socket file
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    /// Send a shutdown RPC to the daemon (best-effort, no response expected).
    private func sendShutdownRPC() -> Bool {
        let id = nextId
        nextId += 1
        let request: [String: Any] = ["id": id, "method": "shutdown", "params": [:]]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              var jsonString = String(data: data, encoding: .utf8) else { return false }
        jsonString += "\n"

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
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
        guard connectResult == 0 else { return false }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let sent = jsonString.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
        return sent > 0
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

    /// Create a worktree with detailed error reporting.
    func createWorktreeWithError(repoPath: String, branch: String? = nil) -> Result<WorktreeInfo, WorktreeCreateError> {
        // Check if CWD is inside a git repo (walk up to find .git)
        guard let gitRoot = findGitRoot(from: repoPath) else {
            return .failure(.notGitRepo)
        }

        // Check daemon connectivity
        guard ping() else {
            return .failure(.daemonNotConnected)
        }

        var params: [String: Any] = ["repo_path": gitRoot]
        if let branch { params["branch"] = branch }
        guard let response = rpcCall(method: "worktree.create", params: params),
              let info = parseWorktreeInfo(response) else {
            return .failure(.rpcError("Worktree creation failed"))
        }
        return .success(info)
    }

    /// Walk up from `path` to find the nearest directory containing `.git`.
    func findGitRoot(from path: String) -> String? {
        var current = path
        guard !current.isEmpty, current.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        while current != "/" && !current.isEmpty {
            let gitDir = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }  // safety: no progress
            current = parent
        }
        return nil
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

    // MARK: - Usage Tracking (JSONL-based API cost)

    /// Get API usage snapshot (parsed from Claude Code JSONL logs).
    func usageSnapshot() -> [String: Any]? {
        guard let response = rpcCall(method: "usage.snapshot", params: [:]) as? [String: Any] else { return nil }
        return response
    }

    /// Trigger an immediate usage scan.
    func usageScan() {
        let _ = rpcCall(method: "usage.scan", params: [:])
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

    /// Sync app-side team dashboard state with the daemon (for remote dashboard).
    func syncTeams(_ payload: [String: Any]) {
        let _ = rpcCall(method: "team.sync", params: payload)
    }

    // MARK: - Agent Sessions (F-06)

    /// Spawn N agent sessions with worktree sandboxes.
    func spawnAgents(repoPath: String, count: Int = 1, name: String? = nil, command: String? = nil) -> [AgentSessionInfo] {
        var params: [String: Any] = ["repo_path": repoPath, "count": count]
        if let name { params["name"] = name }
        if let command { params["command"] = command }
        guard let response = rpcCall(method: "agent.spawn", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseAgentSessionInfo($0) }
    }

    /// List agent sessions (active only by default).
    func listAgents(includeTerminated: Bool = false) -> [AgentSessionInfo] {
        let params: [String: Any] = ["include_terminated": includeTerminated]
        guard let response = rpcCall(method: "agent.list", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseAgentSessionInfo($0) }
    }

    /// Get a single agent session by ID.
    func getAgent(id: String) -> AgentSessionInfo? {
        guard let response = rpcCall(method: "agent.get", params: ["id": id]) as? [String: Any] else { return nil }
        return parseAgentSessionInfo(response)
    }

    /// Terminate an agent session (cleanup worktree + processes).
    func terminateAgent(id: String, force: Bool = false) -> Bool {
        let params: [String: Any] = ["id": id, "force": force]
        return rpcCall(method: "agent.terminate", params: params) != nil
    }

    /// Bind a UI panel to an agent session.
    func bindAgentPanel(sessionId: String, panelId: String) -> Bool {
        let params: [String: Any] = ["session_id": sessionId, "panel_id": panelId]
        return rpcCall(method: "agent.bind_panel", params: params) != nil
    }

    /// Unbind a UI panel from an agent session (session stays alive).
    func unbindAgentPanel(sessionId: String) -> Bool {
        let params: [String: Any] = ["session_id": sessionId]
        return rpcCall(method: "agent.unbind_panel", params: params) != nil
    }

    /// Register a PID with an agent session.
    func addAgentPid(sessionId: String, pid: Int32) -> Bool {
        let params: [String: Any] = ["session_id": sessionId, "pid": pid]
        return rpcCall(method: "agent.add_pid", params: params) != nil
    }

    // MARK: - Tasks (F-06)

    /// Create a new task.
    func createTask(title: String, description: String? = nil, priority: Int? = nil, createdBy: String? = nil, deps: [String]? = nil) -> TaskInfo? {
        var params: [String: Any] = ["title": title]
        if let description { params["description"] = description }
        if let priority { params["priority"] = priority }
        if let createdBy { params["created_by"] = createdBy }
        if let deps { params["deps"] = deps }
        guard let response = rpcCall(method: "task.create", params: params) as? [String: Any] else { return nil }
        return parseTaskInfo(response)
    }

    /// Get a task by ID.
    func getTask(id: String) -> TaskInfo? {
        guard let response = rpcCall(method: "task.get", params: ["id": id]) as? [String: Any] else { return nil }
        return parseTaskInfo(response)
    }

    /// List tasks with optional status/assignee filters.
    func listTasks(status: String? = nil, assignee: String? = nil) -> [TaskInfo] {
        var params: [String: Any] = [:]
        if let status { params["status"] = status }
        if let assignee { params["assignee"] = assignee }
        guard let response = rpcCall(method: "task.list", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseTaskInfo($0) }
    }

    /// Update a task (title, description, status, priority, assignee).
    func updateTask(id: String, title: String? = nil, description: String? = nil, status: String? = nil, priority: Int? = nil, assignee: String? = nil) -> TaskInfo? {
        var params: [String: Any] = ["id": id]
        if let title { params["title"] = title }
        if let description { params["description"] = description }
        if let status { params["status"] = status }
        if let priority { params["priority"] = priority }
        if let assignee { params["assignee"] = assignee }
        guard let response = rpcCall(method: "task.update", params: params) as? [String: Any] else { return nil }
        return parseTaskInfo(response)
    }

    /// Assign a task to an agent.
    func assignTask(taskId: String, agentId: String) -> TaskInfo? {
        let params: [String: Any] = ["task_id": taskId, "agent_id": agentId]
        guard let response = rpcCall(method: "task.assign", params: params) as? [String: Any] else { return nil }
        return parseTaskInfo(response)
    }

    /// Get task log entries.
    func taskLog(taskId: String, limit: Int? = nil) -> [TaskLogEntry] {
        var params: [String: Any] = ["task_id": taskId]
        if let limit { params["limit"] = limit }
        guard let response = rpcCall(method: "task.log", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseTaskLogEntry($0) }
    }

    // MARK: - Messages (F-06)

    /// Send a message to an agent.
    func sendMessage(toAgent: String, content: String, fromAgent: String? = nil) -> AgentMessageInfo? {
        var params: [String: Any] = ["to_agent": toAgent, "content": content]
        if let fromAgent { params["from_agent"] = fromAgent }
        guard let response = rpcCall(method: "message.send", params: params) as? [String: Any] else { return nil }
        return parseAgentMessageInfo(response)
    }

    /// List messages for an agent.
    func listMessages(agentId: String, unreadOnly: Bool = false, limit: Int? = nil) -> [AgentMessageInfo] {
        var params: [String: Any] = ["agent_id": agentId]
        if unreadOnly { params["unread_only"] = true }
        if let limit { params["limit"] = limit }
        guard let response = rpcCall(method: "message.list", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseAgentMessageInfo($0) }
    }

    /// Acknowledge (mark as read) messages by IDs.
    func ackMessages(messageIds: [Int64]) -> Int {
        let params: [String: Any] = ["message_ids": messageIds]
        guard let response = rpcCall(method: "message.ack", params: params) as? [String: Any] else { return 0 }
        return (response["acknowledged"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Input Queue (F-06)

    /// Enqueue text input for an agent's PTY.
    func enqueueInput(sessionId: String, text: String) -> Bool {
        let params: [String: Any] = ["session_id": sessionId, "text": text]
        return rpcCall(method: "input.enqueue", params: params) != nil
    }

    /// Poll all pending inputs (for Swift-side PTY injection).
    func pollInputs() -> [PendingInputInfo] {
        guard let response = rpcCall(method: "input.poll", params: [:]) as? [[String: Any]] else { return [] }
        return response.compactMap { parsePendingInputInfo($0) }
    }

    // MARK: - Private Parsers

    private func parseAgentSessionInfo(_ dict: [String: Any]) -> AgentSessionInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let repoPath = dict["repo_path"] as? String,
              let worktreeName = dict["worktree_name"] as? String,
              let worktreePath = dict["worktree_path"] as? String,
              let worktreeBranch = dict["worktree_branch"] as? String,
              let status = dict["status"] as? String else { return nil }
        return AgentSessionInfo(
            id: id,
            name: name,
            repoPath: repoPath,
            worktreeName: worktreeName,
            worktreePath: worktreePath,
            worktreeBranch: worktreeBranch,
            command: dict["command"] as? String,
            status: status,
            pid: (dict["pid"] as? NSNumber)?.int32Value,
            panelId: dict["panel_id"] as? String,
            createdAtMs: (dict["created_at_ms"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    private func parseTaskInfo(_ dict: [String: Any]) -> TaskInfo? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String,
              let status = dict["status"] as? String,
              let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.uint64Value,
              let updatedAtMs = (dict["updated_at_ms"] as? NSNumber)?.uint64Value else { return nil }
        return TaskInfo(
            id: id,
            title: title,
            description: dict["description"] as? String,
            status: status,
            priority: (dict["priority"] as? NSNumber)?.intValue ?? 0,
            assignee: dict["assignee"] as? String,
            createdBy: dict["created_by"] as? String,
            deps: dict["deps"] as? [String] ?? [],
            createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs
        )
    }

    private func parseTaskLogEntry(_ dict: [String: Any]) -> TaskLogEntry? {
        guard let id = (dict["id"] as? NSNumber)?.int64Value,
              let taskId = dict["task_id"] as? String,
              let message = dict["message"] as? String,
              let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.uint64Value else { return nil }
        return TaskLogEntry(
            id: id,
            taskId: taskId,
            agentId: dict["agent_id"] as? String,
            message: message,
            createdAtMs: createdAtMs
        )
    }

    private func parseAgentMessageInfo(_ dict: [String: Any]) -> AgentMessageInfo? {
        guard let id = (dict["id"] as? NSNumber)?.int64Value,
              let toAgent = dict["to_agent"] as? String,
              let content = dict["content"] as? String,
              let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.uint64Value else { return nil }
        return AgentMessageInfo(
            id: id,
            fromAgent: dict["from_agent"] as? String,
            toAgent: toAgent,
            content: content,
            read: (dict["read"] as? NSNumber)?.boolValue ?? false,
            createdAtMs: createdAtMs
        )
    }

    private func parsePendingInputInfo(_ dict: [String: Any]) -> PendingInputInfo? {
        guard let sessionId = dict["session_id"] as? String,
              let text = dict["text"] as? String,
              let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.uint64Value else { return nil }
        return PendingInputInfo(
            sessionId: sessionId,
            text: text,
            createdAtMs: createdAtMs
        )
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
        let devPath = (termMeshEnv("PROJECT_DIR") ?? "")
            + "/daemon/target/debug/term-meshd"
        if FileManager.default.fileExists(atPath: devPath) { return devPath }

        // Option 2: Next to the app bundle
        if let bundlePath = Bundle.main.executablePath {
            let dir = (bundlePath as NSString).deletingLastPathComponent
            let bundledPath = (dir as NSString).appendingPathComponent("term-meshd")
            if FileManager.default.fileExists(atPath: bundledPath) { return bundledPath }
        }

        // Option 3: Hardcoded project path (development fallback)
        let fallback = "/Users/jinwoo/work/project/cmux/daemon/target/debug/term-meshd"
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

enum WorktreeCreateError: Error {
    case daemonNotConnected
    case notGitRepo
    case rpcError(String)
}

struct AgentSessionInfo {
    let id: String
    let name: String
    let repoPath: String
    let worktreeName: String
    let worktreePath: String
    let worktreeBranch: String
    let command: String?
    let status: String  // "spawning", "running", "suspended", "terminated"
    let pid: Int32?
    let panelId: String?
    let createdAtMs: UInt64
}

struct TaskInfo {
    let id: String
    let title: String
    let description: String?
    let status: String  // "pending", "assigned", "in_progress", "completed", "failed", "cancelled"
    let priority: Int
    let assignee: String?
    let createdBy: String?
    let deps: [String]
    let createdAtMs: UInt64
    let updatedAtMs: UInt64
}

struct TaskLogEntry {
    let id: Int64
    let taskId: String
    let agentId: String?
    let message: String
    let createdAtMs: UInt64
}

struct AgentMessageInfo {
    let id: Int64
    let fromAgent: String?
    let toAgent: String
    let content: String
    let read: Bool
    let createdAtMs: UInt64
}

struct PendingInputInfo {
    let sessionId: String
    let text: String
    let createdAtMs: UInt64
}
