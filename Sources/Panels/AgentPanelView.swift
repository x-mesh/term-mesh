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
            Text(panel.agentName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
            CliBadge(cli: panel.cli, accent: accent)
            if let summary = session.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
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
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(accent.opacity(isFocused ? 0.12 : 0.05))
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
            Mascot(rows: Self.mascot(for: panel.cli), accent: accent)
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
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.35)))
    }

    /// A mascot per CLI, in block characters, all nine columns wide so they
    /// read as one family rather than six unrelated doodles.
    ///
    /// Claude's is its own welcome banner. The rest are silhouettes taken from
    /// what the thing is called — codex a knot of code, kiro a cut gem, cursor
    /// a pointer, agy (Antigravity) something lifting off, gemini a pair of
    /// sparks. Deliberately not imitations of anyone's logo: the pane says the
    /// CLI's name beside the mascot, so the drawing never has to be decoded to
    /// answer "which one is this".
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
            return ["   ▗▖    ",
                    "  ▟██▙   ",
                    " ▘▘  ▝▝  "]
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
                LazyVStack(alignment: .leading, spacing: 10) {
                    banner
                    ForEach(session.entries) { entry in
                        row(entry).id(entry.id)
                    }
                    // Anchors the auto-scroll, so a stream of tool calls does
                    // not have to be chased down the pane by hand.
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
        }
    }

    private static let bottom = "bottom"

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
        VStack(alignment: .leading, spacing: 3) {
            Text(speaker == .person ? "you" : "leader")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tint)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
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
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            // Stated by the agent, not inferred from the screen going quiet —
            // which is the whole reason the pane path needed a timer here.
            Text(facts(end))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(end.failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                // One line between two rules. Left to wrap, it breaks the rule
                // in half and reads as two unrelated things.
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
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
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(isFocused ? 0.04 : 0.02))
    }

    private var canSend: Bool {
        session.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

/// Block characters drawn tight enough to be a shape.
///
/// A `Text` holding all three rows would space them by the font's line height
/// and the blocks would not meet — the drawing only reads as one if the rows
/// touch, so each is its own row with the leading pulled out.
private struct Mascot: View {
    let rows: [String]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(row)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(0)
                    .fixedSize()
            }
        }
        .foregroundStyle(accent)
        .accessibilityHidden(true)
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
        Text(text)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomTrailing) {
                if streaming { Caret().alignmentGuide(.bottom) { $0[.bottom] } }
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
