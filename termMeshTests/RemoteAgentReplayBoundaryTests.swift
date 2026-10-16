import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class RemoteAgentReplayBoundaryTests: XCTestCase {
    func testEqualSeqsMeanNoHistory() {
        XCTAssertEqual(
            RemoteAgentReplayBoundary.historyBytes(deliveredHostSeq: 4_096, newInitialSeq: 4_096),
            0
        )
    }

    func testTheReplayedPrefixIsTheDistanceBackToTheDeliveredSeq() {
        XCTAssertEqual(
            RemoteAgentReplayBoundary.historyBytes(deliveredHostSeq: 70_000, newInitialSeq: 4_464),
            65_536
        )
    }

    /// A fresh hub's snapshot can be longer than everything the tap emitted,
    /// so the host reports an initial seq just below `UInt64.max`.
    func testAWrappedInitialSeqStillMeasuresTheReplayedPrefix() {
        XCTAssertEqual(
            RemoteAgentReplayBoundary.historyBytes(
                deliveredHostSeq: 100,
                newInitialSeq: UInt64.max - 99
            ),
            200
        )
    }

    func testAnAttachThatStartsPastTheDeliveredSeqIsAGap() {
        XCTAssertNil(
            RemoteAgentReplayBoundary.historyBytes(deliveredHostSeq: 1_000, newInitialSeq: 1_001)
        )
    }

    func testAHostSeqResetIsAGap() {
        XCTAssertNil(
            RemoteAgentReplayBoundary.historyBytes(deliveredHostSeq: 5_000_000, newInitialSeq: 0,
                                                   maxBytes: 1_000_000)
        )
    }

    func testTheRingCapacityIsTheLargestHistory() {
        let cap = RemoteAgentReplayBoundary.maxReplayBytes
        XCTAssertEqual(
            RemoteAgentReplayBoundary.historyBytes(deliveredHostSeq: cap + 10, newInitialSeq: 10),
            cap
        )
        XCTAssertNil(
            RemoteAgentReplayBoundary.historyBytes(deliveredHostSeq: cap + 11, newInitialSeq: 10)
        )
    }
}
