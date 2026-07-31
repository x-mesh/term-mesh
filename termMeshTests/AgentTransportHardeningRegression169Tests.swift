import XCTest
import Foundation

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class AgentTransportHardeningRegression169Tests: XCTestCase {
    private final class LockedOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func append(_ value: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
            return values.count
        }

        var snapshot: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testCommittedFIFOlineFinishesAfterDeadlineInsteadOfLeavingTruncatedJSON() throws {
        var attempts: [AgentPipeTransport.WriteAttempt] = [
            .written(4), .wouldBlock, .written(6),
        ]
        let written = try AgentPipeTransport.writeWholeLine(
            byteCount: 10,
            timeout: 1,
            now: { 10 },
            pause: {},
            attempt: { _, _ in attempts.removeFirst() }
        )
        XCTAssertEqual(written, 10)
        XCTAssertTrue(attempts.isEmpty)
    }

    func testUncommittedFIFOlineMayFailAtDeadlineWithoutWritingBytes() {
        XCTAssertThrowsError(try AgentPipeTransport.writeWholeLine(
            byteCount: 10,
            timeout: 0,
            now: { 10 },
            pause: {},
            attempt: { _, _ in .wouldBlock }
        ))
    }

    func testFailedReservationClearsOnlyItsOwnTaskId() {
        let agentId = "expect-rollback-\(UUID().uuidString)"
        AgentPipeCompletion.shared.watch(
            agentId: agentId, teamName: "t", agentName: "executor")
        defer { AgentPipeCompletion.shared.forget(agentId: agentId) }

        let first = AgentPipeCompletion.shared.expect(
            agentId: agentId, instruction: "TASK_ID: T1")
        let second = AgentPipeCompletion.shared.expect(
            agentId: agentId, instruction: "TASK_ID: T2")

        AgentPipeCompletion.shared.cancelExpectation(agentId: agentId, token: first)
        XCTAssertEqual(
            AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId), "T2",
            "an older failed delivery must not clear a newer reservation")

        AgentPipeCompletion.shared.cancelExpectation(agentId: agentId, token: second)
        XCTAssertNil(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId))
    }

    func testSameAgentWriterOperationsStayFIFO() {
        let finished = expectation(description: "serial writer drained")
        let order = LockedOrder()
        let agentId = "writer-order-\(UUID().uuidString)"

        for value in 0..<3 {
            AgentPipeTransport.enqueueForTesting(agentId: agentId) {
                if order.append(value) == 3 { finished.fulfill() }
            }
        }

        wait(for: [finished], timeout: 1)
        XCTAssertEqual(order.snapshot, [0, 1, 2])
    }

    func testMarkdownPresentationPrecomputesInlineAndCodeAttributes() {
        let rendered = AgentMarkdownPresentation.prepare(
            "**ready**\n\n```swift\nlet value = 1\n```")
        XCTAssertEqual(rendered.source, "**ready**\n\n```swift\nlet value = 1\n```")
        XCTAssertEqual(rendered.blocks.count, 2)
        guard case .paragraph(let paragraph) = rendered.blocks[0],
              case .code(let language, let code) = rendered.blocks[1] else {
            return XCTFail("expected prepared paragraph and code blocks")
        }
        XCTAssertEqual(String(paragraph.characters), "ready")
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(String(code.characters), "let value = 1")
    }
}
