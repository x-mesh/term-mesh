import Foundation
import Bonsplit

/// Closing a task on what the agent said, not on what its screen looked like.
///
/// The pane path has no completion signal, so one was inferred: read the
/// rendered scrollback every second, diff it, strip ANSI, strip whichever
/// bullet glyph the CLI happened to use, keep 300 lines because a TUI redraws
/// in place, and decide the answer is over when the screen has been still for
/// half a second. That is `AutoReplyDetector` + `AutoReplyPoller` +
/// `AutoReplyEmit` — about 1,100 lines whose job is to guess a boundary.
///
/// On the pipe the boundary is stated. Every turn ends with
/// `{"type":"result","stop_reason":"end_turn","result":"…","total_cost_usd":…}`,
/// and `result` is the agent's final text as a clean string.
///
/// **What this replaces and what it does not.** `stop_reason` answers *when the
/// turn ended* — the whole timing apparatus goes. It does not answer *how it
/// went*: DONE, BLOCKED and NEEDS_REVIEW are the agent's verdict and still
/// arrive as the 5-field header it writes. The difference is where that header
/// is read from — a clean string here, a rendered terminal there. Parsing does
/// not disappear; guessing does.
@MainActor
final class AgentPipeCompletion {
    static let shared = AgentPipeCompletion()

    private struct Watch {
        let teamName: String
        let agentName: String
        let path: String
        var offset: UInt64 = 0
        var carry = ""
        /// The task the last instruction carried, so its answer closes it and
        /// not whichever task happens to be first in the list.
        var pendingTaskId: String?
    }

    private var watches: [String: Watch] = [:]
    private var timer: DispatchSourceTimer?

    /// Deliberately slower than a keystroke and far faster than a turn. The
    /// file only grows when the agent speaks, so an idle team costs a `stat`.
    private static let interval: TimeInterval = 0.25

    /// The copy `tee` leaves for this side to read.
    static func eventsPath(agentId: String) -> String {
        AgentPipeTransport.fifoPath(agentId: agentId) + ".events"
    }

    func watch(agentId: String, teamName: String, agentName: String) {
        watches[agentId] = Watch(
            teamName: teamName, agentName: agentName,
            path: Self.eventsPath(agentId: agentId)
        )
        start()
    }

    /// Remember which task the turn now being sent is answering.
    ///
    /// The capsule already names it — `TASK_ID: …` — and this side is the one
    /// writing that text, so the correlation the screen path could never make
    /// is free here.
    func expect(agentId: String, instruction: String) {
        guard watches[agentId] != nil else { return }
        watches[agentId]?.pendingTaskId = Self.taskId(in: instruction)
    }

    static func taskId(in text: String) -> String? {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TASK_ID:") else { continue }
            let id = String(line.dropFirst("TASK_ID:".count))
                .trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        return nil
    }

    func forget(agentId: String) {
        watches.removeValue(forKey: agentId)
        try? FileManager.default.removeItem(atPath: Self.eventsPath(agentId: agentId))
        if watches.isEmpty { stop() }
    }

    // MARK: - Reading

    private func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.resume()
        timer = t
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        for (agentId, watch) in watches {
            guard let handle = FileHandle(forReadingAtPath: watch.path) else { continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: watch.offset)
                guard let chunk = try handle.readToEnd(), !chunk.isEmpty else { continue }
                watches[agentId]?.offset = watch.offset + UInt64(chunk.count)
                let text = watch.carry + (String(data: chunk, encoding: .utf8) ?? "")
                // A read can land mid-line; the tail waits for the rest rather
                // than being parsed as a truncated object.
                var lines = text.components(separatedBy: "\n")
                watches[agentId]?.carry = lines.removeLast()
                for line in lines { consume(line, agentId: agentId) }
            } catch {
                continue
            }
        }
    }

    private func consume(_ line: String, agentId: String) {
        guard let watch = watches[agentId],
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "result"
        else { return }

        let finalText = obj["result"] as? String ?? ""
        let stop = obj["stop_reason"] as? String ?? obj["subtype"] as? String ?? "?"
        let cost = obj["total_cost_usd"] as? Double
        #if DEBUG
        dlog("agent.pipe.result agent=\(agentId) stop=\(stop) cost=\(cost.map { String(format: "%.4f", $0) } ?? "-") chars=\(finalText.count)")
        #endif

        // The turn is over — that part is stated. What the agent decided is
        // still its own words, read here from a clean string.
        let event = Self.headerEvent(from: finalText)
        AutoReplyEmit.emit(
            teamName: watch.teamName,
            agentName: watch.agentName,
            event: event,
            preferredTaskId: watch.pendingTaskId
        )
        watches[agentId]?.pendingTaskId = nil
    }

    // MARK: - The agent's verdict

    /// Pull the 5-field header out of the agent's final message.
    ///
    /// The same five fields the terminal path hunts for, minus everything that
    /// hunting required: no ANSI to strip because nothing rendered this, no
    /// bullet glyphs because no TUI drew it, no sliding window because the
    /// whole message arrived at once, and no idle timer because the boundary
    /// came with it.
    ///
    /// A turn that ends without a header is **not** a success.
    ///
    /// Defaulting the missing STATUS to DONE was measured turning
    /// "I could not do this because the file is missing" into a completed
    /// task. The turn genuinely ended, so the task should not sit open — but
    /// the agent stated no verdict, and inventing the good one is the worst
    /// available guess. NEEDS_REVIEW says what is true: it is finished and
    /// nobody has said whether it worked.
    static let headerKeys = ["STATUS", "FILES", "VERIFY", "NEXT", "FULL_REPORT"]

    /// Split a line that packed several fields onto it.
    ///
    /// Measured: codex answered `STATUS: DONE|FILES: none|VERIFY: n/a|…` all on
    /// one line, which a line-based parser reads as a status of "DONE|FILES:
    /// none|…". The cause was the template writing `DONE|BLOCKED|NEEDS_REVIEW`
    /// and the bar being read as a separator rather than a choice; that wording
    /// is fixed, but models improvise and the parser should survive it.
    ///
    /// Only splits when the line really does carry more than one field, so a
    /// `VERIFY: a | b` pipeline is left intact.
    static func headerLines(in text: String) -> [String] {
        text.components(separatedBy: "\n").flatMap { raw -> [String] in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let packed = headerKeys.filter { line.contains($0 + ":") }.count
            guard packed > 1, line.contains("|") else { return [line] }
            return line.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    static func headerEvent(from text: String) -> AutoReplyEvent {
        var fields: [String: String] = [:]
        for line in headerLines(in: text) {
            for key in headerKeys {
                let prefix = key + ":"
                guard line.hasPrefix(prefix), fields[key] == nil else { continue }
                fields[key] = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return AutoReplyEvent(
            status: fields["STATUS"] ?? "NEEDS_REVIEW",
            files: fields["FILES"] ?? "none",
            verify: fields["VERIFY"] ?? "n/a",
            next: fields["NEXT"] ?? "NONE",
            fullReport: fields["FULL_REPORT"] ?? "n/a",
            body: text,
            raw: text
        )
    }
}
