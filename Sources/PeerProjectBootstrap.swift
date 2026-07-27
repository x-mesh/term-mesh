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
    enum DeletionError: LocalizedError {
        case unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .unsafePath(let path):
                return "Refusing to delete unsafe remote path: \(path)"
            }
        }
    }

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
            if plan.agentCheckouts.contains(where: { $0.path != plan.primaryPath }) {
                // A brand-new project has no repository to clone yet. Make
                // the primary directory the repository instead of attempting
                // `git clone <plain folder>`, which fails and used to leave
                // every advertised checkout as an unrelated empty directory.
                //
                // Do not silently turn an existing folder with files into a
                // repository: cloning it would omit every untracked file and
                // give agents checkouts that look valid but contain none of
                // the project.
                steps.append(
                    "(git -C \(primary) rev-parse --git-dir >/dev/null 2>&1 "
                        + "|| (test -z \"$(find \(primary) -mindepth 1 -maxdepth 1 "
                        + "-print -quit)\" && git -C \(primary) init))"
                )
            }
        }
        for checkout in plan.agentCheckouts where checkout.path != plan.primaryPath {
            let path = quote(checkout.path)
            steps.append(
                "(git -C \(path) rev-parse --git-dir >/dev/null 2>&1 "
                    + "|| git clone \(primary) \(path))"
            )
            if !checkout.branch.isEmpty {
                let branch = quote(checkout.branch)
                steps.append(
                    "(git -C \(path) switch \(branch) 2>/dev/null "
                        + "|| git -C \(path) switch -c \(branch))"
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

    /// Build the one destructive command in the project lifecycle.
    ///
    /// Only absolute, specific paths are accepted. A project root must have
    /// at least two components below `/` (`/tmp/project`, `/app/projects`, …);
    /// broad roots and relative paths never reach `rm`.
    static func deletionScript(paths: [String]) throws -> String {
        let safePaths = try Array(Set(paths)).sorted().map { path -> String in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let standardized = (trimmed as NSString).standardizingPath
            let components = standardized.split(separator: "/")
            guard trimmed.hasPrefix("/"),
                  standardized.hasPrefix("/"),
                  standardized != "/",
                  components.count >= 2
            else {
                throw DeletionError.unsafePath(path)
            }
            return standardized
        }
        guard !safePaths.isEmpty else { throw DeletionError.unsafePath("") }
        return "rm -rf -- " + safePaths.map(quote).joined(separator: " ")
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
    /// The machine that owns the leader pane.  This is deliberately distinct
    /// from `ProjectSource.hostKey`: a project can live on one peer while its
    /// leader is local, or the leader can be on another connected peer.
    ///
    /// Keeping the endpoint in the project request means later bootstrap
    /// stages never need to infer locality from a pane UUID (which is only
    /// unique within its creating host).
    var endpoint: LeaderEndpoint = .local
}

/// A leader's address before (and after) it has a pane.  A remote pane ID is
/// not available when New Project is submitted, so host identity is the
/// durable part of the endpoint; the bootstrap protocol supplies its remote
/// surface reference later.
///
/// The explicit `.local` default is the migration path for every existing
/// in-memory/local team that predates peer-hosted leaders.
enum LeaderEndpoint: Hashable, Codable, Sendable {
    case local
    case peer(hostKey: String)

    private enum CodingKeys: String, CodingKey { case kind, hostKey }
    private enum Kind: String, Codable { case local, peer }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local
        case .peer:
            self = .peer(hostKey: try container.decode(String.self, forKey: .hostKey))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case let .peer(hostKey):
            try container.encode(Kind.peer, forKey: .kind)
            try container.encode(hostKey, forKey: .hostKey)
        }
    }

    var hostKey: String? {
        guard case let .peer(hostKey) = self else { return nil }
        return hostKey
    }
}

/// A surface owned by another peer.  A bare surface UUID is not enough here:
/// UUIDs are only unique inside the peer that created them, and using one as a
/// local pane identifier lets a relay pane accidentally be published again by
/// the next host it passes through.
struct RemoteRef: Hashable, Codable, Sendable {
    /// Stable peer identity, not an SSH target or a transient tunnel path.
    let hostPeerID: String
    let workspaceID: UUID
    /// nil means the remote workspace itself; a value addresses one leaf.
    let surfaceID: UUID?

    init(hostPeerID: String, workspaceID: UUID, surfaceID: UUID? = nil) {
        self.hostPeerID = hostPeerID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }
}

/// A UI selection can point at a local pane or an address in a peer's
/// namespace.  Keeping the two cases distinct prevents callers from dropping
/// the host component while forwarding a selection across a peer boundary.
enum SelectionTarget: Hashable, Sendable {
    case local(workspaceID: UUID, surfaceID: UUID)
    case remote(RemoteRef)

    var workspaceID: UUID {
        switch self {
        case let .local(workspaceID, _): workspaceID
        case let .remote(ref): ref.workspaceID
        }
    }

    var surfaceID: UUID? {
        switch self {
        case let .local(_, surfaceID): surfaceID
        case let .remote(ref): ref.surfaceID
        }
    }
}
