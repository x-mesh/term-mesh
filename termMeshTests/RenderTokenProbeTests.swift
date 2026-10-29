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

    func testRejectProducesRejectedOutcome() throws {
        let probe = RenderTokenProbe()
        let token = try XCTUnwrap(probe.begin())

        probe.reject(token: token)

        let result = probe.wait(token: token, timeout: 0)
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertNil(result.callbackOnMain)
        XCTAssertNil(result.callbackStatus)
    }

    func testSecondRequestIsRejectedWhileTokenIsPending() throws {
        let probe = RenderTokenProbe()
        let token = try XCTUnwrap(probe.begin())

        XCTAssertNil(probe.begin())
        probe.reject(token: token)
    }

    func testLateFailureDoesNotCompleteNextToken() throws {
        let probe = RenderTokenProbe()
        let firstToken = try XCTUnwrap(probe.begin())

        XCTAssertEqual(probe.wait(token: firstToken, timeout: 0).outcome, .timeout)
        let secondToken = try XCTUnwrap(probe.begin())
        let callbacksFinished = expectation(description: "late callbacks finished")

        DispatchQueue.global().async {
            probe.fail(token: firstToken, status: GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED)
            probe.present(token: secondToken)
            callbacksFinished.fulfill()
        }
        wait(for: [callbacksFinished], timeout: 1)

        let result = probe.wait(token: secondToken, timeout: 1)
        XCTAssertEqual(result.token, secondToken)
        XCTAssertEqual(result.outcome, .presented)
        XCTAssertFalse(result.callbackOnMain ?? true)
        XCTAssertEqual(result.callbackStatus, 0)
    }

    func testLatePresentationDoesNotCompleteNextToken() throws {
        let probe = RenderTokenProbe()
        let firstToken = try XCTUnwrap(probe.begin())

        XCTAssertEqual(probe.wait(token: firstToken, timeout: 0).outcome, .timeout)
        let secondToken = try XCTUnwrap(probe.begin())
        let callbackFinished = expectation(description: "late presentation finished")

        DispatchQueue.global().async {
            probe.present(token: firstToken)
            callbackFinished.fulfill()
        }
        wait(for: [callbackFinished], timeout: 1)

        XCTAssertNil(probe.begin())

        let result = probe.wait(token: secondToken, timeout: 0.01)
        XCTAssertEqual(result.token, secondToken)
        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertNil(result.callbackOnMain)
        XCTAssertNil(result.callbackStatus)
    }
}
#endif
