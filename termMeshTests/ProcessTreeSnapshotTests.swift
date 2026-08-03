import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ProcessTreeSnapshotTests: XCTestCase {
    func testFindsEveryGenerationButNotUnrelatedProcesses() {
        let snapshot: [ProcessTreeSnapshot.ParentPair] = [
            (pid: 10, parentPID: 1),
            (pid: 11, parentPID: 10),
            (pid: 12, parentPID: 11),
            (pid: 13, parentPID: 10),
            (pid: 99, parentPID: 1),
        ]

        XCTAssertEqual(
            ProcessTreeSnapshot.descendantPIDs(of: 10, in: snapshot),
            Set([11, 12, 13])
        )
    }

    func testIgnoresRootSelfEntryAndTerminatesOnCycle() {
        let snapshot: [ProcessTreeSnapshot.ParentPair] = [
            (pid: 20, parentPID: 20),
            (pid: 21, parentPID: 20),
            (pid: 22, parentPID: 21),
            (pid: 21, parentPID: 22),
        ]

        XCTAssertEqual(
            ProcessTreeSnapshot.descendantPIDs(of: 20, in: snapshot),
            Set([21, 22])
        )
    }

    func testLiveSnapshotContainsLaunchd() throws {
        let snapshot = try XCTUnwrap(ProcessTreeSnapshot.currentParentPairs())
        XCTAssertTrue(snapshot.contains { $0.pid == 1 })
    }
}
