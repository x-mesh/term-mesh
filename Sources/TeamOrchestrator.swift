import AppKit
import Bonsplit
import Foundation
import os

/// Manages multi-agent Claude teams where a leader orchestrates N agent instances,
/// each running in split panes within a single workspace.
@MainActor
final class TeamOrchestrator: ObservableObject {
    static let shared = TeamOrchestrator()

    struct AgentMember: Identifiable {
        let id: String           // agent-name@team-name (stable identity across hard restart)
        let name: String         // e.g. "executor", "reviewer"
        let teamName: String
        let cli: String          // "claude", "kiro" (which CLI to run)
        let launchCommand: String // bare binary name fallback (e.g. "claude") for retype
        let model: String        // "opus", "sonnet", "haiku"
        let agentType: String    // "Explore", "executor", etc.
        let color: String        // terminal color
        let instructions: String // role description for leader routing
        let workspaceId: UUID
        /// nil for headless agents (no GUI pane); set for pane-mode agents.
        /// Mutable so hard restart (pane close + respawn) can rewrite the panel
        /// without rebuilding the AgentMember from scratch.
        var panelId: UUID?
        var parentSessionId: String?
        let createdAt: Date
        // Worktree isolation
        var worktreeName: String?
        var worktreePath: String?
        var worktreeBranch: String?
        /// Full CLI invocation captured at spawn time (binary + model flag + system
        /// prompt + agent-type flags). Retyped on soft restart to recover original
        /// agent context rather than the bare binary name. nil for headless agents
        /// (daemon-managed subprocess, no pane to retype into).
        var originalSpawnCommand: String?
        /// The exact `agentWorkDir` used when the pane was first spawned (either
        /// the worktree path or the team's working directory). Hard restart feeds
        /// it back into `addAgentPaneToWorkspace` so cwd is preserved.
        var originalAgentWorkDir: String?
    }

    struct Team: Identifiable {
        let id: String            // team name
        let leaderSessionId: String
        let leaderMode: String    // "repl", "claude", "kiro", "codex", "gemini", "adopted"
        let leaderModel: String   // e.g. "sonnet", "opus", "haiku"
        let leaderPanelId: UUID   // leader pane for sending instructions
        let leaderWorkspaceId: UUID?  // only set in "adopted" mode (leader lives in a separate workspace)
        let workingDirectory: String
        let workspaceId: UUID     // agent workspace (may differ from leader workspace in "adopted" mode)
        var agents: [AgentMember]
        let createdAt: Date
        var gitRepoRoot: String?  // for worktree cleanup
        var worktreeMode: String  // "off", "shared", "isolated"
        var sharedWorktreeName: String?
        var sharedWorktreePath: String?
        var sharedWorktreeBranch: String?
        /// Phase 2 — stable headless team UUID returned by `headless.create_team` /
        /// `headless.resume_team`. Nil for pane-mode (non-headless) teams.
        var teamUuid: String? = nil
    }

    struct AgentPaneIdentity: Equatable {
        let teamName: String
        let agentName: String
        let panelId: UUID
        let workspaceId: UUID
        let launchCommand: String
        /// Full CLI invocation; falls back to launchCommand at use sites when nil.
        var originalSpawnCommand: String?
    }

    struct AgentMentionTarget: Equatable {
        let teamName: String
        let name: String
        let cli: String
        let model: String
        let agentType: String
        let workspaceId: UUID
        let panelId: UUID?
    }

    @Published private(set) var teams: [String: Team] = [:]
    // Round-robin counter per "teamName/agentName" key — cycles across duplicate-named agents.
    private var agentSendRoundRobin: [String: Int] = [:]

    /// In-flight send counter keyed by "<team>/<agent>". Incremented at the start
    /// of sendToAgent and decremented after sendIMEText completes. Hard restart
    /// waits for this counter to drain (with a 200ms grace) before closing the pane.
    private var activeSends: [String: Int] = [:]

    /// Per-agent migration guard. While the key is present, panelId-bound
    /// operations on that agent should bail out with `migration_in_flight`.
    private var migratingAgents: Set<String> = []

    /// Resolve the correct TabManager for a team by locating any agent panel in the window hierarchy.
    /// Returns nil only if no agent panel can be found (all closed or headless).
    func resolveTabManager(teamName: String) -> TabManager? {
        guard let team = teams[teamName] else { return nil }
        // Try each agent until we find one whose panel is still alive in a window.
        for agent in team.agents {
            guard let pid = agent.panelId else { continue }
            if let located = AppDelegate.shared?.locateSurface(surfaceId: pid) {
                return located.tabManager
            }
        }
        return nil
    }

    /// When true, agent terminal surfaces are occluded; a periodic timer triggers a single
    /// ghostty_surface_draw every 3 s so new output is visible when the user glances at agents.
    @Published private(set) var agentRenderingPaused = false

    private var periodicRenderTimer: DispatchSourceTimer?

#if DEBUG
    /// Debug-only one-shot flag: log periodicRenderAgents on first fire only to avoid noise.
    private static var _periodicRenderLogged = false
#endif

    /// Reads the user-configured interval (seconds) from UserDefaults; defaults to 3.
    private var periodicRenderInterval: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: "agentRenderingInterval")
        return stored > 0 ? TimeInterval(stored) : 3.0
    }

    /// Called when the user changes the rendering interval in Settings.
    /// Restarts the timer with the new interval if rendering is currently paused.
    func updatePeriodicRenderInterval() {
        guard agentRenderingPaused else { return }
        stopPeriodicRenderTimer()
        startPeriodicRenderTimer()
    }

    /// Toggle rendering for all agent panes across all teams.
    /// Paused: occludes surfaces (stops CVDisplayLink + wakeup rendering) and starts a 3-second
    /// periodic draw so new output is still captured. Resumed: restores normal rendering.
    func toggleAgentRendering() {
#if DEBUG
        dlog("team.toggleAgentRendering paused=\(agentRenderingPaused)")
#endif
        agentRenderingPaused.toggle()
        if agentRenderingPaused {
            setAgentSurfaceOcclusion(visible: false)
            startPeriodicRenderTimer()
        } else {
            stopPeriodicRenderTimer()
            setAgentSurfaceOcclusion(visible: true)
        }
    }

    private func setAgentSurfaceOcclusion(visible: Bool) {
#if DEBUG
        let agentCount = teams.values.reduce(0) { $0 + $1.agents.count }
        dlog("team.setAgentSurfaceOcclusion visible=\(visible) agentCount=\(agentCount)")
#endif
        for team in teams.values {
            for agent in team.agents {
                guard let pid = agent.panelId,
                      let appDelegate = AppDelegate.shared,
                      let located = appDelegate.locateSurface(surfaceId: pid),
                      let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                      let panel = workspace.panels[pid] as? TerminalPanel else { continue }
                // Set renderingPaused before any focus/occlusion calls so guards work correctly.
                panel.surface.renderingPaused = !visible
                // setOcclusion(false) blocks all rendering paths (CVDisplayLink + wakeup-driven).
                // setFocus is also called for belt-and-suspenders CVDisplayLink control.
                if visible {
                    panel.surface.setOcclusion(true)
                    panel.surface.setFocus(true)
                } else {
                    panel.surface.setFocus(false)
                    panel.surface.setOcclusion(false)
                }
            }
        }
    }

    private func startPeriodicRenderTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + periodicRenderInterval, repeating: periodicRenderInterval)
        timer.setEventHandler { [weak self] in
            self?.periodicRenderAgents()
        }
        timer.resume()
        periodicRenderTimer = timer
    }

    private func stopPeriodicRenderTimer() {
        periodicRenderTimer?.cancel()
        periodicRenderTimer = nil
    }

    /// Re-present agent terminal surfaces after macOS wakes the display.
    /// Unlike the periodic path which only fires when rendering is paused,
    /// this runs unconditionally because wake can black-out any surface
    /// regardless of its paused state.
    /// Issues an immediate draw plus a 50ms-delayed follow-up to absorb cases where IOSurface /
    /// CALayer rebinding completes a few frames after didWakeNotification fires (especially on
    /// external displays returning from sleep).
    func drawAgentSurfacesAfterWake() {
        drawAgentSurfaces(reason: "wake")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.drawAgentSurfaces(reason: "wake-followup")
        }
    }

    /// Called by the periodic timer while rendering is paused.
    /// Issues a single ghostty_surface_draw per agent so new terminal output is captured.
    private func periodicRenderAgents() {
#if DEBUG
        if !Self._periodicRenderLogged {
            Self._periodicRenderLogged = true
            let agentCount = teams.values.reduce(0) { $0 + $1.agents.count }
            dlog("team.periodicRenderAgents firstFire=true paused=\(agentRenderingPaused) agentCount=\(agentCount)")
        }
#endif
        guard agentRenderingPaused else { return }
        drawAgentSurfaces(reason: "periodic")
    }

    private func drawAgentSurfaces(reason: String) {
        var drawnCount = 0
        for team in teams.values {
            for agent in team.agents {
                guard let pid = agent.panelId,
                      let appDelegate = AppDelegate.shared,
                      let located = appDelegate.locateSurface(surfaceId: pid),
                      let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                      let panel = workspace.panels[pid] as? TerminalPanel,
                      let surface = panel.surface.surface else { continue }
                ghostty_surface_draw(surface)
                drawnCount += 1
            }
        }
#if DEBUG
        dlog("team.drawAgentSurfaces reason=\(reason) drawn=\(drawnCount) paused=\(agentRenderingPaused)")
#endif
    }

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
        var resultPath: String?
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
    /// Maximum messages retained per team. Oldest messages are pruned on insert.
    private let maxMessagesPerTeam = 500
    private var heartbeats: [String: [String: (at: Date, summary: String?)]] = [:]
    private let staleTaskThreshold: TimeInterval = 10 * 60
    private let staleHeartbeatThreshold: TimeInterval = 5 * 60

    // MARK: - Aspect-Ratio-Aware Grid Layout

    /// Compute optimal (cols, rows) so each pane's aspect ratio is closest to 1:1 (square).
    /// Falls back to fixed column logic when container size is unavailable.
    private func optimalGridDimensions(
        count: Int,
        containerSize: CGSize,
        hasLeader: Bool
    ) -> (cols: Int, rows: Int) {
        guard count > 1 else { return (1, 1) }

        let totalWidth: CGFloat = containerSize.width
        let totalHeight: CGFloat = containerSize.height

        guard totalWidth > 0, totalHeight > 0 else {
            if count <= 3 { return (1, count) }
            if count <= 8 { return (2, Int(ceil(Double(count) / 2.0))) }
            return (3, Int(ceil(Double(count) / 3.0)))
        }

        var bestCols = 1
        var bestRatio = CGFloat.greatestFiniteMagnitude

        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            // When there's a leader, it occupies one column-width slot in the equalized grid.
            // So actual cell width = totalWidth / (cols + 1 leader slot).
            let cellW = hasLeader ? totalWidth / CGFloat(cols + 1) : totalWidth / CGFloat(cols)
            let cellH = totalHeight / CGFloat(rows)
            let ratio = max(cellW / cellH, cellH / cellW)
            // Penalize portrait (tall) cells — prefer landscape (wide) layouts
            let adjustedRatio = cellH > cellW ? ratio * 1.2 : ratio

            if adjustedRatio < bestRatio {
                bestRatio = adjustedRatio
                bestCols = cols
            }
        }

        let bestRows = Int(ceil(Double(count) / Double(bestCols)))
        return (bestCols, bestRows)
    }

    /// Equalize agent pane splits, skipping the root leader|agents split.
    /// H-splits use column-count (equal column widths regardless of row count).
    /// V-splits use leaf-count (equal row heights within each column).
    private func equalizeAgentGrid(workspace: Workspace) {
        /// Count columns in a subtree: H-splits add children's columns, V-splits count as 1.
        func columnCount(_ node: ExternalTreeNode) -> Int {
            switch node {
            case .pane: return 1
            case .split(let s):
                if s.orientation == "horizontal" {
                    return columnCount(s.first) + columnCount(s.second)
                } else {
                    return 1
                }
            }
        }
        /// Count leaves for V-split equalization (equal row heights).
        func leafCount(_ node: ExternalTreeNode) -> Int {
            switch node {
            case .pane: return 1
            case .split(let s): return leafCount(s.first) + leafCount(s.second)
            }
        }
        func equalizeSplits(_ node: ExternalTreeNode) {
            guard case .split(let splitNode) = node else { return }
            let ratio: Double
            if splitNode.orientation == "horizontal" {
                // Column-count: equal width per column
                let leftCols = columnCount(splitNode.first)
                let rightCols = columnCount(splitNode.second)
                ratio = Double(leftCols) / Double(leftCols + rightCols)
            } else {
                // Leaf-count: equal height per row
                let leftLeaves = leafCount(splitNode.first)
                let rightLeaves = leafCount(splitNode.second)
                ratio = Double(leftLeaves) / Double(leftLeaves + rightLeaves)
            }
            if let splitId = UUID(uuidString: splitNode.id) {
                workspace.bonsplitController.setDividerPosition(CGFloat(ratio), forSplit: splitId)
            }
            equalizeSplits(splitNode.first)
            equalizeSplits(splitNode.second)
        }
        let tree = workspace.bonsplitController.treeSnapshot()
        // Set root split to 50% (leader gets half), then equalize the agent subtree
        if case .split(let root) = tree {
            if let rootId = UUID(uuidString: root.id) {
                workspace.bonsplitController.setDividerPosition(0.5, forSplit: rootId)
            }
            #if DEBUG
            dlog("[equalize] root orientation=\(root.orientation), agent subtree columns=\(columnCount(root.second)), leaves=\(leafCount(root.second))")
            #endif
            equalizeSplits(root.second)
        } else {
            #if DEBUG
            dlog("[equalize] ERROR: tree root is not a split (single pane?)")
            #endif
        }
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

    // MARK: - Agent Pane Env (shared helper)

    /// Build the complete environment dict for an agent pane.
    /// Single source of truth for agent pane env — used by both `createTeam` and
    /// `attachToWorkspace` to prevent the 2026-03-19 regression where
    /// `TERMMESH_WINDOW_ID` / `TERMMESH_WORKSPACE_ID` were missing on agent panes.
    ///
    /// Includes:
    /// - PATH with essential homebrew/local bins merged
    /// - Socket path (TERMMESH_SOCKET / CMUX_SOCKET)
    /// - Team identity (TERMMESH_TEAM*, CMUX_TEAM*)
    /// - CLAUDECODE flag (only for `agentCli == "claude"`; codex/gemini/kiro must not have it)
    /// - Per-agent routing (TERMMESH_AGENT_NAME, TERMMESH_AGENT_ROLE, TERMMESH_WINDOW_ID, TERMMESH_WORKSPACE_ID)
    static func buildAgentPaneEnv(
        teamName: String,
        agentName: String,
        agentType: String,
        agentCli: String,
        windowId: String?,
        workspaceId: UUID
    ) -> [String: String] {
        // Essential PATH entries — pane commands don't source shell profiles,
        // so we must inject homebrew/local bins explicitly.
        let resourceBin = Bundle.main.resourcePath.map { "\($0)/bin" } ?? ""
        let essentialPaths = [
            resourceBin,
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let appPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let existingPaths = Set(appPath.split(separator: ":").map(String.init))
        let missingPaths = essentialPaths.filter { !existingPaths.contains($0) }
        let currentPath = (appPath.isEmpty ? essentialPaths : appPath.split(separator: ":").map(String.init) + missingPaths).joined(separator: ":")
        let socketPath = SocketControlSettings.socketPath()

        var env: [String: String] = [
            "TERMMESH_TEAM_AGENT": "1",
            "CMUX_TEAM_AGENT": "1",
            "TERMMESH_TEAM_NAME": teamName,
            "CMUX_TEAM_NAME": teamName,
            "TERMMESH_TEAM": teamName,
            "CMUX_TEAM": teamName,
            "TERMMESH_SOCKET": socketPath,
            "CMUX_SOCKET": socketPath,
            "PATH": currentPath,
        ]

        // Only claude agents get CLAUDECODE=1 (Anthropic-specific; codex/gemini/kiro must not).
        if agentCli == "claude" {
            env["CLAUDECODE"] = "1"
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        }

        // Per-agent routing — 2026-03-19 regression guard.
        env["TERMMESH_AGENT_NAME"] = agentName
        env["TERMMESH_AGENT_ROLE"] = agentType
        if let windowId = windowId, !windowId.isEmpty {
            env["TERMMESH_WINDOW_ID"] = windowId
        }
        env["TERMMESH_WORKSPACE_ID"] = workspaceId.uuidString

        return env
    }

    // MARK: - Agent Pane Construction (shared helper)

    /// Build the kiro worker prompt embedded in the kiro agent profile at CLI startup.
    private static func buildKiroWorkerPrompt(agentName: String, teamName: String, instructions: String) -> String {
        let roleInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleSection = roleInstructions.isEmpty ? "" : """

        Role instructions:
        \(roleInstructions)
        """
        return """
        You are a focused worker agent named '\(agentName)' in team '\(teamName)'. \
        Rules: 1) Be EXTREMELY concise — no preamble, no summaries unless asked. \
        2) Output only code, commands, or direct answers. \
        3) When done, state the result in 1-2 lines max. 4) Never repeat the task back.

        Operational rules:
        1. Work should be tracked with task ids.
        2. When you begin a task, run `tm-agent task start <task_id>`.
        3. While actively working, periodically run `tm-agent heartbeat '<short progress summary>'`.
        4. If blocked, run `tm-agent task block <task_id> '<reason>'`.
        5. If ready for validation, run `tm-agent task review <task_id> '<summary>'`.
        6. When done, run `tm-agent reply '<5-line header plus result>'`; it auto-reports and completes your active task.
        When you complete any task, you MUST use your bash/execute tool to run:
        tm-agent reply '<STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus concise result>'
        Do NOT just write the result as text — actually execute the shell command.
        \(roleSection)
        """
    }

    /// Add a single agent pane to an existing workspace.
    ///
    /// This is the single source of truth for agent pane construction. It builds
    /// the CLI-specific invocation, wraps it in a shell with working-directory cd
    /// when a worktree is active, constructs the pane env via `buildAgentPaneEnv`,
    /// spawns the split pane, applies the pane title, and returns an `AgentMember`.
    ///
    /// Used by:
    /// - `createTeam` — inside the multi-agent grid loop
    /// - `attachToWorkspace` — for single-agent attach (t3)
    ///
    /// The caller is responsible for:
    /// - Pre-normalizing `agentCli` (empty → "claude")
    /// - Resolving `cliPath` via `agentBinaryPath`
    /// - Choosing `splitFrom` and `orientation` (grid vs single-agent logic differs)
    /// - Deciding `agentWorkDir` (worktree path or team working directory)
    ///
    /// Returns `nil` on split failure. The caller logs context-specific errors.
    private func addAgentPaneToWorkspace(
        workspace: Workspace,
        agentName: String,
        agentCli: String,
        agentModel: String,
        agentType: String,
        agentColor: String,
        agentInstructions: String,
        cliPath: String,
        teamName: String,
        leaderSessionId: String,
        workingDirectory: String,
        agentWorkDir: String,
        worktreeName: String?,
        worktreePath: String?,
        worktreeBranch: String?,
        splitFrom: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        /// Phase 2 (pane-mode resume): when set and `agentCli == "claude"`,
        /// the agent CLI is invoked with `--resume <sid>` so claude
        /// re-attaches to the captured session. Defaults to nil — fresh spawn.
        /// Other CLIs (codex/kiro/gemini) currently ignore this; resume
        /// support for them is a follow-up.
        resumeSessionId: String? = nil,
        extraArgs: [String] = [],
        extraEnv: [String: String] = [:],
        tabManager: TabManager
    ) -> AgentMember? {
        let agentId = "\(agentName)@\(teamName)"

        // Build CLI-specific invocation
        var agentCommand: String
        switch agentCli {
        case "kiro":
            let workerPrompt = Self.buildKiroWorkerPrompt(agentName: agentName, teamName: teamName, instructions: agentInstructions)
            agentCommand = buildKiroCommand(
                kiroPath: cliPath,
                agentName: agentName,
                teamName: teamName,
                model: agentModel,
                systemPrompt: workerPrompt,
                extraArgs: extraArgs
            )
        case "codex":
            agentCommand = buildCodexCommand(
                codexPath: cliPath,
                agentName: agentName,
                teamName: teamName,
                model: agentModel,
                extraArgs: extraArgs
            )
        case "gemini":
            agentCommand = buildGeminiCommand(
                geminiPath: cliPath,
                agentName: agentName,
                teamName: teamName,
                model: agentModel,
                extraArgs: extraArgs
            )
        default:
            agentCommand = buildClaudeCommand(
                claudePath: cliPath,
                agentId: agentId,
                agentName: agentName,
                teamName: teamName,
                agentColor: agentColor,
                parentSessionId: leaderSessionId,
                agentType: agentType,
                model: agentModel,
                instructions: agentInstructions,
                extraArgs: extraArgs
            )
            if let sid = resumeSessionId, !sid.isEmpty {
                // Mirror the leader pattern (createTeam, claude case) — append
                // `--resume <sid>` so claude re-attaches to its prior session.
                agentCommand.append(" --resume \(sid)")
            }
        }

        // Wrap so the terminal stays open (drops to shell) if the CLI exits.
        // When a worktree is active, build a login-shell invocation with explicit
        // `cd` to guarantee the agent CLI starts in the worktree directory.
        let shellCommand: String
        if agentWorkDir != workingDirectory {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let inner = "cd \"\(agentWorkDir)\" && exec \(agentCommand); exec $SHELL"
            let escaped = inner.replacingOccurrences(of: "'", with: "'\\''")
            shellCommand = "\(shell) -l -c '\(escaped)'"
        } else {
            shellCommand = "\(agentCommand); exec $SHELL"
        }

        // Build env via shared helper (2026-03-19 regression guard — single source of truth)
        let windowId = AppDelegate.shared?.windowId(for: tabManager)?.uuidString
        var paneEnv = Self.buildAgentPaneEnv(
            teamName: teamName,
            agentName: agentName,
            agentType: agentType,
            agentCli: agentCli,
            windowId: windowId,
            workspaceId: workspace.id
        )
        // Profile env is merged last — user-defined values take precedence over defaults.
        if !extraEnv.isEmpty {
            paneEnv.merge(extraEnv) { _, new in new }
        }

        // Spawn the split pane. `insertFirst` lets hard-restart respawn into the
        // exact slot the dead pane occupied within its parent split.
        guard let panel = workspace.newTerminalSplit(
            from: splitFrom,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: false,
            skipEqualization: true,
            workingDirectory: agentWorkDir,
            command: shellCommand,
            environment: paneEnv
        ) else {
            return nil
        }

        // Apply pane title (include branch if worktree active)
        let colorEmoji = Self.colorEmoji(agentColor)
        let paneTitle = worktreeBranch != nil
            ? "\(colorEmoji) \(agentName) [\(worktreeBranch!)]"
            : "\(colorEmoji) \(agentName)"
        workspace.setPanelCustomTitle(panelId: panel.id, title: paneTitle)

        return AgentMember(
            id: agentId,
            name: agentName,
            teamName: teamName,
            cli: agentCli,
            launchCommand: Self.defaultLaunchCommand(for: agentCli),
            model: agentModel,
            agentType: agentType,
            color: agentColor,
            instructions: agentInstructions,
            workspaceId: workspace.id,
            panelId: panel.id,
            parentSessionId: leaderSessionId,
            createdAt: Date(),
            worktreeName: worktreeName,
            worktreePath: worktreePath,
            worktreeBranch: worktreeBranch,
            originalSpawnCommand: agentCommand,
            originalAgentWorkDir: agentWorkDir
        )
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
        leaderModel: String = "sonnet",
        resumeSessionId: String? = nil,
        worktreeMode: String = "off",
        executionMode: String = "pane",
        adoptedLeaderSurfaceId: UUID? = nil,
        skipRunbookPromptForInteractiveAgents: Bool = false,
        /// Phase 2 (pane-mode resume): agent name → claude session id, used to
        /// invoke each agent CLI with `--resume <sid>`. Pane-mode resume passes
        /// this; fresh team creation leaves it nil.
        agentResumeSessionIds: [String: String]? = nil,
        tabManager: TabManager
    ) -> Team? {
        guard !agents.isEmpty else { return nil }

        // Always clear stale on-disk state for this team name before creating.
        // Result/message/task files in /tmp persist across app restarts and workspace closures,
        // causing wait --mode report to return immediately with outdated data.
        clearResults(teamName: name)
        clearMessages(teamName: name)
        clearTasks(teamName: name)

        // Auto-cleanup: if a team with this name exists but its workspace was closed, remove the stale entry.
        // Check across ALL windows (not just the current tabManager) to enforce global uniqueness.
        if let existing = teams[name] {
            let workspaceAlive: Bool = {
                // First check if any window still contains this workspace
                if let appDelegate = AppDelegate.shared,
                   appDelegate.contextContainingTabId(existing.workspaceId) != nil {
                    return true
                }
                // Fallback: check the passed tabManager (in case AppDelegate lookup fails)
                return tabManager.tabs.contains(where: { $0.id == existing.workspaceId })
            }()
            if workspaceAlive {
                Logger.team.info("team '\(name, privacy: .public)' already exists")
                return nil
            }
            Logger.team.info("cleaning up stale team '\(name, privacy: .public)' (workspace closed)")
            teams.removeValue(forKey: name)
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
        if executionMode == "headless" {
            workspace.customTitle = "[\(name)] \(agents.count) headless"
            workspace.title = "[\(name)] \(agents.count) headless"
        } else {
            workspace.customTitle = "[\(name)]"
            workspace.title = "[\(name)]"
        }

        // Env vars for agent panes
        // Include essential PATH entries since pane commands may not source shell profiles
        // Include app's Resources/bin (contains tm-agent, term-meshd)
        let resourceBin = Bundle.main.resourcePath.map { "\($0)/bin" } ?? ""
        let essentialPaths = [
            resourceBin,
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
        // Leader env: Claude leader needs no CLAUDECODE (runs its own instance).
        // Explicitly clear CLAUDECODE to prevent inheritance from parent process
        // (Claude Code refuses to start inside another CLAUDECODE session).
        // Non-claude CLI leaders (kiro, codex, gemini) also clear it.
        // REPL leader gets claudeAgentEnv so nested `claude` calls work.
        let leaderEnv = leaderMode == "repl"
            ? claudeAgentEnv
            : baseEnv.merging(["CLAUDECODE": ""]) { _, new in new }

        // Worktree isolation based on team-level mode.
        // Created early so both leader and agent panels can use the worktree path.
        let useWorktrees = worktreeMode != "off"
        let gitRepoRoot = useWorktrees ? daemon.findGitRoot(from: workingDirectory) : nil

        // Shared mode: create ONE worktree for the whole team
        var sharedWorkDir: String?
        var sharedWtName: String?
        var sharedWtPath: String?
        var sharedWtBranch: String?

        if useWorktrees {
            WorktreeLog.log("team.create mode=\(worktreeMode) team=\(name) gitRoot=\(gitRepoRoot ?? "nil")")
        }

        if worktreeMode == "shared", let repoRoot = gitRepoRoot {
            let branchName = "team/\(name)"
            let result = daemon.createWorktreeWithError(repoPath: repoRoot, branch: branchName)
            switch result {
            case .success(let info):
                sharedWorkDir = info.path
                sharedWtName = info.name
                sharedWtPath = info.path
                sharedWtBranch = info.branch
                Logger.team.info("shared worktree for team '\(name, privacy: .public)': \(info.path, privacy: .public)")
                WorktreeLog.log("team.shared.ok team=\(name) path=\(info.path) branch=\(info.branch)")
            case .failure(let error):
                Logger.team.error("shared worktree failed: \(error, privacy: .public), using original directory")
                WorktreeLog.log("team.shared.FAIL team=\(name) error=\(error)")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Worktree Creation Failed"
                    alert.informativeText = "Shared worktree for team '\(name)' could not be created: \(error). Agents will use the original directory."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.presentAsSheet()
                }
            }
        }

        // Leader working directory: use shared worktree when active
        let leaderWorkDir = sharedWorkDir ?? workingDirectory

        // First panel = leader console (left side)
        // Close the default panel and create a new one with the leader script as command
        guard let defaultPanelId = workspace.focusedPanelId else {
            Logger.team.error("no initial panel in workspace")
            return nil
        }

        // ── Leader setup: adopted vs normal ─────────────────────────────────
        // "adopted" mode: caller's terminal IS the leader. Skip leader pane creation;
        // register the caller's surface as leaderPanelId and track its workspace separately.
        let leaderPanelId: UUID
        let leaderWorkspaceId: UUID?

        if leaderMode == "adopted" {
            guard let adoptedSurfaceId = adoptedLeaderSurfaceId else {
                Logger.team.error("[team] adopted mode requires adoptedLeaderSurfaceId")
                return nil
            }
            // Look up the adopted leader's workspace so cross-workspace sends work correctly.
            leaderWorkspaceId = AppDelegate.shared?.locateSurface(surfaceId: adoptedSurfaceId)?.workspaceId
            if leaderWorkspaceId == nil {
                Logger.team.warning("[team] adopted mode: locateSurface(surfaceId:) returned nil — leader workspace unknown, cross-workspace send may fail")
            }
            leaderPanelId = adoptedSurfaceId
            #if DEBUG
            dlog("[team] adopted mode: leaderPanelId=\(adoptedSurfaceId.uuidString.prefix(8)) leaderWorkspaceId=\(leaderWorkspaceId?.uuidString.prefix(8) ?? "nil")")
            #endif
            // The workspace's defaultPanel will serve as anchor for agent splits.
            // It will be closed after all agent panes are created.
        } else {
            leaderWorkspaceId = nil

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
                        let summary = Self.oneLinerFromInstructions(a.instructions)
                        return summary.isEmpty
                            ? "  \(i + 1). \(a.name) (\(a.agentType))"
                            : "  \(i + 1). \(a.name) (\(a.agentType)) — \(summary)"
                    }.joined(separator: "\n")
                    let runbookSection = Self.runbookLeaderSection(
                        workingDirectory: leaderWorkDir,
                        roles: agents.map(\.agentType)
                    )
                    let tmAgent = "tm-agent"
                    let systemPrompt = Self.buildLeaderClaudeSystemPrompt(
                        teamName: name,
                        agentList: agentListStr,
                        runbookSection: runbookSection,
                        tmAgent: tmAgent,
                        socketPath: socketPath
                    )
                    // Escape single quotes for shell, same approach as buildClaudeCommand
                    let escaped = systemPrompt.replacingOccurrences(of: "'", with: "'\\''")
                    let quotedPath = claudePath.contains(" ") ? "\"\(claudePath)\"" : claudePath
                    var claudeLeaderParts = ["\(quotedPath)", "--system-prompt '\(escaped)'", "--dangerously-skip-permissions"]
                    if !leaderModel.isEmpty && leaderModel != "sonnet" {
                        claudeLeaderParts.append("--model \(leaderModel)")
                    }
                    if let sid = resumeSessionId, !sid.isEmpty {
                        claudeLeaderParts.append("--resume \(sid)")
                    }
                    leaderCommand = claudeLeaderParts.joined(separator: " ")
                } else {
                    leaderCommand = nil
                }
            case "kiro":
                if let path = agentBinaryPath(cli: "kiro") {
                    leaderCommand = buildKiroCommand(kiroPath: path, agentName: "leader", teamName: name, model: leaderModel, isLeader: true)
                } else { leaderCommand = nil }
            case "codex":
                if let path = agentBinaryPath(cli: "codex") {
                    leaderCommand = buildCodexCommand(codexPath: path, agentName: "leader", teamName: name, model: leaderModel)
                } else { leaderCommand = nil }
            case "gemini":
                if let path = agentBinaryPath(cli: "gemini") {
                    leaderCommand = buildGeminiCommand(geminiPath: path, agentName: "leader", teamName: name, model: leaderModel)
                } else { leaderCommand = nil }
            default:
                leaderCommand = nil
            }
            #if DEBUG
            dlog("[team] leaderMode=\(leaderMode) leaderCommand=\(leaderCommand ?? "nil")")
            #endif

            // If a CLI leader was requested but the binary wasn't found, surface
            // a visible error in the pane instead of silently launching a blank
            // shell (which looks like "leader is empty" to the user).
            // Use a marker so the cd-wrapper below can decide whether to `exec`.
            struct ResolvedLeader { let cmd: String; let isExec: Bool }
            let resolvedLeader: ResolvedLeader? = {
                if let cmd = leaderCommand { return ResolvedLeader(cmd: cmd, isExec: true) }
                if leaderMode == "repl" { return nil }
                let cliName = leaderMode
                let msg = "term-mesh: '\(cliName)' binary not found on PATH or known install locations.\\nSet a custom path under Settings → Agent Teams → CLI Paths, then recreate the team."
                let escaped = msg.replacingOccurrences(of: "'", with: "'\\''")
                return ResolvedLeader(cmd: "printf '\\033[1;31m%b\\033[0m\\n' '\(escaped)'", isExec: false)
            }()

            // Build leader shell command with explicit cd when worktree is active
            let leaderShellCommand: String? = resolvedLeader.map { rl in
                let runVerb = rl.isExec ? "exec " : ""
                if leaderWorkDir != workingDirectory {
                    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                    let inner = "cd \"\(leaderWorkDir)\" && \(runVerb)\(rl.cmd); exec $SHELL"
                    let escaped = inner.replacingOccurrences(of: "'", with: "'\\''")
                    return "\(shell) -l -c '\(escaped)'"
                } else {
                    return "\(rl.cmd); exec $SHELL"
                }
            }

            // Replace default panel: split from it with leader command, then close the original
            guard let leaderPanel = workspace.newTerminalSplit(
                from: defaultPanelId,
                orientation: .horizontal,
                insertFirst: true,
                focus: true,
                skipEqualization: true,
                workingDirectory: leaderWorkDir,
                command: leaderShellCommand,
                environment: leaderEnv
            ) else {
                Logger.team.error("failed to create leader panel")
                return nil
            }
            leaderPanelId = leaderPanel.id

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
        }

        // Agent grid anchor: in normal mode agents split from leaderPanel;
        // in adopted mode they split from the workspace's default panel (no leader pane exists).
        let agentAnchorPanelId = leaderMode == "adopted" ? defaultPanelId : leaderPanelId

        // ── Headless mode: spawn agents via daemon instead of GUI panes ──
        if executionMode == "headless" {
            // Spawn agents via daemon RPC (no GUI panes)
            let agentSpecs: [[String: Any]] = agents.map { a in
                let cli = a.cli.isEmpty ? "claude" : a.cli
                let effectiveInstructions = AgentRunbookService.shared.composeInstructions(
                    roleName: a.agentType,
                    presetInstructions: a.instructions,
                    workingDirectory: workingDirectory,
                    mode: .digest
                )
                let headlessProfile = CLIPathSettings.activeProfile(for: cli)
                let headlessExtraArgs = headlessProfile?.extraArgs ?? []
                let headlessExtraEnv = headlessProfile?.env ?? [:]
                let headlessModel = headlessProfile?.modelOverride ?? a.model
                var spec: [String: Any] = ["name": a.name, "agent_type": a.agentType, "cli": cli, "model": headlessModel]
                if let path = cliPaths[cli] {
                    spec["cli_path"] = path
                }
                if !effectiveInstructions.isEmpty {
                    spec["instructions"] = effectiveInstructions
                }
                if !headlessExtraArgs.isEmpty {
                    spec["extra_args"] = headlessExtraArgs
                }
                if !headlessExtraEnv.isEmpty {
                    spec["extra_env"] = headlessExtraEnv
                }
                return spec
            }
            let createParams: [String: Any] = [
                "team_name": name,
                "working_directory": workingDirectory,
                "leader_session_id": leaderSessionId,
                "agents": agentSpecs,
                "app_socket_path": SocketControlSettings.socketPath(),
            ]
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let result = self.daemon.rpcCallRaw(method: "headless.create_team", params: createParams)
                if let raw = result,
                   let data = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let teamUuid: String?
                    if let inner = obj["result"] as? [String: Any], let uuid = inner["team_uuid"] as? String {
                        teamUuid = uuid
                    } else {
                        teamUuid = obj["team_uuid"] as? String
                    }
                    if let teamUuid {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if var existing = self.teams[name] {
                                existing.teamUuid = teamUuid
                                self.teams[name] = existing
                            }
                        }
                    }
                } else {
                    Logger.team.error("[headless] create_team RPC failed")
                }
            }

            // In adopted mode, close the default panel (no agents to anchor to)
            if leaderMode == "adopted" {
                workspace.closePanel(defaultPanelId)
            }

            // Build headless members (no panelId — they're daemon subprocesses)
            let colors = ["green", "blue", "yellow", "magenta", "cyan", "red"]
            var headlessMembers: [AgentMember] = []
            for (index, agent) in agents.enumerated() {
                let agentColor = agent.color.isEmpty ? colors[index % colors.count] : agent.color
                let agentCli = agent.cli.isEmpty ? "claude" : agent.cli
                let effectiveInstructions = AgentRunbookService.shared.composeInstructions(
                    roleName: agent.agentType,
                    presetInstructions: agent.instructions,
                    workingDirectory: workingDirectory,
                    mode: .digest
                )
                let member = AgentMember(
                    id: "\(agent.name)@\(name)",
                    name: agent.name,
                    teamName: name,
                    cli: agentCli,
                    launchCommand: Self.defaultLaunchCommand(for: agentCli),
                    model: agent.model,
                    agentType: agent.agentType,
                    color: agentColor,
                    instructions: effectiveInstructions,
                    workspaceId: workspace.id,
                    panelId: nil, // headless — no real panel
                    parentSessionId: leaderSessionId,
                    createdAt: Date(),
                    worktreeName: nil,
                    worktreePath: nil,
                    worktreeBranch: nil,
                    originalSpawnCommand: nil, // headless — daemon owns subprocess
                    originalAgentWorkDir: nil
                )
                headlessMembers.append(member)
            }

            let team = Team(
                id: name,
                leaderSessionId: leaderSessionId,
                leaderMode: leaderMode,
                leaderModel: leaderModel,
                leaderPanelId: leaderPanelId,
                leaderWorkspaceId: leaderWorkspaceId,
                workingDirectory: workingDirectory,
                workspaceId: workspace.id,
                agents: headlessMembers,
                createdAt: Date(),
                gitRepoRoot: nil,
                worktreeMode: worktreeMode,
                sharedWorktreeName: nil,
                sharedWorktreePath: nil,
                sharedWorktreeBranch: nil
            )
            teams[name] = team
            TeamDataStore.shared.registerTeam(name, agentNames: headlessMembers.map(\.name))
            syncTeamStateToDaemon()
            Logger.team.info("created headless team '\(name, privacy: .public)' with \(headlessMembers.count, privacy: .public) agent(s) + leader console")
            return team
        }

        // Compute optimal grid dimensions for agent panes
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        let containerSize: CGSize
        if snapshot.containerFrame.width > 0, snapshot.containerFrame.height > 0 {
            containerSize = CGSize(width: snapshot.containerFrame.width, height: snapshot.containerFrame.height)
        } else if let screen = NSScreen.main?.visibleFrame {
            containerSize = CGSize(width: screen.width, height: screen.height)
        } else {
            containerSize = .zero
        }
        let (numCols, _) = optimalGridDimensions(
            count: agents.count, containerSize: containerSize, hasLeader: true
        )

        // Build agent panes with Claude running directly via command parameter
        // This bypasses shell init (.zshrc/.zprofile) entirely for reliable startup.
        for (index, agent) in agents.enumerated() {
            let agentColor = agent.color.isEmpty ? colors[index % colors.count] : agent.color

            // Worktree for this agent
            var agentWorkDir = sharedWorkDir ?? workingDirectory
            var wtName = sharedWtName
            var wtPath = sharedWtPath
            var wtBranch = sharedWtBranch

            if worktreeMode == "isolated", let repoRoot = gitRepoRoot {
                let branchName = "team/\(name)/\(agent.name)"
                let result = daemon.createWorktreeWithError(repoPath: repoRoot, branch: branchName)
                switch result {
                case .success(let info):
                    agentWorkDir = info.path
                    wtName = info.name
                    wtPath = info.path
                    wtBranch = info.branch
                    Logger.team.info("worktree for \(agent.name, privacy: .public): \(info.path, privacy: .public) [\(info.branch, privacy: .public)]")
                    WorktreeLog.log("team.isolated.ok team=\(name) agent=\(agent.name) path=\(info.path) branch=\(info.branch)")
                case .failure(let error):
                    Logger.team.error("worktree failed for \(agent.name, privacy: .public): \(error, privacy: .public), using original directory")
                    WorktreeLog.log("team.isolated.FAIL team=\(name) agent=\(agent.name) error=\(error)")
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Worktree Creation Failed"
                        alert.informativeText = "Worktree for agent '\(agent.name)' could not be created: \(error). Agent will use the original directory."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.presentAsSheet()
                    }
                }
            }

            let agentCli = agent.cli.isEmpty ? "claude" : agent.cli
            let cliPath = cliPaths[agentCli]!
            let effectiveInstructions: String
            if skipRunbookPromptForInteractiveAgents && agentCli != "kiro" {
                effectiveInstructions = agent.instructions
            } else {
                effectiveInstructions = AgentRunbookService.shared.composeInstructions(
                    roleName: agent.agentType,
                    presetInstructions: agent.instructions,
                    workingDirectory: agentWorkDir,
                    mode: .digest
                )
            }

            // Grid layout: agents are assigned to cells in column-major order.
            // col = index % numCols, row = index / numCols
            // Row 0: split RIGHT from previous column (creates natural L→R order).
            // Row > 0: split DOWN from the agent above in the same column.
            let col = index % numCols
            let row = index / numCols

            let splitFrom: UUID
            let orientation: SplitOrientation
            if row == 0 {
                orientation = .horizontal
                if col == 0 {
                    splitFrom = agentAnchorPanelId
                } else {
                    splitFrom = members[col - 1].panelId ?? agentAnchorPanelId
                }
            } else {
                orientation = .vertical
                splitFrom = members[index - numCols].panelId ?? agentAnchorPanelId
            }

            // Delegate pane construction to shared helper (see addAgentPaneToWorkspace).
            let agentResumeSid = agentResumeSessionIds?[agent.name]
            let activeProfile = CLIPathSettings.activeProfile(for: agentCli)
            let profileExtraArgs = activeProfile?.extraArgs ?? []
            let profileExtraEnv = activeProfile?.env ?? [:]
            let effectiveModel = activeProfile?.modelOverride ?? agent.model
            guard let member = addAgentPaneToWorkspace(
                workspace: workspace,
                agentName: agent.name,
                agentCli: agentCli,
                agentModel: effectiveModel,
                agentType: agent.agentType,
                agentColor: agentColor,
                agentInstructions: effectiveInstructions,
                cliPath: cliPath,
                teamName: name,
                leaderSessionId: leaderSessionId,
                workingDirectory: workingDirectory,
                agentWorkDir: agentWorkDir,
                worktreeName: wtName,
                worktreePath: wtPath,
                worktreeBranch: wtBranch,
                splitFrom: splitFrom,
                orientation: orientation,
                resumeSessionId: agentResumeSid,
                extraArgs: profileExtraArgs,
                extraEnv: profileExtraEnv,
                tabManager: tabManager
            ) else {
                if index == 0 {
                    Logger.team.error("failed to create first agent split pane")
                    return nil
                }
                Logger.team.error("failed to create split pane for agent '\(agent.name, privacy: .public)'")
                continue
            }
            members.append(member)
        }

        // In adopted mode, the default panel served as anchor but is no longer needed.
        if leaderMode == "adopted" {
            workspace.closePanel(defaultPanelId)
        }

        // Equalize splits multiple times: bonsplit needs layout passes to settle.
        // First pass immediate, then delayed passes for robustness.
        for delay in [0.05, 0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.equalizeAgentGrid(workspace: workspace)
            }
        }

        let team = Team(
            id: name,
            leaderSessionId: leaderSessionId,
            leaderMode: leaderMode,
            leaderModel: leaderModel,
            leaderPanelId: leaderPanelId,
            leaderWorkspaceId: leaderWorkspaceId,
            workingDirectory: workingDirectory,
            workspaceId: workspace.id,
            agents: members,
            createdAt: Date(),
            gitRepoRoot: gitRepoRoot,
            worktreeMode: worktreeMode,
            sharedWorktreeName: sharedWtName,
            sharedWorktreePath: sharedWtPath,
            sharedWorktreeBranch: sharedWtBranch
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
                workingDirectory: leaderWorkDir,
                socketPath: socketPath,
                scriptDir: scriptDir,
                worktreeMode: worktreeMode,
                sharedWorktreeBranch: sharedWtBranch,
                sharedWorktreePath: sharedWtPath
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
                    let msg = "Read the file \(promptFile) — it contains your team leader instructions with agent list and tm-agent commands. Follow those instructions for all team coordination."
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

        // Auto-warmup disabled: causes Enter swallowed + high CPU load with 10+ agents.
        // The 2s-staggered approach still floods the main queue with concurrent GCD dispatches.
        // Real tasks serve as implicit warmup — first-task latency is acceptable (~2-3s).
        // scheduleAutoWarmup(team: team, tabManager: tabManager)

        return team
    }

    // MARK: - Workspace-local Attach/Detach

    /// Errors returned by `attachToWorkspace`. Each case maps to a specific
    /// CLI-visible error code handled by the `team.attach` RPC layer.
    enum AttachError: Error, CustomStringConvertible {
        case workspaceNotFound
        case existingGuiTeam(name: String)       // non-ws- team already in this workspace (R7)
        case teamInOtherWorkspace(name: String)  // ws-<hex> exists but in a different workspace
        case agentNameConflict(name: String, team: String)
        case cliBinaryNotFound(cli: String)
        case paneCreationFailed

        var description: String {
            switch self {
            case .workspaceNotFound:
                return "workspace not found for the given workspace_id"
            case .existingGuiTeam(let name):
                return "Workspace already has an existing team '\(name)' created via tm-agent create. Destroy it first with tm-agent destroy."
            case .teamInOtherWorkspace(let name):
                return "team '\(name)' exists in a different workspace"
            case .agentNameConflict(let name, let team):
                return "Agent '\(name)' already exists in team '\(team)'. Use --name to specify a different name."
            case .cliBinaryNotFound(let cli):
                return "\(cli) binary not found"
            case .paneCreationFailed:
                return "failed to create agent pane"
            }
        }

        var code: String {
            switch self {
            case .workspaceNotFound: return "workspace_not_found"
            case .existingGuiTeam: return "existing_gui_team"
            case .teamInOtherWorkspace: return "team_in_other_workspace"
            case .agentNameConflict: return "agent_name_conflict"
            case .cliBinaryNotFound: return "cli_not_found"
            case .paneCreationFailed: return "pane_creation_failed"
            }
        }
    }

    /// Compute the auto team name for a workspace: `ws-<first8hex>` of its UUID.
    /// The same workspace always maps to the same team name, so multiple attach calls
    /// in the same workspace converge on a single team.
    static func workspaceTeamName(for workspaceId: UUID) -> String {
        let hex = workspaceId.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(8)
        return "ws-\(hex)"
    }

    /// Attach a single agent pane to an existing workspace. Creates a workspace-local
    /// team (`ws-<hex>`) on first call, reuses it on subsequent calls.
    ///
    /// On first attach, the caller's `callerPanelId` becomes the team's leader pane
    /// (leaderMode = "adopted") — no new workspace or leader pane is created.
    /// Subsequent attaches append agents to the same team, preserving the leader.
    ///
    /// Rejects if the workspace already hosts a non-`ws-` team created via `createTeam`
    /// (R7 — no mixing of workspace-local and create-based teams).
    ///
    /// Returns the updated Team and the newly-added AgentMember on success.
    func attachToWorkspace(
        workspaceId: UUID,
        callerPanelId: UUID,
        agentName: String,
        agentCli: String,
        agentModel: String,
        agentType: String,
        instructions: String,
        tabManager: TabManager
    ) -> Result<(team: Team, newAgent: AgentMember), AttachError> {
        // 1. Resolve workspace in the given TabManager
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return .failure(.workspaceNotFound)
        }

        // 2. Reject if a non-ws- team already lives in this workspace (R7)
        if let existingGui = teams.values.first(where: { $0.workspaceId == workspaceId && !$0.id.hasPrefix("ws-") }) {
            return .failure(.existingGuiTeam(name: existingGui.id))
        }

        // 3. Compute auto team name
        let teamName = Self.workspaceTeamName(for: workspaceId)

        // 4. Resolve or create the team
        let normalizedCli = agentCli.isEmpty ? "claude" : agentCli
        var team: Team
        if let existing = teams[teamName] {
            if existing.workspaceId != workspaceId {
                return .failure(.teamInOtherWorkspace(name: teamName))
            }
            // Agent name uniqueness within the existing team (R6)
            if existing.agents.contains(where: { $0.name == agentName }) {
                return .failure(.agentNameConflict(name: agentName, team: teamName))
            }
            team = existing
        } else {
            let workspaceDirectory = workspace.currentDirectory
            // First attach: register workspace-local team with caller pane as adopted leader
            team = Team(
                id: teamName,
                leaderSessionId: "leader-attach-\(UUID().uuidString.prefix(8))",
                leaderMode: "adopted",
                leaderModel: "sonnet",
                leaderPanelId: callerPanelId,
                leaderWorkspaceId: workspaceId,
                workingDirectory: workspaceDirectory,
                workspaceId: workspaceId,
                agents: [],
                createdAt: Date(),
                gitRepoRoot: nil,
                worktreeMode: "off",
                sharedWorktreeName: nil,
                sharedWorktreePath: nil,
                sharedWorktreeBranch: nil
            )
        }

        let effectiveInstructions = AgentRunbookService.shared.composeInstructions(
            roleName: agentType,
            presetInstructions: instructions,
            workingDirectory: team.workingDirectory,
            mode: .digest
        )

        // 5. Resolve CLI binary
        guard let cliPath = agentBinaryPath(cli: normalizedCli) else {
            return .failure(.cliBinaryNotFound(cli: normalizedCli))
        }

        // 6. Pick a color deterministically based on current agent count
        let colorList = ["green", "blue", "yellow", "magenta", "cyan", "red"]
        let agentColor = colorList[team.agents.count % colorList.count]

        // 7. Choose split target and orientation
        // - First agent: split RIGHT from the leader pane (horizontal) — consistent with createTeam layout
        // - Subsequent: split DOWN from the last existing agent (vertical) — stacks under prior agents
        let splitFrom: UUID
        let orientation: SplitOrientation
        if let lastAgent = team.agents.last, let lastPanel = lastAgent.panelId {
            splitFrom = lastPanel
            orientation = .vertical
        } else {
            splitFrom = team.leaderPanelId
            orientation = .horizontal
        }

        // 8. Delegate pane construction to the shared helper
        let attachProfile = CLIPathSettings.activeProfile(for: normalizedCli)
        let attachExtraArgs = attachProfile?.extraArgs ?? []
        let attachExtraEnv = attachProfile?.env ?? [:]
        let attachEffectiveModel = attachProfile?.modelOverride ?? agentModel
        guard let member = addAgentPaneToWorkspace(
            workspace: workspace,
            agentName: agentName,
            agentCli: normalizedCli,
            agentModel: attachEffectiveModel,
            agentType: agentType,
            agentColor: agentColor,
            agentInstructions: effectiveInstructions,
            cliPath: cliPath,
            teamName: teamName,
            leaderSessionId: team.leaderSessionId,
            workingDirectory: team.workingDirectory,
            agentWorkDir: team.workingDirectory,
            worktreeName: nil,
            worktreePath: nil,
            worktreeBranch: nil,
            splitFrom: splitFrom,
            orientation: orientation,
            extraArgs: attachExtraArgs,
            extraEnv: attachExtraEnv,
            tabManager: tabManager
        ) else {
            return .failure(.paneCreationFailed)
        }

        // 9. Commit updated team state
        team.agents.append(member)
        teams[teamName] = team
        TeamDataStore.shared.registerTeam(teamName, agentNames: team.agents.map(\.name))
        syncTeamStateToDaemon()
        Logger.team.info("attached agent '\(agentName, privacy: .public)' to team '\(teamName, privacy: .public)' (\(team.agents.count, privacy: .public) total)")

        return .success((team: team, newAgent: member))
    }

    /// Errors returned by `detachAgent`.
    enum DetachError: Error, CustomStringConvertible {
        case teamNotFound(name: String)
        case agentNotFound(name: String, available: [String])

        var description: String {
            switch self {
            case .teamNotFound(let name):
                return "No attach team '\(name)' found for this workspace. Run tm-agent attach <type> first."
            case .agentNotFound(let name, let available):
                let list = available.isEmpty ? "(none)" : available.joined(separator: ", ")
                return "Agent '\(name)' not found. Available: \(list)."
            }
        }

        var code: String {
            switch self {
            case .teamNotFound: return "team_not_found"
            case .agentNotFound: return "agent_not_found"
            }
        }
    }

    /// Result of a successful detach. `teamDestroyed == true` when the detached
    /// agent was the last in its team — in which case the team entry is removed
    /// but the adopted leader pane (caller's pane) is preserved.
    struct DetachResult {
        let teamName: String
        let agentName: String
        let remainingAgents: Int
        let teamDestroyed: Bool
    }

    /// Detach a single agent from a workspace-local team.
    /// Closes the agent's pane (idempotent — tolerates already-closed panes),
    /// removes it from `team.agents`, and destroys the team if it was the last
    /// agent. The adopted leader pane is never touched.
    func detachAgent(
        teamName: String,
        agentName: String,
        tabManager: TabManager,
        force: Bool = true
    ) -> Result<DetachResult, DetachError> {
        guard var team = teams[teamName] else {
            return .failure(.teamNotFound(name: teamName))
        }
        guard let agentIndex = team.agents.firstIndex(where: { $0.name == agentName }) else {
            return .failure(.agentNotFound(
                name: agentName,
                available: team.agents.map(\.name)
            ))
        }

        let agent = team.agents[agentIndex]

        // Close the pane if the workspace still exists.
        // `Workspace.closePanel` is idempotent — returns false if the panel
        // has already been closed (user-initiated or otherwise), which we
        // treat as successful detach.
        // TODO: when force=false, check daemon task state for agent_busy before closing
        if let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }),
           let pid = agent.panelId {
            _ = workspace.closePanel(pid, force: force)
        }

        // Remove from team.agents
        team.agents.remove(at: agentIndex)
        let remaining = team.agents.count

        if remaining == 0 {
            // Last agent — remove the team entry. The adopted leader pane is
            // the caller's own pane (external ownership) and must not be closed.
            teams.removeValue(forKey: teamName)
            TeamDataStore.shared.unregisterTeam(teamName)
            syncTeamStateToDaemon()
            Logger.team.info("detached last agent '\(agentName, privacy: .public)' from team '\(teamName, privacy: .public)' — team destroyed (leader pane preserved)")
            return .success(DetachResult(
                teamName: teamName,
                agentName: agentName,
                remainingAgents: 0,
                teamDestroyed: true
            ))
        } else {
            teams[teamName] = team
            TeamDataStore.shared.registerTeam(teamName, agentNames: team.agents.map(\.name))
            syncTeamStateToDaemon()
            Logger.team.info("detached agent '\(agentName, privacy: .public)' from team '\(teamName, privacy: .public)' (\(remaining, privacy: .public) remaining)")
            return .success(DetachResult(
                teamName: teamName,
                agentName: agentName,
                remainingAgents: remaining,
                teamDestroyed: false
            ))
        }
    }

    // MARK: - GUI Team Add Agent

    /// Errors returned by `addAgentToTeam`.
    enum AddAgentError: Error, CustomStringConvertible {
        case teamNotFound(name: String)
        case duplicateName(name: String, team: String)
        case workspaceGone(teamName: String)
        case cliBinaryNotFound(cli: String)
        case paneCreationFailed

        var description: String {
            switch self {
            case .teamNotFound(let name):
                return "Team '\(name)' not found."
            case .duplicateName(let name, let team):
                return "Agent '\(name)' already exists in team '\(team)'. Use a different --name."
            case .workspaceGone(let teamName):
                return "Team '\(teamName)' workspace no longer exists."
            case .cliBinaryNotFound(let cli):
                return "\(cli) binary not found"
            case .paneCreationFailed:
                return "Failed to create agent pane."
            }
        }

        var code: String {
            switch self {
            case .teamNotFound: return "team_not_found"
            case .duplicateName: return "duplicate_name"
            case .workspaceGone: return "workspace_gone"
            case .cliBinaryNotFound: return "cli_not_found"
            case .paneCreationFailed: return "pane_creation_failed"
            }
        }
    }

    /// Add a new agent pane to an existing GUI team (created via `createTeam`).
    ///
    /// Unlike `attachToWorkspace`, this:
    ///   - resolves the workspace from the stored team record (no caller surface_id), and
    ///   - bypasses the `existingGuiTeam` guard — it intentionally targets GUI teams.
    ///
    /// Used by the `team.add_agent` RPC, which is what `tm-agent add <role>` calls.
    func addAgentToTeam(
        teamName: String,
        agentType: String,
        agentName: String,
        agentModel: String,
        agentCli: String
    ) -> Result<AgentMember, AddAgentError> {
        // 1. Look up team by name
        guard var team = teams[teamName] else {
            return .failure(.teamNotFound(name: teamName))
        }

        // 2. Reject duplicate name within the team
        if team.agents.contains(where: { $0.name == agentName }) {
            return .failure(.duplicateName(name: agentName, team: teamName))
        }

        // 3. Resolve TabManager from team.workspaceId (no caller env required)
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId) else {
            return .failure(.workspaceGone(teamName: teamName))
        }

        // 4. Confirm workspace is still alive within that TabManager
        guard let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }) else {
            return .failure(.workspaceGone(teamName: teamName))
        }

        // 5. Normalize CLI and resolve binary path
        let normalizedCli = agentCli.isEmpty ? "claude" : agentCli
        guard let cliPath = agentBinaryPath(cli: normalizedCli) else {
            return .failure(.cliBinaryNotFound(cli: normalizedCli))
        }

        // 6. Compose runbook instructions for the role
        let effectiveInstructions = AgentRunbookService.shared.composeInstructions(
            roleName: agentType,
            presetInstructions: "",
            workingDirectory: team.workingDirectory,
            mode: .digest
        )

        // 7. Pick color deterministically from current agent count
        let colorList = ["green", "blue", "yellow", "magenta", "cyan", "red"]
        let agentColor = colorList[team.agents.count % colorList.count]

        // 8. Choose split target — last agent pane or leader pane
        let splitFrom: UUID
        let orientation: SplitOrientation
        if let lastAgent = team.agents.last, let lastPanel = lastAgent.panelId {
            splitFrom = lastPanel
            orientation = .vertical
        } else {
            splitFrom = team.leaderPanelId
            orientation = .horizontal
        }

        // 9. Apply active CLI profile overrides (extraArgs / env / modelOverride)
        let profile = CLIPathSettings.activeProfile(for: normalizedCli)
        let extraArgs = profile?.extraArgs ?? []
        let extraEnv = profile?.env ?? [:]
        let effectiveModel = profile?.modelOverride ?? agentModel

        // 10. Spawn the pane via shared helper
        guard let member = addAgentPaneToWorkspace(
            workspace: workspace,
            agentName: agentName,
            agentCli: normalizedCli,
            agentModel: effectiveModel,
            agentType: agentType,
            agentColor: agentColor,
            agentInstructions: effectiveInstructions,
            cliPath: cliPath,
            teamName: teamName,
            leaderSessionId: team.leaderSessionId,
            workingDirectory: team.workingDirectory,
            agentWorkDir: team.workingDirectory,
            worktreeName: nil,
            worktreePath: nil,
            worktreeBranch: nil,
            splitFrom: splitFrom,
            orientation: orientation,
            extraArgs: extraArgs,
            extraEnv: extraEnv,
            tabManager: tabManager
        ) else {
            return .failure(.paneCreationFailed)
        }

        // 11. Commit updated team state
        team.agents.append(member)
        teams[teamName] = team
        TeamDataStore.shared.registerTeam(teamName, agentNames: team.agents.map(\.name))
        syncTeamStateToDaemon()
        Logger.team.info("add_agent: added '\(agentName, privacy: .public)' to team '\(teamName, privacy: .public)' (\(team.agents.count, privacy: .public) total)")

        return .success(member)
    }

    /// Send a lightweight "pong" task to each agent after a delay, warming the Anthropic prompt cache.
    /// This reduces first-real-task latency from ~10s (cold) to ~1.2s (hot cache).
    /// Staggers agent warmups by 2s each to avoid flooding the GCD main queue with concurrent
    /// Enter keystrokes, which can cause TUI input drops (Enter swallowed) and failed deliveries.
    private func scheduleAutoWarmup(team: Team, tabManager: TabManager) {
        let warmupDelay: TimeInterval = 15.0
        let perAgentStagger: TimeInterval = 2.0  // 2s between each agent warmup
        let teamName = team.id
        let agentCount = team.agents.count

        for (index, agent) in team.agents.enumerated() {
            let agentDelay = warmupDelay + Double(index) * perAgentStagger
            let agentName = agent.name

            DispatchQueue.main.asyncAfter(deadline: .now() + agentDelay) { [weak self] in
                guard let self = self, self.teams[teamName] != nil else { return }

                let currentTabManager = self.resolveTabManager(teamName: teamName) ?? tabManager

                let result = self.delegateToAgent(
                    teamName: teamName,
                    agentName: agentName,
                    text: "Reply with exactly one word: pong",
                    taskTitle: "warmup-ping",
                    priority: 3,
                    tabManager: currentTabManager
                )
                let delivered = result?.textDelivered == true
                #if DEBUG
                dlog("[team] auto-warmup \(delivered ? "sent" : "FAILED") to \(agentName) in team '\(teamName)' (delay=\(agentDelay)s)")
                #endif

                // Log summary after last agent
                if index == agentCount - 1 {
                    Logger.team.info("auto-warmup: dispatched \(agentCount) agent(s) in team '\(teamName, privacy: .public)' (staggered \(perAgentStagger)s each)")
                }
            }
        }
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
        for projectDir in ["term-mesh-term-mesh", "project/term-mesh", "project/term-mesh"] {
            let projectPath = "\(home)/work/\(projectDir)/scripts/\(filename)"
            if FileManager.default.fileExists(atPath: projectPath) { return projectPath }
        }
        return nil
    }

    /// Find the scripts/ directory (for leader prompts).
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
        for projectDir in ["term-mesh-term-mesh", "project/term-mesh", "project/term-mesh"] {
            let projectPath = "\(home)/work/\(projectDir)/scripts"
            if FileManager.default.fileExists(atPath: projectPath) { return projectPath }
        }
        return "\(workingDirectory)/scripts"  // fallback to working directory
    }

    /// Extract a one-line routing summary from agent instructions.
    ///
    /// New format: first line IS the routing summary (e.g., "Codebase navigator — send file lookups...").
    /// Legacy format: "You are a X. Your job is to:" — strips boilerplate to extract the role noun.
    private static func oneLinerFromInstructions(_ instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let firstLine = (trimmed.components(separatedBy: .newlines).first ?? trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // New format: first line is already a routing summary (no "You are" prefix)
        if !firstLine.hasPrefix("You are") {
            return String(firstLine.prefix(120))
        }
        // Legacy fallback: strip boilerplate from "You are a X. Your job is to:" pattern
        let cleaned = firstLine
            .replacingOccurrences(of: "Your job is to:", with: "")
            .replacingOccurrences(of: "You are a ", with: "")
            .replacingOccurrences(of: "You are an ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(120))
    }

    private static func runbookLeaderSection(workingDirectory: String, roles: [String]) -> String {
        let normalizedRoles = Array(Set(roles.map(AgentRunbookService.normalizeRoleName))).sorted()
        let status = AgentRunbookService.shared.status(workingDirectory: workingDirectory, roles: normalizedRoles)
        let lines = status.roles.map { roleStatus in
            "  - \(roleStatus.role): \(roleStatus.sourceState.rawValue)"
        }.joined(separator: "\n")
        let available = status.roles.filter { $0.sourceState != .missing }.map(\.role)
        let availability = available.isEmpty
            ? "No repo-local source runbooks are present; agents fall back to role preset instructions."
            : "Repo-local runbooks are present for: \(available.joined(separator: ", "))."

        return """
        ## Agent Runbooks

        Source of truth: `.agent-runbooks/<role>.md` in \(status.projectRoot).
        Precedence: base term-mesh protocol -> role preset -> repo runbook -> per-team custom instructions.
        \(availability)

        Current source status:
        \(lines.isEmpty ? "  - none" : lines)

        Useful commands:
        ```
        tm-agent runbook status
        tm-agent runbook install --tool all
        ```
        """
    }

    /// Build system prompt for Claude leader (launched directly, no shell script wrapper).
    private static func buildLeaderClaudeSystemPrompt(
        teamName: String,
        agentList: String,
        runbookSection: String,
        tmAgent: String,
        socketPath: String
    ) -> String {
        return """
        You are the TEAM LEADER for team '\(teamName)'. You direct a group of Claude agent workers running in terminal split panes.

        ## DELEGATE-FIRST PRINCIPLE (CRITICAL)

        You are a COORDINATOR, not a worker. Your agents are your hands and eyes.

        **MANDATORY:** For ANY substantive work — reading code, exploring the codebase, analyzing architecture,
        writing code, debugging, reviewing — you MUST delegate to an appropriate agent.

        **NEVER do these yourself:**
        - Read or grep source files (delegate to an explorer/researcher agent)
        - Analyze architecture or design (delegate to an architect agent)
        - Write or modify code (delegate to an executor/implementer agent)
        - Debug or investigate issues (delegate to a debugger agent)
        - Review code quality (delegate to a reviewer agent)

        **You may do these yourself:**
        - Run `\(tmAgent)` commands (status, delegate, read, wait, inbox, task)
        - Synthesize and summarize agent results for the user
        - Break down tasks and create task plans
        - Coordinate dependencies between agents

        **When in doubt, DELEGATE.** An idle agent is a wasted resource.

        ## TOOL RESTRICTIONS (CRITICAL)

        You MUST use `\(tmAgent)` for ALL team operations. The following Claude Code built-in tools create a parallel, disconnected team state and MUST NEVER be used:

        **BANNED:** Agent (spawns disconnected subprocesses), TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskList, TaskGet, TaskUpdate

        If you catch yourself about to use the Agent tool — STOP and use `\(tmAgent) delegate` instead.

        ## Your Agents
        \(agentList)

        Match each task to the agent whose specialty fits best.
        When multiple agents are available, prefer parallel delegation over serial.
        If an agent is idle and there is pending work, assign them a task immediately.

        \(runbookSection)

        ## How to Command Agents

        Create a task and delegate it to a specific agent (PREFERRED — creates trackable task):
        ```
        \(tmAgent) delegate <agent_name> '<your instruction>'
        ```

        Send a raw direct message (lightweight, for follow-ups or clarifications):
        ```
        \(tmAgent) send <agent_name> '<your instruction>'
        ```

        Broadcast to all agents:
        ```
        \(tmAgent) broadcast '<your instruction>'
        ```

        Check team status / inbox:
        ```
        \(tmAgent) status
        \(tmAgent) inbox
        ```

        ## Writing Good Delegation Instructions

        A good delegation includes:
        - WHAT: clear description of the task
        - WHERE: specific file paths or directories to look at
        - HOW MUCH: scope boundaries (what NOT to touch)
        - OUTPUT: what format the result should be in

        Good: `\(tmAgent) delegate explorer 'Find all socket command handlers in TerminalController.swift. Search for case patterns in the RPC dispatch switch. Report: method name, line number, and threading (MainActor or off-main). Focus only on TerminalController.swift.'`

        Bad: `\(tmAgent) delegate explorer 'look at the socket stuff'`

        ## Reading Agent Results (MANDATORY)

        After delegating tasks, you MUST collect results before responding to the user.
        NEVER answer using only your own analysis when agents were delegated.

        ```
        \(tmAgent) read <agent_name> --lines 100
        \(tmAgent) collect --lines 100
        \(tmAgent) wait --timeout 120
        \(tmAgent) wait --mode blocked --timeout 120
        \(tmAgent) wait --mode review_ready --timeout 120
        \(tmAgent) wait --mode report --timeout 120
        ```

        ## Message Channel
        ```
        \(tmAgent) msg list
        \(tmAgent) msg list --from-agent <agent_name>
        ```

        ## Task Board
        ```
        \(tmAgent) task create '<title>' --assign <agent_name> --priority 2
        \(tmAgent) task list
        \(tmAgent) task get <id>
        \(tmAgent) task start <id>
        \(tmAgent) task block <id> '<reason>'
        \(tmAgent) task review <id> '<summary>'
        \(tmAgent) task done <id> '<result>'
        ```

        ## Your Workflow

        For EVERY user message, execute these steps IN ORDER:

        1. `\(tmAgent) status` — check which agents are idle
        2. Decompose the request into 1-3 concrete subtasks
        3. Delegate IMMEDIATELY to idle agents — do NOT analyze the problem yourself first
        4. `\(tmAgent) wait --timeout 120 --mode report` — wait for results
        5. `\(tmAgent) read <agent> --lines 100` — read each agent's output
        6. Synthesize results and respond to the user

        **CRITICAL:** Step 3 must happen BEFORE you read any source files or form your own analysis. Your job is to write good delegation instructions, not to do the work.

        **Anti-patterns to AVOID:**
        - Answering a question by reading files yourself when an explorer agent exists
        - Providing architecture advice yourself when an architect agent exists
        - Saying "I'll look into this" without delegating to an agent
        - Waiting for one agent to finish before starting another independent task
        - Responding to the user before collecting agent results

        ## Keeping Agents Busy

        **Parallel:** tasks that don't need each other's output
        - Example: explorer searches for X while architect reads existing design docs

        **Serial:** task B needs task A's result as input
        - Example: architect designs API → THEN executor implements it

        **Always parallel when possible.** After each delegation round, check `\(tmAgent) status` — if any agent is idle and there is remaining work, delegate to them immediately.

        ## Error Recovery

        - Agent not responding: `\(tmAgent) read <agent> --lines 50` then `\(tmAgent) send <agent> 'status?'`
        - Agent stuck/blocked: `\(tmAgent) task reassign <id> <other_agent>`
        - Need to stop all: `\(tmAgent) broadcast 'STOP'`
        - Results truncated: full reports at `~/.term-mesh/results/\(teamName)/<agent>-reply.md`

        ## Example Workflow

        User: "IME 입력창에서 방향키가 동작하지 않는 버그를 고쳐줘"

        Step 1: `\(tmAgent) status` → explorer idle, executor idle, tester idle
        Step 2: Decompose → (a) 원인 조사, (b) 수정 구현, (c) 테스트
        Step 3: Parallel delegation:
          `\(tmAgent) delegate explorer 'Sources/에서 IME 키 이벤트 처리를 찾아라. performKeyEquivalent, keyDown, flagsChanged에서 방향키 처리. NSEvent.keyCode 123-126 관련 코드 보고.'`
          `\(tmAgent) delegate architect 'IME markedText 상태에서 방향키 이벤트의 올바른 처리 흐름 분석. NSTextInputClient 관점에서 정리.'`
        Step 4: `\(tmAgent) wait --timeout 120 --mode report`
        Step 5: Read results → delegate executor with fix instructions
        Step 6: After fix → delegate tester to verify

        Environment: TERMMESH_SOCKET=\(socketPath)
        """
    }

    /// Build team leader instructions for non-Claude CLI leaders (kiro, codex, gemini).
    /// These CLIs lack a --system-prompt flag, so we inject instructions as the first message.
    private func buildTeamLeaderPrompt(
        teamName: String,
        agents: [AgentMember],
        workingDirectory: String,
        socketPath: String,
        scriptDir: String,
        worktreeMode: String = "off",
        sharedWorktreeBranch: String? = nil,
        sharedWorktreePath: String? = nil
    ) -> String {
        let agentList = agents.enumerated().map { i, a in
            let summary = Self.oneLinerFromInstructions(a.instructions)
            return summary.isEmpty
                ? "  \(i + 1). \(a.name) (\(a.agentType))"
                : "  \(i + 1). \(a.name) (\(a.agentType)) — \(summary)"
        }.joined(separator: "\n")

        let tmAgent = "tm-agent"
        let runbookSection = Self.runbookLeaderSection(
            workingDirectory: workingDirectory,
            roles: agents.map(\.agentType)
        )

        // Worktree info
        let worktreeSection: String
        if worktreeMode == "shared", let branch = sharedWorktreeBranch, let path = sharedWorktreePath {
            worktreeSection = """

            ## Worktree Isolation (SHARED)
            All agents share a single worktree branch: '\(branch)' at '\(path)'.
            Agents should coordinate commits to avoid conflicts.
            When work is complete: git add -A && git commit && git push && gh pr create
            """
        } else if worktreeMode == "isolated" {
            let worktreeAgents = agents.filter { $0.worktreeBranch != nil }
            if !worktreeAgents.isEmpty {
                let wtList = worktreeAgents.map { a in
                    "  - \(a.name): branch='\(a.worktreeBranch ?? "?")' path='\(a.worktreePath ?? "?")'"
                }.joined(separator: "\n")
                worktreeSection = """

                ## Worktree Isolation (ISOLATED)
                Each agent works in its own isolated git worktree.
                \(wtList)
                When agents complete work, instruct them to: git add -A && git commit && git push && gh pr create
                """
            } else {
                worktreeSection = ""
            }
        } else {
            worktreeSection = ""
        }

        return """
        You are the TEAM LEADER for team '\(teamName)'. You direct agent workers running in terminal split panes.

        ## DELEGATE-FIRST PRINCIPLE (CRITICAL)

        You are a COORDINATOR, not a worker. Your agents are your hands and eyes.

        **MANDATORY:** For ANY substantive work — reading code, exploring the codebase, analyzing architecture,
        writing code, debugging, reviewing — you MUST delegate to an appropriate agent.

        **NEVER do these yourself:**
        - Read or grep source files (delegate to an explorer/researcher agent)
        - Analyze architecture or design (delegate to an architect agent)
        - Write or modify code (delegate to an executor/implementer agent)
        - Debug or investigate issues (delegate to a debugger agent)
        - Review code quality (delegate to a reviewer agent)

        **You may do these yourself:**
        - Run `\(tmAgent)` commands (status, delegate, read, wait, inbox, task)
        - Synthesize and summarize agent results for the user
        - Break down tasks and create task plans
        - Coordinate dependencies between agents

        **When in doubt, DELEGATE.** An idle agent is a wasted resource.

        ## Your Agents
        \(agentList)

        Match each task to the agent whose specialty fits best.
        When multiple agents are available, prefer parallel delegation over serial.
        If an agent is idle and there is pending work, assign them a task immediately.

        \(runbookSection)

        ## How to Command Agents

        Create a task and delegate it to a specific agent (PREFERRED — creates trackable task):
        ```
        \(tmAgent) delegate <agent_name> '<your instruction>'
        ```

        Send a raw direct message (lightweight, for follow-ups or clarifications):
        ```
        \(tmAgent) send <agent_name> '<your instruction>'
        ```

        Broadcast to all agents:
        ```
        \(tmAgent) broadcast '<your instruction>'
        ```

        Check team status / inbox:
        ```
        \(tmAgent) status
        \(tmAgent) inbox
        ```

        ## Reading Agent Results (MANDATORY)

        After delegating tasks, you MUST collect results before responding to the user.
        NEVER answer using only your own analysis when agents were delegated.

        ```
        \(tmAgent) read <agent_name> --lines 100
        \(tmAgent) collect --lines 100
        \(tmAgent) wait --timeout 120
        \(tmAgent) wait --mode blocked --timeout 120
        \(tmAgent) wait --mode review_ready --timeout 120
        ```

        ## Message Channel
        ```
        \(tmAgent) msg list
        \(tmAgent) msg list --from-agent <agent_name>
        ```

        ## Task Board
        ```
        \(tmAgent) task create '<title>' --assign <agent_name> --priority 2
        \(tmAgent) task list
        \(tmAgent) task get <id>
        \(tmAgent) task start <id>
        \(tmAgent) task block <id> '<reason>'
        \(tmAgent) task review <id> '<summary>'
        \(tmAgent) task done <id> '<result>'
        ```
        \(worktreeSection)

        ## Your Workflow

        For EVERY user request, follow this pattern:

        1. **Decompose** — Break the request into concrete subtasks
        2. **Route** — Match each subtask to the best-fit agent by specialty
        3. **Delegate** — Send tasks to agents in parallel when independent
        4. **Monitor** — Use `wait`/`inbox`/`read` to track progress; unblock stuck agents
        5. **Synthesize** — Collect all results and present a unified answer to the user

        **Anti-patterns to AVOID:**
        - Answering a question by reading files yourself when an explorer agent exists
        - Providing architecture advice yourself when an architect agent exists
        - Saying "I'll look into this" without delegating to an agent
        - Waiting for one agent to finish before starting another independent task
        - Responding to the user before collecting agent results

        ## Keeping Agents Busy

        After each user message, check: are any agents idle? If yes and there is work to do, delegate to them.
        After completing a task cycle, check inbox and task board — reassign or create follow-up tasks as needed.
        Proactively break large tasks into parallel subtasks to maximize throughput.

        Environment: TERMMESH_SOCKET=\(socketPath)
        """
    }

    /// Pick one agent by name using round-robin across duplicates.
    /// Thread-safety: must be called on the main actor (mutates agentSendRoundRobin).
    private func selectAgent(in agents: [AgentMember], name: String) -> AgentMember? {
        let candidates = agents.filter { $0.name == name }
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0] }
        let key = "\(candidates[0].teamName)/\(name)"
        let idx = (agentSendRoundRobin[key] ?? 0) % candidates.count
        agentSendRoundRobin[key] = idx + 1
        return candidates[idx]
    }

    /// Send text to a specific agent in a team.
    /// When multiple agents share the same name, round-robins across them.
    /// Maintains an in-flight counter and a panelId snapshot so a concurrent
    /// hard restart can either drain (preferred) or detect mid-flight migration.
    func sendToAgent(teamName: String, agentName: String, text: String, tabManager: TabManager, withReturn: Bool = true, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard let team = teams[teamName] else {
            #if DEBUG
            dlog("[team.sendToAgent] DROP reason=team_not_found team=\(teamName) agent=\(agentName)")
            #endif
            completion?(false); return false
        }
        guard let agent = selectAgent(in: team.agents, name: agentName) else {
            #if DEBUG
            dlog("[team.sendToAgent] DROP reason=agent_not_found team=\(teamName) agent=\(agentName) agentCount=\(team.agents.count)")
            #endif
            completion?(false); return false
        }
        let teamAgentKey = "\(teamName)/\(agentName)"
        if migratingAgents.contains(teamAgentKey) {
            #if DEBUG
            dlog("[team.sendToAgent] aborted reason=migration_in_flight team=\(teamName) agent=\(agentName)")
            #endif
            completion?(false)
            return false
        }
        guard let pid = agent.panelId else {
            #if DEBUG
            dlog("[team.sendToAgent] DROP reason=panelId_nil team=\(teamName) agent=\(agentName) workspaceId=\(agent.workspaceId.uuidString.prefix(8))")
            #endif
            completion?(false); return false
        }
        #if DEBUG
        dlog("[team.sendToAgent] enter team=\(teamName) agent=\(agentName) panelId=\(pid.uuidString.prefix(8)) withReturn=\(withReturn) textLen=\(text.count)")
        #endif
        activeSends[teamAgentKey, default: 0] += 1
        return sendTextToPanel(
            workspaceId: agent.workspaceId,
            panelId: pid,
            text: text,
            tabManager: tabManager,
            withReturn: withReturn
        ) { [weak self] sent in
            if let self = self {
                let remaining = (self.activeSends[teamAgentKey] ?? 0) - 1
                if remaining <= 0 {
                    self.activeSends.removeValue(forKey: teamAgentKey)
                } else {
                    self.activeSends[teamAgentKey] = remaining
                }
            }
            completion?(sent)
        }
    }

    /// Send text to an agent by its unique panelId (skips name lookup entirely).
    /// Used by broadcast and asyncTeamBroadcast to avoid duplicate-name collapse.
    @discardableResult
    func sendToAgentByPanel(teamName: String, panelId: UUID, workspaceId: UUID, text: String, tabManager: TabManager, withReturn: Bool = true) -> Bool {
        return sendTextToPanel(workspaceId: workspaceId, panelId: panelId, text: text, tabManager: tabManager, withReturn: withReturn)
    }

    /// Send text to an agent without requiring a tabManager.
    /// Uses AppDelegate.locateSurface to find the agent's panel across all windows.
    /// Must be called on the main thread.
    @discardableResult
    func sendToAgentAutoLocate(teamName: String, agentName: String, text: String) -> Bool {
        guard let team = teams[teamName],
              let agent = selectAgent(in: team.agents, name: agentName),
              let pid = agent.panelId,
              let located = AppDelegate.shared?.locateSurface(surfaceId: pid) else { return false }
        return sendTextToPanel(workspaceId: agent.workspaceId, panelId: pid, text: text, tabManager: located.tabManager)
    }

    func sendToLeader(teamName: String, text: String, tabManager: TabManager) -> Bool {
        guard let team = teams[teamName] else { return false }
        // Adopted mode: leader lives in a different workspace than the agent workspace.
        // Use AppDelegate to locate the leader panel across all windows.
        if let leaderWsId = team.leaderWorkspaceId {
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: team.leaderPanelId) else { return false }
            return sendTextToPanel(workspaceId: leaderWsId, panelId: team.leaderPanelId, text: text, tabManager: located.tabManager)
        }
        return sendTextToPanel(workspaceId: team.workspaceId, panelId: team.leaderPanelId, text: text, tabManager: tabManager)
    }

    @discardableResult
    func notifyTaskCreated(teamName: String, taskId: String, tabManager: TabManager) -> Bool {
        guard let task = getTask(teamName: teamName, taskId: taskId) else { return false }
        return notifyTaskCreated(teamName: teamName, task: task, tabManager: tabManager)
    }

    /// Overload that accepts a pre-fetched task — avoids re-reading taskBoards
    /// (used by claim paths where the task lives in TeamDataStore, not taskBoards).
    @discardableResult
    func notifyTaskCreated(teamName: String, task: TeamTask, tabManager: TabManager) -> Bool {
        // Skip leader stdin injection — leader gets notifications via tm-agent wait/inbox
        Logger.team.info("[notifyTaskCreated] task=\(task.id.prefix(8), privacy: .public)")
        #if DEBUG
        dlog("[team.notifyTaskCreated] task=\(task.id.prefix(8)) — suppressed leader stdin injection")
        #endif
        guard let assignee = task.assignee?.nilIfBlank else { return true }
        let assigneeNotice = formatTaskAssignmentInstruction(task: task)
        return sendToAgent(teamName: teamName, agentName: assignee, text: assigneeNotice, tabManager: tabManager)
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
        // Do NOT inject notification into leader stdin — it pollutes the prompt.
        // Leader receives notifications via tm-agent wait/inbox (daemon push).
        Logger.team.info("[notifyTask] \(event, privacy: .public) task=\(task.id.prefix(8), privacy: .public) assignee=\(task.assignee ?? "none", privacy: .public)")
        #if DEBUG
        dlog("[team.notifyTask] \(event) task=\(task.id.prefix(8)) — suppressed leader stdin injection")
        #endif
        return true
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
        // Skip leader stdin injection — leader gets notifications via tm-agent wait/inbox
        let event = dispatched ? "started" : "start_failed"
        Logger.team.info("[dispatchTask] \(event, privacy: .public) task=\(task.id.prefix(8), privacy: .public) assignee=\(assignee, privacy: .public)")
        #if DEBUG
        dlog("[team.dispatchTask] \(event) task=\(task.id.prefix(8)) assignee=\(assignee) — suppressed leader stdin injection")
        #endif
        return dispatched
    }

    /// Result of a delegate operation, containing both the task and delivery status.
    struct DelegateResult {
        let task: TeamTask
        let textDelivered: Bool
        /// Pre-formatted instruction text for retry (avoids re-calling private formatter).
        let instruction: String
    }

    /// Unified delegate: atomically create a task in TeamDataStore and dispatch the
    /// formatted instruction to the agent. Mirrors the `tm-agent delegate` two-step
    /// logic (team.task.create + team.send) in a single atomic call.
    /// Must be called on the main thread (sendToAgent requires MainActor).
    @discardableResult
    func delegateToAgent(
        teamName: String,
        agentName: String,
        text: String,
        taskTitle: String? = nil,
        priority: Int? = nil,
        context: String? = nil,
        tabManager: TabManager,
        submit: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) -> DelegateResult? {
        let title = taskTitle?.nilIfBlank ?? String(text.prefix(80))
        guard let task = TeamDataStore.shared.createTask(
            teamName: teamName,
            title: title,
            assignee: agentName,
            priority: priority ?? 2
        ) else { return nil }
        let instruction = formatDelegateInstruction(task: task, text: text, context: context)
        // CLI callers keep submit=false and send Return separately after paste ack.
        // GUI callers can submit=true to use the IME paste path's inline Return.
        let delivered = sendToAgent(
            teamName: teamName,
            agentName: agentName,
            text: instruction,
            tabManager: tabManager,
            withReturn: submit,
            completion: completion
        )
        return DelegateResult(task: task, textDelivered: delivered, instruction: instruction)
    }

    private func formatDelegateInstruction(task: TeamTask, text: String, context: String? = nil) -> String {
        let taskId = task.id
        var lines: [String] = [
            "## Task Capsule",
            "TASK_ID: \(taskId)",
            "TASK_TITLE: \(task.title)",
            "TASK_STATUS: \(task.status)",
            "TASK_PRIORITY: \(task.priority)",
            "PROTOCOL: TM-PROTOCOL-v1",
            "OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus concise summary",
        ]
        if let ctx = context, !ctx.isEmpty {
            let truncated = String(ctx.prefix(500))
            lines.append("")
            lines.append("[CONTEXT_SUMMARY]")
            lines.append(truncated)
            lines.append("[/CONTEXT_SUMMARY]")
        }
        lines.append(contentsOf: [
            "",
            "[GOAL]",
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            "[/GOAL]",
        ])
        let body = lines.joined(separator: "\n")
        return body + "\n\n[IMPORTANT] Finish via TM-PROTOCOL-v1: tm-agent reply '<5-line header plus concise summary>'."
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
        lines.append("- tm-agent task start \(task.id)")
        lines.append("- tm-agent task block \(task.id) '<reason>'")
        lines.append("- tm-agent task review \(task.id) '<summary>'")
        lines.append("- tm-agent reply '<5-line header plus result>'")
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
        lines.append("tm-agent task start \(task.id)")
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

    /// Exponential backoff delays (ms) for surface-nil retry in sendTextToPanel.
    /// 4 attempts: 50 → 150 → 400 → 800 ms (total ~1.4 s before final failure).
    private static let sendTextRetryDelaysMs: [Double] = [50, 150, 400, 800]

    private func sendTextToPanel(workspaceId: UUID, panelId: UUID, text: String, tabManager: TabManager, withReturn: Bool = true, retryCount: Int = 0, completion: ((Bool) -> Void)? = nil) -> Bool {
        // Try the provided tabManager first, then fall back to global surface lookup
        // for cross-window scenarios (e.g. broadcast when agents are in a different window).
        let panel: TerminalPanel
        if let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
           let p = workspace.terminalPanel(for: panelId) {
            panel = p
        } else if let located = AppDelegate.shared?.locateSurface(surfaceId: panelId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let p = workspace.terminalPanel(for: panelId) {
            panel = p
        } else {
            #if DEBUG
            // Detailed failure logging to diagnose text_delivered:false
            let wsFound = tabManager.tabs.first(where: { $0.id == workspaceId })
            let panelFound = wsFound?.panels[panelId]
            let locateResult = AppDelegate.shared?.locateSurface(surfaceId: panelId)
            dlog("[team.sendTextToPanel.FAIL] panelId=\(panelId.uuidString.prefix(8)) wsId=\(workspaceId.uuidString.prefix(8)) wsFound=\(wsFound != nil) panelInWs=\(panelFound != nil) globalLocate=\(locateResult != nil) tabCount=\(tabManager.tabs.count) ctxCount=\(AppDelegate.shared?.mainWindowContexts.count ?? 0) retryCount=\(retryCount)")
            #endif
            Logger.team.warning("[sendTextToPanel] panel \(panelId.uuidString.prefix(8), privacy: .public) not found (attempt \(retryCount + 1))")

            // Retry after 0.5s if this is the first failure
            // Panel may exist but not yet visible in workspace list after fast splits
            if retryCount < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    _ = self?.sendTextToPanel(
                        workspaceId: workspaceId, panelId: panelId, text: text,
                        tabManager: tabManager, withReturn: withReturn, retryCount: retryCount + 1,
                        completion: completion
                    )
                }
            } else {
                completion?(false)
            }
            return false
        }
        let trimmed = text.replacingOccurrences(of: "[\\r\\n]+$", with: "", options: .regularExpression)
        if trimmed.isEmpty {
            // Text was pure whitespace/newlines — still send Return so the agent receives the
            // Enter keystroke that the caller intended (e.g. bare newline commands).
#if DEBUG
            dlog("[team.sendTextToPanel] text empty after trim, sending Return key only panelId=\(panelId.uuidString.prefix(8))")
#endif
            let sent = panel.surface.sendIMEText("", withReturn: true)
            completion?(sent)
            return sent
        }

        // Surface readiness check — if the underlying ghostty surface is nil,
        // sendIMEText will silently drop the text+Enter. Detect this early and
        // retry with exponential backoff (50 → 150 → 400 → 800 ms, 4 attempts).
        // Note: TerminalSurface.sendIMEText has no async retry of its own; retries
        // are managed exclusively here to prevent duplicate delivery.
        guard panel.surface.surface != nil else {
            let delays = Self.sendTextRetryDelaysMs
            #if DEBUG
            if retryCount < delays.count {
                dlog("[team.sendTextToPanel] surface nil, retry \(retryCount + 1)/\(delays.count) after \(Int(delays[retryCount]))ms panelId=\(panelId.uuidString.prefix(5))")
            } else {
                dlog("[team.sendTextToPanel] FAIL: surface nil after \(delays.count) retries, text+Enter dropped: \(text.prefix(50))")
            }
            #endif
            Logger.team.warning("[sendTextToPanel] surface nil for panel \(panelId.uuidString.prefix(8), privacy: .public) (attempt \(retryCount + 1))")
            if retryCount < delays.count {
                let delayMs = delays[retryCount]
                DispatchQueue.main.asyncAfter(deadline: .now() + delayMs / 1000.0) { [weak self] in
                    _ = self?.sendTextToPanel(
                        workspaceId: workspaceId, panelId: panelId, text: text,
                        tabManager: tabManager, withReturn: withReturn, retryCount: retryCount + 1,
                        completion: completion
                    )
                }
            } else {
                completion?(false)
            }
            return false
        }

        // Normalize and send text via sendIMEText.
        // Note: when withReturn=false (team.delegate), only text is pasted — the Rust
        // CLI sends Return separately via team.send_key RPC using the reliable
        // sendNamedKey path. When withReturn=true (team.send, broadcast), Return is
        // delivered inline via sendIMEText.
        let normalized = trimmed
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if let completion {
            // Ack-based path: sendIMETextResult fires completion when paste drains.
            // Dispatch async so completion always fires after delegateToAgent returns,
            // ensuring capturedDelegateResult is set before the caller reads it.
            panel.surface.sendIMETextResult(normalized, withReturn: withReturn) { result in
                let ok: Bool
                switch result {
                case .success:
                    ok = true
                case .failure(let error):
                    ok = false
                    #if DEBUG
                    let reason: String
                    switch error {
                    case .queueOverflow:
                        reason = "queue_overflow"
                    case .surfaceUnavailable:
                        reason = "surface_unavailable"
                    case .returnRetryExhausted:
                        reason = "watchdog"
                    }
                    dlog("text.delivered.false reason=\(reason) panelId=\(panelId.uuidString.prefix(8)) textLen=\(normalized.count) withReturn=\(withReturn)")
                    #endif
                }
                DispatchQueue.main.async { completion(ok) }
            }
            #if DEBUG
            dlog("[team.sendTextToPanel] sendIMETextResult (ack) panelId=\(panelId.uuidString.prefix(8)) textLen=\(normalized.count) withReturn=\(withReturn) text=\(normalized.prefix(80).debugDescription)")
            #endif
            return true
        }
        let sent = panel.surface.sendIMEText(normalized, withReturn: withReturn)
        #if DEBUG
        dlog("[team.sendTextToPanel] sendIMEText panelId=\(panelId.uuidString.prefix(8)) textLen=\(normalized.count) withReturn=\(withReturn) sent=\(sent) text=\(normalized.prefix(80).debugDescription)")
        #endif
        return sent
    }

    /// Broadcast text to all agents in a team.
    /// Iterates by panelId (not name) so every agent pane receives the message,
    /// including multiple agents that share the same name.
    func broadcast(teamName: String, text: String, tabManager: TabManager) -> Int {
        guard let team = teams[teamName] else { return 0 }
        var count = 0
        for agent in team.agents {
            guard let pid = agent.panelId else { continue }
            if sendTextToPanel(workspaceId: agent.workspaceId, panelId: pid, text: text, tabManager: tabManager) {
                count += 1
            }
        }
        return count
    }

    /// Send Ctrl+C (ETX) to a specific agent's terminal, interrupting the current operation.
    /// Unlike sendToAgent which types text into the prompt, this sends a raw interrupt signal
    /// that works even when the agent is busy (thinking/running tools).
    func interruptAgent(teamName: String, agentName: String, tabManager: TabManager) -> Bool {
        guard let team = teams[teamName],
              let agent = team.agents.first(where: { $0.name == agentName }) else { return false }
        guard let panel = agentPanel(teamName: teamName, agentName: agentName, tabManager: tabManager) else { return false }
        // Send ETX byte (0x03 = Ctrl+C) directly to PTY — bypasses TUI input handling
        panel.sendText("\u{03}")
        #if DEBUG
        dlog("[team.interrupt] sent ETX to agent '\(agentName)' in team '\(teamName)'")
        #endif
        return true
    }

    /// Send Ctrl+C (ETX) to ALL agents in a team, interrupting all running operations.
    func interruptAll(teamName: String, tabManager: TabManager) -> Int {
        guard let team = teams[teamName] else { return 0 }
        var count = 0
        for agent in team.agents {
            if interruptAgent(teamName: teamName, agentName: agent.name, tabManager: tabManager) {
                count += 1
            }
        }
        #if DEBUG
        dlog("[team.interrupt_all] interrupted \(count)/\(team.agents.count) agents in team '\(teamName)'")
        #endif
        return count
    }

    /// Send Ctrl+C (ETX) to ALL agents across ALL teams.
    func interruptAllTeams(tabManager: TabManager) -> Int {
        var total = 0
        for teamName in teams.keys {
            total += interruptAll(teamName: teamName, tabManager: tabManager)
        }
        return total
    }

    func agentIdentity(teamName: String, agentName: String) -> AgentPaneIdentity? {
        guard let team = teams[teamName],
              let agent = team.agents.first(where: { $0.name == agentName }) else { return nil }
        return agentIdentity(for: agent)
    }

    func agentIdentity(forPanelId panelId: UUID) -> AgentPaneIdentity? {
        for team in teams.values {
            if let agent = team.agents.first(where: { $0.panelId == panelId }) {
                if let identity = agentIdentity(for: agent) { return identity }
            }
        }
        return nil
    }

    func teamName(containingPanelId panelId: UUID, workspaceId: UUID? = nil) -> String? {
        for team in teams.values {
            if team.leaderPanelId == panelId {
                return team.id
            }
            if team.agents.contains(where: { $0.panelId == panelId }) {
                return team.id
            }
        }
        if let workspaceId {
            let candidates = teams.values.filter {
                $0.workspaceId == workspaceId || $0.leaderWorkspaceId == workspaceId
            }
            if candidates.count == 1 {
                return candidates[0].id
            }
        }
        return nil
    }

    func agentMentionTargets(containingPanelId panelId: UUID, workspaceId: UUID? = nil) -> [AgentMentionTarget] {
        guard let teamName = teamName(containingPanelId: panelId, workspaceId: workspaceId),
              let team = teams[teamName] else { return [] }
        return team.agents.map {
            AgentMentionTarget(
                teamName: team.id,
                name: $0.name,
                cli: $0.cli,
                model: $0.model,
                agentType: $0.agentType,
                workspaceId: $0.workspaceId,
                panelId: $0.panelId
            )
        }
    }

    @discardableResult
    func restartAgentPane(
        panelId: UUID,
        tabManager preferredTabManager: TabManager? = nil,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard let identity = agentIdentity(forPanelId: panelId),
              let panel = terminalPanel(for: identity, preferredTabManager: preferredTabManager) else {
            return false
        }

        // Prefer the full spawn invocation (CLI + model + system prompt + agent-type
        // flags) captured at addAgentPaneToWorkspace time. Falls back to the bare
        // binary name when unavailable (older sessions, headless edge cases).
        let invocation: String = {
            if let original = identity.originalSpawnCommand, !original.isEmpty {
                return original
            }
            return identity.launchCommand
        }()
        let usingOriginal = identity.originalSpawnCommand?.isEmpty == false

        // Soft-restart escalation: ETX → 150ms → ETX → 200ms → SIGQUIT (\u{1c}) → 150ms → retype.
        // ETX×2 + SIGQUIT is harmless against a healthy CLI (just an extra interrupt
        // it ignores at its prompt) and gives a stuck foreground process two more
        // signals to act on before we attempt to retype.
        panel.sendText("\u{03}")
        #if DEBUG
        dlog("[team.restart] mode=soft ETX#1 team=\(identity.teamName) agent=\(identity.agentName) panel=\(panel.id.uuidString.prefix(8)) invocation_len=\(invocation.count) using_original=\(usingOriginal)")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            panel.sendText("\u{03}")
            #if DEBUG
            dlog("[team.restart] mode=soft ETX#2 panel=\(panel.id.uuidString.prefix(8))")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                panel.sendText("\u{1c}")
                #if DEBUG
                dlog("[team.restart] mode=soft SIGQUIT panel=\(panel.id.uuidString.prefix(8))")
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Task { @MainActor in
                        let sent = panel.surface.sendIMEText(invocation, withReturn: true)
                        if sent {
                            panel.surface.forceRefresh()
                        }
                        #if DEBUG
                        dlog("[team.restart] mode=soft retype sent=\(sent) team=\(identity.teamName) agent=\(identity.agentName) panel=\(panel.id.uuidString.prefix(8)) invocation_len=\(invocation.count) preview=\(invocation.prefix(80).debugDescription)")
                        #endif
                        completion?(sent)
                    }
                }
            }
        }
        return true
    }

    /// Hard restart — close the agent pane and respawn a fresh one in the same
    /// position using the captured spawn metadata. Returns the (old, new) panel
    /// IDs on success. Pane-mode only — headless agents return `.headlessNoPane`.
    ///
    /// In-flight drain policy: waits up to 200ms for active sends to this agent
    /// to finish, then proceeds. Concurrent sends after the migration flag is set
    /// are rejected with `migration_in_flight`.
    enum RestartHardError: Error {
        case agentNotFound
        case headlessNoPane
        case workspaceMissing
        case spawnFailed
        case alreadyMigrating

        var code: String {
            switch self {
            case .agentNotFound: return "not_found"
            case .headlessNoPane: return "headless_no_pane"
            case .workspaceMissing: return "workspace_missing"
            case .spawnFailed: return "spawn_failed"
            case .alreadyMigrating: return "migration_locked"
            }
        }
        var message: String {
            switch self {
            case .agentNotFound: return "Agent not found"
            case .headlessNoPane: return "Hard restart not supported for headless agents"
            case .workspaceMissing: return "Workspace for agent no longer alive"
            case .spawnFailed: return "Failed to spawn new agent pane"
            case .alreadyMigrating: return "Another migration is already in progress for this agent"
            }
        }
    }

    /// PanelId-keyed entry point. Use this from UI sites that already know the
    /// exact panel being restarted (e.g. the pane-header ↻ button) so duplicate
    /// agent names — two `executor` panes in the same team — don't collapse to
    /// the first match. Resolves to (teamName, panelId-matched index) and runs
    /// the full restart sequence with that index.
    @discardableResult
    func restartAgentPaneHard(
        panelId: UUID,
        tabManager preferred: TabManager? = nil
    ) async -> Result<(old: UUID, new: UUID), RestartHardError> {
        var resolved: (team: String, agent: String)?
        for (teamName, team) in teams {
            if let agent = team.agents.first(where: { $0.panelId == panelId }) {
                resolved = (teamName, agent.name)
                break
            }
        }
        guard let r = resolved else {
            #if DEBUG
            dlog("[team.restart] mode=hard panelId-lookup miss panel=\(panelId.uuidString.prefix(8))")
            #endif
            Logger.team.info(
                "[team.restart] mode=hard panelId-lookup miss panel=\(panelId.uuidString.prefix(8), privacy: .public)"
            )
            return .failure(.agentNotFound)
        }
        return await restartAgentPaneHard(
            teamName: r.team,
            agentName: r.agent,
            disambiguatePanelId: panelId,
            tabManager: preferred
        )
    }

    func restartAgentPaneHard(
        teamName: String,
        agentName: String,
        disambiguatePanelId: UUID? = nil,
        tabManager preferred: TabManager? = nil
    ) async -> Result<(old: UUID, new: UUID), RestartHardError> {
        // When `disambiguatePanelId` is provided, match by (name, panelId) so
        // duplicate-named agents resolve to the correct pane. Falls back to
        // first-name-match for the legacy CLI/RPC entry point.
        let idxOpt: Int?
        if let target = disambiguatePanelId {
            idxOpt = teams[teamName]?.agents.firstIndex(where: {
                $0.name == agentName && $0.panelId == target
            })
        } else {
            idxOpt = teams[teamName]?.agents.firstIndex(where: { $0.name == agentName })
        }
        guard var team = teams[teamName], let idx = idxOpt else {
            return .failure(.agentNotFound)
        }
        let old = team.agents[idx]
        guard let oldPid = old.panelId else {
            return .failure(.headlessNoPane)
        }
        let teamAgentKey = "\(teamName)/\(agentName)"
        if migratingAgents.contains(teamAgentKey) {
            return .failure(.alreadyMigrating)
        }
        guard let tabManager = preferred ?? resolveTabManager(teamName: teamName),
              let workspace = tabManager.tabs.first(where: { $0.id == old.workspaceId })
        else {
            return .failure(.workspaceMissing)
        }

        // Phase A — flag agent as migrating, drain in-flight sends (200ms grace).
        migratingAgents.insert(teamAgentKey)
        #if DEBUG
        dlog("[team.restart] mode=hard begin team=\(teamName) agent=\(agentName) oldPanel=\(oldPid.uuidString.prefix(8)) active=\(activeSends[teamAgentKey] ?? 0)")
        #endif
        Logger.team.info(
            "[team.restart] mode=hard begin team=\(teamName, privacy: .public) agent=\(agentName, privacy: .public) oldPanel=\(oldPid.uuidString.prefix(8), privacy: .public)"
        )
        let drainDeadline = Date().addingTimeInterval(0.20)
        while (activeSends[teamAgentKey] ?? 0) > 0 && Date() < drainDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms poll
        }
        let postDrainActive = activeSends[teamAgentKey] ?? 0
        if postDrainActive > 0 {
            #if DEBUG
            dlog("[team.restart] mode=hard drain_timeout team=\(teamName) agent=\(agentName) remaining=\(postDrainActive) — proceeding anyway")
            #endif
        }

        // Pick splitFrom + orientation + insertFirst while the dead pane is still
        // alive in the bonsplit tree. We need its parent-split info to choose the
        // correct sibling anchor + insert side.
        let (splitFrom, orientation, insertFirst) = splitFromForRespawn(
            workspace: workspace, deadPanelId: oldPid, team: team
        )

        // Phase B — SPAWN FIRST, then close. If we close first, bonsplit collapses
        // the parent split and promotes the sibling up one level; the subsequent
        // newTerminalSplit then splits the promoted sibling and produces a totally
        // different layout. By spawning while the dead pane still exists, the new
        // panel is inserted *next to the sibling inside the parent split*. After
        // we then close the dead panel, the outer parent split collapses and the
        // inner (new, sibling) split takes over the slot — visually identical to
        // the original (dead, sibling) layout.

        guard let cliPath = agentBinaryPath(cli: old.cli) else {
            migratingAgents.remove(teamAgentKey)
            return .failure(.spawnFailed)
        }
        let agentWorkDir = old.originalAgentWorkDir ?? team.workingDirectory
        let restartProfile = CLIPathSettings.activeProfile(for: old.cli)
        let restartExtraArgs = restartProfile?.extraArgs ?? []
        let restartExtraEnv = restartProfile?.env ?? [:]
        let restartEffectiveModel = restartProfile?.modelOverride ?? old.model
        guard let newMember = addAgentPaneToWorkspace(
            workspace: workspace,
            agentName: old.name,
            agentCli: old.cli,
            agentModel: restartEffectiveModel,
            agentType: old.agentType,
            agentColor: old.color,
            agentInstructions: old.instructions,
            cliPath: cliPath,
            teamName: teamName,
            leaderSessionId: old.parentSessionId ?? team.leaderSessionId,
            workingDirectory: team.workingDirectory,
            agentWorkDir: agentWorkDir,
            worktreeName: old.worktreeName,
            worktreePath: old.worktreePath,
            worktreeBranch: old.worktreeBranch,
            splitFrom: splitFrom,
            orientation: orientation,
            insertFirst: insertFirst,
            extraArgs: restartExtraArgs,
            extraEnv: restartExtraEnv,
            tabManager: tabManager
        ) else {
            // Spawn failed — dead panel is still alive; leave it in place rather
            // than orphaning the user with neither old nor new pane.
            migratingAgents.remove(teamAgentKey)
            return .failure(.spawnFailed)
        }

        guard let newPid = newMember.panelId else {
            migratingAgents.remove(teamAgentKey)
            return .failure(.spawnFailed)
        }

        #if DEBUG
        dlog("[team.restart] mode=hard spawned team=\(teamName) agent=\(agentName) newPanel=\(newPid.uuidString.prefix(8)) splitFrom=\(splitFrom.uuidString.prefix(8)) orientation=\(orientation) insertFirst=\(insertFirst) — now closing oldPanel=\(oldPid.uuidString.prefix(8))")
        #endif

        // Now close the dead panel. bonsplit collapses the outer parent split,
        // promoting the inner (new, sibling) split into the slot it occupied.
        let closed = workspace.closePanel(oldPid, force: true)
        #if DEBUG
        dlog("[team.restart] mode=hard closed=\(closed) oldPanel=\(oldPid.uuidString.prefix(8))")
        if !closed {
            dlog("[team.restart] mode=hard WARNING close of oldPanel failed — new pane is up but dead pane may linger; user should close manually")
        }
        #endif

        // Phase C — atomic swap. Replace the AgentMember in place (id/name stable).
        // dispatcher / heartbeat / task routing are all (team, agent_name) keyed and
        // resolve agent.panelId fresh on every call, so no explicit rebind is needed.
        team.agents[idx] = newMember
        teams[teamName] = team
        TeamDataStore.shared.registerTeam(teamName, agentNames: team.agents.map(\.name))
        syncTeamStateToDaemon()
        migratingAgents.remove(teamAgentKey)

        #if DEBUG
        dlog("[team.restart] mode=hard ok team=\(teamName) agent=\(agentName) oldPanel=\(oldPid.uuidString.prefix(8)) newPanel=\(newPid.uuidString.prefix(8)) splitFrom=\(splitFrom.uuidString.prefix(8)) orientation=\(orientation) insertFirst=\(insertFirst) close_ok=\(closed)")
        #endif
        Logger.team.info(
            "[team.restart] mode=hard ok team=\(teamName, privacy: .public) agent=\(agentName, privacy: .public) oldPanel=\(oldPid.uuidString.prefix(8), privacy: .public) newPanel=\(newPid.uuidString.prefix(8), privacy: .public) splitFrom=\(splitFrom.uuidString.prefix(8), privacy: .public) insertFirst=\(insertFirst, privacy: .public) close_ok=\(closed, privacy: .public)"
        )
        return .success((old: oldPid, new: newPid))
    }

    /// Snapshot of a pane's position in the bonsplit tree, captured before
    /// closing so the respawned pane can re-occupy the same slot.
    private struct PaneLayoutSnapshot {
        /// Live sibling panel id under the same parent split. Used as splitFrom anchor.
        let siblingPanelId: UUID
        /// Orientation of the parent split (horizontal = side-by-side, vertical = stacked).
        let orientation: SplitOrientation
        /// Was the dead pane on the `first` side of the parent split?
        /// `insertFirst: true` on newTerminalSplit puts the new pane back on that side.
        let deadWasFirst: Bool
    }

    /// Walk the bonsplit treeSnapshot to find the parent split of `deadPanelId`
    /// and return its sibling + orientation + side info. Returns nil if the dead
    /// panel is at the root (no split parent) or cannot be located.
    private func paneLayoutSnapshot(
        workspace: Workspace,
        deadPanelId: UUID
    ) -> PaneLayoutSnapshot? {
        guard let deadTabId = workspace.surfaceIdFromPanelId(deadPanelId) else { return nil }
        let deadTabIdString = deadTabId.uuid.uuidString

        // Walk the tree: at each split, check if `deadTabIdString` is in the first or
        // second subtree's pane-tabs. Return the parent split's info.
        func contains(_ node: ExternalTreeNode, tabId: String) -> Bool {
            switch node {
            case .pane(let pane):
                return pane.tabs.contains(where: { $0.id == tabId })
            case .split(let split):
                return contains(split.first, tabId: tabId) || contains(split.second, tabId: tabId)
            }
        }

        // Returns the first live sibling tab's TabID in the given subtree.
        func firstSiblingTabId(in node: ExternalTreeNode) -> String? {
            switch node {
            case .pane(let pane):
                return pane.selectedTabId ?? pane.tabs.first?.id
            case .split(let split):
                return firstSiblingTabId(in: split.first) ?? firstSiblingTabId(in: split.second)
            }
        }

        var found: PaneLayoutSnapshot?

        // Post-order walk — descend into both children first, only matching the
        // current split as a parent if neither subtree was the immediate parent.
        // root.contains(dead) is trivially true for every ancestor split, so a
        // pre-order match would always pin to the root and pick the wrong sibling
        // (e.g. for root.h(leader, vsplit(a1, a2)), restarting a1 would resolve
        // sibling=leader rather than sibling=a2). Post-order resolves to the
        // *immediate* parent split.
        func walk(_ node: ExternalTreeNode) -> Bool {
            guard case .split(let split) = node else { return false }
            if walk(split.first) { return true }
            if walk(split.second) { return true }
            let inFirst = contains(split.first, tabId: deadTabIdString)
            let inSecond = !inFirst && contains(split.second, tabId: deadTabIdString)
            if inFirst || inSecond {
                let siblingSubtree = inFirst ? split.second : split.first
                if let siblingTabIdString = firstSiblingTabId(in: siblingSubtree),
                   let siblingUUID = UUID(uuidString: siblingTabIdString),
                   let siblingPanelId = workspace.panelIdFromSurfaceId(TabID(uuid: siblingUUID)) {
                    let orient: SplitOrientation = (split.orientation == "horizontal") ? .horizontal : .vertical
                    found = PaneLayoutSnapshot(
                        siblingPanelId: siblingPanelId,
                        orientation: orient,
                        deadWasFirst: inFirst
                    )
                    #if DEBUG
                    dlog("[team.restart] snapshot match deadIn=\(inFirst ? "first" : "second") sibling=\(siblingPanelId.uuidString.prefix(8)) orient=\(orient)")
                    #endif
                    Logger.team.info(
                        "[team.restart] snapshot match deadIn=\(inFirst ? "first" : "second", privacy: .public) sibling=\(siblingPanelId.uuidString.prefix(8), privacy: .public)"
                    )
                    return true
                }
            }
            return false
        }
        _ = walk(workspace.bonsplitController.treeSnapshot())
        if found == nil {
            #if DEBUG
            dlog("[team.restart] snapshot miss — no parent split located for deadPanel=\(deadPanelId.uuidString.prefix(8))")
            #endif
            Logger.team.info(
                "[team.restart] snapshot miss deadPanel=\(deadPanelId.uuidString.prefix(8), privacy: .public)"
            )
        }
        return found
    }

    /// Decide the splitFrom anchor + orientation + insertFirst flag for respawning
    /// a dead pane. When possible, restore the exact slot via the parent-split
    /// snapshot; otherwise fall through a chain of weaker anchors.
    private func splitFromForRespawn(
        workspace: Workspace,
        deadPanelId: UUID,
        team: Team
    ) -> (UUID, SplitOrientation, Bool) {
        // 0. Layout-aware: rebuild in the same slot using parent split info.
        if let snap = paneLayoutSnapshot(workspace: workspace, deadPanelId: deadPanelId),
           workspace.panels[snap.siblingPanelId] != nil {
            return (snap.siblingPanelId, snap.orientation, snap.deadWasFirst)
        }
        // 1. Same bonsplit pane — pick the first surviving tab as anchor.
        if let paneId = workspace.paneId(forPanelId: deadPanelId) {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                if let sibling = workspace.panelIdFromSurfaceId(tab.id), sibling != deadPanelId {
                    return (sibling, .horizontal, false)
                }
            }
        }
        // 2. Another live agent panel.
        for other in team.agents {
            guard let pid = other.panelId, pid != deadPanelId else { continue }
            if workspace.panels[pid] != nil {
                return (pid, .horizontal, false)
            }
        }
        // 3. Team leader panel, if alive here.
        if workspace.panels[team.leaderPanelId] != nil {
            return (team.leaderPanelId, .horizontal, false)
        }
        // 4. First workspace panel (e.g. focusedPanelId).
        if let firstPid = workspace.panels.keys.first {
            return (firstPid, .horizontal, false)
        }
        // Shouldn't reach here — newTerminalSplit will fail and we'll return spawnFailed.
        return (team.leaderPanelId, .horizontal, false)
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
                    var info: [String: Any] = [
                        "id": agent.id,
                        "name": agent.name,
                        "cli": agent.cli,
                        "model": agent.model,
                        "agent_type": agent.agentType,
                        "color": agent.color,
                        "active_task_id": activeTask?.id as Any? ?? NSNull(),
                        "active_task_title": activeTask?.title as Any? ?? NSNull(),
                        "active_task_status": activeTask?.status as Any? ?? NSNull(),
                        "active_task_is_stale": activeTask.map(isTaskStale) ?? false,
                        "agent_state": agentRuntimeState(teamName: team.id, agentName: agent.name),
                        "heartbeat_age_seconds": heartbeatAgeSeconds(teamName: team.id, agentName: agent.name) as Any? ?? NSNull(),
                        "last_heartbeat_summary": heartbeat?.summary as Any? ?? NSNull(),
                        "heartbeat_is_stale": heartbeat.map(isHeartbeatStale) ?? false,
                        "workspace_id": agent.workspaceId.uuidString,
                    ]
                    if let pid = agent.panelId {
                        info["panel_id"] = pid.uuidString
                    }
                    return info
                },
                "attention_count": teamInbox.count,
                "created_at": ISO8601DateFormatter().string(from: team.createdAt),
                // Leader pane runs its own CLI session — expose it so the daemon's
                // usage-tick broadcaster can attribute token usage to the leader
                // (the leader is intentionally NOT part of the `agents` array).
                "leader_cli": team.leaderMode,
                "leader_panel_id": team.leaderPanelId.uuidString
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
                    "active_task_id": activeTask?.id as Any? ?? NSNull(),
                    "active_task_title": activeTask?.title as Any? ?? NSNull(),
                    "active_task_status": activeTask?.status as Any? ?? NSNull(),
                    "active_task_is_stale": activeTask.map(isTaskStale) ?? false,
                    "agent_state": agentRuntimeState(teamName: team.id, agentName: agent.name),
                    "heartbeat_age_seconds": heartbeatAgeSeconds(teamName: team.id, agentName: agent.name) as Any? ?? NSNull(),
                    "last_heartbeat_summary": heartbeat?.summary as Any? ?? NSNull(),
                    "heartbeat_is_stale": heartbeat.map(isHeartbeatStale) ?? false,
                    "workspace_id": agent.workspaceId.uuidString,
                ]
                if let pid = agent.panelId {
                    info["panel_id"] = pid.uuidString
                }
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
        // Phase 2 (pane-mode resume): persist a `mode: "pane"` archive so this
        // team shows up in `Resume from previous team`. Best-effort — failures
        // don't block destroy. Headless teams are archived daemon-side by
        // `headless.destroy_team` and never enter this code path.
        archivePaneTeamIfApplicable(team)
        guard let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }) else {
            cleanupWorktrees(team: team)
            clearResults(teamName: name)
            clearMessages(teamName: name)
            clearTasks(teamName: name)
            teams.removeValue(forKey: name)
            heartbeats.removeValue(forKey: name)
            TeamDataStore.shared.unregisterTeam(name)
            syncTeamStateToDaemon()
            return true
        }

        // Send Ctrl-C to all agent panels
        for agent in team.agents {
            guard let pid = agent.panelId else { continue }
            if let panel = workspace.terminalPanel(for: pid) {
                panel.sendText("\u{03}")  // Ctrl-C
            }
        }

        // Send exit after a delay, then close workspace and clean up worktrees
        let wsRef = workspace
        let teamCopy = team
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for agent in teamCopy.agents {
                guard let pid = agent.panelId else { continue }
                if let panel = wsRef.terminalPanel(for: pid) {
                    panel.sendText("exit\n")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            tabManager.closeTab(wsRef)
            // Clean up worktrees after workspace is closed
            self.cleanupWorktrees(team: teamCopy)
        }

        // Stop periodic render timer if no teams remain after this removal
        if teams.count <= 1 {
            stopPeriodicRenderTimer()
            agentRenderingPaused = false
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

        // Clean up leader prompt temp file
        let safeName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        try? FileManager.default.removeItem(atPath: "/tmp/term-mesh-leader-\(safeName).md")

        teams.removeValue(forKey: name)
        syncTeamStateToDaemon()
        Logger.team.info("destroyed team '\(name, privacy: .public)'")
        // Phase 2: notify any open TeamCreationView so its "Resume from previous
        // team" list refreshes promptly when a team is destroyed mid-dialog.
        NotificationCenter.default.post(name: .headlessTeamDestroyed, object: nil, userInfo: ["team_name": name])
        return true
    }

    /// Phase 2: register a previously-destroyed headless team that the daemon
    /// has just resumed via `headless.resume_team`. The daemon has already
    /// respawned all agent subprocesses; we mirror the team in our in-memory
    /// registry and open a workspace at the worktree path so the UI surfaces
    /// the resumed agents. Best-effort — if the result is malformed we log and
    /// return without throwing (caller is a UI completion handler).
    /// Phase 2 (pane-mode resume): adopt a pane-mode archive that the daemon
    /// returned via `team.resume_pane`. Delegates to `createTeam` so the
    /// workspace, leader pane, and agent panes are all materialized the same
    /// way a fresh `New Agent Team` would create them — then patches the
    /// archived `team_uuid` and per-agent `session_id`s back onto the live
    /// `Team` so a subsequent destroy archives to the same UUID and preserves
    /// the per-agent session IDs (re-resumable).
    ///
    /// The **leader** pane resumes via `--resume <leader.session_id>` (already
    /// wired through `createTeam`'s `resumeSessionId` parameter). Per-agent
    /// `--resume <sid>` for individual agent CLIs is a follow-up — agents
    /// currently start fresh but their captured session IDs are preserved on
    /// the in-memory `AgentMember` so a future iteration can wire them through
    /// `addAgentPaneToWorkspace`'s CLI command builders.
    @discardableResult
    func adoptResumedPaneTeam(result: [String: Any], tabManager: TabManager) -> Team? {
        guard let teamName = result["team_name"] as? String,
              let workingDirectory = result["working_directory"] as? String,
              let agentsArr = result["agents"] as? [[String: Any]] else {
            Logger.team.error("[pane-resume] result missing required fields")
            return nil
        }
        if teams[teamName] != nil {
            Logger.team.info("[pane-resume] team '\(teamName, privacy: .public)' already live — skipping adopt")
            return teams[teamName]
        }
        let archivedTeamUuid = result["team_uuid"] as? String
        let leaderDict = result["leader"] as? [String: Any]
        let leaderSessionId = (leaderDict?["session_id"] as? String) ?? ""
        let leaderMode = (leaderDict?["mode"] as? String) ?? "claude"
        let leaderModel = (leaderDict?["model"] as? String) ?? "sonnet"

        // worktree mode from archive (off / shared / isolated). If the archive
        // had a shared worktree, the createTeam path will reuse the same
        // configuration when laying out panes.
        let archivedWorktreeMode: String = {
            if let wt = result["worktree"] as? [String: Any],
               let mode = wt["mode"] as? String, !mode.isEmpty {
                return mode
            }
            return "off"
        }()

        // Build agents tuple in createTeam's expected shape.
        typealias AgentTuple = (name: String, cli: String, model: String, agentType: String, color: String, instructions: String)
        let agentTuples: [AgentTuple] = agentsArr.map { a in
            (
                name: (a["name"] as? String) ?? "agent",
                cli: (a["cli"] as? String) ?? "claude",
                model: (a["model"] as? String) ?? "sonnet",
                agentType: (a["agent_type"] as? String) ?? ((a["name"] as? String) ?? "agent"),
                color: (a["color"] as? String) ?? "blue",
                instructions: (a["instructions"] as? String) ?? ""
            )
        }

        // Phase 2: per-agent claude session IDs (captured at archive time via
        // sidebar token tracker, stored in AgentMember.parentSessionId). Passed
        // into createTeam so each claude agent CLI starts with `--resume <sid>`
        // and re-attaches to its previous transcript. Codex/kiro/gemini agents
        // currently ignore this; resume support for them is a follow-up.
        var agentResumeMap: [String: String] = [:]
        for a in agentsArr {
            guard let name = a["name"] as? String,
                  let sid = a["session_id"] as? String,
                  !sid.isEmpty else { continue }
            agentResumeMap[name] = sid
        }

        // Fresh leader routing UUID for the new team (regenerated each create).
        let freshLeaderSessionId = UUID().uuidString

        // `leaderSessionId` from the archive is the REAL claude session id
        // (discovered from ~/.claude/projects/ at archive time). Passing it
        // as `--resume` re-attaches claude to its prior transcript.
        let leaderClaudeSid = leaderSessionId.isEmpty ? nil : leaderSessionId

        guard let team = createTeam(
            name: teamName,
            agents: agentTuples,
            workingDirectory: workingDirectory,
            leaderSessionId: freshLeaderSessionId,
            leaderMode: leaderMode,
            leaderModel: leaderModel,
            resumeSessionId: leaderClaudeSid,
            worktreeMode: archivedWorktreeMode,
            executionMode: "pane",
            agentResumeSessionIds: agentResumeMap.isEmpty ? nil : agentResumeMap,
            tabManager: tabManager
        ) else {
            Logger.team.error("[pane-resume] createTeam failed for '\(teamName, privacy: .public)'")
            return nil
        }

        // Patch back the archived team_uuid + per-agent session IDs so the
        // live team round-trips: a future destroy archives to the same UUID
        // and carries forward each agent's resume identity.
        if var t = teams[teamName] {
            if let uuid = archivedTeamUuid, !uuid.isEmpty {
                t.teamUuid = uuid
            }
            // Map archived agents by name and copy session_id back.
            var archivedSessionsByName: [String: String] = [:]
            for a in agentsArr {
                guard let name = a["name"] as? String,
                      let sid = a["session_id"] as? String,
                      !sid.isEmpty else { continue }
                archivedSessionsByName[name] = sid
            }
            if !archivedSessionsByName.isEmpty {
                t.agents = t.agents.map { member in
                    var m = member
                    if let sid = archivedSessionsByName[member.name] {
                        m.parentSessionId = sid
                    }
                    return m
                }
            }
            teams[teamName] = t
        }

        Logger.team.info("[pane-resume] adopted team '\(teamName, privacy: .public)' with \(agentTuples.count) agent(s); leader resumed via --resume, agents start fresh (per-agent --resume is a follow-up)")
        return teams[teamName]
    }

    @discardableResult
    func adoptResumedHeadlessTeam(result: [String: Any], tabManager: TabManager) -> Team? {
        guard let teamName = result["name"] as? String,
              let agentIds = result["agents"] as? [String],
              let workingDirectory = result["working_directory"] as? String,
              let leaderSessionId = result["leader_session_id"] as? String else {
            Logger.team.error("[headless] resume_team result missing required fields")
            return nil
        }
        let teamUuid = result["team_uuid"] as? String

        // Avoid clobbering a live team with the same name (defense — daemon
        // would normally reject this with team_name_in_use, but UI may race).
        if let existing = teams[teamName] {
            Logger.team.info("[headless] resumed team '\(teamName, privacy: .public)' already exists locally — skipping adopt")
            return existing
        }

        // Optional worktree info from resume_team result. The contract does
        // not require these to be echoed back, but if they are, prefer the
        // worktree path as workspace cwd.
        var worktreePath: String?
        var worktreeBranch: String?
        var worktreeName: String?
        if let wt = result["worktree"] as? [String: Any] {
            worktreePath = wt["path"] as? String
            worktreeBranch = wt["branch"] as? String
            if let p = worktreePath, let name = (p as NSString).lastPathComponent as String? {
                worktreeName = name
            }
        }
        let workspaceCwd = worktreePath ?? workingDirectory

        // Open a workspace tab pointed at the resumed team's worktree (or
        // working_directory). The headless agents have no panes — this
        // workspace acts as the leader console host.
        let workspace = tabManager.addWorkspace(
            workingDirectory: workspaceCwd,
            select: true
        )
        workspace.customTitle = "[\(teamName)] \(agentIds.count) headless"
        workspace.title = "[\(teamName)] \(agentIds.count) headless"

        // Build minimal AgentMember stubs from the agent id strings
        // ("<name>@<team>"). We don't have full per-agent metadata in the
        // resume result envelope, so cli/model/color/instructions default
        // sensibly until the daemon emits state updates.
        let colors = ["green", "blue", "yellow", "magenta", "cyan", "red"]
        let members: [AgentMember] = agentIds.enumerated().map { index, fullId in
            let name = String(fullId.split(separator: "@").first ?? Substring(fullId))
            return AgentMember(
                id: fullId,
                name: name,
                teamName: teamName,
                cli: "claude",
                launchCommand: Self.defaultLaunchCommand(for: "claude"),
                model: "sonnet",
                agentType: name,
                color: colors[index % colors.count],
                instructions: "",
                workspaceId: workspace.id,
                panelId: nil, // headless — no real panel (resumed team)
                parentSessionId: leaderSessionId,
                createdAt: Date(),
                worktreeName: worktreeName,
                worktreePath: worktreePath,
                worktreeBranch: worktreeBranch,
                originalSpawnCommand: nil, // headless — daemon owns subprocess
                originalAgentWorkDir: nil
            )
        }

        let team = Team(
            id: teamName,
            leaderSessionId: leaderSessionId,
            leaderMode: "claude",
            leaderModel: "sonnet",
            leaderPanelId: UUID(), // placeholder — headless team has no leader pane
            leaderWorkspaceId: workspace.id,
            workingDirectory: workingDirectory,
            workspaceId: workspace.id,
            agents: members,
            createdAt: Date(),
            gitRepoRoot: nil,
            worktreeMode: worktreePath == nil ? "off" : "isolated",
            sharedWorktreeName: nil,
            sharedWorktreePath: nil,
            sharedWorktreeBranch: nil,
            teamUuid: teamUuid
        )
        teams[teamName] = team
        TeamDataStore.shared.registerTeam(teamName, agentNames: members.map(\.name))
        syncTeamStateToDaemon()
        Logger.team.info("[headless] adopted resumed team '\(teamName, privacy: .public)' uuid=\(teamUuid ?? "?", privacy: .public)")
        return team
    }

    /// Phase 2 (pane-mode resume): discover the real claude session id for a
    /// pane by scanning `~/.claude/projects/<encoded-workdir>/`. Claude writes
    /// its conversation transcript to `<sessionId>.jsonl` in that directory,
    /// so the most recently modified file there is the live session for any
    /// claude CLI started in that working directory.
    ///
    /// Returns nil when the directory is absent or empty. The encoded directory
    /// name mirrors what claude itself produces (`/` → `-`).
    private static func discoverClaudeSessionId(workingDirectory: String) -> String? {
        guard !workingDirectory.isEmpty else { return nil }
        let encoded = workingDirectory.replacingOccurrences(of: "/", with: "-")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.claude/projects/\(encoded)"
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir),
              let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (sid: String, mtime: Date)?
        for item in items {
            guard item.hasSuffix(".jsonl") else { continue }
            let sid = String(item.dropLast(6))
            // claude session ids are RFC4122 UUIDs (8-4-4-4-12 = 36 chars, 4 dashes).
            guard sid.count == 36, sid.filter({ $0 == "-" }).count == 4 else { continue }
            let path = "\(dir)/\(item)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime {
                best = (sid, mtime)
            }
        }
        return best?.sid
    }

    /// Phase 2 (pane-mode resume): on destroy of a pane-mode team, ship a
    /// `team.archive_pane` RPC to the daemon so the team appears in
    /// `headless.list_resumable` with `mode: "pane"`. Headless teams (managed by
    /// the daemon) are archived by the daemon's own destroy path and skip this.
    ///
    /// Best-effort: failures are logged and don't block destroy. The leader's
    /// `--resume <leaderSessionId>` and each agent's `parentSessionId`
    /// (captured by the sidebar token-tracking infrastructure in 0.115.0) are
    /// sufficient to bring the team back via `team.resume_pane`.
    ///
    /// - Parameter synchronous: when true (used by `applicationWillTerminate`),
    ///   the RPC runs inline on the caller's queue so the archive write
    ///   completes before the daemon is stopped. The normal destroy path
    ///   defaults to false so the UI doesn't block on disk I/O.
    private func archivePaneTeamIfApplicable(_ team: Team, synchronous: Bool = false) {
        // Skip headless teams — the daemon's `headless.destroy_team` already
        // writes their archive. Pane-mode agents always have a `panelId` (real
        // GUI pane); headless agents have `panelId == nil` (daemon subprocess).
        // Note: `teamUuid` alone is not a reliable headless signal here because
        // a RESUMED pane team carries the archived uuid forward — it's still
        // pane-mode and must be re-archived on next destroy / quit.
        let isHeadless = !team.agents.isEmpty && team.agents.allSatisfy { $0.panelId == nil }
        if isHeadless {
            #if DEBUG
            dlog("[archive_pane] skip — headless team=\(team.id) (agents have no panelId)")
            #endif
            return
        }
        #if DEBUG
        dlog("[archive_pane] proceed team=\(team.id) sync=\(synchronous) agents=\(team.agents.count) teamUuid=\(team.teamUuid ?? "nil")")
        #endif

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        // For each pane we need the REAL claude session id (not the team's
        // routing UUID stored in `parentSessionId` / `leaderSessionId`). Claude
        // writes its transcripts to `~/.claude/projects/<encoded-workdir>/<sid>.jsonl`,
        // so the most recently modified file in that directory is the live
        // session for that pane. This is imperfect when multiple panes share a
        // workdir (no worktree / shared worktree) — in that case the latest
        // file wins for the agent we look up last; worktree-isolated mode
        // gives clean 1-to-1 mapping.
        // `leader_session_id` carries the REAL claude session id (discovered
        // from `~/.claude/projects/`), not the team's ephemeral routing UUID.
        // Empty string when no claude transcript exists yet (e.g., a team
        // destroyed before the leader pane was used).
        let leaderSid = Self.discoverClaudeSessionId(workingDirectory: team.workingDirectory) ?? ""
        var payload: [String: Any] = [
            "team_name": team.id,
            "leader_session_id": leaderSid,
            "leader_mode": team.leaderMode,
            "leader_model": team.leaderModel,
            "working_directory": team.workingDirectory,
            "termmesh_app_version": appVersion,
            "agents": team.agents.map { a -> [String: Any] in
                var row: [String: Any] = [
                    "name": a.name,
                    "cli": a.cli,
                    "model": a.model,
                    "agent_type": a.agentType,
                    "color": a.color,
                ]
                // Per-agent claude session id. Only safe to discover when the
                // agent has its OWN worktree (1-to-1 mapping). When agents share
                // the team workdir, mtime-based discovery returns the same jsonl
                // for every agent — almost always the leader's — which causes
                // resume to rehydrate every pane with the leader's conversation.
                // Leave session_id nil in that case so the team is marked
                // `no_sessions` rather than silently corrupting on resume.
                // Also drop the value if it collides with the leader sid even
                // when a worktree path is set (catches edge cases like a freshly
                // created worktree where claude hasn't yet written a transcript
                // and discovery falls through to the parent dir).
                if let wt = a.worktreePath, !wt.isEmpty, wt != team.workingDirectory,
                   let sid = Self.discoverClaudeSessionId(workingDirectory: wt),
                   !sid.isEmpty, sid != leaderSid {
                    row["session_id"] = sid
                }
                if !a.instructions.isEmpty {
                    row["instructions"] = a.instructions
                }
                return row
            },
        ]
        // git_root drives the "this repo" filter in the resume picker. Pane
        // teams created with worktreeMode = "off" leave `team.gitRepoRoot`
        // nil, so fall back to discovering it from the team's working
        // directory at archive time. Without this, worktree-off pane teams
        // only show up under "All" — a UX regression vs. headless teams.
        let resolvedGitRoot: String? = {
            if let root = team.gitRepoRoot, !root.isEmpty { return root }
            return TermMeshDaemon.shared.findGitRoot(from: team.workingDirectory)
        }()
        #if DEBUG
        dlog("[archive_pane.git_root] team=\(team.id) team.gitRepoRoot=\(team.gitRepoRoot ?? "nil") workingDirectory=\(team.workingDirectory) resolved=\(resolvedGitRoot ?? "nil")")
        #endif
        if let root = resolvedGitRoot, !root.isEmpty {
            payload["git_root"] = root
        }
        // worktree info: pane-mode teams may share or per-agent. Capture shared.
        if let wtName = team.sharedWorktreeName,
           let wtPath = team.sharedWorktreePath,
           let wtBranch = team.sharedWorktreeBranch,
           !wtName.isEmpty {
            payload["worktree_mode"] = team.worktreeMode
            payload["worktree_path"] = wtPath
            payload["worktree_branch"] = wtBranch
        }

        let work = {
            let raw = TermMeshDaemon.shared.rpcCallRaw(
                method: "team.archive_pane",
                params: payload
            )
            if let raw, let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errMsg = obj["error"] as? String {
                    Logger.team.warning("[archive_pane] daemon error: \(errMsg, privacy: .public)")
                } else if let result = obj["result"] as? [String: Any],
                          let path = result["archived_path"] as? String {
                    Logger.team.info("[archive_pane] archived → \(path, privacy: .public)")
                }
            } else {
                Logger.team.warning("[archive_pane] daemon did not respond")
            }
        }
        if synchronous {
            work()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }

    /// Phase 2 (pane-mode resume): archive every live pane-mode team
    /// synchronously. Called from `applicationWillTerminate` so a plain Cmd+Q
    /// also leaves resumable archives on disk — users shouldn't have to
    /// explicitly destroy a team just to see it in the resume picker later.
    /// Runs each archive RPC inline on the calling queue (the main thread
    /// during termination) so the writes finish before the daemon is stopped.
    func archiveAllLivePaneTeamsForQuit() {
        // Pane-mode = at least one agent has a real GUI panel. Mirrors the
        // skip rule in `archivePaneTeamIfApplicable`.
        let live = teams.values.filter { team in
            !team.agents.isEmpty && !team.agents.allSatisfy { $0.panelId == nil }
        }
        #if DEBUG
        dlog("[archive_pane] quit hook: total teams=\(teams.count) live-pane=\(live.count)")
        #endif
        if live.isEmpty { return }
        Logger.team.info("[archive_pane] quit: archiving \(live.count) live pane team(s)")
        for team in live {
            archivePaneTeamIfApplicable(team, synchronous: true)
        }
    }

    /// Log detached worktrees from a destroyed team (no longer auto-deleted).
    private func cleanupWorktrees(team: Team) {
        for agent in team.agents {
            guard let wtName = agent.worktreeName else { continue }
            Logger.team.info("worktree '\(wtName, privacy: .public)' detached from agent '\(agent.name, privacy: .public)' (kept for manual cleanup)")
        }
    }

    // MARK: - Private

    private func agentIdentity(for agent: AgentMember) -> AgentPaneIdentity? {
        guard let pid = agent.panelId else { return nil }
        return AgentPaneIdentity(
            teamName: agent.teamName,
            agentName: agent.name,
            panelId: pid,
            workspaceId: agent.workspaceId,
            launchCommand: agent.launchCommand.isEmpty
                ? Self.defaultLaunchCommand(for: agent.cli)
                : agent.launchCommand,
            originalSpawnCommand: agent.originalSpawnCommand
        )
    }

    private func terminalPanel(
        for identity: AgentPaneIdentity,
        preferredTabManager: TabManager?
    ) -> TerminalPanel? {
        let tabManager = preferredTabManager ?? resolveTabManager(teamName: identity.teamName)
        if let tabManager,
           let workspace = tabManager.tabs.first(where: { $0.id == identity.workspaceId }),
           let panel = workspace.terminalPanel(for: identity.panelId) {
            return panel
        }
        if let located = AppDelegate.shared?.locateSurface(surfaceId: identity.panelId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) {
            return workspace.terminalPanel(for: identity.panelId)
        }
        return nil
    }

    private static func defaultLaunchCommand(for cli: String) -> String {
        switch cli.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "claude":
            return "claude"
        case "codex":
            return "codex"
        case "gemini":
            return "gemini"
        case "kiro", "kiro-cli":
            return "kiro-cli"
        default:
            return cli
        }
    }

    private func buildClaudeCommand(
        claudePath: String,
        agentId: String,
        agentName: String,
        teamName: String,
        agentColor: String,
        parentSessionId: String,
        agentType: String,
        model: String,
        instructions: String = "",
        extraArgs: [String] = []
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

        parts += extraArgs.map { shellQuote($0) }

        return parts.joined(separator: " ")
    }

    private func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Map short model names (used internally) to kiro-cli model identifiers.
    private static func kiroModelName(_ shortName: String) -> String {
        switch shortName.lowercased() {
        case "opus":   return "claude-opus-4.7"
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
        systemPrompt: String? = nil,
        extraArgs: [String] = []
    ) -> String {
        let profileName = "team-\(teamName)-\(agentName)"

        let defaultPrompt: String
        if isLeader {
            // Leader profile tells kiro to read the prompt file on startup.
            // The file is written after agents are created (by createTeam).
            defaultPrompt = """
            You are a team leader in term-mesh. \
            On startup, immediately read /tmp/term-mesh-leader-\(teamName).md — \
            it contains your full team instructions with agent list and tm-agent commands. \
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

        parts += extraArgs.map { shellQuote($0) }

        return parts.joined(separator: " ")
    }

    /// Map short model names to Codex CLI model identifiers.
    /// All short tiers map to gpt-5.5; differentiation happens via reasoning effort
    /// (see codexReasoningEffort). New-style names pass through directly.
    private static func codexModelName(_ shortName: String) -> String {
        switch shortName.lowercased() {
        case "opus", "sonnet", "haiku": return "gpt-5.5"
        default: return shortName
        }
    }

    /// Map short model tier to Codex reasoning effort (high/medium/low).
    /// Returns nil for non-tier model names so we don't override user-specified models.
    private static func codexReasoningEffort(_ shortName: String) -> String? {
        switch shortName.lowercased() {
        case "opus": return "high"
        case "sonnet": return "medium"
        case "haiku": return "low"
        default: return nil
        }
    }

    private func buildCodexCommand(
        codexPath: String,
        agentName: String,
        teamName: String,
        model: String,
        extraArgs: [String] = []
    ) -> String {
        let path = codexPath.contains(" ") ? "\"\(codexPath)\"" : codexPath
        var parts = [
            path,
            "--ask-for-approval never",       // auto-approve all tool calls
            "--sandbox danger-full-access"    // allow Unix socket access for tm-agent communication
        ]

        if !model.isEmpty {
            let codexModel = Self.codexModelName(model)
            parts.append("--model \(codexModel)")
        }

        if !model.isEmpty, let effort = Self.codexReasoningEffort(model) {
            parts.append("-c model_reasoning_effort=\(effort)")
        }

        parts += extraArgs.map { shellQuote($0) }

        // Start interactively — leader sends instructions via tm-agent send.
        return parts.joined(separator: " ")
    }

    /// Map short model names to Gemini CLI model identifiers.
    /// New-style names pass through directly.
    private static func geminiModelName(_ shortName: String) -> String {
        switch shortName.lowercased() {
        case "opus":   return "gemini-3.1-pro-preview"
        case "sonnet": return "gemini-3-flash-preview"
        case "haiku":  return "gemini-3.1-flash-lite-preview"
        default:       return shortName
        }
    }

    private func buildGeminiCommand(
        geminiPath: String,
        agentName: String,
        teamName: String,
        model: String,
        extraArgs: [String] = []
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

        parts += extraArgs.map { shellQuote($0) }

        // Start interactively — leader sends instructions via tm-agent send.
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
        guard let pid = agent.panelId else { return nil }
        guard let workspace = tabManager.tabs.first(where: { $0.id == agent.workspaceId }) else { return nil }
        return workspace.terminalPanel(for: pid)
    }

    /// Get all agent panels for a team.
    func allAgentPanels(teamName: String, tabManager: TabManager) -> [(name: String, panel: TerminalPanel)] {
        guard let team = teams[teamName] else { return [] }
        var results: [(name: String, panel: TerminalPanel)] = []
        for agent in team.agents {
            guard let pid = agent.panelId,
                  let workspace = tabManager.tabs.first(where: { $0.id == agent.workspaceId }),
                  let panel = workspace.terminalPanel(for: pid) else { continue }
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
        // Prune oldest messages when exceeding the per-team cap.
        if let count = messages[teamName]?.count, count > maxMessagesPerTeam {
            messages[teamName]?.removeFirst(count - maxMessagesPerTeam)
        }
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
            resultPath: nil,
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
        resultPath: String? = nil,
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
        if let resultPath { tasks[idx].resultPath = resultPath.nilIfBlank }
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
        let now = Date()
        heartbeats[teamName, default: [:]][agentName] = (now, summary?.nilIfBlank)
        // Update lastProgressAt for the agent's active in_progress task
        if var tasks = taskBoards[teamName],
           let idx = tasks.firstIndex(where: { $0.assignee == agentName && $0.status == "in_progress" }) {
            tasks[idx].lastProgressAt = now
            taskBoards[teamName] = tasks
        }
        syncTeamStateToDaemon()
    }

    func inboxItems(teamName: String, agentName: String? = nil, topOnly: Bool = false) -> [[String: Any]] {
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
                "agent_name": task.assignee as Any? ?? NSNull(),
                "reason": attention.1,
                "age_seconds": Int(now.timeIntervalSince(task.updatedAt)),
                "summary": task.title,
                "task_title": task.title,
                "result": task.result as Any? ?? NSNull(),
                "review_summary": task.reviewSummary as Any? ?? NSNull(),
                "status": task.status,
                "is_stale": staleSeconds != nil,
                "stale_seconds": staleSeconds as Any? ?? NSNull()
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
                // When agentName is provided, include all messages addressed to this agent
                if let agent = agentName, message.to == agent {
                    priority = 6
                } else {
                    priority = nil
                }
            }
            guard let priority else { continue }
            var item: [String: Any] = [
                "kind": "message",
                "priority": priority,
                "team_name": teamName,
                "task_id": NSNull(),
                "agent_name": message.from,
                "status": message.type,
                "reason": message.content,
                "age_seconds": Int(now.timeIntervalSince(message.timestamp)),
                "summary": message.content,
                "message_type": message.type,
                "message_id": message.id,
            ]
            if let to = message.to { item["to"] = to }
            items.append(item)
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
            "description": task.details as Any? ?? NSNull(),
            "acceptance_criteria": task.acceptanceCriteria,
            "labels": task.labels,
            "estimated_size": task.estimatedSize as Any? ?? NSNull(),
            "status": task.status,
            "priority": task.priority,
            "depends_on": task.dependsOn,
            "parent_task_id": task.parentTaskId as Any? ?? NSNull(),
            "child_task_ids": task.childTaskIds,
            "reassignment_count": task.reassignmentCount,
            "superseded_by": task.supersededBy as Any? ?? NSNull(),
            "assignee": task.assignee as Any? ?? NSNull(),
            "blocked_reason": task.blockedReason as Any? ?? NSNull(),
            "review_summary": task.reviewSummary as Any? ?? NSNull(),
            "created_by": task.createdBy,
            "result": task.result as Any? ?? NSNull(),
            "result_path": task.resultPath as Any? ?? NSNull(),
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

    // MARK: - Phase 2.5 — Sidebar context-menu RPC helpers

    /// Resolve the headless `team_uuid` for a given team name. Nil for
    /// pane-mode teams or teams whose UUID has not yet been captured from
    /// `headless.create_team`.
    func teamUuid(for teamName: String) -> String? {
        teams[teamName]?.teamUuid
    }

    /// Park one agent immediately via `headless.park_agent` (off-main).
    /// `completion` (optional) is invoked on the main thread with the raw
    /// response dictionary or `nil` on transport failure.
    func parkAgent(teamName: String, agentName: String, completion: (([String: Any]?) -> Void)? = nil) {
        let params: [String: Any] = [
            "team_name": teamName,
            "agent_name": agentName,
        ]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let raw = self.daemon.rpcCallRaw(method: "headless.park_agent", params: params)
            var dict: [String: Any]?
            if let raw, let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dict = (obj["result"] as? [String: Any]) ?? obj
            }
            DispatchQueue.main.async { completion?(dict) }
        }
    }

    /// Unpark a previously parked agent via `headless.unpark_agent`.
    func unparkAgent(teamName: String, agentName: String, completion: (([String: Any]?) -> Void)? = nil) {
        let params: [String: Any] = [
            "team_name": teamName,
            "agent_name": agentName,
            "app_socket_path": SocketControlSettings.socketPath(),
        ]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let raw = self.daemon.rpcCallRaw(method: "headless.unpark_agent", params: params)
            var dict: [String: Any]?
            if let raw, let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dict = (obj["result"] as? [String: Any]) ?? obj
            }
            DispatchQueue.main.async { completion?(dict) }
        }
    }

    /// Count of resumable headless teams via `headless.list_resumable`. The
    /// daemon already excludes corrupt / non-resumable rows; this helper
    /// counts only entries whose `resumable == true`.
    func countResumableTeams(gitRoot: String? = nil, completion: @escaping (Int) -> Void) {
        var params: [String: Any] = ["limit": 200]
        if let root = gitRoot { params["git_root"] = root }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(0) }
                return
            }
            let raw = self.daemon.rpcCallRaw(method: "headless.list_resumable", params: params)
            var count = 0
            if let raw, let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let teamList: [[String: Any]]?
                if let inner = obj["result"] as? [String: Any] {
                    teamList = inner["teams"] as? [[String: Any]]
                } else {
                    teamList = obj["teams"] as? [[String: Any]]
                }
                if let teamList {
                    count = teamList.filter { ($0["resumable"] as? Bool) == true }.count
                }
            }
            DispatchQueue.main.async { completion(count) }
        }
    }

    private func agentRuntimeState(teamName: String, agentName: String) -> String {
        // Phase 2: parked is daemon-authoritative — overrides task-derived state
        // because the subprocess is not live regardless of task board entry.
        if TeamDataStore.shared.isAgentParked(teamName: teamName, agentName: agentName) {
            return "parked"
        }
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
        case "parked":
            return "parked"
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
