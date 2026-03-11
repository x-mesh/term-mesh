import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo
import Combine
import os

@MainActor
class TabManager: ObservableObject {
    /// Injected daemon service.
    let daemon: any DaemonService
    /// Injected notification service.
    let notifications: any NotificationService

    @Published var tabs: [Workspace] = []
    @Published private(set) var isWorkspaceCycleHot: Bool = false

    /// Titlebar progress bar state. Set to non-nil to show, nil to hide.
    @Published var titlebarProgress: TitlebarProgress?

    /// Global monotonically increasing counter for TERMMESH_PORT ordinal assignment.
    /// Static so port ranges don't overlap across multiple windows (each window has its own TabManager).
    private static var nextPortOrdinal: Int = 0
    @Published var selectedTabId: UUID? {
        didSet {
            guard selectedTabId != oldValue else { return }
            sentryBreadcrumb("workspace.switch", data: [
                "tabCount": tabs.count
            ])
            let previousTabId = oldValue
            if let previousTabId,
               let previousPanelId = focusedPanelId(for: previousTabId) {
                lastFocusedPanelByTab[previousTabId] = previousPanelId
            }
            if !isNavigatingHistory, let selectedTabId {
                recordTabInHistory(selectedTabId)
            }
#if DEBUG
            let switchId = debugWorkspaceSwitchId
            let switchDtMs = debugWorkspaceSwitchStartTime > 0
                ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
                : 0
            dlog(
                "ws.select.didSet id=\(switchId) from=\(Self.debugShortWorkspaceId(previousTabId)) " +
                "to=\(Self.debugShortWorkspaceId(selectedTabId)) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
            selectionSideEffectsGeneration &+= 1
            let generation = selectionSideEffectsGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionSideEffectsGeneration == generation else { return }
                self.focusSelectedTabPanel(previousTabId: previousTabId)
                self.updateWindowTitleForSelectedTab()
                if let selectedTabId = self.selectedTabId {
                    self.markFocusedPanelReadIfActive(tabId: selectedTabId)
                }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                dlog(
                    "ws.select.asyncDone id=\(self.debugWorkspaceSwitchId) dt=\(Self.debugMsText(dtMs)) " +
                    "selected=\(Self.debugShortWorkspaceId(self.selectedTabId))"
                )
#endif
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var suppressFocusFlash = false
    private var lastFocusedPanelByTab: [UUID: UUID] = [:]
    private struct PanelTitleUpdateKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }
    private var pendingPanelTitleUpdates: [PanelTitleUpdateKey: String] = [:]
    private let panelTitleUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    var recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)

    // Recent tab history for back/forward navigation (like browser history)
    private var tabHistory: [UUID] = []
    private var historyIndex: Int = -1
    private var isNavigatingHistory = false
    private let maxHistorySize = 50
    private var selectionSideEffectsGeneration: UInt64 = 0
    private var workspaceCycleGeneration: UInt64 = 0
    private var workspaceCycleCooldownTask: Task<Void, Never>?
    private var pendingWorkspaceUnfocusTarget: (tabId: UUID, panelId: UUID)?
#if DEBUG
    private var debugWorkspaceSwitchCounter: UInt64 = 0
    private var debugWorkspaceSwitchId: UInt64 = 0
    private var debugWorkspaceSwitchStartTime: CFTimeInterval = 0
#endif

#if DEBUG
    var didSetupSplitCloseRightUITest = false
    var didSetupUITestFocusShortcuts = false
    var didSetupChildExitSplitUITest = false
    var didSetupChildExitKeyboardUITest = false
    var uiTestCancellables = Set<AnyCancellable>()
#endif

    init(
        initialWorkingDirectory: String? = nil,
        daemon: (any DaemonService)? = nil,
        notifications: (any NotificationService)? = nil
    ) {
        self.daemon = daemon ?? TermMeshDaemon.shared
        self.notifications = notifications ?? TerminalNotificationStore.shared
        // Session restore: if enabled and no explicit directory was passed, restore previous workspaces
        if initialWorkingDirectory == nil,
           SessionRestoreSettings.mode() == .always,
           let saved = Self.loadSavedSession() {
            restoreSession(saved)
        } else {
            addWorkspace(workingDirectory: initialWorkingDirectory)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
                enqueuePanelTitleUpdate(tabId: tabId, panelId: surfaceId, title: title)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .termMeshBroadcastIMEText,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let text = notification.userInfo?["text"] as? String else { return }
            self.broadcastIMEText(text)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                markPanelReadOnFocusIfActive(tabId: tabId, panelId: surfaceId)
            }
        })

#if DEBUG
        setupUITestFocusShortcutsIfNeeded()
        setupSplitCloseRightUITestIfNeeded()
        setupChildExitSplitUITestIfNeeded()
        setupChildExitKeyboardUITestIfNeeded()
#endif
    }

    deinit {
        workspaceCycleCooldownTask?.cancel()
    }

    private func wireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = { [weak self] snapshot in
            self?.recentlyClosedBrowsers.push(snapshot)
        }
    }

    private func unwireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = nil
    }

    var selectedWorkspace: Workspace? {
        guard let selectedTabId else { return nil }
        return tabs.first(where: { $0.id == selectedTabId })
    }

    // Keep selectedTab as convenience alias
    var selectedTab: Workspace? { selectedWorkspace }

    // MARK: - Surface/Panel Compatibility Layer

    /// Returns the focused terminal surface for the selected workspace
    var selectedSurface: TerminalSurface? {
        selectedWorkspace?.focusedTerminalPanel?.surface
    }

    /// Returns the focused panel's terminal panel (if it is a terminal)
    var selectedTerminalPanel: TerminalPanel? {
        selectedWorkspace?.focusedTerminalPanel
    }

    var isFindVisible: Bool {
        selectedTerminalPanel?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalPanel?.hasSelection() == true
    }

    func startSearch() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: startSearch workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("start_search")
    }

    func searchSelection() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: searchSelection workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        _ = selectedTerminalPanel?.performBindingAction("search:next")
    }

    func findPrevious() {
        _ = selectedTerminalPanel?.performBindingAction("search:previous")
    }

    func hideFind() {
        selectedTerminalPanel?.searchState = nil
    }

    func toggleIMEInputBar() {
        guard let panel = selectedTerminalPanel else { return }
        NotificationCenter.default.post(name: .termMeshToggleIMEInputBar, object: panel.surface)
    }

    func broadcastIMEText(_ text: String) {
        guard let workspace = selectedWorkspace else { return }
        // Send text + Enter to all terminal panes for immediate execution
        let textWithReturn = text + "\r"
        for panel in workspace.panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            terminalPanel.sendText(textWithReturn)
        }
    }

    @discardableResult
    func addWorkspace(workingDirectory overrideWorkingDirectory: String? = nil, select: Bool = true, command: String? = nil, environment: [String: String] = [:]) -> Workspace {
        sentryBreadcrumb("workspace.create", data: ["tabCount": tabs.count + 1])
        var workingDirectory = normalizedWorkingDirectory(overrideWorkingDirectory) ?? preferredWorkingDirectoryForNewTab()

        // term-mesh: Create worktree sandbox if enabled and CWD is a git repo
        var worktreeInfo: WorktreeInfo?
        var gitRepoRoot: String?  // git root for worktree cleanup
        if daemon.worktreeEnabled, let cwd = workingDirectory {
            gitRepoRoot = daemon.findGitRoot(from: cwd)
            let result = daemon.createWorktreeWithError(repoPath: cwd)
            switch result {
            case .success(let info):
                workingDirectory = info.path
                worktreeInfo = info
                Logger.app.info("worktree created: \(info.name, privacy: .public) at \(info.path, privacy: .public)")
            case .failure(let error):
                let message: String
                switch error {
                case .daemonNotConnected:
                    message = "term-meshd daemon is not running.\nNew tab will open without sandbox."
                case .notGitRepo:
                    message = "Current directory is not a git repository.\nNew tab will open without sandbox."
                case .rpcError(let detail):
                    message = "Failed to create worktree: \(detail)\nNew tab will open without sandbox."
                }
                Logger.app.error("worktree error: \(message, privacy: .public)")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Worktree Sandbox"
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }

        let inheritedConfig = inheritedTerminalConfigForNewWorkspace()
        let ordinal = Self.nextPortOrdinal
        Self.nextPortOrdinal += 1
        let newWorkspace = Workspace(
            title: worktreeInfo.map { "[\($0.branch)] Terminal \(tabs.count + 1)" } ?? "Terminal \(tabs.count + 1)",
            workingDirectory: workingDirectory,
            portOrdinal: ordinal,
            configTemplate: inheritedConfig,
            command: command,
            environment: environment
        )
        // term-mesh: Store worktree metadata for auto-cleanup on tab close
        if let info = worktreeInfo {
            newWorkspace.worktreeName = info.name
            newWorkspace.worktreeRepoPath = gitRepoRoot
        }

        // term-mesh: Auto-watch the working directory for file heatmap
        if let cwd = workingDirectory, !cwd.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                daemon.watchPath(cwd)
            }
        }

        wireClosedBrowserTracking(for: newWorkspace)
        let insertIndex = newTabInsertIndex()
        if insertIndex >= 0 && insertIndex <= tabs.count {
            tabs.insert(newWorkspace, at: insertIndex)
        } else {
            tabs.append(newWorkspace)
        }
        if select {
            selectedTabId = newWorkspace.id
            NotificationCenter.default.post(
                name: .ghosttyDidFocusTab,
                object: nil,
                userInfo: [GhosttyNotificationKey.tabId: newWorkspace.id]
            )
        }
#if DEBUG
        UITestRecorder.incrementInt("addTabInvocations")
        UITestRecorder.record([
            "tabCount": String(tabs.count),
            "selectedTabId": select ? newWorkspace.id.uuidString : (selectedTabId?.uuidString ?? "")
        ])
#endif
        scheduleSessionSave()
        observeDirectoryChanges(for: newWorkspace)
        return newWorkspace
    }

    // Keep addTab as convenience alias
    @discardableResult
    func addTab(select: Bool = true) -> Workspace { addWorkspace(select: select) }

    // MARK: - Session Save/Restore

    func saveSessionState() {
        // Exclude team workspaces — they are ephemeral (agents die on restart)
        let teamWorkspaceIds = Set(
            TeamOrchestrator.shared.teams.values.map { $0.workspaceId }
        )
        let nonTeamTabs = tabs.filter { !teamWorkspaceIds.contains($0.id) }

        let workspaceStates = nonTeamTabs.map { workspace in
            SavedWorkspaceState(
                title: workspace.title,
                customTitle: workspace.customTitle,
                directory: workspace.currentDirectory,
                isPinned: workspace.isPinned,
                customColor: workspace.customColor
            )
        }
        let selectedIndex = selectedTabId.flatMap { id in
            nonTeamTabs.firstIndex(where: { $0.id == id })
        }
        let session = SavedSessionState(
            version: 1,
            workspaces: workspaceStates,
            selectedIndex: selectedIndex
        )
        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: URL(fileURLWithPath: SessionRestoreSettings.sessionFilePath), options: .atomic)
            Logger.app.info("session-restore: saved \(workspaceStates.count, privacy: .public) workspace(s)")
        } catch {
            Logger.app.error("session-restore: save failed: \(error, privacy: .public)")
        }
    }

    /// Debounced session save — coalesces rapid tab open/close/directory changes
    /// into a single disk write. Safe to call frequently.
    private var sessionSaveWorkItem: DispatchWorkItem?

    private func scheduleSessionSave() {
        sessionSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveSessionState()
        }
        sessionSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Observe currentDirectory changes on a workspace so session state is
    /// persisted when the user cd's into a different directory.
    private var directoryObservers: [UUID: AnyCancellable] = [:]

    private func observeDirectoryChanges(for workspace: Workspace) {
        directoryObservers[workspace.id] = workspace.$currentDirectory
            .dropFirst()  // skip initial value
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.scheduleSessionSave()
            }
    }

    static func loadSavedSession() -> SavedSessionState? {
        let path = SessionRestoreSettings.sessionFilePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let session = try JSONDecoder().decode(SavedSessionState.self, from: data)
            guard session.version == 1, !session.workspaces.isEmpty else { return nil }
            return session
        } catch {
            Logger.app.error("session-restore: load failed: \(error, privacy: .public)")
            return nil
        }
    }

    private func restoreSession(_ session: SavedSessionState) {
        // Remove the default workspace created by init
        tabs.removeAll()
        selectedTabId = nil

        let fm = FileManager.default
        for saved in session.workspaces {
            let directory = fm.fileExists(atPath: saved.directory)
                ? saved.directory
                : fm.homeDirectoryForCurrentUser.path
            let workspace = addWorkspace(workingDirectory: directory, select: false)
            if let customTitle = saved.customTitle {
                workspace.customTitle = customTitle
                workspace.title = customTitle
            }
            workspace.isPinned = saved.isPinned
            workspace.customColor = saved.customColor
        }

        // Restore selected tab
        if let idx = session.selectedIndex, idx >= 0, idx < tabs.count {
            selectedTabId = tabs[idx].id
        } else if let first = tabs.first {
            selectedTabId = first.id
        }
        Logger.app.info("session-restore: restored \(self.tabs.count, privacy: .public) workspace(s)")
    }

    func terminalPanelForWorkspaceConfigInheritanceSource() -> TerminalPanel? {
        guard let workspace = selectedWorkspace else { return nil }
        if let focusedTerminal = workspace.focusedTerminalPanel {
            return focusedTerminal
        }
        if let rememberedTerminal = workspace.lastRememberedTerminalPanelForConfigInheritance() {
            return rememberedTerminal
        }
        if let focusedPaneId = workspace.bonsplitController.focusedPaneId,
           let paneTerminal = workspace.terminalPanelForConfigInheritance(inPane: focusedPaneId) {
            return paneTerminal
        }
        return workspace.terminalPanelForConfigInheritance()
    }

    private func inheritedTerminalConfigForNewWorkspace() -> ghostty_surface_config_s? {
        if let sourceSurface = terminalPanelForWorkspaceConfigInheritanceSource()?.surface.surface {
            return termMeshInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_TAB
            )
        }
        if let fallbackFontPoints = selectedWorkspace?.lastRememberedTerminalFontPointsForConfigInheritance() {
            var config = ghostty_surface_config_new()
            config.font_size = fallbackFontPoints
            return config
        }
        return nil
    }

    private func normalizedWorkingDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let normalized = normalizeDirectory(directory)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    private func newTabInsertIndex() -> Int {
        let placement = WorkspacePlacementSettings.current()
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let selectedIndex = selectedTabId.flatMap { tabId in
            tabs.firstIndex(where: { $0.id == tabId })
        }
        let selectedIsPinned = selectedIndex.map { tabs[$0].isPinned } ?? false
        return WorkspacePlacementSettings.insertionIndex(
            placement: placement,
            selectedIndex: selectedIndex,
            selectedIsPinned: selectedIsPinned,
            pinnedCount: pinnedCount,
            totalCount: tabs.count
        )
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            return nil
        }
        let focusedDirectory = tab.focusedPanelId
            .flatMap { tab.panelDirectories[$0] }
        let candidate = focusedDirectory ?? tab.currentDirectory
        let normalized = normalizeDirectory(candidate)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    func moveTabToTop(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard index != 0 else { return }
        let tab = tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = tab.isPinned ? 0 : pinnedCount
        tabs.insert(tab, at: insertIndex)
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let remainingTabs = tabs.filter { !tabIds.contains($0.id) }
        let selectedPinned = selectedTabs.filter { $0.isPinned }
        let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
        let remainingPinned = remainingTabs.filter { $0.isPinned }
        let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
        tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        if tabs.count <= 1 { return true }

        let clamped = max(0, min(targetIndex, tabs.count - 1))
        if currentIndex == clamped { return true }

        let workspace = tabs.remove(at: currentIndex)
        tabs.insert(workspace, at: clamped)
        return true
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> Bool {
        guard tabs.contains(where: { $0.id == tabId }) else { return false }
        if let beforeId {
            guard let idx = tabs.firstIndex(where: { $0.id == beforeId }) else { return false }
            return reorderWorkspace(tabId: tabId, toIndex: idx)
        }
        if let afterId {
            guard let idx = tabs.firstIndex(where: { $0.id == afterId }) else { return false }
            return reorderWorkspace(tabId: tabId, toIndex: idx + 1)
        }
        return false
    }

    func setCustomTitle(tabId: UUID, title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
    }

    func clearCustomTitle(tabId: UUID) {
        setCustomTitle(tabId: tabId, title: nil)
    }

    func setTabColor(tabId: UUID, color: String?) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.setCustomColor(color)
    }

    func togglePin(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    func setPinned(_ tab: Workspace, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
    }

    private func reorderTabForPinnedState(_ tab: Workspace) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = min(pinnedCount, tabs.count)
        tabs.insert(tab, at: insertIndex)
    }

    // MARK: - Surface Directory Updates (Backwards Compatibility)

    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let normalized = normalizeDirectory(directory)
        tab.updatePanelDirectory(panelId: surfaceId, directory: normalized)
    }

    private func normalizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

    func closeWorkspace(_ workspace: Workspace) {
        guard tabs.count > 1 else { return }
        sentryBreadcrumb("workspace.close", data: ["tabCount": tabs.count - 1])

        // term-mesh: Clean up worktree sandbox if this tab was using one
        if let name = workspace.worktreeName, let repoPath = workspace.worktreeRepoPath {
            DispatchQueue.global(qos: .utility).async {
                let success = daemon.removeWorktree(repoPath: repoPath, name: name)
                Logger.app.info("worktree cleanup \(name, privacy: .public): \(success ? "ok" : "failed", privacy: .public)")
            }
        }

        notifications.clearNotifications(forTabId: workspace.id)
        unwireClosedBrowserTracking(for: workspace)
        directoryObservers.removeValue(forKey: workspace.id)

        if let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            tabs.remove(at: index)

            if selectedTabId == workspace.id {
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            }
        }
        scheduleSessionSave()
    }

    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(tabId: UUID) -> Workspace? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }

        let removed = tabs.remove(at: index)
        unwireClosedBrowserTracking(for: removed)
        directoryObservers.removeValue(forKey: removed.id)
        lastFocusedPanelByTab.removeValue(forKey: removed.id)

        if tabs.isEmpty {
            // The UI assumes each window always has at least one workspace.
            _ = addWorkspace()
            return removed
        }

        if selectedTabId == removed.id {
            let nextIndex = min(index, max(0, tabs.count - 1))
            selectedTabId = tabs[nextIndex].id
        }

        return removed
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        wireClosedBrowserTracking(for: workspace)
        let insertIndex: Int = {
            guard let index else { return tabs.count }
            return max(0, min(index, tabs.count))
        }()
        tabs.insert(workspace, at: insertIndex)
        if select {
            selectedTabId = workspace.id
        }
    }

    // Keep closeTab as convenience alias
    func closeTab(_ tab: Workspace) { closeWorkspace(tab) }
    func closeCurrentTabWithConfirmation() { closeCurrentWorkspaceWithConfirmation() }

    func closeCurrentWorkspace() {
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspace(workspace)
    }

    func closeCurrentPanelWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closePanelInvocations")
#endif
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }),
              let focusedPanelId = tab.focusedPanelId else { return }
        closePanelWithConfirmation(tab: tab, panelId: focusedPanelId)
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func closeWorkspaceWithConfirmation(_ workspace: Workspace) {
        closeWorkspaceIfRunningProcess(workspace)
    }

    func closeWorkspaceWithConfirmation(tabId: UUID) {
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func selectWorkspace(_ workspace: Workspace) {
        selectedTabId = workspace.id
    }

    // Keep selectTab as convenience alias
    func selectTab(_ tab: Workspace) { selectWorkspace(tab) }

    private func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        // macOS convention: Cmd+D = confirm destructive close (e.g. "Don't Save").
        // We only opt into this for the "close last workspace => close window" path to avoid
        // conflicting with app-level Cmd+D (split right) during normal usage.
        if acceptCmdD, let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "d"
            closeButton.keyEquivalentModifierMask = [.command]

            // Keep Return/Enter behavior by explicitly setting the default button cell.
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func closeWorkspaceIfRunningProcess(_ workspace: Workspace) {
        let willCloseWindow = tabs.count <= 1
        if workspaceNeedsConfirmClose(workspace),
           !confirmClose(
               title: "Close workspace?",
               message: "This will close the workspace and all of its panels.",
               acceptCmdD: willCloseWindow
           ) {
            return
        }
        if tabs.count <= 1 {
            // Last workspace in this window: close the window (Cmd+Shift+W behavior).
            AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
        } else {
            closeWorkspace(workspace)
        }
    }

    private func closePanelWithConfirmation(tab: Workspace, panelId: UUID) {
        // Cmd+W closes the focused Bonsplit tab (a "tab" in the UI). When the workspace only has
        // a single tab left, closing it should close the workspace (and possibly the window),
        // rather than creating a replacement terminal.
        let isLastTabInWorkspace = tab.panels.count <= 1
        if isLastTabInWorkspace {
            let willCloseWindow = tabs.count <= 1
            let needsConfirm = workspaceNeedsConfirmClose(tab)
            if needsConfirm {
                let message = willCloseWindow
                    ? "This will close the last tab and close the window."
                    : "This will close the last tab and close its workspace."
                guard confirmClose(
                    title: "Close tab?",
                    message: message,
                    acceptCmdD: willCloseWindow
                ) else { return }
            }

            notifications.clearNotifications(forTabId: tab.id)
            if willCloseWindow {
                AppDelegate.shared?.closeMainWindowContainingTabId(tab.id)
            } else {
                closeWorkspace(tab)
            }
            return
        }

        if let terminalPanel = tab.terminalPanel(for: panelId),
           terminalPanel.needsConfirmClose() {
            guard confirmClose(
                title: "Close tab?",
                message: "This will close the current tab.",
                acceptCmdD: false
            ) else { return }
        }

        // We already confirmed (if needed); bypass Bonsplit's delegate gating.
        tab.closePanel(panelId, force: true)
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        closePanelWithConfirmation(tab: tab, panelId: surfaceId)
    }

    /// Runtime close requests from Ghostty should only ever target the specific surface.
    /// They must not escalate into workspace/window-close semantics for "last tab".
    func closeRuntimeSurfaceWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

        if let terminalPanel = tab.terminalPanel(for: surfaceId),
           terminalPanel.needsConfirmClose() {
            guard confirmClose(
                title: "Close tab?",
                message: "This will close the current tab.",
                acceptCmdD: false
            ) else { return }
        }

        _ = tab.closePanel(surfaceId, force: true)
        notifications.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Runtime close requests from Ghostty without confirmation (e.g. child-exit).
    /// This path must only close the addressed surface and must never close the workspace window.
    func closeRuntimeSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

#if DEBUG
        dlog(
            "surface.close.runtime tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panelsBefore=\(tab.panels.count)"
        )
#endif

        // Keep AppKit first responder in sync with workspace focus before routing the close.
        // If split reparenting caused a temporary model/view mismatch, fallback close logic in
        // Workspace.closePanel uses focused selection to resolve the correct tab deterministically.
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        let closed = tab.closePanel(surfaceId, force: true)
#if DEBUG
        dlog(
            "surface.close.runtime.done tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) panelsAfter=\(tab.panels.count)"
        )
#endif
        notifications.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Close a panel because its child process exited (e.g. the user hit Ctrl+D).
    ///
    /// This should never prompt: the process is already gone, and Ghostty emits the
    /// `SHOW_CHILD_EXITED` action specifically so the host app can decide what to do.
    func closePanelAfterChildExited(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

#if DEBUG
        dlog(
            "surface.close.childExited tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panels=\(tab.panels.count) workspaces=\(tabs.count)"
        )
#endif

        // Child-exit on the last panel should collapse the workspace, matching explicit close
        // semantics (and close the window when it was the last workspace).
        if tab.panels.count <= 1 {
            if tabs.count <= 1 {
                if let app = AppDelegate.shared {
                    notifications.clearNotifications(forTabId: tabId)
                    app.closeMainWindowContainingTabId(tabId)
                } else {
                    // Headless/test fallback when no AppDelegate window context exists.
                    closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
                }
            } else {
                closeWorkspace(tab)
            }
            return
        }

        closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
#if DEBUG
        if termMeshEnv("UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE") == "1" {
            return true
        }
#endif
        return workspace.needsConfirmClose()
    }

    func titleForTab(_ tabId: UUID) -> String? {
        tabs.first(where: { $0.id == tabId })?.title
    }

    // MARK: - Panel/Surface ID Access

    /// Returns the focused panel ID for a tab (replaces focusedSurfaceId)
    func focusedPanelId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.focusedPanelId
    }

    /// Returns the focused panel if it's a BrowserPanel, nil otherwise
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return nil }
        return tab.panels[panelId] as? BrowserPanel
    }

    @discardableResult
    func zoomInFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedBrowser() -> Bool {
        focusedBrowserPanel?.resetZoom() ?? false
    }

    @discardableResult
    func toggleDeveloperToolsFocusedBrowser() -> Bool {
        focusedBrowserPanel?.toggleDeveloperTools() ?? false
    }

    @discardableResult
    func showJavaScriptConsoleFocusedBrowser() -> Bool {
        focusedBrowserPanel?.showDeveloperToolsConsole() ?? false
    }

    /// Backwards compatibility: returns the focused surface ID
    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        focusedPanelId(for: tabId)
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        lastFocusedPanelByTab[tabId] = surfaceId
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let terminalPanel = tab.focusedTerminalPanel else { return }
        terminalPanel.applyWindowBackgroundIfActive()
    }

    private func focusSelectedTabPanel(previousTabId: UUID?) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }

        // Try to restore previous focus
        if let restoredPanelId = lastFocusedPanelByTab[selectedTabId],
           tab.panels[restoredPanelId] != nil,
           tab.focusedPanelId != restoredPanelId {
            tab.focusPanel(restoredPanelId)
        }

        // Focus the panel
        guard let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] else { return }

        // Defer unfocusing the previous workspace's panel until ContentView confirms handoff
        // completion (new workspace has focus or timeout fallback), to avoid a visible freeze gap.
        if let previousTabId,
           let previousTab = tabs.first(where: { $0.id == previousTabId }),
           let previousPanelId = previousTab.focusedPanelId,
           previousTab.panels[previousPanelId] != nil {
            replacePendingWorkspaceUnfocusTarget(
                with: (tabId: previousTabId, panelId: previousPanelId)
            )
        }

        panel.focus()

        // For terminal panels, ensure proper focus handling
        if let terminalPanel = panel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: selectedTabId, surfaceId: panelId)
        }
    }

    func completePendingWorkspaceUnfocus(reason: String) {
        guard let pending = pendingWorkspaceUnfocusTarget else { return }
        // If this tab became selected again before handoff completion, drop the stale
        // pending entry so it cannot be flushed later and deactivate the selected workspace.
        guard Self.shouldUnfocusPendingWorkspace(
            pendingTabId: pending.tabId,
            selectedTabId: selectedTabId
        ) else {
            pendingWorkspaceUnfocusTarget = nil
#if DEBUG
            dlog(
                "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=selected_again"
            )
#endif
            return
        }
        pendingWorkspaceUnfocusTarget = nil
        unfocusWorkspacePanel(tabId: pending.tabId, panelId: pending.panelId)
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.unfocus.complete id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        } else {
            dlog(
                "ws.unfocus.complete id=none tab=\(Self.debugShortWorkspaceId(pending.tabId)) " +
                "panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        }
#endif
    }

    private func replacePendingWorkspaceUnfocusTarget(with next: (tabId: UUID, panelId: UUID)) {
        if let current = pendingWorkspaceUnfocusTarget,
           current.tabId == next.tabId,
           current.panelId == next.panelId {
            return
        }

        if let current = pendingWorkspaceUnfocusTarget {
            // Never unfocus the currently selected workspace when replacing stale pending state.
            if Self.shouldUnfocusPendingWorkspace(
                pendingTabId: current.tabId,
                selectedTabId: selectedTabId
            ) {
                unfocusWorkspacePanel(tabId: current.tabId, panelId: current.panelId)
#if DEBUG
                dlog(
                    "ws.unfocus.flush tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced"
                )
#endif
            } else {
#if DEBUG
                dlog(
                    "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced_selected"
                )
#endif
            }
        }

        pendingWorkspaceUnfocusTarget = next
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.unfocus.defer id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        } else {
            dlog(
                "ws.unfocus.defer id=none tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        }
#endif
    }

    private func unfocusWorkspacePanel(tabId: UUID, panelId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let panel = tab.panels[panelId] else { return }
        panel.unfocus()
    }

    static func shouldUnfocusPendingWorkspace(pendingTabId: UUID, selectedTabId: UUID?) -> Bool {
        selectedTabId != pendingTabId
    }

    private func markFocusedPanelReadIfActive(tabId: UUID) {
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard let panelId = focusedPanelId(for: tabId) else { return }
        markPanelReadOnFocusIfActive(tabId: tabId, panelId: panelId)
    }

    private func markPanelReadOnFocusIfActive(tabId: UUID, panelId: UUID) {
        guard selectedTabId == tabId else { return }
        guard !suppressFocusFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard notifications.hasUnreadNotification(forTabId: tabId, surfaceId: panelId) else { return }
        if let tab = tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: false)
        }
        notifications.markRead(forTabId: tabId, surfaceId: panelId)
    }

    private func enqueuePanelTitleUpdate(tabId: UUID, panelId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = PanelTitleUpdateKey(tabId: tabId, panelId: panelId)
        pendingPanelTitleUpdates[key] = trimmed
        panelTitleUpdateCoalescer.signal { [weak self] in
            self?.flushPendingPanelTitleUpdates()
        }
    }

    private func flushPendingPanelTitleUpdates() {
        guard !pendingPanelTitleUpdates.isEmpty else { return }
        let updates = pendingPanelTitleUpdates
        pendingPanelTitleUpdates.removeAll(keepingCapacity: true)
        for (key, title) in updates {
            updatePanelTitle(tabId: key.tabId, panelId: key.panelId, title: title)
        }
    }

    private func updatePanelTitle(tabId: UUID, panelId: UUID, title: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let didChange = tab.updatePanelTitle(panelId: panelId, title: title)
        guard didChange else { return }

        // Update window title if this is the selected tab and focused panel
        if selectedTabId == tabId && tab.focusedPanelId == panelId {
            updateWindowTitle(for: tab)
        }
    }

    func focusedSurfaceTitleDidChange(tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let focusedPanelId = tab.focusedPanelId,
              let title = tab.panelTitles[focusedPanelId] else { return }
        tab.applyProcessTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tab)
        }
    }

    private func updateWindowTitleForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: tab)
    }

    private func updateWindowTitle(for tab: Workspace?) {
        let title = windowTitle(for: tab)
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        targetWindow?.title = title
    }

    private func windowTitle(for tab: Workspace?) -> String {
        guard let tab else { return "Term-Mesh" }
        let trimmedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedDirectory = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "Term-Mesh" : trimmedDirectory
    }

    func focusTab(_ tabId: UUID, surfaceId: UUID? = nil, suppressFlash: Bool = false) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        if let surfaceId, tab.panels[surfaceId] != nil {
            // Keep selected-surface intent stable across selectedTabId didSet async restore.
            lastFocusedPanelByTab[tabId] = surfaceId
        }
        selectedTabId = tabId
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }

        if let surfaceId {
            if !suppressFlash {
                focusSurface(tabId: tabId, surfaceId: surfaceId)
            } else {
                tab.focusPanel(surfaceId)
            }
        }
    }

    func focusTabFromNotification(_ tabId: UUID, surfaceId: UUID? = nil) {
        let wasSelected = selectedTabId == tabId
        let desiredPanelId = surfaceId ?? tabs.first(where: { $0.id == tabId })?.focusedPanelId
#if DEBUG
        if let desiredPanelId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(tabId: tabId, surfaceId: desiredPanelId)
        }
#endif
        suppressFocusFlash = true
        focusTab(tabId, surfaceId: desiredPanelId, suppressFlash: true)
        if wasSelected {
            suppressFocusFlash = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  let tab = self.tabs.first(where: { $0.id == tabId }) else { return }
            let targetPanelId = desiredPanelId ?? tab.focusedPanelId
            guard let targetPanelId,
                  tab.panels[targetPanelId] != nil else { return }
            guard self.notifications.hasUnreadNotification(forTabId: tabId, surfaceId: targetPanelId) else { return }
            tab.triggerNotificationFocusFlash(panelId: targetPanelId, requiresSplit: false, shouldFocus: true)
            self.notifications.markRead(forTabId: tabId, surfaceId: targetPanelId)
        }
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.focusPanel(surfaceId)
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
#if DEBUG
        let nextId = tabs[nextIndex].id
        debugWorkspaceSwitchCounter &+= 1
        debugWorkspaceSwitchId = debugWorkspaceSwitchCounter
        debugWorkspaceSwitchStartTime = CACurrentMediaTime()
        dlog(
            "ws.switch.begin id=\(debugWorkspaceSwitchId) dir=next from=\(Self.debugShortWorkspaceId(currentId)) " +
            "to=\(Self.debugShortWorkspaceId(nextId)) hot=\(isWorkspaceCycleHot ? 1 : 0) tabs=\(tabs.count)"
        )
#endif
        activateWorkspaceCycleHotWindow()
        selectedTabId = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
#if DEBUG
        let prevId = tabs[prevIndex].id
        debugWorkspaceSwitchCounter &+= 1
        debugWorkspaceSwitchId = debugWorkspaceSwitchCounter
        debugWorkspaceSwitchStartTime = CACurrentMediaTime()
        dlog(
            "ws.switch.begin id=\(debugWorkspaceSwitchId) dir=prev from=\(Self.debugShortWorkspaceId(currentId)) " +
            "to=\(Self.debugShortWorkspaceId(prevId)) hot=\(isWorkspaceCycleHot ? 1 : 0) tabs=\(tabs.count)"
        )
#endif
        activateWorkspaceCycleHotWindow()
        selectedTabId = tabs[prevIndex].id
    }

    private func activateWorkspaceCycleHotWindow() {
        workspaceCycleGeneration &+= 1
        let generation = workspaceCycleGeneration
#if DEBUG
        let switchId = debugWorkspaceSwitchId
        let switchDtMs = debugWorkspaceSwitchStartTime > 0
            ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
            : 0
#endif
        if !isWorkspaceCycleHot {
            isWorkspaceCycleHot = true
#if DEBUG
            dlog(
                "ws.hot.on id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
        }

        let hadPendingCooldown = workspaceCycleCooldownTask != nil
        workspaceCycleCooldownTask?.cancel()
#if DEBUG
        if hadPendingCooldown {
            dlog(
                "ws.hot.cancelPrev id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
        }
#endif
        workspaceCycleCooldownTask = Task { [weak self, generation] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
#if DEBUG
                await MainActor.run {
                    guard let self else { return }
                    let dtMs = self.debugWorkspaceSwitchStartTime > 0
                        ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                        : 0
                    dlog(
                        "ws.hot.cooldownCanceled id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                    )
                }
#endif
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard self.workspaceCycleGeneration == generation else { return }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                dlog(
                    "ws.hot.off id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                )
#endif
                self.isWorkspaceCycleHot = false
                self.workspaceCycleCooldownTask = nil
            }
        }
    }

#if DEBUG
    func debugCurrentWorkspaceSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        guard debugWorkspaceSwitchId > 0, debugWorkspaceSwitchStartTime > 0 else { return nil }
        return (debugWorkspaceSwitchId, debugWorkspaceSwitchStartTime)
    }

    private static func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private static func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedTabId = tabs[index].id
    }

    func selectLastTab() {
        guard let lastTab = tabs.last else { return }
        selectedTabId = lastTab.id
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane of the selected workspace
    func selectNextSurface() {
        selectedWorkspace?.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected workspace
    func selectPreviousSurface() {
        selectedWorkspace?.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected workspace
    func selectSurface(at index: Int) {
        selectedWorkspace?.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected workspace
    func selectLastSurface() {
        selectedWorkspace?.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected workspace
    func newSurface() {
        // Cmd+T should always focus the newly created surface.
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true)
    }

    // MARK: - Split Creation

    /// Create a new split in the current tab
    func createSplit(direction: SplitDirection) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return }
        sentryBreadcrumb("split.create", data: ["direction": String(describing: direction)])
        _ = newSplit(tabId: selectedTabId, surfaceId: focusedPanelId, direction: direction)
    }

    /// Create a new browser split from the currently focused panel.
    @discardableResult
    func createBrowserSplit(direction: SplitDirection, url: URL? = nil) -> UUID? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return nil }
        return newBrowserSplit(
            tabId: selectedTabId,
            fromPanelId: focusedPanelId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            url: url
        )
    }

    /// Spawn N agent sessions as splits in the current workspace (F-06).
    /// Each agent gets its own worktree sandbox and is bound to its panel.
    func spawnAgentSessions(count: Int, command: String? = nil) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return }

        // Determine repo path from the focused terminal panel's directory
        let focusedDir = tab.panelDirectories[focusedPanelId] ?? ""
        let currentDir = focusedDir.isEmpty ? tab.currentDirectory : focusedDir
        guard let repoPath = daemon.findGitRoot(from: currentDir), !repoPath.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Spawn Agents"
            alert.informativeText = "Current directory is not inside a git repository."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Show indeterminate progress while spawning
        titlebarProgress = .indeterminate("Spawning \(count) agent\(count > 1 ? "s" : "")…", color: .green)

        // Spawn agent sessions via daemon (background to avoid blocking UI)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessions = daemon.spawnAgents(repoPath: repoPath, count: count, command: command)
            guard !sessions.isEmpty else {
                DispatchQueue.main.async {
                    self?.titlebarProgress = nil
                    let alert = NSAlert()
                    alert.messageText = "Spawn Agents"
                    alert.informativeText = "Failed to spawn agent sessions. Is term-meshd running?"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let tab = self.tabs.first(where: { $0.id == selectedTabId }),
                      let focusedPanelId = tab.focusedPanelId else {
                    self?.titlebarProgress = nil
                    return
                }

                let count = sessions.count

                // Grid layout: balanced grid on the right side of the leader pane.
                // Prefer fewer columns (max 3) so agent panes stay wide enough.
                // Layout: [Leader | Col1 | Col2 | ...]  each column split into rows.
                let numCols: Int
                if count <= 3 {
                    numCols = 1
                } else if count <= 8 {
                    numCols = 2
                } else {
                    numCols = 3
                }
                let numRows = Int(ceil(Double(count) / Double(numCols)))

                // Helper to bind a session to a newly created panel
                var created = 0
                let bindSession = { [weak self] (session: AgentSessionInfo, panelId: UUID) in
                    if let panel = tab.panels[panelId] as? TerminalPanel {
                        panel.agentSessionId = session.id
                        panel.updateTitle("🔀 [\(session.worktreeBranch)] \(session.name)")
                    }
                    created += 1
                    self?.titlebarProgress = .determinate(
                        Double(created) / Double(count),
                        label: "Spawning agents (\(created)/\(count))…",
                        color: .green
                    )
                    DispatchQueue.global(qos: .utility).async {
                        let _ = daemon.bindAgentPanel(
                            sessionId: session.id,
                            panelId: panelId.uuidString
                        )
                    }
                }

                // Assign sessions to grid cells: grid[col][row]
                var grid: [[Int]] = Array(repeating: [], count: numCols)
                for i in 0..<count {
                    grid[i % numCols].append(i)
                }

                // Phase 1: Create the first pane in each column (right splits from leader)
                // Split from the FIRST agent pane (not cascading) so columns stay equal width.
                var columnTopPanelIds: [UUID] = []
                var firstAgentPanelId: UUID?
                for col in 0..<numCols {
                    let sessionIdx = grid[col][0]
                    let splitFrom = firstAgentPanelId ?? focusedPanelId
                    if let panelId = self.newSplit(
                        tabId: selectedTabId,
                        surfaceId: splitFrom,
                        direction: .right,
                        focus: false,
                        workingDirectory: sessions[sessionIdx].worktreePath,
                        command: sessions[sessionIdx].command
                    ) {
                        bindSession(sessions[sessionIdx], panelId)
                        columnTopPanelIds.append(panelId)
                        if firstAgentPanelId == nil { firstAgentPanelId = panelId }
                    }
                }

                // Phase 2: Split each column down to create rows
                for col in 0..<numCols {
                    guard col < columnTopPanelIds.count else { break }
                    var lastRowPanelId = columnTopPanelIds[col]
                    for rowIdx in 1..<grid[col].count {
                        let sessionIdx = grid[col][rowIdx]
                        if let panelId = self.newSplit(
                            tabId: selectedTabId,
                            surfaceId: lastRowPanelId,
                            direction: .down,
                            focus: false,
                            workingDirectory: sessions[sessionIdx].worktreePath,
                            command: sessions[sessionIdx].command
                        ) {
                            bindSession(sessions[sessionIdx], panelId)
                            lastRowPanelId = panelId
                        }
                    }
                }

                // Phase 3: Equalize splits via tree snapshot
                // Delay to let bonsplit complete its layout pass before setting divider positions.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.equalizeAgentGrid(workspace: tab)

                    // Clear progress after a brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            self?.titlebarProgress = nil
                        }
                    }
                }
            }
        }
    }

    /// Equalize split dividers so all leaf panes get uniform size.
    /// Uses leaf-count weighting: ratio = leftLeaves / (leftLeaves + rightLeaves).
    /// This correctly handles cascading splits (e.g., 3 rows → 1/3 + 1/3 + 1/3).
    private func equalizeAgentGrid(workspace: Workspace) {
        func leafCount(_ node: ExternalTreeNode) -> Int {
            switch node {
            case .pane: return 1
            case .split(let s): return leafCount(s.first) + leafCount(s.second)
            }
        }
        func equalizeSplits(_ node: ExternalTreeNode) {
            guard case .split(let splitNode) = node else { return }
            let left = leafCount(splitNode.first)
            let right = leafCount(splitNode.second)
            let ratio = Double(left) / Double(left + right)
            if let splitId = UUID(uuidString: splitNode.id) {
                workspace.bonsplitController.setDividerPosition(CGFloat(ratio), forSplit: splitId)
            }
            equalizeSplits(splitNode.first)
            equalizeSplits(splitNode.second)
        }
        let tree = workspace.bonsplitController.treeSnapshot()
        equalizeSplits(tree)
    }

    /// Spawn N plain CLI terminal panes without worktrees.
    /// Uses the same balanced grid layout as spawnAgentSessions.
    func spawnCLISessions(count: Int, command: String? = nil, newWorkspace: Bool = false) {
        // Suppress shell banners (e.g. motd, figlet) so commands run reliably.
        let spawnEnv: [String: String] = [
            "TERMMESH_SPAWN_CLI": "1",
            "CMUX_TEAM_AGENT": "1",
        ]

        let tab: Workspace
        let rootPanelId: UUID

        if newWorkspace {
            // Create a new workspace tab with CLI panes filling the entire space.
            // Pass command directly so the shell executes it on startup (no sendText timing issues).
            let ws = addWorkspace(select: true, command: command, environment: spawnEnv)
            tab = ws
            guard let firstPanel = ws.focusedPanelId else { return }
            rootPanelId = firstPanel
            ws.setPanelCustomTitle(panelId: firstPanel, title: "CLI 1")
        } else {
            guard let selectedTabId,
                  let t = tabs.first(where: { $0.id == selectedTabId }),
                  let focusedPanelId = t.focusedPanelId else { return }
            tab = t
            rootPanelId = focusedPanelId
        }

        let tabId = tab.id

        titlebarProgress = .indeterminate("Creating \(count) terminal\(count > 1 ? "s" : "")…", color: .blue)

        // For new workspace, the first pane is already CLI 1 — create count-1 more splits
        let splitsNeeded = newWorkspace ? count - 1 : count

        let numCols: Int
        if newWorkspace {
            // New workspace: all panes are equal, no leader — use full grid
            if count <= 2 {
                numCols = count
            } else if count <= 6 {
                numCols = Int(ceil(Double(count) / 2.0))
            } else {
                numCols = Int(ceil(Double(count) / 3.0))
            }
        } else {
            if count <= 3 {
                numCols = 1
            } else if count <= 8 {
                numCols = 2
            } else {
                numCols = 3
            }
        }

        // Get working directory
        let workDir = tab.panelDirectories[rootPanelId] ?? tab.currentDirectory

        var created = newWorkspace ? 1 : 0
        let totalCount = count
        let setTitle = { [weak self] (panelId: UUID, index: Int) in
            tab.setPanelCustomTitle(panelId: panelId, title: "CLI \(index + 1)")
            created += 1
            self?.titlebarProgress = .determinate(
                Double(created) / Double(totalCount),
                label: "Creating terminals (\(created)/\(totalCount))…",
                color: .blue
            )
        }

        if newWorkspace && splitsNeeded > 0 {
            // For new workspace: build grid from the root pane
            // Assign all count panes (including root=0) to grid cells
            var grid: [[Int]] = Array(repeating: [], count: numCols)
            for i in 0..<count {
                grid[i % numCols].append(i)
            }

            // The root pane is grid[0][0]. Split right for additional columns.
            var columnTopPanelIds: [UUID] = [rootPanelId]  // col 0 = root pane
            for col in 1..<numCols {
                let idx = grid[col][0]
                if let panelId = self.newSplit(
                    tabId: tabId, surfaceId: rootPanelId,
                    direction: .right, focus: false,
                    workingDirectory: workDir, command: command,
                    environment: spawnEnv
                ) {
                    setTitle(panelId, idx)
                    columnTopPanelIds.append(panelId)
                }
            }

            // Split each column down for rows
            for col in 0..<numCols {
                guard col < columnTopPanelIds.count else { break }
                var lastRowPanelId = columnTopPanelIds[col]
                let startRow = (col == 0) ? 1 : 1  // col 0 row 0 is root (already titled)
                for rowIdx in startRow..<grid[col].count {
                    let idx = grid[col][rowIdx]
                    if let panelId = self.newSplit(
                        tabId: tabId, surfaceId: lastRowPanelId,
                        direction: .down, focus: false,
                        workingDirectory: workDir, command: command,
                        environment: spawnEnv
                    ) {
                        setTitle(panelId, idx)
                        lastRowPanelId = panelId
                    }
                }
            }
        } else if !newWorkspace {
            // Existing workspace: splits to the right of leader (original behavior)
            let numColsActual = numCols
            var grid: [[Int]] = Array(repeating: [], count: numColsActual)
            for i in 0..<count {
                grid[i % numColsActual].append(i)
            }

            var columnTopPanelIds: [UUID] = []
            var firstPanelId: UUID?
            for col in 0..<numColsActual {
                let idx = grid[col][0]
                let splitFrom = firstPanelId ?? rootPanelId
                if let panelId = self.newSplit(
                    tabId: tabId, surfaceId: splitFrom,
                    direction: .right, focus: false,
                    workingDirectory: workDir, command: command,
                    environment: spawnEnv
                ) {
                    setTitle(panelId, idx)
                    columnTopPanelIds.append(panelId)
                    if firstPanelId == nil { firstPanelId = panelId }
                }
            }

            for col in 0..<numColsActual {
                guard col < columnTopPanelIds.count else { break }
                var lastRowPanelId = columnTopPanelIds[col]
                for rowIdx in 1..<grid[col].count {
                    let idx = grid[col][rowIdx]
                    if let panelId = self.newSplit(
                        tabId: tabId, surfaceId: lastRowPanelId,
                        direction: .down, focus: false,
                        workingDirectory: workDir, command: command,
                        environment: spawnEnv
                    ) {
                        setTitle(panelId, idx)
                        lastRowPanelId = panelId
                    }
                }
            }
        }

        // Equalize splits (delay to let bonsplit complete layout pass)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.equalizeAgentGrid(workspace: tab)

            // Clear progress
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeOut(duration: 0.3)) {
                    self?.titlebarProgress = nil
                }
            }
        }
    }

    /// Reconnect a detached agent session to a new split panel.
    /// Unlike spawnAgentSessions, this does NOT create a worktree or run a command —
    /// it opens a shell in the existing worktree directory and binds the panel to the session.
    func reconnectAgentSession(sessionId: String) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let session = daemon.getAgent(id: sessionId) else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Reconnect Agent"
                    alert.informativeText = "Agent session not found."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let tab = self.tabs.first(where: { $0.id == selectedTabId }) else { return }

                if let panelId = self.newSplit(
                    tabId: selectedTabId,
                    surfaceId: focusedPanelId,
                    direction: .right,
                    focus: true,
                    workingDirectory: session.worktreePath,
                    command: nil
                ) {
                    if let panel = tab.panels[panelId] as? TerminalPanel {
                        panel.agentSessionId = session.id
                        panel.updateTitle("🔀 [\(session.worktreeBranch)] \(session.name)")
                    }
                    DispatchQueue.global(qos: .utility).async {
                        let _ = daemon.bindAgentPanel(
                            sessionId: session.id,
                            panelId: panelId.uuidString
                        )
                    }
                }
            }
        }
    }

    /// Refresh Bonsplit right-side action button tooltips for all workspaces.
    func refreshSplitButtonTooltips() {
        for workspace in tabs {
            workspace.refreshSplitButtonTooltips()
        }
    }

    // MARK: - Pane Focus Navigation

    /// Move focus to an adjacent pane in the specified direction
    func movePaneFocus(direction: NavigationDirection) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        tab.moveFocus(direction: direction)
    }

    /// Focus the next pane in sequential order (wraps around)
    func focusNextPane() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        tab.focusNextPane()
    }

    /// Focus the previous pane in sequential order (wraps around)
    func focusPrevPane() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        tab.focusPrevPane()
    }

    // MARK: - Recent Tab History Navigation

    private func recordTabInHistory(_ tabId: UUID) {
        // If we're not at the end of history, truncate forward history
        if historyIndex < tabHistory.count - 1 {
            tabHistory = Array(tabHistory.prefix(historyIndex + 1))
        }

        // Don't add duplicate consecutive entries
        if tabHistory.last == tabId {
            return
        }

        tabHistory.append(tabId)

        // Trim history if it exceeds max size
        if tabHistory.count > maxHistorySize {
            tabHistory.removeFirst(tabHistory.count - maxHistorySize)
        }

        historyIndex = tabHistory.count - 1
    }

    func navigateBack() {
        guard historyIndex > 0 else { return }

        // Find the previous valid tab in history (skip closed tabs)
        var targetIndex = historyIndex - 1
        while targetIndex >= 0 {
            let tabId = tabHistory[targetIndex]
            if tabs.contains(where: { $0.id == tabId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedTabId = tabId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            tabHistory.remove(at: targetIndex)
            historyIndex -= 1
            targetIndex -= 1
        }
    }

    func navigateForward() {
        guard historyIndex < tabHistory.count - 1 else { return }

        // Find the next valid tab in history (skip closed tabs)
        let targetIndex = historyIndex + 1
        while targetIndex < tabHistory.count {
            let tabId = tabHistory[targetIndex]
            if tabs.contains(where: { $0.id == tabId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedTabId = tabId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            tabHistory.remove(at: targetIndex)
            // Don't increment targetIndex since we removed the element
        }
    }

    var canNavigateBack: Bool {
        historyIndex > 0 && tabHistory.prefix(historyIndex).contains { tabId in
            tabs.contains { $0.id == tabId }
        }
    }

    var canNavigateForward: Bool {
        historyIndex < tabHistory.count - 1 && tabHistory.suffix(from: historyIndex + 1).contains { tabId in
            tabs.contains { $0.id == tabId }
        }
    }

    // MARK: - Split Operations (Backwards Compatibility)

    /// Create a new split in the specified direction
    /// Returns the new panel's ID (which is also the surface ID for terminals)
    func newSplit(tabId: UUID, surfaceId: UUID, direction: SplitDirection, focus: Bool = true, workingDirectory: String? = nil, command: String? = nil, environment: [String: String] = [:]) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newTerminalSplit(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            command: command,
            environment: environment
        )?.id
    }

    /// Move focus in the specified direction
    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        tab.moveFocus(direction: direction)
        return true
    }

    /// Resize split - not directly supported by bonsplit, but we can adjust divider positions
    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        // Bonsplit handles resize through its own divider dragging
        // This is a no-op for now as bonsplit manages divider positions internally
        return false
    }

    /// Equalize splits - not directly supported by bonsplit
    func equalizeSplits(tabId: UUID) -> Bool {
        // Bonsplit doesn't have a built-in equalize feature
        // This would require manually setting all divider positions to 0.5
        return false
    }

    /// Toggle zoom on the focused pane — expands it to fill the workspace.
    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        tab.togglePaneZoom()
        return true
    }

    /// Toggle zoom on the focused pane of the current workspace.
    func toggleFocusedPaneZoom() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        tab.togglePaneZoom()
    }

    /// Close a surface/panel
    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        // Guard against stale close callbacks (e.g. child-exit can trigger multiple actions).
        // A stale callback must never affect unrelated panels/workspaces.
        guard tab.panels[surfaceId] != nil,
              tab.surfaceIdFromPanelId(surfaceId) != nil else { return false }
        tab.closePanel(surfaceId)
        notifications.clearNotifications(forTabId: tabId, surfaceId: surfaceId)
        return true
    }

}
