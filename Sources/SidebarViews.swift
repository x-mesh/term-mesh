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
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @StateObject private var commandKeyMonitor = SidebarCommandKeyMonitor()
    @StateObject private var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    @ObservedObject private var remoteHostStore = RemoteHostStore.shared
    @State private var draggedTabId: UUID?
    @State private var dropIndicator: SidebarDropIndicator?
    @AppStorage(SidebarLayoutSettings.localTabsCollapsedKey)
    private var localTabsCollapsed = false
    @AppStorage(SidebarPresentationSettings.separatedSectionsEnabledKey)
    private var sidebarSeparatedSectionsEnabled = SidebarPresentationSettings.defaultSeparatedSectionsEnabled

    /// Space at top of sidebar for traffic light buttons
    private let trafficLightPadding: CGFloat = 28
    private let tabRowSpacing: CGFloat = 2

    private var visibleLocalWorkspaceIds: [UUID] {
        SidebarPresentationSettings.visibleLocalWorkspaceIDs(
            from: tabManager.tabs.map { (id: $0.id, isPeerMirror: $0.isPeerMirror) },
            separatedSectionsEnabled: sidebarSeparatedSectionsEnabled
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Space for traffic lights / fullscreen controls
                        Spacer()
                            .frame(height: trafficLightPadding)

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
                                            tab: tab,
                                            index: index,
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
            guard draggedTabId != nil else { return }
            let reason = SidebarDragLifecycleNotification.reason(from: notification)
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

struct SidebarRemoteHostsSection: View {
    @ObservedObject var store: RemoteHostStore
    let usesSeparatedPresentation: Bool
    @AppStorage(SidebarLayoutSettings.remoteHostsCollapsedKey)
    private var isCollapsed = false
    @AppStorage(PeerSidebarGroupingSettings.featureFlagKey)
    private var isGroupingControlEnabled = true
    @AppStorage(PeerSidebarGroupingSettings.selectedModeKey)
    private var selectedGroupingMode = PeerSidebarGroupingSettings.defaultMode.rawValue
    /// Non-nil presents the add/edit sheet.
    @State private var editorContext: PeerHostEditorContext?
    @State private var areAllPaneDetailsExpanded = false
    @State private var paneExpansionCommand = PeerPaneExpansionCommand(
        isExpanded: false,
        generation: 0
    )

    private var hasPeerPaneDetails: Bool {
        store.sortedHosts.contains { host in
            host.workspaces.contains { !$0.panes.isEmpty }
        }
    }

    private var groupingMode: PeerSidebarGroupingMode {
        guard isGroupingControlEnabled else { return .host }
        return PeerSidebarGroupingSettings.mode(from: selectedGroupingMode)
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

                if !isCollapsed, isGroupingControlEnabled {
                    Picker("", selection: $selectedGroupingMode) {
                        ForEach(PeerSidebarGroupingMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 104)
                    .layoutPriority(1)
                    .accessibilityLabel("Peer hosts grouping")
                    .help("Group peer hosts by host or project")
                }

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
                    VStack(spacing: usesSeparatedPresentation ? 8 : 0) {
                        switch groupingMode {
                        case .host:
                            ForEach(store.sortedHosts) { host in
                                RemoteHostGroupView(
                                    host: host,
                                    store: store,
                                    usesSeparatedPresentation: usesSeparatedPresentation,
                                    paneExpansionCommand: paneExpansionCommand
                                ) { context in
                                    editorContext = context
                                }
                            }
                        case .project:
                            SidebarPeerProjectsView(
                                hosts: store.sortedHosts,
                                store: store,
                                usesSeparatedPresentation: usesSeparatedPresentation,
                                paneExpansionCommand: paneExpansionCommand
                            )
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

private struct SidebarPeerProjectGroup: Identifiable {
    struct WorkspaceItem: Identifiable {
        let host: HostEntry
        let workspace: WorkspaceSummary

        var id: String {
            "\(host.id):\(workspace.id.base64EncodedString())"
        }
    }

    let identity: PeerProjectIdentity
    var items: [WorkspaceItem]

    var id: String { identity.id }
}

/// Project-axis rendering of the peer section. Deliberately shows NOTHING but
/// projects: a host that contributes no workspace has no place on this axis,
/// and listing it here just reproduced the Host view one toggle away. Host
/// lifecycle (connect, retry, edit, delete) lives in the Host view alone.
private struct SidebarPeerProjectsView: View {
    let hosts: [HostEntry]
    let store: RemoteHostStore
    let usesSeparatedPresentation: Bool
    let paneExpansionCommand: PeerPaneExpansionCommand

    private var connectedHosts: [HostEntry] {
        hosts.filter { $0.isConnected && !$0.workspaces.isEmpty }
    }

    private var projectGroups: [SidebarPeerProjectGroup] {
        var indexes: [PeerProjectIdentity: Int] = [:]
        var groups: [SidebarPeerProjectGroup] = []
        for host in connectedHosts {
            for workspace in host.workspaces {
                let identity = peerProjectIdentity(for: workspace.panes)
                let item = SidebarPeerProjectGroup.WorkspaceItem(
                    host: host,
                    workspace: workspace
                )
                if let index = indexes[identity] {
                    groups[index].items.append(item)
                } else {
                    indexes[identity] = groups.count
                    groups.append(SidebarPeerProjectGroup(identity: identity, items: [item]))
                }
            }
        }
        return groups.sorted {
            if $0.identity.isUnknown != $1.identity.isUnknown {
                return !$0.identity.isUnknown
            }
            return $0.identity.label.localizedCaseInsensitiveCompare($1.identity.label) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: usesSeparatedPresentation ? 8 : 0) {
            if projectGroups.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No projects yet")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    // The empty state is the only place this view mentions
                    // hosts at all — without it a peerless Project view would
                    // be a dead end with no route to connecting one.
                    Text("Connect a peer in the Host view to see its projects.")
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }

            ForEach(projectGroups) { group in
                VStack(spacing: 4) {
                    Text(group.identity.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(group.identity.isUnknown
                                            ? "Unknown Project"
                                            : "Project \(group.identity.label)")
                    ForEach(group.items) { item in
                        RemoteWorkspaceRowView(
                            workspace: item.workspace,
                            host: item.host,
                            store: store,
                            usesSeparatedPresentation: usesSeparatedPresentation,
                            paneExpansionCommand: paneExpansionCommand
                        )
                    }
                }
            }

        }
    }
}

struct RemoteHostGroupView: View {
    @Environment(\.colorScheme) private var colorScheme
    let host: HostEntry
    let store: RemoteHostStore
    let usesSeparatedPresentation: Bool
    let paneExpansionCommand: PeerPaneExpansionCommand
    /// Opens the shared add/edit sheet (owned by the section view).
    let onEdit: (PeerHostEditorContext) -> Void
    @State private var isExpanded: Bool
    @State private var showDeleteConfirm = false
    @State private var showNewWorkspaceAlert = false
    @State private var newWorkspaceTitle = ""
    @State private var showForceDisconnectConfirm = false

    init(host: HostEntry, store: RemoteHostStore,
         usesSeparatedPresentation: Bool,
         paneExpansionCommand: PeerPaneExpansionCommand,
         onEdit: @escaping (PeerHostEditorContext) -> Void) {
        self.host = host
        self.store = store
        self.usesSeparatedPresentation = usesSeparatedPresentation
        self.paneExpansionCommand = paneExpansionCommand
        self.onEdit = onEdit
        // Fold state persists per stable host key; default is expanded.
        _isExpanded = State(initialValue: !SidebarLayoutSettings.isHostCollapsed(host.id))
    }

    /// Profile-management items shared by every connection state.
    @ViewBuilder
    private var profileMenuItems: some View {
        if let profileID = host.profileID,
           let profile = PeerHostProfileStore.shared.profile(id: profileID) {
            Divider()
            Button("Edit…") {
                onEdit(PeerHostEditorContext(profile: profile, isNew: false))
            }
            Button("Delete…", role: .destructive) {
                showDeleteConfirm = true
            }
        } else if let draft = store.profileDraft(for: host) {
            // Ad-hoc SSH connection → offer promotion to a saved host.
            Divider()
            Button("Save as Host…") {
                onEdit(PeerHostEditorContext(profile: draft, isNew: true))
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
                Button("Open Surface as Pane…") {
                    store.openSurfaceAsPane(host)
                }
                Button("New Workspace…") {
                    newWorkspaceTitle = ""
                    showNewWorkspaceAlert = true
                }
                .disabled(host.supportsWorkspaceLifecycle != true)
                if store.hasSidebarLease(for: host.id) {
                    Button("Disconnect") { store.disconnectSavedHost(host) }
                }
                Button("Force Disconnect (Close All Panes)…") {
                    showForceDisconnectConfirm = true
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
        .confirmationDialog(
            "Force disconnect \"\(host.displayName)\"?",
            isPresented: $showForceDisconnectConfirm
        ) {
            Button("Force Disconnect", role: .destructive) {
                store.forceDisconnectSavedHost(host)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Closes every pane, mirror and relay window opened from this host. Remote processes keep running on the host.")
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
        .padding(.horizontal, usesSeparatedPresentation ? 0 : 6)
        .onChange(of: isExpanded) { newValue in
            SidebarLayoutSettings.setHostCollapsed(host.id, !newValue)
        }
        .onChange(of: store.expandSignal) { signal in
            if signal.key == host.id { isExpanded = true }
        }
    }
}

struct RemoteWorkspaceRowView: View {
    private enum MirrorVisualState {
        case closed
        case connected
        case working
        case viewing
    }

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tabManager: TabManager
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
    @State private var panesExpanded = false
    @State private var manuallyCollapsedWhileSelected = false
    @FocusState private var renameFieldFocused: Bool

    private var canManage: Bool { host.supportsWorkspaceLifecycle == true }

    private var mirroredWorkspace: Workspace? {
        PeerClientCoordinator.shared.mirroredWorkspace(
            forHostKey: host.paneHostSpec.hostKey,
            hostWorkspaceID: workspace.id,
            in: tabManager
        )
    }

    private var isMirrorOpen: Bool { mirroredWorkspace != nil }

    private var isMirrorSelected: Bool {
        mirroredWorkspace?.id == tabManager.selectedTabId
    }

    private var mirrorVisualState: MirrorVisualState {
        if isMirrorSelected { return .viewing }
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
        }
    }

    private var mirrorStatusIcon: String {
        switch mirrorVisualState {
        case .closed: return "arrow.triangle.2.circlepath"
        case .connected: return "link"
        case .working: return "bolt.fill"
        case .viewing: return "eye.fill"
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
        case .closed, .connected: return false
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
        }
    }

    private var separatedCardBackground: AnyShapeStyle {
        switch mirrorVisualState {
        case .closed: return AnyShapeStyle(rowBackgroundFill)
        case .connected: return AnyShapeStyle(peerTintGradient(role: .workspaceConnected))
        case .working: return AnyShapeStyle(peerTintGradient(role: .workspaceWorking))
        case .viewing: return AnyShapeStyle(originalPeerGradient)
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
    }
}
