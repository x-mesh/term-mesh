import SwiftUI
import AppKit
import Bonsplit

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

    private var workspaceHintSlotWidth: CGFloat {
        guard let label = workspaceShortcutLabel else { return 28 }
        let positiveDebugInset = max(0, CGFloat(ShortcutHintDebugSettings.clamped(sidebarShortcutHintXOffset))) + 2
        return max(28, workspaceHintWidth(for: label) + positiveDebugInset)
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
                    .opacity(showCloseButton && !showsWorkspaceShortcutHint ? 1 : 0)
                    .allowsHitTesting(showCloseButton && !showsWorkspaceShortcutHint)

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
                .frame(width: workspaceHintSlotWidth, height: 16, alignment: .trailing)
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
        let attentionCount = teamAttentionCount(teamName: teamName)

        VStack(alignment: .leading, spacing: 4) {
            // Team badge row with inbox count
            HStack(spacing: 4) {
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
            .foregroundColor(activeSecondaryColor(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))

            // Agent status dots (compact overview)
            if let team = activeTeam {
                HStack(spacing: 3) {
                    ForEach(team.agents, id: \.id) { agent in
                        agentDot(teamName: teamName, agent: agent)
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func agentDot(teamName: String, agent: TeamOrchestrator.AgentMember) -> some View {
        let state = TeamOrchestrator.shared.agentState(teamName: teamName, agentName: agent.name)
        let color: Color = switch state {
        case "running":      .green
        case "blocked":      .red
        case "review_ready": .yellow
        case "error":        .red.opacity(0.7)
        default:             .gray  // idle
        }

        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help("\(agent.name): \(state)")
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

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        applyTabColor(normalized, targetIds: targetIds)
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
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
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
