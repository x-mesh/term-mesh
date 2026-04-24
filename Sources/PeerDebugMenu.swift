//  Phase C-3b-β + C-3c.2α: DEBUG-only hook that lets a developer exercise
//  the Swift peer-federation client from inside term-mesh.app without
//  touching any terminal UI yet.
//
//  Flow:
//   1. Menu item → NSAlert prompt for socket path.
//   2. Connect + handshake + list (from C-3b-β).
//   3. Attach to the first surface (C-3c.2α).
//   4. Open a `PeerDebugConsoleWindow`:
//        - NSTextView (read-only) streams raw PtyData bytes as UTF-8. No
//          ANSI escape processing — the user sees the raw tty stream,
//          which is the point: it proves bytes are flowing into the GUI
//          process and rendering on-screen.
//        - NSTextField below lets the developer type a line and hit
//          Enter; it gets sent as an Input frame, field clears.
//        - Closing the window sends Goodbye and tears down the transport.

#if DEBUG
import AppKit
import PeerProto

@MainActor
enum PeerDebugMenu {
    static func item() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Peer… (debug)",
            action: #selector(PeerDebugCoordinator.promptAndRun(_:)),
            keyEquivalent: ""
        )
        item.target = PeerDebugCoordinator.shared
        return item
    }

    static func relayItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Peer via Ghostty Relay… (debug)",
            action: #selector(PeerDebugCoordinator.promptAndRunRelay(_:)),
            keyEquivalent: ""
        )
        item.target = PeerDebugCoordinator.shared
        return item
    }
}

@MainActor
final class PeerDebugCoordinator: NSObject {
    static let shared = PeerDebugCoordinator()

    /// Holding onto the window controllers here keeps their reader Tasks
    /// alive; dropping the reference would cancel the stream.
    private var openConsoles: [PeerDebugConsoleWindowController] = []
    private var openRelays: [PeerRelayWindowController] = []

    @objc func promptAndRunRelay(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Peer via Ghostty Relay"
        alert.informativeText = "Path to a Swift peer server socket (e.g. TERMMESH_DEBUG_PEER_SERVER_PATH).\nOpens remote pane in a real Ghostty surface."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = ProcessInfo.processInfo.environment["TERMMESH_DEBUG_PEER_SERVER_PATH"] ?? "/tmp/termmesh-app-peer.sock"
        alert.accessoryView = input
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }

        Task {
            func traceLog(_ msg: String) {
                let line = "\(Date()): [peer-relay] \(msg)\n"
                if let data = line.data(using: .utf8) {
                    let url = URL(fileURLWithPath: "/tmp/peer-relay-trace.log")
                    if let fh = try? FileHandle(forWritingTo: url) {
                        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                    } else {
                        try? data.write(to: url)
                    }
                }
            }
            traceLog("task started, connecting to \(path)")
            do {
                let session = try await PeerRelaySession.create(hostSockPath: path)
                traceLog("session created, preparing listener")
                try session.prepareListener()
                traceLog("listener ready at \(session.relaySockPath)")
                let controller = PeerRelayWindowController(session: session)
                self.openRelays.append(controller)
                controller.onClose = { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    self.openRelays.removeAll { $0 === controller }
                }
                traceLog("showing window")
                controller.show()
            } catch {
                traceLog("ERROR: \(error)")
                self.showAlert(title: "Peer Relay Failed", body: String(describing: error))
            }
        }
    }

    @objc func promptAndRun(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to peer socket"
        alert.informativeText = "Path to a term-meshd peer socket (see TERMMESH_PEER_SOCKET)."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = defaultSocketPath()
        input.placeholderString = "/tmp/termmesh-peer.sock"
        alert.accessoryView = input
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }

        Task { await self.run(socketPath: path) }
    }

    private func run(socketPath: String) async {
        do {
            let transport = try await UnixSocketTransport.connect(socketPath: socketPath)
            let session = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            let info = try await session.handshake()
            let surfaces = try await session.listSurfaces()
            guard let chosen = surfaces.first(where: { $0.attachable }) ?? surfaces.first else {
                await transport.close()
                showAlert(title: "No surfaces on host", body: "\(info.hostDisplayName) reports no exposable surfaces.")
                return
            }

            let outcome = try await session.attachSurface(
                id: chosen.surfaceID,
                mode: .coWrite,
                cols: 80,
                rows: 24
            )

            let controller = PeerDebugConsoleWindowController(
                hostName: info.hostDisplayName,
                surfaceTitle: chosen.title,
                surfaceID: outcome.surfaceID,
                session: session,
                transport: transport
            )
            openConsoles.append(controller)
            controller.onClose = { [weak self] in
                guard let self else { return }
                self.openConsoles.removeAll { $0 === controller }
            }
            controller.show()
        } catch {
            showAlert(title: "Peer connection failed", body: String(describing: error))
        }
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func defaultSocketPath() -> String {
        if let env = ProcessInfo.processInfo.environment["TERMMESH_PEER_SOCKET"],
           !env.isEmpty
        {
            return env
        }
        return "/tmp/termmesh-peer.sock"
    }
}

@MainActor
final class PeerDebugConsoleWindowController: NSWindowController, NSWindowDelegate {
    private let surfaceID: Data
    private let session: PeerSession
    private let transport: UnixSocketTransport
    private let outputView: NSTextView
    private let inputField: NSTextField
    private var readerTask: Task<Void, Never>?
    private var isClosing = false

    var onClose: (@MainActor () -> Void)?

    init(
        hostName: String,
        surfaceTitle: String,
        surfaceID: Data,
        session: PeerSession,
        transport: UnixSocketTransport
    ) {
        self.surfaceID = surfaceID
        self.session = session
        self.transport = transport

        let outputView = Self.makeOutputView()
        let inputField = Self.makeInputField()
        self.outputView = outputView
        self.inputField = inputField

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = outputView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(inputField)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),
            inputField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            inputField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            inputField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(hostName) · \(surfaceTitle)  [peer-debug]"
        window.contentView = root
        window.center()

        super.init(window: window)
        window.delegate = self

        inputField.target = self
        inputField.action = #selector(sendInputLine(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        inputField.window?.makeFirstResponder(inputField)
        startReader()
        appendText("[connected]\n")
    }

    private func startReader() {
        readerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let msg: PeerIncomingMessage
                do {
                    msg = try await self.session.receiveNextMessage()
                } catch {
                    await self.handleStreamError(error)
                    return
                }
                await self.handle(msg)
                if case .goodbye = msg { return }
            }
        }
    }

    private func handle(_ msg: PeerIncomingMessage) {
        switch msg {
        case .ptyData(_, _, let payload):
            append(payload)
        case .workspaceMeta(let cwd, let branch, _, _):
            appendText("[workspace: cwd=\(cwd)\(branch.isEmpty ? "" : " @\(branch)")]\n")
        case .error(let code, let message):
            appendText("\n[peer error \(code)] \(message)\n")
        case .goodbye(let reason):
            appendText("\n[host goodbye: \(reason)]\n")
            closeWindow()
        default:
            break
        }
    }

    private func handleStreamError(_ error: Error) {
        appendText("\n[stream error] \(error)\n")
        closeWindow()
    }

    private func append(_ data: Data) {
        let text = String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>\n"
        appendText(text)
    }

    private func appendText(_ text: String) {
        guard let ts = outputView.textStorage else { return }
        let attr = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.textColor, .font: Self.monospaceFont]
        )
        ts.append(attr)
        outputView.scrollRangeToVisible(NSRange(location: ts.length, length: 0))
    }

    @objc private func sendInputLine(_ sender: NSTextField) {
        let line = sender.stringValue + "\n"
        sender.stringValue = ""
        let payload = Data(line.utf8)
        let surfaceID = self.surfaceID
        let session = self.session
        Task {
            try? await session.sendInput(surfaceID: surfaceID, keys: payload)
        }
    }

    private func closeWindow() {
        guard !isClosing else { return }
        isClosing = true
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        readerTask?.cancel()
        readerTask = nil
        let session = self.session
        let transport = self.transport
        let surfaceID = self.surfaceID
        _ = surfaceID  // silence
        Task {
            try? await session.sendGoodbye(reason: "debug console closed")
            await transport.close()
        }
        onClose?()
    }

    // MARK: - Helpers

    private static func makeOutputView() -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = false
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.font = monospaceFont
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        return tv
    }

    private static func makeInputField() -> NSTextField {
        let f = NSTextField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.placeholderString = "type here, Enter to send"
        f.font = monospaceFont
        f.focusRingType = .default
        return f
    }

    private static var monospaceFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }
}
#endif
