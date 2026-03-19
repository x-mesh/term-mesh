import SwiftUI

/// A bottom-docked input bar for CJK IME composition.
///
/// Raw-mode TUI apps (ink/Claude Code) break IME preedit rendering because
/// they move the terminal cursor to unpredictable positions during re-renders.
/// This bar provides a native NSTextField where IME composition works perfectly,
/// then sends the completed text to the terminal on Enter.
///
/// - Enter: send text + execute
/// - Shift+Enter: new line
/// - Up/Down: history navigation (max 30 entries)
/// - Esc: close
///
/// Activated via Cmd+Shift+I (or menu: Edit → IME Input Bar).
/// Docked at the bottom of the terminal pane; the terminal shrinks to make room.
struct IMEInputBar: View {
    let onSubmit: (String) -> Bool
    let onBroadcast: ((String) -> Void)?
    let onClose: () -> Void
    var onCtrlC: (() -> Void)? = nil
    /// Send a raw key event (keycode + modifier flags) to the terminal surface.
    var onSendKey: ((_ keycode: UInt16, _ mods: UInt32) -> Void)? = nil

    @State private var text: String = ""
    @State private var history: [String] = []   // Q4: loaded async in .task
    @State private var historyIndex: Int = -1   // -1 = editing draft
    @State private var historyDraft: String = ""
    @State private var isComposing: Bool = false
    @State private var showKeyboardHelp: Bool = false
    @State private var feedbackState: FeedbackState = .none  // Q1
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFieldFocused: Bool

    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Q1: Feedback state

    private enum FeedbackState { case none, success, failure }

    private var feedbackColor: Color {
        switch feedbackState {
        case .none:    return .clear
        case .success: return .green
        case .failure: return .red
        }
    }

    // MARK: - Actions

    private func doSubmit() {
        if text.isEmpty {
            // Pass through Enter to the terminal so the user isn't "trapped"
            _ = onSubmit("")
            return
        }
        let submitted = text
        let success = onSubmit(submitted)
        if success {
            addToHistory(submitted)  // Bug fix: record only on success
            text = ""
            feedbackState = .success  // Q1
        } else {
            feedbackState = .failure  // Q1
        }
        // On failure, keep text in the box so the user can retry or edit.
        // The caller (sendIMEText / surface retry) will beep to signal the error.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            feedbackState = .none
        }
    }

    private func doSubmitAndClose() {
        if !text.isEmpty {
            let submitted = text
            let success = onSubmit(submitted)
            if success {
                addToHistory(submitted)  // Bug fix: record only on success
                text = ""
            }
        }
        onClose()
    }

    private func doBroadcast() {
        guard !text.isEmpty, let onBroadcast else { return }
        let submitted = text
        addToHistory(submitted)
        onBroadcast(submitted)
        text = ""
    }

    private func addToHistory(_ entry: String) {
        // Cap entry size to prevent bloating UserDefaults
        let capped = entry.count > 1000 ? String(entry.prefix(1000)) : entry
        history.removeAll { $0 == capped }
        history.insert(capped, at: 0)
        if history.count > IMEHistory.maxEntries {
            history.removeLast(history.count - IMEHistory.maxEntries)
        }
        IMEHistory.save(history)
        historyIndex = -1
        historyDraft = ""
    }

    private func historyUp() {
        guard !history.isEmpty else { return }
        if historyIndex == -1 {
            historyDraft = text
        }
        let next = historyIndex + 1
        if next < history.count {
            historyIndex = next
            text = history[next]
        }
    }

    private func historyDown() {
        if historyIndex < 0 { return }
        let next = historyIndex - 1
        if next < 0 {
            historyIndex = -1
            text = historyDraft
        } else {
            historyIndex = next
            text = history[next]
        }
    }

    /// Reverse-search history (Ctrl+R): find next entry containing current text.
    private func historySearch() {
        let query = text.lowercased()
        let startIndex = historyIndex + 1
        guard startIndex < history.count else { return }
        for i in startIndex..<history.count {
            if query.isEmpty || history[i].lowercased().contains(query) {
                if historyIndex == -1 { historyDraft = text }
                historyIndex = i
                text = history[i]
                return
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "keyboard")
                    .foregroundColor(.primary.opacity(0.6))
                    .font(.system(size: 11))
                    .padding(.top, 5)

                IMETextEditor(
                    text: $text,
                    onSubmit: doSubmit,
                    onCancel: onClose,
                    onCtrlC: onCtrlC,
                    onSendKey: onSendKey,
                    onSubmitAndClose: doSubmitAndClose,
                    onHistoryUp: historyUp,
                    onHistoryDown: historyDown,
                    onHistorySearch: historySearch,
                    onComposingChanged: { isComposing = $0 }
                )
                .focused($isFieldFocused)

                actionButtons
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Hint bar + status indicators (same row)
            HStack(spacing: 12) {
                hintBar

                Spacer()

                // Status indicators (right-aligned)
                HStack(spacing: 8) {
                    // Q3: multiline line count
                    let lineCount = text.components(separatedBy: "\n").count
                    if lineCount >= 2 {
                        Text("\(lineCount) lines")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    if isComposing {
                        Text("IME composing")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.8))
                    }
                    if historyIndex >= 0 {
                        Text("history [\(historyIndex + 1)/\(history.count)]")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDark ? Color.black.opacity(0.75) : Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
        // Q1: send feedback border overlay
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(feedbackColor, lineWidth: feedbackState == .none ? 0 : 2)
                .animation(.easeInOut(duration: 0.15), value: feedbackState)
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFieldFocused = true
            }
        }
        // Q4: async history loading
        .task {
            let loaded = await Task.detached { IMEHistory.loadMerged() }.value
            history = loaded
        }
    }

    // MARK: - Subviews

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if !text.isEmpty {
                Button(action: doSubmit) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.green)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Send to current pane (Enter)")

                if onBroadcast != nil {
                    Button(action: doBroadcast) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.orange)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help("Broadcast to all panes")
                }

                // Q5: clear button — only visible when there is text
                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear input")
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.primary.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.15))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .help("Close (⌘Esc)")
        }
        .padding(.top, 3)
    }

    private var hintBar: some View {
        HStack(spacing: 10) {
            hintLabel("⏎ send")
            hintLabel("⌘⏎ send+close")
            hintLabel("⇧⏎ newline")
            hintLabel("Tab →term")
            hintLabel("⇧Tab accept")
            hintLabel("Esc →term")
            hintLabel("⌃C interrupt")

            Button(action: { showKeyboardHelp.toggle() }) {
                Text("?")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(7)
            }
            .buttonStyle(.plain)
            .help("Show all keyboard shortcuts")
            .popover(isPresented: $showKeyboardHelp, arrowEdge: .top) {
                keyboardHelpView
            }
        }
    }

    private var keyboardHelpView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 11, weight: .semibold))
                .padding(.bottom, 6)

            Group {
                helpSection("Input") {
                    helpRow("⏎", "Send")
                    helpRow("⌘⏎", "Send & close")
                    helpRow("⇧⏎", "New line")
                    helpRow("⌃C", "Interrupt (Ctrl+C)")
                }
                helpSection("Navigation") {
                    helpRow("↑ ↓", "History (\(history.count))")
                    helpRow("⌃R", "Search history")
                    helpRow("⌃A / ⌃E", "Line start / end")
                }
                helpSection("Terminal") {
                    helpRow("Esc", "Send Escape to terminal")
                    helpRow("Tab", "Tab to terminal")
                    helpRow("⇧Tab", "Send Shift+Tab (accept)")
                    helpRow("⌥↑↓←→", "Arrow to terminal")
                    helpRow("⌥Tab", "Tab to terminal")
                    helpRow("Del", "Forward delete (empty)")
                }
                helpSection("Claude Code") {
                    helpRow("⌃J", "Submit (alt Enter)")
                    helpRow("⌃L", "Clear conversation")
                    helpRow("⌃C", "Interrupt")
                    helpRow("Esc Esc", "Double-ESC → Ctrl+C")
                    helpRow("⇧Tab", "Accept suggestion")
                    helpRow("⌥Tab", "Toggle thinking")
                }
                helpSection("IME Box") {
                    helpRow("⌘Esc", "Close")
                    helpRow("⌘⇧I", "Toggle")
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(12)
        .frame(width: 240)
    }

    private func helpSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 2)
            content()
        }
    }

    private func helpRow(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 0) {
            Text(key)
                .foregroundColor(.primary.opacity(0.7))
                .frame(width: 80, alignment: .leading)
            Text(desc)
                .foregroundColor(.primary.opacity(0.5))
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func hintLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.primary.opacity(0.5))
    }
}
