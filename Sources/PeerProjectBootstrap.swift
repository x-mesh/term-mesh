import Foundation

enum ProjectSourceKind: String, Codable, CaseIterable {
    case clone
    case existingFolder
    case empty
}

enum ProjectLocationSettings {
    static let localProjectsRootKey = "termMesh.localProjectsRoot"
    static let defaultLocalProjectsRoot = "~/work/project"

    static var localProjectsRoot: String {
        let saved = UserDefaults.standard.string(forKey: localProjectsRootKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultLocalProjectsRoot : saved
    }

    static func expandedLocalProjectsRoot() -> String {
        (localProjectsRoot as NSString).expandingTildeInPath
    }
}

/// Getting a project, and each agent's own copy of it, onto another machine.
///
/// Agents that share one checkout collide in every way that matters: they
/// overwrite each other's files, they are on one branch between them, and
/// their tool state — settings, caches, installed dependencies — is one set of
/// files with several writers.
///
/// Each agent gets a Git worktree. That gives every worker its own index,
/// branch and working files while downloading the repository only once.
/// Branch names and paths are unique even when a preset repeats a role.
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

    /// One machine/path participating in a project creation transaction.
    ///
    /// The source checkout, leader checkout and agent checkouts may live on
    /// different machines. Grouping them before any command runs lets the
    /// caller prepare every destination first and launch panes only after the
    /// whole filesystem transaction succeeds.
    struct Placement: Equatable {
        var hostKey: String?
        var projectPath: String
        var agentIndices: [Int]
        var includesLeader: Bool
        var isSource: Bool
    }

    enum PlacementError: LocalizedError, Equatable {
        case missingProjectPath(hostKey: String)

        var errorDescription: String? {
            switch self {
            case .missingProjectPath(let hostKey):
                return "Choose a project folder for \(hostKey)."
            }
        }
    }

    /// Resolve the source, leader and member choices into checkout groups.
    ///
    /// `additionalRemoteProjectPath` supplies the host convention for a peer
    /// that is not the Project machine. A row's explicit directory wins over
    /// that convention. Groups are keyed by both host and project path so two
    /// agents deliberately pointed at different copies on one host remain
    /// different transactions.
    static func placements(
        source: ProjectSource,
        rows: [TeamAgentRow],
        leaderHostKey: String?,
        localProjectsRoot: String,
        additionalRemoteProjectPath: (String) -> String?
    ) throws -> [Placement] {
        let projectName = URL(fileURLWithPath: source.projectPath).lastPathComponent
        var result: [Placement] = []

        func normalized(_ path: String) -> String {
            (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .standardizingPath
        }

        func path(
            for hostKey: String?,
            preferred: String? = nil
        ) throws -> String {
            if let preferred {
                let value = normalized(preferred)
                if !value.isEmpty && value != "." { return value }
            }
            if hostKey == source.hostKey {
                return normalized(source.projectPath)
            }
            if hostKey == nil {
                return normalized(
                    (localProjectsRoot as NSString).appendingPathComponent(projectName)
                )
            }
            guard let hostKey,
                  let predicted = additionalRemoteProjectPath(hostKey),
                  !normalized(predicted).isEmpty,
                  normalized(predicted) != "."
            else {
                throw PlacementError.missingProjectPath(hostKey: hostKey ?? "This Mac")
            }
            return normalized(predicted)
        }

        func merge(
            hostKey: String?,
            projectPath: String,
            agentIndex: Int? = nil,
            includesLeader: Bool = false,
            isSource: Bool = false
        ) {
            if let index = result.firstIndex(where: {
                $0.hostKey == hostKey && $0.projectPath == projectPath
            }) {
                if let agentIndex { result[index].agentIndices.append(agentIndex) }
                result[index].includesLeader = result[index].includesLeader || includesLeader
                result[index].isSource = result[index].isSource || isSource
                return
            }
            result.append(Placement(
                hostKey: hostKey,
                projectPath: projectPath,
                agentIndices: agentIndex.map { [$0] } ?? [],
                includesLeader: includesLeader,
                isSource: isSource
            ))
        }

        let sourcePath = try path(for: source.hostKey, preferred: source.projectPath)
        merge(
            hostKey: source.hostKey,
            projectPath: sourcePath,
            includesLeader: leaderHostKey == source.hostKey,
            isSource: true
        )

        for (index, row) in rows.enumerated() {
            let projectPath = try path(
                for: row.hostKey,
                preferred: row.hostDirectory
            )
            merge(
                hostKey: row.hostKey,
                projectPath: projectPath,
                agentIndex: index
            )
        }

        if leaderHostKey != source.hostKey {
            merge(
                hostKey: leaderHostKey,
                projectPath: try path(for: leaderHostKey),
                includesLeader: true
            )
        }
        return result
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
        var occurrences: [String: Int] = [:]
        return Plan(
            primaryPath: primary,
            agentCheckouts: agents.map { agent in
                let count = (occurrences[agent] ?? 0) + 1
                occurrences[agent] = count
                let suffix = count == 1 ? agent : "\(agent)-\(count)"
                return (
                    agent: agent,
                    path: (root as NSString).appendingPathComponent("\(projectName)-\(suffix)"),
                    branch: "agent/\(suffix)"
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
    static func script(
        for plan: Plan,
        gitURL: String?,
        sourceKind: ProjectSourceKind = .clone
    ) -> String? {
        var steps: [String] = []
        let primary = quote(plan.primaryPath)
        if let gitURL, !gitURL.isEmpty {
            steps.append(
                "test -d \(primary)/.git || "
                    + "GIT_SSH_COMMAND=\(quote(nonInteractiveGitSSHCommand)) "
                    + "git clone \(quote(gitURL)) \(primary)"
            )
        } else {
            if sourceKind == .existingFolder {
                // "Existing" is a promise, not a request to create a missing
                // directory. Failing here keeps the sheet open with a useful
                // error instead of launching panes whose `cd` already failed.
                steps.append("test -d \(primary)")
            } else {
                steps.append("mkdir -p \(primary)")
            }
            if sourceKind == .empty {
                steps.append(
                    "git -C \(primary) rev-parse --git-dir >/dev/null 2>&1 "
                        + "|| git -C \(primary) init"
                )
                steps.append(
                    "git -C \(primary) rev-parse --verify HEAD >/dev/null 2>&1 "
                        + "|| git -C \(primary) -c user.name=term-mesh "
                        + "-c user.email=term-mesh@local commit --allow-empty -m 'Initial commit'"
                )
            } else if plan.agentCheckouts.contains(where: { $0.path != plan.primaryPath }) {
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
            let branch = quote(checkout.branch)
            steps.append(
                "(git -C \(path) rev-parse --git-dir >/dev/null 2>&1 "
                    + "|| (git -C \(primary) show-ref --verify --quiet refs/heads/\(branch) "
                    + "&& git -C \(primary) worktree add \(path) \(branch) "
                    + "|| git -C \(primary) worktree add -b \(branch) \(path) HEAD))"
                )
        }
        guard steps.count > 1
                || gitURL?.isEmpty == false
                || sourceKind == .existingFolder
        else { return nil }
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
        sourceKind: ProjectSourceKind = .clone,
        timeoutSeconds: TimeInterval = 300
    ) async throws {
        guard let script = script(for: plan, gitURL: gitURL, sourceKind: sourceKind) else { return }
        try await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: port,
            identityFile: identityFile,
            script: script,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func runLocal(
        plan: Plan,
        gitURL: String?,
        sourceKind: ProjectSourceKind,
        timeoutSeconds: TimeInterval = 300
    ) async throws {
        guard let script = script(
            for: plan, gitURL: gitURL, sourceKind: sourceKind
        ) else { return }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-lc", script]
                let errorPipe = Pipe()
                process.standardError = errorPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(throwing: ProjectBootstrapError.timedOut)
                    return
                }
                guard process.terminationStatus == 0 else {
                    let data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let message = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(
                        throwing: ProjectBootstrapError.commandFailed(
                            message.isEmpty ? "git exited with \(process.terminationStatus)" : message
                        )
                    )
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    enum ProjectBootstrapError: LocalizedError {
        case timedOut
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Project setup timed out."
            case .commandFailed(let message):
                return "Project setup failed: \(message)"
            }
        }
    }

    /// Turn common remote Git failures into a next action instead of exposing
    /// SSH's multi-line diagnostic verbatim in the project sheet.
    static func remoteFailureDescription(_ error: Error, gitURL: String?) -> String {
        let detail = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = detail.lowercased()
        let repository = gitURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if lowercased.contains("permission denied (publickey)") {
            return repository.isEmpty
                ? "SSH authentication failed. Add an SSH key on this machine, then try again."
                : "Git SSH authentication failed. Add an SSH key with access to this repository on this machine, then try again."
        }
        if lowercased.contains("repository not found") {
            return "The repository was not found or this machine does not have access to it."
        }
        if lowercased.contains("host key verification failed")
            || lowercased.contains("authenticity of host") {
            return "The Git host identity could not be verified. Check this machine's SSH known_hosts entry, then try again."
        }
        if lowercased.contains("could not resolve host")
            || lowercased.contains("temporary failure in name resolution") {
            return "This machine could not reach the Git host. Check its network and DNS settings."
        }
        if lowercased.contains("timed out") {
            return "Project setup timed out on this machine. Check its network connection, then try again."
        }
        return detail.isEmpty ? "Project setup failed on this machine." : detail
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

    /// A project sheet cannot answer an SSH prompt hidden inside a remote
    /// `git clone`. Trust a host only on first sight, reject changed keys, and
    /// fail immediately when credentials need interaction.
    private static let nonInteractiveGitSSHCommand =
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
}

/// Where a project comes from and how its members are laid out, as the
/// creation form describes it.
struct ProjectSource: Equatable {
    var kind: ProjectSourceKind
    /// The peer it lives on, or nil for this machine.
    var hostKey: String?
    /// The project's directory on that machine.
    var projectPath: String
    /// A repository to clone if the project is not there yet. Empty means the
    /// directory is expected to be, or to become, whatever the agents make it.
    var gitURL: String
    /// Whether each member gets its own checkout.
    var isolateAgents: Bool

    init(
        hostKey: String?,
        projectPath: String,
        gitURL: String,
        isolateAgents: Bool,
        kind: ProjectSourceKind? = nil
    ) {
        self.kind = kind ?? (gitURL.isEmpty ? .empty : .clone)
        self.hostKey = hostKey
        self.projectPath = projectPath
        self.gitURL = gitURL
        self.isolateAgents = isolateAgents
    }
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
