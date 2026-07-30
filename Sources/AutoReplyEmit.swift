import Foundation

// Emits a synthesised `tm-agent reply` when the GUI-side detector observes
// the 5-line header but the agent forgot to invoke the shell command.
// Mirrors `daemon/term-meshd/src/auto_reply_emit.rs` but calls TeamDataStore
// directly (no socket round-trip) since we're already in-process.

enum AutoReplyEmit {
    private static let resultTruncChars = 1500

    /// Statuses a reply must never reopen.
    static let terminalStatuses: Set<String> = [
        "completed", "failed", "abandoned", "cancelled",
    ]

    /// Which task a reply is answering.
    ///
    /// When the caller knows — it wrote the capsule, so it does — the answer is
    /// the task the capsule named and there is nothing to decide.
    ///
    /// When it does not, this is a guess, and the shape of the guess matters.
    /// It used to be "first non-terminal in list order", with `blocked` counted
    /// as non-terminal. An unrelated turn was measured walking up to a task
    /// another turn had parked as blocked, marking it completed, and leaving
    /// its own task untouched — losing the block reason on the way.
    ///
    /// So a blocked task is now only closable by a reply that names it. Parking
    /// something is a decision; a drive-by reply is not entitled to undo one.
    /// Among the rest the most recent wins, because a reply is far likelier to
    /// answer the instruction just given than the oldest one still open.
    static func selectTask(
        from tasks: [TeamOrchestrator.TeamTask],
        preferredTaskId: String?
    ) -> TeamOrchestrator.TeamTask? {
        if let preferredTaskId,
           let named = tasks.first(where: { $0.id == preferredTaskId }) {
            return named
        }
        if let running = tasks.filter({ $0.status == "in_progress" })
            .max(by: { $0.createdAt < $1.createdAt }) {
            return running
        }
        return tasks
            .filter { !terminalStatuses.contains($0.status) && $0.status != "blocked" }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    /// Normalize FULL_REPORT field: strip whitespace, treat "n/a" as nil.
    private static func normalizedFullReportPath(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.lowercased() == "n/a" { return nil }
        return s
    }

    /// Returns `true` when a task was matched and updated, `false` when the
    /// report file was written but no matching task existed (still useful).
    @discardableResult
    static func emit(
        teamName: String,
        agentName: String,
        event: AutoReplyEvent,
        // The task this reply is answering, when the caller knows it.
        //
        // The scrollback path never can: it sees an answer appear on a screen
        // with nothing tying it to a request. So it guesses — first
        // `in_progress`, else the first non-terminal task — and `blocked` is
        // not in that terminal set, so an unrelated turn can walk up and mark
        // a blocked task completed. Observed doing exactly that.
        //
        // A caller that sent the instruction does know, and passing it here is
        // the difference between closing a task and closing *this* task.
        preferredTaskId: String? = nil,
        agentInstanceId: String? = nil,
        store: TeamDataStore = .shared
    ) -> Bool {
        let replyText = formatReplyText(event)
        let resultPath = normalizedFullReportPath(event.fullReport)

        // 1. Find target task for this assignee (mirror Rust CLI auto-complete).
        // The assignment carries the pane identity captured at dispatch, so a
        // reply from a duplicate role can never file against its sibling.
        let tasks = store.listTasks(
            teamName: teamName,
            status: nil,
            assignee: agentName,
            needsAttention: false,
            priority: nil,
            staleOnly: false,
            dependsOn: nil
        )
        guard let task = selectTask(from: tasks, preferredTaskId: preferredTaskId),
              store.agentIdentityMatches(
                  teamName: teamName, agentName: agentName,
                  expectedInstanceId: task.assigneeInstanceId,
                  reportedInstanceId: agentInstanceId)
        else {
            return false
        }

        guard store.writeResult(teamName: teamName, agentName: agentName,
                                agentInstanceId: agentInstanceId, taskId: task.id,
                                content: replyText, resultPath: resultPath)
        else { return false }
        store.postMessage(teamName: teamName, from: agentName, content: replyText, type: "report")

        // 2. Map STATUS to task status + drive updateTask
        let taskStatus: String
        switch event.status {
        case "BLOCKED": taskStatus = "blocked"
        case "NEEDS_REVIEW": taskStatus = "review_ready"
        default: taskStatus = "completed"
        }
        let summary = String(replyText.prefix(resultTruncChars))
        let blockedReason = (event.status == "BLOCKED" && !event.body.isEmpty) ? event.body : nil
        let reviewSummary = (event.status == "NEEDS_REVIEW" && !event.body.isEmpty) ? event.body : nil

        let prevStatus = task.status
        guard let updated = store.updateTask(
            teamName: teamName,
            taskId: task.id,
            status: taskStatus,
            result: summary,
            resultPath: resultPath,
            assignee: nil,
            blockedReason: blockedReason,
            reviewSummary: reviewSummary,
            progressNote: nil
        ) else {
            return true
        }

        // 4. Mirror teamDataTaskUpdate hooks so tm-agent wait subscribers are
        //    woken and auto-recycle counters increment — bypassed when calling
        //    store.updateTask directly without going through the socket RPC path.
        if taskStatus != prevStatus {
            _ = TermMeshDaemon.shared.rpcCallRaw(method: "events.publish", params: [
                "kind": "task_status",
                "team": teamName,
                "agent": updated.assignee ?? agentName,
                "task_id": updated.id,
                "status": taskStatus,
                "prev_status": prevStatus
            ] as [String: Any])
            if taskStatus == "completed" {
                let tn = teamName, an = updated.assignee ?? agentName, ai = updated.assigneeInstanceId
                Task { @MainActor in
                    TeamOrchestrator.shared.handleTaskCompletionForAutoRecycle(
                        teamName: tn, agentName: an, agentInstanceId: ai
                    )
                }
            }
        }
        return true
    }

    static func formatReplyText(_ event: AutoReplyEvent) -> String {
        let header = "STATUS: \(event.status)\nFILES: \(event.files)\nVERIFY: \(event.verify)\nNEXT: \(event.next)\nFULL_REPORT: \(event.fullReport)"
        return event.body.isEmpty ? header : "\(header)\n\n\(event.body)"
    }
}
