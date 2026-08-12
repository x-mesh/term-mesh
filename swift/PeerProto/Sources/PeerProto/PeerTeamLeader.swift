import Foundation

/// Shared security limits for `team.leader.v1`.
///
/// Keep these values and validation order in lockstep with
/// `daemon/peer-proto/src/lib.rs`. Bootstrap deliberately accepts no path,
/// command, CLI, environment or argument fields; executable configuration is
/// resolved by the host from `projectID` after this validation succeeds.
public enum PeerTeamLeader {
    public static let maxProjectIDBytes = 128
    public static let maxTeamUUIDBytes = 128
    public static let requestIDBytes = 16
    public static let grantIDBytes = 32
    public static let maxBootstrapPayloadBytes = 512
    public static let maxCommandPayloadBytes = 64 * 1024

    /// Extra methods available only to a project-scoped autonomous leader.
    /// Generic `team.call.v1` peers must not inherit these permissions.
    public static let scopedMethods: Set<String> = [
        "team.add_agent",
    ]

    public static func isAllowed(_ method: String) -> Bool {
        PeerTeamCall.isAllowed(method) || scopedMethods.contains(method)
    }

    public enum ValidationError: String, Error, Sendable, Equatable {
        case payloadTooLarge = "payload_too_large"
        case invalidProject = "invalid_project"
        case invalidPlacement = "invalid_placement"
        case invalidRequestID = "invalid_request_id"
        case invalidMethod = "invalid_method"
        case invalidParams = "invalid_params"
        case replayedRequest = "replayed_request"
        case unknownGrant = "unknown_grant"
        case forgedProject = "forged_project"
        case forgedTeam = "forged_team"
        case invalidRole = "invalid_role"
        case expiredGrant = "expired_grant"
        case wrongAudience = "wrong_audience"
    }

    public static func validateBootstrap(
        _ request: Termmesh_Peer_V1_TeamLeaderBootstrapRequest,
        encodedBytes: Int? = nil
    ) -> Result<Void, ValidationError> {
        if let encodedBytes, encodedBytes > maxBootstrapPayloadBytes {
            return .failure(.payloadTooLarge)
        }
        guard isSafeIdentifier(request.projectID, maxBytes: maxProjectIDBytes) else {
            return .failure(.invalidProject)
        }
        guard request.leaderPlacement == .local || request.leaderPlacement == .peer else {
            return .failure(.invalidPlacement)
        }
        guard request.requestID.count == requestIDBytes else {
            return .failure(.invalidRequestID)
        }
        return .success(())
    }

    public static func validateGrant(
        _ presented: Termmesh_Peer_V1_TeamLeaderGrant,
        registered: Termmesh_Peer_V1_TeamLeaderGrant?,
        registeredValidUntilUnixSeconds: UInt64? = nil,
        expectedProjectID: String,
        expectedTeamUUID: String,
        nowUnixSeconds: UInt64
    ) -> Result<Void, ValidationError> {
        guard presented.grantID.count == grantIDBytes, let registered else {
            return .failure(.unknownGrant)
        }
        guard registered.grantID == presented.grantID else {
            return .failure(.unknownGrant)
        }
        guard presented.projectID == registered.projectID,
              presented.projectID == expectedProjectID else {
            return .failure(.forgedProject)
        }
        guard presented.teamUuid == registered.teamUuid,
              presented.teamUuid == expectedTeamUUID,
              isSafeIdentifier(presented.teamUuid, maxBytes: maxTeamUUIDBytes) else {
            return .failure(.forgedTeam)
        }
        guard presented.role == .leader, registered.role == .leader else {
            return .failure(.invalidRole)
        }
        // The wire expiry remains bound to the originally issued grant so a
        // caller cannot forge it. Active grants may have a later, server-only
        // lease deadline; that authority is never copied into the leader
        // process environment.
        let validUntil = registeredValidUntilUnixSeconds
            ?? registered.expiresAtUnixSecs
        guard presented.expiresAtUnixSecs == registered.expiresAtUnixSecs,
              validUntil > nowUnixSeconds else {
            return .failure(.expiredGrant)
        }
        return .success(())
    }

    /// Validate everything supplied by a remote leader before the owning
    /// host touches its team dispatcher. JSON parsing intentionally happens
    /// here (inside the control-plane actor), not in a MainActor provider.
    /// Everything a machine can decide about a leader command without being
    /// the one that minted its grant.
    ///
    /// Split out because a relay hop is not the authority. A leader placed on
    /// a peer presents a grant the *project's* host minted and stored, so the
    /// peer it runs on has no registry entry for it and never will — demanding
    /// one there rejected every genuine command with `noMatchingLeaderSession`
    /// while the grant was valid the whole time. Shape is still worth checking
    /// early: an oversized or unknown-method frame is not worth a round trip.
    ///
    /// Authenticity — is this grant real, unexpired, and for this audience —
    /// belongs to `validateCommand` on the machine that issued it.
    public static func validateCommandShape(
        _ request: Termmesh_Peer_V1_TeamLeaderCommandRequest,
        encodedBytes: Int
    ) -> Result<Void, ValidationError> {
        guard encodedBytes <= maxCommandPayloadBytes else {
            return .failure(.payloadTooLarge)
        }
        guard request.requestID.count == requestIDBytes else {
            return .failure(.invalidRequestID)
        }
        // `team.list` is intentionally excluded from the scoped leader
        // surface: it ignores a team parameter and would reveal every team
        // owned by the control-plane host.
        guard request.method != "team.list",
              isAllowed(request.method) else {
            return .failure(.invalidMethod)
        }
        guard isSafeIdentifier(request.teamUuid, maxBytes: maxTeamUUIDBytes) else {
            return .failure(.forgedTeam)
        }
        guard let data = request.paramsJson.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] else {
            return .failure(.invalidParams)
        }
        return .success(())
    }

    public static func validateCommand(
        _ request: Termmesh_Peer_V1_TeamLeaderCommandRequest,
        registeredGrant: Termmesh_Peer_V1_TeamLeaderGrant?,
        registeredValidUntilUnixSeconds: UInt64? = nil,
        encodedBytes: Int,
        nowUnixSeconds: UInt64
    ) -> Result<Void, ValidationError> {
        if case .failure(let error) = validateCommandShape(
            request,
            encodedBytes: encodedBytes
        ) {
            return .failure(error)
        }
        let grantValidation = validateGrant(
            request.grant,
            registered: registeredGrant,
            registeredValidUntilUnixSeconds: registeredValidUntilUnixSeconds,
            expectedProjectID: request.grant.projectID,
            expectedTeamUUID: request.teamUuid,
            nowUnixSeconds: nowUnixSeconds
        )
        if case .failure = grantValidation {
            return grantValidation
        }
        return .success(())
    }

    /// Reject control characters, shell metacharacters and separators that
    /// could turn an identifier into executable input if a later layer made
    /// the mistake of interpolating it. Registered project ids currently use
    /// UUIDs or `name:<slug>`, both covered by this grammar.
    private static func isSafeIdentifier(_ value: String, maxBytes: Int) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= maxBytes else { return false }
        return bytes.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 46 || $0 == 58 || $0 == 95
        }
    }
}

/// Per-peer-session replay registry. The connection owns one instance and
/// calls `consume` before any project lookup or UI mutation.
public actor PeerTeamLeaderReplayGuard {
    private var consumed: Set<Data> = []

    public init() {}

    public func consume(_ requestID: Data) -> Result<Void, PeerTeamLeader.ValidationError> {
        guard requestID.count == PeerTeamLeader.requestIDBytes else {
            return .failure(.invalidRequestID)
        }
        guard consumed.insert(requestID).inserted else {
            return .failure(.replayedRequest)
        }
        return .success(())
    }
}

/// One audit record for the scoped remote-leader return route.
public struct PeerTeamLeaderAuditRecord: Sendable, Equatable {
    public let requestID: Data
    public let projectID: String
    public let teamUUID: String
    public let method: String
    public let accepted: Bool
    public let replayed: Bool
    public let errorCode: String?
    public let timestampUnixSeconds: UInt64
}

/// Authoritative, server-wide remote-leader command boundary.
///
/// A single instance is shared by every peer session so reconnects cannot
/// bypass grant lookup or request-id dedupe. Validation, JSON parsing,
/// replay coordination and audit all stay actor-isolated. Only the supplied
/// dispatcher closure may hop to MainActor for a command's minimal pane/team
/// mutation.
public actor PeerTeamLeaderControlPlane {
    /// One process-wide authority for grants minted for leaders that execute
    /// on a peer. PeerServer and the reverse request handler must share this
    /// instance; otherwise a grant created while launching the remote pane
    /// would be unknown when its command comes back on another peer session.
    public static let shared = PeerTeamLeaderControlPlane()

    public typealias Dispatcher = @Sendable (
        _ method: String,
        _ paramsJSON: String,
        _ teamUUID: String
    ) async -> Result<String, PeerTeamCallFailure>

    private struct RequestKey: Hashable {
        let grantID: Data
        let requestID: Data
    }

    private struct RegisteredGrant {
        let value: Termmesh_Peer_V1_TeamLeaderGrant
        let audiencePeerID: Data?
        var validUntilLeaseSeconds: UInt64
        let renewalLifetimeSeconds: UInt64?
    }

    struct RegisteredGrantSnapshot: Sendable {
        let value: Termmesh_Peer_V1_TeamLeaderGrant
        let validUntilLeaseSeconds: UInt64
    }

    private let maxCacheEntries: Int
    private let maxAuditEntries: Int
    private let maxBootstrapEntries: Int
    private let maxGrantEntries: Int
    private var bootstrapRequestIDs: [Data: UInt64] = [:]
    private var bootstrapOrder: [Data] = []
    private var grants: [Data: RegisteredGrant] = [:]
    private var grantOrder: [Data] = []
    private var completed: [RequestKey: Termmesh_Peer_V1_TeamLeaderCommandResponse] = [:]
    private var completionOrder: [RequestKey] = []
    private var inFlight: [
        RequestKey: Task<Result<String, PeerTeamCallFailure>, Never>
    ] = [:]
    private var auditLog: [PeerTeamLeaderAuditRecord] = []

    public init(
        maxCacheEntries: Int = 2_048,
        maxAuditEntries: Int = 4_096,
        maxBootstrapEntries: Int = 2_048,
        maxGrantEntries: Int = 2_048
    ) {
        self.maxCacheEntries = max(1, maxCacheEntries)
        self.maxAuditEntries = max(1, maxAuditEntries)
        self.maxBootstrapEntries = max(1, maxBootstrapEntries)
        self.maxGrantEntries = max(1, maxGrantEntries)
    }

    /// Bootstrap owns grant creation; registering is separated so the
    /// project resolver remains app-specific and tests can install exact
    /// expiry/role fixtures.
    public func registerGrant(
        _ grant: Termmesh_Peer_V1_TeamLeaderGrant,
        audiencePeerID: Data? = nil,
        renewalLifetimeSeconds: UInt64? = nil,
        nowLeaseSeconds: UInt64? = nil
    ) {
        guard grant.grantID.count == PeerTeamLeader.grantIDBytes else { return }
        let leaseNow = nowLeaseSeconds ?? Self.awakeClockSeconds()
        let wallNow = Self.wallClockSeconds()
        let remaining = grant.expiresAtUnixSecs > wallNow
            ? grant.expiresAtUnixSecs - wallNow
            : 0
        storeGrant(
            grant,
            audiencePeerID: audiencePeerID,
            renewalLifetimeSeconds: renewalLifetimeSeconds,
            validUntilLeaseSeconds: leaseNow &+ remaining
        )
    }

    func registeredGrant(id: Data) -> RegisteredGrantSnapshot? {
        guard let registered = grants[id] else { return nil }
        return RegisteredGrantSnapshot(
            value: registered.value,
            validUntilLeaseSeconds: registered.validUntilLeaseSeconds
        )
    }

    public func revokeGrant(id: Data) {
        grants.removeValue(forKey: id)
    }

    /// Extend a live grant on behalf of the app that minted and owns it.
    ///
    /// This is deliberately not a wire command: possession of an old bearer
    /// must not be enough to resurrect it. The owning app uses this while the
    /// remote leader project still exists, so an otherwise-idle pane does not
    /// lose its team route after the one-hour bootstrap lease.
    @discardableResult
    public func keepAliveGrant(
        id: Data,
        nowUnixSeconds: UInt64? = nil,
        nowLeaseSeconds: UInt64? = nil
    ) -> Bool {
        let wallNow = nowUnixSeconds ?? Self.wallClockSeconds()
        let leaseNow = nowLeaseSeconds
            ?? nowUnixSeconds
            ?? Self.awakeClockSeconds()
        purgeExpired(
            nowUnixSeconds: wallNow,
            nowLeaseSeconds: leaseNow
        )
        guard grants[id] != nil else { return false }
        touchGrant(id, nowLeaseSeconds: leaseNow)
        return true
    }

    public func auditRecords() -> [PeerTeamLeaderAuditRecord] {
        auditLog
    }

    /// Resolve a registered project to its already-created authoritative
    /// team, then mint a short-lived leader grant. No executable settings
    /// cross this boundary.
    public func bootstrap(
        _ request: Termmesh_Peer_V1_TeamLeaderBootstrapRequest,
        encodedBytes: Int,
        nowUnixSeconds: UInt64? = nil,
        nowLeaseSeconds: UInt64? = nil,
        grantLifetimeSeconds: UInt64 = 3_600,
        audiencePeerID: Data? = nil,
        resolveTeamUUID: @escaping @Sendable (String) async -> String?
    ) async -> Termmesh_Peer_V1_TeamLeaderBootstrapResponse {
        let wallNow = nowUnixSeconds ?? Self.wallClockSeconds()
        let leaseNow = nowLeaseSeconds
            ?? nowUnixSeconds
            ?? Self.awakeClockSeconds()
        purgeExpired(
            nowUnixSeconds: wallNow,
            nowLeaseSeconds: leaseNow
        )
        let validation = PeerTeamLeader.validateBootstrap(
            request,
            encodedBytes: encodedBytes
        )
        if case .failure(let error) = validation {
            return bootstrapFailure(error)
        }
        guard bootstrapRequestIDs[request.requestID] == nil else {
            return bootstrapFailure(.replayedRequest)
        }
        bootstrapRequestIDs[request.requestID] = wallNow &+ grantLifetimeSeconds
        bootstrapOrder.append(request.requestID)
        trimBootstrapRegistry()
        guard let teamUUID = await resolveTeamUUID(request.projectID),
              !teamUUID.isEmpty else {
            return bootstrapFailure(.invalidProject)
        }

        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data((0..<PeerTeamLeader.grantIDBytes).map { _ in UInt8.random(in: .min ... .max) })
        grant.projectID = request.projectID
        grant.teamUuid = teamUUID
        grant.role = .leader
        grant.expiresAtUnixSecs = wallNow &+ grantLifetimeSeconds
        storeGrant(
            grant,
            audiencePeerID: audiencePeerID,
            renewalLifetimeSeconds: grantLifetimeSeconds,
            validUntilLeaseSeconds: leaseNow &+ grantLifetimeSeconds
        )

        var response = Termmesh_Peer_V1_TeamLeaderBootstrapResponse()
        response.ok = true
        response.teamUuid = teamUUID
        response.grant = grant
        return response
    }

    public func execute(
        _ request: Termmesh_Peer_V1_TeamLeaderCommandRequest,
        encodedBytes: Int,
        nowUnixSeconds: UInt64? = nil,
        nowLeaseSeconds: UInt64? = nil,
        audiencePeerID: Data? = nil,
        dispatch: @escaping Dispatcher
    ) async -> Termmesh_Peer_V1_TeamLeaderCommandResponse {
        let wallNow = nowUnixSeconds ?? Self.wallClockSeconds()
        let leaseNow = nowLeaseSeconds
            ?? nowUnixSeconds
            ?? Self.awakeClockSeconds()
        purgeExpired(
            nowUnixSeconds: wallNow,
            nowLeaseSeconds: leaseNow
        )
        let registered = grants[request.grant.grantID]
        let validation = PeerTeamLeader.validateCommand(
            request,
            registeredGrant: registered?.value,
            registeredValidUntilUnixSeconds: registered?.validUntilLeaseSeconds,
            encodedBytes: encodedBytes,
            nowUnixSeconds: leaseNow
        )
        if case .failure(let error) = validation {
            let response = failureResponse(
                requestID: request.requestID,
                code: error.rawValue,
                message: "remote leader command rejected"
            )
            appendAudit(
                request,
                accepted: false,
                replayed: false,
                errorCode: error.rawValue,
                now: wallNow
            )
            return response
        }
        if let expectedAudience = registered?.audiencePeerID,
           audiencePeerID != expectedAudience {
            let response = failureResponse(
                requestID: request.requestID,
                code: PeerTeamLeader.ValidationError.wrongAudience.rawValue,
                message: "remote leader command rejected"
            )
            appendAudit(
                request,
                accepted: false,
                replayed: false,
                errorCode: PeerTeamLeader.ValidationError.wrongAudience.rawValue,
                now: wallNow
            )
            return response
        }
        touchGrant(request.grant.grantID, nowLeaseSeconds: leaseNow)

        let key = RequestKey(
            grantID: request.grant.grantID,
            requestID: request.requestID
        )

        if var cached = completed[key] {
            cached.cached = true
            appendAudit(
                request,
                accepted: cached.ok,
                replayed: true,
                errorCode: cached.ok ? nil : cached.errorCode,
                now: wallNow
            )
            return cached
        }

        if let task = inFlight[key] {
            let outcome = await task.value
            var response = makeResponse(
                requestID: request.requestID,
                outcome: outcome
            )
            response.cached = true
            appendAudit(
                request,
                accepted: response.ok,
                replayed: true,
                errorCode: response.ok ? nil : response.errorCode,
                now: wallNow
            )
            return response
        }

        // Force the authoritative scope into the dispatcher. The peer's JSON
        // may contain a forged `team` field, but the provider overwrites it
        // with the team resolved from this validated UUID.
        let task = Task {
            await dispatch(request.method, request.paramsJson, request.teamUuid)
        }
        inFlight[key] = task
        let outcome = await task.value
        inFlight.removeValue(forKey: key)

        let response = makeResponse(requestID: request.requestID, outcome: outcome)
        store(response, for: key)
        appendAudit(
            request,
            accepted: response.ok,
            replayed: false,
            errorCode: response.ok ? nil : response.errorCode,
            now: wallNow
        )
        return response
    }

    private func storeGrant(
        _ grant: Termmesh_Peer_V1_TeamLeaderGrant,
        audiencePeerID: Data?,
        renewalLifetimeSeconds: UInt64?,
        validUntilLeaseSeconds: UInt64
    ) {
        grantOrder.removeAll { $0 == grant.grantID }
        grantOrder.append(grant.grantID)
        grants[grant.grantID] = RegisteredGrant(
            value: grant,
            audiencePeerID: audiencePeerID,
            validUntilLeaseSeconds: validUntilLeaseSeconds,
            renewalLifetimeSeconds: renewalLifetimeSeconds
        )
        while grantOrder.count > maxGrantEntries {
            grants.removeValue(forKey: grantOrder.removeFirst())
        }
    }

    private func touchGrant(_ grantID: Data, nowLeaseSeconds: UInt64) {
        guard var registered = grants[grantID] else { return }
        if let lifetime = registered.renewalLifetimeSeconds {
            let (deadline, overflow) = nowLeaseSeconds.addingReportingOverflow(lifetime)
            registered.validUntilLeaseSeconds = max(
                registered.validUntilLeaseSeconds,
                overflow ? UInt64.max : deadline
            )
            grants[grantID] = registered
        }
        grantOrder.removeAll { $0 == grantID }
        grantOrder.append(grantID)
    }

    private func purgeExpired(
        nowUnixSeconds: UInt64,
        nowLeaseSeconds: UInt64
    ) {
        let expiredRequests = bootstrapRequestIDs.compactMap { id, expiry in
            expiry <= nowUnixSeconds ? id : nil
        }
        for id in expiredRequests {
            bootstrapRequestIDs.removeValue(forKey: id)
        }
        if !expiredRequests.isEmpty {
            bootstrapOrder.removeAll { bootstrapRequestIDs[$0] == nil }
        }

        let expiredGrants = grants.compactMap { id, grant in
            grant.validUntilLeaseSeconds <= nowLeaseSeconds ? id : nil
        }
        for id in expiredGrants {
            grants.removeValue(forKey: id)
        }
        if !expiredGrants.isEmpty {
            grantOrder.removeAll { grants[$0] == nil }
        }
    }

    /// Wall time stays on the wire for tamper detection and audit records.
    /// The renewable server lease deliberately uses system uptime instead:
    /// `systemUptime` advances while the Mac is awake but not while it sleeps,
    /// so an overnight sleep cannot consume an otherwise active leader lease.
    private static func wallClockSeconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }

    private static func awakeClockSeconds() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime)
    }

    private func trimBootstrapRegistry() {
        while bootstrapOrder.count > maxBootstrapEntries {
            bootstrapRequestIDs.removeValue(forKey: bootstrapOrder.removeFirst())
        }
    }

    private func makeResponse(
        requestID: Data,
        outcome: Result<String, PeerTeamCallFailure>
    ) -> Termmesh_Peer_V1_TeamLeaderCommandResponse {
        switch outcome {
        case .success(let json):
            var response = Termmesh_Peer_V1_TeamLeaderCommandResponse()
            response.requestID = requestID
            response.ok = true
            response.resultJson = json
            return response
        case .failure(let failure):
            return failureResponse(
                requestID: requestID,
                code: failure.code,
                message: failure.message
            )
        }
    }

    private func failureResponse(
        requestID: Data,
        code: String,
        message: String
    ) -> Termmesh_Peer_V1_TeamLeaderCommandResponse {
        var response = Termmesh_Peer_V1_TeamLeaderCommandResponse()
        response.requestID = requestID
        response.ok = false
        response.errorCode = code
        response.errorMessage = message
        return response
    }

    private func bootstrapFailure(
        _ error: PeerTeamLeader.ValidationError
    ) -> Termmesh_Peer_V1_TeamLeaderBootstrapResponse {
        var response = Termmesh_Peer_V1_TeamLeaderBootstrapResponse()
        response.ok = false
        response.errorCode = error.rawValue
        response.errorMessage = "remote leader bootstrap rejected"
        return response
    }

    private func store(
        _ response: Termmesh_Peer_V1_TeamLeaderCommandResponse,
        for key: RequestKey
    ) {
        if completed[key] == nil {
            completionOrder.append(key)
        }
        completed[key] = response
        while completionOrder.count > maxCacheEntries {
            completed.removeValue(forKey: completionOrder.removeFirst())
        }
    }

    private func appendAudit(
        _ request: Termmesh_Peer_V1_TeamLeaderCommandRequest,
        accepted: Bool,
        replayed: Bool,
        errorCode: String?,
        now: UInt64
    ) {
        auditLog.append(PeerTeamLeaderAuditRecord(
            requestID: request.requestID,
            projectID: request.grant.projectID,
            teamUUID: request.teamUuid,
            method: request.method,
            accepted: accepted,
            replayed: replayed,
            errorCode: errorCode,
            timestampUnixSeconds: now
        ))
        if auditLog.count > maxAuditEntries {
            auditLog.removeFirst(auditLog.count - maxAuditEntries)
        }
    }
}
