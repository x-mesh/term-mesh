import Foundation

/// The cross-session inbox of a Claude Code session running in a terminal pane,
/// as that session's SessionStart hook reported it.
struct ClaudeInboxRecord: Equatable {
    let surfaceId: UUID
    let socketPath: String
    let token: String
    let sessionId: String
    let claudePid: Int32?
    let transcriptPath: String?
}

enum ClaudeInboxRegistrationError: Error, Equatable {
    case invalidSurfaceId
    case notInteractive(entrypoint: String)
    case invalidSocketPath
    case invalidToken
    case missingSessionId
    case invalidPid
    case invalidTranscriptPath
}

/// Inbox records keyed by the pane they were reported from.
///
/// The token lets its holder post into that session as the session itself, so
/// records stay in memory only: never persisted, never logged.
final class ClaudeInboxRegistry {
    static let shared = ClaudeInboxRegistry()

    // Darwin's sockaddr_un.sun_path is 104 bytes including the terminating NUL.
    static let maxSocketPathBytes = 103
    static let maxTokenLength = 512

    private let lock = NSLock()
    private var records: [UUID: ClaudeInboxRecord] = [:]

    init() {}

    func register(_ record: ClaudeInboxRecord) {
        lock.lock()
        defer { lock.unlock() }
        records[record.surfaceId] = record
    }

    func record(for surfaceId: UUID) -> ClaudeInboxRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[surfaceId]
    }

    @discardableResult
    func remove(surfaceId: UUID) -> ClaudeInboxRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.removeValue(forKey: surfaceId)
    }

    static func record(from params: [String: Any]) -> Result<ClaudeInboxRecord, ClaudeInboxRegistrationError> {
        guard let rawSurface = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: rawSurface) else {
            return .failure(.invalidSurfaceId)
        }
        // A `claude -p` run from a worker's shell inherits the pane's surface
        // env and fires SessionStart too; registering it would point the pane
        // at a short-lived subprocess instead of the TUI session.
        let entrypoint = params["entrypoint"] as? String ?? ""
        guard entrypoint == "cli" else {
            return .failure(.notInteractive(entrypoint: entrypoint))
        }
        guard let socketPath = params["socket_path"] as? String,
              socketPath.hasPrefix("/"),
              !socketPath.split(separator: "/").contains(".."),
              socketPath.utf8.count <= maxSocketPathBytes else {
            return .failure(.invalidSocketPath)
        }
        guard let token = params["token"] as? String,
              !token.isEmpty,
              token.count <= maxTokenLength,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .failure(.invalidToken)
        }
        guard let sessionId = params["session_id"] as? String, !sessionId.isEmpty else {
            return .failure(.missingSessionId)
        }
        let claudePid: Int32?
        switch params["claude_pid"] {
        case nil:
            claudePid = nil
        case let value as Int where value > 0 && value <= Int(Int32.max):
            claudePid = Int32(value)
        case let value as String:
            guard let parsed = Int32(value), parsed > 0 else { return .failure(.invalidPid) }
            claudePid = parsed
        default:
            return .failure(.invalidPid)
        }
        let transcriptPath = params["transcript_path"] as? String
        if let transcriptPath, !transcriptPath.hasPrefix("/") {
            return .failure(.invalidTranscriptPath)
        }
        return .success(ClaudeInboxRecord(
            surfaceId: surfaceId,
            socketPath: socketPath,
            token: token,
            sessionId: sessionId,
            claudePid: claudePid,
            transcriptPath: transcriptPath
        ))
    }
}
