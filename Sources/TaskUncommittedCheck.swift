import Foundation

/// What a task's checkout held when its worker reported DONE, BLOCKED or
/// NEEDS_REVIEW.
///
/// A worker can stop with edits it never committed and still report
/// NEEDS_REVIEW, which a leader reads as ordinary review-ready work (#818).
/// The task status stays as reported; this record lets readers tell the two
/// apart. The check runs after the status is set, so a reader can see
/// `pending` for the few seconds `git status` takes.
struct TaskUncommittedCheck: Codable, Equatable {
    enum State: String, Codable {
        case pending, checked, skipped, failed
    }

    var state: State
    /// Ties a result to the report that asked for it. A later report replaces
    /// the token, so a slow check of an earlier report is dropped.
    var token: String
    /// The status the report set. The check describes that report only, so
    /// it is dropped as soon as the task's status moves on by any route.
    var forStatus: String
    var checkout: String?
    var count: Int?
    var paths: [String]?
    var reason: String?
    var requestedAt: Date
    var checkedAt: Date?

    static let reportedStatuses: Set<String> = ["review_ready", "blocked", "completed"]
    static let deadline: TimeInterval = 5
    /// A pending check older than this never finished, for example because
    /// the app quit during it. Readers get `unknown` instead of a pending that
    /// never ends.
    static let staleAfter: TimeInterval = 30
    static let maxPaths = 10
    /// Task dictionaries go out in every daemon team sync, which has a payload
    /// limit (#740), so a recorded path is bounded too.
    static let maxPathLength = 200

    static func pending(
        checkout: String?, forStatus: String, at date: Date
    ) -> TaskUncommittedCheck {
        TaskUncommittedCheck(
            state: .pending, token: UUID().uuidString, forStatus: forStatus,
            checkout: checkout, count: nil, paths: nil, reason: nil,
            requestedAt: date, checkedAt: nil
        )
    }

    /// The check for a task in `status`, or nil when it was taken for an
    /// earlier status and no longer describes the task.
    func current(forTaskStatus status: String) -> TaskUncommittedCheck? {
        forStatus == status ? self : nil
    }

    /// True while this check is still running for the same status and
    /// checkout, so a repeated report can reuse it. A pending check past
    /// `staleAfter` never finished and does not count.
    func answersRepeatedReport(ofStatus status: String, checkout: String?, at date: Date) -> Bool {
        state == .pending && forStatus == status && self.checkout == checkout
            && date.timeIntervalSince(requestedAt) <= Self.staleAfter
    }

    func dictionary(now: Date = Date()) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let neverFinished = state == .pending
            && now.timeIntervalSince(requestedAt) > Self.staleAfter
        return [
            "state": neverFinished ? "unknown" : state.rawValue,
            "checkout": checkout as Any? ?? NSNull(),
            "count": count as Any? ?? NSNull(),
            "paths": paths as Any? ?? NSNull(),
            "reason": (neverFinished ? "check_did_not_finish" : reason) as Any? ?? NSNull(),
            "requested_at": formatter.string(from: requestedAt),
            "checked_at": checkedAt.map { formatter.string(from: $0) } as Any? ?? NSNull(),
        ]
    }
}

enum TaskUncommittedChecker {
    struct Outcome: Equatable {
        var state: TaskUncommittedCheck.State
        var count: Int? = nil
        var paths: [String]? = nil
        var reason: String? = nil
    }

    /// Runs `git status` in the task's own checkout. Only a path that is the
    /// root of a work tree is checked: a plain directory inside some other
    /// repository would otherwise report that repository's changes.
    static func run(
        checkout: String?,
        timeout: TimeInterval = TaskUncommittedCheck.deadline
    ) async -> Outcome {
        guard let checkout, !checkout.isEmpty else {
            return Outcome(state: .skipped, reason: "no_task_worktree")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: checkout, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return Outcome(state: .skipped, reason: "checkout_missing")
        }
        guard let git = ProcessRun.locate("git") else {
            return Outcome(state: .failed, reason: "git_not_found")
        }
        // An optional lock would let this background read take index.lock
        // and fail the worker's next commit.
        let base = ["--no-optional-locks", "-C", checkout]
        let toplevel: ProcessRun.Output
        do {
            toplevel = try await ProcessRun.capture(
                executable: git, arguments: base + ["rev-parse", "--show-toplevel"],
                timeout: timeout)
        } catch {
            return Outcome(state: .failed, reason: "git_could_not_start")
        }
        if toplevel.timedOut { return Outcome(state: .failed, reason: "timeout") }
        guard toplevel.status == 0 else {
            return Outcome(state: .skipped, reason: "not_git_worktree")
        }
        let root = toplevel.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved(root) == resolved(checkout) else {
            return Outcome(state: .skipped, reason: "not_worktree_root")
        }
        let status: ProcessRun.Output
        do {
            status = try await ProcessRun.capture(
                executable: git,
                arguments: base + [
                    "status", "--porcelain=v1", "-z",
                    "--untracked-files=normal", "--ignore-submodules=dirty",
                ],
                timeout: timeout)
        } catch {
            return Outcome(state: .failed, reason: "git_could_not_start")
        }
        if status.timedOut { return Outcome(state: .failed, reason: "timeout") }
        guard status.status == 0 else {
            return Outcome(state: .failed, reason: "git_status_exit_\(status.status)")
        }
        let paths = parsePorcelainZ(status.stdout)
        return Outcome(
            state: .checked, count: paths.count,
            paths: paths.prefix(TaskUncommittedCheck.maxPaths).map(bounded))
    }

    /// Paths from `git status --porcelain=v1 -z`. A rename or copy entry is
    /// followed by its source path as a separate field, which is skipped.
    static func parsePorcelainZ(_ data: Data) -> [String] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var paths: [String] = []
        var index = fields.startIndex
        while index < fields.endIndex {
            let entry = String(decoding: fields[index], as: UTF8.self)
            index = fields.index(after: index)
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            if code.contains("R") || code.contains("C"), index < fields.endIndex {
                index = fields.index(after: index)
            }
        }
        return paths
    }

    private static func bounded(_ path: String) -> String {
        guard path.count > TaskUncommittedCheck.maxPathLength else { return path }
        return String(path.prefix(TaskUncommittedCheck.maxPathLength - 1)) + "…"
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
