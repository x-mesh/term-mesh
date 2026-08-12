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
    /// Left-to-right pane inventory for the sidebar's expandable detail.
    /// Retains the full remote cwd for project grouping while the visible
    /// pane detail label stays shortened to the final path component.
    let panes: [RemotePaneSummary]
}

/// An agent team running on a peer host. A team is invisible in the layout
/// tree — which pane leads which work is not a fact about how panes are
/// arranged — so this arrives over its own RPC and is the only way to know
/// where a project's leader sits on a machine that is not this one.
struct RemoteTeamSummary: Identifiable, Equatable {
    let name: String
    let teamUUID: String
    let workingDirectory: String
    /// Repository root the host resolved for `workingDirectory`, empty when
    /// the team was not created inside one.
    let projectRootPath: String?
    let agentNames: [String]

    var id: String { teamUUID.isEmpty ? name : teamUUID }
}

struct RemotePaneSummary: Identifiable, Equatable {
    let id: Data
    let title: String
    let workingDirectoryPath: String?
    let workingDirectoryName: String?
    /// Repository root the host resolved for this pane, when it reported one.
    /// nil on hosts predating the field — project grouping then falls back to
    /// guessing from the cwd.
    let projectRootPath: String?
    let tabCount: Int
    let columns: Int
    let rows: Int
    let isBusy: Bool
}

/// Flatten a peer layout into the compact pane details shown by the sidebar.
/// Pre-order traversal matches the visual left-to-right/top-to-bottom layout.
func peerPaneSummaries(
    _ layout: Termmesh_Peer_V1_WorkspaceLayout?
) -> [RemotePaneSummary] {
    func shortDirectoryName(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if path == "/" { return "/" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    func walk(_ node: Termmesh_Peer_V1_WorkspaceLayout) -> [RemotePaneSummary] {
        switch node.node {
        case .pane(let pane):
            return [RemotePaneSummary(
                id: pane.surfaceID,
                title: pane.title.isEmpty ? "Shell" : pane.title,
                workingDirectoryPath: pane.cwd.isEmpty ? nil : pane.cwd,
                workingDirectoryName: shortDirectoryName(pane.cwd),
                projectRootPath: pane.projectRoot.isEmpty ? nil : pane.projectRoot,
                tabCount: max(pane.tabs.count, 1),
                columns: Int(pane.cols),
                rows: Int(pane.rows),
                isBusy: pane.busy
            )]
        case .split(let split):
            return walk(split.first) + walk(split.second)
        case .none:
            return []
        }
    }

    guard let layout else { return [] }
    return walk(layout)
}

/// Every terminal surface owned by a peer workspace, including inactive tabs.
/// `WorkspacePane.surfaceID` names only the active tab; deletion and durable
/// ownership cleanup must also account for every entry in `tabs[]`.
func peerSurfaceIDs(
    _ layout: Termmesh_Peer_V1_WorkspaceLayout
) -> Set<Data> {
    func walk(_ node: Termmesh_Peer_V1_WorkspaceLayout) -> Set<Data> {
        switch node.node {
        case .pane(let pane):
            var ids = Set(pane.tabs.map(\.surfaceID).filter { !$0.isEmpty })
            if !pane.surfaceID.isEmpty {
                ids.insert(pane.surfaceID)
            }
            return ids
        case .split(let split):
            return walk(split.first).union(walk(split.second))
        case .none:
            return []
        }
    }
    return walk(layout)
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

struct PeerProjectIdentity: Identifiable, Equatable, Hashable {
    let key: String
    let label: String
    let isUnknown: Bool

    var id: String { key }

    static let unknown = PeerProjectIdentity(
        key: "unknown",
        label: "Unknown Project",
        isUnknown: true
    )
}

/// What the whole sidebar is organised by. This began as a grouping control
/// inside the Peer Hosts section, which is why the stored key still says so —
/// but a control that only regrouped peers while the local sections stayed put
/// read as a global switch and behaved as a local one. The two are now
/// alternative views of everything: Host answers "which machine is this on",
/// Project answers "what is this work part of".
enum SidebarAxis: String, CaseIterable, Identifiable {
    case host
    case project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host: return "Host"
        case .project: return "Project"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .host: return "Group the sidebar by machine"
        case .project: return "Group the sidebar by project"
        }
    }
}

enum SidebarAxisSettings {
    /// Off pins the sidebar to Host and hides the switch entirely — the
    /// escape hatch from when the Project view was new.
    static let featureFlagKey = "sidebar.peerHosts.groupingControl.enabled"
    /// Deliberately still the old key: the stored values (`host` / `project`)
    /// did not change, and renaming it would silently reset every existing
    /// install to the default for no gain.
    static let selectedAxisKey = "sidebar.peerHosts.groupingMode"
    static let defaultAxis = SidebarAxis.host

    static func axis(from raw: String) -> SidebarAxis {
        SidebarAxis(rawValue: raw) ?? defaultAxis
    }
}

func peerProjectIdentity(for panes: [RemotePaneSummary]) -> PeerProjectIdentity {
    // A reported repo root is an answer, not a guess, so it wins outright.
    // With real roots in hand a majority vote is meaningful: panes in two
    // repos genuinely put the workspace in the one it mostly works on,
    // whereas voting on cwds would be voting on subdirectory names.
    let roots = panes.compactMap(\.projectRootPath)
    if let winner = mostCommonProjectRoot(roots) {
        return projectIdentity(forWorkingDirectories: [winner])
    }
    return projectIdentity(forWorkingDirectories: panes.compactMap(\.workingDirectoryPath))
}

/// The repo root most panes report, ties going to the leftmost pane.
/// nil when no pane reported one (a host predating `project_root`).
private func mostCommonProjectRoot(_ roots: [String]) -> String? {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for root in roots.compactMap(peerNormalizeRemotePath) {
        if counts[root] == nil { order.append(root) }
        counts[root, default: 0] += 1
    }
    guard var best = order.first else { return nil }
    for root in order.dropFirst() where counts[root, default: 0] > counts[best, default: 0] {
        best = root
    }
    return best
}

/// Project identity for a set of working directories, whatever produced them
/// — peer pane cwds off the wire, or a local workspace's panel directories.
/// Both axes must agree on what counts as a project, or the same checkout
/// would group differently depending on which side reported it.
func projectIdentity(forWorkingDirectories rawPaths: [String]) -> PeerProjectIdentity {
    let paths = rawPaths.compactMap(peerNormalizeRemotePath)
    guard !paths.isEmpty else { return .unknown }

    // Panes working in unrelated trees collapse the common ancestor up to a
    // home or a system root, which is NOT a project — a peer shelling in
    // `/root` would otherwise surface a bogus "root" project grouping every
    // one of its workspaces. Refusing to name it leaves the workspace
    // unassigned, which is the honest answer: cwd alone cannot tell us where
    // the project root is (that needs the host's git root — see `docs/`).
    let root = peerCommonProjectPath(paths)
    guard peerPathNamesProject(root),
          let name = root.split(separator: "/").last.map(String.init),
          !name.isEmpty else {
        return .unknown
    }
    // Keyed by folder name, not by absolute path: the same project checked
    // out at `~/work/project/term-mesh` locally and `/root/term-mesh` on a
    // peer is ONE project, and a path key would split it in two.
    return PeerProjectIdentity(
        key: "name:\(name.lowercased())",
        label: name,
        isUnknown: false
    )
}

/// Path prefixes that only ever contain homes or system state, so their
/// direct children name a user or a mount rather than a project.
/// `/root/term-mesh` still qualifies — `root` here IS the home, not a prefix.
private let peerNonProjectPrefixes: Set<String> = [
    "Users", "home", "private", "var", "tmp", "mnt", "media", "Volumes",
]

/// Whether a normalized absolute path's last component can stand for a
/// project. Rejects `/`, any bare top-level directory (`/root`, `/tmp`), and
/// a home directory itself (`/Users/jinwoo`, `/home/ubuntu`).
private func peerPathNamesProject(_ path: String) -> Bool {
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return false }
    if parts.count == 2, peerNonProjectPrefixes.contains(parts[0]) { return false }
    return true
}

private func peerNormalizeRemotePath(_ path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let unified = trimmed.replacingOccurrences(of: "\\", with: "/")
    let parts = unified
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
        .filter { $0 != "." }
    guard !parts.isEmpty else { return "/" }
    return "/" + parts.joined(separator: "/")
}

private func peerCommonProjectPath(_ paths: [String]) -> String {
    guard var common = paths.first?.split(separator: "/").map(String.init) else { return "/" }
    for path in paths.dropFirst() {
        let parts = path.split(separator: "/").map(String.init)
        common = Array(zip(common, parts).prefix { $0 == $1 }.map { $0.0 })
        if common.isEmpty { return "/" }
    }
    return "/" + common.joined(separator: "/")
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

/// Immutable identity of the SSH endpoint whose handshake authenticated
/// launch metadata. `remoteSocket` is the profile's configured value (empty
/// means auto-detect), not the mutable resolved-socket cache.
struct PeerHostEndpointProvenance: Equatable, Sendable {
    let sshTarget: String
    let port: Int?
    let identityFile: String?
    let remoteSocket: String
}

struct HostEntry: Identifiable, Equatable {
    let id: String         // stable dedup key (stableKey)
    var displayName: String
    var connectionState: HostConnectionState
    var workspaces: [WorkspaceSummary]
    /// Agent teams the host reported, empty on hosts predating
    /// `team.roster.v1` or running none.
    var teams: [RemoteTeamSummary] = []
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
    /// Version advertised by the process that completed the current peer
    /// handshake. This is the serving version, not whichever binary an SSH
    /// login shell happens to resolve, so creation UI can explain capability
    /// fallback before launching work on the host.
    var servingAppVersion: String? = nil
    /// Whether the serving process can own a Native Codex/Kiro agent for its
    /// full lifetime. Nil means no current authenticated handshake supplied
    /// the answer; false is an explicit compatibility result, not offline.
    var supportsPeerOwnedAgentHosting: Bool? = nil
    /// Whether `tm-agent` inside a remote pane can reach the owning project
    /// through the scoped `team.leader.v1` reverse route. A host may have a
    /// newer tm-agent in its login PATH while the serving daemon is older;
    /// only the authenticated handshake answers this correctly.
    var supportsRemoteTeamRoute: Bool? = nil
    /// Authenticated host CLI directories. Live-session cache only: never
    /// written to PeerHostProfile/UserDefaults and cleared with the socket.
    var hostCLIBinDirs: [String] = []
    /// True once `hostCLIBinDirs` reflects the current connection's own
    /// handshake (set alongside it in `fetchWorkspaces`), false while a
    /// fresh connection is still in flight. `connectionState` flips to
    /// `.connected` synchronously (lease acquired), but the authenticated
    /// bin dirs only land after a second async round trip — a launch that
    /// gates on `isConnected` alone can race that gap and start a remote
    /// CLI with an empty PATH addition. `isLaunchable` closes it.
    var hostCLIBinDirsResolved: Bool = false
    /// Profile route currently configured for this row. Kept separate from
    /// mutable display/connection fields so profile sync cannot relabel an
    /// earlier handshake as belonging to a newly edited endpoint.
    var configuredEndpoint: PeerHostEndpointProvenance?
    /// Exact endpoint tuple captured before the handshake that supplied
    /// `hostCLIBinDirs`. Nil means the metadata is pending or invalid.
    var hostCLIBinDirsProvenance: PeerHostEndpointProvenance?

    var isConnected: Bool { connectionState == .connected }
    var servingVersionDisplay: String? {
        guard let raw = servingAppVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard PeerDaemonVersion.parseComponents(raw) != nil else { return raw }
        return raw.hasPrefix("v") || raw.hasPrefix("V") ? raw : "v\(raw)"
    }

    /// Compact label shared by project/team placement pickers. It names the
    /// process actually serving the peer connection, which can differ from an
    /// updated app bundle that has not been restarted yet.
    var versionedDisplayName: String {
        guard let version = servingVersionDisplay else { return displayName }
        return "\(displayName) · \(version)"
    }

    /// Use this instead of `isConnected` before starting any remote CLI
    /// process (leader/agent attach, CLI availability probes) — those
    /// consume `hostCLIBinDirs` and must not race its resolution.
    var isLaunchable: Bool {
        isConnected
            && hostCLIBinDirsResolved
            && hostCLIBinDirsProvenance != nil
            && hostCLIBinDirsProvenance == configuredEndpoint
    }

    mutating func applyConfiguredEndpoint(_ endpoint: PeerHostEndpointProvenance) {
        let changed = configuredEndpoint != endpoint
        if changed {
            clearAuthenticatedHostCLIBinDirs()
            clearServingMetadata()
        }
        configuredEndpoint = endpoint
        sshTarget = endpoint.sshTarget
        sshPort = endpoint.port
        identityFile = endpoint.identityFile
        // A route edit invalidates the previous resolved-socket cache too.
        // For an unchanged auto-detect route, preserve the live resolution.
        if changed || !endpoint.remoteSocket.isEmpty || remoteSockPath == nil {
            remoteSockPath = endpoint.remoteSocket.isEmpty ? nil : endpoint.remoteSocket
        }
    }

    mutating func acceptAuthenticatedHostCLIBinDirs(
        _ dirs: [String],
        provenance: PeerHostEndpointProvenance
    ) -> Bool {
        guard configuredEndpoint == provenance else {
            clearAuthenticatedHostCLIBinDirs()
            return false
        }
        hostCLIBinDirs = dirs
        hostCLIBinDirsResolved = true
        hostCLIBinDirsProvenance = provenance
        return true
    }

    mutating func clearAuthenticatedHostCLIBinDirs() {
        hostCLIBinDirs = []
        hostCLIBinDirsResolved = false
        hostCLIBinDirsProvenance = nil
    }

    mutating func clearServingMetadata() {
        supportsWorkspaceLifecycle = nil
        servingAppVersion = nil
        supportsPeerOwnedAgentHosting = nil
        supportsRemoteTeamRoute = nil
    }

    /// Detach profile-owned configuration without letting a still-live
    /// connection retain launch authority from the profile's old route. This
    /// is required when an sshTarget edit moves the profile to a new stable
    /// dictionary key: the old row can remain visible until its connection
    /// closes, but it is metadata-pending and cannot launch remote tools.
    mutating func detachProfileConfiguration() {
        profileID = nil
        colorHex = nil
        symbolName = nil
        configuredEndpoint = nil
        clearAuthenticatedHostCLIBinDirs()
        clearServingMetadata()
    }

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

    /// Returns readiness metadata only when the exact endpoint tuple being
    /// probed already backs a live, authenticated connection for this
    /// profile. Matching on `profileID` alone is not enough: sshTarget,
    /// port, identityFile, and the pinned remote socket are all
    /// independently editable in the host editor sheet, so a profile can
    /// keep its id while pointing at a different machine entirely — and
    /// target-only matching (the previous behavior) can then leak a stale
    /// connection's authenticated CLI directories onto an endpoint that
    /// connection never actually reached. An empty `remoteSocket` means
    /// "auto-detect" and is compatible with whatever socket the live
    /// connection resolved, since that field genuinely hasn't changed.
    nonisolated static func hostCLIBinDirs(
        forProfileID profileID: UUID,
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        remoteSocket: String,
        in hosts: [HostEntry]
    ) -> [String] {
        let requested = PeerHostEndpointProvenance(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            remoteSocket: remoteSocket
        )
        return hosts.first {
            $0.profileID == profileID
                && $0.isLaunchable
                && $0.hostCLIBinDirsProvenance == requested
        }?.hostCLIBinDirs ?? []
    }

    nonisolated static func selectableLaunchHosts(in hosts: [HostEntry]) -> [HostEntry] {
        hosts.filter { $0.isLaunchable && !(($0.sshTarget ?? "").isEmpty) }
    }

    /// Whether the viewer may take the agent-surface path against this host
    /// connection at all. Check it BEFORE opening or ensuring an agent
    /// surface (`SurfaceInfo.surface_type == "agent"` /
    /// `EnsureSurfaceRequest.kind = "agent"`), passing the connection's
    /// negotiated `hostCapabilities` (`conn.hostCapabilities`, the same
    /// value the workspace-lifecycle and roster gates below read). A host
    /// that did not advertise `surface.agent.v1` in its Hello is an older
    /// daemon that cannot own a `tm-agent-bridge` child: the agent path is
    /// not issued against it, and the existing terminal path is left
    /// exactly as it was.
    ///
    /// For listing-driven paths this is deliberate defensive duplication:
    /// an old daemon never reports `surface_type == "agent"` in the first
    /// place, and a Phase 1 daemon enforces its own half of the gate by
    /// demoting agent surfaces to `attachable = false` (and rejecting
    /// attach) for clients that did not advertise the capability. The
    /// primary consumer is the request the viewer originates on its own —
    /// `EnsureSurfaceRequest.kind = "agent"` (Phase 3, the team
    /// orchestrator's remote agent factory) — where no host-side listing
    /// has filtered anything before the request leaves this machine.
    nonisolated static func hostSupportsAgentSurfaces(
        _ hostCapabilities: PeerCapabilities
    ) -> Bool {
        hostCapabilities.has(PeerCapability.surfaceAgentV1)
    }

    /// Creating a new peer-owned agent has a stronger contract than merely
    /// viewing an existing agent surface: its environment must arrive intact
    /// and its authoritative exit must close the AgentSession. Missing any
    /// one capability selects the established terminal fallback.
    nonisolated static func hostSupportsPeerOwnedAgentFactory(
        _ hostCapabilities: PeerCapabilities
    ) -> Bool {
        hostCapabilities.has(PeerCapability.surfaceAgentV1)
            && hostCapabilities.has(PeerCapability.surfaceExitV1)
            && hostCapabilities.has(PeerCapability.surfaceEnsureEnvV1)
    }

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
    /// One long-lived, receive-only roster stream per sidebar host. It never
    /// shares a session with a response-waiting RPC: `WorkspaceListChanged`
    /// frames are pushed asynchronously and PeerSession has one reader.
    private var rosterSubscriptionTasks: [String: Task<Void, Never>] = [:]
    /// Sidebar-held lease per host key: one ref that keeps the tunnel
    /// alive while the user browses workspaces. Panes/mirrors opened
    /// from here hold their own refs, so a sidebar disconnect never
    /// kills them (registry refcount semantics).
    private var sidebarLeases: [String: PeerPaneHostLease] = [:]
    /// Preserved panes remain in the coordinator roster after an intentional
    /// host disconnect. Ignore their retired tunnel path during rebuild so a
    /// dead view cannot immediately promote the host back to `.connected`.
    /// A fresh SSH lease receives a fresh local socket path.
    private var disconnectedSockPaths: [String: Set<String>] = [:]
    private var connectTasks: [String: Task<Void, Never>] = [:]
    /// Available only after an auto socket probe. It lets Cancel stop exactly
    /// the matching pending SSH acquire, never another host's live lease.
    private var connectingLeaseKeys: [String: PeerPaneHostKey] = [:]
    /// A late completion from a cancelled attempt must not turn the row back
    /// into connected after the user has already pressed Retry.
    private var connectAttemptIDs: [String: UUID] = [:]
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
                let endpoint = PeerHostEndpointProvenance(
                    sshTarget: p.sshTarget, port: p.sshPort,
                    identityFile: p.identityFile, remoteSocket: p.remoteSocket
                )
                hosts[key] = HostEntry(
                    id: key,
                    displayName: p.effectiveDisplayName,
                    connectionState: .saved,
                    workspaces: [],
                    activeSockPath: "",
                    sshTarget: p.sshTarget,
                    remoteSockPath: p.connectionSocket,
                    sshPort: p.sshPort,
                    identityFile: p.identityFile,
                    profileID: p.id,
                    colorHex: p.colorHex,
                    symbolName: p.symbolName,
                    configuredEndpoint: endpoint
                )
            } else {
                hosts[key]?.profileID = p.id
                hosts[key]?.displayName = p.effectiveDisplayName
                hosts[key]?.colorHex = p.colorHex
                hosts[key]?.symbolName = p.symbolName
                // A coordinator-discovered row may predate its saved profile
                // and therefore have no SSH route. Keep the route in sync too:
                // placement pickers intentionally hide entries that cannot be
                // reached over SSH to prepare their project checkout.
                // Always replace the row's route from the profile. This is
                // what makes clearing an explicit socket observable: upsert
                // invalidates `lastResolvedSocket`, so this assignment turns
                // the old row cache into nil and the next connect probes.
                let endpoint = PeerHostEndpointProvenance(
                    sshTarget: p.sshTarget, port: p.sshPort,
                    identityFile: p.identityFile, remoteSocket: p.remoteSocket
                )
                hosts[key]?.applyConfiguredEndpoint(endpoint)
                if p.remoteSocket.isEmpty, hosts[key]?.remoteSockPath == nil {
                    hosts[key]?.remoteSockPath = p.connectionSocket
                }
            }
        }
        for (key, entry) in hosts where entry.profileID != nil && !profileKeys.contains(key) {
            if entry.isConnected || sidebarLeases[key] != nil {
                hosts[key]?.detachProfileConfiguration()
            } else {
                hosts[key] = nil
            }
        }
    }

    /// Derive a stable dedup key per connection.
    /// SSH tunnels use a unique local socket path per session, so keying by
    /// hostSockPath would insert a new HostEntry on every reconnect. Instead:
    ///   SSH connection  → "ssh:<sshTarget>" (stable across reconnects)
    ///   Direct socket   → hostSockPath (already stable)
    /// LIMITATION: same sshTarget with different remote sockets collapse into
    /// one entry; needs remoteSockPath in connectionInfo to distinguish them.
    private func stableKey(for conn: PeerRelayConnectionInfo) -> String {
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

    private func syncFromCoordinator() {
        let connections = PeerClientCoordinator.shared.activeConnections()

        // Key derivation lives in `stableKey(for:)` so Force Disconnect can
        // resolve the same host identity from a connection row.

        var activeKeys = Set<String>()
        for conn in connections {
            let key = stableKey(for: conn)
            if disconnectedSockPaths[key]?.contains(conn.hostSockPath) == true {
                // A reconnect installs a new current lease. SSH gets a fresh
                // path; direct sockets reuse theirs, so identity-by-path alone
                // would suppress a successful direct reconnect forever.
                let leaseKey: PeerPaneHostKey
                if let existingHost = hosts[key], existingHost.sshTarget != nil {
                    leaseKey = existingHost.paneHostSpec.hostKey
                } else {
                    leaseKey = .direct(sockPath: conn.hostSockPath)
                }
                guard PeerPaneHostRegistry.shared.activeLease(forKey: leaseKey)?
                    .hostSockPath == conn.hostSockPath
                else { continue }
                disconnectedSockPaths[key]?.remove(conn.hostSockPath)
            }
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
                fetchWorkspaces(for: conn.hostSockPath, key: key, provenance: nil)
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
                    hosts[key]?.clearAuthenticatedHostCLIBinDirs()
                    hosts[key]?.activeSockPath = conn.hostSockPath
                    hosts[key]?.workspaces = []
                    fetchWorkspaces(for: conn.hostSockPath, key: key, provenance: nil)
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
                hosts[key]?.clearAuthenticatedHostCLIBinDirs()
            }
        }
    }

    // MARK: - Sidebar connect / disconnect (saved hosts)

    /// Wall-clock budget for a sidebar connect attempt. Nothing below
    /// `PeerPaneHostRegistry.acquire` carries a deadline of its own — an ssh
    /// spawn that never reports leaves the row in `.connecting` with no way
    /// back — so the row gives up here and offers Retry instead.
    private static let connectTimeoutSeconds: Double = 45

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
        let attemptID = UUID()
        connectAttemptIDs[key] = attemptID
        hosts[key]?.connectionState = .connecting
        #if DEBUG
        dlog("peer.sidebar.connect start key=\(key)")
        #endif
        connectTasks[key] = Task { [weak self] in
            guard let self else { return }
            // The acquire below can block indefinitely (a hung ssh spawn is
            // not cancellation-cooperative), which would strand the row in
            // `.connecting` where neither Connect nor Disconnect is offered.
            // The watchdog only moves the row to `.failed` so Retry becomes
            // reachable — it never touches the in-flight acquire, and the
            // attemptID guard below still adopts a late success.
            let watchdog = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.connectTimeoutSeconds * 1_000_000_000)
                )
                guard !Task.isCancelled, let self else { return }
                guard self.connectAttemptIDs[key] == attemptID,
                      self.hosts[key]?.connectionState == .connecting
                else { return }
                self.hosts[key]?.connectionState =
                    .failed("Timed out after \(Int(Self.connectTimeoutSeconds))s")
                #if DEBUG
                dlog("peer.sidebar.connect timeout key=\(key)")
                #endif
                RemoteWorkLog.info(
                    "\(host.displayName) did not answer in \(Int(Self.connectTimeoutSeconds))s — use Retry Connection"
                )
            }
            defer { watchdog.cancel() }
            defer {
                if self.connectAttemptIDs[key] == attemptID {
                    self.connectTasks[key] = nil
                    self.connectingLeaseKeys[key] = nil
                    self.connectAttemptIDs[key] = nil
                }
            }
            do {
                let profile = PeerHostProfileStore.shared.profile(id: host.profileID)
                let provenance = PeerHostEndpointProvenance(
                    sshTarget: target, port: profile?.sshPort,
                    identityFile: profile?.identityFile,
                    remoteSocket: profile?.remoteSocket ?? (host.remoteSockPath ?? "")
                )
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
                self.connectingLeaseKeys[key] = spec.hostKey
                let lease = try await PeerPaneHostRegistry.shared.acquire(spec)
                // Cancellation is cooperative. If the acquire completed while
                // ssh was being reaped, balance it instead of reviving this row.
                guard !Task.isCancelled,
                      self.connectAttemptIDs[key] == attemptID,
                      self.hosts[key] != nil
                else {
                    PeerPaneHostRegistry.shared.release(lease)
                    return
                }
                self.sidebarLeases[key] = lease
                self.hosts[key]?.connectionState = .connected
                self.hosts[key]?.activeSockPath = lease.hostSockPath
                self.hosts[key]?.remoteSockPath = socket
                // Panes that Disconnect Host kept on screen have been showing a
                // transcript with nothing behind it. The transport exists again
                // as of this line, so this is where they become live.
                PeerClientCoordinator.shared.resumePanesAfterHostReconnect(spec.hostKey)
                PeerHostProfileStore.shared.recordConnection(
                    sshTarget: target, resolvedSocket: socket
                )
                self.fetchWorkspaces(
                    for: lease.hostSockPath, key: key, provenance: provenance
                )
                SidebarLayoutSettings.setHostCollapsed(key, false)
                self.expandSignal = ExpandSignal(
                    key: key, generation: self.expandSignal.generation + 1
                )
                #if DEBUG
                dlog("peer.sidebar.connect ok key=\(key) sock=\(lease.hostSockPath)")
                #endif
            } catch is CancellationError {
                // cancelConnectingHost already restored the row to `.saved`.
            } catch {
                guard self.connectAttemptIDs[key] == attemptID else { return }
                self.hosts[key]?.clearAuthenticatedHostCLIBinDirs()
                self.hosts[key]?.connectionState = .failed(String(describing: error))
                #if DEBUG
                dlog("peer.sidebar.connect fail key=\(key) error=\(error)")
                #endif
            }
        }
    }

    /// Cancel an in-progress sidebar connection and return immediately to a
    /// retryable state. Existing panes/mirrors retain their independent
    /// leases; only this host-row attempt is stopped.
    func cancelConnectingHost(_ host: HostEntry) {
        let key = host.id
        guard case .connecting = hosts[key]?.connectionState else { return }
        connectAttemptIDs[key] = nil
        connectTasks[key]?.cancel()
        connectTasks[key] = nil
        if let hostKey = connectingLeaseKeys[key] {
            PeerPaneHostRegistry.shared.cancelPendingAcquire(for: hostKey)
        }
        connectingLeaseKeys[key] = nil
        fetchTasks[key]?.cancel()
        fetchTasks[key] = nil
        stopWorkspaceSubscription(for: key)
        hosts[key]?.workspaces = []
        hosts[key]?.activeSockPath = ""
        hosts[key]?.clearServingMetadata()
        hosts[key]?.clearAuthenticatedHostCLIBinDirs()
        hosts[key]?.connectionState = .saved
        #if DEBUG
        dlog("peer.sidebar.connect cancelled key=\(key)")
        #endif
        RemoteWorkLog.info("Cancelled connection to \(host.displayName)")
    }

    /// Abandon whatever this row is doing and start a fresh attempt.
    /// Reachable from `.connecting` and `.failed` alike, because both can
    /// leave `connectTasks[key]` populated — a hung acquire never returns to
    /// clear it, and that leftover entry makes `connectSavedHost` return
    /// immediately, which is what leaves a stuck row with no way forward.
    /// Returns false when the attempt could not actually be restarted.
    @discardableResult
    func retryConnectingHost(_ host: HostEntry) -> Bool {
        let key = host.id
        // Release the sidebar lease first. `connectSavedHost` returns early
        // while one exists, so retrying a row that already holds a lease — a
        // connected host, or one whose watchdog gave up after the acquire had
        // in fact succeeded — would report that it started and then do
        // nothing at all.
        if let lease = sidebarLeases[key] {
            sidebarLeases[key] = nil
            PeerPaneHostRegistry.shared.release(lease)
        }
        connectAttemptIDs[key] = nil
        connectTasks[key]?.cancel()
        connectTasks[key] = nil
        var cancelledPending = true
        if let hostKey = connectingLeaseKeys[key] {
            cancelledPending = PeerPaneHostRegistry.shared.cancelPendingAcquire(for: hostKey)
        }
        connectingLeaseKeys[key] = nil
        fetchTasks[key]?.cancel()
        fetchTasks[key] = nil
        stopWorkspaceSubscription(for: key)
        hosts[key]?.workspaces = []
        hosts[key]?.activeSockPath = ""
        hosts[key]?.clearServingMetadata()
        hosts[key]?.clearAuthenticatedHostCLIBinDirs()
        hosts[key]?.connectionState = .saved
        #if DEBUG
        dlog("peer.sidebar.connect retry key=\(key) cancelledPending=\(cancelledPending)")
        #endif
        if !cancelledPending {
            // A pane or mirror is waiting on the same coalesced start, so it
            // cannot be cancelled from here. connectSavedHost would rejoin that
            // very task, leaving the row stuck and the waiter count higher —
            // say so rather than pretending a fresh attempt began.
            RemoteWorkLog.info(
                "Cannot restart \(host.displayName) — another pane is waiting on the same connection attempt; close it first"
            )
            return false
        }
        RemoteWorkLog.info("Retrying connection to \(host.displayName)")
        connectSavedHost(host)
        return true
    }

    /// Close every pane, mirror and relay window opened from this host, then
    /// release the sidebar lease.
    ///
    /// `disconnectSavedHost` deliberately leaves panes running, so a row whose
    /// only remaining refs are panes has no lease — and with no lease the
    /// Disconnect button is hidden while `syncFromCoordinator` keeps
    /// re-promoting the row to `.connected` on every rebuild. That combination
    /// offers the user no action at all; this is the escape hatch out of it.
    /// Close order for a force disconnect: mirrors and relay windows first,
    /// panes last.
    ///
    /// While a live mirror owns the workspace,
    /// `Workspace.mirrorForwardsLocalActions` turns every local close into a
    /// forwardClose to the host and returns false — the pane stays put until
    /// the host pushes a layout that drops it, which it never does for the
    /// last surface in a workspace, so exactly one pane survives. Tearing the
    /// mirror down first flips that predicate off and restores plain local
    /// close semantics for the panes that follow.
    ///
    /// Kept order-stable within each group so the close sequence stays
    /// predictable (activeConnections is already sorted by connectedAt).
    ///
    /// `nonisolated` so tests can call it synchronously without the MainActor
    /// hop, matching the pure-helper pattern in PeerHostProfileStore.
    nonisolated static func forceDisconnectOrder(
        _ rows: [PeerRelayConnectionInfo]
    ) -> [PeerRelayConnectionInfo] {
        rows.filter { $0.kind != .pane } + rows.filter { $0.kind == .pane }
    }

    /// Returns how many connections were asked to close. Counting rows here is
    /// the only accurate measure: window closes land asynchronously, so
    /// comparing `activeConnections().count` before and after reports 0, and it
    /// would also fold in unrelated hosts' connections.
    @discardableResult
    func forceDisconnectSavedHost(_ host: HostEntry) -> Int {
        let key = host.id
        let coordinator = PeerClientCoordinator.shared
        // Resolve rows before clearing activeSockPath: stableKey folds
        // borrowed-socket connections in by matching that very field.
        let rows = coordinator.activeConnections()
            .filter { stableKey(for: $0) == key }
        let ordered = Self.forceDisconnectOrder(rows)
        for row in ordered {
            coordinator.disconnect(id: row.id)
        }
        let ids = ordered.map(\.id)
        if let lease = sidebarLeases[key] {
            sidebarLeases[key] = nil
            PeerPaneHostRegistry.shared.release(lease)
        }
        connectAttemptIDs[key] = nil
        connectTasks[key]?.cancel()
        connectTasks[key] = nil
        // The registry starts the tunnel in a detached Task that does not
        // inherit the cancel above, so an in-flight — or hung — ssh spawn
        // would outlive the force disconnect and leak its helper process.
        // Cancel it before dropping the key that identifies it.
        if let hostKey = connectingLeaseKeys[key] {
            PeerPaneHostRegistry.shared.cancelPendingAcquire(for: hostKey)
        }
        connectingLeaseKeys[key] = nil
        fetchTasks[key]?.cancel()
        fetchTasks[key] = nil
        stopWorkspaceSubscription(for: key)
        hosts[key]?.workspaces = []
        hosts[key]?.activeSockPath = ""
        hosts[key]?.clearServingMetadata()
        hosts[key]?.clearAuthenticatedHostCLIBinDirs()
        hosts[key]?.connectionState = .saved
        #if DEBUG
        dlog("peer.sidebar.forceDisconnect key=\(key) closed=\(ids.count)")
        #endif
        rebuild()
        RemoteWorkLog.info(
            "Force-disconnected \(host.displayName) — closed \(ids.count) connection(s)"
        )
        return ids.count
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
            stopBrowsingSavedHost(host)
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

    /// Stop browsing this host in the sidebar without ending its transport.
    /// Used while deleting a saved profile: panes and mirrors retain their
    /// refs and stay connected as ad-hoc entries.
    func stopBrowsingSavedHost(_ host: HostEntry) {
        let key = host.id
        guard let lease = sidebarLeases[key] else { return }
        sidebarLeases[key] = nil
        PeerPaneHostRegistry.shared.release(lease)
        fetchTasks[key]?.cancel()
        stopWorkspaceSubscription(for: key)
        hosts[key]?.workspaces = []
        hosts[key]?.activeSockPath = ""
        hosts[key]?.clearServingMetadata()
        hosts[key]?.clearAuthenticatedHostCLIBinDirs()
        if hosts[key]?.connectionState == .connected {
            hosts[key]?.connectionState = .saved
        }
        #if DEBUG
        dlog("peer.sidebar.disconnect key=\(key)")
        #endif
        rebuild()
        // Reported AFTER rebuild, because rebuild decides whether a pane or
        // mirror keeps the host connected. This action is deliberately named
        // Stop Browsing in the UI: it releases the sidebar lease without
        // claiming that every connection ended.
        if hosts[key]?.connectionState == .connected {
            RemoteWorkLog.info(
                "Stopped browsing \(host.displayName) — open panes stay connected"
            )
        } else {
            RemoteWorkLog.info("Stopped browsing \(host.displayName)")
        }
    }

    /// End only this host's pooled transport. Pane/mirror objects and remote
    /// processes remain alive; their existing disconnected UI keeps the local
    /// context visible and reconnects through a fresh lease when requested.
    @discardableResult
    func disconnectSavedHost(_ host: HostEntry) -> Bool {
        let key = host.id
        let registry = PeerPaneHostRegistry.shared
        let hostKey = sidebarLeases[key]?.key ?? host.paneHostSpec.hostKey
        PeerClientCoordinator.shared.preparePanesForHostDisconnect(hostKey)
        let retiredPath = registry.disconnectTransport(for: hostKey)

        if let lease = sidebarLeases.removeValue(forKey: key) {
            registry.release(lease)
        }
        if let retiredPath, !retiredPath.isEmpty {
            disconnectedSockPaths[key, default: []].insert(retiredPath)
        }
        connectAttemptIDs[key] = nil
        connectTasks[key]?.cancel()
        connectTasks[key] = nil
        if let connectingKey = connectingLeaseKeys[key] {
            registry.cancelPendingAcquire(for: connectingKey)
        }
        connectingLeaseKeys[key] = nil
        fetchTasks[key]?.cancel()
        fetchTasks[key] = nil
        stopWorkspaceSubscription(for: key)
        hosts[key]?.workspaces = []
        hosts[key]?.activeSockPath = ""
        hosts[key]?.clearServingMetadata()
        hosts[key]?.clearAuthenticatedHostCLIBinDirs()
        hosts[key]?.connectionState = .saved
        rebuild()
        #if DEBUG
        dlog("peer.sidebar.hostDisconnect key=\(key) transportStopped=\(retiredPath != nil)")
        #endif
        RemoteWorkLog.info(
            retiredPath == nil
                ? "No active transport to disconnect for \(host.displayName)"
                : "Disconnected \(host.displayName) — panes and remote processes remain open"
        )
        return retiredPath != nil
    }

    private func fetchWorkspaces(
        for hostSockPath: String,
        key: String,
        provenance: PeerHostEndpointProvenance?
    ) {
        fetchTasks[key]?.cancel()
        stopWorkspaceSubscription(for: key)
        let path = hostSockPath
        fetchInFlight.insert(key)
        // Task inherits @MainActor; await suspensions yield main without blocking it.
        fetchTasks[key] = Task {
            defer { self.fetchInFlight.remove(key) }
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: path)
                // Record capability regardless of what listWorkspaces below does —
                // it's already known from this connection's handshake, and the
                // sidebar CRUD menu gates on it independently of the roster fetch.
                if !Task.isCancelled, self.hosts[key]?.activeSockPath == path {
                    self.hosts[key]?.supportsWorkspaceLifecycle =
                        conn.hostCapabilities.has(PeerCapability.workspaceLifecycleV1)
                    self.hosts[key]?.servingAppVersion = conn.hostAppVersion
                    self.hosts[key]?.supportsPeerOwnedAgentHosting =
                        Self.hostSupportsPeerOwnedAgentFactory(conn.hostCapabilities)
                    self.hosts[key]?.supportsRemoteTeamRoute =
                        conn.hostCapabilities.has(PeerCapability.teamLeaderV1)
                    if let provenance {
                        _ = self.hosts[key]?.acceptAuthenticatedHostCLIBinDirs(
                            conn.hostCLIBinDirs, provenance: provenance
                        )
                    } else {
                        self.hosts[key]?.clearAuthenticatedHostCLIBinDirs()
                    }
                }
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    workspaces = try await conn.session.listWorkspaces()
                } catch {
                    await conn.cancel()
                    if self.hosts[key]?.activeSockPath == path {
                        self.hosts[key]?.clearAuthenticatedHostCLIBinDirs()
                    }
                    return
                }
                // Same connection, same round trip: a team roster is only
                // meaningful next to the workspaces it leads, and opening a
                // second connection to ask would race the first one's teardown.
                // Hosts predating team.roster.v1 are never asked.
                var teams: [RemoteTeamSummary] = []
                if conn.hostCapabilities.has(PeerCapability.teamRosterV1) {
                    if let reported = try? await conn.session.listTeams() {
                        teams = reported.map { team in
                            RemoteTeamSummary(
                                name: team.name,
                                teamUUID: team.teamUuid,
                                workingDirectory: team.workingDirectory,
                                projectRootPath: team.projectRoot.isEmpty ? nil : team.projectRoot,
                                agentNames: team.agentNames
                            )
                        }
                    }
                }
                await conn.cancel()
                // Stale-path guard: a reconnect may have superseded this fetch with a
                // newer ephemeral path. Drop the result if this task was cancelled or the
                // host's active path no longer matches the path we fetched against.
                if Task.isCancelled || self.hosts[key]?.activeSockPath != path {
                    return
                }
                let summaries = workspaces.map { ws -> WorkspaceSummary in
                    let layout = ws.hasLayout ? ws.layout : nil
                    let counts = peerLayoutCounts(layout)
                    return WorkspaceSummary(
                        id: ws.workspaceID,
                        title: ws.title.isEmpty ? "<workspace>" : ws.title,
                        hostSockPath: path,
                        windowID: ws.windowID,
                        windowTitle: ws.windowTitle,
                        isDefault: ws.isDefault,
                        paneCount: counts.panes,
                        surfaceCount: counts.surfaces,
                        busyCount: counts.busy,
                        panes: peerPaneSummaries(layout)
                    )
                }
                self.hosts[key]?.workspaces = summaries
                self.hosts[key]?.teams = teams
                if conn.hostCapabilities.has(PeerCapability.workspaceListSubscribeV1) {
                    self.startWorkspaceSubscription(for: path, key: key)
                }
            } catch {
                // A refresh that cannot open a connection has learned
                // something, and dropping it on the floor was how a host could
                // sit there reading `connected` with nothing at the other end.
                // Everything downstream believes that word: the sidebar shows
                // the machine as fine, its agents as idle rather than
                // unreachable, and their tasks stay assigned with no reason
                // given. Say it instead.
                //
                // Only for a host this app currently believes is up, and only
                // when it is still the same connection — a fetch racing a
                // deliberate disconnect must not resurrect a state the user
                // just changed.
                if !Task.isCancelled,
                   self.hosts[key]?.activeSockPath == path,
                   self.hosts[key]?.isConnected == true {
                    self.hosts[key]?.connectionState = .failed(Self.unreachableReason)
                    self.hosts[key]?.workspaces = []
                    self.hosts[key]?.teams = []
                    self.hosts[key]?.clearAuthenticatedHostCLIBinDirs()
                    TeamOrchestrator.shared.markRemoteAgentsUnreachable(
                        hostKey: key,
                        reason: Self.unreachableReason
                    )
                }
            }
        }
    }

    /// What a host is told to say when a refresh cannot reach it. Its own
    /// wording would be a socket error, which describes the plumbing rather
    /// than the situation.
    static let unreachableReason = "stopped responding"

    /// Hosts whose roster is being read right now. A refresh cancels the fetch
    /// before it, which is right when the user just did something and wrong on
    /// a timer: over a slow link the next tick would keep restarting a fetch
    /// that never gets to finish.
    private var fetchInFlight: Set<String> = []

    /// Open one receive-only roster stream. The initial complete snapshot is
    /// sent by the host immediately after subscription; later snapshots are
    /// replacement values, which makes tunnel reconnects converge without
    /// local delta/replay bookkeeping.
    private func startWorkspaceSubscription(for path: String, key: String) {
        rosterSubscriptionTasks[key]?.cancel()
        rosterSubscriptionTasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await PeerRelaySession.connect(hostSockPath: path)
                guard connection.hostCapabilities.has(PeerCapability.workspaceListSubscribeV1) else {
                    await connection.cancel()
                    return
                }
                try await connection.session.subscribeWorkspaceList()
                while !Task.isCancelled {
                    let message = try await connection.session.receiveNextMessage()
                    guard case .workspaceListChanged(let workspaces) = message else { continue }
                    guard self.hosts[key]?.activeSockPath == path,
                          self.hosts[key]?.isConnected == true
                    else { continue }
                    self.applyWorkspaceRoster(workspaces, hostSockPath: path, key: key)
                }
                await connection.cancel()
            } catch is CancellationError {
                // Replacement/disconnect owns cleanup; never mark its newer
                // socket path stale.
            } catch {
                self.workspaceSubscriptionLost(key: key, path: path, error: error)
            }
        }
    }

    private func stopWorkspaceSubscription(for key: String) {
        rosterSubscriptionTasks[key]?.cancel()
        rosterSubscriptionTasks[key] = nil
    }

    private func applyWorkspaceRoster(
        _ workspaces: [Termmesh_Peer_V1_Workspace],
        hostSockPath: String,
        key: String
    ) {
        hosts[key]?.workspaces = workspaces.map { ws in
            let layout = ws.hasLayout ? ws.layout : nil
            let counts = peerLayoutCounts(layout)
            return WorkspaceSummary(
                id: ws.workspaceID,
                title: ws.title.isEmpty ? "<workspace>" : ws.title,
                hostSockPath: hostSockPath,
                windowID: ws.windowID,
                windowTitle: ws.windowTitle,
                isDefault: ws.isDefault,
                paneCount: counts.panes,
                surfaceCount: counts.surfaces,
                busyCount: counts.busy,
                panes: peerPaneSummaries(layout)
            )
        }
    }

    /// A dead subscription is a stale sidebar, not an empty remote machine.
    /// Preserve the latest snapshot for context but surface the row as failed;
    /// an SSH tunnel reconnect updates activeSockPath through `rebuild()`, at
    /// which point `fetchWorkspaces` establishes a fresh stream.
    private func workspaceSubscriptionLost(key: String, path: String, error: Error) {
        guard hosts[key]?.activeSockPath == path,
              hosts[key]?.isConnected == true
        else { return }
        hosts[key]?.connectionState = .failed(Self.unreachableReason)
        hosts[key]?.clearAuthenticatedHostCLIBinDirs()
        TeamOrchestrator.shared.markRemoteAgentsUnreachable(
            hostKey: key,
            reason: Self.unreachableReason
        )
        RemoteWorkLog.info("Workspace roster stream stopped for \(hosts[key]?.displayName ?? key): \(error.localizedDescription)")
    }

    /// Keep sidebar pane details and busy state in lockstep with an open live
    /// mirror. The mirror already receives each host layout push, so reuse it
    /// instead of adding a second poll or RPC on the main actor.
    func recordLiveMirrorLayout(
        _ layout: Termmesh_Peer_V1_WorkspaceLayout,
        hostKey: PeerPaneHostKey,
        workspaceIDs: Set<Data>
    ) {
        guard let hostID = hosts.values.first(where: {
            $0.paneHostSpec.hostKey == hostKey
        })?.id,
        let index = hosts[hostID]?.workspaces.firstIndex(where: {
            workspaceIDs.contains($0.id)
        }),
        let current = hosts[hostID]?.workspaces[index]
        else { return }

        let counts = peerLayoutCounts(layout)
        hosts[hostID]?.workspaces[index] = WorkspaceSummary(
            id: current.id,
            title: current.title,
            hostSockPath: current.hostSockPath,
            windowID: current.windowID,
            windowTitle: current.windowTitle,
            isDefault: current.isDefault,
            paneCount: counts.panes,
            surfaceCount: counts.surfaces,
            busyCount: counts.busy,
            panes: peerPaneSummaries(layout)
        )
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
    /// `select: false` from the socket path — `peer.workspace.open_mirror` is
    /// not a focus-intent method, so it must not pull the user onto the new
    /// workspace. The sidebar keeps the default, because clicking there is
    /// explicit focus intent.
    func openWorkspaceAsMirror(
        _ workspace: WorkspaceSummary,
        host: HostEntry,
        live: Bool = true,
        select: Bool = true,
        alertOnFailure: Bool = true
    ) {
        let spec = host.paneHostSpec
        Task {
            await PeerClientCoordinator.shared.openRemoteWorkspaceMirror(
                spec: spec,
                workspaceID: workspace.id,
                live: live,
                select: select,
                alertOnFailure: alertOnFailure
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
            self.fetchWorkspaces(
                for: path, key: key,
                provenance: self.hosts[key]?.hostCLIBinDirsProvenance
            )
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
            self.fetchWorkspaces(
                for: path, key: key,
                provenance: self.hosts[key]?.hostCLIBinDirsProvenance
            )
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
            self.fetchWorkspaces(
                for: path, key: key,
                provenance: self.hosts[key]?.hostCLIBinDirsProvenance
            )
        }
    }
}
