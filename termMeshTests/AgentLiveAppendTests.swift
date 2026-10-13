import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class AgentLiveAppendTests: XCTestCase {
    private let generation = UUID()
    private let answerID = UUID()

    private func state(
        _ entries: [AgentSession.Entry], streaming: Bool = true, generation: UUID? = nil
    ) -> AgentSession.LiveState {
        .init(generation: generation ?? self.generation, entries: entries, running: true, thinking: false,
              interruptible: true, streaming: streaming ? [answerID] : [], summary: nil,
              model: "fixture", usage: nil)
    }

    private func answer(_ text: String) -> AgentSession.Entry { .answered(id: answerID, text) }

    /// One frame per state, as the host would send them, plus the bytes on the wire.
    private func frames(
        for states: [AgentSession.LiveState], supportsAppend: Bool
    ) async throws -> (frames: [AgentLiveFrame], bytes: Int) {
        let pair = AsyncStream<AgentSession.LiveState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let encoder = AgentLiveEncoder(pair.stream, supportsAppend: supportsAppend)
        var result: [AgentLiveFrame] = []
        var bytes = 0
        for state in states {
            pair.continuation.yield(state)
            var payload = Data()
            while let chunk = await encoder.next() {
                bytes += chunk.bytes.count
                let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: chunk.bytes) as? [String: Any])
                payload.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(packet["payload"] as? String))))
                if packet["end"] as? Bool == true { break }
            }
            result.append(try JSONDecoder().decode(AgentLiveFrame.self, from: payload))
        }
        pair.continuation.finish()
        return (result, bytes)
    }

    private func replay(_ frames: [AgentLiveFrame]) -> AgentSession {
        let viewer = AgentSession()
        viewer.prepareLivePresentation()
        for frame in frames { XCTAssertTrue(viewer.acceptLivePresentation(frame)) }
        return viewer
    }

    private func growingStates(_ pieces: [String]) -> [AgentSession.LiveState] {
        var text = ""
        return pieces.map { piece in
            text += piece
            return state([answer(text)])
        }
    }

    func testAppendChainReconstructsTheAnswerExactly() async throws {
        let states = growingStates(["Hello", ", ", "world", "!", " more text"])
        let sent = try await frames(for: states, supportsAppend: true)
        XCTAssertTrue(sent.frames[0].full)
        XCTAssertNil(sent.frames[0].appends)
        for frame in sent.frames.dropFirst() {
            XCTAssertEqual(frame.appends?.count, 1)
            XCTAssertTrue(frame.state.entries.isEmpty, "a patched entry is not sent whole")
        }
        XCTAssertEqual(replay(sent.frames).entries, states.last?.entries)
    }

    func testAppendUsesUTF8BytesForKoreanAndEmoji() async throws {
        let states = growingStates(["안녕", "하세요 😀", " 👩‍👩‍👧 가족", "👍🏽 끝"])
        let sent = try await frames(for: states, supportsAppend: true)
        let append = try XCTUnwrap(sent.frames[1].appends?.first)
        XCTAssertEqual(append.baseUTF8Bytes, UInt64("안녕".utf8.count))
        XCTAssertEqual(append.appendedText, "하세요 😀")
        XCTAssertEqual(replay(sent.frames).entries, states.last?.entries)
    }

    func testRewrittenTextFallsBackToTheWholeEntry() async throws {
        let states = [state([answer("draft one")]), state([answer("draft two")])]
        let sent = try await frames(for: states, supportsAppend: true)
        XCTAssertNil(sent.frames[1].appends)
        XCTAssertEqual(sent.frames[1].state.entries, [answer("draft two")])
        XCTAssertEqual(replay(sent.frames).entries, [answer("draft two")])
    }

    func testViewerWithoutTheCapabilityGetsWholeEntries() async throws {
        let states = growingStates(["Hello", " there", " friend"])
        let sent = try await frames(for: states, supportsAppend: false)
        XCTAssertTrue(sent.frames.allSatisfy { $0.appends == nil })
        XCTAssertEqual(sent.frames[2].state.entries, states[2].entries)
        XCTAssertEqual(replay(sent.frames).entries, states.last?.entries)
    }

    func testAFreshEncoderStartsWithAFullSnapshotAndTheDecoderRefusesALoosePatch() async throws {
        let states = growingStates(["start", " middle", " end"])
        let sent = try await frames(for: states, supportsAppend: true)
        let reconnect = try await frames(for: [states[2]], supportsAppend: true)
        XCTAssertTrue(reconnect.frames[0].full)
        XCTAssertNil(reconnect.frames[0].appends)
        XCTAssertEqual(replay(reconnect.frames).entries, states[2].entries)

        let refused = expectation(description: "a patch cannot start a restarted stream")
        let decoder = AgentLiveDecoder(invalid: { refused.fulfill() }) { _ in
            XCTFail("a patch was delivered before a full snapshot")
        }
        decoder.resetForRestart()
        var data = try JSONSerialization.data(withJSONObject: [
            "begin": true, "end": true,
            "payload": try JSONEncoder().encode(sent.frames[1]).base64EncodedString(),
        ])
        data.append(10)
        decoder.consume(data)
        await fulfillment(of: [refused], timeout: 3)
        decoder.stop()
    }

    func testBadPatchLeavesTheViewerUntouched() {
        let viewer = AgentSession()
        viewer.prepareLivePresentation()
        let other = UUID()
        func frame(base: UInt64, revision: UInt64, appends: [AgentLiveAppend], full: Bool = false) -> AgentLiveFrame {
            AgentLiveFrame(full: full, baseRevision: base, revision: revision,
                           order: [answerID, other], state: state(full ? [answer("abc"), .notice(id: other, "n")] : []),
                           appends: appends)
        }
        XCTAssertTrue(viewer.acceptLivePresentation(frame(base: 0, revision: 1, appends: [], full: true)))
        let good = AgentLiveAppend(entryID: answerID, field: .answered, baseUTF8Bytes: 3, appendedText: "def")
        let wrongBase = AgentLiveAppend(entryID: answerID, field: .answered, baseUTF8Bytes: 99, appendedText: "x")
        let wrongKind = AgentLiveAppend(entryID: other, field: .answered, baseUTF8Bytes: 1, appendedText: "x")
        let unknown = AgentLiveAppend(entryID: UUID(), field: .answered, baseUTF8Bytes: 0, appendedText: "x")
        for bad in [wrongBase, wrongKind, unknown] {
            XCTAssertFalse(viewer.acceptLivePresentation(frame(base: 1, revision: 2, appends: [good, bad])))
            XCTAssertEqual(viewer.entries.first, answer("abc"), "a valid patch before a bad one must not stick")
        }
        XCTAssertFalse(viewer.acceptLivePresentation(frame(base: 5, revision: 6, appends: [good])), "revision gap")
        XCTAssertFalse(viewer.acceptLivePresentation(frame(base: 1, revision: 2, appends: [good], full: true)), "patch on a full frame")
        XCTAssertEqual(viewer.entries.first, answer("abc"))
        XCTAssertTrue(viewer.acceptLivePresentation(frame(base: 1, revision: 2, appends: [good])))
        XCTAssertEqual(viewer.entries.first, answer("abcdef"))
    }

    func testPatchBudgetCheckpointsTheStreamingEntry() async throws {
        let pieces = Array(repeating: "x", count: 300)
        let states = growingStates(pieces)
        let sent = try await frames(for: states, supportsAppend: true)
        let appendFrames = sent.frames.dropFirst().prefix { $0.appends != nil }.count
        XCTAssertEqual(appendFrames, AgentLiveAppendLimits.maxPatchesPerEntry)
        let checkpoint = sent.frames[1 + appendFrames]
        XCTAssertNil(checkpoint.appends)
        XCTAssertEqual(checkpoint.state.entries.count, 1, "the whole entry is sent once the budget is spent")
        XCTAssertEqual(replay(sent.frames).entries, states.last?.entries)
    }

    func testLegacyFrameWithoutAppendsStillDecodes() throws {
        let legacy = AgentLiveFrame(full: true, baseRevision: 0, revision: 1, order: [answerID],
                                    state: state([answer("old host")]))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        XCTAssertNil(object["appends"], "an unused field is not written")
        object["appends"] = nil
        let decoded = try JSONDecoder().decode(AgentLiveFrame.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.appends)
        XCTAssertEqual(replay([decoded]).entries, [answer("old host")])
    }

    func testStreamingTwentyKilobyteAnswerSendsFarFewerBytes() async throws {
        let piece = String(repeating: "스트리밍 답변 ", count: 12)
        var pieces: [String] = []
        var total = 0
        while total < 20_000 && pieces.count < 100 {
            pieces.append(piece)
            total += piece.utf8.count
        }
        let states = growingStates(pieces)
        let before = try await frames(for: states, supportsAppend: false)
        let after = try await frames(for: states, supportsAppend: true)
        XCTAssertEqual(replay(after.frames).entries, replay(before.frames).entries)
        let saved = 100 - 100 * Double(after.bytes) / Double(before.bytes)
        print("AGENT_APPEND_BYTES updates=\(pieces.count) text=\(total) before=\(before.bytes) after=\(after.bytes) saved=\(Int(saved))%")
        XCTAssertGreaterThan(saved, 80)
    }
}
