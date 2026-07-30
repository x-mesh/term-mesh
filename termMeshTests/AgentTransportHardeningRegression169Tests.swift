import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class AgentTransportHardeningRegression169Tests: XCTestCase {
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
