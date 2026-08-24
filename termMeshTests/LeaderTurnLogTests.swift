import Foundation
import CryptoKit
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class LeaderTurnLogTests: XCTestCase {
    private func temporaryLog() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeaderTurnLogTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("nested/turns.log")
    }

    func testAppendThenReadRoundTripAndCounts() throws {
        let log = try temporaryLog()
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let start = LeaderTurnLog.Record.turnStart(
            team: "alpha", surfaceID: "surface-1", prompt: "measure me", timestamp: date
        )
        let end = LeaderTurnLog.Record.turnEnd(
            team: "alpha", surfaceID: "surface-1", prompt: "measure me", timestamp: date
        )

        try LeaderTurnLog.append(start, to: log)
        try LeaderTurnLog.append(end, to: log)

        XCTAssertEqual(LeaderTurnLog.readAll(from: log), [start, end])
        XCTAssertEqual(LeaderTurnLog.countsByEvent(from: log), [.turnStart: 1, .turnEnd: 1])
        XCTAssertEqual(start.turnID, end.turnID)
    }

    func testConcurrentAppendsLoseNoLinesOrCreateTornLines() throws {
        let log = try temporaryLog()
        let queues = [DispatchQueue(label: "turn-log-a"), DispatchQueue(label: "turn-log-b")]
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [Error] = []
        let appendsPerQueue = 100

        for (queueIndex, queue) in queues.enumerated() {
            group.enter()
            queue.async {
                defer { group.leave() }
                for index in 0..<appendsPerQueue {
                    let record = LeaderTurnLog.Record.turnEnd(
                        team: "team-\(queueIndex)",
                        surfaceID: "surface-\(queueIndex)-\(index)",
                        prompt: "prompt-\(queueIndex)-\(index)"
                    )
                    do {
                        try LeaderTurnLog.append(record, to: log)
                    } catch {
                        lock.lock()
                        failures.append(error)
                        lock.unlock()
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(failures.isEmpty, "append failures: \(failures)")

        let bytes = try Data(contentsOf: log)
        XCTAssertEqual(bytes.last, 0x0A)
        XCTAssertEqual(bytes.filter { $0 == 0x0A }.count, appendsPerQueue * queues.count)
        let records = LeaderTurnLog.readAll(from: log)
        XCTAssertEqual(records.count, appendsPerQueue * queues.count)
        XCTAssertEqual(Set(records.map(\.turnID)).count, appendsPerQueue * queues.count)
    }

    func testMalformedAndTruncatedLinesAreSkipped() throws {
        let log = try temporaryLog()
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let bytes = """
        {"event":"turn_end","turn_id":"one","ts":"2026-08-24T00:00:00Z","team":"alpha","surface_id":"s1","route_status":"unstated"}
        {not-json}
        {"event":"turn_route","turn_id":"two","ts":"2026-08-24T00:00:01Z","team":"alpha","surface_id":"s1"}
        {"event":"turn_end","turn_id":"torn"
        """
        try Data(bytes.utf8).write(to: log)

        let records = LeaderTurnLog.readAll(from: log)
        XCTAssertEqual(records.map(\.turnID), ["one", "two"])
        XCTAssertEqual(records.map(\.event), [.turnEnd, .turnRoute])
        XCTAssertEqual(records.first?.routeStatus, "unstated")
    }

    func testHealthUsesSupportedStartsAsDenominatorAndSeparatesCapabilities() throws {
        let log = try temporaryLog()
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let payload = """
        {"event":"turn_start","turn_id":"a","ts":"2026-08-24T00:00:00Z","team":"t","surface_id":"s"}
        {"event":"turn_route","turn_id":"a","ts":"2026-08-24T00:00:01Z","team":"t","route_status":"stated"}
        {"event":"turn_end","turn_id":"a","ts":"2026-08-24T00:00:02Z","team":"t","route_status":"stated"}
        {"event":"turn_start","turn_id":"b","ts":"2026-08-24T00:00:03Z","team":"t","surface_id":"s"}
        {"event":"turn_end","turn_id":"b","ts":"2026-08-24T00:00:04Z","team":"t","route_status":"unstated"}
        {not-json}
        """ + "\n"
        try Data(payload.utf8).write(to: log)

        let health = LeaderTurnLog.health(
            from: log, capabilities: [.supported, .unsupported, .degraded]
        )
        XCTAssertEqual(health.supportedTurns, 2)
        XCTAssertEqual(health.linkedTurns, 1)
        XCTAssertEqual(health.statedTurns, 1)
        XCTAssertEqual(health.unstatedTurns, 1)
        XCTAssertEqual(health.unsupportedTurns, 1)
        XCTAssertEqual(health.degradedTurns, 1)
        XCTAssertEqual(health.malformedLines, 1)
        XCTAssertEqual(health.coverage, 1)
        XCTAssertEqual(health.linkage, 0.5)
        XCTAssertEqual(health.observedDays, 1)
    }

    func testHealthComputesInclusiveObservedDaysForSevenDayPromotionPath() throws {
        let log = try temporaryLog()
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let payload = """
        {"event":"turn_start","turn_id":"first","ts":"2026-08-18T23:59:00Z","team":"t"}
        {"event":"turn_start","turn_id":"last","ts":"2026-08-24T00:01:00Z","team":"t"}
        """ + "\n"
        try Data(payload.utf8).write(to: log)
        XCTAssertEqual(LeaderTurnLog.health(from: log).observedDays, 7)
    }

    func testRouteRecordWinsMarkerRaceAndCoverageNeverExceedsOne() throws {
        let log = try temporaryLog()
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let payload = """
        {"event":"turn_start","turn_id":"raced","ts":"2026-08-24T00:00:00Z","team":"t"}
        {"event":"turn_end","turn_id":"raced","ts":"2026-08-24T00:00:01Z","team":"t","route_status":"unstated"}
        {"event":"turn_route","turn_id":"raced","ts":"2026-08-24T00:00:02Z","team":"t","route_status":"stated"}
        """ + "\n"
        try Data(payload.utf8).write(to: log)

        let health = LeaderTurnLog.health(from: log)
        XCTAssertEqual(health.supportedTurns, 1)
        XCTAssertEqual(health.statedTurns, 1)
        XCTAssertEqual(health.unstatedTurns, 0)
        XCTAssertEqual(health.coverage, 1)
        XCTAssertLessThanOrEqual(health.coverage, 1)
        XCTAssertLessThanOrEqual(health.linkage, 1)
    }

    func testShadowPolicyFieldsDecodeAdditivelyWithoutChangingLegacyRecords() throws {
        let log = try temporaryLog()
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let payload = """
        {"event":"turn_route","turn_id":"policy","ts":"2026-08-24T00:00:00Z","team":"t","route":"parallel","actual_route":"parallel","suggested_participation":"hands_on","suggested_route":"direct","policy_version":"1","policy_mode":"shadow","policy_applied":false,"cohort":"shadow","policy_reasons":["unsupported_input"],"dispatch_bounds":"no required worker dispatch"}
        {"event":"turn_route","turn_id":"legacy","ts":"2026-08-24T00:00:01Z","team":"t","route":"direct"}
        """ + "\n"
        try Data(payload.utf8).write(to: log)

        let records = LeaderTurnLog.readAll(from: log)
        XCTAssertEqual(records[0].actualRoute, "parallel")
        XCTAssertEqual(records[0].suggestedRoute, "direct")
        XCTAssertEqual(records[0].policyApplied, false)
        XCTAssertEqual(records[0].cohort, "shadow")
        XCTAssertEqual(records[1].actualRoute, nil)
        XCTAssertEqual(records[1].policyApplied, nil)
    }

    func testPolicyReportSeparatesCohortsAppliedAndSuggestedDeviation() throws {
        let log = try temporaryLog()
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let payload = """
        {"event":"turn_route","turn_id":"s","ts":"2026-08-24T00:00:00Z","team":"t","actual_route":"direct","suggested_route":"parallel","policy_mode":"shadow","policy_applied":false,"cohort":"shadow"}
        {"event":"turn_route","turn_id":"c","ts":"2026-08-24T00:00:01Z","team":"t","actual_route":"parallel","suggested_route":"parallel","policy_mode":"canary","policy_applied":true,"cohort":"canary"}
        {"event":"turn_route","turn_id":"h","ts":"2026-08-24T00:00:02Z","team":"t","actual_route":"direct","suggested_route":"parallel","policy_mode":"canary","policy_applied":false,"cohort":"holdout"}
        """ + "\n"
        try Data(payload.utf8).write(to: log)

        let report = LeaderTurnLog.policyReport(from: log)
        XCTAssertEqual(report.shadowTurns, 1)
        XCTAssertEqual(report.canaryTurns, 1)
        XCTAssertEqual(report.holdoutTurns, 1)
        XCTAssertEqual(report.appliedTurns, 1)
        XCTAssertEqual(report.suggestedTurns, 3)
        XCTAssertEqual(report.routeDeviations, 2)
    }

    func testAppendCreatesMissingDirectory() throws {
        let log = try temporaryLog()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.deletingLastPathComponent().path))

        try LeaderTurnLog.append(
            .turnEnd(team: "alpha", surfaceID: "surface", prompt: "prompt"),
            to: log
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        XCTAssertEqual(LeaderTurnLog.readAll(from: log).count, 1)
    }

    func testAppendRecreatesPathAfterLogRotation() throws {
        let log = try temporaryLog()
        let rotatedLog = log.appendingPathExtension("1")
        let beforeRotation = LeaderTurnLog.Record.turnEnd(
            team: "alpha", surfaceID: "surface-before", prompt: "before"
        )
        let afterRotation = LeaderTurnLog.Record.turnEnd(
            team: "alpha", surfaceID: "surface-after", prompt: "after"
        )

        try LeaderTurnLog.append(beforeRotation, to: log)
        try FileManager.default.moveItem(at: log, to: rotatedLog)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))

        try LeaderTurnLog.append(afterRotation, to: log)

        XCTAssertEqual(LeaderTurnLog.readAll(from: rotatedLog), [beforeRotation])
        XCTAssertEqual(LeaderTurnLog.readAll(from: log), [afterRotation])
    }

    func testTurnIDIsDeterministicAndInputSensitive() {
        let promptHash = LeaderTurnLog.promptSHA256("same prompt")
        let first = LeaderTurnLog.turnID(
            sessionID: nil, surfaceID: "surface-a", promptSHA256: promptHash
        )
        let again = LeaderTurnLog.turnID(
            sessionID: nil, surfaceID: "surface-a", promptSHA256: promptHash
        )
        let otherSurface = LeaderTurnLog.turnID(
            sessionID: nil, surfaceID: "surface-b", promptSHA256: promptHash
        )
        let otherPrompt = LeaderTurnLog.turnID(
            sessionID: nil,
            surfaceID: "surface-a",
            promptSHA256: LeaderTurnLog.promptSHA256("different prompt")
        )

        XCTAssertEqual(first, again)
        XCTAssertEqual(first.count, 16)
        XCTAssertNotEqual(first, otherSurface)
        XCTAssertNotEqual(first, otherPrompt)
    }

    /// The shell hook is the writer that actually produces turn_start/turn_end,
    /// and it prefers the CLI session ID over the surface ID as the hash
    /// discriminator. This helper must agree byte-for-byte or the two writers
    /// derive different IDs for the same turn — and since the join is by
    /// turn_id alone, the records never meet and the miss looks exactly like a
    /// leader that never reported a route. Recompute the hook's documented
    /// derivation here rather than trusting the implementation.
    func testTurnIDMatchesTheHookDiscriminatorPreference() {
        let promptHash = LeaderTurnLog.promptSHA256("shared prompt")

        // A session ID in the payload wins over the surface ID.
        let withSession = LeaderTurnLog.turnID(
            sessionID: "session-42", surfaceID: "surface-a", promptSHA256: promptHash
        )
        let sessionAsDiscriminator = Self.sha256Prefix16("session-42:\(promptHash)")
        XCTAssertEqual(withSession, sessionAsDiscriminator)

        // The surface ID is used only as the fallback: absent and empty behave
        // identically, matching the hook's `${SESSION_ID:-$SURFACE_ID}`.
        let surfaceFallback = Self.sha256Prefix16("surface-a:\(promptHash)")
        XCTAssertEqual(
            LeaderTurnLog.turnID(
                sessionID: nil, surfaceID: "surface-a", promptSHA256: promptHash
            ),
            surfaceFallback
        )
        XCTAssertEqual(
            LeaderTurnLog.turnID(
                sessionID: "", surfaceID: "surface-a", promptSHA256: promptHash
            ),
            surfaceFallback
        )

        // And the two discriminators must not collide.
        XCTAssertNotEqual(withSession, surfaceFallback)
    }

    private static func sha256Prefix16(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    func testPromptContentIsAbsentFromWrittenBytes() throws {
        let log = try temporaryLog()
        let secretPrompt = "NEVER_STORE_THIS_PROMPT_7f644c"
        try LeaderTurnLog.append(
            .turnStart(team: "alpha", surfaceID: "surface", prompt: secretPrompt),
            to: log
        )

        let written = try XCTUnwrap(String(data: Data(contentsOf: log), encoding: .utf8))
        XCTAssertFalse(written.contains(secretPrompt))
        XCTAssertTrue(written.contains("\"prompt_bytes\":\(secretPrompt.utf8.count)"))
        XCTAssertTrue(written.contains("\"prompt_sha256\":\"\(LeaderTurnLog.promptSHA256(secretPrompt))\""))
    }

    /// The Rust writer omits `surface_id` entirely when TERMMESH_SURFACE_ID is
    /// unset. Requiring it here would make `readAll` drop those `turn_route`
    /// lines — and because `readAll` swallows decode failures, the loss would be
    /// silent and would look exactly like a leader that never reported a route.
    func testForeignWriterLinesWithoutSurfaceIDStillDecode() throws {
        let file = try temporaryLog()
        let foreign = """
        {"event":"turn_route","turn_id":"abc123","ts":"2026-08-24T09:15:00Z","team":"term-mesh","route":"direct"}
        {"event":"turn_end","turn_id":"abc123","ts":"2026-08-24T09:15:01Z","team":"term-mesh"}
        """
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (foreign + "\n").write(to: file, atomically: true, encoding: .utf8)

        let records = LeaderTurnLog.readAll(from: file)

        XCTAssertEqual(records.count, 2, "a foreign writer's records must not be silently dropped")
        XCTAssertEqual(records.first?.event, .turnRoute)
        XCTAssertEqual(records.first?.turnID, "abc123")
        XCTAssertEqual(records.first?.surfaceID, "")
    }

    /// One sink, three writers: a second `ts` shape would break string ordering
    /// and equality across them for no gain at this resolution.
    func testTimestampMatchesTheWholeSecondShapeOfTheOtherWriters() throws {
        let file = try temporaryLog()
        try LeaderTurnLog.append(
            .turnStart(team: "term-mesh", surfaceID: "surface-1", prompt: "hello"),
            to: file
        )

        let ts = try XCTUnwrap(LeaderTurnLog.readAll(from: file).first?.timestamp)

        XCTAssertFalse(ts.contains("."), "ts must not carry fractional seconds: \(ts)")
        XCTAssertTrue(ts.hasSuffix("Z"), "ts must be UTC with a Z suffix: \(ts)")
        XCTAssertEqual(ts.count, 20, "expected YYYY-MM-DDTHH:MM:SSZ, got \(ts)")
    }
}
