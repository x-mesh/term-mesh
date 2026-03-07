import Bonsplit
import Foundation

/// Manages multi-agent Claude teams where a leader orchestrates N agent instances,
/// each running in split panes within a single workspace.
@MainActor
final class TeamOrchestrator {
    static let shared = TeamOrchestrator()

    struct AgentMember: Identifiable {
        let id: String           // agent-name@team-name
        let name: String         // e.g. "executor", "reviewer"
        let teamName: String
        let model: String        // "opus", "sonnet", "haiku"
        let agentType: String    // "Explore", "executor", etc.
        let color: String        // terminal color
        let workspaceId: UUID
        let panelId: UUID        // specific panel within the workspace
        var parentSessionId: String?
        let createdAt: Date
    }

    struct Team: Identifiable {
        let id: String            // team name
        let leaderSessionId: String
        let workingDirectory: String
        let workspaceId: UUID     // single workspace for all agents
        var agents: [AgentMember]
        let createdAt: Date
    }

    private(set) var teams: [String: Team] = [:]

    // MARK: - Claude Binary

    private func claudeBinaryPath() -> String? {
        // Prefer the symlink at ~/.local/bin/claude
        let localBin = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude")
        if FileManager.default.fileExists(atPath: localBin) { return localBin }

        // Fallback: latest version in ~/.local/share/claude/versions/
        let versionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/claude/versions")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) {
            let sorted = contents.sorted()
            if let latest = sorted.last {
                let path = (versionsDir as NSString).appendingPathComponent(latest)
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }

        return nil
    }

    // MARK: - Team Lifecycle

    /// Create a team of Claude agents in split panes within a single workspace.
    /// Layout: leader console on left, agents stacked vertically on right.
    /// Returns the team info on success.
    func createTeam(
        name: String,
        agents: [(name: String, model: String, agentType: String, color: String, instructions: String)],
        workingDirectory: String,
        leaderSessionId: String,
        leaderMode: String = "repl",
        tabManager: TabManager
    ) -> Team? {
        guard !agents.isEmpty else { return nil }
        guard teams[name] == nil else {
            print("[team] team '\(name)' already exists")
            return nil
        }

        guard let claudePath = claudeBinaryPath() else {
            print("[team] claude binary not found")
            return nil
        }

        let colors = ["green", "blue", "yellow", "magenta", "cyan", "red"]
        var members: [AgentMember] = []

        // Create a single workspace for the team
        let workspace = tabManager.addWorkspace(
            workingDirectory: workingDirectory,
            select: true
        )
        workspace.customTitle = "[\(name)]"
        workspace.title = "[\(name)]"

        // Env vars — skip .zshrc/.zprofile heavy init
        let baseEnv: [String: String] = [
            "CMUX_TEAM_AGENT": "1",
            "CMUX_TEAM_NAME": name,
        ]
        // Agent panes get CLAUDECODE=1; leader pane in "claude" mode must NOT have it
        // (Claude Code refuses to start inside another CLAUDECODE session)
        let agentEnv = baseEnv.merging([
            "CLAUDECODE": "1",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
        ]) { _, new in new }

        let leaderEnv = leaderMode == "claude"
            ? baseEnv  // no CLAUDECODE — leader runs its own Claude instance
            : agentEnv

        // First panel = leader console (left side)
        // Close the default panel and create a new one with the leader script as command
        guard let defaultPanelId = workspace.focusedPanelId else {
            print("[team] no initial panel in workspace")
            return nil
        }

        // Build leader command
        let socketPath = SocketControlSettings.socketPath()
        let scriptPath = leaderScriptPath(mode: leaderMode)
        #if DEBUG
        dlog("[team] leaderMode=\(leaderMode) scriptPath=\(scriptPath ?? "nil")")
        #endif
        let leaderCommand: String? = scriptPath.map { script in
            "\(script) \(socketPath) \(name)"
        }

        // Replace default panel: split from it with leader command, then close the original
        guard let leaderPanel = workspace.newTerminalSplit(
            from: defaultPanelId,
            orientation: .horizontal,
            insertFirst: true,
            focus: true,
            workingDirectory: workingDirectory,
            command: leaderCommand,
            environment: leaderEnv
        ) else {
            print("[team] failed to create leader panel")
            return nil
        }
        let leaderPanelId = leaderPanel.id

        // Set leader pane title
        let leaderLabel = leaderMode == "claude" ? "👑 Leader (Claude)" : "👑 Leader (REPL)"
        workspace.setPanelCustomTitle(panelId: leaderPanelId, title: leaderLabel)

        // Close the original empty panel
        workspace.closePanel(defaultPanelId)

        // Build agent panes with Claude running directly via command parameter
        // This bypasses shell init (.zshrc/.zprofile) entirely for reliable startup.
        for (index, agent) in agents.enumerated() {
            let agentColor = agent.color.isEmpty ? colors[index % colors.count] : agent.color
            let agentId = "\(agent.name)@\(name)"

            let claudeArgs = buildClaudeCommand(
                claudePath: claudePath,
                agentId: agentId,
                agentName: agent.name,
                teamName: name,
                agentColor: agentColor,
                parentSessionId: leaderSessionId,
                agentType: agent.agentType,
                model: agent.model,
                instructions: agent.instructions
            )
            // Wrap in shell -c so env vars from agentEnv are inherited and
            // the terminal stays open (drops to shell) if Claude exits.
            let shellCommand = "\(claudeArgs); exec $SHELL"

            let panelId: UUID
            if index == 0 {
                // First agent: split horizontally from leader (right side)
                guard let panel = workspace.newTerminalSplit(
                    from: leaderPanelId,
                    orientation: .horizontal,
                    focus: false,
                    workingDirectory: workingDirectory,
                    command: shellCommand,
                    environment: agentEnv
                ) else {
                    print("[team] failed to create first agent split pane")
                    return nil
                }
                panelId = panel.id
            } else {
                // Stack agents vertically on the right side
                let splitFrom = members[index - 1].panelId
                guard let panel = workspace.newTerminalSplit(
                    from: splitFrom,
                    orientation: .vertical,
                    focus: false,
                    workingDirectory: workingDirectory,
                    command: shellCommand,
                    environment: agentEnv
                ) else {
                    print("[team] failed to create split pane for agent '\(agent.name)'")
                    continue
                }
                panelId = panel.id
            }

            // Set agent name as pane title
            let colorEmoji = Self.colorEmoji(agentColor)
            workspace.setPanelCustomTitle(panelId: panelId, title: "\(colorEmoji) \(agent.name)")

            let member = AgentMember(
                id: agentId,
                name: agent.name,
                teamName: name,
                model: agent.model,
                agentType: agent.agentType,
                color: agentColor,
                workspaceId: workspace.id,
                panelId: panelId,
                parentSessionId: leaderSessionId,
                createdAt: Date()
            )
            members.append(member)
        }

        let team = Team(
            id: name,
            leaderSessionId: leaderSessionId,
            workingDirectory: workingDirectory,
            workspaceId: workspace.id,
            agents: members,
            createdAt: Date()
        )
        teams[name] = team
        print("[team] created team '\(name)' with \(members.count) agent(s) + leader console")
        return team
    }

    /// Find the leader script for the given mode.
    private func leaderScriptPath(mode: String) -> String? {
        let filename = mode == "claude" ? "team-leader-claude.sh" : "team-leader.sh"
        // Look relative to the working directory first (dev mode)
        let devPath = "scripts/\(filename)"
        if FileManager.default.fileExists(atPath: devPath) { return devPath }
        // Try absolute from known project locations
        let home = NSHomeDirectory()
        let projectPath = "\(home)/work/project/cmux/scripts/\(filename)"
        if FileManager.default.fileExists(atPath: projectPath) { return projectPath }
        return nil
    }

    /// Send text to a specific agent in a team.
    func sendToAgent(teamName: String, agentName: String, text: String, tabManager: TabManager) -> Bool {
        guard let team = teams[teamName] else { return false }
        guard let agent = team.agents.first(where: { $0.name == agentName }) else { return false }
        return sendTextToPanel(workspaceId: agent.workspaceId, panelId: agent.panelId, text: text, tabManager: tabManager)
    }

    private func sendTextToPanel(workspaceId: UUID, panelId: UUID, text: String, tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return false }
        guard let panel = workspace.terminalPanel(for: panelId) else { return false }
        panel.sendInputText(text)
        panel.surface.forceRefresh()
        return true
    }

    /// Broadcast text to all agents in a team.
    func broadcast(teamName: String, text: String, tabManager: TabManager) -> Int {
        guard let team = teams[teamName] else { return 0 }
        var count = 0
        for agent in team.agents {
            if sendToAgent(teamName: teamName, agentName: agent.name, text: text, tabManager: tabManager) {
                count += 1
            }
        }
        return count
    }

    /// List all teams.
    func listTeams() -> [[String: Any]] {
        teams.values.map { team in
            [
                "team_name": team.id,
                "leader_session_id": team.leaderSessionId,
                "working_directory": team.workingDirectory,
                "workspace_id": team.workspaceId.uuidString,
                "agent_count": team.agents.count,
                "agents": team.agents.map { agent in
                    [
                        "id": agent.id,
                        "name": agent.name,
                        "model": agent.model,
                        "agent_type": agent.agentType,
                        "color": agent.color,
                        "workspace_id": agent.workspaceId.uuidString,
                        "panel_id": agent.panelId.uuidString
                    ] as [String: Any]
                },
                "created_at": ISO8601DateFormatter().string(from: team.createdAt)
            ] as [String: Any]
        }
    }

    /// Get team status.
    func teamStatus(name: String) -> [String: Any]? {
        guard let team = teams[name] else { return nil }
        return [
            "team_name": team.id,
            "leader_session_id": team.leaderSessionId,
            "workspace_id": team.workspaceId.uuidString,
            "agent_count": team.agents.count,
            "agents": team.agents.map { agent in
                [
                    "id": agent.id,
                    "name": agent.name,
                    "model": agent.model,
                    "agent_type": agent.agentType,
                    "workspace_id": agent.workspaceId.uuidString,
                    "panel_id": agent.panelId.uuidString
                ] as [String: Any]
            }
        ] as [String: Any]
    }

    /// Destroy a team — send Ctrl-C to all agents and close the workspace.
    func destroyTeam(name: String, tabManager: TabManager) -> Bool {
        guard let team = teams[name] else { return false }
        guard let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }) else {
            teams.removeValue(forKey: name)
            return true
        }

        // Send Ctrl-C to all agent panels
        for agent in team.agents {
            if let panel = workspace.terminalPanel(for: agent.panelId) {
                panel.sendText("\u{03}")  // Ctrl-C
            }
        }

        // Send exit after a delay, then close workspace
        let wsRef = workspace
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for agent in team.agents {
                if let panel = wsRef.terminalPanel(for: agent.panelId) {
                    panel.sendText("exit\n")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            tabManager.closeTab(wsRef)
        }

        teams.removeValue(forKey: name)
        print("[team] destroyed team '\(name)'")
        return true
    }

    // MARK: - Private

    private func buildClaudeCommand(
        claudePath: String,
        agentId: String,
        agentName: String,
        teamName: String,
        agentColor: String,
        parentSessionId: String,
        agentType: String,
        model: String,
        instructions: String = ""
    ) -> String {
        var parts = [
            claudePath.contains(" ") ? "\"\(claudePath)\"" : claudePath,
            "--agent-id \(agentId)",
            "--agent-name \(agentName)",
            "--team-name \(teamName)",
            "--agent-color \(agentColor)",
            "--parent-session-id \(parentSessionId)",
            "--agent-type \(agentType)",
            "--dangerously-skip-permissions"
        ]

        if !model.isEmpty {
            parts.append("--model \(model)")
        }

        if !instructions.isEmpty {
            // Escape single quotes for shell and pass as --append-system-prompt
            let escaped = instructions.replacingOccurrences(of: "'", with: "'\\''")
            parts.append("--append-system-prompt '\(escaped)'")
        }

        return parts.joined(separator: " ")
    }

    private static func colorEmoji(_ color: String) -> String {
        switch color {
        case "green":   return "🟢"
        case "blue":    return "🔵"
        case "yellow":  return "🟡"
        case "red":     return "🔴"
        case "cyan":    return "🩵"
        case "magenta": return "🟣"
        default:        return "⚪"
        }
    }
}
