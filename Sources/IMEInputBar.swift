import SwiftUI

// MARK: - History persistence

private enum IMEHistory {
    static let key = "imeInputBarHistory"
    static let maxEntries = 30

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ entries: [String]) {
        UserDefaults.standard.set(Array(entries.prefix(maxEntries)), forKey: key)
    }
}

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
    let onSubmit: (String) -> Void
    let onBroadcast: ((String) -> Void)?
    let onClose: () -> Void

    @State private var text: String = ""
    @State private var history: [String] = IMEHistory.load()
    @State private var historyIndex: Int = -1   // -1 = editing draft
    @State private var historyDraft: String = ""
    @FocusState private var isFieldFocused: Bool

    private var lineCount: Int {
        max(1, text.components(separatedBy: "\n").count)
    }

    // MARK: - Actions

    private func doSubmit() {
        guard !text.isEmpty else { return }
        let submitted = text
        addToHistory(submitted)
        onSubmit(submitted)
        text = ""
    }

    private func doBroadcast() {
        guard !text.isEmpty, let onBroadcast else { return }
        let submitted = text
        addToHistory(submitted)
        onBroadcast(submitted)
        text = ""
    }

    private func addToHistory(_ entry: String) {
        history.removeAll { $0 == entry }
        history.insert(entry, at: 0)
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

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "keyboard")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                    .padding(.top, 5)

                IMETextEditor(
                    text: $text,
                    onSubmit: doSubmit,
                    onCancel: onClose,
                    onHistoryUp: historyUp,
                    onHistoryDown: historyDown
                )
                .focused($isFieldFocused)

                actionButtons
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Hint bar
            hintBar

            // History position indicator
            if historyIndex >= 0 {
                Text("history [\(historyIndex + 1)/\(history.count)]")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange.opacity(0.8))
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFieldFocused = true
            }
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
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.top, 3)
    }

    private var hintBar: some View {
        HStack(spacing: 12) {
            hintLabel("Enter: send")
            hintLabel("\u{21e7}Enter: new line")
            hintLabel("\u{2191}\u{2193}: history (\(history.count))")
            hintLabel("Esc: close")
        }
        .padding(.bottom, 6)
    }

    private func hintLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.6))
    }
}

// MARK: - Custom NSTextView wrapper for Enter/Shift+Enter/History handling

struct IMETextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onHistoryUp: () -> Void
    let onHistoryDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = IMETextView()
        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.submitHandler = onSubmit
        textView.cancelHandler = onCancel
        textView.historyUpHandler = onHistoryUp
        textView.historyDownHandler = onHistoryDown

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Focus the text view
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? IMETextView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        }
        textView.submitHandler = onSubmit
        textView.cancelHandler = onCancel
        textView.historyUpHandler = onHistoryUp
        textView.historyDownHandler = onHistoryDown
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IMETextEditor
        weak var textView: NSTextView?

        init(_ parent: IMETextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// Custom NSTextView that intercepts Enter (submit), Shift+Enter (newline),
/// Up/Down (history navigation), and Escape (cancel).
final class IMETextView: NSTextView {
    var submitHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    var historyUpHandler: (() -> Void)?
    var historyDownHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Enter without Shift → submit
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            submitHandler?()
            return
        }
        // Shift+Enter → insert newline (default behavior)
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
            insertNewline(nil)
            return
        }
        // Escape → cancel
        if event.keyCode == 53 {
            cancelHandler?()
            return
        }
        // ArrowUp → history (when cursor is on first line and not composing IME)
        if event.keyCode == 126 && !hasMarkedText() && isCursorOnFirstLine() {
            historyUpHandler?()
            return
        }
        // ArrowDown → history (when cursor is on last line and not composing IME)
        if event.keyCode == 125 && !hasMarkedText() && isCursorOnLastLine() {
            historyDownHandler?()
            return
        }
        super.keyDown(with: event)
    }

    private func isCursorOnFirstLine() -> Bool {
        let loc = selectedRange().location
        let str = string as NSString
        let firstNewline = str.range(of: "\n").location
        return firstNewline == NSNotFound || loc <= firstNewline
    }

    private func isCursorOnLastLine() -> Bool {
        let loc = selectedRange().location
        let str = string as NSString
        let lastNewline = str.range(of: "\n", options: .backwards).location
        return lastNewline == NSNotFound || loc > lastNewline
    }
}
