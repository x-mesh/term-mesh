import Foundation
import Combine

/// Splits an NDJSON byte stream without copying the unread tail once per line.
/// Owned by the stream's serial queue; it is intentionally not thread-safe.
final class AgentStreamDecoder {
    static let defaultMaxLineBytes = 8 * 1024 * 1024
    static let maxPendingBatchBytes = 1 * 1024 * 1024
    static let batchInterval: TimeInterval = 1.0 / 30.0
    enum Output: Equatable {
        case line(String)
        case oversized(Int)
    }

    private var bytes: [UInt8] = []
    private var scanOffset = 0
    private let maxLineBytes: Int

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    func consume(_ data: Data) -> [Output] {
        bytes.append(contentsOf: data)
        var output: [Output] = []
        var lineStart = 0
        var index = scanOffset

        while index < bytes.count {
            guard bytes[index] == 0x0A else {
                index += 1
                continue
            }
            var end = index
            if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
            if end > lineStart {
                let lineBytes = bytes[lineStart..<end]
                if lineBytes.count > maxLineBytes {
                    output.append(.oversized(lineBytes.count))
                } else if let line = String(bytes: lineBytes, encoding: .utf8), !line.isEmpty {
                    output.append(.line(line))
                }
            }
            lineStart = index + 1
            index += 1
        }

        if lineStart > 0 {
            bytes.removeFirst(lineStart)
            index -= lineStart
        }
        scanOffset = index

        if bytes.count > maxLineBytes {
            output.append(.oversized(bytes.count))
            bytes.removeAll(keepingCapacity: true)
            scanOffset = 0
        }
        return output
    }
}

/// JSON objects are created and then consumed on two serial queues. Foundation
/// exposes them as `Any`, so Swift cannot prove that they are immutable; this
/// wrapper owns the transfer and no caller mutates the object after parsing.
private struct AgentParsedLine: @unchecked Sendable {
    let raw: String
    let object: [String: Any]?
    let preparedChanges: [String: AgentDiff.Change]
    let preparedToolIDs: Set<String>
    let sourceLineCount: Int
    let sourceBytes: Int

    init(_ raw: String) {
        self.raw = raw
        sourceLineCount = 1
        sourceBytes = raw.utf8.count
        if let data = raw.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            object = nil
        }
        var changes: [String: AgentDiff.Change] = [:]
        var toolIDs: Set<String> = []
        if object?["type"] as? String == "assistant",
           let message = object?["message"] as? [String: Any] {
            for block in message["content"] as? [[String: Any]] ?? []
            where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String else { continue }
                toolIDs.insert(id)
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                changes[id] = AgentDiff.change(tool: name, input: input)
            }
        }
        preparedChanges = changes
        preparedToolIDs = toolIDs
    }

    private init(object: [String: Any], sourceLineCount: Int, sourceBytes: Int) {
        raw = ""
        self.object = object
        preparedChanges = [:]
        preparedToolIDs = []
        self.sourceLineCount = sourceLineCount
        self.sourceBytes = sourceBytes
    }

    private var deltaParts: (index: Int, field: String, text: String)? {
        guard object?["type"] as? String == "stream_event",
              let event = object?["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let index = event["index"] as? Int,
              let delta = event["delta"] as? [String: Any],
              let type = delta["type"] as? String else { return nil }
        if type == "text_delta", let text = delta["text"] as? String {
            return (index, "text", text)
        }
        if type == "thinking_delta", let text = delta["thinking"] as? String {
            return (index, "thinking", text)
        }
        return nil
    }

    /// Adjacent deltas for the same content block are semantically one append.
    /// Merging them here avoids repeatedly copying the growing Swift `String`
    /// when a CLI emits one JSON frame per token.
    func merging(_ next: AgentParsedLine) -> AgentParsedLine? {
        guard let lhs = deltaParts, let rhs = next.deltaParts,
              lhs.index == rhs.index, lhs.field == rhs.field,
              var outer = object,
              var event = outer["event"] as? [String: Any],
              var delta = event["delta"] as? [String: Any]
        else { return nil }
        delta[lhs.field] = lhs.text + rhs.text
        event["delta"] = delta
        outer["event"] = event
        return AgentParsedLine(
            object: outer,
            sourceLineCount: sourceLineCount + next.sourceLineCount,
            sourceBytes: sourceBytes + next.sourceBytes
        )
    }

    var isBarrier: Bool {
        guard let type = object?["type"] as? String else { return true }
        if type == "result" || type == "system" || type == "user" || type == "assistant" {
            return true
        }
        guard type == "stream_event",
              let event = object?["event"] as? [String: Any],
              let eventType = event["type"] as? String else { return false }
        return eventType != "content_block_delta"
    }
}

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
/// **Observation.** `@Observable` rather than `ObservableObject`, because
/// invalidation here is per-delta and multiplied by however many agents are
/// running. `ObservableObject` announces the *object*: every view watching the
/// session — and, through `AgentPanel`'s forwarding, every view watching the
/// panel — was dirtied by a change to any one property. With ten agents
/// streaming, `sample` put 1017 main-thread samples inside
/// `AG::Graph::UpdateStack::update` with no app symbols beneath it: not bodies
/// running, but the graph being walked. `@Observable` tracks the properties a
/// view actually read, so a delta wakes what draws the transcript and nothing
/// else.
///
/// The rule for what stays observable: **a stored property is observed only if
/// a view body reads it.** Bookkeeping, callbacks, process handles and the raw
/// `entries` are `@ObservationIgnored` — the same split vendor/bonsplit made.
@Observable @MainActor
final class AgentSession {

    // MARK: - What a session is made of

    /// Who spoke. A turn from the leader and a turn from the person watching
    /// are identical on the wire — deliberately, so the agent cannot treat
    /// them differently — so the distinction is kept here, where it is only a
    /// label.
    enum Speaker: Equatable {
        case leader
        case person
    }

    enum Entry: Identifiable, Equatable {
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
        /// What this call did to a file, when it did something to a file.
        ///
        /// Held beside the headline rather than instead of it: a tool row is
        /// still a tool row — it spins, it fails, it is closed by the id its
        /// result carries — and a diff is one more thing it can say about
        /// itself.
        var change: AgentDiff.Change?
        var result: String?
        var failed: Bool = false
        var isRunning: Bool { result == nil }

        /// Whether there is anything under the fold. `result` is the empty
        /// string for a call whose turn ended without one, and testing that
        /// alone hid the control on rows that had a whole diff to show.
        var canExpand: Bool { change != nil || result?.isEmpty == false }
    }

    struct TurnEnd: Equatable {
        let stop: String
        let failed: Bool
        let cost: Double?
        let duration: TimeInterval?
        let tokensIn: Int?
        let tokensOut: Int?
        /// What the agent said about how it went, parsed rather than printed.
        var verdict: Verdict?
    }

    /// The 5-field header, held as fields.
    ///
    /// Measured on a real transcript: an agent's answer was six lines, five of
    /// them this header — 83% of the most-read element on screen was protocol.
    /// And the app was already parsing it to close the task, so it was being
    /// shown raw *and* read structurally. Only one of those is necessary.
    struct Verdict: Equatable {
        var status: String
        var files: String
        var verify: String
        var next: String
        var fullReport: String

        static let keys = ["STATUS", "FILES", "VERIFY", "NEXT", "FULL_REPORT"]

        var isDone: Bool { status.uppercased().hasPrefix("DONE") }
        var isBlocked: Bool { status.uppercased().hasPrefix("BLOCKED") }

        /// The fields worth a second look. `none` / `n/a` / `NONE` are the
        /// agent saying "nothing here", and showing five of those is worse
        /// than showing none.
        var details: [(String, String)] {
            [("FILES", files), ("VERIFY", verify), ("NEXT", next),
             ("FULL_REPORT", fullReport)]
                .filter { !["", "none", "n/a", "none.", "nothing"].contains($0.1.lowercased()) }
        }
    }

    /// Pull the header out of an answer, and hand back the answer without it.
    static func splitVerdict(from text: String) -> (body: String, verdict: Verdict?) {
        var fields: [String: String] = [:]
        var kept: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let key = Verdict.keys.first {
                line.hasPrefix($0 + ":") && fields[$0] == nil
            }
            if let key {
                fields[key] = String(line.dropFirst(key.count + 1))
                    .trimmingCharacters(in: .whitespaces)
            } else {
                kept.append(raw)
            }
        }
        guard fields["STATUS"] != nil else { return (text, nil) }
        let body = kept.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, Verdict(status: fields["STATUS"] ?? "",
                              files: fields["FILES"] ?? "",
                              verify: fields["VERIFY"] ?? "",
                              next: fields["NEXT"] ?? "",
                              fullReport: fields["FULL_REPORT"] ?? ""))
    }

    /// What an instruction actually asks for, separated from the protocol it
    /// travels in.
    ///
    /// Measured: sixteen lines, nine of them scaffold, the intent one line
    /// inside `[GOAL]`. The bubble was showing the envelope and burying the
    /// letter.
    struct Instruction: Equatable {
        var headline: String
        var taskId: String?
        var full: String
        var hasMore: Bool { headline.count < full.trimmingCharacters(in: .whitespacesAndNewlines).count }
    }

    static func read(instruction text: String) -> Instruction {
        let taskId = Self.taskId(in: text)
        let lines = text.components(separatedBy: "\n")

        // A capsule names its goal outright; nothing else needs guessing.
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[GOAL]" }),
           let close = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[/GOAL]" }),
           close > open {
            let goal = lines[(open + 1)..<close].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !goal.isEmpty {
                return Instruction(headline: goal, taskId: taskId, full: text)
            }
        }

        // Only a capsule gets folded. Everything else is shown whole.
        //
        // Filtering by line prefix alone ate two real lines out of a runbook
        // digest — its `VERIFY:` and `OUTPUT:` rows, which say what the role
        // must do — because those prefixes are also header keys. Hiding what
        // the leader actually said is worse than showing an envelope.
        let isCapsule = lines.contains {
            let l = $0.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("## Task Capsule") || l.hasPrefix("[FINAL LINE")
                || l.hasPrefix("[REQUIRED FINAL STEP")
        }
        guard isCapsule else {
            return Instruction(headline: text, taskId: taskId, full: text)
        }

        // Otherwise drop the lines that are unmistakably protocol and keep
        // what a person wrote.
        var fenced = false
        var kept: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fenced.toggle(); continue }
            if fenced { continue }
            if line.hasPrefix("[FINAL LINE") || line.hasPrefix("[REQUIRED FINAL STEP")
                || line.hasPrefix("[REMINDER]") || line.hasPrefix("## Task Capsule")
                || line.hasPrefix("TASK_") || line.hasPrefix("PROTOCOL:")
                || line.hasPrefix("OUTPUT:")
                || Verdict.keys.contains(where: { line.hasPrefix($0 + ":") }) {
                continue
            }
            kept.append(raw)
        }
        let headline = kept.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Instruction(headline: headline.isEmpty ? text : headline,
                           taskId: taskId, full: text)
    }

    // MARK: - State

    /// The model's own history, deliberately outside observation.
    ///
    /// No view reads this — the panel draws `rows`, the bounded projection
    /// below. Observing it would mean every streamed character invalidated the
    /// transcript twice: once here and once when the projection it feeds is
    /// rebuilt. `withEntryTransaction` still collapses a whole pipe read into
    /// one `publishEntries()`, so N deltas remain one announcement.
    @ObservationIgnored private(set) var entries: [Entry] = [] {
        didSet {
            if oldValue.count != entries.count ||
                !zip(oldValue, entries).allSatisfy({ $0.0.id == $0.1.id }) {
                rowsStructureDirty = true
            } else {
                for (old, new) in zip(oldValue, entries) where old != new {
                    dirtyEntryIDs.insert(new.id)
                }
            }
            entriesDirty = true
            if mutationDepth == 0 { publishEntries() }
        }
    }

    /// A pipe read can contain hundreds of character deltas. Apply the whole
    /// read as one model transaction so row projection and SwiftUI invalidation
    /// happen once, not once per character.
    @ObservationIgnored private var mutationDepth = 0
    @ObservationIgnored private var entriesDirty = false
    @ObservationIgnored private var rowsStructureDirty = true
    @ObservationIgnored private var dirtyEntryIDs: Set<UUID> = []
    /// The bound `rows` was last built with. Only differs from
    /// `maxRenderedEntries` when the override moved between two publishes.
    @ObservationIgnored private var renderedBound = 0

    private func withEntryTransaction(_ body: () -> Void) {
        mutationDepth += 1
        body()
        mutationDepth -= 1
        if mutationDepth == 0, entriesDirty { publishEntries() }
    }

    private func publishEntries() {
        guard entriesDirty else { return }
        entriesDirty = false
        // The incremental branch below maps `rows[relative]` onto
        // `entries[displayStart + relative]` and uses `rows.count` as the width
        // of the window. That substitution holds only while the bound is the
        // one `rows` was built with, so a change of bound has to rebuild in
        // full — otherwise `displayStart` moves under an array that did not,
        // and the branch reads past the end of `entries`.
        let bound = Self.maxRenderedEntries
        if rowsStructureDirty || renderedBound != bound {
            let display = Self.displayRows(for: entries)
            rows = display.rows
            omittedEntryCount = display.omitted
            renderedBound = bound
        } else if !dirtyEntryIDs.isEmpty {
            let displayStart = max(0, entries.count - bound)
            var relativeIndexes = Set<Int>()
            for id in dirtyEntryIDs {
                guard let absolute = entries.firstIndex(where: { $0.id == id }),
                      absolute >= displayStart else { continue }
                let relative = absolute - displayStart
                relativeIndexes.insert(relative)
                if relative + 1 < rows.count { relativeIndexes.insert(relative + 1) }
            }
            for relative in relativeIndexes.sorted() where relative < rows.count {
                let absolute = displayStart + relative
                let entry = entries[absolute]
                let previous = absolute > displayStart ? entries[absolute - 1] : nil
                rows[relative] = Row(
                    id: entry.id,
                    topGap: Self.topGap(before: entry, after: previous),
                    entry: entry
                )
            }
        }
        rowsStructureDirty = false
        dirtyEntryIDs.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    /// One transcript row, with its identity and its spacing already decided.
    ///
    /// The view used to derive both per body evaluation, from
    /// `Array(entries.enumerated())` keyed on `\.element.id`. That made identity
    /// a read *through* the enum, so a layout pass copied every entry's payload
    /// once per item it placed; and the row's top padding read
    /// `entries[index - 1]`, which makes a row's geometry depend on its
    /// neighbour — inside a `LazyVStack`, a placement pass that can re-enter
    /// itself. Together they pinned the main thread at 100% with the view graph
    /// never converging (observed: a 25-minute hang whose every backtrace sat in
    /// `AG::Graph::UpdateStack::update`, under `LazyStack.place(subviews:)`).
    ///
    /// Deciding both here costs one pass per mutation instead of one per layout,
    /// and leaves `id` a stored property that nothing has to unwrap an enum to
    /// read.
    /// `Equatable` so the view layer can tell an unchanged row from a changed
    /// one: the transcript mounts this whole window in a non-lazy stack, and a
    /// streamed delta usually rewrites exactly one row.
    struct Row: Identifiable, Equatable {
        let id: UUID
        /// Presentation, in the model on purpose: it is a function of which
        /// *kinds* of entry sit next to each other, so it can only be settled
        /// where the neighbours are already in hand.
        let topGap: CGFloat
        let entry: Entry
    }

    /// The recent transcript window as the view consumes it.
    ///
    /// The complete, capped transcript remains in `entries` for result parsing
    /// and diagnostics. Rendering every retained entry in a non-lazy stack
    /// would trade the `LazyVStack` placement spin for an increasingly heavy
    /// view tree, so the panel only keeps a bounded recent window mounted.
    private(set) var rows: [Row] = []
    private(set) var omittedEntryCount = 0

    /// Spacing is uniform no longer: a turn runs instruction → thinking → tools
    /// → answer → footer, and at one gap for everything those five read as five
    /// unrelated rows. Tight inside a turn, open between them.
    static func topGap(before entry: Entry, after previous: Entry?) -> CGFloat {
        guard let previous else { return 12 }
        if case .turnEnded = previous { return 20 }
        if case .said = entry { return 20 }
        if case .turnEnded = entry { return 6 }
        switch (previous, entry) {
        // Reasoning and the tools it drives are one train of thought.
        case (.thought, .tool), (.tool, .thought), (.tool, .tool): return 4
        default: return 8
        }
    }

    static func rows(for entries: [Entry]) -> [Row] {
        var previous: Entry?
        return entries.map { entry in
            defer { previous = entry }
            return Row(id: entry.id,
                       topGap: topGap(before: entry, after: previous),
                       entry: entry)
        }
    }

    /// Keep SwiftUI's mounted transcript bounded while retaining the longer
    /// model history above. A native agent can emit hundreds of tool events in
    /// one task; mounting all 2,000 rich rows makes every streamed delta more
    /// expensive even after lazy placement is removed.
    static func displayRows(for entries: [Entry]) -> (omitted: Int, rows: [Row]) {
        let omitted = max(0, entries.count - maxRenderedEntries)
        return (omitted, rows(for: Array(entries.suffix(maxRenderedEntries))))
    }

    /// 300 is the shipped bound. The override exists so the bound itself can be
    /// measured: the transcript stack is not lazy, so `ScrollView` sizes every
    /// mounted row on each streamed delta, and that cost scales with this number
    /// even for rows `TranscriptRow`'s `Equatable` already spared a body pass.
    /// Whether that sizing is a large share of the streaming cost or a rounding
    /// error is unmeasured — and two builds cannot answer it, because the
    /// workload cannot be reproduced across them. Reading it live lets one app
    /// carry one workload through both settings:
    ///
    ///   defaults write <bundle id> agentMaxRenderedEntries -int 50
    ///
    /// `publishEntries` must rebuild in full when this changes; see the note
    /// there. Delete the key to return to 300.
    static var maxRenderedEntries: Int {
        let override = UserDefaults.standard.integer(forKey: "agentMaxRenderedEntries")
        return override > 0 ? override : 300
    }

    /// Changes on every mutation, not just every append.
    ///
    /// A view following the bottom cannot key on `entries.count`: a streamed
    /// answer grows an entry that is already there, so the count sits still
    /// while the text runs off the bottom of the pane. Observed, because
    /// `AgentPanelView` keys its auto-scroll on it; also a monotonic mutation
    /// counter, which is what the transaction tests assert on.
    private(set) var revision = 0
    #if DEBUG
    @ObservationIgnored private var debugAppliedBatches = 0
    @ObservationIgnored private var debugAppliedLines = 0
    @ObservationIgnored private var debugAppliedBytes = 0
    @ObservationIgnored private var debugAutoScrolls = 0
    @ObservationIgnored private var debugApplyTotalMs = 0.0
    @ObservationIgnored private var debugApplyMaxMs = 0.0
    #endif
    private(set) var isThinking = false {
        didSet {
            guard oldValue != isThinking else { return }
            onBusyChanged?(isThinking)
        }
    }

    /// Fired when a turn starts or ends.
    ///
    /// `isThinking` is the truth and it lives on the main actor, while the
    /// status RPC is served off it — so the fact has to be pushed somewhere an
    /// off-main reader can see, rather than pulled.
    @ObservationIgnored var onBusyChanged: ((Bool) -> Void)?
    private(set) var isRunning = false
    /// What the CLI announced about itself, shown once rather than per turn.
    private(set) var summary: String?

    /// Whether this agent's turn can be stopped. See `Launch.interruptible`.
    private(set) var canInterrupt = false

    /// Rows still being written, so the view can show a caret on them.
    ///
    /// Nothing else can say this. A terminal shows characters arriving and
    /// leaves "is it still coming, or did it stop there?" to be inferred from
    /// whether more shows up — which is the same inference the completion
    /// detector had to make, one layer down.
    private(set) var streamingIds: Set<UUID> = []

    /// Called when a turn ends, with the agent's final text. The task-board
    /// side reads its own header out of this; the session does not interpret it.
    @ObservationIgnored var onTurnEnd: ((String, TurnEnd, String?) -> Void)?

    // MARK: - Turn-state writes
    //
    // `@Observable` invalidates on *assignment*, not on change. The turn
    // boundaries below assign unconditionally — `isThinking = false` runs on
    // every result event whether or not a turn was in flight — and each of
    // those woke every view reading the property for no visible difference.
    // `isThinking`'s `didSet` already guarded the *callback*; these guard the
    // write itself, which is what observation keys on. Same shape as
    // bonsplit's `focusPane` redundant-write guard.

    private func setThinking(_ value: Bool) {
        guard isThinking != value else { return }
        isThinking = value
    }

    private func setRunning(_ value: Bool) {
        guard isRunning != value else { return }
        isRunning = value
    }

    private func setCanInterrupt(_ value: Bool) {
        guard canInterrupt != value else { return }
        canInterrupt = value
    }

    private func clearStreamingIds() {
        guard !streamingIds.isEmpty else { return }
        streamingIds.removeAll()
    }

    /// Lifecycle state is confined to `queue`. `ioLock` protects FileHandle reads
    /// against asynchronous close; MainActor never waits on either synchronization
    /// primitive.
    private final class StreamResources: @unchecked Sendable {
        let output: FileHandle
        let error: FileHandle
        let queue = DispatchQueue(label: "com.termmesh.agent-session.stream")

        /// Read and written only on `queue`.
        var closed = false
        var stdoutEOF = false
        var terminationStatus: Int32?
        var finishScheduled = false
        let decoder = AgentStreamDecoder(maxLineBytes: AgentStreamDecoder.defaultMaxLineBytes)
        var pending: [AgentParsedLine] = []
        var pendingBytes = 0
        var flushScheduled = false

        /// Protects FileHandle read/notification/close operations only.
        private let ioLock = NSLock()
        private var handlesClosed = false

        init(output: FileHandle, error: FileHandle) {
            self.output = output
            self.error = error
        }

        /// Called by a Foundation readability callback, never by `queue`.
        /// The callback must enqueue its event before this method releases the
        /// lock, so a later EOF callback cannot overtake an earlier data callback.
        func withAvailableData(
            _ handle: FileHandle,
            enqueue: (Data) -> Void
        ) {
            ioLock.lock()
            defer { ioLock.unlock() }
            guard !handlesClosed else { return }
            enqueue(handle.availableData)
        }

        func stopOutputNotifications() {
            ioLock.lock()
            output.readabilityHandler = nil
            ioLock.unlock()
        }

        func stopErrorNotifications() {
            ioLock.lock()
            error.readabilityHandler = nil
            ioLock.unlock()
        }

        /// Called asynchronously from `queue`, never synchronously by MainActor.
        func closeHandles() {
            ioLock.lock()
            defer { ioLock.unlock() }
            guard !handlesClosed else { return }
            handlesClosed = true
            output.readabilityHandler = nil
            error.readabilityHandler = nil
            try? output.close()
            try? error.close()
        }

        /// Called only on `queue`. Whichever signal arrives second claims the one
        /// permitted natural-finish dispatch.
        func takeFinishCodeIfReady() -> Int32? {
            guard !closed, stdoutEOF, !finishScheduled,
                  let terminationStatus else { return nil }
            finishScheduled = true
            return terminationStatus
        }

        /// Called only on `queue`. At most one timer is outstanding.
        func enqueue(_ parsed: [AgentParsedLine], flush: @escaping @Sendable ([AgentParsedLine]) -> Void) {
            guard !parsed.isEmpty else { return }
            for item in parsed {
                if let last = pending.last, let merged = last.merging(item) {
                    pending[pending.count - 1] = merged
                } else {
                    pending.append(item)
                }
                pendingBytes += item.sourceBytes
                if pendingBytes >= AgentStreamDecoder.maxPendingBatchBytes {
                    flushPending(flush)
                }
            }
            if parsed.contains(where: \.isBarrier) {
                flushPending(flush)
                return
            }
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + AgentStreamDecoder.batchInterval) { [weak self] in
                self?.flushPending(flush)
            }
        }

        func flushPending(_ flush: @escaping @Sendable ([AgentParsedLine]) -> Void) {
            flushScheduled = false
            guard !pending.isEmpty else { return }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            flush(batch)
        }
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: FileHandle?
    @ObservationIgnored private var streamResources: StreamResources?
    /// Bytes, not a string.
    ///
    /// A pipe read ends wherever the kernel handed the buffer over, which can
    /// be the middle of a multi-byte character. Decoding each chunk on arrival
    /// and dropping it when that fails loses the whole chunk — for a Korean
    /// answer that is most of a line, and if the line it lands in is `result`
    /// the turn never ends at all. Split on newlines in the bytes; decode only
    /// what is whole.
    @ObservationIgnored private var directDecoder = AgentStreamDecoder(maxLineBytes: AgentSession.maxLineBytes)

    /// A line that never arrives must not grow forever. Far above any real
    /// event: a long tool result is tens of kilobytes.
    private static let maxLineBytes = AgentStreamDecoder.defaultMaxLineBytes

    /// How long stdout may stay open after the agent itself has gone.
    ///
    /// EOF is the right signal and it is not a guaranteed one: a descendant
    /// that inherited the write end — a server a Bash tool left running, a
    /// stalled `ssh` — holds the pipe open after the process it belonged to
    /// exited. Waiting for EOF unconditionally then means the turn never ends,
    /// the task sits `in_progress`, and every instruction behind it waits on a
    /// queue nothing will drain. Long enough that a normal exit is never cut
    /// short (EOF arrives with the exit, not seconds after it), short enough
    /// that nobody is left watching a pane that has already finished.
    static let drainGrace: TimeInterval = 2

    /// Tool calls waiting for their result, keyed by the id the events use.
    @ObservationIgnored private var openTools: [String: Int] = [:]
    /// Assistant text for the turn in flight, so `result` can be trusted to
    /// carry the final answer without the model having to be reassembled.
    @ObservationIgnored private var saidThisTurn: [String] = []

    /// Content blocks being streamed, keyed by the index the events use, held
    /// as positions in `entries` so a delta lands on the row it belongs to.
    ///
    /// A message arrives twice under `--include-partial-messages`: once as
    /// deltas, then again whole. Both would draw it, so the second is skipped
    /// for whatever the first already built — but only for that, since tool
    /// calls only ever arrive complete.
    @ObservationIgnored private var streamOpen: [Int: Int] = [:]
    @ObservationIgnored private var streamedThisMessage = false

    // MARK: - Running

    struct Launch {
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        /// Whether a turn can be cancelled without killing the session.
        ///
        /// Claude takes `control_request` / `interrupt` on the same stdin as
        /// its turns — measured: the turn ends in half a second, the process
        /// lives, and the next turn still answers with its context intact. The
        /// bridged CLIs have their own cancel verbs and none of them have been
        /// measured, so their panes do not offer a button that might do
        /// something else.
        var interruptible = false
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
                      workingDirectory: workingDirectory, environment: environment,
                      interruptible: true)
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
        cliPath: String = "",
        workingDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Launch {
        var args = [bridgePath, "--cli", cli, "--cwd", workingDirectory]
        if !model.isEmpty { args += ["--model", model] }
        // The path Settings resolved, so the bridge runs the binary the user
        // chose rather than whichever one PATH happens to find.
        if !cliPath.isEmpty { args += ["--exe", cliPath] }
        return Launch(executable: "/usr/bin/env",
                      arguments: AgentPipeTransport.bridgeInterpreter(for: bridgePath) + args,
                      workingDirectory: workingDirectory,
                      environment: environment)
    }

    /// Hold a Claude process on an SSH peer in this app's native pane.
    ///
    /// SSH carries the same stdin/stdout stream that a local native pane uses.
    /// The remote shell exists only to load the peer's login PATH and replace
    /// itself with Claude; no terminal surface is created or attached.
    static func remoteClaudeLaunch(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        model: String,
        instructions: String,
        extraArgs: [String] = [],
        workingDirectory: String,
        remoteEnvironment: [String: String] = [:]
    ) -> Launch {
        let claude = claudeLaunch(
            claudePath: "claude",
            model: model,
            instructions: instructions,
            extraArgs: extraArgs,
            workingDirectory: workingDirectory,
            environment: [:]
        )
        let command = remoteCommand(
            executable: claude.executable,
            arguments: claude.arguments,
            workingDirectory: workingDirectory,
            environment: remoteEnvironment
        )
        return Launch(
            executable: "/usr/bin/ssh",
            arguments: sshArguments(
                target: sshTarget,
                port: port,
                identityFile: identityFile
            ) + [command],
            // `Process` needs a local directory. The requested directory lives
            // on the peer and is created by `remoteCommand`.
            workingDirectory: FileManager.default.temporaryDirectory.path,
            environment: ProcessInfo.processInfo.environment,
            interruptible: true
        )
    }

    /// Run the normal local protocol bridge while its child CLI lives on the
    /// peer. This keeps Codex/Kiro/Cursor normalization local and sends only
    /// the child process across SSH.
    static func remoteBridgeLaunch(
        cli: String,
        bridgePath: String,
        model: String,
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        workingDirectory: String,
        remoteEnvironment: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Launch {
        var env = environment
        let ssh = ["/usr/bin/ssh"] + sshArguments(
            target: sshTarget,
            port: port,
            identityFile: identityFile
        )
        if let encoded = try? JSONSerialization.data(withJSONObject: ssh),
           let value = String(data: encoded, encoding: .utf8) {
            env["TERMMESH_REMOTE_NATIVE_SSH_ARGS"] = value
        }
        env["TERMMESH_REMOTE_NATIVE_CWD"] = workingDirectory
        if let encoded = try? JSONSerialization.data(withJSONObject: remoteEnvironment),
           let value = String(data: encoded, encoding: .utf8) {
            env["TERMMESH_REMOTE_NATIVE_ENV"] = value
        }

        var args = [bridgePath, "--cli", cli, "--cwd", workingDirectory]
        if !model.isEmpty { args += ["--model", model] }
        return Launch(
            executable: "/usr/bin/env",
            arguments: AgentPipeTransport.bridgeInterpreter(for: bridgePath) + args,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            environment: env
        )
    }

    static func sshArguments(
        target: String,
        port: Int?,
        identityFile: String?
    ) -> [String] {
        var args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        if let port { args += ["-p", String(port)] }
        if let identityFile, !identityFile.isEmpty { args += ["-i", identityFile] }
        args.append(target)
        return args
    }

    private static func remoteCommand(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String]
    ) -> String {
        let directory = shellQuoted(workingDirectory)
        // Peer terminal surfaces receive this from term-meshd. Keep native SSH
        // equivalent: Claude otherwise rejects explicit bypass mode for a root
        // peer even though the same agent works in the relay terminal path.
        let assignments = environment
            .filter { $0.key != "PATH" }
            .filter { isSafeEnvironmentKey($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let launch = (["env", "IS_SANDBOX=1"] + assignments + [executable] + arguments)
            .map(shellQuoted)
            .joined(separator: " ")
        let remotePath = "$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:"
            + "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let loginLaunch = shellQuoted(
            "export PATH=\"\(remotePath)\"; exec \(launch)"
        )
        return "mkdir -p \(directory) && cd \(directory) && "
            + "exec \"${SHELL:-/bin/sh}\" -lc \(loginLaunch)"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isSafeEnvironmentKey(_ value: String) -> Bool {
        guard let first = value.first,
              first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
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
        let streams = StreamResources(
            output: out.fileHandleForReading,
            error: err.fileHandleForReading
        )

        streams.output.readabilityHandler = { [weak self, weak p, streams] handle in
            // The callback is invoked for readable data or EOF. Do not move this read
            // onto `streams.queue`: only completed read events belong on that queue.
            streams.withAvailableData(handle) { data in
                streams.queue.async {
                    guard !streams.closed else { return }
                    if !data.isEmpty {
                        let parsed = streams.decoder.consume(data).map { output -> AgentParsedLine in
                            switch output {
                            case .line(let line):
                                return AgentParsedLine(line)
                            case .oversized(let count):
                                return AgentParsedLine(
                                    "dropped an unterminated line of \(count) bytes"
                                )
                            }
                        }
                        streams.enqueue(parsed) { [weak self, weak p] batch in
                            DispatchQueue.main.async { [weak self, weak p] in
                                guard let self, let p, self.process === p else { return }
                                self.apply(batch)
                            }
                        }
                        return
                    }

                    // Empty availableData is FileHandle's EOF signal. All earlier
                    // stdout events were enqueued under ioLock before this event.
                    streams.stopOutputNotifications()
                    streams.stdoutEOF = true
                    streams.flushPending { [weak self, weak p] batch in
                        DispatchQueue.main.async { [weak self, weak p] in
                            guard let self, let p, self.process === p else { return }
                            self.apply(batch)
                        }
                    }
                    guard let code = streams.takeFinishCodeIfReady() else { return }
                    DispatchQueue.main.async { [weak self, weak p] in
                        guard let self, let p, self.process === p else { return }
                        self.finish(process: p, code: code)
                    }
                }
            }
        }
        // Kept separate rather than merged into stdout: a warning is not an
        // event, and folding it in would make the stream unparseable exactly
        // when something has gone wrong.
        streams.error.readabilityHandler = { [weak self, weak p, streams] handle in
            streams.withAvailableData(handle) { data in
                streams.queue.async {
                    guard !streams.closed else { return }
                    guard !data.isEmpty else {
                        streams.stopErrorNotifications()
                        return
                    }
                    guard let text = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return }
                    DispatchQueue.main.async { [weak self, weak p] in
                        guard let self, let p, self.process === p else { return }
                        self.append(.notice(id: UUID(), AgentSession.withoutAnsi(text)))
                    }
                }
            }
        }
        p.terminationHandler = { [weak self, streams] proc in
            let code = proc.terminationStatus
            streams.queue.async {
                guard !streams.closed else { return }
                streams.terminationStatus = code
                // Do not remove the stdout handler here. It remains responsible for
                // draining all data and observing EOF, even after the parent exits.
                if let code = streams.takeFinishCodeIfReady() {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.process === proc else { return }
                        self.finish(process: proc, code: code)
                    }
                    return
                }
                // EOF has not arrived, and it may never: see `drainGrace`. The
                // fallback runs on the same serial queue as every other stream
                // event, so it cannot race the EOF it is covering for —
                // whichever gets there first takes the one permitted finish.
                streams.queue.asyncAfter(deadline: .now() + AgentSession.drainGrace) {
                    guard !streams.closed, !streams.stdoutEOF else { return }
                    streams.stopOutputNotifications()
                    streams.stdoutEOF = true
                    guard let code = streams.takeFinishCodeIfReady() else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.process === proc else { return }
                        self.finish(process: proc, code: code, drainedFully: false)
                    }
                }
            }
        }

        // Publish ownership before run: a process can print and exit before
        // `run()` returns, and its callbacks must already have an identity to
        // compare against.
        process = p
        stdin = input.fileHandleForWriting
        streamResources = streams
        do {
            try p.run()
        } catch {
            _ = teardown(process: p, terminate: false)
            append(.notice(id: UUID(), "could not start the agent: \(error.localizedDescription)"))
            return
        }
        setRunning(true)
        setCanInterrupt(launch.interruptible)
    }

    func stop() {
        guard let process else { return }
        _ = teardown(process: process, terminate: true)
        // A deliberate stop is still the end of whatever turn was running, and
        // the same thing `finishAfterDrain` was written for is true of it: the
        // turn is not going to end on its own, so its task would sit
        // `in_progress` for a pane that has gone while every instruction behind
        // it waited on a queue nothing will drain. Closing a pane mid-turn was
        // measured leaving exactly that. Nobody said the work succeeded, so it
        // reports as NEEDS_REVIEW — the same verdict a process that died gets.
        finishAfterDrain(code: 0, stopped: true)
    }

    /// The sole natural-exit entry point. The stream queue has already drained
    /// stdout through EOF; its dispatches to the main queue are FIFO, so this
    /// block runs after every preceding `consume` from that process.
    ///
    /// `drainedFully` is false when the grace above ended the wait rather than
    /// EOF: the agent's last words may be missing, and a pane that quietly
    /// dropped them would be indistinguishable from one that had nothing more
    /// to say.
    private func finish(process expected: Process, code: Int32,
                        drainedFully: Bool = true) {
        guard process === expected else { return }
        // A result frame normally starts the next queued turn. This process has
        // exited, so keep that queue intact for finishAfterDrain to report.
        setRunning(false)
        guard teardown(process: expected, terminate: false) else { return }
        if !drainedFully {
            append(.notice(id: UUID(),
                           "the agent exited but something still holds its output open; "
                               + "finished after \(Int(Self.drainGrace))s without the rest of it"))
        }
        finishAfterDrain(code: code)
    }

    /// Release process resources exactly once. The identity check makes a late
    /// callback from an old process unable to tear down a restarted session;
    /// clearing `process` makes repeated calls for one process harmless.
    @discardableResult
    private func teardown(process expected: Process, terminate: Bool) -> Bool {
        guard process === expected else { return false }

        // A deliberate stop owns completion and must not later become a second
        // process-exited finish when Foundation reports the signal.
        expected.terminationHandler = nil
        if terminate, expected.isRunning { expected.terminate() }

        let streams = streamResources
        let input = stdin

        // Revoke actor-owned identity first. Any already-dispatched data or finish from
        // this process fails its `self.process === expected` guard after this point.
        stdin = nil
        streamResources = nil
        process = nil
        directDecoder = AgentStreamDecoder(maxLineBytes: Self.maxLineBytes)
        setRunning(false)
        setCanInterrupt(false)

        // Closing our stdin descriptor is a local close, not a drain or wait.
        try? input?.close()

        // Never synchronously wait from MainActor for stream cleanup. This queue only
        // processes completed Data/EOF events, so cleanup always makes progress.
        streams?.queue.async {
            guard let streams, !streams.closed else { return }
            streams.closed = true
            streams.closeHandles()
        }
        return true
    }

    private func finishAfterDrain(code: Int32, stopped: Bool = false) {
        setThinking(false)
        streamOpen.removeAll()
        clearStreamingIds()
        if code != 0 {
            append(.notice(id: UUID(), "the agent exited (\(code))"))
        }
        // A turn that was running when the process went is not going to end on
        // its own, and its task would sit `in_progress` forever while every
        // instruction behind it waited on a queue that will never drain.
        if turnInFlight {
            let end = TurnEnd(stop: stopped ? "session_stopped" : "process_exited",
                              failed: true, cost: nil,
                              duration: nil, tokensIn: nil, tokensOut: nil)
            append(.turnEnded(id: UUID(), end))
            let answered = currentTaskId
            currentTaskId = nil
            turnInFlight = false
            // No STATUS, so this reads as NEEDS_REVIEW rather than a success —
            // nobody said it worked, and the agent is not there to say.
            onTurnEnd?(stopped ? "the session was stopped before this turn finished"
                               : "the agent exited before finishing this turn",
                       end, answered)
        }
        if !queued.isEmpty {
            append(.notice(id: UUID(),
                           "\(queued.count) queued instruction(s) were never delivered"))
            queued.removeAll()
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
        // Native turns report completion from their result event. Peer-proxied
        // worktree delegates can bypass deliverNatively(), so strip terminal
        // completion instructions again at the final stdin boundary.
        let deliveredText = speaker == .leader
            ? TeamOrchestrator.withoutTerminalProtocol(text)
            : text
        if speaker == .leader, turnInFlight {
            queued.append((deliveredText, Self.taskId(in: deliveredText)))
            return 0
        }
        return try write(
            deliveredText,
            from: speaker,
            taskId: Self.taskId(in: deliveredText)
        )
    }

    /// Whether a turn is running, whoever started it.
    ///
    /// This used to be set only for leader writes, so a person typing in the
    /// composer left it false — and a task arriving during that turn was
    /// written straight into the same stdin, taking `currentTaskId` with it.
    /// The person's `result` would then close the leader's task, or the CLI
    /// would merge the two and one completion would simply never arrive.
    @ObservationIgnored private var turnInFlight = false

    @discardableResult
    private func write(_ text: String, from speaker: Speaker, taskId: String?) throws -> Int {
        guard let stdin, isRunning else { throw SendError.notRunning }
        let payload = try Self.encode(text: text)
        try stdin.write(contentsOf: payload)
        // Shown from the receipt (`isReplay`) rather than from here, so what is
        // drawn is what the agent confirmed receiving — not what was hoped for.
        pendingSpeaker = speaker
        // Any write opens a turn. Only a leader's carries a task.
        turnInFlight = true
        if speaker == .leader { currentTaskId = taskId }
        setThinking(true)
        return payload.count
    }

    /// The task this turn is answering, named by the capsule that carried it.
    ///
    /// The screen path could never make this correlation — an answer on a
    /// screen has nothing tying it to a request — so it guessed, and a reply
    /// was measured closing an unrelated blocked task. Here the instruction
    /// says which task it is, and this side is the one that wrote it.
    @ObservationIgnored private(set) var currentTaskId: String?

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

    @ObservationIgnored private var pendingSpeaker: Speaker = .leader

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
    @ObservationIgnored private var queued: [(text: String, taskId: String?)] = []

    static func encode(text: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "message": ["role": "user", "content": text],
        ])
        data.append(0x0A)
        return data
    }

    /// Stop the turn in flight, keeping the session.
    ///
    /// Not a signal and not a restart: claude reads this on the same stdin its
    /// turns arrive on, ends the turn, and carries on. Measured — half a
    /// second to `result`, process alive, next turn answered normally.
    func interrupt() {
        guard canInterrupt, turnInFlight || isThinking, let stdin else { return }
        let control: [String: Any] = [
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: control) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
        stopRequested = true
    }

    /// Set when the stop came from here, so the turn that ends a moment later
    /// can say "stopped" rather than `error_during_execution` — which is what
    /// claude calls it, and which reads like something went wrong.
    @ObservationIgnored private var stopRequested = false

    // MARK: - Reading the stream

    private func consume(_ data: Data) {
        withEntryTransaction {
            for output in directDecoder.consume(data) {
                switch output {
                case .line(let line):
                    handle(AgentParsedLine(line))
                case .oversized(let count):
                    append(.notice(
                        id: UUID(),
                        "dropped an unterminated line of \(count) bytes"
                    ))
                }
            }
        }
    }

    /// Production input is parsed off-main and arrives in coalesced batches.
    /// Tests still feed individual strings through `handle(_:)`, which keeps
    /// their synchronous contract while exercising the same event handlers.
    private func apply(_ batch: [AgentParsedLine]) {
        #if DEBUG
        let applyStarted = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - applyStarted) * 1_000
            debugApplyTotalMs += elapsed
            debugApplyMaxMs = max(debugApplyMaxMs, elapsed)
        }
        debugAppliedBatches += 1
        debugAppliedLines += batch.reduce(0) { $0 + $1.sourceLineCount }
        debugAppliedBytes += batch.reduce(0) { $0 + $1.sourceBytes }
        #endif
        withEntryTransaction {
            for parsed in batch { handle(parsed) }
        }
    }

    private func handle(_ parsed: AgentParsedLine) {
        guard let object = parsed.object else {
            append(.notice(id: UUID(), Self.withoutAnsi(parsed.raw)))
            return
        }
        handle(object, preparedChanges: parsed.preparedChanges,
               preparedToolIDs: parsed.preparedToolIDs)
    }

    private func handle(_ line: String) {
        withEntryTransaction { handle(AgentParsedLine(line)) }
    }

    private func handle(_ obj: [String: Any],
                        preparedChanges: [String: AgentDiff.Change] = [:],
                        preparedToolIDs: Set<String> = []) {
        switch obj["type"] as? String {
        case "system":  system(obj)
        case "user":    user(obj)
        case "assistant": assistant(obj, preparedChanges: preparedChanges,
                                      preparedToolIDs: preparedToolIDs)
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

    private func assistant(_ o: [String: Any],
                           preparedChanges: [String: AgentDiff.Change],
                           preparedToolIDs: Set<String>) {
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
                let toolId = block["id"] as? String
                openTool(block,
                         preparedChange: toolId.flatMap { preparedChanges[$0] },
                         changeWasPrepared: toolId.map(preparedToolIDs.contains) ?? false)
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
                append(.answered(id: UUID(), ""))
            case "thinking":
                append(.thought(id: UUID(), ""))
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

    private func openTool(_ block: [String: Any], preparedChange: AgentDiff.Change?,
                          changeWasPrepared: Bool) {
        let name = block["name"] as? String ?? "tool"
        let args = block["input"] as? [String: Any] ?? [:]
        // The one field that says what a call will do, per tool. A generic dump
        // buries it in schema.
        let headline = (args["command"] ?? args["file_path"] ?? args["pattern"]
                        ?? args["path"] ?? args["description"]) as? String ?? ""
        // The input already carries everything a diff needs; this was pulling
        // one string out of it and dropping the rest on the floor. Worked out
        // here, once, because a view's body is the one place it must never be.
        let change = changeWasPrepared
            ? preparedChange
            : AgentDiff.change(tool: name, input: args)
        append(.tool(id: UUID(),
                     ToolCall(name: name, headline: headline, change: change)))
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
        if let change = call.change {
            call.change = AgentDiff.refined(change, result: call.result ?? "",
                                            failed: call.failed)
        }
        entries[index] = .tool(id: entryId, call)
    }

    private func result(_ o: [String: Any]) {
        let usage = o["usage"] as? [String: Any] ?? [:]
        // A turn we stopped on purpose is not a failure.
        let failed = stopRequested ? false : (o["is_error"] as? Bool ?? false)
        let reason = o["stop_reason"] as? String ?? o["subtype"] as? String ?? "?"
        var end = TurnEnd(
            stop: stopRequested ? "stopped" : reason,
            failed: failed,
            cost: o["total_cost_usd"] as? Double,
            duration: (o["duration_ms"] as? Double).map { $0 / 1000 },
            tokensIn: usage["input_tokens"] as? Int,
            tokensOut: usage["output_tokens"] as? Int
        )
        // The header moves out of the prose and into the turn, where it is a
        // value the footer can render as a verdict. Shown raw *and* parsed was
        // paying for the same five lines twice.
        end.verdict = stripVerdictFromThisTurn()
        // A turn can end with blocks still open — an error, a stop, a killed
        // process. Leaving their carets on would say "still writing" forever.
        streamOpen.removeAll()
        clearStreamingIds()
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
        setThinking(false)
        turnInFlight = false
        stopRequested = false
        // `result` carries the final answer as a clean string — the boundary is
        // stated rather than inferred from a screen going quiet.
        let final = o["result"] as? String ?? saidThisTurn.joined(separator: "\n")
        saidThisTurn.removeAll()
        let answered = currentTaskId
        currentTaskId = nil
        onTurnEnd?(final, end, answered)

        // The next leader turn only now, so it gets a turn of its own.
        if isRunning, process?.isRunning == true, !queued.isEmpty {
            let next = queued.removeFirst()
            try? write(next.text, from: .leader, taskId: next.taskId)
        }
    }

    /// Take the header out of the answers this turn produced, and return it.
    ///
    /// Walks back only as far as the previous turn's end, so an earlier
    /// answer's header is never re-read.
    private func stripVerdictFromThisTurn() -> Verdict? {
        var found: Verdict?
        var index = entries.count - 1
        while index >= 0 {
            if case .turnEnded = entries[index] { break }
            if case .answered(let id, let text) = entries[index] {
                let (body, verdict) = Self.splitVerdict(from: text)
                if let verdict {
                    found = found ?? verdict
                    // An answer that was *only* a header leaves an empty row;
                    // drop it rather than show a blank one.
                    if body.isEmpty { entries.remove(at: index) }
                    else { entries[index] = .answered(id: id, body) }
                }
            }
            index -= 1
        }
        return found
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        trimToCap()
    }

    /// Drop the oldest entries once the session exceeds its cap.
    ///
    /// A long session is a memory leak with a scrollbar. The terminal had the
    /// same problem and answered it with a scrollback limit.
    ///
    /// `streamOpen` and `openTools` hold absolute positions into `entries`, so
    /// dropping from the front without shifting them leaves every open stream
    /// and tool call pointing one row per dropped entry too far back — deltas
    /// would land on someone else's text. That is the reason the two hottest
    /// append paths (streamed content, tool calls) could not simply call
    /// `append` before: they are the only ones that keep positions, they are
    /// the ones that need the cap most, and this is what makes it safe for
    /// them. An entry whose position falls inside the dropped range is gone,
    /// so its key is dropped with it.
    private func trimToCap() {
        guard entries.count > Self.maxEntries else { return }
        let dropped = entries.count - Self.maxEntries
        entries.removeFirst(dropped)
        streamOpen = streamOpen.compactMapValues { $0 >= dropped ? $0 - dropped : nil }
        openTools = openTools.compactMapValues { $0 >= dropped ? $0 - dropped : nil }
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
    struct RenderMetrics {
        let batches: Int
        let lines: Int
        let bytes: Int
        let revisions: Int
        let autoScrolls: Int
        let entries: Int
        let renderedRows: Int
        let applyTotalMs: Double
        let applyMaxMs: Double
    }

    func noteAutoScrollForDebug() { debugAutoScrolls += 1 }

    func renderMetricsForDebug() -> RenderMetrics {
        RenderMetrics(batches: debugAppliedBatches, lines: debugAppliedLines,
                      bytes: debugAppliedBytes, revisions: revision,
                      autoScrolls: debugAutoScrolls, entries: entries.count,
                      renderedRows: rows.count, applyTotalMs: debugApplyTotalMs,
                      applyMaxMs: debugApplyMaxMs)
    }

    /// Feed one line of the stream, as the reader would.
    func ingestForTesting(_ line: String) { handle(line) }

    /// Who the next receipt belongs to, without a process to send through.
    func noteSenderForTesting(_ speaker: Speaker) { pendingSpeaker = speaker }

    /// A leader turn in flight, without a process to write it to.
    func beginTurnForTesting(taskId: String?) {
        turnInFlight = true
        currentTaskId = taskId
    }

    /// A turn opened by either speaker, without a process.
    func openTurnForTesting(from speaker: Speaker, taskId: String? = nil) {
        pendingSpeaker = speaker
        turnInFlight = true
        setThinking(true)
        if speaker == .leader { currentTaskId = taskId }
    }

    /// A leader instruction arriving while a turn is already running.
    func queueForTesting(_ text: String) {
        queued.append((text, Self.taskId(in: text)))
    }

    /// Bytes as the reader would hand them over, boundaries and all.
    func consumeForTesting(_ data: Data) { consume(data) }

    /// A production-style parsed batch without a Process or pipe.
    func applyBatchForTesting(_ lines: [String]) {
        apply(lines.map(AgentParsedLine.init))
    }

    /// The process going away.
    func finishForTesting(code: Int32) { finishAfterDrain(code: code) }
    #endif
}
