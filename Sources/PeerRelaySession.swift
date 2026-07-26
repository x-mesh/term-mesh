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
    /// The host's advertised app version (`PeerSessionInfo.hostAppVersion`),
    /// carried through for version-visibility logging/UX. Optional so a
    /// future caller that cannot re-derive it from a live handshake (e.g. a
    /// cached/reconstructed connection) can represent "unknown" rather than
    /// a misleading empty string.
    let hostAppVersion: String?
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
    case capabilityUnavailable(String)
    case ensureRejected(code: String, stage: String, safeContext: String)
    case surfaceIDMismatch
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
    // 32 (was 256): a smaller app→relay writer window pushes backpressure to
    // the host sooner, so an output flood cannot pile up MBs of stale bytes
    // that keep rendering after the user hits Ctrl+C. Measured on a jw-server
    // relay pane: 588 KB burst drain 997ms → 660ms; combined with the host's
    // larger READ_BUF coalescing, 3.4 MB drain went ~9s → ~1s. No throughput
    // regression observed (drain stayed linear at ~10 MB/s).
    private let slots = RelayFrameSlots(limit: 32)
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
    // `var`, not `let`: a successful R3 resume-heal reconnect (see
    // `PeerRelaySession.performResumeHeal`) hands this actor the new
    // session via `adopt(session:)` so an ordinary resize sent right after
    // a swap still lands on the live connection instead of the retired one.
    private var session: PeerSession
    private let surfaceID: Data
    private let delayNs: UInt64
    private var pending: (cols: UInt32, rows: UInt32)?
    private var flushTask: Task<Void, Never>?
    /// The heal action itself. Owned by `PeerRelaySession`, not this actor:
    /// R3 replaced the old in-place resize nudge with a resume re-attach,
    /// which needs `PeerRelaySession`'s session/transport/seq-tracking state
    /// this actor doesn't (and shouldn't) hold. This actor keeps owning only
    /// the debounce/throttle *timing* — see the class doc comment.
    private let onHeal: @Sendable (String) async -> Void
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
        healMaxWaitSeconds: TimeInterval = 2.0,
        onHeal: @escaping @Sendable (String) async -> Void
    ) {
        self.session = session
        self.surfaceID = surfaceID
        self.delayNs = delayMs * 1_000_000
        self.healDebounceSeconds = TimeInterval(healDebounceMs) / 1000.0
        self.healMaxWait = healMaxWaitSeconds
        self.onHeal = onHeal
        // Seed so a gap heal always has a size to nudge, even before the
        // relay's first resize frame reaches `submit` — for some mirror panes
        // that resize lags or never arrives, which silently no-op'd the heal
        // (performGapHeal returned at the `lastSize == nil` guard).
        if initialCols > 0 && initialRows > 0 {
            self.lastSize = (initialCols, initialRows)
        }
    }

    /// R3: re-target this actor's normal (non-heal) resize forwarding at a
    /// session that replaced a retired one via a resume-heal reconnect.
    func adopt(session: PeerSession) {
        self.session = session
    }

    /// The most recently known remote size, so `performResumeHeal` can
    /// re-attach at the size the pane is actually showing instead of the
    /// (possibly stale) size captured at the original attach.
    func snapshotSize() -> (cols: UInt32, rows: UInt32)? {
        lastSize
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
    // stream — a full-screen TUI stays corrupt until it redraws, and any
    // scrolled-off output in the gap is gone from the live stream for good.
    // R3 (peer-relay-bulk-loss) replaced the original fix — nudging the
    // remote size (shrink 1 col, then restore) to force a SIGWINCH redraw —
    // with an actual resume request: `onHeal` (owned by `PeerRelaySession`)
    // re-attaches the surface with `resume_from_seq` set to the exact point
    // this pane last processed, so the host's replay ring can stream the
    // missing bytes back instead of just prompting a redraw of already-
    // truncated state. This actor still owns the debounce/throttle timing
    // below — only the *action* moved out.
    //
    // Debounced so a burst of thousands of gaps triggers exactly one heal,
    // once output settles (no point healing mid-flood).

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
        // size to heal with yet (avoids a tight retry loop before the first
        // resize/attach establishes one).
        lastHealAt = Date()
        // A resume re-attach still needs a sane size to send as
        // client_cols/client_rows; a 0-sized pane (e.g. a transient 0-col
        // resize from the relay) isn't worth reconnecting for.
        guard let size = lastSize, size.cols > 0, size.rows > 0 else { return }
        #if DEBUG
        dlog("peer.relay.gap.heal reason=\(reason) cols=\(size.cols) rows=\(size.rows)")
        #endif
        await onHeal(reason)
    }
}

/// R3 (peer-relay-bulk-loss): the last-processed wire `byte_seq` (this
/// attach's own 0-based space — see `PeerServer.swift`'s wire↔host seq
/// mapping doc), written by the hot host→relay pump loop on every PtyData
/// chunk (thousands/sec under load) and read only by the rare resume-heal
/// path (`PeerRelaySession.performResumeHeal`, at most ~once per
/// `healMaxWaitSeconds`). A plain `NSLock` box rather than a MainActor
/// property or an actor: the write side must never pay a cross-context hop.
private final class WireSeqTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func update(_ newValue: UInt64) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// tmux-copy-mode-style scrollback browse state, shared between the
/// MainActor (wheel events enter/steer the browse) and the pump task
/// (which must suppress live PtyData while a past window is on screen —
/// otherwise live output paints over the browsed history). Same
/// NSLock-box shape as `WireSeqTracker`, for the same reason: the pump
/// touches this per chunk and must not pay a MainActor hop.
private final class ScrollbackBrowse: @unchecked Sendable {
    private let lock = NSLock()
    /// Rows above the live bottom currently displayed. nil = live screen.
    private var offset: UInt32?
    /// The host said the last rendered window is its oldest history.
    private var atTop = false
    /// One request on the wire at a time; wheel steps meanwhile land in
    /// `pending` and are re-requested when the current chunk arrives.
    private var inFlight = false
    private var pending: UInt32?

    var isBrowsing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offset != nil
    }

    /// Turn a wheel step into the offset that should be requested now, or
    /// nil when nothing should be sent (mid-flight steps park in
    /// `pending`; upward steps at the top are dropped).
    func requestForWheel(up: Bool, step: UInt32, atLocalTop: Bool) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        switch offset {
        case nil:
            // Enter only on an upward step when the local scrollback is
            // already exhausted — downward wheel on the live screen is
            // none of our business.
            guard up && atLocalTop else { return nil }
            return stage(step)
        case .some(let current):
            if up {
                guard !atTop else { return nil }
                return stage(current &+ step)
            }
            // Downward: toward (and at 0, back onto) the live screen.
            return stage(current > step ? current - step : 0)
        }
    }

    /// The exit request (offset 0 = the live render). nil when not browsing.
    func requestForExit() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        guard offset != nil else { return nil }
        return stage(0)
    }

    /// Must be called with the lock held.
    private func stage(_ wanted: UInt32) -> UInt32? {
        if inFlight {
            pending = wanted
            return nil
        }
        inFlight = true
        return wanted
    }

    /// Record an arrived chunk. Returns the parked follow-up request to
    /// send, if any. `browsingAfter` is false once the live screen (offset
    /// 0) is back on display.
    func noteChunk(effectiveOffset: UInt32, atTop: Bool) -> (followUp: UInt32?, browsingAfter: Bool) {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
        self.atTop = atTop
        offset = effectiveOffset == 0 ? nil : effectiveOffset
        if let next = pending, next != effectiveOffset {
            pending = nil
            inFlight = true
            return (next, offset != nil)
        }
        pending = nil
        return (nil, offset != nil)
    }

    /// The host proved itself grid-snapshot-capable (sent a typed
    /// GridSnapshot). Requests to an older host would just be dropped, so
    /// the browse refuses to engage until this flips — the wheel then
    /// stays on the local scrollback, which still holds replayed bytes on
    /// the legacy path.
    private var hostCapable = false

    func markHostCapable() {
        lock.lock()
        hostCapable = true
        lock.unlock()
    }

    var isHostCapable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hostCapable
    }

    /// Hard reset (session teardown / reconnect).
    func reset() {
        lock.lock()
        offset = nil
        atTop = false
        inFlight = false
        pending = nil
        lock.unlock()
    }
}

/// Adopted by `PeerRelaySession`; consumed by the pane's scroll-view
/// wrapper so wheel events can steer a scrollback browse instead of the
/// local (empty-above-the-snapshot) Ghostty scrollback.
@MainActor
protocol PeerScrollbackBrowseHandling: AnyObject {
    /// Returns true when the event was consumed by the browse.
    func handleBrowseWheel(up: Bool, atLocalTop: Bool) -> Bool
}

// ── PeerRelaySession ─────────────────────────────────────────────────

/// Byte accounting for a single relay session, for post-hoc diagnosis of a
/// pane that opened but never rendered.
///
/// Nothing in the host→pane chain counted bytes before this, which left the
/// two halves of a blank pane indistinguishable: "the host sent nothing" and
/// "we received bytes and lost them downstream" produced identical logs
/// (namely, none). `peer.relay.gap` cannot cover the first case — it only
/// arms once a first frame establishes `expectedByteSeq`, so a session that
/// receives zero bytes never reports anything at all.
///
/// Lock-guarded and deliberately outside the MainActor annotation below: the
/// counters are written from the pump loop, so an actor hop per chunk would
/// be a real cost. Same shape as `WireSeqTracker` above.
private final class RelayIOStats: @unchecked Sendable {
    private let lock = NSLock()
    private var received: UInt64 = 0
    private var enqueued: UInt64 = 0
    private var chunks: UInt64 = 0
    private var sawFirst = false

    /// Returns true only for the first chunk, so the caller logs `firstByte`
    /// exactly once without keeping a second flag. No timestamp is kept here:
    /// `dlog` already stamps every line, and holding a `Date` would drag this
    /// type onto the main actor under the project's default isolation.
    func noteReceived(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        received += UInt64(count)
        chunks += 1
        guard !sawFirst else { return false }
        sawFirst = true
        return true
    }

    func noteEnqueued(_ count: Int) {
        lock.lock()
        enqueued += UInt64(count)
        lock.unlock()
    }

    var sawFirstByte: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawFirst
    }

    func read() -> (received: UInt64, enqueued: UInt64, chunks: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (received, enqueued, chunks)
    }
}

/// Manages the full relay lifetime for one remote-pane window.
/// 1. Creates a listener socket that the relay binary will connect to.
/// 2. Holds a PeerSession to the remote host.
/// 3. After start(), pumps data between host and relay.
@MainActor
final class PeerRelaySession {
    private static let setupReadTimeoutSeconds: TimeInterval = 10
    /// How long after `start()` a session may render nothing before it is
    /// worth a log line. Long enough that a slow shell spawn is not noise,
    /// short enough that the marker lands while the incident is live.
    private static let firstByteWatchdogSeconds: TimeInterval = 3

    /// Byte counters for this session. Private like `WireSeqTracker`: the
    /// project's default isolation pins an internal type to MainActor, and
    /// these are written from the pump loop. Exposed through `ioSnapshot`.
    private let ioStats = RelayIOStats()

    /// Counter snapshot for `debugPaneStatus()` — lets a live probe tell
    /// "nothing ever arrived" from "arrived and was lost downstream".
    var ioSnapshot: [String: Any] {
        let c = ioStats.read()
        return [
            "bytes_received": c.received,
            "bytes_enqueued": c.enqueued,
            "chunks": c.chunks,
            "saw_first_byte": ioStats.sawFirstByte,
        ]
    }

    /// One-line counter summary for the disconnect / watchdog log lines.
    var ioSummary: String {
        let c = ioStats.read()
        return "received=\(c.received) enqueued=\(c.enqueued) chunks=\(c.chunks)"
    }

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

    /// Environment for the relay helper. Single source for all three spawn
    /// sites (pane, relay window, workspace-relay window), which previously
    /// each inlined the same two keys — so a third key had to be remembered
    /// in three places or it silently applied to only some panes.
    var relayEnvironment: [String: String] {
        var env = [
            "TERMMESH_PEER_RELAY_SOCKET": relaySockPath,
            "TERMMESH_PEER_RELAY_SECRET": relaySecret,
        ]
        #if DEBUG
        // The helper logs cumulative output and its exit cause with errno,
        // but `rlog` is inert unless this is set (or a marker file was created
        // beforehand) — so that instrumentation was dark exactly when it was
        // needed, after an incident nobody predicted. The helper spans the one
        // process boundary the app cannot see across.
        env["TERMMESH_PEER_RELAY_DEBUG"] = "1"
        #endif
        return env
    }

    let hostSockPath: String
    let hostDisplayName: String
    /// Which machine this session reaches, for state that belongs to the
    /// host rather than to one pane (its load, memory, and I/O rates).
    /// `hostSockPath` cannot stand in: for an SSH host it is the local end
    /// of a tunnel, which says nothing about which machine is on the far
    /// side. Set by the caller that owns the lease; nil for sessions opened
    /// without one, which simply record nothing.
    var hostKey: PeerPaneHostKey?
    private let surfaceID: Data
    private let remoteCols: UInt32
    private let remoteRows: UInt32

    private var listenerFd: Int32 = -1
    private var relaySocket: RelaySocket?
    private var session: PeerSession?
    private var transport: UnixSocketTransport?
    private var pumpTask: Task<Void, Never>?
    private var isTorndown = false
    // Stored (not just local to `startPumping`) so `performResumeHeal` can
    // read the live remote size and re-target its session after a swap.
    private var resizeCoalescer: RelayResizeCoalescer?

    // ── R3 resume heal (peer-relay-bulk-loss) ─────────────────────────
    //
    // Absolute host seq (`PtyChunk.seq` space) that this attach's wire
    // byte_seq == 0 maps to — see `PeerServer.swift`'s wire↔host seq
    // mapping doc for the full contract. Together with `wireSeqTracker`
    // this is everything `performResumeHeal` needs to compute
    // `resume_from_seq = attachInitialSeq + <last processed wire seq>`.
    // Updated on the initial attach and on every successful resume
    // re-attach (the new attach's own wire byte_seq resets to 0).
    private var attachInitialSeq: UInt64
    // Whether the live host advertised `replay.ring.v1` at the last
    // (re)attach. An older host neither reads nor honors
    // `resume_from_seq`, so this client gates it explicitly rather than
    // relying on the host silently ignoring an unrecognized field.
    private var hostSupportsReplayRing: Bool
    private let wireSeqTracker = WireSeqTracker()
    /// Scrollback browse state (tmux copy-mode model). Shared with the
    /// pump task, hence a lock box rather than MainActor state.
    private let scrollbackBrowse = ScrollbackBrowse()

    // Guards against piling up concurrent reconnect attempts if the
    // debounce and throttle heal paths both fire before the first one
    // finishes.
    private var resumeInFlight = false

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

    /// Explicit host-side termination. Ordinary local pane close must not call
    /// this; it only detaches the relay and leaves the remote PTY alive.
    func requestRemoteClose() async throws {
        guard let session else { return }
        try await session.requestClosePane(paneID: surfaceID)
    }

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
            hostAppVersion: connection.hostAppVersion,
            hostCapabilities: connection.hostCapabilities,
            session: connection.session,
            transport: connection.transport,
            surfaces: surfaces
        )
    }

    static func connect(hostSockPath: String) async throws -> PeerRelayConnection {
        let transport = try await UnixSocketTransport.connect(socketPath: hostSockPath)
        await transport.setReadTimeoutSeconds(setupReadTimeoutSeconds)
        // The transport-aware initializer gives PeerSession a close hook.
        // Cancelling a correlated ensure then shuts down the socket, which
        // wakes a suspended read before the caller releases its tunnel lease.
        let session = PeerSession(transport: transport)
        let info: PeerSessionInfo
        do {
            info = try await session.handshake()
        } catch {
            await transport.close()
            throw error
        }
        await transport.setReadTimeoutSeconds(nil)
        #if DEBUG
        dlog("peer.relay.hostVersion displayName=\(info.hostDisplayName) appVersion=\(info.hostAppVersion) protocolVersion=\(info.hostProtocolVersion)")
        #endif
        // Debug rather than info: it is the same three values on every
        // connection until the day they are not, and a version skew is the
        // first thing to check when a feature works on one host and not
        // another.
        RemoteWorkLog.debugOffMain(
            "Host \(info.hostDisplayName) — app \(info.hostAppVersion), protocol \(info.hostProtocolVersion)"
        )
        return PeerRelayConnection(
            hostSockPath: hostSockPath,
            hostDisplayName: info.hostDisplayName,
            hostAppVersion: info.hostAppVersion,
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
        guard outcome.surfaceID == surface.surfaceID else {
            // Nothing logged this at all, and the error reaches the user as a
            // pane that simply never opens. Both ids are here because the
            // difference between them is the diagnosis: the host redirected
            // the attachment to a surface other than the one that was picked.
            RemoteWorkLog.infoOffMain(
                "Attach refused: asked for surface \(surface.surfaceID), host attached \(outcome.surfaceID)"
            )
            throw RelayError.surfaceIDMismatch
        }

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
            onSharedDetach: nil,
            attachInitialSeq: outcome.initialByteSeq,
            hostSupportsReplayRing: connection.hostCapabilities.has(PeerCapability.replayRingV1)
        )
    }

    /// Reconcile a saved process recipe over the already-handshaked
    /// connection. This is deliberately separate from `connectAndList`: no
    /// surface roster is fetched and no picker can influence the returned id.
    static func ensureSurface(
        _ connection: PeerRelayConnection,
        spec: PeerRunnerSurfaceSpec
    ) async throws -> PeerEnsureSurfaceOutcome {
        guard connection.hostCapabilities.has(PeerCapability.surfaceEnsureV1) else {
            throw RelayError.capabilityUnavailable(PeerCapability.surfaceEnsureV1)
        }
        await connection.transport.setReadTimeoutSeconds(setupReadTimeoutSeconds)
        let outcome: PeerEnsureSurfaceOutcome
        do {
            outcome = try await connection.session.ensureSurface(
                key: spec.key,
                cwd: spec.cwd,
                executable: spec.executable,
                args: spec.args,
                restartPolicy: spec.restartPolicy.wireValue
            )
        } catch {
            await connection.transport.setReadTimeoutSeconds(nil)
            throw error
        }
        await connection.transport.setReadTimeoutSeconds(nil)

        switch outcome.result {
        case .created, .reused, .recreated:
            guard !outcome.surfaceID.isEmpty else {
                throw RelayError.ensureRejected(
                    code: "MALFORMED_RESPONSE", stage: "ensure", safeContext: "missing surface_id"
                )
            }
            return outcome
        case .specConflict, .failed, .unspecified, .UNRECOGNIZED:
            let failure = outcome.error
            throw RelayError.ensureRejected(
                code: failure.map { Self.ensureErrorCode($0.code) }
                    ?? Self.ensureResultErrorCode(outcome.result),
                stage: failure?.stage.isEmpty == false ? failure!.stage : "ensure",
                safeContext: failure?.safeContext ?? ""
            )
        }
    }

    private static func ensureResultErrorCode(
        _ result: Termmesh_Peer_V1_EnsureSurfaceResult
    ) -> String {
        switch result {
        case .specConflict: return "SPEC_CONFLICT"
        case .failed: return "ENSURE_FAILED"
        case .unspecified: return "MALFORMED_RESPONSE"
        case .UNRECOGNIZED(let raw): return "UNRECOGNIZED_RESULT_\(raw)"
        case .created, .reused, .recreated: return "ENSURE_FAILED"
        }
    }

    private static func ensureErrorCode(
        _ code: Termmesh_Peer_V1_EnsureSurfaceErrorCode
    ) -> String {
        switch code {
        case .unspecified: return "ENSURE_FAILED"
        case .invalidRequest: return "INVALID_REQUEST"
        case .requestTooLarge: return "REQUEST_TOO_LARGE"
        case .duplicateRequestID: return "DUPLICATE_REQUEST_ID"
        case .cwdNotFound: return "CWD_NOT_FOUND"
        case .cwdNotDirectory: return "CWD_NOT_DIRECTORY"
        case .cwdPermissionDenied: return "CWD_PERMISSION_DENIED"
        case .commandNotFound: return "COMMAND_NOT_FOUND"
        case .commandExited: return "COMMAND_EXITED"
        case .specConflict: return "SPEC_CONFLICT"
        case .internal: return "INTERNAL"
        case .commandPermissionDenied: return "COMMAND_PERMISSION_DENIED"
        case .commandSignaled: return "COMMAND_SIGNALED"
        case .commandExecError: return "COMMAND_EXEC_ERROR"
        case .cwdError: return "CWD_ERROR"
        case .execHandshakeTruncated: return "EXEC_HANDSHAKE_TRUNCATED"
        case .execHandshakeInvalidStage: return "EXEC_HANDSHAKE_INVALID_STAGE"
        case .execHandshakeTimeout: return "EXEC_HANDSHAKE_TIMEOUT"
        case .UNRECOGNIZED(let raw): return "UNRECOGNIZED_\(raw)"
        }
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
        surface: Termmesh_Peer_V1_SurfaceInfo,
        // R3: no caller passes this today (WorkspaceMirror doesn't thread
        // its handshake's capabilities through here), and the shared path
        // can't safely resume-reattach on a session it doesn't own anyway
        // (see `performResumeHeal`'s `ownsSession` fallback) — kept as an
        // explicit, defaulted parameter rather than hardcoding `false` so a
        // future caller that DOES have it doesn't have to fight a hidden
        // assumption.
        hostCapabilities: PeerCapabilities = PeerCapabilities()
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
            },
            attachInitialSeq: outcome.initialByteSeq,
            hostSupportsReplayRing: hostCapabilities.has(PeerCapability.replayRingV1)
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
        onSharedDetach: (@Sendable () async -> Void)?,
        attachInitialSeq: UInt64,
        hostSupportsReplayRing: Bool
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
        self.attachInitialSeq = attachInitialSeq
        self.hostSupportsReplayRing = hostSupportsReplayRing
        self.relayBinaryPath = Self.findRelayBinary()
    }

    deinit {
        // Defense-in-depth: if a session is dropped WITHOUT disconnect()
        // (e.g. an owner deallocated without calling teardown/stop), the
        // detached pumpTask keeps the RelaySocket alive off-object, so the
        // relay helper never gets EOF and leaks. Cancelling the pump and
        // closing the socket here forces EOF → the relay exits. Both are
        // idempotent (no-ops after disconnect() already ran).
        pumpTask?.cancel()
        relaySocket?.close()
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
        #if DEBUG
        // A successful accept was previously invisible, which made "the helper
        // never launched" and "the helper connected but nothing came through"
        // look identical after the fact.
        dlog("peer.relay.accept ok sock=\(relaySockPath)")
        #endif
        // Watchdog: a pane that attaches and receives nothing produces no log
        // at all today — `peer.relay.gap` only arms after a first frame sets
        // `expectedByteSeq`, so the zero-byte case is exactly the one that
        // stays silent. One deferred line makes it visible.
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.firstByteWatchdogSeconds * 1_000_000_000)
            )
            // `isTorndown` as well as the byte check: a session that
            // disconnected before its first byte is still held by the pane
            // (it renders the disconnect banner), so without this the
            // watchdog fires on an already-dead connection and tells the
            // user a closed pane "may render blank".
            guard let self, !self.ioStats.sawFirstByte, !self.isTorndown else { return }
            #if DEBUG
            dlog("peer.relay.firstByte.timeout — no PtyData \(Int(Self.firstByteWatchdogSeconds))s after accept (\(self.ioSummary))")
            #endif
            RemoteWorkLog.infoOffMain(
                "Remote pane has received no output \(Int(Self.firstByteWatchdogSeconds))s after connecting — it may render blank"
            )
        }
        // The listener has done its single job (one relay connection, no
        // reconnect). Release the fd + socket file now instead of holding them
        // until deinit. The accept poll has already resolved, so nothing else
        // touches listenerFd — closing it here cannot race a concurrent accept.
        if listenerFd >= 0 {
            Darwin.close(listenerFd)
            listenerFd = -1
        }
        try? FileManager.default.removeItem(atPath: relaySockPath)
        // Only the owned-session path drives its own heartbeat. On the
        // shared path the workspace controller owns the subscription
        // session's heartbeat, so a per-pane one would double-ping and,
        // worse, close the shared transport for every sibling on a miss.
        if ownsSession, let session, let transport {
            await startHeartbeatMonitoring(session: session, transport: transport)
        }
        startPumping(relay: relay)
    }

    /// App-level heartbeat: detect a remote daemon that has stopped
    /// responding while its TCP socket is still considered alive (laptop
    /// sleep on the remote, deadlocked daemon, etc.). When the heartbeat
    /// declares the session dead we close the transport so the pump's
    /// `receiveNextMessage()` unblocks with an error and `disconnect()`
    /// runs through the normal teardown path instead of leaving the user
    /// staring at a hung terminal. Owned-session path only (see call
    /// sites) — shared by `start()`'s initial attach and, since R3, by
    /// `performResumeHeal`'s resumed re-attach, both of which need the
    /// exact same monitoring wired onto whichever session is current.
    private func startHeartbeatMonitoring(session: PeerSession, transport: UnixSocketTransport) async {
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
            RemoteWorkLog.infoOffMain("Host stopped answering for 30s — closing the connection")
            Task { await weakTransport.close() }
        }
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
            initialRows: remoteRows,
            onHeal: { [weak self] reason in
                await self?.performResumeHeal(reason: reason)
            }
        )
        // Stored so `performResumeHeal` (an instance method outside this
        // closure) can read the live remote size and re-target this actor's
        // session after a resume-heal swap.
        self.resizeCoalescer = resizeCoalescer
        // Capture the sharing mode for the detached pumps. On the shared
        // path host→relay bytes arrive pre-demuxed via `ptyStream`; on the
        // owned path this task reads frames itself and filters by surface_id.
        let ptyStream = self.ptyStream
        let ownsSession = self.ownsSession
        let mySurfaceID = surfaceID
        // R3: plain Sendable reference, captured like `writer`/`reader` above
        // rather than read via `self.` inside the detached closures below.
        let wireSeqTracker = self.wireSeqTracker
        let scrollbackBrowse = self.scrollbackBrowse

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
                            // Rate-limited like the owned path: one line per
                            // 500 gaps keeps a flood from wiping the ring.
                            if gapCount == 1 || gapCount % 500 == 0 {
                                #if DEBUG
                                // "peer.relay.gap" is on DebugEventLog's circuit-breaker
                                // bypass whitelist — a flood that trips the 500 logs/s
                                // breaker must not also swallow the one line that explains
                                // why the pane just went blank.
                                dlog("peer.relay.gap #\(gapCount) dropped=\(gap) totalDropped=\(gapBytesTotal) — shared-path drop (content truncated)")
                                #endif
                                // `.info`, not `.debug`: this must reach the drawer on
                                // gapCount == 1 regardless of the user's log-level
                                // setting (default .info drops .debug lines), so the
                                // very first drop of a flood is seen at least once —
                                // not just recorded in a file nobody is watching.
                                RemoteWorkLog.infoOffMain(
                                    "Output dropped on the shared path — \(gap) bytes (\(gapBytesTotal) total over \(gapCount) gaps); the pane is missing content"
                                )
                            }
                            await resizeCoalescer.noteGapForHeal()
                        }
                        expectedByteSeq = chunk.byteSeq + UInt64(chunk.payload.count)
                        if self.ioStats.noteReceived(chunk.payload.count) {
                            #if DEBUG
                            // Splits the blank-pane failure space in half: with
                            // this line the host did send and any loss is
                            // downstream; without it nothing ever arrived.
                            dlog("peer.relay.firstByte path=shared bytes=\(chunk.payload.count)")
                            #endif
                        }
                        do {
                            try await writer.enqueue(type: kTypePtyData, payload: chunk.payload)
                            self.ioStats.noteEnqueued(chunk.payload.count)
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
                // R3: mutable, not the closure-captured `session` constant —
                // `performResumeHeal` retires this session (Goodbye + close)
                // only once its resumed replacement is already live in
                // `self.session`, so a receive error here can mean either a
                // real disconnect or a deliberate swap to pump up next.
                var currentSession = session
                pumpLoop: while !Task.isCancelled {
                    let msg: PeerIncomingMessage
                    do {
                        msg = try await currentSession.receiveNextMessage()
                    } catch {
                        if let swapped = await self.session, swapped !== currentSession {
                            // Deliberate resume-heal swap, not a failure: adopt
                            // the resumed session and keep pumping. Its wire
                            // byte_seq restarts at 0, so the gap baseline must
                            // reset too — otherwise the first post-resume chunk
                            // reads as a spurious gap against the old session's
                            // trailing byte_seq.
                            currentSession = swapped
                            expectedByteSeq = nil
                            gapBytesTotal = 0
                            gapCount = 0
                            continue pumpLoop
                        }
                        try? await writer.enqueue(type: kTypeGoodbye, payload: Data("host-error".utf8))
                        endReason = "hostToRelay-receive-error"
                        break pumpLoop
                    }
                    switch msg {
                    case .teamLeaderCommandRequest(let request, let correlationID):
                        // A tm-agent running inside the remote pane can reach
                        // only the remote daemon. The daemon sends this scoped
                        // request back over the already-authenticated peer
                        // session; answer it here without app activation or a
                        // local TERMMESH_SOCKET ever crossing machines.
                        let response = await GhosttyPaneSurfaceProvider
                            .handleRemoteLeaderCommand(request)
                        do {
                            try await currentSession.sendTeamLeaderCommandResponse(
                                response,
                                correlationID: correlationID
                            )
                        } catch {
                            endReason = "hostToRelay-leader-response-error"
                            break pumpLoop
                        }
                        continue pumpLoop
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
                            // Rate-limited: a heavy flood drops thousands of
                            // chunks/sec; logging every one floods the debug
                            // ring (opening its circuit breaker and dropping
                            // OTHER events, including the heal logs). One line
                            // per 500 gaps is enough to see truncation happening.
                            if gapCount == 1 || gapCount % 500 == 0 {
                                #if DEBUG
                                // "peer.relay.gap" is on DebugEventLog's circuit-breaker
                                // bypass whitelist — a flood that trips the 500 logs/s
                                // breaker must not also swallow the one line that explains
                                // why the pane just went blank.
                                dlog("peer.relay.gap #\(gapCount) dropped=\(gap) totalDropped=\(gapBytesTotal) — host broadcast Lag (content truncated)")
                                #endif
                                // `.info`, not `.debug`: this must reach the drawer on
                                // gapCount == 1 regardless of the user's log-level
                                // setting (default .info drops .debug lines), so the
                                // very first drop of a flood is seen at least once —
                                // not just recorded in a file nobody is watching.
                                RemoteWorkLog.infoOffMain(
                                    "Host output lagged — \(gap) bytes dropped (\(gapBytesTotal) total over \(gapCount) gaps); the pane is missing content"
                                )
                            }
                            // P9.2: schedule a debounced redraw heal so a TUI
                            // corrupted by the drop recovers once output settles.
                            await resizeCoalescer.noteGapForHeal()
                        }
                        expectedByteSeq = byteSeq + UInt64(data.count)
                        // R3: `expectedByteSeq` IS "last processed wire seq" —
                        // the wire position `performResumeHeal` resumes from on
                        // the next heal. Written every chunk (hot path), so a
                        // lock-protected box rather than a MainActor hop.
                        wireSeqTracker.update(expectedByteSeq!)
                        if self.ioStats.noteReceived(data.count) {
                            #if DEBUG
                            dlog("peer.relay.firstByte path=owned bytes=\(data.count)")
                            #endif
                        }
                        // While a scrollback window is on display, live
                        // bytes must not paint over it. They are DROPPED,
                        // not buffered: the browse-exit render (offset 0)
                        // is the host's own current screen, so nothing is
                        // lost — the same contract tmux's copy-mode has.
                        // Seq accounting above stays live either way.
                        if scrollbackBrowse.isBrowsing {
                            break
                        }
                        do {
                            try await writer.enqueue(type: kTypePtyData, payload: data)
                            self.ioStats.noteEnqueued(data.count)
                        } catch {
                            endReason = "hostToRelay-enqueue-failed"
                            break pumpLoop
                        }
                    case .gridSnapshot(let sid, _, _, let ansi) where sid == mySurfaceID:
                        // The host just proved it speaks the grid model —
                        // scrollback browsing may engage from here on.
                        scrollbackBrowse.markHostCapable()
                        // Typed fresh-attach keyframe (grid.snapshot.v1).
                        // ESC[3J first: repeated attaches used to stack one
                        // stale screen per open into the viewer's local
                        // scrollback, and only the typed form can safely
                        // clear it — an untyped byte stream might be
                        // mid-escape. Then the rendered screen itself.
                        var payload = Data([0x1b, 0x5b, 0x33, 0x4a]) // ESC [ 3 J
                        payload.append(ansi)
                        // Reset the gap baseline to wire zero, NOT to the
                        // snapshot's host-absolute byte_seq: `expectedByteSeq`
                        // lives in the per-attach wire space, and a host on
                        // the typed path spends no wire seq on the snapshot —
                        // the first live PtyData after this message starts at
                        // byte_seq 0 (its host-absolute anchor arrives as
                        // AttachResult.initial_seq, which equals this
                        // message's byte_seq). Without the reset every attach
                        // would read as a jump, fire a spurious gap log, and
                        // schedule a needless redraw heal.
                        expectedByteSeq = 0
                        wireSeqTracker.update(0)
                        if self.ioStats.noteReceived(payload.count) {
                            #if DEBUG
                            dlog("peer.relay.firstByte path=owned-snapshot bytes=\(payload.count)")
                            #endif
                        }
                        do {
                            try await writer.enqueue(type: kTypePtyData, payload: payload)
                            self.ioStats.noteEnqueued(payload.count)
                        } catch {
                            endReason = "hostToRelay-enqueue-failed"
                            break pumpLoop
                        }
                    case .scrollbackChunk(let sid, let effOffset, let ansi, let atTop, _) where sid == mySurfaceID:
                        // One browse window (or, at offset 0, the live
                        // screen again). The render is a full replacement —
                        // clear+home first — so it goes down the same relay
                        // byte pipe as everything else.
                        let (followUp, browsing) = scrollbackBrowse.noteChunk(
                            effectiveOffset: effOffset,
                            atTop: atTop
                        )
                        do {
                            try await writer.enqueue(type: kTypePtyData, payload: ansi)
                        } catch {
                            endReason = "hostToRelay-enqueue-failed"
                            break pumpLoop
                        }
                        #if DEBUG
                        dlog("peer.relay.scrollback offset=\(effOffset) atTop=\(atTop) browsing=\(browsing)")
                        #endif
                        // A wheel step that landed mid-flight parked its
                        // target; chase it now that the wire is free.
                        if let next = followUp {
                            try? await session.requestScrollback(
                                surfaceID: mySurfaceID,
                                offsetRows: next
                            )
                        }
                    case .hostStats(let stats):
                        // About the machine, not this pane, so it does not go
                        // to the relay — it lands in the host-keyed store the
                        // titlebar reads. Only for a session that knows which
                        // host it reached.
                        if let hostKey = await self.hostKey {
                            await MainActor.run {
                                PeerHostStatsStore.shared.record(stats, for: hostKey)
                            }
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
                            // R3: read the CURRENT session, not the one captured
                            // when pumping started — a resume-heal may have
                            // swapped it out from under this pane transparently.
                            guard let current = await self.session else { break }
                            // Typing while browsing scrollback exits the
                            // browse first (offset-0 render restores the
                            // live screen), then the key goes through — the
                            // same "any input snaps back to live" rule as
                            // tmux copy-mode's q.
                            if let exit = scrollbackBrowse.requestForExit() {
                                try? await current.requestScrollback(
                                    surfaceID: surfaceID,
                                    offsetRows: exit
                                )
                            }
                            do {
                                try await current.sendInput(surfaceID: surfaceID, keys: frame.payload)
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
                            if ownsSession, let current = await self.session {
                                try? await current.sendGoodbye(reason: "relay disconnected")
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

    // ── R3 resume heal (peer-relay-bulk-loss) ─────────────────────────
    //
    // The P9.2 gap-heal action. A host broadcast-Lag drop means bytes are
    // gone from the live stream for good — nudging the remote PTY size (the
    // pre-R3 fix) only forces the child to redraw its CURRENT state, so the
    // truncated scrollback stays lost. This reconnects instead: a fresh
    // transport + handshake to the same host, then AttachSurface on the
    // SAME surface_id with `resume_from_seq` set to the exact wire position
    // this pane last processed (translated into the host's absolute seq
    // space via `attachInitialSeq` — see `PeerServer.swift`'s wire↔host
    // mapping doc), so the host's replay ring streams the missing bytes
    // back before live data resumes.
    //
    // Deliberately a NEW session, not a re-attach on the live one: the live
    // session's `hostToRelay` pump keeps an outstanding `receiveNextMessage`
    // in flight essentially the whole time (that's how the gap that
    // triggered this heal was even observed), and `PeerSession.attachSurface`
    // is a direct-response RPC that rejects a concurrent receive
    // (`concurrentReceiveOperation`) — see the file header. Racing that
    // guard, or interrupting the in-flight receive to clear it, tears down
    // the live session's transport, which is exactly the resource this pane
    // still needs while the resume attach is in flight. Host-side, this is
    // safe: `attached` (`connection.rs`) is scoped per TCP connection, not
    // per surface, so a second connection attaching the same surface_id
    // never collides with the still-live one — it simply gets its own
    // subscriber + replay snapshot.
    private func performResumeHeal(reason: String) async {
        guard !isTorndown, !resumeInFlight else { return }
        guard let oldSession = session else { return }

        guard ownsSession else {
            // Shared (workspace-mirror) session: this pane doesn't own the
            // transport — WorkspaceMirror does, on behalf of every sibling
            // pane attached to it — so a resume re-attach isn't reachable
            // from here without that controller's cooperation (out of R3's
            // scope; see the task's file-scope note). Fall back to the
            // pre-R3 resize nudge so mirror panes keep SOME heal instead of
            // silently losing the one they already had: real bytes stay
            // lost, but the pane at least redraws its current state.
            guard let size = await resizeCoalescer?.snapshotSize(), size.cols > 1 else { return }
            #if DEBUG
            dlog("peer.relay.gap.heal.sharedFallback nudge redraw reason=\(reason) cols=\(size.cols) rows=\(size.rows)")
            #endif
            try? await oldSession.sendResize(surfaceID: surfaceID, cols: size.cols - 1, rows: size.rows)
            try? await oldSession.sendResize(surfaceID: surfaceID, cols: size.cols, rows: size.rows)
            return
        }
        guard let oldTransport = transport else { return }

        resumeInFlight = true
        defer { resumeInFlight = false }

        let size = await resizeCoalescer?.snapshotSize() ?? (remoteCols, remoteRows)

        let newConnection: PeerRelayConnection
        do {
            newConnection = try await Self.connect(hostSockPath: hostSockPath)
        } catch {
            #if DEBUG
            dlog("peer.relay.gap.heal.resume.connectFailed error=\(error)")
            #endif
            return
        }
        guard !isTorndown else {
            await newConnection.cancel()
            return
        }

        // Read the resume anchor as late as possible: the old (lagging)
        // session keeps pumping frames while `connect` is in flight, and
        // every one it delivers past an anchor read earlier would come back
        // again in the resume replay as duplicate output. Reading after the
        // connect round trip shrinks that window to the attach RPC alone.
        //
        // Gating: an older host that never advertised replay.ring.v1 has no
        // replay ring to serve a resume from, so this client doesn't rely on
        // it silently ignoring the field — 0 asks for the same full-snapshot
        // attach a fresh connection would get anyway.
        //
        // `&+`, not `+`: the host derives `initialByteSeq` with a *wrapping*
        // subtraction (`tapSeq &- initial.count`, see
        // `GhosttyPaneSurfaceProvider.attach`), so on a fresh hub — where the
        // replayed snapshot is longer than everything the tap has ever
        // emitted — `attachInitialSeq` legitimately sits just below
        // `UInt64.max`. Re-adding the wire offset is the modular inverse that
        // lands back on the real host seq, so it must wrap too; a trapping `+`
        // crashed the whole app here (arithmetic overflow) on the first gap
        // heal of such an attach, and since the heal IS the recovery path, the
        // pane could never come back.
        let lastWireSeq = wireSeqTracker.read()
        let resumeFromSeq: UInt64 = hostSupportsReplayRing ? (attachInitialSeq &+ lastWireSeq) : 0

        #if DEBUG
        dlog("peer.relay.gap.heal.resume reason=\(reason) resumeFromSeq=\(resumeFromSeq) gated=\(hostSupportsReplayRing) cols=\(size.cols) rows=\(size.rows)")
        #endif

        let outcome: PeerAttachOutcome
        do {
            outcome = try await newConnection.session.attachSurface(
                id: surfaceID,
                mode: .coWrite,
                cols: size.cols,
                rows: size.rows,
                resumeFromSeq: resumeFromSeq
            )
        } catch {
            #if DEBUG
            dlog("peer.relay.gap.heal.resume.attachFailed error=\(error)")
            #endif
            await newConnection.cancel()
            return
        }
        guard outcome.surfaceID == surfaceID, !isTorndown else {
            await newConnection.cancel()
            return
        }

        // Swap BEFORE retiring the old session: `hostToRelay`'s receive-error
        // handler adopts the resumed session by re-reading `self.session`, so
        // it must already be in place by the time the old transport closes
        // and unblocks that pending receive (see the doc comment above).
        await oldSession.stopHeartbeat()
        // Re-check: `stopHeartbeat()` is this method's first suspension point
        // since the last guard, and MainActor cooperative scheduling means
        // `disconnect()` (e.g. the user closed the pane mid-reconnect) could
        // have run and torn everything down while this was suspended. Without
        // this the mutations below would revive session/transport state right
        // after teardown nilled them.
        guard !isTorndown else {
            await newConnection.cancel()
            return
        }
        session = newConnection.session
        transport = newConnection.transport
        attachInitialSeq = outcome.initialByteSeq
        wireSeqTracker.update(0)
        hostSupportsReplayRing = newConnection.hostCapabilities.has(PeerCapability.replayRingV1)
        await resizeCoalescer?.adopt(session: newConnection.session)
        await startHeartbeatMonitoring(session: newConnection.session, transport: newConnection.transport)

        try? await oldSession.sendGoodbye(reason: "resume-heal reconnect")
        await oldTransport.close()

        #if DEBUG
        dlog("peer.relay.gap.heal.resume.swapped newInitialSeq=\(outcome.initialByteSeq)")
        #endif
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
        // Counters ride along: a disconnect with received=0 says the pane was
        // blank because nothing ever arrived, while received>0 with
        // enqueued<received localizes the loss to the writer/semaphore.
        dlog("peer.relay.disconnect reason=\(reason) ownsSession=\(ownsSession) \(ioSummary)")
        #endif
        // The reason is the whole value here: "heartbeat.dead" and
        // "user closed the pane" produce an identical empty pane, and which
        // one it was decides whether anything is wrong.
        RemoteWorkLog.infoOffMain("Relay session ended: \(reason)")
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


// ── Scrollback browse (tmux copy-mode model) ─────────────────────────

extension PeerRelaySession: PeerScrollbackBrowseHandling {
    /// Wheel steps arrive from the pane's scroll-view wrapper. Page-sized
    /// steps (the remote viewport height) keep request volume low — the
    /// same granularity tmux's PageUp browsing has.
    func handleBrowseWheel(up: Bool, atLocalTop: Bool) -> Bool {
        guard scrollbackBrowse.isHostCapable else { return false }
        let step = max(3, remoteRows)
        guard let offset = scrollbackBrowse.requestForWheel(
            up: up,
            step: step,
            atLocalTop: atLocalTop
        ) else {
            // Consumed silently while browsing (a parked mid-flight step),
            // untouched otherwise (let the local scrollback scroll).
            return scrollbackBrowse.isBrowsing
        }
        guard let session else { return false }
        let surfaceID = self.surfaceID
        Task {
            try? await session.requestScrollback(surfaceID: surfaceID, offsetRows: offset)
        }
        return true
    }
}
