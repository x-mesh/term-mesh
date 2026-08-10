import AppKit
import SwiftUI

/// The session, drawn as what it is rather than as characters.
///
/// The python renderer that came before this priced the work: a terminal can
/// only be sent text, so every distinction has to be re-encoded as colour and
/// rules and then read back by eye. Here the distinctions survive — a tool call
/// is a tool call, so it can carry a spinner while it runs and fold its output
/// when it is done; an answer is an answer, so it stays selectable text; a
/// turn's end is a value, so its cost and timing are laid out rather than
/// printed. None of that is available once it has been flattened into a grid.
struct AgentPanelView: View {
    @ObservedObject var panel: AgentPanel
    let isFocused: Bool
    /// Selected in its pane, in a showing workspace, not covered by a zoom.
    /// Forwarded to the session, which stops publishing its transcript while
    /// this is false — see `AgentSession.isVisible`.
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onFocus: () -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    /// Whether the view is following the bottom. Reading back through a
    /// transcript is the one thing auto-scroll must not fight.
    @State private var following = true
    /// When the last append happened, so the bottom leaving the screen because
    /// *we* grew the content is not mistaken for the user scrolling away.
    @State private var grewAt = Date.distantPast
    /// Which tool rows are open, held here rather than in the rows themselves.
    /// A `@State` inside a row of a `LazyVStack` is discarded when the row
    /// scrolls out of view, so an opened diff quietly closed itself on the way
    /// back — barely visible on a one-line result, impossible to miss on a
    /// diff someone was reading.
    @State private var openTools: Set<UUID> = []

    private var session: AgentSession { panel.session }

    /// The colour the team assigned this agent, which the pane title already
    /// shows as an emoji and the view was throwing away.
    private var accent: Color {
        switch panel.color {
        case "green":   return .green
        case "blue":    return .blue
        case "yellow":  return .yellow
        case "red":     return .red
        case "cyan":    return .cyan
        case "magenta": return .purple
        default:        return .secondary
        }
    }

    /// Role colour answers "which worker is this"; provider colour answers
    /// "which engine is behind it". Keeping both prevents a Claude executor
    /// and a Claude reviewer from collapsing into the same identity.
    private var providerAccent: Color {
        ProviderIdentity.readableAccent(
            for: panel.cli,
            colorScheme: colorScheme,
            fallback: accent
        )
    }

    private var providerMarkAccent: Color {
        ProviderIdentity.markAccent(for: panel.cli, fallback: accent)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().foregroundStyle(appearance.dividerColor)
            transcript
            Divider().foregroundStyle(appearance.dividerColor)
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Clicking anywhere in the pane puts the caret where typing goes, the
        // way clicking a terminal pane does. Reporting focus without taking the
        // caret would leave the pane focused and un-typeable.
        .onTapGesture {
            onFocus()
            composerFocused = true
        }
        // Clicking the composer is a click on the text field, not on the body
        // above, so the tap gesture never fired and the workspace went on
        // believing the previously focused pane — usually the leader terminal —
        // still had focus. A terminal told it is focused reclaims the window's
        // first responder whenever it re-lays out, and an agent pane re-lays
        // the workspace out on every streamed delta. The result was typing that
        // landed a few characters here and then continued in the leader's
        // shell: the pane could not be typed into at all while anything was
        // running. Taking focus has to be reported, not just accepted.
        .onChange(of: composerFocused) { _, focused in
            if focused { onFocus() }
        }
        // `initial: true` because a pane that is built already hidden — a
        // background workspace being restored, a tab that is not the selected
        // one — never gets a change to react to, and would otherwise publish
        // every delta of a transcript nobody has looked at yet.
        .onChange(of: isVisibleInUI, initial: true) { _, visible in
            session.isVisible = visible
        }
        .onAppear {
            panel.onFocusRequested { composerFocused = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            // The agent's own colour, as a rail rather than a dot: five panes
            // side by side were five identical grey lines, and a 7pt dot is
            // not something you pick a pane out by.
            Capsule().fill(accent).frame(width: 3, height: 15)
            // A pane can be narrow, and a wrapped name reads as two agents:
            // measured at a real width, this row broke into `explore / r` and
            // `CLAUD / E`. Identity never wraps and never yields; the model
            // summary is the part worth losing first, so it is the only thing
            // allowed to shrink.
            Text(panel.agentName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .fixedSize()
            CliBadge(cli: panel.cli, accent: providerAccent)
                .fixedSize()
            if let summary = session.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            if !session.isRunning {
                Text("stopped").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            // Two different facts, and the pane path could show neither: the
            // turn is open, and something is arriving right now. A turn can be
            // open and silent for a minute while a tool runs.
            if session.isThinking {
                Text(session.streamingIds.isEmpty ? "working" : "writing")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            WorkingHeaderBackground(
                accent: accent,
                isWorking: session.isThinking,
                isFocused: isFocused
            )
        }
    }

    // MARK: - The banner

    /// Said once, at the top, the way a CLI greets you when it starts.
    ///
    /// The header identifies the pane at a glance while scrolling; this says
    /// the things worth reading exactly once — which CLI, which model, which
    /// directory. Both exist because they answer different questions, and a
    /// banner that scrolls away cannot answer the first one.
    private var banner: some View {
        HStack(alignment: .top, spacing: 10) {
            Mascot(
                cli: panel.cli,
                rows: Self.mascot(for: panel.cli),
                fallbackAccent: providerMarkAccent
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.agentName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent)
                Text(panel.cli.uppercased())
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                if let summary = session.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(panel.workingDirectory)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(providerMarkAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(providerMarkAccent.opacity(0.35)))
    }

    /// A compact mark per CLI, in block characters, all nine columns wide so
    /// the banners retain one rhythm while each provider retains its silhouette.
    ///
    /// Provider colour is applied by `Mascot`: Claude stays coral, Cursor stays
    /// monochrome, and the two Google marks retain their multicolour identity.
    static func mascot(for cli: String) -> [String] {
        switch cli {
        case "claude":
            return [" ▐▛███▜▌ ",
                    "▝▜█████▛▘",
                    "  ▘▘ ▝▝  "]
        case "codex":
            return [" ▗▄▟█▙▄▖ ",
                    "▐█▛▘ ▝▜█▌",
                    " ▝▀▜█▛▀▘ "]
        case "kiro":
            return ["   ▗▄▖   ",
                    "  ▟███▙  ",
                    "  ▝▀▀▀▘  "]
        case "cursor":
            return ["  ▙▖     ",
                    "  ▐█▙▖   ",
                    "  ▐███▙▖ "]
        case "agy":
            return ["   ▟█▙   ",
                    "  ▟███▙  ",
                    " ▟█▛ ▜█▙ "]
        case "gemini":
            return ["  ▗▄▖▗▖  ",
                    " ▝█████▘ ",
                    "  ▘▝▀▘▝  "]
        default:
            return ["  ▗▄▄▄▖  ",
                    " ▐█████▌ ",
                    "  ▝▀▀▀▘  "]
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // This deliberately is not lazy. Instruments caught the
                    // main thread permanently inside
                    // `LazyStack.place(subviews:)` while streamed rows changed
                    // height. `AgentSession` bounds this mounted window, so a
                    // regular stack is finite and avoids that placement path.
                    VStack(alignment: .leading, spacing: 0) {
                        banner
                        if session.omittedEntryCount > 0 {
                            Text("Showing latest \(session.rows.count) events · "
                                 + "\(session.omittedEntryCount) earlier events hidden")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 10)
                                .accessibilityLabel(
                                    "\(session.omittedEntryCount) earlier transcript events hidden"
                                )
                        }
                        if session.rows.isEmpty { emptyState }
                        ForEach(session.rows) { item in
                            TranscriptRow(
                                item: item,
                                streaming: session.streamingIds.contains(item.id),
                                open: openTools.contains(item.id),
                                root: panel.workingDirectory,
                                setOpen: { open in
                                    // Opening a row grows the transcript exactly
                                    // as an append does, and the bottom anchor
                                    // cannot tell the two apart. Without touching
                                    // `grewAt` the anchor reads its own
                                    // disappearance as the user scrolling away,
                                    // and the "Latest" pill appears because
                                    // somebody expanded a diff.
                                    grewAt = Date()
                                    if open {
                                        openTools.insert(item.id)
                                    } else {
                                        openTools.remove(item.id)
                                    }
                                }
                            )
                            .equatable()
                            .id(item.id)
                        }
                        // A normal VStack mounts this marker even while it is
                        // off screen, so visibility is measured in the scroll
                        // coordinate space rather than inferred from onAppear.
                        GeometryReader { marker in
                            Color.clear.preference(
                                key: TranscriptBottomPreferenceKey.self,
                                value: marker.frame(in: .named(Self.scrollSpace)).maxY
                            )
                        }
                        .frame(height: 1)
                        .id(Self.bottom)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(TranscriptBottomPreferenceKey.self) { bottomY in
                    // Preferences are delivered during a view update. Mutating
                    // @State in that pass asks NSHostingView to lay itself out
                    // reentrantly, so apply the observation on the next main
                    // run-loop turn.
                    let viewportHeight = viewport.size.height
                    DispatchQueue.main.async {
                        let isAtBottom = bottomY <= viewportHeight + 2
                        if isAtBottom {
                            if !following { following = true }
                        } else if following, Date().timeIntervalSince(grewAt) > 0.4 {
                            following = false
                        }
                    }
                }
                // Every mutation, not every append: a streamed answer grows a
                // row that already exists, and keying on the count meant the
                // text ran off the bottom while the view sat still.
                .onChange(of: session.revision) { _, _ in
                    grewAt = Date()
                    guard following else { return }
                    // Unanimated on purpose. A 250-delta answer animating each
                    // step is not a smooth scroll, it is a stutter.
                    #if DEBUG
                    session.noteAutoScrollForDebug()
                    #endif
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !following {
                        Button {
                            following = true
                            withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
                }
            }
        }
    }

    private static let bottom = "bottom"
    private static let scrollSpace = "agent-transcript-scroll"

    // How much air a row needs above it is `AgentSession.topGap` — decided once
    // per mutation with the row, not per layout pass from its neighbour.

    /// What a pane says before anything has happened in it.
    ///
    /// "Nothing here" teaches nothing. A fresh pane's real question is "what is
    /// this and what do I do", and it has two answers worth one line each.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Waiting for the leader.")
                .font(.system(size: 12, weight: .medium))
            Text("Instructions from the leader appear here. "
                 + "You can also type below to talk to \(panel.agentName) yourself; "
                 + "it cannot tell the difference.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Composer

    /// The person's way in.
    ///
    /// On the terminal path this came free — the pane *was* the agent's stdin.
    /// On the pipe it had to be won back by reading `/dev/tty` from inside the
    /// pipeline. Here it is just a text field, and it can do what neither could:
    /// hold a multi-line draft without submitting on the first newline.
    private var composer: some View {
        AgentComposer(
            draft: $draft,
            focused: $composerFocused,
            agentName: panel.agentName,
            accent: accent,
            isThinking: session.isThinking,
            canStop: canStop,
            canSend: canSend,
            isFocused: isFocused,
            onSend: send,
            onStop: { session.interrupt() }
        )
        .equatable()
    }
}

/// The composer, isolated behind `Equatable`.
///
/// It is a text field and a button, but it sat in the panel's own body, so it
/// was re-evaluated on every streamed delta along with the transcript — one
/// more subtree for AttributeGraph to walk per token. Nothing it draws depends
/// on the transcript, so it should not move when the transcript does.
private struct AgentComposer: View, Equatable {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let agentName: String
    let accent: Color
    let isThinking: Bool
    let canStop: Bool
    let canSend: Bool
    let isFocused: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    /// `draft` is compared, and has to be: the field is the one thing here that
    /// the person is changing, and skipping its body would drop keystrokes.
    /// The two closures are not — the panel rebuilds them on every pass.
    /// Neither is `focused`: it is a binding the field attaches to, not
    /// something this view draws, and `FocusState.Binding` is not `Equatable`.
    ///
    /// `nonisolated` for the same reason `ReviewBoardTaskRow.==` carries it:
    /// `Equatable` is not actor-isolated, and the moment the enclosing view
    /// becomes `@MainActor` this conformance would cross that boundary — a
    /// warning today, an error under Swift 6. Everything compared is `Sendable`.
    nonisolated static func == (lhs: AgentComposer, rhs: AgentComposer) -> Bool {
        lhs.draft == rhs.draft
            && lhs.agentName == rhs.agentName
            && lhs.accent == rhs.accent
            && lhs.isThinking == rhs.isThinking
            && lhs.canStop == rhs.canStop
            && lhs.canSend == rhs.canSend
            && lhs.isFocused == rhs.isFocused
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(agentName)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...8)
                .focused(focused)
                .onSubmit(onSend)
            // Which of six panes is working is a question you answer by
            // glancing, not by reading. So the state has a shape — and it
            // lives here rather than over the transcript, where it landed on
            // the banner card and read as the banner's decoration. This row
            // never scrolls, is the same place in every pane, and puts "it is
            // working" next to "stop it".
            if isThinking {
                WorkingMark(accent: accent)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // One button, two jobs. A stop that only exists while a turn runs
            // has to live where your hand already is: a 9pt icon appearing at
            // the far end of the header for the three seconds a haiku turn
            // lasts is not a control anyone can find. Send and stop are also
            // never both available, so they are never two buttons.
            Button(action: canStop ? onStop : onSend) {
                Image(systemName: canStop ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(canStop ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .disabled(!canStop && !canSend)
            .help(canStop ? "Stop this turn" : "Send")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(isFocused ? 0.04 : 0.02))
        .animation(.easeOut(duration: 0.2), value: isThinking)
    }
}

extension AgentPanelView {
    private var canSend: Bool {
        session.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stopping wins while a turn is in flight — the one moment the button is
    /// worth pressing for something other than sending.
    private var canStop: Bool { session.isThinking && session.canInterrupt }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try session.send(text, from: .person)
            draft = ""
        } catch {
            // Said in the transcript rather than swallowed: a send that goes
            // nowhere while reporting success is the failure this whole path
            // exists to stop making.
            NSSound.beep()
        }
    }
}

private struct TranscriptBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// What was asked, with the protocol it travelled in folded away.
///
/// Measured on a real transcript: sixteen lines, nine of them scaffold, the
/// intent one line inside `[GOAL]`. The bubble was showing the envelope and
/// burying the letter. The envelope is still there for anyone who needs it.
/// One transcript row, isolated behind `Equatable`.
///
/// The transcript mounts its whole window in a non-lazy stack — `LazyVStack`
/// spun forever inside `LazyStack.place(subviews:)` while streamed rows changed
/// height — and `ScrollView` has to size that entire stack to know its scroll
/// range. So a streamed delta re-ran the layout for every mounted row to settle
/// a change that usually touches only the last one: with five agents streaming,
/// `sample` put 1088 of 5157 main-thread samples inside
/// `GeometryReaderLayout.placeSubviews` → `ScrollViewLayoutComputer.sizeThatFits`.
///
/// Equality lets SwiftUI skip the body *and* the re-measure for rows that did
/// not move, which is all of them but one during a stream.
private struct TranscriptRow: View, Equatable {
    let item: AgentSession.Row
    let streaming: Bool
    let open: Bool
    let root: String
    let setOpen: (Bool) -> Void

    /// `setOpen` is deliberately not compared: the parent rebuilds that closure
    /// on every body pass, so comparing it would defeat the shell entirely, and
    /// nothing it captures changes what this row draws.
    ///
    /// `nonisolated` matches `ReviewBoardTaskRow.==` — `Equatable` is not
    /// actor-isolated, so this conformance would cross the boundary as soon as
    /// the enclosing view is `@MainActor`. Everything compared is `Sendable`.
    nonisolated static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.item == rhs.item
            && lhs.streaming == rhs.streaming
            && lhs.open == rhs.open
            && lhs.root == rhs.root
    }

    var body: some View {
        content.padding(.top, item.topGap)
    }

    @ViewBuilder
    private var content: some View {
        switch item.entry {
        case .said(_, let speaker, let text):
            Instruction(speaker: speaker, read: AgentSession.read(instruction: text))
        case .answered(_, let text):
            // Selectable, because the reason to read an agent's answer is
            // usually to take something out of it. The caret says the row is
            // still being written — a terminal can only show characters
            // arriving and leave "did it stop there?" to be guessed.
            Answer(text: text, streaming: streaming)
        case .thought(_, let body):
            label("✻", (body?.isEmpty == false ? body! : "thinking"),
                  muted: true, streaming: streaming)
        case .tool(_, let call):
            if let change = call.change {
                ChangeRow(call: call, change: change, root: root, open: openBinding)
            } else {
                ToolRow(call: call, open: openBinding)
            }
        case .turnEnded(_, let end):
            TurnFooter(end: end, facts: Self.facts(end))
        case .notice(_, let text):
            label("!", text, muted: false)
        }
    }

    private var openBinding: Binding<Bool> {
        Binding(get: { open }, set: { setOpen($0) })
    }

    private func label(_ glyph: String, _ text: String, muted: Bool,
                       streaming: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(glyph).font(.system(size: 11))
            // Thinking streams too, and it is the part that runs longest with
            // nothing else to show. Pinned to the tail so a long reasoning
            // block does not push the pane around while it is written.
            Text(streaming ? String(text.suffix(120)) : text)
                .font(.system(size: 11))
                .lineLimit(muted ? 2 : nil)
            if streaming { Caret() }
        }
        .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
    }

    private static func facts(_ end: AgentSession.TurnEnd) -> String {
        var parts = [end.stop]
        if let d = end.duration { parts.append(String(format: "%.1fs", d)) }
        if let c = end.cost { parts.append(String(format: "$%.4f", c)) }
        if end.tokensIn != nil || end.tokensOut != nil {
            parts.append("\(end.tokensIn ?? 0)→\(end.tokensOut ?? 0) tok")
        }
        return parts.joined(separator: " · ")
    }
}

private struct Instruction: View {
    let speaker: AgentSession.Speaker
    let read: AgentSession.Instruction
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(speaker == .person ? "you" : "leader")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tint)
                if let id = read.taskId {
                    Text(id.prefix(8))
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if read.hasMore {
                    Button(expanded ? "less" : "protocol") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                }
            }
            MarkdownText(text: expanded ? read.full : read.headline)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The header's working state moves in the same direction as reading: a quiet
/// band travels left to right behind the identity and status. It complements
/// the persistent composer spinner without replacing it.
private struct WorkingHeaderBackground: View {
    let accent: Color
    let isWorking: Bool
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cycle: Double = 1.8

    var body: some View {
        ZStack {
            accent.opacity(isFocused ? 0.12 : 0.05)

            if isWorking {
                if reduceMotion {
                    LinearGradient(
                        colors: [
                            accent.opacity(0.04),
                            accent.opacity(0.14),
                            accent.opacity(0.04),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    AnimatedHeaderBand(accent: accent, duration: Self.cycle)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The end of a turn: the agent's verdict, and what the turn cost.
///
/// The five header fields used to be five lines of body text after every
/// answer — 83% of the most-read element on screen. They are values, so they
/// are laid out as values, and the ones the agent filled in with "none" are
/// not worth a row of their own.
private struct TurnFooter: View {
    let end: AgentSession.TurnEnd
    let facts: String
    @State private var expanded = false

    private var verdictColor: Color {
        guard let v = end.verdict else { return end.failed ? .red : .secondary }
        if end.failed || v.isBlocked { return .red }
        return v.isDone ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let v = end.verdict, !v.status.isEmpty {
                    Text(v.status)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(verdictColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(verdictColor)
                        // A verdict is the state, not expendable metadata.
                        // Keep it intact while the facts to its right truncate.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                }
                // Stated by the agent, not inferred from the screen going
                // quiet — the whole reason the pane path needed a timer here.
                // Allowed to truncate rather than run off the edge: in a narrow
                // pane it was being clipped mid-number.
                Text(facts)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(end.failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Rectangle().fill(.quaternary).frame(height: 1)
                if end.verdict?.details.isEmpty == false {
                    Button(expanded ? "less" : "details") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                }
            }
            if expanded, let v = end.verdict {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(v.details, id: \.0) { field, value in
                        HStack(alignment: .top, spacing: 6) {
                            Text(field)
                                .font(.system(size: 9, weight: .semibold).monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(width: 76, alignment: .leading)
                            Text(value)
                                .font(.system(size: 10).monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
    }
}

/// Block characters drawn tight enough to be a shape.
///
/// A `Text` holding all three rows would space them by the font's line height
/// and the blocks would not meet — the drawing only reads as one if the rows
/// touch, so each is its own row with the leading pulled out.
private enum ProviderIdentity {
    /// Brand colour used by the mark itself. It is decorative and can retain
    /// the provider's original saturation; text uses `readableAccent` below.
    static func markAccent(for cli: String, fallback: Color) -> Color {
        switch cli.lowercased() {
        case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex":  return Color(red: 0.06, green: 0.64, blue: 0.50)
        case "kiro":   return Color(red: 0.58, green: 0.42, blue: 0.94)
        case "cursor": return .primary
        case "agy":    return Color(red: 0.25, green: 0.63, blue: 0.96)
        case "gemini": return Color(red: 0.26, green: 0.52, blue: 0.96)
        default:       return fallback
        }
    }

    /// Small badge text needs stronger contrast than a decorative logo.
    /// These are darker/lighter steps of the same provider hue, selected for
    /// the active appearance rather than replacing brand identity with gray.
    static func readableAccent(
        for cli: String,
        colorScheme: ColorScheme,
        fallback: Color
    ) -> Color {
        let isDark = colorScheme == .dark
        switch cli.lowercased() {
        case "claude":
            return isDark
                ? Color(red: 0.93, green: 0.61, blue: 0.48)
                : Color(red: 0.63, green: 0.23, blue: 0.14)
        case "codex":
            return isDark
                ? Color(red: 0.31, green: 0.86, blue: 0.70)
                : Color(red: 0.02, green: 0.40, blue: 0.31)
        case "kiro":
            return isDark
                ? Color(red: 0.75, green: 0.64, blue: 0.97)
                : Color(red: 0.36, green: 0.21, blue: 0.68)
        case "cursor":
            return .primary
        case "agy":
            return isDark
                ? Color(red: 0.48, green: 0.74, blue: 1.00)
                : Color(red: 0.08, green: 0.35, blue: 0.67)
        case "gemini":
            return isDark
                ? Color(red: 0.56, green: 0.70, blue: 1.00)
                : Color(red: 0.10, green: 0.29, blue: 0.67)
        default:
            return fallback
        }
    }

    /// Letter-coded palettes keep the pixel marks deterministic and make the
    /// Antigravity A match its orange → green/blue → violet reference without
    /// baking a raster asset into the app.
    private static let rainbow: [Character: Color] = [
        "O": Color(red: 1.00, green: 0.54, blue: 0.22),
        "R": Color(red: 1.00, green: 0.36, blue: 0.36),
        "Y": Color(red: 1.00, green: 0.80, blue: 0.25),
        "G": Color(red: 0.29, green: 0.77, blue: 0.42),
        "C": Color(red: 0.30, green: 0.79, blue: 0.94),
        "M": Color(red: 0.84, green: 0.35, blue: 0.73),
        "P": Color(red: 0.66, green: 0.37, blue: 1.00),
        "B": Color(red: 0.23, green: 0.51, blue: 0.96),
    ]

    private static let agyTones = [
        "   OOR   ",
        "  YYOMP  ",
        " CCG PBB ",
    ]

    private static let geminiTones = [
        "  BBGRR  ",
        " RRYGGGB ",
        "  YYBBB  ",
    ]

    static func mascotColor(
        for cli: String,
        row: Int,
        column: Int,
        fallback: Color
    ) -> Color {
        let tones: [String]?
        switch cli.lowercased() {
        case "agy": tones = agyTones
        case "gemini": tones = geminiTones
        default: tones = nil
        }
        if let tones, tones.indices.contains(row) {
            let characters = Array(tones[row])
            if characters.indices.contains(column),
               let colour = rainbow[characters[column]] {
                return colour
            }
        }
        return markAccent(for: cli, fallback: fallback)
    }
}

private struct Mascot: View {
    let cli: String
    let rows: [String]
    let fallbackAccent: Color

    @ViewBuilder
    var body: some View {
        if cli.lowercased() == "codex" {
            Image("CodexLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    colored(row, at: rowIndex)
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(0)
                        .fixedSize()
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func colored(_ row: String, at rowIndex: Int) -> Text {
        Array(row).enumerated().reduce(Text("")) { result, item in
            result + Text(String(item.element)).foregroundColor(
                ProviderIdentity.mascotColor(
                    for: cli,
                    row: rowIndex,
                    column: item.offset,
                    fallback: fallbackAccent
                )
            )
        }
    }
}

/// Which CLI is behind a pane, said rather than symbolised.
private struct CliBadge: View {
    let cli: String
    let accent: Color

    var body: some View {
        Text(cli.uppercased())
            .font(.system(size: 9, weight: .bold).monospaced())
            .tracking(0.8)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(accent.opacity(0.20), in: Capsule())
            .foregroundStyle(accent)
    }
}

/// An answer, with a caret while it is still being written.
private struct Answer: View {
    let text: String
    let streaming: Bool

    var body: some View {
        MarkdownText(text: text, streaming: streaming)
            .overlay(alignment: .bottomTrailing) {
                if streaming { Caret().alignmentGuide(.bottom) { $0[.bottom] } }
            }
    }
}

/// Markdown, kept quiet.
///
/// Agents write markdown whether or not anything renders it, so the pane was
/// showing `**bold**` and `## Heading` as literal characters. A full renderer
/// is the wrong answer for a dense product surface: headings blown up to
/// display sizes turn a five-line answer into a poster. So a heading carries
/// weight, not size. Code is the exception, because a fenced block is the one
/// thing in an answer you read character by character.
struct MarkdownText: View {
    let text: String
    var streaming: Bool = false
    @State private var presentation: AgentMarkdownPresentation?

    var body: some View {
        Group {
            if streaming {
                Text(text).font(.system(size: 12))
            } else if let presentation, presentation.source == text {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(presentation.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let body):
                            Text(body).font(.system(size: 12))
                        case .heading(let level, let title):
                            Text(title)
                                .font(.system(size: level == 1 ? 13 : (level == 2 ? 12.5 : 12),
                                              weight: level <= 2 ? .bold : .semibold))
                                .padding(.top, 2)
                        case .bullet(let marker, let body):
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(marker)
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(body).font(.system(size: 12))
                            }
                        case .quote(let body):
                            HStack(alignment: .top, spacing: 8) {
                                Rectangle().fill(.quaternary).frame(width: 2)
                                Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        case .code(let language, let body):
                            PreparedCodeBlock(language: language, code: body)
                        case .table(let headers, let rows):
                            PreparedMarkdownTable(headers: headers, rows: rows)
                        case .rule:
                            Rectangle().fill(.quaternary).frame(height: 1).padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Text(text).font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(streaming):\(text)") {
            guard !streaming else { presentation = nil; return }
            let source = text
            let prepared = await Task.detached(priority: .userInitiated) {
                AgentMarkdownPresentation.prepare(source)
            }.value
            guard !Task.isCancelled, source == text else { return }
            presentation = prepared
        }
    }
}

/// Immutable rendering input prepared outside SwiftUI body evaluation.
struct AgentMarkdownPresentation: @unchecked Sendable {
    enum Block: @unchecked Sendable {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case bullet(marker: String, text: AttributedString)
        case quote(AttributedString)
        case code(language: String?, text: AttributedString)
        case table(headers: [AttributedString], rows: [[AttributedString]])
        case rule
    }

    let source: String
    let blocks: [Block]

    static func prepare(_ source: String) -> AgentMarkdownPresentation {
        let blocks = AgentMarkdown.blocks(source).map { block -> Block in
            switch block {
            case .paragraph(let text): return .paragraph(AgentMarkdown.inline(text))
            case .heading(let level, let text):
                return .heading(level: level, text: AgentMarkdown.inline(text))
            case .bullet(let marker, let text):
                return .bullet(marker: marker, text: AgentMarkdown.inline(text))
            case .quote(let text): return .quote(AgentMarkdown.inline(text))
            case .code(let language, let text):
                return .code(language: language, text: AgentMarkdown.highlighted(text, language: language))
            case .table(let headers, let rows):
                return .table(headers: headers.map(AgentMarkdown.inline),
                              rows: rows.map { $0.map(AgentMarkdown.inline) })
            case .rule: return .rule
            }
        }
        return AgentMarkdownPresentation(source: source, blocks: blocks)
    }
}

private struct PreparedMarkdownTable: View {
    let headers: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header).font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellColumns(headers.count)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(headers.indices), id: \.self) { index in
                            Text(index < row.count ? row[index] : AttributedString())
                                .font(.system(size: 12))
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct PreparedCodeBlock: View {
    let language: String?
    let code: AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language).font(.system(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 5)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Nine squares, pulsing along the diagonal: this pane is working.
///
/// Placed over the transcript rather than in the header because the question
/// it answers is asked across a whole window — which of six agents is busy —
/// and that is answered by glancing at a shape in a fixed place, not by
/// reading a word at the end of a row. Faint on purpose: it sits on top of
/// text, and anything strong enough to notice while reading is too strong.
private struct WorkingMark: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let side: CGFloat = 6
    private static let gap: CGFloat = 2
    /// 0.6s of pulse and a 0.2s rest, so the wave reads as a wave and not as a
    /// stutter that never stops.
    private static let cycle: Double = 0.8
    private static let pulse: Double = 0.6

    var body: some View {
        // Driven from the clock rather than from a state flip.
        //
        // The first version animated `scaleEffect` off an `onAppear` toggle with
        // `.repeatForever`, and measured, it never moved at all: two frames a
        // quarter-second apart were identical to the pixel while an agent was
        // working. Inside a conditionally-inserted overlay, on a pane that
        // re-renders on every delta, a repeating animation hung on a one-shot
        // state change is not something to rely on. Time is always there.
        AnimatedWorkingMark(
            accent: accent,
            side: Self.side,
            gap: Self.gap,
            cycle: Self.cycle,
            reduceMotion: reduceMotion
        )
        .frame(
            width: Self.side * 3 + Self.gap * 2,
            height: Self.side * 3 + Self.gap * 2
        )
        // Faint made sense when this sat over the transcript; in the composer
        // row it sits over nothing, so the reason is gone. Still a step under
        // the stop button beside it — that one is the thing to press, this one
        // is only the thing to notice.
        .opacity(0.85)
        // A grid of squares keeping time is not something to announce; the
        // header already says "working" in words.
        .accessibilityHidden(true)
    }

    /// Each square shrinks and returns, offset down the diagonal.
    ///
    /// The diagonal is what makes nine squares read as one object rather than
    /// nine: `(row + column)` gives the anti-diagonal, so the wave crosses the
    /// grid corner to corner.
    private static func scale(at time: Double, row: Int, column: Int) -> CGFloat {
        let phase = (time - Double(row + column) * 0.1)
            .truncatingRemainder(dividingBy: cycle)
        let p = phase < 0 ? phase + cycle : phase
        guard p < pulse else { return 1 }
        let half = pulse / 2
        let t = p < half ? p / half : (pulse - p) / half
        // Smoothstep, so it eases at both ends without a bounce.
        let eased = t * t * (3 - 2 * t)
        return CGFloat(1 - 0.8 * eased)
    }
}

private struct AnimatedHeaderBand: NSViewRepresentable {
    let accent: Color
    let duration: Double

    func makeNSView(context: Context) -> HeaderBandView {
        HeaderBandView()
    }

    func updateNSView(_ view: HeaderBandView, context: Context) {
        view.update(accent: NSColor(accent), duration: duration)
    }
}

private final class HeaderBandView: NSView {
    private let band = CAGradientLayer()
    private var duration: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(band)
    }

    required init?(coder: NSCoder) { nil }

    func update(accent: NSColor, duration: Double) {
        band.colors = [
            accent.withAlphaComponent(0).cgColor,
            accent.withAlphaComponent(0.05).cgColor,
            accent.withAlphaComponent(0.18).cgColor,
            accent.withAlphaComponent(0.05).cgColor,
            accent.withAlphaComponent(0).cgColor,
        ]
        guard self.duration != duration || band.animation(forKey: "travel") == nil else { return }
        self.duration = duration
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(90, bounds.width * 0.48)
        band.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        band.removeAnimation(forKey: "travel")
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -width / 2
        animation.toValue = bounds.width + width / 2
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        band.add(animation, forKey: "travel")
    }
}

private struct AnimatedWorkingMark: NSViewRepresentable {
    let accent: Color
    let side: CGFloat
    let gap: CGFloat
    let cycle: Double
    let reduceMotion: Bool

    func makeNSView(context: Context) -> WorkingMarkView {
        WorkingMarkView()
    }

    func updateNSView(_ view: WorkingMarkView, context: Context) {
        view.update(
            accent: NSColor(accent),
            side: side,
            gap: gap,
            cycle: cycle,
            reduceMotion: reduceMotion
        )
    }
}

private final class WorkingMarkView: NSView {
    private let squares = (0..<9).map { _ in CALayer() }
    private var configuration = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        squares.forEach {
            $0.cornerRadius = 1
            layer?.addSublayer($0)
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(
        accent: NSColor,
        side: CGFloat,
        gap: CGFloat,
        cycle: Double,
        reduceMotion: Bool
    ) {
        let next = "\(accent.description)-\(side)-\(gap)-\(cycle)-\(reduceMotion)"
        guard next != configuration else { return }
        configuration = next
        for (index, square) in squares.enumerated() {
            let row = index / 3
            let column = index % 3
            square.frame = CGRect(
                x: CGFloat(column) * (side + gap),
                y: CGFloat(2 - row) * (side + gap),
                width: side,
                height: side
            )
            square.backgroundColor = accent.cgColor
            square.removeAllAnimations()
            guard !reduceMotion else { continue }
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = 1
            animation.toValue = 0.45
            animation.autoreverses = true
            animation.duration = cycle * 0.375
            animation.beginTime = CACurrentMediaTime()
                + Double(row + column) * cycle / 12
            animation.repeatCount = .infinity
            square.add(animation, forKey: "pulse")
        }
    }
}

/// The blink that says a row is still open.
private struct Caret: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.tint)
            .frame(width: 6, height: 12)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
            // A blinking rectangle is exactly what a screen reader should not
            // be asked to announce.
            .accessibilityHidden(true)
    }
}

/// A tool call, which a terminal could only ever show as two unrelated lines.
private struct ToolRow: View {
    let call: AgentSession.ToolCall
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                mark
                Text(call.name).font(.system(size: 11, weight: .medium))
                Text(AgentSession.projectedToolHeadline(call.headline))
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if call.canExpand {
                    Button(open ? "hide" : "show") { open.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                }
            }
            if open, let result = call.result {
                // Folded by default. A tool result can be thousands of lines,
                // and in a terminal all of them are in the way of the answer.
                ScrollView(.horizontal) {
                    Text(result)
                        .font(.system(size: 10).monospaced())
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        if call.isRunning {
            ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 12)
        } else {
            Image(systemName: call.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(call.failed ? Color.red : Color.green)
        }
    }
}

/// An edit, drawn as what changed rather than as which file.
///
/// A tool row could say a file was touched, and that is where this pane stopped
/// — the name of a file and nothing about what happened inside it. The line
/// that is always on screen answers the question you actually have while six
/// panes are working: which file, how much. The fold answers the one you have
/// when that answer is surprising.
private struct ChangeRow: View {
    let call: AgentSession.ToolCall
    let change: AgentDiff.Change
    let root: String
    @Binding var open: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                mark
                Text(call.name).font(.system(size: 11, weight: .medium))
                // Truncated from the head, not the middle: a path that has to
                // give ground should give up its directories and keep the
                // filename, which is the part being talked about.
                Text(AgentDiff.short(change.path, relativeTo: root))
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if let note {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                counts
                Button(open ? "hide" : "show") { open.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
                    .fixedSize()
            }
            if open {
                DiffBody(change: change)
                HStack(spacing: 10) {
                    Button("copy diff") { copy() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                    if let result = call.result, !result.isEmpty, call.failed {
                        // A successful edit's result is one sentence saying it
                        // worked, and the diff above says it better. A failed
                        // one is the only thing worth reading.
                        Text(result)
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    /// `+12 −3`, kept whole while the path beside it truncates: the numbers are
    /// the reason the row is legible at a glance, and they are three characters.
    private var counts: some View {
        HStack(spacing: 5) {
            if change.added > 0 {
                Text("+\(change.added)")
                    .foregroundStyle(DiffPalette.added(colorScheme).text)
            }
            if change.removed > 0 {
                Text("−\(change.removed)")
                    .foregroundStyle(DiffPalette.removed(colorScheme).text)
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .fixedSize()
        .layoutPriority(2)
    }

    /// What makes the counts honest when they are not the whole story.
    private var note: String? {
        // Applied everywhere, so the counts are per site and the total is a
        // number we were never told. Saying "all" is the honest version of a
        // multiplication we cannot do.
        if change.everywhere { return "all" }
        switch change.kind {
        case .write(let created?): return created ? "new file" : "overwrite"
        case .write(nil): return nil
        case .delete: return "deleted"
        case .multiEdit(let sites): return sites > 1 ? "\(sites) sites" : nil
        case .notebook(let cell): return cell == nil ? nil : "cell"
        case .edit: return nil
        }
    }

    private func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(AgentDiff.text(change), forType: .string)
    }

    @ViewBuilder
    private var mark: some View {
        if call.isRunning {
            ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 12)
        } else {
            Image(systemName: call.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(call.failed ? Color.red : Color.green)
        }
    }
}

/// The diff itself.
///
/// One horizontal scroller around the whole column, so a long line never drags
/// its own row out of alignment with the gutter beside it. Deliberately no
/// vertical scroller and no `maxHeight`: a same-axis scroll view nested inside
/// the transcript's `LazyVStack` is the geometry that made this view's
/// placement pass re-enter itself. Length is controlled by showing fewer lines,
/// not by putting a window over them.
private struct DiffBody: View {
    let change: AgentDiff.Change
    @State private var all = false

    /// Enough to see what an edit did without the row becoming the transcript.
    private static let preview = 120

    var body: some View {
        let shown = all ? change.lines : Array(change.lines.prefix(Self.preview))
        let hidden = change.lines.count - shown.count + change.elided
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line, gutter: gutter)
                    }
                }
            }
            if hidden > 0 {
                HStack(spacing: 6) {
                    Text("\(hidden) more lines")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    // `elided` was dropped when the diff was read and is not
                    // here to be shown; offering to reveal it would be a button
                    // that cannot keep its promise.
                    if !all, change.lines.count > shown.count {
                        Button("show all") { all = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 9))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 6)
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Width of the line-number column, or zero when there are no numbers.
    ///
    /// An `Edit` hands over a fragment of a file and never says where in the
    /// file it sits, so most diffs here have no numbers at all and the column
    /// should not be reserved. Walked here rather than in `ChangeRow` because
    /// this view only exists while the row is open — a folded row pays nothing.
    private var gutter: CGFloat {
        var widest = 0
        for line in change.lines {
            switch line {
            case .context(let old, let new, _): widest = max(widest, old ?? 0, new ?? 0)
            case .added(let new, _): widest = max(widest, new ?? 0)
            case .removed(let old, _): widest = max(widest, old ?? 0)
            case .gap, .site: break
            }
        }
        guard widest > 0 else { return 0 }
        return CGFloat(String(widest).count) * 6.5 + 6
    }
}

private struct DiffLineRow: View {
    let line: AgentDiff.Line
    let gutter: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch line {
        case .context(let old, _, let text):
            row(" ", number: old, text: text, tone: nil)
        case .added(let new, let text):
            row("+", number: new, text: text, tone: DiffPalette.added(colorScheme))
        case .removed(let old, let text):
            row("−", number: old, text: text, tone: DiffPalette.removed(colorScheme))
        case .gap(let count):
            marker(count > 0 ? "⋯ \(count) unchanged" : "⋯")
        case .site(let index):
            marker("edit \(index + 1)")
        }
    }

    private func row(_ sign: String, number: Int?, text: String,
                     tone: (text: Color, wash: Color)?) -> some View {
        HStack(spacing: 0) {
            if gutter > 0 {
                Text(number.map(String.init) ?? "")
                    .frame(width: gutter, alignment: .trailing)
                    .foregroundStyle(.tertiary)
            }
            // The sign column carries the meaning on its own, so the colour is
            // reinforcement rather than the only signal — which is what makes
            // this readable without colour vision.
            Text(sign)
                .frame(width: 12, alignment: .center)
                .foregroundStyle(tone?.text ?? Color.secondary)
            // Tabs jump by a variable width in a monospaced Text and pull the
            // gutter out of line. Expanded to four, the same way the copy
            // button writes them out.
            Text(text.replacingOccurrences(of: "\t", with: "    "))
                .foregroundStyle(tone?.text ?? Color.primary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10).monospaced())
        .textSelection(.enabled)
        .padding(.vertical, 0.5)
        // Inside a horizontal scroller the tint ends where the line does, since
        // nothing here proposes a width to stretch to. Left as is: the sign
        // column already says which side a line is on, so the colour is
        // reinforcement, and matching every row's width would mean measuring
        // the longest one and feeding it back through a preference — a layout
        // round trip in the one view that must not have any.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone?.wash ?? .clear)
    }

    private func marker(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9).monospaced())
            .foregroundStyle(.tertiary)
            .padding(.leading, gutter + 12)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
    }
}

/// Green and red that survive both appearances.
///
/// The system colours are too light against a light background to read as text
/// and too saturated behind it to sit under one; and a 0.10 wash over a dark
/// pane is not a colour, it is a rumour. So each side has a text tone and a
/// wash chosen per appearance, the way `ProviderIdentity.readableAccent` does.
private enum DiffPalette {
    static func added(_ scheme: ColorScheme) -> (text: Color, wash: Color) {
        scheme == .dark
            ? (Color(red: 0.55, green: 0.87, blue: 0.62),
               Color(red: 0.28, green: 0.78, blue: 0.44).opacity(0.16))
            : (Color(red: 0.08, green: 0.42, blue: 0.19),
               Color(red: 0.20, green: 0.68, blue: 0.35).opacity(0.10))
    }

    static func removed(_ scheme: ColorScheme) -> (text: Color, wash: Color) {
        scheme == .dark
            ? (Color(red: 0.95, green: 0.55, blue: 0.55),
               Color(red: 0.88, green: 0.30, blue: 0.32).opacity(0.16))
            : (Color(red: 0.60, green: 0.11, blue: 0.13),
               Color(red: 0.85, green: 0.25, blue: 0.28).opacity(0.10))
    }
}
