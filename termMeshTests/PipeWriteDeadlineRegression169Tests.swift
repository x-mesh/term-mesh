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
