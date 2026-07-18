import Foundation
import AppKit
import Bonsplit
import Combine
import PeerProto

struct WorkspaceSummary: Identifiable, Equatable {
    let id: Data
    let title: String
    let hostSockPath: String
    /// Id of the host window that owns this workspace. Empty when talking to
    /// a host that predates multi-window enumeration (legacy single-window).
    let windowID: Data
    /// Human-readable window label (window title bar text) for grouping.
    let windowTitle: String
    /// The daemon's protected default workspace — delete is refused on
    /// the host (IsDefault), so the sidebar disables the affordance.
    let isDefault: Bool
    /// Leaf panes in this workspace's layout tree.
    let paneCount: Int
    /// Surfaces (Σ tabs across leaf panes; a leaf always has ≥1).
    let surfaceCount: Int
    /// Leaf panes whose active surface is busy (a foreground command is
    /// running). 0 on hosts that predate the `busy` field.
    let busyCount: Int
}

/// Fold a peer workspace layout tree into (panes, surfaces, busy panes).
/// The tree comes free with every `ListWorkspaces` roster fetch, so these
/// counts cost nothing beyond a walk — no extra RPC, no host change.
func peerLayoutCounts(
    _ layout: Termmesh_Peer_V1_WorkspaceLayout?
) -> (panes: Int, surfaces: Int, busy: Int) {
    func walk(_ node: Termmesh_Peer_V1_WorkspaceLayout) -> (Int, Int, Int) {
        switch node.node {
        case .pane(let p):
            // tabs includes the active surface, so its count is the pane's
            // surface count; a well-formed leaf never has zero.
            return (1, max(p.tabs.count, 1), p.busy ? 1 : 0)
        case .split(let s):
            let a = walk(s.first)
            let b = walk(s.second)
            return (a.0 + b.0, a.1 + b.1, a.2 + b.2)
        case .none:
            return (0, 0, 0)
        }
    }
    guard let layout else { return (0, 0, 0) }
    let r = walk(layout)
    return (r.0, r.1, r.2)
}

/// Human label for a host window in the peer workspace UI. Uses the window's
/// title when the host supplied one, else a short hex of the window id.
/// Empty id (legacy host) collapses to a bare "Window".
func peerWindowLabel(title: String, id: Data) -> String {
    if !title.isEmpty { return title }
    let hex = id.prefix(3).map { String(format: "%02x", $0) }.joined()
    return hex.isEmpty ? "Window" : "Window \(hex)"
}

/// Group an ordered workspace roster by owning window, preserving the input
/// order of both windows and workspaces. Returns one entry per distinct
/// windowID. Used by the picker/sidebars to render window sections only when
/// the host actually reports more than one window.
func groupWorkspacesByWindow<T>(
    _ items: [T],
    windowID: (T) -> Data,
    windowTitle: (T) -> String
) -> [(windowID: Data, windowTitle: String, items: [T])] {
    var indexByID: [Data: Int] = [:]
    var groups: [(windowID: Data, windowTitle: String, items: [T])] = []
    for item in items {
        let wid = windowID(item)
        if let idx = indexByID[wid] {
            groups[idx].items.append(item)
        } else {
            indexByID[wid] = groups.count
            groups.append((wid, windowTitle(item), [item]))
        }
    }
    return groups
}

/// Sidebar-visible lifecycle of a host entry. `saved` covers both a
/// never-connected profile and a disconnected one; `failed` carries the
/// short reason shown inline (row icon + tooltip — never an NSAlert,
/// which would activate the app and violate the socket focus policy).
enum HostConnectionState: Equatable {
    case saved
    case connecting
    case connected
    case failed(String)
}

struct HostEntry: Identifiable {
    let id: String         // stable dedup key (stableKey)
    var displayName: String
    var connectionState: HostConnectionState
    var workspaces: [WorkspaceSummary]
    /// The most-recently-used ephemeral sock path. Updated on each reconnect so
    /// that fetchWorkspaces always connects over the current live tunnel.
    var activeSockPath: String
    /// SSH reach info when this host was opened over an `ssh -L` tunnel.
    /// Present → sidebar pane/mirror opens derive an `.ssh` spec that leases
    /// its own tunnel (surviving the origin relay closing + reconnects);
    /// nil → direct-socket host that rides the shared live socket.
    var sshTarget: String?
    var remoteSockPath: String?
    /// Optional auth parameters from the backing profile.
    var sshPort: Int?
    var identityFile: String?
    /// Backing saved profile, when this entry derives from one.
    var profileID: UUID?
    var colorHex: String?
    var symbolName: String?
    /// Cached from the one-shot session's handshake capabilities each time
    /// `fetchWorkspaces` reconnects. nil = not yet known (or host never
    /// connected); false = host build predates workspace CRUD. Sidebar
    /// CRUD menu items gate on `== true` rather than treating nil as
    /// permissive, so a stale/unknown host defaults to disabled.
    var supportsWorkspaceLifecycle: Bool?

    var isConnected: Bool { connectionState == .connected }

    /// Host spec for opening a pane/mirror from this entry. Prefers an owned
    /// `.ssh` tunnel when both SSH fields are known; otherwise falls back to
    /// `.direct` on the live local socket (legacy Phase-1 behavior).
    var paneHostSpec: PeerPaneHostSpec {
        if let sshTarget, !sshTarget.isEmpty,
           let remoteSockPath, !remoteSockPath.isEmpty {
            return .ssh(
                target: sshTarget,
                remoteSockPath: remoteSockPath,
                port: sshPort,
                identityFile: identityFile
            )
        }
        return .direct(sockPath: activeSockPath)
    }
}

@MainActor
final class RemoteHostStore: ObservableObject {
    static let shared = RemoteHostStore()

    /// Fired after a successful sidebar connect so the mounted host
    /// group force-expands (its fold state is view-local @State).
    struct ExpandSignal: Equatable {
        var key: String = ""
        var generation: Int = 0
    }

    @Published private(set) var hosts: [String: HostEntry] = [:]
    @Published private(set) var expandSignal = ExpandSignal()

    /// Connected (or connecting) first, then saved/failed; name-sorted
    /// within each band so entries don't shuffle on reconnect.
    var sortedHosts: [HostEntry] {
        func rank(_ e: HostEntry) -> Int {
            switch e.connectionState {
            case .connected, .connecting: return 0
            case .saved, .failed: return 1
            }
        }
        return hosts.values.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var observer: NSObjectProtocol?
    private var fetchTasks: [String: Task<Void, Never>] = [:]
    /// Sidebar-held lease per host key: one ref that keeps the tunnel
    /// alive while the user browses workspaces. Panes/mirrors opened
    /// from here hold their own refs, so a sidebar disconnect never
    /// kills them (registry refcount semantics).
    private var sidebarLeases: [String: PeerPaneHostLease] = [:]
    private var connectTasks: [String: Task<Void, Never>] = [:]
    private var profileCancellable: AnyCancellable?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: PeerClientCoordinator.relaysDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        // objectWillChange fires before the profile list mutates; the
        // main-queue hop reads the post-change state.
        profileCancellable = PeerHostProfileStore.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.rebuild() }
            }
        // Catch connections that opened before the sidebar first rendered.
        rebuild()
    }

    deinit {
        if let token = observer {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func rebuild() {
        syncFromProfiles()
        syncFromCoordinator()
    }

    /// Saved profiles are always visible: ensure an entry per profile
    /// and refresh profile-derived metadata on existing ones. Entries
    /// whose backing profile was deleted stay only while connected.
    private func syncFromProfiles() {
        let profiles = PeerHostProfileStore.shared.profiles
        var profileKeys = Set<String>()
        for p in profiles {
            let key = p.stableKey
            profileKeys.insert(key)
            if hosts[key] == nil {
                hosts[key] = HostEntry(
                    id: key,
                    displayName: p.effectiveDisplayName,
                    connectionState: .saved,
                    workspaces: [],
                    activeSockPath: "",
                    sshTarget: p.sshTarget,
                    remoteSockPath: p.remoteSocket.isEmpty ? nil : p.remoteSocket,
                    sshPort: p.sshPort,
                    identityFile: p.identityFile,
                    profileID: p.id,
                    colorHex: p.colorHex,
                    symbolName: p.symbolName
                )
            } else {
                hosts[key]?.profileID = p.id
                hosts[key]?.displayName = p.effectiveDisplayName
                hosts[key]?.colorHex = p.colorHex
                hosts[key]?.symbolName = p.symbolName
                hosts[key]?.sshPort = p.sshPort
                hosts[key]?.identityFile = p.identityFile
                // A non-empty profile socket is the user's explicit choice
                // and must WIN over whatever this row cached from an earlier
                // resolution — the old nil-only fill meant editing the
                // socket path in the profile editor never reached the
                // sidebar row, which kept tunneling to the stale path.
                // An empty profile socket means auto-detect: keep the
                // resolved path so reconnects skip a redundant probe.
                if !p.remoteSocket.isEmpty {
                    hosts[key]?.remoteSockPath = p.remoteSocket
                }
            }
        }
        for (key, entry) in hosts where entry.profileID != nil && !profileKeys.contains(key) {
            if entry.isConnected || sidebarLeases[key] != nil {
                hosts[key]?.profileID = nil
                hosts[key]?.colorHex = nil
                hosts[key]?.symbolName = nil
            } else {
                hosts[key] = nil
            }
        }
    }

    private func syncFromCoordinator() {
        let connections = PeerClientCoordinator.shared.activeConnections()

        // Derive a stable dedup key per connection.
        // SSH tunnels use a unique local socket path per session, so keying by
        // hostSockPath would insert a new HostEntry on every reconnect. Instead:
        //   SSH connection  → "ssh:<sshTarget>" (stable across reconnects)
        //   Direct socket   → hostSockPath (already stable)
        // LIMITATION: same sshTarget with different remote sockets collapse into
        // one entry; needs remoteSockPath in connectionInfo to distinguish them.
        func stableKey(for conn: PeerRelayConnectionInfo) -> String {
            if let ssh = conn.sshTarget, !ssh.isEmpty { return "ssh:\(ssh)" }
            // Borrowed-socket connections carry no SSH identity — e.g. a
            // relay window opened from the sidebar rides an existing
            // tunnel's local socket (openWorkspaceRelayForSidebar attaches
            // no tunnel, so connectionInfo.sshTarget is nil). Fold such a
            // connection into the entry that owns that socket instead of
            // materializing a doppelgänger keyed by the ephemeral path.
            if let owner = hosts.values.first(where: {
                !$0.activeSockPath.isEmpty && $0.activeSockPath == conn.hostSockPath
            }) {
                return owner.id
            }
            return conn.hostSockPath
        }

        var activeKeys = Set<String>()
        for conn in connections {
            let key = stableKey(for: conn)
            activeKeys.insert(key)
            if hosts[key] == nil {
                hosts[key] = HostEntry(
                    id: key,
                    displayName: conn.hostDisplay,
                    connectionState: .connected,
                    workspaces: [],
                    activeSockPath: conn.hostSockPath,
                    sshTarget: conn.sshTarget,
                    remoteSockPath: conn.remoteSockPath
                )
                // Pass the actual (possibly ephemeral) sock path for the relay
                // connection, but store results under the stable key.
                fetchWorkspaces(for: conn.hostSockPath, key: key)
            } else {
                hosts[key]?.connectionState = .connected
                // A profile-named entry keeps its user-chosen name; ad-hoc
                // entries keep tracking the connection's display string.
                if !conn.hostDisplay.isEmpty, hosts[key]?.profileID == nil {
                    hosts[key]?.displayName = conn.hostDisplay
                }
                // Backfill SSH reach info once a connection carrying it arrives
                // (e.g. a direct-first entry later joined by its SSH tunnel).
                if let ssh = conn.sshTarget, !ssh.isEmpty {
                    hosts[key]?.sshTarget = ssh
                }
                // Track the connection's resolved socket only when the
                // profile doesn't pin one explicitly — an explicit profile
                // socket must keep winning even while an older connection
                // (opened before the profile edit) is still alive on the
                // previous path, or the next connect silently reuses the
                // stale socket the user just edited away.
                let pinnedSocket = hosts[key].flatMap {
                    PeerHostProfileStore.shared.profile(id: $0.profileID)?.remoteSocket
                } ?? ""
                if pinnedSocket.isEmpty, let remote = conn.remoteSockPath, !remote.isEmpty {
                    hosts[key]?.remoteSockPath = remote
                }
                // P1 fix: SSH reconnects produce a new ephemeral hostSockPath.
                // If it changed, refresh activeSockPath and re-fetch workspaces so
                // WorkspaceSummary.hostSockPath never points to the dead tunnel.
                if hosts[key]?.activeSockPath != conn.hostSockPath {
                    hosts[key]?.activeSockPath = conn.hostSockPath
                    hosts[key]?.workspaces = []
                    fetchWorkspaces(for: conn.hostSockPath, key: key)
                }
            }
        }

        // Keys with a live sidebar lease stay connected — that lease is
        // not a pane/mirror, so it never appears in activeConnections().
        // Only a `.connected` state downgrades; an in-flight `.connecting`
        // or surfaced `.failed` is owned by connectSavedHost.
        for key in hosts.keys
        where !activeKeys.contains(key) && sidebarLeases[key] == nil {
            if hosts[key]?.connectionState == .connected {
                hosts[key]?.connectionState = .saved
            }
        }
    }

    // MARK: - Sidebar connect / disconnect (saved hosts)

    var hasAnySidebarLease: Bool { !sidebarLeases.isEmpty }

    func hasSidebarLease(for key: String) -> Bool {
        sidebarLeases[key] != nil
    }

    /// Click-to-connect for a saved host: resolve the remote socket
    /// (auto-detect when the profile left it empty), lease the host —
    /// the sidebar holds one ref so the tunnel stays up while the user
    /// browses — then fetch the workspace roster and force-expand the
    /// group. Failures surface inline on the row (icon + tooltip); no
    /// NSAlert here, which would activate the app and violate the
    /// socket focus policy.
    func connectSavedHost(_ host: HostEntry) {
        let key = host.id
        guard let target = host.sshTarget, !target.isEmpty else { return }
        guard sidebarLeases[key] == nil, connectTasks[key] == nil else { return }
        hosts[key]?.connectionState = .connecting
        #if DEBUG
        dlog("peer.sidebar.connect start key=\(key)")
        #endif
        connectTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { self.connectTasks[key] = nil }
            do {
                let profile = PeerHostProfileStore.shared.profile(id: host.profileID)
                var socket = host.remoteSockPath ?? ""
                if socket.isEmpty {
                    socket = try await PeerSocketProber.probe(
                        sshTarget: target,
                        port: profile?.sshPort,
                        identityFile: profile?.identityFile
                    )
                }
                let spec = PeerPaneHostSpec.ssh(
                    target: target,
                    remoteSockPath: socket,
                    port: profile?.sshPort,
                    identityFile: profile?.identityFile
                )
                let lease = try await PeerPaneHostRegistry.shared.acquire(spec)
                // The entry may have been deleted while connecting.
                guard self.hosts[key] != nil else {
                    PeerPaneHostRegistry.shared.release(lease)
                    return
                }
                self.sidebarLeases[key] = lease
                self.hosts[key]?.connectionState = .connected
                self.hosts[key]?.activeSockPath = lease.hostSockPath
                self.hosts[key]?.remoteSockPath = socket
                PeerHostProfileStore.shared.recordConnection(
                    sshTarget: target, resolvedSocket: socket
                )
                self.fetchWorkspaces(for: lease.hostSockPath, key: key)
                SidebarLayoutSettings.setHostCollapsed(key, false)
                self.expandSignal = ExpandSignal(
                    key: key, generation: self.expandSignal.generation + 1
                )
                #if DEBUG
                dlog("peer.sidebar.connect ok key=\(key) sock=\(lease.hostSockPath)")
                #endif
            } catch {
                self.hosts[key]?.connectionState = .failed(String(describing: error))
                #if DEBUG
                dlog("peer.sidebar.connect fail key=\(key) error=\(error)")
                #endif
            }
        }
    }

    /// Delete the backing profile. Releases the sidebar lease first so
    /// the tunnel ref is balanced; panes/mirrors keep their own refs
    /// and the entry survives as ad-hoc while they live (rebuild rule).
    /// Removes every saved profile for this host's sshTarget, not just
    /// the one id this row happens to be bound to — a leftover
    /// duplicate profile would otherwise resurrect the row on the next
    /// profile sync. Falls back to the id-based delete when the host
    /// has no sshTarget (shouldn't happen for a profile-backed entry,
    /// but keeps the old behavior as a safety net).
    func deleteProfile(for host: HostEntry) {
        guard let profileID = host.profileID else { return }
        if hasSidebarLease(for: host.id) {
            disconnectSavedHost(host)
        }
        if let target = host.sshTarget, !target.isEmpty {
            PeerHostProfileStore.shared.deleteAll(forSSHTarget: target)
        } else {
            PeerHostProfileStore.shared.delete(id: profileID)
        }
    }

    /// Promote an ad-hoc connected SSH entry to a saved profile draft
    /// (shown in the editor before persisting). nil for direct-socket
    /// entries — V1 profiles are SSH-only.
    func profileDraft(for host: HostEntry) -> PeerHostProfile? {
        guard host.profileID == nil,
              let target = host.sshTarget, !target.isEmpty else { return nil }
        return PeerHostProfile(
            displayName: host.displayName,
            sshTarget: target,
            remoteSocket: host.remoteSockPath ?? ""
        )
    }

    /// Release the sidebar's lease ref. Panes/mirrors opened from this
    /// host hold their own refs and survive; rebuild() re-promotes the
    /// entry if such a connection is still live.
    func disconnectSavedHost(_ host: HostEntry) {
        let key = host.id
        guard let lease = sidebarLeases[key] else { return }
        sidebarLeases[key] = nil
        PeerPaneHostRegistry.shared.release(lease)
        fetchTasks[key]?.cancel()
        hosts[key]?.workspaces = []
        hosts[key]?.activeSockPath = ""
        hosts[key]?.supportsWorkspaceLifecycle = nil
        if hosts[key]?.connectionState == .connected {
            hosts[key]?.connectionState = .saved
        }
        #if DEBUG
        dlog("peer.sidebar.disconnect key=\(key)")
        #endif
        rebuild()
    }

    private func fetchWorkspaces(for hostSockPath: String, key: String) {
        fetchTasks[key]?.cancel()
        let path = hostSockPath
        // Task inherits @MainActor; await suspensions yield main without blocking it.
        fetchTasks[key] = Task {
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: path)
                // Record capability regardless of what listWorkspaces below does —
                // it's already known from this connection's handshake, and the
                // sidebar CRUD menu gates on it independently of the roster fetch.
                if !Task.isCancelled, self.hosts[key]?.activeSockPath == path {
                    self.hosts[key]?.supportsWorkspaceLifecycle =
                        conn.hostCapabilities.has(PeerCapability.workspaceLifecycleV1)
                }
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    workspaces = try await conn.session.listWorkspaces()
                } catch {
                    await conn.cancel()
                    return
                }
                await conn.cancel()
                // Stale-path guard: a reconnect may have superseded this fetch with a
                // newer ephemeral path. Drop the result if this task was cancelled or the
                // host's active path no longer matches the path we fetched against.
                if Task.isCancelled || self.hosts[key]?.activeSockPath != path {
                    return
                }
                let summaries = workspaces.map { ws -> WorkspaceSummary in
                    let counts = peerLayoutCounts(ws.hasLayout ? ws.layout : nil)
                    return WorkspaceSummary(
                        id: ws.workspaceID,
                        title: ws.title.isEmpty ? "<workspace>" : ws.title,
                        hostSockPath: path,
                        windowID: ws.windowID,
                        windowTitle: ws.windowTitle,
                        isDefault: ws.isDefault,
                        paneCount: counts.panes,
                        surfaceCount: counts.surfaces,
                        busyCount: counts.busy
                    )
                }
                self.hosts[key]?.workspaces = summaries
            } catch {
                // Host disconnected between detection and fetch — ignore.
            }
        }
    }

    /// `host` is the sidebar group the row was rendered under — used for
    /// the relay window's display name. (The old `hosts[path]` lookup was
    /// always nil for SSH hosts: `hosts` is keyed by stableKey, not by
    /// sock path.)
    func openWorkspace(_ workspace: WorkspaceSummary, host: HostEntry) {
        let path = workspace.hostSockPath
        let displayName = host.displayName
        Task {
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: path)
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    workspaces = try await conn.session.listWorkspaces()
                } catch {
                    await conn.cancel()
                    return
                }
                await conn.cancel()
                guard let chosen = workspaces.first(where: { $0.workspaceID == workspace.id })
                    ?? workspaces.first
                else { return }
                PeerClientCoordinator.shared.openWorkspaceRelayForSidebar(
                    hostSockPath: path,
                    workspace: chosen,
                    hostDisplayName: displayName
                )
            } catch {
                NSLog("[remote-host-store] openWorkspace failed: %@", String(describing: error))
            }
        }
    }

    /// Phase 1 remote pane primitive: surface picker + attach into the
    /// current workspace. SSH hosts lease their own tunnel (`.ssh` spec) so
    /// the pane survives the origin relay closing and reconnects; direct
    /// hosts ride the shared live socket (`.direct`).
    func openSurfaceAsPane(_ host: HostEntry) {
        let spec = host.paneHostSpec
        Task {
            await PeerClientCoordinator.shared.openRemotePane(spec: spec)
        }
    }

    /// Sidebar workspace row entry — like `openSurfaceAsPane`, but scoped
    /// to a single remote workspace's surfaces instead of the whole host.
    /// A one-surface workspace attaches directly with no picker; a
    /// multi-surface one opens a picker restricted to that workspace.
    func openWorkspaceSurfaceAsPane(_ workspace: WorkspaceSummary, host: HostEntry) {
        let spec = host.paneHostSpec
        Task {
            await PeerClientCoordinator.shared.openWorkspaceSurfaceAsPane(
                spec: spec, workspaceID: workspace.id
            )
        }
    }

    /// Open this host workspace as a main-window workspace mirror.
    /// live=true (Phase 2B): host-authoritative layout sync; false
    /// (Phase 2A): one-shot snapshot placement, local layout afterwards.
    /// `host` is the sidebar group the row was rendered under — its spec
    /// decides SSH vs direct. SSH hosts open over an owned `.ssh` tunnel so
    /// the mirror survives the origin relay closing and daemon/network
    /// reconnects (the tunnel's local socket is re-derived per reconnect);
    /// direct hosts fall back to `.direct` on the live socket.
    func openWorkspaceAsMirror(_ workspace: WorkspaceSummary, host: HostEntry, live: Bool = true) {
        let spec = host.paneHostSpec
        Task {
            await PeerClientCoordinator.shared.openRemoteWorkspaceMirror(
                spec: spec,
                workspaceID: workspace.id,
                live: live
            )
        }
    }

    // MARK: - Workspace CRUD (workspace.lifecycle.v1)
    //
    // Each op opens its own one-shot connection (mirrors fetchWorkspaces'
    // connect → RPC → cancel pattern), never reusing a live subscription
    // session — createWorkspace in particular must run on a session whose
    // receive loop isn't already pumping (PeerSession's single-reader
    // invariant). Failures are logged inline, never surfaced via NSAlert
    // (socket focus policy: no app-activation side effects from sidebar
    // actions). Callers are expected to have already gated the triggering
    // UI on `host.supportsWorkspaceLifecycle == true`; these methods don't
    // re-check it themselves so a stale cache can't silently no-op an
    // explicit user action — the host-side RPC is the real gate.

    /// Creates a workspace on `host`, then re-fetches the roster so the new
    /// entry appears. The RPC's returned workspace id isn't consumed
    /// directly — the sidebar always reflects the host's own listing.
    func createWorkspace(host: HostEntry, title: String) {
        let path = host.activeSockPath
        let key = host.id
        guard !path.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: path)
                do {
                    // The daemon seeds the first pane at creation, so the
                    // workspace is born with a shell — no client-side
                    // NewTab needed here.
                    _ = try await conn.session.createWorkspace(title: title)
                } catch {
                    #if DEBUG
                    dlog("peer.sidebar.createWorkspace rpc-fail key=\(key) error=\(error)")
                    #endif
                }
                await conn.cancel()
            } catch {
                #if DEBUG
                dlog("peer.sidebar.createWorkspace connect-fail key=\(key) error=\(error)")
                #endif
                return
            }
            // Small settle for the daemon to apply NewTab before the
            // roster refetch, so the row lands already populated.
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.fetchWorkspaces(for: path, key: key)
        }
    }

    /// Renames `workspace` on `host`. The rename RPC is fire-and-forget
    /// (no reply frame) — the re-fetch below is what surfaces the result.
    func renameWorkspace(_ workspace: WorkspaceSummary, host: HostEntry, title: String) {
        let path = host.activeSockPath
        let key = host.id
        guard !path.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: path)
                do {
                    try await conn.session.renameWorkspace(workspaceID: workspace.id, title: title)
                } catch {
                    #if DEBUG
                    dlog("peer.sidebar.renameWorkspace rpc-fail key=\(key) error=\(error)")
                    #endif
                }
                await conn.cancel()
            } catch {
                #if DEBUG
                dlog("peer.sidebar.renameWorkspace connect-fail key=\(key) error=\(error)")
                #endif
                return
            }
            self.fetchWorkspaces(for: path, key: key)
        }
    }

    /// Deletes `workspace` on `host`. Fire-and-forget RPC — the host pushes
    /// `WorkspaceUpdate.workspaceRemoved` to any attached mirror sessions
    /// (`PeerWorkspaceMirrorController.markHostWorkspaceGone()` auto-closes
    /// those via `TabManager.closeWorkspace`), and this sidebar's own
    /// re-fetch drops the row.
    func deleteWorkspace(_ workspace: WorkspaceSummary, host: HostEntry) {
        let path = host.activeSockPath
        let key = host.id
        guard !path.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: path)
                do {
                    try await conn.session.deleteWorkspace(workspaceID: workspace.id)
                } catch {
                    #if DEBUG
                    dlog("peer.sidebar.deleteWorkspace rpc-fail key=\(key) error=\(error)")
                    #endif
                }
                await conn.cancel()
            } catch {
                #if DEBUG
                dlog("peer.sidebar.deleteWorkspace connect-fail key=\(key) error=\(error)")
                #endif
                return
            }
            self.fetchWorkspaces(for: path, key: key)
        }
    }
}
