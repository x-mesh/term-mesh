import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Writing one turn onto an agent's FIFO has to satisfy two things at once,
/// and 0.169 held each of them alone for a while.
///
/// Abandoning a line halfway leaves a fragment of a JSON object in the pipe and
/// the next instruction is appended straight onto it — two turns destroyed
/// rather than one. Finishing a committed line whatever it takes is the other
/// failure: `deliver` is called from `TeamOrchestrator`, which is `@MainActor`,
/// so a loop that only ends when the reader resumes is the whole app waiting on
/// a process that may already be gone.
///
/// These pin both, because a fix for either one alone is what produced the
/// other.
final class PipeWriteDeadlineRegression169Tests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        @discardableResult
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var snapshot: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// The regression this file exists for.
    ///
    /// A reader that accepts one byte and then stops is indistinguishable, from
    /// `EAGAIN` alone, from one that will resume in a moment — so the wait has
    /// to be bounded. With the bug present this test does not fail, it hangs:
    /// the loop past the first byte never consulted the clock again.
    func testAStalledReaderEndsTheWaitInsteadOfHoldingTheMainActorForever() {
        var clock: TimeInterval = 0
        var pauses = 0
        var terminations = 0

        XCTAssertThrowsError(try AgentPipeTransport.writeWholeLine(
            byteCount: 64,
            timeout: 5,
            now: { clock },
            pause: { clock += 0.002; pauses += 1 },
            terminateLine: { terminations += 1; return true },
            attempt: { offset, _ in offset == 0 ? .written(1) : .wouldBlock }
        )) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("1/64B"), "says how far it got: \(message)")
            XCTAssertTrue(message.contains("terminated"), "says what it did: \(message)")
        }

        XCTAssertEqual(terminations, 1, "the committed fragment is closed exactly once")
        XCTAssertGreaterThanOrEqual(clock, 5, "it waited out the whole stall budget")
        XCTAssertLessThanOrEqual(pauses, 5_000, "and no longer than the budget allows")
    }

    /// The property the deadline must not cost: a reader that is slow but
    /// consuming is the reader working. Two hundred bytes taken one at a time,
    /// a second apart, is forty times the stall budget in wall clock and must
    /// still arrive whole — the clock measures silence, not duration.
    func testASlowButConsumingReaderStillGetsTheWholeLine() throws {
        var clock: TimeInterval = 0
        var terminations = 0
        var blocking = true

        let written = try AgentPipeTransport.writeWholeLine(
            byteCount: 200,
            timeout: 5,
            now: { clock },
            pause: { clock += 1 },
            terminateLine: { terminations += 1; return true },
            attempt: { _, _ in
                defer { blocking.toggle() }
                return blocking ? .wouldBlock : .written(1)
            }
        )

        XCTAssertEqual(written, 200, "nothing was cut short")
        XCTAssertEqual(terminations, 0, "a line that finished needs no terminator")
        XCTAssertGreaterThan(clock, 5, "far past the budget, and never tripped it")
    }

    /// Nothing committed, nothing to clean up: the pipe is untouched, so the
    /// failure is the plain one and no newline is pushed into somebody else's
    /// stream.
    func testALineThatNeverStartedFailsWithoutTerminatingAnything() {
        var terminations = 0

        XCTAssertThrowsError(try AgentPipeTransport.writeWholeLine(
            byteCount: 10,
            timeout: 0,
            now: { 10 },
            pause: {},
            terminateLine: { terminations += 1; return true },
            attempt: { _, _ in .wouldBlock }
        )) { error in
            XCTAssertTrue("\(error)".contains("before line commit"), "\(error)")
        }

        XCTAssertEqual(terminations, 0)
    }

    /// When even the newline cannot be placed, the caller is told which of the
    /// two happened — the next delivery on that pipe will be glued to a
    /// fragment, and the log is the only place that can say so.
    func testATerminatorThatCannotBePlacedIsReportedAsSuch() {
        var clock: TimeInterval = 0

        XCTAssertThrowsError(try AgentPipeTransport.writeWholeLine(
            byteCount: 8,
            timeout: 1,
            now: { clock },
            pause: { clock += 0.5 },
            terminateLine: { false },
            attempt: { offset, _ in offset == 0 ? .written(2) : .wouldBlock }
        )) { error in
            XCTAssertTrue("\(error)".contains("could not be terminated"), "\(error)")
        }
    }

    func testUnterminatedPartialPoisonsLaterFramesUntilChannelReset() {
        let agentId = "poisoned-writer-\(UUID().uuidString)"
        let firstFinished = expectation(description: "partial delivery failed")
        let secondFinished = expectation(description: "next delivery rejected")
        let resetFinished = expectation(description: "delivery after reset succeeded")
        let laterWrites = LockedCounter()
        defer { AgentPipeTransport.discard(agentId: agentId) }

        AgentPipeTransport.enqueueDeliveryForTesting(
            agentId: agentId, resultTimeout: 1,
            operation: {
                var clock: TimeInterval = 0
                return try AgentPipeTransport.writeWholeLine(
                    byteCount: 8, timeout: 1, now: { clock },
                    pause: { clock += 1 }, terminateLine: { false },
                    attempt: { offset, _ in offset == 0 ? .written(2) : .wouldBlock })
            },
            completion: { result in
                guard case .failure(let error) = result else {
                    return XCTFail("partial delivery unexpectedly succeeded")
                }
                XCTAssertTrue("\(error)".contains("could not be terminated"))
                firstFinished.fulfill()
            })

        AgentPipeTransport.enqueueDeliveryForTesting(
            agentId: agentId, resultTimeout: 1,
            operation: { laterWrites.increment() },
            completion: { result in
                guard case .failure(let error) = result else {
                    return XCTFail("poisoned channel accepted the next frame")
                }
                XCTAssertTrue("\(error)".contains("restart required"))
                secondFinished.fulfill()
            })

        wait(for: [firstFinished, secondFinished], timeout: 1)
        XCTAssertEqual(laterWrites.snapshot, 0, "no later frame reached the poisoned pipe")

        AgentPipeTransport.discard(agentId: agentId)
        AgentPipeTransport.enqueueDeliveryForTesting(
            agentId: agentId, resultTimeout: 1,
            operation: { laterWrites.increment() },
            completion: { result in
                guard case .success = result else {
                    return XCTFail("reset channel did not accept a new frame: \(result)")
                }
                resetFinished.fulfill()
            })

        wait(for: [resetFinished], timeout: 1)
        XCTAssertEqual(laterWrites.snapshot, 1)
    }

    /// Two properties at once, and only the first of them held.
    ///
    /// The caller deadline starts when the turn is enqueued rather than when
    /// the writer reaches it, so a queue held by an earlier write still bounds
    /// the caller's wait, and whoever gets there first the completion runs
    /// exactly once. What was missing is the other half: once the deadline has
    /// answered, the abandoned turn must not reach the pipe at all. It used to,
    /// and since a failed delivery is never marked delivered, the caller's
    /// retry pasted the same instruction into the agent a second time.
    func testCallerDeadlineBoundsTheCallerAndDropsTheAbandonedWrite() {
        let agentId = "queued-deadline-\(UUID().uuidString)"
        let blockerStarted = expectation(description: "writer queue blocked")
        let deadlineFired = expectation(description: "caller deadline fired")
        let writerQueueDrained = expectation(description: "writer queue drained")
        let duplicateCallback = expectation(description: "completion called twice")
        duplicateCallback.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let callbacks = LockedCounter()
        let writes = LockedCounter()
        defer {
            release.signal()
            AgentPipeTransport.discard(agentId: agentId)
        }

        AgentPipeTransport.enqueueForTesting(agentId: agentId) {
            blockerStarted.fulfill()
            _ = release.wait(timeout: .now() + 2)
        }
        wait(for: [blockerStarted], timeout: 1)

        AgentPipeTransport.enqueueDeliveryForTesting(
            agentId: agentId, resultTimeout: 0.05,
            operation: { writes.increment() },
            completion: { result in
                guard callbacks.increment() == 1 else {
                    duplicateCallback.fulfill()
                    return
                }
                guard case .failure(let error) = result else {
                    return XCTFail("queued delivery beat its caller deadline")
                }
                XCTAssertTrue("\(error)".contains("delivery result deadline exceeded"))
                deadlineFired.fulfill()
            })
        AgentPipeTransport.enqueueForTesting(agentId: agentId) {
            writerQueueDrained.fulfill()
        }

        wait(for: [deadlineFired], timeout: 1)
        XCTAssertEqual(callbacks.snapshot, 1)
        release.signal()
        // The queue is serial, so draining past the abandoned delivery is what
        // makes the write count below mean "never ran" and not "not yet".
        wait(for: [writerQueueDrained], timeout: 1)
        wait(for: [duplicateCallback], timeout: 0.1)
        XCTAssertEqual(callbacks.snapshot, 1, "late writer completion must not call back twice")
        XCTAssertEqual(
            writes.snapshot, 0,
            "the turn its caller was told had failed never reached the pipe")
    }

    /// The other half of the deadline contract, and the half that was missing.
    ///
    /// Dropping the abandoned turn is only sound if "abandoned" is decided
    /// atomically. The writer used to read "nobody has answered yet", release
    /// the lock, and only then start; a deadline landing in that gap told the
    /// caller the turn had failed while the turn was already on its way. Since
    /// a failed delivery is never marked delivered, the retry sent the same
    /// instruction to the agent a second time.
    ///
    /// Here the write starts immediately and outlives its result deadline by
    /// far. Whoever it reports to, it must be the write's own outcome — a
    /// failure here means the caller was told something untrue about a turn the
    /// agent received.
    func testAWriteAlreadyUnderWayReportsItsOwnOutcomeNotTheDeadline() {
        let agentId = "claimed-write-\(UUID().uuidString)"
        let reported = expectation(description: "delivery reported")
        let callbacks = LockedCounter()
        defer { AgentPipeTransport.discard(agentId: agentId) }

        AgentPipeTransport.enqueueDeliveryForTesting(
            agentId: agentId, resultTimeout: 0.05,
            operation: {
                // Six times the result deadline: the deadline certainly fires
                // while this write holds the turn.
                Thread.sleep(forTimeInterval: 0.3)
                return 7
            },
            completion: { result in
                XCTAssertEqual(callbacks.increment(), 1, "reported more than once")
                guard case .success(let written) = result else {
                    return XCTFail(
                        "a write already under way must not be answered by the deadline: \(result)")
                }
                XCTAssertEqual(written, 7)
                reported.fulfill()
            })

        wait(for: [reported], timeout: 2)
        XCTAssertEqual(callbacks.snapshot, 1)
    }

    /// A signal interruption says nothing about the reader, so it must cost
    /// nothing — the property 6494c280 established and this must not undo.
    func testSignalInterruptionsDoNotConsumeTheStallBudget() throws {
        var clock: TimeInterval = 0
        var pauses = 0
        var remainingInterrupts = 1_000

        let written = try AgentPipeTransport.writeWholeLine(
            byteCount: 4,
            timeout: 5,
            now: { clock },
            pause: { clock += 10; pauses += 1 },
            terminateLine: { true },
            attempt: { _, remaining in
                guard remainingInterrupts == 0 else {
                    remainingInterrupts -= 1
                    return .interrupted
                }
                return .written(remaining)
            }
        )

        XCTAssertEqual(written, 4)
        XCTAssertEqual(pauses, 0, "an interrupt is retried, not waited out")
        XCTAssertEqual(clock, 0)
    }

    /// A reader that goes away for real still reports the errno rather than
    /// spinning on it.
    func testAFailedWriteStopsImmediately() {
        XCTAssertThrowsError(try AgentPipeTransport.writeWholeLine(
            byteCount: 16,
            timeout: 5,
            now: { 0 },
            pause: { XCTFail("a hard error must not be retried") },
            terminateLine: { XCTFail("nor treated as a stall"); return false },
            attempt: { offset, _ in offset == 0 ? .written(3) : .failed(EPIPE) }
        )) { error in
            XCTAssertTrue("\(error)".contains("errno \(EPIPE)"), "\(error)")
        }
    }
}
