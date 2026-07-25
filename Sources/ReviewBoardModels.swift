import Foundation
import SwiftUI

enum ReviewBoardSettings {
    static let enabledKey = "reviewBoard.enabled"
    static let widthKey = "reviewBoard.width"
    static let isClosedKey = "reviewBoard.isClosed"
    static let selectedTaskIDKey = "reviewBoard.selectedTaskID"
    static let defaultWidth: CGFloat = 380
    static let minimumWidth: CGFloat = 320
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
    let resultPath: String?
    let worktreeBranch: String?
    let worktreeParent: String?
    let worktreeFinishMode: String?
    let worktreeRemoved: Bool?
    let isStale: Bool
    let staleSeconds: Int?
    let updatedAt: String?

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
        resultPath: String? = nil,
        worktreeBranch: String? = nil,
        worktreeParent: String? = nil,
        worktreeFinishMode: String? = nil,
        worktreeRemoved: Bool? = nil,
        isStale: Bool = false,
        staleSeconds: Int? = nil,
        updatedAt: String? = nil
    ) {
        self.id = ReviewBoardText.safeIdentifier(id)
        self.rawID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.teamName = ReviewBoardText.safeLabel(teamName)
        self.title = ReviewBoardText.safeLabel(title)
        self.status = status
        self.assignee = assignee.map(ReviewBoardText.safeLabel)
        self.priority = priority
        self.labels = labels.map(ReviewBoardText.safeLabel)
        self.dependsOn = dependsOn.map(ReviewBoardText.safeIdentifier)
        self.blockedReason = blockedReason.map { ReviewBoardText.safeBody($0) }
        self.reviewSummary = reviewSummary.map { ReviewBoardText.safeBody($0) }
        self.result = result.map { ReviewBoardText.safeBody($0) }
        self.resultPath = resultPath.flatMap(ReviewBoardText.safePathLabel)
        self.worktreeBranch = worktreeBranch.map(ReviewBoardText.safeLabel)
        self.worktreeParent = worktreeParent.map(ReviewBoardText.safeLabel)
        self.worktreeFinishMode = worktreeFinishMode.map(ReviewBoardText.safeLabel)
        self.worktreeRemoved = worktreeRemoved
        self.isStale = isStale
        self.staleSeconds = staleSeconds
        self.updatedAt = updatedAt
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
            worktreeFinishMode: dictionary["worktree_finish_mode"] as? String,
            worktreeRemoved: dictionary["worktree_removed"] as? Bool,
            isStale: dictionary["is_stale"] as? Bool ?? false,
            staleSeconds: dictionary["stale_seconds"] as? Int,
            updatedAt: dictionary["updated_at"] as? String
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
            status: Self.coordinatorOnlyPhases.contains(other.status) ? other.status : status,
            // Where it runs is the coordinator's to say; who holds it is the
            // team's. Prefer the agent, because that is what a person looks for.
            assignee: assignee ?? other.assignee,
            priority: priority,
            labels: labels,
            dependsOn: dependsOn.isEmpty ? other.dependsOn : dependsOn,
            blockedReason: blockedReason ?? other.blockedReason,
            reviewSummary: reviewSummary ?? other.reviewSummary,
            result: result ?? other.result,
            resultPath: resultPath ?? other.resultPath,
            worktreeBranch: worktreeBranch,
            worktreeParent: worktreeParent,
            worktreeFinishMode: worktreeFinishMode,
            worktreeRemoved: worktreeRemoved,
            isStale: isStale,
            staleSeconds: staleSeconds,
            updatedAt: [updatedAt, other.updatedAt].compactMap { $0 }.max()
        )
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
