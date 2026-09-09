import CryptoKit
import Darwin
import Foundation

/// Append-only leader turn measurements shared by the app and CLI.
enum LeaderTurnLog {
    private static let identityLock = NSLock()
    private static var knownIdentities: [String: (teamUUID: String, leaderSessionID: String?)] = [:]

    /// Delegation-intensity order matching `ProjectRoutingRoute` in LeaderParallelPolicy.swift.
    /// Unknown route strings are absent and excluded from direction comparisons.
    private static let routeDelegationRank: [String: Int] = [
        "direct": 0,
        "probe": 1,
        "delegated": 2,
        "parallel": 3,
    ]

    enum MeasurementCapability: String, Codable, CaseIterable {
        case supported
        case unsupported
        case degraded
    }

    struct Health: Equatable {
        let supportedTurns: Int
        let linkedTurns: Int
        let statedTurns: Int
        let unstatedTurns: Int
        let unsupportedTurns: Int
        let degradedTurns: Int
        let malformedLines: Int
        let observedDays: Int

        var coverage: Double {
            supportedTurns == 0 ? 0 : Double(statedTurns + unstatedTurns) / Double(supportedTurns)
        }

        var linkage: Double {
            supportedTurns == 0 ? 0 : Double(linkedTurns) / Double(supportedTurns)
        }
    }

    struct PolicyReport: Equatable {
        let cohortCounts: [String: Int]
        let appliedTurns: Int
        let suggestedTurns: Int
        let routeDeviations: Int
        /// Deviations where the leader delegated more than the policy suggested (direct < probe < delegated < parallel).
        let moreParallelThanSuggested: Int
        /// Deviations where the leader delegated less than the policy suggested.
        let lessParallelThanSuggested: Int
        let shadowTurns: Int
        let canaryTurns: Int
        let holdoutTurns: Int
        let delegatedWaves: Int
        let delegatedTasks: Int
        let completedDelegatedTasks: Int
        let delegationRate: Double
        let delegationCompletionRate: Double
        let delegatedRoutes: Int
        let unlinkedDelegatedTasks: Int
        let delegationRateByCohort: [String: Double]
        /// Prevent a missing task stream from being reported as a measured 0%.
        let delegationMeasurementStatus: String
    }

    enum CollaborationState: String, Equatable, CaseIterable {
        case healthy
        case leaderOnly
        case identityMismatch
        case routeFailure
        case unmeasured
    }

    /// A bounded, identity-scoped view of recent collaboration evidence.
    struct CollaborationSummary: Equatable {
        let state: CollaborationState
        let routeCount: Int
        let dispatchCount: Int
        let completionCount: Int
        let workerCount: Int
        let unmetFloorCount: Int
        let lastActivity: String?
        let legacyRecordCount: Int

        static func empty(workerCount: Int) -> CollaborationSummary {
            CollaborationSummary(
                state: .unmeasured, routeCount: 0, dispatchCount: 0, completionCount: 0,
                workerCount: workerCount, unmetFloorCount: 0, lastActivity: nil,
                legacyRecordCount: 0
            )
        }
    }

    enum Event: String, Codable, CaseIterable {
        case turnStart = "turn_start"
        case turnRoute = "turn_route"
        case turnEnd = "turn_end"
        case taskDispatch = "task_dispatch"
        case taskLifecycle = "task_lifecycle"
    }

    struct Record: Codable, Equatable {
        let event: Event
        let turnID: String
        let timestamp: String
        let team: String
        let surfaceID: String
        let promptBytes: Int?
        let promptSHA256: String?
        let routeStatus: String?
        /// Shadow-policy fields are additive. `actualRoute` is intentionally
        /// distinct from `suggestedRoute`, and `policyApplied` remains false
        /// unless a future health-gated canary explicitly changes behavior.
        let actualRoute: String?
        let suggestedParticipation: String?
        let suggestedRoute: String?
        let policyVersion: String?
        let policyMode: String?
        let policyApplied: Bool?
        let cohort: String?
        let policyReasons: [String]?
        let dispatchBounds: String?
        let requestID: String?
        let taskID: String?
        let worker: String?
        let workerInstanceID: String?
        let taskStatus: String?
        let taskRoute: String?
        let taskWaveID: String?
        /// The route record uses wave_id while task records use task_wave_id.
        let waveID: String?
        let taskDelivery: String?
        let teamUUID: String?
        let leaderSessionID: String?
        let delegationFloor: String?

        private enum CodingKeys: String, CodingKey {
            case event
            case turnID = "turn_id"
            case timestamp = "ts"
            case team
            case surfaceID = "surface_id"
            case promptBytes = "prompt_bytes"
            case promptSHA256 = "prompt_sha256"
            case routeStatus = "route_status"
            case actualRoute = "actual_route"
            case suggestedParticipation = "suggested_participation"
            case suggestedRoute = "suggested_route"
            case policyVersion = "policy_version"
            case policyMode = "policy_mode"
            case policyApplied = "policy_applied"
            case cohort
            case policyReasons = "policy_reasons"
            case dispatchBounds = "dispatch_bounds"
            case requestID = "request_id"
            case taskID = "task_id"
            case worker
            case workerInstanceID = "worker_instance_id"
            case taskStatus = "task_status"
            case taskRoute = "task_route"
            case taskWaveID = "task_wave_id"
            case waveID = "wave_id"
            case taskDelivery = "task_delivery"
            case teamUUID = "team_uuid"
            case leaderSessionID = "leader_session_id"
            case delegationFloor = "delegation_floor"
        }

        private init(
            event: Event,
            turnID: String,
            timestamp: String,
            team: String,
            surfaceID: String,
            promptBytes: Int?,
            promptSHA256: String?,
            routeStatus: String? = nil,
            actualRoute: String? = nil,
            suggestedParticipation: String? = nil,
            suggestedRoute: String? = nil,
            policyVersion: String? = nil,
            policyMode: String? = nil,
            policyApplied: Bool? = nil,
            cohort: String? = nil,
            policyReasons: [String]? = nil,
            dispatchBounds: String? = nil,
            requestID: String? = nil,
            taskID: String? = nil,
            worker: String? = nil,
            workerInstanceID: String? = nil,
            taskStatus: String? = nil,
            taskRoute: String? = nil,
            taskWaveID: String? = nil,
            waveID: String? = nil,
            taskDelivery: String? = nil,
            teamUUID: String? = nil,
            leaderSessionID: String? = nil,
            delegationFloor: String? = nil
        ) {
            self.event = event
            self.turnID = turnID
            self.timestamp = timestamp
            self.team = team
            self.surfaceID = surfaceID
            self.promptBytes = promptBytes
            self.promptSHA256 = promptSHA256
            self.routeStatus = routeStatus
            self.actualRoute = actualRoute
            self.suggestedParticipation = suggestedParticipation
            self.suggestedRoute = suggestedRoute
            self.policyVersion = policyVersion
            self.policyMode = policyMode
            self.policyApplied = policyApplied
            self.cohort = cohort
            self.policyReasons = policyReasons
            self.dispatchBounds = dispatchBounds
            self.requestID = requestID
            self.taskID = taskID
            self.worker = worker
            self.workerInstanceID = workerInstanceID
            self.taskStatus = taskStatus
            self.taskRoute = taskRoute
            self.taskWaveID = taskWaveID
            self.waveID = waveID
            self.taskDelivery = taskDelivery
            self.teamUUID = teamUUID
            self.leaderSessionID = leaderSessionID
            self.delegationFloor = delegationFloor
        }

        static func turnStart(
            team: String,
            surfaceID: String,
            prompt: String,
            sessionID: String? = nil,
            teamUUID: String? = nil,
            leaderSessionID: String? = nil,
            timestamp: Date = Date()
        ) -> Record {
            let promptHash = LeaderTurnLog.promptSHA256(prompt)
            return Record(
                event: .turnStart,
                turnID: LeaderTurnLog.turnID(
                    sessionID: sessionID,
                    surfaceID: surfaceID,
                    promptSHA256: promptHash
                ),
                timestamp: LeaderTurnLog.timestamp(timestamp),
                team: team,
                surfaceID: surfaceID,
                promptBytes: prompt.utf8.count,
                promptSHA256: promptHash,
                teamUUID: teamUUID, leaderSessionID: leaderSessionID
            )
        }

        static func turnEnd(
            team: String,
            surfaceID: String,
            prompt: String,
            sessionID: String? = nil,
            teamUUID: String? = nil,
            leaderSessionID: String? = nil,
            timestamp: Date = Date()
        ) -> Record {
            let promptHash = LeaderTurnLog.promptSHA256(prompt)
            return Record(
                event: .turnEnd,
                turnID: LeaderTurnLog.turnID(
                    sessionID: sessionID,
                    surfaceID: surfaceID,
                    promptSHA256: promptHash
                ),
                timestamp: LeaderTurnLog.timestamp(timestamp),
                team: team,
                surfaceID: surfaceID,
                promptBytes: nil,
                promptSHA256: nil,
                teamUUID: teamUUID, leaderSessionID: leaderSessionID
            )
        }

        static func taskDispatch(
            team: String,
            requestID: String?,
            taskID: String,
            worker: String?,
            workerInstanceID: String?,
            route: String?,
            waveID: String?,
            delivery: String,
            teamUUID: String? = nil,
            leaderSessionID: String? = nil,
            timestamp: Date = Date()
        ) -> Record {
            Record(
                event: .taskDispatch,
                turnID: requestID ?? waveID ?? taskID,
                timestamp: LeaderTurnLog.timestamp(timestamp),
                team: team,
                surfaceID: "",
                promptBytes: nil,
                promptSHA256: nil,
                requestID: requestID,
                taskID: taskID,
                worker: worker,
                workerInstanceID: workerInstanceID,
                taskRoute: route,
                taskWaveID: waveID,
                taskDelivery: delivery,
                teamUUID: teamUUID, leaderSessionID: leaderSessionID
            )
        }

        static func taskLifecycle(
            team: String,
            requestID: String?,
            taskID: String,
            worker: String?,
            workerInstanceID: String?,
            route: String?,
            waveID: String?,
            status: String,
            delivery: String? = nil,
            teamUUID: String? = nil,
            leaderSessionID: String? = nil,
            timestamp: Date = Date()
        ) -> Record {
            Record(
                event: .taskLifecycle,
                turnID: requestID ?? waveID ?? taskID,
                timestamp: LeaderTurnLog.timestamp(timestamp),
                team: team,
                surfaceID: "",
                promptBytes: nil,
                promptSHA256: nil,
                requestID: requestID,
                taskID: taskID,
                worker: worker,
                workerInstanceID: workerInstanceID,
                taskStatus: status,
                taskRoute: route,
                taskWaveID: waveID,
                taskDelivery: delivery,
                teamUUID: teamUUID, leaderSessionID: leaderSessionID
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            event = try container.decode(Event.self, forKey: .event)
            turnID = try container.decode(String.self, forKey: .turnID)
            timestamp = try container.decode(String.self, forKey: .timestamp)
            team = try container.decode(String.self, forKey: .team)
            // Absent, not empty: the Rust writer omits surface_id entirely when
            // TERMMESH_SURFACE_ID is unset, so requiring it here would make
            // readAll drop those turn_route lines — and readAll swallows decode
            // failures, so the loss would be silent and would look exactly like
            // a leader that never reported a route.
            surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID) ?? ""

            switch event {
            case .turnStart:
                promptBytes = try container.decodeIfPresent(Int.self, forKey: .promptBytes)
                promptSHA256 = try container.decodeIfPresent(String.self, forKey: .promptSHA256)
            case .turnRoute, .turnEnd, .taskDispatch, .taskLifecycle:
                promptBytes = nil
                promptSHA256 = nil
            }
            routeStatus = try container.decodeIfPresent(String.self, forKey: .routeStatus)
            actualRoute = try container.decodeIfPresent(String.self, forKey: .actualRoute)
            suggestedParticipation = try container.decodeIfPresent(String.self, forKey: .suggestedParticipation)
            suggestedRoute = try container.decodeIfPresent(String.self, forKey: .suggestedRoute)
            policyVersion = try container.decodeIfPresent(String.self, forKey: .policyVersion)
            policyMode = try container.decodeIfPresent(String.self, forKey: .policyMode)
            policyApplied = try container.decodeIfPresent(Bool.self, forKey: .policyApplied)
            cohort = try container.decodeIfPresent(String.self, forKey: .cohort)
            policyReasons = try container.decodeIfPresent([String].self, forKey: .policyReasons)
            dispatchBounds = try container.decodeIfPresent(String.self, forKey: .dispatchBounds)
            requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
            taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
            worker = try container.decodeIfPresent(String.self, forKey: .worker)
            workerInstanceID = try container.decodeIfPresent(String.self, forKey: .workerInstanceID)
            taskStatus = try container.decodeIfPresent(String.self, forKey: .taskStatus)
            taskRoute = try container.decodeIfPresent(String.self, forKey: .taskRoute)
            taskWaveID = try container.decodeIfPresent(String.self, forKey: .taskWaveID)
            waveID = try container.decodeIfPresent(String.self, forKey: .waveID)
            taskDelivery = try container.decodeIfPresent(String.self, forKey: .taskDelivery)
            teamUUID = try container.decodeIfPresent(String.self, forKey: .teamUUID)
            leaderSessionID = try container.decodeIfPresent(String.self, forKey: .leaderSessionID)
            delegationFloor = try container.decodeIfPresent(String.self, forKey: .delegationFloor)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(event, forKey: .event)
            try container.encode(turnID, forKey: .turnID)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(team, forKey: .team)
            if !surfaceID.isEmpty {
                try container.encode(surfaceID, forKey: .surfaceID)
            }
            if event == .turnStart {
                try container.encode(promptBytes, forKey: .promptBytes)
                try container.encode(promptSHA256, forKey: .promptSHA256)
            }
            try container.encodeIfPresent(routeStatus, forKey: .routeStatus)
            try container.encodeIfPresent(actualRoute, forKey: .actualRoute)
            try container.encodeIfPresent(suggestedParticipation, forKey: .suggestedParticipation)
            try container.encodeIfPresent(suggestedRoute, forKey: .suggestedRoute)
            try container.encodeIfPresent(policyVersion, forKey: .policyVersion)
            try container.encodeIfPresent(policyMode, forKey: .policyMode)
            try container.encodeIfPresent(policyApplied, forKey: .policyApplied)
            try container.encodeIfPresent(cohort, forKey: .cohort)
            try container.encodeIfPresent(policyReasons, forKey: .policyReasons)
            try container.encodeIfPresent(dispatchBounds, forKey: .dispatchBounds)
            try container.encodeIfPresent(requestID, forKey: .requestID)
            try container.encodeIfPresent(taskID, forKey: .taskID)
            try container.encodeIfPresent(worker, forKey: .worker)
            try container.encodeIfPresent(workerInstanceID, forKey: .workerInstanceID)
            try container.encodeIfPresent(taskStatus, forKey: .taskStatus)
            try container.encodeIfPresent(taskRoute, forKey: .taskRoute)
            try container.encodeIfPresent(taskWaveID, forKey: .taskWaveID)
            if event == .turnRoute {
                try container.encodeIfPresent(waveID, forKey: .waveID)
            }
            try container.encodeIfPresent(taskDelivery, forKey: .taskDelivery)
            try container.encodeIfPresent(teamUUID, forKey: .teamUUID)
            try container.encodeIfPresent(leaderSessionID, forKey: .leaderSessionID)
            try container.encodeIfPresent(delegationFloor, forKey: .delegationFloor)
        }
    }

    enum AppendError: Error {
        case openFailed(Int32)
        case writeFailed(expected: Int, actual: Int, errno: Int32)
    }

    static let logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".term-mesh/logs", isDirectory: true)

    /// Keep the .log extension: term-meshd's GC rotates only files whose
    /// extension is exactly log, even though this file's content is JSONL.
    static let logFile = logDirectory.appendingPathComponent("turns.log")

    static func promptSHA256(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Pure cross-process identity: first 16 lowercase hex characters of
    /// SHA-256(UTF8(discriminator + ":" + prompt_sha256)).
    ///
    /// The discriminator MUST match `scripts/leader-turn-hook.sh`, which is the
    /// writer that actually produces `turn_start`/`turn_end` today: it prefers
    /// the CLI session ID from the hook payload and falls back to the surface
    /// ID only when the payload carries none. An implementation here that hard-
    /// coded the surface ID would derive a different ID for the same turn, and
    /// because the join is by `turn_id` alone the two records would simply
    /// never meet — no error, just a start with no route. Take the
    /// discriminator as a parameter so a caller cannot silently pick the wrong
    /// one, and let it carry the same preference order the hook uses.
    static func turnID(sessionID: String?, surfaceID: String, promptSHA256: String) -> String {
        let discriminator = (sessionID?.isEmpty == false) ? sessionID! : surfaceID
        let input = Data("\(discriminator):\(promptSHA256)".utf8)
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    /// The sole append entry point. The complete JSON object and trailing
    /// newline are assembled before opening the file and emitted in one write.
    /// Open by path and close on every call: term-meshd periodically rotates
    /// this log with rename, so retaining a handle would keep writing to the
    /// old inode until a later rotation unlinks it and silently loses records.
    static func append(_ record: Record, to logFile: URL = logFile) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)

        let descriptor = Darwin.open(
            logFile.path,
            O_WRONLY | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw AppendError.openFailed(errno) }
        defer { Darwin.close(descriptor) }

        let written = line.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == line.count else {
            throw AppendError.writeFailed(expected: line.count, actual: written, errno: errno)
        }
    }

    @discardableResult
    static func appendTaskDispatch(
        team: String,
        requestID: String?,
        taskID: String,
        worker: String?,
        workerInstanceID: String?,
        route: String?,
        waveID: String?,
        delivery: String,
        teamUUID: String? = nil,
        leaderSessionID: String? = nil,
        to logFile: URL = logFile
    ) -> Bool {
        let identity = recordIdentity(
            team: team, teamUUID: teamUUID, leaderSessionID: leaderSessionID
        )
        do {
            try append(
                .taskDispatch(
                    team: team, requestID: requestID, taskID: taskID,
                    worker: worker, workerInstanceID: workerInstanceID,
                    route: route, waveID: waveID, delivery: delivery,
                    teamUUID: identity.teamUUID, leaderSessionID: identity.leaderSessionID
                ),
                to: logFile
            )
            return true
        } catch {
            fputs("term-mesh: leader task dispatch log append failed: \(error)\\n", stderr)
            return false
        }
    }

    @discardableResult
    static func appendTaskLifecycle(
        team: String,
        requestID: String?,
        taskID: String,
        worker: String?,
        workerInstanceID: String?,
        route: String?,
        waveID: String?,
        status: String,
        delivery: String? = nil,
        teamUUID: String? = nil,
        leaderSessionID: String? = nil,
        to logFile: URL = logFile
    ) -> Bool {
        let identity = recordIdentity(
            team: team, teamUUID: teamUUID, leaderSessionID: leaderSessionID
        )
        do {
            try append(
                .taskLifecycle(
                    team: team, requestID: requestID, taskID: taskID,
                    worker: worker, workerInstanceID: workerInstanceID,
                    route: route, waveID: waveID, status: status,
                    delivery: delivery, teamUUID: identity.teamUUID,
                    leaderSessionID: identity.leaderSessionID
                ),
                to: logFile
            )
            return true
        } catch {
            fputs("term-mesh: leader task lifecycle log append failed: \(error)\\n", stderr)
            return false
        }
    }

    /// Inspection helper. A final segment without a newline is considered torn,
    /// and malformed complete lines are skipped independently.
    /// `policyReport` and `countsByEvent` both walk the whole history, and
    /// `fleet.state` asks for them on the main actor every three seconds, so
    /// this shares the identity-keyed cache used by `health`.
    static func readAll(from logFile: URL = logFile) -> [Record] {
        let path = logFile.path
        let stamp = LogFileStamp(path: path)
        if let stamp {
            logCacheLock.lock()
            let cached = recordCache
            logCacheLock.unlock()
            if let cached, cached.stamp == stamp { return cached.records }
        }
        let records = decodeAll(from: logFile)
        if let stamp, let after = LogFileStamp(path: path), after == stamp {
            logCacheLock.lock()
            recordCache = (stamp, records)
            logCacheLock.unlock()
        }
        return records
    }

    private static func decodeAll(from logFile: URL) -> [Record] {
        guard let data = try? Data(contentsOf: logFile), !data.isEmpty else { return [] }
        var lines = data.split(separator: 0x0A)
        if data.last != 0x0A {
            lines.removeLast()
        }
        let decoder = JSONDecoder()
        return lines.compactMap { line in
            try? decoder.decode(Record.self, from: Data(line))
        }
    }

    static func readAll(from text: String) -> [Record] {
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Record.self, from: Data(line.utf8))
        }
    }

    /// Decode only the newest records for one Project. The file is shared by
    /// every team, so callers that draw one card must not decode and sort the
    /// entire append-only history on the main actor.
    /// The delegation panel asks for this on the Review Board's own beat, which
    /// is every settled team change, so the tail is re-decoded far more often
    /// than a turn is written. Cache per (team, limit) under one file identity;
    /// a changed file replaces the whole table, so it never grows past the
    /// number of teams on screen.
    static func readRecent(
        from logFile: URL = logFile,
        team: String,
        limit: Int = 200
    ) -> [Record] {
        let path = logFile.path
        let key = RecentKey(team: team, limit: limit)
        let stamp = LogFileStamp(path: path)
        if let stamp {
            logCacheLock.lock()
            let cached = recentCache
            logCacheLock.unlock()
            if let cached, cached.stamp == stamp, let hit = cached.entries[key] { return hit }
        }
        let records = decodeRecent(from: logFile, team: team, limit: limit)
        if let stamp, let after = LogFileStamp(path: path), after == stamp {
            logCacheLock.lock()
            if var current = recentCache, current.stamp == stamp {
                current.entries[key] = records
                recentCache = current
            } else {
                recentCache = (stamp, [key: records])
            }
            logCacheLock.unlock()
        }
        return records
    }

    private struct RecentKey: Hashable {
        let team: String
        let limit: Int
    }

    private static func decodeRecent(
        from logFile: URL,
        team: String,
        limit: Int
    ) -> [Record] {
        guard let data = try? Data(contentsOf: logFile), !data.isEmpty else { return [] }
        var lines = data.split(separator: 0x0A)
        if data.last != 0x0A { lines.removeLast() }
        let decoder = JSONDecoder()
        var records: [Record] = []
        records.reserveCapacity(max(1, limit))
        for line in lines.reversed() {
            guard let record = try? decoder.decode(Record.self, from: Data(line)),
                  record.team == team else { continue }
            records.append(record)
            if records.count >= max(1, limit) { break }
        }
        return records.reversed()
    }

    /// Use live identity only when the caller already runs on the main thread.
    /// Socket telemetry stays off-main and must never block it with main.sync.
    private static func recordIdentity(
        team: String, teamUUID: String?, leaderSessionID: String?
    ) -> (teamUUID: String?, leaderSessionID: String?) {
        if teamUUID != nil || leaderSessionID != nil {
            return (teamUUID, leaderSessionID)
        }
        identityLock.lock()
        let remembered = knownIdentities[team]
        identityLock.unlock()
        if let remembered { return remembered }
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                guard let live = TeamOrchestrator.shared.teams[team] else {
                    return (nil, nil)
                }
                return (live.teamUuid, live.leaderSessionId)
            }
        }
        let environment = ProcessInfo.processInfo.environment
        guard environment["TERMMESH_TEAM"] == team else { return (nil, nil) }
        return (
            environment["TERMMESH_LEADER_TEAM_UUID"],
            environment["TERMMESH_LEADER_SESSION_ID"]
        )
    }

    static func rememberIdentity(
        team: String, teamUUID: String, leaderSessionID: String?
    ) {
        guard !team.isEmpty, !teamUUID.isEmpty else { return }
        identityLock.lock()
        knownIdentities[team] = (teamUUID, leaderSessionID?.isEmpty == false ? leaderSessionID : nil)
        identityLock.unlock()
    }

    /// One immutable measurement snapshot. Supported-turn denominator comes
    /// only from `turn_start`; unsupported and degraded leader cohorts are
    /// supplied from runtime capability inventory and never dilute coverage.
    /// A linked turn owns start + route + end with the same non-placeholder id.
    static func health(
        from logFile: URL = logFile,
        capabilities: [MeasurementCapability] = []
    ) -> Health {
        let derived = fileDerivedHealth(from: logFile)
        return Health(
            supportedTurns: derived.supportedTurns,
            linkedTurns: derived.linkedTurns,
            statedTurns: derived.statedTurns,
            unstatedTurns: derived.unstatedTurns,
            unsupportedTurns: capabilities.filter { $0 == .unsupported }.count,
            degradedTurns: capabilities.filter { $0 == .degraded }.count,
            malformedLines: derived.malformedLines,
            observedDays: derived.observedDays
        )
    }

    /// The part of `Health` that depends only on the log bytes. `capabilities`
    /// is a live runtime signal supplied by the caller, so it stays out of the
    /// cache below.
    private struct FileDerivedHealth {
        let supportedTurns: Int
        let linkedTurns: Int
        let statedTurns: Int
        let unstatedTurns: Int
        let malformedLines: Int
        let observedDays: Int

        static let empty = FileDerivedHealth(
            supportedTurns: 0,
            linkedTurns: 0,
            statedTurns: 0,
            unstatedTurns: 0,
            malformedLines: 0,
            observedDays: 0
        )
    }

    /// Identity of the exact bytes an aggregate came from. Rotation renames the
    /// file, so a changed inode invalidates on its own; `birthtime` separates a
    /// rotated file from an older one that happens to reuse the inode number.
    private struct LogFileStamp: Equatable {
        let deviceID: dev_t
        let fileID: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let createdSeconds: Int
        let createdNanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            deviceID = info.st_dev
            fileID = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            createdSeconds = info.st_birthtimespec.tv_sec
            createdNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    private static let logCacheLock = NSLock()
    private static var healthCache: (stamp: LogFileStamp, value: FileDerivedHealth)?
    private static var recordCache: (stamp: LogFileStamp, records: [Record])?
    private static var recentCache: (stamp: LogFileStamp, entries: [RecentKey: [Record]])?
    private static var policyCache: (stamp: LogFileStamp, entries: [String: PolicyReport])?

    /// Decoding the whole append-only history is the dominant main-thread cost
    /// of `fleet.state`, `team.status` and the dashboard's three-second tick.
    /// All three ask for this aggregate far more often than a turn is written,
    /// so key it on the file's identity and never decode an unchanged file
    /// twice. A file that grows keeps paying the full decode; only repeats of
    /// identical bytes become free.
    private static func fileDerivedHealth(from logFile: URL) -> FileDerivedHealth {
        let path = logFile.path
        let stamp = LogFileStamp(path: path)
        if let stamp {
            logCacheLock.lock()
            let cached = healthCache
            logCacheLock.unlock()
            if let cached, cached.stamp == stamp { return cached.value }
        }
        let value = computeFileDerivedHealth(from: logFile)
        // Cache only when the file did not change while it was being read.
        // Otherwise the aggregate describes bytes the stamp no longer names.
        if let stamp, let after = LogFileStamp(path: path), after == stamp {
            logCacheLock.lock()
            healthCache = (stamp, value)
            logCacheLock.unlock()
        }
        return value
    }

    private static func computeFileDerivedHealth(from logFile: URL) -> FileDerivedHealth {
        guard let data = try? Data(contentsOf: logFile), !data.isEmpty else {
            return .empty
        }
        var rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if data.last == 0x0A { rawLines.removeLast() }
        let decoder = JSONDecoder()
        var malformed = 0
        var records: [Record] = []
        for line in rawLines where !line.isEmpty {
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else {
                malformed += 1
                continue
            }
            records.append(record)
        }
        let grouped = Dictionary(grouping: records, by: \.turnID)
        let absorbedTurnIDs = Set(records.compactMap { record in
            record.event == .turnEnd && record.routeStatus == "absorbed" ? record.turnID : nil
        })
        let starts = records.filter {
            $0.event == .turnStart && !absorbedTurnIDs.contains($0.turnID)
        }
        let observedDays: Int = {
            let parser = ISO8601DateFormatter()
            let dates = starts.compactMap { parser.date(from: $0.timestamp) }.sorted()
            guard let first = dates.first, let last = dates.last, last >= first else { return 0 }
            // Calendar-day observation uses inclusive days: activity on one
            // UTC date is day 1, and seven distinct elapsed dates unlock the
            // time path. Missing/malformed timestamps never promote.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let start = calendar.startOfDay(for: first)
            let end = calendar.startOfDay(for: last)
            return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        }()
        var linked = 0
        var stated = 0
        var unstated = 0
        for start in starts {
            let turn = grouped[start.turnID] ?? []
            let hasRoute = turn.contains { $0.event == .turnRoute }
            let ends = turn.filter { $0.event == .turnEnd }
            // A durable route record is authoritative even if Stop raced the
            // marker and wrote route_status=unstated. Count every supported
            // turn in exactly one outcome cohort so coverage cannot exceed 1.
            if hasRoute {
                stated += 1
            } else if !ends.isEmpty {
                unstated += 1
            }
            if start.turnID != "unknown", start.turnID != "unstated",
               hasRoute, !ends.isEmpty {
                linked += 1
            }
        }
        return FileDerivedHealth(
            supportedTurns: starts.count,
            linkedTurns: linked,
            statedTurns: stated,
            unstatedTurns: unstated,
            malformedLines: malformed,
            observedDays: observedDays
        )
    }

    static func countsByEvent(from logFile: URL = logFile) -> [Event: Int] {
        Dictionary(grouping: readAll(from: logFile), by: \.event).mapValues(\.count)
    }

    /// Read only a recent tail and require exact Project identity. Name-only
    /// legacy rows remain readable, but never establish current health.
    static func collaborationSummary(
        from logFile: URL = logFile,
        team: String,
        teamUUID: String?,
        leaderSessionID: String?,
        leaderSurfaceID: String? = nil,
        workerCount: Int,
        limit: Int = 200
    ) -> CollaborationSummary {
        collaborationSummary(
            records: readAll(from: logFile), team: team, teamUUID: teamUUID,
            leaderSessionID: leaderSessionID, leaderSurfaceID: leaderSurfaceID,
            workerCount: workerCount, limit: limit
        )
    }

    static func collaborationSummary(
        records: [Record],
        team: String,
        teamUUID: String?,
        leaderSessionID: String?,
        leaderSurfaceID: String? = nil,
        workerCount: Int,
        limit: Int = 200
    ) -> CollaborationSummary {
        // Bound this Project's history, not the shared log's history. Applying
        // the window first lets a noisy sibling Project evict every current
        // record and makes healthy collaboration appear unmeasured.
        let ordered = records.enumerated().filter { $0.element.team == team }.sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let recent = Array(ordered.suffix(max(1, limit)))
        let requiresSession = leaderSessionID?.isEmpty == false
        let legacy = recent.filter { record in
            record.teamUUID == nil || (requiresSession && record.leaderSessionID == nil)
        }
        guard let teamUUID, !teamUUID.isEmpty else {
            var summary = CollaborationSummary.empty(workerCount: workerCount)
            summary = CollaborationSummary(
                state: summary.state, routeCount: 0, dispatchCount: 0,
                completionCount: 0, workerCount: workerCount, unmetFloorCount: 0,
                lastActivity: nil, legacyRecordCount: legacy.count
            )
            return summary
        }
        let scoped = recent.filter { record in
            if record.teamUUID == nil,
               let leaderSurfaceID, !leaderSurfaceID.isEmpty,
               !record.surfaceID.isEmpty {
                return Self.normalizedSurfaceID(record.surfaceID)
                    == Self.normalizedSurfaceID(leaderSurfaceID)
            }
            guard record.teamUUID == teamUUID else { return false }
            guard let leaderSessionID, !leaderSessionID.isEmpty else { return true }
            return record.leaderSessionID == leaderSessionID
        }
        let mismatched = recent.contains { record in
            guard let recordUUID = record.teamUUID else { return false }
            if recordUUID != teamUUID { return true }
            guard let leaderSessionID, !leaderSessionID.isEmpty else { return false }
            guard let recordSession = record.leaderSessionID else { return false }
            return recordSession != leaderSessionID
        }
        let routes = scoped.filter { $0.event == .turnRoute }
        let dispatches = scoped.filter { $0.event == .taskDispatch }
        let lifecycles = scoped.filter { $0.event == .taskLifecycle }
        let completions = lifecycles.filter { $0.taskStatus == "completed" }
        let unmet = scoped.filter { $0.delegationFloor == "unmet" }
        let failures = scoped.filter { record in
            guard record.event == .taskLifecycle else { return false }
            let status = record.taskStatus ?? ""
            let delivery = record.taskDelivery ?? ""
            return delivery == "failed"
                || status == "delivery_failed"
                || status == "route_failed"
                || status == "timeout"
        }
        let lastDispatch = scoped.lastIndex { $0.event == .taskDispatch }
        let lastFailure = scoped.lastIndex { failures.contains($0) }
        let lastUnmet = scoped.lastIndex { $0.delegationFloor == "unmet" }
        func isLater(_ lhs: Int?, than rhs: Int?) -> Bool {
            guard let lhs else { return false }
            guard let rhs else { return true }
            return lhs > rhs
        }
        let state: CollaborationState
        if isLater(lastFailure, than: lastDispatch) {
            state = .routeFailure
        } else if scoped.isEmpty, mismatched {
            state = .identityMismatch
        } else if isLater(lastUnmet, than: lastDispatch) {
            state = .leaderOnly
        } else if !dispatches.isEmpty {
            state = .healthy
        } else if workerCount > 0 && (!routes.isEmpty || !unmet.isEmpty) {
            state = .leaderOnly
        } else {
            state = .unmeasured
        }
        return CollaborationSummary(
            state: state, routeCount: routes.count, dispatchCount: dispatches.count,
            completionCount: completions.count, workerCount: workerCount,
            unmetFloorCount: unmet.count, lastActivity: scoped.last?.timestamp,
            legacyRecordCount: legacy.count
        )
    }

    private static func normalizedSurfaceID(_ value: String) -> String {
        value.lowercased().filter { $0.isASCII && $0.isHexDigit }
    }

    /// `fleet.state` asks for this on the Review Board's beat, and the report
    /// walks the whole history three times plus several set builds. Caching the
    /// decoded records removed the parse but left that aggregate repeating on
    /// every tick, where profiles put it at 42% of the board's refresh. Key the
    /// finished report on the file's identity, as `health` does.
    static func policyReport(from logFile: URL = logFile, team: String? = nil) -> PolicyReport {
        let path = logFile.path
        let key = team ?? ""
        let stamp = LogFileStamp(path: path)
        if let stamp {
            logCacheLock.lock()
            let cached = policyCache
            logCacheLock.unlock()
            if let cached, cached.stamp == stamp, let hit = cached.entries[key] { return hit }
        }
        let report = computePolicyReport(from: logFile, team: team)
        if let stamp, let after = LogFileStamp(path: path), after == stamp {
            logCacheLock.lock()
            if var current = policyCache, current.stamp == stamp {
                current.entries[key] = report
                policyCache = current
            } else {
                policyCache = (stamp, [key: report])
            }
            logCacheLock.unlock()
        }
        return report
    }

    private static func computePolicyReport(from logFile: URL, team: String?) -> PolicyReport {
        let records = readAll(from: logFile).filter { record in
            guard let team else { return true }
            return record.team == team
        }
        let routes = records.filter { $0.event == .turnRoute }
        let dispatches = records.filter { $0.event == .taskDispatch }
        let lifecycles = records.filter { $0.event == .taskLifecycle }
        let cohorts = Dictionary(grouping: routes.compactMap(\.cohort), by: { $0 })
            .mapValues(\.count)
        // Only an explicit wave is a dispatch join key. Falling back to task_id
        // made every single task look like a delegated wave and inflated rates.
        let waves = Set(dispatches.compactMap(\.taskWaveID))
        let taskIDs = Set(dispatches.compactMap(\.taskID))
        let completedTaskIDs = Set(lifecycles.compactMap { record -> String? in
            guard record.taskStatus == "completed" else { return nil }
            return record.taskID
        })
        let routeCount = routes.count
        let delegatedRoutes = routes.filter { route in
            guard let wave = route.waveID else { return false }
            return waves.contains(wave)
        }.count
        let unlinkedDelegatedTasks = dispatches.filter { dispatch in
            guard let wave = dispatch.taskWaveID else { return true }
            return !routes.contains { $0.waveID == wave }
        }.count
        let delegationRateByCohort = Dictionary(grouping: routes, by: { $0.cohort ?? "unknown" })
            .mapValues { cohortRoutes in
                let delegated = cohortRoutes.filter { route in
                    guard let wave = route.waveID else { return false }
                    return waves.contains(wave)
                }.count
                return cohortRoutes.isEmpty ? 0 : Double(delegated) / Double(cohortRoutes.count)
            }
        let unlinkedDelegatedRoutes = routes.contains { route in
            guard let wave = route.waveID else { return false }
            return !waves.contains(wave)
        }
        let delegationMeasurementStatus: String
        if routes.isEmpty {
            delegationMeasurementStatus = dispatches.isEmpty ? "no_turn_routes" : "dispatches_without_turn_routes"
        } else if unlinkedDelegatedTasks > 0 || unlinkedDelegatedRoutes {
            delegationMeasurementStatus = "incomplete_unlinked_tasks"
        } else {
            delegationMeasurementStatus = "measured"
        }
        return PolicyReport(
            cohortCounts: cohorts,
            appliedTurns: routes.filter { $0.policyApplied == true }.count,
            suggestedTurns: routes.filter { $0.suggestedRoute != nil }.count,
            routeDeviations: routes.filter { route in
                guard let actual = route.actualRoute, let suggested = route.suggestedRoute else { return false }
                return actual != suggested
            }.count,
            moreParallelThanSuggested: routes.filter { route in
                guard let actual = route.actualRoute, let suggested = route.suggestedRoute,
                      actual != suggested,
                      let actualRank = routeDelegationRank[actual], let suggestedRank = routeDelegationRank[suggested]
                else { return false }
                return actualRank > suggestedRank
            }.count,
            lessParallelThanSuggested: routes.filter { route in
                guard let actual = route.actualRoute, let suggested = route.suggestedRoute,
                      actual != suggested,
                      let actualRank = routeDelegationRank[actual], let suggestedRank = routeDelegationRank[suggested]
                else { return false }
                return actualRank < suggestedRank
            }.count,
            shadowTurns: routes.filter { $0.policyMode == "shadow" }.count,
            canaryTurns: cohorts["canary", default: 0],
            holdoutTurns: cohorts["holdout", default: 0],
            delegatedWaves: waves.count,
            delegatedTasks: taskIDs.count,
            completedDelegatedTasks: completedTaskIDs.intersection(taskIDs).count,
            delegationRate: routeCount == 0 ? 0 : Double(delegatedRoutes) / Double(routeCount),
            delegationCompletionRate: taskIDs.isEmpty
                ? 0 : Double(completedTaskIDs.intersection(taskIDs).count) / Double(taskIDs.count),
            delegatedRoutes: delegatedRoutes,
            unlinkedDelegatedTasks: unlinkedDelegatedTasks,
            delegationRateByCohort: delegationRateByCohort,
            delegationMeasurementStatus: delegationMeasurementStatus
        )
    }

    private static func timestamp(_ date: Date) -> String {
        // Whole seconds, matching the shell hook (`date -u +%Y-%m-%dT%H:%M:%SZ`)
        // and the Rust writer (`iso8601_utc_now`). Fractional seconds here would
        // make one dataset carry two `ts` shapes, breaking string ordering and
        // equality across writers for no gain at this resolution.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
