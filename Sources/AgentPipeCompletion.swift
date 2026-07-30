import Foundation
import os
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
        /// Which duplicate this watch belongs to. A pipe-driven agent's turn
        /// carries no pane to prove it, so this is the only thing that can —
        /// without it, `AutoReplyEmit`'s duplicate guard sees `nil` against a
        /// task's real `assigneeInstanceId` and silently drops the reply.
        let agentInstanceId: String?
        let path: String
        var offset: UInt64 = 0
        /// Which file `offset` counts into. `tee` may not have replaced the
        /// previous pane's events file yet when the watch is created, so the
        /// offset seeded then can belong to a file that is about to be thrown
        /// away — and a shrink is only visible if the replacement happens to
        /// be shorter. The identity says so either way.
        var fileID: FileID?
        /// Bytes, for the same reason `AgentSession` keeps bytes: a read ends
        /// where the kernel handed it over, which can be mid-character, and
        /// decoding a partial chunk loses the whole thing.
        var carry = Data()
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

    /// Which file a path currently names, as the filesystem counts it.
    struct FileID: Equatable {
        let device: Int
        let inode: Int
    }

    static func fileID(atPath path: String) -> FileID? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = attributes[.systemNumber] as? Int,
              let inode = attributes[.systemFileNumber] as? Int
        else { return nil }
        return FileID(device: device, inode: inode)
    }

    func watch(agentId: String, teamName: String, agentName: String, agentInstanceId: String? = nil) {
        let path = Self.eventsPath(agentId: agentId)
        // A hard restart reuses the agent's transport id, so the events file the
        // pane that just died left behind is indistinguishable from a live one —
        // and a fresh watch reading it from byte 0 replays every finished turn
        // in it. Start at whatever is already there instead: those bytes belong
        // to a process that is gone, and nothing after them does.
        //
        // Deleting the file did the same job and could take the live one with
        // it. `watch` is called *after* the pane's shell is launched, and the
        // tail of that command is `| tee <fifo>.events`. If tee opens first the
        // unlink hits the inode it holds, tee keeps writing to a file with no
        // name, and every later `FileHandle(forReadingAtPath:)` here returns
        // nil — the agent's completions are then lost for the life of the pane,
        // which is the same hang this seeding exists to prevent. Truncation is
        // already tee's job (no `-a`), and a file that shrinks under a live
        // watch is handled in `tick`.
        var offset: UInt64 = 0
        if let handle = FileHandle(forReadingAtPath: path) {
            offset = (try? handle.seekToEnd()) ?? 0
            try? handle.close()
        }
        watches[agentId] = Watch(
            teamName: teamName, agentName: agentName, agentInstanceId: agentInstanceId,
            path: path, offset: offset, fileID: Self.fileID(atPath: path)
        )
        start()
    }

    /// Remember which task the turn now being sent is answering.
    ///
    /// The capsule already names it — `TASK_ID: …` — and this side is the one
    /// writing that text, so the correlation the screen path could never make
    /// is free here.
    ///
    /// Only a turn that names a task moves the expectation. This is not the
    /// delegate-only entry point it reads as: every delivery goes through it,
    /// so `send` and `broadcast` arrive here too, and they carry no `TASK_ID`.
    /// Writing their `nil` over a delegate's pending id erased the one thing
    /// that could close that task — `consume` now refuses to guess, so the
    /// result was dropped outright and the task sat `in_progress` until a
    /// leader's `tm-agent wait` timed out. A turn with no task to answer says
    /// nothing about the turn already waiting for one.
    func expect(agentId: String, instruction: String) {
        guard watches[agentId] != nil else { return }
        guard let taskId = Self.taskId(in: instruction) else { return }
        watches[agentId]?.pendingTaskId = taskId
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
                // The file can be replaced underneath a watch: `tee` truncates
                // it at launch and the bridge appends to whatever is there, so
                // an offset carried over from a previous process sits past the
                // new end. `seek` past EOF is legal and reads nothing, which
                // left the watch permanently deaf — every real completion for
                // the restarted agent missed.
                //
                // Two ways to notice. A file that shrank is a new file, which
                // covers a truncation seen after the fact. Identity covers the
                // rest: the offset seeded in `watch` may belong to the file the
                // *previous* pane wrote, and if tee's replacement grows past
                // that mark before the first tick, size alone says nothing.
                var offset = watch.offset
                var carry = watch.carry
                let currentID = Self.fileID(atPath: watch.path)
                let replaced = watch.fileID != nil && currentID != nil
                    && watch.fileID != currentID
                let end = try handle.seekToEnd()
                if replaced || end < offset {
                    offset = 0
                    carry = Data()
                }
                watches[agentId]?.fileID = currentID ?? watch.fileID
                try handle.seek(toOffset: offset)
                guard let chunk = try handle.readToEnd(), !chunk.isEmpty else {
                    watches[agentId]?.offset = offset
                    watches[agentId]?.carry = carry
                    continue
                }
                watches[agentId]?.offset = offset + UInt64(chunk.count)
                var buffer = carry
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[buffer.startIndex..<newline])
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        consume(line, agentId: agentId)
                    }
                }
                watches[agentId]?.carry = buffer
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
        // Only a turn whose task is known may close one. Without a task
        // `AutoReplyEmit` falls back to guessing the newest open one, and that
        // guess was measured completing work this turn had nothing to do with —
        // a broadcast carries no `TASK_ID`, and a replayed file carries no
        // expectation at all. The native path already refuses this; so does
        // this one now.
        guard let pendingTaskId = watch.pendingTaskId else {
            #if DEBUG
            dlog("agent.pipe.result.untracked agent=\(agentId) status=\(event.status)")
            #endif
            // Outside DEBUG too: dropping a turn is the correct move here and
            // an invisible one, and a leader watching a task that never closes
            // has nothing else to look at. No prompt, no result body — the
            // agent name and its own verdict are enough to tell a stray
            // broadcast apart from a delegate whose id went missing.
            Logger.team.notice(
                "[agent.pipe] \(watch.agentName, privacy: .public) ended a turn with no task to answer (status \(event.status, privacy: .public)); result not recorded"
            )
            return
        }
        AutoReplyEmit.emit(
            teamName: watch.teamName,
            agentName: watch.agentName,
            event: event,
            preferredTaskId: pendingTaskId,
            agentInstanceId: watch.agentInstanceId
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

    // MARK: - Testing

    #if DEBUG
    /// One read of every watched file, as the timer would do it.
    func tickForTesting() { tick() }

    /// Which task the next `result` from this agent would answer, if any.
    func pendingTaskIdForTesting(agentId: String) -> String? {
        watches[agentId]?.pendingTaskId
    }

    /// How far into its events file this watch has read.
    func offsetForTesting(agentId: String) -> UInt64? {
        watches[agentId]?.offset
    }
    #endif
}
