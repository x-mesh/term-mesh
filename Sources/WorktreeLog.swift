import Foundation

/// Persistent worktree log at ~/.term-mesh/logs/worktree.log.
/// Both the Rust daemon and Swift app append to the same file.
enum WorktreeLog {

    static let logDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".term-mesh/logs", isDirectory: true)
    }()

    static let logFile: URL = {
        logDir.appendingPathComponent("worktree.log")
    }()

    // MARK: - Write

    /// Append a timestamped line to the worktree log.
    static func log(_ message: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let ts = df.string(from: Date())

        let line = "[\(ts)] [swift] \(message)\n"
        if fm.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        } else {
            try? line.write(to: logFile, atomically: false, encoding: .utf8)
        }
    }

    // MARK: - Read

    /// Log file size in bytes (0 if missing).
    static var fileSize: UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path)
        return attrs?[.size] as? UInt64 ?? 0
    }

    /// Last modification date (nil if missing).
    static var lastModified: Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Number of lines in the log file.
    static var lineCount: Int {
        guard let data = try? String(contentsOf: logFile, encoding: .utf8) else { return 0 }
        return data.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
    }

    /// Read the last N lines.
    static func tail(_ n: Int = 50) -> String {
        guard let data = try? String(contentsOf: logFile, encoding: .utf8) else { return "" }
        let lines = data.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.suffix(n).joined(separator: "\n")
    }

    // MARK: - Manage

    /// Delete the log file.
    static func clear() {
        try? FileManager.default.removeItem(at: logFile)
    }

    /// Human-readable file size.
    static var fileSizeFormatted: String {
        let bytes = fileSize
        if bytes == 0 { return "Empty" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
