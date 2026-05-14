import SwiftUI

struct IMEAgentMention: Identifiable, Equatable {
    let mention: String
    let title: String
    let subtitle: String
    let isBroadcast: Bool

    var id: String { mention }
}

private enum IMEAgentRouteMode: Equatable {
    case message
    case task
    case ping

    var label: String {
        switch self {
        case .message: return "msg"
        case .task: return "task"
        case .ping: return "ping"
        }
    }

    func color(isDark: Bool) -> Color {
        switch self {
        case .message: return Color.cyan.opacity(isDark ? 0.9 : 0.78)
        case .task: return Color.indigo.opacity(isDark ? 0.9 : 0.75)
        case .ping: return Color.green.opacity(isDark ? 0.85 : 0.74)
        }
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
    let onSubmit: (String) -> Bool
    let onBroadcast: ((String) -> Void)?
    let onClose: () -> Void
    var onCtrlC: (() -> Void)? = nil
    /// Stop all team agents — sends Ctrl+C to every agent panel.
    var onStopAllAgents: (() -> Void)? = nil
    /// Available team targets for @mention routing.
    var agentMentions: [IMEAgentMention] = []
    /// Route the current text through the leader for an @mention target. The mention is passed without "@".
    var onAgentMentionSend: ((_ mention: String, _ text: String) -> Bool)? = nil
    /// Send a raw key event (keycode + modifier flags) to the terminal surface.
    var onSendKey: ((_ keycode: UInt16, _ mods: UInt32) -> Void)? = nil
    /// Terminal working directory — used to discover project-local slash commands.
    var workingDirectory: String? = nil
    /// Slash aliases expanded just before submit, e.g. /tm -> read .codex/prompts/tm.md.
    var slashCommandAliases: [String: String] = [:]

    @State private var text: String = ""
    @State private var history: [String] = IMEHistory.load()   // Q4: fast sync init; merged async in .task
    @State private var slashCommands: [SlashCommand] = []
    @State private var historyIndex: Int = -1   // -1 = editing draft
    @State private var historyDraft: String = ""
    @State private var isComposing: Bool = false
    @State private var showKeyboardHelp: Bool = false
    @State private var compactHintBar: Bool = false
    @State private var feedbackState: FeedbackState = .none  // Q1
    // M1: Fuzzy history picker state
    @State private var showHistoryPicker: Bool = false
    @State private var historyPickerSelection: Int = 0
    // Slash command picker state
    @State private var showSlashPicker: Bool = false
    @State private var slashPickerSelection: Int = 0
    // Agent @mention picker state
    @State private var showAgentPicker: Bool = false
    @State private var agentPickerSelection: Int = 0
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFieldFocused: Bool

    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Q1: Feedback state

    private enum FeedbackState { case none, success, failure }

    private var feedbackColor: Color {
        switch feedbackState {
        case .none:    return .clear
        case .success: return Color(red: 0.55, green: 0.45, blue: 0.95)
        case .failure: return .red
        }
    }

    private var activeAgentTarget: IMEAgentMention? {
        guard text.hasPrefix("@") else { return nil }
        let token = text
            .dropFirst()
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)?
            .lowercased()
        guard let token, !token.isEmpty else { return nil }
        if token == "team" {
            return IMEAgentMention(
                mention: "team",
                title: "@team",
                subtitle: "Route to all agents",
                isBroadcast: true
            )
        }
        return agentMentions.first { $0.mention.lowercased() == token }
    }

    private var activeAgentMode: IMEAgentRouteMode? {
        guard activeAgentTarget != nil,
              let route = agentRoute(for: text) else {
            return activeAgentTarget == nil ? nil : .message
        }
        return classifyAgentRouteMode(route.message)
    }

    private var activeAgentBorderColor: Color {
        guard let mode = activeAgentMode else { return .clear }
        return mode.color(isDark: isDark)
    }

    private var effectiveBorderColor: Color {
        feedbackState == .none ? activeAgentBorderColor : feedbackColor
    }

    private var effectiveBorderWidth: CGFloat {
        if feedbackState != .none { return 2 }
        return activeAgentTarget == nil ? 0 : 1.5
    }

    // MARK: - M1: Fuzzy history matching

    private struct HistoryMatch {
        let index: Int
        let entry: String
        let score: Int
    }

    private func fuzzyMatch(_ query: String, in candidate: String) -> (matched: Bool, score: Int) {
        let q = query.lowercased()
        let c = candidate.lowercased()
        if c.hasPrefix(q) { return (true, 1000 + q.count) }
        var qIdx = q.startIndex
        var score = 0
        var consecutive = 0
        for char in c {
            if qIdx < q.endIndex && char == q[qIdx] {
                score += 1 + consecutive * 2
                consecutive += 1
                qIdx = q.index(after: qIdx)
            } else {
                consecutive = 0
            }
        }
        return (qIdx == q.endIndex, score)
    }

    private var filteredHistory: [HistoryMatch] {
        guard showHistoryPicker else { return [] }
        if text.isEmpty {
            return Array(history.prefix(10).enumerated().map {
                HistoryMatch(index: $0.offset, entry: $0.element, score: 0)
            })
        }
        return Array(history.enumerated()
            .compactMap { idx, entry -> HistoryMatch? in
                let (matched, score) = fuzzyMatch(text, in: entry)
                return matched ? HistoryMatch(index: idx, entry: entry, score: score) : nil
            }
            .sorted { $0.score > $1.score }
            .prefix(10)
        )
    }

    private var filteredSlashCommands: [SlashCommand] {
        guard showSlashPicker else { return [] }
        let query = text.lowercased()
        let commands = mergedSlashCommands
        if query == "/" {
            return Array(commands.prefix(15))
        }
        return Array(commands
            .filter { $0.name.lowercased().hasPrefix(query) }
            .prefix(15))
    }

    private var mergedSlashCommands: [SlashCommand] {
        guard !slashCommandAliases.isEmpty else { return slashCommands }
        var seen = Set<String>()
        var merged: [SlashCommand] = []
        for alias in slashCommandAliases.keys.sorted() {
            if seen.insert(alias).inserted {
                merged.append(SlashCommand(name: alias, desc: "Codex prompt alias"))
            }
        }
        for command in slashCommands where seen.insert(command.name).inserted {
            merged.append(command)
        }
        return merged.sorted { $0.name < $1.name }
    }

    private var filteredAgentMentions: [IMEAgentMention] {
        guard showAgentPicker else { return [] }
        let query = String(text.dropFirst()).lowercased()
        if query.isEmpty {
            return Array(agentMentions.prefix(15))
        }
        return Array(agentMentions
            .filter {
                $0.mention.lowercased().hasPrefix(query)
                    || $0.title.lowercased().hasPrefix("@\(query)")
            }
            .prefix(15))
    }

    // MARK: - Actions

    private func agentRoute(for raw: String) -> (mention: String, message: String)? {
        guard raw.hasPrefix("@") else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines
        guard let split = raw.rangeOfCharacter(from: separators) else { return nil }
        let token = String(raw[..<split.lowerBound]).dropFirst().lowercased()
        guard !token.isEmpty else { return nil }
        let message = String(raw[split.upperBound...]).trimmingCharacters(in: separators)
        guard !message.isEmpty else { return nil }

        let knownMentions = Set(agentMentions.map { $0.mention.lowercased() } + ["team"])
        guard knownMentions.contains(String(token)) else { return nil }
        return (String(token), message)
    }

    private func classifyAgentRouteMode(_ raw: String) -> IMEAgentRouteMode {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if lower.hasPrefix("task ") || lower.hasPrefix("delegate ") ||
            lower.hasPrefix("작업 ") || lower.hasPrefix("일감 ") ||
            value.hasPrefix(":") {
            return .task
        }
        if lower == "ping" || lower.contains("ping") || lower.contains("pong") ||
            lower.contains("핑") || lower.contains("퐁") {
            return .ping
        }
        return .message
    }

    private func submitText(_ submitted: String) -> Bool {
        let expanded = expandSlashAlias(in: submitted)
        if let route = agentRoute(for: expanded), let onAgentMentionSend {
            return onAgentMentionSend(route.mention, route.message)
        }
        return onSubmit(expanded)
    }

    private func expandSlashAlias(in submitted: String) -> String {
        guard submitted.hasPrefix("/") else { return submitted }
        let separators = CharacterSet.whitespacesAndNewlines
        let tokenEnd = submitted.rangeOfCharacter(from: separators)?.lowerBound ?? submitted.endIndex
        let token = String(submitted[..<tokenEnd])
        guard let promptFile = slashCommandAliases[token] else { return submitted }
        let args = String(submitted[tokenEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        TERM-MESH CODEX PROMPT REQUEST
        PROMPT_FILE: \(promptFile)
        ARGUMENTS:
        \(args)

        Read PROMPT_FILE, treat ARGUMENTS as that prompt's $ARGUMENTS, and execute the prompt's workflow. This is a user-facing shortcut for \(token); do not try to run \(token) or /prompts:* as a Codex slash command.
        """
    }

    private func doSubmit() {
        if text.isEmpty {
            // Pass through Enter to the terminal so the user isn't "trapped"
            _ = onSubmit("")
            return
        }
        let submitted = text
        let success = submitText(submitted)
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
            let success = submitText(submitted)
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

    /// Reverse-search history (Ctrl+R): open fuzzy picker.
    private func historySearch() {
        showHistoryPicker = true
        historyPickerSelection = 0
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Agent @mention picker (above input row, expands upward into available space)
            if showAgentPicker && !filteredAgentMentions.isEmpty {
                agentMentionPickerView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Slash command picker (above input row, expands upward into available space)
            if showSlashPicker && !filteredSlashCommands.isEmpty {
                slashCommandPickerView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
                    onStopAllAgents: onStopAllAgents,
                    onSendKey: onSendKey,
                    onSubmitAndClose: doSubmitAndClose,
                    onHistoryUp: historyUp,
                    onHistoryDown: historyDown,
                    onHistorySearch: historySearch,
                    onComposingChanged: { isComposing = $0 },
                    history: history,
                    slashCommands: slashCommands.map(\.name),
                    isHistoryPickerOpen: showHistoryPicker,
                    onHistoryPickerToggle: {
                        showHistoryPicker.toggle()
                        historyPickerSelection = 0
                    },
                    onHistoryPickerMove: { delta in
                        let count = filteredHistory.count
                        guard count > 0 else { return }
                        historyPickerSelection = (historyPickerSelection + delta + count) % count
                    },
                    onHistoryPickerConfirm: {
                        guard historyPickerSelection < filteredHistory.count else { return }
                        text = filteredHistory[historyPickerSelection].entry
                        showHistoryPicker = false
                        historyPickerSelection = 0
                    },
                    onHistoryPickerCancel: {
                        showHistoryPicker = false
                        historyPickerSelection = 0
                    },
                    isSlashPickerOpen: showSlashPicker,
                    onSlashPickerMove: { delta in
                        let count = filteredSlashCommands.count
                        guard count > 0 else { return }
                        slashPickerSelection = (slashPickerSelection + delta + count) % count
                    },
                    onSlashPickerConfirm: {
                        guard slashPickerSelection < filteredSlashCommands.count else { return }
                        text = filteredSlashCommands[slashPickerSelection].name + " "
                        showSlashPicker = false
                        slashPickerSelection = 0
                    },
                    onSlashPickerCancel: {
                        showSlashPicker = false
                        slashPickerSelection = 0
                    },
                    isAgentPickerOpen: showAgentPicker,
                    onAgentPickerMove: { delta in
                        let count = filteredAgentMentions.count
                        guard count > 0 else { return }
                        agentPickerSelection = (agentPickerSelection + delta + count) % count
                    },
                    onAgentPickerConfirm: {
                        guard agentPickerSelection < filteredAgentMentions.count else { return }
                        text = "@\(filteredAgentMentions[agentPickerSelection].mention) "
                        showAgentPicker = false
                        agentPickerSelection = 0
                    },
                    onAgentPickerCancel: {
                        showAgentPicker = false
                        agentPickerSelection = 0
                    }
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
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { compactHintBar = geo.size.width < 300 }
                                .onChange(of: geo.size.width) { w in compactHintBar = w < 300 }
                        }
                    )

                Spacer()

                // Status indicators (right-aligned)
                HStack(spacing: 8) {
                    if let target = activeAgentTarget, let mode = activeAgentMode {
                        Text("leader \(mode.label) → @\(target.mention)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(mode.color(isDark: isDark))
                            .lineLimit(1)
                    }

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
                .stroke(effectiveBorderColor, lineWidth: effectiveBorderWidth)
                .animation(.easeInOut(duration: 0.15), value: feedbackState)
                .animation(.easeInOut(duration: 0.12), value: activeAgentTarget?.mention)
        )
        // M1: fuzzy history picker popover (appears above the bar)
        .popover(isPresented: $showHistoryPicker, arrowEdge: .bottom) {
            historyPickerView
        }
        // (slash picker is inline in VStack above)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFieldFocused = true
            }
        }
        // Q4: async history loading + slash command scanning (both off main thread)
        .task {
            let loaded = await Task.detached { IMEHistory.loadMerged() }.value
            history = loaded
        }
        .task {
            let wd = workingDirectory
            let loaded = await Task.detached { SlashCommands.loadAll(workingDirectory: wd) }.value
            slashCommands = loaded
        }
        // M1: reset picker selection when text changes; auto-open slash picker
        .onChange(of: text) { _ in
            if showHistoryPicker { historyPickerSelection = 0 }
            if showAgentPicker { agentPickerSelection = 0 }

            let isAgentQuery = !isComposing
                && text.hasPrefix("@")
                && !text.contains(" ")
                && !text.contains("\n")
                && !agentMentions.isEmpty
            if isAgentQuery && !showAgentPicker {
                showAgentPicker = true
                showSlashPicker = false
                showHistoryPicker = false
                agentPickerSelection = 0
            } else if !isAgentQuery && showAgentPicker {
                showAgentPicker = false
                agentPickerSelection = 0
            } else if showAgentPicker {
                agentPickerSelection = 0
            }

            // Auto-trigger slash picker when text is a bare slash command prefix
            let isSlashQuery = !isComposing && text.hasPrefix("/") && !text.contains(" ") && !text.contains("\n")
            if isSlashQuery && !showSlashPicker {
                showSlashPicker = true
                showAgentPicker = false
                showHistoryPicker = false
                slashPickerSelection = 0
            } else if !isSlashQuery && showSlashPicker {
                showSlashPicker = false
                slashPickerSelection = 0
            } else if showSlashPicker {
                slashPickerSelection = 0
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

                if onStopAllAgents != nil {
                    Button(action: { onStopAllAgents?() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.red)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help("Stop all agents (⌃⇧C)")
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
            // Only show hint labels when there is enough width
            if !compactHintBar {
                hintLabel("⏎ send")
                hintLabel("⌘⏎ send+close")
                hintLabel("⇧⏎ newline")
                hintLabel("Tab →term")
                hintLabel("⇧Tab accept")
                if !agentMentions.isEmpty {
                    hintLabel("@ agent")
                }
                hintLabel("Esc →term")
                hintLabel("⌃U clear")
                hintLabel("⌃C interrupt")
                if onStopAllAgents != nil {
                    hintLabel("⌃⇧C stop all")
                }
            }

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

    // MARK: - M1: History picker popover content

    private var historyPickerView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("⌃R close · ↑↓ nav · ⏎ select · Esc close")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if filteredHistory.isEmpty {
                Text("No matching history")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredHistory.enumerated()), id: \.offset) { i, item in
                            Button(action: {
                                text = item.entry
                                showHistoryPicker = false
                                historyPickerSelection = 0
                            }) {
                                HStack(spacing: 6) {
                                    Text(item.entry)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    i == historyPickerSelection
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)

                            if i < filteredHistory.count - 1 {
                                Divider().padding(.leading, 10)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .frame(width: 420)
    }

    // MARK: - Agent @mention picker content

    private var agentMentionPickerView: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                Text("Agents")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("↑↓ nav · Tab/⏎ select · Esc close")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(Array(filteredAgentMentions.enumerated()), id: \.offset) { i, target in
                            Button(action: {
                                text = "@\(target.mention) "
                                showAgentPicker = false
                                agentPickerSelection = 0
                            }) {
                                HStack(spacing: 8) {
                                    Text("@\(target.mention)")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(i == agentPickerSelection ? .white : .primary)
                                        .lineLimit(1)
                                        .frame(minWidth: 130, minHeight: 16, alignment: .leading)
                                    Text(target.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundColor(i == agentPickerSelection ? .white.opacity(0.75) : .secondary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 26, alignment: .center)
                                .background(
                                    i == agentPickerSelection
                                        ? Color.indigo.opacity(0.65)
                                        : Color.clear
                                )
                                .cornerRadius(3)
                            }
                            .buttonStyle(.plain)
                            .id(i)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 180)
                .onChange(of: agentPickerSelection) { newVal in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(newVal, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Slash command picker popover content

    private var slashCommandPickerView: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                Text("Slash Commands")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("↑↓ nav · Tab/⏎ select · Esc close")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(Array(filteredSlashCommands.enumerated()), id: \.offset) { i, cmd in
                            Button(action: {
                                text = cmd.name + " "
                                showSlashPicker = false
                                slashPickerSelection = 0
                            }) {
                                HStack(spacing: 0) {
                                    Text(cmd.name)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(i == slashPickerSelection ? .white : .primary)
                                        .frame(minWidth: 140, alignment: .leading)
                                    Text(cmd.desc)
                                        .font(.system(size: 10))
                                        .foregroundColor(i == slashPickerSelection ? .white.opacity(0.7) : .secondary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 2)
                                .background(
                                    i == slashPickerSelection
                                        ? Color.teal.opacity(0.6)
                                        : Color.clear
                                )
                                .cornerRadius(3)
                            }
                            .buttonStyle(.plain)
                            .id(i)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 180)
                .onChange(of: slashPickerSelection) { newVal in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(newVal, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity)
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
                    helpRow("⌃U", "Clear line")
                    helpRow("⌃C", "Interrupt (Ctrl+C)")
                    helpRow("⌃⇧C", "Stop all agents")
                }
                helpSection("Navigation") {
                    helpRow("↑ ↓", "History (\(history.count))")
                    helpRow("⌃R", "Fuzzy history picker")
                    helpRow("⌃A / ⌃E", "Line start / end")
                }
                helpSection("Terminal") {
                    helpRow("Esc", "Send Escape to terminal")
                    helpRow("Tab", "Accept ghost / tab to terminal")
                    helpRow("⇧Tab", "Send Shift+Tab (accept)")
                    helpRow("⌥↑↓", "↑↓ to terminal (selection)")
                    helpRow("⌥←→", "Word move (Alt+←→)")
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
