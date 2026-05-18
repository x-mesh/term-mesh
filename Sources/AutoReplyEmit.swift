import Foundation

// Emits a synthesised `tm-agent reply` when the GUI-side detector observes
// the 5-line header but the agent forgot to invoke the shell command.
// Mirrors `daemon/term-meshd/src/auto_reply_emit.rs` but calls TeamDataStore
// directly (no socket round-trip) since we're already in-process.

enum AutoReplyEmit {
    private static let resultTruncChars = 1500

    /// Returns `true` when a task was matched and updated, `false` when the
    /// report file was written but no matching task existed (still useful).
    @discardableResult
    static func emit(
        teamName: String,
        agentName: String,
        event: AutoReplyEvent,
        store: TeamDataStore = .shared
    ) -> Bool {
        let replyText = formatReplyText(event)

        // 1. team.report equivalent — write file + post message
        _ = store.writeResult(teamName: teamName, agentName: agentName, content: replyText)
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
        let target = tasks.first(where: { $0.status == "in_progress" })
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

        _ = store.updateTask(
            teamName: teamName,
            taskId: task.id,
            status: taskStatus,
            result: summary,
            resultPath: nil,
            assignee: nil,
            blockedReason: blockedReason,
            reviewSummary: reviewSummary,
            progressNote: nil
        )
        return true
    }

    static func formatReplyText(_ event: AutoReplyEvent) -> String {
        let header = "STATUS: \(event.status)\nFILES: \(event.files)\nVERIFY: \(event.verify)\nNEXT: \(event.next)\nFULL_REPORT: \(event.fullReport)"
        return event.body.isEmpty ? header : "\(header)\n\n\(event.body)"
    }
}
