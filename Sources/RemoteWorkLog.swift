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

    /// Past this, the file is truncated and starts again.
    ///
    /// It lives in `/tmp` and a machine that stays connected for a week would
    /// otherwise grow one without limit. Truncating rather than rotating is
    /// deliberate: what this is read for is the last few minutes before
    /// something broke, and a second file to go looking through is a cost with
    /// no matching benefit.
    private static let maxFileBytes: UInt64 = 8 * 1024 * 1024

    private static func append(_ message: String) {
        let stamp = stampFormatter.string(from: Date())
        queue.async {
            guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            if let size = try? handle.seekToEnd(), size > maxFileBytes {
                try? handle.truncate(atOffset: 0)
            }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
