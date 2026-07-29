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
            // The recorded parent, not the shown one: the policy compares this
            // against the ceiling and the merge later uses the same string, so a
            // scrubbed copy would approve against one branch and merge into
            // another.
            targetBranch: task.rawWorktreeParent ?? "",
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

        // Before the check runs, not after: the point is that nothing is
        // executed, and the reason a person reads has to say which command was
        // refused rather than "nothing verified this".
        if let refusal = AutoPilotCheck.refusal(for: task) {
            return hold(task, refusal.reason, head: patch.headSHA, check: refusal.command)
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
            // The recorded parent, not the shown one: the policy compares this
            // against the ceiling and the merge later uses the same string, so a
            // scrubbed copy would approve against one branch and merge into
            // another.
            targetBranch: task.rawWorktreeParent ?? "",
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
            // Asked again at the point of execution, not only where the
            // decision is audited: this closure is what actually reaches
            // `/bin/sh`, so this is the line that has to be true.
            guard case .none = refusal(for: task) else { return nil }
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
    ///
    /// Read from `rawResult`, never from `result`. `result` is the display
    /// copy: it is clipped at 240 characters and has had paths and long tokens
    /// replaced. Running that is not running the agent's command — it is
    /// running a different one that happens to start the same way, and its exit
    /// code is evidence about nothing.
    static func verifyCommand(in task: ReviewBoardTask) -> String? {
        guard let verify = ReviewBoardAgentReport(result: task.rawResult)?.verify else { return nil }
        let trimmed = verify.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skipValues.contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    /// What `safeBody` leaves behind when it has rewritten a string. A command
    /// carrying any of these is a scrubbed command, whatever it was read from.
    static let redactionMarkers: [String] = ["…", "<token>", "<uuid>"]

    /// Why this task's check must not be run, or nil when it may be.
    ///
    /// Two things are refused, and neither is "there is no check": that case
    /// already has a route (`checker` returns nil and the task is held for a
    /// person). What is refused here is running *something else* and calling
    /// the exit code evidence.
    ///
    ///   - the raw reply was not kept, but the shown one has a VERIFY line, so
    ///     the only command available is the scrubbed one;
    ///   - the command still carries a redaction marker, which means the text
    ///     it came from had been rewritten before it got here.
    ///
    /// A marker can also be something the agent genuinely typed. Refusing that
    /// costs one hand-off to a person; running it when it is a rewrite costs an
    /// unattended merge on evidence that was never produced.
    static func refusal(for task: ReviewBoardTask) -> (reason: String, command: String?)? {
        guard let command = verifyCommand(in: task) else {
            guard let shown = ReviewBoardAgentReport(result: task.result)?.verify,
                  !skipValues.contains(
                      shown.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                  ) else { return nil }
            return (
                "This task's reply was not kept in full, so its VERIFY command cannot be run as "
                    + "the agent wrote it. Run it yourself and approve by hand.",
                nil
            )
        }
        guard let marker = redactionMarkers.first(where: { command.contains($0) }) else {
            return nil
        }
        return (
            "This task's VERIFY command still contains \(marker), so it is not the command the "
                + "agent wrote. It was not run.",
            command
        )
    }
}
