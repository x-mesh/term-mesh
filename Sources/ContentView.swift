import AppKit
import Bonsplit
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


/// Installs a FileDropOverlayView on the window's theme frame for Finder file drag support.

struct ContentView: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let windowId: UUID
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var sidebarSelectionState: SidebarSelectionState
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.daemonService) private var daemonService
    @Environment(\.configProvider) private var configProvider
    @Environment(\.browserHistoryService) private var browserHistory
    @State private var sidebarWidth: CGFloat = 200
    @State private var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    @State private var isResizerDragging = false
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var selectedTabIds: Set<UUID> = []
    @State private var mountedWorkspaceIds: [UUID] = []
    @State private var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var titlebarGitBranch: String = ""
    @State private var titlebarGitDirty: Bool = false
    @State private var titlebarGitDirtyCount: Int = 0
    @State private var titlebarWorktreeName: String = ""
    @State private var titlebarIsWorktree: Bool = false
    @State private var titlebarDirBasename: String = ""
    @State private var titlebarPorts: [Int] = []
    @State private var titlebarSessionStart: Date? = nil
    @State private var titlebarTag: String? = nil
    @State private var titlebarDashboardPort: Int? = nil
    @State private var titlebarWorktreeCount: Int = 0
    @State private var isFullScreen: Bool = false
    @State private var observedWindow: NSWindow?
    @StateObject private var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @State private var previousSelectedWorkspaceId: UUID?
    @State private var retiringWorkspaceId: UUID?
    @State private var workspaceHandoffGeneration: UInt64 = 0
    @State private var workspaceHandoffFallbackTask: Task<Void, Never>?
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State private var sidebarDraggedTabId: UUID?
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @State private var sidebarResizerCursorReleaseWorkItem: DispatchWorkItem?
    @State private var sidebarResizerPointerMonitor: Any?
    @State private var isResizerBandActive = false
    @State private var isSidebarResizerCursorActive = false
    @State private var sidebarResizerCursorStabilizer: DispatchSourceTimer?
    @State private var isCommandPalettePresented = false
    @State private var commandPaletteQuery: String = ""
    @State private var commandPaletteMode: CommandPaletteMode = .commands
    @State private var commandPaletteRenameDraft: String = ""
    @State private var commandPaletteSelectedResultIndex: Int = 0
    @State private var commandPaletteHoveredResultIndex: Int?
    @State private var commandPaletteScrollTargetIndex: Int?
    @State private var commandPaletteScrollTargetAnchor: UnitPoint?
    @State private var commandPaletteRestoreFocusTarget: CommandPaletteRestoreFocusTarget?
    @State private var commandPaletteUsageHistoryByCommandId: [String: CommandPaletteUsageEntry] = [:]
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @FocusState private var isCommandPaletteSearchFocused: Bool
    @FocusState private var isCommandPaletteRenameFocused: Bool

    private static let fixedSidebarResizeCursor = NSCursor(
        image: NSCursor.resizeLeftRight.image,
        hotSpot: NSCursor.resizeLeftRight.hotSpot
    )
    private static let commandPaletteUsageDefaultsKey = "commandPalette.commandUsage.v1"
    private static let commandPaletteCommandsPrefix = ">"
    private static let minimumSidebarWidth: CGFloat = 186
    private static let maximumSidebarWidthRatio: CGFloat = 1.0 / 3.0

    private enum SidebarResizerHandle: Hashable {
        case divider
    }

    private var sidebarResizerHitWidthPerSide: CGFloat {
        SidebarResizeInteraction.hitWidthPerSide
    }

    private func maxSidebarWidth(availableWidth: CGFloat? = nil) -> CGFloat {
        let resolvedAvailableWidth = availableWidth
            ?? observedWindow?.contentView?.bounds.width
            ?? observedWindow?.contentLayoutRect.width
            ?? NSApp.keyWindow?.contentView?.bounds.width
            ?? NSApp.keyWindow?.contentLayoutRect.width
        if let resolvedAvailableWidth, resolvedAvailableWidth > 0 {
            return max(Self.minimumSidebarWidth, resolvedAvailableWidth * Self.maximumSidebarWidthRatio)
        }

        let fallbackScreenWidth = NSApp.keyWindow?.screen?.frame.width
            ?? NSScreen.main?.frame.width
            ?? 1920
        return max(Self.minimumSidebarWidth, fallbackScreenWidth * Self.maximumSidebarWidthRatio)
    }

    private func clampSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = max(
            Self.minimumSidebarWidth,
            min(maxSidebarWidth(availableWidth: availableWidth), sidebarWidth)
        )
        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            sidebarWidth = nextWidth
        }
    }

    private func activateSidebarResizerCursor() {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        sidebarResizerCursorReleaseWorkItem = nil
        isSidebarResizerCursorActive = true
        Self.fixedSidebarResizeCursor.set()
    }

    private func releaseSidebarResizerCursorIfNeeded(force: Bool = false) {
        let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let shouldKeepCursor = !force
            && (isResizerDragging || isResizerBandActive || !hoveredResizerHandles.isEmpty || isLeftMouseButtonDown)
        guard !shouldKeepCursor else { return }
        guard isSidebarResizerCursorActive else { return }
        isSidebarResizerCursorActive = false
        NSCursor.arrow.set()
    }

    private func scheduleSidebarResizerCursorRelease(force: Bool = false, delay: TimeInterval = 0) {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            sidebarResizerCursorReleaseWorkItem = nil
            releaseSidebarResizerCursorIfNeeded(force: force)
        }
        sidebarResizerCursorReleaseWorkItem = workItem
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    private func dividerBandContains(pointInContent point: NSPoint, contentBounds: NSRect) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        let minX = sidebarWidth - sidebarResizerHitWidthPerSide
        let maxX = sidebarWidth + sidebarResizerHitWidthPerSide
        return point.x >= minX && point.x <= maxX
    }

    private func updateSidebarResizerBandState(using event: NSEvent? = nil) {
        guard sidebarState.isVisible,
              let window = observedWindow,
              let contentView = window.contentView else {
            isResizerBandActive = false
            scheduleSidebarResizerCursorRelease(force: true)
            return
        }

        // Use live global pointer location instead of per-event coordinates.
        // Overlapping tracking areas (notably WKWebView) can deliver stale/jittery
        // event locations during cursor updates, which causes visible cursor flicker.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        let isInDividerBand = dividerBandContains(pointInContent: pointInContent, contentBounds: contentView.bounds)
        isResizerBandActive = isInDividerBand

        if isInDividerBand || isResizerDragging {
            activateSidebarResizerCursor()
            startSidebarResizerCursorStabilizer()
            // AppKit cursorUpdate handlers from overlapped portal/web views can run
            // after our local monitor callback and temporarily reset the cursor.
            // Re-assert on the next runloop turn to keep the resize cursor stable.
            DispatchQueue.main.async {
                Self.fixedSidebarResizeCursor.set()
            }
        } else {
            stopSidebarResizerCursorStabilizer()
            scheduleSidebarResizerCursorRelease()
        }
    }

    private func startSidebarResizerCursorStabilizer() {
        guard sidebarResizerCursorStabilizer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler {
            updateSidebarResizerBandState()
            if isResizerBandActive || isResizerDragging {
                Self.fixedSidebarResizeCursor.set()
            } else {
                stopSidebarResizerCursorStabilizer()
            }
        }
        sidebarResizerCursorStabilizer = timer
        timer.resume()
    }

    private func stopSidebarResizerCursorStabilizer() {
        sidebarResizerCursorStabilizer?.cancel()
        sidebarResizerCursorStabilizer = nil
    }

    private func installSidebarResizerPointerMonitorIfNeeded() {
        guard sidebarResizerPointerMonitor == nil else { return }
        observedWindow?.acceptsMouseMovedEvents = true
        sidebarResizerPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .mouseEntered,
                .mouseExited,
                .cursorUpdate,
                .appKitDefined,
                .systemDefined,
                .leftMouseDown,
                .leftMouseUp,
                .leftMouseDragged,
            ]
        ) { event in
            updateSidebarResizerBandState(using: event)
            let shouldOverrideCursorEvent: Bool = {
                switch event.type {
                case .cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited, .appKitDefined, .systemDefined:
                    return true
                default:
                    return false
                }
            }()
            if shouldOverrideCursorEvent, (isResizerBandActive || isResizerDragging) {
                // Consume hover motion in divider band so overlapped views cannot
                // continuously reassert their own cursor while we are resizing.
                activateSidebarResizerCursor()
                Self.fixedSidebarResizeCursor.set()
                return nil
            }
            return event
        }
        updateSidebarResizerBandState()
    }

    private func removeSidebarResizerPointerMonitor() {
        if let monitor = sidebarResizerPointerMonitor {
            NSEvent.removeMonitor(monitor)
            sidebarResizerPointerMonitor = nil
        }
        isResizerBandActive = false
        isSidebarResizerCursorActive = false
        stopSidebarResizerCursorStabilizer()
        scheduleSidebarResizerCursorRelease(force: true)
    }

    private func sidebarResizerHandleOverlay(
        _ handle: SidebarResizerHandle,
        width: CGFloat,
        availableWidth: CGFloat,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredResizerHandles.insert(handle)
                    activateSidebarResizerCursor()
                } else {
                    hoveredResizerHandles.remove(handle)
                    let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    if isLeftMouseButtonDown {
                        // Keep resize cursor pinned through mouse-down so AppKit
                        // cursorUpdate events from overlapping views do not flash arrow.
                        activateSidebarResizerCursor()
                    } else {
                        // Give mouse-down + drag-start callbacks time to establish state
                        // before any cursor pop is attempted.
                        scheduleSidebarResizerCursorRelease(delay: 0.05)
                    }
                }
                updateSidebarResizerBandState()
            }
            .onDisappear {
                hoveredResizerHandles.remove(handle)
                isResizerDragging = false
                sidebarDragStartWidth = nil
                isResizerBandActive = false
                scheduleSidebarResizerCursorRelease(force: true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isResizerDragging {
                            isResizerDragging = true
                            sidebarDragStartWidth = sidebarWidth
                            #if DEBUG
                            dlog("sidebar.resizeDragStart")
                            #endif
                        }

                        activateSidebarResizerCursor()
                        let startWidth = sidebarDragStartWidth ?? sidebarWidth
                        let nextWidth = max(
                            Self.minimumSidebarWidth,
                            min(maxSidebarWidth(availableWidth: availableWidth), startWidth + value.translation.width)
                        )
                        withTransaction(Transaction(animation: nil)) {
                            sidebarWidth = nextWidth
                        }
                    }
                    .onEnded { _ in
                        if isResizerDragging {
                            isResizerDragging = false
                            sidebarDragStartWidth = nil
                        }
                        activateSidebarResizerCursor()
                        scheduleSidebarResizerCursorRelease()
                    }
            )
            .modifier(SidebarResizerAccessibilityModifier(accessibilityIdentifier: accessibilityIdentifier))
    }

    private var sidebarResizerOverlay: some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width)
            let dividerX = min(max(sidebarWidth, 0), totalWidth)
            let leadingWidth = max(0, dividerX - sidebarResizerHitWidthPerSide)

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingWidth)
                    .allowsHitTesting(false)

                sidebarResizerHandleOverlay(
                    .divider,
                    width: sidebarResizerHitWidthPerSide * 2,
                    availableWidth: totalWidth,
                    accessibilityIdentifier: "SidebarResizer"
                )

                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
            .onAppear {
                clampSidebarWidthIfNeeded(availableWidth: totalWidth)
            }
            .onChange(of: totalWidth) {
                clampSidebarWidthIfNeeded(availableWidth: totalWidth)
            }
        }
    }

    private var sidebarView: some View {
        VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        .frame(width: sidebarWidth)
    }

    /// Space at top of content area for the titlebar. This must be at least the actual titlebar
    /// height; otherwise controls like Bonsplit tab dragging can be interpreted as window drags.
    @State private var titlebarPadding: CGFloat = 32

    private var terminalContent: some View {
        let mountedWorkspaceIdSet = Set(mountedWorkspaceIds)
        let mountedWorkspaces = tabManager.tabs.filter { mountedWorkspaceIdSet.contains($0.id) }
        let selectedWorkspaceId = tabManager.selectedTabId
        let retiringWorkspaceId = self.retiringWorkspaceId

        return ZStack {
            ZStack {
                ForEach(mountedWorkspaces) { tab in
                    let isSelectedWorkspace = selectedWorkspaceId == tab.id
                    let isRetiringWorkspace = retiringWorkspaceId == tab.id
                    // Keep the retiring workspace visible during handoff, but never input-active.
                    // Allowing both selected+retiring workspaces to be input-active lets the
                    // old workspace steal first responder (notably with WKWebView), which can
                    // delay handoff completion and make browser returns feel laggy.
                    let isInputActive = isSelectedWorkspace
                    let isVisible = isSelectedWorkspace || isRetiringWorkspace
                    let portalPriority = isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0)
                    WorkspaceContentView(
                        workspace: tab,
                        isWorkspaceVisible: isVisible,
                        isWorkspaceInputActive: isInputActive,
                        workspacePortalPriority: portalPriority,
                        onThemeRefreshRequest: { reason, eventId, source, payloadHex in
                            scheduleTitlebarThemeRefreshFromWorkspace(
                                workspaceId: tab.id,
                                reason: reason,
                                backgroundEventId: eventId,
                                backgroundSource: source,
                                notificationPayloadHex: payloadHex
                            )
                        }
                    )
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isSelectedWorkspace)
                    .zIndex(isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0))
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)

            NotificationsPage(selection: $sidebarSelectionState.selection)
                .opacity(sidebarSelectionState.selection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelectionState.selection == .notifications)
        }
        .padding(.top, titlebarPadding)
        .overlay(alignment: .top) {
            customTitlebar
        }
    }

    private var terminalContentWithSidebarDropOverlay: some View {
        terminalContent
            .overlay {
                SidebarExternalDropOverlay(draggedTabId: sidebarDraggedTabId)
            }
    }

    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("hideWelcomeScreen") private var hideWelcomeScreen: Bool = false
    @AppStorage("showStatusBar") private var showStatusBar: Bool = true
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue

    // Background glass settings
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = true
    @AppStorage("debugTitlebarLeadingExtra") private var debugTitlebarLeadingExtra: Double = 0

    @State private var titlebarLeadingInset: CGFloat = 12
    private var windowIdentifier: String { "term-mesh.main.\(windowId.uuidString)" }
    private var fakeTitlebarBackground: Color {
        _ = titlebarThemeGeneration
        let minimumChromeOpacity: CGFloat = theme.isLightBackground ? 0.90 : 0.84
        let chromeOpacity = max(minimumChromeOpacity, theme.backgroundOpacity)
        return Color(nsColor: theme.backgroundColor.withAlphaComponent(chromeOpacity))
    }
    private var fakeTitlebarTextColor: Color {
        _ = titlebarThemeGeneration
        return theme.isLightBackground
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.82)
    }

    /// Adaptive titlebar text color based on actual terminal background, not color scheme.
    private func titlebarColor(opacity: Double) -> Color {
        _ = titlebarThemeGeneration
        return theme.isLightBackground ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }
    private var fullscreenControls: some View {
        TitlebarControlsView(
            notificationStore: notificationStore,
            viewModel: fullscreenControlsViewModel,
            onToggleSidebar: { sidebarState.toggle() },
            onToggleNotifications: { [fullscreenControlsViewModel] in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: fullscreenControlsViewModel.notificationsAnchorView
                )
            },
            onNewTab: { tabManager.addTab() }
        )
    }

    private var customTitlebar: some View {
        ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            TitlebarLeadingInsetReader(inset: $titlebarLeadingInset)
                .allowsHitTesting(false)

            HStack(spacing: 6) {
                if isFullScreen && !sidebarState.isVisible {
                    fullscreenControls
                        .padding(.trailing, 4)
                }

                // Git branch + directory basename
                titlebarBranchAndDirectory

                Spacer()

                titlebarRightInfo
            }
            .frame(height: 28)
            .padding(.top, 2)
            .padding(.leading, (isFullScreen && !sidebarState.isVisible) ? 8 : (sidebarState.isVisible ? 12 : titlebarLeadingInset + CGFloat(debugTitlebarLeadingExtra)))
            .padding(.trailing, 8)
        }
        .frame(height: titlebarPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(fakeTitlebarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .overlay(alignment: .top) {
            if let progress = tabManager.titlebarProgress {
                TitlebarProgressBar(progress: progress)
                    .transition(.opacity)
            }
        }
    }

    private var titlebarBranchAndDirectory: some View {
        HStack(spacing: 5) {
            if !titlebarGitBranch.isEmpty {
                Image(systemName: titlebarIsWorktree ? "arrow.triangle.swap" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(titlebarIsWorktree ? .cyan.opacity(0.8) : titlebarColor(opacity: 0.7))
                Text(titlebarGitBranch)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(titlebarIsWorktree ? .cyan.opacity(0.9) : titlebarColor(opacity: 0.85))
                if !titlebarWorktreeName.isEmpty {
                    Text("⋮")
                        .font(.system(size: 11))
                        .foregroundColor(titlebarColor(opacity: 0.4))
                    Text(titlebarWorktreeName)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(titlebarColor(opacity: 0.65))
                }
                if titlebarGitDirty {
                    Text(titlebarGitDirtyCount > 0 ? "±\(titlebarGitDirtyCount)" : "±")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.9))
                }
            }
            if !titlebarDirBasename.isEmpty {
                if !titlebarGitBranch.isEmpty {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(titlebarColor(opacity: 0.4))
                }
                Text(titlebarDirBasename)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(titlebarColor(opacity: 0.6))
            }
        }
        .lineLimit(1)
    }

    private var titlebarInfoSeparator: some View {
        Text("|")
            .font(.system(size: 10))
            .foregroundColor(titlebarColor(opacity: 0.15))
    }

    private var titlebarRightInfo: some View {
        HStack(spacing: 8) {
            Button(action: {
                if let workspace = tabManager.selectedWorkspace {
                    ContentView.showWorkspaceTagPrompt(for: workspace)
                }
            }) {
                if let tag = titlebarTag, !tag.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9))
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.yellow.opacity(0.8))
                } else {
                    Image(systemName: "bookmark")
                        .font(.system(size: 9))
                        .foregroundColor(titlebarColor(opacity: 0.3))
                }
            }
            .buttonStyle(.plain)
            .help(titlebarTag != nil ? "Edit Tag" : "Set Tag")

            if !titlebarPorts.isEmpty {
                titlebarInfoSeparator
                HStack(spacing: 3) {
                    Image(systemName: "network")
                        .font(.system(size: 9))
                    Text(verbatim: titlebarPorts.prefix(3).map { ":\($0)" }.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.cyan.opacity(0.8))
            }

            if let port = titlebarDashboardPort {
                titlebarInfoSeparator
                let host = daemonService?.isLocalhostOnly ?? true ? "localhost" : "0.0.0.0"
                Button(action: {
                    if let url = URL(string: "http://localhost:\(port)") {
                        _ = tabManager.createBrowserSplit(direction: .right, url: url)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 9))
                        Text(verbatim: "\(host):\(port)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(titlebarColor(opacity: 0.45))
                }
                .buttonStyle(.plain)
                .help("Open Dashboard")
            }

            if titlebarWorktreeCount > 0 {
                titlebarInfoSeparator
                Button(action: {
                    guard let workspace = tabManager.selectedWorkspace else { return }
                    let dir = workspace.currentDirectory
                    let daemon = self.daemonService
                    DispatchQueue.global(qos: .userInitiated).async {
                        guard let repoPath = daemon?.findGitRoot(from: dir), !repoPath.isEmpty else {
                            DispatchQueue.main.async { NSSound.beep() }
                            return
                        }
                        let worktrees = daemon?.listWorktrees(repoPath: repoPath) ?? []
                        DispatchQueue.main.async {
                            Self.showWorktreeManager(worktrees: worktrees, repoPath: repoPath)
                        }
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text(verbatim: "\(titlebarWorktreeCount)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(.green.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Manage Worktrees")
            }

            // Zoom indicator
            if tabManager.selectedWorkspace?.isPaneZoomed == true {
                titlebarInfoSeparator
                Button(action: {
                    tabManager.toggleFocusedPaneZoom()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("ZOOM")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.orange.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("Exit zoom (⇧⌘↩)")
            }

            // Theme toggle (sun/moon)
            titlebarInfoSeparator
            Button(action: {
                let isDark = Self.isEffectivelyDark(appearanceMode)
                appearanceMode = isDark ? AppearanceMode.light.rawValue : AppearanceMode.dark.rawValue
            }) {
                Image(systemName: Self.isEffectivelyDark(appearanceMode) ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Self.isEffectivelyDark(appearanceMode) ? .yellow.opacity(0.8) : .indigo.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(Self.isEffectivelyDark(appearanceMode) ? "Switch to light theme" : "Switch to dark theme")

            if let start = titlebarSessionStart {
                titlebarInfoSeparator
                Text(Self.formatDuration(since: start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(titlebarColor(opacity: 0.5))
            }

            titlebarInfoSeparator
            Text(Self.appVersion)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(titlebarColor(opacity: 0.4))
        }
        .lineLimit(1)
    }

    private static let appVersion: String = {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(ver)"
    }()

    private static func isEffectivelyDark(_ rawMode: String) -> Bool {
        let mode = AppearanceMode(rawValue: rawMode) ?? .system
        switch mode {
        case .dark: return true
        case .light: return false
        case .system, .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    @MainActor
    static func showWorkspaceTagPrompt(for target: Workspace) {
        let alert = NSAlert()
        alert.messageText = "Set Workspace Tag"
        alert.informativeText = "Enter a short tag or bookmark label for this workspace."
        let input = NSTextField(string: target.tag ?? "")
        input.placeholderString = "e.g. debug, prod, test"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Set Tag")
        alert.addButton(withTitle: "Cancel")
        if target.tag != nil {
            alert.addButton(withTitle: "Clear")
        }
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            target.tag = value.isEmpty ? nil : value
        } else if response == .alertThirdButtonReturn {
            target.tag = nil
        }
    }

    private func createWorktreeWorkspace() {
        let daemon = TermMeshDaemon.shared
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let dir = workspace.currentDirectory
        DispatchQueue.global(qos: .userInitiated).async { [tabManager] in
            let repoPath = daemon.findGitRoot(from: dir) ?? ""
            guard !repoPath.isEmpty else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Not a Git Repository"
                    alert.informativeText = "Current directory (\(dir)) is not inside a git repository."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return
            }
            let branches = daemon.listBranches(repoPath: repoPath)
            DispatchQueue.main.async {
                Self.showWorktreeCreationSheet(
                    repoPath: repoPath,
                    branches: branches,
                    tabManager: tabManager
                )
            }
        }
    }

    @MainActor
    private static func showWorktreeCreationSheet(
        repoPath: String,
        branches: [String],
        tabManager: TabManager
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "New Worktree Workspace"
        panel.isFloatingPanel = true

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))

        // Base branch label + popup
        let branchLabel = NSTextField(labelWithString: "Base branch:")
        branchLabel.frame = NSRect(x: 20, y: 112, width: 100, height: 20)
        branchLabel.font = .systemFont(ofSize: 13)
        contentView.addSubview(branchLabel)

        let branchPopup = NSPopUpButton(frame: NSRect(x: 130, y: 108, width: 270, height: 28))
        let branchList = branches.isEmpty ? ["main"] : branches
        branchPopup.addItems(withTitles: branchList)
        if let mainIdx = branchList.firstIndex(of: "main") {
            branchPopup.selectItem(at: mainIdx)
        } else if let masterIdx = branchList.firstIndex(of: "master") {
            branchPopup.selectItem(at: masterIdx)
        }
        contentView.addSubview(branchPopup)

        // Worktree name label + field
        let nameLabel = NSTextField(labelWithString: "Worktree name:")
        nameLabel.frame = NSRect(x: 20, y: 72, width: 110, height: 20)
        nameLabel.font = .systemFont(ofSize: 13)
        contentView.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 130, y: 68, width: 270, height: 28))
        nameField.placeholderString = "optional (e.g. fix-login-bug)"
        contentView.addSubview(nameField)

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.frame = NSRect(x: 220, y: 16, width: 80, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)

        let createButton = NSButton(title: "Create", target: nil, action: nil)
        createButton.frame = NSRect(x: 310, y: 16, width: 90, height: 32)
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        contentView.addSubview(createButton)

        // Repo info
        let repoName = (repoPath as NSString).lastPathComponent
        let repoLabel = NSTextField(labelWithString: "Repository: \(repoName)")
        repoLabel.frame = NSRect(x: 20, y: 20, width: 190, height: 16)
        repoLabel.font = .systemFont(ofSize: 11)
        repoLabel.textColor = .secondaryLabelColor
        contentView.addSubview(repoLabel)

        panel.contentView = contentView
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        let handler = WorktreeCreationHandler(
            panel: panel,
            branchPopup: branchPopup,
            nameField: nameField,
            repoPath: repoPath,
            tabManager: tabManager
        )
        objc_setAssociatedObject(panel, &WorktreeAssocKeys.creationHandler, handler, .OBJC_ASSOCIATION_RETAIN)

        cancelButton.target = handler
        cancelButton.action = #selector(WorktreeCreationHandler.cancel(_:))
        createButton.target = handler
        createButton.action = #selector(WorktreeCreationHandler.create(_:))
    }

    @MainActor
    static func showWorktreeManager(worktrees: [WorktreeInfo], repoPath: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Worktrees (\(worktrees.count))"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 400, height: 250)

        if worktrees.isEmpty {
            let label = NSTextField(labelWithString: "No active worktrees.")
            label.font = .systemFont(ofSize: 14)
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
            label.autoresizingMask = [.width, .height]
            panel.contentView = label
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        contentView.autoresizingMask = [.width, .height]

        // Table data source
        let dataSource = WorktreeTableDataSource(worktrees: worktrees, repoPath: repoPath)

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 50, width: 488, height: 334))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let tableView = NSTableView()
        tableView.style = .fullWidth
        tableView.rowHeight = 52
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let actionWidth: CGFloat = 130
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Worktree"
        nameCol.width = scrollView.frame.width - actionWidth
        nameCol.resizingMask = .autoresizingMask
        tableView.addTableColumn(nameCol)

        let actionCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionCol.title = ""
        actionCol.width = actionWidth
        actionCol.maxWidth = actionWidth
        actionCol.minWidth = actionWidth
        actionCol.resizingMask = []
        tableView.addTableColumn(actionCol)

        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // Bottom bar: Cleanup All + Close
        let closeButton = NSButton(title: "Close", target: nil, action: #selector(NSPanel.close))
        closeButton.frame = NSRect(x: 520 - 16 - 80, y: 12, width: 80, height: 28)
        closeButton.autoresizingMask = [.minXMargin]
        closeButton.bezelStyle = .rounded
        closeButton.target = panel
        contentView.addSubview(closeButton)

        let cleanupButton = NSButton(title: "Cleanup Stale", target: dataSource, action: #selector(WorktreeTableDataSource.cleanupStale(_:)))
        cleanupButton.frame = NSRect(x: 16, y: 12, width: 120, height: 28)
        cleanupButton.bezelStyle = .rounded
        contentView.addSubview(cleanupButton)

        // Store dataSource so it's retained
        dataSource.tableView = tableView
        dataSource.panel = panel
        objc_setAssociatedObject(panel, &WorktreeAssocKeys.dataSource, dataSource, .OBJC_ASSOCIATION_RETAIN)

        panel.contentView = contentView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private static func formatDuration(since start: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(start))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        return "\(h)h \(m)m"
    }

    private func updateTitlebarText() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            if !titlebarText.isEmpty { titlebarText = "" }
            if !titlebarGitBranch.isEmpty { titlebarGitBranch = "" }
            if !titlebarWorktreeName.isEmpty { titlebarWorktreeName = "" }
            if titlebarIsWorktree { titlebarIsWorktree = false }
            if !titlebarDirBasename.isEmpty { titlebarDirBasename = "" }
            if !titlebarPorts.isEmpty { titlebarPorts = [] }
            if titlebarSessionStart != nil { titlebarSessionStart = nil }
            if titlebarTag != nil { titlebarTag = nil }
            return
        }
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if titlebarText != title {
            titlebarText = title
        }
        // Git branch — prefer focused panel's reported branch; fall back to git query
        let focusedPanelId = tab.focusedPanelId
        let branchState = tab.gitBranch
        let focusedDir = focusedPanelId.flatMap { tab.panelDirectories[$0] } ?? tab.currentDirectory
        let focusedTTY: String? = focusedPanelId.flatMap { tab.surfaceTTYNames[$0] }
        let hasPanelDir = focusedPanelId != nil && tab.panelDirectories[focusedPanelId!] != nil
        #if DEBUG
        dlog("titlebar.update focusedPanel=\(focusedPanelId?.uuidString.prefix(8) ?? "nil") gitBranch=\(branchState?.branch ?? "nil") panelBranches=\(tab.panelGitBranches.mapValues { $0.branch }) currentDir=\(tab.currentDirectory) focusedDir=\(focusedDir) tty=\(focusedTTY ?? "nil") hasPanelDir=\(hasPanelDir) worktreeName=\(tab.worktreeName ?? "nil")")
        #endif
        if let bs = branchState {
            let branch = bs.branch
            if titlebarGitBranch != branch { titlebarGitBranch = branch }
            let dirty = bs.isDirty
            if titlebarGitDirty != dirty { titlebarGitDirty = dirty }
            let dirtyCount = bs.dirtyFileCount ?? 0
            if titlebarGitDirtyCount != dirtyCount { titlebarGitDirtyCount = dirtyCount }
            if titlebarIsWorktree { titlebarIsWorktree = false }
        } else {
            // Fallback: resolve CWD from TTY if panelDirectories has no entry, then run git
            let resolveDir = focusedDir
            let needsTTYResolve = !hasPanelDir && focusedTTY != nil
            let ttyForResolve = focusedTTY
            DispatchQueue.global(qos: .utility).async {
                let dir: String
                if needsTTYResolve, let tty = ttyForResolve,
                   let ttyCwd = Self.queryCWDFromTTY(tty), !ttyCwd.isEmpty {
                    dir = ttyCwd
                } else {
                    dir = resolveDir
                }
                guard !dir.isEmpty else { return }
                let (branch, dirty, count, isWt) = Self.queryGitBranch(in: dir)
                #if DEBUG
                dlog("titlebar.gitFallback dir=\(dir) branch=\(branch) dirty=\(dirty) count=\(count) isWorktree=\(isWt) viaTTY=\(needsTTYResolve)")
                #endif
                DispatchQueue.main.async {
                    if self.titlebarGitBranch != branch { self.titlebarGitBranch = branch }
                    if self.titlebarGitDirty != dirty { self.titlebarGitDirty = dirty }
                    if self.titlebarGitDirtyCount != count { self.titlebarGitDirtyCount = count }
                    if self.titlebarIsWorktree != isWt { self.titlebarIsWorktree = isWt }
                }
            }
        }
        // Worktree name — show user-friendly name from customTitle, not internal name
        let hasWorktree = (tab.worktreeName != nil && !tab.worktreeName!.isEmpty)
            || tab.isInsideWorktree
        let wtName: String
        if hasWorktree {
            if let customTitle = tab.customTitle, !customTitle.isEmpty {
                wtName = customTitle
            } else if let rawWtName = tab.worktreeName, !rawWtName.isEmpty {
                wtName = rawWtName
            } else {
                // Fallback: derive from directory
                wtName = "worktree"
            }
        } else {
            wtName = ""
        }
        if titlebarWorktreeName != wtName { titlebarWorktreeName = wtName }

        // Directory basename — skip when the workspace is a worktree (dirname is internal and redundant)
        let rawDirBase = (tab.currentDirectory as NSString).lastPathComponent
        let dirBase = hasWorktree ? "" : rawDirBase
        if titlebarDirBasename != dirBase { titlebarDirBasename = dirBase }

        // Listening ports
        let ports = tab.listeningPorts
        if titlebarPorts != ports { titlebarPorts = ports }

        // Session time
        if titlebarSessionStart != tab.createdAt { titlebarSessionStart = tab.createdAt }

        // Tag
        if titlebarTag != tab.tag { titlebarTag = tab.tag }

        // Dashboard port
        let dashPort: Int? = daemonService?.isDashboardEnabled == true ? daemonService?.dashboardPort : nil
        if titlebarDashboardPort != dashPort { titlebarDashboardPort = dashPort }

        // Worktree count
        let daemon = self.daemonService
        DispatchQueue.global(qos: .utility).async {
            let currentDir = tab.currentDirectory
            if let repoPath = daemon?.findGitRoot(from: currentDir), !repoPath.isEmpty {
                let count = daemon?.listWorktrees(repoPath: repoPath).count ?? 0
                DispatchQueue.main.async {
                    if self.titlebarWorktreeCount != count { self.titlebarWorktreeCount = count }
                }
            }
        }
    }

    private static func queryGitBranch(in directory: String) -> (branch: String, dirty: Bool, dirtyCount: Int, isWorktree: Bool) {
        let branchProcess = Process()
        branchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        branchProcess.arguments = ["branch", "--show-current"]
        branchProcess.currentDirectoryURL = URL(fileURLWithPath: directory)
        let branchPipe = Pipe()
        branchProcess.standardOutput = branchPipe
        branchProcess.standardError = Pipe()
        do {
            try branchProcess.run()
            branchProcess.waitUntilExit()
        } catch { return ("", false, 0, false) }
        guard branchProcess.terminationStatus == 0 else { return ("", false, 0, false) }
        let branchData = branchPipe.fileHandleForReading.readDataToEndOfFile()
        let branch = String(data: branchData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !branch.isEmpty else { return ("", false, 0, false) }

        let statusProcess = Process()
        statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        statusProcess.arguments = ["status", "--porcelain", "--short"]
        statusProcess.currentDirectoryURL = URL(fileURLWithPath: directory)
        let statusPipe = Pipe()
        statusProcess.standardOutput = statusPipe
        statusProcess.standardError = Pipe()
        do {
            try statusProcess.run()
            statusProcess.waitUntilExit()
        } catch { return (branch, false, 0, false) }
        let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
        let statusOutput = String(data: statusData, encoding: .utf8) ?? ""
        let changedFiles = statusOutput.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Detect worktree: git-dir != git-common-dir means we're in a worktree
        var isWorktree = false
        let gitDirProcess = Process()
        gitDirProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitDirProcess.arguments = ["rev-parse", "--git-dir", "--git-common-dir"]
        gitDirProcess.currentDirectoryURL = URL(fileURLWithPath: directory)
        let gitDirPipe = Pipe()
        gitDirProcess.standardOutput = gitDirPipe
        gitDirProcess.standardError = FileHandle.nullDevice
        do {
            try gitDirProcess.run()
            gitDirProcess.waitUntilExit()
            let gitDirData = gitDirPipe.fileHandleForReading.readDataToEndOfFile()
            let lines = (String(data: gitDirData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            if lines.count >= 2 {
                let gitDir = lines[0].trimmingCharacters(in: .whitespaces)
                let commonDir = lines[1].trimmingCharacters(in: .whitespaces)
                isWorktree = gitDir != commonDir
            }
        } catch {}

        return (branch, !changedFiles.isEmpty, changedFiles.count, isWorktree)
    }

    /// Resolve the CWD of the foreground process on a given TTY.
    /// Runs `ps` to find PIDs, then `lsof` to get the CWD of the last (deepest) process.
    private static func queryCWDFromTTY(_ tty: String) -> String? {
        // 1. Get all PIDs on this TTY
        let psProcess = Process()
        psProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
        psProcess.arguments = ["-t", tty, "-o", "pid="]
        let psPipe = Pipe()
        psProcess.standardOutput = psPipe
        psProcess.standardError = FileHandle.nullDevice
        do { try psProcess.run(); psProcess.waitUntilExit() } catch { return nil }
        let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
        let psOutput = String(data: psData, encoding: .utf8) ?? ""
        let pids = psOutput.split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return nil }

        // 2. Get CWD of all PIDs via lsof, take the last one (deepest child)
        let pidsCsv = pids.map(String.init).joined(separator: ",")
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-a", "-d", "cwd", "-p", pidsCsv, "-Fn"]
        let lsofPipe = Pipe()
        lsofProcess.standardOutput = lsofPipe
        lsofProcess.standardError = FileHandle.nullDevice
        do { try lsofProcess.run(); lsofProcess.waitUntilExit() } catch { return nil }
        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        let lsofOutput = String(data: lsofData, encoding: .utf8) ?? ""

        // Parse lsof -Fn: lines starting with 'n' contain the path
        var lastCwd: String?
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("n") {
                lastCwd = String(line.dropFirst())
            }
        }
        return lastCwd
    }

    private func scheduleTitlebarTextRefresh() {
        titlebarTextUpdateCoalescer.signal {
            updateTitlebarText()
        }
    }

    private func scheduleTitlebarThemeRefresh(
        reason: String,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousGeneration = titlebarThemeGeneration
        titlebarThemeGeneration &+= 1
        configProvider?.logBackgroundIfEnabled(
            "titlebar theme refresh scheduled reason=\(reason) event=\(backgroundEventId.map(String.init) ?? "nil") source=\(backgroundSource ?? "nil") payload=\(notificationPayloadHex ?? "nil") previousGeneration=\(previousGeneration) generation=\(titlebarThemeGeneration) appBg=\(configProvider?.defaultBackgroundColor.hexString() ?? "nil") appOpacity=\(String(format: "%.3f", configProvider?.defaultBackgroundOpacity ?? 0))"
        )
    }

    private func scheduleTitlebarThemeRefreshFromWorkspace(
        workspaceId: UUID,
        reason: String,
        backgroundEventId: UInt64?,
        backgroundSource: String?,
        notificationPayloadHex: String?
    ) {
        guard tabManager.selectedTabId == workspaceId else {
            configProvider?.logBackgroundIfEnabled(
                "titlebar theme refresh skipped workspace=\(workspaceId.uuidString) selected=\(tabManager.selectedTabId?.uuidString ?? "nil") reason=\(reason)"
            )
            return
        }

        scheduleTitlebarThemeRefresh(
            reason: reason,
            backgroundEventId: backgroundEventId,
            backgroundSource: backgroundSource,
            notificationPayloadHex: notificationPayloadHex
        )
    }

    private var focusedDirectory: String? {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return nil
        }
        // Use focused panel's directory if available
        if let focusedPanelId = tab.focusedPanelId,
           let panelDir = tab.panelDirectories[focusedPanelId] {
            let trimmed = panelDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    private var contentAndSidebarLayout: AnyView {
        let layout: AnyView
        if sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue {
            // Overlay mode: terminal extends full width, sidebar on top
            // This allows withinWindow blur to see the terminal content
            layout = AnyView(
                ZStack(alignment: .leading) {
                    terminalContentWithSidebarDropOverlay
                        .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
                    if sidebarState.isVisible {
                        sidebarView
                    }
                }
            )
        } else {
            // Standard HStack mode for behindWindow blur
            layout = AnyView(
                HStack(spacing: 0) {
                    if sidebarState.isVisible {
                        sidebarView
                    }
                    terminalContentWithSidebarDropOverlay
                }
            )
        }

        return AnyView(
            layout
                .overlay(alignment: .leading) {
                    if sidebarState.isVisible {
                        sidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
        )
    }

    var body: some View {
        var view = AnyView(
            VStack(spacing: 0) {
                contentAndSidebarLayout
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(alignment: .topLeading) {
                        if isFullScreen && sidebarState.isVisible {
                            fullscreenControls
                                .padding(.leading, 10)
                                .padding(.top, 4)
                        }
                    }
                // Status bar removed — version now shown in titlebar right info.
            }
            .frame(minWidth: 800, minHeight: 600)
                .background(Color.clear)
                .sheet(isPresented: Binding(
                    get: { !hideWelcomeScreen },
                    set: { if !$0 { hideWelcomeScreen = true } }
                )) {
                    WelcomeView(onGetStarted: {
                        hideWelcomeScreen = true
                    })
                    .frame(width: 560, height: 560)
                }
        )

        view = AnyView(view.onAppear {
            tabManager.applyWindowBackgroundForSelectedTab()
            reconcileMountedWorkspaceIds()
            previousSelectedWorkspaceId = tabManager.selectedTabId
            installSidebarResizerPointerMonitorIfNeeded()
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
            }
            updateTitlebarText()
        })

        view = AnyView(view.onChange(of: tabManager.selectedTabId) { newValue in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.view.selectedChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newValue))"
                )
            } else {
                dlog("ws.view.selectedChange id=none selected=\(debugShortWorkspaceId(newValue))")
            }
#endif
            tabManager.applyWindowBackgroundForSelectedTab()
            startWorkspaceHandoffIfNeeded(newSelectedId: newValue)
            reconcileMountedWorkspaceIds(selectedId: newValue)
            guard let newValue else { return }
            if selectedTabIds.count <= 1 {
                selectedTabIds = [newValue]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == newValue }
            }
            updateTitlebarText()
        })

        view = AnyView(view.onChange(of: tabManager.isWorkspaceCycleHot) { _ in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.view.hotChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)"
                )
            } else {
                dlog("ws.view.hotChange id=none hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)")
            }
#endif
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onChange(of: retiringWorkspaceId) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidSetTitle)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelectionState.selection = .tabs
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "focus")
            scheduleTitlebarTextRefresh()
        })

        // Periodically refresh titlebar git branch + directory (3s interval)
        view = AnyView(view.onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            updateTitlebarText()
        })

        view = AnyView(view.onChange(of: titlebarThemeGeneration) { [configProvider] oldValue, newValue in
            configProvider?.logBackgroundIfEnabled(
                "titlebar theme refresh applied oldGeneration=\(oldValue) generation=\(newValue) appBg=\(configProvider?.defaultBackgroundColor.hexString() ?? "nil") appOpacity=\(String(format: "%.3f", configProvider?.defaultBackgroundOpacity ?? 0))"
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidBecomeFirstResponderSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "first_responder")
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedPanelId = selectedWorkspace.focusedPanelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_first_responder")
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  selectedWorkspace.focusedPanelId == panelId,
                  selectedWorkspace.browserPanel(for: panelId) != nil else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_address_bar")
        })

        view = AnyView(view.onReceive(tabManager.$tabs) { tabs in
            let existingIds = Set(tabs.map { $0.id })
            if let retiringWorkspaceId, !existingIds.contains(retiringWorkspaceId) {
                self.retiringWorkspaceId = nil
                workspaceHandoffFallbackTask?.cancel()
                workspaceHandoffFallbackTask = nil
            }
            if let previousSelectedWorkspaceId, !existingIds.contains(previousSelectedWorkspaceId) {
                self.previousSelectedWorkspaceId = tabManager.selectedTabId
            }
            reconcileMountedWorkspaceIds(tabs: tabs)
            selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
            }
            if let lastIndex = lastSidebarSelectionIndex, lastIndex >= tabs.count {
                if let selectedId = tabManager.selectedTabId {
                    lastSidebarSelectionIndex = tabs.firstIndex { $0.id == selectedId }
                } else {
                    lastSidebarSelectionIndex = nil
                }
            }
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.stateDidChange)) { notification in
            let tabId = SidebarDragLifecycleNotification.tabId(from: notification)
            sidebarDraggedTabId = tabId
#if DEBUG
            dlog(
                "sidebar.dragState.content tab=\(debugShortWorkspaceId(tabId)) " +
                "reason=\(SidebarDragLifecycleNotification.reason(from: notification))"
            )
#endif
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteToggleRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            toggleCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteCommands()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSwitcherRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteSwitcher()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .worktreeWorkspaceRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            createWorktreeWorkspace()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameTabRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenameTabInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteMoveSelection)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .commands = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
            moveCommandPaletteSelection(by: delta)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputInteractionRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteRenameInputInteraction()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputDeleteBackwardRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            _ = handleCommandPaletteRenameDeleteBackward(modifiers: [])
        })

        view = AnyView(view.background(WindowAccessor(dedupeByWindow: false) { window in
            MainActor.assumeIsolated {
                let overlayController = commandPaletteWindowOverlayController(for: window)
                overlayController.update(rootView: AnyView(commandPaletteOverlay), isVisible: isCommandPalettePresented)
            }
        }))

        view = AnyView(view.onChange(of: bgGlassTintHex) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onChange(of: bgGlassTintOpacity) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = true
            setTitlebarControlsHidden(true, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = fullscreenControlsViewModel
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = false
            setTitlebarControlsHidden(false, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = nil
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            clampSidebarWidthIfNeeded(availableWidth: window.contentView?.bounds.width ?? window.contentLayoutRect.width)
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarWidth) { _ in
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarState.isVisible) { _ in
            updateSidebarResizerBandState()
        })

        view = AnyView(view.ignoresSafeArea())

        view = AnyView(view.onDisappear {
            removeSidebarResizerPointerMonitor()
        })

        view = AnyView(view.background(WindowAccessor { [sidebarBlendMode, bgGlassEnabled, bgGlassTintHex, bgGlassTintOpacity] window in
            window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
            window.titlebarAppearsTransparent = true
            // Do not make the entire background draggable; it interferes with drag gestures
            // like sidebar tab reordering in multi-window mode.
            window.isMovableByWindowBackground = false
            // Let the system titlebar handle window dragging (Warp-style flush layout).
            window.isMovable = true
            window.styleMask.insert(.fullSizeContentView)

            // Track this window for fullscreen notifications
            if observedWindow !== window {
                DispatchQueue.main.async {
                    observedWindow = window
                    isFullScreen = window.styleMask.contains(.fullScreen)
                    clampSidebarWidthIfNeeded(availableWidth: window.contentView?.bounds.width ?? window.contentLayoutRect.width)
                    syncCommandPaletteDebugStateForObservedWindow()
                    installSidebarResizerPointerMonitorIfNeeded()
                    updateSidebarResizerBandState()
                }
            }

            // Keep content below the titlebar so drags on Bonsplit's tab bar don't
            // get interpreted as window drags.
            let computedTitlebarHeight = window.frame.height - window.contentLayoutRect.height
            let nextPadding = max(28, min(72, computedTitlebarHeight))
            if abs(titlebarPadding - nextPadding) > 0.5 {
                DispatchQueue.main.async {
                    titlebarPadding = nextPadding
                }
            }
#if DEBUG
            if termMeshEnv("UI_TEST_MODE") == "1" {
                UpdateLogStore.shared.append("ui test window accessor: id=\(windowIdentifier) visible=\(window.isVisible)")
            }
#endif
            // Background glass: skip on macOS 26+ where NSGlassEffectView can cause blank
            // or incorrectly tinted SwiftUI content. Keep native window rendering there so
            // Ghostty theme colors remain authoritative.
            if sidebarBlendMode == SidebarBlendModeOption.behindWindow.rawValue
                && bgGlassEnabled
                && !WindowGlassEffect.isAvailable {
                window.isOpaque = false
                window.backgroundColor = .clear
                // Configure contentView and all subviews for transparency
                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    contentView.layer?.backgroundColor = NSColor.clear.cgColor
                    contentView.layer?.isOpaque = false
                    // Make SwiftUI hosting view transparent
                    for subview in contentView.subviews {
                        subview.wantsLayer = true
                        subview.layer?.backgroundColor = NSColor.clear.cgColor
                        subview.layer?.isOpaque = false
                    }
                }
                // Apply liquid glass effect to the window with tint from settings
                let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
                WindowGlassEffect.apply(to: window, tintColor: tintColor)
            }
            AppDelegate.shared?.attachUpdateAccessory(to: window)
            AppDelegate.shared?.applyWindowDecorations(to: window)
            AppDelegate.shared?.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState
            )
            installFileDropOverlay(on: window, tabManager: tabManager)
        }))

        return view
    }

    private func reconcileMountedWorkspaceIds(tabs: [Workspace]? = nil, selectedId: UUID? = nil) {
        let currentTabs = tabs ?? tabManager.tabs
        let orderedTabIds = currentTabs.map { $0.id }
        let effectiveSelectedId = selectedId ?? tabManager.selectedTabId
        let pinnedIds = retiringWorkspaceId.map { Set([ $0 ]) } ?? []
        let isCycleHot = tabManager.isWorkspaceCycleHot
        let shouldKeepHandoffPair = isCycleHot && !pinnedIds.isEmpty
        let baseMaxMounted = shouldKeepHandoffPair
            ? WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
            : WorkspaceMountPolicy.maxMountedWorkspaces
        let selectedCount = effectiveSelectedId == nil ? 0 : 1
        let maxMounted = max(baseMaxMounted, selectedCount + pinnedIds.count)
        let previousMountedIds = mountedWorkspaceIds
        mountedWorkspaceIds = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: mountedWorkspaceIds,
            selected: effectiveSelectedId,
            pinnedIds: pinnedIds,
            orderedTabIds: orderedTabIds,
            isCycleHot: isCycleHot,
            maxMounted: maxMounted
        )
#if DEBUG
        if mountedWorkspaceIds != previousMountedIds {
            let added = mountedWorkspaceIds.filter { !previousMountedIds.contains($0) }
            let removed = previousMountedIds.filter { !mountedWorkspaceIds.contains($0) }
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(debugShortWorkspaceIds(added)) removed=\(debugShortWorkspaceIds(removed))"
                )
            } else {
                dlog(
                    "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds))"
                )
            }
        }
#endif
    }

    private func addTab() {
        tabManager.addTab()
        sidebarSelectionState.selection = .tabs
    }

    private func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        WindowGlassEffect.updateTint(to: window, color: tintColor)
    }

    private func setTitlebarControlsHidden(_ hidden: Bool, in window: NSWindow) {
        let controlsId = NSUserInterfaceItemIdentifier("term-mesh.titlebarControls")
        for accessory in window.titlebarAccessoryViewControllers {
            if accessory.view.identifier == controlsId {
                accessory.isHidden = hidden
                accessory.view.alphaValue = hidden ? 0 : 1
            }
        }
    }

    private func startWorkspaceHandoffIfNeeded(newSelectedId: UUID?) {
        let oldSelectedId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedId

        guard let oldSelectedId, let newSelectedId, oldSelectedId != newSelectedId else {
            tabManager.completePendingWorkspaceUnfocus(reason: "no_handoff")
            retiringWorkspaceId = nil
            workspaceHandoffFallbackTask?.cancel()
            workspaceHandoffFallbackTask = nil
            return
        }

        workspaceHandoffGeneration &+= 1
        let generation = workspaceHandoffGeneration
        retiringWorkspaceId = oldSelectedId
        workspaceHandoffFallbackTask?.cancel()

#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.start id=\(snapshot.id) dt=\(debugMsText(dtMs)) old=\(debugShortWorkspaceId(oldSelectedId)) " +
                "new=\(debugShortWorkspaceId(newSelectedId))"
            )
        } else {
            dlog(
                "ws.handoff.start id=none old=\(debugShortWorkspaceId(oldSelectedId)) new=\(debugShortWorkspaceId(newSelectedId))"
            )
        }
#endif

        workspaceHandoffFallbackTask = Task { [generation] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard workspaceHandoffGeneration == generation else { return }
                completeWorkspaceHandoff(reason: "timeout")
            }
        }
    }

    private func completeWorkspaceHandoffIfNeeded(focusedTabId: UUID, reason: String) {
        guard focusedTabId == tabManager.selectedTabId else { return }
        guard retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
        let retiring = retiringWorkspaceId

        // Hide terminal portal views for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // (to avoid blackouts during transient bonsplit dismantles). Hiding here
        // prevents stale portal-hosted terminals from covering browser panes.
        if let retiring, let workspace = tabManager.tabs.first(where: { $0.id == retiring }) {
            workspace.hideAllTerminalPortalViews()
        }

        retiringWorkspaceId = nil
        tabManager.completePendingWorkspaceUnfocus(reason: reason)
#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.complete id=\(snapshot.id) dt=\(debugMsText(dtMs)) reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))"
            )
        } else {
            dlog("ws.handoff.complete id=none reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))")
        }
#endif
    }

    private var commandPaletteOverlay: some View {
        GeometryReader { proxy in
            let maxAllowedWidth = max(340, proxy.size.width - 260)
            let targetWidth = min(560, maxAllowedWidth)

            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissCommandPalette()
                    }

                VStack(spacing: 0) {
                    switch commandPaletteMode {
                    case .commands:
                        commandPaletteCommandListView
                    case .renameInput(let target):
                        commandPaletteRenameInputView(target: target)
                    case let .renameConfirm(target, proposedName):
                        commandPaletteRenameConfirmView(target: target, proposedName: proposedName)
                    }
                }
                .frame(width: targetWidth)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 5)
                .padding(.top, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand {
            dismissCommandPalette()
        }
        .zIndex(2000)
    }

    private var commandPaletteCommandListView: some View {
        let visibleResults = Array(commandPaletteResults)
        let selectedIndex = commandPaletteSelectedIndex(resultCount: visibleResults.count)
        let commandPaletteListMaxHeight: CGFloat = 450
        let commandPaletteRowHeight: CGFloat = 24
        let commandPaletteEmptyStateHeight: CGFloat = 44
        let commandPaletteListContentHeight = visibleResults.isEmpty
            ? commandPaletteEmptyStateHeight
            : CGFloat(visibleResults.count) * commandPaletteRowHeight
        let commandPaletteListHeight = min(commandPaletteListMaxHeight, commandPaletteListContentHeight)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(commandPaletteSearchPlaceholder, text: $commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular))
                    .tint(.white)
                    .focused($isCommandPaletteSearchFocused)
                    .onSubmit {
                        runSelectedCommandPaletteResult(visibleResults: visibleResults)
                    }
                    .backport.onKeyPress(.downArrow) { _ in
                        moveCommandPaletteSelection(by: 1)
                        return .handled
                    }
                    .backport.onKeyPress(.upArrow) { _ in
                        moveCommandPaletteSelection(by: -1)
                        return .handled
                    }
                    .backport.onKeyPress("n") { modifiers in
                        handleCommandPaletteControlNavigationKey(modifiers: modifiers, delta: 1)
                    }
                    .backport.onKeyPress("p") { modifiers in
                        handleCommandPaletteControlNavigationKey(modifiers: modifiers, delta: -1)
                    }
                    .backport.onKeyPress("j") { modifiers in
                        handleCommandPaletteControlNavigationKey(modifiers: modifiers, delta: 1)
                    }
                    .backport.onKeyPress("k") { modifiers in
                        handleCommandPaletteControlNavigationKey(modifiers: modifiers, delta: -1)
                    }

            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if visibleResults.isEmpty {
                        Text(commandPaletteEmptyStateText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
                            let isSelected = index == selectedIndex
                            let isHovered = commandPaletteHoveredResultIndex == index
                            let rowBackground: Color = isSelected
                                ? Color.accentColor.opacity(0.12)
                                : (isHovered ? Color.primary.opacity(0.08) : .clear)

                            Button {
                                runCommandPaletteCommand(result.command)
                            } label: {
                                HStack(spacing: 8) {
                                    commandPaletteHighlightedTitleText(
                                        result.command.title,
                                        matchedIndices: result.titleMatchIndices
                                    )
                                        .font(.system(size: 13, weight: .regular))
                                        .lineLimit(1)
                                    Spacer()

                                    if let trailingLabel = commandPaletteTrailingLabel(for: result.command) {
                                        switch trailingLabel.style {
                                        case .shortcut:
                                            Text(trailingLabel.text)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        case .kind:
                                            Text(trailingLabel.text)
                                                .font(.system(size: 11, weight: .regular))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(rowBackground)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .onHover { hovering in
                                if hovering {
                                    commandPaletteHoveredResultIndex = index
                                } else if commandPaletteHoveredResultIndex == index {
                                    commandPaletteHoveredResultIndex = nil
                                }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                // Force a fresh row tree per query so rendered labels/actions stay in lockstep.
                .id(commandPaletteQuery)
            }
            .frame(height: commandPaletteListHeight)
            .scrollPosition(
                id: Binding(
                    get: { commandPaletteScrollTargetIndex },
                    // Ignore passive readback so manual scrolling doesn't mutate selection-follow state.
                    set: { _ in }
                ),
                anchor: commandPaletteScrollTargetAnchor
            )
            .onChange(of: commandPaletteSelectedResultIndex) { _ in
                updateCommandPaletteScrollTarget(resultCount: visibleResults.count, animated: true)
            }

            // Keep Esc-to-close behavior without showing footer controls.
            Button(action: { dismissCommandPalette() }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            commandPaletteHoveredResultIndex = nil
            updateCommandPaletteScrollTarget(resultCount: visibleResults.count, animated: false)
            resetCommandPaletteSearchFocus()
        }
        .onChange(of: commandPaletteQuery) { _ in
            commandPaletteSelectedResultIndex = 0
            commandPaletteHoveredResultIndex = nil
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: visibleResults.count) { _ in
            commandPaletteSelectedResultIndex = commandPaletteSelectedIndex(resultCount: visibleResults.count)
            updateCommandPaletteScrollTarget(resultCount: visibleResults.count, animated: false)
            if let hoveredIndex = commandPaletteHoveredResultIndex, hoveredIndex >= visibleResults.count {
                commandPaletteHoveredResultIndex = nil
            }
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteSelectedResultIndex) { _ in
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

    private func commandPaletteRenameInputView(target: CommandPaletteRenameTarget) -> some View {
        VStack(spacing: 0) {
            TextField(target.placeholder, text: $commandPaletteRenameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .tint(.white)
                .focused($isCommandPaletteRenameFocused)
                .backport.onKeyPress(.delete) { modifiers in
                    handleCommandPaletteRenameDeleteBackward(modifiers: modifiers)
                }
                .onSubmit {
                    continueRenameFlow(target: target)
                }
                .onTapGesture {
                    handleCommandPaletteRenameInputInteraction()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text("Enter a \(renameTargetNoun(target)) name. Press Enter to rename, Escape to cancel.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                continueRenameFlow(target: target)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            resetCommandPaletteRenameFocus()
        }
    }

    private func commandPaletteRenameConfirmView(
        target: CommandPaletteRenameTarget,
        proposedName: String
    ) -> some View {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmedName.isEmpty ? "(clear custom name)" : trimmedName

        return VStack(spacing: 0) {
            Text(nextName)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text("Press Enter to apply this \(renameTargetNoun(target)) name, or Escape to cancel.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                applyRenameFlow(target: target, proposedName: proposedName)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func renameTargetNoun(_ target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return "workspace"
        case .tab:
            return "tab"
        }
    }

    private var commandPaletteListScope: CommandPaletteListScope {
        if commandPaletteQuery.hasPrefix(Self.commandPaletteCommandsPrefix) {
            return .commands
        }
        return .switcher
    }

    private var commandPaletteSearchPlaceholder: String {
        switch commandPaletteListScope {
        case .commands:
            return "Type a command"
        case .switcher:
            return "Search workspaces and tabs"
        }
    }

    private var commandPaletteEmptyStateText: String {
        switch commandPaletteListScope {
        case .commands:
            return "No commands match your search."
        case .switcher:
            return "No workspaces or tabs match your search."
        }
    }

    private var commandPaletteQueryForMatching: String {
        switch commandPaletteListScope {
        case .commands:
            let suffix = String(commandPaletteQuery.dropFirst(Self.commandPaletteCommandsPrefix.count))
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        case .switcher:
            return commandPaletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var commandPaletteEntries: [CommandPaletteCommand] {
        switch commandPaletteListScope {
        case .commands:
            return commandPaletteCommands()
        case .switcher:
            return commandPaletteSwitcherEntries()
        }
    }

    private var commandPaletteResults: [CommandPaletteSearchResult] {
        let entries = commandPaletteEntries
        let query = commandPaletteQueryForMatching
        let queryIsEmpty = query.isEmpty

        let results: [CommandPaletteSearchResult] = queryIsEmpty
            ? entries.map { entry in
                CommandPaletteSearchResult(
                    command: entry,
                    score: commandPaletteHistoryBoost(for: entry.id, queryIsEmpty: true),
                    titleMatchIndices: []
                )
            }
            : entries.compactMap { entry in
                guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(query: query, candidates: entry.searchableTexts) else {
                    return nil
                }
                return CommandPaletteSearchResult(
                    command: entry,
                    score: fuzzyScore + commandPaletteHistoryBoost(for: entry.id, queryIsEmpty: false),
                    titleMatchIndices: CommandPaletteFuzzyMatcher.matchCharacterIndices(
                        query: query,
                        candidate: entry.title
                    )
                )
            }

        return results
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.command.rank != rhs.command.rank { return lhs.command.rank < rhs.command.rank }
                return lhs.command.title.localizedCaseInsensitiveCompare(rhs.command.title) == .orderedAscending
            }
    }

    private func commandPaletteHighlightedTitleText(_ title: String, matchedIndices: Set<Int>) -> Text {
        guard !matchedIndices.isEmpty else {
            return Text(title).foregroundColor(.primary)
        }

        let chars = Array(title)
        var index = 0
        var result = Text("")

        while index < chars.count {
            let isMatched = matchedIndices.contains(index)
            var end = index + 1
            while end < chars.count, matchedIndices.contains(end) == isMatched {
                end += 1
            }

            let segment = String(chars[index..<end])
            if isMatched {
                result = result + Text(segment).foregroundColor(.blue)
            } else {
                result = result + Text(segment).foregroundColor(.primary)
            }
            index = end
        }

        return result
    }

    private func commandPaletteTrailingLabel(for command: CommandPaletteCommand) -> CommandPaletteTrailingLabel? {
        if let shortcutHint = command.shortcutHint {
            return CommandPaletteTrailingLabel(text: shortcutHint, style: .shortcut)
        }

        guard commandPaletteListScope == .switcher else { return nil }
        if command.id.hasPrefix("switcher.workspace.") {
            return CommandPaletteTrailingLabel(text: "Workspace", style: .kind)
        }
        if command.id.hasPrefix("switcher.surface.") {
            return CommandPaletteTrailingLabel(text: "Surface", style: .kind)
        }
        return nil
    }

    private func commandPaletteSwitcherEntries() -> [CommandPaletteCommand] {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        guard !windowContexts.isEmpty else { return [] }

        var entries: [CommandPaletteCommand] = []
        let estimatedCount = windowContexts.reduce(0) { partial, context in
            partial + max(1, context.tabManager.tabs.count) * 4
        }
        entries.reserveCapacity(estimatedCount)
        var nextRank = 0

        for context in windowContexts {
            var workspaces = context.tabManager.tabs
            guard !workspaces.isEmpty else { continue }

            let selectedWorkspaceId = context.selectedWorkspaceId ?? context.tabManager.selectedTabId
            if let selectedWorkspaceId,
               let selectedIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceId }) {
                let selectedWorkspace = workspaces.remove(at: selectedIndex)
                workspaces.insert(selectedWorkspace, at: 0)
            }

            let windowId = context.windowId
            let windowTabManager = context.tabManager
            let windowKeywords = commandPaletteWindowKeywords(windowLabel: context.windowLabel)
            for workspace in workspaces {
                let workspaceName = workspaceDisplayName(workspace)
                let workspaceCommandId = "switcher.workspace.\(workspace.id.uuidString.lowercased())"
                let workspaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
                    baseKeywords: [
                        "workspace",
                        "switch",
                        "go",
                        "open",
                        workspaceName
                    ] + windowKeywords,
                    metadata: commandPaletteWorkspaceSearchMetadata(for: workspace),
                    detail: .workspace
                )
                let workspaceId = workspace.id
                entries.append(
                    CommandPaletteCommand(
                        id: workspaceCommandId,
                        rank: nextRank,
                        title: workspaceName,
                        subtitle: commandPaletteSwitcherSubtitle(base: "Workspace", windowLabel: context.windowLabel),
                        shortcutHint: nil,
                        keywords: workspaceKeywords,
                        dismissOnRun: true,
                        action: {
                            focusCommandPaletteSwitcherTarget(
                                windowId: windowId,
                                tabManager: windowTabManager,
                                workspaceId: workspaceId,
                                panelId: nil
                            )
                        }
                    )
                )
                nextRank += 1

                var orderedPanelIds = workspace.sidebarOrderedPanelIds()
                if let focusedPanelId = workspace.focusedPanelId,
                   let focusedIndex = orderedPanelIds.firstIndex(of: focusedPanelId) {
                    orderedPanelIds.remove(at: focusedIndex)
                    orderedPanelIds.insert(focusedPanelId, at: 0)
                }

                for panelId in orderedPanelIds {
                    guard let panel = workspace.panels[panelId] else { continue }
                    let panelTitle = panelDisplayName(workspace: workspace, panelId: panelId, fallback: panel.displayTitle)
                    let typeLabel: String = (panel.panelType == .browser) ? "Browser" : "Terminal"
                    let panelKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
                        baseKeywords: [
                            "tab",
                            "surface",
                            "panel",
                            "switch",
                            "go",
                            workspaceName,
                            panelTitle,
                            typeLabel.lowercased()
                        ] + windowKeywords,
                        metadata: commandPalettePanelSearchMetadata(in: workspace, panelId: panelId)
                    )
                    entries.append(
                        CommandPaletteCommand(
                            id: "switcher.surface.\(workspace.id.uuidString.lowercased()).\(panelId.uuidString.lowercased())",
                            rank: nextRank,
                            title: panelTitle,
                            subtitle: commandPaletteSwitcherSubtitle(
                                base: "\(typeLabel) • \(workspaceName)",
                                windowLabel: context.windowLabel
                            ),
                            shortcutHint: nil,
                            keywords: panelKeywords,
                            dismissOnRun: true,
                            action: {
                                focusCommandPaletteSwitcherTarget(
                                    windowId: windowId,
                                    tabManager: windowTabManager,
                                    workspaceId: workspaceId,
                                    panelId: panelId
                                )
                            }
                        )
                    )
                    nextRank += 1
                }
            }
        }

        return entries
    }

    private func commandPaletteSwitcherWindowContexts() -> [CommandPaletteSwitcherWindowContext] {
        let fallback = CommandPaletteSwitcherWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            selectedWorkspaceId: tabManager.selectedTabId,
            windowLabel: nil
        )

        guard let appDelegate = AppDelegate.shared else { return [fallback] }
        let summaries = appDelegate.listMainWindowSummaries()
        guard !summaries.isEmpty else { return [fallback] }

        let orderedSummaries = summaries.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.windowId == windowId
            let rhsIsCurrent = rhs.windowId == windowId
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        var windowLabelById: [UUID: String] = [:]
        if orderedSummaries.count > 1 {
            for (index, summary) in orderedSummaries.enumerated() where summary.windowId != windowId {
                windowLabelById[summary.windowId] = "Window \(index + 1)"
            }
        }

        var contexts: [CommandPaletteSwitcherWindowContext] = []
        var seenWindowIds: Set<UUID> = []
        for summary in orderedSummaries {
            guard let manager = appDelegate.tabManagerFor(windowId: summary.windowId) else { continue }
            guard seenWindowIds.insert(summary.windowId).inserted else { continue }
            contexts.append(
                CommandPaletteSwitcherWindowContext(
                    windowId: summary.windowId,
                    tabManager: manager,
                    selectedWorkspaceId: summary.selectedWorkspaceId,
                    windowLabel: windowLabelById[summary.windowId]
                )
            )
        }

        if contexts.isEmpty {
            return [fallback]
        }
        return contexts
    }

    private func commandPaletteSwitcherSubtitle(base: String, windowLabel: String?) -> String {
        guard let windowLabel else { return base }
        return "\(base) • \(windowLabel)"
    }

    private func commandPaletteWindowKeywords(windowLabel: String?) -> [String] {
        guard let windowLabel else { return [] }
        return ["window", windowLabel.lowercased()]
    }

    private func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID?
    ) {
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        if let panelId {
            tabManager.focusTab(workspaceId, surfaceId: panelId, suppressFlash: true)
        } else {
            tabManager.focusTab(workspaceId, suppressFlash: true)
        }
    }

    private func commandPaletteWorkspaceSearchMetadata(for workspace: Workspace) -> CommandPaletteSwitcherSearchMetadata {
        // Keep workspace rows coarse so surface rows win for directory/branch-specific queries.
        let directories = [workspace.currentDirectory]
        let branches = [workspace.gitBranch?.branch].compactMap { $0 }
        let ports = workspace.listeningPorts
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }

    private func commandPalettePanelSearchMetadata(in workspace: Workspace, panelId: UUID) -> CommandPaletteSwitcherSearchMetadata {
        var directories: [String] = []
        if let directory = workspace.panelDirectories[panelId] {
            directories.append(directory)
        } else if workspace.focusedPanelId == panelId {
            directories.append(workspace.currentDirectory)
        }

        var branches: [String] = []
        if let branch = workspace.panelGitBranches[panelId]?.branch {
            branches.append(branch)
        } else if workspace.focusedPanelId == panelId, let branch = workspace.gitBranch?.branch {
            branches.append(branch)
        }

        var ports = workspace.surfaceListeningPorts[panelId] ?? []
        if ports.isEmpty, workspace.panels.count == 1 {
            ports = workspace.listeningPorts
        }

        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }

    private func commandPaletteCommands() -> [CommandPaletteCommand] {
        let context = commandPaletteContextSnapshot()
        let contributions = commandPaletteCommandContributions()
        var handlerRegistry = CommandPaletteHandlerRegistry()
        registerCommandPaletteHandlers(&handlerRegistry)

        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(contributions.count)
        var nextRank = 0

        for contribution in contributions {
            guard contribution.when(context), contribution.enablement(context) else { continue }
            guard let action = handlerRegistry.handler(for: contribution.commandId) else {
                assertionFailure("No command palette handler registered for \(contribution.commandId)")
                continue
            }
            commands.append(
                CommandPaletteCommand(
                    id: contribution.commandId,
                    rank: nextRank,
                    title: contribution.title(context),
                    subtitle: contribution.subtitle(context),
                    shortcutHint: commandPaletteShortcutHint(for: contribution, context: context),
                    keywords: contribution.keywords,
                    dismissOnRun: contribution.dismissOnRun,
                    action: action
                )
            )
            nextRank += 1
        }

        return commands
    }

    private func commandPaletteShortcutHint(
        for contribution: CommandPaletteCommandContribution,
        context: CommandPaletteContextSnapshot
    ) -> String? {
        // Preserve browser reload semantics for Cmd+R when a browser tab is focused.
        if contribution.commandId == "palette.renameTab",
           context.bool(CommandPaletteContextKeys.panelIsBrowser) {
            return nil
        }
        if let action = commandPaletteShortcutAction(for: contribution.commandId) {
            return KeyboardShortcutSettings.shortcut(for: action).displayString
        }
        if let staticShortcut = commandPaletteStaticShortcutHint(for: contribution.commandId) {
            return staticShortcut
        }
        return contribution.shortcutHint
    }

    private func commandPaletteShortcutAction(for commandId: String) -> KeyboardShortcutSettings.Action? {
        switch commandId {
        case "palette.newWorkspace":
            return .newTab
        case "palette.newWindow":
            return .newWindow
        case "palette.newTerminalTab":
            return .newSurface
        case "palette.newBrowserTab":
            return .openBrowser
        case "palette.closeWindow":
            return .closeWindow
        case "palette.toggleSidebar":
            return .toggleSidebar
        case "palette.showNotifications":
            return .showNotifications
        case "palette.jumpUnread":
            return .jumpToUnread
        case "palette.renameTab":
            return .renameTab
        case "palette.renameWorkspace":
            return .renameWorkspace
        case "palette.nextWorkspace":
            return .nextSidebarTab
        case "palette.previousWorkspace":
            return .prevSidebarTab
        case "palette.nextTabInPane":
            return .nextSurface
        case "palette.previousTabInPane":
            return .prevSurface
        case "palette.browserToggleDevTools":
            return .toggleBrowserDeveloperTools
        case "palette.browserConsole":
            return .showBrowserJavaScriptConsole
        case "palette.browserSplitRight", "palette.terminalSplitBrowserRight":
            return .splitBrowserRight
        case "palette.browserSplitDown", "palette.terminalSplitBrowserDown":
            return .splitBrowserDown
        case "palette.terminalSplitRight":
            return .splitRight
        case "palette.terminalSplitDown":
            return .splitDown
        default:
            return nil
        }
    }

    private func commandPaletteStaticShortcutHint(for commandId: String) -> String? {
        switch commandId {
        case "palette.closeTab":
            return "⌘W"
        case "palette.closeWorkspace":
            return "⌘⇧W"
        case "palette.reopenClosedBrowserTab":
            return "⌘⇧T"
        case "palette.openSettings":
            return "⌘,"
        case "palette.browserBack":
            return "⌘["
        case "palette.browserForward":
            return "⌘]"
        case "palette.browserReload":
            return "⌘R"
        case "palette.browserFocusAddressBar":
            return "⌘L"
        case "palette.browserZoomIn":
            return "⌘="
        case "palette.browserZoomOut":
            return "⌘-"
        case "palette.browserZoomReset":
            return "⌘0"
        case "palette.terminalFind":
            return "⌘F"
        case "palette.terminalFindNext":
            return "⌘G"
        case "palette.terminalFindPrevious":
            return "⌘⇧G"
        case "palette.terminalHideFind":
            return "⌘⇧F"
        case "palette.terminalUseSelectionForFind":
            return "⌘E"
        default:
            return nil
        }
    }

    private func commandPaletteContextSnapshot() -> CommandPaletteContextSnapshot {
        var snapshot = CommandPaletteContextSnapshot()

        if let workspace = tabManager.selectedWorkspace {
            snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
            snapshot.setString(CommandPaletteContextKeys.workspaceName, workspaceDisplayName(workspace))
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomName, workspace.customTitle != nil)
            snapshot.setBool(CommandPaletteContextKeys.workspaceShouldPin, !workspace.isPinned)
        }

        if let panelContext = focusedPanelContext {
            let workspace = panelContext.workspace
            let panelId = panelContext.panelId
            let panelIsTerminal = panelContext.panel.panelType == .terminal
            snapshot.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            snapshot.setString(
                CommandPaletteContextKeys.panelName,
                panelDisplayName(workspace: workspace, panelId: panelId, fallback: panelContext.panel.displayTitle)
            )
            snapshot.setBool(CommandPaletteContextKeys.panelIsBrowser, panelContext.panel.panelType == .browser)
            snapshot.setBool(CommandPaletteContextKeys.panelIsTerminal, panelIsTerminal)
            snapshot.setBool(CommandPaletteContextKeys.panelHasCustomName, workspace.panelCustomTitles[panelId] != nil)
            snapshot.setBool(CommandPaletteContextKeys.panelShouldPin, !workspace.isPanelPinned(panelId))
            let hasUnread = workspace.manualUnreadPanelIds.contains(panelId)
                || notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId)
            snapshot.setBool(CommandPaletteContextKeys.panelHasUnread, hasUnread)

            if panelIsTerminal {
                let availableTargets = TerminalDirectoryOpenTarget.cachedLiveAvailableTargets
                for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
                    snapshot.setBool(
                        CommandPaletteContextKeys.terminalOpenTargetAvailable(target),
                        availableTargets.contains(target)
                    )
                }
            }
        }

        if case .updateAvailable = updateViewModel.effectiveState {
            snapshot.setBool(CommandPaletteContextKeys.updateHasAvailable, true)
        }

        return snapshot
    }

    private func commandPaletteCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.workspaceName) ?? "Workspace"
            return "Workspace • \(name)"
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? "Tab"
            return "Tab • \(name)"
        }

        func browserPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? "Tab"
            return "Browser • \(name)"
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? "Tab"
            return "Terminal • \(name)"
        }

        var contributions: [CommandPaletteCommandContribution] = []

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant("New Workspace"),
                subtitle: constant("Workspace"),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant("New Window"),
                subtitle: constant("Window"),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant("New Tab (Terminal)"),
                subtitle: constant("Tab"),
                shortcutHint: "⌘T",
                keywords: ["new", "terminal", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserTab",
                title: constant("New Tab (Browser)"),
                subtitle: constant("Tab"),
                shortcutHint: "⌘⇧L",
                keywords: ["new", "browser", "tab", "web"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant("Close Tab"),
                subtitle: constant("Tab"),
                shortcutHint: "⌘W",
                keywords: ["close", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant("Close Workspace"),
                subtitle: constant("Workspace"),
                shortcutHint: "⌘⇧W",
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant("Close Window"),
                subtitle: constant("Window"),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenClosedBrowserTab",
                title: constant("Reopen Closed Browser Tab"),
                subtitle: constant("Browser"),
                shortcutHint: "⌘⇧T",
                keywords: ["reopen", "closed", "browser"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant("Toggle Sidebar"),
                subtitle: constant("Layout"),
                keywords: ["toggle", "sidebar", "layout"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant("Show Notifications"),
                subtitle: constant("Notifications"),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant("Jump to Latest Unread"),
                subtitle: constant("Notifications"),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant("Open Settings"),
                subtitle: constant("Global"),
                shortcutHint: "⌘,",
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant("Check for Updates"),
                subtitle: constant("Global"),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant("Apply Update (If Available)"),
                subtitle: constant("Global"),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant("Attempt Update"),
                subtitle: constant("Global"),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameWorkspace",
                title: constant("Rename Workspace…"),
                subtitle: workspaceSubtitle,
                keywords: ["rename", "workspace", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.setWorkspaceTag",
                title: constant("Set Workspace Tag…"),
                subtitle: workspaceSubtitle,
                keywords: ["tag", "bookmark", "label", "workspace"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceTag",
                title: constant("Clear Workspace Tag"),
                subtitle: workspaceSubtitle,
                keywords: ["tag", "bookmark", "clear", "remove"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.listWorktrees",
                title: constant("List Worktrees"),
                subtitle: workspaceSubtitle,
                keywords: ["worktree", "list", "git", "branch"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.cleanupWorktrees",
                title: constant("Cleanup Stale Worktrees"),
                subtitle: workspaceSubtitle,
                keywords: ["worktree", "cleanup", "clean", "remove", "stale"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openWorktreeDir",
                title: constant("Open Worktree Directory"),
                subtitle: constant("Open in Finder"),
                keywords: ["worktree", "directory", "open", "finder"],
                when: { _ in true }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorktreeWorkspace",
                title: constant("New Worktree Workspace"),
                subtitle: workspaceSubtitle,
                shortcutHint: "⌘⌥⇧N",
                keywords: ["worktree", "new", "workspace", "branch", "git", "sandbox", "isolate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceName",
                title: constant("Clear Workspace Name"),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleWorkspacePin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.workspaceShouldPin) ? "Pin Workspace" : "Unpin Workspace"
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextWorkspace",
                title: constant("Next Workspace"),
                subtitle: constant("Workspace Navigation"),
                keywords: ["next", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousWorkspace",
                title: constant("Previous Workspace"),
                subtitle: constant("Workspace Navigation"),
                keywords: ["previous", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameTab",
                title: constant("Rename Tab…"),
                subtitle: panelSubtitle,
                keywords: ["rename", "tab", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearTabName",
                title: constant("Clear Tab Name"),
                subtitle: panelSubtitle,
                keywords: ["clear", "tab", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabPin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelShouldPin) ? "Pin Tab" : "Unpin Tab"
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabUnread",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelHasUnread) ? "Mark Tab as Read" : "Mark Tab as Unread"
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant("Next Tab in Pane"),
                subtitle: constant("Tab Navigation"),
                keywords: ["next", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant("Previous Tab in Pane"),
                subtitle: constant("Tab Navigation"),
                keywords: ["previous", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserBack",
                title: constant("Back"),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘[",
                keywords: ["browser", "back", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserForward",
                title: constant("Forward"),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘]",
                keywords: ["browser", "forward", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReload",
                title: constant("Reload Page"),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘R",
                keywords: ["browser", "reload", "refresh"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserOpenDefault",
                title: constant("Open Current Page in Default Browser"),
                subtitle: browserPanelSubtitle,
                keywords: ["open", "default", "external", "browser"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusAddressBar",
                title: constant("Focus Address Bar"),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘L",
                keywords: ["browser", "address", "omnibar", "url"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleDevTools",
                title: constant("Toggle Developer Tools"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "devtools", "inspector"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserConsole",
                title: constant("Show JavaScript Console"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "console", "javascript"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomIn",
                title: constant("Zoom In"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "in"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomOut",
                title: constant("Zoom Out"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "out"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomReset",
                title: constant("Actual Size"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "reset", "actual size"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserClearHistory",
                title: constant("Clear Browser History"),
                subtitle: constant("Browser"),
                keywords: ["browser", "history", "clear"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openDashboard",
                title: constant("Open Dashboard"),
                subtitle: constant("Term-Mesh"),
                shortcutHint: "⌘⇧D",
                keywords: ["dashboard", "monitor", "heatmap", "resources", "term-mesh"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitRight",
                title: constant("Split Browser Right"),
                subtitle: constant("Browser Layout"),
                keywords: ["browser", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitDown",
                title: constant("Split Browser Down"),
                subtitle: constant("Browser Layout"),
                keywords: ["browser", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserDuplicateRight",
                title: constant("Duplicate Browser to the Right"),
                subtitle: constant("Browser Layout"),
                keywords: ["browser", "duplicate", "clone", "split"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: target.commandPaletteCommandId,
                    title: constant(target.commandPaletteTitle),
                    subtitle: terminalPanelSubtitle,
                    keywords: target.commandPaletteKeywords,
                    when: { context in
                        context.bool(CommandPaletteContextKeys.panelIsTerminal)
                            && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(target))
                    }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant("Find…"),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘F",
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant("Find Next"),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘G",
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant("Find Previous"),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘⇧G",
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant("Hide Find Bar"),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘⇧F",
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant("Use Selection for Find"),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant("Split Right"),
                subtitle: constant("Terminal Layout"),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant("Split Down"),
                subtitle: constant("Terminal Layout"),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserRight",
                title: constant("Split Browser Right"),
                subtitle: constant("Terminal Layout"),
                keywords: ["terminal", "split", "browser", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserDown",
                title: constant("Split Browser Down"),
                subtitle: constant("Terminal Layout"),
                keywords: ["terminal", "split", "browser", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )

        // --- Dev Workflow Commands ---
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.copyGitBranch",
                title: constant("Copy Git Branch"),
                subtitle: constant("Dev"),
                keywords: ["git", "branch", "copy", "clipboard"],
                when: { _ in
                    tabManager.selectedWorkspace?.gitBranch != nil
                }
            )
        )

        // --- Agent Team Commands ---
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newAgentTeam",
                title: constant("New Agent Team…"),
                subtitle: constant("Team"),
                shortcutHint: "⌘⌥T",
                keywords: ["agent", "team", "create", "multi", "orchestrate", "claude"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.destroyTeam",
                title: constant("Destroy Agent Team"),
                subtitle: constant("Team"),
                keywords: ["agent", "team", "destroy", "stop", "kill", "close"],
                when: { _ in !TeamOrchestrator.shared.teams.isEmpty }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.broadcastToTeam",
                title: constant("Broadcast to All Agents"),
                subtitle: constant("Team"),
                keywords: ["agent", "team", "broadcast", "send", "all", "message"],
                when: { _ in !TeamOrchestrator.shared.teams.isEmpty }
            )
        )

        return contributions
    }

    private func registerCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newWorkspace") {
            tabManager.addWorkspace()
        }
        registry.register(commandId: "palette.newWindow") {
            AppDelegate.shared?.openNewMainWindow(nil)
        }
        registry.register(commandId: "palette.newTerminalTab") {
            tabManager.newSurface()
        }
        registry.register(commandId: "palette.newBrowserTab") {
            _ = tabManager.openBrowser()
        }
        registry.register(commandId: "palette.closeTab") {
            tabManager.closeCurrentPanelWithConfirmation()
        }
        registry.register(commandId: "palette.closeWorkspace") {
            tabManager.closeCurrentWorkspaceWithConfirmation()
        }
        registry.register(commandId: "palette.closeWindow") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.performClose(nil)
        }
        registry.register(commandId: "palette.reopenClosedBrowserTab") {
            _ = tabManager.reopenMostRecentlyClosedBrowserPanel()
        }
        registry.register(commandId: "palette.toggleSidebar") {
            sidebarState.toggle()
        }
        registry.register(commandId: "palette.showNotifications") {
            AppDelegate.shared?.toggleNotificationsPopover(animated: false)
        }
        registry.register(commandId: "palette.jumpUnread") {
            AppDelegate.shared?.jumpToLatestUnread()
        }
        registry.register(commandId: "palette.openSettings") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        registry.register(commandId: "palette.checkForUpdates") {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        registry.register(commandId: "palette.applyUpdateIfAvailable") {
            AppDelegate.shared?.applyUpdateIfAvailable(nil)
        }
        registry.register(commandId: "palette.attemptUpdate") {
            AppDelegate.shared?.attemptUpdate(nil)
        }

        registry.register(commandId: "palette.renameWorkspace") {
            beginRenameWorkspaceFlow()
        }
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomTitle(tabId: workspace.id)
        }
        registry.register(commandId: "palette.setWorkspaceTag") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            Self.showWorkspaceTagPrompt(for: workspace)
        }
        registry.register(commandId: "palette.clearWorkspaceTag") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            workspace.tag = nil
        }
        registry.register(commandId: "palette.listWorktrees") { [daemon = self.daemonService] in
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            let dir = workspace.currentDirectory
            DispatchQueue.global(qos: .userInitiated).async {
                guard let repoPath = daemon?.findGitRoot(from: dir), !repoPath.isEmpty else {
                    DispatchQueue.main.async { NSSound.beep() }
                    return
                }
                let worktrees = daemon?.listWorktrees(repoPath: repoPath) ?? []
                DispatchQueue.main.async {
                    Self.showWorktreeManager(worktrees: worktrees, repoPath: repoPath)
                }
            }
        }
        registry.register(commandId: "palette.cleanupWorktrees") { [daemon = self.daemonService] in
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            let dir = workspace.currentDirectory
            DispatchQueue.global(qos: .userInitiated).async {
                guard let repoPath = daemon?.findGitRoot(from: dir), !repoPath.isEmpty else {
                    DispatchQueue.main.async { NSSound.beep() }
                    return
                }
                let result = daemon?.cleanupStaleWorktrees(repoPath: repoPath) ?? (removed: 0, skippedDirty: 0)
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Worktree Cleanup"
                    if result.removed > 0 && result.skippedDirty > 0 {
                        alert.informativeText = "Removed \(result.removed) stale worktree(s).\nSkipped \(result.skippedDirty) with uncommitted changes."
                    } else if result.removed > 0 {
                        alert.informativeText = "Removed \(result.removed) stale worktree(s)."
                    } else if result.skippedDirty > 0 {
                        alert.informativeText = "No clean stale worktrees to remove.\nSkipped \(result.skippedDirty) with uncommitted changes."
                    } else {
                        alert.informativeText = "No stale worktrees to clean up."
                    }
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
        registry.register(commandId: "palette.openWorktreeDir") { [daemon = self.daemonService] in
            let path = daemon?.worktreeBaseDir ?? ""
            let url = URL(fileURLWithPath: path)
            // Create directory if it doesn't exist
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        }
        registry.register(commandId: "palette.newWorktreeWorkspace") {
            createWorktreeWorkspace()
        }
        registry.register(commandId: "palette.toggleWorkspacePin") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.setPinned(workspace, pinned: !workspace.isPinned)
        }
        registry.register(commandId: "palette.nextWorkspace") {
            tabManager.selectNextTab()
        }
        registry.register(commandId: "palette.previousWorkspace") {
            tabManager.selectPreviousTab()
        }

        registry.register(commandId: "palette.renameTab") {
            beginRenameTabFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.toggleTabPin") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelPinned(
                panelId: panelContext.panelId,
                pinned: !panelContext.workspace.isPanelPinned(panelContext.panelId)
            )
        }
        registry.register(commandId: "palette.toggleTabUnread") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            let hasUnread = panelContext.workspace.manualUnreadPanelIds.contains(panelContext.panelId)
                || notificationStore.hasUnreadNotification(forTabId: panelContext.workspace.id, surfaceId: panelContext.panelId)
            if hasUnread {
                panelContext.workspace.markPanelRead(panelContext.panelId)
            } else {
                panelContext.workspace.markPanelUnread(panelContext.panelId)
            }
        }
        registry.register(commandId: "palette.nextTabInPane") {
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            tabManager.selectPreviousSurface()
        }

        registry.register(commandId: "palette.browserBack") {
            tabManager.focusedBrowserPanel?.goBack()
        }
        registry.register(commandId: "palette.browserForward") {
            tabManager.focusedBrowserPanel?.goForward()
        }
        registry.register(commandId: "palette.browserReload") {
            tabManager.focusedBrowserPanel?.reload()
        }
        registry.register(commandId: "palette.browserOpenDefault") {
            if !openFocusedBrowserInDefaultBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusAddressBar") {
            if !focusFocusedBrowserAddressBar() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleDevTools") {
            if !tabManager.toggleDeveloperToolsFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserConsole") {
            if !tabManager.showJavaScriptConsoleFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomIn") {
            if !tabManager.zoomInFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomOut") {
            if !tabManager.zoomOutFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomReset") {
            if !tabManager.resetZoomFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserClearHistory") {
            browserHistory?.clearHistory()
        }
        registry.register(commandId: "palette.openDashboard") {
            let port = ProcessInfo.processInfo.environment["TERM_MESH_HTTP_ADDR"]
                .flatMap { $0.split(separator: ":").last.map(String.init) } ?? "9876"
            if let url = URL(string: "http://localhost:\(port)") {
                _ = tabManager.createBrowserSplit(direction: .right, url: url)
            }
        }
        registry.register(commandId: "palette.browserSplitRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.browserSplitDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.browserDuplicateRight") {
            let url = tabManager.focusedBrowserPanel?.preferredURLStringForOmnibar().flatMap(URL.init(string:))
            _ = tabManager.createBrowserSplit(direction: .right, url: url)
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            registry.register(commandId: target.commandPaletteCommandId) {
                if !openFocusedDirectory(in: target) {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.terminalFind") {
            tabManager.startSearch()
        }
        registry.register(commandId: "palette.terminalFindNext") {
            tabManager.findNext()
        }
        registry.register(commandId: "palette.terminalFindPrevious") {
            tabManager.findPrevious()
        }
        registry.register(commandId: "palette.terminalHideFind") {
            tabManager.hideFind()
        }
        registry.register(commandId: "palette.terminalUseSelectionForFind") {
            tabManager.searchSelection()
        }
        registry.register(commandId: "palette.terminalSplitRight") {
            tabManager.createSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitDown") {
            tabManager.createSplit(direction: .down)
        }
        registry.register(commandId: "palette.terminalSplitBrowserRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitBrowserDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }

        // --- Dev Workflow Commands ---
        registry.register(commandId: "palette.copyGitBranch") {
            if let branch = tabManager.selectedWorkspace?.gitBranch?.branch {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(branch, forType: .string)
            }
        }

        // --- Agent Team Commands ---
        registry.register(commandId: "palette.newAgentTeam") {
            NotificationCenter.default.post(name: .teamCreationRequested, object: nil)
        }
        registry.register(commandId: "palette.destroyTeam") {
            let teams = TeamOrchestrator.shared.teams
            guard let firstTeam = teams.keys.sorted().first else { return }
            _ = TeamOrchestrator.shared.destroyTeam(name: firstTeam, tabManager: tabManager)
        }
        registry.register(commandId: "palette.broadcastToTeam") {
            // Broadcast is handled via the leader REPL or socket API;
            // from palette we focus the leader workspace for the first active team.
            let teams = TeamOrchestrator.shared.teams
            guard let firstTeam = teams.values.sorted(by: { $0.createdAt < $1.createdAt }).first else { return }
            if let workspace = tabManager.tabs.first(where: { $0.id == firstTeam.workspaceId }) {
                tabManager.selectTab(workspace)
            }
        }
    }

    private var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = title.isEmpty ? "Workspace" : title
        if workspace.worktreeName != nil {
            return "🔀 " + base
        }
        return base
    }

    private func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "Tab" : trimmedFallback
    }

    private func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(commandPaletteSelectedResultIndex, 0), resultCount - 1)
    }

    static func commandPaletteScrollPositionAnchor(
        selectedIndex: Int,
        resultCount: Int
    ) -> UnitPoint? {
        guard resultCount > 0 else { return nil }
        if selectedIndex <= 0 {
            return UnitPoint.top
        }
        if selectedIndex >= resultCount - 1 {
            return UnitPoint.bottom
        }
        return nil
    }

    private func updateCommandPaletteScrollTarget(resultCount: Int, animated: Bool) {
        guard resultCount > 0 else {
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            return
        }

        let selectedIndex = commandPaletteSelectedIndex(resultCount: resultCount)
        commandPaletteScrollTargetAnchor = Self.commandPaletteScrollPositionAnchor(
            selectedIndex: selectedIndex,
            resultCount: resultCount
        )

        let assignTarget = {
            commandPaletteScrollTargetIndex = selectedIndex
        }
        if animated {
            withAnimation(.easeOut(duration: 0.1)) {
                assignTarget()
            }
        } else {
            assignTarget()
        }
    }

    private func moveCommandPaletteSelection(by delta: Int) {
        let count = commandPaletteResults.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let current = commandPaletteSelectedIndex(resultCount: count)
        commandPaletteSelectedResultIndex = min(max(current + delta, 0), count - 1)
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func handleCommandPaletteControlNavigationKey(
        modifiers: EventModifiers,
        delta: Int
    ) -> BackportKeyPressResult {
        guard modifiers.contains(.control),
              !modifiers.contains(.command),
              !modifiers.contains(.shift),
              !modifiers.contains(.option) else {
            return .ignored
        }
        moveCommandPaletteSelection(by: delta)
        return .handled
    }

    static func commandPaletteShouldPopRenameInputOnDelete(
        renameDraft: String,
        modifiers: EventModifiers
    ) -> Bool {
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return renameDraft.isEmpty
    }

    private func handleCommandPaletteRenameDeleteBackward(
        modifiers: EventModifiers
    ) -> BackportKeyPressResult {
        guard case .renameInput = commandPaletteMode else { return .ignored }
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return .ignored }

        if Self.commandPaletteShouldPopRenameInputOnDelete(
            renameDraft: commandPaletteRenameDraft,
            modifiers: modifiers
        ) {
            commandPaletteMode = .commands
            resetCommandPaletteSearchFocus()
            syncCommandPaletteDebugStateForObservedWindow()
            return .handled
        }

        if let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.deleteBackward(nil)
            commandPaletteRenameDraft = editor.string
        } else if !commandPaletteRenameDraft.isEmpty {
            commandPaletteRenameDraft.removeLast()
        }

        syncCommandPaletteDebugStateForObservedWindow()
        return .handled
    }

    private func runSelectedCommandPaletteResult(visibleResults: [CommandPaletteSearchResult]? = nil) {
        let visibleResults = visibleResults ?? Array(commandPaletteResults)
        guard !visibleResults.isEmpty else {
            NSSound.beep()
            return
        }
        let index = commandPaletteSelectedIndex(resultCount: visibleResults.count)
        runCommandPaletteCommand(visibleResults[index].command)
    }

    private func runCommandPaletteCommand(_ command: CommandPaletteCommand) {
        recordCommandPaletteUsage(command.id)
        command.action()
        if command.dismissOnRun {
            dismissCommandPalette(restoreFocus: false)
        }
    }

    private func toggleCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
    }

    private func openCommandPaletteCommands() {
        toggleCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
    }

    private func openCommandPaletteSwitcher() {
        toggleCommandPalette(initialQuery: "")
    }

    private func toggleCommandPalette(initialQuery: String) {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette(initialQuery: initialQuery)
        }
    }

    private func openCommandPaletteRenameTabInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameTabFlow()
    }

    static func shouldHandleCommandPaletteRequest(
        observedWindow: NSWindow?,
        requestedWindow: NSWindow?,
        keyWindow: NSWindow?,
        mainWindow: NSWindow?
    ) -> Bool {
        guard let observedWindow else { return false }
        if let requestedWindow {
            return requestedWindow === observedWindow
        }
        if let keyWindow {
            return keyWindow === observedWindow
        }
        if let mainWindow {
            return mainWindow === observedWindow
        }
        return false
    }

    private func syncCommandPaletteDebugStateForObservedWindow() {
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        AppDelegate.shared?.setCommandPaletteVisible(isCommandPalettePresented, for: window)
        let visibleResultCount = commandPaletteResults.count
        let selectedIndex = isCommandPalettePresented ? commandPaletteSelectedIndex(resultCount: visibleResultCount) : 0
        AppDelegate.shared?.setCommandPaletteSelectionIndex(selectedIndex, for: window)
        AppDelegate.shared?.setCommandPaletteSnapshot(commandPaletteDebugSnapshot(), for: window)
    }

    private func commandPaletteDebugSnapshot() -> CommandPaletteDebugSnapshot {
        guard isCommandPalettePresented else { return .empty }

        let mode: String
        switch commandPaletteMode {
        case .commands:
            mode = commandPaletteListScope.rawValue
        case .renameInput:
            mode = "rename_input"
        case .renameConfirm:
            mode = "rename_confirm"
        }

        let rows = Array(commandPaletteResults.prefix(20)).map { result in
            CommandPaletteDebugResultRow(
                commandId: result.command.id,
                title: result.command.title,
                shortcutHint: result.command.shortcutHint,
                trailingLabel: commandPaletteTrailingLabel(for: result.command)?.text,
                score: result.score
            )
        }

        return CommandPaletteDebugSnapshot(
            query: commandPaletteQueryForMatching,
            mode: mode,
            results: rows
        )
    }

    private func presentCommandPalette(initialQuery: String) {
        if let panelContext = focusedPanelContext {
            commandPaletteRestoreFocusTarget = CommandPaletteRestoreFocusTarget(
                workspaceId: panelContext.workspace.id,
                panelId: panelContext.panelId
            )
        } else {
            commandPaletteRestoreFocusTarget = nil
        }
        isCommandPalettePresented = true
        refreshCommandPaletteUsageHistory()
        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func resetCommandPaletteListState(initialQuery: String) {
        commandPaletteMode = .commands
        commandPaletteQuery = initialQuery
        commandPaletteRenameDraft = ""
        commandPaletteSelectedResultIndex = 0
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        resetCommandPaletteSearchFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func dismissCommandPalette(restoreFocus: Bool = true) {
        let focusTarget = commandPaletteRestoreFocusTarget
        isCommandPalettePresented = false
        commandPaletteMode = .commands
        commandPaletteQuery = ""
        commandPaletteRenameDraft = ""
        commandPaletteSelectedResultIndex = 0
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        isCommandPaletteSearchFocused = false
        isCommandPaletteRenameFocused = false
        commandPaletteRestoreFocusTarget = nil
        if let window = observedWindow {
            _ = window.makeFirstResponder(nil)
        }
        syncCommandPaletteDebugStateForObservedWindow()

        guard restoreFocus, let focusTarget else { return }
        restoreCommandPaletteFocus(target: focusTarget, attemptsRemaining: 6)
    }

    private func restoreCommandPaletteFocus(
        target: CommandPaletteRestoreFocusTarget,
        attemptsRemaining: Int
    ) {
        guard !isCommandPalettePresented else { return }
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else { return }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        tabManager.focusTab(target.workspaceId, surfaceId: target.panelId, suppressFlash: true)

        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard !isCommandPalettePresented else { return }
            if let context = focusedPanelContext,
               context.workspace.id == target.workspaceId,
               context.panelId == target.panelId {
                return
            }
            restoreCommandPaletteFocus(target: target, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func resetCommandPaletteSearchFocus() {
        applyCommandPaletteInputFocusPolicy(.search)
    }

    private func resetCommandPaletteRenameFocus() {
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func handleCommandPaletteRenameInputInteraction() {
        guard isCommandPalettePresented else { return }
        guard case .renameInput = commandPaletteMode else { return }
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func commandPaletteRenameInputFocusPolicy() -> CommandPaletteInputFocusPolicy {
        let selectAllOnFocus = CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled()
        let selectionBehavior: CommandPaletteTextSelectionBehavior = selectAllOnFocus
            ? .selectAll
            : .caretAtEnd
        return CommandPaletteInputFocusPolicy(
            focusTarget: .rename,
            selectionBehavior: selectionBehavior
        )
    }

    private func applyCommandPaletteInputFocusPolicy(_ policy: CommandPaletteInputFocusPolicy) {
        DispatchQueue.main.async {
            switch policy.focusTarget {
            case .search:
                isCommandPaletteRenameFocused = false
                isCommandPaletteSearchFocused = true
            case .rename:
                isCommandPaletteSearchFocused = false
                isCommandPaletteRenameFocused = true
            }
            applyCommandPaletteTextSelection(policy.selectionBehavior)
        }
    }

    private func applyCommandPaletteTextSelection(
        _ behavior: CommandPaletteTextSelectionBehavior,
        attemptsRemaining: Int = 20
    ) {
        guard isCommandPalettePresented else { return }
        switch behavior {
        case .selectAll:
            guard case .renameInput = commandPaletteMode else { return }
        case .caretAtEnd:
            switch commandPaletteMode {
            case .commands, .renameInput:
                break
            case .renameConfirm:
                return
            }
        }
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            let length = (editor.string as NSString).length
            switch behavior {
            case .selectAll:
                editor.setSelectedRange(NSRange(location: 0, length: length))
            case .caretAtEnd:
                editor.setSelectedRange(NSRange(location: length, length: 0))
            }
            return
        }

        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            applyCommandPaletteTextSelection(behavior, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func refreshCommandPaletteUsageHistory() {
        commandPaletteUsageHistoryByCommandId = loadCommandPaletteUsageHistory()
    }

    private func loadCommandPaletteUsageHistory() -> [String: CommandPaletteUsageEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.commandPaletteUsageDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CommandPaletteUsageEntry].self, from: data)) ?? [:]
    }

    private func persistCommandPaletteUsageHistory(_ history: [String: CommandPaletteUsageEntry]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.commandPaletteUsageDefaultsKey)
    }

    private func recordCommandPaletteUsage(_ commandId: String) {
        var history = commandPaletteUsageHistoryByCommandId
        var entry = history[commandId] ?? CommandPaletteUsageEntry(useCount: 0, lastUsedAt: 0)
        entry.useCount += 1
        entry.lastUsedAt = Date().timeIntervalSince1970
        history[commandId] = entry
        commandPaletteUsageHistoryByCommandId = history
        persistCommandPaletteUsageHistory(history)
    }

    private func commandPaletteHistoryBoost(for commandId: String, queryIsEmpty: Bool) -> Int {
        guard let entry = commandPaletteUsageHistoryByCommandId[commandId] else { return 0 }

        let now = Date().timeIntervalSince1970
        let ageDays = max(0, now - entry.lastUsedAt) / 86_400
        let recencyBoost = max(0, 320 - Int(ageDays * 20))
        let countBoost = min(180, entry.useCount * 12)
        let totalBoost = recencyBoost + countBoost

        return queryIsEmpty ? totalBoost : max(0, totalBoost / 3)
    }

    private func beginRenameWorkspaceFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspace.id),
            currentName: workspaceDisplayName(workspace)
        )
        startRenameFlow(target)
    }

    private func beginRenameTabFlow() {
        guard let panelContext = focusedPanelContext else {
            NSSound.beep()
            return
        }
        let panelName = panelDisplayName(
            workspace: panelContext.workspace,
            panelId: panelContext.panelId,
            fallback: panelContext.panel.displayTitle
        )
        let target = CommandPaletteRenameTarget(
            kind: .tab(workspaceId: panelContext.workspace.id, panelId: panelContext.panelId),
            currentName: panelName
        )
        startRenameFlow(target)
    }

    private func startRenameFlow(_ target: CommandPaletteRenameTarget) {
        commandPaletteRenameDraft = target.currentName
        commandPaletteMode = .renameInput(target)
        resetCommandPaletteRenameFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func continueRenameFlow(target: CommandPaletteRenameTarget) {
        guard case .renameInput(let activeTarget) = commandPaletteMode,
              activeTarget == target else { return }
        applyRenameFlow(target: target, proposedName: commandPaletteRenameDraft)
    }

    private func applyRenameFlow(target: CommandPaletteRenameTarget, proposedName: String) {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName: String? = trimmedName.isEmpty ? nil : trimmedName

        switch target.kind {
        case .workspace(let workspaceId):
            tabManager.setCustomTitle(tabId: workspaceId, title: normalizedName)
        case .tab(let workspaceId, let panelId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                NSSound.beep()
                return
            }
            workspace.setPanelCustomTitle(panelId: panelId, title: normalizedName)
        }

        dismissCommandPalette()
    }

    private func focusFocusedBrowserAddressBar() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel else { return false }
        _ = panel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
        return true
    }

    private func openFocusedBrowserInDefaultBrowser() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel,
              let rawURL = panel.preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func openFocusedDirectory(in target: TerminalDirectoryOpenTarget) -> Bool {
        guard let directoryURL = focusedTerminalDirectoryURL() else { return false }
        return openFocusedDirectory(directoryURL, in: target)
    }

    private func openFocusedDirectory(_ directoryURL: URL, in target: TerminalDirectoryOpenTarget) -> Bool {
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            return true
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
    }

    private func focusedTerminalDirectoryURL() -> URL? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let rawDirectory: String = {
            if let focusedPanelId = workspace.focusedPanelId,
               let directory = workspace.panelDirectories[focusedPanelId] {
                return directory
            }
            return workspace.currentDirectory
        }()
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

#if DEBUG
    private func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private func debugShortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }

    private func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif
}
