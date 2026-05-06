// Phase W: layout-preserving relay window. Hosts N PeerRelaySessions
// inside a single NSWindow, arranged in NSSplitViews that mirror the
// host workspace's bonsplit tree.
//
// Each pane in the workspace gets:
//   * its own PeerRelayConnection (independent transport, so closing
//     one pane does not tear down the others),
//   * a PeerRelaySession driving a relay binary process,
//   * a TerminalSurface whose "shell" is the relay binary, embedded
//     in the appropriate NSSplitView leaf slot.
//
// The split tree from the host (`Termmesh_Peer_V1_WorkspaceLayout`) is
// translated 1:1 to NSSplitView nesting. Divider positions are
// re-applied after the window has its final size so percentages map
// to actual pixels.

#if DEBUG
import AppKit
import PeerProto

@MainActor
final class PeerRelayWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private let hostSockPath: String
    private let workspace: Termmesh_Peer_V1_Workspace
    private var sessions: [PeerRelaySession] = []
    // TerminalSurface owns the live ghostty_surface_t; without a
    // strong reference here it deinits when buildPaneView returns,
    // which frees the ghostty surface before Ghostty has a chance to
    // spawn the relay binary as the surface's child shell.
    private var terminalSurfaces: [TerminalSurface] = []
    private var pendingDividerSetters: [(NSSplitView, CGFloat)] = []
    private var startTask: Task<Void, Never>?
    private var isClosing = false

    var onClose: (@MainActor () -> Void)?

    init(hostSockPath: String, workspace: Termmesh_Peer_V1_Workspace) {
        self.hostSockPath = hostSockPath
        self.workspace = workspace

        let initialSize = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let window = NSWindow(
            contentRect: initialSize,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let title = workspace.title.isEmpty ? "<workspace>" : workspace.title
        window.title = "Peer Workspace · \(title)"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)

        // Build all relay sessions, then build the NSSplitView tree
        // and mount the resulting view as the window content.
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let view = try await self.buildLayoutTree(self.workspace.layout)
                await MainActor.run {
                    guard let window = self.window else { return }
                    let container = NSView(frame: window.contentLayoutRect)
                    view.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(view)
                    NSLayoutConstraint.activate([
                        view.topAnchor.constraint(equalTo: container.topAnchor),
                        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    ])
                    window.contentView = container
                    self.applyPendingDividerPositions()
                }
            } catch {
                NSLog("[peer-relay] workspace start failed: %@", String(describing: error))
                await MainActor.run {
                    self.window?.performClose(nil)
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        startTask?.cancel()
        startTask = nil
        let toStop = sessions
        sessions.removeAll()
        Task {
            for s in toStop {
                await s.stop()
            }
        }
        onClose?()
    }

    // MARK: - Tree → view

    /// Recursively walks the proto layout tree, building either an
    /// NSSplitView (interior) or an embedded TerminalSurface
    /// (leaf). Each leaf brings up its own PeerRelaySession, which we
    /// retain on `sessions` so the streams keep running.
    private func buildLayoutTree(_ layout: Termmesh_Peer_V1_WorkspaceLayout) async throws -> NSView {
        switch layout.node {
        case .pane(let pane):
            return try await buildPaneView(pane)
        case .split(let split):
            let firstView = try await buildLayoutTree(split.first)
            let secondView = try await buildLayoutTree(split.second)
            return makeSplitView(orientation: split.orientation,
                                 dividerPosition: CGFloat(split.dividerPosition),
                                 first: firstView,
                                 second: secondView)
        case .none:
            throw NSError(domain: "PeerRelayWorkspace", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty layout node"])
        }
    }

    private func buildPaneView(_ pane: Termmesh_Peer_V1_WorkspacePane) async throws -> NSView {
        // Each pane uses an independent connection so per-pane close
        // doesn't cascade. PeerRelaySession.attach reuses the
        // connection's session/transport, so we burn one handshake
        // per pane — fine for local sockets and acceptable for SSH
        // tunnels (the SSH multiplexer collapses them anyway).
        let conn = try await PeerRelaySession.connectAndList(hostSockPath: hostSockPath)

        // Find the matching surface in the freshly-listed set so we
        // pick up any cols/rows updates since the workspace listing.
        let chosen = conn.surfaces.first(where: { $0.surfaceID == pane.surfaceID })
                        ?? makeFallbackSurfaceInfo(from: pane)
        let session = try await PeerRelaySession.attach(conn, surface: chosen)
        try session.prepareListener()

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: nil,
            command: session.relayBinaryPath,
            environment: ["TERMMESH_PEER_RELAY_SOCKET": session.relaySockPath]
        )
        sessions.append(session)
        terminalSurfaces.append(surface)
        session.onDisconnect = { [weak self] in
            _ = self
        }

        // Start the relay pump after the surface view is on screen
        // (Ghostty needs a window to spawn its child process).
        Task {
            do {
                try await session.start()
            } catch {
                NSLog("[peer-relay] workspace pane start failed: %@", String(describing: error))
            }
        }

        let host = surface.hostedView
        host.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: wrapper.topAnchor),
            host.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    private func makeFallbackSurfaceInfo(from pane: Termmesh_Peer_V1_WorkspacePane) -> Termmesh_Peer_V1_SurfaceInfo {
        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = pane.surfaceID
        info.title = pane.title
        info.cols = pane.cols
        info.rows = pane.rows
        info.cwd = pane.cwd
        info.surfaceType = "terminal"
        info.attachable = true
        return info
    }

    /// bonsplit "horizontal" = side-by-side, "vertical" = stacked.
    /// NSSplitView is the inverse: `isVertical=true` puts subviews
    /// side-by-side. Translate accordingly.
    private func makeSplitView(orientation: String, dividerPosition: CGFloat, first: NSView, second: NSView) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = (orientation == "horizontal")
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addSubview(first)
        split.addSubview(second)
        // Defer divider-position application until the view has size,
        // otherwise NSSplitView rounds to 0 / max.
        pendingDividerSetters.append((split, dividerPosition))
        return split
    }

    private func applyPendingDividerPositions() {
        guard let window = self.window else { return }
        // Two-pass: layout once so split views know their sizes, then
        // apply percentages.
        window.contentView?.layoutSubtreeIfNeeded()
        for (split, fraction) in pendingDividerSetters {
            let extent: CGFloat = split.isVertical ? split.bounds.width : split.bounds.height
            guard extent > 0 else { continue }
            let position = max(20, min(extent - 20, extent * fraction))
            split.setPosition(position, ofDividerAt: 0)
        }
        // Don't clear `pendingDividerSetters` — re-apply on resize via
        // splitViewDidResizeSubviews if NSSplitView clamps positions.
    }
}
#endif
