// Phase E-5: a small floating window listing every active peer
// federation relay window the app currently hosts. Each row shows the
// host (SSH target if available, otherwise the peer name or local socket
// path), the connection type, the remote target title, the time the
// relay opened, and a Disconnect button.
//
// `PeerClientCoordinator.relaysDidChangeNotification` fires on every open /
// close so the table refreshes itself without polling.

import AppKit
import Bonsplit

/// NSButton carrying the stable `ObjectIdentifier` of the relay
/// controller it disconnects. The handler resolves the id back to a
/// live controller through `PeerClientCoordinator.disconnect(id:)`, so a
/// roster change between render and click can't make the button act
/// on the wrong controller — and the panel doesn't need to hold a
/// reference to the controller at all.
@MainActor
final class DisconnectButton: NSButton {
    var targetID: ObjectIdentifier?

    convenience init(targetID: ObjectIdentifier) {
        self.init(title: "Disconnect", target: nil, action: nil)
        self.targetID = targetID
        self.controlSize = .small
        self.bezelStyle = .rounded
        self.font = .systemFont(ofSize: 11)
    }
}

/// Carries the viewer machine's peer ID rather than a row index, so a list
/// that changed between render and click cannot disconnect the wrong machine.
@MainActor
final class InboundDisconnectButton: NSButton {
    var peerID: Data?
}

@MainActor
final class PeerConnectionsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PeerConnectionsWindowController()

    private var rows: [PeerRelayConnectionInfo] = []
    private var inboundRows: [PeerHostCoordinator.InboundConnectionRow] = []
    private var tableView: NSTableView!
    private var inboundTableView: NSTableView!
    private var refreshTimer: Timer?
    private var observerToken: NSObjectProtocol?
    private var inboundObserverToken: NSObjectProtocol?
    private var inboundReloadGeneration = 0

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
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
            forName: PeerClientCoordinator.relaysDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
#if DEBUG
            dlog("peer.connections.notify received")
#endif
            Task { @MainActor in self?.reload() }
        }
        inboundObserverToken = NotificationCenter.default.addObserver(
            forName: PeerHostCoordinator.inboundConnectionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadInbound() }
        }
#if DEBUG
        dlog("peer.connections.panel init token=\(String(describing: observerToken))")
#endif
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let t = observerToken {
            NotificationCenter.default.removeObserver(t)
        }
        if let t = inboundObserverToken {
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
        // Tick once a second so "Attached 12s ago" stays current. The
        // inbound list is re-read too: which side owns a pane's size changes
        // on focus, and nothing notifies that.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tableView?.reloadData()
                self?.reloadInbound()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Layout

    private func installContent() {
        guard let window else { return }
        let outgoing = makeTable(columns: [
            ("host", "Host", 220),
            ("kind", "Type", 76),
            ("target", "Target", 160),
            ("attached", "Attached", 80),
            ("action", "", 80),
        ])
        tableView = outgoing.table
        let incoming = makeTable(columns: [
            ("machine", "Machine", 180),
            ("workspace", "Workspace", 140),
            ("pane", "Pane", 120),
            ("viewerSize", "Viewer size", 80),
            ("sizeOwner", "Size follows", 110),
            ("connected", "Connected", 80),
            ("action", "", 90),
        ])
        inboundTableView = incoming.table

        let outgoingLabel = makeSectionLabel("Outgoing — machines this Mac is viewing")
        let incomingLabel = makeSectionLabel("Incoming — machines viewing this Mac")
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        for view in [outgoingLabel, outgoing.scroll, incomingLabel, incoming.scroll] {
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            outgoingLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            outgoingLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            outgoing.scroll.topAnchor.constraint(equalTo: outgoingLabel.bottomAnchor, constant: 4),
            outgoing.scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            outgoing.scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            incomingLabel.topAnchor.constraint(equalTo: outgoing.scroll.bottomAnchor, constant: 10),
            incomingLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            incoming.scroll.topAnchor.constraint(equalTo: incomingLabel.bottomAnchor, constant: 4),
            incoming.scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            incoming.scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            incoming.scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            incoming.scroll.heightAnchor.constraint(equalTo: outgoing.scroll.heightAnchor),
        ])
        window.contentView = container
    }

    private func makeTable(columns: [(String, String, CGFloat)]) -> (scroll: NSScrollView, table: NSTableView) {
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
        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 40
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        return (scroll, table)
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Data

    private func reload() {
        rows = PeerClientCoordinator.shared.activeConnections()
#if DEBUG
        dlog("peer.connections.panel reload rows=\(rows.count)")
#endif
        tableView?.reloadData()
        reloadInbound()
    }

    private func reloadInbound() {
        inboundReloadGeneration += 1
        let generation = inboundReloadGeneration
        Task { @MainActor in
            let fetched = await PeerHostCoordinator.shared.inboundConnections()
            // A slower earlier fetch must not overwrite a newer one.
            guard generation == self.inboundReloadGeneration else { return }
            guard fetched != self.inboundRows else { return }
            self.inboundRows = fetched
            self.inboundTableView?.reloadData()
        }
    }
}

extension PeerConnectionsWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === inboundTableView ? inboundRows.count : rows.count
    }
}

extension PeerConnectionsWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if tableView === inboundTableView {
            guard let column = tableColumn, row < inboundRows.count else { return nil }
            let isFirstOfMachine = row == 0 || inboundRows[row - 1].peerID != inboundRows[row].peerID
            return inboundCell(
                column: column.identifier.rawValue,
                row: inboundRows[row],
                isFirstOfMachine: isFirstOfMachine
            )
        }
        guard let column = tableColumn, row < rows.count else { return nil }
        let info = rows[row]
        switch column.identifier.rawValue {
        case "host":
            return makeLabel(info.hostDisplay)
        case "kind":
            return makeLabel(info.kind.rawValue)
        case "target":
            return makeLabel(info.targetTitle)
        case "attached":
            return makeLabel(formatRelative(info.connectedAt))
        case "action":
            return makeDisconnectButton(for: info)
        default:
            return nil
        }
    }

    private func inboundCell(
        column: String,
        row: PeerHostCoordinator.InboundConnectionRow,
        isFirstOfMachine: Bool
    ) -> NSView? {
        switch column {
        case "machine":
            return makeLabel(isFirstOfMachine ? row.machine : "")
        case "action":
            // One button per machine: a viewer holds a connection per pane
            // plus one per mirrored workspace, and ending only some of them
            // leaves the rest attached.
            guard isFirstOfMachine, !row.peerID.isEmpty else { return nil }
            let button = InboundDisconnectButton(title: "Disconnect", target: self,
                                                 action: #selector(inboundDisconnectClicked(_:)))
            button.peerID = row.peerID
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.toolTip = "End every connection from \(row.machine). It stays disconnected until someone reconnects from that machine."
            return button
        case "workspace":
            return makeLabel(row.workspaceTitle ?? "—")
        case "pane":
            return makeLabel(row.paneTitle ?? "No pane attached")
        case "viewerSize":
            return makeLabel(row.viewerCols > 0 ? "\(row.viewerCols)×\(row.viewerRows)" : "—")
        case "sizeOwner":
            return makeLabel(Self.sizeOwnerLabel(row.sizeOwner))
        case "connected":
            return makeLabel(formatRelative(row.connectedAt))
        default:
            return nil
        }
    }

    static func sizeOwnerLabel(_ owner: SharedPTYSizeOwner?) -> String {
        switch owner {
        case .local: return "This Mac"
        case .remote: return "Viewer"
        case .smallest: return "Smaller of both"
        case nil: return "—"
        }
    }

    @objc private func inboundDisconnectClicked(_ sender: InboundDisconnectButton) {
        guard let peerID = sender.peerID else { return }
        Task { @MainActor in
            await PeerHostCoordinator.shared.disconnectInbound(peerID: peerID)
            reloadInbound()
        }
    }

    private func makeLabel(_ s: String) -> NSView {
        let f = NSTextField(labelWithString: s)
        f.lineBreakMode = .byTruncatingTail
        f.toolTip = s
        f.font = .systemFont(ofSize: 12)
        return f
    }

    private func makeDisconnectButton(for info: PeerRelayConnectionInfo) -> NSView {
        let btn = DisconnectButton(targetID: info.id)
        btn.target = self
        btn.action = #selector(disconnectClicked(_:))
        return btn
    }

    @objc private func disconnectClicked(_ sender: DisconnectButton) {
        // Resolve the stable id through the coordinator. A
        // closed-since-render controller produces a safe no-op
        // rather than mis-acting on the row at the same position.
        guard let id = sender.targetID else { return }
        PeerClientCoordinator.shared.disconnect(id: id)
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
