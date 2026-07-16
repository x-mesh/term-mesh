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
import Bonsplit
import Darwin
import PeerProto

// ── Frame types (must match relay binary) ───────────────────────────

private let kTypePtyData: UInt8  = 0x01
private let kTypeKeyInput: UInt8 = 0x02
private let kTypeResize: UInt8   = 0x03
private let kTypeGoodbye: UInt8  = 0xFF
private let kTypeAuth: UInt8     = 0xFE
private let kRelayMaxFrameBytes = 1024 * 1024
private let kRelayAuthMaxPayload = 256
private typealias RelayFrame = (type: UInt8, payload: Data)

// ── Two-stage handshake result ─────────────────────────────────────

/// Carries an open PeerSession and the surface list from a host. Yielded
/// by `PeerRelaySession.connectAndList` so the caller can show a picker
/// and then either call `PeerRelaySession.attach(_, surface:)` or
/// `cancel()` to release the connection cleanly.
struct PeerRelayConnection: Sendable {
    let hostSockPath: String
    let hostDisplayName: String
    /// Negotiated during handshake (part of `connect()`, no extra round
    /// trip). Callers gate optional RPCs (e.g. workspace CRUD) on this
    /// rather than assuming every host build supports them.
    let hostCapabilities: PeerCapabilities
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
    // Guards `isClosed` only; never held during a blocking write, so close()
    // can flip the flag without waiting on an in-flight writeFrame.
    private let closeStateLock = NSLock()
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
        // Flip the closed flag under a lock that is NEVER held during a
        // blocking write, so a stalled peer cannot make close() (and its
        // MainActor caller) block. shutdown() then wakes any in-flight
        // writeFrame holding writeLock with an error, so the writeLock
        // acquisition below cannot hang. shutdown/close run exactly once.
        closeStateLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        closeStateLock.unlock()
        guard !alreadyClosed else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        writeLock.lock()
        defer { writeLock.unlock() }
        Darwin.close(fd)
    }
}

private func writeFull(fd: Int32, data: Data) throws {
    var sent = 0
    while sent < data.count {
        let n = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress! + sent, data.count - sent)
        }
        if n <= 0 {
            if n < 0 && errno == EINTR { continue }  // signal-interrupted; retry
            throw RelayError.ioError("write failed: errno \(errno)")
        }
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
        if n <= 0 {
            if n < 0 && errno == EINTR { continue }  // signal-interrupted; retry (EOF n==0 stays fatal)
            throw RelayError.ioError("read EOF or error: errno \(errno)")
        }
        received += n
    }
}

enum RelayError: Error, Sendable {
    case ioError(String)
    case noRelayBinary(String)
    case listenerSetupFailed(String)
    case acceptTimedOut
}

private actor RelayFrameSlots {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var stoppedError: Error?

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    func acquire() async throws {
        if let stoppedError {
            throw stoppedError
        }
        if available > 0 {
            available -= 1
            return
        }
        #if DEBUG
        // Slots exhausted: the relay socket write side is backed up (relay
        // not draining → its stdout to Ghostty is blocked). Log only the
        // onset edge (0→1 waiter) so a sustained stall is one line, not one
        // per frame. This is the app→relay choke point in the "heavy output
        // → truncate → pane closes" chain.
        if waiters.isEmpty {
            dlog("peer.relay.backpressure.stall limit=\(limit) — relay socket write side backed up")
        }
        #endif
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if stoppedError != nil {
            available = min(limit, available + 1)
            return
        }
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            #if DEBUG
            // Drain edge: last waiter about to be resumed → backpressure cleared.
            if waiters.count == 1 {
                dlog("peer.relay.backpressure.drained")
            }
            #endif
            waiters.removeFirst().resume()
        }
    }

    func stop(error: Error) {
        guard stoppedError == nil else { return }
        stoppedError = error
        let pending = waiters
        waiters.removeAll()
        available = 0
        for waiter in pending {
            waiter.resume(throwing: error)
        }
    }
}

private final class RelayFrameWriter: @unchecked Sendable {
    private let relay: RelaySocket
    private let queue = DispatchQueue(label: "term-mesh.peer.relay.writer", qos: .userInitiated)
    private let slots = RelayFrameSlots(limit: 256)
    private let lock = NSLock()
    private var stopped = false
    private let onFailure: @Sendable (Error) -> Void

    init(relay: RelaySocket, onFailure: @escaping @Sendable (Error) -> Void) {
        self.relay = relay
        self.onFailure = onFailure
    }

    func enqueue(type: UInt8, payload: Data) async throws {
        let framePayload = payload
        try await slots.acquire()
        guard !isStopped else {
            await slots.release()
            throw RelayError.ioError("relay writer stopped")
        }

        queue.async {
            defer { Task { await self.slots.release() } }
            guard !self.isStopped else { return }
            do {
                try self.relay.writeFrame(type: type, payload: framePayload)
            } catch {
                if self.markStopped() {
                    Task {
                        await self.slots.stop(error: RelayError.ioError("relay writer stopped"))
                    }
                    self.onFailure(error)
                }
            }
        }
    }

    func stop() {
        if markStopped() {
            Task {
                await self.slots.stop(error: RelayError.ioError("relay writer stopped"))
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func markStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        stopped = true
        return true
    }
}

private final class RelayFrameReader: @unchecked Sendable {
    private let relay: RelaySocket
    private let queue = DispatchQueue(label: "term-mesh.peer.relay.reader", qos: .userInitiated)
    private let lock = NSLock()
    private var stopped = false

    init(relay: RelaySocket) {
        self.relay = relay
    }

    func frames() -> AsyncThrowingStream<RelayFrame, Error> {
        AsyncThrowingStream { continuation in
            queue.async {
                while !self.isStopped {
                    do {
                        continuation.yield(try self.relay.readFrame())
                    } catch {
                        if self.isStopped {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: error)
                        }
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                self.stop()
            }
        }
    }

    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        if shouldStop {
            relay.close()
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

// `internal` (not `private`) so `@testable import` can exercise the P9.2 gap
// heal logic directly — the trailing-debounce/throttle timing is impractical
// to verify through the flaky live workspace-mirror path.
actor RelayResizeCoalescer {
    private let session: PeerSession
    private let surfaceID: Data
    private let delayNs: UInt64
    private var pending: (cols: UInt32, rows: UInt32)?
    private var flushTask: Task<Void, Never>?
    /// Most recent size seen — the baseline for a P9.2 heal nudge.
    private var lastSize: (cols: UInt32, rows: UInt32)?
    /// The single trailing-debounce task for the current gap episode. Started
    /// once per episode and self-reschedules off `lastGapAt`, rather than being
    /// cancelled + recreated on every gap (the hot pump loop drops thousands of
    /// chunks/sec — per-gap Task churn is exactly what this path exists to
    /// survive).
    private var healTask: Task<Void, Never>?
    private let healDebounceSeconds: TimeInterval
    /// Timestamp of the most recent gap — the trailing debounce fires once this
    /// is `healDebounceSeconds` in the past (drops have settled).
    private var lastGapAt: Date = .distantPast
    /// Start of the current gap episode (nil = no active drops). Gates the
    /// throttle so a short burst heals only via the trailing debounce.
    private var gapEpisodeStart: Date?
    /// Last time a heal actually ran. Bounds the throttle to one heal per
    /// `healMaxWait` so a long CONTINUOUS-drop flood (slow network, no lull for
    /// the trailing debounce to ever fire) still gets periodic redraws instead
    /// of staying corrupt until the very end.
    private var lastHealAt: Date = .distantPast
    private let healMaxWait: TimeInterval

    init(
        session: PeerSession,
        surfaceID: Data,
        initialCols: UInt32,
        initialRows: UInt32,
        delayMs: UInt64 = 24,
        healDebounceMs: UInt64 = 400,
        healMaxWaitSeconds: TimeInterval = 2.0
    ) {
        self.session = session
        self.surfaceID = surfaceID
        self.delayNs = delayMs * 1_000_000
        self.healDebounceSeconds = TimeInterval(healDebounceMs) / 1000.0
        self.healMaxWait = healMaxWaitSeconds
        // Seed so a gap heal always has a size to nudge, even before the
        // relay's first resize frame reaches `submit` — for some mirror panes
        // that resize lags or never arrives, which silently no-op'd the heal
        // (performGapHeal returned at the `lastSize == nil` guard).
        if initialCols > 0 && initialRows > 0 {
            self.lastSize = (initialCols, initialRows)
        }
    }

    func submit(cols: UInt32, rows: UInt32) {
        pending = (cols, rows)
        lastSize = (cols, rows)
        guard flushTask == nil else { return }
        let delayNs = self.delayNs
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delayNs)
            await self.flushPending()
        }
    }

    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await flushPending()
    }

    func cancel() {
        flushTask?.cancel()
        flushTask = nil
        healTask?.cancel()
        healTask = nil
        gapEpisodeStart = nil
        pending = nil
    }

    private func flushPending() async {
        guard let size = pending else {
            flushTask = nil
            return
        }
        pending = nil
        flushTask = nil
        try? await session.sendResize(surfaceID: surfaceID, cols: size.cols, rows: size.rows)
    }

    // ── P9.2 gap heal ────────────────────────────────────────────────
    //
    // A host broadcast-Lag drop (P9.1) leaves the terminal truncated mid-
    // stream — a full-screen TUI stays corrupt until it redraws. Nudging the
    // remote size (shrink 1 col, then restore) makes the host apply
    // TIOCSWINSZ twice, so the child gets SIGWINCH and redraws its true state.
    // A shell ignores it. Debounced so a burst of thousands of gaps triggers
    // exactly one heal, once output settles (no point healing mid-flood).

    func noteGapForHeal() {
        let now = Date()
        lastGapAt = now
        if gapEpisodeStart == nil { gapEpisodeStart = now }
        // Throttle path: once an episode has run past `healMaxWait`, heal at
        // most once per `healMaxWait` even while drops keep streaming. A slow-
        // network flood produces continuous gaps with no lull, so the trailing
        // debounce below never fires until the very end — this guarantees
        // periodic redraws throughout instead of a single (or missed) one.
        if let episodeStart = gapEpisodeStart,
           now.timeIntervalSince(episodeStart) >= healMaxWait,
           now.timeIntervalSince(lastHealAt) >= healMaxWait {
            Task { [weak self] in await self?.performGapHeal(reason: "throttle") }
        }
        // Trailing-debounce path: start exactly ONE task per episode; it
        // self-reschedules off `lastGapAt` (updated above) rather than being
        // cancelled + recreated on every gap. Subsequent gaps only touch
        // `lastGapAt`, so no Task allocation scales with the drop rate.
        if healTask == nil {
            healTask = Task { [weak self] in await self?.runTrailingDebounce() }
        }
    }

    private func runTrailingDebounce() async {
        while true {
            let remaining = healDebounceSeconds - Date().timeIntervalSince(lastGapAt)
            guard remaining > 0 else { break }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled {
                healTask = nil
                return
            }
        }
        // Clear before healing so a gap arriving during the async heal starts a
        // fresh debounce task instead of being dropped.
        healTask = nil
        await performGapHeal(reason: "settle")
        endGapEpisode()
    }

    private func endGapEpisode() {
        gapEpisodeStart = nil
    }

    private func performGapHeal(reason: String) async {
        // Update first so the throttle window advances even when there is no
        // size to nudge yet (avoids a tight retry loop before the first resize).
        lastHealAt = Date()
        // Need ≥2 columns to nudge (shrink by one, then restore). A 0/1-col size
        // can't be nudged — and `size.cols - 1` on a UInt32 0 would trap (crash).
        guard let size = lastSize, size.cols > 1 else { return }
        let shrunk = size.cols - 1
        #if DEBUG
        dlog("peer.relay.gap.heal nudge redraw reason=\(reason) cols=\(size.cols) rows=\(size.rows)")
        #endif
        try? await session.sendResize(surfaceID: surfaceID, cols: shrunk, rows: size.rows)
        try? await session.sendResize(surfaceID: surfaceID, cols: size.cols, rows: size.rows)
    }
}

// ── PeerRelaySession ─────────────────────────────────────────────────

/// Manages the full relay lifetime for one remote-pane window.
/// 1. Creates a listener socket that the relay binary will connect to.
/// 2. Holds a PeerSession to the remote host.
/// 3. After start(), pumps data between host and relay.
@MainActor
final class PeerRelaySession {
    private static let setupReadTimeoutSeconds: TimeInterval = 10

    // Path the relay binary should connect to.
    let relaySockPath: String
    // Per-session secret the relay binary must echo before we forward input.
    let relaySecret: String
    // Relay binary location (must exist before calling start()).
    let relayBinaryPath: String
    // Shell-safe command string for Ghostty's command parser. Debug app
    // bundle paths contain spaces ("term-mesh DEV <tag>.app"), and
    // Ghostty treats `command` as a shell command rather than argv.
    var relayLaunchCommand: String { Self.shellQuote(relayBinaryPath) }

    let hostSockPath: String
    let hostDisplayName: String
    private let surfaceID: Data
    private let remoteCols: UInt32
    private let remoteRows: UInt32

    private var listenerFd: Int32 = -1
    private var relaySocket: RelaySocket?
    private var session: PeerSession?
    private var transport: UnixSocketTransport?
    private var pumpTask: Task<Void, Never>?
    private var isTorndown = false

    // ── Session ownership (P1 narrow session sharing) ────────────────
    //
    // ownsSession == true is the classic path: this instance opened its
    // own transport + PeerSession + handshake and tears them all down on
    // disconnect. ownsSession == false is the shared path: the pane
    // reuses the workspace's already-authenticated subscription session,
    // so teardown must only close the local relay socket + deregister
    // this surface from the demux — never stop the shared session's
    // heartbeat, send it a Goodbye, or close its transport (that would
    // kill every sibling pane).
    private let ownsSession: Bool
    // Shared path only: host→relay PtyData for THIS surface arrives here
    // (already de-multiplexed by surface_id) instead of via
    // `session.receiveNextMessage()`. nil on the owned-session path.
    private let ptyStream: AsyncStream<PeerPtyChunk>?
    // Shared path only: deregister this surface from the demux so its
    // stream finishes and the host→relay pump loop exits. nil otherwise.
    private let onSharedDetach: (@Sendable () async -> Void)?

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
        await connection.transport.setReadTimeoutSeconds(setupReadTimeoutSeconds)
        let surfaces: [Termmesh_Peer_V1_SurfaceInfo]
        do {
            surfaces = try await connection.session.listSurfaces()
        } catch {
            await connection.transport.setReadTimeoutSeconds(nil)
            await connection.cancel()
            throw error
        }
        await connection.transport.setReadTimeoutSeconds(nil)
        return PeerRelayConnection(
            hostSockPath: hostSockPath,
            hostDisplayName: connection.hostDisplayName,
            hostCapabilities: connection.hostCapabilities,
            session: connection.session,
            transport: connection.transport,
            surfaces: surfaces
        )
    }

    static func connect(hostSockPath: String) async throws -> PeerRelayConnection {
        let transport = try await UnixSocketTransport.connect(socketPath: hostSockPath)
        await transport.setReadTimeoutSeconds(setupReadTimeoutSeconds)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        let info: PeerSessionInfo
        do {
            info = try await session.handshake()
        } catch {
            await transport.close()
            throw error
        }
        await transport.setReadTimeoutSeconds(nil)
        return PeerRelayConnection(
            hostSockPath: hostSockPath,
            hostDisplayName: info.hostDisplayName,
            hostCapabilities: info.hostCapabilities,
            session: session,
            transport: transport,
            surfaces: []
        )
    }

    static func attach(
        _ connection: PeerRelayConnection,
        surface: Termmesh_Peer_V1_SurfaceInfo
    ) async throws -> PeerRelaySession {
        await connection.transport.setReadTimeoutSeconds(setupReadTimeoutSeconds)
        let outcome: PeerAttachOutcome
        do {
            outcome = try await connection.session.attachSurface(
                id: surface.surfaceID,
                mode: .coWrite,
                cols: UInt32(surface.cols),
                rows: UInt32(surface.rows)
            )
        } catch {
            await connection.transport.setReadTimeoutSeconds(nil)
            throw error
        }
        await connection.transport.setReadTimeoutSeconds(nil)

        let relaySockPath = try Self.makeRelaySocketPath()

        return PeerRelaySession(
            hostSockPath: connection.hostSockPath,
            hostDisplayName: connection.hostDisplayName,
            relaySockPath: relaySockPath,
            relaySecret: Self.makeRelaySecret(),
            surfaceID: outcome.surfaceID,
            remoteCols: UInt32(surface.cols),
            remoteRows: UInt32(surface.rows),
            session: connection.session,
            transport: connection.transport,
            ownsSession: true,
            ptyStream: nil,
            onSharedDetach: nil
        )
    }

    /// P1 narrow session sharing: attach a pane onto an already-handshaked
    /// session (the workspace subscription session) instead of opening a
    /// fresh transport + handshake. The single receive loop that owns
    /// `sharedSession` routes this surface's PtyData through `demux`; the
    /// returned session consumes that stream rather than reading frames
    /// directly (which would steal sibling panes' frames). Teardown never
    /// touches the shared session — see `ownsSession`.
    ///
    /// The consumer is registered with the demux BEFORE AttachSurface so
    /// the host's initial replay bytes are buffered, not dropped. On a
    /// failed attach the registration is rolled back and the error is
    /// rethrown so the caller can fall back to the owned-session path.
    static func attachShared(
        sharedSession: PeerSession,
        demux: PeerSessionDemux,
        hostSockPath: String,
        hostDisplayName: String,
        surface: Termmesh_Peer_V1_SurfaceInfo
    ) async throws -> PeerRelaySession {
        let surfaceID = surface.surfaceID
        let ptyStream = await demux.register(surfaceID: surfaceID)
        let outcome: PeerAttachOutcome
        do {
            outcome = try await sharedSession.attachSurface(
                id: surfaceID,
                mode: .coWrite,
                cols: UInt32(surface.cols),
                rows: UInt32(surface.rows)
            )
        } catch {
            await demux.deregister(surfaceID: surfaceID)
            throw error
        }

        let relaySockPath = try Self.makeRelaySocketPath()

        return PeerRelaySession(
            hostSockPath: hostSockPath,
            hostDisplayName: hostDisplayName,
            relaySockPath: relaySockPath,
            relaySecret: Self.makeRelaySecret(),
            surfaceID: outcome.surfaceID,
            remoteCols: UInt32(surface.cols),
            remoteRows: UInt32(surface.rows),
            session: sharedSession,
            transport: nil,
            ownsSession: false,
            ptyStream: ptyStream,
            onSharedDetach: { [weak demux] in
                await demux?.deregister(surfaceID: surfaceID)
            }
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
        do {
            return try await attach(conn, surface: chosen)
        } catch {
            await conn.cancel()
            throw error
        }
    }

    private init(
        hostSockPath: String,
        hostDisplayName: String,
        relaySockPath: String,
        relaySecret: String,
        surfaceID: Data,
        remoteCols: UInt32,
        remoteRows: UInt32,
        session: PeerSession,
        transport: UnixSocketTransport?,
        ownsSession: Bool,
        ptyStream: AsyncStream<PeerPtyChunk>?,
        onSharedDetach: (@Sendable () async -> Void)?
    ) {
        self.hostSockPath = hostSockPath
        self.hostDisplayName = hostDisplayName
        self.relaySockPath = relaySockPath
        self.relaySecret = relaySecret
        self.surfaceID = surfaceID
        self.remoteCols = remoteCols
        self.remoteRows = remoteRows
        self.session = session
        self.transport = transport
        self.ownsSession = ownsSession
        self.ptyStream = ptyStream
        self.onSharedDetach = onSharedDetach
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

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // ── Relay binary location ────────────────────────────────────────

    static func findRelayBinary() -> String {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath

        // Production: bundled under Contents/Resources/bin/, where every
        // other Rust binary lives (term-meshd, term-mesh-run, tm-agent).
        // Makefile deploy/deploy-prod/dmg targets copy them here.
        let bundledResource = bundlePath + "/Contents/Resources/bin/term-mesh-peer-relay"
        if fm.fileExists(atPath: bundledResource) { return bundledResource }

        // Legacy fallback: older builds may have placed it in MacOS/.
        let bundledMacOS = bundlePath + "/Contents/MacOS/term-mesh-peer-relay"
        if fm.fileExists(atPath: bundledMacOS) { return bundledMacOS }

        // Development: derive daemon/target/release from the DerivedData
        // path. Works for any developer when the app runs straight from
        // Xcode (./scripts/reload.sh, xcodebuild …) without committing a
        // hardcoded user-specific source root.
        if let derivedRoot = bundlePath.components(separatedBy: "/Build/").first {
            let derivedRelative = (derivedRoot + "/../daemon/target/release/term-mesh-peer-relay") as NSString
            let devPath = derivedRelative.standardizingPath
            if fm.fileExists(atPath: devPath) { return devPath }
        }

        // Last resort: cwd-relative for `swift run` / unit tests launched
        // from the repo root.
        let cwdPath = fm.currentDirectoryPath + "/daemon/target/release/term-mesh-peer-relay"
        if fm.fileExists(atPath: cwdPath) { return cwdPath }

        return bundledResource  // will fail at runtime; caller handles error
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
        // The listener has done its single job (one relay connection, no
        // reconnect). Release the fd + socket file now instead of holding them
        // until deinit. The accept poll has already resolved, so nothing else
        // touches listenerFd — closing it here cannot race a concurrent accept.
        if listenerFd >= 0 {
            Darwin.close(listenerFd)
            listenerFd = -1
        }
        try? FileManager.default.removeItem(atPath: relaySockPath)
        // App-level heartbeat: detect a remote daemon that has stopped
        // responding while its TCP socket is still considered alive
        // (laptop sleep on the remote, deadlocked daemon, etc.). When
        // the heartbeat declares the session dead we close the transport
        // so the pump's `receiveNextMessage()` unblocks with an error
        // and `disconnect()` runs through the normal teardown path
        // instead of leaving the user staring at a hung terminal.
        // Only the owned-session path drives its own heartbeat. On the
        // shared path the workspace controller owns the subscription
        // session's heartbeat, so a per-pane one would double-ping and,
        // worse, close the shared transport for every sibling on a miss.
        if ownsSession, let session, let transport {
            let weakTransport = transport
            await session.startHeartbeat(
                intervalSeconds: 10,
                deadAfterSeconds: 30,
                onFirstMiss: {
                    #if DEBUG
                    dlog("peer.relay.heartbeat.firstMiss — pong overdue > 1 interval (output backpressure starving the receive loop?)")
                    #endif
                },
                onMissRecovered: {
                    #if DEBUG
                    dlog("peer.relay.heartbeat.recovered")
                    #endif
                }
            ) {
                #if DEBUG
                dlog("peer.relay.heartbeat.dead — no pong for 30s, closing transport (this will end hostToRelay with receive-error → pane closes)")
                #endif
                Task { await weakTransport.close() }
            }
        }
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
                            Self.clearSocketReceiveTimeout(fd)
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

    private nonisolated static func clearSocketReceiveTimeout(_ fd: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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
        let disconnect: @Sendable (String) -> Void = { [weak self] reason in
            Task { @MainActor in
                self?.disconnect(reason: reason)
            }
        }
        let writer = RelayFrameWriter(relay: relay) { [weak self] error in
            // Surface the failure instead of letting every relay I/O error look
            // like a clean disconnect: log it (DEBUG) and fire onError so a
            // consumer can distinguish a crash from a goodbye.
            #if DEBUG
            dlog("peer.relay.writer.failure error=\(error)")
            #endif
            Task { @MainActor in self?.onError?(error) }
            disconnect("writer-failure")
        }
        let reader = RelayFrameReader(relay: relay)
        let resizeCoalescer = RelayResizeCoalescer(
            session: session,
            surfaceID: surfaceID,
            initialCols: remoteCols,
            initialRows: remoteRows
        )
        // Capture the sharing mode for the detached pumps. On the shared
        // path host→relay bytes arrive pre-demuxed via `ptyStream`; on the
        // owned path this task reads frames itself and filters by surface_id.
        let ptyStream = self.ptyStream
        let ownsSession = self.ownsSession
        let mySurfaceID = surfaceID

        pumpTask = Task.detached(priority: .userInitiated) {
            // Host → relay: deliver PtyData frames to the relay socket.
            let hostToRelay = Task.detached(priority: .userInitiated) {
                if let ptyStream {
                    // Shared session: the workspace demux already routed only
                    // THIS surface's PtyData here — no sibling frame to steal
                    // and nothing to filter. Stream end == demux deregistered
                    // this surface (pane close) or the shared session died.
                    //
                    // P9 gap detection on the SHARED path too: the demux
                    // carries each frame's byte_seq, and a jump past the
                    // previous frame's end means bytes were dropped upstream
                    // (host tap overflow, or the demux's own bounded buffer)
                    // — the mirror pane is now truncated. Before this the
                    // check lived only on the owned path below, so workspace
                    // mirror panes never detected drops and never healed.
                    var expectedByteSeq: UInt64?
                    var gapBytesTotal: UInt64 = 0
                    var gapCount = 0
                    for await chunk in ptyStream {
                        if Task.isCancelled { break }
                        if let expected = expectedByteSeq, chunk.byteSeq > expected {
                            let gap = chunk.byteSeq - expected
                            gapBytesTotal += gap
                            gapCount += 1
                            #if DEBUG
                            // Rate-limited like the owned path: one line per
                            // 500 gaps keeps a flood from wiping the ring.
                            if gapCount == 1 || gapCount % 500 == 0 {
                                dlog("peer.relay.gap #\(gapCount) dropped=\(gap) totalDropped=\(gapBytesTotal) — shared-path drop (content truncated)")
                            }
                            #endif
                            await resizeCoalescer.noteGapForHeal()
                        }
                        expectedByteSeq = chunk.byteSeq + UInt64(chunk.payload.count)
                        do {
                            try await writer.enqueue(type: kTypePtyData, payload: chunk.payload)
                        } catch {
                            disconnect("hostToRelay-enqueue-failed")
                            return
                        }
                    }
                    disconnect("hostToRelay-ptyStream-end")
                    return
                }
                // Owned session: read frames directly.
                // Labeled so a relay-write failure breaks the pump loop, not
                // just the switch — a bare `break` inside the switch would keep
                // looping and silently drop frames to a dead writer.
                var endReason = "hostToRelay-loop-end"
                // nil until the first PtyData establishes the baseline — without
                // this the initial frame (whose byte_seq may be the attach's
                // non-zero initial_seq) reads as a spurious gap vs 0.
                var expectedByteSeq: UInt64?
                var gapBytesTotal: UInt64 = 0
                var gapCount = 0
                pumpLoop: while !Task.isCancelled {
                    let msg: PeerIncomingMessage
                    do {
                        msg = try await session.receiveNextMessage()
                    } catch {
                        try? await writer.enqueue(type: kTypeGoodbye, payload: Data("host-error".utf8))
                        endReason = "hostToRelay-receive-error"
                        break pumpLoop
                    }
                    switch msg {
                    // Forward only this surface's output. Other-surface PtyData
                    // (never expected on a single-attach owned session, but the
                    // guard makes a shared session's stray frame a drop, not a
                    // mis-echo to the wrong pane's relay) falls to `default`.
                    case .ptyData(let sid, let byteSeq, let data) where sid == mySurfaceID:
                        // P9 gap detection: a byte_seq that jumps past the end of
                        // the previous frame means the host's broadcast dropped
                        // (Lagged) the bytes in between under load — the terminal
                        // is now truncated. Surface it here (heal = P9.2).
                        if let expected = expectedByteSeq, byteSeq > expected {
                            let gap = byteSeq - expected
                            gapBytesTotal += gap
                            gapCount += 1
                            #if DEBUG
                            // Rate-limited: a heavy flood drops thousands of
                            // chunks/sec; logging every one floods the debug
                            // ring (opening its circuit breaker and dropping
                            // OTHER events, including the heal logs). One line
                            // per 500 gaps is enough to see truncation happening.
                            if gapCount == 1 || gapCount % 500 == 0 {
                                dlog("peer.relay.gap #\(gapCount) dropped=\(gap) totalDropped=\(gapBytesTotal) — host broadcast Lag (content truncated)")
                            }
                            #endif
                            // P9.2: schedule a debounced redraw heal so a TUI
                            // corrupted by the drop recovers once output settles.
                            await resizeCoalescer.noteGapForHeal()
                        }
                        expectedByteSeq = byteSeq + UInt64(data.count)
                        do {
                            try await writer.enqueue(type: kTypePtyData, payload: data)
                        } catch {
                            endReason = "hostToRelay-enqueue-failed"
                            break pumpLoop
                        }
                    case .goodbye:
                        try? await writer.enqueue(type: kTypeGoodbye, payload: Data("host-goodbye".utf8))
                        // Tear down now so the sibling relayToHost task unblocks
                        // immediately instead of hanging until the heartbeat (~30s).
                        disconnect("host-goodbye")
                        return
                    default:
                        break
                    }
                }
                disconnect(endReason)
            }

            // Relay → host: read frames from relay socket, forward to PeerSession.
            let relayToHost = Task.detached(priority: .userInitiated) {
                do {
                    for try await frame in reader.frames() {
                        if Task.isCancelled { break }
                        switch frame.type {
                        case kTypeKeyInput:
                            do {
                                try await session.sendInput(surfaceID: surfaceID, keys: frame.payload)
                            } catch {
                                // Don't tear down on a single dropped keystroke, but
                                // make the loss visible instead of silently swallowing.
                                #if DEBUG
                                dlog("peer.relay.sendInput.failed error=\(error)")
                                #endif
                            }
                        case kTypeResize where frame.payload.count >= 4:
                            let cols = UInt32(UInt16(littleEndian: frame.payload.withUnsafeBytes {
                                $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
                            }))
                            let rows = UInt32(UInt16(littleEndian: frame.payload.withUnsafeBytes {
                                $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
                            }))
                            await resizeCoalescer.submit(cols: cols, rows: rows)
                        case kTypeGoodbye:
                            await resizeCoalescer.flushNow()
                            // Owned session only: a Goodbye on the shared
                            // subscription session would tear it down for every
                            // sibling pane. On the shared path disconnect() below
                            // just deregisters this surface from the demux.
                            if ownsSession {
                                try? await session.sendGoodbye(reason: "relay disconnected")
                            }
                            // Tear down now so the sibling hostToRelay task unblocks
                            // immediately instead of hanging until the heartbeat (~30s).
                            disconnect("relay-goodbye")
                            return
                        default:
                            break
                        }
                    }
                } catch {
                    // The normal teardown path also arrives here after the relay
                    // fd is closed. `disconnect()` below owns the user-visible state.
                }
                await resizeCoalescer.flushNow()
                disconnect("relayToHost-end")
            }

            _ = await hostToRelay.result
            _ = await relayToHost.result
            writer.stop()
            reader.stop()
            await resizeCoalescer.cancel()
        }
    }

    private func disconnect(reason: String) {
        // Multiple teardown paths (writer onFailure, hostToRelay end,
        // relayToHost end) all funnel here; without this guard onDisconnect?()
        // fires 2-3 times per session.
        guard !isTorndown else { return }
        isTorndown = true
        #if DEBUG
        // Which teardown path fired first is the key signal for the
        // "heavy input → truncate → pane closes" investigation: e.g. a
        // `hostToRelay-receive-error` right after a `heartbeat.dead` means
        // the heartbeat starved and killed the session under output load.
        dlog("peer.relay.disconnect reason=\(reason) ownsSession=\(ownsSession)")
        #endif
        pumpTask?.cancel()
        pumpTask = nil
        relaySocket?.close()
        relaySocket = nil
        let transport = self.transport
        let session = self.session
        self.session = nil
        self.transport = nil
        if ownsSession {
            // Owned path: this instance created the transport + heartbeat,
            // so it tears them all down.
            Task {
                await session?.stopHeartbeat()
                try? await session?.sendGoodbye(reason: "relay-session teardown")
                await transport?.close()
            }
        } else {
            // Shared path: leave the subscription session/transport/heartbeat
            // alone (the workspace controller owns them and its siblings still
            // use them). Only deregister this surface from the demux so its
            // PtyData stream finishes.
            let detach = onSharedDetach
            Task { await detach?() }
        }
        onDisconnect?()
    }

    func stop() async {
        disconnect(reason: "stop")
    }
}
