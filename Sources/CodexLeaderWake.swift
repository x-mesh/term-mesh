import Darwin
import Foundation

/// Wakes a Codex leader when a worker task it is waiting on finishes.
///
/// A Claude Code leader is re-invoked by its own harness when a background
/// wait returns. A Codex leader has nothing like that, so it either blocks in
/// a foreground `tm-agent wait` or ends its turn and never hears back. With
/// the option on, a finished task becomes one short line in the leader's
/// session, which starts a Codex turn the way a user message would.
///
/// Claude leaders are excluded on purpose: their harness already wakes them,
/// and a second wake would start a second turn.
final class CodexLeaderWake: @unchecked Sendable {
    static let shared = CodexLeaderWake()

    /// Read once per team, when the team is created and its Codex leader
    /// prompt is written. Changing it affects only teams created afterwards:
    /// a team keeps the behaviour its leader was told about, so a leader told
    /// to end its turn always gets the wake, and a leader told to wait in the
    /// foreground never gets one.
    static let enabledKey = "teamLeaderWake.codex.enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func isCodexLeader(leaderMode: String, leaderCli: String?) -> Bool {
        if leaderMode.lowercased() == "codex" { return true }
        return leaderMode == "adopted" && leaderCli?.lowercased() == "codex"
    }

    /// The per-team snapshot. Only a leader whose prompt term-mesh writes at
    /// creation can be told that a wake will come.
    static func newTeamWakes(
        leaderPromptInjected: Bool,
        leaderMode: String,
        leaderCli: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        leaderPromptInjected
            && isEnabled(defaults: defaults)
            && isCodexLeader(leaderMode: leaderMode, leaderCli: leaderCli)
    }

    /// Checked on the main actor right before delivery, against the live team.
    static func shouldDeliver(
        teamWakes: Bool, leaderReady: Bool, leaderMode: String, leaderCli: String?
    ) -> Bool {
        teamWakes && leaderReady && isCodexLeader(leaderMode: leaderMode, leaderCli: leaderCli)
    }

    /// Workers that finish together, such as one parallel wave, produce one
    /// line, so the leader starts one turn rather than one per task.
    static let coalesceWindow: TimeInterval = 2
    static let queueCommandTimeout: TimeInterval = 15

    /// All state below is owned by `stateQueue`. Callers may hold
    /// `TeamDataStore`'s lock, so entry points only enqueue.
    private let stateQueue = DispatchQueue(label: "com.termmesh.codex-leader-wake.state")
    private let deliveryQueue = DispatchQueue(
        label: "com.termmesh.codex-leader-wake.delivery", qos: .utility
    )
    private var state = CodexLeaderWakeState()
    private var flushScheduled: Set<String> = []

    /// Records the team's snapshot. Team creation always calls this, so a
    /// reused team name never inherits the previous team's answer.
    func setTeamWakes(teamName: String, wakes: Bool) {
        stateQueue.async { [self] in
            state.setTeamWakes(teamName, wakes)
        }
    }

    func noteTaskStatus(teamName: String, taskId: String, status: String) {
        stateQueue.async { [self] in
            guard state.note(teamName: teamName, taskId: taskId, status: status) else { return }
            guard flushScheduled.insert(teamName).inserted else { return }
            stateQueue.asyncAfter(deadline: .now() + Self.coalesceWindow) { [self] in
                flush(teamName: teamName)
            }
        }
    }

    private func flush(teamName: String) {
        flushScheduled.remove(teamName)
        guard let wake = state.flush(teamName: teamName) else { return }
        Task { @MainActor in
            guard let team = TeamOrchestrator.shared.teams[teamName],
                  Self.shouldDeliver(
                      teamWakes: team.codexLeaderWake, leaderReady: true,
                      leaderMode: team.leaderMode, leaderCli: team.leaderCli
                  )
            else {
                self.finish(teamName: teamName, flush: wake, retry: false)
                return
            }
            // A team that wakes but whose leader is not ready yet is retried.
            guard team.leaderReady else {
                self.finish(teamName: teamName, flush: wake, retry: true)
                return
            }
            var isPeer = false
            if case .peer = team.leaderEndpoint { isPeer = true }
            let panelId = team.leaderPanelId
            let fallbackBinary = CLIPathSettings.resolvedPath(for: "codex")
            self.deliveryQueue.async {
                // A peer leader runs on another host, out of reach of a local
                // `codex queue`; the text path already crosses the relay.
                if !isPeer,
                   let target = CodexLeaderThreadLocator.locate(surfaceId: panelId),
                   Self.queue(wake.line, to: target, fallbackBinary: fallbackBinary) {
                    self.finish(teamName: teamName, flush: wake, retry: false, delivered: true)
                    return
                }
                Task { @MainActor in
                    guard let manager = AppDelegate.shared?.locateSurface(surfaceId: panelId)?.tabManager
                    else {
                        self.finish(teamName: teamName, flush: wake, retry: true)
                        return
                    }
                    let sent = TeamOrchestrator.shared.sendToLeader(
                        teamName: teamName, text: wake.line, tabManager: manager
                    )
                    self.finish(teamName: teamName, flush: wake, retry: !sent, delivered: sent)
                }
            }
        }
    }

    /// Settles one flush on `stateQueue`. A failed delivery puts its events
    /// back and schedules the next try with backoff; the dedupe record is
    /// untouched, so the same pair is not announced twice.
    private func finish(
        teamName: String, flush wake: CodexLeaderWakeState.Flush, retry: Bool, delivered: Bool = false
    ) {
        stateQueue.async { [self] in
            if delivered { state.delivered(teamName: teamName, flush: wake) }
            guard retry else { return }
            switch state.retry(teamName: teamName, flush: wake) {
            case .scheduled(let attempt):
                guard flushScheduled.insert(teamName).inserted else { return }
                stateQueue.asyncAfter(deadline: .now() + CodexLeaderWakeBatch.retryDelay(attempt: attempt)) { [self] in
                    flush(teamName: teamName)
                }
            case .gaveUp:
                NSLog("[codex-wake] dropped wake team=%@ line=%@ after %ld failed attempts",
                      teamName, wake.line, CodexLeaderWakeBatch.maxRetries + 1)
            case .discarded:
                break
            }
        }
    }

    /// `codex queue` hands the message to the shared app-server daemon, which
    /// starts it as the thread's next turn once the current one ends. Unlike
    /// typed text it cannot land in the middle of whatever the user is
    /// composing in that pane.
    private static func queue(
        _ line: String, to target: CodexLeaderThreadLocator.Target, fallbackBinary: String?
    ) -> Bool {
        guard let binary = target.executable ?? fallbackBinary else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // The = form keeps clap from reading text that starts with "-" as a flag.
        process.arguments = ["queue", "--thread", target.threadId, "--message=\(line)"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        environment.removeValue(forKey: "CODEX_SESSION_ID")
        if let codexHome = target.codexHome { environment["CODEX_HOME"] = codexHome }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard finished.wait(timeout: .now() + queueCommandTimeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}

/// Which teams wake, and what each is waiting to say.
struct CodexLeaderWakeState {
    /// One drained line. `generation` ties it to the team incarnation that
    /// produced it, so a failure that settles after the team was recreated
    /// cannot put old events into the new team's batch.
    struct Flush: Equatable {
        let events: [CodexLeaderWakeBatch.Event]
        let line: String
        fileprivate let generation: Int
    }

    enum RetryOutcome: Equatable {
        case scheduled(attempt: Int)
        case gaveUp
        case discarded
    }

    private var wakingTeams: Set<String> = []
    private var batches: [String: CodexLeaderWakeBatch] = [:]
    private var generations: [String: Int] = [:]

    mutating func setTeamWakes(_ teamName: String, _ wakes: Bool) {
        generations[teamName, default: 0] += 1
        if wakes {
            wakingTeams.insert(teamName)
        } else {
            wakingTeams.remove(teamName)
            batches[teamName] = nil
        }
    }

    /// True when the team wakes and this (task, status) pair is new.
    mutating func note(teamName: String, taskId: String, status: String) -> Bool {
        guard wakingTeams.contains(teamName) else { return false }
        return batches[teamName, default: CodexLeaderWakeBatch()]
            .admit(taskId: taskId, status: status)
    }

    /// Re-checks the team at flush time: one that stopped waking during the
    /// coalesce window sends nothing.
    mutating func flush(teamName: String) -> Flush? {
        guard let events = batches[teamName]?.drain(), wakingTeams.contains(teamName),
              let line = CodexLeaderWakeBatch.wakeLine(for: events)
        else { return nil }
        return Flush(events: events, line: line, generation: generations[teamName, default: 0])
    }

    mutating func flushLine(teamName: String) -> String? {
        flush(teamName: teamName)?.line
    }

    /// Puts a failed flush back ahead of newer events, within the retry bound.
    mutating func retry(teamName: String, flush: Flush) -> RetryOutcome {
        guard wakingTeams.contains(teamName),
              generations[teamName, default: 0] == flush.generation,
              batches[teamName] != nil
        else { return .discarded }
        if let attempt = batches[teamName]?.requeue(flush.events) {
            return .scheduled(attempt: attempt)
        }
        return .gaveUp
    }

    mutating func delivered(teamName: String, flush: Flush) {
        guard generations[teamName, default: 0] == flush.generation else { return }
        batches[teamName]?.resetRetries()
    }
}

/// Dedupe and coalescing for one team's wakes.
struct CodexLeaderWakeBatch {
    struct Event: Equatable {
        let taskId: String
        let status: String
    }

    static let wakeStatuses: Set<String> = ["completed", "review_ready", "blocked", "failed", "cancelled"]

    /// A leader that is not ready yet, or a pane that cannot be found for a
    /// moment, recovers within seconds; a longer outage drops the wake.
    static let maxRetries = 3
    static func retryDelay(attempt: Int) -> TimeInterval {
        CodexLeaderWake.coalesceWindow * pow(2, Double(max(1, attempt)))
    }

    /// Bounds memory for a long-lived team. A task id is eight hex characters
    /// and a team runs far fewer tasks than this between restarts.
    static let defaultRememberLimit = 1024

    private let rememberLimit: Int
    private var announced: Set<String> = []
    private var announcedOrder: [String] = []
    private(set) var pending: [Event] = []
    private var failedAttempts = 0

    init(rememberLimit: Int = defaultRememberLimit) {
        self.rememberLimit = max(1, rememberLimit)
    }

    /// True when this (task, status) pair has not been announced before and
    /// is now waiting for the next line.
    mutating func admit(taskId: String, status: String) -> Bool {
        guard Self.wakeStatuses.contains(status), !taskId.isEmpty else { return false }
        let key = taskId + "\u{1F}" + status
        guard announced.insert(key).inserted else { return false }
        announcedOrder.append(key)
        if announcedOrder.count > rememberLimit {
            announced.remove(announcedOrder.removeFirst())
        }
        pending.append(Event(taskId: taskId, status: status))
        return true
    }

    mutating func drain() -> [Event] {
        defer { pending = [] }
        return pending
    }

    /// Returns the attempt number, or nil once the retry bound is spent, in
    /// which case the events are dropped.
    mutating func requeue(_ events: [Event]) -> Int? {
        failedAttempts += 1
        guard failedAttempts <= Self.maxRetries else {
            failedAttempts = 0
            return nil
        }
        pending = events + pending
        return failedAttempts
    }

    mutating func resetRetries() {
        failedAttempts = 0
    }

    /// One line, because the text fallback flattens newlines and a Codex turn
    /// starts on the whole message anyway.
    static func wakeLine(for events: [Event]) -> String? {
        let parts = events.compactMap { event -> String? in
            let id = event.taskId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !id.isEmpty else { return nil }
            return "\(id) \(event.status)"
        }
        guard !parts.isEmpty else { return nil }
        let noun = parts.count == 1 ? "task" : "tasks"
        return "[term-mesh] \(noun) \(parts.joined(separator: ", ")) — run tm-agent collect --headers"
    }
}

/// Finds the Codex thread a leader pane is running.
///
/// The app clears `CODEX_THREAD_ID` from every pane it builds, so the thread
/// is not something it was told. It is found the way x-kit relay finds live
/// sessions: a running Codex CLI holds `thread-writer-locks/<thread>.lock`
/// open. The pane is matched by the `TERMMESH_SURFACE_ID` every term-mesh
/// pane process inherits.
enum CodexLeaderThreadLocator {
    struct Target: Equatable {
        let threadId: String
        let executable: String?
        let codexHome: String?
    }

    struct ProcessImage: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    static func locate(surfaceId: UUID) -> Target? {
        var targets: [Target] = []
        for pid in codexPids() {
            guard let image = processImage(pid: pid),
                  image.environment["TERMMESH_SURFACE_ID"]?.lowercased()
                    == surfaceId.uuidString.lowercased(),
                  !isCodexService(arguments: image.arguments),
                  // A TUI detached from the shared daemon never reads its queue.
                  !image.arguments.contains("--no-daemon"),
                  !image.arguments.contains(where: { $0 == "--remote" || $0.hasPrefix("--remote=") })
            else { continue }
            for threadId in threadIds(inOpenPaths: openVnodePaths(pid: pid)) {
                targets.append(Target(
                    threadId: threadId,
                    executable: executablePath(pid: pid),
                    codexHome: image.environment["CODEX_HOME"]
                ))
            }
        }
        let threads = Set(targets.map(\.threadId))
        // More than one thread, such as a subagent the leader started, means
        // the leader's own thread is not known. Guessing could wake the wrong one.
        guard threads.count == 1 else { return nil }
        return targets.first
    }

    static func threadIds(inOpenPaths paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().lastPathComponent == "thread-writer-locks",
                  url.pathExtension == "lock"
            else { continue }
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            guard UUID(uuidString: id) != nil, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    private static let valueOptions: Set<String> = [
        "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
        "-i", "--image", "-m", "--model", "--local-provider", "-p", "--profile",
        "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval",
    ]
    private static let switchOptions: Set<String> = [
        "--strict-config", "--oss", "--approve-for-me",
        "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
        "--worktree", "--search", "--no-alt-screen", "--no-daemon", "-h", "--help",
        "-V", "--version",
    ]
    /// Every `codex` subcommand (codex-cli 0.160) except `resume` and `fork`,
    /// which reopen an interactive session. `exec` matters most: a leader can
    /// run it as a tool, the child inherits the pane's TERMMESH_SURFACE_ID, and
    /// it holds a writer lock for a thread that is not the leader's.
    private static let nonInteractiveSubcommands: Set<String> = [
        "agents", "exec", "e", "review", "login", "logout", "mcp", "mcp-server", "plugin",
        "app-server", "remote-control", "app", "completion", "update", "doctor", "sandbox",
        "debug", "apply", "a", "queue", "archive", "delete", "migrate-rollouts", "unarchive",
        "cloud", "exec-server", "features", "help",
    ]

    /// True for a `codex` process that is not an interactive session: a
    /// service such as `app-server` or `queue`, or a one-shot command such as
    /// `exec`. Option parsing mirrors x-kit relay `isCodexService`; a first
    /// positional that is not a subcommand is the TUI's initial prompt.
    static func isCodexService(arguments: [String]) -> Bool {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if !argument.hasPrefix("-") {
                return nonInteractiveSubcommands.contains(argument)
            }
            let shortOption = String(argument.prefix(2))
            let option = valueOptions.contains(shortOption)
                ? shortOption
                : String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            if valueOptions.contains(option) {
                if argument == option { index += 1 }
            } else if !switchOptions.contains(option) {
                return false
            }
            index += 1
        }
        return false
    }

    /// Parses a `KERN_PROCARGS2` buffer: argc, the executable path, padding,
    /// argv, then environment strings, all NUL-terminated.
    static func parseProcArgs(_ buffer: [UInt8]) -> ProcessImage? {
        guard buffer.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc >= 0, argc < 65_536 else { return nil }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            guard index < buffer.count else { return nil }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        guard let executable = nextString() else { return nil }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while index < buffer.count, buffer[index] != 0, let entry = nextString() {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            if environment[key] == nil {
                environment[key] = String(entry[entry.index(after: separator)...])
            }
        }
        return ProcessImage(executable: executable, arguments: arguments, environment: environment)
    }

    private static func codexPids() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0 else { return false }
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
            return String(cString: name) == "codex"
        }
    }

    /// The kernel's record of the executable. argv[0] and the exec path in
    /// `KERN_PROCARGS2` live in memory the process itself can rewrite.
    private static func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a macro Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    private static func processImage(pid: pid_t) -> ProcessImage? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    private static func openVnodePaths(pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let used = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard used > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size
            else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}
