import SwiftUI

// MARK: - Settings

enum IMEInputBarSettings {
    static let defaultFontSize: Double = 12
    static let defaultHeight: Double = 90

    static var fontSize: CGFloat {
        let val = UserDefaults.standard.double(forKey: "imeBarFontSize")
        return val > 0 ? CGFloat(val) : CGFloat(defaultFontSize)
    }

    static var height: CGFloat {
        let val = UserDefaults.standard.double(forKey: "imeBarHeight")
        return val > 0 ? CGFloat(val) : CGFloat(defaultHeight)
    }
}

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

    /// Merged history: IME own entries → Claude prompt history → shell history (deduplicated).
    /// All sources are always included so the user can access any previous input regardless
    /// of what is currently running in the terminal.
    static func loadMerged() -> [String] {
        let imeEntries = load()
        let claudeEntries = ClaudeHistory.load()
        let shellEntries = ShellHistory.load()
        var seen = Set<String>()
        var merged: [String] = []
        for entry in imeEntries + claudeEntries + shellEntries {
            if !seen.contains(entry) {
                seen.insert(entry)
                merged.append(entry)
            }
        }
        return Array(merged.prefix(200))
    }
}

// MARK: - Claude Code history reader

private enum ClaudeHistory {
    /// Reads `~/.claude/history.jsonl` and returns prompt display strings,
    /// most recent first. Entries are capped to avoid memory bloat.
    static func load() -> [String] {
        let historyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/history.jsonl")
        guard let data = try? Data(contentsOf: historyPath),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let lines = content.components(separatedBy: .newlines)
        var entries: [String] = []
        entries.reserveCapacity(min(lines.count, 300))

        // Parse in reverse (most recent last in file → most recent first in result)
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let display = obj["display"] as? String else { continue }

            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty, slash commands, and very short entries
            if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.count < 2 { continue }
            // Cap individual entry length
            let capped = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed
            entries.append(capped)
            if entries.count >= 300 { break }
        }
        return entries
    }
}

// MARK: - Shell history reader

private enum ShellHistory {
    /// Reads shell history (~/.zsh_history or ~/.bash_history), most recent first.
    static func load() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Try zsh first, then bash
        let candidates = [
            home.appendingPathComponent(".zsh_history"),
            home.appendingPathComponent(".bash_history"),
        ]
        guard let historyURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: historyURL),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let isZsh = historyURL.lastPathComponent == ".zsh_history"
        let lines = content.components(separatedBy: .newlines)
        var entries: [String] = []
        entries.reserveCapacity(min(lines.count, 300))

        // Parse in reverse (most recent at the end of file)
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            let command: String
            if isZsh, line.hasPrefix(": ") {
                // Extended zsh format: ": timestamp:0;command"
                if let semicolonIdx = line.firstIndex(of: ";") {
                    command = String(line[line.index(after: semicolonIdx)...])
                } else {
                    continue
                }
            } else {
                command = line
            }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.count < 2 { continue }
            // Skip duplicates within shell history
            if entries.contains(trimmed) { continue }
            let capped = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed
            entries.append(capped)
            if entries.count >= 300 { break }
        }
        return entries
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
    var onCtrlC: (() -> Void)? = nil
    /// Send a raw key event (keycode + modifier flags) to the terminal surface.
    var onSendKey: ((_ keycode: UInt16, _ mods: UInt32) -> Void)? = nil

    @State private var text: String = ""
    @State private var history: [String] = IMEHistory.loadMerged()
    @State private var historyIndex: Int = -1   // -1 = editing draft
    @State private var historyDraft: String = ""
    @State private var isComposing: Bool = false
    @State private var showKeyboardHelp: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFieldFocused: Bool

    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Actions

    private func doSubmit() {
        if text.isEmpty {
            // Pass through Enter to the terminal so the user isn't "trapped"
            onSubmit("")
            return
        }
        let submitted = text
        addToHistory(submitted)
        onSubmit(submitted)
        text = ""
    }

    private func doSubmitAndClose() {
        if !text.isEmpty {
            let submitted = text
            addToHistory(submitted)
            onSubmit(submitted)
            text = ""
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
                    helpRow("⇧Tab", "Send Shift+Tab (accept)")
                    helpRow("⌥↑↓←→", "Arrow to terminal")
                    helpRow("⌥Tab", "Tab to terminal")
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

// MARK: - Custom NSTextView wrapper for Enter/Shift+Enter/History handling

struct IMETextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var onCtrlC: (() -> Void)? = nil
    var onSendKey: ((_ keycode: UInt16, _ mods: UInt32) -> Void)? = nil
    var onSubmitAndClose: (() -> Void)? = nil
    let onHistoryUp: () -> Void
    let onHistoryDown: () -> Void
    var onHistorySearch: (() -> Void)? = nil
    var onComposingChanged: ((Bool) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

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
        textView.font = NSFont.monospacedSystemFont(ofSize: IMEInputBarSettings.fontSize, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = true
        textView.insertionPointColor = NSColor.textColor
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Explicit marked text (IME composing) attributes for dark mode visibility
        textView.markedTextAttributes = [
            .foregroundColor: NSColor.textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.cyan.withAlphaComponent(0.6),
        ]

        textView.submitHandler = onSubmit
        textView.cancelHandler = onCancel
        textView.ctrlCHandler = onCtrlC
        textView.sendKeyHandler = onSendKey
        textView.submitAndCloseHandler = onSubmitAndClose
        textView.historyUpHandler = onHistoryUp
        textView.historyDownHandler = onHistoryDown
        textView.historySearchHandler = onHistorySearch
        textView.composingHandler = onComposingChanged

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
        if textView.submittableText() != text && !textView.hasMarkedText() {
            // Clear image attachments when text is reset externally (e.g. after submit)
            if text.isEmpty {
                textView.imageAttachments.removeAll()
            }
            textView.string = text
            textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        }
        // Update colors when appearance changes
        textView.textColor = NSColor.textColor
        textView.backgroundColor = .clear
        textView.insertionPointColor = NSColor.textColor
        textView.markedTextAttributes = [
            .foregroundColor: NSColor.textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.cyan.withAlphaComponent(0.6),
        ]

        textView.submitHandler = onSubmit
        textView.cancelHandler = onCancel
        textView.ctrlCHandler = onCtrlC
        textView.sendKeyHandler = onSendKey
        textView.submitAndCloseHandler = onSubmitAndClose
        textView.historyUpHandler = onHistoryUp
        textView.historyDownHandler = onHistoryDown
        textView.historySearchHandler = onHistorySearch
        textView.composingHandler = onComposingChanged
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IMETextEditor
        weak var textView: NSTextView?

        init(_ parent: IMETextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? IMETextView else { return }
            parent.text = textView.submittableText()
        }
    }
}

/// Custom NSTextView that intercepts Enter (submit), Shift+Enter (newline),
/// Up/Down (history navigation), and Escape (cancel).
final class IMETextView: NSTextView {
    var submitHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    var ctrlCHandler: (() -> Void)?
    var historyUpHandler: (() -> Void)?
    var historyDownHandler: (() -> Void)?
    var historySearchHandler: (() -> Void)?
    var composingHandler: ((Bool) -> Void)?
    /// Send a raw key event (keycode + mods) directly to the terminal surface,
    /// bypassing text input.  Used for Shift+Tab, Ctrl+Tab, and similar TUI shortcuts.
    var sendKeyHandler: ((_ keycode: UInt16, _ mods: UInt32) -> Void)?
    /// Submit current text and close the IME box in one action (Cmd+Enter).
    var submitAndCloseHandler: (() -> Void)?
    /// Tracks the last ESC keypress time for double-ESC detection.
    private var lastEscapeTime: TimeInterval = 0
    /// Double-ESC threshold in seconds.
    private let doubleEscapeThreshold: TimeInterval = 0.4

    // MARK: - Focus activation

    override func mouseDown(with event: NSEvent) {
        // When the user clicks the IME box, ensure the app is activated and the
        // window is key — so typing works even when another app had focus.
        if let w = window, !w.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        super.mouseDown(with: event)
    }

    // MARK: - Key equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+C: if IME has no text selection but a terminal in the window does, copy the
        // terminal selection. This lets users mouse-select terminal text while IME is active
        // and copy it without losing IME focus.
        if event.keyCode == 8 && flags == .command && selectedRange().length == 0 {
            if let surfaceView = Self.findTerminalSurfaceWithSelection(in: window) {
                surfaceView.copy(nil)
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    /// Walk the window's view hierarchy to find a GhosttyNSView that has an active selection.
    private static func findTerminalSurfaceWithSelection(in window: NSWindow?) -> GhosttyNSView? {
        guard let contentView = window?.contentView else { return nil }
        return findGhosttyViewWithSelection(in: contentView)
    }

    private static func findGhosttyViewWithSelection(in view: NSView) -> GhosttyNSView? {
        if let gv = view as? GhosttyNSView,
           let surface = gv.surface,
           ghostty_surface_has_selection(surface) {
            return gv
        }
        for sub in view.subviews {
            if let found = findGhosttyViewWithSelection(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        // Cmd+V → paste (ensure image paste works even if menu dispatch is intercepted)
        if event.keyCode == 9 && event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
            paste(nil)
            return
        }
        // Cmd+Enter → submit and close IME box
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            submitAndCloseHandler?()
            return
        }
        // Enter without Shift → submit (guard: let IME commit composed text first)
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            submitHandler?()
            return
        }
        // Shift+Enter → insert newline (guard: let IME handle if composing)
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            insertNewline(nil)
            return
        }
        // Ctrl+C → send ETX interrupt + key event (enables Claude double Ctrl+C exit)
        if event.keyCode == 8 && event.modifierFlags.contains(.control) {
            ctrlCHandler?()
            return
        }
        // Ctrl+A → move to beginning of line (readline)
        if event.keyCode == 0 && event.modifierFlags.contains(.control) {
            moveToBeginningOfLine(nil)
            return
        }
        // Ctrl+E → move to end of line (readline)
        if event.keyCode == 14 && event.modifierFlags.contains(.control) {
            moveToEndOfLine(nil)
            return
        }
        // Ctrl+K → delete to end of paragraph (readline)
        if event.keyCode == 40 && event.modifierFlags.contains(.control) {
            deleteToEndOfParagraph(nil)
            return
        }
        // Ctrl+W → delete word backward (readline)
        if event.keyCode == 13 && event.modifierFlags.contains(.control) {
            deleteWordBackward(nil)
            return
        }
        // Ctrl+R → reverse history search
        if event.keyCode == 15 && event.modifierFlags.contains(.control) {
            historySearchHandler?()
            return
        }
        // Shift+Tab → forward to terminal (Claude Code uses this for accepting suggestions)
        if event.keyCode == 48 && event.modifierFlags.contains(.shift) {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_SHIFT.rawValue))
            return
        }
        // Cmd+Escape → close IME box
        if event.keyCode == 53 && event.modifierFlags.contains(.command) {
            cancelHandler?()
            return
        }
        // Escape handling: double-ESC → Ctrl+C to terminal, single ESC → forward ESC to terminal
        if event.keyCode == 53 {
            let now = CACurrentMediaTime()
            if (now - lastEscapeTime) < doubleEscapeThreshold {
                // Double-ESC: send Ctrl+C (keycode 8 = 'c', with ctrl mod) to cancel running command
                sendKeyHandler?(8, UInt32(GHOSTTY_MODS_CTRL.rawValue))
                lastEscapeTime = 0  // reset to avoid triple-trigger
            } else {
                // Single ESC: forward to terminal
                sendKeyHandler?(event.keyCode, 0)
                lastEscapeTime = now
            }
            return
        }
        // Option+ArrowUp → forward plain Up arrow to terminal (e.g. Claude menu navigation)
        if event.keyCode == 126 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, 0)
            return
        }
        // Option+ArrowDown → forward plain Down arrow to terminal
        if event.keyCode == 125 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, 0)
            return
        }
        // Option+ArrowLeft → forward Alt+Left to terminal (word-level cursor movement)
        if event.keyCode == 123 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_ALT.rawValue))
            return
        }
        // Option+ArrowRight → forward Alt+Right to terminal (word-level cursor movement)
        if event.keyCode == 124 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_ALT.rawValue))
            return
        }
        // Option+Tab → forward Meta+Tab to terminal (e.g. Claude thinking toggle)
        if event.keyCode == 48 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_ALT.rawValue))
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

    // MARK: - Paste (image → inline thumbnail)

    /// Pasted image attachments and their /tmp file paths.
    var imageAttachments: [(attachment: NSTextAttachment, path: String)] = []

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) != nil || pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")) != nil {
            super.paste(sender)
            return
        }
        if let path = GhosttyPasteboardHelper.saveClipboardImageToTempFile(from: pb),
           let image = NSImage(contentsOfFile: path) {
            let attachment = NSTextAttachment()
            let maxHeight: CGFloat = 48
            let scale = min(maxHeight / image.size.height, 1.0)
            let thumbSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let cell = NSTextAttachmentCell(imageCell: image)
            cell.image?.size = thumbSize
            attachment.attachmentCell = cell

            let attrStr = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            attrStr.append(NSAttributedString(string: " ",
                attributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]))

            textStorage?.insert(attrStr, at: selectedRange().location)
            setSelectedRange(NSRange(location: selectedRange().location + attrStr.length, length: 0))
            imageAttachments.append((attachment: attachment, path: path))
            delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
            return
        }
        super.paste(sender)
    }

    /// Returns text with image attachments replaced by their file paths.
    func submittableText() -> String {
        guard let storage = textStorage, !imageAttachments.isEmpty else { return string }
        var result = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            if let att = attrs[.attachment] as? NSTextAttachment,
               let entry = imageAttachments.first(where: { $0.attachment === att }) {
                result += entry.path
            } else {
                result += (storage.string as NSString).substring(with: range)
            }
        }
        return result
    }

    // MARK: - IME composition tracking

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composingHandler?(hasMarkedText())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        composingHandler?(false)
    }
}
