import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class RemoteAgentReplayBoundaryTests: XCTestCase {
    private let cap = RemoteAgentReplayBoundary.maxReplayBytes

    func testEqualSeqsMeanNoHistory() {
        XCTAssertEqual(
            RemoteAgentReplayBoundary.historyBytes(
                appliedHostSeq: 4_096, retiredInitialSeq: 1, newInitialSeq: 4_096
            ),
            0
        )
    }

    func testTheReplayedPrefixIsTheDistanceBackToTheAppliedSeq() {
        XCTAssertEqual(
            RemoteAgentReplayBoundary.historyBytes(
                appliedHostSeq: 70_000, retiredInitialSeq: 1_000, newInitialSeq: 20_000
            ),
            50_000
        )
    }

    func testAnAttachThatStartsPastTheAppliedSeqIsAGap() {
        XCTAssertNil(
            RemoteAgentReplayBoundary.historyBytes(
                appliedHostSeq: 1_000, retiredInitialSeq: 1, newInitialSeq: 1_001
            )
        )
    }

    /// A fresh tail never starts before an earlier one on the same host, so
    /// an attach that does is a different seq space.
    func testAnAttachThatStartsBeforeTheRetiredOneIsAHostRestart() {
        XCTAssertNil(
            RemoteAgentReplayBoundary.historyBytes(
                appliedHostSeq: 2_000, retiredInitialSeq: 1_500, newInitialSeq: 1_499
            )
        )
    }

    /// A restarted host whose surface began at the same seq as the retired
    /// attach: only the shipped replay cap tells the two apart.
    func testAHostSeqResetPastTheReplayCapIsAGap() {
        XCTAssertNil(
            RemoteAgentReplayBoundary.historyBytes(
                appliedHostSeq: 5_000_000, retiredInitialSeq: 0, newInitialSeq: 0
            )
        )
    }

    /// The daemon's fresh-attach tail is the most any rebuild can replay.
    func testTheFreshAttachTailIsTheLargestHistory() {
        XCTAssertEqual(cap, 64 * 1024)
        XCTAssertEqual(
            RemoteAgentReplayBoundary.historyBytes(
                appliedHostSeq: cap + 10, retiredInitialSeq: 0, newInitialSeq: 10
            ),
            cap
        )
        XCTAssertNil(
            RemoteAgentReplayBoundary.historyBytes(
                appliedHostSeq: cap + 11, retiredInitialSeq: 0, newInitialSeq: 10
            )
        )
    }
}
