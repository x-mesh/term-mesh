// Phase C-3c.3.3b: bridges the app's live Ghostty terminal panes into the
// PeerServer's PeerSurfaceProvider abstraction.
//
// Surface enumeration: TabManager → Workspace.panels → TerminalPanel.surface
// (TerminalSurface) → ghostty_surface_t.
//
// Input forwarding: ghostty_surface_text() on MainActor.
// Output tapping:   ghostty_surface_set_pty_data_callback() registers a C
//                   callback that yields raw PTY bytes into an AsyncStream.
//                   The callback is invoked on Ghostty's IO reader thread
//                   under renderer_state.mutex, so it must be non-blocking.
//
// Memory contract:
//   • attach() retains a PtyTapContext (strong ref keeps TerminalSurface alive)
//   • detach() clears the C callback then releases the context
//   • If the surface is freed before detach: TerminalSurface.deinit clears the
//     C callback and then ghostty_surface_free proceeds safely; the context is
//     released by the detach closure when the PeerServer eventually calls it.

import AppKit
import Bonsplit
import PeerProto

// MARK: - C callback (top-level; @convention(c) cannot capture)

private func ptyTapCallback(
    userdata: UnsafeMutableRawPointer?,
    data: UnsafePointer<UInt8>?,
    len: UInt
) {
    guard let userdata, let data, len > 0 else { return }
    let hub = Unmanaged<PtyTapHub>.fromOpaque(userdata).takeUnretainedValue()
    hub.broadcast(Data(bytes: data, count: Int(len)))
}

// MARK: - PtyTapHub

/// Bounded recent-output history for attach-time ANSI-preserving replay
/// (Phase P4). Ports the Rust `ReplayBuffer`
/// (`daemon/term-meshd/src/peer/surface.rs:52-75`) 1:1 in cap and eviction
/// semantics — "drop the oldest whole chunks until back under the byte
/// cap" — so both implementations share identical truncation behavior.
/// Chunks are stored with a lazily-compacted head index instead of
/// `removeFirst()` per evict, so `push` stays O(1) amortized on both ends
/// (no per-chunk element shift): required because `push` runs inside
/// `PtyTapHub.broadcast(_:)`'s lock, called directly from Ghostty's IO
/// reader thread (see file header — must be non-blocking).
private struct ReplayBuffer {
    private var chunks: [Data] = []
    private var head: Int = 0
    private(set) var totalBytes: Int = 0
    /// Sticky once true: at least one chunk was evicted to stay under cap,
    /// so the buffer can no longer certify it holds the surface's
    /// *complete* output history. Never resets.
    private(set) var hasEvicted: Bool = false

    var isEmpty: Bool { head >= chunks.count }
    var chunkCount: Int { chunks.count - head }

    mutating func push(_ data: Data) {
        guard !data.isEmpty else { return }
        chunks.append(data)
        totalBytes += data.count
        while totalBytes > PtyTapHub.replayCapacityBytes, head < chunks.count {
            totalBytes -= chunks[head].count
            head += 1
            hasEvicted = true
        }
        // Lazy compaction: reclaim consumed head slots once they dominate
        // the backing array, so a long-lived surface's `chunks` array
        // doesn't grow unboundedly even though live bytes stay capped.
        // Threshold of 64 keeps this off the common path.
        if head > 64, head * 2 > chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
    }

    /// Non-empty AND never evicted ⇒ certifiably the surface's complete
    /// output history — safe to replay verbatim in place of a plain-text
    /// snapshot. Deliberately conservative: reaching this exact byte cap
    /// without ever evicting still reads as "safe" here (only an actual
    /// eviction flips `hasEvicted`), which is fine — the eviction check is
    /// the correctness boundary, not the byte count.
    var isSafeForCompleteReplay: Bool { !isEmpty && !hasEvicted }

    func concatenatedBytes() -> Data {
        var out = Data()
        out.reserveCapacity(totalBytes)
        for i in head..<chunks.count { out.append(chunks[i]) }
        return out
    }

    /// `concatenatedBytes()`, cut to only the bytes at or after `fromSeq` —
    /// the resume-tail counterpart to the Rust `ReplayBuffer::snapshot_from`
    /// (`daemon/term-meshd/src/peer/surface.rs`) this type otherwise mirrors.
    ///
    /// Unlike the Rust ring, this buffer doesn't retain a `seq` per chunk —
    /// only the concatenated bytes and a running total — so the absolute
    /// seq of the OLDEST buffered byte has to be derived here instead of
    /// read off a chunk: `tapSeqAtCall` (the tap's cumulative counter at
    /// the moment of the call, one past the newest buffered byte) minus
    /// `totalBytes` (how many contiguous bytes are behind it). PTY output
    /// has no internal gaps, so that subtraction is exact.
    ///
    /// `fromSeq` outside `[oldest, tapSeqAtCall]` — already evicted, or
    /// newer than anything buffered (seq-space mismatch) — falls back to
    /// the full buffer rather than resending nothing, same as the Rust
    /// side. `fromSeq == tapSeqAtCall` (caught up exactly) returns empty.
    func concatenatedBytes(from fromSeq: UInt64, tapSeqAtCall: UInt64) -> Data {
        let oldest = tapSeqAtCall - UInt64(totalBytes)
        guard fromSeq >= oldest, fromSeq <= tapSeqAtCall else {
            return concatenatedBytes()
        }
        let skip = Int(fromSeq - oldest)
        let all = concatenatedBytes()
        guard skip < all.count else { return Data() }
        return all.suffix(from: all.startIndex + skip)
    }
}

/// One Ghostty PTY callback per surface, fan-out to bounded per-peer streams.
final class PtyTapHub: @unchecked Sendable {
    /// Bytes of recent PTY output retained for attach-time replay. Mirrors
    /// the Rust `REPLAY_CAPACITY_BYTES` constant exactly
    /// (`daemon/term-meshd/src/peer/surface.rs:43`).
    static let replayCapacityBytes = 64 * 1024

    private let lock = NSLock()
    /// Serializes the stateful query filter without extending the shared hub
    /// lock across a scan/allocation of every PTY chunk. The handoff in
    /// `broadcast(_:)` acquires `lock` before releasing this lock, preserving
    /// callback order across both filtered output and sequence offsets.
    private let filterLock = NSLock()
    private var continuations: [UUID: AsyncStream<PtyTapChunk>.Continuation] = [:]
    private var replay = ReplayBuffer()
    /// Strips terminal-control queries before anything downstream sees them.
    ///
    /// Held here rather than per-consumer because its state is a property of
    /// the PTY stream, not of who is watching: a sequence split across two
    /// reads has to reassemble once. Mutated only under `filterLock` on
    /// Ghostty's IO reader thread.
    private var queryStripper = PeerTerminalQueryStripper()
    /// Cumulative bytes ever broadcast through this hub. Advanced under
    /// `lock` for EVERY chunk — including ones a consumer's bounded
    /// buffer then drops — and stamped onto each `PtyTapChunk.seq`, so a
    /// drop shows up downstream as a seq hole (`PeerServer.pumpByteStream`
    /// forwards it into `PtyData.byte_seq`, which is what the viewer's P9
    /// gap detection keys on). Before this, drops were invisible on the
    /// wire: the pump counted only delivered chunks, seq stayed
    /// contiguous, and flood truncation could never trigger a heal.
    private var tapSeq: UInt64 = 0
    /// Cumulative count of `broadcast()` yields dropped by ANY consumer's
    /// `bufferingNewest(256)` stream (a slow/stalled peer's buffer
    /// overflowing while PTY output keeps arriving). `AsyncStream`
    /// silently overwrites on overflow, but `Continuation.yield(_:)`'s
    /// `YieldResult` DOES report `.dropped` per call — this counts that
    /// directly rather than approximating via a separate push/consume
    /// tally (R11 phase 1: counter + dlog; phase 2 auto-resnapshot is
    /// out of scope here).
    private var dropCount: UInt64 = 0

    let surfaceID: UUID
    let surfacePtr: ghostty_surface_t
    // Strong reference prevents TerminalSurface.deinit during active relay.
    // Nulled by shutdown() when the panel closes to release the surface.
    private var surfaceRef: TerminalSurface?

    init(surfaceID: UUID, surfacePtr: ghostty_surface_t, surfaceRef: TerminalSurface) {
        self.surfaceID = surfaceID
        self.surfacePtr = surfacePtr
        self.surfaceRef = surfaceRef
    }

    /// Call when the backing panel closes (not on normal peer detach).
    /// Finishes all streams and drops the TerminalSurface strong reference.
    func shutdown() {
        finishAll()
        surfaceRef = nil
    }

    deinit {
        #if DEBUG
        dlog("deinit \(Self.self)")
        #endif
    }

    /// Atomically — one `lock` hold shared with `broadcast(_:)` — decides
    /// the attach-time backlog (ring replay vs the caller-supplied
    /// viewport fallback), registers the consumer continuation, and
    /// stamps the initial chunk against the tap's cumulative counter.
    /// This closes the P4-era seam where `replaySnapshot()` and
    /// registration were two separate lock acquisitions: a `broadcast()`
    /// landing between them was neither in the replay copy nor delivered
    /// live. Now nothing can interleave, and even if a producer-side
    /// drop hits immediately after, the seq stamps make it visible.
    ///
    /// `fallbackSnapshot` must be computed BEFORE calling (it reads
    /// Ghostty's grid on MainActor — never under this lock, which the IO
    /// reader thread contends on).
    ///
    /// `resumeFromSeq` (R1, peer-relay-bulk-loss): when nonzero, replay
    /// only the tail starting at that absolute tap seq instead of the full
    /// ring — but ONLY when the ring is `isSafeForCompleteReplay`. An
    /// evicted ring can't honor an exact cut without risking a slice that
    /// starts mid-escape-sequence, so it falls through to the ordinary
    /// full-ring-or-fallback-snapshot decision below exactly as if no
    /// resume had been requested. Callers gate this on the `replay.ring.v1`
    /// capability before ever passing a nonzero value — see
    /// `PeerServerSession.handleAttach`'s doc comment for the full wire↔host
    /// seq mapping.
    func makeStream(
        fallbackSnapshot: Data?,
        initialPrefix: Data?,
        resumeFromSeq: UInt64 = 0
    ) -> (
        attachID: UUID,
        stream: AsyncStream<PtyTapChunk>,
        usedBufferReplay: Bool,
        initialByteCount: Int,
        replayChunkCount: Int,
        initialSeq: UInt64
    ) {
        let attachID = UUID()
        lock.lock()
        let usedBufferReplay = replay.isSafeForCompleteReplay
        var initial: Data
        if resumeFromSeq != 0, usedBufferReplay {
            initial = replay.concatenatedBytes(from: resumeFromSeq, tapSeqAtCall: tapSeq)
        } else {
            initial = usedBufferReplay ? replay.concatenatedBytes() : (fallbackSnapshot ?? Data())
        }
        if let initialPrefix, !initialPrefix.isEmpty {
            initial = initialPrefix + initial
        }
        let replayChunkCount = replay.chunkCount
        // Absolute tap seq that this attach's wire byte_seq == 0 maps to —
        // backdated `initial.count` bytes from the current tap offset.
        // Ring-replay/resume-tail bytes genuinely ARE the tap stream's last
        // `initial.count` bytes, so this is exact for them; for the
        // viewport fallback (and the palette/mouse prefix, always synthetic)
        // it's a deliberate fiction that still establishes a consistent
        // baseline — see `PeerServerSession.handleAttach`'s doc comment.
        // (`&-` may wrap on a fresh hub; the pump only uses chunk END
        // offsets, and `wrap &+ count` round-trips back to `tapSeq`.)
        let initialSeq = tapSeq &- UInt64(initial.count)
        let stream = AsyncStream<PtyTapChunk>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            // The build closure runs synchronously inside init — still
            // under the outer lock hold, so registration + initial yield
            // are atomic with any concurrent broadcast().
            continuations[attachID] = continuation
            if !initial.isEmpty {
                // Stamp so the chunk's END lands exactly on the current
                // tap offset — see `initialSeq` above for why this exact
                // value is correct for every source `initial` can come from.
                continuation.yield(PtyTapChunk(bytes: initial, seq: initialSeq))
            }
        }
        lock.unlock()
        return (attachID, stream, usedBufferReplay, initial.count, replayChunkCount, initialSeq)
    }

    func broadcast(_ bytes: Data) {
        // Filtering is stateful but potentially scans and allocates for the
        // whole chunk. Keep that work out of the shared replay/subscriber
        // lock. Hold `filterLock` until `lock` is acquired so another callback
        // cannot overtake this one between filtering and sequence stamping.
        filterLock.lock()
        let bytes = queryStripper.strip(bytes)
        guard !bytes.isEmpty else {
            filterLock.unlock()
            return
        }
        lock.lock()
        filterLock.unlock()

        // Yield directly under the lock — `AsyncStream.Continuation.yield`
        // with `bufferingNewest(256)` is a non-blocking enqueue into a
        // bounded ring buffer, so holding the lock for the duration is
        // bounded by N × O(1) rather than waiting on consumers. Avoids
        // the per-chunk `Array(continuations.values)` allocation that
        // showed up on tail-following workloads (cat /dev/urandom etc.)
        // where the PTY callback fires thousands of times per second.
        // Phase P4: `replay.push` joins the same lock scope — it's an
        // O(1)-amortized Data append (+ occasional whole-chunk evict), so
        // it doesn't change the non-blocking contract this scope already
        // had to satisfy. Phase P7/R11: checking `yield`'s `YieldResult`
        // for `.dropped` is the same O(1)-per-consumer shape this loop
        // already had; the actual `dlog` call (I/O-adjacent) is deferred
        // until after `unlock()` below so logging never happens while
        // holding the lock, even though drops are expected to be rare.
        // The chunk was stripped before this lock acquisition, so neither the
        // live stream nor the replay buffer ever carries a query. A viewer
        // that answered one would send its reply back across the link and into
        // the shell prompt — see `PeerTerminalQueryStripper`. Replaying a
        // stored query at attach time would do the same thing later.
        //
        // Returns the same buffer untouched when there is nothing to strip,
        // and `tapSeq` counts what actually goes out, so a stripped query
        // consumes no offsets and gap detection stays exact.
        replay.push(bytes)
        // Stamp BEFORE fan-out and advance unconditionally: a dropped
        // yield must still consume tap offsets, or the drop is invisible
        // in the seq stream (see `tapSeq` doc).
        let chunk = PtyTapChunk(bytes: bytes, seq: tapSeq)
        tapSeq &+= UInt64(bytes.count)
        var droppedCount: UInt64?
        for continuation in continuations.values {
            if case .dropped = continuation.yield(chunk) {
                dropCount &+= 1
                droppedCount = dropCount
            }
        }
        lock.unlock()
        #if DEBUG
        // Rate-limited (first + every 500th): a flood drops thousands of
        // chunks/sec, and one line per drop rewrites the entire 500-entry
        // debug ring with drop spam — evicting the very gap/heal events
        // needed to diagnose the flood. Same pattern as the P9 gap log in
        // PeerRelaySession.
        if let droppedCount, droppedCount == 1 || droppedCount % 500 == 0 {
            dlog("peer.broadcast.drop count=\(droppedCount) surface=\(surfaceID.uuidString.prefix(8))")
        }
        #endif
    }

    /// Attach-time replay decision (Phase P4): a locked snapshot of the
    /// ring buffer's current state. Takes the same lock `broadcast(_:)`
    /// pushes under, so this never races a concurrent PTY callback on
    /// Ghostty's IO thread — the returned `bytes`/`chunkCount` are a
    /// consistent point-in-time copy, not a torn read.
    func replaySnapshot() -> (bytes: Data, chunkCount: Int, isSafeForCompleteReplay: Bool) {
        lock.lock()
        let bytes = replay.concatenatedBytes()
        let chunkCount = replay.chunkCount
        let safe = replay.isSafeForCompleteReplay
        lock.unlock()
        return (bytes, chunkCount, safe)
    }

    @discardableResult
    func finish(attachID: UUID) -> Bool {
        lock.lock()
        let continuation = continuations.removeValue(forKey: attachID)
        let isEmpty = continuations.isEmpty
        lock.unlock()
        continuation?.finish()
        return isEmpty
    }

    func finishAll() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }
}

// MARK: - GhosttyPaneSurfaceProvider

/// PeerSurfaceProvider backed by the app's live terminal panes.
/// Conformance to PeerSurfaceProvider (which requires Sendable) is valid
/// because @MainActor isolation makes the class's state consistent.
@MainActor
final class GhosttyPaneSurfaceProvider: PeerSurfaceProvider {
    private var tapHubs: [UUID: PtyTapHub] = [:]

    /// Called when a terminal panel closes. Shuts down the hub (finishes all
    /// peer streams + drops TerminalSurface ref) without waiting for peer detach.
    func invalidateTapHub(forSurfaceId surfaceId: UUID) {
        guard let hub = tapHubs.removeValue(forKey: surfaceId) else { return }
        hub.shutdown()
        #if DEBUG
        dlog("tapHub.invalidate surfaceId=\(surfaceId.uuidString.prefix(8))")
        #endif
    }

    // MARK: PeerSurfaceProvider

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] {
        // Background panes have a lazy `ghostty_surface_t` — newly opened
        // splits / non-active tabs may not have one yet. Kick lazy init
        // for any unready pane and wait briefly so the next collect
        // picks them up. Without this the latest split is silently
        // dropped from the picker.
        await MainActor.run { kickLazySurfaceStarts() }
        for _ in 0..<10 {
            if await MainActor.run(body: { allSurfacesReady() }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms × 10 = ≤300 ms
        }
        return await MainActor.run { collectSurfaces() }
    }

    func listWorkspaces() async -> [Termmesh_Peer_V1_Workspace] {
        await MainActor.run { kickLazySurfaceStarts() }
        for _ in 0..<10 {
            if await MainActor.run(body: { allSurfacesReady() }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await MainActor.run { collectWorkspaces() }
    }

    /// The GUI teams this Mac is running, as a peer client would see them.
    /// A team is invisible in the layout tree, so a client asking where a
    /// project's leader sits has no other way to find out — and on a Mac
    /// host the leader usually IS here, which is what makes the answer
    /// worth carrying.
    func listTeams() async -> [Termmesh_Peer_V1_Team] {
        await MainActor.run {
            TeamOrchestrator.shared.teams.values.map { team in
                var wire = Termmesh_Peer_V1_Team()
                wire.name = team.id
                wire.teamUuid = team.teamUuid ?? ""
                wire.workingDirectory = team.workingDirectory
                // Resolve the repo root here: a client staring at the working
                // directory cannot tell it from one of its subdirectories.
                wire.projectRoot = team.gitRepoRoot ?? ""
                wire.agentNames = team.agents.map(\.name)
                wire.createdAtUnixSecs = UInt64(max(0, team.createdAt.timeIntervalSince1970))
                return wire
            }
        }
    }

    /// Run an allow-listed `team.*` method for a peer. Routed through the
    /// app's own team dispatcher — the same one the local control socket
    /// uses — so a peer can never reach a method the local caller cannot,
    /// and the two can never drift apart.
    func callTeamMethod(
        _ method: String,
        paramsJSON: String
    ) async -> Result<String, PeerTeamCallFailure>? {
        var params: [String: Any] = [:]
        if !paramsJSON.isEmpty {
            guard let data = paramsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                return .failure(PeerTeamCallFailure(
                    code: PeerTeamCall.ErrorCode.invalidParams,
                    message: "params_json must be a JSON object"
                ))
            }
            params = dictionary
        }

        let response = await MainActor.run {
            TerminalController.shared.peerTeamCommand(method: method, params: params)
        }

        // The dispatcher answers in JSON-RPC; unwrap it so the peer sees the
        // method's own result rather than a nested envelope.
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(PeerTeamCallFailure(
                code: PeerTeamCall.ErrorCode.hostError,
                message: "team dispatcher returned a non-JSON response"
            ))
        }
        if let error = object["error"] as? [String: Any] {
            return .failure(PeerTeamCallFailure(
                code: error["code"] as? String ?? PeerTeamCall.ErrorCode.hostError,
                message: error["message"] as? String ?? "team call failed"
            ))
        }
        let result = object["result"] ?? [:]
        guard let resultData = try? JSONSerialization.data(withJSONObject: result),
              let resultJSON = String(data: resultData, encoding: .utf8) else {
            return .failure(PeerTeamCallFailure(
                code: PeerTeamCall.ErrorCode.hostError,
                message: "team result was not serializable"
            ))
        }
        return .success(resultJSON)
    }

    /// Resolve only teams already owned by this app. `name:<team>` is the
    /// project identifier emitted by New Project; accepting the stable team
    /// UUID as well makes reconnect restore independent of a display-name
    /// change. Paths are never accepted by the protocol's identifier grammar.
    func resolveTeamLeaderProject(_ projectID: String) async -> String? {
        TeamOrchestrator.shared.teams.values.first { team in
            team.id == projectID
                || "name:\(team.id)" == projectID
                || team.teamUuid == projectID
        }?.teamUuid
    }

    /// The control-plane actor has already parsed and validated this request.
    /// Keep the second JSON parse off MainActor, resolve the authoritative
    /// team name with one minimal hop, and overwrite both accepted spelling
    /// variants so peer-supplied scope can never win.
    nonisolated func callScopedTeamLeaderMethod(
        _ method: String,
        paramsJSON: String,
        teamUUID: String
    ) async -> Result<String, PeerTeamCallFailure>? {
        guard let data = paramsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              var params = object as? [String: Any] else {
            return .failure(PeerTeamCallFailure(
                code: PeerTeamCall.ErrorCode.invalidParams,
                message: "params_json must be a JSON object"
            ))
        }
        guard let teamName = await MainActor.run(body: {
            TeamOrchestrator.shared.teams.values.first(where: {
                $0.teamUuid == teamUUID
            })?.id
        }) else {
            return .failure(PeerTeamCallFailure(
                code: "team_not_found",
                message: "granted team is not owned by this control plane"
            ))
        }

        params["team"] = teamName
        params["team_name"] = teamName
        let response = await TerminalController.shared.peerTeamCommandAsync(
            method: method,
            params: params
        )
        return Self.unwrapTeamDispatcherResponse(response)
    }

    /// Execute a reverse request received on an attached peer session. The
    /// shared control-plane actor validates the grant, overwrites team scope,
    /// deduplicates request IDs, and only then reaches the local dispatcher.
    nonisolated static func handleRemoteLeaderCommand(
        _ request: Termmesh_Peer_V1_TeamLeaderCommandRequest
    ) async -> Termmesh_Peer_V1_TeamLeaderCommandResponse {
        let encodedBytes = (try? request.serializedData().count)
            ?? (PeerTeamLeader.maxCommandPayloadBytes + 1)
        return await PeerTeamLeaderControlPlane.shared.execute(
            request,
            encodedBytes: encodedBytes,
            audiencePeerID: PeerIdentity.defaultPeerID()
        ) { method, paramsJSON, teamUUID in
            guard let data = paramsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  var params = object as? [String: Any] else {
                return .failure(PeerTeamCallFailure(
                    code: PeerTeamCall.ErrorCode.invalidParams,
                    message: "params_json must be a JSON object"
                ))
            }
            guard let teamName = await MainActor.run(body: {
                TeamOrchestrator.shared.teams.values.first(where: {
                    $0.teamUuid == teamUUID
                })?.id
            }) else {
                return .failure(PeerTeamCallFailure(
                    code: "team_not_found",
                    message: "granted team is not owned by this control plane"
                ))
            }
            params["team"] = teamName
            params["team_name"] = teamName
            let response = await TerminalController.shared.peerTeamCommandAsync(
                method: method,
                params: params
            )
            return unwrapTeamDispatcherResponse(response)
        }
    }

    nonisolated static func unwrapTeamDispatcherResponse(
        _ response: String
    ) -> Result<String, PeerTeamCallFailure> {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(PeerTeamCallFailure(
                code: PeerTeamCall.ErrorCode.hostError,
                message: "team dispatcher returned a non-JSON response"
            ))
        }
        if let error = object["error"] as? [String: Any] {
            return .failure(PeerTeamCallFailure(
                code: error["code"] as? String ?? PeerTeamCall.ErrorCode.hostError,
                message: error["message"] as? String ?? "team call failed"
            ))
        }
        let result = object["result"] ?? [:]
        guard let resultData = try? JSONSerialization.data(withJSONObject: result),
              let resultJSON = String(data: resultData, encoding: .utf8) else {
            return .failure(PeerTeamCallFailure(
                code: PeerTeamCall.ErrorCode.hostError,
                message: "team result was not serializable"
            ))
        }
        return .success(resultJSON)
    }

    func handleWorkspaceControl(_ control: Termmesh_Peer_V1_WorkspaceControl) async {
        await MainActor.run { applyWorkspaceControl(control) }
    }

    func createWorkspace(title: String) async -> Data? {
        await MainActor.run { performCreateWorkspace(title: title) }
    }

    func renameWorkspace(id workspaceID: Data, title: String) async -> Bool {
        await MainActor.run { performRenameWorkspace(workspaceIDBytes: workspaceID, title: title) }
    }

    func deleteWorkspace(id workspaceID: Data) async -> Bool {
        await MainActor.run { performDeleteWorkspace(workspaceIDBytes: workspaceID) }
    }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? {
        guard let (sfcPtr, ts) = findSurface(id: surfaceID)
        else { return nil }

        // Hub must exist before its replay buffer can be consulted below —
        // a brand-new hub's buffer is trivially empty, which the mode
        // decision already treats as a snapshot fallback, so creating it
        // early (before computing `snapshot`) is safe.
        let hub: PtyTapHub
        if let existing = tapHubs[ts.id] {
            hub = existing
        } else {
            hub = PtyTapHub(surfaceID: ts.id, surfacePtr: sfcPtr, surfaceRef: ts)
            tapHubs[ts.id] = hub
            // Register the C tap under renderer_state.mutex in Ghostty.
            let hubPtr = Unmanaged.passUnretained(hub).toOpaque()
            ghostty_surface_set_pty_data_callback(sfcPtr, ptyTapCallback, hubPtr)
        }

        // Phase P4: prefer the hub ring's replay (raw PTY bytes — ANSI/
        // style preserved) over the plain-text viewport snapshot, but ONLY
        // when the ring is certifiably the surface's *complete* output
        // history (non-empty, never evicted anything to stay under the
        // byte cap). A pane opened hours ago (vim/htop/log tail) easily
        // outlives the 64KB cap; replaying an evicted ring risks starting
        // mid-escape-sequence or mid-frame — worse than the fallback.
        //
        // The replay-vs-fallback decision now happens INSIDE `makeStream`
        // under the hub lock, atomically with continuation registration —
        // closing the old seam where a `broadcast()` between the separate
        // `replaySnapshot()` and registration lock holds was neither in
        // the replay copy nor delivered live. Any producer-side drop from
        // here on is visible downstream anyway: chunks carry tap seqs and
        // the pump forwards discontinuities as `byte_seq` holes.
        //
        // The viewport fallback is computed unconditionally up front: it
        // reads Ghostty's live cell grid on MainActor and must never run
        // under the hub lock (contended by Ghostty's IO reader thread).
        // Cost is one grid read per attach — attaches are user-driven and
        // rare. ANSI styling is lost on this path (text only); fullscreen
        // TUIs (vim, less, htop) won't redraw without SIGWINCH and
        // require manual refresh.
        let fallbackSnapshot = readPaneSnapshot(sfcPtr)

        // Replay mouse-mode state the viewer missed. Apps that enabled
        // mouse reporting before this attach (Claude Code, vim, htop)
        // sent their DECSET sequences long before the PTY tap existed,
        // so the viewer surface never sees them: mouse_captured stays
        // false on the viewer, scroll events scroll the (empty) local
        // scrollback, and nothing reaches the host pty. Prepending the
        // enable sequences puts the viewer in captured mode so wheel and
        // click events are encoded as SGR mouse reports and flow to the
        // host via relay stdin → Input. Best-effort approximation: the
        // C API only exposes captured yes/no, not the exact tracking
        // mode, so use button-event tracking (1002) + SGR encoding
        // (1006). Attach-only on purpose: a later mode change on the
        // host streams through the tap, and the resize-path snapshot
        // re-send must not overwrite an exact mode (e.g. ?1003h) with
        // this guess. Applies uniformly whether the initial bytes come
        // from the buffer replay or the plain-text fallback.
        var initialPrefix = peerTerminalPalettePrefix(
            foreground: GhosttyApp.shared.defaultForegroundColor,
            background: GhosttyApp.shared.defaultBackgroundColor
        )
        if ghostty_surface_mouse_captured(sfcPtr) {
            initialPrefix.append(Data("\u{1b}[?1002h\u{1b}[?1006h".utf8))
        }

        let (attachID, stream, usedBufferReplay, initialByteCount, replayChunkCount, initialSeq) =
            hub.makeStream(
                fallbackSnapshot: fallbackSnapshot,
                initialPrefix: initialPrefix,
                resumeFromSeq: resumeFromSeq
            )
        #if DEBUG
        dlog("peer.replay.attach mode=\(usedBufferReplay ? "buffer" : "snapshot") bytes=\(initialByteCount) chunks=\(replayChunkCount) resumeFromSeq=\(resumeFromSeq) initialSeq=\(initialSeq)")
        #endif

        // Light up the peer-attached ring on the host pane and bump
        // the per-surface ref count so concurrent attaches all share
        // a single visible ring.
        let isFirstAttach = Self.incrementPeerAttach(for: ts)

        // Phase E-6: optional Ctrl-L injection so TUIs repaint with
        // full styling on attach. The plain-text snapshot path above
        // restores content but loses ANSI; sending Ctrl-L makes vim /
        // htop / less redraw correctly. Disabled by default because
        // the redraw is visible to the host's local viewer too.
        //
        // Gate on the 0→1 transition: clients 2..N attaching to the
        // same surface get the redraw bytes via the existing PTY tap
        // (broadcast from the first attach's redraw), so emitting
        // Ctrl-L on every attach would just stack form-feeds and
        // multiply the host's local flicker.
        //
        // Phase P4 note: this flag exists to compensate for the plain-text
        // snapshot's lost styling. When `usedBufferReplay` was true above,
        // `snapshot` already carries the surface's real ANSI bytes verbatim
        // — the redraw this flag forces is largely redundant for that
        // attach (though still harmless/off by default). Left as-is rather
        // than conditioning on `usedBufferReplay`: this setting is a
        // blanket host-visible-flicker tradeoff the user opts into, not a
        // per-attach optimization worth the added branching here.
        if isFirstAttach && PeerFederationSettings.forceRedrawOnAttach {
            // Defer briefly so the snapshot lands first; the redraw
            // bytes that come back through the PTY tap will then
            // cleanly overwrite it.
            Task { @MainActor [weak ts] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let ptr = ts?.surface else { return }
                sendPeerInputBytes(ptr, bytes: Data([0x0c]))
            }
        }

        // Capture weak reference to TerminalSurface for input/resize closures;
        // the strong ref lives in PtyTapContext for the lifetime of the attach.
        let weakTS = WeakRef(ts)
        // FIX A: capture key at attach time so the detach closure can clean up
        // peerPendingInputTail even if the TerminalSurface is already freed.
        let sfcPtrKey = UInt(bitPattern: sfcPtr)

        let input: @Sendable (Data) async -> Void = { [weakTS] bytes in
            await MainActor.run {
                guard let terminalSurface = weakTS.value,
                      let ptr = terminalSurface.surface else { return }
                // Somebody is typing in the viewer, so the viewer's size wins
                // the arbitration from here — see `resolvePixelSize`. Without
                // this the viewer can never grow past the host pane's width.
                terminalSurface.noteRemoteInput()
                // Track a weak surface ref so a deferred lone-Escape tail can be
                // flushed later without capturing the raw (non-Sendable) pointer.
                peerSurfaceRefForKey[UInt(bitPattern: ptr)] = weakTS
                sendPeerInputBytes(ptr, bytes: bytes)
            }
        }

        let detach: @Sendable () async -> Void = { [provider = WeakRef(self), weakTS, hub, sfcPtrKey] in
            await MainActor.run {
                let hubEmpty = hub.finish(attachID: attachID)
                if let ts = weakTS.value {
                    GhosttyPaneSurfaceProvider.decrementPeerAttach(for: ts)
                    if hubEmpty {
                        if let ptr = ts.surface {
                            ghostty_surface_clear_pty_data_callback(ptr)
                        }
                        // Nobody is looking from elsewhere any more, so the
                        // local pane stops accommodating a viewer that has
                        // left and takes its own size back.
                        ts.clearRemoteViewerPixelSize()
                        provider.value?.tapHubs.removeValue(forKey: ts.id)
                    }
                }
                // FIX A: release pending escape-sequence tail on last client detach
                // to prevent stale bytes prepending to a future session at the same
                // surface pointer address (OS pointer reuse after surface free).
                if hubEmpty {
                    clearPeerPendingInputTail(surfaceKey: sfcPtrKey)
                }
            }
        }

        let meta: PeerWorkspaceMeta? = nil

        return PeerSurfaceAttachment(
            byteStream: stream,
            input: input,
            resize: { [weakTS, hub] cols, rows in
                await MainActor.run {
                    guard let terminalSurface = weakTS.value,
                          let ptr = terminalSurface.surface else { return }
                    // ghostty_surface_set_size takes pixel dimensions.
                    // Use current cell size to convert cols×rows → pixels.
                    let curSz = ghostty_surface_size(ptr)
                    guard curSz.cell_width_px > 0, curSz.cell_height_px > 0 else { return }
                    let safeCols = min(cols, 1000)
                    let safeRows = min(rows, 1000)
                    let (w, wOverflow) = safeCols.multipliedReportingOverflow(by: UInt32(curSz.cell_width_px))
                    let (h, hOverflow) = safeRows.multipliedReportingOverflow(by: UInt32(curSz.cell_height_px))
                    guard !wOverflow, !hOverflow else { return }

                    // The host pane and each remote viewer are two windows onto
                    // one PTY, and a PTY has one size. The viewer's real size
                    // only reaches us here (the attach `clientCols/clientRows`
                    // carry the host-echoed size, not the viewer's). Until it
                    // lands, the viewer renders host-sized PTY bytes into a
                    // differently-sized grid, so absolute-cursor TUIs (Claude
                    // Code, vim, htop) paint spinners/status lines on top of
                    // body text and the screen looks garbled/duplicated.
                    //
                    // `applyRemoteViewerPixelSize` owns the arbitration — while
                    // the local pane is on screen the smaller of the two wins,
                    // otherwise the viewer does — and keeps the local pane's own
                    // size cache honest. Setting the size here directly is what
                    // let the two paths overwrite each other unseen: the local
                    // side went on comparing against a value the surface no
                    // longer had, so it never noticed it had been resized, and
                    // the shell kept wrapping to a width the viewer wasn't
                    // drawing.
                    //
                    // On a real change, wipe the viewer's now-stale grid so the
                    // SIGWINCH-driven repaint lands clean at the new size. The
                    // clear is yielded before the repaint bytes (which arrive
                    // via the PTY tap), so the viewer sees: clear → full
                    // repaint. Skipped on a no-op resize so plain shells don't
                    // lose their view.
                    let sizeChanged = terminalSurface.applyRemoteViewerPixelSize(
                        width: w, height: h
                    )
                    if sizeChanged {
                        // ESC[2J (erase screen) + ESC[H (cursor home).
                        hub.broadcast(Data([0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x5B, 0x48]))
                        // Then re-send the host viewport snapshot at the new
                        // size. The bare clear above (added in v0.139.0 to stop
                        // garbled absolute-cursor TUI output) assumed a
                        // SIGWINCH-driven repaint would refill the grid — but
                        // plain shells (bash/zsh at a prompt) do NOT repaint on
                        // SIGWINCH, so the viewer stayed blank after every real
                        // resize (initial sizing from bounds=.zero, window
                        // shrink, etc.). Re-sending the snapshot restores
                        // content for plain shells; TUIs additionally repaint
                        // via the PTY tap, overwriting the plain-text snapshot.
                        if let snap = readPaneSnapshot(ptr) {
                            hub.broadcast(snap)
                        }
                    }
                }
            },
            workspaceMeta: meta,
            initialByteSeq: initialSeq,
            detach: detach
        )
    }

    // MARK: - Workspace control dispatch

    private func applyWorkspaceControl(_ control: Termmesh_Peer_V1_WorkspaceControl) {
        switch control.kind {
        case .splitPane(let req):
            performSplit(paneIDBytes: req.paneID, orientationString: req.orientation)
        case .closePane(let req):
            performClose(paneIDBytes: req.paneID)
        case .focusPane(let req):
            performFocus(paneIDBytes: req.paneID)
        case .setDivider(let req):
            performSetDivider(splitIDBytes: req.splitID, ratio: req.ratio)
        case .newTab(let req):
            performNewTab(paneIDBytes: req.paneID, workspaceIDBytes: req.workspaceID)
        case .activateTab(let req):
            performActivateTab(paneIDBytes: req.paneID, surfaceIDBytes: req.surfaceID)
        case .none:
            break
        }
    }

    /// Phase E-4: switch the active tab inside the bonsplit pane that
    /// hosts `paneIDBytes` to the tab whose surface is
    /// `surfaceIDBytes`. Both arguments are surface_ids; the pane id
    /// is the *current* active surface used as a locator.
    private func performActivateTab(paneIDBytes: Data, surfaceIDBytes: Data) {
        guard let currentSurfaceUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: currentSurfaceUUID),
              let targetSurfaceUUID = uuidFromSurfaceID(surfaceIDBytes),
              let currentTabID = workspace.surfaceIdFromPanelId(currentSurfaceUUID),
              let targetTabID = workspace.surfaceIdFromPanelId(targetSurfaceUUID)
        else { return }
        let targetPaneId = workspace.bonsplitController.allPaneIds.first { paneId in
            workspace.bonsplitController.tabs(inPane: paneId).contains { $0.id == currentTabID }
        }
        guard let targetPaneId,
              workspace.bonsplitController.tabs(inPane: targetPaneId).contains(where: { $0.id == targetTabID })
        else { return }
        workspace.bonsplitController.selectTab(targetTabID)
    }

    /// What a `NewTabRequest` should do, given what its two locators resolve to.
    ///
    /// Split out from `performNewTab` because the bug was in the decision, not
    /// in the doing: `workspace_id` was never consulted, so the empty-workspace
    /// case — the one the field exists for — fell out of the guard and did
    /// nothing at all.
    enum NewTabTarget: Equatable {
        /// `pane_id` named a live pane; open the tab beside it.
        case besidePane
        /// `pane_id` could not be resolved and `workspace_id` names a workspace
        /// with no surfaces yet. This is the seed the leader placement waits on.
        case seedWorkspace
        /// Neither locator is usable, or the workspace already has surfaces —
        /// in which case an unresolvable pane id is a stale locator rather than
        /// a request to add another tab.
        case ignore
    }

    /// `nonisolated` because it decides from four booleans and touches nothing
    /// — the resolving that does needs the main actor stays in `performNewTab`.
    nonisolated static func newTabTarget(
        paneResolved: Bool,
        hasWorkspaceID: Bool,
        workspaceFound: Bool,
        workspaceHasPanels: Bool
    ) -> NewTabTarget {
        if paneResolved { return .besidePane }
        guard hasWorkspaceID, workspaceFound, !workspaceHasPanels else { return .ignore }
        return .seedWorkspace
    }

    /// Open a terminal tab, either beside a pane or in an empty workspace.
    ///
    /// `pane_id` names a pane to open next to, which is the ordinary case. It
    /// is empty when the workspace was just created and has no pane to name yet
    /// — `NewTabRequest.workspace_id` is the proto's answer to exactly that, and
    /// the Rust host has always honoured it.
    ///
    /// This one used to read `pane_id` alone: the empty id failed the guard and
    /// the request returned having done nothing. A project whose leader is
    /// placed on a Mac peer got a fresh workspace and then waited fifteen polls
    /// for a pane that nobody was going to open, which surfaced as "could not
    /// prepare the project workspace" and no leader. Linux peers were unaffected
    /// because the daemon reads both fields.
    private func performNewTab(paneIDBytes: Data, workspaceIDBytes: Data = Data()) {
        // Resolve both locators first, then let `newTabTarget` decide.
        var besidePane: (workspace: Workspace, pane: PaneID)?
        if let panelUUID = uuidFromSurfaceID(paneIDBytes),
           let workspace = workspaceContaining(panelUUID: panelUUID),
           let tabID = workspace.surfaceIdFromPanelId(panelUUID),
           let targetPaneId = workspace.bonsplitController.allPaneIds.first(where: { paneId in
               workspace.bonsplitController.tabs(inPane: paneId).contains { $0.id == tabID }
           }) {
            besidePane = (workspace, targetPaneId)
        }

        // A workspace made by `createWorkspace` has its root pane already; what
        // it has none of is surfaces — which is also why it reports no panes to
        // a peer listing them, since `peerPaneSummaries` walks surfaces.
        // Keep the owning tab manager, not just the workspace: seeding a pane
        // into it also needs the mount that only its own window can grant.
        let named: (workspace: Workspace, tabManager: TabManager)? =
            uuidFromSurfaceID(workspaceIDBytes).flatMap { uuid in
                for ctx in allWindowContexts() {
                    if let workspace = ctx.tabManager.tabs.first(where: { $0.id == uuid }) {
                        return (workspace, ctx.tabManager)
                    }
                }
                return nil
            }
        let namedWorkspace: Workspace? = named?.workspace

        let target = Self.newTabTarget(
            paneResolved: besidePane != nil,
            hasWorkspaceID: !workspaceIDBytes.isEmpty,
            workspaceFound: namedWorkspace != nil,
            workspaceHasPanels: !(namedWorkspace?.panels.isEmpty ?? true)
        )

        switch target {
        case .besidePane:
            guard let besidePane else { return }
            _ = besidePane.workspace.newTerminalSurface(inPane: besidePane.pane, focus: true)
        case .seedWorkspace:
            guard let named,
                  let seedPane = named.workspace.bonsplitController.focusedPaneId
                      ?? named.workspace.bonsplitController.allPaneIds.first
            else { return }
            _ = named.workspace.newTerminalSurface(inPane: seedPane, focus: true)
            // A seeded pane is in the same position as a created workspace's
            // root pane: the model exists, the surface does not, and only a
            // mount makes one. Ask for the mount here too, or the caller waits
            // out its poll budget on a pane that will never be reported.
            pinWorkspaceUntilReportable(
                named.workspace,
                on: named.tabManager,
                reason: "newTab.seed"
            )
        case .ignore:
            return
        }
    }

    private func performSetDivider(splitIDBytes: Data, ratio: Double) {
        guard let splitUUID = uuidFromSurfaceID(splitIDBytes) else { return }
        let clamped = CGFloat(max(0.05, min(0.95, ratio)))
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                if workspace.bonsplitController.findSplit(splitUUID) {
                    workspace.bonsplitController.setDividerPosition(
                        clamped,
                        forSplit: splitUUID,
                        fromExternal: false
                    )
                    return
                }
            }
        }
    }

    private func performFocus(paneIDBytes: Data) {
        // A peer client's local focus must not steal keyboard focus on
        // the host app. Split/close/new-tab requests carry their target
        // surface id explicitly, so host-side focus is not needed for
        // correctness.
        _ = paneIDBytes
    }

    /// Split a pane for a peer, and say so when it cannot.
    ///
    /// The request is fire-and-forget, so a refusal here reaches the caller
    /// only as silence: it asks, waits for a new surface that never appears,
    /// and reports `could not create a fresh leader surface` ten seconds later
    /// with nothing to act on. That happened on a host whose surface list
    /// still advertised a pane no workspace held any more — the caller picked
    /// it, this returned at the second `guard`, and neither side recorded why.
    ///
    /// Both logs, because the two readers are different machines: `dlog` for a
    /// DEBUG host being driven from a test, `RemoteWorkLog` for the release
    /// build a person is actually running when their peer goes quiet.
    private func performSplit(paneIDBytes: Data, orientationString: String) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes) else {
            reportSplitRefusal(reason: "unreadable surface id", surface: nil)
            return
        }
        guard let workspace = workspaceContaining(panelUUID: panelUUID) else {
            // The surface was listed but belongs to no open workspace — the
            // roster and the windows disagree.
            reportSplitRefusal(reason: "no workspace holds this pane", surface: panelUUID)
            return
        }
        let orientation: SplitOrientation = (orientationString == "vertical") ? .vertical : .horizontal
        if workspace.newTerminalSplit(from: panelUUID, orientation: orientation) == nil {
            reportSplitRefusal(reason: "the workspace refused the split", surface: panelUUID)
        }
    }

    private func reportSplitRefusal(reason: String, surface: UUID?) {
        let id = surface.map { String($0.uuidString.prefix(8)) } ?? "unknown"
        #if DEBUG
        dlog("peer.host.splitPane rejected reason=\(reason) surface=\(id)")
        #endif
        RemoteWorkLog.info("A peer asked to split \(id) and this host could not: \(reason)")
    }

    private func performClose(paneIDBytes: Data) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: panelUUID),
              workspace.panels[panelUUID] != nil
        else { return }
        // `bonsplitController.closeTab` only updates the split tree. It skips
        // Workspace's panel teardown, leaving the Ghostty surface and its PTY
        // child alive after the peer roster says the pane is gone.
        _ = workspace.closePanel(panelUUID, force: true)
    }

    /// Create in the window the host already considers current, but do not
    /// select or raise it. Peer lifecycle commands mutate the roster; they do
    /// not carry focus intent.
    private func performCreateWorkspace(title: String) -> Data? {
        guard let tabManager = AppDelegate.shared?
            .preferredMainWindowContextForServiceWorkspace()?
            .tabManager
        else {
            #if DEBUG
            dlog("peer.host.createWorkspace rejected reason=no_window")
            #endif
            return nil
        }
        let workspace = tabManager.addWorkspace(select: false)
        workspace.setCustomTitle(title)
        // Created but not selected, so nothing mounts it, so its root pane
        // never gets a surface and the caller sees an empty workspace forever.
        // The pin closes that gap without granting the focus this command
        // deliberately withholds.
        pinWorkspaceUntilReportable(workspace, on: tabManager, reason: "createWorkspace")
        #if DEBUG
        dlog("peer.host.createWorkspace id=\(workspace.id.uuidString.prefix(8)) title=\(title)")
        #endif
        return withUnsafeBytes(of: workspace.id.uuid) { Data($0) }
    }

    /// How long a realization pin may hold a workspace in the mounted set.
    ///
    /// Generous next to the caller's own budget (fifteen polls, ~3s) because
    /// the pin outliving one caller's patience is harmless, while releasing
    /// early strands the workspace unrealized. It is bounded at all because a
    /// pin that never resolves would keep an invisible workspace mounted for
    /// the rest of the session, paying SwiftUI update cost for nothing.
    static let surfaceRealizationPinTimeout: TimeInterval = 10

    /// Interval between checks of the pin's exit condition.
    static let surfaceRealizationPollInterval: Duration = .milliseconds(100)

    /// Mount `workspace` off-screen until it has a pane the peer protocol will
    /// report, then release it.
    ///
    /// Surfaces outlive the mount — only `panel.close()` frees one — so this
    /// buys realization once and then gets out of the way.
    private func pinWorkspaceUntilReportable(
        _ workspace: Workspace,
        on tabManager: TabManager,
        reason: String
    ) {
        // Already reportable: the pane the caller wants is there, and pinning
        // would only schedule an unmount for later.
        guard !tabManager.workspaceHasReportablePane(workspace.id) else { return }
        // A second request for the same workspace must not start a second
        // waiter — both would race to unpin, and the loser would drop the pin
        // out from under a workspace the first one is still waiting on.
        guard !tabManager.surfaceRealizationPins.contains(workspace.id) else { return }

        tabManager.pinWorkspaceForSurfaceRealization(workspace.id)
        let workspaceID = workspace.id
        let deadline = Date().addingTimeInterval(Self.surfaceRealizationPinTimeout)
        Task { @MainActor [weak tabManager] in
            defer { tabManager?.unpinWorkspaceForSurfaceRealization(workspaceID) }
            while Date() < deadline {
                try? await Task.sleep(for: Self.surfaceRealizationPollInterval)
                guard let tabManager else { return }
                guard tabManager.tabs.contains(where: { $0.id == workspaceID }) else { return }
                if tabManager.workspaceHasReportablePane(workspaceID) { return }
            }
            // Reaching here means a mounted workspace still produced no
            // reportable pane. The machine that asked is about to report
            // "could not prepare the project workspace" with no idea why, and
            // this is the only place that knows.
            RemoteWorkLog.info(
                "Workspace \(workspaceID.uuidString.prefix(8)) (\(reason)) never opened a terminal "
                    + "after \(Int(Self.surfaceRealizationPinTimeout))s — the machine that asked "
                    + "for it will see an empty workspace"
            )
        }
    }

    /// Rename an existing workspace's display name in place; its id
    /// never changes. Returns `false` (no-op) for an empty/unknown
    /// `workspaceIDBytes` — mirrors the Rust host's
    /// `PeerHost::rename_workspace` contract (`connection.rs`'s
    /// `RenameWorkspaceRequest` handler) of never guessing "the
    /// current" or "the default" workspace. Delegates the actual
    /// title update to `Workspace.setCustomTitle(_:)` — the same
    /// entry point the tab-bar's inline rename UI uses — so a
    /// whitespace-only/empty title clears back to the process title
    /// exactly like a host-local rename would, instead of hand-rolling
    /// a second, slightly different empty-title rule here.
    private func performRenameWorkspace(workspaceIDBytes: Data, title: String) -> Bool {
        guard !workspaceIDBytes.isEmpty,
              let target = uuidFromSurfaceID(workspaceIDBytes),
              let (_, workspace) = workspaceForID(target)
        else {
            #if DEBUG
            dlog("peer.host.renameWorkspace ignored id=\(workspaceIDBytes.map { String(format: "%02x", $0) }.joined().prefix(8)) reason=unknown_or_empty")
            #endif
            return false
        }
        workspace.setCustomTitle(title)
        #if DEBUG
        dlog("peer.host.renameWorkspace id=\(target.uuidString.prefix(8)) title=\(title)")
        #endif
        return true
    }

    /// Delete an existing workspace: tears down every pane inside it
    /// via `TabManager.closeWorkspace` and drops it from that window's
    /// roster. Returns `false` (no-op) for an empty/unknown
    /// `workspaceIDBytes` — same "never delete all/current" contract as
    /// `performRenameWorkspace` and the Rust host's
    /// `PeerHost::remove_workspace`.
    ///
    /// Unlike the Rust daemon host (a single flat workspace collection
    /// that refuses to remove its LAST entry — `RemoveWorkspaceError
    /// .LastWorkspace` — because un-namespaced control always needs a
    /// home), term-mesh.app is multi-window: `TabManager.closeWorkspace`
    /// already guarantees each *window* keeps at least one tab by
    /// replacing the closed one with a fresh blank workspace when it
    /// was the window's last tab. That self-heal is the Mac-side
    /// equivalent of the Rust refusal — it never leaves a window with
    /// zero workspaces — so no separate last-workspace guard is needed
    /// here.
    ///
    /// The caller (`PeerServerSession.dispatch`) does not itself
    /// broadcast `WorkspaceRemoved` — `TabManager.closeWorkspace` posts
    /// `.peerWorkspaceDidClose`, which `PeerHostCoordinator` observes
    /// and forwards to `PeerServer.broadcastWorkspaceRemoved`, so a
    /// host-local close (Cmd+W, sidebar) broadcasts through the exact
    /// same path as a peer-initiated `DeleteWorkspaceRequest`.
    private func performDeleteWorkspace(workspaceIDBytes: Data) -> Bool {
        guard !workspaceIDBytes.isEmpty,
              let target = uuidFromSurfaceID(workspaceIDBytes),
              let (tabManager, workspace) = workspaceForID(target)
        else {
            #if DEBUG
            dlog("peer.host.deleteWorkspace ignored id=\(workspaceIDBytes.map { String(format: "%02x", $0) }.joined().prefix(8)) reason=unknown_or_empty")
            #endif
            return false
        }
        #if DEBUG
        dlog("peer.host.deleteWorkspace id=\(target.uuidString.prefix(8)) paneCount=\(workspace.panels.count)")
        #endif
        tabManager.closeWorkspace(workspace)
        return true
    }

    /// Find the live `Workspace` (across every host window) whose id
    /// matches `target`, plus the `TabManager` that owns it. Shared
    /// lookup for rename/delete — both address a workspace by its wire
    /// `workspace_id`, not by a pane inside it (contrast
    /// `workspaceContaining(panelUUID:)` below).
    private func workspaceForID(_ target: UUID) -> (tabManager: TabManager, workspace: Workspace)? {
        for ctx in allWindowContexts() {
            if let workspace = ctx.tabManager.tabs.first(where: { $0.id == target }) {
                return (ctx.tabManager, workspace)
            }
        }
        return nil
    }

    private func uuidFromSurfaceID(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func workspaceContaining(panelUUID: UUID) -> Workspace? {
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                if workspace.panels[panelUUID] != nil {
                    return workspace
                }
            }
        }
        return nil
    }

    // MARK: - Peer attach indicator

    /// Per-surface attach counter. Lives on the @MainActor-isolated
    /// type so reads/writes serialize with the rest of provider state.
    private static var peerAttachCounts: [UUID: Int] = [:]

    /// Bump the attach counter and update the teal ring + count
    /// badge. Returns `true` when this attach transitioned the surface
    /// from 0 → 1 — i.e. it's the first peer attaching, used by the
    /// caller to decide whether to inject Ctrl-L for TUI redraw.
    @discardableResult
    static func incrementPeerAttach(for ts: TerminalSurface) -> Bool {
        let prev = peerAttachCounts[ts.id] ?? 0
        let next = prev + 1
        peerAttachCounts[ts.id] = next
        ts.hostedView.setPeerRing(visible: true, count: next)
        return prev == 0
    }

    static func decrementPeerAttach(for ts: TerminalSurface) {
        let prev = peerAttachCounts[ts.id] ?? 0
        let next = max(0, prev - 1)
        if next == 0 {
            peerAttachCounts.removeValue(forKey: ts.id)
            ts.hostedView.setPeerRing(visible: false, count: 0)
        } else {
            peerAttachCounts[ts.id] = next
            ts.hostedView.setPeerRing(visible: true, count: next)
        }
    }

    // MARK: - Private helpers

    /// All live main-window contexts, in a deterministic order.
    ///
    /// `AppDelegate.mainWindowContexts` is an unordered dictionary, so it is
    /// sorted by `windowId` to keep the workspace roster the host advertises
    /// to peers stable across repeated `listWorkspaces` fetches (a churning
    /// order would reshuffle the client's picker/sidebar on every refresh).
    /// Each entry carries the owning window's id + title so a workspace can
    /// be tagged with the window it belongs to — the host may have several
    /// top-level windows open, each with its own `TabManager`, and a peer
    /// client should see ALL of them, not just the active one.
    private func allWindowContexts()
        -> [(windowId: UUID, windowTitle: String, tabManager: TabManager)] {
        guard let appDelegate = AppDelegate.shared else { return [] }
        return appDelegate.mainWindowContexts.values
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .map { ctx in (ctx.windowId, windowLabel(for: ctx), ctx.tabManager) }
    }

    /// Best-effort human label for a host window, used by the client to head
    /// the window's section in the workspace picker/sidebar. Derived from the
    /// window's *selected* workspace title rather than `NSWindow.title`,
    /// because the title bar is only kept in sync for the key window — a
    /// background window's `.title` is often empty or stale. Falls back to the
    /// live title, then to "" so the client renders a short window-id suffix.
    /// Snapshot semantics match the other workspace fields: refreshed on each
    /// `listWorkspaces`/layout-change push, not on bare title edits.
    private func windowLabel(for ctx: AppDelegate.MainWindowContext) -> String {
        let mgr = ctx.tabManager
        if let selID = mgr.selectedTabId,
           let ws = mgr.tabs.first(where: { $0.id == selID }) {
            let title = (ws.customTitle ?? ws.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return (ctx.window?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wake up any pane whose `ghostty_surface_t` hasn't been created
    /// yet (newly opened splits, background tabs). Non-blocking — caller
    /// polls `allSurfacesReady` to know when init has settled.
    private func kickLazySurfaceStarts() {
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel,
                          !terminal.isRemoteOrigin else { continue }
                    let ts = terminal.surface
                    if ts.surface == nil {
                        ts.requestBackgroundSurfaceStartIfNeeded()
                    }
                }
            }
        }
    }

    /// True when every terminal pane has a non-nil `ghostty_surface_t`.
    private func allSurfacesReady() -> Bool {
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel,
                          !terminal.isRemoteOrigin else { continue }
                    if terminal.surface.surface == nil { return false }
                }
            }
        }
        return true
    }

    private func collectWorkspaces() -> [Termmesh_Peer_V1_Workspace] {
        var result: [Termmesh_Peer_V1_Workspace] = []
        for ctx in allWindowContexts() {
            let windowIDBytes = withUnsafeBytes(of: ctx.windowId.uuid) { Data($0) }
            for workspace in ctx.tabManager.tabs {
                let tree = workspace.bonsplitController.treeSnapshot()
                guard let layout = translateBonsplitNode(tree, workspace: workspace) else {
                    continue
                }
                var ws = Termmesh_Peer_V1_Workspace()
                ws.workspaceID = withUnsafeBytes(of: workspace.id.uuid) { Data($0) }
                ws.title = workspace.customTitle ?? workspace.title
                ws.layout = layout
                ws.windowID = windowIDBytes
                ws.windowTitle = ctx.windowTitle
                result.append(ws)
            }
        }
        return result
    }

    /// Walk a bonsplit `ExternalTreeNode` and produce the corresponding
    /// `WorkspaceLayout` proto. Pane leaves are dereferenced via
    /// `workspace.surfaceIdToPanelId` to find the underlying
    /// TerminalSurface ID — that's the value clients use for
    /// AttachSurface. Non-terminal panes (browsers, panes whose
    /// surface hasn't materialised yet) are dropped; if both children
    /// of a split drop, the split itself is folded out.
    private func translateBonsplitNode(
        _ node: ExternalTreeNode,
        workspace: Workspace
    ) -> Termmesh_Peer_V1_WorkspaceLayout? {
        switch node {
        case .pane(let pane):
            guard let selectedTabIDStr = pane.selectedTabId ?? pane.tabs.first?.id,
                  let tabUUID = UUID(uuidString: selectedTabIDStr),
                  let panelUUID = workspace.surfaceIdToPanelId[TabID(uuid: tabUUID)],
                  let terminal = workspace.panels[panelUUID] as? TerminalPanel,
                  !terminal.isRemoteOrigin,
                  let sfcPtr = terminal.surface.surface
            else {
                // An unrealized pane is dropped here, which is why a workspace
                // nobody has mounted reads as empty from the other end. That is
                // the whole reason peer-created workspaces get a realization
                // pin — see `TabManager.surfaceRealizationPins`.
                return nil
            }
            let ts = terminal.surface
            var paneMsg = Termmesh_Peer_V1_WorkspacePane()
            paneMsg.surfaceID = surfaceIDBytes(ts.id)
            paneMsg.title = workspace.panelTitles[terminal.id] ?? "Terminal"
            let sz = ghostty_surface_size(sfcPtr)
            paneMsg.cols = UInt32(sz.columns)
            paneMsg.rows = UInt32(sz.rows)
            if let cwd = workspace.panelDirectories[terminal.id] {
                paneMsg.cwd = cwd
            }
            // Phase E-4: include every tab in this bonsplit pane so
            // the relay window can render a tab strip and let the user
            // switch the active tab via WorkspaceControl.activate_tab.
            paneMsg.tabs = pane.tabs.compactMap { tab -> Termmesh_Peer_V1_PaneTab? in
                guard let tUUID = UUID(uuidString: tab.id),
                      let pUUID = workspace.surfaceIdToPanelId[TabID(uuid: tUUID)],
                      let term = workspace.panels[pUUID] as? TerminalPanel,
                      !term.isRemoteOrigin,
                      term.surface.surface != nil
                else { return nil }
                var t = Termmesh_Peer_V1_PaneTab()
                t.surfaceID = surfaceIDBytes(term.surface.id)
                t.title = workspace.panelTitles[term.id] ?? "Terminal"
                return t
            }
            var layout = Termmesh_Peer_V1_WorkspaceLayout()
            layout.pane = paneMsg
            return layout

        case .split(let split):
            let firstChild = translateBonsplitNode(split.first, workspace: workspace)
            let secondChild = translateBonsplitNode(split.second, workspace: workspace)
            // If one side has nothing attachable, fold the split out
            // and surface only the populated child.
            switch (firstChild, secondChild) {
            case (nil, nil):
                return nil
            case (let f?, nil):
                return f
            case (nil, let s?):
                return s
            case (let f?, let s?):
                var splitMsg = Termmesh_Peer_V1_WorkspaceSplit()
                splitMsg.orientation = split.orientation
                splitMsg.dividerPosition = split.dividerPosition
                splitMsg.first = f
                splitMsg.second = s
                if let splitUUID = UUID(uuidString: split.id) {
                    splitMsg.splitID = withUnsafeBytes(of: splitUUID.uuid) { Data($0) }
                }
                var layout = Termmesh_Peer_V1_WorkspaceLayout()
                layout.split = splitMsg
                return layout
            }
        }
    }

    private func collectSurfaces() -> [Termmesh_Peer_V1_SurfaceInfo] {
        var result: [Termmesh_Peer_V1_SurfaceInfo] = []
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel,
                          !terminal.isRemoteOrigin else { continue }
                    let ts = terminal.surface
                    guard let sfcPtr = ts.surface else { continue }
                    var info = Termmesh_Peer_V1_SurfaceInfo()
                    info.surfaceID = surfaceIDBytes(ts.id)
                    info.title = workspace.panelTitles[terminal.id] ?? "Terminal"
                    info.surfaceType = "terminal"
                    info.attachable = true
                    let sz = ghostty_surface_size(sfcPtr)
                    info.cols = UInt32(sz.columns)
                    info.rows = UInt32(sz.rows)
                    if let cwd = workspace.panelDirectories[terminal.id] {
                        info.cwd = cwd
                    }
                    result.append(info)
                }
            }
        }
        return result
    }

    private func findSurface(id: Data) -> (ghostty_surface_t, TerminalSurface)? {
        for ctx in allWindowContexts() {
            for workspace in ctx.tabManager.tabs {
                for (_, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel,
                          !terminal.isRemoteOrigin else { continue }
                    let ts = terminal.surface
                    guard surfaceIDBytes(ts.id) == id else { continue }
                    guard let ptr = ts.surface else { continue }
                    return (ptr, ts)
                }
            }
        }
        return nil
    }
}

// MARK: - Helpers

/// Per-surface carry buffer for trailing incomplete escape sequences.
/// If a TYPE_KEY_INPUT chunk ends with a lone 0x1b (or partial CSI head),
/// we hold those bytes here and prepend them to the next chunk so the
/// sequence isn't split across frame boundaries.
/// Key = surface pointer identity (UInt(bitPattern:)). @MainActor — all
/// accesses happen on the main thread via sendPeerInputBytes.
/// Bound to ≤32 bytes per surface to prevent unbounded growth on malformed input.
@MainActor private var peerPendingInputTail: [UInt: [UInt8]] = [:]
private let peerPendingInputTailMax = 32

/// Generation token per surface for the deferred-tail flush timer. Bumped
/// whenever the pending tail is set or cleared so a stale timer (fired after
/// the tail was already consumed/replaced) becomes a no-op.
@MainActor private var peerPendingTailFlushGen: [UInt: Int] = [:]
/// Weak surface reference per surface key, so schedulePeerPendingTailFlush()
/// can re-fetch the live surface after its timeout WITHOUT capturing the raw
/// `ghostty_surface_t` (OpaquePointer, not Sendable) across an await. Mirrors
/// the attach-time `weakTS.value?.surface` re-fetch pattern.
@MainActor private var peerSurfaceRefForKey: [UInt: WeakRef<TerminalSurface>] = [:]
/// Deferred-tail flush delay. Mirrors the relay's ESC_FLUSH_TIMEOUT_MS (100 ms)
/// plus a little slack for socket jitter, so a lone Escape that has no
/// follow-up keystroke is still delivered promptly instead of hanging until
/// the next key.
private let peerPendingTailFlushDelayNanos: UInt64 = 120_000_000

/// FIX C: Multi-chunk bracketed paste accumulator. When `\e[200~` arrives
/// without a matching `\e[201~` in the same frame, we stash the body bytes
/// here and keep consuming subsequent frames as paste content until the
/// closing marker is seen. Then we flush the buffered body through
/// `ghostty_surface_text` so Ghostty re-wraps in bracketed paste markers
/// for the destination surface (vim/codex/claude see a real paste instead
/// of a stream of keystrokes that triggers autoindent and command-mode
/// shortcuts mid-paste).
///
/// Key = surface pointer identity (UInt(bitPattern:)). @MainActor.
@MainActor private var peerPendingPasteBody: [UInt: Data] = [:]
/// FIX C v2: timestamp of the last byte appended to `peerPendingPasteBody`.
/// Used to detect a stalled paste accumulator (close marker `\e[201~`
/// never arrived — relay dropped it, SSH stalled, user aborted, etc.).
/// Without this safety valve, every subsequent keystroke gets absorbed
/// as paste body and the destination surface becomes unresponsive: even
/// a bare ESC never reaches the next-hop vim, so the user can't escape
/// INSERT mode and `:q!` shows up as literal text. On a stale entry we
/// flush whatever was buffered and resume normal parsing.
@MainActor private var peerPendingPasteTimestamp: [UInt: Date] = [:]
/// Frame-to-frame idle window. Real pastes arrive as a burst (consecutive
/// frames within milliseconds); a gap of this size means the close
/// marker is gone and we should not keep eating keystrokes.
private let peerPendingPasteIdleTimeout: TimeInterval = 0.75
/// Hard cap on accumulated paste body. Exceeding this flushes whatever
/// has been collected so far and drops the rest of the paste; the
/// destination app sees a truncated paste rather than an unbounded buffer.
/// 8 MiB is well above any realistic clipboard payload.
private let peerPendingPasteBodyMax = 8 * 1024 * 1024

/// FIX A: Release any buffered incomplete-escape tail for a peer surface
/// when the last client detaches. Prevents stale bytes from being prepended
/// to a new session if the OS reuses the same surface pointer address.
@MainActor
private func clearPeerPendingInputTail(surfaceKey: UInt) {
    peerPendingInputTail.removeValue(forKey: surfaceKey)
    peerPendingPasteBody.removeValue(forKey: surfaceKey)
    peerPendingPasteTimestamp.removeValue(forKey: surfaceKey)
    // Drop the deferred-tail flush bookkeeping so nothing accumulates for a
    // torn-down surface. An in-flight timer captured its generation by value,
    // so after this removal its `peerPendingTailFlushGen[surfaceKey]` lookup is
    // nil (≠ the captured gen) and it no-ops; the tail-equality guard covers the
    // rare surface-pointer-reuse case.
    peerPendingTailFlushGen.removeValue(forKey: surfaceKey)
    peerSurfaceRefForKey.removeValue(forKey: surfaceKey)
}

/// Schedule a one-shot flush of a deferred lone-Escape / incomplete-escape
/// tail. If, after the timeout, the buffered bytes are unchanged (no follow-up
/// frame completed or replaced them) the tail is delivered as-is via a final
/// pass through `sendPeerInputBytes`. The surface is re-fetched from the weak
/// registry inside the closure, never captured raw across the await.
@MainActor
private func schedulePeerPendingTailFlush(surfaceKey: UInt, tail: [UInt8]) {
    let gen = (peerPendingTailFlushGen[surfaceKey] ?? 0) + 1
    peerPendingTailFlushGen[surfaceKey] = gen
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: peerPendingTailFlushDelayNanos)
        guard peerPendingTailFlushGen[surfaceKey] == gen,
              peerPendingInputTail[surfaceKey] == tail,
              let ptr = peerSurfaceRefForKey[surfaceKey]?.value?.surface else { return }
        sendPeerInputBytes(ptr, bytes: Data(), finalFlush: true)
    }
}

/// FIX C helper: flush accumulated paste body to the destination surface.
@MainActor
private func flushPeerPasteBody(_ surface: ghostty_surface_t, _ body: Data) {
    guard !body.isEmpty else { return }
    body.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress?
            .assumingMemoryBound(to: CChar.self) else { return }
        ghostty_surface_text(surface, base, UInt(rawBuffer.count))
    }
}

/// FIX C helper: consume bytes from `arr` while in paste-accumulate mode.
/// Returns the number of bytes consumed. If the close marker `\e[201~`
/// appears in this chunk, flushes the buffered body and returns the
/// position just past the marker; the caller should resume normal parsing
/// on the remainder. If no close marker is found, consumes the entire
/// chunk into the buffer and returns `arr.count`.
@MainActor
private func absorbPasteContinuation(
    surface: ghostty_surface_t,
    surfaceKey: UInt,
    arr: [UInt8]
) -> Int {
    var closeStart: Int? = nil
    var j = 0
    while j + 5 < arr.count {
        if arr[j] == 0x1b,
           arr[j + 1] == 0x5b,
           arr[j + 2] == 0x32,
           arr[j + 3] == 0x30,
           arr[j + 4] == 0x31,
           arr[j + 5] == 0x7e {
            closeStart = j
            break
        }
        j += 1
    }

    if let close = closeStart {
        var body = peerPendingPasteBody.removeValue(forKey: surfaceKey) ?? Data()
        peerPendingPasteTimestamp.removeValue(forKey: surfaceKey)
        if close > 0 {
            body.append(contentsOf: arr[0..<close])
        }
        flushPeerPasteBody(surface, body)
        return close + 6
    }

    // Hold back a trailing incomplete ESC sequence so a close marker
    // (`\e[201~`) that straddles a relay read boundary — e.g. `…\e[20` here
    // and `1~…` in the next frame — can be reassembled. The buffered tail is
    // prepended at the next `sendPeerInputBytes` entry (peerPendingInputTail),
    // so `absorbPasteContinuation` then sees the full marker and closes the
    // paste. Without this the partial marker is appended to the body verbatim,
    // the paste never closes, and subsequent keystrokes are swallowed into the
    // accumulator until the idle timeout. Mirrors the FIX B tail deferral on
    // the non-paste path (and the UTF-8 tail deferral in sendPeerInputBytes).
    let tailLen = trailingIncompleteEscape(arr, bound: peerPendingInputTailMax)
    let bodyEnd = arr.count - tailLen
    if tailLen > 0 {
        let tail = Array(arr[bodyEnd...])
        peerPendingInputTail[surfaceKey] = tail
        schedulePeerPendingTailFlush(surfaceKey: surfaceKey, tail: tail)
    }
    var body = peerPendingPasteBody[surfaceKey] ?? Data()
    if bodyEnd > 0 {
        body.append(contentsOf: arr[0..<bodyEnd])
    }
    if body.count > peerPendingPasteBodyMax {
        flushPeerPasteBody(surface, body)
        peerPendingPasteBody.removeValue(forKey: surfaceKey)
        peerPendingPasteTimestamp.removeValue(forKey: surfaceKey)
    } else {
        peerPendingPasteBody[surfaceKey] = body
        peerPendingPasteTimestamp[surfaceKey] = Date()
    }
    return arr.count
}

/// FIX B: Return the number of trailing bytes in `arr` that form an
/// incomplete ESC-introduced sequence (CSI/OSC/SS3 head split across a frame
/// boundary). Scans backward up to `bound` bytes from the end looking for
/// the rightmost 0x1b; if found and `peerEscapeSequenceLength` returns nil
/// (incomplete), returns the tail length — caller should buffer those bytes.
/// Returns 0 when no incomplete tail is detected.
///
/// Scenarios where tail > 0:
///   - Lone ESC at end            ("\e")        → tailLen 1
///   - Partial CSI head           ("\e[")        → tailLen 2
///   - Partial CSI with params    ("\e[<35")     → tailLen 4+
///   - SS3 missing final byte     ("\eO")        → tailLen 2
///   - OSC without BEL/ST         ("\e]0;txt")   → tailLen varies
///
/// Bound cap: ESC is only searched within the last `bound` bytes, so
/// tailLen ≤ bound. A giant OSC split across >32-byte frames falls through
/// with tailLen = 0 (the leading ESC is beyond the search window) — this
/// matches the pre-FIX-B behavior for that edge case.
private func trailingIncompleteEscape(_ arr: [UInt8], bound: Int) -> Int {
    let start = max(0, arr.count - bound)
    var i = arr.count - 1
    while i >= start {
        if arr[i] == 0x1b {
            let tail = Array(arr[i..<arr.count])
            return peerEscapePrefixCouldComplete(tail) ? arr.count - i : 0
        }
        i -= 1
    }
    return 0
}

/// True when `tail` (which begins with ESC) is a *prefix* of a still-
/// completable escape sequence — i.e. more bytes could turn it into a valid
/// CSI / OSC / SS3. This is the crucial distinction `peerEscapeSequenceLength`
/// alone cannot make: that helper returns nil for BOTH a genuinely incomplete
/// head ("\e[" waiting for a final byte) AND a complete ESC keypress followed
/// by literal input ("\e:" = Escape then ':'). Deferring the latter is the bug
/// behind vim ":wq!" after Escape: the host stashes ESC, then mis-reads
/// ESC+':' / ESC+'w' / … as "still incomplete" and buffers the whole string
/// into `peerPendingInputTail` until 32 bytes accumulate — the surface freezes
/// then releases in a burst. Only genuine prefixes may be deferred here.
private func peerEscapePrefixCouldComplete(_ tail: [UInt8]) -> Bool {
    guard tail.first == 0x1b else { return false }
    // Lone trailing ESC: ambiguous (could begin CSI/OSC/SS3, or be a bare
    // Escape key). Defer; schedulePeerPendingTailFlush() releases it after a
    // short timeout — mirroring the relay's ESC_FLUSH_TIMEOUT_MS — so a real
    // Escape never hangs the remote app in e.g. vim INSERT mode.
    guard tail.count >= 2 else { return true }
    switch tail[1] {
    case 0x5b: // '[' — CSI, completable while body bytes stay in 0x20...0x3f
        for k in 2..<tail.count {
            let b = tail[k]
            if (0x40...0x7e).contains(b) { return false }   // already terminated
            if !(0x20...0x3f).contains(b) { return false }  // invalid CSI body byte
        }
        return true                                          // valid, unterminated
    case 0x5d: // ']' — OSC, completable until BEL (0x07) or ST (ESC '\')
        var k = 2
        while k < tail.count {
            if tail[k] == 0x07 { return false }
            if tail[k] == 0x1b, k + 1 < tail.count, tail[k + 1] == 0x5c { return false }
            k += 1
        }
        return true
    case 0x4f: // 'O' — SS3, needs exactly one final byte
        return tail.count < 3
    default:
        // ESC + a byte that cannot introduce CSI/OSC/SS3 ⇒ a complete Escape
        // keypress immediately followed by literal input. Never defer.
        return false
    }
}

/// Route peer Input bytes into Ghostty as key events.
///
/// All bytes flow through `ghostty_surface_key()`; we deliberately avoid
/// `ghostty_surface_text()` because that path wraps content in bracketed
/// paste markers which (a) breaks Enter / Tab / Ctrl-C semantics in
/// readline-style shells and (b) eats some control bytes before they
/// reach the PTY. Mirroring `GhosttyTerminalView.sendSocketStyleText`:
///
/// - Enter (CR/LF), Tab, Backspace, Escape        → key event with keycode
/// - CSI/SS3 navigation keys and function keys    → key event with keycode
/// - Ctrl-letter control bytes (0x01-0x1A)        → key event + Ctrl mod
/// - Anything else                                 → key event (keycode=0)
///   with the Unicode scalar as text. Multi-byte UTF-8 sequences are
///   grouped into a single scalar before dispatch.
///
/// LF→Return mapping is needed because the relay binary's stdin is a PTY
/// slave with default ICRNL, so Ghostty writes CR but the relay reads
/// LF before forwarding over the peer socket.
#if DEBUG
/// Test-only entry point: route raw bytes through the host peer-relay
/// re-encode path exactly as a connected peer client's Input frame would,
/// without needing a live peer server/relay. Backs the
/// `debug.peer.inject_input` socket command used by the ESC-freeze
/// regression test (`tests_v2/test_peer_input_esc_freeze_regression.py`).
@MainActor
func debugInjectPeerInput(_ surface: ghostty_surface_t, bytes: Data) {
    sendPeerInputBytes(surface, bytes: bytes)
}
#endif

#if DEBUG
/// Debug/test-only extension backing `debug.peer.replay_probe` (Phase P4).
/// Exercises the exact `PtyTapHub`/`ReplayBuffer` decision `attach()` uses
/// so socket e2e can assert the buffer-vs-snapshot replay contract against a
/// live surface's real ring-buffer state, without standing up a live 2-node
/// peer session or a full `PeerSurfaceAttachment` (stream/input/resize/detach).
extension GhosttyPaneSurfaceProvider {
    /// Test-scoped singleton, deliberately separate from whatever
    /// `GhosttyPaneSurfaceProvider` instance `PeerServerHost` creates for
    /// real peer hosting (`Sources/PeerServerHost.swift:257`). Its own
    /// `tapHubs` dict is what lets repeated `debug.peer.replay_probe` calls
    /// against the same surface observe the same accumulating buffer across
    /// separate socket round-trips — a fresh instance per call would
    /// re-create (and so reset) the hub every time. No state is shared with
    /// production hosting; this exists purely for the test probe.
    static let debugProbeShared = GhosttyPaneSurfaceProvider()

    /// Ensure a `PtyTapHub` exists for `surfaceID` (creating + wiring the C
    /// PTY tap callback on first call — exactly `attach()`'s hub lookup — so
    /// real PTY output starts accumulating into its replay buffer from that
    /// point on), then report the same buffer-vs-snapshot decision
    /// `attach()` consults via `PtyTapHub.replaySnapshot()`. Returns `nil`
    /// when `surfaceID` doesn't resolve to a live surface (test-visible as
    /// `{ok: false, error: "unknown_surface"}`, not an RPC-level error).
    /// `text` is a best-effort lossy UTF-8 decode of the replayed bytes so a
    /// caller can assert on actual content (e.g. a marker + its raw ANSI
    /// escape survived), not just the byte count.
    func debugReplayProbe(surfaceID: Data) -> (mode: String, bytes: Int, chunks: Int, text: String)? {
        guard let (sfcPtr, ts) = findSurface(id: surfaceID) else { return nil }
        let hub: PtyTapHub
        if let existing = tapHubs[ts.id] {
            hub = existing
        } else {
            hub = PtyTapHub(surfaceID: ts.id, surfacePtr: sfcPtr, surfaceRef: ts)
            tapHubs[ts.id] = hub
            let hubPtr = Unmanaged.passUnretained(hub).toOpaque()
            ghostty_surface_set_pty_data_callback(sfcPtr, ptyTapCallback, hubPtr)
        }
        let snap = hub.replaySnapshot()
        return (
            mode: snap.isSafeForCompleteReplay ? "buffer" : "snapshot",
            bytes: snap.bytes.count,
            chunks: snap.chunkCount,
            text: String(decoding: snap.bytes, as: UTF8.self)
        )
    }
}
#endif

/// Number of trailing bytes that form an *incomplete* UTF-8 multibyte
/// sequence (a lead byte plus fewer continuation bytes than its length
/// requires). Returns 0 when the buffer ends on a complete character or on
/// invalid data. Used to defer a partial sequence to the next input frame so
/// `String(bytes:encoding:.utf8)` decodes the full character instead of
/// garbling it via the Latin-1 per-byte fallback.
private func trailingIncompleteUTF8(_ arr: [UInt8]) -> Int {
    let n = arr.count
    if n == 0 { return 0 }
    // Walk back over continuation bytes (10xxxxxx). A complete sequence needs
    // at most 3 continuation bytes (4-byte char), so cap the scan.
    var cont = 0
    var idx = n - 1
    while idx >= 0, cont < 3, (arr[idx] & 0xC0) == 0x80 {
        cont += 1
        idx -= 1
    }
    if idx < 0 { return 0 }            // ran off the front — malformed, don't buffer
    let lead = arr[idx]
    let expected: Int
    if lead & 0x80 == 0 { return 0 }   // ASCII byte can't start a multibyte seq
    else if lead & 0xE0 == 0xC0 { expected = 2 }
    else if lead & 0xF0 == 0xE0 { expected = 3 }
    else if lead & 0xF8 == 0xF0 { expected = 4 }
    else { return 0 }                  // not a valid lead byte
    let have = cont + 1                 // lead + continuation bytes present
    return have < expected ? have : 0   // incomplete → buffer; complete → process now
}

@MainActor
private func sendPeerInputBytes(_ surface: ghostty_surface_t, bytes: Data, finalFlush: Bool = false) {
    // FIX 2 / FIX B: prepend any bytes carried over from the previous chunk,
    // then trim any new incomplete ESC tail before the main parse loop so that
    // split CSI/OSC/SS3 heads ("\e[", "\e[<35", etc.) are also deferred — not
    // just lone trailing ESC (the old FIX 2 scope).
    let surfaceKey = UInt(bitPattern: surface)
    var arr: [UInt8]
    if let pending = peerPendingInputTail.removeValue(forKey: surfaceKey), !pending.isEmpty {
        arr = pending + Array(bytes)
    } else {
        arr = Array(bytes)
    }

    // FIX C: if a previous frame opened a bracketed paste that hasn't been
    // closed yet, this frame's bytes belong to the paste body (until the
    // closing `\e[201~`). Drain those bytes into the accumulator before the
    // normal parser runs. Bytes past the close marker (if any) fall through.
    if let body = peerPendingPasteBody[surfaceKey] {
        // FIX C v2 safety valve: if the previous paste burst ended without
        // ever delivering `\e[201~` and the next frame arrives after a
        // pause, treat the accumulator as stalled. Flush what we have so
        // the user at least gets the leading half of the paste, clear
        // state, and run this frame through the normal parser. Without
        // this, every subsequent keystroke (ESC, `:`, `q`, `!`) gets
        // absorbed into the paste body and the destination surface
        // becomes unresponsive.
        //
        // A `finalFlush` entry forces the same stall handling. The 120ms
        // deferred-tail timer re-enters here with `finalFlush: true` carrying an
        // incomplete close prefix (`\e[20`). Routing that through
        // `absorbPasteContinuation` would re-buffer the same tail and refresh
        // `peerPendingPasteTimestamp` every tick — a livelock that keeps `idle`
        // pinned below the 0.75s safety window forever, so the valve never fires
        // and later keystrokes are swallowed indefinitely. Treat `finalFlush` as
        // "the burst is over": flush the body, clear state, and let the dangling
        // bytes fall through (the prelude's `finalFlush` path runs them without
        // re-deferring a tail).
        let lastTs = peerPendingPasteTimestamp[surfaceKey]
        let idle = lastTs.map { Date().timeIntervalSince($0) } ?? .infinity
        if finalFlush || idle > peerPendingPasteIdleTimeout {
            flushPeerPasteBody(surface, body)
            peerPendingPasteBody.removeValue(forKey: surfaceKey)
            peerPendingPasteTimestamp.removeValue(forKey: surfaceKey)
            // Fall through to normal parser on this frame.
        } else {
            let consumed = absorbPasteContinuation(
                surface: surface, surfaceKey: surfaceKey, arr: arr)
            if consumed >= arr.count {
                return
            }
            arr = Array(arr[consumed...])
        }
    }

    // FIX B prelude: detect any trailing incomplete escape sequence and buffer
    // it now, before the main loop, so the loop never sees a partial head.
    // On a final flush (timer-driven) treat every byte as processable so a
    // deferred lone Escape / stale escape head is delivered instead of being
    // re-buffered forever.
    //
    // Defer two kinds of trailing partials so the main loop never sees a
    // truncated sequence: (1) an incomplete ESC head, and (2) an incomplete
    // UTF-8 multibyte sequence. A paste of multibyte text (e.g. Korean, 3
    // bytes/char) split across protocol frames would otherwise leave a partial
    // UTF-8 sequence at the frame boundary; the printable path's
    // `String(bytes:encoding:.utf8)` then fails and the per-byte fallback
    // decodes each byte as a Latin-1 scalar — turning "결과" into "ê²°ê³¼".
    // Buffering the partial tail and prepending it to the next frame lets the
    // full sequence decode correctly.
    let escTail = finalFlush ? 0 : trailingIncompleteEscape(arr, bound: peerPendingInputTailMax)
    let utf8Tail = finalFlush ? 0 : trailingIncompleteUTF8(arr)
    let tailLen = max(escTail, utf8Tail)
    let processCount = arr.count - tailLen
    if tailLen > 0 {
        let tail = Array(arr[processCount...])
        peerPendingInputTail[surfaceKey] = tail
        schedulePeerPendingTailFlush(surfaceKey: surfaceKey, tail: tail)
    }
    var i = 0
    while i < processCount {
        let byte = arr[i]

        if byte == 0x1b,
           let sequence = peerEscapeKeySequence(arr, start: i) {
            sendPeerKeyEvent(surface, keycode: sequence.keycode, mods: sequence.mods, text: nil)
            i += sequence.consumed
            continue
        }

        // Bracketed-paste passthrough. `\e[200~…\e[201~` brackets paste
        // content from the client. The body must reach the next-hop
        // verbatim: raw `\n` / `\r` / ESC bytes get re-encoded as
        // `\e[13;2u` / `\e[27u` when funneled through the surface_key
        // path (kitty / modifyOtherKeys mode), and vim's paste decoder
        // then writes those bytes into the buffer as invisible
        // characters — the user sees only blank lines. Even sending
        // markers + body as a single surface_key text payload loses the
        // first few bytes of body (observed: `\e[200~⏺ R…` → vim sees
        // only `an…`), because Ghostty's text-key handler tries to
        // parse leading ESC sequences as input encodings.
        //
        // Fix: strip the markers and route the inner content through
        // `ghostty_surface_text`, the same API local paste uses. Ghostty
        // re-wraps with `\e[200~…\e[201~` automatically when the remote
        // surface has bracketed-paste mode enabled (set by the
        // next-hop app), so vim still sees a real paste.
        //
        // Stateless across Input frames: only handle the case where
        // both markers land in this chunk. Multi-chunk pastes fall
        // through to the legacy per-byte path — still imperfect but no
        // worse than before this fix.
        if byte == 0x1b,
           i + 5 < arr.count,
           arr[i + 1] == 0x5b,
           arr[i + 2] == 0x32,
           arr[i + 3] == 0x30,
           arr[i + 4] == 0x30,
           arr[i + 5] == 0x7e {
            var closeStart: Int? = nil
            var j = i + 6
            while j + 5 < arr.count {
                if arr[j] == 0x1b,
                   arr[j + 1] == 0x5b,
                   arr[j + 2] == 0x32,
                   arr[j + 3] == 0x30,
                   arr[j + 4] == 0x31,
                   arr[j + 5] == 0x7e {
                    closeStart = j
                    break
                }
                j += 1
            }
            if let close = closeStart {
                let body = Data(arr[(i + 6)..<close])
                if !body.isEmpty {
                    body.withUnsafeBytes { rawBuffer in
                        guard let base = rawBuffer.baseAddress?
                            .assumingMemoryBound(to: CChar.self) else { return }
                        ghostty_surface_text(surface, base, UInt(rawBuffer.count))
                    }
                }
                i = close + 6
                continue
            }
            // FIX C: no close marker in this frame — open the paste
            // accumulator. Bytes from `i + 6` up to `processCount` become the
            // first slice of the paste body. Any trailing incomplete-UTF-8 /
            // escape tail the FIX B prelude detected (bytes in
            // `processCount..<arr.count`) is ALREADY stashed in
            // `peerPendingInputTail`; it must NOT be appended here too. Slicing
            // to `arr.count` and re-appending the stash would double-count the
            // partial bytes (e.g. the leading 1–2 bytes of a frame-split Korean
            // glyph), corrupting the paste. Leave the tail in
            // `peerPendingInputTail` so the next frame's prelude prepends it
            // (~`peerPendingInputTail` drain at the top of `sendPeerInputBytes`)
            // and `absorbPasteContinuation` absorbs the completed glyph. If no
            // next frame arrives, the scheduled tail flush delivers it.
            //
            // `processCount >= i + 6` holds because the opener's terminating
            // `~` (0x7e, ASCII) stops any trailing-UTF-8/escape tail from
            // reaching into the marker; `max` is a defensive clamp so a future
            // tail-detector change can never invert the slice and trap.
            let bodyEnd = max(i + 6, processCount)
            let body = Data(arr[(i + 6)..<bodyEnd])
            if body.count > peerPendingPasteBodyMax {
                flushPeerPasteBody(surface, body)
            } else {
                peerPendingPasteBody[surfaceKey] = body
                peerPendingPasteTimestamp[surfaceKey] = Date()
            }
            return
        }

        // SGR mouse WHEEL report (`\e[<btn;col;rowM`) from the viewer.
        // The attach-time DECSET replay (48efa7cd) puts the viewer surface
        // in captured mode, so its wheel arrives here as SGR press
        // reports — which the unrecognized-CSI branch below silently
        // dropped: the reason peer viewers still could not scroll
        // Claude Code / vim even after the mode replay fix. There is no
        // verbatim-byte-injection API, so re-dispatch each report through
        // ghostty_surface_mouse_scroll: core then re-encodes for the host
        // pane's REAL mouse state (exact tracking mode + encoding),
        // falls back to alternate-scroll arrow keys, or scrolls the pane
        // viewport — identical to a local wheel tick on the host pane.
        // One report is fed as one non-precision tick so viewer and local
        // scroll speeds match (Surface.zig scrollCallback normalizes a
        // tick to one row before re-encoding). Click/motion reports still
        // fall through to the drop branch below. Report coordinates are
        // not forwarded: ghostty uses its last-known host-side cursor
        // position, which is irrelevant for transcript scrolling and only
        // matters for scrolling a specific split inside a remote TUI.
        if byte == 0x1b, let wheel = peerSgrWheelReport(arr, start: i) {
            // ghostty's SGR encoder drops wheel reports whose host-side
            // mouse position sits outside the pane viewport
            // (mouse_encode.zig posOutOfViewport) — true whenever the
            // host user's real cursor hovers some other window. Warp the
            // surface's cursor to the viewer-reported cell first so the
            // re-encoded report survives that guard AND carries the cell
            // the viewer actually scrolled over.
            movePeerMouseToReportedCell(
                surface, surfaceKey: surfaceKey, col: wheel.col, row: wheel.row)
            // One incoming report must re-encode as exactly ONE outgoing
            // report. The viewer's ghostty already applied
            // mouse-scroll-multiplier when it turned the physical wheel
            // tick into N reports; feeding a non-precision tick here would
            // multiply again (multiplier² ≈ 9 rows per physical tick,
            // observed live). The precision path (scroll_mods bit 0) takes
            // raw pixels with a default multiplier of 1, so one cell's
            // worth of pixels scrolls exactly one row.
            let cellSize = ghostty_surface_size(surface)
            let dy = wheel.dy * Double(max(cellSize.cell_height_px, 1))
            let dx = wheel.dx * Double(max(cellSize.cell_width_px, 1))
            ghostty_surface_mouse_scroll(surface, dx, dy, 1)
            #if DEBUG
            dlog("peer.input.sgr_wheel dx=\(dx) dy=\(dy) cell=\(wheel.col),\(wheel.row)")
            #endif
            i += wheel.consumed
            continue
        }

        // SGR mouse BUTTON / MOTION / RELEASE report (press / drag / release)
        // from the viewer. The wheel branch above already claimed wheel
        // reports; here we re-dispatch button and motion through the host
        // pane's REAL mouse state via ghostty_surface_mouse_button /
        // _mouse_pos — the same APIs the local mouse handlers use. The host
        // core re-encodes for the host app's actual mouse mode (1000/1002/1003
        // + SGR/legacy) or drops it when the app never enabled tracking,
        // identical to a local click/drag on the host pane. Without this,
        // click/motion/release fell through to the drop branch below — the
        // reason peer viewers could scroll but never select/drag in claude/vim.
        if byte == 0x1b, let m = peerSgrButtonReport(arr, start: i) {
            movePeerMouseToReportedCell(
                surface, surfaceKey: surfaceKey, col: m.col, row: m.row)
            // Motion reports carry no button transition: the pos warp above is
            // enough — with a button still held from an earlier press, the host
            // core emits the drag-motion report itself. Press/release forward a
            // real button event (skip the no-button pure-motion case).
            if !m.motion, let button = m.button {
                _ = ghostty_surface_mouse_button(
                    surface,
                    m.press ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE,
                    button,
                    m.mods)
            }
            #if DEBUG
            dlog("peer.input.sgr_button press=\(m.press) motion=\(m.motion) cell=\(m.col),\(m.row)")
            #endif
            i += m.consumed
            continue
        }

        // Unrecognized CSI/OSC/SS3/SS2: DROP silently.
        //
        // Sending via sendPeerKeyEvent(text: ESC…) is broken for two reasons:
        //   1. ghostty_surface_key re-encodes the leading ESC byte (kitty mode
        //      → `\e[27u`, legacy → a separate PTY ESC write), corrupting the
        //      next-hop CSI parser and leaving bracketed-paste markers as
        //      literal visible characters in claude/codex/vim.
        //   2. ghostty_surface_text auto-wraps with bracketed-paste markers
        //      when the destination surface has bracketed-paste mode on —
        //      also wrong for arbitrary escape sequences.
        // Drop is the least-bad option until a verbatim-byte-injection API
        // exists in Ghostty. Bracketed-paste bodies are handled by the
        // peerPendingPasteBody path BEFORE this point and are never dropped.
        if byte == 0x1b,
           let consumed = peerEscapeSequenceLength(arr, start: i),
           consumed > 1 {
            i += consumed
            continue
        }

        if let mapping = peerSingleByteKeyMapping(byte) {
            sendPeerKeyEvent(surface, keycode: mapping.keycode, mods: mapping.mods, text: mapping.text)
            i += 1
            continue
        }

        if let kc = peerCtrlLetterKeycode(byte) {
            sendPeerCtrlLetterKey(surface, keycode: kc, byte: byte)
            i += 1
            continue
        }

        // Printable / UTF-8 path. Batch runs of consecutive printable
        // bytes (no escape, no mapped single byte, no Ctrl+letter)
        // into one ghostty_surface_key call rather than firing one
        // event per scalar. Pasting a 10KB chunk of plain text used
        // to walk the renderer state machine ~10000 times; with the
        // batch path it's ~one call per `tokTypeKeyInput` frame
        // sent by the relay.
        let runStart = i
        while i < processCount {
            let bb = arr[i]
            if bb == 0x1b { break }
            if peerSingleByteKeyMapping(bb) != nil { break }
            if peerCtrlLetterKeycode(bb) != nil { break }
            i += 1
        }
        if i > runStart {
            let chunkBytes = Array(arr[runStart..<i])
            if let str = String(bytes: chunkBytes, encoding: .utf8), !str.isEmpty {
                sendPeerKeyEvent(surface, keycode: 0, text: str)
            } else {
                // UTF-8 decode failed mid-paste (rare for typed input
                // but possible if a continuation byte was split
                // across two protocol frames). Fall back to per-scalar
                // best-effort recovery so partial bytes don't get
                // silently dropped.
                for j in runStart..<i {
                    sendPeerKeyEvent(surface, keycode: 0, text: String(UnicodeScalar(arr[j])))
                }
            }
        } else {
            // Defensive: shouldn't happen because at least one of the
            // earlier branches would have matched. Avoid an infinite
            // loop on a degenerate byte by advancing one position.
            i += 1
        }
    }
}

/// Special single bytes that map to a named macOS keycode.
private func peerSingleByteKeyMapping(_ byte: UInt8) -> (keycode: UInt32, mods: ghostty_input_mods_e, text: String)? {
    switch byte {
    // CR → unmodified Return (submit). The host surface's kitty-mode key
    // encoder turns this into a bare \r.
    case 0x0d:        return (36, GHOSTTY_MODS_NONE, "\r")   // kVK_Return
    // LF → Shift+Return (insert newline). The peer-relay binary translates a
    // kitty `CSI 13;2u` (shift+enter) into a bare LF; replaying it as a plain
    // Return would submit instead of inserting a newline. Synthesizing
    // Shift+Return lets the host's kitty-mode encoder regenerate `CSI 13;2u`,
    // which Claude/codex/jupyter interpret as a literal newline. See
    // term-mesh-peer-relay translate_terminal_csi_input (shift+enter → LF).
    case 0x0a:        return (36, GHOSTTY_MODS_SHIFT, "\r")  // kVK_Return + Shift
    case 0x09:        return (0x30, GHOSTTY_MODS_NONE, "\t")    // kVK_Tab
    case 0x7f, 0x08:  return (0x33, GHOSTTY_MODS_NONE, "\u{7f}")// kVK_Delete (Backspace)
    case 0x1b:        return (0x35, GHOSTTY_MODS_NONE, "\u{1b}")// kVK_Escape
    default:          return nil
    }
}

/// Map a Ctrl+letter control byte (0x01-0x1A, excluding bytes already
/// claimed by `peerSingleByteKeyMapping`) to its `kVK_ANSI_*` keycode.
private func peerCtrlLetterKeycode(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 0x01: return 0x00 // Ctrl-A → kVK_ANSI_A
    case 0x02: return 0x0B // Ctrl-B → kVK_ANSI_B
    case 0x03: return 0x08 // Ctrl-C → kVK_ANSI_C
    case 0x04: return 0x02 // Ctrl-D → kVK_ANSI_D
    case 0x05: return 0x0E // Ctrl-E → kVK_ANSI_E
    case 0x06: return 0x03 // Ctrl-F → kVK_ANSI_F
    case 0x07: return 0x05 // Ctrl-G → kVK_ANSI_G
    // 0x08 BS, 0x09 Tab, 0x0a LF — handled above
    case 0x0B: return 0x28 // Ctrl-K → kVK_ANSI_K
    case 0x0C: return 0x25 // Ctrl-L → kVK_ANSI_L
    // 0x0d CR — handled above
    case 0x0E: return 0x2D // Ctrl-N → kVK_ANSI_N
    case 0x0F: return 0x1F // Ctrl-O → kVK_ANSI_O
    case 0x10: return 0x23 // Ctrl-P → kVK_ANSI_P
    case 0x11: return 0x0C // Ctrl-Q → kVK_ANSI_Q
    case 0x12: return 0x0F // Ctrl-R → kVK_ANSI_R
    case 0x13: return 0x01 // Ctrl-S → kVK_ANSI_S
    case 0x14: return 0x11 // Ctrl-T → kVK_ANSI_T
    case 0x15: return 0x20 // Ctrl-U → kVK_ANSI_U
    case 0x16: return 0x09 // Ctrl-V → kVK_ANSI_V
    case 0x17: return 0x0D // Ctrl-W → kVK_ANSI_W
    case 0x18: return 0x07 // Ctrl-X → kVK_ANSI_X
    case 0x19: return 0x10 // Ctrl-Y → kVK_ANSI_Y
    case 0x1A: return 0x06 // Ctrl-Z → kVK_ANSI_Z
    // 0x1b Esc — handled above
    default:   return nil
    }
}

private func peerEscapeKeySequence(
    _ bytes: [UInt8],
    start: Int
) -> (keycode: UInt32, mods: ghostty_input_mods_e, consumed: Int)? {
    guard start + 2 < bytes.count, bytes[start] == 0x1b else { return nil }
    switch bytes[start + 1] {
    case 0x5b: // '[' — CSI
        return peerCsiKeySequence(bytes, start: start)
    case 0x4f: // 'O' — SS3, commonly F1-F4 and Home/End.
        guard let keycode = peerSs3Keycode(bytes[start + 2]) else { return nil }
        return (keycode, GHOSTTY_MODS_NONE, 3)
    default:
        return nil
    }
}

/// Length in bytes of a well-formed ESC-introduced control sequence that
/// begins at `start`. Returns nil when the sequence is incomplete or
/// malformed. Recognized shapes:
///   * CSI:  `\e[` parameters (0x20-0x3F) terminated by 0x40-0x7E
///   * OSC:  `\e]` body terminated by BEL (0x07) or ESC `\` (ST)
///   * SS3:  `\eO` + one final byte (3 bytes total)
/// Used to forward bracketed-paste markers and other unrecognized escape
/// sequences as a single contiguous text payload instead of splitting
/// them across a lone-ESC key event and a printable body.
private func peerEscapeSequenceLength(_ bytes: [UInt8], start: Int) -> Int? {
    guard start + 1 < bytes.count, bytes[start] == 0x1b else { return nil }
    switch bytes[start + 1] {
    case 0x5b: // '[' — CSI
        var i = start + 2
        while i < bytes.count {
            let b = bytes[i]
            if (0x40...0x7e).contains(b) {
                return i - start + 1
            }
            if !(0x20...0x3f).contains(b) {
                return nil
            }
            i += 1
        }
        return nil
    case 0x5d: // ']' — OSC
        var i = start + 2
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x07 {
                return i - start + 1
            }
            if b == 0x1b, i + 1 < bytes.count, bytes[i + 1] == 0x5c {
                return i - start + 2
            }
            i += 1
        }
        return nil
    case 0x4f: // 'O' — SS3
        guard start + 2 < bytes.count else { return nil }
        return 3
    default:
        return nil
    }
}

/// Parse an SGR mouse WHEEL report (`\e[<Pb;Px;PyM`, the DECSET 1006
/// encoding the attach-time mode replay advertises) beginning at `start`.
/// Returns the consumed byte count plus one non-precision scroll tick for
/// `ghostty_surface_mouse_scroll` — +y wheel-up / -y wheel-down and ±x for
/// the horizontal pair, mirroring Surface.zig's four/five/six/seven encode
/// directions so a report round-trips through the host at 1:1 speed.
/// Non-wheel reports (click, motion — wheel bit 0x40 clear or motion bit
/// 0x20 set), releases (`m`; wheels are press-only), and malformed or
/// frame-split sequences return nil: the caller's generic unrecognized-CSI
/// drop keeps consuming those, and FIX B's tail deferral reassembles the
/// split heads before this parser ever sees them.
private func peerSgrWheelReport(
    _ bytes: [UInt8],
    start: Int
) -> (dx: Double, dy: Double, col: Int, row: Int, consumed: Int)? {
    guard start + 2 < bytes.count,
          bytes[start] == 0x1b,
          bytes[start + 1] == 0x5b, // '['
          bytes[start + 2] == 0x3c  // '<'
    else { return nil }
    var i = start + 3
    var params: [Int] = []
    var current = 0
    var hasDigit = false
    while i < bytes.count, params.count < 3 {
        let b = bytes[i]
        switch b {
        case 0x30...0x39:
            current = current * 10 + Int(b - 0x30)
            guard current <= 0xFFFF else { return nil }
            hasDigit = true
        case 0x3b: // ';'
            guard hasDigit else { return nil }
            params.append(current)
            current = 0
            hasDigit = false
        case 0x4d: // 'M' — press-type report
            guard hasDigit else { return nil }
            params.append(current)
            guard params.count == 3 else { return nil }
            let btn = params[0]
            guard btn & 0x40 != 0, btn & 0x20 == 0 else { return nil }
            let consumed = i - start + 1
            let col = params[1]
            let row = params[2]
            switch btn & 0x03 {
            case 0:  return (0, 1, col, row, consumed)  // wheel up    (button four)
            case 1:  return (0, -1, col, row, consumed) // wheel down  (button five)
            case 2:  return (1, 0, col, row, consumed)  // wheel left  (button six)
            default: return (-1, 0, col, row, consumed) // wheel right (button seven)
            }
        default:
            return nil
        }
        i += 1
    }
    return nil
}

/// Warp the host surface's cursor position to the center of the 1-based
/// cell a viewer's SGR wheel report named, expressed in the surface view's
/// point coordinates (top-left origin — the same convention the local
/// mouse handlers use via `bounds.height - point.y`). Clamped into the
/// view so an out-of-range report still lands inside the viewport. Best
/// effort: when the surface is no longer registered (detached mid-frame)
/// the warp is skipped and the report may be dropped by the encoder's
/// out-of-viewport guard — the pre-fix behavior.
@MainActor
private func movePeerMouseToReportedCell(
    _ surface: ghostty_surface_t,
    surfaceKey: UInt,
    col: Int,
    row: Int
) {
    let size = ghostty_surface_size(surface)
    guard size.width_px > 0, size.height_px > 0,
          size.cell_width_px > 0, size.cell_height_px > 0 else { return }
    // ghostty_surface_mouse_pos takes view POINTS (the embedded apprt
    // multiplies by the content scale on the way in), but a peer-attached
    // pane can be a background tab whose view has no laid-out bounds, so
    // derive points from the surface's own pixel dimensions and the
    // display scale instead of the view frame. Same-source consistency:
    // the app feeds ghostty_surface_set_content_scale from the identical
    // window/screen backingScaleFactor chain.
    let window = peerSurfaceRefForKey[surfaceKey]?.value?.hostedView.window
    let scale = max(
        1.0,
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    )
    let cellW = CGFloat(size.cell_width_px) / scale
    let cellH = CGFloat(size.cell_height_px) / scale
    let maxX = CGFloat(size.width_px) / scale - 1
    let maxY = CGFloat(size.height_px) / scale - 1
    let x = min(max((CGFloat(col) - 0.5) * cellW, 0), maxX)
    let y = min(max((CGFloat(row) - 0.5) * cellH, 0), maxY)
    ghostty_surface_mouse_pos(surface, Double(x), Double(y), GHOSTTY_MODS_NONE)
}

/// Parse an SGR mouse BUTTON / MOTION / RELEASE report (`\e[<Pb;Px;Py` + `M`
/// press-or-motion / `m` release, DECSET 1006). Wheel reports (Pb bit 0x40)
/// are excluded — `peerSgrWheelReport` owns those. Returns the button (nil for
/// a no-button pure-motion report, Pb low bits == 3), whether this is a motion
/// report (Pb bit 0x20), the press/release state, the 1-based cell, decoded key
/// modifiers (Pb bits 0x04/0x08/0x10 → Shift/Alt/Ctrl), and the consumed byte
/// count. Malformed / frame-split sequences return nil (the caller's generic
/// unrecognized-CSI drop consumes those; FIX B reassembles split heads before
/// this parser sees them).
private func peerSgrButtonReport(
    _ bytes: [UInt8],
    start: Int
) -> (press: Bool, motion: Bool, button: ghostty_input_mouse_button_e?,
      col: Int, row: Int, mods: ghostty_input_mods_e, consumed: Int)? {
    guard start + 2 < bytes.count,
          bytes[start] == 0x1b,
          bytes[start + 1] == 0x5b, // '['
          bytes[start + 2] == 0x3c  // '<'
    else { return nil }
    var i = start + 3
    var params: [Int] = []
    var current = 0
    var hasDigit = false
    while i < bytes.count, params.count < 3 {
        let b = bytes[i]
        switch b {
        case 0x30...0x39:
            current = current * 10 + Int(b - 0x30)
            guard current <= 0xFFFF else { return nil }
            hasDigit = true
        case 0x3b: // ';'
            guard hasDigit else { return nil }
            params.append(current)
            current = 0
            hasDigit = false
        case 0x4d, 0x6d: // 'M' press/motion, 'm' release
            guard hasDigit else { return nil }
            params.append(current)
            guard params.count == 3 else { return nil }
            let pb = params[0]
            guard pb & 0x40 == 0 else { return nil } // wheel → peerSgrWheelReport
            let button: ghostty_input_mouse_button_e?
            switch pb & 0x03 {
            case 0:  button = GHOSTTY_MOUSE_LEFT
            case 1:  button = GHOSTTY_MOUSE_MIDDLE
            case 2:  button = GHOSTTY_MOUSE_RIGHT
            default: button = nil // 3 = no button held (pure motion / mode 1003)
            }
            var rawMods = GHOSTTY_MODS_NONE.rawValue
            if (pb & 0x04) != 0 { rawMods |= GHOSTTY_MODS_SHIFT.rawValue }
            if (pb & 0x08) != 0 { rawMods |= GHOSTTY_MODS_ALT.rawValue }
            if (pb & 0x10) != 0 { rawMods |= GHOSTTY_MODS_CTRL.rawValue }
            return (
                press: b == 0x4d,
                motion: (pb & 0x20) != 0,
                button: button,
                col: params[1],
                row: params[2],
                mods: ghostty_input_mods_e(rawValue: rawMods),
                consumed: i - start + 1
            )
        default:
            return nil
        }
        i += 1
    }
    return nil
}

private func peerCsiKeySequence(
    _ bytes: [UInt8],
    start: Int
) -> (keycode: UInt32, mods: ghostty_input_mods_e, consumed: Int)? {
    let bodyStart = start + 2
    var finalIndex = bodyStart
    while finalIndex < bytes.count {
        let byte = bytes[finalIndex]
        if (0x40...0x7e).contains(byte) { break }
        finalIndex += 1
    }
    guard finalIndex < bytes.count else { return nil }

    let final = bytes[finalIndex]
    let params = peerCsiParams(Array(bytes[bodyStart..<finalIndex]))
    let keycode: UInt32?
    let modifierParam: Int?

    switch final {
    case 0x41, 0x42, 0x43, 0x44, 0x48, 0x46: // A/B/C/D/H/F
        keycode = peerCsiFinalKeycode(final)
        modifierParam = params.dropFirst().first
    case 0x5a: // 'Z' — CBT / back-tab (Shift+Tab). Bare `\e[Z` carries an
               // implicit Shift; OR in any explicit `1;mod` param modifier.
        // Without this the sequence fell through to the unrecognized-CSI drop,
        // so Shift+Tab never reached the host pane (menus/vim/claude reverse
        // navigation was dead over the relay).
        let extra = peerCsiModifier(params.dropFirst().first).rawValue
        let mods = ghostty_input_mods_e(rawValue: extra | GHOSTTY_MODS_SHIFT.rawValue)
        return (0x30, mods, finalIndex - start + 1) // kVK_Tab + Shift
    case 0x75: // 'u' — kitty keyboard protocol: CSI codepoint[:alt];mods[:event] u
        // Modified keys the relay leaves untranslated (Alt+<key>, kitty-form
        // Shift+Tab `9;2u`, Shift+<key> in report-all mode) reach here verbatim
        // and used to hit the unrecognized-CSI drop. Map the codepoint to a
        // keycode and the kitty modifier flags to ghostty mods so the host
        // pane's own encoder regenerates the right sequence for its mode.
        // Unmappable codepoints fall through to the drop branch (no regression).
        guard let ev = peerKittyUKeyEvent(bytes, bodyStart: bodyStart, finalIndex: finalIndex) else {
            return nil
        }
        return (ev.keycode, ev.mods, finalIndex - start + 1)
    case 0x7e: // '~'
        guard let first = params.first else { return nil }
        keycode = peerCsiTildeKeycode(first)
        modifierParam = params.dropFirst().first
    default:
        return nil
    }

    guard let keycode else { return nil }
    return (keycode, peerCsiModifier(modifierParam), finalIndex - start + 1)
}

/// Parse a kitty keyboard-protocol key report body (`codepoint[:alt];mods[:event]`)
/// into a (keycode, mods) key event for the subset we can faithfully replay:
/// control keys, ASCII letters, digits, space. The relay already translates the
/// common unmodified control keys and Ctrl+letter to legacy bytes; what reaches
/// here is mainly Alt/Shift-modified keys and kitty-form Shift+Tab. Key-release
/// events (kitty event type 3) and unmappable codepoints return nil (dropped —
/// no worse than the pre-fix behaviour). Release events are already stripped by
/// the relay, but the event-type guard keeps this correct if that ever changes.
private func peerKittyUKeyEvent(
    _ bytes: [UInt8],
    bodyStart: Int,
    finalIndex: Int
) -> (keycode: UInt32, mods: ghostty_input_mods_e)? {
    guard bodyStart < finalIndex else { return nil }
    let body = Array(bytes[bodyStart..<finalIndex])
    let sections = body.split(separator: 0x3b, omittingEmptySubsequences: false).map(Array.init)
    guard let cpSection = sections.first else { return nil }
    // codepoint = digits before an optional `:alternate` sub-parameter.
    let cpDigits = cpSection.split(separator: 0x3a, omittingEmptySubsequences: false)
        .first.map(Array.init) ?? cpSection
    guard let cp = peerParseDigits(cpDigits) else { return nil }
    var modValue = 1
    if sections.count > 1 {
        let sub = sections[1].split(separator: 0x3a, omittingEmptySubsequences: false).map(Array.init)
        if let m = sub.first, let mv = peerParseDigits(m) { modValue = mv }
        if sub.count > 1, peerParseDigits(sub[1]) == 3 {
            return nil // key-release event: not a press
        }
    }
    guard let keycode = peerKittyCodepointKeycode(cp) else { return nil }
    return (keycode, peerCsiModifier(modValue))
}

/// Digits-only parse of a CSI parameter slice. nil for empty / non-digit.
/// Accumulate one ASCII digit into a base-10 value, rejecting overflow.
/// These parsers run on CSI/kitty sequences the remote host controls, so a
/// crafted long-digit field would otherwise trap Swift's checked Int
/// arithmetic and crash the app (untrusted-input DoS). Returns nil on a
/// non-digit byte or on overflow.
private func peerAppendDigit(_ value: Int, _ byte: UInt8) -> Int? {
    guard byte >= 0x30, byte <= 0x39 else { return nil }
    let (product, mulOverflow) = value.multipliedReportingOverflow(by: 10)
    guard !mulOverflow else { return nil }
    let (sum, addOverflow) = product.addingReportingOverflow(Int(byte - 0x30))
    return addOverflow ? nil : sum
}

private func peerParseDigits(_ bytes: [UInt8]) -> Int? {
    guard !bytes.isEmpty else { return nil }
    var value = 0
    for b in bytes {
        guard let next = peerAppendDigit(value, b) else { return nil }
        value = next
    }
    return value
}

/// Map a kitty codepoint to its macOS virtual keycode for the replayable
/// subset (control keys, digits, ASCII letters). Returns nil for anything else.
private func peerKittyCodepointKeycode(_ cp: Int) -> UInt32? {
    switch cp {
    case 9:    return 0x30 // Tab
    case 13:   return 0x24 // Return
    case 27:   return 0x35 // Escape
    case 32:   return 0x31 // Space
    case 127:  return 0x33 // Delete (Backspace)
    case 0x30: return 0x1D // 0
    case 0x31: return 0x12 // 1
    case 0x32: return 0x13 // 2
    case 0x33: return 0x14 // 3
    case 0x34: return 0x15 // 4
    case 0x35: return 0x17 // 5
    case 0x36: return 0x16 // 6
    case 0x37: return 0x1A // 7
    case 0x38: return 0x1C // 8
    case 0x39: return 0x19 // 9
    case 0x41...0x5a: return peerLetterKeycode(cp + 0x20) // A-Z → lowercase
    case 0x61...0x7a: return peerLetterKeycode(cp)        // a-z
    default:   return nil
    }
}

/// ASCII lowercase-letter codepoint → kVK_ANSI_* keycode.
private func peerLetterKeycode(_ cp: Int) -> UInt32? {
    switch cp {
    case 0x61: return 0x00 // a
    case 0x62: return 0x0B // b
    case 0x63: return 0x08 // c
    case 0x64: return 0x02 // d
    case 0x65: return 0x0E // e
    case 0x66: return 0x03 // f
    case 0x67: return 0x05 // g
    case 0x68: return 0x04 // h
    case 0x69: return 0x22 // i
    case 0x6a: return 0x26 // j
    case 0x6b: return 0x28 // k
    case 0x6c: return 0x25 // l
    case 0x6d: return 0x2E // m
    case 0x6e: return 0x2D // n
    case 0x6f: return 0x1F // o
    case 0x70: return 0x23 // p
    case 0x71: return 0x0C // q
    case 0x72: return 0x0F // r
    case 0x73: return 0x01 // s
    case 0x74: return 0x11 // t
    case 0x75: return 0x20 // u
    case 0x76: return 0x09 // v
    case 0x77: return 0x0D // w
    case 0x78: return 0x07 // x
    case 0x79: return 0x10 // y
    case 0x7a: return 0x06 // z
    default:   return nil
    }
}

private func peerCsiParams(_ body: [UInt8]) -> [Int] {
    guard !body.isEmpty else { return [] }
    return body.split(separator: 0x3b, omittingEmptySubsequences: false).compactMap { part in
        guard !part.isEmpty else { return nil }
        var value = 0
        for byte in part {
            guard let next = peerAppendDigit(value, byte) else { return nil }
            value = next
        }
        return value
    }
}

private func peerCsiModifier(_ encoded: Int?) -> ghostty_input_mods_e {
    guard let encoded, encoded > 1 else { return GHOSTTY_MODS_NONE }
    let flags = encoded - 1
    var raw = GHOSTTY_MODS_NONE.rawValue
    if (flags & 0b001) != 0 { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if (flags & 0b010) != 0 { raw |= GHOSTTY_MODS_ALT.rawValue }
    if (flags & 0b100) != 0 { raw |= GHOSTTY_MODS_CTRL.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
}

private func peerCsiFinalKeycode(_ final: UInt8) -> UInt32? {
    switch final {
    case 0x41: return 0x7e // Up
    case 0x42: return 0x7d // Down
    case 0x43: return 0x7c // Right
    case 0x44: return 0x7b // Left
    case 0x48: return 0x73 // Home
    case 0x46: return 0x77 // End
    default:   return nil
    }
}

private func peerSs3Keycode(_ final: UInt8) -> UInt32? {
    switch final {
    case 0x41: return 0x7e // Up
    case 0x42: return 0x7d // Down
    case 0x43: return 0x7c // Right
    case 0x44: return 0x7b // Left
    case 0x48: return 0x73 // Home
    case 0x46: return 0x77 // End
    case 0x50: return 0x7a // F1
    case 0x51: return 0x78 // F2
    case 0x52: return 0x63 // F3
    case 0x53: return 0x76 // F4
    default:   return nil
    }
}

private func peerCsiTildeKeycode(_ value: Int) -> UInt32? {
    switch value {
    case 1, 7: return 0x73 // Home
    case 2:    return 0x72 // Insert / Help
    case 3:    return 0x75 // Forward Delete
    case 4, 8: return 0x77 // End
    case 5:    return 0x74 // Page Up
    case 6:    return 0x79 // Page Down
    case 11:   return 0x7a // F1
    case 12:   return 0x78 // F2
    case 13:   return 0x63 // F3
    case 14:   return 0x76 // F4
    case 15:   return 0x60 // F5
    case 17:   return 0x61 // F6
    case 18:   return 0x62 // F7
    case 19:   return 0x64 // F8
    case 20:   return 0x65 // F9
    case 21:   return 0x6d // F10
    case 23:   return 0x67 // F11
    case 24:   return 0x6f // F12
    default:   return nil
    }
}

/// Number of bytes in the UTF-8 sequence whose lead byte is `byte`.
/// Returns 1 for ASCII and for stray continuation bytes.
private func peerUtf8Len(_ byte: UInt8) -> Int {
    if byte < 0x80 { return 1 }
    if byte < 0xC0 { return 1 }
    if byte < 0xE0 { return 2 }
    if byte < 0xF0 { return 3 }
    return 4
}

@MainActor
private func sendPeerKeyEvent(
    _ surface: ghostty_surface_t,
    keycode: UInt32,
    mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
    text: String?
) {
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = GHOSTTY_ACTION_PRESS
    keyEvent.keycode = keycode
    keyEvent.mods = mods
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = 0
    keyEvent.composing = false
    if let text {
        text.withCString { ptr in
            keyEvent.text = ptr
            _ = ghostty_surface_key(surface, keyEvent)
        }
    } else {
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
    }
    keyEvent.action = GHOSTTY_ACTION_RELEASE
    keyEvent.text = nil
    _ = ghostty_surface_key(surface, keyEvent)
}

@MainActor
private func sendPeerCtrlLetterKey(_ surface: ghostty_surface_t, keycode: UInt32, byte: UInt8) {
    // Don't send text for Ctrl+key combos — keycode + mods +
    // unshifted_codepoint are enough for Ghostty's KeyEncoder. Adding
    // the raw control byte as text triggers Kitty-protocol double
    // encoding that leaks CSI-u sequences (e.g. "9;5u") as visible
    // text. Mirrors the de5df7d fix in GhosttyTerminalView's Ctrl
    // fast path.
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = GHOSTTY_ACTION_PRESS
    keyEvent.keycode = keycode
    keyEvent.mods = GHOSTTY_MODS_CTRL
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = UInt32(byte) + 0x60 // 0x03 → 'c'
    keyEvent.composing = false
    keyEvent.text = nil
    _ = ghostty_surface_key(surface, keyEvent)

    keyEvent.action = GHOSTTY_ACTION_RELEASE
    _ = ghostty_surface_key(surface, keyEvent)
}

/// Read the current viewport text via ghostty_surface_read_text and
/// wrap it in an ANSI clear+home prefix so the attaching client sees
/// the host's current screen instead of a blank canvas.
@MainActor
private func readPaneSnapshot(_ surface: ghostty_surface_t) -> Data? {
    let topLeft = ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0, y: 0
    )
    let bottomRight = ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0, y: 0
    )
    let selection = ghostty_selection_s(
        top_left: topLeft,
        bottom_right: bottomRight,
        rectangle: true
    )
    var out = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
    defer { ghostty_surface_free_text(surface, &out) }
    guard let ptr = out.text, out.text_len > 0 else { return nil }

    let raw = Data(bytes: ptr, count: Int(out.text_len))
    // Convert bare LFs to CR+LF so each line lands on column 0 in the
    // remote terminal emulator. Already-CRLF input is left untouched.
    var body = Data()
    body.reserveCapacity(raw.count + 16)
    var prev: UInt8 = 0
    for b in raw {
        if b == 0x0a && prev != 0x0d {
            body.append(0x0d)
        }
        body.append(b)
        prev = b
    }

    var snapshot = Data()
    snapshot.append(contentsOf: [0x1b, 0x5b, 0x32, 0x4a]) // ESC [ 2 J — clear screen
    snapshot.append(contentsOf: [0x1b, 0x5b, 0x48])       // ESC [ H   — cursor home
    snapshot.append(body)
    return snapshot
}

/// Recreates the source pane's default terminal colors before replaying its
/// cells into a relay viewer. Most terminal cells use the default palette,
/// while TUIs such as Codex paint selected surfaces with an explicit color.
/// Without this prefix a dark viewer resolves the default cells locally but
/// preserves the host's explicit light composer color, producing a mixed
/// light/dark screen.
func peerTerminalPalettePrefix(foreground: NSColor, background: NSColor) -> Data {
    func oscRGB(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func component(_ value: CGFloat) -> String {
            let byte = min(255, max(0, Int((value * 255).rounded())))
            return String(format: "%02x%02x", byte, byte)
        }

        return "rgb:\(component(rgb.redComponent))/\(component(rgb.greenComponent))/\(component(rgb.blueComponent))"
    }

    let sequence =
        "\u{1b}]10;\(oscRGB(foreground))\u{7}" +
        "\u{1b}]11;\(oscRGB(background))\u{7}"
    return Data(sequence.utf8)
}

private func surfaceIDBytes(_ id: UUID) -> Data {
    withUnsafeBytes(of: id.uuid) { Data($0) }
}

private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
