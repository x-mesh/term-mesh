import Bonsplit
import Foundation

/// How much the remote-work path says about what it is doing.
enum RemoteWorkLogLevel: String, CaseIterable, Identifiable {
    /// Only what the user needs: a step succeeded, or why one refused.
    case info
    /// Every decision with its inputs — which pane, which paths, which guard
    /// rejected and what it saw.
    case debug

    var id: String { rawValue }
    var label: String { self == .info ? "Info" : "Debug" }
}

/// How urgently a Live Activity line needs attention.
enum RemoteWorkLogSeverity: String, Hashable, Sendable {
    case info
    case warning
    case error
}

/// Progress and failures of the remote-work (git checkpoint) path.
///
/// This path used to fail invisibly: a guard set `errorMessage`, the drawer
/// rendered that only inside the close-confirmation sheet, and a button press
/// therefore looked like nothing had happened at all. Everything now goes to
/// three places at once — the Live Activity list the user is already watching,
/// a file for after the fact, and the shared debug log.
///
/// The file is separate from the app's debug log on purpose: that one is a
/// 500-entry ring that layout tracing floods, so a handful of lines are gone
/// before anyone can read them.
enum RemoteWorkLog {
    /// Receives every emitted line, for the Live Activity list. Set by the
    /// workspace that owns the drawer.
    @MainActor static var sink: ((String, RemoteWorkLogSeverity) -> Void)?

    @MainActor static var level: RemoteWorkLogLevel = .info

    /// Tag-isolated like the daemon's own log, so parallel dev builds do not
    /// interleave.
    static var path: String {
        // A test run writes here too, and it is the same file the installed
        // app is using — a suite exercising mock hosts and `example.invalid`
        // tunnels lands its lines in the middle of the log someone is reading
        // to diagnose a live machine. `TERMMESH_TAG` isolates a tagged dev
        // build, but no test sets one, so isolate on the signal XCTest itself
        // provides.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            return "/tmp/term-mesh-remote-work-tests.log"
        }
        let tag = ProcessInfo.processInfo.environment["TERMMESH_TAG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tag.isEmpty ? "/tmp/term-mesh-remote-work.log" : "/tmp/term-mesh-remote-work-\(tag).log"
    }

    /// A line the user should see regardless of level.
    @MainActor static func info(_ message: String) {
        emit(message, at: .info, severity: .info)
    }

    /// A condition that needs attention but has not yet proved the operation failed.
    @MainActor static func warning(_ message: String) {
        emit(message, at: .info, severity: .warning)
    }

    /// A failed operation. Always visible at every log level.
    @MainActor static func error(_ message: String) {
        emit(message, at: .info, severity: .error)
    }

    /// Detail that only matters when something is being diagnosed.
    @MainActor static func debug(_ message: String) {
        emit(message, at: .debug, severity: .info)
    }

    /// `info`, from a thread that is not the main one.
    ///
    /// The paths worth watching most — the SSH tunnel, the relay pump, a file
    /// being copied to a peer — all run off the main actor, while the list
    /// these lines feed lives on it. The file leg is written right here so the
    /// recorded order still matches the order things happened; only the
    /// on-screen leg hops, and it hops per line rather than in a batch so a
    /// hang mid-sequence still shows everything up to it.
    nonisolated static func infoOffMain(_ message: String) {
        emitOffMain(message, at: .info, severity: .info)
    }

    nonisolated static func warningOffMain(_ message: String) {
        emitOffMain(message, at: .info, severity: .warning)
    }

    nonisolated static func errorOffMain(_ message: String) {
        emitOffMain(message, at: .info, severity: .error)
    }

    /// `debug`, from a thread that is not the main one.
    nonisolated static func debugOffMain(_ message: String) {
        emitOffMain(message, at: .debug, severity: .info)
    }

    @MainActor
    private static func emit(
        _ message: String,
        at messageLevel: RemoteWorkLogLevel,
        severity: RemoteWorkLogSeverity
    ) {
        // The file keeps everything: the level is about how much to show, not
        // how much to record, and a failure is usually read after the fact.
        append("[\(messageLevel.rawValue)] [\(severity.rawValue)] \(message)")
        #if DEBUG
        dlog("remotework.\(message)")
        #endif
        guard messageLevel == .info || level == .debug else { return }
        sink?(message, severity)
    }

    nonisolated private static func emitOffMain(
        _ message: String,
        at messageLevel: RemoteWorkLogLevel,
        severity: RemoteWorkLogSeverity
    ) {
        append("[\(messageLevel.rawValue)] [\(severity.rawValue)] \(message)")
        #if DEBUG
        dlog("remotework.\(message)")
        #endif
        Task { @MainActor in
            guard messageLevel == .info || level == .debug else { return }
            sink?(message, severity)
        }
    }

    private static let queue = DispatchQueue(label: "com.termmesh.remote-work-log")

    /// Built once. A formatter per line was affordable when only the
    /// checkpoint path wrote here; now that every tunnel transition and every
    /// dropped-output gap does, it is not.
    private static let stampFormatter = ISO8601DateFormatter()

    /// Past this, the oldest half of the file is dropped.
    ///
    /// It lives in `/tmp` and a machine that stays connected for a week would
    /// otherwise grow one without limit. A second file to go looking through
    /// is a cost with no matching benefit, so this rewrites in place rather
    /// than rotating — but it keeps the newer half. Truncating to zero, which
    /// is what this used to do, throws away every line at the moment the file
    /// fills: the reader arrives just after the wipe and finds nothing, which
    /// is the worst possible time for the log to be empty.
    private static let maxFileBytes: UInt64 = 8 * 1024 * 1024

    /// Consecutive identical messages are counted, not repeated.
    ///
    /// Two individually reasonable decisions collide here: the file records
    /// every level because "the level is about how much to show, not how much
    /// to record", and `SessionHostPanes` polls the local daemon every 15
    /// seconds, each pass opening a connection whose handshake logs one line
    /// at debug. Measured on a live machine, that one line was **99% of a 7.4
    /// MB log** — a budget whose overflow then discards everything, spent
    /// almost entirely on a sentence already known to be the same.
    ///
    /// Counting rather than suppressing keeps what a repeat actually carries:
    /// that it is still happening, and how often. The tally is flushed when
    /// the message changes, so the run is closed by the line that follows it.
    private static var lastMessage: String?
    private static var repeatCount = 0
    /// Flush a run this long even while it continues, so a repeat that lasts
    /// hours still leaves a trace inside the window a reader is looking at
    /// rather than only when it finally stops.
    static let maxSuppressedRepeats = 200

    private static func append(_ message: String) {
        let stamp = stampFormatter.string(from: Date())
        queue.async {
            if message == lastMessage {
                repeatCount += 1
                guard repeatCount >= maxSuppressedRepeats else { return }
                writeLine("\(stamp) [repeat] last message ×\(repeatCount)")
                repeatCount = 0
                return
            }
            if repeatCount > 0 {
                writeLine("\(stamp) [repeat] previous message ×\(repeatCount)")
            }
            lastMessage = message
            repeatCount = 0
            writeLine("\(stamp) \(message)")
        }
    }

    /// Serialized by `queue`; never call directly.
    private static func writeLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > maxFileBytes {
            dropOldestHalf(handle, size: size)
        }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    /// Keep the newer half, cut at a line boundary.
    ///
    /// Reading half the cap into memory is affordable at this size and happens
    /// once per fill. A mid-line cut would leave a first line that parses as
    /// something it is not, so the surviving text starts after the first
    /// newline it contains.
    private static func dropOldestHalf(_ handle: FileHandle, size: UInt64) {
        let keep = maxFileBytes / 2
        guard (try? handle.seek(toOffset: size - keep)) != nil,
              let tail = try? handle.readToEnd(), !tail.isEmpty
        else {
            try? handle.truncate(atOffset: 0)
            return
        }
        let kept = tailAfterFirstPartialLine(tail)
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        handle.write(kept)
    }

    /// Drop everything up to and including the first newline.
    ///
    /// A cut at a byte offset lands mid-line, and the fragment left at the
    /// front would parse as a whole entry — a timestamp-less line, or worse a
    /// plausible one assembled from the tail of a message. Split out because
    /// that is the only judgement in the retention path, and it is not worth
    /// building an 8 MB file to check.
    nonisolated static func tailAfterFirstPartialLine(_ data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
        return data.subdata(in: data.index(after: newline)..<data.endIndex)
    }

    #if DEBUG
    /// Block until every queued line has reached the file. Tests only: the
    /// write is asynchronous, so reading the file without this races it.
    static func drainForTesting() { queue.sync {} }

    /// Consecutive-repeat state is process-wide, so one test's trailing run
    /// would otherwise be counted into the next test's first line.
    static func resetRepeatStateForTesting() {
        queue.sync {
            lastMessage = nil
            repeatCount = 0
        }
    }
    #endif
}
