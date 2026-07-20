import Foundation

struct RemoteGitCheckpointResult: Sendable {
    let checkpoint: RemoteCheckpointRecord
    let changeset: IncomingChangeset
}

enum RemoteGitCheckpointError: LocalizedError, Equatable {
    case invalidTarget
    case invalidPath(String)
    case commandFailed(String)
    case malformedCheckpointResponse
    case staleBase
    case dirtyOrigin
    case changedCheckpoint

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "The remote pane is not connected through SSH."
        case .invalidPath(let path):
            return "The project path is not usable: \(path)"
        case .commandFailed(let message):
            return message
        case .malformedCheckpointResponse:
            return "The remote host returned an invalid checkpoint response."
        case .staleBase:
            return "Local origin changed after this remote run started. Validate a newer checkpoint."
        case .dirtyOrigin:
            return "Local origin has uncommitted changes. Commit or stash them before Apply All."
        case .changedCheckpoint:
            return "The fetched checkpoint no longer matches Incoming changes. Fetch it again."
        }
    }
}

protocol RemoteGitCheckpointServicing: Sendable {
    func seedProjectIfNeeded(
        sshTarget: String,
        remoteRoot: String,
        localOrigin: String
    ) async throws

    func checkpointAndFetch(
        paneID: RemotePaneID,
        projectBindingID: ProjectBindingID,
        sshTarget: String,
        remoteRoot: String,
        localOrigin: String,
        boundary: CheckpointBoundary
    ) async throws -> RemoteGitCheckpointResult

    func validate(_ changeset: IncomingChangeset, localOrigin: String) async throws
    func apply(_ changeset: IncomingChangeset, localOrigin: String) async throws
    func discard(_ changeset: IncomingChangeset, localOrigin: String) async throws
}

final class RemoteGitCheckpointService: RemoteGitCheckpointServicing, @unchecked Sendable {
    /// The steps `seedProjectIfNeeded` would take, in order, without taking
    /// them.
    ///
    /// Written from the same values the real call uses so the two cannot drift
    /// into describing different work. Preconditions are listed as steps
    /// because they are where this usually stops.
    nonisolated func seedPlan(sshTarget: String, remoteRoot: String, localOrigin: String) -> [String] {
        [
            "check local origin \(localOrigin) is a clean Git worktree",
            "read local HEAD (git -C \(localOrigin) rev-parse HEAD)",
            "ssh \(sshTarget): if \(remoteRoot) is a worktree, require its HEAD to equal that base",
            "ssh \(sshTarget): otherwise require \(remoteRoot) to be absent or empty, then git init -b term-mesh-base",
            "git push \(sshTarget):\(remoteRoot) HEAD:refs/heads/term-mesh-base (only when freshly initialised)",
            "verify the remote HEAD now equals the local base",
        ]
    }

    /// The steps `checkpointAndFetch` would take, in order, without taking them.
    nonisolated func checkpointPlan(sshTarget: String, remoteRoot: String, localOrigin: String) -> [String] {
        [
            "ssh \(sshTarget): commit the current state of \(remoteRoot) onto a fresh refs/term-mesh/checkpoints/<id>",
            "fetch that ref into refs/term-mesh/incoming/<id> in \(localOrigin)",
            "record the checkpoint so it appears under Incoming for review",
        ]
    }


    static let shared = RemoteGitCheckpointService()

    private let queue = DispatchQueue(label: "com.termmesh.remote-checkpoint", qos: .utility)
    private let applyCoordinator = OriginApplyCoordinator()

    func seedProjectIfNeeded(
        sshTarget: String,
        remoteRoot: String,
        localOrigin: String
    ) async throws {
        try Self.validateTarget(sshTarget)
        try Self.validateAbsolutePath(remoteRoot)
        try Self.validateAbsolutePath(localOrigin)
        try await requireCleanOrigin(localOrigin)
        let base = try await run("/usr/bin/git", ["-C", localOrigin, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isGitObjectID(base) else {
            throw RemoteGitCheckpointError.commandFailed("Local origin does not have a valid Git HEAD.")
        }

        let quotedRoot = Self.shellQuote(remoteRoot)
        let quotedBase = Self.shellQuote(base)
        // `--is-inside-work-tree` answers for the whole ancestry, so a bare
        // folder sitting anywhere under an unrelated repository claims to be
        // a worktree and sends us down the "compare its HEAD" path — where
        // git then fails on a revision that has nothing to do with us. Ask
        // whether the path is a repository ROOT instead, and say so plainly
        // when it is merely inside one.
        let remoteCommand = """
        set -eu
        root=\(quotedRoot)
        expected=\(quotedBase)
        toplevel=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
        if test -n "$toplevel"; then
          if test "$toplevel" != "$root"; then
            printf 'Remote path is inside another Git repository (%s), not a project of its own. Pick a path outside it, or remove that repository.\\n' "$toplevel" >&2
            exit 44
          fi
          actual=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
          if test -z "$actual"; then
            printf 'Remote Git repository at %s has no commits yet, so there is no base to match. Remove it and let this create one.\\n' "$root" >&2
            exit 45
          fi
          test "$actual" = "$expected" || { printf 'Remote HEAD %s does not match local base %s.\\n' "$actual" "$expected" >&2; exit 42; }
          printf 'existing\\n'
          exit 0
        fi
        if test -d "$root" && test -n "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"; then
          printf 'Remote project folder is not empty and is not a Git worktree.\\n' >&2
          exit 43
        fi
        mkdir -p "$root"
        git -C "$root" init -b term-mesh-base >/dev/null
        git -C "$root" config receive.denyCurrentBranch updateInstead
        printf 'initialized\\n'
        """
        let state = try await run("/usr/bin/ssh", [sshTarget, remoteCommand])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if state == "initialized" {
            _ = try await run(
                "/usr/bin/git",
                ["-C", localOrigin, "push", "\(sshTarget):\(remoteRoot)", "HEAD:refs/heads/term-mesh-base"]
            )
        }
        let remoteRevision = try await run(
            "/usr/bin/ssh",
            [sshTarget, "git -C \(Self.shellQuote(remoteRoot)) rev-parse HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteRevision == base else {
            throw RemoteGitCheckpointError.staleBase
        }
    }

    func checkpointAndFetch(
        paneID: RemotePaneID,
        projectBindingID: ProjectBindingID,
        sshTarget: String,
        remoteRoot: String,
        localOrigin: String,
        boundary: CheckpointBoundary
    ) async throws -> RemoteGitCheckpointResult {
        try Self.validateTarget(sshTarget)
        try Self.validateAbsolutePath(remoteRoot)
        try Self.validateAbsolutePath(localOrigin)

        let checkpointID = CheckpointID()
        let changesetID = ChangesetID()
        let suffix = checkpointID.rawValue.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let remoteRef = "refs/term-mesh/checkpoints/\(suffix)"
        let localRef = "refs/term-mesh/incoming/\(suffix)"
        let quotedRoot = Self.shellQuote(remoteRoot)
        let quotedRef = Self.shellQuote(remoteRef)
        let message = Self.shellQuote("term-mesh checkpoint \(suffix)")
        let remoteCommand = """
        set -eu
        root=\(quotedRoot)
        ref=\(quotedRef)
        # Root, not merely inside one: committing against an enclosing
        # repository would capture that repository's tree, not this project.
        toplevel=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
        if test "$toplevel" != "$root"; then
          if test -n "$toplevel"; then
            printf 'Remote path is inside another Git repository (%s), not a project of its own. Run Prepare Project first, or bind a path outside it.\\n' "$toplevel" >&2
          else
            printf 'Remote path %s is not a Git repository. Run Prepare Project first.\\n' "$root" >&2
          fi
          exit 44
        fi
        base=$(git -C "$root" rev-parse HEAD)
        git -C "$root" add -A
        tree=$(git -C "$root" write-tree)
        checkpoint=$(printf '%s\\n' \(message) | GIT_AUTHOR_NAME=term-mesh GIT_AUTHOR_EMAIL=checkpoint@term-mesh.local GIT_COMMITTER_NAME=term-mesh GIT_COMMITTER_EMAIL=checkpoint@term-mesh.local git -C "$root" commit-tree "$tree" -p "$base")
        git -C "$root" update-ref "$ref" "$checkpoint"
        printf '%s\\n%s\\n%s\\n' "$base" "$checkpoint" "$ref"
        """

        let response = try await run("/usr/bin/ssh", [sshTarget, remoteCommand])
        let lines = response.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard lines.count >= 3,
              Self.isGitObjectID(lines[0]),
              Self.isGitObjectID(lines[1]),
              lines[2] == remoteRef else {
            throw RemoteGitCheckpointError.malformedCheckpointResponse
        }
        let base = lines[0]
        let revision = lines[1]

        let remoteURL = "\(sshTarget):\(remoteRoot)"
        _ = try await run(
            "/usr/bin/git",
            ["-C", localOrigin, "fetch", "--no-tags", remoteURL, "\(remoteRef):\(localRef)"]
        )
        let changedPathsOutput = try await run(
            "/usr/bin/git",
            ["-C", localOrigin, "diff", "--name-only", base, revision]
        )
        let changedPaths = changedPathsOutput
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        let diffSummary = try await run(
            "/usr/bin/git",
            ["-C", localOrigin, "diff", "--stat", base, revision]
        )
        let now = Date()
        let checkpoint = RemoteCheckpointRecord(
            id: checkpointID,
            paneID: paneID,
            revision: revision,
            remoteRef: remoteRef,
            boundary: boundary,
            createdAt: now
        )
        let changeset = IncomingChangeset(
            id: changesetID,
            paneID: paneID,
            projectBindingID: projectBindingID,
            baseRevision: base,
            checkpointRevision: revision,
            localRef: localRef,
            boundary: boundary,
            changedPaths: changedPaths,
            diffSummary: diffSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            state: .incoming,
            failureMessage: nil
        )
        return RemoteGitCheckpointResult(checkpoint: checkpoint, changeset: changeset)
    }

    func validate(_ changeset: IncomingChangeset, localOrigin: String) async throws {
        try Self.validateAbsolutePath(localOrigin)
        try await requireExpectedBase(changeset, localOrigin: localOrigin)
        try await requireExpectedCheckpoint(changeset, localOrigin: localOrigin)
        let validationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-validate-\(changeset.id.rawValue.uuidString)", isDirectory: true)
        do {
            _ = try await run(
                "/usr/bin/git",
                ["-C", localOrigin, "worktree", "add", "--detach", validationRoot.path, changeset.checkpointRevision]
            )
            _ = try await run(
                "/usr/bin/git",
                ["-C", validationRoot.path, "diff", "--check", changeset.baseRevision, changeset.checkpointRevision]
            )
            _ = try await run(
                "/usr/bin/git",
                ["-C", localOrigin, "worktree", "remove", "--force", validationRoot.path]
            )
        } catch {
            _ = try? await run(
                "/usr/bin/git",
                ["-C", localOrigin, "worktree", "remove", "--force", validationRoot.path]
            )
            throw error
        }
    }

    func apply(_ changeset: IncomingChangeset, localOrigin: String) async throws {
        try Self.validateAbsolutePath(localOrigin)
        await applyCoordinator.acquire(localOrigin)
        do {
            try await requireCleanOrigin(localOrigin)
            try await requireExpectedBase(changeset, localOrigin: localOrigin)
            try await requireExpectedCheckpoint(changeset, localOrigin: localOrigin)
            _ = try await run(
                "/usr/bin/git",
                ["-C", localOrigin, "merge", "--ff-only", changeset.checkpointRevision]
            )
            await applyCoordinator.release(localOrigin)
        } catch {
            await applyCoordinator.release(localOrigin)
            throw error
        }
    }

    func discard(_ changeset: IncomingChangeset, localOrigin: String) async throws {
        try Self.validateAbsolutePath(localOrigin)
        // Discard hides the changeset in the UI but deliberately keeps its
        // fetched ref. A later recovery or explicit purge can still find it.
        _ = try await run(
            "/usr/bin/git",
            ["-C", localOrigin, "show-ref", "--verify", "--quiet", changeset.localRef]
        )
    }

    private func requireExpectedBase(_ changeset: IncomingChangeset, localOrigin: String) async throws {
        let head = try await run("/usr/bin/git", ["-C", localOrigin, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == changeset.baseRevision else {
            throw RemoteGitCheckpointError.staleBase
        }
    }

    private func requireCleanOrigin(_ localOrigin: String) async throws {
        let status = try await run(
            "/usr/bin/git",
            ["-C", localOrigin, "status", "--porcelain=v1", "--untracked-files=normal"]
        )
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteGitCheckpointError.dirtyOrigin
        }
    }

    private func requireExpectedCheckpoint(_ changeset: IncomingChangeset, localOrigin: String) async throws {
        let fetchedRevision: String
        do {
            fetchedRevision = try await run(
                "/usr/bin/git",
                ["-C", localOrigin, "rev-parse", "--verify", changeset.localRef]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw RemoteGitCheckpointError.changedCheckpoint
        }
        guard fetchedRevision == changeset.checkpointRevision else {
            throw RemoteGitCheckpointError.changedCheckpoint
        }
    }

    /// A one-line name for a command, for the log.
    ///
    /// Arguments are summarised rather than printed: the checkpoint's remote
    /// argument is a whole shell script, and pasting it into the log per run
    /// would bury the sequence this is here to make readable.
    private static func describe(_ executable: String, _ arguments: [String]) -> String {
        let name = (executable as NSString).lastPathComponent
        let parts = arguments.map { argument -> String in
            if argument.contains("\n") { return "<script>" }
            return argument.count > 48 ? String(argument.prefix(48)) + "…" : argument
        }
        let joined = parts.joined(separator: " ")
        return joined.count > 160 ? "\(name) \(joined.prefix(160))…" : "\(name) \(joined)"
    }

    private func run(_ executable: String, _ arguments: [String]) async throws -> String {
        // Every step of every remote-work action passes through here. Until
        // now the drawer showed the PLAN and then nothing, so an action that
        // died on its third command was indistinguishable from one that never
        // started.
        let label = Self.describe(executable, arguments)
        RemoteWorkLog.debugOffMain("run \(label)")
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errorOutput, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let resolvedMessage = message.flatMap { $0.isEmpty ? nil : $0 }
                            ?? "Command failed: \(executable)"
                        // Names the command only. The caller logs the failure
                        // with its message, and repeating stderr here would
                        // print the same paragraph twice in a row.
                        RemoteWorkLog.infoOffMain("Command failed: \(label)")
                        continuation.resume(throwing: RemoteGitCheckpointError.commandFailed(resolvedMessage))
                        return
                    }
                    continuation.resume(returning: String(data: output, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(throwing: RemoteGitCheckpointError.commandFailed(error.localizedDescription))
                }
            }
        }
    }

    private static func validateTarget(_ target: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@[]:")
        guard !target.isEmpty,
              target.unicodeScalars.allSatisfy(allowed.contains),
              !target.hasPrefix("-") else {
            throw RemoteGitCheckpointError.invalidTarget
        }
    }

    private static func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw RemoteGitCheckpointError.invalidPath(path)
        }
    }

    private static func isGitObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private actor OriginApplyCoordinator {
    private var activeOrigins: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ origin: String) async {
        guard activeOrigins.contains(origin) else {
            activeOrigins.insert(origin)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[origin, default: []].append(continuation)
        }
    }

    func release(_ origin: String) {
        guard var originWaiters = waiters[origin], !originWaiters.isEmpty else {
            activeOrigins.remove(origin)
            waiters[origin] = nil
            return
        }
        let next = originWaiters.removeFirst()
        waiters[origin] = originWaiters.isEmpty ? nil : originWaiters
        next.resume()
    }
}
