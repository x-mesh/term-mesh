//  Swift-side peer-federation server — mirrors the Rust
//  daemon/term-meshd/src/peer module. term-mesh.app uses this to
//  expose its own PTYs as attachable surfaces for remote clients.
//
//  Phase C-3c.3.1: listener + handshake + ListSurfaces only. Attach
//  and PtyData streaming land in C-3c.3.2; wiring real panes into the
//  surface provider comes in C-3c.3.3+.
//
//  Transport uses POSIX `socket(AF_UNIX) + bind + listen + accept`
//  because Apple's `NWListener` public API does not expose Unix-domain
//  server sockets. Per-connection byte I/O runs through DispatchIO so
//  there's no blocking thread per client.

#if canImport(Darwin)
import Darwin
import Security
#endif
import Foundation
import Dispatch
import SwiftProtobuf

// Per-PeerServer cap on concurrent accepted client sessions. 16 is
// trivially exhausted in normal multi-workspace / multi-surface attach
// patterns; 64 leaves headroom while still bounding fd consumption.
// Combined with the per-process FD limit raised at app launch
// (see AppDelegate.raiseFileDescriptorLimit), this keeps peer
// attach churn well under the kernel's accept budget.
private let maxPeerServerSessions = 64

// MARK: - PeerSurfaceProvider

/// One host→client PTY chunk plus its offset in the producer's cumulative
/// byte stream. `seq` is the tap-relative offset of `bytes`' first byte.
///
/// Producers MUST advance their running offset for every byte that enters
/// the tap — including chunks a bounded stream buffer later drops — so
/// `pumpByteStream` can forward producer-side drops as `PtyData.byte_seq`
/// holes. Without this the wire seq stays contiguous across a drop and the
/// viewer's gap detection (P9, `PeerRelaySession.swift`) mathematically
/// never fires: silent truncation with no heal. A producer with no drop
/// path (e.g. `EchoSurfaceProvider`) just counts delivered bytes.
public struct PtyTapChunk: Sendable {
    public let bytes: Data
    public let seq: UInt64

    public init(bytes: Data, seq: UInt64) {
        self.bytes = bytes
        self.seq = seq
    }
}

/// Returned by `PeerSurfaceProvider.attach`. Carries the per-attach state
/// the server needs to pump bytes to the client and route client inputs
/// back to the surface's underlying byte producer (e.g. a PTY).
public struct PeerSurfaceAttachment: Sendable {
    /// Host → client byte stream. Each element is a chunk that becomes
    /// one `PtyData` frame (before P7 coalescing). The session continues
    /// until this stream finishes, then ends the attach from the server
    /// side. Chunk `seq` discontinuities are forwarded as wire `byte_seq`
    /// holes — see `PtyTapChunk`.
    public let byteStream: AsyncStream<PtyTapChunk>
    /// Client → host: raw keystroke bytes from an Input frame.
    public let input: @Sendable (Data) async -> Void
    /// Client → host: resize from a Resize frame (cols, rows).
    public let resize: @Sendable (UInt32, UInt32) async -> Void
    /// Optional initial `WorkspaceUpdate.meta` to push to the client
    /// right after the AttachResult. Mirrors Phase 2.4b on the Rust side.
    public let workspaceMeta: PeerWorkspaceMeta?
    /// Absolute host seq that this attach's wire `byte_seq == 0` maps to —
    /// what `PeerServerSession.handleAttach` reports back as
    /// `AttachResult.initialSeq` (R1, peer-relay-bulk-loss). Defaults to 0,
    /// which is exactly right for a provider with no persistent replay
    /// state of its own (`EchoSurfaceProvider`, `StaticSurfaceProvider`):
    /// their wire and absolute spaces coincide. `GhosttyPaneSurfaceProvider`
    /// reports its tap hub's real absolute seq here so a client can later
    /// translate a wire `byte_seq` it observed into the value it must send
    /// back as `AttachSurface.resumeFromSeq` — see
    /// `PeerServerSession.handleAttach`'s doc comment for the full mapping.
    public let initialByteSeq: UInt64
    /// Called by the session when the client detaches, the connection
    /// closes, or the session is shut down. Providers should stop
    /// yielding to `byteStream` and release per-attach resources.
    public let detach: @Sendable () async -> Void

    public init(
        byteStream: AsyncStream<PtyTapChunk>,
        input: @escaping @Sendable (Data) async -> Void,
        resize: @escaping @Sendable (UInt32, UInt32) async -> Void = { _, _ in },
        workspaceMeta: PeerWorkspaceMeta? = nil,
        initialByteSeq: UInt64 = 0,
        detach: @escaping @Sendable () async -> Void = {}
    ) {
        self.byteStream = byteStream
        self.input = input
        self.resize = resize
        self.workspaceMeta = workspaceMeta
        self.initialByteSeq = initialByteSeq
        self.detach = detach
    }
}

public struct PeerWorkspaceMeta: Sendable, Equatable {
    public let cwd: String
    public let branch: String
    public let ports: [UInt32]
    public let latestNotification: String

    public init(
        cwd: String = "",
        branch: String = "",
        ports: [UInt32] = [],
        latestNotification: String = ""
    ) {
        self.cwd = cwd
        self.branch = branch
        self.ports = ports
        self.latestNotification = latestNotification
    }
}

/// Supplies the server with the set of surfaces to advertise AND the
/// per-attach plumbing. term-mesh.app's real pane registry will
/// implement this in Phase C-3c.3.3; tests use `StaticSurfaceProvider`
/// for list-only scenarios and `EchoSurfaceProvider` for round-trip.
public protocol PeerSurfaceProvider: AnyObject, Sendable {
    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo]
    /// Return an attachment for `surfaceID`, or `nil` if unknown. The
    /// server sends an `AttachResult(accepted: false)` back to the
    /// client on `nil`.
    ///
    /// `resumeFromSeq`, when nonzero, asks the provider to replay only the
    /// tail of its buffered output starting at that absolute host seq
    /// instead of a full fresh snapshot (R1, peer-relay-bulk-loss) — see
    /// `PeerServerSession.handleAttach`'s doc comment for the wire↔host
    /// seq mapping this value lives in, and `PeerSurfaceAttachment
    /// .initialByteSeq` for the matching reply half. `handleAttach` has
    /// already gated this on the `replay.ring.v1` capability and on
    /// `AttachSurface.resumeFromSeq != 0` before calling — a provider with
    /// no partial-replay support of its own is free to ignore it and
    /// always return a full/fallback snapshot.
    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment?
    /// Layout-preserving discovery: enumerate the host's workspaces
    /// (tabs) plus their split tree. Default implementation returns an
    /// empty list, so providers that don't expose split layouts (Static,
    /// Echo) can ignore the call. Clients combine this with
    /// `listSurfaces` to attach every leaf in a workspace and place
    /// them in the same arrangement locally.
    func listWorkspaces() async -> [Termmesh_Peer_V1_Workspace]

    /// Fire-and-forget workspace mutation requests (split, close).
    /// Default no-op; providers that own a real workspace tree
    /// (`GhosttyPaneSurfaceProvider`) override to drive bonsplit. The
    /// resulting layout change is observable via the same
    /// `WorkspaceLayoutChanged` push path.
    func handleWorkspaceControl(_ control: Termmesh_Peer_V1_WorkspaceControl) async

    /// Create a workspace and return its host-assigned id. Returning `nil`
    /// rejects the request. Unlike rename/delete this is a paired RPC: the
    /// caller needs the id before it can address the new workspace.
    func createWorkspace(title: String) async -> Data?

    /// Rename an existing workspace in place; the id never changes.
    /// Returns `false` (no-op) for an empty or unknown `workspaceID` —
    /// mirrors the Rust host's `PeerHost::rename_workspace` contract
    /// of never guessing "the current" or "the default" workspace.
    /// Gated behind capability "workspace.lifecycle.v1". Default no-op
    /// for providers with no real workspace tree.
    func renameWorkspace(id workspaceID: Data, title: String) async -> Bool

    /// Delete an existing workspace: tears down every pane inside it
    /// and removes it from the roster. Returns `false` (no-op) for an
    /// empty or unknown `workspaceID` — same "never delete all/current"
    /// contract as `renameWorkspace`. Callers are responsible for
    /// broadcasting the resulting `WorkspaceRemoved` push (see
    /// `PeerServer.broadcastWorkspaceRemoved`); this method only
    /// mutates local state. Gated behind capability
    /// "workspace.lifecycle.v1". Default no-op for providers with no
    /// real workspace tree.
    func deleteWorkspace(id workspaceID: Data) async -> Bool

    /// The agent teams running on this host. A team is invisible in the
    /// layout tree — which pane leads which work is not a fact about how
    /// panes are arranged — so a client asking "where does this project's
    /// leader sit" has no other way to find out. Read-only: no command
    /// crosses this call. Gated behind capability "team.roster.v1"; the
    /// default empty list is what a provider with no teams reports. Team
    /// capabilities describe server support and remain advertised even when
    /// this snapshot is empty.
    func listTeams() async -> [Termmesh_Peer_V1_Team]

    /// Run one allow-listed `team.*` method and return its JSON result.
    /// The server checks `PeerTeamCall.isAllowed` BEFORE calling this, so a
    /// provider never sees a method outside the list — but a provider that
    /// reaches further than its own teams would defeat that check, so keep
    /// implementations routed through the same handler the local socket uses.
    /// Returning nil means the host has no team subsystem at all.
    func callTeamMethod(_ method: String, paramsJSON: String) async -> Result<String, PeerTeamCallFailure>?

    /// Resolve a project identifier to an already-created authoritative
    /// team UUID. This lookup must not create panes, activate the app or
    /// accept any executable configuration from the peer.
    func resolveTeamLeaderProject(_ projectID: String) async -> String?

    /// Dispatch a command after `PeerTeamLeaderControlPlane` validated its
    /// grant and team UUID. Implementations MUST overwrite any peer-supplied
    /// team name with the team resolved from `teamUUID`.
    func callScopedTeamLeaderMethod(
        _ method: String,
        paramsJSON: String,
        teamUUID: String
    ) async -> Result<String, PeerTeamCallFailure>?
}

/// Why a team call failed on the host side.
public struct PeerTeamCallFailure: Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public extension PeerSurfaceProvider {
    func listWorkspaces() async -> [Termmesh_Peer_V1_Workspace] { [] }
    func createWorkspace(title: String) async -> Data? { nil }
    func renameWorkspace(id workspaceID: Data, title: String) async -> Bool { false }
    func deleteWorkspace(id workspaceID: Data) async -> Bool { false }
    func handleWorkspaceControl(_ control: Termmesh_Peer_V1_WorkspaceControl) async {}
    func listTeams() async -> [Termmesh_Peer_V1_Team] { [] }
    func callTeamMethod(
        _ method: String,
        paramsJSON: String
    ) async -> Result<String, PeerTeamCallFailure>? { nil }
    func resolveTeamLeaderProject(_ projectID: String) async -> String? { nil }
    func callScopedTeamLeaderMethod(
        _ method: String,
        paramsJSON: String,
        teamUUID: String
    ) async -> Result<String, PeerTeamCallFailure>? { nil }
}

/// Provider for the list-only case: static surfaces, no attach support.
/// Attaching raises an `attachRejected` to the caller.
public actor StaticSurfaceProvider: PeerSurfaceProvider {
    private var surfaces: [Termmesh_Peer_V1_SurfaceInfo]

    public init(surfaces: [Termmesh_Peer_V1_SurfaceInfo]) {
        self.surfaces = surfaces
    }

    public func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] {
        surfaces
    }

    public func setSurfaces(_ newValue: [Termmesh_Peer_V1_SurfaceInfo]) async {
        surfaces = newValue
    }

    public func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? {
        nil
    }
}

/// Echoes client Input back as PtyData on the same surface. Used by
/// in-process tests to exercise the full attach → input → data path
/// without a real PTY on the provider side.
public actor EchoSurfaceProvider: PeerSurfaceProvider {
    private let surfaces: [Termmesh_Peer_V1_SurfaceInfo]
    private var continuations: [Data: AsyncStream<PtyTapChunk>.Continuation] = [:]
    /// Per-surface running byte offset for `PtyTapChunk.seq`. The echo
    /// path has no drop point, so counting delivered bytes is exact.
    private var echoSeqs: [Data: UInt64] = [:]

    public init(surfaces: [Termmesh_Peer_V1_SurfaceInfo]) {
        self.surfaces = surfaces
    }

    public func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] {
        surfaces
    }

    public func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? {
        // No partial-replay support: the echo path has nothing buffered to
        // cut a resume tail from, so a resume request just gets the usual
        // fresh (empty) attachment like any other.
        guard surfaces.contains(where: { $0.surfaceID == surfaceID }) else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: PtyTapChunk.self)
        continuations[surfaceID] = continuation

        let input: @Sendable (Data) async -> Void = { [weak self] bytes in
            await self?.yield(surfaceID: surfaceID, bytes: bytes)
        }
        let detach: @Sendable () async -> Void = { [weak self] in
            await self?.finish(surfaceID: surfaceID)
        }
        return PeerSurfaceAttachment(
            byteStream: stream,
            input: input,
            resize: { _, _ in },
            workspaceMeta: nil,
            detach: detach
        )
    }

    private func yield(surfaceID: Data, bytes: Data) {
        let seq = echoSeqs[surfaceID] ?? 0
        echoSeqs[surfaceID] = seq &+ UInt64(bytes.count)
        continuations[surfaceID]?.yield(PtyTapChunk(bytes: bytes, seq: seq))
    }

    private func finish(surfaceID: Data) {
        continuations[surfaceID]?.finish()
        continuations.removeValue(forKey: surfaceID)
        echoSeqs.removeValue(forKey: surfaceID)
    }
}

// MARK: - PeerServer

public enum PeerServerError: Error, Equatable {
    case bindFailed(errno: Int32, message: String)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case alreadyRunning
    case notRunning
    case noMatchingLeaderSession
    /// The request could not be a leader command whatever machine minted its
    /// grant — oversized, an unknown method, a malformed id. Distinct from
    /// `noMatchingLeaderSession` because a relay hop rejecting a malformed
    /// frame and a relay hop having no session to route through are different
    /// problems, and reporting both as the latter sent an afternoon looking
    /// for a session that was fine.
    case malformedLeaderCommand
    case leaderCallTimedOut
    case leaderSessionClosed
}

public struct PeerServerConfig: Sendable {
    public var hostDisplayName: String
    public var hostAppVersion: String
    public var protocolVersion: String
    public var hostCLIBinDirs: [String]
    /// Where a session owner that outlives this process serves the same
    /// protocol on this machine, or empty when there is none.
    ///
    /// Resolved per Hello rather than fixed at start-up, because at start-up
    /// the answer is not known yet: this server comes up alongside its
    /// machine's session daemon and normally beats it to the socket. A value
    /// decided there is a guess that never gets corrected — and the first
    /// version guessed "yes" every time, so a client planned to come back to a
    /// socket nothing was listening on. Asked at Hello, the question is
    /// answered at the moment it is being asked.
    ///
    /// Empty is the honest default: a host whose sessions end when it does
    /// should say so rather than let a client plan to come back.
    public var resolveSessionHostSocket: @Sendable () -> String

    /// Reads this machine's current load, or nil when it cannot be measured.
    ///
    /// Injected rather than implemented here for two reasons. This module
    /// knows the wire, not the platform — and on a Mac the numbers already
    /// exist: the app's own `term-meshd` samples them for the resource
    /// monitor, so the provider is a lookup rather than a second sampler
    /// competing with the first.
    ///
    /// **Nil is a contract, not an omission.** A host with no provider does
    /// not advertise `host.stats.v1` (see `advertisedCapabilities`) and never
    /// starts the push loop, mirroring the daemon, where the test and embedder
    /// constructors leave the host without a monitor and simply never push.
    /// Before this existed the Mac host advertised the capability and then
    /// sent nothing, so a viewer waited for a frame that was never coming and
    /// showed an empty field with no way to tell why.
    public var hostStatsProvider: (@Sendable () async -> Termmesh_Peer_V1_HostStats?)?

    /// How often the push loop samples. Matches the daemon's monitor tick, so
    /// a viewer sees the same cadence whichever kind of host it is attached to
    /// — `PeerHostStats.staleAfter` on the client is written against it.
    public var hostStatsInterval: Duration = .seconds(2)

    public init(
        hostDisplayName: String = "term-mesh",
        hostAppVersion: String = "0.0.0",
        protocolVersion: String = "1.0.0",
        hostCLIBinDirs: [String] = [],
        resolveSessionHostSocket: @escaping @Sendable () -> String = { "" },
        hostStatsProvider: (@Sendable () async -> Termmesh_Peer_V1_HostStats?)? = nil
    ) {
        self.hostDisplayName = hostDisplayName
        self.hostAppVersion = hostAppVersion
        self.protocolVersion = protocolVersion
        self.hostCLIBinDirs = PeerHostCLIBinDirs.validated(hostCLIBinDirs)
        self.resolveSessionHostSocket = resolveSessionHostSocket
        self.hostStatsProvider = hostStatsProvider
    }
}

public actor PeerServer {
    public let socketPath: String
    public let config: PeerServerConfig
    private let provider: any PeerSurfaceProvider
    private let teamLeaderControlPlane: PeerTeamLeaderControlPlane
    private var listenerFd: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    /// The machine-load push loop, present only when `config` carries a
    /// provider. See `startHostStatsLoopIfConfigured()`.
    private var hostStatsTask: Task<Void, Never>?
    // Internal (not private) so `@testable import PeerProto` tests can
    // inspect a live session's `hasClientCapability(_:)` after a real
    // handshake — see PeerServerTests.swift. No visibility change outside
    // the package: external consumers still only see the `public` members.
    var activeSessions: [PeerServerSession] = []

    public init(
        socketPath: String,
        provider: any PeerSurfaceProvider,
        config: PeerServerConfig = PeerServerConfig(),
        teamLeaderControlPlane: PeerTeamLeaderControlPlane = .shared
    ) {
        self.socketPath = socketPath
        self.provider = provider
        self.config = config
        self.teamLeaderControlPlane = teamLeaderControlPlane
    }

    public func start() throws {
        guard listenerFd < 0 else { throw PeerServerError.alreadyRunning }
        try Self.prepareSocketParentDirectory(for: socketPath)
        // Remove any stale socket file first; an old entry would make bind fail.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw PeerServerError.bindFailed(errno: errno, message: "socket() failed")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < maxPathLen else {
            close(fd)
            throw PeerServerError.bindFailed(
                errno: ENAMETOOLONG,
                message: "socket path exceeds \(maxPathLen - 1) bytes"
            )
        }
        // Copy path into sun_path (leaves trailing zeros).
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPathLen) { cPtr in
                for (i, byte) in pathBytes.enumerated() {
                    cPtr[i] = CChar(bitPattern: byte)
                }
            }
        }

        // Tight umask so the socket file is created at 0600 from the
        // start, eliminating the bind→chmod TOCTOU window where a
        // racing local connect() could reach the listener before the
        // explicit chmod below lands. Restored immediately on the
        // success and error paths so other threads doing concurrent
        // bind() / open() aren't affected longer than this syscall.
        let prevUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(prevUmask)
        if bindResult != 0 {
            let err = errno
            close(fd)
            throw PeerServerError.bindFailed(errno: err, message: "bind() failed")
        }
        // Belt-and-braces: even with the tight umask, normalize the
        // socket file's mode to 0600 in case a future code path or
        // umask quirk lets it land permissive.
        chmod(socketPath, 0o600)

        if listen(fd, 8) != 0 {
            let err = errno
            close(fd)
            throw PeerServerError.listenFailed(errno: err)
        }

        // Non-blocking listener so accept() doesn't stall the accept loop
        // when DispatchSource fires spuriously. Accept errors with EAGAIN
        // are then a normal "no pending connection" signal we skip over.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        listenerFd = fd
        let myConfig = config
        let myProvider = provider
        let myTeamLeaderControlPlane = teamLeaderControlPlane
        let myFd = fd
        acceptTask = Task { [weak self] in
            await Self.runAcceptLoop(
                fd: myFd,
                config: myConfig,
                provider: myProvider,
                teamLeaderControlPlane: myTeamLeaderControlPlane,
                server: self
            )
        }
        startHostStatsLoopIfConfigured()
    }

    /// Starts the machine-load push loop, or does nothing when this host has
    /// no way to measure itself. A host without a provider stays silent AND
    /// stops claiming `host.stats.v1` — the two go together.
    private func startHostStatsLoopIfConfigured() {
        guard config.hostStatsProvider != nil else { return }
        let interval = config.hostStatsInterval
        hostStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                // Sleep first: a client that has just connected is still
                // finishing its handshake, and a sample sent into that is
                // dropped by `pushHostStats`'s `state == .ready` guard anyway.
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.pushHostStatsSample()
            }
        }
    }

    public func stop() async {
        hostStatsTask?.cancel()
        hostStatsTask = nil
        acceptTask?.cancel()
        acceptTask = nil
        if listenerFd >= 0 {
            close(listenerFd)
            listenerFd = -1
        }
        unlink(socketPath)
        // Close any still-running sessions.
        for session in activeSessions {
            await session.close()
        }
        activeSessions.removeAll()
    }

    fileprivate func sessionFinished(_ session: PeerServerSession) {
        activeSessions.removeAll { $0 === session }
    }

    /// Atomic capacity-check + insert. The previous "canAcceptSession()
    /// then register()" pair allowed a TOCTOU window where two concurrent
    /// accepts could both see capacity and both register, pushing
    /// `activeSessions` past `maxPeerServerSessions`. Doing both inside
    /// the same actor-isolated call eliminates that race.
    fileprivate func tryRegister(_ session: PeerServerSession) -> Bool {
        guard activeSessions.count < maxPeerServerSessions else { return false }
        activeSessions.append(session)
        return true
    }

    /// Push a `WorkspaceLayoutChanged` update to every connected
    /// session. Callers (term-mesh.app's PeerDebugServerCoordinator)
    /// invoke this when bonsplit reports a layout change so attached
    /// clients can patch their local NSSplitView trees.
    public func broadcastWorkspaceLayoutChanged(
        workspaceID: Data,
        layout: Termmesh_Peer_V1_WorkspaceLayout
    ) async {
        for session in activeSessions {
            try? await session.pushWorkspaceLayoutChanged(workspaceID: workspaceID, layout: layout)
        }
    }

    /// Push a `WorkspaceRemoved` update to every connected session.
    /// Callers (term-mesh.app's `PeerHostCoordinator`) invoke this
    /// once a workspace is actually gone — via a peer
    /// `DeleteWorkspaceRequest` or a host-local UI close (Cmd+W,
    /// sidebar close) — so already-attached clients drop it from their
    /// roster without polling `ListWorkspaces`.
    public func broadcastWorkspaceRemoved(workspaceID: Data) async {
        for session in activeSessions {
            try? await session.pushWorkspaceRemoved(workspaceID: workspaceID)
        }
    }

    /// Sample this machine once and hand the result to every connected
    /// session.
    ///
    /// One sample per tick regardless of how many peers are attached: the
    /// reading describes the machine, not the connection, and sampling per
    /// session would make the cost of being watched grow with the number of
    /// watchers.
    private func pushHostStatsSample() async {
        guard let provider = config.hostStatsProvider else { return }
        guard !activeSessions.isEmpty else { return }
        guard let stats = await provider() else { return }
        for session in activeSessions {
            try? await session.pushHostStats(stats)
        }
    }

    /// Publish one complete roster to sidebar-only subscribers. This is kept
    /// separate from layout pushes: mirror sessions can continue receiving
    /// their focused layout stream without paying for a full roster on every
    /// divider drag, while a sidebar sees additions/removals immediately.
    public func broadcastWorkspaceListChanged(
        _ workspaces: [Termmesh_Peer_V1_Workspace]
    ) async {
        for session in activeSessions {
            try? await session.pushWorkspaceListChanged(workspaces)
        }
    }

    /// Route a command from a leader process running on this host back to the
    /// viewer that owns the team. The viewer's stable peer id is part of the
    /// grant environment, so an unrelated connected peer can never receive
    /// the request.
    public func callTeamLeader(
        _ request: Termmesh_Peer_V1_TeamLeaderCommandRequest,
        targetPeerID: Data,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> Termmesh_Peer_V1_TeamLeaderCommandResponse {
        for session in activeSessions
        where await session.canRouteTeamLeaderCommand(to: targetPeerID) {
            return try await session.callTeamLeader(
                request,
                timeoutSeconds: timeoutSeconds
            )
        }
        throw PeerServerError.noMatchingLeaderSession
    }

    fileprivate func register(_ session: PeerServerSession) {
        activeSessions.append(session)
    }

    private static func runAcceptLoop(
        fd: Int32,
        config: PeerServerConfig,
        provider: any PeerSurfaceProvider,
        teamLeaderControlPlane: PeerTeamLeaderControlPlane,
        server: PeerServer?
    ) async {
        let queue = DispatchQueue(label: "term-mesh.peer.server.accept", qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

        // Funnel readiness events into an AsyncStream so the loop is driven
        // by structured concurrency rather than by a blocking accept().
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        source.setEventHandler { continuation.yield() }
        source.setCancelHandler { continuation.finish() }
        source.resume()
        defer { source.cancel() }

        for await _ in stream {
            if Task.isCancelled { break }
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                    accept(fd, saddr, &len)
                }
            }
            if clientFd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            // Gate on uid + server existence before allocating a Connection;
            // these raw-fd paths still need an explicit `close(clientFd)`
            // because no holder has taken ownership of the fd yet.
            guard Self.clientHasSameUser(fd: clientFd) else {
                close(clientFd)
                continue
            }
            guard let server else {
                close(clientFd)
                continue
            }
            // Hand fd ownership to the RAII holder inside the actor *first*,
            // so any subsequent failure path (capacity reject, dropped Task)
            // still reclaims the fd via the holder's deinit. Without this,
            // a bare clientFd held only by a closure that never runs leaks
            // the descriptor for the lifetime of the process.
            let connection = AcceptedUnixConnection(fd: clientFd)
            let session = PeerServerSession(
                connection: connection,
                config: config,
                provider: provider,
                teamLeaderControlPlane: teamLeaderControlPlane
            )
            guard await server.tryRegister(session) else {
                // Cap reached. Explicit close keeps the fd recovery
                // observable in lsof immediately rather than waiting on
                // ARC + deinit.
                await connection.close()
                continue
            }
            Task {
                await session.run()
                await server.sessionFinished(session)
            }
        }
    }

    private static func prepareSocketParentDirectory(for socketPath: String) throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        guard !parent.path.isEmpty, parent.path != "/" else { return }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory)
        if !exists {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } else if !isDirectory.boolValue {
            throw PeerServerError.bindFailed(errno: ENOTDIR, message: "socket parent is not a directory")
        }
        // Resolve the directory we'll actually be binding under, then
        // decide what level of hardening to apply. Use `stat()` (which
        // follows symlinks) instead of `lstat` because system paths
        // like macOS's `/tmp` are themselves symlinks (`/tmp` →
        // `/private/tmp`) — `lstat` would incorrectly flag those as
        // "not a directory."
        var st = stat()
        guard stat(parent.path, &st) == 0 else {
            throw PeerServerError.bindFailed(
                errno: errno,
                message: "stat failed on socket parent \(parent.path)"
            )
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw PeerServerError.bindFailed(
                errno: ENOTDIR,
                message: "socket parent \(parent.path) is not a directory"
            )
        }
        let myUid = getuid()
        let isOurOwn = st.st_uid == myUid
        // Sticky-bit world-writable directories (e.g. /tmp itself,
        // mode 01777) get their security from the kernel's sticky-bit
        // semantics — only the file's owner or root can unlink/rename
        // entries — so we don't need to own the directory ourselves
        // when binding inside one. The socket file's own 0600 mode is
        // what gates other users.
        let isStickyTmp = (st.st_mode & UInt16(S_ISVTX)) != 0
        if isOurOwn {
            // Tighten mode unconditionally — a directory we just
            // created with umask 0077 lands at 0700 already, but a
            // pre-existing one we own may be looser. Idempotent.
            if (st.st_mode & 0o777) != 0o700 {
                chmod(parent.path, 0o700)
            }
        } else if isStickyTmp {
            // System tmp dir (sticky-bit). Trust the kernel; bind on.
        } else {
            // Pre-existing directory at our expected path that's
            // neither ours nor a sticky-bit world dir — most likely
            // an attacker-controlled drop-in.
            throw PeerServerError.bindFailed(
                errno: EPERM,
                message: "socket parent \(parent.path) not owned by uid \(myUid) (got \(st.st_uid)); refusing to use it"
            )
        }
    }

    private static func clientHasSameUser(fd: Int32) -> Bool {
        #if canImport(Darwin)
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        return result == 0 && cred.cr_uid == getuid()
        #else
        return true
        #endif
    }
}

// MARK: - AcceptedUnixConnection

/// RAII fd owner. Guarantees the accepted unix socket fd is closed
/// exactly once, even on code paths that drop the owning actor without
/// an explicit `close()` call (Task spawn failure, capacity reject,
/// stop() racing accept, etc.). Without this, a leaked `AcceptedUnixConnection`
/// would hold the fd for the lifetime of the process — observed as 87+ unix
/// FDs accumulating on `peer.sock` until the per-process maxfiles cap of 256
/// was hit and `accept()` started silently dropping new clients.
///
/// Lock-guarded close is idempotent and safe to invoke both from the
/// actor's `close()` and from the nonisolated `deinit`.
final class UnixFdHolder: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var didClose = false

    init(fd: Int32) {
        self.fd = fd
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return didClose
    }

    func close() {
        lock.lock()
        let already = didClose
        didClose = true
        lock.unlock()
        if !already {
            Darwin.close(fd)
        }
    }

    deinit { close() }
}

/// Async wrapper around an accepted client fd. Uses DispatchSourceRead
/// for readability notifications + plain POSIX read/write for the actual
/// I/O so the "return as soon as some bytes are available" semantics
/// match what `PeerSession.readFrame` expects. DispatchIO's batched
/// streaming model blocks until its target length is filled, which
/// deadlocks our protocol loop.
///
/// The fd is owned by a `UnixFdHolder` so dropping this actor without
/// an explicit close still reclaims the descriptor.
actor AcceptedUnixConnection {
    private let holder: UnixFdHolder
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?

    init(fd: Int32) {
        self.holder = UnixFdHolder(fd: fd)
        self.queue = DispatchQueue(label: "term-mesh.peer.server.conn.\(fd)", qos: .userInitiated)
        // Make fd non-blocking so read/write return EAGAIN instead of
        // sleeping; the readiness sources wake us when the kernel has work.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// Return the next chunk of bytes the peer has sent, or empty Data on
    /// EOF. Matches PeerSession.readFrame's "keep reading until a frame
    /// decodes" loop.
    func read() async throws -> Data {
        if holder.isClosed { return Data() }
        while !holder.isClosed {
            // Try a non-blocking read first. If bytes are already sitting
            // in the kernel, skip the DispatchSource round-trip.
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buffer.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(holder.fd, bp.baseAddress, bp.count)
            }
            if n > 0 {
                return Data(buffer.prefix(n))
            }
            if n == 0 {
                holder.close()
                return Data() // EOF
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try await waitForReadable()
                continue
            }
            if errno == EINTR {
                continue
            }
            throw PeerServerError.acceptFailed(errno: errno)
        }
        return Data()
    }

    private func waitForReadable() async throws {
        let fd = self.holder.fd
        let queue = self.queue
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let resumed = AtomicFlag()
            source.setEventHandler {
                if resumed.setOnce() {
                    source.cancel()
                    cont.resume()
                }
            }
            source.setCancelHandler {
                if resumed.setOnce() {
                    cont.resume()
                }
            }
            source.resume()
        }
    }

    /// Serializes whole frames across concurrent writers.
    ///
    /// This is not an optimization — it is what keeps the wire parseable.
    /// The loop below suspends when the socket buffer is full (EAGAIN),
    /// and `actor` isolation does NOT survive a suspension: another task
    /// could enter `write` and interleave its bytes into the middle of a
    /// half-written frame. The client then reads a length prefix at the
    /// wrong offset — observed as
    /// `frameTooLarge(size: 1685024303)`, which is the ASCII "/nod" of a
    /// `node_modules` path from the very PTY output being relayed.
    ///
    /// EAGAIN needs a full socket buffer, so this only bites under a heavy
    /// output flood — where several writers (PTY data, Pong, HostStats)
    /// are also most likely to overlap.
    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireWriteSlot() async {
        guard writeInFlight else {
            writeInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
        // Ownership was handed over by `releaseWriteSlot`; `writeInFlight`
        // deliberately stays true across the handoff so no third writer can
        // slip in between the resume and this frame's first byte.
    }

    private func releaseWriteSlot() {
        if writeWaiters.isEmpty {
            writeInFlight = false
        } else {
            writeWaiters.removeFirst().resume()
        }
    }

    func write(_ data: Data) async throws {
        if holder.isClosed { return }
        await acquireWriteSlot()
        defer { releaseWriteSlot() }
        if holder.isClosed { return }
        let bytes = Array(data)
        var offset = 0
        var remaining = bytes.count
        while remaining > 0 {
            if holder.isClosed { return }
            let n = bytes.withUnsafeBytes { bp -> Int in
                let base = bp.baseAddress!.advanced(by: offset)
                return Darwin.write(holder.fd, base, remaining)
            }
            if n > 0 {
                offset += n
                remaining -= n
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Suspension point. Safe only because `acquireWriteSlot`
                // above guarantees this task owns the socket until the
                // frame is fully written — see the note on that method.
                try await Task.sleep(nanoseconds: 1_000_000)
                continue
            }
            if n < 0 && errno == EINTR { continue }
            throw PeerServerError.acceptFailed(errno: errno)
        }
    }

    func close() {
        holder.close()
    }
}

/// Tiny atomic flag for single-shot continuation guards. Not a full
/// lock — just avoids double-resume when two source handlers race.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - PtyDataCoalescer

/// Batches `pumpByteStream`'s per-chunk PTY output into fewer, larger
/// `PtyData` sends (Phase P7). Before this, Ghostty's PTY tap firing
/// "thousands of times per second" (`PtyTapHub.broadcast` —
/// `Sources/GhosttyPaneSurfaceProvider.swift`) meant one Envelope encode +
/// framed `write()` syscall per chunk, with no batching at all.
///
/// Leading-edge coalescing — same idea as `RelayResizeCoalescer`
/// (`Sources/PeerRelaySession.swift:311-356`) but with a zero-latency
/// first send instead of always waiting out the delay: the first chunk
/// after an idle period is sent unbuffered immediately (an isolated
/// keystroke echo incurs no added latency), which also arms a short
/// collection window. Chunks that arrive while the window is armed are
/// merged into one payload and flushed when the window elapses or the
/// byte cap is hit, whichever comes first. A non-empty window flush
/// re-arms immediately (hitting the window/cap with bytes still pending
/// is itself evidence the source is still producing), so a sustained
/// burst settles into roughly one send per window instead of reverting
/// to a fresh unbuffered send for every single chunk.
///
/// Transport-layer batching only — this changes send *cadence*, never
/// content or ordering. Every byte submitted leaves via `send` in the
/// same order it arrived, just grouped into fewer envelopes. The client
/// re-parses the reassembled byte stream regardless of how the sender
/// chunked it (`sendPeerInputBytes`'s ESC/bracketed-paste state machine
/// lives on the separate client→host *input* path), so merging frames
/// here cannot desync it — see the P7 proposal's forbidden-contract audit
/// (`docs/peer-perf-proposal.md` §P7, F1-F4: disjoint code paths).
public actor PtyDataCoalescer {
    /// Default coalescing window. P7 spec range is 4-8ms; 6ms is the
    /// midpoint — short enough that even a chunk that waits out the full
    /// window adds imperceptible latency to typing echo.
    public static let defaultWindowMs: UInt64 = 6
    /// Default forced-flush byte cap. Matches `PtyTapHub.replayCapacityBytes`
    /// / Rust's `REPLAY_CAPACITY_BYTES` (64KB) so one coalesced frame never
    /// exceeds one replay buffer's worth of bytes (P7 proposal audit note
    /// on sizing this against the replay ring's double-clone cost).
    public static let defaultMaxBytes = 64 * 1024

    private let windowNs: UInt64
    private let maxBytes: Int
    private let send: @Sendable (Data, UInt64) async -> Bool

    private var armed = false
    private var pending = Data()
    private var pendingStartSeq: UInt64 = 0
    private var flushTask: Task<Void, Never>?
    private var stopped = false

    /// - Parameters:
    ///   - windowMs: coalescing window once armed by a leading-edge send.
    ///   - maxBytes: forced-flush cap, checked after every submitted chunk.
    ///   - send: performs the actual framed send for one merged payload
    ///     starting at byte offset `startSeq`. Returns `false` on failure
    ///     (e.g. connection gone); the coalescer then stops permanently,
    ///     mirroring `pumpByteStream`'s original catch-and-return.
    public init(
        windowMs: UInt64 = PtyDataCoalescer.defaultWindowMs,
        maxBytes: Int = PtyDataCoalescer.defaultMaxBytes,
        send: @escaping @Sendable (Data, UInt64) async -> Bool
    ) {
        self.windowNs = windowMs * 1_000_000
        self.maxBytes = maxBytes
        self.send = send
    }

    /// Submit one chunk as it arrives from the byte producer. `startSeq`
    /// is the running byte-offset counter's value BEFORE this chunk (the
    /// caller advances its own counter by `bytes.count` after calling
    /// this) — `PtyData.byteSeq` marks "offset of this payload's first
    /// byte" both before and after coalescing, so a merged frame's seq is
    /// simply its first constituent chunk's seq; no receiver-visible
    /// change to the field's meaning (confirmed against
    /// `proto/peer/v1/peer.proto:311` and `PeerSessionDemux.route` — seq
    /// is carried through as opaque metadata, never used for a per-chunk
    /// contiguity assert on either side, so merging chunks under this
    /// semantic is safe).
    /// Returns `false` once the coalescer has permanently stopped (a
    /// prior send failed) — the caller should stop pumping.
    @discardableResult
    public func submit(_ bytes: Data, startSeq: UInt64) async -> Bool {
        guard !stopped else { return false }
        guard !bytes.isEmpty else { return true }

        guard armed else {
            // Idle → active: send unbuffered (leading edge) so an
            // isolated write incurs zero coalescing delay, then arm the
            // window to catch whatever follows within it.
            guard await send(bytes, startSeq) else {
                stopped = true
                return false
            }
            arm()
            return true
        }

        if pending.isEmpty { pendingStartSeq = startSeq }
        pending.append(bytes)
        guard pending.count >= maxBytes else { return true }

        // Byte cap hit mid-window: flush now instead of waiting out the
        // rest of the window, then keep coalescing — hitting the cap is
        // itself evidence the burst is still ongoing. Checked AFTER the
        // append (not pre-split), so a flushed frame can exceed `maxBytes`
        // by up to one chunk's worth in the worst case — deliberately not
        // pre-emptively splitting a single incoming chunk to shave that
        // off, since real PTY reads are far smaller than the 64KB default
        // cap in practice. The cap's job is bounding unbounded growth
        // during a sustained burst, not guaranteeing an exact ceiling.
        flushTask?.cancel()
        flushTask = nil
        guard await flushLocked() else { return false }
        arm()
        return true
    }

    /// Drains any buffered-but-unflushed bytes immediately, bypassing the
    /// window. Callers MUST await this before discarding the coalescer
    /// (stream finished, cancelled, or a send failed) so in-flight
    /// coalesced bytes are never silently lost on pane/session teardown —
    /// see `pumpByteStream`'s call site for why this alone covers every
    /// teardown path.
    public func flushRemaining() async {
        flushTask?.cancel()
        flushTask = nil
        armed = false
        _ = await flushLocked()
    }

    private func arm() {
        armed = true
        flushTask?.cancel()
        let ns = windowNs
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await self?.windowElapsed()
        }
    }

    private func windowElapsed() async {
        flushTask = nil
        guard !pending.isEmpty else {
            // Nothing arrived during the window: the burst already ended
            // (or was a single already-sent isolated chunk). Go fully
            // idle so the next chunk gets its own fresh leading-edge send
            // rather than silently waiting out another window.
            armed = false
            return
        }
        guard await flushLocked() else { return }
        // Still receiving data as of this flush — keep the window
        // rolling rather than reverting to per-chunk leading-edge sends,
        // so a sustained burst settles into ~1 send per window.
        arm()
    }

    @discardableResult
    private func flushLocked() async -> Bool {
        guard !pending.isEmpty else { return true }
        let payload = pending
        let seq = pendingStartSeq
        pending = Data()
        guard await send(payload, seq) else {
            stopped = true
            return false
        }
        return true
    }
}

// MARK: - PeerServerSession

/// Per-connection state machine. Mirrors the Rust `connection::run`
/// in daemon/term-meshd/src/peer/connection.rs.
actor PeerServerSession {
    private enum State { case initial, authSent, ready }

    private let connection: AcceptedUnixConnection
    private let config: PeerServerConfig
    private let provider: any PeerSurfaceProvider
    private let teamLeaderControlPlane: PeerTeamLeaderControlPlane
    private var state: State = .initial
    private var seq: UInt64 = 0
    private var pendingInbound = Data()
    private var attachments: [Data: PeerSurfaceAttachment] = [:]
    private var relayTasks: [Data: Task<Void, Never>] = [:]
    /// A roster subscription is intentionally independent of surface
    /// attachments. The sidebar needs to observe a host before opening a
    /// workspace, and an attached mirror must not be required merely to keep
    /// its host row fresh.
    private var workspaceListSubscribed = false
    /// Parsed once out of the client's Hello and kept for the life of the
    /// session — plumbing only for now (see P3, docs/peer-perf-proposal.md):
    /// nothing branches on it yet, but future wire changes (P8 and later)
    /// need somewhere to ask "does this client support X" before using it.
    private var clientCapabilities = PeerCapabilities()
    /// Stable identity from this connection's authenticated Hello. Scoped
    /// leader grants are bound to it so reconnects from the same install work
    /// while another peer cannot replay a captured grant.
    private var clientPeerID = Data()
    private var pendingLeaderCalls: [
        UInt64: CheckedContinuation<Termmesh_Peer_V1_TeamLeaderCommandResponse, Error>
    ] = [:]

    /// Whether the connected client advertised `capability` in its Hello.
    func hasClientCapability(_ capability: String) -> Bool {
        clientCapabilities.has(capability)
    }

    init(
        connection: AcceptedUnixConnection,
        config: PeerServerConfig,
        provider: any PeerSurfaceProvider,
        teamLeaderControlPlane: PeerTeamLeaderControlPlane = .shared
    ) {
        self.connection = connection
        self.config = config
        self.provider = provider
        self.teamLeaderControlPlane = teamLeaderControlPlane
    }

    func run() async {
        do {
            while !Task.isCancelled {
                let env = try await readFrame()
                try await dispatch(env)
                if case .goodbye = env.payload { break }
            }
        } catch is CancellationError {
            // graceful
        } catch {
            // Stream ended or protocol error — session terminates.
        }
        failPendingLeaderCalls(with: PeerServerError.leaderSessionClosed)
        await teardownAttachments()
        await connection.close()
    }

    func close() async {
        failPendingLeaderCalls(with: PeerServerError.leaderSessionClosed)
        await teardownAttachments()
        await connection.close()
    }

    func canRouteTeamLeaderCommand(to peerID: Data) -> Bool {
        state == .ready
            && peerID.count == PeerIdentity.byteCount
            && clientPeerID == peerID
            && clientCapabilities.has(PeerCapability.teamLeaderV1)
            // Only an attached relay has a long-lived receive pump. One-shot
            // list/bootstrap sessions also advertise the capability but stop
            // reading after their direct response; routing to one would wait
            // until timeout while the visible pane remained idle.
            && !attachments.isEmpty
    }

    /// Reverse RPC over the session's existing single-reader pump. The run
    /// loop remains the only frame reader; this method registers a
    /// correlation waiter, writes the request, and is resumed by dispatch
    /// when the viewer sends TeamLeaderCommandResponse.
    func callTeamLeader(
        _ request: Termmesh_Peer_V1_TeamLeaderCommandRequest,
        timeoutSeconds: TimeInterval
    ) async throws -> Termmesh_Peer_V1_TeamLeaderCommandResponse {
        guard state == .ready,
              clientCapabilities.has(PeerCapability.teamLeaderV1) else {
            throw PeerServerError.noMatchingLeaderSession
        }
        let encodedBytes = (try? request.serializedData().count)
            ?? (PeerTeamLeader.maxCommandPayloadBytes + 1)
        // This hop is a relay, not the authority.
        //
        // It used to require the grant to be registered *here*, which is
        // unsatisfiable for the case the feature exists for: a leader placed
        // on a peer presents a grant the project's host minted and stored on
        // itself, so this machine has no entry for it and never will. Every
        // genuine command was rejected as `noMatchingLeaderSession` while the
        // grant was valid the whole time — the registry was simply on the
        // other machine.
        //
        // What stops a local process here from inventing a grant is not this
        // check. It is that routing only reaches the peer the request names,
        // over an already-authenticated attached session
        // (`canRouteTeamLeaderCommand`), and that the receiving host validates
        // the grant against the registry that minted it and fails closed on an
        // unknown one — `PeerTeamLeaderControlPlane.execute` passes
        // `registeredGrant: grants[id]`, nil for anything it did not issue,
        // and audits the rejection. A forged grant therefore buys a rejected
        // round trip to one authenticated peer, not execution.
        guard case .success = PeerTeamLeader.validateCommandShape(
            request,
            encodedBytes: encodedBytes
        ) else {
            throw PeerServerError.malformedLeaderCommand
        }

        let requestSeq = nextSeq()
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.seq = requestSeq
        envelope.teamLeaderCommandRequest = request
        let frame = try encodeFrame(envelope)
        let boundedTimeout = timeoutSeconds.isFinite
            ? min(max(timeoutSeconds, 0.05), 60)
            : 10

        return try await withCheckedThrowingContinuation { continuation in
            pendingLeaderCalls[requestSeq] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.writeLeaderCallFrame(frame)
                } catch {
                    await self.failPendingLeaderCall(requestSeq, with: error)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(boundedTimeout * 1_000_000_000)
                )
                await self?.failPendingLeaderCall(
                    requestSeq,
                    with: PeerServerError.leaderCallTimedOut
                )
            }
        }
    }

    private func writeLeaderCallFrame(_ frame: Data) async throws {
        try await connection.write(frame)
    }

    private func failPendingLeaderCall(_ correlationID: UInt64, with error: Error) {
        pendingLeaderCalls.removeValue(forKey: correlationID)?
            .resume(throwing: error)
    }

    private func failPendingLeaderCalls(with error: Error) {
        let pending = pendingLeaderCalls.values
        pendingLeaderCalls.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }

    /// Server-initiated push of a workspace layout change. Sent only
    /// after the session reaches the `.ready` state — callers should
    /// avoid pushing during handshake.
    func pushWorkspaceLayoutChanged(
        workspaceID: Data,
        layout: Termmesh_Peer_V1_WorkspaceLayout
    ) async throws {
        guard state == .ready else { return }
        try await sendEnvelope { env in
            var changed = Termmesh_Peer_V1_WorkspaceLayoutChanged()
            changed.workspaceID = workspaceID
            changed.layout = layout
            var wu = Termmesh_Peer_V1_WorkspaceUpdate()
            wu.workspaceLayout = changed
            env.workspaceUpdate = wu
        }
    }

    /// Server-initiated push notifying the client that `workspaceID`
    /// itself (not a pane inside it) was deleted — via a peer
    /// `DeleteWorkspaceRequest` or a host-local UI close. Sent only
    /// after the session reaches `.ready`, matching
    /// `pushWorkspaceLayoutChanged`.
    func pushWorkspaceRemoved(workspaceID: Data) async throws {
        guard state == .ready else { return }
        try await sendEnvelope { env in
            var removed = Termmesh_Peer_V1_WorkspaceRemoved()
            removed.workspaceID = workspaceID
            var wu = Termmesh_Peer_V1_WorkspaceUpdate()
            wu.workspaceRemoved = removed
            env.workspaceUpdate = wu
        }
    }

    /// Push one machine-load sample. Unsolicited, like the workspace pushes
    /// above — the client's `PeerSession` already treats `hostStats` as a
    /// frame that arrives on its own schedule rather than as a reply.
    func pushHostStats(_ stats: Termmesh_Peer_V1_HostStats) async throws {
        guard state == .ready else { return }
        try await sendEnvelope { env in
            env.hostStats = stats
        }
    }

    /// Push a full workspace roster to an explicitly subscribed client. Full
    /// snapshots make reconnect and deletion convergence idempotent: clients
    /// replace their cached roster rather than merging deltas from a possibly
    /// interrupted stream.
    func pushWorkspaceListChanged(
        _ workspaces: [Termmesh_Peer_V1_Workspace]
    ) async throws {
        guard state == .ready, workspaceListSubscribed else { return }
        try await sendEnvelope { env in
            var changed = Termmesh_Peer_V1_WorkspaceListChanged()
            changed.workspaces = workspaces
            env.workspaceListChanged = changed
        }
    }

    private func teardownAttachments() async {
        for (_, task) in relayTasks {
            task.cancel()
        }
        let snapshot = attachments
        attachments.removeAll()
        relayTasks.removeAll()
        for (_, attachment) in snapshot {
            await attachment.detach()
        }
    }

    private func dispatch(_ env: Termmesh_Peer_V1_Envelope) async throws {
        switch (state, env.payload) {
        case (.initial, .hello(let clientHello)):
            // Major version must match. Otherwise tell the client and bail.
            if majorPart(of: clientHello.protocolVersion) != majorPart(of: config.protocolVersion) {
                try await sendError(
                    code: 104,
                    message: "version mismatch: host \(config.protocolVersion), client \(clientHello.protocolVersion)"
                )
                return
            }
            guard clientHello.peerID.count == PeerIdentity.byteCount else {
                try await sendError(code: 102, message: "peer_id must be 16 bytes")
                return
            }
            clientCapabilities = PeerCapabilities(clientHello.capabilities)
            clientPeerID = clientHello.peerID
            // Capabilities describe implemented protocol support, not whether
            // the current team roster happens to contain any rows.
            //
            // Gating them on a non-empty roster deadlocked the one flow they
            // exist for: standing up a leader is what one does on a host that
            // has no teams yet, so the client refused to bootstrap because the
            // host advertised nothing, and the host had nothing to advertise
            // because no leader had been bootstrapped. Observed as a project
            // that never finished creating on a peer whose team list was empty.
            // `host.stats.v1` is the exception to the paragraph above, and for
            // the opposite reason: it is not "implemented protocol support"
            // this host can honour unconditionally, but a promise to send
            // frames it may have no way to produce. A Mac host with no stats
            // provider advertised it anyway and then never pushed, so a viewer
            // waited forever and drew an empty field with nothing to explain
            // it. Claim it only when the push loop will actually run.
            var advertisedCapabilities = PeerCapability.supported
            if config.hostStatsProvider == nil {
                advertisedCapabilities.removeAll { $0 == PeerCapability.hostStatsV1 }
            }
            try await sendEnvelope { env in
                var h = Termmesh_Peer_V1_Hello()
                h.protocolVersion = self.config.protocolVersion
                h.displayName = self.config.hostDisplayName
                h.appVersion = self.config.hostAppVersion
                h.peerID = randomPeerBytes(count: 16)
                h.capabilities = advertisedCapabilities
                h.cliBinDirs = self.config.hostCLIBinDirs
                // A GUI host's surfaces live in its own process, so a session
                // it owns cannot survive it. Naming a session owner that can is
                // how a client reaches one without being told it may reattach
                // later and then finding nothing there.
                h.sessionHostSocket = self.config.resolveSessionHostSocket()
                env.hello = h
            }
            try await sendEnvelope { env in
                var c = Termmesh_Peer_V1_AuthChallenge()
                c.nonce = randomPeerBytes(count: 32)
                c.supportedMethods = ["ssh-passthrough"]
                env.authChallenge = c
            }
            state = .authSent

        case (.initial, _):
            try await sendError(code: 103, message: "expected Hello first")

        case (.authSent, .auth(let auth)):
            if auth.method != "ssh-passthrough" {
                try await sendEnvelopeWithCorrelation(env.seq) { inner in
                    var r = Termmesh_Peer_V1_AuthResult()
                    r.accepted = false
                    r.reason = "unsupported auth method: \(auth.method)"
                    inner.authResult = r
                }
                return
            }
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                var r = Termmesh_Peer_V1_AuthResult()
                r.accepted = true
                r.sessionID = randomPeerBytes(count: 16)
                inner.authResult = r
            }
            state = .ready

        case (.authSent, _):
            try await sendError(code: 103, message: "expected Auth")

        case (.ready, .listSurfaces):
            let surfaces = await provider.listSurfaces()
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                var list = Termmesh_Peer_V1_SurfaceList()
                list.surfaces = surfaces
                inner.surfaceList = list
            }

        case (.ready, .listWorkspaces):
            let workspaces = await provider.listWorkspaces()
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                var list = Termmesh_Peer_V1_WorkspaceList()
                list.workspaces = workspaces
                inner.workspaceList = list
            }

        case (.ready, .subscribeWorkspaceList):
            // A legacy client cannot classify WorkspaceListChanged, so only
            // activate the stream when it explicitly advertised support.
            guard clientCapabilities.has(PeerCapability.workspaceListSubscribeV1) else {
                try await sendError(code: 106, message: "workspace roster subscription not negotiated")
                return
            }
            workspaceListSubscribed = true
            try await pushWorkspaceListChanged(await provider.listWorkspaces())

        case (.ready, .listTeams):
            let teams = await provider.listTeams()
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                var list = Termmesh_Peer_V1_TeamList()
                list.teams = teams
                inner.teamList = list
            }

        case (.ready, .teamCallRequest(let request)):
            // The allow-list is checked HERE, before the provider is reached:
            // a refusal must not depend on every provider remembering to
            // implement it.
            guard PeerTeamCall.isAllowed(request.method) else {
                try await sendEnvelopeWithCorrelation(env.seq) { inner in
                    var response = Termmesh_Peer_V1_TeamCallResponse()
                    response.ok = false
                    response.errorCode = PeerTeamCall.ErrorCode.methodNotAllowed
                    response.errorMessage = "\(request.method) is not callable by a peer"
                    inner.teamCallResponse = response
                }
                return
            }
            let outcome = await provider.callTeamMethod(
                request.method,
                paramsJSON: request.paramsJson
            )
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                var response = Termmesh_Peer_V1_TeamCallResponse()
                switch outcome {
                case .some(.success(let json)):
                    response.ok = true
                    response.resultJson = json
                case .some(.failure(let failure)):
                    response.ok = false
                    response.errorCode = failure.code
                    response.errorMessage = failure.message
                case .none:
                    response.ok = false
                    response.errorCode = PeerTeamCall.ErrorCode.hostError
                    response.errorMessage = "host has no team subsystem"
                }
                inner.teamCallResponse = response
            }

        case (.ready, .teamLeaderBootstrapRequest(let request)):
            guard clientCapabilities.has(PeerCapability.teamLeaderV1) else {
                try await sendError(code: 106, message: "team leader capability not negotiated")
                return
            }
            let encodedBytes = (try? request.serializedData().count)
                ?? (PeerTeamLeader.maxBootstrapPayloadBytes + 1)
            let response = await teamLeaderControlPlane.bootstrap(
                request,
                encodedBytes: encodedBytes,
                audiencePeerID: clientPeerID
            ) { [provider] projectID in
                await provider.resolveTeamLeaderProject(projectID)
            }
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                inner.teamLeaderBootstrapResponse = response
            }

        case (.ready, .teamLeaderCommandRequest(let request)):
            guard clientCapabilities.has(PeerCapability.teamLeaderV1) else {
                try await sendError(code: 106, message: "team leader capability not negotiated")
                return
            }
            let encodedBytes = (try? request.serializedData().count)
                ?? (PeerTeamLeader.maxCommandPayloadBytes + 1)
            let response = await teamLeaderControlPlane.execute(
                request,
                encodedBytes: encodedBytes,
                audiencePeerID: clientPeerID
            ) { [provider] method, paramsJSON, teamUUID in
                await provider.callScopedTeamLeaderMethod(
                    method,
                    paramsJSON: paramsJSON,
                    teamUUID: teamUUID
                ) ?? .failure(PeerTeamCallFailure(
                    code: PeerTeamCall.ErrorCode.hostError,
                    message: "host has no team subsystem"
                ))
            }
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                inner.teamLeaderCommandResponse = response
            }

        case (.ready, .teamLeaderCommandResponse(let response)):
            guard env.correlationID != 0,
                  let continuation = pendingLeaderCalls.removeValue(
                    forKey: env.correlationID
                  ) else {
                try await sendError(
                    code: 103,
                    message: "unexpected team leader command response"
                )
                return
            }
            continuation.resume(returning: response)

        case (.ready, .workspaceControl(let ctl)):
            // Fire-and-forget; the resulting layout update flows back
            // via the existing WorkspaceLayoutChanged push.
            await provider.handleWorkspaceControl(ctl)

        case (.ready, .createWorkspaceRequest(let req)):
            let workspaceID = await provider.createWorkspace(title: req.title)
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                var response = Termmesh_Peer_V1_CreateWorkspaceResponse()
                response.accepted = workspaceID != nil
                response.reason = workspaceID == nil
                    ? "host could not create a workspace"
                    : ""
                response.workspaceID = workspaceID ?? Data()
                inner.createWorkspaceResponse = response
            }
            if workspaceID != nil {
                try await pushWorkspaceListChanged(await provider.listWorkspaces())
            }

        case (.ready, .renameWorkspaceRequest(let req)):
            // Fire-and-forget like WorkspaceControl: no reply, paired
            // or otherwise. An empty/unknown workspace_id is a silent
            // no-op — matches the Rust host's connection.rs handler.
            _ = await provider.renameWorkspace(id: req.workspaceID, title: req.title)

        case (.ready, .deleteWorkspaceRequest(let req)):
            // Fire-and-forget: the only observable result of a
            // successful delete is the WorkspaceRemoved push the
            // provider's caller (term-mesh.app's PeerHostCoordinator)
            // broadcasts once the underlying TabManager mutation
            // completes — see GhosttyPaneSurfaceProvider.deleteWorkspace.
            _ = await provider.deleteWorkspace(id: req.workspaceID)

        case (.ready, .attachSurface(let req)):
            try await handleAttach(req, correlationID: env.seq)

        case (.ready, .detachSurface(let det)):
            await detachSurface(id: det.surfaceID)

        case (.ready, .input(let input)):
            guard let attachment = attachments[input.surfaceID] else { return }
            switch input.kind {
            case .keys(let keys):
                await attachment.input(keys)
            case .paste(let paste):
                await attachment.input(paste.text)
            case .mouse, .none:
                // Mouse encoding is deferred; drop silently for now.
                break
            }

        case (.ready, .resize(let r)):
            guard let attachment = attachments[r.surfaceID] else { return }
            if r.cols > 0 && r.rows > 0 {
                await attachment.resize(r.cols, r.rows)
            }

        case (.ready, .ping(let p)):
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                var pong = Termmesh_Peer_V1_Pong()
                pong.nonce = p.nonce
                inner.pong = pong
            }

        case (.ready, .goodbye):
            return

        case (.ready, _):
            // Remaining payloads (DataAck, Error inbound, etc.) are either
            // advisory from the client side or shouldn't arrive here.
            // Silent drop matches the Rust server's behavior.
            break
        }
    }

    // MARK: - attach plumbing

    /// ## The wire↔host seq mapping (R1, peer-relay-bulk-loss)
    ///
    /// Mirrors the Rust host's `connection.rs::spawn_attach_relay` doc
    /// comment exactly — same design, same field pairing, ported to this
    /// direct (non-daemon) host path:
    ///
    /// - **Wire `byte_seq`** (`PtyData.byteSeq`, `pumpByteStream`'s
    ///   `wireSeq`): reset to 0 at the start of every attach, then advanced
    ///   by real bytes plus any tap-side drop width — self-consistent
    ///   within one attach, meaningless across a dead one.
    /// - **Host absolute seq** (`PtyTapChunk.seq` / `PtyTapHub.tapSeq`): one
    ///   monotonic counter per surface, shared by every attach — what
    ///   `PtyTapHub`'s replay ring cuts on.
    ///
    /// `AttachSurface.resumeFromSeq` and `AttachResult.initialSeq` both live
    /// in the **host absolute** space: `initialSeq` tells the client the
    /// absolute seq its wire `byteSeq == 0` maps to for THIS attach, so any
    /// wire `byteSeq = w` it later processes translates to `initialSeq + w`
    /// — computed entirely client-side. A reattach after a gap sends that
    /// value back as `resumeFromSeq`, and `provider.attach` below can use
    /// it directly against its own absolute seq space with no further
    /// conversion.
    ///
    /// Gated on `replay.ring.v1`: a peer that never advertised it may
    /// predate this mapping, so its `resumeFromSeq` is not trusted —
    /// forced to 0, i.e. a fresh full-snapshot attach exactly like before
    /// this field had meaning. Old-peer fallback nuance beyond this gate is
    /// t6's scope.
    private func handleAttach(
        _ req: Termmesh_Peer_V1_AttachSurface,
        correlationID: UInt64
    ) async throws {
        if attachments[req.surfaceID] != nil {
            try await sendEnvelopeWithCorrelation(correlationID) { inner in
                var r = Termmesh_Peer_V1_AttachResult()
                r.accepted = false
                r.reason = "already attached"
                r.surfaceID = req.surfaceID
                inner.attachResult = r
            }
            return
        }

        let resumeFromSeq = (req.resumeFromSeq != 0 && hasClientCapability(PeerCapability.replayRingV1))
            ? req.resumeFromSeq
            : 0

        guard
            let attachment = await provider.attach(
                surfaceID: req.surfaceID,
                clientCols: req.clientCols,
                clientRows: req.clientRows,
                resumeFromSeq: resumeFromSeq
            )
        else {
            try await sendEnvelopeWithCorrelation(correlationID) { inner in
                var r = Termmesh_Peer_V1_AttachResult()
                r.accepted = false
                r.reason = "surface not found"
                r.surfaceID = req.surfaceID
                inner.attachResult = r
            }
            return
        }

        let grantedMode: Termmesh_Peer_V1_AttachMode = {
            switch req.mode {
            case .coWrite, .takeOver: return .coWrite
            default: return .readOnly
            }
        }()

        try await sendEnvelopeWithCorrelation(correlationID) { inner in
            var r = Termmesh_Peer_V1_AttachResult()
            r.accepted = true
            r.surfaceID = req.surfaceID
            r.initialSeq = attachment.initialByteSeq
            r.grantedMode = grantedMode
            inner.attachResult = r
        }

        if let meta = attachment.workspaceMeta {
            try await sendEnvelope { inner in
                var m = Termmesh_Peer_V1_WorkspaceMeta()
                m.cwd = meta.cwd
                m.branch = meta.branch
                m.ports = meta.ports
                m.latestNotification = meta.latestNotification
                var wu = Termmesh_Peer_V1_WorkspaceUpdate()
                wu.meta = m
                inner.workspaceUpdate = wu
            }
        }

        attachments[req.surfaceID] = attachment
        let surfaceID = req.surfaceID
        let relayTask: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.pumpByteStream(surfaceID: surfaceID, attachment: attachment)
        }
        relayTasks[surfaceID] = relayTask
    }

    /// Phase P7: pumps `attachment.byteStream` through a `PtyDataCoalescer`
    /// instead of sending one `PtyData` per chunk 1:1 — see that type's
    /// doc comment for the leading-edge/window/cap design.
    private func pumpByteStream(
        surfaceID: Data,
        attachment: PeerSurfaceAttachment
    ) async {
        // Wire seq accounting: rebases the producer's tap-relative chunk
        // seqs to a per-attach 0-based wire seq, PRESERVING inter-chunk
        // holes. A chunk the producer's bounded buffer dropped never
        // arrives here — its width shows up as `chunk.seq > lastTapEnd`
        // and is added to `wireSeq`, so the viewer sees a `byte_seq` jump
        // and its P9 gap heal fires. The old `byteSeq &+= bytes.count`
        // counter only counted DELIVERED chunks: drops left the wire seq
        // contiguous and truncation was undetectable downstream.
        var wireSeq: UInt64 = 0
        var lastTapEnd: UInt64?
        var sendFailed = false
        let coalescer = PtyDataCoalescer { [weak self] payload, seq in
            guard let self else { return false }
            do {
                try await self.sendEnvelope { env in
                    var p = Termmesh_Peer_V1_PtyData()
                    p.surfaceID = surfaceID
                    p.byteSeq = seq
                    p.payload = payload
                    env.ptyData = p
                }
                return true
            } catch {
                return false
            }
        }

        for await chunk in attachment.byteStream {
            if Task.isCancelled { break }
            if chunk.bytes.isEmpty { continue }
            if let prevEnd = lastTapEnd, chunk.seq > prevEnd {
                // Producer-side drop between the previous chunk and this
                // one — forward the hole to the wire. (A `seq` at or below
                // `prevEnd` — synthetic snapshot stamps, wrap — is treated
                // as contiguous; only forward jumps are meaningful.)
                wireSeq &+= (chunk.seq - prevEnd)
            }
            lastTapEnd = chunk.seq &+ UInt64(chunk.bytes.count)
            let startSeq = wireSeq
            wireSeq &+= UInt64(chunk.bytes.count)
            if await coalescer.submit(chunk.bytes, startSeq: startSeq) == false {
                sendFailed = true
                break
            }
        }
        // Stream ended (natural finish, cancellation, or a send failure
        // broke the loop above) — flush whatever the coalescer is still
        // holding. Every pane-teardown path funnels through here: a
        // peer-initiated detach finishes this specific stream via
        // `PtyTapHub.finish(attachID:)`, and a host-side close
        // (closeWorkspace / didCloseTab / didClosePane) finishes ALL of a
        // surface's streams via `invalidateTapHub` -> `hub.shutdown()` ->
        // `finishAll()` — either way `for await` above exits and this
        // flush runs, so no separate hook is needed at those three call
        // sites. This is what keeps in-flight coalesced bytes from being
        // lost on close (P7 proposal audit note; hard regression gate:
        // test_peer_input_bracketed_paste_split_close.py).
        await coalescer.flushRemaining()
        // A send failure means this attach can never deliver another byte,
        // but the attach registry still lists it — the host keeps the pane
        // "attached" while the stream is permanently dead (zombie pane:
        // heartbeat fine, output frozen forever). Detach so the provider
        // releases per-attach resources and the client's next attach starts
        // a live pump instead of piling onto a corpse.
        if sendFailed {
            await detachSurface(id: surfaceID)
        }
    }

    private func detachSurface(id: Data) async {
        relayTasks.removeValue(forKey: id)?.cancel()
        if let attachment = attachments.removeValue(forKey: id) {
            await attachment.detach()
        }
    }

    // MARK: - framing helpers

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    private func sendEnvelope(configure: (inout Termmesh_Peer_V1_Envelope) -> Void) async throws {
        try await sendEnvelopeWithCorrelation(0, configure: configure)
    }

    private func sendEnvelopeWithCorrelation(
        _ correlation: UInt64,
        configure: (inout Termmesh_Peer_V1_Envelope) -> Void
    ) async throws {
        var env = Termmesh_Peer_V1_Envelope()
        env.seq = nextSeq()
        env.correlationID = correlation
        configure(&env)
        let data = try encodeFrame(env)
        try await connection.write(data)
    }

    private func sendError(code: UInt32, message: String) async throws {
        try await sendEnvelope { env in
            var err = Termmesh_Peer_V1_Error()
            err.code = code
            err.message = message
            env.error = err
        }
    }

    private func readFrame() async throws -> Termmesh_Peer_V1_Envelope {
        while true {
            if let env = try decodeFrame(from: &pendingInbound) {
                return env
            }
            let chunk = try await connection.read()
            if chunk.isEmpty {
                throw PeerSessionError.unexpectedEof
            }
            pendingInbound.append(chunk)
        }
    }
}

private func majorPart(of semver: String) -> Substring {
    semver.split(separator: ".").first ?? Substring(semver)
}

private func randomPeerBytes(count: Int) -> Data {
    #if canImport(Darwin)
    // SecRandomCopyBytes is the documented CSPRNG entry point on
    // Darwin. Avoids the structural fixed bits of UUIDv4 (version /
    // variant nibbles) that the previous implementation embedded in
    // every 16-byte chunk of the nonce.
    var bytes = [UInt8](repeating: 0, count: count)
    let rc = bytes.withUnsafeMutableBufferPointer { buf -> Int32 in
        guard let base = buf.baseAddress else { return errSecParam }
        return SecRandomCopyBytes(kSecRandomDefault, count, base)
    }
    if rc == errSecSuccess {
        return Data(bytes)
    }
    #endif
    // Fallback: the original UUID-concat path. Worse than the
    // CSPRNG but better than panicking if SecRandom ever returns an
    // error (which shouldn't happen in practice).
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
        var uuid = UUID().uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    }
    return data.prefix(count)
}
