import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ProjectSyncViewModelTests: XCTestCase {
    @MainActor
    func testFixtureExposesFullStateWithoutDaemonMutation() {
        let operation = Self.operation(id: "11111111111111111111111111111111", state: .running)
        let snapshot = ProjectSyncSnapshot(
            projectID: operation.projectID,
            projectName: "term-mesh",
            projectPath: "/tmp/term-mesh",
            devices: [
                ProjectSyncDevice(id: String(repeating: "a", count: 64), name: "MacBook", status: .approved, lastSeen: "now"),
                ProjectSyncDevice(id: String(repeating: "b", count: 64), name: "Old Mac", status: .revoked, lastSeen: nil),
            ],
            activeOperation: operation,
            conflicts: [ProjectSyncConflict(id: "c1", path: "Sources/App.swift", summary: "Both devices changed this file")],
            gcRoot: ProjectSyncGCRoot(manifestID: String(repeating: "c", count: 64), retainedObjects: 42),
            capabilities: ProjectSyncCapabilities(Set(ProjectSyncCapability.allCases)),
            recoveryRequiresUserPresence: true
        )
        let model = ProjectSyncViewModel(client: RecordingProjectSyncClient(), snapshot: snapshot)

        XCTAssertEqual(model.snapshot.devices.map(\.status), [.approved, .revoked])
        XCTAssertEqual(model.snapshot.conflicts.count, 1)
        XCTAssertEqual(model.snapshot.gcRoot?.retainedObjects, 42)
        XCTAssertTrue(model.userPresenceRequired)
    }

    @MainActor
    func testCancelUsesExactDisplayedOperationAndProjectIDs() async {
        let client = RecordingProjectSyncClient()
        let operation = Self.operation(id: "1234567890abcdef1234567890abcdef", state: .running)
        let model = ProjectSyncViewModel(client: client, snapshot: Self.snapshot(operation: operation))

        await model.cancelActiveOperation()

        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [.cancel(operation.operationID, operation.projectID)])
        XCTAssertEqual(model.snapshot.activeOperation?.state, .cancelRequested)
    }

    @MainActor
    func testRetryUsesExactFailedOperationAndFreshRequestID() async {
        let client = RecordingProjectSyncClient()
        let operation = Self.operation(id: "fedcba0987654321fedcba0987654321", state: .failed)
        let model = ProjectSyncViewModel(client: client, snapshot: Self.snapshot(operation: operation))

        await model.retryActiveOperation()

        let calls = await client.recordedCalls()
        guard case .retry(let operationID, let projectID, let requestID) = calls.first else {
            return XCTFail("Expected one retry call")
        }
        XCTAssertEqual(operationID, operation.operationID)
        XCTAssertEqual(projectID, operation.projectID)
        XCTAssertEqual(requestID.count, 32)
        XCTAssertNotEqual(requestID, operation.requestID)
    }

    @MainActor
    func testMissingProjectFailsExplicitlyWithoutRPC() async {
        let client = RecordingProjectSyncClient()
        let model = ProjectSyncViewModel(client: client)

        await model.startManifestScan()

        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(model.errorMessage, "Project discovery is unavailable. Register the project with the daemon first.")
    }

    @MainActor
    func testTelemetryUpdatesStateOnly() async {
        let client = RecordingProjectSyncClient()
        let operation = Self.operation(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", state: .running)
        let model = ProjectSyncViewModel(client: client, snapshot: Self.snapshot(operation: operation))

        await model.refreshActiveOperation()

        XCTAssertEqual(model.snapshot.activeOperation?.operationID, operation.operationID)
        XCTAssertEqual(model.snapshot.activeOperation?.state, .succeeded)
        XCTAssertEqual(model.action, .idle)
    }

    private static func snapshot(operation: ProjectSyncOperation) -> ProjectSyncSnapshot {
        ProjectSyncSnapshot(
            projectID: operation.projectID,
            projectName: "term-mesh",
            projectPath: operation.root,
            devices: [],
            activeOperation: operation,
            conflicts: [],
            gcRoot: nil,
            capabilities: .liveManifestScanOnly,
            recoveryRequiresUserPresence: true
        )
    }

    private static func operation(id: String, state: ProjectSyncOperationState) -> ProjectSyncOperation {
        ProjectSyncOperation(
            operationID: id,
            requestID: "00112233445566778899aabbccddeeff",
            projectID: String(repeating: "1", count: 64),
            kind: "manifest_scan",
            root: "/tmp/term-mesh",
            state: state,
            result: state == .succeeded ? ProjectSyncOperationResult(manifestRoot: String(repeating: "2", count: 64), entries: 8) : nil,
            errorCode: state == .failed ? "manifest_scan_failed" : nil,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 2
        )
    }
}

private actor RecordingProjectSyncClient: ProjectSyncClient {
    enum Call: Equatable {
        case start(String, String)
        case status(String, String)
        case cancel(String, String)
        case retry(String, String, String)
    }

    private var calls: [Call] = []

    func recordedCalls() -> [Call] { calls }

    func startManifestScan(projectID: String, requestID: String) async throws -> ProjectSyncOperation {
        calls.append(.start(projectID, requestID))
        return makeOperation(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", projectID: projectID, requestID: requestID, state: .pending)
    }

    func status(operationID: String, projectID: String) async throws -> ProjectSyncOperation {
        calls.append(.status(operationID, projectID))
        return makeOperation(id: operationID, projectID: projectID, requestID: "00112233445566778899aabbccddeeff", state: .succeeded)
    }

    func cancel(operationID: String, projectID: String) async throws -> ProjectSyncOperation {
        calls.append(.cancel(operationID, projectID))
        return makeOperation(id: operationID, projectID: projectID, requestID: "00112233445566778899aabbccddeeff", state: .cancelRequested)
    }

    func retry(operationID: String, projectID: String, requestID: String) async throws -> ProjectSyncOperation {
        calls.append(.retry(operationID, projectID, requestID))
        return makeOperation(id: String(repeating: "c", count: 32), projectID: projectID, requestID: requestID, state: .pending)
    }

    private func makeOperation(
        id: String,
        projectID: String,
        requestID: String,
        state: ProjectSyncOperationState
    ) -> ProjectSyncOperation {
        ProjectSyncOperation(
            operationID: id,
            requestID: requestID,
            projectID: projectID,
            kind: "manifest_scan",
            root: "/tmp/term-mesh",
            state: state,
            result: state == .succeeded ? ProjectSyncOperationResult(manifestRoot: String(repeating: "d", count: 64), entries: 8) : nil,
            errorCode: nil,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 2
        )
    }
}
