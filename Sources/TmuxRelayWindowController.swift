// Phase 2.1: NSWindow that hosts a Ghostty terminal surface driven by the
// term-meshd-tmux-relay binary.  The relay binary connects to term-meshd,
// calls multiplexer.tmux.{attach,subscribe}, decodes hex-encoded output
// frames, and writes raw PTY bytes to stdout — which Ghostty renders.
//
// Only the relay → Ghostty direction (display) is wired in Phase 2.1.
// Keyboard input (stdin → multiplexer.tmux.input) is Phase 2.2.

import AppKit

@MainActor
final class TmuxRelayWindowController: NSWindowController, NSWindowDelegate {
    private let terminalSurface: TerminalSurface
    private let sshHost: String
    private let tmuxSession: String

    init(host: String, session: String, daemonSocket: String) {
        self.sshHost = host
        self.tmuxSession = session

        guard let relayBinary = TmuxRelayWindowController.findRelayBinary() else {
            // Surface will just show an error message from the shell.
            let surface = TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
                configTemplate: nil,
                command: "/bin/sh",
                environment: [:]
            )
            self.terminalSurface = surface
            let window = TmuxRelayWindowController.makeWindow(title: "tmux relay: binary not found")
            super.init(window: window)
            TmuxRelayWindowController.embed(surface.hostedView, in: window)
            window.delegate = self
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: nil,
            command: relayBinary,
            environment: [
                "TERMMESH_DAEMON_UNIX_PATH": daemonSocket,
                "TERMMESH_TMUX_HOST": host,
                "TERMMESH_TMUX_SESSION": session,
            ]
        )
        self.terminalSurface = surface

        let title = "tmux · \(session) @ \(host)"
        let window = TmuxRelayWindowController.makeWindow(title: title)
        super.init(window: window)
        TmuxRelayWindowController.embed(surface.hostedView, in: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // TerminalSurface.deinit handles PTY/Ghostty cleanup.
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private static func makeWindow(title: String) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    private static func embed(_ hostedView: NSView, in window: NSWindow) {
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        container.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.contentView = container
    }

    /// Search for term-meshd-tmux-relay binary in development and bundled locations.
    static func findRelayBinary() -> String? {
        let fm = FileManager.default

        // Development: daemon workspace relative to the Swift source file.
        let srcFile = URL(fileURLWithPath: #file)
        // Sources/TmuxRelayWindowController.swift → ../../daemon/target/release/
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

    /// Best-effort daemon socket path. Order:
    ///   1. TERMMESH_DAEMON_UNIX_PATH / TERMMESH_DAEMON_SOCKET env
    ///   2. macOS Library/Application Support/term-mesh/term-meshd-*.sock
    ///      (this is where the app-spawned daemon writes its socket when
    ///       a build tag is in effect; the value also lives in the daemon
    ///       child's env but is not always re-exported to the app)
    ///   3. ~/.local/share/term-mesh/term-meshd.sock
    ///   4. /tmp/term-meshd.sock fallback
    static func detectDaemonSocket() -> String {
        if let p = ProcessInfo.processInfo.environment["TERMMESH_DAEMON_UNIX_PATH"], !p.isEmpty {
            return p
        }
        if let p = ProcessInfo.processInfo.environment["TERMMESH_DAEMON_SOCKET"], !p.isEmpty {
            return p
        }
        // Probe getenv directly in case ProcessInfo cached an empty env.
        if let raw = getenv("TERMMESH_DAEMON_UNIX_PATH") {
            let s = String(cString: raw)
            if !s.isEmpty { return s }
        }

        // macOS app-spawned daemon writes its socket into
        // ~/Library/Application Support/term-mesh/term-meshd-*.sock.
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/term-mesh")
            .path
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: appSupport) {
            let socks = entries
                .filter { $0.hasPrefix("term-meshd-") && $0.hasSuffix(".sock") }
                .map { "\(appSupport)/\($0)" }
                .filter { FileManager.default.fileExists(atPath: $0) }
            // Prefer the one matching the current TERMMESH_TAG, otherwise newest.
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

        // Standard path written by term-meshd at startup (Linux / non-tagged).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let standard = home + "/.local/share/term-mesh/term-meshd.sock"
        if FileManager.default.fileExists(atPath: standard) { return standard }
        return "/tmp/term-meshd.sock"
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
    private var openControllers: [TmuxRelayWindowController] = []

    private struct TmuxPaneOption {
        let index: Int
        let paneID: String
        let command: String
        let active: Bool

        var displayTitle: String {
            let commandLabel = command.isEmpty ? "unknown" : command
            let state = active ? ", active" : ""
            return "pane \(index) (\(paneID), \(commandLabel)\(state))"
        }
    }

    @MainActor
    @objc func promptAndConnect(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Linux Tmux"
        alert.informativeText = "Enter the SSH host and tmux session name.\nRequires term-meshd to be running."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 340, height: 66))
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.alignment = .leading

        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        hostField.placeholderString = "SSH host (e.g. ubuntu@192.168.1.10)"
        hostField.stringValue = ProcessInfo.processInfo.environment["TERMMESH_TMUX_HOST"] ?? ""

        let sessionField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        sessionField.placeholderString = "tmux session name (e.g. main)"
        sessionField.stringValue = ProcessInfo.processInfo.environment["TERMMESH_TMUX_SESSION"] ?? ""

        stackView.addArrangedSubview(hostField)
        stackView.addArrangedSubview(sessionField)
        alert.accessoryView = stackView

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = sessionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !session.isEmpty else { return }

        Task { [weak self] in
            let panes = await Self.listPanesViaSSH(host: host, session: session)
            if panes.count >= 2,
               let selectedPane = Self.promptForPaneSelection(host: host, session: session, panes: panes) {
                let didSelect = await Self.selectPaneViaSSH(host: host, paneID: selectedPane.paneID)
                if !didSelect {
                    let shouldContinue = Self.confirmPaneSelectionFailure(pane: selectedPane)
                    guard shouldContinue else { return }
                }
            } else if panes.count >= 2 {
                return
            }

            self?.openRelay(host: host, session: session)
        }
    }

    @MainActor
    private func openRelay(host: String, session: String) {
        // TermMeshDaemon.shared.socketPath is the authoritative socket path
        // (already set via LSEnvironment or setenv in startDaemon).
        let daemonSocket = TermMeshDaemon.shared.socketPath
        let controller = TmuxRelayWindowController(host: host, session: session, daemonSocket: daemonSocket)
        openControllers.append(controller)
        controller.show()
    }

    private static func listPanesViaSSH(host: String, session: String) async -> [TmuxPaneOption] {
        let format = "#{pane_index}\t#{pane_id}\t#{pane_current_command}\t#{pane_active}"
        let command = [
            "tmux",
            "list-panes",
            "-t",
            shellQuote(session),
            "-F",
            shellQuote(format),
        ].joined(separator: " ")
        let result = await runSSHCommand(host: host, command: command, timeout: 6)
        guard result.exitCode == 0, !result.stdout.isEmpty else { return [] }
        return parsePaneList(result.stdout)
    }

    private static func selectPaneViaSSH(host: String, paneID: String) async -> Bool {
        let command = "tmux select-pane -t \(shellQuote(paneID))"
        let result = await runSSHCommand(host: host, command: command, timeout: 6)
        return result.exitCode == 0 && !result.timedOut
    }

    @MainActor
    private static func promptForPaneSelection(
        host: String,
        session: String,
        panes: [TmuxPaneOption]
    ) -> TmuxPaneOption? {
        let alert = NSAlert()
        alert.messageText = "Choose a tmux pane"
        alert.informativeText = "\(session) on \(host) has multiple panes. Select the pane to show before connecting."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 420, height: 30))
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.alignment = .leading

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        for pane in panes {
            popup.addItem(withTitle: pane.displayTitle)
        }
        if let activeIndex = panes.firstIndex(where: \.active) {
            popup.selectItem(at: activeIndex)
        }
        stackView.addArrangedSubview(popup)
        alert.accessoryView = stackView

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedIndex = max(0, popup.indexOfSelectedItem)
        guard panes.indices.contains(selectedIndex) else { return panes.first }
        return panes[selectedIndex]
    }

    @MainActor
    private static func confirmPaneSelectionFailure(pane: TmuxPaneOption) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Could not select \(pane.displayTitle)"
        alert.informativeText = "term-mesh can still connect, but tmux may open on the session's current active pane."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Default")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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

    private static func parsePaneList(_ output: String) -> [TmuxPaneOption] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> TmuxPaneOption? in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count >= 4, let index = Int(columns[0]) else { return nil }
                return TmuxPaneOption(
                    index: index,
                    paneID: String(columns[1]),
                    command: String(columns[2]),
                    active: columns[3] == "1"
                )
            }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
