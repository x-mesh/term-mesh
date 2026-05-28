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
