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
#endif
import Foundation
import Dispatch
import SwiftProtobuf

// MARK: - PeerSurfaceProvider

/// Supplies the server with the set of surfaces to advertise. Phase
/// C-3c.3.2 will extend this with attach-side methods
/// (`subscribe(surfaceID:cols:rows:)` returning a byte stream + input
/// sink); for now ListSurfaces is the only thing clients can do past
/// the handshake.
public protocol PeerSurfaceProvider: AnyObject, Sendable {
    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo]
}

/// Convenience provider for tests and early GUI integration: just
/// reports a fixed surface list.
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
}

// MARK: - PeerServer

public enum PeerServerError: Error, Equatable {
    case bindFailed(errno: Int32, message: String)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case alreadyRunning
    case notRunning
}

public struct PeerServerConfig: Sendable {
    public var hostDisplayName: String
    public var hostAppVersion: String
    public var protocolVersion: String

    public init(
        hostDisplayName: String = "term-mesh",
        hostAppVersion: String = "0.0.0",
        protocolVersion: String = "1.0.0"
    ) {
        self.hostDisplayName = hostDisplayName
        self.hostAppVersion = hostAppVersion
        self.protocolVersion = protocolVersion
    }
}

public actor PeerServer {
    public let socketPath: String
    public let config: PeerServerConfig
    private let provider: any PeerSurfaceProvider
    private var listenerFd: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var activeSessions: [PeerServerSession] = []

    public init(
        socketPath: String,
        provider: any PeerSurfaceProvider,
        config: PeerServerConfig = PeerServerConfig()
    ) {
        self.socketPath = socketPath
        self.provider = provider
        self.config = config
    }

    public func start() throws {
        guard listenerFd < 0 else { throw PeerServerError.alreadyRunning }
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

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            let err = errno
            close(fd)
            throw PeerServerError.bindFailed(errno: err, message: "bind() failed")
        }

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
        let myFd = fd
        acceptTask = Task { [weak self] in
            await Self.runAcceptLoop(fd: myFd, config: myConfig, provider: myProvider, server: self)
        }
    }

    public func stop() async {
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

    fileprivate func register(_ session: PeerServerSession) {
        activeSessions.append(session)
    }

    private static func runAcceptLoop(
        fd: Int32,
        config: PeerServerConfig,
        provider: any PeerSurfaceProvider,
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
            let connection = AcceptedUnixConnection(fd: clientFd)
            let session = PeerServerSession(
                connection: connection,
                config: config,
                provider: provider
            )
            await server?.register(session)
            Task {
                await session.run()
                if let server = server {
                    await server.sessionFinished(session)
                }
            }
        }
    }
}

// MARK: - AcceptedUnixConnection

/// Async wrapper around an accepted client fd. Uses DispatchSourceRead
/// for readability notifications + plain POSIX read/write for the actual
/// I/O so the "return as soon as some bytes are available" semantics
/// match what `PeerSession.readFrame` expects. DispatchIO's batched
/// streaming model blocks until its target length is filled, which
/// deadlocks our protocol loop.
actor AcceptedUnixConnection {
    let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
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
        if closed { return Data() }
        while !closed {
            // Try a non-blocking read first. If bytes are already sitting
            // in the kernel, skip the DispatchSource round-trip.
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buffer.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n > 0 {
                return Data(buffer.prefix(n))
            }
            if n == 0 {
                closed = true
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
        let fd = self.fd
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

    func write(_ data: Data) async throws {
        if closed { return }
        let bytes = Array(data)
        var offset = 0
        var remaining = bytes.count
        while remaining > 0 {
            if closed { return }
            let n = bytes.withUnsafeBytes { bp -> Int in
                let base = bp.baseAddress!.advanced(by: offset)
                return Darwin.write(fd, base, remaining)
            }
            if n > 0 {
                offset += n
                remaining -= n
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Rare for Unix sockets with small frames; a brief yield
                // lets the kernel buffer drain. Production code would
                // use DispatchSourceWrite; PoC keeps it simple.
                try await Task.sleep(nanoseconds: 1_000_000)
                continue
            }
            if n < 0 && errno == EINTR { continue }
            throw PeerServerError.acceptFailed(errno: errno)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
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

// MARK: - PeerServerSession

/// Per-connection state machine. Mirrors the Rust `connection::run`
/// in daemon/term-meshd/src/peer/connection.rs.
actor PeerServerSession {
    private enum State { case initial, authSent, ready }

    private let connection: AcceptedUnixConnection
    private let config: PeerServerConfig
    private let provider: any PeerSurfaceProvider
    private var state: State = .initial
    private var seq: UInt64 = 0
    private var pendingInbound = Data()

    init(
        connection: AcceptedUnixConnection,
        config: PeerServerConfig,
        provider: any PeerSurfaceProvider
    ) {
        self.connection = connection
        self.config = config
        self.provider = provider
    }

    func run() async {
        do {
            while !Task.isCancelled {
                let env = try await readFrame()
                try await dispatch(env)
                if case .goodbye = env.payload { return }
            }
        } catch is CancellationError {
            // graceful
        } catch {
            // Stream ended or protocol error — session terminates.
        }
        await connection.close()
    }

    func close() async {
        await connection.close()
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
            try await sendEnvelope { env in
                var h = Termmesh_Peer_V1_Hello()
                h.protocolVersion = self.config.protocolVersion
                h.displayName = self.config.hostDisplayName
                h.appVersion = self.config.hostAppVersion
                h.peerID = Data(count: 16)
                env.hello = h
            }
            try await sendEnvelope { env in
                var c = Termmesh_Peer_V1_AuthChallenge()
                c.nonce = Data(count: 32)
                c.supportedMethods = ["ssh-passthrough", "token-ed25519"]
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
                r.sessionID = Data(count: 16)
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

        case (.ready, .ping(let p)):
            try await sendEnvelopeWithCorrelation(env.seq) { inner in
                var pong = Termmesh_Peer_V1_Pong()
                pong.nonce = p.nonce
                inner.pong = pong
            }

        case (.ready, .goodbye):
            return

        case (.ready, _):
            // Attach / Input / Resize / Detach land in Phase C-3c.3.2.
            // Advertise the unsupported payload as an error so clients
            // don't silently hang on a reply that never comes.
            try await sendError(
                code: 103,
                message: "payload not supported in Phase C-3c.3.1: \(String(describing: env.payload))"
            )
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
