import AppKit
import SwiftUI
import Darwin

@main
struct TermMeshApp: App {
    @StateObject private var tabManager: TabManager
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var sidebarSelectionState = SidebarSelectionState()
    @ObservedObject private var termMeshDaemon = TermMeshDaemon.shared
    private let configProvider: any GhosttyConfigProvider = GhosttyApp.shared
    private let browserHistory: any BrowserHistoryService = BrowserHistoryStore.shared
    private let primaryWindowId = UUID()
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyle = TitlebarControlsStyle.classic.rawValue
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(KeyboardShortcutSettings.Action.toggleSidebar.defaultsKey) private var toggleSidebarShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newTab.defaultsKey) private var newWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newWindow.defaultsKey) private var newWindowShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.showNotifications.defaultsKey) private var showNotificationsShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.jumpToUnread.defaultsKey) private var jumpToUnreadShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.nextSurface.defaultsKey) private var nextSurfaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.prevSurface.defaultsKey) private var prevSurfaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.nextSidebarTab.defaultsKey) private var nextWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.prevSidebarTab.defaultsKey) private var prevWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.splitRight.defaultsKey) private var splitRightShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.splitDown.defaultsKey) private var splitDownShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.toggleBrowserDeveloperTools.defaultsKey)
    private var toggleBrowserDeveloperToolsShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.showBrowserJavaScriptConsole.defaultsKey)
    private var showBrowserJavaScriptConsoleShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.splitBrowserRight.defaultsKey) private var splitBrowserRightShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.splitBrowserDown.defaultsKey) private var splitBrowserDownShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.renameWorkspace.defaultsKey) private var renameWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.closeWorkspace.defaultsKey) private var closeWorkspaceShortcutData = Data()
    @AppStorage(TermMeshDaemon.worktreeAutoCleanupKey) private var worktreeAutoCleanup = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var showTeamCreation = false
    /// TabManager captured at menu-click time (before sheet steals key window).
    @State private var teamCreationTabManager: TabManager?
    @State private var ghosttyTheme = GhosttyTheme.current

    init() {
        Self.configureGhosttyEnvironment()

        let startupAppearance = AppearanceSettings.resolvedMode()
        Self.applyAppearance(startupAppearance)
        _tabManager = StateObject(wrappedValue: TabManager(
            daemon: TermMeshDaemon.shared,
            notifications: TerminalNotificationStore.shared
        ))
        // Migrate legacy and old-format socket mode values to the new enum.
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: SocketControlSettings.appStorageKey) {
            let migrated = SocketControlSettings.migrateMode(stored)
            if migrated.rawValue != stored {
                defaults.set(migrated.rawValue, forKey: SocketControlSettings.appStorageKey)
            }
        } else if let legacy = defaults.object(forKey: SocketControlSettings.legacyEnabledKey) as? Bool {
            defaults.set(legacy ? SocketControlMode.termMeshOnly.rawValue : SocketControlMode.off.rawValue,
                         forKey: SocketControlSettings.appStorageKey)
        }
        migrateSidebarAppearanceDefaultsIfNeeded(defaults: defaults)

        // UI tests depend on AppDelegate wiring happening even if SwiftUI view appearance
        // callbacks (e.g. `.onAppear`) are delayed or skipped.
        appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
    }

    private static func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let bundledGhosttyURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty")
        var resolvedResourcesDir: String?

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.path),
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                resolvedResourcesDir = ghosttyAppResources
            } else if let bundledGhosttyURL, fileManager.fileExists(atPath: bundledGhosttyURL.path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            }

            if let resolvedResourcesDir {
                setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
            }
        }

        if getenv("TERM") == nil {
            setenv("TERM", "xterm-ghostty", 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            let resourcesParent = resourcesURL.deletingLastPathComponent()
            let dataDir = resourcesParent.path
            let manDir = resourcesParent.appendingPathComponent("man").path

            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: dataDir,
                defaultValue: "/usr/local/share:/usr/share"
            )
            appendEnvPathIfMissing("MANPATH", path: manDir)
        }
    }

    private static func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }
        var current = getenv(key).flatMap { String(cString: $0) } ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }
        let updated = current.isEmpty ? path : "\(current):\(path)"
        setenv(key, updated, 1)
    }

    private func migrateSidebarAppearanceDefaultsIfNeeded(defaults: UserDefaults) {
        let migrationKey = "sidebarAppearanceDefaultsVersion"
        let targetVersion = 1
        guard defaults.integer(forKey: migrationKey) < targetVersion else { return }

        func normalizeHex(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "#", with: "")
                .uppercased()
        }

        func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
            abs(lhs - rhs) <= tolerance
        }

        let material = defaults.string(forKey: "sidebarMaterial") ?? SidebarMaterialOption.sidebar.rawValue
        let blendMode = defaults.string(forKey: "sidebarBlendMode") ?? SidebarBlendModeOption.behindWindow.rawValue
        let state = defaults.string(forKey: "sidebarState") ?? SidebarStateOption.followWindow.rawValue
        let tintHex = defaults.string(forKey: "sidebarTintHex") ?? "#101010"
        let tintOpacity = defaults.object(forKey: "sidebarTintOpacity") as? Double ?? 0.54
        let blurOpacity = defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 0.79
        let cornerRadius = defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0.0

        let usesLegacyDefaults =
            material == SidebarMaterialOption.sidebar.rawValue &&
            blendMode == SidebarBlendModeOption.behindWindow.rawValue &&
            state == SidebarStateOption.followWindow.rawValue &&
            normalizeHex(tintHex) == "101010" &&
            approximatelyEqual(tintOpacity, 0.54) &&
            approximatelyEqual(blurOpacity, 0.79) &&
            approximatelyEqual(cornerRadius, 0.0)

        if usesLegacyDefaults {
            let preset = SidebarPresetOption.nativeSidebar
            defaults.set(preset.rawValue, forKey: "sidebarPreset")
            defaults.set(preset.material.rawValue, forKey: "sidebarMaterial")
            defaults.set(preset.blendMode.rawValue, forKey: "sidebarBlendMode")
            defaults.set(preset.state.rawValue, forKey: "sidebarState")
            defaults.set(preset.tintHex, forKey: "sidebarTintHex")
            defaults.set(preset.tintOpacity, forKey: "sidebarTintOpacity")
            defaults.set(preset.blurOpacity, forKey: "sidebarBlurOpacity")
            defaults.set(preset.cornerRadius, forKey: "sidebarCornerRadius")
        }

        defaults.set(targetVersion, forKey: migrationKey)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(updateViewModel: appDelegate.updateViewModel, windowId: primaryWindowId)
                .environmentObject(tabManager)
                .environmentObject(notificationStore)
                .environmentObject(sidebarState)
                .environmentObject(sidebarSelectionState)
                .environment(\.ghosttyTheme, ghosttyTheme)
                .withServices()
                .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
                    ghosttyTheme = .current
                }
                .onAppear {
#if DEBUG
                    if termMeshEnv("UI_TEST_MODE") == "1" {
                        UpdateLogStore.shared.append("ui test: TermMeshApp onAppear")
                    }
#endif
                    // Start the Unix socket controller for programmatic access
                    updateSocketController()
                    appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
                    applyAppearance()
                    if termMeshEnv("UI_TEST_SHOW_SETTINGS") == "1" {
                        DispatchQueue.main.async {
                            showSettingsPanel()
                        }
                    }
                }
                .onChange(of: appearanceMode) { _ in
                    applyAppearance()
                    // Write terminal color override and reload Ghostty config
                    TerminalThemeOverride.write(for: appearanceMode)
                    configProvider.reloadConfiguration(source: "appearance.toggle")
                }
                .onChange(of: socketControlMode) { _ in
                    updateSocketController()
                }
                .onReceive(NotificationCenter.default.publisher(for: .teamCreationRequested)) { _ in
                    if let kw = NSApp.keyWindow, let ctx = AppDelegate.shared?.contextForMainWindow(kw) {
                        teamCreationTabManager = ctx.tabManager
                    } else if let mw = NSApp.mainWindow, let ctx = AppDelegate.shared?.contextForMainWindow(mw) {
                        teamCreationTabManager = ctx.tabManager
                    } else {
                        teamCreationTabManager = nil
                    }
                    showTeamCreation = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .spawnCLIRequested)) { _ in
                    showSpawnCLIDialog()
                }
                .sheet(isPresented: $showTeamCreation) {
                    TeamCreationView { teamName, leaderMode, leaderModel, agents, worktreeMode in
                        let agentTuples = agents.map { row in
                            (
                                name: row.preset.name,
                                cli: row.preset.cli,
                                model: row.preset.model,
                                agentType: row.preset.name,
                                color: row.preset.color,
                                instructions: row.customInstructions.isEmpty
                                    ? row.preset.instructions
                                    : row.customInstructions
                            )
                        }
                        // Use the TabManager captured at menu-click time (before
                        // the sheet stole key window focus).
                        let activeTabManager = teamCreationTabManager ?? tabManager
                        let workDir = activeTabManager.selectedTab?.currentDirectory
                            ?? FileManager.default.currentDirectoryPath
                        _ = TeamOrchestrator.shared.createTeam(
                            name: teamName,
                            agents: agentTuples,
                            workingDirectory: workDir,
                            leaderSessionId: UUID().uuidString,
                            leaderMode: leaderMode,
                            leaderModel: leaderModel,
                            worktreeMode: worktreeMode,
                            tabManager: activeTabManager
                        )
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // MARK: - Agents Menu (combined agents + worktrees)
            CommandMenu("Agents") {
                // -- Create --
                Button("New Agent Team…") {
                    // Capture the key window's TabManager NOW, before the sheet steals focus.
                    if let kw = NSApp.keyWindow, let ctx = AppDelegate.shared?.contextForMainWindow(kw) {
                        teamCreationTabManager = ctx.tabManager
                    } else if let mw = NSApp.mainWindow, let ctx = AppDelegate.shared?.contextForMainWindow(mw) {
                        teamCreationTabManager = ctx.tabManager
                    } else {
                        teamCreationTabManager = nil
                    }
                    showTeamCreation = true
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button("Spawn CLI…") {
                    showSpawnCLIDialog()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                // -- Manage --
                Divider()

                Button("Reconnect Agent…") {
                    showReconnectAgentDialog()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])

                Button("Destroy Team…") {
                    showDestroyTeamDialog()
                }

                Button("Collect All Results") {
                    showCollectResultsDialog()
                }

                // -- Worktrees --
                Divider()

                Button("New Worktree Workspace") {
                    NotificationCenter.default.post(name: .worktreeWorkspaceRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])

                Button(termMeshDaemon.worktreeEnabled
                    ? "✓ Worktree Sandbox"
                    : "  Worktree Sandbox"
                ) {
                    let newValue = !termMeshDaemon.worktreeEnabled
                    termMeshDaemon.worktreeEnabled = newValue
                    if newValue {
                        DispatchQueue.global(qos: .utility).async { [daemon = self.termMeshDaemon] in
                            let connected = daemon.ping()
                            if !connected {
                                DispatchQueue.main.async {
                                    let alert = NSAlert()
                                    alert.messageText = "Worktree Sandbox"
                                    alert.informativeText = "term-meshd daemon is not running.\nNew tabs will open without sandbox until the daemon is started."
                                    alert.alertStyle = .warning
                                    alert.addButton(withTitle: "OK")
                                    alert.runModal()
                                }
                            }
                        }
                    }
                }

                Toggle("Worktree Auto-Cleanup", isOn: $worktreeAutoCleanup)

                Divider()

                Button("Clean Up Stale Worktrees") {
                    cleanupStaleWorktrees()
                }

                Button("Open Worktree Directory…") {
                    let path = termMeshDaemon.worktreeBaseDir
                    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    showSettingsPanel()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .appInfo) {
                Button("About Term-Mesh") {
                    showAboutPanel()
                }
                Button("Welcome Screen") {
                    UserDefaults.standard.set(false, forKey: "hideWelcomeScreen")
                }
                Divider()
                Button("Ghostty Settings…") {
                    configProvider.openConfigurationInTextEdit()
                }
                Button("Reload Configuration") {
                    configProvider.reloadConfiguration(source: "menu.reload_configuration")
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                Divider()
                Button("Check for Updates…") {
                    appDelegate.checkForUpdates(nil)
                }
                InstallUpdateMenuItem(model: appDelegate.updateViewModel)
                Divider()
                Button("Term-Mesh Dashboard (Window)") {
                    DashboardController.shared.showDashboard()
                }
                Button("Term-Mesh Dashboard (Split)") {
                    openDashboardSplit()
                }
            }

#if DEBUG
            CommandMenu("Update Pill") {
                Button("Show Update Pill") {
                    appDelegate.showUpdatePill(nil)
                }
                Button("Show Long Nightly Pill") {
                    appDelegate.showUpdatePillLongNightly(nil)
                }
                Button("Show Loading State") {
                    appDelegate.showUpdatePillLoading(nil)
                }
                Button("Hide Update Pill") {
                    appDelegate.hideUpdatePill(nil)
                }
                Button("Automatic Update Pill") {
                    appDelegate.clearUpdatePillOverride(nil)
                }
            }
#endif

            CommandMenu("Update Logs") {
                Button("Copy Update Logs") {
                    appDelegate.copyUpdateLogs(nil)
                }
                Button("Copy Focus Logs") {
                    appDelegate.copyFocusLogs(nil)
                }
            }

            CommandMenu("Notifications") {
                let snapshot = notificationMenuSnapshot

                Button(snapshot.stateHintTitle) {}
                    .disabled(true)

                if !snapshot.recentNotifications.isEmpty {
                    Divider()

                    ForEach(snapshot.recentNotifications) { notification in
                        Button(notificationMenuItemTitle(for: notification)) {
                            openNotificationFromMainMenu(notification)
                        }
                    }

                    Divider()
                }

                splitCommandButton(title: "Show Notifications", shortcut: showNotificationsMenuShortcut) {
                    showNotificationsPopover()
                }

                splitCommandButton(title: "Jump to Latest Unread", shortcut: jumpToUnreadMenuShortcut) {
                    appDelegate.jumpToLatestUnread()
                }
                .disabled(!snapshot.hasUnreadNotifications)

                Button("Mark All Read") {
                    notificationStore.markAllRead()
                }
                .disabled(!snapshot.hasUnreadNotifications)

                Button("Clear All") {
                    notificationStore.clearAll()
                }
                .disabled(!snapshot.hasNotifications)
            }

#if DEBUG
            CommandMenu("Debug") {
                Button("New Tab With Lorem Search Text") {
                    appDelegate.openDebugLoremTab(nil)
                }

                Button("New Tab With Large Scrollback") {
                    appDelegate.openDebugScrollbackTab(nil)
                }

                Button("Open Workspaces for All Tab Colors") {
                    appDelegate.openDebugColorComparisonWorkspaces(nil)
                }

                Divider()
                Menu("Debug Windows") {
                    Button("Debug Window Controls…") {
                        DebugWindowControlsWindowController.shared.show()
                    }

                    Button("Settings/About Titlebar Debug…") {
                        SettingsAboutTitlebarDebugWindowController.shared.show()
                    }

                    Divider()
                    Button("Sidebar Debug…") {
                        SidebarDebugWindowController.shared.show()
                    }

                    Button("Background Debug…") {
                        BackgroundDebugWindowController.shared.show()
                    }

                    Button("Menu Bar Extra Debug…") {
                        MenuBarExtraDebugWindowController.shared.show()
                    }

                    Divider()

                    Button("Open All Debug Windows") {
                        openAllDebugWindows()
                    }
                }

                Toggle("Always Show Shortcut Hints", isOn: $alwaysShowShortcutHints)

                Divider()

                Picker("Titlebar Controls Style", selection: $titlebarControlsStyle) {
                    ForEach(TitlebarControlsStyle.allCases) { style in
                        Text(style.menuTitle).tag(style.rawValue)
                    }
                }

                Divider()

                Button("Trigger Sentry Test Crash") {
                    appDelegate.triggerSentryTestCrash(nil)
                }
            }
#endif

            // MARK: - File & Navigation Commands
            Group {
            CommandGroup(replacing: .newItem) {
                splitCommandButton(title: "New Window", shortcut: newWindowMenuShortcut) {
                    appDelegate.openNewMainWindow(nil)
                }

                splitCommandButton(title: "New Workspace", shortcut: newWorkspaceMenuShortcut) {
                    activeTabManager.addTab()
                }
            }

            // Close tab/workspace
            CommandGroup(after: .newItem) {
                Button("Go to Workspace or Tab…") {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: targetWindow)
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button("Command Palette…") {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteRequested, object: targetWindow)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                // Terminal semantics:
                // Cmd+W closes the focused tab (with confirmation if needed). If this is the last
                // tab in the last workspace, it closes the window.
                Button("Close Tab") {
                    closePanelOrWindow()
                }
                .keyboardShortcut("w", modifiers: .command)

                // Cmd+Shift+W closes the current workspace (with confirmation if needed). If this
                // is the last workspace, it closes the window.
                splitCommandButton(title: "Close Workspace", shortcut: closeWorkspaceMenuShortcut) {
                    closeTabOrWindow()
                }

                Button("Reopen Closed Browser Panel") {
                    _ = activeTabManager.reopenMostRecentlyClosedBrowserPanel()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            // Find
            CommandGroup(after: .textEditing) {
                Menu("Find") {
                    Button("Find…") {
                        activeTabManager.startSearch()
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button("Find Next") {
                        activeTabManager.findNext()
                    }
                    .keyboardShortcut("g", modifiers: .command)

                    Button("Find Previous") {
                        activeTabManager.findPrevious()
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Divider()

                    Button("Hide Find Bar") {
                        activeTabManager.hideFind()
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!(activeTabManager.isFindVisible))

                    Divider()

                    Button("Use Selection for Find") {
                        activeTabManager.searchSelection()
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!(activeTabManager.canUseSelectionForFind))
                }

                Divider()

                Button("IME Input Bar") {
                    activeTabManager.toggleIMEInputBar()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            // Tab navigation
            CommandGroup(after: .toolbar) {
                splitCommandButton(title: "Toggle Sidebar", shortcut: toggleSidebarMenuShortcut) {
                    if AppDelegate.shared?.toggleSidebarInActiveMainWindow() != true {
                        sidebarState.toggle()
                    }
                }

                Divider()

                splitCommandButton(title: "Next Surface", shortcut: nextSurfaceMenuShortcut) {
                    activeTabManager.selectNextSurface()
                }

                splitCommandButton(title: "Previous Surface", shortcut: prevSurfaceMenuShortcut) {
                    activeTabManager.selectPreviousSurface()
                }

                Button("Back") {
                    activeTabManager.focusedBrowserPanel?.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    activeTabManager.focusedBrowserPanel?.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Reload Page") {
                    activeTabManager.focusedBrowserPanel?.reload()
                }
                .keyboardShortcut("r", modifiers: .command)

                splitCommandButton(title: "Toggle Developer Tools", shortcut: toggleBrowserDeveloperToolsMenuShortcut) {
                    let manager = activeTabManager
                    if !manager.toggleDeveloperToolsFocusedBrowser() {
                        NSSound.beep()
                    }
                }

                splitCommandButton(title: "Show JavaScript Console", shortcut: showBrowserJavaScriptConsoleMenuShortcut) {
                    let manager = activeTabManager
                    if !manager.showJavaScriptConsoleFocusedBrowser() {
                        NSSound.beep()
                    }
                }

                Button("Zoom In") {
                    _ = activeTabManager.zoomInFocusedBrowser()
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    _ = activeTabManager.zoomOutFocusedBrowser()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    _ = activeTabManager.resetZoomFocusedBrowser()
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Clear Browser History") {
                    browserHistory.clearHistory()
                }

                splitCommandButton(title: "Next Workspace", shortcut: nextWorkspaceMenuShortcut) {
                    activeTabManager.selectNextTab()
                }

                splitCommandButton(title: "Previous Workspace", shortcut: prevWorkspaceMenuShortcut) {
                    activeTabManager.selectPreviousTab()
                }

                splitCommandButton(title: "Rename Workspace…", shortcut: renameWorkspaceMenuShortcut) {
                    _ = AppDelegate.shared?.promptRenameSelectedWorkspace()
                }

                Divider()

                // Split shortcuts are handled by AppDelegate's local NSEvent monitor.
                // Registering them as SwiftUI .keyboardShortcut() causes the menu
                // system to process the shortcut independently, which can trigger
                // WindowGroup to create a duplicate window.
                splitCommandButton(title: "Split Right", shortcut: splitRightMenuShortcut, registerShortcut: false) {
                    performSplitFromMenu(direction: .right)
                }

                splitCommandButton(title: "Split Down", shortcut: splitDownMenuShortcut, registerShortcut: false) {
                    performSplitFromMenu(direction: .down)
                }

                splitCommandButton(title: "Split Browser Right", shortcut: splitBrowserRightMenuShortcut, registerShortcut: false) {
                    performBrowserSplitFromMenu(direction: .right)
                }

                splitCommandButton(title: "Split Browser Down", shortcut: splitBrowserDownMenuShortcut, registerShortcut: false) {
                    performBrowserSplitFromMenu(direction: .down)
                }

                Divider()

                // Cmd+1 through Cmd+9 for workspace selection (9 = last workspace)
                ForEach(1...9, id: \.self) { number in
                    Button("Workspace \(number)") {
                        let manager = activeTabManager
                        if let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: number, workspaceCount: manager.tabs.count) {
                            manager.selectTab(at: targetIndex)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }

                Divider()

                splitCommandButton(title: "Jump to Latest Unread", shortcut: jumpToUnreadMenuShortcut) {
                    AppDelegate.shared?.jumpToLatestUnread()
                }

                splitCommandButton(title: "Show Notifications", shortcut: showNotificationsMenuShortcut) {
                    showNotificationsPopover()
                }
            }
            } // Group: File & Navigation Commands
        }
    }

    private func showAboutPanel() {
        AboutWindowController.shared.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettingsPanel() {
        SettingsWindowController.shared.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppearance() {
        let mode = AppearanceSettings.mode(for: appearanceMode)
        if appearanceMode != mode.rawValue {
            appearanceMode = mode.rawValue
        }
        Self.applyAppearance(mode)
    }

    private static func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .auto:
            NSApplication.shared.appearance = nil
        }
    }

    private func updateSocketController() {
        let mode = SocketControlSettings.effectiveMode(userMode: currentSocketMode)
        if mode != .off {
            TerminalController.shared.start(
                tabManager: tabManager,
                socketPath: SocketControlSettings.socketPath(),
                accessMode: mode
            )
        } else {
            TerminalController.shared.stop()
        }
    }

    private var currentSocketMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    private var splitRightMenuShortcut: StoredShortcut {
        decodeShortcut(from: splitRightShortcutData, fallback: KeyboardShortcutSettings.Action.splitRight.defaultShortcut)
    }

    private var toggleSidebarMenuShortcut: StoredShortcut {
        decodeShortcut(from: toggleSidebarShortcutData, fallback: KeyboardShortcutSettings.Action.toggleSidebar.defaultShortcut)
    }

    private var newWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(from: newWorkspaceShortcutData, fallback: KeyboardShortcutSettings.Action.newTab.defaultShortcut)
    }

    private var newWindowMenuShortcut: StoredShortcut {
        decodeShortcut(from: newWindowShortcutData, fallback: KeyboardShortcutSettings.Action.newWindow.defaultShortcut)
    }

    private var showNotificationsMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: showNotificationsShortcutData,
            fallback: KeyboardShortcutSettings.Action.showNotifications.defaultShortcut
        )
    }

    private var jumpToUnreadMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: jumpToUnreadShortcutData,
            fallback: KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut
        )
    }

    private var nextSurfaceMenuShortcut: StoredShortcut {
        decodeShortcut(from: nextSurfaceShortcutData, fallback: KeyboardShortcutSettings.Action.nextSurface.defaultShortcut)
    }

    private var prevSurfaceMenuShortcut: StoredShortcut {
        decodeShortcut(from: prevSurfaceShortcutData, fallback: KeyboardShortcutSettings.Action.prevSurface.defaultShortcut)
    }

    private var nextWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: nextWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        )
    }

    private var prevWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: prevWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        )
    }

    private var splitDownMenuShortcut: StoredShortcut {
        decodeShortcut(from: splitDownShortcutData, fallback: KeyboardShortcutSettings.Action.splitDown.defaultShortcut)
    }

    private var toggleBrowserDeveloperToolsMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: toggleBrowserDeveloperToolsShortcutData,
            fallback: KeyboardShortcutSettings.Action.toggleBrowserDeveloperTools.defaultShortcut
        )
    }

    private var showBrowserJavaScriptConsoleMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: showBrowserJavaScriptConsoleShortcutData,
            fallback: KeyboardShortcutSettings.Action.showBrowserJavaScriptConsole.defaultShortcut
        )
    }

    private var splitBrowserRightMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: splitBrowserRightShortcutData,
            fallback: KeyboardShortcutSettings.Action.splitBrowserRight.defaultShortcut
        )
    }

    private var splitBrowserDownMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: splitBrowserDownShortcutData,
            fallback: KeyboardShortcutSettings.Action.splitBrowserDown.defaultShortcut
        )
    }

    private var renameWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: renameWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        )
    }

    private var closeWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: closeWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        )
    }

    private var notificationMenuSnapshot: NotificationMenuSnapshot {
        NotificationMenuSnapshotBuilder.make(notifications: notificationStore.notifications)
    }

    private var activeTabManager: TabManager {
        AppDelegate.shared?.synchronizeActiveMainWindowContext(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        ) ?? tabManager
    }

    private func decodeShortcut(from data: Data, fallback: StoredShortcut) -> StoredShortcut {
        guard !data.isEmpty,
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return fallback
        }
        return shortcut
    }

    private func notificationMenuItemTitle(for notification: TerminalNotification) -> String {
        let tabTitle = appDelegate.tabTitle(for: notification.tabId)
        return MenuBarNotificationLineFormatter.menuTitle(notification: notification, tabTitle: tabTitle)
    }

    private func openNotificationFromMainMenu(_ notification: TerminalNotification) {
        _ = appDelegate.openNotification(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            notificationId: notification.id
        )
    }

    private func performSplitFromMenu(direction: SplitDirection) {
        if AppDelegate.shared?.performSplitShortcut(direction: direction) == true {
            return
        }
        tabManager.createSplit(direction: direction)
    }

    private func performBrowserSplitFromMenu(direction: SplitDirection) {
        if AppDelegate.shared?.performBrowserSplitShortcut(direction: direction) == true {
            return
        }
        _ = tabManager.createBrowserSplit(direction: direction)
    }

    private func openDashboardSplit() {
        let port = ProcessInfo.processInfo.environment["TERM_MESH_HTTP_ADDR"]
            .flatMap { $0.split(separator: ":").last.map(String.init) } ?? "9876"
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        _ = activeTabManager.createBrowserSplit(direction: .right, url: url)
    }

    private func cleanupStaleWorktrees() {
        let repoPath = activeTabManager.selectedWorkspace?.worktreeRepoPath
            ?? termMeshDaemon.findGitRoot(from: FileManager.default.currentDirectoryPath)
            ?? FileManager.default.currentDirectoryPath
        DispatchQueue.global(qos: .utility).async { [daemon = self.termMeshDaemon] in
            let result = daemon.cleanupStaleWorktrees(repoPath: repoPath)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .informational
                if result.removed == 0 && result.skippedDirty == 0 {
                    alert.messageText = "No Stale Worktrees"
                    alert.informativeText = "All worktrees are either active or already cleaned up."
                } else {
                    alert.messageText = "Worktree Cleanup Complete"
                    var info = "Removed \(result.removed) stale worktree\(result.removed == 1 ? "" : "s")."
                    if result.skippedDirty > 0 {
                        info += "\nSkipped \(result.skippedDirty) dirty worktree\(result.skippedDirty == 1 ? "" : "s") (uncommitted changes)."
                    }
                    alert.informativeText = info
                }
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func showDestroyTeamDialog() {
        let teamList = TeamOrchestrator.shared.listTeams()
        guard !teamList.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Destroy Team"
            alert.informativeText = "No active teams found."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Destroy Team"
        alert.informativeText = "Select a team to destroy. This will close all agent panes and clean up worktrees."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Destroy")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        for team in teamList {
            let name = team["team_name"] as? String ?? "unknown"
            let count = team["agent_count"] as? Int ?? 0
            popup.addItem(withTitle: "\(name) (\(count) agents)")
            popup.lastItem?.representedObject = name as NSString
        }
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn,
              let teamName = popup.selectedItem?.representedObject as? String else { return }

        _ = TeamOrchestrator.shared.destroyTeam(name: teamName, tabManager: activeTabManager)
    }

    private func showCollectResultsDialog() {
        let teamList = TeamOrchestrator.shared.listTeams()
        guard !teamList.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Collect Results"
            alert.informativeText = "No active teams found."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // If single team, use it directly; otherwise show picker
        let teamName: String
        if teamList.count == 1 {
            teamName = teamList[0]["team_name"] as? String ?? ""
        } else {
            let alert = NSAlert()
            alert.messageText = "Collect Results"
            alert.informativeText = "Select a team:"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Collect")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
            for team in teamList {
                let name = team["team_name"] as? String ?? "unknown"
                let count = team["agent_count"] as? Int ?? 0
                popup.addItem(withTitle: "\(name) (\(count) agents)")
                popup.lastItem?.representedObject = name as NSString
            }
            alert.accessoryView = popup

            guard alert.runModal() == .alertFirstButtonReturn,
                  let selected = popup.selectedItem?.representedObject as? String else { return }
            teamName = selected
        }

        let status = TeamOrchestrator.shared.resultStatus(teamName: teamName)
        let total = status["total"] as? Int ?? 0
        let completed = status["completed"] as? Int ?? 0
        let agents = status["agents"] as? [[String: Any]] ?? []

        let resultAlert = NSAlert()
        resultAlert.alertStyle = .informational
        resultAlert.messageText = "Results — \(teamName)"

        var lines: [String] = ["\(completed)/\(total) agents submitted results.\n"]
        for agent in agents {
            let name = agent["name"] as? String ?? "?"
            let done = agent["has_result"] as? Bool ?? false
            lines.append("  \(done ? "✅" : "⏳") \(name)")
        }
        let dir = TeamOrchestrator.resultDirectory(teamName: teamName)
        lines.append("\nResults directory:\n\(dir)")
        resultAlert.informativeText = lines.joined(separator: "\n")

        resultAlert.addButton(withTitle: "Open in Finder")
        resultAlert.addButton(withTitle: "OK")

        if resultAlert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir, isDirectory: true))
        }
    }

    private static let spawnCLILastCommandKey = "spawnCLILastCommand"
    private static let spawnCLILastOptionsKey = "spawnCLILastOptions"
    private static let spawnCLILastCountKey = "spawnCLILastCount"
    private static let spawnCLILastWorktreeKey = "spawnCLILastWorktree"
    private static let spawnCLILastNewWorkspaceKey = "spawnCLILastNewWorkspace"

    private func showSpawnCLIDialog() {
        let alert = NSAlert()
        alert.messageText = "Spawn CLI"
        alert.informativeText = "Create multiple terminal panes in a grid layout:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        // Build available commands from CLI path settings
        let cliNames = ["claude", "kiro", "codex", "gemini"]
        var availableCommands: [String] = ["(shell only)"]
        for cli in cliNames {
            if CLIPathSettings.resolvedPath(for: cli) != nil {
                availableCommands.append(cli)
            }
        }

        // Restore last selections
        let lastCommand = UserDefaults.standard.string(forKey: Self.spawnCLILastCommandKey) ?? "(shell only)"
        let lastOptions = UserDefaults.standard.string(forKey: Self.spawnCLILastOptionsKey) ?? ""
        let lastCount = UserDefaults.standard.integer(forKey: Self.spawnCLILastCountKey)
        let lastWorktree = UserDefaults.standard.bool(forKey: Self.spawnCLILastWorktreeKey)
        let lastNewWorkspace = UserDefaults.standard.bool(forKey: Self.spawnCLILastNewWorkspaceKey)

        let lastLoginShell = UserDefaults.standard.object(forKey: "shellLoginMode") as? String ?? "login"

        let rowH: CGFloat = 28
        var y: CGFloat = rowH * 6 + 4  // 7 rows

        // -- Command popup --
        y -= rowH
        let commandLabel = NSTextField(labelWithString: "Command:")
        commandLabel.frame = NSRect(x: 0, y: y + 2, width: 80, height: 18)

        let commandCombo = NSComboBox(frame: NSRect(x: 84, y: y - 2, width: 250, height: 26))
        for cmd in availableCommands { commandCombo.addItem(withObjectValue: cmd) }
        if let idx = availableCommands.firstIndex(of: lastCommand) {
            commandCombo.selectItem(at: idx)
        } else {
            commandCombo.selectItem(at: 0)
        }
        commandCombo.completes = true

        // -- Options field --
        y -= rowH
        let optionsLabel = NSTextField(labelWithString: "Options:")
        optionsLabel.frame = NSRect(x: 0, y: y + 2, width: 80, height: 18)

        let optionsField = NSTextField(frame: NSRect(x: 84, y: y, width: 250, height: 22))
        optionsField.placeholderString = "e.g. --dangerously-skip-permissions"
        optionsField.stringValue = lastOptions

        // -- Count stepper --
        y -= rowH
        let countLabel = NSTextField(labelWithString: "Terminals:")
        countLabel.frame = NSRect(x: 0, y: y + 2, width: 80, height: 18)

        let stepper = NSStepper(frame: NSRect(x: 84, y: y, width: 26, height: 22))
        stepper.minValue = 1
        stepper.maxValue = 12
        stepper.integerValue = lastCount > 0 ? lastCount : 3
        stepper.valueWraps = false

        let countValueLabel = NSTextField(labelWithString: "\(stepper.integerValue)")
        countValueLabel.frame = NSRect(x: 114, y: y + 2, width: 30, height: 18)
        countValueLabel.alignment = .center

        stepper.target = countValueLabel
        stepper.action = #selector(NSTextField.takeIntegerValueFrom(_:))

        // -- New Workspace checkbox --
        y -= rowH
        let newWorkspaceCheck = NSButton(checkboxWithTitle: "Open in new workspace", target: nil, action: nil)
        newWorkspaceCheck.frame = NSRect(x: 0, y: y, width: 300, height: 20)
        newWorkspaceCheck.state = lastNewWorkspace ? .on : .off

        // -- Worktree checkbox --
        y -= rowH
        let worktreeCheck = NSButton(checkboxWithTitle: "Use separate worktrees (git)", target: nil, action: nil)
        worktreeCheck.frame = NSRect(x: 0, y: y, width: 300, height: 20)
        worktreeCheck.state = lastWorktree ? .on : .off

        // -- Login Shell checkbox --
        y -= rowH
        let loginShellCheck = NSButton(checkboxWithTitle: "Login shell (load .profile/.zshrc)", target: nil, action: nil)
        loginShellCheck.frame = NSRect(x: 0, y: y, width: 300, height: 20)
        loginShellCheck.state = lastLoginShell == "login" ? .on : .off

        let totalHeight = rowH * 6 + 4
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: totalHeight))
        container.addSubview(commandLabel)
        container.addSubview(commandCombo)
        container.addSubview(optionsLabel)
        container.addSubview(optionsField)
        container.addSubview(countLabel)
        container.addSubview(stepper)
        container.addSubview(countValueLabel)
        container.addSubview(newWorkspaceCheck)
        container.addSubview(worktreeCheck)
        container.addSubview(loginShellCheck)
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let count = stepper.integerValue
        let useWorktree = worktreeCheck.state == .on
        let useNewWorkspace = newWorkspaceCheck.state == .on
        let selectedCommand = commandCombo.stringValue
        let options = optionsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Save selections for next time
        UserDefaults.standard.set(selectedCommand, forKey: Self.spawnCLILastCommandKey)
        UserDefaults.standard.set(options, forKey: Self.spawnCLILastOptionsKey)
        UserDefaults.standard.set(count, forKey: Self.spawnCLILastCountKey)
        UserDefaults.standard.set(useWorktree, forKey: Self.spawnCLILastWorktreeKey)
        UserDefaults.standard.set(useNewWorkspace, forKey: Self.spawnCLILastNewWorkspaceKey)
        let loginShellMode = loginShellCheck.state == .on ? "login" : "auto"
        UserDefaults.standard.set(loginShellMode, forKey: "shellLoginMode")

        // Build full command string using resolved path from CLI settings
        let command: String? = {
            if selectedCommand == "(shell only)" || selectedCommand.isEmpty {
                return nil
            }
            let resolvedCli = CLIPathSettings.resolvedPath(for: selectedCommand) ?? selectedCommand
            if options.isEmpty {
                return resolvedCli
            }
            return "\(resolvedCli) \(options)"
        }()

        if useWorktree {
            activeTabManager.spawnAgentSessions(count: count, command: command)
        } else {
            activeTabManager.spawnCLISessions(count: count, command: command, newWorkspace: useNewWorkspace)
        }
    }

    private func showReconnectAgentDialog() {
        let agents = termMeshDaemon.listAgents(includeTerminated: false)
        let detached = agents.filter { $0.status != "terminated" && $0.panelId == nil }

        guard !detached.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Reconnect Agent"
            alert.informativeText = "No detached agent sessions found."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Reconnect Agent"
        alert.informativeText = "Select a detached agent session to reconnect:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reconnect")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        for agent in detached {
            let label = "\(agent.name) [\(agent.worktreeBranch)] — \(agent.worktreePath)"
            popup.addItem(withTitle: label)
            popup.lastItem?.representedObject = agent.id as NSString
        }
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn,
              let selectedId = popup.selectedItem?.representedObject as? String else { return }

        activeTabManager.reconnectAgentSession(sessionId: selectedId)
    }

    @ViewBuilder
    private func splitCommandButton(title: String, shortcut: StoredShortcut, action: @escaping () -> Void) -> some View {
        splitCommandButton(title: title, shortcut: shortcut, registerShortcut: true, action: action)
    }

    /// When `registerShortcut` is false the menu item still shows the shortcut
    /// hint text but does NOT register it as an NSMenuItem key equivalent.
    /// Use this for shortcuts already handled by the local NSEvent monitor to
    /// prevent SwiftUI from processing the shortcut independently (which can
    /// cause WindowGroup to create a duplicate window).
    @ViewBuilder
    private func splitCommandButton(title: String, shortcut: StoredShortcut, registerShortcut: Bool, action: @escaping () -> Void) -> some View {
        if registerShortcut, let key = shortcut.keyEquivalent {
            Button(title, action: action)
                .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(title, action: action)
        }
    }

    private func closePanelOrWindow() {
        if let window = NSApp.keyWindow,
           window.identifier?.rawValue == "term-mesh.settings" {
            window.performClose(nil)
            return
        }
        activeTabManager.closeCurrentPanelWithConfirmation()
    }

    private func closeTabOrWindow() {
        activeTabManager.closeCurrentTabWithConfirmation()
    }

    private func showNotificationsPopover() {
        AppDelegate.shared?.toggleNotificationsPopover(animated: false)
    }

    private func openAllDebugWindows() {
        SettingsAboutTitlebarDebugWindowController.shared.show()
        SidebarDebugWindowController.shared.show()
        BackgroundDebugWindowController.shared.show()
        MenuBarExtraDebugWindowController.shared.show()
    }
}

