import Foundation

/// Runs the merges the board has approved.
///
/// Approving records a decision; this is what acts on it. Each queued item is
/// taken once, `git-kit worktree finish` runs against the task's worktree, and
/// the coordinator hears back either `merged` or `failed` with the reason.
///
/// It never retries. git-kit *pauses* on conflict rather than failing, and
/// re-running finish against a paused rebase compounds the mess instead of
/// clearing it — a merge that stopped is a merge that wants a person. Every
/// stopping condition here therefore ends in `failed` with something a person
/// can act on, not in a second attempt.
actor ReviewBoardMergeRunner {
    /// One approved item, with everything the merge needs already resolved.
    /// Nothing here is inferred at merge time: a merge that lands somewhere
    /// nobody expected is exactly what guessing a target buys.
    struct Job: Equatable {
        let queueID: String
        let taskID: String
        /// Where the task did its work. `nil` when the board never recorded one.
        let worktreePath: String?
        /// Passed to `--to` verbatim: `parent`, `base`, or a branch name.
        let target: String

        init(queueID: String, taskID: String, worktreePath: String?, target: String = "parent") {
            self.queueID = queueID
            self.taskID = taskID
            self.worktreePath = worktreePath
            self.target = target
        }
    }

    enum Outcome: Equatable {
        case merged(branch: String)
        /// The reason lands in the queue entry's `last_error`, so it is written
        /// for whoever opens the board next, not for a log.
        case failed(String)
        /// This queue item is already being merged by this runner.
        case alreadyRunning
    }

    /// Runs a command. Injected so the failure modes below can be tested
    /// without a repository in a particular state — a conflicted rebase is
    /// otherwise very hard to arrange on demand.
    typealias Command = (_ arguments: [String], _ timeout: TimeInterval) async throws
        -> ProcessRun.Output

    private let command: Command
    private let pathExists: (String) -> Bool
    private let report: (String, String, String?) async -> Void
    private let timeout: TimeInterval

    /// Queue ids currently being merged. The actor is the lock: a second call
    /// for the same item cannot get past this set while the first is awaiting
    /// the merge.
    private var inFlight: Set<String> = []

    init(
        timeout: TimeInterval = 300,
        command: @escaping Command,
        pathExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        report: @escaping (String, String, String?) async -> Void
    ) {
        self.timeout = timeout
        self.command = command
        self.pathExists = pathExists
        self.report = report
    }

    /// The live wiring: git-kit against the real filesystem, reporting to the
    /// coordinator.
    static func live(
        coordinator: ReviewBoardCoordinatorService,
        gitKitPath: String? = nil,
        timeout: TimeInterval = 300
    ) -> ReviewBoardMergeRunner? {
        guard let executable = gitKitPath ?? ProcessRun.locate("git-kit") else { return nil }
        return ReviewBoardMergeRunner(
            timeout: timeout,
            command: { arguments, timeout in
                var environment = ProcessInfo.processInfo.environment
                // Without this git-kit prints prose for humans; with it every
                // command answers in the same {state, ok, result, error}
                // envelope, which is the only thing safe to branch on.
                environment["GK_AGENT"] = "1"
                return try await ProcessRun.capture(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    timeout: timeout
                )
            },
            report: { queueID, status, lastError in
                try? await coordinator.transitionMergeQueue(
                    queueID: queueID, status: status, lastError: lastError
                )
            }
        )
    }

    // MARK: - Merging

    @discardableResult
    func process(_ job: Job) async -> Outcome {
        guard !inFlight.contains(job.queueID) else { return .alreadyRunning }

        // Everything that can be known without running anything is checked
        // first, so a hopeless merge is refused rather than half-attempted.
        guard let path = job.worktreePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return await fail(job, "This task has no worktree recorded, so there is nothing to merge.")
        }
        guard pathExists(path) else {
            return await fail(job, "The worktree at \(path) is gone — it was removed or never created.")
        }

        inFlight.insert(job.queueID)
        defer { inFlight.remove(job.queueID) }

        await report(job.queueID, "running", nil)

        let arguments = [
            "worktree", "finish",
            "--repo", path,
            "--to", job.target,
            "--cleanup",
        ]
        let output: ProcessRun.Output
        do {
            output = try await command(arguments, timeout)
        } catch let ProcessRun.Failure.couldNotStart(reason) {
            return await fail(job, "git-kit could not be started: \(reason)")
        } catch {
            return await fail(job, "git-kit could not be started: \(error.localizedDescription)")
        }

        if output.timedOut {
            return await fail(
                job,
                "git-kit worktree finish did not answer within \(Int(timeout))s and was stopped."
            )
        }

        return await interpret(output, for: job)
    }

    /// Process every job, one at a time. Serial on purpose: two merges into the
    /// same branch at once is how a clean queue produces a conflicted one.
    func processAll(_ jobs: [Job]) async -> [(Job, Outcome)] {
        var results: [(Job, Outcome)] = []
        for job in jobs {
            results.append((job, await process(job)))
        }
        return results
    }

    // MARK: - Reading git-kit's answer

    private func interpret(_ output: ProcessRun.Output, for job: Job) async -> Outcome {
        guard let envelope = try? JSONSerialization.jsonObject(with: output.stdout)
                as? [String: Any] else {
            let detail = output.stderrText.isEmpty
                ? "exit \(output.status)"
                : output.stderrText
            return await fail(job, "git-kit answered with something unreadable (\(detail)).")
        }

        let state = envelope["state"] as? String ?? (envelope["ok"] as? Bool == true ? "ok" : "error")
        switch state {
        case "ok":
            let result = envelope["result"] as? [String: Any]
            let branch = result?["branch"] as? String ?? job.target
            await report(job.queueID, "merged", nil)
            return .merged(branch: branch)

        case "paused":
            // The merge stopped mid-way and the repository is holding a
            // conflicted state. Reporting it as failed is the point: a retry
            // would run finish again on top of the pause.
            return await fail(job, Self.pausedReason(envelope))

        default:
            return await fail(job, Self.errorReason(envelope, fallback: output.stderrText))
        }
    }

    /// A paused merge is only actionable if the reader is told how to get out
    /// of it, so the resume command git-kit already computed is carried along.
    private static func pausedReason(_ envelope: [String: Any]) -> String {
        let result = envelope["result"] as? [String: Any]
        let error = envelope["error"] as? [String: Any]
        let what = (result?["message"] as? String)
            ?? (error?["message"] as? String)
            ?? "The merge paused, most likely on a conflict."
        let resume = (result?["resume"] as? String)
            ?? (result?["resume_command"] as? String)
            ?? firstRemedy(error)
        guard let resume, !resume.isEmpty else {
            return "\(what) It was not retried — finish it by hand."
        }
        return "\(what) It was not retried; resume or abort by hand: \(resume)"
    }

    private static func errorReason(_ envelope: [String: Any], fallback: String) -> String {
        let error = envelope["error"] as? [String: Any]
        let message = (error?["message"] as? String)
            ?? (envelope["message"] as? String)
            ?? (fallback.isEmpty ? "git-kit worktree finish failed." : fallback)
        guard let remedy = firstRemedy(error), !remedy.isEmpty else { return message }
        return "\(message) Suggested: \(remedy)"
    }

    private static func firstRemedy(_ error: [String: Any]?) -> String? {
        guard let remedies = error?["remedies"] as? [[String: Any]] else { return nil }
        return remedies.first?["command"] as? String
    }

    private func fail(_ job: Job, _ reason: String) async -> Outcome {
        await report(job.queueID, "failed", reason)
        return .failed(reason)
    }
}

extension ReviewBoardMergeRunner.Job {
    /// The queue entry joined to the task that owns the worktree.
    ///
    /// An entry whose task the board does not have is not merged — the
    /// worktree path lives on the task, and merging without it would mean
    /// picking a directory.
    init?(item: ReviewBoardMergeQueueItem, tasks: [ReviewBoardTask], target: String = "parent") {
        guard let task = tasks.first(where: { $0.rawID == item.taskRawID }) else { return nil }
        self.init(
            queueID: item.id,
            taskID: item.taskRawID,
            worktreePath: task.worktreePath,
            target: target
        )
    }
}
