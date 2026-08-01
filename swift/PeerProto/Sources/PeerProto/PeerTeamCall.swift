import Foundation

/// What a peer is allowed to ask a host to run on its teams.
///
/// This is the security boundary of `team.call.v1`, and it is an allow-list
/// on purpose: proxying arbitrary `team.*` methods would hand a peer the
/// host's entire team surface, including the parts that create teams, spawn
/// processes and name filesystem paths. Everything listed here acts INSIDE a
/// team the host already owns, which is the difference between "drive the
/// agents on that machine" and "run whatever you like on that machine".
///
/// Adding a method here is a security decision, not a convenience one: ask
/// whether a peer holding it could reach outside the team.
///
/// What the list deliberately does NOT say is WHICH team. A peer names the
/// team in its own request and the host resolves it as given, so this bounds
/// what a peer may do without bounding whose team it does it to. That is
/// sound only because a peer is always another machine the same person owns:
/// the caller is their own viewer app, driven by hand, so it is treated as
/// equivalent to the local control socket. `team.leader.v1` scopes its caller
/// to a single team with a registered grant precisely because that caller is
/// an autonomous process rather than a person — the difference between the
/// two designs is the caller, not an oversight in this one.
///
/// Revisit the day a peer can be someone else's machine. The four directing
/// methods and the two task-writing ones would then need restricting to teams
/// the connection has already attached a surface for; the reads can stay.
public enum PeerTeamCall {
    public static let allowedMethods: Set<String> = [
        // Reads — the team's own state.
        "team.status",
        "team.list",
        "team.read",
        "team.collect",
        "team.reports",
        "team.result.status",
        "team.result.collect",
        "team.inbox",
        "team.message.list",
        // Directing agents that already exist.
        "team.send",
        "team.broadcast",
        "team.delegate",
        "team.message.post",
        // Task board bookkeeping, all scoped to the team.
        "team.task.list",
        "team.task.get",
        "team.task.create",
        "team.task.update",
        "team.task.done",
        "team.task.block",
        "team.task.review",
        "team.task.unblock",
        "team.task.approve",
        // Reading what a task changed, so a review can happen where the work
        // is visible rather than only where it ran.
        //
        // This is the one method here that reaches the filesystem, so it is
        // worth saying exactly how far: the host resolves the worktree from
        // the task row the peer names — the peer supplies no path, no ref and
        // no command — and runs a fixed read against it. There is no argument
        // through which a caller can choose what runs or where, which is the
        // line between this and the spawning methods below that stay out.
        //
        // It reads a working tree the same person's agent is writing, which
        // the reads above already do by another route (`team.read` returns
        // that agent's pane). The new exposure is the diff's content, not a
        // new machine or a new directory.
        "team.task.diff",
    ]

    /// Deliberately NOT allowed, kept explicit so the reasoning survives:
    /// `team.create` / `team.destroy` / `team.attach` / `team.detach` /
    /// `team.add_agent` / `team.restart` — these spawn or tear down
    /// processes and take a working directory, so a peer holding them could
    /// start an arbitrary command anywhere on the host.
    public static func isAllowed(_ method: String) -> Bool {
        allowedMethods.contains(method)
    }

    public enum ErrorCode {
        public static let methodNotAllowed = "method_not_allowed"
        public static let invalidParams = "invalid_params"
        public static let hostError = "host_error"
    }
}
