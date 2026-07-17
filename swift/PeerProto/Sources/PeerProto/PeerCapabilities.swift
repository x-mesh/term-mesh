//  Feature-flag strings a peer may advertise via `Hello.capabilities`
//  (`proto/peer/v1/peer.proto` Evolution rule 3). Mirrors
//  `daemon/peer-proto/src/lib.rs`'s `capability` module on the Rust side —
//  keep the two lists in sync.
//
//  This is plumbing only (see P3 in `docs/peer-perf-proposal.md`): nothing
//  in this codebase branches on a capability string yet. It exists so P8
//  and later wire changes have a real, already-round-tripped negotiation
//  channel to gate on instead of inventing one from scratch.

/// Namespace for the capability string constants this build advertises.
/// Not instantiable — use the static members directly (`PeerCapability.supported`).
public enum PeerCapability {
    /// PtyData broadcast coalescing (P7). Purely a sender-side batching
    /// change with no new wire shape, but advertised so a future receiver
    /// that cares about batch boundaries (e.g. a compressor, P8) can
    /// detect support for it.
    public static let ptyDataCoalesceV1 = "ptydata.coalesce.v1"
    /// Attach-time ANSI-preserving raw-byte replay ring (P4).
    public static let replayRingV1 = "replay.ring.v1"
    /// The host supports workspace-level lifecycle RPCs:
    /// `CreateWorkspaceRequest`/`Response`, `RenameWorkspaceRequest`,
    /// `DeleteWorkspaceRequest`, and the `WorkspaceRemoved` push (see
    /// `proto/peer/v1/peer.proto`'s "Workspace lifecycle" section).
    /// Mirrors `WORKSPACE_LIFECYCLE_V1` on the Rust side.
    public static let workspaceLifecycleV1 = "workspace.lifecycle.v1"
    /// Deterministic daemon-owned surface reconciliation via
    /// `EnsureSurfaceRequest`/`EnsureSurfaceResponse`.
    public static let surfaceEnsureV1 = "surface.ensure.v1"
    /// Exact ensured-surface termination via
    /// `TerminateSurfaceRequest`/`TerminateSurfaceResponse`.
    public static let surfaceTerminateV1 = "surface.terminate.v1"

    /// Every capability this build supports. Single source of truth for
    /// populating outgoing `Hello.capabilities` — don't hand-roll the list
    /// at each call site.
    public static let supported: [String] = [ptyDataCoalesceV1, replayRingV1, workspaceLifecycleV1, surfaceEnsureV1, surfaceTerminateV1]
}

/// The other side's advertised feature flags, parsed once out of its
/// `Hello.capabilities` and kept around for the life of a connection.
///
/// Unknown strings (a future peer advertising something this build
/// predates) are kept but never interpreted — only `has(_:)` gives them
/// meaning, and no current call site queries anything but the constants in
/// `PeerCapability`. Memory is bounded by the wire's own frame-size cap
/// (`MAX_FRAME_BYTES` on the Rust side / the framing layer's length
/// prefix), so no separate entry-count limit is applied here.
public struct PeerCapabilities: Sendable, Equatable {
    private let values: Set<String>

    public init(_ capabilities: [String] = []) {
        self.values = Set(capabilities)
    }

    /// Whether the peer that sent this `Hello` advertised `capability`.
    public func has(_ capability: String) -> Bool {
        values.contains(capability)
    }
}
