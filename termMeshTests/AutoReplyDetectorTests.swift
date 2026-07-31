import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class AutoReplyDetectorTests: XCTestCase {

    private func t0() -> Date { Date() }
    private func drain(_ d: AutoReplyDetector, at t: Date) -> AutoReplyEvent? {
        d.tick(at: t.addingTimeInterval(10))
    }
    private func bytes(_ s: String) -> Data { Data(s.utf8) }
    private func detect(statusValue: String) -> AutoReplyEvent? {
        let detector = AutoReplyDetector()
        let now = t0()
        let input = "STATUS: \(statusValue)\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n"
        detector.pushBytes(bytes(input), at: now)
        return detector.tick(at: now.addingTimeInterval(1))
    }

    // MARK: - Fix D: sliding window

    func test_strict_pass_done() {
        let input = "STATUS: DONE\nFILES: src/foo.rs\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: n/a\n\nfix landed\n"
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        let ev = drain(d, at: t)
        XCTAssertEqual(ev?.status, "DONE")
        XCTAssertEqual(ev?.body, "fix landed")
    }

    // MARK: - What an agent pane actually renders

    func test_bulleted_and_indented_header_commits() {
        // Claude renders the reply as a list item: a bullet on the first line
        // and the rest merely indented. Both used to miss `hasPrefix`.
        let input = """
        ● STATUS: DONE
          FILES: (none — read-only)
          VERIFY: find . -maxdepth 1 -type f | wc -l
          NEXT: NONE
          FULL_REPORT: n/a

        """
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        let ev = drain(d, at: t)
        XCTAssertEqual(ev?.status, "DONE")
        XCTAssertEqual(ev?.files, "(none — read-only)")
    }

    func test_capsule_echo_is_not_a_result() {
        // The capsule prints the template, and agent panes redraw it. A status
        // that still lists the choices is the instruction coming back.
        let input = "STATUS: DONE|BLOCKED|NEEDS_REVIEW\nFILES: <changed paths>\nVERIFY: <cmd>\n"
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        XCTAssertNil(drain(d, at: t), "the echoed template must not close a task")
    }

    func test_capsule_placeholder_five_lines_is_not_a_result() {
        let input = """
        STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>
        FILES: <changed paths or none>
        VERIFY: <single shell command or n/a>
        NEXT: <action or NONE>
        FULL_REPORT: <result file path or n/a>

        """
        let detector = AutoReplyDetector()
        let now = t0()
        detector.pushBytes(bytes(input), at: now)

        XCTAssertNil(detector.tick(at: now.addingTimeInterval(1)))
        XCTAssertNil(detector.flush())
    }

    func test_noncanonical_status_values_are_rejected() {
        for value in ["done", " DONE", "DON", "DONEISH", ""] {
            XCTAssertNil(
                AutoReplyDetector.validatedStatus(value),
                "validation unexpectedly accepted \(String(reflecting: value))"
            )
            XCTAssertNil(
                detect(statusValue: value),
                "detector unexpectedly accepted \(String(reflecting: value))"
            )
        }
    }

    func test_terminal_row_padding_after_status_is_accepted() {
        XCTAssertEqual(AutoReplyDetector.validatedStatus("DONE   \t"), "DONE")
        XCTAssertEqual(detect(statusValue: "NEEDS_REVIEW   ")?.status, "NEEDS_REVIEW")
    }

    func test_all_canonical_status_values_are_accepted() {
        for status in ["DONE", "BLOCKED", "NEEDS_REVIEW"] {
            XCTAssertEqual(AutoReplyDetector.validatedStatus(status), status)
            XCTAssertEqual(detect(statusValue: status)?.status, status)
        }
    }

    func test_prose_keeps_its_dash() {
        // Marker stripping applies only when a header follows it.
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n\n- kept the dash\n"
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        XCTAssertEqual(drain(d, at: t)?.body, "- kept the dash")
    }

    func test_out_of_order_still_commits() {
        // Fix D: sliding window tolerates out-of-order headers
        let input = "NEXT: NONE\nFILES: src/foo.rs\nFULL_REPORT: n/a\nVERIFY: cargo test\nSTATUS: DONE\n"
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        let ev = drain(d, at: t)
        XCTAssertNotNil(ev, "out-of-order must commit with sliding window")
        XCTAssertEqual(ev?.status, "DONE")
        XCTAssertEqual(ev?.files, "src/foo.rs")
    }

    func test_blank_and_ansi_noise_interspersed() {
        // Fix D: noise between header lines is tolerated
        let input = "STATUS: DONE\n\u{001b}[1msome bold noise\u{001b}[0m\nFILES: src/foo.rs\n\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: n/a\nbody text\n"
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        let ev = drain(d, at: t)
        XCTAssertNotNil(ev, "noise-interspersed header must commit")
        XCTAssertEqual(ev?.status, "DONE")
        XCTAssertEqual(ev?.files, "src/foo.rs")
        XCTAssertEqual(ev?.body, "body text")
    }

    func test_status_missing_no_commit() {
        let input = "FILES: src/foo.rs\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: n/a\n"
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        XCTAssertNil(drain(d, at: t), "STATUS missing must not commit")
    }

    func test_partial_status_plus_2_commits_at_hard_cap() {
        // STATUS + 2 others at hard_cap → partial commit with "n/a" placeholders
        let input = "STATUS: DONE\nFILES: none\nVERIFY: cargo test\n"
        let cfg = AutoReplyDetectorConfig(idleDebounce: 100, hardCap: 5)
        let d = AutoReplyDetector(config: cfg)
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        let ev = d.tick(at: t.addingTimeInterval(6))
        XCTAssertNotNil(ev, "STATUS + 2 fields at hard_cap must partial commit")
        XCTAssertEqual(ev?.status, "DONE")
        XCTAssertEqual(ev?.next, "n/a")
        XCTAssertEqual(ev?.fullReport, "n/a")
    }

    func test_status_only_no_partial_commit() {
        let input = "STATUS: DONE\n"
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        XCTAssertNil(d.tick(at: t.addingTimeInterval(10)), "STATUS-only must not partial commit")
    }

    func test_body_extracted_after_last_header() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\nfirst body line\nsecond body line\n"
        let d = AutoReplyDetector()
        let t = t0()
        d.pushBytes(bytes(input), at: t)
        XCTAssertEqual(drain(d, at: t)?.body, "first body line\nsecond body line")
    }

    func test_flush_emits_pending() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\nbody\n"
        let d = AutoReplyDetector()
        d.pushBytes(bytes(input), at: t0())
        let ev = d.flush()
        XCTAssertEqual(ev?.status, "DONE")
        XCTAssertEqual(ev?.body, "body")
    }

    func test_flush_idle_returns_nil() {
        let d = AutoReplyDetector()
        d.pushBytes(bytes("random log line\n"), at: t0())
        XCTAssertNil(d.flush())
    }
}
