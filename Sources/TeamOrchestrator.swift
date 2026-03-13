import Bonsplit
import Foundation
import os

/// Manages multi-agent Claude teams where a leader orchestrates N agent instances,
/// each running in split panes within a single workspace.
@MainActor
final class TeamOrchestrator {
    static let shared = TeamOrchestrator()

    struct AgentMember: Identifiable {
        let id: String           // agent-name@team-name
        let name: String         // e.g. "executor", "reviewer"
        let teamName: String
        let cli: String          // "claude", "kiro" (which CLI to run)
        let model: String        // "opus", "sonnet", "haiku"
        let agentType: String    // "Explore", "executor", etc.
        let color: String        // terminal color
        let workspaceId: UUID
        let panelId: UUID        // specific panel within the workspace
        var parentSessionId: String?
        let createdAt: Date
        // Worktree isolation
        var worktreeName: String?
        var worktreePath: String?
        var worktreeBranch: String?
    }

    struct Team: Identifiable {
        let id: String            // team name
        let leaderSessionId: String
        let leaderMode: String    // "repl", "claude", "kiro", "codex", "gemini"
        let leaderPanelId: UUID   // leader pane for sending instructions
        let workingDirectory: String
        let workspaceId: UUID     // single workspace for all agents
        var agents: [AgentMember]
        let createdAt: Date
        var gitRepoRoot: String?  // for worktree cleanup
    }

    private(set) var teams: [String: Team] = [:]

    // MARK: - Bidirectional Communication

    /// B: File-based results — convention directory
    static func resultDirectory(teamName: String) -> String {
        "/tmp/term-mesh-team-\(teamName)"
    }

    /// C: In-memory message queue (agent ↔ agent, agent → leader)
    struct TeamMessage {
        let id: String
        let from: String       // agent name or "leader"
        let to: String?        // recipient agent name, "leader", or nil (broadcast to all)
        let teamName: String
        let content: String
        let timestamp: Date
        let type: String       // "note", "progress", "blocked", "review_ready", "error", "report"
    }

    /// D: Shared task board
    struct TeamTask {
        let id: String
        var title: String
        var details: String?
        var acceptanceCriteria: [String]
        var labels: [String]
        var estimatedSize: Int?
        var assignee: String?
        var status: String     // "queued", "assigned", "in_progress", "blocked", "review_ready", "completed", "failed", "abandoned"
        var priority: Int
        var dependsOn: [String]
        var parentTaskId: String?
        var childTaskIds: [String]
        var reassignmentCount: Int
        var supersededBy: String?
        var blockedReason: String?
        var reviewSummary: String?
        var createdBy: String
        var result: String?
        let createdAt: Date
        var updatedAt: Date
        var startedAt: Date?
        var completedAt: Date?
        var lastProgressAt: Date?
    }

    /// Injected daemon service (defaults to singleton for backward compatibility).
    var daemon: any DaemonService = TermMeshDaemon.shared

    private(set) var messages: [String: [TeamMessage]] = [:]   // team_name → messages
    private(set) var taskBoards: [String: [TeamTask]] = [:]    // team_name → tasks
    private var heartbeats: [String: [String: (at: Date, summary: String?)]] = [:]
    private let staleTaskThreshold: TimeInterval = 10 * 60
    private let staleHeartbeatThreshold: TimeInterval = 5 * 60

    // MARK: - Balanced Split Layout

    /// Compute the split orientation for agent at the given index in the balanced binary tree.
    /// Left children (odd index) alternate from parent; right children (even index) keep parent's.
    private func agentSplitOrientation(at index: Int) -> SplitOrientation {
        if index == 0 { return .horizontal }
        let parentIndex = (index - 1) / 2
        let parentOrientation = agentSplitOrientation(at: parentIndex)
        let isLeftChild = (index % 2 == 1)
        return isLeftChild
            ? (parentOrientation == .horizontal ? .vertical : .horizontal)
            : parentOrientation
    }

    // MARK: - Agent CLI Binaries

    /// Resolve the binary path for a given CLI type ("claude", "kiro", "codex", "gemini").
    /// Uses Settings custom path first, then falls back to auto-detection.
    private func agentBinaryPath(cli: String) -> String? {
        if let path = CLIPathSettings.resolvedPath(for: cli) {
            return path
        }
        // Extra fallback for claude: check versioned installs
        if cli == "claude" {
            let versionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/claude/versions")
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) {
                let sorted = contents.sorted()
                if let latest = sorted.last {
                    let path = (versionsDir as NSString).appendingPathComponent(latest)
                    if FileManager.default.fileExists(atPath: path) { return path }
                }
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
        agents: [(name: String, cli: String, model: String, agentType: String, color: String, instructions: String)],
        workingDirectory: String,
        leaderSessionId: String,
        leaderMode: String = "repl",
        tabManager: TabManager
    ) -> Team? {
        guard !agents.isEmpty else { return nil }

        // Auto-cleanup: if a team with this name exists but its workspace was closed, remove the stale entry
        if let existing = teams[name] {
            if tabManager.tabs.first(where: { $0.id == existing.workspaceId }) == nil {
                Logger.team.info("cleaning up stale team '\(name, privacy: .public)' (workspace closed)")
                teams.removeValue(forKey: name)
            } else {
                Logger.team.info("team '\(name, privacy: .public)' already exists")
                return nil
            }
        }

        // Validate that all required CLI binaries are available
        let cliTypes = Set(agents.map { $0.cli.isEmpty ? "claude" : $0.cli })
        var cliPaths: [String: String] = [:]
        for cli in cliTypes {
            guard let path = agentBinaryPath(cli: cli) else {
                Logger.team.error("\(cli, privacy: .public) binary not found")
                return nil
            }
            cliPaths[cli] = path
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

        // Env vars for agent panes
        // Include essential PATH entries since pane commands may not source shell profiles
        let essentialPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        // Merge essential paths with app's PATH to ensure node/homebrew are available
        let appPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let existingPaths = Set(appPath.split(separator: ":").map(String.init))
        let missingPaths = essentialPaths.filter { !existingPaths.contains($0) }
        let currentPath = (appPath.isEmpty ? essentialPaths : appPath.split(separator: ":").map(String.init) + missingPaths).joined(separator: ":")
        let socketPath = SocketControlSettings.socketPath()
        let baseEnv: [String: String] = [
            "TERMMESH_TEAM_AGENT": "1",
            "CMUX_TEAM_AGENT": "1",
            "TERMMESH_TEAM_NAME": name,
            "CMUX_TEAM_NAME": name,
            "TERMMESH_TEAM": name,
            "CMUX_TEAM": name,
            "TERMMESH_SOCKET": socketPath,
            "CMUX_SOCKET": socketPath,
            "PATH": currentPath,
        ]
        // Agent panes get CLAUDECODE=1; leader pane in "claude" mode must NOT have it
        // (Claude Code refuses to start inside another CLAUDECODE session)
        let claudeAgentEnv = baseEnv.merging([
            "CLAUDECODE": "1",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
        ]) { _, new in new }
        // Kiro agents: no CLAUDECODE (kiro-cli is a separate CLI and doesn't need it)
        let kiroAgentEnv = baseEnv

        // Leader env: Claude leader needs no CLAUDECODE (runs its own instance).
        // Explicitly clear CLAUDECODE to prevent inheritance from parent process
        // (Claude Code refuses to start inside another CLAUDECODE session).
        // Non-claude CLI leaders (kiro, codex, gemini) also clear it.
        // REPL leader gets claudeAgentEnv so nested `claude` calls work.
        let leaderEnv = leaderMode == "repl"
            ? claudeAgentEnv
            : baseEnv.merging(["CLAUDECODE": ""]) { _, new in new }

        // First panel = leader console (left side)
        // Close the default panel and create a new one with the leader script as command
        guard let defaultPanelId = workspace.focusedPanelId else {
            Logger.team.error("no initial panel in workspace")
            return nil
        }

        // Build leader command
        let leaderCommand: String?
        switch leaderMode {
        case "repl":
            let scriptPath = leaderScriptPath(mode: "repl", workingDirectory: workingDirectory)
            leaderCommand = scriptPath.map { "\($0) \(socketPath) \(name)" }
        case "claude":
            if let claudePath = agentBinaryPath(cli: "claude") {
                // Build system prompt from input agent specs (available before panes are created)
                let scriptDir = Self.findScriptsDir(workingDirectory: workingDirectory)
                let agentListStr = agents.enumerated().map { i, a in
                    "  \(i + 1). \(a.name) (\(a.agentType))"
                }.joined(separator: "\n")
                let teamPy = "\(scriptDir)/team.py"
                let systemPrompt = Self.buildLeaderClaudeSystemPrompt(
                    teamName: name,
                    agentList: agentListStr,
                    teamPy: teamPy,
                    socketPath: socketPath
                )
                // Escape single quotes for shell, same approach as buildClaudeCommand
                let escaped = systemPrompt.replacingOccurrences(of: "'", with: "'\\''")
                let quotedPath = claudePath.contains(" ") ? "\"\(claudePath)\"" : claudePath
                leaderCommand = "\(quotedPath) --system-prompt '\(escaped)' --dangerously-skip-permissions"
            } else {
                leaderCommand = nil
            }
        case "kiro":
            if let path = agentBinaryPath(cli: "kiro") {
                leaderCommand = buildKiroCommand(kiroPath: path, agentName: "leader", teamName: name, model: "sonnet", isLeader: true)
            } else { leaderCommand = nil }
        case "codex":
            if let path = agentBinaryPath(cli: "codex") {
                leaderCommand = buildCodexCommand(codexPath: path, agentName: "leader", teamName: name, model: "sonnet")
            } else { leaderCommand = nil }
        case "gemini":
            if let path = agentBinaryPath(cli: "gemini") {
                leaderCommand = buildGeminiCommand(geminiPath: path, agentName: "leader", teamName: name, model: "sonnet")
            } else { leaderCommand = nil }
        default:
            leaderCommand = nil
        }
        #if DEBUG
        dlog("[team] leaderMode=\(leaderMode) leaderCommand=\(leaderCommand ?? "nil")")
        #endif

        // Replace default panel: split from it with leader command, then close the original
        guard let leaderPanel = workspace.newTerminalSplit(
            from: defaultPanelId,
            orientation: .horizontal,
            insertFirst: true,
            focus: true,
            workingDirectory: workingDirectory,
            command: leaderCommand.map { "\($0); exec $SHELL" },
            environment: leaderEnv
        ) else {
            Logger.team.error("failed to create leader panel")
            return nil
        }
        let leaderPanelId = leaderPanel.id

        // Set leader pane title
        let leaderLabel: String
        switch leaderMode {
        case "repl":   leaderLabel = "👑 Leader (REPL)"
        case "claude": leaderLabel = "👑 Leader (Claude)"
        case "kiro":   leaderLabel = "👑 Leader (Kiro)"
        case "codex":  leaderLabel = "👑 Leader (Codex)"
        case "gemini": leaderLabel = "👑 Leader (Gemini)"
        default:       leaderLabel = "👑 Leader (\(leaderMode))"
        }
        workspace.setPanelCustomTitle(panelId: leaderPanelId, title: leaderLabel)

        // Close the original empty panel
        workspace.closePanel(defaultPanelId)

        // Worktree isolation: create per-agent worktrees if enabled
        let useWorktrees = daemon.worktreeEnabled
        let gitRepoRoot = useWorktrees ? daemon.findGitRoot(from: workingDirectory) : nil

        // Build agent panes with Claude running directly via command parameter
        // This bypasses shell init (.zshrc/.zprofile) entirely for reliable startup.
        for (index, agent) in agents.enumerated() {
            let agentColor = agent.color.isEmpty ? colors[index % colors.count] : agent.color
            let agentId = "\(agent.name)@\(name)"

            // Create isolated worktree for this agent if enabled
            var agentWorkDir = workingDirectory
            var wtName: String?
            var wtPath: String?
            var wtBranch: String?

            if useWorktrees, let repoRoot = gitRepoRoot {
                let branchName = "team/\(name)/\(agent.name)"
                let result = daemon.createWorktreeWithError(repoPath: repoRoot, branch: branchName)
                switch result {
                case .success(let info):
                    agentWorkDir = info.path
                    wtName = info.name
                    wtPath = info.path
                    wtBranch = info.branch
                    Logger.team.info("worktree for \(agent.name, privacy: .public): \(info.path, privacy: .public) [\(info.branch, privacy: .public)]")
                case .failure(let error):
                    Logger.team.error("worktree failed for \(agent.name, privacy: .public): \(error, privacy: .public), using shared directory")
                }
            }

            let agentCli = agent.cli.isEmpty ? "claude" : agent.cli
            let cliPath = cliPaths[agentCli]!
            let agentCommand: String
            switch agentCli {
            case "kiro":
                // Build full init prompt embedded in the kiro agent profile.
                // This is loaded at CLI startup — no delayed TUI injection needed.
                let workerPrompt = """
                You are a focused worker agent named '\(agent.name)' in team '\(name)'. \
                Rules: 1) Be EXTREMELY concise — no preamble, no summaries unless asked. \
                2) Output only code, commands, or direct answers. \
                3) When done, state the result in 1-2 lines max. 4) Never repeat the task back.

                Operational rules:
                1. Work should be tracked with task ids.
                2. When you begin a task, run `./scripts/team.py task start <task_id>`.
                3. While actively working, periodically run `./scripts/team.py agent ping '<short progress summary>'`.
                4. If blocked, run `./scripts/team.py task block <task_id> '<reason>'`.
                5. If ready for validation, run `./scripts/team.py task review <task_id> '<summary>'`.
                6. When accepted as done, run `./scripts/team.py task done <task_id> '<result>'`.
                When you complete any task, you MUST use your bash/execute tool to run:
                ./scripts/team.py report '<summary of your result>'
                Do NOT just write the result as text — actually execute the shell command.
                """
                agentCommand = buildKiroCommand(
                    kiroPath: cliPath,
                    agentName: agent.name,
                    teamName: name,
                    model: agent.model,
                    systemPrompt: workerPrompt
                )
            case "codex":
                agentCommand = buildCodexCommand(
                    codexPath: cliPath,
                    agentName: agent.name,
                    teamName: name,
                    model: agent.model
                )
                // Codex CLI starts interactively; leader sends instructions via team.py send.
            case "gemini":
                agentCommand = buildGeminiCommand(
                    geminiPath: cliPath,
                    agentName: agent.name,
                    teamName: name,
                    model: agent.model
                )
                // Gemini CLI starts interactively; leader sends instructions via team.py send.
            default:
                agentCommand = buildClaudeCommand(
                    claudePath: cliPath,
                    agentId: agentId,
                    agentName: agent.name,
                    teamName: name,
                    agentColor: agentColor,
                    parentSessionId: leaderSessionId,
                    agentType: agent.agentType,
                    model: agent.model,
                    instructions: agent.instructions
                )
            }
            // Wrap so the terminal stays open (drops to shell) if the CLI exits.
            let shellCommand = "\(agentCommand); exec $SHELL"
            // Select the right environment: non-claude agents don't need CLAUDECODE
            let paneEnv = (agentCli == "claude" ? claudeAgentEnv : kiroAgentEnv)
                .merging(["TERMMESH_AGENT_NAME": agent.name]) { _, new in new }

            // Balanced binary tree with alternating H/V orientations for grid layout.
            // Agent i splits from agent floor((i-1)/2). Left children alternate
            // orientation from parent, right children keep parent's orientation.
            // Example for 4 agents → clean 2×2 grid:
            //   A0: H from leader, A1: V from A0, A2: H from A0, A3: H from A1
            //   | Leader | A0 | A2 |
            //   |        |----|----|
            //   |        | A1 | A3 |
            let splitFrom: UUID
            let orientation: SplitOrientation

            if index == 0 {
                orientation = .horizontal
                splitFrom = leaderPanelId
            } else {
                let parentIndex = (index - 1) / 2
                splitFrom = members[parentIndex].panelId
                // Compute orientation: walk up the tree to determine parent's orientation,
                // then alternate for left child (odd index), keep for right child (even index).
                let parentOrientation = agentSplitOrientation(at: parentIndex)
                let isLeftChild = (index % 2 == 1)
                orientation = isLeftChild
                    ? (parentOrientation == .horizontal ? .vertical : .horizontal)
                    : parentOrientation
            }

            guard let panel = workspace.newTerminalSplit(
                from: splitFrom,
                orientation: orientation,
                focus: false,
                workingDirectory: agentWorkDir,
                command: shellCommand,
                environment: paneEnv
            ) else {
                if index == 0 {
                    Logger.team.error("failed to create first agent split pane")
                    return nil
                }
                Logger.team.error("failed to create split pane for agent '\(agent.name, privacy: .public)'")
                continue
            }
            let panelId = panel.id

            // Set agent name as pane title (include branch if worktree)
            let colorEmoji = Self.colorEmoji(agentColor)
            let paneTitle = wtBranch != nil
                ? "\(colorEmoji) \(agent.name) [\(wtBranch!)]"
                : "\(colorEmoji) \(agent.name)"
            workspace.setPanelCustomTitle(panelId: panelId, title: paneTitle)

            let member = AgentMember(
                id: agentId,
                name: agent.name,
                teamName: name,
                cli: agentCli,
                model: agent.model,
                agentType: agent.agentType,
                color: agentColor,
                workspaceId: workspace.id,
                panelId: panelId,
                parentSessionId: leaderSessionId,
                createdAt: Date(),
                worktreeName: wtName,
                worktreePath: wtPath,
                worktreeBranch: wtBranch
            )
            members.append(member)
        }

        let team = Team(
            id: name,
            leaderSessionId: leaderSessionId,
            leaderMode: leaderMode,
            leaderPanelId: leaderPanelId,
            workingDirectory: workingDirectory,
            workspaceId: workspace.id,
            agents: members,
            createdAt: Date(),
            gitRepoRoot: gitRepoRoot
        )
        teams[name] = team
        // Register in thread-safe data store for off-main access (approach C: dual queue)
        TeamDataStore.shared.registerTeam(name, agentNames: members.map(\.name))
        syncTeamStateToDaemon()
        Logger.team.info("created team '\(name, privacy: .public)' with \(members.count, privacy: .public) agent(s) + leader console")

        // For non-Claude CLI leaders (kiro, codex, gemini), inject team instructions.
        // Claude leaders get instructions via --system-prompt in team-leader-claude.sh.
        if leaderMode != "repl" && leaderMode != "claude" {
            let scriptDir = Self.findScriptsDir(workingDirectory: workingDirectory)
            let prompt = buildTeamLeaderPrompt(
                teamName: name,
                agents: members,
                socketPath: socketPath,
                scriptDir: scriptDir
            )
            // Write prompt to a temp file — used by kiro profile (self-directed read)
            // and by codex/gemini (delayed TUI injection).
            let promptFile = "/tmp/term-mesh-leader-\(name).md"
            try? prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)

            if leaderMode == "kiro" {
                // Kiro leader profile already includes "read /tmp/term-mesh-leader-<name>.md"
                // in its system prompt. No delayed TUI injection needed — kiro reads the file
                // on its own once MCP init completes.
                #if DEBUG
                dlog("[team] kiro leader prompt file written to \(promptFile) (profile-directed, no delay)")
                #endif
            } else {
                // codex/gemini: still need delayed TUI injection
                let delay: Double = 5.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    let msg = "Read the file \(promptFile) — it contains your team leader instructions with agent list and team.py commands. Follow those instructions for all team coordination."
                    let sent = self.sendTextToPanel(
                        workspaceId: workspace.id,
                        panelId: leaderPanelId,
                        text: msg,
                        tabManager: tabManager
                    )
                    #if DEBUG
                    dlog("[team] leader prompt injection \(sent ? "OK" : "FAILED") for \(leaderMode) leader in team '\(name)'")
                    #endif
                }
            }
        }

        return team
    }

    /// Find the leader script for the given mode.
    private func leaderScriptPath(mode: String, workingDirectory: String? = nil) -> String? {
        let filename = mode == "claude" ? "team-leader-claude.sh" : "team-leader.sh"
        // 1) App bundle Resources/scripts/ (works in Release builds)
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/\(filename)").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // 2) Look relative to the working directory (project root)
        if let wd = workingDirectory {
            let wdPath = (wd as NSString).appendingPathComponent("scripts/\(filename)")
            if FileManager.default.fileExists(atPath: wdPath) { return wdPath }
        }
        // 3) Fallback: relative to app CWD (legacy dev mode)
        let devPath = "scripts/\(filename)"
        if FileManager.default.fileExists(atPath: devPath) { return devPath }
        // 4) Try absolute from known project locations
        let home = NSHomeDirectory()
        for projectDir in ["cmux-term-mesh", "project/cmux", "project/term-mesh"] {
            let projectPath = "\(home)/work/\(projectDir)/scripts/\(filename)"
            if FileManager.default.fileExists(atPath: projectPath) { return projectPath }
        }
        return nil
    }

    /// Find the scripts/ directory (for team.py path in leader prompts).
    private static func findScriptsDir(workingDirectory: String) -> String {
        // 1) App bundle Resources/scripts/ (works in Release builds)
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("scripts").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // 2) Check relative to working directory (project root, dev mode)
        let wdPath = (workingDirectory as NSString).appendingPathComponent("scripts")
        if FileManager.default.fileExists(atPath: wdPath) { return wdPath }
        // 3) Fallback: relative to app CWD (legacy dev mode)
        let devPath = "scripts"
        if FileManager.default.fileExists(atPath: devPath) { return devPath }
        // 4) Fallback: known project locations
        let home = NSHomeDirectory()
        for projectDir in ["cmux-term-mesh", "project/cmux", "project/term-mesh"] {
            let projectPath = "\(home)/work/\(projectDir)/scripts"
            if FileManager.default.fileExists(atPath: projectPath) { return projectPath }
        }
        return "\(workingDirectory)/scripts"  // fallback to working directory
    }

    /// Build system prompt for Claude leader (launched directly, no shell script wrapper).
    private static func buildLeaderClaudeSystemPrompt(
        teamName: String,
        agentList: String,
        teamPy: String,
        socketPath: String
    ) -> String {
        return """
        You are the TEAM LEADER for team '\(teamName)'. You direct a group of Claude agent workers running in terminal split panes.

        ## Your Agents
        \(agentList)

        ## Operating Model

        Task objects are the canonical unit of delegation.
        Messages are conversational transport. Reports are result summaries.
        Manage by task state and inbox, not by ad hoc chat alone.
        Before sending meaningful work, create a task and assign it.

        ## How to Command Agents

        Create a task and delegate it to a specific agent:
        ```
        \(teamPy) delegate <agent_name> '<your instruction>'
        ```

        Send a raw direct message:
        ```
        \(teamPy) send <agent_name> '<your instruction>'
        ```

        Broadcast to all agents:
        ```
        \(teamPy) broadcast '<your instruction>'
        ```

        Check team status / inbox:
        ```
        \(teamPy) status
        \(teamPy) inbox
        ```

        ## Reading Agent Results (MANDATORY)

        After sending tasks, you MUST collect results before responding.
        NEVER answer using only your own analysis when agents were delegated.

        ```
        \(teamPy) read <agent_name> --lines 100
        \(teamPy) collect --lines 100
        \(teamPy) wait --timeout 120
        \(teamPy) wait --mode blocked --timeout 120
        \(teamPy) wait --mode review_ready --timeout 120
        ```

        ## Message Channel
        ```
        \(teamPy) msg list
        \(teamPy) msg list --from <agent_name>
        ```

        ## Task Board
        ```
        \(teamPy) task create '<title>' --assign <agent_name> --priority 2
        \(teamPy) task list
        \(teamPy) task get <id>
        \(teamPy) task start <id> --assign <agent_name>
        \(teamPy) task block <id> '<reason>'
        \(teamPy) task review <id> '<summary>'
        \(teamPy) task done <id> '<result>'
        ```

        ## Your Role
        1. Break down user tasks and create explicit tasks before delegating
        2. Use agent specialties to route work effectively
        3. AFTER delegating, ALWAYS read agent results using read/collect/wait before responding
        4. Check inbox before responding to the user
        5. Treat blocked and review_ready as first-class control points
        6. Coordinate between agents when tasks have dependencies
        7. Synthesize agent results and report back to the user
        8. Prefer parallel work: send independent tasks to multiple agents simultaneously

        Environment: TERMMESH_SOCKET=\(socketPath)
        """
    }

    /// Build team leader instructions for non-Claude CLI leaders (kiro, codex, gemini).
    /// These CLIs lack a --system-prompt flag, so we inject instructions as the first message.
    private func buildTeamLeaderPrompt(
        teamName: String,
        agents: [AgentMember],
        socketPath: String,
        scriptDir: String
    ) -> String {
        let agentList = agents.enumerated().map { i, a in
            "  \(i + 1). \(a.name) (\(a.agentType))"
        }.joined(separator: "\n")

        let teamPy = "\(scriptDir)/team.py"

        // Worktree info
        let worktreeAgents = agents.filter { $0.worktreeBranch != nil }
        let worktreeSection: String
        if !worktreeAgents.isEmpty {
            let wtList = worktreeAgents.map { a in
                "  - \(a.name): branch='\(a.worktreeBranch ?? "?")' path='\(a.worktreePath ?? "?")'"
            }.joined(separator: "\n")
            worktreeSection = """

            ## Worktree Isolation (ACTIVE)
            Each agent works in its own isolated git worktree.
            \(wtList)
            When agents complete work, instruct them to: git add -A && git commit && git push && gh pr create
            """
        } else {
            worktreeSection = ""
        }

        return """
        You are the TEAM LEADER for team '\(teamName)'. You direct agent workers running in terminal split panes.

        ## Your Agents
        \(agentList)

        ## Operating Model

        Task objects are the canonical unit of delegation.
        Messages are for conversation. Reports are for result summaries.
        You should manage by task state and inbox, not by ad hoc chat alone.

        Before sending meaningful work, create a task and assign it.

        ## How to Command Agents

        Create a task and delegate it to a specific agent:
        ```
        \(teamPy) delegate <agent_name> '<your instruction>'
        ```

        Send a raw direct message to a specific agent:
        ```
        \(teamPy) send <agent_name> '<your instruction>'
        ```

        Broadcast to all agents:
        ```
        \(teamPy) broadcast '<your instruction>'
        ```

        Check team status:
        ```
        \(teamPy) status
        ```

        Check what needs intervention first:
        ```
        \(teamPy) inbox
        ```

        ## Reading Agent Results (MANDATORY)

        After sending tasks, you MUST collect results before responding.

        Read a specific agent's output:
        ```
        \(teamPy) read <agent_name> --lines 100
        ```

        Read ALL agents' output:
        ```
        \(teamPy) collect --lines 100
        ```

        Wait for agents to finish:
        ```
        \(teamPy) wait --timeout 120
        ```

        Wait for the next blocked or review-ready item:
        ```
        \(teamPy) wait --mode blocked --timeout 120
        \(teamPy) wait --mode review_ready --timeout 120
        ```

        ## Message Channel
        ```
        \(teamPy) msg list
        \(teamPy) msg list --from <agent_name>
        ```

        ## Task Board
        ```
        \(teamPy) task create '<title>' --assign <agent_name> --priority 2
        \(teamPy) task list
        \(teamPy) task get <id>
        \(teamPy) task start <id> --assign <agent_name>
        \(teamPy) task block <id> '<reason>'
        \(teamPy) task review <id> '<summary>'
        \(teamPy) task done <id> '<result>'
        ```
        \(worktreeSection)

        ## Your Role
        1. Break down user tasks and create explicit tasks before delegating work
        2. Delegate to appropriate agents with task ids and clear acceptance criteria
        3. Check `inbox` before responding to the user
        4. Treat `blocked` and `review_ready` as first-class control points
        5. ALWAYS read agent results using read/collect/wait before responding
        6. Coordinate dependencies between agents
        7. Synthesize results and report back

        Environment: TERMMESH_SOCKET=\(socketPath)
        """
    }

    /// Send text to a specific agent in a team.
    func sendToAgent(teamName: String, agentName: String, text: String, tabManager: TabManager, enterDelay: TimeInterval = 0.05) -> Bool {
        guard let team = teams[teamName] else { return false }
        guard let agent = team.agents.first(where: { $0.name == agentName }) else { return false }
        return sendTextToPanel(workspaceId: agent.workspaceId, panelId: agent.panelId, text: text, tabManager: tabManager, enterDelay: enterDelay)
    }

    func sendToLeader(teamName: String, text: String, tabManager: TabManager) -> Bool {
        guard let team = teams[teamName] else { return false }
        return sendTextToPanel(workspaceId: team.workspaceId, panelId: team.leaderPanelId, text: text, tabManager: tabManager)
    }

    @discardableResult
    func notifyTaskCreated(teamName: String, taskId: String, tabManager: TabManager) -> Bool {
        guard let task = getTask(teamName: teamName, taskId: taskId) else { return false }
        let leaderSummary = formatLeaderTaskNotification(task: task, event: "created")
        let leaderSent = sendToLeader(teamName: teamName, text: leaderSummary, tabManager: tabManager)
        guard let assignee = task.assignee?.nilIfBlank else { return leaderSent }
        let assigneeNotice = formatTaskAssignmentInstruction(task: task)
        let agentSent = sendToAgent(teamName: teamName, agentName: assignee, text: assigneeNotice, tabManager: tabManager)
        return leaderSent || agentSent
    }

    @discardableResult
    func notifyTaskLifecycleEvent(
        teamName: String,
        taskId: String,
        event: String,
        note: String? = nil,
        tabManager: TabManager
    ) -> Bool {
        guard let task = getTask(teamName: teamName, taskId: taskId) else { return false }
        return notifyTaskLifecycleEvent(teamName: teamName, task: task, event: event, note: note, tabManager: tabManager)
    }

    /// Overload that accepts a pre-fetched task (used by approach D async handlers
    /// where the task comes from TeamDataStore, not from taskBoards).
    func notifyTaskLifecycleEvent(
        teamName: String,
        task: TeamTask,
        event: String,
        note: String? = nil,
        tabManager: TabManager
    ) -> Bool {
        let leaderSummary = formatLeaderTaskNotification(task: task, event: event, note: note)
        return sendToLeader(teamName: teamName, text: leaderSummary, tabManager: tabManager)
    }

    func dispatchTaskToAssignee(teamName: String, taskId: String, tabManager: TabManager) -> Bool {
        guard let task = getTask(teamName: teamName, taskId: taskId) else { return false }
        return dispatchTaskToAssignee(teamName: teamName, task: task, tabManager: tabManager)
    }

    /// Overload that accepts a pre-fetched task (used by approach D async handlers).
    func dispatchTaskToAssignee(teamName: String, task: TeamTask, tabManager: TabManager) -> Bool {
        guard let assignee = task.assignee?.nilIfBlank else { return false }
        let instruction = formatTaskDispatchInstruction(task: task)
        let dispatched = sendToAgent(teamName: teamName, agentName: assignee, text: instruction, tabManager: tabManager)
        let leaderSummary = formatLeaderTaskNotification(task: task, event: dispatched ? "started" : "start_failed")
        _ = sendToLeader(teamName: teamName, text: leaderSummary, tabManager: tabManager)
        return dispatched
    }

    private func formatTaskDispatchInstruction(task: TeamTask) -> String {
        var lines = [
            "Task \(task.id): \(task.title)",
            "Status: \(task.status)",
            "Priority: \(task.priority)"
        ]
        if !task.acceptanceCriteria.isEmpty {
            lines.append("Acceptance criteria:")
            for item in task.acceptanceCriteria {
                lines.append("- \(item)")
            }
        }
        if !task.dependsOn.isEmpty {
            lines.append("Dependencies: \(task.dependsOn.joined(separator: ", "))")
        }
        if let description = task.details?.nilIfBlank {
            lines.append("Details: \(description)")
        }
        lines.append("")
        lines.append("Resume or start this assigned task now.")
        lines.append("")
        lines.append("Use the task lifecycle commands with this task id:")
        lines.append("- ./scripts/team.py task start \(task.id)")
        lines.append("- ./scripts/team.py task block \(task.id) '<reason>'")
        lines.append("- ./scripts/team.py task review \(task.id) '<summary>'")
        lines.append("- ./scripts/team.py task done \(task.id) '<result>'")
        return lines.joined(separator: "\n")
    }

    private func formatTaskAssignmentInstruction(task: TeamTask) -> String {
        var lines = [
            "New assigned task: \(task.title)",
            "Task id: \(task.id)",
            "Status: \(task.status)",
        ]
        if let description = task.details?.nilIfBlank {
            lines.append("")
            lines.append(description)
        }
        lines.append("")
        lines.append("A new task has been assigned to you.")
        lines.append("When you begin work, run:")
        lines.append("./scripts/team.py task start \(task.id)")
        return lines.joined(separator: "\n")
    }

    private func formatLeaderTaskNotification(task: TeamTask, event: String, note: String? = nil) -> String {
        let assignee = task.assignee?.nilIfBlank ?? "unassigned"
        let eventText: String
        switch event {
        case "created": eventText = "New task created"
        case "started": eventText = "Task started"
        case "blocked": eventText = "Task blocked"
        case "review_ready": eventText = "Task ready for review"
        case "completed": eventText = "Task completed"
        case "start_failed": eventText = "Task start dispatch failed"
        default: eventText = "Task update"
        }
        var lines = [
            "\(eventText): \(task.title)",
            "Task id: \(task.id)",
            "Assignee: \(assignee)",
            "Status: \(task.status)"
        ]
        if let note = note?.nilIfBlank {
            lines.append("Note: \(note)")
        }
        return lines.joined(separator: "\n")
    }

    private func sendTextToPanel(workspaceId: UUID, panelId: UUID, text: String, tabManager: TabManager, enterDelay: TimeInterval = 0.05) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return false }
        guard let panel = workspace.terminalPanel(for: panelId) else { return false }
        let trimmed = text.replacingOccurrences(of: "[\\r\\n]+$", with: "", options: .regularExpression)
        guard !trimmed.isEmpty else { return true }

        // Send text first, then schedule Enter after a short delay.
        // TUI apps (Claude Code) need a gap between text input and Return
        // to process the text into their input buffer. Atomic (text+\n)
        // delivery in a single call was tested and causes missed submissions.
        //
        // RunLoop timer in .common mode fires reliably even under heavy
        // main-thread load. Broadcast uses staggered enterDelay values
        // so N agents don't fire Enter simultaneously.
        panel.sendInputText(trimmed)

        // Primary Enter
        let enterTimer = Timer(timeInterval: enterDelay, repeats: false) { [weak panel] _ in
            panel?.sendInputText("\n")
        }
        RunLoop.main.add(enterTimer, forMode: .common)

        // Safety retry: if primary Enter was missed (e.g. TUI was busy),
        // send another Enter later. Double-Enter on an idle prompt is harmless.
        let retryTimer = Timer(timeInterval: enterDelay + 0.15, repeats: false) { [weak panel] _ in
            panel?.sendInputText("\n")
        }
        RunLoop.main.add(retryTimer, forMode: .common)

        #if DEBUG
        dlog("[team.sendTextToPanel] sendText textLen=\(trimmed.count) enterDelay=\(enterDelay) text=\(trimmed.prefix(80).debugDescription)")
        #endif
        return true
    }

    /// Broadcast text to all agents in a team.
    /// Staggers Enter delivery: agent 0 at 50ms, agent 1 at 100ms, etc.
    /// Each agent also gets a retry Enter 150ms after its primary.
    func broadcast(teamName: String, text: String, tabManager: TabManager) -> Int {
        guard let team = teams[teamName] else { return 0 }
        var count = 0
        for (index, agent) in team.agents.enumerated() {
            let enterDelay = 0.05 + Double(index) * 0.05
            if sendToAgent(teamName: teamName, agentName: agent.name, text: text, tabManager: tabManager, enterDelay: enterDelay) {
                count += 1
            }
        }
        return count
    }

    /// List all teams.
    func listTeams() -> [[String: Any]] {
        teams.values.map { team in
            let teamInbox = inboxItems(teamName: team.id)
            return [
                "team_name": team.id,
                "leader_session_id": team.leaderSessionId,
                "working_directory": team.workingDirectory,
                "workspace_id": team.workspaceId.uuidString,
                "agent_count": team.agents.count,
                "agents": team.agents.map { agent in
                    let activeTask = activeTask(for: team.id, agentName: agent.name)
                    let heartbeat = heartbeats[team.id]?[agent.name]
                    return [
                        "id": agent.id,
                        "name": agent.name,
                        "cli": agent.cli,
                        "model": agent.model,
                        "agent_type": agent.agentType,
                        "color": agent.color,
                        "active_task_id": activeTask?.id as Any,
                        "active_task_title": activeTask?.title as Any,
                        "active_task_status": activeTask?.status as Any,
                        "active_task_is_stale": activeTask.map(isTaskStale) ?? false,
                        "agent_state": agentRuntimeState(teamName: team.id, agentName: agent.name),
                        "heartbeat_age_seconds": heartbeatAgeSeconds(teamName: team.id, agentName: agent.name) as Any,
                        "last_heartbeat_summary": heartbeat?.summary as Any,
                        "heartbeat_is_stale": heartbeat.map(isHeartbeatStale) ?? false,
                        "workspace_id": agent.workspaceId.uuidString,
                        "panel_id": agent.panelId.uuidString
                    ] as [String: Any]
                },
                "attention_count": teamInbox.count,
                "created_at": ISO8601DateFormatter().string(from: team.createdAt)
            ] as [String: Any]
        }
    }

    private func daemonPayload() -> [String: Any] {
        let teamData = listTeams()
        let teamTasks = teamData.flatMap { team -> [[String: Any]] in
            guard let teamName = team["team_name"] as? String else { return [] }
            return listTasks(teamName: teamName).map { task in
                var dict = taskDictionary(task)
                dict["team_name"] = teamName
                return dict
            }
        }
        let teamAttention = teamData.flatMap { team -> [[String: Any]] in
            guard let teamName = team["team_name"] as? String else { return [] }
            return inboxItems(teamName: teamName)
        }
        let instanceMeta: [String: Any] = [
            "app_name": Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? ProcessInfo.processInfo.processName,
            "socket_path": SocketControlSettings.socketPath(),
            "team_count": teamData.count
        ]
        return [
            "teams": teamData,
            "tasks": teamTasks,
            "attention": teamAttention,
            "instance": instanceMeta,
        ]
    }

    private func syncTeamStateToDaemon() {
        let payload = daemonPayload()
        DispatchQueue.global(qos: .utility).async {
            self.daemon.syncTeams(payload)
        }
    }

    /// Get raw team struct for minimal MainActor access (used by hybrid team.status).
    func teamStruct(name: String) -> Team? {
        teams[name]
    }

    /// Get team status.
    func teamStatus(name: String) -> [String: Any]? {
        guard let team = teams[name] else { return nil }
        let teamInbox = inboxItems(teamName: team.id)
        return [
            "team_name": team.id,
            "leader_session_id": team.leaderSessionId,
            "workspace_id": team.workspaceId.uuidString,
            "agent_count": team.agents.count,
            "agents": team.agents.map { agent in
                let activeTask = activeTask(for: team.id, agentName: agent.name)
                let heartbeat = heartbeats[team.id]?[agent.name]
                var info: [String: Any] = [
                    "id": agent.id,
                    "name": agent.name,
                    "cli": agent.cli,
                    "model": agent.model,
                    "agent_type": agent.agentType,
                    "active_task_id": activeTask?.id as Any,
                    "active_task_title": activeTask?.title as Any,
                    "active_task_status": activeTask?.status as Any,
                    "active_task_is_stale": activeTask.map(isTaskStale) ?? false,
                    "agent_state": agentRuntimeState(teamName: team.id, agentName: agent.name),
                    "heartbeat_age_seconds": heartbeatAgeSeconds(teamName: team.id, agentName: agent.name) as Any,
                    "last_heartbeat_summary": heartbeat?.summary as Any,
                    "heartbeat_is_stale": heartbeat.map(isHeartbeatStale) ?? false,
                    "workspace_id": agent.workspaceId.uuidString,
                    "panel_id": agent.panelId.uuidString
                ]
                if let branch = agent.worktreeBranch {
                    info["worktree_branch"] = branch
                }
                if let path = agent.worktreePath {
                    info["worktree_path"] = path
                }
                return info as [String: Any]
            },
            "attention_count": teamInbox.count,
            "task_count": taskBoards[team.id, default: []].count
        ] as [String: Any]
    }

    /// Destroy a team — send Ctrl-C to all agents and close the workspace.
    func destroyTeam(name: String, tabManager: TabManager) -> Bool {
        guard let team = teams[name] else { return false }
        guard let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }) else {
            cleanupWorktrees(team: team)
            teams.removeValue(forKey: name)
            heartbeats.removeValue(forKey: name)
            TeamDataStore.shared.unregisterTeam(name)
            syncTeamStateToDaemon()
            return true
        }

        // Send Ctrl-C to all agent panels
        for agent in team.agents {
            if let panel = workspace.terminalPanel(for: agent.panelId) {
                panel.sendText("\u{03}")  // Ctrl-C
            }
        }

        // Send exit after a delay, then close workspace and clean up worktrees
        let wsRef = workspace
        let teamCopy = team
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for agent in teamCopy.agents {
                if let panel = wsRef.terminalPanel(for: agent.panelId) {
                    panel.sendText("exit\n")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            tabManager.closeTab(wsRef)
            // Clean up worktrees after workspace is closed
            self.cleanupWorktrees(team: teamCopy)
        }

        // Clean up bidirectional communication state
        clearResults(teamName: name)
        clearMessages(teamName: name)
        clearTasks(teamName: name)
        heartbeats.removeValue(forKey: name)

        // Unregister from thread-safe data store (approach C: dual queue)
        TeamDataStore.shared.unregisterTeam(name)

        // Clean up dynamic kiro agent profiles
        Self.cleanupKiroProfiles(teamName: name)

        teams.removeValue(forKey: name)
        syncTeamStateToDaemon()
        Logger.team.info("destroyed team '\(name, privacy: .public)'")
        return true
    }

    /// Log detached worktrees from a destroyed team (no longer auto-deleted).
    private func cleanupWorktrees(team: Team) {
        for agent in team.agents {
            guard let wtName = agent.worktreeName else { continue }
            Logger.team.info("worktree '\(wtName, privacy: .public)' detached from agent '\(agent.name, privacy: .public)' (kept for manual cleanup)")
        }
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

    /// Map short model names (used internally) to kiro-cli model identifiers.
    private static func kiroModelName(_ shortName: String) -> String {
        switch shortName.lowercased() {
        case "opus":   return "claude-opus-4.6"
        case "sonnet": return "claude-sonnet-4.6"
        case "haiku":  return "claude-haiku-4.5"
        default:       return shortName  // pass through if already full name
        }
    }

    /// Write a kiro agent profile to ~/.kiro/agents/ with a specific system prompt.
    /// Each team+agent combination gets its own profile so the prompt is loaded at CLI startup
    /// — no delayed TUI injection needed.
    @discardableResult
    private static func writeKiroProfile(
        profileName: String,
        description: String,
        prompt: String
    ) -> String {
        let agentsDir = "\(NSHomeDirectory())/.kiro/agents"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)

        let path = "\(agentsDir)/\(profileName).json"
        let json: [String: Any] = [
            "name": profileName,
            "description": description,
            "prompt": prompt,
            "mcpServers": [String: Any](),
            "tools": ["read", "write", "shell", "thinking", "todo"],
            "toolAliases": [String: Any](),
            "allowedTools": [String](),
            "resources": ["file://AGENTS.md", "file://CLAUDE.md"],
            "hooks": [String: Any](),
            "toolsSettings": [String: Any](),
            "useLegacyMcpJson": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            fm.createFile(atPath: path, contents: data)
        }
        return profileName
    }

    /// Remove dynamic kiro profiles created for a team.
    private static func cleanupKiroProfiles(teamName: String) {
        let agentsDir = "\(NSHomeDirectory())/.kiro/agents"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: agentsDir) else { return }
        let prefix = "team-\(teamName)-"
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(".json") {
            try? fm.removeItem(atPath: "\(agentsDir)/\(file)")
        }
    }

    private func buildKiroCommand(
        kiroPath: String,
        agentName: String,
        teamName: String,
        model: String,
        isLeader: Bool = false,
        systemPrompt: String? = nil
    ) -> String {
        let profileName = "team-\(teamName)-\(agentName)"

        let defaultPrompt: String
        if isLeader {
            // Leader profile tells kiro to read the prompt file on startup.
            // The file is written after agents are created (by createTeam).
            defaultPrompt = """
            You are a team leader in term-mesh. \
            On startup, immediately read /tmp/term-mesh-leader-\(teamName).md — \
            it contains your full team instructions with agent list and team.py commands. \
            Follow those instructions for all team coordination. \
            Rules: 1) Be concise. 2) Delegate work, don't do it yourself. \
            3) Always read agent results before responding. 4) Use short, clear instructions.
            """
        } else {
            defaultPrompt = """
            You are a focused worker agent named '\(agentName)' in team '\(teamName)'. \
            Rules: 1) Be EXTREMELY concise — no preamble, no summaries unless asked. \
            2) Output only code, commands, or direct answers. \
            3) When done, state the result in 1-2 lines max. 4) Never repeat the task back.
            """
        }

        Self.writeKiroProfile(
            profileName: profileName,
            description: isLeader
                ? "Team leader for \(teamName)"
                : "Worker agent \(agentName) in team \(teamName)",
            prompt: systemPrompt ?? defaultPrompt
        )

        let path = kiroPath.contains(" ") ? "\"\(kiroPath)\"" : kiroPath
        var parts = [
            path,
            "chat",
            "--trust-all-tools",   // equivalent to claude's --dangerously-skip-permissions
            "--wrap never",        // reduce formatting overhead in split panes
            "--agent \(profileName)"
        ]

        if !model.isEmpty {
            let kiroModel = Self.kiroModelName(model)
            parts.append("--model \(kiroModel)")
        }

        return parts.joined(separator: " ")
    }

    /// Map short model names to Codex CLI model identifiers.
    private static func codexModelName(_ shortName: String) -> String {
        switch shortName.lowercased() {
        case "opus":   return "o3"       // highest reasoning
        case "sonnet": return "o4-mini"  // balanced
        case "haiku":  return "o4-mini"  // fast
        default:       return shortName
        }
    }

    private func buildCodexCommand(
        codexPath: String,
        agentName: String,
        teamName: String,
        model: String
    ) -> String {
        let path = codexPath.contains(" ") ? "\"\(codexPath)\"" : codexPath
        var parts = [
            path,
            "--ask-for-approval never"  // equivalent to --dangerously-skip-permissions
        ]

        if !model.isEmpty {
            let codexModel = Self.codexModelName(model)
            parts.append("--model \(codexModel)")
        }

        // Start interactively — leader sends instructions via team.py send.
        return parts.joined(separator: " ")
    }

    /// Map short model names to Gemini CLI model identifiers.
    private static func geminiModelName(_ shortName: String) -> String {
        switch shortName.lowercased() {
        case "opus":   return "gemini-2.5-pro"
        case "sonnet": return "gemini-2.5-flash"
        case "haiku":  return "gemini-2.5-flash"
        default:       return shortName
        }
    }

    private func buildGeminiCommand(
        geminiPath: String,
        agentName: String,
        teamName: String,
        model: String
    ) -> String {
        let path = geminiPath.contains(" ") ? "\"\(geminiPath)\"" : geminiPath
        var parts = [
            path,
            "--yolo"   // auto-approve all actions (equivalent to --dangerously-skip-permissions)
        ]

        if !model.isEmpty {
            let geminiModel = Self.geminiModelName(model)
            parts.append("--model \(geminiModel)")
        }

        // Start interactively — leader sends instructions via team.py send.
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

    // MARK: - B: File-Based Results

    /// Write an agent's result to the file-based result directory.
    func writeResult(teamName: String, agentName: String, content: String) -> Bool {
        let dir = Self.resultDirectory(teamName: teamName)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(agentName).result.json")
        let payload: [String: Any] = [
            "agent": agentName,
            "team": teamName,
            "content": content,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data)
    }

    /// Read an agent's result file.
    func readResult(teamName: String, agentName: String) -> [String: Any]? {
        let path = (Self.resultDirectory(teamName: teamName) as NSString).appendingPathComponent("\(agentName).result.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    /// Collect all agent results for a team.
    func collectResults(teamName: String) -> [[String: Any]] {
        guard let team = teams[teamName] else { return [] }
        return team.agents.compactMap { readResult(teamName: teamName, agentName: $0.name) }
    }

    /// Check which agents have submitted results.
    func resultStatus(teamName: String) -> [String: Any] {
        guard let team = teams[teamName] else { return [:] }
        let dir = Self.resultDirectory(teamName: teamName)
        var agentStatus: [[String: Any]] = []
        for agent in team.agents {
            let path = (dir as NSString).appendingPathComponent("\(agent.name).result.json")
            let hasResult = FileManager.default.fileExists(atPath: path)
            agentStatus.append(["name": agent.name, "has_result": hasResult])
        }
        let completed = agentStatus.filter { $0["has_result"] as? Bool == true }.count
        return [
            "team_name": teamName,
            "total": team.agents.count,
            "completed": completed,
            "all_done": completed == team.agents.count,
            "agents": agentStatus
        ]
    }

    /// Clean up result files for a team.
    func clearResults(teamName: String) {
        let dir = Self.resultDirectory(teamName: teamName)
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - A: Read Agent Pane Screen

    /// Read terminal text from a specific agent's pane.
    /// Returns the panel for external callers to use with readTerminalTextBase64.
    func agentPanel(teamName: String, agentName: String, tabManager: TabManager) -> TerminalPanel? {
        guard let team = teams[teamName] else { return nil }
        guard let agent = team.agents.first(where: { $0.name == agentName }) else { return nil }
        guard let workspace = tabManager.tabs.first(where: { $0.id == agent.workspaceId }) else { return nil }
        return workspace.terminalPanel(for: agent.panelId)
    }

    /// Get all agent panels for a team.
    func allAgentPanels(teamName: String, tabManager: TabManager) -> [(name: String, panel: TerminalPanel)] {
        guard let team = teams[teamName] else { return [] }
        var results: [(name: String, panel: TerminalPanel)] = []
        for agent in team.agents {
            guard let workspace = tabManager.tabs.first(where: { $0.id == agent.workspaceId }),
                  let panel = workspace.terminalPanel(for: agent.panelId) else { continue }
            results.append((name: agent.name, panel: panel))
        }
        return results
    }

    // MARK: - C: Message Queue

    /// Post a message from an agent (or leader) to the team message queue.
    @discardableResult
    func postMessage(teamName: String, from: String, to: String? = nil, content: String, type: String = "report") -> TeamMessage? {
        guard teams[teamName] != nil else { return nil }
        let msg = TeamMessage(
            id: UUID().uuidString,
            from: from,
            to: to,
            teamName: teamName,
            content: content,
            timestamp: Date(),
            type: normalizedMessageType(type)
        )
        messages[teamName, default: []].append(msg)
        syncTeamStateToDaemon()
        return msg
    }

    /// Get messages for a team, optionally filtered.
    func getMessages(teamName: String, from: String? = nil, to: String? = nil, type: String? = nil, since: Date? = nil, limit: Int? = nil) -> [TeamMessage] {
        guard let msgs = messages[teamName] else { return [] }
        var filtered = msgs
        if let from { filtered = filtered.filter { $0.from == from } }
        if let to { filtered = filtered.filter { $0.to == to } }
        if let type { filtered = filtered.filter { $0.type == type } }
        if let since { filtered = filtered.filter { $0.timestamp > since } }
        if let limit { filtered = Array(filtered.suffix(limit)) }
        return filtered
    }

    /// Clear messages for a team.
    func clearMessages(teamName: String) {
        messages.removeValue(forKey: teamName)
        syncTeamStateToDaemon()
    }

    // MARK: - D: Task Board

    /// Create a new task on the team's task board.
    @discardableResult
    func createTask(
        teamName: String,
        title: String,
        details: String? = nil,
        assignee: String? = nil,
        acceptanceCriteria: [String] = [],
        labels: [String] = [],
        estimatedSize: Int? = nil,
        priority: Int = 2,
        dependsOn: [String] = [],
        parentTaskId: String? = nil,
        createdBy: String = "leader"
    ) -> TeamTask? {
        guard teams[teamName] != nil else { return nil }
        let now = Date()
        let normalizedAssignee = assignee?.nilIfBlank
        let normalizedCreatedBy = createdBy.nilIfBlank ?? "leader"
        if normalizedCreatedBy.contains("dashboard"),
           let duplicate = taskBoards[teamName, default: []].last(where: {
               $0.title == title &&
               $0.assignee == normalizedAssignee &&
               $0.createdBy == normalizedCreatedBy &&
               now.timeIntervalSince($0.createdAt) < 5
           }) {
            return duplicate
        }
        let task = TeamTask(
            id: UUID().uuidString.prefix(8).lowercased().description,
            title: title,
            details: details?.nilIfBlank,
            acceptanceCriteria: acceptanceCriteria.compactMap(\.nilIfBlank),
            labels: labels.compactMap(\.nilIfBlank),
            estimatedSize: estimatedSize,
            assignee: normalizedAssignee,
            status: normalizedAssignee == nil ? "queued" : "assigned",
            priority: max(1, min(priority, 3)),
            dependsOn: dependsOn.compactMap(\.nilIfBlank),
            parentTaskId: parentTaskId?.nilIfBlank,
            childTaskIds: [],
            reassignmentCount: 0,
            supersededBy: nil,
            blockedReason: nil,
            reviewSummary: nil,
            createdBy: normalizedCreatedBy,
            result: nil,
            createdAt: now,
            updatedAt: now,
            startedAt: nil,
            completedAt: nil,
            lastProgressAt: nil
        )
        taskBoards[teamName, default: []].append(task)
        if let parentTaskId,
           var tasks = taskBoards[teamName],
           let parentIdx = tasks.firstIndex(where: { $0.id == parentTaskId }) {
            tasks[parentIdx].childTaskIds.append(task.id)
            tasks[parentIdx].updatedAt = now
            taskBoards[teamName] = tasks
        }
        syncTeamStateToDaemon()
        return task
    }

    /// Update a task's status and optional result.
    @discardableResult
    func updateTask(
        teamName: String,
        taskId: String,
        status: String? = nil,
        result: String? = nil,
        assignee: String? = nil,
        blockedReason: String? = nil,
        reviewSummary: String? = nil,
        progressNote: String? = nil
    ) -> TeamTask? {
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let now = Date()
        if let assignee {
            tasks[idx].assignee = assignee.nilIfBlank
            if tasks[idx].status == "queued", tasks[idx].assignee != nil {
                tasks[idx].status = "assigned"
            }
        }
        if let blockedReason {
            tasks[idx].blockedReason = blockedReason.nilIfBlank
        }
        if let reviewSummary {
            tasks[idx].reviewSummary = reviewSummary.nilIfBlank
        }
        if let result { tasks[idx].result = result }
        if let progressNote = progressNote?.nilIfBlank {
            tasks[idx].lastProgressAt = now
            _ = postMessage(
                teamName: teamName,
                from: tasks[idx].assignee ?? "leader",
                content: progressNote,
                type: "progress"
            )
        }
        if let status {
            let normalizedStatus = normalizedTaskStatus(status)
            tasks[idx].status = normalizedStatus
            switch normalizedStatus {
            case "in_progress":
                tasks[idx].startedAt = tasks[idx].startedAt ?? now
                tasks[idx].lastProgressAt = now
                tasks[idx].blockedReason = nil
            case "blocked":
                tasks[idx].lastProgressAt = now
            case "review_ready":
                tasks[idx].lastProgressAt = now
                tasks[idx].blockedReason = nil
            case "completed", "failed", "abandoned":
                tasks[idx].completedAt = now
                tasks[idx].lastProgressAt = now
                if normalizedStatus == "completed" {
                    tasks[idx].blockedReason = nil
                }
            default:
                break
            }
        }
        tasks[idx].updatedAt = now
        taskBoards[teamName] = tasks
        syncTeamStateToDaemon()
        return tasks[idx]
    }

    func getTask(teamName: String, taskId: String) -> TeamTask? {
        taskBoards[teamName]?.first(where: { $0.id == taskId })
    }

    @discardableResult
    func reassignTask(teamName: String, taskId: String, assignee: String?) -> TeamTask? {
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let now = Date()
        let previousAssignee = tasks[idx].assignee
        tasks[idx].assignee = assignee?.nilIfBlank
        tasks[idx].status = tasks[idx].assignee == nil ? "queued" : "assigned"
        tasks[idx].blockedReason = nil
        tasks[idx].reviewSummary = nil
        tasks[idx].completedAt = nil
        tasks[idx].updatedAt = now
        tasks[idx].lastProgressAt = now
        if previousAssignee != tasks[idx].assignee {
            tasks[idx].reassignmentCount += 1
        }
        taskBoards[teamName] = tasks
        syncTeamStateToDaemon()
        return tasks[idx]
    }

    @discardableResult
    func unblockTask(teamName: String, taskId: String) -> TeamTask? {
        guard var tasks = taskBoards[teamName],
              let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let now = Date()
        tasks[idx].blockedReason = nil
        if tasks[idx].status == "blocked" {
            if tasks[idx].startedAt != nil {
                tasks[idx].status = "in_progress"
            } else {
                tasks[idx].status = tasks[idx].assignee == nil ? "queued" : "assigned"
            }
        }
        tasks[idx].updatedAt = now
        tasks[idx].lastProgressAt = now
        taskBoards[teamName] = tasks
        syncTeamStateToDaemon()
        return tasks[idx]
    }

    @discardableResult
    func splitTask(
        teamName: String,
        parentTaskId: String,
        title: String,
        assignee: String? = nil,
        createdBy: String = "leader"
    ) -> TeamTask? {
        guard let parent = getTask(teamName: teamName, taskId: parentTaskId) else { return nil }
        var details = "Split from \(parent.id): \(parent.title)"
        if let parentDetails = parent.details?.nilIfBlank {
            details += "\n\n\(parentDetails)"
        }
        return createTask(
            teamName: teamName,
            title: title,
            details: details,
            assignee: assignee ?? parent.assignee,
            acceptanceCriteria: [],
            labels: parent.labels,
            estimatedSize: parent.estimatedSize,
            priority: parent.priority,
            dependsOn: [],
            parentTaskId: parent.id,
            createdBy: createdBy
        )
    }

    /// List tasks, optionally filtered by status or assignee.
    func listTasks(
        teamName: String,
        status: String? = nil,
        assignee: String? = nil,
        needsAttention: Bool = false,
        priority: Int? = nil,
        staleOnly: Bool = false,
        dependsOn: String? = nil
    ) -> [TeamTask] {
        guard let tasks = taskBoards[teamName] else { return [] }
        var filtered = tasks
        if let status {
            filtered = filtered.filter { $0.status == normalizedTaskStatus(status) }
        }
        if let assignee { filtered = filtered.filter { $0.assignee == assignee } }
        if needsAttention { filtered = filtered.filter(taskNeedsAttention) }
        if let priority { filtered = filtered.filter { $0.priority == priority } }
        if staleOnly { filtered = filtered.filter(isTaskStale) }
        if let dependsOn {
            filtered = filtered.filter { $0.dependsOn.contains(dependsOn) }
        }
        return filtered
    }

    func dependentTasks(teamName: String, taskId: String) -> [TeamTask] {
        taskBoards[teamName, default: []].filter { $0.dependsOn.contains(taskId) || $0.parentTaskId == taskId }
    }

    func postHeartbeat(teamName: String, agentName: String, summary: String?) {
        guard teams[teamName] != nil else { return }
        heartbeats[teamName, default: [:]][agentName] = (Date(), summary?.nilIfBlank)
        syncTeamStateToDaemon()
    }

    func inboxItems(teamName: String, topOnly: Bool = false) -> [[String: Any]] {
        guard teams[teamName] != nil else { return [] }
        let now = Date()
        var items: [[String: Any]] = []

        for task in taskBoards[teamName, default: []] {
            let staleSeconds = staleAgeSeconds(for: task, now: now)
            let attention: (Int, String)?
            switch task.status {
            case "blocked":
                attention = (1, task.blockedReason ?? "Blocked")
            case "review_ready":
                attention = (2, task.reviewSummary ?? "Ready for review")
            case "failed":
                attention = (3, task.result ?? "Task failed")
            default:
                if let staleSeconds {
                    attention = (4, "Stale for \(staleSeconds)s")
                } else if task.status == "completed" {
                    attention = (5, task.result ?? "Completed")
                } else {
                    attention = nil
                }
            }
            guard let attention else { continue }
            items.append([
                "kind": "task",
                "priority": attention.0,
                "team_name": teamName,
                "task_id": task.id,
                "agent_name": task.assignee as Any,
                "reason": attention.1,
                "age_seconds": Int(now.timeIntervalSince(task.updatedAt)),
                "summary": task.title,
                "task_title": task.title,
                "result": task.result as Any,
                "review_summary": task.reviewSummary as Any,
                "status": task.status,
                "is_stale": staleSeconds != nil,
                "stale_seconds": staleSeconds as Any
            ])
        }

        for message in messages[teamName, default: []] {
            let priority: Int?
            switch message.type {
            case "blocked":
                priority = 1
            case "review_ready":
                priority = 2
            case "error":
                priority = 3
            default:
                priority = nil
            }
            guard let priority else { continue }
            items.append([
                "kind": "message",
                "priority": priority,
                "team_name": teamName,
                "task_id": NSNull(),
                "agent_name": message.from,
                "reason": message.type,
                "age_seconds": Int(now.timeIntervalSince(message.timestamp)),
                "summary": message.content,
                "message_id": message.id
            ])
        }

        let sorted = items.sorted {
            let lhsPriority = $0["priority"] as? Int ?? Int.max
            let rhsPriority = $1["priority"] as? Int ?? Int.max
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            let lhsAge = $0["age_seconds"] as? Int ?? .max
            let rhsAge = $1["age_seconds"] as? Int ?? .max
            return lhsAge > rhsAge
        }
        if topOnly, let first = sorted.first { return [first] }
        return sorted
    }

    /// Clear the task board for a team.
    func clearTasks(teamName: String) {
        taskBoards.removeValue(forKey: teamName)
        syncTeamStateToDaemon()
    }

    func taskDictionary(_ task: TeamTask) -> [String: Any] {
        var dict: [String: Any] = [
            "id": task.id,
            "title": task.title,
            "description": task.details as Any,
            "acceptance_criteria": task.acceptanceCriteria,
            "labels": task.labels,
            "estimated_size": task.estimatedSize as Any,
            "status": task.status,
            "priority": task.priority,
            "depends_on": task.dependsOn,
            "parent_task_id": task.parentTaskId as Any,
            "child_task_ids": task.childTaskIds,
            "reassignment_count": task.reassignmentCount,
            "superseded_by": task.supersededBy as Any,
            "assignee": task.assignee as Any,
            "blocked_reason": task.blockedReason as Any,
            "review_summary": task.reviewSummary as Any,
            "created_by": task.createdBy,
            "result": task.result as Any,
            "created_at": ISO8601DateFormatter().string(from: task.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: task.updatedAt),
            "needs_attention": taskNeedsAttention(task),
            "is_stale": isTaskStale(task)
        ]
        if let startedAt = task.startedAt {
            dict["started_at"] = ISO8601DateFormatter().string(from: startedAt)
        }
        if let completedAt = task.completedAt {
            dict["completed_at"] = ISO8601DateFormatter().string(from: completedAt)
        }
        if let lastProgressAt = task.lastProgressAt {
            dict["last_progress_at"] = ISO8601DateFormatter().string(from: lastProgressAt)
            dict["stale_seconds"] = max(0, Int(Date().timeIntervalSince(lastProgressAt)))
        } else {
            dict["stale_seconds"] = NSNull()
        }
        return dict
    }

    func messageDictionary(_ message: TeamMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "id": message.id,
            "from": message.from,
            "type": message.type,
            "content": message.content,
            "timestamp": ISO8601DateFormatter().string(from: message.timestamp),
        ]
        if let to = message.to {
            dict["to"] = to
        }
        return dict
    }

    private func normalizedMessageType(_ type: String) -> String {
        switch type.lowercased() {
        case "note", "progress", "blocked", "review_ready", "error", "report":
            return type.lowercased()
        case "complete":
            return "report"
        default:
            return "note"
        }
    }

    private func normalizedTaskStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "pending":
            return "queued"
        case "done":
            return "completed"
        case "review":
            return "review_ready"
        case "queued", "assigned", "in_progress", "blocked", "review_ready", "completed", "failed", "abandoned":
            return status.lowercased()
        default:
            return status.lowercased()
        }
    }

    private func heartbeatAgeSeconds(teamName: String, agentName: String) -> Int? {
        guard let heartbeat = heartbeats[teamName]?[agentName] else { return nil }
        return max(0, Int(Date().timeIntervalSince(heartbeat.at)))
    }

    private func isHeartbeatStale(_ heartbeat: (at: Date, summary: String?)) -> Bool {
        Date().timeIntervalSince(heartbeat.at) >= staleHeartbeatThreshold
    }

    func agentState(teamName: String, agentName: String) -> String {
        agentRuntimeState(teamName: teamName, agentName: agentName)
    }

    private func agentRuntimeState(teamName: String, agentName: String) -> String {
        guard let task = activeTask(for: teamName, agentName: agentName) else { return "idle" }
        switch task.status {
        case "blocked":
            return "blocked"
        case "review_ready":
            return "review_ready"
        case "failed":
            return "error"
        case "queued", "assigned":
            return "idle"
        default:
            return "running"
        }
    }

    private func activeTask(for teamName: String, agentName: String) -> TeamTask? {
        taskBoards[teamName, default: []]
            .filter { $0.assignee == agentName && !isTerminalTaskStatus($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private func isTerminalTaskStatus(_ status: String) -> Bool {
        ["completed", "failed", "abandoned"].contains(status)
    }

    private func taskNeedsAttention(_ task: TeamTask) -> Bool {
        ["blocked", "review_ready", "failed"].contains(task.status) || isTaskStale(task)
    }

    private func isTaskStale(_ task: TeamTask) -> Bool {
        staleAgeSeconds(for: task, now: Date()) != nil
    }

    private func staleAgeSeconds(for task: TeamTask, now: Date) -> Int? {
        guard !isTerminalTaskStatus(task.status) else { return nil }
        let anchor = task.lastProgressAt ?? task.startedAt ?? task.updatedAt
        let age = Int(now.timeIntervalSince(anchor))
        return age >= Int(staleTaskThreshold) ? age : nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
