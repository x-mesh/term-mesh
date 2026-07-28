import Foundation

/// Putting a branch back where auto pilot found it.
///
/// The naive move — `git update-ref refs/heads/develop <sha>` — is wrong
/// precisely when it matters. If that branch is checked out somewhere, moving
/// the ref leaves HEAD pointing at one commit and the index and working tree at
/// another; git then reports every file in the merge as a staged deletion, and
/// the person undoing a merge is now looking at a mess worse than the one they
/// started with.
///
/// So where the branch lives decides how it is put back, and uncommitted work
/// stops the undo rather than being discarded by it. Undoing auto pilot must
/// never cost someone their own edits.
enum AutoPilotUndo {
    enum Plan: Equatable {
        /// The branch is not checked out: move the ref.
        case updateRef(repository: String, branch: String, sha: String)
        /// The branch is checked out and clean: reset that worktree.
        case resetWorktree(path: String, sha: String)
        /// Not safely undoable from here, with the reason.
        case refuse(String)

        /// What will run, for the person about to press the button. Undoing
        /// someone's merge is a decision, and a decision needs to be shown
        /// before it is taken.
        var displayCommand: String? {
            switch self {
            case .updateRef(let repository, let branch, let sha):
                return "git -C \(quote(repository)) update-ref refs/heads/\(branch) \(sha)"
            case .resetWorktree(let path, let sha):
                return "git -C \(quote(path)) reset --hard \(sha)"
            case .refuse:
                return nil
            }
        }

        private func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    /// Where the branch is checked out, and whether that checkout is clean.
    struct Placement: Equatable {
        /// The worktree holding this branch, or nil when nothing has it.
        let checkedOutAt: String?
        /// Whether that checkout has uncommitted changes.
        let isDirty: Bool

        static let notCheckedOut = Placement(checkedOutAt: nil, isDirty: false)
    }

    static func plan(for point: AutoPilotUndoPoint, placement: Placement) -> Plan {
        guard !point.sha.isEmpty else {
            return .refuse("No commit was recorded for this merge, so there is nowhere to go back to.")
        }
        guard let path = placement.checkedOutAt else {
            return .updateRef(
                repository: point.repositoryPath, branch: point.branch, sha: point.sha
            )
        }
        guard !placement.isDirty else {
            return .refuse(
                "\(point.branch) is checked out at \(path) with uncommitted changes to tracked files. "
                    + "Commit or stash them first — undoing must not throw away your own work."
            )
        }
        return .resetWorktree(path: path, sha: point.sha)
    }

    // MARK: - Reading and applying

    /// The repository that outlives the merge.
    ///
    /// `worktree finish --cleanup` deletes the worktree it merged from, so an
    /// undo point recorded against that path points at a directory that no
    /// longer exists by the time anyone wants to use it. The shared git
    /// directory's parent is the checkout that stays.
    static func repositoryRoot(
        containing worktreePath: String,
        run: (_ arguments: [String]) async -> ProcessRun.Output? = { arguments in
            try? await ProcessRun.capture(
                executable: "/usr/bin/git", arguments: arguments, timeout: 30
            )
        }
    ) async -> String? {
        guard let output = await run([
            "-C", worktreePath, "rev-parse", "--path-format=absolute", "--git-common-dir",
        ]), output.status == 0 else { return nil }
        let commonDir = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonDir.isEmpty else { return nil }
        // A bare repository has no parent checkout to reset; the common dir is
        // itself the repository, and update-ref against it is right.
        guard commonDir.hasSuffix("/.git") else { return commonDir }
        return (commonDir as NSString).deletingLastPathComponent
    }

    /// Where the branch is, read from git rather than assumed.
    static func placement(
        of branch: String,
        in repository: String,
        run: (_ arguments: [String]) async -> ProcessRun.Output? = { arguments in
            try? await ProcessRun.capture(
                executable: "/usr/bin/git", arguments: arguments, timeout: 30
            )
        }
    ) async -> Placement {
        guard let listing = await run(["-C", repository, "worktree", "list", "--porcelain"]),
              listing.status == 0 else {
            return .notCheckedOut
        }
        guard let path = checkoutPath(of: branch, inPorcelain: listing.stdoutText) else {
            return .notCheckedOut
        }
        // Tracked changes only. `reset --hard` moves HEAD and overwrites
        // tracked files; it does not touch untracked ones, so a stray build
        // artifact is not something an undo could destroy — and refusing on
        // one would make undo unusable in any real checkout.
        let status = await run(["-C", path, "status", "--porcelain", "--untracked-files=no"])
        let dirty = (status?.stdoutText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        return Placement(checkedOutAt: path, isDirty: dirty)
    }

    /// `worktree list --porcelain` is stanzas separated by blank lines, each
    /// opening with `worktree <path>` and naming its branch on a later line.
    /// Parsed rather than grepped so a path containing the word "branch"
    /// cannot be mistaken for one.
    static func checkoutPath(of branch: String, inPorcelain text: String) -> String? {
        var currentPath: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let entry = String(line)
            if entry.hasPrefix("worktree ") {
                currentPath = String(entry.dropFirst("worktree ".count))
            } else if entry == "branch refs/heads/\(branch)" {
                return currentPath
            } else if entry.isEmpty {
                currentPath = nil
            }
        }
        return nil
    }

    enum Result: Equatable {
        case done(String)
        case failed(String)
    }

    static func apply(
        _ plan: Plan,
        run: (_ arguments: [String]) async -> ProcessRun.Output? = { arguments in
            try? await ProcessRun.capture(
                executable: "/usr/bin/git", arguments: arguments, timeout: 60
            )
        }
    ) async -> Result {
        let arguments: [String]
        let done: String
        switch plan {
        case .refuse(let reason):
            return .failed(reason)
        case .updateRef(let repository, let branch, let sha):
            arguments = ["-C", repository, "update-ref", "refs/heads/\(branch)", sha]
            done = "\(branch) is back at \(sha.prefix(8))."
        case .resetWorktree(let path, let sha):
            arguments = ["-C", path, "reset", "--hard", sha]
            done = "\(path) is back at \(sha.prefix(8))."
        }

        guard let output = await run(arguments) else {
            return .failed("git could not be run.")
        }
        guard output.status == 0 else {
            let detail = output.stderrText
            return .failed(detail.isEmpty ? "git exited \(output.status)." : detail)
        }
        return .done(done)
    }
}
