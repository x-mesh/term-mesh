import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

// MARK: - Helpers

/// Pattern-match assertion for TerminalSurface.PasteSendError (not Equatable in production).
private func assertError(
    _ result: Result<Void, TerminalSurface.PasteSendError>,
    is expected: TerminalSurface.PasteSendError,
    _ message: String = "",
    file: StaticString = #file, line: UInt = #line
) {
    guard case .failure(let err) = result else {
        return XCTFail("Expected failure(\(expected)) but got success", file: file, line: line)
    }
    switch (err, expected) {
    case (.queueOverflow, .queueOverflow),
         (.surfaceUnavailable, .surfaceUnavailable),
         (.returnRetryExhausted, .returnRetryExhausted):
        break   // match
    default:
        XCTFail("Expected .\(expected) but got .\(err)\(message.isEmpty ? "" : " — \(message)")",
                file: file, line: line)
    }
}

// MARK: - PasteDispatcher: testable seam (ADR addendum P2-3)
//
// Mirrors TerminalSurface.sendIMETextResult(_:withReturn:completion:).
// TODO: when executor adds `protocol PasteSurfaceProtocol`, replace this
// with conformance to that protocol and drop the explicit typealias.

protocol PasteDispatcher: AnyObject {
    typealias PasteCompletion = (Result<Void, TerminalSurface.PasteSendError>) -> Void
    func sendIMETextResult(_ text: String, withReturn: Bool,
                           completion: @escaping PasteCompletion)
    var pasteQueueDepthForTesting: Int { get }
}

// MARK: - MockPasteDispatcher

/// Synchronous, in-memory mock that enforces the oldest-drop overflow policy
/// and records dispatched calls. Does NOT call any ghostty C surface functions.
/// Uses `TerminalSurface.PasteSendError` so enum cases stay aligned with production.
final class MockPasteDispatcher: PasteDispatcher {
    struct Call: Equatable {
        let text: String
        let withReturn: Bool
    }

    static let maxDepth = 16

    private(set) var calls: [Call] = []
    private var pending: [(Call, PasteCompletion)] = []
    private var inFlight = false

    /// When true, new enqueues are held and drain does not auto-run.
    var suspendDrain = false

    var pasteQueueDepthForTesting: Int { pending.count }

    func sendIMETextResult(_ text: String, withReturn: Bool = true,
                           completion: @escaping PasteCompletion) {
        if pending.count >= Self.maxDepth {
            let (_, cb) = pending.removeFirst()    // oldest-drop
            cb(.failure(.queueOverflow))
        }
        pending.append((Call(text: text, withReturn: withReturn), completion))
        if !suspendDrain { drain() }
    }

    private func drain() {
        // inFlight guard prevents re-entrant stack growth.
        guard !inFlight, !pending.isEmpty else { return }
        let (call, cb) = pending.removeFirst()
        inFlight = true
        calls.append(call)
        cb(.success(()))
        inFlight = false
        if !suspendDrain { drain() }
    }

    func drainAll() {
        suspendDrain = false
        drain()
    }

    /// Simulate watchdog/retry-exhausted: fire completion(.failure(.returnRetryExhausted))
    /// for the currently in-flight item without resolving via drain.
    func simulateRetryExhausted(forText text: String) {
        // Remove the pending item that matches text and fire its completion with error.
        if let idx = pending.firstIndex(where: { $0.0.text == text }) {
            let (_, cb) = pending.remove(at: idx)
            cb(.failure(.returnRetryExhausted))
        }
    }

    /// Simulate surface becoming nil mid-retry: fire completion(.failure(.surfaceUnavailable)).
    func simulateSurfaceUnavailable(forText text: String) {
        if let idx = pending.firstIndex(where: { $0.0.text == text }) {
            let (_, cb) = pending.remove(at: idx)
            cb(.failure(.surfaceUnavailable))
        }
    }
}

// MARK: - Test cases (ADR addendum P2-3, reviewer P0-2)

/// 1. reentrancy — calling sendIMETextResult from within a completion callback
///    must not cause a stack overflow; items must be processed in sequential order.
final class PasteQueueReentrancyTests: XCTestCase {

    func testReentrancyNoStackOverflowSequentialOrder() {
        let mock = MockPasteDispatcher()
        var processedOrder: [String] = []

        mock.sendIMETextResult("cmd1", withReturn: true) { [mock] _ in
            processedOrder.append("cmd1")
            // Re-entrant enqueue from within a completion (mirrors async retry closure path)
            mock.sendIMETextResult("cmd2", withReturn: true) { _ in
                processedOrder.append("cmd2")
            }
        }

        XCTAssertEqual(processedOrder, ["cmd1", "cmd2"],
                       "Re-entrant paste must be appended and processed after the current item")
        XCTAssertEqual(mock.calls.map(\.text), ["cmd1", "cmd2"])
        XCTAssertEqual(mock.pasteQueueDepthForTesting, 0,
                       "Queue must be empty after full drain")
    }
}

/// 2. overflowDropOldest — enqueue 17 items (capacity = 16): the first (oldest)
///    must be dropped with completion(.failure(.queueOverflow)); 16 remain.
final class PasteQueueOverflowTests: XCTestCase {

    func testOverflowDropsOldestItemWithQueueOverflowError() {
        let mock = MockPasteDispatcher()
        mock.suspendDrain = true

        var overflowTexts: [String] = []

        for i in 0..<17 {
            let text = "cmd\(i)"
            mock.sendIMETextResult(text, withReturn: true) { result in
                if case .failure = result {
                    assertError(result, is: .queueOverflow,
                                "Overflow must report .queueOverflow, not other errors")
                    overflowTexts.append(text)
                }
            }
        }

        XCTAssertEqual(overflowTexts, ["cmd0"],
                       "Exactly the oldest item (cmd0) must be dropped on overflow")
        XCTAssertEqual(mock.pasteQueueDepthForTesting, MockPasteDispatcher.maxDepth,
                       "Queue depth must be exactly maxDepth (16) after overflow")

        mock.drainAll()
        XCTAssertEqual(mock.calls.count, 16,
                       "All 16 surviving items must be processed after drain")
        XCTAssertEqual(mock.pasteQueueDepthForTesting, 0)
    }

    func testOverflowCompletionCalledBeforeDrain() {
        // Overflow callback fires synchronously during enqueue, before drain starts.
        let mock = MockPasteDispatcher()
        mock.suspendDrain = true

        for i in 0..<MockPasteDispatcher.maxDepth {
            mock.sendIMETextResult("fill\(i)", withReturn: true) { _ in }
        }

        var newcomerOverflowFired = false
        mock.sendIMETextResult("newcomer", withReturn: true) { result in
            if case .failure(.queueOverflow) = result { newcomerOverflowFired = true }
        }

        // "fill0" (oldest) was dropped; "newcomer" was enqueued — newcomer's own
        // completion must NOT have been called with overflow (it's still in queue).
        XCTAssertFalse(newcomerOverflowFired,
                       "Newcomer's completion must not fire with overflow — fill0 was dropped, not newcomer")
        XCTAssertEqual(mock.pasteQueueDepthForTesting, MockPasteDispatcher.maxDepth)
    }
}

/// 3. bareEnterCaller — sendIMETextResult(withReturn:false) must paste text only,
///    without sending a Return key, and the queue must drain cleanly.
///    Mirrors the TeamOrchestrator:2125 bare-Enter caller pattern (ADR addendum P0-2).
final class PasteQueueBareEnterTests: XCTestCase {

    func testBareEnterCallerNeverSetsNeedsReturn() {
        let mock = MockPasteDispatcher()

        mock.sendIMETextResult("ls -la", withReturn: false) { _ in }

        XCTAssertEqual(mock.calls.count, 1)
        guard let call = mock.calls.first else { return XCTFail("No call recorded") }
        XCTAssertFalse(call.withReturn,
                       "withReturn=false must be preserved through the queue")
        XCTAssertEqual(call.text, "ls -la")
        XCTAssertEqual(mock.pasteQueueDepthForTesting, 0)
    }

    func testBareEnterCallerFollowedByNormalPasteRetainsOrder() {
        let mock = MockPasteDispatcher()

        mock.sendIMETextResult("cd /tmp", withReturn: false) { _ in }
        mock.sendIMETextResult("pwd", withReturn: true) { _ in }

        XCTAssertEqual(mock.calls.count, 2)
        XCTAssertFalse(mock.calls[0].withReturn, "First call is bare-Enter")
        XCTAssertTrue(mock.calls[1].withReturn, "Second call fires Return normally")
    }
}

/// 4. IMEComposingConcurrentPaste — a paste arriving while IME marked text is
///    active must be safely enqueued; the queue state must be consistent, and
///    the paste must be processed exactly once after composing ends.
final class PasteQueueIMEComposingTests: XCTestCase {

    func testPasteDuringIMEComposingIsSafelyQueued() {
        let mock = MockPasteDispatcher()
        mock.suspendDrain = true

        mock.sendIMETextResult("pasted-during-ime", withReturn: true) { _ in }

        XCTAssertEqual(mock.pasteQueueDepthForTesting, 1,
                       "Paste must be safely queued while IME composing is active")
        XCTAssertEqual(mock.calls.count, 0, "Must not process while drain is suspended")
    }

    func testPasteDuringIMEComposingProcessedExactlyOnceAfterComposingEnds() {
        let mock = MockPasteDispatcher()
        mock.suspendDrain = true

        var completionCount = 0
        mock.sendIMETextResult("pasted-during-ime", withReturn: true) { _ in
            completionCount += 1
        }

        mock.drainAll()

        XCTAssertEqual(completionCount, 1,
                       "Paste completion must fire exactly once after IME composing ends")
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.pasteQueueDepthForTesting, 0)
    }

    func testMultiplePastesDuringIMEComposingProcessedInFIFOOrder() {
        let mock = MockPasteDispatcher()
        mock.suspendDrain = true

        for text in ["first", "second", "third"] {
            mock.sendIMETextResult(text, withReturn: true) { _ in }
        }

        mock.drainAll()

        XCTAssertEqual(mock.calls.map(\.text), ["first", "second", "third"],
                       "Pastes accumulated during IME composing must be delivered in FIFO order")
    }
}

/// 5. Error paths — production PasteSendError cases: queueOverflow, surfaceUnavailable,
///    returnRetryExhausted. Verifies that completions receive the correct error type
///    and that the queue continues draining after each failure.
final class PasteQueueErrorPathTests: XCTestCase {

    func testReturnRetryExhaustedCallsCompletionAndContinuesDrain() {
        let mock = MockPasteDispatcher()
        mock.suspendDrain = true

        var errorResults: [Result<Void, TerminalSurface.PasteSendError>] = []
        var successTexts: [String] = []

        mock.sendIMETextResult("will-timeout", withReturn: true) { result in
            if case .failure = result { errorResults.append(result) }
        }
        mock.sendIMETextResult("after-timeout", withReturn: true) { result in
            if case .success = result { successTexts.append("after-timeout") }
        }

        mock.suspendDrain = false
        mock.simulateRetryExhausted(forText: "will-timeout")
        mock.drainAll()

        XCTAssertEqual(errorResults.count, 1, "Exactly one error result expected")
        if let r = errorResults.first {
            assertError(r, is: .returnRetryExhausted,
                        "Exhausted retries must yield .returnRetryExhausted")
        }
        XCTAssertEqual(successTexts, ["after-timeout"],
                       "Queue must continue draining after returnRetryExhausted")
    }

    func testSurfaceUnavailableCallsCompletionAndContinuesDrain() {
        let mock = MockPasteDispatcher()
        mock.suspendDrain = true

        var errorResults: [Result<Void, TerminalSurface.PasteSendError>] = []
        var successTexts: [String] = []

        mock.sendIMETextResult("surface-gone", withReturn: true) { result in
            if case .failure = result { errorResults.append(result) }
        }
        mock.sendIMETextResult("next-paste", withReturn: true) { result in
            if case .success = result { successTexts.append("next-paste") }
        }

        mock.suspendDrain = false
        mock.simulateSurfaceUnavailable(forText: "surface-gone")
        mock.drainAll()

        XCTAssertEqual(errorResults.count, 1, "Exactly one error result expected")
        if let r = errorResults.first {
            assertError(r, is: .surfaceUnavailable,
                        "Surface disposed mid-retry must yield .surfaceUnavailable")
        }
        XCTAssertEqual(successTexts, ["next-paste"],
                       "Queue must continue draining after surfaceUnavailable")
    }

    func testQueueOverflowDoesNotAffectReturnRetryExhaustedBehavior() {
        let mock = MockPasteDispatcher()
        mock.suspendDrain = true

        var allResults: [Result<Void, TerminalSurface.PasteSendError>] = []

        for i in 0..<17 {
            mock.sendIMETextResult("fill\(i)", withReturn: true) { r in allResults.append(r) }
        }

        mock.simulateRetryExhausted(forText: "fill16")
        mock.drainAll()

        let overflowCount = allResults.filter {
            if case .failure(.queueOverflow) = $0 { return true }; return false
        }.count
        let retryCount = allResults.filter {
            if case .failure(.returnRetryExhausted) = $0 { return true }; return false
        }.count

        XCTAssertEqual(overflowCount, 1, "Exactly one .queueOverflow error expected")
        XCTAssertEqual(retryCount, 1, "Exactly one .returnRetryExhausted error expected")
    }
}
