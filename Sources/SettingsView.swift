import AppKit
import SwiftUI

struct SettingsView: View {
    private let contentTopInset: CGFloat = 8
    private let pickerColumnWidth: CGFloat = 196

    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(ClaudeCodeIntegrationSettings.hooksEnabledKey)
    private var claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
    @AppStorage("termMeshPortBase") private var termMeshPortBase = 9100
    @AppStorage("termMeshPortRange") private var termMeshPortRange = 10
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserThemeSettings.modeKey) private var browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowserKey) private var openTerminalLinksInTermMeshBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInTermMeshBrowser
    @AppStorage(BrowserLinkOpenSettings.interceptTerminalOpenCommandInTermMeshBrowserKey)
    private var interceptTerminalOpenCommandInTermMeshBrowser = BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInTermMeshBrowserValue()
    @AppStorage(BrowserLinkOpenSettings.browserHostWhitelistKey) private var browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
    @AppStorage(BrowserInsecureHTTPSettings.allowlistKey) private var browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
    @AppStorage(NotificationBadgeSettings.dockBadgeEnabledKey) private var notificationDockBadgeEnabled = NotificationBadgeSettings.defaultDockBadgeEnabled
    @AppStorage(QuitWarningSettings.warnBeforeQuitKey) private var warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(WorkspacePlacementSettings.placementKey) private var newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
    @AppStorage(WorkspaceAutoReorderSettings.key) private var workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
    @AppStorage(SessionRestoreSettings.modeKey) private var sessionRestoreMode = SessionRestoreSettings.defaultMode.rawValue
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("teamDefaultLeaderMode") private var teamDefaultLeaderMode = "claude"
    @AppStorage("teamDefaultModel") private var teamDefaultModel = "sonnet"
    @AppStorage("teamDefaultWorkingDirectory") private var teamDefaultWorkingDirectory = ""
    @AppStorage("cliPath.claude") private var cliPathClaude = ""
    @AppStorage("cliPath.kiro") private var cliPathKiro = ""
    @AppStorage("cliPath.codex") private var cliPathCodex = ""
    @AppStorage("cliPath.gemini") private var cliPathGemini = ""
    @AppStorage("imeBarFontSize") private var imeBarFontSize = IMEInputBarSettings.defaultFontSize
    @AppStorage("imeBarHeight") private var imeBarHeight = IMEInputBarSettings.defaultHeight
    @AppStorage(TermMeshDaemon.dashboardEnabledKey) private var dashboardEnabled = true
    @AppStorage(TermMeshDaemon.dashboardLocalhostOnlyKey) private var dashboardLocalhostOnly = true
    @AppStorage(TermMeshDaemon.dashboardPortKey) private var dashboardPort = 9876
    @AppStorage(TermMeshDaemon.dashboardPasswordKey) private var dashboardPassword = ""

    @Environment(\.daemonService) private var daemonService
    @Environment(\.browserHistoryService) private var browserHistory

    @State private var shortcutResetToken = UUID()
    @State private var topBlurOpacity: Double = 0
    @State private var topBlurBaselineOffset: CGFloat?
    @State private var settingsTitleLeadingInset: CGFloat = 92
    @State private var settingsSearchQuery = ""
    @State private var showClearBrowserHistoryConfirmation = false
    @State private var showOpenAccessConfirmation = false
    @State private var pendingOpenAccessMode: SocketControlMode?
    @State private var browserHistoryEntryCount: Int = 0
    @State private var browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
    @State private var socketPasswordDraft = ""
    @State private var socketPasswordStatusMessage: String?
    @State private var socketPasswordStatusIsError = false
    @State private var workspaceTabDefaultEntries = WorkspaceTabColorSettings.defaultPaletteWithOverrides()
    @State private var workspaceTabCustomColors = WorkspaceTabColorSettings.customColors()

    private var selectedWorkspacePlacement: NewWorkspacePlacement {
        NewWorkspacePlacement(rawValue: newWorkspacePlacement) ?? WorkspacePlacementSettings.defaultPlacement
    }

    private var selectedSidebarActiveTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarActiveTabIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    private var selectedSocketControlMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    private var selectedBrowserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeMode)
    }

    private var browserThemeModeSelection: Binding<String> {
        Binding(
            get: { browserThemeMode },
            set: { newValue in
                browserThemeMode = BrowserThemeSettings.mode(for: newValue).rawValue
            }
        )
    }

    private var socketModeSelection: Binding<String> {
        Binding(
            get: { socketControlMode },
            set: { newValue in
                let normalized = SocketControlSettings.migrateMode(newValue)
                if normalized == .allowAll && selectedSocketControlMode != .allowAll {
                    pendingOpenAccessMode = normalized
                    showOpenAccessConfirmation = true
                    return
                }
                socketControlMode = normalized.rawValue
                if normalized != .password {
                    socketPasswordStatusMessage = nil
                    socketPasswordStatusIsError = false
                }
            }
        )
    }

    private var hasSocketPasswordConfigured: Bool {
        SocketControlPasswordStore.hasConfiguredPassword()
    }

    private var browserHistorySubtitle: String {
        switch browserHistoryEntryCount {
        case 0:
            return "No saved pages yet."
        case 1:
            return "1 saved page appears in omnibar suggestions."
        default:
            return "\(browserHistoryEntryCount) saved pages appear in omnibar suggestions."
        }
    }

    private var browserInsecureHTTPAllowlistHasUnsavedChanges: Bool {
        browserInsecureHTTPAllowlistDraft != browserInsecureHTTPAllowlist
    }

    private func blurOpacity(forContentOffset offset: CGFloat) -> Double {
        guard let baseline = topBlurBaselineOffset else { return 0 }
        let reveal = (baseline - offset) / 24
        return Double(min(max(reveal, 0), 1))
    }

    private func saveSocketPassword() {
        let trimmed = socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            socketPasswordStatusMessage = "Enter a password first."
            socketPasswordStatusIsError = true
            return
        }

        do {
            try SocketControlPasswordStore.savePassword(trimmed)
            socketPasswordDraft = ""
            socketPasswordStatusMessage = "Password saved to keychain."
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = "Failed to save password (\(error.localizedDescription))."
            socketPasswordStatusIsError = true
        }
    }

    private func clearSocketPassword() {
        do {
            try SocketControlPasswordStore.clearPassword()
            socketPasswordDraft = ""
            socketPasswordStatusMessage = "Password cleared."
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = "Failed to clear password (\(error.localizedDescription))."
            socketPasswordStatusIsError = true
        }
    }

    private var normalizedSearchQuery: String {
        settingsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearching: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private func settingsMatch(_ keywords: String...) -> Bool {
        let q = normalizedSearchQuery
        guard !q.isEmpty else { return true }
        return keywords.contains { $0.lowercased().contains(q) }
    }

    private func sectionVisible(_ sectionKeywords: [String], rowKeywords: [[String]]) -> Bool {
        let q = normalizedSearchQuery
        guard !q.isEmpty else { return true }
        if sectionKeywords.contains(where: { $0.lowercased().contains(q) }) { return true }
        return rowKeywords.contains { group in
            group.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if sectionVisible(["app"], rowKeywords: [
                        ["theme", "appearance", "dark", "light"],
                        ["workspace", "placement", "new tab", "position"],
                        ["reorder", "notification"],
                        ["session", "restore", "resume", "reopen", "directory", "folder", "startup", "launch"],
                        ["dock", "badge", "unread"],
                        ["quit", "warn", "confirmation"],
                        ["rename", "select", "command palette"],
                        ["sidebar", "branch", "layout", "git"]
                    ]) {
                    SettingsSectionHeader(title: "App")
                    SettingsCard {
                        if settingsMatch("theme", "appearance", "dark", "light", "app") {
                        SettingsCardRow("Theme", controlWidth: pickerColumnWidth) {
                            Picker("", selection: $appearanceMode) {
                                ForEach(AppearanceMode.visibleCases) { mode in
                                    Text(mode.displayName).tag(mode.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        }

                        if settingsMatch("workspace", "placement", "new tab", "position", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "New Workspace Placement",
                            subtitle: selectedWorkspacePlacement.description,
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: $newWorkspacePlacement) {
                                ForEach(NewWorkspacePlacement.allCases) { placement in
                                    Text(placement.displayName).tag(placement.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        }

                        if settingsMatch("reorder", "notification", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Reorder on Notification",
                            subtitle: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions."
                        ) {
                            Toggle("", isOn: $workspaceAutoReorder)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        }

                        if settingsMatch("session", "restore", "resume", "reopen", "directory", "folder", "startup", "launch", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Session Restore",
                            subtitle: sessionRestoreMode == SessionRestoreMode.always.rawValue
                                ? "Reopen previous workspaces and directories on launch."
                                : "Start with a fresh workspace on launch.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: $sessionRestoreMode) {
                                ForEach(SessionRestoreMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode.rawValue)
                                }
                            }
                            .labelsHidden()
                        }
                        }

                        if settingsMatch("dock", "badge", "unread", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Dock Badge",
                            subtitle: "Show unread count on app icon (Dock and Cmd+Tab)."
                        ) {
                            Toggle("", isOn: $notificationDockBadgeEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        }

                        if settingsMatch("quit", "warn", "confirmation", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Warn Before Quit",
                            subtitle: warnBeforeQuitShortcut
                                ? "Show a confirmation before quitting with Cmd+Q."
                                : "Cmd+Q quits immediately without confirmation."
                        ) {
                            Toggle("", isOn: $warnBeforeQuitShortcut)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        }

                        if settingsMatch("rename", "select", "command palette", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Rename Selects Existing Name",
                            subtitle: commandPaletteRenameSelectAllOnFocus
                                ? "Command Palette rename starts with all text selected."
                                : "Command Palette rename keeps the caret at the end."
                        ) {
                            Toggle("", isOn: $commandPaletteRenameSelectAllOnFocus)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        }

                        if settingsMatch("sidebar", "branch", "layout", "git", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Sidebar Branch Layout",
                            subtitle: sidebarBranchVerticalLayout
                                ? "Vertical: each branch appears on its own line."
                                : "Inline: all branches share one line."
                        ) {
                            Picker("", selection: $sidebarBranchVerticalLayout) {
                                Text("Vertical").tag(true)
                                Text("Inline").tag(false)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        }

                    }
                    }

                    if settingsMatch("workspace", "color", "indicator", "palette", "custom") {
                    SettingsSectionHeader(title: "Workspace Colors")
                    SettingsCard {
                        SettingsCardRow(
                            "Workspace Color Indicator",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: sidebarIndicatorStyleSelection) {
                                ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                    Text(style.displayName).tag(style.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        SettingsCardDivider()

                        SettingsCardNote("Customize the workspace color palette used by Sidebar > Tab Color. \"Choose Custom Color...\" entries are persisted below.")

                        ForEach(Array(workspaceTabDefaultEntries.enumerated()), id: \.element.name) { index, entry in
                            if index > 0 {
                                SettingsCardDivider()
                            }
                            SettingsCardRow(
                                entry.name,
                                subtitle: "Base: \(baseTabColorHex(for: entry.name))"
                            ) {
                                HStack(spacing: 8) {
                                    ColorPicker(
                                        "",
                                        selection: defaultTabColorBinding(for: entry.name),
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()
                                    .frame(width: 38)

                                    Text(entry.hex)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 76, alignment: .trailing)
                                }
                            }
                        }

                        SettingsCardDivider()

                        if workspaceTabCustomColors.isEmpty {
                            SettingsCardNote("Custom colors: none yet. Use \"Choose Custom Color...\" from a workspace context menu.")
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Custom Colors")
                                    .font(.system(size: 13, weight: .semibold))

                                ForEach(workspaceTabCustomColors, id: \.self) { hex in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                                            .frame(width: 11, height: 11)

                                        Text(hex)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)

                                        Spacer(minLength: 8)

                                        Button("Remove") {
                                            removeWorkspaceCustomColor(hex)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            "Reset Palette",
                            subtitle: "Restore built-in defaults and clear all custom colors."
                        ) {
                            Button("Reset") {
                                resetWorkspaceTabColors()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    }

                    if settingsMatch("automation", "socket", "claude", "port", "integration", "password") {
                    SettingsSectionHeader(title: "Automation")
                    SettingsCard {
                        SettingsCardRow(
                            "Socket Control Mode",
                            subtitle: selectedSocketControlMode.description,
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: socketModeSelection) {
                                ForEach(SocketControlMode.uiCases) { mode in
                                    Text(mode.displayName).tag(mode.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("AutomationSocketModePicker")
                        }

                        SettingsCardDivider()

                        SettingsCardNote("Controls access to the local Unix socket for programmatic control. Choose a mode that matches your threat model.")
                        if selectedSocketControlMode == .password {
                            SettingsCardDivider()
                            SettingsCardRow(
                                "Socket Password",
                                subtitle: hasSocketPasswordConfigured
                                    ? "Stored in login keychain."
                                    : "No password set. External clients will be blocked until one is configured."
                            ) {
                                HStack(spacing: 8) {
                                    SecureField("Password", text: $socketPasswordDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 170)
                                    Button(hasSocketPasswordConfigured ? "Change" : "Set") {
                                        saveSocketPassword()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    if hasSocketPasswordConfigured {
                                        Button("Clear") {
                                            clearSocketPassword()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }
                            if let message = socketPasswordStatusMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(socketPasswordStatusIsError ? Color.red : Color.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 8)
                            }
                        }
                        if selectedSocketControlMode == .allowAll {
                            SettingsCardDivider()
                            Text("Warning: Full open access makes the control socket world-readable/writable on this Mac and disables auth checks. Use only for local debugging.")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        SettingsCardNote("Overrides: TERMMESH_SOCKET_ENABLE, TERMMESH_SOCKET_MODE, and TERMMESH_SOCKET_PATH (set TERMMESH_ALLOW_SOCKET_OVERRIDE=1 for stable/nightly builds). Legacy CMUX_* prefixes also accepted.")
                    }

                    SettingsCard {
                        SettingsCardRow(
                            "Claude Code Integration",
                            subtitle: claudeCodeHooksEnabled
                                ? "Sidebar shows Claude session status and notifications."
                                : "Claude Code runs without Term-Mesh integration."
                        ) {
                            Toggle("", isOn: $claudeCodeHooksEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsClaudeCodeHooksToggle")
                        }

                        SettingsCardDivider()

                        SettingsCardNote("When enabled, Term-Mesh wraps the claude command to inject session tracking and notification hooks. Disable if you prefer to manage Claude Code hooks yourself.")
                    }

                    SettingsCard {
                        SettingsCardRow("Port Base", subtitle: "Starting port for TERMMESH_PORT env var.", controlWidth: pickerColumnWidth) {
                            TextField("", value: $termMeshPortBase, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardRow("Port Range Size", subtitle: "Number of ports per workspace.", controlWidth: pickerColumnWidth) {
                            TextField("", value: $termMeshPortRange, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardNote("Each workspace gets TERMMESH_PORT and TERMMESH_PORT_END env vars with a dedicated port range. New terminals inherit these values.")
                    }
                    }

                    if sectionVisible(["agent", "team"], rowKeywords: [
                        ["leader", "mode", "repl", "claude"],
                        ["model", "sonnet", "opus", "haiku"],
                        ["directory", "working", "path"]
                    ]) {
                    SettingsSectionHeader(title: "Agent Teams")
                    SettingsCard {
                        if settingsMatch("leader", "mode", "repl", "claude", "agent", "team") {
                        SettingsCardRow(
                            "Default Leader Mode",
                            subtitle: teamDefaultLeaderMode == "claude"
                                ? "Leader runs Claude automatically."
                                : "Leader provides a manual REPL console.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: $teamDefaultLeaderMode) {
                                Text("REPL (Manual)").tag("repl")
                                Text("Claude (Auto)").tag("claude")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        }

                        if settingsMatch("model", "sonnet", "opus", "haiku", "agent", "team") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Default Agent Model",
                            subtitle: "Model used for new agents when creating a team.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: $teamDefaultModel) {
                                Text("Sonnet").tag("sonnet")
                                Text("Opus").tag("opus")
                                Text("Haiku").tag("haiku")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        }

                        if settingsMatch("directory", "working", "path", "agent", "team") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Default Working Directory",
                            subtitle: teamDefaultWorkingDirectory.isEmpty
                                ? "Uses the current workspace directory."
                                : teamDefaultWorkingDirectory
                        ) {
                            HStack(spacing: 8) {
                                TextField("~/projects", text: $teamDefaultWorkingDirectory)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 170)
                                Button("Browse…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = true
                                    panel.canChooseFiles = false
                                    panel.allowsMultipleSelection = false
                                    if panel.runModal() == .OK, let url = panel.url {
                                        teamDefaultWorkingDirectory = url.path
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        }
                    }
                    }

                    if settingsMatch("cli", "path", "claude", "kiro", "codex", "gemini", "binary", "agent") {
                    SettingsSectionHeader(title: "Agent CLI Paths")
                    SettingsCard {
                        CLIPathRow(label: "Claude", cliKey: "claude", path: $cliPathClaude)
                        SettingsCardDivider()
                        CLIPathRow(label: "Kiro", cliKey: "kiro", path: $cliPathKiro)
                        SettingsCardDivider()
                        CLIPathRow(label: "Codex", cliKey: "codex", path: $cliPathCodex)
                        SettingsCardDivider()
                        CLIPathRow(label: "Gemini", cliKey: "gemini", path: $cliPathGemini)
                    }
                    SettingsCardNote("Leave empty to use auto-detected path. Custom paths take priority.")
                    }

                    if settingsMatch("worktrees", "worktree", "base directory", "cleanup", "auto") {
                    SettingsSectionHeader(title: "Worktrees")
                    SettingsCard {
                        SettingsCardRow("Base Directory", subtitle: "Where worktrees are created") {
                            HStack(spacing: 8) {
                                TextField("", text: Binding(
                                    get: { daemonService?.worktreeBaseDir ?? "" },
                                    set: { daemonService?.worktreeBaseDir = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)

                                Button("Reset") {
                                    UserDefaults.standard.removeObject(forKey: TermMeshDaemon.worktreeBaseDirKey)
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)

                                Button("Open") {
                                    let path = daemonService?.worktreeBaseDir ?? ""
                                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardRow("Auto-Cleanup on Quit", subtitle: "Remove stale worktrees when app closes") {
                            Toggle("", isOn: Binding(
                                get: { daemonService?.worktreeAutoCleanup ?? true },
                                set: { daemonService?.worktreeAutoCleanup = $0 }
                            ))
                            .toggleStyle(.switch)
                        }
                    }
                    }

                    if settingsMatch("dashboard", "http", "localhost", "port", "remote") {
                    SettingsSectionHeader(title: "Dashboard")
                    SettingsCard {
                        SettingsCardRow(
                            "HTTP Dashboard",
                            subtitle: dashboardEnabled
                                ? "Web dashboard at \(dashboardLocalhostOnly ? "localhost" : "0.0.0.0"):\(dashboardPort)"
                                    + (dashboardPassword.isEmpty ? "" : " 🔒")
                                : "Dashboard is disabled. Daemon runs without HTTP server."
                        ) {
                            Toggle("", isOn: $dashboardEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        if dashboardEnabled {
                            SettingsCardDivider()

                            SettingsCardRow(
                                "Bind Address",
                                subtitle: dashboardLocalhostOnly
                                    ? "Only accessible from this Mac (127.0.0.1)."
                                    : "⚠️ Accessible from any network interface (0.0.0.0). Set a password for security.",
                                controlWidth: pickerColumnWidth
                            ) {
                                Picker("", selection: $dashboardLocalhostOnly) {
                                    Text("localhost (127.0.0.1)").tag(true)
                                    Text("All interfaces (0.0.0.0)").tag(false)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }

                            SettingsCardDivider()

                            SettingsCardRow("Port", subtitle: "HTTP port for the dashboard.", controlWidth: pickerColumnWidth) {
                                TextField("", value: $dashboardPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                            }

                            SettingsCardDivider()

                            SettingsCardRow("Password", subtitle: "Require a password to access the dashboard. Leave empty to disable auth.", controlWidth: pickerColumnWidth) {
                                SecureField("Optional", text: $dashboardPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardNote("Changes take effect after restarting the daemon (quit and relaunch the app). The dashboard shows system metrics, team status, agents, and task boards.")
                    }
                    }

                    if settingsMatch("browser", "search", "engine", "theme", "link", "history", "http", "insecure", "suggestion") {
                    SettingsSectionHeader(title: "Browser")
                    SettingsCard {
                        SettingsCardRow(
                            "Default Search Engine",
                            subtitle: "Used by the browser address bar when input is not a URL.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: $browserSearchEngine) {
                                ForEach(BrowserSearchEngine.allCases) { engine in
                                    Text(engine.displayName).tag(engine.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        SettingsCardDivider()

                        SettingsCardRow("Show Search Suggestions") {
                            Toggle("", isOn: $browserSearchSuggestionsEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            "Browser Theme",
                            subtitle: selectedBrowserThemeMode == .system
                                ? "System follows app and macOS appearance."
                                : "\(selectedBrowserThemeMode.displayName) forces that color scheme for compatible pages.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: browserThemeModeSelection) {
                                ForEach(BrowserThemeMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            "Open Terminal Links in Term-Mesh Browser",
                            subtitle: "When off, links clicked in terminal output open in your default browser."
                        ) {
                            Toggle("", isOn: $openTerminalLinksInTermMeshBrowser)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            "Intercept open http(s) in Terminal",
                            subtitle: "When off, `open https://...` and `open http://...` always use your default browser."
                        ) {
                            Toggle("", isOn: $interceptTerminalOpenCommandInTermMeshBrowser)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        if openTerminalLinksInTermMeshBrowser || interceptTerminalOpenCommandInTermMeshBrowser {
                            SettingsCardDivider()

                            VStack(alignment: .leading, spacing: 6) {
                                SettingsCardRow(
                                    "Hosts to Open in Embedded Browser",
                                    subtitle: "Applies to terminal link clicks and intercepted `open https://...` calls. Only these hosts open in term-mesh. Others open in your default browser. One host or wildcard per line (for example: example.com, *.internal.example). Leave empty to open all hosts in term-mesh."
                                ) {
                                    EmptyView()
                                }

                                TextEditor(text: $browserHostWhitelist)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 60, maxHeight: 120)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                    )
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 12)
                            }
                        }

                        SettingsCardDivider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("HTTP Hosts Allowed in Embedded Browser")
                                .font(.system(size: 13, weight: .semibold))

                            Text("Controls which HTTP (non-HTTPS) hosts can open in Term-Mesh without a warning prompt. Defaults include localhost, 127.0.0.1, ::1, 0.0.0.0, and *.localtest.me.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $browserInsecureHTTPAllowlistDraft)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .frame(minHeight: 86)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                )
                                .accessibilityIdentifier("SettingsBrowserHTTPAllowlistField")

                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .center, spacing: 10) {
                                    Text("One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Spacer(minLength: 0)

                                    Button("Save") {
                                        saveBrowserInsecureHTTPAllowlist()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                                    .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    HStack {
                                        Spacer(minLength: 0)
                                        Button("Save") {
                                            saveBrowserInsecureHTTPAllowlist()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                                        .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsCardDivider()

                        SettingsCardRow("Browsing History", subtitle: browserHistorySubtitle) {
                            Button("Clear History…") {
                                showClearBrowserHistoryConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(browserHistoryEntryCount == 0)
                        }
                    }
                    }

                    if settingsMatch("ime", "input", "bar", "font", "height", "cjk") {
                    SettingsSectionHeader(title: "IME Input Bar")
                    SettingsCard {
                        SettingsCardRow("Font Size", subtitle: "Text size in the IME input bar (pt).", controlWidth: pickerColumnWidth) {
                            TextField("", value: $imeBarFontSize, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardRow("Bar Height", subtitle: "Height of the IME input bar (px).", controlWidth: pickerColumnWidth) {
                            TextField("", value: $imeBarHeight, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardNote("The IME input bar (Cmd+Shift+I) provides a native text field for CJK composition. Adjust font size and bar height to your preference.")
                    }
                    }

                    if settingsMatch("keyboard", "shortcut", "keybinding", "hotkey") {
                    SettingsSectionHeader(title: "Keyboard Shortcuts")
                    SettingsCard {
                        let actions = KeyboardShortcutSettings.Action.allCases
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            ShortcutSettingRow(action: action)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                            if index < actions.count - 1 {
                                SettingsCardDivider()
                            }
                        }
                    }
                    .id(shortcutResetToken)

                    Text("Click a shortcut value to record a new shortcut.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 2)
                    }

                    if settingsMatch("reset", "clear", "defaults") {
                    SettingsSectionHeader(title: "Reset")
                    SettingsCard {
                        HStack {
                            Spacer(minLength: 0)
                            Button("Reset All Settings") {
                                resetAllSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    }

                    if isSearching {
                        let anyVisible = sectionVisible(["app"], rowKeywords: [["theme"], ["workspace"], ["reorder"], ["session", "restore"], ["dock"], ["quit"], ["rename"], ["sidebar"]])
                            || settingsMatch("workspace", "color", "indicator", "palette", "custom")
                            || settingsMatch("automation", "socket", "claude", "port", "integration", "password")
                            || sectionVisible(["agent", "team"], rowKeywords: [["leader"], ["model"], ["directory"]])
                            || settingsMatch("browser", "search", "engine", "theme", "link", "history", "http", "insecure", "suggestion")
                            || settingsMatch("keyboard", "shortcut", "keybinding", "hotkey")
                            || settingsMatch("reset", "clear", "defaults")
                        if !anyVisible {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("No settings match \"\(settingsSearchQuery)\"")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, contentTopInset)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SettingsTopOffsetPreferenceKey.self,
                            value: proxy.frame(in: .named("SettingsScrollArea")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "SettingsScrollArea")
            .onPreferenceChange(SettingsTopOffsetPreferenceKey.self) { value in
                if topBlurBaselineOffset == nil {
                    topBlurBaselineOffset = value
                }
                topBlurOpacity = blurOpacity(forContentOffset: value)
            }

            ZStack(alignment: .top) {
                SettingsTitleLeadingInsetReader(inset: $settingsTitleLeadingInset)
                    .frame(width: 0, height: 0)

                AboutVisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow)
                    .mask(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.9),
                                Color.black.opacity(0.64),
                                Color.black.opacity(0.36),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.52)

                AboutVisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow)
                    .mask(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.98),
                                Color.black.opacity(0.78),
                                Color.black.opacity(0.42),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.14 + (topBlurOpacity * 0.86))

                HStack(spacing: 12) {
                    Text("Settings")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.92))
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("Search", text: $settingsSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .frame(width: 140)
                        if !settingsSearchQuery.isEmpty {
                            Button(action: { settingsSearchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                            )
                    )
                }
                .padding(.leading, settingsTitleLeadingInset)
                .padding(.trailing, 20)
                .padding(.top, 12)
            }
                .frame(height: 62)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
                .overlay(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.07))
                        .frame(height: 1),
                    alignment: .bottom
                )
                .allowsHitTesting(true)
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .toggleStyle(.switch)
        .onAppear {
            browserHistory?.loadIfNeeded()
            browserThemeMode = BrowserThemeSettings.mode(defaults: .standard).rawValue
            browserHistoryEntryCount = browserHistory?.entries.count ?? 0
            browserInsecureHTTPAllowlistDraft = browserInsecureHTTPAllowlist
            reloadWorkspaceTabColorSettings()
        }
        .onChange(of: browserInsecureHTTPAllowlist) { oldValue, newValue in
            // Keep draft in sync with external changes unless the user has local unsaved edits.
            if browserInsecureHTTPAllowlistDraft == oldValue {
                browserInsecureHTTPAllowlistDraft = newValue
            }
        }
        .onReceive(BrowserHistoryStore.shared.$entries) { entries in
            browserHistoryEntryCount = entries.count
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadWorkspaceTabColorSettings()
        }
        .confirmationDialog(
            "Clear browser history?",
            isPresented: $showClearBrowserHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                browserHistory?.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes visited-page suggestions from the browser omnibar.")
        }
        .confirmationDialog(
            "Enable full open access?",
            isPresented: $showOpenAccessConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable Full Open Access", role: .destructive) {
                socketControlMode = (pendingOpenAccessMode ?? .allowAll).rawValue
                pendingOpenAccessMode = nil
            }
            Button("Cancel", role: .cancel) {
                pendingOpenAccessMode = nil
            }
        } message: {
            Text("This disables ancestry and password checks and opens the socket to all local users. Only enable when you understand the risk.")
        }
    }

    private func resetAllSettings() {
        appearanceMode = AppearanceSettings.defaultMode.rawValue
        socketControlMode = SocketControlSettings.defaultMode.rawValue
        claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
        browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
        browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
        browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
        openTerminalLinksInTermMeshBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInTermMeshBrowser
        interceptTerminalOpenCommandInTermMeshBrowser = BrowserLinkOpenSettings.defaultInterceptTerminalOpenCommandInTermMeshBrowser
        browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
        browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
        browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
        notificationDockBadgeEnabled = NotificationBadgeSettings.defaultDockBadgeEnabled
        warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
        commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
        newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
        workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
        sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
        sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
        showOpenAccessConfirmation = false
        pendingOpenAccessMode = nil
        socketPasswordDraft = ""
        socketPasswordStatusMessage = nil
        socketPasswordStatusIsError = false
        imeBarFontSize = IMEInputBarSettings.defaultFontSize
        imeBarHeight = IMEInputBarSettings.defaultHeight
        KeyboardShortcutSettings.resetAll()
        WorkspaceTabColorSettings.reset()
        reloadWorkspaceTabColorSettings()
        shortcutResetToken = UUID()
    }

    private func defaultTabColorBinding(for name: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = WorkspaceTabColorSettings.defaultColorHex(named: name)
                return Color(nsColor: NSColor(hex: hex) ?? .systemBlue)
            },
            set: { newValue in
                let hex = NSColor(newValue).hexString()
                WorkspaceTabColorSettings.setDefaultColor(named: name, hex: hex)
                reloadWorkspaceTabColorSettings()
            }
        )
    }

    private func baseTabColorHex(for name: String) -> String {
        WorkspaceTabColorSettings.defaultPalette
            .first(where: { $0.name == name })?
            .hex ?? "#1565C0"
    }

    private func removeWorkspaceCustomColor(_ hex: String) {
        WorkspaceTabColorSettings.removeCustomColor(hex)
        reloadWorkspaceTabColorSettings()
    }

    private func resetWorkspaceTabColors() {
        WorkspaceTabColorSettings.reset()
        reloadWorkspaceTabColorSettings()
    }

    private func reloadWorkspaceTabColorSettings() {
        workspaceTabDefaultEntries = WorkspaceTabColorSettings.defaultPaletteWithOverrides()
        workspaceTabCustomColors = WorkspaceTabColorSettings.customColors()
    }

    private func saveBrowserInsecureHTTPAllowlist() {
        browserInsecureHTTPAllowlist = browserInsecureHTTPAllowlistDraft
    }
}

private struct SettingsTopOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SettingsTitleLeadingInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let maxX = buttons
                .compactMap { window.standardWindowButton($0)?.frame.maxX }
                .max() ?? 78
            let nextInset = maxX + 14
            if abs(nextInset - inset) > 0.5 {
                inset = nextInset
            }
        }
    }
}

private struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, -2)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: NSColor.controlBackgroundColor).opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
    }
}

private struct SettingsCardRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat?
    @ViewBuilder let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let controlWidth {
                    trailing
                        .frame(width: controlWidth, alignment: .trailing)
                } else {
                    trailing
                }
            }
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: NSColor.separatorColor).opacity(0.5))
            .frame(height: 1)
    }
}

private struct CLIPathRow: View {
    let label: String
    let cliKey: String
    @Binding var path: String
    @State private var autoDetected: String = ""

    var body: some View {
        let resolvedPath = path.isEmpty ? autoDetected : path
        let exists = !resolvedPath.isEmpty && FileManager.default.fileExists(atPath: resolvedPath)

        SettingsCardRow(
            label,
            subtitle: resolvedPath.isEmpty
                ? "Not found"
                : resolvedPath
        ) {
            HStack(spacing: 6) {
                Circle()
                    .fill(resolvedPath.isEmpty ? Color.red : (exists ? Color.green : Color.red))
                    .frame(width: 8, height: 8)
                    .help(resolvedPath.isEmpty ? "Not found" : (exists ? "Found" : "File not found"))
                TextField("auto-detect", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = false
                    panel.treatsFilePackagesAsDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        path = url.path
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .onAppear { autoDetected = CLIPathSettings.autoDetect(cli: cliKey) }
    }
}

enum CLIPathSettings {
    static func resolvedPath(for cli: String, defaults: UserDefaults = .standard) -> String? {
        let key = "cliPath.\(cli)"
        let custom = defaults.string(forKey: key) ?? ""
        if !custom.isEmpty && FileManager.default.fileExists(atPath: custom) {
            return custom
        }
        let detected = autoDetect(cli: cli)
        return detected.isEmpty ? nil : detected
    }

    static func autoDetect(cli: String) -> String {
        let home = NSHomeDirectory()
        let candidates: [String]
        switch cli {
        case "claude":
            candidates = [
                (home as NSString).appendingPathComponent(".local/bin/claude"),
            ]
        case "kiro":
            candidates = [
                (home as NSString).appendingPathComponent(".local/bin/kiro-cli"),
                "/usr/local/bin/kiro-cli",
                "/opt/homebrew/bin/kiro-cli",
            ]
        case "codex":
            candidates = [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                (home as NSString).appendingPathComponent(".local/bin/codex"),
                (home as NSString).appendingPathComponent(".cargo/bin/codex"),
            ]
        case "gemini":
            candidates = [
                "/opt/homebrew/bin/gemini",
                "/usr/local/bin/gemini",
                (home as NSString).appendingPathComponent(".local/bin/gemini"),
            ]
        default:
            candidates = []
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }
}

private struct SettingsCardNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutSettingRow: View {
    let action: KeyboardShortcutSettings.Action
    @State private var shortcut: StoredShortcut

    init(action: KeyboardShortcutSettings.Action) {
        self.action = action
        _shortcut = State(initialValue: KeyboardShortcutSettings.shortcut(for: action))
    }

    var body: some View {
        KeyboardShortcutRecorder(label: action.label, shortcut: $shortcut)
            .onChange(of: shortcut) { newValue in
                KeyboardShortcutSettings.setShortcut(newValue, for: action)
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                let latest = KeyboardShortcutSettings.shortcut(for: action)
                if latest != shortcut {
                    shortcut = latest
                }
            }
    }
}

struct SettingsRootView: View {
    var body: some View {
        SettingsView()
            .background(WindowAccessor { window in
                configureSettingsWindow(window)
            })
    }

    private func configureSettingsWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("term-mesh.settings")
        applyCurrentSettingsWindowStyle(to: window)

        let accessories = window.titlebarAccessoryViewControllers
        for index in accessories.indices.reversed() {
            guard let identifier = accessories[index].view.identifier?.rawValue else { continue }
            guard identifier.hasPrefix("term-mesh.") else { continue }
            window.removeTitlebarAccessoryViewController(at: index)
        }
        AppDelegate.shared?.applyWindowDecorations(to: window)
    }

    private func applyCurrentSettingsWindowStyle(to window: NSWindow) {
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
    }
}
