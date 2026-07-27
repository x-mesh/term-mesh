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
        .onTapGesture { onFocus() }
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
        ScrollViewReader { proxy in
            ScrollView {
                // Spacing is uniform no longer: a turn runs instruction →
                // thinking → tools → answer → footer, and at one gap for
                // everything those five read as five unrelated rows. Tight
                // inside a turn, open between them.
                LazyVStack(alignment: .leading, spacing: 0) {
                    banner
                    if session.entries.isEmpty { emptyState }
                    ForEach(Array(session.entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry)
                            .padding(.top, Self.gap(before: entry,
                                                    after: index > 0 ? session.entries[index - 1] : nil))
                            .id(entry.id)
                    }
                    // Anchors the auto-scroll, and doubles as the test for
                    // whether the bottom is on screen at all.
                    Color.clear.frame(height: 1)
                        .id(Self.bottom)
                        .onAppear { following = true }
                        .onDisappear {
                            // Content growing pushes this off screen too, and
                            // that is not the user walking away — only a
                            // disappearance with no recent append is.
                            if Date().timeIntervalSince(grewAt) > 0.4 { following = false }
                        }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Every mutation, not every append: a streamed answer grows a row
            // that already exists, and keying on the count meant the text ran
            // off the bottom while the view sat still.
            .onChange(of: session.revision) { _, _ in
                grewAt = Date()
                guard following else { return }
                // Unanimated on purpose. A 250-delta answer animating each step
                // is not a smooth scroll, it is a stutter.
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

    private static let bottom = "bottom"

    /// How much air a row needs above it, given what came before.
    ///
    /// The footer belongs to the answer it closes, so it sits close. A new
    /// instruction, or anything after a footer, starts a turn and gets room.
    static func gap(before entry: AgentSession.Entry,
                    after previous: AgentSession.Entry?) -> CGFloat {
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

    @ViewBuilder
    private func row(_ entry: AgentSession.Entry) -> some View {
        switch entry {
        case .said(_, let speaker, let text):
            said(speaker, text)
        case .answered(let id, let text):
            // Selectable, because the reason to read an agent's answer is
            // usually to take something out of it. The caret says the row is
            // still being written — a terminal can only show characters
            // arriving and leave "did it stop there?" to be guessed.
            Answer(text: text, streaming: session.streamingIds.contains(id))
        case .thought(let id, let body):
            label("✻", (body?.isEmpty == false ? body! : "thinking"),
                  muted: true, streaming: session.streamingIds.contains(id))
        case .tool(_, let call):
            ToolRow(call: call)
        case .turnEnded(_, let end):
            turnEnd(end)
        case .notice(_, let text):
            label("!", text, muted: false)
        }
    }

    private func said(_ speaker: AgentSession.Speaker, _ text: String) -> some View {
        Instruction(speaker: speaker, read: AgentSession.read(instruction: text))
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

    private func turnEnd(_ end: AgentSession.TurnEnd) -> some View {
        TurnFooter(end: end, facts: facts(end))
    }

    private func facts(_ end: AgentSession.TurnEnd) -> String {
        var parts = [end.stop]
        if let d = end.duration { parts.append(String(format: "%.1fs", d)) }
        if let c = end.cost { parts.append(String(format: "$%.4f", c)) }
        if end.tokensIn != nil || end.tokensOut != nil {
            parts.append("\(end.tokensIn ?? 0)→\(end.tokensOut ?? 0) tok")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Composer

    /// The person's way in.
    ///
    /// On the terminal path this came free — the pane *was* the agent's stdin.
    /// On the pipe it had to be won back by reading `/dev/tty` from inside the
    /// pipeline. Here it is just a text field, and it can do what neither could:
    /// hold a multi-line draft without submitting on the first newline.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(panel.agentName)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
            // Which of six panes is working is a question you answer by
            // glancing, not by reading. So the state has a shape — and it
            // lives here rather than over the transcript, where it landed on
            // the banner card and read as the banner's decoration. This row
            // never scrolls, is the same place in every pane, and puts "it is
            // working" next to "stop it".
            if session.isThinking {
                WorkingMark(accent: accent)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // One button, two jobs. A stop that only exists while a turn runs
            // has to live where your hand already is: a 9pt icon appearing at
            // the far end of the header for the three seconds a haiku turn
            // lasts is not a control anyone can find. Send and stop are also
            // never both available, so they are never two buttons.
            Button(action: canStop ? session.interrupt : send) {
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
        .animation(.easeOut(duration: 0.2), value: session.isThinking)
    }

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

/// What was asked, with the protocol it travelled in folded away.
///
/// Measured on a real transcript: sixteen lines, nine of them scaffold, the
/// intent one line inside `[GOAL]`. The bubble was showing the envelope and
/// burying the letter. The envelope is still there for anyone who needs it.
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

    var body: some View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AgentMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let body):
                    inline(body)
                case .heading(let level, let title):
                    // Weight, not size: 13/12.5/12 against a 12pt body. A
                    // heading should be findable when you scan, not loud when
                    // you read.
                    inline(title)
                        .font(.system(size: level == 1 ? 13 : (level == 2 ? 12.5 : 12),
                                      weight: level <= 2 ? .bold : .semibold))
                        .padding(.top, 2)
                case .bullet(let marker, let body):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        inline(body)
                    }
                case .quote(let body):
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                        inline(body).foregroundStyle(.secondary)
                    }
                case .code(let language, let body):
                    CodeBlock(language: language, code: body)
                case .table(let headers, let rows):
                    MarkdownTable(headers: headers, rows: rows, streaming: streaming)
                case .rule:
                    Rectangle().fill(.quaternary).frame(height: 1).padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline emphasis resolves once the row stops streaming. Half-written
    /// emphasis is unparseable by definition, and parsing it on each of a few
    /// hundred deltas costs more than it returns.
    private func inline(_ body: String) -> Text {
        streaming ? Text(body).font(.system(size: 12))
                  : Text(AgentMarkdown.inline(body)).font(.system(size: 12))
    }
}

/// A small report table, not a spreadsheet: the header has just enough weight
/// to orient a scan, and wide tables scroll instead of squeezing words into a
/// pile of ellipses.
private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]
    let streaming: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        cell(header)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellColumns(headers.count)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(headers.indices), id: \.self) { index in
                            cell(index < row.count ? row[index] : "")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cell(_ text: String) -> Text {
        streaming ? Text(text).font(.system(size: 12))
                  : Text(AgentMarkdown.inline(text)).font(.system(size: 12))
    }
}

/// A fenced block: monospaced, scrollable, and coloured enough to scan.
private struct CodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
            }
            // Horizontal scrolling rather than wrapping: a wrapped command line
            // is a line you cannot copy correctly by eye.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(AgentMarkdown.highlighted(code, language: language))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
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
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                mark
                Text(call.name).font(.system(size: 11, weight: .medium))
                Text(call.headline)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if call.result?.isEmpty == false {
                    Button(expanded ? "hide" : "show") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                }
            }
            if expanded, let result = call.result {
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
