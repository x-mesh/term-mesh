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
        HStack(spacing: 8) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(panel.agentName).font(.system(size: 12, weight: .semibold))
            if let summary = session.summary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if session.isThinking {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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
        case .answered(_, let text):
            // Selectable, because the reason to read an agent's answer is
            // usually to take something out of it.
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .thought(_, let body):
            label("✻", body ?? "thinking", muted: true)
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

    private func label(_ glyph: String, _ text: String, muted: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(glyph).font(.system(size: 11))
            Text(text).font(.system(size: 11)).lineLimit(muted ? 2 : nil)
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
