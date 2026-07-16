import Foundation
import Bonsplit

enum ProjectSyncCapability: String, CaseIterable, Hashable, Sendable {
    case projectDiscovery
    case devices
    case conflicts
    case garbageCollection
    case recoveryExport
    case deviceRevocation
}

struct ProjectSyncCapabilities: Equatable, Sendable {
    private var available: Set<ProjectSyncCapability>

    init(_ available: Set<ProjectSyncCapability> = []) {
        self.available = available
    }

    func supports(_ capability: ProjectSyncCapability) -> Bool {
        available.contains(capability)
    }

    static let liveManifestScanOnly = ProjectSyncCapabilities()
}

struct ProjectSyncDevice: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        case approved
        case revoked
    }

    let id: String
    let name: String
    let status: Status
    let lastSeen: String?
}

struct ProjectSyncConflict: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let summary: String
}

struct ProjectSyncGCRoot: Equatable, Sendable {
    let manifestID: String
    let retainedObjects: UInt64
}

enum ProjectSyncOperationState: String, Codable, Sendable {
    case pending
    case running
    case cancelRequested = "cancel_requested"
    case succeeded
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted: return true
        case .pending, .running, .cancelRequested: return false
        }
    }
}

struct ProjectSyncOperationResult: Codable, Equatable, Sendable {
    let manifestRoot: String
    let entries: UInt64

    enum CodingKeys: String, CodingKey {
        case manifestRoot = "manifest_root"
        case entries
    }
}

struct ProjectSyncOperation: Codable, Equatable, Identifiable, Sendable {
    let operationID: String
    let requestID: String
    let projectID: String
    let kind: String
    let root: String
    let state: ProjectSyncOperationState
    let result: ProjectSyncOperationResult?
    let errorCode: String?
    let createdAtMilliseconds: UInt64
    let updatedAtMilliseconds: UInt64

    var id: String { operationID }

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case requestID = "request_id"
        case projectID = "project_id"
        case kind
        case root
        case state
        case result
        case errorCode = "error_code"
        case createdAtMilliseconds = "created_at_ms"
        case updatedAtMilliseconds = "updated_at_ms"
    }
}

struct ProjectSyncSnapshot: Equatable, Sendable {
    let projectID: String?
    let projectName: String
    let projectPath: String?
    let devices: [ProjectSyncDevice]
    let activeOperation: ProjectSyncOperation?
    let conflicts: [ProjectSyncConflict]
    let gcRoot: ProjectSyncGCRoot?
    let capabilities: ProjectSyncCapabilities
    let recoveryRequiresUserPresence: Bool

    static let liveUnavailable = ProjectSyncSnapshot(
        projectID: nil,
        projectName: "No registered project",
        projectPath: nil,
        devices: [],
        activeOperation: nil,
        conflicts: [],
        gcRoot: nil,
        capabilities: .liveManifestScanOnly,
        recoveryRequiresUserPresence: true
    )
}

enum ProjectSyncClientError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let capability): return "\(capability) is not available from this daemon."
        case .invalidResponse: return "The daemon returned an invalid Project Sync response."
        }
    }
}

protocol ProjectSyncClient: Sendable {
    func startManifestScan(projectID: String, requestID: String) async throws -> ProjectSyncOperation
    func status(operationID: String, projectID: String) async throws -> ProjectSyncOperation
    func cancel(operationID: String, projectID: String) async throws -> ProjectSyncOperation
    func retry(operationID: String, projectID: String, requestID: String) async throws -> ProjectSyncOperation
}

final class ProjectSyncDaemonClient: ProjectSyncClient, @unchecked Sendable {
    private let daemon: any DaemonService
    private let queue = DispatchQueue(label: "com.termmesh.project-sync.rpc", qos: .utility)

    init(daemon: any DaemonService) {
        self.daemon = daemon
    }

    func startManifestScan(projectID: String, requestID: String) async throws -> ProjectSyncOperation {
        try await call(method: "operation.start", params: [
            "project_id": projectID,
            "request_id": requestID,
            "kind": "manifest_scan",
        ])
    }

    func status(operationID: String, projectID: String) async throws -> ProjectSyncOperation {
        try await call(method: "operation.status", params: operationParams(operationID, projectID))
    }

    func cancel(operationID: String, projectID: String) async throws -> ProjectSyncOperation {
        try await call(method: "operation.cancel", params: operationParams(operationID, projectID))
    }

    func retry(operationID: String, projectID: String, requestID: String) async throws -> ProjectSyncOperation {
        var params = operationParams(operationID, projectID)
        params["request_id"] = requestID
        return try await call(method: "operation.retry", params: params)
    }

    private func operationParams(_ operationID: String, _ projectID: String) -> [String: Any] {
        ["operation_id": operationID, "project_id": projectID]
    }

    private func call(method: String, params: [String: Any]) async throws -> ProjectSyncOperation {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [daemon] in
                guard let raw = daemon.rpcCallRaw(method: method, params: params),
                      let data = raw.data(using: .utf8),
                      let operation = try? JSONDecoder().decode(ProjectSyncOperation.self, from: data) else {
                    continuation.resume(throwing: ProjectSyncClientError.invalidResponse)
                    return
                }
                continuation.resume(returning: operation)
            }
        }
    }
}

@MainActor
final class ProjectSyncViewModel: ObservableObject {
    enum Action: Equatable {
        case idle
        case starting
        case cancelling(String)
        case retrying(String)
        case refreshing(String)
    }

    @Published private(set) var snapshot: ProjectSyncSnapshot
    @Published private(set) var action: Action = .idle
    @Published private(set) var errorMessage: String?

    let client: any ProjectSyncClient

    init(client: any ProjectSyncClient, snapshot: ProjectSyncSnapshot = .liveUnavailable) {
        self.client = client
        self.snapshot = snapshot
    }

    var userPresenceRequired: Bool { snapshot.recoveryRequiresUserPresence }
    var canStartManifestScan: Bool { snapshot.projectID != nil && action == .idle }

    func replaceSnapshot(_ snapshot: ProjectSyncSnapshot) {
        self.snapshot = snapshot
        errorMessage = nil
    }

    func startManifestScan() async {
        guard let projectID = snapshot.projectID else {
            errorMessage = "Project discovery is unavailable. Register the project with the daemon first."
            return
        }
        let requestID = Self.requestID()
        action = .starting
        #if DEBUG
        dlog("sync.ui.start project=\(Self.short(projectID)) request=\(Self.short(requestID))")
        #endif
        await perform {
            try await client.startManifestScan(projectID: projectID, requestID: requestID)
        }
    }

    func refreshActiveOperation() async {
        guard let operation = snapshot.activeOperation else { return }
        action = .refreshing(operation.operationID)
        await perform {
            try await client.status(operationID: operation.operationID, projectID: operation.projectID)
        }
    }

    func cancelActiveOperation() async {
        guard let operation = snapshot.activeOperation, !operation.state.isTerminal else { return }
        let exactOperationID = operation.operationID
        let exactProjectID = operation.projectID
        action = .cancelling(exactOperationID)
        #if DEBUG
        dlog("sync.ui.cancel project=\(Self.short(exactProjectID)) op=\(Self.short(exactOperationID))")
        #endif
        await perform {
            try await client.cancel(operationID: exactOperationID, projectID: exactProjectID)
        }
    }

    func retryActiveOperation() async {
        guard let operation = snapshot.activeOperation,
              operation.state.isTerminal,
              operation.state != .succeeded else { return }
        let exactOperationID = operation.operationID
        let exactProjectID = operation.projectID
        let requestID = Self.requestID()
        action = .retrying(exactOperationID)
        #if DEBUG
        dlog("sync.ui.retry project=\(Self.short(exactProjectID)) op=\(Self.short(exactOperationID)) request=\(Self.short(requestID))")
        #endif
        await perform {
            try await client.retry(
                operationID: exactOperationID,
                projectID: exactProjectID,
                requestID: requestID
            )
        }
    }

    func reportUnavailable(_ capability: ProjectSyncCapability) {
        errorMessage = "\(capabilityLabel(capability)) is not exposed by the current daemon."
    }

    private func perform(_ operation: () async throws -> ProjectSyncOperation) async {
        do {
            let updated = try await operation()
            let previous = snapshot.activeOperation?.state.rawValue ?? "none"
            snapshot = ProjectSyncSnapshot(
                projectID: snapshot.projectID,
                projectName: snapshot.projectName,
                projectPath: snapshot.projectPath,
                devices: snapshot.devices,
                activeOperation: updated,
                conflicts: snapshot.conflicts,
                gcRoot: snapshot.gcRoot,
                capabilities: snapshot.capabilities,
                recoveryRequiresUserPresence: snapshot.recoveryRequiresUserPresence
            )
            errorMessage = nil
            #if DEBUG
            dlog("sync.ui.state project=\(Self.short(updated.projectID)) op=\(Self.short(updated.operationID)) from=\(previous) to=\(updated.state.rawValue)")
            #endif
        } catch {
            errorMessage = error.localizedDescription
            #if DEBUG
            dlog("sync.ui.error kind=\(String(describing: type(of: error)))")
            #endif
        }
        action = .idle
    }

    private func capabilityLabel(_ capability: ProjectSyncCapability) -> String {
        switch capability {
        case .projectDiscovery: return "Project discovery"
        case .devices: return "Device management"
        case .conflicts: return "Conflict resolution"
        case .garbageCollection: return "Garbage collection"
        case .recoveryExport: return "Recovery export"
        case .deviceRevocation: return "Device revocation"
        }
    }

    private static func requestID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func short(_ identifier: String) -> String {
        String(identifier.prefix(8))
    }
}
