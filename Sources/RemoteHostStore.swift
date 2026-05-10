import Foundation
import AppKit
import PeerProto

struct WorkspaceSummary: Identifiable, Equatable {
    let id: Data
    let title: String
    let hostSockPath: String
}

struct HostEntry: Identifiable {
    let id: String  // hostSockPath
    var displayName: String
    var isConnected: Bool
    var workspaces: [WorkspaceSummary]
}

@MainActor
final class RemoteHostStore: ObservableObject {
    static let shared = RemoteHostStore()

    @Published private(set) var hosts: [String: HostEntry] = [:]

    var sortedHosts: [HostEntry] {
        hosts.values.sorted { $0.displayName < $1.displayName }
    }

    private var observer: NSObjectProtocol?
    private var fetchTasks: [String: Task<Void, Never>] = [:]

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: PeerClientCoordinator.relaysDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncFromCoordinator() }
        }
        // Catch connections that opened before the sidebar first rendered.
        syncFromCoordinator()
    }

    deinit {
        if let token = observer {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func syncFromCoordinator() {
        let connections = PeerClientCoordinator.shared.activeConnections()
        let activePaths = Set(connections.map { $0.hostSockPath })

        for conn in connections {
            let path = conn.hostSockPath
            if hosts[path] == nil {
                hosts[path] = HostEntry(
                    id: path,
                    displayName: conn.hostDisplay,
                    isConnected: true,
                    workspaces: []
                )
                fetchWorkspaces(for: path)
            } else {
                hosts[path]?.isConnected = true
                if !conn.hostDisplay.isEmpty {
                    hosts[path]?.displayName = conn.hostDisplay
                }
            }
        }

        for key in hosts.keys where !activePaths.contains(key) {
            hosts[key]?.isConnected = false
        }
    }

    private func fetchWorkspaces(for hostSockPath: String) {
        fetchTasks[hostSockPath]?.cancel()
        let path = hostSockPath
        // Task inherits @MainActor; await suspensions yield main without blocking it.
        fetchTasks[path] = Task {
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: path)
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    workspaces = try await conn.session.listWorkspaces()
                } catch {
                    await conn.cancel()
                    return
                }
                await conn.cancel()
                let summaries = workspaces.map {
                    WorkspaceSummary(
                        id: $0.workspaceID,
                        title: $0.title.isEmpty ? "<workspace>" : $0.title,
                        hostSockPath: path
                    )
                }
                self.hosts[path]?.workspaces = summaries
            } catch {
                // Host disconnected between detection and fetch — ignore.
            }
        }
    }

    func openWorkspace(_ workspace: WorkspaceSummary) {
        let path = workspace.hostSockPath
        let displayName = hosts[path]?.displayName
        Task {
            do {
                let conn = try await PeerRelaySession.connect(hostSockPath: path)
                let workspaces: [Termmesh_Peer_V1_Workspace]
                do {
                    workspaces = try await conn.session.listWorkspaces()
                } catch {
                    await conn.cancel()
                    return
                }
                await conn.cancel()
                guard let chosen = workspaces.first(where: { $0.workspaceID == workspace.id })
                    ?? workspaces.first
                else { return }
                PeerClientCoordinator.shared.openWorkspaceRelayForSidebar(
                    hostSockPath: path,
                    workspace: chosen,
                    hostDisplayName: displayName
                )
            } catch {
                NSLog("[remote-host-store] openWorkspace failed: %@", String(describing: error))
            }
        }
    }
}
