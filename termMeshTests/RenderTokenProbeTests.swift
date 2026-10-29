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
        XCTAssertEqual(
            RenderTokenProbeOutcome.from(failureStatusRawValue: 99).rawValue,
            "unknown"
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

    func testLateCallbackDoesNotCompleteNextToken() {
        let probe = RenderTokenProbe()
        let firstToken = try! XCTUnwrap(probe.begin())

        XCTAssertEqual(probe.wait(token: firstToken, timeout: 0).outcome, .timeout)
        let secondToken = try! XCTUnwrap(probe.begin())

        DispatchQueue.global().async {
            probe.present(token: firstToken)
            probe.present(token: secondToken)
        }

        let result = probe.wait(token: secondToken, timeout: 1)
        XCTAssertEqual(result.token, secondToken)
        XCTAssertEqual(result.outcome, .presented)
        XCTAssertFalse(result.callbackOnMain ?? true)
        XCTAssertEqual(result.callbackStatus, 0)
    }
}
#endif
