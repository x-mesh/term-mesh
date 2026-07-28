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

/// What an approval must repeat back to prove which tree it approved.
///
/// The coordinator stores no patch, so these three fields are the whole of
/// what "this is what I reviewed" means to it: change the worktree between
/// reading and approving and the evidence stops matching, and the approval is
/// refused rather than landing something nobody looked at.
struct ReviewBoardSnapshotEvidence: Equatable {
    let snapshotID: String
    let headSHA: String
    let diffDigest: String
    /// Not part of the evidence the coordinator re-checks — it validates
    /// `head_sha` and `diff_digest` only — but carried because a reader needs
    /// it to reproduce the diff.
    let baseSHA: String?
}

/// One task as a reviewer needs it: what to act on, what is already recorded,
/// and whether it has moved on already.
struct ReviewBoardReviewDetail: Equatable {
    let status: String?
    let attemptID: String?
    /// Read off the attempt, never minted. Issuing a fresh fence would take
    /// the token from whoever is running the attempt — the thing fencing
    /// exists to prevent.
    let fencingToken: String?
    let worktreePath: String?
    let hostID: String?
    let snapshot: ReviewBoardSnapshotEvidence?
    let queueID: String?
    let queueStatus: String?
    let queueLastError: String?

    /// Whether an approval could be attempted at all. A task that reached
    /// `review_ready` through the team-board mirror has no snapshot and no
    /// attempt, and the board has to say so rather than offer a button that
    /// cannot work.
    var isApprovable: Bool {
        status == "review_ready" && attemptID != nil && fencingToken != nil
    }
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

    func fetchSnapshot(names: CoordinatorDisplayNames = .empty) async throws -> ReviewBoardSnapshot {
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
        let reviewTasks = taskRows.compactMap {
            ReviewBoardTask(coordinatorDictionary: $0, names: names)
        }
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

    /// Project id to the name it was registered under.
    func fetchProjectNames() async throws -> [String: String] {
        let projects = (try await request(method: "project.list") as? [String: Any])?["projects"]
            as? [[String: Any]] ?? []
        var names: [String: String] = [:]
        for project in projects {
            guard let id = project["project_id"] as? String else { continue }
            // A project always has a root even when it was registered without
            // a name, and its folder is what the sidebar calls it.
            let name = (project["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (project["root_path"] as? String).map {
                    URL(fileURLWithPath: $0).lastPathComponent
                }
            names[id] = name ?? "Unknown project"
        }
        return names
    }

    /// Move a task along in the coordinator's own vocabulary. Idempotent on
    /// the attempt so a repeated report is the same event, not a second one.
    func reportPlacementStatus(
        taskID: String,
        attemptID: String,
        status: String,
        reason: String? = nil
    ) async {
        var params: [String: Any] = [
            "request_id": "dispatch-\(status):\(attemptID)",
            "task_id": taskID,
            "status": status,
        ]
        // What the agent said, carried with the status. A remote task has no
        // local team row to hold its result, so without this the board would
        // show it finish and still have nothing to show for it.
        if let reason, !reason.isEmpty { params["reason"] = reason }
        _ = try? await request(method: "task.update", params: params)
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
    /// `taskID` is the id this work already has on the team task board. The
    /// coordinator records placement against it instead of minting a second
    /// id, so there is one piece of work with one identity rather than two
    /// records whose statuses drift apart.
    func delegate(
        projectID: String,
        title: String,
        body: String,
        taskID: String? = nil
    ) async throws {
        let requestID = "delegate:\(UUID().uuidString)"
        var createParams: [String: Any] = [
            "request_id": "\(requestID):create",
            "project_id": projectID,
            "title": title,
            "body": body,
        ]
        if let taskID { createParams["task_id"] = taskID }
        let created = try await request(method: "task.create", params: createParams)
        guard let event = (created as? [String: Any])?["event"] as? [String: Any],
              let payload = event["payload"] as? [String: Any],
              let taskID = payload["task_id"] as? String else {
            throw ReviewBoardCoordinatorError.invalidResponse
        }
        try await place(taskID: taskID, requestID: "\(requestID):place")
    }

    /// Ask the coordinator to pick a host for a task that has none.
    ///
    /// Separate from `delegate` because placing is not a one-shot: it fails
    /// whenever no host has reported the project yet, and the machine that is
    /// about to run the work may only become eligible moments later — when the
    /// pane it opened turns up in the next host observation. The caller retries
    /// off the refresh loop.
    func place(taskID: String, requestID: String) async throws {
        _ = try await request(
            method: "task.place",
            params: ["request_id": requestID, "task_id": taskID]
        )
    }

    // MARK: - Reviewing a finished attempt

    /// Everything a reviewer needs about one task, from the one call that
    /// carries it.
    ///
    /// `task.get` returns the task, its attempts, the newest review snapshot
    /// and this task's merge-queue rows together, so a board can render a
    /// review and then act on it without a second round trip. The pieces are
    /// gathered here rather than handed out raw because three of them only
    /// mean anything together: an approval needs the attempt, the token that
    /// attempt is currently fenced with, and the snapshot whose evidence it
    /// must match.
    func reviewDetail(taskID: String) async throws -> ReviewBoardReviewDetail {
        let result = try await request(method: "task.get", params: ["task_id": taskID])
        guard let object = result as? [String: Any] else {
            throw ReviewBoardCoordinatorError.invalidResponse
        }
        let task = object["task"] as? [String: Any]
        let attemptID = task?["current_attempt_id"] as? String
        // The token is read off the attempt rather than minted: issuing a
        // fresh fence would take it from whoever is running the attempt.
        // That copy is only trustworthy because the reducer now updates it
        // with the fence (see `re_fencing_updates_the_token_that_task_get_reports`).
        let attempts = object["attempts"] as? [[String: Any]] ?? []
        let attempt = attempts.first { $0["attempt_id"] as? String == attemptID }
        var snapshot: ReviewBoardSnapshotEvidence?
        if let raw = object["latest_review_snapshot"] as? [String: Any],
           let id = raw["snapshot_id"] as? String,
           let head = raw["head_sha"] as? String,
           let digest = raw["diff_digest"] as? String {
            snapshot = ReviewBoardSnapshotEvidence(
                snapshotID: id,
                headSHA: head,
                diffDigest: digest,
                baseSHA: raw["base_sha"] as? String
            )
        }
        let queue = object["merge_queue"] as? [[String: Any]] ?? []
        return ReviewBoardReviewDetail(
            status: task?["status"] as? String,
            attemptID: attemptID,
            fencingToken: attempt?["fencing_token"] as? String,
            worktreePath: attempt?["worktree_path"] as? String,
            hostID: attempt?["host_id"] as? String,
            snapshot: snapshot,
            queueID: queue.last?["queue_id"] as? String,
            queueStatus: queue.last?["status"] as? String,
            queueLastError: queue.last?["last_error"] as? String
        )
    }

    /// Record what is being reviewed, and get back the id an approval cites.
    ///
    /// The coordinator stores no patch — by design (`mission-control-approval-queue`
    /// §v1) — so what it keeps is the pair of shas plus a digest, and an
    /// approval must repeat them exactly. That is what makes an approval refer
    /// to a specific state of the tree rather than to "the task": if the
    /// worktree moves between reading and approving, the evidence stops
    /// matching and the approval is refused instead of landing something
    /// nobody looked at.
    func recordReviewSnapshot(
        taskID: String,
        attemptID: String,
        fencingToken: String,
        baseSHA: String,
        headSHA: String,
        diffDigest: String,
        summary: String?,
        files: [[String: Any]]
    ) async throws -> ReviewBoardSnapshotEvidence {
        var params: [String: Any] = [
            // Derived from the evidence, not random: a retry of the same
            // snapshot is then idempotent, while a different tree state gets
            // its own id. The key is global to the coordinator, so it names
            // what it is.
            "request_id": "review.snapshot:\(taskID):\(attemptID):\(headSHA)",
            "task_id": taskID,
            "attempt_id": attemptID,
            "fencing_token": fencingToken,
            "base_sha": baseSHA,
            "head_sha": headSHA,
            "diff_digest": diffDigest,
        ]
        if let summary, !summary.isEmpty { params["summary"] = summary }
        if !files.isEmpty { params["files"] = files }
        let result = try await request(method: "review.snapshot", params: params)
        guard let payload = eventPayload(in: result),
              let snapshotID = payload["snapshot_id"] as? String else {
            throw ReviewBoardCoordinatorError.invalidResponse
        }
        return ReviewBoardSnapshotEvidence(
            snapshotID: snapshotID,
            headSHA: headSHA,
            diffDigest: diffDigest,
            baseSHA: baseSHA
        )
    }

    /// Approve an attempt and put it on the merge queue.
    ///
    /// Returns the queue id, because approving IS queueing — the coordinator
    /// moves the task to `queued_for_merge` and inserts the row in one step.
    /// Nothing is merged by this call.
    @discardableResult
    func approve(
        taskID: String,
        attemptID: String,
        fencingToken: String,
        reviewer: String,
        evidence: ReviewBoardSnapshotEvidence
    ) async throws -> String {
        let result = try await request(
            method: "approve",
            params: [
                // Naming the snapshot means a retry after a transport failure
                // returns the original approval rather than attempting a
                // second one — which would fail, since the task has already
                // left `review_ready`.
                "request_id": "approve:\(taskID):\(attemptID):\(evidence.snapshotID)",
                "task_id": taskID,
                "attempt_id": attemptID,
                "fencing_token": fencingToken,
                "reviewer": reviewer,
                "snapshot_id": evidence.snapshotID,
                "head_sha": evidence.headSHA,
                "diff_digest": evidence.diffDigest,
            ]
        )
        guard let payload = eventPayload(in: result),
              let item = payload["merge_queue_item"] as? [String: Any],
              let queueID = item["queue_id"] as? String else {
            throw ReviewBoardCoordinatorError.invalidResponse
        }
        return queueID
    }

    /// Send an attempt back with a reason.
    ///
    /// No snapshot is involved: rejecting does not need to prove what was
    /// looked at, only that the reviewer holds the current fence. The reason
    /// is required by the coordinator and is what the next attempt is briefed
    /// with, so an empty one is refused here rather than sent.
    func reject(
        taskID: String,
        attemptID: String,
        fencingToken: String,
        reviewer: String,
        reason: String
    ) async throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ReviewBoardCoordinatorError.jsonRPCError(
                code: nil,
                message: "A rejection needs a reason — it is what the next attempt is told."
            )
        }
        _ = try await request(
            method: "reject",
            params: [
                "request_id": "reject:\(taskID):\(attemptID)",
                "task_id": taskID,
                "attempt_id": attemptID,
                "fencing_token": fencingToken,
                "reviewer": reviewer,
                "reason": trimmed,
            ]
        )
    }

    /// Move a queued item along. The merge itself happens elsewhere; this
    /// records what happened to it.
    func transitionMergeQueue(
        queueID: String,
        status: String,
        lastError: String? = nil
    ) async throws {
        var params: [String: Any] = [
            "request_id": "merge.queue.transition:\(queueID):\(status)",
            "queue_id": queueID,
            "status": status,
        ]
        if let lastError, !lastError.isEmpty { params["last_error"] = lastError }
        _ = try await request(method: "merge.queue.transition", params: params)
    }

    /// Every mutating coordinator method answers with the same envelope.
    private func eventPayload(in result: Any) -> [String: Any]? {
        guard let object = result as? [String: Any],
              let event = object["event"] as? [String: Any] else { return nil }
        return event["payload"] as? [String: Any]
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
    private var hostObservationTicker: Timer?
    private var outstandingWorkTicker: Timer?

    /// Whether anything is still on its way to an answer. A board with nothing
    /// running costs one set comparison per tick and no socket traffic.
    private var hasOutstandingWork: Bool {
        snapshot.tasks.contains { Self.outstandingPhases.contains($0.status) }
    }

    private static let outstandingPhases: Set<String> = [
        "pending", "queued", "placed", "assigned", "in_progress", "reassigned",
    ]
    private var teamMirrorCancellable: AnyCancellable?
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
        startTeamMirrorIfNeeded()
    }

    /// Refresh when the team side moves, not only when the coordinator does.
    ///
    /// An agent finishing a task changes the team board and nothing else; the
    /// coordinator emits no event for it, so the read that would have carried
    /// the news back never happened and the coordinator sat on `in_progress`
    /// while the work was long done.
    private func startTeamMirrorIfNeeded() {
        guard teamMirrorCancellable == nil else { return }
        teamMirrorCancellable = TeamDataStore.shared.$taskRevision
            // Task changes arrive in bursts as an agent works through one.
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        eventRefreshWorkItem?.cancel()
        eventRefreshWorkItem = nil
        hostObservationCancellable?.cancel()
        hostObservationCancellable = nil
        hostObservationTicker?.invalidate()
        hostObservationTicker = nil
        outstandingWorkTicker?.invalidate()
        outstandingWorkTicker = nil
        teamMirrorCancellable?.cancel()
        teamMirrorCancellable = nil
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

        // This machine's project roots come from pane working directories,
        // which arrive from the shell a moment after launch — after the sync
        // above has already run and found nothing, and through a tab manager
        // that is per-window and so not in the merge. The app therefore stayed
        // invisible to its own coordinator until something unrelated happened
        // to churn one of the publishers above, and a delegation in that window
        // failed with "no eligible host".
        //
        // A tick rather than more subscriptions: the report is deduped against
        // the last one, so a quiet app pays for a comparison and nothing else,
        // and it cannot be defeated by picking the wrong publisher.
        hostObservationTicker?.invalidate()
        let ticker = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncHostObservations(store: store) }
        }
        RunLoop.main.add(ticker, forMode: .common)
        hostObservationTicker = ticker

        // Work running on a peer finishes silently. Nothing on that machine can
        // tell this one it is done — the dispatch is a `team.send`, not a task
        // the host tracks — so the answer has to be asked for, and asking once
        // right after handing the work over is asking before there is one.
        //
        // The refresh loop that reads results only ran when the host table
        // changed, so a delegation to a peer got exactly that single early
        // look and then nothing: the agent replied seconds later to no one.
        // While work is outstanding, keep asking.
        outstandingWorkTicker?.invalidate()
        let pump = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasOutstandingWork else { return }
                self.refresh()
            }
        }
        RunLoop.main.add(pump, forMode: .common)
        outstandingWorkTicker = pump
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

    /// What the panes are doing, plus whatever only the coordinator knows.
    ///
    /// This used to *replace* the local view with the coordinator's, so
    /// turning the coordinator on made the board stop showing the work
    /// happening in front of you — a leader delegating locally produced
    /// nothing on the board at all. The teams are the subject; the coordinator
    /// is a second source about the same subject, not a different one.
    func providerSnapshot() -> ReviewBoardSnapshot {
        let local = TeamDataStoreReviewBoardSnapshotProvider().snapshot()
        guard ReviewBoardCoordinatorSettings.isIntegrationEnabled() else { return local }
        var merged = local
        merged.coordinatorOnline = snapshot.coordinatorOnline
        guard snapshot.coordinatorOnline else { return merged }
        // Both sides now key on the same id, so a task either side knows about
        // is the same work rather than a second copy of it. Where both speak,
        // their accounts are merged into one row; where only the coordinator
        // does, the work is running on another machine and is added as is.
        var byID: [String: ReviewBoardTask] = [:]
        for task in snapshot.tasks { byID[task.rawID] = task }
        merged.tasks = local.tasks.map { task in
            byID.removeValue(forKey: task.rawID).map(task.merging(coordinator:)) ?? task
        }
        merged.tasks += byID.values
        merged.mergeQueue = snapshot.mergeQueue
        merged.memMeshAvailable = snapshot.memMeshAvailable
        merged.suspectHost = local.suspectHost || snapshot.suspectHost
        merged.fencedZombie = local.fencedZombie || snapshot.fencedZombie
        if merged.panelRuns.isEmpty { merged.panelRuns = snapshot.panelRuns }
        return merged
    }

    /// A coordinator we just spawned needs a moment before it binds, and one
    /// we are reusing may be mid-restart. Without a retry the very first
    /// failed read is final — the app reports "offline" forever while a
    /// perfectly healthy coordinator answers every other client.
    private static let onlineRetryDelays: [Double] = [0.3, 0.7, 1.5, 3.0]

    /// Give every task still waiting for a host another chance at one.
    ///
    /// Delegating places the task immediately, and at that moment the machine
    /// that is about to do the work may not be a candidate yet: it becomes
    /// eligible when the pane it just opened shows up in a host observation,
    /// which is a couple of seconds behind. That single attempt used to be the
    /// only one, so a task that lost the race sat at `pending` forever — no
    /// host, no reason, no retry, while the agent beside it finished the job.
    /// Placement is idempotent (the coordinator rejects the transition once a
    /// task is placed), so re-offering costs a local socket call and converges
    /// as soon as any host can take it.
    private static func placeUnplacedTasks(
        _ rows: [[String: Any]],
        client: ReviewBoardCoordinatorClient
    ) async {
        for row in rows {
            guard row["status"] as? String == "pending",
                  let taskID = row["task_id"] as? String else { continue }
            do {
                try await client.place(taskID: taskID, requestID: "reconcile:place:\(taskID)")
            } catch {
                // Expected while no host reports the project. The next refresh
                // asks again; there is nothing to do until one does.
                continue
            }
        }
    }

    func refresh(attempt: Int = 0) {
        guard let client else { return }
        // Resolved on the main actor before the read, because the host names
        // come from the sidebar's own store.
        let hostNames = hostsByCoordinatorID().mapValues(\.displayName)
        refreshTask?.cancel()
        refreshTask = Task.detached { [weak self, client] in
            let projectNames = (try? await client.fetchProjectNames()) ?? [:]
            let names = CoordinatorDisplayNames(projects: projectNames, hosts: hostNames)
            let next: ReviewBoardSnapshot
            do {
                next = try await client.fetchSnapshot(names: names)
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
                await Self.placeUnplacedTasks(placementInputs.rows, client: client)
                await self?.dispatchPlacements(placementInputs, client: client)
            }
        }
    }

    /// What a team status means in the coordinator's vocabulary.
    ///
    /// There is no `completed`: the coordinator's shape is work, then a review
    /// snapshot, then approval, then merge. So an agent finishing lands on
    /// `review_ready` — the work is done and waiting on a person, which is
    /// exactly what a finished team task means.
    private static let coordinatorStatusForTeamStatus: [String: String] = [
        "in_progress": "in_progress",
        "completed": "review_ready",
        "done": "review_ready",
        "review": "review_ready",
        "review_ready": "review_ready",
        "failed": "failed",
        "blocked": "blocked",
        "cancelled": "cancelled",
        "abandoned": "cancelled",
    ]

    /// Carry the team's account of a task forward to the coordinator.
    ///
    /// The agent moves the task on the team board — starts it, blocks it,
    /// finishes it — and the coordinator, which decided where it should run,
    /// would otherwise never hear how it went. Now that both sides key on the
    /// same id, saying so is a lookup rather than a guess.
    @MainActor
    private func mirrorTeamStatuses(
        coordinatorRows: [[String: Any]],
        client: ReviewBoardCoordinatorClient
    ) async {
        var coordinatorStatus: [String: String] = [:]
        for row in coordinatorRows {
            guard let id = row["task_id"] as? String,
                  let status = row["status"] as? String else { continue }
            coordinatorStatus[id] = status
        }
        guard !coordinatorStatus.isEmpty else { return }

        for team in TeamOrchestrator.shared.listTeams() {
            guard let name = team["team_name"] as? String else { continue }
            for task in TeamDataStore.shared.listTasks(teamName: name) {
                guard let current = coordinatorStatus[task.id],
                      let wanted = Self.coordinatorStatusForTeamStatus[task.status],
                      wanted != current else { continue }
                // The coordinator checks the transition itself and refuses an
                // illegal one, so this only has to avoid repeating itself.
                await client.reportPlacementStatus(
                    taskID: task.id,
                    attemptID: "\(task.id):\(wanted)",
                    status: wanted
                )
            }
        }
    }

    @MainActor
    private func dispatchPlacements(
        _ inputs: (rows: [[String: Any]], roots: [String: String]),
        client: ReviewBoardCoordinatorClient
    ) async {
        await mirrorTeamStatuses(coordinatorRows: inputs.rows, client: client)
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
        } started: { placement in
            await client.reportPlacementStatus(
                taskID: placement.taskID,
                attemptID: placement.attemptID,
                status: "in_progress"
            )
        }
        // Work sent to a peer has no way of telling us it finished, so the
        // same pass that hands work out also asks after the work already out
        // there.
        await CoordinatorPlacementDispatcher.shared.collectRemoteResults(
            taskRows: inputs.rows,
            projectRoots: inputs.roots,
            hostsByCoordinatorID: hostsByCoordinatorID(),
            localHostID: CoordinatorHostObservation(
                hostKey: CoordinatorHostObservation.localHostKey,
                projectRoots: [],
                isLive: true
            ).coordinatorHostID
        ) { taskID, attemptID, summary in
            await client.reportPlacementStatus(
                taskID: taskID,
                attemptID: attemptID,
                status: "review_ready",
                reason: summary
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

        // Hand the work to the team first. That is what makes it real: the
        // team task is what the agent starts, reports against and finishes,
        // and the capsule that goes with it carries the reply protocol. The
        // coordinator then records placement against that same id rather than
        // opening a second file on the same job.
        let project = projectIdentity(forWorkingDirectories: [projectRoot])
        let handed = await handToTeam(project: project, root: projectRoot, title: title, body: body)

        try await client.delegate(
            projectID: projectID,
            title: title,
            body: body,
            taskID: handed?.taskID
        )
        if let handed, handed.delivered {
            // The agent already has it, so the dispatcher must not send it a
            // second time — it only acts on work still sitting at `placed`.
            await client.reportPlacementStatus(
                taskID: handed.taskID,
                attemptID: handed.taskID,
                status: "in_progress"
            )
        }
        // Placement lands on the next read, and the board is what shows it.
        refresh()
    }

    /// Create (or find) the project's team, delegate through it, and return the
    /// task id the team minted. Returns nil when no team can be started here —
    /// the coordinator still records the work, and the dispatcher will report
    /// why nothing picked it up.
    @MainActor
    private func handToTeam(
        project: PeerProjectIdentity,
        root: String,
        title: String,
        body: String
    ) async -> (taskID: String, delivered: Bool)? {
        guard !project.isUnknown else { return nil }
        // Only take work this machine actually holds. A project root that lives
        // on a peer does not exist here, and starting a team in it anyway gave
        // the pane no directory to open — so it fell back to whatever the app's
        // own working directory was. The agent then answered confidently about
        // the wrong repository and the board showed that as completed: asked
        // for the first line of a README on jw-server, it returned the first
        // line of a README on this Mac.
        //
        // Declining is what lets the rest work. The coordinator has already
        // been told about the project, so it places the task on a host that
        // does have it and the dispatcher carries it there.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else {
#if DEBUG
            dlog("coordinator.handToTeam declined: \(root) is not on this machine")
#endif
            return nil
        }
        let dispatcher = CoordinatorPlacementDispatcher.shared
        let existing = dispatcher.teamName(forProject: project, host: nil)
        guard let team = existing
            ?? dispatcher.createTeam(forProject: project, root: root) else { return nil }
        // A team that was just created is only its leader; the delegation
        // needs an agent to land on.
        var spawnedNow = false
        if TeamOrchestrator.shared.teams[team]?.agents.isEmpty ?? true {
            _ = TeamOrchestrator.shared.addAgentToTeam(
                teamName: team,
                agentType: "executor",
                agentName: "executor",
                agentModel: "sonnet",
                agentCli: "claude"
            )
            spawnedNow = true
        }
        // A pane that was spawned a moment ago is still starting its CLI, and
        // text that arrives during the boot lands in the composer while the
        // Return is swallowed by whatever is on screen at the time. The
        // capsule then sits at the prompt unsent: the agent never begins, the
        // task stays `assigned` forever, and the only STATUS lines in the
        // scrollback are the capsule's own echo. Wait for the pane to print —
        // that is the CLI coming up — before handing it anything.
        if spawnedNow {
            await waitForAgentPaneToStart(teamName: team, agentName: "executor")
        }
        guard let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: team)
            ?? TerminalController.shared.tabManager else { return nil }
        let instruction = body.isEmpty ? title : "\(title)\n\n\(body)"
        guard let result = TeamOrchestrator.shared.delegateToAgent(
            teamName: team,
            agentName: "executor",
            text: instruction,
            taskTitle: title,
            tabManager: tabManager,
            // `submit: false` is for the CLI, which sends Return itself once
            // the paste is acknowledged. Nothing does that for an in-app
            // caller, so the capsule sat in the prompt unsent.
            submit: true
        ) else { return nil }
        return (result.task.id, result.textDelivered)
    }

    /// Give a freshly spawned agent pane time to bring its CLI up.
    ///
    /// Readiness is read from the pane rather than assumed from a fixed sleep:
    /// the poller already watches every agent pane, and a pane that has
    /// printed is a CLI that has started. The settle afterwards covers the gap
    /// between the first frame and a composer that accepts a submit.
    @MainActor
    private func waitForAgentPaneToStart(
        teamName: String,
        agentName: String,
        timeout: TimeInterval = 20
    ) async {
        AutoReplyPoller.shared.ensureRunning()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let panelID = TeamOrchestrator.shared.teams[teamName]?
                .agents.first(where: { $0.name == agentName })?.panelId,
               AutoReplyPoller.shared.isPaneActive(panelId: panelID) {
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
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
    /// Attempts whose remote result has already been carried back, so a
    /// finished task is reported once rather than on every refresh.
    private var collectedAttempts: Set<String> = []

    /// The one thing here the product decides rather than the plumbing: what a
    /// placement actually asks for. Everything above and below this line —
    /// resolving the host, not repeating a dispatch, reporting a failure — is
    /// the same whatever the answer turns out to be.
    ///
    /// The reporting header goes with it. A local delegation gets the capsule
    /// from `formatDelegateInstruction`; a remote one came through here with
    /// the bare title, so the peer agent answered in prose — "3" — with no
    /// STATUS line for the host's auto-reply to catch, and the task sat at
    /// `in_progress` while the work was long done. The remote agent needs the
    /// same contract as the local one, and this is the only place that speaks
    /// to it.
    static func instruction(for placement: CoordinatorPlacement) -> String {
        let ask = placement.body.isEmpty
            ? placement.title
            : "\(placement.title)\n\n\(placement.body)"
        return """
        \(ask)

        [HOW TO REPORT — required]
        Close your reply with these lines so the task is recorded as done;
        without them it stays open.

        STATUS: DONE|BLOCKED|NEEDS_REVIEW
        FILES: <changed paths, space-separated, or none>
        VERIFY: <single shell command to verify the result, or n/a>
        NEXT: <one-line action for the leader, or NONE>
        FULL_REPORT: <path to a full result file, or n/a>

        Then one last line: the answer or outcome in a sentence, after the
        header — text above STATUS is not captured.
        """
    }

    func reconcile(
        taskRows: [[String: Any]],
        projectRoots: [String: String],
        hostsByCoordinatorID: [String: HostEntry],
        localHostID: String,
        report: @escaping (CoordinatorPlacement, String) async -> Void,
        started: @escaping (CoordinatorPlacement) async -> Void = { _ in }
    ) async {
        // A task the team board already holds was delivered by whoever put it
        // there; the coordinator's copy going through `placed` is bookkeeping,
        // not a second request. Without this the dispatcher raced the delegate
        // path and sent the same work twice — once as a capsule, once as bare
        // text — and the bare one won because it was the one that submitted.
        let alreadyWithATeam = Set(
            TeamOrchestrator.shared.listTeams()
                .compactMap { $0["team_name"] as? String }
                .flatMap { TeamDataStore.shared.listTasks(teamName: $0) }
                .map(\.id)
        )
        for placement in taskRows.compactMap(CoordinatorPlacement.init(taskRow:)) {
            guard !handledAttempts.contains(placement.attemptID) else { continue }
            guard !alreadyWithATeam.contains(placement.taskID) else {
                handledAttempts.insert(placement.attemptID)
                continue
            }
            handledAttempts.insert(placement.attemptID)

            guard let root = projectRoots[placement.projectID] else {
                await report(placement, "the coordinator has no root path for this project")
                continue
            }
            let project = projectIdentity(forWorkingDirectories: [root])
            let isLocal = placement.hostID == localHostID
            var resolvedTeam = teamName(
                forProject: project,
                host: isLocal ? nil : hostsByCoordinatorID[placement.hostID]
            )
            // No team yet, and the work is for this machine: make one. The
            // point of this whole path is that a person can watch an agent
            // work in a pane — reporting "no team is running" instead leaves
            // them with a status string and nothing to look at, which is the
            // opposite of what the terminal is for.
            //
            // Only locally. Creating a team spawns processes in a working
            // directory, and the peer allow-list refuses that on purpose;
            // a remote project without a team is told so, not worked around.
            if resolvedTeam == nil, isLocal {
                resolvedTeam = createTeam(forProject: project, root: root)
            }
            guard let teamName = resolvedTeam else {
                await report(
                    placement,
                    isLocal
                        ? "could not start a team in \(project.label)"
                        : "no team is running in \(project.label) on that host — create one there first"
                )
                continue
            }
            if isLocal {
                let delivered = await deliverLocally(
                    teamName: teamName,
                    agentName: placement.agentName ?? "executor",
                    text: Self.instruction(for: placement)
                )
                if delivered {
                    // The agent has the work. Saying so is the difference
                    // between a board that tracks progress and one that shows
                    // the same word from hand-off to finish.
                    await started(placement)
                } else {
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
            await dispatchToPeer(
                placement,
                host: host,
                teamName: teamName,
                report: report,
                started: started
            )
        }
    }

    /// Ask the peers whether the work they were handed is finished.
    ///
    /// Dispatching to a peer said `in_progress` and then stopped asking. The
    /// remote agent did the job, printed the reply header and went idle, and
    /// the task stayed `in_progress` forever — the work was done and the only
    /// place that said so was a machine nobody was looking at.
    ///
    /// Nothing pushes that back: the host has no task of its own to complete
    /// (the dispatch is a `team.send`, not a task), and there is no event
    /// channel from a peer's agents to this coordinator. So the answer is read
    /// rather than awaited, on the same refresh that dispatches — one
    /// `team.read` per outstanding remote task.
    func collectRemoteResults(
        taskRows: [[String: Any]],
        projectRoots: [String: String],
        hostsByCoordinatorID: [String: HostEntry],
        localHostID: String,
        finished: @escaping (_ taskID: String, _ attemptID: String, _ summary: String?) async -> Void
    ) async {
        for row in taskRows {
            guard row["status"] as? String == "in_progress",
                  let taskID = row["task_id"] as? String,
                  let attemptID = row["current_attempt_id"] as? String,
                  let projectID = row["project_id"] as? String,
                  let placement = row["placement"] as? [String: Any],
                  let hostID = placement["host_id"] as? String,
                  hostID != localHostID,
                  let host = hostsByCoordinatorID[hostID],
                  let root = projectRoots[projectID] else { continue }
            // Already reported once; the coordinator has moved on.
            guard !collectedAttempts.contains(attemptID) else { continue }
            let project = projectIdentity(forWorkingDirectories: [root])
            guard let teamName = teamName(forProject: project, host: host) else { continue }
            let agentName = (placement["pane_ref"] as? [String: Any])?["agent_name"] as? String
                ?? "executor"
            guard let text = await readFromPeer(
                host: host, teamName: teamName, agentName: agentName
            ) else { continue }
            guard let report = ReviewBoardAgentReport(result: text), report.status != nil else {
                continue
            }
            collectedAttempts.insert(attemptID)
            await finished(
                taskID,
                attemptID,
                Self.summary(fromRemoteReply: text) ?? report.body ?? report.status
            )
        }
    }

    /// Read one remote agent's recent output.
    ///
    /// A headless host answers in stream-json — one JSON object per line — so
    /// the agent's own words have to be dug out of it. Lines that are not
    /// stream-json are passed through as-is, which is what a host backed by
    /// panes returns.
    private func readFromPeer(
        host: HostEntry,
        teamName: String,
        agentName: String
    ) async -> String? {
        let path = host.activeSockPath
        guard !path.isEmpty else { return nil }
        let params: [String: Any] = [
            "team_name": teamName,
            "agent_name": agentName,
            "lines": 200,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsJSON = String(data: data, encoding: .utf8) else { return nil }
        do {
            let conn = try await PeerRelaySession.connect(hostSockPath: path)
            defer { Task { await conn.cancel() } }
            let response = try await conn.session.callTeam(
                method: "team.read",
                paramsJSON: paramsJSON
            )
            guard response.ok,
                  let resultData = response.resultJson.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  let lines = result["lines"] as? [String] else { return nil }
            return Self.plainText(fromHostOutput: lines)
        } catch {
            return nil
        }
    }

    /// What a remote agent said, minus the header it was asked to end with.
    ///
    /// A local reply is read off a screen, so only the lines below the header
    /// can be trusted to be the agent's — above it is scrollback. A remote one
    /// arrives as the agent's own turn, nothing else in it, so text on either
    /// side of the header is the answer. That matters because agents put the
    /// answer first however the instruction is worded: asked to count lines,
    /// this one replied "3" and then the header, and taking only what followed
    /// left the board reporting the word DONE.
    static func summary(fromRemoteReply text: String) -> String? {
        let headers = ["STATUS:", "FILES:", "VERIFY:", "NEXT:", "FULL_REPORT:"]
        let kept = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !headers.contains(where: { line.hasPrefix($0) })
            }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    /// The agent's text, out of whatever the host reports.
    static func plainText(fromHostOutput lines: [String]) -> String {
        var out: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                out.append(line)
                continue
            }
            // Claude's stream-json: only assistant turns carry the reply.
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "text" {
                if let text = part["text"] as? String { out.append(text) }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Hand the instruction to a local agent and wait for the answer that
    /// actually means something.
    ///
    /// The synchronous return of a send is not that answer: a pane still
    /// spawning fails the first attempt and the send retries behind the
    /// scenes, so the immediate `false` says "not yet", not "no". Reporting it
    /// as failure marked work suspect that was about to run — and did run,
    /// while the board said it had not started.
    private func deliverLocally(teamName: String, agentName: String, text: String) async -> Bool {
        guard let tabManager = TeamOrchestrator.shared.resolveTabManager(teamName: teamName)
            ?? TerminalController.shared.tabManager else { return false }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (Bool) -> Void = { delivered in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: delivered)
            }
            // The retry ladder inside the send is bounded, but nothing here
            // should hang on it for ever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(false) }
            _ = TeamOrchestrator.shared.sendToAgent(
                teamName: teamName,
                agentName: agentName,
                text: text,
                tabManager: tabManager,
                completion: finish
            )
        }
    }

    /// Start a team in the project so there is a pane to watch. One executor,
    /// because the placement asks for one piece of work — more agents is a
    /// choice for the person to make afterwards, not something delegation
    /// should decide on their behalf.
    func createTeam(forProject project: PeerProjectIdentity, root: String) -> String? {
        guard let tabManager = TerminalController.shared.tabManager else { return nil }
        let name = teamNameCandidate(for: project)
        let team = TeamOrchestrator.shared.createTeam(
            name: name,
            agents: [(
                name: "executor",
                cli: "claude",
                model: "sonnet",
                agentType: "executor",
                color: "",
                instructions: "",
                customInstructions: ""
            )],
            workingDirectory: root,
            leaderSessionId: UUID().uuidString,
            tabManager: tabManager
        )
        if team != nil {
            RemoteWorkLog.info("Started team \(name) in \(project.label) to run delegated work")
        }
        return team.map { _ in name }
    }

    /// Team names are an identifier elsewhere in the app, so keep it to what a
    /// team name is allowed to be, and keep it recognisably the project's.
    func teamNameCandidate(for project: PeerProjectIdentity) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = String(
            project.label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
        .lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "project" : slug
        let existing = Set(
            TeamOrchestrator.shared.listTeams().compactMap { $0["team_name"] as? String }
        )
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// The team a placement lands in. A placement names a host and an agent but
    /// never a team, so the team has to come from what is actually running —
    /// and the honest link is the project, which teams already report. A local
    /// team reports its `working_directory`; a peer team reports
    /// `project_root` over `team.roster.v1`. Both are put through the very
    /// same identity function the sidebar groups by, so a team lands in the
    /// project the user sees it under and nowhere else.
    func teamName(
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
        report: @escaping (CoordinatorPlacement, String) async -> Void,
        started: @escaping (CoordinatorPlacement) async -> Void
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
            if response.ok {
                await started(placement)
            } else {
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

// MARK: - Reviewing a task

/// One task, read and ready to act on.
///
/// The pieces only mean something together: the coordinator's view of the
/// attempt (what an approval must cite) and the patch read out of the working
/// tree (what a person actually looks at). `blocker` is the honest answer when
/// they cannot be assembled — a board that offers a button it knows cannot
/// work is worse than one that says why.
struct ReviewBoardReview: Equatable {
    let taskID: String
    let detail: ReviewBoardReviewDetail
    let patch: ReviewBoardEvidence.Patch?
    let blocker: String?

    var canAct: Bool { blocker == nil && detail.isApprovable }
}

extension ReviewBoardCoordinatorService {

    /// Gather everything a review needs, or say why it cannot be gathered.
    ///
    /// Reads the coordinator first because it decides whether an approval is
    /// possible at all, and only then goes to the filesystem: there is no
    /// point running git for a task whose `review_ready` came from the
    /// team-board mirror, which records no attempt and no snapshot.
    func review(task: ReviewBoardTask) async -> ReviewBoardReview {
        guard let client else {
            return ReviewBoardReview(
                taskID: task.rawID,
                detail: .unavailable,
                patch: nil,
                blocker: "The coordinator is off, so nothing can be approved from here."
            )
        }
        let detail: ReviewBoardReviewDetail
        do {
            detail = try await client.reviewDetail(taskID: task.rawID)
        } catch {
            return ReviewBoardReview(
                taskID: task.rawID,
                detail: .unavailable,
                patch: nil,
                blocker: "Could not read the task: \(error.localizedDescription)"
            )
        }
        guard detail.isApprovable else {
            return ReviewBoardReview(
                taskID: task.rawID, detail: detail, patch: nil,
                blocker: detail.attemptID == nil
                    // The mirror path: `task.update` moved it to review_ready
                    // without placing an attempt, so there is nothing to
                    // approve even though the board says it is ready.
                    ? "This task has no coordinator attempt — it was marked ready by the team board, which records nothing to approve."
                    : "This task is \(detail.status ?? "not ready") rather than review_ready."
            )
        }
        // The attempt's own worktree first: it is the one the coordinator
        // placed. The team-board row is the fallback for work the board knows
        // about by the other route.
        guard let worktree = detail.worktreePath ?? task.worktreePath else {
            return ReviewBoardReview(
                taskID: task.rawID, detail: detail, patch: nil,
                blocker: "This attempt records no worktree, so there is no change to read."
            )
        }
        do {
            let patch = try await ReviewBoardEvidence.read(
                worktreePath: worktree,
                parentRef: task.worktreeParent
            )
            return ReviewBoardReview(
                taskID: task.rawID, detail: detail, patch: patch,
                blocker: patch.isEmpty ? "The worktree has no changes against its parent." : nil
            )
        } catch ReviewBoardEvidenceError.unknownBase {
            return ReviewBoardReview(
                taskID: task.rawID, detail: detail, patch: nil,
                blocker: "The task records no parent branch, so there is nothing to diff against."
            )
        } catch {
            return ReviewBoardReview(
                taskID: task.rawID, detail: detail, patch: nil,
                blocker: "Could not read the worktree: \(error.localizedDescription)"
            )
        }
    }

    /// Approve what was read.
    ///
    /// A snapshot is recorded from the patch in hand rather than reusing
    /// whatever the coordinator last stored: approving against a stale
    /// snapshot would either be refused as an evidence mismatch or — worse, if
    /// it happened to match — land a tree nobody looked at. Recording is
    /// idempotent for the same head, so re-approving the same review costs
    /// nothing.
    func approve(_ review: ReviewBoardReview, reviewer: String, summary: String? = nil) async throws {
        guard let client else { throw ReviewBoardCoordinatorError.disabled }
        let (attemptID, token, patch) = try requireActionable(review)
        let evidence = try await client.recordReviewSnapshot(
            taskID: review.taskID,
            attemptID: attemptID,
            fencingToken: token,
            baseSHA: patch.baseSHA,
            headSHA: patch.headSHA,
            diffDigest: patch.digest,
            summary: summary,
            files: patch.files.map(\.rpcValue)
        )
        _ = try await client.approve(
            taskID: review.taskID,
            attemptID: attemptID,
            fencingToken: token,
            reviewer: reviewer,
            evidence: evidence
        )
        refresh()
    }

    /// Send it back. No snapshot: rejecting does not have to prove what was
    /// read, only that the reviewer holds the current fence.
    func reject(_ review: ReviewBoardReview, reviewer: String, reason: String) async throws {
        guard let client else { throw ReviewBoardCoordinatorError.disabled }
        guard let attemptID = review.detail.attemptID,
              let token = review.detail.fencingToken else {
            throw ReviewBoardCoordinatorError.invalidResponse
        }
        try await client.reject(
            taskID: review.taskID,
            attemptID: attemptID,
            fencingToken: token,
            reviewer: reviewer,
            reason: reason
        )
        refresh()
    }

    /// Record what became of a queued merge.
    ///
    /// The merge runs elsewhere; this is only the report. It refreshes because
    /// the board's queue list is what a person watches to know whether the
    /// merge they approved actually landed.
    func transitionMergeQueue(
        queueID: String,
        status: String,
        lastError: String? = nil
    ) async throws {
        guard let client else { throw ReviewBoardCoordinatorError.disabled }
        try await client.transitionMergeQueue(
            queueID: queueID, status: status, lastError: lastError
        )
        refresh()
    }

    private func requireActionable(
        _ review: ReviewBoardReview
    ) throws -> (attemptID: String, token: String, patch: ReviewBoardEvidence.Patch) {
        guard let attemptID = review.detail.attemptID,
              let token = review.detail.fencingToken,
              let patch = review.patch else {
            throw ReviewBoardCoordinatorError.jsonRPCError(
                code: nil,
                message: review.blocker ?? "This task cannot be approved from here."
            )
        }
        return (attemptID, token, patch)
    }
}

extension ReviewBoardReviewDetail {
    /// Nothing known — the shape a review takes when the coordinator could not
    /// be asked at all.
    static let unavailable = ReviewBoardReviewDetail(
        status: nil, attemptID: nil, fencingToken: nil,
        worktreePath: nil, hostID: nil, snapshot: nil,
        queueID: nil, queueStatus: nil, queueLastError: nil
    )
}
