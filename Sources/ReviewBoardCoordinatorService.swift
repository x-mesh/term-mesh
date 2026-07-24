import Bonsplit
import Combine
import Foundation
import Darwin

enum ReviewBoardCoordinatorSettings {
    static let enabledEnvironmentKey = "TERMMESH_COORDINATOR_ENABLED"
    static let socketPathEnvironmentKey = "TERMMESH_COORDINATOR_UNIX_PATH"
    static let binaryPathEnvironmentKey = "TERMMESH_COORDINATOR_BINARY"
    static let localJournalEnvironmentKey = "TERMMESH_COORDINATOR_LOCAL_JOURNAL"
    static let distributedFeatureKey = "distributedWorkspaces.enabled"

    /// Environment for a coordinator we launch ourselves.
    ///
    /// The coordinator refuses to start without an event log that guarantees
    /// ordered append/read, and mem-mesh does not offer that contract (it
    /// exposes memory search/add, not a canonical log), so its local journal
    /// is the only backing store that actually works today. Without this the
    /// process exits immediately on `mem_mesh_unavailable` and the app just
    /// sees a coordinator that is never online. An explicit value from the
    /// launcher still wins, so switching backends stays possible.
    static func launchEnvironment(
        base: [String: String],
        socketPath: String
    ) -> [String: String] {
        var environment = base
        environment[socketPathEnvironmentKey] = socketPath
        if environment[localJournalEnvironmentKey] == nil {
            environment[localJournalEnvironmentKey] = "1"
        }
        return environment
    }

    static func isIntegrationEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        environment[enabledEnvironmentKey] == "1"
            && defaults.bool(forKey: distributedFeatureKey)
            && defaults.bool(forKey: ReviewBoardSettings.enabledKey)
    }

    /// The two UserDefaults halves of the gate, read and written as one.
    /// The gate is an AND, so the toggle is "on" only when BOTH are set, and
    /// flipping it moves both together — a half-set state (one key on, one
    /// off) can only come from an older build and must read as off.
    static func distributedWorkspacesToggleOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: distributedFeatureKey)
            && defaults.bool(forKey: ReviewBoardSettings.enabledKey)
    }

    static func setDistributedWorkspacesToggle(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: distributedFeatureKey)
        defaults.set(on, forKey: ReviewBoardSettings.enabledKey)
    }

    static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = {
#if DEBUG
            true
#else
            false
#endif
        }()
    ) -> String {
        if let override = environment[socketPathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        let appSocket = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            isDebugBuild: isDebugBuild
        )
        return appSocket.replacingOccurrences(of: "/term-mesh", with: "/tm-coordinator")
    }
}

/// One peer host as the coordinator should see it. The coordinator is the
/// only place that can answer cross-host questions ("which machine holds
/// this project"), and it learns nothing on its own — the app is what
/// actually watches the peers, so it reports what it sees.
struct CoordinatorHostObservation: Equatable {
    /// The sidebar's stable host key (e.g. `ssh:root@jw-server`), or
    /// `local:` for this machine — which has to appear in the table too, or
    /// the coordinator's view of a project stops at the network boundary.
    let hostKey: String
    let projectRoots: [String]
    /// Subset of `projectRoots` whose team leader runs on this host.
    var leaderProjectRoots: [String] = []
    let isLive: Bool

    static let localHostKey = "local:this-mac"

    /// Derived from the host key so a reconnect — or an app restart — keeps
    /// reporting the SAME host instead of minting a new one each time.
    var coordinatorHostID: String {
        "hst_" + Self.stableDigest(hostKey)
    }

    /// Deterministic in the observation's content: re-reporting an unchanged
    /// host hits the coordinator's idempotency check instead of appending a
    /// duplicate event, so an idle peer costs nothing in journal growth.
    var requestID: String {
        let roots = projectRoots.sorted().joined(separator: "\u{1F}")
        let leaders = leaderProjectRoots.sorted().joined(separator: "\u{1F}")
        return "host-observe:" + Self.stableDigest(
            "\(hostKey)\u{1E}\(roots)\u{1E}\(leaders)\u{1E}\(isLive)"
        )
    }

    var rpcParams: [String: Any] {
        [
            "request_id": requestID,
            "host_id": coordinatorHostID,
            // The peer handshake does not carry platform details yet, and
            // inventing them would be worse than reporting none.
            "os": "",
            "arch": "",
            "load": 0,
            // Slots are omitted, not zeroed. The app mirrors a peer roster
            // and has no basis for a capacity number, and `0` is not the way
            // to say so: the coordinator reads a known zero as "this host is
            // full" and refused to place work on any host the app reported,
            // by hand or automatically. An absent count means "unknown",
            // which stays schedulable and simply ranks last.
            "project_roots": projectRoots.sorted(),
            // The coordinator rejects a leader project the host does not
            // report hosting, so keep this a strict subset.
            "leader_projects": leaderProjectRoots.filter(projectRoots.contains).sorted(),
            "live": isLive,
        ]
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(value.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016lx", hash)
    }
}

/// A host as the coordinator remembers it — including one that is not
/// connected right now. This is the whole point of keeping a coordinator:
/// the peer roster only describes what is reachable this instant, while the
/// coordinator can still say which project lived on a machine that is off.
struct CoordinatorKnownHost: Equatable {
    let hostID: String
    let projectRoots: [String]
    let leaderProjectRoots: [String]
    let isLive: Bool
    let observedAtMilliseconds: Double

    init?(dictionary: [String: Any]) {
        guard let hostID = dictionary["host_id"] as? String else { return nil }
        self.hostID = hostID
        self.projectRoots = (dictionary["project_roots"] as? [String] ?? [])
            .filter { !$0.isEmpty }
        self.leaderProjectRoots = (dictionary["leader_projects"] as? [String] ?? [])
            .filter { !$0.isEmpty }
        self.isLive = dictionary["live"] as? Bool ?? false
        self.observedAtMilliseconds = (dictionary["observed_at_ms"] as? NSNumber)?.doubleValue ?? 0
    }

    init(
        hostID: String,
        projectRoots: [String],
        leaderProjectRoots: [String] = [],
        isLive: Bool,
        observedAtMilliseconds: Double
    ) {
        self.hostID = hostID
        self.projectRoots = projectRoots
        self.leaderProjectRoots = leaderProjectRoots
        self.isLive = isLive
        self.observedAtMilliseconds = observedAtMilliseconds
    }
}

enum ReviewBoardCoordinatorError: Error, Equatable {
    case disabled
    case socketPathTooLong
    case invalidResponse
    case jsonRPCError(code: Int?, message: String)
    case syscall(String, Int32)
}

/// Whether a subscription loop should still be running. Kept as its own
/// object so the loop's life is decided by `stop()` and nothing else — tying
/// it to the client's lifetime instead means a caller who does not happen to
/// retain the client gets a subscription that never runs at all.
private final class CoordinatorSubscriptionToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

final class ReviewBoardCoordinatorClient: @unchecked Sendable {
    private let subscriptionToken = CoordinatorSubscriptionToken()
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.termmesh.review-board.coordinator", qos: .utility)
    /// The event subscription blocks on its socket for the connection's whole
    /// lifetime. Sharing `queue` with it would mean the first subscribe
    /// starves every later request forever — no snapshot refresh, no host
    /// observation — so it gets a queue of its own.
    private let subscriptionQueue = DispatchQueue(
        label: "com.termmesh.review-board.coordinator.events",
        qos: .utility
    )
    private var nextID = 1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func fetchSnapshot() async throws -> ReviewBoardSnapshot {
        async let statusResponse = request(method: "orchestration.status")
        async let taskResponse = request(method: "task.list")
        async let mergeQueueResponse = request(method: "merge.queue")
        async let eventResponse = request(method: "events.subscribe", params: ["scope": "review_board", "replay": false])

        let statusObject = try await statusResponse as? [String: Any] ?? [:]
        let taskObject = try await taskResponse
        // The queue is additive to the board: losing it should grey out one
        // section, not sink the whole snapshot and report a live coordinator
        // as offline.
        let mergeQueueObject = try? await mergeQueueResponse
        _ = try? await eventResponse

        let taskRows: [[String: Any]]
        if let rows = taskObject as? [[String: Any]] {
            taskRows = rows
        } else if let object = taskObject as? [String: Any],
                  let rows = object["tasks"] as? [[String: Any]] {
            taskRows = rows
        } else {
            taskRows = []
        }

        let mergeQueueRows = (mergeQueueObject as? [String: Any])?["items"] as? [[String: Any]] ?? []
        let mergeQueue = mergeQueueRows.compactMap(ReviewBoardMergeQueueItem.init(dictionary:))

        // Coordinator rows, read with the coordinator's vocabulary. Parsed
        // with the team board's they all failed the `id` guard and the board
        // showed nothing at all.
        let reviewTasks = taskRows.compactMap(ReviewBoardTask.init(coordinatorDictionary:))
        let panelRuns = (statusObject["panel_runs"] as? [[String: Any]] ?? [])
            .compactMap(ReviewBoardPanelRun.init(dictionary:))
        let memMeshAvailable = statusObject["mem_mesh_available"] as? Bool
            ?? statusObject["memMeshAvailable"] as? Bool
            ?? true
        let suspectHost = statusObject["suspect_host"] as? Bool
            ?? statusObject["suspectHost"] as? Bool
            ?? reviewTasks.contains { $0.labels.contains("suspect-host") }
        let fencedZombie = statusObject["fenced_zombie"] as? Bool
            ?? statusObject["fencedZombie"] as? Bool
            ?? reviewTasks.contains { $0.labels.contains("fenced-zombie") }

        return ReviewBoardSnapshot(
            tasks: reviewTasks,
            panelRuns: panelRuns,
            mergeQueue: mergeQueue,
            coordinatorOnline: true,
            memMeshAvailable: memMeshAvailable,
            suspectHost: suspectHost,
            fencedZombie: fencedZombie
        )
    }

    /// Raw task rows, plus each project's root path. The board's parsed tasks
    /// deliberately drop `placement` and `current_attempt_id` — the two fields
    /// a dispatcher needs — so this reads them separately rather than widening
    /// `ReviewBoardTask` with fields no view shows.
    func fetchPlacementInputs() async throws -> (rows: [[String: Any]], roots: [String: String]) {
        async let taskResponse = request(method: "task.list")
        async let projectResponse = request(method: "project.list")
        let rows = (try await taskResponse as? [String: Any])?["tasks"] as? [[String: Any]] ?? []
        let projects = (try await projectResponse as? [String: Any])?["projects"] as? [[String: Any]] ?? []
        var roots: [String: String] = [:]
        for project in projects {
            guard let id = project["project_id"] as? String,
                  let root = project["root_path"] as? String else { continue }
            roots[id] = root
        }
        return (rows, roots)
    }

    /// Say a dispatch failed, in the coordinator's own vocabulary, so the
    /// board shows it instead of the work sitting placed-and-silent forever.
    /// The request id is derived from the attempt so a retry of the same
    /// failure is idempotent rather than a second journal entry.
    func reportPlacementFailure(taskID: String, attemptID: String, reason: String) async {
        _ = try? await request(
            method: "task.suspect",
            params: [
                "request_id": "dispatch-failed:\(attemptID)",
                "task_id": taskID,
                "reason": reason,
            ]
        )
    }

    /// Register a project root and return its coordinator id, reusing the
    /// existing record when the root is already known. Delegating work to a
    /// project the coordinator has never heard of has to create it, and doing
    /// so here keeps that out of the sidebar's hands.
    func ensureProject(rootPath: String, name: String) async throws -> String {
        let projects = (try await request(method: "project.list") as? [String: Any])?["projects"]
            as? [[String: Any]] ?? []
        if let existing = projects.first(where: { $0["root_path"] as? String == rootPath }),
           let id = existing["project_id"] as? String {
            return id
        }
        let added = try await request(
            method: "project.add",
            params: [
                "request_id": "project-add:\(rootPath)",
                "root_path": rootPath,
                "name": name,
            ]
        )
        guard let event = (added as? [String: Any])?["event"] as? [String: Any],
              let id = event["project_id"] as? String else {
            throw ReviewBoardCoordinatorError.invalidResponse
        }
        return id
    }

    /// Create a task in a project and immediately ask for it to be placed.
    /// Creating without placing would leave work the coordinator never picks a
    /// host for — it schedules on request, not on a timer.
    func delegate(projectID: String, title: String, body: String) async throws {
        let requestID = "delegate:\(UUID().uuidString)"
        let created = try await request(
            method: "task.create",
            params: [
                "request_id": "\(requestID):create",
                "project_id": projectID,
                "title": title,
                "body": body,
            ]
        )
        guard let event = (created as? [String: Any])?["event"] as? [String: Any],
              let payload = event["payload"] as? [String: Any],
              let taskID = payload["task_id"] as? String else {
            throw ReviewBoardCoordinatorError.invalidResponse
        }
        _ = try await request(
            method: "task.place",
            params: ["request_id": "\(requestID):place", "task_id": taskID]
        )
    }

    func observeHosts(_ observations: [CoordinatorHostObservation]) async {
        for observation in observations {
            // One failing host must not stop the rest: the coordinator may be
            // mid-restart, and the next sync re-reports everything anyway.
            do {
                _ = try await request(method: "host.observe", params: observation.rpcParams)
#if DEBUG
                dlog("coordinator.observeHost ok key=\(observation.hostKey) roots=\(observation.projectRoots.count)")
#endif
            } catch {
#if DEBUG
                dlog("coordinator.observeHost FAILED sock=\(socketPath) key=\(observation.hostKey) error=\(error)")
#endif
            }
        }
    }

    func fetchKnownHosts() async throws -> [CoordinatorKnownHost] {
        let response = try await request(method: "host.list")
        let rows: [[String: Any]]
        if let object = response as? [String: Any], let hosts = object["hosts"] as? [[String: Any]] {
            rows = hosts
        } else {
            rows = response as? [[String: Any]] ?? []
        }
        return rows.compactMap(CoordinatorKnownHost.init(dictionary:))
    }

    /// Reconnecting, because the first attempt is made moments after the app
    /// spawns the coordinator and routinely lands before it is listening. This
    /// used to give up there — silently, and for the life of the process, so
    /// nothing the coordinator did ever reached the app again. The refresh
    /// path already learned this lesson and got a backoff; the subscription
    /// did not, and a subscription that dies once is worse than one that never
    /// starts, because everything downstream of it simply stops happening.
    ///
    /// The same loop covers a coordinator that restarts later: the stream ends,
    /// and the next pass dials again.
    func subscribeEvents(onEvent: @escaping @Sendable () -> Void) {
        subscriptionQueue.async { [socketPath, subscriptionToken] in
            var backoff = 0.25
            while subscriptionToken.isRunning {
                let connected = Self.pumpEvents(socketPath: socketPath, onEvent: onEvent)
                // A connection that carried frames is a healthy one that ended;
                // start the next attempt eagerly. One that never opened means
                // the coordinator is still not there, so ease off.
                backoff = connected ? 0.25 : min(backoff * 2, 5)
                Thread.sleep(forTimeInterval: backoff)
            }
        }
    }

    /// Runs one subscription connection to completion. Returns whether it ever
    /// got as far as subscribing, which is what tells the caller apart a
    /// coordinator that is absent from one that closed the stream.
    private static func pumpEvents(
        socketPath: String,
        onEvent: @escaping @Sendable () -> Void
    ) -> Bool {
        guard let fd = try? connect(socketPath: socketPath) else { return false }
        defer { Darwin.close(fd) }
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "events.subscribe",
            "params": ["scope": "review_board"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              writeLine(fd: fd, data: data) else {
            return false
        }
        while let line = readLine(fd: fd) {
            switch eventFrame(from: line) {
            case .relevant, .gap:
                onEvent()
            case .keepalive, .ack, .ignored:
                continue
            }
        }
        return true
    }

    func stopSubscribing() {
        subscriptionToken.stop()
    }

    private func request(method: String, params: [String: Any]? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let fd = try Self.connect(socketPath: socketPath)
                    defer { Darwin.close(fd) }
                    let id = nextRequestID()
                    var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
                    if let params { payload["params"] = params }
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    guard Self.writeLine(fd: fd, data: data),
                          let line = Self.readLine(fd: fd),
                          let lineData = line.data(using: .utf8),
                          let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        throw ReviewBoardCoordinatorError.invalidResponse
                    }
                    if let error = object["error"] as? [String: Any] {
                        throw ReviewBoardCoordinatorError.jsonRPCError(
                            code: error["code"] as? Int,
                            message: error["message"] as? String ?? "Coordinator request failed"
                        )
                    }
                    guard let result = object["result"] else {
                        throw ReviewBoardCoordinatorError.invalidResponse
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func nextRequestID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    /// Whether something is actually accepting on `socketPath`. A socket FILE
    /// proves nothing — a coordinator that died leaves its path behind — so
    /// this is what "already running" has to mean.
    static func isSocketAlive(_ socketPath: String) -> Bool {
        guard let fd = try? connect(socketPath: socketPath) else { return false }
        Darwin.close(fd)
        return true
    }

    private static func connect(socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ReviewBoardCoordinatorError.syscall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else {
            Darwin.close(fd)
            throw ReviewBoardCoordinatorError.socketPathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                for (offset, byte) in path.enumerated() {
                    bytes[offset] = CChar(bitPattern: byte)
                }
            }
        }
        let rc = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ReviewBoardCoordinatorError.syscall("connect", code)
        }
        return fd
    }

    static func writeLine(fd: Int32, data: Data) -> Bool {
        var line = data
        line.append(0x0A)
        return line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var sent = 0
            while sent < line.count {
                let written = Darwin.write(fd, base.advanced(by: sent), line.count - sent)
                guard written > 0 else { return false }
                sent += written
            }
            return true
        }
    }

    static func readLine(fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { break }
            guard count > 0 else { return nil }
            if byte == 0x0A { break }
            bytes.append(byte)
            if bytes.count > 1_048_576 { return nil }
        }
        guard !bytes.isEmpty else { return nil }
        return String(data: Data(bytes), encoding: .utf8)
    }

    enum EventFrame: Equatable {
        case ack
        case keepalive
        case gap
        case relevant
        case ignored
    }

    static func eventFrame(from line: String) -> EventFrame {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }
        if object["jsonrpc"] as? String == "2.0" {
            return .ack
        }
        let kind = (
            object["kind"] as? String
                ?? object["event_kind"] as? String
                ?? object["eventKind"] as? String
                ?? object["type"] as? String
                ?? ((object["event"] as? [String: Any])?["kind"] as? String)
                ?? ""
        )
        if kind == "keepalive" || object["keepalive"] as? Bool == true {
            return .keepalive
        }
        if kind == "event_gap" || object["event_gap"] as? Bool == true {
            return .gap
        }
        if kind == "error", object["code"] as? String == "event_too_large" {
            return .gap
        }
        return relevantEventKinds.contains(kind) ? .relevant : .ignored
    }

    private static let relevantEventKinds: Set<String> = [
        "project_added",
        "host_observed",
        "task_created",
        "task_placed",
        "task_reassigned",
        "task_suspected",
        "task_quarantined",
        "fence_issued",
        "review_snapshot_recorded",
        "attempt_approved",
        "attempt_rejected",
        "merge_queue_transitioned",
    ]
}

@MainActor
final class ReviewBoardCoordinatorService: ObservableObject {
    static let shared = ReviewBoardCoordinatorService()

    @Published private(set) var snapshot = ReviewBoardSnapshot.empty
    /// Hosts the coordinator remembers, live or not. Empty whenever the
    /// integration is off, so every consumer degrades to peer-roster-only.
    @Published private(set) var knownHosts: [CoordinatorKnownHost] = []

    /// Projects whose leader the coordinator has been told about, by
    /// identity. This is the only path by which a leader on ANOTHER machine
    /// can ever be shown here — a peer's team state never crosses the wire.
    var leaderProjectIdentities: Set<PeerProjectIdentity> {
        var identities: Set<PeerProjectIdentity> = []
        for host in knownHosts {
            for root in host.leaderProjectRoots {
                let identity = projectIdentity(forWorkingDirectories: [root])
                if !identity.isUnknown { identities.insert(identity) }
            }
        }
        return identities
    }

    private var client: ReviewBoardCoordinatorClient?
    private var process: Process?
    private var refreshTask: Task<Void, Never>?
    private var eventRefreshWorkItem: DispatchWorkItem?
    private var subscriptionStarted = false
    private var hostObservationCancellable: AnyCancellable?
    private var hostSyncTask: Task<Void, Never>?
    private var lastReportedObservations: [CoordinatorHostObservation] = []

    func startIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        let gateOpen = ReviewBoardCoordinatorSettings.isIntegrationEnabled(
            environment: environment, defaults: defaults
        )
#if DEBUG
        dlog("coordinator.startIfNeeded gate=\(gateOpen)")
#endif
        guard gateOpen else {
            stop()
            return
        }
        let socketPath = ReviewBoardCoordinatorSettings.socketPath(environment: environment)
        if client == nil {
            client = ReviewBoardCoordinatorClient(socketPath: socketPath)
        }
        startProcessIfNeeded(socketPath: socketPath, environment: environment)
        refresh()
        startSubscriptionIfNeeded()
        startHostObservationIfNeeded()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        eventRefreshWorkItem?.cancel()
        eventRefreshWorkItem = nil
        hostObservationCancellable?.cancel()
        hostObservationCancellable = nil
        hostSyncTask?.cancel()
        hostSyncTask = nil
        lastReportedObservations = []
        knownHosts = []
        subscriptionStarted = false
        // The subscription loop outlives the reference: dropping the client is
        // not what ends it, telling it to stop is.
        client?.stopSubscribing()
        client = nil
        process?.terminate()
        process = nil
        snapshot = .empty
    }

    /// Mirror the peer roster into the coordinator. Nothing else populates it
    /// — the app is what watches the peers — so without this the coordinator
    /// runs with an empty host table and can answer no cross-host question.
    private func startHostObservationIfNeeded(
        store: RemoteHostStore = .shared
    ) {
        guard hostObservationCancellable == nil else { return }
        // Peer state is only half of it: creating a team moves a leader
        // without touching the peer roster at all, and that is exactly the
        // fact the coordinator exists to record.
        hostObservationCancellable = Publishers.Merge(
            store.objectWillChange.map { _ in () },
            TeamOrchestrator.shared.objectWillChange.map { _ in () }
        )
        // objectWillChange fires BEFORE the mutation lands, and both sides
        // churn in bursts (connect → roster → layout; team create → panes),
        // so settle first and then read; the debounce doubles as burst
        // coalescing.
        .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.syncHostObservations(store: store)
        }
        syncHostObservations(store: store)
    }

    func syncHostObservations(store: RemoteHostStore = .shared) {
        guard let client else {
#if DEBUG
            dlog("coordinator.syncHosts skipped: no client")
#endif
            return
        }
        // Every window contributes: a project can be open in one window while
        // its team leader sits in another.
        let workspaces = (AppDelegate.shared?.mainWindowContexts.values ?? [:].values)
            .flatMap(\.tabManager.tabs)
        let leaderWorkspaceIDs = Set(TeamOrchestrator.shared.teams.values.map {
            $0.leaderWorkspaceId ?? $0.workspaceId
        })
        let local = Self.localProjectState(
            workspaces: workspaces,
            leaderWorkspaceIDs: leaderWorkspaceIDs
        )
        let observations = Self.hostObservations(
            from: store.sortedHosts,
            localProjectRoots: local.roots,
            localLeaderProjectRoots: local.leaderRoots
        )
        // The coordinator dedupes by request_id anyway; skipping here saves
        // the round trip entirely when nothing about the peers changed.
        // Logging only real changes keeps peer churn from tripping the debug
        // log's rate breaker and burying what we came to read.
        guard observations != lastReportedObservations else { return }
#if DEBUG
        dlog("coordinator.syncHosts hosts=\(store.sortedHosts.count) observations=\(observations.count)")
#endif
        lastReportedObservations = observations
        hostSyncTask?.cancel()
        hostSyncTask = Task.detached { [weak self, client] in
            await client.observeHosts(observations)
            // Read our own writes back. The event subscription is meant to do
            // this, but relying on it alone left the sidebar showing a leader
            // the app itself had just reported — the write reached the
            // coordinator while this client's own knownHosts stayed stale. A
            // refresh right after the write closes that loop deterministically.
            await self?.refresh()
        }
    }

    /// This machine's project roots, and which of them hold a team leader.
    /// Peer mirrors are skipped for the same reason the sidebar skips them:
    /// they are a view onto someone else's workspace, and counting them would
    /// report a remote project as living here.
    static func localProjectState(
        workspaces: [Workspace],
        leaderWorkspaceIDs: Set<UUID>
    ) -> (roots: [String], leaderRoots: [String]) {
        var roots: Set<String> = []
        var leaderRoots: Set<String> = []

        for workspace in workspaces where !workspace.isPeerMirror {
            let directories = workspace.panelDirectories.values.filter { !$0.isEmpty }
            let candidates = directories.isEmpty
                ? [workspace.currentDirectory].filter { !$0.isEmpty }
                : Array(directories)
            let identity = projectIdentity(forWorkingDirectories: candidates)
            guard !identity.isUnknown, let root = candidates.first else { continue }
            roots.insert(root)
            if leaderWorkspaceIDs.contains(workspace.id) {
                leaderRoots.insert(root)
            }
        }
        return (Array(roots), Array(leaderRoots))
    }

    /// A project the coordinator remembers on a host that is NOT connected
    /// right now — the peer roster cannot produce these, since it only
    /// describes what is reachable this instant.
    struct RememberedProject: Equatable {
        let identity: PeerProjectIdentity
        let hostKey: String
        let hostDisplayName: String
        let projectRoot: String
        let observedAtMilliseconds: Double
    }

    /// Match remembered hosts back to sidebar entries. The coordinator stores
    /// a hashed host id, so the only way back to a name is to re-derive the
    /// hash from the hosts we know — which works for exactly the hosts still
    /// saved in the sidebar, and those are the ones a user can act on.
    static func rememberedProjects(
        knownHosts: [CoordinatorKnownHost],
        sidebarHosts: [HostEntry],
        liveIdentities: Set<PeerProjectIdentity>
    ) -> [RememberedProject] {
        var hostsByCoordinatorID: [String: HostEntry] = [:]
        for host in sidebarHosts {
            let id = CoordinatorHostObservation(
                hostKey: host.id, projectRoots: [], isLive: true
            ).coordinatorHostID
            hostsByCoordinatorID[id] = host
        }

        var seen: Set<PeerProjectIdentity> = liveIdentities
        var remembered: [RememberedProject] = []
        for known in knownHosts {
            guard let host = hostsByCoordinatorID[known.hostID] else { continue }
            // A connected host is already speaking for itself through the
            // roster; repeating it from memory would double every project.
            guard !host.isConnected else { continue }
            for root in known.projectRoots {
                let identity = projectIdentity(forWorkingDirectories: [root])
                guard !identity.isUnknown, !seen.contains(identity) else { continue }
                seen.insert(identity)
                remembered.append(RememberedProject(
                    identity: identity,
                    hostKey: host.id,
                    hostDisplayName: host.displayName,
                    projectRoot: root,
                    observedAtMilliseconds: known.observedAtMilliseconds
                ))
            }
        }
        return remembered.sorted {
            $0.identity.label.localizedCaseInsensitiveCompare($1.identity.label) == .orderedAscending
        }
    }

    /// Only connected hosts carry a workspace roster, so only they can report
    /// project roots; a saved-but-offline host would contribute an empty list
    /// that reads as "this machine has no projects" rather than "unknown".
    ///
    /// A peer's leaders come from its team roster (`team.roster.v1`), which
    /// is the only thing that can answer it — a team is not visible in the
    /// layout tree. Hosts that do not report one contribute no leaders rather
    /// than a guess.
    static func hostObservations(
        from hosts: [HostEntry],
        localProjectRoots: [String] = [],
        localLeaderProjectRoots: [String] = []
    ) -> [CoordinatorHostObservation] {
        var observations: [CoordinatorHostObservation] = []

        if !localProjectRoots.isEmpty {
            observations.append(CoordinatorHostObservation(
                hostKey: CoordinatorHostObservation.localHostKey,
                projectRoots: Array(Set(localProjectRoots)),
                leaderProjectRoots: Array(Set(localLeaderProjectRoots)),
                isLive: true
            ))
        }

        for host in hosts where host.isConnected {
            var roots: Set<String> = []
            for workspace in host.workspaces {
                for pane in workspace.panes {
                    if let root = pane.projectRootPath, !root.isEmpty {
                        roots.insert(root)
                    }
                }
            }
            // A team's own project root counts as hosted even when no pane
            // happens to sit in it right now — the leader is there either way,
            // and the coordinator rejects a leader outside project_roots.
            var leaderRoots: Set<String> = []
            for team in host.teams {
                guard let root = team.projectRootPath, !root.isEmpty else { continue }
                roots.insert(root)
                leaderRoots.insert(root)
            }
            observations.append(CoordinatorHostObservation(
                hostKey: host.id,
                projectRoots: Array(roots),
                leaderProjectRoots: Array(leaderRoots),
                isLive: true
            ))
        }
        return observations
    }

    func providerSnapshot() -> ReviewBoardSnapshot {
        let local = TeamDataStoreReviewBoardSnapshotProvider().snapshot()
        guard ReviewBoardCoordinatorSettings.isIntegrationEnabled() else { return local }
        guard snapshot.coordinatorOnline else {
            var offline = local
            offline.coordinatorOnline = false
            return offline
        }
        return snapshot
    }

    /// A coordinator we just spawned needs a moment before it binds, and one
    /// we are reusing may be mid-restart. Without a retry the very first
    /// failed read is final — the app reports "offline" forever while a
    /// perfectly healthy coordinator answers every other client.
    private static let onlineRetryDelays: [Double] = [0.3, 0.7, 1.5, 3.0]

    func refresh(attempt: Int = 0) {
        guard let client else { return }
        refreshTask?.cancel()
        refreshTask = Task.detached { [weak self, client] in
            let next: ReviewBoardSnapshot
            do {
                next = try await client.fetchSnapshot()
            } catch {
                next = ReviewBoardSnapshot(
                    tasks: [],
                    panelRuns: [],
                    coordinatorOnline: false,
                    memMeshAvailable: false,
                    suspectHost: false,
                    fencedZombie: false
                )
            }
            // Failing to read the host table is not a reason to forget it —
            // "last seen" is precisely what survives a coordinator hiccup.
            let hosts = (try? await client.fetchKnownHosts())
            let placementInputs = next.coordinatorOnline
                ? try? await client.fetchPlacementInputs()
                : nil
            await MainActor.run {
                self?.snapshot = next
                if let hosts { self?.knownHosts = hosts }
                NotificationCenter.default.post(name: .reviewBoardSnapshotDidChange, object: nil)
                if !next.coordinatorOnline, attempt < Self.onlineRetryDelays.count {
                    self?.scheduleOnlineRetry(attempt: attempt)
                }
            }
            // Every refresh re-reads what is placed and carries out whatever
            // has not been carried out yet. Riding the refresh rather than the
            // event stream is what makes a dropped frame or a reconnect cost
            // nothing: the next read sees the same placement still waiting.
            if let placementInputs {
                await self?.dispatchPlacements(placementInputs, client: client)
            }
        }
    }

    @MainActor
    private func dispatchPlacements(
        _ inputs: (rows: [[String: Any]], roots: [String: String]),
        client: ReviewBoardCoordinatorClient
    ) async {
        await CoordinatorPlacementDispatcher.shared.reconcile(
            taskRows: inputs.rows,
            projectRoots: inputs.roots,
            hostsByCoordinatorID: hostsByCoordinatorID(),
            localHostID: CoordinatorHostObservation(
                hostKey: CoordinatorHostObservation.localHostKey,
                projectRoots: [],
                isLive: true
            ).coordinatorHostID
        ) { placement, reason in
            RemoteWorkLog.info("Could not start \"\(placement.title)\": \(reason)")
            await client.reportPlacementFailure(
                taskID: placement.taskID,
                attemptID: placement.attemptID,
                reason: reason
            )
        }
    }

    /// Coordinator host ids are a hash of the sidebar's own host key, so the
    /// app can turn them back into the host it knows — the same reverse map
    /// the remembered-projects row uses.
    @MainActor
    private func hostsByCoordinatorID() -> [String: HostEntry] {
        var map: [String: HostEntry] = [:]
        for host in RemoteHostStore.shared.sortedHosts {
            let id = CoordinatorHostObservation(
                hostKey: host.id,
                projectRoots: [],
                isLive: host.isConnected
            ).coordinatorHostID
            map[id] = host
        }
        return map
    }

    private func scheduleOnlineRetry(attempt: Int) {
        let delay = Self.onlineRetryDelays[attempt]
#if DEBUG
        dlog("coordinator.refresh offline — retry \(attempt + 1) in \(delay)s")
#endif
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.client != nil else { return }
            self.refresh(attempt: attempt + 1)
            // A coordinator that came up late has host state to hear about.
            self.lastReportedObservations = []
            self.syncHostObservations()
        }
    }

    private func startSubscriptionIfNeeded() {
        guard !subscriptionStarted, let client else { return }
        subscriptionStarted = true
        client.subscribeEvents { [weak self] in
            Task { @MainActor in
                self?.scheduleEventRefresh()
            }
        }
    }

    private func scheduleEventRefresh() {
        eventRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        eventRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func startProcessIfNeeded(socketPath: String, environment: [String: String]) {
        if let process, process.isRunning { return }
        self.process = nil
        // Someone else's live coordinator (another window, a manual run) is
        // fine to reuse; a leftover socket file from a dead one is not, and
        // testing only for the file's existence strands the app forever on a
        // path nothing listens to.
        if ReviewBoardCoordinatorClient.isSocketAlive(socketPath) { return }
        try? FileManager.default.removeItem(atPath: socketPath)
        let binary = environment[ReviewBoardCoordinatorSettings.binaryPathEnvironmentKey] ?? "tm-coordinator"
        let process = Process()
        process.executableURL = binary.contains("/")
            ? URL(fileURLWithPath: binary)
            : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = binary.contains("/") ? [] : [binary]
        process.environment = ReviewBoardCoordinatorSettings.launchEnvironment(
            base: environment,
            socketPath: socketPath
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }
}

extension ReviewBoardCoordinatorService {
    /// Register the project if it is new, create the work, and ask for it to
    /// be placed — the three calls a person means by "delegate this".
    @MainActor
    func delegate(
        projectRoot: String,
        projectName: String,
        title: String,
        body: String
    ) async throws {
        guard let client else {
            throw ReviewBoardCoordinatorError.disabled
        }
        let projectID = try await client.ensureProject(rootPath: projectRoot, name: projectName)
        try await client.delegate(projectID: projectID, title: title, body: body)
        // Placement lands on the next read, and the board is what shows it.
        refresh()
    }
}

struct CoordinatorReviewBoardSnapshotProvider {
    @MainActor
    func snapshot() -> ReviewBoardSnapshot {
        ReviewBoardCoordinatorService.shared.providerSnapshot()
    }
}

/// One placement the coordinator decided and nobody has carried out yet.
struct CoordinatorPlacement: Equatable {
    let taskID: String
    let attemptID: String
    let hostID: String
    let agentName: String?
    let title: String
    let body: String

    /// A coordinator task row is a placement worth acting on only once it has
    /// been placed AND has an attempt to act under. An attempt id is what
    /// makes a dispatch identifiable, so without one there is nothing to
    /// avoid doing twice.
    let projectID: String

    init?(taskRow: [String: Any]) {
        guard let taskID = taskRow["task_id"] as? String,
              let projectID = taskRow["project_id"] as? String,
              taskRow["status"] as? String == "placed",
              let attemptID = taskRow["current_attempt_id"] as? String,
              let placement = taskRow["placement"] as? [String: Any],
              let hostID = placement["host_id"] as? String else {
            return nil
        }
        self.projectID = projectID
        self.taskID = taskID
        self.attemptID = attemptID
        self.hostID = hostID
        self.agentName = (placement["pane_ref"] as? [String: Any])?["agent_name"] as? String
        self.title = taskRow["title"] as? String ?? ""
        self.body = taskRow["body"] as? String ?? ""
    }
}

/// Carries the coordinator's placement decisions out to real panes.
///
/// The coordinator does not do this itself because it cannot: its whole
/// dependency list is sqlite, serde and tokio — it is a unix-socket *server*
/// that never dials anything. The app already holds every peer connection and
/// the local team dispatcher, so putting the actuator anywhere else would mean
/// building a second peer client next to the one that already exists.
///
/// Reconciliation is level-triggered on purpose. Acting on the event stream
/// alone would mean a dropped frame or a reconnect silently loses a placement
/// forever; instead every wake-up re-reads what is placed and acts on whatever
/// has not been acted on yet.
@MainActor
final class CoordinatorPlacementDispatcher {
    static let shared = CoordinatorPlacementDispatcher()

    /// Attempt ids already carried out, or being carried out right now. An
    /// attempt is the unit because the coordinator mints a fresh one per
    /// placement — a reassigned task is a new attempt and must dispatch again.
    private var handledAttempts: Set<String> = []

    /// The one thing here the product decides rather than the plumbing: what a
    /// placement actually asks for. Everything above and below this line —
    /// resolving the host, not repeating a dispatch, reporting a failure — is
    /// the same whatever the answer turns out to be.
    static func instruction(for placement: CoordinatorPlacement) -> String {
        placement.body.isEmpty
            ? placement.title
            : "\(placement.title)\n\n\(placement.body)"
    }

    func reconcile(
        taskRows: [[String: Any]],
        projectRoots: [String: String],
        hostsByCoordinatorID: [String: HostEntry],
        localHostID: String,
        report: @escaping (CoordinatorPlacement, String) async -> Void
    ) async {
        for placement in taskRows.compactMap(CoordinatorPlacement.init(taskRow:)) {
            guard !handledAttempts.contains(placement.attemptID) else { continue }
            handledAttempts.insert(placement.attemptID)

            guard let root = projectRoots[placement.projectID] else {
                await report(placement, "the coordinator has no root path for this project")
                continue
            }
            let project = projectIdentity(forWorkingDirectories: [root])
            let isLocal = placement.hostID == localHostID
            guard let teamName = teamName(
                forProject: project,
                host: isLocal ? nil : hostsByCoordinatorID[placement.hostID]
            ) else {
                await report(placement, "no team is running in \(project.label)")
                continue
            }
            if isLocal {
                let delivered = TeamOrchestrator.shared.sendToAgentAutoLocate(
                    teamName: teamName,
                    agentName: placement.agentName ?? "executor",
                    text: Self.instruction(for: placement)
                )
                if !delivered {
                    await report(placement, "local agent did not accept the instruction")
                }
                continue
            }
            guard let host = hostsByCoordinatorID[placement.hostID] else {
                // The coordinator remembers hosts this app has never connected
                // to. Saying so beats dispatching into nothing.
                await report(placement, "host is not connected to this app")
                continue
            }
            await dispatchToPeer(placement, host: host, teamName: teamName, report: report)
        }
    }

    /// The team a placement lands in. A placement names a host and an agent but
    /// never a team, so the team has to come from what is actually running —
    /// and the honest link is the project, which teams already report. A local
    /// team reports its `working_directory`; a peer team reports
    /// `project_root` over `team.roster.v1`. Both are put through the very
    /// same identity function the sidebar groups by, so a team lands in the
    /// project the user sees it under and nowhere else.
    private func teamName(
        forProject project: PeerProjectIdentity,
        host: HostEntry?
    ) -> String? {
        guard !project.isUnknown else { return nil }
        guard let host else {
            return TeamOrchestrator.shared.listTeams().first { team in
                guard let directory = team["working_directory"] as? String,
                      !directory.isEmpty else { return false }
                return projectIdentity(forWorkingDirectories: [directory]) == project
            }?["team_name"] as? String
        }
        return host.teams.first { team in
            let directories = [team.projectRootPath, team.workingDirectory]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            guard !directories.isEmpty else { return false }
            return projectIdentity(forWorkingDirectories: directories) == project
        }?.name
    }

    private func dispatchToPeer(
        _ placement: CoordinatorPlacement,
        host: HostEntry,
        teamName: String,
        report: @escaping (CoordinatorPlacement, String) async -> Void
    ) async {
        let path = host.activeSockPath
        guard !path.isEmpty else {
            await report(placement, "\(host.displayName) has no active connection")
            return
        }
        // `team.send`, not `team.delegate`. Delegate is a fan-out the app
        // composes out of several calls, so a headless host answers it with
        // `unsupported_on_host` — allowed, but not something it can do in one
        // operation. Send is the one primitive every host kind implements, and
        // carrying an instruction to a named agent is all this needs.
        //
        // Key names are the host's, not the CLI's: `team_name` / `agent_name`.
        let params: [String: Any] = [
            "team_name": teamName,
            "agent_name": placement.agentName ?? "executor",
            "text": Self.instruction(for: placement),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsJSON = String(data: data, encoding: .utf8) else {
            await report(placement, "could not encode the instruction")
            return
        }
        do {
            let conn = try await PeerRelaySession.connect(hostSockPath: path)
            defer { Task { await conn.cancel() } }
            let response = try await conn.session.callTeam(
                method: "team.send",
                paramsJSON: paramsJSON
            )
            if !response.ok {
                // A refusal is information, not a broken link — the host's own
                // wording is the most useful thing to pass on.
                await report(
                    placement,
                    "\(host.displayName) refused: \(response.errorCode) \(response.errorMessage)"
                )
            }
        } catch {
            await report(placement, "\(host.displayName): \(error.localizedDescription)")
        }
    }
}
