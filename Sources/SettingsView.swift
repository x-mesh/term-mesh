import AppKit
import SwiftUI
import PeerProto

enum SettingsSection: String, CaseIterable, Identifiable {
    case app = "app"
    case terminal = "terminal"
    case workspaceColors = "workspaceColors"
    case automation = "automation"
    case agentTeams = "agentTeams"
    case agentRunbooks = "agentRunbooks"
    case agentCLIPaths = "agentCLIPaths"
    case agentModels = "agentModels"
    case worktrees = "worktrees"
    case dashboard = "dashboard"
    case services = "services"
    case browser = "browser"
    case imeInputBar = "imeInputBar"
    case keyboardShortcuts = "keyboardShortcuts"
    case peerFederation = "peerFederation"
    case projectSync = "projectSync"
    case reset = "reset"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "App"
        case .terminal: return "Terminal"
        case .workspaceColors: return "Workspace Colors"
        case .automation: return "Automation"
        case .agentTeams: return "Agent Teams"
        case .agentRunbooks: return "Agent Runbooks"
        case .agentCLIPaths: return "Agent CLI Paths"
        case .agentModels: return "Agent Models"
        case .worktrees: return "Worktrees"
        case .dashboard: return "Dashboard"
        case .services: return "Services"
        case .browser: return "Browser"
        case .imeInputBar: return "IME Input Bar"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .peerFederation: return "Peer Federation"
        case .projectSync: return "Project Sync"
        case .reset: return "Reset"
        }
    }

    var icon: String {
        switch self {
        case .app: return "gear"
        case .terminal: return "character.cursor.ibeam"
        case .workspaceColors: return "paintpalette"
        case .automation: return "bolt.horizontal"
        case .agentTeams: return "person.3"
        case .agentRunbooks: return "book.closed"
        case .agentCLIPaths: return "terminal"
        case .agentModels: return "cpu"
        case .worktrees: return "arrow.triangle.branch"
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .services: return "stethoscope"
        case .browser: return "globe"
        case .imeInputBar: return "keyboard"
        case .keyboardShortcuts: return "command"
        case .peerFederation: return "antenna.radiowaves.left.and.right"
        case .projectSync: return "arrow.triangle.2.circlepath"
        case .reset: return "arrow.counterclockwise"
        }
    }

    var category: SettingsSectionCategory {
        switch self {
        case .app, .terminal, .workspaceColors: return .general
        case .automation, .agentTeams, .agentRunbooks, .agentCLIPaths, .agentModels, .worktrees: return .agents
        case .dashboard, .services, .peerFederation, .projectSync: return .network
        case .browser: return .browser
        case .imeInputBar, .keyboardShortcuts: return .input
        case .reset: return .system
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .app: return ["app", "language", "system", "english", "korean", "theme", "appearance", "dark", "light", "workspace", "placement", "session", "restore", "dock", "badge", "quit", "warn", "rename", "sidebar", "branch", "reorder", "notification", "experimental", "mirror", "peer hosts", "distributed", "coordinator", "review board"]
        case .terminal: return ["terminal", "font", "size", "theme", "monospace", "family"]
        case .workspaceColors: return ["workspace", "color", "indicator", "palette", "custom"]
        case .automation: return ["automation", "socket", "claude", "port", "integration", "password"]
        case .agentTeams: return ["agent", "team", "leader", "model", "directory", "rendering", "interval", "refresh", "recycle", "auto"]
        case .agentRunbooks: return ["agent", "runbook", "skill", "claude", "codex", "opencode", "install", "role"]
        case .agentCLIPaths: return ["cli", "path", "binary", "agent"] + AgentRolePreset.knownCLIs
        case .agentModels: return ["model", "custom", "version", "gemini", "codex", "kiro", "claude", "preview"]
        case .worktrees: return ["worktrees", "worktree", "base directory", "cleanup", "auto"]
        case .dashboard: return ["dashboard", "http", "localhost", "port", "remote"]
        case .services: return ["services", "daemon", "doctor", "status", "restart", "subsystem", "log", "shell", "integration", "health"]
        case .browser: return ["browser", "search", "engine", "theme", "link", "history", "http", "insecure", "suggestion"]
        case .imeInputBar: return ["ime", "input", "bar", "font", "height", "cjk"]
        case .keyboardShortcuts: return ["keyboard", "shortcut", "keybinding", "hotkey"]
        case .peerFederation: return ["peer", "federation", "remote", "ssh", "relay", "share", "bonjour", "lan"]
        case .projectSync: return ["project", "sync", "manifest", "device", "conflict", "recovery", "gc"]
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
    @AppStorage(LanguageSettings.languageModeKey) private var languageMode = LanguageSettings.defaultMode.rawValue
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
    @AppStorage(PasteShelfCaptureSettings.captureTextKey)
    private var pasteShelfCaptureText = PasteShelfCaptureSettings.defaultCaptureText
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(WorkspacePlacementSettings.placementKey) private var newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
    @AppStorage(WorkspaceAutoReorderSettings.key) private var workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
    @AppStorage(SessionRestoreSettings.modeKey) private var sessionRestoreMode = SessionRestoreSettings.defaultMode.rawValue
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage(SidebarPresentationSettings.separatedSectionsEnabledKey)
    private var sidebarSeparatedSectionsEnabled = SidebarPresentationSettings.defaultSeparatedSectionsEnabled
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    // The two UserDefaults halves of the coordinator gate. The env half
    // (TERMMESH_COORDINATOR_ENABLED) is intentionally NOT here: a release
    // build never sets it, so flipping this toggle in a shipped app enables
    // the cross-host UI without ever launching a coordinator — safe until the
    // feature is ready to ship on by itself.
    @AppStorage(ReviewBoardCoordinatorSettings.distributedFeatureKey)
    private var distributedWorkspacesEnabled = ReviewBoardCoordinatorSettings.defaultDistributedWorkspacesEnabled
    @AppStorage(ReviewBoardSettings.enabledKey)
    private var reviewBoardEnabled = ReviewBoardSettings.defaultEnabled
    @AppStorage("teamDefaultLeaderMode") private var teamDefaultLeaderMode = "claude"

    /// Whether agents get a pane the app draws instead of a terminal.
    ///
    /// Stored under the pane key; the transport key is written alongside it,
    /// because a native pane *is* the pipe transport with no terminal around
    /// it and turning on one without the other does nothing.
    @AppStorage(AgentPipeTransport.nativePanelKey)
    private var agentNativePanes = AgentPipeTransport.defaultNativePanel
    @AppStorage("teamDefaultModel") private var teamDefaultModel = "sonnet"
    @AppStorage("teamDefaultWorkingDirectory") private var teamDefaultWorkingDirectory = ""
    @AppStorage(ProjectLocationSettings.localProjectsRootKey)
    private var localProjectsRoot = ProjectLocationSettings.defaultLocalProjectsRoot
    @AppStorage(ProjectLocationSettings.repositorySearchRootsKey)
    private var repositorySearchRoots = ""
    @AppStorage("agentRenderingInterval") private var agentRenderingInterval = 3
    // Phase 2 headless: idle-park threshold (0 = disabled, max 1440 min/24h)
    @AppStorage("headlessIdleParkMinutes") private var headlessIdleParkMinutes = 60
    // Phase 2 headless: archive retention (days, 1–30)
    @AppStorage("headlessSessionRetentionDays") private var headlessSessionRetentionDays = 7
    @AppStorage("cliPath.claude") private var cliPathClaude = ""
    @AppStorage("cliPath.kiro") private var cliPathKiro = ""
    @AppStorage("cliPath.codex") private var cliPathCodex = ""
    @AppStorage("cliPath.gemini") private var cliPathGemini = ""
    @AppStorage("imeBarFontSize") private var imeBarFontSize = IMEInputBarSettings.defaultFontSize
    @AppStorage("imeBarHeight") private var imeBarHeight = IMEInputBarSettings.defaultHeight
    @AppStorage("termmesh.autoRecycle.globalDefault") private var autoRecycleGlobalDefault: Int = 0
    @AppStorage(TermMeshDaemon.dashboardEnabledKey) private var dashboardEnabled = true
    @AppStorage(TermMeshDaemon.dashboardLocalhostOnlyKey) private var dashboardLocalhostOnly = true
    @AppStorage(TermMeshDaemon.dashboardPortKey) private var dashboardPort = 9876
    @AppStorage(TermMeshDaemon.dashboardPasswordKey) private var dashboardPassword = ""
    @AppStorage(TerminalSettingsOverride.fontFamilyKey) private var terminalFontFamily = ""
    @AppStorage(TerminalSettingsOverride.fontSizeKey) private var terminalFontSize: Double = 0
    @AppStorage(TerminalSettingsOverride.themeLightKey) private var terminalThemeLight = ""
    @AppStorage(TerminalSettingsOverride.themeDarkKey) private var terminalThemeDark = ""
    @AppStorage(TerminalSettingsOverride.backgroundOpacityKey) private var terminalBgOpacity: Double = -1
    @AppStorage(TerminalSettingsOverride.cursorColorKey) private var terminalCursorColor = ""
    @AppStorage(TerminalSettingsOverride.cursorStyleKey) private var terminalCursorStyle = ""
    @AppStorage(TerminalSettingsOverride.scrollbackLimitKey) private var terminalScrollback: Int = 0
    @AppStorage(TerminalSettingsOverride.unfocusedSplitOpacityKey) private var terminalUnfocusedOpacity: Double = -1
    @AppStorage(TerminalSettingsOverride.splitDividerColorKey) private var terminalDividerColor = ""

    @AppStorage(PeerFederationSettings.autoStartKey) private var peerFederationAutoStart = false
    @AppStorage(PeerFederationSettings.socketPathKey) private var peerFederationSocketPath = PeerFederationSettings.defaultSocketPath
    @AppStorage(PeerFederationSettings.displayNameKey) private var peerFederationDisplayName = ""
    @AppStorage(PeerFederationSettings.forceRedrawKey) private var peerFederationForceRedraw = false
    /// Mirrors `PeerHostCoordinator.shared.isRunning`. Refreshed on
    /// section appear and after every toggle change since the
    /// coordinator state is held outside SwiftUI.
    @State private var peerFederationServerRunning = false

    @Environment(\.daemonService) private var daemonService
    @Environment(\.browserHistoryService) private var browserHistory

    @State private var shortcutResetToken = UUID()
    @State private var topBlurOpacity: Double = 0
    @State private var topBlurBaselineOffset: CGFloat?
    @State private var settingsTitleLeadingInset: CGFloat = 92
    @State private var settingsSearchQuery = ""
    @State private var showClearBrowserHistoryConfirmation = false
    @State private var showOpenAccessConfirmation = false
    @State private var showPeerIDRegenerateConfirmation = false
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
    @State private var dashboardRestartWork: DispatchWorkItem?
    @State private var daemonLogTail: AttributedString?
    @State private var shellHealthEntries: [ShellHealthEntry] = []
    @State private var shellFixCopied = false
    @State private var peerFederationPeerIDHex = "Loading..."
    @State private var peerFederationPeerIDStatusMessage: String?
    @State private var peerFederationPeerIDStatusIsError = false
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
            return LanguageSettings.localized("No saved pages yet.")
        case 1:
            return LanguageSettings.localized("1 saved page appears in omnibar suggestions.")
        default:
            return String(
                format: LanguageSettings.localized("%lld saved pages appear in omnibar suggestions."),
                locale: LanguageSettings.currentLocale(),
                browserHistoryEntryCount
            )
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
        matchesQuery(keywords)
    }

    private func sectionVisible(_ sectionKeywords: [String], rowKeywords: [[String]]) -> Bool {
        let q = normalizedSearchQuery
        guard !q.isEmpty else { return true }
        if matchesQuery(sectionKeywords) { return true }
        return rowKeywords.contains { matchesQuery($0) }
    }

    /// Matches the query against a row's keywords, which are always written in
    /// English.
    ///
    /// Once the UI is Korean the user types 테마, which appears in no keyword
    /// list. Rather than duplicating every list per language, the query is
    /// mapped back through the string catalog — 테마 translates "Theme", so
    /// "theme" joins the terms being matched. Keyword lists stay single-source.
    private func matchesQuery(_ keywords: [String]) -> Bool {
        let q = normalizedSearchQuery
        guard !q.isEmpty else { return true }
        if keywords.contains(where: { $0.lowercased().contains(q) }) { return true }

        let translated = SettingsSearchIndex.englishTerms(
            matching: q,
            locale: LanguageSettings.locale(for: languageMode)
        )
        guard !translated.isEmpty else { return false }
        return keywords.contains { keyword in
            let k = keyword.lowercased()
            return translated.contains { $0.contains(k) || k.contains($0) }
        }
    }

    // MARK: - Sidebar Filtering

    /// Sections that match the current search query.
    private var visibleSections: [SettingsSection] {
        let workspaceFirstSections = SettingsSection.allCases.filter { $0 != .projectSync }
        guard isSearching else { return workspaceFirstSections }
        return workspaceFirstSections.filter { sectionMatchesSearch($0) }
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
        .onReceive(NotificationCenter.default.publisher(for: .settingsNavigateToSection)) { output in
            guard let raw = output.userInfo?[SettingsNavigationUserInfoKey.section] as? String,
                  let section = SettingsSection(rawValue: raw) else { return }
            settingsSearchQuery = ""
            selectedSection = section
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
        .confirmationDialog(
            "Regenerate peer ID?",
            isPresented: $showPeerIDRegenerateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Regenerate Peer ID", role: .destructive) {
                regeneratePeerIdentity()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing peer pairings may stop working. Durable Project ownership is retained on this Mac. Restart active peer sessions after regenerating this ID.")
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
                            Text(LocalizedStringKey(section.category.rawValue))
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
                                Text(LocalizedStringKey(section.title))
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
                Text(LocalizedStringKey(selectedSection.title))
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
        case .terminal:
            sectionTerminal
        case .workspaceColors:
            sectionWorkspaceColors
        case .automation:
            sectionAutomation
        case .agentTeams:
            sectionAgentTeams
        case .agentRunbooks:
            AgentRunbookSettingsView()
        case .agentCLIPaths:
            sectionAgentCLIPaths
        case .agentModels:
            sectionAgentModels
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
        case .peerFederation:
            sectionPeerFederation
        case .projectSync:
            ProjectSyncPanelView()
        case .reset:
            sectionReset
        }
    }

    // MARK: - Section: App

    @ViewBuilder
    private var sectionApp: some View {
        SettingsCard {
                        let showsLanguageSetting = settingsMatch("language", "system", "english", "korean", "app")
                        if showsLanguageSetting {
                        SettingsCardRow(
                            "Language",
                            subtitle: "Follow the macOS language, or choose a language for term-mesh.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("Language", selection: $languageMode) {
                                ForEach(AppLanguage.allCases) { language in
                                    if let endonym = language.endonym {
                                        Text(verbatim: endonym).tag(language.rawValue)
                                    } else {
                                        Text(LocalizedStringKey(language.displayName)).tag(language.rawValue)
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        }

                        if settingsMatch("theme", "appearance", "dark", "light", "app") {
                        if showsLanguageSetting {
                            SettingsCardDivider()
                        }

                        SettingsCardRow("Theme", controlWidth: pickerColumnWidth) {
                            Picker("Theme", selection: $appearanceMode) {
                                ForEach(AppearanceMode.visibleCases) { mode in
                                    Text(LocalizedStringKey(mode.displayName)).tag(mode.rawValue)
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
                                    Text(LocalizedStringKey(placement.displayName)).tag(placement.rawValue)
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
                                    Text(LocalizedStringKey(mode.displayName)).tag(mode.rawValue)
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

                        if settingsMatch("paste", "shelf", "clipboard", "copy", "privacy", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Save Copied Text to Paste Shelf",
                            subtitle: pasteShelfCaptureText
                                ? "Cmd+C in a terminal stores the text on disk for 7 days, unencrypted."
                                : "Only copied images are stored. Text copies are never written to disk."
                        ) {
                            Toggle("", isOn: $pasteShelfCaptureText)
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

                        if settingsMatch("sidebar", "experimental", "local", "peer hosts", "mirror", "app") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "New Sidebar (Experimental)",
                            subtitle: "Separates local workspaces from Peer Hosts and presents peer workspaces as mirror actions."
                        ) {
                            Toggle("", isOn: $sidebarSeparatedSectionsEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel("Use new sidebar")
                        }
                        }

                        if settingsMatch("distributed", "coordinator", "experimental", "review board", "peer hosts") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Distributed Workspaces (Experimental)",
                            subtitle: distributedWorkspacesActive
                                ? "Tracks projects, hosts, and team leaders across machines via the coordinator."
                                : "Tracks projects and team leaders across machines. Needs TERMMESH_COORDINATOR_ENABLED=1 in the environment to actually launch the coordinator."
                        ) {
                            Toggle("", isOn: distributedWorkspacesBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel("Enable distributed workspaces")
                        }
                        }

        }
    }

    /// Both UserDefaults halves of the coordinator gate, flipped as one — the
    /// gate is an AND of the two, so a single switch is the honest control.
    private var distributedWorkspacesBinding: Binding<Bool> {
        // Reading the @AppStorage vars keeps the toggle reactive; writing
        // goes through the shared setter so the two-keys-as-one rule lives in
        // one place (and is unit-tested there).
        Binding(
            get: { distributedWorkspacesEnabled && reviewBoardEnabled },
            set: { on in
                distributedWorkspacesEnabled = on
                reviewBoardEnabled = on
                // Turning it on here has to actually show it. Writing only
                // `enabled` left a board that had been dismissed still
                // dismissed, so the switch read as broken.
                ReviewBoardSettings.setVisible(on)
            }
        )
    }

    /// Whether the gate is fully open — the env half is out of the UI's
    /// hands, so the subtitle tells the user when the toggle is not enough.
    private var distributedWorkspacesActive: Bool {
        ReviewBoardCoordinatorSettings.isIntegrationEnabled()
    }

    // MARK: - Section: Terminal

    @ViewBuilder
    private var sectionTerminal: some View {
        SettingsCard {
            if settingsMatch("font", "family", "monospace", "terminal") {
                SettingsCardRow(
                    "Font Family",
                    subtitle: terminalFontFamily.isEmpty ? "Using ghostty config value" : nil,
                    controlWidth: pickerColumnWidth
                ) {
                    Picker("", selection: $terminalFontFamily) {
                        Text("Default (from config)").tag("")
                        let fonts = MonospaceFontList.list()
                        let monoCount = MonospaceFontList.monospaceFontCount
                        if monoCount > 0 {
                            Divider()
                            ForEach(fonts.prefix(monoCount), id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }
                        if fonts.count > monoCount {
                            Divider()
                            ForEach(fonts.suffix(from: monoCount), id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            if settingsMatch("font", "size", "terminal") {
                SettingsCardDivider()

                SettingsCardRow(
                    "Font Size",
                    subtitle: terminalFontSize == 0 ? "Using ghostty config value" : nil,
                    controlWidth: pickerColumnWidth
                ) {
                    HStack(spacing: 6) {
                        TextField("", value: Binding(
                            get: { terminalFontSize == 0 ? 13 : Int(terminalFontSize) },
                            set: { terminalFontSize = Double($0) }
                        ), format: .number)
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)

                        Stepper("", value: Binding(
                            get: { terminalFontSize == 0 ? 13.0 : terminalFontSize },
                            set: { terminalFontSize = $0 }
                        ), in: 8...32, step: 1)
                        .labelsHidden()

                        if terminalFontSize > 0 {
                            Button("Reset") {
                                terminalFontSize = 0
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.accentColor)
                            .font(.caption)
                        }
                    }
                }
            }

            if settingsMatch("theme", "light", "terminal") {
                SettingsCardDivider()

                SettingsCardRow(
                    "Light Theme",
                    subtitle: terminalThemeLight.isEmpty ? "Using ghostty config value" : nil,
                    controlWidth: pickerColumnWidth
                ) {
                    Picker("", selection: $terminalThemeLight) {
                        Text("Default (from config)").tag("")
                        Divider()
                        ForEach(TerminalThemeList.bundledThemeNames(for: .light), id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            if settingsMatch("theme", "dark", "terminal") {
                SettingsCardDivider()

                SettingsCardRow(
                    "Dark Theme",
                    subtitle: terminalThemeDark.isEmpty ? "Using ghostty config value" : nil,
                    controlWidth: pickerColumnWidth
                ) {
                    Picker("", selection: $terminalThemeDark) {
                        Text("Default (from config)").tag("")
                        Divider()
                        ForEach(TerminalThemeList.bundledThemeNames(for: .dark), id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }

        SettingsCard {
            // Background Opacity: requires CAMetalLayer.isOpaque=false in ghostty — deferred

            if settingsMatch("cursor", "style", "block", "bar", "underline", "terminal") {
                SettingsCardRow(
                    "Cursor Style",
                    subtitle: terminalCursorStyle.isEmpty ? "Using ghostty config value" : nil,
                    controlWidth: pickerColumnWidth
                ) {
                    Picker("", selection: $terminalCursorStyle) {
                        Text("Default (from config)").tag("")
                        Divider()
                        Text("Block").tag("block")
                        Text("Bar").tag("bar")
                        Text("Underline").tag("underline")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            if settingsMatch("cursor", "color", "terminal") {
                SettingsCardDivider()

                SettingsCardRow(
                    "Cursor Color",
                    subtitle: terminalCursorColor.isEmpty ? "Using ghostty config value" : nil,
                    controlWidth: pickerColumnWidth
                ) {
                    HStack(spacing: 6) {
                        ColorPicker("", selection: Binding(
                            get: {
                                if terminalCursorColor.isEmpty { return .white }
                                return Color(nsColor: NSColor(hex: terminalCursorColor) ?? .white)
                            },
                            set: { newValue in
                                terminalCursorColor = NSColor(newValue).hexString()
                            }
                        ))
                        .labelsHidden()
                        if !terminalCursorColor.isEmpty {
                            Button("Reset") { terminalCursorColor = "" }
                                .buttonStyle(.borderless)
                                .foregroundColor(.accentColor)
                                .font(.caption)
                        }
                    }
                }
            }

            if settingsMatch("unfocused", "split", "opacity", "dim", "terminal") {
                SettingsCardDivider()

                SettingsCardRow(
                    "Unfocused Split Opacity",
                    verbatimSubtitle: terminalUnfocusedOpacity < 0
                        ? LanguageSettings.localized("Using ghostty config value")
                        : "\(Int(terminalUnfocusedOpacity * 100))%",
                    controlWidth: pickerColumnWidth
                ) {
                    HStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { terminalUnfocusedOpacity < 0 ? 0.7 : terminalUnfocusedOpacity },
                                set: { terminalUnfocusedOpacity = $0 }
                            ),
                            in: 0...1,
                            step: 0.05
                        )
                        if terminalUnfocusedOpacity >= 0 {
                            Button("Reset") { terminalUnfocusedOpacity = -1 }
                                .buttonStyle(.borderless)
                                .foregroundColor(.accentColor)
                                .font(.caption)
                        }
                    }
                }
            }

            if settingsMatch("split", "divider", "color", "border", "separator", "terminal") {
                SettingsCardDivider()

                SettingsCardRow(
                    "Split Divider Color",
                    subtitle: terminalDividerColor.isEmpty ? "Using ghostty config value" : nil,
                    controlWidth: pickerColumnWidth
                ) {
                    HStack(spacing: 6) {
                        ColorPicker(
                            "",
                            selection: Binding(
                                get: {
                                    if terminalDividerColor.isEmpty { return .gray }
                                    return Color(nsColor: NSColor(hex: terminalDividerColor) ?? .gray)
                                },
                                set: { newValue in
                                    terminalDividerColor = NSColor(newValue).hexString()
                                }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        if !terminalDividerColor.isEmpty {
                            Button("Reset") { terminalDividerColor = "" }
                                .buttonStyle(.borderless)
                                .foregroundColor(.accentColor)
                                .font(.caption)
                        }
                    }
                }
            }

            if settingsMatch("scrollback", "limit", "history", "buffer", "terminal") {
                SettingsCardDivider()

                SettingsCardRow(
                    "Scrollback Limit",
                    verbatimSubtitle: terminalScrollback == 0
                        ? LanguageSettings.localized("Using ghostty config value")
                        : String(
                            format: LanguageSettings.localized("%@ bytes"),
                            terminalScrollback.formatted()
                          ),
                    controlWidth: pickerColumnWidth
                ) {
                    Picker("", selection: $terminalScrollback) {
                        Text("Default (from config)").tag(0)
                        Divider()
                        Text("1 MB").tag(1_000_000)
                        Text("10 MB").tag(10_000_000)
                        Text("50 MB").tag(50_000_000)
                        Text("100 MB").tag(100_000_000)
                        Text("Unlimited").tag(Int.max)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }

        SettingsCardNote("These settings override your ghostty config file. Select \"Default\" or \"Reset\" to use the config file value.")
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
                                    Text(LocalizedStringKey(style.displayName)).tag(style.rawValue)
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
                                verbatim: entry.name,
                                verbatimSubtitle: "Base: \(baseTabColorHex(for: entry.name))"
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
                                    Text(LocalizedStringKey(mode.displayName)).tag(mode.rawValue)
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
                        if settingsMatch("agent", "pane", "native", "terminal",
                                         "surface", "stream", "team") {
                        SettingsCardRow(
                            "Agent Panes",
                            subtitle: agentNativePanes
                                ? "Agents run in the app and are drawn by it — streamed text, tool calls that fold, a message box. No terminal."
                                : "Agents run a CLI inside a terminal pane, as they always have.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: $agentNativePanes) {
                                Text("Terminal").tag(false)
                                Text("Native").tag(true)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        // Two keys, one decision: the native pane is the pipe
                        // transport without a terminal around it, and turning
                        // on the pane alone would do nothing at all.
                        .onChange(of: agentNativePanes) { _, on in
                            UserDefaults.standard.set(on, forKey: AgentPipeTransport.enabledKey)
                        }

                        SettingsCardDivider()
                        }

                        if settingsMatch("leader", "mode", "repl", "claude", "agent", "team") {
                        SettingsCardRow(
                            "Default Leader Mode",
                            subtitle: teamDefaultLeaderMode == "claude"
                                ? "Leader runs Claude automatically. (핀이 없을 때만 사용)"
                                : "Leader provides a manual REPL console. (핀이 없을 때만 사용)",
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
                            "Projects Under",
                            subtitle: "Default parent folder for new projects on This Mac."
                        ) {
                            HStack(spacing: 8) {
                                TextField("~/work/project", text: $localProjectsRoot)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 170)
                                Button("Browse…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = true
                                    panel.canChooseFiles = false
                                    panel.allowsMultipleSelection = false
                                    panel.presentAsSheet { response in
                                        if response == .OK, let url = panel.url {
                                            localProjectsRoot = url.path
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            "Find Repositories In",
                            subtitle: "Folders scanned for already-cloned repositories, one per line. Empty uses Projects Under."
                        ) {
                            TextEditor(text: $repositorySearchRoots)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 240, height: 54)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            "Default Working Directory",
                            verbatimSubtitle: teamDefaultWorkingDirectory.isEmpty
                                ? LanguageSettings.localized("Uses the current workspace directory.")
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
                                    panel.presentAsSheet { response in
                                        if response == .OK, let url = panel.url {
                                            teamDefaultWorkingDirectory = url.path
                                        }
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

                        // Phase 2 Headless options
                        if settingsMatch("headless", "park", "idle", "auto", "agent", "team") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Idle Auto-Park (min)",
                            subtitle: headlessIdleParkMinutes == 0
                                ? "Disabled — headless agents stay alive indefinitely."
                                : "Headless agents are parked after this many idle minutes (subprocess terminated, session preserved).",
                            controlWidth: pickerColumnWidth
                        ) {
                            HStack(spacing: 6) {
                                Stepper(value: $headlessIdleParkMinutes, in: 0...1440, step: 5) {
                                    Text(headlessIdleParkMinutes == 0 ? "Off" : "\(headlessIdleParkMinutes) min")
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minWidth: 70, alignment: .trailing)
                                }
                                .labelsHidden()
                            }
                            .onChange(of: headlessIdleParkMinutes) { newValue in
                                pushIdleParkMinutes(newValue)
                            }
                        }
                        }

                        if settingsMatch("headless", "retention", "archive", "session", "days") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Session Retention (days)",
                            subtitle: "Destroyed headless team sessions remain resumable for this many days before they are garbage-collected.",
                            controlWidth: pickerColumnWidth
                        ) {
                            Stepper(value: $headlessSessionRetentionDays, in: 1...30, step: 1) {
                                Text("\(headlessSessionRetentionDays) day\(headlessSessionRetentionDays == 1 ? "" : "s")")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minWidth: 70, alignment: .trailing)
                            }
                            .labelsHidden()
                        }
                        }

                        if settingsMatch("recycle", "auto", "agent", "team") {
                        SettingsCardDivider()

                        SettingsCardRow(
                            "Auto-recycle default",
                            verbatimSubtitle: autoRecycleGlobalDefault == 0
                                ? LanguageSettings.localized("Disabled — new teams will not auto-recycle agents.")
                                : String(
                                    format: LanguageSettings.localized(
                                        autoRecycleGlobalDefault == 1
                                            ? "New teams will auto-recycle agents every %lld completed task."
                                            : "New teams will auto-recycle agents every %lld completed tasks."
                                    ),
                                    locale: LanguageSettings.currentLocale(),
                                    autoRecycleGlobalDefault
                                  )
                        ) {
                            Stepper(value: $autoRecycleGlobalDefault, in: 0...100, step: 1) {
                                Text(autoRecycleGlobalDefault == 0 ? "Off" : "\(autoRecycleGlobalDefault) tasks")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minWidth: 70, alignment: .trailing)
                            }
                            .labelsHidden()
                        }
                        }
        }
    }

    /// Phase 2: push idle-park threshold to the daemon. Fire-and-forget;
    /// failure is non-fatal (setting persists in AppStorage either way and
    /// re-syncs on next change). Off-main per "Socket command threading policy".
    private func pushIdleParkMinutes(_ minutes: Int) {
        let clamped = max(0, min(1440, minutes))
        DispatchQueue.global(qos: .utility).async {
            _ = TermMeshDaemon.shared.rpcCallRaw(
                method: "headless.set_idle_park_minutes",
                params: ["minutes": clamped]
            )
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
        SettingsCardNote("Select or create profiles to customize path, extra args, and env per CLI. Active profile takes priority over auto-detect.")
    }

    // MARK: - Section: Agent Models

    @ViewBuilder
    private var sectionAgentModels: some View {
        ForEach(AgentRolePreset.knownCLIs, id: \.self) { cli in
            CLICustomModelsSection(cli: cli)
        }
        SettingsCardNote("Add custom model names per CLI. These appear alongside built-in models in the team creation picker.")
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
                                // Matches the stored default (UserDefaults.bool
                                // is false when unset) — reading `true` here
                                // showed the switch on while nothing was set.
                                get: { daemonService?.worktreeAutoCleanup ?? false },
                                set: { daemonService?.worktreeAutoCleanup = $0 }
                            ))
                            .toggleStyle(.switch)
                        }
        }

        WorktreeManagerSection(baseDir: daemonService?.worktreeBaseDir ?? TermMeshDaemon.defaultWorktreeBaseDir)

        WorktreeLogSection()
    }

    // MARK: - Section: Dashboard

    @ViewBuilder
    private var sectionDashboard: some View {
        SettingsCard {
                        SettingsCardRow(
                            "HTTP Dashboard",
                            verbatimSubtitle: dashboardEnabled
                                ? String(
                                    format: LanguageSettings.localized("Web dashboard at %@:%@"),
                                    dashboardLocalhostOnly ? "localhost" : "0.0.0.0",
                                    String(dashboardPort)
                                  ) + (dashboardPassword.isEmpty ? "" : " 🔒")
                                : LanguageSettings.localized("Dashboard is disabled. Daemon runs without HTTP server.")
                        ) {
                            Toggle("", isOn: $dashboardEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                                .onChange(of: dashboardEnabled) { _ in
                                    scheduleDaemonRestart(delay: 0)
                                }
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
                                .onChange(of: dashboardLocalhostOnly) { _ in
                                    scheduleDaemonRestart(delay: 0)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow("Port", subtitle: "HTTP port for the dashboard.", controlWidth: pickerColumnWidth) {
                                TextField("", value: $dashboardPort, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .onChange(of: dashboardPort) { _ in
                                        scheduleDaemonRestart(delay: 1.5)
                                    }
                            }

                            SettingsCardDivider()

                            SettingsCardRow("Password", subtitle: "Require a password to access the dashboard. Leave empty to disable auth.", controlWidth: pickerColumnWidth) {
                                SecureField("Optional", text: $dashboardPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .onChange(of: dashboardPassword) { _ in
                                        scheduleDaemonRestart(delay: 1.5)
                                    }
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardNote("Dashboard settings auto-restart the daemon when changed. The dashboard shows system metrics, team status, agents, and task boards.")
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
                                verbatimSubtitle: status.bundleIdentifier
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
                            verbatimSubtitle: daemonStatusSubtitle
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
                                verbatimSubtitle: status.socketPath
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
                                verbatimSubtitle: status.binaryPath
                                    ?? LanguageSettings.localized("(not found)")
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
                                verbatimSubtitle: status.logPath
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
                                    verbatim: sub.name,
                                    verbatimSubtitle: sub.detail
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
                                    // Brand names — never translated.
                                    Text(verbatim: engine.displayName).tag(engine.rawValue)
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
                            verbatimSubtitle: selectedBrowserThemeMode == .system
                                ? LanguageSettings.localized("System follows app and macOS appearance.")
                                : String(
                                    format: LanguageSettings.localized("%@ forces that color scheme for compatible pages."),
                                    LanguageSettings.localized(selectedBrowserThemeMode.displayName)
                                  ),
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: browserThemeModeSelection) {
                                ForEach(BrowserThemeMode.allCases) { mode in
                                    Text(LocalizedStringKey(mode.displayName)).tag(mode.rawValue)
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

                        SettingsCardRow("Browsing History", verbatimSubtitle: browserHistorySubtitle) {
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

    // MARK: - Section: Peer Federation

    @ViewBuilder
    private var sectionPeerFederation: some View {
        SettingsCard {
            SettingsCardRow(
                "Enable peer server",
                verbatimSubtitle: peerFederationServerRunning
                    ? String(
                        format: LanguageSettings.localized("Listening at %@. Remote clients can attach now."),
                        peerFederationSocketPath
                      )
                    : LanguageSettings.localized("Server is off. Toggle on to accept incoming relay attaches.")
            ) {
                Toggle("", isOn: $peerFederationServerRunning)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: peerFederationServerRunning) { newValue in
                        Task { @MainActor in
                            await PeerHostCoordinator.shared.setRunning(newValue)
                            peerFederationServerRunning = PeerHostCoordinator.shared.isRunning
                        }
                    }
            }

            SettingsCardDivider()

            SettingsCardRow(
                "Auto-start at app launch",
                subtitle: peerFederationAutoStart
                    ? "Server will start automatically when the app launches."
                    : "Server stays off until you toggle it on or click \"Start Peer Server…\" in the menu bar."
            ) {
                Toggle("", isOn: $peerFederationAutoStart)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                "Socket path",
                subtitle: "Local Unix socket the peer server binds. SSH clients tunnel into this path on the remote machine.",
                controlWidth: 280
            ) {
                TextField(PeerFederationSettings.defaultSocketPath, text: $peerFederationSocketPath)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(
                "Display name",
                subtitle: "Shown in remote clients' connect dialogs and Bonjour LAN browse list. Defaults to this Mac's hostname.",
                controlWidth: 280
            ) {
                TextField(PeerFederationSettings.defaultDisplayName, text: $peerFederationDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(
                "Peer ID",
                subtitle: "Stable 16-byte identity stored in this Mac's keychain. Regenerating can invalidate existing pairings.",
                controlWidth: 360
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(peerFederationPeerIDHex)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(peerFederationPeerIDHex)
                        Button("Regenerate") {
                            showPeerIDRegenerateConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if let message = peerFederationPeerIDStatusMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundColor(peerFederationPeerIDStatusIsError ? .red : .secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                "Force TUI redraw on attach",
                subtitle: peerFederationForceRedraw
                    ? "Sends Ctrl-L to the host PTY whenever a peer attaches so vim, htop, less repaint with full color. The redraw is also visible to the host's local viewer."
                    : "Initial-attach snapshot is plain text; full-screen TUIs keep their text but lose styling until they redraw on their own."
            ) {
                Toggle("", isOn: $peerFederationForceRedraw)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardNote("Peer federation lets another term-mesh.app instance attach this Mac's terminal panes via SSH (workspace mirror with live layout sync). \"Enable peer server\" controls the running state right now; \"Auto-start at app launch\" persists across restarts.")
        }
        .onAppear {
            peerFederationServerRunning = PeerHostCoordinator.shared.isRunning
            refreshPeerIdentityDisplay()
        }
    }

    private func refreshPeerIdentityDisplay() {
        Task.detached {
            let result = Result { PeerIdentity.defaultPeerID() }
            await MainActor.run {
                switch result {
                case .success(let id):
                    peerFederationPeerIDHex = PeerIdentity.hexString(id)
                    peerFederationPeerIDStatusMessage = nil
                    peerFederationPeerIDStatusIsError = false
                case .failure(let error):
                    peerFederationPeerIDHex = "Unavailable"
                    peerFederationPeerIDStatusMessage = String(describing: error)
                    peerFederationPeerIDStatusIsError = true
                }
            }
        }
    }

    private func regeneratePeerIdentity() {
        Task.detached {
            let result = Result { try PeerIdentity.regenerate() }
            await MainActor.run {
                switch result {
                case .success(let id):
                    peerFederationPeerIDHex = PeerIdentity.hexString(id)
                    peerFederationPeerIDStatusMessage = "Regenerated. Restart active peer sessions."
                    peerFederationPeerIDStatusIsError = false
                case .failure(let error):
                    peerFederationPeerIDStatusMessage = String(describing: error)
                    peerFederationPeerIDStatusIsError = true
                }
            }
        }
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
        guard let status = daemonStatusInfo else {
            return LanguageSettings.localized("Checking...")
        }
        if !status.connected {
            if !status.binaryExists {
                return LanguageSettings.localized("Binary not found. Build the daemon first.")
            }
            if !status.socketExists {
                return LanguageSettings.localized("Socket missing. Daemon may not be running.")
            }
            return String(
                format: LanguageSettings.localized("Not responding on %@"),
                status.socketPath
            )
        }
        if let pid = status.pid, let uptime = status.uptimeSecs {
            return String(
                format: LanguageSettings.localized("PID %@ — up %@"),
                String(pid),
                formatUptime(uptime)
            )
        }
        return LanguageSettings.localized("Connected")
    }

    private var resolvedDaemon: (any DaemonService)? {
        daemonService ?? TermMeshDaemon.shared
    }

    private func scheduleDaemonRestart(delay: TimeInterval) {
        dashboardRestartWork?.cancel()
        if delay <= 0 {
            isDaemonRestarting = true
            resolvedDaemon?.restartDaemon {
                refreshDaemonStatus()
                isDaemonRestarting = false
            }
            return
        }
        let work = DispatchWorkItem {
            isDaemonRestarting = true
            resolvedDaemon?.restartDaemon {
                refreshDaemonStatus()
                isDaemonRestarting = false
            }
        }
        dashboardRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
            SettingsCardRow("Shell Integration", verbatimSubtitle: shellHealthSummary) {
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

                    let displayStatus = entry.isAgentPanel ? IntegrationStatus.agentMode : entry.health.status
                    SettingsCardRow(
                        verbatim: "\(entry.workspaceTitle) / \(entry.panelTitle)",
                        verbatimSubtitle: entry.isAgentPanel
                            ? LanguageSettings.localized("TUI agent — shell integration N/A")
                            : shellHealthDetail(entry)
                    ) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(displayStatus.settingsColor)
                                .frame(width: 7, height: 7)
                            Text(displayStatus.label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            SettingsCardDivider()

            HStack {
                Spacer(minLength: 0)
                if shellHealthEntries.filter({ !$0.isAgentPanel })
                    .contains(where: { $0.health.status == .notLoaded || $0.health.status == .stale }) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shellFixCommand, forType: .string)
                        shellFixCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            shellFixCopied = false
                        }
                    } label: {
                        Label(
                            shellFixCopied ? (isZshShell ? "Copied — opens a fixed shell" : "Copied!") : "Copy Fix Command",
                            systemImage: shellFixCopied ? "checkmark" : "doc.on.clipboard"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
        if total == 0 { return LanguageSettings.localized("No terminal panels detected") }
        let key = total == 1
            ? "%lld terminal panel across all workspaces"
            : "%lld terminal panels across all workspaces"
        return String(
            format: LanguageSettings.localized(key),
            locale: LanguageSettings.currentLocale(),
            total
        )
    }

    private var shellHealthOverallColor: Color {
        if shellHealthEntries.isEmpty { return .gray }
        // Agent panels are expected to lack shell integration; exclude from health assessment.
        let nonAgentStatuses = shellHealthEntries
            .filter { !$0.isAgentPanel }
            .map { $0.health.status }
        if nonAgentStatuses.isEmpty {
            // All panels are agent panels — show blue if any exist, gray otherwise.
            return shellHealthEntries.isEmpty ? .gray : .blue
        }
        if nonAgentStatuses.contains(.notLoaded) { return .red }
        if nonAgentStatuses.contains(.partial) || nonAgentStatuses.contains(.stale) { return .orange }
        if nonAgentStatuses.allSatisfy({ $0 == .starting }) { return .gray }
        return .green
    }

    private var shellHealthOverallLabel: String {
        if shellHealthEntries.isEmpty { return "No panels" }
        let agentCount = shellHealthEntries.filter { $0.isAgentPanel }.count
        // Evaluate health only for non-agent panels.
        let nonAgentStatuses = shellHealthEntries
            .filter { !$0.isAgentPanel }
            .map { $0.health.status }
        if nonAgentStatuses.isEmpty {
            return "\(agentCount) agent\(agentCount == 1 ? "" : "s")"
        }
        let notLoadedCount = nonAgentStatuses.filter { $0 == .notLoaded }.count
        if notLoadedCount > 0 {
            let suffix = agentCount > 0 ? " · \(agentCount) agent\(agentCount == 1 ? "" : "s")" : ""
            return "\(notLoadedCount) not loaded\(suffix)"
        }
        let problemCount = nonAgentStatuses.filter { $0 == .partial || $0 == .stale }.count
        if problemCount > 0 {
            let suffix = agentCount > 0 ? " · \(agentCount) agent\(agentCount == 1 ? "" : "s")" : ""
            return "\(problemCount) degraded\(suffix)"
        }
        if nonAgentStatuses.allSatisfy({ $0 == .starting }) { return "Starting..." }
        let suffix = agentCount > 0 ? " · \(agentCount) agent\(agentCount == 1 ? "" : "s")" : ""
        return "All healthy\(suffix)"
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

    private var isZshShell: Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return URL(fileURLWithPath: shell).lastPathComponent == "zsh"
    }

    private var shellFixCommand: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        guard let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path else {
            return "# Shell integration directory not found. Try reinstalling term-mesh."
        }
        let escaped = integrationDir.replacingOccurrences(of: "\"", with: "\\\"")
        switch shellName {
        case "zsh":
            // zsh integration requires ZDOTDIR at startup; cannot source into running session.
            // This opens a nested zsh with integration active.
            return "ZDOTDIR=\"\(escaped)/zsh\" zsh"
        case "bash":
            return "source \"\(escaped)/bash/ghostty.bash\""
        case "fish":
            return "source \"\(escaped)/fish/vendor_conf.d/ghostty.fish\""
        default:
            return "# Open a new term-mesh tab to reload shell integration (detected shell: \(shellName))"
        }
    }

    private func refreshShellIntegrationHealth() {
        guard let appDelegate = AppDelegate.shared else {
            shellHealthEntries = []
            return
        }
        // Collect all agent panel IDs across all teams for quick lookup
        let agentPanelIds: Set<UUID> = {
            var ids = Set<UUID>()
            for team in TeamOrchestrator.shared.teams.values {
                for agent in team.agents {
                    if let pid = agent.panelId {
                        ids.insert(pid)
                    }
                }
            }
            return ids
        }()
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
                        health: health,
                        isAgentPanel: agentPanelIds.contains(panelId)
                    ))
                }
            }
        }
        shellHealthEntries = entries
    }

    /// Collection, redaction, and formatting all live in `DiagnosticsReport`
    /// so this button and the bug-report flow cannot drift into producing
    /// two different bundles — and so nothing reaches the pasteboard that
    /// has not passed the redactor.
    private func copyDiagnostics() {
        let text = DiagnosticsReport.build(daemonStatus: daemonStatusInfo)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resetAllSettings() {
        languageMode = LanguageSettings.defaultMode.rawValue
        appearanceMode = AppearanceSettings.defaultMode.rawValue
        terminalFontFamily = ""
        terminalFontSize = 0
        terminalThemeLight = ""
        terminalThemeDark = ""
        terminalBgOpacity = -1
        terminalCursorColor = ""
        terminalCursorStyle = ""
        terminalScrollback = 0
        terminalUnfocusedOpacity = -1
        terminalDividerColor = ""
        TerminalSettingsOverride.remove()
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
        pasteShelfCaptureText = PasteShelfCaptureSettings.defaultCaptureText
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
        Text(LocalizedStringKey(title))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, -2)
    }
}

struct SettingsCard<Content: View>: View {
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

/// A settings row.
///
/// Title and subtitle are `LocalizedStringKey`, not `String`, so the compiler
/// separates UI wording from data. When these were `String` the view turned
/// every one into a catalog key, which silently translated runtime values: a
/// peer named "Terminal" rendered as 터미널. Pass runtime text through the
/// `verbatim` initializers instead — the distinction is then checked, not
/// remembered.
struct SettingsCardRow<Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    let controlWidth: CGFloat?
    @ViewBuilder let trailing: Trailing

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: Text(title),
            subtitle: subtitle.map { Text($0) },
            controlWidth: controlWidth,
            trailing: trailing
        )
    }

    /// A translated title with a subtitle that carries runtime data (a path, a
    /// summary, a formatted count).
    init(
        _ title: LocalizedStringKey,
        verbatimSubtitle: String?,
        controlWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: Text(title),
            subtitle: verbatimSubtitle.map { Text(verbatim: $0) },
            controlWidth: controlWidth,
            trailing: trailing
        )
    }

    /// A row whose title is data — a device, project, model or role name.
    init(
        verbatim title: String,
        verbatimSubtitle: String? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: Text(verbatim: title),
            subtitle: verbatimSubtitle.map { Text(verbatim: $0) },
            controlWidth: controlWidth,
            trailing: trailing
        )
    }

    /// A data title with a translated subtitle (a "built-in" / "custom" tag).
    init(
        verbatim title: String,
        subtitle: LocalizedStringKey?,
        controlWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: Text(verbatim: title),
            subtitle: subtitle.map { Text($0) },
            controlWidth: controlWidth,
            trailing: trailing
        )
    }

    private init(
        title: Text,
        subtitle: Text?,
        controlWidth: CGFloat?,
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
                title
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    subtitle
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

struct SettingsCardDivider: View {
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

    @State private var profiles: [CliProfile] = []
    @State private var activeProfileId: UUID? = nil
    @State private var detectedCandidates: [String] = []
    @State private var recentPaths: [String] = []
    @State private var showManageSheet = false

    private var activeProfile: CliProfile? {
        profiles.first { $0.id == activeProfileId }
    }

    private var resolvedPath: String {
        if let exe = activeProfile?.executable, !exe.isEmpty { return exe }
        return detectedCandidates.first ?? ""
    }

    private var pathExists: Bool {
        !resolvedPath.isEmpty && FileManager.default.fileExists(atPath: resolvedPath)
    }

    var body: some View {
        SettingsCardRow(
            verbatim: label,
            verbatimSubtitle: resolvedPath.isEmpty
                ? LanguageSettings.localized("Not found")
                : resolvedPath
        ) {
            HStack(spacing: 6) {
                Circle()
                    .fill(resolvedPath.isEmpty ? Color.red : (pathExists ? Color.green : Color.red))
                    .frame(width: 8, height: 8)
                    .help(resolvedPath.isEmpty ? "Not found"
                          : (pathExists ? "Found" : "File not found at path"))

                Text(activeProfile?.name ?? "auto-detect")
                    .font(.system(size: 12))
                    .foregroundColor(activeProfileId == nil ? .secondary : .primary)
                    .frame(minWidth: 60, maxWidth: 120, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Menu {
                    if !profiles.isEmpty {
                        Section("Profiles") {
                            Picker(
                                selection: Binding<UUID?>(
                                    get: { activeProfileId },
                                    set: { id in
                                        guard let id,
                                              let p = profiles.first(where: { $0.id == id })
                                        else { return }
                                        activateProfile(p)
                                    }
                                )
                            ) {
                                ForEach(profiles) { p in
                                    Text(p.name).tag(Optional(p.id))
                                }
                            } label: { EmptyView() }
                                .pickerStyle(.inline)
                        }
                        Divider()
                    }
                    if !detectedCandidates.isEmpty {
                        Section("Detected") {
                            ForEach(detectedCandidates, id: \.self) { p in
                                Button(p) { useExecutable(p) }
                            }
                        }
                    }
                    if !recentPaths.isEmpty {
                        Section("Recent") {
                            ForEach(recentPaths, id: \.self) { p in
                                Button(p) { useExecutable(p) }
                            }
                        }
                    }
                    Divider()
                    Button("Browse…") { browse() }
                    Button("Manage Profiles…") { showManageSheet = true }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
        }
        .sheet(isPresented: $showManageSheet, onDismiss: refresh) {
            CLIProfileManageSheet(cliKey: cliKey, cliLabel: label)
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .cliActiveProfileChanged)) { _ in
            refresh()
        }
    }

    private func refresh() {
        profiles = CLIPathSettings.profiles(for: cliKey)
        activeProfileId = CLIPathSettings.activeProfile(for: cliKey)?.id
        detectedCandidates = Self.allCandidates(for: cliKey)
        recentPaths = CLIPathSettings.recent(for: cliKey)
    }

    private func activateProfile(_ profile: CliProfile) {
        CLIPathSettings.setActiveProfile(profile, for: cliKey)
        if !profile.executable.isEmpty {
            CLIPathSettings.addRecent(profile.executable, for: cliKey)
            path = profile.executable
        }
        refresh()
    }

    private func useExecutable(_ exe: String) {
        CLIPathSettings.addRecent(exe, for: cliKey)
        if var active = CLIPathSettings.activeProfile(for: cliKey) {
            active.executable = exe
            CliProfileStore.shared.save(active, for: cliKey)
            CLIPathSettings.setActiveProfile(active, for: cliKey)
        } else {
            let newProfile = CliProfile(name: "Default", family: cliKey, executable: exe)
            CliProfileStore.shared.save(newProfile, for: cliKey)
            CLIPathSettings.setActiveProfile(newProfile, for: cliKey)
        }
        path = exe
        refresh()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.presentAsSheet { response in
            if response == .OK, let url = panel.url {
                useExecutable(url.path)
            }
        }
    }

    private static func allCandidates(for cli: String) -> [String] {
        let home = NSHomeDirectory()
        let list: [String]
        switch cli {
        case "claude":
            list = [
                (home as NSString).appendingPathComponent(".local/bin/claude"),
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                (home as NSString).appendingPathComponent(".npm-global/bin/claude"),
                "/opt/homebrew/opt/node/bin/claude",
            ]
        case "kiro":
            list = [
                (home as NSString).appendingPathComponent(".local/bin/kiro-cli"),
                "/usr/local/bin/kiro-cli",
                "/opt/homebrew/bin/kiro-cli",
            ]
        case "codex":
            list = [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                (home as NSString).appendingPathComponent(".local/bin/codex"),
                (home as NSString).appendingPathComponent(".cargo/bin/codex"),
                (home as NSString).appendingPathComponent(".npm-global/bin/codex"),
                (home as NSString).appendingPathComponent(".volta/bin/codex"),
                "/opt/homebrew/opt/node/bin/codex",
            ]
        case "gemini":
            list = [
                "/opt/homebrew/bin/gemini",
                "/usr/local/bin/gemini",
                (home as NSString).appendingPathComponent(".local/bin/gemini"),
                (home as NSString).appendingPathComponent(".npm-global/bin/gemini"),
                (home as NSString).appendingPathComponent(".volta/bin/gemini"),
                "/opt/homebrew/opt/node/bin/gemini",
            ]
        default:
            list = []
        }
        return list.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

private struct CLIProfileManageSheet: View {
    let cliKey: String
    let cliLabel: String
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [CliProfile] = []
    @State private var activeId: UUID? = nil
    @State private var editingProfile: CliProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(cliLabel) Profiles")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if profiles.isEmpty {
                VStack(spacing: 8) {
                    Text("No profiles yet.")
                        .foregroundColor(.secondary)
                    Text("Add a profile to customize the executable, extra args, or environment variables.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(profiles) { profile in
                        HStack(spacing: 10) {
                            Button {
                                CLIPathSettings.setActiveProfile(profile, for: cliKey)
                                activeId = profile.id
                            } label: {
                                Image(systemName: activeId == profile.id
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(activeId == profile.id ? .accentColor : .secondary)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(profile.executable.isEmpty ? "auto-detect" : profile.executable)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !profile.extraArgs.isEmpty {
                                    Text("args: " + profile.extraArgs.joined(separator: " "))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()

                            Button("Edit") { editingProfile = profile }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                            Button(role: .destructive) { deleteProfile(profile) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                            .help("Delete \"\(profile.name)\"")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    editingProfile = CliProfile(name: "", family: cliKey, executable: "")
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 360)
        .onAppear { loadProfiles() }
        .sheet(item: $editingProfile, onDismiss: loadProfiles) { profile in
            CLIProfileEditView(profile: profile, cliKey: cliKey)
        }
    }

    private func loadProfiles() {
        profiles = CLIPathSettings.profiles(for: cliKey)
        activeId = CLIPathSettings.activeProfile(for: cliKey)?.id
    }

    private func deleteProfile(_ profile: CliProfile) {
        CliProfileStore.shared.delete(profile, for: cliKey)
        if activeId == profile.id {
            UserDefaults.standard.removeObject(forKey: "cliProfiles.active.\(cliKey)")
        }
        loadProfiles()
    }
}

private struct CLIProfileEditView: View {
    @State private var profile: CliProfile
    let cliKey: String
    let titleText: String
    @Environment(\.dismiss) private var dismiss

    @State private var extraArgsText = ""
    @State private var envText = ""

    private static let bannedArgs = [
        "--model", "--dangerously-skip-permissions", "--session-id",
        "--resume", "--print", "--append-system-prompt"
    ]

    private var hasBannedArgs: Bool {
        extraArgsText.split(separator: " ").contains { Self.bannedArgs.contains(String($0)) }
    }

    init(profile: CliProfile, cliKey: String) {
        _profile = State(initialValue: profile)
        self.cliKey = cliKey
        let exists = CliProfileStore.shared.profiles(for: cliKey).contains { $0.id == profile.id }
        self.titleText = exists ? "Edit Profile" : "Add Profile"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(titleText).font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fieldRow(label: "Name") {
                        TextField("e.g. Work, Opus Heavy", text: $profile.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }

                    fieldRow(label: "Executable") {
                        HStack(spacing: 6) {
                            TextField("auto-detect", text: $profile.executable)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            Button("Browse…") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = true
                                panel.canChooseDirectories = false
                                panel.allowsMultipleSelection = false
                                panel.treatsFilePackagesAsDirectories = true
                                panel.presentAsSheet { response in
                                    if response == .OK, let url = panel.url {
                                        profile.executable = url.path
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Extra Args")
                                .font(.system(size: 13, weight: .medium))
                            if hasBannedArgs {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                    .font(.system(size: 12))
                                    .help("Contains flags auto-injected by term-mesh:\n"
                                          + Self.bannedArgs.joined(separator: ", "))
                            }
                        }
                        TextField("e.g. --no-cache --timeout 60", text: $extraArgsText)
                            .textFieldStyle(.roundedBorder)
                        Text("Space-separated. Appended after term-mesh's built-in flags.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Environment Variables")
                            .font(.system(size: 13, weight: .medium))
                        TextEditor(text: $envText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 64, maxHeight: 96)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            )
                        Text("One KEY=VALUE per line.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    fieldRow(label: "Model Override") {
                        Picker("", selection: $profile.modelOverride) {
                            Text("None (use team default)").tag(Optional<String>.none)
                            Text("opus").tag(Optional<String>.some("opus"))
                            Text("sonnet").tag(Optional<String>.some("sonnet"))
                            Text("haiku").tag(Optional<String>.some("haiku"))
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Save") { saveAndDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .onAppear {
            extraArgsText = profile.extraArgs.joined(separator: " ")
            envText = profile.env
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
        }
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 120, alignment: .trailing)
            content()
            Spacer()
        }
    }

    private func saveAndDismiss() {
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.extraArgs = extraArgsText
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        profile.env = [:]
        for line in envText.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                profile.env[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        CliProfileStore.shared.save(profile, for: cliKey)
        dismiss()
    }
}

private struct WorktreeLogSection: View {
    @State private var fileSize = WorktreeLog.fileSizeFormatted
    @State private var lineCount = WorktreeLog.lineCount
    @State private var lastModified: String = ""
    @State private var tailPreview = ""
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Worktree Log")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 2)

            SettingsCard {
                SettingsCardRow("Log File", verbatimSubtitle: WorktreeLog.logFile.path) {
                    HStack(spacing: 8) {
                        Text(fileSize)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if lineCount > 0 {
                            Text("(\(lineCount) lines)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                SettingsCardDivider()

                SettingsCardRow(
                    "Last Modified",
                    verbatimSubtitle: lastModified.isEmpty
                        ? LanguageSettings.localized("No log yet")
                        : lastModified
                ) {
                    EmptyView()
                }

                SettingsCardDivider()

                HStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        let url = WorktreeLog.logFile
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(WorktreeLog.logDir)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(showPreview ? "Hide Preview" : "Preview") {
                        if !showPreview {
                            tailPreview = WorktreeLog.tail(30)
                        }
                        showPreview.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button("Clear Log") {
                        WorktreeLog.clear()
                        refresh()
                        tailPreview = ""
                        showPreview = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(lineCount == 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                if showPreview && !tailPreview.isEmpty {
                    SettingsCardDivider()
                    ScrollView(.vertical) {
                        Text(tailPreview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        fileSize = WorktreeLog.fileSizeFormatted
        lineCount = WorktreeLog.lineCount
        if let date = WorktreeLog.lastModified {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .medium
            lastModified = df.string(from: date)
        } else {
            lastModified = ""
        }
    }
}

private struct CLICustomModelsSection: View {
    let cli: String
    @State private var customModels: [String] = []
    @State private var newModelName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cli.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(AgentRolePreset.builtInModels(for: cli).count) built-in, \(customModels.count) custom")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 2)

            SettingsCard {
                // Built-in models (read-only)
                ForEach(AgentRolePreset.builtInModels(for: cli), id: \.self) { model in
                    SettingsCardRow(verbatim: model, subtitle: "built-in") {
                        EmptyView()
                    }
                    SettingsCardDivider()
                }

                // Custom models (editable)
                ForEach(customModels, id: \.self) { model in
                    SettingsCardRow(verbatim: model, subtitle: "custom") {
                        Button(role: .destructive) {
                            AgentRolePreset.removeCustomModel(model, for: cli)
                            customModels = AgentRolePreset.customModels(for: cli)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    SettingsCardDivider()
                }

                // Add new model row
                HStack(spacing: 8) {
                    TextField("e.g. gemini-2.5-pro-preview-06-05", text: $newModelName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        guard !newModelName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        AgentRolePreset.addCustomModel(newModelName, for: cli)
                        customModels = AgentRolePreset.customModels(for: cli)
                        newModelName = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .onAppear {
            customModels = AgentRolePreset.customModels(for: cli)
        }
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
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                (home as NSString).appendingPathComponent(".npm-global/bin/claude"),
                "/opt/homebrew/opt/node/bin/claude",
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
                (home as NSString).appendingPathComponent(".npm-global/bin/codex"),
                (home as NSString).appendingPathComponent(".volta/bin/codex"),
                "/opt/homebrew/opt/node/bin/codex",
            ]
        case "gemini":
            candidates = [
                "/opt/homebrew/bin/gemini",
                "/usr/local/bin/gemini",
                (home as NSString).appendingPathComponent(".local/bin/gemini"),
                (home as NSString).appendingPathComponent(".npm-global/bin/gemini"),
                (home as NSString).appendingPathComponent(".volta/bin/gemini"),
                "/opt/homebrew/opt/node/bin/gemini",
            ]
        case "cursor":
            // The binary is `cursor-agent`; plain `cursor` is the editor.
            candidates = [
                (home as NSString).appendingPathComponent(".local/bin/cursor-agent"),
                "/usr/local/bin/cursor-agent",
                "/opt/homebrew/bin/cursor-agent",
            ]
        case "agy":
            candidates = [
                (home as NSString).appendingPathComponent(".local/bin/agy"),
                "/usr/local/bin/agy",
                "/opt/homebrew/bin/agy",
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
        case .agentMode: return .blue
        }
    }
}

private struct ShellHealthEntry: Identifiable {
    let id: UUID
    let workspaceTitle: String
    let panelTitle: String
    let health: ShellIntegrationHealth
    /// True if this panel belongs to a team agent (TUI mode, shell integration N/A).
    let isAgentPanel: Bool
}

struct SettingsCardNote: View {
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
        /// The repository that registered this worktree, or nil if it is gone.
        let repoPath: String?
    }

    /// A delete the daemon refused because the worktree still holds work.
    struct ForceDeletePrompt: Identifiable {
        var id: String { worktree.id }
        let worktree: FoundWorktree
        let reason: String
    }

    @State private var worktrees: [FoundWorktree] = []
    @State private var isScanning = false
    @State private var hasScanResult = false
    @State private var confirmDelete: FoundWorktree? = nil
    @State private var confirmForceDelete: ForceDeletePrompt? = nil
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
                Button("Delete \"\(wt.name)\"", role: .destructive) { delete(wt) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let wt = confirmDelete {
                Text("This removes the worktree and its git registration:\n\(wt.path)\n\nA worktree with uncommitted changes is kept — you will be asked again before anything is discarded.")
            }
        }
        // A refused delete is a second, explicitly destructive decision: the
        // first dialog promised nothing would be discarded.
        .confirmationDialog(
            "Discard uncommitted work?",
            isPresented: Binding(
                get: { confirmForceDelete != nil },
                set: { if !$0 { confirmForceDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let prompt = confirmForceDelete {
                Button("Delete and discard changes", role: .destructive) {
                    forceDelete(prompt.worktree)
                }
                Button("Keep it", role: .cancel) {}
            }
        } message: {
            if let prompt = confirmForceDelete {
                Text("\(prompt.worktree.path)\n\n\(prompt.reason)\n\nDeleting now throws that work away permanently.")
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

    /// Delete through the daemon so git's own registration goes with the
    /// directory.
    ///
    /// Removing the directory alone — what this used to do — left the parent
    /// repo holding a `prunable` entry, which is why the dialog had to tell
    /// people to run `git worktree prune` themselves. The daemon refuses a
    /// worktree with uncommitted changes, and that refusal becomes the second
    /// confirmation rather than a silent failure.
    private func delete(_ wt: FoundWorktree) {
        confirmDelete = nil
        guard let repoPath = wt.repoPath else {
            // No repo left to ask: nothing can be registered anywhere, so the
            // directory is all there is.
            forceDelete(wt)
            return
        }
        let name = wt.name
        Task.detached(priority: .userInitiated) {
            let removed = TermMeshDaemon.shared.removeWorktree(
                repoPath: repoPath, name: name, force: false
            )
            let status = removed
                ? nil
                : TermMeshDaemon.shared.worktreeStatus(repoPath: repoPath, name: name)
            await MainActor.run {
                if removed {
                    worktrees.removeAll { $0.id == wt.id }
                    return
                }
                let reason = (status?.dirty ?? false)
                    ? "It has uncommitted changes."
                    : "The daemon refused to remove it."
                confirmForceDelete = ForceDeletePrompt(worktree: wt, reason: reason)
            }
        }
    }

    /// Last resort: discard the worktree even though git objected, and fall
    /// back to a plain directory delete when there is no repo to go through.
    private func forceDelete(_ wt: FoundWorktree) {
        confirmForceDelete = nil
        let path = wt.path
        let wtId = wt.id
        let repoPath = wt.repoPath
        let name = wt.name
        Task.detached(priority: .userInitiated) {
            if let repoPath,
               TermMeshDaemon.shared.removeWorktree(repoPath: repoPath, name: name, force: true) {
                await MainActor.run { worktrees.removeAll { $0.id == wtId } }
                return
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                await MainActor.run {
                    worktrees.removeAll { $0.id == wtId }
                    if repoPath != nil {
                        errorMessage = "Removed the directory only — run `git worktree prune` in the parent repo to clear its metadata."
                    }
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
                repoName: repoName,
                // Needed to delete through git rather than behind its back.
                // nil when the parent repo is gone, which the delete path
                // treats as its own case.
                repoPath: TermMeshDaemon.primaryRepoPath(
                    ofWorktreeAt: URL(fileURLWithPath: wtPath)
                )
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

enum SettingsNavigationUserInfoKey {
    static let section = "settingsSection"
}

extension Notification.Name {
    static let settingsNavigateToSection = Notification.Name("TermMeshSettingsNavigateToSection")
}

struct SettingsRootView: View {
    var body: some View {
        SettingsView()
            .termMeshLanguage()
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
