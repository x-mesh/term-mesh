import CryptoKit
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

    /// A per-creation suffix for agent checkouts: the date it happened and
    /// enough randomness to never repeat.
    ///
    /// Without it, every run of the same project names the same directories
    /// (`demo-executor`), and the idempotent bootstrap script happily adopts
    /// whatever already sits at that path — a previous run's leftovers, or an
    /// unrelated folder that merely has a `.git`. A checkout is an agent
    /// instance's temporary station, so its name carries the instance, not
    /// just the role. One tag per creation transaction, shared by every
    /// machine in it: retries of the same plan stay idempotent, distinct
    /// creations never collide.
    static func makeInstanceTag(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let random = (0..<4).map { _ in
            "0123456789abcdef".randomElement().map(String.init) ?? "0"
        }.joined()
        return "\(formatter.string(from: now))-\(random)"
    }

    /// Where everything goes, without touching the machine.
    ///
    /// Separated from doing it so the paths can be shown before anything is
    /// created, and asserted in a test without an ssh connection.
    ///
    /// `instanceTag` (see `makeInstanceTag`) suffixes every agent checkout
    /// and branch. nil keeps the legacy role-only names — for previews and
    /// tests; real creations should always pass one.
    static func plan(
        projectRoot: String,
        projectName: String,
        agents: [String],
        isolateAgents: Bool,
        instanceTag: String? = nil
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
                var suffix = count == 1 ? agent : "\(agent)-\(count)"
                if let instanceTag, !instanceTag.isEmpty {
                    suffix = "\(suffix)-\(instanceTag)"
                }
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
        sourceKind: ProjectSourceKind = .clone,
        memMeshProjectID: String? = nil
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
        if plan.agentCheckouts.contains(where: { $0.path != plan.primaryPath }) {
            // Hygiene before adding more: reclaim the registrations of agent
            // worktrees whose directories are already gone (reaped on agent
            // detach, or deleted by hand). Without it they accumulate in
            // `.git/worktrees` forever — each creation makes new ones now
            // that checkout names carry an instance tag.
            steps.append("git -C \(primary) worktree prune 2>/dev/null || true")
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
        // Appended after the guard on purpose: a project that needed no setup
        // still needs none, and there is no repository to name yet either.
        if let memMeshProjectID, !memMeshProjectID.isEmpty {
            steps.append(memMeshIdentityStep(primary: primary, projectID: memMeshProjectID))
        }
        return steps.joined(separator: " && ")
    }

    /// Why this Repository URL cannot work, or nil when it can (or when it
    /// is empty — emptiness is the caller's decision, not a URL defect).
    ///
    /// Exists because the form used to accept anything and the first thing to
    /// object was `git clone` on a machine at the other end of ssh — a pasted
    /// chat block with a URL somewhere inside it produced
    /// `fatal: protocol 'available skills\n https' is not supported`, on the
    /// one machine that did not already have the clone. The form is where the
    /// mistake happened; the form is where it should be caught.
    static func repositoryURLProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: \.isNewline) {
            return "Repository URL is several lines — paste just the URL."
        }
        if trimmed.contains(where: \.isWhitespace) {
            return "Repository URL cannot contain spaces."
        }
        // The shapes git actually accepts: scheme://…, scp-like user@host:path
        // (a colon before any slash), or a filesystem path.
        if let schemeEnd = trimmed.range(of: "://") {
            let scheme = trimmed[trimmed.startIndex..<schemeEnd.lowerBound]
            let validScheme = !scheme.isEmpty && scheme.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
            }
            return validScheme ? nil : "\"\(scheme)\" is not a URL scheme."
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") {
            return nil
        }
        if let colon = trimmed.firstIndex(of: ":"),
           trimmed.startIndex < colon,
           !trimmed[trimmed.startIndex..<colon].contains("/") {
            return nil
        }
        return "Not a git URL — expected https://…, git@host:path, or a path."
    }

    /// The project id mem-mesh should answer with on every machine holding a
    /// copy of this project.
    ///
    /// mem-mesh reads `git config --local mem-mesh.project-id` before falling
    /// back to the checkout's directory name, and a repository's local config
    /// is shared by all of its worktrees. Writing the name once at creation
    /// therefore gives the project one identity across its own worktrees and
    /// across every host term-mesh sets up — each host is written on that
    /// host, with git alone, so a machine receiving a project needs no
    /// mem-mesh installation to agree with the one that sent it. A clone taken
    /// outside term-mesh still gets nothing: `--local` config is not carried
    /// by clone, fetch or push.
    ///
    /// Without this, every copy falls back to its own directory name: the same
    /// project is `demo` here and `demo-executor` in an agent's worktree, and
    /// memories written from one are invisible to a search scoped to the other.
    ///
    /// mem-mesh's charset is `^[a-zA-Z0-9_-]{1,100}$`, which many real names do
    /// not survive — every Korean name reduces to whatever ASCII sits beside
    /// it, so `결제-api` and `인증-api` would both be `api` and share one
    /// namespace. When the slug loses something the name carried, a digest of
    /// the name as typed is appended: readable while it can be, distinct once
    /// it cannot. A name with nothing usable in it is pinned from the digest
    /// alone rather than left unpinned, because unpinned is the per-directory
    /// drift this exists to prevent.
    static func memMeshProjectID(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Lowercased to match the repo's other slugs (`AgentRolePreset.slugify`,
        // `teamNameCandidate`), so one project is not `My-App` to mem-mesh and
        // `my-app` to its own team.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        var lostCharacters = false
        let mapped = String(trimmed.lowercased().map { character -> Character in
            if allowed.contains(character) { return character }
            // Whitespace is how people separate words, not information the id
            // drops. Everything else the charset cannot render is a real loss.
            if !character.isWhitespace { lostCharacters = true }
            return "-"
        })
        let slug = mapped
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        guard lostCharacters || slug.count > 100 else { return slug }

        let digest = SHA256.hash(data: Data(trimmed.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        // Trimmed after bounding, not before: cutting a collapsed slug at 100
        // can land on the separator the collapse just removed.
        let head = String(slug.prefix(100 - digest.count - 1))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return head.isEmpty ? digest : "\(head)-\(digest)"
    }

    /// Pin the identity on the project's own repository, once.
    ///
    /// Three properties have to hold together:
    ///
    /// - Failing to name a project must not fail the project. Files in place
    ///   without a pinned name is the better of the two outcomes.
    /// - That fallback must not reach the steps before it. `script` joins every
    ///   step with `&&`, and `A && B || true` parses as `(A && B) || true`, so
    ///   an unscoped `|| true` would report a failed clone as a success. Hence
    ///   the subshell — the same shape the worktree steps already use.
    /// - It must write to this project's repository and no other. `rev-parse
    ///   --git-dir` succeeds from any descendant, so a project folder created
    ///   inside somebody else's checkout would otherwise rename that checkout.
    ///   Comparing toplevel to project path is what separates the two, and both
    ///   sides are resolved because git reports a physical path while the
    ///   caller's may not be (`/var` vs `/private/var` on macOS).
    private static func memMeshIdentityStep(primary: String, projectID: String) -> String {
        "( top=$(git -C \(primary) rev-parse --show-toplevel 2>/dev/null) "
            + "&& here=$(cd \(primary) 2>/dev/null && pwd -P) "
            + "&& [ -n \"$top\" ] && [ \"$top\" = \"$here\" ] "
            + "&& { git -C \(primary) config --local --get mem-mesh.project-id >/dev/null 2>&1 "
            + "|| git -C \(primary) config --local mem-mesh.project-id \(quote(projectID)); } "
            + "|| true )"
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
        // Deliberately not defaulted: `nil` and "the caller forgot" would
        // otherwise be the same value, and a forgotten id is permanent —
        // nothing rewrites a pin once the project exists.
        memMeshProjectID: String?,
        // The host profile's variables — a clone behind a proxy needs them
        // as much as the agent that follows does.
        environment: [String: String] = [:],
        timeoutSeconds: TimeInterval = 300
    ) async throws {
        guard let script = script(
            for: plan,
            gitURL: gitURL,
            sourceKind: sourceKind,
            memMeshProjectID: memMeshProjectID
        ) else { return }
        let assignments = PeerHostEnvironment.inlineAssignments(environment)
        let prefixed = assignments.isEmpty
            ? script
            : "export \(assignments) && \(script)"
        try await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: port,
            identityFile: identityFile,
            script: prefixed,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func runLocal(
        plan: Plan,
        gitURL: String?,
        sourceKind: ProjectSourceKind,
        // See `run` — not defaulted, for the same reason.
        memMeshProjectID: String?,
        timeoutSeconds: TimeInterval = 300
    ) async throws {
        guard let script = script(
            for: plan,
            gitURL: gitURL,
            sourceKind: sourceKind,
            memMeshProjectID: memMeshProjectID
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
        let safePaths = try Array(Set(paths)).sorted().map(validatedDeletablePath)
        guard !safePaths.isEmpty else { throw DeletionError.unsafePath("") }
        return "rm -rf -- " + safePaths.map(quote).joined(separator: " ")
    }

    private static func validatedDeletablePath(_ path: String) throws -> String {
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

    /// Remove a detached agent's checkout, but only when git itself proves
    /// it is disposable.
    ///
    /// An instance-tagged checkout has exactly one occupant, ever — nothing
    /// will come back for it — so leaving it behind on detach turns every
    /// removed agent into garbage on someone else's disk. The guards are
    /// structural rather than bookkept: the directory must be a LINKED
    /// worktree (`--git-dir` differs from `--git-common-dir`; a primary
    /// checkout fails this and is never touched), and `status --porcelain`
    /// must be empty (uncommitted work keeps the directory, with committed
    /// work already safe in the `agent/…` branch either way). Anything the
    /// probes cannot prove — not a repo, git too old, permissions — is left
    /// alone; a false "keep" costs a directory, a false "reap" costs work.
    static func reapWorktreeScript(path: String) throws -> String {
        let safe = quote(try validatedDeletablePath(path))
        return """
        WT=\(safe)
        if [ -e "$WT/.git" ]; then
          GD=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)
          CD=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
          if [ -n "$GD" ] && [ -n "$CD" ] && [ "$GD" != "$CD" ] \
             && [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
            rm -rf -- "$WT" && git --git-dir "$CD" worktree prune 2>/dev/null || true
          fi
        fi
        """
    }

    /// `reapWorktreeScript` over ssh, as a best effort: the agent is already
    /// gone either way, and a machine that cannot be reached right now keeps
    /// the directory until the next creation's `worktree prune` or the
    /// project's deletion.
    static func reapWorktree(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        path: String,
        timeoutSeconds: TimeInterval = 60
    ) async {
        guard let script = try? reapWorktreeScript(path: path) else { return }
        _ = try? await PeerHostReadinessChecker.runScript(
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
