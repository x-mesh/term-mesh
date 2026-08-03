import SwiftUI
import AppKit
import Bonsplit

// MARK: - Phase 2.5 — Token compaction helper

/// Compact integer token counts for sidebar display.
///   0..999            → "123"
///   1_000..999_999    → "1.2k"
///   1_000_000..       → "1.2M"
///   1_000_000_000..   → "1.2G"
fileprivate func compactToken(_ n: UInt64) -> String {
    if n < 1_000 { return "\(n)" }
    let formatter: (Double) -> String = { v in
        // Show one decimal unless the value is an exact multiple (e.g. 5.0 → 5).
        if v.truncatingRemainder(dividingBy: 1) == 0 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
    if n < 1_000_000 { return formatter(Double(n) / 1_000) + "k" }
    if n < 1_000_000_000 { return formatter(Double(n) / 1_000_000) + "M" }
    return formatter(Double(n) / 1_000_000_000) + "G"
}

struct SidebarEmptyArea: View {
    @EnvironmentObject var tabManager: TabManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2) {
                tabManager.addTab()
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
            .onDrop(of: [SidebarTabDragPayload.typeIdentifier], delegate: SidebarTabDropDelegate(
                targetTabId: nil,
                tabManager: tabManager,
                draggedTabId: $draggedTabId,
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                targetRowHeight: nil,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastTabId = tabManager.tabs.last?.id else { return false }
        return indicator.tabId == lastTabId
    }
}

struct TabItemView: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    /// Action target only. The row deliberately does not subscribe to the
    /// manager's broad publisher; explicit render snapshots below define its
    /// invalidation boundary.
    let tabManager: TabManager
    @ObservedObject var tab: Tab
    let index: Int
    let isActive: Bool
    let isMultiSelected: Bool
    let workspaceCount: Int
    /// Parent-computed snapshot. Avoids a linear scan of every team from
    /// every row body and makes team membership part of the Equatable edge.
    let activeTeamName: String?
    /// Parent-computed notification state. This prevents a notification for
    /// one workspace from directly invalidating every sidebar row.
    let notificationSummary: SidebarNotificationSummary
    /// Tabs that are actually rendered in this section, in presentation
    /// order. Experimental mode excludes peer-mirror backing workspaces.
    let visibleTabIds: [UUID]
    let rowSpacing: CGFloat
    /// Action-only bindings are stored as closures so selection changes do not
    /// directly invalidate every row. Explicit render snapshots below still
    /// carry the drag state that affects pixels.
    private let getSelection: () -> SidebarSelection
    private let setSelection: (SidebarSelection) -> Void
    private let getSelectedTabIds: () -> Set<UUID>
    private let setSelectedTabIds: (Set<UUID>) -> Void
    private let getLastSidebarSelectionIndex: () -> Int?
    private let setLastSidebarSelectionIndex: (Int?) -> Void
    let showsCommandShortcutHints: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    private let getDraggedTabId: () -> UUID?
    private let setDraggedTabId: (UUID?) -> Void
    private let getDropIndicator: () -> SidebarDropIndicator?
    private let setDropIndicator: (SidebarDropIndicator?) -> Void
    private let draggedTabIdSnapshot: UUID?
    private let dropIndicatorSnapshot: SidebarDropIndicator?
    @State private var isHovering = false
    @State private var rowHeight: CGFloat = 1
    @State private var cachedSlotWidth: CGFloat = 28

    init(
        tabManager: TabManager,
        tab: Tab,
        index: Int,
        isActive: Bool,
        isMultiSelected: Bool,
        workspaceCount: Int,
        activeTeamName: String?,
        notificationSummary: SidebarNotificationSummary,
        visibleTabIds: [UUID],
        rowSpacing: CGFloat,
        selection: Binding<SidebarSelection>,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>,
        showsCommandShortcutHints: Bool,
        dragAutoScrollController: SidebarDragAutoScrollController,
        draggedTabId: Binding<UUID?>,
        dropIndicator: Binding<SidebarDropIndicator?>
    ) {
        self.tabManager = tabManager
        self.tab = tab
        self.index = index
        self.isActive = isActive
        self.isMultiSelected = isMultiSelected
        self.workspaceCount = workspaceCount
        self.activeTeamName = activeTeamName
        self.notificationSummary = notificationSummary
        self.visibleTabIds = visibleTabIds
        self.rowSpacing = rowSpacing
        self.getSelection = { selection.wrappedValue }
        self.setSelection = { selection.wrappedValue = $0 }
        self.getSelectedTabIds = { selectedTabIds.wrappedValue }
        self.setSelectedTabIds = { selectedTabIds.wrappedValue = $0 }
        self.getLastSidebarSelectionIndex = { lastSidebarSelectionIndex.wrappedValue }
        self.setLastSidebarSelectionIndex = { lastSidebarSelectionIndex.wrappedValue = $0 }
        self.showsCommandShortcutHints = showsCommandShortcutHints
        self.dragAutoScrollController = dragAutoScrollController
        self.getDraggedTabId = { draggedTabId.wrappedValue }
        self.setDraggedTabId = { draggedTabId.wrappedValue = $0 }
        self.getDropIndicator = { dropIndicator.wrappedValue }
        self.setDropIndicator = { dropIndicator.wrappedValue = $0 }
        self.draggedTabIdSnapshot = draggedTabId.wrappedValue
        self.dropIndicatorSnapshot = dropIndicator.wrappedValue
    }

    private var selection: SidebarSelection {
        get { getSelection() }
        nonmutating set { setSelection(newValue) }
    }

    private var selectedTabIds: Set<UUID> {
        get { getSelectedTabIds() }
        nonmutating set { setSelectedTabIds(newValue) }
    }

    private var lastSidebarSelectionIndex: Int? {
        get { getLastSidebarSelectionIndex() }
        nonmutating set { setLastSidebarSelectionIndex(newValue) }
    }

    private var draggedTabId: UUID? {
        get { getDraggedTabId() }
        nonmutating set { setDraggedTabId(newValue) }
    }

    private var dropIndicator: SidebarDropIndicator? {
        get { getDropIndicator() }
        nonmutating set { setDropIndicator(newValue) }
    }

    private var selectedTabIdsBinding: Binding<Set<UUID>> {
        Binding(get: getSelectedTabIds, set: setSelectedTabIds)
    }

    private var lastSidebarSelectionIndexBinding: Binding<Int?> {
        Binding(get: getLastSidebarSelectionIndex, set: setLastSidebarSelectionIndex)
    }

    private var draggedTabIdBinding: Binding<UUID?> {
        Binding(get: getDraggedTabId, set: setDraggedTabId)
    }

    private var dropIndicatorBinding: Binding<SidebarDropIndicator?> {
        Binding(get: getDropIndicator, set: setDropIndicator)
    }

    /// Host chip for a relay/remote workspace row. Extracted from `body`
    /// to keep the row's VStack within the Swift type-checker's budget.
    @ViewBuilder
    private var hostChip: some View {
        if let hostKey = tab.dominantRemoteHostKey {
            let chipColor = Color(nsColor: PeerHostAccent.primaryColor(for: hostKey))
            // Dot always carries the host hue. Text switches to white on a
            // selected row (bright gradient background) where the host hue
            // would blend in; on an unselected (dark) row it keeps the hue.
            let textColor = usesInvertedActiveForeground ? Color.white : chipColor.opacity(0.9)
            HStack(spacing: 4) {
                Circle()
                    .fill(chipColor)
                    .frame(width: 5, height: 5)
                Text(PeerHostProfileStore.shared.displayLabel(for: hostKey))
                    .font(.system(size: 10, weight: usesInvertedActiveForeground ? .medium : .regular, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
    @AppStorage(ShortcutHintDebugSettings.sidebarHintXKey) private var sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
    @AppStorage(ShortcutHintDebugSettings.sidebarHintYKey) private var sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage("sidebarShowGitBranch") private var sidebarShowGitBranch = true
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage("sidebarShowGitBranchIcon") private var sidebarShowGitBranchIcon = false
    @AppStorage("sidebarShowPorts") private var sidebarShowPorts = true
    @AppStorage("sidebarShowLog") private var sidebarShowLog = true
    @AppStorage("sidebarShowProgress") private var sidebarShowProgress = true
    @AppStorage("sidebarShowStatusPills") private var sidebarShowStatusPills = true
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var activeTabIndicatorStyleRaw = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue

    private var isBeingDragged: Bool {
        draggedTabId == tab.id
    }

    private var activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: activeTabIndicatorStyleRaw)
    }

    private var titleFontWeight: Font.Weight {
        .semibold
    }

    private var showsLeadingRail: Bool {
        explicitRailColor != nil || peerRailColor != nil
    }

    private var activeBorderLineWidth: CGFloat {
        switch activeTabIndicatorStyle {
        case .leftRail:
            return 0
        case .solidFill:
            return isActive ? 1.5 : 0
        }
    }

    private var activeBorderColor: Color {
        guard isActive else { return .clear }
        switch activeTabIndicatorStyle {
        case .leftRail:
            return .clear
        case .solidFill:
            return Color.primary.opacity(0.5)
        }
    }

    private var usesInvertedActiveForeground: Bool {
        isActive
    }

    private var activePrimaryTextColor: Color {
        usesInvertedActiveForeground ? .white : .primary
    }

    private func activeSecondaryColor(_ opacity: Double = 0.75) -> Color {
        usesInvertedActiveForeground ? .white.opacity(opacity) : .secondary
    }

    private var activeUnreadBadgeFillColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.25) : Color.accentColor
    }

    private var activeProgressTrackColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.15) : Color.secondary.opacity(0.2)
    }

    private var activeProgressFillColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.8) : Color.accentColor
    }

    private var shortcutHintEmphasis: Double {
        usesInvertedActiveForeground ? 1.0 : 0.9
    }

    private var workspaceShortcutDigit: Int? {
        WorkspaceShortcutMapper.commandDigitForWorkspace(at: index, workspaceCount: workspaceCount)
    }

    private var showCloseButton: Bool {
        isHovering && workspaceCount > 1 && !(showsCommandShortcutHints || alwaysShowShortcutHints)
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "⌘\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsCommandShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    private var visibleIndex: Int? {
        visibleTabIds.firstIndex(of: tab.id)
    }

    private func updateCachedSlotWidth() {
        guard let label = workspaceShortcutLabel else {
            cachedSlotWidth = 28
            return
        }
        let positiveDebugInset = max(0, CGFloat(ShortcutHintDebugSettings.clamped(sidebarShortcutHintXOffset))) + 2
        cachedSlotWidth = max(28, workspaceHintWidth(for: label) + positiveDebugInset)
    }

    private func workspaceHintWidth(for label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 12
    }

    static func == (lhs: TabItemView, rhs: TabItemView) -> Bool {
        lhs.tab === rhs.tab &&
            lhs.index == rhs.index &&
            lhs.isActive == rhs.isActive &&
            lhs.isMultiSelected == rhs.isMultiSelected &&
            lhs.workspaceCount == rhs.workspaceCount &&
            lhs.activeTeamName == rhs.activeTeamName &&
            lhs.notificationSummary == rhs.notificationSummary &&
            lhs.visibleTabIds == rhs.visibleTabIds &&
            lhs.rowSpacing == rhs.rowSpacing &&
            lhs.showsCommandShortcutHints == rhs.showsCommandShortcutHints &&
            lhs.draggedTabIdSnapshot == rhs.draggedTabIdSnapshot &&
            lhs.dropIndicatorSnapshot == rhs.dropIndicatorSnapshot
    }

    var body: some View {
        // Selection changes invalidate every sidebar row. Build the relatively
        // expensive branch/directory presentation once per body evaluation;
        // referring to the computed property from the emptiness check, branch
        // icon gate, and ForEach used to repeat path normalization three times.
        let verticalLines = sidebarBranchVerticalLayout
            ? tab.sidebarBranchDirectoryDisplayLines(showGitBranch: sidebarShowGitBranch)
            : []

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                let unreadCount = notificationSummary.unreadCount
                if unreadCount > 0 {
                    ZStack {
                        Circle()
                            .fill(activeUnreadBadgeFillColor)
                        Text("\(unreadCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 16, height: 16)
                }

                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(activeSecondaryColor(0.8))
                }

                HStack(spacing: 4) {
                    if tab.worktreeName != nil || tab.isInsideWorktree {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.green)
                    }
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: titleFontWeight))
                        .foregroundColor(activePrimaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                ZStack(alignment: .trailing) {
                    // Conditionally include the xmark button to avoid resolving the SF Symbol
                    // on every tab row regardless of hover state (TERM-MESH-5).
                    if showCloseButton && !showsWorkspaceShortcutHint {
                        Button(action: {
                            #if DEBUG
                            dlog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=button")
                            #endif
                            tabManager.closeWorkspaceWithConfirmation(tab)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(activeSecondaryColor(0.7))
                        }
                        .buttonStyle(.plain)
                        .help(KeyboardShortcutSettings.Action.closeWorkspace.tooltip("Close Workspace"))
                        .frame(width: 16, height: 16, alignment: .center)
                        .transition(.opacity)
                    } else {
                        Color.clear
                            .frame(width: 16, height: 16)
                    }

                    if showsWorkspaceShortcutHint, let workspaceShortcutLabel {
                        Text(workspaceShortcutLabel)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(activePrimaryTextColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ShortcutHintPillBackground(emphasis: shortcutHintEmphasis))
                            .offset(
                                x: ShortcutHintDebugSettings.clamped(sidebarShortcutHintXOffset),
                                y: ShortcutHintDebugSettings.clamped(sidebarShortcutHintYOffset)
                            )
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.14), value: showsCommandShortcutHints || alwaysShowShortcutHints)
                .frame(width: cachedSlotWidth, height: 16, alignment: .trailing)
            }

            // Remote pane host chip — pane-mixing model (distinct from the
            // peerMirror row gradient above): shows which host receives
            // input for THIS workspace's panes so a relay workspace isn't
            // just an anonymous shell CWD in the list.
            hostChip

            if let subtitle = latestNotificationText {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(activeSecondaryColor(0.8))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }

            if sidebarShowStatusPills, !tab.statusEntries.isEmpty {
                SidebarStatusPillsRow(
                    entries: tab.statusEntries.values.sorted(by: { (lhs, rhs) in
                        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                        return lhs.key < rhs.key
                    }),
                    isActive: usesInvertedActiveForeground,
                    onFocus: { updateSelection() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Active team indicator with inbox badge and expandable overview
            if let teamName = activeTeamName {
                teamIndicatorView(teamName: teamName)
            }

            // Latest log entry
            if sidebarShowLog, let latestLog = tab.logEntries.last {
                HStack(spacing: 4) {
                    Image(systemName: logLevelIcon(latestLog.level))
                        .font(.system(size: 8))
                        .foregroundColor(logLevelColor(latestLog.level, isActive: usesInvertedActiveForeground))
                    Text(latestLog.message)
                        .font(.system(size: 10))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Progress bar
            if sidebarShowProgress, let progress = tab.progress {
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(activeProgressTrackColor)
                            Capsule()
                                .fill(activeProgressFillColor)
                                .frame(width: max(0, geo.size.width * CGFloat(progress.value)))
                        }
                    }
                    .frame(height: 3)

                    if let label = progress.label {
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundColor(activeSecondaryColor(0.6))
                            .lineLimit(1)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Branch + directory row
            if sidebarBranchVerticalLayout {
                if !verticalLines.isEmpty {
                    HStack(alignment: .top, spacing: 3) {
                        if sidebarShowGitBranchIcon,
                           sidebarShowGitBranch,
                           verticalLines.contains(where: { $0.branch != nil }) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                                .foregroundColor(activeSecondaryColor(0.6))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(verticalLines.enumerated()), id: \.offset) { _, line in
                                HStack(spacing: 3) {
                                    if let branch = line.branch {
                                        Text(branch)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(activeSecondaryColor(0.75))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    if line.branch != nil, line.directory != nil {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 3))
                                            .foregroundColor(activeSecondaryColor(0.6))
                                            .padding(.horizontal, 1)
                                    }
                                    if let directory = line.directory {
                                        Text(directory)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(activeSecondaryColor(0.75))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                            }
                        }
                    }
                }
            } else if let dirRow = branchDirectoryRow {
                HStack(spacing: 3) {
                    if sidebarShowGitBranch && gitBranchSummaryText != nil && sidebarShowGitBranchIcon {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundColor(activeSecondaryColor(0.6))
                    }
                    Text(dirRow)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(activeSecondaryColor(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // Ports row
            if sidebarShowPorts, !tab.listeningPorts.isEmpty {
                Text(tab.listeningPorts.map { ":\($0)" }.joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(activeSecondaryColor(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.logEntries.count)
        .animation(.easeInOut(duration: 0.2), value: tab.progress != nil)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(activeTabGradientOrColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(activeBorderColor, lineWidth: activeBorderLineWidth)
                }
                .overlay(alignment: .leading) {
                    if showsLeadingRail {
                        Capsule(style: .continuous)
                            .fill(railColor)
                            .frame(width: 3)
                            .padding(.leading, 4)
                            .padding(.vertical, 5)
                            .offset(x: -1)
                    }
                }
        )
        .padding(.horizontal, 6)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        rowHeight = max(proxy.size.height, 1)
                    }
                    .onChange(of: proxy.size.height) { newHeight in
                        rowHeight = max(newHeight, 1)
                    }
            }
        }
        .contentShape(Rectangle())
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay {
            MiddleClickCapture {
                #if DEBUG
                dlog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=middleClick")
                #endif
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        }
        .overlay(alignment: .top) {
            if showsCenteredTopDropIndicator {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .offset(y: index == 0 ? 0 : -(rowSpacing / 2))
            }
        }
        .onDrag {
            #if DEBUG
            dlog("sidebar.onDrag tab=\(tab.id.uuidString.prefix(5))")
            #endif
            draggedTabId = tab.id
            dropIndicator = nil
            return SidebarTabDragPayload.provider(for: tab.id)
        }
        .onDrop(of: [SidebarTabDragPayload.typeIdentifier], delegate: SidebarTabDropDelegate(
            targetTabId: tab.id,
            tabManager: tabManager,
            draggedTabId: draggedTabIdBinding,
            selectedTabIds: selectedTabIdsBinding,
            lastSidebarSelectionIndex: lastSidebarSelectionIndexBinding,
            targetRowHeight: rowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: dropIndicatorBinding
        ))
        .onTapGesture {
            updateSelection()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityHint(Text("Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."))
        .accessibilityAction(named: Text("Move Up")) {
            moveBy(-1)
        }
        .accessibilityAction(named: Text("Move Down")) {
            moveBy(1)
        }
        .contextMenu {
            SidebarTabContextMenu(
                clickedID: tab.id,
                selectedTabIds: selectedTabIds,
                visibleTabIds: visibleTabIds,
                visibleIndex: visibleIndex,
                visibleWorkspaceCount: visibleTabIds.count,
                isPinned: tab.isPinned,
                hasCustomTitle: tab.hasCustomTitle,
                customColor: tab.customColor,
                hasTag: tab.tag != nil,
                onAction: handleContextMenuAction
            )
            .equatable()
        }
        .onAppear { updateCachedSlotWidth() }
        .onChange(of: workspaceShortcutLabel) { _ in updateCachedSlotWidth() }
        .onChange(of: sidebarShortcutHintXOffset) { _ in updateCachedSlotWidth() }
    }

    private var backgroundColor: Color {
        switch activeTabIndicatorStyle {
        case .leftRail:
            if isActive        { return Color.accentColor }
            if isMultiSelected { return Color.accentColor.opacity(0.25) }
            return Color.clear
        case .solidFill:
            if let custom = resolvedCustomTabColor {
                if isActive        { return custom }
                if isMultiSelected { return custom.opacity(0.35) }
                return custom.opacity(0.7)
            }
            if isActive        { return Color.accentColor }
            if isMultiSelected { return Color.accentColor.opacity(0.25) }
            return Color.clear
        }
    }

    /// Host-accent colors when this row is a live peer-mirror workspace;
    /// nil for local workspaces. Decision (2026-07-15): the peer signal
    /// lives on the sidebar row (selected = host-accent gradient,
    /// unselected = accent rail), not on the main-window titlebar. The
    /// sidebar palette never hashes onto the purple family, which is the
    /// local selected-row gradient below.
    private var peerAccentNSColors: [NSColor]? {
        guard let mirror = tab.peerMirror else { return nil }
        return PeerHostAccent.colors(for: mirror.lease.key)
    }

    private var activeTabGradientOrColor: AnyShapeStyle {
        if isActive && resolvedCustomTabColor == nil {
            let colors = peerAccentNSColors?.map { Color(nsColor: $0) } ?? [
                Color(red: 0.95, green: 0.45, blue: 0.55),  // soft pink
                Color(red: 0.55, green: 0.45, blue: 0.95),  // soft purple
                Color(red: 0.45, green: 0.55, blue: 0.95),  // soft blue
            ]
            return AnyShapeStyle(
                LinearGradient(
                    colors: colors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        return AnyShapeStyle(backgroundColor)
    }

    /// Unselected peer-mirror rows keep an always-on accent rail so the
    /// host identity reads without selecting the row.
    private var peerRailColor: Color? {
        guard !isActive, let colors = peerAccentNSColors, let first = colors.first
        else { return nil }
        return Color(nsColor: first).opacity(0.9)
    }

    private var railColor: Color {
        explicitRailColor ?? peerRailColor ?? .clear
    }

    private var explicitRailColor: Color? {
        guard activeTabIndicatorStyle == .leftRail,
              let custom = resolvedCustomTabColor else {
            return nil
        }
        return custom.opacity(0.95)
    }

    private var resolvedCustomTabColor: Color? {
        guard let hex = tab.customColor else { return nil }
        return WorkspaceTabColorSettings.displayColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        )
    }

    private func tabColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    private var showsCenteredTopDropIndicator: Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == tab.id && indicator.edge == .top {
            return true
        }

        guard indicator.edge == .bottom,
              let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }),
              currentIndex > 0
        else {
            return false
        }
        return tabManager.tabs[currentIndex - 1].id == indicator.tabId
    }

    private var accessibilityTitle: String {
        let position = (visibleIndex ?? index) + 1
        return "\(tab.title), workspace \(position) of \(visibleTabIds.count)"
    }

    private func moveBy(_ delta: Int) {
        guard let currentVisibleIndex = visibleIndex else { return }
        let targetVisibleIndex = currentVisibleIndex + delta
        guard targetVisibleIndex >= 0, targetVisibleIndex < visibleTabIds.count else { return }
        let targetID = visibleTabIds[targetVisibleIndex]
        guard let targetRawIndex = tabManager.tabs.firstIndex(where: { $0.id == targetID }) else { return }
        guard tabManager.reorderWorkspace(tabId: tab.id, toIndex: targetRawIndex) else { return }
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == tab.id }
        tabManager.selectTab(tab)
        selection = .tabs
    }

    private func updateSelection() {
        #if DEBUG
        let mods = NSEvent.modifierFlags
        var modStr = ""
        if mods.contains(.command) { modStr += "cmd " }
        if mods.contains(.shift) { modStr += "shift " }
        if mods.contains(.option) { modStr += "opt " }
        if mods.contains(.control) { modStr += "ctrl " }
        dlog("sidebar.select workspace=\(tab.id.uuidString.prefix(5)) modifiers=\(modStr.isEmpty ? "none" : modStr.trimmingCharacters(in: .whitespaces))")
        #endif
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let visibleIDSet = Set(visibleTabIds)
        selectedTabIds.formIntersection(visibleIDSet)

        if isShift,
           let lastIndex = lastSidebarSelectionIndex,
           tabManager.tabs.indices.contains(lastIndex) {
            let anchorID = tabManager.tabs[lastIndex].id
            let rangeIds = SidebarPresentationSettings.rangeSelectionIDs(
                anchorID: anchorID,
                targetID: tab.id,
                visibleWorkspaceIDs: visibleTabIds
            )
            guard !rangeIds.isEmpty else {
                selectedTabIds = [tab.id]
                lastSidebarSelectionIndex = index
                tabManager.selectTab(tab)
                selection = .tabs
                return
            }
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.contains(tab.id) {
                selectedTabIds.remove(tab.id)
            } else {
                selectedTabIds.insert(tab.id)
            }
        } else {
            selectedTabIds = [tab.id]
        }

        lastSidebarSelectionIndex = index
        tabManager.selectTab(tab)
        selection = .tabs
    }

    private func contextTargetIds() -> [UUID] {
        SidebarPresentationSettings.contextTargetIDs(
            clickedID: tab.id,
            selectedIDs: selectedTabIds,
            visibleWorkspaceIDs: visibleTabIds
        )
    }

    private func handleContextMenuAction(_ action: SidebarTabMenuAction) {
        switch action {
        case .setPinned(let shouldPin, let targetIds):
            for id in targetIds {
                if let target = tabManager.tabs.first(where: { $0.id == id }) {
                    tabManager.setPinned(target, pinned: shouldPin)
                }
            }
            syncSelectionAfterMutation()
        case .rename:
            promptRename()
        case .clearCustomTitle:
            tabManager.clearCustomTitle(tabId: tab.id)
        case .applyColor(let color, let targetIds):
            applyTabColor(color, targetIds: targetIds)
        case .chooseCustomColor(let targetIds):
            promptCustomColor(targetIds: targetIds)
        case .clearTag:
            tab.tag = nil
        case .setTag:
            ContentView.showWorkspaceTagPrompt(for: tab)
        case .move(let offset):
            moveBy(offset)
        case .moveToTop(let targetIds):
            tabManager.moveTabsToTop(Set(targetIds))
            syncSelectionAfterMutation()
        case .close(let targetIds):
            closeTabs(targetIds, allowPinned: true)
        case .closeOthers(let targetIds):
            closeOtherTabs(targetIds)
        case .closeBelow:
            closeTabsBelow(tabId: tab.id)
        case .closeAbove:
            closeTabsAbove(tabId: tab.id)
        case .markRead(let targetIds):
            markTabsRead(targetIds)
        case .markUnread(let targetIds):
            markTabsUnread(targetIds)
        }
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        let idsToClose = targetIds.filter { id in
            guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return false }
            return allowPinned || !tab.isPinned
        }
        for id in idsToClose {
            if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        }
        selectedTabIds.subtract(idsToClose)
        syncSelectionAfterMutation()
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        let keepIds = Set(targetIds)
        let idsToClose = visibleTabIds.filter { !keepIds.contains($0) }
        closeTabs(idsToClose, allowPinned: false)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = visibleTabIds.firstIndex(of: tabId) else { return }
        let idsToClose = Array(visibleTabIds.suffix(from: anchorIndex + 1))
        closeTabs(idsToClose, allowPinned: false)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = visibleTabIds.firstIndex(of: tabId) else { return }
        let idsToClose = Array(visibleTabIds.prefix(upTo: anchorIndex))
        closeTabs(idsToClose, allowPinned: false)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds {
            TerminalNotificationStore.shared.markRead(forTabId: id)
        }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds {
            TerminalNotificationStore.shared.markUnread(forTabId: id)
        }
    }

    private func syncSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map(\.id)).intersection(visibleTabIds)
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty,
           let selectedId = tabManager.selectedTabId,
           existingIds.contains(selectedId) {
            selectedTabIds = [selectedId]
        }
        let anchorID = tabManager.selectedTabId.flatMap { existingIds.contains($0) ? $0 : nil }
            ?? visibleTabIds.first(where: { selectedTabIds.contains($0) })
        if let anchorID {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == anchorID }
        } else {
            lastSidebarSelectionIndex = nil
        }
    }

    private var latestNotificationText: String? {
        notificationSummary.displayText
    }

    private var activeTeam: TeamOrchestrator.Team? {
        activeTeamName.flatMap { TeamOrchestrator.shared.teams[$0] }
    }

    private func teamAttentionCount(teamName: String) -> Int {
        TeamOrchestrator.shared.inboxItems(teamName: teamName).count
    }

    @ViewBuilder
    private func teamIndicatorView(teamName: String) -> some View {
        // Wrapped in a per-team view so @AppStorage for expansion state
        // can drive both the chevron orientation and the inline agent list
        // in a single SwiftUI subtree.
        TeamIndicatorBlock(
            teamName: teamName,
            activeTeam: activeTeam,
            attentionCount: teamAttentionCount(teamName: teamName),
            badgeForegroundColor: activeSecondaryColor(0.9),
            teamContextMenuBuilder: { AnyView(self.teamRowContextMenu(teamName: teamName)) },
            agentDotBuilder: { agent in AnyView(self.agentDot(teamName: teamName, agent: agent)) }
        )
    }

    @ViewBuilder
    private func agentDot(teamName: String, agent: TeamOrchestrator.AgentMember) -> some View {
        let state = TeamOrchestrator.shared.agentState(teamName: teamName, agentName: agent.name)
        let color: Color = switch state {
        case "running":      .green
        case "blocked":      .red
        case "review_ready": .yellow
        case "error":        .red.opacity(0.7)
        case "parked":       .gray.opacity(0.5)
        default:             .gray  // idle
        }

        ZStack {
            if state == "running" {
                // in_progress task → animated spinner replaces static dot
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .opacity(0.85)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                // Phase 2: parked → small pause glyph overlay so the gray dot is
                // distinguishable from plain idle.
                if state == "parked" {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 4, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
            }
        }
        .frame(width: 8, height: 8)
        .help("\(agent.name): \(state)")
    }

    // MARK: - Phase 2.5 — Team-row context menu

    @ViewBuilder
    private func teamRowContextMenu(teamName: String) -> some View {
        Button("Park all agents") {
            guard let team = TeamOrchestrator.shared.teams[teamName] else { return }
            for agent in team.agents {
                TeamOrchestrator.shared.parkAgent(teamName: teamName, agentName: agent.name)
            }
        }
        Button("Recycle all agents…") {
            confirmAndRecycleAllAgents(teamName: teamName)
        }
        Button("Destroy team…") {
            confirmAndDestroyTeam(teamName: teamName)
        }
        Divider()
        Button("Reveal worktree in Finder") {
            revealWorktreeInFinder(teamName: teamName)
        }
        .disabled(TeamOrchestrator.shared.teams[teamName]?.sharedWorktreePath == nil
                  && TeamOrchestrator.shared.teams[teamName]?.agents.first?.worktreePath == nil)
    }

    private func confirmAndRecycleAllAgents(teamName: String) {
        guard let team = TeamOrchestrator.shared.teams[teamName] else { return }
        let agentCount = team.agents.count
        let alert = NSAlert()
        alert.messageText = "Recycle all agents in \"\(teamName)\"?"
        alert.informativeText = "\(agentCount) agent pane\(agentCount == 1 ? "" : "s") will be hard-restarted — full transcripts discarded. Agents with active tasks will be skipped."
        alert.addButton(withTitle: "Recycle")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.presentAsSheet { response in
            guard response == .alertFirstButtonReturn else { return }
            let (recycled, skipped) = TeamOrchestrator.shared.recycleAllAgents(teamName: teamName, force: false)
            #if DEBUG
            dlog("recycleAll teamName=\(teamName) recycled=\(recycled) skipped=\(skipped)")
            #endif
            _ = (recycled, skipped)
        }
    }

    private func confirmAndDestroyTeam(teamName: String) {
        let alert = NSAlert()
        alert.messageText = "Destroy team \"\(teamName)\"?"
        alert.informativeText = "All agent panes will be closed. The session metadata is preserved (resumable for the configured retention window)."
        alert.addButton(withTitle: "Destroy")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.presentAsSheet { response in
            guard response == .alertFirstButtonReturn else { return }
            _ = TeamOrchestrator.shared.destroyTeam(name: teamName, tabManager: self.tabManager)
        }
    }

    private func revealWorktreeInFinder(teamName: String) {
        guard let team = TeamOrchestrator.shared.teams[teamName] else { return }
        let path = team.sharedWorktreePath
            ?? team.agents.first(where: { $0.worktreePath != nil })?.worktreePath
            ?? team.workingDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private var branchDirectoryRow: String? {
        var parts: [String] = []

        // Git branch (if enabled and available)
        if sidebarShowGitBranch, let gitSummary = gitBranchSummaryText {
            parts.append(gitSummary)
        }

        // Directory summary
        if let dirs = directorySummaryText {
            parts.append(dirs)
        }

        let result = parts.joined(separator: " · ")
        return result.isEmpty ? nil : result
    }

    private var gitBranchSummaryText: String? {
        let lines = gitBranchSummaryLines
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private var gitBranchSummaryLines: [String] {
        tab.sidebarGitBranchesInDisplayOrder().map { branch in
            var text = branch.branch
            if branch.isDirty {
                if let count = branch.dirtyFileCount, count > 0 {
                    text += "* (\(count))"
                } else {
                    text += "*"
                }
            }
            return text
        }
    }

    private var directorySummaryText: String? {
        guard !tab.panels.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen: Set<String> = []
        var entries: [String] = []
        for panelId in tab.sidebarOrderedPanelIds() {
            let directory = tab.panelDirectories[panelId] ?? tab.currentDirectory
            let shortened = shortenPath(directory, home: home)
            guard !shortened.isEmpty else { continue }
            if seen.insert(shortened).inserted {
                entries.append(shortened)
            }
        }
        return entries.isEmpty ? nil : entries.joined(separator: " | ")
    }

    private func logLevelIcon(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func logLevelColor(_ level: SidebarLogLevel, isActive: Bool) -> Color {
        if isActive {
            switch level {
            case .info: return .white.opacity(0.5)
            case .progress: return .white.opacity(0.8)
            case .success: return .white.opacity(0.9)
            case .warning: return .white.opacity(0.9)
            case .error: return .white.opacity(0.9)
            }
        }
        switch level {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    private func applyTabColor(_ hex: String?, targetIds: [UUID]) {
        for targetId in targetIds {
            tabManager.setTabColor(tabId: targetId, color: hex)
        }
    }

    private func promptCustomColor(targetIds: [UUID]) {
        let alert = NSAlert()
        alert.messageText = "Custom Tab Color"
        alert.informativeText = "Enter a hex color in the format #RRGGBB."

        let seed = tab.customColor ?? WorkspaceTabColorSettings.customColors().first ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        alert.presentAsSheet { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
                self.showInvalidColorAlert(input.stringValue)
                return
            }
            self.applyTabColor(normalized, targetIds: targetIds)
        }
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Invalid Color"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = "Enter a hex color in the format #RRGGBB."
        } else {
            alert.informativeText = "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB."
        }
        alert.addButton(withTitle: "OK")
        alert.presentAsSheet()
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a custom name for this workspace."
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = "Workspace name"
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
        alert.presentAsSheet { response in
            guard response == .alertFirstButtonReturn else { return }
            self.tabManager.setCustomTitle(tabId: self.tab.id, title: input.stringValue)
        }
    }
}

private enum SidebarTabMenuAction {
    case setPinned(Bool, [UUID])
    case rename
    case clearCustomTitle
    case applyColor(String?, [UUID])
    case chooseCustomColor([UUID])
    case clearTag
    case setTag
    case move(Int)
    case moveToTop([UUID])
    case close([UUID])
    case closeOthers([UUID])
    case closeBelow
    case closeAbove
    case markRead([UUID])
    case markUnread([UUID])
}

private struct SidebarTabContextMenu: View, Equatable {
    @EnvironmentObject private var notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var activeIndicatorStyleRaw = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue

    let clickedID: UUID
    let selectedTabIds: Set<UUID>
    let visibleTabIds: [UUID]
    let visibleIndex: Int?
    let visibleWorkspaceCount: Int
    let isPinned: Bool
    let hasCustomTitle: Bool
    let customColor: String?
    let hasTag: Bool
    let onAction: (SidebarTabMenuAction) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clickedID == rhs.clickedID &&
            lhs.selectedTabIds == rhs.selectedTabIds &&
            lhs.visibleTabIds == rhs.visibleTabIds &&
            lhs.visibleIndex == rhs.visibleIndex &&
            lhs.visibleWorkspaceCount == rhs.visibleWorkspaceCount &&
            lhs.isPinned == rhs.isPinned &&
            lhs.hasCustomTitle == rhs.hasCustomTitle &&
            lhs.customColor == rhs.customColor &&
            lhs.hasTag == rhs.hasTag
    }

    @ViewBuilder
    var body: some View {
        let targetIds = SidebarPresentationSettings.contextTargetIDs(
            clickedID: clickedID,
            selectedIDs: selectedTabIds,
            visibleWorkspaceIDs: visibleTabIds
        )
        let palette = WorkspaceTabColorSettings.palette()
        let renameShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let closeShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        let shouldPin = !isPinned
        let plural = targetIds.count > 1

        Button(plural ? (shouldPin ? "Pin Workspaces" : "Unpin Workspaces") : (shouldPin ? "Pin Workspace" : "Unpin Workspace")) {
            onAction(.setPinned(shouldPin, targetIds))
        }

        shortcutButton("Rename Workspace…", shortcut: renameShortcut) { onAction(.rename) }

        if hasCustomTitle {
            Button("Remove Custom Workspace Name") { onAction(.clearCustomTitle) }
        }

        Menu("Tab Color") {
            if customColor != nil {
                Button { onAction(.applyColor(nil, targetIds)) } label: {
                    Label("Clear Color", systemImage: "xmark.circle")
                }
            }
            Button { onAction(.chooseCustomColor(targetIds)) } label: {
                Label("Choose Custom Color…", systemImage: "paintpalette")
            }
            if !palette.isEmpty { Divider() }
            ForEach(palette) { entry in
                Button { onAction(.applyColor(entry.hex, targetIds)) } label: {
                    Label { Text(entry.name) } icon: {
                        Image(nsImage: coloredCircleImage(color: swatchColor(for: entry.hex)))
                    }
                }
            }
        }

        if hasTag { Button("Clear Tag") { onAction(.clearTag) } }
        Button("Set Tag…") { onAction(.setTag) }
        Divider()

        Button("Move Up") { onAction(.move(-1)) }.disabled(visibleIndex == 0)
        Button("Move Down") { onAction(.move(1)) }
            .disabled(visibleIndex.map { $0 >= visibleWorkspaceCount - 1 } ?? true)
        Button("Move to Top") { onAction(.moveToTop(targetIds)) }.disabled(targetIds.isEmpty)
        Divider()

        shortcutButton(plural ? "Close Workspaces" : "Close Workspace", shortcut: closeShortcut) {
            onAction(.close(targetIds))
        }
            .disabled(targetIds.isEmpty)
        Button("Close Other Workspaces") { onAction(.closeOthers(targetIds)) }
            .disabled(visibleWorkspaceCount <= 1 || targetIds.count == visibleWorkspaceCount)
        Button("Close Workspaces Below") { onAction(.closeBelow) }
            .disabled(visibleIndex.map { $0 >= visibleWorkspaceCount - 1 } ?? true)
        Button("Close Workspaces Above") { onAction(.closeAbove) }.disabled(visibleIndex == 0)
        Divider()

        Button(plural ? "Mark Workspaces as Read" : "Mark Workspace as Read") {
            onAction(.markRead(targetIds))
        }
            .disabled(!hasUnreadNotifications(in: targetIds))
        Button(plural ? "Mark Workspaces as Unread" : "Mark Workspace as Unread") {
            onAction(.markUnread(targetIds))
        }
            .disabled(!hasReadNotifications(in: targetIds))
    }

    @ViewBuilder
    private func shortcutButton(_ title: String, shortcut: StoredShortcut, action: @escaping () -> Void) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(title, action: action).keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(title, action: action)
        }
    }

    private func hasUnreadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && !$0.isRead }
    }

    private func hasReadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && $0.isRead }
    }

    private func swatchColor(for hex: String) -> NSColor {
        let activeIndicatorStyle = SidebarActiveTabIndicatorSettings.resolvedStyle(
            rawValue: activeIndicatorStyleRaw
        )
        return WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }
}

// MARK: - Phase 2.5 — Inline Team Expansion

/// A single team's sidebar indicator block: chevron + name capsule, status
/// dots row, and (when expanded) indented agent list. Owns the `@AppStorage`
/// for its chevron state so toggling persists across launches AND drives the
/// inline-list visibility without forcing the parent view to redraw.
private struct TeamIndicatorBlock: View {
    let teamName: String
    let activeTeam: TeamOrchestrator.Team?
    let attentionCount: Int
    let badgeForegroundColor: Color
    let teamContextMenuBuilder: () -> AnyView
    let agentDotBuilder: (TeamOrchestrator.AgentMember) -> AnyView
    @AppStorage private var isExpanded: Bool

    // P0-2: watch status chip + sheet state
    @State private var showWatchConfig = false
    @State private var watchChipText: String? = nil
    @State private var watchEnabled = false

    init(
        teamName: String,
        activeTeam: TeamOrchestrator.Team?,
        attentionCount: Int,
        badgeForegroundColor: Color,
        teamContextMenuBuilder: @escaping () -> AnyView,
        agentDotBuilder: @escaping (TeamOrchestrator.AgentMember) -> AnyView
    ) {
        self.teamName = teamName
        self.activeTeam = activeTeam
        self.attentionCount = attentionCount
        self.badgeForegroundColor = badgeForegroundColor
        self.teamContextMenuBuilder = teamContextMenuBuilder
        self.agentDotBuilder = agentDotBuilder
        self._isExpanded = AppStorage(wrappedValue: false, "sidebar.team.\(teamName).expanded")
    }

    private var workingDirectory: String {
        TeamOrchestrator.shared.teams[teamName]?.workingDirectory ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 8))
                        Text(teamName)
                            .font(.system(size: 10, weight: .medium))

                        if attentionCount > 0 {
                            Text("\(attentionCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(attentionCount > 2 ? Color.red : Color.orange))
                        }
                    }
                    .foregroundColor(badgeForegroundColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    // Existing team actions
                    teamContextMenuBuilder()
                    // P0-2: Watch actions
                    Divider()
                    Button("Configure Watch…") {
                        showWatchConfig = true
                    }
                    Button("Stop Watch") {
                        let params: [String: Any] = ["team_id": teamName]
                        _ = TermMeshDaemon.shared.rpcCallRaw(method: "watch.off", params: params)
                        refreshWatchChip()
                    }
                    .disabled(!watchEnabled)
                    // R4: watch.trigger_now — fires one immediate check, bypassing the interval
                    Button("Run Watch Check Now") {
                        let tn = teamName
                        DispatchQueue.global(qos: .userInitiated).async {
                            let raw = TermMeshDaemon.shared.rpcCallRaw(
                                method: "watch.trigger_now", params: ["team_id": tn])
                            DispatchQueue.main.async {
                                guard let raw,
                                      let data = raw.data(using: .utf8),
                                      let json = try? JSONSerialization.jsonObject(with: data)
                                            as? [String: Any]
                                else {
                                    let a = NSAlert()
                                    a.messageText = "Watch check failed"
                                    a.informativeText = "Could not reach the daemon"
                                    a.alertStyle = .warning
                                    a.runModal()
                                    return
                                }
                                if (json["status"] as? String) == "rejected" {
                                    let reason = json["reason"] as? String ?? "in-flight or disabled"
                                    let a = NSAlert()
                                    a.messageText = "Watch check skipped"
                                    a.informativeText = reason.prefix(1).uppercased() + reason.dropFirst()
                                    a.alertStyle = .informational
                                    a.runModal()
                                }
                                // status == "ok": silent success
                            }
                        }
                    }
                    .disabled(!watchEnabled)
                }
            }

            // P0-2: watch status chip (shown when watch is enabled)
            if let chipText = watchChipText {
                Text(chipText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
            }

            if let team = activeTeam {
                HStack(spacing: 3) {
                    ForEach(team.agents, id: \.agentInstanceId) { agent in
                        agentDotBuilder(agent)
                    }
                }
                .padding(.leading, 4)

                if isExpanded {
                    ExpandedTeamAgentList(team: team)
                        .padding(.leading, 4)
                }
            }
        }
        .onAppear { refreshWatchChip() }
        .sheet(isPresented: $showWatchConfig, onDismiss: { refreshWatchChip() }) {
            WatchConfigSheet(teamName: teamName, workingDirectory: workingDirectory)
                .frame(width: 480)
        }
    }

    private func refreshWatchChip() {
        let tn = teamName
        let wd = workingDirectory
        DispatchQueue.global(qos: .utility).async {
            let params: [String: Any] = ["team_id": tn, "working_directory": wd]
            guard let raw = TermMeshDaemon.shared.rpcCallRaw(method: "watch.status", params: params),
                  let data = raw.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                DispatchQueue.main.async { watchChipText = nil; watchEnabled = false }
                return
            }
            let w: [String: Any]?
            if let watch = root["watch"] as? [String: Any] {
                w = watch
            } else if let watches = root["watches"] as? [[String: Any]] {
                w = watches.first { ($0["team_id"] as? String) == tn }
            } else {
                w = nil
            }
            guard let watch = w else {
                DispatchQueue.main.async { watchChipText = nil; watchEnabled = false }
                return
            }
            let enabled = watch["enabled"] as? Bool ?? false
            let chip: String? = enabled ? Self.buildWatchChip(from: watch) : nil
            DispatchQueue.main.async {
                watchEnabled = enabled
                watchChipText = chip
            }
        }
    }

    private static func buildWatchChip(from w: [String: Any]) -> String {
        let target = w["target"] as? String
        let workers = w["workers"] as? [String] ?? []
        let stance = w["stance"] as? String ?? "critic"
        let nextTick = w["next_tick"] as? Int
        let lastError = w["last_error"] as? String
        let dupWarning = w["duplicate_name_warning"] as? String

        if let err = lastError, !err.isEmpty {
            return "Watch: Error · \(err.prefix(20))"
        }
        let targetLabel: String
        if let t = target, t != "all", !t.isEmpty {
            targetLabel = t
        } else {
            targetLabel = workers.isEmpty ? "All workers" : "All · \(workers.count)"
        }
        let stanceShort = String(stance.prefix(4))
        // R3: ⚠ prefix when duplicate worker names were detected (chip-level hint).
        let dupPrefix = dupWarning != nil ? "⚠ " : ""
        if let next = nextTick {
            let remaining = next - Int(Date().timeIntervalSince1970)
            let mins = max(0, remaining / 60)
            let secs = max(0, remaining % 60)
            let timeStr = mins > 0 ? "\(mins)m\(String(format: "%02d", secs))s" : "\(secs)s"
            return "\(dupPrefix)Watch: \(targetLabel) · \(stanceShort) · \(timeStr)"
        }
        return "\(dupPrefix)Watch: \(targetLabel) · \(stanceShort)"
    }
}

/// Indented agent list shown when a team row is expanded. Subscribes to
/// `TeamDataStore.shared` so it re-renders on `agent.usage_tick` pushes.
/// Lives in a separate view so the parent row body does not re-evaluate on
/// every usage update (collapsed teams pay nothing).
private struct ExpandedTeamAgentList: View {
    let team: TeamOrchestrator.Team
    @ObservedObject private var dataStore = TeamDataStore.shared
    @ObservedObject private var orchestrator = TeamOrchestrator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Leader runs its own CLI session; the daemon attributes its token
            // usage under the reserved `__leader__` name (see socket.rs).
            if team.leaderMode == "claude" {
                ExpandedLeaderRow(teamName: team.id, leaderMode: team.leaderMode)
            }
            ForEach(team.agents, id: \.agentInstanceId) { agent in
                ExpandedAgentRow(teamName: team.id, agent: agent)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

/// Reserved usage-tick name the daemon broadcasts the leader pane's token
/// usage under. Must stay in sync with `LEADER_USAGE_NAME` in socket.rs.
private let leaderUsageName = "__leader__"

/// A single expanded leader row: 👑 + "leader" + CLI + token-usage column.
/// The leader is not a `team.agents` member, so it gets its own lightweight
/// row that reads usage from the reserved `__leader__` key.
private struct ExpandedLeaderRow: View {
    let teamName: String
    let leaderMode: String
    @ObservedObject private var dataStore = TeamDataStore.shared

    private var usage: AgentUsageSnapshot? {
        dataStore.agentUsage[teamName]?[leaderUsageName]
    }

    private var tokenLabel: String {
        guard let u = usage, u.updatedAt != .distantPast else { return "—" }
        return "\(compactToken(u.inputTokens))↑ \(compactToken(u.outputTokens))↓"
    }

    private var tokenTooltip: String {
        guard let u = usage, u.updatedAt != .distantPast else { return "No token data yet." }
        let total = u.cacheReadTokens &+ u.cacheCreationTokens
        let base = "input \(u.inputTokens) · output \(u.outputTokens)"
        if total > 0, let ratio = u.cacheHitRatio {
            let pct = Int((ratio * 100).rounded())
            return "\(base)\ncache hit \(pct)% · \(compactToken(u.cacheReadTokens)) cached · \(compactToken(u.cacheCreationTokens)) fresh"
        }
        return base
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("👑")
                .font(.system(size: 9))
                .frame(width: 10, height: 10)

            Text("leader")
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)

            Text(leaderMode)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Text(tokenLabel)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(tokenTooltip)
        }
        .contentShape(Rectangle())
    }
}

/// A single expanded agent row: state dot + name + relative activity time +
/// optional branch + token-usage column + status label.
private struct ExpandedAgentRow: View {
    let teamName: String
    let agent: TeamOrchestrator.AgentMember
    @ObservedObject private var dataStore = TeamDataStore.shared
    @ObservedObject private var orchestrator = TeamOrchestrator.shared
    // P0-3: Watch This Agent sheet
    @State private var showWatchConfig = false

    private var state: String {
        TeamOrchestrator.shared.agentState(teamName: teamName, agentName: agent.name)
    }

    private var stateColor: Color {
        switch state {
        case "running":      return .green
        case "blocked":      return .red
        case "review_ready": return .yellow
        case "error":        return .red.opacity(0.7)
        case "parked":       return .gray.opacity(0.5)
        default:             return .gray  // idle
        }
    }

    /// SF Symbol overlay on the status dot. Only present for states that
    /// otherwise look like idle (parked) or that demand attention (needs_input
    /// surfaced via `review_ready` → exclamationmark).
    private var stateGlyph: String? {
        switch state {
        case "parked": return "pause.fill"
        case "review_ready", "blocked": return "exclamationmark"
        default: return nil
        }
    }

    private var usage: AgentUsageSnapshot? {
        dataStore.agentUsage[teamName]?[agent.name]
    }

    private var tokenLabel: String {
        guard let u = usage, u.updatedAt != .distantPast else { return "—" }
        return "\(compactToken(u.inputTokens))↑ \(compactToken(u.outputTokens))↓"
    }

    private var tokenTooltip: String {
        guard let u = usage, u.updatedAt != .distantPast else { return "No token data yet." }
        let total = u.cacheReadTokens &+ u.cacheCreationTokens
        let base = "input \(u.inputTokens) · output \(u.outputTokens)"
        if total > 0, let ratio = u.cacheHitRatio {
            let pct = Int((ratio * 100).rounded())
            return "\(base)\ncache hit \(pct)% · \(compactToken(u.cacheReadTokens)) cached · \(compactToken(u.cacheCreationTokens)) fresh"
        }
        return base
    }

    private var relativeActivity: String {
        // Prefer usage update; fall back to agent createdAt.
        let anchor: Date = (usage?.updatedAt ?? .distantPast) > agent.createdAt
            ? (usage?.updatedAt ?? agent.createdAt)
            : agent.createdAt
        return Self.compactRelative(date: anchor)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Status dot + optional glyph overlay.
            ZStack {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                if let glyph = stateGlyph {
                    Image(systemName: glyph)
                        .font(.system(size: 5, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
            }
            .frame(width: 10, height: 10)

            Text(agent.name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)

            Text(relativeActivity)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            if let branch = agent.worktreeBranch, !branch.isEmpty {
                Text(branch)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if state == "parked" {
                Text("[parked]")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text(tokenLabel)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(tokenTooltip)
        }
        .help(agent.worktreePath ?? agent.workspaceId.uuidString)
        .contentShape(Rectangle())
        .contextMenu {
            agentRowContextMenu()
        }
        .sheet(isPresented: $showWatchConfig) {
            let wd = TeamOrchestrator.shared.teams[teamName]?.workingDirectory ?? ""
            WatchConfigSheet(
                teamName: teamName,
                workingDirectory: wd,
                prefillTarget: agent.name
            )
            .frame(width: 480)
        }
    }

    @ViewBuilder
    private func agentRowContextMenu() -> some View {
        Button("Send message…") {
            promptAndSendMessage()
        }
        .keyboardShortcut(.return, modifiers: .command)

        Button("Park now") {
            TeamOrchestrator.shared.parkAgent(teamName: teamName, agentName: agent.name)
        }
        .disabled(state == "parked")

        Button("Unpark") {
            TeamOrchestrator.shared.unparkAgent(teamName: teamName, agentName: agent.name)
        }
        .disabled(state != "parked")

        // Mirror the terminal-pane right-click menu (GhosttyTerminalView) so the
        // agent's own sidebar row also exposes recycle — the most discoverable
        // place to look for it. recycleAgent() guards active non-terminal tasks
        // unless force is set, so both variants are always offered.
        Button("Recycle Agent") {
            TeamOrchestrator.shared.recycleAgent(teamName: teamName, agentName: agent.name, force: false)
        }

        Button("Recycle Agent (Force)") {
            TeamOrchestrator.shared.recycleAgent(teamName: teamName, agentName: agent.name, force: true)
        }

        Divider()

        Button("Copy session id") {
            copySessionId()
        }

        Button("View logs") {
            revealLogsInFinder()
        }

        Divider()

        // P0-3: Watch This Agent — opens WatchConfigSheet with this agent pre-filled as target
        Button("Watch This Agent…") {
            showWatchConfig = true
        }

        Divider()

        Button("Detach (keep session)") {
            // Destroy team in-memory but session metadata stays archived for resume.
            confirmDestroyTeam(discardSession: false)
        }

        Button("Destroy (discard session)") {
            confirmDestroyTeam(discardSession: true)
        }
    }

    private func promptAndSendMessage() {
        let alert = NSAlert()
        alert.messageText = "Send message to \(agent.name)"
        alert.informativeText = "The message will be delivered to the leader pane for routing."
        let input = NSTextField(string: "")
        input.placeholderString = "Message"
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(input)
        }
        alert.presentAsSheet { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // Use TeamDataStore for delivery so we work in both pane and headless modes.
            TeamDataStore.shared.postMessage(
                teamName: teamName,
                from: "leader",
                to: agent.name,
                content: text,
                type: "note"
            )
        }
    }

    private func copySessionId() {
        // Phase 2.5 — AgentMember carries parentSessionId; per-agent session IDs
        // are stored on the daemon side. Best-effort: copy parentSessionId.
        let sessionId = agent.parentSessionId ?? agent.id
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionId, forType: .string)
    }

    private func revealLogsInFinder() {
        // Reveal the agent metadata JSON under ~/.term-mesh/headless/<uuid>/agents/.
        // We don't have direct access to the team UUID without a lookup —
        // fall back to the team's results directory if uuid is unavailable.
        let home = NSHomeDirectory()
        if let teamUuid = TeamOrchestrator.shared.teamUuid(for: teamName) {
            let path = "\(home)/.term-mesh/headless/\(teamUuid)/agents/\(agent.name).json"
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "\(home)/.term-mesh/headless/\(teamUuid)/agents")
                return
            }
            // Fall back to the team directory.
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "\(home)/.term-mesh/headless/\(teamUuid)")
            return
        }
        let resultsDir = "/tmp/term-mesh-team-\(teamName)"
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: resultsDir)
    }

    private func confirmDestroyTeam(discardSession: Bool) {
        let alert = NSAlert()
        alert.messageText = discardSession
            ? "Destroy team \"\(teamName)\"?"
            : "Detach team \"\(teamName)\"?"
        alert.informativeText = discardSession
            ? "All agent panes will be closed and the session archive will be removed at the next GC sweep."
            : "All agent panes will be closed but the session archive remains resumable until the retention window expires."
        alert.addButton(withTitle: discardSession ? "Destroy" : "Detach")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.presentAsSheet { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: agent.workspaceId) else { return }
            _ = TeamOrchestrator.shared.destroyTeam(name: teamName, tabManager: tabManager)
        }
    }

    private static func compactRelative(date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 1 { return "now" }
        if elapsed < 60 { return "\(Int(elapsed))s" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h" }
        return "\(Int(elapsed / 86400))d"
    }
}

struct SidebarStatusPillsRow: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(isActive ? .white.opacity(0.8) : .secondary)
                .lineLimit(isExpanded ? nil : 3)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onFocus()
                    guard shouldShowToggle else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }

            if shouldShowToggle {
                Button(isExpanded ? "Show less" : "Show more") {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? .white.opacity(0.65) : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .help(statusText)
    }

    private var statusText: String {
        entries
            .map { entry in
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
                return entry.key
            }
            .joined(separator: "\n")
    }

    private var shouldShowToggle: Bool {
        entries.count > 1 || statusText.count > 120
    }
}

enum SidebarDropEdge: Equatable {
    case top
    case bottom
}

struct SidebarDropIndicator: Equatable {
    let tabId: UUID?
    let edge: SidebarDropEdge
}

enum SidebarDropPlanner {
    static func indicator(
        draggedTabId: UUID?,
        targetTabId: UUID?,
        tabIds: [UUID],
        pointerY: CGFloat? = nil,
        targetHeight: CGFloat? = nil
    ) -> SidebarDropIndicator? {
        guard tabIds.count > 1, let draggedTabId else { return nil }
        guard let fromIndex = tabIds.firstIndex(of: draggedTabId) else { return nil }

        let insertionPosition: Int
        if let targetTabId {
            guard let targetTabIndex = tabIds.firstIndex(of: targetTabId) else { return nil }
            let edge: SidebarDropEdge
            if let pointerY, let targetHeight {
                edge = edgeForPointer(locationY: pointerY, targetHeight: targetHeight)
            } else {
                edge = preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds)
            }
            insertionPosition = (edge == .bottom) ? targetTabIndex + 1 : targetTabIndex
        } else {
            insertionPosition = tabIds.count
        }

        let targetIndex = resolvedTargetIndex(from: fromIndex, insertionPosition: insertionPosition, totalCount: tabIds.count)
        guard targetIndex != fromIndex else { return nil }
        return indicatorForInsertionPosition(insertionPosition, tabIds: tabIds)
    }

    static func targetIndex(
        draggedTabId: UUID,
        targetTabId: UUID?,
        indicator: SidebarDropIndicator?,
        tabIds: [UUID]
    ) -> Int? {
        guard let fromIndex = tabIds.firstIndex(of: draggedTabId) else { return nil }

        let insertionPosition: Int
        if let indicator, let indicatorInsertion = insertionPositionForIndicator(indicator, tabIds: tabIds) {
            insertionPosition = indicatorInsertion
        } else if let targetTabId {
            guard let targetTabIndex = tabIds.firstIndex(of: targetTabId) else { return nil }
            let edge = (indicator?.tabId == targetTabId)
                ? (indicator?.edge ?? preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds))
                : preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds)
            insertionPosition = (edge == .bottom) ? targetTabIndex + 1 : targetTabIndex
        } else {
            insertionPosition = tabIds.count
        }

        return resolvedTargetIndex(from: fromIndex, insertionPosition: insertionPosition, totalCount: tabIds.count)
    }

    private static func indicatorForInsertionPosition(_ insertionPosition: Int, tabIds: [UUID]) -> SidebarDropIndicator {
        let clampedInsertion = max(0, min(insertionPosition, tabIds.count))
        if clampedInsertion >= tabIds.count {
            return SidebarDropIndicator(tabId: nil, edge: .bottom)
        }
        return SidebarDropIndicator(tabId: tabIds[clampedInsertion], edge: .top)
    }

    private static func insertionPositionForIndicator(_ indicator: SidebarDropIndicator, tabIds: [UUID]) -> Int? {
        if let tabId = indicator.tabId {
            guard let targetTabIndex = tabIds.firstIndex(of: tabId) else { return nil }
            return indicator.edge == .bottom ? targetTabIndex + 1 : targetTabIndex
        }
        return tabIds.count
    }

    private static func preferredEdge(fromIndex: Int, targetTabId: UUID, tabIds: [UUID]) -> SidebarDropEdge {
        guard let targetIndex = tabIds.firstIndex(of: targetTabId) else { return .top }
        return fromIndex < targetIndex ? .bottom : .top
    }

    static func edgeForPointer(locationY: CGFloat, targetHeight: CGFloat) -> SidebarDropEdge {
        guard targetHeight > 0 else { return .top }
        let clampedY = min(max(locationY, 0), targetHeight)
        return clampedY < (targetHeight / 2) ? .top : .bottom
    }

    private static func resolvedTargetIndex(from sourceIndex: Int, insertionPosition: Int, totalCount: Int) -> Int {
        let clampedInsertion = max(0, min(insertionPosition, totalCount))
        let adjusted = clampedInsertion > sourceIndex ? clampedInsertion - 1 : clampedInsertion
        return max(0, min(adjusted, max(0, totalCount - 1)))
    }
}
