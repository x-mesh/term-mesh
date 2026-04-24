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

#if DEBUG
import Foundation
import Darwin
import PeerProto

// ── Frame types (must match relay binary) ───────────────────────────

private let kTypePtyData: UInt8  = 0x01
private let kTypeKeyInput: UInt8 = 0x02
private let kTypeResize: UInt8   = 0x03
private let kTypeGoodbye: UInt8  = 0xFF

// ── Relay socket wrapper ─────────────────────────────────────────────

/// Wraps a connected relay fd; provides framed reads and writes.
final class RelaySocket: @unchecked Sendable {
    let fd: Int32
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

    // Blocking send of a single frame (called from background tasks).
    func writeFrame(type: UInt8, payload: Data) throws {
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
        var payload = Data(count: len)
        if len > 0 {
            try readFull(fd: fd, into: &payload)
        }
        return (type, payload)
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

    // ── Factory ─────────────────────────────────────────────────────

    /// Connects to hostSockPath, picks first attachable surface, returns
    /// a ready-to-start PeerRelaySession.
    static func create(hostSockPath: String) async throws -> PeerRelaySession {
        let transport = try await UnixSocketTransport.connect(socketPath: hostSockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()
        let surfaces = try await session.listSurfaces()
        guard let chosen = surfaces.first(where: { $0.attachable }) ?? surfaces.first else {
            await transport.close()
            throw RelayError.ioError("host has no attachable surfaces")
        }
        let outcome = try await session.attachSurface(
            id: chosen.surfaceID,
            mode: .coWrite,
            cols: UInt32(chosen.cols),
            rows: UInt32(chosen.rows)
        )

        let uuid = UUID().uuidString.lowercased().prefix(8)
        let relaySockPath = "/tmp/tm-peer-relay-\(uuid).sock"

        return PeerRelaySession(
            hostSockPath: hostSockPath,
            relaySockPath: relaySockPath,
            surfaceID: outcome.surfaceID,
            remoteCols: UInt32(chosen.cols),
            remoteRows: UInt32(chosen.rows),
            session: session,
            transport: transport
        )
    }

    private init(
        hostSockPath: String,
        relaySockPath: String,
        surfaceID: Data,
        remoteCols: UInt32,
        remoteRows: UInt32,
        session: PeerSession,
        transport: UnixSocketTransport
    ) {
        self.hostSockPath = hostSockPath
        self.relaySockPath = relaySockPath
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
                        cont.resume(returning: RelaySocket(fd: fd))
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

    // ── Bidirectional pumping ────────────────────────────────────────

    private func startPumping(relay: RelaySocket) {
        guard let session else { return }
        let surfaceID = self.surfaceID

        pumpTask = Task {
            func pLog(_ msg: String) {
                let line = "\(Date()): [pump] \(msg)\n"
                if let data = line.data(using: .utf8) {
                    let url = URL(fileURLWithPath: "/tmp/peer-relay-trace.log")
                    if let fh = try? FileHandle(forWritingTo: url) {
                        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                    }
                }
            }

            // Host → relay: receive PtyData frames, write to relay socket.
            let hostToRelay = Task {
                pLog("hostToRelay started")
                var count = 0
                while !Task.isCancelled {
                    let msg: PeerIncomingMessage
                    do {
                        msg = try await session.receiveNextMessage()
                    } catch {
                        pLog("hostToRelay: receiveNextMessage error: \(error)")
                        try? relay.writeFrame(type: kTypeGoodbye, payload: Data("host-error".utf8))
                        break
                    }
                    count += 1
                    switch msg {
                    case .ptyData(_, _, let data):
                        pLog("hostToRelay: ptyData #\(count) \(data.count)B")
                        do {
                            try relay.writeFrame(type: kTypePtyData, payload: data)
                        } catch {
                            pLog("hostToRelay: writeFrame error: \(error)")
                            break
                        }
                    case .goodbye(let reason):
                        pLog("hostToRelay: host sent goodbye: \(reason)")
                        try? relay.writeFrame(type: kTypeGoodbye, payload: Data("host-goodbye".utf8))
                        return
                    default:
                        pLog("hostToRelay: ignoring msg #\(count): \(msg)")
                        break
                    }
                }
                pLog("hostToRelay: exiting, calling disconnect")
                await self.disconnect()
            }

            // Relay → host: read frames from relay socket, forward to PeerSession.
            let relayToHost = Task {
                pLog("relayToHost started")
                while !Task.isCancelled {
                    let frame: (type: UInt8, payload: Data)
                    do {
                        frame = try await Task.detached { try relay.readFrame() }.value
                    } catch {
                        pLog("relayToHost: readFrame error: \(error)")
                        break
                    }
                    pLog("relayToHost: got frame type=0x\(String(frame.type, radix: 16)) size=\(frame.payload.count)")
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
                        pLog("relayToHost: resize \(cols)x\(rows)")
                        try? await session.sendResize(surfaceID: surfaceID, cols: cols, rows: rows)
                    case kTypeGoodbye:
                        pLog("relayToHost: relay sent goodbye")
                        try? await session.sendGoodbye(reason: "relay disconnected")
                        return
                    default:
                        pLog("relayToHost: unknown frame type 0x\(String(frame.type, radix: 16))")
                        break
                    }
                }
                pLog("relayToHost: exiting, calling disconnect")
                await self.disconnect()
            }

            _ = await hostToRelay.result
            _ = await relayToHost.result
        }
    }

    private func disconnect() {
        pumpTask?.cancel()
        pumpTask = nil
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
#endif
