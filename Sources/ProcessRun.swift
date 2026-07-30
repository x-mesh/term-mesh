import Darwin
import Foundation

/// Running a command and getting all of its output back.
///
/// The care here is entirely about the pipes. A patch, or a merge's log,
/// routinely outruns the 64KB pipe buffer, and a process whose pipe is full
/// blocks on the write while the caller blocks waiting for it to exit. So both
/// pipes are drained before anything waits, and stderr gets its own queue —
/// draining one after the other only moves the deadlock to whichever fills
/// while the other is being read.
///
/// The deadline is enforced by terminating the process rather than by giving up
/// on the read: a command that never writes and never exits would otherwise
/// hold the queue forever, and terminating it is what closes the pipes and lets
/// the read return.
enum ProcessRun {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data
        /// The watchdog fired. `status` is then whatever a killed process
        /// reports, which is not a failure the command chose.
        let timedOut: Bool

        var stdoutText: String {
            String(data: stdout, encoding: .utf8) ?? ""
        }

        var stderrText: String {
            (String(data: stderr, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum Failure: Error, Equatable {
        /// The executable is missing or not runnable — distinct from a command
        /// that ran and disagreed.
        case couldNotStart(String)
    }

    private static let queue = DispatchQueue(
        label: "com.termmesh.processrun",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let stderrQueue = DispatchQueue(
        label: "com.termmesh.processrun.stderr",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func capture(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr
                if let environment { process.environment = environment }
                if let currentDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: Failure.couldNotStart(error.localizedDescription)
                    )
                    return
                }

                var errorOutput = Data()
                let stderrDone = DispatchGroup()
                stderrDone.enter()
                stderrQueue.async {
                    errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
                    stderrDone.leave()
                }
                let escalation = DispatchWorkItem {
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    stderrQueue.asyncAfter(deadline: .now() + 1, execute: escalation)
                }
                stderrQueue.asyncAfter(deadline: .now() + timeout, execute: watchdog)

                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                stderrDone.wait()
                process.waitUntilExit()
                let timedOut = !watchdog.isCancelled
                    && process.terminationReason == .uncaughtSignal
                watchdog.cancel()
                escalation.cancel()

                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: output,
                    stderr: errorOutput,
                    timedOut: timedOut
                ))
            }
        }
    }

    /// Where a CLI actually is.
    ///
    /// PATH is not the answer here. A GUI app launched by launchd inherits a
    /// minimal PATH that has never contained `~/.local/bin` or Homebrew, which
    /// is how CLI spawning has silently failed before. Explicit candidates,
    /// checked for executability, is what survives that.
    static func locate(_ name: String, extraCandidates: [String] = []) -> String? {
        let home = NSHomeDirectory()
        var candidates = extraCandidates
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            (home as NSString).appendingPathComponent(".local/bin/\(name)"),
            "/usr/bin/\(name)",
        ])
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append((String(directory) as NSString).appendingPathComponent(name))
            }
        }
        let manager = FileManager.default
        return candidates.first { manager.isExecutableFile(atPath: $0) }
    }
}
