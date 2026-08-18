//  Phase C-3c.3.3b: DEBUG-only hook that starts a Swift PeerServer inside
//  term-mesh.app. The provider enumerates the app's live Ghostty terminal
//  panes (GhosttyPaneSurfaceProvider) so remote clients can list and attach
//  to real PTYs via `tm-agent peer list / peer attach`.

import AppKit
import Bonsplit
import PeerProto

/// Builds the wire `HostStats` from the daemon's `monitor.snapshot` JSON.
///
/// A translation, not a measurement: the daemon already samples every figure
/// here for the resource monitor, and `term-meshd`'s own peer path builds the
/// same message from the same struct (`host_stats_from` in
/// `peer/connection.rs`). Keeping this a pure function over the decoded JSON
/// is what makes the field mapping testable without a daemon.
///
/// Field names are the Rust struct's, verbatim — `SystemSnapshot` derives
/// `Serialize` with no `rename_all`, so a rename there would surface here as
/// a figure quietly reading zero. That is why every lookup below is explicit
/// rather than driven by a decoder that would tolerate absence.
enum LocalHostStatsSample {
    static func make(from snapshot: [String: Any]) -> Termmesh_Peer_V1_HostStats? {
        var stats = Termmesh_Peer_V1_HostStats()

        // `load_avg` is [1m, 5m, 15m]. The first says how busy the machine is;
        // the other two say whether that is a spike or a trend, which is why
        // all three travel together rather than just the first.
        if let load = snapshot["load_avg"] as? [Any], load.count >= 3 {
            stats.load1M = double(load[0])
            stats.load5M = double(load[1])
            stats.load15M = double(load[2])
        }
        stats.cpuCount = uint32(snapshot["cpu_count"])
        stats.memoryPercent = Float(double(snapshot["memory_percent"]))
        stats.memoryUsedBytes = uint64(snapshot["used_memory_bytes"])
        stats.memoryTotalBytes = uint64(snapshot["total_memory_bytes"])
        stats.diskReadBytesPerSec = uint64(snapshot["disk_read_bytes_per_sec"])
        stats.diskWriteBytesPerSec = uint64(snapshot["disk_write_bytes_per_sec"])
        // Absolute capacity, so a viewer can warn before this machine runs out
        // of room. Zero total means "not measured" to the client, never "full".
        stats.diskTotalBytes = uint64(snapshot["disk_total_bytes"])
        stats.diskAvailableBytes = uint64(snapshot["disk_available_bytes"])

        // Summed across interfaces, matching the daemon: the question a viewer
        // asks is how much traffic this machine is moving, not which NIC moved
        // it. Rates are already per-second; the clamp only guards a negative
        // that a counter reset could produce.
        var rx = 0.0
        var tx = 0.0
        for case let interface as [String: Any] in snapshot["network_io"] as? [Any] ?? [] {
            rx += double(interface["rx_rate"])
            tx += double(interface["tx_rate"])
        }
        stats.netRxBytesPerSec = UInt64(max(0, rx))
        stats.netTxBytesPerSec = UInt64(max(0, tx))

        return stats
    }

    /// JSON numbers arrive as `NSNumber` whatever their Rust type was, so one
    /// coercion per width rather than a cast that silently fails on the other.
    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func uint64(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else { return 0 }
        return UInt64(max(0, number.doubleValue))
    }

    private static func uint32(_ value: Any?) -> UInt32 {
        guard let number = value as? NSNumber else { return 0 }
        return UInt32(max(0, min(Double(UInt32.max), number.doubleValue)))
    }
}

@MainActor
enum PeerServerMenu {
    static func startItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: LanguageSettings.localized("Start Peer Server…"),
            action: #selector(PeerHostCoordinator.startServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerHostCoordinator.shared
        return item
    }

    static func stopItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: LanguageSettings.localized("Stop Peer Server"),
            action: #selector(PeerHostCoordinator.stopServer(_:)),
            keyEquivalent: ""
        )
        item.target = PeerHostCoordinator.shared
        return item
    }
}

@MainActor
final class PeerHostCoordinator: NSObject {
    static let shared = PeerHostCoordinator()

    private enum Lifecycle {
        case stopped
        case starting(String)
        case running(String)
        case stopping(String?)
    }

    private var server: PeerServer?
    private var socketPath: String?
    private var provider: GhosttyPaneSurfaceProvider?
    private var layoutObserver: NSObjectProtocol?
    private var workspaceClosedObserver: NSObjectProtocol?
    private var bonjour: PeerBonjourPublisher?
    private var lifecycle: Lifecycle = .stopped
    private var startDialogOpen = false
    private var infoAlertOpen = false
    /// Per-workspace debounce of `WorkspaceLayoutChanged` broadcasts.
    /// `bonsplit.didChangeGeometry` fires on every intermediate
    /// position during a divider drag (~60Hz); coalescing here keeps
    /// the network/CPU cost proportional to "drag ended" rather than
    /// "frame settled."
    private var layoutBroadcastDebounce: [UUID: Task<Void, Never>] = [:]

    /// Launch-time hook. Start the peer server when either the
    /// `TERMMESH_PEER_SERVER_PATH` (or legacy
    /// `TERMMESH_DEBUG_PEER_SERVER_PATH`) env var is set or the
    /// "Auto-start" preference is on. Env wins on path conflict.
    static func autoStartIfConfigured() {
        let env = ProcessInfo.processInfo.environment
        let envPath = env["TERMMESH_PEER_SERVER_PATH"]
            ?? env["TERMMESH_DEBUG_PEER_SERVER_PATH"]
        let path: String?
        if let envPath, !envPath.isEmpty {
            path = envPath
        } else if PeerFederationSettings.autoStart {
            path = PeerFederationSettings.socketPath
        } else {
            path = nil
        }
        guard let path else { return }
        Task { await PeerHostCoordinator.shared.bringUp(at: path, silent: true) }
    }

    /// Toggle the server on/off without showing any UI. Used by the
    /// Settings pane and by `autoStartIfConfigured`.
    @discardableResult
    func setRunning(_ shouldRun: Bool) async -> Bool {
        if shouldRun {
            guard case .stopped = lifecycle else { return server != nil }
            await bringUp(at: PeerFederationSettings.socketPath, silent: false)
            postStateChange()
            return server != nil
        } else {
            return await tearDown(showStoppedAlert: false)
        }
    }

    private func postStateChange() {
        NotificationCenter.default.post(name: .peerServerStateDidChange, object: nil)
    }

    /// `true` while the server is listening. Lets Settings reflect
    /// state without polling.
    var isRunning: Bool { server != nil }
    var currentSocketPath: String? { socketPath }

    func callTeamLeader(
        _ request: Termmesh_Peer_V1_TeamLeaderCommandRequest,
        targetPeerID: Data,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> Termmesh_Peer_V1_TeamLeaderCommandResponse {
        guard let server else { throw PeerServerError.notRunning }
        return try await server.callTeamLeader(
            request,
            targetPeerID: targetPeerID,
            timeoutSeconds: timeoutSeconds
        )
    }

    @objc func startServer(_ sender: Any?) {
        switch lifecycle {
        case .running(let existing):
            showInfo(
                title: LanguageSettings.localized("Peer server is already running."),
                body: String(
                    format: LanguageSettings.localized("Listening at %@. Stop it first if you want a new path."),
                    existing
                )
            )
            return
        case .starting(let path):
            showInfo(
                title: LanguageSettings.localized("Peer server is starting"),
                body: String(
                    format: LanguageSettings.localized("Already starting at %@."),
                    path
                )
            )
            return
        case .stopping:
            showInfo(
                title: LanguageSettings.localized("Peer server is stopping"),
                body: LanguageSettings.localized("Wait for the current stop operation to finish before starting it again.")
            )
            return
        case .stopped:
            break
        }
        guard !startDialogOpen else { return }

        let alert = NSAlert()
        alert.messageText = LanguageSettings.localized("Start peer server")
        alert.informativeText = LanguageSettings.localized("term-mesh.app will listen on this Unix socket. Existing file at the path will be overwritten.")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = PeerFederationSettings.socketPath
        alert.accessoryView = input
        alert.addButton(withTitle: LanguageSettings.localized("Start"))
        alert.addButton(withTitle: LanguageSettings.localized("Cancel"))
        startDialogOpen = true
        presentAlert(alert) { [weak self] response in
            self?.startDialogOpen = false
            guard response == .alertFirstButtonReturn else { return }
            let path = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return }
            Task { await self?.bringUp(at: path, persistPath: true) }
        }
    }

    /// Forward to the provider so TabManager / Workspace can release stale tapHubs
    /// without a direct dependency on GhosttyPaneSurfaceProvider.
    func invalidateTapHub(forSurfaceId surfaceId: UUID) {
        provider?.invalidateTapHub(forSurfaceId: surfaceId)
    }

    @objc func stopServer(_ sender: Any?) {
        switch lifecycle {
        case .starting(let path):
            showInfo(
                title: LanguageSettings.localized("Peer server is starting"),
                body: String(
                    format: LanguageSettings.localized("Already starting at %@. Wait for startup to finish before stopping it."),
                    path
                )
            )
            return
        case .stopping:
            return
        case .stopped:
            showInfo(
                title: LanguageSettings.localized("No server running"),
                body: LanguageSettings.localized("Start one first via Start Peer Server…")
            )
            return
        case .running:
            break
        }
        Task { await self.tearDown(showStoppedAlert: true) }
    }

    @discardableResult
    private func tearDown(showStoppedAlert: Bool) async -> Bool {
        guard let server = self.server else {
            if case .starting = lifecycle {
                return false
            }
            lifecycle = .stopped
            return true
        }
        lifecycle = .stopping(socketPath)
        // Stop looking for this machine's own sessions: it is no longer a host,
        // and a poller that outlived the server would keep opening panes for
        // one.
        SessionHostPanes.stopPolling()
        self.server = nil
        self.provider = nil
        let oldPath = socketPath
        socketPath = nil
        uninstallPeerBridges()
        bonjour?.stop()
        bonjour = nil
        await server.stop()
        lifecycle = .stopped
        postStateChange()
        if showStoppedAlert {
            showInfo(
                title: LanguageSettings.localized("Peer server stopped"),
                body: oldPath.map {
                    String(format: LanguageSettings.localized("Socket %@ is gone."), $0)
                } ?? LanguageSettings.localized("Socket removed.")
            )
        }
        return true
    }

    private func canStartServer(at path: String, silent: Bool) -> Bool {
        switch lifecycle {
        case .stopped:
            lifecycle = .starting(path)
            postStateChange()
            return true
        case .running(let existing):
            if !silent {
                showInfo(
                    title: "Peer server is already running.",
                    body: "Listening at \(existing). Stop it first if you want a new path."
                )
            }
            return false
        case .starting, .stopping:
            return false
        }
    }

    private func markStartFailed() {
        server = nil
        provider = nil
        socketPath = nil
        uninstallPeerBridges()
        bonjour?.stop()
        bonjour = nil
        lifecycle = .stopped
        postStateChange()
    }

    private func markStartSucceeded(server: PeerServer,
                                    path: String,
                                    provider: GhosttyPaneSurfaceProvider,
                                    persistPath: Bool) {
        self.server = server
        self.socketPath = path
        self.provider = provider
        if persistPath {
            UserDefaults.standard.set(path, forKey: PeerFederationSettings.socketPathKey)
        }
        lifecycle = .running(path)
        installLayoutChangeBridge(server: server, provider: provider)
        installWorkspaceClosedBridge(server: server)
        // LAN discovery: advertise via Bonjour so other macs on
        // the same network can pick this host out of a list
        // instead of typing an SSH alias by hand. The TXT record
        // carries the socket path; the actual data path remains
        // SSH (clients connect with `ssh -L`).
        let publisher = PeerBonjourPublisher(
            serviceName: PeerFederationSettings.displayName,
            socketPath: path
        )
        publisher.start()
        self.bonjour = publisher
        postStateChange()
    }

    /// What this app-hosted server answers in the Hello handshake. The
    /// daemon reports its real Cargo version, and pickers label a host with
    /// whichever process serves the connection — so the placeholder that
    /// used to sit here showed every app-served host as "debug-server",
    /// on every build, updated or not.
    nonisolated static func advertisedAppVersion(bundle: Bundle = .main) -> String {
        (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }

    private func bringUp(at path: String, silent: Bool = false, persistPath: Bool = false) async {
        guard canStartServer(at: path, silent: silent) else { return }
        let provider = GhosttyPaneSurfaceProvider()

        var config = PeerServerConfig()
        config.hostDisplayName = PeerFederationSettings.displayName
        config.hostAppVersion = Self.advertisedAppVersion()
        if let resourceURL = Bundle.main.resourceURL {
            config.hostCLIBinDirs = [
                resourceURL.appendingPathComponent("bin").standardizedFileURL.path
            ]
        }
        // This app's surfaces die with it, so a client that wants a session to
        // outlive a quit is pointed at the daemon instead. Named only while
        // something is actually listening there — otherwise the session dies
        // here too, and saying otherwise is a promise this machine cannot keep.
        //
        // Resolved per Hello rather than decided here: this server usually
        // finishes starting before the daemon has bound its socket, so any
        // answer available at this line is a guess.
        config.resolveSessionHostSocket = { TermMeshDaemon.shared.advertisedSessionHostSocket }
        // How loaded this Mac is, for a viewer's titlebar and its low-disk
        // badge. The daemon beside this app already samples all of it for the
        // resource monitor, so this reads that rather than starting a second
        // sampler — which also keeps the syscalls off this process's main
        // thread, where a two-second tick would land in the middle of SwiftUI's
        // update cycle.
        //
        // Returning nil (no daemon, or no sample yet) skips that tick. The
        // provider itself is still configured, so the host advertises
        // `host.stats.v1`: capabilities describe implemented support, while a
        // temporarily absent sample is normal during daemon startup.
        config.hostStatsProvider = {
            guard let snapshot = await TermMeshDaemon.shared.monitorSnapshot() else { return nil }
            return LocalHostStatsSample.make(from: snapshot)
        }

        let server = PeerServer(socketPath: path, provider: provider, config: config)
        do {
            try await server.start()
            markStartSucceeded(server: server, path: path, provider: provider, persistPath: persistPath)
            // Sessions the daemon is already holding predate this app: it may
            // have been restarted while they kept running, which is the whole
            // reason they live there. Nothing else would show them — and
            // nothing would show the ones created after this line either,
            // which is most of them, so this keeps looking rather than asking
            // once.
            SessionHostPanes.startPolling()
            NSLog("[peer-debug] server listening on %@", path)
            if !silent {
                showInfo(
                    title: LanguageSettings.localized("Peer server listening"),
                    body: String(
                        format: LanguageSettings.localized("""
                            Socket: %@

                            Try from a terminal:
                              tm-agent peer list %@
                              tm-agent peer attach %@ --name echo
                            """),
                        path, path, path
                    )
                )
            }
        } catch {
            markStartFailed()
            NSLog("[peer-debug] server failed to start at %@: %@", path, String(describing: error))
            // `socketInUse` is reported even when `silent` — and autostart is
            // always silent, which is where this one actually happens.
            //
            // Every other start failure is a syscall going wrong on a path
            // nobody else wants, so a quiet log is proportionate. This one says
            // another live server holds the path, which used to be the case
            // where THIS app silently unlinked it and took over. Refusing
            // instead is correct, but refusing quietly during autostart just
            // moves the silence: peer serving is simply off, with nothing
            // anywhere saying why, and the symptom (a viewer that cannot
            // attach) looks identical to the bug that was fixed.
            if case PeerServerError.socketInUse(let takenPath) = error {
                showInfo(
                    title: LanguageSettings.localized("Peer server is already running"),
                    body: String(
                        format: LanguageSettings.localized("""
                            Another term-mesh build is already serving this socket, so this one did not start:
                            %@

                            Whichever app got there first keeps serving. Quit it to serve from this build, or give this build its own socket path in Settings → Peer Federation.
                            """),
                        takenPath
                    )
                )
            } else if !silent {
                showInfo(
                    title: LanguageSettings.localized("Failed to start peer server"),
                    body: String(describing: error)
                )
            }
        }
    }

    /// Bridge from `Workspace+BonsplitDelegate.didChangeGeometry`'s
    /// NotificationCenter post to the peer server's broadcast API.
    /// Each notification carries a `workspaceID`; we fetch the latest
    /// `WorkspaceLayout` from the provider and push it to all
    /// connected sessions.
    private func installLayoutChangeBridge(server: PeerServer,
                                           provider: GhosttyPaneSurfaceProvider) {
        layoutObserver = NotificationCenter.default.addObserver(
            forName: .peerWorkspaceLayoutDidChange,
            object: nil,
            queue: .main
        ) { [weak self, weak server, weak provider] note in
            guard let self, let server, let provider,
                  let workspaceID = note.userInfo?["workspaceID"] as? UUID
            else { return }
            // Coalesce a flurry of layout-change notifications (e.g. a
            // divider drag posts one per pixel of motion) into a single
            // broadcast so attached relays don't thrash.
            self.scheduleLayoutBroadcast(
                workspaceID: workspaceID,
                server: server,
                provider: provider
            )
        }
    }

    /// Debounce window for divider-drag-style flurries. 120 ms balances
    /// "feels live" against "don't broadcast every intermediate frame."
    private static let layoutBroadcastDebounceInterval: UInt64 = 120_000_000

    private func scheduleLayoutBroadcast(workspaceID: UUID,
                                         server: PeerServer,
                                         provider: GhosttyPaneSurfaceProvider) {
        layoutBroadcastDebounce[workspaceID]?.cancel()
        let idBytes = withUnsafeBytes(of: workspaceID.uuid) { Data($0) }
        let debounceNs = Self.layoutBroadcastDebounceInterval
        let task = Task { [weak self, weak server, weak provider] in
            try? await Task.sleep(nanoseconds: debounceNs)
            if Task.isCancelled { return }
            guard let server, let provider else { return }
            let workspaces = await provider.listWorkspaces()
            guard let updated = workspaces.first(where: { $0.workspaceID == idBytes })
            else { return }
            await server.broadcastWorkspaceLayoutChanged(
                workspaceID: idBytes,
                layout: updated.layout
            )
            // Sidebar subscribers use complete snapshots, not layout deltas:
            // a newly created workspace or a locally renamed tab has no
            // pre-existing mirror session to carry the change.
            await server.broadcastWorkspaceListChanged(workspaces)
            await MainActor.run { [weak self] in
                self?.layoutBroadcastDebounce.removeValue(forKey: workspaceID)
            }
        }
        layoutBroadcastDebounce[workspaceID] = task
    }

    /// Bridge from `TabManager.closeWorkspace`'s `.peerWorkspaceDidClose`
    /// post to the peer server's `WorkspaceRemoved` broadcast. Covers
    /// both a peer-initiated `DeleteWorkspaceRequest`
    /// (`GhosttyPaneSurfaceProvider.deleteWorkspace` calls
    /// `closeWorkspace` directly) and a host-local close (Cmd+W,
    /// sidebar, tab-bar) — `closeWorkspace` is the single choke point
    /// for both, so one observer covers the whole contract described
    /// on `WorkspaceRemoved` in peer.proto ("via DeleteWorkspaceRequest
    /// or a host-local UI action").
    private func installWorkspaceClosedBridge(server: PeerServer) {
        workspaceClosedObserver = NotificationCenter.default.addObserver(
            forName: .peerWorkspaceDidClose,
            object: nil,
            queue: .main
        ) { [weak self, weak server] note in
            guard let server,
                  let workspaceID = note.userInfo?["workspaceID"] as? UUID
            else { return }
            // Defense-in-depth, not a correctness fix: any layout-change
            // broadcast still pending for this exact workspace_id can
            // never actually resurrect it on the wire even if left to
            // fire — scheduleLayoutBroadcast's debounced task re-queries
            // provider.listWorkspaces() live at fire-time (never a cached
            // snapshot), and by the time that 120 ms debounce elapses,
            // TabManager.closeWorkspace's synchronous tabs.remove(at:)
            // has long since made the workspace genuinely absent, so the
            // task's own `guard let updated = ... else { return }` no-ops.
            // Cancelling here just avoids a redundant listWorkspaces()
            // call and closes the narrow theoretical window where an
            // in-flight broadcast Task races this one on the wire.
            self?.layoutBroadcastDebounce.removeValue(forKey: workspaceID)?.cancel()
            let provider = self?.provider
            let idBytes = withUnsafeBytes(of: workspaceID.uuid) { Data($0) }
            #if DEBUG
            dlog("peer.host.broadcastWorkspaceRemoved id=\(workspaceID.uuidString.prefix(8))")
            #endif
            Task {
                await server.broadcastWorkspaceRemoved(workspaceID: idBytes)
                // Re-read after TabManager's synchronous removal so every
                // subscriber converges even if it missed the tombstone while
                // its tunnel was being recreated.
                await server.broadcastWorkspaceListChanged(await provider?.listWorkspaces() ?? [])
            }
        }
    }

    private func uninstallPeerBridges() {
        if let observer = layoutObserver {
            NotificationCenter.default.removeObserver(observer)
            layoutObserver = nil
        }
        if let observer = workspaceClosedObserver {
            NotificationCenter.default.removeObserver(observer)
            workspaceClosedObserver = nil
        }
        for (_, task) in layoutBroadcastDebounce { task.cancel() }
        layoutBroadcastDebounce.removeAll()
    }

    private func presentAlert(_ alert: NSAlert,
                              completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        guard targetWindow?.attachedSheet == nil else {
            completion?(.abort)
            return
        }
        alert.presentAsSheet(for: targetWindow, completion: completion)
    }

    private func showInfo(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: LanguageSettings.localized("OK"))
        guard !infoAlertOpen else { return }
        infoAlertOpen = true
        presentAlert(alert) { [weak self] _ in
            self?.infoAlertOpen = false
        }
    }
}

extension Notification.Name {
    /// Posted by `Workspace` when bonsplit reports a layout change
    /// (split add/remove, divider drag). userInfo carries
    /// `["workspaceID": UUID]`. Observed by
    /// `PeerHostCoordinator` which pushes the refreshed layout
    /// to attached peer clients.
    static let peerWorkspaceLayoutDidChange = Notification.Name("PeerWorkspaceLayoutDidChange")

    /// Posted by `TabManager.closeWorkspace` whenever a workspace
    /// itself (not a pane inside one) is torn down — via a peer
    /// `DeleteWorkspaceRequest` (`GhosttyPaneSurfaceProvider
    /// .deleteWorkspace`) or a host-local UI close (Cmd+W, sidebar,
    /// tab-bar close). userInfo carries `["workspaceID": UUID]` — the
    /// id of the workspace that was actually removed (for the
    /// "closed the window's last tab" case, this is the ORIGINAL
    /// workspace's id, not its blank replacement). Observed by
    /// `PeerHostCoordinator`, which broadcasts `WorkspaceRemoved` to
    /// every attached peer session so viewers drop it from their
    /// roster without polling `ListWorkspaces`.
    static let peerWorkspaceDidClose = Notification.Name("PeerWorkspaceDidClose")

    /// Posted by `PeerHostCoordinator` whenever the local peer
    /// server starts or stops. Observed by the status-bar icon to
    /// toggle the activity dot.
    static let peerServerStateDidChange = Notification.Name("PeerServerStateDidChange")
}
