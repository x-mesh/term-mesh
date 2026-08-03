import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ProcessTreeSnapshotTests: XCTestCase {
    func testTargetedTraversalFindsEveryGenerationAndStopsOnCycles() {
        let children: [Int32: [Int32]] = [
            10: [11, 13],
            11: [12],
            12: [10],
        ]

        XCTAssertEqual(
            ProcessTreeSnapshot.descendantPIDs(of: 10) { children[$0] ?? [] },
            Set([11, 12, 13])
        )
    }

    func testTargetedTraversalRejectsRootLookupFailureButToleratesExitedChild() {
        XCTAssertNil(ProcessTreeSnapshot.descendantPIDs(of: 10) { _ in nil })

        XCTAssertEqual(
            ProcessTreeSnapshot.descendantPIDs(of: 10) { pid in
                if pid == 10 { return [11] }
                return nil
            },
            Set([11])
        )
    }

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

    func testLiveTargetedLookupFindsSpawnedDirectChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let children = try XCTUnwrap(ProcessTreeSnapshot.childPIDs(of: getpid()))
        XCTAssertTrue(children.contains(process.processIdentifier))
    }
}
