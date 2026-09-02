import Foundation
import SwiftUI

enum ReviewBoardSettings {
    static let enabledKey = "reviewBoard.enabled"
    static let defaultEnabled = true
    static let widthKey = "reviewBoard.width"
    static let isClosedKey = "reviewBoard.isClosed"
    static let selectedTaskIDKey = "reviewBoard.selectedTaskID"

    /// Whether the board is on screen right now.
    ///
    /// Two keys decide it, and they mean different things: `enabled` is
    /// "this window has a board at all", `isClosed` is "I dismissed it". The
    /// close button only ever set the second, and nothing cleared it — so
    /// closing the board was a one-way door. Neither the Settings toggle nor
    /// anything else could bring it back, because flipping `enabled` leaves
    /// `isClosed` standing.
    ///
    /// One place decides now, and it writes both.
    static var isVisible: Bool {
        let defaults = UserDefaults.standard
        return isEnabled(defaults: defaults) && !defaults.bool(forKey: isClosedKey)
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func setVisible(_ visible: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(visible, forKey: enabledKey)
        defaults.set(!visible, forKey: isClosedKey)
    }

    static func toggleVisible() {
        setVisible(!isVisible)
    }
    static let defaultWidth: CGFloat = 320
    /// How narrow the board may be dragged.
    ///
    /// It was 320 — wide enough that the board was never a strip you keep at
    /// the edge, only a second column you make room for. Nothing in the panel
    /// needs that: no content sets a horizontal size, so titles and summaries
    /// wrap the whole way down. What survives at 200 is the part worth keeping
    /// at a glance — which task, whose, and its state — and anyone who wants
    /// the detail drags it back out.
    static let minimumWidth: CGFloat = 200
    static let maximumWidth: CGFloat = 560

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func loadWidth(defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: widthKey)
        guard stored > 0 else { return defaultWidth }
        return clampedWidth(CGFloat(stored))
    }

    static func saveWidth(_ width: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clampedWidth(width)), forKey: widthKey)
    }
}

extension Notification.Name {
    static let reviewBoardTaskSelected = Notification.Name("termMesh.reviewBoard.taskSelected")
    static let reviewBoardSnapshotDidChange = Notification.Name("termMesh.reviewBoard.snapshotDidChange")
}

enum ReviewBoardStatus: String, CaseIterable, Equatable, Sendable {
    case coordinatorOffline
    case memMeshUnavailable
    case suspectHost
    case fencedZombie
    case blocked
    case reviewReady
    case mergeFailed

    var title: String {
        switch self {
        case .coordinatorOffline: return "Coordinator Offline"
        case .memMeshUnavailable: return "mem-mesh Unavailable"
        case .suspectHost: return "Suspect Host"
        case .fencedZombie: return "Fenced Zombie"
        case .blocked: return "Blocked"
        case .reviewReady: return "Review Ready"
        case .mergeFailed: return "Merge Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .coordinatorOffline: return "antenna.radiowaves.left.and.right.slash"
        case .memMeshUnavailable: return "externaldrive.badge.xmark"
        case .suspectHost: return "exclamationmark.triangle"
        case .fencedZombie: return "lock.shield"
        case .blocked: return "hand.raised"
        case .reviewReady: return "checkmark.seal"
        case .mergeFailed: return "arrow.triangle.merge"
        }
    }

    var color: Color {
        switch self {
        case .coordinatorOffline, .memMeshUnavailable: return .secondary
        case .suspectHost, .blocked: return .orange
        case .fencedZombie, .mergeFailed: return .red
        case .reviewReady: return .green
        }
    }

    var accessibilityLabel: String {
        "\(title) state"
    }
}

struct ReviewBoardSnapshot: Equatable, Sendable {
    var tasks: [ReviewBoardTask]
    var panelRuns: [ReviewBoardPanelRun]
    var mergeQueue: [ReviewBoardMergeQueueItem]
    var coordinatorOnline: Bool
    var memMeshAvailable: Bool
    var suspectHost: Bool
    var fencedZombie: Bool

    init(
        tasks: [ReviewBoardTask],
        panelRuns: [ReviewBoardPanelRun],
        mergeQueue: [ReviewBoardMergeQueueItem] = [],
        coordinatorOnline: Bool,
        memMeshAvailable: Bool,
        suspectHost: Bool,
        fencedZombie: Bool
    ) {
        self.tasks = tasks
        self.panelRuns = panelRuns
        self.mergeQueue = mergeQueue
        self.coordinatorOnline = coordinatorOnline
        self.memMeshAvailable = memMeshAvailable
        self.suspectHost = suspectHost
        self.fencedZombie = fencedZombie
    }

    func mergeQueueItem(for task: ReviewBoardTask) -> ReviewBoardMergeQueueItem? {
        mergeQueue.first { $0.taskRawID == task.rawID }
    }

    static let empty = ReviewBoardSnapshot(
        tasks: [],
        panelRuns: [],
        mergeQueue: [],
        coordinatorOnline: false,
        memMeshAvailable: false,
        suspectHost: false,
        fencedZombie: false
    )
}

struct ReviewBoardTask: Identifiable, Equatable, Sendable {
    let id: String
    /// The identifier as the producer wrote it. `id` is shortened for display,
    /// and a coordinator task id is a 36-character `tsk_<uuid>` that shortens
    /// to four distinguishing hex digits — fine to read, far too collision
    /// prone to join a merge queue entry on. Anything matching rows across
    /// two payloads uses this; anything shown to a person uses `id`.
    let rawID: String
    let teamName: String
    let title: String
    let status: String
    let assignee: String?
    let priority: Int
    let labels: [String]
    let dependsOn: [String]
    let blockedReason: String?
    let reviewSummary: String?
    let result: String?
    /// The agent's reply as the producer wrote it. `result` is scrubbed and
    /// clipped for display — paths become `…/name`, long tokens become
    /// `<token>`, and the whole thing stops at 240 characters — which is right
    /// for a row on a board and wrong for anything that has to be *run*.
    /// Auto pilot's VERIFY command is read from here and nowhere else; showing
    /// this string is not allowed, which is why every view still reads
    /// `result`.
    let rawResult: String?
    let resultPath: String?
    let worktreeBranch: String?
    let worktreeParent: String?
    /// The parent branch as recorded, not as shown. `worktreeParent` goes
    /// through `safeLabel`, which rewrites any 32-character run of word
    /// characters to `<token>` and clips at 120 — harmless on a row, ruinous as
    /// a merge target, which is what this is for. Same reasoning as
    /// `worktreePath`, which was never scrubbed for exactly this reason.
    let rawWorktreeParent: String?
    /// Where the work actually is. Present on team-board rows only — a task
    /// the coordinator placed carries no worktree facts (its `attempts` row
    /// does, and that comes from `task.get`).
    let worktreePath: String?
    let worktreeFinishMode: String?
    let worktreeRemoved: Bool?
    /// The instruction as the producer wrote it. `title` is scrubbed and
    /// clipped to 120 characters for display, which is right for a row and
    /// wrong for deciding whether two tasks are the same instruction: a
    /// delegated instruction opens with a shared preamble, so two different
    /// asks routinely agree for the first 119 characters and then differ.
    /// Same reasoning as `rawID` and `rawResult`.
    let rawTitle: String
    let isStale: Bool
    let staleSeconds: Int?
    let updatedAt: String?
    /// The wave this task was dispatched in, when the leader stated one.
    ///
    /// Both task serializers already emit `wave_id`; the board simply never
    /// read it, which is why one fan-out to four agents arrived as four
    /// unrelated rows repeating the same instruction. Optional because a
    /// directly created task belongs to no wave, and because a leader may
    /// dispatch without stating one — those cases are grouped by evidence
    /// rather than by claim, and marked as derived.
    let waveID: String?

    /// Statuses that mean the agent is done with it — `review_ready` included,
    /// because the work finished even though the review has not.
    private static let finishedStatuses: Set<String> = [
        "completed", "review_ready", "approved", "merged", "done"
    ]

    /// When the task finished, or nil while it is still running.
    ///
    /// There is no `completed_at` to read: both boards stamp `updated_at` on
    /// every state change, so for a task that has reached a terminal status
    /// that stamp *is* the finish. Deriving it here rather than showing
    /// `updatedAt` on every row keeps the board from labelling a running
    /// task's last heartbeat as a completion.
    var finishedAt: String? {
        Self.finishedStatuses.contains(status) ? updatedAt : nil
    }

    init(
        id: String,
        teamName: String,
        title: String,
        status: String,
        assignee: String? = nil,
        priority: Int = 2,
        labels: [String] = [],
        dependsOn: [String] = [],
        blockedReason: String? = nil,
        reviewSummary: String? = nil,
        result: String? = nil,
        // Only passed explicitly by code that already holds a scrubbed
        // `result` and must not re-derive the raw text from it — see
        // `merging(coordinator:)`. Every parser hands the producer's own
        // string to `result` and gets this filled in from it.
        rawResult: String? = nil,
        rawTitle: String? = nil,
        resultPath: String? = nil,
        worktreeBranch: String? = nil,
        worktreeParent: String? = nil,
        // Same rule as `rawResult`: only passed explicitly by code holding an
        // already-scrubbed `worktreeParent`.
        rawWorktreeParent: String? = nil,
        worktreePath: String? = nil,
        worktreeFinishMode: String? = nil,
        worktreeRemoved: Bool? = nil,
        isStale: Bool = false,
        staleSeconds: Int? = nil,
        updatedAt: String? = nil,
        waveID: String? = nil
    ) {
        self.id = ReviewBoardText.safeIdentifier(id)
        self.rawID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.teamName = ReviewBoardText.safeLabel(teamName)
        self.title = ReviewBoardText.safeLabel(title)
        self.rawTitle = rawTitle ?? title
        self.status = status
        self.assignee = assignee.map(ReviewBoardText.safeLabel)
        self.priority = priority
        self.labels = labels.map(ReviewBoardText.safeLabel)
        self.dependsOn = dependsOn.map(ReviewBoardText.safeIdentifier)
        self.blockedReason = blockedReason.map { ReviewBoardText.safeBody($0) }
        self.reviewSummary = reviewSummary.map { ReviewBoardText.safeBody($0) }
        self.result = result.map { ReviewBoardText.safeBody($0) }
        // Kept whole, deliberately: this is the copy a command is read out of,
        // and a scrubbed command is a different command.
        self.rawResult = (rawResult ?? result)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.resultPath = resultPath.flatMap(ReviewBoardText.safePathLabel)
        self.worktreeBranch = worktreeBranch.map(ReviewBoardText.safeLabel)
        self.worktreeParent = worktreeParent.map(ReviewBoardText.safeLabel)
        self.rawWorktreeParent = (rawWorktreeParent ?? worktreeParent)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        // Not run through safeLabel: this is a path the app hands to git, not
        // a string it prints. Redacting it would make it unusable.
        self.worktreePath = worktreePath
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.worktreeFinishMode = worktreeFinishMode.map(ReviewBoardText.safeLabel)
        self.worktreeRemoved = worktreeRemoved
        self.isStale = isStale
        self.staleSeconds = staleSeconds
        self.updatedAt = updatedAt
        // A wave id identifies a dispatch, so a blank one identifies nothing:
        // every task with an empty string would otherwise land in one group.
        self.waveID = waveID
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    init?(dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String,
              let title = dictionary["title"] as? String else {
            return nil
        }
        self.init(
            id: id,
            teamName: dictionary["team_name"] as? String ?? "Unknown team",
            title: title,
            status: dictionary["status"] as? String ?? "queued",
            assignee: dictionary["assignee"] as? String,
            priority: dictionary["priority"] as? Int ?? 2,
            labels: dictionary["labels"] as? [String] ?? [],
            dependsOn: dictionary["depends_on"] as? [String] ?? [],
            blockedReason: dictionary["blocked_reason"] as? String,
            reviewSummary: dictionary["review_summary"] as? String,
            result: dictionary["result"] as? String,
            resultPath: dictionary["result_path"] as? String,
            worktreeBranch: dictionary["worktree_branch"] as? String,
            worktreeParent: dictionary["worktree_parent"] as? String,
            worktreePath: dictionary["worktree_path"] as? String,
            worktreeFinishMode: dictionary["worktree_finish_mode"] as? String,
            worktreeRemoved: dictionary["worktree_removed"] as? Bool,
            isStale: dictionary["is_stale"] as? Bool ?? false,
            staleSeconds: dictionary["stale_seconds"] as? Int,
            updatedAt: dictionary["updated_at"] as? String,
            waveID: dictionary["wave_id"] as? String
        )
    }

    /// The coordinator writes its own domain's vocabulary — `task_id`, no
    /// team, millisecond timestamps — and the board used to read only the
    /// team board's (`id`, `team_name`, `updated_at`). Every coordinator row
    /// therefore failed the `id` guard above and vanished, so a board backed
    /// by a healthy coordinator showed "No review tasks" no matter how much
    /// work it held.
    ///
    /// Two producers get two parsers rather than one that guesses: a single
    /// init reading `id ?? task_id` would keep working while quietly filling
    /// unrelated fields from the wrong schema.
    /// `names` turns the coordinator's identifiers into the words a person
    /// uses — a project id into the project's name, a host id into the machine
    /// it stands for. Showing the raw ones is worse than terse: a project id is
    /// long enough that the scrubber replaces it with `<token>`, so the row
    /// read `<token> · hst_529b6dae74912ffc` and named nothing at all.
    init?(
        coordinatorDictionary dictionary: [String: Any],
        names: CoordinatorDisplayNames = .empty
    ) {
        guard let taskID = dictionary["task_id"] as? String,
              let title = dictionary["title"] as? String else {
            return nil
        }
        let projectID = dictionary["project_id"] as? String
        let hostID = (dictionary["placement"] as? [String: Any])?["host_id"] as? String
        // Coordinator statuses are kept verbatim. Folding `queued_for_merge`
        // into `queued` would read fine and lose the one distinction the
        // merge queue exists to show.
        let status = dictionary["status"] as? String ?? "pending"
        // `last_reason` is whatever the coordinator recorded alongside the
        // task's latest status, which is a reason only when the task stopped.
        // For work that ran to a result on a peer it holds the agent's own
        // summary — the only copy of it on this machine, since a remote task
        // has no local team row — and putting that in the blocked-reason box
        // would announce a finished job as a failure.
        let note = dictionary["last_reason"] as? String
        let stopped = Self.stoppedPhases.contains(status)
        self.init(
            id: taskID,
            teamName: projectID.flatMap { names.projects[$0] } ?? "Unknown project",
            title: title,
            status: status,
            assignee: hostID.flatMap { names.hosts[$0] },
            priority: (dictionary["priority"] as? Int) ?? 0,
            dependsOn: dictionary["depends_on"] as? [String] ?? [],
            // Why the task stopped. Without it the board showed a task go
            // `suspect` and then eight rows of "not reported" — every one of
            // which was true, and none of which was the answer.
            blockedReason: stopped ? note : nil,
            result: stopped ? nil : note,
            updatedAt: (dictionary["updated_at_ms"] as? UInt64).map(ReviewBoardText.timestamp(fromUnixMilliseconds:))
        )
    }
}

extension ReviewBoardTask {
    /// Phases only the coordinator can know about. The team task board tracks
    /// execution — a task is assigned, running, blocked, done — and knows
    /// nothing of fencing, review approval or the merge queue. When the
    /// coordinator reports one of these it is saying something the team
    /// vocabulary cannot express, so it wins.
    ///
    /// `placed` is deliberately not here: it is what the coordinator says
    /// before the agent has it, and the team board is already further along by
    /// the time anyone is looking.
    /// Phases where the coordinator's note explains a stop rather than
    /// reporting an outcome.
    static let stoppedPhases: Set<String> = [
        "suspect",
        "quarantined",
        "rejected",
        "blocked",
        "failed",
        "cancelled",
    ]

    static let coordinatorOnlyPhases: Set<String> = [
        "suspect",
        "quarantined",
        "approved",
        "rejected",
        "queued_for_merge",
        "merged",
    ]

    /// How `merging` says "there is no raw copy" to an initialiser whose `nil`
    /// means something else.
    ///
    /// `init` fills a missing `rawResult` in from `result`, which is right for
    /// every parser — they hand it the producer's own string. It is wrong here,
    /// where `result` has already been through `safeBody`: the fallback would
    /// turn a display string into the command that runs. An empty string is
    /// dropped to nil by that same initialiser, which is the outcome wanted.
    static let noRawResult = ""

    /// A local completion closes execution. When the coordinator has already
    /// advanced that same work to review, its status is the newer phase.
    ///
    /// Keep this transition narrow: a stale coordinator `review_ready` must
    /// never overwrite a local block or failure.
    private static func mergedStatus(local: String, coordinator: String) -> String {
        if coordinatorOnlyPhases.contains(coordinator) { return coordinator }
        if local == "completed", coordinator == "review_ready" { return coordinator }
        return local
    }

    /// One row for one piece of work, now that both sides key on the same id.
    ///
    /// Neither side is simply right: agents move the task through execution,
    /// the coordinator moves it through placement and merge. So the status
    /// comes from whichever is speaking about a phase the other cannot see,
    /// and the facts each holds alone are filled in rather than dropped.
    func merging(coordinator other: ReviewBoardTask) -> ReviewBoardTask {
        ReviewBoardTask(
            id: rawID,
            teamName: teamName == "Unknown team" ? other.teamName : teamName,
            title: title.isEmpty ? other.title : title,
            status: Self.mergedStatus(local: status, coordinator: other.status),
            // Where it runs is the coordinator's to say; who holds it is the
            // team's. Prefer the agent, because that is what a person looks for.
            assignee: assignee ?? other.assignee,
            priority: priority,
            labels: labels,
            dependsOn: dependsOn.isEmpty ? other.dependsOn : dependsOn,
            blockedReason: blockedReason ?? other.blockedReason,
            reviewSummary: reviewSummary ?? other.reviewSummary,
            result: result ?? other.result,
            // The raw copy is the one a VERIFY command is read out of and then
            // run in `worktreePath`, so the two have to come off the same
            // machine. The coordinator's copy does not always: for work placed
            // on a peer it holds that peer's own reply, carried back as
            // `last_reason`. Inheriting it here while `worktreePath` below
            // keeps the local row's directory is how a command written on one
            // machine got a shell on another.
            //
            // So the coordinator's raw text is taken only when this side has
            // no worktree to run it in. The scrubbed `result` above still
            // shows it — reading a peer's answer is the point — but nothing
            // executes it, and `AutoPilotCheck.refusal` then hands the task to
            // a person because the shown reply has a VERIFY line the raw copy
            // cannot back.
            //
            // Passed explicitly rather than left to the init's fallback:
            // `result` here is already scrubbed, and letting the raw copy be
            // re-derived from it would quietly make a display string the
            // command.
            rawResult: result != nil
                ? rawResult
                : (worktreePath == nil ? other.rawResult : Self.noRawResult),
            resultPath: resultPath ?? other.resultPath,
            worktreeBranch: worktreeBranch,
            worktreeParent: worktreeParent,
            // Passed explicitly for the same reason as `rawResult`: the value
            // above has already been scrubbed, and letting it re-derive the raw
            // copy would make a display string the merge target.
            rawWorktreeParent: rawWorktreeParent,
            worktreePath: [worktreePath, other.worktreePath].compactMap { $0 }.first,
            worktreeFinishMode: worktreeFinishMode,
            worktreeRemoved: worktreeRemoved,
            isStale: isStale,
            staleSeconds: staleSeconds,
            updatedAt: [updatedAt, other.updatedAt].compactMap { $0 }.max(),
            // Only the team board records a wave; a coordinator row carries
            // none. Taking whichever side has one keeps a merged row inside
            // the dispatch it came from instead of falling back to the
            // title-and-time guess.
            waveID: waveID ?? other.waveID
        )
    }
}

/// One dispatch: the instruction as it was given once, and every agent it
/// went to.
///
/// The board drew one card per task, so a leader fanning one question out to
/// four agents produced four cards repeating the same two lines of
/// instruction, distinguished only by an agent name and a clock time. The
/// question was asked once; it should be read once.
struct ReviewBoardTaskGroup: Identifiable, Equatable, Sendable {
    let id: String
    let teamName: String
    let title: String
    let priority: Int
    /// Members in the order the board received them, so a group's rows do not
    /// reshuffle on a status tick.
    let members: [ReviewBoardTask]
    /// Whether `id` is a wave the leader actually stated, or one derived from
    /// the instruction text and the clock.
    ///
    /// The distinction is shown, not hidden. A derived group can be wrong in
    /// both directions — a leader that reworded one agent's copy of the same
    /// instruction splits, and two unrelated dispatches of an identical
    /// instruction inside the window merge — and a reader deciding whether
    /// "3 agents" means anything has to know which kind of group it is.
    let isDerived: Bool

    var isSingle: Bool { members.count == 1 }

    /// The clock face of the newest member, which is when the dispatch as a
    /// whole last moved.
    var updatedAt: String? { members.compactMap(\.updatedAt).max() }

    /// Statuses in first-seen member order, deduplicated, with their counts.
    ///
    /// First-seen, not severity-ranked: the board already hands members over
    /// in its own sort order, and re-ranking here would quietly disagree with
    /// the rows beside it. A view that wants to lead with the worst status
    /// ranks this list itself.
    ///
    /// Not a sentence: a group's rollup is rendered differently at different
    /// widths, and building the prose here would decide that for the view.
    var statusCounts: [(status: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for member in members {
            if counts[member.status] == nil { order.append(member.status) }
            counts[member.status, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    /// Whether every member reached the same status, which is the common case
    /// and the one worth stating as one phrase.
    var uniformStatus: String? {
        let statuses = Set(members.map(\.status))
        return statuses.count == 1 ? statuses.first : nil
    }
}

extension ReviewBoardTask {
    /// How far apart two members of the same derived group may be.
    ///
    /// A fan-out is dispatched in one motion, and its members finish within a
    /// wave of each other. Two minutes is wide enough to hold a wave whose
    /// agents answered at different speeds and narrow enough to keep a
    /// re-ask of the same question, minutes later, as its own dispatch.
    static let derivedGroupWindow: TimeInterval = 120

    /// Group tasks into the dispatches they were made in.
    ///
    /// A stated wave id wins outright. Without one the fallback is evidence
    /// rather than claim — same Project, same instruction, finished close
    /// together — and every group it forms is marked `isDerived`, because it
    /// is a guess and the board must not present a guess as a wave.
    static func grouped(
        _ tasks: [ReviewBoardTask],
        window: TimeInterval = derivedGroupWindow
    ) -> [ReviewBoardTaskGroup] {
        /// A group under construction, with the two values the scan would
        /// otherwise recompute for every candidate: the normalized
        /// instruction, and the anchor the window is measured from.
        struct Building {
            let id: String
            let teamName: String
            let title: String
            let normalizedTitle: String
            /// The earliest and latest member instants, so the window bounds
            /// the group's whole span rather than its last arrival.
            var earliest: Date?
            var latest: Date?
            var priority: Int
            var members: [ReviewBoardTask]
            let isDerived: Bool
        }

        var building: [Building] = []
        var indexByKey: [String: Int] = [:]

        for task in tasks {
            let moment = task.updatedAt.flatMap(ReviewBoardText.date)
            let key: String
            let derived: Bool
            if let waveID = task.waveID {
                key = "wave:\(task.teamName)\u{1F}\(waveID)"
                derived = false
            } else {
                key = Self.derivedKey(
                    for: task, moment: moment, against: building.map {
                        (id: $0.id, teamName: $0.teamName,
                         normalizedTitle: $0.normalizedTitle,
                         earliest: $0.earliest, latest: $0.latest,
                         isDerived: $0.isDerived)
                    },
                    window: window
                )
                derived = true
            }
            if let index = indexByKey[key] {
                building[index].members.append(task)
                // The board sorts by urgency, so a group is as urgent as its
                // most urgent member.
                building[index].priority = min(building[index].priority, task.priority)
                if let moment {
                    building[index].earliest = min(building[index].earliest ?? moment, moment)
                    building[index].latest = max(building[index].latest ?? moment, moment)
                }
                continue
            }
            indexByKey[key] = building.count
            building.append(Building(
                id: key, teamName: task.teamName, title: task.title,
                normalizedTitle: ReviewBoardText.normalizedGroupTitle(task.rawTitle),
                earliest: moment, latest: moment,
                priority: task.priority, members: [task], isDerived: derived
            ))
        }

        return building.map {
            ReviewBoardTaskGroup(
                id: $0.id, teamName: $0.teamName, title: $0.title,
                priority: $0.priority, members: $0.members, isDerived: $0.isDerived
            )
        }
    }

    /// A candidate group, reduced to what the derived match actually reads.
    typealias DerivedCandidate = (
        id: String, teamName: String, normalizedTitle: String,
        earliest: Date?, latest: Date?, isDerived: Bool
    )

    /// The key of an existing derived group this task belongs to, or a new one.
    ///
    /// The window bounds the group's whole span, not the distance to its
    /// nearest member. Measuring against any member made membership
    /// transitive: arrivals 110 seconds apart chained into one group of
    /// unbounded width, so a poll repeating the same instruction folded into a
    /// single card claiming one dispatch. It also made the result depend on
    /// input order, and the board hands these over sorted by urgency rather
    /// than by time.
    private static func derivedKey(
        for task: ReviewBoardTask,
        moment: Date?,
        against candidates: [DerivedCandidate],
        window: TimeInterval
    ) -> String {
        let normalized = ReviewBoardText.normalizedGroupTitle(task.rawTitle)
        guard let moment else {
            // No clock means no evidence of a wave. Stand alone rather than
            // join a group on the instruction by itself.
            return "solo:\(task.id)"
        }
        for candidate in candidates where candidate.isDerived
            && candidate.teamName == task.teamName
            && candidate.normalizedTitle == normalized {
            guard let earliest = candidate.earliest, let latest = candidate.latest else {
                continue
            }
            let span = max(latest, moment).timeIntervalSince(min(earliest, moment))
            if span <= window { return candidate.id }
        }
        return "derived:\(task.teamName)\u{1F}\(normalized)\u{1F}\(task.id)"
    }
}

/// The names a person recognises, keyed by the ids the coordinator uses.
struct CoordinatorDisplayNames: Equatable, Sendable {
    var projects: [String: String]
    var hosts: [String: String]

    static let empty = CoordinatorDisplayNames(projects: [:], hosts: [:])
}

/// One row of the coordinator's merge queue. The board used to describe merge
/// state by searching task prose for the word "merge"; these are the actual
/// records the coordinator gates a merge on.
struct ReviewBoardMergeQueueItem: Identifiable, Equatable, Sendable {
    let id: String
    /// Untruncated, to join against `ReviewBoardTask.rawID`.
    let taskRawID: String
    let taskDisplayID: String
    let attemptID: String
    /// `queued` | `running` | `merged` | `failed` | `cancelled`.
    let status: String
    let approvedBy: String
    let approvedAt: String?
    let lastError: String?

    var isFailed: Bool { status == "failed" }

    /// Still waiting on the queue, as opposed to finished one way or another.
    var isPending: Bool { status == "queued" || status == "running" }

    init?(dictionary: [String: Any]) {
        guard let queueID = dictionary["queue_id"] as? String,
              let taskID = dictionary["task_id"] as? String else {
            return nil
        }
        id = ReviewBoardText.safeIdentifier(queueID)
        taskRawID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        taskDisplayID = ReviewBoardText.safeIdentifier(taskID)
        attemptID = ReviewBoardText.safeIdentifier(dictionary["attempt_id"] as? String ?? "")
        status = dictionary["status"] as? String ?? "queued"
        approvedBy = ReviewBoardText.safeLabel(dictionary["approved_by"] as? String ?? "unknown")
        approvedAt = (dictionary["approved_at_ms"] as? UInt64)
            .map(ReviewBoardText.timestamp(fromUnixMilliseconds:))
        lastError = (dictionary["last_error"] as? String).map { ReviewBoardText.safeBody($0) }
    }

    /// What the task's Merge Queue fact says. Reads as a sentence because it
    /// lands in a text row, not a table.
    var summary: String {
        var line = "\(status) · approved by \(approvedBy)"
        if let approvedAt {
            line += " at \(approvedAt)"
        }
        if let lastError {
            line += " — \(lastError)"
        }
        return line
    }
}

struct ReviewBoardPanelRun: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let phase: String
    let isTerminal: Bool
    let tail: String?

    init?(dictionary: [String: Any]) {
        guard let run = dictionary["run"] as? String else { return nil }
        id = ReviewBoardText.safeIdentifier(run)
        title = ReviewBoardText.safeLabel(dictionary["title"] as? String ?? "Panel run")
        phase = ReviewBoardText.safeLabel(dictionary["phase"] as? String ?? "unknown")
        isTerminal = dictionary["terminal"] as? Bool ?? false
        tail = (dictionary["tail"] as? String).map { ReviewBoardText.safeBody($0) }
    }
}

/// What is actually known about a task. Every field is optional because most
/// of them are unknown for most of a task's life, and a row reading "not
/// reported" is worse than no row: eight of them in a column buried the one
/// line that had something to say, and made a task that was running look like
/// a task that had gone nowhere.
/// What the agent said, as it said it.
///
/// The digest below reads a task for merge and CI facts, which is the right
/// summary for work that ends in a pull request and no summary at all for work
/// that ends in an answer. A task could finish, store the agent's report, and
/// the board would still say nothing had been reported — the one thing a person
/// opens it to find out.
///
/// The reply protocol guarantees these five fields, so they are read straight
/// off the stored result rather than pattern-matched.
struct ReviewBoardAgentReport: Equatable, Sendable {
    let status: String?
    let files: String?
    let verify: String?
    let next: String?
    let fullReport: String?
    /// Whatever the agent wrote under the header.
    let body: String?

    private static let fieldOrder = ["STATUS", "FILES", "VERIFY", "NEXT", "FULL_REPORT"]

    /// Where the reply stops and the terminal starts.
    ///
    /// Claude closes a turn with a spinner line — `✻ Crunched for 6s` — and
    /// below it the pane paints its own furniture: a rule with the agent name
    /// welded into it, an effort indicator, the prompt, the shell's own line.
    /// All of it sits under the header, so all of it read as the agent's
    /// answer.
    private static let spinnerGlyphs: Set<Character> = ["✻", "✽", "✢", "✳", "✶", "✷", "✸", "✹", "✺", "·", "⏺", "*"]
    private static let ruleCharacters: Set<Character> = ["─", "━", "═", "—", "-", "_"]
    private static let promptPrefixes: [Character] = ["❯", "›", "$", "%", "◉", "⏵", "▶"]

    static func isPaneChrome(_ line: String) -> Bool {
        if let first = line.first, promptPrefixes.contains(first) { return true }
        // A rule, whether or not it has a label in the middle.
        if line.filter({ ruleCharacters.contains($0) }).count >= 8 { return true }
        // A shell prompt: user@host:/some/path.
        if line.contains("@"), line.contains(":"), line.contains("/") { return true }
        guard let first = line.first, spinnerGlyphs.contains(first) else { return false }
        let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        // `<Gerund> for 6s` and `<Gerund>…` are the two shapes it takes. An
        // asterisk-bulleted sentence the agent actually wrote matches neither,
        // so it survives.
        if rest.hasSuffix("…") { return true }
        let words = rest.split(separator: " ")
        return words.count == 3
            && words[1] == "for"
            && words[2].hasSuffix("s")
            && words[2].dropLast().allSatisfy(\.isNumber)
    }

    /// Nil when the text holds no header at all — there is nothing to show in a
    /// shape the view can label, and the raw text is better left to the caller.
    init?(result: String?) {
        guard let result, !result.isEmpty else { return nil }
        var fields: [String: String] = [:]
        var bodyLines: [String] = []
        var seenHeader = false

        for rawLine in result.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let name = Self.fieldOrder.first(where: { line.hasPrefix("\($0):") }) {
                let value = line
                    .dropFirst(name.count + 1)
                    .trimmingCharacters(in: .whitespaces)
                // A repeated header means a second report scrolled in; the
                // later one is the current answer.
                fields[name] = value
                seenHeader = true
                continue
            }
            if seenHeader { bodyLines.append(line) }
        }
        guard seenHeader else { return nil }

        func value(_ name: String) -> String? {
            guard let raw = fields[name], !raw.isEmpty else { return nil }
            // `n/a` and `NONE` are the protocol's way of saying "nothing here",
            // and showing a field whose content is "nothing" is just noise.
            let placeholder = ["n/a", "none", "-"]
            return placeholder.contains(raw.lowercased()) ? nil : raw
        }

        status = value("STATUS")
        files = value("FILES")
        verify = value("VERIFY")
        next = value("NEXT")
        fullReport = value("FULL_REPORT")

        // Only what the agent wrote under the header, and only up to the point
        // where the pane takes over. What gets captured is a screen: the reply,
        // then a spinner line, then a rule, the status bar, the prompt, the
        // shell's own line. Reading to the end put all of that on the board;
        // stepping over the chrome instead of stopping at it just moved the
        // problem to the next line down. So the first of those ends the body —
        // and when the agent wrote no summary at all, the body is empty, which
        // is the truthful answer rather than a rule with an agent name in it.
        let body = bodyLines
            .drop { $0.isEmpty }
            .prefix { !$0.isEmpty && !Self.isPaneChrome($0) }
            .joined(separator: "\n")
        self.body = body.isEmpty ? nil : body
    }

    /// In display order, skipping what the agent left empty.
    var presentFields: [(title: String, systemImage: String, text: String)] {
        [
            ("Verify", "terminal", verify),
            ("Next", "arrow.turn.down.right", next),
            ("Files", "doc.text", files),
            ("Full Report", "doc.richtext", fullReport),
        ].compactMap { title, image, text in
            guard let text, !text.isEmpty else { return nil }
            return (title, image, text)
        }
    }

    var isEmpty: Bool { presentFields.isEmpty && body == nil }
}

struct ReviewBoardTaskDigest: Equatable, Sendable {
    let attemptLineage: String?
    let aheadBehind: String?
    let commitPush: String?
    let platformChecks: String?
    let pullRequestChecks: String?
    let overlappingFiles: String?
    let rejectionReason: String?
    let mergeQueue: String?

    /// In display order, skipping everything nothing is known about.
    var presentFacts: [(title: String, systemImage: String, text: String)] {
        [
            ("Merge Queue", "arrow.triangle.merge", mergeQueue),
            ("Rejection Reason", "xmark.octagon", rejectionReason),
            ("Commit/Push", "arrow.up.doc", commitPush),
            ("Ahead/Behind", "arrow.left.arrow.right", aheadBehind),
            ("PR/Checks", "checkmark.rectangle.stack", pullRequestChecks),
            ("Platform Checks", "macwindow", platformChecks),
            ("Overlapping Files", "square.stack.3d.down.forward", overlappingFiles),
            ("Attempt Lineage", "point.3.connected.trianglepath.dotted", attemptLineage),
        ].compactMap { title, image, text in
            guard let text, !text.isEmpty else { return nil }
            return (title, image, text)
        }
    }

    static func make(
        for task: ReviewBoardTask,
        panelRuns: [ReviewBoardPanelRun],
        mergeQueueItem: ReviewBoardMergeQueueItem? = nil
    ) -> ReviewBoardTaskDigest {
        let haystack = ([task.title, task.blockedReason, task.reviewSummary, task.result] + task.labels)
            .compactMap { $0 }
            .joined(separator: "\n")
        let activeRun = panelRuns.first { !$0.isTerminal }
        let lastRun = panelRuns.first

        return ReviewBoardTaskDigest(
            attemptLineage: task.dependsOn.isEmpty
                ? nil
                : "Depends on \(task.dependsOn.joined(separator: ", "))",
            aheadBehind: firstLine(containingAny: ["ahead", "behind"], in: haystack),
            commitPush: firstLine(containingAny: ["commit", "push"], in: haystack)
                ?? fallbackCommitPush(task),
            platformChecks: firstLine(containingAny: ["xcodebuild", "test", "platform", "macos"], in: haystack),
            pullRequestChecks: firstLine(containingAny: ["pr", "check", "ci"], in: haystack),
            overlappingFiles: firstLine(containingAny: ["overlap", "conflict"], in: haystack),
            rejectionReason: task.blockedReason
                ?? firstLine(containingAny: ["reject", "rejected", "blocked"], in: haystack),
            // The coordinator's own record when it has one. What stood here
            // before was a panel run — a review panel, not a merge — with a
            // last resort of "the word merge appears in this task's text",
            // which reported merge activity for a task that merely mentioned
            // it and reported none for a queue entry that was actively
            // failing. Panel runs stay as a fallback because a board fed by
            // the local team store has no queue to read.
            mergeQueue: mergeQueueItem.map(\.summary)
                ?? activeRun.map { "Panel run: \($0.title) (\($0.phase))" }
                ?? lastRun.map { "Last panel run: \($0.title) (\($0.phase))" }
        )
    }

    private static func fallbackCommitPush(_ task: ReviewBoardTask) -> String? {
        var parts: [String] = []
        if let branch = task.worktreeBranch {
            parts.append("branch \(branch)")
        }
        if let mode = task.worktreeFinishMode {
            parts.append("finish \(mode)")
        }
        if task.worktreeRemoved == true {
            parts.append("worktree removed")
        }
        if let resultPath = task.resultPath {
            parts.append("report \(resultPath)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func firstLine(containingAny needles: [String], in text: String) -> String? {
        text.split(separator: "\n")
            .map(String.init)
            .first { line in
                let lower = line.lowercased()
                return needles.contains { lower.contains($0) }
            }
            .map { ReviewBoardText.safeBody($0) }
    }
}

enum ReviewBoardText {
    private static let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    private static let longHexPattern = #"\b[0-9a-fA-F]{24,}\b"#
    private static let tokenPattern = #"\b[A-Za-z0-9_-]{32,}\b"#

    static func safeIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        return String(trimmed.prefix(8))
    }

    static func safeLabel(_ value: String) -> String {
        safeBody(value, limit: 120)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The coordinator stamps events in Unix milliseconds; the board sorts and
    /// shows ISO-8601 strings. Converting at the parser keeps every consumer
    /// downstream working in one representation.
    static func timestamp(fromUnixMilliseconds milliseconds: UInt64) -> String {
        timestampFormatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// The two shapes an ISO-8601 stamp arrives in here: the coordinator's own,
    /// written by `timestamp(fromUnixMilliseconds:)` above, and the team
    /// board's, which carries fractional seconds. One parser would silently
    /// return nil for half the rows.
    private static let timestampParsers: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let datedClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    /// The instant an ISO timestamp names, for arithmetic rather than display.
    static func date(_ iso: String) -> Date? {
        for parser in timestampParsers {
            if let date = parser.date(from: iso) { return date }
        }
        return nil
    }

    /// Two copies of one instruction, compared the way a reader would.
    ///
    /// Whitespace and case carry no dispatch meaning, and a leader that
    /// reflows the same paragraph for two agents has still asked one question.
    /// Nothing else is normalised: rewording is a different instruction, and
    /// collapsing those would merge dispatches that are genuinely separate.
    ///
    /// Callers pass `rawTitle`. The display `title` is clipped at 120
    /// characters, and delegated instructions share a preamble, so comparing
    /// the clipped copy merged asks that differ only past the cut.
    static func normalizedGroupTitle(_ title: String) -> String {
        title.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// A wall-clock reading of a stamp, for a row a person is looking at.
    ///
    /// The board carried these as raw `2026-07-28T08:32:11Z` strings, which is
    /// the machine's form: it answers "when" only after the reader has done
    /// timezone arithmetic. Today's times drop the date — a review board is
    /// read while the work is happening.
    static func clockTime(_ iso: String) -> String? {
        for parser in timestampParsers {
            guard let date = parser.date(from: iso) else { continue }
            return Calendar.current.isDateInToday(date)
                ? clockFormatter.string(from: date)
                : datedClockFormatter.string(from: date)
        }
        return nil
    }

    /// Directives a delegated instruction opens with, addressed to the agent
    /// rather than describing the task.
    private static let titleDirectives = ["READ-ONLY", "READ ONLY"]

    /// Split a leading protocol directive off a task title.
    ///
    /// A delegated instruction is used verbatim as the title, and those open
    /// with the constraint the agent was handed — `READ-ONLY 설계 검토. 파일
    /// 수정 절대 금지 …`. Rendered as-is it ate the first line of every card,
    /// so a board of four tasks read as four copies of the same word with the
    /// actual work truncated behind it. The constraint is worth keeping, just
    /// not as the headline: returned separately, it becomes a mark on the row.
    static func splitDirective(_ title: String) -> (directive: String?, rest: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for directive in titleDirectives {
            guard trimmed.count > directive.count,
                  trimmed.prefix(directive.count).caseInsensitiveCompare(directive) == .orderedSame
            else { continue }
            let separators = CharacterSet(charactersIn: " :.-—·|").union(.whitespacesAndNewlines)
            let rest = String(trimmed.dropFirst(directive.count))
                .trimmingCharacters(in: separators)
            // A title that was nothing but the directive still has to say
            // something, so it keeps what it had.
            guard !rest.isEmpty else { return (nil, trimmed) }
            return (directive.uppercased(), rest)
        }
        return (nil, trimmed)
    }

    static func safeBody(_ value: String, limit: Int = 240) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = replace(pattern: uuidPattern, in: text, with: "<uuid>")
        text = replace(pattern: longHexPattern, in: text, with: "<token>")
        text = replace(pattern: tokenPattern, in: text, with: "<token>")
        text = text
            .split(separator: " ")
            .map { token -> String in
                let raw = String(token)
                return safePathLikeToken(raw) ?? raw
            }
            .joined(separator: " ")
        if text.count > limit {
            return String(text.prefix(limit - 1)) + "…"
        }
        return text
    }

    static func safePathLabel(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return safePathLikeToken(trimmed) ?? safeLabel(trimmed)
    }

    private static func safePathLikeToken(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}\"'"))
        guard trimmed.hasPrefix("/") || trimmed.contains("/Users/") || trimmed.contains("/.gk/") else {
            return nil
        }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !name.isEmpty else { return "…/" }
        return "…/\(name)"
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
