//  Phase C-3b-β + C-3c.2α: DEBUG-only hook that lets a developer exercise
//  the Swift peer-federation client from inside term-mesh.app without
//  touching any terminal UI yet.
//
//  Flow:
//   1. Menu item → NSAlert prompt for socket path.
//   2. Connect + handshake + list (from C-3b-β).
//   3. Attach to the first surface (C-3c.2α).
//   4. Open a `PeerConsoleWindow`:
//        - NSTextView (read-only) streams raw PtyData bytes as UTF-8. No
//          ANSI escape processing — the user sees the raw tty stream,
//          which is the point: it proves bytes are flowing into the GUI
//          process and rendering on-screen.
//        - NSTextField below lets the developer type a line and hit
//          Enter; it gets sent as an Input frame, field clears.
//        - Closing the window sends Goodbye and tears down the transport.

import AppKit
import Bonsplit
import Darwin
import PeerProto

@MainActor
enum PeerMenu {
    static func item() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Peer…",
            action: #selector(PeerClientCoordinator.promptAndRun(_:)),
            keyEquivalent: ""
        )
        item.target = PeerClientCoordinator.shared
        return item
    }

    static func relayWorkspaceItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Connect to Peer Workspace via Ghostty Relay…",
            action: #selector(PeerClientCoordinator.promptAndRunRelayWorkspace(_:)),
            keyEquivalent: ""
        )
        item.target = PeerClientCoordinator.shared
        return item
    }

    /// The sidebar-first replacement for the legacy SSH connect dialog:
    /// opens the saved-host editor sheet in the main window's sidebar.
    static func addRemoteHostItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Peer Hosts", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Peer Hosts")
        submenu.delegate = PeerClientCoordinator.shared
        item.submenu = submenu
        PeerClientCoordinator.shared.populatePeerHostsMenu(submenu)
        return item
    }

    static func connectionsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Show Peer Connections…",
            action: #selector(PeerClientCoordinator.showConnections(_:)),
            keyEquivalent: ""
        )
        item.target = PeerClientCoordinator.shared
        return item
    }

}

@MainActor
final class PeerClientCoordinator: NSObject, NSMenuDelegate {
    static let shared = PeerClientCoordinator()
    private static let setupReadTimeoutSeconds: TimeInterval = 10

    /// Posted whenever the active-relays roster changes (open / close).
    /// `PeerConnectionsWindowController` listens to refresh its table.
    static let relaysDidChangeNotification = Notification.Name("PeerClientCoordinatorRelaysDidChange")

    /// Holding onto the window controllers here keeps their reader Tasks
    /// alive; dropping the reference would cancel the stream.
    private var openConsoles: [PeerConsoleWindowController] = []
    private var openRelays: [PeerRelayWindowController] = []
    private var openWorkspaceRelays: [PeerRelayWorkspaceWindowController] = []
    /// Active SSH tunnels keyed by the controller they back. The
    /// tunnel must outlive the relay window; dropped tunnels yank the
    /// forwarded socket out from under the relay sessions.
    private var sshTunnels: [ObjectIdentifier: PeerSSHTunnel] = [:]
    private var activeConnectionFlows: Set<ConnectionFlow> = []
    private var savedRunnerStatuses: [UUID: PeerSavedRunnerStatus] = [:]
    private var savedRunnerProfilesInFlight: Set<UUID> = []

    static let savedRunnerStatusDidChangeNotification =
        Notification.Name("PeerSavedRunnerStatusDidChange")

    private enum ConnectionFlow: Hashable {
        case console(String)
        case relayPane(String)
        case workspace(String)
        case workspaceSSH(target: String, remote: String)

        var displayName: String {
            switch self {
            case .console(let path):
                return "peer console at \(path)"
            case .relayPane(let path):
                return "peer relay at \(path)"
            case .workspace(let path):
                return "peer workspace at \(path)"
            case .workspaceSSH(let target, let remote):
                return "SSH peer workspace \(target):\(remote)"
            }
        }
    }

    /// Snapshot of every active peer connection for the Connections
    /// panel. Returned in open-order. Exposes value types rather than
    /// controllers so external observers don't grow a dependency on
    /// AppKit window-controller internals.
    func activeConnections() -> [PeerRelayConnectionInfo] {
        let infos = (openConsoles.map { $0.connectionInfo }
            + openRelays.map { $0.connectionInfo }
            + openWorkspaceRelays.map { $0.connectionInfo }
            + openPaneSessions.map { $0.connectionInfo }
            + openWorkspaceMirrors.map { $0.connectionInfo })
            .sorted { $0.connectedAt < $1.connectedAt }
#if DEBUG
        dlog("peer.connections.active count=\(infos.count) consoles=\(openConsoles.count) relays=\(openRelays.count) workspaces=\(openWorkspaceRelays.count)")
        for info in infos {
            dlog("peer.connections.active row kind=\(info.kind.rawValue) host=\(info.hostDisplay) ssh=\(info.sshTarget ?? "nil") target=\(info.targetTitle)")
        }
#endif
        return infos
    }

    /// Disconnect (close) the relay window matching `id`. No-op when
    /// the controller has already been released or removed from the
    /// roster — safer than indexing by row position.
    func disconnect(id: ObjectIdentifier) {
        if let ctrl = openWorkspaceRelays.first(where: { ObjectIdentifier($0) == id }) {
            ctrl.window?.performClose(nil)
            return
        }
        if let ctrl = openRelays.first(where: { ObjectIdentifier($0) == id }) {
            ctrl.window?.performClose(nil)
            return
        }
        if let ctrl = openConsoles.first(where: { ObjectIdentifier($0) == id }) {
            ctrl.window?.performClose(nil)
            return
        }
        if let session = openPaneSessions.first(where: { ObjectIdentifier($0) == id }) {
            // Prefer closing the hosting pane (which tears the session
            // down through TerminalPanel.close()); fall back to a bare
            // teardown when the pane hook is gone.
            if let closePane = session.requestPaneClose {
                closePane()
            } else {
                session.teardown()
            }
            return
        }
        if let mirror = openWorkspaceMirrors.first(where: { ObjectIdentifier($0) == id }) {
            // Closing the workspace tab tears everything down through
            // TabManager.closeWorkspace → panel closes + mirror teardown.
            if let workspace = mirror.workspace,
               let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspace.id)
            {
                tabManager.closeWorkspace(workspace)
            } else {
                mirror.teardown()
            }
        }
    }

    // MARK: - Remote pane roster (Phase 1 remote pane primitive)

    /// Main-window remote panes, kept in the same roster that feeds the
    /// Connections panel and the sidebar's Remote Hosts section. Strong
    /// references are safe: `PeerPaneSession.teardown()` always
    /// deregisters, and the hosting TerminalPanel always tears down on
    /// close.
    private var openPaneSessions: [PeerPaneSession] = []

    func registerPaneSession(_ session: PeerPaneSession) {
        guard !openPaneSessions.contains(where: { $0 === session }) else { return }
        openPaneSessions.append(session)
        postRelaysChanged()
    }

    func deregisterPaneSession(_ session: PeerPaneSession) {
        let before = openPaneSessions.count
        openPaneSessions.removeAll { $0 === session }
        guard openPaneSessions.count != before else { return }
        postRelaysChanged()
    }

    // MARK: - Live workspace mirrors (Phase 2B)

    private var openWorkspaceMirrors: [PeerWorkspaceMirrorController] = []

    func registerWorkspaceMirror(_ mirror: PeerWorkspaceMirrorController) {
        guard !openWorkspaceMirrors.contains(where: { $0 === mirror }) else { return }
        openWorkspaceMirrors.append(mirror)
        postRelaysChanged()
    }

    func deregisterWorkspaceMirror(_ mirror: PeerWorkspaceMirrorController) {
        let before = openWorkspaceMirrors.count
        openWorkspaceMirrors.removeAll { $0 === mirror }
        guard openWorkspaceMirrors.count != before else { return }
        postRelaysChanged()
    }

    func workspaceMirror(forWorkspaceId id: UUID) -> PeerWorkspaceMirrorController? {
        openWorkspaceMirrors.first { $0.workspace?.id == id }
    }

    fileprivate func postRelaysChanged() {
#if DEBUG
        dlog("peer.connections.post consoles=\(openConsoles.count) relays=\(openRelays.count) workspaces=\(openWorkspaceRelays.count)")
#endif
        NotificationCenter.default.post(name: Self.relaysDidChangeNotification, object: self)
    }

    private func beginConnectionFlow(_ flow: ConnectionFlow) -> Bool {
        guard !activeConnectionFlows.contains(flow) else {
            showAlert(
                title: "Connection Already in Progress",
                body: "term-mesh is already connecting to \(flow.displayName)."
            )
            return false
        }
        activeConnectionFlows.insert(flow)
        return true
    }

    private func finishConnectionFlow(_ flow: ConnectionFlow) {
        activeConnectionFlows.remove(flow)
    }

    /// Posted by menu entries that want the saved-host editor; the
    /// sidebar's Remote Hosts section listens and presents its sheet.
    static let addRemoteHostRequestedNotification =
        Notification.Name("PeerAddRemoteHostRequested")

    /// Menu-bar / main-menu entry point for adding a saved host. The
    /// editor sheet lives in the main window's sidebar, so activate the
    /// app first (explicit user intent from a menu — not a socket
    /// command, so the focus policy allows it).
    @objc func addRemoteHost(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: Self.addRemoteHostRequestedNotification, object: nil
        )
    }

    func populatePeerHostsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let add = NSMenuItem(
            title: "Add Peer Host…",
            action: #selector(addRemoteHost(_:)),
            keyEquivalent: ""
        )
        add.target = self
        menu.addItem(add)

        let profiles = PeerHostProfileStore.shared.savedRunnerProfiles
        guard !profiles.isEmpty else { return }
        menu.addItem(.separator())
        for profile in profiles {
            guard let runner = profile.savedRunner else { continue }
            let item = NSMenuItem(
                title: "Run \(profile.effectiveDisplayName) · \(runner.surface.cwd)",
                action: #selector(runSavedProfileFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id.uuidString
            item.isEnabled = !savedRunnerProfilesInFlight.contains(profile.id)
            menu.addItem(item)
        }
    }

    @objc private func runSavedProfileFromMenu(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID),
              let profile = PeerHostProfileStore.shared.profile(id: id)
        else { return }
        Task { await openSavedRunner(profile: profile) }
    }

    /// Picker-free saved MachineProfile launch. Stage updates contain only
    /// allowlisted machine/cwd/error fields, so UI and diagnostics never echo
    /// executable arguments, identity-file contents, or SSH stderr.
    func openSavedRunner(profile: PeerHostProfile) async {
        guard savedRunnerProfilesInFlight.insert(profile.id).inserted else {
            return
        }
        defer { savedRunnerProfilesInFlight.remove(profile.id) }
        await performOpenSavedRunner(profile: profile)
    }

    private func performOpenSavedRunner(profile: PeerHostProfile) async {
        guard let runner = profile.savedRunner else { return }
        let machine = profile.effectiveDisplayName
        let cwd = runner.surface.cwd
        var stage: PeerSavedRunnerStage = .probe
        updateSavedRunnerStatus(profileID: profile.id, stage: stage, machine: machine, cwd: cwd)

        let resolvedSocket: String
        do {
            let probed = try await PeerSocketProber.probe(
                sshTarget: profile.sshTarget,
                port: profile.sshPort,
                identityFile: profile.identityFile
            )
            resolvedSocket = profile.remoteSocket.isEmpty ? probed : profile.remoteSocket
        } catch {
            failSavedRunner(
                profileID: profile.id, stage: stage, machine: machine, cwd: cwd,
                code: Self.safeProbeErrorCode(error), context: "SSH or daemon socket probe failed"
            )
            return
        }
        guard !Task.isCancelled else {
            failSavedRunner(
                profileID: profile.id, stage: stage, machine: machine, cwd: cwd,
                code: "CANCELLED", context: "Launch cancelled"
            )
            return
        }

        let hostSpec = PeerPaneHostSpec.ssh(
            target: profile.sshTarget,
            remoteSockPath: resolvedSocket,
            port: profile.sshPort,
            identityFile: profile.identityFile
        )
        stage = .lease
        updateSavedRunnerStatus(profileID: profile.id, stage: stage, machine: machine, cwd: cwd)
        let lease: PeerPaneHostLease
        do {
            lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        } catch {
            failSavedRunner(
                profileID: profile.id, stage: stage, machine: machine, cwd: cwd,
                code: "TUNNEL_FAILED", context: "SSH tunnel could not be established"
            )
            return
        }

        let registry = PeerPaneHostRegistry.shared
        guard !Task.isCancelled else {
            registry.release(lease)
            failSavedRunner(
                profileID: profile.id, stage: stage, machine: machine, cwd: cwd,
                code: "CANCELLED", context: "Launch cancelled"
            )
            return
        }
        guard let workspace = Self.currentWorkspaceForPaneOpen() else {
            registry.release(lease)
            failSavedRunner(
                profileID: profile.id, stage: .openPane, machine: machine, cwd: cwd,
                code: "NO_ACTIVE_WORKSPACE", context: "Open a terminal workspace first"
            )
            return
        }

        stage = .ensure
        updateSavedRunnerStatus(profileID: profile.id, stage: stage, machine: machine, cwd: cwd)
        let ensured: (session: PeerPaneSession, outcome: PeerEnsureSurfaceOutcome)
        do {
            ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: runner.surface,
                attachment: runner.attachment,
                hostSpec: hostSpec,
                onEnsured: {
                    stage = .attach
                    self.updateSavedRunnerStatus(
                        profileID: profile.id, stage: stage,
                        machine: machine, cwd: cwd
                    )
                }
            )
        } catch {
            registry.release(lease)
            let safe = Self.safeRunnerError(error, fallbackStage: stage)
            failSavedRunner(
                profileID: profile.id, stage: safe.stage, machine: machine, cwd: cwd,
                code: safe.code, context: safe.context
            )
            return
        }
        guard !Task.isCancelled else {
            ensured.session.teardown()
            registry.release(lease)
            failSavedRunner(
                profileID: profile.id, stage: stage, machine: machine, cwd: cwd,
                code: "CANCELLED", context: "Launch cancelled"
            )
            return
        }
        registry.release(lease)

        guard workspace.openRemotePane(
            session: ensured.session,
            lifetime: runner.attachment.lifetime
        ) != nil else {
            ensured.session.teardown()
            failSavedRunner(
                profileID: profile.id, stage: .openPane, machine: machine, cwd: cwd,
                code: "PANE_OPEN_FAILED", context: "No focused terminal pane is available"
            )
            return
        }
        PeerHostProfileStore.shared.recordConnection(
            sshTarget: profile.sshTarget, resolvedSocket: resolvedSocket
        )
        updateSavedRunnerStatus(
            profileID: profile.id, stage: .ready, machine: machine, cwd: cwd,
            context: Self.ensureResultName(ensured.outcome.result)
        )
    }

    func savedRunnerStatus(profileID: UUID) -> PeerSavedRunnerStatus? {
        savedRunnerStatuses[profileID]
    }

    private func updateSavedRunnerStatus(
        profileID: UUID,
        stage: PeerSavedRunnerStage,
        machine: String,
        cwd: String,
        code: String? = nil,
        context: String? = nil
    ) {
        savedRunnerStatuses[profileID] = PeerSavedRunnerStatus(
            stage: stage, machine: machine, cwd: cwd,
            errorCode: code, safeContext: context
        )
        NotificationCenter.default.post(
            name: Self.savedRunnerStatusDidChangeNotification,
            object: self,
            userInfo: ["profileID": profileID]
        )
        #if DEBUG
        dlog("peer.runner.stage stage=\(stage.rawValue) machine=\(machine) cwd=\(cwd) code=\(code ?? "none")")
        #endif
    }

    private func failSavedRunner(
        profileID: UUID,
        stage: PeerSavedRunnerStage,
        machine: String,
        cwd: String,
        code: String,
        context: String
    ) {
        updateSavedRunnerStatus(
            profileID: profileID, stage: stage, machine: machine, cwd: cwd,
            code: code, context: context
        )
        showAlert(
            title: "Remote Runner Failed",
            body: "Stage: \(stage.rawValue)\nMachine: \(machine)\nCWD: \(cwd)\nError: \(code)\n\(context)"
        )
    }

    private static func safeProbeErrorCode(_ error: Error) -> String {
        guard let probeError = error as? PeerSocketProbeError else {
            return "PROBE_FAILED"
        }
        switch probeError {
        case .noSocketFound: return "DAEMON_UNAVAILABLE"
        case .timedOut: return "PROBE_TIMEOUT"
        case .sshFailed: return "SSH_FAILED"
        case .invalidResult: return "REMOTE_SOCKET_INVALID"
        case .spawnFailed: return "SSH_SPAWN_FAILED"
        }
    }

    static func safeRunnerError(
        _ error: Error,
        fallbackStage: PeerSavedRunnerStage
    ) -> (stage: PeerSavedRunnerStage, code: String, context: String) {
        if case RelayError.capabilityUnavailable = error {
            return (.ensure, "CAPABILITY_UNAVAILABLE", "Host does not support surface.ensure.v1")
        }
        if case RelayError.ensureRejected(let code, let wireStage, _) = error {
            let stage: PeerSavedRunnerStage = wireStage == "attach" ? .attach : .ensure
            return (stage, code, sanitizedRunnerContext(for: code))
        }
        if case PeerSessionError.attachRejected = error {
            return (.attach, "ATTACH_REJECTED", "Host rejected the exact surface attachment")
        }
        if case RelayError.surfaceIDMismatch = error {
            return (.attach, "SURFACE_ID_MISMATCH", "Host attached a different surface id")
        }
        if error is CancellationError {
            return (fallbackStage, "CANCELLED", "Launch cancelled")
        }
        let code = fallbackStage == .ensure
            ? "ENSURE_TRANSPORT_FAILED"
            : "ATTACH_FAILED"
        return (fallbackStage, code, "Peer request failed")
    }

    /// Deterministic UI allowlist for daemon failures. Peer-provided
    /// `safe_context` is intentionally never returned: the peer is a trust
    /// boundary and can put executable arguments, stderr, or secrets in that
    /// field despite the protocol contract.
    static func sanitizedRunnerContext(for code: String) -> String {
        switch code {
        case "INVALID_REQUEST", "REQUEST_TOO_LARGE":
            return "The saved runner specification is invalid"
        case "DUPLICATE_REQUEST_ID":
            return "The request identifier was already used"
        case "CWD_NOT_FOUND":
            return "The configured working directory does not exist"
        case "CWD_NOT_DIRECTORY":
            return "The configured working directory is not a directory"
        case "CWD_PERMISSION_DENIED", "CWD_ERROR":
            return "The configured working directory cannot be accessed"
        case "COMMAND_NOT_FOUND":
            return "The configured executable does not exist"
        case "COMMAND_PERMISSION_DENIED":
            return "The configured executable cannot be launched"
        case "COMMAND_EXITED", "COMMAND_SIGNALED":
            return "The remote process stopped during startup"
        case "COMMAND_EXEC_ERROR", "EXEC_HANDSHAKE_TRUNCATED",
             "EXEC_HANDSHAKE_INVALID_STAGE", "EXEC_HANDSHAKE_TIMEOUT":
            return "The remote process could not complete startup"
        case "SPEC_CONFLICT":
            return "This runner key already has a different specification"
        case "MALFORMED_RESPONSE":
            return "The host returned an invalid ensure response"
        case "INTERNAL", "ENSURE_FAILED":
            return "The host could not ensure the remote runner"
        default:
            return "The remote runner request failed"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Peer Hosts" else { return }
        populatePeerHostsMenu(menu)
    }

    private static func ensureResultName(
        _ result: Termmesh_Peer_V1_EnsureSurfaceResult
    ) -> String {
        switch result {
        case .created: return "CREATED"
        case .reused: return "REUSED"
        case .recreated: return "RECREATED"
        case .specConflict: return "SPEC_CONFLICT"
        case .failed: return "FAILED"
        case .unspecified: return "UNSPECIFIED"
        case .UNRECOGNIZED(let raw): return "UNRECOGNIZED_\(raw)"
        }
    }

    @objc func showConnections(_ sender: Any?) {
        PeerConnectionsWindowController.shared.showAndFocus()
    }

    /// Open a workspace relay window initiated from the sidebar.
    /// Registers the controller in the shared roster so the Connections
    /// panel and `RemoteHostStore` both see it.
    func openWorkspaceRelayForSidebar(
        hostSockPath: String,
        workspace: Termmesh_Peer_V1_Workspace,
        hostDisplayName: String?
    ) {
        let controller = PeerRelayWorkspaceWindowController(
            hostSockPath: hostSockPath,
            workspace: workspace,
            hostDisplayName: hostDisplayName
        )
        openWorkspaceRelays.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.openWorkspaceRelays.removeAll { $0 === controller }
            self.postRelaysChanged()
        }
        controller.show()
        postRelaysChanged()
    }

    /// Shared tail of the SSH workspace-relay connect flow — optional
    /// socket auto-detect, tunnel bring-up, recent-host bookkeeping,
    /// workspace relay window. The legacy connect dialog is gone
    /// (sidebar-first UX); kept for programmatic callers and future
    /// sidebar "open in relay window against a fresh tunnel" flows.
    /// `remote` may be empty: the socket path is then resolved on the
    /// remote host via `PeerSocketProber`.
    @MainActor
    private func connectWorkspaceSSH(target: String, remote: String) async {
        // Keyed by target + remote-as-typed; an empty remote still dedupes
        // concurrent auto-detect submissions for the same target.
        let flow = ConnectionFlow.workspaceSSH(target: target, remote: remote)
        guard beginConnectionFlow(flow) else { return }
        defer { finishConnectionFlow(flow) }

        var remote = remote
        if remote.isEmpty {
            do {
                remote = try await PeerSocketProber.probe(sshTarget: target)
            } catch {
                self.showAlert(
                    title: "Socket Auto-Detect Failed",
                    body: Self.probeFailureBody(error, target: target)
                )
                return
            }
        }

        let tunnel = PeerSSHTunnel(
            sshTarget: target,
            remoteSockPath: remote,
            dashboardRemotePort: PeerFederationSettings.forwardDashboard
                ? PeerFederationSettings.remoteDashboardPort
                : nil
        )
        do {
            try await tunnel.start()
        } catch {
            self.showAlert(title: "SSH Tunnel Failed",
                           body: String(describing: error))
            return
        }
        // Tunnel is up — remember the host (with the *resolved* socket
        // path) so the next connect dialog and the recent-hosts menu
        // have it ready.
        PeerFederationSettings.rememberRecentHost(
            .init(sshTarget: target, remoteSocket: remote)
        )
        PeerHostProfileStore.shared.recordConnection(
            sshTarget: target, resolvedSocket: remote
        )
        await self.openWorkspaceRelay(
            hostSockPath: tunnel.localSockPath,
            titleSuffix: " · \(target)",
            tunnel: tunnel
        )
    }

    // MARK: - Remote pane flow (Phase 1 remote pane primitive)

    /// SSH variant of the pane flow: resolve the socket (auto-detect
    /// when the field was empty), lease the host (shared tunnel), then
    /// open one chosen surface as a pane in the current workspace.
    private func connectRemotePaneSSH(target: String, remote: String) async {
        let flow = ConnectionFlow.workspaceSSH(target: target, remote: remote)
        guard beginConnectionFlow(flow) else { return }
        defer { finishConnectionFlow(flow) }

        var remote = remote
        if remote.isEmpty {
            do {
                remote = try await PeerSocketProber.probe(sshTarget: target)
            } catch {
                self.showAlert(
                    title: "Socket Auto-Detect Failed",
                    body: Self.probeFailureBody(error, target: target)
                )
                return
            }
        }
        let opened = await openRemotePaneFlow(
            spec: .ssh(target: target, remoteSockPath: remote, port: nil, identityFile: nil)
        )
        if opened {
            PeerFederationSettings.rememberRecentHost(
                .init(sshTarget: target, remoteSocket: remote)
            )
            PeerHostProfileStore.shared.recordConnection(
                sshTarget: target, resolvedSocket: remote
            )
        }
    }

    /// Sidebar entry — open a chosen surface as a pane in the current
    /// workspace using an explicit host spec. SSH hosts pass `.ssh(...)`
    /// so the pane leases its own tunnel and survives the origin relay
    /// closing plus reconnects (the tunnel's ephemeral local socket is
    /// re-derived per reconnect); direct hosts pass `.direct(...)` and
    /// still ride the shared live socket.
    func openRemotePane(spec: PeerPaneHostSpec) async {
        await openRemotePaneFlow(spec: spec)
    }

    /// Sidebar workspace-row entry — same tail as `openRemotePane`, but
    /// the surface candidates are resolved from a single remote
    /// workspace's layout tree instead of the host's flat surface list.
    func openWorkspaceSurfaceAsPane(spec: PeerPaneHostSpec, workspaceID: Data) async {
        await openRemotePaneFlow(spec: spec, workspaceID: workspaceID)
    }

    /// Shared tail: lease → list surfaces → pick → attach → split into
    /// the current workspace. Returns true when a pane actually opened.
    /// Balances the browse ref on every exit; an attached pane holds its
    /// own lease ref until teardown.
    ///
    /// `workspaceID` nil (host context menu) resolves candidates from the
    /// host's flat `ListSurfaces` roster, filtered to `attachable`. Set
    /// (workspace-row entry) it resolves candidates from that one
    /// workspace's layout tree via a fresh `ListWorkspaces` round-trip —
    /// `SurfaceInfo` carries no workspace id, so a flat surface list can't
    /// be scoped after the fact.
    @discardableResult
    private func openRemotePaneFlow(spec: PeerPaneHostSpec, workspaceID: Data? = nil) async -> Bool {
        let lease: PeerPaneHostLease
        do {
            lease = try await PeerPaneHostRegistry.shared.acquire(spec)
        } catch {
            self.showAlert(title: "Peer Connection Failed", body: String(describing: error))
            return false
        }
        let registry = PeerPaneHostRegistry.shared

        let surfaces: [Termmesh_Peer_V1_SurfaceInfo]
        do {
            if let workspaceID {
                guard let leaves = try await Self.leafSurfaces(forWorkspace: workspaceID, lease: lease) else {
                    // Stale sidebar row: the workspace was deleted (or
                    // never existed on this host) between the click and
                    // this round-trip. No-op with an error rather than
                    // falling back to some other workspace's panes.
                    registry.release(lease)
                    self.showAlert(
                        title: "Workspace Unavailable",
                        body: "This remote workspace is no longer available on the host."
                    )
                    return false
                }
                surfaces = leaves
            } else {
                surfaces = try await PeerPaneSession.listSurfaces(on: lease)
            }
        } catch {
            registry.release(lease)
            self.showAlert(title: "Surface List Failed", body: String(describing: error))
            return false
        }
        let attachable = surfaces.filter { $0.attachable }
        guard !attachable.isEmpty else {
            registry.release(lease)
            self.showAlert(
                title: "No Attachable Surfaces",
                body: workspaceID == nil
                    ? "The host reports no surfaces that allow per-surface attach."
                    : "This workspace has no panes to attach."
            )
            return false
        }

        let chosen: Termmesh_Peer_V1_SurfaceInfo?
        if attachable.count == 1 {
            chosen = attachable[0]
        } else {
            // Multi-candidate picker: backfill workspace names on the flat
            // host-level roster before showing it. ListSurfaces never
            // carries a workspace id, so `workspaceName` is always empty
            // coming from that RPC — the workspace-scoped roster (from
            // `leafSurfaces`) already has it stamped and skips this. A
            // failed/old-host lookup just leaves names blank; it must
            // never block the picker itself.
            let candidates: [Termmesh_Peer_V1_SurfaceInfo]
            if workspaceID == nil {
                let names = await Self.surfaceWorkspaceNames(lease: lease)
                candidates = names.isEmpty ? attachable : attachable.map { s in
                    guard s.workspaceName.isEmpty, let name = names[s.surfaceID] else { return s }
                    var stamped = s
                    stamped.workspaceName = name
                    return stamped
                }
            } else {
                candidates = attachable
            }
            chosen = await promptForSurfaceSelection(from: candidates)
        }
        guard let chosen else {
            registry.release(lease)
            return false
        }

        guard let lifetime = await promptForRemotePaneLifetime(surface: chosen) else {
            registry.release(lease)
            return false
        }

        guard let workspace = Self.currentWorkspaceForPaneOpen() else {
            registry.release(lease)
            self.showAlert(
                title: "No Active Workspace",
                body: "Open a terminal workspace first, then add the remote pane."
            )
            return false
        }

        let session: PeerPaneSession
        do {
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: chosen,
                title: chosen.title.isEmpty ? chosen.workspaceName : chosen.title,
                spec: spec
            )
        } catch {
            registry.release(lease)
            self.showAlert(title: "Attach Failed", body: String(describing: error))
            return false
        }
        // Browse ref done — the pane session holds its own ref now.
        registry.release(lease)

        guard workspace.openRemotePane(session: session, lifetime: lifetime) != nil else {
            session.teardown()
            self.showAlert(
                title: "Pane Open Failed",
                body: "No focused terminal pane to split from in the current workspace."
            )
            return false
        }
        #if DEBUG
        let surfaceHex = chosen.surfaceID.prefix(4).map { String(format: "%02x", $0) }.joined()
        dlog("peer.sidebar.openAsPane host=\(spec.hostKey) workspaceScoped=\(workspaceID != nil) surface=\(surfaceHex)")
        #endif
        return true
    }

    /// Resolve the surfaces belonging to `workspaceID` via a fresh
    /// `ListWorkspaces` round-trip on `lease`'s host (mirrors the
    /// connect/list/cancel shape `openRemoteWorkspaceMirror` already
    /// uses). Returns nil — not an empty array — when the workspace isn't
    /// in the roster, so the caller can tell "gone" apart from "empty".
    private static func leafSurfaces(
        forWorkspace workspaceID: Data,
        lease: PeerPaneHostLease
    ) async throws -> [Termmesh_Peer_V1_SurfaceInfo]? {
        let conn = try await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
        let workspaces: [Termmesh_Peer_V1_Workspace]
        do {
            workspaces = try await conn.session.listWorkspaces()
        } catch {
            await conn.cancel()
            throw error
        }
        await conn.cancel()
        guard let match = workspaces.first(where: { $0.workspaceID == workspaceID }) else {
            return nil
        }
        // Stamp the owning workspace's title onto each synthetic
        // SurfaceInfo so the picker can show it and the attach-title
        // fallback (chosen.workspaceName when a leaf's own title is
        // empty) still resolves to something useful.
        return collectLeafPanes(match.layout).map { leaf in
            var info = surfaceInfo(fromLeaf: leaf)
            info.workspaceName = match.title
            return info
        }
    }

    /// Best-effort surface_id → owning-workspace-title map, built from a
    /// fresh `ListWorkspaces` round-trip. Backfills `workspaceName` on the
    /// flat host-level `ListSurfaces` roster, which never carries it
    /// (daemon doesn't populate that field on that RPC). Never throws — a
    /// stale/old host or a transient RPC error just means no names get
    /// backfilled; the caller falls back to the un-annotated roster
    /// rather than the picker failing outright.
    private static func surfaceWorkspaceNames(lease: PeerPaneHostLease) async -> [Data: String] {
        do {
            let conn = try await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
            let workspaces: [Termmesh_Peer_V1_Workspace]
            do {
                workspaces = try await conn.session.listWorkspaces()
            } catch {
                await conn.cancel()
                throw error
            }
            await conn.cancel()
            var names: [Data: String] = [:]
            for ws in workspaces where !ws.title.isEmpty {
                for leaf in collectLeafPanes(ws.layout) {
                    names[leaf.surfaceID] = ws.title
                }
            }
            return names
        } catch {
            #if DEBUG
            dlog("peer.sidebar.surfaceWorkspaceNames failed error=\(error)")
            #endif
            return [:]
        }
    }

    private static func currentWorkspaceForPaneOpen() -> Workspace? {
        // NSApp.delegate is the SwiftUI adaptor shim, not our type —
        // AppDelegate.shared is the canonical accessor.
        AppDelegate.shared?.tabManager?.selectedWorkspace
    }

    // MARK: - Remote workspace mirror (Phase 2A — snapshot placement)

    /// Mirror opens currently in flight, keyed by host key description —
    /// a double click must not materialize two copies.
    private var mirrorOpensInFlight: Set<String> = []

    /// Open a host workspace as a NEW main-window workspace: read its
    /// split tree once and materialize one Phase-1 remote pane per leaf
    /// in the same shape (orientation + divider ratios). Layout is
    /// local-owned afterwards — this is the snapshot model; live
    /// host↔local layout sync is Phase 2B.
    func openRemoteWorkspaceMirror(
        spec: PeerPaneHostSpec,
        workspaceID: Data?,
        pickFirstWithoutPrompt: Bool = false,
        live: Bool = true
    ) async {
        // Live-mirror dedupe: a second live mirror of the same host
        // workspace is meaningless (both would be host-authoritative
        // copies), so re-clicking the sidebar row focuses the existing
        // mirror tab instead of materializing another one. Sidebar click
        // is explicit user focus intent, so selecting here respects the
        // socket focus policy.
        if live, let workspaceID,
           let existing = openWorkspaceMirrors.first(where: {
               !$0.isTornDown
                   && $0.lease.key == spec.hostKey
                   && $0.hostWorkspaceID == workspaceID
           }),
           let mirrorWorkspace = existing.workspace {
            // The sidebar is a shared singleton, so this row is clickable from
            // every window — but the mirror lives in exactly one of them.
            // `selectWorkspace` performs no ownership check, so pointing the
            // clicking window's manager at a workspace it does not own leaves
            // it rendering panes bound to the other window's portal: a black
            // pane, with no mirror created here either (we return below).
            let app = AppDelegate.shared
            let owner = app?.tabManagerFor(tabId: mirrorWorkspace.id)
            let clicked = app?.tabManager
            if let owner, owner === clicked {
                // Same window — plain focus, the original dedupe behaviour.
                owner.selectWorkspace(mirrorWorkspace)
            } else if let clicked, let selectedTabId = clicked.selectedTabId {
                // Different window. Raising the owner would yank focus away
                // from the window the user just clicked in, and selecting here
                // would black out this one — so touch neither, and say where
                // the mirror already is. One live mirror per host workspace is
                // deliberate: two copies would fight over the PTY's single
                // winsize (the daemon applies resizes last-writer-wins).
                clicked.notifications.addNotification(
                    tabId: selectedTabId,
                    surfaceId: nil,
                    title: "Already mirrored in another window",
                    subtitle: PeerHostProfileStore.shared.displayLabel(for: spec.hostKey),
                    body: "“\(mirrorWorkspace.title)” is live in another window. "
                        + "A host workspace mirrors into one window at a time — "
                        + "a second live copy would fight over the terminal size."
                )
            }
            #if DEBUG
            dlog("peer.mirror.dedupe host=\(spec.hostKey) owner=\(owner == nil ? "nil" : (owner === clicked ? "sameWindow" : "otherWindow"))")
            #endif
            return
        }

        let flowKey = spec.hostKey.description
        guard !mirrorOpensInFlight.contains(flowKey) else { return }
        mirrorOpensInFlight.insert(flowKey)
        defer { mirrorOpensInFlight.remove(flowKey) }

        let registry = PeerPaneHostRegistry.shared
        let lease: PeerPaneHostLease
        do {
            lease = try await registry.acquire(spec)
        } catch {
            self.showAlert(title: "Peer Connection Failed", body: String(describing: error))
            return
        }

        let workspaces: [Termmesh_Peer_V1_Workspace]
        do {
            let conn = try await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
            // Live mirror needs the host to support workspace-lifecycle RPCs
            // and the layout-changed / WorkspaceRemoved push it subscribes to
            // (`workspace.lifecycle.v1`). An older host (e.g. a term-meshd that
            // predates that capability) still completes the handshake, so the
            // mirror used to build the workspace and only fail later inside
            // `start()` when it hit the missing subscription — leaving a dead
            // first-pane-only workspace behind on every retry (the duplicate-
            // zombie accumulation the user hit against a 0.72.0 host). Refuse
            // up front, before any workspace is materialized, with an
            // actionable "update the host" message.
            if live, !conn.hostCapabilities.has(PeerCapability.workspaceLifecycleV1) {
                let ver = conn.hostAppVersion.map { "term-meshd \($0)" }
                    ?? "an older term-meshd build"
                await conn.cancel()
                registry.release(lease)
                self.showAlert(
                    title: "Host Too Old for Live Mirror",
                    body: "This host is running \(ver), which doesn't support "
                        + "live workspace mirroring (needs workspace.lifecycle.v1). "
                        + "Update the host's term-meshd and reconnect."
                )
                return
            }
            do {
                workspaces = try await conn.session.listWorkspaces()
            } catch {
                await conn.cancel()
                throw error
            }
            await conn.cancel()
        } catch {
            registry.release(lease)
            self.showAlert(title: "Workspace List Failed", body: String(describing: error))
            return
        }
        guard !workspaces.isEmpty else {
            registry.release(lease)
            self.showAlert(
                title: "No Workspaces",
                body: "The host reports no workspaces (older hosts may not expose layouts)."
            )
            return
        }

        let chosen: Termmesh_Peer_V1_Workspace?
        if let workspaceID {
            chosen = workspaces.first { $0.workspaceID == workspaceID } ?? workspaces.first
        } else if workspaces.count == 1 || pickFirstWithoutPrompt {
            chosen = workspaces[0]
        } else {
            chosen = await promptForWorkspaceSelection(from: workspaces)
        }
        guard let chosen else {
            registry.release(lease)
            return
        }

        guard let tabManager = AppDelegate.shared?.tabManager else {
            registry.release(lease)
            self.showAlert(title: "No Main Window", body: "Open a term-mesh window first.")
            return
        }

        // First leaf seeds the new workspace's initial pane; every other
        // leaf is split off recursively in the host tree's shape.
        // A freshly created (empty) workspace has no leaf yet — ask the
        // host to seed its first pane (NewTab targeted by workspace id,
        // workspace.lifecycle.v1 hosts spawn an ephemeral shell) and
        // re-list until it appears. Hosts that predate the field ignore
        // the request (F8) and we fall through to the alert.
        var resolved = chosen
        if Self.firstLeafPane(resolved.layout) == nil {
            resolved = await Self.seedEmptyWorkspace(chosen, lease: lease) ?? chosen
        }
        guard let firstLeaf = Self.firstLeafPane(resolved.layout) else {
            registry.release(lease)
            self.showAlert(title: "Empty Workspace", body: "The chosen workspace has no panes.")
            return
        }

        let firstSession: PeerPaneSession
        do {
            firstSession = try await PeerPaneSession.attach(
                lease: lease,
                surface: Self.surfaceInfo(fromLeaf: firstLeaf),
                title: firstLeaf.title,
                spec: spec
            )
        } catch {
            registry.release(lease)
            self.showAlert(title: "Attach Failed", body: String(describing: error))
            return
        }

        let workspace = tabManager.addWorkspace(
            select: true,
            command: firstSession.relayLaunchCommand,
            environment: firstSession.relayEnvironment
        )
        let hostChip = PeerHostProfileStore.shared.displayLabel(for: spec.hostKey)
        // Distinct sidebar markers per mode — identical titles made the
        // two modes impossible to tell apart (or A/B test) in the tab
        // list: ⌁ = live host-synced mirror, ⧉ = detached layout copy.
        let mirrorBaseTitle = chosen.title.isEmpty ? "Workspace" : chosen.title
        workspace.title = live
            ? "\(mirrorBaseTitle) ⌁ \(hostChip)"
            : "\(mirrorBaseTitle) ⧉ \(hostChip) (copy)"
        guard let firstPanel = workspace.panels.values
            .compactMap({ $0 as? TerminalPanel }).first
        else {
            firstSession.teardown()
            registry.release(lease)
            self.showAlert(title: "Mirror Failed", body: "New workspace has no terminal panel.")
            return
        }
        workspace.bindRemotePane(session: firstSession, to: firstPanel)

        if live {
            // Phase 2B live mirror: the controller owns the browse lease
            // ref from here (released in its teardown). Initial build
            // runs through the reconciler — one code path for open,
            // pushes, and reconnect.
            let mirror = PeerWorkspaceMirrorController(
                workspace: workspace,
                lease: lease,
                spec: spec,
                hostWorkspaceID: chosen.workspaceID,
                hostWorkspaceTitle: chosen.title
            )
            mirror.panelBySurfaceID[firstLeaf.surfaceID] = firstPanel.id
            workspace.peerMirror = mirror
            registerWorkspaceMirror(mirror)
            do {
                try await mirror.start()
            } catch {
                // Mirror couldn't initialize (listWorkspaces / subscribe /
                // reconcile failed): `startReceiveLoop` never ran, so there is
                // no reconnect machinery — the workspace is a frozen zombie,
                // not a live mirror. Leaving it open made every retry stack
                // another dead workspace (the duplicate-pane accumulation).
                // Close it, matching the host-gone auto-close path, and
                // surface an actionable error.
                workspace.peerMirror = nil
                mirror.teardown()
                AppDelegate.shared?.tabManagerFor(tabId: workspace.id)?
                    .closeWorkspace(workspace)
                self.showAlert(
                    title: "Live Mirror Failed",
                    body: "\(String(describing: error))\n\nThe workspace was closed. Reconnect to retry."
                )
                return
            }
            #if DEBUG
            dlog("peer.mirror.live.open host=\(spec.hostKey) workspace=\(chosen.title)")
            #endif
            return
        }

        await materializeLayout(
            resolved.layout, seed: firstPanel,
            workspace: workspace, lease: lease, spec: spec
        )

        // Copy the host's divider ratios onto the (shape-identical by
        // construction) local tree. A skipped leaf breaks the shape
        // match — the walk just stops descending that branch.
        Self.applyDividerRatios(
            host: resolved.layout,
            local: workspace.bonsplitController.treeSnapshot(),
            controller: workspace.bonsplitController
        )

        // Browse ref done — each pane session holds its own lease ref.
        registry.release(lease)
        #if DEBUG
        dlog("peer.mirror.open host=\(spec.hostKey) workspace=\(chosen.title) leaves=\(Self.countLeafPanes(resolved.layout))")
        #endif
    }

    /// Pre-order split materialization: split the seed's region for the
    /// top split (new pane = second subtree's first leaf), then recurse
    /// into both regions. A failed leaf attach logs and skips its
    /// subtree — the rest of the workspace still opens.
    private func materializeLayout(
        _ node: Termmesh_Peer_V1_WorkspaceLayout,
        seed: TerminalPanel,
        workspace: Workspace,
        lease: PeerPaneHostLease,
        spec: PeerPaneHostSpec
    ) async {
        guard case .split(let split) = node.node else { return }
        guard let secondLeaf = Self.firstLeafPane(split.second) else {
            await materializeLayout(split.first, seed: seed, workspace: workspace, lease: lease, spec: spec)
            return
        }
        let session: PeerPaneSession
        do {
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: Self.surfaceInfo(fromLeaf: secondLeaf),
                title: secondLeaf.title,
                spec: spec
            )
        } catch {
            NSLog("[peer-mirror] leaf attach failed, skipping subtree: %@", String(describing: error))
            await materializeLayout(split.first, seed: seed, workspace: workspace, lease: lease, spec: spec)
            return
        }
        let orientation = SplitOrientation(rawValue: split.orientation) ?? .horizontal
        guard let newPanel = workspace.openRemotePane(
            session: session, orientation: orientation, focus: false, from: seed.id
        ) else {
            session.teardown()
            NSLog("[peer-mirror] split failed, skipping subtree")
            await materializeLayout(split.first, seed: seed, workspace: workspace, lease: lease, spec: spec)
            return
        }
        await materializeLayout(split.first, seed: seed, workspace: workspace, lease: lease, spec: spec)
        await materializeLayout(split.second, seed: newPanel, workspace: workspace, lease: lease, spec: spec)
    }

    private static func applyDividerRatios(
        host: Termmesh_Peer_V1_WorkspaceLayout,
        local: ExternalTreeNode,
        controller: BonsplitController
    ) {
        guard case .split(let hostSplit) = host.node,
              case .split(let localSplit) = local
        else { return }
        if hostSplit.dividerPosition > 0, hostSplit.dividerPosition < 1,
           let splitId = UUID(uuidString: localSplit.id)
        {
            _ = controller.setDividerPosition(
                CGFloat(hostSplit.dividerPosition), forSplit: splitId
            )
        }
        applyDividerRatios(host: hostSplit.first, local: localSplit.first, controller: controller)
        applyDividerRatios(host: hostSplit.second, local: localSplit.second, controller: controller)
    }

    /// Ask the host to spawn the first pane of an empty workspace
    /// (NewTab targeted by workspace id), then poll the roster until
    /// the seeded pane shows up. Returns the refreshed workspace, or
    /// nil when the host never seeded one (old daemon — the field is
    /// ignored per F8 — or spawn failure); the caller falls back to
    /// its existing empty-workspace alert.
    private static func seedEmptyWorkspace(
        _ workspace: Termmesh_Peer_V1_Workspace,
        lease: PeerPaneHostLease
    ) async -> Termmesh_Peer_V1_Workspace? {
        do {
            let conn = try await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
            defer { Task { await conn.cancel() } }
            try await conn.session.requestNewTab(workspaceID: workspace.workspaceID)
            // The daemon applies NewTab asynchronously; poll until the
            // seeded pane appears (25 × 200ms = 5s), re-nudging with
            // another NewTab midway in case the first was dropped.
            for attempt in 0..<25 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if attempt == 12 {
                    try? await conn.session.requestNewTab(workspaceID: workspace.workspaceID)
                }
                let workspaces = try await conn.session.listWorkspaces()
                if let updated = workspaces.first(where: { $0.workspaceID == workspace.workspaceID }),
                   firstLeafPane(updated.layout) != nil {
                    #if DEBUG
                    dlog("peer.mirror.seed ok workspace=\(workspace.title) attempt=\(attempt)")
                    #endif
                    return updated
                }
            }
            #if DEBUG
            dlog("peer.mirror.seed timeout workspace=\(workspace.title)")
            #endif
            return nil
        } catch {
            #if DEBUG
            dlog("peer.mirror.seed error workspace=\(workspace.title) error=\(error)")
            #endif
            return nil
        }
    }

    private static func firstLeafPane(
        _ node: Termmesh_Peer_V1_WorkspaceLayout
    ) -> Termmesh_Peer_V1_WorkspacePane? {
        switch node.node {
        case .pane(let pane): return pane
        case .split(let split):
            return firstLeafPane(split.first) ?? firstLeafPane(split.second)
        case .none: return nil
        }
    }

    private static func countLeafPanes(_ node: Termmesh_Peer_V1_WorkspaceLayout) -> Int {
        switch node.node {
        case .pane: return 1
        case .split(let split):
            return countLeafPanes(split.first) + countLeafPanes(split.second)
        case .none: return 0
        }
    }

    /// All leaf panes in a workspace's layout tree, left-to-right —
    /// `firstLeafPane`'s sibling for callers that need the full roster
    /// (e.g. the workspace-scoped pane-open picker) rather than just one.
    private static func collectLeafPanes(
        _ node: Termmesh_Peer_V1_WorkspaceLayout
    ) -> [Termmesh_Peer_V1_WorkspacePane] {
        switch node.node {
        case .pane(let pane): return [pane]
        case .split(let split):
            return collectLeafPanes(split.first) + collectLeafPanes(split.second)
        case .none: return []
        }
    }

    /// AttachSurface only needs id + geometry; the layout leaf carries
    /// both, so the mirror never has to cross-reference ListSurfaces.
    private static func surfaceInfo(
        fromLeaf leaf: Termmesh_Peer_V1_WorkspacePane
    ) -> Termmesh_Peer_V1_SurfaceInfo {
        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = leaf.surfaceID
        info.title = leaf.title
        info.cols = leaf.cols
        info.rows = leaf.rows
        info.cwd = leaf.cwd
        info.attachable = true
        return info
    }

    #if DEBUG
    // MARK: - Remote pane debug hooks (tests_v2 socket e2e)

    /// Result of the last `debug.peer.open_remote_pane`, polled via
    /// `debug.peer.pane_status`. The open command is fire-and-forget
    /// because the flow is async and the socket handler must not block
    /// the main thread.
    private(set) var debugLastPaneOpenResult: [String: Any]?

    /// Headless remote-pane open: no pickers, no alerts. With a nil
    /// sockPath, brings up the in-app peer server and mirrors one of
    /// this instance's own surfaces (loopback self-mirror). An sshTarget
    /// routes through the same ssh-tunnel spec the picker flow uses, so
    /// socket e2e can exercise a real remote host end to end.
    func debugOpenRemotePane(sockPath: String?, sshTarget: String? = nil, remoteSockPath: String? = nil) {
        debugLastPaneOpenResult = nil
        Task { @MainActor in
            let spec: PeerPaneHostSpec
            if let target = sshTarget, !target.isEmpty {
                guard let remoteSock = remoteSockPath, !remoteSock.isEmpty else {
                    self.debugLastPaneOpenResult = ["ok": false, "error": "no_remote_sock_path"]
                    return
                }
                spec = .ssh(target: target, remoteSockPath: remoteSock, port: nil, identityFile: nil)
                return await debugOpenRemotePaneResolved(spec: spec)
            }
            var resolvedSock = sockPath
            if resolvedSock == nil {
                _ = await PeerHostCoordinator.shared.setRunning(true)
                resolvedSock = PeerHostCoordinator.shared.currentSocketPath
            }
            guard let hostSock = resolvedSock, !hostSock.isEmpty else {
                self.debugLastPaneOpenResult = ["ok": false, "error": "no_host_socket"]
                return
            }
            await debugOpenRemotePaneResolved(spec: .direct(sockPath: hostSock))
        }
    }

    @MainActor
    private func debugOpenRemotePaneResolved(spec: PeerPaneHostSpec) async {
            let registry = PeerPaneHostRegistry.shared
            do {
                let lease = try await registry.acquire(spec)
                do {
                    let surfaces = try await PeerPaneSession.listSurfaces(on: lease)
                    guard let chosen = surfaces.first(where: { $0.attachable }) else {
                        registry.release(lease)
                        self.debugLastPaneOpenResult = ["ok": false, "error": "no_attachable_surface"]
                        return
                    }
                    guard let workspace = Self.currentWorkspaceForPaneOpen() else {
                        registry.release(lease)
                        self.debugLastPaneOpenResult = ["ok": false, "error": "no_active_workspace"]
                        return
                    }
                    let session = try await PeerPaneSession.attach(
                        lease: lease,
                        surface: chosen,
                        title: chosen.title.isEmpty ? chosen.workspaceName : chosen.title,
                        spec: spec
                    )
                    registry.release(lease)
                    guard let panel = workspace.openRemotePane(session: session) else {
                        session.teardown()
                        self.debugLastPaneOpenResult = ["ok": false, "error": "no_focused_terminal_pane"]
                        return
                    }
                    self.debugLastPaneOpenResult = [
                        "ok": true,
                        "panel_id": panel.id.uuidString,
                        "host_key": String(describing: session.lease.key),
                    ]
                } catch {
                    registry.release(lease)
                    self.debugLastPaneOpenResult = ["ok": false, "error": String(describing: error)]
                }
            } catch {
                self.debugLastPaneOpenResult = ["ok": false, "error": String(describing: error)]
            }
    }

    /// Test-only headless workspace mirror: no pickers/alerts on the
    /// happy path (first workspace auto-picked). Outcome polled via
    /// `debug.peer.pane_status` — session count reflects mirrored
    /// leaves.
    func debugOpenWorkspaceMirror(sockPath: String?, live: Bool = false) {
        debugLastPaneOpenResult = nil
        Task { @MainActor in
            var resolvedSock = sockPath
            if resolvedSock == nil {
                _ = await PeerHostCoordinator.shared.setRunning(true)
                resolvedSock = PeerHostCoordinator.shared.currentSocketPath
            }
            guard let hostSock = resolvedSock, !hostSock.isEmpty else {
                self.debugLastPaneOpenResult = ["ok": false, "error": "no_host_socket"]
                return
            }
            let before = self.openPaneSessions.count
            // Mirror the currently-SELECTED workspace: hosts key
            // workspaces by raw UUID bytes, so the loopback e2e can
            // seed a specific workspace, select it, and mirror exactly
            // it — first-listed would race with session-restored tabs.
            let selectedID = (AppDelegate.shared?.tabManager?.selectedWorkspace?.id.uuid)
                .map { withUnsafeBytes(of: $0) { Data($0) } }
            await self.openRemoteWorkspaceMirror(
                spec: .direct(sockPath: hostSock),
                workspaceID: selectedID,
                pickFirstWithoutPrompt: true,
                live: live
            )
            let opened = self.openPaneSessions.count - before
            self.debugLastPaneOpenResult = [
                "ok": opened > 0,
                "mirror": true,
                "live": live,
                "panes_opened": opened,
            ]
        }
    }

    /// Snapshot of live-mirror state for e2e assertions.
    func debugMirrorStatus() -> [String: Any] {
        [
            "mirrors": openWorkspaceMirrors.map { mirror -> [String: Any] in
                var entry: [String: Any] = [
                    "host_key": String(describing: mirror.spec.hostKey),
                    "subscription_alive": mirror.subscriptionAlive,
                    "applying": mirror.isApplyingRemoteLayout,
                    "leaf_count": mirror.panelBySurfaceID.count,
                    "split_map_count": mirror.hostSplitToLocal.count,
                    "torn_down": mirror.isTornDown,
                ]
                if let layout = mirror.lastAppliedLayout {
                    entry["shape"] = PeerWorkspaceMirrorController.shapeHash(layout)
                }
                if let workspaceId = mirror.workspace?.id.uuidString {
                    entry["workspace_id"] = workspaceId
                }
                return entry
            }
        ]
    }

    /// Snapshot of remote-pane state for e2e assertions.
    func debugPaneStatus() -> [String: Any] {
        [
            "pane_sessions": openPaneSessions.map { session in
                [
                    "host_key": String(describing: session.lease.key),
                    "title": session.surfaceTitle,
                    "torn_down": session.isTorndown,
                ] as [String: Any]
            },
            "lease_count": PeerPaneHostRegistry.shared.activeLeaseCount,
            "last_open_result": debugLastPaneOpenResult ?? NSNull(),
        ]
    }
    #endif

    /// Panels with a reconnect currently in flight — repeated banner
    /// clicks must not spawn concurrent reconnect tasks (double panes,
    /// double sessions).
    private var reconnectingPanelIds: Set<UUID> = []

    /// Reconnect action for a remote pane's disconnect banner: re-lease
    /// the host, find the original surface again (by id, then by title),
    /// attach a fresh session, and swap the dead pane IN PLACE — the new
    /// pane splits off the dead one (so it lands adjacent, not wherever
    /// focus happens to be) and only then is the dead pane closed. Any
    /// failure before that leaves the old pane and its banner (with
    /// Retry) untouched.
    func reconnectRemotePane(
        oldSession: PeerPaneSession,
        panelId: UUID,
        workspace: Workspace
    ) async {
        guard !reconnectingPanelIds.contains(panelId) else { return }
        reconnectingPanelIds.insert(panelId)
        defer { reconnectingPanelIds.remove(panelId) }

        let spec = oldSession.originSpec
        let wanted = oldSession.originSurface
        oldSession.teardown()

        let registry = PeerPaneHostRegistry.shared
        let lease: PeerPaneHostLease
        do {
            lease = try await registry.acquire(spec)
        } catch {
            self.showAlert(title: "Reconnect Failed", body: String(describing: error))
            return
        }
        let surfaces: [Termmesh_Peer_V1_SurfaceInfo]
        do {
            surfaces = try await PeerPaneSession.listSurfaces(on: lease)
        } catch {
            registry.release(lease)
            self.showAlert(title: "Reconnect Failed", body: String(describing: error))
            return
        }
        let match = surfaces.first { $0.surfaceID == wanted.surfaceID && $0.attachable }
            ?? surfaces.first { $0.title == wanted.title && $0.attachable }
        guard let match else {
            registry.release(lease)
            self.showAlert(
                title: "Surface Gone",
                body: "The remote surface no longer exists on the host."
            )
            return
        }
        let session: PeerPaneSession
        do {
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: match,
                title: match.title.isEmpty ? match.workspaceName : match.title,
                spec: spec
            )
        } catch {
            registry.release(lease)
            self.showAlert(title: "Reconnect Failed", body: String(describing: error))
            return
        }
        registry.release(lease)

        // Replacement first, removal second: split the new pane off the
        // dead one so it inherits the slot's neighborhood, then close
        // the dead pane. If the split fails the old pane (and banner)
        // survive for another retry.
        guard workspace.openRemotePane(session: session, from: panelId) != nil else {
            session.teardown()
            self.showAlert(
                title: "Reconnect Failed",
                body: "Could not open a replacement pane in the workspace."
            )
            return
        }
        _ = workspace.closePanel(panelId, force: true)
    }

    private static func probeFailureBody(_ error: Error, target: String) -> String {
        guard let probeError = error as? PeerSocketProbeError else {
            return String(describing: error)
        }
        switch probeError {
        case .noSocketFound:
            let candidates = PeerSocketProber.candidateSummary
                .map { "  • \($0)" }
                .joined(separator: "\n")
            return "Reached \(target), but no peer socket exists at any default location:\n\(candidates)\n\nIs term-meshd running on the host? Otherwise enter the socket path manually."
        case .sshFailed(_, let stderr):
            let detail = stderr.isEmpty ? "(no stderr)" : stderr
            return "Could not reach the host over ssh: \(detail)\n\nVerify that `ssh \(target)` works in a terminal."
        case .timedOut:
            return "The auto-detect probe timed out. Check the connection to \(target), or enter the socket path manually."
        case .invalidResult, .spawnFailed:
            return String(describing: probeError)
        }
    }

    /// Shared workflow: enumerate workspaces over a `PeerRelayConnection`
    /// rooted at `hostSockPath`, prompt for one when there are multiple,
    /// open a `PeerRelayWorkspaceWindowController` and own its lifetime.
    /// `tunnel` (when non-nil) is held alive until the controller closes
    /// and torn down on close.
    private func openWorkspaceRelay(hostSockPath: String,
                                    titleSuffix: String = "",
                                    tunnel: PeerSSHTunnel? = nil) async {
        let probe: PeerRelayConnection
        do {
            probe = try await PeerRelaySession.connect(hostSockPath: hostSockPath)
        } catch {
            tunnel?.stop()
            await MainActor.run {
                self.showAlert(title: "Peer Workspace Failed",
                               body: String(describing: error))
            }
            return
        }
        let workspaces: [Termmesh_Peer_V1_Workspace]
        await probe.transport.setReadTimeoutSeconds(Self.setupReadTimeoutSeconds)
        do {
            workspaces = try await probe.session.listWorkspaces()
        } catch {
            await probe.transport.setReadTimeoutSeconds(nil)
            await probe.cancel()
            tunnel?.stop()
            await MainActor.run {
                self.showAlert(title: "Peer Workspace Failed",
                               body: "listWorkspaces failed: \(error)")
            }
            return
        }
        await probe.transport.setReadTimeoutSeconds(nil)
        await probe.cancel()

        guard !workspaces.isEmpty else {
            tunnel?.stop()
            await MainActor.run {
                self.showAlert(title: "Peer Workspace Failed",
                               body: "Host did not return any workspaces.")
            }
            return
        }

        let chosen: Termmesh_Peer_V1_Workspace?
        if workspaces.count == 1 {
            chosen = workspaces[0]
        } else {
            chosen = await self.promptForWorkspaceSelection(from: workspaces)
        }
        guard let chosen else {
            tunnel?.stop()
            return
        }

        await MainActor.run {
            let controller = PeerRelayWorkspaceWindowController(
                hostSockPath: hostSockPath,
                workspace: chosen,
                hostDisplayName: probe.hostDisplayName
            )
            self.openWorkspaceRelays.append(controller)
#if DEBUG
            dlog("peer.connections.openWorkspaceRelay appended hasTunnel=\(tunnel != nil) host=\(hostSockPath) hostDisplay=\(probe.hostDisplayName) workspace=\(controller.connectionInfo.targetTitle)")
#endif
            if let tunnel {
                self.sshTunnels[ObjectIdentifier(controller)] = tunnel
                controller.attachTunnel(tunnel)
#if DEBUG
                dlog("peer.connections.openWorkspaceRelay attached tunnel sshTarget=\(tunnel.sshTarget)")
#endif
                if !titleSuffix.isEmpty {
                    controller.window?.title += titleSuffix
                }
            }
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.openWorkspaceRelays.removeAll { $0 === controller }
                if let stale = self.sshTunnels.removeValue(forKey: ObjectIdentifier(controller)) {
                    stale.stop()
                }
                self.postRelaysChanged()
            }
            controller.show()
            self.postRelaysChanged()
        }
    }

    @objc func promptAndRunRelayWorkspace(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Peer Workspace via Ghostty Relay"
        alert.informativeText = "Path to a Swift peer server socket. Picks one of the host's workspaces and mirrors its split layout in a single window."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = ProcessInfo.processInfo.environment["TERMMESH_DEBUG_PEER_SERVER_PATH"]
            ?? PeerHostCoordinator.shared.currentSocketPath
            ?? PeerFederationSettings.socketPath
        alert.accessoryView = input
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        Task { @MainActor in
            let resp = await Self.runModalAsSheet(alert)
            guard resp == .alertFirstButtonReturn else { return }
            let path = self.normalizedSocketPath(from: input.stringValue)
            guard !path.isEmpty else {
                self.showAlert(title: "Peer Socket Required", body: "Enter a peer socket path.")
                return
            }
            guard self.validateLocalSocketPathForConnect(path) else { return }
            await self.runWorkspaceFlow(path: path)
        }
    }

    /// Body of the workspace-relay flow, extracted from
    /// promptAndRunRelayWorkspace so the sheet-based completion can
    /// call it cleanly.
    private func runWorkspaceFlow(path: String) async {
        let flow = ConnectionFlow.workspace(path)
        guard beginConnectionFlow(flow) else { return }
        defer { finishConnectionFlow(flow) }

        // Open a probe connection to enumerate workspaces, then
        // discard it — each pane in the chosen workspace will
        // open its own connection.
        let probe: PeerRelayConnection
        do {
            probe = try await PeerRelaySession.connect(hostSockPath: path)
        } catch {
            self.showAlert(title: "Peer Workspace Failed",
                           body: String(describing: error))
            return
        }
        let workspaces: [Termmesh_Peer_V1_Workspace]
        await probe.transport.setReadTimeoutSeconds(Self.setupReadTimeoutSeconds)
        do {
            workspaces = try await probe.session.listWorkspaces()
        } catch {
            await probe.transport.setReadTimeoutSeconds(nil)
            await probe.cancel()
            self.showAlert(title: "Peer Workspace Failed",
                           body: "listWorkspaces failed: \(error)")
            return
        }
        await probe.transport.setReadTimeoutSeconds(nil)
        await probe.cancel()

        guard !workspaces.isEmpty else {
            self.showAlert(title: "Peer Workspace Failed",
                           body: "Host did not return any workspaces.")
            return
        }

        let chosen: Termmesh_Peer_V1_Workspace?
        if workspaces.count == 1 {
            chosen = workspaces[0]
        } else {
            chosen = await self.promptForWorkspaceSelection(from: workspaces)
        }
        guard let chosen else { return }

        let controller = PeerRelayWorkspaceWindowController(
            hostSockPath: path,
            workspace: chosen,
            hostDisplayName: probe.hostDisplayName
        )
        self.openWorkspaceRelays.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.openWorkspaceRelays.removeAll { $0 === controller }
            self.postRelaysChanged()
        }
        controller.show()
        self.postRelaysChanged()
    }

    private func promptForWorkspaceSelection(
        from workspaces: [Termmesh_Peer_V1_Workspace]
    ) async -> Termmesh_Peer_V1_Workspace? {
        let alert = NSAlert()
        alert.messageText = "Choose a workspace"
        alert.informativeText = "Host has \(workspaces.count) workspaces. The chosen one will open in a single window with its host split layout."

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 360, height: 26),
            pullsDown: false
        )
        // Group the roster by owning host window. When the host reports more
        // than one window, insert a disabled section-header item per window
        // and indent its workspaces; a single-window host keeps the flat list.
        let windowGroups = groupWorkspacesByWindow(
            workspaces,
            windowID: { $0.windowID },
            windowTitle: { $0.windowTitle }
        )
        let multiWindow = windowGroups.count > 1
        for group in windowGroups {
            if multiWindow {
                let header = NSMenuItem(
                    title: Self.menuSafeTitle(
                        peerWindowLabel(title: group.windowTitle, id: group.windowID),
                        maxLength: 80
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                header.isEnabled = false
                popup.menu?.addItem(header)
            }
            for w in group.items {
                let title = Self.menuSafeTitle(
                    w.title.isEmpty ? "<untitled>" : w.title,
                    maxLength: 64
                )
                let count = countLeaves(w.layout)
                let idHex = w.workspaceID.prefix(4).map { String(format: "%02x", $0) }.joined()
                let item = NSMenuItem(title: "\(title)  ·  \(count) panes  [\(idHex)]",
                                      action: nil, keyEquivalent: "")
                // Stash the workspace itself so the index→workspace mapping
                // survives the interleaved (non-selectable) header rows.
                item.representedObject = w
                if multiWindow { item.indentationLevel = 1 }
                popup.menu?.addItem(item)
            }
        }
        // Default the popup to the first real workspace, not a header row.
        if let firstReal = popup.menu?.items.first(where: { $0.representedObject != nil }) {
            popup.select(firstReal)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let resp = await Self.runModalAsSheet(alert)
        guard resp == .alertFirstButtonReturn else { return nil }
        return popup.selectedItem?.representedObject as? Termmesh_Peer_V1_Workspace
    }

    private func countLeaves(_ layout: Termmesh_Peer_V1_WorkspaceLayout) -> Int {
        switch layout.node {
        case .pane: return 1
        case .split(let s): return countLeaves(s.first) + countLeaves(s.second)
        case .none: return 0
        }
    }

    /// Show an NSAlert with an NSPopUpButton listing the available
    /// surfaces. Returns the user's pick, or nil if Cancel was clicked.
    private func promptForSurfaceSelection(
        from surfaces: [Termmesh_Peer_V1_SurfaceInfo]
    ) async -> Termmesh_Peer_V1_SurfaceInfo? {
        let alert = NSAlert()
        alert.messageText = "Choose a remote surface"
        alert.informativeText = "Host exposes \(surfaces.count) surfaces. Pick which one this relay window should mirror."

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 360, height: 26),
            pullsDown: false
        )
        // NSPopUpButton dedupes items by visible title — when the host
        // has multiple panes with the same title/cwd (e.g. four splits
        // in the same workspace), they collapse into one entry. Stamp a
        // short surfaceID prefix on every label and add NSMenuItem
        // directly (rather than addItem(withTitle:)) so each row stays
        // distinct.
        for s in surfaces {
            let title = Self.menuSafeTitle(
                s.title.isEmpty ? "<untitled>" : s.title,
                maxLength: 48
            )
            let detail = s.cwd.isEmpty ? "" : "  ·  \(Self.abbreviatedMenuPath(s.cwd))"
            let dims = "  (\(s.cols)×\(s.rows))"
            // Which remote workspace this surface lives in — only known
            // when the host populated it (flat host-level ListSurfaces
            // today never does) or the caller pre-stamped it (the
            // workspace-scoped pane-open picker always does). Omitted
            // rather than shown blank when unmapped.
            let workspaceLabel = s.workspaceName.isEmpty
                ? ""
                : "  ·  \(Self.menuSafeTitle(s.workspaceName, maxLength: 32))"
            let idHex = s.surfaceID.prefix(4).map { String(format: "%02x", $0) }.joined()
            let display = "\(title)\(detail)\(dims)\(workspaceLabel)  [\(idHex)]"
            let item = NSMenuItem(title: display, action: nil, keyEquivalent: "")
            popup.menu?.addItem(item)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let resp = await Self.runModalAsSheet(alert)
        guard resp == .alertFirstButtonReturn else { return nil }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < surfaces.count else { return nil }
        return surfaces[idx]
    }

    private func promptForRemotePaneLifetime(
        surface: Termmesh_Peer_V1_SurfaceInfo
    ) async -> RemotePaneLifetime? {
        let alert = NSAlert()
        alert.messageText = "Open remote pane"
        alert.informativeText = "Temporary collects changes before close. Keep Alive can be linked into another Workspace and keeps the remote PTY running when removed locally."

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 360, height: 26),
            pullsDown: false
        )
        popup.addItems(withTitles: ["Temporary — collect, then close", "Keep Alive — reusable across Workspaces"])
        popup.selectItem(at: 0)
        popup.toolTip = surface.cwd.isEmpty
            ? "No remote project directory was reported"
            : "Current Project: \(surface.cwd)"
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let response = await Self.runModalAsSheet(alert)
        guard response == .alertFirstButtonReturn else { return nil }
        return popup.indexOfSelectedItem == 1 ? .keepAlive : .temporary
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

        Task { @MainActor in
            let resp = await Self.runModalAsSheet(alert)
            guard resp == .alertFirstButtonReturn else { return }
            let path = self.normalizedSocketPath(from: input.stringValue)
            guard !path.isEmpty else {
                self.showAlert(title: "Peer Socket Required", body: "Enter a peer socket path.")
                return
            }
            guard self.validateLocalSocketPathForConnect(path) else { return }
            await self.run(socketPath: path)
        }
    }

    private func run(socketPath: String) async {
        let flow = ConnectionFlow.console(socketPath)
        guard beginConnectionFlow(flow) else { return }
        defer { finishConnectionFlow(flow) }

        let transport: UnixSocketTransport
        do {
            transport = try await UnixSocketTransport.connect(socketPath: socketPath)
        } catch {
            showAlert(title: "Peer connection failed", body: String(describing: error))
            return
        }

        do {
            let session = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            await transport.setReadTimeoutSeconds(Self.setupReadTimeoutSeconds)
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
            await transport.setReadTimeoutSeconds(nil)

            let controller = PeerConsoleWindowController(
                hostSockPath: socketPath,
                hostName: info.hostDisplayName,
                surfaceTitle: chosen.title,
                surfaceID: outcome.surfaceID,
                session: session,
                transport: transport
            )
            openConsoles.append(controller)
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.openConsoles.removeAll { $0 === controller }
                self.postRelaysChanged()
            }
            controller.show()
            self.postRelaysChanged()
        } catch {
            await transport.close()
            showAlert(title: "Peer connection failed", body: String(describing: error))
        }
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        Self.presentAsSheetIfPossible(alert) { _ in }
    }

    private func normalizedSocketPath(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private func validateLocalSocketPathForConnect(_ path: String) -> Bool {
        if let message = localSocketPathValidationMessage(path) {
            showAlert(title: "Peer Socket Unavailable", body: message)
            return false
        }
        return true
    }

    private func localSocketPathValidationMessage(_ path: String) -> String? {
        guard !path.isEmpty else {
            return "Enter a peer socket path."
        }
        if path.utf8.count >= 104 {
            return "Unix socket path is too long (\(path.utf8.count) bytes). Use a path under 104 bytes."
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "Socket path does not exist:\n\(path)"
        }
        if isDirectory.boolValue {
            return "Socket path points to a directory:\n\(path)"
        }
        var st = stat()
        guard stat(path, &st) == 0 else {
            return "Socket path is not accessible:\n\(path)"
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            return "Socket path is not a Unix socket:\n\(path)"
        }
        return nil
    }

    static func menuSafeTitle(_ value: String, maxLength: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard singleLine.count > maxLength else { return singleLine }
        guard maxLength > 3 else { return String(singleLine.prefix(maxLength)) }
        return "..." + String(singleLine.suffix(maxLength - 3))
    }

    private static func abbreviatedMenuPath(_ path: String, maxLength: Int = 72) -> String {
        let singleLine = path
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard singleLine.count > maxLength else { return singleLine }

        let last = (singleLine as NSString).lastPathComponent
        guard !last.isEmpty else {
            return menuSafeTitle(singleLine, maxLength: maxLength)
        }

        let candidate = ".../\(last)"
        if candidate.count <= maxLength {
            return candidate
        }
        return menuSafeTitle(last, maxLength: maxLength)
    }

    /// Present `alert` as a window-attached sheet when possible so the
    /// main run loop isn't blocked on `mach_msg2_trap` for the
    /// duration the dialog is up — this is what `App Hanging` tickets
    /// trace back to. Falls back to the original modal flow only when
    /// no host window is reachable (status-bar-only invocation with
    /// no visible app window).
    @MainActor
    static func presentAsSheetIfPossible(
        _ alert: NSAlert,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let host: NSWindow? = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        guard let host else {
            alert.presentAsSheet(completion: completion)
            return
        }
        alert.beginSheetModal(for: host) { response in
            // beginSheetModal's completion runs on the main thread but
            // isn't @MainActor-annotated by the SDK; hop explicitly.
            Task { @MainActor in completion(response) }
        }
    }

    /// Async wrapper for `presentAsSheetIfPossible` — lets dialog
    /// flows keep their straight-line shape (`let resp = await
    /// runModalAsSheet(alert)`) instead of pyramiding completion
    /// blocks.
    @MainActor
    static func runModalAsSheet(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { cont in
            presentAsSheetIfPossible(alert) { resp in
                cont.resume(returning: resp)
            }
        }
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
final class PeerConsoleWindowController: NSWindowController, NSWindowDelegate {
    private let hostSockPath: String
    private let hostName: String
    private let surfaceTitle: String
    private let surfaceID: Data
    private let session: PeerSession
    private let transport: UnixSocketTransport
    private let outputView: NSTextView
    private let inputField: NSTextField
    private let connectedAt = Date()
    private var readerTask: Task<Void, Never>?
    private var isClosing = false

    var onClose: (@MainActor () -> Void)?

    var connectionInfo: PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(self),
            kind: .console,
            hostSockPath: hostSockPath,
            hostDisplayName: hostName,
            sshTarget: nil,
            remoteSockPath: nil,
            targetTitle: surfaceTitle.isEmpty ? "<surface>" : surfaceTitle,
            connectedAt: connectedAt
        )
    }

    init(
        hostSockPath: String,
        hostName: String,
        surfaceTitle: String,
        surfaceID: Data,
        session: PeerSession,
        transport: UnixSocketTransport
    ) {
        self.hostSockPath = hostSockPath
        self.hostName = hostName
        self.surfaceTitle = surfaceTitle
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
        window.installPeerTitlebarGradientAccent()
        window.center()

        super.init(window: window)
        window.delegate = self

        inputField.target = self
        inputField.action = #selector(sendInputLine(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show() {
        window?.installPeerTitlebarGradientAccent()
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
                    self.handleStreamError(error)
                    return
                }
                self.handle(msg)
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
