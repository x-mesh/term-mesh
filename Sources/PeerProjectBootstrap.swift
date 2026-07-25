import Foundation

/// Getting a project, and each agent's own copy of it, onto another machine.
///
/// Agents that share one checkout collide in every way that matters: they
/// overwrite each other's files, they are on one branch between them, and
/// their tool state — settings, caches, installed dependencies — is one set of
/// files with several writers.
///
/// A git worktree is the usual answer and is the wrong one here. Worktrees
/// share `.git`, so two agents cannot both start from `main`, and the refs and
/// object store they share become a lock others are waiting on — agents run
/// git constantly, and the contention surfaces as work that fails now and then
/// for no visible reason. A clone shares nothing: its own refs, its own index,
/// its own config and hooks. On a machine with disk, that is simpler and it is
/// the isolation actually being asked for.
///
/// Cloned from the primary copy on the same machine rather than from the
/// remote: credentials and the network are needed once, for the project, and
/// never again for a member. Deliberately not `--shared` or `--reference` —
/// borrowing another repository's objects means a `gc` over there can break a
/// clone over here, and disk is cheaper than that failure.
enum PeerProjectBootstrap {
    struct Plan: Equatable {
        /// The project's own copy, `<root>/<name>`.
        var primaryPath: String
        /// Per agent, the directory it works in and the branch it starts on.
        var agentCheckouts: [(agent: String, path: String, branch: String)]

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.primaryPath == rhs.primaryPath
                && lhs.agentCheckouts.map(\.path) == rhs.agentCheckouts.map(\.path)
                && lhs.agentCheckouts.map(\.branch) == rhs.agentCheckouts.map(\.branch)
        }
    }

    /// Where everything goes, without touching the machine.
    ///
    /// Separated from doing it so the paths can be shown before anything is
    /// created, and asserted in a test without an ssh connection.
    static func plan(
        projectRoot: String,
        projectName: String,
        agents: [String],
        isolateAgents: Bool
    ) -> Plan {
        let root = (projectRoot as NSString).standardizingPath
        let primary = (root as NSString).appendingPathComponent(projectName)
        guard isolateAgents else {
            // Everyone in the project's own copy. Honest when the work is
            // sequential or read-only, and the collision above when it is not.
            return Plan(
                primaryPath: primary,
                agentCheckouts: agents.map { (agent: $0, path: primary, branch: "") }
            )
        }
        return Plan(
            primaryPath: primary,
            agentCheckouts: agents.map { agent in
                (
                    agent: agent,
                    path: (root as NSString).appendingPathComponent("\(projectName)-\(agent)"),
                    branch: "agent/\(agent)"
                )
            }
        )
    }

    /// The shell script that realises a plan, or nil when there is nothing to
    /// do because the project is a plain directory with no isolation asked for.
    ///
    /// Every step is conditional on its result not already being there, so
    /// running it twice is running it once. The `||` on the branch switch is
    /// deliberate: an agent's branch surviving from a previous run is the
    /// normal case on the second visit, not a failure.
    static func script(for plan: Plan, gitURL: String?) -> String? {
        var steps: [String] = []
        let primary = quote(plan.primaryPath)
        if let gitURL, !gitURL.isEmpty {
            steps.append(
                "test -d \(primary)/.git || git clone \(quote(gitURL)) \(primary)"
            )
        } else {
            steps.append("mkdir -p \(primary)")
        }
        for checkout in plan.agentCheckouts where checkout.path != plan.primaryPath {
            let path = quote(checkout.path)
            steps.append(
                "test -d \(path)/.git || git clone \(primary) \(path)"
            )
            if !checkout.branch.isEmpty {
                let branch = quote(checkout.branch)
                steps.append(
                    "git -C \(path) switch \(branch) 2>/dev/null "
                        + "|| git -C \(path) switch -c \(branch)"
                )
            }
        }
        guard steps.count > 1 || gitURL?.isEmpty == false else { return nil }
        return steps.joined(separator: " && ")
    }

    /// Carry out the plan on the host.
    ///
    /// Over ssh rather than through the pane: this has to finish before the
    /// agents start, and a shell that is also a terminal someone is watching
    /// is not a place to wait for a clone.
    static func run(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        plan: Plan,
        gitURL: String?,
        timeoutSeconds: TimeInterval = 300
    ) async throws {
        guard let script = script(for: plan, gitURL: gitURL) else { return }
        try await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: port,
            identityFile: identityFile,
            script: script,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where a project comes from and how its members are laid out, as the
/// creation form describes it.
struct ProjectSource: Equatable {
    /// The peer it lives on, or nil for this machine.
    var hostKey: String?
    /// The project's directory on that machine.
    var projectPath: String
    /// A repository to clone if the project is not there yet. Empty means the
    /// directory is expected to be, or to become, whatever the agents make it.
    var gitURL: String
    /// Whether each member gets its own checkout.
    var isolateAgents: Bool
}

/// What runs the project's leader pane.
///
/// `mode` is an agent CLI name (`claude`, `codex`, …) or `repl` for the manual
/// console. `model` is meaningless for `repl` and ignored there.
struct ProjectLeader: Equatable {
    var mode: String
    var model: String
}
