import Foundation

// Emits a synthesised `tm-agent reply` when the GUI-side detector observes
// the 5-line header but the agent forgot to invoke the shell command.
// Mirrors `daemon/term-meshd/src/auto_reply_emit.rs` but calls TeamDataStore
// directly (no socket round-trip) since we're already in-process.

enum AutoReplyEmit {
    private static let resultTruncChars = 1500

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
        store: TeamDataStore = .shared
    ) -> Bool {
        let replyText = formatReplyText(event)
        let resultPath = normalizedFullReportPath(event.fullReport)

        // 1. team.report equivalent — write file + post message
        _ = store.writeResult(teamName: teamName, agentName: agentName, content: replyText, resultPath: resultPath)
        store.postMessage(teamName: teamName, from: agentName, content: replyText, type: "report")

        // 2. Find target task for this assignee (mirror Rust CLI auto-complete)
        let tasks = store.listTasks(
            teamName: teamName,
            status: nil,
            assignee: agentName,
            needsAttention: false,
            priority: nil,
            staleOnly: false,
            dependsOn: nil
        )
        let terminal: Set<String> = ["completed", "failed", "abandoned", "cancelled"]
        let target = preferredTaskId.flatMap { id in tasks.first(where: { $0.id == id }) }
            ?? tasks.first(where: { $0.status == "in_progress" })
            ?? tasks.first(where: { !terminal.contains($0.status) })
        guard let task = target else {
            return false
        }

        // 3. Map STATUS to task status + drive updateTask
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
                let tn = teamName, an = updated.assignee ?? agentName
                Task { @MainActor in
                    TeamOrchestrator.shared.handleTaskCompletionForAutoRecycle(teamName: tn, agentName: an)
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
