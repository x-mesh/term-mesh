import Foundation
import SwiftUI

/// Protocol abstracting TermMeshDaemon's public API for testability and decoupling.
protocol DaemonService: AnyObject {
    // MARK: - Settings / Configuration
    var worktreeEnabled: Bool { get set }
    var worktreeBaseDir: String { get set }
    var worktreeAutoCleanup: Bool { get set }
    var isLocalhostOnly: Bool { get }
    var isDashboardEnabled: Bool { get }
    var dashboardPort: Int { get }

    // MARK: - Lifecycle
    func startDaemon()
    func stopDaemon()
    func ping() -> Bool

    // MARK: - Worktree
    func createWorktree(repoPath: String, branch: String?) -> WorktreeInfo?
    func createWorktreeWithError(repoPath: String, branch: String?) -> Result<WorktreeInfo, WorktreeCreateError>
    func findGitRoot(from path: String) -> String?
    func removeWorktree(repoPath: String, name: String) -> Bool
    func listWorktrees(repoPath: String) -> [WorktreeInfo]
    func cleanupStaleWorktrees(repoPath: String) -> Int

    // MARK: - Process Management
    func trackPID(_ pid: Int32)
    func untrackPID(_ pid: Int32)
    func stopProcess(pid: Int32) -> Bool
    func resumeProcess(pid: Int32) -> Bool

    // MARK: - Session / Team Sync
    func syncSessions(_ sessions: [[String: Any]])
    func syncTeams(_ payload: [String: Any])
    func watchPath(_ path: String)
    func unwatchPath(_ path: String)

    // MARK: - Agent Management
    func spawnAgents(repoPath: String, count: Int, name: String?, command: String?) -> [AgentSessionInfo]
    func listAgents(includeTerminated: Bool) -> [AgentSessionInfo]
    func getAgent(id: String) -> AgentSessionInfo?
    func bindAgentPanel(sessionId: String, panelId: String) -> Bool
    func unbindAgentPanel(sessionId: String) -> Bool

    // MARK: - Dashboard
    func setAutoStop(enabled: Bool)

    // MARK: - Low-Level RPC
    func rpcCallRaw(method: String, params: [String: Any]) -> String?
}

extension TermMeshDaemon: DaemonService {}

// MARK: - SwiftUI Environment

struct DaemonServiceKey: EnvironmentKey {
    static let defaultValue: (any DaemonService)? = nil
}

struct NotificationServiceKey: EnvironmentKey {
    static let defaultValue: (any NotificationService)? = nil
}

extension EnvironmentValues {
    var daemonService: (any DaemonService)? {
        get { self[DaemonServiceKey.self] }
        set { self[DaemonServiceKey.self] = newValue }
    }

    var notificationService: (any NotificationService)? {
        get { self[NotificationServiceKey.self] }
        set { self[NotificationServiceKey.self] = newValue }
    }
}
