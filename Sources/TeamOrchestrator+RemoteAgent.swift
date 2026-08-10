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
    typealias Terminator = @MainActor (String, Data) async -> Bool
    struct Record: Codable, Equatable, Identifiable {
        let hostKey: String
        let surfaceIDBase64: String
        let createdAt: Date

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
        terminator: @escaping Terminator = { sockPath, surfaceID in
            await TeamOrchestrator.terminatePeerAgentSurfaceConfirmed(
                hostSockPath: sockPath,
                surfaceID: surfaceID
            )
        }
    ) {
        self.defaults = defaults
        self.automaticRetryDelay = automaticRetryDelay
        self.hostSockPathProvider = hostSockPathProvider
        self.terminator = terminator
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

    func enqueue(hostKey: String, surfaceID: Data) {
        guard !hostKey.isEmpty, !surfaceID.isEmpty else { return }
        let encoded = surfaceID.base64EncodedString()
        guard !records.contains(where: {
            $0.hostKey == hostKey && $0.surfaceIDBase64 == encoded
        }) else { return }
        records.append(Record(
            hostKey: hostKey,
            surfaceIDBase64: encoded,
            createdAt: Date()
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
        terminate: (String, Data) async -> Bool
    ) async {
        let snapshot = records
        for record in snapshot {
            guard let surfaceID = record.surfaceID,
                  let sockPath = hostSockPath(record.hostKey),
                  !sockPath.isEmpty,
                  await terminate(sockPath, surfaceID)
            else { continue }
            records.removeAll { $0.id == record.id }
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
            case .noAttachableSurface(let name): return "\(name) has no free surface to attach"
            case .noFreshSurface(let name): return "\(name) could not create a fresh leader surface"
            case .workspaceGone: return "the team's workspace is gone"
            case .paneCreationFailed: return "could not open the remote pane"
            case .duplicateName(let name): return "the team already has an agent named \(name)"
            case .duplicateInstance(let id): return "the team already has agent instance \(id)"
            case .cliUnavailable(let cli, let host):
                return "\(cli) is not installed on \(host)"
            case .promptStagingFailed(let host):
                return "could not stage the leader prompt on \(host)"
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

    static func remoteProjectWorkspaceTitle(teamName: String) -> String {
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
        let promptFile: String?
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
            hostSockPath = host.activeSockPath
        }

        func cleanup() async {
            if let panelID {
                _ = workspace.closePanel(panelID, force: true)
            } else {
                session?.teardown()
            }
            if let grantID {
                await PeerTeamLeaderControlPlane.shared.revokeGrant(id: grantID)
            }
            if let surfaceID {
                await TeamOrchestrator.closeManagedRemoteSurface(
                    hostSockPath: hostSockPath,
                    hostKey: hostKey,
                    surfaceID: surfaceID
                )
            }
            if let promptFile {
                await TeamOrchestrator.removeRemoteLeaderPrompt(
                    host: host,
                    promptFile: promptFile
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
        let hostSockPath = controlSockPath ?? host.activeSockPath
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

    func closePeerShells(host: HostEntry, surfaceIDs: Set<Data>) async throws -> Int {
        guard !host.activeSockPath.isEmpty else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }
        let protected = claimedRemoteSurfaceIDs(host: host)
        let targets = surfaceIDs.subtracting(protected)
        guard !targets.isEmpty else { return 0 }

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
        func send(_ paneID: Data) async throws {
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
        return try await Self.sweepClose(targets: targets, send: send) { surfaceID in
            ManagedPeerSurfaceStore.shared.forget(hostKey: host.id, surfaceID: surfaceID)
        }
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
        result.formUnion(
            peerPaneSessions(hostKey: host.paneHostSpec.hostKey)
                .map(\.originSurface.surfaceID)
        )
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
        guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }) else {
            throw RemoteAgentError.hostNotFound(hostKey)
        }
        guard host.isLaunchable else { throw RemoteAgentError.hostNotConnected(host.displayName) }
        let promptFile = systemPrompt.map { _ in
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

        let lease = try await PeerPaneHostRegistry.shared.acquire(host.paneHostSpec)
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
                workingDirectory: workingDirectory
            )
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: chosen,
                title: "Leader",
                spec: host.paneHostSpec
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

        do {
#if DEBUG
            dlog("leader.attach.stage prepare.begin host=\(hostKey)")
#endif
            try await Self.prepareRemoteLeader(
                cli: cli,
                host: host,
                systemPrompt: systemPrompt,
                promptFile: promptFile
            )
            try await attempt.ensureCurrent()
#if DEBUG
            dlog("leader.attach.stage prepare.ok host=\(hostKey)")
#endif
        } catch {
            await attempt.compensate()
            throw error
        }

        var bootstrap = Termmesh_Peer_V1_TeamLeaderBootstrapRequest()
        bootstrap.projectID = "name:\(teamName)"
        bootstrap.leaderPlacement = .peer
        var requestUUID = UUID().uuid
        bootstrap.requestID = withUnsafeBytes(of: &requestUUID) { Data($0) }
        let grantResponse = await PeerTeamLeaderControlPlane.shared.bootstrap(
            bootstrap,
            encodedBytes: (try? bootstrap.serializedData().count) ?? 513,
            audiencePeerID: PeerIdentity.defaultPeerID()
        ) { projectID in
            projectID == "name:\(teamName)" ? teamUUID : nil
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

        let command = Self.remoteLeaderCommand(
            cli: cli,
            model: model,
            teamName: teamName,
            workingDirectory: workingDirectory,
            grant: grantResponse.grant,
            systemPromptFile: promptFile,
            environment: PeerHostEnvironment.stored(forHostKey: host.id),
            hostBinDirs: host.hostCLIBinDirs
        )
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
        replaceLeaderAnchorPanel(teamName: teamName, panelID: panel.id)
        panel.surface.resetTerminal()
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "👑 Leader (\(cli.capitalized)) @\(host.displayName)"
        )
        markLeaderPolicyState(teamName: teamName, state: "injected")
        replaceLeaderEndpoint(
            teamName: teamName,
            panelID: panel.id,
            endpoint: .peer(hostKey: hostKey)
        )
        attempt.commit()
        startRemoteLeaderGrantKeepalive(
            teamName: teamName,
            grantID: grantResponse.grant.grantID
        )
    }

    /// Keep a live remote leader's scoped grant renewable while its owning
    /// project exists. Thirty minutes leaves a full interval of scheduler
    /// tolerance inside the one-hour lease. No bearer is sent over a new
    /// channel and an already-expired grant is never resurrected.
    func startRemoteLeaderGrantKeepalive(teamName: String, grantID: Data) {
        stopRemoteLeaderGrantKeepalive(teamName: teamName, revoke: true)
        remoteLeaderGrantIDs[teamName] = grantID
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
                    return
                }
            }
        }
    }

    func stopRemoteLeaderGrantKeepalive(teamName: String, revoke: Bool) {
        remoteLeaderGrantKeepalives.removeValue(forKey: teamName)?.cancel()
        guard let grantID = remoteLeaderGrantIDs.removeValue(forKey: teamName), revoke else { return }
        Task { await PeerTeamLeaderControlPlane.shared.revokeGrant(id: grantID) }
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
    func reattachRemoteLeaderIfNeeded(teamName: String) async -> RemoteLeaderReattachOutcome {
        guard let team = teams[teamName],
              case let .peer(hostKey) = team.leaderEndpoint
        else { return .temporarilyUnavailable }
        if isLeaderPaneAttached(teamName: teamName) { return .attached }
        guard !remoteLeaderReattachInFlight.contains(teamName) else {
            return .temporarilyUnavailable
        }
        remoteLeaderReattachInFlight.insert(teamName)
        defer { remoteLeaderReattachInFlight.remove(teamName) }

        guard let record = ManagedPeerSurfaceStore.shared.leaderRecord(
            hostKey: hostKey,
            teamName: teamName
        ), let surfaceID = record.surfaceID else {
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
            lease = try await PeerPaneHostRegistry.shared.acquire(host.paneHostSpec)
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

        let session: PeerPaneSession
        do {
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: surface,
                title: "Leader",
                spec: host.paneHostSpec
            )
        } catch {
            // The surface is on the host's own roster; only this attach failed.
            PeerPaneHostRegistry.shared.release(lease)
            RemoteWorkLog.info("Cannot restore \(teamName) leader: \(error)")
            return .temporarilyUnavailable
        }
        PeerPaneHostRegistry.shared.release(lease)

        guard let panel = workspace.openRemotePane(
            session: session,
            focus: false,
            lifetime: .keepAlive
        ) else {
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
        closedPanelID: UUID
    ) async -> Bool {
        guard let original = teams[teamName],
              original.leaderPanelId == closedPanelID,
              case let .peer(hostKey) = original.leaderEndpoint
        else { return false }
        guard !remoteLeaderRecoveryInFlight.contains(teamName) else { return false }
        remoteLeaderRecoveryInFlight.insert(teamName)
        defer { remoteLeaderRecoveryInFlight.remove(teamName) }

        markRemoteLeaderFailed(
            teamName: teamName,
            description: "Remote leader disconnected; reconnecting"
        )

        // Bootstrapping mints a second grant and a second surface, so it needs
        // the host to have *said* the old surface is gone. A reattach that
        // merely could not reach the host is retried instead: the remote
        // leader is most likely still running, and replacing it there leaves
        // two on one team.
        var outcome = await reattachRemoteLeaderIfNeeded(teamName: teamName)
        for delay in Self.remoteLeaderReattachBackoffSeconds {
            if case .attached = outcome { return true }
            if outcome.permitsReplacementBootstrap { break }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return false }
            outcome = await reattachRemoteLeaderIfNeeded(teamName: teamName)
        }
        if case .attached = outcome { return true }
        guard outcome.permitsReplacementBootstrap else {
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
        let systemPrompt: String?
        if team.leaderMode.lowercased() == "claude" {
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
                    cli: team.leaderMode,
                    model: team.leaderModel,
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
                projectName: teamName
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
           let leaderSurfaceID = ManagedPeerSurfaceStore.shared.leaderRecord(
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
            projectName: teamName
        )
        if let anchorPanelID = progress.anchorPanelID, workspace.panels.count > 1 {
            _ = workspace.closePanel(anchorPanelID, force: true)
        }
        scheduleAgentGridEqualization(workspace: workspace)

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
    private func attachRestoredRemoteSurface(
        hostKey: String,
        surfaceID: Data,
        title: String,
        panelTitle: String,
        workspace: Workspace,
        onAgentPanel: ((AgentPanel, HostEntry) -> Void)? = nil
    ) async -> UUID? {
        guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              host.isConnected else { return nil }
        let lease: PeerPaneHostLease
        do {
            lease = try await PeerPaneHostRegistry.shared.acquire(host.paneHostSpec)
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
                return nil
            }
            isAgentSurface = SessionHostPanes.isAgentSurfaceType(surface.surfaceType)
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: surface,
                title: title,
                spec: host.paneHostSpec
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
              case let .peer(hostKey) = team.leaderEndpoint,
              let record = ManagedPeerSurfaceStore.shared.leaderRecord(
                  hostKey: hostKey,
                  teamName: teamName
              ),
              let surfaceID = record.surfaceID,
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              !host.activeSockPath.isEmpty
        else { return }

        Task { @MainActor in
            await Self.closeManagedRemoteSurface(
                hostSockPath: host.activeSockPath,
                hostKey: hostKey,
                surfaceID: surfaceID
            )
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
    /// a host with no `tm-agent-bridge` simply cannot own an agent surface and
    /// the terminal path is taken instead.
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

    /// Probe the CLI and stage the long Claude prompt in one SSH round trip.
    ///
    /// Sending the prompt through the attached terminal splits it into several
    /// bracketed-paste transactions. Their boundary bytes then become literal
    /// shell input inside the quoted prompt. A mode-0600 file keeps the launch
    /// line short; the shell reads and removes it before starting Claude.
    private static func prepareRemoteLeader(
        cli: String,
        host: HostEntry,
        systemPrompt: String?,
        promptFile: String?
    ) async throws {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
            if systemPrompt != nil {
                throw RemoteAgentError.promptStagingFailed(host.displayName)
            }
            try await ensureRemoteCLIAvailable(cli: cli, host: host)
            return
        }
        guard AgentRolePreset.knownCLIs.contains(cli) else {
            throw RemoteAgentError.cliUnavailable(cli, host.displayName)
        }
        let marker = "__TERMMESH_LEADER_READY__"
        let missing = "__TERMMESH_LEADER_CLI_MISSING__"
        var script = RemoteShellPath.prologue(hostBinDirs: host.hostCLIBinDirs)
            + "if ! command -v \(shellQuoted(cli)) >/dev/null 2>&1; "
            + "then printf %s \(shellQuoted(missing)); exit 0; fi"
        if let systemPrompt, let promptFile {
            script += "; umask 077; printf %s \(shellQuoted(systemPrompt)) > \(shellQuoted(promptFile))"
        }
        script += "; printf %s \(shellQuoted(marker))"
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
                throw RemoteAgentError.promptStagingFailed(host.displayName)
            }
        } catch let error as RemoteAgentError {
            throw error
        } catch {
            if systemPrompt == nil {
                throw RemoteAgentError.cliUnavailable(cli, host.displayName)
            }
            throw RemoteAgentError.promptStagingFailed(host.displayName)
        }
    }

    private static func removeRemoteLeaderPrompt(host: HostEntry, promptFile: String) async {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return }
        _ = try? await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile,
            script: "rm -f -- \(shellQuoted(promptFile))",
            timeoutSeconds: 10
        )
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
        cli: String = "claude"
    ) async throws -> AgentMember {
        guard let team = teams[teamName] else { throw RemoteAgentError.teamNotFound(teamName) }
        guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }) else {
            throw RemoteAgentError.hostNotFound(hostKey)
        }
        guard host.isLaunchable else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }
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
        if team.remoteProjectLocations.contains(
            .init(hostKey: hostKey, path: requestedDirectory)
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
            let location = Team.RemoteProjectLocation(hostKey: hostKey, path: path)
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

        do {

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
        // **The local bridge** is kept for exactly cursor and agy. A turn is a
        // whole process for those two and they have no interactive UI, so a
        // terminal pane would open empty — the native path is not an upgrade
        // there but the only thing that works at all. Moving them to the peer
        // is a separate change with its own live verification (R8), and until
        // it lands they stay a child of this app and die with it.
        //
        // **Terminal** is everything else, and is exactly the behaviour every
        // remote member had before any of this: claude and gemini have no
        // peer-owned recipe (`tm-agent-bridge --cli` has no claude value, and
        // no native panel holds gemini), and a host whose daemon lacks any of
        // `surface.agent.v1`, `surface.exit.v1`, or `surface.ensure-env.v1`
        // (or has no bridge installed) keeps its PTY pane.
        // Falling back is never silent — each reason is logged below with the
        // one thing that would give the agent pane back.
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
        switch Self.remoteAgentFactory(
            cli: cli,
            hostAdvertisesAgentSurfaces: availability == .available,
            peerBridgePath: binaries.bridgePath,
            sshTarget: host.sshTarget
        ) {
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
                    workingDirectory: workingDirectory,
                    agentType: agentType,
                    model: model,
                    cli: cli,
                    stillWanted: attachStillWanted
                )
                recordIsolatedCheckout()
                return member
            } catch let error as RemoteAgentError {
                // A decision this side made — the roster already holds this
                // member, or the team was retired mid-attach. The terminal
                // path would reach the same answer after spawning a second
                // surface for nothing, so it is reported rather than retried.
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
            } catch {
                // The host's answer, not ours. `canUsePeerOwnedAgent` read the
                // capability off a connection it then closed, so the host can
                // stop advertising it in between — and an ensure refused
                // locally or on the wire creates nothing there. Falling
                // through costs a pane that renders less well; refusing would
                // cost the member entirely.
                RemoteWorkLog.info(
                    Self.peerOwnedAgentFallbackMessage(
                        .ensureRefused, cli: cli, hostName: host.displayName
                    )
                )
            }
        case .localNativeBridge:
            if let sshTarget = host.sshTarget, !sshTarget.isEmpty {
                let member = try attachRemoteNativeAgent(
                    team: team,
                    workspace: workspace,
                    tabManager: tabManager,
                    host: host,
                    sshTarget: sshTarget,
                    splitFrom: placement.panelId,
                    orientation: placement.orientation,
                    agentName: agentName,
                    workingDirectory: workingDirectory,
                    agentType: agentType,
                    model: model,
                    cli: cli
                )
                recordIsolatedCheckout()
                return member
            }
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
        let lease = try await registry.acquire(host.paneHostSpec)
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
                spec: host.paneHostSpec
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
                await Self.closeManagedRemoteSurface(
                    hostSockPath: host.activeSockPath,
                    hostKey: hostKey,
                    surfaceID: spawnedSurfaceID
                )
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
                await Self.closeManagedRemoteSurface(
                    hostSockPath: host.activeSockPath,
                    hostKey: hostKey,
                    surfaceID: spawnedSurfaceID
                )
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
            if let session = panel.peerPaneSession {
                await Self.waitForRemoteShell(session: session)
            }
            let command = Self.remoteAgentCommand(
                cli: cli,
                model: model,
                agentName: agentName,
                teamName: teamName,
                workingDirectory: workingDirectory,
                environment: PeerHostEnvironment.stored(forHostKey: hostKey),
                hostBinDirs: hostCLIBinDirs
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

        recordIsolatedCheckout()
        return member
        } catch {
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
    /// The conservative half is `isPipeOnly` (cursor / agy). They already run
    /// natively and moving them is a separate change with its own live
    /// verification, so they keep the local bridge until that lands.
    ///
    /// Claude is excluded for harder reasons, and they are worth writing down
    /// because "claude speaks NDJSON directly, so it needs no bridge" reads
    /// like an argument for including it:
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
    /// None of that is unfixable, and none of it is a flag flip.
    static func remoteAgentFactory(
        cli: String,
        hostAdvertisesAgentSurfaces: Bool,
        peerBridgePath: String,
        sshTarget: String?
    ) -> RemoteAgentFactory {
        let reachableOverSSH = !(sshTarget ?? "").isEmpty
        // Native panes off, or a CLI no panel can hold (gemini): unchanged.
        guard AgentPipeTransport.canHoldNatively(cli: cli) else { return .terminal }
        if AgentPipeTransport.isPipeOnly(cli: cli) {
            return reachableOverSSH ? .localNativeBridge : .terminal
        }
        // What is left that the bridge can drive is exactly codex and kiro.
        guard AgentPipeTransport.needsBridge(cli: cli) else { return .terminal }
        guard reachableOverSSH,
              hostAdvertisesAgentSurfaces,
              !peerBridgePath.isEmpty
        else { return .terminal }
        return .peerOwnedAgent
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
    }

    /// Whether the peer-owned path is open for this member.
    ///
    /// `notApplicable` is not a failure and must not be reported as one: a
    /// claude member never had this path, so nothing was given up by not
    /// taking it. Only `blocked` describes something the user lost.
    enum PeerOwnedAgentAvailability: Equatable, Sendable {
        case available
        case notApplicable
        case blocked(PeerOwnedAgentBlock)
    }

    /// The one line the user sees when a native agent pane was possible and
    /// did not happen.
    ///
    /// Pure and separate from the check so the wording is pinned by a test
    /// rather than by whoever reads the log next: what opened instead, on
    /// which host, and the single action that would give the agent pane back.
    static func peerOwnedAgentFallbackMessage(
        _ block: PeerOwnedAgentBlock,
        cli: String,
        hostName: String
    ) -> String {
        let lead = "\(cli) on \(hostName) opens as a terminal pane instead of a "
            + "native agent pane"
        switch block {
        case .bridgeMissing:
            return lead + ": that host has no tm-agent-bridge. "
                + "Install term-mesh on \(hostName) to get one."
        case .daemonTooOld:
            return lead + ": its term-meshd lacks the required agent, exit, "
                + "or ensure-environment protocol capability. "
                + "Update term-mesh on \(hostName) to get one."
        case .hostUnreachable:
            return lead + ": its term-meshd could not be asked what it supports. "
                + "Reconnect \(hostName) and attach again to get one."
        case .ensureRefused:
            return lead + ": the host refused to start the bridge. "
                + "Nothing was left running there; attach again to retry."
        }
    }

    static func peerOwnedAgentInvalidEnvironmentFallbackMessage(
        _ error: PeerEnsureEnvironment.ValidationError,
        cli: String,
        hostName: String
    ) -> String {
        "\(cli) on \(hostName) opens as a terminal pane instead of a native agent pane: "
            + "the configured peer environment is invalid (\(error.localizedDescription)). "
            + "Fix the active CLI profile or explicit host environment to restore the native pane."
    }

    /// Ask the host connection itself whether the peer-owned path is open.
    ///
    /// The capability is only knowable from a live handshake — nothing is
    /// cached on `HostEntry` — so this opens a connection, reads
    /// `hostCapabilities`, and closes it. Never fatal: every answer other than
    /// `available` sends the caller to the terminal path, which is what every
    /// remote member did before this existed.
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
              AgentPipeTransport.needsBridge(cli: cli),
              !AgentPipeTransport.isPipeOnly(cli: cli),
              let sshTarget = host.sshTarget, !sshTarget.isEmpty
        else { return .notApplicable }
        guard !binaries.bridgePath.isEmpty else { return .blocked(.bridgeMissing) }
        guard !host.activeSockPath.isEmpty,
              let connection = try? await PeerRelaySession.connect(
                  hostSockPath: host.activeSockPath
              )
        else { return .blocked(.hostUnreachable) }
        let supported = RemoteHostStore.hostSupportsPeerOwnedAgentFactory(
            connection.hostCapabilities
        )
        await connection.cancel()
        return supported ? .available : .blocked(.daemonTooOld)
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
        cli: String,
        workingDirectory: String,
        model: String,
        binaries: RemoteAgentBinaries
    ) -> PeerRunnerSurfaceSpec {
        PeerRunnerSurfaceSpec(
            key: peerAgentEnsureKey(teamName: teamName, agentInstanceId: agentInstanceId),
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
        cleanup.enqueue(hostKey: hostKey, surfaceID: surfaceID)
        cleanup.scheduleRetry()
    }

    /// Record cleanup before dropping the only local handle to a peer-owned
    /// surface. This is also used between ensure and roster adoption, where no
    /// `AgentMember` exists yet for the normal detach cleanup path to inspect.
    static func enqueuePendingPeerAgentSurfaceCleanup(
        hostKey: String,
        surfaceID: Data
    ) {
        enqueuePendingPeerAgentSurfaceCleanup(
            hostKey: hostKey,
            surfaceID: surfaceID,
            cleanup: .shared
        )
    }

    static func enqueuePendingPeerAgentSurfaceCleanup(
        hostKey: String,
        surfaceID: Data,
        cleanup: PendingPeerAgentSurfaceCleanupStore
    ) {
        cleanup.enqueue(hostKey: hostKey, surfaceID: surfaceID)
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
            lease = try await PeerPaneHostRegistry.shared.acquire(host.paneHostSpec)
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
                spec: host.paneHostSpec
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
        surfaceID: Data
    ) -> Bool {
        teams[teamName]?.agents.contains(where: {
            $0.agentInstanceId == agentInstanceID
                && $0.remoteAgentSurface
                && $0.remoteSurfaceID == surfaceID
        }) == true
    }

    @discardableResult
    func validatePeerAgentRecoveryOwnership(
        teamName: String,
        agentInstanceID: String,
        surfaceID: Data,
        onMismatch: () -> Void
    ) -> Bool {
        guard ownsPeerAgentSurface(
            teamName: teamName,
            agentInstanceID: agentInstanceID,
            surfaceID: surfaceID
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
    private func peerOwnedAgentMember(
        panelID: UUID,
        surfaceID: Data
    ) -> (teamName: String, agent: AgentMember)? {
        for (teamName, team) in teams {
            for agent in team.agents where agent.remoteAgentSurface {
                if !surfaceID.isEmpty, agent.remoteSurfaceID == surfaceID {
                    return (teamName, agent)
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
    static func peerOwnedAgentEnvironment(
        profile: [String: String],
        explicitHost: [String: String],
        internalIdentity: [String: String]
    ) throws -> [String: String] {
        let merged = profile
            .merging(explicitHost) { _, hostValue in hostValue }
            .merging(internalIdentity) { _, internalValue in internalValue }
        try PeerEnsureEnvironment.validate(merged)
        return Dictionary(
            uniqueKeysWithValues: try PeerEnsureEnvironment.validatedPairs(merged)
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
        workingDirectory: String,
        agentType: String,
        model: String,
        cli: String,
        stillWanted: () -> Bool
    ) async throws -> AgentMember {
        let agentInstanceId = UUID().uuidString
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
        let environment = try Self.peerOwnedAgentEnvironment(
            profile: CLIPathSettings.activeProfile(for: cli)?.env ?? [:],
            explicitHost: PeerHostEnvironment.stored(forHostKey: host.id),
            internalIdentity: Self.remoteNativeAgentEnvironment(
                teamName: team.id,
                agentName: agentName,
                agentType: agentType,
                agentCli: cli,
                workspaceId: workspace.id,
                socketPath: host.remoteSockPath
            )
        )

        let registry = PeerPaneHostRegistry.shared
        let lease = try await registry.acquire(host.paneHostSpec)
        let ensured: (session: PeerPaneSession, outcome: PeerEnsureSurfaceOutcome)
        do {
            ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: spec,
                attachment: PeerRunnerAttachment(title: agentName, lifetime: .keepAlive),
                hostSpec: host.paneHostSpec,
                agentCli: cli,
                environment: environment,
                onAgentPostEnsureFailure: { surfaceID in
                    Self.enqueuePendingPeerAgentSurfaceCleanup(
                        hostKey: host.id,
                        surfaceID: surfaceID
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
                surfaceID: surfaceID
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
        workingDirectory: String,
        agentType: String,
        model: String,
        cli: String
    ) throws -> AgentMember {
        let agentInstanceId = UUID().uuidString
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
        // The host profile's variables underneath, term-mesh's own on top —
        // a profile must be able to add a proxy, not to impersonate the team.
        let remoteEnvironment = PeerHostEnvironment.stored(forHostKey: host.id)
            .merging(Self.remoteNativeAgentEnvironment(
                teamName: team.id,
                agentName: agentName,
                agentType: agentType,
                agentCli: cli,
                workspaceId: workspace.id,
                socketPath: host.remoteSockPath
            )) { _, internalValue in internalValue }
        guard let panel = workspace.newAgentSplit(
            from: splitFrom,
            orientation: orientation,
            agentName: agentName,
            teamName: team.id,
            workingDirectory: workingDirectory,
            cli: cli,
            color: color
        ) else {
            throw RemoteAgentError.paneCreationFailed
        }

        if let bridge {
            panel.start(
                remoteBridgedCli: cli,
                bridgePath: bridge,
                model: Self.bridgeModelArg(cli: cli, model: model),
                target: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                remoteEnvironment: remoteEnvironment
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
                remoteEnvironment: remoteEnvironment
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

    private static func remoteNativeAgentEnvironment(
        teamName: String,
        agentName: String,
        agentType: String,
        agentCli: String,
        workspaceId: UUID,
        socketPath: String?
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
        if agentCli == "claude" {
            env["CLAUDECODE"] = "1"
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        }
        return env
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
              knownRemoteProjectLocations(teamName: teamName).contains(
                  Team.RemoteProjectLocation(hostKey: hostKey, path: workDir)
              ),
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
        projectSource: ProjectSource? = nil,
        onRemoteAttach: ((RemoteAttachOutcome) -> Void)? = nil,
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
            resumeSessionId: resumeSessionId,
            worktreeMode: worktreeMode,
            executionMode: executionMode,
            leaderEndpoint: initialLeaderEndpoint,
            launchLeaderLocally: launchLeaderLocally,
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
            if let hostKey = projectSource.hostKey {
                locations.insert(.init(hostKey: hostKey, path: projectSource.projectPath))
            }
            for resolved in resolvedRemoteRows {
                guard let hostKey = resolved.row.hostKey else { continue }
                locations.insert(.init(hostKey: hostKey, path: resolved.workingDirectory))
            }
            if case let .peer(hostKey) = leaderEndpoint {
                guard let resolvedRemoteLeaderWorkingDirectory else { return nil }
                locations.insert(.init(hostKey: hostKey, path: resolvedRemoteLeaderWorkingDirectory))
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
                        cli: row.preset.cli
                    )
                    onRemoteAttach?(.agentAttached(name: row.preset.name, host: hostKey))
                } catch {
                    let description =
                        "Could not start \(row.preset.name) on \(hostKey): \(error)"
                    RemoteWorkLog.info(description)
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

        // Read through the durable record: after a restart the team's
        // in-memory list is empty while its checkouts are still on the peers.
        let grouped = Dictionary(
            grouping: knownRemoteProjectLocations(teamName: teamName),
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
                remoteSurfaces.append((host.activeSockPath, hostKey, surfaceID, false))
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
                    host.activeSockPath, hostKey, surfaceID, agent.remoteAgentSurface
                )
            } else {
                peerSurface = nil
            }
            if let panelID = agent.panelId, workspace?.agentPanel(for: panelID) != nil {
                _ = workspace?.closePanel(panelID, force: true)
            }
            if let peerSurface { remoteSurfaces.append(peerSurface) }
        }

        for remote in remoteSurfaces {
            let label = "surface \(remote.hostKey):\(remote.surfaceID.base64EncodedString())"
            guard !remote.socket.isEmpty else {
                failures.append("\(label): host not connected")
                remaining.append(label)
                continue
            }
            do {
                let connection = try await PeerRelaySession.connect(hostSockPath: remote.socket)
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
                        hostSockPath: remote.socket,
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
        for (hostKey, workspaceID) in team.remoteWorkspaceIDs {
            let label = "workspace \(hostKey):\(workspaceID.base64EncodedString())"
            guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
                  !host.activeSockPath.isEmpty
            else {
                failures.append("\(label): host not connected")
                remaining.append(label)
                continue
            }
            do {
                let connection = try await PeerRelaySession.connect(
                    hostSockPath: host.activeSockPath
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
                    hostSockPath: host.activeSockPath,
                    workspaceID: workspaceID
                ) else {
                    throw RemoteAgentError.projectDeletionIncomplete(
                        "host did not confirm removal of \(label)"
                    )
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
        _ = destroyTeam(name: teamName, tabManager: tabManager, archive: false)
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

    /// Tell every agent running on a peer to quit, because this app is.
    ///
    /// A local agent dies with the app: its process lives in a pane, and the
    /// pane goes when the process hosting it does. An agent on another machine
    /// does not — it keeps running, holding its session, with nobody left who
    /// knows it exists. Teams do not survive a restart, so nothing would ever
    /// come back for it, and the next agent added to that host would find the
    /// surface occupied by a ghost. Every restart would leave one more.
    ///
    /// Returns whether anything was asked to quit, so the caller knows whether
    /// it is worth delaying the quit at all.
    @MainActor
    @discardableResult
    func releaseAllRemoteAgentsForQuit() -> Bool {
        let remote = teams.values.flatMap(\.agents).filter { $0.hostKey != nil }
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
        needsSocketAccess: Bool = false
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
            guard let systemPromptFile else {
                return "\(enter) && \(envPrefix)claude --model \(quotedModel) --dangerously-skip-permissions"
            }
            let quotedFile = shellQuoted(systemPromptFile)
            return "\(enter) && TERMMESH_LEADER_PROMPT=$(cat \(quotedFile))"
                + " && rm -f \(quotedFile)"
                + " && \(envPrefix)claude --model \(quotedModel)"
                + " --system-prompt \"$TERMMESH_LEADER_PROMPT\""
                + " --dangerously-skip-permissions"
        case "codex", "kiro", "gemini":
            let autonomy = needsSocketAccess ? Self.leaderAutonomyFlags(cli: cli) : []
            let flags = autonomy.isEmpty ? "" : " " + autonomy.joined(separator: " ")
            guard let systemPromptFile else {
                return "\(enter) && \(envPrefix)\(cli) --model \(quotedModel)\(flags)"
            }
            let directive = LeaderParallelPolicy.launchDirective(promptFile: systemPromptFile)
            switch cli {
            case "kiro":
                return "\(enter) && \(envPrefix)kiro chat --model \(quotedModel)\(flags)"
                    + " \(shellQuoted(directive))"
            default:
                return "\(enter) && \(envPrefix)\(cli) --model \(quotedModel)\(flags)"
                    + " \(shellQuoted(directive))"
            }
        default:
            return "\(enter) && \(envPrefix)\(cli) --model \(quotedModel)"
        }
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
        systemPromptFile: String? = nil,
        environment: [String: String] = [:],
        hostBinDirs: [String] = []
    ) -> String {
        let hexGrant = grant.grantID.map { String(format: "%02x", $0) }.joined()
        let exports = [
            "TERMMESH_LEADER_GRANT_ID=\(shellQuoted(hexGrant))",
            "TERMMESH_LEADER_PROJECT_ID=\(shellQuoted(grant.projectID))",
            "TERMMESH_LEADER_TEAM_UUID=\(shellQuoted(grant.teamUuid))",
            "TERMMESH_LEADER_EXPIRES_AT=\(grant.expiresAtUnixSecs)",
            "TERMMESH_LEADER_PEER_ID=\(shellQuoted(PeerIdentity.hexString(PeerIdentity.defaultPeerID())))",
            "TERMMESH_TEAM=\(shellQuoted(teamName))",
        ].joined(separator: " ")
        let launch = remoteAgentCommand(
            cli: cli,
            model: model,
            agentName: "leader",
            teamName: teamName,
            workingDirectory: workingDirectory,
            systemPromptFile: systemPromptFile,
            environment: environment,
            hostBinDirs: hostBinDirs,
            needsSocketAccess: true
        )
        // `export` applies to the final CLI, unlike a shell assignment prefix
        // before `mkdir`, which would have scoped the grant to that one setup
        // command only.
        // Replace the interactive shell after exporting. That drops the grant
        // as soon as the CLI exits instead of leaving it in a resumed shell.
        return "export \(exports); exec /bin/sh -lc \(shellQuoted(launch))"
    }

    /// Secret-free first stage for remote leader launch. The next command is
    /// sent only after this Return, while terminal echo and shell history are
    /// disabled, so the scoped bearer grant is not rendered or retained by the
    /// interactive shell.
    static func remoteLeaderPrepareCommand() -> String {
        "unset HISTFILE; stty -echo"
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
