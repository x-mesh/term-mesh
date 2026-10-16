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
    /// So a blocked or review_ready task is now only closable by a reply that
    /// names it. Parking something is a decision; a drive-by reply is not
    /// entitled to undo one. Among the rest the most recent wins, because a
    /// reply is far likelier to answer the instruction just given than the
    /// oldest one still open.
    ///
    /// A reply that names a task never falls back to a guess: when the named
    /// task is gone or already terminal there is nothing for it to close.
    static func selectTask(
        from tasks: [TeamOrchestrator.TeamTask],
        preferredTaskId: String?
    ) -> TeamOrchestrator.TeamTask? {
        if let preferredTaskId {
            return tasks.first {
                $0.id == preferredTaskId && !terminalStatuses.contains($0.status)
            }
        }
        if let running = tasks.filter({ $0.status == "in_progress" })
            .max(by: { $0.createdAt < $1.createdAt }) {
            return running
        }
        return tasks
            .filter {
                !terminalStatuses.contains($0.status)
                    && $0.status != "blocked" && $0.status != "review_ready"
            }
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
        // with nothing tying it to a request, so `selectTask` has to guess.
        // A caller that sent the instruction does know, and passing it here is
        // the difference between closing a task and closing *this* task.
        preferredTaskId: String? = nil,
        agentInstanceId: String? = nil,
        store: TeamDataStore = .shared
    ) -> Bool {
        // Fail closed before formatting, task lookup, result persistence, or
        // message emission. Every producer shares the detector's exact enum
        // validation, including turn-end paths that bypass scrollback parsing.
        guard let status = AutoReplyDetector.statedVerdict(event.status) else {
            return false
        }
        let taskStatus: String
        switch status {
        case "DONE": taskStatus = "completed"
        case "BLOCKED": taskStatus = "blocked"
        case "NEEDS_REVIEW": taskStatus = "review_ready"
        default: return false
        }

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

        // 2. Drive the already validated STATUS transition.
        let summary = String(replyText.prefix(resultTruncChars))
        let blockedReason = (status == "BLOCKED" && !event.body.isEmpty) ? event.body : nil
        let reviewSummary = (status == "NEEDS_REVIEW" && !event.body.isEmpty) ? event.body : nil

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
            publishTaskStatus(
                teamName: teamName, agentName: updated.assignee ?? agentName,
                taskId: updated.id, status: taskStatus, prevStatus: prevStatus
            )
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

    static func publishTaskStatus(
        teamName: String, agentName: String, taskId: String,
        status: String, prevStatus: String
    ) {
        _ = TermMeshDaemon.shared.rpcCallRaw(method: "events.publish", params: [
            "kind": "task_status",
            "team": teamName,
            "agent": agentName,
            "task_id": taskId,
            "status": status,
            "prev_status": prevStatus
        ] as [String: Any])
    }

    /// Settle a native worker's turn against the task it was correlated with.
    ///
    /// Only a STATUS the agent actually stated moves the task. A turn without
    /// one is often not the agent's last word on it — it can hand a long job
    /// to the background and finish the task in a later turn it starts itself
    /// — so it is recorded as progress and the task stays open.
    static func settleNativeTurn(
        teamName: String,
        agentName: String,
        agentInstanceId: String?,
        final: String,
        taskId: String?,
        store: TeamDataStore = .shared
    ) {
        guard let taskId else { return }
        if AgentPipeCompletion.explicitStatus(in: final) != nil {
            emit(
                teamName: teamName, agentName: agentName,
                event: AgentPipeCompletion.headerEvent(from: final),
                preferredTaskId: taskId, agentInstanceId: agentInstanceId,
                store: store
            )
        } else {
            recordProgressWithoutStatus(
                teamName: teamName, agentName: agentName,
                agentInstanceId: agentInstanceId, final: final,
                taskId: taskId, store: store
            )
        }
    }

    @discardableResult
    static func recordProgressWithoutStatus(
        teamName: String,
        agentName: String,
        agentInstanceId: String?,
        final: String,
        taskId: String,
        store: TeamDataStore = .shared
    ) -> Bool {
        guard let task = store.getTask(teamName: teamName, taskId: taskId),
              task.assignee == agentName,
              store.agentIdentityMatches(
                  teamName: teamName, agentName: agentName,
                  expectedInstanceId: task.assigneeInstanceId,
                  reportedInstanceId: agentInstanceId),
              !terminalStatuses.contains(task.status)
        else { return false }
        let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmed.isEmpty
            ? "turn ended without an explicit STATUS"
            : String(trimmed.prefix(resultTruncChars))
        return store.updateTask(
            teamName: teamName, taskId: taskId,
            progressNote: note,
            expectedStatus: task.status,
            expectedAssignee: agentName,
            expectedAssigneeInstanceId: task.assigneeInstanceId
        ) != nil
    }

    /// Move a task its worker never settled to `blocked`.
    ///
    /// `review_ready` stays reserved for an agent that said NEEDS_REVIEW;
    /// `blocked` is settled for `tm-agent wait` and asks the leader to look.
    /// Status, assignee and a pinned instance are re-checked under the store
    /// lock, so a completion or reassignment that landed first wins.
    @discardableResult
    static func blockUnsettledTask(
        teamName: String,
        agentName: String,
        agentInstanceId: String?,
        taskId: String,
        reason: String,
        store: TeamDataStore = .shared
    ) -> Bool {
        guard let task = store.getTask(teamName: teamName, taskId: taskId),
              task.assignee == agentName,
              store.agentIdentityMatches(
                  teamName: teamName, agentName: agentName,
                  expectedInstanceId: task.assigneeInstanceId,
                  reportedInstanceId: agentInstanceId)
        else { return false }
        guard let updated = store.updateTask(
            teamName: teamName, taskId: taskId,
            status: "blocked",
            blockedReason: reason,
            expectedStatus: "in_progress",
            expectedAssignee: agentName,
            expectedAssigneeInstanceId: task.assigneeInstanceId
        ) else { return false }
        publishTaskStatus(
            teamName: teamName, agentName: updated.assignee ?? agentName,
            taskId: updated.id, status: "blocked", prevStatus: "in_progress"
        )
        return true
    }

    static func formatReplyText(_ event: AutoReplyEvent) -> String {
        let header = "STATUS: \(event.status)\nFILES: \(event.files)\nVERIFY: \(event.verify)\nNEXT: \(event.next)\nFULL_REPORT: \(event.fullReport)"
        return event.body.isEmpty ? header : "\(header)\n\n\(event.body)"
    }
}
