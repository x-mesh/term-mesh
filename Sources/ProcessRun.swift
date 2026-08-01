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
/// The deadline is enforced by terminating the spawned process group rather
/// than by giving up on the read: descendants inherit the pipe write ends, so
/// the entire group must exit before the reads can return.
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

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdout: Pipe,
        stderr: Pipe
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            throw Failure.couldNotStart(String(cString: strerror(actionsResult)))
        }
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            throw Failure.couldNotStart(String(cString: strerror(attributesResult)))
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let stdoutRead = stdout.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdout.fileHandleForWriting.fileDescriptor
        let stderrRead = stderr.fileHandleForReading.fileDescriptor
        let stderrWrite = stderr.fileHandleForWriting.fileDescriptor
        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutRead),
            posix_spawn_file_actions_addclose(&actions, stderrRead),
            posix_spawn_file_actions_addclose(&actions, stdoutWrite),
            posix_spawn_file_actions_addclose(&actions, stderrWrite),
        ]
        if let failure = actionResults.first(where: { $0 != 0 }) {
            throw Failure.couldNotStart(String(cString: strerror(failure)))
        }
        if let currentDirectory {
            let result = currentDirectory.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            }
            guard result == 0 else {
                throw Failure.couldNotStart(String(cString: strerror(result)))
            }
        }

        let flagsResult = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        )
        guard flagsResult == 0 else {
            throw Failure.couldNotStart(String(cString: strerror(flagsResult)))
        }
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupResult == 0 else {
            throw Failure.couldNotStart(String(cString: strerror(groupResult)))
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        let inheritedEnvironment = environment ?? ProcessInfo.processInfo.environment
        let envp = inheritedEnvironment.map { key, value in
            strdup(key + "=" + value)
        } + [nil]
        defer { envp.compactMap { $0 }.forEach { free($0) } }

        var pid: pid_t = 0
        let result = executable.withCString { executablePointer in
            argv.withUnsafeBufferPointer { argvPointer in
                envp.withUnsafeBufferPointer { envPointer in
                    posix_spawn(
                        &pid,
                        executablePointer,
                        &actions,
                        &attributes,
                        UnsafeMutablePointer(mutating: argvPointer.baseAddress),
                        UnsafeMutablePointer(mutating: envPointer.baseAddress)
                    )
                }
            }
        }
        guard result == 0 else {
            throw Failure.couldNotStart(String(cString: strerror(result)))
        }
        return pid
    }

    static func capture(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let stdout = Pipe()
                let stderr = Pipe()
                let pid: pid_t
                do {
                    pid = try spawn(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        currentDirectory: currentDirectory,
                        stdout: stdout,
                        stderr: stderr
                    )
                } catch let failure as Failure {
                    continuation.resume(throwing: failure)
                    return
                } catch {
                    continuation.resume(
                        throwing: Failure.couldNotStart(error.localizedDescription)
                    )
                    return
                }
                stdout.fileHandleForWriting.closeFile()
                stderr.fileHandleForWriting.closeFile()

                var errorOutput = Data()
                let stderrDone = DispatchGroup()
                stderrDone.enter()
                stderrQueue.async {
                    errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
                    stderrDone.leave()
                }
                let processGroup = pid
                let stateLock = NSLock()
                var didTimeOut = false
                var didFinish = false
                let escalation = DispatchWorkItem {
                    stateLock.lock()
                    guard !didFinish else {
                        stateLock.unlock()
                        return
                    }
                    stateLock.unlock()
                    Darwin.kill(-processGroup, SIGKILL)
                }
                let watchdog = DispatchWorkItem {
                    stateLock.lock()
                    guard !didFinish else {
                        stateLock.unlock()
                        return
                    }
                    let signalled = Darwin.kill(-processGroup, SIGTERM) == 0
                    didTimeOut = signalled
                    stateLock.unlock()
                    guard signalled else { return }
                    stderrQueue.asyncAfter(deadline: .now() + 1, execute: escalation)
                }
                stderrQueue.asyncAfter(deadline: .now() + timeout, execute: watchdog)

                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                stderrDone.wait()
                var waitStatus: Int32 = 0
                while true {
                    stateLock.lock()
                    let waited = waitpid(pid, &waitStatus, WNOHANG)
                    if waited == pid || (waited == -1 && errno != EINTR) {
                        didFinish = true
                        stateLock.unlock()
                        break
                    }
                    stateLock.unlock()
                    usleep(10_000)
                }
                watchdog.cancel()
                let terminatingSignal = waitStatus & 0x7f
                let status = terminatingSignal == 0
                    ? (waitStatus >> 8) & 0xff
                    : terminatingSignal
                stateLock.lock()
                let timedOut = didTimeOut
                stateLock.unlock()
                if timedOut {
                    // The direct child can obey SIGTERM while one of its
                    // descendants ignores it and has already closed the
                    // captured pipes. Reaping the child is therefore not proof
                    // that the process group is gone. Kill any remainder now
                    // instead of cancelling the scheduled escalation.
                    Darwin.kill(-processGroup, SIGKILL)
                }
                escalation.cancel()

                continuation.resume(returning: Output(
                    status: status,
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
