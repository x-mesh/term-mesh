import AppKit
import Bonsplit
import SwiftUI

/// AppKit-level double-click handler for the sidebar title-bar area.
/// Uses NSView hit-testing so it isn't swallowed by the SwiftUI ScrollView underneath.
struct DoubleClickZoomView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DoubleClickZoomNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DoubleClickZoomNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { self }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

struct MiddleClickCapture: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickCaptureView {
        let view = MiddleClickCaptureView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: MiddleClickCaptureView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

final class MiddleClickCaptureView: NSView {
    var onMiddleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept middle-click so left-click selection and right-click context menus
        // continue to hit-test through to SwiftUI/AppKit normally.
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown,
              event.buttonNumber == 2 else {
            return nil
        }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick?()
    }
}

enum SidebarSelection {
    case tabs
    case notifications
}

struct ClearScrollBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background(ScrollBackgroundClearer())
        } else {
            content
                .background(ScrollBackgroundClearer())
        }
    }
}

private struct ScrollBackgroundClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = findScrollView(startingAt: nsView) else { return }
            // Clear all backgrounds and mark as non-opaque for transparency
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.wantsLayer = true
            scrollView.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.layer?.isOpaque = false

            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.contentView.layer?.isOpaque = false

            if let docView = scrollView.documentView {
                docView.wantsLayer = true
                docView.layer?.backgroundColor = NSColor.clear.cgColor
                docView.layer?.isOpaque = false
            }
        }
    }

    private func findScrollView(startingAt view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            current = candidate.superview
        }
        return nil
    }
}

private struct DraggableFolderIcon: View {
    let directory: String

    var body: some View {
        DraggableFolderIconRepresentable(directory: directory)
            .frame(width: 16, height: 16)
            .help("Drag to open in Finder or another app")
            .onTapGesture(count: 2) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
            }
    }
}

private struct DraggableFolderIconRepresentable: NSViewRepresentable {
    let directory: String

    func makeNSView(context: Context) -> DraggableFolderNSView {
        DraggableFolderNSView(directory: directory)
    }

    func updateNSView(_ nsView: DraggableFolderNSView, context: Context) {
        nsView.directory = directory
        nsView.updateIcon()
    }
}

final class DraggableFolderNSView: NSView, NSDraggingSource {
    private final class FolderIconImageView: NSImageView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    var directory: String
    private var imageView: FolderIconImageView!
    private var previousWindowMovableState: Bool?
    private weak var suppressedWindow: NSWindow?
    private var hasActiveDragSession = false
    private var didArmWindowDragSuppression = false

    private static let iconCache = NSCache<NSString, NSImage>()
    private static let iconQueue = DispatchQueue(label: "com.termmesh.icon-loader", qos: .userInitiated)

    private static func loadIcon(forPath path: String, size: NSSize, completion: @escaping (NSImage) -> Void) {
        let key = "\(path)@\(Int(size.width))" as NSString
        if let cached = iconCache.object(forKey: key) {
            completion(cached)
            return
        }
        iconQueue.async {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = size
            iconCache.setObject(icon, forKey: key)
            DispatchQueue.main.async {
                completion(icon)
            }
        }
    }

    private func formatPoint(_ point: NSPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    init(directory: String) {
        self.directory = directory
        super.init(frame: .zero)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func setupImageView() {
        imageView = FolderIconImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateIcon()
    }

    func updateIcon() {
        let size = NSSize(width: 16, height: 16)
        // Show a generic folder placeholder immediately; replace with the real icon asynchronously.
        imageView.image = NSImage(named: NSImage.folderName)
        Self.loadIcon(forPath: directory, size: size) { [weak self] icon in
            self?.imageView.image = icon
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hasActiveDragSession = false
        restoreWindowMovableStateIfNeeded()
        #if DEBUG
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.dragEnd dir=\(directory) operation=\(operation.rawValue) screen=\(formatPoint(screenPoint)) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        maybeDisableWindowDraggingEarly(trigger: "hitTest")
        let hit = super.hitTest(point)
        #if DEBUG
        let hitDesc = hit.map { String(describing: type(of: $0)) } ?? "nil"
        let imageHit = (hit === imageView)
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        dlog("folder.hitTest point=\(formatPoint(point)) hit=\(hitDesc) imageViewHit=\(imageHit) returning=DraggableFolderNSView wasMovable=\(wasMovable) nowMovable=\(nowMovable)")
        #endif
        return self
    }

    override func mouseDown(with event: NSEvent) {
        maybeDisableWindowDraggingEarly(trigger: "mouseDown")
        hasActiveDragSession = false
        #if DEBUG
        let localPoint = convert(event.locationInWindow, from: nil)
        let responderDesc = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.mouseDown dir=\(directory) point=\(formatPoint(localPoint)) firstResponder=\(responderDesc) wasMovable=\(wasMovable) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
        let fileURL = URL(fileURLWithPath: directory)
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)

        // Use cached icon for drag; fall back to the already-displayed imageView image.
        let iconSize = NSSize(width: 32, height: 32)
        let dragIcon: NSImage
        if let cached = Self.iconCache.object(forKey: "\(directory)@32" as NSString) {
            dragIcon = cached
        } else if let existing = imageView.image, let copy = existing.copy() as? NSImage {
            copy.size = iconSize
            dragIcon = copy
        } else {
            let fallback = NSImage(named: NSImage.folderName) ?? NSImage()
            fallback.size = iconSize
            dragIcon = fallback
        }
        draggingItem.setDraggingFrame(bounds, contents: dragIcon)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        hasActiveDragSession = true
        #if DEBUG
        let itemCount = session.draggingPasteboard.pasteboardItems?.count ?? 0
        dlog("folder.dragStart dir=\(directory) pasteboardItems=\(itemCount)")
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if !hasActiveDragSession {
            restoreWindowMovableStateIfNeeded()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = buildPathMenu()
        // Pop up menu at bottom-left of icon (like native proxy icon)
        let menuLocation = NSPoint(x: 0, y: bounds.height)
        menu.popUp(positioning: nil, at: menuLocation, in: self)
    }

    private func buildPathMenu() -> NSMenu {
        let menu = NSMenu()
        let url = URL(fileURLWithPath: directory).standardized
        var pathComponents: [URL] = []

        // Build path from current directory up to root
        var current = url
        while current.path != "/" {
            pathComponents.append(current)
            current = current.deletingLastPathComponent()
        }
        pathComponents.append(URL(fileURLWithPath: "/"))

        // Add path components (current dir at top, root at bottom - matches native macOS)
        for pathURL in pathComponents {
            let displayName: String
            if pathURL.path == "/" {
                // Use the volume name for root
                if let volumeName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
                    displayName = volumeName
                } else {
                    displayName = "Macintosh HD"
                }
            } else {
                displayName = FileManager.default.displayName(atPath: pathURL.path)
            }

            let item = NSMenuItem(title: displayName, action: #selector(openPathComponent(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(named: NSImage.folderName)
            item.representedObject = pathURL
            menu.addItem(item)

            // Load the real icon asynchronously and update the menu item.
            let iconSize = NSSize(width: 16, height: 16)
            Self.loadIcon(forPath: pathURL.path, size: iconSize) { icon in
                item.image = icon
            }
        }

        // Add computer name at the bottom (like native proxy icon)
        let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let computerIcon = NSImage(named: NSImage.computerName) ?? NSImage()
        computerIcon.size = NSSize(width: 16, height: 16)

        let computerItem = NSMenuItem(title: computerName, action: #selector(openComputer(_:)), keyEquivalent: "")
        computerItem.target = self
        computerItem.image = computerIcon
        menu.addItem(computerItem)

        return menu
    }

    @objc private func openPathComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    @objc private func openComputer(_ sender: NSMenuItem) {
        // Open "Computer" view in Finder (shows all volumes)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/", isDirectory: true))
    }

    private func restoreWindowMovableStateIfNeeded() {
        guard didArmWindowDragSuppression || previousWindowMovableState != nil else { return }
        let targetWindow = suppressedWindow ?? window
        let depthAfter = endWindowDragSuppression(window: targetWindow)
        restoreWindowDragging(window: targetWindow, previousMovableState: previousWindowMovableState)
        self.previousWindowMovableState = nil
        self.suppressedWindow = nil
        self.didArmWindowDragSuppression = false
        #if DEBUG
        let nowMovable = targetWindow.map { String($0.isMovable) } ?? "nil"
        dlog("folder.dragSuppression restore depth=\(depthAfter) nowMovable=\(nowMovable)")
        #endif
    }

    private func maybeDisableWindowDraggingEarly(trigger: String) {
        guard !didArmWindowDragSuppression else { return }
        guard let eventType = NSApp.currentEvent?.type,
              eventType == .leftMouseDown || eventType == .leftMouseDragged else {
            return
        }
        guard let currentWindow = window else { return }

        didArmWindowDragSuppression = true
        suppressedWindow = currentWindow
        let suppressionDepth = beginWindowDragSuppression(window: currentWindow) ?? 0
        if currentWindow.isMovable {
            previousWindowMovableState = temporarilyDisableWindowDragging(window: currentWindow)
        } else {
            previousWindowMovableState = nil
        }
        #if DEBUG
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = String(currentWindow.isMovable)
        dlog(
            "folder.dragSuppression trigger=\(trigger) event=\(eventType) depth=\(suppressionDepth) wasMovable=\(wasMovable) nowMovable=\(nowMovable)"
        )
        #endif
    }
}

func temporarilyDisableWindowDragging(window: NSWindow?) -> Bool? {
    guard let window else { return nil }
    let wasMovable = window.isMovable
    if wasMovable {
        window.isMovable = false
    }
    return wasMovable
}

func restoreWindowDragging(window: NSWindow?, previousMovableState: Bool?) {
    guard let window, let previousMovableState else { return }
    window.isMovable = previousMovableState
}

/// Wrapper view that tries NSGlassEffectView (macOS 26+) when available or requested
/// Reads the leading inset required to clear traffic lights + left titlebar accessories.
final class TitlebarLeadingInsetPassthroughView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct TitlebarLeadingInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = TitlebarLeadingInsetPassthroughView()
        view.setFrameSize(.zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            // Start past the traffic lights
            var leading: CGFloat = 78
            // Add width of all left-aligned titlebar accessories
            for accessory in window.titlebarAccessoryViewControllers
                where accessory.layoutAttribute == .leading || accessory.layoutAttribute == .left {
                leading += accessory.view.frame.width
            }
            leading += 0
            if leading != inset {
                inset = leading
            }
        }
    }
}

// MARK: - Worktree Manager Table

enum WorktreeAssocKeys {
    nonisolated(unsafe) static var dataSource: UInt8 = 0
    nonisolated(unsafe) static var creationHandler: UInt8 = 0
}

// MARK: - Worktree Creation Handler

@MainActor
final class WorktreeCreationHandler: NSObject {
    weak var panel: NSPanel?
    let branchPopup: NSPopUpButton
    let nameField: NSTextField
    let repoPath: String
    let tabManager: TabManager

    init(panel: NSPanel, branchPopup: NSPopUpButton, nameField: NSTextField, repoPath: String, tabManager: TabManager) {
        self.panel = panel
        self.branchPopup = branchPopup
        self.nameField = nameField
        self.repoPath = repoPath
        self.tabManager = tabManager
    }

    @objc func cancel(_ sender: Any?) {
        panel?.close()
    }

    @objc func create(_ sender: Any?) {
        let baseBranch = branchPopup.titleOfSelectedItem ?? "main"
        let worktreeName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoPath = self.repoPath
        let tabManager = self.tabManager

        panel?.close()

        let daemon = TermMeshDaemon.shared
        DispatchQueue.global(qos: .userInitiated).async {
            // If user gave a name, use it as the branch name (prefixed with term-mesh/)
            let branch: String? = worktreeName.isEmpty ? nil : "term-mesh/\(worktreeName)"
            switch daemon.createWorktreeWithError(repoPath: repoPath, branch: branch, baseBranch: baseBranch) {
            case .success(let info):
                DispatchQueue.main.async {
                    let ws = tabManager.addWorkspace(workingDirectory: info.path)
                    ws.worktreeName = info.name
                    ws.worktreeRepoPath = repoPath
                    let displayName = worktreeName.isEmpty ? info.branch : worktreeName
                    tabManager.setCustomTitle(tabId: ws.id, title: "[\(displayName)] from \(baseBranch)")
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Worktree Creation Failed"
                    switch error {
                    case .daemonNotConnected:
                        alert.informativeText = "term-meshd daemon is not running."
                    case .notGitRepo:
                        alert.informativeText = "Current directory is not a git repository."
                    case .rpcError(let detail):
                        alert.informativeText = "Failed to create worktree: \(detail)"
                    }
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                        alert.beginSheetModal(for: window) { _ in }
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
    }
}

@MainActor
final class WorktreeTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var worktrees: [WorktreeInfo]
    private let repoPath: String
    private let daemon: any DaemonService
    weak var tableView: NSTableView?
    weak var panel: NSPanel?

    init(worktrees: [WorktreeInfo], repoPath: String, daemon: any DaemonService = TermMeshDaemon.shared) {
        self.worktrees = worktrees
        self.repoPath = repoPath
        self.daemon = daemon
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        worktrees.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < worktrees.count else { return nil }
        let wt = worktrees[row]

        if tableColumn?.identifier.rawValue == "action" {
            let container = NSStackView()
            container.orientation = .horizontal
            container.spacing = 4
            container.alignment = .centerY
            container.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

            let renameButton = NSButton(image: NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename")!, target: self, action: #selector(renameRow(_:)))
            renameButton.bezelStyle = .rounded
            renameButton.tag = row
            renameButton.controlSize = .small
            renameButton.isBordered = false
            renameButton.toolTip = "Rename Worktree"

            let copyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Path")!, target: self, action: #selector(copyPath(_:)))
            copyButton.bezelStyle = .rounded
            copyButton.tag = row
            copyButton.controlSize = .small
            copyButton.isBordered = false
            copyButton.toolTip = "Copy Path"

            let terminalButton = NSButton(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: "Open Terminal")!, target: self, action: #selector(openTerminal(_:)))
            terminalButton.bezelStyle = .rounded
            terminalButton.tag = row
            terminalButton.controlSize = .small
            terminalButton.isBordered = false
            terminalButton.toolTip = "Open Terminal Here"

            let deleteButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: self, action: #selector(deleteRow(_:)))
            deleteButton.bezelStyle = .rounded
            deleteButton.tag = row
            deleteButton.controlSize = .small
            deleteButton.isBordered = false
            deleteButton.contentTintColor = .systemRed
            deleteButton.toolTip = "Delete Worktree"

            container.addArrangedSubview(renameButton)
            container.addArrangedSubview(copyButton)
            container.addArrangedSubview(terminalButton)
            container.addArrangedSubview(deleteButton)
            return container
        }

        // Name column: two-line cell (name + branch, path)
        let cell = NSView()
        let nameLabel = NSTextField(labelWithString: "\(wt.name)")
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail

        let detailLabel = NSTextField(labelWithString: "branch: \(wt.branch)  ·  \(wt.path)")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(nameLabel)
        cell.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            nameLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])

        return cell
    }

    @objc func renameRow(_ sender: NSButton) {
        let row = sender.tag
        guard row < worktrees.count else { return }
        let wt = worktrees[row]

        let alert = NSAlert()
        alert.messageText = "Rename Worktree"
        alert.informativeText = "Enter a new display name for \"\(wt.name)\" (branch: \(wt.branch)):"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        nameField.stringValue = wt.name
        nameField.placeholderString = "Worktree display name"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        alert.presentAsSheet { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }

            // Update the display name in any open workspace tab that uses this worktree
            if let tabManager = AppDelegate.shared?.preferredMainWindowContextForServiceWorkspace()?.tabManager {
                for ws in tabManager.tabs where ws.worktreeName == wt.name {
                    tabManager.setCustomTitle(tabId: ws.id, title: newName)
                }
            }

            // Refresh table (display name is stored in the workspace tab title, not in WorktreeInfo)
            self?.tableView?.reloadData()
        }
    }

    @objc func copyPath(_ sender: NSButton) {
        let row = sender.tag
        guard row < worktrees.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(worktrees[row].path, forType: .string)
    }

    @objc func openTerminal(_ sender: NSButton) {
        let row = sender.tag
        guard row < worktrees.count else { return }
        let path = worktrees[row].path
        guard let tabManager = AppDelegate.shared?.preferredMainWindowContextForServiceWorkspace()?.tabManager else {
            NSSound.beep()
            return
        }
        tabManager.addWorkspace(workingDirectory: path)
        panel?.close()
    }

    @objc func deleteRow(_ sender: NSButton) {
        let row = sender.tag
        guard row < worktrees.count else { return }
        let wt = worktrees[row]

        let repoPath = self.repoPath
        let name = wt.name

        // Pre-check: warn if worktree has uncommitted changes
        let st = daemon.worktreeStatus(repoPath: repoPath, name: name)

        let confirm = NSAlert()
        confirm.messageText = "Delete Worktree?"
        if st.dirty {
            confirm.alertStyle = .critical
            confirm.informativeText = "⚠ \"\(wt.name)\" has uncommitted changes!\nBranch: \(wt.branch)\nPath: \(wt.path)\n\nDeleting will permanently discard these changes."
            confirm.addButton(withTitle: "Delete Anyway")
        } else {
            confirm.alertStyle = .warning
            confirm.informativeText = "Remove \"\(wt.name)\" (branch: \(wt.branch))?\nPath: \(wt.path)"
            confirm.addButton(withTitle: "Delete")
        }
        confirm.addButton(withTitle: "Cancel")
        confirm.presentAsSheet { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                // Use force remove since user explicitly confirmed (even if dirty)
                let success = self.daemon.removeWorktree(repoPath: repoPath, name: name, force: true)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if success {
                        if let idx = self.worktrees.firstIndex(where: { $0.name == name }) {
                            self.worktrees.remove(at: idx)
                        }
                        self.tableView?.reloadData()
                        self.panel?.title = "Worktrees (\(self.worktrees.count))"
                    } else {
                        let errAlert = NSAlert()
                        errAlert.messageText = "Failed to remove worktree"
                        errAlert.informativeText = "Could not remove \"\(name)\". It may be in use."
                        errAlert.alertStyle = .warning
                        errAlert.addButton(withTitle: "OK")
                        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                            errAlert.beginSheetModal(for: window) { _ in }
                        } else {
                            errAlert.runModal()
                        }
                    }
                }
            }
        }
    }

    @objc func cleanupStale(_ sender: Any?) {
        let repoPath = self.repoPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.daemon.cleanupStaleWorktrees(repoPath: repoPath)
            let remaining = self.daemon.listWorktrees(repoPath: repoPath)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.worktrees = remaining
                self.tableView?.reloadData()
                self.panel?.title = "Worktrees (\(remaining.count))"

                // Switch to empty-state label when all worktrees have been removed
                if remaining.isEmpty, let panel = self.panel {
                    let label = NSTextField(labelWithString: "No active worktrees.")
                    label.font = .systemFont(ofSize: 14)
                    label.alignment = .center
                    label.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 520, height: 400)
                    label.autoresizingMask = [.width, .height]
                    panel.contentView = label
                }

                let resultAlert = NSAlert()
                resultAlert.messageText = "Worktree Cleanup"
                if result.removed > 0 && result.skippedDirty > 0 {
                    resultAlert.informativeText = "Removed \(result.removed) stale worktree(s).\nSkipped \(result.skippedDirty) with uncommitted changes."
                } else if result.removed > 0 {
                    resultAlert.informativeText = "Removed \(result.removed) stale worktree(s)."
                } else if result.skippedDirty > 0 {
                    resultAlert.informativeText = "No clean stale worktrees to remove.\nSkipped \(result.skippedDirty) with uncommitted changes."
                } else {
                    resultAlert.informativeText = "No stale worktrees found."
                }
                resultAlert.addButton(withTitle: "OK")
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    resultAlert.beginSheetModal(for: window) { _ in }
                } else {
                    resultAlert.runModal()
                }
            }
        }
    }
}
