import Combine
import Foundation

/// What the board can DO, injected the way the snapshot is read.
///
/// The read path has been fakeable since the beginning (`snapshotProvider`);
/// the write path had no seam at all, because there was nothing to write.
/// Giving it the same shape is what keeps approving testable without a live
/// coordinator socket — and keeps the view model from reaching for a
/// singleton.
struct ReviewBoardActions {
    var review: @MainActor (ReviewBoardTask) async -> ReviewBoardReview
    var approve: @MainActor (ReviewBoardReview) async throws -> Void
    var reject: @MainActor (ReviewBoardReview, String) async throws -> Void

    /// What the board does before anything is wired: nothing, and it says so.
    static let unavailable = ReviewBoardActions(
        review: { task in
            ReviewBoardReview(
                taskID: task.rawID, detail: .unavailable, patch: nil,
                blocker: "The coordinator is off, so nothing can be approved from here."
            )
        },
        approve: { _ in throw ReviewBoardCoordinatorError.disabled },
        reject: { _, _ in throw ReviewBoardCoordinatorError.disabled }
    )
}

@MainActor
final class ReviewBoardViewModel: ObservableObject {
    @Published private(set) var snapshot: ReviewBoardSnapshot
    @Published var selectedTaskID: String?

    /// The selected task's evidence, once it has been read. Nil while nothing
    /// is selected or the read has not finished.
    @Published private(set) var review: ReviewBoardReview?
    /// True while a read or a decision is in flight. The buttons watch this so
    /// a second click cannot start a second approval.
    @Published private(set) var actionInFlight = false
    /// The last failure, in the words the coordinator or git used. Cleared
    /// when the next action starts — a stale error next to a fresh result
    /// reads as though the fresh one failed.
    @Published private(set) var actionError: String?

    /// The boundary, as configured. Read from settings so what the toggle
    /// shows and what the runner enforces cannot drift apart.
    @Published private(set) var autoPilot: AutoPilotPolicy
    /// What auto pilot did, newest first — including what it declined, which
    /// is usually the question being asked.
    @Published private(set) var autoPilotAudit: [AutoPilotAudit] = []
    /// Merges that can still be taken back.
    @Published private(set) var autoPilotUndoPoints: [AutoPilotUndoPoint] = []
    @Published private(set) var undoInFlight = false
    /// The result of the last undo, in git's words when it failed.
    @Published private(set) var undoMessage: String?

    private var snapshotProvider: @MainActor () -> ReviewBoardSnapshot
    /// Where the auto pilot policy is read and written. Injected so a test can
    /// exercise the toggle without arming unattended merging for whoever is
    /// running the tests.
    private let defaults: UserDefaults
    private var actions: ReviewBoardActions = .unavailable
    private var reviewedTaskID: String?
    private var teamCancellable: AnyCancellable?
    private var activityTicker: Timer?

    init(
        initialSnapshot: ReviewBoardSnapshot = .empty,
        selectedTaskID: String? = UserDefaults.standard.string(forKey: ReviewBoardSettings.selectedTaskIDKey),
        snapshotProvider: @escaping @MainActor () -> ReviewBoardSnapshot = {
            TeamDataStoreReviewBoardSnapshotProvider().snapshot()
        },
        defaults: UserDefaults = .standard
    ) {
        snapshot = initialSnapshot
        self.defaults = defaults
        autoPilot = AutoPilotPolicy.load(from: defaults)
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

    func setActions(_ actions: ReviewBoardActions) {
        self.actions = actions
    }

    // MARK: - Reviewing the selected task

    /// Read the selected task's evidence.
    ///
    /// Keyed on which task was read, so re-appearing or a refresh tick does
    /// not re-run git for a task already in hand — reading a patch is a
    /// subprocess, not a property.
    func loadReview(for task: ReviewBoardTask, force: Bool = false) async {
        guard force || reviewedTaskID != task.rawID else { return }
        guard !actionInFlight else { return }
        actionInFlight = true
        actionError = nil
        let result = await actions.review(task)
        // The selection can move while a read is in flight; a result for a
        // task nobody is looking at must not replace what is on screen.
        guard selectedTaskID == nil || task.id == selectedTaskID else {
            actionInFlight = false
            return
        }
        reviewedTaskID = task.rawID
        review = result
        actionInFlight = false
    }

    /// Approve what was read. Returns whether it landed, so a view can close
    /// a sheet only on success.
    @discardableResult
    func approve() async -> Bool {
        await act { review in try await self.actions.approve(review) }
    }

    @discardableResult
    func reject(reason: String) async -> Bool {
        await act { review in try await self.actions.reject(review, reason) }
    }

    private func act(_ body: (ReviewBoardReview) async throws -> Void) async -> Bool {
        guard let review, !actionInFlight else { return false }
        // The panel hides the buttons when the coordinator cannot act, but the
        // panel is not the only caller. Refusing here means the reason shown is
        // the one already read off the task rather than whatever the
        // coordinator returns for an approval it was never going to accept.
        guard review.canAct else {
            actionError = review.blocker ?? "This task cannot be decided yet."
            return false
        }
        actionInFlight = true
        actionError = nil
        do {
            try await body(review)
            // The task has moved on, so what was read no longer describes it.
            // Dropping it forces the next look to re-read rather than offer a
            // second decision on a decided task.
            reviewedTaskID = nil
            self.review = nil
            actionInFlight = false
            refresh()
            return true
        } catch {
            actionError = Self.message(for: error)
            actionInFlight = false
            return false
        }
    }

    /// The coordinator's own words where it has them. A rejected approval says
    /// `snapshot evidence mismatch` or `stale_fencing_token`, and those are the
    /// two things a reviewer actually needs to see — replacing them with
    /// "Approval failed" would hide which one happened.
    private static func message(for error: Error) -> String {
        switch error {
        case ReviewBoardCoordinatorError.disabled:
            return "The coordinator is off."
        case let ReviewBoardCoordinatorError.jsonRPCError(_, message):
            return message
        default:
            return error.localizedDescription
        }
    }

    func selectTask(id: String) {
        selectedTaskID = id
        UserDefaults.standard.set(id, forKey: ReviewBoardSettings.selectedTaskIDKey)
    }

    // MARK: - Auto pilot

    /// Turning it on, and where it may go.
    ///
    /// Written straight through to the settings rather than held here: the
    /// runner reads the policy fresh on every sweep, so a toggle that only
    /// changed a published property would look on and act off.
    func setAutoPilotEnabled(_ enabled: Bool) {
        var updated = autoPilot
        updated.isEnabled = enabled
        updated.save(to: defaults)
        autoPilot = updated
        reloadAutoPilotJournals()
    }

    func setAutoPilotCeiling(_ branch: String) {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = autoPilot
        updated.ceilingBranch = trimmed.isEmpty ? AutoPilotPolicy.defaultCeiling : trimmed
        updated.save(to: defaults)
        autoPilot = updated
    }

    /// What it did, newest first, and what can still be taken back.
    func reloadAutoPilotJournals() {
        guard let team = snapshot.tasks.first?.teamName, !team.isEmpty else {
            autoPilotAudit = []
            autoPilotUndoPoints = []
            return
        }
        autoPilotAudit = AutoPilotJournal<AutoPilotAudit>(teamName: team, kind: "audit").entries()
        autoPilotUndoPoints = AutoPilotUndoLog(teamName: team).points()
    }

    /// Put a branch back. Reads where it actually is first — moving a ref out
    /// from under a checkout is what makes an undo worse than the merge.
    func undoAutoMerge(_ point: AutoPilotUndoPoint) async {
        guard !undoInFlight else { return }
        undoInFlight = true
        undoMessage = nil
        defer { undoInFlight = false }

        let placement = await AutoPilotUndo.placement(
            of: point.branch, in: point.repositoryPath
        )
        switch await AutoPilotUndo.apply(AutoPilotUndo.plan(for: point, placement: placement)) {
        case .done(let message):
            undoMessage = message
            reloadAutoPilotJournals()
            refresh()
        case .failed(let reason):
            undoMessage = reason
        }
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
