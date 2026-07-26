import Foundation
import Combine

/// A running agent, held directly rather than through a terminal.
///
/// Everything terminal-shaped in the pipe transport is there because the host
/// is a terminal, not because the agent needs one. Measured: `claude --print`
/// with plain pipes and no PTY, no shell and no FIFO takes turn after turn and
/// keeps its context. So the whole apparatus collapses —
///
///     FIFO + `exec 3<>`          → `stdin.write`
///     `$SHELL -c` wrapper        → `Process.arguments`
///     `/dev/tty` reader          → a text field
///     ANSI renderer + `tee`      → this model, and a view over it
///
/// — and what is left is a process, a list of events, and somewhere to draw
/// them. That is what this is.
///
/// **Why it is worth doing rather than keeping the pane.** A terminal can only
/// show what it was sent, once, as characters. The events say what each part
/// *is*: this is a tool call, this is its result, this failed, this turn cost
/// $0.31 and took 2.7s. A view over the model can fold a long tool result, show
/// a diff as a diff, keep the answer selectable, and let a person search it —
/// none of which is available to something that has already been flattened to
/// a grid of cells.
@MainActor
final class AgentSession: ObservableObject {

    // MARK: - What a session is made of

    /// Who spoke. A turn from the leader and a turn from the person watching
    /// are identical on the wire — deliberately, so the agent cannot treat
    /// them differently — so the distinction is kept here, where it is only a
    /// label.
    enum Speaker: Equatable {
        case leader
        case person
    }

    enum Entry: Identifiable {
        case said(id: UUID, Speaker, String)
        case answered(id: UUID, String)
        case thought(id: UUID, String?)
        case tool(id: UUID, ToolCall)
        case turnEnded(id: UUID, TurnEnd)
        case notice(id: UUID, String)

        var id: UUID {
            switch self {
            case .said(let id, _, _), .answered(let id, _), .thought(let id, _),
                 .tool(let id, _), .turnEnded(let id, _), .notice(let id, _):
                return id
            }
        }
    }

    struct ToolCall: Equatable {
        let name: String
        let headline: String
        var result: String?
        var failed: Bool = false
        var isRunning: Bool { result == nil }
    }

    struct TurnEnd: Equatable {
        let stop: String
        let failed: Bool
        let cost: Double?
        let duration: TimeInterval?
        let tokensIn: Int?
        let tokensOut: Int?
    }

    // MARK: - State

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isThinking = false
    @Published private(set) var isRunning = false
    /// What the CLI announced about itself, shown once rather than per turn.
    @Published private(set) var summary: String?

    /// Rows still being written, so the view can show a caret on them.
    ///
    /// Nothing else can say this. A terminal shows characters arriving and
    /// leaves "is it still coming, or did it stop there?" to be inferred from
    /// whether more shows up — which is the same inference the completion
    /// detector had to make, one layer down.
    @Published private(set) var streamingIds: Set<UUID> = []

    /// Called when a turn ends, with the agent's final text. The task-board
    /// side reads its own header out of this; the session does not interpret it.
    var onTurnEnd: ((String, TurnEnd, String?) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var carry = ""
    /// Tool calls waiting for their result, keyed by the id the events use.
    private var openTools: [String: Int] = [:]
    /// Assistant text for the turn in flight, so `result` can be trusted to
    /// carry the final answer without the model having to be reassembled.
    private var saidThisTurn: [String] = []

    /// Content blocks being streamed, keyed by the index the events use, held
    /// as positions in `entries` so a delta lands on the row it belongs to.
    ///
    /// A message arrives twice under `--include-partial-messages`: once as
    /// deltas, then again whole. Both would draw it, so the second is skipped
    /// for whatever the first already built — but only for that, since tool
    /// calls only ever arrive complete.
    private var streamOpen: [Int: Int] = [:]
    private var streamedThisMessage = false

    // MARK: - Running

    struct Launch {
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
    }

    /// The arguments that make claude take turns on a pipe.
    ///
    /// `--print` is the non-interactive mode and `--verbose` is required
    /// alongside it for stream-json. `--replay-user-messages` is what makes a
    /// delivery verifiable: the message comes back, so "the agent has it" stops
    /// being an inference drawn from a paste queue.
    static func claudeLaunch(
        claudePath: String,
        model: String,
        instructions: String,
        extraArgs: [String],
        workingDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Launch {
        var args = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--replay-user-messages",
            // Without this a turn appears all at once when it is already over.
            // The events are the Anthropic block/delta shape wrapped in
            // `stream_event`, which is also what the bridge emits for the CLIs
            // that stream differently — so this side learns one vocabulary.
            "--include-partial-messages",
            "--dangerously-skip-permissions",
        ]
        if !model.isEmpty { args += ["--model", model] }
        if !instructions.isEmpty { args += ["--append-system-prompt", instructions] }
        args += extraArgs
        return Launch(executable: claudePath, arguments: args,
                      workingDirectory: workingDirectory, environment: environment)
    }

    /// The launch line for a CLI the bridge has to run on our behalf.
    ///
    /// The bridge already emits claude's events; making its *input* symmetric —
    /// turns on stdin rather than a FIFO — is what makes it a drop-in here.
    /// Same `Process`, same NDJSON written to stdin, same events parsed back:
    /// this side does not learn that codex speaks JSON-RPC or that kiro speaks
    /// ACP, and it does not learn that a turn is a process for cursor and agy.
    ///
    /// No `--events` and no `--fifo`: both exist for a terminal host, where
    /// something else has to write the turns and read the results out of a
    /// file. Here the process is right here.
    static func bridgeLaunch(
        cli: String,
        bridgePath: String,
        model: String,
        workingDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Launch {
        var args = [bridgePath, "--cli", cli, "--cwd", workingDirectory]
        if !model.isEmpty { args += ["--model", model] }
        return Launch(executable: "/usr/bin/env",
                      arguments: ["python3"] + args,
                      workingDirectory: workingDirectory,
                      environment: environment)
    }

    func start(_ launch: Launch) {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.executable)
        p.arguments = launch.arguments
        p.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory)
        var env = launch.environment
        // A nested agent CLI refuses to start when it thinks it is inside one.
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        p.environment = env

        let out = Pipe(), input = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardInput = input
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        // Kept separate rather than merged into stdout: a warning is not an
        // event, and folding it in would make the stream unparseable exactly
        // when something has gone wrong.
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            Task { @MainActor in
                self?.append(.notice(id: UUID(), AgentSession.withoutAnsi(text)))
            }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finish(code: proc.terminationStatus) }
        }

        do {
            try p.run()
        } catch {
            append(.notice(id: UUID(), "could not start the agent: \(error.localizedDescription)"))
            return
        }
        process = p
        stdin = input.fileHandleForWriting
        isRunning = true
    }

    func stop() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? stdin?.close()
        process?.terminate()
        process = nil
        stdin = nil
        isRunning = false
    }

    private func finish(code: Int32) {
        isRunning = false
        isThinking = false
        if code != 0 {
            append(.notice(id: UUID(), "the agent exited (\(code))"))
        }
    }

    // MARK: - Sending a turn

    enum SendError: Error, CustomStringConvertible {
        case notRunning
        var description: String { "the agent is not running" }
    }

    /// One user turn onto the agent's stdin.
    ///
    /// The text goes as-is. Nothing is flattened — an instruction carrying
    /// newlines arrives with them, because there is no composer on the far side
    /// to submit early on one. That flattening is the clearest thing the
    /// terminal path costs: an instruction reshaped to survive its own delivery.
    @discardableResult
    func send(_ text: String, from speaker: Speaker) throws -> Int {
        guard isRunning else { throw SendError.notRunning }
        if speaker == .leader, turnInFlight {
            queued.append((text, Self.taskId(in: text)))
            return 0
        }
        return try write(text, from: speaker, taskId: Self.taskId(in: text))
    }

    @discardableResult
    private func write(_ text: String, from speaker: Speaker, taskId: String?) throws -> Int {
        guard let stdin, isRunning else { throw SendError.notRunning }
        let payload = try Self.encode(text: text)
        try stdin.write(contentsOf: payload)
        // Shown from the receipt (`isReplay`) rather than from here, so what is
        // drawn is what the agent confirmed receiving — not what was hoped for.
        pendingSpeaker = speaker
        if speaker == .leader {
            turnInFlight = true
            currentTaskId = taskId
        }
        isThinking = true
        return payload.count
    }

    /// The task this turn is answering, named by the capsule that carried it.
    ///
    /// The screen path could never make this correlation — an answer on a
    /// screen has nothing tying it to a request — so it guessed, and a reply
    /// was measured closing an unrelated blocked task. Here the instruction
    /// says which task it is, and this side is the one that wrote it.
    private(set) var currentTaskId: String?

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

    private var pendingSpeaker: Speaker = .leader

    /// Leader turns waiting for the one in flight to finish.
    ///
    /// Measured: five messages sent back to back arrived byte for byte — zero
    /// lost — but came out as three turns, because claude queues whatever
    /// arrives mid-turn and joins it into the next one. For a person typing a
    /// follow-up that is the right behaviour and the same thing Claude Code
    /// does. For the leader it is not: two delegated tasks merged into one turn
    /// produce one `result`, so the second task never gets its completion and
    /// the board waits forever.
    ///
    /// So leader turns are serialised — one instruction, one turn, one result —
    /// and a person's message still goes straight in, joining the turn already
    /// running, which is what makes interrupting useful.
    private var queued: [(text: String, taskId: String?)] = []
    private var turnInFlight = false

    static func encode(text: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "message": ["role": "user", "content": text],
        ])
        data.append(0x0A)
        return data
    }

    // MARK: - Reading the stream

    private func consume(_ data: Data) {
        // A read can land mid-line, so the tail waits for the rest rather than
        // being parsed as a truncated object.
        let text = carry + (String(data: data, encoding: .utf8) ?? "")
        var lines = text.components(separatedBy: "\n")
        carry = lines.removeLast()
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not every line is ours — a CLI may write a warning to stdout.
            // Showing it beats swallowing it.
            // A CLI colours its warnings whether or not anything can interpret
            // the escapes. Nothing here can — this draws text, not cells.
            append(.notice(id: UUID(), Self.withoutAnsi(line)))
            return
        }
        switch obj["type"] as? String {
        case "system":  system(obj)
        case "user":    user(obj)
        case "assistant": assistant(obj)
        case "stream_event": streamEvent(obj["event"] as? [String: Any] ?? [:])
        case "result":  result(obj)
        default:        break
        }
    }

    private func system(_ o: [String: Any]) {
        // Hooks fire a dozen times before an agent does anything, and a running
        // token estimate arrives throughout. Neither is an event a person is
        // watching for; the totals come with the turn.
        guard o["subtype"] as? String == "init", summary == nil else { return }
        let model = o["model"] as? String ?? ""
        let tools = (o["tools"] as? [Any])?.count ?? 0
        let mcp = (o["mcp_servers"] as? [Any])?.count ?? 0
        summary = [model, tools > 0 ? "\(tools) tools" : "", mcp > 0 ? "\(mcp) mcp" : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func user(_ o: [String: Any]) {
        let message = o["message"] as? [String: Any] ?? [:]
        if let text = message["content"] as? String {
            // The receipt. This is the only place a sent turn is drawn from,
            // so what appears is what the agent confirmed it received.
            append(.said(id: UUID(), pendingSpeaker, text))
            return
        }
        for block in message["content"] as? [[String: Any]] ?? []
        where block["type"] as? String == "tool_result" {
            closeTool(block)
        }
    }

    private func assistant(_ o: [String: Any]) {
        let message = o["message"] as? [String: Any] ?? [:]
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                // Already drawn as it was written; the whole message is the
                // same content arriving a second time.
                if streamedThisMessage { continue }
                let text = block["text"] as? String ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    saidThisTurn.append(text)
                    append(.answered(id: UUID(), text))
                }
            case "thinking":
                if streamedThisMessage { continue }
                // Extended thinking arrives redacted — a signature and an empty
                // string. Saying "it thought here" is honest; saying nothing
                // hides that time passed.
                let body = (block["thinking"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                append(.thought(id: UUID(), body.isEmpty ? nil : body))
            case "tool_use":
                openTool(block)
            default:
                break
            }
        }
    }

    // MARK: - Streaming

    /// A message as it is written, rather than once it is finished.
    ///
    /// `content_block_start` opens a row, `content_block_delta` extends it,
    /// `content_block_stop` closes it. Blocks are addressed by `index` — one
    /// message interleaves thinking and text — so a delta has to find its own
    /// row rather than append to whatever is last.
    private func streamEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            streamOpen.removeAll()
            streamedThisMessage = false

        case "content_block_start":
            guard let index = event["index"] as? Int,
                  let block = event["content_block"] as? [String: Any]
            else { return }
            switch block["type"] as? String {
            case "text":
                entries.append(.answered(id: UUID(), ""))
            case "thinking":
                entries.append(.thought(id: UUID(), ""))
            default:
                // Tool calls arrive complete, with their arguments already
                // parsed. Assembling them from `input_json_delta` would mean
                // parsing half a JSON document to show a headline sooner.
                return
            }
            streamOpen[index] = entries.count - 1
            streamedThisMessage = true
            streamingIds.insert(entries[entries.count - 1].id)

        case "content_block_delta":
            guard let index = event["index"] as? Int,
                  let position = streamOpen[index], position < entries.count,
                  let delta = event["delta"] as? [String: Any]
            else { return }
            switch delta["type"] as? String {
            case "text_delta":
                guard case .answered(let id, let text) = entries[position],
                      let more = delta["text"] as? String else { return }
                entries[position] = .answered(id: id, text + more)
            case "thinking_delta":
                guard case .thought(let id, let text) = entries[position],
                      let more = delta["thinking"] as? String else { return }
                entries[position] = .thought(id: id, (text ?? "") + more)
            default:
                return  // signature deltas carry no text to show
            }

        case "content_block_stop":
            guard let index = event["index"] as? Int,
                  let position = streamOpen.removeValue(forKey: index),
                  position < entries.count
            else { return }
            streamingIds.remove(entries[position].id)
            if case .answered(_, let text) = entries[position] {
                saidThisTurn.append(text)
            }

        default:
            return
        }
    }

    private func openTool(_ block: [String: Any]) {
        let name = block["name"] as? String ?? "tool"
        let args = block["input"] as? [String: Any] ?? [:]
        // The one field that says what a call will do, per tool. A generic dump
        // buries it in schema.
        let headline = (args["command"] ?? args["file_path"] ?? args["pattern"]
                        ?? args["path"] ?? args["description"]) as? String ?? ""
        entries.append(.tool(id: UUID(), ToolCall(name: name, headline: headline)))
        if let id = block["id"] as? String { openTools[id] = entries.count - 1 }
    }

    private func closeTool(_ block: [String: Any]) {
        guard let id = block["tool_use_id"] as? String,
              let index = openTools.removeValue(forKey: id),
              index < entries.count,
              case .tool(let entryId, var call) = entries[index]
        else { return }
        var body = block["content"]
        if let blocks = body as? [[String: Any]] {
            body = blocks.compactMap { $0["text"] as? String }.joined()
        }
        call.result = body as? String ?? ""
        call.failed = block["is_error"] as? Bool ?? false
        entries[index] = .tool(id: entryId, call)
    }

    private func result(_ o: [String: Any]) {
        let usage = o["usage"] as? [String: Any] ?? [:]
        let failed = o["is_error"] as? Bool ?? false
        let end = TurnEnd(
            stop: o["stop_reason"] as? String ?? o["subtype"] as? String ?? "?",
            failed: failed,
            cost: o["total_cost_usd"] as? Double,
            duration: (o["duration_ms"] as? Double).map { $0 / 1000 },
            tokensIn: usage["input_tokens"] as? Int,
            tokensOut: usage["output_tokens"] as? Int
        )
        // A turn can end with blocks still open — an error, a stop, a killed
        // process. Leaving their carets on would say "still writing" forever.
        streamOpen.removeAll()
        streamingIds.removeAll()
        // Same for a tool whose result never came. Measured on kiro: five rows
        // left spinning because the bridge dropped the id its results carried,
        // and a row with no id can never be closed by one. The id is carried
        // now, but a CLI that simply never reports is still possible, and the
        // turn being over is proof that nothing is still running.
        for position in openTools.values where position < entries.count {
            guard case .tool(let id, var call) = entries[position], call.isRunning
            else { continue }
            call.result = ""
            entries[position] = .tool(id: id, call)
        }
        openTools.removeAll()
        append(.turnEnded(id: UUID(), end))
        isThinking = false
        turnInFlight = false
        // `result` carries the final answer as a clean string — the boundary is
        // stated rather than inferred from a screen going quiet.
        let final = o["result"] as? String ?? saidThisTurn.joined(separator: "\n")
        saidThisTurn.removeAll()
        let answered = currentTaskId
        currentTaskId = nil
        onTurnEnd?(final, end, answered)

        // The next leader turn only now, so it gets a turn of its own.
        if !queued.isEmpty {
            let next = queued.removeFirst()
            try? write(next.text, from: .leader, taskId: next.taskId)
        }
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        // A long session is a memory leak with a scrollbar. The terminal had
        // the same problem and answered it with a scrollback limit.
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// Escape sequences are for a grid of cells; there is not one here.
    static func withoutAnsi(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[a-zA-Z]",
            with: "", options: .regularExpression
        )
    }

    private static let maxEntries = 2_000

    // MARK: - Testing

    #if DEBUG
    /// Feed one line of the stream, as the reader would.
    func ingestForTesting(_ line: String) { handle(line) }

    /// Who the next receipt belongs to, without a process to send through.
    func noteSenderForTesting(_ speaker: Speaker) { pendingSpeaker = speaker }

    /// A leader turn in flight, without a process to write it to.
    func beginTurnForTesting(taskId: String?) {
        turnInFlight = true
        currentTaskId = taskId
    }
    #endif
}
