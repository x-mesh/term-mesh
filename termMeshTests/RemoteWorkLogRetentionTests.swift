import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// What keeps this log readable when something starts repeating.
///
/// Measured on a live machine: one debug line — the handshake of the local
/// daemon connection `SessionHostPanes` opens every 15 seconds — was **99% of
/// a 7.4 MB log**, and the overflow policy at the time discarded the whole
/// file. Two individually reasonable decisions produced that: the file records
/// every level on purpose ("the level is about how much to show, not how much
/// to record"), and the poll is deliberately slow but never stops. Neither is
/// wrong alone, so the fix belongs here, in what the file does with a repeat.
@MainActor
final class RemoteWorkLogRetentionTests: XCTestCase {

    private var logPath: String { RemoteWorkLog.path }

    override func setUp() {
        super.setUp()
        RemoteWorkLog.resetRepeatStateForTesting()
        try? FileManager.default.removeItem(atPath: logPath)
    }

    private func logContents() -> String {
        RemoteWorkLog.drainForTesting()
        return (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    // MARK: - Test runs stay off the production file

    func test_testRunsWriteToTheirOwnFile() {
        // A suite exercising mock hosts and `example.invalid` tunnels used to
        // land its lines in the middle of the log someone was reading to
        // diagnose a live machine — 132 such lines were found in one.
        XCTAssertEqual(RemoteWorkLog.path, "/tmp/term-mesh-remote-work-tests.log")
    }

    // MARK: - Repeats are counted, not repeated

    func test_aRepeatedMessageIsWrittenOnceAndThenCounted() {
        let message = "Host term-mesh-host — app 0.218.0, protocol 1.0.0"
        for _ in 0..<10 { RemoteWorkLog.info(message) }
        RemoteWorkLog.info("something else")

        let text = logContents()
        let occurrences = text.components(separatedBy: message).count - 1
        XCTAssertEqual(occurrences, 1, "the repeated message should appear once:\n\(text)")
        XCTAssertTrue(
            text.contains("[repeat] previous message ×9"),
            "the run's length is the part worth keeping:\n\(text)"
        )
    }

    func test_aDistinctMessageIsNeverSuppressed() {
        // Suppression must key on the message, not on rate: three different
        // lines in a row are three events, and collapsing them would hide the
        // sequence a reader is here for.
        RemoteWorkLog.info("first")
        RemoteWorkLog.info("second")
        RemoteWorkLog.info("third")

        let text = logContents()
        for message in ["first", "second", "third"] {
            XCTAssertTrue(text.contains(message), "lost \(message):\n\(text)")
        }
        XCTAssertFalse(text.contains("[repeat]"), "nothing repeated:\n\(text)")
    }

    func test_anAlternatingPairIsNeverSuppressed() {
        // Only CONSECUTIVE identical messages collapse. Two lines taking turns
        // are a live back-and-forth, and reading it as a repeat would erase
        // the interleaving that makes it legible.
        for _ in 0..<5 {
            RemoteWorkLog.info("ping")
            RemoteWorkLog.info("pong")
        }
        let text = logContents()
        XCTAssertEqual(text.components(separatedBy: "ping").count - 1, 5)
        XCTAssertEqual(text.components(separatedBy: "pong").count - 1, 5)
    }

    func test_aLongRunIsFlushedBeforeItEnds() {
        // A repeat that lasts hours must still leave a trace inside the window
        // a reader is looking at. Waiting for it to stop means the only
        // evidence of an ongoing loop arrives after the loop does.
        for _ in 0..<(RemoteWorkLog.maxSuppressedRepeats + 2) {
            RemoteWorkLog.info("stuck")
        }
        XCTAssertTrue(
            logContents().contains("[repeat] last message ×\(RemoteWorkLog.maxSuppressedRepeats)"),
            "an ongoing run should report itself:\n\(logContents())"
        )
    }

    // MARK: - Overflow keeps the newer half

    func test_theKeptTailStartsAtALineBoundary() {
        // Cutting at a byte offset lands mid-line, and the fragment left at
        // the front reads as a whole entry — a line with no timestamp, or a
        // plausible one assembled from the tail of a message.
        let cut = Data("14:02Z [info] [info] half a lin".utf8)
            + Data("e\n2026-01-01T00:00:00Z [info] [info] whole\n".utf8)
        let kept = RemoteWorkLog.tailAfterFirstPartialLine(cut)
        XCTAssertEqual(
            String(decoding: kept, as: UTF8.self),
            "2026-01-01T00:00:00Z [info] [info] whole\n"
        )
    }

    func test_aTailWithNoNewlineKeepsNothing() {
        // One line longer than the half kept. There is no boundary to start
        // at, and emitting the fragment would be the exact failure above.
        XCTAssertTrue(
            RemoteWorkLog.tailAfterFirstPartialLine(Data("no newline here".utf8)).isEmpty
        )
    }

    func test_aTailThatBeginsAtABoundaryLosesTheFirstLine() {
        // Accepted cost, stated so it is not read as a bug: the cut offset is
        // a byte count and cannot know it already landed on a boundary, so one
        // whole line is spent on the guarantee that no fragment survives.
        let kept = RemoteWorkLog.tailAfterFirstPartialLine(Data("first\nsecond\n".utf8))
        XCTAssertEqual(String(decoding: kept, as: UTF8.self), "second\n")
    }
}
