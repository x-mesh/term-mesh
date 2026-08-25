//  Feature-flag strings a peer may advertise via `Hello.capabilities`
//  (`proto/peer/v1/peer.proto` Evolution rule 3). Mirrors
//  `daemon/peer-proto/src/lib.rs`'s `capability` module on the Rust side —
//  keep the two lists in sync. "In sync" means the constants mirror; each
//  side's advertised `supported` list adds an entry only once that side
//  actually implements the behavior. `surfaceAgentV1` walked that path:
//  the daemon advertised it first (Phase 1), and this viewer joined
//  `PeerCapability.supported` only once it could render agent surfaces
//  (Phase 2, AgentPanel wiring).
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
    /// `EnsureSurfaceRequest.env` is validated and applied by the host.
    /// A client must not infer this from `surface.ensure.v1`: older hosts
    /// decode an unknown map field as empty and would silently launch an
    /// agent without its configured profile/identity environment.
    public static let surfaceEnsureEnvV1 = "surface.ensure-env.v1"
    /// Exact ensured-surface termination via
    /// `TerminateSurfaceRequest`/`TerminateSurfaceResponse`.
    public static let surfaceTerminateV1 = "surface.terminate.v1"
    /// Daemon-owned agent surfaces (`SurfaceInfo.surface_type == "agent"`):
    /// non-PTY `tm-agent-bridge` children whose byte stream is NDJSON
    /// events, not a terminal grid. Direction matters — a HOST advertises
    /// that it can create and attach agent-kind ensured surfaces; a CLIENT
    /// advertises that it can render them (AgentPanel). To a client that
    /// did not advertise this, a host lists agent surfaces as
    /// `attachable = false` and rejects attach attempts, so older viewers
    /// degrade for free through the existing `attachable` filter. Mirrors
    /// `SURFACE_AGENT_V1` on the Rust side.
    ///
    /// In `supported` since Phase 2 (viewer AgentPanel wiring):
    /// advertising tells hosts this build attaches agent surfaces as
    /// AgentPanels rather than opening them as broken terminal panes, so
    /// hosts now list them as attachable to this viewer. This build's
    /// CLIENT Hello carries it; the HOST direction does not — only the
    /// Rust daemon can host agent surfaces today, so `PeerServer` filters
    /// this string out of its own Hello (see its `advertisedCapabilities`)
    /// and rejects agent-kind EnsureSurface outright. That filter goes
    /// when the Mac host learns to host agent surfaces.
    public static let surfaceAgentV1 = "surface.agent.v1"
    /// Host-pushed terminal process status for an attached surface. The host
    /// sends `SurfaceExited` only after its final `PtyData`, allowing a viewer
    /// to finish the matching session without guessing from socket lifetime.
    /// Client-advertised: sending it opts this connection into the new push.
    public static let surfaceExitV1 = "surface.exit.v1"
    /// SurfaceInfo carries foreground-process liveness for terminal surfaces.
    public static let surfaceForegroundV1 = "surface.foreground.v1"
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
    public static let projectPresentationV1 = "project.presentation.v1"
    public static let projectPresentationRepairV1 = "project.presentation.repair.v1"
    public static let teamRouteFileV1 = "team.route-file.v1"

    /// Every capability this build supports. Single source of truth for
    /// populating outgoing `Hello.capabilities` — don't hand-roll the list
    /// at each call site.
    public static let supported: [String] = [ptyDataCoalesceV1, replayRingV1, workspaceLifecycleV1, workspaceListSubscribeV1, surfaceEnsureV1, surfaceEnsureEnvV1, surfaceTerminateV1, surfaceAgentV1, surfaceExitV1, surfaceForegroundV1, hostStatsV1, gridSnapshotV1, hostCLIBinDirsV1, teamRosterV1, teamCallV1, teamLeaderV1, projectPresentationV1, projectPresentationRepairV1, teamRouteFileV1]
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
