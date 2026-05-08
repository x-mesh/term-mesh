// Phase C-4: PeerRelaySession — wires a Swift PeerSession (host) to
// a term-mesh-peer-relay binary (Ghostty "shell") via a local Unix socket.
//
// Data flow:
//   [remote host PTY]
//        ↓ PeerSession PtyData
//   [PeerRelaySession]
//        ↓ relay socket type=0x01 (raw bytes)
//   [term-mesh-peer-relay process]  ← Ghostty spawns this as the shell
//        ↓ relay writes to stdout → Ghostty master fd → Ghostty renders
//        ↑ user keystrokes (relay stdin) → type=0x02 → app → PeerSession Input
//        ↑ SIGWINCH (relay) → type=0x03 → app → PeerSession Resize

import Foundation
import Darwin
import PeerProto

// ── Frame types (must match relay binary) ───────────────────────────

private let kTypePtyData: UInt8  = 0x01
private let kTypeKeyInput: UInt8 = 0x02
private let kTypeResize: UInt8   = 0x03
private let kTypeGoodbye: UInt8  = 0xFF
private let kTypeAuth: UInt8     = 0xFE
private let kRelayMaxFrameBytes = 1024 * 1024

// ── Two-stage handshake result ─────────────────────────────────────

/// Carries an open PeerSession and the surface list from a host. Yielded
/// by `PeerRelaySession.connectAndList` so the caller can show a picker
/// and then either call `PeerRelaySession.attach(_, surface:)` or
/// `cancel()` to release the connection cleanly.
struct PeerRelayConnection: Sendable {
    let hostSockPath: String
    let session: PeerSession
    let transport: UnixSocketTransport
    let surfaces: [Termmesh_Peer_V1_SurfaceInfo]

    func cancel() async {
        try? await session.sendGoodbye(reason: "peer-relay picker cancelled")
        await transport.close()
    }
}

// ── Relay socket wrapper ─────────────────────────────────────────────

/// Wraps a connected relay fd; provides framed reads and writes.
final class RelaySocket: @unchecked Sendable {
    let fd: Int32
    private let writeLock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    // Blocking send of a single frame (called from background tasks).
    func writeFrame(type: UInt8, payload: Data) throws {
        guard payload.count <= kRelayMaxFrameBytes else {
            throw RelayError.ioError("relay frame too large: \(payload.count)")
        }
        var header = Data(count: 5)
        header[0] = type
        let len = UInt32(payload.count)
        withUnsafeBytes(of: len.littleEndian) { header.replaceSubrange(1..<5, with: $0) }
        writeLock.lock()
        defer { writeLock.unlock() }
        try writeFull(fd: fd, data: header)
        try writeFull(fd: fd, data: payload)
    }

    // Blocking read of one frame.
    func readFrame() throws -> (type: UInt8, payload: Data) {
        var header = Data(count: 5)
        try readFull(fd: fd, into: &header)
        let type = header[0]
        let len = Int(UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) }))
        guard len <= kRelayMaxFrameBytes else {
            throw RelayError.ioError("relay frame too large: \(len)")
        }
        var payload = Data(count: len)
        if len > 0 {
            try readFull(fd: fd, into: &payload)
        }
        return (type, payload)
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

private func writeFull(fd: Int32, data: Data) throws {
    var sent = 0
    while sent < data.count {
        let n = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress! + sent, data.count - sent)
        }
        if n <= 0 { throw RelayError.ioError("write failed: errno \(errno)") }
        sent += n
    }
}

private func readFull(fd: Int32, into data: inout Data) throws {
    var received = 0
    let total = data.count
    while received < total {
        let n = data.withUnsafeMutableBytes { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress! + received, total - received)
        }
        if n <= 0 { throw RelayError.ioError("read EOF or error: errno \(errno)") }
        received += n
    }
}

enum RelayError: Error {
    case ioError(String)
    case noRelayBinary(String)
    case listenerSetupFailed(String)
    case acceptTimedOut
}

// ── PeerRelaySession ─────────────────────────────────────────────────

/// Manages the full relay lifetime for one remote-pane window.
/// 1. Creates a listener socket that the relay binary will connect to.
/// 2. Holds a PeerSession to the remote host.
/// 3. After start(), pumps data between host and relay.
@MainActor
final class PeerRelaySession {
    // Path the relay binary should connect to.
    let relaySockPath: String
    // Per-session secret the relay binary must echo before we forward input.
    let relaySecret: String
    // Relay binary location (must exist before calling start()).
    let relayBinaryPath: String

    private let hostSockPath: String
    private let surfaceID: Data
    private let remoteCols: UInt32
    private let remoteRows: UInt32

    private var listenerFd: Int32 = -1
    private var relaySocket: RelaySocket?
    private var session: PeerSession?
    private var transport: UnixSocketTransport?
    private var pumpTask: Task<Void, Never>?

    var onError: (@MainActor (Error) -> Void)?
    var onDisconnect: (@MainActor () -> Void)?

    // ── Stale-socket sweep ──────────────────────────────────────────
    //
    // Per-session sockets land in a private per-user directory.
    // Normal teardown removes them in deinit, but a crash leaves the
    // file behind. Call this at app startup to remove any whose
    // listener is no longer accepting (i.e. a `connect()` returns
    // ECONNREFUSED). Sockets with a live listener — for example one
    // owned by another running debug app instance — are left alone.

    static func sweepStaleRelaySockets() {
        let dir = "/tmp/term-mesh-relays-\(getuid())"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in entries
            where name.hasSuffix(".sock")
        {
            let path = "\(dir)/\(name)"
            if !relaySocketHasLiveListener(at: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private static func relaySocketHasLiveListener(at path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true } // can't tell — keep
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return true }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress, count: pathBytes.count))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ap -> Int32 in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        if rc == 0 { return true }
        // ECONNREFUSED means the file exists but nobody is listening —
        // the leftover from a previous crashed run.
        return errno != ECONNREFUSED
    }

    // ── Factory (two-stage) ────────────────────────────────────────
    //
    // Stage 1 — `connectAndList`: open the transport, handshake, list
    //   surfaces. The caller inspects the list (e.g. shows a picker)
    //   and either decides on a surface or aborts.
    // Stage 2 — `attach`: take an open connection plus the chosen
    //   surface and return a ready-to-start PeerRelaySession.
    //
    // The split keeps surface selection transport-agnostic so a future
    // SSH transport (or Bonjour discovery) only changes how stage 1
    // dials the socket — the picker UX and stage 2 are unaffected.

    static func connectAndList(hostSockPath: String) async throws -> PeerRelayConnection {
        let connection = try await connect(hostSockPath: hostSockPath)
        let surfaces = try await connection.session.listSurfaces()
        return PeerRelayConnection(
            hostSockPath: hostSockPath,
            session: connection.session,
            transport: connection.transport,
            surfaces: surfaces
        )
    }

    static func connect(hostSockPath: String) async throws -> PeerRelayConnection {
        let transport = try await UnixSocketTransport.connect(socketPath: hostSockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()
        return PeerRelayConnection(
            hostSockPath: hostSockPath,
            session: session,
            transport: transport,
            surfaces: []
        )
    }

    static func attach(
        _ connection: PeerRelayConnection,
        surface: Termmesh_Peer_V1_SurfaceInfo
    ) async throws -> PeerRelaySession {
        let outcome = try await connection.session.attachSurface(
            id: surface.surfaceID,
            mode: .coWrite,
            cols: UInt32(surface.cols),
            rows: UInt32(surface.rows)
        )

        let relaySockPath = try Self.makeRelaySocketPath()

        return PeerRelaySession(
            hostSockPath: connection.hostSockPath,
            relaySockPath: relaySockPath,
            relaySecret: Self.makeRelaySecret(),
            surfaceID: outcome.surfaceID,
            remoteCols: UInt32(surface.cols),
            remoteRows: UInt32(surface.rows),
            session: connection.session,
            transport: connection.transport
        )
    }

    /// Convenience for callers that don't care which surface — auto-picks
    /// the first attachable. Kept so existing in-process tests / scripts
    /// keep working.
    static func create(hostSockPath: String) async throws -> PeerRelaySession {
        let conn = try await connectAndList(hostSockPath: hostSockPath)
        guard let chosen = conn.surfaces.first(where: { $0.attachable }) ?? conn.surfaces.first else {
            await conn.cancel()
            throw RelayError.ioError("host has no attachable surfaces")
        }
        return try await attach(conn, surface: chosen)
    }

    private init(
        hostSockPath: String,
        relaySockPath: String,
        relaySecret: String,
        surfaceID: Data,
        remoteCols: UInt32,
        remoteRows: UInt32,
        session: PeerSession,
        transport: UnixSocketTransport
    ) {
        self.hostSockPath = hostSockPath
        self.relaySockPath = relaySockPath
        self.relaySecret = relaySecret
        self.surfaceID = surfaceID
        self.remoteCols = remoteCols
        self.remoteRows = remoteRows
        self.session = session
        self.transport = transport
        self.relayBinaryPath = Self.findRelayBinary()
    }

    deinit {
        if listenerFd >= 0 { Darwin.close(listenerFd) }
        try? FileManager.default.removeItem(atPath: relaySockPath)
    }

    private static func makeRelaySocketPath() throws -> String {
        let dir = "/tmp/term-mesh-relays-\(getuid())"
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } else if !isDirectory.boolValue {
            throw RelayError.listenerSetupFailed("relay socket parent is not a directory")
        }
        Darwin.chmod(dir, 0o700)
        return "\(dir)/\(UUID().uuidString.lowercased()).sock"
    }

    private static func makeRelaySecret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // ── Relay binary location ────────────────────────────────────────

    static func findRelayBinary() -> String {
        // Bundled alongside the app binary.
        let appDir = Bundle.main.bundlePath + "/Contents/MacOS"
        let bundled = appDir + "/term-mesh-peer-relay"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }

        // Development build: look relative to the project root via
        // the __FILE__ path at compile time (approximation).
        let devBuildPaths = [
            // Xcode sets SOURCE_ROOT as the project root; not available at runtime,
            // but we can derive it from the app's DerivedData path.
            Bundle.main.bundlePath
                .components(separatedBy: "/Build/")
                .first
                .map { $0 + "/../daemon/target/release/term-mesh-peer-relay" }
                .map { ($0 as NSString).standardizingPath },
            "/Users/jinwoo/work/project/term-mesh/daemon/target/release/term-mesh-peer-relay",
        ]
        for path in devBuildPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return bundled  // will fail at runtime; caller handles error
    }

    // ── Start ────────────────────────────────────────────────────────

    /// Sets up the listener socket. The Ghostty surface must be created
    /// AFTER this returns (so the relay binary can connect to relaySockPath).
    func prepareListener() throws {
        guard FileManager.default.fileExists(atPath: relayBinaryPath) else {
            throw RelayError.noRelayBinary("relay binary not found at \(relayBinaryPath)")
        }

        // Remove stale socket if any.
        try? FileManager.default.removeItem(atPath: relaySockPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError.listenerSetupFailed("socket() errno \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy path into sun_path using raw pointer to avoid Swift exclusivity violations.
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPathBuf in
            relaySockPath.withCString { src in
                _ = Darwin.strlcpy(
                    sunPathBuf.baseAddress!.assumingMemoryBound(to: CChar.self),
                    src,
                    sunPathSize
                )
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrLen)
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw RelayError.listenerSetupFailed("bind() errno \(errno)")
        }
        Darwin.chmod(relaySockPath, 0o600)
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw RelayError.listenerSetupFailed("listen() errno \(errno)")
        }

        self.listenerFd = fd
    }

    /// Call after the Ghostty surface has been created. Accepts the relay
    /// connection (with a timeout) and starts bidirectional pumping.
    func start() async throws {
        let relay = try await acceptRelay()
        self.relaySocket = relay
        startPumping(relay: relay)
    }

    // ── Accept ───────────────────────────────────────────────────────

    private func acceptRelay() async throws -> RelaySocket {
        let lfd = listenerFd
        let expectedSecret = relaySecret
        // Set non-blocking so we can poll in a background Task.
        _ = Darwin.fcntl(lfd, F_SETFL, O_NONBLOCK)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                // Poll up to 100 × 100ms = 10s for the relay to connect.
                for _ in 0..<100 {
                    let fd = Darwin.accept(lfd, nil, nil)
                    if fd >= 0 {
                        // Accepted fd inherits O_NONBLOCK from listener; reset to blocking.
                        _ = Darwin.fcntl(fd, F_SETFL, Darwin.fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                        // Prevent a slow/stalled relay from blocking auth indefinitely.
                        var timeout = timeval(tv_sec: 5, tv_usec: 0)
                        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                        guard Self.clientHasSameUser(fd: fd) else {
                            Darwin.close(fd)
                            cont.resume(throwing: RelayError.ioError("relay peer uid mismatch"))
                            return
                        }
                        let relay = RelaySocket(fd: fd)
                        do {
                            try Self.verifyRelaySecret(relay, expected: expectedSecret)
                            cont.resume(returning: relay)
                        } catch {
                            relay.close()
                            cont.resume(throwing: error)
                        }
                        return
                    }
                    if errno != EAGAIN && errno != EWOULDBLOCK {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                cont.resume(throwing: RelayError.acceptTimedOut)
            }
        }
    }

    private static let kRelayAuthMaxPayload: Int = 256

    private nonisolated static func verifyRelaySecret(_ relay: RelaySocket, expected: String) throws {
        let frame = try relay.readFrame()
        guard frame.payload.count <= kRelayAuthMaxPayload else {
            throw RelayError.ioError("relay auth frame too large: \(frame.payload.count)")
        }
        let expectedBytes = Array(expected.utf8)
        let receivedBytes = Array(frame.payload)
        guard frame.type == kTypeAuth,
              constantTimeEquals(receivedBytes, expectedBytes)
        else {
            throw RelayError.ioError("relay auth failed")
        }
    }

    /// Length-aware, constant-time byte comparison. Iterates the
    /// longer of the two inputs so total work is independent of where
    /// the first divergence sits, defeating the wall-clock side
    /// channel that ordinary `==` exposes.
    private nonisolated static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = max(a.count, b.count)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }

    private nonisolated static func clientHasSameUser(fd: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        return result == 0 && cred.cr_uid == getuid()
    }

    // ── Bidirectional pumping ────────────────────────────────────────

    private func startPumping(relay: RelaySocket) {
        guard let session else { return }
        let surfaceID = self.surfaceID

        pumpTask = Task {
            // Host → relay: receive PtyData frames, write to relay socket.
            let hostToRelay = Task {
                while !Task.isCancelled {
                    let msg: PeerIncomingMessage
                    do {
                        msg = try await session.receiveNextMessage()
                    } catch {
                        try? relay.writeFrame(type: kTypeGoodbye, payload: Data("host-error".utf8))
                        break
                    }
                    switch msg {
                    case .ptyData(_, _, let data):
                        do {
                            try relay.writeFrame(type: kTypePtyData, payload: data)
                        } catch {
                            break
                        }
                    case .goodbye:
                        try? relay.writeFrame(type: kTypeGoodbye, payload: Data("host-goodbye".utf8))
                        return
                    default:
                        break
                    }
                }
                await self.disconnect()
            }

            // Relay → host: read frames from relay socket, forward to PeerSession.
            let relayToHost = Task {
                while !Task.isCancelled {
                    let frame: (type: UInt8, payload: Data)
                    do {
                        frame = try await Task.detached { try relay.readFrame() }.value
                    } catch {
                        break
                    }
                    switch frame.type {
                    case kTypeKeyInput:
                        try? await session.sendInput(surfaceID: surfaceID, keys: frame.payload)
                    case kTypeResize where frame.payload.count >= 4:
                        let cols = UInt32(UInt16(littleEndian: frame.payload.withUnsafeBytes {
                            $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
                        }))
                        let rows = UInt32(UInt16(littleEndian: frame.payload.withUnsafeBytes {
                            $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
                        }))
                        try? await session.sendResize(surfaceID: surfaceID, cols: cols, rows: rows)
                    case kTypeGoodbye:
                        try? await session.sendGoodbye(reason: "relay disconnected")
                        return
                    default:
                        break
                    }
                }
                await self.disconnect()
            }

            _ = await hostToRelay.result
            _ = await relayToHost.result
        }
    }

    private func disconnect() {
        pumpTask?.cancel()
        pumpTask = nil
        relaySocket?.close()
        relaySocket = nil
        let transport = self.transport
        let session = self.session
        self.session = nil
        self.transport = nil
        Task {
            try? await session?.sendGoodbye(reason: "relay-session teardown")
            await transport?.close()
        }
        onDisconnect?()
    }

    func stop() async {
        disconnect()
    }
}
