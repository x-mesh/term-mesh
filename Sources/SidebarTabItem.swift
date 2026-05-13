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

struct TabItemView: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var tab: Tab
    let index: Int
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let showsCommandShortcutHints: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    @State private var isHovering = false
    @State private var rowHeight: CGFloat = 1
    @State private var cachedSlotWidth: CGFloat = 28
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

    var isActive: Bool {
        tabManager.selectedTabId == tab.id
    }

    var isMultiSelected: Bool {
        selectedTabIds.contains(tab.id)
    }

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
        explicitRailColor != nil
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
        WorkspaceShortcutMapper.commandDigitForWorkspace(at: index, workspaceCount: tabManager.tabs.count)
    }

    private var showCloseButton: Bool {
        isHovering && tabManager.tabs.count > 1 && !(showsCommandShortcutHints || alwaysShowShortcutHints)
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "⌘\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsCommandShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                let unreadCount = notificationStore.unreadCount(forTabId: tab.id)
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
                if !verticalBranchDirectoryLines.isEmpty {
                    HStack(alignment: .top, spacing: 3) {
                        if sidebarShowGitBranchIcon, sidebarShowGitBranch, verticalRowsContainBranch {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                                .foregroundColor(activeSecondaryColor(0.6))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(verticalBranchDirectoryLines.enumerated()), id: \.offset) { _, line in
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
            draggedTabId: $draggedTabId,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: rowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: $dropIndicator
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
            let targetIds = contextTargetIds()
            let tabColorPalette = WorkspaceTabColorSettings.palette()
            let shouldPin = !tab.isPinned
            let pinLabel = targetIds.count > 1
                ? (shouldPin ? "Pin Workspaces" : "Unpin Workspaces")
                : (shouldPin ? "Pin Workspace" : "Unpin Workspace")
            let closeLabel = targetIds.count > 1 ? "Close Workspaces" : "Close Workspace"
            let markReadLabel = targetIds.count > 1 ? "Mark Workspaces as Read" : "Mark Workspace as Read"
            let markUnreadLabel = targetIds.count > 1 ? "Mark Workspaces as Unread" : "Mark Workspace as Unread"
            let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
            let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
            Button(pinLabel) {
                for id in targetIds {
                    if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                        tabManager.setPinned(tab, pinned: shouldPin)
                    }
                }
                syncSelectionAfterMutation()
            }

            if let key = renameWorkspaceShortcut.keyEquivalent {
                Button("Rename Workspace…") {
                    promptRename()
                }
                .keyboardShortcut(key, modifiers: renameWorkspaceShortcut.eventModifiers)
            } else {
                Button("Rename Workspace…") {
                    promptRename()
                }
            }

            if tab.hasCustomTitle {
                Button("Remove Custom Workspace Name") {
                    tabManager.clearCustomTitle(tabId: tab.id)
                }
            }

            Menu("Tab Color") {
                if tab.customColor != nil {
                    Button {
                        applyTabColor(nil, targetIds: targetIds)
                    } label: {
                        Label("Clear Color", systemImage: "xmark.circle")
                    }
                }

                Button {
                    promptCustomColor(targetIds: targetIds)
                } label: {
                    Label("Choose Custom Color…", systemImage: "paintpalette")
                }

                if !tabColorPalette.isEmpty {
                    Divider()
                }

                ForEach(tabColorPalette, id: \.id) { entry in
                    Button {
                        applyTabColor(entry.hex, targetIds: targetIds)
                    } label: {
                        Label {
                            Text(entry.name)
                        } icon: {
                            Image(nsImage: coloredCircleImage(color: tabColorSwatchColor(for: entry.hex)))
                        }
                    }
                }
            }

            if tab.tag != nil {
                Button("Clear Tag") {
                    tab.tag = nil
                }
            }
            Button("Set Tag…") {
                ContentView.showWorkspaceTagPrompt(for: tab)
            }

            Divider()

            Button("Move Up") {
                moveBy(-1)
            }
            .disabled(index == 0)

            Button("Move Down") {
                moveBy(1)
            }
            .disabled(index >= tabManager.tabs.count - 1)

            Button("Move to Top") {
                tabManager.moveTabsToTop(Set(targetIds))
                syncSelectionAfterMutation()
            }
            .disabled(targetIds.isEmpty)

            Divider()

            if let key = closeWorkspaceShortcut.keyEquivalent {
                Button(closeLabel) {
                    closeTabs(targetIds, allowPinned: true)
                }
                .keyboardShortcut(key, modifiers: closeWorkspaceShortcut.eventModifiers)
                .disabled(targetIds.isEmpty)
            } else {
                Button(closeLabel) {
                    closeTabs(targetIds, allowPinned: true)
                }
                .disabled(targetIds.isEmpty)
            }

            Button("Close Other Workspaces") {
                closeOtherTabs(targetIds)
            }
            .disabled(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)

            Button("Close Workspaces Below") {
                closeTabsBelow(tabId: tab.id)
            }
            .disabled(index >= tabManager.tabs.count - 1)

            Button("Close Workspaces Above") {
                closeTabsAbove(tabId: tab.id)
            }
            .disabled(index == 0)

            Divider()

            Button(markReadLabel) {
                markTabsRead(targetIds)
            }
            .disabled(!hasUnreadNotifications(in: targetIds))

            Button(markUnreadLabel) {
                markTabsUnread(targetIds)
            }
            .disabled(!hasReadNotifications(in: targetIds))
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

    private var activeTabGradientOrColor: AnyShapeStyle {
        if isActive && resolvedCustomTabColor == nil {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.45, blue: 0.55),  // soft pink
                        Color(red: 0.55, green: 0.45, blue: 0.95),  // soft purple
                        Color(red: 0.45, green: 0.55, blue: 0.95),  // soft blue
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        return AnyShapeStyle(backgroundColor)
    }

    private var railColor: Color {
        explicitRailColor ?? .clear
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
        "\(tab.title), workspace \(index + 1) of \(tabManager.tabs.count)"
    }

    private func moveBy(_ delta: Int) {
        let targetIndex = index + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        guard tabManager.reorderWorkspace(tabId: tab.id, toIndex: targetIndex) else { return }
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

        if isShift, let lastIndex = lastSidebarSelectionIndex {
            let lower = min(lastIndex, index)
            let upper = max(lastIndex, index)
            let rangeIds = tabManager.tabs[lower...upper].map { $0.id }
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
        let baseIds: Set<UUID> = selectedTabIds.contains(tab.id) ? selectedTabIds : [tab.id]
        return tabManager.tabs.compactMap { baseIds.contains($0.id) ? $0.id : nil }
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
        let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
        closeTabs(idsToClose, allowPinned: false)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
        closeTabs(idsToClose, allowPinned: false)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
        closeTabs(idsToClose, allowPinned: false)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markRead(forTabId: id)
        }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markUnread(forTabId: id)
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

    private func syncSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }

    private var latestNotificationText: String? {
        guard let notification = notificationStore.latestNotification(forTabId: tab.id) else { return nil }
        let text = notification.body.isEmpty ? notification.title : notification.body
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var activeTeamName: String? {
        TeamOrchestrator.shared.teams.values.first(where: { $0.workspaceId == tab.id })?.id
    }

    private var activeTeam: TeamOrchestrator.Team? {
        TeamOrchestrator.shared.teams.values.first(where: { $0.workspaceId == tab.id })
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

    private var verticalBranchDirectoryEntries: [SidebarBranchOrdering.BranchDirectoryEntry] {
        tab.sidebarBranchDirectoryEntriesInDisplayOrder()
    }

    private var verticalRowsContainBranch: Bool {
        sidebarShowGitBranch && verticalBranchDirectoryLines.contains { $0.branch != nil }
    }

    private struct VerticalBranchDirectoryLine {
        let branch: String?
        let directory: String?
    }

    private var verticalBranchDirectoryLines: [VerticalBranchDirectoryLine] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return verticalBranchDirectoryEntries.compactMap { entry in
            let branchText: String? = {
                guard sidebarShowGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()

            let directoryText: String? = {
                guard let directory = entry.directory else { return nil }
                let shortened = shortenPath(directory, home: home)
                return shortened.isEmpty ? nil : shortened
            }()

            switch (branchText, directoryText) {
            case let (branch?, directory?):
                return VerticalBranchDirectoryLine(branch: branch, directory: directory)
            case let (branch?, nil):
                return VerticalBranchDirectoryLine(branch: branch, directory: nil)
            case let (nil, directory?):
                return VerticalBranchDirectoryLine(branch: nil, directory: directory)
            default:
                return nil
            }
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
                    teamContextMenuBuilder()
                }
            }

            if let team = activeTeam {
                HStack(spacing: 3) {
                    ForEach(team.agents, id: \.id) { agent in
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
            ForEach(team.agents, id: \.id) { agent in
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

/// A single expanded agent row: state dot + name + relative activity time +
/// optional branch + token-usage column + status label.
private struct ExpandedAgentRow: View {
    let teamName: String
    let agent: TeamOrchestrator.AgentMember
    @ObservedObject private var dataStore = TeamDataStore.shared
    @ObservedObject private var orchestrator = TeamOrchestrator.shared

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
        return "\(compactToken(u.inputTokens)) in · \(compactToken(u.outputTokens)) out"
    }

    private var tokenTooltip: String {
        guard let u = usage, u.updatedAt != .distantPast else { return "No usage data yet." }
        let total = u.cacheReadTokens &+ u.cacheCreationTokens
        if total > 0, let ratio = u.cacheHitRatio {
            let pct = Int((ratio * 100).rounded())
            return "cache hit \(pct)% · \(compactToken(u.cacheReadTokens)) cached · \(compactToken(u.cacheCreationTokens)) fresh"
        }
        return "input \(u.inputTokens) · output \(u.outputTokens)"
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

        Button("Copy session id") {
            copySessionId()
        }

        Button("View logs") {
            revealLogsInFinder()
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

enum SidebarDropEdge {
    case top
    case bottom
}

struct SidebarDropIndicator {
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
