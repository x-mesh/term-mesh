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
    /// Complete workspace-roster snapshots pushed after a client subscribes.
    /// This replaces sidebar process/socket polling while preserving a single
    /// authoritative source for additions, removals, and layout metadata.
    public static let workspaceListSubscribeV1 = "workspace.list.subscribe.v1"
    /// Deterministic daemon-owned surface reconciliation via
    /// `EnsureSurfaceRequest`/`EnsureSurfaceResponse`.
    public static let surfaceEnsureV1 = "surface.ensure.v1"
    /// Exact ensured-surface termination via
    /// `TerminateSurfaceRequest`/`TerminateSurfaceResponse`.
    public static let surfaceTerminateV1 = "surface.terminate.v1"
    /// `HostStats` pushes — load, memory, disk and network rates for the
    /// machine hosting the panes. Advertised by the side that WANTS them,
    /// so a host sends them only to a client that asked. Mirrors
    /// `HOST_STATS_V1` on the Rust side.
    public static let hostStatsV1 = "host.stats.v1"
    /// The typed fresh-attach screen keyframe (`GridSnapshot.ansi`).
    /// Client-advertised: a host that sees it sends the fresh-attach
    /// screen as a `GridSnapshot` envelope instead of untyped `PtyData`,
    /// which lets this client clear stale local scrollback and reset its
    /// wire-gap baseline. Mirrors `GRID_SNAPSHOT_V1` on the Rust side.
    public static let gridSnapshotV1 = "grid.snapshot.v1"
    /// Authenticated host-reported directories containing bundled CLIs.
    public static let hostCLIBinDirsV1 = "host.cli-bin-dirs.v1"

    /// The host answers `ListTeams` with the agent teams it runs. Advertised
    /// by the HOST — only a host with a team manager can answer, and a team
    /// is not derivable from the layout tree.
    public static let teamRosterV1 = "team.roster.v1"

    /// The host runs allow-listed `team.*` methods on behalf of a client.
    /// Advertised by the HOST. Unlike the roster, this CHANGES things, so
    /// the allow-list — not the capability — is what bounds it.
    public static let teamCallV1 = "team.call.v1"
    /// Project-bound remote leader bootstrap with scoped, expiring grants.
    /// This is separate from `team.call.v1` so its lifecycle exception cannot
    /// widen that generic allow-list.
    public static let teamLeaderV1 = "team.leader.v1"

    /// Every capability this build supports. Single source of truth for
    /// populating outgoing `Hello.capabilities` — don't hand-roll the list
    /// at each call site.
    public static let supported: [String] = [ptyDataCoalesceV1, replayRingV1, workspaceLifecycleV1, workspaceListSubscribeV1, surfaceEnsureV1, surfaceTerminateV1, hostStatsV1, gridSnapshotV1, hostCLIBinDirsV1, teamRosterV1, teamCallV1, teamLeaderV1]
}

/// Strict validation for host-controlled Hello.cli_bin_dirs. Invalid input
/// disables this optional hint; it never aborts an otherwise valid session.
public enum PeerHostCLIBinDirs {
    public static let maximumCount = 2
    public static let maximumUTF8Bytes = 4096

    public static func validated(_ candidates: [String]) -> [String] {
        guard candidates.count <= maximumCount else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            guard candidate.utf8.count <= maximumUTF8Bytes, isSafe(candidate) else { return [] }
            let standardized = "/" + candidate
                .split(separator: "/", omittingEmptySubsequences: true)
                .joined(separator: "/")
            guard isSafe(standardized) else { return [] }
            if seen.insert(standardized).inserted { result.append(standardized) }
        }
        return result
    }

    private static func isSafe(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.isEmpty else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return false
        }
        let forbidden = Set<Character>(":~$*?[]{}\"")
        guard !path.contains(where: forbidden.contains) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(".") && !components.contains("..")
    }
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
