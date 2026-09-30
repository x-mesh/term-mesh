import Foundation

enum ClaudeInboxDelivery {
    static let enabledKey = "claudeInbox.enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    // Team agents are launched by the resolved claude binary, not through
    // Resources/bin/claude, so its SessionStart hook never runs for them.
    // `$TERMMESH_APP_BIN` names this app's CLI; a PATH lookup can reach another
    // installed build that talks to a different socket.
    static let registerHookSettingsJSON = "{\"hooks\":{\"SessionStart\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"\\\"$TERMMESH_APP_BIN/term-mesh\\\" claude-hook inbox-register\",\"timeout\":10}]}]}}"

    enum Outcome: Equatable {
        case delivered
        /// The session provably did not take the message; typing it instead is safe.
        case notDelivered(String)
        /// The message was written but its fate is unknown: it may be held
        /// behind an approval dialog that would swallow a paste, or accepted
        /// late, which a paste would duplicate. Neither allows a fallback.
        case unconfirmed(String)
    }

    enum PostError: Error, Equatable {
        case socketPathTooLong
        case syscall(String, Int32)
    }

    enum TranscriptVerdict: Equatable {
        case enqueued
        case held
        case silent
    }

    static let enqueueConfirmTimeout: TimeInterval = 3
    static let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    static func deliver(text: String, to record: ClaudeInboxRecord, completion: @escaping @MainActor (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = deliverNow(text: text, to: record)
            Task { @MainActor in completion(outcome) }
        }
    }

    /// A write that succeeds proves nothing: a receiver that does not accept the
    /// token holds the message for its user and says so only on its own screen.
    /// The session's transcript records an `enqueue` the moment the message is
    /// accepted, idle or mid-turn, so that is what counts as delivered.
    static func deliverNow(
        text: String,
        to record: ClaudeInboxRecord,
        sessionsDirectory: URL = sessionsDirectory,
        confirmTimeout: TimeInterval = enqueueConfirmTimeout
    ) -> Outcome {
        if isStale(record, sessionsDirectory: sessionsDirectory) {
            return .notDelivered("stale_session")
        }
        guard let transcriptPath = record.transcriptPath else {
            return .notDelivered("no_transcript_path")
        }
        let offset = fileSize(atPath: transcriptPath)
        do {
            let payload = try messageLines(token: record.token, text: text, messageId: UUID().uuidString)
            try post(payload, toSocket: record.socketPath)
        } catch {
            return .notDelivered("post: \(error)")
        }
        switch transcriptVerdict(of: text, atPath: transcriptPath, after: offset, timeout: confirmTimeout) {
        case .enqueued: return .delivered
        case .held: return .unconfirmed("held_for_approval")
        case .silent: return .unconfirmed("not_enqueued")
        }
    }

    static func messageLines(token: String, text: String, messageId: String) throws -> Data {
        let auth = try JSONSerialization.data(withJSONObject: ["type": "auth", "token": token])
        let message = try JSONSerialization.data(withJSONObject: [
            "msgV": 1,
            "msg_id": messageId,
            "type": "user",
            "message": ["role": "user", "content": text],
        ] as [String: Any])
        return auth + Data([0x0A]) + message + Data([0x0A])
    }

    /// The pid in a record can outlive its session: `/clear` starts a new
    /// session in the same process, and a reused pid can name a different one.
    /// Only an entry naming a different session counts as stale. A missing or
    /// unreadable entry is not evidence: sessions started as team agents
    /// (`--agent-id`) bind an inbox but write no entry, and a process that
    /// exited fails the connect anyway.
    static func isStale(_ record: ClaudeInboxRecord, sessionsDirectory: URL) -> Bool {
        guard let pid = record.claudePid else { return false }
        let entry = sessionsDirectory.appendingPathComponent("\(pid).json")
        guard let data = FileManager.default.contents(atPath: entry.path) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = object["sessionId"] as? String else { return false }
        return sessionId != record.sessionId
    }

    static func post(_ payload: Data, toSocket socketPath: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PostError.syscall("socket", errno) }
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else { throw PostError.socketPathTooLong }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                for (offset, byte) in path.enumerated() {
                    bytes[offset] = CChar(bitPattern: byte)
                }
            }
        }
        let rc = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw PostError.syscall("connect", errno) }

        try payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: sent), buffer.count - sent)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PostError.syscall("write", errno)
                }
                sent += written
            }
        }
        Darwin.shutdown(fd, SHUT_WR)
    }

    static func fileSize(atPath path: String) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Reads what the session appended after `offset` until it either accepts
    /// the message or reports holding one. A held message's preview is cut, so
    /// any hold notice after our write is taken as ours: we just posted, and
    /// reading someone else's hold as ours only withholds a paste.
    static func transcriptVerdict(
        of content: String,
        atPath path: String,
        after offset: UInt64,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05
    ) -> TranscriptVerdict {
        let expected = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = Date().addingTimeInterval(timeout)
        var cursor = offset
        var pending = Data()
        while true {
            if let handle = FileHandle(forReadingAtPath: path) {
                if (try? handle.seek(toOffset: cursor)) != nil, let chunk = try? handle.readToEnd() {
                    cursor += UInt64(chunk.count)
                    pending.append(chunk)
                }
                try? handle.close()
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    if let verdict = verdict(for: line, expecting: expected) { return verdict }
                }
            }
            if Date() >= deadline { return .silent }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private static func verdict(for line: Data, expecting expected: String) -> TranscriptVerdict? {
        let mayEnqueue = line.range(of: Data("queue-operation".utf8)) != nil
        let mayHold = line.range(of: Data("Held peer message".utf8)) != nil
        guard mayEnqueue || mayHold,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        if object["type"] as? String == "queue-operation",
           object["operation"] as? String == "enqueue",
           let content = object["content"] as? String,
           content.trimmingCharacters(in: .whitespacesAndNewlines) == expected {
            return .enqueued
        }
        if object["type"] as? String == "system",
           (object["content"] as? String)?.hasPrefix("Held peer message") == true {
            return .held
        }
        return nil
    }
}

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
    private var quarantined: Set<UUID> = []

    init() {}

    func register(_ record: ClaudeInboxRecord) {
        lock.lock()
        defer { lock.unlock() }
        records[record.surfaceId] = record
        quarantined.remove(record.surfaceId)
    }

    /// After an unconfirmed delivery the pane may show an approval dialog that
    /// would swallow typed text, so neither the inbox nor a paste is safe until
    /// the session starts again and registers a fresh record.
    func quarantine(_ record: ClaudeInboxRecord) {
        lock.lock()
        defer { lock.unlock() }
        if records[record.surfaceId] == record {
            quarantined.insert(record.surfaceId)
        }
    }

    func isQuarantined(surfaceId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return quarantined.contains(surfaceId)
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
        quarantined.remove(surfaceId)
        return records.removeValue(forKey: surfaceId)
    }

    /// Drops a record only if no later SessionStart replaced it meanwhile.
    func removeIfCurrent(_ record: ClaudeInboxRecord) {
        lock.lock()
        defer { lock.unlock() }
        if records[record.surfaceId] == record {
            records.removeValue(forKey: record.surfaceId)
        }
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
