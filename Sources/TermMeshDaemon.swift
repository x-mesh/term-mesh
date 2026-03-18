import Foundation
import Combine
import os

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
    /// Dashboard password (empty = no auth).
    static let dashboardPasswordKey = "termMeshDashboardPassword"

    var isDashboardEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.dashboardEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.dashboardEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardEnabledKey) }
    }

    var isLocalhostOnly: Bool {
        get {
            // Default to true (localhost only) for security — 0.0.0.0 requires explicit opt-in
            if UserDefaults.standard.object(forKey: Self.dashboardLocalhostOnlyKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.dashboardLocalhostOnlyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardLocalhostOnlyKey) }
    }

    var dashboardPort: Int {
        get {
            let port = UserDefaults.standard.integer(forKey: Self.dashboardPortKey)
            return port > 0 ? port : 9876
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardPortKey) }
    }

    var dashboardPassword: String {
        get { UserDefaults.standard.string(forKey: Self.dashboardPasswordKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardPasswordKey) }
    }

    // MARK: - Worktree Settings (UserDefaults)

    static let worktreeBaseDirKey = "termMeshWorktreeBaseDir"
    static let worktreeAutoCleanupKey = "termMeshWorktreeAutoCleanup"

    var worktreeBaseDir: String {
        get {
            let val = UserDefaults.standard.string(forKey: Self.worktreeBaseDirKey) ?? ""
            return val.isEmpty ? Self.defaultWorktreeBaseDir : val
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.worktreeBaseDirKey) }
    }

    var worktreeAutoCleanup: Bool {
        get { UserDefaults.standard.bool(forKey: Self.worktreeAutoCleanupKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.worktreeAutoCleanupKey) }
    }

    static var defaultWorktreeBaseDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.term-mesh/worktrees"
    }

    // MARK: - Socket Path

    var socketPath: String {
        // Tagged/isolated builds use explicit daemon socket path
        if let override_ = ProcessInfo.processInfo.environment["TERMMESH_DAEMON_UNIX_PATH"],
           !override_.isEmpty {
            return override_
        }
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
                Logger.daemon.info("daemon already running on socket, reusing")
                if let daemonPid = self.getDaemonPeerPid() {
                    DispatchQueue.main.async {
                        TerminalController.shared.trustedDaemonPid = daemonPid
                    }
                }
                return
            }

            // Clean up stale socket before starting
            try? FileManager.default.removeItem(atPath: self.socketPath)

            // Find the daemon binary next to the app bundle, or in the daemon build dir
            let binaryPath = self.daemonBinaryPath()
            guard let binaryPath, FileManager.default.fileExists(atPath: binaryPath) else {
                Logger.daemon.info("daemon binary not found, skipping launch")
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

            // Dashboard password (Bearer token auth)
            let dashPwd = self.dashboardPassword
            if !dashPwd.isEmpty {
                env["TERM_MESH_HTTP_PASSWORD"] = dashPwd
            }

            process.environment = env

            // Log daemon stdout/stderr — isolated per tag
            let tag = termMeshEnv("TAG") ?? ""
            let logPath = tag.isEmpty ? "/tmp/term-meshd.log" : "/tmp/term-meshd-\(tag).log"
            FileManager.default.createFile(atPath: logPath, contents: nil)
            let logHandle = FileHandle(forWritingAtPath: logPath)
            logHandle?.seekToEndOfFile()
            process.standardOutput = logHandle ?? FileHandle.nullDevice
            process.standardError = logHandle ?? FileHandle.nullDevice

            do {
                try process.run()
                self.daemonProcess = process
                let daemonPid = process.processIdentifier
                Logger.daemon.info("daemon started (pid: \(daemonPid, privacy: .public), binary: \(binaryPath, privacy: .public))")
                DispatchQueue.main.async {
                    TerminalController.shared.trustedDaemonPid = daemonPid
                }
            } catch {
                Logger.daemon.error("failed to start daemon: \(error, privacy: .public)")
            }
        }
    }

    /// Stop the daemon process.
    /// Called from applicationWillTerminate — must complete quickly.
    func stopDaemon() {
        // Case 1: We spawned the daemon — terminate directly
        if let proc = daemonProcess, proc.isRunning {
            proc.terminate()
            daemonProcess = nil
            Logger.daemon.info("daemon stopped (tracked process)")
        }

        // Case 2: Kill daemon listening on our socket (isolated — won't affect other instances).
        // Use lsof to find the PID bound to our specific socket path.
        let path = socketPath
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", path]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        let lsofDone = DispatchSemaphore(value: 0)
        lsof.terminationHandler = { _ in lsofDone.signal() }
        try? lsof.run()
        let lsofTimedOut = lsofDone.wait(timeout: .now() + 2.0) == .timedOut
        if lsofTimedOut { lsof.terminate() }
        // On timeout skip reading to avoid blocking on a stale pipe.
        let pidData = lsofTimedOut ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
        if let pidStr = String(data: pidData, encoding: .utf8) {
            for line in pidStr.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGTERM)
                    Logger.daemon.info("daemon killed (pid: \(pid, privacy: .public), socket: \(path, privacy: .public))")
                }
            }
        }

        // Clean up socket file
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Restart

    /// Stop and re-start the daemon process.
    func restartDaemon(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            // Stop synchronously (fast — pkill + socket cleanup)
            // Use async + DispatchGroup to avoid deadlock when main is waiting on this queue
            let stopGroup = DispatchGroup()
            stopGroup.enter()
            DispatchQueue.main.async { [weak self] in
                self?.stopDaemon()
                stopGroup.leave()
            }
            stopGroup.wait()
            // Brief pause so the socket file is fully released
            Thread.sleep(forTimeInterval: 0.3)
            self.startDaemon()
            // Wait for the daemon to become responsive
            for _ in 0..<20 {
                if self.ping() { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Daemon Status

    struct DaemonStatus {
        let connected: Bool
        let pid: Int?
        let uptimeSecs: Int?
        let binaryPath: String?
        let binaryExists: Bool
        let socketPath: String
        let socketExists: Bool
        let logPath: String
        let logExists: Bool
        let appVariant: String       // "Release", "Debug", "Staging", "Nightly", "Debug (tag)"
        let bundleIdentifier: String
        let subsystems: [SubsystemStatus]
    }

    struct SubsystemStatus: Identifiable {
        let id: String   // key name
        let name: String  // display name
        let status: String  // "running", "disabled", "starting", etc.
        let detail: String?
    }

    /// Query the daemon for its full status.
    func daemonStatus() -> DaemonStatus {
        let fm = FileManager.default
        let binPath = daemonBinaryPath()
        let sockPath = socketPath
        let logPath = "/tmp/term-meshd.log"
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let variant = Self.resolveAppVariant()

        let base = { (connected: Bool, pid: Int?, uptime: Int?, subs: [SubsystemStatus]) in
            DaemonStatus(
                connected: connected, pid: pid, uptimeSecs: uptime,
                binaryPath: binPath, binaryExists: binPath != nil && fm.fileExists(atPath: binPath!),
                socketPath: sockPath, socketExists: fm.fileExists(atPath: sockPath),
                logPath: logPath, logExists: fm.fileExists(atPath: logPath),
                appVariant: variant, bundleIdentifier: bundleId,
                subsystems: subs
            )
        }

        guard let response = rpcCall(method: "daemon.status", params: [:]) as? [String: Any] else {
            return base(false, nil, nil, [])
        }

        let pid = (response["pid"] as? NSNumber)?.intValue
        let uptime = (response["uptime_secs"] as? NSNumber)?.intValue
        var subs: [SubsystemStatus] = []

        if let subsystems = response["subsystems"] as? [String: Any] {
            let order = [
                ("socket", "Unix Socket"),
                ("http", "HTTP Dashboard"),
                ("monitor", "Resource Monitor"),
                ("watcher", "File Watcher"),
                ("agents", "Agent Manager"),
            ]
            for (key, displayName) in order {
                guard let info = subsystems[key] as? [String: Any] else { continue }
                let status = info["status"] as? String ?? "unknown"
                var detail: String?
                if let addr = info["addr"] as? String { detail = addr }
                if let count = info["tracked_pids"] as? Int { detail = "\(count) tracked PIDs" }
                if let count = info["watched_paths"] as? Int { detail = "\(count) watched paths" }
                if let count = info["active_sessions"] as? Int { detail = "\(count) active sessions" }
                subs.append(SubsystemStatus(id: key, name: displayName, status: status, detail: detail))
            }
        }

        return base(true, pid, uptime, subs)
    }

    /// Determine the current app variant from bundle identifier and build config.
    static func resolveAppVariant() -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if bundleId == "com.termmesh.app.nightly" { return "Nightly" }
        if SocketControlSettings.isStagingBundleIdentifier(bundleId) { return "Staging" }
        if SocketControlSettings.isDebugLikeBundleIdentifier(bundleId) {
            // Tagged debug builds have bundle IDs like com.termmesh.app.debug.doctor-test
            let suffix = bundleId.replacingOccurrences(of: "com.termmesh.app.debug", with: "")
            if suffix.hasPrefix("."), suffix.count > 1 {
                return "Debug (\(String(suffix.dropFirst())))"
            }
            return "Debug"
        }
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    // MARK: - RPC Calls

    /// Create a worktree sandbox for the given repo path.
    /// Returns the worktree path on success, nil on failure.
    func createWorktree(repoPath: String, branch: String? = nil, baseBranch: String? = nil) -> WorktreeInfo? {
        var params: [String: Any] = ["repo_path": repoPath, "base_dir": worktreeBaseDir]
        if let branch { params["branch"] = branch }
        if let baseBranch { params["base_ref"] = baseBranch }
        guard let response = rpcCall(method: "worktree.create", params: params) else { return nil }
        return parseWorktreeInfo(response)
    }

    /// Create a worktree with detailed error reporting.
    func createWorktreeWithError(repoPath: String, branch: String? = nil, baseBranch: String? = nil) -> Result<WorktreeInfo, WorktreeCreateError> {
        // Check if CWD is inside a git repo (walk up to find .git)
        guard let gitRoot = findGitRoot(from: repoPath) else {
            return .failure(.notGitRepo)
        }

        // Check daemon connectivity
        guard ping() else {
            return .failure(.daemonNotConnected)
        }

        var params: [String: Any] = ["repo_path": gitRoot, "base_dir": worktreeBaseDir]
        if let branch { params["branch"] = branch }
        if let baseBranch { params["base_ref"] = baseBranch }
        guard let response = rpcCall(method: "worktree.create", params: params),
              let info = parseWorktreeInfo(response) else {
            return .failure(.rpcError("Worktree creation failed"))
        }
        return .success(info)
    }

    /// List local branches for a repo.
    func listBranches(repoPath: String) -> [String] {
        let params: [String: Any] = ["repo_path": repoPath]
        guard let response = rpcCall(method: "worktree.list_branches", params: params),
              let array = response as? [String] else { return [] }
        return array
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

    /// Remove a worktree by name (force — skips dirty check).
    func removeWorktree(repoPath: String, name: String) -> Bool {
        let params: [String: Any] = ["repo_path": repoPath, "name": name]
        return rpcCall(method: "worktree.remove", params: params) != nil
    }

    /// Remove a worktree only if it has no uncommitted changes.
    /// Returns a tuple: (success, errorMessage).
    func safeRemoveWorktree(repoPath: String, name: String) -> (Bool, String?) {
        let params: [String: Any] = ["repo_path": repoPath, "name": name]
        if rpcCall(method: "worktree.safe_remove", params: params) != nil {
            return (true, nil)
        }
        // On failure, check status to provide a meaningful message
        let st = worktreeStatus(repoPath: repoPath, name: name)
        if st.dirty {
            return (false, "Worktree has uncommitted changes.")
        }
        return (false, "Failed to remove worktree.")
    }

    /// Check worktree status (dirty / unpushed).
    struct WorktreeStatusResult {
        let dirty: Bool
        let unpushed: Bool
    }

    func worktreeStatus(repoPath: String, name: String) -> WorktreeStatusResult {
        let params: [String: Any] = ["repo_path": repoPath, "name": name]
        guard let response = rpcCall(method: "worktree.status", params: params),
              let dict = response as? [String: Any] else {
            return WorktreeStatusResult(dirty: false, unpushed: false)
        }
        return WorktreeStatusResult(
            dirty: dict["dirty"] as? Bool ?? false,
            unpushed: dict["unpushed"] as? Bool ?? false
        )
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
        var params: [String: Any] = ["repo_path": repoPath, "count": count, "worktree_base_dir": worktreeBaseDir]
        if let name { params["name"] = name }
        if let command { params["command"] = command }
        // Worktree creation takes ~2s per agent; allow generous timeout
        let timeoutSec = max(10, count * 5)
        guard let response = rpcCall(method: "agent.spawn", params: params, timeout: timeoutSec) as? [[String: Any]] else { return [] }
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

    /// Connect to the daemon socket and retrieve its PID via LOCAL_PEERPID.
    /// Used to register an orphaned (reused) daemon as a trusted ancestor.
    private func getDaemonPeerPid() -> pid_t? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size)
        return pid > 0 ? pid : nil
    }

    /// Raw RPC call that returns the result as a JSON string (for injecting into WKWebView).
    func rpcCallRaw(method: String, params: [String: Any]) -> String? {
        guard let response = rpcCall(method: method, params: params) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Private

    private func rpcCall(method: String, params: [String: Any], timeout timeoutSec: Int = 5) -> Any? {
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
        var timeout = timeval(tv_sec: timeoutSec, tv_usec: 0)
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
            let msg = (error["message"] as? String) ?? "unknown"
            Logger.daemon.error("RPC error: \(msg, privacy: .public)")
            return nil
        }

        return json["result"]
    }

    private func daemonBinaryPath() -> String? {
        let fm = FileManager.default
        let projectDir = termMeshEnv("PROJECT_DIR") ?? ""
        let isTagged = termMeshEnv("TAG") != nil

        // Option 0: Explicit binary path override
        if let explicit = termMeshEnv("DAEMON_BINARY_PATH"),
           fm.fileExists(atPath: explicit) { return explicit }

        // Option 1: App bundle Resources/bin/ (tagged builds use their snapshot copy)
        if let resourcePath = Bundle.main.resourcePath {
            let resourceBinPath = (resourcePath as NSString).appendingPathComponent("bin/term-meshd")
            if fm.fileExists(atPath: resourceBinPath) {
                // Tagged builds always prefer bundle binary for isolation
                if isTagged { return resourceBinPath }
            }
        }

        // Option 2: Built in the daemon/ directory (untagged development — debug then release)
        for config in ["debug", "release"] {
            let path = projectDir + "/daemon/target/\(config)/term-meshd"
            if !path.hasPrefix("/daemon") && fm.fileExists(atPath: path) { return path }
        }

        // Option 3: App bundle fallback (release DMG layout, untagged)
        if let resourcePath = Bundle.main.resourcePath {
            let resourceBinPath = (resourcePath as NSString).appendingPathComponent("bin/term-meshd")
            if fm.fileExists(atPath: resourceBinPath) { return resourceBinPath }
        }

        // Option 4: Next to the app executable (legacy layout)
        if let bundlePath = Bundle.main.executablePath {
            let dir = (bundlePath as NSString).deletingLastPathComponent
            let bundledPath = (dir as NSString).appendingPathComponent("term-meshd")
            if fm.fileExists(atPath: bundledPath) { return bundledPath }
        }

        // Option 5: ~/bin/term-meshd (user install via make deploy)
        let homeBin = (NSHomeDirectory() as NSString).appendingPathComponent("bin/term-meshd")
        if fm.fileExists(atPath: homeBin) { return homeBin }

        // Option 6: Hardcoded project path (development fallback)
        for config in ["release", "debug"] {
            let path = "/Users/jinwoo/work/project/term-mesh/daemon/target/\(config)/term-meshd"
            if fm.fileExists(atPath: path) { return path }
        }

        return nil
    }

    private func parseWorktreeInfo(_ obj: Any?) -> WorktreeInfo? {
        guard let dict = obj as? [String: Any],
              let name = dict["name"] as? String,
              let path = dict["path"] as? String,
              let branch = dict["branch"] as? String else { return nil }
        return WorktreeInfo(name: name, path: path, branch: branch)
    }

    // MARK: - Worktree Cleanup

    /// Remove all stale worktrees (those not bound to any active agent session).
    /// Skips dirty worktrees (uncommitted changes). Returns (removed, skippedDirty).
    func cleanupStaleWorktrees(repoPath: String) -> (removed: Int, skippedDirty: Int) {
        let worktrees = listWorktrees(repoPath: repoPath)
        let activeAgents = listAgents(includeTerminated: false)
        let activePaths = Set(activeAgents.map { $0.worktreePath })

        var removed = 0
        var skippedDirty = 0
        for wt in worktrees {
            if !activePaths.contains(wt.path) {
                let st = worktreeStatus(repoPath: repoPath, name: wt.name)
                if st.dirty {
                    skippedDirty += 1
                    continue
                }
                if removeWorktree(repoPath: repoPath, name: wt.name) {
                    removed += 1
                }
            }
        }
        return (removed, skippedDirty)
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
