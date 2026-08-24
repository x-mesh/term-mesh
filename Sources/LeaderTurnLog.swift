import CryptoKit
import Darwin
import Foundation

/// Append-only leader turn measurements shared by the app and CLI.
enum LeaderTurnLog {
    enum Event: String, Codable, CaseIterable {
        case turnStart = "turn_start"
        case turnRoute = "turn_route"
        case turnEnd = "turn_end"
    }

    struct Record: Codable, Equatable {
        let event: Event
        let turnID: String
        let timestamp: String
        let team: String
        let surfaceID: String
        let promptBytes: Int?
        let promptSHA256: String?

        private enum CodingKeys: String, CodingKey {
            case event
            case turnID = "turn_id"
            case timestamp = "ts"
            case team
            case surfaceID = "surface_id"
            case promptBytes = "prompt_bytes"
            case promptSHA256 = "prompt_sha256"
        }

        private init(
            event: Event,
            turnID: String,
            timestamp: String,
            team: String,
            surfaceID: String,
            promptBytes: Int?,
            promptSHA256: String?
        ) {
            self.event = event
            self.turnID = turnID
            self.timestamp = timestamp
            self.team = team
            self.surfaceID = surfaceID
            self.promptBytes = promptBytes
            self.promptSHA256 = promptSHA256
        }

        static func turnStart(
            team: String,
            surfaceID: String,
            prompt: String,
            sessionID: String? = nil,
            timestamp: Date = Date()
        ) -> Record {
            let promptHash = LeaderTurnLog.promptSHA256(prompt)
            return Record(
                event: .turnStart,
                turnID: LeaderTurnLog.turnID(
                    sessionID: sessionID,
                    surfaceID: surfaceID,
                    promptSHA256: promptHash
                ),
                timestamp: LeaderTurnLog.timestamp(timestamp),
                team: team,
                surfaceID: surfaceID,
                promptBytes: prompt.utf8.count,
                promptSHA256: promptHash
            )
        }

        static func turnEnd(
            team: String,
            surfaceID: String,
            prompt: String,
            sessionID: String? = nil,
            timestamp: Date = Date()
        ) -> Record {
            let promptHash = LeaderTurnLog.promptSHA256(prompt)
            return Record(
                event: .turnEnd,
                turnID: LeaderTurnLog.turnID(
                    sessionID: sessionID,
                    surfaceID: surfaceID,
                    promptSHA256: promptHash
                ),
                timestamp: LeaderTurnLog.timestamp(timestamp),
                team: team,
                surfaceID: surfaceID,
                promptBytes: nil,
                promptSHA256: nil
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            event = try container.decode(Event.self, forKey: .event)
            turnID = try container.decode(String.self, forKey: .turnID)
            timestamp = try container.decode(String.self, forKey: .timestamp)
            team = try container.decode(String.self, forKey: .team)
            // Absent, not empty: the Rust writer omits surface_id entirely when
            // TERMMESH_SURFACE_ID is unset, so requiring it here would make
            // readAll drop those turn_route lines — and readAll swallows decode
            // failures, so the loss would be silent and would look exactly like
            // a leader that never reported a route.
            surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID) ?? ""

            switch event {
            case .turnStart:
                promptBytes = try container.decodeIfPresent(Int.self, forKey: .promptBytes)
                promptSHA256 = try container.decodeIfPresent(String.self, forKey: .promptSHA256)
            case .turnRoute, .turnEnd:
                promptBytes = nil
                promptSHA256 = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(event, forKey: .event)
            try container.encode(turnID, forKey: .turnID)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(team, forKey: .team)
            if !surfaceID.isEmpty {
                try container.encode(surfaceID, forKey: .surfaceID)
            }
            if event == .turnStart {
                try container.encode(promptBytes, forKey: .promptBytes)
                try container.encode(promptSHA256, forKey: .promptSHA256)
            }
        }
    }

    enum AppendError: Error {
        case openFailed(Int32)
        case writeFailed(expected: Int, actual: Int, errno: Int32)
    }

    static let logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".term-mesh/logs", isDirectory: true)

    /// Keep the .log extension: term-meshd's GC rotates only files whose
    /// extension is exactly log, even though this file's content is JSONL.
    static let logFile = logDirectory.appendingPathComponent("turns.log")

    static func promptSHA256(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Pure cross-process identity: first 16 lowercase hex characters of
    /// SHA-256(UTF8(discriminator + ":" + prompt_sha256)).
    ///
    /// The discriminator MUST match `scripts/leader-turn-hook.sh`, which is the
    /// writer that actually produces `turn_start`/`turn_end` today: it prefers
    /// the CLI session ID from the hook payload and falls back to the surface
    /// ID only when the payload carries none. An implementation here that hard-
    /// coded the surface ID would derive a different ID for the same turn, and
    /// because the join is by `turn_id` alone the two records would simply
    /// never meet — no error, just a start with no route. Take the
    /// discriminator as a parameter so a caller cannot silently pick the wrong
    /// one, and let it carry the same preference order the hook uses.
    static func turnID(sessionID: String?, surfaceID: String, promptSHA256: String) -> String {
        let discriminator = (sessionID?.isEmpty == false) ? sessionID! : surfaceID
        let input = Data("\(discriminator):\(promptSHA256)".utf8)
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    /// The sole append entry point. The complete JSON object and trailing
    /// newline are assembled before opening the file and emitted in one write.
    /// Open by path and close on every call: term-meshd periodically rotates
    /// this log with rename, so retaining a handle would keep writing to the
    /// old inode until a later rotation unlinks it and silently loses records.
    static func append(_ record: Record, to logFile: URL = logFile) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)

        let descriptor = Darwin.open(
            logFile.path,
            O_WRONLY | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw AppendError.openFailed(errno) }
        defer { Darwin.close(descriptor) }

        let written = line.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == line.count else {
            throw AppendError.writeFailed(expected: line.count, actual: written, errno: errno)
        }
    }

    /// Inspection helper. A final segment without a newline is considered torn,
    /// and malformed complete lines are skipped independently.
    static func readAll(from logFile: URL = logFile) -> [Record] {
        guard let data = try? Data(contentsOf: logFile), !data.isEmpty else { return [] }
        var lines = data.split(separator: 0x0A)
        if data.last != 0x0A {
            lines.removeLast()
        }
        let decoder = JSONDecoder()
        return lines.compactMap { line in
            try? decoder.decode(Record.self, from: Data(line))
        }
    }

    static func countsByEvent(from logFile: URL = logFile) -> [Event: Int] {
        Dictionary(grouping: readAll(from: logFile), by: \.event).mapValues(\.count)
    }

    private static func timestamp(_ date: Date) -> String {
        // Whole seconds, matching the shell hook (`date -u +%Y-%m-%dT%H:%M:%SZ`)
        // and the Rust writer (`iso8601_utc_now`). Fractional seconds here would
        // make one dataset carry two `ts` shapes, breaking string ordering and
        // equality across writers for no gain at this resolution.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
