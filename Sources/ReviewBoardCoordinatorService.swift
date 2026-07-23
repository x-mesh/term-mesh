import Foundation
import Darwin

enum ReviewBoardCoordinatorSettings {
    static let enabledEnvironmentKey = "TERMMESH_COORDINATOR_ENABLED"
    static let socketPathEnvironmentKey = "TERMMESH_COORDINATOR_UNIX_PATH"
    static let binaryPathEnvironmentKey = "TERMMESH_COORDINATOR_BINARY"
    static let distributedFeatureKey = "distributedWorkspaces.enabled"

    static func isIntegrationEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        environment[enabledEnvironmentKey] == "1"
            && defaults.bool(forKey: distributedFeatureKey)
            && defaults.bool(forKey: ReviewBoardSettings.enabledKey)
    }

    static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = {
#if DEBUG
            true
#else
            false
#endif
        }()
    ) -> String {
        if let override = environment[socketPathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        let appSocket = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            isDebugBuild: isDebugBuild
        )
        return appSocket.replacingOccurrences(of: "/term-mesh", with: "/tm-coordinator")
    }
}

enum ReviewBoardCoordinatorError: Error, Equatable {
    case disabled
    case socketPathTooLong
    case invalidResponse
    case jsonRPCError(code: Int?, message: String)
    case syscall(String, Int32)
}

final class ReviewBoardCoordinatorClient: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.termmesh.review-board.coordinator", qos: .utility)
    private var nextID = 1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func fetchSnapshot() async throws -> ReviewBoardSnapshot {
        async let statusResponse = request(method: "orchestration.status")
        async let taskResponse = request(method: "task.list")
        async let eventResponse = request(method: "events.subscribe", params: ["scope": "review_board", "replay": false])

        let statusObject = try await statusResponse as? [String: Any] ?? [:]
        let taskObject = try await taskResponse
        _ = try? await eventResponse

        let taskRows: [[String: Any]]
        if let rows = taskObject as? [[String: Any]] {
            taskRows = rows
        } else if let object = taskObject as? [String: Any],
                  let rows = object["tasks"] as? [[String: Any]] {
            taskRows = rows
        } else {
            taskRows = []
        }

        let reviewTasks = taskRows.compactMap(ReviewBoardTask.init(dictionary:))
        let panelRuns = (statusObject["panel_runs"] as? [[String: Any]] ?? [])
            .compactMap(ReviewBoardPanelRun.init(dictionary:))
        let memMeshAvailable = statusObject["mem_mesh_available"] as? Bool
            ?? statusObject["memMeshAvailable"] as? Bool
            ?? true
        let suspectHost = statusObject["suspect_host"] as? Bool
            ?? statusObject["suspectHost"] as? Bool
            ?? reviewTasks.contains { $0.labels.contains("suspect-host") }
        let fencedZombie = statusObject["fenced_zombie"] as? Bool
            ?? statusObject["fencedZombie"] as? Bool
            ?? reviewTasks.contains { $0.labels.contains("fenced-zombie") }

        return ReviewBoardSnapshot(
            tasks: reviewTasks,
            panelRuns: panelRuns,
            coordinatorOnline: true,
            memMeshAvailable: memMeshAvailable,
            suspectHost: suspectHost,
            fencedZombie: fencedZombie
        )
    }

    func subscribeEvents(onEvent: @escaping @Sendable () -> Void) {
        queue.async { [socketPath] in
            guard let fd = try? Self.connect(socketPath: socketPath) else { return }
            defer { Darwin.close(fd) }
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "events.subscribe",
                "params": ["scope": "review_board"],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  Self.writeLine(fd: fd, data: data) else {
                return
            }
            while let line = Self.readLine(fd: fd) {
                switch Self.eventFrame(from: line) {
                case .relevant, .gap:
                    onEvent()
                case .keepalive, .ack, .ignored:
                    continue
                }
            }
        }
    }

    private func request(method: String, params: [String: Any]? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let fd = try Self.connect(socketPath: socketPath)
                    defer { Darwin.close(fd) }
                    let id = nextRequestID()
                    var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
                    if let params { payload["params"] = params }
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    guard Self.writeLine(fd: fd, data: data),
                          let line = Self.readLine(fd: fd),
                          let lineData = line.data(using: .utf8),
                          let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        throw ReviewBoardCoordinatorError.invalidResponse
                    }
                    if let error = object["error"] as? [String: Any] {
                        throw ReviewBoardCoordinatorError.jsonRPCError(
                            code: error["code"] as? Int,
                            message: error["message"] as? String ?? "Coordinator request failed"
                        )
                    }
                    guard let result = object["result"] else {
                        throw ReviewBoardCoordinatorError.invalidResponse
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func nextRequestID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    private static func connect(socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ReviewBoardCoordinatorError.syscall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else {
            Darwin.close(fd)
            throw ReviewBoardCoordinatorError.socketPathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                for (offset, byte) in path.enumerated() {
                    bytes[offset] = CChar(bitPattern: byte)
                }
            }
        }
        let rc = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ReviewBoardCoordinatorError.syscall("connect", code)
        }
        return fd
    }

    static func writeLine(fd: Int32, data: Data) -> Bool {
        var line = data
        line.append(0x0A)
        return line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var sent = 0
            while sent < line.count {
                let written = Darwin.write(fd, base.advanced(by: sent), line.count - sent)
                guard written > 0 else { return false }
                sent += written
            }
            return true
        }
    }

    static func readLine(fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { break }
            guard count > 0 else { return nil }
            if byte == 0x0A { break }
            bytes.append(byte)
            if bytes.count > 1_048_576 { return nil }
        }
        guard !bytes.isEmpty else { return nil }
        return String(data: Data(bytes), encoding: .utf8)
    }

    enum EventFrame: Equatable {
        case ack
        case keepalive
        case gap
        case relevant
        case ignored
    }

    static func eventFrame(from line: String) -> EventFrame {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }
        if object["jsonrpc"] as? String == "2.0" {
            return .ack
        }
        let kind = (
            object["kind"] as? String
                ?? object["event_kind"] as? String
                ?? object["eventKind"] as? String
                ?? object["type"] as? String
                ?? ((object["event"] as? [String: Any])?["kind"] as? String)
                ?? ""
        )
        if kind == "keepalive" || object["keepalive"] as? Bool == true {
            return .keepalive
        }
        if kind == "event_gap" || object["event_gap"] as? Bool == true {
            return .gap
        }
        if kind == "error", object["code"] as? String == "event_too_large" {
            return .gap
        }
        return relevantEventKinds.contains(kind) ? .relevant : .ignored
    }

    private static let relevantEventKinds: Set<String> = [
        "project_added",
        "host_observed",
        "task_created",
        "task_placed",
        "task_reassigned",
        "task_suspected",
        "task_quarantined",
        "fence_issued",
        "review_snapshot_recorded",
        "attempt_approved",
        "attempt_rejected",
        "merge_queue_transitioned",
    ]
}

@MainActor
final class ReviewBoardCoordinatorService: ObservableObject {
    static let shared = ReviewBoardCoordinatorService()

    @Published private(set) var snapshot = ReviewBoardSnapshot.empty

    private var client: ReviewBoardCoordinatorClient?
    private var process: Process?
    private var refreshTask: Task<Void, Never>?
    private var eventRefreshWorkItem: DispatchWorkItem?
    private var subscriptionStarted = false

    func startIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        guard ReviewBoardCoordinatorSettings.isIntegrationEnabled(environment: environment, defaults: defaults) else {
            stop()
            return
        }
        let socketPath = ReviewBoardCoordinatorSettings.socketPath(environment: environment)
        if client == nil {
            client = ReviewBoardCoordinatorClient(socketPath: socketPath)
        }
        startProcessIfNeeded(socketPath: socketPath, environment: environment)
        refresh()
        startSubscriptionIfNeeded()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        eventRefreshWorkItem?.cancel()
        eventRefreshWorkItem = nil
        subscriptionStarted = false
        client = nil
        process?.terminate()
        process = nil
        snapshot = .empty
    }

    func providerSnapshot() -> ReviewBoardSnapshot {
        let local = TeamDataStoreReviewBoardSnapshotProvider().snapshot()
        guard ReviewBoardCoordinatorSettings.isIntegrationEnabled() else { return local }
        guard snapshot.coordinatorOnline else {
            var offline = local
            offline.coordinatorOnline = false
            return offline
        }
        return snapshot
    }

    func refresh() {
        guard let client else { return }
        refreshTask?.cancel()
        refreshTask = Task.detached { [weak self, client] in
            let next: ReviewBoardSnapshot
            do {
                next = try await client.fetchSnapshot()
            } catch {
                next = ReviewBoardSnapshot(
                    tasks: [],
                    panelRuns: [],
                    coordinatorOnline: false,
                    memMeshAvailable: false,
                    suspectHost: false,
                    fencedZombie: false
                )
            }
            await MainActor.run {
                self?.snapshot = next
                NotificationCenter.default.post(name: .reviewBoardSnapshotDidChange, object: nil)
            }
        }
    }

    private func startSubscriptionIfNeeded() {
        guard !subscriptionStarted, let client else { return }
        subscriptionStarted = true
        client.subscribeEvents { [weak self] in
            Task { @MainActor in
                self?.scheduleEventRefresh()
            }
        }
    }

    private func scheduleEventRefresh() {
        eventRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        eventRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func startProcessIfNeeded(socketPath: String, environment: [String: String]) {
        guard process == nil else { return }
        guard access(socketPath, F_OK) != 0 else { return }
        let binary = environment[ReviewBoardCoordinatorSettings.binaryPathEnvironmentKey] ?? "tm-coordinator"
        let process = Process()
        process.executableURL = binary.contains("/")
            ? URL(fileURLWithPath: binary)
            : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = binary.contains("/") ? [] : [binary]
        var processEnvironment = environment
        processEnvironment[ReviewBoardCoordinatorSettings.socketPathEnvironmentKey] = socketPath
        process.environment = processEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }
}

struct CoordinatorReviewBoardSnapshotProvider {
    @MainActor
    func snapshot() -> ReviewBoardSnapshot {
        ReviewBoardCoordinatorService.shared.providerSnapshot()
    }
}
