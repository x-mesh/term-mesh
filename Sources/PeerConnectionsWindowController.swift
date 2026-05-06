// Phase E-5: a small floating window listing every active peer
// federation relay window the app currently hosts. Each row shows the
// host (SSH target if available, otherwise the local socket path), the
// workspace title, the time the relay opened, and a Disconnect button.
//
// `PeerCoordinator.relaysDidChangeNotification` fires on every open /
// close so the table refreshes itself without polling.

import AppKit

@MainActor
final class PeerConnectionsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PeerConnectionsWindowController()

    private var rows: [PeerRelayWorkspaceWindowController] = []
    private var tableView: NSTableView!
    private var refreshTimer: Timer?
    private var observerToken: NSObjectProtocol?

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Peer Connections"
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
        installContent()
        observerToken = NotificationCenter.default.addObserver(
            forName: PeerCoordinator.relaysDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let t = observerToken {
            NotificationCenter.default.removeObserver(t)
        }
    }

    func showAndFocus() {
        if window?.isVisible != true {
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        reload()
        // Tick once a second so "Attached 12s ago" stays current.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tableView?.reloadData() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Layout

    private func installContent() {
        guard let window else { return }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let table = NSTableView()
        table.translatesAutoresizingMaskIntoConstraints = false
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 28
        table.headerView = NSTableHeaderView()

        for (id, title, width) in [
            ("host", "Host", CGFloat(180)),
            ("workspace", "Workspace", CGFloat(160)),
            ("attached", "Attached", CGFloat(80)),
            ("action", "", CGFloat(80)),
        ] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 40
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        self.tableView = table

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])
        window.contentView = container
    }

    // MARK: - Data

    private func reload() {
        rows = PeerCoordinator.shared.activeWorkspaceRelays()
        tableView?.reloadData()
    }
}

extension PeerConnectionsWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

extension PeerConnectionsWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let ctrl = rows[row]
        switch column.identifier.rawValue {
        case "host":
            return makeLabel(ctrl.sshTarget ?? ctrl.hostSockPath)
        case "workspace":
            return makeLabel(ctrl.workspaceTitle)
        case "attached":
            return makeLabel(formatRelative(ctrl.connectedAt))
        case "action":
            return makeDisconnectButton(for: ctrl)
        default:
            return nil
        }
    }

    private func makeLabel(_ s: String) -> NSView {
        let f = NSTextField(labelWithString: s)
        f.lineBreakMode = .byTruncatingTail
        f.toolTip = s
        f.font = .systemFont(ofSize: 12)
        return f
    }

    private func makeDisconnectButton(for ctrl: PeerRelayWorkspaceWindowController) -> NSView {
        let btn = NSButton(title: "Disconnect", target: self, action: #selector(disconnectClicked(_:)))
        btn.controlSize = .small
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 11)
        // ObjectIdentifier doesn't survive into selectors; tag the
        // button with the row index instead.
        btn.tag = rows.firstIndex(where: { $0 === ctrl }) ?? -1
        return btn
    }

    @objc private func disconnectClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < rows.count else { return }
        rows[idx].window?.performClose(nil)
        // The roster-changed notification will re-fire reload.
    }

    private func formatRelative(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "\(elapsed)s ago" }
        if elapsed < 3600 { return "\(elapsed / 60)m ago" }
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        return m == 0 ? "\(h)h ago" : "\(h)h \(m)m ago"
    }
}
