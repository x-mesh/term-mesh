import Foundation

/// What auto pilot did, and why.
///
/// Written for someone reading afterwards who was not there. "Held" entries
/// matter as much as approvals — the usual question is not "what did it merge"
/// but "why is this still sitting here".
struct AutoPilotAudit: Codable, Equatable {
    let taskID: String
    let title: String
    /// `approved` or `held`.
    let decision: String
    let reason: String
    let headSHA: String?
    let checkCommand: String?
    let atMS: Int64

    var wasApproved: Bool { decision == "approved" }
}

/// Deciding, without a person, whether a finished task may merge.
///
/// The board already knows how to approve; this decides which tasks get that
/// treatment automatically. Two things have to hold, and neither is taken on
/// an agent's word:
///
///   - the task's own check passes **against the commit that would merge**,
///     which is why the check is run here rather than believed from a reply.
///     `STATUS: DONE` is a claim; an exit code at a known HEAD is evidence.
///   - the boundary policy allows it — see `AutoPilotPolicy`.
///
/// Everything it declines falls through to the human review path unchanged.
/// There is no second, looser route to an approval.
actor AutoPilotRunner {
    /// Reading a task's patch, which is where the head that would merge comes
    /// from.
    typealias Reviewer = (ReviewBoardTask) async -> ReviewBoardReview
    /// Approving, exactly as the panel's button does.
    typealias Approver = (ReviewBoardReview, String) async throws -> Void
    /// Producing evidence for a task at a given head, or `nil` when there is
    /// nothing to run.
    typealias Checker = (ReviewBoardTask) async -> AutoPilotCheckEvidence?
    typealias Clock = () -> Int64

    private let policy: () -> AutoPilotPolicy
    private let reviewer: Reviewer
    private let approver: Approver
    private let checker: Checker
    private let audit: AutoPilotJournal<AutoPilotAudit>
    private let now: Clock

    /// Approvals this runner has issued, which is what the policy's budget
    /// counts.
    private(set) var approvalsThisSession = 0
    /// The last reason each task was held for. The board refreshes every two
    /// seconds; without this the audit log would be the same sentence ten
    /// thousand times and the one entry that mattered would be unfindable.
    private var lastHeldReason: [String: String] = [:]

    init(
        policy: @escaping () -> AutoPilotPolicy,
        reviewer: @escaping Reviewer,
        approver: @escaping Approver,
        checker: @escaping Checker,
        audit: AutoPilotJournal<AutoPilotAudit>,
        now: @escaping Clock = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.policy = policy
        self.reviewer = reviewer
        self.approver = approver
        self.checker = checker
        self.audit = audit
        self.now = now
    }

    struct Outcome: Equatable {
        let taskID: String
        let approved: Bool
        let reason: String
    }

    /// Look at everything the board is holding and act on what qualifies.
    ///
    /// Only `review_ready` is considered. A task in any other state is not
    /// "declined" — it is simply not up for a decision yet, and auditing that
    /// would bury the tasks that are.
    func sweep(_ tasks: [ReviewBoardTask]) async -> [Outcome] {
        let current = policy()
        guard current.isEnabled else { return [] }

        var outcomes: [Outcome] = []
        for task in tasks where task.status == "review_ready" {
            outcomes.append(await consider(task, policy: current))
        }
        return outcomes
    }

    private func consider(_ task: ReviewBoardTask, policy current: AutoPilotPolicy) async -> Outcome {
        let review = await reviewer(task)
        guard let patch = review.patch else {
            return hold(task, review.blocker ?? "There is no patch to look at yet.", head: nil, check: nil)
        }

        // Running the check is the expensive part, so everything decidable
        // without it is decided first. A task targeting main should not cost a
        // full test run to refuse.
        let cheap = AutoPilotCandidate(
            taskID: task.rawID,
            targetBranch: task.worktreeParent ?? "",
            headSHA: patch.headSHA,
            // Stand-in: this pass is only meaningful for the checks that come
            // before evidence, and a `nil` here would short-circuit on the
            // evidence rule instead of the one that actually applies.
            checkEvidence: AutoPilotCheckEvidence(
                command: "", passed: true, headSHA: patch.headSHA, recordedAtMS: now()
            ),
            wouldPush: false,
            autoMergesSoFar: approvalsThisSession
        )
        if let reason = current.evaluate(cheap).reason {
            return hold(task, reason, head: patch.headSHA, check: nil)
        }

        guard let evidence = await checker(task) else {
            return hold(
                task,
                "Nothing has verified this task's build or tests.",
                head: patch.headSHA,
                check: nil
            )
        }

        let candidate = AutoPilotCandidate(
            taskID: task.rawID,
            targetBranch: task.worktreeParent ?? "",
            headSHA: patch.headSHA,
            checkEvidence: evidence,
            wouldPush: false,
            autoMergesSoFar: approvalsThisSession
        )
        if let reason = current.evaluate(candidate).reason {
            return hold(task, reason, head: patch.headSHA, check: evidence.command)
        }

        let summary = "Auto pilot: \(evidence.command) passed at "
            + "\(patch.headSHA.prefix(8)); merging into \(current.ceilingBranch)."
        do {
            try await approver(review, summary)
        } catch {
            // A refused approval is not a policy decision, so it does not
            // become the remembered hold reason — the next sweep should try
            // again rather than stay quiet about a transient failure.
            let reason = "The coordinator refused the approval: \(error.localizedDescription)"
            record(task, decision: "held", reason: reason, head: patch.headSHA, check: evidence.command)
            return Outcome(taskID: task.rawID, approved: false, reason: reason)
        }

        approvalsThisSession += 1
        lastHeldReason[task.rawID] = nil
        record(task, decision: "approved", reason: summary, head: patch.headSHA, check: evidence.command)
        return Outcome(taskID: task.rawID, approved: true, reason: summary)
    }

    private func hold(
        _ task: ReviewBoardTask, _ reason: String, head: String?, check: String?
    ) -> Outcome {
        if lastHeldReason[task.rawID] != reason {
            lastHeldReason[task.rawID] = reason
            record(task, decision: "held", reason: reason, head: head, check: check)
        }
        return Outcome(taskID: task.rawID, approved: false, reason: reason)
    }

    private func record(
        _ task: ReviewBoardTask, decision: String, reason: String, head: String?, check: String?
    ) {
        audit.record(AutoPilotAudit(
            taskID: task.rawID,
            title: task.title,
            decision: decision,
            reason: reason,
            headSHA: head,
            checkCommand: check,
            atMS: now()
        ))
    }
}

// MARK: - Running a task's own check

/// Running the command a task said would verify it.
///
/// The command comes from the agent's `VERIFY` line, and running it unattended
/// is the one genuinely new thing auto pilot does. It is not new *capability* —
/// the agent that wrote the line already had a shell in this repository — but
/// it is new *unsupervised* execution, which is why auto pilot is off until
/// someone turns it on and why every run here is bounded by a timeout.
///
/// The head is read after the command finishes, not before. A check that ran
/// while the worktree moved underneath it proved something about a commit that
/// no longer exists, and comparing the *ending* head to the patch's head is
/// what catches that.
enum AutoPilotCheck {
    static let skipValues: Set<String> = ["n/a", "na", "none", "-", ""]

    static func live(timeout: TimeInterval = 900) -> AutoPilotRunner.Checker {
        { task in
            guard let command = verifyCommand(in: task) else { return nil }
            guard let path = task.worktreePath?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
                FileManager.default.fileExists(atPath: path) else { return nil }

            let result = try? await ProcessRun.capture(
                executable: "/bin/sh",
                arguments: ["-c", command],
                currentDirectory: path,
                timeout: timeout
            )
            guard let result, !result.timedOut else { return nil }

            guard let head = try? await ProcessRun.capture(
                executable: "/usr/bin/git",
                arguments: ["-C", path, "rev-parse", "HEAD"],
                timeout: 30
            ), head.status == 0 else { return nil }

            let sha = head.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { return nil }

            return AutoPilotCheckEvidence(
                command: command,
                passed: result.status == 0,
                headSHA: sha,
                recordedAtMS: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
    }

    /// The `VERIFY` line, or nothing. `n/a` is an agent saying there is no
    /// check — which is a reason to hand the task to a person, not a reason to
    /// treat "no check" as "check passed".
    static func verifyCommand(in task: ReviewBoardTask) -> String? {
        guard let verify = ReviewBoardAgentReport(result: task.result)?.verify else { return nil }
        let trimmed = verify.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skipValues.contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }
}
