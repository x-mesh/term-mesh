import SwiftUI
import AppKit
import Bonsplit

struct SidebarResizerAccessibilityModifier: ViewModifier {
    let accessibilityIdentifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}

struct VerticalTabsSidebar: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject private var notificationStore: TerminalNotificationStore
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @StateObject private var commandKeyMonitor = SidebarCommandKeyMonitor()
    @StateObject private var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    @ObservedObject private var remoteHostStore = RemoteHostStore.shared
    @ObservedObject private var teamOrchestrator = TeamOrchestrator.shared
    @ObservedObject private var activeDrag = SidebarActiveDrag.shared
    @State private var draggedTabId: UUID?
    @State private var dropIndicator: SidebarDropIndicator?
    @AppStorage(SidebarLayoutSettings.localTabsCollapsedKey)
    private var localTabsCollapsed = false
    @AppStorage(SidebarPresentationSettings.separatedSectionsEnabledKey)
    private var sidebarSeparatedSectionsEnabled = SidebarPresentationSettings.defaultSeparatedSectionsEnabled
    @AppStorage(SidebarAxisSettings.featureFlagKey)
    private var isAxisControlEnabled = true
    @AppStorage(SidebarAxisSettings.selectedAxisKey)
    private var selectedAxisRaw = SidebarAxisSettings.defaultAxis.rawValue

    /// Space at top of sidebar for traffic light buttons
    private let trafficLightPadding: CGFloat = 28
    private let tabRowSpacing: CGFloat = 2

    /// With the switch turned off there is no way to reach the Project view,
    /// so the axis has to read as Host no matter what was stored.
    private var axis: SidebarAxis {
        guard isAxisControlEnabled else { return .host }
        return SidebarAxisSettings.axis(from: selectedAxisRaw)
    }

    private var visibleLocalWorkspaceIds: [UUID] {
        SidebarPresentationSettings.visibleLocalWorkspaceIDs(
            from: tabManager.tabs.map { (id: $0.id, isPeerMirror: $0.isPeerMirror) },
            separatedSectionsEnabled: sidebarSeparatedSectionsEnabled
        )
    }

    /// A workspace from another window is in flight, so this sidebar is a
    /// place to put it. Says so with a border, because outside the Local
    /// Workspaces list there are no row indicators to imply it.
    private var isAcceptingWindowMoveDrop: Bool {
        guard let id = activeDrag.tabId else { return false }
        return !tabManager.tabs.contains { $0.id == id }
    }

    var body: some View {
        let notificationSummaryByWorkspaceId = notificationStore.sidebarSummaryCache
        let teamSnapshotByWorkspaceId = teamOrchestrator.teams.values.reduce(
            into: [UUID: SidebarTeamRuntimeSnapshot]()
        ) { result, team in
            // Preserve the old `first(where:)` behavior for the unlikely case
            // where stale team records temporarily share a workspace.
            if result[team.workspaceId] == nil {
                result[team.workspaceId] = SidebarTeamRuntimeSnapshot(
                    teamName: team.id,
                    attentionCount: teamOrchestrator.inboxItems(teamName: team.id).count,
                    agentStates: team.agents.map { agent in
                        SidebarTeamRuntimeSnapshot.AgentState(
                            agentInstanceId: agent.agentInstanceId,
                            state: teamOrchestrator.agentState(teamName: team.id, agentName: agent.name)
                        )
                    }
                )
            }
        }
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Space for traffic lights / fullscreen controls
                        Spacer()
                            .frame(height: trafficLightPadding)

                        if isAxisControlEnabled {
                            SidebarAxisPicker(
                                selection: selectedAxisRaw,
                                onSelectionChange: { selectedAxisRaw = $0 }
                            )
                                .equatable()
                                .padding(.top, 2)
                                .padding(.bottom, 2)
                        }

                        // The two axes are alternatives, not layers. Leaving
                        // Local Workspaces mounted under the Project view was
                        // the whole complaint: the switch appeared to change
                        // what the sidebar was about while the section above
                        // it — selection highlight and all — never moved.
                        switch axis {
                        case .host:
                            SidebarSectionHeader(
                                title: sidebarSeparatedSectionsEnabled ? "Local Workspaces" : "Workspaces",
                                isCollapsed: $localTabsCollapsed
                            )
                            .padding(.top, sidebarSeparatedSectionsEnabled ? 6 : 4)

                            if !localTabsCollapsed {
                                LazyVStack(spacing: tabRowSpacing) {
                                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                                        if SidebarPresentationSettings.includesInLocalWorkspaces(
                                            isPeerMirror: tab.isPeerMirror,
                                            separatedSectionsEnabled: sidebarSeparatedSectionsEnabled
                                        ) {
                                            TabItemView(
                                                tabManager: tabManager,
                                                tab: tab,
                                                index: index,
                                                isActive: tabManager.selectedTabId == tab.id,
                                                isMultiSelected: selectedTabIds.contains(tab.id),
                                                workspaceCount: tabManager.tabs.count,
                                                teamRuntimeSnapshot: teamSnapshotByWorkspaceId[tab.id],
                                                remoteHostLabel: tab.dominantRemoteHostKey.map {
                                                    PeerHostProfileStore.shared.displayLabel(for: $0)
                                                },
                                                notificationSummary: notificationSummaryByWorkspaceId[tab.id] ?? SidebarNotificationSummary(),
                                                visibleTabIds: visibleLocalWorkspaceIds,
                                                rowSpacing: tabRowSpacing,
                                                selection: $selection,
                                                selectedTabIds: $selectedTabIds,
                                                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                                                showsCommandShortcutHints: commandKeyMonitor.isCommandPressed,
                                                dragAutoScrollController: dragAutoScrollController,
                                                draggedTabId: $draggedTabId,
                                                dropIndicator: $dropIndicator
                                            )
                                            .equatable()
                                        }
                                    }
                                }
                                .padding(.bottom, 8)
                                .padding(.top, 2)
                            }

                            SidebarRemoteHostsSection(
                                store: remoteHostStore,
                                usesSeparatedPresentation: sidebarSeparatedSectionsEnabled
                            )
                            .equatable()
                        case .project:
                            SidebarProjectsSection(
                                store: remoteHostStore,
                                usesSeparatedPresentation: sidebarSeparatedSectionsEnabled
                            )
                        }

                        if let selectedWorkspace = tabManager.tabs.first(where: { $0.id == tabManager.selectedTabId }) {
                            WorkspaceRetrievalSidebarSection(workspace: selectedWorkspace)
                        }

                        SidebarEmptyArea(
                            rowSpacing: tabRowSpacing,
                            selection: $selection,
                            selectedTabIds: $selectedTabIds,
                            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                            dragAutoScrollController: dragAutoScrollController,
                            draggedTabId: $draggedTabId,
                            dropIndicator: $dropIndicator
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .background(
                    SidebarScrollViewResolver { scrollView in
                        dragAutoScrollController.attach(scrollView: scrollView)
                    }
                    .frame(width: 0, height: 0)
                )
                .overlay(alignment: .top) {
                    SidebarTopScrim(height: trafficLightPadding + 20)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    // Double-click the sidebar title-bar area to zoom the
                    // window, matching the panel top-bar behaviour.
                    DoubleClickZoomView()
                        .frame(height: trafficLightPadding)
                }
                .background(Color.clear)
                .modifier(ClearScrollBackground())
                // Last in line: the row and empty-area delegates above take
                // their drops first, and whatever they leave — the Projects
                // axis, the Remote Hosts section, a list too full to leave any
                // empty area — lands here as a move into this window.
                .onDrop(
                    of: [SidebarTabDragPayload.typeIdentifier],
                    delegate: SidebarWindowMoveDropDelegate(
                        tabManager: tabManager,
                        selectedTabIds: $selectedTabIds,
                        lastSidebarSelectionIndex: $lastSidebarSelectionIndex
                    )
                )
                .overlay {
                    if isAcceptingWindowMoveDrop {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
            }
            SidebarWorktreeSandboxToggle()
                .frame(maxWidth: .infinity, alignment: .leading)

            // Restore Fleet — crash-recovery banner. Empty when no live
            // snapshots were found at launch (or all were restored/dismissed).
            SidebarFleetRestoreBanner()
                .frame(maxWidth: .infinity, alignment: .leading)

            // Phase 2.5 — resumable team counter. Hidden when count == 0.
            SidebarResumableFooter()
                .frame(maxWidth: .infinity, alignment: .leading)

#if DEBUG
            SidebarDevFooter(updateViewModel: updateViewModel)
                .frame(maxWidth: .infinity, alignment: .leading)
#else
            UpdatePill(model: updateViewModel)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
#endif
        }
        .accessibilityIdentifier("Sidebar")
        .ignoresSafeArea()
        .background(SidebarBackdrop().ignoresSafeArea())
        .background(
            WindowAccessor { window in
                commandKeyMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            commandKeyMonitor.start()
            draggedTabId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_appear"
            )
        }
        .onDisappear {
            commandKeyMonitor.stop()
            dragAutoScrollController.stop()
            dragFailsafeMonitor.stop()
            draggedTabId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_disappear"
            )
        }
        .onChange(of: draggedTabId) { newDraggedTabId in
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: newDraggedTabId,
                reason: "drag_state_change"
            )
#if DEBUG
            dlog("sidebar.dragState.sidebar tab=\(debugShortSidebarTabId(newDraggedTabId))")
#endif
            if newDraggedTabId != nil {
                dragFailsafeMonitor.start {
                    SidebarDragLifecycleNotification.postClearRequest(reason: $0)
                }
                return
            }
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dropIndicator = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.requestClear)) { notification in
            let reason = SidebarDragLifecycleNotification.reason(from: notification)
            // The app-wide source is cleared even when this window never held
            // the drag: a peer row drags without setting `draggedTabId`, and a
            // stale id there would move that workspace on the next drop
            // anywhere.
            SidebarActiveDrag.shared.end(reason: reason)
            guard draggedTabId != nil else { return }
#if DEBUG
            dlog("sidebar.dragClear tab=\(debugShortSidebarTabId(draggedTabId)) reason=\(reason)")
#endif
            draggedTabId = nil
        }
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

// MARK: - Restore Fleet Layer 3 — crash-recovery banner

/// One row per crash-recoverable team snapshot (`TeamOrchestrator.
/// restorableFleets`, populated by `detectRestorableFleets()` at launch in
/// `ask` mode). Restore routes through `.restoreFleetRequested` so the
/// handler with an active `TabManager` (TermMeshApp) performs the adopt;
/// the X button hides the row for this app run.
struct SidebarFleetRestoreBanner: View {
    @ObservedObject private var orchestrator = TeamOrchestrator.shared

    var body: some View {
        ForEach(orchestrator.restorableFleets) { fleet in
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fleet.teamName)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle(for: fleet))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Restore") {
                    NotificationCenter.default.post(
                        name: .restoreFleetRequested,
                        object: nil,
                        userInfo: ["team_uuid": fleet.teamUuid]
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.accentColor)
                .help("Restore this team's workspace, agents, and task board")
                Button {
                    orchestrator.dismissRestorableFleet(teamUuid: fleet.teamUuid)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss (snapshot stays on disk)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private func subtitle(for fleet: TeamOrchestrator.RestorableFleet) -> String {
        var parts = ["\(fleet.agentCount) agent\(fleet.agentCount == 1 ? "" : "s")"]
        if let at = fleet.lastSnapshotAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append(formatter.localizedString(for: at, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Phase 2.5 — Resumable team counter (sidebar footer)

/// Footer row showing the number of resumable headless teams plus the
/// configured auto-park threshold. Hidden entirely when no resumable teams
/// exist. Click the count → opens the New Agent Team sheet in Resume mode;
/// click the info glyph → jumps to Settings > Agent Teams (where the
/// Headless idle-park threshold lives).
struct SidebarResumableFooter: View {
    @State private var resumableCount: Int = 0
    @AppStorage("headlessIdleParkMinutes") private var headlessIdleParkMinutes: Int = 60

    var body: some View {
        Group {
            if resumableCount > 0 {
                HStack(spacing: 6) {
                    Button {
                        NotificationCenter.default.post(
                            name: .openCreateTeamSheetInResumeMode,
                            object: nil
                        )
                    } label: {
                        Text("\(resumableCount) resumable team\(resumableCount == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Open New Agent Team in Resume mode")

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text(autoParkLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Button {
                        NotificationCenter.default.post(
                            name: .settingsNavigateToSection,
                            object: nil,
                            userInfo: [SettingsNavigationUserInfoKey.section: SettingsSection.agentTeams.rawValue]
                        )
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open Settings > Agent Teams")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .headlessTeamDestroyed)) { _ in
            refresh()
        }
    }

    private var autoParkLabel: String {
        if headlessIdleParkMinutes <= 0 { return "Auto-park off" }
        return "Auto-park \(headlessIdleParkMinutes)min"
    }

    private func refresh() {
        TeamOrchestrator.shared.countResumableTeams { count in
            self.resumableCount = count
        }
    }
}

// MARK: - Worktree Sandbox Toggle

struct SidebarWorktreeSandboxToggle: View {
    @ObservedObject private var daemon = TermMeshDaemon.shared

    var body: some View {
        Button(action: {
            daemon.worktreeEnabled.toggle()
        }) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text("Sandbox")
                    .font(.system(size: 11))
            }
            .foregroundColor(daemon.worktreeEnabled ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help(daemon.worktreeEnabled ? "Worktree Sandbox: ON" : "Worktree Sandbox: OFF")
    }
}

// MARK: - Sidebar Visual Effect Background

struct SidebarVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let opacity: Double
    let tintColor: NSColor?
    let cornerRadius: CGFloat
    let preferLiquidGlass: Bool

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        opacity: Double = 1.0,
        tintColor: NSColor? = nil,
        cornerRadius: CGFloat = 0,
        preferLiquidGlass: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.opacity = opacity
        self.tintColor = tintColor
        self.cornerRadius = cornerRadius
        self.preferLiquidGlass = preferLiquidGlass
    }

    static var liquidGlassAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    func makeNSView(context: Context) -> NSView {
        // Try NSGlassEffectView if preferred or if we want to test availability
        if preferLiquidGlass, let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            glass.autoresizingMask = [.width, .height]
            glass.wantsLayer = true
            return glass
        }

        // Use NSVisualEffectView
        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Configure based on view type
        if nsView.className == "NSGlassEffectView" {
            // NSGlassEffectView configuration via private API
            nsView.alphaValue = max(0.0, min(1.0, opacity))
            nsView.layer?.cornerRadius = cornerRadius
            nsView.layer?.masksToBounds = cornerRadius > 0

            // Try to set tint color via private selector
            if let color = tintColor {
                let selector = NSSelectorFromString("setTintColor:")
                if nsView.responds(to: selector) {
                    nsView.perform(selector, with: color)
                }
            }
        } else if let visualEffect = nsView as? NSVisualEffectView {
            // NSVisualEffectView configuration
            visualEffect.material = material
            visualEffect.blendingMode = blendingMode
            visualEffect.state = state
            visualEffect.alphaValue = max(0.0, min(1.0, opacity))
            visualEffect.layer?.cornerRadius = cornerRadius
            visualEffect.layer?.masksToBounds = cornerRadius > 0
            visualEffect.needsDisplay = true
        }
    }
}

// MARK: - Sidebar Backdrop

struct SidebarBackdrop: View {
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = 0.75
    @AppStorage("sidebarTintHex") private var sidebarTintHex = "#FFFFFF"
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    /// Authoritative dark/light source: the user's explicit appearance
    /// preference. SwiftUI's `\.colorScheme` is derived from the window's
    /// `effectiveAppearance`, which lags behind on the first frame after
    /// a brew upgrade relaunch — the sidebar would render with the white
    /// `sidebarTintHex` while the rest of the app is already dark. Reading
    /// the saved preference directly closes that gap.
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let materialOption = SidebarMaterialOption(rawValue: sidebarMaterial)
        let blendingMode = SidebarBlendModeOption(rawValue: sidebarBlendMode)?.mode ?? .behindWindow
        let state = SidebarStateOption(rawValue: sidebarState)?.state ?? .active
        // Resolve dark/light: explicit user preference wins; only fall
        // through to the SwiftUI environment when the user picked
        // `.system` (or the legacy `.auto`).
        let isDark: Bool = {
            switch AppearanceMode(rawValue: appearanceMode) ?? .system {
            case .dark: return true
            case .light: return false
            case .system, .auto: return colorScheme == .dark
            }
        }()
        // In dark mode, use a deep dark tint instead of the user-configured (typically white) tint
        let effectiveTintColor: NSColor = {
            if isDark {
                return (NSColor(hex: "#0a0e14") ?? .black).withAlphaComponent(0.85)
            }
            return (NSColor(hex: sidebarTintHex) ?? .black).withAlphaComponent(sidebarTintOpacity)
        }()
        let tintColor = effectiveTintColor
        let cornerRadius = CGFloat(max(0, sidebarCornerRadius))
        let useLiquidGlass = materialOption?.usesLiquidGlass ?? false
        let useWindowLevelGlass = useLiquidGlass && blendingMode == .behindWindow

        return ZStack {
            if let material = materialOption?.material {
                // When using liquidGlass + behindWindow, window handles glass + tint
                // Sidebar is fully transparent
                if !useWindowLevelGlass {
                    SidebarVisualEffectBackground(
                        material: material,
                        blendingMode: blendingMode,
                        state: state,
                        opacity: sidebarBlurOpacity,
                        tintColor: tintColor,
                        cornerRadius: cornerRadius,
                        preferLiquidGlass: useLiquidGlass
                    )
                    // Tint overlay for NSVisualEffectView fallback
                    if !useLiquidGlass {
                        Color(nsColor: tintColor)
                    }
                }
            }
            // When material is none or useWindowLevelGlass, render nothing
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Sidebar Material Options

enum SidebarMaterialOption: String, CaseIterable, Identifiable {
    case none
    case liquidGlass  // macOS 26+ NSGlassEffectView
    case sidebar
    case hudWindow
    case menu
    case popover
    case underWindowBackground
    case windowBackground
    case contentBackground
    case fullScreenUI
    case sheet
    case headerView
    case toolTip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .liquidGlass: return "Liquid Glass (macOS 26+)"
        case .sidebar: return "Sidebar"
        case .hudWindow: return "HUD Window"
        case .menu: return "Menu"
        case .popover: return "Popover"
        case .underWindowBackground: return "Under Window"
        case .windowBackground: return "Window Background"
        case .contentBackground: return "Content Background"
        case .fullScreenUI: return "Full Screen UI"
        case .sheet: return "Sheet"
        case .headerView: return "Header View"
        case .toolTip: return "Tool Tip"
        }
    }

    /// Returns true if this option should use NSGlassEffectView (macOS 26+)
    var usesLiquidGlass: Bool {
        self == .liquidGlass
    }

    var material: NSVisualEffectView.Material? {
        switch self {
        case .none: return nil
        case .liquidGlass: return .underWindowBackground  // Fallback material
        case .sidebar: return .sidebar
        case .hudWindow: return .hudWindow
        case .menu: return .menu
        case .popover: return .popover
        case .underWindowBackground: return .underWindowBackground
        case .windowBackground: return .windowBackground
        case .contentBackground: return .contentBackground
        case .fullScreenUI: return .fullScreenUI
        case .sheet: return .sheet
        case .headerView: return .headerView
        case .toolTip: return .toolTip
        }
    }
}

enum SidebarBlendModeOption: String, CaseIterable, Identifiable {
    case behindWindow
    case withinWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .behindWindow: return "Behind Window"
        case .withinWindow: return "Within Window"
        }
    }

    var mode: NSVisualEffectView.BlendingMode {
        switch self {
        case .behindWindow: return .behindWindow
        case .withinWindow: return .withinWindow
        }
    }
}

enum SidebarStateOption: String, CaseIterable, Identifiable {
    case active
    case inactive
    case followWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .followWindow: return "Follow Window"
        }
    }

    var state: NSVisualEffectView.State {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .followWindow: return .followsWindowActiveState
        }
    }
}

enum SidebarPresetOption: String, CaseIterable, Identifiable {
    case nativeSidebar
    case glassBehind
    case softBlur
    case popoverGlass
    case hudGlass
    case underWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeSidebar: return "Native Sidebar"
        case .glassBehind: return "Raycast Gray"
        case .softBlur: return "Soft Blur"
        case .popoverGlass: return "Popover Glass"
        case .hudGlass: return "HUD Glass"
        case .underWindow: return "Under Window"
        }
    }

    var material: SidebarMaterialOption {
        switch self {
        case .nativeSidebar: return .sidebar
        case .glassBehind: return .sidebar
        case .softBlur: return .sidebar
        case .popoverGlass: return .popover
        case .hudGlass: return .hudWindow
        case .underWindow: return .underWindowBackground
        }
    }

    var blendMode: SidebarBlendModeOption {
        switch self {
        case .nativeSidebar: return .withinWindow
        case .glassBehind: return .behindWindow
        case .softBlur: return .behindWindow
        case .popoverGlass: return .behindWindow
        case .hudGlass: return .withinWindow
        case .underWindow: return .withinWindow
        }
    }

    var state: SidebarStateOption {
        switch self {
        case .nativeSidebar: return .followWindow
        case .glassBehind: return .active
        case .softBlur: return .active
        case .popoverGlass: return .active
        case .hudGlass: return .active
        case .underWindow: return .followWindow
        }
    }

    var tintHex: String {
        switch self {
        case .nativeSidebar: return "#FFFFFF"
        case .glassBehind: return "#000000"
        case .softBlur: return "#000000"
        case .popoverGlass: return "#000000"
        case .hudGlass: return "#000000"
        case .underWindow: return "#000000"
        }
    }

    var tintOpacity: Double {
        switch self {
        case .nativeSidebar: return 0.75
        case .glassBehind: return 0.36
        case .softBlur: return 0.28
        case .popoverGlass: return 0.10
        case .hudGlass: return 0.62
        case .underWindow: return 0.14
        }
    }

    var cornerRadius: Double {
        switch self {
        case .nativeSidebar: return 0.0
        case .glassBehind: return 0.0
        case .softBlur: return 0.0
        case .popoverGlass: return 10.0
        case .hudGlass: return 10.0
        case .underWindow: return 6.0
        }
    }

    var blurOpacity: Double {
        switch self {
        case .nativeSidebar: return 1.0
        case .glassBehind: return 0.6
        case .softBlur: return 0.45
        case .popoverGlass: return 0.9
        case .hudGlass: return 0.98
        case .underWindow: return 0.9
        }
    }
}

extension NSColor {
    func hexString() -> String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            min(255, max(0, Int(red * 255))),
            min(255, max(0, Int(green * 255))),
            min(255, max(0, Int(blue * 255)))
        )
    }
}

// MARK: - Sidebar layout persistence

/// Persisted sidebar layout state: width, section collapse, and per-host
/// group collapse. Imperative UserDefaults helpers are used where a view
/// needs the value at init time (width, per-key host folding); the two
/// section flags are consumed directly via @AppStorage on the same keys.
enum SidebarLayoutSettings {
    static let widthKey = "sidebar.width"
    static let localTabsCollapsedKey = "sidebar.section.localTabs.collapsed"
    static let remoteHostsCollapsedKey = "sidebar.section.remoteHosts.collapsed"
    static let collapsedHostKeysKey = "sidebar.remoteHost.collapsedKeys"

    /// Last user-committed sidebar width (saved on drag end only, so
    /// transient window-resize clamps never overwrite user intent).
    /// nil when the user has never resized the sidebar.
    static func loadWidth() -> CGFloat? {
        let raw = UserDefaults.standard.double(forKey: widthKey)
        return raw > 0 ? CGFloat(raw) : nil
    }

    static func saveWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: widthKey)
    }

    /// Collapsed host groups, stored as an array of stable host keys.
    /// Default (expanded) needs no entry, so the list only holds hosts
    /// the user explicitly folded — no per-launch key accumulation.
    private static func collapsedHostKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedHostKeysKey) ?? [])
    }

    static func isHostCollapsed(_ hostKey: String) -> Bool {
        collapsedHostKeys().contains(hostKey)
    }

    static func setHostCollapsed(_ hostKey: String, _ collapsed: Bool) {
        var keys = collapsedHostKeys()
        if collapsed { keys.insert(hostKey) } else { keys.remove(hostKey) }
        UserDefaults.standard.set(Array(keys).sorted(), forKey: collapsedHostKeysKey)
    }
}

/// Collapsible sidebar section header: chevron + caption title. The whole
/// row toggles `isCollapsed`; persistence is the caller's @AppStorage.
struct SidebarSectionHeader: View {
    let title: String
    @Binding var isCollapsed: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundColor(Color.secondary.opacity(0.7))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Remote Hosts Sidebar

struct PeerPaneExpansionCommand: Equatable {
    let isExpanded: Bool
    let generation: Int
}

private enum PeerSidebarPaletteRole {
    case hostExpanded
    case hostCollapsed
    case hostBusy
    case workspaceConnected
    case workspaceWorking

    func components(for colorScheme: ColorScheme) -> (saturation: CGFloat, brightness: CGFloat) {
        let isDark = colorScheme == .dark
        switch self {
        case .hostExpanded: return isDark ? (0.48, 0.27) : (0.22, 0.97)
        case .hostCollapsed: return isDark ? (0.58, 0.35) : (0.34, 0.94)
        case .hostBusy: return isDark ? (0.68, 0.48) : (0.50, 0.90)
        case .workspaceConnected: return isDark ? (0.65, 0.42) : (0.42, 0.95)
        case .workspaceWorking: return isDark ? (0.72, 0.58) : (0.70, 0.87)
        }
    }
}

private enum PeerSidebarPalette {
    static func colors(
        from sourceColors: [NSColor],
        role: PeerSidebarPaletteRole,
        colorScheme: ColorScheme
    ) -> [Color] {
        let components = role.components(for: colorScheme)
        return sourceColors.map { sourceColor in
            let rgb = sourceColor.usingColorSpace(.deviceRGB) ?? sourceColor
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            rgb.getHue(
                &hue,
                saturation: &saturation,
                brightness: &brightness,
                alpha: &alpha
            )
            return Color(nsColor: NSColor(
                hue: hue,
                saturation: components.saturation,
                brightness: components.brightness,
                alpha: 1
            ))
        }
    }
}

/// The sidebar's top-level switch. It sits above every section on purpose:
/// as a control tucked inside the Peer Hosts header it looked like it governed
/// the sidebar but only regrouped one section of it.
struct SidebarAxisPicker: View, Equatable {
    let selection: String
    let onSelectionChange: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection
    }

    var body: some View {
        Picker(
            "",
            selection: Binding(
                get: { selection },
                set: onSelectionChange
            )
        ) {
            ForEach(SidebarAxis.allCases) { axis in
                Text(axis.title)
                    .accessibilityLabel(axis.accessibilityDescription)
                    .tag(axis.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .padding(.horizontal, 12)
        .accessibilityIdentifier("sidebar.axis")
        .accessibilityLabel("Sidebar grouping")
        .help("Group the sidebar by host or by project")
    }
}

/// The Project axis: every workspace this app can see, local and peer, grouped
/// by the project it works inside.
struct SidebarProjectsSection: View {
    @ObservedObject var store: RemoteHostStore
    let usesSeparatedPresentation: Bool
    @AppStorage(SidebarLayoutSettings.localTabsCollapsedKey)
    private var isCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .foregroundColor(Color.secondary.opacity(0.7))
                        Text("Projects")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Projects")

                // Under the Host axis this same corner adds a peer host. Here
                // it has to add a project, which is what the button's position
                // promises — a project is not a thing to register, though, it
                // is where work happens, so opening a folder is how one starts
                // existing.
                Button {
                    // A project's own questions, and the same agent composer
                    // the team sheet uses for the rest. Pointing this at the
                    // team sheet was closer than the duplicate before it, but
                    // it still asked about pair mode and worktree isolation of
                    // someone who had not chosen a folder yet.
                    //
                    // The sheet itself belongs to the app, not to this header:
                    // the titlebar's + opens the same one, and it is visible
                    // exactly when the sidebar — and so this button — is not.
                    NotificationCenter.default.post(
                        name: .projectCreationRequested,
                        object: nil
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.projects.add")
                .accessibilityLabel("New Project")
                .help(
                    KeyboardShortcutSettings.Action.newProject.tooltip(
                        "Start a project and the team that works on it"
                    )
                )
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 4)

            if !isCollapsed {
                SidebarPeerProjectsView(
                    hosts: store.sortedHosts,
                    store: store,
                    usesSeparatedPresentation: usesSeparatedPresentation,
                    paneExpansionCommand: PeerPaneExpansionCommand(isExpanded: false, generation: 0)
                )
            }
        }
        .padding(.bottom, 4)
    }
}


struct SidebarRemoteHostsSection: View, Equatable {
    @ObservedObject var store: RemoteHostStore
    @ObservedObject private var hostStats = PeerHostStatsStore.shared
    let usesSeparatedPresentation: Bool
    @AppStorage(SidebarLayoutSettings.remoteHostsCollapsedKey)
    private var isCollapsed = false
    /// Non-nil presents the add/edit sheet.
    @State private var editorContext: PeerHostEditorContext?
    @State private var areAllPaneDetailsExpanded = false
    @State private var paneExpansionCommand = PeerPaneExpansionCommand(
        isExpanded: false,
        generation: 0
    )

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store
            && lhs.usesSeparatedPresentation == rhs.usesSeparatedPresentation
    }

    private var hasPeerPaneDetails: Bool {
        store.sortedHosts.contains { host in
            host.workspaces.contains { !$0.panes.isEmpty }
        }
    }

    private func toggleAllPaneDetails() {
        areAllPaneDetailsExpanded.toggle()
        paneExpansionCommand = PeerPaneExpansionCommand(
            isExpanded: areAllPaneDetailsExpanded,
            generation: paneExpansionCommand.generation + 1
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 10)
                .padding(.top, usesSeparatedPresentation ? 10 : 4)
                .padding(.bottom, usesSeparatedPresentation ? 5 : 2)

            // "Peer Hosts", not "Remote Hosts" — plain "hosts" read as
            // direct-SSH terminal access; these entries are term-mesh
            // peer daemons (Peer menu / Peer Connections vocabulary).
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .foregroundColor(Color.secondary.opacity(0.7))
                        Text("Peer Hosts")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Peer Hosts")

                if !isCollapsed, hasPeerPaneDetails {
                    Button(action: toggleAllPaneDetails) {
                        Image(systemName: areAllPaneDetailsExpanded
                              ? "chevron.up"
                              : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(areAllPaneDetailsExpanded
                                        ? "Collapse all peer pane details"
                                        : "Expand all peer pane details")
                    .help(areAllPaneDetailsExpanded
                          ? "Collapse all peer pane details"
                          : "Expand all peer pane details")
                }

                Button {
                    editorContext = PeerHostEditorContext(
                        profile: PeerHostProfile(sshTarget: ""),
                        isNew: true
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Peer Host")
                .help("Add Peer Host…")
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 4)

            if !isCollapsed {
                if store.sortedHosts.isEmpty {
                    Text("No saved hosts — click + to add")
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondary.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                } else {
                    // Hosts only. Grouping by project is now the sidebar's own
                    // axis, chosen above this section rather than inside it.
                    VStack(spacing: usesSeparatedPresentation ? 8 : 0) {
                        ForEach(store.sortedHosts) { host in
                            RemoteHostGroupView(
                                host: host,
                                store: store,
                                usesSeparatedPresentation: usesSeparatedPresentation,
                                paneExpansionCommand: paneExpansionCommand,
                                expandSignal: store.expandSignal,
                                diskWarningText: host.isConnected
                                    ? hostStats.stats(for: host.paneHostSpec.hostKey)?.diskWarningText
                                    : nil
                            ) { context in
                                editorContext = context
                            }
                            .equatable()
                        }
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .sheet(item: $editorContext) { context in
            PeerHostEditorView(
                context: context,
                onSave: { profile in
                    PeerHostProfileStore.shared.upsert(profile)
                    editorContext = nil
                },
                onCancel: { editorContext = nil }
            )
        }
        // Menu-bar / main-menu "Add Remote Host…" routes here — the
        // sheet is sidebar-hosted, so menus just ask for it.
        .onReceive(NotificationCenter.default.publisher(
            for: PeerClientCoordinator.addRemoteHostRequestedNotification
        )) { _ in
            guard editorContext == nil else { return }
            editorContext = PeerHostEditorContext(
                profile: PeerHostProfile(sshTarget: ""),
                isNew: true
            )
        }
    }
}

struct SidebarProjectDelegateTarget: Identifiable {
    let label: String
    let rootPath: String?
    var id: String { rootPath ?? label }
}

/// Hand a project some work. The coordinator picks which machine runs it, so
/// this asks for the work and nothing about where — choosing a host here would
/// re-decide, by hand and with less information, the one thing the coordinator
/// exists to decide.
/// Which project is getting a member, and where that member should run.
struct SidebarRemoteAgentTarget: Identifiable {
    let projectLabel: String
    /// The team the member joins. Nil when the project has no team here, which
    /// is the one case this cannot serve — a member needs teammates.
    let teamName: String?
    var id: String { projectLabel }
}

private struct SidebarProjectDeletionTarget: Identifiable {
    let label: String
    let teamName: String
    let locations: [TeamOrchestrator.Team.RemoteProjectLocation]
    var id: String { teamName }
}

/// Put a member of this project's team on another machine.
///
/// The delegate sheet beside this one deliberately asks nothing about where —
/// the coordinator picks a host, and choosing one by hand would re-decide with
/// less information. This is the opposite case, and the reason both exist: the
/// machine IS the request. Tests want the Mac; a build may want the Linux box.
///
/// The directory is asked for rather than inferred. Two machines rarely lay a
/// checkout out the same way, so the local path is not an answer; what the host
/// reports about itself is, and that is what prefills the field.
struct SidebarRemoteAgentSheet: View {
    let target: SidebarRemoteAgentTarget
    let onClose: () -> Void

    @ObservedObject private var store = RemoteHostStore.shared
    @State private var hostKey: String = ""
    @State private var directory: String = ""
    @State private var role: String = "executor"
    @State private var failure: String?
    @State private var isAdding = false

    private var connectedHosts: [HostEntry] {
        RemoteHostStore.selectableLaunchHosts(in: store.sortedHosts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add Agent on Another Machine")
                    .font(.system(size: 14, weight: .semibold))
                Text(target.projectLabel)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if connectedHosts.isEmpty {
                Text("No peer is connected. Connect one from the Host list first.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Machine")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $hostKey) {
                        ForEach(connectedHosts, id: \.id) { host in
                            Text(host.displayName).tag(host.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: hostKey) { _, _ in prefillDirectory() }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Working directory on that machine")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("/root/project", text: $directory)
                        .textFieldStyle(.roundedBorder)
                    // The same convention creation uses: an agent never
                    // shares the project's checkout with the leader.
                    Text("A folder this project owns gets the agent its own dated worktree beside it; any other path is used as typed.")
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Role")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("executor", text: $role)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("The pane opens here, beside its team.")
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(0.8))
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(isAdding ? "Adding…" : "Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAdding || !isReady)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            if hostKey.isEmpty { hostKey = connectedHosts.first?.id ?? "" }
            prefillDirectory()
        }
        .accessibilityIdentifier("sidebar.project.addRemoteAgent")
    }

    private var isReady: Bool {
        target.teamName != nil
            && !hostKey.isEmpty
            && !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Offer what the machine says about itself, preferring a folder named the
    /// same as this project. A wrong guess here is cheap — the field is right
    /// there — but a blank one makes the person go and look it up.
    private func prefillDirectory() {
        guard let host = connectedHosts.first(where: { $0.id == hostKey }) else { return }
        var roots = host.workspaces
            .flatMap(\.panes)
            .compactMap(\.projectRootPath)
            .filter { !$0.isEmpty }
        roots.append(contentsOf: host.teams.compactMap(\.projectRootPath).filter { !$0.isEmpty })
        let byName = roots.first {
            URL(fileURLWithPath: $0).lastPathComponent == target.projectLabel
        }
        directory = byName ?? roots.first ?? ""
    }

    private func add() {
        guard let teamName = target.teamName else {
            failure = "This project has no team here to join."
            return
        }
        isAdding = true
        failure = nil
        let name = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = hostKey
        Task { @MainActor in
            do {
                _ = try await TeamOrchestrator.shared.attachRemoteAgent(
                    teamName: teamName,
                    agentName: name,
                    hostKey: key,
                    workingDirectory: dir,
                    agentType: name
                )
                onClose()
            } catch {
                isAdding = false
                failure = String(describing: error)
            }
        }
    }
}

struct SidebarProjectDelegateSheet: View {
    let target: SidebarProjectDelegateTarget
    let onClose: () -> Void

    @State private var title = ""
    @State private var body_ = ""
    @State private var failure: String?
    @State private var isSending = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Delegate Work")
                    .font(.system(size: 14, weight: .semibold))
                Text(target.label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("What needs doing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                TextField("Add a retry to the peer reconnect", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Detail (optional)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                TextEditor(text: $body_)
                    .font(.system(size: 12))
                    .frame(height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("A host is chosen for you.")
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(0.8))
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(isSending ? "Sending…" : "Delegate", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { titleFocused = true }
        .accessibilityIdentifier("sidebar.project.delegate")
    }

    private func send() {
        guard let rootPath = target.rootPath else {
            failure = "This project has no folder on this machine to delegate into."
            return
        }
        isSending = true
        failure = nil
        Task {
            do {
                let coordinator = ReviewBoardCoordinatorService.shared
                try await coordinator.delegate(
                    projectRoot: rootPath,
                    projectName: target.label,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: body_
                )
                await MainActor.run { onClose() }
            } catch {
                await MainActor.run {
                    isSending = false
                    // Placement fails for a reason worth reading — no host has
                    // the project checked out, every host is full — so the
                    // coordinator's own words go straight through.
                    failure = error.localizedDescription
                }
            }
        }
    }
}

private struct SidebarPeerProjectGroup: Identifiable {
    /// A project is a place work happens, not a place work is hosted, so the
    /// same group holds workspaces from either side of the wire.
    enum WorkspaceItem: Identifiable {
        case local(Workspace)
        case peer(host: HostEntry, workspace: WorkspaceSummary)

        var id: String {
            switch self {
            case .local(let workspace):
                return "local:\(workspace.id.uuidString)"
            case .peer(let host, let workspace):
                return "\(host.id):\(workspace.id.base64EncodedString())"
            }
        }

        var isLocal: Bool {
            if case .local = self { return true }
            return false
        }
    }

    let identity: PeerProjectIdentity
    var items: [WorkspaceItem]

    var id: String { identity.id }

    /// Which sides of the wire this project spans — drives the header badges.
    var spansLocal: Bool { items.contains { $0.isLocal } }
    var spansPeer: Bool { items.contains { !$0.isLocal } }
}

/// Project-axis rendering of the peer section. Deliberately shows NOTHING but
/// projects: a host that contributes no workspace has no place on this axis,
/// and listing it here just reproduced the Host view one toggle away. Host
/// lifecycle (connect, retry, edit, delete) lives in the Host view alone.
private struct SidebarPeerProjectsView: View {
    @EnvironmentObject private var tabManager: TabManager
    @ObservedObject private var coordinator = ReviewBoardCoordinatorService.shared
    @ObservedObject private var orchestrator = TeamOrchestrator.shared
    let hosts: [HostEntry]
    let store: RemoteHostStore
    let usesSeparatedPresentation: Bool
    let paneExpansionCommand: PeerPaneExpansionCommand
    /// The same key the switch above writes, so the unassigned footer can send
    /// the user to the view that actually lists those workspaces.
    @AppStorage(SidebarAxisSettings.selectedAxisKey)
    private var selectedAxisRaw = SidebarAxisSettings.defaultAxis.rawValue
    /// Non-nil presents the delegate sheet.
    @State private var delegateTarget: SidebarProjectDelegateTarget?
    /// Non-nil presents the remote-agent sheet.
    @State private var remoteAgentTarget: SidebarRemoteAgentTarget?
    @State private var deletionTarget: SidebarProjectDeletionTarget?
    @State private var deletionFailure: String?
    @State private var presentationRestoreFailure: String?
    @State private var restoringTeamNames: Set<String> = []

    private var connectedHosts: [HostEntry] {
        hosts.filter { $0.isConnected && !$0.workspaces.isEmpty }
    }

    /// Every local workspace, paired with the project it belongs to — or an
    /// unknown identity when it belongs to none. A peer mirror is excluded on
    /// purpose: it is a view onto someone else's workspace, already
    /// represented by that peer's own row, and counting it here would list one
    /// remote workspace twice. Matches the rule the Local Workspaces section
    /// applies (`SidebarPresentationSettings`).
    ///
    /// A local workspace naming no project is counted rather than listed: the
    /// Host view already shows it under Workspaces, so a second copy here was
    /// duplication. What it contributes is the footer's count — the one thing
    /// the Host view cannot say from over there.
    private var localMembers: [(Workspace, PeerProjectIdentity)] {
        tabManager.tabs.compactMap { workspace in
            guard !workspace.isPeerMirror else { return nil }
            // A project that named itself is not up for reinterpretation. Only
            // workspaces nobody declared fall through to the path rule.
            let declared = WorkspaceProjectNames.shared.identity(for: workspace.id)
            return (
                workspace,
                declared
                    ?? projectIdentity(forWorkingDirectories: localWorkingDirectories(workspace))
            )
        }
    }

    private func localWorkingDirectories(_ workspace: Workspace) -> [String] {
        let panelPaths = workspace.panelDirectories.values.filter { !$0.isEmpty }
        if !panelPaths.isEmpty { return Array(panelPaths) }
        return workspace.currentDirectory.isEmpty ? [] : [workspace.currentDirectory]
    }

    /// Split the connected roster into named projects and the leftovers.
    /// A workspace whose panes do not name a project (a shell sitting in the
    /// home directory, panes spread across unrelated trees) is NOT given a
    /// group header — calling it a project would be a lie — and it is not
    /// listed either: the Host view is where those live. Only the count
    /// survives, so the axis admits what it is leaving out.
    private var groupedWorkspaces: (
        projects: [SidebarPeerProjectGroup],
        unassigned: [SidebarPeerProjectGroup.WorkspaceItem]
    ) {
        var indexes: [PeerProjectIdentity: Int] = [:]
        var groups: [SidebarPeerProjectGroup] = []
        var unassigned: [SidebarPeerProjectGroup.WorkspaceItem] = []

        func append(_ item: SidebarPeerProjectGroup.WorkspaceItem, to identity: PeerProjectIdentity) {
            if let index = indexes[identity] {
                groups[index].items.append(item)
            } else {
                indexes[identity] = groups.count
                groups.append(SidebarPeerProjectGroup(identity: identity, items: [item]))
            }
        }

        // Local first so a project the user is working on locally leads its
        // own group instead of trailing the peers that joined it.
        for (workspace, identity) in localMembers {
            let item = SidebarPeerProjectGroup.WorkspaceItem.local(workspace)
            guard !identity.isUnknown else {
                unassigned.append(item)
                continue
            }
            append(item, to: identity)
        }
        for host in connectedHosts {
            for workspace in host.workspaces {
                let identity = peerProjectIdentity(for: workspace.panes)
                let item = SidebarPeerProjectGroup.WorkspaceItem.peer(
                    host: host,
                    workspace: workspace
                )
                guard !identity.isUnknown else {
                    unassigned.append(item)
                    continue
                }
                append(item, to: identity)
            }
        }
        let sorted = groups.sorted {
            $0.identity.label.localizedCaseInsensitiveCompare($1.identity.label) == .orderedAscending
        }
        return (sorted, unassigned)
    }

    /// Live projects outlive any individual NSWindow. When their former
    /// workspace has no registered window, keep them visible so a new window
    /// can attach fresh viewers to the same peer-owned surfaces.
    private var detachedTeams: [TeamOrchestrator.Team] {
        return orchestrator.teams.values
            .filter { team in
                AppDelegate.shared?.contextContainingTabId(team.workspaceId) == nil
            }
            .sorted {
                $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
            }
    }

    private func detachedProjectRow(
        _ team: TeamOrchestrator.Team,
        showsHeader: Bool = true
    ) -> some View {
        VStack(spacing: 4) {
            if showsHeader {
                HStack(spacing: 5) {
                    Text(team.id)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.primary.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 8))
                        .foregroundColor(Color.orange.opacity(0.8))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.top, 7)
                .padding(.bottom, 2)
            }

            Button {
                guard !restoringTeamNames.contains(team.id) else { return }
                restoringTeamNames.insert(team.id)
                Task { @MainActor in
                    let restored = await orchestrator.restoreDetachedProjectPresentation(
                        teamName: team.id,
                        tabManager: tabManager
                    )
                    restoringTeamNames.remove(team.id)
                    if !restored {
                        presentationRestoreFailure =
                            "The live project could not be attached to this window."
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if restoringTeamNames.contains(team.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.left.and.arrow.up.right")
                            .font(.system(size: 9))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open live project")
                            .font(.system(size: 11))
                        Text("\(team.agents.count) agents · processes still running")
                            .font(.system(size: 9))
                    }
                    Spacer(minLength: 4)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(restoringTeamNames.contains(team.id))
            .padding(.horizontal, usesSeparatedPresentation ? 10 : 8)
            .accessibilityIdentifier("sidebar.projects.detached.\(team.id)")
            .help("Attach this project's existing leader and agents to the current window")
        }
    }

    @ViewBuilder
    private func workspaceRow(
        _ item: SidebarPeerProjectGroup.WorkspaceItem
    ) -> some View {
        switch item {
        case .local(let workspace):
            SidebarProjectLocalRowView(
                workspace: workspace,
                usesSeparatedPresentation: usesSeparatedPresentation
            )
        case .peer(let host, let workspace):
            RemoteWorkspaceRowView(
                workspace: workspace,
                host: host,
                store: store,
                usesSeparatedPresentation: usesSeparatedPresentation,
                paneExpansionCommand: paneExpansionCommand
            )
        }
    }

    /// `⌂` / `▣` badges telling, at a glance, whether a project lives here,
    /// out there, or both — the question the Host axis used to answer by
    /// nesting workspaces under a host.
    @ViewBuilder
    private func spanBadges(_ group: SidebarPeerProjectGroup) -> some View {
        HStack(spacing: 3) {
            if group.spansLocal {
                Image(systemName: "house")
                    .accessibilityLabel("Has local workspaces")
            }
            if group.spansPeer {
                Image(systemName: "rectangle.inset.filled")
                    .accessibilityLabel("Has peer workspaces")
            }
            // A leader on a peer machine can only be known through the
            // coordinator; the local row's own star covers the local case.
            if !group.spansLocal, coordinatorLeaderIdentities.contains(group.identity) {
                Image(systemName: "star.fill")
                    .foregroundColor(.orange)
                    .accessibilityLabel("Team leader runs on a peer host")
            }
        }
        .font(.system(size: 8))
        .foregroundColor(Color.secondary.opacity(0.6))
    }

    private var coordinatorLeaderIdentities: Set<PeerProjectIdentity> {
        coordinator.leaderProjectIdentities
    }

    /// The absolute path the coordinator will register this project under.
    /// A project the sidebar groups purely from peer panes has no path this
    /// machine can name, so delegation is offered only where one exists.
    /// What can be done to a project, wherever it is right-clicked.
    @ViewBuilder
    private func projectActions(for group: SidebarPeerProjectGroup) -> some View {
        Button("Delegate Work to \(group.identity.label)…") {
            delegateTarget = SidebarProjectDelegateTarget(
                label: group.identity.label,
                rootPath: delegateRootPath(for: group)
            )
        }
        .disabled(delegateRootPath(for: group) == nil)
        // Under the delegate item because it answers the other half of the
        // same question: that one asks what needs doing and lets the
        // coordinator pick a machine, this one is for when the machine is
        // the point.
        Button("Add Agent on Another Machine…") {
            remoteAgentTarget = SidebarRemoteAgentTarget(
                projectLabel: group.identity.label,
                teamName: teamName(for: group)
            )
        }
        .disabled(teamName(for: group) == nil)
        Divider()
        Button("Delete Project…", role: .destructive) {
            guard let teamName = teamName(for: group),
                  let team = TeamOrchestrator.shared.teams[teamName]
            else { return }
            deletionTarget = SidebarProjectDeletionTarget(
                label: group.identity.label,
                teamName: teamName,
                locations: team.remoteProjectLocations
            )
        }
        .disabled(teamName(for: group) == nil)
    }


    /// The team running in this project on this machine, if there is one.
    /// A remote member joins an existing team — there is no such thing as a
    /// team with only a member somewhere else.
    private func teamName(for group: SidebarPeerProjectGroup) -> String? {
        let workspaceIDs = Set(group.items.compactMap { item -> UUID? in
            guard case .local(let workspace) = item else { return nil }
            return workspace.id
        })
        guard !workspaceIDs.isEmpty else { return nil }
        return TeamOrchestrator.shared.teams.values
            .first { workspaceIDs.contains($0.workspaceId) }?
            .id
    }

    private func delegateRootPath(for group: SidebarPeerProjectGroup) -> String? {
        for item in group.items {
            guard case .local(let workspace) = item else { continue }
            let directories = localWorkingDirectories(workspace)
            if let root = directories.first(where: { !$0.isEmpty }) {
                return root
            }
        }
        return nil
    }

    var body: some View {
        let grouped = groupedWorkspaces
        let detached = detachedTeams
        let groupedLabels = Set(grouped.projects.map { $0.identity.label })
        return VStack(spacing: usesSeparatedPresentation ? 8 : 0) {
            if grouped.projects.isEmpty && detached.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No projects yet")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    // The empty state is the only place this view mentions
                    // hosts at all — without it a peerless Project view would
                    // be a dead end with no route to connecting one. Once
                    // there ARE workspaces the footer below already accounts
                    // for them, so this line only has to say what to do next.
                    Text(grouped.unassigned.isEmpty
                         ? "Click + to start a project, or connect a peer in the Host view."
                         : "Click + to start one.")
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }

            ForEach(grouped.projects) { group in
                VStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Text(group.identity.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.primary.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel("Project \(group.identity.label)")
                        spanBadges(group)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                    .padding(.top, 7)
                    .padding(.bottom, 2)
                    // Delegating from the project's own row means the target
                    // is already chosen — nothing to pick again, nothing to
                    // pick wrongly.
                    .contentShape(Rectangle())
                    .contextMenu { projectActions(for: group) }
                    ForEach(group.items) { item in
                        // The same two actions on the rows themselves. They
                        // were on the group's header alone, which is a thin
                        // grey label that does not read as a row — so the
                        // menu was on the one thing nobody right-clicks,
                        // while the workspace beneath it, which is what
                        // people actually aim at, had nothing to say about
                        // its own project.
                        workspaceRow(item)
                            .contextMenu { projectActions(for: group) }
                    }
                    if let detachedTeam = detached.first(where: {
                        $0.id == group.identity.label
                    }) {
                        detachedProjectRow(detachedTeam, showsHeader: false)
                    }
                }
            }

            ForEach(detached.filter { !groupedLabels.contains($0.id) }) { team in
                detachedProjectRow(team)
            }

            let remembered = ReviewBoardCoordinatorService.rememberedProjects(
                knownHosts: coordinator.knownHosts,
                sidebarHosts: hosts,
                liveIdentities: Set(grouped.projects.map(\.identity))
            )
            ForEach(remembered, id: \.identity) { project in
                rememberedProjectRow(project)
            }

            if !grouped.unassigned.isEmpty {
                unassignedFooter(grouped.unassigned)
            }
        }
        .sheet(item: $delegateTarget) { target in
            SidebarProjectDelegateSheet(target: target) { delegateTarget = nil }
        }
        .sheet(item: $remoteAgentTarget) { target in
            SidebarRemoteAgentSheet(target: target) { remoteAgentTarget = nil }
        }
        .alert(
            "Delete “\(deletionTarget?.label ?? "Project")”?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            presenting: deletionTarget
        ) { target in
            Button("Delete Project", role: .destructive) {
                deletionTarget = nil
                Task { @MainActor in
                    do {
                        try await TeamOrchestrator.shared.deleteProject(
                            teamName: target.teamName,
                            tabManager: tabManager
                        )
                    } catch {
                        deletionFailure = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: { target in
            if target.locations.isEmpty {
                Text("The project and its panes will close. Local folders are kept.")
            } else {
                let paths = target.locations
                    .map { "\($0.hostKey): \($0.path)" }
                    .joined(separator: "\n")
                Text("The leader and agents will stop. These remote folders will be permanently deleted:\n\n\(paths)")
            }
        }
        .alert(
            "Couldn’t Delete Project",
            isPresented: Binding(
                get: { deletionFailure != nil },
                set: { if !$0 { deletionFailure = nil } }
            )
        ) {
            Button("OK") { deletionFailure = nil }
        } message: {
            Text(deletionFailure ?? "")
        }
        .alert(
            "Couldn’t Open Project",
            isPresented: Binding(
                get: { presentationRestoreFailure != nil },
                set: { if !$0 { presentationRestoreFailure = nil } }
            )
        ) {
            Button("OK") { presentationRestoreFailure = nil }
        } message: {
            Text(presentationRestoreFailure ?? "")
        }
    }

    /// A project the coordinator remembers on a host that is currently off.
    /// Dimmed, and not expandable — there is no live workspace to expand —
    /// but clicking reconnects the machine it was last seen on, which is the
    /// only useful action here.
    private func rememberedProjectRow(
        _ project: ReviewBoardCoordinatorService.RememberedProject
    ) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Text(project.identity.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.secondary.opacity(0.68))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 8))
                    .foregroundColor(Color.secondary.opacity(0.45))
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.top, 7)
            .padding(.bottom, 2)

            Button {
                if let host = hosts.first(where: { $0.id == project.hostKey }) {
                    store.connectSavedHost(host)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.hostDisplayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text("Last seen · not connected")
                            .font(.system(size: 9))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .foregroundColor(Color.secondary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, usesSeparatedPresentation ? 10 : 8)
            .help("Reconnect \(project.hostDisplayName) to open \(project.identity.label)")
            .accessibilityLabel("\(project.identity.label) on \(project.hostDisplayName), not connected")
        }
    }

    /// What this axis is leaving out, in one line.
    ///
    /// These workspaces used to be listed here in an expandable section, which
    /// was the Host view's roster reprinted under a heading saying the opposite
    /// of what its rows are. The count still has to be said — a workspace
    /// silently missing from the sidebar reads as lost — but saying it once,
    /// next to the way to go and see them, does that job without turning the
    /// project axis back into the host one.
    private func unassignedFooter(
        _ items: [SidebarPeerProjectGroup.WorkspaceItem]
    ) -> some View {
        let count = items.count
        let noun = count == 1 ? "workspace" : "workspaces"
        return Button {
            selectedAxisRaw = SidebarAxis.host.rawValue
        } label: {
            HStack(spacing: 4) {
                Text("\(count) \(noun) without a project")
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundColor(Color.secondary.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .padding(.bottom, 1)
        .accessibilityIdentifier("sidebar.projects.unassignedLink")
        .accessibilityLabel("\(count) \(noun) without a project — show the Host view")
        .help("Listed under Workspaces and Peer Hosts in the Host view")
    }
}

/// A local workspace as it appears on the project axis. Deliberately NOT
/// `TabItemView`: that row carries the local list's drag-reorder, multi-select
/// and index bookkeeping, none of which mean anything under a project header
/// (reordering across projects would be reordering across hosts). This row
/// does the two things that do make sense here — show where it is working,
/// and select it.
private struct SidebarProjectLocalRowView: View {
    @EnvironmentObject private var tabManager: TabManager
    @ObservedObject private var orchestrator = TeamOrchestrator.shared
    let workspace: Workspace
    let usesSeparatedPresentation: Bool
    @State private var isHovering = false

    private var isSelected: Bool { tabManager.selectedTabId == workspace.id }

    /// The team whose leader pane lives in THIS workspace. In adopted mode the
    /// leader sits in its own workspace, apart from the agents, so the leader
    /// workspace takes precedence over the agent one.
    private var ledTeamName: String? {
        orchestrator.teams.values.first {
            ($0.leaderWorkspaceId ?? $0.workspaceId) == workspace.id
        }?.id
    }

    private var directoryName: String? {
        let path = workspace.currentDirectory
        guard !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        return isHovering ? Color.secondary.opacity(0.12) : Color.clear
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "house")
                .font(.system(size: 9))
                .foregroundColor(isSelected ? .primary : .secondary)
                .accessibilityLabel("Local workspace")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(workspace.title)
                        .font(.system(size: 11.5))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Where the leader sits is the first thing you need when a
                    // project spans machines. Only local teams can be answered
                    // today — a peer-hosted leader has no reporting path yet.
                    if let ledTeamName {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundColor(.orange)
                            .help("Team leader: \(ledTeamName)")
                            .accessibilityLabel("Team leader for \(ledTeamName)")
                    }
                }
                if let directoryName {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 8))
                        Text(directoryName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 9))
                    .foregroundColor(Color.secondary.opacity(0.75))
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(background)
        )
        .padding(.horizontal, usesSeparatedPresentation ? 10 : 8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            tabManager.selectedTabId = workspace.id
            if let ledTeamName {
                Task { @MainActor in
                    _ = await orchestrator.recoverRemoteLeaderIfNeeded(
                        teamName: ledTeamName
                    )
                }
            }
        }
        .help(workspace.currentDirectory)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct PeerShellCleanupSheet: View {
    let hostName: String
    var scopeName: String? = nil
    let items: [TeamOrchestrator.PeerShellCleanupItem]
    let isLoading: Bool
    let error: String?
    @Binding var selection: Set<Data>
    let onRefresh: () -> Void
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCloseConfirm = false

    private var closeableCount: Int {
        items.filter { $0.state != .inUse && !$0.isBusy }.count
    }

    /// Running and claimed panes are never bulk-close candidates. A person can
    /// stop the process first and refresh; the cleanup flow itself stays safe.
    private var closeableIDs: Set<Data> {
        Set(items.filter { $0.state != .inUse && !$0.isBusy }.map(\.id))
    }

    private var allCloseableSelected: Bool {
        !closeableIDs.isEmpty && closeableIDs.isSubset(of: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clean Up Panes")
                        .font(.headline)
                    Text([hostName, scopeName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Unlike Disconnect, this reaches across the link and ends
            // processes on the host. Say so before the list, not after —
            // the sheet title alone reads like local housekeeping.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("These shells run on \(hostName). Closing them ends the processes inside — anything unsaved there is lost.")
            }
            .font(.caption)

            Text("Orphans and panes whose folder was deleted are selected automatically. Panes in use or running a command are always protected.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // A host accumulates a shell per project run, so the list is
            // routinely dozens long and the automatic selection covers only the
            // two states it can prove are dead. Clearing the rest one checkbox
            // at a time is the whole reason this sheet felt unusable.
            HStack(spacing: 10) {
                Button(allCloseableSelected ? "Deselect All" : "Select All") {
                    if allCloseableSelected {
                        selection.subtract(closeableIDs)
                    } else {
                        selection.formUnion(closeableIDs)
                    }
                }
                .disabled(closeableIDs.isEmpty || isLoading)
                Text("\(selection.count) of \(closeableCount) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            List(items) { item in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { selection.contains(item.id) },
                        set: { selected in
                            if selected {
                                selection.insert(item.id)
                            } else {
                                selection.remove(item.id)
                            }
                        }
                    ))
                    .labelsHidden()
                    .disabled(item.state == .inUse || item.isBusy)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title.isEmpty ? "Shell" : item.title)
                                .lineLimit(1)
                            Text(item.idLabel)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Text(item.workingDirectory.isEmpty ? "Unknown folder" : item.workingDirectory)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()
                    if item.isBusy {
                        Text("busy")
                            .foregroundColor(.orange)
                    }
                    Text(stateLabel(item.state))
                        .foregroundColor(stateColor(item.state))
                }
                .font(.caption)
            }
            .frame(minHeight: 300)

            HStack {
                Text("\(items.count) panes · \(closeableCount) safe to close")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh", action: onRefresh)
                    .disabled(isLoading)
                Button("Cancel") { dismiss() }
                Button("Close \(selection.count) Panes", role: .destructive) {
                    showCloseConfirm = true
                }
                .disabled(selection.isEmpty || isLoading)
            }
        }
        .padding(18)
        .frame(minWidth: 680, minHeight: 430)
        // Select All puts every closeable shell one click from termination,
        // so the irreversible step gets its own confirmation. This is the one
        // place in the host menu that earns a prompt.
        .confirmationDialog(
            "Close \(selection.count) panes on \"\(hostName)\"?",
            isPresented: $showCloseConfirm
        ) {
            Button("Close \(selection.count) Panes", role: .destructive, action: onClose)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The processes inside end immediately. This cannot be undone.")
        }
    }

    private func stateLabel(_ state: TeamOrchestrator.PeerShellCleanupItem.State) -> String {
        switch state {
        case .inUse: return "in use"
        case .managedOrphan: return "orphan"
        case .missingDirectory: return "folder deleted"
        case .unclaimed: return "unclaimed"
        }
    }

    private func stateColor(_ state: TeamOrchestrator.PeerShellCleanupItem.State) -> Color {
        switch state {
        case .inUse: return .green
        case .managedOrphan, .missingDirectory: return .orange
        case .unclaimed: return .secondary
        }
    }
}

struct RemoteHostGroupView: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    let host: HostEntry
    let store: RemoteHostStore
    let usesSeparatedPresentation: Bool
    let paneExpansionCommand: PeerPaneExpansionCommand
    let expandSignal: RemoteHostStore.ExpandSignal
    let diskWarningText: String?
    /// Opens the shared add/edit sheet (owned by the section view).
    let onEdit: (PeerHostEditorContext) -> Void
    @State private var isExpanded: Bool
    @State private var showDeleteConfirm = false
    @State private var showNewWorkspaceAlert = false
    @State private var newWorkspaceTitle = ""
    @State private var showShellCleanup = false
    @State private var shellCleanupItems: [TeamOrchestrator.PeerShellCleanupItem] = []
    @State private var shellCleanupSelection = Set<Data>()
    @State private var shellCleanupLoading = false
    @State private var shellCleanupError: String?
    init(host: HostEntry, store: RemoteHostStore,
         usesSeparatedPresentation: Bool,
         paneExpansionCommand: PeerPaneExpansionCommand,
         expandSignal: RemoteHostStore.ExpandSignal,
         diskWarningText: String?,
         onEdit: @escaping (PeerHostEditorContext) -> Void) {
        self.host = host
        self.store = store
        self.usesSeparatedPresentation = usesSeparatedPresentation
        self.paneExpansionCommand = paneExpansionCommand
        self.expandSignal = expandSignal
        self.diskWarningText = diskWarningText
        self.onEdit = onEdit
        // Fold state persists per stable host key; default is expanded.
        _isExpanded = State(initialValue: !SidebarLayoutSettings.isHostCollapsed(host.id))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host == rhs.host
            && lhs.usesSeparatedPresentation == rhs.usesSeparatedPresentation
            && lhs.paneExpansionCommand == rhs.paneExpansionCommand
            && lhs.expandSignal == rhs.expandSignal
            && lhs.diskWarningText == rhs.diskWarningText
    }

    /// Profile-management items shared by every connection state.
    @ViewBuilder
    private var profileMenuItems: some View {
        if let profileID = host.profileID,
           let profile = PeerHostProfileStore.shared.profile(id: profileID) {
            Divider()
            Button("Edit…") {
                Task { @MainActor in
                    // Let AppKit finish its nested context-menu event loop
                    // before presenting a SwiftUI sheet. Presenting inline
                    // re-enters AttributeGraph while the menu is still
                    // tracking and can spin the main thread indefinitely.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    onEdit(PeerHostEditorContext(profile: profile, isNew: false))
                }
            }
            Button("Delete…", role: .destructive) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    showDeleteConfirm = true
                }
            }
        } else if let draft = store.profileDraft(for: host) {
            // Ad-hoc SSH connection → offer promotion to a saved host.
            Divider()
            Button("Save as Host…") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    onEdit(PeerHostEditorContext(profile: draft, isNew: true))
                }
            }
        }
    }

    private var emptyBodyText: String {
        switch host.connectionState {
        case .connecting: return "Connecting…"
        case .connected: return "Loading…"
        case .saved: return "Not connected"
        case .failed: return "Connection failed"
        }
    }

    private var peerAccentNSColors: [NSColor] {
        PeerHostAccent.colors(for: host.paneHostSpec.hostKey)
    }

    private var peerAccentPrimary: Color {
        Color(nsColor: PeerHostAccent.primaryColor(for: host.paneHostSpec.hostKey))
    }

    private var peerAccentGradient: LinearGradient {
        LinearGradient(
            colors: peerAccentNSColors.map { Color(nsColor: $0) },
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var hostBusyCount: Int {
        host.workspaces.reduce(0) { $0 + $1.busyCount }
    }

    private var isCollapsedHostBusy: Bool {
        host.isConnected && !isExpanded && hostBusyCount > 0
    }

    private var peerHeaderPaletteRole: PeerSidebarPaletteRole {
        if isCollapsedHostBusy { return .hostBusy }
        return isExpanded ? .hostExpanded : .hostCollapsed
    }

    private var peerHeaderBackground: AnyShapeStyle {
        guard host.isConnected else { return AnyShapeStyle(Color.clear) }
        return AnyShapeStyle(LinearGradient(
            colors: PeerSidebarPalette.colors(
                from: peerAccentNSColors,
                role: peerHeaderPaletteRole,
                colorScheme: colorScheme
            ),
            startPoint: .leading,
            endPoint: .trailing
        ))
    }

    private var hostAccessibilityValue: String {
        switch host.connectionState {
        case .connected:
            if isCollapsedHostBusy {
                return "Connected, collapsed, work in progress"
            }
            return isExpanded ? "Connected, expanded" : "Connected, collapsed"
        case .connecting: return "Connecting"
        case .saved: return "Not connected"
        case .failed: return "Connection failed"
        }
    }

    private var hostAccessibilityLabel: String {
        isCollapsedHostBusy ? "\(host.displayName), work in progress" : host.displayName
    }

    @ViewBuilder
    private var hostStatusIcon: some View {
        switch host.connectionState {
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 11, height: 11)
        case .connected:
            Image(systemName: host.symbolName ?? "network")
                .font(.system(size: 9))
                .foregroundColor(peerAccentPrimary)
        case .saved:
            Image(systemName: host.symbolName ?? "network.slash")
                .font(.system(size: 9))
                .foregroundColor(Color.secondary.opacity(0.4))
        case .failed(let reason):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9))
                .foregroundColor(.red)
                .help(reason)
        }
    }

    /// Row tap: saved/failed SSH hosts connect (+ auto-expand on
    /// success); a connected host just toggles its fold.
    private func handleRowTap() {
        switch host.connectionState {
        case .failed:
            if host.sshTarget != nil {
                // Same reason as the context menu's Retry: a failed attempt can
                // leave its connect task behind, and connectSavedHost returns
                // early when it sees one, so tapping the row would do nothing.
                store.retryConnectingHost(host)
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
        case .saved:
            if host.sshTarget != nil {
                store.connectSavedHost(host)
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
        case .connected:
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        case .connecting:
            break
        }
    }

    /// Free space on the peer, shown only once it is worth acting on.
    ///
    /// Agent checkouts and their build output are what fill a remote host, and
    /// the failure mode is a job that dies mid-run with no obvious cause. A
    /// host that reports no capacity — an older build, or one that cannot
    /// measure it — shows nothing rather than a fake reading.
    @ViewBuilder
    private var diskBadge: some View {
        if host.isConnected,
           let text = diskWarningText {
            HStack(spacing: 2) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 8, weight: .semibold))
                Text(text)
                    .font(.system(size: 9))
                    .monospacedDigit()
            }
            .foregroundColor(.orange)
            .help("Low disk space on \(host.displayName) — agent checkouts and builds may fail. Reclaim with `tm-agent gc plan` on that host.")
        }
    }

    private var hostHeader: some View {
        HStack(spacing: 2) {
            Button(action: handleRowTap) {
                HStack(spacing: 3) {
                    if host.isConnected {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(peerAccentGradient)
                            .frame(width: 3, height: 12)
                            .accessibilityHidden(true)
                    }
                    hostStatusIcon
                    Text(host.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(host.isConnected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isCollapsedHostBusy {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundColor(peerAccentPrimary)
                            .accessibilityHidden(true)
                    }
                    if host.isConnected, !host.workspaces.isEmpty {
                        let panes = host.workspaces.reduce(0) { $0 + $1.paneCount }
                        let busy = host.workspaces.reduce(0) { $0 + $1.busyCount }
                        Text("(\(host.workspaces.count) · \(panes)p)")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundColor(Color.secondary.opacity(0.7))
                        if busy > 0 {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 5, height: 5)
                                .help("\(busy) pane\(busy == 1 ? "" : "s") running a command across this host")
                        }
                    }
                    diskBadge
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .accessibilityLabel(hostAccessibilityLabel)
            .accessibilityValue(hostAccessibilityValue)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(host.displayName)" : "Expand \(host.displayName)")
            .help(isExpanded ? "Collapse \(host.displayName)" : "Expand \(host.displayName)")

            if host.isConnected {
                Button {
                    showShellCleanup = true
                    Task { await loadShellCleanup() }
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clean Up Panes…")
            }

            if host.isConnected, host.supportsWorkspaceLifecycle == true {
                Button {
                    newWorkspaceTitle = ""
                    showNewWorkspaceAlert = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Workspace…")
            }
        }
        .padding(.leading, host.isConnected ? 2 : 10)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(peerHeaderBackground)
        }
        .padding(.horizontal, usesSeparatedPresentation ? 6 : 0)
        .contextMenu {
            switch host.connectionState {
            case .saved:
                if host.sshTarget != nil {
                    Button("Connect") { store.connectSavedHost(host) }
                }
            case .failed:
                if host.sshTarget != nil {
                    Button("Retry Connection") { store.retryConnectingHost(host) }
                }
            case .connected:
                // Grouped by what the action touches, because the two
                // destructive-looking entries are not equally destructive:
                // Disconnect only drops this Mac's end of the link, while
                // Clean Up Panes ends processes on the host itself.
                Button("Open Surface as Pane…") {
                    store.openSurfaceAsPane(host)
                }
                Button("New Workspace…") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        newWorkspaceTitle = ""
                        showNewWorkspaceAlert = true
                    }
                }
                .disabled(host.supportsWorkspaceLifecycle != true)

                Divider()
                // No confirmation: the host keeps running, so reconnecting
                // picks the work back up. Guarding a reversible action wears
                // out the habit that has to still work for Clean Up Panes.
                Button("Disconnect") { store.forceDisconnectSavedHost(host) }

                Divider()
                Button("Clean Up Panes…", role: .destructive) {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        showShellCleanup = true
                        await loadShellCleanup()
                    }
                }
            case .connecting:
                Button("Cancel Connection") { store.cancelConnectingHost(host) }
                Button("Retry Connection") { store.retryConnectingHost(host) }
            }
            profileMenuItems
        }
    }

    @ViewBuilder
    private var hostContent: some View {
        if host.workspaces.isEmpty {
            HStack(spacing: 8) {
                Text(emptyBodyText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if case .connecting = host.connectionState {
                    Spacer(minLength: 4)
                    Button("Cancel") { store.cancelConnectingHost(host) }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help("Cancel connection attempt")
                    Button("Retry") { store.retryConnectingHost(host) }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help("Abandon this attempt and start a new one")
                }
                if case .failed = host.connectionState, host.sshTarget != nil {
                    Spacer(minLength: 4)
                    Button("Retry") { store.retryConnectingHost(host) }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help("Try connecting again")
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let windowGroups = groupWorkspacesByWindow(
                host.workspaces,
                windowID: { $0.windowID },
                windowTitle: { $0.windowTitle }
            )
            VStack(spacing: 4) {
                if windowGroups.count > 1 {
                    ForEach(windowGroups, id: \.windowID) { group in
                        Text(peerWindowLabel(title: group.windowTitle, id: group.windowID))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color.secondary.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 20)
                            .padding(.top, 4)
                            .padding(.bottom, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(group.items) { workspace in
                            RemoteWorkspaceRowView(
                                workspace: workspace,
                                host: host,
                                store: store,
                                usesSeparatedPresentation: usesSeparatedPresentation,
                                paneExpansionCommand: paneExpansionCommand
                            )
                        }
                    }
                } else {
                    ForEach(host.workspaces) { workspace in
                        RemoteWorkspaceRowView(
                            workspace: workspace,
                            host: host,
                            store: store,
                            usesSeparatedPresentation: usesSeparatedPresentation,
                            paneExpansionCommand: paneExpansionCommand
                        )
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            hostHeader
            if isExpanded {
                hostContent
                    .padding(.top, 4)
            }
        }
        .confirmationDialog(
            "Delete \"\(host.displayName)\"?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                store.deleteProfile(for: host)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved host profile is removed. Open panes and mirrors stay connected.")
        }
        .alert("New Workspace", isPresented: $showNewWorkspaceAlert) {
            TextField("Workspace name", text: $newWorkspaceTitle)
            Button("Create") {
                let title = newWorkspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                store.createWorkspace(host: host, title: title)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new workspace on \"\(host.displayName)\".")
        }
        .sheet(isPresented: $showShellCleanup) {
            PeerShellCleanupSheet(
                hostName: host.displayName,
                items: shellCleanupItems,
                isLoading: shellCleanupLoading,
                error: shellCleanupError,
                selection: $shellCleanupSelection,
                onRefresh: {
                    Task { await loadShellCleanup() }
                },
                onClose: {
                    Task { await closeSelectedShells() }
                }
            )
        }
        .padding(.horizontal, usesSeparatedPresentation ? 0 : 6)
        .onChange(of: isExpanded) { newValue in
            SidebarLayoutSettings.setHostCollapsed(host.id, !newValue)
        }
        .onChange(of: expandSignal) { signal in
            if signal.key == host.id { isExpanded = true }
        }
    }

    @MainActor
    private func loadShellCleanup() async {
        shellCleanupLoading = true
        shellCleanupError = nil
        do {
            let items = try await TeamOrchestrator.shared.inspectPeerShells(host: host)
            shellCleanupItems = items
            shellCleanupSelection = Set(items.compactMap { item in
                guard !item.isBusy else { return nil }
                switch item.state {
                case .managedOrphan, .missingDirectory: return item.id
                case .inUse, .unclaimed: return nil
                }
            })
        } catch {
            shellCleanupItems = []
            shellCleanupSelection = []
            shellCleanupError = String(describing: error)
        }
        shellCleanupLoading = false
    }

    @MainActor
    private func closeSelectedShells() async {
        shellCleanupLoading = true
        shellCleanupError = nil
        do {
            _ = try await TeamOrchestrator.shared.closePeerShells(
                host: host,
                surfaceIDs: shellCleanupSelection
            )
            shellCleanupItems.removeAll { shellCleanupSelection.contains($0.id) }
            shellCleanupSelection = []
        } catch {
            // Part of the sweep may have landed before the failure, so the list
            // on screen no longer describes the host. Re-read it, then restore
            // the message the refresh clears on its way in.
            let message = String(describing: error)
            await loadShellCleanup()
            shellCleanupError = message
        }
        shellCleanupLoading = false
    }
}

struct RemoteWorkspaceRowView: View {
    private enum MirrorVisualState {
        case closed
        case connected
        case working
        case viewing
        /// Open, but living in a different window of this app. The row still
        /// reads "open" everywhere (one app holds one view of a host
        /// workspace), so without this the only feedback for a click is focus
        /// jumping to a window the person may not even be looking at.
        case elsewhere
    }

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tabManager: TabManager
    @ObservedObject private var activeDrag = SidebarActiveDrag.shared
    let workspace: WorkspaceSummary
    /// The host group this row is rendered under. Passed explicitly so the
    /// mirror open uses THIS host's spec (SSH vs direct) — a workspace.id can
    /// be shared across host groups (same daemon reached two ways), so an
    /// id-based reverse lookup could pick the wrong (non-SSH) host.
    let host: HostEntry
    let store: RemoteHostStore
    let usesSeparatedPresentation: Bool
    let paneExpansionCommand: PeerPaneExpansionCommand
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameTitle = ""
    @State private var showDeleteConfirm = false
    @State private var showShellCleanup = false
    @State private var shellCleanupItems: [TeamOrchestrator.PeerShellCleanupItem] = []
    @State private var shellCleanupSelection = Set<Data>()
    @State private var shellCleanupLoading = false
    @State private var shellCleanupError: String?
    @State private var panesExpanded = false
    @State private var manuallyCollapsedWhileSelected = false
    @FocusState private var renameFieldFocused: Bool

    private var canManage: Bool { host.supportsWorkspaceLifecycle == true }

    private var mirroredWorkspace: Workspace? {
        // App-wide on purpose: one app holds one view of a host workspace,
        // so the row reads "open" in every window and clicking it goes to
        // wherever that view lives.
        PeerClientCoordinator.shared.mirroredWorkspace(
            forHostKey: host.paneHostSpec.hostKey,
            hostWorkspaceID: workspace.id
        )
    }

    private var isMirrorOpen: Bool { mirroredWorkspace != nil }

    private var isBeingDragged: Bool {
        guard let id = mirroredWorkspace?.id else { return false }
        return activeDrag.tabId == id
    }

    private var isMirrorSelected: Bool {
        mirroredWorkspace?.id == tabManager.selectedTabId
    }

    /// The window that actually holds this mirror, which is not necessarily
    /// the window drawing this row — `RemoteHostStore` is a singleton, so
    /// every window's sidebar renders the same host list.
    private var mirrorHomeContext: AppDelegate.MainWindowContext? {
        guard let id = mirroredWorkspace?.id else { return nil }
        return AppDelegate.shared?.contextContainingTabId(id)
    }

    private var isMirrorInAnotherWindow: Bool {
        guard let home = mirrorHomeContext?.tabManager else { return false }
        return home !== tabManager
    }

    /// Names the other window by what it is showing rather than by index —
    /// "Window 2" has to be counted, a workspace title is recognized.
    private var mirrorHomeWindowLabel: String? {
        guard isMirrorInAnotherWindow, let home = mirrorHomeContext else { return nil }
        if let title = home.window?.title, !title.isEmpty { return title }
        guard let selected = home.tabManager.selectedTabId,
              let tab = home.tabManager.tabs.first(where: { $0.id == selected }),
              !tab.title.isEmpty
        else { return nil }
        return tab.title
    }

    private var mirrorVisualState: MirrorVisualState {
        if isMirrorSelected { return .viewing }
        if isMirrorInAnotherWindow { return .elsewhere }
        if isMirrorOpen, workspace.busyCount > 0 { return .working }
        if isMirrorOpen { return .connected }
        return .closed
    }

    private var mirrorActionTitle: String {
        switch mirrorVisualState {
        case .closed: return "미러 열기"
        case .connected: return "연결됨"
        case .working: return "작업 중"
        case .viewing: return "보고 있음"
        case .elsewhere:
            guard let label = mirrorHomeWindowLabel else { return "다른 창" }
            return "다른 창 · \(label)"
        }
    }

    private var mirrorStatusIcon: String {
        switch mirrorVisualState {
        case .closed: return "arrow.triangle.2.circlepath"
        case .connected: return "link"
        case .working: return "bolt.fill"
        case .viewing: return "eye.fill"
        case .elsewhere: return "macwindow.on.rectangle"
        }
    }

    private var peerAccentNSColors: [NSColor] {
        PeerHostAccent.colors(for: host.paneHostSpec.hostKey)
    }

    private var originalPeerGradient: LinearGradient {
        LinearGradient(
            colors: peerAccentNSColors.map { Color(nsColor: $0) },
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func peerTintGradient(role: PeerSidebarPaletteRole) -> LinearGradient {
        LinearGradient(
            colors: PeerSidebarPalette.colors(
                from: peerAccentNSColors,
                role: role,
                colorScheme: colorScheme
            ),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var usesInvertedMirrorForeground: Bool {
        switch mirrorVisualState {
        case .working, .viewing: return true
        case .closed, .connected, .elsewhere: return false
        }
    }

    private var mirrorPrimaryColor: Color {
        usesInvertedMirrorForeground ? .white : .primary
    }

    private func mirrorSecondaryColor(_ opacity: Double = 0.75) -> Color {
        switch mirrorVisualState {
        case .working, .viewing: return .white.opacity(opacity)
        case .connected: return .primary.opacity(opacity)
        case .closed: return .secondary.opacity(opacity)
        case .elsewhere: return .secondary.opacity(opacity * 0.8)
        }
    }

    private var separatedCardBackground: AnyShapeStyle {
        switch mirrorVisualState {
        case .closed: return AnyShapeStyle(rowBackgroundFill)
        case .connected: return AnyShapeStyle(peerTintGradient(role: .workspaceConnected))
        case .working: return AnyShapeStyle(peerTintGradient(role: .workspaceWorking))
        case .viewing: return AnyShapeStyle(originalPeerGradient)
        // Deliberately the plain row fill, not a tint: the host accent means
        // "live here", and this window is not where it lives.
        case .elsewhere: return AnyShapeStyle(rowBackgroundFill)
        }
    }

    private var mirrorAccessibilityValue: String {
        guard isMirrorOpen else { return "열리지 않음" }
        return isMirrorSelected ? "미러링 중, 선택됨" : "미러링 중"
    }

    private var mirrorAccessibilityHint: String {
        if isMirrorSelected {
            return "현재 mirror workspace가 열려 있습니다."
        }
        if isMirrorOpen {
            return "이미 열린 mirror workspace를 선택합니다."
        }
        return "Peer workspace를 현재 window에서 live mirror로 엽니다."
    }

    /// Row fill: an accent wash while renaming (so the mode reads at a
    /// glance), a faint hover highlight otherwise.
    private var rowBackgroundFill: Color {
        if isRenaming { return Color.accentColor.opacity(0.12) }
        return isHovering ? Color.primary.opacity(0.07) : Color.clear
    }

    @ViewBuilder
    private var mirrorStatus: some View {
        HStack(spacing: 3) {
            Image(systemName: mirrorStatusIcon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(mirrorActionTitle)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(mirrorSecondaryColor(0.9))
    }

    /// Enter Finder-style inline rename: swap the label for a focused,
    /// pre-selected text field.
    private func beginRename() {
        renameTitle = workspace.title
        isRenaming = true
    }

    /// Row tap: open the live workspace mirror. Rename is a context-menu
    /// action (the slow-second-click gesture was dropped — it fought the
    /// click-to-open primary action and felt unpredictable).
    private func handleTap() {
        guard !isRenaming else { return }
        store.openWorkspaceAsMirror(workspace, host: host, live: true)
    }

    /// Commit the edit if it changed and is non-empty; always exit edit mode.
    private func commitRename() {
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != workspace.title {
            store.renameWorkspace(workspace, host: host, title: title)
        }
        isRenaming = false
    }

    @ViewBuilder
    private var workspaceIdentity: some View {
        Image(systemName: "terminal")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
        if isRenaming {
            // Finder-style inline edit: Enter commits, Esc cancels,
            // focus loss commits (matching macOS rename behavior).
            // Distinct field chrome (filled background + accent ring)
            // so entering rename reads clearly in both light and dark
            // — a bare inline field was too easy to miss.
            TextField("", text: $renameTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundColor(.primary)
                .focused($renameFieldFocused)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        )
                )
                .onSubmit { commitRename() }
                .onExitCommand { isRenaming = false }   // Esc = cancel
                .onChange(of: renameFieldFocused) { focused in
                    if !focused && isRenaming { commitRename() }
                }
                .onAppear { renameFieldFocused = true }
        } else {
            Text(workspace.title)
                .font(.system(size: 11.5))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var busyIndicator: some View {
        if workspace.busyCount > 0 {
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
                .help("\(workspace.busyCount) pane\(workspace.busyCount == 1 ? "" : "s") running a command")
        }
    }

    private var legacyRow: some View {
        HStack(spacing: 5) {
            workspaceIdentity
            Spacer()
            // Pane/surface counts + a busy dot — the workspace's live
            // inventory at a glance (hidden mid-rename so the field is
            // uncluttered). "2p" when panes == surfaces, else "2p·4s".
            if !isRenaming {
                Text(workspace.paneCount == workspace.surfaceCount
                     ? "\(workspace.paneCount)p"
                     : "\(workspace.paneCount)p·\(workspace.surfaceCount)s")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundColor(Color.secondary.opacity(0.7))
                busyIndicator
            }
        }
    }

    private func rowChrome<Content: View>(
        leadingPadding: CGFloat = 20,
        _ content: Content
    ) -> some View {
        content
            .padding(.leading, leadingPadding)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(rowBackgroundFill)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
    }

    private var paneDetails: some View {
        VStack(spacing: 3) {
            ForEach(workspace.panes) { pane in
                VStack(spacing: 1) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(
                                pane.isBusy
                                    ? (usesInvertedMirrorForeground ? Color.white : Color.orange)
                                    : mirrorSecondaryColor(0.45)
                            )
                            .frame(width: 5, height: 5)
                        Text(pane.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(mirrorPrimaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if pane.columns > 0, pane.rows > 0 {
                            Text("\(pane.columns)×\(pane.rows)")
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundColor(mirrorSecondaryColor(0.65))
                        }
                    }
                    HStack(spacing: 4) {
                        if let directory = pane.workingDirectoryName {
                            Image(systemName: "folder")
                                .font(.system(size: 8))
                            Text(directory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if pane.workingDirectoryName != nil {
                            Text("·")
                        }
                        Text("\(pane.tabCount) tab\(pane.tabCount == 1 ? "" : "s")")
                    }
                    .font(.system(size: 9))
                    .foregroundColor(mirrorSecondaryColor(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.leading, 33)
        .padding(.trailing, 11)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .transition(.opacity)
    }

    @ViewBuilder
    private var separatedRow: some View {
        if isRenaming {
            rowChrome(HStack(spacing: 5) {
                workspaceIdentity
                Spacer()
            })
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !workspace.panes.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                panesExpanded.toggle()
                                manuallyCollapsedWhileSelected = isMirrorSelected && !panesExpanded
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(panesExpanded ? 90 : 0))
                                .foregroundColor(mirrorSecondaryColor(0.8))
                                .frame(width: 20, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(panesExpanded
                                            ? "Hide pane details for \(workspace.title)"
                                            : "Show pane details for \(workspace.title)")
                        .padding(.leading, 8)
                        .help(panesExpanded ? "Hide pane details" : "Show pane details")
                    }
                    Button(action: handleTap) {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal")
                                .font(.system(size: 9))
                                .foregroundColor(mirrorSecondaryColor(0.85))
                            Text(workspace.title)
                                .font(.system(size: 11.5))
                                .foregroundColor(mirrorPrimaryColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            mirrorStatus
                        }
                        .padding(.leading, workspace.panes.isEmpty ? 10 : 0)
                        .padding(.trailing, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(workspace.title), \(mirrorActionTitle)")
                    .accessibilityValue(mirrorAccessibilityValue)
                    .accessibilityHint(mirrorAccessibilityHint)
                    .help(isMirrorOpen
                          ? "Select the open mirror for \(workspace.title)"
                          : "Open \(workspace.title) as a live workspace mirror")
                }
                if panesExpanded {
                    paneDetails
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(separatedCardBackground)
            )
            .padding(.horizontal, 6)
        }
    }

    var body: some View {
        Group {
            if usesSeparatedPresentation {
                separatedRow
            } else {
                rowChrome(legacyRow)
                    .onTapGesture { handleTap() }
            }
        }
        // Dragging this row moves the open mirror to another window. What
        // travels is the local Workspace backing it, so the drop side needs no
        // peer-specific handling — the same payload the Local Workspaces rows
        // use. A row with nothing open is not draggable: there is no view to
        // move, and opening one belongs to the menu above, where the person
        // can say which window.
        .opacity(isBeingDragged ? 0.6 : 1)
        .onDrag {
            guard let mirror = mirroredWorkspace else {
#if DEBUG
                dlog("sidebar.onDrag.peer.skip reason=noMirror host=\(host.displayName)")
#endif
                return NSItemProvider()
            }
#if DEBUG
            dlog("sidebar.onDrag.peer tab=\(mirror.id.uuidString.prefix(5)) host=\(host.displayName)")
#endif
            return SidebarTabDragPayload.provider(for: mirror.id)
        }
        .contextMenu {
            // Live mirror (Phase 2B): host-authoritative layout sync —
            // splits/closes follow the host and local actions forward.
            Button("Open as Live Workspace in Main Window") {
                store.openWorkspaceAsMirror(workspace, host: host, live: true)
            }
            // Legacy standalone viewer window.
            Button("Open in Relay Window") {
                store.openWorkspace(workspace, host: host)
            }
            // Phase 1.5 remote pane primitive, scoped to this workspace's
            // surfaces: single-surface workspaces attach directly (no
            // picker), multi-surface workspaces fall through to a picker
            // restricted to this workspace. Surface count isn't cached in
            // WorkspaceSummary, so the branch is resolved at click time —
            // see RemoteHostStore.openWorkspaceSurfaceAsPane.
            Button("Open as Pane in Current Workspace…") {
                store.openWorkspaceSurfaceAsPane(workspace, host: host)
            }
            // Snapshot mode (live: false — detached layout copy) is
            // intentionally NOT offered: with content always streaming
            // live, users read the near-identical workspace as a broken
            // mirror. The code path stays for a future, clearer surface.
            Divider()
            Button("Clean Up Panes…") {
                showShellCleanup = true
                Task { await loadShellCleanup() }
            }
            // Rename opens Finder-style inline edit (no modal). Always
            // shown, disabled when the host hasn't negotiated
            // workspace.lifecycle.v1 — keeps the menu shape stable.
            Button("Rename") { beginRename() }
                .disabled(!canManage)
            // Any workspace (including the default) can be deleted, but
            // the host refuses to remove the LAST one — disable delete
            // then so the action never silently no-ops.
            Button("Delete…", role: .destructive) {
                showDeleteConfirm = true
            }
            .disabled(!canManage || host.workspaces.count <= 1)
        }
        .onHover { isHovering = $0 }
        .onAppear {
            if isMirrorSelected, !manuallyCollapsedWhileSelected {
                panesExpanded = true
            }
        }
        .onChange(of: isMirrorSelected) { isSelected in
            if isSelected {
                if !manuallyCollapsedWhileSelected {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        panesExpanded = true
                    }
                }
            } else {
                manuallyCollapsedWhileSelected = false
            }
        }
        .onChange(of: paneExpansionCommand) { command in
            withAnimation(.easeInOut(duration: 0.15)) {
                panesExpanded = command.isExpanded
                manuallyCollapsedWhileSelected = isMirrorSelected && !command.isExpanded
            }
        }
        .confirmationDialog(
            "Delete \"\(workspace.title)\"?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                store.deleteWorkspace(workspace, host: host)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(workspace.isDefault
                 ? "All panes on the host for this workspace are closed. This is the default workspace — another one is promoted in its place."
                 : "All panes on the host for this workspace are closed.")
        }
        .sheet(isPresented: $showShellCleanup) {
            PeerShellCleanupSheet(
                hostName: host.displayName,
                scopeName: workspace.title,
                items: shellCleanupItems,
                isLoading: shellCleanupLoading,
                error: shellCleanupError,
                selection: $shellCleanupSelection,
                onRefresh: {
                    Task { await loadShellCleanup() }
                },
                onClose: {
                    Task { await closeSelectedShells() }
                }
            )
        }
    }

    @MainActor
    private func loadShellCleanup() async {
        shellCleanupLoading = true
        shellCleanupError = nil
        do {
            let items = try await TeamOrchestrator.shared.inspectPeerShells(
                host: host,
                workspaceID: workspace.id
            )
            shellCleanupItems = items
            shellCleanupSelection = Set(items.compactMap { item in
                guard !item.isBusy else { return nil }
                switch item.state {
                case .managedOrphan, .missingDirectory: return item.id
                case .inUse, .unclaimed: return nil
                }
            })
        } catch {
            shellCleanupItems = []
            shellCleanupSelection = []
            shellCleanupError = String(describing: error)
        }
        shellCleanupLoading = false
    }

    @MainActor
    private func closeSelectedShells() async {
        shellCleanupLoading = true
        shellCleanupError = nil
        do {
            _ = try await TeamOrchestrator.shared.closePeerShells(
                host: host,
                surfaceIDs: shellCleanupSelection
            )
            shellCleanupItems.removeAll { shellCleanupSelection.contains($0.id) }
            shellCleanupSelection = []
        } catch {
            let message = String(describing: error)
            await loadShellCleanup()
            shellCleanupError = message
        }
        shellCleanupLoading = false
    }
}
