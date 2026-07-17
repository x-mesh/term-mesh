//  Client-side PtyData de-multiplexer for a shared PeerSession.
//
//  A workspace relay window used to open one PeerSession (+ NWConnection +
//  handshake) per pane. The host, however, already accepts many
//  AttachSurface calls on a single session and tags every PtyData frame
//  with its surface_id, so the panes of one workspace can share a single
//  authenticated session (the "narrow sharing" in the P1 proposal).
//
//  With sharing, exactly ONE receive loop reads the session's frames
//  (the workspace controller's subscription loop). That loop must not
//  hand a frame to the wrong pane, and it must not *drop* another pane's
//  frame while filtering for its own — a naive per-pane
//  `receiveNextMessage()` filter would do both (frames are consumed
//  destructively). This registry is the fan-out: the single loop calls
//  `route(surfaceID:byteSeq:payload:)` for each PtyData frame and this
//  type delivers it to the one consumer registered for that surface_id.
//
//  It is intentionally passive — it owns no receive loop of its own, so
//  there is never more than one reader on the shared session. That keeps
//  the existing single-session-per-pane path (the fallback) and the
//  disconnect/reconnect machinery untouched.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One host→client PTY output chunk for a single surface.
public struct PeerPtyChunk: Sendable, Equatable {
    public let byteSeq: UInt64
    public let payload: Data
    public init(byteSeq: UInt64, payload: Data) {
        self.byteSeq = byteSeq
        self.payload = payload
    }
}

/// Routes a shared session's PtyData frames to per-surface consumers.
///
/// Thread-safety: an `actor`, so `register` / `deregister` / `route` are
/// serialised. `route` is a hot path (called for every PtyData frame),
/// but it only performs a dictionary lookup + non-blocking `yield`, so it
/// never blocks the single receive loop.
public actor PeerSessionDemux {
    /// Backpressure policy mirrors the host-side `PtyTapHub`
    /// (`bufferingNewest(256)`): a slow pane drops its own oldest chunks
    /// under load rather than stalling the shared receive loop or growing
    /// without bound. The host keeps a 64KB replay ring, so a briefly
    /// stalled consumer recovers on the next attach rather than from this
    /// buffer.
    private static let perSurfaceBuffer = 256

    private var continuations: [Data: AsyncStream<PeerPtyChunk>.Continuation] = [:]

    /// Pending request/response RPCs share the same peer connection, but the
    /// daemon may complete them out of order.  Keep their continuations here
    /// rather than coupling completion order to wire order.
    private var ensureWaiters: [Data: AsyncThrowingStream<Termmesh_Peer_V1_EnsureSurfaceResponse, Error>.Continuation] = [:]

    /// Per-surface count of chunks dropped by the `bufferingNewest` policy
    /// (a slow pane whose relay is backed up). This is an app-side
    /// truncation source distinct from the host's broadcast `Lagged` drop;
    /// surfacing it makes the "heavy output → content truncated" half of
    /// the pane-close symptom measurable rather than silent.
    private var droppedCount: [Data: Int] = [:]

    /// Optional observer fired (rate-limited) when `route` drops a chunk.
    /// The app module sets this to a `dlog` closure; the demux itself stays
    /// logging-agnostic so it can live in the transport-only PeerProto lib.
    private var onDrop: (@Sendable (_ surfaceID: Data, _ totalDropped: Int) -> Void)?

    public init() {}

    func registerEnsure(
        requestID: Data
    ) throws -> AsyncThrowingStream<Termmesh_Peer_V1_EnsureSurfaceResponse, Error> {
        guard ensureWaiters[requestID] == nil else {
            throw PeerSessionError.duplicateEnsureRequestID
        }
        var captured: AsyncThrowingStream<Termmesh_Peer_V1_EnsureSurfaceResponse, Error>.Continuation!
        let stream = AsyncThrowingStream<Termmesh_Peer_V1_EnsureSurfaceResponse, Error> { continuation in
            captured = continuation
        }
        ensureWaiters[requestID] = captured
        return stream
    }

    /// Completes at most one waiter. Duplicate, late, and unknown responses
    /// are harmless no-ops because the continuation is removed before resume.
    func routeEnsureResponse(_ response: Termmesh_Peer_V1_EnsureSurfaceResponse) {
        guard response.requestID.count == 16 else {
            failAllEnsures(error: PeerSessionError.malformedEnsureResponse("request_id must be 16 bytes"))
            return
        }
        guard let continuation = ensureWaiters.removeValue(forKey: response.requestID) else {
            return
        }
        if let reason = Self.ensureResponseValidationError(response) {
            continuation.finish(throwing: PeerSessionError.malformedEnsureResponse(reason))
        } else {
            continuation.yield(response)
            continuation.finish()
        }
    }

    var pendingEnsureCount: Int { ensureWaiters.count }

    func failAllEnsures(error: Error) {
        let waiters = ensureWaiters.values
        ensureWaiters.removeAll()
        for continuation in waiters {
            continuation.finish(throwing: error)
        }
    }

    func failEnsure(requestID: Data, error: Error) {
        ensureWaiters.removeValue(forKey: requestID)?.finish(throwing: error)
    }

    func cancelEnsure(requestID: Data) {
        ensureWaiters.removeValue(forKey: requestID)?.finish(throwing: CancellationError())
    }

    private static func ensureResponseValidationError(
        _ response: Termmesh_Peer_V1_EnsureSurfaceResponse
    ) -> String? {
        switch response.result {
        case .created, .reused, .recreated:
            guard response.surfaceID.count == 16 else { return "surface_id must be 16 bytes" }
            guard response.instanceID.count == 16 else { return "instance_id must be 16 bytes" }
            guard response.specHash.count == 32 else { return "spec_hash must be 32 bytes" }
            guard !response.hasError else { return "successful response must not contain error" }
        case .specConflict, .failed:
            guard response.hasError else { return "failure response must contain error" }
            guard response.error.code != .unspecified else { return "failure error code must be specified" }
        case .unspecified, .UNRECOGNIZED:
            return "result must be recognized and specified"
        }
        return nil
    }

    /// Install the drop observer (see `onDrop`). Actor-isolated setter so
    /// the app can wire a `dlog` closure without exposing mutable state.
    public func setOnDrop(_ handler: @escaping @Sendable (_ surfaceID: Data, _ totalDropped: Int) -> Void) {
        onDrop = handler
    }

    /// Register a consumer for `surfaceID` and return its stream. Call
    /// this BEFORE issuing the AttachSurface RPC so the host's initial
    /// replay bytes are buffered rather than dropped. Registering an
    /// already-registered surface finishes the previous stream (a
    /// re-attach supersedes the stale consumer).
    public func register(surfaceID: Data) -> AsyncStream<PeerPtyChunk> {
        continuations[surfaceID]?.finish()
        var captured: AsyncStream<PeerPtyChunk>.Continuation!
        let stream = AsyncStream<PeerPtyChunk>(
            bufferingPolicy: .bufferingNewest(Self.perSurfaceBuffer)
        ) { continuation in
            captured = continuation
        }
        continuations[surfaceID] = captured
        return stream
    }

    /// Stop delivering to `surfaceID` and finish its stream so the
    /// consuming pump loop exits. Safe to call for an unknown surface.
    public func deregister(surfaceID: Data) {
        continuations.removeValue(forKey: surfaceID)?.finish()
    }

    /// Deliver one PtyData frame to the surface's consumer, or drop it if
    /// no consumer is (or is no longer) registered — a frame for a pane
    /// that detached is discarded here rather than leaking to a sibling.
    public func route(surfaceID: Data, byteSeq: UInt64, payload: Data) {
        guard let continuation = continuations[surfaceID] else { return }
        let result = continuation.yield(PeerPtyChunk(byteSeq: byteSeq, payload: payload))
        // `.bufferingNewest(256)` returns `.dropped(evictedOldest)` when the
        // consumer (this pane's hostToRelay pump) can't keep up. Count and
        // report it — this is silent content loss otherwise.
        if case .dropped = result {
            let n = (droppedCount[surfaceID] ?? 0) + 1
            droppedCount[surfaceID] = n
            if n == 1 || n % 128 == 0 {
                onDrop?(surfaceID, n)
            }
        }
    }

    /// Finish every stream (host went away / controller teardown) so all
    /// pane pump loops exit. The registry is left empty and reusable.
    public func finishAll() {
        for (_, continuation) in continuations {
            continuation.finish()
        }
        continuations.removeAll()
    }

    /// Count of live consumers — for diagnostics / tests only.
    public var registeredCount: Int { continuations.count }
}
