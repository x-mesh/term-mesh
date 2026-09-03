import Foundation
import AppKit

/// The app's view of the daemon's mobile exposure registry.
///
/// `/rc on` and this store drive the same four RPCs (`remote.on`, `remote.off`,
/// `remote.status`, `remote.list`), so neither entry point can show a state the
/// other does not have. The daemon owns the registry; this only mirrors it.
///
/// It exists because the pane header needs to *draw* exposure state. That draw
/// happens inside a SwiftUI view body, where a blocking RPC would stall every
/// frame, so the header reads this and nothing else.
@MainActor
final class RemoteExposureStore: ObservableObject {
    /// One exposed surface, as the registry reports it.
    ///
    /// A subset of the daemon's `Entry`: the fields the app has any use for.
    /// `session_id` is `skip_serializing` on the daemon side and never arrives.
    struct Exposure: Equatable {
        let surfaceID: String
        let kind: String
        let title: String
        /// Unix seconds. The registry prunes on read, but a cached copy can
        /// outlive the entry it describes, so readers check this themselves.
        let expiresAt: TimeInterval
    }

    /// What a completed `remote.on` said about reachability.
    ///
    /// Registering an exposure and being able to reach it are separate things:
    /// with the listener disabled the entry is real and the phone cannot open
    /// it. The distinction is the daemon's to report, not the app's to infer.
    struct ExposureResult: Equatable {
        let surfaceID: String
        let url: String?
        let listenerEnabled: Bool
        let listenerError: String?

        var isReachable: Bool { listenerEnabled && url != nil }
    }

    enum ExposureError: Error, Equatable {
        /// The daemon did not answer, or answered something unparseable.
        case unavailable
        /// The daemon rejected the request; the string is its own message.
        case rejected(String)
    }

    @Published private(set) var exposures: [String: Exposure] = [:]
    /// Bumped on every published change, so a view that cannot observe the
    /// dictionary itself still has one value to depend on.
    @Published private(set) var revision: Int = 0

    /// The registry is one per daemon, so mirroring it once per app keeps
    /// every workspace's headers agreeing without N copies polling it.
    static let shared = RemoteExposureStore(daemon: TermMeshDaemon.shared)

    private let daemon: any DaemonService
    private let now: () -> Date
    private var refreshTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var mutationGeneration: UInt64 = 0
    private let pollNanoseconds: UInt64

    init(
        daemon: any DaemonService,
        now: @escaping () -> Date = Date.init,
        pollNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.daemon = daemon
        self.now = now
        self.pollNanoseconds = pollNanoseconds
    }

    // MARK: - Reading

    /// Whether this surface is exposed *and* has not expired.
    ///
    /// The expiry check is not redundant with the daemon's pruning. Pruning
    /// happens when the registry is read; between two refreshes this cache can
    /// name an entry the daemon would already have dropped, and drawing that as
    /// exposed would tell someone their pane is reachable when it is not.
    func isExposed(_ surfaceID: String) -> Bool {
        guard let exposure = exposures[surfaceID] else { return false }
        return exposure.expiresAt > now().timeIntervalSince1970
    }

    func exposure(_ surfaceID: String) -> Exposure? {
        isExposed(surfaceID) ? exposures[surfaceID] : nil
    }

    // MARK: - Refreshing

    /// Start the one app-wide monitor used by every Workspace header.
    /// Idempotent: workspace churn never adds another observer or poller.
    func startMonitoring() {
        guard pollingTask == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let pollNanoseconds = self.pollNanoseconds
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
        refresh()
    }

    /// Re-read the registry.
    ///
    /// Coalesced: a refresh already running is left to finish rather than
    /// stacking another blocking call behind it. Callers fire this on window
    /// focus and after a toggle, not on a tight timer.
    func refresh() {
        guard refreshTask == nil else { return }
        let generation = mutationGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let entries = await Self.list(daemon: self.daemon)
            self.refreshTask = nil
            guard let entries else { return }
            guard self.mutationGeneration == generation else { return }
            self.publish(entries)
        }
    }

    /// Expose a surface and adopt whatever the daemon says came of it.
    ///
    /// The reply is the source of truth for the stored entry — the app does not
    /// re-derive the expiry from its own clock and the TTL it asked for, because
    /// the daemon clamps TTL to 60s-7d and would silently disagree.
    @discardableResult
    func expose(_ spec: [String: Any]) async -> Result<ExposureResult, ExposureError> {
        guard let surfaceID = spec["surface_id"] as? String, !surfaceID.isEmpty else {
            return .failure(.rejected("missing surface_id"))
        }
        let daemon = self.daemon
        let raw = await Task.detached {
            daemon.rpcCallRaw(method: "remote.on", params: spec)
        }.value
        guard let object = Self.decode(raw) else { return .failure(.unavailable) }
        if let error = object["error"] as? String { return .failure(.rejected(error)) }
        mutationGeneration &+= 1
        if let entry = (object["entry"] as? [String: Any]).flatMap(Self.exposure(from:)) {
            exposures[entry.surfaceID] = entry
            revision &+= 1
            scheduleExpiry()
        }
        return .success(ExposureResult(
            surfaceID: surfaceID,
            url: object["url"] as? String,
            listenerEnabled: object["listener_enabled"] as? Bool ?? false,
            listenerError: object["listener_error"] as? String
        ))
    }

    @discardableResult
    func unexpose(_ surfaceID: String) async -> Result<Void, ExposureError> {
        let daemon = self.daemon
        let raw = await Task.detached {
            daemon.rpcCallRaw(method: "remote.off", params: ["surface_id": surfaceID])
        }.value
        guard let object = Self.decode(raw) else { return .failure(.unavailable) }
        if let error = object["error"] as? String { return .failure(.rejected(error)) }
        // Drop it locally whether or not the daemon had it: `removed: false`
        // means it was already gone, which is the state being asked for.
        mutationGeneration &+= 1
        if exposures.removeValue(forKey: surfaceID) != nil { revision &+= 1 }
        scheduleExpiry()
        return .success(())
    }

    // MARK: - Internals

    private func publish(_ entries: [Exposure]) {
        let cutoff = now().timeIntervalSince1970
        let live = entries.filter { $0.expiresAt > cutoff }
        let next = Dictionary(live.map { ($0.surfaceID, $0) }) { first, _ in first }
        guard next != exposures else { return }
        exposures = next
        revision &+= 1
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let earliest = exposures.values.map(\.expiresAt).min() else {
            expiryTask = nil
            return
        }
        let delay = max(earliest - now().timeIntervalSince1970, 0)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.expiryTask = nil
            self.pruneExpired()
        }
    }

    /// Internal seam used by the expiry task and deterministic tests.
    func pruneExpired() {
        let cutoff = now().timeIntervalSince1970
        let next = exposures.filter { $0.value.expiresAt > cutoff }
        guard next != exposures else {
            scheduleExpiry()
            return
        }
        exposures = next
        revision &+= 1
        scheduleExpiry()
    }

    #if DEBUG
    func stopMonitoringForTesting() {
        pollingTask?.cancel()
        pollingTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    var monitoringForTesting: Bool { pollingTask != nil }
    #endif

    private static func list(daemon: any DaemonService) async -> [Exposure]? {
        // `rpcCallRaw` blocks for up to its timeout. Off-main, always.
        let raw = await Task.detached {
            daemon.rpcCallRaw(method: "remote.list", params: [:])
        }.value
        guard let object = decode(raw) else { return nil }
        guard let rows = object["entries"] as? [[String: Any]] else { return [] }
        return rows.compactMap(exposure(from:))
    }

    private static func decode(_ raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func exposure(from row: [String: Any]) -> Exposure? {
        guard let surfaceID = row["surface_id"] as? String, !surfaceID.isEmpty else {
            return nil
        }
        // An entry with no expiry is not treated as eternal: the registry always
        // sets one, so its absence means this row is not one we understand.
        guard let expires = (row["expires_at"] as? NSNumber)?.doubleValue else { return nil }
        return Exposure(
            surfaceID: surfaceID,
            kind: row["kind"] as? String ?? "pane",
            title: row["title"] as? String ?? "",
            expiresAt: expires
        )
    }
}

// MARK: - Building the daemon's EnableSpec

extension RemoteExposureStore {
    /// What the app knows about a pane, reduced to what `EnableSpec` needs.
    ///
    /// A value type on purpose: building the spec is the part worth testing,
    /// and it should not need a Workspace, a TeamOrchestrator or a window.
    struct PaneIdentity: Equatable {
        let surfaceID: String
        let panelType: PanelType
        let title: String
        let cwd: String
        /// Set when this pane is a team's leader pane.
        var leaderTeamName: String?
        /// Set when this pane holds a team agent, native or terminal-backed.
        var agentTeamName: String?
        var agentName: String?
        var agentCLI: String = ""
    }

    /// How much the phone may send back to a terminal-backed pane.
    enum KeysPolicy: String, CaseIterable, Sendable {
        /// The fixed allowlist in docs/mobile-remote-control.md §6.
        case safe
        /// Read the screen, send nothing.
        case none
    }

    /// The daemon's `remote.on` parameters for this pane, or nil when the pane
    /// cannot be exposed at all.
    ///
    /// The kind comes from what the app holds — panel type and team membership
    /// — rather than from the environment variables `tm-agent` has to read,
    /// which is why an adopted leader needs no `--leader --team ws-<hex>` here.
    ///
    /// `chat_capable` is narrower from the app than from the CLI, and that is
    /// not an oversight. The CLI reads `CLAUDE_CODE_SESSION_ID` /
    /// `CODEX_THREAD_ID` out of its own process environment; the app clears
    /// exactly those variables when it builds a pane
    /// (`GhosttyTerminalView.removingInheritedCLISessionIdentity`) so each CLI
    /// starts its own session. A hand-run CLI's session id is therefore not
    /// the app's to know, and claiming chat for a pane whose transcript cannot
    /// be followed would show the phone an empty conversation. Such a pane is
    /// exposed as a terminal mirror; `/rc on` from inside it still offers Chat.
    static func enableSpec(
        for pane: PaneIdentity,
        appSocket: String,
        keys: KeysPolicy,
        ttlSeconds: Int?,
        owner: String?,
        leaderRequestToken: String? = nil
    ) -> [String: Any]? {
        guard !pane.surfaceID.isEmpty else { return nil }
        // A browser pane has no surface to mirror and no transcript to follow.
        guard pane.panelType != .browser else { return nil }

        let kind: String
        let chatCapable: Bool
        if pane.leaderTeamName != nil {
            kind = "leader"
            chatCapable = true
        } else if pane.panelType == .agent, pane.agentName != nil {
            kind = "agent"
            chatCapable = true
        } else {
            kind = "pane"
            chatCapable = false
        }

        var spec: [String: Any] = [
            "surface_id": pane.surfaceID,
            "kind": kind,
            "chat_capable": chatCapable,
            "agent_cli": pane.agentCLI,
            "title": pane.title,
            "cwd": pane.cwd,
            "app_socket": appSocket,
            "keys": keys.rawValue,
        ]
        // `kind = leader` needs the team whose request board receives the text,
        // and `kind = agent` needs team plus member. Carried whenever known, as
        // the CLI does, so a terminal-backed agent still names itself.
        if let team = pane.leaderTeamName ?? pane.agentTeamName {
            spec["team_name"] = team
        }
        if let agentName = pane.agentName {
            spec["agent_name"] = agentName
        }
        if let owner, !owner.isEmpty {
            spec["owner"] = owner
        }
        if let ttlSeconds {
            spec["ttl_secs"] = ttlSeconds
        }
        // Only a leader pane can spend it, and the daemon rejects a leader
        // target that cannot reach the request board.
        if kind == "leader", let leaderRequestToken, !leaderRequestToken.isEmpty {
            spec["leader_request_token"] = leaderRequestToken
        }
        return spec
    }
}
