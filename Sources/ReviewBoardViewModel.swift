import Combine
import Foundation

@MainActor
final class ReviewBoardViewModel: ObservableObject {
    @Published private(set) var snapshot: ReviewBoardSnapshot
    @Published var selectedTaskID: String?

    private var snapshotProvider: @MainActor () -> ReviewBoardSnapshot
    private var teamCancellable: AnyCancellable?
    private var activityTicker: Timer?

    init(
        initialSnapshot: ReviewBoardSnapshot = .empty,
        selectedTaskID: String? = UserDefaults.standard.string(forKey: ReviewBoardSettings.selectedTaskIDKey),
        snapshotProvider: @escaping @MainActor () -> ReviewBoardSnapshot = {
            TeamDataStoreReviewBoardSnapshotProvider().snapshot()
        }
    ) {
        snapshot = initialSnapshot
        self.selectedTaskID = selectedTaskID
        self.snapshotProvider = snapshotProvider
        if initialSnapshot == .empty {
            refresh()
        } else {
            keepSelectionValid()
        }
        observeTeams()
    }

    /// The board reads the teams, so it listens to the teams. It used to be
    /// refreshed only by the coordinator's event stream and by appearing on
    /// screen, which meant that with the coordinator off — its normal state —
    /// the board was a single snapshot taken at launch, when nothing had
    /// happened yet. Work would run to completion in a pane beside a board
    /// that still said there was none.
    private func observeTeams() {
        // Both stores, because the board reads both: teams and agents live in
        // the orchestrator, tasks in the data store, and a change to either is
        // a change to what the board shows.
        teamCancellable = Publishers.Merge(
            TeamOrchestrator.shared.objectWillChange.map { _ in () },
            TeamDataStore.shared.$taskRevision.map { _ in () }
        )
        // Team state churns in bursts (add agent → panes → task assigned), and
        // objectWillChange fires before the change lands, so settle then read.
        .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refresh()
        }

        // Whether an agent is printing changes without either store changing,
        // so nothing above fires while work is under way — the very moment the
        // board most needs to be moving. A short tick covers it; the refresh
        // is a read of state already in memory.
        activityTicker?.invalidate()
        let ticker = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWhileWorkIsRunning() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        activityTicker = ticker
    }

    /// Idle boards cost nothing: with no tasks there is nothing to animate.
    private func refreshWhileWorkIsRunning() {
        guard !snapshot.tasks.isEmpty else { return }
        refresh()
    }

    /// Agent names that are printing right now, by the task they hold. The
    /// board's own status comes from the task board, which cannot tell work in
    /// progress from work not yet begun; this is what closes that gap.
    var workingAssignees: Set<String> {
        var working: Set<String> = []
        for team in TeamOrchestrator.shared.listTeams() {
            for agent in team["agents"] as? [[String: Any]] ?? [] {
                guard (agent["agent_state"] as? String) == "running",
                      let name = agent["name"] as? String else { continue }
                working.insert(name)
            }
        }
        return working
    }

    func isWorking(_ task: ReviewBoardTask) -> Bool {
        guard let assignee = task.assignee else { return false }
        return workingAssignees.contains(assignee)
    }

    var tasks: [ReviewBoardTask] {
        snapshot.tasks.sorted { lhs, rhs in
            let lhsRank = statusRank(lhs.status)
            let rhsRank = statusRank(rhs.status)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return (lhs.updatedAt ?? "") > (rhs.updatedAt ?? "")
        }
    }

    var selectedTask: ReviewBoardTask? {
        if let selectedTaskID,
           let task = tasks.first(where: { $0.id == selectedTaskID }) {
            return task
        }
        return tasks.first
    }

    func refresh() {
        snapshot = snapshotProvider()
        keepSelectionValid()
    }

    func setSnapshotProvider(_ provider: @escaping @MainActor () -> ReviewBoardSnapshot) {
        snapshotProvider = provider
        refresh()
    }

    func selectTask(id: String) {
        selectedTaskID = id
        UserDefaults.standard.set(id, forKey: ReviewBoardSettings.selectedTaskIDKey)
    }

    func statusBadges(for task: ReviewBoardTask?) -> [ReviewBoardStatus] {
        var badges: [ReviewBoardStatus] = []
        if !snapshot.coordinatorOnline { badges.append(.coordinatorOffline) }
        if !snapshot.memMeshAvailable { badges.append(.memMeshUnavailable) }
        if snapshot.suspectHost { badges.append(.suspectHost) }
        if snapshot.fencedZombie { badges.append(.fencedZombie) }
        guard let task else { return badges }

        let labels = Set(task.labels.map { $0.lowercased() })
        if labels.contains("coordinator-offline") { badges.append(.coordinatorOffline) }
        if labels.contains("mem-mesh-unavailable") { badges.append(.memMeshUnavailable) }
        if labels.contains("suspect-host") || task.isStale { badges.append(.suspectHost) }
        if labels.contains("fenced-zombie") { badges.append(.fencedZombie) }
        if task.status == "blocked" || task.status == "quarantined" { badges.append(.blocked) }
        if task.status == "review_ready" { badges.append(.reviewReady) }
        // A real queue entry outranks the guesses below it: when the
        // coordinator says this task's merge failed, nothing else needs to be
        // inferred. Only when there is no entry do we fall back to reading
        // the task's own text, which is all a locally-backed board has.
        if let item = snapshot.mergeQueueItem(for: task) {
            if item.isFailed { badges.append(.mergeFailed) }
        } else {
            if task.status == "failed" && mergeText(for: task).contains("merge") {
                badges.append(.mergeFailed)
            }
            if labels.contains("merge-failed") {
                badges.append(.mergeFailed)
            }
        }

        return ReviewBoardStatus.allCases.filter { badges.contains($0) }
    }

    /// Entries still waiting on the queue, newest approval first. Finished
    /// ones are dropped: a merged entry is history, and the panel is for what
    /// still needs attention — except failures, which need it most of all.
    var pendingMergeQueue: [ReviewBoardMergeQueueItem] {
        snapshot.mergeQueue
            .filter { $0.isPending || $0.isFailed }
            .sorted { ($0.approvedAt ?? "") > ($1.approvedAt ?? "") }
    }

    /// A queue entry names a task by id, which is not a thing to show a
    /// person. Falls back to the shortened id when the task is not in the
    /// list — the queue is project-wide and the task list is capped, so an
    /// entry can outlive its row.
    func taskTitle(forMergeQueueItem item: ReviewBoardMergeQueueItem) -> String {
        snapshot.tasks.first { $0.rawID == item.taskRawID }?.title
            ?? "Task \(item.taskDisplayID)"
    }

    /// The pane this task is running in, when it is running on this machine.
    /// Work placed on a peer has no local pane — the coordinator knows it is
    /// out there, but there is nothing here to look at.
    func paneLocation(for task: ReviewBoardTask) -> (workspaceID: UUID, panelID: UUID)? {
        guard let assignee = task.assignee,
              let team = TeamOrchestrator.shared.teams[task.teamName],
              let agent = team.agents.first(where: { $0.name == assignee }),
              let panelID = agent.panelId else { return nil }
        return (agent.workspaceId, panelID)
    }

    /// Go to the work. The board is an index of what is happening; the pane is
    /// where it is actually happening, and without a way across, the index
    /// leaves you to hunt the sidebar for the workspace it was talking about.
    @discardableResult
    func revealPane(for task: ReviewBoardTask) -> Bool {
        guard let assignee = task.assignee else { return false }
        return TeamOrchestrator.shared.revealAgentPane(
            teamName: task.teamName,
            agentName: assignee
        )
    }

    func digest(for task: ReviewBoardTask) -> ReviewBoardTaskDigest {
        ReviewBoardTaskDigest.make(
            for: task,
            panelRuns: snapshot.panelRuns,
            mergeQueueItem: snapshot.mergeQueueItem(for: task)
        )
    }

    private func keepSelectionValid() {
        let ids = Set(snapshot.tasks.map(\.id))
        if let selectedTaskID, ids.contains(selectedTaskID) { return }
        selectedTaskID = tasks.first?.id
    }

    private func mergeText(for task: ReviewBoardTask) -> String {
        ([task.title, task.reviewSummary, task.result, task.blockedReason] + task.labels)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    /// Needs-attention first. Both vocabularies are ranked here — the team
    /// board's and the coordinator's — because either producer can fill the
    /// list, and an unranked status sinks to the bottom where a blocked task
    /// would go unseen.
    private func statusRank(_ status: String) -> Int {
        switch status {
        case "blocked", "quarantined": return 0
        case "failed", "rejected": return 1
        case "review_ready": return 2
        case "queued_for_merge", "approved": return 3
        case "in_progress": return 4
        case "suspect": return 5
        case "assigned", "queued", "placed", "reassigned": return 6
        case "pending": return 7
        case "completed", "merged": return 8
        case "cancelled": return 9
        default: return 10
        }
    }
}

struct TeamDataStoreReviewBoardSnapshotProvider {
    @MainActor
    func snapshot() -> ReviewBoardSnapshot {
        let fleet = TeamOrchestrator.shared.fleetState()
        let tasks = (fleet["tasks"] as? [[String: Any]] ?? []).compactMap(ReviewBoardTask.init(dictionary:))
        let panelRuns = (fleet["panel_runs"] as? [[String: Any]] ?? []).compactMap(ReviewBoardPanelRun.init(dictionary:))
        let labels = tasks.flatMap { $0.labels.map { $0.lowercased() } }
        let instance = fleet["instance"] as? [String: Any]
        let coordinatorOnline = !(instance?["socket_path"] as? String ?? "").isEmpty

        return ReviewBoardSnapshot(
            tasks: tasks,
            panelRuns: panelRuns,
            coordinatorOnline: coordinatorOnline,
            memMeshAvailable: !labels.contains("mem-mesh-unavailable"),
            suspectHost: labels.contains("suspect-host"),
            fencedZombie: labels.contains("fenced-zombie")
        )
    }
}
