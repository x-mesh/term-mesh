import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ClaudeInboxDeliveryTests: XCTestCase {

    private let surface = UUID()

    private func params(_ overrides: [String: Any?] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "surface_id": surface.uuidString,
            "socket_path": "/tmp/cc-socks/67515.sock",
            "token": String(repeating: "a", count: 64),
            "session_id": "14adb8a2-baf0-4435-9eaa-2a95cbc4490c",
            "entrypoint": "cli",
            "claude_pid": "67515",
            "transcript_path": "/Users/me/.claude/projects/x/14adb8a2.jsonl",
        ]
        for (key, value) in overrides {
            if let value { base[key] = value } else { base.removeValue(forKey: key) }
        }
        return base
    }

    private func error(_ params: [String: Any]) -> ClaudeInboxRegistrationError? {
        if case .failure(let error) = ClaudeInboxRegistry.record(from: params) { return error }
        return nil
    }

    func testAcceptsWhatAnInteractiveSessionStartReports() throws {
        let record = try ClaudeInboxRegistry.record(from: params()).get()
        XCTAssertEqual(record.surfaceId, surface)
        XCTAssertEqual(record.socketPath, "/tmp/cc-socks/67515.sock")
        XCTAssertEqual(record.sessionId, "14adb8a2-baf0-4435-9eaa-2a95cbc4490c")
        XCTAssertEqual(record.claudePid, 67515)
        XCTAssertEqual(record.transcriptPath, "/Users/me/.claude/projects/x/14adb8a2.jsonl")
    }

    func testPrintModeSessionFromAWorkersShellIsNotRegistered() {
        XCTAssertEqual(error(params(["entrypoint": "sdk-cli"])), .notInteractive(entrypoint: "sdk-cli"))
        XCTAssertEqual(error(params(["entrypoint": nil])), .notInteractive(entrypoint: ""))
    }

    func testRejectsSocketPathsThatCannotNameALocalInbox() {
        XCTAssertEqual(error(params(["socket_path": "cc-socks/1.sock"])), .invalidSocketPath)
        XCTAssertEqual(error(params(["socket_path": "/tmp/cc-socks/../x.sock"])), .invalidSocketPath)
        let tooLong = "/tmp/" + String(repeating: "s", count: ClaudeInboxRegistry.maxSocketPathBytes)
        XCTAssertEqual(error(params(["socket_path": tooLong])), .invalidSocketPath)
        XCTAssertEqual(error(params(["socket_path": nil])), .invalidSocketPath)
    }

    func testRejectsTokensThatCouldNotBeAnAuthLine() {
        XCTAssertEqual(error(params(["token": ""])), .invalidToken)
        XCTAssertEqual(error(params(["token": "abc\ndef"])), .invalidToken)
        let tooLong = String(repeating: "t", count: ClaudeInboxRegistry.maxTokenLength + 1)
        XCTAssertEqual(error(params(["token": tooLong])), .invalidToken)
    }

    func testRejectsMalformedIdentity() {
        XCTAssertEqual(error(params(["surface_id": "not-a-uuid"])), .invalidSurfaceId)
        XCTAssertEqual(error(params(["session_id": ""])), .missingSessionId)
        XCTAssertEqual(error(params(["claude_pid": "0"])), .invalidPid)
        XCTAssertEqual(error(params(["claude_pid": "abc"])), .invalidPid)
        XCTAssertEqual(error(params(["transcript_path": "relative.jsonl"])), .invalidTranscriptPath)
    }

    func testPidIsOptionalAndAcceptsANumber() throws {
        XCTAssertNil(try ClaudeInboxRegistry.record(from: params(["claude_pid": nil])).get().claudePid)
        XCTAssertEqual(try ClaudeInboxRegistry.record(from: params(["claude_pid": 42])).get().claudePid, 42)
    }

    func testALaterSessionInTheSamePaneReplacesTheRecord() throws {
        let registry = ClaudeInboxRegistry()
        let first = try ClaudeInboxRegistry.record(from: params()).get()
        let second = try ClaudeInboxRegistry.record(from: params([
            "socket_path": "/tmp/cc-socks/70000.sock",
            "session_id": "second-session",
        ])).get()
        registry.register(first)
        registry.register(second)
        XCTAssertEqual(registry.record(for: surface), second)
    }

    func testDeliveryIsOffUnlessTheOptionIsSet() throws {
        let suite = "ClaudeInboxDeliveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ClaudeInboxDelivery.isEnabled(defaults: defaults))
        defaults.set(true, forKey: ClaudeInboxDelivery.enabledKey)
        XCTAssertTrue(ClaudeInboxDelivery.isEnabled(defaults: defaults))
    }

    func testWorkerLaunchHookRegistersThroughThisAppsCLI() throws {
        let json = ClaudeInboxDelivery.registerHookSettingsJSON
        XCTAssertFalse(json.contains("'"), "the settings are passed inside single quotes on the launch line")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let entry = try XCTUnwrap((sessionStart.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["command"] as? String,
                       "\"$TERMMESH_APP_BIN/term-mesh\" claude-hook inbox-register")
    }

    func testWorkersAreToldHowLeaderMessagesArrive() {
        let combined = ClaudeInboxDelivery.workerSystemPrompt(roleInstructions: "ROLE PRESET")
        XCTAssertTrue(combined.hasPrefix("ROLE PRESET\n\n"))
        XCTAssertTrue(combined.hasSuffix(ClaudeInboxDelivery.workerChannelNote))
        XCTAssertEqual(ClaudeInboxDelivery.workerSystemPrompt(roleInstructions: ""),
                       ClaudeInboxDelivery.workerChannelNote)
        let note = ClaudeInboxDelivery.workerChannelNote
        XCTAssertTrue(note.contains("Another Claude session sent a message"),
                      "the note must name the framing the worker will actually see")
        XCTAssertTrue(note.contains("cannot approve a permission prompt"),
                      "authority for tasks must not extend to permission prompts")
    }

    // MARK: - Delivery

    func testMessageOpensWithTheAuthLineAndKeepsTheTextVerbatim() throws {
        let text = "line one\n\"quoted\" <tag> & 한글\nline three"
        let data = try ClaudeInboxDelivery.messageLines(token: "tok", text: text, messageId: "m-1")
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2)
        let auth = try XCTUnwrap(JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
        XCTAssertEqual(auth["type"] as? String, "auth")
        XCTAssertEqual(auth["token"] as? String, "tok")
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: lines[1]) as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "user")
        XCTAssertEqual(message["msg_id"] as? String, "m-1")
        XCTAssertNil(message["from"], "a from address would make the receiver hold the message")
        let body = try XCTUnwrap(message["message"] as? [String: Any])
        XCTAssertEqual(body["content"] as? String, text)
    }

    func testPostReachesAListeningInbox() throws {
        let inbox = try FakeInbox()
        let received = inbox.readOnce()
        try ClaudeInboxDelivery.post(Data("hello\n".utf8), toSocket: inbox.path)
        XCTAssertEqual(received.wait(), Data("hello\n".utf8))
    }

    func testPostToAMissingSocketThrows() {
        XCTAssertThrowsError(try ClaudeInboxDelivery.post(Data("x".utf8), toSocket: "/tmp/cib-missing-\(UUID().uuidString.prefix(8)).sock"))
    }

    func testDeliveredOnlyWhenTheTranscriptRecordsTheEnqueue() throws {
        let inbox = try FakeInbox()
        let transcript = try temporaryTranscript()
        let record = try inboxRecord(socket: inbox.path, transcript: transcript.path)
        let text = "TASK: build it\nsecond line"
        let received = inbox.readOnce { _ in
            Self.append(transcript, ["type": "queue-operation", "operation": "enqueue", "content": text])
        }
        let outcome = ClaudeInboxDelivery.deliverNow(
            text: text, to: record, sessionsDirectory: try sessionsDirectory(), confirmTimeout: 2)
        XCTAssertEqual(outcome, .delivered)
        XCTAssertFalse(received.wait().isEmpty)
    }

    func testASilentSessionLeavesTheDeliveryUnconfirmedRatherThanFailed() throws {
        let inbox = try FakeInbox()
        let transcript = try temporaryTranscript()
        let record = try inboxRecord(socket: inbox.path, transcript: transcript.path)
        let received = inbox.readOnce()
        let outcome = ClaudeInboxDelivery.deliverNow(
            text: "held", to: record, sessionsDirectory: try sessionsDirectory(), confirmTimeout: 0.3)
        XCTAssertEqual(outcome, .unconfirmed("not_enqueued"))
        XCTAssertFalse(received.wait().isEmpty)
    }

    func testAHoldNoticeEndsTheWaitAsUnconfirmed() throws {
        let inbox = try FakeInbox()
        let transcript = try temporaryTranscript()
        let record = try inboxRecord(socket: inbox.path, transcript: transcript.path)
        let received = inbox.readOnce { _ in
            Self.append(transcript, [
                "type": "system", "subtype": "informational",
                "content": "Held peer message — from an unidentified session; preview: «## Task» — not delivered to Claude (1 held).",
            ])
        }
        let started = Date()
        let outcome = ClaudeInboxDelivery.deliverNow(
            text: "## Task\nbody", to: record, sessionsDirectory: try sessionsDirectory(), confirmTimeout: 5)
        XCTAssertEqual(outcome, .unconfirmed("held_for_approval"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the hold notice should end the wait early")
        XCTAssertFalse(received.wait().isEmpty)
    }

    func testAnEnqueueWrittenBeforeTheSendIsNotConfirmation() throws {
        let transcript = try temporaryTranscript()
        Self.append(transcript, ["type": "queue-operation", "operation": "enqueue", "content": "same"])
        let offset = ClaudeInboxDelivery.fileSize(atPath: transcript.path)
        XCTAssertEqual(ClaudeInboxDelivery.transcriptVerdict(
            of: "same", atPath: transcript.path, after: offset, timeout: 0.2), .silent)
        Self.append(transcript, ["type": "queue-operation", "operation": "enqueue", "content": "same"])
        XCTAssertEqual(ClaudeInboxDelivery.transcriptVerdict(
            of: "same", atPath: transcript.path, after: offset, timeout: 0.2), .enqueued)
    }

    func testMissingSocketIsNotDeliveredWithoutWaitingForTheTranscript() throws {
        let transcript = try temporaryTranscript()
        let record = try inboxRecord(socket: "/tmp/cib-missing-\(UUID().uuidString.prefix(8)).sock", transcript: transcript.path)
        let outcome = ClaudeInboxDelivery.deliverNow(
            text: "x", to: record, sessionsDirectory: try sessionsDirectory(), confirmTimeout: 5)
        guard case .notDelivered(let reason) = outcome else { return XCTFail("expected notDelivered, got \(outcome)") }
        XCTAssertTrue(reason.hasPrefix("post:"), reason)
    }

    func testQuarantineHoldsUntilTheSessionRegistersAgain() throws {
        let registry = ClaudeInboxRegistry()
        let record = try ClaudeInboxRegistry.record(from: params()).get()
        registry.register(record)
        registry.quarantine(record)
        XCTAssertTrue(registry.isQuarantined(surfaceId: surface))
        XCTAssertEqual(registry.record(for: surface), record, "the record stays so no Return is owed")
        let restarted = try ClaudeInboxRegistry.record(from: params(["session_id": "after-clear"])).get()
        registry.register(restarted)
        XCTAssertFalse(registry.isQuarantined(surfaceId: surface))
    }

    func testQuarantiningAReplacedRecordDoesNothing() throws {
        let registry = ClaudeInboxRegistry()
        let old = try ClaudeInboxRegistry.record(from: params()).get()
        let new = try ClaudeInboxRegistry.record(from: params(["session_id": "newer"])).get()
        registry.register(new)
        registry.quarantine(old)
        XCTAssertFalse(registry.isQuarantined(surfaceId: surface))
    }

    func testARecordIsStaleOnlyWhenItsProcessRunsAnotherSession() throws {
        let directory = try sessionsDirectory()
        let record = try inboxRecord(socket: "/tmp/x.sock", transcript: "/tmp/t.jsonl")
        let entry = directory.appendingPathComponent("67515.json")
        try FileManager.default.removeItem(at: entry)
        XCTAssertFalse(ClaudeInboxDelivery.isStale(record, sessionsDirectory: directory),
                       "team agents bind an inbox without writing a registry entry")
        try Data(#"{"sessionId":"other"}"#.utf8).write(to: entry)
        XCTAssertTrue(ClaudeInboxDelivery.isStale(record, sessionsDirectory: directory))
        try Data(#"{"sessionId":"14adb8a2-baf0-4435-9eaa-2a95cbc4490c"}"#.utf8).write(to: entry)
        XCTAssertFalse(ClaudeInboxDelivery.isStale(record, sessionsDirectory: directory))
        try Data("not json".utf8).write(to: entry)
        XCTAssertFalse(ClaudeInboxDelivery.isStale(record, sessionsDirectory: directory), "unreadable is not evidence")
    }

    func testRemoveIfCurrentKeepsARecordALaterSessionReplaced() throws {
        let registry = ClaudeInboxRegistry()
        let old = try ClaudeInboxRegistry.record(from: params()).get()
        let new = try ClaudeInboxRegistry.record(from: params(["session_id": "newer"])).get()
        registry.register(new)
        registry.removeIfCurrent(old)
        XCTAssertEqual(registry.record(for: surface), new)
        registry.removeIfCurrent(new)
        XCTAssertNil(registry.record(for: surface))
    }

    // MARK: - Helpers

    private func inboxRecord(socket: String, transcript: String) throws -> ClaudeInboxRecord {
        try ClaudeInboxRegistry.record(from: params([
            "socket_path": socket, "transcript_path": transcript,
        ])).get()
    }

    private func sessionsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cib-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"sessionId":"14adb8a2-baf0-4435-9eaa-2a95cbc4490c"}"#.utf8)
            .write(to: directory.appendingPathComponent("67515.json"))
        return directory
    }

    private func temporaryTranscript() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cib-\(UUID().uuidString).jsonl")
        try Data(#"{"type":"user"}"#.utf8 + [0x0A]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static func append(_ url: URL, _ object: [String: Any]) {
        guard let handle = try? FileHandle(forWritingTo: url),
              let line = try? JSONSerialization.data(withJSONObject: object) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data([0x0A]))
        try? handle.close()
    }

    func testRecordsAreKeptPerPaneAndRemovable() throws {
        let registry = ClaudeInboxRegistry()
        let other = UUID()
        let mine = try ClaudeInboxRegistry.record(from: params()).get()
        let theirs = try ClaudeInboxRegistry.record(from: params(["surface_id": other.uuidString])).get()
        registry.register(mine)
        registry.register(theirs)
        XCTAssertEqual(registry.remove(surfaceId: surface), mine)
        XCTAssertNil(registry.record(for: surface))
        XCTAssertEqual(registry.record(for: other), theirs)
    }
}

/// A listening Unix socket that stands in for a Claude session's inbox.
private final class FakeInbox {
    let path: String
    private let fd: Int32

    init() throws {
        path = "/tmp/cib-\(UUID().uuidString.prefix(8)).sock"
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "FakeInbox", code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in
                for (offset, byte) in bytes.enumerated() { chars[offset] = CChar(bitPattern: byte) }
                chars[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, Darwin.listen(fd, 4) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: "FakeInbox", code: Int(code))
        }
    }

    deinit {
        Darwin.close(fd)
        unlink(path)
    }

    final class Received {
        private let semaphore = DispatchSemaphore(value: 0)
        fileprivate var data = Data()
        fileprivate func finish() { semaphore.signal() }

        func wait(timeout: TimeInterval = 5) -> Data {
            _ = semaphore.wait(timeout: .now() + timeout)
            return data
        }
    }

    /// Accepts one connection and reads it to EOF. `onRead` runs before the
    /// read is reported, the way a session writes its transcript on receipt.
    func readOnce(onRead: ((Data) -> Void)? = nil) -> Received {
        let received = Received()
        let listener = fd
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { received.finish(); return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(client, &buffer, buffer.count)
                if count <= 0 { break }
                received.data.append(contentsOf: buffer[0..<count])
            }
            Darwin.close(client)
            onRead?(received.data)
            received.finish()
        }
        return received
    }
}
