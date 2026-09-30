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
