import AppKit
import Bonsplit
import Foundation
import PeerProto

// An agent that runs on another machine, in a pane you can watch.
//
// The coordinator can already place a whole project's work on whichever host
// happens to have it, which is the right answer when any machine will do. It
// is the wrong answer when a specific one is the point: tests want the Mac,
// a build may want the Linux box, and a team is often both at once — a leader
// here and one member over there.
//
// That is a property of the member, not of the team, so it is attached one
// agent at a time. The pane is local: a peer surface is attached into this
// workspace, so `panelId` still addresses it and everything keyed on that —
// delegating, reading the reply off the scrollback, revealing it — works
// without knowing the agent is somewhere else.

/// What a reattach attempt established about the team's remote leader.
///
/// Three states rather than a `Bool`, because the two ways of not being
/// attached call for opposite repairs and a `Bool` cannot tell them apart. The
/// old code caught every transport failure and returned the same `false` an
/// authoritative absence returned, and the recovery path read any `false` as
/// permission to bootstrap — so a brief tunnel or list-RPC failure just after a
/// relay EOF minted a second leader beside a remote process that was still
/// running.
enum RemoteLeaderReattachOutcome: Equatable {
    /// The local viewer is on the surface the team already owns.
    case attached
    /// The host answered with its surface roster and the stored surface was not
    /// in it — or none was ever recorded. Authoritative: there is no live
    /// remote leader left for a replacement to duplicate.
    case confirmedMissing
    /// The surface is durable but its login shell is idle. This proves the
    /// recorded leader CLI is not in the foreground, but does not prove it is
    /// safe to mint a duplicate (it may be stopped/backgrounded). Keep the
    /// surface and require an explicit restart decision.
    case confirmedInactive
    /// Nothing was established and nothing was disproved. The surface may well
    /// still be there; whatever is stored for it must be kept.
    case temporarilyUnavailable

    /// The one state that may mint a second grant and a second surface.
    var permitsReplacementBootstrap: Bool {
        self == .confirmedMissing
    }
}

/// Durable tombstones for peer-owned agent surfaces that still need to be
/// terminated. The team roster cannot be that tombstone: detach/destroy removes
/// it immediately, and an agent surface appears in neither the workspace tree
/// nor `ManagedPeerSurfaceStore`.
@MainActor
final class PendingPeerAgentSurfaceCleanupStore {
    typealias HostSockPath = @MainActor (String) -> String?
    /// `(hostKey, servingSockPath, surfaceID)`.
    ///
    /// The host key rides along because the serving socket is not always where
    /// the surface is. A redirected host ensured it on its session owner, and a
    /// `TerminateSurface` sent to the socket that merely *served* the handshake
    /// names a surface that endpoint never created — the tombstone would then
    /// retry forever against a host that keeps answering "not mine" while the
    /// `tm-agent-bridge` it was meant to kill stays up.
    typealias Terminator = @MainActor (String, String, Data, String?) async -> Bool
    typealias Confirmation = @MainActor (String, Data) -> Void
    struct Record: Codable, Equatable, Identifiable {
        let hostKey: String
        let surfaceIDBase64: String
        let createdAt: Date
        /// The remote socket of the endpoint that actually created this
        /// surface, when it was not the serving one.
        ///
        /// The host's *current* `teamHostSpec` is the wrong thing to ask at
        /// termination time: a later handshake can move the route, and the
        /// surface does not move with it. Asking the new owner produces a
        /// `notFound` that is indistinguishable from a real confirmation, so
        /// the tombstone is dropped while the `tm-agent-bridge` keeps running
        /// on the endpoint that has it. Recording the creation endpoint is what
        /// makes the two answers tellable apart.
        ///
        /// Optional and decoded leniently: tombstones persisted by an earlier
        /// build have no such field, and must keep resolving by host key rather
        /// than being discarded — a dropped tombstone is a bridge that runs
        /// forever.
        var owningRemoteSockPath: String?

        var id: String { "\(hostKey)\u{0000}\(surfaceIDBase64)" }
        var surfaceID: Data? { Data(base64Encoded: surfaceIDBase64) }
    }

    static let shared = PendingPeerAgentSurfaceCleanupStore()
    private static let storageKey = "termmesh.pendingPeerAgentSurfaceCleanup"

    private let defaults: UserDefaults
    private var records: [Record]
    private var observer: NSObjectProtocol?
    private var retryTask: Task<Void, Never>?
    private var retryInFlight = false
    private let automaticRetryDelay: TimeInterval
    private let hostSockPathProvider: HostSockPath
    private let terminator: Terminator
    private let onConfirmed: Confirmation

    /// Cleanup only needs the authenticated transport that already backs the
    /// connected host row. CLI launch metadata is resolved by a later RPC and
    /// must not hold a termination tombstone hostage while that probe is
    /// pending or failed.
    nonisolated static func connectedHostSockPath(
        for hostKey: String,
        in hosts: [HostEntry]
    ) -> String? {
        guard let host = hosts.first(where: { $0.id == hostKey }),
              host.isConnected,
              !host.activeSockPath.isEmpty
        else { return nil }
        return host.activeSockPath
    }

    init(
        defaults: UserDefaults = .standard,
        observeNotifications: Bool = true,
        automaticRetryDelay: TimeInterval = 30,
        hostSockPathProvider: @escaping HostSockPath = { hostKey in
            PendingPeerAgentSurfaceCleanupStore.connectedHostSockPath(
                for: hostKey,
                in: RemoteHostStore.shared.sortedHosts
            )
        },
        terminator: @escaping Terminator = { hostKey, sockPath, surfaceID, owningRemoteSockPath in
            await TeamOrchestrator.terminatePeerAgentSurfaceOnOwningEndpoint(
                hostKey: hostKey,
                servingSockPath: sockPath,
                surfaceID: surfaceID,
                owningRemoteSockPath: owningRemoteSockPath
            )
        },
        onConfirmed: @escaping Confirmation = { hostKey, surfaceID in
            ManagedPeerSurfaceStore.shared.forget(
                hostKey: hostKey, surfaceID: surfaceID
            )
        }
    ) {
        self.defaults = defaults
        self.automaticRetryDelay = automaticRetryDelay
        self.hostSockPathProvider = hostSockPathProvider
        self.terminator = terminator
        self.onConfirmed = onConfirmed
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            records = decoded
        } else {
            records = []
        }
        if observeNotifications {
            observer = NotificationCenter.default.addObserver(
                forName: PeerClientCoordinator.relaysDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    PendingPeerAgentSurfaceCleanupStore.shared.scheduleRetry()
                }
            }
            // Covers records restored after an app restart when the host is
            // already connected and therefore emits no new relay transition.
            Task { @MainActor [weak self] in self?.scheduleRetry() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var pendingRecords: [Record] { records }

    func enqueue(hostKey: String, surfaceID: Data, owningRemoteSockPath: String? = nil) {
        guard !hostKey.isEmpty, !surfaceID.isEmpty else { return }
        let encoded = surfaceID.base64EncodedString()
        let owner = (owningRemoteSockPath?.isEmpty ?? true) ? nil : owningRemoteSockPath
        if let existing = records.firstIndex(where: {
            $0.hostKey == hostKey && $0.surfaceIDBase64 == encoded
        }) {
            // Already recorded, but a later caller may know the endpoint the
            // first one did not. Ambiguity carried forever is the thing to
            // avoid: a nil endpoint resolves by the host's current route, which
            // is exactly the wrong-owner guess these records exist to prevent.
            // Never the reverse — a known endpoint is not downgraded to nil.
            guard let owner,
                  records[existing].owningRemoteSockPath == nil
            else { return }
            records[existing].owningRemoteSockPath = owner
            persist()
            return
        }
        records.append(Record(
            hostKey: hostKey,
            surfaceIDBase64: encoded,
            createdAt: Date(),
            owningRemoteSockPath: owner
        ))
        persist()
    }

    func scheduleRetry() {
        retryTask?.cancel()
        retryTask = nil
        guard !retryInFlight, !records.isEmpty else { return }
        retryInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await retryPending(
                hostSockPath: hostSockPathProvider,
                terminate: terminator
            )
            retryInFlight = false
            scheduleSlowRetryIfNeeded()
        }
    }

    private func scheduleSlowRetryIfNeeded() {
        guard retryTask == nil, !records.isEmpty else { return }
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(max(0, automaticRetryDelay) * 1_000_000_000)
            if nanoseconds > 0 { try? await Task.sleep(nanoseconds: nanoseconds) }
            guard !Task.isCancelled else { return }
            retryTask = nil
            scheduleRetry()
        }
    }

    /// One pass only. Failed/unreachable records remain durable and the next
    /// relay transition starts another pass.
    func retryPending(
        hostSockPath: (String) -> String?,
        terminate: (String, String, Data, String?) async -> Bool
    ) async {
        let snapshot = records
        for record in snapshot {
            guard let surfaceID = record.surfaceID,
                  let sockPath = hostSockPath(record.hostKey),
                  !sockPath.isEmpty,
                  await terminate(
                      record.hostKey,
                      sockPath,
                      surfaceID,
                      record.owningRemoteSockPath
                  )
            else { continue }
            // Spend only the record this pass actually terminated. While the
            // await above was in flight, `enqueue` may have enriched the live
            // record with the exact owning endpoint this snapshot did not
            // have — and a nil-owner attempt resolves by the host's current
            // route, whose `notFound` is indistinguishable from success.
            // Dropping the enriched record on that answer would orphan the
            // bridge on the endpoint that has it; leaving it costs one
            // idempotent extra attempt on the next pass.
            records.removeAll {
                $0.id == record.id
                    && $0.owningRemoteSockPath == record.owningRemoteSockPath
            }
            onConfirmed(record.hostKey, surfaceID)
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

@MainActor
final class PeerAgentPaneRecoveryCoordinator {
    typealias RetryAction = @MainActor () async -> Void
    struct Request: Equatable {
        let teamName: String
        let agentInstanceID: String
        let closedPanelID: UUID
        let surfaceID: Data

        var key: String { "\(teamName)/\(agentInstanceID)" }
    }

    static let shared = PeerAgentPaneRecoveryCoordinator()
    private var requests: [String: Request] = [:]
    private var observer: NSObjectProtocol?
    private var retryTask: Task<Void, Never>?
    private var retryInFlight = false
    private let automaticRetryDelay: TimeInterval
    private let retryAction: RetryAction

    init(
        observeNotifications: Bool = true,
        automaticRetryDelay: TimeInterval = 30,
        retryAction: @escaping RetryAction = {
            await TeamOrchestrator.shared.retryPendingPeerAgentPaneRecoveries()
        }
    ) {
        self.automaticRetryDelay = automaticRetryDelay
        self.retryAction = retryAction
        if observeNotifications {
            observer = NotificationCenter.default.addObserver(
                forName: PeerClientCoordinator.relaysDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    PeerAgentPaneRecoveryCoordinator.shared.retryNow()
                }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var pending: [Request] { Array(requests.values) }
    func remember(_ request: Request) { requests[request.key] = request }
    func forget(_ request: Request) {
        guard requests[request.key] == request else { return }
        requests.removeValue(forKey: request.key)
        if requests.isEmpty {
            retryTask?.cancel()
            retryTask = nil
        }
    }

    func retryNow() {
        retryTask?.cancel()
        retryTask = nil
        guard !requests.isEmpty else { return }
        runRetryAction()
    }

    func scheduleRetryIfNeeded() {
        guard retryTask == nil, !requests.isEmpty else { return }
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(max(0, automaticRetryDelay) * 1_000_000_000)
            if nanoseconds > 0 { try? await Task.sleep(nanoseconds: nanoseconds) }
            guard !Task.isCancelled else { return }
            retryTask = nil
            runRetryAction()
        }
    }

    private func runRetryAction() {
        guard !retryInFlight, !requests.isEmpty else { return }
        retryInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await retryAction()
            retryInFlight = false
            scheduleRetryIfNeeded()
        }
    }
}

extension TeamOrchestrator {
    struct ExactRepairIdentity: Equatable {
        let hostKey: String
        let teamUUID: String
        let projectID: String
    }

    struct RemoteRepairPlaceholderGeneration: Equatable {
        let hostKey: String
        let teamUUID: String
        let projectID: String
        let workspaceID: UUID
        let leaderPanelID: UUID
        let revision: UInt64
        let createdAt: Date
        let memberInstanceIDs: [String]
        let memberSurfaceIDs: [Data?]
    }

    enum ExactRepairInput: Equatable {
        case omitted
        case valid(ExactRepairIdentity)
        case invalid
    }

    nonisolated static func exactRepairInput(
        params: [String: Any]
    ) -> ExactRepairInput {
        let keys = ["host_key", "team_uuid", "project_id"]
        guard keys.contains(where: params.keys.contains) else { return .omitted }
        guard let hostKey = params["host_key"] as? String, !hostKey.isEmpty,
              let teamUUID = params["team_uuid"] as? String, !teamUUID.isEmpty,
              let projectID = params["project_id"] as? String, !projectID.isEmpty
        else { return .invalid }
        return .valid(.init(
            hostKey: hostKey, teamUUID: teamUUID, projectID: projectID
        ))
    }

    enum CollaborationLeaderRepairDecision: Equatable {
        case keepExisting
        case bootstrapReplacement
        case deferUntilAuthoritative
    }

    struct CollaborationLeaderLaunchMetadata: Equatable {
        let cli: String
        let model: String
    }

    struct CollaborationRecoveryPlan: Equatable {
        let leaderLive: Bool
        let deadAgentInstanceIDs: [String]
        let liveAgentCount: Int
    }

    /// Decide from one authoritative host snapshot, never from the local pane.
    /// A pane can retain `relayStarted` after its remote process has exited, so
    /// using it here would make Repair preserve exactly the stale leader it is
    /// meant to replace. Unknown process state remains conservative: creating
    /// a second leader is worse than asking the user to retry the read.
    nonisolated static func collaborationLeaderRepairDecision(
        remoteTeam: RemoteTeamSummary?,
        surfaces: [Termmesh_Peer_V1_SurfaceInfo],
        localLeaderRelayStarted _: Bool = false
    ) -> CollaborationLeaderRepairDecision {
        guard let remoteTeam else { return .deferUntilAuthoritative }
        let surfaceID = remoteTeam.leaderSurfaceID
        guard !surfaceID.isEmpty,
              let surface = surfaces.first(where: { $0.surfaceID == surfaceID }) else {
            return .bootstrapReplacement
        }
        if remoteTeam.leaderProcessActiveKnown {
            return remoteTeam.leaderProcessActive
                ? .keepExisting : .bootstrapReplacement
        }
        if surface.foregroundBusyKnown {
            return surface.foregroundBusy
                ? .keepExisting : .bootstrapReplacement
        }
        return .deferUntilAuthoritative
    }

    /// Adopted is a local presentation state, not an executable. New protocol
    /// fields preserve the owner's actual launch choice. Legacy manifests have
    /// no such metadata, so use the explicit New Project default rather than
    /// ever trying to execute `adopted`.
    nonisolated static func collaborationLeaderLaunchMetadata(
        remoteCLI: String,
        remoteModel: String
    ) -> CollaborationLeaderLaunchMetadata {
        let cli = remoteCLI.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = remoteModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cli.isEmpty, cli.lowercased() != "adopted", !model.isEmpty else {
            return CollaborationLeaderLaunchMetadata(cli: "claude", model: "opus")
        }
        return CollaborationLeaderLaunchMetadata(cli: cli, model: model)
    }

    /// After a replacement starts, the durable manifest may still name the
    /// old leader until its debounced publication lands. Confirm the newly
    /// managed identity directly against the fresh surface roster instead of
    /// falsely failing on that expected persistence lag.
    nonisolated static func confirmedReplacementLeaderSurfaceID(
        manifestLeaderSurfaceID _: Data,
        managedLeaderSurfaceID: Data?,
        surfaces: [Termmesh_Peer_V1_SurfaceInfo]
    ) -> Data? {
        guard let managedLeaderSurfaceID, !managedLeaderSurfaceID.isEmpty,
              let surface = surfaces.first(where: {
                  $0.surfaceID == managedLeaderSurfaceID
              }),
              surface.foregroundBusyKnown, surface.foregroundBusy else {
            return nil
        }
        return managedLeaderSurfaceID
    }

    nonisolated static func recoverableManagedLeaderSurfaceID(
        manifestLeaderSurfaceID: Data,
        managedRecords: [ManagedPeerSurfaceStore.Record],
        teamName: String,
        teamUUID: String,
        projectID: String?,
        workingDirectory: String,
        surfaces: [Termmesh_Peer_V1_SurfaceInfo]
    ) -> Data? {
        let live = managedRecords.compactMap { record -> Data? in
            guard record.teamName == teamName, record.role == "leader",
                  record.workingDirectory == workingDirectory,
                  record.teamUUID == teamUUID,
                  record.projectID == projectID,
                  let surfaceID = record.surfaceID,
                  surfaceID != manifestLeaderSurfaceID,
                  let surface = surfaces.first(where: { $0.surfaceID == surfaceID }),
                  surface.attachable, surface.foregroundBusyKnown, surface.foregroundBusy
            else { return nil }
            return surfaceID
        }
        let unique = Set(live)
        return unique.count == 1 ? unique.first : nil
    }

    nonisolated static func legacyManagedLeaderCandidateSurfaceID(
        manifestLeaderSurfaceID: Data,
        managedRecords: [ManagedPeerSurfaceStore.Record],
        teamName: String,
        workingDirectory: String,
        surfaces: [Termmesh_Peer_V1_SurfaceInfo]
    ) -> Data? {
        let live = managedRecords.compactMap { record -> Data? in
            guard record.teamName == teamName, record.role == "leader",
                  record.workingDirectory == workingDirectory,
                  record.teamUUID == nil, record.projectID == nil,
                  let surfaceID = record.surfaceID, surfaceID != manifestLeaderSurfaceID,
                  let surface = surfaces.first(where: { $0.surfaceID == surfaceID }),
                  surface.attachable, surface.foregroundBusyKnown, surface.foregroundBusy
            else { return nil }
            return surfaceID
        }
        let unique = Set(live)
        return unique.count == 1 ? unique.first : nil
    }

    static func legacyManagedLeaderIdentityProofScript() -> String {
        // Snapshot before reading the identity tokens or spawning any matcher.
        // Therefore neither this verifier nor its later ps/grep children can
        // appear in the candidate PID set.
        let body = "self=$$; snapshot=$(ps -axo pid=,ppid=,pgid= 2>/dev/null) || exit 75; "
            + "IFS= read -r surface || exit 76; IFS= read -r team || exit 76; "
            + "ancestors=\" $self \"; current=$self; "
            + "while :; do parent=$(printf '%s\\n' \"$snapshot\" | awk -v p=\"$current\" '$1 == p { print $2; exit }'); "
            + "case \"$parent\" in ''|0|1) break;; esac; ancestors=\"$ancestors$parent \"; current=$parent; done; "
            + "groups=' '; for pid in $(printf '%s\\n' \"$snapshot\" | awk '{ print $1 }'); do "
            + "case \"$ancestors\" in *\" $pid \"*) continue;; esac; "
            + "pgid=$(printf '%s\\n' \"$snapshot\" | awk -v p=\"$pid\" '$1 == p { print $3; exit }'); [ -n \"$pgid\" ] || continue; "
            + "matched=0; if [ -r \"/proc/$pid/environ\" ]; then "
            + "envlines=$(tr '\\000' '\\n' < \"/proc/$pid/environ\" 2>/dev/null || true); "
            + "printf '%s\\n' \"$envlines\" | grep -Fqx -- \"$surface\" && printf '%s\\n' \"$envlines\" | grep -Fqx -- \"$team\" && matched=1; "
            + "else line=$(ps eww -p \"$pid\" -o command= 2>/dev/null || true); "
            + "case \" $line \" in *\" $surface \"*) case \" $line \" in *\" $team \"*) matched=1;; esac;; esac; fi; "
            + "[ \"$matched\" -eq 1 ] || continue; case \"$groups\" in *\" $pgid \"*) ;; *) groups=\"$groups$pgid \";; esac; done; "
            + "count=$(printf '%s\\n' \"$groups\" | awk '{ print NF }'); [ \"$count\" -eq 1 ] && printf '1\\n' || printf '0\\n'"
        return RemotePasteTransfer.serviceAccountCommand(body)
    }

    nonisolated static func legacyManagedLeaderIdentityProofInput(
        surfaceID: Data, teamUUID: String
    ) -> Data {
        let surfaceHex = surfaceID.map { String(format: "%02x", $0) }.joined()
        return Data(
            "TERMMESH_SURFACE_ID=\(surfaceHex)\n"
                .appending("TERMMESH_LEADER_TEAM_UUID=\(teamUUID)\n").utf8
        )
    }

    static func verifyLegacyManagedLeaderIdentity(
        host: HostEntry, surfaceID: Data, teamUUID: String
    ) async -> Bool {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return false }
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget, port: host.sshPort,
                identityFile: host.identityFile,
                script: legacyManagedLeaderIdentityProofScript(),
                standardInput: legacyManagedLeaderIdentityProofInput(
                    surfaceID: surfaceID, teamUUID: teamUUID
                ),
                timeoutSeconds: 20
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        } catch {
            return false
        }
    }

    nonisolated static func exactCollaborationRemoteTeam(
        in teams: [RemoteTeamSummary],
        teamUUID: String,
        projectID: String?
    ) -> RemoteTeamSummary? {
        let matches = teams.filter { remote in
            guard remote.teamUUID == teamUUID else { return false }
            guard let projectID, !projectID.isEmpty else { return true }
            return remote.projectID == projectID
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private typealias AuthoritativeCollaborationSnapshot = (
        surfaces: [Termmesh_Peer_V1_SurfaceInfo], team: RemoteTeamSummary
    )

    private enum AuthoritativeCollaborationSnapshotResult {
        case success(AuthoritativeCollaborationSnapshot)
        case failure(String)
    }

    @MainActor
    private func authoritativeCollaborationSnapshot(
        host: HostEntry,
        teamUUID: String,
        projectID: String?
    ) async -> AuthoritativeCollaborationSnapshotResult {
        let lease: PeerPaneHostLease
        do {
            if let current = RemoteHostStore.shared.sortedHosts.first(where: {
                $0.id == host.id
            }), !Self.teamHostCanLaunch(current) {
                // A daemon restart can let the retired connection's failure
                // callback land after a fresh row briefly reported ready.
                // Repair owns route recovery, so start one fresh generation
                // before waiting on the ordinary bounded readiness funnel.
                _ = RemoteHostStore.shared.retryConnectingHost(current)
            }
            let readyHost = try await Self.waitForTeamHostLaunchReadiness(
                hostKey: host.id
            )
            let spec = try Self.requireTeamHostSpec(readyHost)
            lease = try await PeerPaneHostRegistry.shared.acquire(spec)
        } catch {
            return .failure("Host connection unavailable: \(error.localizedDescription)")
        }
        defer { PeerPaneHostRegistry.shared.release(lease) }
        let snapshot: (
            surfaces: [Termmesh_Peer_V1_SurfaceInfo],
            teams: [Termmesh_Peer_V1_Team]
        )
        do {
            snapshot = try await PeerPaneSession.listSessionHostSnapshot(on: lease)
        } catch {
            return .failure("Host roster request failed: \(error.localizedDescription)")
        }
        let teams = snapshot.teams.map(RemoteHostStore.remoteTeamSummary)
        guard let team = Self.exactCollaborationRemoteTeam(
            in: teams, teamUUID: teamUUID, projectID: projectID
        ) else {
            return .failure(
                "Exact Project roster unavailable: expected team \(teamUUID) "
                    + "project \(projectID ?? "<legacy>"); received \(teams.count) Project(s)"
            )
        }
        return .success((snapshot.surfaces, team))
    }

    struct CollaborationRouteGeneration: Equatable {
        let teamUUID: String?
        let workspaceID: UUID
        let leaderPanelID: UUID
        let agents: [String]
    }

    static func collaborationRouteGeneration(_ team: Team) -> CollaborationRouteGeneration {
        CollaborationRouteGeneration(
            teamUUID: team.teamUuid,
            workspaceID: team.workspaceId,
            leaderPanelID: team.leaderPanelId,
            agents: team.agents.map { agent in
                let panel = agent.panelId?.uuidString ?? "-"
                let surface = agent.remoteSurfaceID?.map {
                    String(format: "%02x", $0)
                }.joined() ?? "-"
                return "\(agent.agentInstanceId)|\(panel)|\(surface)"
            }.sorted()
        )
    }

    nonisolated static func collaborationRecoveryPlan(
        leaderSurfaceID: Data?,
        agents: [AgentMember],
        surfaces: [Termmesh_Peer_V1_SurfaceInfo]
    ) -> CollaborationRecoveryPlan {
        // The roster is remote input. Two rows sharing a surface id — the
        // protobuf default empty Data included — would trap
        // `Dictionary(uniqueKeysWithValues:)` and take the app down inside a
        // recovery path. Keep the first row and carry on.
        let byID = Dictionary(surfaces.map { ($0.surfaceID, $0) }) { first, _ in first }
        let leaderLive = leaderSurfaceID.flatMap { byID[$0] }.map {
            $0.attachable && (!$0.foregroundBusyKnown || $0.foregroundBusy)
        } == true
        let remoteAgents = agents.filter { $0.remoteAgentSurface }
        let dead = remoteAgents.compactMap { agent -> String? in
            guard let surfaceID = agent.remoteSurfaceID,
                  byID[surfaceID]?.attachable == true else {
                return agent.agentInstanceId
            }
            return nil
        }
        return CollaborationRecoveryPlan(
            leaderLive: leaderLive,
            deadAgentInstanceIDs: dead,
            liveAgentCount: remoteAgents.count - dead.count
        )
    }

    /// Restore the local viewer shape before changing any grants. A route-only
    /// repair makes roster calls work while native delivery still has nowhere
    /// to land, which is the split-brain this action exists to remove.
    @MainActor
    private func ensureCollaborationPresentation(
        teamName: String,
        repairableMissingAgentIDs: Set<String>
    ) async -> Bool {
        if teams[teamName]?.isRemoteRepairPlaceholder == true {
            await attachRemoteRepairPlaceholderWorkers(
                teamName: teamName,
                repairableMissingAgentIDs: repairableMissingAgentIDs
            )
        }
        if collaborationPresentationState(
            teamName: teamName,
            requireLiveSessions: false,
            repairableMissingAgentIDs: repairableMissingAgentIDs
        ) == .ready {
            return true
        }
        guard let tabManager = AppDelegate.shared?.tabManager else { return false }
        _ = await restoreDetachedProjectPresentation(
            teamName: teamName,
            tabManager: tabManager
        )
        return collaborationPresentationState(
            teamName: teamName,
            requireLiveSessions: false,
            repairableMissingAgentIDs: repairableMissingAgentIDs
        ) == .ready
    }

    /// Explicit Repair has already replaced the dead leader. Reattach each
    /// surviving persisted worker into that new workspace before refreshing
    /// routes; known-dead workers stay panel-less for the replacement phase.
    @MainActor
    private func attachRemoteRepairPlaceholderWorkers(
        teamName: String,
        repairableMissingAgentIDs: Set<String>
    ) async {
        guard let team = teams[teamName], team.isRemoteRepairPlaceholder,
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId })
        else { return }
        for agent in team.agents where agent.panelId == nil
            && !repairableMissingAgentIDs.contains(agent.agentInstanceId) {
            guard let hostKey = agent.hostKey, let surfaceID = agent.remoteSurfaceID else { continue }
            let owningEndpoint = RestoredSurfaceEndpoint()
            guard let panelID = await attachRestoredRemoteSurface(
                hostKey: hostKey,
                surfaceID: surfaceID,
                title: agent.name,
                panelTitle: "\(Self.colorEmoji(agent.color)) \(agent.name)",
                workspace: workspace,
                owningRemoteSockPath: owningEndpoint,
                onAgentPanel: { panel, host in
                    Self.bindPeerOwnedAgentPanel(
                        panel: panel,
                        workspace: workspace,
                        teamName: teamName,
                        agentName: agent.name,
                        agentInstanceId: agent.agentInstanceId,
                        color: agent.color,
                        hostDisplayName: host.displayName
                    )
                }
            ) else { continue }
            guard var current = teams[teamName],
                  let index = current.agents.firstIndex(where: {
                      $0.agentInstanceId == agent.agentInstanceId
                  }) else { continue }
            current.agents[index].panelId = panelID
            current.agents[index].remoteSurfaceOwnerRemoteSockPath =
                owningEndpoint.remoteSockPath
            teams[teamName] = current
        }
        finishRemoteRepairPlaceholderMaterialization(teamName: teamName)
    }

    /// The inert-install publication guard must end at the same boundary as
    /// materialization. Leader recovery can request publication earlier while
    /// the flag is still true; explicitly rescheduling here ensures the new
    /// leader and worker topology becomes the durable remote manifest.
    @MainActor
    func finishRemoteRepairPlaceholderMaterialization(teamName: String) {
        guard var current = teams[teamName], current.isRemoteRepairPlaceholder else {
            return
        }
        current.isRemoteRepairPlaceholder = false
        teams[teamName] = current
        syncTeamStateToDaemon()
        if case .peer(let hostKey) = current.leaderEndpoint {
            scheduleRemoteProjectManifestPublication(forHostKey: hostKey)
        }
    }

    /// Respawn a peer-owned member whose durable roster entry survived but
    /// whose local pane did not. The leader pane is the stable insertion
    /// anchor; unlike the ordinary hard-restart path there is no old local tab
    /// to close after the replacement commits.
    @MainActor
    private func replaceMissingPeerOwnedAgentPane(
        teamName: String,
        agentInstanceID: String
    ) async -> Bool {
        guard let team = teams[teamName],
              let agent = team.agents.first(where: {
                  $0.agentInstanceId == agentInstanceID && $0.remoteAgentSurface
              }),
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }),
              workspace.panels[team.leaderPanelId] != nil
        else { return false }

        let result = await restartPeerOwnedAgentPaneHard(
            team: team,
            agent: agent,
            workspace: workspace,
            splitFrom: (team.leaderPanelId, .horizontal, false)
        )
        guard case .success(let replacement) = result else { return false }
        guard commitPeerOwnedAgentReplacement(
                  teamName: teamName,
                  expected: agent,
                  replacement: replacement.member
              ) else {
            discardPeerOwnedAgentRestart(replacement, workspace: workspace)
            return false
        }
        guard await activatePeerOwnedAgentRestart(
            replacement,
            teamName: teamName,
            agentInstanceID: agent.agentInstanceId
        ) else {
            _ = commitPeerOwnedAgentReplacement(
                teamName: teamName, expected: replacement.member, replacement: agent
            )
            discardPeerOwnedAgentRestart(replacement, workspace: workspace)
            return false
        }
        Self.releasePeerOwnedAgentSurface(agent)
        scheduleAgentGridEqualization(workspace: workspace)
        return true
    }

    /// Materialize the inert owner placeholder only after an explicit Repair
    /// action and an authoritative dead-leader decision. Automatic restore
    /// itself never spawns, attaches, or focuses a surface.
    @MainActor
    private func materializeRemoteRepairPlaceholder(teamName: String) -> Bool {
        guard var team = teams[teamName], team.isRemoteRepairPlaceholder,
              let tabManager = AppDelegate.shared?.tabManager
        else { return teams[teamName]?.isRemoteRepairPlaceholder == false }
        let workspace = tabManager.addWorkspace(
            workingDirectory: team.workingDirectory,
            select: false
        )
        workspace.customTitle = "[\(teamName)]"
        workspace.title = "[\(teamName)]"
        team.workspaceId = workspace.id
        guard let anchorPanelID = workspace.focusedPanelId else {
            tabManager.closeWorkspace(workspace)
            return false
        }
        team.leaderPanelId = anchorPanelID
        for index in team.agents.indices {
            team.agents[index].workspaceId = workspace.id
        }
        teams[teamName] = team
        WorkspaceProjectNames.shared.declare(
            workspaceId: workspace.id,
            projectName: teamName,
            projectID: team.remotePresentationProjectID
        )
        return true
    }

    /// Explicit repair is the one background flow that must realize its new
    /// leader pane immediately: unlike passive restore, it waits for that
    /// pane's prompt before it can report success. The caller owns only a pin
    /// it acquired itself; releasing somebody else's pin could unmount the
    /// workspace while that operation is still realizing another surface.
    /// The realization pin belongs to one replacement, not merely to a
    /// workspace that now happens to contain some terminal. This keeps the pin
    /// until the team points at the panel we inspected and that exact panel's
    /// relay has completed its accept/start path.
    nonisolated static func remoteRepairLeaderIsReadyToUnpin(
        teamLeaderPanelID: UUID?,
        inspectedPanelID: UUID?,
        relayStarted: Bool
    ) -> Bool {
        guard let teamLeaderPanelID, let inspectedPanelID else { return false }
        return teamLeaderPanelID == inspectedPanelID && relayStarted
    }

    @MainActor
    func repairCollaboration(
        teamName: String, exactIdentity: ExactRepairIdentity? = nil
    ) async -> CollaborationRecoveryReport {
        guard collaborationRepairInFlight.insert(teamName).inserted else {
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Collaboration repair already in progress"]
            )
        }
        defer { collaborationRepairInFlight.remove(teamName) }
        if let exactIdentity {
            if let localTeam = teams[teamName] {
                if !Self.exactRepairIdentityMatches(
                    team: localTeam, hostKey: exactIdentity.hostKey,
                    teamUUID: exactIdentity.teamUUID,
                    projectID: exactIdentity.projectID
                ) {
                    guard let expected = inertRemoteRepairPlaceholderGeneration(
                        teamName: teamName
                    ) else {
                        return CollaborationRecoveryReport(
                            routeRepaired: false, leaderLive: false, liveAgents: 0,
                            replacedAgents: [], failedAgents: [
                                "Local Project does not match the exact repair identity"
                            ]
                        )
                    }
                    if let failure = await installExactRemoteProjectRepairPlaceholder(
                        teamName: teamName, hostKey: exactIdentity.hostKey,
                        teamUUID: exactIdentity.teamUUID,
                        projectID: exactIdentity.projectID,
                        replacing: expected
                    ) {
                        return CollaborationRecoveryReport(
                            routeRepaired: false, leaderLive: false, liveAgents: 0,
                            replacedAgents: [], failedAgents: [failure]
                        )
                    }
                }
            } else if let failure = await installExactRemoteProjectRepairPlaceholder(
                teamName: teamName, hostKey: exactIdentity.hostKey,
                teamUUID: exactIdentity.teamUUID, projectID: exactIdentity.projectID
            ) {
                return CollaborationRecoveryReport(
                    routeRepaired: false, leaderLive: false, liveAgents: 0,
                    replacedAgents: [], failedAgents: [failure]
                )
            }
            guard let installed = teams[teamName],
                  Self.exactRepairIdentityMatches(
                    team: installed, hostKey: exactIdentity.hostKey,
                    teamUUID: exactIdentity.teamUUID,
                    projectID: exactIdentity.projectID
                  ) else {
                return CollaborationRecoveryReport(
                    routeRepaired: false, leaderLive: false, liveAgents: 0,
                    replacedAgents: [], failedAgents: [
                        "Exact Project identity changed before repair"
                    ]
                )
            }
        }
        guard let initial = teams[teamName],
              let teamUUID = initial.teamUuid,
              case let .peer(hostKey) = initial.leaderEndpoint,
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey })
        else {
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Project route unavailable"]
            )
        }

        var snapshotResult = await authoritativeCollaborationSnapshot(
            host: host,
            teamUUID: teamUUID,
            projectID: initial.remotePresentationProjectID
        )
        guard case .success(let firstSnapshot) = snapshotResult else {
            let reason: String
            if case .failure(let message) = snapshotResult { reason = message }
            else { reason = "Host roster unavailable" }
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: [reason]
            )
        }
        var authoritative = firstSnapshot
        let leaderDecision = Self.collaborationLeaderRepairDecision(
            remoteTeam: authoritative.team,
            surfaces: authoritative.surfaces,
            localLeaderRelayStarted: initial.leaderReady
        )
        var recoverableManagedLeaderSurfaceID: Data? = leaderDecision == .bootstrapReplacement
            ? Self.recoverableManagedLeaderSurfaceID(
                manifestLeaderSurfaceID: authoritative.team.leaderSurfaceID,
                managedRecords: ManagedPeerSurfaceStore.shared.records(hostKey: hostKey),
                teamName: teamName, teamUUID: teamUUID,
                projectID: initial.remotePresentationProjectID,
                workingDirectory: authoritative.team.workingDirectory,
                surfaces: authoritative.surfaces
            ) : nil
        if recoverableManagedLeaderSurfaceID == nil,
           leaderDecision == .bootstrapReplacement,
           let projectID = initial.remotePresentationProjectID,
           let legacySurfaceID = Self.legacyManagedLeaderCandidateSurfaceID(
               manifestLeaderSurfaceID: authoritative.team.leaderSurfaceID,
               managedRecords: ManagedPeerSurfaceStore.shared.records(hostKey: hostKey),
               teamName: teamName,
               workingDirectory: authoritative.team.workingDirectory,
               surfaces: authoritative.surfaces
           ),
           await Self.verifyLegacyManagedLeaderIdentity(
               host: host, surfaceID: legacySurfaceID, teamUUID: teamUUID
           ) {
            ManagedPeerSurfaceStore.shared.remember(
                hostKey: hostKey, surfaceID: legacySurfaceID,
                teamName: teamName, role: "leader",
                workingDirectory: authoritative.team.workingDirectory,
                teamUUID: teamUUID, projectID: projectID
            )
            recoverableManagedLeaderSurfaceID = legacySurfaceID
        }
        if let recoverableManagedLeaderSurfaceID {
            let launch = Self.collaborationLeaderLaunchMetadata(
                remoteCLI: authoritative.team.leaderCLI,
                remoteModel: authoritative.team.leaderModel
            )
            guard materializeRemoteRepairPlaceholder(teamName: teamName),
                  let repairTeam = teams[teamName],
                  let repairTabManager = AppDelegate.shared?.tabManagerFor(
                      tabId: repairTeam.workspaceId
                  ) else {
                return CollaborationRecoveryReport(
                    routeRepaired: false, leaderLive: false, liveAgents: 0,
                    replacedAgents: [], failedAgents: ["Repair presentation unavailable"]
                )
            }
            repairTabManager.pinWorkspaceForSurfaceRealization(repairTeam.workspaceId)
            defer {
                repairTabManager.unpinWorkspaceForSurfaceRealization(repairTeam.workspaceId)
            }
            guard case .attached = await reattachRemoteLeaderIfNeeded(
                teamName: teamName, expectedSurfaceID: recoverableManagedLeaderSurfaceID
            ) else {
                return CollaborationRecoveryReport(
                    routeRepaired: false, leaderLive: false, liveAgents: 0,
                    replacedAgents: [],
                    failedAgents: ["Managed replacement leader could not be reattached"]
                )
            }
            let relayDeadline = Date().addingTimeInterval(30)
            while Date() < relayDeadline {
                let panelID = teams[teamName]?.leaderPanelId
                let started = panelID.flatMap { panelID in
                    repairTabManager.tabs.first(where: {
                        $0.id == repairTeam.workspaceId
                    })?.terminalPanel(for: panelID)?.peerPaneSession?.isRelayStarted
                } == true
                if started { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let repairedPanelID = teams[teamName]?.leaderPanelId,
                  let repairedWorkspace = repairTabManager.tabs.first(where: {
                      $0.id == repairTeam.workspaceId
                  }),
                  let repairedSession = repairedWorkspace.terminalPanel(
                      for: repairedPanelID
                  )?.peerPaneSession,
                  repairedSession.isRelayStarted,
                  repairedSession.originSurface.surfaceID
                    == recoverableManagedLeaderSurfaceID else {
                return CollaborationRecoveryReport(
                    routeRepaired: false, leaderLive: false, liveAgents: 0,
                    replacedAgents: [], failedAgents: ["Managed leader relay did not start"]
                )
            }
            recordRecoveredRemoteLeaderSurface(
                teamName: teamName, surfaceID: recoverableManagedLeaderSurfaceID,
                leaderCLI: launch.cli, leaderModel: launch.model
            )
            scheduleRemoteProjectManifestPublication(forHostKey: hostKey)
            snapshotResult = await authoritativeCollaborationSnapshot(
                host: host, teamUUID: teamUUID,
                projectID: initial.remotePresentationProjectID
            )
            guard case .success(let refreshed) = snapshotResult else {
                return CollaborationRecoveryReport(
                    routeRepaired: false, leaderLive: false, liveAgents: 0,
                    replacedAgents: [], failedAgents: ["Managed leader refresh failed"]
                )
            }
            authoritative = refreshed
        } else { switch leaderDecision {
        case .keepExisting:
            break
        case .deferUntilAuthoritative:
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Leader state unavailable"]
            )
        case .bootstrapReplacement:
            let launch = Self.collaborationLeaderLaunchMetadata(
                remoteCLI: authoritative.team.leaderCLI,
                remoteModel: authoritative.team.leaderModel
            )
            let isExplicitRepairPlaceholder = teams[teamName]?.isRemoteRepairPlaceholder == true
            guard materializeRemoteRepairPlaceholder(teamName: teamName),
                  let repairedTeam = teams[teamName] else {
                return CollaborationRecoveryReport(
                    routeRepaired: false, leaderLive: false, liveAgents: 0,
                    replacedAgents: [], failedAgents: ["Repair presentation unavailable"]
                )
            }
            let repairWorkspaceID = repairedTeam.workspaceId
            let repairAnchor = repairedTeam.leaderPanelId
            let repairTabManager = AppDelegate.shared?.tabManagerFor(tabId: repairWorkspaceID)
            let acquiredRealizationPin = isExplicitRepairPlaceholder
                && repairTabManager != nil
            if acquiredRealizationPin {
                repairTabManager?.pinWorkspaceForSurfaceRealization(repairWorkspaceID)
            }
            do {
                // `recoverRemoteLeaderAfterRuntimeClose` does not return until
                // attachRemoteLeader has replaced this exact anchor and
                // confirmed its prompt. Keeping the focus-neutral mount pin for
                // that whole await lets TerminalPanelView create the Ghostty
                // surface, launch the relay helper, and arm the reverse-command
                // receiver without selecting the repaired workspace.
                defer {
                    if acquiredRealizationPin {
                        repairTabManager?.unpinWorkspaceForSurfaceRealization(
                            repairWorkspaceID
                        )
                    }
                }
                guard await recoverRemoteLeaderAfterRuntimeClose(
                    teamName: teamName,
                    closedPanelID: repairAnchor,
                    authoritativeReplacementRequired: true,
                    replacementLaunchMetadata: launch
                ) else {
                    let detail = teams[teamName]?.leaderFailureDescription
                        ?? "Leader replacement failed"
                    return CollaborationRecoveryReport(
                        routeRepaired: false, leaderLive: false, liveAgents: 0,
                        replacedAgents: [], failedAgents: [detail]
                    )
                }
                let repairedLeaderPanelID = teams[teamName]?.leaderPanelId
                let inspectedPanel: TerminalPanel? = {
                    guard let repairedLeaderPanelID,
                          let located = AppDelegate.shared?.locateSurface(
                              surfaceId: repairedLeaderPanelID
                          ),
                          located.workspaceId == repairWorkspaceID,
                          let workspace = located.tabManager.tabs.first(where: {
                              $0.id == repairWorkspaceID
                          }) else { return nil }
                    return workspace.terminalPanel(for: repairedLeaderPanelID)
                }()
                guard Self.remoteRepairLeaderIsReadyToUnpin(
                    teamLeaderPanelID: repairedLeaderPanelID,
                    inspectedPanelID: inspectedPanel?.id,
                    relayStarted: inspectedPanel?.peerPaneSession?.isRelayStarted == true
                ) else {
                    return CollaborationRecoveryReport(
                        routeRepaired: false, leaderLive: false, liveAgents: 0,
                        replacedAgents: [],
                        failedAgents: ["Replacement leader relay did not become ready"]
                    )
                }
            }
            snapshotResult = await authoritativeCollaborationSnapshot(
                host: host,
                teamUUID: teamUUID,
                projectID: initial.remotePresentationProjectID
            )
            let managedLeaderSurfaceID = ManagedPeerSurfaceStore.shared.leaderRecord(
                hostKey: hostKey, teamName: teamName
            )?.surfaceID
            guard case .success(let refreshed) = snapshotResult,
                  let replacementSurfaceID = Self.confirmedReplacementLeaderSurfaceID(
                    manifestLeaderSurfaceID: refreshed.team.leaderSurfaceID,
                    managedLeaderSurfaceID: managedLeaderSurfaceID,
                    surfaces: refreshed.surfaces
                  ) else {
                return CollaborationRecoveryReport(
                    routeRepaired: false, leaderLive: false, liveAgents: 0,
                    replacedAgents: [], failedAgents: ["Replacement leader not confirmed"]
                )
            }
            recordRecoveredRemoteLeaderSurface(
                teamName: teamName, surfaceID: replacementSurfaceID,
                leaderCLI: launch.cli, leaderModel: launch.model
            )
            scheduleRemoteProjectManifestPublication(forHostKey: hostKey)
            authoritative = refreshed
        }}

        let initialLeaderSurfaceID = teams[teamName]?.remoteLeaderSurfaceID
            ?? authoritative.team.leaderSurfaceID
        let initialPlan = Self.collaborationRecoveryPlan(
            leaderSurfaceID: initialLeaderSurfaceID,
            agents: initial.agents,
            surfaces: authoritative.surfaces
        )
#if DEBUG
        let surfaceState = authoritative.surfaces.map {
            let id = $0.surfaceID.map { String(format: "%02x", $0) }
                .joined().prefix(8)
            return "\(id):" + ($0.attachable ? "live" : "dead")
        }.joined(separator: ",")
        let deadIDSummary = initialPlan.deadAgentInstanceIDs.joined(separator: ",")
        dlog(
            "collaboration.repair.roster team=\(teamName) leader=\(initialPlan.leaderLive) "
                + "dead=\(deadIDSummary) "
                + "surfaces=[\(surfaceState)]"
        )
#endif
        guard await ensureCollaborationPresentation(
            teamName: teamName,
            repairableMissingAgentIDs: Set(initialPlan.deadAgentInstanceIDs)
        ) else {
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: initialPlan.leaderLive,
                liveAgents: initialPlan.liveAgentCount,
                replacedAgents: [], failedAgents: ["presentation_missing"]
            )
        }

        guard let routeTeam = teams[teamName], routeTeam.teamUuid == teamUUID else {
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Project changed during repair"]
            )
        }
        let routeGeneration = Self.collaborationRouteGeneration(routeTeam)
        let reusableLeaderGrant = remoteLeaderGrants[teamName]
        guard let routes = await mintAdoptedRemoteAgentRoutes(
            teamName: teamName, teamUUID: teamUUID, host: host, members: routeTeam.agents,
            reusingLeaderGrant: reusableLeaderGrant
        ) else {
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: initial.leaderReady, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Route refresh failed"]
            )
        }
        let grantIDs = routes.newlyMintedGrantIDs
        guard teams[teamName].map(Self.collaborationRouteGeneration) == routeGeneration else {
            Self.rollbackRemoteAgentRoutesPreservingGrants(
                host: host, transaction: routes.transaction, grantIDs: grantIDs
            )
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Project changed during repair"]
            )
        }
        guard let candidate = teams[teamName],
              Self.collaborationRouteGeneration(candidate) == routeGeneration else {
            Self.rollbackRemoteAgentRoutesPreservingGrants(
                host: host, transaction: routes.transaction, grantIDs: grantIDs
            )
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Project changed during repair"]
            )
        }
        // Verify the staged leader candidate directly. The canonical route
        // files and their old keepalives remain untouched until this exact
        // leader-side path proves it reaches the expected Project.
        if let verificationFailure = await Self.verifyRemoteCollaborationRoute(
            host: host, teamName: teamName, teamUUID: teamUUID,
            routeFilePath: routes.candidateLeaderRouteFilePath
        ) {
            if await Self.finishAdoptedRemoteAgentRoutes(
                host: host, transaction: routes.transaction, commit: false
            ) {
                await Self.revokeGrants(grantIDs)
            } else {
                Self.rollbackRemoteAgentRoutesPreservingGrants(
                    host: host, transaction: routes.transaction, grantIDs: grantIDs
                )
            }
            return CollaborationRecoveryReport(
                routeRepaired: false, routeVerified: false,
                leaderLive: initialPlan.leaderLive,
                liveAgents: initialPlan.liveAgentCount,
                replacedAgents: [], failedAgents: [],
                verificationFailure: verificationFailure
            )
        }

        guard let current = teams[teamName],
              Self.collaborationRouteGeneration(current) == routeGeneration else {
            Self.rollbackRemoteAgentRoutesPreservingGrants(
                host: host, transaction: routes.transaction, grantIDs: grantIDs
            )
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Project changed during verification"]
            )
        }
        guard await Self.finishAdoptedRemoteAgentRoutes(
            host: host, transaction: routes.transaction, commit: true
        ) else {
            Self.rollbackRemoteAgentRoutesPreservingGrants(
                host: host, transaction: routes.transaction, grantIDs: grantIDs
            )
            return CollaborationRecoveryReport(
                routeRepaired: false, leaderLive: initial.leaderReady, liveAgents: 0,
                replacedAgents: [], failedAgents: ["Route commit failed"]
            )
        }
        startRemoteLeaderGrantKeepalive(teamName: teamName, grant: routes.leaderGrant)
        for (instanceID, grantID) in routes.workerGrants {
            startRemoteAgentRouteKeepalive(
                teamName: teamName, agentInstanceID: instanceID, grantID: grantID
            )
        }
        if !(await Self.finalizeAdoptedRemoteAgentRoutes(
            host: host, transaction: routes.transaction
        )) {
            // Verification and commit both succeeded. Keep the new grants and
            // finish deleting rollback backups in the background.
            Self.scheduleAdoptedRemoteAgentRouteFinalize(
                host: host, transaction: routes.transaction
            )
        }
        var hookRefreshFailed = false
        if let hookData = Self.localLeaderTurnHookData() {
            hookRefreshFailed = await Self.writeRemoteLeaderTurnHookOverSSH(
                host: host, hookData: hookData, teamUUID: teamUUID
            ) == nil
        }
        refreshLeaderParticipationControls()

        let postVerificationSnapshot = await authoritativeCollaborationSnapshot(
            host: host,
            teamUUID: teamUUID,
            projectID: initial.remotePresentationProjectID
        )
        guard case .success(let postVerification) = postVerificationSnapshot else {
            let reason: String
            if case .failure(let message) = postVerificationSnapshot { reason = message }
            else { reason = "Host roster unavailable" }
            return CollaborationRecoveryReport(
                routeRepaired: true, routeVerified: true,
                leaderLive: false, liveAgents: 0,
                replacedAgents: [], failedAgents: [reason]
            )
        }
        let refreshedSurfaces = postVerification.surfaces
        let leaderSurfaceID = current.remoteLeaderSurfaceID
            ?? ManagedPeerSurfaceStore.shared.leaderRecord(
                hostKey: hostKey, teamName: teamName
            )?.surfaceID
        let plan = Self.collaborationRecoveryPlan(
            leaderSurfaceID: leaderSurfaceID,
            agents: current.agents,
            surfaces: refreshedSurfaces
        )
        guard plan.leaderLive else {
            return CollaborationRecoveryReport(
                routeRepaired: true, routeVerified: true,
                leaderLive: false, liveAgents: plan.liveAgentCount,
                replacedAgents: [], failedAgents: []
            )
        }

        var replaced: [String] = []
        var failed: [String] = hookRefreshFailed ? ["Turn hook refresh failed"] : []
        let deadIDs = Set(plan.deadAgentInstanceIDs)
        for agent in current.agents where agent.remoteAgentSurface
            && !deadIDs.contains(agent.agentInstanceId) {
            guard let panelID = agent.panelId,
                  let manager = AppDelegate.shared?.tabManagerFor(tabId: agent.workspaceId),
                  let workspace = manager.tabs.first(where: { $0.id == agent.workspaceId })
            else {
                failed.append(agent.name)
                continue
            }
            if !workspace.peerAgentPanelIsLive(panelID) {
                if await workspace.repairRemoteAgentPane(panelId: panelID) {
                    replaced.append(agent.name)
                } else {
                    failed.append(agent.name)
                }
            }
        }
        for instanceID in plan.deadAgentInstanceIDs {
            guard let liveTeam = teams[teamName],
                  let agent = liveTeam.agents.first(where: {
                      $0.agentInstanceId == instanceID
                  }) else {
                failed.append(instanceID)
                continue
            }
            guard let panelID = agent.panelId,
                  let manager = AppDelegate.shared?.tabManagerFor(tabId: agent.workspaceId),
                  let workspace = manager.tabs.first(where: { $0.id == agent.workspaceId }),
                  workspace.panels[panelID] != nil else {
                if await replaceMissingPeerOwnedAgentPane(
                    teamName: teamName,
                    agentInstanceID: instanceID
                ) {
                    replaced.append(agent.name)
                } else {
                    failed.append(agent.name)
                }
                continue
            }
            switch await restartAgentPaneHard(panelId: panelID) {
            case .success:
                replaced.append(agent.name)
            case .failure:
                failed.append(agent.name)
            }
        }
        return CollaborationRecoveryReport(
            routeRepaired: true, routeVerified: true, leaderLive: true,
            liveAgents: plan.liveAgentCount + replaced.count,
            replacedAgents: replaced, failedAgents: failed
        )
    }

    struct CollaborationRecoveryReport: Equatable {
        let routeRepaired: Bool
        let routeVerified: Bool
        let leaderLive: Bool
        let liveAgents: Int
        let replacedAgents: [String]
        let failedAgents: [String]
        let verificationFailure: String?

        init(
            routeRepaired: Bool, routeVerified: Bool = false,
            leaderLive: Bool, liveAgents: Int,
            replacedAgents: [String], failedAgents: [String],
            verificationFailure: String? = nil
        ) {
            self.routeRepaired = routeRepaired
            self.routeVerified = routeVerified
            self.leaderLive = leaderLive
            self.liveAgents = liveAgents
            self.replacedAgents = replacedAgents
            self.failedAgents = failedAgents
            self.verificationFailure = verificationFailure
        }

        var succeeded: Bool {
            routeRepaired && routeVerified && leaderLive && failedAgents.isEmpty
        }

        var message: String {
            if let verificationFailure, !routeVerified {
                return routeRepaired
                    ? "Routes were refreshed, but leader control verification failed: \(verificationFailure)."
                    : "Leader control verification failed and the route update was rolled back: \(verificationFailure)."
            }
            if !routeRepaired {
                return failedAgents.first.map { "Collaboration repair failed: \($0)." }
                    ?? "Collaboration repair failed."
            }
            if !routeVerified { return "Routes were refreshed, but leader control could not be verified." }
            if !failedAgents.isEmpty, !leaderLive {
                return "Leader control verified, but \(failedAgents.joined(separator: ", "))."
            }
            if !leaderLive {
                return "Leader control verified, but the leader process is not live. Worker replacement was withheld."
            }
            if !failedAgents.isEmpty {
                return "Leader control verified. Replaced \(replacedAgents.count) agent(s); \(failedAgents.count) replacement(s) failed."
            }
            if !replacedAgents.isEmpty {
                return "Collaboration verified. Replaced \(replacedAgents.count) dead agent(s)."
            }
            return "Collaboration verified. Leader and \(liveAgents) agent(s) are live; nothing was replaced."
        }
    }

    static let collaborationRouteVerificationMarker =
        "__TERMMESH_COLLABORATION_ROUTE_RESULT__="
    static let collaborationRouteVerificationExitMarker =
        "__TERMMESH_COLLABORATION_ROUTE_EXIT__="

    /// Resolve only a control socket that belongs to the authenticated peer
    /// endpoint. Linux custom installs use Host Doctor's measured path; the
    /// filename substitutions cover the bundled macOS daemon and the standard
    /// Linux install. No global app socket or last-used socket participates.
    static func collaborationControlSocketPath(
        peerSocketPath: String,
        health: PeerHostHealthBaseline?
    ) -> String? {
        if let health,
           health.peerPathPresent, health.peerPath == peerSocketPath,
           health.controlPathPresent, !health.controlPath.isEmpty {
            return health.controlPath
        }
        if peerSocketPath.hasSuffix("/term-meshd-peer.sock") {
            return String(peerSocketPath.dropLast("term-meshd-peer.sock".count))
                + "term-meshd.sock"
        }
        if peerSocketPath.hasSuffix("/tm-peer.sock") {
            return String(peerSocketPath.dropLast("tm-peer.sock".count))
                + "term-meshd.sock"
        }
        return nil
    }

    /// Verification must measure the same authenticated endpoint that supplied
    /// the Team and surface roster. A saved Mac profile can still name its old
    /// GUI/legacy peer socket while Hello redirects durable team work to the
    /// daemon's session-owner socket.
    nonisolated static func collaborationPeerSocketPath(
        teamHostKey: PeerPaneHostKey?
    ) -> String? {
        if let teamHostKey {
            let path: String
            switch teamHostKey {
            case .direct(let sockPath): path = sockPath
            case .ssh(_, let remoteSockPath, _): path = remoteSockPath
            }
            if !path.isEmpty { return path }
        }
        return nil
    }

    /// Run `tm-agent status` in the same service account and with the same
    /// route file as the long-lived leader. The command and its output are
    /// secret-free; the bearer never leaves the 0600 file.
    static func remoteCollaborationRouteVerificationScript(
        teamName: String,
        teamUUID: String,
        controlSocketPath: String,
        hostBinDirs: [String],
        routeFilePath: String? = nil
    ) -> String {
        let routeName = remoteLeaderRouteFileName(teamUUID: teamUUID)
        let routeAssignment: String
        if let routeFilePath, routeFilePath.hasPrefix("/") {
            routeAssignment = "route=\(shellQuoted(routeFilePath)); "
        } else {
            routeAssignment = "route=\"$HOME/.term-mesh/agent-routes/\(routeName)\"; "
        }
        let body = "set -e; " + RemoteShellPath.prologue(hostBinDirs: hostBinDirs)
            + routeAssignment
            + "[ -r \"$route\" ] || exit 70; "
            + "control=\(shellQuoted(controlSocketPath)); "
            + "[ -S \"$control\" ] || exit 71; "
            + "cli=$(command -v tm-agent 2>/dev/null || true); "
            + "[ -x \"$cli\" ] || cli=\"$HOME/.local/bin/tm-agent\"; "
            + "[ -x \"$cli\" ] || exit 72; "
            + "set +e; result=$(TERMMESH_SOCKET=\"$control\" "
            + "TERMMESH_TEAM=\(shellQuoted(teamName)) "
            + "TERMMESH_LEADER_ROUTE_FILE=\"$route\" TERMMESH_RPC_TIMEOUT=20 "
            + "\"$cli\" --team \(shellQuoted(teamName)) status 2>&1); status=$?; set -e; "
            + "encoded=$(printf %s \"$result\" | base64 | tr -d '\\n'); "
            + "printf '%s%s\\n' \(shellQuoted(collaborationRouteVerificationMarker)) "
            + "\"$encoded\"; printf '%s%s\\n' "
            + "\(shellQuoted(collaborationRouteVerificationExitMarker)) \"$status\""
        return RemotePasteTransfer.serviceAccountCommand(body)
    }

    static func parseRemoteCollaborationRouteVerification(
        _ output: String, expectedTeamName: String
    ) -> Bool {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let range = text.range(of: collaborationRouteVerificationMarker),
                  let data = Data(base64Encoded: String(text[range.upperBound...])),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["ok"] as? Bool == true,
                  object["remote_leader_proxy"] as? Bool == true,
                  let result = object["result"] as? [String: Any],
                  result["team_name"] as? String == expectedTeamName
            else { continue }
            return true
        }
        return false
    }

    static func remoteCollaborationRouteVerificationFailure(_ output: String) -> String {
        var status = "unknown"
        var detail = "no diagnostic output"
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let range = text.range(of: collaborationRouteVerificationExitMarker) {
                status = String(text[range.upperBound...])
            }
            if let range = text.range(of: collaborationRouteVerificationMarker),
               let data = Data(base64Encoded: String(text[range.upperBound...])),
               let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
                detail = String(decoded.prefix(512))
            }
        }
        return "leader route exited \(status): \(detail)"
    }

    private static func verifyRemoteCollaborationRoute(
        host: HostEntry, teamName: String, teamUUID: String,
        routeFilePath: String? = nil
    ) async -> String? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
            return "the host has no SSH verification route"
        }
        guard let peerSocketPath = collaborationPeerSocketPath(
            teamHostKey: host.teamHostSpec?.hostKey
        ) else {
            return "the authenticated team peer socket could not be resolved"
        }
        let health = await PeerHostDoctor.healthBaseline(
            sshTarget: sshTarget, port: host.sshPort, identityFile: host.identityFile
        )
        guard let controlSocketPath = collaborationControlSocketPath(
            peerSocketPath: peerSocketPath, health: health
        ) else {
            return "the host control socket could not be resolved"
        }
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: remoteCollaborationRouteVerificationScript(
                    teamName: teamName, teamUUID: teamUUID,
                    controlSocketPath: controlSocketPath,
                    hostBinDirs: host.hostCLIBinDirs,
                    routeFilePath: routeFilePath
                ),
                timeoutSeconds: 30
            )
            return parseRemoteCollaborationRouteVerification(
                output, expectedTeamName: teamName
            ) ? nil : remoteCollaborationRouteVerificationFailure(output)
        } catch {
            return String(describing: error)
        }
    }

    /// Capture every namespace owner relevant to New Project. The snapshot is
    /// read-only and spans all windows, preserved/detached viewers and live
    /// remote manifests, so callers do not grow subtly different preflight
    /// rules.
    func projectConflictRecords(
        currentTabManager: TabManager?,
        hosts providedHosts: [HostEntry]? = nil
    ) -> [ProjectConflictRecord] {
        let hosts = providedHosts ?? RemoteHostStore.shared.sortedHosts
        let currentWindowID = currentTabManager.flatMap {
            AppDelegate.shared?.windowId(for: $0)
        }
        var records: [ProjectConflictRecord] = teams.values.map { team in
            let identity = ProjectCreationIdentity(
                projectID: Self.effectiveRemotePresentationProjectID(
                    storedProjectID: team.remotePresentationProjectID,
                    teamUUID: team.teamUuid, teamName: team.id
                ),
                // `workingDirectory` is the local source/working checkout. A
                // remote leader does not move that checkout to its host.
                hostKey: nil,
                workingDirectory: team.workingDirectory
            )
            let location: ProjectConflictLocation
            if let context = AppDelegate.shared?.contextContainingTabId(team.workspaceId) {
                if context.windowId == currentWindowID {
                    location = .currentWindow(
                        windowID: context.windowId, workspaceID: team.workspaceId
                    )
                } else {
                    location = .otherWindow(
                        windowID: context.windowId, workspaceID: team.workspaceId
                    )
                }
            } else {
                location = .detached(workspaceID: team.workspaceId)
            }
            return ProjectConflictRecord(
                name: team.id, identity: identity, location: location,
                teamName: team.id, leaderReady: team.leaderReady,
                failureDescription: team.leaderFailureDescription
            )
        }

        // A Project may have its source checkout on a peer while its local
        // `workingDirectory` is only the viewer/leader fallback. Preserve the
        // same Project/location metadata but expose every recorded checkout as
        // an identity alias so exact host+path matching does not depend on the
        // leader placement.
        let localRecords = records
        for record in localRecords {
            guard let teamName = record.teamName, let team = teams[teamName] else { continue }
            for location in team.remoteProjectLocations {
                var alias = record
                alias.identity = ProjectCreationIdentity(
                    projectID: record.identity.projectID,
                    hostKey: location.hostKey,
                    workingDirectory: location.path
                )
                records.append(alias)
            }
        }

        for host in hosts where host.isConnected {
            for remote in host.teams {
                records.append(ProjectConflictRecord(
                    name: remote.name,
                    identity: ProjectCreationIdentity(
                        projectID: remote.projectID, hostKey: host.id,
                        workingDirectory: remote.workingDirectory
                    ),
                    location: .remote(hostKey: host.id, hostName: host.displayName),
                    teamName: remote.name,
                    leaderReady: remote.leaderProcessActiveKnown
                        ? remote.leaderProcessActive : !remote.leaderSurfaceID.isEmpty,
                    failureDescription: remote.leaderProcessActiveKnown
                        && !remote.leaderProcessActive
                        ? "Remote leader process is not active" : nil,
                    presentationOwnedByRequester: remote.presentationOwnedByRequester,
                    leaderProcessActiveKnown: remote.leaderProcessActiveKnown
                ))
            }
        }
        return records
    }

    func projectNameConflict(
        name: String,
        identity: ProjectCreationIdentity,
        currentTabManager: TabManager?
    ) -> ProjectNameConflict {
        Self.classifyProjectNameConflict(
            requestedName: name, requestedIdentity: identity,
            candidates: projectConflictRecords(currentTabManager: currentTabManager)
        )
    }

    /// Publish complete remote presentation descriptors after the normal team
    /// state funnel runs. A viewer restart must learn this from the daemon;
    /// local UserDefaults/live snapshots are intentionally not part of the
    /// discovery contract.
    func scheduleRemoteProjectManifestPublication(forHostKey requestedHostKey: String? = nil) {
        for team in teams.values {
            guard case let .peer(hostKey) = team.leaderEndpoint,
                  requestedHostKey == nil || requestedHostKey == hostKey,
                  team.ownsRemotePresentation,
                  !team.isRemoteRepairPlaceholder
            else { continue }
            let signature = Self.remoteProjectManifestSignature(team, hostKey: hostKey)
            // Ordinary team syncs include high-frequency task/message state.
            // Only topology changes schedule a new revision. A concrete host
            // reconnect bypasses this guard because the daemon may have been
            // replaced since the last successful publication.
            if requestedHostKey == nil,
               remoteProjectManifestSignatures[team.id] == signature {
                continue
            }
            remoteProjectManifestSignatures[team.id] = signature
            remoteProjectManifestTasks[team.id]?.cancel()
            remoteProjectManifestTasks[team.id] = Task { @MainActor [weak self] in
                for delay in Self.remoteProjectManifestRetryDelaysNanoseconds {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled, let self else { return }
                    if await self.publishRemoteProjectManifest(teamName: team.id) {
                        return
                    }
                }
            }
        }
    }

    static func remoteProjectManifestSignature(
        _ team: Team,
        hostKey: String
    ) -> String {
        let members = team.agents.map { agent in
            [
                agent.agentInstanceId,
                agent.name,
                agent.cli,
                agent.model,
                agent.agentType,
                agent.color,
                agent.originalAgentWorkDir ?? team.workingDirectory,
                agent.remoteSurfaceID?.base64EncodedString() ?? "",
                agent.remoteAgentSurface ? "agent" : "terminal",
                agent.hostKey ?? "",
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        let leaderID = ManagedPeerSurfaceStore.shared.leaderRecord(
            hostKey: hostKey,
            teamName: team.id
        )?.surfaceID?.base64EncodedString() ?? ""
        return [
            team.id,
            team.teamUuid ?? "",
            team.workingDirectory,
            team.gitRepoRoot ?? "",
            hostKey,
            leaderID,
            team.leaderCli ?? team.leaderMode,
            team.leaderModel,
            team.delegationState.configured.rawValue,
            team.delegationState.effective.rawValue,
            team.delegationState.pending?.rawValue ?? "",
            members,
        ].joined(separator: "\u{1d}")
    }

    /// A project name is presentation copy, not identity. The team UUID is
    /// generated once and retained across leader/app reconnects, so two
    /// same-named projects on one daemon remain independent.
    nonisolated static func remoteProjectPresentationID(teamUUID: String) -> String {
        "team:\(teamUUID)"
    }

    /// Initial debounce plus bounded reconnect retries. A successful host
    /// refresh also starts a fresh sequence, so recovery is not limited to
    /// this window.
    nonisolated static let remoteProjectManifestRetryDelaysNanoseconds: [UInt64] = [
        250_000_000,
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
    ]

    /// Returns false only for a transient transport/persistence failure that
    /// is worth retrying. Invalid or unsupported topology is terminal until a
    /// later team mutation schedules a new publication.
    private func publishRemoteProjectManifest(teamName: String) async -> Bool {
        guard let team = teams[teamName],
              let rawTeamUUID = team.teamUuid,
              !rawTeamUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case let .peer(hostKey) = team.leaderEndpoint,
              let leaderSurfaceID = ManagedPeerSurfaceStore.shared.leaderRecord(
                  hostKey: hostKey,
                  teamName: teamName
              )?.surfaceID,
              !leaderSurfaceID.isEmpty,
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey })
        else { return true }
        let projectID = Self.remoteProjectPresentationID(teamUUID: rawTeamUUID)
        let suppression = Self.projectDeletionSuppressionKey(
            hostID: hostKey, projectID: projectID
        )
        guard !projectDeletionSuppressions.contains(suppression) else { return true }
        guard host.isConnected, !Self.liveTeamSockPath(for: host).isEmpty else { return false }
        let teamUUID = rawTeamUUID

        // v1 manifests live on the daemon that owns the leader and contain
        // daemon-local surface ids. Publishing only the matching subset would
        // make a multi-host team look complete while silently dropping its
        // other members after a viewer restart. Until the wire carries a
        // per-member endpoint, decline the whole manifest instead.
        guard Self.remoteManifestCoversEveryAgent(team.agents, hostKey: hostKey) else {
            RemoteWorkLog.info(
                "Could not persist project \(team.id) on \(host.displayName): "
                    + "project.presentation.v1 requires every agent on the leader host"
            )
            // Same-host members acquire their daemon-local surface ids only
            // after EnsureSurface returns. Keep the bounded publisher alive
            // across that creation window; a genuinely mixed-host topology is
            // terminal until a later roster mutation schedules a new signature.
            return team.agents.contains { $0.hostKey != hostKey }
        }

        var project = Termmesh_Peer_V1_Team()
        project.name = team.id
        project.teamUuid = teamUUID
        project.workingDirectory = team.workingDirectory
        project.projectRoot = team.gitRepoRoot ?? ""
        project.agentNames = team.agents.map(\.name)
        project.createdAtUnixSecs = UInt64(max(0, team.createdAt.timeIntervalSince1970))
        project.leaderSurfaceID = leaderSurfaceID
        project.leaderCli = team.leaderCli ?? team.leaderMode
        project.leaderModel = team.leaderModel
        project.projectID = projectID
        project.delegationConfigured = team.delegationState.configured.rawValue
        project.delegationEffective = team.delegationState.effective.rawValue
        project.delegationPending = team.delegationState.pending?.rawValue ?? ""
        project.members = team.agents.compactMap { agent in
            guard let surfaceID = agent.remoteSurfaceID else { return nil }
            var member = Termmesh_Peer_V1_TeamMember()
            member.name = agent.name
            member.agentInstanceID = agent.agentInstanceId
            member.cli = agent.cli
            member.model = agent.model
            member.agentType = agent.agentType
            member.color = agent.color
            member.workingDirectory = agent.originalAgentWorkDir ?? team.workingDirectory
            member.surfaceID = surfaceID
            member.surfaceType = agent.remoteAgentSurface ? "agent" : "terminal"
            return member
        }

        guard let connection = try? await PeerRelaySession.connect(
            hostSockPath: Self.liveTeamSockPath(for: host)
        ) else { return false }
        guard connection.hostCapabilities.has(PeerCapability.projectPresentationV1) else {
            await connection.cancel()
            return true
        }
        do {
            // Delete may begin while the network connection above is opening.
            // Re-check at the mutation boundary so a delayed publisher cannot
            // resurrect a manifest after its tombstone was committed.
            guard !projectDeletionSuppressions.contains(suppression) else {
                await connection.cancel()
                return true
            }
            let response = try await connection.session.upsertProjectPresentation(project)
            await connection.cancel()
            if !response.ok {
                RemoteWorkLog.info(
                    "Could not persist project \(team.id) on \(host.displayName): "
                        + response.errorCode
                )
            } else {
                publishedRemoteProjectAgentSurfaceIDs[teamName] = Set(
                    project.members.map(\.surfaceID)
                )
                recordPublishedRemoteProjectIdentity(
                    teamName: teamName, projectID: project.projectID,
                    hostKey: hostKey, revision: response.revision
                )
                RemoteHostStore.shared.refreshTeamRoster(forHostKey: hostKey)
            }
            return response.ok
                || !Self.remoteProjectManifestShouldRetry(errorCode: response.errorCode)
        } catch {
            await connection.cancel()
            RemoteWorkLog.info(
                "Could not persist project \(team.id) on \(host.displayName): \(error)"
            )
            return false
        }
    }

    static func remoteManifestCoversEveryAgent(
        _ agents: [AgentMember],
        hostKey: String
    ) -> Bool {
        agents.allSatisfy { agent in
            agent.hostKey == hostKey
                && agent.remoteSurfaceID?.isEmpty == false
        }
    }

    /// Surface restoration can lag behind tunnel reconnection. These errors
    /// describe an otherwise valid topology that may become publishable during
    /// the bounded retry window; ownership/validation failures are terminal.
    nonisolated static func remoteProjectManifestShouldRetry(errorCode: String) -> Bool {
        [
            "persistence_failed",
            "leader_surface_missing",
            "member_surface_missing",
            "member_surface_mismatch",
        ].contains(errorCode)
    }

    static func adoptedAgentOwnsRemoteCleanup(
        presentationOwnedByRequester: Bool,
        surfaceType: String
    ) -> Bool {
        presentationOwnedByRequester
            && SessionHostPanes.isAgentSurfaceType(surfaceType)
    }

    static func adoptedPresentationAllowsRemoteDestruction(
        presentationOwnedByRequester: Bool
    ) -> Bool {
        presentationOwnedByRequester
    }

    /// A viewer must rediscover the project from the peer daemon after an app
    /// restart. Persisting its local attachment as an owner-restorable pane
    /// snapshot would lose the ownership bit and could later let that viewer
    /// destroy the peer-owned leader.
    nonisolated static func shouldPersistProjectPresentationSnapshot(
        presentationOwnedByRequester: Bool
    ) -> Bool {
        presentationOwnedByRequester
    }

    static func remotePresentationCanAttach(
        leaderSurfaceID: Data,
        isConnected: Bool,
        hasResolvedTeamRoute: Bool
    ) -> Bool {
        !leaderSurfaceID.isEmpty
            && isConnected
            && hasResolvedTeamRoute
    }

    /// A durable manifest remains authoritative repair input even after its
    /// leader exits, but it must not be presented or adopted as live work.
    /// Legacy manifests have no process probe, so preserve their existing
    /// conservative attach policy until the host reports an exact state.
    nonisolated static func remoteManifestLeaderIsAdoptable(
        _ remote: RemoteTeamSummary
    ) -> Bool {
        !remote.leaderProcessActiveKnown || remote.leaderProcessActive
    }

    nonisolated static func shouldOfferRemoteManifest(
        hasLocalTeam: Bool,
        localPresentationOwnedByRequester: Bool,
        localRevision: UInt64,
        remoteRevision: UInt64
    ) -> Bool {
        !hasLocalTeam
            || (!localPresentationOwnedByRequester && remoteRevision > localRevision)
    }

    nonisolated static func sidebarRemoteManifestState(
        localTeam: Team?,
        remote: RemoteTeamSummary,
        hostKey: String
    ) -> (shouldOffer: Bool, isUpdate: Bool) {
        let matching = localTeam.map {
            remotePresentationIdentityMatches(
                team: $0, remote: remote, hostKey: hostKey
            )
        } ?? false
        let shouldOffer = shouldOfferRemoteManifest(
            hasLocalTeam: matching,
            localPresentationOwnedByRequester:
                matching ? (localTeam?.ownsRemotePresentation ?? false) : false,
            localRevision: matching ? (localTeam?.remotePresentationRevision ?? 0) : 0,
            remoteRevision: remote.presentationRevision
        )
        return (shouldOffer, matching)
    }

    nonisolated static func sidebarProjectIdentity(
        declared: PeerProjectIdentity?,
        runtimeTeamName: String?,
        inferred: PeerProjectIdentity
    ) -> PeerProjectIdentity {
        if let declared { return declared }
        if let name = runtimeTeamName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return PeerProjectIdentity(
                key: "name:\(name.lowercased())",
                label: name,
                isUnknown: false
            )
        }
        return inferred
    }

    /// The manifests a host lists under its own row in the Host axis.
    ///
    /// Deliberately the same rule the Project axis applies, because a machine's
    /// projects appearing in one view and not the other is what made a Project
    /// on a Mac peer look deleted: workspaces come from the serving GUI socket,
    /// which publishes no manifest, so the Host axis had nothing to show and
    /// said nothing about it. A manifest with no leader surface or a known-dead
    /// leader is skipped because neither can be attached as live work. The raw
    /// host roster remains intact so its owner can still repair that Project.
    nonisolated static func hostAxisOfferedManifests(
        isConnected: Bool,
        teams: [RemoteTeamSummary],
        hostKey: String,
        localTeamForName: (String) -> Team?
    ) -> [RemoteTeamSummary] {
        guard isConnected else { return [] }
        return teams.filter { team in
            guard !team.leaderSurfaceID.isEmpty,
                  remoteManifestLeaderIsAdoptable(team) else { return false }
            return sidebarRemoteManifestState(
                localTeam: localTeamForName(team.name),
                remote: team,
                hostKey: hostKey
            ).shouldOffer
        }.sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return sidebarRemoteManifestKey(hostID: hostKey, team: lhs)
                < sidebarRemoteManifestKey(hostID: hostKey, team: rhs)
        }
    }

    /// Team names are presentation copy and can repeat across hosts. Project
    /// identity plus host identity is stable for restore state and automation.
    nonisolated static func sidebarRemoteManifestKey(
        hostID: String, team: RemoteTeamSummary
    ) -> String {
        let projectIdentity = team.projectID.isEmpty ? team.id : team.projectID
        return Data(hostID.utf8).base64EncodedString() + "."
            + Data(projectIdentity.utf8).base64EncodedString()
    }

    /// Pick the one daemon manifest this installation may restore without a
    /// click. Team names are presentation copy and can repeat; the newest
    /// locally-owned leader record is the durable join key that prevents an
    /// old same-named Project from being adopted after a restart.
    nonisolated static func automaticRemoteProjectRestoreCandidate(
        in remotes: [RemoteTeamSummary],
        leaderRecord: ManagedPeerSurfaceStore.Record?
    ) -> RemoteTeamSummary? {
        let owned = remotes.filter {
            $0.presentationOwnedByRequester && !$0.projectID.isEmpty
        }
        if let leaderSurfaceID = leaderRecord?.surfaceID {
            return owned
                .filter { $0.leaderSurfaceID == leaderSurfaceID }
                .max { $0.presentationRevision < $1.presentationRevision }
        }
        // A hard app relaunch can occur before cfprefsd flushes the local
        // surface record. The daemon manifest is still durable and carries an
        // authenticated ownership bit. Restore only when this team name has
        // exactly one owned identity; ambiguity remains fail-closed so an old
        // same-named Project can never be adopted by guessing.
        let identities = Dictionary(grouping: owned, by: \.projectID)
        guard identities.count == 1, let candidates = identities.values.first else { return nil }
        return candidates.max { $0.presentationRevision < $1.presentationRevision }
    }

    /// A dead owner manifest cannot be adopted, but it still contains the
    /// deterministic input for Repair collaboration. Unknown liveness and
    /// ambiguous owner identity remain fail-closed.
    nonisolated static func automaticRemoteProjectRepairPlaceholderCandidate(
        in remotes: [RemoteTeamSummary],
        leaderRecord: ManagedPeerSurfaceStore.Record?
    ) -> RemoteTeamSummary? {
        guard let remote = automaticRemoteProjectRestoreCandidate(
            in: remotes, leaderRecord: leaderRecord
        ), remote.presentationOwnedByRequester,
           remote.leaderProcessActiveKnown, !remote.leaderProcessActive,
           !remote.teamUUID.isEmpty, !remote.projectID.isEmpty,
           !remote.leaderSurfaceID.isEmpty
        else { return nil }
        return remote
    }

    /// Reconstruct owner repair state without attaching, spawning, focusing,
    /// or registering any surface. The local UUIDs are inert sentinels; Repair
    /// uses the exact durable project/team and surface identities below.
    nonisolated static func remoteProjectRepairPlaceholder(
        remote: RemoteTeamSummary,
        hostKey: String
    ) -> Team? {
        guard remote.presentationOwnedByRequester,
              remote.leaderProcessActiveKnown, !remote.leaderProcessActive,
              !remote.teamUUID.isEmpty, !remote.projectID.isEmpty,
              !remote.leaderSurfaceID.isEmpty, !hostKey.isEmpty
        else { return nil }
        let workspaceID = UUID()
        let launch = collaborationLeaderLaunchMetadata(
            remoteCLI: remote.leaderCLI, remoteModel: remote.leaderModel
        )
        let members = remote.members.map { descriptor in
            AgentMember(
                id: "\(descriptor.name)@\(remote.name)",
                agentInstanceId: descriptor.agentInstanceID,
                name: descriptor.name,
                teamName: remote.name,
                cli: descriptor.cli,
                launchCommand: descriptor.cli,
                model: descriptor.model,
                agentType: descriptor.agentType,
                color: descriptor.color,
                instructions: "",
                workspaceId: workspaceID,
                panelId: nil,
                createdAt: Date(),
                remoteSurfaceID: descriptor.surfaceID,
                remoteSurfaceSpawned: descriptor.surfaceType == "agent",
                remoteAgentSurface: descriptor.surfaceType == "agent",
                hostKey: hostKey,
                originalAgentWorkDir: descriptor.workingDirectory
            )
        }
        var team = Team(
            id: remote.name,
            leaderSessionId: UUID().uuidString,
            leaderMode: "adopted",
            leaderModel: launch.model,
            leaderCli: launch.cli,
            leaderPanelId: UUID(),
            leaderEndpoint: .peer(hostKey: hostKey),
            leaderReady: false,
            leaderFailureDescription:
                "Remote leader process is inactive; Repair collaboration can restore it",
            workingDirectory: remote.workingDirectory,
            workspaceId: workspaceID,
            agents: members,
            createdAt: Date(),
            gitRepoRoot: remote.projectRootPath,
            worktreeMode: "off",
            teamUuid: remote.teamUUID,
            usesDedicatedRemoteWorkspaces: true,
            ownsRemotePresentation: true,
            remotePresentationRevision: remote.presentationRevision,
            remotePresentationProjectID: remote.projectID,
            remotePresentationHostKey: hostKey,
            remoteLeaderSurfaceID: remote.leaderSurfaceID,
            isRemoteRepairPlaceholder: true
        )
        team.delegationState = remote.delegationState
        return team
    }

    /// Commit the placeholder to every local routing surface as one logical
    /// install. The published assignment emits the UI change; the registry
    /// receives the same durable ids and delegation before daemon sync.
    @MainActor
    func installRemoteProjectRepairPlaceholder(_ team: Team) -> Bool {
        guard team.isRemoteRepairPlaceholder, team.ownsRemotePresentation,
              teams[team.id] == nil,
              let teamUUID = team.teamUuid?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !teamUUID.isEmpty,
              TeamDataStore.shared.preparePlaceholderBoardRegistration(
                teamName: team.id, teamUUID: teamUUID
              )
        else { return false }
        teams[team.id] = team
        TeamDataStore.shared.registerTeam(
            team.id,
            agents: team.agents.map {
                .init(name: $0.name, instanceId: $0.agentInstanceId)
            },
            delegationState: team.delegationState
        )
        syncTeamStateToDaemon()
        return true
    }

    /// Explicit owner-RPC counterpart to automatic cold reconstruction. Unlike
    /// the name-based startup scan, exact durable identity makes multiple
    /// same-owner manifests unambiguous. It still installs only inert repair
    /// state; the caller's immediately-following Repair owns materialization.
    @MainActor
    func installExactRemoteProjectRepairPlaceholder(
        teamName: String, hostKey: String, teamUUID: String, projectID: String,
        replacing expected: RemoteRepairPlaceholderGeneration? = nil
    ) async -> String? {
        guard !hostKey.isEmpty, !teamUUID.isEmpty, !projectID.isEmpty,
              (expected == nil ? teams[teamName] == nil : true),
              let host = RemoteHostStore.shared.sortedHosts.first(where: {
                  $0.id == hostKey && $0.isConnected && $0.teamHostSpec != nil
              }) else {
            return "Exact Project host or local name is unavailable"
        }
        let snapshot = await authoritativeCollaborationSnapshot(
            host: host, teamUUID: teamUUID, projectID: projectID
        )
        guard case .success(let authoritative) = snapshot,
              authoritative.team.name == teamName,
              authoritative.team.presentationOwnedByRequester,
              authoritative.team.leaderProcessActiveKnown,
              !authoritative.team.leaderProcessActive,
              let placeholder = Self.remoteProjectRepairPlaceholder(
                  remote: authoritative.team, hostKey: hostKey
              ) else {
            return "Exact owned inactive Project could not be reconstructed"
        }
        let installed: Bool
        if let expected {
            installed = replaceInertRemoteProjectRepairPlaceholder(
                expected: expected, replacement: placeholder
            )
        } else {
            installed = installRemoteProjectRepairPlaceholder(placeholder)
        }
        guard installed else {
            return "Exact Project identity changed before repair"
        }
        return nil
    }

    nonisolated static func remoteRepairPlaceholderGeneration(
        team: Team
    ) -> RemoteRepairPlaceholderGeneration? {
        guard team.isRemoteRepairPlaceholder, team.ownsRemotePresentation,
              !team.leaderReady, team.pairPanelId == nil,
              team.remoteWorkspaceIDs.isEmpty, team.remoteProjectLocations.isEmpty,
              let teamUUID = team.teamUuid?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ), !teamUUID.isEmpty,
              let projectID = team.remotePresentationProjectID?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ), !projectID.isEmpty,
              case .peer(let hostKey) = team.leaderEndpoint,
              !hostKey.isEmpty,
              team.agents.allSatisfy({
                  $0.panelId == nil
                      && $0.remoteSurfaceOwnerRemoteSockPath == nil
                      && $0.workspaceId == team.workspaceId
              })
        else { return nil }
        return RemoteRepairPlaceholderGeneration(
            hostKey: hostKey, teamUUID: teamUUID, projectID: projectID,
            workspaceID: team.workspaceId, leaderPanelID: team.leaderPanelId,
            revision: team.remotePresentationRevision, createdAt: team.createdAt,
            memberInstanceIDs: team.agents.map(\.agentInstanceId),
            memberSurfaceIDs: team.agents.map(\.remoteSurfaceID)
        )
    }

    @MainActor
    func inertRemoteRepairPlaceholderGeneration(
        teamName: String
    ) -> RemoteRepairPlaceholderGeneration? {
        guard let team = teams[teamName],
              let generation = Self.remoteRepairPlaceholderGeneration(team: team),
              AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId) == nil,
              AppDelegate.shared?.locateSurface(surfaceId: team.leaderPanelId) == nil,
              team.agents.allSatisfy({ agent in
                  AppDelegate.shared?.tabManagerFor(tabId: agent.workspaceId) == nil
                      && (agent.panelId.flatMap {
                          AppDelegate.shared?.locateSurface(surfaceId: $0)
                      }) == nil
              }),
              !hasPreservedProjectPresentation(teamName: teamName),
              WorkspaceProjectNames.shared.projectName(for: team.workspaceId) == nil,
              WorkspaceProjectNames.shared.projectID(for: team.workspaceId) == nil,
              remoteLeaderGrantIDs[teamName] == nil,
              remoteLeaderGrants[teamName] == nil,
              remoteLeaderGrantKeepalives[teamName] == nil,
              !remoteAgentRouteLeases.values.contains(where: {
                  $0.teamName == teamName
              }),
              !remoteAgentRouteKeepalives.values.contains(where: {
                  $0.teamName == teamName
              }),
              !remoteLeaderReattachInFlight.contains(teamName),
              !remoteLeaderRecoveryInFlight.contains(teamName),
              !projectRestoreInFlight.contains(teamName),
              remoteLeaderReconnectTasks[teamName] == nil,
              remoteProjectManifestTasks[teamName] == nil,
              remoteProjectManifestSignatures[teamName] == nil,
              publishedRemoteProjectAgentSurfaceIDs[teamName] == nil,
              !automaticProjectRestoreRetryTasks.keys.contains(where: { key in
                  key.hasPrefix(generation.hostKey + "\u{1f}")
                      && key.contains("\u{1f}" + generation.projectID + "\u{1f}")
              }),
              !peerAgentRecoveryInFlight.contains(where: {
                  $0.hasPrefix(teamName + "/")
              }),
              !PeerAgentPaneRecoveryCoordinator.shared.pending.contains(where: {
                  $0.teamName == teamName
              }),
              !projectDeletionSuppressions.contains(
                  Self.projectDeletionSuppressionKey(
                      hostID: generation.hostKey, projectID: generation.projectID
                  )
              )
        else { return nil }
        return generation
    }

    @MainActor
    func replaceInertRemoteProjectRepairPlaceholder(
        expected: RemoteRepairPlaceholderGeneration, replacement: Team
    ) -> Bool {
        guard let current = teams[replacement.id],
              inertRemoteRepairPlaceholderGeneration(teamName: replacement.id) == expected,
              let oldTeamUUID = current.teamUuid,
              let newTeamUUID = replacement.teamUuid,
              TeamDataStore.shared.replacePristinePlaceholderRegistration(
                  teamName: replacement.id,
                  expectedAgents: current.agents.map {
                      .init(name: $0.name, instanceId: $0.agentInstanceId)
                  },
                  expectedDelegationState: current.delegationState,
                  expectedTeamUUID: oldTeamUUID,
                  replacementAgents: replacement.agents.map {
                      .init(name: $0.name, instanceId: $0.agentInstanceId)
                  },
                  replacementDelegationState: replacement.delegationState,
                  replacementTeamUUID: newTeamUUID
              )
        else { return false }
        teams[replacement.id] = replacement
        syncTeamStateToDaemon()
        return true
    }

    nonisolated static func exactRemoteRepairPlaceholderCandidate(
        in remotes: [RemoteTeamSummary], teamName: String,
        teamUUID: String, projectID: String
    ) -> RemoteTeamSummary? {
        let matches = remotes.filter { remote in
            remote.name == teamName
                && remote.teamUUID == teamUUID
                && remote.projectID == projectID
                && remote.presentationOwnedByRequester
                && remote.leaderProcessActiveKnown
                && !remote.leaderProcessActive
                && !remote.leaderSurfaceID.isEmpty
        }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated static func exactRepairIdentityMatches(
        team: Team, hostKey: String, teamUUID: String, projectID: String
    ) -> Bool {
        guard case .peer(let actualHost) = team.leaderEndpoint else { return false }
        return actualHost == hostKey
            && team.teamUuid == teamUUID
            && team.remotePresentationProjectID == projectID
    }

    nonisolated static func shouldReleaseRemoteAgentsOnQuit(
        ownsRemotePresentation: Bool,
        hasPeerLeader: Bool,
        teamUUID: String?,
        agentSurfacePublished: Bool
    ) -> Bool {
        !(ownsRemotePresentation
            && hasPeerLeader
            && teamUUID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && agentSurfacePublished)
    }

    nonisolated static func automaticProjectRestoreFailureKey(
        hostID: String,
        activeSockPath: String,
        projectID: String,
        revision: UInt64
    ) -> String {
        [hostID, activeSockPath, projectID, String(revision)].joined(separator: "\u{1f}")
    }

    nonisolated static func projectDeletionSuppressionKey(
        hostID: String, projectID: String
    ) -> String {
        hostID + "\u{1f}" + projectID
    }

    nonisolated static func shouldTombstoneDeletedProject(
        ownsRemotePresentation: Bool
    ) -> Bool {
        ownsRemotePresentation
    }

    nonisolated static func automaticProjectRestoreRetryDelayNanoseconds(
        afterFailureCount failureCount: Int
    ) -> UInt64? {
        switch failureCount {
        case 1: return 1_000_000_000
        case 2: return 2_000_000_000
        case 3: return 4_000_000_000
        default: return nil
        }
    }

    nonisolated static func shouldRecoverRemoteLeaderOnHostReconnect(
        teamHostKey: String?, connectedHostKey: String, recoveryEligible: Bool
    ) -> Bool {
        teamHostKey == connectedHostKey && recoveryEligible
    }

    /// Recreate owned Project viewers as soon as the session-owner roster is
    /// available. Persistence is useful only when relaunch does not require a
    /// hidden Projects-sidebar button to materialize it again.
    func restoreOwnedRemoteProjectsIfNeeded(
        hosts: [HostEntry],
        tabManager: TabManager
    ) async {
        for host in hosts where host.isConnected && host.teamHostSpec != nil {
            let leaderRecoveryNames = teams.values.compactMap { team -> String? in
                guard !team.isRemoteRepairPlaceholder else { return nil }
                let teamHostKey: String? = {
                    guard case let .peer(key) = team.leaderEndpoint else { return nil }
                    return key
                }()
                return Self.shouldRecoverRemoteLeaderOnHostReconnect(
                    teamHostKey: teamHostKey,
                    connectedHostKey: host.id,
                    recoveryEligible: isRemoteLeaderRecoveryEligible(teamName: team.id)
                ) ? team.id : nil
            }
            for teamName in leaderRecoveryNames.sorted() {
                guard remoteLeaderReconnectTasks[teamName] == nil else { continue }
                remoteLeaderReconnectTasks[teamName] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.recoverRemoteLeaderIfNeeded(teamName: teamName)
                    self.remoteLeaderReconnectTasks.removeValue(forKey: teamName)
                }
            }

            let teamNames = Set(host.teams.map(\.name))
            for teamName in teamNames.sorted() where teams[teamName] == nil {
                let leaderRecord = ManagedPeerSurfaceStore.shared.leaderRecord(
                    hostKey: host.id,
                    teamName: teamName
                )
                guard let remote = Self.automaticRemoteProjectRestoreCandidate(
                    in: host.teams.filter { $0.name == teamName },
                    leaderRecord: leaderRecord
                ) else { continue }
                if let dead = Self.automaticRemoteProjectRepairPlaceholderCandidate(
                    in: host.teams.filter { $0.name == teamName },
                    leaderRecord: leaderRecord
                ), let placeholder = Self.remoteProjectRepairPlaceholder(
                    remote: dead, hostKey: host.id
                ) {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment[
                        "TERMMESH_E2E_DISABLE_AUTO_REPAIR_PLACEHOLDERS"
                    ] == "1" {
                        continue
                    }
                    #endif
                    _ = installRemoteProjectRepairPlaceholder(placeholder)
                    continue
                }
                let failureKey = Self.automaticProjectRestoreFailureKey(
                    hostID: host.id,
                    activeSockPath: host.activeSockPath,
                    projectID: remote.projectID,
                    revision: remote.presentationRevision
                )
                guard automaticProjectRestoreRetryTasks[failureKey] == nil,
                      (automaticProjectRestoreFailureAttempts[failureKey] ?? 0) < 4,
                      !projectRestoreInFlight.contains(remote.name),
                      !projectDeletionSuppressions.contains(
                        Self.projectDeletionSuppressionKey(
                            hostID: host.id, projectID: remote.projectID
                        )
                      ) else {
                    continue
                }
                let restored = await adoptRemoteProjectPresentation(
                    remote, host: host, tabManager: tabManager, selectWorkspace: false
                )
                if restored {
                    automaticProjectRestoreFailureAttempts.removeValue(forKey: failureKey)
                    automaticProjectRestoreRetryTasks.removeValue(forKey: failureKey)?.cancel()
                } else {
                    let failureCount = (automaticProjectRestoreFailureAttempts[failureKey] ?? 0) + 1
                    automaticProjectRestoreFailureAttempts[failureKey] = failureCount
                    guard let delay = Self.automaticProjectRestoreRetryDelayNanoseconds(
                        afterFailureCount: failureCount
                    ) else { continue }
                    automaticProjectRestoreRetryTasks[failureKey] = Task {
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled else { return }
                        self.automaticProjectRestoreRetryTasks.removeValue(forKey: failureKey)
                        await self.restoreOwnedRemoteProjectsIfNeeded(
                            hosts: RemoteHostStore.shared.sortedHosts,
                            tabManager: tabManager
                        )
                    }
                }
            }
        }
    }

    func persistProjectPresentationLayoutIfNeeded(workspace: Workspace) {
        guard !workspace.isApplyingProjectPresentationLayout,
              let team = teams.values.first(where: { $0.workspaceId == workspace.id }),
              team.ownsRemotePresentation,
              let projectID = team.remotePresentationProjectID
                ?? team.teamUuid.map(Self.remoteProjectPresentationID(teamUUID:)) ,
              let snapshot = workspace.projectPresentationLayoutSnapshot(projectID: projectID)
        else { return }
        ProjectPresentationLayoutStore.shared.save(snapshot)
    }

    func scheduleProjectPresentationLayoutSaveIfNeeded(workspace: Workspace) {
        guard !workspace.isApplyingProjectPresentationLayout,
              let team = teams.values.first(where: { $0.workspaceId == workspace.id }),
              team.ownsRemotePresentation,
              let projectID = team.remotePresentationProjectID
                ?? team.teamUuid.map(Self.remoteProjectPresentationID(teamUUID:))
        else { return }
        scheduleProjectPresentationLayoutSave(projectID: projectID, workspace: workspace)
    }

    enum ProjectPresentationLayoutRestoreOutcome: Equatable {
        case restoredSaved
        case rebuiltCanonical
        case failed
    }

    @discardableResult
    func resetProjectPresentationLayout(teamName: String) -> Bool {
        guard let team = teams[teamName],
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }),
              let projectID = team.remotePresentationProjectID
                ?? team.teamUuid.map(Self.remoteProjectPresentationID(teamUUID:)),
              workspace.peerSurfaceID(forPanelID: team.leaderPanelId) != nil
        else { return false }
        let agentPanelIDs = team.agents.compactMap { $0.panelId }
        guard agentPanelIDs.count == team.agents.count,
              agentPanelIDs.allSatisfy({ workspace.peerSurfaceID(forPanelID: $0) != nil })
        else { return false }
        return rebuildCanonicalProjectPresentationLayout(
            projectID: projectID,
            workspace: workspace,
            leaderPanelID: team.leaderPanelId,
            agentPanelIDs: agentPanelIDs,
            focusedSurfaceID: workspace.focusedPanelId.flatMap(
                workspace.peerSurfaceID(forPanelID:)
            ),
            restoreFocus: true,
            layoutStore: .shared
        )
    }

    @discardableResult
    func rebuildCanonicalProjectPresentationLayout(
        projectID: String,
        workspace: Workspace,
        leaderPanelID: UUID,
        agentPanelIDs: [UUID],
        focusedSurfaceID: Data?,
        restoreFocus: Bool,
        layoutStore: ProjectPresentationLayoutStore
    ) -> Bool {
        let panelIDs = [leaderPanelID] + agentPanelIDs
        guard Set(panelIDs).count == panelIDs.count,
              panelIDs.allSatisfy({ workspace.peerSurfaceID(forPanelID: $0) != nil })
        else { return false }
        let layout = workspace.bonsplitController.layoutSnapshot()
        let size = CGSize(
            width: CGFloat(layout.containerFrame.width),
            height: CGFloat(layout.containerFrame.height)
        )
        let columns = optimalGridDimensions(
            count: agentPanelIDs.count, containerSize: size, hasLeader: true
        ).cols
        let rebuilt = workspace.withProjectPresentationLayoutPersistenceSuppressed {
            workspace.applyCanonicalProjectPresentationGrid(
                leaderPanelID: leaderPanelID,
                agentPanelIDs: agentPanelIDs,
                columnCount: columns,
                focusedSurfaceID: focusedSurfaceID,
                restoreFocus: restoreFocus
            )
        }
        guard rebuilt,
              let snapshot = workspace.projectPresentationLayoutSnapshot(projectID: projectID)
        else { return false }
        layoutStore.save(snapshot)
        return true
    }

    @discardableResult
    func finalizeRestoredProjectLayout(
        projectID: String,
        workspace: Workspace,
        anchorPanelID: UUID?,
        leaderPanelID: UUID,
        agentPanelIDs: [UUID],
        restoreFocus: Bool,
        layoutStore providedLayoutStore: ProjectPresentationLayoutStore? = nil
    ) -> ProjectPresentationLayoutRestoreOutcome {
        let layoutStore = providedLayoutStore ?? ProjectPresentationLayoutStore.shared
        let saved = layoutStore.snapshot(projectID: projectID)
        let currentFocusedSurfaceID = workspace.focusedPanelId.flatMap(
            workspace.peerSurfaceID(forPanelID:)
        )
        let fallbackFocusedSurfaceID = saved?.focusedSurfaceID.flatMap { surfaceID in
            workspace.panelID(forPeerSurfaceID: surfaceID) == nil ? nil : surfaceID
        } ?? currentFocusedSurfaceID
        let restored = workspace.withProjectPresentationLayoutPersistenceSuppressed {
            if let anchorPanelID, workspace.panels.count > 1 {
                _ = workspace.closePanel(anchorPanelID, force: true)
            }
            guard let saved else { return false }
            return workspace.applyProjectPresentationLayout(saved, restoreFocus: restoreFocus)
        }
        if restored {
            // The saved snapshot already is the source of truth. Capturing the
            // background viewer's temporary focus here would overwrite its
            // focusedSurfaceID with the first pane.
            return .restoredSaved
        } else {
            let rebuilt = rebuildCanonicalProjectPresentationLayout(
                projectID: projectID,
                workspace: workspace,
                leaderPanelID: leaderPanelID,
                agentPanelIDs: agentPanelIDs,
                focusedSurfaceID: fallbackFocusedSurfaceID,
                restoreFocus: restoreFocus,
                layoutStore: layoutStore
            )
            if !rebuilt {
                settleRestoredAgentGrid(workspace: workspace)
                return .failed
            }
            return .rebuiltCanonical
        }
    }

    nonisolated static func remotePresentationIdentityMatches(
        localHostKey: String?,
        localProjectID: String?,
        remoteHostKey: String,
        remoteProjectID: String
    ) -> Bool {
        localHostKey == remoteHostKey && localProjectID == remoteProjectID
    }

    /// One Project id on both sides of publication. Owners used to publish
    /// `team:<uuid>` while keeping nil locally, so the sidebar compared the
    /// same Project as `name:<team>` versus `team:<uuid>`, rendered it twice,
    /// and then refused its misleading "Update" action as a name collision.
    nonisolated static func effectiveRemotePresentationProjectID(
        storedProjectID: String?,
        teamUUID: String?,
        teamName: String
    ) -> String {
        if let storedProjectID, !storedProjectID.isEmpty { return storedProjectID }
        if let teamUUID, !teamUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return remoteProjectPresentationID(teamUUID: teamUUID)
        }
        return "name:\(teamName)"
    }

    nonisolated static func remotePresentationIdentityMatches(
        team: Team,
        remote: RemoteTeamSummary,
        hostKey: String
    ) -> Bool {
        let localHostKey = team.remotePresentationHostKey ?? {
            if case let .peer(key) = team.leaderEndpoint { return key }
            return nil
        }()
        let localProjectID = effectiveRemotePresentationProjectID(
            storedProjectID: team.remotePresentationProjectID,
            teamUUID: team.teamUuid,
            teamName: team.id
        )
        return remotePresentationIdentityMatches(
            localHostKey: localHostKey,
            localProjectID: localProjectID,
            remoteHostKey: hostKey,
            remoteProjectID: remote.projectID
        )
    }

    /// Adopt a daemon-owned project discovered on a host into this window.
    /// Every pane attaches by the exact persisted surface id. No ensure,
    /// split, shell launch, or agent spawn is allowed on this path.
    @discardableResult
    func adoptRemoteProjectPresentation(
        _ remote: RemoteTeamSummary,
        host: HostEntry,
        tabManager: TabManager,
        selectWorkspace: Bool = true
    ) async -> Bool {
        guard !projectDeletionSuppressions.contains(
            Self.projectDeletionSuppressionKey(hostID: host.id, projectID: remote.projectID)
        ), Self.remoteManifestLeaderIsAdoptable(remote) else { return false }
        let namedTeam = teams[remote.name]
        let matchingTeam = namedTeam.flatMap {
            Self.remotePresentationIdentityMatches(
                team: $0,
                remote: remote,
                hostKey: host.id
            ) ? $0 : nil
        }
        // The app's runtime team namespace is name-keyed. A same-name project
        // on another host remains discoverable, but must never replace or
        // restore this unrelated team.
        guard namedTeam == nil || matchingTeam != nil else { return false }
        if let existing = matchingTeam,
           existing.ownsRemotePresentation
            || remote.presentationRevision <= existing.remotePresentationRevision {
            return await restoreDetachedProjectPresentation(
                teamName: remote.name,
                tabManager: tabManager
            )
        }
        guard !projectRestoreInFlight.contains(remote.name) else { return false }
        projectRestoreInFlight.insert(remote.name)
        defer { projectRestoreInFlight.remove(remote.name) }

        // Keep an existing viewer intact until every replacement surface has
        // attached. The final team swap is synchronous on MainActor, after
        // which only the obsolete local workspace is closed.
        let updateTarget = matchingTeam
        guard Self.remotePresentationCanAttach(
            leaderSurfaceID: remote.leaderSurfaceID,
            isConnected: host.isConnected,
            hasResolvedTeamRoute: host.teamHostSpec != nil
        )
        else { return false }

        let workspace = tabManager.addWorkspace(
            workingDirectory: remote.workingDirectory,
            select: selectWorkspace
        )
        let anchorPanelID = workspace.focusedPanelId
        workspace.customTitle = "[\(remote.name)]"
        workspace.title = "[\(remote.name)]"

        guard let leaderPanelID = await attachRestoredRemoteSurface(
            hostKey: host.id,
            surfaceID: remote.leaderSurfaceID,
            title: "Leader",
            panelTitle: "👑 Leader (Adopted)",
            workspace: workspace
        ) else {
            tabManager.closeWorkspace(workspace)
            return false
        }
        if remote.presentationOwnedByRequester {
            ManagedPeerSurfaceStore.shared.remember(
                hostKey: host.id,
                surfaceID: remote.leaderSurfaceID,
                teamName: remote.name,
                role: "leader",
                workingDirectory: remote.workingDirectory,
                teamUUID: remote.teamUUID,
                projectID: remote.projectID
            )
        }

        var members: [AgentMember] = []
        for descriptor in remote.members {
            let owningEndpoint = RestoredSurfaceEndpoint()
            guard let panelID = await attachRestoredRemoteSurface(
                hostKey: host.id,
                surfaceID: descriptor.surfaceID,
                title: descriptor.name,
                panelTitle: "\(Self.colorEmoji(descriptor.color)) \(descriptor.name)",
                workspace: workspace,
                owningRemoteSockPath: owningEndpoint,
                onAgentPanel: { panel, host in
                    Self.bindPeerOwnedAgentPanel(
                        panel: panel,
                        workspace: workspace,
                        teamName: remote.name,
                        agentName: descriptor.name,
                        agentInstanceId: descriptor.agentInstanceID,
                        color: descriptor.color,
                        hostDisplayName: host.displayName
                    )
                }
            ) else {
                tabManager.closeWorkspace(workspace)
                return false
            }
            members.append(AgentMember(
                id: "\(descriptor.name)@\(remote.name)",
                agentInstanceId: descriptor.agentInstanceID,
                name: descriptor.name,
                teamName: remote.name,
                cli: descriptor.cli,
                launchCommand: descriptor.cli,
                model: descriptor.model,
                agentType: descriptor.agentType,
                color: descriptor.color,
                instructions: "",
                workspaceId: workspace.id,
                panelId: panelID,
                createdAt: Date(),
                remoteSurfaceID: descriptor.surfaceID,
                remoteSurfaceSpawned: Self.adoptedAgentOwnsRemoteCleanup(
                    presentationOwnedByRequester: remote.presentationOwnedByRequester,
                    surfaceType: descriptor.surfaceType
                ),
                remoteAgentSurface: descriptor.surfaceType == "agent",
                // The endpoint whose lease proved this surface exists, reported
                // by the attach itself. Re-reading the store here would read it
                // after an await, and a reconnect landing in that window would
                // name an endpoint that never had the surface.
                remoteSurfaceOwnerRemoteSockPath: owningEndpoint.remoteSockPath,
                hostKey: host.id,
                originalAgentWorkDir: descriptor.workingDirectory
            ))
        }

        // Before anything is installed: every adopted worker must be holding a
        // grant this app owns, or the adoption does not happen at all. The
        // panes attach either way — it is `tm-agent send`/`inbox`/`reply` that
        // would silently address the previous viewer's revoked bearer.
        guard let routeTransfer = await mintAdoptedRemoteAgentRoutes(
            teamName: remote.name,
            teamUUID: remote.teamUUID,
            host: host,
            members: members
        ) else {
            tabManager.closeWorkspace(workspace)
            return false
        }
        let mintedRoutes = routeTransfer.workerGrants
        let mintedGrantIDs = routeTransfer.newlyMintedGrantIDs

        let leaderLaunch = Self.collaborationLeaderLaunchMetadata(
            remoteCLI: remote.leaderCLI, remoteModel: remote.leaderModel
        )
        var team = Team(
            id: remote.name,
            leaderSessionId: UUID().uuidString,
            leaderMode: "adopted",
            leaderModel: leaderLaunch.model,
            leaderCli: leaderLaunch.cli,
            leaderPanelId: leaderPanelID,
            leaderEndpoint: .peer(hostKey: host.id),
            workingDirectory: remote.workingDirectory,
            workspaceId: workspace.id,
            agents: members,
            createdAt: Date(),
            gitRepoRoot: remote.projectRootPath,
            worktreeMode: "off",
            teamUuid: remote.teamUUID,
            ownsRemotePresentation: remote.presentationOwnedByRequester,
            remotePresentationRevision: remote.presentationRevision,
            remotePresentationProjectID: remote.projectID,
            remotePresentationHostKey: host.id,
            remoteLeaderSurfaceID: remote.leaderSurfaceID
        )
        team.delegationState = remote.delegationState
        // A background pane is pending, while a selected workspace can finish
        // its relay before this team record is installed. Read the session's
        // actual state so neither ordering loses the readiness transition.
        team.leaderReady = workspace.terminalPanel(for: leaderPanelID)?
            .peerPaneSession?.isRelayStarted == true
        if !team.leaderReady {
            team.leaderFailureDescription = "Remote leader relay is pending"
        }
        if remote.leaderProcessActiveKnown, !remote.leaderProcessActive {
            team.leaderFailureDescription =
                "Remote leader surface exists, but no foreground leader process is running"
        }
        // Delete can land while the surface and route awaits above are in
        // flight. Re-check at the commit boundary; a start-only guard lets the
        // stale adoption resurrect the team after manifest deletion.
        guard !projectDeletionSuppressions.contains(
            Self.projectDeletionSuppressionKey(hostID: host.id, projectID: remote.projectID)
        ) else {
            _ = await Self.finishAdoptedRemoteAgentRoutes(
                host: host, transaction: routeTransfer.transaction, commit: false
            )
            await Self.revokeGrants(mintedGrantIDs)
            tabManager.closeWorkspace(workspace)
            return false
        }
        guard await Self.commitRemoteAgentRoutesPreservingGrants(
            host: host,
            transaction: routeTransfer.transaction,
            grantIDs: mintedGrantIDs,
            finalize: false
        ) else {
            tabManager.closeWorkspace(workspace)
            return false
        }
        if let updateTarget {
            let oldTabManager = AppDelegate.shared?.tabManagerFor(
                tabId: updateTarget.workspaceId
            )
            let replacementPresentationReady = tabManager.tabs.contains(where: {
                $0 === workspace
            }) && workspace.terminalPanel(for: leaderPanelID) != nil
                && members.allSatisfy { member in
                    guard member.workspaceId == workspace.id,
                          let panelID = member.panelId else { return false }
                    return member.remoteAgentSurface
                        ? workspace.agentPanel(for: panelID) != nil
                        : workspace.panels[panelID] != nil
                }
            let replacement = replaceAdoptedRemoteProject(
                team,
                expectedWorkspaceID: updateTarget.workspaceId,
                expectedRevision: updateTarget.remotePresentationRevision,
                replacementPresentationReady: replacementPresentationReady
            )
            guard replacement.replaced else {
                _ = await Self.finishAdoptedRemoteAgentRoutes(
                    host: host, transaction: routeTransfer.transaction, commit: false
                )
                await Self.revokeGrants(mintedGrantIDs)
                tabManager.closeWorkspace(workspace)
                return false
            }
            if let oldTabManager,
               let oldWorkspace = oldTabManager.tabs.first(where: {
                   $0.id == updateTarget.workspaceId
               }) {
                oldTabManager.closeTab(oldWorkspace)
            } else if let detached = replacement.detachedWorkspace {
                tabManager.attachWorkspace(detached, select: false)
                tabManager.closeTab(detached)
            }
        } else {
            guard installAdoptedRemoteProject(team) else {
                _ = await Self.finishAdoptedRemoteAgentRoutes(
                    host: host, transaction: routeTransfer.transaction, commit: false
                )
                await Self.revokeGrants(mintedGrantIDs)
                tabManager.closeWorkspace(workspace)
                return false
            }
        }
        // The running leader's hook command points at a deterministic path.
        // Replacing that file upgrades identity logging on its next turn,
        // without restarting the CLI or losing its conversation.
        if let hookData = Self.localLeaderTurnHookData() {
            if await Self.writeRemoteLeaderTurnHookOverSSH(
                host: host, hookData: hookData, teamUUID: remote.teamUUID
            ) == nil {
                recordRemoteAttachFailure(
                    teamName: remote.name,
                    description: "Turn hook refresh failed"
                )
            }
        }
        LeaderTurnLog.rememberIdentity(
            team: remote.name, teamUUID: remote.teamUUID,
            leaderSessionID: team.leaderSessionId
        )
        refreshLeaderParticipationControls()
        let adoptedSignature = Self.remoteProjectManifestSignature(
            team, hostKey: host.id
        )
        remoteProjectManifestSignatures[remote.name] = adoptedSignature
        publishedRemoteProjectAgentSurfaceIDs[remote.name] = Set(
            remote.members.map(\.surfaceID)
        )
        // Only now that the roster is real: the keepalive loop retires itself
        // when the team or the member is missing, so starting it any earlier
        // would have cancelled every lease on its first tick.
        startRemoteLeaderGrantKeepalive(
            teamName: remote.name, grant: routeTransfer.leaderGrant
        )
        for (agentInstanceID, grantID) in mintedRoutes {
            startRemoteAgentRouteKeepalive(
                teamName: remote.name,
                agentInstanceID: agentInstanceID,
                grantID: grantID
            )
        }
        if !(await Self.finalizeAdoptedRemoteAgentRoutes(
            host: host, transaction: routeTransfer.transaction
        )) {
            Self.scheduleAdoptedRemoteAgentRouteFinalize(
                host: host, transaction: routeTransfer.transaction
            )
        }
        WorkspaceProjectNames.shared.declare(
            workspaceId: workspace.id,
            projectName: remote.name,
            projectID: remote.projectID
        )
        finalizeRestoredProjectLayout(
            projectID: remote.projectID,
            workspace: workspace,
            anchorPanelID: anchorPanelID,
            leaderPanelID: leaderPanelID,
            agentPanelIDs: members.compactMap(\.panelId),
            restoreFocus: selectWorkspace
        )
        RemoteWorkLog.info(
            "Adopted live project \(remote.name) from \(host.displayName): "
                + "leader + \(members.count) existing agent surfaces"
        )
        return true
    }

    struct PeerShellCleanupItem: Identifiable, Equatable {
        enum State: Equatable {
            case inUse
            case managedOrphan
            case missingDirectory
            case unclaimed
        }

        let id: Data
        let title: String
        let workingDirectory: String
        let isBusy: Bool
        let state: State
        var isProtected: Bool { state == .inUse || isBusy }

        var idLabel: String { id.prefix(4).map { String(format: "%02x", $0) }.joined() }
    }

    /// `LocalizedError` is what puts `description` in front of the user. An
    /// alert reads `localizedDescription`, and a plain `Error` answers that
    /// with "(term_mesh.TeamOrchestrator.RemoteAgentError error 12.)" — so a
    /// deletion report naming every path that survived was being discarded at
    /// the one moment it mattered.
    enum RemoteAgentError: LocalizedError, CustomStringConvertible {
        case teamNotFound(String)
        case hostNotFound(String)
        case hostNotConnected(String)
        case noAttachableSurface(String)
        case noFreshSurface(String)
        case workspaceGone
        case paneCreationFailed
        case duplicateName(String)
        case duplicateInstance(String)
        case cliUnavailable(String, String)
        case promptStagingFailed(String)
        case environmentStagingFailed(String)
        case hostUpdateRequired(host: String, version: String?)
        case peerShellSweepTimedOut(host: String, seconds: Int)
        case durableAgentUnavailable(cli: String, host: String, reason: String)
        /// The peer never showed a pane in the workspace the leader was going to
        /// take. Everything after `host` is what the placement loop already knew
        /// and used to throw away: without it the failure reads as "it did not
        /// work" and there is nothing for the sheet's Troubleshoot to open.
        case projectWorkspaceUnavailable(
            host: String,
            workspaceID: String?,
            attempts: Int,
            seedRequested: Bool
        )
        case unresolvedRemoteWorkingDirectory(host: String, path: String)
        case checkoutIsolationFailed(host: String, path: String, reason: String)
        case projectDeletionIncomplete(String)
        case leaderAttachTimedOut(host: String, seconds: TimeInterval)
        case partialShellClose(closed: Int, failed: Int, reason: String)

        var description: String {
            switch self {
            case .teamNotFound(let name): return "no team named \(name)"
            case .hostNotFound(let key): return "no host \(key)"
            case .hostNotConnected(let name): return "\(name) is not connected"
            // Say what to do next. The likeliest cause is that every one of the
            // host's connection slots is held by an attached pane, and the
            // sweep needs one of its own — so the way out is to give one back,
            // and both ways of doing that are in the same menu as this sheet.
            case .peerShellSweepTimedOut(let name, let seconds):
                return "\(name) did not answer within \(seconds)s. Some panes may have "
                    + "closed — press Refresh to see. If it times out again, the host has "
                    + "no free connection slot: close remote panes you are not using, or "
                    + "use \"Close All Panes and Disconnect\" on the host, then try again."
            case .noAttachableSurface(let name): return "\(name) has no free surface to attach"
            case .noFreshSurface(let name):
                // The split request is fire-and-forget, so this is a timeout
                // rather than a refusal, and the person needs the likeliest
                // cause rather than the symptom. A host whose pane list still
                // names panes it no longer holds answers exactly this way.
                return "\(name) did not open a new shell for the leader — "
                    + "its pane list may still name panes that are no longer open, "
                    + "which reconnecting or restarting term-mesh there clears"
            case .workspaceGone: return "the team's workspace is gone"
            case .paneCreationFailed: return "could not open the remote pane"
            case .duplicateName(let name): return "the team already has an agent named \(name)"
            case .duplicateInstance(let id): return "the team already has agent instance \(id)"
            case .cliUnavailable(let cli, let host):
                return "\(cli) is not installed on \(host)"
            case .promptStagingFailed(let host):
                return "could not stage the leader prompt on \(host)"
            case .environmentStagingFailed(let host):
                return "could not stage the agent environment on \(host)"
            case .hostUpdateRequired(let host, let version):
                let serving = version.map { "term-mesh \($0)" } ?? "an unknown term-mesh version"
                return "\(host) is serving \(serving), which cannot route remote team messages; "
                    + "update and restart term-mesh on that host before adding agents"
            case .durableAgentUnavailable(let cli, let host, let reason):
                return "cannot create durable \(cli) agent on \(host): \(reason). "
                    + "A Project that must survive every viewer cannot use an SSH-owned fallback; "
                    + "update/restart the host and retry."
            case .projectWorkspaceUnavailable(let host, let workspaceID, let attempts, let seedRequested):
                var detail = "could not prepare the project workspace on \(host)"
                if let workspaceID {
                    detail += "; waited \(attempts) time(s) for a pane in workspace \(workspaceID)"
                    detail += seedRequested
                        ? " after asking it to open one"
                        : " without getting as far as asking for one"
                } else {
                    detail += "; the host never reported a workspace to place the leader in"
                }
                return detail
            case .unresolvedRemoteWorkingDirectory(let host, let path):
                return "could not resolve remote working directory for host \(host) "
                    + "from path \(path); specify --dir <remote-path> for that host"
            case .checkoutIsolationFailed(let host, let path, let reason):
                return "could not provision a dedicated checkout on \(host) from \(path): \(reason); "
                    + "refusing to reuse the requested checkout"
            case .projectDeletionIncomplete(let report):
                return "project deletion incomplete: \(report)"
            case .leaderAttachTimedOut(let host, let seconds):
                return "the leader on \(host) did not finish starting within "
                    + "\(Int(seconds))s; the host may be unreachable or the CLI may not be launching"
            case .partialShellClose(let closed, let failed, let reason):
                return "closed \(closed) shell(s); \(failed) refused — \(reason)"
            }
        }

        var errorDescription: String? { description }
    }

    typealias FailedLeaderSurfaceTerminator = @MainActor (
        PeerPaneHostSpec, Data
    ) async -> Bool
    typealias FailedLeaderSurfaceForgetter = @MainActor (String, Data) -> Void
    typealias FailedLeaderSurfaceEnqueuer = @MainActor (
        String, Data, String?
    ) -> Void

    /// Reap a leader surface created by an attach that never committed. The
    /// captured creation endpoint wins over the host's current route, and local
    /// teardown happens only after confirmation or a durable owner-aware
    /// tombstone exists.
    @MainActor
    static func compensateFailedLeaderSurface(
        hostKey: String,
        surfaceID: Data?,
        owningHostSpec: PeerPaneHostSpec?,
        terminate: FailedLeaderSurfaceTerminator,
        forgetManaged: FailedLeaderSurfaceForgetter,
        enqueueCleanup: FailedLeaderSurfaceEnqueuer,
        teardownLocal: @MainActor () -> Void
    ) async {
        defer { teardownLocal() }
        guard let surfaceID, !surfaceID.isEmpty else { return }
        let terminated = if let owningHostSpec {
            await terminate(owningHostSpec, surfaceID)
        } else {
            false
        }
        if terminated {
            forgetManaged(hostKey, surfaceID)
        } else {
            enqueueCleanup(
                hostKey, surfaceID,
                owningHostSpec.flatMap(failedLeaderOwningSocketPath)
            )
        }
    }

    nonisolated static func failedLeaderOwningSocketPath(
        _ spec: PeerPaneHostSpec
    ) -> String? {
        let path: String
        switch spec {
        case .direct(let sockPath): path = sockPath
        case .ssh(_, let remoteSockPath, _, _): path = remoteSockPath
        }
        return path.isEmpty ? nil : path
    }

    @MainActor
    private static func terminateFailedLeaderSurface(
        owningHostSpec: PeerPaneHostSpec, surfaceID: Data
    ) async -> Bool {
        guard let lease = try? await PeerPaneHostRegistry.shared.acquire(owningHostSpec)
        else { return false }
        defer { PeerPaneHostRegistry.shared.release(lease) }
        return await terminatePeerAgentSurfaceConfirmed(
            hostSockPath: lease.hostSockPath, surfaceID: surfaceID
        )
    }

    /// What happened to each participant that had to be attached over a peer,
    /// reported as it happens.
    ///
    /// `createTeam` returns as soon as the team exists, while the attaches run
    /// on behind it — so anything watching the return value sees a success that
    /// has not happened yet. The creation sheet used to close on exactly that,
    /// which is how a leader could fail to start with nobody left on screen to
    /// tell. `settled` is the signal that the attaches are done arguing and the
    /// caller may now decide what the result was.
    enum RemoteAttachOutcome: Equatable {
        case leaderAttached(host: String)
        case leaderFailed(host: String, message: String)
        case agentAttached(name: String, host: String)
        case agentFailed(name: String, host: String, message: String)
        /// Every attach this team asked for has finished, successfully or not.
        case settled
    }

    nonisolated static func requiredRemoteWorkingDirectory(
        _ path: String?,
        hostKey: String
    ) throws -> String {
        let resolved = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolved.isEmpty else {
            let suppliedPath: String
            if let path, !path.isEmpty {
                suppliedPath = String(reflecting: path)
            } else {
                suppliedPath = path == nil ? "<unset>" : "<empty>"
            }
            throw RemoteAgentError.unresolvedRemoteWorkingDirectory(
                host: hostKey,
                path: suppliedPath
            )
        }
        return resolved
    }

    private struct RemoteSurfacePlacement {
        let sourceID: Data
        let isDedicated: Bool
        /// A dedicated workspace's first shell is guaranteed to be clean, so
        /// the first project member can consume it directly. Later members
        /// split an existing project surface and stay in the same workspace.
        let useSourceDirectly: Bool
    }

    nonisolated static func remoteProjectWorkspaceTitle(teamName: String) -> String {
        let singleLine = teamName
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Project · \(String(singleLine.prefix(72)))"
    }

    struct LeaderAttachGeneration: Equatable, Sendable {
        let teamName: String
        let value: UInt64
    }

    @MainActor
    final class LeaderAttachGenerationGate {
        static let shared = LeaderAttachGenerationGate()
        private var generations: [String: UInt64] = [:]

        func begin(teamName: String) -> LeaderAttachGeneration {
            let value = (generations[teamName] ?? 0) &+ 1
            generations[teamName] = value
            return LeaderAttachGeneration(teamName: teamName, value: value)
        }

        func isCurrent(_ generation: LeaderAttachGeneration) -> Bool {
            generations[generation.teamName] == generation.value
        }

        func invalidate(_ generation: LeaderAttachGeneration) {
            guard isCurrent(generation) else { return }
            generations[generation.teamName] = generation.value &+ 1
        }

        /// The value in force now, for a caller that wants to notice a retirement
        /// without claiming a generation of its own.
        ///
        /// A remote agent attach is that caller: it is not the leader, so it has
        /// no attempt to carry, but it commits the same two things a deletion
        /// tears down — a surface record and a team member.
        func current(teamName: String) -> UInt64 {
            generations[teamName] ?? 0
        }

        func isCurrent(teamName: String, value: UInt64) -> Bool {
            current(teamName: teamName) == value
        }

        /// Retire whatever generation is current, for a caller that holds none.
        ///
        /// Project deletion is that caller. It tears down against a snapshot of
        /// the team taken when it starts, so an attach still in flight can
        /// register a surface or a checkout after that snapshot is read — and
        /// the deletion, already past it, leaves the remote process running
        /// with nothing left pointing at it. Retiring the generation first
        /// makes every remaining `ensureCurrent` throw and compensate instead.
        func invalidateAll(teamName: String) {
            generations[teamName] = (generations[teamName] ?? 0) &+ 1
        }
    }

    @MainActor
    final class LeaderAttachAttempt {
        let generation: LeaderAttachGeneration
        private var cleanup: (@MainActor () async -> Void)?
        private var cleanupStarted = false
        private var committed = false

        init(generation: LeaderAttachGeneration) {
            self.generation = generation
        }

        func installCleanup(_ cleanup: @escaping @MainActor () async -> Void) {
            self.cleanup = cleanup
        }

        var mayCommit: Bool {
            !cleanupStarted
                && !committed
                && !Task.isCancelled
                && LeaderAttachGenerationGate.shared.isCurrent(generation)
        }

        func ensureCurrent() async throws {
            guard mayCommit else {
                await compensate()
                throw CancellationError()
            }
        }

        func commit() {
            precondition(mayCommit, "stale remote-leader attach attempted to commit")
            committed = true
            cleanup = nil
        }

        func timeout() {
            LeaderAttachGenerationGate.shared.invalidate(generation)
            guard let cleanup = beginCompensation() else { return }
            Task { @MainActor in await cleanup() }
        }

        func compensate() async {
            guard let cleanup = beginCompensation() else { return }
            await cleanup()
        }

        private func beginCompensation() -> (@MainActor () async -> Void)? {
            guard !committed, !cleanupStarted, let cleanup else { return nil }
            cleanupStarted = true
            return cleanup
        }
    }

    @MainActor
    private final class LeaderAttachResources {
        let host: HostEntry
        let hostKey: String
        let workspace: Workspace
        var promptFile: String?
        var launchFile: String?
        var turnHookFile: String?
        var participationControlFile: String?
        var routeFilePath: String?
        var routeTransaction: String?
        var owningHostSpec: PeerPaneHostSpec?
        var hostSockPath: String
        var surfaceID: Data?
        var session: PeerPaneSession?
        var panelID: UUID?
        var grantID: Data?

        init(
            host: HostEntry,
            hostKey: String,
            workspace: Workspace,
            promptFile: String?
        ) {
            self.host = host
            self.hostKey = hostKey
            self.workspace = workspace
            self.promptFile = promptFile
            hostSockPath = TeamOrchestrator.liveTeamSockPath(for: host)
        }

        func cleanup() async {
            // Restore the previous canonical route before revoking the new
            // bearer. Reversing these two steps leaves a live route file that
            // points at a dead grant while rollback SSH is still in flight.
            var grantRevocationDeferred = false
            if let routeTransaction {
                let restored = await TeamOrchestrator.finishAdoptedRemoteAgentRoutes(
                    host: host, transaction: routeTransaction, commit: false
                )
                if !restored, let grantID {
                    TeamOrchestrator.rollbackRemoteAgentRoutesPreservingGrants(
                        host: host, transaction: routeTransaction, grantIDs: [grantID]
                    )
                    grantRevocationDeferred = true
                }
            } else if let routeFilePath {
                await TeamOrchestrator.removeRemoteLeaderFile(host: host, path: routeFilePath)
            }
            if let grantID, !grantRevocationDeferred {
                await PeerTeamLeaderControlPlane.shared.revokeGrant(id: grantID)
            }
            await TeamOrchestrator.compensateFailedLeaderSurface(
                hostKey: hostKey, surfaceID: surfaceID,
                owningHostSpec: owningHostSpec,
                terminate: { spec, surfaceID in
                    await TeamOrchestrator.terminateFailedLeaderSurface(
                        owningHostSpec: spec, surfaceID: surfaceID
                    )
                },
                forgetManaged: { hostKey, surfaceID in
                    ManagedPeerSurfaceStore.shared.forget(
                        hostKey: hostKey, surfaceID: surfaceID
                    )
                },
                enqueueCleanup: { hostKey, surfaceID, owningRemoteSockPath in
                    TeamOrchestrator.enqueuePendingPeerAgentSurfaceCleanup(
                        hostKey: hostKey, surfaceID: surfaceID,
                        owningRemoteSockPath: owningRemoteSockPath
                    )
                },
                teardownLocal: { [weak self] in
                    guard let self else { return }
                    if let panelID = self.panelID {
                        _ = self.workspace.closePanel(panelID, force: true)
                    } else {
                        self.session?.teardown()
                    }
                }
            )
            if let promptFile {
                await TeamOrchestrator.removeRemoteLeaderPrompt(
                    host: host,
                    promptFile: promptFile
                )
            }
            if let launchFile {
                await TeamOrchestrator.removeRemoteLeaderFile(
                    host: host,
                    path: launchFile
                )
            }
            if let turnHookFile {
                await TeamOrchestrator.removeRemoteLeaderFile(host: host, path: turnHookFile)
            }
            if let participationControlFile {
                await TeamOrchestrator.removeRemoteLeaderFile(
                    host: host, path: participationControlFile
                )
            }
        }
    }

    @MainActor
    private final class DetachedRestoreProgress {
        let workspace: Workspace
        let anchorPanelID: UUID?
        var leaderPanelID: UUID?
        var agentPanelIDs: [String: UUID] = [:]

        init(workspace: Workspace) {
            self.workspace = workspace
            anchorPanelID = workspace.focusedPanelId
        }
    }

    @MainActor
    private enum DetachedRestoreRegistry {
        static var progressByTeam: [String: DetachedRestoreProgress] = [:]
    }

    nonisolated static func newlyCreatedWorkspaceIDs(
        before: [Termmesh_Peer_V1_Workspace],
        after: [Termmesh_Peer_V1_Workspace],
        expectedTitle: String
    ) -> [Data] {
        let existing = Set(before.map(\.workspaceID))
        return after.compactMap { workspace in
            workspace.title == expectedTitle && !existing.contains(workspace.workspaceID)
                ? workspace.workspaceID
                : nil
        }
    }

    nonisolated static func missingRestoredAgentIDs(
        expected: [String],
        attached: Set<String>
    ) -> [String] {
        expected.filter { !attached.contains($0) }
    }

    /// How long the whole remote-leader attach may take before it is called a
    /// failure. Generous — it covers an ssh dial, a clone-sized wait on a
    /// cold host, and a CLI's first launch — because the point is to bound a
    /// stall, not to race a slow but working host.
    static let leaderAttachTimeout: TimeInterval = 180

    /// How often to re-check whether the leader's surface has a busy
    /// foreground process, after the launch command's keystrokes were
    /// delivered. Unbounded on its own — `attachRemoteLeader` runs inside
    /// `withLeaderAttachDeadline`, so `leaderAttachTimeout` above is what
    /// stops the poll, the same way it already stops every other step here.
    static let remoteLeaderForegroundPollInterval: TimeInterval = 0.5

    /// Settles on whichever of two outcomes arrives first and ignores the
    /// other. Deliberately not a task group: a group waits for every child
    /// before its scope may exit, so a child that ignores cancellation holds
    /// the timeout inside with it — the deadline fires, and nobody hears it.
    private actor AttachOutcome {
        private var result: Result<Void, Error>?
        private var waiter: CheckedContinuation<Void, Error>?

        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { waiter = $0 }
        }

        func settle(_ outcome: Result<Void, Error>) {
            guard result == nil else { return }
            result = outcome
            guard let waiter else { return }
            self.waiter = nil
            waiter.resume(with: outcome)
        }
    }

    /// Runs `body`, failing with `.leaderAttachTimedOut` if it has not
    /// finished within `leaderAttachTimeout`.
    ///
    /// A timed-out attach is abandoned rather than awaited. Cancellation is
    /// still requested, but this path reaches ssh and a remote shell, and
    /// waiting for those to notice is exactly the hang being bounded.
    static func withLeaderAttachDeadline(
        teamName: String,
        hostKey: String,
        timeout: TimeInterval = leaderAttachTimeout,
        _ body: @escaping @MainActor @Sendable (LeaderAttachAttempt) async throws -> Void
    ) async throws {
        let outcome = AttachOutcome()
        let generation = LeaderAttachGenerationGate.shared.begin(teamName: teamName)
        let attempt = LeaderAttachAttempt(generation: generation)
        let work = Task { @MainActor in
            do {
                try await body(attempt)
                await outcome.settle(.success(()))
            } catch {
                await attempt.compensate()
                await outcome.settle(.failure(error))
            }
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
#if DEBUG
            dlog("leader.deadline.fired host=\(hostKey)")
#endif
            attempt.timeout()
            await outcome.settle(
                .failure(RemoteAgentError.leaderAttachTimedOut(host: hostKey, seconds: timeout))
            )
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        try await outcome.wait()
    }

    private func waitForRemoteRemoval(
        hostSockPath: String,
        surfaceID: Data? = nil,
        workspaceID: Data? = nil
    ) async throws -> Bool {
        for attempt in 0..<15 {
            let isLastAttempt = attempt == 14
            // One failed probe is a missed observation, not a verdict — a
            // reconnect blip mid-poll must not abort a confirmation the next
            // attempt would have delivered. Only the final failure propagates.
            let workspaces: [Termmesh_Peer_V1_Workspace]
            do {
                let probe = try await PeerRelaySession.connect(hostSockPath: hostSockPath)
                do {
                    workspaces = try await probe.session.listWorkspaces(timeoutSeconds: 2)
                    await probe.cancel()
                } catch {
                    await probe.cancel()
                    throw error
                }
            } catch {
                guard !isLastAttempt else { throw error }
                try await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            if surfaceID != nil, !workspaces.isEmpty,
               !workspaces.contains(where: \.hasLayout) {
                // This host exposes no layouts, so its panes can never be
                // observed here — every poll would "confirm" removal no
                // matter what the host did. Proceed, but say so instead of
                // minting a confirmation the roster cannot back.
                RemoteWorkLog.info(
                    "Surface removal on \(hostSockPath) is unverifiable: the host lists no workspace layouts."
                )
                return true
            }
            let workspaceStillExists = workspaceID.map { target in
                workspaces.contains { $0.workspaceID == target }
            } ?? false
            let surfaceStillExists = surfaceID.map { target in
                workspaces.contains { workspace in
                    peerPaneSummaries(workspace.hasLayout ? workspace.layout : nil)
                        .contains { $0.id == target }
                }
            } ?? false
            if !workspaceStillExists && !surfaceStillExists { return true }
            if !isLastAttempt {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return false
    }

    private func remoteSurfacePlacement(
        teamName: String,
        host: HostEntry,
        fallbackSourceID: Data?,
        controlSockPath: String? = nil,
        leaderAttempt: LeaderAttachAttempt? = nil
    ) async throws -> RemoteSurfacePlacement? {
        guard let team = teams[teamName],
              team.usesDedicatedRemoteWorkspaces
        else {
            return fallbackSourceID.map {
                RemoteSurfacePlacement(
                    sourceID: $0,
                    isDedicated: false,
                    useSourceDirectly: false
                )
            }
        }
        let hostSockPath = controlSockPath ?? TeamOrchestrator.liveTeamSockPath(for: host)
        guard !hostSockPath.isEmpty else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }

        // When the caller already owns a pane-host lease, use that tunnel for
        // every setup RPC. The sidebar's `activeSockPath` is a separate,
        // reconnectable tunnel and can be stale even though the newly acquired
        // pane lease has just completed a successful ListSurfaces handshake.
        let connection = try await PeerRelaySession.connect(hostSockPath: hostSockPath)
        try await leaderAttempt?.ensureCurrent()
#if DEBUG
        dlog("leader.placement.stage connected host=\(host.id)")
#endif
        guard connection.hostCapabilities.has(PeerCapability.workspaceLifecycleV1) else {
            await connection.cancel()
            return fallbackSourceID.map {
                RemoteSurfacePlacement(
                    sourceID: $0,
                    isDedicated: false,
                    useSourceDirectly: false
                )
            }
        }
        var workspaceID = team.remoteWorkspaceIDs[host.id]
        var createdWorkspace = false
        do {
            if let cachedWorkspaceID = workspaceID {
#if DEBUG
                dlog("leader.placement.stage cached.list host=\(host.id)")
#endif
                let workspaces = try await connection.session.listWorkspaces(timeoutSeconds: 10)
                try await leaderAttempt?.ensureCurrent()
                if !workspaces.contains(where: { $0.workspaceID == cachedWorkspaceID }) {
                    // The host may have restarted or the user may have removed
                    // the workspace outside this app. Do not keep sending seed
                    // requests to an ID the authoritative roster no longer has.
                    forgetRemoteWorkspaceID(teamName: teamName, hostKey: host.id)
                    workspaceID = nil
                }
            }
            if workspaceID == nil {
#if DEBUG
                dlog("leader.placement.stage create.begin host=\(host.id)")
#endif
                let workspaceTitle = Self.remoteProjectWorkspaceTitle(teamName: teamName)
                let workspacesBeforeCreate = try await connection.session.listWorkspaces(
                    timeoutSeconds: 10
                )
                try await leaderAttempt?.ensureCurrent()
                do {
                    workspaceID = try await connection.session.createWorkspace(
                        title: workspaceTitle,
                        timeoutSeconds: 5
                    )
                } catch PeerSessionError.rpcTimedOut(_) {
                    await connection.cancel()
                    try await reconcileTimedOutWorkspaceCreation(
                        hostSockPath: hostSockPath,
                        host: host,
                        title: workspaceTitle,
                        workspacesBeforeCreate: workspacesBeforeCreate,
                        leaderAttempt: leaderAttempt
                    )
                    RemoteWorkLog.info(
                        "\(host.displayName) did not answer createWorkspace; "
                            + "reconciled the timed-out request before falling back"
                    )
                    return fallbackSourceID.map {
                        RemoteSurfacePlacement(
                            sourceID: $0,
                            isDedicated: false,
                            useSourceDirectly: false
                        )
                    }
                }
                try await leaderAttempt?.ensureCurrent()
                createdWorkspace = true
#if DEBUG
                dlog("leader.placement.stage create.ok host=\(host.id)")
#endif
            }
            guard let workspaceID else {
                await connection.cancel()
                throw RemoteAgentError.projectWorkspaceUnavailable(
                    host: host.displayName,
                    workspaceID: nil,
                    attempts: 0,
                    seedRequested: false
                )
            }

            let managedIDs = Set(
                ManagedPeerSurfaceStore.shared.records(hostKey: host.id)
                    .filter { $0.teamName == teamName }
                    .compactMap(\.surfaceID)
            )
            var requestedSeed = false
            var attemptsMade = 0
            for attempt in 0..<15 {
                attemptsMade = attempt + 1
#if DEBUG
                dlog("leader.placement.stage list host=\(host.id) attempt=\(attempt)")
#endif
                let workspaces = try await connection.session.listWorkspaces(timeoutSeconds: 10)
                try await leaderAttempt?.ensureCurrent()
                if let workspace = workspaces.first(where: { $0.workspaceID == workspaceID }),
                   let sourceID = peerPaneSummaries(workspace.hasLayout ? workspace.layout : nil)
                    .map(\.id)
                    .first {
                    let hasManagedProjectSurface = managedIDs.contains(sourceID)
                    if createdWorkspace {
                        recordRemoteWorkspaceID(
                            teamName: teamName,
                            hostKey: host.id,
                            workspaceID: workspaceID
                        )
                    }
                    await connection.cancel()
                    return RemoteSurfacePlacement(
                        sourceID: sourceID,
                        isDedicated: true,
                        useSourceDirectly: createdWorkspace || !hasManagedProjectSurface
                    )
                }
                // Re-ask every fifth pass rather than once. A single request
                // makes "the peer is still opening it" and "the request never
                // landed" the same fifteen-poll silence, and only one of those
                // is worth waiting through. Every fifth keeps the retry cheap
                // while still leaving a full second between asks.
                if !requestedSeed || attempt % 5 == 0 {
#if DEBUG
                    dlog("leader.placement.stage seed host=\(host.id) attempt=\(attempt)")
#endif
                    try await connection.session.requestNewTab(workspaceID: workspaceID)
                    try await leaderAttempt?.ensureCurrent()
                    requestedSeed = true
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw RemoteAgentError.projectWorkspaceUnavailable(
                host: host.displayName,
                workspaceID: workspaceID.prefix(4).map { String(format: "%02x", $0) }.joined(),
                attempts: attemptsMade,
                seedRequested: requestedSeed
            )
        } catch {
            if createdWorkspace, let workspaceID {
                // Creation is not committed until a seed surface exists.
                // Confirm compensation before dropping the connection. A
                // write completing only proves that the request entered the
                // socket, not that the host applied it.
                do {
                    try await connection.session.deleteWorkspace(workspaceID: workspaceID)
                } catch let cleanupError {
                    await connection.cancel()
                    throw RemoteAgentError.projectDeletionIncomplete(
                        "workspace setup failed with \(error); compensation failed with \(cleanupError)"
                    )
                }
                await connection.cancel()
                do {
                    guard try await waitForRemoteRemoval(
                        hostSockPath: hostSockPath,
                        workspaceID: workspaceID
                    ) else {
                        throw RemoteAgentError.projectDeletionIncomplete(
                            "workspace compensation was not confirmed on \(host.displayName)"
                        )
                    }
                } catch let cleanupError {
                    throw RemoteAgentError.projectDeletionIncomplete(
                        "workspace setup failed with \(error); compensation failed with \(cleanupError)"
                    )
                }
                throw error
            }
            await connection.cancel()
            throw error
        }
    }

    private func reconcileTimedOutWorkspaceCreation(
        hostSockPath: String,
        host: HostEntry,
        title: String,
        workspacesBeforeCreate: [Termmesh_Peer_V1_Workspace],
        leaderAttempt: LeaderAttachAttempt?
    ) async throws {
        var reconciledIDs = Set<Data>()
        for attempt in 0..<20 {
            try await leaderAttempt?.ensureCurrent()
            let probe = try await PeerRelaySession.connect(hostSockPath: hostSockPath)
            // The probe is cancelled exactly once on every path. It used to be
            // cancelled inside the `do`, after which the removal loop below
            // could still throw from the same block and the `catch` cancelled
            // it a second time.
            let candidates: [Data]
            do {
                let current = try await probe.session.listWorkspaces(timeoutSeconds: 2)
                let found = Self.newlyCreatedWorkspaceIDs(
                    before: workspacesBeforeCreate,
                    after: current,
                    expectedTitle: title
                )
                // Identity here is a generated title, and everything matched
                // gets deleted. One match is our own timed-out creation.
                // Several means another client created a same-titled
                // workspace inside the reconcile window, and we cannot tell
                // which is ours — deleting both destroys someone else's work,
                // while leaving them costs a stray workspace the user can
                // remove. Prefer the recoverable failure. A real fix needs a
                // creation request id on the wire.
                guard found.count <= 1 else {
                    // No cancel here: this throw is caught below, and that
                    // handler is what cancels. Doing it in both places is the
                    // double cancel the comment above says cannot happen.
                    throw RemoteAgentError.projectDeletionIncomplete(
                        "\(found.count) workspaces on \(host.displayName) match "
                            + "'\(title)'; refusing to delete an ambiguous match"
                    )
                }
                for workspaceID in found where reconciledIDs.insert(workspaceID).inserted {
                    try await probe.session.deleteWorkspace(workspaceID: workspaceID)
                }
                candidates = found
            } catch {
                await probe.cancel()
                throw error
            }
            await probe.cancel()

            if !candidates.isEmpty {
                for workspaceID in candidates {
                    guard try await waitForRemoteRemoval(
                        hostSockPath: hostSockPath,
                        workspaceID: workspaceID
                    ) else {
                        throw RemoteAgentError.projectDeletionIncomplete(
                            "timed-out workspace creation was not removed on \(host.displayName)"
                        )
                    }
                }
                return
            }
            if attempt < 19 {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw RemoteAgentError.projectDeletionIncomplete(
            "timed-out workspace creation could not be reconciled on \(host.displayName)"
        )
    }

    func inspectPeerShells(
        host: HostEntry,
        workspaceID: Data? = nil
    ) async throws -> [PeerShellCleanupItem] {
        let workspaces = workspaceID.map { id in
            host.workspaces.filter { $0.id == id }
        } ?? host.workspaces
        let panes = Dictionary(
            workspaces.flatMap(\.panes).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let claimed = claimedRemoteSurfaceIDs(host: host)
        let managed = Dictionary(
            ManagedPeerSurfaceStore.shared.records(hostKey: host.id).compactMap { record in
                record.surfaceID.map { ($0, record) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var seenPaths = Set<String>()
        let indexedPaths = panes.values
            .compactMap(\.workingDirectoryPath)
            .filter { !$0.isEmpty && seenPaths.insert($0).inserted }
        var missingPaths = Set<String>()
        if let sshTarget = host.sshTarget, !sshTarget.isEmpty, !indexedPaths.isEmpty {
            let checks = indexedPaths.enumerated().map { index, path in
                "if [ ! -d \(Self.shellQuoted(path)) ]; "
                    + "then printf 'MISSING \(index)\\n'; fi"
            }
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: checks.joined(separator: "\n") + "\ntrue",
                timeoutSeconds: 20
            )
            for line in output.split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count == 2, fields[0] == "MISSING",
                      let index = Int(fields[1]), indexedPaths.indices.contains(index)
                else { continue }
                missingPaths.insert(indexedPaths[index])
            }
        }

        return panes.values.map { pane in
            let path = pane.workingDirectoryPath ?? ""
            let state: PeerShellCleanupItem.State
            if claimed.contains(pane.id) {
                state = .inUse
            } else if managed[pane.id] != nil {
                state = .managedOrphan
            } else if !path.isEmpty && missingPaths.contains(path) {
                state = .missingDirectory
            } else {
                state = .unclaimed
            }
            return PeerShellCleanupItem(
                id: pane.id,
                title: pane.title,
                workingDirectory: path,
                isBusy: pane.isBusy,
                state: state
            )
        }
        .sorted {
            if $0.state != $1.state {
                return cleanupStateOrder($0.state) < cleanupStateOrder($1.state)
            }
            return $0.workingDirectory.localizedStandardCompare($1.workingDirectory)
                == .orderedAscending
        }
    }

    /// Sweeps leftover *shells*, which is why this one keeps the serving
    /// endpoint while the team lifecycle above moved to the session owner.
    ///
    /// Its targets come from `inspectPeerShells`, which reads `host.workspaces`
    /// — the roster the sidebar fetched over `activeSockPath`. Those surfaces
    /// belong to whatever is serving that socket, so a `ClosePane` addressed to
    /// a redirected host's daemon names a pane that daemon never published. The
    /// guard is worse than the send: `liveTeamSockPath` is empty until some
    /// pane has leased the team tunnel, so a perfectly connected GUI host would
    /// report itself disconnected before a single shell was tried.
    /// How long a whole sweep may take before it reports back.
    ///
    /// Every step inside has its own read timeout, but the sweep as a whole had
    /// none, so a dial that never answered left the sheet spinning with no
    /// error and no end — the one outcome a person cannot act on.
    static let peerShellSweepDeadlineSeconds: Double = 25

    func closePeerShells(
        host: HostEntry,
        surfaceIDs: Set<Data>,
        force: Bool = false
    ) async throws -> Int {
        let name = host.displayName
        return try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { [self] in
                try await performClosePeerShells(
                    host: host, surfaceIDs: surfaceIDs, force: force
                )
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.peerShellSweepDeadlineSeconds * 1_000_000_000)
                )
                throw RemoteAgentError.peerShellSweepTimedOut(
                    host: name, seconds: Int(Self.peerShellSweepDeadlineSeconds)
                )
            }
            guard let first = try await group.next() else {
                throw RemoteAgentError.peerShellSweepTimedOut(
                    host: name, seconds: Int(Self.peerShellSweepDeadlineSeconds)
                )
            }
            group.cancelAll()
            return first
        }
    }

    private func performClosePeerShells(
        host: HostEntry,
        surfaceIDs: Set<Data>,
        force: Bool
    ) async throws -> Int {
        guard !host.activeSockPath.isEmpty else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }
        let protected = claimedRemoteSurfaceIDs(host: host)
        let targets = Self.peerShellTargets(
            selected: surfaceIDs, protected: protected, force: force
        )
        guard !targets.isEmpty else { return 0 }
        if force { closeLocalPeerPanes(surfaceIDs: targets) }
        let rosterCheckpoint = RemoteHostStore.shared.peerShellCleanupCheckpoint(
            hostID: host.id, expectedSockPath: host.activeSockPath
        )
        var confirmedAbsent = Set<Data>()

        // Prefer a connection the host has already granted. Opening one here
        // is what made this sweep unusable: the host allows a fixed number of
        // concurrent peer connections and every attached pane holds one, so a
        // host with enough leftover shells to be worth sweeping has no slot
        // left to grant, and the dial came back as an EOF mid-handshake.
        //
        // The donor must not be one of the shells being closed. Borrowing a
        // target's own session sends its own death down its own connection:
        // the host drops the PTY without telling the client, so the local pane
        // stays attached to a stream that will never produce another byte, and
        // the sweep counts it as a clean close.
        var borrowed = borrowedRelaySession(
            hostKey: host.paneHostSpec.hostKey, excluding: targets
        )
        var opened: PeerRelayConnection?
        var dialFailed = false
        defer { if let opened { Task { await opened.cancel() } } }

        // Dial only once the borrowed session is gone. That death is also what
        // frees the slot this path was avoiding, so the sweep can finish on its
        // own connection rather than failing every remaining target.
        func sendClosePane(_ paneID: Data) async throws {
            if let session = borrowed {
                if try await session.requestClosePane(paneID) { return }
                borrowed = nil
            }
            if opened == nil {
                guard !dialFailed else {
                    throw RemoteAgentError.hostNotConnected(host.displayName)
                }
                do {
                    opened = try await PeerRelaySession.connect(
                        hostSockPath: host.activeSockPath
                    )
                } catch {
                    // Remember it: without this every remaining target pays for
                    // the same refused dial.
                    dialFailed = true
                    throw error
                }
            }
            try await opened?.session.requestClosePane(paneID: paneID)
        }
        func terminateSurface(_ paneID: Data) async throws
            -> Termmesh_Peer_V1_TerminateSurfaceResult {
            // Direct-response RPCs cannot share a relay session whose inbound
            // pump is active. Keep one dedicated connection for the whole
            // sweep instead of consuming a new host permit for every target.
            if opened == nil {
                let route = Self.peerShellTerminateRoute(
                    hasOpenedSession: false,
                    dialFailed: dialFailed,
                    hasBorrowedSession: borrowed != nil
                )
                if route == .dial {
                    do {
                        opened = try await PeerRelaySession.connect(
                            hostSockPath: host.activeSockPath
                        )
                    } catch {
                        // Disable future dials, but keep using the admitted
                        // borrowed session for every remaining target.
                        dialFailed = true
                    }
                }
                if opened == nil, let borrowed,
                   let result = try await borrowed.requestTerminateSurface(paneID) {
                    return result
                }
                if opened == nil {
                    throw RemoteAgentError.hostNotConnected(host.displayName)
                }
            }
            guard let session = opened?.session else {
                throw RemoteAgentError.hostNotConnected(host.displayName)
            }
            return try await session.terminateSurface(
                surfaceID: paneID, timeoutSeconds: 5
            )
        }
        func applyAuthoritativeAbsence() {
            guard let rosterCheckpoint else { return }
            _ = RemoteHostStore.shared.removeAuthoritativelyAbsentPeerShells(
                confirmedAbsent, checkpoint: rosterCheckpoint
            )
        }
        do {
            let closed = try await Self.sweepClose(targets: targets, send: { surfaceID in
                let confirmed = try await Self.closePeerShellConfirmed(
                    surfaceID: surfaceID,
                    force: force,
                    terminate: { try await terminateSurface(surfaceID) },
                    closePane: { try await sendClosePane(surfaceID) },
                    confirmRemoved: {
                        if let session = opened?.session {
                            return try await self.waitForPeerShellRemoval(
                                session: session, surfaceID: surfaceID
                            )
                        }
                        if RemoteHostStore.shared.hosts[host.id] != nil {
                            // A borrowed session on an older host cannot
                            // produce an authoritative roster response. Fail
                            // immediately instead of polling the same stale
                            // cache for 25 seconds.
                            return false
                        }
                        return try await self.waitForRemoteRemoval(
                            hostSockPath: host.activeSockPath,
                            surfaceID: surfaceID
                        )
                    }
                )
                if confirmed { confirmedAbsent.insert(surfaceID) }
            }) { surfaceID in
                ManagedPeerSurfaceStore.shared.forget(hostKey: host.id, surfaceID: surfaceID)
            }
            applyAuthoritativeAbsence()
            return closed
        } catch {
            applyAuthoritativeAbsence()
            throw error
        }
    }

    enum PeerShellTerminateRoute: Equatable {
        case opened, dial, borrowed, unavailable
    }

    nonisolated static func peerShellTerminateRoute(
        hasOpenedSession: Bool,
        dialFailed: Bool,
        hasBorrowedSession: Bool
    ) -> PeerShellTerminateRoute {
        if hasOpenedSession { return .opened }
        if !dialFailed { return .dial }
        return hasBorrowedSession ? .borrowed : .unavailable
    }

    @MainActor
    private func waitForStoredPeerShellRemoval(
        hostID: String,
        surfaceID: Data
    ) async throws -> Bool {
        for attempt in 0..<15 {
            guard let current = RemoteHostStore.shared.hosts[hostID] else {
                return false
            }
            let stillExists = current.workspaces
                .flatMap(\.panes)
                .contains { $0.id == surfaceID }
            if !stillExists { return true }
            if attempt < 14 {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return false
    }

    /// Confirm on the same direct-response connection that carried ClosePane.
    /// Older GUI hosts do not advertise TerminateSurface, but they do process
    /// envelopes serially, so this full roster is ordered after the close and
    /// cannot race a snapshot from another connection.
    private func waitForPeerShellRemoval(
        session: PeerSession,
        surfaceID: Data
    ) async throws -> Bool {
        for attempt in 0..<15 {
            let workspaces = try await session.listWorkspaces(timeoutSeconds: 2)
            let stillExists = workspaces.contains { workspace in
                workspace.hasLayout && peerSurfaceIDs(workspace.layout).contains(surfaceID)
            }
            if !stillExists { return true }
            if attempt < 14 {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return false
    }

    /// Close one cleanup target only after the host has authoritatively removed
    /// it. `ClosePane` is fire-and-forget and deliberately ignores the final
    /// pane in a workspace, so successful frame delivery is not successful
    /// cleanup. Force mode first uses `TerminateSurface`, whose response is
    /// authoritative and can remove the final pane; older hosts that return
    /// `.notFound` fall back to ClosePane plus roster polling.
    /// Returns true when a correlated terminate response or an ordered roster
    /// read authoritatively proved the exact surface absent.
    static func closePeerShellConfirmed(
        surfaceID: Data,
        force: Bool,
        terminate: () async throws -> Termmesh_Peer_V1_TerminateSurfaceResult,
        closePane: () async throws -> Void,
        confirmRemoved: () async throws -> Bool
    ) async throws -> Bool {
        if force, let result = try? await terminate(),
           result == .terminated || result == .notFound {
            return true
        }
        try await closePane()
        guard try await confirmRemoved() else {
            throw RemoteAgentError.projectDeletionIncomplete(
                "host did not confirm removal of shell "
                    + surfaceID.prefix(4).map { String(format: "%02x", $0) }.joined()
            )
        }
        return true
    }

    /// Close local viewers before force-ending their remote surfaces. Leaving
    /// one attached creates a zombie pane whose stream can never produce
    /// another byte, which is less honest than the current refusal.
    @MainActor
    private func closeLocalPeerPanes(surfaceIDs: Set<Data>) {
        guard let app = AppDelegate.shared else { return }
        let workspaces = app.mainWindowContexts.values.flatMap { $0.tabManager.tabs }
        _ = Self.closePeerSurfaceViewers(surfaceIDs: surfaceIDs, workspaces: workspaces)
    }

    nonisolated static func peerShellTargets(
        selected: Set<Data>,
        protected: Set<Data>,
        force: Bool
    ) -> Set<Data> {
        force ? selected : selected.subtracting(protected)
    }

    @MainActor
    @discardableResult
    static func closePeerSurfaceViewers(
        surfaceIDs: Set<Data>,
        workspaces: [Workspace]
    ) -> Int {
        var closed = 0
        for workspace in workspaces {
            let panels = surfaceIDs.compactMap(workspace.panelID(forPeerSurfaceID:))
            for panelID in panels where workspace.closePanel(panelID, force: true) {
                closed += 1
            }
        }
        return closed
    }

    nonisolated static func protectedPeerShellCount(
        items: [PeerShellCleanupItem],
        selection: Set<Data>
    ) -> Int {
        items.count { selection.contains($0.id) && $0.isProtected }
    }

    /// Attempt every target, count what actually closed, and report the
    /// shortfall as one error.
    ///
    /// One shell refusing to close must not strand the ones behind it. A sweep
    /// here is routinely dozens long, and aborting on the first failure left
    /// the caller no way to tell "nothing closed" from "most of them did" — so
    /// every target is attempted and the count comes with the failure.
    ///
    /// Split from `closePeerShells` because the counting is the part worth
    /// testing and the rest of that function is session lookup: which
    /// connection to borrow, when to dial. Those need a live host; this does
    /// not.
    static func sweepClose(
        targets: Set<Data>,
        send: (Data) async throws -> Void,
        onClosed: (Data) -> Void = { _ in }
    ) async throws -> Int {
        var closed = 0
        var firstFailure: Error?
        for surfaceID in targets {
            do {
                try await send(surfaceID)
                onClosed(surfaceID)
                closed += 1
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            throw RemoteAgentError.partialShellClose(
                closed: closed,
                failed: targets.count - closed,
                reason: String(describing: firstFailure)
            )
        }
        return closed
    }

    /// Every open pane whose shell runs on `hostKey`.
    ///
    /// Shared by the two callers that need to know which of the host's
    /// surfaces this app is currently holding — one to protect them, one to
    /// borrow a connection from them.
    private func peerPaneSessions(hostKey: PeerPaneHostKey) -> [PeerPaneSession] {
        guard let app = AppDelegate.shared else { return [] }
        var result: [PeerPaneSession] = []
        for context in app.mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values {
                    guard let terminal = panel as? TerminalPanel,
                          let session = terminal.peerPaneSession,
                          !session.isTorndown,
                          session.lease.key == hostKey
                    else { continue }
                    result.append(session)
                }
            }
        }
        return result
    }

    /// A live relay session on `hostKey`, to carry control requests that are
    /// about the host rather than about one pane. Control frames are
    /// fire-and-forget and carry their own pane id, so which pane's session
    /// delivers them does not matter — only that the host already granted it,
    /// and that it is not itself one of the panes being acted on.
    private func borrowedRelaySession(
        hostKey: PeerPaneHostKey,
        excluding targets: Set<Data>
    ) -> PeerRelaySession? {
        peerPaneSessions(hostKey: hostKey)
            .first { !targets.contains($0.originSurface.surfaceID) }?
            .relaySession
    }

    /// Surfaces on `host` that this app is already using, which a cleanup
    /// sweep must never close.
    ///
    /// Three kinds, equally in use: a team agent's surface, a team leader's,
    /// and — the one this originally missed — any remote pane the user simply
    /// has open. The cleanup sheet promises "tracked shells are protected",
    /// and a pane sitting on screen is the most visible kind of tracked there
    /// is; leaving it out bucketed it as `unclaimed`, which Select All then
    /// swept up.
    private func claimedRemoteSurfaceIDs(host: HostEntry) -> Set<Data> {
        let hostKey = host.id
        var result = Set(
            teams.values
                .flatMap(\.agents)
                .filter { $0.hostKey == hostKey }
                .compactMap(\.remoteSurfaceID)
        )
        for team in teams.values {
            guard team.leaderEndpoint == .peer(hostKey: hostKey) else { continue }
            if let surfaceID = team.remoteLeaderSurfaceID {
                result.insert(surfaceID)
                continue
            }
            if let record = ManagedPeerSurfaceStore.shared.leaderRecord(
                hostKey: hostKey,
                teamName: team.id
            ), let surfaceID = record.surfaceID {
                // The project owns the remote leader surface even when no
                // local viewer is attached. Never offer it as an orphan while
                // the project/team record is still live.
                result.insert(surfaceID)
                continue
            }
            if let located = AppDelegate.shared?.locateSurface(surfaceId: team.leaderPanelId),
               let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
               let session = workspace.terminalPanel(for: team.leaderPanelId)?.peerPaneSession {
                result.insert(session.originSurface.surfaceID)
            }
        }
        // Both endpoints, because a redirected host has panes on each: ordinary
        // remote terminals lease `paneHostSpec`, team agents lease the session
        // owner. Asking only the team key was a regression with the sweep's own
        // failure mode — an on-screen pane it could not see was bucketed
        // `unclaimed`, and Select All closed it. Asking only the pane key would
        // lose agent surfaces the same way.
        var protectedKeys: Set<PeerPaneHostKey> = [host.paneHostSpec.hostKey]
        if let teamKey = host.teamHostSpec?.hostKey { protectedKeys.insert(teamKey) }
        for key in protectedKeys {
            result.formUnion(
                peerPaneSessions(hostKey: key).map(\.originSurface.surfaceID)
            )
        }
        return result
    }

    private func cleanupStateOrder(_ state: PeerShellCleanupItem.State) -> Int {
        switch state {
        case .managedOrphan: return 0
        case .missingDirectory: return 1
        case .unclaimed: return 2
        case .inUse: return 3
        }
    }

    /// Replace the inert local anchor with a pane whose process runs on
    /// `hostKey`. The remote process receives only an expiring scoped
    /// grant and its own daemon socket; the viewer's TERMMESH_SOCKET is never
    /// copied across the peer boundary.
    @MainActor
    /// The second half of a leader failure that nothing else reports.
    ///
    /// `rpcTimedOut(operation: "listWorkspaces")` names the symptom and stops
    /// there, and on a Mac peer the cause is often processes left behind by an
    /// earlier run of the app. Asking once, on the way out, turns a message
    /// nobody can act on into one that says where to go. Returns nil for Linux
    /// hosts (their daemon outliving the app is correct), for unreachable
    /// hosts, and whenever there is nothing to report — the failure text is
    /// then left exactly as it was.
    static func staleDaemonHint(hostKey: String) async -> String? {
        guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              let target = host.sshTarget, !target.isEmpty,
              let snapshot = await PeerHostDoctor.daemonSnapshot(
                sshTarget: target, port: host.sshPort, identityFile: host.identityFile
              )
        else { return nil }
        let stale = PeerHostDoctor.staleDaemons(in: snapshot)
        guard !stale.isEmpty else { return nil }
        let pids = stale.map { String($0.pid) }.joined(separator: ", ")
        return " — this host is also running \(stale.count) term-meshd process(es) that serve nothing"
            + " (pid \(pids)); Edit Peer Host → Clean Up Daemons stops them"
    }

    /// Whether a remote leader launch needs foreground confirmation at all.
    /// `repl`/`adopted` never launch a CLI on this path — there is nothing
    /// running for the peer to report as busy, so gating on it would fail
    /// every attach in those modes.
    nonisolated static func remoteLeaderNeedsForegroundConfirmation(leaderMode: String) -> Bool {
        leaderMode != "repl" && leaderMode != "adopted"
    }

    /// Whether one `listSurfaces` snapshot already confirms the leader's
    /// surface has a live foreground process. `foregroundBusyKnown` is
    /// required, not just `foregroundBusy`, so a host that cannot answer the
    /// question at all (older peer, capability gap) reads as "not yet",
    /// never as a false confirmation.
    nonisolated static func remoteLeaderSurfaceConfirmsForeground(
        surfaces: [Termmesh_Peer_V1_SurfaceInfo],
        surfaceID: Data
    ) -> Bool {
        guard let surface = surfaces.first(where: { $0.surfaceID == surfaceID }) else {
            return false
        }
        return surface.foregroundBusyKnown && surface.foregroundBusy
    }

    /// Confirm the just-launched remote leader actually took over its
    /// shell's foreground, instead of accepting a silently-failed launch
    /// (missing binary, PATH, a permission error) as success.
    /// `sendRemoteLeaderStage` only confirms the launch command's keystrokes
    /// were delivered and the relay transport is up — neither says anything
    /// about what is now running in the shell. This reuses the same
    /// `foreground_busy`/`foreground_busy_known` peer signal the leader
    /// restore path already reads off `listSurfaces` (no new protocol).
    ///
    /// Polls until confirmed with no budget of its own: `attachRemoteLeader`
    /// runs inside `withLeaderAttachDeadline`, whose `leaderAttachTimeout`
    /// already bounds this call the same way it bounds every other step in
    /// that function. On timeout the deadline cancels the enclosing `Task`,
    /// `Task.sleep` below throws `CancellationError` instead of swallowing
    /// it, and that propagates out to the caller's existing
    /// compensate-and-rethrow handling — settling as the deadline's own
    /// `leaderAttachTimedOut`, not a second bespoke error.
    private func confirmRemoteLeaderForeground(
        host: HostEntry,
        surfaceID: Data,
        leaderMode: String
    ) async throws {
        guard Self.remoteLeaderNeedsForegroundConfirmation(leaderMode: leaderMode) else { return }
        while true {
            let lease = try? await PeerPaneHostRegistry.shared.acquire(
                Self.requireTeamHostSpec(host)
            )
            if let lease {
                let surfaces = try? await PeerPaneSession.listSurfaces(on: lease)
                PeerPaneHostRegistry.shared.release(lease)
                let confirmed = surfaces.map {
                    Self.remoteLeaderSurfaceConfirmsForeground(surfaces: $0, surfaceID: surfaceID)
                } ?? false
                if confirmed { return }
            }
            try await Task.sleep(
                nanoseconds: UInt64(Self.remoteLeaderForegroundPollInterval * 1_000_000_000)
            )
        }
    }

    private func confirmRemoteLeaderPrompt(
        panel: TerminalPanel,
        host: HostEntry,
        surfaceID: Data,
        leaderMode: String
    ) async throws {
        guard Self.remoteLeaderNeedsForegroundConfirmation(leaderMode: leaderMode) else { return }
        var stableObservations = 0
        var answeredStartupPrompt = false
        while true {
            try Task.checkCancellation()
            let hostLease = try? await PeerPaneHostRegistry.shared.acquire(
                Self.requireTeamHostSpec(host)
            )
            let foregroundConfirmed: Bool
            if let hostLease {
                let surfaces = try? await PeerPaneSession.listSurfaces(on: hostLease)
                PeerPaneHostRegistry.shared.release(hostLease)
                foregroundConfirmed = surfaces.map {
                    Self.remoteLeaderSurfaceConfirmsForeground(
                        surfaces: $0, surfaceID: surfaceID
                    )
                } ?? false
            } else {
                foregroundConfirmed = false
            }
            if foregroundConfirmed, let lease = panel.surface.beginReadLease() {
                let text: String? = await withCheckedContinuation {
                    (continuation: CheckedContinuation<String?, Never>) in
                    Self.localLeaderReadinessQueue.async {
                        let value = Self.readLocalLeaderPane(lease.surface)
                        lease.release()
                        continuation.resume(returning: value)
                    }
                }
                // Every first-run prompt, not just codex's. Claude's folder
                // trust used to be excluded here, and nothing else answers a
                // leader: `AutoReplyPoller` only walks `team.agents`, which a
                // leader is not in. So a Claude leader on a freshly cloned
                // remote checkout sat on the trust screen until this loop timed
                // out at 180s and the whole Project failed to start.
                //
                // The keys are a sequence, not one Return. Claude now defaults
                // its selection to "No, exit", so committing without moving the
                // caret first quits the CLI — the failure this is meant to
                // prevent, delivered faster.
                if !answeredStartupPrompt,
                   let answer = text.flatMap(AgentStartupPrompt.answer(in:)) {
                    answeredStartupPrompt = true
                    guard let peerSession = panel.peerPaneSession else {
                        throw RemoteAgentError.paneCreationFailed
                    }
                    for key in answer.keys {
                        guard let bytes = AgentStartupPrompt.remoteBytes(forKey: key),
                              try await peerSession.relaySession.sendRemoteKeys(bytes) else {
                            throw RemoteAgentError.paneCreationFailed
                        }
                        // Let the TUI redraw its selection before the next key;
                        // a commit that races the caret answers the wrong row.
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                    stableObservations = 0
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            Self.remoteLeaderForegroundPollInterval * 1_000_000_000
                        )
                    )
                    continue
                }
                stableObservations = text.map {
                    Self.localLeaderPaneLooksReady($0, leaderMode: leaderMode)
                } == true
                    ? stableObservations + 1 : 0
                if stableObservations >= Self.localLeaderStablePromptObservations { return }
            } else {
                stableObservations = 0
            }
            try await Task.sleep(
                nanoseconds: UInt64(Self.remoteLeaderForegroundPollInterval * 1_000_000_000)
            )
        }
    }

    func attachRemoteLeader(
        teamName: String,
        hostKey: String,
        workingDirectory: String,
        cli: String,
        model: String,
        attempt: LeaderAttachAttempt,
        systemPrompt: String? = nil
    ) async throws {
        guard let team = teams[teamName] else { throw RemoteAgentError.teamNotFound(teamName) }
        guard let teamUUID = team.teamUuid else { throw RemoteAgentError.teamNotFound(teamName) }
        let host = try await Self.waitForTeamHostLaunchReadiness(hostKey: hostKey)
        var promptFile = systemPrompt.map { _ in
            "/tmp/term-mesh-leader-prompt-\(teamUUID).txt"
        }
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }) else {
            throw RemoteAgentError.workspaceGone
        }
        let resources = LeaderAttachResources(
            host: host,
            hostKey: hostKey,
            workspace: workspace,
            promptFile: promptFile
        )
        attempt.installCleanup { await resources.cleanup() }
        try await attempt.ensureCurrent()

        let owningHostSpec = try Self.requireTeamHostSpec(host)
        resources.owningHostSpec = owningHostSpec
        let lease = try await PeerPaneHostRegistry.shared.acquire(owningHostSpec)
        resources.hostSockPath = lease.hostSockPath
        try await attempt.ensureCurrent()
#if DEBUG
        dlog("leader.attach.stage acquired host=\(hostKey)")
#endif
        let session: PeerPaneSession
        do {
            let surfaces = try await PeerPaneSession.listSurfaces(on: lease)
            try await attempt.ensureCurrent()
#if DEBUG
            dlog("leader.attach.stage listed host=\(hostKey) surfaces=\(surfaces.count)")
#endif
            // `attachable` only means another viewer may attach. It says
            // nothing about what the surface is running. Reusing one here can
            // paste the bootstrap grant into an already-running Claude pane,
            // where Claude answers the shell command as prose and the new
            // project silently inherits the old relay.
            //
            // Reserve a fresh shell exactly as remote agents do. Falling back
            // to an existing surface would recreate the credential leak this
            // path is preventing, so an old/full host must fail visibly.
            guard let placement = try await remoteSurfacePlacement(
                teamName: teamName,
                host: host,
                fallbackSourceID: surfaces.first?.surfaceID,
                controlSockPath: lease.hostSockPath,
                leaderAttempt: attempt
            ) else {
                throw RemoteAgentError.noFreshSurface(host.displayName)
            }
#if DEBUG
            dlog("leader.attach.stage placed host=\(hostKey) direct=\(placement.useSourceDirectly)")
#endif
            let chosen: Termmesh_Peer_V1_SurfaceInfo?
            if placement.useSourceDirectly {
                let refreshed = try await PeerPaneSession.listSurfaces(on: lease)
                try await attempt.ensureCurrent()
                chosen = refreshed.first { $0.surfaceID == placement.sourceID }
            } else {
                chosen = try await PeerPaneSession.spawnSurface(
                    on: lease,
                    splitting: placement.sourceID
                )
                try await attempt.ensureCurrent()
            }
            guard let chosen else {
                throw RemoteAgentError.noFreshSurface(host.displayName)
            }
#if DEBUG
            dlog("leader.attach.stage spawned host=\(hostKey)")
#endif
            resources.surfaceID = chosen.surfaceID
            ManagedPeerSurfaceStore.shared.remember(
                hostKey: hostKey,
                surfaceID: chosen.surfaceID,
                teamName: teamName,
                role: "leader",
                workingDirectory: workingDirectory,
                teamUUID: teamUUID,
                projectID: team.remotePresentationProjectID
                    ?? PeerTeamLeader.projectID(
                        teamName: teamName, teamUUID: teamUUID
                    )
            )
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: chosen,
                title: "Leader",
                spec: Self.requireTeamHostSpec(host)
            )
            resources.session = session
            try await attempt.ensureCurrent()
#if DEBUG
            dlog("leader.attach.stage session host=\(hostKey)")
#endif
        } catch {
            await attempt.compensate()
            PeerPaneHostRegistry.shared.release(lease)
            throw error
        }
        PeerPaneHostRegistry.shared.release(lease)

        let remoteEnvironment = Self.configuredRemoteAgentEnvironment(
            profile: CLIPathSettings.env(for: cli),
            explicitHost: PeerHostEnvironment.stored(forHostKey: host.id)
        )
        do {
#if DEBUG
            dlog("leader.attach.stage prepare.begin host=\(hostKey)")
#endif
            if let environment = try await Self.prepareRemoteLeader(
                cli: cli,
                host: host,
                environment: remoteEnvironment
            ) {
                AgentEnvironmentComparisonStore.recordLeader(environment, teamName: teamName)
                RemoteWorkLog.info(
                    "Leader environment: \(teamName) [\(cli)] on \(host.displayName) — "
                        + environment.liveActivityText
                )
            }
            try await attempt.ensureCurrent()
#if DEBUG
            dlog("leader.attach.stage prepare.ok host=\(hostKey)")
#endif
        } catch {
            await attempt.compensate()
            throw error
        }

        var bootstrap = Termmesh_Peer_V1_TeamLeaderBootstrapRequest()
        // Never the raw display name: the wire grammar cannot spell a space
        // or any non-ASCII character, and New Project's duplicate suffix
        // ("<repo> 2") produces one by itself.
        let bootstrapProjectID = PeerTeamLeader.projectID(
            teamName: teamName,
            teamUUID: teamUUID
        )
        bootstrap.projectID = bootstrapProjectID
        bootstrap.leaderPlacement = .peer
        var requestUUID = UUID().uuid
        bootstrap.requestID = withUnsafeBytes(of: &requestUUID) { Data($0) }
        let grantResponse = await PeerTeamLeaderControlPlane.shared.bootstrap(
            bootstrap,
            encodedBytes: (try? bootstrap.serializedData().count) ?? 513,
            audiencePeerID: PeerIdentity.defaultPeerID()
        ) { projectID in
            projectID == bootstrapProjectID ? teamUUID : nil
        }
        guard grantResponse.ok else {
            await attempt.compensate()
            throw RemoteAgentError.paneCreationFailed
        }
        resources.grantID = grantResponse.grant.grantID
        try await attempt.ensureCurrent()
#if DEBUG
        dlog("leader.attach.stage bootstrap.ok host=\(hostKey)")
#endif

        // The leader must read the same replaceable route as its workers. A
        // frozen launch grant keeps targeting the viewer that created this
        // pane after another viewer adopts the durable Project.
        guard let stagedLeaderRoute = await Self.stageRemoteAgentRouteTransaction(
            host: host,
            agentInstanceID: Self.remoteLeaderRouteIdentity(teamUUID: teamUUID),
            grant: grantResponse.grant
        ) else {
            await attempt.compensate()
            throw RemoteAgentError.environmentStagingFailed(host.displayName)
        }
        let routeFilePath = stagedLeaderRoute.routeFilePath
        resources.routeFilePath = routeFilePath
        resources.routeTransaction = stagedLeaderRoute.transaction
        guard await Self.finishAdoptedRemoteAgentRoutes(
            host: host, transaction: stagedLeaderRoute.transaction, commit: true
        ) else {
            await attempt.compensate()
            throw RemoteAgentError.environmentStagingFailed(host.displayName)
        }
        try await attempt.ensureCurrent()

        await Self.waitForRemoteShell(session: session)
        try await attempt.ensureCurrent()
#if DEBUG
        dlog("leader.attach.stage shell.ready host=\(hostKey)")
#endif

        // Do not paste the bearer grant into the terminal's visible scrollback
        // or history. First disable echo and history without any secret, then
        // submit the export+exec line while echo is disabled. The grant is
        // already short-lived and remains only in the launched CLI process.
        let prepare = Self.remoteLeaderPrepareCommand()
        guard await sendRemoteLeaderStage(
            session: session,
            text: prepare
        ) else {
            await attempt.compensate()
            throw RemoteAgentError.paneCreationFailed
        }
#if DEBUG
        dlog("leader.attach.stage prepare.sent host=\(hostKey)")
#endif

        if let systemPrompt, let fallbackPromptFile = promptFile {
            guard let stagedPromptFile = await stageRemoteLeaderPrompt(
                session: session,
                host: host,
                systemPrompt: systemPrompt,
                promptFile: fallbackPromptFile
            ) else {
                _ = await sendRemoteLeaderStage(session: session, text: "stty echo")
                await attempt.compensate()
                throw RemoteAgentError.promptStagingFailed(host.displayName)
            }
            promptFile = stagedPromptFile
            resources.promptFile = stagedPromptFile
            try await attempt.ensureCurrent()
        }

        let turnHookFile: String?
        if Self.supportsLeaderTurnMeasurement(cli: cli),
           let hookData = Self.localLeaderTurnHookData() {
            turnHookFile = await Self.writeRemoteLeaderTurnHookOverSSH(
                host: host, hookData: hookData, teamUUID: teamUUID
            )
            resources.turnHookFile = turnHookFile
        } else {
            turnHookFile = nil
        }
        let participationControlFile: String?
        if Self.supportsLeaderTurnMeasurement(cli: cli), turnHookFile != nil,
           let controlData = Self.leaderParticipationControlData(
               teamName: teamName, sessionID: team.leaderSessionId, supportedLeader: true,
               delegationState: team.delegationState,
               healthScope: .executionHost
           ) {
            participationControlFile = await Self.writeRemoteLeaderFileOverSSH(
                host: host, data: controlData,
                fileName: Self.remoteLeaderParticipationControlFileName(teamUUID: teamUUID),
                mode: "600"
            )
            resources.participationControlFile = participationControlFile
        } else {
            participationControlFile = nil
        }

        let launch = Self.remoteLeaderCommand(
            cli: cli,
            model: model,
            teamName: teamName,
            workingDirectory: workingDirectory,
            grant: grantResponse.grant,
            leaderRequestToken: TeamDataStore.shared.prepareLeaderRequestToken(teamName: teamName),
            systemPromptFile: promptFile,
            environment: remoteEnvironment,
            hostBinDirs: host.hostCLIBinDirs,
            turnHookFile: turnHookFile,
            participationControlFile: participationControlFile,
            routeFilePath: routeFilePath,
            leaderSessionID: team.leaderSessionId
        )
        var command = Self.remoteLeaderCommandCheckingPrompt(
            launch: launch,
            systemPrompt: systemPrompt,
            promptFile: promptFile
        )
        if host.sshTarget?.isEmpty == false {
            let launchFileName = "leader-\(teamUUID)-\(UUID().uuidString).sh"
            guard let stagedLaunchFile = await Self.writeRemoteLeaderLaunchOverSSH(
                host: host, command: command, fileName: launchFileName
            ) else {
                _ = await sendRemoteLeaderStage(session: session, text: "stty echo")
                await attempt.compensate()
                throw RemoteAgentError.paneCreationFailed
            }
            resources.launchFile = stagedLaunchFile
            command = Self.remoteLeaderStagedLaunchCommand(path: stagedLaunchFile)
        }
        let launched = await sendRemoteLeaderStage(
            session: session,
            text: command
        )
        if !launched {
            // Best-effort recovery for the only stage that can leave a shell
            // with echo disabled. This command carries no credential either.
            _ = await sendRemoteLeaderStage(session: session, text: "stty echo")
            await attempt.compensate()
            throw RemoteAgentError.paneCreationFailed
        }
        try await attempt.ensureCurrent()
#if DEBUG
        dlog("leader.attach.stage launch.sent host=\(hostKey)")
#endif
        guard let leaderSurfaceID = resources.surfaceID else {
            _ = await sendRemoteLeaderStage(session: session, text: "stty echo")
            await attempt.compensate()
            throw RemoteAgentError.paneCreationFailed
        }
        do {
            try await confirmRemoteLeaderForeground(
                host: host, surfaceID: leaderSurfaceID, leaderMode: cli
            )
        } catch {
            // Best-effort recovery for the only stage that can leave a shell
            // with echo disabled, same as the send failure above.
            _ = await sendRemoteLeaderStage(session: session, text: "stty echo")
            await attempt.compensate()
            throw error
        }
        try await attempt.ensureCurrent()
#if DEBUG
        dlog("leader.attach.stage foreground.confirmed host=\(hostKey)")
#endif

        // No await between this generation check and the synchronous UI/team
        // commit: both run on MainActor, so a timeout generation cannot slip
        // between them and publish a stale attach.
        try await attempt.ensureCurrent()
        let presentation = Self.remoteLeaderRecoveryPresentation(
            anchorExists: workspace.panels[team.leaderPanelId] != nil
        )
        let panel: TerminalPanel?
        switch presentation {
        case .replaceAnchor:
            panel = workspace.replaceTerminalPaneWithRemote(
                panelId: team.leaderPanelId,
                session: session,
                lifetime: .keepAlive
            )
        case .openPane:
            // A runtime EOF removes the dead panel before recovery starts.
            // Re-bootstrap must add a new pane instead of requiring the
            // project-creation placeholder that only exists on first launch.
            panel = workspace.openRemotePane(
                session: session,
                focus: false,
                lifetime: .keepAlive
            )
        }
        guard let panel else {
            await attempt.compensate()
            throw RemoteAgentError.paneCreationFailed
        }
        resources.panelID = panel.id
        panel.surface.resetTerminal()
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "👑 Leader (\(cli.capitalized)) @\(host.displayName)"
        )
        do {
            try await confirmRemoteLeaderPrompt(
                panel: panel, host: host, surfaceID: leaderSurfaceID, leaderMode: cli
            )
        } catch {
            await attempt.compensate()
            throw error
        }
        try await attempt.ensureCurrent()
        if let verificationFailure = await Self.verifyRemoteCollaborationRoute(
            host: host, teamName: teamName, teamUUID: teamUUID,
            routeFilePath: routeFilePath
        ) {
            RemoteWorkLog.info(
                "Replacement leader route verification failed for \(teamName): "
                    + verificationFailure
            )
            await attempt.compensate()
            throw RemoteAgentError.paneCreationFailed
        }
        try await attempt.ensureCurrent()
        replaceLeaderAnchorPanel(teamName: teamName, panelID: panel.id)
        markLeaderPolicyState(teamName: teamName, state: "injected")
        setLeaderMeasurementCapability(
            teamName: teamName,
            capability: Self.supportsLeaderTurnMeasurement(cli: cli)
                ? (turnHookFile == nil ? .degraded : .supported)
                : .unsupported
        )
        replaceLeaderEndpoint(
            teamName: teamName,
            panelID: panel.id,
            endpoint: .peer(hostKey: hostKey)
        )
        attempt.commit()
        LeaderTurnLog.rememberIdentity(
            team: teamName, teamUUID: teamUUID, leaderSessionID: team.leaderSessionId
        )
        startRemoteLeaderGrantKeepalive(
            teamName: teamName, grant: grantResponse.grant
        )
        let routeTransaction = stagedLeaderRoute.transaction
        resources.routeTransaction = nil
        resources.routeFilePath = nil
        if !(await Self.finalizeAdoptedRemoteAgentRoutes(
            host: host, transaction: routeTransaction
        )) {
            Self.scheduleAdoptedRemoteAgentRouteFinalize(
                host: host, transaction: routeTransaction
            )
        }
    }

    /// Keep a live remote leader's scoped grant renewable while its owning
    /// project exists. Thirty minutes leaves a full interval of scheduler
    /// tolerance inside the one-hour lease. No bearer is sent over a new
    /// channel and an already-expired grant is never resurrected.
    func startRemoteLeaderGrantKeepalive(
        teamName: String, grant: Termmesh_Peer_V1_TeamLeaderGrant
    ) {
        let grantID = grant.grantID
        if remoteLeaderGrantIDs[teamName] == grantID,
           remoteLeaderGrantKeepalives[teamName] != nil {
            remoteLeaderGrants[teamName] = grant
            return
        }
        stopRemoteLeaderGrantKeepalive(teamName: teamName, revoke: true)
        remoteLeaderGrantIDs[teamName] = grantID
        remoteLeaderGrants[teamName] = grant
        installRemoteLeaderWakeObserver()
        remoteLeaderGrantKeepalives[teamName] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.teams[teamName] != nil,
                      self.remoteLeaderGrantIDs[teamName] == grantID else { return }
                let renewed = await PeerTeamLeaderControlPlane.shared.keepAliveGrant(id: grantID)
                // Reconnect can replace this grant while the control-plane
                // actor call is suspended. A superseded task must never mark
                // the new leader failed or erase its keepalive registration.
                guard !Task.isCancelled,
                      self.remoteLeaderGrantIDs[teamName] == grantID else { return }
                guard renewed else {
                    self.markRemoteLeaderFailed(
                        teamName: teamName,
                        description: "Remote leader grant expired; reconnect the leader pane"
                    )
                    self.remoteLeaderGrantKeepalives.removeValue(forKey: teamName)
                    self.remoteLeaderGrantIDs.removeValue(forKey: teamName)
                    self.remoteLeaderGrants.removeValue(forKey: teamName)
                    return
                }
            }
        }
    }

    /// Mint a bearer for one remote worker's reverse team route.
    ///
    /// The worker can only reach the daemon socket on its own host. The grant
    /// lets that daemon carry the allow-listed team call back over the peer
    /// session to this app; no local Unix socket path or credential crosses
    /// machines. Workers intentionally do not share the leader's grant: a
    /// leader reconnect can replace its bearer without cutting every agent's
    /// `tm-agent` channel at once.
    ///
    /// `teamUUID` is passed explicitly by adoption, which mints routes before
    /// the team exists in `teams` — installing a project whose workers had
    /// already been proven unreachable is the failure this ordering avoids.
    private func bootstrapRemoteAgentRoute(
        teamName: String,
        teamUUID explicitTeamUUID: String? = nil
    ) async throws -> Termmesh_Peer_V1_TeamLeaderGrant {
        let resolved = explicitTeamUUID ?? teams[teamName]?.teamUuid
        guard let teamUUID = resolved, !teamUUID.isEmpty else {
            throw RemoteAgentError.teamNotFound(teamName)
        }
        var bootstrap = Termmesh_Peer_V1_TeamLeaderBootstrapRequest()
        // Same identifier rule as the leader grant: a display name the wire
        // grammar cannot spell would fail every worker's route bootstrap.
        let bootstrapProjectID = PeerTeamLeader.projectID(
            teamName: teamName,
            teamUUID: teamUUID
        )
        bootstrap.projectID = bootstrapProjectID
        bootstrap.leaderPlacement = .peer
        var requestUUID = UUID().uuid
        bootstrap.requestID = withUnsafeBytes(of: &requestUUID) { Data($0) }
        let response = await PeerTeamLeaderControlPlane.shared.bootstrap(
            bootstrap,
            encodedBytes: (try? bootstrap.serializedData().count) ?? 513,
            audiencePeerID: PeerIdentity.defaultPeerID()
        ) { projectID in
            projectID == bootstrapProjectID ? teamUUID : nil
        }
        guard response.ok else { throw RemoteAgentError.paneCreationFailed }
        return response.grant
    }

    private func startRemoteAgentRouteKeepalive(
        teamName: String,
        agentInstanceID: String,
        grantID: Data
    ) {
        stopRemoteAgentRouteKeepalive(agentInstanceID: agentInstanceID, revoke: true)
        remoteAgentRouteLeases[agentInstanceID] = RemoteAgentRouteLease(
            teamName: teamName,
            grantID: grantID
        )
        installRemoteLeaderWakeObserver()
        let keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      let lease = self.remoteAgentRouteLeases[agentInstanceID],
                      lease.teamName == teamName,
                      lease.grantID == grantID,
                      self.teams[teamName]?.agents.contains(where: {
                          $0.agentInstanceId == agentInstanceID
                      }) == true else { return }
                let renewed = await PeerTeamLeaderControlPlane.shared.keepAliveGrant(id: grantID)
                guard !Task.isCancelled,
                      self.remoteAgentRouteLeases[agentInstanceID]?.grantID == grantID else {
                    return
                }
                guard renewed else {
                    RemoteWorkLog.info(
                        "The remote team route for \(teamName)/\(agentInstanceID) expired; "
                            + "detach and attach that agent again"
                    )
                    self.remoteAgentRouteKeepalives.removeValue(forKey: agentInstanceID)
                    self.remoteAgentRouteLeases.removeValue(forKey: agentInstanceID)
                    return
                }
            }
        }
        remoteAgentRouteKeepalives[agentInstanceID] = .init(
            teamName: teamName, task: keepalive
        )
    }

    /// Renew every live grant as soon as the machine wakes.
    ///
    /// The 30-minute loop is `Task.sleep`, which does not advance while the
    /// Mac is asleep. A lid closed for longer than the remaining lease means
    /// the next tick arrives after the grant is already gone — on a laptop
    /// that is the ordinary case, not an edge one, and it is how a leader
    /// that was fine at lunch is unreachable after it.
    ///
    /// Waking is also precisely when the network is not up yet, so a failure
    /// here proves nothing. This pass therefore never retires a leader: the
    /// 30-minute loop stays the only place allowed to declare a grant gone.
    /// Renewing early can only help; misreading a cold network as a lapse
    /// would kill a team that was about to be perfectly fine.
    private func installRemoteLeaderWakeObserver() {
        guard remoteLeaderWakeObserver == nil else { return }
        remoteLeaderWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.renewRemoteLeaderGrantsAfterWake()
            }
        }
    }

    private func renewRemoteLeaderGrantsAfterWake() async {
        // Snapshot first: a renewal can retire its own entry, and reconnect
        // can replace one while this loop is suspended.
        let pairs = remoteLeaderGrantIDs.map { ($0.key, $0.value) }
        let agentPairs = remoteAgentRouteLeases.map { ($0.key, $0.value) }
        guard !pairs.isEmpty || !agentPairs.isEmpty else { return }
        // Let the network come back before asking. A few seconds costs
        // nothing against a 30-minute interval and avoids spending the
        // attempt on a link that is not up yet.
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        for (teamName, grantID) in pairs {
            guard remoteLeaderGrantIDs[teamName] == grantID else { continue }
            let renewed = await PeerTeamLeaderControlPlane.shared.keepAliveGrant(id: grantID)
#if DEBUG
            dlog("leader.grant.wakeRenew team=\(teamName) renewed=\(renewed)")
#endif
            if !renewed {
                // Deliberately silent for the person: the 30-minute loop
                // reports a real lapse, and a notice here would fire on every
                // wake where the network simply had not returned yet.
                RemoteWorkLog.info(
                    "Could not renew the remote leader grant for \(teamName) on wake; will retry on the next interval"
                )
            }
        }
        for (agentInstanceID, lease) in agentPairs {
            guard remoteAgentRouteLeases[agentInstanceID]?.grantID == lease.grantID else {
                continue
            }
            let renewed = await PeerTeamLeaderControlPlane.shared.keepAliveGrant(
                id: lease.grantID
            )
#if DEBUG
            dlog(
                "agent.grant.wakeRenew team=\(lease.teamName) "
                    + "agent=\(agentInstanceID.prefix(8)) renewed=\(renewed)"
            )
#endif
            if !renewed {
                RemoteWorkLog.info(
                    "Could not renew the remote agent route for \(lease.teamName) on wake; "
                        + "will retry on the next interval"
                )
            }
        }
    }

    func stopRemoteLeaderGrantKeepalive(teamName: String, revoke: Bool) {
        remoteLeaderGrantKeepalives.removeValue(forKey: teamName)?.cancel()
        remoteLeaderGrants.removeValue(forKey: teamName)
        guard let grantID = remoteLeaderGrantIDs.removeValue(forKey: teamName), revoke else { return }
        Task { await PeerTeamLeaderControlPlane.shared.revokeGrant(id: grantID) }
    }

    func stopRemoteAgentRouteKeepalive(
        agentInstanceID: String,
        revoke: Bool
    ) {
        remoteAgentRouteKeepalives.removeValue(forKey: agentInstanceID)?.task.cancel()
        guard let lease = remoteAgentRouteLeases.removeValue(forKey: agentInstanceID),
              revoke else { return }
        Task { await PeerTeamLeaderControlPlane.shared.revokeGrant(id: lease.grantID) }
    }

    /// How a roster read lands, or nil when the stored surface is in the list
    /// and the attach may go ahead.
    ///
    /// `rosterSurfaceIDs` is nil when the host could not be asked at all — a
    /// lease that would not open, a list RPC that threw. That is the whole
    /// point of the separation: not knowing is not the same as knowing the
    /// surface is gone, and only the second one may mint a replacement leader.
    ///
    /// Split out from the flow so the distinction can be tested without a peer:
    /// the bug this replaces was not a missing rule but a `catch` that folded
    /// every transport failure into the same `false` the authoritative absence
    /// returned.
    nonisolated static func remoteLeaderRosterVerdict(
        rosterSurfaceIDs: [Data]?,
        storedSurfaceID: Data
    ) -> RemoteLeaderReattachOutcome? {
        guard let rosterSurfaceIDs else { return .temporarilyUnavailable }
        return rosterSurfaceIDs.contains(storedSurfaceID) ? nil : .confirmedMissing
    }

    /// How long to wait between reattach retries before giving the team back to
    /// a person. Bounded on purpose: a peer that stays unreachable is not
    /// something this loop can fix, and `recoverRemoteLeaderIfNeeded` is the
    /// manual retry that stays available once these are spent.
    static let remoteLeaderReattachBackoffSeconds: [Double] = [1, 2, 4]

    /// Reattach the project's local leader viewer to the exact remote surface
    /// it already owns. The remote process/surface outlives any one local pane;
    /// this path restores presentation without spawning a second leader or
    /// replaying bootstrap credentials.
    ///
    /// Every answer other than `.confirmedMissing` leaves the stored surface
    /// record and its grant untouched, because the remote leader may well still
    /// be running behind it.
    @discardableResult
    func reattachRemoteLeaderIfNeeded(
        teamName: String, expectedSurfaceID: Data? = nil
    ) async -> RemoteLeaderReattachOutcome {
        guard let team = teams[teamName],
              case let .peer(hostKey) = team.leaderEndpoint
        else { return .temporarilyUnavailable }
        if isLeaderPaneAttached(teamName: teamName) {
            guard let expectedSurfaceID,
                  let located = AppDelegate.shared?.locateSurface(
                      surfaceId: team.leaderPanelId
                  ),
                  let workspace = located.tabManager.tabs.first(where: {
                      $0.id == located.workspaceId
                  }),
                  workspace.terminalPanel(for: team.leaderPanelId)?
                    .peerPaneSession?.originSurface.surfaceID == expectedSurfaceID else {
                return expectedSurfaceID == nil ? .attached : .temporarilyUnavailable
            }
            return .attached
        }
        guard !remoteLeaderReattachInFlight.contains(teamName) else {
            return .temporarilyUnavailable
        }
        remoteLeaderReattachInFlight.insert(teamName)
        defer { remoteLeaderReattachInFlight.remove(teamName) }

        let surfaceID: Data? = expectedSurfaceID ?? ManagedPeerSurfaceStore.shared
            .leaderRecord(hostKey: hostKey, teamName: teamName)?.surfaceID
        guard let surfaceID else {
            // No surface was ever recorded, so there is none to duplicate. This
            // is the initial-attach-failed case `recoverRemoteLeaderIfNeeded`
            // documents, and bootstrapping is its intended repair.
            RemoteWorkLog.info("Cannot restore \(teamName) leader: its remote surface identity is missing")
            return .confirmedMissing
        }
        guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              host.isConnected else {
            RemoteWorkLog.info("Cannot restore \(teamName) leader: \(hostKey) is disconnected")
            return .temporarilyUnavailable
        }
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId })
        else { return .temporarilyUnavailable }

        let lease: PeerPaneHostLease
        do {
            lease = try await PeerPaneHostRegistry.shared.acquire(Self.requireTeamHostSpec(host))
        } catch {
            RemoteWorkLog.info("Cannot restore \(teamName) leader: \(error)")
            return .temporarilyUnavailable
        }

        // nil means the roster could not be read. `host.isConnected` does not
        // promise this call succeeds — it is a cached reachability flag, and a
        // relay EOF is exactly when the list RPC is most likely to fail.
        var roster: [Termmesh_Peer_V1_SurfaceInfo]?
        do {
            roster = try await PeerPaneSession.listSurfaces(on: lease)
        } catch {
            RemoteWorkLog.info(
                "Cannot confirm \(teamName) leader's surface on \(host.displayName): \(error)"
            )
            roster = nil
        }
        if let verdict = Self.remoteLeaderRosterVerdict(
            rosterSurfaceIDs: roster?.map(\.surfaceID),
            storedSurfaceID: surfaceID
        ) {
            PeerPaneHostRegistry.shared.release(lease)
            if verdict.permitsReplacementBootstrap {
                markRemoteLeaderFailed(
                    teamName: teamName,
                    description: "Remote leader surface no longer exists on \(host.displayName)"
                )
            }
            return verdict
        }
        guard let surface = roster?.first(where: { $0.surfaceID == surfaceID }) else {
            PeerPaneHostRegistry.shared.release(lease)
            return .temporarilyUnavailable
        }
        if surface.foregroundBusyKnown, !surface.foregroundBusy {
            PeerPaneHostRegistry.shared.release(lease)
            markRemoteLeaderFailed(
                teamName: teamName,
                description: "Remote leader surface exists, but no foreground leader process is running"
            )
            return .confirmedInactive
        }

        let session: PeerPaneSession
        do {
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: surface,
                title: "Leader",
                spec: Self.requireTeamHostSpec(host)
            )
        } catch {
            // The surface is on the host's own roster; only this attach failed.
            PeerPaneHostRegistry.shared.release(lease)
            RemoteWorkLog.info("Cannot restore \(teamName) leader: \(error)")
            return .temporarilyUnavailable
        }
        PeerPaneHostRegistry.shared.release(lease)

        let panel = team.isRemoteRepairPlaceholder
            ? workspace.replaceTerminalPaneWithRemote(
                panelId: team.leaderPanelId, session: session, lifetime: .keepAlive
            )
            : workspace.openRemotePane(
                session: session, focus: false, lifetime: .keepAlive
            )
        guard let panel else {
            session.teardown()
            RemoteWorkLog.info("Cannot restore \(teamName) leader: no local pane can host it")
            return .temporarilyUnavailable
        }
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "👑 Leader (\(team.leaderMode.capitalized)) @\(host.displayName)"
        )
        replaceLeaderEndpoint(
            teamName: teamName,
            panelID: panel.id,
            endpoint: .peer(hostKey: hostKey)
        )
#if DEBUG
        dlog(
            "leader.reattach.ok team=\(teamName) host=\(hostKey) "
                + "surface=\(surfaceID.base64EncodedString()) "
                + "panel=\(panel.id.uuidString.prefix(8))"
        )
#endif
        return .attached
    }

    /// Restore a peer leader after its relay reports runtime EOF. Reattach the
    /// exact surface when it survived a viewer interruption; if the peer host
    /// restarted and the surface is gone, mint a fresh grant and bootstrap a
    /// replacement leader into the existing team workspace.
    @discardableResult
    func recoverRemoteLeaderAfterRuntimeClose(
        teamName: String,
        closedPanelID: UUID,
        authoritativeReplacementRequired: Bool = false,
        replacementLaunchMetadata: CollaborationLeaderLaunchMetadata? = nil
    ) async -> Bool {
        guard let original = teams[teamName],
              original.leaderPanelId == closedPanelID,
              case let .peer(hostKey) = original.leaderEndpoint
        else { return false }
        guard beginRemoteLeaderAttach(teamName: teamName) else { return false }
        defer { endRemoteLeaderAttach(teamName: teamName) }

        markRemoteLeaderFailed(
            teamName: teamName,
            description: "Remote leader disconnected; reconnecting"
        )

        // Bootstrapping mints a second grant and a second surface, so it needs
        // the host to have *said* the old surface is gone. A reattach that
        // merely could not reach the host is retried instead: the remote
        // leader is most likely still running, and replacing it there leaves
        // two on one team.
        var outcome: RemoteLeaderReattachOutcome = authoritativeReplacementRequired
            ? .confirmedMissing
            : await reattachRemoteLeaderIfNeeded(teamName: teamName)
        if !authoritativeReplacementRequired {
            for delay in Self.remoteLeaderReattachBackoffSeconds {
                if case .attached = outcome { return true }
                if outcome.permitsReplacementBootstrap { break }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return false }
                outcome = await reattachRemoteLeaderIfNeeded(teamName: teamName)
            }
        }
        if case .attached = outcome { return true }
        guard authoritativeReplacementRequired || outcome.permitsReplacementBootstrap else {
            // Deliberately not a bootstrap. The stored surface and grant are
            // left as they are, so `recoverRemoteLeaderIfNeeded` can pick this
            // up again once the host answers.
            markRemoteLeaderFailed(
                teamName: teamName,
                description: "Remote leader could not be reached to confirm its surface; "
                    + "not replaced. Retry once the host is reachable."
            )
#if DEBUG
            dlog("leader.recover.unconfirmed team=\(teamName) host=\(hostKey)")
#endif
            return false
        }

        guard let team = teams[teamName],
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              host.isConnected
        else {
            markRemoteLeaderFailed(
                teamName: teamName,
                description: "Remote leader host is disconnected"
            )
            return false
        }
        let workingDirectory =
            ManagedPeerSurfaceStore.shared.leaderRecord(
                hostKey: hostKey,
                teamName: teamName
            )?.workingDirectory
            ?? team.remoteProjectLocations.first(where: { $0.hostKey == hostKey })?.path
            ?? team.workingDirectory
        let launchMetadata = replacementLaunchMetadata
            ?? Self.collaborationLeaderLaunchMetadata(
                remoteCLI: team.leaderCli ?? team.leaderMode,
                remoteModel: team.leaderModel
            )
        let systemPrompt: String?
        if launchMetadata.cli.lowercased() == "claude" {
            systemPrompt = Self.remoteLeaderClaudeRecoverySystemPrompt(
                teamName: teamName,
                agents: team.agents,
                remoteWorkingDirectory: workingDirectory,
                remoteSocketPath: host.remoteSockPath ?? "inherited from TERMMESH_SOCKET",
                hostCLIBinDirs: host.hostCLIBinDirs
            )
        } else {
            // Recovery had the same CLI-shaped hole as creation: a restarted
            // codex leader came back knowing how to schedule and not who for.
            systemPrompt = Self.remoteLeaderNonClaudeRecoverySystemPrompt(
                teamName: teamName,
                agents: team.agents,
                remoteWorkingDirectory: workingDirectory,
                remoteSocketPath: host.remoteSockPath ?? "inherited from TERMMESH_SOCKET",
                hostCLIBinDirs: host.hostCLIBinDirs
            )
        }

        do {
            try await Self.withLeaderAttachDeadline(
                teamName: teamName,
                hostKey: hostKey
            ) { attempt in
                try await self.attachRemoteLeader(
                    teamName: teamName,
                    hostKey: hostKey,
                    workingDirectory: workingDirectory,
                    cli: launchMetadata.cli,
                    model: launchMetadata.model,
                    attempt: attempt,
                    systemPrompt: systemPrompt
                )
            }
#if DEBUG
            dlog("leader.recover.ok team=\(teamName) host=\(hostKey)")
#endif
            return true
        } catch {
            let description = "Could not recover remote leader on \(hostKey): \(error)"
            markRemoteLeaderFailed(teamName: teamName, description: description)
            markLeaderPolicyState(
                teamName: teamName,
                state: "failed",
                failureDescription: description
            )
#if DEBUG
            dlog("leader.recover.failed team=\(teamName) host=\(hostKey) error=\(error)")
#endif
            return false
        }
    }

    /// User- and debug-triggered counterpart to runtime EOF recovery. This is
    /// also safe for an initial attach that failed before a surface was
    /// recorded: the current placeholder becomes the replacement anchor.
    @discardableResult
    func recoverRemoteLeaderIfNeeded(teamName: String) async -> Bool {
        if isLeaderPaneAttached(teamName: teamName) { return true }
        guard let panelID = teams[teamName]?.leaderPanelId else { return false }
        return await recoverRemoteLeaderAfterRuntimeClose(
            teamName: teamName,
            closedPanelID: panelID
        )
    }

    /// Resume is explicit, but it still must not turn a merely existing local
    /// pane into a successful recovery. Remote leaders have a reconstruction
    /// protocol; local leaders currently do not, so local incomplete state
    /// remains visible until readiness is authoritative.
    func resumeIncompleteProjectSetup(teamName: String) async -> Bool {
        guard let team = teams[teamName] else { return false }
        switch team.leaderEndpoint {
        case .peer:
            return await recoverRemoteLeaderIfNeeded(teamName: teamName)
        case .local:
            return team.leaderReady
        }
    }

    /// Rebuild the local workspace for a live peer-backed project whose
    /// previous window was closed. Remote processes and surfaces are reused
    /// exactly; this never launches a second leader or agent.
    @discardableResult
    func restoreDetachedProjectPresentation(
        teamName: String,
        tabManager: TabManager
    ) async -> Bool {
        guard let original = teams[teamName] else { return false }
        // Single-flight at orchestrator scope, not per sidebar view: two
        // windows showing the same detached project, or one window plus the
        // debug command, otherwise both compute `missingRestoredAgentIDs`
        // before any await and both reattach every surface.
        guard !projectRestoreInFlight.contains(teamName) else { return false }
        projectRestoreInFlight.insert(teamName)
        defer { projectRestoreInFlight.remove(teamName) }

        if let existing = AppDelegate.shared?.contextContainingTabId(original.workspaceId) {
            existing.window?.makeKeyAndOrderFront(nil)
            return await recoverRemoteLeaderIfNeeded(teamName: teamName)
        }

        // Normal window-close recovery: adopt the exact Workspace that the
        // closing window preserved. This is lossless for both remote terminal
        // panes and native AgentPanels because no process/session is restarted.
        if let preserved = takePreservedProjectPresentation(teamName: teamName) {
            tabManager.attachWorkspace(preserved, select: true)
            WorkspaceProjectNames.shared.declare(
                workspaceId: preserved.id,
                projectName: teamName,
                projectID: original.remotePresentationProjectID
            )
#if DEBUG
            dlog(
                "project.presentation.adopted team=\(teamName) "
                    + "workspace=\(preserved.id.uuidString.prefix(8)) "
                    + "panels=\(preserved.panels.count)"
            )
#endif
            return true
        }

        // Compatibility recovery for a project detached before Workspace
        // preservation existed. The test is a durable surface identity on the
        // PEER — a surface its daemon still holds and this side can name — and
        // both remote kinds have one: a terminal-backed member's PTY and a
        // peer-owned agent's `tm-agent-bridge` alike. What must never enter
        // this fallback is a LOCAL native agent, whose process is a child of
        // this app owned by its preserved `AgentSession`; it has no
        // `remoteSurfaceID`, which is what this guard reads.
        //
        // `attachRestoredRemoteSurface` picks the renderer from the surface
        // type the host reports, so an agent surface comes back as an
        // `AgentPanel` rather than being pushed through `openRemotePane` —
        // which refuses it by contract and would fail every retry at the same
        // point, forever.
        guard original.agents.allSatisfy({
            $0.hostKey != nil && $0.remoteSurfaceID != nil
        }) else {
            RemoteWorkLog.info(
                "Cannot restore \(teamName): its exact native/local presentation is unavailable"
            )
            return false
        }

        let progress: DetachedRestoreProgress
        if let existing = DetachedRestoreRegistry.progressByTeam[teamName],
           tabManager.tabs.contains(where: { $0.id == existing.workspace.id }) {
            progress = existing
        } else {
            let workspace = tabManager.addWorkspace(
                workingDirectory: original.workingDirectory,
                select: true
            )
            workspace.customTitle = "[\(teamName)]"
            workspace.title = "[\(teamName)]"
            progress = DetachedRestoreProgress(workspace: workspace)
            DetachedRestoreRegistry.progressByTeam[teamName] = progress
        }
        let workspace = progress.workspace

        if progress.leaderPanelID == nil,
           case let .peer(leaderHostKey) = original.leaderEndpoint,
           let leaderSurfaceID = original.remoteLeaderSurfaceID
               ?? ManagedPeerSurfaceStore.shared.leaderRecord(
                   hostKey: leaderHostKey,
                   teamName: teamName
               )?.surfaceID,
           let panelID = await attachRestoredRemoteSurface(
               hostKey: leaderHostKey,
               surfaceID: leaderSurfaceID,
               title: "Leader",
               panelTitle: "👑 Leader (\(original.leaderMode.capitalized))",
               workspace: workspace
           ) {
            progress.leaderPanelID = panelID
        }

        let missingAgentIDs = Self.missingRestoredAgentIDs(
            expected: original.agents.map(\.agentInstanceId),
            attached: Set(progress.agentPanelIDs.keys)
        )
        for originalAgent in original.agents
        where missingAgentIDs.contains(originalAgent.agentInstanceId) {
            guard let hostKey = originalAgent.hostKey,
                  let surfaceID = originalAgent.remoteSurfaceID
            else { continue }
            if let panelID = await attachRestoredRemoteSurface(
                hostKey: hostKey,
                surfaceID: surfaceID,
                title: originalAgent.name,
                panelTitle: "\(Self.colorEmoji(originalAgent.color)) \(originalAgent.name)",
                workspace: workspace,
                // A restored `AgentPanel` is a brand new `AgentSession`, so it
                // arrives with none of the team's closures on it. Without this
                // the pane renders, turns run, and no reply is ever filed —
                // the quietest way for a restored member to be broken.
                onAgentPanel: { panel, host in
                    Self.bindPeerOwnedAgentPanel(
                        panel: panel,
                        workspace: workspace,
                        teamName: teamName,
                        agentName: originalAgent.name,
                        agentInstanceId: originalAgent.agentInstanceId,
                        color: originalAgent.color,
                        hostDisplayName: host.displayName
                    )
                }
            ) {
                progress.agentPanelIDs[originalAgent.agentInstanceId] = panelID
            }
        }

        let complete = progress.leaderPanelID != nil
            && progress.agentPanelIDs.count == original.agents.count
        guard complete, let leaderPanelID = progress.leaderPanelID else {
            RemoteWorkLog.info(
                "Restore of \(teamName) is incomplete; a retry will attach only missing panes"
            )
            return false
        }

        // Commit presentation addresses only after every remote surface is
        // attached. These helpers are synchronous MainActor operations, so no
        // retry can observe the new workspace ID with a partial agent list.
        guard beginProjectPresentationRestore(
            teamName: teamName,
            workspaceID: workspace.id
        ) else { return false }
        replaceLeaderEndpoint(
            teamName: teamName,
            panelID: leaderPanelID,
            endpoint: original.leaderEndpoint
        )
        for originalAgent in original.agents {
            guard let panelID = progress.agentPanelIDs[originalAgent.agentInstanceId] else {
                return false
            }
            replaceRemoteAgentPresentation(
                teamName: teamName,
                agentInstanceID: originalAgent.agentInstanceId,
                workspaceID: workspace.id,
                panelID: panelID
            )
        }
        DetachedRestoreRegistry.progressByTeam.removeValue(forKey: teamName)
        WorkspaceProjectNames.shared.declare(
            workspaceId: workspace.id,
            projectName: teamName,
            projectID: original.remotePresentationProjectID
        )
        if let projectID = original.remotePresentationProjectID
            ?? original.teamUuid.map(Self.remoteProjectPresentationID(teamUUID:)) {
            finalizeRestoredProjectLayout(
                projectID: projectID,
                workspace: workspace,
                anchorPanelID: progress.anchorPanelID,
                leaderPanelID: leaderPanelID,
                agentPanelIDs: original.agents.compactMap {
                    progress.agentPanelIDs[$0.agentInstanceId]
                },
                restoreFocus: true
            )
        } else {
            if let anchorPanelID = progress.anchorPanelID, workspace.panels.count > 1 {
                _ = workspace.closePanel(anchorPanelID, force: true)
            }
            settleRestoredAgentGrid(workspace: workspace)
        }

#if DEBUG
        dlog(
            "project.presentation.restore team=\(teamName) "
                + "workspace=\(workspace.id.uuidString.prefix(8)) "
                + "leader=true agents=\(progress.agentPanelIDs.count)/\(original.agents.count)"
        )
#endif
        return true
    }

    /// Reattach one surviving peer surface and give it a local pane again.
    ///
    /// The renderer is chosen from the surface type the HOST reports, not from
    /// anything this side remembers. An agent surface carries NDJSON for
    /// `AgentSession`, and `openRemotePane` refuses it by contract — routing
    /// one there returns nil at the same point on every retry, so a project
    /// with a single peer-owned agent member could never finish restoring.
    ///
    /// `onAgentPanel` is how the caller puts its own meaning back on a
    /// restored `AgentPanel` (a fresh `AgentSession` has none of the team's
    /// closures). A caller that passes none is declaring it cannot host one —
    /// the leader is never an agent surface — and gets nil rather than a pane
    /// wired to nobody.
    /// Carries the proven endpoint back out of `attachRestoredRemoteSurface`.
    ///
    /// A plain return value would mean changing four call sites for one that
    /// needs it; a class lets the restore path collect the value without the
    /// others learning about it.
    @MainActor
    final class RestoredSurfaceEndpoint {
        /// nil until `ListSurfaces` finds the surface, and nil afterwards when
        /// the host owns its own sessions — the same "no redirect" the field
        /// means elsewhere. A later attach or panel failure can leave this set
        /// on a call that returns nil; callers read it only after a non-nil
        /// panel id, and each gets its own box.
        var remoteSockPath: String?
    }

    /// `owningRemoteSockPath` receives the remote socket of the endpoint whose
    /// lease proved this surface exists — the `ListSurfaces` above ran on it.
    ///
    /// Reported back rather than re-read from the store by the caller: this
    /// function awaits, and a reconnect handshake landing in that window can
    /// move or clear the host's route. A post-await store snapshot would then
    /// name an endpoint that never had the surface, which is the whole defect
    /// the recorded endpoint exists to prevent.
    private func attachRestoredRemoteSurface(
        hostKey: String,
        surfaceID: Data,
        title: String,
        panelTitle: String,
        workspace: Workspace,
        owningRemoteSockPath: RestoredSurfaceEndpoint? = nil,
        onAgentPanel: ((AgentPanel, HostEntry) -> Void)? = nil
    ) async -> UUID? {
        guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              host.isConnected else { return nil }
        let lease: PeerPaneHostLease
        do {
            lease = try await PeerPaneHostRegistry.shared.acquire(Self.requireTeamHostSpec(host))
        } catch {
            RemoteWorkLog.info("Cannot restore \(title) on \(hostKey): \(error)")
            return nil
        }
        let session: PeerPaneSession
        let isAgentSurface: Bool
        do {
            let surfaces = try await PeerPaneSession.listSurfaces(on: lease)
            guard let surface = surfaces.first(where: { $0.surfaceID == surfaceID }) else {
                PeerPaneHostRegistry.shared.release(lease)
                RemoteWorkLog.error(
                    "Cannot restore \(title) on \(hostKey): the saved surface is no longer available"
                )
                return nil
            }
            isAgentSurface = SessionHostPanes.isAgentSurfaceType(surface.surfaceType)
            // Recorded here, where the lease that answered ListSurfaces is still
            // in hand. `.direct` endpoints have no remote socket and mean "the
            // serving socket", which is exactly the nil case.
            owningRemoteSockPath?.remoteSockPath = lease.key.remoteSockPath
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: surface,
                title: title,
                spec: Self.requireTeamHostSpec(host)
            )
        } catch {
            PeerPaneHostRegistry.shared.release(lease)
            RemoteWorkLog.info("Cannot restore \(title) on \(hostKey): \(error)")
            return nil
        }
        PeerPaneHostRegistry.shared.release(lease)

        if isAgentSurface {
            guard let onAgentPanel else {
                session.teardown()
                RemoteWorkLog.info(
                    "Cannot restore \(title) on \(hostKey): it is an agent surface, "
                        + "which this pane cannot host"
                )
                return nil
            }
            guard let panel = workspace.openRemoteAgentPane(
                session: session,
                focus: false
            ) else {
                session.teardown()
                RemoteWorkLog.error(
                    "Cannot restore \(title) on \(hostKey): the agent panel could not be opened"
                )
                return nil
            }
            onAgentPanel(panel, host)
            return panel.id
        }

        guard let panel = workspace.openRemotePane(
            session: session,
            focus: false,
            lifetime: .keepAlive
        ) else {
            session.teardown()
            RemoteWorkLog.error(
                "Cannot restore \(title) on \(hostKey): the terminal relay pane could not be opened"
            )
            return nil
        }
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "\(panelTitle) @\(host.displayName)"
        )
        return panel.id
    }

    /// A team destroy is an explicit end-of-lifecycle action, unlike closing
    /// its local viewer. Tear down the project-owned remote surface even when
    /// that viewer was detached earlier.
    func closeRemoteLeaderSurfaceIfNeeded(teamName: String) {
        stopRemoteLeaderGrantKeepalive(teamName: teamName, revoke: true)
        guard let team = teams[teamName],
              Self.adoptedPresentationAllowsRemoteDestruction(
                  presentationOwnedByRequester: team.ownsRemotePresentation
              ),
              case let .peer(hostKey) = team.leaderEndpoint,
              let record = ManagedPeerSurfaceStore.shared.leaderRecord(
                  hostKey: hostKey,
                  teamName: teamName
              ),
              let surfaceID = record.surfaceID,
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              host.teamRouteResolved
        else { return }

        // Leases rather than looks up: this runs while a project is being torn
        // down, which is after its panes — and therefore the team tunnel they
        // held — are gone. Requiring a live tunnel here would skip exactly the
        // case it was written for.
        Task { @MainActor in
            _ = await Self.withTeamSockPath(host: host) { sockPath in
                await Self.closeManagedRemoteSurface(
                    hostSockPath: sockPath,
                    hostKey: hostKey,
                    surfaceID: surfaceID
                )
            }
        }
    }

    private static func closeManagedRemoteSurface(
        hostSockPath: String,
        hostKey: String,
        surfaceID: Data
    ) async {
        guard !hostSockPath.isEmpty,
              let connection = try? await PeerRelaySession.connect(hostSockPath: hostSockPath)
        else { return }
        do {
            try await connection.session.requestClosePane(paneID: surfaceID)
            ManagedPeerSurfaceStore.shared.forget(hostKey: hostKey, surfaceID: surfaceID)
        } catch {
            // Keep the record. The host row's shell manager can retry it after
            // a reconnect instead of losing the only ownership evidence.
        }
        await connection.cancel()
    }

    /// What one login-shell probe found on a host for a given agent CLI.
    ///
    /// Both entries are absolute paths or empty. Empty is data, not an error:
    /// a host with no `tm-agent-bridge` simply cannot own an agent surface;
    /// Native mode can still use this Mac's SSH-owned bridge instead.
    struct RemoteAgentBinaries: Equatable, Sendable {
        /// Where the login shell resolves the agent CLI. Empty when it is not
        /// on that PATH at all, or resolves to something that is not a path
        /// (a shell function, a builtin).
        var cliPath: String = ""
        /// Where the login shell resolves the binary the BRIDGE spawns, which
        /// is not always the same file as `cliPath` — see
        /// `peerAgentExecutableName`. This, not `cliPath`, is what `--exe`
        /// gets. Empty when the probe found nothing usable, which is a signal
        /// to omit `--exe` and let the bridge use its own default.
        var execPath: String = ""
        /// Where `tm-agent-bridge` lives on this host. Empty when absent.
        var bridgePath: String = ""
        /// Whether the CLI is runnable at all — `command -v` succeeded, even
        /// if what it named was not a path. This, not `cliPath`, is what the
        /// terminal path needs: it types a bare CLI name at a login shell,
        /// where a function or alias works exactly as well as a binary.
        var cliAvailable: Bool = false
    }

    /// Markers for `remoteAgentBinariesProbe`. Prefixes rather than bare
    /// sentinels because a login shell prints its own greeting around them.
    private static let remoteCLIAvailableMarker = "__TERMMESH_CLI_AVAILABLE__"
    private static let remoteCLIPathMarker = "__TERMMESH_CLI_PATH__="
    private static let remoteExecPathMarker = "__TERMMESH_EXE_PATH__="
    private static let remoteBridgePathMarker = "__TERMMESH_BRIDGE_PATH__="

    /// The binary `tm-agent-bridge` actually spawns for a role CLI.
    ///
    /// Usually the role name IS the binary, and for kiro it is not: the role
    /// is `kiro`, the ACP server is `kiro-cli`
    /// (`daemon/tm-agent-bridge/src/main.rs` defaults `--exe` to `kiro-cli`,
    /// and `TeamOrchestrator.defaultLaunchCommand` has said the same for as
    /// long as kiro has been supported). `--exe` names an executable, not a
    /// role — handing it a `kiro` launcher/wrapper overrides the correct
    /// default with something that cannot speak ACP, and the bridge exits at
    /// the handshake behind an agent pane that already opened.
    static func peerAgentExecutableName(cli: String) -> String {
        cli == "kiro" ? "kiro-cli" : cli
    }

    /// One round trip for four questions. A second ssh to ask where the
    /// bridge is would double the wait before a member's pane appears, and
    /// the answers are only meaningful together anyway.
    ///
    /// The login shell is asked deliberately. `term-meshd` runs under systemd
    /// with its default PATH, which does not include `$HOME/.local/bin` — so
    /// the daemon cannot find a `codex` the user installed there. Resolving
    /// the path *here*, where the login profile has run, and handing the
    /// daemon `--exe <absolute path>` is what closes that gap.
    ///
    /// The role CLI and the bridge's executable are asked for separately
    /// because they are separate questions with separate consumers: the
    /// terminal path types the role name at a login shell, while `--exe` needs
    /// the binary the bridge spawns (`peerAgentExecutableName`). For every CLI
    /// but kiro they resolve to the same file, and asking twice costs nothing.
    static func remoteAgentBinariesProbe(
        cli: String,
        hostBinDirs: [String]
    ) -> String {
        RemoteShellPath.prologue(hostBinDirs: hostBinDirs)
            + "cli_path=$(command -v \(shellQuoted(cli)) 2>/dev/null || true); "
            + "exe_path=$(command -v \(shellQuoted(peerAgentExecutableName(cli: cli))) "
            + "2>/dev/null || true); "
            + "bridge_path=$(command -v tm-agent-bridge 2>/dev/null || true); "
            + "if [ -n \"$cli_path\" ]; then "
            + "printf '%s\\n' \(shellQuoted(remoteCLIAvailableMarker)); fi; "
            + "printf '%s%s\\n' \(shellQuoted(remoteCLIPathMarker)) \"$cli_path\"; "
            + "printf '%s%s\\n' \(shellQuoted(remoteExecPathMarker)) \"$exe_path\"; "
            + "printf '%s%s\\n' \(shellQuoted(remoteBridgePathMarker)) \"$bridge_path\""
    }

    /// Read the probe's answer out of whatever the login shell printed around
    /// it. Only absolute paths are accepted: `command -v` also names shell
    /// functions and builtins, and neither is something the daemon can spawn.
    static func parseRemoteAgentBinaries(_ output: String) -> RemoteAgentBinaries {
        var result = RemoteAgentBinaries()
        result.cliAvailable = output.contains(remoteCLIAvailableMarker)
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            func value(after marker: String) -> String? {
                guard let range = text.range(of: marker) else { return nil }
                let candidate = String(text[range.upperBound...])
                return candidate.hasPrefix("/") ? candidate : ""
            }
            if let cliPath = value(after: remoteCLIPathMarker), result.cliPath.isEmpty {
                result.cliPath = cliPath
            }
            if let execPath = value(after: remoteExecPathMarker), result.execPath.isEmpty {
                result.execPath = execPath
            }
            if let bridgePath = value(after: remoteBridgePathMarker), result.bridgePath.isEmpty {
                result.bridgePath = bridgePath
            }
        }
        return result
    }

    /// Fail before opening a pane when the CLI is not on the host, and report
    /// back what the same probe found — the CLI's absolute path and the
    /// bridge's, which is what the peer-owned agent factory needs.
    ///
    /// A host reached without ssh cannot be probed at all; it answers "no
    /// paths, assume available", which is exactly the pre-existing contract
    /// (this used to `return` early) and routes such a host to the terminal
    /// path, where nothing needs a path.
    @discardableResult
    private static func ensureRemoteCLIAvailable(
        cli: String,
        host: HostEntry
    ) async throws -> RemoteAgentBinaries {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
            return RemoteAgentBinaries(cliAvailable: true)
        }
        guard AgentRolePreset.knownCLIs.contains(cli) else {
            throw RemoteAgentError.cliUnavailable(cli, host.displayName)
        }
        let probe = remoteAgentBinariesProbe(cli: cli, hostBinDirs: host.hostCLIBinDirs)
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: "exec \"${SHELL:-/bin/sh}\" -lc \(shellQuoted(probe))",
                timeoutSeconds: 15
            )
            let binaries = parseRemoteAgentBinaries(output)
            guard binaries.cliAvailable else {
                throw RemoteAgentError.cliUnavailable(cli, host.displayName)
            }
            return binaries
        } catch {
            throw RemoteAgentError.cliUnavailable(cli, host.displayName)
        }
    }

    /// The daemon probe, wrapped so it can never affect the script it is
    /// appended to. `( … ) || true` contains both the deliberate `exit 44`
    /// that ends it on a non-Mac host and anything unexpected inside it.
    ///
    /// The leading `echo` is load-bearing: the readiness marker is written
    /// with `printf %s`, so without it the probe's first line arrives glued to
    /// the marker as `__TERMMESH_LEADER_READY__app=1234` and the parser — which
    /// matches whole-line keys — sees no app at all. That reads as "no app
    /// running", which is exactly the case that reports nothing stale, so the
    /// diagnostic would have been silent on every host.
    static let leaderDaemonDiagnostic =
        "( echo; " + PeerHostDoctor.daemonInstancesProbeBody + " ) 2>/dev/null || true"

    /// Say it before the leader starts, not only after something fails.
    ///
    /// Reads the diagnostic lines out of the readiness output — the parser
    /// only looks at `app=` / `daemon=` lines, so the readiness markers
    /// sharing that output are simply ignored. Never throws and never blocks
    /// the launch: a host with leftovers still gets its leader, it just stops
    /// being a silent condition.
    private static func reportStaleDaemons(in output: String, host: HostEntry) {
        let stale = PeerHostDoctor.staleDaemons(
            in: PeerHostDoctor.parseDaemonSnapshot(output)
        )
        guard !stale.isEmpty else { return }
        let pids = stale.map { String($0.pid) }.joined(separator: ", ")
        RemoteWorkLog.infoOffMain(
            "\(host.displayName): \(stale.count) term-meshd process(es) here serve nothing "
                + "(pid \(pids)) — Edit Peer Host → Clean Up Daemons stops them"
        )
#if DEBUG
        dlog("leader.prepare.staleDaemons host=\(host.id) count=\(stale.count) pids=\(pids)")
#endif
    }

    /// Probe only whether the requested CLI is available. Prompt staging
    /// belongs to the attached
    /// pane shell below: an SSH login shell may have a different /tmp namespace
    /// from the service that owns the peer surface.
    private static func prepareRemoteLeader(
        cli: String,
        host: HostEntry,
        environment: [String: String]
    ) async throws -> AgentEnvironmentSummary? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
            try await ensureRemoteCLIAvailable(cli: cli, host: host)
            return nil
        }
        guard AgentRolePreset.knownCLIs.contains(cli) else {
            throw RemoteAgentError.cliUnavailable(cli, host.displayName)
        }
        let marker = "__TERMMESH_LEADER_READY__"
        let missing = "__TERMMESH_LEADER_CLI_MISSING__"
        var script = RemoteShellPath.prologue(hostBinDirs: host.hostCLIBinDirs)
            + "if ! command -v \(shellQuoted(cli)) >/dev/null 2>&1; "
            + "then printf %s \(shellQuoted(missing)); exit 0; fi"
        script += "; printf %s \(shellQuoted(marker))"
        // Ride along on the round trip that is already happening. Two rules
        // make this safe to bolt onto the path that decides whether a leader
        // can start at all:
        //
        //  1. it comes AFTER the marker, so readiness is already decided by
        //     the time any of it runs;
        //  2. it is a subshell ending in `|| true`, so neither its `exit 44`
        //     on a non-Mac host nor any failure inside it reaches this
        //     script's exit status.
        //
        // Both matter because the `catch` below turns *every* error into
        // `cliUnavailable` — a diagnostic that leaked a failure out of here
        // would report a perfectly good host as having no CLI, and no leader
        // would start on it again.
        script += "; " + Self.leaderDaemonDiagnostic
        let environmentProbe = RemoteAgentEnvironmentShell.loginPrelude(
            profileFailureAction: "term_mesh_profile_fallback=failed",
            agentEnvFailureAction: "term_mesh_agent_env=failed"
        ) + RemoteAgentEnvironmentShell.exportAssignments(
            RemoteAgentEnvironmentShell.presenceOverlay(environment)
        )
            + RemoteAgentEnvironmentShell.diagnosticEvent
        script += "; ( " + RemoteAgentEnvironmentShell.accountLoginShellExec(environmentProbe)
            + " ) || true"
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: script,
                timeoutSeconds: 20
            )
            if output.contains(missing) {
                throw RemoteAgentError.cliUnavailable(cli, host.displayName)
            }
            guard output.contains(marker) else {
                throw RemoteAgentError.cliUnavailable(cli, host.displayName)
            }
            reportStaleDaemons(in: output, host: host)
            return AgentEnvironmentSummary.parse(from: output)
        } catch let error as RemoteAgentError {
            throw error
        } catch {
            throw RemoteAgentError.cliUnavailable(cli, host.displayName)
        }
    }

    private static func removeRemoteLeaderPrompt(host: HostEntry, promptFile: String) async {
        await removeRemoteLeaderFile(host: host, path: promptFile)
    }

    private static func removeRemoteLeaderFile(host: HostEntry, path: String) async {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return }
        _ = try? await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile,
            script: "rm -f -- \(shellQuoted(path))",
            timeoutSeconds: 10
        )
    }

    /// Put the leader's system prompt in the pane account's shared cache.
    ///
    /// Two routes, in cost order:
    ///
    ///  1. **SSH stdin → shared cache.** The bytes never become a command-line
    ///     argument, and the cache is outside a service's private `/tmp`.
    ///     Root SSH logins switch to the systemd unit's `User=` account using
    ///     the same resolver as remote paste transfer.
    ///  2. **Typed into the pane as base64 chunks.** Retained only for peer
    ///     connections that have no SSH route at all.
    ///
    /// Route 2 is why this exists. A 7 KB prompt is ~10 KB of base64 across
    /// ~14 typed commands, and a PTY in canonical mode holds 1024 bytes: sent
    /// back-to-back, most of it never reaches the shell, and every write still
    /// reports success. That is how a leader came to launch against a
    /// zero-byte prompt while the app believed staging had worked.
    private func stageRemoteLeaderPrompt(
        session: PeerPaneSession,
        host: HostEntry,
        systemPrompt: String,
        promptFile: String
    ) async -> String? {
        if let sshTarget = host.sshTarget, !sshTarget.isEmpty {
            guard let sharedPromptFile = await Self.writeRemoteLeaderPromptOverSSH(
                host: host, systemPrompt: systemPrompt, promptFile: promptFile
            ) else {
#if DEBUG
                dlog("leader.prompt.stage route=ssh_failed host=\(host.id)")
#endif
                RemoteWorkLog.infoOffMain(
                    "\(host.displayName): could not stream the leader prompt over SSH"
                )
                return nil
            }
#if DEBUG
            dlog("leader.prompt.stage route=ssh host=\(host.id)")
#endif
            return sharedPromptFile
        }
#if DEBUG
        dlog("leader.prompt.stage route=pty host=\(host.id)")
#endif
        RemoteWorkLog.infoOffMain(
            "\(host.displayName): no SSH route is available; typing the leader prompt instead"
        )
        let stages = Self.remoteLeaderPromptStageCommands(
            systemPrompt: systemPrompt,
            promptFile: promptFile
        )
        for stage in stages {
            // 0.35s, not 50ms. Each command must be consumed before the next
            // arrives or they queue into a 1 KB PTY buffer and are lost.
            guard await sendRemoteLeaderStage(
                session: session, text: stage, settleDelay: 0.35
            ) else { return nil }
        }
        return promptFile
    }

    private static func writeRemoteLeaderPromptOverSSH(
        host: HostEntry,
        systemPrompt: String,
        promptFile: String
    ) async -> String? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return nil }
        let fileName = (promptFile as NSString).lastPathComponent
        let script = remoteLeaderPromptSSHStageCommand(fileName: fileName)
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: script,
                standardInput: Data(systemPrompt.utf8),
                timeoutSeconds: 20
            )
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"),
                  !path.contains("\n"),
                  !path.contains("\0"),
                  (path as NSString).lastPathComponent == fileName
            else { return nil }
            return path
        } catch {
            return nil
        }
    }

    /// Stage the full leader launch outside the PTY and return a shared path.
    ///
    /// Linux canonical PTYs accept only a bounded input line. The login-shell
    /// prelude, environment diagnostics, grant and policy together can exceed
    /// that bound; the shell then receives only a prefix and waits forever at
    /// its continuation prompt. SSH stdin has no such line limit.
    private static func writeRemoteLeaderLaunchOverSSH(
        host: HostEntry,
        command: String,
        fileName: String
    ) async -> String? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return nil }
        let contents = "umask 077\nrm -f -- \"$0\"\n"
            + command
            + "\nterm_mesh_exit_status=$?\nstty echo\nexit \"$term_mesh_exit_status\"\n"
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: remoteLeaderLaunchSSHStageCommand(fileName: fileName),
                standardInput: Data(contents.utf8),
                timeoutSeconds: 20
            )
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"),
                  !path.contains("\n"),
                  !path.contains("\0"),
                  (path as NSString).lastPathComponent == fileName
            else { return nil }
            return path
        } catch {
            return nil
        }
    }

    static func remoteLeaderTurnHookSSHStageCommand(fileName: String) -> String {
        let quotedName = shellQuoted((fileName as NSString).lastPathComponent)
        return RemotePasteTransfer.serviceAccountCommand(
            "umask 077; d=\"${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/leader-hooks\"; "
                + "mkdir -p \"$d\" && chmod 700 \"$d\" || exit 1; "
                + "p=\"$d\"/\(quotedName); t=\"$p.tmp.$$\"; "
                + "trap 'rm -f \"$t\"' 0 1 2 15; "
                + "if cat > \"$t\" && chmod 700 \"$t\" && mv -f \"$t\" \"$p\"; "
                + "then trap - 0 1 2 15; printf %s \"$p\"; else exit 1; fi"
        )
    }

    static func localLeaderTurnHookData() -> Data? {
        [
            Bundle.main.resourceURL?.appendingPathComponent("scripts/leader-turn-hook.sh"),
            URL(fileURLWithPath: "scripts/leader-turn-hook.sh"),
        ].compactMap { $0 }.compactMap { try? Data(contentsOf: $0) }.first
    }

    static func remoteLeaderTurnHookFileName(teamUUID: String) -> String {
        let safeID = teamUUID.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
        }
        return "leader-turn-\(safeID.isEmpty ? "unknown" : safeID).sh"
    }

    static func remoteLeaderParticipationControlFileName(teamUUID: String) -> String {
        let safeID = teamUUID.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
        }
        return "leader-participation-\(safeID.isEmpty ? "unknown" : safeID).json"
    }

    /// End the host's daemon so the next connection starts a fresh one.
    ///
    /// This exists because a surface whose process is already gone cannot be
    /// removed any other way: `TerminateSurface` only reaches the live PTY
    /// registry, so a leftover record answers `NotFound` and the ClosePane
    /// fallback never confirms. Restarting the daemon drops those records, and
    /// until the daemon learns to clear them it is the only cure — so it
    /// belongs in the host menu rather than in a maintainer's terminal.
    ///
    /// Scoped to this user's own daemon. `-x` matches the executable name
    /// exactly so an unrelated process that merely mentions the name in its
    /// arguments is not a target; the second form covers a daemon launched by
    /// full path.
    static func restartPeerHostDaemonCommand() -> String {
        RemotePasteTransfer.serviceAccountCommand(
            "u=\"$(id -u)\"; "
                + "pkill -u \"$u\" -x term-meshd 2>/dev/null; "
                + "pkill -u \"$u\" -f 'Resources/bin/term-meshd' 2>/dev/null; "
                + "exit 0"
        )
    }

    /// Restart `host`'s daemon. The app reconnects on its own afterwards and
    /// the host starts a new daemon on that connection.
    func restartPeerHostDaemon(host: HostEntry) async throws {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }
        _ = try await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile,
            script: Self.restartPeerHostDaemonCommand(),
            timeoutSeconds: 30
        )
    }

    static func remoteLeaderArtifactCleanupCommand(teamUUID: String) -> String {
        let names = [
            remoteLeaderTurnHookFileName(teamUUID: teamUUID),
            remoteLeaderParticipationControlFileName(teamUUID: teamUUID),
        ]
        let paths = names.map { "\"$d\"/\(shellQuoted($0))" }.joined(separator: " ")
        return RemotePasteTransfer.serviceAccountCommand(
            "d=\"${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/leader-hooks\"; "
                + "rm -f -- \(paths)"
        )
    }

    private static func removeRemoteLeaderArtifacts(
        host: HostEntry,
        teamUUID: String
    ) async throws {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return }
        try await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile,
            script: remoteLeaderArtifactCleanupCommand(teamUUID: teamUUID),
            timeoutSeconds: 20
        )
    }

    static func remoteLeaderFileSSHStageCommand(fileName: String, mode: String) -> String {
        let quotedName = shellQuoted((fileName as NSString).lastPathComponent)
        let safeMode = mode == "700" ? "700" : "600"
        return RemotePasteTransfer.serviceAccountCommand(
            "umask 077; d=\"${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/leader-hooks\"; "
                + "mkdir -p \"$d\" && chmod 700 \"$d\" || exit 1; "
                + "p=\"$d\"/\(quotedName); t=\"$p.tmp.$$\"; "
                + "trap 'rm -f \"$t\"' 0 1 2 15; "
                + "if cat > \"$t\" && chmod \(safeMode) \"$t\" && mv -f \"$t\" \"$p\"; "
                + "then trap - 0 1 2 15; printf %s \"$p\"; else exit 1; fi"
        )
    }

    private static func writeRemoteLeaderFileOverSSH(
        host: HostEntry, data: Data, fileName: String, mode: String
    ) async -> String? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return nil }
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget, port: host.sshPort, identityFile: host.identityFile,
                script: remoteLeaderFileSSHStageCommand(fileName: fileName, mode: mode),
                standardInput: data, timeoutSeconds: 20
            )
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !path.contains("\n"),
                  (path as NSString).lastPathComponent == fileName else { return nil }
            return path
        } catch {
            return nil
        }
    }

    /// `delegationState` has to be passed explicitly. Omitting it silently wrote
    /// `leaderFirst` into every peer leader's control file regardless of the
    /// Project's configured level, so a peer leader could never observe the
    /// setting the user chose.
    /// - Returns: whether the file the leader reads was actually replaced.
    ///   The caller uses this to decide if the payload may be remembered as
    ///   delivered; a swallowed SSH failure must not look like a write.
    @discardableResult
    static func refreshRemoteLeaderParticipationControl(
        hostKey: String, teamUUID: String, teamName: String, payload data: Data
    ) async -> Bool {
        guard let host = await MainActor.run(body: {
            RemoteHostStore.shared.sortedHosts.first { $0.id == hostKey }
        }) else {
#if DEBUG
            dlog("leaderControl.noHost team=\(teamName) hostKey=\(hostKey)")
#endif
            return false
        }
        // The caller's exact bytes, not a fresh snapshot: it records these as
        // delivered, and recomputing here would let the two disagree.
        //
        // The write is over SSH and every failure inside it is swallowed, so
        // say whether the file the leader reads was actually replaced.
        let written = await writeRemoteLeaderFileOverSSH(
            host: host, data: data,
            fileName: remoteLeaderParticipationControlFileName(teamUUID: teamUUID),
            mode: "600"
        )
#if DEBUG
        dlog("leaderControl.result team=\(teamName) uuid=\(teamUUID) "
            + (written.map { "wrote=\($0)" } ?? "FAILED"))
#endif
        return written != nil
    }

    private static func writeRemoteLeaderTurnHookOverSSH(
        host: HostEntry, hookData: Data, teamUUID: String
    ) async -> String? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return nil }
        let fileName = remoteLeaderTurnHookFileName(teamUUID: teamUUID)
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget, port: host.sshPort, identityFile: host.identityFile,
                script: remoteLeaderTurnHookSSHStageCommand(fileName: fileName),
                standardInput: hookData, timeoutSeconds: 20
            )
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !path.contains("\n"),
                  (path as NSString).lastPathComponent == fileName else { return nil }
            return path
        } catch {
            return nil
        }
    }

    /// Stage an SSH-owned agent's explicit environment without placing API
    /// keys or the scoped team-route bearer in the local ssh process argv.
    /// PATH remains a separate additive bridge setting; every other valid
    /// entry is sourced once and the file is removed by the remote wrapper.
    private static func writeRemoteAgentEnvironmentOverSSH(
        host: HostEntry,
        environment: [String: String],
        agentInstanceID: String
    ) async -> String? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return nil }
        let fileName = "agent-\(agentInstanceID).env"
        let contents = PeerHostEnvironment.sanitized(environment)
            .filter { $0.key != "PATH" }
            .map { "export \($0.key)=\(shellQuoted($0.value))" }
            .joined(separator: "\n") + "\n"
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: remoteAgentEnvironmentSSHStageCommand(fileName: fileName),
                standardInput: Data(contents.utf8),
                timeoutSeconds: 20
            )
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"),
                  !path.contains("\n"),
                  !path.contains("\0"),
                  (path as NSString).lastPathComponent == fileName
            else { return nil }
            return path
        } catch {
            return nil
        }
    }

    private static func removeRemoteAgentEnvironmentOverSSH(
        host: HostEntry,
        path: String
    ) async {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return }
        _ = try? await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile,
            script: "rm -f -- \(shellQuoted(path))",
            timeoutSeconds: 10
        )
    }

    /// Constant-sized staging command; only the generated basename enters
    /// argv. The environment bytes themselves travel on SSH stdin.
    static func remoteAgentEnvironmentSSHStageCommand(fileName: String) -> String {
        let quotedName = shellQuoted((fileName as NSString).lastPathComponent)
        return "umask 077; "
            + "d=\"${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/agent-env\"; "
            + "mkdir -p \"$d\" && chmod 700 \"$d\" || exit 1; "
            + "p=\"$d\"/\(quotedName); t=\"$p.tmp.$$\"; "
            + "trap 'rm -f \"$t\"' 0 1 2 15; "
            + "if cat > \"$t\" && chmod 600 \"$t\" && mv -f \"$t\" \"$p\"; "
            + "then trap - 0 1 2 15; printf %s \"$p\"; else exit 1; fi"
    }

    /// The command is deliberately small and constant-sized. Prompt bytes
    /// arrive on stdin, land in a private temporary file, and become visible
    /// atomically only after the complete stream has arrived.
    static func remoteLeaderPromptSSHStageCommand(fileName: String) -> String {
        let quotedName = shellQuoted((fileName as NSString).lastPathComponent)
        return RemotePasteTransfer.serviceAccountCommand(
            "umask 077; "
                + "d=\"${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/leader-prompts\"; "
                + "mkdir -p \"$d\" && chmod 700 \"$d\" || exit 1; "
                + "p=\"$d\"/\(quotedName); t=\"$p.tmp.$$\"; "
                + "trap 'rm -f \"$t\"' 0 1 2 15; "
                + "if cat > \"$t\" && chmod 600 \"$t\" && mv -f \"$t\" \"$p\"; "
                + "then trap - 0 1 2 15; printf %s \"$p\"; else exit 1; fi"
        )
    }

    static func remoteLeaderLaunchSSHStageCommand(fileName: String) -> String {
        let quotedName = shellQuoted((fileName as NSString).lastPathComponent)
        return RemotePasteTransfer.serviceAccountCommand(
            "umask 077; "
                + "d=\"${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/leader-launches\"; "
                + "mkdir -p \"$d\" && chmod 700 \"$d\" || exit 1; "
                + "p=\"$d\"/\(quotedName); t=\"$p.tmp.$$\"; "
                + "trap 'rm -f \"$t\"' 0 1 2 15; "
                + "if cat > \"$t\" && chmod 600 \"$t\" && mv -f \"$t\" \"$p\"; "
                + "then trap - 0 1 2 15; printf %s \"$p\"; else exit 1; fi"
        )
    }

    static func remoteLeaderStagedLaunchCommand(path: String) -> String {
        "/bin/sh \(shellQuoted(path))"
    }

    /// Send one remote-leader bootstrap line directly to the attached peer
    /// PTY. A synthetic Return can be accepted by Ghostty without traversing
    /// the relay, leaving the command visibly typed but never executed.
    /// Command and CR therefore travel in one authenticated peer Input frame.
    private func sendRemoteLeaderStage(
        session: PeerPaneSession,
        text: String,
        settleDelay: TimeInterval = 0.5
    ) async -> Bool {
        var payload = Data(text.utf8)
        payload.append(0x0D)
        do {
            guard try await session.relaySession.sendRemoteKeys(payload) else {
                return false
            }
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, settleDelay) * 1_000_000_000)
            )
            return true
        } catch {
            return false
        }
    }

    /// Attach an agent to this team that runs on `hostKey`.
    ///
    /// The remote CLI is started by typing into the attached shell rather than
    /// spawned with an environment, because that is all an attached surface
    /// offers — the host published the shell, this side did not create it. So
    /// the agent gets no `TERMMESH_SOCKET` and cannot call `tm-agent` back
    /// here. It does not need to: the reply header it prints is read off the
    /// pane by the same poller that watches local agents, and that is what
    /// closes the task.
    @discardableResult
    func attachRemoteAgent(
        teamName: String,
        agentName: String,
        hostKey: String,
        workingDirectory: String,
        agentType: String = "executor",
        model: String = "sonnet",
        cli: String = "claude",
        agentInstanceId reservedAgentInstanceId: String? = nil
    ) async throws -> AgentMember {
        guard let team = teams[teamName] else { throw RemoteAgentError.teamNotFound(teamName) }
        let requiresDurableRemoteMember: Bool
        if team.ownsRemotePresentation, case .peer = team.leaderEndpoint {
            requiresDurableRemoteMember = true
        } else {
            requiresDurableRemoteMember = false
        }
        if requiresDurableRemoteMember,
           case let .peer(leaderHostKey) = team.leaderEndpoint,
           leaderHostKey != hostKey {
            throw RemoteAgentError.durableAgentUnavailable(
                cli: cli,
                host: hostKey,
                reason: "project.presentation.v1 requires every member on the leader host"
            )
        }
        let host = try await Self.waitForTeamHostLaunchReadiness(hostKey: hostKey)
        // An agent attach is not the leader, so it carries no attempt — but it
        // commits the same two things a project deletion tears down: a surface
        // record and a team member. Snapshot the generation now and refuse to
        // commit against a retired one, or a deletion that started mid-attach
        // finishes against a snapshot this then adds to, and the remote process
        // outlives everything pointing at it.
        let attachGeneration = LeaderAttachGenerationGate.shared.current(teamName: teamName)
        func attachStillWanted() -> Bool {
            LeaderAttachGenerationGate.shared
                .isCurrent(teamName: teamName, value: attachGeneration)
        }
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }) else {
            throw RemoteAgentError.workspaceGone
        }

        // Fail before opening any kind of pane. Otherwise a missing remote
        // executable leaves a dead native bridge or a terminal that looks like
        // an agent but only contains "command not found".
        //
        // The same probe reports where the CLI and `tm-agent-bridge` live on
        // that host. Both are what the peer-owned factory below ensures with,
        // so asking here costs no extra round trip.
        let binaries = try await Self.ensureRemoteCLIAvailable(cli: cli, host: host)

        // A late member joining one of this project's own checkouts gets an
        // instance-tagged worktree. The requested path may be the prefilled
        // primary or another member's worktree — both are recorded in
        // `remoteProjectLocations` — so derive the primary repository through
        // --git-common-dir before planning. Isolation failure is fatal here:
        // falling back would silently put two writers in one checkout.
        //
        // A path the project did not create stays exactly as typed. That is
        // the documented `--dir` contract, and it is what keeps non-git
        // directories (and projects created without isolation) reachable —
        // the caller who names a custom directory owns its sharing rules.
        let requestedDirectory = try Self.requiredRemoteWorkingDirectory(
            workingDirectory,
            hostKey: hostKey
        )
        let workingDirectory: String
        var isolatedCheckout: String?
        if team.remoteProjectLocations.containsLocation(
            hostKey: hostKey, path: requestedDirectory
        ) {
            let isolated = try await Self.prepareLateAgentCheckout(
                host: host,
                hostKey: hostKey,
                agentName: agentName,
                requestedDirectory: requestedDirectory
            )
            workingDirectory = isolated.path
            isolatedCheckout = isolated.path
        } else {
            workingDirectory = requestedDirectory
        }

        func recordIsolatedCheckout() {
            guard let path = isolatedCheckout else { return }
            var locations = teams[teamName]?.remoteProjectLocations ?? []
            let location = Team.RemoteProjectLocation(
                hostKey: hostKey, path: path, owned: true
            )
            if !locations.contains(location) {
                locations.append(location)
            }
            recordRemoteProjectLocations(
                teamName: teamName,
                locations: locations.sorted { ($0.hostKey, $0.path) < ($1.hostKey, $1.path) }
            )
        }

        // Captured for the launch task below, which outlives this call and so
        // reads plain values rather than the local `var` and the host entry.
        let createdCheckout = isolatedCheckout
        let hostName = host.displayName
        let hostSSHTarget = host.sshTarget
        let hostSSHPort = host.sshPort
        let hostIdentityFile = host.identityFile
        let agentInstanceId = reservedAgentInstanceId ?? UUID().uuidString
        var unownedRouteGrant: Termmesh_Peer_V1_TeamLeaderGrant?

        do {
        let routeGrant = try await bootstrapRemoteAgentRoute(teamName: teamName)
        unownedRouteGrant = routeGrant

        // Stage the route beside the worker before anything launches, so its
        // environment can name a file a later viewer is able to replace. A
        // host with no SSH provisioning route keeps the frozen variables and
        // the old ceiling: it works until the app that minted the grant quits.
        // A durable member may not accept that ceiling — surviving every
        // viewer is the entire promise it was created under.
        let routeFilePath = await Self.stageRemoteAgentRouteFile(
            host: host,
            agentInstanceID: agentInstanceId,
            grant: routeGrant
        )
        if routeFilePath == nil, requiresDurableRemoteMember {
            throw RemoteAgentError.environmentStagingFailed(host.displayName)
        }

        // Use the same incremental grid growth as local `add`/`attach`.
        let placement = nextAgentSplitPlacement(team: team, workspace: workspace)

        // Which of the three factories builds this member, and why.
        //
        // The difference that matters is *who owns the CLI process*, because
        // that is what decides whether the work survives this Mac:
        //
        // | factory | owner | survives this Mac | renders as |
        // |---|---|---|---|
        // | peer-owned agent | the peer's `term-meshd` | yes | AgentPanel |
        // | local native bridge | this app's ssh child | no | AgentPanel |
        // | terminal | the peer's `term-meshd` (PTY) | yes | terminal pane |
        //
        // **Peer-owned** is the only one that gives up neither, so codex and
        // kiro take it whenever the host can hold it: `tm-agent-bridge` is a
        // child of the peer daemon, so quitting here leaves the turn running
        // and a reattach picks the same surface back up, while its NDJSON
        // draws in an AgentPanel instead of scrolling past as a wire dump.
        // The ensure carries the same environment contract as other remote
        // native launches: active CLI profile, explicit host overrides, then
        // non-spoofable TERMMESH identity. Hosts must advertise the dedicated
        // ensure-env capability so an older decoder cannot silently drop it.
        //
        // **The local bridge** is the compatibility route for every supported
        // CLI when the peer-owned contract is unavailable. It costs survival
        // across this app quitting, but preserves the explicit Native setting.
        //
        // **Terminal** now means Native was disabled, the CLI is unsupported,
        // or no SSH route exists. Peer capability may choose ownership, never
        // override the renderer the user selected.
        // Preflight uses the cached endpoint snapshot for synchronous UI, but
        // process creation always re-checks the live team endpoint. A daemon
        // may restart between opening the sheet and pressing Create.
        let availability = await Self.canUsePeerOwnedAgent(
            host: host, cli: cli, binaries: binaries
        )
        if case .blocked(let block) = availability {
            RemoteWorkLog.info(
                Self.peerOwnedAgentFallbackMessage(
                    block, cli: cli, hostName: host.displayName
                )
            )
        }

        func attachSSHOwnedNativeAgent() async throws -> AgentMember {
            guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
                throw RemoteAgentError.paneCreationFailed
            }
            let member = try await attachRemoteNativeAgent(
                team: team,
                workspace: workspace,
                tabManager: tabManager,
                host: host,
                sshTarget: sshTarget,
                splitFrom: placement.panelId,
                orientation: placement.orientation,
                agentName: agentName,
                agentInstanceId: agentInstanceId,
                workingDirectory: workingDirectory,
                agentType: agentType,
                model: model,
                cli: cli,
                routeGrant: routeGrant,
                routeFilePath: routeFilePath
            )
            startRemoteAgentRouteKeepalive(
                teamName: teamName,
                agentInstanceID: member.agentInstanceId,
                grantID: routeGrant.grantID
            )
            unownedRouteGrant = nil
            recordIsolatedCheckout()
            return member
        }

        let factory = Self.remoteAgentFactory(
            cli: cli,
            hostAdvertisesAgentSurfaces: availability == .available,
            peerBridgePath: binaries.bridgePath,
            sshTarget: host.sshTarget
        )
        if requiresDurableRemoteMember, factory == .localNativeBridge {
            let reason: String
            if case .blocked(let block) = availability {
                reason = block.rawValue
            } else {
                reason = "no daemon-owned surface recipe"
            }
            throw RemoteAgentError.durableAgentUnavailable(
                cli: cli, host: host.displayName, reason: reason
            )
        }
        // Terminal and peer-owned routes need the serving host to proxy the
        // grant. Only SSH-owned Native has its own authenticated control hop.
        guard Self.teamRouteAllowsFactory(
            factory, liveAvailability: availability,
            cachedSnapshot: host.teamHostReadiness.snapshot
        ) else {
            throw RemoteAgentError.hostUpdateRequired(
                host: host.displayName,
                version: host.teamHostReadiness.snapshot?.appVersion
            )
        }

        switch factory {
        case .peerOwnedAgent:
            guard attachStillWanted() else {
                throw RemoteAgentError.teamNotFound(teamName)
            }
            do {
                let member = try await attachPeerOwnedAgent(
                    team: team,
                    workspace: workspace,
                    host: host,
                    binaries: binaries,
                    splitFrom: placement.panelId,
                    orientation: placement.orientation,
                    agentName: agentName,
                    agentInstanceId: agentInstanceId,
                    workingDirectory: workingDirectory,
                    agentType: agentType,
                    model: model,
                    cli: cli,
                    routeGrant: routeGrant,
                    routeFilePath: routeFilePath,
                    stillWanted: attachStillWanted
                )
                startRemoteAgentRouteKeepalive(
                    teamName: teamName,
                    agentInstanceID: member.agentInstanceId,
                    grantID: routeGrant.grantID
                )
                unownedRouteGrant = nil
                recordIsolatedCheckout()
                return member
            } catch let error as RemoteAgentError {
                // A decision this side made — the roster already holds this
                // member, or the team was retired mid-attach. The SSH-owned
                // path would reach the same answer after spawning a second
                // process for nothing, so it is reported rather than retried.
                throw error
            } catch let error as PeerEnsureEnvironment.ValidationError {
                // This is a local configuration refusal, not the host saying
                // no. Values never enter the diagnostic; the shared validator
                // reports only the offending key or aggregate limit.
                RemoteWorkLog.info(
                    Self.peerOwnedAgentInvalidEnvironmentFallbackMessage(
                        error, cli: cli, hostName: host.displayName
                    )
                )
                if requiresDurableRemoteMember {
                    throw RemoteAgentError.environmentStagingFailed(host.displayName)
                }
                return try await attachSSHOwnedNativeAgent()
            } catch {
                // The host's answer, not ours. `canUsePeerOwnedAgent` read the
                // capability off a connection it then closed, so the host can
                // stop advertising it in between — and an ensure refused
                // locally or on the wire creates nothing there. Falling
                // The Native setting still wins: use the existing SSH-owned
                // renderer, sacrificing peer-owned survival rather than the
                // pane type the user explicitly chose.
                RemoteWorkLog.info(
                    Self.peerOwnedAgentFallbackMessage(
                        .ensureRefused, cli: cli, hostName: host.displayName
                    )
                )
                if requiresDurableRemoteMember {
                    throw RemoteAgentError.durableAgentUnavailable(
                        cli: cli, host: host.displayName, reason: "ensure refused"
                    )
                }
                return try await attachSSHOwnedNativeAgent()
            }
        case .localNativeBridge:
            return try await attachSSHOwnedNativeAgent()
        case .terminal:
            // The one terminal pane that is not a graceful degradation: a
            // turn-per-process CLI has no interactive UI to put in it, so the
            // pane opens and stays blank. Say so rather than letting the user
            // discover it by staring at it.
            if AgentPipeTransport.isPipeOnly(cli: cli) {
                RemoteWorkLog.info(
                    "\(cli) has no interactive terminal UI, so \(agentName) on "
                        + "\(host.displayName) will open an empty pane. It needs a "
                        + "native agent pane: turn Agent Panes back to Native, or "
                        + "reach that host over SSH."
                )
            }
        }

        let registry = PeerPaneHostRegistry.shared
        let lease = try await registry.acquire(Self.requireTeamHostSpec(host))
        let panel: TerminalPanel
        let attachedSurfaceID: Data
        var spawnedSurface = false
        var spawnedSurfaceID: Data?
        do {
            let surfaces = try await PeerPaneSession.listSurfaces(on: lease)
            // Ask for a shell of our own rather than taking one of the
            // host's published surfaces.
            //
            // An agent's first act is to type a launch command, which only
            // means anything at a shell prompt. Whether a listed surface is at
            // one cannot be known from the listing: `SurfaceInfo` says a
            // surface is attachable, not that it is idle, and attaching twice
            // is legal — so a shell running someone else's agent looks exactly
            // like a free one. Reusing it types `mkdir … && claude …` into
            // that agent's prompt, which answers in prose about how it cannot
            // run shell commands. The pane looks attached and nothing started.
            //
            // Tracking which surfaces our own agents hold only covers the ones
            // this app knows about, and the ones that cause this are the
            // others: a previous run, a crash, another machine's term-mesh.
            // Spawning is the only way to be sure, and abandoned surfaces are
            // reaped by the host, so asking for one costs nothing lasting.
            let taken = Set(
                teams.values
                    .flatMap(\.agents)
                    .filter { $0.hostKey == hostKey }
                    .compactMap(\.remoteSurfaceID)
            )
            let remotePlacement = try await remoteSurfacePlacement(
                teamName: teamName,
                host: host,
                fallbackSourceID: surfaces.first?.surfaceID
            )
            let usesDedicatedWorkspace = remotePlacement?.isDedicated == true

            // Legacy/generic teams retain the best-effort free-surface
            // fallback. New Project is stricter: taking an arbitrary host
            // surface would put the member back under relay/default, exactly
            // the mixing the dedicated workspace exists to prevent.
            var chosen = usesDedicatedWorkspace
                ? nil
                : surfaces.first { $0.attachable && !taken.contains($0.surfaceID) }
            if let remotePlacement {
                if remotePlacement.useSourceDirectly {
                    let refreshed = try await PeerPaneSession.listSurfaces(on: lease)
                    chosen = refreshed.first { $0.surfaceID == remotePlacement.sourceID }
                } else if let fresh = try await PeerPaneSession.spawnSurface(
                    on: lease,
                    splitting: remotePlacement.sourceID
                ) {
                    chosen = fresh
                }
            }
            guard attachStillWanted() else {
                throw RemoteAgentError.teamNotFound(teamName)
            }
            if let chosen,
               usesDedicatedWorkspace || !surfaces.contains(where: { $0.surfaceID == chosen.surfaceID }) {
                spawnedSurface = true
                spawnedSurfaceID = chosen.surfaceID
                ManagedPeerSurfaceStore.shared.remember(
                    hostKey: hostKey,
                    surfaceID: chosen.surfaceID,
                    teamName: teamName,
                    role: agentName,
                    workingDirectory: workingDirectory
                )
            }
            guard let chosen else {
                registry.release(lease)
                throw RemoteAgentError.noAttachableSurface(host.displayName)
            }
            let session = try await PeerPaneSession.attach(
                lease: lease,
                surface: chosen,
                title: agentName,
                spec: Self.requireTeamHostSpec(host)
            )
            registry.release(lease)
            guard let opened = workspace.openRemotePane(
                session: session,
                orientation: placement.orientation,
                focus: false,
                from: placement.panelId,
                lifetime: .keepAlive
            ) else {
                session.teardown()
                throw RemoteAgentError.paneCreationFailed
            }
            panel = opened
            attachedSurfaceID = chosen.surfaceID
            // The shell being attached to may have been left in a TUI's modes
            // by whoever had it last — mouse reporting especially, which turns
            // every movement over this pane into a command at the far prompt.
            opened.surface.resetTerminal()
        } catch {
            registry.release(lease)
            if let spawnedSurfaceID {
                // Leases rather than looks up. Both callers reach here having
                // just given up the thing that held the team tunnel — one
                // released the lease, the other closed the pane — so a lookup
                // finds nothing and the surface this is compensating for stays
                // up on the host.
                _ = await Self.withTeamSockPath(host: host) { sockPath in
                    await Self.closeManagedRemoteSurface(
                        hostSockPath: sockPath,
                        hostKey: hostKey,
                        surfaceID: spawnedSurfaceID
                    )
                }
            }
            throw error
        }

        let colorList = ["green", "blue", "yellow", "magenta", "cyan", "red"]
        let agentColor = colorList[team.agents.count % colorList.count]
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "\(Self.colorEmoji(agentColor)) \(agentName) @\(host.displayName)"
        )

        let member = AgentMember(
            id: "\(agentName)@\(teamName)",
            agentInstanceId: agentInstanceId,
            name: agentName,
            teamName: teamName,
            cli: cli,
            launchCommand: cli,
            model: model,
            agentType: agentType,
            color: agentColor,
            instructions: "",
            workspaceId: workspace.id,
            panelId: panel.id,
            createdAt: Date(),
            remoteSurfaceID: attachedSurfaceID,
            remoteSurfaceSpawned: spawnedSurface,
            hostKey: hostKey,
            originalAgentWorkDir: workingDirectory
        )
        // Last gate before the member becomes part of the team. A deletion that
        // began while this was attaching has already decided the roster; adding
        // to it here is the orphan.
        guard attachStillWanted() else {
            throw RemoteAgentError.teamNotFound(teamName)
        }
        guard adoptAgentMember(member, teamName: teamName) else {
            _ = workspace.closePanel(panel.id, force: true)
            if let spawnedSurfaceID {
                // Leases rather than looks up. Both callers reach here having
                // just given up the thing that held the team tunnel — one
                // released the lease, the other closed the pane — so a lookup
                // finds nothing and the surface this is compensating for stays
                // up on the host.
                _ = await Self.withTeamSockPath(host: host) { sockPath in
                    await Self.closeManagedRemoteSurface(
                        hostSockPath: sockPath,
                        hostKey: hostKey,
                        surfaceID: spawnedSurfaceID
                    )
                }
            }
            throw RemoteAgentError.duplicateInstance(member.agentInstanceId)
        }
        scheduleAgentGridEqualization(workspace: workspace)
        // Remembered on success rather than on typing, so a path that turned
        // out to be wrong is not the one offered next time.
        RemoteProjectPaths.shared.remember(
            host: hostKey,
            localRoot: team.workingDirectory,
            path: workingDirectory
        )
        AutoReplyPoller.shared.ensureRunning()
        let hostCLIBinDirs = host.hostCLIBinDirs

        // Start the CLI once the remote shell is actually reading. The same
        // race a local pane has, for the same reason: text that arrives while
        // a shell is still coming up lands in a buffer nobody submits.
        Task { @MainActor in
            guard let session = panel.peerPaneSession else { return }
            await Self.waitForRemoteShell(session: session)
            // This command carries the scoped route grant. Disable terminal
            // echo and history first so it is neither rendered nor retained
            // by the interactive shell.
            guard await self.sendRemoteLeaderStage(
                session: session,
                text: Self.remoteLeaderPrepareCommand(),
                settleDelay: 0.35
            ) else {
                RemoteWorkLog.info(
                    "\(agentName) on \(hostName): could not prepare the shell for a secure launch"
                )
                return
            }
            let command = Self.remoteAgentCommand(
                cli: cli,
                model: model,
                agentName: agentName,
                teamName: teamName,
                workingDirectory: workingDirectory,
                environment: PeerHostEnvironment.stored(forHostKey: hostKey)
                    .merging(Self.remoteNativeAgentEnvironment(
                        teamName: teamName,
                        agentName: agentName,
                        agentType: agentType,
                        agentCli: cli,
                        workspaceId: workspace.id,
                        // A peer socket speaks protobuf framing, not the app
                        // JSON-RPC protocol. The remote pane already inherits
                        // its owning app/daemon control socket; preserve it.
                        socketPath: nil,
                        routeGrant: routeGrant,
                        routeFilePath: routeFilePath
                    )) {
                        _, internalValue in internalValue
                    },
                hostBinDirs: hostCLIBinDirs,
                needsSocketAccess: true
            )
            _ = self.sendToAgentByPanel(
                teamName: teamName,
                panelId: panel.id,
                workspaceId: workspace.id,
                text: command,
                tabManager: tabManager,
                withReturn: true,
                recordPendingReturnFor: agentName,
                // The launch line is the last thing this attach owes the agent,
                // and it is typed after the function has already returned — so
                // a failure here lands outside the `catch` below, which is how
                // a checkout made for an agent that never started was left on
                // the peer with a location record still pointing at it.
                //
                // Only a *reported* failure compensates. `sendTextToPanel`
                // answers `false` synchronously on its first miss and then
                // retries; it calls back with `false` only once it has given
                // up finding the pane, which means the line was never typed.
                completion: { delivered in
                    guard !delivered else { return }
                    Task { @MainActor in
                        await self.abandonIsolatedRemoteCheckout(
                            teamName: teamName,
                            hostKey: hostKey,
                            agentName: agentName,
                            hostName: hostName,
                            sshTarget: hostSSHTarget,
                            sshPort: hostSSHPort,
                            identityFile: hostIdentityFile,
                            path: createdCheckout,
                            reason: "its pane was gone before the launch line could be typed"
                        )
                    }
                }
            )
        }

        startRemoteAgentRouteKeepalive(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            grantID: routeGrant.grantID
        )
        unownedRouteGrant = nil
        recordIsolatedCheckout()
        return member
        } catch {
            if let grant = unownedRouteGrant {
                await PeerTeamLeaderControlPlane.shared.revokeGrant(id: grant.grantID)
            }
            await abandonIsolatedRemoteCheckout(
                teamName: teamName,
                hostKey: hostKey,
                agentName: agentName,
                hostName: host.displayName,
                sshTarget: host.sshTarget,
                sshPort: host.sshPort,
                identityFile: host.identityFile,
                path: isolatedCheckout,
                reason: error.localizedDescription
            )
            throw error
        }
    }

    /// Give back a checkout this attach made, when the agent it was made for
    /// never started.
    ///
    /// Two callers, one order, and the order is the point. The location record
    /// goes first because `reapDetachedAgentWorktree` gates on it: with the
    /// record gone, detaching the half-attached member later cannot reap the
    /// same path a second time. Then the reap itself, which is best effort by
    /// design — the remote script refuses anything that is not a clean linked
    /// worktree, so a checkout that did get used is kept rather than deleted.
    ///
    /// `path` is nil whenever this attach did not create a checkout, which is
    /// the case that matters most: a directory the caller named, or one
    /// another member already owns, is never reaped by a failure here.
    @MainActor
    private func abandonIsolatedRemoteCheckout(
        teamName: String,
        hostKey: String,
        agentName: String,
        hostName: String,
        sshTarget: String?,
        sshPort: Int?,
        identityFile: String?,
        path: String?,
        reason: String
    ) async {
        guard let path else { return }
        let locations = knownRemoteProjectLocations(teamName: teamName)
        if !locations.isEmpty {
            let remaining = Self.remoteProjectLocations(
                locations, abandoning: path, onHost: hostKey
            )
            if remaining.count != locations.count {
                recordRemoteProjectLocations(teamName: teamName, locations: remaining)
            }
        }
        guard let sshTarget, !sshTarget.isEmpty else { return }
        RemoteWorkLog.info(
            "\(agentName) never started on \(hostName) (\(reason)); "
                + "reclaiming \(path) (kept if it held uncommitted work)."
        )
        await PeerProjectBootstrap.reapWorktree(
            sshTarget: sshTarget,
            port: sshPort,
            identityFile: identityFile,
            path: path
        )
    }

    /// The team's locations with one checkout's entry taken out.
    ///
    /// Matched on host *and* path together: two machines routinely lay a
    /// project out at the same path, and dropping every entry with that path
    /// would disarm the detach-time reap for a member on another host that is
    /// still running.
    nonisolated static func remoteProjectLocations(
        _ locations: [Team.RemoteProjectLocation],
        abandoning path: String,
        onHost hostKey: String
    ) -> [Team.RemoteProjectLocation] {
        locations.filter { !($0.hostKey == hostKey && $0.path == path) }
    }

    /// Filesystem entries Delete Project may remove. A source checkout the
    /// user selected is a routing input, not project-owned storage. Keeping
    /// this decision pure lets a fast test fail if deletion ever broadens back
    /// to every path associated with the team.
    nonisolated static func ownedRemoteProjectLocations(
        _ locations: [Team.RemoteProjectLocation]
    ) -> [Team.RemoteProjectLocation] {
        locations.filter(\.owned)
    }

    // MARK: - Peer-owned agent surface

    /// Which of the three factories builds a remote member.
    ///
    /// They differ in *who owns the process*, which is the only difference
    /// that matters when the Mac goes away:
    ///
    /// | factory | owner | survives the Mac | renders as |
    /// |---|---|---|---|
    /// | `peerOwnedAgent` | the peer's `term-meshd` | yes | AgentPanel |
    /// | `localNativeBridge` | this app's ssh child | no | AgentPanel |
    /// | `terminal` | the peer's `term-meshd` (PTY) | yes | terminal pane |
    enum RemoteAgentFactory: String, Equatable, Sendable {
        /// `ensure(kind: "agent")` — the peer daemon holds `tm-agent-bridge`
        /// as a non-PTY child and streams its NDJSON here.
        case peerOwnedAgent
        /// The bridge runs as a child of this app's ssh. Nothing exists on
        /// the peer, so the member dies with this process.
        case localNativeBridge
        /// A peer PTY the member's CLI is typed into.
        case terminal
    }

    /// Decide which factory a remote member gets, from facts alone.
    ///
    /// Deliberately total and free of I/O so the matrix can be pinned in a
    /// test: every combination of CLI, host capability and bridge presence
    /// has one answer here, and the call site does no second-guessing.
    ///
    /// Claude is excluded from *peer ownership* for harder reasons, while its
    /// existing SSH-native path still satisfies the renderer contract:
    ///  - `tm-agent-bridge --cli` has no `claude` value at all
    ///    (`daemon/tm-agent-bridge/src/main.rs`), so the peer-owned recipe
    ///    this file builds does not cover it. Spawning `claude --print …`
    ///    directly would be a second, differently shaped ensure spec.
    ///  - the daemon reads `SurfaceInfo.agent_cli` out of the request's own
    ///    `--cli` argument (`connection.rs`, `agent_cli_from_args`), which a
    ///    direct claude vector does not carry — the surface would report an
    ///    empty CLI label and a reattach would have nothing to pick a
    ///    renderer by.
    ///  - claude takes its runbook as `--append-system-prompt <text>`, and
    ///    `args` join `SurfaceSpec::canonical_hash` on the daemon. The
    ///    runbook would become part of the surface's identity, so editing it
    ///    would turn every reattach into a SPEC_CONFLICT — which is exactly
    ///    the reattach this whole path exists for.
    /// None of that prevents a Native pane; it only determines which machine
    /// owns the process behind that pane.
    static func remoteAgentFactory(
        cli: String,
        hostAdvertisesAgentSurfaces: Bool,
        peerBridgePath: String,
        sshTarget: String?
    ) -> RemoteAgentFactory {
        let reachableOverSSH = !(sshTarget ?? "").isEmpty
        // Native panes off, or a CLI no panel can hold (gemini): unchanged.
        guard AgentPipeTransport.canHoldNatively(cli: cli) else { return .terminal }
        guard reachableOverSSH else { return .terminal }
        // Prefer the durable peer-owned renderer whenever the serving daemon
        // can hold it. Claude speaks stream-json directly; the other
        // session-shaped CLIs use tm-agent-bridge. Native is nevertheless a rendering
        // contract, not a durability hint: an older daemon must fall back to
        // the already-supported SSH-owned native process, never to a terminal.
        let hasPeerRecipe = cli == "claude"
            || (AgentPipeTransport.needsBridge(cli: cli) && !peerBridgePath.isEmpty)
        if hostAdvertisesAgentSurfaces, hasPeerRecipe {
            return .peerOwnedAgent
        }
        return .localNativeBridge
    }

    /// What stopped a member that could have had a peer-owned agent pane.
    ///
    /// Only reasons a *user* can act on. The distinction between them is the
    /// whole point: "install term-mesh there" and "update term-mesh there" are
    /// different repairs, and one message covering both tells nobody which.
    enum PeerOwnedAgentBlock: String, Equatable, Sendable, CaseIterable {
        /// No `tm-agent-bridge` on the host.
        case bridgeMissing
        /// Its `term-meshd` lacks one of the peer-owned agent contract's
        /// agent, authoritative-exit, or ensure-environment capabilities.
        case daemonTooOld
        /// The handshake that would have answered could not be made.
        case hostUnreachable
        /// It was open at the check and refused at the ensure — the host
        /// changed underneath, or said no for its own reason.
        case ensureRefused
        /// The host is serving the peer protocol from the term-mesh app, and
        /// named no `term-meshd` to take durable work. A GUI process owns no
        /// lifecycle past its own, so no version of it can host an agent —
        /// which makes "update term-mesh there" the wrong instruction and
        /// "start its daemon" the right one.
        case guiHostNoSessionOwner
    }

    /// `host.teamHostSpec`, or the retryable failure every team call site
    /// already raises for a socket it cannot reach.
    ///
    /// An unresolved route and a dead socket deserve the same response — wait
    /// and try again — so they raise the same error rather than a second one
    /// callers would have to learn. Lives here rather than on `HostEntry`
    /// because the error is the orchestrator's; a host row should not have to
    /// know how team work reports failure.
    static func requireTeamHostSpec(_ host: HostEntry) throws -> PeerPaneHostSpec {
        guard let spec = host.teamHostSpec else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }
        return spec
    }

    static func teamHostCanLaunch(_ host: HostEntry) -> Bool {
        guard host.isLaunchable,
              let endpoint = host.teamHostSpec?.hostKey,
              host.teamHostReadiness.snapshot?.endpoint == endpoint
        else { return false }
        return true
    }

    /// A sidebar row becomes connected before authenticated launch metadata
    /// and the session-owner route land. Wait for the same complete answer the
    /// creation UI requires instead of freezing that partial snapshot into a
    /// permanent attach failure.
    @MainActor
    static func waitForTeamHostLaunchReadiness(
        hostKey: String,
        timeoutNanoseconds: UInt64 = 15_000_000_000
    ) async throws -> HostEntry {
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            try Task.checkCancellation()
            guard let host = RemoteHostStore.shared.sortedHosts.first(where: {
                $0.id == hostKey
            }) else {
                throw RemoteAgentError.hostNotFound(hostKey)
            }
            if teamHostCanLaunch(host) { return host }
            if case .failed = host.connectionState {
                throw RemoteAgentError.hostNotConnected(host.displayName)
            }
            if DispatchTime.now().uptimeNanoseconds &- started >= timeoutNanoseconds {
                throw RemoteAgentError.hostNotConnected(host.displayName)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Local socket to dial for a team RPC on `host`, without starting a
    /// tunnel.
    ///
    /// Team surfaces live on `teamHostSpec`, which on a redirected host is not
    /// the socket the sidebar mirrors from. Addressing such a surface through
    /// `activeSockPath` reaches a peer server that never created it and
    /// reports success for closing nothing. Empty means "no live route" —
    /// every caller already treats that as "skip", the same as a disconnected
    /// host.
    /// Run `body` against a local socket for team RPCs on `host`, holding a
    /// tunnel lease for its duration.
    ///
    /// `liveTeamSockPath` only *finds* a tunnel, which is right for the hot
    /// paths that run beside a live pane and wrong for everything that runs
    /// after the panes are gone. Project deletion is the case that named this:
    /// it closes the team's panes, which drops the last lease, and only then
    /// asks the host to remove the workspace and the manifest — so the endpoint
    /// it needs is the one its own earlier steps just tore down.
    ///
    /// Returns nil without calling `body` when the route is unresolved or the
    /// tunnel cannot be established; callers already treat that as the
    /// retryable "host not connected".
    static func withTeamSockPath<T>(
        host: HostEntry,
        _ body: (String) async throws -> T
    ) async rethrows -> T? {
        guard let spec = host.teamHostSpec else { return nil }
        guard host.redirectsTeamWorkToSessionHost else {
            guard !host.activeSockPath.isEmpty else { return nil }
            return try await body(host.activeSockPath)
        }
        guard let lease = try? await PeerPaneHostRegistry.shared.acquire(spec)
        else { return nil }
        defer { PeerPaneHostRegistry.shared.release(lease) }
        let sockPath = lease.hostSockPath
        guard !sockPath.isEmpty else { return nil }
        return try await body(sockPath)
    }

    static func liveTeamSockPath(for host: HostEntry) -> String {
        // Empty while the route is unknown, which callers already treat as
        // "host not connected" and retry. Answering `activeSockPath` here
        // instead would aim team RPCs at the serving socket for the window
        // between a reconnect and its handshake — and on a redirecting host
        // that socket did not create any of the surfaces being named.
        guard host.teamRouteResolved else { return "" }
        guard host.redirectsTeamWorkToSessionHost,
              let teamKey = host.teamHostSpec?.hostKey
        else { return host.activeSockPath }
        return PeerPaneHostRegistry.shared
            .existingLocalSockPath(for: teamKey) ?? ""
    }

    /// Whether a handshake came from the Swift GUI peer server rather than a
    /// `term-meshd`.
    ///
    /// `PeerServer` strips exactly `surface.agent.v1` and
    /// `project.presentation.v1` from an otherwise complete list, because a
    /// GUI host publishes TerminalPanels and owns nothing past its own quit.
    /// A daemon old enough to predate peer-owned agents is missing that whole
    /// group — the ensure-environment and authoritative-exit halves too — so
    /// requiring those to be *present* is what separates "cannot, by design"
    /// from "cannot, for now".
    static func looksLikeGUIPeerHost(_ capabilities: PeerCapabilities) -> Bool {
        RemoteHostStore.looksLikeGUIPeerHost(capabilities)
    }

    static func peerOwnedAvailability(
        from snapshot: TeamHostCapabilitySnapshot
    ) -> PeerOwnedAgentAvailability {
        guard snapshot.supportsDurableRemoteCreation else {
            return .blocked(snapshot.peerOwnedAgentIssue == .guiHostNoSessionOwner
                ? .guiHostNoSessionOwner : .daemonTooOld)
        }
        return .available
    }

    static func teamRouteAllowsFactory(
        _ factory: RemoteAgentFactory,
        liveAvailability: PeerOwnedAgentAvailability,
        cachedSnapshot: TeamHostCapabilitySnapshot?
    ) -> Bool {
        factory == .localNativeBridge
            || liveAvailability == .available
            || cachedSnapshot?.lacksRemoteTeamRoute != true
    }

    /// Whether the peer-owned path is open for this member.
    ///
    /// `notApplicable` is not a failure and must not be reported as one: a
    /// terminal-only or turn-per-process member has no daemon-owned native
    /// recipe. Only `blocked` describes something the user lost.
    enum PeerOwnedAgentAvailability: Equatable, Sendable {
        case available
        case notApplicable
        case blocked(PeerOwnedAgentBlock)
    }

    /// The one line the user sees when the durable peer-owned native process
    /// was unavailable and the app kept the Native pane contract over SSH.
    ///
    /// Pure and separate from the check so the wording is pinned by a test
    /// rather than by whoever reads the log next: what opened instead, on
    /// which host, and the single action that would give the agent pane back.
    static func peerOwnedAgentFallbackMessage(
        _ block: PeerOwnedAgentBlock,
        cli: String,
        hostName: String
    ) -> String {
        let lead = "\(cli) on \(hostName) uses an SSH-owned native agent pane"
        switch block {
        case .bridgeMissing:
            return lead + ": that host has no tm-agent-bridge, so this agent "
                + "will not survive quitting this Mac. Install term-mesh on \(hostName) "
                + "to make the peer own it."
        case .daemonTooOld:
            return lead + ": its serving term-meshd lacks the required agent, exit, "
                + "or ensure-environment protocol capability, so this agent will not "
                + "survive quitting this Mac. Restart or update term-mesh on \(hostName) "
                + "to make the peer own it."
        case .hostUnreachable:
            return lead + ": its term-meshd could not be asked what it supports, "
                + "so this agent will not survive quitting this Mac. Reconnect "
                + "\(hostName) and attach again to make the peer own it."
        case .ensureRefused:
            return lead + ": the host refused to start its bridge, so this agent "
                + "will not survive quitting this Mac. Nothing was left running "
                + "there; attach again to retry peer ownership."
        case .guiHostNoSessionOwner:
            return lead + ": \(hostName) is serving the peer protocol from the "
                + "term-mesh app, which owns nothing past its own quit, and named "
                + "no term-meshd to take durable work. Updating term-mesh there "
                + "will not change this. Start its daemon — reopen term-mesh on "
                + "\(hostName) with peer auto-start enabled — to make the peer own it."
        }
    }

    static func peerOwnedAgentInvalidEnvironmentFallbackMessage(
        _ error: PeerEnsureEnvironment.ValidationError,
        cli: String,
        hostName: String
    ) -> String {
        "\(cli) on \(hostName) uses an SSH-owned native agent pane because the configured "
            + "peer environment is invalid (\(error.localizedDescription)). Fix the active CLI "
            + "profile or explicit host environment to restore peer ownership."
    }

    /// Ask the host connection itself whether the peer-owned path is open.
    ///
    /// Preflight caches an endpoint-bound snapshot on `HostEntry`, but process
    /// creation re-checks the live endpoint so a daemon restart cannot make a
    /// stale UI answer authorize work. Every answer other than `available`
    /// preserves Native rendering with an SSH-owned process when SSH exists.
    ///
    /// Reporting is the caller's, deliberately. This is also the shape of the
    /// answer the factory wants, and a function that both decides and
    /// announces cannot be asked the question twice.
    static func canUsePeerOwnedAgent(
        host: HostEntry,
        cli: String,
        binaries: RemoteAgentBinaries
    ) async -> PeerOwnedAgentAvailability {
        guard AgentPipeTransport.canHoldNatively(cli: cli),
              let sshTarget = host.sshTarget, !sshTarget.isEmpty
        else { return .notApplicable }
        if AgentPipeTransport.needsBridge(cli: cli), binaries.bridgePath.isEmpty {
            return .blocked(.bridgeMissing)
        }
        // Probe the endpoint the ensure will actually use, not the one the
        // sidebar is mirroring from. On a host that named a session owner
        // those differ, and asking the wrong one is how a capable machine
        // reported itself incapable.
        // Unresolved is not "no redirect": probing the serving socket here
        // would report a capable machine as incapable for the window between a
        // reconnect and its handshake, and the caller would then open the
        // SSH-owned fallback pane that this whole path exists to avoid.
        guard host.teamRouteResolved else { return .blocked(.hostUnreachable) }
        var teamLease: PeerPaneHostLease?
        let probeSockPath: String
        if host.redirectsTeamWorkToSessionHost {
            guard let teamSpec = host.teamHostSpec,
                  let lease = try? await PeerPaneHostRegistry.shared.acquire(teamSpec)
            else { return .blocked(.hostUnreachable) }
            teamLease = lease
            probeSockPath = lease.hostSockPath
        } else {
            probeSockPath = host.activeSockPath
        }
        func releaseTeamLease() {
            if let teamLease { PeerPaneHostRegistry.shared.release(teamLease) }
        }
        guard !probeSockPath.isEmpty,
              let connection = try? await PeerRelaySession.connect(
                  hostSockPath: probeSockPath
              )
        else {
            releaseTeamLease()
            return .blocked(.hostUnreachable)
        }
        let capabilities = connection.hostCapabilities
        let snapshot = RemoteHostStore.teamHostCapabilitySnapshot(
            endpoint: host.teamHostSpec?.hostKey ?? host.paneHostSpec.hostKey,
            capabilities: capabilities,
            appVersion: connection.hostAppVersion,
            redirectedFromServingEndpoint: host.redirectsTeamWorkToSessionHost
        )
        await connection.cancel()
        releaseTeamLease()
        return peerOwnedAvailability(from: snapshot)
    }

    /// The logical key an agent surface is ensured under.
    ///
    /// The instance id is what makes it unique and is never truncated — two
    /// members of one team must not collide on a key, because ensure would
    /// then answer REUSED and hand the second member the first one's bridge.
    /// The team name is there for whoever reads `tm-agent gc` output on the
    /// peer, and is trimmed to fit the protocol's 256-byte key limit.
    static func peerAgentEnsureKey(teamName: String, agentInstanceId: String) -> String {
        let prefix = "termmesh/team/"
        let suffix = "/agent/\(agentInstanceId)"
        let budget = 256 - prefix.utf8.count - suffix.utf8.count
        guard budget > 0 else { return "termmesh/agent/\(agentInstanceId)" }
        var team = teamName.replacingOccurrences(of: "\u{0}", with: "")
        while team.utf8.count > budget { team.removeLast() }
        return prefix + team + suffix
    }

    /// The argument vector the peer daemon spawns `tm-agent-bridge` with.
    ///
    /// `--cli` is not optional and not merely descriptive: the daemon reads
    /// `SurfaceInfo.agent_cli` back out of this vector (there is no wire field
    /// for it), and that label is what picks the renderer on reattach. It also
    /// joins the spec hash, so changing it under the same key is a
    /// SPEC_CONFLICT rather than a silent relabel.
    ///
    /// `--exe` matters just as much and for a duller reason: `term-meshd`
    /// runs under systemd's default PATH, which does not contain
    /// `$HOME/.local/bin` — so a bare `codex` would simply not be found.
    /// Omitted only when the probe could not resolve a path, where the
    /// bridge's own default (`peerAgentExecutableName`'s binary, by name) is
    /// still a better guess than failing outright.
    ///
    /// `remoteCLIPath` is the path of the binary the BRIDGE spawns, which for
    /// kiro is `kiro-cli` and not the `kiro` the role is named after. Passing
    /// the role's own path here would override the bridge's correct default
    /// with a wrapper that cannot speak ACP.
    static func peerAgentBridgeArgs(
        cli: String,
        workingDirectory: String,
        model: String,
        remoteCLIPath: String
    ) -> [String] {
        var args = ["--cli", cli, "--cwd", workingDirectory]
        let modelArg = Self.bridgeModelArg(cli: cli, model: model)
        if !modelArg.isEmpty { args += ["--model", modelArg] }
        if !remoteCLIPath.isEmpty { args += ["--exe", remoteCLIPath] }
        return args
    }

    /// The full ensure recipe for a peer-owned agent surface.
    ///
    /// `restartPolicy` is `.never` on purpose. The survivability this whole
    /// path exists for is "the Mac went away", and the daemon keeps the child
    /// running through that on its own. A daemon *restart* is different: the
    /// bridge would come back with an empty conversation behind a pane whose
    /// transcript says otherwise, which is worse than a pane that visibly
    /// ended.
    static func peerAgentSurfaceSpec(
        teamName: String,
        agentInstanceId: String,
        surfaceInstanceId: String? = nil,
        cli: String,
        workingDirectory: String,
        model: String,
        binaries: RemoteAgentBinaries
    ) -> PeerRunnerSurfaceSpec {
        if cli == "claude" {
            let launch = AgentSession.claudeLaunch(
                claudePath: binaries.cliPath.isEmpty ? "claude" : binaries.cliPath,
                model: model,
                instructions: "",
                extraArgs: [],
                workingDirectory: workingDirectory
            )
            // The daemon extracts `--cli claude` from the ensure argv to label
            // later attaches. Keep that metadata in the shell's positional
            // arguments; the exec command itself forwards only Claude's real
            // stream-json flags.
            let command = ([launch.executable] + launch.arguments)
                .map(Self.shellQuoted)
                .joined(separator: " ")
            return PeerRunnerSurfaceSpec(
                key: peerAgentEnsureKey(
                    teamName: teamName,
                    agentInstanceId: surfaceInstanceId ?? agentInstanceId
                ),
                cwd: workingDirectory,
                executable: "/bin/sh",
                args: ["-c", "exec \(command)", "--cli", "claude"],
                restartPolicy: .never,
                kind: SessionHostPanes.agentSurfaceType
            )
        }
        return PeerRunnerSurfaceSpec(
            key: peerAgentEnsureKey(
                teamName: teamName,
                agentInstanceId: surfaceInstanceId ?? agentInstanceId
            ),
            cwd: workingDirectory,
            executable: binaries.bridgePath,
            args: peerAgentBridgeArgs(
                cli: cli,
                workingDirectory: workingDirectory,
                model: model,
                remoteCLIPath: binaries.execPath
            ),
            restartPolicy: .never,
            kind: SessionHostPanes.agentSurfaceType
        )
    }

    /// Stop an ensured agent surface on the peer.
    ///
    /// `requestClosePane` is the wrong verb here and fails silently: an agent
    /// surface is deliberately never placed in the workspace tree, so a close
    /// by pane id finds nothing and reports success while the bridge keeps
    /// running. TerminateSurface addresses the registry directly.
    ///
    /// Best effort by design — every caller is already unwinding a failure,
    /// and a host that cannot be reached to clean up is not a second error to
    /// report on top of the first.
    static func terminatePeerAgentSurface(
        hostSockPath: String,
        surfaceID: Data
    ) async {
        _ = await terminatePeerAgentSurfaceConfirmed(
            hostSockPath: hostSockPath,
            surfaceID: surfaceID
        )
    }

    /// Terminate an agent surface on the endpoint that actually created it.
    ///
    /// `liveTeamSockPath` is not usable here, and that difference is the whole
    /// reason this exists. It only *finds* a tunnel, and the case this serves is
    /// precisely the one with no tunnel left to find: the ensure succeeded, the
    /// local attach failed, the pane that would have held the lease was never
    /// opened. Left to a lookup, the tombstone would wait for a lease nothing
    /// is going to take, while the bridge it names keeps running.
    ///
    /// So this leases the session owner itself, and releases it as soon as the
    /// answer is in. On a host that is not redirected the serving socket is the
    /// owning socket, and the old direct path is kept — no tunnel is started to
    /// reach a socket already open.
    /// Where a tombstone's `TerminateSurface` has to be sent.
    ///
    /// Split out from the send so the choice can be tested without a socket —
    /// it is the whole defect, and the surrounding code is transport.
    enum PeerAgentCleanupEndpoint {
        /// The socket that served the handshake already owns the surface.
        case serving(String)
        /// The surface was ensured on this host's session owner; a tunnel to it
        /// has to be leased before anything can be addressed there.
        case sessionOwner(PeerPaneHostSpec)
        /// The host is reachable but has not yet said where its sessions live.
        /// Keep the tombstone and retry; guessing costs a `TerminateSurface`
        /// sent to an endpoint that never created the surface, which the host
        /// answers as "not mine" — indistinguishable from a real confirmation
        /// unless the caller happens to check, and the bridge keeps running.
        case unresolved

        /// What the endpoint resolves to on the wire, for assertions and logs.
        /// A serving endpoint is already a local path; a session owner is a
        /// remote path that only becomes dialable once leased.
        var describedTarget: String {
            switch self {
            case .serving(let sockPath): return sockPath
            case .sessionOwner(let spec): return spec.hostKey.remoteSockPath ?? ""
            case .unresolved: return ""
            }
        }

        var leasesSessionOwner: Bool {
            if case .sessionOwner = self { return true }
            return false
        }

        var isUnresolved: Bool {
            if case .unresolved = self { return true }
            return false
        }
    }

    /// Where a recorded surface's `TerminateSurface` has to be sent.
    ///
    /// `owningRemoteSockPath` is the endpoint that created the surface, and it
    /// wins over the host's current route whenever the two disagree. The
    /// host's route answers "where does team work go now", which is a different
    /// question and the wrong one here: a handshake that moves the route does
    /// not move existing surfaces, and the new owner replies `notFound` for a
    /// surface it never created — a reply this code cannot tell from a real
    /// confirmation, so the tombstone would be dropped with the bridge still
    /// running on the endpoint that has it.
    ///
    /// A record without a recorded endpoint (persisted by an earlier build, or
    /// created on a host that never redirected) falls back to resolving by
    /// host, which is what it has.
    static func peerAgentCleanupEndpoint(
        host: HostEntry?,
        servingSockPath: String,
        owningRemoteSockPath: String? = nil
    ) -> PeerAgentCleanupEndpoint {
        if let owningRemoteSockPath, !owningRemoteSockPath.isEmpty {
            // Rebuilt from the host so the tunnel keeps the profile's auth
            // parameters; only the remote socket is pinned to the recorded one.
            // Without a live host row there is no target to dial, and unlike
            // the unknown-host case below there is a specific endpoint that is
            // known to be the right one — so this waits for the row rather
            // than sending the request somewhere it does not belong.
            guard let host else { return .unresolved }
            guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
                // A direct host reaches its own socket path directly.
                return .sessionOwner(.direct(sockPath: owningRemoteSockPath))
            }
            return .sessionOwner(.ssh(
                target: sshTarget,
                remoteSockPath: owningRemoteSockPath,
                port: host.sshPort,
                identityFile: host.identityFile
            ))
        }
        // An unknown host is not an unresolved one: nothing is coming that
        // would answer, so the socket that served this tombstone is the only
        // address there will ever be. Attempt it.
        guard let host else { return .serving(servingSockPath) }
        guard host.teamRouteResolved else { return .unresolved }
        guard host.redirectsTeamWorkToSessionHost else {
            return .serving(servingSockPath)
        }
        guard let teamSpec = host.teamHostSpec else { return .unresolved }
        return .sessionOwner(teamSpec)
    }

    static func terminatePeerAgentSurfaceOnOwningEndpoint(
        hostKey: String,
        servingSockPath: String,
        surfaceID: Data,
        owningRemoteSockPath: String? = nil
    ) async -> Bool {
        switch peerAgentCleanupEndpoint(
            host: RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
            servingSockPath: servingSockPath,
            owningRemoteSockPath: owningRemoteSockPath
        ) {
        case .serving(let sockPath):
            return await terminatePeerAgentSurfaceConfirmed(
                hostSockPath: sockPath, surfaceID: surfaceID
            )
        case .sessionOwner(let spec):
            guard let lease = try? await PeerPaneHostRegistry.shared.acquire(spec)
            else { return false }
            defer { PeerPaneHostRegistry.shared.release(lease) }
            return await terminatePeerAgentSurfaceConfirmed(
                hostSockPath: lease.hostSockPath, surfaceID: surfaceID
            )
        case .unresolved:
            // Not a failure to report — the handshake that answers this is
            // already in flight, and the tombstone is durable precisely so it
            // can wait for it.
            return false
        }
    }

    /// Returns true only when the host authoritatively says the surface is gone.
    /// A dropped response is deliberately false: the request may have applied,
    /// and a retry then receives the idempotent `.notFound` confirmation.
    static func terminatePeerAgentSurfaceConfirmed(
        hostSockPath: String,
        surfaceID: Data
    ) async -> Bool {
        guard !hostSockPath.isEmpty, !surfaceID.isEmpty,
              let connection = try? await PeerRelaySession.connect(hostSockPath: hostSockPath)
        else { return false }
        do {
            let result = try await connection.session.terminateSurface(surfaceID: surfaceID)
            await connection.cancel()
            return result == .terminated || result == .notFound
        } catch {
            await connection.cancel()
            RemoteWorkLog.infoOffMain(
                "Could not confirm peer agent termination: \(String(describing: error))"
            )
            return false
        }
    }

    /// Stop the peer bridge behind one roster member, if that is what it has.
    ///
    /// The roster is the last place that knows a peer-owned agent's surface
    /// id: it is in no workspace tree (so no Peer Shells sweep sees it) and in
    /// no `ManagedPeerSurfaceStore` (so no reclaim UI lists it). Every path
    /// that drops the member — detach, project delete, team destroy — has to
    /// spend that id on the way out or the bridge runs on the peer forever.
    static func releasePeerOwnedAgentSurface(_ agent: AgentMember) {
        releasePeerOwnedAgentSurface(agent, cleanup: .shared)
    }

    static func releasePeerOwnedAgentSurface(
        _ agent: AgentMember,
        cleanup: PendingPeerAgentSurfaceCleanupStore
    ) {
        guard agent.remoteAgentSurface, agent.remoteSurfaceSpawned,
              let surfaceID = agent.remoteSurfaceID, !surfaceID.isEmpty,
              let hostKey = agent.hostKey, !hostKey.isEmpty
        else { return }
        cleanup.enqueue(
            hostKey: hostKey,
            surfaceID: surfaceID,
            // What the member recorded at ensure time, and only then the host's
            // current route: a member that never recorded one predates this
            // field or ran on a host that owns its own sessions.
            owningRemoteSockPath: agent.remoteSurfaceOwnerRemoteSockPath
                ?? currentTeamOwnerRemoteSockPath(forHostKey: hostKey)
        )
        cleanup.scheduleRetry()
    }

    /// The remote socket team surfaces are being created on for this host right
    /// now, or nil when that is the serving socket (or is not yet known).
    ///
    /// Read at the moment a tombstone is written, so the record keeps the
    /// endpoint that has the surface rather than whichever one a later
    /// handshake points at.
    static func currentTeamOwnerRemoteSockPath(forHostKey hostKey: String) -> String? {
        guard let host = RemoteHostStore.shared.sortedHosts
            .first(where: { $0.id == hostKey }),
              host.redirectsTeamWorkToSessionHost,
              let remote = host.teamHostSpec?.hostKey.remoteSockPath,
              !remote.isEmpty
        else { return nil }
        return remote
    }

    /// Record cleanup before dropping the only local handle to a peer-owned
    /// surface. This is also used between ensure and roster adoption, where no
    /// `AgentMember` exists yet for the normal detach cleanup path to inspect.
    static func enqueuePendingPeerAgentSurfaceCleanup(
        hostKey: String,
        surfaceID: Data,
        owningRemoteSockPath: String? = nil
    ) {
        enqueuePendingPeerAgentSurfaceCleanup(
            hostKey: hostKey,
            surfaceID: surfaceID,
            owningRemoteSockPath: owningRemoteSockPath,
            cleanup: .shared
        )
    }

    static func enqueuePendingPeerAgentSurfaceCleanup(
        hostKey: String,
        surfaceID: Data,
        owningRemoteSockPath: String? = nil,
        cleanup: PendingPeerAgentSurfaceCleanupStore
    ) {
        cleanup.enqueue(
            hostKey: hostKey,
            surfaceID: surfaceID,
            owningRemoteSockPath: owningRemoteSockPath
                ?? currentTeamOwnerRemoteSockPath(forHostKey: hostKey)
        )
        cleanup.scheduleRetry()
    }

    /// The team's half of a peer-owned agent pane: which member it is, whether
    /// it is busy, and where a finished turn's report goes.
    ///
    /// Split out because a peer-owned agent pane is created three times over
    /// its life, not once — at attach, when a rewound stream forces a fresh
    /// pane (`Workspace.dropRemoteAgentPane` → `recoverPeerOwnedAgentPane`),
    /// and when a detached project is restored. The bridge on the peer is the
    /// same process throughout; only the local view is rebuilt. Miss this
    /// wiring on any of those and the member goes quiet in the way that is
    /// hardest to see: the pane renders, turns run, and no reply is ever filed.
    ///
    /// What it deliberately does NOT touch is the data path.
    /// `openRemoteAgentPane` installs that (startRemote's sink, `onPtyData`,
    /// the lifecycle hooks); a second `startRemote` would replace a live sink
    /// mid-turn.
    @MainActor
    static func bindPeerOwnedAgentPanel(
        panel: AgentPanel,
        workspace: Workspace,
        teamName: String,
        agentName: String,
        agentInstanceId: String,
        color: String,
        hostDisplayName: String
    ) {
        panel.runtimeOwnership = .peerOwned(hostName: hostDisplayName)
        let previousClose = panel.onClose
        panel.onClose = { [weak panel] in
            if let id = panel?.id {
                AgentEnvironmentComparisonStore.removeNative(teamName: teamName, id: id)
            }
            previousClose?()
        }
        panel.session.onEnvironmentSummary = { [weak panel] environment in
            RemoteWorkLog.info(
                "Native environment: \(agentName) [\(panel?.cli ?? "agent")] — "
                    + environment.liveActivityText
            )
            AgentEnvironmentComparisonStore.recordNative(
                environment,
                teamName: teamName,
                id: panel?.id ?? UUID()
            ) { [weak panel] mismatch in
                panel?.session.setEnvironmentMismatch(mismatch)
                if let mismatch {
                    RemoteWorkLog.warning("\(mismatch) — team=\(teamName), agent=\(agentName)")
                }
            }
        }
        if let environment = panel.session.environmentSummary {
            panel.session.onEnvironmentSummary?(environment)
        }
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "\(Self.colorEmoji(color)) \(agentName) @\(hostDisplayName)"
        )
        panel.session.onBusyChanged = { [teamName, agentName, agentInstanceId] busy in
            TeamDataStore.shared.setAgentBusy(
                teamName: teamName, agentName: agentName,
                agentInstanceId: agentInstanceId, busy: busy
            )
        }
        panel.session.onTurnEnd = { [teamName, agentName, agentInstanceId] final, _, taskId in
            Self.fileReport(
                teamName: teamName, agentName: agentName,
                agentInstanceId: agentInstanceId,
                taskId: taskId, text: final
            )
            guard let taskId else { return }
            AutoReplyEmit.emit(
                teamName: teamName,
                agentName: agentName,
                event: AgentPipeCompletion.headerEvent(from: final),
                preferredTaskId: taskId,
                agentInstanceId: agentInstanceId
            )
        }
    }

    /// Rebuild the local pane for a peer-owned agent whose previous one was
    /// dropped, and point the roster at it.
    ///
    /// `Workspace.dropRemoteAgentPane` closes a peer agent pane whenever the
    /// stream rewinds past what this side already consumed (a *healthy*
    /// resume: `AgentSession.consume` is not idempotent, so a replayed stream
    /// needs a fresh `AgentSession`, and `AgentPanel.session` is fixed for the
    /// panel's life) or the relay dies for good. It then hands recovery to
    /// `SessionHostPanes.reconcile()`, which is correct for the surfaces that
    /// path was built for and useless here: that poller lists **this Mac's own
    /// daemon** (`TermMeshDaemon.shared.daemonPeerSocketPath`), and a surface
    /// held by jw-server is never in that list. Until this existed, a single
    /// rewind retired a team member permanently — the pane never came back,
    /// `AgentMember.panelId` pointed at a closed panel so `delegate`/`send`
    /// could not reach it, and the peer's bridge kept running with nothing
    /// naming it.
    ///
    /// The peer's daemon still holds the surface, so this is a reattach, not a
    /// respawn: same surface id, same bridge, same conversation, replayed from
    /// the daemon's ring. Failure is not fatal and not silent — the member
    /// keeps its surface id so a later attempt (or a detach) can still address
    /// the bridge.
    enum PeerAgentPaneRecoveryResult: Equatable {
        case recovered
        case authoritativeMissing
        case transientFailure
    }

    static func peerAgentRecoveryDelay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(8, pow(2, Double(attempt - 1)))
    }

    static func retryPeerAgentPaneRecovery(
        maxAttempts: Int = 6,
        sleep: (TimeInterval) async -> Void = { delay in
            guard delay > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        },
        attempt: () async -> PeerAgentPaneRecoveryResult
    ) async -> PeerAgentPaneRecoveryResult {
        guard maxAttempts > 0 else { return .transientFailure }
        for index in 0..<maxAttempts {
            let result = await attempt()
            guard result == .transientFailure else { return result }
            if index + 1 < maxAttempts {
                await sleep(peerAgentRecoveryDelay(attempt: index + 1))
            }
        }
        return .transientFailure
    }

    @discardableResult
    func recoverPeerOwnedAgentPane(closedPanelID: UUID, surfaceID: Data) async -> Bool {
        guard let (teamName, agent) = peerOwnedAgentMember(
            panelID: closedPanelID, surfaceID: surfaceID
        ) else { return false }
        let request = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: teamName,
            agentInstanceID: agent.agentInstanceId,
            closedPanelID: closedPanelID,
            surfaceID: surfaceID
        )
        PeerAgentPaneRecoveryCoordinator.shared.remember(request)
        let result = await retryPeerOwnedAgentPaneRecovery(request)
        return result == .recovered
    }

    func retryPendingPeerAgentPaneRecoveries() async {
        for request in PeerAgentPaneRecoveryCoordinator.shared.pending {
            _ = await retryPeerOwnedAgentPaneRecovery(request)
        }
    }

    private func retryPeerOwnedAgentPaneRecovery(
        _ request: PeerAgentPaneRecoveryCoordinator.Request
    ) async -> PeerAgentPaneRecoveryResult {
        // Same shape as `agentOperationKey`, which is file-private to
        // TeamOrchestrator.swift: team plus durable instance id, so two
        // members named `executor` do not share one recovery slot.
        let recoveryKey = request.key
        guard !peerAgentRecoveryInFlight.contains(recoveryKey) else {
            return .transientFailure
        }
        peerAgentRecoveryInFlight.insert(recoveryKey)
        defer { peerAgentRecoveryInFlight.remove(recoveryKey) }

        let result = await Self.retryPeerAgentPaneRecovery { [weak self] in
            guard let self else { return .transientFailure }
            return await self.attemptPeerOwnedAgentPaneRecovery(request)
        }
        if result != .transientFailure {
            PeerAgentPaneRecoveryCoordinator.shared.forget(request)
        } else {
            PeerAgentPaneRecoveryCoordinator.shared.scheduleRetryIfNeeded()
        }
        return result
    }

    private func attemptPeerOwnedAgentPaneRecovery(
        _ request: PeerAgentPaneRecoveryCoordinator.Request
    ) async -> PeerAgentPaneRecoveryResult {
        guard let team = teams[request.teamName],
              let agent = team.agents.first(where: {
                  $0.agentInstanceId == request.agentInstanceID
                      && $0.panelId == request.closedPanelID
                      && $0.remoteSurfaceID == request.surfaceID
              })
        else {
            // Detach/destroy retired the owner while a retry was sleeping.
            return .authoritativeMissing
        }

        guard let hostKey = agent.hostKey,
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              host.isLaunchable
        else {
            RemoteWorkLog.info(
                "\(agent.name)'s host is disconnected; its pane will come back "
                    + "when the host does"
            )
            return .transientFailure
        }
        guard let workspace = AppDelegate.shared?.tabManager?.tabs
            .first(where: { $0.id == agent.workspaceId })
            ?? resolveTabManager(teamName: request.teamName)?.tabs
            .first(where: { $0.id == agent.workspaceId })
        else { return .transientFailure }

        let lease: PeerPaneHostLease
        do {
            lease = try await PeerPaneHostRegistry.shared.acquire(Self.requireTeamHostSpec(host))
        } catch {
            RemoteWorkLog.info("Cannot reattach \(agent.name) on \(host.displayName): \(error)")
            return .transientFailure
        }
        let session: PeerPaneSession
        do {
            let surfaces = try await PeerPaneSession.listSurfaces(on: lease)
            // Absent means the peer no longer holds the bridge — it exited, or
            // its daemon restarted with `restartPolicy: .never`. There is
            // nothing to reattach to and nothing left to terminate; say so
            // rather than retrying a surface that does not exist.
            guard let surface = surfaces.first(where: { $0.surfaceID == request.surfaceID }) else {
                PeerPaneHostRegistry.shared.release(lease)
                RemoteWorkLog.info(
                    "\(agent.name) on \(host.displayName) has ended: its host no longer "
                        + "holds that agent surface. Detach and attach it again to restart it."
                )
                return .authoritativeMissing
            }
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: surface,
                title: agent.name,
                spec: Self.requireTeamHostSpec(host)
            )
        } catch {
            PeerPaneHostRegistry.shared.release(lease)
            RemoteWorkLog.info("Cannot reattach \(agent.name) on \(host.displayName): \(error)")
            return .transientFailure
        }
        PeerPaneHostRegistry.shared.release(lease)

        // `listSurfaces` and `attach` both suspend. Detach/team destruction may
        // have retired this owner while the remote session was being opened;
        // never resurrect a pane after that authoritative local decision.
        guard validatePeerAgentRecoveryOwnership(
            teamName: request.teamName,
            agentInstanceID: request.agentInstanceID,
            surfaceID: request.surfaceID,
            panelID: request.closedPanelID,
            onMismatch: { session.teardown() }
        ) else { return .authoritativeMissing }

        guard let panel = workspace.openRemoteAgentPane(session: session, focus: false) else {
            session.teardown()
            RemoteWorkLog.info("Cannot reattach \(agent.name): no local pane can host it")
            return .transientFailure
        }
        Self.bindPeerOwnedAgentPanel(
            panel: panel,
            workspace: workspace,
            teamName: request.teamName,
            agentName: agent.name,
            agentInstanceId: agent.agentInstanceId,
            color: agent.color,
            hostDisplayName: host.displayName
        )
        replaceRemoteAgentPresentation(
            teamName: request.teamName,
            agentInstanceID: agent.agentInstanceId,
            workspaceID: workspace.id,
            panelID: panel.id
        )
        scheduleAgentGridEqualization(workspace: workspace)
#if DEBUG
        dlog(
            "peer.agentPane.recover team=\(request.teamName) agent=\(agent.name) "
                + "panel=\(panel.id.uuidString.prefix(8))"
        )
#endif
        return .recovered
    }

    func ownsPeerAgentSurface(
        teamName: String,
        agentInstanceID: String,
        surfaceID: Data,
        panelID: UUID? = nil
    ) -> Bool {
        teams[teamName]?.agents.contains(where: {
            $0.agentInstanceId == agentInstanceID
                && $0.remoteAgentSurface
                && $0.remoteSurfaceID == surfaceID
                && (panelID == nil || $0.panelId == panelID)
        }) == true
    }

    @discardableResult
    func validatePeerAgentRecoveryOwnership(
        teamName: String,
        agentInstanceID: String,
        surfaceID: Data,
        panelID: UUID? = nil,
        onMismatch: () -> Void
    ) -> Bool {
        guard ownsPeerAgentSurface(
            teamName: teamName,
            agentInstanceID: agentInstanceID,
            surfaceID: surfaceID,
            panelID: panelID
        ) else {
            onMismatch()
            return false
        }
        return true
    }

    /// The roster member a dropped peer-owned agent pane belonged to.
    ///
    /// Matched on the surface id first and the panel id only as a tiebreak:
    /// the panel is minted per attach and is exactly the thing that just went
    /// away, while the surface id is the peer's own durable name for the
    /// bridge.
    func peerOwnedAgentMember(
        panelID: UUID,
        surfaceID: Data
    ) -> (teamName: String, agent: AgentMember)? {
        for (teamName, team) in teams {
            for agent in team.agents where agent.remoteAgentSurface {
                if !surfaceID.isEmpty {
                    // A viewer replacement reuses the durable peer surface but
                    // mints a new local panel. A delayed callback from the old
                    // pane must not recover or retire the new presentation.
                    if agent.remoteSurfaceID == surfaceID, agent.panelId == panelID {
                        return (teamName, agent)
                    }
                    continue
                }
                if agent.panelId == panelID { return (teamName, agent) }
            }
        }
        return nil
    }

    /// Attach an agent whose process the PEER owns, rendered here as a native
    /// `AgentPanel`.
    ///
    /// The third factory, and the only one that gets both halves: the bridge
    /// is a child of the peer's `term-meshd` (so quitting this app leaves it
    /// running and another machine can pick it up), and its stdout is NDJSON
    /// delivered straight into `AgentSession` (so the pane draws turns rather
    /// than a wire dump).
    ///
    /// The ensure request carries the validated remote-native environment:
    /// active CLI profile first, explicit peer-host values overriding it, and
    /// term-mesh identity last so configured values cannot impersonate another
    /// team/member. This factory is therefore available only when the host
    /// advertises agent, authoritative-exit, and ensure-environment support.
    /// The standing brief remains required for role instructions; the reply
    /// path does not depend on it — `onTurnEnd` files the report from this side,
    /// exactly as the local native path does.
    ///
    /// Callers must treat a thrown `RelayError` as "take the terminal path",
    /// not as a failed attach. `canUsePeerOwnedAgent` reads the capability off
    /// a connection that is then closed, so a host can stop advertising it
    /// between that check and this ensure; the ensure refuses locally with
    /// `RelayError.capabilityUnavailable` and nothing is created there. A
    /// `RemoteAgentError` is the opposite — a decision this side made, which
    /// the terminal path would reach identically.
    ///
    /// `stillWanted` is the team-deletion gate, and it matters more here than
    /// on any other path: what this creates is a process on another machine
    /// that no longer dies with anything local, so committing it to a roster
    /// that was already retired strands a bridge on the peer for good.
    @MainActor
    static func configuredRemoteAgentEnvironment(
        profile: [String: String],
        explicitHost: [String: String]
    ) -> [String: String] {
        profile.merging(explicitHost) { _, hostValue in hostValue }
    }

    @MainActor
    static func peerOwnedAgentEnvironment(
        profile: [String: String],
        explicitHost: [String: String],
        internalIdentity: [String: String]
    ) throws -> [String: String] {
        let merged = configuredRemoteAgentEnvironment(
            profile: profile,
            explicitHost: explicitHost
        )
            .merging(internalIdentity) { _, internalValue in internalValue }
        try PeerEnsureEnvironment.validate(merged)
        return Dictionary(
            uniqueKeysWithValues: try PeerEnsureEnvironment.validatedPairs(merged)
        )
    }

    /// The complete environment a remote native agent launches with, for
    /// either ownership model.
    ///
    /// Both models want the same three layers in the same order, and both used
    /// to assemble them at their own call site. They drifted: the SSH-owned
    /// site omitted the profile layer entirely, so a pane launched with the
    /// host's stored keys but without the active CLI profile's — the layer
    /// carrying the gateway base URL, auth token, and model-discovery flag.
    /// The result authenticated against the wrong endpoint and failed far from
    /// the code that caused it.
    ///
    /// Deciding the layers once is what prevents that. The lookups are
    /// parameters so the composition can be tested without reaching into
    /// `UserDefaults` or the host profile store.
    ///
    /// They are optionals rather than defaulted closures because a default
    /// argument is evaluated in a nonisolated context and both real lookups
    /// are main-actor bound; resolving them in the body keeps the call sites
    /// down to the three arguments that vary.
    @MainActor
    static func remoteNativeAgentLaunchEnvironment(
        cli: String,
        hostKey: String,
        internalIdentity: [String: String],
        profileLookup: ((String) -> [String: String])? = nil,
        hostLookup: ((String) -> [String: String])? = nil
    ) throws -> [String: String] {
        let profile = profileLookup?(cli)
            ?? CLIPathSettings.activeProfile(for: cli)?.env
            ?? [:]
        let explicitHost = hostLookup?(hostKey)
            ?? PeerHostEnvironment.stored(forHostKey: hostKey)
        return try peerOwnedAgentEnvironment(
            profile: profile,
            explicitHost: explicitHost,
            internalIdentity: internalIdentity
        )
    }

    private func attachPeerOwnedAgent(
        team: Team,
        workspace: Workspace,
        host: HostEntry,
        binaries: RemoteAgentBinaries,
        splitFrom: UUID,
        orientation: SplitOrientation,
        agentName: String,
        agentInstanceId: String,
        workingDirectory: String,
        agentType: String,
        model: String,
        cli: String,
        routeGrant: Termmesh_Peer_V1_TeamLeaderGrant,
        routeFilePath: String?,
        stillWanted: () -> Bool
    ) async throws -> AgentMember {
        let color = Self.agentColor(
            forRole: agentType,
            taken: Set(team.agents.map(\.color))
        )
        let instructions = AgentRunbookService.shared.composeInstructions(
            roleName: agentType,
            presetInstructions: "",
            customInstructions: nil,
            workingDirectory: workingDirectory,
            mode: .digest
        )
        let spec = Self.peerAgentSurfaceSpec(
            teamName: team.id,
            agentInstanceId: agentInstanceId,
            cli: cli,
            workingDirectory: workingDirectory,
            model: model,
            binaries: binaries
        )
        // Match the documented remote-native launch contract: active CLI
        // profile at the bottom, explicit peer-host values above it, and
        // term-mesh's identity last so configuration cannot impersonate
        // another team/member.
        let environment = try Self.remoteNativeAgentLaunchEnvironment(
            cli: cli,
            hostKey: host.id,
            internalIdentity: Self.remoteNativeAgentEnvironment(
                teamName: team.id,
                agentName: agentName,
                agentType: agentType,
                agentCli: cli,
                workspaceId: workspace.id,
                // Peer-owned surfaces receive the authoritative daemon
                // control socket as protected identity environment.
                socketPath: nil,
                routeGrant: routeGrant,
                routeFilePath: routeFilePath
            )
        )

        let registry = PeerPaneHostRegistry.shared
        let lease = try await registry.acquire(Self.requireTeamHostSpec(host))
        let ensured: (session: PeerPaneSession, outcome: PeerEnsureSurfaceOutcome)
        do {
            ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: spec,
                attachment: PeerRunnerAttachment(title: agentName, lifetime: .keepAlive),
                hostSpec: Self.requireTeamHostSpec(host),
                agentCli: cli,
                environment: environment,
                onAgentPostEnsureFailure: { surfaceID in
                    Self.enqueuePendingPeerAgentSurfaceCleanup(
                        hostKey: host.id,
                        surfaceID: surfaceID,
                        owningRemoteSockPath: lease.key.remoteSockPath
                    )
                }
            )
            registry.release(lease)
        } catch {
            registry.release(lease)
            throw error
        }
        let session = ensured.session
        let surfaceID = ensured.outcome.surfaceID

        // From here on the surface exists on the peer. Every exit has to take
        // it back down, or a failed attach leaves a bridge running there with
        // nothing on this side pointing at it.
        func abandonSurface() {
            session.teardown()
            Self.enqueuePendingPeerAgentSurfaceCleanup(
                hostKey: host.id,
                surfaceID: surfaceID,
                // The endpoint this surface was just ensured on, not whichever
                // one the host points at when the tombstone is finally spent.
                owningRemoteSockPath: lease.key.remoteSockPath
            )
        }

        // The ensure is the point of no return on the peer, so re-ask before
        // building anything on top of it. A deletion that began while this was
        // ensuring has already decided the roster.
        guard stillWanted() else {
            abandonSurface()
            throw RemoteAgentError.teamNotFound(team.id)
        }

        guard let panel = workspace.openRemoteAgentPane(
            session: session,
            orientation: orientation,
            focus: false,
            from: splitFrom
        ) else {
            abandonSurface()
            throw RemoteAgentError.paneCreationFailed
        }
        Self.bindPeerOwnedAgentPanel(
            panel: panel,
            workspace: workspace,
            teamName: team.id,
            agentName: agentName,
            agentInstanceId: agentInstanceId,
            color: color,
            hostDisplayName: host.displayName
        )
        // A bridged CLI has no `--append-system-prompt` equivalent, so the
        // runbook arrives as the first turn — the same contract the local
        // bridged path uses.
        if !instructions.isEmpty {
            let briefing = Self.withoutTerminalProtocol(instructions)
                + "\n\nThis is your standing brief, not a task. "
                + "Do no work now: reply with exactly "
                + "\"Agent \(agentName) ready.\" and wait."
            try? panel.session.send(briefing, from: .leader)
        }

        let member = AgentMember(
            id: "\(agentName)@\(team.id)",
            agentInstanceId: agentInstanceId,
            name: agentName,
            teamName: team.id,
            cli: cli,
            launchCommand: cli,
            model: model,
            agentType: agentType,
            color: color,
            instructions: instructions,
            workspaceId: workspace.id,
            panelId: panel.id,
            createdAt: Date(),
            remoteSurfaceID: surfaceID,
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            // The endpoint this surface was just ensured on. Read from the lease
            // rather than the store so it cannot drift from where the ensure
            // actually went.
            remoteSurfaceOwnerRemoteSockPath: lease.key.remoteSockPath,
            hostKey: host.id,
            originalAgentWorkDir: workingDirectory
        )
        // Last gate before the member becomes part of the team, for the same
        // reason the terminal path has one: adding to a roster a deletion has
        // already finished with is what orphans the peer's bridge.
        guard stillWanted() else {
            _ = workspace.closePanel(panel.id, force: true)
            abandonSurface()
            throw RemoteAgentError.teamNotFound(team.id)
        }
        guard adoptAgentMember(member, teamName: team.id) else {
            _ = workspace.closePanel(panel.id, force: true)
            abandonSurface()
            throw RemoteAgentError.duplicateInstance(member.agentInstanceId)
        }
        scheduleAgentGridEqualization(workspace: workspace)
        RemoteProjectPaths.shared.remember(
            host: host.id,
            localRoot: team.workingDirectory,
            path: workingDirectory
        )
        return member
    }

    struct PeerOwnedAgentRestart {
        let panelID: UUID
        let member: AgentMember
        let routeGrantID: Data
        let routeHost: HostEntry
        let routeTransaction: String
        let teamName: String
        let agentInstanceID: String
    }

    /// Replace exactly the peer-owned member that a hard restart observed.
    /// The caller may have crossed several network awaits, so every unrelated
    /// roster mutation must come from `current`, never from its old snapshot.
    @MainActor
    static func teamByReplacingPeerOwnedAgent(
        current: Team,
        expected: AgentMember,
        replacement: AgentMember
    ) -> Team? {
        guard let index = current.agents.firstIndex(where: {
            $0.agentInstanceId == expected.agentInstanceId
                && $0.panelId == expected.panelId
                && $0.remoteSurfaceID == expected.remoteSurfaceID
        }) else { return nil }
        var updated = current
        updated.agents[index] = replacement
        return updated
    }

    /// Remove exactly the peer-owned member whose authoritative surface ended.
    /// A stale exit callback from an older pane must not remove a replacement
    /// that kept the same durable instance id but already owns a new surface.
    @MainActor
    static func teamByRetiringEndedPeerOwnedAgent(
        current: Team,
        agentInstanceID: String,
        surfaceID: Data
    ) -> (team: Team, retired: AgentMember)? {
        guard let index = current.agents.firstIndex(where: {
            $0.agentInstanceId == agentInstanceID
                && $0.remoteAgentSurface
                && $0.remoteSurfaceID == surfaceID
        }) else { return nil }
        var updated = current
        let retired = updated.agents.remove(at: index)
        return (updated, retired)
    }

    @MainActor
    func discardPeerOwnedAgentRestart(
        _ replacement: PeerOwnedAgentRestart,
        workspace: Workspace
    ) {
        workspace.discardPanelForRollback(replacement.panelID)
        Self.releasePeerOwnedAgentSurface(replacement.member)
        Task {
            _ = await Self.finishAdoptedRemoteAgentRoutes(
                host: replacement.routeHost,
                transaction: replacement.routeTransaction,
                commit: false
            )
            await PeerTeamLeaderControlPlane.shared.revokeGrant(
                id: replacement.routeGrantID
            )
        }
    }

    @MainActor
    func activatePeerOwnedAgentRestart(
        _ replacement: PeerOwnedAgentRestart,
        teamName: String,
        agentInstanceID: String
    ) async -> Bool {
        // The live worker route still names the old grant until this finishes.
        // Only then may `startRemoteAgentRouteKeepalive` revoke that old grant.
        guard await Self.commitRemoteAgentRoutesPreservingGrants(
            host: replacement.routeHost,
            transaction: replacement.routeTransaction,
            grantIDs: [replacement.routeGrantID]
        ) else { return false }
        startRemoteAgentRouteKeepalive(
            teamName: teamName,
            agentInstanceID: agentInstanceID,
            grantID: replacement.routeGrantID
        )
        return true
    }

    /// Replace a peer-owned native agent with a fresh bridge/session while
    /// preserving its durable roster identity. The old surface is deliberately
    /// left alive until this returns success, so a probe, ensure, attach, or
    /// pane-allocation failure cannot destroy the user's current conversation.
    @MainActor
    func restartPeerOwnedAgentPaneHard(
        team: Team,
        agent: AgentMember,
        workspace: Workspace,
        splitFrom: (UUID, SplitOrientation, Bool)
    ) async -> Result<PeerOwnedAgentRestart, RestartHardError> {
        guard let hostKey = agent.hostKey,
              let host = RemoteHostStore.shared.sortedHosts.first(where: {
                  $0.id == hostKey
              }),
              host.isLaunchable
        else { return .failure(.peerOwnedAgent) }

        let binaries: RemoteAgentBinaries
        do {
            binaries = try await Self.ensureRemoteCLIAvailable(
                cli: agent.cli, host: host
            )
        } catch {
            return .failure(.spawnFailed)
        }
        guard await Self.canUsePeerOwnedAgent(
            host: host, cli: agent.cli, binaries: binaries
        ) == .available else {
            return .failure(.peerOwnedAgent)
        }

        let routeGrant: Termmesh_Peer_V1_TeamLeaderGrant
        do {
            routeGrant = try await bootstrapRemoteAgentRoute(teamName: team.id)
        } catch {
            return .failure(.spawnFailed)
        }
        var grantOwned = true
        var stagedRouteTransaction: String?
        defer {
            if grantOwned {
                Task {
                    if let transaction = stagedRouteTransaction {
                        _ = await Self.finishAdoptedRemoteAgentRoutes(
                            host: host, transaction: transaction, commit: false
                        )
                    }
                    await PeerTeamLeaderControlPlane.shared.revokeGrant(
                        id: routeGrant.grantID
                    )
                }
            }
        }

        // Restart mints a new grant, so the staged route has to move with it.
        // Skipping this would leave the file naming a bearer that was revoked
        // the moment the old surface went away.
        guard let stagedRoute = await Self.stageRemoteAgentRouteTransaction(
            host: host,
            agentInstanceID: agent.agentInstanceId,
            grant: routeGrant
        ) else {
            return .failure(.spawnFailed)
        }
        stagedRouteTransaction = stagedRoute.transaction
        let routeFilePath = stagedRoute.routeFilePath

        let workingDirectory = agent.originalAgentWorkDir
            ?? agent.worktreePath
            ?? team.workingDirectory
        let spec = Self.peerAgentSurfaceSpec(
            teamName: team.id,
            agentInstanceId: agent.agentInstanceId,
            // EnsureSurface is idempotent by key. Reusing the durable member
            // id here would reattach the old bridge and preserve its context.
            surfaceInstanceId: UUID().uuidString,
            cli: agent.cli,
            workingDirectory: workingDirectory,
            model: agent.model,
            binaries: binaries
        )
        let environment: [String: String]
        do {
            environment = try Self.remoteNativeAgentLaunchEnvironment(
                cli: agent.cli,
                hostKey: host.id,
                internalIdentity: Self.remoteNativeAgentEnvironment(
                    teamName: team.id,
                    agentName: agent.name,
                    agentType: agent.agentType,
                    agentCli: agent.cli,
                    workspaceId: workspace.id,
                    socketPath: nil,
                    routeGrant: routeGrant,
                    routeFilePath: routeFilePath
                )
            )
        } catch {
            return .failure(.spawnFailed)
        }

        let registry = PeerPaneHostRegistry.shared
        let lease: PeerPaneHostLease
        do {
            lease = try await registry.acquire(Self.requireTeamHostSpec(host))
        } catch {
            return .failure(.spawnFailed)
        }
        let ensured: (session: PeerPaneSession, outcome: PeerEnsureSurfaceOutcome)
        do {
            ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: spec,
                attachment: PeerRunnerAttachment(
                    title: agent.name, lifetime: .keepAlive
                ),
                hostSpec: Self.requireTeamHostSpec(host),
                agentCli: agent.cli,
                environment: environment,
                onAgentPostEnsureFailure: { surfaceID in
                    Self.enqueuePendingPeerAgentSurfaceCleanup(
                        hostKey: host.id, surfaceID: surfaceID,
                        owningRemoteSockPath: lease.key.remoteSockPath
                    )
                }
            )
            registry.release(lease)
        } catch {
            registry.release(lease)
            return .failure(.spawnFailed)
        }

        let session = ensured.session
        let surfaceID = ensured.outcome.surfaceID
        func abandonReplacement() {
            session.teardown()
            Self.enqueuePendingPeerAgentSurfaceCleanup(
                hostKey: host.id, surfaceID: surfaceID,
                owningRemoteSockPath: lease.key.remoteSockPath
            )
        }
        guard ownsPeerAgentSurface(
            teamName: team.id,
            agentInstanceID: agent.agentInstanceId,
            surfaceID: agent.remoteSurfaceID ?? Data()
        ) else {
            abandonReplacement()
            return .failure(.agentNotFound)
        }
        guard let panel = workspace.openRemoteAgentPane(
            session: session,
            orientation: splitFrom.1,
            insertFirst: splitFrom.2,
            focus: false,
            from: splitFrom.0
        ) else {
            abandonReplacement()
            return .failure(.spawnFailed)
        }
        Self.bindPeerOwnedAgentPanel(
            panel: panel,
            workspace: workspace,
            teamName: team.id,
            agentName: agent.name,
            agentInstanceId: agent.agentInstanceId,
            color: agent.color,
            hostDisplayName: host.displayName
        )

        if !agent.instructions.isEmpty {
            let briefing = Self.withoutTerminalProtocol(agent.instructions)
                + "\n\nThis is your standing brief, not a task. "
                + "Do no work now: reply with exactly "
                + "\"Agent \(agent.name) ready.\" and wait."
            try? panel.session.send(briefing, from: .leader)
        }

        var replacement = agent
        replacement.panelId = panel.id
        replacement.workspaceId = workspace.id
        replacement.remoteSurfaceID = surfaceID
        replacement.remoteSurfaceSpawned = true
        replacement.remoteAgentSurface = true
        // A restart re-ensures the surface, so the endpoint that owns it is the
        // one this attempt leased — not whatever the previous surface used.
        replacement.remoteSurfaceOwnerRemoteSockPath = lease.key.remoteSockPath
        // Ownership moves to the caller. It starts this grant only after the
        // roster swap and old-pane close both commit; until then the old
        // surface's keepalive must remain valid for rollback.
        grantOwned = false
        return .success(PeerOwnedAgentRestart(
            panelID: panel.id,
            member: replacement,
            routeGrantID: routeGrant.grantID,
            routeHost: host,
            routeTransaction: stagedRoute.transaction,
            teamName: team.id,
            agentInstanceID: agent.agentInstanceId
        ))
    }

    @MainActor
    private func attachRemoteNativeAgent(
        team: Team,
        workspace: Workspace,
        tabManager _: TabManager,
        host: HostEntry,
        sshTarget: String,
        splitFrom: UUID,
        orientation: SplitOrientation,
        agentName: String,
        agentInstanceId: String,
        workingDirectory: String,
        agentType: String,
        model: String,
        cli: String,
        routeGrant: Termmesh_Peer_V1_TeamLeaderGrant,
        routeFilePath: String?
    ) async throws -> AgentMember {
        let bridge = AgentPipeTransport.needsBridge(cli: cli)
            ? AgentPipeTransport.bridgePath(workingDirectory: workingDirectory)
            : nil
        if AgentPipeTransport.needsBridge(cli: cli), bridge == nil {
            throw RemoteAgentError.paneCreationFailed
        }

        let color = Self.agentColor(
            forRole: agentType,
            taken: Set(team.agents.map(\.color))
        )
        let instructions = AgentRunbookService.shared.composeInstructions(
            roleName: agentType,
            presetInstructions: "",
            customInstructions: nil,
            workingDirectory: workingDirectory,
            mode: .digest
        )
        let reverseUnixForward = Self.sshOwnedAgentReverseForward(
            agentInstanceID: agentInstanceId,
            localControlSocket: SocketControlSettings.socketPath()
        )
        // Active CLI profile at the bottom, explicit peer-host values above
        // it, term-mesh's identity last — a profile must be able to add a
        // gateway, not to impersonate the team.
        //
        // Built by the same helper the daemon-owned path uses. This merge was
        // once written out by hand here and omitted the profile layer, so an
        // SSH-owned pane launched without the gateway variables that layer
        // carries (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
        // `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`) while host-stored keys
        // still arrived. A partly-populated environment is the worst shape to
        // debug: it reads as "some variables work" rather than as a whole
        // layer missing, and the CLI fails at authentication far from here.
        // Sharing the helper is what keeps the two ownership models from
        // drifting apart again.
        let remoteEnvironment = try Self.remoteNativeAgentLaunchEnvironment(
            cli: cli,
            hostKey: host.id,
            internalIdentity: Self.remoteNativeAgentEnvironment(
                teamName: team.id,
                agentName: agentName,
                agentType: agentType,
                agentCli: cli,
                workspaceId: workspace.id,
                socketPath: reverseUnixForward.remote,
                routeGrant: routeGrant,
                routeFilePath: routeFilePath
            )
        )
        guard let remoteEnvironmentFile = await Self.writeRemoteAgentEnvironmentOverSSH(
            host: host,
            environment: remoteEnvironment,
            agentInstanceID: agentInstanceId
        ) else {
            throw RemoteAgentError.environmentStagingFailed(host.displayName)
        }
        // PATH is an additive, non-secret bridge input. Everything else is
        // sourced from the peer's 0600 file so grants and API keys never sit
        // in the long-lived local ssh process argv.
        let bridgeEnvironment = remoteEnvironment.filter { $0.key == "PATH" }
        guard let panel = workspace.newAgentSplit(
            from: splitFrom,
            orientation: orientation,
            agentName: agentName,
            teamName: team.id,
            workingDirectory: workingDirectory,
            cli: cli,
            color: color
        ) else {
            await Self.removeRemoteAgentEnvironmentOverSSH(
                host: host, path: remoteEnvironmentFile
            )
            throw RemoteAgentError.paneCreationFailed
        }
        panel.runtimeOwnership = .sshOwned(hostName: host.displayName)

        if let bridge {
            panel.start(
                remoteBridgedCli: cli,
                bridgePath: bridge,
                model: Self.bridgeModelArg(cli: cli, model: model),
                target: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                remoteEnvironment: bridgeEnvironment,
                remoteEnvironmentFile: remoteEnvironmentFile,
                reverseUnixForward: reverseUnixForward
            )
            if !instructions.isEmpty {
                let briefing = Self.withoutTerminalProtocol(instructions)
                    + "\n\nThis is your standing brief, not a task. "
                    + "Do no work now: reply with exactly "
                    + "\"Agent \(agentName) ready.\" and wait."
                try? panel.session.send(briefing, from: .leader)
            }
        } else {
            panel.start(
                remoteClaudeAt: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                model: Self.resolveClaudeModelArg(model),
                instructions: instructions,
                remoteEnvironment: bridgeEnvironment,
                remoteEnvironmentFile: remoteEnvironmentFile,
                reverseUnixForward: reverseUnixForward
            )
        }
        // The remote wrapper normally unlinks the file immediately after
        // sourcing it. This covers authentication/launch failures where that
        // wrapper never ran, without racing a normally starting agent.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await Self.removeRemoteAgentEnvironmentOverSSH(
                host: host, path: remoteEnvironmentFile
            )
        }

        panel.session.onBusyChanged = { [teamName = team.id, agentName, agentInstanceId] busy in
            TeamDataStore.shared.setAgentBusy(
                teamName: teamName, agentName: agentName,
                agentInstanceId: agentInstanceId, busy: busy
            )
        }
        panel.session.onTurnEnd = { [teamName = team.id, agentName, agentInstanceId] final, _, taskId in
            Self.fileReport(
                teamName: teamName, agentName: agentName,
                agentInstanceId: agentInstanceId,
                taskId: taskId, text: final
            )
            guard let taskId else { return }
            AutoReplyEmit.emit(
                teamName: teamName,
                agentName: agentName,
                event: AgentPipeCompletion.headerEvent(from: final),
                preferredTaskId: taskId,
                agentInstanceId: agentInstanceId
            )
        }
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "\(Self.colorEmoji(color)) \(agentName) @\(host.displayName)"
        )

        let member = AgentMember(
            id: "\(agentName)@\(team.id)",
            agentInstanceId: agentInstanceId,
            name: agentName,
            teamName: team.id,
            cli: cli,
            launchCommand: cli,
            model: model,
            agentType: agentType,
            color: color,
            instructions: instructions,
            workspaceId: workspace.id,
            panelId: panel.id,
            createdAt: Date(),
            hostKey: host.id,
            originalAgentWorkDir: workingDirectory
        )
        guard adoptAgentMember(member, teamName: team.id) else {
            _ = workspace.closePanel(panel.id, force: true)
            throw RemoteAgentError.duplicateInstance(member.agentInstanceId)
        }
        scheduleAgentGridEqualization(workspace: workspace)
        RemoteProjectPaths.shared.remember(
            host: host.id,
            localRoot: team.workingDirectory,
            path: workingDirectory
        )
        return member
    }

    static func remoteNativeAgentEnvironment(
        teamName: String,
        agentName: String,
        agentType: String,
        agentCli: String,
        workspaceId: UUID,
        socketPath: String?,
        routeGrant: Termmesh_Peer_V1_TeamLeaderGrant? = nil,
        routeFilePath: String? = nil
    ) -> [String: String] {
        var env: [String: String] = [
            "TERMMESH_TEAM_AGENT": "1",
            "CMUX_TEAM_AGENT": "1",
            "TERMMESH_TEAM_NAME": teamName,
            "CMUX_TEAM_NAME": teamName,
            "TERMMESH_TEAM": teamName,
            "CMUX_TEAM": teamName,
            "TERMMESH_CLI": agentCli,
            "TERMMESH_AGENT_NAME": agentName,
            "TERMMESH_AGENT_ROLE": agentType,
            "TERMMESH_WORKSPACE_ID": workspaceId.uuidString,
        ]
        if let socketPath, !socketPath.isEmpty {
            env["TERMMESH_SOCKET"] = socketPath
            env["CMUX_SOCKET"] = socketPath
        }
        if let routeGrant {
            env.merge(remoteTeamRouteEnvironment(routeGrant)) {
                _, routeValue in routeValue
            }
        }
        // A path, not a bearer. It is what lets a later viewer replace this
        // worker's grant without touching the process that is already running.
        if let routeFilePath, routeFilePath.hasPrefix("/") {
            env[remoteTeamRouteFileEnvName] = routeFilePath
        }
        if agentCli == "claude" {
            env["CLAUDECODE"] = "1"
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        }
        return env
    }

    /// A private control-socket hop for an SSH-owned Native agent.
    ///
    /// The peer endpoint (`peer.sock`) is a framed protobuf transport and
    /// cannot answer tm-agent JSON-RPC. The SSH process already owns this
    /// agent's lifetime, so let the same authenticated session reverse-forward
    /// one per-agent Unix socket to the current app. `peer.leader.call` still
    /// validates the short-lived scoped grant before any team command runs.
    static func sshOwnedAgentReverseForward(
        agentInstanceID: String,
        localControlSocket: String
    ) -> (remote: String, local: String) {
        let safeID = agentInstanceID.lowercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
        let suffix = String(safeID.prefix(48))
        return (
            remote: "/tmp/term-mesh-agent-route-\(suffix).sock",
            local: localControlSocket
        )
    }

    /// Environment understood by `tm-agent`'s scoped reverse route.
    /// The daemon socket remains local to the remote host; these values are a
    /// one-team bearer and audience, not a path back into this Mac.
    static func remoteTeamRouteEnvironment(
        _ grant: Termmesh_Peer_V1_TeamLeaderGrant
    ) -> [String: String] {
        let grantID = grant.grantID.map { String(format: "%02x", $0) }.joined()
        return [
            "TERMMESH_LEADER_GRANT_ID": grantID,
            "TERMMESH_LEADER_PROJECT_ID": grant.projectID,
            "TERMMESH_LEADER_TEAM_UUID": grant.teamUuid,
            "TERMMESH_LEADER_EXPIRES_AT": String(grant.expiresAtUnixSecs),
            "TERMMESH_LEADER_PEER_ID": PeerIdentity.hexString(
                PeerIdentity.defaultPeerID()
            ),
        ]
    }

    /// Names the file `tm-agent` reads its scoped route out of, on every
    /// invocation, in preference to the five frozen variables beside it.
    static let remoteTeamRouteFileEnvName = "TERMMESH_LEADER_ROUTE_FILE"

    private static let remoteRouteFilePathMarker = "__TERMMESH_ROUTE_FILE__="

    /// Where one worker's route lives on its own machine.
    ///
    /// Derived from the agent instance id and nothing else, because the app
    /// that adopts this project later has the roster and not the launch. The
    /// same sanitising rule as the SSH-owned control socket keeps a hostile
    /// instance id from naming a path of its choosing.
    static func remoteAgentRouteFileName(agentInstanceID: String) -> String {
        let safeID = agentInstanceID.lowercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
        return String(safeID.prefix(48)) + ".json"
    }

    /// Stable across viewers, unlike a local leader session or pane id.
    static func remoteLeaderRouteIdentity(teamUUID: String) -> String {
        "leader-" + teamUUID
    }

    static func remoteLeaderRouteFileName(teamUUID: String) -> String {
        remoteAgentRouteFileName(
            agentInstanceID: remoteLeaderRouteIdentity(teamUUID: teamUUID)
        )
    }

    /// The exact bytes `tm-agent`'s `remote_leader_route_from_file` parses.
    static func remoteAgentRouteFilePayload(
        _ grant: Termmesh_Peer_V1_TeamLeaderGrant
    ) -> Data {
        let object: [String: Any] = [
            "version": 1,
            "grant_id_hex": grant.grantID.map { String(format: "%02x", $0) }.joined(),
            "project_id": grant.projectID,
            "team_uuid": grant.teamUuid,
            "expires_at_unix_secs": grant.expiresAtUnixSecs,
            "target_peer_id_hex": PeerIdentity.hexString(PeerIdentity.defaultPeerID()),
        ]
        return (try? JSONSerialization.data(withJSONObject: object))
            ?? Data("{}".utf8)
    }

    /// Write the route beside the running worker, then move it into place.
    ///
    /// Two properties matter and both are in the script rather than in Swift.
    /// The rename is atomic, so a `tm-agent` invocation that lands mid-swap
    /// reads either the whole old route or the whole new one and never a torn
    /// file. And the grant arrives on **stdin**: a bearer in the remote
    /// command line would sit in `ps` output and in shell history on a machine
    /// this app does not own.
    ///
    /// `$HOME` is resolved on the far side and echoed back, because the app
    /// knows the account but not its home directory, and the path has to be
    /// the same one the next adopting app will compute.
    static func remoteAgentRouteStagingScript(agentInstanceID: String) -> String {
        let fileName = remoteAgentRouteFileName(agentInstanceID: agentInstanceID)
        let body = "set -e; umask 077; "
            + "dir=\"$HOME/.term-mesh/agent-routes\"; "
            + "mkdir -p \"$dir\"; chmod 700 \"$dir\"; "
            + "path=\"$dir/\(fileName)\"; tmp=\"$path.$$.tmp\"; "
            + "trap 'rm -f \"$tmp\"' EXIT; "
            + "cat > \"$tmp\"; chmod 600 \"$tmp\"; mv -f \"$tmp\" \"$path\"; "
            + "printf '%s%s\\n' \(shellQuoted(remoteRouteFilePathMarker)) \"$path\""
        // The worker belongs to term-meshd's service account, which may differ
        // from the SSH login. Stage under that same account/home so the child
        // can read the path now and a later viewer can replace it. The helper
        // also forces /bin/sh for fish/csh login accounts.
        return RemotePasteTransfer.serviceAccountCommand(body)
    }

    /// Only an absolute path counts. A shell that printed a warning around the
    /// marker, or a marker with nothing after it, means the write did not land
    /// where the environment will point.
    static func parseRemoteAgentRouteFilePath(_ output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let range = text.range(of: remoteRouteFilePathMarker) else { continue }
            let candidate = String(text[range.upperBound...])
            if candidate.hasPrefix("/") { return candidate }
        }
        return nil
    }

    /// Stage one worker's route on its host, returning the path the worker's
    /// environment should name. `nil` means the route stayed in the
    /// environment — the pre-existing behaviour, and all a host without an SSH
    /// provisioning route can offer.
    static func stageRemoteAgentRouteFile(
        host: HostEntry,
        agentInstanceID: String,
        grant: Termmesh_Peer_V1_TeamLeaderGrant
    ) async -> String? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return nil }
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: remoteAgentRouteStagingScript(agentInstanceID: agentInstanceID),
                standardInput: remoteAgentRouteFilePayload(grant),
                timeoutSeconds: 20
            )
            return parseRemoteAgentRouteFilePath(output)
        } catch {
            // Deliberately value-free: the failure is reported by the caller
            // that knows whether this member was allowed to degrade.
            return nil
        }
    }

    static func revokeGrants(_ grantIDs: [Data]) async {
        for grantID in grantIDs {
            await PeerTeamLeaderControlPlane.shared.revokeGrant(id: grantID)
        }
    }

    /// Replace every adopted worker route as one remote transaction. All new
    /// files are decoded before the first live path changes; the trap restores
    /// backups (or removes newly-created paths) if any later rename fails.
    struct AdoptedRemoteAgentRouteTransfer {
        let leaderGrant: Termmesh_Peer_V1_TeamLeaderGrant
        let workerGrants: [String: Data]
        let transaction: String
        let candidateLeaderRouteFilePath: String
        let newlyMintedGrantIDs: [Data]

        var leaderGrantID: Data { leaderGrant.grantID }
    }

    struct StagedAdoptedRemoteAgentRoutes {
        let transaction: String
        let directory: String

        @MainActor
        func candidateRouteFilePath(agentInstanceID: String) -> String {
            directory + "/" + transaction + "/"
                + TeamOrchestrator.remoteAgentRouteFileName(
                    agentInstanceID: agentInstanceID
                ) + ".new"
        }
    }

    static func stageAdoptedRemoteAgentRoutes(
        host: HostEntry,
        routes: [(agentInstanceID: String, grant: Termmesh_Peer_V1_TeamLeaderGrant)]
    ) async -> StagedAdoptedRemoteAgentRoutes? {
        guard !routes.isEmpty else { return nil }
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return nil }
        let records = routes.map { route in
            remoteAgentRouteFileName(agentInstanceID: route.agentInstanceID)
                + "\t" + remoteAgentRouteFilePayload(route.grant).base64EncodedString()
        }.joined(separator: "\n") + "\n"
        let body = adoptedRemoteAgentRouteTransactionScript()
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: RemotePasteTransfer.serviceAccountCommand(body),
                standardInput: Data(records.utf8),
                timeoutSeconds: 30
            )
            guard let transaction = parseAdoptedRouteTransaction(output),
                  let directory = parseAdoptedRouteDirectory(output) else { return nil }
            return StagedAdoptedRemoteAgentRoutes(
                transaction: transaction, directory: directory
            )
        } catch {
            return nil
        }
    }

    private static let adoptedRouteTransactionMarker = "__TERMMESH_ROUTE_TX__="
    private static let adoptedRouteDirectoryMarker = "__TERMMESH_ROUTE_DIR__="

    struct StagedRemoteAgentRoute {
        let routeFilePath: String
        let transaction: String
    }

    static func parseAdoptedRouteTransaction(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(adoptedRouteTransactionMarker) else { continue }
            let name = String(text.dropFirst(adoptedRouteTransactionMarker.count))
            if name.hasPrefix(".tx."), name.dropFirst(4).allSatisfy(\.isNumber) { return name }
        }
        return nil
    }

    static func parseAdoptedRouteDirectory(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(adoptedRouteDirectoryMarker) else { continue }
            let path = String(text.dropFirst(adoptedRouteDirectoryMarker.count))
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    static func adoptedRemoteAgentRouteTransactionScript() -> String {
        "set -e; umask 077; "
            + "dir=\"$HOME/.term-mesh/agent-routes\"; mkdir -p \"$dir\"; chmod 700 \"$dir\"; "
            + "find \"$dir\" -type f -name '.tx*.done' -mtime +1 -delete 2>/dev/null || true; "
            + "tx=; cleanup() { [ -z \"$tx\" ] || rm -rf \"$tx\"; }; trap cleanup EXIT HUP INT TERM; "
            + "stamp=$(date +%s 2>/dev/null || printf 0); tx=\"$dir/.tx.$$\"$stamp; mkdir \"$tx\"; : > \"$tx/committed\"; tab=$(printf '\\t'); "
            + "while IFS=\"$tab\" read -r n b; do [ -n \"$n\" ] || continue; "
            + "case \"$n\" in *[!a-z0-9.-]*|'') exit 64;; esac; "
            + "if printf '' | base64 -d >/dev/null 2>&1; then flag=-d; elif printf '' | base64 -D >/dev/null 2>&1; then flag=-D; else exit 65; fi; "
            + "printf %s \"$b\" | base64 $flag > \"$tx/$n.new\"; chmod 600 \"$tx/$n.new\"; if [ -f \"$dir/$n\" ]; then cp -p \"$dir/$n\" \"$tx/$n.base\"; else : > \"$tx/$n.absent\"; fi; done; "
            + "for p in \"$tx\"/*.new; do [ -f \"$p\" ] || exit 66; done; "
            + "trap - EXIT HUP INT TERM; printf '%s%s\\n' \(shellQuoted(adoptedRouteDirectoryMarker)) \"$dir\""
            + "; printf '%s%s\\n' \(shellQuoted(adoptedRouteTransactionMarker)) \"${tx##*/}\""
    }

    static func stageRemoteAgentRouteTransaction(
        host: HostEntry,
        agentInstanceID: String,
        grant: Termmesh_Peer_V1_TeamLeaderGrant
    ) async -> StagedRemoteAgentRoute? {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return nil }
        let fileName = remoteAgentRouteFileName(agentInstanceID: agentInstanceID)
        let record = fileName + "\t"
            + remoteAgentRouteFilePayload(grant).base64EncodedString() + "\n"
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: RemotePasteTransfer.serviceAccountCommand(
                    adoptedRemoteAgentRouteTransactionScript()
                ),
                standardInput: Data(record.utf8),
                timeoutSeconds: 30
            )
            guard let transaction = parseAdoptedRouteTransaction(output),
                  let directory = parseAdoptedRouteDirectory(output) else { return nil }
            return StagedRemoteAgentRoute(
                routeFilePath: directory + "/" + fileName,
                transaction: transaction
            )
        } catch {
            return nil
        }
    }

    static func adoptedRemoteAgentRouteFinishScript(
        transaction: String, commit: Bool
    ) -> String? {
        guard transaction.hasPrefix(".tx."),
              transaction.dropFirst(4).allSatisfy(\.isNumber) else { return nil }
        // The validation above reduces this to `.tx.` plus ASCII digits, so it
        // is already safe to embed. Quoting it again inside the surrounding
        // double-quoted path would make the single quotes literal and target
        // `$dir/'.tx.1234'` instead of the staged transaction directory.
        let safeTransaction = transaction
        let rollback = "while IFS= read -r n; do [ -n \"$n\" ] || continue; if [ -f \"$tx/$n.installed\" ] && [ -f \"$dir/$n\" ] && cmp -s \"$tx/$n.installed\" \"$dir/$n\"; then if [ -f \"$tx/$n.old\" ]; then mv -f \"$tx/$n.old\" \"$dir/$n\"; else rm -f \"$dir/$n\"; fi; fi; done < \"$tx/committed\"; rm -rf \"$tx\""
        let lock = "commit_lock=\"$dir/.commit.lock\"; if command -v flock >/dev/null 2>&1; then exec 9>\"$commit_lock\"; flock -n 9 || exit 73; lock_mode=flock; elif command -v shlock >/dev/null 2>&1; then shlock -f \"$commit_lock\" -p $$ || exit 73; lock_mode=shlock; else exit 73; fi; unlock() { if [ \"$lock_mode\" = flock ]; then flock -u 9 2>/dev/null || true; else owner=$(cat \"$commit_lock\" 2>/dev/null || true); [ \"$owner\" = \"$$\" ] && rm -f \"$commit_lock\"; fi; }"
        let action = commit
            ? "[ -f \"$tx/committed.done\" ] && exit 0; [ -d \"$tx\" ] || exit 67; " + lock + "; rollback_and_unlock() { trap - EXIT HUP INT TERM; " + rollback + "; unlock; }; success_signal() { trap - EXIT HUP INT TERM; unlock; exit 74; }; trap rollback_and_unlock EXIT HUP INT TERM; for p in \"$tx\"/*.new; do [ -f \"$p\" ] || continue; n=${p##*/}; n=${n%.new}; if [ -f \"$tx/$n.base\" ]; then [ -f \"$dir/$n\" ] && cmp -s \"$tx/$n.base\" \"$dir/$n\" || exit 73; else [ ! -e \"$dir/$n\" ] || exit 73; fi; done; for p in \"$tx\"/*.new; do [ -f \"$p\" ] || continue; n=${p##*/}; n=${n%.new}; [ ! -f \"$tx/$n.base\" ] || cp -p \"$tx/$n.base\" \"$tx/$n.old\"; cp -p \"$p\" \"$tx/$n.installed\"; printf '%s\\n' \"$n\" >> \"$tx/committed\"; mv -f \"$p\" \"$dir/$n\"; done; trap success_signal HUP INT TERM; trap - EXIT; : > \"$tx/committed.done\"; unlock; trap - HUP INT TERM"
            : lock + "; unlock_only() { trap - EXIT HUP INT TERM; unlock; }; trap unlock_only EXIT HUP INT TERM; " + rollback + "; trap - EXIT HUP INT TERM; unlock"
        let guardTransaction = commit
            ? ""
            : "[ -f \"$tx.done\" ] && exit 69; [ -d \"$tx\" ] || exit 0; "
        return "set -e; dir=\"$HOME/.term-mesh/agent-routes\"; tx=\"$dir/"
            + safeTransaction + "\"; " + guardTransaction + action
    }

    static func adoptedRemoteAgentRouteFinalizeScript(transaction: String) -> String? {
        guard transaction.hasPrefix(".tx."),
              transaction.dropFirst(4).allSatisfy(\.isNumber) else { return nil }
        return "set -e; dir=\"$HOME/.term-mesh/agent-routes\"; tx=\"$dir/"
            + transaction
            + "\"; [ -f \"$tx.done\" ] && exit 0; [ -d \"$tx\" ] || exit 68; "
            + "[ -f \"$tx/committed.done\" ] || exit 68; : > \"$tx.done\"; rm -rf \"$tx\""
    }

    static func finishAdoptedRemoteAgentRoutes(
        host: HostEntry, transaction: String, commit: Bool
    ) async -> Bool {
        await finishAdoptedRemoteAgentRoutesResult(
            host: host, transaction: transaction, commit: commit
        ) == .success
    }

    enum AdoptedRouteFinishResult: Equatable {
        case success
        case conflict
        case unavailable
    }

    static func finishAdoptedRemoteAgentRoutesResult(
        host: HostEntry, transaction: String, commit: Bool
    ) async -> AdoptedRouteFinishResult {
        guard let body = adoptedRemoteAgentRouteFinishScript(
            transaction: transaction, commit: commit
        ), let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return .unavailable }
        do {
            _ = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget, port: host.sshPort, identityFile: host.identityFile,
                script: RemotePasteTransfer.serviceAccountCommand(body), timeoutSeconds: 20
            )
            return .success
        } catch {
            return String(describing: error).contains("exited 73")
                ? .conflict : .unavailable
        }
    }

    static func finalizeAdoptedRemoteAgentRoutes(
        host: HostEntry, transaction: String
    ) async -> Bool {
        guard let body = adoptedRemoteAgentRouteFinalizeScript(transaction: transaction),
              let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return false }
        do {
            _ = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget, port: host.sshPort, identityFile: host.identityFile,
                script: RemotePasteTransfer.serviceAccountCommand(body), timeoutSeconds: 20
            )
            return true
        } catch {
            return false
        }
    }

    static func scheduleAdoptedRemoteAgentRouteFinalize(
        host: HostEntry,
        transaction: String
    ) {
        Task {
            while !(await finalizeAdoptedRemoteAgentRoutes(
                host: host, transaction: transaction
            )) {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    /// Retry the commit after the local roster owns the worker. Staging never
    /// touches the live route, so a failed local operation can simply discard
    /// its prepared transaction and revoke the unused grants.
    static func commitRemoteAgentRoutesPreservingGrants(
        host: HostEntry, transaction: String, grantIDs: [Data],
        finalize: Bool = true
    ) async -> Bool {
        while true {
            switch await finishAdoptedRemoteAgentRoutesResult(
                host: host, transaction: transaction, commit: true
            ) {
            case .success:
                if !finalize { return true }
                while !(await finalizeAdoptedRemoteAgentRoutes(
                    host: host, transaction: transaction
                )) {
                    for grantID in grantIDs {
                        _ = await PeerTeamLeaderControlPlane.shared.keepAliveGrant(id: grantID)
                    }
                    try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                }
                return true
            case .conflict:
                _ = await finishAdoptedRemoteAgentRoutes(
                    host: host, transaction: transaction, commit: false
                )
                await revokeGrants(grantIDs)
                return false
            case .unavailable:
                break
            }
            for grantID in grantIDs {
                _ = await PeerTeamLeaderControlPlane.shared.keepAliveGrant(id: grantID)
            }
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
    }

    /// A committed route keeps its grants until the previous files are
    /// restored. Revoking first leaves every worker reading a dead bearer when
    /// SSH is unavailable for the rollback itself.
    static func rollbackRemoteAgentRoutesPreservingGrants(
        host: HostEntry,
        transaction: String,
        grantIDs: [Data]
    ) {
        Task {
            while true {
                if await finishAdoptedRemoteAgentRoutes(
                    host: host, transaction: transaction, commit: false
                ) {
                    await revokeGrants(grantIDs)
                    return
                }
                for grantID in grantIDs {
                    _ = await PeerTeamLeaderControlPlane.shared.keepAliveGrant(id: grantID)
                }
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    /// Hand the adopted leader and every worker grants this app owns.
    ///
    /// Adoption used to attach the surfaces and stop there, which left each
    /// worker addressing the bearer of whichever viewer created it. While that
    /// viewer ran, everything worked; once it quit, `tm-agent send`, `inbox`
    /// and `reply` answered "invalid remote leader route" on processes that
    /// were otherwise perfectly alive, and the only cure was restarting them
    /// and losing their context.
    ///
    /// So mint per-worker grants here and replace each route file. Returning
    /// the leases rather than installing them keeps the caller free to abandon
    /// the whole adoption: a half-refreshed team is worse than none, because
    /// the panes look adopted and half the roster cannot be reached.
    func mintAdoptedRemoteAgentRoutes(
        teamName: String,
        teamUUID: String,
        host: HostEntry,
        members: [AgentMember],
        reusingLeaderGrant: Termmesh_Peer_V1_TeamLeaderGrant? = nil
    ) async -> AdoptedRemoteAgentRouteTransfer? {
        guard host.sshTarget?.isEmpty == false else { return nil }
        var minted: [String: Data] = [:]
        var routes: [(agentInstanceID: String, grant: Termmesh_Peer_V1_TeamLeaderGrant)] = []
        let leaderRouteID = Self.remoteLeaderRouteIdentity(teamUUID: teamUUID)

        func abandon() async {
            await Self.revokeGrants(Array(minted.values))
        }

        let leaderGrant: Termmesh_Peer_V1_TeamLeaderGrant
        if let reusable = reusingLeaderGrant,
           reusable.teamUuid == teamUUID,
           reusable.projectID == PeerTeamLeader.projectID(
               teamName: teamName, teamUUID: teamUUID
           ) {
            leaderGrant = reusable
        } else {
            guard let fresh = try? await bootstrapRemoteAgentRoute(
                teamName: teamName, teamUUID: teamUUID
            ) else {
                RemoteWorkLog.info(
                    "Could not mint a leader route on \(host.displayName); "
                        + "leaving the existing project untouched"
                )
                return nil
            }
            leaderGrant = fresh
            minted[leaderRouteID] = fresh.grantID
        }
        routes.append((leaderRouteID, leaderGrant))

        for member in members {
            guard let grant = try? await bootstrapRemoteAgentRoute(
                teamName: teamName,
                teamUUID: teamUUID
            ) else {
                RemoteWorkLog.info(
                    "Could not mint a team route for \(member.name) on \(host.displayName); "
                        + "leaving the existing project untouched"
                )
                await abandon()
                return nil
            }
            minted[member.agentInstanceId] = grant.grantID
            routes.append((member.agentInstanceId, grant))
        }
        guard let staged = await Self.stageAdoptedRemoteAgentRoutes(
            host: host, routes: routes
        ) else {
            RemoteWorkLog.info(
                "Could not atomically hand workers new team routes on \(host.displayName); "
                    + "the existing project was left untouched"
            )
            await abandon()
            return nil
        }
        return AdoptedRemoteAgentRouteTransfer(
            leaderGrant: leaderGrant,
            workerGrants: minted.filter { $0.key != leaderRouteID },
            transaction: staged.transaction,
            candidateLeaderRouteFilePath: staged.candidateRouteFilePath(
                agentInstanceID: leaderRouteID
            ),
            newlyMintedGrantIDs: Array(minted.values)
        )
    }

    /// Stop what this agent left running on the other machine, then close its
    /// pane.
    ///
    /// Detaching closes the local pane, which is the whole story for a local
    /// agent — the process lives in that pane and dies with it. A remote pane
    /// is a window onto a process on another machine, so closing it reaches
    /// nothing: the CLI kept running on the peer, still holding a session,
    /// still occupying the surface, and the next agent added to that host
    /// quietly landed in the abandoned one's shell.
    ///
    /// The keystrokes have to outlive the window they travel through, which is
    /// why this owns the close rather than racing it. Then the surface, but
    /// only one this side asked the host to make — a shell the operator
    /// published is theirs, and we merely borrowed it.
    @MainActor
    func releaseRemoteAgent(_ agent: AgentMember, closing workspace: Workspace?, teamName: String? = nil) {
        stopRemoteAgentRouteKeepalive(
            agentInstanceID: agent.agentInstanceId,
            revoke: true
        )
        let hostSockPath = agent.hostKey
            .flatMap { key in RemoteHostStore.shared.sortedHosts.first { $0.id == key } }
            .map(\.activeSockPath)
            .flatMap { $0.isEmpty ? nil : $0 }
        let panelId = agent.panelId
        let panel = panelId.flatMap { id -> TerminalPanel? in
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: id),
                  let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId })
            else { return nil }
            return ws.terminalPanel(for: id)
        }

        // Asked before the panel, deliberately. A peer-owned agent's process
        // is a child of the FAR daemon, and the surface id in the roster is
        // the only thing that can address it — it is in no workspace tree (so
        // no Peer Shells sweep sees it) and in no `ManagedPeerSurfaceStore`
        // (so no reclaim UI lists it). Deciding by "does a panel exist here"
        // would skip the terminate entirely for a member whose pane was
        // already dropped by a rewind, and drop the terminal branch's `/exit`
        // + ClosePane onto a surface that answers neither.
        if agent.remoteAgentSurface {
            if let workspace, let panelId {
                _ = workspace.closePanel(panelId, force: true)
            }
            Self.releasePeerOwnedAgentSurface(agent)
            reapDetachedAgentWorktree(agent, teamName: teamName)
            return
        }

        // A native remote member is an SSH child owned by AgentSession.
        // Closing the panel stops that process; there is no peer surface or
        // interactive CLI to unwind first.
        if let workspace, let panelId, workspace.agentPanel(for: panelId) != nil {
            _ = workspace.closePanel(panelId, force: true)
            reapDetachedAgentWorktree(agent, teamName: teamName)
            return
        }

        if let panel {
            TerminalController.shared.sendNamedKeyWithRetry(on: panel.surface, keyName: "ctrl-c") { _, _ in }
        }
        let surfaceID = agent.remoteSurfaceSpawned ? agent.remoteSurfaceID : nil
        let surfaceHostKey = agent.hostKey
        let quit = Self.quitCommand(cli: agent.cli)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let panel {
                // Its own word for quitting, typed. Ctrl+C and Ctrl+D both
                // reach the remote pane and both are ignored there — measured,
                // twice — because an agent CLI treats them as editing keys,
                // not as the door.
                // Text and Return separately, with room between them. The
                // inline form puts 5ms between the two, which is generous for
                // a local PTY and nothing at all for a pane whose composer is
                // on another machine: the Return arrives before the word does
                // and submits an empty prompt. Measured — `/exit` typed this
                // way ends the CLI, the same string sent inline does not.
                _ = panel.surface.sendIMEText(quit, withReturn: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    TerminalController.shared.sendNamedKeyWithRetry(
                        on: panel.surface, keyName: "return"
                    ) { _, _ in }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                // Hand the shell back plain. The CLI restores these itself on
                // a clean exit, and this is for every other kind.
                panel?.surface.resetTerminal()
                if let workspace, let panelId {
                    _ = workspace.closePanel(panelId, force: true)
                }
                self.reapDetachedAgentWorktree(agent, teamName: teamName)
                guard let surfaceID, let hostSockPath, let surfaceHostKey else { return }
                Task { @MainActor in
                    await Self.closeManagedRemoteSurface(
                        hostSockPath: hostSockPath,
                        hostKey: surfaceHostKey,
                        surfaceID: surfaceID
                    )
                }
            }
        }
    }

    /// A late-added agent's own checkout, prepared on the host.
    ///
    /// Called only for directories recorded as this project's
    /// (`remoteProjectLocations`); an explicitly custom path never reaches
    /// here. The primary is derived from the requested directory over ssh
    /// (`--git-common-dir`), so a request pointing at an existing member's
    /// worktree still creates a new sibling checkout. Every failure is
    /// surfaced because falling back would violate checkout isolation.
    nonisolated static func lateRemoteAgentCheckoutPlan(
        primaryRepository: String,
        agentName: String,
        instanceTag: String
    ) -> PeerProjectBootstrap.Plan {
        PeerProjectBootstrap.plan(
            projectRoot: (primaryRepository as NSString).deletingLastPathComponent,
            projectName: (primaryRepository as NSString).lastPathComponent,
            agents: [agentName],
            isolateAgents: true,
            instanceTag: instanceTag
        )
    }

    static func prepareLateAgentCheckout(
        host: HostEntry,
        hostKey: String,
        agentName: String,
        requestedDirectory: String
    ) async throws -> (path: String, branch: String) {
        let requested = requestedDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
            throw RemoteAgentError.checkoutIsolationFailed(
                host: host.displayName,
                path: requested,
                reason: "the connected host has no SSH provisioning route"
            )
        }

        let quoted = "'" + requested.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let commonDir: String
        do {
            commonDir = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: "git -C \(quoted) rev-parse --path-format=absolute --git-common-dir 2>/dev/null",
                timeoutSeconds: 30
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw RemoteAgentError.checkoutIsolationFailed(
                host: host.displayName,
                path: requested,
                reason: "the requested directory is not a reachable Git checkout"
            )
        }
        guard commonDir.hasSuffix("/.git") else {
            throw RemoteAgentError.checkoutIsolationFailed(
                host: host.displayName,
                path: requested,
                reason: "Git did not report a primary repository"
            )
        }
        let primary = String(commonDir.dropLast("/.git".count))
        guard !primary.isEmpty, primary != "/" else {
            throw RemoteAgentError.checkoutIsolationFailed(
                host: host.displayName,
                path: requested,
                reason: "Git reported an invalid primary repository"
            )
        }

        let plan = Self.lateRemoteAgentCheckoutPlan(
            primaryRepository: primary,
            agentName: agentName,
            instanceTag: PeerProjectBootstrap.makeInstanceTag()
        )
        guard let checkout = plan.agentCheckouts.first else {
            throw RemoteAgentError.checkoutIsolationFailed(
                host: host.displayName,
                path: requested,
                reason: "checkout planning produced no agent checkout"
            )
        }
        do {
            try await PeerProjectBootstrap.run(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                plan: plan,
                gitURL: nil,
                sourceKind: .existingFolder,
                memMeshProjectID: nil,
                environment: PeerHostEnvironment.stored(forHostKey: hostKey)
            )
        } catch {
            throw RemoteAgentError.checkoutIsolationFailed(
                host: host.displayName,
                path: requested,
                reason: String(describing: error)
            )
        }
        RemoteWorkLog.info(
            "\(agentName) joins in its own checkout on \(host.displayName): \(checkout.path) (\(checkout.branch))"
        )
        return (path: checkout.path, branch: checkout.branch)
    }

    /// A detached agent's instance-tagged checkout has no future occupant, so
    /// try to reclaim it. Gated twice: the path must be one this team created
    /// (recorded in `remoteProjectLocations` at creation), and the remote
    /// script itself refuses anything that is not a clean linked worktree —
    /// see `PeerProjectBootstrap.reapWorktreeScript`. Restart and recycle
    /// never come through here; only a true detach does.
    private func reapDetachedAgentWorktree(_ agent: AgentMember, teamName: String?) {
        guard let teamName,
              let hostKey = agent.hostKey,
              let workDir = agent.originalAgentWorkDir?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !workDir.isEmpty,
              teams[teamName] != nil,
              knownRemoteProjectLocations(teamName: teamName)
                  .containsLocation(hostKey: hostKey, path: workDir),
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              let sshTarget = host.sshTarget, !sshTarget.isEmpty
        else { return }
        let port = host.sshPort
        let identityFile = host.identityFile
        Task.detached {
            await PeerProjectBootstrap.reapWorktree(
                sshTarget: sshTarget,
                port: port,
                identityFile: identityFile,
                path: workDir
            )
            await MainActor.run {
                RemoteWorkLog.info(
                    "Reaped \(agent.name)'s checkout on \(host.displayName) (kept if it held uncommitted work): \(workDir)"
                )
            }
        }
    }

    /// Create a team from composed rows, wherever they run.
    ///
    /// The one place that turns `TeamAgentRow`s into a live team, because the
    /// two callers that need it — the New Agent Team sheet and New Project —
    /// would otherwise each carry their own copy of the same three subtleties:
    /// composing the runbook instructions, holding remote members out of
    /// `createTeam`, and attaching them once the workspace and team exist.
    /// The first duplicate of this cost a workspace per project earlier today.
    @discardableResult
    func createTeam(
        named teamName: String,
        rows: [TeamAgentRow],
        workingDirectory: String,
        leaderMode: String,
        leaderModel: String = "sonnet",
        leaderEndpoint: LeaderEndpoint = .local,
        leaderWorkingDirectory: String? = nil,
        worktreeMode: String = "off",
        executionMode: String = "pane",
        resumeSessionId: String? = nil,
        pairMode: String = "none",
        pairModel: String = "",
        pairSpec: String = "",
        delegationLevel: ProjectDelegationLevel = .leaderFirst,
        projectSource: ProjectSource? = nil,
        /// What the bootstrap actually created, as the setup script reported
        /// it. Empty means nothing here is deletable, which is the safe answer
        /// for a caller that did not run a bootstrap.
        createdPaths: Set<PeerProjectBootstrap.CreatedPath> = [],
        onRemoteAttach: ((RemoteAttachOutcome) -> Void)? = nil,
        projectCreationReservation: ProjectCreationReservation? = nil,
        projectCreationIdentity: ProjectCreationIdentity? = nil,
        tabManager: TabManager
    ) -> Team? {
        // Peer attachment is asynchronous. Record the requested endpoint from
        // the start, but keep `leaderReady` false until attach commits. This
        // avoids a visible local → remote identity change without presenting
        // an unattached peer leader as usable. No leader CLI is launched here.
        let initialLeaderEndpoint = Self.initialLeaderEndpoint(
            forRequestedEndpoint: leaderEndpoint
        )
        let launchLeaderLocally = Self.shouldLaunchLeaderLocally(
            forRequestedEndpoint: leaderEndpoint
        )
        // A remote pane is a peer surface pulled into this workspace, so it
        // needs the workspace and the team to already exist. Spawning these
        // locally and moving them would start each CLI on the wrong machine
        // and then close it.
        let remoteRows = rows.filter { $0.hostKey != nil }
        let resolvedRemoteRows: [(row: TeamAgentRow, workingDirectory: String)]
        let resolvedRemoteLeaderWorkingDirectory: String?
        do {
            resolvedRemoteRows = try remoteRows.map { row in
                guard let hostKey = row.hostKey else {
                    preconditionFailure("remoteRows contains a local row")
                }
                return (
                    row,
                    try Self.requiredRemoteWorkingDirectory(
                        row.hostDirectory,
                        hostKey: hostKey
                    )
                )
            }
            if case let .peer(hostKey) = leaderEndpoint {
                resolvedRemoteLeaderWorkingDirectory = try Self.requiredRemoteWorkingDirectory(
                    leaderWorkingDirectory,
                    hostKey: hostKey
                )
            } else {
                resolvedRemoteLeaderWorkingDirectory = nil
            }
        } catch {
            RemoteWorkLog.info("Could not create \(teamName): \(error)")
            return nil
        }
        let remoteLeaderSystemPrompt: String?
        if case let .peer(hostKey) = leaderEndpoint {
            let remoteLeaderHost = RemoteHostStore.shared.sortedHosts
                .first(where: { $0.id == hostKey })
            let remoteSocketPath = remoteLeaderHost?.remoteSockPath
                ?? "inherited from TERMMESH_SOCKET"
            let remoteLeaderBinDirs = remoteLeaderHost?.hostCLIBinDirs ?? []
            if leaderMode.lowercased() == "claude" {
                guard let resolvedRemoteLeaderWorkingDirectory else { return nil }
                remoteLeaderSystemPrompt = Self.remoteLeaderClaudeSystemPrompt(
                    teamName: teamName,
                    rows: rows,
                    remoteWorkingDirectory: resolvedRemoteLeaderWorkingDirectory,
                    remoteSocketPath: remoteSocketPath,
                    hostCLIBinDirs: remoteLeaderBinDirs
                )
            } else {
                // The staged file is this string, so whatever is left out here
                // is left out entirely. Sending only the routing policy taught
                // the leader how to schedule work it had no way to name: no
                // team, no roster, no tm-agent. The renderer already embeds
                // `LeaderParallelPolicy.renderedInstructions`, so the routing
                // rules still arrive — with the team around them.
                guard let resolvedRemoteLeaderWorkingDirectory else { return nil }
                remoteLeaderSystemPrompt = Self.remoteLeaderNonClaudeSystemPrompt(
                    teamName: teamName,
                    rows: rows,
                    remoteWorkingDirectory: resolvedRemoteLeaderWorkingDirectory,
                    remoteSocketPath: remoteSocketPath,
                    hostCLIBinDirs: remoteLeaderBinDirs
                )
            }
        } else {
            remoteLeaderSystemPrompt = nil
        }
        let localTuples = rows.filter { $0.hostKey == nil }.map { row in
            let customInstructions = row.customInstructions == row.preset.instructions
                ? ""
                : row.customInstructions
            let effectiveInstructions = AgentRunbookService.shared.composeInstructions(
                roleName: row.preset.name,
                presetInstructions: row.preset.instructions,
                customInstructions: customInstructions,
                workingDirectory: workingDirectory,
                mode: .digest
            )
            return (
                name: row.preset.name,
                cli: row.preset.cli,
                model: row.preset.model,
                agentType: row.preset.name,
                color: row.preset.color,
                // The custom instructions are composed into `instructions`
                // above; passing them again would append the same spec twice.
                instructions: effectiveInstructions,
                customInstructions: ""
            )
        }

        guard var team = createTeam(
            name: teamName,
            agents: localTuples,
            workingDirectory: workingDirectory,
            leaderSessionId: UUID().uuidString,
            leaderMode: leaderMode,
            leaderModel: leaderModel,
            pairMode: pairMode,
            pairModel: pairModel,
            pairSpec: pairSpec,
            delegationLevel: delegationLevel,
            resumeSessionId: resumeSessionId,
            worktreeMode: worktreeMode,
            executionMode: executionMode,
            leaderEndpoint: initialLeaderEndpoint,
            launchLeaderLocally: launchLeaderLocally,
            agentInstanceIds: rows.filter { $0.hostKey == nil }.map { $0.id.uuidString },
            projectCreationReservation: projectCreationReservation,
            projectCreationIdentity: projectCreationIdentity,
            tabManager: tabManager
        ) else { return nil }

        if let projectSource {
            team.usesDedicatedRemoteWorkspaces = true
            let targetBranch = projectSource.gitBranch
                .trimmingCharacters(in: .whitespacesAndNewlines)
            team.projectTargetBranch = targetBranch.isEmpty ? nil : targetBranch
            setProjectTargetBranch(teamName: team.id, branch: team.projectTargetBranch)
            configureDedicatedRemoteWorkspaces(teamName: team.id, enabled: true)
            var locations: Set<Team.RemoteProjectLocation> = []
            // Ownership is what the bootstrap reported creating, not what the
            // paths look like. A path comparison cannot tell a clone this run
            // made from a checkout the user already kept at that location, and
            // it gets the answer wrong in both directions: it marked a
            // pre-existing sibling checkout deletable, and it marked a clone
            // term-mesh made on the source host permanent.
            func owned(hostKey: String?, path: String) -> Bool {
                createdPaths.contains(.init(hostKey: hostKey, path: path))
            }
            if let hostKey = projectSource.hostKey {
                locations.insert(.init(
                    hostKey: hostKey, path: projectSource.projectPath,
                    owned: owned(hostKey: hostKey, path: projectSource.projectPath)
                ))
            }
            for resolved in resolvedRemoteRows {
                guard let hostKey = resolved.row.hostKey else { continue }
                locations.insert(.init(
                    hostKey: hostKey, path: resolved.workingDirectory,
                    owned: owned(hostKey: hostKey, path: resolved.workingDirectory)
                ))
            }
            if case let .peer(hostKey) = leaderEndpoint {
                guard let resolvedRemoteLeaderWorkingDirectory else { return nil }
                locations.insert(.init(
                    hostKey: hostKey,
                    path: resolvedRemoteLeaderWorkingDirectory,
                    owned: owned(
                        hostKey: hostKey, path: resolvedRemoteLeaderWorkingDirectory
                    )
                ))
            }
            team.remoteProjectLocations = locations.sorted {
                ($0.hostKey, $0.path) < ($1.hostKey, $1.path)
            }
            recordRemoteProjectLocations(
                teamName: team.id,
                locations: team.remoteProjectLocations
            )
        }

        // One at a time. Choosing a surface reads which ones this app's agents
        // already hold, so two attaches running at once both look at a roster
        // that does not have the other in it yet, both pick the same free
        // shell, and both type their launch command into it — the commands
        // interleave character by character and neither CLI starts. Seen as
        // `--dangerously-skip-permissionsskip-permissions` and a `mkdir` that
        // the shell could not find.
        Task { @MainActor in
            if case let .peer(hostKey) = leaderEndpoint {
                guard self.beginRemoteLeaderAttach(teamName: team.id) else {
                    onRemoteAttach?(.leaderFailed(
                        host: hostKey,
                        message: "Remote leader attachment is already in progress"
                    ))
                    onRemoteAttach?(.settled)
                    return
                }
                defer { self.endRemoteLeaderAttach(teamName: team.id) }
#if DEBUG
                dlog("leader.attach.enter host=\(hostKey) "
                    + "wd=\(resolvedRemoteLeaderWorkingDirectory ?? "nil")")
#endif
                guard let resolvedRemoteLeaderWorkingDirectory else {
#if DEBUG
                    dlog("leader.attach.skip reason=noRemoteWorkingDirectory host=\(hostKey)")
#endif
                    // Returning quietly here left the team with a leader that
                    // was never going to arrive and no record of why.
                    let description = "Could not start remote leader on \(hostKey): "
                        + "no working directory was resolved for that host"
                    RemoteWorkLog.info(description)
                    onRemoteAttach?(.leaderFailed(host: hostKey, message: description))
                    self.markRemoteLeaderFailed(teamName: team.id, description: description)
                    onRemoteAttach?(.settled)
                    return
                }
                do {
                    // Bounded as a whole rather than step by step. This path
                    // crosses a tunnel, a relay session, an ssh command and a
                    // shell handshake, and a stall in any one of them used to
                    // leave the pane on "Connecting remote leader…" with no
                    // error, no retry and nothing written to the team — the
                    // failure handling below never ran because nothing ever
                    // threw. A ceiling turns every such stall into the
                    // reported failure it already knows how to show.
#if DEBUG
                    dlog("leader.attach.begin host=\(hostKey) cli=\(leaderMode)")
#endif
                    try await Self.withLeaderAttachDeadline(
                        teamName: team.id,
                        hostKey: hostKey
                    ) { attempt in
                        try await self.attachRemoteLeader(
                            teamName: team.id,
                            hostKey: hostKey,
                            workingDirectory: resolvedRemoteLeaderWorkingDirectory,
                            cli: leaderMode,
                            model: leaderModel,
                            attempt: attempt,
                            systemPrompt: remoteLeaderSystemPrompt
                        )
                    }
#if DEBUG
                    dlog("leader.attach.ok host=\(hostKey)")
#endif
                    onRemoteAttach?(.leaderAttached(host: hostKey))
                } catch {
#if DEBUG
                    dlog("leader.attach.threw host=\(hostKey) error=\(error)")
#endif
                    let description = "Could not start remote leader on \(hostKey): \(error)"
                        + (await Self.staleDaemonHint(hostKey: hostKey) ?? "")
                    RemoteWorkLog.info(description)
                    onRemoteAttach?(.leaderFailed(host: hostKey, message: description))
                    // A failed agent leaves a red row on the board; a failed
                    // leader used to leave nothing, because its only other
                    // channel is a pane title and the failure is what stopped
                    // the pane existing. Same record, so neither depends on a
                    // surface that may not be there.
                    if let task = TeamDataStore.shared.createTask(
                        teamName: team.id,
                        title: "Remote attach failed: leader @ \(hostKey)",
                        details: description,
                        labels: ["remote-attach", "failure", "leader"],
                        priority: 1,
                        createdBy: "term-mesh"
                    ) {
                        _ = TeamDataStore.shared.updateTask(
                            teamName: team.id,
                            taskId: task.id,
                            status: "failed",
                            result: description
                        )
                    }
                    self.markRemoteLeaderFailed(
                        teamName: team.id,
                        description: description
                    )
                    self.markLeaderPolicyState(
                        teamName: team.id,
                        state: "failed",
                        failureDescription: description
                    )
                }
            }
            let rosterGeneration = LeaderAttachGenerationGate.shared.current(teamName: team.id)
            for resolved in resolvedRemoteRows {
                let row = resolved.row
                guard let hostKey = row.hostKey else { continue }
                // Stop starting new ones once a deletion has retired the
                // generation. Attaching agents 3..N into a project that is being
                // removed leaves exactly the checkouts and surfaces the removal
                // has already walked past.
                guard LeaderAttachGenerationGate.shared
                    .isCurrent(teamName: team.id, value: rosterGeneration)
                else { break }
                do {
                    _ = try await self.attachRemoteAgent(
                        teamName: team.id,
                        agentName: row.preset.name,
                        hostKey: hostKey,
                        workingDirectory: resolved.workingDirectory,
                        agentType: row.preset.name,
                        model: row.preset.model,
                        cli: row.preset.cli,
                        agentInstanceId: row.id.uuidString
                    )
                    onRemoteAttach?(.agentAttached(name: row.preset.name, host: hostKey))
                } catch {
                    let description =
                        "Could not start \(row.preset.name) on \(hostKey): \(error)"
                    RemoteWorkLog.info(description)
                    self.recordRemoteAttachFailure(
                        teamName: team.id, description: description
                    )
                    onRemoteAttach?(.agentFailed(
                        name: row.preset.name,
                        host: hostKey,
                        message: description
                    ))
                    if let task = TeamDataStore.shared.createTask(
                        teamName: team.id,
                        title: "Remote attach failed: \(row.preset.name) @ \(hostKey)",
                        details: description,
                        labels: ["remote-attach", "failure"],
                        priority: 1,
                        createdBy: "term-mesh"
                    ) {
                        _ = TeamDataStore.shared.updateTask(
                            teamName: team.id,
                            taskId: task.id,
                            status: "failed",
                            result: description
                        )
                    }
                }
            }
            onRemoteAttach?(.settled)
        }
        return team
    }

    @MainActor
    func deleteProject(teamName: String, tabManager: TabManager) async throws {
        guard let team = teams[teamName] else {
            throw RemoteAgentError.teamNotFound(teamName)
        }
        // Destructive Project actions follow the workspace owner. A sheet in
        // window A may resolve an incomplete Project in window B; using A's
        // manager removes metadata while leaving B's workspace and processes
        // alive. Resolve once, before any teardown side effect.
        let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId)
            ?? tabManager
        let deletionSuppression: String? = {
            guard case let .peer(hostKey) = team.leaderEndpoint,
                  let projectID = team.remotePresentationProjectID
                    ?? team.teamUuid.map(Self.remoteProjectPresentationID(teamUUID:))
            else { return nil }
            return Self.projectDeletionSuppressionKey(hostID: hostKey, projectID: projectID)
        }()
        // A discovered presentation is a local viewer, not an ownership
        // grant. Its destructive action is therefore a detach: close only
        // this app's sessions and leave the daemon-owned surfaces and files.
        guard team.ownsRemotePresentation else {
            _ = destroyTeam(name: teamName, tabManager: tabManager, archive: false)
            return
        }
        if Self.shouldTombstoneDeletedProject(
            ownsRemotePresentation: team.ownsRemotePresentation
        ), let deletionSuppression {
            projectDeletionSuppressions.insert(deletionSuppression)
        }
        // Before anything is read, let alone removed. A leader attach that is
        // still in flight commits by writing a surface record and a checkout;
        // if it does that after the snapshot below, deletion has already
        // decided what exists and the remote process is orphaned. This makes
        // the attach fail its next `ensureCurrent` and run its own
        // compensation instead of racing this.
        //
        // Covers the leader only. A remote *agent* attach carries no attempt
        // and cannot be retired this way — see attachRemoteAgent.
        LeaderAttachGenerationGate.shared.invalidateAll(teamName: teamName)

        // Hold the team tunnel for the whole teardown, before a single pane is
        // closed.
        //
        // Deletion is the one flow that destroys its own transport: it closes
        // the team's panes, which drops the last lease on a redirected host's
        // session owner, and only *then* asks that host to remove surfaces, the
        // workspace, and the manifest. Resolving the socket per step therefore
        // found nothing exactly when it mattered, and every remote object
        // survived a "successful" delete. One lease up front, released when the
        // function returns, keeps every step below addressing the endpoint that
        // owns what it is deleting.
        var teamLeases: [String: PeerPaneHostLease] = [:]
        defer {
            for lease in teamLeases.values { PeerPaneHostRegistry.shared.release(lease) }
        }
        var teamLeaseHostKeys = Set(team.remoteWorkspaceIDs.keys)
        if case let .peer(leaderHostKey) = team.leaderEndpoint {
            teamLeaseHostKeys.insert(leaderHostKey)
        }
        for agent in team.agents { agent.hostKey.map { teamLeaseHostKeys.insert($0) } }
        for hostKey in teamLeaseHostKeys {
            guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
                  let spec = host.teamHostSpec,
                  let lease = try? await PeerPaneHostRegistry.shared.acquire(spec)
            else { continue }
            teamLeases[hostKey] = lease
        }
        /// Local socket for team RPCs against `hostKey`, empty when no lease
        /// could be taken. Callers already report empty as "host not
        /// connected" and leave the object in `remaining`.
        func teamSock(_ hostKey: String) -> String {
            teamLeases[hostKey]?.hostSockPath ?? ""
        }

        // Open the manifest control session before deleting any pane or
        // workspace. The project workspace owns the last live relay in the
        // common adopted-viewer topology; opening a fresh control connection
        // after DeleteWorkspace has torn that relay down repeatedly timed out
        // and left the durable manifest behind. The tunnel lease above keeps
        // the pathname alive, while this connection keeps the authenticated
        // protocol session itself alive across every destructive step.
        var manifestDeletionConnection: PeerRelayConnection?
        if case let .peer(hostKey) = team.leaderEndpoint,
           let teamUUID = team.teamUuid,
           !teamUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sock = teamSock(hostKey)
            guard !sock.isEmpty else {
                throw RemoteAgentError.projectDeletionIncomplete(
                    "manifest preflight \(hostKey): host not connected"
                )
            }
            do {
                let connection = try await PeerRelaySession.connect(hostSockPath: sock)
                if connection.hostCapabilities.has(PeerCapability.projectPresentationV1) {
                    manifestDeletionConnection = connection
                } else {
                    await connection.cancel()
                }
            } catch {
                throw RemoteAgentError.projectDeletionIncomplete(
                    "manifest preflight \(hostKey): \(error)"
                )
            }
        }
        defer {
            if let manifestDeletionConnection {
                Task { await manifestDeletionConnection.cancel() }
            }
        }
        // Commit the durable tombstone while the Project workspace and its
        // relay are still unquestionably alive. Doing this last made the
        // delete ambiguous: DeleteWorkspace succeeded, then the manifest RPC
        // timed out and discovery hid the now-dead surfaces even though the
        // record was still on disk. A successful response here proves the
        // durable record is gone before local/remote runtime cleanup begins.
        if case let .peer(hostKey) = team.leaderEndpoint,
           let teamUUID = team.teamUuid,
           !teamUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let connection = manifestDeletionConnection {
            do {
                let response = try await connection.session.deleteProjectPresentation(
                    projectID: Self.remoteProjectPresentationID(teamUUID: teamUUID)
                )
                guard response.ok else {
                    throw RemoteAgentError.projectDeletionIncomplete(
                        "manifest \(hostKey): \(response.errorCode)"
                    )
                }
                RemoteHostStore.shared.refreshTeamRoster(forHostKey: hostKey)
            } catch {
                throw RemoteAgentError.projectDeletionIncomplete(
                    "manifest delete \(hostKey): \(error)"
                )
            }
        }

        // An ADOPTING viewer holds no recorded workspace id — the manifest
        // carries none, and `recordRemoteWorkspaceID` fires only when leader
        // placement creates the workspace. Deleting from such a viewer
        // skipped DeleteWorkspace entirely, and the leader pane then fell
        // through to ClosePane's last-pane refusal: the daemon-owned leader
        // process survived every "successful" delete. Re-derive the missing
        // ids from the authoritative roster before deciding what exists.
        var remoteWorkspaceIDs = team.remoteWorkspaceIDs
        for hostKey in teamLeaseHostKeys.sorted() where remoteWorkspaceIDs[hostKey] == nil {
            let sock = teamSock(hostKey)
            guard !sock.isEmpty else { continue }
            var knownSurfaceIDs = Set(
                ManagedPeerSurfaceStore.shared.records(hostKey: hostKey)
                    .filter { $0.teamName == teamName }
                    .compactMap(\.surfaceID)
            )
            if case let .peer(leaderHostKey) = team.leaderEndpoint,
               leaderHostKey == hostKey,
               let leaderSurfaceID = team.remoteLeaderSurfaceID {
                knownSurfaceIDs.insert(leaderSurfaceID)
            }
            for agent in team.agents where agent.hostKey == hostKey {
                if let surfaceID = agent.remoteSurfaceID {
                    knownSurfaceIDs.insert(surfaceID)
                }
            }
            guard !knownSurfaceIDs.isEmpty else { continue }
            do {
                let connection = try await PeerRelaySession.connect(hostSockPath: sock)
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    workspaces = try await connection.session.listWorkspaces(timeoutSeconds: 10)
                } catch {
                    await connection.cancel()
                    throw error
                }
                await connection.cancel()
                if let resolved = Self.resolveDedicatedProjectWorkspaceID(
                    workspaces: workspaces,
                    teamName: teamName,
                    knownSurfaceIDs: knownSurfaceIDs
                ) {
                    remoteWorkspaceIDs[hostKey] = resolved
                }
            } catch {
                // Best-effort: an unreachable roster falls back to the
                // per-surface path below, which reports its own failures.
            }
        }

        // Read through the durable record: after a restart the team's
        // in-memory list is empty while its checkouts are still on the peers.
        let grouped = Dictionary(
            grouping: Self.ownedRemoteProjectLocations(
                knownRemoteProjectLocations(teamName: teamName)
            ),
            by: \.hostKey
        )
        var deletionJobs: [(host: HostEntry, script: String)] = []
        var deleted: [String] = []
        var remaining: [String] = []
        var failures: [String] = []
        for (hostKey, locations) in grouped {
            guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey })
            else {
                failures.append("filesystem \(hostKey): host not found")
                remaining.append(contentsOf: locations.map { "path \(hostKey):\($0.path)" })
                continue
            }
            guard host.isConnected, let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
                failures.append("filesystem \(hostKey): host not connected")
                remaining.append(contentsOf: locations.map { "path \(hostKey):\($0.path)" })
                continue
            }
            do {
                let script = try PeerProjectBootstrap.deletionScript(paths: locations.map(\.path))
                deletionJobs.append((host, script))
            } catch {
                failures.append("filesystem \(hostKey): \(error)")
                remaining.append(contentsOf: locations.map { "path \(hostKey):\($0.path)" })
            }
        }

        let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId })
        var remoteSurfaces: [
            (socket: String, hostKey: String, surfaceID: Data, isAgent: Bool)
        ] = []
        if case let .peer(hostKey) = team.leaderEndpoint,
           let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }) {
            let panel = workspace?.terminalPanel(for: team.leaderPanelId)
            if let panel, panel.peerPaneSession != nil {
                TerminalController.shared.sendNamedKeyWithRetry(
                    on: panel.surface, keyName: "ctrl-c"
                ) { _, _ in }
            }
            let surfaceID = panel?.peerPaneSession?.originSurface.surfaceID
                ?? ManagedPeerSurfaceStore.shared.leaderRecord(
                    hostKey: hostKey,
                    teamName: teamName
                )?.surfaceID
            if let surfaceID {
                remoteSurfaces.append((teamSock(hostKey), hostKey, surfaceID, false))
            }
        }

        for agent in team.agents {
            // Order matters, and it is the peer-owned agent that made it
            // matter. Such a member has BOTH an `AgentPanel` here and a live
            // bridge on the peer, so asking "is there a panel?" first closed
            // the local view and stopped — the far `tm-agent-bridge` kept
            // running in a project that no longer exists, with the roster
            // holding the only copy of its surface id, about to be discarded.
            // Ask about the peer's copy first, close the local view too, and
            // let both branches reach the removal loop.
            let peerSurface: (socket: String, hostKey: String, surfaceID: Data, isAgent: Bool)?
            if agent.remoteSurfaceSpawned,
               let surfaceID = agent.remoteSurfaceID,
               let hostKey = agent.hostKey,
               let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }) {
                peerSurface = (
                    teamSock(hostKey), hostKey, surfaceID, agent.remoteAgentSurface
                )
            } else {
                peerSurface = nil
            }
            if let panelID = agent.panelId, workspace?.agentPanel(for: panelID) != nil {
                _ = workspace?.closePanel(panelID, force: true)
            }
            if let peerSurface { remoteSurfaces.append(peerSurface) }
        }

        // Resolve ownership from the authoritative peer layout, per surface.
        // A host can contain old generic surfaces and a newer dedicated
        // project workspace at the same time after a daemon upgrade. The
        // presence of `remoteWorkspaceIDs[host]` alone therefore cannot say
        // that every terminal surface on that host belongs to the workspace.
        var ownedWorkspaceSurfaceIDs: [String: Set<Data>] = [:]
        var workspaceInspectionFailedHosts = Set<String>()
        for (hostKey, workspaceID) in remoteWorkspaceIDs {
            let label = "workspace \(hostKey):\(workspaceID.base64EncodedString())"
            guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
                  !teamSock(hostKey).isEmpty
            else {
                continue
            }
            do {
                let connection = try await PeerRelaySession.connect(
                    hostSockPath: teamSock(hostKey)
                )
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    workspaces = try await connection.session.listWorkspaces(timeoutSeconds: 10)
                } catch {
                    await connection.cancel()
                    throw error
                }
                await connection.cancel()
                guard let surfaceIDs = Self.remoteWorkspaceSurfaceIDs(
                    workspaces: workspaces, workspaceID: workspaceID
                ) else {
                    throw RemoteAgentError.projectDeletionIncomplete(
                        "host returned no workspace for \(label)"
                    )
                }
                // An empty layout means the workspace lifecycle already shed
                // its panes. Continue with individual surface confirmation and
                // DeleteWorkspace instead of turning partial cleanup into an
                // unrecoverable inspection failure.
                ownedWorkspaceSurfaceIDs[hostKey] = surfaceIDs
            } catch {
                workspaceInspectionFailedHosts.insert(hostKey)
                failures.append("\(label): could not inspect workspace surfaces: \(error)")
                remaining.append(label)
            }
        }

        for remote in remoteSurfaces {
            let label = "surface \(remote.hostKey):\(remote.surfaceID.base64EncodedString())"
            // A project-owned workspace is the lifecycle boundary for its
            // terminal panes. ClosePane deliberately refuses to remove the
            // last pane in a workspace, so deleting that pane first both
            // fails confirmation and poisons an otherwise successful project
            // deletion. DeleteWorkspace below tears every pane down
            // authoritatively. Peer-owned native agents are not in the
            // workspace tree and still require TerminateSurface here.
            guard Self.shouldDeleteRemoteSurfaceIndividually(
                isAgent: remote.isAgent,
                belongsToOwnedWorkspace:
                    ownedWorkspaceSurfaceIDs[remote.hostKey]?.contains(remote.surfaceID) == true
            ) else {
                continue
            }
            guard !teamSock(remote.hostKey).isEmpty else {
                failures.append("\(label): host not connected")
                remaining.append(label)
                continue
            }
            do {
                let connection = try await PeerRelaySession.connect(hostSockPath: teamSock(remote.hostKey))
                if remote.isAgent {
                    // An agent surface is never placed in the workspace tree,
                    // so ClosePane finds nothing and reports success — and
                    // `waitForRemoteRemoval`, which reads the layout, then
                    // confirms a removal that never happened. TerminateSurface
                    // addresses the registry and answers for itself:
                    // TERMINATED, or NOT_FOUND, which the proto defines as the
                    // idempotent success a retried cleanup needs.
                    let result: Termmesh_Peer_V1_TerminateSurfaceResult
                    do {
                        result = try await connection.session.terminateSurface(
                            surfaceID: remote.surfaceID
                        )
                    } catch {
                        await connection.cancel()
                        throw error
                    }
                    await connection.cancel()
                    guard result == .terminated || result == .notFound else {
                        throw RemoteAgentError.projectDeletionIncomplete(
                            "host refused to terminate \(label) (\(result))"
                        )
                    }
                } else {
                    do {
                        try await connection.session.requestClosePane(paneID: remote.surfaceID)
                    } catch {
                        await connection.cancel()
                        throw error
                    }
                    // Cancelled exactly once, before confirmation: the removal
                    // poll opens its own probes.
                    await connection.cancel()
                    guard try await waitForRemoteRemoval(
                        hostSockPath: teamSock(remote.hostKey),
                        surfaceID: remote.surfaceID
                    ) else {
                        throw RemoteAgentError.projectDeletionIncomplete(
                            "host did not confirm removal of \(label)"
                        )
                    }
                }
                ManagedPeerSurfaceStore.shared.forget(
                    hostKey: remote.hostKey,
                    surfaceID: remote.surfaceID
                )
                deleted.append(label)
            } catch {
                failures.append("\(label): \(error)")
                remaining.append(label)
            }
        }

        // The project owns these peer workspaces. Removing the project should
        // remove their now-detached shell containers too; relay/default and
        // user-created workspaces are never included in this map.
        for (hostKey, workspaceID) in remoteWorkspaceIDs {
            let label = "workspace \(hostKey):\(workspaceID.base64EncodedString())"
            guard !workspaceInspectionFailedHosts.contains(hostKey) else {
                continue
            }
            guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
                  !teamSock(hostKey).isEmpty
            else {
                failures.append("\(label): host not connected")
                remaining.append(label)
                continue
            }
            do {
                let connection = try await PeerRelaySession.connect(
                    hostSockPath: teamSock(hostKey)
                )
                do {
                    try await connection.session.deleteWorkspace(workspaceID: workspaceID)
                } catch {
                    await connection.cancel()
                    throw error
                }
                // Cancelled exactly once, before confirmation: the removal
                // poll opens its own probes.
                await connection.cancel()
                guard try await waitForRemoteRemoval(
                    hostSockPath: teamSock(hostKey),
                    workspaceID: workspaceID
                ) else {
                    throw RemoteAgentError.projectDeletionIncomplete(
                        "host did not confirm removal of \(label)"
                    )
                }
                let removedSurfaceIDs = ownedWorkspaceSurfaceIDs[hostKey] ?? []
                // DeleteWorkspace removed every terminal surface in this
                // project-owned workspace, including ones skipped by the
                // individual surface loop above. Retire their durable
                // ownership records only after the host confirms the
                // workspace is gone, so a failed delete remains retryable.
                for record in ManagedPeerSurfaceStore.shared.records(hostKey: hostKey)
                where record.teamName == teamName
                    && record.surfaceID.map({ removedSurfaceIDs.contains($0) }) == true {
                    if let surfaceID = record.surfaceID {
                        ManagedPeerSurfaceStore.shared.forget(
                            hostKey: hostKey,
                            surfaceID: surfaceID
                        )
                    }
                }
                forgetRemoteWorkspaceID(teamName: teamName, hostKey: hostKey)
                deleted.append(label)
            } catch {
                failures.append("\(label): \(error)")
                remaining.append(label)
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        for job in deletionJobs {
            let hostKey = job.host.id
            do {
                guard let sshTarget = job.host.sshTarget else {
                    throw RemoteAgentError.hostNotConnected(job.host.displayName)
                }
                try await PeerHostReadinessChecker.runScript(
                    sshTarget: sshTarget,
                    port: job.host.sshPort,
                    identityFile: job.host.identityFile,
                    script: job.script,
                    timeoutSeconds: 60
                )
                let paths = grouped[hostKey, default: []].map(\.path)
                deleted.append(contentsOf: paths.map { "path \(hostKey):\($0)" })
                RemoteProjectPaths.shared.forget(
                    host: hostKey,
                    localRoot: team.workingDirectory
                )
            } catch {
                failures.append("filesystem \(hostKey): \(error)")
                remaining.append(contentsOf: grouped[hostKey, default: []].map {
                    "path \(hostKey):\($0.path)"
                })
            }
        }

        if case let .peer(hostKey) = team.leaderEndpoint,
           let teamUUID = team.teamUuid,
           let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }) {
            do {
                try await Self.removeRemoteLeaderArtifacts(host: host, teamUUID: teamUUID)
                deleted.append("leader artifacts \(hostKey):\(teamUUID)")
            } catch {
                failures.append("leader artifacts \(hostKey): \(error)")
                remaining.append("leader artifacts \(hostKey):\(teamUUID)")
            }
        }

        guard failures.isEmpty else {
            let report = "deleted=[\(deleted.joined(separator: ", "))]; "
                + "remaining=[\(remaining.joined(separator: ", "))]; "
                + "failures=[\(failures.joined(separator: "; "))]"
            // The alert is dismissed and the report goes with it. Remote Work
            // is where the user is already looking for what a peer did, and a
            // partial deletion is exactly the thing to compare against the
            // next attempt.
            RemoteWorkLog.info("Could not delete \(teamName): \(report)")
            throw RemoteAgentError.projectDeletionIncomplete(report)
        }
        let projectID = team.remotePresentationProjectID
            ?? team.teamUuid.map(Self.remoteProjectPresentationID(teamUUID:))
        _ = destroyTeam(name: teamName, tabManager: tabManager, archive: false)
        if let projectID {
            removeProjectPresentationLayout(projectID: projectID)
        }
    }

    /// Terminal panes inside a project-owned workspace are removed by the
    /// workspace lifecycle operation. Agent surfaces live outside that tree
    /// and must always be terminated by their own registry identity.
    nonisolated static func shouldDeleteRemoteSurfaceIndividually(
        isAgent: Bool,
        belongsToOwnedWorkspace: Bool
    ) -> Bool {
        isAgent || !belongsToOwnedWorkspace
    }

    nonisolated static func remoteWorkspaceSurfaceIDs(
        workspaces: [Termmesh_Peer_V1_Workspace],
        workspaceID: Data
    ) -> Set<Data>? {
        guard let workspace = workspaces.first(where: { $0.workspaceID == workspaceID })
        else { return nil }
        return workspace.hasLayout ? peerSurfaceIDs(workspace.layout) : []
    }

    /// The dedicated project workspace for `teamName` on one host, re-derived
    /// from the authoritative workspace roster. The manifest carries no
    /// workspace id, so a viewer that ADOPTED the project holds none —
    /// `recordRemoteWorkspaceID` fires only when leader placement creates the
    /// workspace. Title alone is not ownership (a recreated team can leave an
    /// older same-title workspace behind), so the workspace must also hold
    /// one of the project's known surfaces.
    nonisolated static func resolveDedicatedProjectWorkspaceID(
        workspaces: [Termmesh_Peer_V1_Workspace],
        teamName: String,
        knownSurfaceIDs: Set<Data>
    ) -> Data? {
        guard !knownSurfaceIDs.isEmpty else { return nil }
        let title = remoteProjectWorkspaceTitle(teamName: teamName)
        return workspaces.first(where: { workspace in
            workspace.title == title
                && workspace.hasLayout
                && !peerSurfaceIDs(workspace.layout).isDisjoint(with: knownSurfaceIDs)
        })?.workspaceID
    }

    /// Preserve the user's requested endpoint while the pane is connecting.
    /// Readiness, rather than pretending the endpoint is local, guards sends
    /// and exposes attach failure.
    static func initialLeaderEndpoint(
        forRequestedEndpoint endpoint: LeaderEndpoint
    ) -> LeaderEndpoint {
        endpoint
    }

    static func shouldLaunchLeaderLocally(
        forRequestedEndpoint endpoint: LeaderEndpoint
    ) -> Bool {
        if case .peer = endpoint { return false }
        return true
    }

    /// The delayed first-message injection targets a locally launched TUI.
    /// A peer leader still occupies the local anchor panel while its remote
    /// shell is being prepared; injecting there types the policy directive
    /// into zsh and races the real remote launch.
    static func shouldInjectLocalLeaderPrompt(
        launchLeaderLocally: Bool,
        leaderMode: String
    ) -> Bool {
        launchLeaderLocally && leaderMode != "repl" && leaderMode != "claude"
    }

    /// Say that work on this host has stopped, because the host has.
    ///
    /// An unreachable machine leaves its tasks looking exactly like tasks
    /// nobody has got to yet: `assigned`, no reason, no end. The agent reads
    /// `idle` too, which is worse than wrong — idle means available. Someone
    /// looking at the board sees a healthy team with one task that never
    /// moves, and nothing anywhere connects that to the machine having gone
    /// away.
    ///
    /// Blocking is not a guess about the work. The agent may well have
    /// finished; the point is that this side can no longer find out, and a
    /// task that cannot be observed is not in progress in any useful sense.
    /// Reconnecting is what resolves it, and the reason says so.
    @MainActor
    func markRemoteAgentsUnreachable(hostKey: String, reason: String) {
        for team in teams.values {
            let names = Set(team.agents.filter { $0.hostKey == hostKey }.map(\.name))
            guard !names.isEmpty else { continue }
            for task in TeamDataStore.shared.listTasks(teamName: team.id)
            where names.contains(task.assignee ?? "") && Self.unfinishedStatuses.contains(task.status) {
                _ = TeamDataStore.shared.updateTask(
                    teamName: team.id,
                    taskId: task.id,
                    status: "blocked",
                    blockedReason: "\(hostKey) \(reason) — reconnect the host to pick this up again"
                )
            }
        }
    }

    /// Statuses that mean the work has not reached an end. A task already
    /// finished or already blocked is left alone: the first is history and the
    /// second already says something more specific than this would.
    private static let unfinishedStatuses: Set<String> = [
        "pending", "queued", "assigned", "in_progress", "reassigned",
    ]

    /// Tell only non-durable remote agents to quit because this app is.
    ///
    /// A local agent dies with the app: its process lives in a pane, and the
    /// pane goes when the process hosting it does. An agent on another machine
    /// does not. Durable peer Projects now persist an exact daemon manifest
    /// and are restored from it, so quitting those agents here destroys the
    /// very state the restart contract promises to recover.
    ///
    /// Returns whether anything was asked to quit, so the caller knows whether
    /// it is worth delaying the quit at all.
    @MainActor
    @discardableResult
    func releaseAllRemoteAgentsForQuit() -> Bool {
        let remote = teams.values.flatMap { team -> [AgentMember] in
            let hasPeerLeader: Bool
            if case .peer = team.leaderEndpoint { hasPeerLeader = true }
            else { hasPeerLeader = false }
            let published = publishedRemoteProjectAgentSurfaceIDs[team.id] ?? []
            return team.agents.filter { agent in
                guard agent.hostKey != nil else { return false }
                return Self.shouldReleaseRemoteAgentsOnQuit(
                    ownsRemotePresentation: team.ownsRemotePresentation,
                    hasPeerLeader: hasPeerLeader,
                    teamUUID: team.teamUuid,
                    agentSurfacePublished: agent.remoteSurfaceID.map(published.contains) == true
                )
            }
        }
        var askedTerminalAgentToQuit = false
        for agent in remote {
            guard let panelId = agent.panelId,
                  let located = AppDelegate.shared?.locateSurface(surfaceId: panelId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let panel = workspace.terminalPanel(for: panelId) else { continue }
            askedTerminalAgentToQuit = true
            _ = panel.surface.sendIMEText(Self.quitCommand(cli: agent.cli), withReturn: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitReturnGap) {
                TerminalController.shared.sendNamedKeyWithRetry(
                    on: panel.surface, keyName: "return"
                ) { _, _ in }
            }
        }
        return askedTerminalAgentToQuit
    }

    /// Room for the quit command to reach the far machine before the Return
    /// chasing it. Same reason as every other remote send, on a shorter fuse
    /// because a quit is waiting on it.
    static let quitReturnGap: TimeInterval = 1.0

    /// How long the app will wait for those quits before leaving anyway. A
    /// tidy exit is worth a second or two; it is not worth a quit that hangs
    /// because a peer stopped answering.
    static let quitGrace: TimeInterval = 2.5

    /// How to ask a CLI to quit.
    ///
    /// Typed rather than signalled: Ctrl+C and Ctrl+D both arrive at the pane
    /// and neither ends an agent CLI, which reads them as editing keys —
    /// measured on a live remote pane, twice, before believing it.
    ///
    /// Every CLI term-mesh runs spells it `/exit` today. This takes the CLI
    /// name so the day one of them does not, the answer has a place to live
    /// rather than a literal needing to be found.
    static func quitCommand(cli: String) -> String { "/exit" }

    /// The one line typed into the remote shell to become an agent.
    ///
    /// Deliberately bare: the binary is resolved by the remote PATH rather
    /// than a path captured here, because the two machines do not agree on
    /// where anything lives.
    static func remoteAgentCommand(
        cli: String,
        model: String,
        agentName: String,
        teamName: String,
        workingDirectory: String,
        systemPromptFile: String? = nil,
        environment: [String: String] = [:],
        hostBinDirs: [String] = [],
        // Off for workers on purpose. A worker's results come back through
        // pane output, which is why peer workers already function with their
        // CLI's own sandbox; a leader's do not, so only it needs the socket
        // that sandbox denies. Widening every peer worker to full access
        // without a failure that calls for it is not a change to make quietly.
        needsSocketAccess: Bool = false,
        turnHookFile: String? = nil,
        participationControlFile: String? = nil
    ) -> String {
        let quotedDir = workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
        // `mkdir -p` before `cd`, because a project on another machine has
        // usually not been made there yet. Without it `cd` failed, the `&&`
        // short-circuited, and the CLI never started — leaving a pane that
        // looked attached and was a dead shell, with the reason one scroll up.
        // Idempotent, so an existing directory costs nothing.
        // The launch has to see the same PATH the probe did. Finding a CLI and
        // then starting a shell that cannot is the worst of both: the guard
        // passes and the pane dies with "command not found".
        let enter = RemoteShellPath.prologue(hostBinDirs: hostBinDirs)
            + "mkdir -p '\(quotedDir)' && cd '\(quotedDir)'"
        // The host profile's variables, as an assignment prefix scoped to the
        // CLI itself (`K='v' claude …`). This is where a per-machine
        // IS_SANDBOX or proxy reaches a typed launch.
        let assignments = PeerHostEnvironment.inlineAssignments(environment)
        let envPrefix = assignments.isEmpty ? "" : assignments + " "
        let quotedModel = shellQuoted(model)
        switch cli {
        case "claude":
            let settings = turnHookFile.flatMap(Self.remoteLeaderTurnHookSettingsJSON)
                .map { " --settings \(shellQuoted($0))" } ?? ""
            // The hook must outlive this viewer (the remote Claude process can
            // keep running across an app restart), but it must not survive the
            // leader itself. Attach compensation handles pre-launch failures;
            // this process-lifetime epilogue handles normal exit and Project
            // cleanup while preserving Claude's exit status.
            let cleanupFiles = [turnHookFile, participationControlFile]
                .compactMap { $0 }.map(shellQuoted).joined(separator: " " )
            let hookCleanup = cleanupFiles.isEmpty
                ? ""
                : "; term_mesh_exit_status=$?; rm -f -- \(cleanupFiles); exit \"$term_mesh_exit_status\""
            guard let systemPromptFile else {
                return "\(enter) && \(envPrefix)claude --model \(quotedModel)"
                    + settings + " --dangerously-skip-permissions" + hookCleanup
            }
            let quotedFile = shellQuoted(systemPromptFile)
            return "\(enter) && TERMMESH_LEADER_PROMPT=$(cat \(quotedFile))"
                + " && rm -f \(quotedFile)"
                + " && \(envPrefix)claude --model \(quotedModel)"
                + " --system-prompt \"$TERMMESH_LEADER_PROMPT\""
                + settings
                + " --dangerously-skip-permissions"
                + hookCleanup
        case "codex", "kiro", "gemini":
            let autonomy = needsSocketAccess ? Self.leaderAutonomyFlags(cli: cli) : []
            let codexHooks = cli == "codex" ? turnHookFile.map {
                Self.codexLeaderTurnHookArguments(path: $0).map(shellQuoted).joined(separator: " ")
            } ?? "" : ""
            let allFlags = autonomy + (codexHooks.isEmpty ? [] : [codexHooks])
            let flags = allFlags.isEmpty ? "" : " " + allFlags.joined(separator: " ")
            let cleanupFiles = cli == "codex" ? [turnHookFile, participationControlFile]
                .compactMap { $0 }.map(shellQuoted).joined(separator: " ") : ""
            let cleanup = cleanupFiles.isEmpty ? ""
                : "; term_mesh_exit_status=$?; rm -f -- \(cleanupFiles); exit \"$term_mesh_exit_status\""
            guard let systemPromptFile else {
                return "\(enter) && \(envPrefix)\(cli) --model \(quotedModel)\(flags)" + cleanup
            }
            let directive = LeaderParallelPolicy.launchDirective(promptFile: systemPromptFile)
            switch cli {
            case "kiro":
                return "\(enter) && \(envPrefix)kiro chat --model \(quotedModel)\(flags)"
                    + " \(shellQuoted(directive))"
            default:
                return "\(enter) && \(envPrefix)\(cli) --model \(quotedModel)\(flags)"
                    + " \(shellQuoted(directive))" + cleanup
            }
        default:
            return "\(enter) && \(envPrefix)\(cli) --model \(quotedModel)"
        }
    }

    static func remoteLeaderTurnHookSettingsJSON(path: String) -> String? {
        let hook: (String) -> [String: Any] = { mode in
            ["type": "command", "command": "\"\(path)\" \(mode)", "timeout": 10]
        }
        let object: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [["matcher": "", "hooks": [hook("--start")]]],
                "Stop": [["matcher": "", "hooks": [hook("--end")]]],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The flags a leader CLI needs to act without a human at the keyboard.
    ///
    /// A leader's whole job is `tm-agent`, and `tm-agent` reaches the app over
    /// a Unix socket. Codex's default sandbox denies that connect with EPERM,
    /// so `detect_socket` finds nothing and every team command answers
    /// "no socket found" — the leader can name its teammates and cannot reach
    /// one. Approval prompts fail the same way for a pane nobody is watching.
    ///
    /// The local launch path has passed these since it was written; only the
    /// peer path omitted them, which is why a codex leader was inert on a peer
    /// and fine on this machine. Claude carries its own equivalent
    /// (`--dangerously-skip-permissions`) in the branch above.
    static func leaderAutonomyFlags(cli: String) -> [String] {
        switch cli.lowercased() {
        case "codex":
            return ["--ask-for-approval", "never", "--sandbox", "danger-full-access"]
        case "gemini":
            return ["--yolo"]
        default:
            // kiro has no such flag today. Returning nothing is the honest
            // answer; inventing one would fail at launch instead of at the
            // first socket call.
            return []
        }
    }

    static func remoteLeaderCommand(
        cli: String,
        model: String,
        teamName: String,
        workingDirectory: String,
        grant: Termmesh_Peer_V1_TeamLeaderGrant,
        leaderRequestToken: String,
        systemPromptFile: String? = nil,
        environment: [String: String] = [:],
        hostBinDirs: [String] = [],
        turnHookFile: String? = nil,
        participationControlFile: String? = nil,
        routeFilePath: String? = nil,
        leaderSessionID: String? = nil
    ) -> String {
        let hexGrant = grant.grantID.map { String(format: "%02x", $0) }.joined()
        let protectedValues = [
            ("TERMMESH_LEADER_GRANT_ID", hexGrant),
            ("TERMMESH_LEADER_PROJECT_ID", grant.projectID),
            ("TERMMESH_LEADER_TEAM_UUID", grant.teamUuid),
            ("TERMMESH_LEADER_EXPIRES_AT", String(grant.expiresAtUnixSecs)),
            ("TERMMESH_LEADER_PEER_ID", PeerIdentity.hexString(PeerIdentity.defaultPeerID())),
            ("TERMMESH_LEADER_REQUEST_TOKEN", leaderRequestToken),
            ("TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE", participationControlFile ?? ""),
            (remoteTeamRouteFileEnvName, routeFilePath ?? ""),
            ("TERMMESH_LEADER_SESSION_ID", leaderSessionID ?? ""),
            ("TERMMESH_TEAM", teamName),
        ]
        let savedPrefix = "TERMMESH_SAVED_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let savedExports = protectedValues.map { key, value in
            "\(savedPrefix)_\(key)=\(shellQuoted(value))"
        }.joined(separator: " ")
        let restoreProtected = protectedValues.map { key, _ in
            let saved = "\(savedPrefix)_\(key)"
            return "export \(key)=\"$\(saved)\"; unset \(saved); "
        }.joined()
        let launch = remoteAgentCommand(
            cli: cli,
            model: model,
            agentName: "leader",
            teamName: teamName,
            workingDirectory: workingDirectory,
            systemPromptFile: systemPromptFile,
            environment: environment.filter { $0.key == "PATH" },
            hostBinDirs: hostBinDirs,
            needsSocketAccess: true,
            turnHookFile: turnHookFile,
            participationControlFile: participationControlFile
        )
        // `export` applies to the final CLI, unlike a shell assignment prefix
        // before `mkdir`, which would have scoped the grant to that one setup
        // command only.
        //
        // A terminal surface can inherit SHELL=/bin/sh from systemd even when
        // the account is configured for zsh. Resolve the account shell again
        // here so leaders and peer-owned native agents load the same profile
        // (`~/.zshenv` included). The current terminal shell remains only as a
        // portable resolver and is replaced before the CLI starts.
        let failure = "printf '%s\\n' '[term-mesh environment] failed to load ~/.profile or agent-env'; exit 79"
        let inner = RemoteAgentEnvironmentShell.loginPrelude(
            profileFailureAction: failure,
            agentEnvFailureAction: failure
        ) + RemoteAgentEnvironmentShell.exportAssignments(environment)
            + restoreProtected
            + RemoteAgentEnvironmentShell.terminalDiagnostic
            + launch
        return "export \(savedExports); " + remoteAccountLoginShellExec(inner)
    }

    static func remoteAccountLoginShellExec(_ command: String) -> String {
        RemoteAgentEnvironmentShell.accountLoginShellExec(command)
    }

    /// Secret-free first stage for remote leader launch. The next command is
    /// sent only after this Return, while terminal echo and shell history are
    /// disabled, so the scoped bearer grant is not rendered or retained by the
    /// interactive shell.
    static func remoteLeaderPrepareCommand() -> String {
        "unset HISTFILE; stty -echo"
    }

    /// Create the leader prompt from the shell that will launch the CLI.
    ///
    /// The SSH readiness process may live outside the peer daemon's /tmp
    /// namespace (`PrivateTmp`, container, chroot). PTY canonical input also
    /// has a small per-line limit, so send independently-decodable base64
    /// chunks rather than one long command. 720 is divisible by four and keeps
    /// every command below 1 KiB, including quoting and redirection.
    static func remoteLeaderPromptStageCommands(
        systemPrompt: String?,
        promptFile: String?
    ) -> [String] {
        guard let systemPrompt, let promptFile else { return [] }
        let quotedFile = shellQuoted(promptFile)
        let encoded = Data(systemPrompt.utf8).base64EncodedString()
        let chunkSize = 720
        var chunks: [String] = []
        var start = encoded.startIndex
        while start < encoded.endIndex {
            let end = encoded.index(
                start,
                offsetBy: min(chunkSize, encoded.distance(from: start, to: encoded.endIndex))
            )
            chunks.append(String(encoded[start..<end]))
            start = end
        }

        var commands = [
            "umask 077; "
                + "if printf '' | base64 -d >/dev/null 2>&1; "
                + "then TERMMESH_B64_FLAG='-d'; "
                + "elif printf '' | base64 -D >/dev/null 2>&1; "
                + "then TERMMESH_B64_FLAG='-D'; "
                + "else TERMMESH_B64_FLAG='__missing__'; fi; "
                + ": > \(quotedFile)"
        ]
        commands.append(contentsOf: chunks.map { chunk in
            "printf %s \(shellQuoted(chunk)) | base64 \"$TERMMESH_B64_FLAG\" >> \(quotedFile)"
        })
        return commands
    }

    /// Refuse to launch with a missing or truncated prompt. The error path
    /// restores terminal echo so the pane remains diagnosable instead of
    /// looking like an unresponsive blank shell.
    static func remoteLeaderCommandCheckingPrompt(
        launch: String,
        systemPrompt: String?,
        promptFile: String?
    ) -> String {
        guard let systemPrompt, let promptFile else { return launch }
        let quotedFile = shellQuoted(promptFile)
        let byteCount = Data(systemPrompt.utf8).count
        return "unset TERMMESH_B64_FLAG; "
            + "if [ ! -f \(quotedFile) ] || "
            + "[ \"$(wc -c < \(quotedFile))\" -ne \(byteCount) ]; "
            + "then rm -f \(quotedFile); stty echo; "
            + "printf '%s\\n' 'term-mesh: leader prompt staging failed' >&2; "
            + "else \(launch); fi"
    }

    /// Wait until the relay has forwarded actual shell output before typing.
    ///
    /// `AutoReplyPoller` watches registered agent output, not transport
    /// readiness. A remote leader is not an agent member yet, so asking that
    /// poller kept every leader at its full 25-second timeout even though the
    /// relay had rendered its first frame almost immediately.
    @MainActor
    static func waitForRemoteShell(
        session: PeerPaneSession,
        timeout: TimeInterval = 3,
        settleDelay: TimeInterval = 0.5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = session.relaySession.ioSnapshot
            if (snapshot["bytes_enqueued"] as? UInt64 ?? 0) > 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(
            nanoseconds: UInt64(max(0, settleDelay) * 1_000_000_000)
        )
    }
}
