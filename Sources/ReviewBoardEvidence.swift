import CryptoKit
import Foundation

enum ReviewBoardEvidenceError: Error, Equatable {
    case unknownBase
    case commandFailed(String)
    case timedOut(String)
}

/// What a review is *about*, read out of the working tree the agent used.
///
/// The coordinator stores no patch — it keeps two shas and a digest and
/// re-checks them when an approval arrives — so the bytes have to come from
/// here, and the digest has to be computed from exactly the bytes a person
/// looked at. Nothing in the repository produced one before: `diff_digest` was
/// a `sha256:`-prefixed string the coordinator validated the *shape* of and
/// never the content, and the only values it had ever seen were test literals.
///
/// So this file is where the definition gets fixed:
///
///     diff_digest = "sha256:" + SHA256( stdout of `git diff <base>..<head>` )
///
/// Raw stdout, not a decoded string: a patch that touches a binary file, or a
/// file in an encoding that is not UTF-8, does not survive a round trip
/// through `String`, and a digest that changes depending on whether the bytes
/// happened to decode is not evidence of anything.
enum ReviewBoardEvidence {
    struct FileSummary: Equatable {
        let path: String
        /// `added` / `modified` / `deleted` / `renamed` / `copied`.
        let kind: String
        let add: Int
        let del: Int

        /// The shape `review.snapshot` takes (`ReviewFileSummary` in
        /// daemon/tm-coordinator/src/model.rs).
        var rpcValue: [String: Any] {
            ["path": path, "kind": kind, "add": add, "del": del]
        }
    }

    struct Patch: Equatable {
        let baseSHA: String
        let headSHA: String
        /// `sha256:` + hex over the full patch, never over `text` — which may
        /// have been shortened for display.
        let digest: String
        let text: String
        /// Whether `text` is the whole patch. A reviewer has to know they are
        /// looking at an excerpt; the digest still covers everything.
        let isTruncated: Bool
        let files: [FileSummary]

        var isEmpty: Bool { files.isEmpty }
    }

    /// Beyond this the patch is shown as an excerpt. A review pane that tries
    /// to lay out a megabyte of text stops being a review pane.
    static let displayByteLimit = 256 * 1024

    /// Read the evidence for a worktree.
    ///
    /// `parentRef` is where the branch came from — `gk-parent` for a git-kit
    /// worktree, which is what the task board records. Without it there is no
    /// base to diff against and no honest way to guess one: diffing against
    /// `HEAD~1` would silently review the last commit instead of the branch.
    static func read(
        worktreePath: String,
        parentRef: String?,
        timeout: TimeInterval = 30
    ) async throws -> Patch {
        guard let parentRef, !parentRef.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ReviewBoardEvidenceError.unknownBase
        }
        let git = { (arguments: [String]) in
            try await run(["-C", worktreePath] + arguments, timeout: timeout)
        }

        let head = try await text(git(["rev-parse", "HEAD"]))
        // merge-base rather than the parent tip: the parent may have moved on
        // since the branch was cut, and diffing against its current tip would
        // show somebody else's commits as part of this review.
        let base = try await text(git(["merge-base", parentRef, "HEAD"]))
        let range = "\(base)..\(head)"

        let patch = try await git(["diff", range])
        let numstat = try await text(git(["diff", "--numstat", range]))
        let nameStatus = try await text(git(["diff", "--name-status", range]))

        return Patch(
            baseSHA: base,
            headSHA: head,
            digest: digest(forPatch: patch),
            text: display(patch),
            isTruncated: patch.count > displayByteLimit,
            files: summarize(numstat: numstat, nameStatus: nameStatus)
        )
    }

    /// Split out so the definition can be tested without a repository.
    static func digest(forPatch bytes: Data) -> String {
        let hex = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(hex)"
    }

    // MARK: - Parsing

    static func summarize(numstat: String, nameStatus: String) -> [FileSummary] {
        // `--name-status` carries the kind, `--numstat` the counts, and there
        // is no single flag that gives both.
        var kinds: [String: String] = [:]
        for line in nameStatus.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2, let letter = parts[0].first else { continue }
            // A rename reports old and new paths; the new one is what a
            // reviewer opens.
            let path = String(parts[parts.count - 1])
            kinds[path] = kind(for: letter)
        }
        return numstat.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            let path = String(parts[parts.count - 1])
            // A binary file reports "-" for both counts rather than a number.
            return FileSummary(
                path: path,
                kind: kinds[path] ?? "modified",
                add: Int(parts[0]) ?? 0,
                del: Int(parts[1]) ?? 0
            )
        }
    }

    private static func kind(for letter: Character) -> String {
        switch letter {
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "C": return "copied"
        default:  return "modified"
        }
    }

    private static func display(_ patch: Data) -> String {
        let shown = patch.count > displayByteLimit
            ? patch.prefix(displayByteLimit)
            : patch
        // A patch that does not decode is still worth showing what can be
        // read of it; the digest above already covers the real bytes.
        return String(decoding: shown, as: UTF8.self)
    }

    private static func text(_ data: Data) throws -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Running git

    private static let queue = DispatchQueue(
        label: "com.termmesh.reviewboard.evidence",
        qos: .userInitiated
    )
    private static let stderrQueue = DispatchQueue(
        label: "com.termmesh.reviewboard.evidence.stderr",
        qos: .userInitiated
    )

    private static func run(_ arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: ReviewBoardEvidenceError.commandFailed(error.localizedDescription)
                    )
                    return
                }
                // A patch outruns the 64KB pipe buffer routinely, so both
                // pipes are drained before anything waits on the process, and
                // stderr on its own queue. Waiting first deadlocks; draining
                // one after the other only moves the deadlock to whichever
                // pipe fills while the other is being read.
                var errorOutput = Data()
                let stderrDone = DispatchGroup()
                stderrDone.enter()
                stderrQueue.async {
                    errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
                    stderrDone.leave()
                }
                // The read above is what actually bounds this: a git that
                // never writes and never exits would hold the queue forever,
                // so the deadline is enforced by terminating the process,
                // which closes the pipes and lets the read return.
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                stderrQueue.asyncAfter(deadline: .now() + timeout, execute: watchdog)

                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                stderrDone.wait()
                process.waitUntilExit()
                let timedOut = watchdog.isCancelled == false && process.terminationReason == .uncaughtSignal
                watchdog.cancel()

                guard process.terminationStatus == 0 else {
                    let label = "git \(arguments.joined(separator: " "))"
                    if timedOut {
                        continuation.resume(throwing: ReviewBoardEvidenceError.timedOut(label))
                        return
                    }
                    let message = String(decoding: errorOutput, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: ReviewBoardEvidenceError.commandFailed(
                            message.isEmpty ? label : message
                        )
                    )
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }
}
