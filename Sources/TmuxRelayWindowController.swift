// Phase 1.1 — NSWindow that mirrors a remote tmux window's full pane tree.
//
// The controller is the orchestrator: it talks to term-meshd over JSON-RPC
// to attach + list panes + attach extras + get layout, then builds an
// NSSplitView tree where every leaf hosts one Ghostty surface driven by
// `term-meshd-tmux-relay` in secondary mode (`TERMMESH_TMUX_SURFACE_ID`).
//
// Cmd+D triggers a remote `split-pane` against the focused surface and
// polls the layout briefly so the new pane appears as soon as tmux acks.

import AppKit

@MainActor
final class TmuxRelayWindowController: NSWindowController, NSWindowDelegate {
    private let sshHost: String
    private let tmuxSession: String
    private let daemonSocket: String

    /// surface_id (primary or attach_pane result) → managed terminal surface.
    private var surfaces: [String: TerminalSurface] = [:]
    /// surface_id → tmux pane id (e.g. `%1`). Required so split/kill RPCs
    /// can target the focused pane without re-walking list_panes.
    private var paneIds: [String: String] = [:]
    /// pane_index → surface_id, used while wiring leaf nodes from the
    /// layout tree to their hosted surface.
    private var paneIndexToSurface: [Int: String] = [:]
    /// Primary surface = the active pane at attach time. Anchors the
    /// SSH/tmux session lifecycle; closing the window detaches it.
    private var primarySurfaceId: String?

    /// Container that swaps between the spinner and the live layout.
    private let rootContainer = NSView()
    private var loadingLabel: NSTextField?
    private var statusLabel: NSTextField?
    /// Last applied layout signature — skips redundant rebuilds when
    /// poll-after-split arrives with identical content.
    private var layoutSignature: String?

    init(host: String, session: String, daemonSocket: String) {
        self.sshHost = host
        self.tmuxSession = session
        self.daemonSocket = daemonSocket

        let window = TmuxRelayWindowController.makeWindow(
            title: "tmux · \(session) @ \(host)"
        )
        super.init(window: window)
        window.delegate = self
        window.contentView = rootContainer
        showLoading(message: "Connecting to \(host)…")
        Task { [weak self] in await self?.bootstrap() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // TerminalSurface.deinit owns PTY teardown; the relay process exits
        // when its stdin/stdout pipes close. Best-effort detach so the
        // daemon-side backend can release its SSH connection.
        if let primary = primarySurfaceId {
            Task.detached { [primary] in
                _ = TermMeshDaemon.shared.rpcCallRaw(
                    method: "multiplexer.tmux.detach",
                    params: ["surface_id": primary]
                )
            }
        }
    }

    // ── Bootstrap orchestration ───────────────────────────────────────────

    private func bootstrap() async {
        let host = sshHost
        let session = tmuxSession
        let initialSize = currentCellSize()

        // Heavy lifting (sync RPCs) goes off the main actor.
        let result: BootstrapResult = await Task.detached(priority: .userInitiated) {
            let daemon = TermMeshDaemon.shared
            guard let attach = daemon.tmuxAttach(
                host: host,
                session: session,
                cols: initialSize.cols,
                rows: initialSize.rows,
                createIfMissing: false
            ) else {
                return .failure("tmux attach failed — is the daemon running?")
            }
            let panes = daemon.tmuxListPanes(surfaceId: attach.surfaceId) ?? []
            guard !panes.isEmpty else {
                return .failure("session has no panes")
            }
            // Primary = whichever pane the daemon bound to attach.surfaceId.
            // attach_surface_with_options prefers the active pane, so we
            // mirror that choice here for the UI.
            let primaryPane = panes.first(where: { $0.active }) ?? panes[0]
            var paneBindings: [(pane: TermMeshDaemon.TmuxPaneInfo, surfaceId: String)] = [
                (primaryPane, attach.surfaceId)
            ]
            for pane in panes where pane.paneId != primaryPane.paneId {
                if let newId = daemon.tmuxAttachPane(
                    surfaceId: attach.surfaceId,
                    paneId: pane.paneId,
                    cols: initialSize.cols,
                    rows: initialSize.rows
                ) {
                    paneBindings.append((pane, newId))
                }
            }
            let layout = daemon.tmuxGetLayout(surfaceId: attach.surfaceId)
            return .success(BootstrapData(
                primaryPaneId: primaryPane.paneId,
                bindings: paneBindings,
                layout: layout
            ))
        }.value

        switch result {
        case .failure(let message):
            showError(message: message)
        case .success(let data):
            applyBootstrap(data)
        }
    }

    private func applyBootstrap(_ data: BootstrapData) {
        // Mint surfaces for every binding (primary + extras).
        for binding in data.bindings {
            let surface = makeRelaySurface(surfaceId: binding.surfaceId)
            surfaces[binding.surfaceId] = surface
            paneIds[binding.surfaceId] = binding.pane.paneId
            paneIndexToSurface[binding.pane.paneIndex] = binding.surfaceId
        }
        primarySurfaceId = data.bindings.first?.surfaceId

        let liveView: NSView
        if let layout = data.layout {
            liveView = buildLayoutView(layout) ?? fallbackStackView()
        } else {
            liveView = fallbackStackView()
        }
        swapContent(to: liveView)
        focusFirstAvailableSurface()
    }

    /// Re-fetch the layout (after a split or any topology change) and
    /// rebuild the NSSplitView tree. Surfaces for newly discovered panes
    /// are attached via `tmuxAttachPane`; surfaces for now-missing panes
    /// are torn down. Called manually after Cmd+D; later tied to
    /// `%layout-change` (Phase 1.2).
    private func refreshLayout() {
        guard let primary = primarySurfaceId else { return }
        let initialSize = currentCellSize()
        // Snapshot known pane ids on the main actor so the detached task
        // does not need to read `self`'s state mid-flight.
        let knownPaneIds = Set(paneIds.values)

        Task.detached(priority: .userInitiated) { [primary, initialSize, knownPaneIds, weak self] in
            let daemon = TermMeshDaemon.shared
            let panes = daemon.tmuxListPanes(surfaceId: primary) ?? []
            let layout = daemon.tmuxGetLayout(surfaceId: primary)
            var newBindings: [(pane: TermMeshDaemon.TmuxPaneInfo, surfaceId: String)] = []
            for pane in panes where !knownPaneIds.contains(pane.paneId) {
                if let newId = daemon.tmuxAttachPane(
                    surfaceId: primary,
                    paneId: pane.paneId,
                    cols: initialSize.cols,
                    rows: initialSize.rows
                ) {
                    newBindings.append((pane, newId))
                }
            }
            let panesCopy = panes
            let layoutCopy = layout
            let bindingsCopy = newBindings
            await MainActor.run { [weak self] in
                self?.applyRefresh(
                    panes: panesCopy,
                    layout: layoutCopy,
                    newBindings: bindingsCopy
                )
            }
        }
    }

    private func applyRefresh(
        panes: [TermMeshDaemon.TmuxPaneInfo],
        layout: TermMeshDaemon.TmuxLayoutNode?,
        newBindings: [(pane: TermMeshDaemon.TmuxPaneInfo, surfaceId: String)]
    ) {
        for binding in newBindings {
            let surface = makeRelaySurface(surfaceId: binding.surfaceId)
            surfaces[binding.surfaceId] = surface
            paneIds[binding.surfaceId] = binding.pane.paneId
            paneIndexToSurface[binding.pane.paneIndex] = binding.surfaceId
        }

        // Drop surfaces for panes that no longer exist remotely.
        let liveIndices = Set(panes.map { $0.paneIndex })
        let stalePaneIndices = paneIndexToSurface.keys.filter { !liveIndices.contains($0) }
        for idx in stalePaneIndices {
            if let sid = paneIndexToSurface.removeValue(forKey: idx) {
                surfaces.removeValue(forKey: sid)
                paneIds.removeValue(forKey: sid)
            }
        }

        guard let layout else { return }
        let signature = layoutSignature(of: layout)
        if signature == layoutSignature { return }
        layoutSignature = signature

        let view = buildLayoutView(layout) ?? fallbackStackView()
        swapContent(to: view)
    }

    private func makeRelaySurface(surfaceId: String) -> TerminalSurface {
        let relayBinary = TmuxRelayWindowController.findRelayBinary() ?? "/bin/sh"
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: nil,
            command: relayBinary,
            environment: [
                "TERMMESH_DAEMON_UNIX_PATH": daemonSocket,
                "TERMMESH_TMUX_HOST": sshHost,
                "TERMMESH_TMUX_SESSION": tmuxSession,
                "TERMMESH_TMUX_SURFACE_ID": surfaceId,
            ]
        )
    }

    // ── Layout → NSSplitView ──────────────────────────────────────────────

    private func buildLayoutView(_ node: TermMeshDaemon.TmuxLayoutNode) -> NSView? {
        switch node.kind {
        case .pane:
            guard let idx = node.paneIndex,
                  let sid = paneIndexToSurface[idx],
                  let surface = surfaces[sid] else { return nil }
            return PaneHostView(surfaceId: sid, controller: self, content: surface.hostedView)
        case .horizontal:
            return makeSplit(isVertical: true, children: node.children)
        case .vertical:
            return makeSplit(isVertical: false, children: node.children)
        }
    }

    private func makeSplit(isVertical: Bool, children: [TermMeshDaemon.TmuxLayoutNode]) -> NSView? {
        let leaves = children.compactMap { buildLayoutView($0) }
        guard !leaves.isEmpty else { return nil }
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = isVertical
        split.dividerStyle = .thin
        for leaf in leaves {
            leaf.translatesAutoresizingMaskIntoConstraints = false
            split.addArrangedSubview(leaf)
        }
        return split
    }

    /// Used when the layout RPC fails — show every surface stacked
    /// vertically so the user at least gets I/O.
    private func fallbackStackView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (sid, surface) in surfaces {
            let host = PaneHostView(surfaceId: sid, controller: self, content: surface.hostedView)
            stack.addArrangedSubview(host)
        }
        return stack
    }

    /// Stable string that changes whenever the layout topology changes.
    private func layoutSignature(of node: TermMeshDaemon.TmuxLayoutNode) -> String {
        switch node.kind {
        case .pane:
            return "P\(node.paneIndex ?? -1)"
        case .horizontal:
            return "H[\(node.children.map(layoutSignature(of:)).joined(separator: ","))]"
        case .vertical:
            return "V[\(node.children.map(layoutSignature(of:)).joined(separator: ","))]"
        }
    }

    // ── Container view swapping ───────────────────────────────────────────

    private func showLoading(message: String) {
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13)
        loadingLabel = label
        swapContent(to: label, centered: true)
    }

    private func showError(message: String) {
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .systemRed
        statusLabel = label
        swapContent(to: label, centered: true)
    }

    private func swapContent(to view: NSView, centered: Bool = false) {
        for sub in rootContainer.subviews { sub.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(view)
        if centered {
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: rootContainer.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: rootContainer.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: rootContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            ])
        }
    }

    // ── Focus / Cmd+D ─────────────────────────────────────────────────────

    fileprivate func focusedSurfaceId() -> String? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        var view: NSView? = responder
        while let v = view {
            if let host = v as? PaneHostView { return host.surfaceId }
            view = v.superview
        }
        // Fallback: any view-tag walk failed, just return primary.
        return primarySurfaceId
    }

    fileprivate func surfaceIdFor(paneIndex: Int) -> String? {
        paneIndexToSurface[paneIndex]
    }

    /// Cmd+D entry point — called from `PaneHostView.performKeyEquivalent`.
    /// Returns true if the key was consumed.
    fileprivate func handleSplitCommand(surfaceId: String, direction: String) -> Bool {
        guard let primary = primarySurfaceId,
              let paneId = paneIds[surfaceId] else { return false }
        let ok = TermMeshDaemon.shared.tmuxControl(
            surfaceId: primary,
            command: "split-pane",
            paneId: paneId,
            direction: direction
        )
        if ok {
            // tmux is asynchronous through control mode; give it a brief
            // moment to emit %layout-change before we poll list_panes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                self?.refreshLayout()
            }
        }
        return ok
    }

    private func focusFirstAvailableSurface() {
        guard let sid = primarySurfaceId,
              let surface = surfaces[sid] else { return }
        window?.makeFirstResponder(surface.hostedView)
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private func currentCellSize() -> (cols: UInt16, rows: UInt16) {
        // Pre-bootstrap we don't have a Ghostty surface yet, so use a sane
        // initial size matched against the window's content rect (~80x24
        // cell baseline at 10pt). The first SIGWINCH from the relay
        // refines it instantly.
        return (220, 50)
    }

    private static func makeWindow(title: String) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    /// Search for term-meshd-tmux-relay binary in development and bundled locations.
    static func findRelayBinary() -> String? {
        let fm = FileManager.default

        // Development: daemon workspace relative to the Swift source file.
        let srcFile = URL(fileURLWithPath: #file)
        let devPath = srcFile
            .deletingLastPathComponent()          // Sources/
            .deletingLastPathComponent()          // project root
            .appendingPathComponent("daemon/target/release/term-meshd-tmux-relay")
            .path

        // Bundled locations (for app distribution).
        let bundlePath = Bundle.main.bundlePath
        let candidates = [
            devPath,
            bundlePath + "/Contents/Resources/bin/term-meshd-tmux-relay",
            bundlePath + "/Contents/MacOS/term-meshd-tmux-relay",
            "/usr/local/bin/term-meshd-tmux-relay",
        ]

        return candidates.first { fm.fileExists(atPath: $0) && fm.isExecutableFile(atPath: $0) }
    }

    /// Best-effort daemon socket path resolution. Same chain as before so
    /// tagged builds still find their isolated socket.
    static func detectDaemonSocket() -> String {
        if let p = ProcessInfo.processInfo.environment["TERMMESH_DAEMON_UNIX_PATH"], !p.isEmpty {
            return p
        }
        if let p = ProcessInfo.processInfo.environment["TERMMESH_DAEMON_SOCKET"], !p.isEmpty {
            return p
        }
        if let raw = getenv("TERMMESH_DAEMON_UNIX_PATH") {
            let s = String(cString: raw)
            if !s.isEmpty { return s }
        }

        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/term-mesh")
            .path
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: appSupport) {
            let socks = entries
                .filter { $0.hasPrefix("term-meshd-") && $0.hasSuffix(".sock") }
                .map { "\(appSupport)/\($0)" }
                .filter { FileManager.default.fileExists(atPath: $0) }
            if let tag = ProcessInfo.processInfo.environment["TERMMESH_TAG"], !tag.isEmpty {
                if let match = socks.first(where: { $0.contains("-\(tag).sock") }) {
                    return match
                }
            }
            let newest = socks.sorted { lhs, rhs in
                let l = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let r = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return l > r
            }.first
            if let s = newest { return s }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let standard = home + "/.local/share/term-mesh/term-meshd.sock"
        if FileManager.default.fileExists(atPath: standard) { return standard }
        return "/tmp/term-meshd.sock"
    }
}

// MARK: - Bootstrap data

private enum BootstrapResult {
    case success(BootstrapData)
    case failure(String)
}

private struct BootstrapData {
    let primaryPaneId: String
    let bindings: [(pane: TermMeshDaemon.TmuxPaneInfo, surfaceId: String)]
    let layout: TermMeshDaemon.TmuxLayoutNode?
}

// MARK: - PaneHostView (Cmd+D / focus tracking)

/// Thin NSView wrapper around each leaf so we can: (1) walk the responder
/// chain to identify the focused pane on Cmd+D, (2) intercept Cmd+D /
/// Cmd+Shift+D before they reach the underlying Ghostty surface.
private final class PaneHostView: NSView {
    let surfaceId: String
    private weak var controller: TmuxRelayWindowController?

    init(surfaceId: String, controller: TmuxRelayWindowController, content: NSView) {
        self.surfaceId = surfaceId
        self.controller = controller
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+D = horizontal split, Cmd+Shift+D = vertical split. This
        // matches Ghostty's native split shortcuts so users do not have to
        // re-learn keys when the surface happens to be tmux-backed.
        guard let controller else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if chars == "d" && flags.contains(.command) {
            let direction = flags.contains(.shift) ? "vertical" : "horizontal"
            if controller.handleSplitCommand(surfaceId: surfaceId, direction: direction) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - NSSplitView arranged-subview compatibility

private extension NSSplitView {
    /// NSSplitView has no first-class arranged-subview API on macOS 12
    /// targets. addSubview is enough — it inserts dividers between siblings.
    func addArrangedSubview(_ view: NSView) {
        addSubview(view)
    }
}

// MARK: - TmuxMenu

enum TmuxMenu {
    static func connectItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Linux Tmux…",
            action: #selector(TmuxMenuCoordinator.promptAndConnect(_:)),
            keyEquivalent: ""
        )
        item.target = TmuxMenuCoordinator.shared
        return item
    }
}

// MARK: - TmuxMenuCoordinator

/// Coordinates the "Connect to Linux Tmux…" menu action.
final class TmuxMenuCoordinator: NSObject {
    static let shared = TmuxMenuCoordinator()
    private static let lastHostKey = "termMeshTmuxLastHost"
    private static let lastSessionKey = "termMeshTmuxLastSession"
    private static let shellOptions = ["Default", "/bin/bash", "/bin/zsh", "/bin/sh"]

    private var openControllers: [TmuxRelayWindowController] = []

    @MainActor
    @objc func promptAndConnect(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Linux Tmux"
        alert.informativeText = "Enter the SSH host and tmux session name.\nRequires term-meshd to be running."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 100))
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.alignment = .leading

        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        hostField.placeholderString = "SSH host (e.g. ubuntu@192.168.1.10)"
        hostField.stringValue = Self.lastHostValue()

        let sessionField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        sessionField.placeholderString = "tmux session name (e.g. main)"
        sessionField.stringValue = Self.lastSessionValue()

        let createStack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        createStack.orientation = .horizontal
        createStack.spacing = 10
        createStack.alignment = .centerY

        let createSessionButton = NSButton(checkboxWithTitle: "Create if missing", target: nil, action: nil)
        createSessionButton.state = .on

        let shellPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 145, height: 26), pullsDown: false)
        shellPopup.addItems(withTitles: Self.shellOptions)
        shellPopup.selectItem(at: 0)

        createStack.addArrangedSubview(createSessionButton)
        createStack.addArrangedSubview(shellPopup)

        stackView.addArrangedSubview(hostField)
        stackView.addArrangedSubview(sessionField)
        stackView.addArrangedSubview(createStack)
        alert.accessoryView = stackView

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = sessionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !session.isEmpty else { return }
        let shouldCreateSession = createSessionButton.state == .on
        let selectedShell = Self.selectedShell(from: shellPopup)

        Task { [weak self] in
            if shouldCreateSession,
               let failure = await Self.ensureSessionExists(host: host, session: session, shell: selectedShell) {
                Self.showSessionCreateFailure(session: session, failure: failure)
                return
            }
            self?.openRelay(host: host, session: session)
        }
    }

    @MainActor
    private func openRelay(host: String, session: String) {
        UserDefaults.standard.set(host, forKey: Self.lastHostKey)
        UserDefaults.standard.set(session, forKey: Self.lastSessionKey)

        let daemonSocket = TermMeshDaemon.shared.socketPath
        let controller = TmuxRelayWindowController(host: host, session: session, daemonSocket: daemonSocket)
        openControllers.append(controller)
        controller.show()
    }

    private static func lastHostValue() -> String {
        UserDefaults.standard.string(forKey: lastHostKey)
            ?? ProcessInfo.processInfo.environment["TERMMESH_TMUX_HOST"]
            ?? ""
    }

    private static func lastSessionValue() -> String {
        UserDefaults.standard.string(forKey: lastSessionKey)
            ?? ProcessInfo.processInfo.environment["TERMMESH_TMUX_SESSION"]
            ?? ""
    }

    private static func selectedShell(from popup: NSPopUpButton) -> String? {
        guard popup.indexOfSelectedItem > 0 else { return nil }
        let title = popup.titleOfSelectedItem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    private static func ensureSessionExists(host: String, session: String, shell: String?) async -> SSHResult? {
        let check = await runSSHCommand(
            host: host,
            command: "tmux has-session -t \(shellQuote(session))",
            timeout: 6
        )
        if check.exitCode == 0 && !check.timedOut {
            return nil
        }

        var command = "tmux new-session -d -s \(shellQuote(session))"
        if let shell {
            command += " -- \(shellQuote(shell))"
        }
        let create = await runSSHCommand(host: host, command: command, timeout: 8)
        if create.exitCode == 0 && !create.timedOut {
            return nil
        }
        return create
    }

    @MainActor
    private static func showSessionCreateFailure(session: String, failure: SSHResult) {
        let detail = failure.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.messageText = "Could not create tmux session \(session)"
        alert.informativeText = detail.isEmpty
            ? "tmux new-session failed on the remote host."
            : detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private struct SSHResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static func runSSHCommand(host: String, command: String, timeout: TimeInterval) async -> SSHResult {
        await Task.detached(priority: .userInitiated) {
            guard !host.hasPrefix("-") else {
                return SSHResult(exitCode: 64, stdout: "", stderr: "invalid host", timedOut: false)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                host,
                command,
            ]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return SSHResult(exitCode: 127, stdout: "", stderr: String(describing: error), timedOut: false)
            }

            let deadline = Date().addingTimeInterval(timeout)
            var timedOut = false
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }

            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return SSHResult(
                exitCode: timedOut ? 124 : process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                timedOut: timedOut
            )
        }.value
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
