import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CoreText


/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
///
/// **Observation.** `@Observable`, not `ObservableObject`. Every workspace stays
/// mounted — inactive ones are kept in a ZStack so their terminals survive a tab
/// switch — so with ten workspaces open, an `objectWillChange` from any one of
/// twenty-two `@Published` properties dirtied every view watching it, in every
/// workspace, whether or not it drew the thing that changed.
///
/// The rule is the same one `AgentSession` follows: **a stored property is
/// observed only if a view body reads it.** Bookkeeping, caches, callbacks and
/// close-path state are `@ObservationIgnored`. Two of those exclusions are
/// load-bearing rather than tidy:
///
/// - The lazily-filled caches below must stay out of observation because they
///   are written *during* body evaluation. A view that mutates observed state
///   while being evaluated is the AttributeGraph hazard this whole change
///   exists to avoid. Their freshness is carried by version counters instead.
/// - `processTitle` / `surfaceTTYNames` / `manualUnreadMarkedAt` were
///   deliberately never `@Published`: terminal titles change continuously, and
///   publishing them woke every sidebar subscriber. Making them observed now
///   would undo that.
@Observable @MainActor
final class Workspace: Identifiable {
    let id: UUID
    @ObservationIgnored lazy var retrievalStore = WorkspaceRetrievalStore(workspaceID: id)
    var title: String
    var customTitle: String?
    var isPinned: Bool = false
    var customColor: String?  // hex string, e.g. "#C0392B"
    /// Injected config provider (defaults to singleton for backward compatibility).
    @ObservationIgnored var configProvider: any GhosttyConfigProvider = GhosttyApp.shared

    var currentDirectory: String {
        didSet {
            invalidateSidebarBranchDirectoryEntriesCache()
            // `TabManager` used to reach this through
            // `$currentDirectory.dropFirst().removeDuplicates()`, which
            // `@Observable` has no equivalent for. The two operators it relied
            // on are reproduced here: `didSet` never runs for the value set in
            // `init`, and the comparison stands in for `removeDuplicates`.
            if oldValue != currentDirectory { onCurrentDirectoryChange?() }
        }
    }

    /// Called after `currentDirectory` actually changes. One subscriber
    /// (`TabManager`, to schedule a session save), so a callback rather than a
    /// publisher — the same shape `AgentSession.onBusyChanged` uses.
    @ObservationIgnored var onCurrentDirectoryChange: (() -> Void)?

    /// Timestamp when this workspace was created (for session duration display)
    let createdAt: Date = Date()

    /// User-assigned tag/bookmark displayed in the titlebar
    var tag: String?

    /// Ordinal for TERMMESH_PORT range assignment (monotonically increasing per app session)
    @ObservationIgnored var portOrdinal: Int = 0

    /// term-mesh: Worktree metadata for auto-cleanup on tab close.
    var worktreeName: String?
    @ObservationIgnored var worktreeRepoPath: String?
    /// Detected at runtime: true if currentDirectory is inside a git worktree (`.git` is a file, not a directory).
    var isInsideWorktree: Bool = false

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// Mapping from bonsplit TabID to our Panel instances
    var panels: [UUID: any Panel] = [:] {
        didSet {
            invalidateSidebarBranchDirectoryEntriesCache()
            invalidateDominantRemoteHostKeyCache()
            if oldValue.count != panels.count {
                panelsCountSubject.send(panels.count)
            }
            reconcileRemoteAgentPaneSessions()
        }
    }

    /// Peer sessions bound to AgentPanel panes, keyed by panel id.
    ///
    /// A remote TERMINAL pane carries its `PeerPaneSession` on the
    /// `TerminalPanel` itself and tears it down in `close()`. `AgentPanel`
    /// deliberately knows nothing about transports — the same session
    /// object serves a local process pipe and a peer relay — so the
    /// workspace keeps the binding and reconciles it against `panels`:
    /// the screen is the record, the same reasoning `SessionHostPanes`
    /// runs on. Read by `SessionHostPanes.shownSurfaceIDs()`.
    @ObservationIgnored private(set) var remoteAgentPaneSessions: [UUID: PeerPaneSession] = [:]

    /// Panel-count changes for the UI-test harnesses, which wait on a pane
    /// closing from outside SwiftUI.
    ///
    /// `CurrentValueSubject`, not `PassthroughSubject`, and that is the whole
    /// point: the `$panels` publisher this replaces delivered the current value
    /// on subscribe, so a harness that attached *after* the close it was
    /// waiting for still resolved immediately. With a passthrough it would wait
    /// for a second change that never comes and fail on its 8-second timeout.
    @ObservationIgnored private(set) lazy var panelsCountSubject =
        CurrentValueSubject<Int, Never>(panels.count)

    /// Subscriptions for panel updates (e.g., browser title changes)
    @ObservationIgnored var panelSubscriptions: [UUID: AnyCancellable] = [:]

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels)
    @ObservationIgnored var isProgrammaticSplit = false

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    @ObservationIgnored var lastTerminalConfigInheritancePanelId: UUID?
    /// Last known terminal font points from inheritance sources. Used as fallback when
    /// no live terminal surface is currently available.
    @ObservationIgnored var lastTerminalConfigInheritanceFontPoints: Float?
    /// Per-panel inherited zoom lineage. Descendants reuse this root value unless
    /// a panel is explicitly re-zoomed by the user.
    @ObservationIgnored var terminalInheritanceFontPointsByPanelId: [UUID: Float] = [:]

    /// Callback used by TabManager to capture recently closed browser panels for Cmd+Shift+T restore.
    @ObservationIgnored var onClosedBrowserPanel: ((ClosedBrowserPanelRestoreSnapshot) -> Void)?

    // MARK: - Pane Zoom

    /// Whether any pane is currently zoomed (delegates to bonsplit's native zoom).
    var isPaneZoomed: Bool { bonsplitController.isSplitZoomed }

    /// Toggle zoom on the focused pane. If already zoomed, restores original layout.
    func togglePaneZoom() {
        let wasZoomed = isPaneZoomed
        bonsplitController.togglePaneZoom()
        let isZoomed = isPaneZoomed

        if isZoomed, let zoomedPaneId = bonsplitController.zoomedPaneId {
            // Hide terminal portal views in non-zoomed panes so Metal/IOSurface
            // content doesn't render above the zoomed browser pane. Portal hosts
            // live in the window content view, outside Bonsplit's hierarchy, so
            // Bonsplit hiding the pane doesn't hide the Metal surface.
            // Bonsplit tab ids and panel ids are distinct UUID namespaces — map
            // through surfaceIdToPanelId or the zoomed pane's own terminal gets
            // hidden too and must win a SwiftUI rebind race to come back.
            let zoomedPanelIds = Set(
                bonsplitController.tabs(inPane: zoomedPaneId).compactMap { panelIdFromSurfaceId($0.id) }
            )
            for (_, panel) in panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                if !zoomedPanelIds.contains(terminal.id) {
                    terminal.hostedView.setVisibleInUI(false)
                    TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
                }
            }
        } else if wasZoomed && !isZoomed {
            // Restore portal visibility for all terminal panels after zoom exit.
            for (_, panel) in panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                terminal.hostedView.setVisibleInUI(true)
            }
        }

        // Zoom toggles don't mutate the split tree, so bonsplit emits no
        // didChangeGeometry — run the reconcile safety net explicitly so a
        // dropped anchor-geometry callback can't leave a stale-size surface.
        scheduleTerminalGeometryReconcile()

        // No manual announcement here any more. Zoom state lives in
        // `bonsplitController.zoomedPaneId`, which is itself `@Observable`, and
        // the two views that show it — the titlebar indicator and the pane
        // chrome — reach it through `isPaneZoomed`. Under `ObservableObject`
        // that read was invisible to this object, so the toggle had to announce
        // itself by hand; observation now follows the property across the
        // boundary.
    }


    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// The currently focused pane's panel ID
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return panelIdFromSurfaceId(tab.id)
    }

    /// The currently focused terminal panel (if any)
    var focusedTerminalPanel: TerminalPanel? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalPanel else {
            return nil
        }
        return panel
    }

    /// Published directory for each panel
    var panelDirectories: [UUID: String] = [:] {
        didSet { invalidateSidebarBranchDirectoryEntriesCache() }
    }
    var panelTitles: [UUID: String] = [:]
    var panelCustomTitles: [UUID: String] = [:]
    var pinnedPanelIds: Set<UUID> = []
    var manualUnreadPanelIds: Set<UUID> = []
    @ObservationIgnored var manualUnreadMarkedAt: [UUID: Date] = [:]
    nonisolated static let manualUnreadFocusGraceInterval: TimeInterval = 0.2
    nonisolated static let manualUnreadClearDelayAfterFocusFlash: TimeInterval = 0.2
    var statusEntries: [String: SidebarStatusEntry] = [:]
    var logEntries: [SidebarLogEntry] = []
    var progress: SidebarProgressState?
    var gitBranch: SidebarGitBranchState? {
        didSet { invalidateSidebarBranchDirectoryEntriesCache() }
    }
    var panelGitBranches: [UUID: SidebarGitBranchState] = [:] {
        didSet { invalidateSidebarBranchDirectoryEntriesCache() }
    }
    @ObservationIgnored private var sidebarBranchDirectoryEntriesCache: [SidebarBranchOrdering.BranchDirectoryEntry]?
    @ObservationIgnored private var sidebarBranchDirectoryDisplayLinesCache: [Bool: [SidebarBranchOrdering.BranchDirectoryDisplayLine]] = [:]
    @ObservationIgnored private(set) var sidebarBranchDirectoryEntriesComputationCount = 0
    @ObservationIgnored private(set) var sidebarBranchDirectoryDisplayLinesComputationCount = 0
    /// Outer optional tracks whether a value has been computed; the inner
    /// optional caches the common local-workspace result (`nil`) as well.
    /// Freshness tokens for the two lazily-filled caches above.
    ///
    /// The caches are `@ObservationIgnored` because they are written during
    /// body evaluation, which means a cache *hit* reads nothing observed and
    /// leaves the view with no dependency to invalidate. These counters are the
    /// dependency: each accessor reads one before consulting its cache, and
    /// each `invalidate…` advances it. Bumped only from `didSet` — the model
    /// path — never from the fill path.
    private(set) var sidebarBranchDataVersion = 0
    private(set) var dominantRemoteHostDataVersion = 0

    @ObservationIgnored private var dominantRemoteHostKeyCache: PeerPaneHostKey??
    @ObservationIgnored private var dominantRemoteHostKeyCachedFocusedPanelId: UUID?
    @ObservationIgnored private(set) var dominantRemoteHostKeyComputationCount = 0
    var surfaceListeningPorts: [UUID: [Int]] = [:]
    var listeningPorts: [Int] = []
    @ObservationIgnored var surfaceTTYNames: [UUID: String] = [:]
    var shellIntegrationHealth: [UUID: ShellIntegrationHealth] = [:]

    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    /// Deliberately unobserved. A terminal rewrites its title on every prompt
    /// and every command; publishing that stream woke every sidebar subscriber
    /// for a string most of them do not draw.
    @ObservationIgnored var processTitle: String

    enum SurfaceKind {
        static let terminal = "terminal"
        static let browser = "browser"
        static let agent = "agent"
    }

    // MARK: - Initialization

    static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip("New Terminal"),
            newBrowser: KeyboardShortcutSettings.Action.openBrowser.tooltip("New Browser"),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip("Split Right"),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip("Split Down")
        )
    }

    static func bonsplitAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        bonsplitAppearance(from: config.backgroundColor)
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        .init(backgroundHex: backgroundColor.hexString())
    }

    static func bonsplitAppearance(from backgroundColor: NSColor) -> BonsplitConfiguration.Appearance {
        let chromeColors = resolvedChromeColors(from: backgroundColor)
        return BonsplitConfiguration.Appearance(
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: chromeColors
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        applyGhosttyChrome(backgroundColor: config.backgroundColor, reason: reason)
    }

    func applyGhosttyChrome(backgroundColor: NSColor, reason: String = "unspecified") {
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let nextChromeColors = Self.resolvedChromeColors(from: backgroundColor)
        let isNoOp = currentChromeColors.backgroundHex == nextChromeColors.backgroundHex &&
            currentChromeColors.borderHex == nextChromeColors.borderHex

        configProvider.logBackgroundIfEnabled(
            "theme apply workspace=\(id.uuidString) reason=\(reason) currentBg=\(currentChromeColors.backgroundHex ?? "nil") nextBg=\(nextChromeColors.backgroundHex ?? "nil") currentBorder=\(currentChromeColors.borderHex ?? "nil") nextBorder=\(nextChromeColors.borderHex ?? "nil") noop=\(isNoOp)"
        )

        if isNoOp {
            return
        }
        bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        configProvider.logBackgroundIfEnabled(
            "theme applied workspace=\(id.uuidString) reason=\(reason) resultingBg=\(bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil") resultingBorder=\(bonsplitController.configuration.appearance.chromeColors.borderHex ?? "nil")"
        )
    }

    init(
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: ghostty_surface_config_s? = nil,
        command: String? = nil,
        environment: [String: String] = [:]
    ) {
        // Installs the reconnect observer and retries durable peer-agent
        // tombstones restored from a previous app run.
        _ = PendingPeerAgentSurfaceCleanupStore.shared
        self.id = UUID()
        self.portOrdinal = portOrdinal
        self.processTitle = title
        self.title = title
        self.customTitle = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        let effectiveDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        self.currentDirectory = effectiveDirectory
        self.isInsideWorktree = Self.detectWorktree(in: effectiveDirectory)

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // and keep split entry instantaneous.
        // Avoid re-reading/parsing Ghostty config on every new workspace; this hot path
        // runs for socket/CLI workspace creation and can cause visible typing lag.
        let appearance = Self.bonsplitAppearance(from: configProvider.defaultBackgroundColor)
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // Create initial terminal panel
        let terminalPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: configTemplate,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
            portOrdinal: portOrdinal,
            command: command,
            environment: environment
        )
        panels[terminalPanel.id] = terminalPanel
        panelTitles[terminalPanel.id] = terminalPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: terminalPanel.id, configTemplate: configTemplate)

        // Create initial tab in bonsplit and store the mapping
        var initialTabId: TabID?
        if let tabId = bonsplitController.createTab(
            title: title,
            icon: "terminal.fill",
            kind: SurfaceKind.terminal,
            isDirty: false,
            isPinned: false
        ) {
            surfaceIdToPanelId[tabId] = terminalPanel.id
            initialTabId = tabId
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self
        configurePaneHeaderActions()

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialTabId {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialTabId)
        }
    }

    private func configurePaneHeaderActions() {
        bonsplitController.paneHeaderActions = { [weak self] _, selectedTabId in
            guard let self,
                  let selectedTabId,
                  let panelId = self.panelIdFromSurfaceId(selectedTabId),
                  let panel = self.panels[panelId],
                  let agent = TeamOrchestrator.shared.agentIdentity(forPanelId: panelId),
                  let presentation = Self.agentRestartPresentation(
                      panelType: panel.panelType,
                      agentName: agent.agentName
                  ) else {
                return []
            }

            // Click = hard restart (close + respawn); Option-click = soft (ETX +
            // retype). Interactive CLIs (claude/codex/gemini) swallow Ctrl-C so
            // soft restart is effectively useless against the stuck-pane scenario
            // that drives almost every ↻ press — hard is the safer default.
            //
            // Modifier read via NSEvent.currentEvent (the actual mouse-down event)
            // rather than NSEvent.modifierFlags (process-global, can be stale by
            // the time the SwiftUI Button closure fires).
            return [
                BonsplitController.PaneHeaderAction(
                    id: "agent-restart-\(panelId.uuidString)",
                    systemImage: "arrow.clockwise",
                    help: presentation.help,
                    accessibilityLabel: presentation.accessibilityLabel,
                    action: {
                        let optionHeld =
                            NSApp.currentEvent?.modifierFlags.contains(.option)
                            ?? NSEvent.modifierFlags.contains(.option)
                        let useSoftRestart = optionHeld && presentation.allowsSoftRestart
                        #if DEBUG
                        dlog("[team.restart] header.click team=\(agent.teamName) agent=\(agent.agentName) panelType=\(panel.panelType.rawValue) optionHeld=\(optionHeld) mode=\(useSoftRestart ? "soft" : "hard")")
                        #endif
                        if useSoftRestart {
                            TeamOrchestrator.shared.restartAgentPane(panelId: panelId)
                        } else {
                            // panelId-keyed so duplicate-named agents (e.g. two
                            // `executor` panes) resolve to the exact pane the
                            // user clicked rather than the first by name.
                            Task { @MainActor in
                                _ = await TeamOrchestrator.shared.restartAgentPaneHard(
                                    panelId: panelId
                                )
                            }
                        }
                    }
                )
            ]
        }
    }

    struct AgentRestartPresentation: Equatable {
        let help: String
        let accessibilityLabel: String
        let allowsSoftRestart: Bool
    }

    /// Keep the pane-local context reset available when an agent moves from a
    /// terminal-backed panel to the native renderer. Browser panes can never be
    /// agents, while terminal panes retain their Option-click recovery shortcut.
    static func agentRestartPresentation(
        panelType: PanelType,
        agentName: String
    ) -> AgentRestartPresentation? {
        switch panelType {
        case .terminal:
            return AgentRestartPresentation(
                help: "Restart \(agentName) agent — clears conversation context (⌥-click: soft restart)",
                accessibilityLabel: "Restart \(agentName) agent and clear conversation context",
                allowsSoftRestart: true
            )
        case .agent:
            return AgentRestartPresentation(
                help: "Restart \(agentName) agent — clears conversation context",
                accessibilityLabel: "Restart \(agentName) agent and clear conversation context",
                allowsSoftRestart: false
            )
        case .browser:
            return nil
        }
    }

    func refreshSplitButtonTooltips() {
        let tooltips = Self.currentSplitButtonTooltips()
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtonTooltips != tooltips else { return }
        configuration.appearance.splitButtonTooltips = tooltips
        bonsplitController.configuration = configuration
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    @ObservationIgnored var surfaceIdToPanelId: [TabID: UUID] = [:]

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (e.g., Cmd+W "Close Tab?") so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    @ObservationIgnored var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    @ObservationIgnored var pendingCloseConfirmTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    /// Keyed by the closing tab ID, value is the tab ID we want to select next.
    @ObservationIgnored var postCloseSelectTabId: [TabID: TabID] = [:]
    /// Panel IDs that were in a pane when a pane-close operation was approved.
    /// Bonsplit pane-close does not emit per-tab didClose callbacks.
    @ObservationIgnored var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]
    @ObservationIgnored var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]
    @ObservationIgnored var isApplyingTabSelection = false
    @ObservationIgnored var pendingTabSelection: (tabId: TabID, pane: PaneID)?
    @ObservationIgnored var isReconcilingFocusState = false
    @ObservationIgnored var focusReconcileScheduled = false
    @ObservationIgnored var geometryReconcileScheduled = false
    @ObservationIgnored var isNormalizingPinnedTabOrder = false
    @ObservationIgnored var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?
    @ObservationIgnored var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    struct PendingNonFocusSplitFocusReassert {
        let generation: UInt64
        let preferredPanelId: UUID
        let splitPanelId: UUID
    }

    struct DetachedSurfaceTransfer {
        let panelId: UUID
        let panel: any Panel
        let title: String
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isLoading: Bool
        let isPinned: Bool
        let directory: String?
        let cachedTitle: String?
        let customTitle: String?
        let manuallyUnread: Bool
        /// A remote AgentPanel's peer session rides the transfer, because
        /// the binding lives on the workspace rather than the panel (see
        /// `remoteAgentPaneSessions`). Defaulted so the delegate's
        /// construction site — which never detaches one mid-flight —
        /// stays as it is; `detachSurface` fills it in on the way out.
        var remoteAgentSession: PeerPaneSession? = nil
    }

    @ObservationIgnored var detachingTabIds: Set<TabID> = []
    @ObservationIgnored var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] = [:]

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
    }


    func installBrowserPanelSubscription(_ browserPanel: BrowserPanel) {
        let subscription = Publishers.CombineLatest3(
            browserPanel.$pageTitle.removeDuplicates(),
            browserPanel.$isLoading.removeDuplicates(),
            browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] _, isLoading, favicon in
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            let nextTitle = browserPanel.displayTitle
            if self.panelTitles[browserPanel.id] != nextTitle {
                self.panelTitles[browserPanel.id] = nextTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: browserPanel.id, fallback: nextTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading

            guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconImageData: faviconUpdate,
                hasCustomTitle: self.panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
        panelSubscriptions[browserPanel.id] = subscription
    }
    // MARK: - Panel Access

    func panel(for surfaceId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromSurfaceId(surfaceId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalPanel? {
        panels[panelId] as? TerminalPanel
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        panels[panelId] as? BrowserPanel
    }

    func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal
        case .browser:
            return SurfaceKind.browser
        case .agent:
            return SurfaceKind.agent
        }
    }

    func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        let base: String
        if let custom = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            base = custom
        } else {
            base = fallbackTitle
        }
        // Remote panes carry a host chip in the tab title so mixed
        // workspaces stay legible even for non-focused panes (Phase 1
        // remote pane primitive, always-on signal).
        if let hostKey = (panels[panelId] as? TerminalPanel)?.remoteHostKey {
            let hostLabel = PeerHostProfileStore.shared.displayLabel(for: hostKey)
            if !base.hasSuffix(" ⌁ \(hostLabel)") {
                return "\(base) ⌁ \(hostLabel)"
            }
        }
        return base
    }

    func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        let isPinned = pinnedPanelIds.contains(panelId)
        if let panel = panels[panelId] {
            bonsplitController.updateTab(
                tabId,
                kind: .some(surfaceKind(for: panel)),
                isPinned: isPinned
            )
        } else {
            bonsplitController.updateTab(tabId, isPinned: isPinned)
        }
    }

    func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let shouldShowUnread = Self.shouldShowUnreadIndicator(
            hasUnreadNotification: hasUnreadNotification(panelId: panelId),
            isManuallyUnread: manualUnreadPanelIds.contains(panelId)
        )
        if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == shouldShowUnread {
            return
        }
        bonsplitController.updateTab(tabId, showsNotificationBadge: shouldShowUnread)
    }

    func normalizePinnedTabs(in paneId: PaneID) {
        guard !isNormalizingPinnedTabOrder else { return }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let tabs = bonsplitController.tabs(inPane: paneId)
        let pinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
            return pinnedPanelIds.contains(panelId)
        }
        let unpinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return true }
            return !pinnedPanelIds.contains(panelId)
        }
        let desiredOrder = pinnedTabs + unpinnedTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentTabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = currentTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = bonsplitController.reorderTab(desiredTab.id, toIndex: index)
            }
        }
    }

    func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = panelIdFromSurfaceId(tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }

    func setPanelCustomTitle(panelId: UUID, title: String?) {
        guard panels[panelId] != nil else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if trimmed.isEmpty {
            guard previous != nil else { return }
            panelCustomTitles.removeValue(forKey: panelId)
        } else {
            guard previous != trimmed else { return }
            panelCustomTitles[panelId] = trimmed
        }

        guard let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) else { return }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
    }

    func isPanelPinned(_ panelId: UUID) -> Bool {
        pinnedPanelIds.contains(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return surfaceKind(for: panel)
    }

    func panelTitle(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        let fallback = panelTitles[panelId] ?? panel.displayTitle
        return resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    func setPanelPinned(panelId: UUID, pinned: Bool) {
        guard panels[panelId] != nil else { return }
        let wasPinned = pinnedPanelIds.contains(panelId)
        guard wasPinned != pinned else { return }
        if pinned {
            pinnedPanelIds.insert(panelId)
        } else {
            pinnedPanelIds.remove(panelId)
        }

        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        normalizePinnedTabs(in: paneId)
    }

    func markPanelUnread(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        guard manualUnreadPanelIds.insert(panelId).inserted else { return }
        manualUnreadMarkedAt[panelId] = Date()
        syncUnreadBadgeStateForPanel(panelId)
    }

    func markPanelRead(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        AppDelegate.shared?.notificationStore?.markRead(forTabId: id, surfaceId: panelId)
        clearManualUnread(panelId: panelId)
    }

    func clearManualUnread(panelId: UUID) {
        let didRemoveUnread = manualUnreadPanelIds.remove(panelId) != nil
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        guard didRemoveUnread else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    static func shouldClearManualUnread(
        previousFocusedPanelId: UUID?,
        nextFocusedPanelId: UUID,
        isManuallyUnread: Bool,
        markedAt: Date?,
        now: Date = Date(),
        sameTabGraceInterval: TimeInterval = manualUnreadFocusGraceInterval
    ) -> Bool {
        guard isManuallyUnread else { return false }

        if let previousFocusedPanelId, previousFocusedPanelId != nextFocusedPanelId {
            return true
        }

        guard let markedAt else { return true }
        return now.timeIntervalSince(markedAt) >= sameTabGraceInterval
    }

    static func shouldShowUnreadIndicator(hasUnreadNotification: Bool, isManuallyUnread: Bool) -> Bool {
        hasUnreadNotification || isManuallyUnread
    }

    // MARK: - Title Management

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    func applyProcessTitle(_ title: String) {
        processTitle = title
        guard customTitle == nil else { return }
        self.title = title
    }

    func setCustomColor(_ hex: String?) {
        customColor = hex
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            self.title = processTitle
        } else {
            customTitle = trimmed
            self.title = trimmed
        }
    }

    // MARK: - Directory Updates

    func updatePanelDirectory(panelId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if DEBUG
        let oldPanelDir = panelDirectories[panelId] ?? "(nil)"
        let isFocused = panelId == focusedPanelId
        dlog("workspace.updatePanelDir panel=\(panelId.uuidString.prefix(8)) dir=\(trimmed) oldDir=\(oldPanelDir) isFocused=\(isFocused) currentDir=\(currentDirectory)")
        #endif
        if panelDirectories[panelId] != trimmed {
            panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId, currentDirectory != trimmed {
            #if DEBUG
            dlog("workspace.currentDir.changed from=\(currentDirectory) to=\(trimmed)")
            #endif
            currentDirectory = trimmed
            // Re-detect worktree when directory changes
            let wt = Self.detectWorktree(in: trimmed)
            if isInsideWorktree != wt { isInsideWorktree = wt }
        }
    }

    /// Detect if a directory is inside a git worktree.
    /// In a worktree, `.git` is a file (containing `gitdir: ...`) instead of a directory.
    static func detectWorktree(in directory: String) -> Bool {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
            return !isDir.boolValue  // .git is a file → worktree
        }
        // Walk up to find .git
        var current = directory
        while current != "/" && !current.isEmpty {
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
            let parentGit = (current as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: parentGit, isDirectory: &isDir) {
                return !isDir.boolValue
            }
        }
        return false
    }

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool, dirtyFileCount: Int? = nil) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty, dirtyFileCount: dirtyFileCount)
        let existing = panelGitBranches[panelId]
        if existing?.branch != branch || existing?.isDirty != isDirty || existing?.dirtyFileCount != dirtyFileCount {
            panelGitBranches[panelId] = state
        }
        if panelId == focusedPanelId {
            gitBranch = state
        }
        NotificationCenter.default.post(name: .ghosttyDidUpdateGitBranch, object: nil)
    }

    func recordShellIntegrationEvent(_ signal: ShellIntegrationSignal, panelId: UUID) {
        if shellIntegrationHealth[panelId] == nil {
            shellIntegrationHealth[panelId] = ShellIntegrationHealth(createdAt: Date())
        }
        shellIntegrationHealth[panelId]?.record(signal)
    }

    func clearPanelGitBranch(panelId: UUID) {
        panelGitBranches.removeValue(forKey: panelId)
        if panelId == focusedPanelId {
            gitBranch = nil
        }
        NotificationCenter.default.post(name: .ghosttyDidUpdateGitBranch, object: nil)
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var didMutate = false

        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
        }

        // Update bonsplit tab title only when this panel's title changed.
        if didMutate,
           let tabId = surfaceIdFromPanelId(panelId),
           let panel = panels[panelId] {
            let baseTitle = panelTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
            bonsplitController.updateTab(
                tabId,
                title: resolvedTitle,
                hasCustomTitle: panelCustomTitles[panelId] != nil
            )
        }

        // If this is the only panel and no custom title, update workspace title
        if panels.count == 1, customTitle == nil {
            if self.title != trimmed {
                self.title = trimmed
                didMutate = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

        return didMutate
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        shellIntegrationHealth = shellIntegrationHealth.filter { validSurfaceIds.contains($0.key) }
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }

    func sidebarOrderedPanelIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { panelIdFromSurfaceId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return SidebarBranchOrdering.orderedPanelIds(
            tree: tree,
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        SidebarBranchOrdering
            .orderedUniqueBranches(
                orderedPanelIds: sidebarOrderedPanelIds(),
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        // Register the dependency before the cache can short-circuit it.
        //
        // The cache itself is `@ObservationIgnored` — it has to be, because it
        // is filled during body evaluation. But that means a *hit* reads no
        // observed property at all, so a row drawn from a warm cache would
        // record no dependency and never redraw again: change the branch, the
        // `didSet` empties the cache, and nothing asks for it a second time.
        // This read is the dependency, and `invalidate…` below advances it.
        _ = sidebarBranchDataVersion
        if let sidebarBranchDirectoryEntriesCache {
            return sidebarBranchDirectoryEntriesCache
        }

        let entries = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: sidebarOrderedPanelIds(),
            panelBranches: panelGitBranches,
            panelDirectories: panelDirectories,
            defaultDirectory: currentDirectory,
            fallbackBranch: gitBranch
        )
        sidebarBranchDirectoryEntriesCache = entries
        sidebarBranchDirectoryEntriesComputationCount += 1
        return entries
    }

    func sidebarBranchDirectoryDisplayLines(
        showGitBranch: Bool
    ) -> [SidebarBranchOrdering.BranchDirectoryDisplayLine] {
        // Same reason as above: a cache hit must still leave a dependency.
        _ = sidebarBranchDataVersion
        if let cached = sidebarBranchDirectoryDisplayLinesCache[showGitBranch] {
            return cached
        }

        let lines = SidebarBranchOrdering.branchDirectoryDisplayLines(
            entries: sidebarBranchDirectoryEntriesInDisplayOrder(),
            showGitBranch: showGitBranch,
            homeDirectory: Self.sidebarHomeDirectory
        )
        sidebarBranchDirectoryDisplayLinesCache[showGitBranch] = lines
        sidebarBranchDirectoryDisplayLinesComputationCount += 1
        return lines
    }

    func invalidateSidebarBranchDirectoryEntriesCache() {
        sidebarBranchDirectoryEntriesCache = nil
        sidebarBranchDirectoryDisplayLinesCache.removeAll(keepingCapacity: true)
        // The observed half of the invalidation. Callers all reach here from a
        // `didSet` — the model path — which is the only place it is safe to
        // write an observed property. Never bump this while filling a cache:
        // that path runs inside body evaluation.
        sidebarBranchDataVersion &+= 1
    }

    private static let sidebarHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: - Panel Operations

    func seedTerminalInheritanceFontPoints(
        panelId: UUID,
        configTemplate: ghostty_surface_config_s?
    ) {
        guard let fontPoints = configTemplate?.font_size, fontPoints > 0 else { return }
        terminalInheritanceFontPointsByPanelId[panelId] = fontPoints
        lastTerminalConfigInheritanceFontPoints = fontPoints
    }

    func resolvedTerminalInheritanceFontPoints(
        for terminalPanel: TerminalPanel,
        sourceSurface: ghostty_surface_t,
        inheritedConfig: ghostty_surface_config_s
    ) -> Float? {
        let runtimePoints = termMeshCurrentSurfaceFontSizePoints(sourceSurface)
        if let rooted = terminalInheritanceFontPointsByPanelId[terminalPanel.id], rooted > 0 {
            if let runtimePoints, abs(runtimePoints - rooted) > 0.05 {
                // Runtime zoom changed after lineage was seeded (manual zoom on descendant);
                // treat runtime as the new root for future descendants.
                return runtimePoints
            }
            return rooted
        }
        if inheritedConfig.font_size > 0 {
            return inheritedConfig.font_size
        }
        return runtimePoints
    }

    func rememberTerminalConfigInheritanceSource(_ terminalPanel: TerminalPanel) {
        lastTerminalConfigInheritancePanelId = terminalPanel.id
        if let sourceSurface = terminalPanel.surface.surface,
           let runtimePoints = termMeshCurrentSurfaceFontSizePoints(sourceSurface) {
            let existing = terminalInheritanceFontPointsByPanelId[terminalPanel.id]
            if existing == nil || abs((existing ?? runtimePoints) - runtimePoints) > 0.05 {
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = runtimePoints
            }
            lastTerminalConfigInheritanceFontPoints =
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] ?? runtimePoints
        }
    }

    func lastRememberedTerminalPanelForConfigInheritance() -> TerminalPanel? {
        guard let panelId = lastTerminalConfigInheritancePanelId else { return nil }
        return terminalPanel(for: panelId)
    }

    func lastRememberedTerminalFontPointsForConfigInheritance() -> Float? {
        lastTerminalConfigInheritanceFontPoints
    }

    /// Candidate terminal panels used as the source when creating inherited Ghostty config.
    /// Preference order:
    /// 1) explicitly preferred terminal panel (when the caller has one),
    /// 2) selected terminal in the target pane,
    /// 3) currently focused terminal in the workspace,
    /// 4) last remembered terminal source,
    /// 5) first terminal tab in the target pane,
    /// 6) deterministic workspace fallback.
    func terminalPanelConfigInheritanceCandidates(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> [TerminalPanel] {
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        if let preferredPanelId,
           let terminalPanel = terminalPanel(for: preferredPanelId) {
            appendCandidate(terminalPanel)
        }

        if let preferredPaneId,
           let selectedSurfaceId = bonsplitController.selectedTab(inPane: preferredPaneId)?.id,
           let selectedPanelId = panelIdFromSurfaceId(selectedSurfaceId),
           let selectedTerminalPanel = terminalPanel(for: selectedPanelId) {
            appendCandidate(selectedTerminalPanel)
        }

        if let focusedTerminalPanel {
            appendCandidate(focusedTerminalPanel)
        }

        if let rememberedTerminalPanel = lastRememberedTerminalPanelForConfigInheritance() {
            appendCandidate(rememberedTerminalPanel)
        }

        if let preferredPaneId {
            for tab in bonsplitController.tabs(inPane: preferredPaneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let terminalPanel = terminalPanel(for: panelId) else { continue }
                appendCandidate(terminalPanel)
            }
        }

        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        return candidates
    }

    /// Picks the first terminal panel candidate used as the inheritance source.
    func terminalPanelForConfigInheritance(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> TerminalPanel? {
        terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ).first
    }

    func inheritedTerminalConfig(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> ghostty_surface_config_s? {
        // Walk candidates in priority order and use the first panel with a live surface.
        // This avoids returning nil when the top candidate exists but is not attached yet.
        for terminalPanel in terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            guard let sourceSurface = terminalPanel.surface.surface else { continue }
            var config = termMeshInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            if let rootedFontPoints = resolvedTerminalInheritanceFontPoints(
                for: terminalPanel,
                sourceSurface: sourceSurface,
                inheritedConfig: config
            ), rootedFontPoints > 0 {
                config.font_size = rootedFontPoints
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = rootedFontPoints
            }
            rememberTerminalConfigInheritanceSource(terminalPanel)
            if config.font_size > 0 {
                lastTerminalConfigInheritanceFontPoints = config.font_size
            }
            return config
        }

        if let fallbackFontPoints = lastTerminalConfigInheritanceFontPoints {
            var config = ghostty_surface_config_new()
            config.font_size = fallbackFontPoints
#if DEBUG
            dlog(
                "zoom.inherit fallback=lastKnownFont context=split font=\(String(format: "%.2f", fallbackFontPoints))"
            )
#endif
            return config
        }

        return nil
    }

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true,
        skipEqualization: Bool = false,
        workingDirectory: String? = nil,
        command: String? = nil,
        environment: [String: String] = [:]
    ) -> TerminalPanel? {
        // Live mirror: the host owns the layout — forward the split and
        // create nothing locally (the host's layout push materializes
        // the new pane). Gated at ENTRY, before any panel exists, so no
        // surface can leak on the forwarded path.
        if mirrorForwardsLocalActions {
            peerMirror?.forwardSplit(panelId: panelId, orientation: orientation)
            return nil
        }
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }
        let inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            command: command,
            environment: environment
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        // Seed panel directory from workingDirectory so titlebar shows correct branch
        // before shell integration reports via OSC 7.
        if let wd = workingDirectory, !wd.isEmpty {
            panelDirectories[newPanel.id] = wd
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
        // so we can hand it to focusPanel as the "move focus FROM" view.
        let previousHostedView = focusedTerminalPanel?.hostedView

        // Create the split with the new tab already present in the new pane.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

#if DEBUG
        dlog("split.created pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation)")
#endif

        // Equalize divider positions so all panes in the same orientation chain
        // get equal space (e.g., 3 horizontal panes → 33:33:33 instead of 50:25:25).
        if !skipEqualization {
            equalizeSplitDividers()
        }

        // Suppress the old view's becomeFirstResponder side-effects during SwiftUI reparenting.
        // Without this, reparenting triggers onFocus + ghostty_surface_set_focus on the old view,
        // stealing focus from the new panel and creating model/surface divergence.
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(newPanel.id, previousHostedView: previousHostedView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return newPanel
    }

    // MARK: - Session Restore Split

    /// Create a terminal split targeting a specific bonsplit PaneID.
    /// Used during session restore to rebuild saved split layouts.
    /// Returns the new pane ID, or nil if the split failed.
    @discardableResult
    func restoreSplitTerminal(
        at paneId: PaneID,
        orientation: SplitOrientation,
        directory: String
    ) -> PaneID? {
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: directory,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        // Seed panel directory so titlebar/branch render the restored cwd before
        // shell integration reports via OSC 7.
        if !directory.isEmpty {
            panelDirectories[newPanel.id] = directory
        }

        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: false) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panelDirectories.removeValue(forKey: newPanel.id)
            return nil
        }
        return newPaneId
    }

    // MARK: - Split Equalization

    /// Equalize divider positions so all leaf panes in same-orientation split
    /// chains get equal space (e.g., 3 horizontal panes → 33:33:33).
    private func equalizeSplitDividers() {
        let tree = bonsplitController.treeSnapshot()
        let updates = computeEqualizedDividers(tree)
        for (splitId, position) in updates {
            bonsplitController.setDividerPosition(position, forSplit: splitId)
        }
    }

    private func computeEqualizedDividers(_ node: ExternalTreeNode) -> [(UUID, CGFloat)] {
        guard case .split(let split) = node else { return [] }
        var updates: [(UUID, CGFloat)] = []

        let firstLeaves = countLeavesInOrientationChain(split.first, orientation: split.orientation)
        let secondLeaves = countLeavesInOrientationChain(split.second, orientation: split.orientation)
        let total = firstLeaves + secondLeaves

        if total > 1, let splitId = UUID(uuidString: split.id) {
            let newPosition = CGFloat(firstLeaves) / CGFloat(total)
            updates.append((splitId, newPosition))
        }

        updates += computeEqualizedDividers(split.first)
        updates += computeEqualizedDividers(split.second)
        return updates
    }

    /// Count leaf panes reachable through same-orientation splits.
    /// A split with a different orientation is treated as a single unit.
    private func countLeavesInOrientationChain(_ node: ExternalTreeNode, orientation: String) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let split):
            if split.orientation == orientation {
                return countLeavesInOrientationChain(split.first, orientation: orientation)
                     + countLeavesInOrientationChain(split.second, orientation: orientation)
            } else {
                return 1
            }
        }
    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(inPane paneId: PaneID, focus: Bool? = nil) -> TerminalPanel? {
        // Live mirror: forward as a host-side new-tab (keyed by the
        // pane's selected panel), create nothing locally.
        if mirrorForwardsLocalActions {
            if let tab = bonsplitController.selectedTab(inPane: paneId),
               let panelId = panelIdFromSurfaceId(tab.id)
            {
                peerMirror?.forwardNewTab(panelId: panelId)
            }
            return nil
        }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let inheritedConfig = inheritedTerminalConfig(inPane: paneId)

        // Create new terminal panel
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = newPanel.id

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            newPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }
        return newPanel
    }

    /// Phase 2B reconciler helper: a remote-pane tab (relay command/env)
    /// added to an EXISTING pane without splitting — the reconciler
    /// places it via `splitPane(movingTab:)` afterwards. Mirrors
    /// `newTerminalSurface(inPane:)`'s panel bookkeeping; never focuses.
    func newRemoteTerminalTab(
        inPane paneId: PaneID,
        command: String,
        environment: [String: String]
    ) -> TerminalPanel? {
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedTerminalConfig(inPane: paneId),
            portOrdinal: portOrdinal,
            command: command,
            environment: environment
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            newPanel.close()
            return nil
        }
        surfaceIdToPanelId[newTabId] = newPanel.id
        return newPanel
    }

    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        focus: Bool = true
    ) -> BrowserPanel? {
        // Live mirror: the host has no browser surfaces — refuse.
        if mirrorForwardsLocalActions { NSSound.beep(); return nil }
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        // Create browser panel
        let browserPanel = BrowserPanel(workspaceId: id, initialURL: url)
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newTab = Bonsplit.Tab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = browserPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Create the split with the browser tab already present.
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        // See newTerminalSplit: suppress old view's becomeFirstResponder during reparenting.
        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(browserPanel.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)

        return browserPanel
    }

    /// Split off a pane that holds an agent directly, with no terminal in it.
    ///
    /// Deliberately the browser path with the browser parts removed: the split
    /// tree only needs a panel and a tab kind, which is the point — a pane's
    /// content has never been the tree's business.
    func newAgentSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        agentName: String,
        teamName: String,
        workingDirectory: String,
        cli: String = "claude",
        color: String = "",
        focus: Bool = false
    ) -> AgentPanel? {
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds
        where bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == sourceTabId }) {
            sourcePaneId = paneId
            break
        }
        guard let paneId = sourcePaneId else { return nil }

        let agentPanel = AgentPanel(agentName: agentName, teamName: teamName,
                                    workingDirectory: workingDirectory,
                                    cli: cli, color: color)
        agentPanel.session.onDiagnostic = { [weak agentPanel] severity, detail in
            let title = agentPanel?.title ?? agentName
            let message = "Native agent \(severity == .error ? "error" : "warning"): "
                + "\(title) [\(cli)] — \(detail)"
            switch severity {
            case .warning:
                RemoteWorkLog.warning(message)
            case .error:
                RemoteWorkLog.error(message)
            }
        }
        agentPanel.session.onEnvironmentSummary = { [weak agentPanel] environment in
            let title = agentPanel?.title ?? agentName
            RemoteWorkLog.info(
                "Native environment: \(title) [\(cli)] — \(environment.liveActivityText)"
            )
            let mismatch = AgentEnvironmentComparisonStore.mismatchForNative(
                environment,
                teamName: teamName
            )
            agentPanel?.session.setEnvironmentMismatch(mismatch)
            if let mismatch {
                RemoteWorkLog.warning("\(mismatch) — team=\(teamName), agent=\(agentName)")
            }
        }
        panels[agentPanel.id] = agentPanel
        panelTitles[agentPanel.id] = agentPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: agentPanel.displayTitle,
            icon: agentPanel.displayIcon,
            kind: SurfaceKind.agent,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = agentPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Programmatic, so didSplitPane does not also conjure a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation,
                                           withTab: newTab, insertFirst: insertFirst) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: agentPanel.id)
            panelTitles.removeValue(forKey: agentPanel.id)
            return nil
        }

        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(agentPanel.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: agentPanel.id,
                previousHostedView: previousHostedView
            )
        }
        return agentPanel
    }

    func agentPanel(for panelId: UUID) -> AgentPanel? {
        panels[panelId] as? AgentPanel
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL? = nil,
        focus: Bool? = nil,
        insertAtEnd: Bool = false,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> BrowserPanel? {
        // Live mirror: the host has no browser surfaces — refuse.
        if mirrorForwardsLocalActions { NSSound.beep(); return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let browserPanel = BrowserPanel(
            workspaceId: id,
            initialURL: url,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id

        // Keyboard/browser-open paths want "new tab at end" regardless of global new-tab placement.
        if insertAtEnd {
            let targetIndex = max(0, bonsplitController.tabs(inPane: paneId).count - 1)
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            browserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }

        installBrowserPanelSubscription(browserPanel)

        return browserPanel
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
        // Live mirror: every close — socket force-closes included —
        // forwards to the host; the layout push performs the removal.
        // The reconciler's own closes run under isApplyingRemoteLayout
        // and pass through (with force, so no confirm gating).
        if mirrorForwardsLocalActions {
            peerMirror?.forwardClose(panelId: panelId)
            return false
        }
        if let tabId = surfaceIdFromPanelId(panelId) {
            if force {
                forceCloseTabIds.insert(tabId)
            }
            // Close the tab in bonsplit (this triggers delegate callback)
            return bonsplitController.closeTab(tabId)
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused, close whichever tab bonsplit marks selected in that focused pane.
        guard focusedPanelId == panelId,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
            return false
        }

        if force {
            forceCloseTabIds.insert(selected.id)
        }
        return bonsplitController.closeTab(selected.id)
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        return bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        }
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId })
    }

    /// Returns the nearest right-side sibling pane for browser placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredBrowserTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        let sourcePaneId = sourcePane.id.uuidString
        let tree = bonsplitController.treeSnapshot()
        guard let path = browserPathToPane(targetPaneId: sourcePaneId, node: tree) else { return nil }

        let layout = bonsplitController.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.branch == .first else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            browserCollectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = bonsplitController.allPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    enum BrowserPaneBranch {
        case first
        case second
    }

    struct BrowserPaneBreadcrumb {
        let split: ExternalSplitNode
        let branch: BrowserPaneBranch
    }

    func browserPathToPane(targetPaneId: String, node: ExternalTreeNode) -> [BrowserPaneBreadcrumb]? {
        switch node {
        case .pane(let paneNode):
            return paneNode.id == targetPaneId ? [] : nil
        case .split(let splitNode):
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.first) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .first))
                return path
            }
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.second) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .second))
                return path
            }
            return nil
        }
    }

    func browserCollectPaneNodes(node: ExternalTreeNode, into output: inout [ExternalPaneNode]) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            browserCollectPaneNodes(node: splitNode.first, into: &output)
            browserCollectPaneNodes(node: splitNode.second, into: &output)
        }
    }

    struct BrowserCloseFallbackPlan {
        let orientation: SplitOrientation
        let insertFirst: Bool
        let anchorPaneId: UUID?
    }

    func stageClosedBrowserRestoreSnapshotIfNeeded(for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let browserPanel = browserPanel(for: panelId),
              let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tab.id }) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }

        let fallbackPlan = browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
        )
        let resolvedURL = browserPanel.currentURL
            ?? browserPanel.webView.url
            ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))

        pendingClosedBrowserRestoreSnapshots[tab.id] = ClosedBrowserPanelRestoreSnapshot(
            workspaceId: id,
            url: resolvedURL,
            originalPaneId: pane.id,
            originalTabIndex: tabIndex,
            fallbackSplitOrientation: fallbackPlan?.orientation,
            fallbackSplitInsertFirst: fallbackPlan?.insertFirst ?? false,
            fallbackAnchorPaneId: fallbackPlan?.anchorPaneId
        )
    }

    func clearStagedClosedBrowserRestoreSnapshot(for tabId: TabID) {
        pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
    }

    func browserCloseFallbackPlan(
        forPaneId targetPaneId: String,
        in node: ExternalTreeNode
    ) -> BrowserCloseFallbackPlan? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            if case .pane(let firstPane) = splitNode.first, firstPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: true,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.second,
                        targetCenter: browserPaneCenter(firstPane)
                    )
                )
            }

            if case .pane(let secondPane) = splitNode.second, secondPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: false,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.first,
                        targetCenter: browserPaneCenter(secondPane)
                    )
                )
            }

            if let nested = browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.first) {
                return nested
            }
            return browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.second)
        }
    }

    func browserPaneCenter(_ pane: ExternalPaneNode) -> (x: Double, y: Double) {
        (
            x: pane.frame.x + (pane.frame.width * 0.5),
            y: pane.frame.y + (pane.frame.height * 0.5)
        )
    }

    func browserNearestPaneId(
        in node: ExternalTreeNode,
        targetCenter: (x: Double, y: Double)?
    ) -> UUID? {
        var panes: [ExternalPaneNode] = []
        browserCollectPaneNodes(node: node, into: &panes)
        guard !panes.isEmpty else { return nil }

        let bestPane: ExternalPaneNode?
        if let targetCenter {
            bestPane = panes.min { lhs, rhs in
                let lhsCenter = browserPaneCenter(lhs)
                let rhsCenter = browserPaneCenter(rhs)
                let lhsDistance = pow(lhsCenter.x - targetCenter.x, 2) + pow(lhsCenter.y - targetCenter.y, 2)
                let rhsDistance = pow(rhsCenter.x - targetCenter.x, 2) + pow(rhsCenter.y - targetCenter.y, 2)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.id < rhs.id
            }
        } else {
            bestPane = panes.first
        }

        guard let bestPane else { return nil }
        return UUID(uuidString: bestPane.id)
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        // Live mirror: layout is host-owned — no local pane moves.
        if mirrorForwardsLocalActions { return false }
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int) -> Bool {
        // Live mirror: single-tab panes; reorder is meaningless and the
        // layout is host-owned.
        if mirrorForwardsLocalActions { return false }
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.reorderTab(tabId, toIndex: index) else { return false }

        if let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        // Live mirror: panes cannot leave the mirrored workspace — their
        // sessions are bound to this workspace's host lease.
        if mirrorForwardsLocalActions { return nil }
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        guard panels[panelId] != nil else { return nil }

        detachingTabIds.insert(tabId)
        forceCloseTabIds.insert(tabId)
        guard bonsplitController.closeTab(tabId) else {
            detachingTabIds.remove(tabId)
            pendingDetachedSurfaces.removeValue(forKey: tabId)
            forceCloseTabIds.remove(tabId)
            return nil
        }

        guard var transfer = pendingDetachedSurfaces.removeValue(forKey: tabId) else { return nil }
        // A detach is a move, not a close: hand the agent pane's peer
        // session to the transfer so the destination workspace can adopt
        // the binding. Left behind, this workspace's deinit would tear
        // down a session the transferred pane is still consuming.
        if transfer.panel is AgentPanel {
            transfer.remoteAgentSession = remoteAgentPaneSessions.removeValue(forKey: panelId)
        }
        return transfer
    }

    @discardableResult
    func attachDetachedSurface(
        _ detached: DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard bonsplitController.allPaneIds.contains(paneId) else { return nil }
        guard panels[detached.panelId] == nil else { return nil }

        panels[detached.panelId] = detached.panel
        if let terminalPanel = detached.panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(id)
        } else if let browserPanel = detached.panel as? BrowserPanel {
            browserPanel.updateWorkspaceId(id)
            installBrowserPanelSubscription(browserPanel)
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let cachedTitle = detached.cachedTitle {
            panelTitles[detached.panelId] = cachedTitle
        }
        if let customTitle = detached.customTitle {
            panelCustomTitles[detached.panelId] = customTitle
        }
        if detached.isPinned {
            pinnedPanelIds.insert(detached.panelId)
        } else {
            pinnedPanelIds.remove(detached.panelId)
        }
        if detached.manuallyUnread {
            manualUnreadPanelIds.insert(detached.panelId)
            manualUnreadMarkedAt[detached.panelId] = .distantPast
        } else {
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
        }

        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            isPinned: detached.isPinned,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detached.panelId)
            panelDirectories.removeValue(forKey: detached.panelId)
            panelTitles.removeValue(forKey: detached.panelId)
            panelCustomTitles.removeValue(forKey: detached.panelId)
            pinnedPanelIds.remove(detached.panelId)
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
            panelSubscriptions.removeValue(forKey: detached.panelId)
            // The binding was never adopted here (that happens below), so
            // nothing reconciles it away — close the orphaned session
            // rather than leaking a live peer connection. No dismissal:
            // the daemon still holds it, and the poller reopening a fresh
            // pane is the recovery, not a repeat of a close nobody made.
            detached.remoteAgentSession?.relaySession.onPtyData = nil
            detached.remoteAgentSession?.teardown()
            return nil
        }

        surfaceIdToPanelId[newTabId] = detached.panelId
        if let session = detached.remoteAgentSession {
            // Re-key the binding here and re-point the lifecycle closures
            // at THIS workspace — the ones installed at bind time capture
            // the source workspace, whose closePanel no longer knows this
            // panel. The data-path closures (sink, onPtyData) reference
            // the session and panel directly and move for free.
            remoteAgentPaneSessions[detached.panelId] = session
            installRemoteAgentPaneLifecycle(session: session, panelId: detached.panelId)
        }
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        syncPinnedStateForTab(newTabId, panelId: detached.panelId)
        syncUnreadBadgeStateForPanel(detached.panelId)
        normalizePinnedTabs(in: paneId)

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            detached.panel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

        return detached.panelId
    }
    // MARK: - Focus Management

    func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?
    ) {
        guard let preferredPanelId, panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert()
            scheduleFocusReconcile()
            return
        }

        let generation = beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )

        // Bonsplit splitPane focuses the newly created pane and may emit one delayed
        // didSelect/didFocus callback. Re-assert focus over multiple turns so model
        // focus and AppKit first responder stay aligned with non-focus-intent splits.
        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false
                )
                self.scheduleFocusReconcile()
                self.clearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        allowPreviousHostedView: Bool
    ) {
        guard matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        guard panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if focusedPanelId == splitPanelId {
            focusPanel(
                preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil
            )
            return
        }

        guard focusedPanelId == preferredPanelId,
              let terminalPanel = terminalPanel(for: preferredPanelId) else {
            return
        }
        terminalPanel.hostedView.ensureFocus(for: id, surfaceId: preferredPanelId)
    }

    func focusPanel(_ panelId: UUID, previousHostedView: GhosttySurfaceScrollView? = nil) {
        markExplicitFocusIntent(on: panelId)
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        dlog("focus.panel panel=\(panelId.uuidString.prefix(5)) pane=\(pane)")
        FocusLogStore.shared.append("Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane)")
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView ?? focusedTerminalPanel?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == tabId
        }()

        if let targetPaneId, !selectionAlreadyConverged {
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
            bonsplitController.selectTab(tabId)
        }

        // Also focus the underlying panel
        if let panel = panels[panelId] {
            if currentlyFocusedPanelId != panelId || !selectionAlreadyConverged {
                panel.focus()
            }

            if let terminalPanel = panel as? TerminalPanel {
                // Avoid re-entrant focus loops when focus was initiated by AppKit first-responder
                // (becomeFirstResponder -> onFocus -> focusPanel).
                if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
                }
            }
        }
        if let targetPaneId {
            applyTabSelection(tabId: tabId, inPane: targetPaneId)
        }
    }

    /// Collect pane IDs in visual reading order (left→right, top→bottom).
    /// Sorts by Y position first (row), then X position (column) — like Warp's
    /// sequential navigation: move right across a row, then wrap to the next row.
    func orderedPaneIds() -> [PaneID] {
        var panes: [(id: String, x: Double, y: Double)] = []
        func walk(_ node: ExternalTreeNode) {
            switch node {
            case .pane(let p):
                panes.append((id: p.id, x: p.frame.x, y: p.frame.y))
            case .split(let s):
                walk(s.first)
                walk(s.second)
            }
        }
        walk(bonsplitController.treeSnapshot())
        let allPanes = bonsplitController.allPaneIds
        // Sort by row (Y) then column (X) for reading-order traversal
        panes.sort { a, b in
            if abs(a.y - b.y) > 1 { return a.y < b.y }
            return a.x < b.x
        }
        return panes.compactMap { p in
            allPanes.first(where: { $0.id.uuidString == p.id })
        }
    }

    /// Focus the next pane in sequential (tree) order, wrapping around.
    func focusNextPane() {
        let ordered = orderedPaneIds()
        guard ordered.count > 1, let current = bonsplitController.focusedPaneId else { return }
        guard let idx = ordered.firstIndex(of: current) else { return }
        let next = ordered[(idx + 1) % ordered.count]
        if let prevPanelId = focusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }
        bonsplitController.focusPane(next)
        if let tabId = bonsplitController.selectedTab(inPane: next)?.id {
            applyTabSelection(tabId: tabId, inPane: next)
        }
    }

    /// Focus the previous pane in sequential (tree) order, wrapping around.
    func focusPrevPane() {
        let ordered = orderedPaneIds()
        guard ordered.count > 1, let current = bonsplitController.focusedPaneId else { return }
        guard let idx = ordered.firstIndex(of: current) else { return }
        let prev = ordered[(idx - 1 + ordered.count) % ordered.count]
        if let prevPanelId = focusedPanelId, let panel = panels[prevPanelId] {
            panel.unfocus()
        }
        bonsplitController.focusPane(prev)
        if let tabId = bonsplitController.selectedTab(inPane: prev)?.id {
            applyTabSelection(tabId: tabId, inPane: prev)
        }
    }

    func moveFocus(direction: NavigationDirection) {
        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = focusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        bonsplitController.navigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < tabs.count else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane(focus: Bool? = nil) -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalSurface(inPane: focusedPaneId, focus: focus)
    }

    // MARK: - Remote peer panes (Phase 1 remote pane primitive)

    /// Phase 2B live mirror: non-nil when this workspace mirrors a host
    /// workspace. The HOST owns the layout — local structural actions
    /// forward to it instead of mutating the local tree (see the entry
    /// gates below and the delegate vetoes in
    /// Workspace+BonsplitDelegate). The controller's reconciler is the
    /// only writer, marked by `isApplyingRemoteLayout`.
    @ObservationIgnored weak var peerMirror: PeerWorkspaceMirrorController?
    var isPeerMirror: Bool { peerMirror != nil }

    /// True when a local structural action must forward to the mirror
    /// host instead of applying (mirror mode, and not currently inside
    /// the reconciler's own mutation pass).
    var mirrorForwardsLocalActions: Bool {
        guard let peerMirror else { return false }
        return !peerMirror.isApplyingRemoteLayout && !peerMirror.isTornDown
    }

    /// Host key of this workspace's "dominant" remote pane, for the
    /// titlebar/sidebar host chip (pane-mixing model — a workspace can
    /// hold a mix of local and remote panes, unlike `peerMirror` above).
    /// Prefers the focused panel's host so the chip tracks "where my
    /// keystrokes go right now" (same rationale as
    /// `PeerTitlebarAccentController`); falls back to the first remote
    /// panel found so a workspace with only remote panes (none focused,
    /// or focus on a local pane) still shows a chip. `panels` is
    /// unordered, so a workspace mixing panes from DIFFERENT hosts has
    /// no stable "first" beyond focus — rare in practice (splitting a
    /// remote pane normally stays on the same host). nil for purely
    /// local workspaces.
    var dominantRemoteHostKey: PeerPaneHostKey? {
        // See `sidebarBranchDirectoryEntriesInDisplayOrder`: the cache is
        // unobserved by necessity, so the version counter carries the
        // dependency a cache hit would otherwise skip. Reading an `Int` of our
        // own also keeps the note below true — validating a hit still does not
        // enter Bonsplit's observation graph.
        _ = dominantRemoteHostDataVersion
        if let cached = dominantRemoteHostKeyCache {
            return cached
        }
        let hostKey = computeDominantRemoteHostKey(focusedPanelId: focusedPanelId)
        dominantRemoteHostKeyCachedFocusedPanelId = focusedPanelId
        dominantRemoteHostKeyCache = .some(hostKey)
        return hostKey
    }

    private func invalidateDominantRemoteHostKeyCache() {
        dominantRemoteHostKeyCache = nil
        dominantRemoteHostKeyCachedFocusedPanelId = nil
        dominantRemoteHostDataVersion &+= 1
    }

    /// Selection callbacks already know the focused panel. Refresh from that
    /// ID so subsequent sidebar renders do not have to enter Bonsplit's
    /// observation graph merely to validate a cache hit.
    func refreshDominantRemoteHostKeyCache(focusedPanelId: UUID?) {
        if dominantRemoteHostKeyCache != nil,
           dominantRemoteHostKeyCachedFocusedPanelId == focusedPanelId {
            return
        }
        dominantRemoteHostKeyCachedFocusedPanelId = focusedPanelId
        dominantRemoteHostKeyCache = .some(
            computeDominantRemoteHostKey(focusedPanelId: focusedPanelId)
        )
    }

    private func computeDominantRemoteHostKey(focusedPanelId: UUID?) -> PeerPaneHostKey? {
        dominantRemoteHostKeyComputationCount += 1
        if let focusedPanelId,
           let focusedHostKey = (panels[focusedPanelId] as? TerminalPanel)?.remoteHostKey {
            return focusedHostKey
        }
        return panels.values.lazy.compactMap {
            ($0 as? TerminalPanel)?.remoteHostKey
        }.first
    }

    /// Host a remote peer surface as a NORMAL Bonsplit pane: split from
    /// the focused panel with the relay binary as the pane's shell, hand
    /// the panel ownership of `session`, and start pumping. Layout stays
    /// local — this is the pane-mixing model, not a workspace mirror.
    ///
    /// Returns nil when there is no focused terminal panel to split from
    /// (the caller should surface that to the user). On a relay start
    /// failure the session is torn down; the pane shows the exited relay
    /// process (t4 replaces this with a reconnect banner).
    func openRemotePane(
        session: PeerPaneSession,
        orientation: SplitOrientation = .horizontal,
        focus: Bool = true,
        from explicitSourcePanelId: UUID? = nil,
        lifetime: RemotePaneLifetime = .temporary,
        bindingRole: PaneBindingRole = .owned
    ) -> TerminalPanel? {
        // An agent surface has no terminal to put the relay helper in, and
        // this entry point returns a TerminalPanel — it cannot host one.
        // Refusing with NO side effects keeps every caller's
        // nil-means-failed teardown correct; the agent path is
        // `openRemoteAgentPane`, and `SessionHostPanes` routes there.
        guard !SessionHostPanes.isAgentSurfaceType(session.originSurface.surfaceType) else {
            RemoteWorkLog.debug(
                "Refusing to open agent surface "
                    + "\(session.surfaceTitle.isEmpty ? "<surface>" : session.surfaceTitle) "
                    + "as a terminal pane — it needs openRemoteAgentPane"
            )
            return nil
        }
        guard let sourcePanelId = explicitSourcePanelId ?? focusedPanelId,
              let panel = newTerminalSplit(
                  from: sourcePanelId,
                  orientation: orientation,
                  focus: focus,
                  command: session.relayLaunchCommand,
                  environment: session.relayEnvironment
              )
        else { return nil }
        bindRemotePane(
            session: session,
            to: panel,
            lifetime: lifetime,
            bindingRole: bindingRole
        )
        return panel
    }

    /// Replace an existing terminal panel in-place with a remote relay panel.
    ///
    /// The Bonsplit tab and pane identities stay unchanged, so callers that
    /// are turning a connection placeholder into a remote terminal do not
    /// flash a second split and then collapse the first one.
    func replaceTerminalPaneWithRemote(
        panelId: UUID,
        session: PeerPaneSession,
        lifetime: RemotePaneLifetime = .temporary,
        bindingRole: PaneBindingRole = .owned
    ) -> TerminalPanel? {
        guard let oldPanel = panels[panelId] as? TerminalPanel,
              let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId)
        else { return nil }

        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: panelId,
            inPane: paneId
        )
        let replacement = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal,
            command: session.relayLaunchCommand,
            environment: session.relayEnvironment
        )

        panels[replacement.id] = replacement
        panelTitles[replacement.id] = replacement.displayTitle
        seedTerminalInheritanceFontPoints(
            panelId: replacement.id,
            configTemplate: inheritedConfig
        )
        surfaceIdToPanelId[tabId] = replacement.id
        bonsplitController.updateTab(
            tabId,
            title: replacement.displayTitle,
            icon: .some(replacement.displayIcon),
            iconImageData: .some(nil),
            kind: .some(SurfaceKind.terminal),
            hasCustomTitle: false,
            isDirty: replacement.isDirty,
            showsNotificationBadge: false,
            isLoading: false,
            isPinned: false
        )

        AutoReplyPoller.shared.forget(panelId: panelId)
        PeerHostCoordinator.shared.invalidateTapHub(forSurfaceId: panelId)
        TerminalController.shared.v2CleanupSurface(panelId)
        retrievalStore.removeBinding(panelID: panelId)
        panels.removeValue(forKey: panelId)
        panelDirectories.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        surfaceListeningPorts.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        terminalInheritanceFontPointsByPanelId.removeValue(forKey: panelId)
        if lastTerminalConfigInheritancePanelId == panelId {
            lastTerminalConfigInheritancePanelId = nil
        }
        oldPanel.close()

        bindRemotePane(
            session: session,
            to: replacement,
            lifetime: lifetime,
            bindingRole: bindingRole
        )
        if bonsplitController.selectedTab(inPane: paneId)?.id == tabId {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
        return replacement
    }

    /// Wire a remote session to a panel whose Ghostty surface was
    /// created with the session's relay command/env: session ownership,
    /// host signals, disconnect banner, and relay start. Split out of
    /// `openRemotePane` so the workspace-mirror flow can bind a fresh
    /// workspace's INITIAL panel the same way.
    func bindRemotePane(
        session: PeerPaneSession,
        to panel: TerminalPanel,
        lifetime: RemotePaneLifetime = .temporary,
        bindingRole: PaneBindingRole = .owned
    ) {
        panel.peerPaneSession = session
        invalidateDominantRemoteHostKeyCache()
        let remotePaneID = Self.remotePaneID(from: session.originSurface.surfaceID)
        panel.remotePaneID = remotePaneID
        panel.remotePaneLifetime = lifetime
        panel.remotePaneBindingRole = bindingRole
        retrievalStore.registerPane(
            WorkspaceRemotePaneRecord(
                id: remotePaneID,
                panelID: panel.id,
                sessionID: RemoteSessionID(),
                hostLabel: PeerHostProfileStore.shared.displayLabel(for: session.lease.key),
                sshTarget: session.lease.key.sshTarget,
                title: session.surfaceTitle.isEmpty ? "Remote Terminal" : session.surfaceTitle,
                remoteRoot: session.originSurface.cwd,
                lifetime: lifetime,
                bindingRole: bindingRole,
                state: .running,
                hasUncollectedChanges: true
            ),
            localOrigin: currentDirectory
        )
        if !session.surfaceTitle.isEmpty {
            panel.updateTitle(session.surfaceTitle)
        }
        // Wheel-driven host scrollback browse (grid-snapshot hosts only —
        // the handler refuses to engage until the host sends a typed
        // snapshot, so legacy hosts keep plain local scrolling).
        panel.hostedView.scrollbackBrowseHandler = session.relaySession
        // Always-on host signal: 2pt strip in the host's accent color
        // (the focused-pane titlebar gradient complements this).
        panel.hostedView.setPeerHostStrip(
            color: PeerHostAccent.primaryColor(for: session.lease.key)
        )
        let panelId = panel.id
        session.requestPaneClose = { [weak self] in
            _ = self?.closePanel(panelId, force: true)
        }
        // Disconnect banner (portal-layer overlay): keep the pane's slot,
        // offer Reconnect (attach a fresh session + swap the pane) and
        // Close. Skipped when the pane itself initiated teardown.
        let hostLabel = String(describing: session.lease.key)
        let showBanner: @MainActor (String) -> Void = { [weak self, weak panel] reason in
            guard let self, let panel,
                  let current = panel.peerPaneSession, !current.isTorndown
            else { return }
            panel.hostedView.showPeerDisconnectBanner(
                reason: "Remote pane disconnected — \(reason)",
                onReconnect: { [weak self, weak panel] in
                    guard let self, let panel,
                          let session = panel.peerPaneSession else { return }
                    // Live mirror: individual pane reconnects would fight
                    // the reconciler — resync the whole mirror instead.
                    if let mirror = self.peerMirror {
                        Task { @MainActor in await mirror.forceResync() }
                        return
                    }
                    Task { @MainActor in
                        await PeerClientCoordinator.shared.reconnectRemotePane(
                            oldSession: session,
                            panelId: panel.id,
                            workspace: self
                        )
                    }
                },
                onClosePane: { [weak self] in
                    _ = self?.closePanel(panelId, force: true)
                }
            )
        }
        session.relaySession.onDisconnect = { showBanner(hostLabel) }
        session.relaySession.onError = { error in
            showBanner("\(hostLabel): \(String(describing: error))")
        }
        session.relaySession.onReconnecting = { [weak panel] attempt in
            panel?.hostedView.showPeerDisconnectBanner(
                reason: "Remote pane disconnected — reconnecting to \(hostLabel) (try \(attempt))…",
                onReconnect: nil,
                onClosePane: { [weak self] in
                    _ = self?.closePanel(panelId, force: true)
                }
            )
        }
        session.relaySession.onReconnected = { [weak panel] in
            panel?.hostedView.hidePeerDisconnectBanner()
        }
        PeerTitlebarAccentController.refresh()
        #if DEBUG
        dlog("peer.pane.open workspace=\(id.uuidString.prefix(8)) host=\(session.lease.key) title=\(session.surfaceTitle)")
        #endif
        // Accept the relay binary's connection once Ghostty spawns it as
        // the pane's shell. Weak panel: if the pane closes mid-start,
        // close() already ran teardown and start() unblocks with an error.
        Task { [weak panel] in
            do {
                try await session.start()
            } catch {
                NSLog("[peer-pane] relay start failed: %@", String(describing: error))
                // Banner BEFORE teardown — showBanner refuses to draw on a
                // torn-down session, and a start failure with no visible
                // error (just a dead shell) is undebuggable for the user.
                showBanner("relay start failed: \(String(describing: error))")
                session.teardown()
                _ = panel
            }
        }
    }

    // MARK: - Remote agent panes (peer-owned bridge surfaces)

    /// The remote sink threw because its relay is gone — the send had
    /// nowhere to go, and the session's notice entry should say so
    /// rather than report a nil-silently-dropped line as delivered.
    enum RemoteAgentPaneError: Error {
        case transportClosed
    }

    /// "reviewer @jw-server" — the surface's title when the host gave one,
    /// the CLI's name when it did not, and the host either way: five
    /// identical roles on five machines must stay tellable apart, the same
    /// reason the team path titles its panes "<name> @<host>". Pure so the
    /// naming is testable without a workspace.
    static func remoteAgentPaneTitle(
        surfaceTitle: String, agentCli: String, hostLabel: String
    ) -> String {
        let name = surfaceTitle.isEmpty ? agentCli : surfaceTitle
        return hostLabel.isEmpty ? name : "\(name) @\(hostLabel)"
    }

    /// Only claude is measured to take `control_request`/`interrupt` on
    /// its NDJSON stdin stream; bridged CLIs keep the local default of
    /// not offering a stop button that would do nothing.
    static func remoteAgentInterruptible(agentCli: String) -> Bool {
        agentCli == "claude"
    }

    /// Host a peer AGENT surface as a native AgentPanel pane.
    ///
    /// The terminal twin (`openRemotePane`) spawns the relay helper as the
    /// pane's shell; an agent surface has no terminal to render into, so
    /// nothing is spawned — `newAgentSplit` builds the pane and the peer
    /// session's callback delivery feeds the panel's `AgentSession`
    /// directly. The relay launch command and environment are deliberately
    /// unused here.
    ///
    /// Refuses a session attached with relay-socket delivery: its pump
    /// would wait on a helper that never dials in and the panel would sit
    /// blank forever, which is strictly worse than a visible failure.
    /// Delivery mode is fixed at attach time (`PeerRelaySession.attach`'s
    /// `ptyDelivery`), so the caller owns getting it right.
    func openRemoteAgentPane(
        session: PeerPaneSession,
        orientation: SplitOrientation = .horizontal,
        focus: Bool = true,
        from explicitSourcePanelId: UUID? = nil
    ) -> AgentPanel? {
        guard SessionHostPanes.isAgentSurfaceType(session.originSurface.surfaceType) else {
            return nil
        }
        guard case .callback = session.relaySession.ptyDelivery else {
            // Debug-level on purpose: the session-host poller retries every
            // pass, and a failure per pass must not be a log full of the
            // same line.
            RemoteWorkLog.debug(
                "Agent surface \(session.surfaceTitle.isEmpty ? "<surface>" : session.surfaceTitle) "
                    + "was attached with relay delivery; an AgentPanel needs "
                    + "callback delivery (PeerRelaySession.attach ptyDelivery)"
            )
            return nil
        }
        guard let sourcePanelId = explicitSourcePanelId ?? focusedPanelId else { return nil }
        let surface = session.originSurface
        let cli = surface.agentCli.isEmpty ? "claude" : surface.agentCli
        let hostLabel = PeerHostProfileStore.shared.displayLabel(for: session.lease.key)
        guard let panel = newAgentSplit(
            from: sourcePanelId,
            orientation: orientation,
            agentName: Self.remoteAgentPaneTitle(
                surfaceTitle: session.surfaceTitle, agentCli: cli, hostLabel: hostLabel
            ),
            teamName: "",
            workingDirectory: surface.cwd,
            cli: cli,
            focus: focus
        ) else { return nil }
        bindRemoteAgentPane(session: session, to: panel)
        #if DEBUG
        dlog(
            "peer.agentPane.open workspace=\(id.uuidString.prefix(8)) "
                + "host=\(session.lease.key) cli=\(cli) title=\(session.surfaceTitle)"
        )
        #endif
        RemoteWorkLog.info(
            "Remote agent pane attached: "
                + "\(session.surfaceTitle.isEmpty ? cli : session.surfaceTitle) on \(hostLabel)"
        )
        return panel
    }

    /// The AgentPanel counterpart of `bindRemotePane`: session ownership,
    /// input/output wiring, lifecycle, and relay start. No Ghostty surface
    /// and no relay helper exist on this path — arriving PtyData chunks
    /// are NDJSON event bytes fed straight into the panel's AgentSession,
    /// and outgoing turns leave as ordered `Input.keys` frames through the
    /// authenticated peer session.
    func bindRemoteAgentPane(session: PeerPaneSession, to panel: AgentPanel) {
        let relay = session.relaySession
        let agentSession = panel.session
        let panelId = panel.id
        remoteAgentPaneSessions[panelId] = session
        // Reattach is the drop path, deliberately: the pane's AgentSession is
        // fixed for the panel's life and `consume` is not idempotent, so a
        // replayed stream needs a fresh pane. Dropping here rebuilds it
        // against the same surface with the peer's replay behind it.
        session.requestHostReconnectReattach = { [weak self] in
            self?.dropRemoteAgentPane(panelId: panelId, reason: "host reconnected")
        }

        // Input: every NDJSON line the session writes (turns, queued
        // turns, interrupts) goes out as one Input.keys frame. Weak relay:
        // when it is gone the send must fail visibly — the session leaves
        // a notice — instead of vanishing into a released closure.
        panel.startRemote(
            interruptible: Self.remoteAgentInterruptible(agentCli: session.originSurface.agentCli),
            cli: session.originSurface.agentCli,
            sink: { [weak relay] line in
                guard let relay else { throw RemoteAgentPaneError.transportClosed }
                guard try await relay.sendRemoteKeys(line) else {
                    throw RemoteAgentPaneError.transportClosed
                }
            }
        )

        // Output: the pump delivers chunks off-main in arrival order,
        // straight into the session's receive pipeline — `consume` decodes
        // and coalesces on its own serial queue (order preserved end to
        // end) and hands the main actor only whole batches, the same
        // contract the local pipe path has. Under a streaming flood the
        // main thread therefore pays per batch, never per chunk.
        relay.onPtyData = { [weak agentSession] chunk in
            agentSession?.consume(chunk)
        }

        installRemoteAgentPaneLifecycle(session: session, panelId: panelId)

        // Callback delivery has no helper to accept, so start is quick —
        // but a failure must still be final and visible, matching
        // `bindRemotePane`'s start contract.
        Task { [weak self] in
            do {
                try await session.start()
            } catch {
                RemoteWorkLog.info(
                    "Remote agent pane failed to start: \(String(describing: error))"
                )
                self?.dropRemoteAgentPane(panelId: panelId, reason: "start failed")
            }
        }
    }

    /// Lifecycle closures that capture THIS workspace. Split from
    /// `bindRemoteAgentPane` because a cross-workspace tab detach must
    /// re-install them on the destination (`attachDetachedSurface`) — the
    /// data-path closures move with the session, these do not.
    private func installRemoteAgentPaneLifecycle(session: PeerPaneSession, panelId: UUID) {
        let relay = session.relaySession
        // Host-side close (roster/terminate): drop the pane with the
        // session, mirroring `bindRemotePane`'s requestPaneClose.
        session.requestPaneClose = { [weak self] in
            _ = self?.closePanel(panelId, force: true)
        }
        // The stream is about to repeat bytes this consumer already
        // processed (resume anchored before the requested position), and
        // `AgentSession.consume` is not idempotent — a replayed stream
        // belongs to a fresh AgentSession. `AgentPanel.session` is fixed
        // for the panel's life, so the recovery is a fresh PANE: drop this
        // one without a dismissal and let the session-host poller reopen
        // it, replay and all. The hook fires strictly before the first
        // restarted byte, and clearing `onPtyData` inside it keeps that
        // byte from reaching the retired session.
        relay.onPtyDeliveryRestart = { [weak self] in
            self?.dropRemoteAgentPane(panelId: panelId, reason: "stream rewound")
        }
        relay.onSurfaceExited = { [weak self] exitCode, signal, reason in
            await (self?.panels[panelId] as? AgentPanel)?.session
                .finishRemoteSurfaceExited(
                    exitCode: exitCode,
                    signal: signal,
                    reason: reason
                )
        }
        // Terminal death of the relay session (heartbeat kill, writer
        // failure, host teardown). Same recovery as a rewind: the daemon
        // owning the bridge is the survivability story, so if it still
        // holds the session the poller brings the pane back with the
        // replayed transcript; if the daemon is gone there is nothing to
        // show a banner for.
        relay.onDisconnect = { [weak self, weak session] in
            // A user chose Disconnect Host. Keep the transcript/pane exactly
            // where it is; only accidental loss uses the drop-and-reopen
            // recovery path below. The remote bridge remains daemon-owned.
            if session?.hostTransportWasDisconnected == true {
                RemoteWorkLog.infoOffMain(
                    "Remote agent pane transport disconnected; pane preserved"
                )
                return
            }
            self?.dropRemoteAgentPane(panelId: panelId, reason: "disconnected")
        }
        relay.onError = { error in
            RemoteWorkLog.infoOffMain(
                "Remote agent pane transport error: \(String(describing: error))"
            )
        }
    }

    /// Tear down an agent pane's peer binding WITHOUT marking a user
    /// dismissal: the daemon still holds the session, and the poller
    /// reopening it with a fresh AgentSession is the recovery path.
    /// Removing the map entry FIRST is what keeps the panels-didSet
    /// reconciler from recording this close as the user's.
    private func dropRemoteAgentPane(panelId: UUID, reason: String) {
        guard let session = remoteAgentPaneSessions.removeValue(forKey: panelId) else { return }
        #if DEBUG
        dlog("peer.agentPane.drop panel=\(panelId.uuidString.prefix(8)) reason=\(reason)")
        #endif
        session.relaySession.onPtyData = nil
        // End any in-flight turn as session_stopped so the task board is
        // not left holding an in_progress task for a pane that is going
        // away. Safe when already stopped.
        (panels[panelId] as? AgentPanel)?.session.stop()
        session.teardown()
        let surfaceID = session.originSurface.surfaceID
        let isLocalDaemonSession = Self.isLocalSessionHost(session.originSpec)
        _ = closePanel(panelId, force: true)
        // Reopen promptly when the daemon still holds the session — the
        // poller would get there on its own schedule, this just asks now.
        // "Promptly" is for the healthy cases (a rewind is one or two
        // drops); a host that disconnects every fresh attach would turn
        // the kick into a destroy/recreate spin, so past a burst the
        // governor withholds it and the reopen falls back to the poller's
        // own cadence.
        let mayReopenNow = SessionHostPanes.noteAgentPaneDropped(surfaceID: surfaceID)
        // WHICH daemon holds it decides who can bring it back, and only one
        // of the two answers is the poller's. `SessionHostPanes.reconcile()`
        // lists this Mac's own daemon socket and nothing else, so a surface
        // owned by a peer is never in its result — before this branch existed,
        // one rewind (which the comment above rightly calls a healthy case)
        // retired a peer-owned team member for good: pane gone, roster still
        // naming the closed panel, and the peer's `tm-agent-bridge` still
        // running with nothing left pointing at it. A peer's surface is
        // reattached by the team that owns the member, which is the only side
        // that knows the host, the instance, and the report wiring to restore.
        guard !isLocalDaemonSession else {
            guard mayReopenNow else {
                #if DEBUG
                dlog("peer.agentPane.drop.backoff surface reopen demoted to poller cadence")
                #endif
                return
            }
            Task { await SessionHostPanes.reconcile() }
            return
        }
        Task { @MainActor in
            // The governor means something different on this side. For a local
            // surface, withholding the kick costs nothing — the poller reopens
            // it on its own schedule anyway. A peer surface has no poller
            // behind it, so withholding would BE the permanent loss this
            // branch exists to prevent. The burst limit therefore buys a wait
            // instead of a give-up: same anti-spin effect, same eventual
            // reopen once the host settles.
            if !mayReopenNow {
                #if DEBUG
                dlog("peer.agentPane.drop.backoff peer reattach delayed one poll interval")
                #endif
                try? await Task.sleep(for: SessionHostPanes.pollInterval)
            }
            await TeamOrchestrator.shared.recoverPeerOwnedAgentPane(
                closedPanelID: panelId,
                surfaceID: surfaceID
            )
        }
    }

    /// Whether a pane session is held by THIS machine's daemon — the only
    /// surfaces `SessionHostPanes.reconcile()` can see, and therefore the only
    /// ones it can reopen.
    static func isLocalSessionHost(_ spec: PeerPaneHostSpec) -> Bool {
        guard case let .direct(sockPath) = spec else { return false }
        let daemonPath = TermMeshDaemon.shared.daemonPeerSocketPath
        guard !daemonPath.isEmpty, !sockPath.isEmpty else { return false }
        return (sockPath as NSString).standardizingPath
            == (daemonPath as NSString).standardizingPath
    }

    /// A closed agent pane must close its peer session. `TerminalPanel`
    /// does that in `close()`; `AgentPanel` has no transport of its own,
    /// so the workspace watches the panels map instead — every close
    /// funnel (tab close, pane close, workspace teardown paths that empty
    /// the map) converges here. Runs on every `panels` mutation and
    /// no-ops unless an agent binding lost its panel.
    private func reconcileRemoteAgentPaneSessions() {
        guard !remoteAgentPaneSessions.isEmpty else { return }
        for (panelId, session) in remoteAgentPaneSessions where panels[panelId] == nil {
            // A tab detach is a move, not a close: the panel is parked in
            // `pendingDetachedSurfaces` on its way to another workspace,
            // and `detachSurface` re-keys the binding when it hands the
            // transfer out.
            if pendingDetachedSurfaces.values.contains(where: { $0.panelId == panelId }) {
                continue
            }
            remoteAgentPaneSessions.removeValue(forKey: panelId)
            // Same contract as TerminalPanel.close(): a close of a
            // session-host pane stays closed — the daemon still holds the
            // session, so without this the next pass reopens it.
            SessionHostPanes.noteClosedByUser(surfaceID: session.originSurface.surfaceID)
            session.relaySession.onPtyData = nil
            session.teardown()
            #if DEBUG
            dlog("peer.agentPane.close panel=\(panelId.uuidString.prefix(8))")
            #endif
        }
    }

    /// Prepare the selected project pair on its peer.
    ///
    /// Takes no pane: the subject is two folders, and a pane is only where the
    /// work happens to be visible.
    func seedRemoteProject() async {
        RemoteWorkLog.info("Prepare Project → \(retrievalStore.targetDescription)")
        logDiagnosticContext()
        guard let binding = retrievalStore.selectedBinding else {
            let why = "No project is bound yet. Add one with the + button — a remote shell only binds a project automatically when it was spawned inside one."
            RemoteWorkLog.info(why)
            retrievalStore.errorMessage = why
            return
        }
        guard let sshTarget = sshTarget(for: binding) else {
            let why = "No connected peer matches \(binding.peerID), so its project cannot be reached."
            RemoteWorkLog.info(why)
            retrievalStore.errorMessage = why
            return
        }
        retrievalStore.errorMessage = nil

        let plan = RemoteGitCheckpointService.shared.seedPlan(
            sshTarget: sshTarget, remoteRoot: binding.remoteRoot, localOrigin: binding.localRoot
        )
        if retrievalStore.dryRun {
            RemoteWorkLog.info("Dry run — Prepare Project would:")
            for (index, step) in plan.enumerated() { RemoteWorkLog.info("  \(index + 1). \(step)") }
            return
        }
        for (index, step) in plan.enumerated() { RemoteWorkLog.debug("step \(index + 1): \(step)") }

        do {
            try await RemoteGitCheckpointService.shared.seedProjectIfNeeded(
                sshTarget: sshTarget, remoteRoot: binding.remoteRoot, localOrigin: binding.localRoot
            )
            RemoteWorkLog.info("Project is ready at \(binding.remoteRoot)")
        } catch {
            RemoteWorkLog.info("Project preparation failed: \(error.localizedDescription)")
            retrievalStore.errorMessage = error.localizedDescription
        }
    }

    /// Capture a checkpoint of the selected project pair.
    func checkpointProject(closeAfterCheckpoint: Bool = false) async {
        RemoteWorkLog.info("Checkpoint\(closeAfterCheckpoint ? " and close" : "") → \(retrievalStore.targetDescription)")
        logDiagnosticContext()
        guard let binding = retrievalStore.selectedBinding else {
            let why = "No project is bound yet, so there is nothing to check point."
            RemoteWorkLog.info(why)
            retrievalStore.errorMessage = why
            return
        }
        guard let sshTarget = sshTarget(for: binding) else {
            let why = "No connected peer matches \(binding.peerID)."
            RemoteWorkLog.info(why)
            retrievalStore.errorMessage = why
            return
        }
        let pane = retrievalStore.pane(for: binding)

        let plan = RemoteGitCheckpointService.shared.checkpointPlan(
            sshTarget: sshTarget, remoteRoot: binding.remoteRoot, localOrigin: binding.localRoot
        )
        if retrievalStore.dryRun {
            RemoteWorkLog.info("Dry run — Checkpoint would:")
            for (index, step) in plan.enumerated() { RemoteWorkLog.info("  \(index + 1). \(step)") }
            if closeAfterCheckpoint, let pane { RemoteWorkLog.info("  \(plan.count + 1). close \(pane.title)") }
            return
        }
        for (index, step) in plan.enumerated() { RemoteWorkLog.debug("step \(index + 1): \(step)") }

        if let pane { retrievalStore.beginCheckpoint(panelID: pane.panelID) }
        do {
            let result = try await RemoteGitCheckpointService.shared.checkpointAndFetch(
                paneID: pane?.id ?? RemotePaneID(),
                projectBindingID: binding.id,
                sshTarget: sshTarget,
                remoteRoot: binding.remoteRoot,
                localOrigin: binding.localRoot,
                boundary: .checkpointNow
            )
            RemoteWorkLog.info("Checkpoint captured; it is now under Incoming")
            if let pane {
                retrievalStore.completeCheckpoint(panelID: pane.panelID, result: result)
                retrievalStore.pendingClosePanelID = nil
                if closeAfterCheckpoint { _ = closePanel(pane.panelID, force: true) }
            }
        } catch {
            RemoteWorkLog.info("Checkpoint failed: \(error.localizedDescription)")
            if let pane {
                retrievalStore.failCheckpoint(panelID: pane.panelID, message: error.localizedDescription)
            } else {
                retrievalStore.errorMessage = error.localizedDescription
            }
        }
    }

    /// The ssh target for a binding's peer, from the panes attached to it.
    private func sshTarget(for binding: ProjectBinding) -> String? {
        retrievalStore.panes.first { $0.hostLabel == binding.peerID }?.sshTarget
    }

    private func logDiagnosticContext() {
        RemoteWorkLog.debug("dryRun=\(retrievalStore.dryRun) bindings=\(retrievalStore.projectBindings.count) panes=\(retrievalStore.panes.count) workspaceDir=\(currentDirectory)")
        for b in retrievalStore.projectBindings {
            RemoteWorkLog.debug("  project \(b.peerID): \(b.remoteRoot) ↔ \(b.localRoot)\(b.id == retrievalStore.selectedBinding?.id ? "  ← target" : "")")
        }
        for pane in retrievalStore.panes {
            RemoteWorkLog.debug("  pane \(pane.title) host=\(pane.hostLabel) remoteRoot=\(pane.remoteRoot.isEmpty ? "<empty>" : pane.remoteRoot)")
        }
    }

    /// Entry point for the close-confirmation sheet, which knows a pane rather
    /// than a project. Selects that pane's project and runs the same action.
    func checkpointRemotePane(panelID: UUID, closeAfterCheckpoint: Bool) async {
        if let pane = retrievalStore.pane(panelID: panelID),
           let binding = retrievalStore.projectBinding(for: pane) {
            retrievalStore.selectedBindingID = binding.id
        }
        await checkpointProject(closeAfterCheckpoint: closeAfterCheckpoint)
    }

    private func resolvedPane(panelID: UUID, action: String) -> WorkspaceRemotePaneRecord? {
        guard let pane = retrievalStore.pane(panelID: panelID) else {
            let why = "\(action) needs a remote pane, and that one is no longer open."
            RemoteWorkLog.info(why)
            retrievalStore.errorMessage = why
            return nil
        }
        return pane
    }

    func validateChangeset(_ changesetID: ChangesetID) async {
        guard let changeset = retrievalStore.incoming.first(where: { $0.id == changesetID }),
              let binding = retrievalStore.projectBindings.first(where: { $0.id == changeset.projectBindingID }) else { return }
        retrievalStore.setChangesetState(changesetID, state: .validating)
        do {
            try await RemoteGitCheckpointService.shared.validate(changeset, localOrigin: binding.localRoot)
            // `git diff --check` proves the patch is structurally clean, but it
            // does not prove the project builds or its tests pass.
            retrievalStore.setChangesetState(changesetID, state: .unverified)
        } catch {
            retrievalStore.setChangesetState(changesetID, state: .failed, error: error.localizedDescription)
        }
    }

    func applyChangeset(_ changesetID: ChangesetID) async {
        guard let changeset = retrievalStore.incoming.first(where: { $0.id == changesetID }),
              changeset.state == .validated,
              let binding = retrievalStore.projectBindings.first(where: { $0.id == changeset.projectBindingID }) else { return }
        retrievalStore.setChangesetState(changesetID, state: .applying)
        do {
            try await RemoteGitCheckpointService.shared.apply(changeset, localOrigin: binding.localRoot)
            retrievalStore.setChangesetState(changesetID, state: .applied)
        } catch {
            retrievalStore.setChangesetState(changesetID, state: .failed, error: error.localizedDescription)
        }
    }

    func discardChangeset(_ changesetID: ChangesetID) async {
        guard let changeset = retrievalStore.incoming.first(where: { $0.id == changesetID }),
              let binding = retrievalStore.projectBindings.first(where: { $0.id == changeset.projectBindingID }) else { return }
        do {
            try await RemoteGitCheckpointService.shared.discard(changeset, localOrigin: binding.localRoot)
            retrievalStore.setChangesetState(changesetID, state: .discarded)
        } catch {
            retrievalStore.setChangesetState(changesetID, state: .failed, error: error.localizedDescription)
        }
    }

    func promoteRemotePane(panelID: UUID) {
        guard let panel = terminalPanel(for: panelID) else { return }
        panel.remotePaneLifetime = .keepAlive
        retrievalStore.promote(panelID: panelID)
    }

    func linkRemotePane(panelID: UUID, to targetWorkspace: Workspace) async {
        guard targetWorkspace.id != id,
              let panel = terminalPanel(for: panelID),
              let sourceSession = panel.peerPaneSession else { return }
        promoteRemotePane(panelID: panelID)
        do {
            let linkedSession = try await PeerPaneSession.attach(
                lease: sourceSession.lease,
                surface: sourceSession.originSurface,
                title: sourceSession.surfaceTitle,
                spec: sourceSession.originSpec
            )
            guard targetWorkspace.openRemotePane(
                session: linkedSession,
                lifetime: .keepAlive,
                bindingRole: .linked
            ) != nil else {
                linkedSession.teardown()
                return
            }
        } catch {
            retrievalStore.errorMessage = error.localizedDescription
        }
    }

    /// Ask the host where this pane's shell currently is.
    ///
    /// The host reads it from the OS, so it is right even for a shell with no
    /// shell integration — and it is the only source available, since a
    /// terminal drops a remote shell's own OSC 7 report as untrusted.
    ///
    /// Costs a short-lived connection to the host, so this is for moments of
    /// intent (opening the binding sheet), not for anything that repeats.
    func remoteDirectory(for pane: WorkspaceRemotePaneRecord) async -> String? {
        guard let panel = terminalPanel(for: pane.panelID),
              let session = panel.peerPaneSession else {
            RemoteWorkLog.debug("cwd panel \(pane.panelID.uuidString.prefix(8)) has no live peer session")
            return nil
        }
        let wanted = session.originSurface.surfaceID
        do {
            let surfaces = try await PeerPaneSession.listSurfaces(on: session.lease)
            guard let match = surfaces.first(where: { $0.surfaceID == wanted }) else {
                RemoteWorkLog.debug("cwd host no longer lists this surface — it may have exited")
                return nil
            }
            return match.cwd.isEmpty ? nil : match.cwd
        } catch {
            RemoteWorkLog.debug("cwd host lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    func terminateRemotePane(panelID: UUID) async {
        guard let panel = terminalPanel(for: panelID),
              let session = panel.peerPaneSession else { return }
        do {
            try await session.relaySession.requestRemoteClose()
            _ = closePanel(panelID, force: true)
        } catch {
            retrievalStore.errorMessage = error.localizedDescription
        }
    }

    private static func remotePaneID(from data: Data) -> RemotePaneID {
        let bytes = Array(data.prefix(16))
        guard bytes.count == 16 else { return RemotePaneID() }
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return RemotePaneID(rawValue: uuid)
    }

    // MARK: - Flash/Notification Support

    func triggerFocusFlash(panelId: UUID) {
        panels[panelId]?.triggerFlash()
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard let terminalPanel = terminalPanel(for: panelId) else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        terminalPanel.triggerFlash()
    }

    func triggerDebugFlash(panelId: UUID) {
        triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: true)
    }

    // MARK: - Portal Lifecycle

    /// Hide all terminal portal views for this workspace.
    /// Called before the workspace is unmounted to prevent portal-hosted terminal
    /// views from covering browser panes in the newly selected workspace.
    func hideAllTerminalPortalViews() {
        for panel in panels.values {
            guard let terminal = panel as? TerminalPanel else { continue }
            terminal.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
        }
    }

    // MARK: - Utility

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalPanel() -> TerminalPanel {
        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: focusedPanelId,
            inPane: bonsplitController.focusedPaneId
        )
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        if let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        ) {
            surfaceIdToPanelId[newTabId] = newPanel.id
        }

        return newPanel
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for panel in panels.values {
            if let terminalPanel = panel as? TerminalPanel,
               terminalPanel.needsConfirmClose() {
                return true
            }
        }
        return false
    }

    func reconcileFocusState() {
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let dir = panelDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    func scheduleFocusReconcile() {
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    func scheduleTerminalGeometryReconcile() {
        guard !geometryReconcileScheduled else { return }
        geometryReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryReconcileScheduled = false

            for panel in self.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                terminalPanel.requestViewReattach()
                terminalPanel.hostedView.reconcileGeometryNow()
                terminalPanel.surface.forceRefresh()
            }
        }
    }

    func closeTabs(_ tabIds: [TabID], skipPinned: Bool = true) {
        for tabId in tabIds {
            if skipPinned,
               let panelId = panelIdFromSurfaceId(tabId),
               pinnedPanelIds.contains(panelId) {
                continue
            }
            _ = bonsplitController.closeTab(tabId)
        }
    }

    func tabIdsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return [] }
        return Array(tabs.prefix(index).map(\.id))
    }

    func tabIdsToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }),
              index + 1 < tabs.count else { return [] }
        return Array(tabs.suffix(from: index + 1).map(\.id))
    }

    func tabIdsToCloseOthers(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        bonsplitController.tabs(inPane: paneId)
            .map(\.id)
            .filter { $0 != anchorTabId }
    }

    func createTerminalToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newTerminalSurface(inPane: paneId, focus: true) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    func createBrowserToRight(of anchorTabId: TabID, inPane paneId: PaneID, url: URL? = nil) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(inPane: paneId, url: url, focus: true) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    func duplicateBrowserToRight(anchorTabId: TabID, inPane paneId: PaneID) {
        guard let panelId = panelIdFromSurfaceId(anchorTabId),
              let browser = browserPanel(for: panelId) else { return }
        createBrowserToRight(of: anchorTabId, inPane: paneId, url: browser.currentURL)
    }

    func promptRenamePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a custom name for this tab."
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = "Tab name"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        alert.presentAsSheet { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.setPanelCustomTitle(panelId: panelId, title: input.stringValue)
        }
    }

    isolated deinit {
        #if DEBUG
        dlog("deinit \(Self.self)")
        #endif
        let panelsToClose = panels.values.map { $0 }
        // Agent panes: their peer sessions live on the workspace, not the
        // panel (see `remoteAgentPaneSessions`), so a workspace torn down
        // with panes still in it must close them here — AgentPanel.close()
        // only stops the AgentSession.
        let agentSessionsToClose = remoteAgentPaneSessions.values.map { $0 }
        Task { @MainActor in
            panelsToClose.forEach { $0.close() }
            for session in agentSessionsToClose {
                // The dismissal too, symmetric with `TerminalPanel.close()`:
                // closing the window closed these panes, and without the
                // record the poller resurrects them in the next workspace
                // fifteen seconds later.
                SessionHostPanes.noteClosedByUser(
                    surfaceID: session.originSurface.surfaceID
                )
                session.relaySession.onPtyData = nil
                session.teardown()
            }
        }
    }
}
