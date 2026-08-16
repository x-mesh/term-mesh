//  Transport-agnostic client for the peer-federation handshake + control
//  plane. Callers provide read / write callbacks over whatever bytes-in /
//  bytes-out channel they have (Unix socket, pipe, in-memory stream); the
//  session handles framing, message sequencing, and the handshake state
//  machine.
//
//  Phase C-3a ships the minimum needed to list surfaces from a Rust
//  term-meshd host. Phase C-3b will add AttachSurface + streaming,
//  probably on top of the same type.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SwiftProtobuf

public enum PeerSessionError: Error, Equatable {
    case unexpectedEof
    case framing(PeerFramingError)
    case protocolVersionMismatch(host: String, client: String)
    case authRejected(reason: String)
    case attachRejected(reason: String)
    case createWorkspaceRejected(reason: String)
    case invalidEnsureRequest(String)
    case invalidTeamLeaderBootstrap(String)
    case invalidTeamLeaderCommand(String)
    case duplicateEnsureRequestID
    case malformedEnsureResponse(String)
    case sessionClosed(reason: String)
    case concurrentReceiveOperation
    case capabilityNotNegotiated(String)
    case rpcTimedOut(operation: String)
    case unexpectedMessage(String)
}

private enum PeerRPCOutcome<Value: Sendable>: @unchecked Sendable {
    case success(Value)
    case failure(Error)

    func get() throws -> Value {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

private actor PeerRPCResultGate<Value: Sendable> {
    private var result: PeerRPCOutcome<Value>?
    private var continuation: CheckedContinuation<Value, Error>?

    func wait() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    @discardableResult
    func resolve(_ result: PeerRPCOutcome<Value>) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        if let continuation {
            self.continuation = nil
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
        return true
    }
}

public struct PeerEnsureSurfaceOutcome: Sendable, Equatable {
    public let requestID: Data
    public let result: Termmesh_Peer_V1_EnsureSurfaceResult
    public let surfaceID: Data
    public let instanceID: Data
    public let generation: UInt64
    public let pid: UInt32
    public let specHash: Data
    public let error: Termmesh_Peer_V1_EnsureSurfaceError?
}

/// Post-handshake result of a successful AttachSurface.
public struct PeerAttachOutcome: Sendable, Equatable {
    public let surfaceID: Data
    public let initialByteSeq: UInt64
    public let grantedMode: Termmesh_Peer_V1_AttachMode
}

/// Messages a post-attach session can deliver. `other` covers payloads
/// we don't model yet (WorkspaceUpdate.splitChanged, DataAck, Pong, etc.)
/// so callers don't have to handle every oneof variant.
public enum PeerIncomingMessage: Sendable {
    case ptyData(surfaceID: Data, byteSeq: UInt64, payload: Data)
    /// Terminal status for one surface process, delivered after its final
    /// `PtyData`. Gated behind client capability `surface.exit.v1`.
    case surfaceExited(surfaceID: Data, exitCode: Int32, signal: Int32, reason: String)
    /// Fresh-attach screen keyframe (capability "grid.snapshot.v1"): the
    /// rendered current screen as ANSI, consistent with `byteSeq`. The
    /// consumer must reset its wire-gap baseline to `byteSeq` — snapshot
    /// bytes are synthetic and sit outside the PtyData byte_seq space.
    case gridSnapshot(surfaceID: Data, byteSeq: UInt64, altScreen: Bool, ansi: Data)
    /// One rendered scrollback window (tmux copy-mode model): a full-screen
    /// replacement render at `offsetRows` above the live bottom. `atTop`
    /// means the host has nothing older; offset 0 is the live screen itself
    /// (the browse-exit render).
    case scrollbackChunk(surfaceID: Data, offsetRows: UInt32, ansi: Data, atTop: Bool, totalRows: UInt32)
    case workspaceMeta(cwd: String, branch: String, ports: [UInt32], latestNotification: String)
    case workspaceSurfaceAdded(Termmesh_Peer_V1_SurfaceInfo)
    case workspaceSurfaceRemoved(surfaceID: Data)
    case workspaceSurfaceRetitled(surfaceID: Data, title: String)
    case workspaceLayoutChanged(workspaceID: Data, layout: Termmesh_Peer_V1_WorkspaceLayout)
    /// Pushed when a workspace itself (not a pane inside one) was deleted
    /// on the host. Gated behind capability "workspace.lifecycle.v1".
    case workspaceRemoved(workspaceID: Data)
    /// Complete sidebar roster snapshot delivered after
    /// `subscribeWorkspaceList()` and whenever the host's roster changes.
    /// Consumers replace (rather than merge) their cached rows so a tunnel
    /// reconnect cannot leave a removed workspace behind.
    case workspaceListChanged([Termmesh_Peer_V1_Workspace])
    /// How loaded the host machine is, pushed on the host's own sampling
    /// cadence. Gated behind capability "host.stats.v1", so a host that
    /// predates it simply never sends one.
    case hostStats(Termmesh_Peer_V1_HostStats)
    /// Reverse request emitted by a remote host's local `tm-agent` proxy.
    /// `correlationID` is the host envelope sequence and must be echoed by
    /// `sendTeamLeaderCommandResponse`.
    case teamLeaderCommandRequest(
        Termmesh_Peer_V1_TeamLeaderCommandRequest,
        correlationID: UInt64
    )
    case error(code: UInt32, message: String)
    case goodbye(reason: String)
    case other
}

public struct PeerSessionOptions: Sendable {
    public var displayName: String
    public var peerID: Data
    /// Previous peer IDs used only to recover durable Project ownership after
    /// the user explicitly rotates this installation's peer identity.
    public var projectOwnerAliases: [Data]
    public var appVersion: String
    public var authMethod: String
    public var clientProtocolVersion: String
    /// Feature flags advertised to the host in this session's Hello.
    /// Defaults to everything this build supports (`PeerCapability.supported`);
    /// tests override it to exercise the host's handling of arbitrary input.
    public var capabilities: [String]

    public init(
        displayName: String = "term-mesh-swift",
        peerID: Data = PeerIdentity.defaultPeerID(),
        projectOwnerAliases: [Data] = PeerIdentity.previousPeerIDs(),
        appVersion: String = "0.0.1",
        authMethod: String = "ssh-passthrough",
        clientProtocolVersion: String = "1.0.0",
        capabilities: [String] = PeerCapability.supported
    ) {
        self.displayName = displayName
        self.peerID = peerID
        self.projectOwnerAliases = projectOwnerAliases
        self.appVersion = appVersion
        self.authMethod = authMethod
        self.clientProtocolVersion = clientProtocolVersion
        self.capabilities = capabilities
    }
}

public struct PeerSessionInfo: Sendable, Equatable {
    public let hostDisplayName: String
    public let hostAppVersion: String
    public let hostProtocolVersion: String
    public let sessionID: Data
    /// The host's advertised feature flags, parsed from its Hello.
    /// Plumbing only for now (see P3, docs/peer-perf-proposal.md) — a hook
    /// for future wire changes (P8 and later) to query before using them.
    public let hostCapabilities: PeerCapabilities
    /// Authenticated, validated and session-scoped host CLI directories.
    public let hostCLIBinDirs: [String]
    /// Where this machine serves sessions that outlive the process just spoken
    /// to, or empty when it has none.
    ///
    /// Empty and "the same socket" are different answers. A host that names a
    /// different one is saying its own sessions end with it and pointing at
    /// something that will still be there; a host that names nothing is saying
    /// there is nowhere to come back to.
    public let sessionHostSocketPath: String

    /// Whether the host advertised `capability` in its Hello.
    public func hasHostCapability(_ capability: String) -> Bool {
        hostCapabilities.has(capability)
    }
}

public typealias PeerReadFn = @Sendable () async throws -> Data
public typealias PeerWriteFn = @Sendable (Data) async throws -> Void
public typealias PeerCloseFn = @Sendable () async -> Void

/// The single serialization point for every client -> host envelope.
///
/// Keeping this separate from `PeerSession` is what lets latency-sensitive
/// input bypass the actor that is decoding a host output flood, while still
/// preserving one monotonically increasing sequence and one ordered transport
/// write stream. Sending input directly through the transport would be faster
/// but unsafe: it could interleave framed bytes or reorder envelope sequence
/// numbers relative to resize, heartbeat and RPC traffic.
private actor PeerSessionOutboundWriter {
    private let write: PeerWriteFn
    private var seq: UInt64 = 0

    init(write: @escaping PeerWriteFn) {
        self.write = write
    }

    func send(_ unsequenced: Termmesh_Peer_V1_Envelope) async throws {
        var envelope = unsequenced
        seq &+= 1
        envelope.seq = seq
        let frame: Data
        do {
            frame = try encodeFrame(envelope)
        } catch let error as PeerFramingError {
            throw PeerSessionError.framing(error)
        }
        try await write(frame)
    }
}

public actor PeerSession {
    private let read: PeerReadFn
    private nonisolated let outbound: PeerSessionOutboundWriter
    private let closeTransport: PeerCloseFn?
    private var pendingInbound = Data()
    private let demux = PeerSessionDemux()
    private var activeEnsureRequestIDs: Set<Data> = []
    private var inboundPumpTask: Task<Void, Never>?
    private var bufferedIncomingMessages: [PeerIncomingMessage] = []
    /// Keep the transport reader independent from a slow downstream consumer.
    /// Relay output ultimately drains through a bounded local socket writer; if
    /// that writer stalls, tying socket reads to `receiveNextMessage()` leaves
    /// Pong frames unread and can make a healthy host look dead.
    private static let maxBufferedIncomingMessages = 256
    private var incomingWaiters: [UUID: CheckedContinuation<PeerIncomingMessage, Error>] = [:]
    private var inboundTerminalError: Error?
    private var didCloseTransport = false
    private var directResponseRPCInFlight = false
    private var negotiatedHostCapabilities: PeerCapabilities?
    private var inboundReadInProgress = false

    /// Heartbeat state. SSH `ServerAliveInterval` only catches dead
    /// TCP; it does not catch a remote daemon that has paused (laptop
    /// sleep, debugger, deadlock) while its kernel still answers
    /// keepalives. The application-level Ping/Pong here closes that
    /// gap so a hung relay surfaces as a clean disconnect within
    /// seconds instead of leaving the terminal blocked on `read()`
    /// until the kernel TCP keepalive fires (default 2 hours on
    /// macOS).
    private var heartbeatTask: Task<Void, Never>?
    // Use awake-time rather than wall time. `Date` advances while macOS is
    // asleep, so the first heartbeat tick after wake used to see the whole
    // sleep interval as host silence and tear down a healthy remote pane.
    // `systemUptime` is backed by the suspending monotonic clock and excludes
    // time spent asleep.
    private var lastPongUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    /// Timestamp of the most recent inbound bytes from the host (ANY frame,
    /// not just a processed Pong). Under a heavy host→client output flood the
    /// pump loop can be blocked draining PtyData to the relay, so a Pong
    /// sitting behind that flood is not *processed* for many seconds even
    /// though the connection is plainly alive — bytes keep arriving. Liveness
    /// keys off this so backpressure can no longer be misread as a dead
    /// session and kill a healthy relay pane (measured pane-close root cause).
    /// See `tickHeartbeat` and `readFrame`.
    private var lastInboundUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var pingCounter: UInt64 = 0
    /// Set once `tickHeartbeat` observes a tick with no Pong since the
    /// previous one, and cleared as soon as a fresh Pong lands. Bounds
    /// `onFirstMiss`/`onMissRecovered` to exactly one firing per miss
    /// episode instead of once per tick while the gap persists.
    private var missNotified = false
    /// Whether a Pong has arrived since the previous tick. Reset to
    /// `false` at the top of every tick (right before that tick's own
    /// Ping goes out) and set `true` by `receiveNextMessage()` whenever
    /// a Pong is processed. Starts `true` so the very first tick — before
    /// any Ping has had a chance to be answered — never misreads as a
    /// miss. This is a discrete per-tick signal rather than a
    /// `elapsed > intervalSeconds` time comparison because the latter
    /// hovers right at its own threshold in the healthy steady state
    /// (each tick's elapsed-since-last-Pong is naturally ~one interval)
    /// and false-positives on ordinary scheduler jitter.
    private var pongSeenSinceLastTick = true

    public init(
        read: @escaping PeerReadFn,
        write: @escaping PeerWriteFn,
        close: PeerCloseFn? = nil
    ) {
        self.read = read
        self.outbound = PeerSessionOutboundWriter(write: write)
        self.closeTransport = close
    }

    /// Preferred production initializer. `UnixSocketTransport.close()` calls
    /// `NWConnection.cancel()`, which completes an outstanding `receive` and
    /// lets the session's single inbound pump release its actor promptly.
    public init(transport: UnixSocketTransport) {
        self.read = { try await transport.read() }
        self.outbound = PeerSessionOutboundWriter { try await transport.write($0) }
        self.closeTransport = { await transport.close() }
    }

    /// Begin sending Ping frames every `interval` seconds. If no Pong
    /// arrives within `deadAfter` seconds (or a Ping write itself
    /// fails), `onDead` is invoked exactly once and the heartbeat
    /// task exits. Callers should arrange for `onDead` to close the
    /// transport so the in-flight `receiveNextMessage()` read unblocks
    /// with an error and the existing disconnect path runs. Calling
    /// `startHeartbeat` while a heartbeat is already running cancels
    /// the previous one before starting the new one.
    ///
    /// `onFirstMiss` (P6) is an optimistic early signal: it fires once
    /// when a Pong is overdue by more than one ping interval — well
    /// before `deadAfter` would declare the session dead — early enough
    /// for a caller to show a soft "reconnecting" banner. It does not
    /// repeat on every subsequent tick of the same outage. If the outage
    /// resolves on its own (a fresh Pong lands before `deadAfter`),
    /// `onMissRecovered` fires once so the caller can clear that banner
    /// without ever going through the full dead/reconnect path. Both
    /// default to `nil` so existing callers that only care about
    /// `onDead` are source-compatible and unaffected.
    public func startHeartbeat(
        intervalSeconds: TimeInterval = 10,
        deadAfterSeconds: TimeInterval = 30,
        onFirstMiss: (@Sendable () -> Void)? = nil,
        onMissRecovered: (@Sendable () -> Void)? = nil,
        onDead: @escaping @Sendable () -> Void
    ) {
        heartbeatTask?.cancel()
        let nowUptime = ProcessInfo.processInfo.systemUptime
        lastPongUptime = nowUptime
        lastInboundUptime = nowUptime
        missNotified = false
        pongSeenSinceLastTick = true
        let intervalNs = UInt64(max(intervalSeconds, 0.1) * 1_000_000_000)
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                guard let self else { return }
                let result = await self.tickHeartbeat(deadAfterSeconds: deadAfterSeconds)
                switch result {
                case .dead:
                    onDead()
                    return
                case .firstMiss:
                    onFirstMiss?()
                case .recovered:
                    onMissRecovered?()
                case .alive:
                    break
                }
            }
        }
        startInboundPumpIfNeeded()
    }

    /// Cancel any in-flight heartbeat task. Safe to call multiple
    /// times and from teardown paths.
    public func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Outcome of a single heartbeat tick, folding the P6 first-miss/
    /// recovered edge detection in alongside the original alive/dead
    /// check.
    private enum HeartbeatTick {
        case alive
        case firstMiss
        case recovered
        case dead
    }

    private func tickHeartbeat(deadAfterSeconds: TimeInterval) async -> HeartbeatTick {
        // Only declare the session dead when BOTH the last processed Pong AND
        // the last inbound bytes are older than the deadline. A sustained
        // host→client flood blocks the pump loop from *processing* the Pong in
        // time, but bytes are still arriving, so `lastInboundUptime` stays fresh —
        // backpressure no longer false-positives as death (which used to send a
        // Goodbye and close a perfectly healthy relay pane). Awake-time also
        // prevents a local Mac sleep from counting as remote host silence.
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if nowUptime - lastPongUptime > deadAfterSeconds
            && nowUptime - lastInboundUptime > deadAfterSeconds {
            return .dead
        }
        var result: HeartbeatTick = .alive
        if pongSeenSinceLastTick {
            if missNotified {
                missNotified = false
                result = .recovered
            }
        } else if !missNotified {
            missNotified = true
            result = .firstMiss
        }
        pongSeenSinceLastTick = false
        pingCounter &+= 1
        let nonce = pingCounter
        do {
            try await sendEnvelope { env in
                var p = Termmesh_Peer_V1_Ping()
                p.nonce = nonce
                env.ping = p
            }
            return result
        } catch {
            return .dead
        }
    }

    // MARK: - Handshake

    @discardableResult
    public func handshake(options: PeerSessionOptions = .init()) async throws -> PeerSessionInfo {
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendHello(options: options)
        let host = try await expectHello()
        if majorComponent(of: host.protocolVersion) != majorComponent(of: options.clientProtocolVersion) {
            throw PeerSessionError.protocolVersionMismatch(
                host: host.protocolVersion,
                client: options.clientProtocolVersion
            )
        }
        _ = try await expectAuthChallenge()
        try await sendAuth(method: options.authMethod)
        let result = try await expectAuthResult()
        let hostCapabilities = PeerCapabilities(host.capabilities)
        negotiatedHostCapabilities = hostCapabilities
        return PeerSessionInfo(
            hostDisplayName: host.displayName,
            hostAppVersion: host.appVersion,
            hostProtocolVersion: host.protocolVersion,
            sessionID: result.sessionID,
            hostCapabilities: hostCapabilities,
            hostCLIBinDirs: hostCapabilities.has(PeerCapability.hostCLIBinDirsV1)
                ? PeerHostCLIBinDirs.validated(host.cliBinDirs)
                : [],
            // Absolute or nothing: a relative path would be resolved against
            // whatever directory the reader happens to be in, on a machine that
            // is not the one that sent it.
            sessionHostSocketPath: host.sessionHostSocket.hasPrefix("/")
                ? host.sessionHostSocket
                : ""
        )
    }

    // MARK: - ListSurfaces

    public func listSurfaces() async throws -> [Termmesh_Peer_V1_SurfaceInfo] {
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            env.listSurfaces = Termmesh_Peer_V1_ListSurfaces()
        }
        let reply = try await readFrame()
        guard case .surfaceList(let list) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return list.surfaces
    }

    /// Layout-preserving discovery — host returns its workspaces (tabs)
    /// each carrying a recursive split tree. Hosts that don't expose
    /// layouts return an empty list, in which case the caller should
    /// fall back to per-surface attach.
    public func listWorkspaces(
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> [Termmesh_Peer_V1_Workspace] {
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            env.listWorkspaces = Termmesh_Peer_V1_ListWorkspaces()
        }
        let reply: Termmesh_Peer_V1_Envelope
        if let timeoutSeconds {
            reply = try await readFrame(
                timeoutSeconds: timeoutSeconds,
                operation: "listWorkspaces"
            )
        } else {
            reply = try await readFrame()
        }
        guard case .workspaceList(let list) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return list.workspaces
    }

    /// Opt into host-pushed complete workspace rosters. This is deliberately
    /// write-only: the first `WorkspaceListChanged` arrives on the normal
    /// receive stream, preserving the session's single-reader invariant.
    /// Call only after `handshake()` and before starting the receive loop.
    public func subscribeWorkspaceList() async throws {
        try await sendEnvelope { env in
            env.subscribeWorkspaceList = Termmesh_Peer_V1_SubscribeWorkspaceList()
        }
    }

    /// The agent teams this host is running, when it advertised
    /// `team.roster.v1`. A team is invisible in the layout tree — which pane
    /// leads which work is not a fact about how panes are arranged — so this
    /// is the only way to learn where a project's leader sits on a machine
    /// that is not this one.
    ///
    /// Same single-reader contract as `listWorkspaces()`: it reads exactly
    /// one reply frame, so never call it on a session whose receive loop is
    /// already running.
    public func listTeams(
        timeoutSeconds: TimeInterval = 10
    ) async throws -> [Termmesh_Peer_V1_Team] {
        try requireHostCapability(PeerCapability.teamRosterV1)
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            env.listTeams = Termmesh_Peer_V1_ListTeams()
        }
        let reply = try await readFrame(
            timeoutSeconds: timeoutSeconds,
            operation: "listTeams"
        )
        guard case .teamList(let list) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return list.teams
    }

    /// Publish a complete project → surface manifest to the daemon that owns
    /// those surfaces. The first authenticated installation becomes owner;
    /// other viewers can discover the manifest through `listTeams()` but
    /// cannot overwrite it.
    public func upsertProjectPresentation(
        _ project: Termmesh_Peer_V1_Team,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> Termmesh_Peer_V1_UpsertProjectPresentationResponse {
        try requireHostCapability(PeerCapability.projectPresentationV1)
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        var request = Termmesh_Peer_V1_UpsertProjectPresentationRequest()
        request.requestID = Self.makeEnsureRequestID()
        request.project = project
        try await sendEnvelope { env in
            env.upsertProjectPresentationRequest = request
        }
        let reply = try await readFrame(
            timeoutSeconds: timeoutSeconds,
            operation: "upsertProjectPresentation"
        )
        guard case .upsertProjectPresentationResponse(let response) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return response
    }

    /// Remove a durable project manifest owned by this installation.
    public func deleteProjectPresentation(
        projectID: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> Termmesh_Peer_V1_UpsertProjectPresentationResponse {
        try requireHostCapability(PeerCapability.projectPresentationV1)
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        var request = Termmesh_Peer_V1_UpsertProjectPresentationRequest()
        request.requestID = Self.makeEnsureRequestID()
        request.deleteProjectID = projectID
        try await sendEnvelope { env in
            env.upsertProjectPresentationRequest = request
        }
        let reply = try await readFrame(
            timeoutSeconds: timeoutSeconds,
            operation: "deleteProjectPresentation"
        )
        guard case .upsertProjectPresentationResponse(let response) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return response
    }

    /// Run one allow-listed `team.*` method on the host and get its JSON
    /// result. Same single-reader contract as `listTeams()`.
    ///
    /// A refusal comes back as a normal response with `ok == false` and
    /// `error_code == method_not_allowed`, not as a transport error: the
    /// host declining is information, not a broken connection.
    public func callTeam(
        method: String,
        paramsJSON: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> Termmesh_Peer_V1_TeamCallResponse {
        try requireHostCapability(PeerCapability.teamCallV1)
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            var request = Termmesh_Peer_V1_TeamCallRequest()
            request.method = method
            request.paramsJson = paramsJSON
            env.teamCallRequest = request
        }
        let reply = try await readFrame(
            timeoutSeconds: timeoutSeconds,
            operation: "callTeam"
        )
        guard case .teamCallResponse(let response) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return response
    }

    /// Request project-bound leader bootstrap from the authoritative host.
    ///
    /// The signature mirrors the wire contract on purpose: callers cannot
    /// supply a cwd, executable, CLI, arguments or environment. The host
    /// resolves all of those from its registered `projectID`.
    public func bootstrapTeamLeader(
        projectID: String,
        placement: Termmesh_Peer_V1_TeamLeaderPlacement,
        requestID: Data,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> Termmesh_Peer_V1_TeamLeaderBootstrapResponse {
        try requireHostCapability(PeerCapability.teamLeaderV1)
        var request = Termmesh_Peer_V1_TeamLeaderBootstrapRequest()
        request.projectID = projectID
        request.leaderPlacement = placement
        request.requestID = requestID
        guard case .success = PeerTeamLeader.validateBootstrap(request) else {
            throw PeerSessionError.invalidTeamLeaderBootstrap(
                "project_id, leader_placement or request_id is invalid"
            )
        }

        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            env.teamLeaderBootstrapRequest = request
        }
        let reply = try await readFrame(
            timeoutSeconds: timeoutSeconds,
            operation: "bootstrapTeamLeader"
        )
        guard case .teamLeaderBootstrapResponse(let response) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return response
    }

    /// Send one grant-scoped command back to the authoritative team owner.
    /// The request cannot name a cwd, process or leader lifecycle method.
    public func callTeamLeader(
        grant: Termmesh_Peer_V1_TeamLeaderGrant,
        teamUUID: String,
        requestID: Data,
        method: String,
        paramsJSON: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> Termmesh_Peer_V1_TeamLeaderCommandResponse {
        try requireHostCapability(PeerCapability.teamLeaderV1)
        var request = Termmesh_Peer_V1_TeamLeaderCommandRequest()
        request.grant = grant
        request.teamUuid = teamUUID
        request.requestID = requestID
        request.method = method
        request.paramsJson = paramsJSON
        let encodedBytes = (try? request.serializedData().count)
            ?? (PeerTeamLeader.maxCommandPayloadBytes + 1)
        guard case .success = PeerTeamLeader.validateCommand(
            request,
            registeredGrant: grant,
            encodedBytes: encodedBytes,
            // The server owns expiry because only it can see and renew the
            // uptime-based lease. This preflight checks command shape only.
            nowUnixSeconds: 0
        ) else {
            throw PeerSessionError.invalidTeamLeaderCommand(
                "grant, team_uuid, request_id, method or params_json is invalid"
            )
        }

        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            env.teamLeaderCommandRequest = request
        }
        let reply = try await readFrame(
            timeoutSeconds: timeoutSeconds,
            operation: "callTeamLeader"
        )
        guard case .teamLeaderCommandResponse(let response) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return response
    }

    // MARK: - Workspace lifecycle (create / rename / delete)

    /// Ask the host to create a new, initially pane-less workspace and
    /// wait for its `CreateWorkspaceResponse`. This is a response-waiting
    /// RPC like `listWorkspaces()` above — it reads exactly one reply
    /// frame off the wire, so it must only be called on a session whose
    /// receive loop is NOT already running (single-reader invariant; see
    /// the file header of `PeerWorkspaceMirrorController`). Intended for
    /// a one-shot connection (e.g. the sidebar's "New Workspace" action),
    /// never on a live workspace-mirror subscription session.
    ///
    /// Returns the host-assigned workspace id on success.
    public func createWorkspace(
        title: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> Data {
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_CreateWorkspaceRequest()
            req.title = title
            env.createWorkspaceRequest = req
        }
        let reply = try await readFrame(
            timeoutSeconds: timeoutSeconds,
            operation: "createWorkspace"
        )
        guard case .createWorkspaceResponse(let r) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(
                "expected CreateWorkspaceResponse, got \(String(describing: reply.payload))"
            )
        }
        if !r.accepted {
            throw PeerSessionError.createWorkspaceRejected(reason: r.reason)
        }
        return r.workspaceID
    }

    /// Ask the host to rename an existing workspace. Fire-and-forget, like
    /// the WorkspaceControl requests below — there is no dedicated
    /// response; callers observe the rename via a subsequent
    /// `listWorkspaces()` or the sidebar's own refresh.
    public func renameWorkspace(workspaceID: Data, title: String) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_RenameWorkspaceRequest()
            req.workspaceID = workspaceID
            req.title = title
            env.renameWorkspaceRequest = req
        }
    }

    /// Ask the host to delete an existing workspace. Fire-and-forget; the
    /// host pushes `WorkspaceUpdate.workspaceRemoved` to every attached
    /// client (including this one, if subscribed) once the delete lands.
    public func deleteWorkspace(workspaceID: Data) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_DeleteWorkspaceRequest()
            req.workspaceID = workspaceID
            env.deleteWorkspaceRequest = req
        }
    }

    /// Ask the host to split a pane. Fire-and-forget; the new layout
    /// arrives via the next `WorkspaceLayoutChanged` push.
    public func requestSplitPane(paneID: Data, orientation: String) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_SplitPaneRequest()
            req.paneID = paneID
            req.orientation = orientation
            var ctl = Termmesh_Peer_V1_WorkspaceControl()
            ctl.splitPane = req
            env.workspaceControl = ctl
        }
    }

    /// Ask the host to close a pane. Fire-and-forget.
    public func requestClosePane(paneID: Data) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_ClosePaneRequest()
            req.paneID = paneID
            var ctl = Termmesh_Peer_V1_WorkspaceControl()
            ctl.closePane = req
            env.workspaceControl = ctl
        }
    }

    /// Ask the host to move keyboard focus to a pane. Fire-and-forget.
    public func requestFocusPane(paneID: Data) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_FocusPaneRequest()
            req.paneID = paneID
            var ctl = Termmesh_Peer_V1_WorkspaceControl()
            ctl.focusPane = req
            env.workspaceControl = ctl
        }
    }

    /// Ask the host to update a split's divider ratio. Fire-and-forget;
    /// the resulting layout flows back via WorkspaceLayoutChanged.
    ///
    /// `workspaceID` disambiguates `splitID`, which is only unique WITHIN
    /// a workspace's tree (each LayoutStore has its own counter) — pass
    /// `Data()` only for legacy callers that don't know their workspace id;
    /// the host falls back to first-match (single-workspace behavior).
    public func requestSetDivider(workspaceID: Data, splitID: Data, ratio: Double) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_SetDividerPositionRequest()
            req.workspaceID = workspaceID
            req.splitID = splitID
            req.ratio = ratio
            var ctl = Termmesh_Peer_V1_WorkspaceControl()
            ctl.setDivider = req
            env.workspaceControl = ctl
        }
    }

    /// Ask the host to create a new terminal tab inside the bonsplit
    /// pane that owns this surface. Fire-and-forget.
    public func requestNewTab(paneID: Data) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_NewTabRequest()
            req.paneID = paneID
            var ctl = Termmesh_Peer_V1_WorkspaceControl()
            ctl.newTab = req
            env.workspaceControl = ctl
        }
    }

    /// Seed the first pane of an EMPTY workspace: the same fire-and-
    /// forget NewTab write, targeted by workspace id instead of an
    /// existing pane (multi-workspace hosts spawn an ephemeral shell;
    /// older hosts ignore the unknown field — F8).
    public func requestNewTab(workspaceID: Data) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_NewTabRequest()
            req.workspaceID = workspaceID
            var ctl = Termmesh_Peer_V1_WorkspaceControl()
            ctl.newTab = req
            env.workspaceControl = ctl
        }
    }

    /// Ask the host to switch the active tab in the bonsplit pane
    /// hosting `paneID` to the tab whose surface is `surfaceID`.
    /// Fire-and-forget; the host pushes the resulting layout via
    /// `WorkspaceLayoutChanged`.
    public func requestActivateTab(paneID: Data, surfaceID: Data) async throws {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_ActivateTabRequest()
            req.paneID = paneID
            req.surfaceID = surfaceID
            var ctl = Termmesh_Peer_V1_WorkspaceControl()
            ctl.activateTab = req
            env.workspaceControl = ctl
        }
    }

    // MARK: - AttachSurface

    /// Reconcile one logical runner key to a daemon-owned PTY. Calls may run
    /// concurrently: request ids, not arrival order, select the continuation.
    ///
    /// `kind` selects what the daemon spawns behind the key: empty (or
    /// `"terminal"`) is the PTY that predates the field, `"agent"` is a
    /// non-PTY `tm-agent-bridge` child whose stdout is NDJSON. It is passed
    /// through verbatim rather than validated here — the daemon refuses an
    /// unknown value with INVALID_REQUEST, and duplicating the vocabulary on
    /// this side would only add a second place to forget to update.
    public func ensureSurface(
        requestID suppliedRequestID: Data? = nil,
        key: String,
        cwd: String,
        executable: String,
        args: [String] = [],
        restartPolicy: Termmesh_Peer_V1_EnsureSurfaceRestartPolicy = .never,
        kind: String = "",
        environment: [String: String] = [:]
    ) async throws -> PeerEnsureSurfaceOutcome {
        if let inboundTerminalError { throw inboundTerminalError }
        guard !directResponseRPCInFlight else {
            throw PeerSessionError.concurrentReceiveOperation
        }
        let requestID = suppliedRequestID ?? Self.makeEnsureRequestID()
        try Self.validateEnsureRequest(
            requestID: requestID,
            key: key,
            cwd: cwd,
            executable: executable,
            args: args,
            restartPolicy: restartPolicy,
            environment: environment
        )

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await performEnsureSurface(
                requestID: requestID,
                key: key,
                cwd: cwd,
                executable: executable,
                args: args,
                restartPolicy: restartPolicy,
                kind: kind,
                environment: environment
            )
        } onCancel: {
            Task { await self.cancelEnsure(requestID: requestID) }
        }
    }

    private func performEnsureSurface(
        requestID: Data,
        key: String,
        cwd: String,
        executable: String,
        args: [String],
        restartPolicy: Termmesh_Peer_V1_EnsureSurfaceRestartPolicy,
        kind: String,
        environment: [String: String]
    ) async throws -> PeerEnsureSurfaceOutcome {
        guard activeEnsureRequestIDs.insert(requestID).inserted else {
            throw PeerSessionError.duplicateEnsureRequestID
        }
        let responses: AsyncThrowingStream<Termmesh_Peer_V1_EnsureSurfaceResponse, Error>
        do {
            responses = try await demux.registerEnsure(requestID: requestID)
            try await sendEnsureRequest(
                requestID: requestID,
                key: key,
                cwd: cwd,
                executable: executable,
                args: args,
                restartPolicy: restartPolicy,
                kind: kind,
                environment: environment
            )
        } catch {
            activeEnsureRequestIDs.remove(requestID)
            await demux.failEnsure(requestID: requestID, error: error)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        startInboundPumpIfNeeded()

        let response: Termmesh_Peer_V1_EnsureSurfaceResponse
        do {
            var iterator = responses.makeAsyncIterator()
            guard let next = try await iterator.next() else {
                throw CancellationError()
            }
            response = next
        } catch {
            activeEnsureRequestIDs.remove(requestID)
            if Task.isCancelled {
                await cancelEnsure(requestID: requestID)
                throw CancellationError()
            }
            throw error
        }
        return PeerEnsureSurfaceOutcome(
            requestID: response.requestID,
            result: response.result,
            surfaceID: response.surfaceID,
            instanceID: response.instanceID,
            generation: response.generation,
            pid: response.pid,
            specHash: response.specHash,
            error: response.hasError ? response.error : nil
        )
    }

    private func cancelEnsure(requestID: Data) async {
        activeEnsureRequestIDs.remove(requestID)
        await demux.cancelEnsure(requestID: requestID)
        // A cancelled write closure is not guaranteed to observe cooperative
        // Task cancellation. Close the whole transport even when sibling
        // ensures exist so the suspended write and every waiter terminate.
        await terminateInbound(with: PeerSessionError.sessionClosed(reason: "request cancelled"))
    }

    private func startInboundPumpIfNeeded() {
        guard inboundPumpTask == nil, inboundTerminalError == nil else { return }
        inboundPumpTask = Task { [weak self] in
            await self?.runInboundPump()
        }
    }

    private func runInboundPump() async {
        while !Task.isCancelled {
            guard heartbeatTask != nil
                    || !activeEnsureRequestIDs.isEmpty
                    || !incomingWaiters.isEmpty else {
                inboundPumpTask = nil
                return
            }
            let envelope: Termmesh_Peer_V1_Envelope
            do {
                guard !directResponseRPCInFlight else {
                    inboundPumpTask = nil
                    return
                }
                inboundReadInProgress = true
                // The pump is the one reader that wants everything: pushes
                // are precisely what it exists to deliver, so it must not
                // use the reply-shaped read that filters them out.
                envelope = try await readAnyFrame()
                inboundReadInProgress = false
            } catch {
                inboundReadInProgress = false
                await terminateInbound(with: error)
                return
            }

            if case .ensureSurfaceResponse(let response) = envelope.payload {
                if response.requestID.count == 16 {
                    activeEnsureRequestIDs.remove(response.requestID)
                } else {
                    activeEnsureRequestIDs.removeAll()
                }
                await demux.routeEnsureResponse(response)
                continue
            }

            let message = classifyIncoming(envelope)
            if let key = incomingWaiters.keys.first,
               let continuation = incomingWaiters.removeValue(forKey: key) {
                continuation.resume(returning: message)
            } else {
                bufferIncoming(message)
            }
            if case .goodbye(let reason) = message {
                await terminateInbound(with: PeerSessionError.sessionClosed(reason: reason))
                return
            }
        }
    }

    /// Bound PTY backlog without sacrificing control messages. Dropping an old
    /// PtyData frame is observable through the protocol byte sequence, so the
    /// relay's existing gap/resume path can repair it. Pong is consumed above
    /// and never reaches this buffer; errors/goodbye/layout pushes are retained.
    ///
    /// The cap is enforced on arrival of *any* message, not only PtyData:
    /// gating it on the incoming type meant a run of control messages could
    /// push the buffer past the limit unchecked, which is the unbounded growth
    /// the cap exists to prevent.
    private func bufferIncoming(_ message: PeerIncomingMessage) {
        Self.appendBufferedIncoming(message, to: &bufferedIncomingMessages)
    }

    /// Internal pure seam for the queue policy. The receive actor calls this
    /// synchronously; tests can exercise thousands of control frames without
    /// manufacturing a live socket and heartbeat pump.
    static func appendBufferedIncoming(
        _ message: PeerIncomingMessage,
        to bufferedIncomingMessages: inout [PeerIncomingMessage]
    ) {
        // Complete rosters are replacement values. Keeping an older one has
        // no semantic value and can retain a full recursive workspace tree.
        if case .workspaceListChanged = message,
           let olderSnapshot = bufferedIncomingMessages.firstIndex(where: {
               if case .workspaceListChanged = $0 { return true }
               return false
           }) {
            bufferedIncomingMessages.remove(at: olderSnapshot)
        }

        if bufferedIncomingMessages.count >= Self.maxBufferedIncomingMessages {
            let oldestPty = bufferedIncomingMessages.firstIndex(where: {
               if case .ptyData = $0 { return true }
               return false
            })
            // Preserve terminal errors/goodbye when possible, but the hard
            // count bound is non-negotiable: a control-only stream must not
            // turn a slow UI consumer into unbounded process memory.
            let oldestDroppableControl = bufferedIncomingMessages.firstIndex(where: {
                switch $0 {
                case .error, .goodbye: return false
                default: return true
                }
            })
            bufferedIncomingMessages.remove(
                at: oldestPty ?? oldestDroppableControl ?? bufferedIncomingMessages.startIndex
            )
        }
        bufferedIncomingMessages.append(message)
    }

    private func terminateInbound(with error: Error) async {
        guard inboundTerminalError == nil else { return }
        let task = inboundPumpTask
        inboundPumpTask = nil
        inboundTerminalError = error
        activeEnsureRequestIDs.removeAll()
        await demux.failAllEnsures(error: error)
        let waiters = incomingWaiters.values
        incomingWaiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: error)
        }
        task?.cancel()
        if !didCloseTransport {
            didCloseTransport = true
            await closeTransport?()
        }
    }

    private func sendEnsureRequest(
        requestID: Data,
        key: String,
        cwd: String,
        executable: String,
        args: [String],
        restartPolicy: Termmesh_Peer_V1_EnsureSurfaceRestartPolicy,
        kind: String,
        environment: [String: String]
    ) async throws {
        try await sendEnvelope { env in
            var request = Termmesh_Peer_V1_EnsureSurfaceRequest()
            request.requestID = requestID
            request.key = key
            request.cwd = cwd
            request.executable = executable
            request.args = args
            request.restartPolicy = restartPolicy
            request.kind = kind
            request.env = environment
            env.ensureSurfaceRequest = request
        }
    }

    private static func makeEnsureRequestID() -> Data {
        var uuid = UUID().uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    private static func validateEnsureRequest(
        requestID: Data,
        key: String,
        cwd: String,
        executable: String,
        args: [String],
        restartPolicy: Termmesh_Peer_V1_EnsureSurfaceRestartPolicy,
        environment: [String: String]
    ) throws {
        guard requestID.count == 16 else {
            throw PeerSessionError.invalidEnsureRequest("request_id must be 16 bytes")
        }
        guard !key.isEmpty, key.utf8.count <= 256 else {
            throw PeerSessionError.invalidEnsureRequest("key must be 1...256 UTF-8 bytes")
        }
        guard !cwd.isEmpty, cwd.utf8.count <= 4096 else {
            throw PeerSessionError.invalidEnsureRequest("cwd must be 1...4096 UTF-8 bytes")
        }
        guard !executable.isEmpty, executable.utf8.count <= 4096 else {
            throw PeerSessionError.invalidEnsureRequest("executable must be 1...4096 UTF-8 bytes")
        }
        guard args.count <= 256, args.allSatisfy({ $0.utf8.count <= 65_536 }) else {
            throw PeerSessionError.invalidEnsureRequest("args exceed protocol limits")
        }
        do {
            try PeerEnsureEnvironment.validate(environment)
        } catch {
            throw PeerSessionError.invalidEnsureRequest(
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
        switch restartPolicy {
        case .never, .onDaemonRestart:
            break
        case .unspecified, .UNRECOGNIZED:
            throw PeerSessionError.invalidEnsureRequest("restart_policy must be recognized and specified")
        }
    }

    /// Remove one ensured surface from the host's registry, durable ensured
    /// state, and workspace layout.
    ///
    /// This is the only way to stop an *agent* surface: it is deliberately
    /// never placed in the workspace tree, so `requestClosePane` finds
    /// nothing and silently succeeds. NOT_FOUND is a success — the proto
    /// defines it as the idempotent outcome, which is what a cleanup path
    /// retrying after a dropped response needs.
    ///
    /// Shaped as a direct-response RPC, so it belongs on a connection with no
    /// ensure in flight and no inbound pump running (`beginDirectResponseRPC`
    /// rejects the rest) — in practice a connection opened for the teardown
    /// itself.
    @discardableResult
    public func terminateSurface(
        requestID suppliedRequestID: Data? = nil,
        surfaceID: Data
    ) async throws -> Termmesh_Peer_V1_TerminateSurfaceResult {
        try requireHostCapability(PeerCapability.surfaceTerminateV1)
        let requestID = suppliedRequestID ?? Self.makeEnsureRequestID()
        guard requestID.count == 16 else {
            throw PeerSessionError.invalidEnsureRequest("request_id must be 16 bytes")
        }
        guard surfaceID.count == 16 else {
            throw PeerSessionError.invalidEnsureRequest("surface_id must be 16 bytes")
        }
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            var request = Termmesh_Peer_V1_TerminateSurfaceRequest()
            request.requestID = requestID
            request.surfaceID = surfaceID
            env.terminateSurfaceRequest = request
        }
        let reply = try await readFrame()
        guard case .terminateSurfaceResponse(let response) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(
                "expected TerminateSurfaceResponse, got \(String(describing: reply.payload))"
            )
        }
        guard response.requestID == requestID else {
            throw PeerSessionError.malformedEnsureResponse("request_id does not echo the request")
        }
        return response.result
    }

    public func attachSurface(
        id: Data,
        mode: Termmesh_Peer_V1_AttachMode = .coWrite,
        cols: UInt32 = 80,
        rows: UInt32 = 24,
        resumeFromSeq: UInt64 = 0
    ) async throws -> PeerAttachOutcome {
        try beginDirectResponseRPC()
        defer { directResponseRPCInFlight = false }
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_AttachSurface()
            req.surfaceID = id
            req.mode = mode
            req.clientCols = cols
            req.clientRows = rows
            req.resumeFromSeq = resumeFromSeq
            env.attachSurface = req
        }
        let reply = try await readFrame()
        guard case .attachResult(let r) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(
                "expected AttachResult, got \(String(describing: reply.payload))"
            )
        }
        if !r.accepted {
            throw PeerSessionError.attachRejected(reason: r.reason)
        }
        return PeerAttachOutcome(
            surfaceID: r.surfaceID,
            initialByteSeq: r.initialSeq,
            grantedMode: r.grantedMode
        )
    }

    // MARK: - Post-attach I/O

    /// Read the next envelope from the host and classify it. Callers
    /// typically loop on this in a Task and route by case. Unhandled
    /// payload types collapse into `.other` so this surface stays stable
    /// as the protocol grows (Phase 2.4b's WorkspaceUpdate.meta is
    /// already surfaced here).
    public func receiveNextMessage() async throws -> PeerIncomingMessage {
        if !bufferedIncomingMessages.isEmpty {
            return bufferedIncomingMessages.removeFirst()
        }
        if let inboundTerminalError { throw inboundTerminalError }
        guard !directResponseRPCInFlight else {
            throw PeerSessionError.concurrentReceiveOperation
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                incomingWaiters[waiterID] = continuation
                startInboundPumpIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelIncomingWaiter(waiterID) }
        }
    }

    private func cancelIncomingWaiter(_ waiterID: UUID) async {
        let continuation = incomingWaiters.removeValue(forKey: waiterID)
        continuation?.resume(throwing: CancellationError())
        if continuation != nil, incomingWaiters.isEmpty, activeEnsureRequestIDs.isEmpty {
            await terminateInbound(with: PeerSessionError.sessionClosed(reason: "receive cancelled"))
        }
    }

    private func classifyIncoming(_ env: Termmesh_Peer_V1_Envelope) -> PeerIncomingMessage {
        switch env.payload {
        case .pong:
            // Liveness reply to a heartbeat Ping — refresh the timestamp
            // the heartbeat task checks, and mark a Pong as seen for the
            // P6 first-miss/recovered edge detection (see
            // `pongSeenSinceLastTick`). Surfaced to callers as `.other`
            // since they don't need to act on it.
            lastPongUptime = ProcessInfo.processInfo.systemUptime
            pongSeenSinceLastTick = true
            return .other
        case .ptyData(let p):
            return .ptyData(surfaceID: p.surfaceID, byteSeq: p.byteSeq, payload: p.payload)
        case .surfaceExited(let exited):
            return .surfaceExited(
                surfaceID: exited.surfaceID,
                exitCode: exited.exitCode,
                signal: exited.signal,
                reason: exited.reason
            )
        case .gridSnapshot(let g):
            return .gridSnapshot(
                surfaceID: g.surfaceID,
                byteSeq: g.byteSeq,
                altScreen: g.altScreen,
                ansi: g.ansi
            )
        case .scrollbackChunk(let c):
            return .scrollbackChunk(
                surfaceID: c.surfaceID,
                offsetRows: c.offsetRows,
                ansi: c.ansi,
                atTop: c.atTop,
                totalRows: c.totalScrollbackRows
            )
        case .workspaceUpdate(let wu):
            switch wu.kind {
            case .meta(let m):
                return .workspaceMeta(
                    cwd: m.cwd,
                    branch: m.branch,
                    ports: m.ports,
                    latestNotification: m.latestNotification
                )
            case .added(let a):
                return .workspaceSurfaceAdded(a.surface)
            case .removed(let r):
                return .workspaceSurfaceRemoved(surfaceID: r.surfaceID)
            case .retitled(let rt):
                return .workspaceSurfaceRetitled(surfaceID: rt.surfaceID, title: rt.title)
            case .workspaceLayout(let wl):
                return .workspaceLayoutChanged(workspaceID: wl.workspaceID, layout: wl.layout)
            case .workspaceRemoved(let wr):
                return .workspaceRemoved(workspaceID: wr.workspaceID)
            default:
                return .other
            }
        case .workspaceListChanged(let changed):
            return .workspaceListChanged(changed.workspaces)
        case .hostStats(let s):
            return .hostStats(s)
        case .teamLeaderCommandRequest(let request):
            return .teamLeaderCommandRequest(request, correlationID: env.seq)
        case .error(let e):
            return .error(code: e.code, message: e.message)
        case .goodbye(let g):
            return .goodbye(reason: g.reason)
        default:
            return .other
        }
    }

    /// Send raw keystrokes to an attached surface. `keys` is the bytes the
    /// child would see on its stdin (the caller is responsible for any
    /// terminal escape encoding).
    /// Ask the host to render the scrollback window whose bottom sits
    /// `offsetRows` above the live view (0 = the live screen, i.e. the
    /// browse-exit render). Reply arrives as `.scrollbackChunk`. Gated
    /// host-side on grid.snapshot.v1 — a legacy host ignores it.
    public func requestScrollback(surfaceID: Data, offsetRows: UInt32) async throws {
        try await sendEnvelope { env in
            var r = Termmesh_Peer_V1_ScrollbackRequest()
            r.surfaceID = surfaceID
            r.offsetRows = offsetRows
            env.scrollbackRequest = r
        }
    }

    public nonisolated func sendInput(surfaceID: Data, keys: Data) async throws {
        var input = Termmesh_Peer_V1_Input()
        input.surfaceID = surfaceID
        input.kind = .keys(keys)
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.input = input
        try await outbound.send(envelope)
    }

    /// Answer a reverse scoped-leader request on the same authenticated peer
    /// session. This does not expose an app socket to the remote process.
    public func sendTeamLeaderCommandResponse(
        _ response: Termmesh_Peer_V1_TeamLeaderCommandResponse,
        correlationID: UInt64
    ) async throws {
        var env = Termmesh_Peer_V1_Envelope()
        env.correlationID = correlationID
        env.teamLeaderCommandResponse = response
        try await outbound.send(env)
    }

    /// Paste a block of text as a single Input frame.
    public func sendPaste(surfaceID: Data, text: Data) async throws {
        try await sendEnvelope { env in
            var input = Termmesh_Peer_V1_Input()
            input.surfaceID = surfaceID
            var paste = Termmesh_Peer_V1_Paste()
            paste.text = text
            input.kind = .paste(paste)
            env.input = input
        }
    }

    public func sendResize(
        surfaceID: Data,
        cols: UInt32,
        rows: UInt32,
        claimAuthority: Bool = false
    ) async throws {
        try await sendEnvelope { env in
            var r = Termmesh_Peer_V1_Resize()
            r.surfaceID = surfaceID
            r.cols = cols
            r.rows = rows
            r.claimAuthority = claimAuthority
            env.resize = r
        }
    }

    // MARK: - Goodbye

    public func sendGoodbye(reason: String) async throws {
        try await sendEnvelope { env in
            var gb = Termmesh_Peer_V1_Goodbye()
            gb.reason = reason
            env.goodbye = gb
        }
        await terminateInbound(with: PeerSessionError.unexpectedEof)
    }

    /// Stop the single inbound reader and close its transport. Supplying a
    /// `close` callback backed by `UnixSocketTransport.close()` is what turns
    /// task cancellation into an actual unblock of Network.framework receive.
    public func close(reason: String = "client closed") async {
        await terminateInbound(with: PeerSessionError.sessionClosed(reason: reason))
    }

    // MARK: - Private: envelope plumbing

    private func beginDirectResponseRPC() throws {
        if let inboundTerminalError { throw inboundTerminalError }
        guard !directResponseRPCInFlight,
              activeEnsureRequestIDs.isEmpty,
              incomingWaiters.isEmpty,
              !inboundReadInProgress else {
            throw PeerSessionError.concurrentReceiveOperation
        }
        directResponseRPCInFlight = true
    }

    private func sendEnvelope(configure: (inout Termmesh_Peer_V1_Envelope) -> Void) async throws {
        var env = Termmesh_Peer_V1_Envelope()
        configure(&env)
        try await outbound.send(env)
    }

    private func sendHello(options: PeerSessionOptions) async throws {
        try await sendEnvelope { env in
            var hello = Termmesh_Peer_V1_Hello()
            hello.protocolVersion = options.clientProtocolVersion
            hello.peerID = options.peerID
            hello.projectOwnerAliases = Array(options.projectOwnerAliases.prefix(PeerIdentity.historyLimit))
            hello.displayName = options.displayName
            hello.appVersion = options.appVersion
            hello.capabilities = options.capabilities
            env.hello = hello
        }
    }

    private func sendAuth(method: String) async throws {
        try await sendEnvelope { env in
            var auth = Termmesh_Peer_V1_Auth()
            auth.method = method
            env.auth = auth
        }
    }

    private func expectHello() async throws -> Termmesh_Peer_V1_Hello {
        let env = try await readFrame()
        guard case .hello(let h) = env.payload else {
            throw PeerSessionError.unexpectedMessage("expected Hello, got \(String(describing: env.payload))")
        }
        return h
    }

    private func expectAuthChallenge() async throws -> Termmesh_Peer_V1_AuthChallenge {
        let env = try await readFrame()
        guard case .authChallenge(let c) = env.payload else {
            throw PeerSessionError.unexpectedMessage("expected AuthChallenge, got \(String(describing: env.payload))")
        }
        return c
    }

    private func expectAuthResult() async throws -> Termmesh_Peer_V1_AuthResult {
        let env = try await readFrame()
        guard case .authResult(let r) = env.payload else {
            throw PeerSessionError.unexpectedMessage("expected AuthResult, got \(String(describing: env.payload))")
        }
        if !r.accepted {
            throw PeerSessionError.authRejected(reason: r.reason)
        }
        return r
    }

    /// The next frame, skipping host-initiated pushes that no request asked
    /// for.
    ///
    /// Every caller here is waiting for one specific reply and rejects
    /// anything else, which was safe only while the host spoke solely when
    /// spoken to. `HostStats` breaks that: it arrives on its own schedule,
    /// so without this any RPC unlucky enough to be in flight when a sample
    /// landed would fail with "unexpected message" — including the surface
    /// listing behind the pane picker, which made a host unreachable
    /// outright.
    ///
    /// One-shot direct-response connections have no push consumer. Drop the
    /// host's telemetry and workspace roster/layout pushes while waiting for
    /// the requested reply; these can race a response immediately after a
    /// split or new-tab request. An `Error` frame and reverse leader request
    /// still surface rather than disappearing here.
    private func readFrame() async throws -> Termmesh_Peer_V1_Envelope {
        while true {
            let env = try await readAnyFrame()
            switch env.payload {
            case .hostStats, .workspaceUpdate, .workspaceListChanged:
                continue
            default:
                return env
            }
        }
    }

    private func requireHostCapability(_ capability: String) throws {
        guard negotiatedHostCapabilities?.has(capability) == true else {
            throw PeerSessionError.capabilityNotNegotiated(capability)
        }
    }

    private func readFrame(
        timeoutSeconds: TimeInterval,
        operation: String
    ) async throws -> Termmesh_Peer_V1_Envelope {
        let gate = PeerRPCResultGate<Termmesh_Peer_V1_Envelope>()
        let reader = Task {
            do { await gate.resolve(.success(try await self.readFrame())) }
            catch { await gate.resolve(.failure(error)) }
        }
        let timer = Task {
            // Keep conversion total: NaN/infinity and huge values must not
            // trap while constructing UInt64. Invalid values time out now;
            // valid waits are capped at one day, well above every RPC default.
            let boundedSeconds = timeoutSeconds.isFinite
                ? min(max(0, timeoutSeconds), 86_400)
                : 0
            let nanoseconds = UInt64(boundedSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            let error = PeerSessionError.rpcTimedOut(operation: operation)
            if await gate.resolve(.failure(error)) {
                await self.terminateInbound(with: error)
            }
        }
        defer {
            reader.cancel()
            timer.cancel()
        }
        return try await gate.wait()
    }

    private func readAnyFrame() async throws -> Termmesh_Peer_V1_Envelope {
        while true {
            do {
                if let env = try decodeFrame(from: &pendingInbound) {
                    return env
                }
            } catch let err as PeerFramingError {
                throw PeerSessionError.framing(err)
            }
            let chunk = try await read()
            if chunk.isEmpty {
                throw PeerSessionError.unexpectedEof
            }
            pendingInbound.append(chunk)
            // Inbound liveness: any bytes from the host prove the session is
            // alive, even when the pump loop is too backpressured to reach the
            // Pong buried behind a PtyData flood. See `tickHeartbeat`.
            lastInboundUptime = ProcessInfo.processInfo.systemUptime
        }
    }
}

private func majorComponent(of semver: String) -> Substring {
    semver.split(separator: ".").first ?? Substring(semver)
}
