import Foundation
import Combine
import os

/// Phase 2.5 — per-agent token usage snapshot, mirrored from the daemon's
/// `agent.usage_tick` notify pushes. Values are absolute totals (the daemon is
/// expected to coalesce at ~1Hz before sending). The Swift side simply replaces
/// the entry whenever a fresher snapshot arrives.
struct AgentUsageSnapshot: Equatable {
    var inputTokens: UInt64
    var outputTokens: UInt64
    var cacheReadTokens: UInt64
    var cacheCreationTokens: UInt64
    var updatedAt: Date

    static let empty = AgentUsageSnapshot(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        updatedAt: .distantPast
    )

    /// Cache-hit ratio: cacheRead / (cacheRead + cacheCreation). Nil when both are zero.
    var cacheHitRatio: Double? {
        let denom = cacheReadTokens &+ cacheCreationTokens
        guard denom > 0 else { return nil }
        return Double(cacheReadTokens) / Double(denom)
    }
}

/// Thread-safe data store for team operations that don't require MainActor access.
/// Handles messages, tasks, heartbeats, and file-based results independently of the UI thread.
/// This is approach C (Dual Queue) for fixing the IME hang caused by v2MainSync contention.
final class TeamDataStore: ObservableObject, @unchecked Sendable {
    static let shared = TeamDataStore()

    private let lock = NSLock()

    /// Phase 2.5 — published per-team / per-agent usage map. Updated from
    /// `updateUsage(teamName:agents:)` which the daemon notify handler calls.
    /// Observers should `.objectWillChange` via the data store, and read this
    /// map under the assumption it changes on the main thread.
    @Published var agentUsage: [String: [String: AgentUsageSnapshot]] = [:]

    /// Bumped whenever a team's task board changes. The board views read the
    /// tasks through `listTasks`, which is lock-guarded and therefore cannot
    /// be `@Published` itself; this is the change signal they subscribe to.
    /// Without it a task could be created, assigned and finished while every
    /// view of the task board sat exactly as it was at launch.
    @Published private(set) var taskRevision: Int = 0

    /// Safe to call with the store's lock held: the bump is dispatched.
    func noteTasksChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.taskRevision &+= 1
        }
    }

    struct AgentRegistration: Equatable {
        let name: String
        let instanceId: String?
    }

    // Team registry: name → agents. `name` is a legacy routing alias; result
    // ownership uses the durable per-pane instance id whenever it is known.
    private var teamRegistry: [String: [AgentRegistration]] = [:]

    /// The one gate `writeResult` and `AutoReplyEmit.emit` both call before
    /// attributing a report to a task, so the two paths cannot drift apart
    /// on what counts as a match.
    ///
    /// A task that tracked a real instance (any duplicate-role assignment)
    /// must match it exactly — that is what tells siblings apart, and a
    /// `nil` report against it is a miss, not a pass. A task that tracked
    /// none is the legacy/unique-name case, and a `nil` report only clears
    /// it when the registry currently shows exactly one agent under that
    /// name: two duplicates both missing an instance id would be
    /// indistinguishable from each other, so that is refused rather than
    /// guessed at.
    func agentIdentityMatches(
        teamName: String, agentName: String,
        expectedInstanceId: String?, reportedInstanceId: String?
    ) -> Bool {
        if let expectedInstanceId {
            return expectedInstanceId == reportedInstanceId
        }
        guard reportedInstanceId == nil else { return false }
        lock.lock()
        let count = teamRegistry[teamName]?.filter { $0.name == agentName }.count ?? 0
        lock.unlock()
        return count == 1
    }

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
    /// Phase 2 idle-park: per-team / per-agent flag mirrored from daemon
    /// (`agents/<name>.json:parked`). Set via `setAgentParked` whenever the
    /// daemon emits a parked-state update.
    private var parkedAgents: [String: Set<String>] = [:]
    /// Busy identity is instance-first. A legacy name entry remains supported
    /// for callers that cannot yet identify their pane, but never collapses
    /// instance-specific callers into the same pool member.
    private var busyAgents: [String: Set<String>] = [:]

    /// Watch drift finding in the leader inbox. Deduped by checkId; idempotent on post.
    struct WatchDriftItem {
        let checkId: String
        let target: String
        let driftKind: String        // "execution" | "direction"
        let severity: String         // "high" | "medium" | "low"
        let finding: String
        let specClause: String
        let timestamp: Date
    }

    /// Per-team watch drift items, keyed by checkId for deduplication.
    private var watchDrifts: [String: [String: WatchDriftItem]] = [:]

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
        // Restore Fleet Layer 2: every data change also refreshes the on-disk
        // board snapshots (own debounce + content dedup inside).
        scheduleBoardSave()
    }

    // MARK: - Team Registry

    func registerTeam(_ name: String, agentNames: [String]) {
        registerTeam(name, agents: agentNames.map { AgentRegistration(name: $0, instanceId: nil) })
    }

    func registerTeam(_ name: String, agents: [AgentRegistration]) {
        lock.lock()
        teamRegistry[name] = agents
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
        parkedAgents.removeValue(forKey: name)
        watchDrifts.removeValue(forKey: name)
        let boardUuid = boardUuids.removeValue(forKey: name)
        lock.unlock()
        clearUsageUnsafe(teamName: name)
        // Deliberate destroy → the persisted board is no longer restorable
        // state; remove it. Crash/quit paths never unregister, so their board
        // files survive for Restore Fleet.
        if let boardUuid {
            removeBoardFile(teamUuid: boardUuid)
        }
        notifyChanged()
    }

    // MARK: - Restore Fleet Layer 2: board persistence
    //
    // Task boards (and the shared context store) used to be in-memory only —
    // an app crash or restart lost every task, breaking `tm-agent recycle`'s
    // "durable state remains in the task board" contract at the restart
    // boundary. Every data change now debounces a JSON snapshot to
    // `~/.term-mesh/teams/<team_uuid>/board.json` (atomic write, content
    // deduped). See docs/design/restore-fleet-session-persistence.md §3.2.
    //
    // Inter-agent messages are deliberately NOT persisted: the leader inbox is
    // re-synthesized from task state (`inboxItems`), so tasks are the durable
    // record. Heartbeats/usage are ephemeral or daemon-owned.

    struct PersistedContextEntry: Codable {
        var value: String
        var setBy: String
        var updatedAt: Date
    }

    struct PersistedBoard: Codable {
        var schema: Int
        var teamUuid: String
        var teamName: String
        var savedAt: Date
        var tasks: [TeamOrchestrator.TeamTask]
        var context: [String: PersistedContextEntry]
    }

    /// Dedup payload — everything in `PersistedBoard` except `savedAt`, so an
    /// unchanged board doesn't rewrite the file on every debounce tick.
    private struct BoardContent: Codable {
        var tasks: [TeamOrchestrator.TeamTask]
        var context: [String: PersistedContextEntry]
    }

    static let boardSchemaVersion = 1

    /// Serial queue owning all board file IO plus `boardSavePending` /
    /// `lastBoardContentBytes` below.
    private let boardIOQueue = DispatchQueue(label: "team.board.persist", qos: .utility)
    private var boardSavePending = false
    private var lastBoardContentBytes: [String: Data] = [:]

    /// team_name → team_uuid. Refreshed by `TeamOrchestrator` on every state
    /// sync (uuid is the on-disk identity; teams without one predate D3-A
    /// P1-A and are not persisted). Guarded by `lock`.
    private var boardUuids: [String: String] = [:]

    static func boardsRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["TERMMESH_TEAMS_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".term-mesh", isDirectory: true)
            .appendingPathComponent("teams", isDirectory: true)
    }

    static func boardFileURL(teamUuid: String) -> URL {
        boardsRoot()
            .appendingPathComponent(teamUuid, isDirectory: true)
            .appendingPathComponent("board.json", isDirectory: false)
    }

    /// Refresh the name→uuid map (merge; uuids are stable for a team's life).
    func updateBoardUuids(_ map: [String: String]) {
        lock.lock()
        boardUuids.merge(map) { _, new in new }
        lock.unlock()
    }

    /// Debounced save of every known team board. Cheap to call on any change.
    private func scheduleBoardSave() {
        boardIOQueue.async { [weak self] in
            guard let self, !self.boardSavePending else { return }
            self.boardSavePending = true
            self.boardIOQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.boardSavePending = false
                self.saveAllBoardsNow()
            }
        }
    }

    /// boardIOQueue only.
    private func saveAllBoardsNow() {
        lock.lock()
        let uuids = boardUuids
        let boards = taskBoards
        let contexts = contextStore
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        for (teamName, teamUuid) in uuids {
            let tasks = boards[teamName] ?? []
            let context = (contexts[teamName] ?? [:]).mapValues {
                PersistedContextEntry(value: $0.value, setBy: $0.setBy, updatedAt: $0.updatedAt)
            }
            guard let contentBytes = try? encoder.encode(BoardContent(tasks: tasks, context: context))
            else { continue }
            if lastBoardContentBytes[teamUuid] == contentBytes { continue }

            let board = PersistedBoard(
                schema: Self.boardSchemaVersion,
                teamUuid: teamUuid,
                teamName: teamName,
                savedAt: Date(),
                tasks: tasks,
                context: context
            )
            do {
                let url = Self.boardFileURL(teamUuid: teamUuid)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let data = try encoder.encode(board)
                try data.write(to: url, options: .atomic)
                lastBoardContentBytes[teamUuid] = contentBytes
            } catch {
                Logger.team.warning(
                    "[board.persist] save failed team=\(teamName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Load a persisted board into memory for a resumed/restored team,
    /// replacing that team's in-memory board. Normalization: `in_progress`
    /// tasks become `assigned` — the worker process died with the app, so
    /// nothing is genuinely in progress; the existing dispatch/auto-claim
    /// machinery re-drives them. All other statuses (blocked / review_ready /
    /// completed / failed) carry over verbatim, including worktree fields
    /// (worktrees are real dirs on disk and stay finishable).
    ///
    /// Returns the number of restored tasks (0 when no/invalid board file).
    @discardableResult
    func loadBoard(teamName: String, teamUuid: String) -> Int {
        let url = Self.boardFileURL(teamUuid: teamUuid)
        guard let data = try? Data(contentsOf: url) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let board = try? decoder.decode(PersistedBoard.self, from: data),
              board.schema == Self.boardSchemaVersion,
              board.teamUuid == teamUuid else {
            Logger.team.warning(
                "[board.persist] load skipped team=\(teamName, privacy: .public): schema/uuid mismatch or corrupt file"
            )
            return 0
        }

        var restored = board.tasks
        let now = Date()
        for i in restored.indices where restored[i].status == "in_progress" {
            restored[i].status = "assigned"
            restored[i].updatedAt = now
        }
        let context = board.context.reduce(into: [String: ContextEntry]()) { acc, kv in
            acc[kv.key] = ContextEntry(
                key: kv.key, value: kv.value.value, setBy: kv.value.setBy,
                updatedAt: kv.value.updatedAt
            )
        }

        lock.lock()
        taskBoards[teamName] = restored
        noteTasksChanged()
        if !context.isEmpty {
            contextStore[teamName] = context
        }
        boardUuids[teamName] = teamUuid
        lock.unlock()
        notifyChanged()
        Logger.team.info(
            "[board.persist] restored \(restored.count) task(s) for team=\(teamName, privacy: .public)"
        )
        return restored.count
    }

    /// Remove a board file after a deliberate destroy.
    private func removeBoardFile(teamUuid: String) {
        boardIOQueue.async { [weak self] in
            self?.lastBoardContentBytes[teamUuid] = nil
            let dir = Self.boardFileURL(teamUuid: teamUuid).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Parked agent state (Phase 2)

    /// Update the parked flag for an agent. Called by TeamOrchestrator when
    /// the daemon emits a state update with `agent_state == "parked"`.
    func setAgentParked(teamName: String, agentName: String, parked: Bool) {
        lock.lock()
        var changed = false
        if parked {
            if parkedAgents[teamName, default: []].insert(agentName).inserted {
                changed = true
            }
        } else if parkedAgents[teamName]?.remove(agentName) != nil {
            changed = true
            if parkedAgents[teamName]?.isEmpty == true {
                parkedAgents.removeValue(forKey: teamName)
            }
        }
        lock.unlock()
        if changed { notifyChanged() }
    }

    // MARK: - Turn in flight

    /// Agents with a turn actually running, published by the app.
    ///
    /// Every other state here is derived from the task board, and a broadcast
    /// creates no task — so a whole team mid-answer read as `idle` and "has
    /// everyone replied?" had no way to be asked. A natively-held agent knows
    /// the real answer, but it knows it on the main actor, and `team.status` is
    /// served off it. So the app pushes the fact here, where an off-main reader
    /// can see it.
    func setAgentBusy(
        teamName: String,
        agentName: String,
        agentInstanceId: String? = nil,
        busy: Bool
    ) {
        lock.lock()
        let key = agentInstanceId?.teamDataNilIfBlank ?? agentName
        let had = busyAgents[teamName]?.contains(key) ?? false
        if busy { busyAgents[teamName, default: []].insert(key) }
        else { busyAgents[teamName]?.remove(key) }
        let changed = had != busy
        lock.unlock()
        if changed { notifyChanged() }
    }

    func clearBusyAgents(teamName: String) {
        lock.lock()
        let changed = busyAgents.removeValue(forKey: teamName) != nil
        lock.unlock()
        if changed { notifyChanged() }
    }

    private func isAgentBusyUnsafe(teamName: String, agentName: String, agentInstanceId: String? = nil) -> Bool {
        let busy = busyAgents[teamName] ?? []
        // Name-only reports predate per-pane identity and must remain
        // conservative. An instance-specific report only blocks that pane.
        return busy.contains(agentName) || agentInstanceId.map(busy.contains) == true
    }

    func isAgentBusy(teamName: String, agentName: String, agentInstanceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let busy = busyAgents[teamName] ?? []
        // A legacy name-only busy report is conservative: it still blocks the
        // pool until that caller upgrades to an instance id.
        return busy.contains(agentInstanceId) || busy.contains(agentName)
    }

    func hasActiveTask(teamName: String, agentInstanceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let terminal: Set<String> = ["completed", "failed", "abandoned", "cancelled"]
        return taskBoards[teamName, default: []].contains {
            $0.assigneeInstanceId == agentInstanceId && !terminal.contains($0.status)
        }
    }

    /// Public, lock-acquiring query for callers outside the data store.
    func isAgentParked(teamName: String, agentName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parkedAgents[teamName]?.contains(agentName) ?? false
    }

    /// Internal query for callers that already hold `lock`.
    private func isAgentParkedUnsafe(teamName: String, agentName: String) -> Bool {
        return parkedAgents[teamName]?.contains(agentName) ?? false
    }

    // MARK: - Agent Usage (Phase 2.5)

    /// Replace usage snapshots for one team. Each `(name, snapshot)` overrides
    /// the existing entry; agents absent from the payload are left untouched
    /// (the daemon emits per-agent tick events, so partial updates are normal).
    /// MUST be called on the main thread — `agentUsage` is `@Published`.
    func updateUsage(teamName: String, agents: [(name: String, snapshot: AgentUsageSnapshot)]) {
        var bucket = agentUsage[teamName] ?? [:]
        for entry in agents {
            bucket[entry.name] = entry.snapshot
        }
        agentUsage[teamName] = bucket
    }

    /// Convenience accessor — returns `.empty` placeholder snapshot when no
    /// data has arrived yet. Callers can check `updatedAt == .distantPast`
    /// to render an em-dash.
    func usage(teamName: String, agentName: String) -> AgentUsageSnapshot? {
        agentUsage[teamName]?[agentName]
    }

    /// Drop all usage data for a team (called from `unregisterTeam`).
    private func clearUsageUnsafe(teamName: String) {
        // We can't mutate @Published from off-main, so dispatch.
        DispatchQueue.main.async { [weak self] in
            self?.agentUsage.removeValue(forKey: teamName)
        }
    }

    func teamExists(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return teamRegistry[name] != nil
    }

    func agentNames(for teamName: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (teamRegistry[teamName] ?? []).map(\.name)
    }

    func agentInstanceId(teamName: String, agentName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return teamRegistry[teamName]?.first(where: { $0.name == agentName })?.instanceId
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

    /// Resolve a task assignment without guessing between duplicate agent names.
    /// Caller must hold `lock`.
    private func resolveAssigneeUnsafe(
        teamName: String,
        assignee: String?,
        assigneeInstanceId: String?,
        allowNameOnlyAutoPin: Bool = false
    ) -> (assignee: String?, instanceId: String?)? {
        let normalizedAssignee = assignee?.teamDataNilIfBlank
        let normalizedInstanceId = assigneeInstanceId?.teamDataNilIfBlank
        guard let normalizedAssignee else {
            return normalizedInstanceId == nil ? (nil, nil) : nil
        }
        let candidates = teamRegistry[teamName, default: []].filter { $0.name == normalizedAssignee }
        if let normalizedInstanceId {
            guard candidates.contains(where: { $0.instanceId == normalizedInstanceId }) else { return nil }
            return (normalizedAssignee, normalizedInstanceId)
        }
        if allowNameOnlyAutoPin {
            return (normalizedAssignee, candidates.first?.instanceId)
        }
        guard candidates.count == 1 else { return nil }
        return (normalizedAssignee, candidates[0].instanceId)
    }

    @discardableResult
    func createTask(
        teamName: String,
        title: String,
        details: String? = nil,
        assignee: String? = nil,
        assigneeInstanceId: String? = nil,
        acceptanceCriteria: [String] = [],
        labels: [String] = [],
        estimatedSize: Int? = nil,
        priority: Int = 2,
        dependsOn: [String] = [],
        parentTaskId: String? = nil,
        createdBy: String = "leader",
        worktreePolicy: String? = nil
    ) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard teamRegistry[teamName] != nil else { return nil }
        guard let resolvedAssignee = resolveAssigneeUnsafe(
            teamName: teamName,
            assignee: assignee,
            assigneeInstanceId: assigneeInstanceId,
            allowNameOnlyAutoPin: true
        ) else { return nil }
        let now = Date()
        let normalizedCreatedBy = createdBy.teamDataNilIfBlank ?? "leader"
        // Dedup dashboard-created tasks
        if normalizedCreatedBy.contains("dashboard"),
           let duplicate = taskBoards[teamName, default: []].last(where: {
               $0.title == title &&
               $0.assignee == resolvedAssignee.assignee &&
               $0.assigneeInstanceId == resolvedAssignee.instanceId &&
               $0.createdBy == normalizedCreatedBy &&
               now.timeIntervalSince($0.createdAt) < 5
           }) {
            return duplicate
        }
        // Generate ID early so it can be used in dependency validation below.
        let taskId = UUID().uuidString.prefix(8).lowercased().description
        let existingIds = Set((taskBoards[teamName] ?? []).map(\.id))
        // Validate dependsOn: strip blanks, remove self-references and unknown IDs.
        var validatedDependsOn: [String] = []
        for depId in dependsOn.compactMap(\.teamDataNilIfBlank) {
            if depId == taskId {
                NSLog("[TeamDataStore] createTask: skipping self-reference dep '%@' for task '%@'", depId, taskId)
                continue
            }
            guard existingIds.contains(depId) else {
                NSLog("[TeamDataStore] createTask: WARNING dep '%@' not found in team '%@', removing", depId, teamName)
                continue
            }
            validatedDependsOn.append(depId)
        }

        let task = TeamOrchestrator.TeamTask(
            id: taskId,
            title: title,
            details: details?.teamDataNilIfBlank,
            acceptanceCriteria: acceptanceCriteria.compactMap(\.teamDataNilIfBlank),
            labels: labels.compactMap(\.teamDataNilIfBlank),
            estimatedSize: estimatedSize,
            assignee: resolvedAssignee.assignee,
            assigneeInstanceId: resolvedAssignee.instanceId,
            status: resolvedAssignee.assignee == nil ? "queued" : "assigned",
            priority: max(1, min(priority, 3)),
            dependsOn: validatedDependsOn,
            parentTaskId: parentTaskId?.teamDataNilIfBlank,
            childTaskIds: [],
            reassignmentCount: 0,
            supersededBy: nil,
            blockedReason: nil,
            reviewSummary: nil,
            createdBy: normalizedCreatedBy,
            result: nil,
            resultPath: nil,
            worktreePolicy: worktreePolicy?.teamDataNilIfBlank,
            createdAt: now,
            updatedAt: now,
            startedAt: nil,
            completedAt: nil,
            lastProgressAt: nil
        )
        taskBoards[teamName, default: []].append(task)
        noteTasksChanged()
        if let parentTaskId,
           var tasks = taskBoards[teamName],
           let parentIdx = tasks.firstIndex(where: { $0.id == parentTaskId }) {
            tasks[parentIdx].childTaskIds.append(task.id)
            tasks[parentIdx].updatedAt = now
            taskBoards[teamName] = tasks
            noteTasksChanged()
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
        assigneeInstanceId: String? = nil,
        blockedReason: String? = nil,
        reviewSummary: String? = nil,
        progressNote: String? = nil,
        worktreePolicy: String? = nil,
        worktreePath: String? = nil,
        worktreeBranch: String? = nil,
        worktreeParent: String? = nil,
        worktreeCreated: Bool? = nil,
        worktreeReused: Bool? = nil,
        worktreeInit: String? = nil,
        worktreeFinishedAt: Date? = nil,
        worktreeFinishMode: String? = nil,
        worktreeRemoved: Bool? = nil
    ) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let now = Date()
        if let assignee {
            guard let resolvedAssignee = resolveAssigneeUnsafe(
                teamName: teamName,
                assignee: assignee,
                assigneeInstanceId: assigneeInstanceId
            ) else { return nil }
            tasks[idx].assignee = resolvedAssignee.assignee
            tasks[idx].assigneeInstanceId = resolvedAssignee.instanceId
            if tasks[idx].status == "queued", tasks[idx].assignee != nil {
                tasks[idx].status = "assigned"
            }
        } else if let assigneeInstanceId = assigneeInstanceId?.teamDataNilIfBlank {
            guard tasks[idx].assigneeInstanceId == assigneeInstanceId else { return nil }
        }
        if let blockedReason {
            tasks[idx].blockedReason = blockedReason.teamDataNilIfBlank
        }
        if let reviewSummary {
            tasks[idx].reviewSummary = reviewSummary.teamDataNilIfBlank
        }
        if let result { tasks[idx].result = result }
        if let resultPath { tasks[idx].resultPath = resultPath.teamDataNilIfBlank }
        if let worktreePolicy { tasks[idx].worktreePolicy = worktreePolicy.teamDataNilIfBlank }
        if let worktreePath { tasks[idx].worktreePath = worktreePath.teamDataNilIfBlank }
        if let worktreeBranch { tasks[idx].worktreeBranch = worktreeBranch.teamDataNilIfBlank }
        if let worktreeParent { tasks[idx].worktreeParent = worktreeParent.teamDataNilIfBlank }
        if let worktreeCreated { tasks[idx].worktreeCreated = worktreeCreated }
        if let worktreeReused { tasks[idx].worktreeReused = worktreeReused }
        if let worktreeInit { tasks[idx].worktreeInit = worktreeInit.teamDataNilIfBlank }
        if let worktreeFinishedAt { tasks[idx].worktreeFinishedAt = worktreeFinishedAt }
        if let worktreeFinishMode { tasks[idx].worktreeFinishMode = worktreeFinishMode.teamDataNilIfBlank }
        if let worktreeRemoved { tasks[idx].worktreeRemoved = worktreeRemoved }
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
            case "completed", "failed", "abandoned", "cancelled":
                // Phase E Wave 1: include "cancelled" so daemon-driven auto
                // transitions stamp completedAt and let `activeTask` filter
                // (terminalStatuses) drop the row — keeps sidebar's
                // active_task_id in sync without a per-agent cache.
                tasks[idx].completedAt = now
                tasks[idx].lastProgressAt = now
                if normalizedStatus == "completed" {
                    tasks[idx].blockedReason = nil
                    // Log dependent tasks that may now be ready to start.
                    let dependents = tasks.filter { $0.dependsOn.contains(taskId) }
                    if !dependents.isEmpty {
                        let depIds = dependents.map(\.id).joined(separator: ", ")
                        NSLog("[TeamDataStore] task '%@' completed: %d dependent task(s) may be unblocked: %@", taskId, dependents.count, depIds)
                    }
                }
            default:
                break
            }
        }
        tasks[idx].updatedAt = now
        taskBoards[teamName] = tasks
        noteTasksChanged()
        notifyChanged()
        return tasks[idx]
    }

    func getTask(teamName: String, taskId: String) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        return taskBoards[teamName]?.first(where: { $0.id == taskId })
    }

    @discardableResult
    func reassignTask(
        teamName: String,
        taskId: String,
        assignee: String?,
        assigneeInstanceId: String? = nil
    ) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        guard let resolvedAssignee = resolveAssigneeUnsafe(
            teamName: teamName,
            assignee: assignee,
            assigneeInstanceId: assigneeInstanceId
        ) else { return nil }
        let now = Date()
        let previousAssignee = tasks[idx].assignee
        let previousAssigneeInstanceId = tasks[idx].assigneeInstanceId
        tasks[idx].assignee = resolvedAssignee.assignee
        tasks[idx].assigneeInstanceId = resolvedAssignee.instanceId
        tasks[idx].status = tasks[idx].assignee == nil ? "queued" : "assigned"
        tasks[idx].blockedReason = nil
        tasks[idx].reviewSummary = nil
        tasks[idx].completedAt = nil
        tasks[idx].updatedAt = now
        tasks[idx].lastProgressAt = now
        if previousAssignee != tasks[idx].assignee
            || previousAssigneeInstanceId != tasks[idx].assigneeInstanceId {
            tasks[idx].reassignmentCount += 1
        }
        taskBoards[teamName] = tasks
        noteTasksChanged()
        notifyChanged()
        return tasks[idx]
    }

    /// True when every task `task` dependsOn has reached the `completed` state.
    /// A failed / abandoned / cancelled dependency does NOT release the dependent
    /// (its input never arrived) — the leader must intervene. A dep id no longer
    /// on the board is treated as satisfied (long-completed / pruned), so a
    /// pruned dependency can never deadlock the pool. `tasks` is the caller's
    /// live snapshot (caller holds `lock`).
    private func dependenciesSatisfied(
        _ task: TeamOrchestrator.TeamTask,
        in tasks: [TeamOrchestrator.TeamTask]
    ) -> Bool {
        for depId in task.dependsOn {
            guard let dep = tasks.first(where: { $0.id == depId }) else { continue }
            if dep.status != "completed" { return false }
        }
        return true
    }

    /// Work-stealing: atomically find the highest-priority pending/unassigned task
    /// whose dependencies are all completed and assign it to the given agent
    /// (status → assigned). Returns nil if no claimable task exists.
    @discardableResult
    func claimTask(
        teamName: String,
        agentName: String,
        agentInstanceId: String? = nil
    ) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard var tasks = taskBoards[teamName] else { return nil }
        let resolvedInstanceId: String?
        if let agentInstanceId = agentInstanceId?.teamDataNilIfBlank {
            guard teamRegistry[teamName]?.contains(where: {
                $0.name == agentName && $0.instanceId == agentInstanceId
            }) == true,
            !isAgentBusyUnsafe(teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId),
            !tasks.contains(where: {
                $0.assigneeInstanceId == agentInstanceId
                    && !["completed", "failed", "abandoned", "cancelled"].contains($0.status)
            }) else { return nil }
            resolvedInstanceId = agentInstanceId
        } else {
            // Legacy callers must not mutate an arbitrary duplicate role.
            let candidates = teamRegistry[teamName, default: []].filter { $0.name == agentName }
            guard candidates.count == 1,
                  !isAgentBusyUnsafe(teamName: teamName, agentName: agentName) else { return nil }
            resolvedInstanceId = candidates[0].instanceId
        }
        // Find pending tasks with no assignee AND satisfied dependencies, sorted
        // by priority descending then createdAt ascending. The dependency gate
        // keeps an autonomous claim loop from pulling a task whose inputs aren't
        // ready yet (dependents are only logged, never auto-unblocked, on
        // completion — see updateTask).
        guard let idx = tasks.indices.filter({
            (tasks[$0].status == "pending" || tasks[$0].status == "queued")
                && tasks[$0].assignee == nil
                && dependenciesSatisfied(tasks[$0], in: tasks)
        }).sorted(by: { a, b in
            if tasks[a].priority != tasks[b].priority { return tasks[a].priority > tasks[b].priority }
            return tasks[a].createdAt < tasks[b].createdAt
        }).first else { return nil }
        let now = Date()
        tasks[idx].assignee = agentName
        tasks[idx].assigneeInstanceId = resolvedInstanceId
        tasks[idx].status = "assigned"
        tasks[idx].updatedAt = now
        tasks[idx].lastProgressAt = now
        taskBoards[teamName] = tasks
        noteTasksChanged()
        notifyChanged()
        return tasks[idx]
    }

    /// Undo a claim only while the same instance still owns it. A late paste
    /// acknowledgement must never unassign work that was subsequently rerouted.
    @discardableResult
    func releaseClaim(teamName: String, taskId: String, assigneeInstanceId: String) -> TeamOrchestrator.TeamTask? {
        lock.lock()
        defer { lock.unlock() }
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].assigneeInstanceId == assigneeInstanceId,
              ["assigned", "in_progress"].contains(tasks[idx].status) else { return nil }
        let now = Date()
        tasks[idx].assignee = nil
        tasks[idx].assigneeInstanceId = nil
        tasks[idx].status = "queued"
        tasks[idx].updatedAt = now
        tasks[idx].lastProgressAt = now
        tasks[idx].reassignmentCount += 1
        taskBoards[teamName] = tasks
        noteTasksChanged()
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
        noteTasksChanged()
        notifyChanged()
        return tasks[idx]
    }

    /// Converge one parallel wave at a hard deadline. A deadline is evidence
    /// of incompleteness, never evidence of success: only already-completed
    /// tasks remain completed; every other selected task is explicitly blocked.
    @discardableResult
    func convergeTimebox(
        teamName: String,
        taskIds: [String]? = nil,
        reason: String = "Timebox hard deadline reached; converge on completed evidence."
    ) -> [TeamOrchestrator.TeamTask] {
        lock.lock()
        defer { lock.unlock() }
        guard var tasks = taskBoards[teamName] else { return [] }
        let selected = taskIds.map(Set.init)
        let terminal: Set<String> = ["completed", "failed", "abandoned", "cancelled"]
        let now = Date()
        var changed: [TeamOrchestrator.TeamTask] = []
        for index in tasks.indices where selected?.contains(tasks[index].id) ?? true {
            guard !terminal.contains(tasks[index].status) else { continue }
            tasks[index].status = "blocked"
            tasks[index].blockedReason = reason
            tasks[index].lastProgressAt = now
            tasks[index].updatedAt = now
            changed.append(tasks[index])
        }
        guard !changed.isEmpty else { return [] }
        taskBoards[teamName] = tasks
        noteTasksChanged()
        notifyChanged()
        return changed
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
        let now = Date()
        heartbeats[teamName, default: [:]][agentName] = (now, summary?.teamDataNilIfBlank)
        // Update lastProgressAt for the agent's active non-terminal task
        let nonTerminalStatuses: Set<String> = ["pending", "assigned", "in_progress", "review_ready"]
        if var tasks = taskBoards[teamName],
           let idx = tasks.firstIndex(where: { $0.assignee == agentName && nonTerminalStatuses.contains($0.status) }) {
            tasks[idx].lastProgressAt = now
            taskBoards[teamName] = tasks
            noteTasksChanged()
        }
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

    // MARK: - Watch Drift Items

    /// Idempotently insert/upsert a watch drift item by checkId.
    /// Returns true if successful, false if team not found.
    @discardableResult
    func postWatchDrift(teamName: String, checkId: String, target: String, driftKind: String, severity: String, finding: String, specClause: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard teamRegistry[teamName] != nil else { return false }

        let item = WatchDriftItem(
            checkId: checkId,
            target: target,
            driftKind: driftKind,
            severity: severity,
            finding: finding,
            specClause: specClause,
            timestamp: Date()
        )

        // Idempotent upsert: replace if checkId exists, else append
        watchDrifts[teamName, default: [:]][checkId] = item
        notifyChanged()
        return true
    }

    // MARK: - x-kit Panel Runs (XK-EVENTS-v1)

    /// Live x-panel run mirrored from daemon `xk_run` events
    /// (docs/xk-panel-phase2.md). Instance-global, not team-scoped — runs are
    /// keyed by the `run` id. Never persisted: `.xm/` files remain the durable
    /// record; this map only feeds the dashboard.
    struct XkPanelRun {
        var run: String
        var source: String
        var runKind: String
        var title: String
        var phase: String                    // latest run-level phase ("starting" … "done"/"failed")
        var modelStates: [String: String]    // model → last reported state
        var elapsedMs: Int
        var tail: String?
        var logPath: String?                  // absolute path to this run's events.jsonl (review/panel only)
        var firstSeenAt: Date
        var updatedAt: Date

        var isTerminal: Bool { phase == "done" || phase == "failed" }
    }

    /// run id → live run state. Guarded by `lock`.
    private var xkPanelRuns: [String: XkPanelRun] = [:]

    /// Terminal runs linger this long for the dashboard, then are pruned.
    private let xkPanelRunRetention: TimeInterval = 15 * 60
    private let maxXkPanelRuns = 24

    /// Ingest one `xk_run` event (any thread). Mirrors the xk-bridge rules
    /// (`handle_xk_run` in tm_agent.rs): unknown `v` is ignored; run-level
    /// events (empty `model`) drive `phase`; per-model events only update that
    /// model's state; a terminal event for an unknown run never creates an
    /// entry (late replay).
    func ingestXkPanelRun(payload: [String: Any]) {
        guard (payload["v"] as? NSNumber)?.intValue ?? 1 == 1,
              let run = (payload["run"] as? String)?.teamDataNilIfBlank else { return }
        let model = (payload["model"] as? String)?.teamDataNilIfBlank
        let phase = (payload["phase"] as? String)?.teamDataNilIfBlank
        let now = Date()

        lock.lock()
        defer { lock.unlock() }
        var updated: XkPanelRun
        if let existing = xkPanelRuns[run] {
            updated = existing
        } else {
            if model == nil, phase == "done" || phase == "failed" { return }
            updated = XkPanelRun(
                run: run, source: "", runKind: "run", title: run,
                phase: phase ?? "starting", modelStates: [:], elapsedMs: 0,
                tail: nil, logPath: nil, firstSeenAt: now, updatedAt: now
            )
        }
        if let source = (payload["source"] as? String)?.teamDataNilIfBlank { updated.source = source }
        if let kind = (payload["run_kind"] as? String)?.teamDataNilIfBlank { updated.runKind = kind }
        if let title = (payload["title"] as? String)?.teamDataNilIfBlank { updated.title = title }
        if let model {
            if let state = (payload["state"] as? String)?.teamDataNilIfBlank {
                updated.modelStates[model] = state
            }
        } else if let phase {
            updated.phase = phase
        }
        if let elapsed = (payload["elapsed_ms"] as? NSNumber)?.intValue {
            updated.elapsedMs = max(updated.elapsedMs, elapsed)
        }
        if let tail = (payload["tail"] as? String)?.teamDataNilIfBlank { updated.tail = tail }
        // log_path rides the run-level frame (empty model) once — the socket advertises the
        // durable events.jsonl PATH; the dashboard reads the bytes off disk (richer per-model
        // stdout/stderr than the 256-char socket tail). review/panel runs only; cross omits it.
        if let lp = (payload["log_path"] as? String)?.teamDataNilIfBlank { updated.logPath = lp }
        updated.updatedAt = now
        xkPanelRuns[run] = updated
        pruneXkPanelRunsUnsafe(now: now)
    }

    /// Caller holds `lock`.
    private func pruneXkPanelRunsUnsafe(now: Date) {
        xkPanelRuns = xkPanelRuns.filter {
            !$0.value.isTerminal || now.timeIntervalSince($0.value.updatedAt) < xkPanelRunRetention
        }
        let overflow = xkPanelRuns.count - maxXkPanelRuns
        guard overflow > 0 else { return }
        // Evict oldest terminal runs first, then oldest overall.
        let victims = xkPanelRuns.values
            .sorted {
                if $0.isTerminal != $1.isTerminal { return $0.isTerminal }
                return $0.updatedAt < $1.updatedAt
            }
            .prefix(overflow)
        for victim in victims {
            xkPanelRuns.removeValue(forKey: victim.run)
        }
    }

    /// Dashboard snapshot — active runs first, most recently updated first.
    func xkPanelRunsSnapshot() -> [[String: Any]] {
        lock.lock()
        let now = Date()
        pruneXkPanelRunsUnsafe(now: now)
        let runs = Array(xkPanelRuns.values)
        lock.unlock()
        return runs
            .sorted {
                if $0.isTerminal != $1.isTerminal { return $1.isTerminal }
                return $0.updatedAt > $1.updatedAt
            }
            .map { run in
                [
                    "run": run.run,
                    "source": run.source,
                    "run_kind": run.runKind,
                    "title": run.title,
                    "phase": run.phase,
                    "terminal": run.isTerminal,
                    "models": run.modelStates
                        .sorted { $0.key < $1.key }
                        .map { ["model": $0.key, "state": $0.value] },
                    "elapsed_ms": run.elapsedMs,
                    "age_seconds": Int(now.timeIntervalSince(run.updatedAt)),
                    "tail": run.tail as Any? ?? NSNull(),
                    "log_path": run.logPath as Any? ?? NSNull(),
                ]
            }
    }

    // MARK: - Agent Status Enrichment (off-main data for team.status)

    /// Returns data-layer enrichment for a given agent, avoiding MainActor.
    /// Includes active task, heartbeat, and runtime state derived from task status.
    func agentDataEnrichment(
        teamName: String,
        agentName: String,
        agentInstanceId: String? = nil
    ) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        // Active task: most recently updated non-terminal task assigned to this agent.
        // Phase E Wave 1: "cancelled" joins the terminal set so daemon-driven
        // cancellation clears the sidebar's active_task_id pointer in the same
        // tick as the status flip (no per-agent cache to invalidate — the
        // derived filter is the single source of truth).
        let terminalStatuses: Set<String> = ["completed", "failed", "abandoned", "cancelled"]
        let activeTask = taskBoards[teamName, default: []]
            .filter {
                $0.assignee == agentName
                    && (agentInstanceId == nil || $0.assigneeInstanceId == agentInstanceId)
                    && !terminalStatuses.contains($0.status)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first

        // Task staleness (computed before agent_state so we can derive
        // "assigned_stale" when an assigned task hasn't progressed in time).
        let isTaskStale: Bool
        if let task = activeTask, !terminalStatuses.contains(task.status) {
            let anchor = task.lastProgressAt ?? task.startedAt ?? task.updatedAt
            isTaskStale = Date().timeIntervalSince(anchor) >= staleTaskThreshold
        } else {
            isTaskStale = false
        }

        // Runtime state derived from task status
        // Phase 2: "parked" is a daemon-authoritative state — when an agent's
        // subprocess has been terminated but metadata is preserved on disk
        // (idle auto-park or explicit park_agent RPC). The daemon mirrors the
        // flag into headlessAgentParked[teamName][agentName]. Parked overrides
        // task-derived state because there is no live subprocess regardless of
        // the task board entry. See docs/phase2-rpc-contract.md §5.
        //
        // Phase E Wave 1: "assigned_stale" surfaces a task that was assigned
        // but never picked up (or has gone silent past the stale threshold).
        // Sidebar renders this as an amber/⏳ indicator. Derived locally;
        // daemon may also push the same label via an anomaly event in the
        // future — both paths converge on the same case string.
        var agentState: String
        if isAgentParkedUnsafe(teamName: teamName, agentName: agentName) {
            agentState = "parked"
        } else if let task = activeTask {
            if (task.status == "assigned" || task.status == "queued") && isTaskStale {
                agentState = "assigned_stale"
            } else {
                switch task.status {
                case "blocked": agentState = "blocked"
                case "review_ready": agentState = "review_ready"
                case "failed": agentState = "error"
                case "queued", "assigned": agentState = "idle"
                case "parked": agentState = "parked"
                default: agentState = "running"
                }
            }
        } else {
            agentState = "idle"
        }
        // A turn in flight outranks anything the board can say: the board knows
        // about tasks, and this agent may simply have been asked a question.
        if isAgentBusyUnsafe(teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId) {
            agentState = "running"
        }

        // Heartbeat
        let heartbeat = heartbeats[teamName]?[agentName]
        let heartbeatAge: Int? = heartbeat.map { max(0, Int(Date().timeIntervalSince($0.at))) }
        let heartbeatStale = heartbeat.map { Date().timeIntervalSince($0.at) >= staleHeartbeatThreshold } ?? false

        return [
            "agent_state": agentState,
            "active_task_id": activeTask?.id as Any? ?? NSNull(),
            "active_task_title": activeTask?.title as Any? ?? NSNull(),
            "active_task_status": activeTask?.status as Any? ?? NSNull(),
            "active_task_is_stale": isTaskStale,
            "heartbeat_age_seconds": heartbeatAge as Any? ?? NSNull(),
            "last_heartbeat_summary": heartbeat?.summary as Any? ?? NSNull(),
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

    /// Persist a result. A task result is keyed by `taskId`, never by a role
    /// name: two executor panes may share that alias. The name-keyed file is
    /// retained only as a legacy read fallback for reports without a task.
    func writeResult(
        teamName: String,
        agentName: String,
        agentInstanceId: String? = nil,
        taskId: String? = nil,
        content: String,
        resultPath: String? = nil
    ) -> Bool {
        if let taskId {
            lock.lock()
            let task = taskBoards[teamName]?.first(where: { $0.id == taskId })
            lock.unlock()
            guard let task, task.assignee == agentName,
                  agentIdentityMatches(
                      teamName: teamName, agentName: agentName,
                      expectedInstanceId: task.assigneeInstanceId,
                      reportedInstanceId: agentInstanceId)
            else { return false }
        }
        let dir = Self.resultDirectory(teamName: teamName)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let primaryKey = taskId ?? agentName
        let path = (dir as NSString).appendingPathComponent("\(primaryKey).result.json")
        var payload: [String: Any] = [
            "agent": agentName,
            "content": content,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        if let taskId { payload["task_id"] = taskId }
        if let agentInstanceId { payload["agent_instance_id"] = agentInstanceId }
        if let rp = resultPath, !rp.isEmpty {
            payload["result_path"] = rp
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return false
        }
        return FileManager.default.createFile(atPath: path, contents: data)
    }

    func readResult(teamName: String, taskId: String, agentName: String? = nil) -> [String: Any]? {
        let dir = Self.resultDirectory(teamName: teamName)
        let path = (dir as NSString).appendingPathComponent("\(taskId).result.json")
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Legacy reports did not have a task id and were keyed by role.
            guard let agentName else { return nil }
            let legacy = (dir as NSString).appendingPathComponent("\(agentName).result.json")
            guard let legacyData = FileManager.default.contents(atPath: legacy),
                  let legacyObj = try? JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
            else { return nil }
            return legacyObj
        }
        return obj
    }

    /// Returns result-file presence per agent.
    ///
    /// - Parameters:
    ///   - agentFilter: if non-empty, restrict to these agent names (intersected with team members).
    ///   - activeOnly: if true (and `agentFilter` is empty), restrict to agents who currently have
    ///     a non-terminal task assigned. Used by `tm-agent wait` fallback to avoid counting
    ///     team members who were never delegated to in this round.
    func resultStatus(
        teamName: String,
        agentFilter: [String]? = nil,
        activeOnly: Bool = false
    ) -> [String: Any] {
        lock.lock()
        let allAgents = teamRegistry[teamName, default: []]
        let tasks = taskBoards[teamName, default: []]
        lock.unlock()
        guard !allAgents.isEmpty else { return [:] }
        let agents: [AgentRegistration]
        if let filter = agentFilter, !filter.isEmpty {
            let filterSet = Set(filter)
            agents = allAgents.filter { filterSet.contains($0.name) }
        } else if activeOnly {
            let terminalStatuses: Set<String> = ["completed", "failed", "abandoned", "cancelled"]
            let activeInstances = Set(tasks.compactMap { task in
                !terminalStatuses.contains(task.status) ? task.assigneeInstanceId : nil
            })
            agents = allAgents.filter { registration in
                registration.instanceId.map(activeInstances.contains) == true
            }
        } else {
            agents = allAgents
        }
        let dir = Self.resultDirectory(teamName: teamName)
        var agentStatus: [[String: Any]] = []
        for agent in agents {
            let assignedTask = tasks
                .filter { $0.assignee == agent.name && $0.assigneeInstanceId == agent.instanceId }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
            let path = assignedTask.map { task in
                (dir as NSString).appendingPathComponent("\(task.id).result.json")
            } ?? (dir as NSString).appendingPathComponent("\(agent.name).result.json")
            var row: [String: Any] = [
                "agent_name": agent.name,
                "has_result": FileManager.default.fileExists(atPath: path),
                "task_id": assignedTask?.id as Any? ?? NSNull(),
                "agent_instance_id": agent.instanceId as Any? ?? NSNull(),
            ]
            if let assignedTask {
                row["parallel_telemetry"] = Self.parallelTelemetry(for: assignedTask)
            }
            agentStatus.append(row)
        }
        let completed = agentStatus.filter { $0["has_result"] as? Bool == true }.count
        let total = agents.count
        return [
            "team_name": teamName,
            "agents": agentStatus,
            "completed": completed,
            "total": total,
            // all_done requires at least one agent to be meaningful — empty filter
            // means "no work tracked yet", not "all done".
            "all_done": total > 0 && completed == total,
        ]
    }

    func collectResults(teamName: String) -> [[String: Any]] {
        // One row per task/instance. Name aliases are only a fallback for
        // old result files, never the primary collect key.
        let tasks = listTasks(teamName: teamName, status: nil, assignee: nil,
                              needsAttention: false, priority: nil, staleOnly: false, dependsOn: nil)
        var results: [[String: Any]] = []
        var seen = Set<String>()
        for task in tasks where task.assignee != nil {
            guard let result = readResult(teamName: teamName, taskId: task.id, agentName: task.assignee) else { continue }
            guard let instance = result["agent_instance_id"] as? String else {
                // Legacy fallback is only safe for a task with an unambiguous alias.
                if tasks.filter({ $0.assignee == task.assignee }).count != 1 { continue }
                var enriched = result
                enriched["parallel_telemetry"] = Self.parallelTelemetry(for: task)
                enriched["content_bytes"] = (result["content"] as? String)?.lengthOfBytes(using: .utf8) ?? 0
                results.append(enriched)
                continue
            }
            guard instance == task.assigneeInstanceId, seen.insert(task.id).inserted else { continue }
            var enriched = result
            enriched["parallel_telemetry"] = Self.parallelTelemetry(for: task)
            enriched["content_bytes"] = (result["content"] as? String)?.lengthOfBytes(using: .utf8) ?? 0
            results.append(enriched)
        }
        return results.sorted { ($0["task_id"] as? String ?? "") < ($1["task_id"] as? String ?? "") }
    }

    func clearResults(teamName: String) {
        try? FileManager.default.removeItem(atPath: Self.resultDirectory(teamName: teamName))
    }

    // MARK: - Task Dictionary (for JSON responses)

    func taskDictionary(_ task: TeamOrchestrator.TeamTask) -> [String: Any] {
        var dict: [String: Any] = [
            "id": task.id,
            "title": task.title,
            "description": task.details as Any? ?? NSNull(),
            "acceptance_criteria": task.acceptanceCriteria,
            "labels": task.labels,
            "estimated_size": task.estimatedSize as Any? ?? NSNull(),
            "status": task.status,
            "priority": task.priority,
            "depends_on": task.dependsOn,
            "parent_task_id": task.parentTaskId as Any? ?? NSNull(),
            "child_task_ids": task.childTaskIds,
            "reassignment_count": task.reassignmentCount,
            "superseded_by": task.supersededBy as Any? ?? NSNull(),
            "assignee": task.assignee as Any? ?? NSNull(),
            "agent_instance_id": task.assigneeInstanceId as Any? ?? NSNull(),
            "parallel_telemetry": Self.parallelTelemetry(for: task),
            "blocked_reason": task.blockedReason as Any? ?? NSNull(),
            "review_summary": task.reviewSummary as Any? ?? NSNull(),
            "created_by": task.createdBy,
            "result": task.result as Any? ?? NSNull(),
            "result_path": task.resultPath as Any? ?? NSNull(),
            "worktree_policy": task.worktreePolicy as Any? ?? NSNull(),
            "worktree_path": task.worktreePath as Any? ?? NSNull(),
            "worktree_branch": task.worktreeBranch as Any? ?? NSNull(),
            "worktree_parent": task.worktreeParent as Any? ?? NSNull(),
            "worktree_created": task.worktreeCreated as Any? ?? NSNull(),
            "worktree_reused": task.worktreeReused as Any? ?? NSNull(),
            "worktree_init": task.worktreeInit as Any? ?? NSNull(),
            "worktree_finish_mode": task.worktreeFinishMode as Any? ?? NSNull(),
            "worktree_removed": task.worktreeRemoved as Any? ?? NSNull(),
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
        if let worktreeFinishedAt = task.worktreeFinishedAt {
            dict["worktree_finished_at"] = ISO8601DateFormatter().string(from: worktreeFinishedAt)
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

    /// Additive, body-free routing telemetry for machine readers. Values are
    /// identifiers, digests/status strings, and byte counts only; task details,
    /// prompts, reports, and result bodies never enter this object.
    private static func parallelTelemetry(for task: TeamOrchestrator.TeamTask) -> [String: Any] {
        [
            "wave_id": task.parentTaskId ?? task.id,
            "task_id": task.id,
            "agent_instance_id": task.assigneeInstanceId as Any? ?? NSNull(),
            "host": NSNull(),
            "checkout": task.worktreePath ?? task.worktreeBranch ?? NSNull(),
            "delivery": task.status == "assigned" || task.status == "in_progress" ? "scheduled" : task.status,
            "synthesis": task.reviewSummary == nil ? "pending" : "available",
        ]
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

    func inboxItems(teamName: String, agentName: String? = nil, topOnly: Bool = false) -> [[String: Any]] {
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
                "agent_name": task.assignee as Any? ?? NSNull(),
                "reason": attention.1,
                "age_seconds": Int(now.timeIntervalSince(task.updatedAt)),
                "summary": task.title,
                "task_title": task.title,
                "result": task.result as Any? ?? NSNull(),
                "review_summary": task.reviewSummary as Any? ?? NSNull(),
                "status": task.status,
                "is_stale": staleSeconds != nil,
                "stale_seconds": staleSeconds as Any? ?? NSNull()
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
                // When agentName is provided, include all messages addressed to this agent
                // (e.g. agent-to-agent "note" type messages)
                if let agent = agentName, message.to == agent {
                    priority = 6
                } else {
                    priority = nil
                }
            }
            guard let priority else { continue }
            var item: [String: Any] = [
                "kind": "message",
                "priority": priority,
                "team_name": teamName,
                "task_id": NSNull(),
                "agent_name": message.from,
                "from": message.from,
                "status": message.type,
                "reason": message.content,
                "age_seconds": Int(now.timeIntervalSince(message.timestamp)),
                "summary": String(message.content.prefix(120)),
                "message_type": message.type,
                "message_id": message.id,
            ]
            if let to = message.to { item["to"] = to }
            items.append(item)
        }

        // Watch drift items (Phase 5)
        for drift in watchDrifts[teamName, default: [:]].values {
            let summary = "[watch:\(drift.driftKind)/\(drift.severity)] \(String(drift.finding.prefix(80)))"
            items.append([
                "kind": "watch_drift",
                "priority": 2,
                "team_name": teamName,
                "check_id": drift.checkId,
                "target": drift.target,
                "drift_type": drift.driftKind,
                "severity": drift.severity,
                "finding": drift.finding,
                "spec_clause": drift.specClause,
                "age_seconds": Int(now.timeIntervalSince(drift.timestamp)),
                "summary": summary,
                "timestamp": ISO8601DateFormatter().string(from: drift.timestamp)
            ])
        }

        items.sort {
            let lhsPriority = $0["priority"] as? Int ?? Int.max
            let rhsPriority = $1["priority"] as? Int ?? Int.max
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            let lhsAge = $0["age_seconds"] as? Int ?? .min
            let rhsAge = $1["age_seconds"] as? Int ?? .min
            return lhsAge > rhsAge
        }
        if topOnly, let first = items.first { return [first] }
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
