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

        // TermMeshDaemon.shared.socketPath is the authoritative socket path
        // (already set via LSEnvironment or setenv in startDaemon).
        let daemonSocket = TermMeshDaemon.shared.socketPath
        let controller = TmuxRelayWindowController(host: host, session: session, daemonSocket: daemonSocket)
        openControllers.append(controller)
        controller.show()
    }
}
