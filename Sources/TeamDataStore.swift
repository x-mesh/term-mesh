import Foundation

/// Thread-safe data store for team operations that don't require MainActor access.
/// Handles messages, tasks, heartbeats, and file-based results independently of the UI thread.
/// This is approach C (Dual Queue) for fixing the IME hang caused by v2MainSync contention.
final class TeamDataStore: @unchecked Sendable {
    static let shared = TeamDataStore()

    private let lock = NSLock()

    // Team registry: name → agent names (synced from TeamOrchestrator on create/destroy)
    private var teamRegistry: [String: [String]] = [:]

    struct ContextEntry {
        var key: String
        var value: String
        var setBy: String
        var updatedAt: Date
    }

    // Data collections (previously in TeamOrchestrator, now lock-protected)
    private var messages: [String: [TeamOrchestrator.TeamMessage]] = [:]
    private var taskBoards: [String: [TeamOrchestrator.TeamTask]] = [:]
    private var heartbeats: [String: [String: (at: Date, summary: String?)]] = [:]
    private var contextStore: [String: [String: ContextEntry]] = [:]

    private let staleTaskThreshold: TimeInterval = 10 * 60
    private let staleHeartbeatThreshold: TimeInterval = 5 * 60

    /// Max messages retained per team before oldest are dropped.
    private let maxMessagesPerTeam = 500

    /// Called after data changes to sync state to the daemon (fire-and-forget).
    var onDataChanged: (() -> Void)?

    /// Serial queue for coalescing change notifications to avoid races.
    private let notifyQueue = DispatchQueue(label: "team.data.notify", qos: .utility)
    private var notifyPending = false

    private func notifyChanged() {
        notifyQueue.async { [weak self] in
            guard let self, !self.notifyPending else { return }
            self.notifyPending = true
            self.notifyQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.notifyPending = false
                self?.onDataChanged?()
            }
        }
    }

    // MARK: - Team Registry

    func registerTeam(_ name: String, agentNames: [String]) {
        lock.lock()
        teamRegistry[name] = agentNames
        lock.unlock()
        notifyChanged()
    }

    func unregisterTeam(_ name: String) {
        lock.lock()
        teamRegistry.removeValue(forKey: name)
        messages.removeValue(forKey: name)
        taskBoards.removeValue(forKey: name)
        heartbeats.removeValue(forKey: name)
        contextStore.removeValue(forKey: name)
        lock.unlock()
        notifyChanged()
    }

    func teamExists(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return teamRegistry[name] != nil
    }

    func agentNames(for teamName: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return teamRegistry[teamName] ?? []
    }

    func registeredTeamNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(teamRegistry.keys)
    }

    // MARK: - Messages

    @discardableResult
    func postMessage(teamName: String, from: String, to: String? = nil, content: String, type: String = "report") -> TeamOrchestrator.TeamMessage? {
        lock.lock()
        defer { lock.unlock() }
        guard teamRegistry[teamName] != nil else { return nil }
        let msg = TeamOrchestrator.TeamMessage(
            id: UUID().uuidString,
            from: from,
            to: to,
            teamName: teamName,
            content: content,
            timestamp: Date(),
            type: Self.normalizedMessageType(type)
        )
        messages[teamName, default: []].append(msg)
        // Trim oldest messages if over retention limit
        if let count = messages[teamName]?.count, count > maxMessagesPerTeam {
            messages[teamName]?.removeFirst(count - maxMessagesPerTeam)
        }
        notifyChanged()
        return msg
    }

    func getMessages(teamName: String, from: String? = nil, to: String? = nil, type: String? = nil, since: Date? = nil, limit: Int? = nil) -> [TeamOrchestrator.TeamMessage] {
        lock.lock()
        defer { lock.unlock() }
        guard let msgs = messages[teamName] else { return [] }
        // Single-pass filter to avoid creating intermediate arrays
        let filtered = msgs.filter { msg in
            if let from, msg.from != from { return false }
            if let to, msg.to != to { return false }
            if let type, msg.type != type { return false }
            if let since, msg.timestamp <= since { return false }
            return true
        }
        if let limit { return Array(filtered.suffix(limit)) }
        return filtered
    }

    func clearMessages(teamName: String) {
        lock.lock()
        messages.removeValue(forKey: teamName)
        lock.unlock()
        notifyChanged()
    }

    // MARK: - Tasks

    @discardableResult
    func createTask(
        teamName: String,
        title: String,
        details: String? = nil,
        assignee: String? = nil,
        acceptanceCriteria: [String] = [],
        labels: [String] = [],
        estimatedSize: Int? = nil,
        priority: Int = 2,
        dependsOn: [String] = [],
        parentTaskId: String? = nil,
        createdBy: String = "leader"
    ) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard teamRegistry[teamName] != nil else { return nil }
        let now = Date()
        let normalizedAssignee = assignee?.teamDataNilIfBlank
        let normalizedCreatedBy = createdBy.teamDataNilIfBlank ?? "leader"
        // Dedup dashboard-created tasks
        if normalizedCreatedBy.contains("dashboard"),
           let duplicate = taskBoards[teamName, default: []].last(where: {
               $0.title == title &&
               $0.assignee == normalizedAssignee &&
               $0.createdBy == normalizedCreatedBy &&
               now.timeIntervalSince($0.createdAt) < 5
           }) {
            return duplicate
        }
        let task = TeamOrchestrator.TeamTask(
            id: UUID().uuidString.prefix(8).lowercased().description,
            title: title,
            details: details?.teamDataNilIfBlank,
            acceptanceCriteria: acceptanceCriteria.compactMap(\.teamDataNilIfBlank),
            labels: labels.compactMap(\.teamDataNilIfBlank),
            estimatedSize: estimatedSize,
            assignee: normalizedAssignee,
            status: normalizedAssignee == nil ? "queued" : "assigned",
            priority: max(1, min(priority, 3)),
            dependsOn: dependsOn.compactMap(\.teamDataNilIfBlank),
            parentTaskId: parentTaskId?.teamDataNilIfBlank,
            childTaskIds: [],
            reassignmentCount: 0,
            supersededBy: nil,
            blockedReason: nil,
            reviewSummary: nil,
            createdBy: normalizedCreatedBy,
            result: nil,
            createdAt: now,
            updatedAt: now,
            startedAt: nil,
            completedAt: nil,
            lastProgressAt: nil
        )
        taskBoards[teamName, default: []].append(task)
        if let parentTaskId,
           var tasks = taskBoards[teamName],
           let parentIdx = tasks.firstIndex(where: { $0.id == parentTaskId }) {
            tasks[parentIdx].childTaskIds.append(task.id)
            tasks[parentIdx].updatedAt = now
            taskBoards[teamName] = tasks
        }
        notifyChanged()
        return task
    }

    @discardableResult
    func updateTask(
        teamName: String,
        taskId: String,
        status: String? = nil,
        result: String? = nil,
        resultPath: String? = nil,
        assignee: String? = nil,
        blockedReason: String? = nil,
        reviewSummary: String? = nil,
        progressNote: String? = nil
    ) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let now = Date()
        if let assignee {
            tasks[idx].assignee = assignee.teamDataNilIfBlank
            if tasks[idx].status == "queued", tasks[idx].assignee != nil {
                tasks[idx].status = "assigned"
            }
        }
        if let blockedReason {
            tasks[idx].blockedReason = blockedReason.teamDataNilIfBlank
        }
        if let reviewSummary {
            tasks[idx].reviewSummary = reviewSummary.teamDataNilIfBlank
        }
        if let result { tasks[idx].result = result }
        if let resultPath { tasks[idx].resultPath = resultPath.teamDataNilIfBlank }
        if let progressNote = progressNote?.teamDataNilIfBlank {
            tasks[idx].lastProgressAt = now
            // Post progress message (inline, already holding lock — use messages directly)
            let msg = TeamOrchestrator.TeamMessage(
                id: UUID().uuidString,
                from: tasks[idx].assignee ?? "leader",
                to: nil,
                teamName: teamName,
                content: progressNote,
                timestamp: now,
                type: "progress"
            )
            messages[teamName, default: []].append(msg)
        }
        if let status {
            let normalizedStatus = Self.normalizedTaskStatus(status)
            tasks[idx].status = normalizedStatus
            switch normalizedStatus {
            case "in_progress":
                tasks[idx].startedAt = tasks[idx].startedAt ?? now
                tasks[idx].lastProgressAt = now
                tasks[idx].blockedReason = nil
            case "blocked":
                tasks[idx].lastProgressAt = now
            case "review_ready":
                tasks[idx].lastProgressAt = now
                tasks[idx].blockedReason = nil
            case "completed", "failed", "abandoned":
                tasks[idx].completedAt = now
                tasks[idx].lastProgressAt = now
                if normalizedStatus == "completed" {
                    tasks[idx].blockedReason = nil
                }
            default:
                break
            }
        }
        tasks[idx].updatedAt = now
        taskBoards[teamName] = tasks
        notifyChanged()
        return tasks[idx]
    }

    func getTask(teamName: String, taskId: String) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        return taskBoards[teamName]?.first(where: { $0.id == taskId })
    }

    @discardableResult
    func reassignTask(teamName: String, taskId: String, assignee: String?) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let now = Date()
        let previousAssignee = tasks[idx].assignee
        tasks[idx].assignee = assignee?.teamDataNilIfBlank
        tasks[idx].status = tasks[idx].assignee == nil ? "queued" : "assigned"
        tasks[idx].blockedReason = nil
        tasks[idx].reviewSummary = nil
        tasks[idx].completedAt = nil
        tasks[idx].updatedAt = now
        tasks[idx].lastProgressAt = now
        if previousAssignee != tasks[idx].assignee {
            tasks[idx].reassignmentCount += 1
        }
        taskBoards[teamName] = tasks
        notifyChanged()
        return tasks[idx]
    }

    @discardableResult
    func unblockTask(teamName: String, taskId: String) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let now = Date()
        tasks[idx].blockedReason = nil
        if tasks[idx].status == "blocked" {
            if tasks[idx].startedAt != nil {
                tasks[idx].status = "in_progress"
            } else {
                tasks[idx].status = tasks[idx].assignee == nil ? "queued" : "assigned"
            }
        }
        tasks[idx].updatedAt = now
        tasks[idx].lastProgressAt = now
        taskBoards[teamName] = tasks
        notifyChanged()
        return tasks[idx]
    }

    @discardableResult
    func splitTask(
        teamName: String,
        parentTaskId: String,
        title: String,
        assignee: String? = nil,
        createdBy: String = "leader"
    ) -> TeamOrchestrator.TeamTask? {
        // getTask acquires lock, so do it first
        let parent: TeamOrchestrator.TeamTask?
        lock.lock()
        parent = taskBoards[teamName]?.first(where: { $0.id == parentTaskId })
        lock.unlock()
        guard let parent else { return nil }
        var details = "Split from \(parent.id): \(parent.title)"
        if let parentDetails = parent.details?.teamDataNilIfBlank {
            details += "\n\n\(parentDetails)"
        }
        return createTask(
            teamName: teamName,
            title: title,
            details: details,
            assignee: assignee ?? parent.assignee,
            labels: parent.labels,
            estimatedSize: parent.estimatedSize,
            priority: parent.priority,
            parentTaskId: parent.id,
            createdBy: createdBy
        )
    }

    func listTasks(
        teamName: String,
        status: String? = nil,
        assignee: String? = nil,
        needsAttention: Bool = false,
        priority: Int? = nil,
        staleOnly: Bool = false,
        dependsOn: String? = nil
    ) -> [TeamOrchestrator.TeamTask] {
        lock.lock()
        defer { lock.unlock() }
        guard let tasks = taskBoards[teamName] else { return [] }
        var filtered = tasks
        if let status {
            filtered = filtered.filter { $0.status == Self.normalizedTaskStatus(status) }
        }
        if let assignee { filtered = filtered.filter { $0.assignee == assignee } }
        if needsAttention { filtered = filtered.filter { Self.taskNeedsAttention($0, threshold: staleTaskThreshold) } }
        if let priority { filtered = filtered.filter { $0.priority == priority } }
        if staleOnly { filtered = filtered.filter { Self.isTaskStale($0, threshold: staleTaskThreshold) } }
        if let dependsOn {
            filtered = filtered.filter { $0.dependsOn.contains(dependsOn) }
        }
        return filtered
    }

    func dependentTasks(teamName: String, taskId: String) -> [TeamOrchestrator.TeamTask] {
        lock.lock()
        defer { lock.unlock() }
        return taskBoards[teamName, default: []].filter { $0.dependsOn.contains(taskId) || $0.parentTaskId == taskId }
    }

    func clearTasks(teamName: String) {
        lock.lock()
        taskBoards.removeValue(forKey: teamName)
        lock.unlock()
        notifyChanged()
    }

    // MARK: - Heartbeats

    func postHeartbeat(teamName: String, agentName: String, summary: String?) {
        lock.lock()
        guard teamRegistry[teamName] != nil else { lock.unlock(); return }
        heartbeats[teamName, default: [:]][agentName] = (Date(), summary?.teamDataNilIfBlank)
        lock.unlock()
        notifyChanged()
    }

    func heartbeatInfo(teamName: String, agentName: String) -> (age: Int?, summary: String?, isStale: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = heartbeats[teamName]?[agentName] else {
            return (nil, nil, false)
        }
        let age = Int(Date().timeIntervalSince(entry.at))
        return (age, entry.summary, age >= Int(staleHeartbeatThreshold))
    }

    // MARK: - Agent Status Enrichment (off-main data for team.status)

    /// Returns data-layer enrichment for a given agent, avoiding MainActor.
    /// Includes active task, heartbeat, and runtime state derived from task status.
    func agentDataEnrichment(teamName: String, agentName: String) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        // Active task: most recently updated non-terminal task assigned to this agent
        let terminalStatuses: Set<String> = ["completed", "failed", "abandoned"]
        let activeTask = taskBoards[teamName, default: []]
            .filter { $0.assignee == agentName && !terminalStatuses.contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first

        // Runtime state derived from task status
        let agentState: String
        if let task = activeTask {
            switch task.status {
            case "blocked": agentState = "blocked"
            case "review_ready": agentState = "review_ready"
            case "failed": agentState = "error"
            case "queued", "assigned": agentState = "idle"
            default: agentState = "running"
            }
        } else {
            agentState = "idle"
        }

        // Task staleness
        let isTaskStale: Bool
        if let task = activeTask, !terminalStatuses.contains(task.status) {
            let anchor = task.lastProgressAt ?? task.startedAt ?? task.updatedAt
            isTaskStale = Date().timeIntervalSince(anchor) >= staleTaskThreshold
        } else {
            isTaskStale = false
        }

        // Heartbeat
        let heartbeat = heartbeats[teamName]?[agentName]
        let heartbeatAge: Int? = heartbeat.map { max(0, Int(Date().timeIntervalSince($0.at))) }
        let heartbeatStale = heartbeat.map { Date().timeIntervalSince($0.at) >= staleHeartbeatThreshold } ?? false

        return [
            "agent_state": agentState,
            "active_task_id": activeTask?.id as Any,
            "active_task_title": activeTask?.title as Any,
            "active_task_status": activeTask?.status as Any,
            "active_task_is_stale": isTaskStale,
            "heartbeat_age_seconds": heartbeatAge as Any,
            "last_heartbeat_summary": heartbeat?.summary as Any,
            "heartbeat_is_stale": heartbeatStale,
        ]
    }

    /// Task count for a team (off-main).
    func taskCount(teamName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return taskBoards[teamName, default: []].count
    }

    // MARK: - Context Store

    @discardableResult
    func contextSet(teamName: String, key: String, value: String, setBy: String) -> [String: Any] {
        lock.lock()
        guard teamRegistry[teamName] != nil else {
            lock.unlock()
            return ["ok": false, "error": "team '\(teamName)' is not registered"]
        }
        let entry = ContextEntry(
            key: key,
            value: value,
            setBy: setBy,
            updatedAt: Date()
        )
        contextStore[teamName, default: [:]][key] = entry
        lock.unlock()
        notifyChanged()
        return ["ok": true, "key": key]
    }

    func contextGet(teamName: String, key: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = contextStore[teamName]?[key] else { return nil }
        return [
            "key": entry.key,
            "value": entry.value,
            "set_by": entry.setBy,
            "updated_at": ISO8601DateFormatter().string(from: entry.updatedAt),
        ]
    }

    func contextList(teamName: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return contextStore[teamName, default: [:]].values
            .sorted { $0.key < $1.key }
            .map { entry in
                [
                    "key": entry.key,
                    "value": entry.value,
                    "set_by": entry.setBy,
                    "updated_at": ISO8601DateFormatter().string(from: entry.updatedAt),
                ]
            }
    }

    // MARK: - File-Based Results

    /// Local copy of result directory path (avoids calling @MainActor TeamOrchestrator.resultDirectory)
    private static func resultDirectory(teamName: String) -> String {
        "/tmp/term-mesh-team-\(teamName)"
    }

    func writeResult(teamName: String, agentName: String, content: String) -> Bool {
        let dir = Self.resultDirectory(teamName: teamName)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(agentName).result.json")
        let payload: [String: Any] = [
            "agent": agentName,
            "content": content,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return false
        }
        return FileManager.default.createFile(atPath: path, contents: data)
    }

    func readResult(teamName: String, agentName: String) -> [String: Any]? {
        let dir = Self.resultDirectory(teamName: teamName)
        let path = (dir as NSString).appendingPathComponent("\(agentName).result.json")
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    func resultStatus(teamName: String) -> [String: Any] {
        let agents = agentNames(for: teamName)
        guard !agents.isEmpty else { return [:] }
        let dir = Self.resultDirectory(teamName: teamName)
        var agentStatus: [[String: Any]] = []
        for name in agents {
            let path = (dir as NSString).appendingPathComponent("\(name).result.json")
            agentStatus.append([
                "agent_name": name,
                "has_result": FileManager.default.fileExists(atPath: path),
            ])
        }
        let completed = agentStatus.filter { $0["has_result"] as? Bool == true }.count
        return [
            "team_name": teamName,
            "agents": agentStatus,
            "completed": completed,
            "total": agents.count,
            "all_done": completed == agents.count,
        ]
    }

    func collectResults(teamName: String) -> [[String: Any]] {
        let agents = agentNames(for: teamName)
        return agents.compactMap { readResult(teamName: teamName, agentName: $0) }
    }

    // MARK: - Task Dictionary (for JSON responses)

    func taskDictionary(_ task: TeamOrchestrator.TeamTask) -> [String: Any] {
        var dict: [String: Any] = [
            "id": task.id,
            "title": task.title,
            "description": task.details as Any,
            "acceptance_criteria": task.acceptanceCriteria,
            "labels": task.labels,
            "estimated_size": task.estimatedSize as Any,
            "status": task.status,
            "priority": task.priority,
            "depends_on": task.dependsOn,
            "parent_task_id": task.parentTaskId as Any,
            "child_task_ids": task.childTaskIds,
            "reassignment_count": task.reassignmentCount,
            "superseded_by": task.supersededBy as Any,
            "assignee": task.assignee as Any,
            "blocked_reason": task.blockedReason as Any,
            "review_summary": task.reviewSummary as Any,
            "created_by": task.createdBy,
            "result": task.result as Any,
            "result_path": task.resultPath as Any,
            "created_at": ISO8601DateFormatter().string(from: task.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: task.updatedAt),
            "needs_attention": Self.taskNeedsAttention(task, threshold: staleTaskThreshold),
            "is_stale": Self.isTaskStale(task, threshold: staleTaskThreshold),
        ]
        if let startedAt = task.startedAt {
            dict["started_at"] = ISO8601DateFormatter().string(from: startedAt)
        }
        if let completedAt = task.completedAt {
            dict["completed_at"] = ISO8601DateFormatter().string(from: completedAt)
        }
        if let lastProgressAt = task.lastProgressAt {
            dict["last_progress_at"] = ISO8601DateFormatter().string(from: lastProgressAt)
        }
        if let stale = Self.staleAgeSeconds(for: task, threshold: staleTaskThreshold) {
            dict["stale_seconds"] = stale
        } else {
            dict["stale_seconds"] = NSNull()
        }
        return dict
    }

    func messageDictionary(_ message: TeamOrchestrator.TeamMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "id": message.id,
            "from": message.from,
            "type": message.type,
            "content": message.content,
            "timestamp": ISO8601DateFormatter().string(from: message.timestamp),
        ]
        if let to = message.to {
            dict["to"] = to
        }
        return dict
    }

    // MARK: - Inbox (off-main alternative to TeamOrchestrator.inboxItems)

    func inboxItems(teamName: String, topOnly: Bool = false) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        guard teamRegistry[teamName] != nil else { return [] }
        let now = Date()
        var items: [[String: Any]] = []

        for task in taskBoards[teamName, default: []] {
            let staleSeconds = Self.staleAgeSeconds(for: task, threshold: staleTaskThreshold)
            let attention: (Int, String)?
            switch task.status {
            case "blocked":
                attention = (1, task.blockedReason ?? "Blocked")
            case "review_ready":
                attention = (2, task.reviewSummary ?? "Ready for review")
            case "failed":
                attention = (3, task.result ?? "Task failed")
            default:
                if let staleSeconds {
                    attention = (4, "Stale for \(staleSeconds)s")
                } else if task.status == "completed" {
                    attention = (5, task.result ?? "Completed")
                } else {
                    attention = nil
                }
            }
            guard let attention else { continue }
            items.append([
                "kind": "task",
                "priority": attention.0,
                "team_name": teamName,
                "task_id": task.id,
                "agent_name": task.assignee as Any,
                "reason": attention.1,
                "age_seconds": Int(now.timeIntervalSince(task.updatedAt)),
                "summary": task.title,
                "task_title": task.title,
                "result": task.result as Any,
                "review_summary": task.reviewSummary as Any,
                "status": task.status,
                "is_stale": staleSeconds != nil,
                "stale_seconds": staleSeconds as Any
            ])
        }

        for message in messages[teamName, default: []] {
            let priority: Int?
            switch message.type {
            case "blocked":
                priority = 1
            case "review_ready":
                priority = 2
            case "error":
                priority = 3
            default:
                priority = nil
            }
            guard let priority else { continue }
            items.append([
                "kind": "message",
                "priority": priority,
                "team_name": teamName,
                "from": message.from,
                "reason": message.content,
                "age_seconds": Int(now.timeIntervalSince(message.timestamp)),
                "summary": String(message.content.prefix(120)),
                "message_type": message.type
            ])
        }

        if topOnly {
            // O(n) min scan instead of O(n log n) sort for single item
            if let best = items.min(by: { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }) {
                return [best]
            }
            return []
        }
        items.sort { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
        return items
    }

    // MARK: - Static Helpers (no instance state needed)

    static func normalizedMessageType(_ type: String) -> String {
        switch type.lowercased() {
        case "note", "progress", "blocked", "review_ready", "error", "report":
            return type.lowercased()
        case "complete":
            return "report"
        default:
            return "note"
        }
    }

    static func normalizedTaskStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "pending":
            return "queued"
        case "done":
            return "completed"
        case "review":
            return "review_ready"
        case "queued", "assigned", "in_progress", "blocked", "review_ready", "completed", "failed", "abandoned":
            return status.lowercased()
        default:
            return status.lowercased()
        }
    }

    static func taskNeedsAttention(_ task: TeamOrchestrator.TeamTask, threshold: TimeInterval) -> Bool {
        ["blocked", "review_ready", "failed"].contains(task.status) || isTaskStale(task, threshold: threshold)
    }

    static func isTaskStale(_ task: TeamOrchestrator.TeamTask, threshold: TimeInterval) -> Bool {
        staleAgeSeconds(for: task, threshold: threshold) != nil
    }

    static func staleAgeSeconds(for task: TeamOrchestrator.TeamTask, threshold: TimeInterval) -> Int? {
        guard !["completed", "failed", "abandoned"].contains(task.status) else { return nil }
        let anchor = task.lastProgressAt ?? task.startedAt ?? task.updatedAt
        let age = Int(Date().timeIntervalSince(anchor))
        return age >= Int(threshold) ? age : nil
    }
}

// MARK: - String extension (avoids dependency on TeamOrchestrator's private extension)

extension String {
    var teamDataNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
