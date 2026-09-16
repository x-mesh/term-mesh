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

    /// The Project the board is pointed at, set from whichever workspace is on
    /// screen. Nil means no team there, and the section hides itself.
    @Published private(set) var activeTeamName: String?
    @Published private(set) var delegation: DelegationPanel?
    @Published private(set) var delegationChangeInFlight = false
    @Published private(set) var delegationError: String?
    private var delegationRequestGeneration: UInt64 = 0
    @Published private(set) var collaboration: CollaborationPanel?
    @Published private(set) var collaborationRepairOutcome: CollaborationRepairOutcome = .idle

    var collaborationRepairInFlight: Bool { collaborationRepairOutcome.isRunning }

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
    private var activeTeamProvider: @MainActor () -> String? = { nil }
    private var remoteContextProvider: @MainActor () -> RemoteLiveProject.BoardContext? = { nil }
    /// Where the auto pilot policy is read and written. Injected so a test can
    /// exercise the toggle without arming unattended merging for whoever is
    /// running the tests.
    private let defaults: UserDefaults
    private var actions: ReviewBoardActions = .unavailable
    private var reviewedTaskID: String?
    /// Which task's evidence is being read right now, if any.
    ///
    /// Kept apart from `actionInFlight` — which the panel watches and which is
    /// true for a read of *any* task — so that a read for one task can be
    /// superseded by a read for another instead of blocking it.
    private var loadingTaskID: String?
    /// True only while an approval or rejection is landing. `actionInFlight`
    /// covers reads as well, so it cannot answer "is a decision in flight".
    private var decisionInFlight = false
    private var teamCancellable: AnyCancellable?
    private var activityTicker: Timer?
    private var remoteCollaborationRecords: [String: [LeaderTurnLog.Record]] = [:]
    private var remoteCollaborationFetches: [String: Task<Void, Never>] = [:]
    private var remoteCollaborationFetchedAt: [String: Date] = [:]

    /// The Overlap canary health reading for the active team, kept apart from
    /// `delegation` because it lands on its own throttled schedule (see
    /// `refreshLocalOverlapHealthIfNeeded`) rather than every refresh tick.
    @Published private(set) var overlapHealthReading: OverlapHealthReading = .checking
    private var localOverlapHealthReadings: [String: OverlapHealthReading] = [:]
    private var localOverlapHealthFetches: [String: Task<Void, Never>] = [:]
    private var localOverlapHealthFetchedAt: [String: Date] = [:]
    /// Same shape as the three above, for `.peer` leaders. Kept in its own
    /// dictionaries rather than shared ones: a local and a peer reading for
    /// the same team name can never coexist (a team has exactly one
    /// `leaderEndpoint`), but sharing storage would still leave a stale
    /// remote reading readable after a team's endpoint changed identity.
    private var remoteOverlapHealthReadings: [String: OverlapHealthReading] = [:]
    private var remoteOverlapHealthFetches: [String: Task<Void, Never>] = [:]
    private var remoteOverlapHealthFetchedAt: [String: Date] = [:]

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
            // `refresh()` derives these off a snapshot *change*, and this path
            // has none to react to — the snapshot arrived with the caller.
            rebuildDerivedSnapshotState()
            workingAssignees = Self.runningAgentNames()
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
            // `ReviewBoardPanelView.onAppear` refreshes immediately when the
            // board returns, so an off-screen board can skip this work without
            // reopening with a stale snapshot.
            guard ReviewBoardSettings.isVisible else { return }
            Task { @MainActor in self?.refreshWhileWorkIsRunning() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        activityTicker = ticker
    }

    /// Idle boards cost nothing: with no tasks there is nothing to animate.
    ///
    /// The delegation panel is the exception and is refreshed either way. A
    /// board with no tasks is precisely where someone sets the level for the
    /// work they are about to start, and it also has to show a roster sitting
    /// idle — which is a state with no tasks by definition.
    private func refreshWhileWorkIsRunning() {
        guard !snapshot.tasks.isEmpty else {
            refreshDelegationPanel()
            return
        }
        // Rebuilding the snapshot on this beat used to be how the board saw
        // anything at all change. It no longer has to be: tasks publish through
        // `taskRevision`, teams and agents through the orchestrator, and x-kit
        // panel runs now publish too — `observeTeams` is subscribed to all of
        // it. Rebuilding to discover that nothing moved cost more than every
        // other thing this tick does put together.
        //
        // Two exceptions, both because something moves with no mutation to
        // publish. Panel runs age on the clock: `xkPanelRunsSnapshot` derives
        // `age_seconds` from now and prunes expired terminal runs as it reads,
        // so while any run is on the board this beat is what advances it and
        // what eventually clears it. And the coordinator's snapshot has no
        // publisher at all, so with the distributed integration on this beat is
        // the only thing that would notice a remote task.
        guard snapshot.panelRuns.isEmpty,
              !ReviewBoardCoordinatorSettings.isIntegrationEnabled() else {
            refresh()
            return
        }
        // What this tick is actually for: whether an agent is printing changes
        // with nothing published at all.
        let working = Self.runningAgentNames()
        if workingAssignees != working { workingAssignees = working }
        refreshDelegationPanel()
        keepSelectionValid()
    }

    /// Agent names that are printing right now, by the task they hold. The
    /// board's own status comes from the task board, which cannot tell work in
    /// progress from work not yet begun; this is what closes that gap.
    /// Derived, not computed.
    ///
    /// These three used to be computed properties, and the panel read them from
    /// inside its body — `tasks` five times per pass plus twice per row (through
    /// `selectedTask`), and `isWorking` once per row. Each read re-sorted the
    /// board, re-filtered the queue, or walked every team's agent dictionaries
    /// through `TeamOrchestrator.listTeams()`. With ten agents on a board of N
    /// tasks that is O(N) subsystem walks and ~2N sorts to draw one frame, all
    /// of it repeated on every streamed delta that dirtied the graph.
    ///
    /// They change only when the snapshot or the team roster does, so they are
    /// settled there instead — once per refresh, not once per read.
    @Published private(set) var tasks: [ReviewBoardTask] = []
    @Published private(set) var pendingMergeQueue: [ReviewBoardMergeQueueItem] = []
    @Published private(set) var workingAssignees: Set<String> = []

    func isWorking(_ task: ReviewBoardTask) -> Bool {
        guard let assignee = task.assignee else { return false }
        return workingAssignees.contains(assignee)
    }

    /// Cheap: a lookup in the already-sorted list, no sort of its own.
    var selectedTask: ReviewBoardTask? {
        if let selectedTaskID,
           let task = tasks.first(where: { $0.id == selectedTaskID }) {
            return task
        }
        return tasks.first
    }

    func refresh() {
        // Same reason the service gates its own publish: the ticker calls this
        // on a fixed beat, and re-publishing an unchanged board costs a
        // re-evaluation and the layout pass under it for nothing. Selection is
        // still revalidated — it can go stale for reasons other than a new
        // snapshot, such as the selected task leaving the list.
        let next = snapshotProvider()
        if snapshot != next {
            snapshot = next
            rebuildDerivedSnapshotState()
        }
        // The roster moves on its own beat — an agent starts printing without
        // the board changing — so this is refreshed every tick regardless, and
        // gated on inequality so an unchanged roster publishes nothing.
        let working = Self.runningAgentNames()
        if workingAssignees != working { workingAssignees = working }
        // Same beat as the roster: the level can change from the sidebar sheet
        // or a socket call, and whether a worker is idle changes with nothing
        // published at all.
        refreshDelegationPanel()
        keepSelectionValid()
    }

    /// Re-derive everything that is a pure function of `snapshot`.
    private func rebuildDerivedSnapshotState() {
        tasks = snapshot.tasks.sorted { lhs, rhs in
            let lhsRank = statusRank(lhs.status)
            let rhsRank = statusRank(rhs.status)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return (lhs.updatedAt ?? "") > (rhs.updatedAt ?? "")
        }
        pendingMergeQueue = snapshot.mergeQueue
            .filter { $0.isPending || $0.isFailed }
            .sorted { ($0.approvedAt ?? "") > ($1.approvedAt ?? "") }
    }

    /// Agent names that are printing right now. The board's own status comes
    /// from the task board, which cannot tell work in progress from work not
    /// yet begun; this is what closes that gap.
    private static func runningAgentNames() -> Set<String> {
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
    ///
    /// A second read for a *different* task supersedes the one in flight rather
    /// than being refused. Refusing it was the bug: the panel starts a read from
    /// `.task(id: task.rawID)`, which fires once per id, so a read dropped
    /// because another was out had nothing left to retrigger it — the newly
    /// selected task sat with no review, no spinner, and no way back short of
    /// selecting something else and returning.
    func loadReview(for task: ReviewBoardTask, force: Bool = false) async {
        guard force || reviewedTaskID != task.rawID else { return }
        // A decision owns the model while it is landing; reading under it would
        // race the approval it is about to invalidate.
        guard !decisionInFlight else { return }
        // Already reading this one. Not `actionInFlight`, which is true for any
        // task's read.
        guard loadingTaskID != task.rawID else { return }
        loadingTaskID = task.rawID
        actionInFlight = true
        actionError = nil
        let result = await actions.review(task)
        // Superseded while this read was out: a newer read owns both the model
        // and the in-flight flag, and clearing either here would cut its
        // spinner short and let this stale result land after it.
        guard loadingTaskID == task.rawID else { return }
        loadingTaskID = nil
        actionInFlight = false
        // The selection can move without a new read starting; a result for a
        // task nobody is looking at must not replace what is on screen.
        guard selectedTaskID == nil || task.id == selectedTaskID else { return }
        reviewedTaskID = task.rawID
        review = result
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
        decisionInFlight = true
        actionError = nil
        do {
            try await body(review)
            // The task has moved on, so what was read no longer describes it.
            // Dropping it forces the next look to re-read rather than offer a
            // second decision on a decided task.
            reviewedTaskID = nil
            self.review = nil
            decisionInFlight = false
            actionInFlight = false
            refresh()
            return true
        } catch {
            actionError = Self.message(for: error)
            decisionInFlight = false
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
        guard id != selectedTaskID else { return }
        selectedTaskID = id
        // What was read belongs to the task that was selected. Both go
        // together: dropping the review without dropping `reviewedTaskID`
        // would leave the next read refused as "already in hand" and the panel
        // blank for good.
        dropLoadedReview()
        UserDefaults.standard.set(id, forKey: ReviewBoardSettings.selectedTaskIDKey)
    }

    /// Forget what is on screen, so the next look reads afresh.
    private func dropLoadedReview() {
        review = nil
        reviewedTaskID = nil
    }

    // MARK: - Work distribution

    /// How much of the Project in view its leader hands to workers, plus the
    /// roster that decision is about.
    ///
    /// Keyed to the workspace on screen rather than to the task list. Auto
    /// Pilot infers its team from `snapshot.tasks.first`, which is fine for a
    /// control you reach for once work exists — but this is the setting you
    /// want *before* the first task, and inferring it from tasks would leave it
    /// unreachable on exactly the board that shows "Nothing assigned yet".
    struct DelegationPanel: Equatable {
        var teamName: String
        var level: ProjectDelegationLevel
        var pending: ProjectDelegationLevel?
        var options: ProjectExecutionOptions
        var workerCount: Int
        var workingCount: Int
        var isRemoteViewer = false
        /// The three inputs `overlapCanaryStatus` needs besides the health
        /// reading, read fresh from the same sources `controlPayload` uses so
        /// the status line cannot claim a reason the gate does not share.
        var supportedLeader = false
        var killSwitch = false
        var canaryOptIn = false

        var idleCount: Int { max(0, workerCount - workingCount) }
        /// The state this whole feature exists to make visible: a roster that
        /// is present, and doing nothing.
        var everyWorkerIdle: Bool { workerCount > 0 && workingCount == 0 }
    }

    /// What the Overlap canary status line has to explain, in gate order.
    /// `.checking` is the state before the first health read resolves: the
    /// local read for a `.local` leader (`refreshLocalOverlapHealthIfNeeded`),
    /// or the remote SSH read for a `.peer` leader
    /// (`refreshRemoteOverlapHealthIfNeeded`). Peer teams never read this
    /// Mac's health — their reading comes only from
    /// `parseRemoteLeaderHealth`, scoped `.remoteProject`.
    enum OverlapHealthReading: Equatable {
        enum Scope: Equatable {
            case thisMac
            case remoteProject(String)
        }

        case checking
        case measured(
            supportedTurns: Int, observedDays: Int, coverage: Double, linkage: Double,
            unknownRate: Double, malformedLines: Int?, passesGate: Bool, scope: Scope
        )
        case notReported
        case unavailable(String)
    }

    /// What the Delegation area shows for the Overlap canary: one line
    /// stating the first blocking reason (or Ready), and — only once a health
    /// reading names a scope — a caption stating whose turns it counted.
    struct OverlapCanaryStatus: Equatable {
        let line: String
        let scopeCaption: String?
    }

    /// Pure and fed by exactly the inputs `controlPayload` uses
    /// (`delegationState.effective`, `leaderMeasurementCapability(for:) ==
    /// .supported`, `settings.killSwitch`), so a passing gate and a Ready line
    /// cannot drift apart. It only explains a result; it never recomputes
    /// one — `reading.passesGate` already came from
    /// `Health.passesPromotionGate` (local) or the remote's
    /// `passes_promotion_gate` (peer, from the same Rust function the
    /// read-only tm-agent health command wraps).
    ///
    /// Returns a plain `String`, not `Text`: the gate order branches through
    /// several templates with runtime-computed numbers, which the
    /// `Text("literal \(x)")` catalog trick cannot express outside a View.
    /// `LanguageSettings.localized` is this codebase's established way to
    /// reach the string catalog from exactly that situation (see
    /// `AgentRunbookSettingsView.swift`'s `sourceSummary` and siblings).
    static func overlapCanaryStatus(
        level: ProjectDelegationLevel,
        supportedLeader: Bool,
        killSwitch: Bool,
        reading: OverlapHealthReading,
        defaults: UserDefaults = .standard
    ) -> OverlapCanaryStatus {
        guard level == .delegated else {
            return catalogLine("Off", "Work Distribution is not Delegated", defaults: defaults)
        }
        guard supportedLeader else {
            return catalogLine("Off", "Leader turns are not measured", defaults: defaults)
        }
        guard !killSwitch else {
            return catalogLine("Off", "Kill switch is on", defaults: defaults)
        }
        switch reading {
        case .checking:
            return catalogLine("Checking", "Measuring leader turn health", defaults: defaults)
        case .notReported:
            return catalogLine("Unknown", "Remote does not report health", defaults: defaults)
        case let .unavailable(reason):
            let detail = String(
                format: LanguageSettings.localized("Remote health unavailable: %@", defaults: defaults),
                reason
            )
            return OverlapCanaryStatus(
                line: LanguageSettings.localized("Unknown", defaults: defaults) + " · " + detail,
                scopeCaption: nil
            )
        case let .measured(
            supportedTurns, observedDays, coverage, linkage, unknownRate, malformedLines, passesGate, scope
        ):
            let caption = scopeCaption(scope, defaults: defaults)
            guard passesGate else {
                let detail = waitingDetail(
                    supportedTurns: supportedTurns, observedDays: observedDays,
                    coverage: coverage, linkage: linkage, unknownRate: unknownRate,
                    malformedLines: malformedLines, defaults: defaults
                )
                return OverlapCanaryStatus(
                    line: LanguageSettings.localized("Waiting", defaults: defaults) + " · " + detail,
                    scopeCaption: caption
                )
            }
            let readyDetail = LanguageSettings.localized(
                "Applies to a turn only when the leader reports isolated, disjoint work",
                defaults: defaults
            )
            return OverlapCanaryStatus(
                line: LanguageSettings.localized("Ready", defaults: defaults) + " · " + readyDetail,
                scopeCaption: caption
            )
        }
    }

    private static func catalogLine(
        _ prefix: String, _ detail: String, defaults: UserDefaults
    ) -> OverlapCanaryStatus {
        OverlapCanaryStatus(
            line: LanguageSettings.localized(prefix, defaults: defaults) + " · "
                + LanguageSettings.localized(detail, defaults: defaults),
            scopeCaption: nil
        )
    }

    private static func scopeCaption(
        _ scope: OverlapHealthReading.Scope, defaults: UserDefaults
    ) -> String {
        switch scope {
        case .thisMac:
            return LanguageSettings.localized("Measured on this Mac across all Projects", defaults: defaults)
        case let .remoteProject(host):
            return String(
                format: LanguageSettings.localized("Measured on %@ for this Project", defaults: defaults),
                host
            )
        }
    }

    /// Malformed lines outrank every ratio — they mean the count itself is
    /// suspect. Otherwise: the unmet volume part, then the first failing
    /// ratio in gate order (coverage, linkage, unknown routes). Percentages
    /// are floor-rounded so a value just under a threshold cannot print as
    /// the threshold itself. A gate failure with no displayed part failing
    /// (thresholds shared with `passesPromotionGate` disagreeing on the exact
    /// same inputs) falls back to a generic line rather than implying a
    /// reason that is not there.
    private static func waitingDetail(
        supportedTurns: Int, observedDays: Int, coverage: Double, linkage: Double,
        unknownRate: Double, malformedLines: Int?, defaults: UserDefaults
    ) -> String {
        if let malformedLines, malformedLines > 0 {
            return String(
                format: LanguageSettings.localized("%@ malformed log lines (needs 0)", defaults: defaults),
                String(malformedLines)
            )
        }
        let minTurns = LeaderParticipationSettings.Health.minPromotableTurns
        let minDays = LeaderParticipationSettings.Health.minPromotableObservedDays
        let minCoverage = LeaderParticipationSettings.Health.minPromotableCoverage
        let minLinkage = LeaderParticipationSettings.Health.minPromotableLinkage
        let maxUnknownRate = LeaderParticipationSettings.Health.maxPromotableUnknownRate

        var parts: [String] = []
        if supportedTurns < minTurns, observedDays < minDays {
            parts.append(String(
                format: LanguageSettings.localized("%@/%@ turns or %@/%@ days", defaults: defaults),
                String(supportedTurns), String(minTurns), String(observedDays), String(minDays)
            ))
        }
        if coverage < minCoverage {
            parts.append(String(
                format: LanguageSettings.localized("coverage %@%% (needs %@%%)", defaults: defaults),
                String(floorPercent(coverage)), String(floorPercent(minCoverage))
            ))
        } else if linkage < minLinkage {
            parts.append(String(
                format: LanguageSettings.localized("linkage %@%% (needs %@%%)", defaults: defaults),
                String(floorPercent(linkage)), String(floorPercent(minLinkage))
            ))
        } else if unknownRate > maxUnknownRate {
            parts.append(String(
                format: LanguageSettings.localized("unknown routes %@%% (needs %@%% or less)", defaults: defaults),
                String(floorPercent(unknownRate)), String(floorPercent(maxUnknownRate))
            ))
        }
        guard !parts.isEmpty else {
            return LanguageSettings.localized("Health gate not passed", defaults: defaults)
        }
        return parts.joined(separator: " · ")
    }

    private static func floorPercent(_ value: Double) -> Int {
        Int((value * 100).rounded(.down))
    }

    // MARK: - Peer leader health over SSH

    /// The remote command line for `refreshRemoteOverlapHealthIfNeeded`,
    /// built so a tm-agent failure lands in the script's own stdout instead
    /// of throwing `sshFailed`: the script itself always exits 0, and `rc=`
    /// carries tm-agent's real exit status for `parseRemoteLeaderHealth` to
    /// read. Both arguments pass through `TeamOrchestrator.shellQuoted`
    /// before this runs inside `RemotePasteTransfer.serviceAccountCommand`,
    /// which quotes the whole body again for its own `/bin/sh -c`.
    static func remoteLeaderHealthScript(tmAgent: String, project: String) -> String {
        let quotedAgent = TeamOrchestrator.shellQuoted(tmAgent)
        let quotedProject = TeamOrchestrator.shellQuoted(project)
        return "out=$(\(quotedAgent) leader turn health --project \(quotedProject) --json 2>&1); "
            + "rc=$?; printf 'rc=%s\\n' \"$rc\"; printf '%s\\n' \"$out\""
    }

    /// The exact stderr clap prints for an execution host whose tm-agent
    /// predates the `leader turn health` subcommand (observed on tm-agent
    /// 0.242.0). Matched literally rather than by rc alone, so an rc 2 from
    /// some other cause — a bad flag, say — falls through to the generic
    /// "exited <rc>" reading instead of being read as "does not report
    /// health".
    private static let unrecognizedHealthSubcommandText = "unrecognized subcommand 'health'"

    /// Turns one `remoteLeaderHealthScript` transcript into a reading. Pure
    /// over the captured text so every rc and body shape below is fixed by a
    /// test instead of a live SSH round trip. `output` never reaches here for
    /// a thrown SSH error — the caller reports that directly, since the
    /// script never ran far enough to print an `rc=` line.
    static func parseRemoteLeaderHealth(
        output: String, project: String, host: String
    ) -> OverlapHealthReading {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first, statusLine.hasPrefix("rc="),
              let rc = Int(statusLine.dropFirst(3))
        else {
            return .unavailable("invalid response")
        }
        let body = lines.dropFirst().joined(separator: "\n")
        switch rc {
        case 0:
            return parseRemoteLeaderHealthReport(body, project: project, host: host)
        case 2 where body.contains(unrecognizedHealthSubcommandText):
            return .notReported
        case 127:
            return .unavailable("tm-agent not found on remote")
        default:
            return .unavailable("remote tm-agent exited \(rc)")
        }
    }

    /// Fields read straight off the `leader turn health --json` report
    /// (`leader_turn_health_report` in tm_agent.rs). Any field this reading
    /// needs that is absent, mistyped, or the report of another Project
    /// fails decoding or the match below, so a partial number can never
    /// reach the board.
    private struct RemoteLeaderHealthReport: Decodable {
        let project: String
        let supportedTurns: Int
        let observedDays: Int
        let coverage: Double
        let linkage: Double
        let unknownRate: Double
        let malformedLines: Int
        let passesPromotionGate: Bool

        private enum CodingKeys: String, CodingKey {
            case project
            case supportedTurns = "supported_turns"
            case observedDays = "observed_days"
            case coverage
            case linkage
            case unknownRate = "unknown_rate"
            case malformedLines = "malformed_lines"
            case passesPromotionGate = "passes_promotion_gate"
        }
    }

    private static func parseRemoteLeaderHealthReport(
        _ body: String, project: String, host: String
    ) -> OverlapHealthReading {
        guard let data = body.data(using: .utf8),
              let report = try? JSONDecoder().decode(RemoteLeaderHealthReport.self, from: data),
              report.project == project
        else {
            return .unavailable("invalid health response")
        }
        return .measured(
            supportedTurns: report.supportedTurns, observedDays: report.observedDays,
            coverage: report.coverage, linkage: report.linkage, unknownRate: report.unknownRate,
            malformedLines: report.malformedLines, passesGate: report.passesPromotionGate,
            scope: .remoteProject(host)
        )
    }

    /// The first line of an error description, for a thrown SSH failure
    /// whose detail can carry a joined stdout/stderr blob
    /// (`PeerHostReadinessError.sshFailed`). One line is enough to name what
    /// happened without spilling a multi-line transcript into the status row.
    private static func firstLine(of message: String) -> String {
        guard let newline = message.firstIndex(of: "\n") else { return message }
        return String(message[..<newline])
    }

    private static let remoteOverlapHealthThrottleSeconds: TimeInterval = 60

    /// The 60 s-per-team throttle for `refreshRemoteOverlapHealthIfNeeded`,
    /// pulled out pure so its edges — exactly 60 s, and an in-flight fetch
    /// overriding any elapsed time — are fixed by a test. A failed attempt
    /// does not reset `lastAttempt`: the caller records it once, before the
    /// SSH round trip starts, and never rewrites it afterward, so a
    /// repeatedly failing host is retried no faster than a healthy one.
    static func shouldFetchRemoteLeaderHealth(
        lastAttempt: Date?, now: Date, inFlight: Bool
    ) -> Bool {
        guard !inFlight else { return false }
        return now.timeIntervalSince(lastAttempt ?? .distantPast) >= remoteOverlapHealthThrottleSeconds
    }

    struct CollaborationPanel: Equatable {
        let state: LeaderTurnLog.CollaborationState
        let title: String
        let detail: String
        /// The headline compressed to fit a folded section header, where the
        /// full title would crowd out the level and the roster beside it.
        let shortState: String
        let symbolName: String
        let workerCount: Int
        let dispatchCount: Int
        let completionCount: Int
        let lastActivity: String?
        /// Read from the live presentation, not the turn log: dispatch history
        /// keeps the evidence `healthy` after a daemon restart killed every worker.
        var workerRepairNeeded = false
    }

    /// Leader presentation states are left to the leader's own recovery, so a
    /// relay reconnect does not flash Repair.
    static func presentationNeedsWorkerRepair(
        _ state: TeamOrchestrator.CollaborationPresentationState
    ) -> Bool {
        switch state {
        case .agentPanelMissing, .agentSessionUnavailable:
            return true
        case .ready, .teamMissing, .workspaceMissing,
             .leaderPanelMissing, .leaderSessionUnavailable:
            return false
        }
    }

    static func shouldShowCollaborationRepair(
        state: LeaderTurnLog.CollaborationState,
        workerCount: Int,
        workerRepairNeeded: Bool
    ) -> Bool {
        workerCount > 0 && (state != .healthy || workerRepairNeeded)
    }

    enum CollaborationRepairOutcome: Equatable {
        case idle
        case running
        case verified(String)
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    /// Where the board's Project comes from, injected the way the snapshot is.
    ///
    /// A pushed value loses the race with workspace restore — at launch there
    /// is no selection yet, and if it never changes afterwards nothing pushes
    /// again and the section stays hidden all session. Pulling it on the same
    /// beat as everything else cannot go stale that way.
    func setActiveTeamProvider(_ provider: @escaping @MainActor () -> String?) {
        activeTeamProvider = provider
        refreshDelegationPanel()
    }

    func setRemoteContextProvider(
        _ provider: @escaping @MainActor () -> RemoteLiveProject.BoardContext?
    ) {
        remoteContextProvider = provider
        refreshDelegationPanel()
    }

    func setActiveTeam(_ teamName: String?) {
        guard activeTeamName != teamName else { return }
        activeTeamName = teamName
        if !collaborationRepairInFlight { collaborationRepairOutcome = .idle }
        refreshDelegationPanel()
    }

    func workspaceSelectionDidChange() {
        delegationRequestGeneration &+= 1
        delegationChangeInFlight = false
        delegationError = nil
        refreshDelegationPanel()
    }

    func setDelegationLevel(_ level: ProjectDelegationLevel) {
        guard let panel = delegation else { return }
        if panel.isRemoteViewer {
            guard let context = remoteContextProvider() else {
                delegationChangeInFlight = false
                delegationError = RemoteLiveProject.DelegationError.staleViewer.localizedDescription
                return
            }
            delegationRequestGeneration &+= 1
            let generation = delegationRequestGeneration
            delegationChangeInFlight = true
            delegationError = nil
            Task { [weak self] in
                do {
                    _ = try await RemoteLiveProject.setDelegationLevel(
                        workspaceID: context.workspaceID, level: level
                    )
                } catch {
                    guard self?.delegationRequestGeneration == generation else { return }
                    self?.delegationError = error.localizedDescription
                }
                guard self?.delegationRequestGeneration == generation else { return }
                self?.delegationChangeInFlight = false
                self?.refreshDelegationPanel()
            }
            return
        }
        let teamName = panel.teamName
        delegationError = nil
        _ = TeamOrchestrator.shared.setProjectDelegationLevel(teamName: teamName, level: level)
        refreshDelegationPanel()
    }

    func setMaxParallelWorkers(_ count: Int) {
        updateExecutionOptions { $0.maxParallelWorkers = count }
    }

    func setInjectDirective(_ enabled: Bool) {
        updateExecutionOptions { $0.injectDirective = enabled }
    }

    /// Options live in defaults and reach the leader through its control file,
    /// so a write is only half the change — the file has to be rewritten too,
    /// or the hook keeps reading the values from before.
    private func updateExecutionOptions(_ mutate: (inout ProjectExecutionOptions) -> Void) {
        guard let teamName = delegation?.teamName else { return }
        var options = ProjectExecutionOptions.load(teamName: teamName)
        mutate(&options)
        options.save(teamName: teamName)
        TeamOrchestrator.shared.refreshLeaderParticipationControls()
        refreshDelegationPanel()
    }

    private func refreshDelegationPanel() {
        let resolved = activeTeamProvider() ?? activeTeamName
        if activeTeamName != resolved {
            activeTeamName = resolved
            if !collaborationRepairInFlight { collaborationRepairOutcome = .idle }
        }
        let next = Self.delegationPanel(for: resolved)
            ?? remoteContextProvider().map { context in
                DelegationPanel(
                    teamName: context.teamName,
                    level: context.delegationState.effective,
                    pending: context.delegationState.pending,
                    options: .default, workerCount: context.workerCount,
                    workingCount: 0, isRemoteViewer: true
                )
            }
        if delegation != next { delegation = next }
        let nextCollaboration = Self.collaborationPanel(
            for: resolved,
            remoteRecords: resolved.flatMap { remoteCollaborationRecords[$0] } ?? []
        )
        if collaboration != nextCollaboration { collaboration = nextCollaboration }
        // Read only the dictionary matching the team's *current*
        // `leaderEndpoint`, rather than falling back from local to remote: a
        // Project whose leader moved from this Mac to a peer (or back) keeps
        // its old dictionary entry around with nothing to clear it, and
        // reading both indiscriminately could surface that stale,
        // wrong-scoped reading — this Mac's health captioned onto a team
        // that is now a peer's, or the reverse.
        let nextOverlapHealthReading: OverlapHealthReading = resolved.flatMap { name in
            switch TeamOrchestrator.shared.teams[name]?.leaderEndpoint {
            case .local: return localOverlapHealthReadings[name]
            case .peer: return remoteOverlapHealthReadings[name]
            case nil: return nil
            }
        } ?? .checking
        if overlapHealthReading != nextOverlapHealthReading { overlapHealthReading = nextOverlapHealthReading }
        refreshRemoteCollaborationIfNeeded(for: resolved)
        refreshLocalOverlapHealthIfNeeded(for: resolved)
        refreshRemoteOverlapHealthIfNeeded(for: resolved)
    }

    /// Include or drop this Project from the canary opt-in set. Goes through
    /// the one shared save path used by Settings and the debug socket method,
    /// so a stale Settings snapshot elsewhere cannot overwrite this write, or
    /// vice versa.
    func setCanaryOptIn(_ included: Bool, teamName: String) {
        TeamOrchestrator.shared.updateLeaderParticipationSettings { settings in
            if included {
                settings.optInProjects.insert(teamName)
            } else {
                settings.optInProjects.remove(teamName)
            }
        }
        refreshDelegationPanel()
    }

    private static let localOverlapHealthThrottleSeconds: TimeInterval = 10

    /// Only `.local` leaders read this Mac's turns.log — a peer leader's
    /// Overlap canary reason must never come from an aggregate this Mac
    /// cannot vouch for. Gated on the same three checks the status line
    /// shows first, so a team that would show "Off" never pays for a read
    /// whose result nothing displays.
    ///
    /// `LeaderTurnLog.health()` reads the log file synchronously, so this
    /// runs inside a detached task rather than the plain `Task` the
    /// collaboration fetch above uses: a plain `Task` created from this
    /// MainActor-isolated method still runs on the main actor until its first
    /// `await`, which would put the file read back on the main thread.
    private func refreshLocalOverlapHealthIfNeeded(for teamName: String?) {
        guard let teamName, let panel = delegation, panel.teamName == teamName, !panel.isRemoteViewer,
              panel.level == .delegated, panel.supportedLeader, !panel.killSwitch,
              let team = TeamOrchestrator.shared.teams[teamName],
              team.leaderEndpoint == .local,
              localOverlapHealthFetches[teamName] == nil,
              Date().timeIntervalSince(localOverlapHealthFetchedAt[teamName] ?? .distantPast)
                >= Self.localOverlapHealthThrottleSeconds
        else { return }
        let expectedUUID = team.teamUuid
        localOverlapHealthFetchedAt[teamName] = Date()
        localOverlapHealthFetches[teamName] = Task.detached { [weak self] in
            let measurement = LeaderTurnLog.health(team: teamName)
            let health = LeaderParticipationSettings.Health(measurement: measurement)
            let reading = OverlapHealthReading.measured(
                supportedTurns: health.supportedTurns, observedDays: health.observedDays,
                coverage: health.coverage, linkage: health.linkage, unknownRate: health.unknownRate,
                // This Mac's gate now refuses a damaged measurement exactly as the
                // execution-host gate does, so the count is a reason to show.
                malformedLines: health.malformedLines, passesGate: health.passesPromotionGate,
                scope: .thisMac
            )
            await self?.publishLocalOverlapHealthReading(reading, teamName: teamName, expectedUUID: expectedUUID)
        }
    }

    /// Same publish guard the remote collaboration fetch uses: a reading for
    /// a team that has been recreated under the same name (new `teamUuid`),
    /// or that is no longer the active team, must not land on screen.
    private func publishLocalOverlapHealthReading(
        _ reading: OverlapHealthReading, teamName: String, expectedUUID: String?
    ) {
        localOverlapHealthFetches[teamName] = nil
        guard TeamOrchestrator.shared.teams[teamName]?.teamUuid == expectedUUID else { return }
        localOverlapHealthReadings[teamName] = reading
        guard Self.shouldPublishRemoteCollaboration(
            fetchedTeam: teamName, activeTeam: activeTeamProvider() ?? activeTeamName
        ) else { return }
        overlapHealthReading = reading
    }

    /// Only `.peer` leaders reach here — the counterpart to
    /// `refreshLocalOverlapHealthIfNeeded` above, and the only place a peer
    /// team's Overlap canary reading comes from. Gated on the same three
    /// checks the status line shows first, so a team that would show "Off"
    /// never pays for an SSH round trip whose result nothing displays, plus
    /// `ReviewBoardSettings.isVisible` and `shouldFetchRemoteLeaderHealth`'s
    /// 60 s-per-team throttle.
    ///
    /// `lastAttempt` is recorded once, right here, before the SSH round trip
    /// starts — not in the completion handler — so a failure never resets the
    /// clock the way the collaboration fetch's failure path does.
    /// `PeerHostReadinessChecker.runScript` is already `async`, so the plain
    /// `Task` below never blocks the main actor waiting on it.
    private func refreshRemoteOverlapHealthIfNeeded(for teamName: String?) {
        guard let teamName, let panel = delegation, panel.teamName == teamName, !panel.isRemoteViewer,
              panel.level == .delegated, panel.supportedLeader, !panel.killSwitch,
              let team = TeamOrchestrator.shared.teams[teamName],
              case let .peer(hostKey) = team.leaderEndpoint,
              ReviewBoardSettings.isVisible,
              Self.shouldFetchRemoteLeaderHealth(
                  lastAttempt: remoteOverlapHealthFetchedAt[teamName], now: Date(),
                  inFlight: remoteOverlapHealthFetches[teamName] != nil
              ),
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              let sshTarget = host.sshTarget, !sshTarget.isEmpty
        else { return }
        let expectedUUID = team.teamUuid
        let hostDisplayName = host.displayName
        let sshPort = host.sshPort
        let identityFile = host.identityFile
        let tmAgent = TeamOrchestrator.remoteTMAgentCommand(hostCLIBinDirs: host.hostCLIBinDirs)
        let script = RemotePasteTransfer.serviceAccountCommand(
            Self.remoteLeaderHealthScript(tmAgent: tmAgent, project: teamName)
        )
        remoteOverlapHealthFetchedAt[teamName] = Date()
        remoteOverlapHealthFetches[teamName] = Task { [weak self] in
            let reading: OverlapHealthReading
            do {
                let output = try await PeerHostReadinessChecker.runScript(
                    sshTarget: sshTarget, port: sshPort, identityFile: identityFile,
                    script: script, timeoutSeconds: 10
                )
                reading = Self.parseRemoteLeaderHealth(output: output, project: teamName, host: hostDisplayName)
            } catch {
                reading = .unavailable(Self.firstLine(of: error.localizedDescription))
            }
            await self?.publishRemoteOverlapHealthReading(reading, teamName: teamName, expectedUUID: expectedUUID)
        }
    }

    /// Same publish guard `publishLocalOverlapHealthReading` uses: a reading
    /// for a team that has been recreated under the same name, or that is no
    /// longer the active team, must not land on screen.
    private func publishRemoteOverlapHealthReading(
        _ reading: OverlapHealthReading, teamName: String, expectedUUID: String?
    ) {
        remoteOverlapHealthFetches[teamName] = nil
        guard TeamOrchestrator.shared.teams[teamName]?.teamUuid == expectedUUID else { return }
        remoteOverlapHealthReadings[teamName] = reading
        guard Self.shouldPublishRemoteCollaboration(
            fetchedTeam: teamName, activeTeam: activeTeamProvider() ?? activeTeamName
        ) else { return }
        overlapHealthReading = reading
    }

    private static func delegationPanel(for teamName: String?) -> DelegationPanel? {
        guard let teamName, !teamName.isEmpty,
              let team = TeamOrchestrator.shared.teams[teamName] else { return nil }
        let rosterNames = Set(team.agents.map(\.name))
        let working = runningAgentNames().intersection(rosterNames)
        let settings = LeaderParticipationSettings.load(
            from: LeaderParticipationSettings.defaultsForCurrentProcess()
        )
        return DelegationPanel(
            teamName: teamName,
            level: team.delegationState.effective,
            pending: team.delegationState.pending,
            options: ProjectExecutionOptions.load(teamName: teamName),
            workerCount: team.agents.count,
            workingCount: working.count,
            supportedLeader: TeamOrchestrator.shared.leaderMeasurementCapability(for: team) == .supported,
            killSwitch: settings.killSwitch,
            canaryOptIn: settings.optInProjects.contains(teamName)
        )
    }

    private static func collaborationPanel(
        for teamName: String?, remoteRecords: [LeaderTurnLog.Record]
    ) -> CollaborationPanel? {
        guard let teamName, !teamName.isEmpty,
              let team = TeamOrchestrator.shared.teams[teamName] else { return nil }
        let records = LeaderTurnLog.readRecent(team: teamName) + remoteRecords
        let leaderSurfaceID = team.remoteLeaderSurfaceID?.map {
            String(format: "%02x", $0)
        }.joined()
        var panel = collaborationPanel(summary: LeaderTurnLog.collaborationSummary(
            records: records, team: teamName, teamUUID: team.teamUuid,
            leaderSessionID: team.leaderSessionId, leaderSurfaceID: leaderSurfaceID,
            workerCount: team.agents.count
        ))
        panel.workerRepairNeeded = presentationNeedsWorkerRepair(
            TeamOrchestrator.shared.collaborationPresentationState(
                teamName: teamName, requireLiveSessions: true, ignoringLeader: true
            )
        )
        return panel
    }

    /// Peer leader turns are written on the execution host while task events
    /// are written on this control host. Read only the bounded remote tail and
    /// combine both streams before deriving collaboration health.
    private func refreshRemoteCollaborationIfNeeded(for teamName: String?) {
        guard let teamName, let team = TeamOrchestrator.shared.teams[teamName],
              case let .peer(hostKey) = team.leaderEndpoint,
              remoteCollaborationFetches[teamName] == nil,
              ReviewBoardSettings.isVisible,
              Date().timeIntervalSince(remoteCollaborationFetchedAt[teamName] ?? .distantPast) >= 10,
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return }
        let expectedUUID = team.teamUuid
        remoteCollaborationFetchedAt[teamName] = Date()
        remoteCollaborationFetches[teamName] = Task { [weak self] in
            let loop = "for line in f:\n"
                + " try:\n  row=json.loads(line)\n except Exception:\n  continue\n"
                + " if isinstance(row,dict) and row.get('team')==team:\n  q.append(line)\n"
            let filter = "import collections,json,sys; q=collections.deque(maxlen=200); "
                + "f=open(sys.argv[1],encoding='utf-8'); team=sys.argv[2]; "
                + "exec(" + String(reflecting: loop) + "); sys.stdout.writelines(q)"
            let body = "f=\"$HOME/.term-mesh/logs/turns.log\"; "
                + "if [ -r \"$f\" ]; then python3 -c "
                + TeamOrchestrator.shellQuoted(filter) + " \"$f\" "
                + TeamOrchestrator.shellQuoted(teamName) + "; fi"
            let output = try? await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget, port: host.sshPort, identityFile: host.identityFile,
                script: RemotePasteTransfer.serviceAccountCommand(body), timeoutSeconds: 10
            )
            guard let self else { return }
            self.remoteCollaborationFetches[teamName] = nil
            guard TeamOrchestrator.shared.teams[teamName]?.teamUuid == expectedUUID,
                  let output else {
                self.remoteCollaborationFetchedAt[teamName] = .distantPast
                return
            }
            self.remoteCollaborationRecords[teamName] = LeaderTurnLog.readAll(from: output)
            guard Self.shouldPublishRemoteCollaboration(
                fetchedTeam: teamName,
                activeTeam: self.activeTeamProvider() ?? self.activeTeamName
            ) else {
                return
            }
            let next = Self.collaborationPanel(
                for: teamName, remoteRecords: self.remoteCollaborationRecords[teamName] ?? []
            )
            if self.collaboration != next { self.collaboration = next }
        }
    }

    static func shouldPublishRemoteCollaboration(
        fetchedTeam: String,
        activeTeam: String?
    ) -> Bool {
        fetchedTeam == activeTeam
    }

    static func shouldStartCollaborationRepair(
        isRunning: Bool,
        teamName: String?
    ) -> Bool {
        !isRunning && teamName != nil
    }

    static func shouldPublishCollaborationRepair(
        repairedTeam: String,
        activeTeam: String?
    ) -> Bool {
        repairedTeam == activeTeam
    }

    static func collaborationRepairOutcome(
        succeeded: Bool,
        message: String
    ) -> CollaborationRepairOutcome {
        succeeded ? .verified(message) : .failed(message)
    }

    static func collaborationPanel(
        summary: LeaderTurnLog.CollaborationSummary
    ) -> CollaborationPanel {
        let title: String
        let detail: String
        let short: String
        let symbol: String
        // The state is decided by the newest decisive record in the window,
        // while the counts below it total the whole window. Read as one claim
        // they contradict each other: a Project can show "no dispatch" over
        // four dispatches, because the newest record is a turn that delegated
        // nothing. Every string here names which of the two it speaks for.
        switch summary.state {
        case .healthy:
            title = "Latest evidence: dispatched"
            detail = "Workers received tasks, and nothing since then failed."
            short = "dispatching"
            symbol = "checkmark.circle.fill"
        case .leaderOnly:
            title = "Latest evidence: no dispatch"
            detail = "The newest record is a stated route with no worker task after it."
            short = "no dispatch"
            symbol = "person.crop.circle.badge.exclamationmark"
        case .identityMismatch:
            title = "Identity mismatch"
            detail = "Recent evidence belongs to another Project viewer."
            short = "identity mismatch"
            symbol = "person.crop.circle.badge.xmark"
        case .routeFailure:
            title = "Latest evidence: route failure"
            detail = "A worker delivery or route failed after the last dispatch."
            short = "route failure"
            symbol = "exclamationmark.triangle.fill"
        case .unmeasured:
            title = "Collaboration unmeasured"
            detail = summary.legacyRecordCount > 0
                ? "Only legacy name-scoped records are available."
                : "No identity-scoped task evidence is available."
            short = "unmeasured"
            symbol = "questionmark.circle"
        }
        return CollaborationPanel(
            state: summary.state, title: title, detail: detail, shortState: short,
            symbolName: symbol,
            workerCount: summary.workerCount, dispatchCount: summary.dispatchCount,
            completionCount: summary.completionCount, lastActivity: summary.lastActivity
        )
    }

    func repairCollaboration() async {
        guard Self.shouldStartCollaborationRepair(
            isRunning: collaborationRepairInFlight,
            teamName: activeTeamName
        ), let teamName = activeTeamName else { return }
        collaborationRepairOutcome = .running
        let report = await TeamOrchestrator.shared.repairCollaboration(teamName: teamName)
        if Self.shouldPublishCollaborationRepair(
            repairedTeam: teamName,
            activeTeam: activeTeamProvider() ?? activeTeamName
        ) {
            collaborationRepairOutcome = Self.collaborationRepairOutcome(
                succeeded: report.succeeded,
                message: report.message
            )
        } else {
            collaborationRepairOutcome = .idle
        }
        remoteCollaborationFetchedAt[teamName] = .distantPast
        refreshDelegationPanel()
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
        let next = tasks.first?.id
        // The other way the selection moves. A task dropping off the board
        // leaves its review behind exactly as a click would, so it is dropped
        // here too — same reason as `selectTask`.
        if next != selectedTaskID { dropLoadedReview() }
        selectedTaskID = next
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
