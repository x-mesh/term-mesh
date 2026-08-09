import AppKit
import SwiftUI
import Darwin
import Bonsplit

@main
struct TermMeshApp: App {
    @State private var tabManager: TabManager
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var sidebarSelectionState = SidebarSelectionState()
    @ObservedObject private var termMeshDaemon = TermMeshDaemon.shared
    private let configProvider: any GhosttyConfigProvider = GhosttyApp.shared
    private let browserHistory: any BrowserHistoryService = BrowserHistoryStore.shared
    private let primaryWindowId = UUID()
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage(LanguageSettings.languageModeKey) private var languageMode = LanguageSettings.defaultMode.rawValue
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
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyle = TitlebarControlsStyle.classic.rawValue
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(KeyboardShortcutSettings.Action.toggleSidebar.defaultsKey) private var toggleSidebarShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newTab.defaultsKey) private var newWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newWindow.defaultsKey) private var newWindowShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newProject.defaultsKey) private var newProjectShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.openPeerWorkspace.defaultsKey) private var openPeerWorkspaceShortcutData = Data()
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
    /// A dialog the primary window can present, carrying everything it needs.
    ///
    /// The TabManager rides in the payload because it has to be captured when
    /// the request arrives: once the sheet takes key window, the window that
    /// asked is no longer identifiable.
    private enum PrimarySheet: Identifiable {
        /// New Project. Owned here rather than by the sidebar's Projects
        /// header, because the titlebar's + opens the same sheet and is on
        /// screen precisely when the sidebar is not.
        case projectCreation(tabManager: TabManager?)
        /// `mode` is "new" or "resume" (Phase 2.5).
        case teamCreation(tabManager: TabManager?, mode: String)
        /// P0-5: Configure Watch, from the palette or a sidebar notification.
        case watchConfig(teamName: String, workingDirectory: String)

        /// Identity is the KIND of sheet, not its payload: re-requesting the
        /// dialog already on screen must not tear it down and rebuild it,
        /// which would discard whatever the user had typed into it.
        var id: String {
            switch self {
            case .projectCreation: "project-creation"
            case .teamCreation: "team-creation"
            case .watchConfig: "watch-config"
            }
        }
    }

    /// The one sheet this window can be showing.
    ///
    /// One presenter, not three. A `.sheet(isPresented:)` per dialog put three
    /// bindings in front of a single presentation slot: SwiftUI dropped any
    /// request that landed while another sheet was up — or while one was still
    /// tearing down — and left that dialog's binding stuck `true`, which no
    /// later request could clear, so the dialog stayed dead until the app was
    /// relaunched. With a single `item` there is nothing to strand: what is
    /// showing IS the state, and a request either becomes it or replaces it.
    @State private var activeSheet: PrimarySheet?
    @State private var ghosttyTheme = GhosttyTheme.current

    init() {
        // Idempotent, and already done if a `GhosttyApp.shared` touch got here
        // first. It must run before ghostty_init either way — see
        // GhosttyEnvironment.
        GhosttyEnvironment.configureOnce()

        let startupAppearance = AppearanceSettings.resolvedMode()
        Self.applyAppearance(startupAppearance)
        // Repair an unreadable stored language the same way appearance does,
        // so the Settings picker and the AppKit lookups agree on a value that
        // is actually in AppLanguage rather than each falling back separately.
        LanguageSettings.resolvedMode()
        // Seed this build's override directory from the shared pre-isolation
        // one, before either file is written. Both writes below regenerate
        // from UserDefaults anyway, so this only matters for what a build
        // inherits the first time it runs after the isolation landed — see
        // TerminalOverrideLocation.
        TerminalOverrideLocation.migrateLegacyFilesIfNeeded()
        // Ensure terminal theme override exists at startup (covers fresh install).
        // The settings file goes first: its `theme` line depends on the appearance
        // mode, and a build that shipped before that was true leaves a stale pair
        // behind — which is what made a fresh install come up light on a Light Mac.
        TerminalSettingsOverride.write()
        TerminalThemeOverride.write(for: startupAppearance.rawValue)
        // Unit-test bundles run inside the real app host. Do not restore the
        // user's terminal session before XCTest establishes its connection.
        let isRunningUnderXCTest = AppLaunchEnvironment.isRunningUnderXCTest(
            ProcessInfo.processInfo.environment
        )
        _tabManager = State(wrappedValue: TabManager(
            restoreSavedSession: !isRunningUnderXCTest,
            persistsSessionState: !isRunningUnderXCTest,
            daemon: TermMeshDaemon.shared,
            notifications: TerminalNotificationStore.shared
        ))
        // TabManager init triggers `GhosttyApp.shared` to load. Push the
        // saved appearance to the GhosttyApp-level color scheme right
        // after so the very first surfaces pick the correct variant from
        // a `theme = light:X,dark:Y` config. Without this, every launch
        // (after a brew upgrade or fresh start) renders the LIGHT theme
        // because GhosttyApp defaults to LIGHT until `.onChange(of: appearanceMode)`
        // fires — which it never does at startup.
        Self.syncGhosttyAppColorScheme(for: startupAppearance)
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
        IMEInputBarSettings.migrateHeightIfNeeded()
        CliProfileMigrator.migrateIfNeeded()

        // UI tests depend on AppDelegate wiring happening even if SwiftUI view appearance
        // callbacks (e.g. `.onAppear`) are delayed or skipped.
        appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
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

    private func resolveDefaultWorkingDirectory(activeTabManager: TabManager?) -> (path: String, source: WorkingDirectorySource) {
        // 1. Caller-provided active tab manager (already from the key/main window context at menu click time)
        if let dir = activeTabManager?.selectedTab?.currentDirectory, !dir.isEmpty {
            return (dir, .currentPane)
        }
        // 2. Workspace: key window first, then main window (deterministic; avoids
        //    wrong-window bug class from non-deterministic window ordering).
        if let kw = NSApp.keyWindow,
           let ctx = AppDelegate.shared?.contextForMainWindow(kw),
           let dir = ctx.tabManager.selectedTab?.currentDirectory, !dir.isEmpty {
            return (dir, .workspace)
        }
        if let mw = NSApp.mainWindow,
           let ctx = AppDelegate.shared?.contextForMainWindow(mw),
           let dir = ctx.tabManager.selectedTab?.currentDirectory, !dir.isEmpty {
            return (dir, .workspace)
        }
        // 3. Last successfully used directory from MRU list
        if let dir = TeamCreationRecentDirs.shared.current().first {
            return (dir, .lastUsed)
        }
        // 4. App process CWD — warn via .appLaunch source label
        return (FileManager.default.currentDirectoryPath, .appLaunch)
    }

    private func makeTeamCreationView(
        requestedBy requestingTabManager: TabManager?,
        mode: String
    ) -> TeamCreationView {
        let activeTabManager = requestingTabManager ?? tabManager
        let (defaultDir, defaultSource) = resolveDefaultWorkingDirectory(activeTabManager: activeTabManager)
        return TeamCreationView(
            onCreate: { teamName, leaderMode, leaderModel, agents, worktreeMode, executionMode, resumeSessionId, pairMode, pairModel, pairSpec, workingDirectory in
                TeamOrchestrator.shared.createTeam(
                    named: teamName,
                    rows: agents,
                    workingDirectory: workingDirectory,
                    leaderMode: leaderMode,
                    leaderModel: leaderModel,
                    worktreeMode: worktreeMode,
                    executionMode: executionMode,
                    resumeSessionId: resumeSessionId,
                    pairMode: pairMode,
                    pairModel: pairModel,
                    pairSpec: pairSpec,
                    tabManager: activeTabManager
                ) != nil
            },
            onResume: { (result: [String: Any]) in
                // The picker tags pane-mode resumes so we route to a separate
                // app-side rehydration path. Headless resumes go through the
                // existing daemon-respawn-driven adoption.
                if (result["mode"] as? String) == "pane" {
                    TeamOrchestrator.shared.adoptResumedPaneTeam(
                        result: result,
                        tabManager: activeTabManager
                    )
                } else {
                    TeamOrchestrator.shared.adoptResumedHeadlessTeam(
                        result: result,
                        tabManager: activeTabManager
                    )
                }
            },
            initialMode: mode,
            defaultWorkingDirectory: defaultDir,
            defaultWorkingDirectorySource: defaultSource
        )
    }

    @ViewBuilder
    private var primaryWindowBaseContent: some View {
    ContentView(updateViewModel: appDelegate.updateViewModel, windowId: primaryWindowId)
        .environment(tabManager)
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
            // Duplicate WindowGroup scene guard: if a primary window is already
            // registered, this onAppear is firing for a duplicate scene. Skip
            // configure/socket setup to prevent AppDelegate.tabManager from being
            // overwritten, and close the duplicate window.
            let existingWindows = appDelegate.mainWindowContexts.count
#if DEBUG
            dlog("window.WindowGroup.onAppear primaryWindowId=\(primaryWindowId.uuidString.prefix(8)) existingWindows=\(existingWindows)")
#endif
            // The primary window registers via WindowAccessor before onAppear fires,
            // so count == 1 is normal. A duplicate scene produces count >= 2.
            if existingWindows > 1 {
#if DEBUG
                dlog("window.WindowGroup.onAppear DUPLICATE_SCENE existingWindows=\(existingWindows) — blocking configure, closing duplicate")
#endif
                DispatchQueue.main.async {
                    if let duplicateWindow = NSApp.windows.last,
                       duplicateWindow.contentView != nil,
                       appDelegate.mainWindowContexts.count > 1 {
                        duplicateWindow.close()
                    }
                }
                return
            }
            // Start the Unix socket controller for programmatic access
            updateSocketController()
            appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
            applyAppearance()
            // Sync Ghostty app-level color scheme on startup so the
            // GUI theme picker (`theme = light:X,dark:Y`) selects the
            // right variant. Without this the user sees the light
            // theme on every launch when their saved appearanceMode
            // is `dark` — `.onChange(of: appearanceMode)` doesn't
            // fire on initial load (no change to react to), so the
            // GhosttyApp keeps the default LIGHT scheme it was
            // initialized with and the next config reload picks the
            // light theme.
            syncGhosttyAppColorScheme()
            if termMeshEnv("UI_TEST_SHOW_SETTINGS") == "1" {
                DispatchQueue.main.async {
                    showSettingsPanel()
                }
            }
            // Restore Fleet Layer 3: once the primary window is configured
            // (and session.json layout restore has run inside TabManager
            // init), look for crash-recoverable live team snapshots. Small
            // delay so the daemon spawned by this launch is accepting RPCs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                TeamOrchestrator.shared.detectRestorableFleets()
            }
        }
        .onChange(of: appearanceMode) { _ in
            applyAppearance()
            // The settings file's `theme` line pins light or dark by this mode,
            // so it has to be rewritten here too — otherwise a named theme keeps
            // whichever half the system appearance picked when it was last saved.
            TerminalSettingsOverride.write()
            // Write terminal color override and reload Ghostty config
            TerminalThemeOverride.write(for: appearanceMode)
            configProvider.reloadConfiguration(source: "appearance.toggle")
            // Sync Ghostty app-level color scheme so new surfaces inherit the correct theme
            syncGhosttyAppColorScheme()
        }
        .onChange(of: terminalFontFamily) { _ in applyTerminalSettings() }
        .onChange(of: terminalFontSize) { _ in applyTerminalSettings() }
        .onChange(of: terminalThemeLight) { _ in applyTerminalSettings() }
        .onChange(of: terminalThemeDark) { _ in applyTerminalSettings() }
        .onChange(of: terminalBgOpacity) { _ in applyTerminalSettings() }
        .onChange(of: terminalCursorColor) { _ in applyTerminalSettings() }
        .onChange(of: terminalCursorStyle) { _ in applyTerminalSettings() }
        .onChange(of: terminalScrollback) { _ in applyTerminalSettings() }
        .onChange(of: terminalUnfocusedOpacity) { _ in applyTerminalSettings() }
        .onChange(of: terminalDividerColor) { _ in applyTerminalSettings() }
        .onChange(of: socketControlMode) { _ in
            updateSocketController()
        }
    }

    @ViewBuilder
    private var primaryWindowContent: some View {
        primaryWindowBaseContent
            .onReceive(
                NotificationCenter.default.publisher(for: .teamCreationRequested)
                    .merge(with: NotificationCenter.default.publisher(for: .openCreateTeamSheetInResumeMode))
                    .eraseToAnyPublisher()
            ) { note in
                present(.teamCreation(
                    tabManager: requestingTabManager(),
                    mode: note.name == .openCreateTeamSheetInResumeMode ? "resume" : "new"
                ))
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectCreationRequested)) { _ in
                present(.projectCreation(tabManager: requestingTabManager()))
            }
            .onReceive(NotificationCenter.default.publisher(for: .spawnCLIRequested)) { _ in
                Task { @MainActor in
                    await showSpawnCLIDialog()
                }
            }
            // Restore Fleet Layer 3: perform the restore where an active
            // TabManager is in scope (sidebar banner button, or auto-posted
            // by detectRestorableFleets in `always` mode).
            .onReceive(NotificationCenter.default.publisher(for: .restoreFleetRequested)) { note in
                guard let uuid = note.userInfo?["team_uuid"] as? String else { return }
                let targetTabManager: TabManager = {
                    if let kw = NSApp.keyWindow,
                       let ctx = AppDelegate.shared?.contextForMainWindow(kw) {
                        return ctx.tabManager
                    }
                    if let mw = NSApp.mainWindow,
                       let ctx = AppDelegate.shared?.contextForMainWindow(mw) {
                        return ctx.tabManager
                    }
                    return tabManager
                }()
                TeamOrchestrator.shared.restoreFleet(teamUuid: uuid, tabManager: targetTabManager)
            }
            // P0-5: Configure Watch sheet handler
            .onReceive(NotificationCenter.default.publisher(for: .watchConfigRequested)) { note in
                let info = note.userInfo
                present(.watchConfig(
                    teamName: info?["teamName"] as? String ?? "",
                    workingDirectory: info?["workingDirectory"] as? String ?? ""
                ))
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .projectCreation(let requestingTabManager):
                    makeProjectCreationView(requestedBy: requestingTabManager)
                case .teamCreation(let requestingTabManager, let mode):
                    makeTeamCreationView(requestedBy: requestingTabManager, mode: mode)
                case .watchConfig(let teamName, let workingDirectory):
                    WatchConfigSheet(
                        teamName: teamName,
                        workingDirectory: workingDirectory
                    )
                    .frame(width: 480)
                }
            }
    }

    private func makeProjectCreationView(
        requestedBy requestingTabManager: TabManager?
    ) -> NewProjectView {
        let activeTabManager = requestingTabManager ?? tabManager
        return NewProjectView(
            onCreate: { name, directory, rows, source, leader, progress in
                try await ProjectCreationFlow.create(
                    name: name,
                    directory: directory,
                    rows: rows,
                    source: source,
                    leader: leader,
                    progress: progress,
                    tabManager: activeTabManager
                )
            },
            onClose: { activeSheet = nil },
            onDiscard: { name in
                // Best effort by design: this runs because something already
                // went wrong, and a peer that is now unreachable must not trap
                // the sheet. What could not be removed is reported by
                // `deleteProject` into the team's own record.
                do {
                    try await TeamOrchestrator.shared.deleteProject(
                        teamName: name,
                        tabManager: activeTabManager
                    )
                } catch {
                    RemoteWorkLog.info("Could not discard \(name): \(error)")
                }
            },
            repositoryDirectories: (
                activeTabManager.tabs.map(\.currentDirectory)
                + TeamCreationRecentDirs.shared.current()
            ),
            repositorySearchRoots: ProjectLocationSettings.repositorySearchRoots
        )
    }

    /// The TabManager of the window that asked, captured before the sheet
    /// takes key window and makes it unidentifiable.
    @MainActor
    private func requestingTabManager() -> TabManager? {
        if let kw = NSApp.keyWindow, let ctx = AppDelegate.shared?.contextForMainWindow(kw) {
            return ctx.tabManager
        }
        if let mw = NSApp.mainWindow, let ctx = AppDelegate.shared?.contextForMainWindow(mw) {
            return ctx.tabManager
        }
        return nil
    }

    /// Show `sheet`, replacing whatever is on screen.
    ///
    /// Requesting the dialog already up is a no-op rather than a rebuild, so
    /// a stray second trigger cannot discard what the user has typed.
    ///
    /// Swapping one dialog for another goes through `nil` first: asking
    /// SwiftUI to dismiss and present inside one write gives it a single
    /// frame to do both, and it drops that often enough to matter. Two clean
    /// transitions always land. This is also what makes a lost presentation
    /// self-healing — under `.sheet(isPresented:)` a dropped request left the
    /// binding stuck `true` and killed that dialog until relaunch (the "New
    /// Project stopped opening" report on 0.170.0).
    @MainActor
    private func present(_ sheet: PrimarySheet) {
        guard let current = activeSheet else {
            activeSheet = sheet
            return
        }
        guard current.id != sheet.id else { return }
        activeSheet = nil
        DispatchQueue.main.async { activeSheet = sheet }
    }

    var body: some Scene {
        // Restrict WindowGroup to only create the initial primary window.
        // Use a unique ID that the system won't match for state-restoration
        // or external events, preventing duplicate scene creation.
        // All additional windows are created via AppDelegate.createMainWindow()
        // with their own TabManager, avoiding the shared-@StateObject problem.
        WindowGroup(id: "term-mesh-primary") {
            primaryWindowContent
                .termMeshLanguage()
        }
        .environment(\.locale, LanguageSettings.locale(for: languageMode))
        // Prevent macOS from creating duplicate WindowGroup scenes via
        // state restoration, dock clicks, or external events. Only the
        // initial scene should use this WindowGroup; additional windows
        // are NSWindow-backed via AppDelegate.createMainWindow().
        .handlesExternalEvents(matching: Set(["term-mesh-primary"]))
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // MARK: - Agents Menu (combined agents + worktrees)
            CommandMenu(LanguageSettings.localized("Agents")) {
                // -- Create --
                Button {
                    present(.teamCreation(tabManager: requestingTabManager(), mode: "new"))
                } label: {
                    commandLabel("New Agent Team…")
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button {
                    Task { @MainActor in
                        await showSpawnCLIDialog()
                    }
                } label: {
                    commandLabel("Spawn CLI…")
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                // -- Manage --
                Divider()

                Button {
                    Task { @MainActor in
                        await showReconnectAgentDialog()
                    }
                } label: {
                    commandLabel("Reconnect Agent…")
                }
                .keyboardShortcut("a", modifiers: [.command, .option])

                Button {
                    Task { @MainActor in
                        await showDestroyTeamDialog()
                    }
                } label: {
                    commandLabel("Destroy Team…")
                }

                Button {
                    Task { @MainActor in
                        await showCollectResultsDialog()
                    }
                } label: {
                    commandLabel("Collect All Results")
                }

                Divider()

                Button {
                    showRecycleFocusedAgentDialog(force: false)
                } label: {
                    commandLabel("Recycle Focused Agent…")
                }
                .keyboardShortcut("r", modifiers: [.command, .control])

                Button {
                    showRecycleFocusedAgentDialog(force: true)
                } label: {
                    commandLabel("Recycle Focused Agent (Force)…")
                }
                .keyboardShortcut("r", modifiers: [.command, .control, .shift])

                // -- Worktrees --
                Divider()

                Button {
                    NotificationCenter.default.post(name: .worktreeWorkspaceRequested, object: nil)
                } label: {
                    commandLabel("New Worktree Workspace")
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
                                    alert.presentAsSheet()
                                }
                            }
                        }
                    }
                }

                Toggle(isOn: $worktreeAutoCleanup) { commandLabel("Worktree Auto-Cleanup") }

                Divider()

                Button {
                    cleanupStaleWorktrees()
                } label: {
                    commandLabel("Clean Up Stale Worktrees")
                }

                Button {
                    let path = termMeshDaemon.worktreeBaseDir
                    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
                } label: {
                    commandLabel("Open Worktree Directory…")
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button {
                    showSettingsPanel()
                } label: {
                    commandLabel("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .appInfo) {
                Button {
                    showAboutPanel()
                } label: {
                    commandLabel("About Term-Mesh")
                }
                Button {
                    UserDefaults.standard.set(false, forKey: "hideWelcomeScreen")
                } label: {
                    commandLabel("Welcome Screen")
                }
                Divider()
                Button {
                    configProvider.openConfigurationInTextEdit()
                } label: {
                    commandLabel("Ghostty Settings…")
                }
                Button {
                    configProvider.reloadConfiguration(source: "menu.reload_configuration")
                } label: {
                    commandLabel("Reload Configuration")
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                Divider()
                Button {
                    appDelegate.checkForUpdates(nil)
                } label: {
                    commandLabel("Check for Updates…")
                }
                InstallUpdateMenuItem(model: appDelegate.updateViewModel)
                Divider()
                Button {
                    DashboardController.shared.showDashboard()
                } label: {
                    commandLabel("Term-Mesh Dashboard (Window)")
                }
                Button {
                    openDashboardSplit()
                } label: {
                    commandLabel("Term-Mesh Dashboard (Split)")
                }
            }

#if DEBUG
            CommandMenu(LanguageSettings.localized("Update Pill")) {
                Button {
                    appDelegate.showUpdatePill(nil)
                } label: {
                    commandLabel("Show Update Pill")
                }
                Button {
                    appDelegate.showUpdatePillLongNightly(nil)
                } label: {
                    commandLabel("Show Long Nightly Pill")
                }
                Button {
                    appDelegate.showUpdatePillLoading(nil)
                } label: {
                    commandLabel("Show Loading State")
                }
                Button {
                    appDelegate.hideUpdatePill(nil)
                } label: {
                    commandLabel("Hide Update Pill")
                }
                Button {
                    appDelegate.clearUpdatePillOverride(nil)
                } label: {
                    commandLabel("Automatic Update Pill")
                }
            }
#endif

            CommandGroup(after: .help) {
                Button {
                    appDelegate.copyUpdateLogs(nil)
                } label: {
                    commandLabel("Copy Update Logs")
                }
                Button {
                    appDelegate.copyFocusLogs(nil)
                } label: {
                    commandLabel("Copy Focus Logs")
                }
            }

            CommandMenu(LanguageSettings.localized("Notifications")) {
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

                Button {
                    notificationStore.markAllRead()
                } label: {
                    commandLabel("Mark All Read")
                }
                .disabled(!snapshot.hasUnreadNotifications)

                Button {
                    notificationStore.clearAll()
                } label: {
                    commandLabel("Clear All")
                }
                .disabled(!snapshot.hasNotifications)
            }

            CommandMenu(LanguageSettings.localized("Peer")) {
                Menu(LanguageSettings.localized("Host This Mac")) {
                    Button {
                        PeerHostCoordinator.shared.startServer(nil)
                    } label: {
                        commandLabel("Start Peer Server…")
                    }
                    Button {
                        PeerHostCoordinator.shared.stopServer(nil)
                    } label: {
                        commandLabel("Stop Peer Server")
                    }
                }

                Divider()

                // Sidebar-first peer UX: connecting/opening lives in the
                // sidebar; the menu keeps host management. Raw socket
                // dialogs stay as DEBUG-only tools.
                //
                // The palette entry below is the one exception. It shows the
                // binding but does not register it (`registerShortcut: false`),
                // because AppDelegate's event monitor already claims the key —
                // registering it twice would fire the action twice, the same
                // reason New Window opts out.
                splitCommandButton(
                    title: "Open Peer Workspace…",
                    shortcut: openPeerWorkspaceMenuShortcut,
                    registerShortcut: false
                ) {
                    NotificationCenter.default.post(
                        name: .commandPalettePeersRequested,
                        object: NSApp.keyWindow ?? NSApp.mainWindow
                    )
                }

                Button {
                    PeerClientCoordinator.shared.addRemoteHost(nil)
                } label: {
                    commandLabel("Add Peer Host…")
                }

#if DEBUG
                Menu(LanguageSettings.localized("Debug Connect")) {
                    Button {
                        PeerClientCoordinator.shared.promptAndRun(nil)
                    } label: {
                        commandLabel("Connect to Peer…")
                    }
                    Button {
                        PeerClientCoordinator.shared.promptAndRunRelayWorkspace(nil)
                    } label: {
                        commandLabel("Connect to Workspace via Relay…")
                    }
                }
#endif

                Button {
                    PeerClientCoordinator.shared.showConnections(nil)
                } label: {
                    commandLabel("Show Peer Connections…")
                }

                Divider()

                Button {
                    showSettingsPanel(navigateTo: .peerFederation)
                } label: {
                    commandLabel("Peer Federation Settings…")
                }
            }

            CommandMenu(LanguageSettings.localized("Remote Work")) {
                Button {
                    ReviewBoardSettings.toggleVisible()
                } label: {
                    commandLabel("Toggle Review Board")
                }
                .keyboardShortcut("b", modifiers: [.command, .control])

                Button {
                    AppDelegate.shared?.tabManager?.selectedWorkspace?
                        .retrievalStore.togglePresentation(.drawer)
                } label: {
                    commandLabel("Toggle Activity Drawer")
                }
                .keyboardShortcut("d", modifiers: [.command, .control])

                Button {
                    AppDelegate.shared?.tabManager?.selectedWorkspace?
                        .retrievalStore.togglePresentation(.inspector)
                } label: {
                    commandLabel("Toggle Changes Inspector")
                }
                .keyboardShortcut("i", modifiers: [.command, .control])

                Button {
                    guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
                          let panelID = workspace.retrievalStore.selectedPane?.panelID else { return }
                    Task { await workspace.checkpointRemotePane(panelID: panelID, closeAfterCheckpoint: false) }
                } label: {
                    commandLabel("Checkpoint Now")
                }
                .keyboardShortcut("k", modifiers: [.command, .control])
            }

#if DEBUG
            CommandMenu(LanguageSettings.localized("Debug")) {
                Button {
                    appDelegate.openDebugLoremTab(nil)
                } label: {
                    commandLabel("New Tab With Lorem Search Text")
                }

                Button {
                    appDelegate.openDebugScrollbackTab(nil)
                } label: {
                    commandLabel("New Tab With Large Scrollback")
                }

                Button {
                    appDelegate.openDebugColorComparisonWorkspaces(nil)
                } label: {
                    commandLabel("Open Workspaces for All Tab Colors")
                }

                Divider()
                Menu(LanguageSettings.localized("Debug Windows")) {
                    Button {
                        DebugWindowControlsWindowController.shared.show()
                    } label: {
                        commandLabel("Debug Window Controls…")
                    }

                    Button {
                        SettingsAboutTitlebarDebugWindowController.shared.show()
                    } label: {
                        commandLabel("Settings/About Titlebar Debug…")
                    }

                    Divider()
                    Button {
                        SidebarDebugWindowController.shared.show()
                    } label: {
                        commandLabel("Sidebar Debug…")
                    }

                    Button {
                        BackgroundDebugWindowController.shared.show()
                    } label: {
                        commandLabel("Background Debug…")
                    }

                    Button {
                        MenuBarExtraDebugWindowController.shared.show()
                    } label: {
                        commandLabel("Menu Bar Extra Debug…")
                    }

                    Divider()

                    Button {
                        openAllDebugWindows()
                    } label: {
                        commandLabel("Open All Debug Windows")
                    }
                }

                Toggle(isOn: $alwaysShowShortcutHints) { commandLabel("Always Show Shortcut Hints") }

                Divider()

                Picker(selection: $titlebarControlsStyle) {
                    ForEach(TitlebarControlsStyle.allCases) { style in
                        commandLabel(style.menuTitle).tag(style.rawValue)
                    }
                } label: {
                    commandLabel("Titlebar Controls Style")
                }

                Divider()

                Button {
                    appDelegate.triggerSentryTestCrash(nil)
                } label: {
                    commandLabel("Trigger Sentry Test Crash")
                }
            }
#endif

            // MARK: - File & Navigation Commands
            Group {
            CommandGroup(replacing: .newItem) {
                // New Window shortcut is handled by AppDelegate's local NSEvent monitor.
                // Registering it as SwiftUI .keyboardShortcut() causes the menu system to
                // process the shortcut independently, which can trigger a duplicate window.
                splitCommandButton(title: "New Window", shortcut: newWindowMenuShortcut, registerShortcut: false) {
                    appDelegate.openNewMainWindow(nil)
                }

                splitCommandButton(title: "New Workspace", shortcut: newWorkspaceMenuShortcut) {
                    activeTabManager.addTab()
                }

                // AppDelegate handles this by physical key code as well as characters,
                // so the shortcut keeps working under CJK keyboard layouts.
                splitCommandButton(title: "New Project…", shortcut: newProjectMenuShortcut, registerShortcut: false) {
                    NotificationCenter.default.post(
                        name: .projectCreationRequested,
                        object: nil
                    )
                }
            }

            // Close tab/workspace
            CommandGroup(after: .newItem) {
                Button {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: targetWindow)
                } label: {
                    commandLabel("Go to Workspace or Tab…")
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteRequested, object: targetWindow)
                } label: {
                    commandLabel("Command Palette…")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                // Terminal semantics:
                // Cmd+W closes the focused tab (with confirmation if needed). If this is the last
                // tab in the last workspace, it closes the window.
                Button {
                    closePanelOrWindow()
                } label: {
                    commandLabel("Close Tab")
                }
                .keyboardShortcut("w", modifiers: .command)

                // Cmd+Shift+W closes the current workspace (with confirmation if needed). If this
                // is the last workspace, it closes the window.
                splitCommandButton(title: "Close Workspace", shortcut: closeWorkspaceMenuShortcut) {
                    closeTabOrWindow()
                }

                Button {
                    _ = activeTabManager.reopenMostRecentlyClosedBrowserPanel()
                } label: {
                    commandLabel("Reopen Closed Browser Panel")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            // Find
            CommandGroup(after: .textEditing) {
                Menu(LanguageSettings.localized("Find")) {
                    Button {
                        activeTabManager.startSearch()
                    } label: {
                        commandLabel("Find…")
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button {
                        activeTabManager.findNext()
                    } label: {
                        commandLabel("Find Next")
                    }
                    .keyboardShortcut("g", modifiers: .command)

                    Button {
                        activeTabManager.findPrevious()
                    } label: {
                        commandLabel("Find Previous")
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Divider()

                    Button {
                        activeTabManager.hideFind()
                    } label: {
                        commandLabel("Hide Find Bar")
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!(activeTabManager.isFindVisible))

                    Divider()

                    Button {
                        activeTabManager.searchSelection()
                    } label: {
                        commandLabel("Use Selection for Find")
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!(activeTabManager.canUseSelectionForFind))
                }

                Divider()

                Button {
                    activeTabManager.toggleIMEInputBar()
                } label: {
                    commandLabel("IME Input Bar")
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

                Button {
                    activeTabManager.focusedBrowserPanel?.goBack()
                } label: {
                    commandLabel("Back")
                }
                .keyboardShortcut("[", modifiers: .command)

                Button {
                    activeTabManager.focusedBrowserPanel?.goForward()
                } label: {
                    commandLabel("Forward")
                }
                .keyboardShortcut("]", modifiers: .command)

                Button {
                    activeTabManager.focusedBrowserPanel?.reload()
                } label: {
                    commandLabel("Reload Page")
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

                Button {
                    _ = activeTabManager.zoomInFocusedBrowser()
                } label: {
                    commandLabel("Zoom In")
                }
                .keyboardShortcut("=", modifiers: .command)

                Button {
                    _ = activeTabManager.zoomOutFocusedBrowser()
                } label: {
                    commandLabel("Zoom Out")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    _ = activeTabManager.resetZoomFocusedBrowser()
                } label: {
                    commandLabel("Actual Size")
                }
                .keyboardShortcut("0", modifiers: .command)

                Button {
                    browserHistory.clearHistory()
                } label: {
                    commandLabel("Clear Browser History")
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
                    Button {
                        let manager = activeTabManager
                        if let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: number, workspaceCount: manager.tabs.count) {
                            manager.selectTab(at: targetIndex)
                        }
                    } label: {
                        // Interpolating here would key on "Workspace 1", "Workspace 2", …
                        // — nine entries that all say the same thing. Format instead.
                        Text(verbatim: String(
                            format: LanguageSettings.localized("Workspace %lld"),
                            locale: LanguageSettings.currentLocale(),
                            number
                        ))
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

    private func showSettingsPanel(navigateTo section: SettingsSection? = nil) {
        SettingsWindowController.shared.show()
        NSApp.activate(ignoringOtherApps: true)
        guard let section else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .settingsNavigateToSection,
                object: nil,
                userInfo: [SettingsNavigationUserInfoKey.section: section.rawValue]
            )
        }
    }

    private func applyAppearance() {
        let mode = AppearanceSettings.mode(for: appearanceMode)
        if appearanceMode != mode.rawValue {
            appearanceMode = mode.rawValue
        }
        Self.applyAppearance(mode)
    }

    /// Push the current effective appearance to the GhosttyApp-level color
    /// scheme. Surfaces and config reloads consult the app-level scheme to
    /// pick between `theme = light:X,dark:Y` variants, so this must be in
    /// sync with `NSApp.effectiveAppearance` from startup onward.
    ///
    /// `GhosttyApp.shared.app` may be nil for a brief moment during early
    /// `.onAppear` (it initializes lazily on first reference). The retry
    /// loop covers fast paths; for slow startups (notably the brew-upgrade
    /// relaunch that this method was added to fix) the budget can run out.
    /// `GhosttyApp.shared.app` is also re-checked on every `applyAppearance`
    /// pass and on every `.onChange(of: appearanceMode)` — so a late init
    /// will still receive the saved preference once any of those fire.
    private func syncGhosttyAppColorScheme() {
        Self.syncGhosttyAppColorScheme(for: AppearanceSettings.mode(for: appearanceMode))
    }

    /// Static counterpart so `init()` can call this before any SwiftUI
    /// view appears. Resolves `dark`/`light` from the explicit user
    /// preference; for `.system` falls back to `NSApp.effectiveAppearance`.
    ///
    /// F6 fix: when the retry budget is exhausted without `GhosttyApp.shared.app`
    /// becoming non-nil, schedule one final, longer-delay attempt (3s) before
    /// giving up. On a sluggish brew-upgrade relaunch that's enough time for
    /// the lazy init to finish; if it still hasn't, the next user-driven
    /// appearance change (or any later `applyAppearance` call) will pick up.
    private static func syncGhosttyAppColorScheme(for mode: AppearanceMode, attempt: Int = 0) {
        guard let app = GhosttyApp.shared.app else {
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Self.syncGhosttyAppColorScheme(for: mode, attempt: attempt + 1)
                }
            } else if attempt == 5 {
                // Final long-delay safety net for slow startups (e.g.
                // brew-upgrade relaunch). Without this, exhausting the
                // 500ms budget would leave the GhosttyApp at its default
                // LIGHT scheme and a `theme = light:X,dark:Y` config would
                // pick the wrong variant — exactly the regression that
                // motivated this method.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    Self.syncGhosttyAppColorScheme(for: mode, attempt: attempt + 1)
                }
            }
            return
        }
        let isDark: Bool
        switch mode {
        case .dark:
            isDark = true
        case .light:
            isDark = false
        case .system, .auto:
            isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private func applyTerminalSettings() {
        TerminalSettingsOverride.write()
        TerminalThemeOverride.write(for: appearanceMode)
        configProvider.reloadConfiguration(source: "settings.terminal")
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

    private var newProjectMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: newProjectShortcutData,
            fallback: KeyboardShortcutSettings.Action.newProject.defaultShortcut
        )
    }

    private var openPeerWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: openPeerWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.openPeerWorkspace.defaultShortcut
        )
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
        // Cache the repo path on the main thread before going off-main,
        // so findGitRoot (blocking RPC) never runs on the main thread.
        let cachedRepoPath = activeTabManager.selectedWorkspace?.worktreeRepoPath
        let daemon = self.termMeshDaemon
        Task.detached(priority: .utility) {
            let repoPath = cachedRepoPath
                ?? daemon.findGitRoot(from: FileManager.default.currentDirectoryPath)
                ?? FileManager.default.currentDirectoryPath
            let result = daemon.cleanupStaleWorktrees(repoPath: repoPath)
            await MainActor.run {
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
                alert.presentAsSheet()
            }
        }
    }

    @MainActor
    private func runAlertAsSheetIfPossible(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            var resumed = false
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: response)
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !resumed else { return }
                    resumed = true
                    window.endSheet(alert.window)
                    continuation.resume(returning: .cancel)
                }
            }
        }

        var resumed = false
        return await withCheckedContinuation { continuation in
            alert.presentAsSheet { response in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: response)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: .cancel)
            }
        }
    }

    private func showRecycleFocusedAgentDialog(force: Bool) {
        guard let panelId = AppDelegate.shared?.tabManager?.selectedWorkspace?.focusedPanelId,
              let identity = TeamOrchestrator.shared.agentIdentity(forPanelId: panelId) else {
            let alert = NSAlert()
            alert.messageText = "Recycle Agent"
            alert.informativeText = "No focused agent pane. Click an agent pane first."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        TeamOrchestrator.shared.recycleAgent(teamName: identity.teamName, agentName: identity.agentName, force: force)
    }

    @MainActor
    private func showDestroyTeamDialog() async {
        let teamList = TeamOrchestrator.shared.listTeams()
        guard !teamList.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Destroy Team"
            alert.informativeText = "No active teams found."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            _ = await runAlertAsSheetIfPossible(alert)
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

        guard await runAlertAsSheetIfPossible(alert) == .alertFirstButtonReturn,
              let teamName = popup.selectedItem?.representedObject as? String else { return }

        _ = TeamOrchestrator.shared.destroyTeam(name: teamName, tabManager: activeTabManager)
    }

    @MainActor
    private func showCollectResultsDialog() async {
        let teamList = TeamOrchestrator.shared.listTeams()
        guard !teamList.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Collect Results"
            alert.informativeText = "No active teams found."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            _ = await runAlertAsSheetIfPossible(alert)
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

            guard await runAlertAsSheetIfPossible(alert) == .alertFirstButtonReturn,
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

        if await runAlertAsSheetIfPossible(resultAlert) == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir, isDirectory: true))
        }
    }

    private static let spawnCLILastCommandKey = "spawnCLILastCommand"
    private static let spawnCLILastOptionsKey = "spawnCLILastOptions"
    private static let spawnCLILastCountKey = "spawnCLILastCount"
    private static let spawnCLILastWorktreeKey = "spawnCLILastWorktree"
    private static let spawnCLILastNewWorkspaceKey = "spawnCLILastNewWorkspace"

    @MainActor
    private func showSpawnCLIDialog() async {
        let alert = NSAlert()
        alert.messageText = "Spawn CLI"
        alert.informativeText = "Create multiple terminal panes in a grid layout:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        // Build available commands from CLI path settings
        let cliNames = AgentRolePreset.knownCLIs
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

        guard await runAlertAsSheetIfPossible(alert) == .alertFirstButtonReturn else { return }
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

    @MainActor
    private func showReconnectAgentDialog() async {
        // listAgents() does a blocking socket RPC; run it off the main thread.
        let daemon = self.termMeshDaemon
        let agents = await Task.detached(priority: .userInitiated) {
            daemon.listAgents(includeTerminated: false)
        }.value
        let detached = agents.filter { $0.status != "terminated" && $0.panelId == nil }

        guard !detached.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Reconnect Agent"
            alert.informativeText = "No detached agent sessions found."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            _ = await runAlertAsSheetIfPossible(alert)
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

        guard await runAlertAsSheetIfPossible(alert) == .alertFirstButtonReturn,
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
    ///
    /// The label is built with `commandLabel` rather than `Button(title,…)`:
    /// passing a `String` selects SwiftUI's verbatim overload, which never
    /// consults the string catalog, so every menu item routed through here
    /// stayed English regardless of the language setting.
    @ViewBuilder
    private func splitCommandButton(title: String, shortcut: StoredShortcut, registerShortcut: Bool, action: @escaping () -> Void) -> some View {
        if registerShortcut, let key = shortcut.keyEquivalent {
            Button(action: action) { commandLabel(title) }
                .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(action: action) { commandLabel(title) }
        }
    }

    /// Resolves a menu string against the app-language bundle explicitly.
    ///
    /// Menu bar commands live on the `Scene`, outside the window content that
    /// `termMeshLanguage()` decorates, so they cannot be relied on to inherit
    /// the `\.locale` environment. Looking the string up here keeps the app
    /// menu, the status-item menu and the in-window UI on one language.
    private func commandLabel(_ title: String) -> Text {
        Text(verbatim: LanguageSettings.localized(title))
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
