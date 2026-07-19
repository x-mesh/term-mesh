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
    @MainActor static var sink: ((String) -> Void)?

    @MainActor static var level: RemoteWorkLogLevel = .info

    /// Tag-isolated like the daemon's own log, so parallel dev builds do not
    /// interleave.
    static var path: String {
        let tag = ProcessInfo.processInfo.environment["TERMMESH_TAG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tag.isEmpty ? "/tmp/term-mesh-remote-work.log" : "/tmp/term-mesh-remote-work-\(tag).log"
    }

    /// A line the user should see regardless of level.
    @MainActor static func info(_ message: String) { emit(message, at: .info) }

    /// Detail that only matters when something is being diagnosed.
    @MainActor static func debug(_ message: String) { emit(message, at: .debug) }

    @MainActor
    private static func emit(_ message: String, at messageLevel: RemoteWorkLogLevel) {
        // The file keeps everything: the level is about how much to show, not
        // how much to record, and a failure is usually read after the fact.
        append("[\(messageLevel.rawValue)] \(message)")
        #if DEBUG
        dlog("remotework.\(message)")
        #endif
        guard messageLevel == .info || level == .debug else { return }
        sink?(message)
    }

    private static let queue = DispatchQueue(label: "com.termmesh.remote-work-log")

    private static func append(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
