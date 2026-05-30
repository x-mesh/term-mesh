import Foundation
import AppKit
import PeerProto

struct WorkspaceSummary: Identifiable, Equatable {
    let id: Data
    let title: String
    let hostSockPath: String
}

struct HostEntry: Identifiable {
    let id: String         // stable dedup key (stableKey)
    var displayName: String
    var isConnected: Bool
    var workspaces: [WorkspaceSummary]
    /// The most-recently-used ephemeral sock path. Updated on each reconnect so
    /// that fetchWorkspaces always connects over the current live tunnel.
    var activeSockPath: String
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

        // Derive a stable dedup key per connection.
        // SSH tunnels use a unique local socket path per session, so keying by
        // hostSockPath would insert a new HostEntry on every reconnect. Instead:
        //   SSH connection  → "ssh:<sshTarget>" (stable across reconnects)
        //   Direct socket   → hostSockPath (already stable)
        // LIMITATION: same sshTarget with different remote sockets collapse into
        // one entry; needs remoteSockPath in connectionInfo to distinguish them.
        func stableKey(for conn: PeerRelayConnectionInfo) -> String {
            if let ssh = conn.sshTarget, !ssh.isEmpty { return "ssh:\(ssh)" }
            return conn.hostSockPath
        }

        var activeKeys = Set<String>()
        for conn in connections {
            let key = stableKey(for: conn)
            activeKeys.insert(key)
            if hosts[key] == nil {
                hosts[key] = HostEntry(
                    id: key,
                    displayName: conn.hostDisplay,
                    isConnected: true,
                    workspaces: [],
                    activeSockPath: conn.hostSockPath
                )
                // Pass the actual (possibly ephemeral) sock path for the relay
                // connection, but store results under the stable key.
                fetchWorkspaces(for: conn.hostSockPath, key: key)
            } else {
                hosts[key]?.isConnected = true
                if !conn.hostDisplay.isEmpty {
                    hosts[key]?.displayName = conn.hostDisplay
                }
                // P1 fix: SSH reconnects produce a new ephemeral hostSockPath.
                // If it changed, refresh activeSockPath and re-fetch workspaces so
                // WorkspaceSummary.hostSockPath never points to the dead tunnel.
                if hosts[key]?.activeSockPath != conn.hostSockPath {
                    hosts[key]?.activeSockPath = conn.hostSockPath
                    hosts[key]?.workspaces = []
                    fetchWorkspaces(for: conn.hostSockPath, key: key)
                }
            }
        }

        for key in hosts.keys where !activeKeys.contains(key) {
            hosts[key]?.isConnected = false
        }
    }

    private func fetchWorkspaces(for hostSockPath: String, key: String) {
        fetchTasks[key]?.cancel()
        let path = hostSockPath
        // Task inherits @MainActor; await suspensions yield main without blocking it.
        fetchTasks[key] = Task {
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
                // Stale-path guard: a reconnect may have superseded this fetch with a
                // newer ephemeral path. Drop the result if this task was cancelled or the
                // host's active path no longer matches the path we fetched against.
                if Task.isCancelled || self.hosts[key]?.activeSockPath != path {
                    return
                }
                let summaries = workspaces.map {
                    WorkspaceSummary(
                        id: $0.workspaceID,
                        title: $0.title.isEmpty ? "<workspace>" : $0.title,
                        hostSockPath: path
                    )
                }
                self.hosts[key]?.workspaces = summaries
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
