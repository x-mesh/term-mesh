import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case app = "app"
    case workspaceColors = "workspaceColors"
    case automation = "automation"
    case agentTeams = "agentTeams"
    case agentCLIPaths = "agentCLIPaths"
    case worktrees = "worktrees"
    case dashboard = "dashboard"
    case services = "services"
    case browser = "browser"
    case imeInputBar = "imeInputBar"
    case keyboardShortcuts = "keyboardShortcuts"
    case reset = "reset"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "App"
        case .workspaceColors: return "Workspace Colors"
        case .automation: return "Automation"
        case .agentTeams: return "Agent Teams"
        case .agentCLIPaths: return "Agent CLI Paths"
        case .worktrees: return "Worktrees"
        case .dashboard: return "Dashboard"
        case .services: return "Services"
        case .browser: return "Browser"
        case .imeInputBar: return "IME Input Bar"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .reset: return "Reset"
        }
    }

    var icon: String {
        switch self {
        case .app: return "gear"
        case .workspaceColors: return "paintpalette"
        case .automation: return "bolt.horizontal"
        case .agentTeams: return "person.3"
        case .agentCLIPaths: return "terminal"
        case .worktrees: return "arrow.triangle.branch"
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .services: return "stethoscope"
        case .browser: return "globe"
        case .imeInputBar: return "keyboard"
        case .keyboardShortcuts: return "command"
        case .reset: return "arrow.counterclockwise"
        }
    }

    var category: SettingsSectionCategory {
        switch self {
        case .app, .workspaceColors: return .general
        case .automation, .agentTeams, .agentCLIPaths, .worktrees: return .agents
        case .dashboard, .services: return .network
        case .browser: return .browser
        case .imeInputBar, .keyboardShortcuts: return .input
        case .reset: return .system
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .app: return ["app", "theme", "appearance", "dark", "light", "workspace", "placement", "session", "restore", "dock", "badge", "quit", "warn", "rename", "sidebar", "branch", "reorder", "notification"]
        case .workspaceColors: return ["workspace", "color", "indicator", "palette", "custom"]
        case .automation: return ["automation", "socket", "claude", "port", "integration", "password"]
        case .agentTeams: return ["agent", "team", "leader", "model", "directory", "rendering", "interval", "refresh"]
        case .agentCLIPaths: return ["cli", "path", "claude", "kiro", "codex", "gemini", "binary", "agent"]
        case .worktrees: return ["worktrees", "worktree", "base directory", "cleanup", "auto"]
        case .dashboard: return ["dashboard", "http", "localhost", "port", "remote"]
        case .services: return ["services", "daemon", "doctor", "status", "restart", "subsystem", "log", "shell", "integration", "health"]
        case .browser: return ["browser", "search", "engine", "theme", "link", "history", "http", "insecure", "suggestion"]
        case .imeInputBar: return ["ime", "input", "bar", "font", "height", "cjk"]
        case .keyboardShortcuts: return ["keyboard", "shortcut", "keybinding", "hotkey"]
        case .reset: return ["reset", "clear", "defaults"]
        }
    }
}

enum SettingsSectionCategory: String {
    case general = "General"
    case agents = "Agents"
    case network = "Network"
    case browser = "Browser"
    case input = "Input"
    case system = "System"
}

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
    @AppStorage("agentRenderingInterval") private var agentRenderingInterval = 3
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
    @State private var daemonStatusInfo: TermMeshDaemon.DaemonStatus?
    @State private var isDaemonRestarting = false
    @State private var daemonLogTail: AttributedString?
    @State private var shellHealthEntries: [ShellHealthEntry] = []
    @State private var selectedSection: SettingsSection = .app

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

    // MARK: - Sidebar Filtering

    /// Sections that match the current search query.
    private var visibleSections: [SettingsSection] {
        guard isSearching else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { sectionMatchesSearch($0) }
    }

    private func sectionMatchesSearch(_ section: SettingsSection) -> Bool {
        let q = normalizedSearchQuery
        guard !q.isEmpty else { return true }
        let keywords = section.searchKeywords
        return keywords.contains { $0.lowercased().contains(q) }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // --- Sidebar ---
            settingsSidebar
                .frame(width: 180)

            Divider()

            // --- Content ---
            ZStack(alignment: .top) {
                settingsContentPanel
                settingsTopBar
            }
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
        .onChange(of: settingsSearchQuery) { _, _ in
            // Auto-select first matching section when searching
            if isSearching, let first = visibleSections.first, !visibleSections.contains(selectedSection) {
                selectedSection = first
            }
        }
        .onChange(of: browserInsecureHTTPAllowlist) { oldValue, newValue in
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

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field in sidebar
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search", text: $settingsSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !settingsSearchQuery.isEmpty {
                    Button(action: { settingsSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 52)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let sections = visibleSections
                    var lastCategory: SettingsSectionCategory?

                    ForEach(sections) { section in
                        let showCategoryHeader = section.category != lastCategory
                        let _ = { lastCategory = section.category }()

                        if showCategoryHeader, section.category != .system {
                            if section != sections.first {
                                Spacer().frame(height: 8)
                            }
                            Text(section.category.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.7))
                                .textCase(.uppercase)
                                .padding(.leading, 16)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                        }

                        Button {
                            selectedSection = section
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: section.icon)
                                    .font(.system(size: 11))
                                    .frame(width: 16, alignment: .center)
                                    .foregroundColor(selectedSection == section ? .white : .secondary)
                                Text(section.title)
                                    .font(.system(size: 12))
                                    .foregroundColor(selectedSection == section ? .white : .primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectedSection == section ? Color.accentColor : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Top Bar

    private var settingsTopBar: some View {
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
                Text(selectedSection.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.92))
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .padding(.top, 12)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Content Panel

    private var settingsContentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionContent(for: selectedSection)

                if isSearching && visibleSections.isEmpty {
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
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 52)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsTopOffsetPreferenceKey.self,
                        value: proxy.frame(in: .named("SettingsContentArea")).minY
                    )
                }
            )
        }
        .coordinateSpace(name: "SettingsContentArea")
        .onPreferenceChange(SettingsTopOffsetPreferenceKey.self) { value in
            if topBlurBaselineOffset == nil {
                topBlurBaselineOffset = value
            }
            topBlurOpacity = blurOpacity(forContentOffset: value)
        }
    }

    // MARK: - Section Content Router

    @ViewBuilder
    private func sectionContent(for section: SettingsSection) -> some View {
        switch section {
        case .app:
            sectionApp
        case .workspaceColors:
            sectionWorkspaceColors
        case .automation:
            sectionAutomation
        case .agentTeams:
            sectionAgentTeams
        case .agentCLIPaths:
            sectionAgentCLIPaths
        case .worktrees:
            sectionWorktrees
        case .dashboard:
            sectionDashboard
        case .services:
            sectionServices
        case .browser:
            sectionBrowser
        case .imeInputBar:
            sectionIMEInputBar
        case .keyboardShortcuts:
            sectionKeyboardShortcuts
        case .reset:
            sectionReset
        }
    }

    // MARK: - Section: App

    @ViewBuilder
    private var sectionApp: some View {
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

    // MARK: - Section: Workspace Colors

    @ViewBuilder
    private var sectionWorkspaceColors: some View {
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

    // MARK: - Section: Automation

    @ViewBuilder
    private var sectionAutomation: some View {
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
                            TextField("", value: $termMeshPortBase, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardRow("Port Range Size", subtitle: "Number of ports per workspace.", controlWidth: pickerColumnWidth) {
                            TextField("", value: $termMeshPortRange, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardNote("Each workspace gets TERMMESH_PORT and TERMMESH_PORT_END env vars with a dedicated port range. New terminals inherit these values.")
        }
    }

    // MARK: - Section: Agent Teams

    @ViewBuilder
    private var sectionAgentTeams: some View {
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

                        if settingsMatch("rendering", "interval", "agent", "refresh", "pane") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Agent Rendering Interval",
                            subtitle: "How often to refresh agent panes when rendering is paused.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: $agentRenderingInterval) {
                                Text("1s").tag(1)
                                Text("3s").tag(3)
                                Text("5s").tag(5)
                                Text("10s").tag(10)
                                Text("15s").tag(15)
                                Text("30s").tag(30)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: agentRenderingInterval) { _ in
                                TeamOrchestrator.shared.updatePeriodicRenderInterval()
                            }
                        }
                        }
        }
    }

    // MARK: - Section: Agent CLI Paths

    @ViewBuilder
    private var sectionAgentCLIPaths: some View {
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

    // MARK: - Section: Worktrees

    @ViewBuilder
    private var sectionWorktrees: some View {
        SettingsCard {
                        SettingsCardRow("Base Directory", subtitle: "Where worktrees are created") {
                            HStack(spacing: 8) {
                                TextField("", text: Binding(
                                    get: { daemonService?.worktreeBaseDir ?? TermMeshDaemon.defaultWorktreeBaseDir },
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
                                    let path = daemonService?.worktreeBaseDir ?? TermMeshDaemon.defaultWorktreeBaseDir
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

        WorktreeManagerSection(baseDir: daemonService?.worktreeBaseDir ?? TermMeshDaemon.defaultWorktreeBaseDir)
    }

    // MARK: - Section: Dashboard

    @ViewBuilder
    private var sectionDashboard: some View {
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
                                TextField("", value: $dashboardPort, format: .number.grouping(.never))
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

    // MARK: - Section: Services

    @ViewBuilder
    private var sectionServices: some View {
        SettingsCard {
                        // -- App variant & identity --
                        if let status = daemonStatusInfo {
                            SettingsCardRow(
                                "App Variant",
                                subtitle: "\(status.bundleIdentifier)"
                            ) {
                                Text(status.appVariant)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            SettingsCardDivider()
                        }

                        // -- Daemon connection status row --
                        SettingsCardRow(
                            "Daemon (term-meshd)",
                            subtitle: daemonStatusSubtitle
                        ) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(daemonStatusInfo?.connected == true ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(daemonStatusInfo?.connected == true ? "Running" : "Stopped")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }

                        SettingsCardDivider()

                        // -- Socket & Binary paths (always visible) --
                        if let status = daemonStatusInfo {
                            SettingsCardRow(
                                "Socket",
                                subtitle: status.socketPath
                            ) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(status.socketExists ? Color.green : Color.red)
                                        .frame(width: 7, height: 7)
                                    Text(status.socketExists ? "Exists" : "Missing")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                "Binary",
                                subtitle: status.binaryPath ?? "(not found)"
                            ) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(status.binaryExists ? Color.green : Color.red)
                                        .frame(width: 7, height: 7)
                                    if status.binaryExists, let binPath = status.binaryPath {
                                        Button {
                                            NSWorkspace.shared.selectFile(binPath, inFileViewerRootedAtPath: "")
                                        } label: {
                                            Image(systemName: "folder")
                                                .font(.system(size: 11))
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Reveal in Finder")
                                    } else {
                                        Text("Missing")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.red)
                                    }
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                "Log",
                                subtitle: status.logPath
                            ) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(status.logExists ? Color.green : Color.gray)
                                        .frame(width: 7, height: 7)
                                    Text(status.logExists ? "Exists" : "No log")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if let status = daemonStatusInfo, status.connected {
                            SettingsCardDivider()

                            // -- PID & Uptime --
                            if let pid = status.pid {
                                SettingsCardRow("PID") {
                                    Text(verbatim: "\(pid)")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                                SettingsCardDivider()
                            }

                            if let uptime = status.uptimeSecs {
                                SettingsCardRow("Uptime") {
                                    Text(formatUptime(uptime))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                SettingsCardDivider()
                            }

                            // -- Subsystem rows --
                            ForEach(status.subsystems) { sub in
                                SettingsCardRow(
                                    sub.name,
                                    subtitle: sub.detail
                                ) {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(sub.status == "running" ? Color.green : (sub.status == "disabled" ? Color.gray : Color.orange))
                                            .frame(width: 7, height: 7)
                                        Text(sub.status.capitalized)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                SettingsCardDivider()
                            }
                        }

                        // -- Action buttons --
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)

                            if daemonStatusInfo?.connected == true {
                                Button {
                                    isDaemonRestarting = true
                                    resolvedDaemon?.restartDaemon {
                                        refreshDaemonStatus()
                                        isDaemonRestarting = false
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        if isDaemonRestarting {
                                            ProgressView()
                                                .controlSize(.small)
                                                .scaleEffect(0.7)
                                        }
                                        Text("Restart")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isDaemonRestarting)

                                Button("Stop") {
                                    resolvedDaemon?.stopDaemon()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        refreshDaemonStatus()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Button("Start") {
                                    resolvedDaemon?.startDaemon()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        refreshDaemonStatus()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Button("Refresh") {
                                refreshDaemonStatus()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsCardDivider()

                        // -- Log viewer --
                        SettingsCardRow("Recent Log") {
                            Button("View Log") {
                                loadDaemonLogTail()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if let logContent = daemonLogTail {
                            ScrollView(.vertical) {
                                Text(logContent)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(maxHeight: 200)
                            .background(Color.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                        }

                        SettingsCardDivider()

                        // -- Copy diagnostics --
                        HStack {
                            Spacer(minLength: 0)
                            Button {
                                copyDiagnostics()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 10))
                                    Text("Copy Diagnostics")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Copy system diagnostics to clipboard for bug reports")
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
        }
        .onAppear {
            refreshDaemonStatus()
            refreshShellIntegrationHealth()
        }

        shellIntegrationHealthCard
    }

    // MARK: - Section: Browser

    @ViewBuilder
    private var sectionBrowser: some View {
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

    // MARK: - Section: IME Input Bar

    @ViewBuilder
    private var sectionIMEInputBar: some View {
        SettingsCard {
                        SettingsCardRow("Font Size", subtitle: "Text size in the IME input bar (pt).", controlWidth: pickerColumnWidth) {
                            TextField("", value: $imeBarFontSize, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardRow("Bar Height", subtitle: "Height of the IME input bar (px).", controlWidth: pickerColumnWidth) {
                            TextField("", value: $imeBarHeight, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardNote("The IME input bar (Cmd+Shift+I) provides a native text field for CJK composition. Adjust font size and bar height to your preference.")
        }
    }

    // MARK: - Section: Keyboard Shortcuts

    @ViewBuilder
    private var sectionKeyboardShortcuts: some View {
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

    // MARK: - Section: Reset

    @ViewBuilder
    private var sectionReset: some View {
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

    // MARK: - Services / Doctor

    private var daemonStatusSubtitle: String {
        guard let status = daemonStatusInfo else { return "Checking..." }
        if !status.connected {
            if !status.binaryExists { return "Binary not found. Build the daemon first." }
            if !status.socketExists { return "Socket missing. Daemon may not be running." }
            return "Not responding on \(status.socketPath)"
        }
        if let pid = status.pid, let uptime = status.uptimeSecs {
            return "PID \(pid) — up \(formatUptime(uptime))"
        }
        return "Connected"
    }

    private var resolvedDaemon: (any DaemonService)? {
        daemonService ?? TermMeshDaemon.shared
    }

    private func refreshDaemonStatus() {
        let daemon = resolvedDaemon
        DispatchQueue.global(qos: .userInitiated).async {
            let status = daemon?.daemonStatus()
            DispatchQueue.main.async { daemonStatusInfo = status }
        }
    }

    private func loadDaemonLogTail() {
        let logPath = "/tmp/term-meshd.log"
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = FileManager.default.contents(atPath: logPath),
                  let content = String(data: data, encoding: .utf8) else {
                let fallback = AttributedString("(no log file found)")
                DispatchQueue.main.async { daemonLogTail = fallback }
                return
            }
            let lines = content.components(separatedBy: .newlines)
            let tail = lines.suffix(50).joined(separator: "\n")
            let attributed = parseAnsiLog(tail)
            DispatchQueue.main.async { daemonLogTail = attributed }
        }
    }

    /// Parse ANSI escape codes into an AttributedString with colors.
    private func parseAnsiLog(_ raw: String) -> AttributedString {
        var result = AttributedString()
        let defaultColor = Color.gray

        // ANSI SGR code → Color mapping
        func colorForCode(_ code: Int) -> Color? {
            switch code {
            case 0: return nil                // reset
            case 2: return nil                // dim — handled via opacity
            case 22: return nil               // reset dim
            case 30: return .black
            case 31: return .red
            case 32: return .green
            case 33: return .yellow
            case 34: return .blue
            case 35: return .purple
            case 36: return .cyan
            case 37: return .white
            case 90: return .gray
            case 91: return Color(.systemRed)
            case 92: return Color(.systemGreen)
            case 93: return Color(.systemYellow)
            case 94: return Color(.systemBlue)
            case 95: return Color(.systemPurple)
            case 96: return Color(.systemTeal)
            default: return nil
            }
        }

        var currentColor: Color = defaultColor
        var isDim = false

        // Split by ESC[ sequences: \x1b[ or \033[
        let pattern = "\u{1b}\\[([0-9;]*)m"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AttributedString(raw)
        }

        let nsString = raw as NSString
        var lastEnd = 0

        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            // Append text before this escape sequence
            if match.range.location > lastEnd {
                let textRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
                let text = nsString.substring(with: textRange)
                var segment = AttributedString(text)
                segment.foregroundColor = isDim ? currentColor.opacity(0.5) : currentColor
                result.append(segment)
            }

            // Parse SGR codes
            let codesStr = nsString.substring(with: match.range(at: 1))
            let codes = codesStr.split(separator: ";").compactMap { Int($0) }
            if codes.isEmpty {
                // bare ESC[m is reset
                currentColor = defaultColor
                isDim = false
            }
            for code in codes {
                if code == 0 {
                    currentColor = defaultColor
                    isDim = false
                } else if code == 2 {
                    isDim = true
                } else if code == 22 {
                    isDim = false
                } else if let color = colorForCode(code) {
                    currentColor = color
                }
            }

            lastEnd = match.range.location + match.range.length
        }

        // Append remaining text
        if lastEnd < nsString.length {
            let text = nsString.substring(from: lastEnd)
            var segment = AttributedString(text)
            segment.foregroundColor = isDim ? currentColor.opacity(0.5) : currentColor
            result.append(segment)
        }

        return result
    }

    private func formatUptime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: - Shell Integration Health

    @ViewBuilder
    private var shellIntegrationHealthCard: some View {
        SettingsCard {
            SettingsCardRow("Shell Integration", subtitle: shellHealthSummary) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(shellHealthOverallColor)
                        .frame(width: 8, height: 8)
                    Text(shellHealthOverallLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if !shellHealthEntries.isEmpty {
                ForEach(shellHealthEntries) { entry in
                    SettingsCardDivider()

                    SettingsCardRow(
                        "\(entry.workspaceTitle) / \(entry.panelTitle)",
                        subtitle: shellHealthDetail(entry)
                    ) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(entry.health.status.settingsColor)
                                .frame(width: 7, height: 7)
                            Text(entry.health.status.label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            SettingsCardDivider()

            HStack {
                Spacer(minLength: 0)
                Button("Refresh") {
                    refreshShellIntegrationHealth()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var shellHealthSummary: String {
        let total = shellHealthEntries.count
        if total == 0 { return "No terminal panels detected" }
        return "\(total) terminal panel\(total == 1 ? "" : "s") across all workspaces"
    }

    private var shellHealthOverallColor: Color {
        if shellHealthEntries.isEmpty { return .gray }
        let statuses = shellHealthEntries.map { $0.health.status }
        if statuses.contains(.notLoaded) { return .red }
        if statuses.contains(.partial) || statuses.contains(.stale) { return .orange }
        if statuses.allSatisfy({ $0 == .starting }) { return .gray }
        return .green
    }

    private var shellHealthOverallLabel: String {
        if shellHealthEntries.isEmpty { return "No panels" }
        let statuses = shellHealthEntries.map { $0.health.status }
        let notLoadedCount = statuses.filter { $0 == .notLoaded }.count
        if notLoadedCount > 0 { return "\(notLoadedCount) not loaded" }
        let problemCount = statuses.filter { $0 == .partial || $0 == .stale }.count
        if problemCount > 0 { return "\(problemCount) degraded" }
        if statuses.allSatisfy({ $0 == .starting }) { return "Starting..." }
        return "All healthy"
    }

    private func shellHealthDetail(_ entry: ShellHealthEntry) -> String {
        let h = entry.health
        let pwdAge: String
        if let lastPwd = h.lastReportPwd {
            let secs = Int(Date().timeIntervalSince(lastPwd))
            pwdAge = "\(secs)s ago"
        } else {
            pwdAge = "never"
        }
        return "pwd: \(h.reportPwdCount), last \(pwdAge) | tty: \(h.reportTtyCount > 0 ? "yes" : "no") | git: \(h.reportGitBranchCount > 0 ? "yes" : "no")"
    }

    private func refreshShellIntegrationHealth() {
        guard let appDelegate = AppDelegate.shared else {
            shellHealthEntries = []
            return
        }
        var entries: [ShellHealthEntry] = []
        for context in appDelegate.mainWindowContexts.values {
            let tabManager = context.tabManager
            for workspace in tabManager.tabs {
                for panelId in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                    guard workspace.panels[panelId] is TerminalPanel else { continue }
                    let health = workspace.shellIntegrationHealth[panelId]
                        ?? ShellIntegrationHealth(createdAt: workspace.createdAt)
                    let panelTitle = workspace.panelTitles[panelId]
                        ?? String(panelId.uuidString.prefix(8))
                    let title = workspace.customTitle ?? workspace.title
                    entries.append(ShellHealthEntry(
                        id: panelId,
                        workspaceTitle: title,
                        panelTitle: panelTitle,
                        health: health
                    ))
                }
            }
        }
        shellHealthEntries = entries
    }

    private func copyDiagnostics() {
        var lines: [String] = []
        lines.append("term-mesh diagnostics")
        lines.append("=====================")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("App: \(appVersion) (\(buildNumber))")

        if let status = daemonStatusInfo {
            lines.append("Variant: \(status.appVariant)")
            lines.append("Bundle ID: \(status.bundleIdentifier)")
            lines.append("")
            lines.append("Daemon: \(status.connected ? "connected" : "not connected")")
            if let pid = status.pid { lines.append("PID: \(pid)") }
            if let uptime = status.uptimeSecs { lines.append("Uptime: \(formatUptime(uptime))") }
            lines.append("Binary: \(status.binaryPath ?? "(not found)") [\(status.binaryExists ? "exists" : "MISSING")]")
            lines.append("Socket: \(status.socketPath) [\(status.socketExists ? "exists" : "MISSING")]")
            lines.append("Log: \(status.logPath) [\(status.logExists ? "exists" : "MISSING")]")

            if !status.subsystems.isEmpty {
                lines.append("")
                lines.append("Subsystems:")
                for sub in status.subsystems {
                    var line = "  \(sub.name): \(sub.status)"
                    if let d = sub.detail { line += " (\(d))" }
                    lines.append(line)
                }
            }
        } else {
            lines.append("Daemon: status not available")
        }

        // Shell Integration Health
        lines.append("")
        lines.append("Shell Integration:")
        if let appDelegate = AppDelegate.shared {
            var panelIndex = 0
            for context in appDelegate.mainWindowContexts.values {
                for workspace in context.tabManager.tabs {
                    for panelId in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                        guard workspace.panels[panelId] is TerminalPanel else { continue }
                        let health = workspace.shellIntegrationHealth[panelId]
                            ?? ShellIntegrationHealth(createdAt: workspace.createdAt)
                        let now = Date()
                        let pwdAge: String
                        if let lastPwd = health.lastReportPwd {
                            pwdAge = "last \(Int(now.timeIntervalSince(lastPwd)))s ago"
                        } else {
                            pwdAge = "never"
                        }
                        let age = Int(now.timeIntervalSince(health.createdAt))
                        let title = workspace.customTitle ?? workspace.title
                        let panelLabel = workspace.panelTitles[panelId] ?? String(panelId.uuidString.prefix(8))
                        panelIndex += 1
                        lines.append("  \(title)/\(panelLabel): \(health.status.rawValue) (pwd: \(health.reportPwdCount) msgs, \(pwdAge), tty: \(health.reportTtyCount > 0 ? "yes" : "no"), git: \(health.reportGitBranchCount > 0 ? "yes" : "no"), age: \(age)s)")
                    }
                }
            }
            if panelIndex == 0 {
                lines.append("  (no terminal panels)")
            }
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

extension IntegrationStatus {
    var settingsColor: Color {
        switch self {
        case .starting: return .gray
        case .healthy: return .green
        case .stale, .partial: return .orange
        case .notLoaded: return .red
        }
    }
}

private struct ShellHealthEntry: Identifiable {
    let id: UUID
    let workspaceTitle: String
    let panelTitle: String
    let health: ShellIntegrationHealth
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

// MARK: - Worktree Manager Section

private struct WorktreeManagerSection: View {
    let baseDir: String

    struct FoundWorktree: Identifiable {
        var id: String { path }
        let path: String
        let name: String
        let branch: String
        let repoName: String
    }

    @State private var worktrees: [FoundWorktree] = []
    @State private var isScanning = false
    @State private var hasScanResult = false
    @State private var confirmDelete: FoundWorktree? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Worktrees on Disk")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(isScanning ? "Scanning…" : "Refresh") {
                    Task { await scan() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isScanning)
            }
            .padding(.horizontal, 2)

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning \(baseDir)…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else if hasScanResult {
                if worktrees.isEmpty {
                    Text("No worktrees found.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    SettingsCard {
                        ForEach(Array(worktrees.enumerated()), id: \.element.id) { index, wt in
                            if index > 0 { SettingsCardDivider() }
                            WorktreeRow(worktree: wt) {
                                confirmDelete = wt
                            }
                        }
                    }
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 2)
            }
        }
        .confirmationDialog(
            "Delete Worktree?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let wt = confirmDelete {
                Button("Delete \"\(wt.name)\"", role: .destructive) { forceDelete(wt) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let wt = confirmDelete {
                Text("This will permanently remove the directory:\n\(wt.path)\n\nNote: Run `git worktree prune` in the parent repo to clean up any remaining git metadata.")
            }
        }
        // Re-scan when baseDir changes (e.g. user edits the base directory setting)
        .task(id: baseDir) { await scan() }
    }

    @MainActor
    private func scan() async {
        isScanning = true
        errorMessage = nil
        let dir = baseDir.isEmpty ? TermMeshDaemon.defaultWorktreeBaseDir : baseDir
        let found = await Task.detached(priority: .userInitiated) {
            scanWorktreeDirectory(dir)
        }.value
        worktrees = found
        hasScanResult = true
        isScanning = false
    }

    /// Delete a worktree directory off-main to avoid UI blocking on large trees.
    /// Note: This only removes the filesystem directory. If the parent repo still
    /// has a .git/worktrees/<name> reference, run `git worktree prune` in the
    /// parent repo to clean up stale metadata.
    private func forceDelete(_ wt: FoundWorktree) {
        confirmDelete = nil
        let path = wt.path
        let wtId = wt.id
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.removeItem(atPath: path)
                await MainActor.run {
                    worktrees.removeAll { $0.id == wtId }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to delete: \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct WorktreeRow: View {
    let worktree: WorktreeManagerSection.FoundWorktree
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(worktree.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Text(worktree.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("branch:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(worktree.branch)
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Open in Finder")

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .help("Delete worktree directory")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private func scanWorktreeDirectory(_ baseDir: String) -> [WorktreeManagerSection.FoundWorktree] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: baseDir, isDirectory: &isDir), isDir.boolValue else { return [] }

    var results: [WorktreeManagerSection.FoundWorktree] = []
    guard let repoDirs = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }

    for repoName in repoDirs.sorted() {
        let repoDir = (baseDir as NSString).appendingPathComponent(repoName)
        var isDirFlag: ObjCBool = false
        guard fm.fileExists(atPath: repoDir, isDirectory: &isDirFlag), isDirFlag.boolValue else { continue }
        guard let wtNames = try? fm.contentsOfDirectory(atPath: repoDir) else { continue }

        for wtName in wtNames.sorted() {
            guard wtName.hasPrefix("term-mesh_wt_") else { continue }
            let wtPath = (repoDir as NSString).appendingPathComponent(wtName)
            var isWtDir: ObjCBool = false
            guard fm.fileExists(atPath: wtPath, isDirectory: &isWtDir), isWtDir.boolValue else { continue }
            let branch = readWorktreeBranch(at: wtPath)
            results.append(WorktreeManagerSection.FoundWorktree(
                path: wtPath,
                name: wtName,
                branch: branch,
                repoName: repoName
            ))
        }
    }
    return results
}

/// Reads the branch name from a git worktree directory.
/// A worktree has a `.git` FILE containing `gitdir: /path/to/.git/worktrees/{name}`,
/// and the actual HEAD is inside that linked gitdir.
private func readWorktreeBranch(at path: String) -> String {
    let gitFile = (path as NSString).appendingPathComponent(".git")
    if let content = try? String(contentsOfFile: gitFile, encoding: .utf8) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("gitdir: ") {
            let gitDir = String(trimmed.dropFirst("gitdir: ".count))
            let linkedHead = (gitDir as NSString).appendingPathComponent("HEAD")
            if let head = try? String(contentsOfFile: linkedHead, encoding: .utf8) {
                return parseBranchFromHead(head)
            }
        }
    }
    // Fallback: try HEAD directly (bare worktree layout)
    let headFile = (path as NSString).appendingPathComponent("HEAD")
    if let head = try? String(contentsOfFile: headFile, encoding: .utf8) {
        return parseBranchFromHead(head)
    }
    return "unknown"
}

private func parseBranchFromHead(_ content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("ref: refs/heads/") {
        return String(trimmed.dropFirst("ref: refs/heads/".count))
    }
    if trimmed.hasPrefix("ref: ") {
        return String(trimmed.dropFirst("ref: ".count))
    }
    // Detached HEAD — show abbreviated hash
    return trimmed.isEmpty ? "unknown" : "detached:\(trimmed.prefix(8))"
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
