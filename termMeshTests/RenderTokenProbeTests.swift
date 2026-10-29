import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

#if DEBUG
final class RenderTokenProbeTests: XCTestCase {
    func testFailureStatusesUseStableOutcomeStrings() {
        XCTAssertEqual(
            RenderTokenProbeOutcome
                .from(failureStatusRawValue: Int(GHOSTTY_RENDER_PRESENTATION_DISCARDED.rawValue))
                .rawValue,
            "discarded"
        )
        XCTAssertEqual(
            RenderTokenProbeOutcome
                .from(failureStatusRawValue: Int(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue))
                .rawValue,
            "backend_failed"
        )
    }

    func testRejectProducesRejectedOutcome() {
        let probe = RenderTokenProbe()
        let token = try! XCTUnwrap(probe.begin())

        probe.reject(token: token)

        let result = probe.wait(token: token, timeout: 0)
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertNil(result.callbackOnMain)
        XCTAssertNil(result.callbackStatus)
    }

    func testSecondRequestIsRejectedWhileTokenIsPending() {
        let probe = RenderTokenProbe()
        let token = try! XCTUnwrap(probe.begin())

        XCTAssertNil(probe.begin())
        probe.reject(token: token)
    }
}
#endif
