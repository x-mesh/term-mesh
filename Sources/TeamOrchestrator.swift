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
        /// Real Claude CLI session id (UUID written by Claude to
        /// `~/.claude/projects/<encoded-workdir>/<sid>.jsonl`). Captured at
        /// pane spawn time via FSEventStream and used as the authoritative
        /// `session_id` for archive_pane / pane-resume. Distinct from
        /// `parentSessionId`, which is term-mesh's routing UUID.
        var claudeSessionId: String?
        /// When `claudeSessionId` was captured. Persisted into live snapshots
        /// (`session_id_captured_at`) so restore can judge sid staleness.
        var claudeSessionIdCapturedAt: Date?
        let createdAt: Date
        // Worktree isolation
        var worktreeName: String?
        var worktreePath: String?
        var worktreeBranch: String?
        /// The remote surface this agent's pane is attached to, when it runs
        /// on a peer.
        ///
        /// A host's surface list says whether a surface *may* be attached, not
        /// whether one already is — attaching twice is allowed on purpose, so
        /// two people can watch the same terminal. That makes it indistinguishable
        /// from a free one over the wire, and a second agent quietly landed in
        /// the first one's shell: same pane, same directory, two agents typing
        /// over each other. What this side attached, this side can remember.
        var remoteSurfaceID: Data?
        /// Whether this side asked the host to create that surface. A borrowed
        /// surface is the operator's — one of the shells the host publishes —
        /// and closing it would take away something they offered to everyone.
        /// One we asked for is ours to clean up.
        var remoteSurfaceSpawned: Bool = false
        /// The peer this agent's pane runs on (`ssh:root@jw-server`), or nil
        /// when it runs here.
        ///
        /// A team was implicitly one machine's: an agent had a workspace and a
        /// panel, both local, and nothing to say otherwise. But the machine an
        /// agent needs is a property of the work — tests want the Mac, a build
        /// may want the Linux box — so it belongs to the member rather than to
        /// the team. The pane is local either way: a peer pane is attached
        /// into this workspace, so `panelId` still addresses it and everything
        /// keyed on that (send, scrollback, reveal) is unchanged.
        var hostKey: String?
        /// Full CLI invocation captured at spawn time (binary + model flag + system
        /// prompt + agent-type flags). Retyped on soft restart to recover original
        /// agent context rather than the bare binary name. nil for headless agents
        /// (daemon-managed subprocess, no pane to retype into).
        var originalSpawnCommand: String?
        /// The exact `agentWorkDir` used when the pane was first spawned (either
        /// the worktree path or the team's working directory). Hard restart feeds
        /// it back into `addAgentPaneToWorkspace` so cwd is preserved.
        var originalAgentWorkDir: String?
        /// Auto-recycle threshold: recycle this agent every N completed tasks.
        /// nil = inherit team default; 0 = explicitly disabled for this agent.
        var autoRecycleEvery: Int? = nil
        /// Running count of tasks completed by this agent (reset on recycle).
        var completedTaskCount: Int = 0
    }

    struct Team: Identifiable {
        let id: String            // team name
        let leaderSessionId: String
        let leaderMode: String    // "repl", "claude", "kiro", "codex", "gemini", "adopted"
        let leaderModel: String   // e.g. "sonnet", "opus", "haiku"
        let leaderCli: String?    // detected CLI for adopted leader; nil otherwise
        var leaderPanelId: UUID   // leader pane for sending instructions
        var leaderWorkspaceId: UUID?  // only set in "adopted" mode (leader lives in a separate workspace)
        /// The leader's host namespace.  Older teams did not carry this
        /// field; its default preserves their established local behaviour.
        var leaderEndpoint: LeaderEndpoint = .local
        /// False while a requested peer leader is still connecting or failed
        /// to launch. A placeholder pane may exist locally, but it must never
        /// receive leader instructions as if it were a running CLI.
        var leaderReady: Bool = true
        var leaderFailureDescription: String? = nil
        let workingDirectory: String
        let workspaceId: UUID     // agent workspace (may differ from leader workspace in "adopted" mode)
        var agents: [AgentMember]
        let createdAt: Date
        var gitRepoRoot: String?  // for worktree cleanup
        var worktreeMode: String  // "off", "shared", "isolated"
        var sharedWorktreeName: String?
        var sharedWorktreePath: String?
        var sharedWorktreeBranch: String?
        /// Stable team UUID used by the daemon for archive identity.
        /// - Pane-mode: Swift generates this at team creation (createTeam) so
        ///   archive_pane → resume_pane → destroy round-trips use the same
        ///   uuid. Without it, the daemon falls back to grace mode and
        ///   produces a fresh archive per cycle (D1/D2 same-uuid replacement
        ///   degrades).
        /// - Headless: backfilled from `headless.create_team` /
        ///   `headless.resume_team` result (line ~1085).
        var teamUuid: String? = nil

        // GUI pair-programming companion: a second pane spawned next to the
        // leader running a different CLI ("none" = no pair). The pair is not
        // a member of `agents` and is not addressable via tm-agent; it lives
        // alongside the leader purely so the user can drive two CLIs in
        // parallel from one team.
        var pairMode: String = "none"   // "none", "claude", "kiro", "codex", "gemini"
        var pairModel: String = ""
        var pairPanelId: UUID? = nil
        /// Team-wide auto-recycle default: recycle an agent every N completed tasks.
        /// nil = disabled; per-agent autoRecycleEvery overrides this.
        var defaultAutoRecycleEvery: Int? = nil
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

    /// Install the pane that replaced a temporary local leader. Kept on the
    /// owning type because `teams` is intentionally read-only to extensions.
    func replaceLeaderEndpoint(
        teamName: String,
        panelID: UUID,
        endpoint: LeaderEndpoint
    ) {
        guard var team = teams[teamName] else { return }
        team.leaderPanelId = panelID
        team.leaderWorkspaceId = nil
        team.leaderEndpoint = endpoint
        team.leaderReady = true
        team.leaderFailureDescription = nil
        teams[teamName] = team
        syncTeamStateToDaemon()
    }

    func markRemoteLeaderFailed(teamName: String, description: String) {
        guard var team = teams[teamName] else { return }
        team.leaderReady = false
        team.leaderFailureDescription = description
        teams[teamName] = team
        if let located = AppDelegate.shared?.locateSurface(surfaceId: team.leaderPanelId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) {
            workspace.setPanelCustomTitle(
                panelId: team.leaderPanelId,
                title: "⚠ Remote leader failed"
            )
        }
        syncTeamStateToDaemon()
    }
    // Round-robin counter per "teamName/agentName" key — cycles across duplicate-named agents.
    private var agentSendRoundRobin: [String: Int] = [:]
    // Last paste target awaiting a separate Return, keyed by "teamName/agentName".
    // Needed when duplicate-named agents are round-robined: the follow-up
    // team.send_key must hit the pane that received the text, not the first name match.
    private var pendingReturnTargets: [String: AgentPaneIdentity] = [:]

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
    /// Codable: persisted verbatim by `TeamDataStore` board snapshots
    /// (Restore Fleet Layer 2) — see
    /// docs/design/restore-fleet-session-persistence.md §3.2.
    struct TeamTask: Codable {
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
        var resultPath: String? = nil
        var worktreePolicy: String? = nil
        var worktreePath: String? = nil
        var worktreeBranch: String? = nil
        var worktreeParent: String? = nil
        var worktreeCreated: Bool? = nil
        var worktreeReused: Bool? = nil
        var worktreeInit: String? = nil
        var worktreeFinishedAt: Date? = nil
        var worktreeFinishMode: String? = nil
        var worktreeRemoved: Bool? = nil
        let createdAt: Date
        var updatedAt: Date
        var startedAt: Date?
        var completedAt: Date?
        var lastProgressAt: Date?
    }

    /// Injected daemon service (defaults to singleton for backward compatibility).
    var daemon: any DaemonService = TermMeshDaemon.shared

    private(set) var messages: [String: [TeamMessage]] = [:]   // team_name → messages
    /// Published because the board reads it. Without this a task could be
    /// created, assigned, worked and finished while every view showing the
    /// task board sat unchanged — the data was right and nothing was ever told
    /// to look at it again.
    @Published private(set) var taskBoards: [String: [TeamTask]] = [:]    // team_name → tasks
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
            "TERMMESH_CLI": agentCli,
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

        // For claude panes: register an FSEventStream watcher on
        // `~/.claude/projects/<encoded-workdir>/` so the real Claude session
        // id (written to <sid>.jsonl) can be captured asynchronously and
        // back-filled into `claudeSessionId`. Other CLIs skip this — they
        // don't write into ~/.claude/projects/.
        if agentCli == "claude" {
            ClaudeSessionWatcher.shared.bindIfNeeded()
            ClaudeSessionWatcher.shared.registerPendingClaudePane(
                teamName: teamName,
                agentName: agentName,
                workDir: agentWorkDir
            )
        }

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
            claudeSessionId: nil,
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
        agents: [(name: String, cli: String, model: String, agentType: String, color: String, instructions: String, customInstructions: String)],
        workingDirectory: String,
        leaderSessionId: String,
        leaderMode: String = "repl",
        leaderModel: String = "sonnet",
        leaderCli: String = "claude",
        pairMode: String = "none",
        pairModel: String = "",
        pairSpec: String = "",
        resumeSessionId: String? = nil,
        worktreeMode: String = "off",
        executionMode: String = "pane",
        leaderEndpoint: LeaderEndpoint = .local,
        launchLeaderLocally: Bool = true,
        adoptedLeaderSurfaceId: UUID? = nil,
        skipRunbookPromptForInteractiveAgents: Bool = false,
        /// Phase 2 (pane-mode resume): agent name → claude session id, used to
        /// invoke each agent CLI with `--resume <sid>`. Pane-mode resume passes
        /// this; fresh team creation leaves it nil.
        agentResumeSessionIds: [String: String]? = nil,
        tabManager: TabManager
    ) -> Team? {
        // A team may start with no agents but its leader. That is the normal
        // opening state when someone enters a project to work in it: they talk
        // to the leader, and the leader adds whoever the work turns out to
        // need. Requiring agents up front forced a guess about the work before
        // anyone had described it — and left an idle pane burning context when
        // the guess was wrong.
        //
        // Adopted mode is the exception: it contributes no pane of its own, so
        // a team with neither a leader pane nor an agent would have nothing in
        // it at all.
        guard !agents.isEmpty || leaderMode != "adopted" else { return nil }

        // Pair = `/watch` entry point. When the GUI selects a pair CLI,
        // prepend a watcher-role agent at index 0 so the existing grid
        // places it as `[Leader | Watcher | …]` on the top row. The
        // watcher runbook (AgentRolePreset.swift:955) wires `/watch
        // review|on|status` and the daemon's watch_controller without
        // further setup. Pair eligibility mirrors the GUI guard.
        let pairEligible = leaderMode != "repl"
            && leaderMode != "adopted"
            && pairMode != "none"
            && executionMode == "pane"
        var agents = agents
        if pairEligible {
            let watcherInstructions = AgentRolePresetManager.builtInPresets.first { $0.name == "watcher" }?.instructions ?? ""
            let watcherModel = pairModel.isEmpty ? "sonnet" : pairModel
            let watcherTuple: (name: String, cli: String, model: String, agentType: String, color: String, instructions: String, customInstructions: String) = (
                name: "watcher",
                cli: pairMode,
                model: watcherModel,
                agentType: "watcher",
                color: "yellow",
                instructions: watcherInstructions,
                customInstructions: pairSpec
            )
            agents.insert(watcherTuple, at: 0)
        }

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
        // The workspace is this team's, and the team's name is the project's.
        // Declared here rather than at the New Project sheet because every
        // route that makes a team makes the same fact — and because the
        // sidebar's other way of knowing, reading the panes' directories,
        // cannot see a project whose work is on another machine.
        WorkspaceProjectNames.shared.declare(workspaceId: workspace.id, projectName: name)

        if executionMode == "headless" {
            // "0 headless" would be a strange thing to read on a tab; a team
            // that is only its leader is described by its name alone.
            let suffix = agents.isEmpty ? "" : " \(agents.count) headless"
            workspace.customTitle = "[\(name)]\(suffix)"
            workspace.title = "[\(name)]\(suffix)"
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
        var detectedLeaderCli: String? = nil

        if !launchLeaderLocally {
            leaderWorkspaceId = nil
            leaderPanelId = defaultPanelId
            switch leaderMode {
            case "claude": detectedLeaderCli = "claude"
            case "codex": detectedLeaderCli = "codex"
            case "kiro": detectedLeaderCli = "kiro"
            case "gemini": detectedLeaderCli = "gemini"
            default: detectedLeaderCli = nil
            }
            workspace.setPanelCustomTitle(
                panelId: leaderPanelId,
                title: "Connecting remote leader…"
            )
        } else if leaderMode == "adopted" {
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

            // Use leader_cli parameter if provided; otherwise detect from panel displayTitle
            if !leaderCli.isEmpty && leaderCli != "claude" {
                detectedLeaderCli = leaderCli
            } else {
                // Fallback: detect adopted leader's CLI from its panel displayTitle
                if let located = AppDelegate.shared?.locateSurface(surfaceId: adoptedSurfaceId),
                   let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                   let panel = workspace.panels[adoptedSurfaceId] as? TerminalPanel {
                    let titleLower = panel.displayTitle.lowercased()
                    // "gpt-" indicates an OpenAI/Codex model (e.g. "gpt-5") — treat as codex,
                    // consistent with the isCodexLikePane title fallback. Gemini matches "gemini" only.
                    if titleLower.contains("codex") || titleLower.contains("gpt-") {
                        detectedLeaderCli = "codex"
                    } else if titleLower.contains("kiro") {
                        detectedLeaderCli = "kiro"
                    } else if titleLower.contains("claude") {
                        detectedLeaderCli = "claude"
                    } else if titleLower.contains("gemini") {
                        detectedLeaderCli = "gemini"
                    }
                }
            }

            #if DEBUG
            dlog("[team] adopted mode: leaderPanelId=\(adoptedSurfaceId.uuidString.prefix(8)) leaderWorkspaceId=\(leaderWorkspaceId?.uuidString.prefix(8) ?? "nil") leaderCli=\(detectedLeaderCli ?? "nil") (from_param=\(!leaderCli.isEmpty))")
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
                // Quoted, because all three parts can contain a space and this
                // string is handed to a shell. The app bundle is the one that
                // bites: `term-mesh DEV.app` splits into `…/Debug/term-mesh`
                // plus arguments — and that path is a real file, the CLI, so
                // the shell runs it, it prints `Unknown command: DEV`, and
                // exits. The leader pane dies half a second after opening.
                //
                // A team with agent panes survives that, which is why it went
                // unnoticed: the workspace still has something in it. A team
                // whose members are all on another machine has nothing else
                // yet, so the workspace closes with the leader and the team
                // has nowhere to attach to.
                leaderCommand = scriptPath.map {
                    "\(Self.shellQuoted($0)) \(Self.shellQuoted(socketPath)) \(Self.shellQuoted(name))"
                }
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
                        claudeLeaderParts.append("--model '\(Self.resolveClaudeModelArg(leaderModel))'")
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

            // Set detectedLeaderCli for non-adopted modes
            switch leaderMode {
            case "claude": detectedLeaderCli = "claude"
            case "codex": detectedLeaderCli = "codex"
            case "kiro": detectedLeaderCli = "kiro"
            case "gemini": detectedLeaderCli = "gemini"
            default: detectedLeaderCli = nil
            }
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
                    customInstructions: a.customInstructions.isEmpty ? nil : a.customInstructions,
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
                    customInstructions: agent.customInstructions.isEmpty ? nil : agent.customInstructions,
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
                    claudeSessionId: nil,
                    createdAt: Date(),
                    worktreeName: nil,
                    worktreePath: nil,
                    worktreeBranch: nil,
                    originalSpawnCommand: nil, // headless — daemon owns subprocess
                    originalAgentWorkDir: nil
                )
                headlessMembers.append(member)
            }

            // Set detectedLeaderCli for headless modes if not already set
            if detectedLeaderCli == nil {
                switch leaderMode {
                case "claude": detectedLeaderCli = "claude"
                case "codex": detectedLeaderCli = "codex"
                case "kiro": detectedLeaderCli = "kiro"
                case "gemini": detectedLeaderCli = "gemini"
                default: detectedLeaderCli = nil
                }
            }

            var team = Team(
                id: name,
                leaderSessionId: leaderSessionId,
                leaderMode: leaderMode,
                leaderModel: leaderModel,
                leaderCli: detectedLeaderCli,
                leaderPanelId: leaderPanelId,
                leaderWorkspaceId: leaderWorkspaceId,
                leaderEndpoint: leaderEndpoint,
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
            team.leaderReady = launchLeaderLocally
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
                    customInstructions: agent.customInstructions.isEmpty ? nil : agent.customInstructions,
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

        // Surface the watcher's role in the pane title so the user sees it as
        // "Pair · Watcher" rather than a generic agent. The watcher always
        // occupies members[0] when pair is eligible (insert(at: 0) above).
        if pairEligible, let watcherPanelId = members.first?.panelId {
            workspace.setPanelCustomTitle(
                panelId: watcherPanelId,
                title: "🤝 Pair · Watcher (\(pairMode.capitalized))"
            )
        }

        // Equalize splits multiple times: bonsplit needs layout passes to settle.
        // First pass immediate, then delayed passes for robustness.
        for delay in [0.05, 0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.equalizeAgentGrid(workspace: workspace)
            }
        }

        // D3-A P1-A: fresh pane teams must carry a stable teamUuid from
        // creation. Without it, archive_pane sends an empty team_uuid and
        // the daemon's same-uuid replacement (D1/D2) degrades into grace
        // mode — each destroy/resume cycle produces a fresh archive instead
        // of overwriting the prior one. Headless teams skip this branch and
        // get their uuid backfilled by `headless.create_team` (line ~1085).
        let paneTeamUuid = UUID().uuidString
        var team = Team(
            id: name,
            leaderSessionId: leaderSessionId,
            leaderMode: leaderMode,
            leaderModel: leaderModel,
            leaderCli: detectedLeaderCli,
            leaderPanelId: leaderPanelId,
            leaderWorkspaceId: leaderWorkspaceId,
            leaderEndpoint: leaderEndpoint,
            workingDirectory: workingDirectory,
            workspaceId: workspace.id,
            agents: members,
            createdAt: Date(),
            gitRepoRoot: gitRepoRoot,
            worktreeMode: worktreeMode,
            sharedWorktreeName: sharedWtName,
            sharedWorktreePath: sharedWtPath,
            sharedWorktreeBranch: sharedWtBranch,
            teamUuid: paneTeamUuid,
            pairMode: pairEligible ? pairMode : "none",
            pairModel: pairEligible ? pairModel : "",
            pairPanelId: pairEligible ? members.first?.panelId : nil
        )
        team.leaderReady = launchLeaderLocally
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
        customInstructions: String? = nil,
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
            // First attach: register workspace-local team with caller pane as adopted leader.
            // D3-A P1-A (extension): assign a stable teamUuid at creation so
            // archive_pane carries the same identity across destroy/resume —
            // mirrors the createTeam fix at line ~1319.

            // Detect adopted leader's CLI from its panel displayTitle
            var leaderCli: String? = nil
            if let panel = workspace.panels[callerPanelId] as? TerminalPanel {
                let titleLower = panel.displayTitle.lowercased()
                // "gpt-" indicates an OpenAI/Codex model (e.g. "gpt-5") — treat as codex,
                // consistent with the isCodexLikePane title fallback. Gemini matches "gemini" only.
                if titleLower.contains("codex") || titleLower.contains("gpt-") {
                    leaderCli = "codex"
                } else if titleLower.contains("kiro") {
                    leaderCli = "kiro"
                } else if titleLower.contains("claude") {
                    leaderCli = "claude"
                } else if titleLower.contains("gemini") {
                    leaderCli = "gemini"
                }
            }

            team = Team(
                id: teamName,
                leaderSessionId: "leader-attach-\(UUID().uuidString.prefix(8))",
                leaderMode: "adopted",
                leaderModel: "sonnet",
                leaderCli: leaderCli,
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
                sharedWorktreeBranch: nil,
                teamUuid: UUID().uuidString
            )
        }

        let effectiveInstructions = AgentRunbookService.shared.composeInstructions(
            roleName: agentType,
            presetInstructions: instructions,
            customInstructions: (customInstructions?.isEmpty ?? true) ? nil : customInstructions,
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
        force: Bool = true,
        /// When true, a last-agent detach preserves the (now empty) team record
        /// — its `workspaceId`/`leaderPanelId` stay intact — instead of removing
        /// it. Lets a following `addAgentToTeam` re-create the watcher pane by
        /// splitting from the preserved leader pane (used by `watch doctor`'s
        /// create-branch phantom repair so `remove`+`add` is symmetric with the
        /// `ws-*` `detach`+`attach` self-recreation path). Defaults to false so
        /// every existing caller keeps the original destroy-on-last behavior.
        keepTeamIfEmpty: Bool = false
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

        // D3-A P2 (b): release any pending claude-sid watcher slot so the
        // FSEventStream tears down promptly. Safe to call regardless of cli.
        if agent.cli == "claude" {
            let workDir = agent.worktreePath ?? agent.originalAgentWorkDir ?? team.workingDirectory
            ClaudeSessionWatcher.shared.unregisterPendingClaudePane(
                teamName: teamName,
                agentName: agentName,
                workDir: workDir
            )
        }

        // Close the pane if the workspace still exists.
        // `Workspace.closePanel` is idempotent — returns false if the panel
        // has already been closed (user-initiated or otherwise), which we
        // treat as successful detach.
        // TODO: when force=false, check daemon task state for agent_busy before closing
        let workspace = tabManager.tabs.first { $0.id == team.workspaceId }
        if agent.hostKey != nil {
            // A remote agent leaves a process behind on someone else's
            // machine, and the only way to reach it is through the pane — so
            // the pane has to outlive the interrupt. `releaseRemoteAgent`
            // closes it once that is done.
            releaseRemoteAgent(agent, closing: workspace)
        } else if let workspace, let pid = agent.panelId {
            _ = workspace.closePanel(pid, force: force)
        }

        // Remove from team.agents
        team.agents.remove(at: agentIndex)
        let remaining = team.agents.count

        if remaining == 0 {
            if keepTeamIfEmpty {
                // Preserve the now-empty team record (workspaceId + leaderPanelId
                // intact) so a following addAgentToTeam can re-create the watcher
                // pane from the preserved leader. The team is briefly visible with
                // agent_count 0 in status/daemon sync until the add fills it.
                teams[teamName] = team
                TeamDataStore.shared.registerTeam(teamName, agentNames: [])
                syncTeamStateToDaemon()
                Logger.team.info("detached last agent '\(agentName, privacy: .public)' from team '\(teamName, privacy: .public)' — empty team preserved (keepTeamIfEmpty)")
                return .success(DetachResult(
                    teamName: teamName,
                    agentName: agentName,
                    remainingAgents: 0,
                    teamDestroyed: false
                ))
            }
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
        agentCli: String,
        customInstructions: String? = nil
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
            customInstructions: (customInstructions?.isEmpty ?? true) ? nil : customInstructions,
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

    /// A string a shell will read back as exactly one argument.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        if !withReturn, let identity = agentIdentity(for: agent) {
            pendingReturnTargets[teamAgentKey] = identity
            scheduleOwedReturn(teamName: teamName, agentName: agentName, panelId: pid)
        }
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
    /// When `recordPendingReturnFor` is set and `withReturn` is false, records the
    /// pasted pane as the pending Return target keyed by "<team>/<agentName>" so a
    /// separate team.send_key Return lands on the SAME pane (used by panel-targeted
    /// team.send / team.delegate for deterministic duplicate-name addressing).
    @discardableResult
    func sendToAgentByPanel(teamName: String, panelId: UUID, workspaceId: UUID, text: String, tabManager: TabManager, withReturn: Bool = true, recordPendingReturnFor agentName: String? = nil, completion: ((Bool) -> Void)? = nil) -> Bool {
        if !withReturn,
           let agentName,
           let team = teams[teamName],
           let agent = team.agents.first(where: { $0.panelId == panelId && $0.name == agentName }),
           let identity = agentIdentity(for: agent) {
            pendingReturnTargets["\(teamName)/\(agentName)"] = identity
            scheduleOwedReturn(teamName: teamName, agentName: agentName, panelId: panelId)
        }
        // When an agentName is provided (panel-targeted send/delegate, incl. /tm
        // fan-out), mirror sendToAgent's in-flight accounting so a concurrent
        // name-keyed hard restart drains the paste before tearing the pane down,
        // instead of closing it mid-paste. Broadcast callers pass agentName=nil and
        // keep the original untracked fast path.
        let teamAgentKey = agentName.map { "\(teamName)/\($0)" }
        if let teamAgentKey { activeSends[teamAgentKey, default: 0] += 1 }
        return sendTextToPanel(workspaceId: workspaceId, panelId: panelId, text: text, tabManager: tabManager, withReturn: withReturn) { [weak self] sent in
            if let self, let teamAgentKey {
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

    /// Send text to an agent without requiring a tabManager.
    /// Uses AppDelegate.locateSurface to find the agent's panel across all windows.
    /// Bring an agent's pane to the front. Focusing where the work is running
    /// belongs here rather than in a view: the panel that owns it is a team
    /// fact, and more than one surface wants to point at it.
    @discardableResult
    func revealAgentPane(teamName: String, agentName: String) -> Bool {
        guard let team = teams[teamName],
              let agent = selectAgent(in: team.agents, name: agentName),
              let panelId = agent.panelId,
              let located = AppDelegate.shared?.locateSurface(surfaceId: panelId),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId })
        else { return false }
        located.tabManager.selectedTabId = workspace.id
        workspace.focusPanel(panelId)
        return true
    }

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
        guard let team = teams[teamName], team.leaderReady else { return false }
        if case .peer = team.leaderEndpoint {
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: team.leaderPanelId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let panel = workspace.terminalPanel(for: team.leaderPanelId),
                  let surface = panel.surface.surface
            else { return false }

            // Bracketed paste is unreliable when the viewer pane itself is a
            // peer relay: Ghostty can report the local paste drained while the
            // remote Claude composer never receives it. Socket-style key text
            // traverses the same relay reliably. Keep Return separate so the
            // relay PTY has time to flush the text before Claude submits it.
            let normalized = text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            TerminalController.shared.sendSocketText(normalized, surface: surface)
            panel.surface.forceRefresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.remoteLeaderReturnGap) {
                TerminalController.shared.sendNamedKeyWithRetry(
                    on: panel.surface,
                    keyName: "return"
                ) { _, _ in }
            }
            return true
        }
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
        panelId: UUID? = nil,
        completion: ((Bool) -> Void)? = nil
    ) -> DelegateResult? {
        let title = taskTitle?.nilIfBlank ?? String(text.prefix(80))
        // Task assignee stays the agent NAME even when delivery is panel-targeted —
        // panel_id is DELIVERY-ONLY so wait/collect/reports keyed on name are unaffected.
        guard let task = TeamDataStore.shared.createTask(
            teamName: teamName,
            title: title,
            assignee: agentName,
            priority: priority ?? 2
        ) else { return nil }
        let instruction = formatDelegateInstruction(task: task, text: text, context: context)
        // Deterministic per-pane delivery: when a valid, live, non-migrating panelId is
        // provided, bypass name round-robin (selectAgent) and paste directly into that
        // pane. The follow-up team.send_key Return carries the same panel_id (Rust side)
        // AND pendingReturnTargets is keyed to that exact pane.
        let teamAgentKey = "\(teamName)/\(agentName)"
        if let pid = panelId,
           !migratingAgents.contains(teamAgentKey),
           let team = teams[teamName],
           let agent = team.agents.first(where: { $0.panelId == pid && $0.name == agentName }) {
            // pendingReturnTargets is recorded inside sendToAgentByPanel via
            // recordPendingReturnFor when withReturn==false.
            let delivered = sendToAgentByPanel(
                teamName: teamName,
                panelId: pid,
                workspaceId: agent.workspaceId,
                text: instruction,
                tabManager: tabManager,
                withReturn: submit,
                recordPendingReturnFor: agentName,
                completion: completion
            )
            return DelegateResult(task: task, textDelivered: delivered, instruction: instruction)
        }
        // CLI callers keep submit=false and send Return separately after paste ack.
        // GUI callers can submit=true to use the IME paste path's inline Return.
        // No panelId (or stale/migrating) → name-based round-robin (backward compat).
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
        // The goal comes last and the reporting rule sits right after it,
        // because an agent reads a wall of protocol, finds a one-line ask at
        // the bottom, answers it and stops — which is exactly what happened
        // when the whole preamble came first.
        //
        // And printing the header IS enough: the scrollback detector
        // (AutoReplyDetector) watches every agent pane for it and completes
        // the task. The capsule used to say the opposite — "printing is NOT
        // enough" — which talked agents out of the one thing that reliably
        // works. Running the command is still offered, because it is exact,
        // but it is no longer presented as the only way.
        var lines: [String] = [
            "## Task Capsule",
            "TASK_ID: \(taskId)",
            "TASK_TITLE: \(task.title)",
            "TASK_STATUS: \(task.status)",
            "TASK_PRIORITY: \(task.priority)",
            "PROTOCOL: TM-PROTOCOL-v1",
            "OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus concise summary",
        ]
        if let path = task.worktreePath?.nilIfBlank {
            lines.append("WORKTREE_PATH: \(path)")
            if let branch = task.worktreeBranch?.nilIfBlank {
                lines.append("WORKTREE_BRANCH: \(branch)")
            }
            lines.append("WORKDIR_INSTRUCTION: Run commands from this worktree: cd \(path)")
            lines.append("NEXT_HINT: When code changes are ready, set NEXT to `tm-agent task finish-worktree \(taskId) --to parent --cleanup` or ask the leader to run it.")
        }
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
            "",
            "[HOW TO REPORT — required]",
            "Close your reply with these lines. term-mesh reads them off your",
            "pane and closes the task; without them it stays open and the",
            "leader waits.",
            "",
            "STATUS: DONE|BLOCKED|NEEDS_REVIEW",
            "FILES: <changed paths, space-separated, or none>",
            "VERIFY: <single shell command to verify the result, or n/a>",
            "NEXT: <one-line action for the leader, or NONE>",
            "FULL_REPORT: <path to a full result file, or n/a>",
            "",
            // Anything written above the header is not captured — the reply is
            // read from STATUS onward — so an answer put before it is lost to
            // everything but the pane. Asking for it after the header is what
            // puts the outcome on the board next to the task.
            "Then one last line: the answer or outcome in a sentence. Put it",
            "after the header, not before — text above STATUS is not captured.",
            "",
            "Running `tm-agent reply '<the same header>'` as a shell command",
            "does the same thing and is exact — either is fine.",
        ])
        return lines.joined(separator: "\n")
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
        if let path = task.worktreePath?.nilIfBlank {
            lines.append("Worktree: \(path)")
            if let branch = task.worktreeBranch?.nilIfBlank {
                lines.append("Branch: \(branch)")
            }
            lines.append("Run commands from this worktree: cd \(path)")
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
        if let path = task.worktreePath?.nilIfBlank {
            lines.append("")
            lines.append("WORKTREE_PATH: \(path)")
            if let branch = task.worktreeBranch?.nilIfBlank {
                lines.append("WORKTREE_BRANCH: \(branch)")
            }
            lines.append("WORKDIR_INSTRUCTION: Run commands from this worktree: cd \(path)")
            lines.append("NEXT_HINT: finish with `tm-agent task finish-worktree \(task.id) --to parent --cleanup` after reporting.")
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

        // Someone's unsent words are in the way. Pasting over them makes one
        // garbled prompt out of two thoughts, so the draft goes first — and
        // is said out loud, because it was a person's and it is being thrown
        // away. Ctrl+U only goes out when there is something to clear, which
        // keeps a stray control character off the normal path.
        if let draft = AutoReplyPoller.shared.composerDraft(panelId: panelId) {
            Logger.team.warning(
                "[sendTextToPanel] discarding unsent composer draft in \(panelId.uuidString.prefix(8), privacy: .public): \(draft, privacy: .public)"
            )
#if DEBUG
            dlog("composer.cleared panel=\(panelId.uuidString.prefix(8)) draft=\(draft.prefix(60).debugDescription)")
#endif
            TerminalController.shared.sendNamedKeyWithRetry(
                on: panel.surface,
                keyName: "ctrl-u"
            ) { _, _ in }
        }

        // A remote pane's composer is on another machine, and the inline form
        // puts 5ms between the text and the Return — generous for a local PTY,
        // nothing at all across a network. The Return arrives first and submits
        // an empty prompt while the words are still in flight. It happened to
        // work often enough to look fine, which is the worst way for a race to
        // behave. Same two keystrokes, far enough apart to arrive in order.
        if withReturn, panel.remoteHostKey != nil {
            let delivered = sendTextToPanel(
                workspaceId: workspaceId, panelId: panelId, text: text,
                tabManager: tabManager, withReturn: false, retryCount: retryCount
            ) { sent in
                guard sent else { completion?(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.remoteReturnGap) {
                    TerminalController.shared.sendNamedKeyWithRetry(
                        on: panel.surface, keyName: "return"
                    ) { ok, _ in completion?(ok) }
                }
            }
            return delivered
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

    /// True while a hard restart is migrating the named agent's pane. Panel-targeted
    /// callers use this to fall back to name-based delivery during migration windows.
    func isAgentMigrating(teamName: String, agentName: String) -> Bool {
        migratingAgents.contains("\(teamName)/\(agentName)")
    }

    /// Add a member to a team that already exists.
    ///
    /// `teams` stays `private(set)` — a roster that anything can assign to is
    /// how two views of a team drift apart. This is the one seam, so every
    /// addition also registers with the data store and the daemon, which a
    /// direct write would quietly skip.
    func adoptAgentMember(_ member: AgentMember, teamName: String) -> Bool {
        guard var team = teams[teamName] else { return false }
        guard !team.agents.contains(where: { $0.name == member.name }) else { return false }
        team.agents.append(member)
        teams[teamName] = team
        TeamDataStore.shared.registerTeam(teamName, agentNames: team.agents.map(\.name))
        syncTeamStateToDaemon()
        return true
    }

    func agentIdentity(teamName: String, agentName: String) -> AgentPaneIdentity? {
        guard let team = teams[teamName],
              let agent = team.agents.first(where: { $0.name == agentName }) else { return nil }
        return agentIdentity(for: agent)
    }

    func pendingReturnTarget(teamName: String, agentName: String) -> AgentPaneIdentity? {
        pendingReturnTargets["\(teamName)/\(agentName)"]
    }

    /// How long to leave between text and Return on a remote pane, so they
    /// arrive in that order. Well past a peer round trip, well under the
    /// unsubmitted-paste deadline below.
    private static let remoteReturnGap: TimeInterval = 1.5
    private static let remoteLeaderReturnGap: TimeInterval = 5.0

    /// How long a paste may sit unsubmitted before this side presses Return.
    ///
    /// Generous on purpose: the CLI's own follow-up lands in about a tenth of
    /// a second, so this never races it — it only catches the case where the
    /// second half never comes at all.
    private static let owedReturnGrace: TimeInterval = 4.0

    /// Press Return on a paste nobody came back to submit.
    ///
    /// `team.send`/`team.delegate` paste without Return by design: the CLI
    /// sends it separately once the paste is acknowledged, because firing it
    /// early truncates a long instruction. That makes submitting the work a
    /// two-party contract, and the second party is a different process. When
    /// it does not come — a caller that speaks the socket directly, a CLI that
    /// dies between the two calls — the capsule sits in the composer, the
    /// agent never starts, and the board shows `assigned` forever with no
    /// error anywhere. It has cost this project the same afternoon more than
    /// once.
    ///
    /// So the promise is kept from this side too. The owed Return is already
    /// recorded; this just gives it a deadline.
    private func scheduleOwedReturn(teamName: String, agentName: String, panelId: UUID) {
        let key = "\(teamName)/\(agentName)"
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.owedReturnGrace) { [weak self] in
            guard let self else { return }
            // Someone kept the promise, or the pane moved on to another paste.
            guard let owed = self.pendingReturnTargets[key], owed.panelId == panelId else { return }
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: panelId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let panel = workspace.terminalPanel(for: panelId) else {
                self.pendingReturnTargets.removeValue(forKey: key)
                return
            }
            self.pendingReturnTargets.removeValue(forKey: key)
#if DEBUG
            dlog("owedReturn.fire team=\(teamName) agent=\(agentName) panel=\(panelId.uuidString.prefix(8))")
#endif
            _ = panel.surface.sendIMEText("", withReturn: true)
        }
    }

    func clearPendingReturnTarget(teamName: String, agentName: String, panelId: UUID? = nil) {
        let key = "\(teamName)/\(agentName)"
        guard let panelId else {
            pendingReturnTargets.removeValue(forKey: key)
            return
        }
        if pendingReturnTargets[key]?.panelId == panelId {
            pendingReturnTargets.removeValue(forKey: key)
        }
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
        // Use panelId-based key when available so duplicate-named agents each get
        // their own migration slot and don't block each other (P2-1 fix).
        let teamAgentKey = disambiguatePanelId.map { "\(teamName)/\($0.uuidString)" }
            ?? "\(teamName)/\(agentName)"
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
        // Authoritative completedTaskCount reset: mirror headless recycle (mod.rs:1658).
        // Both single (recycleAgent) and bulk (recycleAllAgents) paths go through here,
        // so no external post-restart reset is needed or correct.
        var memberToSwap = newMember
        memberToSwap.completedTaskCount = 0
        team.agents[idx] = memberToSwap
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

    /// Recycle an agent pane: guard on active task status, then hard-restart.
    /// Mirrors `run_recycle` in the CLI (commit 3cabe882).
    func recycleAgent(teamName: String, agentName: String, force: Bool) {
        #if DEBUG
        dlog("autoRecycle.recycle teamName=\(teamName) agentName=\(agentName) force=\(force)")
        #endif
        let safeStatuses: Set<String> = ["blocked", "review_ready", "completed", "abandoned", "failed"]
        if !force, let task = activeTask(for: teamName, agentName: agentName),
           !safeStatuses.contains(task.status) {
            #if DEBUG
            dlog("autoRecycle.skip reason=active_task_unsafe teamName=\(teamName) agentName=\(agentName) taskId=\(task.id) status=\(task.status)")
            #endif
            let alert = NSAlert()
            alert.messageText = "Cannot recycle \(agentName)"
            alert.informativeText = "Active task \(task.id) is \(task.status). Use Force to bypass."
            alert.runModal()
            return
        }
        if force {
            Logger.team.warning("recycle --force on \(agentName, privacy: .public): discarding pane transcript")
        }
        Task { @MainActor in
            let result = await self.restartAgentPaneHard(teamName: teamName, agentName: agentName)
            #if DEBUG
            switch result {
            case .success(let pids):
                dlog("autoRecycle.restart teamName=\(teamName) agentName=\(agentName) oldPanel=\(pids.old.uuidString.prefix(8)) newPanel=\(pids.new.uuidString.prefix(8))")
            case .failure(let err):
                dlog("autoRecycle.restart.failed teamName=\(teamName) agentName=\(agentName) err=\(err)")
            }
            #endif
        }
    }

    /// Recycle all agents in a team. force=false skips agents with active non-terminal tasks.
    /// Returns (recycled, skipped) counts — skipped agents had an unsafe active task.
    ///
    /// Restarts are serialized (sequential await) to avoid concurrent stale Team
    /// struct write-backs (P2-2). Routing is by panelId so duplicate-named agents
    /// each recycle correctly (P2-1).
    @discardableResult
    func recycleAllAgents(teamName: String, force: Bool) -> (recycled: Int, skipped: Int) {
        guard let team = teams[teamName] else { return (0, 0) }
        let safeStatuses: Set<String> = ["blocked", "review_ready", "completed", "abandoned", "failed"]
        var toRecycle: [UUID] = []
        var skipped = 0
        for agent in team.agents {
            if !force, let task = activeTask(for: teamName, agentName: agent.name),
               !safeStatuses.contains(task.status) {
                skipped += 1
                continue
            }
            if let pid = agent.panelId {
                toRecycle.append(pid)
            }
        }
        Task { @MainActor in
            for panelId in toRecycle {
                await self.restartAgentPaneHard(panelId: panelId)
            }
        }
        return (toRecycle.count, skipped)
    }

    func setTeamDefaultAutoRecycle(teamName: String, every: Int) {
        guard var team = teams[teamName] else { return }
        team.defaultAutoRecycleEvery = every
        teams[teamName] = team
        #if DEBUG
        dlog("autoRecycle.setDefault teamName=\(teamName) every=\(every)")
        #endif
    }

    func setAgentAutoRecycle(teamName: String, agentId: String, every: Int) {
        guard var team = teams[teamName],
              let idx = team.agents.firstIndex(where: { $0.id == agentId }) else { return }
        team.agents[idx].autoRecycleEvery = every
        teams[teamName] = team
    }

    func setAgentAutoRecycleByName(teamName: String, agentName: String, every: Int) {
        guard var team = teams[teamName],
              let idx = team.agents.firstIndex(where: { $0.name == agentName }) else { return }
        team.agents[idx].autoRecycleEvery = every
        teams[teamName] = team
    }

    /// Called when an agent's task transitions to "completed". Increments the
    /// agent's completedTaskCount and triggers a guard recycle when the count
    /// reaches the effective threshold (agent override → team default → nil = off).
    func handleTaskCompletionForAutoRecycle(teamName: String, agentName: String) {
        guard var team = teams[teamName],
              let agentIdx = team.agents.firstIndex(where: { $0.name == agentName }) else {
            #if DEBUG
            dlog("autoRecycle.handleCompletion teamName=\(teamName) agentName=\(agentName) skip=team_or_agent_not_found")
            #endif
            return
        }
        team.agents[agentIdx].completedTaskCount += 1
        let count = team.agents[agentIdx].completedTaskCount
        let agentThreshold = team.agents[agentIdx].autoRecycleEvery
        let teamThreshold = team.defaultAutoRecycleEvery
        teams[teamName] = team
        #if DEBUG
        dlog("autoRecycle.handleCompletion teamName=\(teamName) agentName=\(agentName) count=\(count) agentThreshold=\(agentThreshold.map(String.init) ?? "nil") teamThreshold=\(teamThreshold.map(String.init) ?? "nil")")
        #endif
        guard let threshold = agentThreshold ?? teamThreshold, threshold > 0, count % threshold == 0 else {
            #if DEBUG
            dlog("autoRecycle.skip reason=threshold_not_met teamName=\(teamName) agentName=\(agentName) count=\(count) threshold=\(agentThreshold ?? teamThreshold ?? 0)")
            #endif
            // Not recycling → the agent is now idle and ready. Pull the next task
            // from the UNASSIGNED work-pool and push it, so a populated pool drains
            // itself without the leader re-broadcasting `tm-agent claim` after every
            // wave. This is the self-sustaining parallel loop (finish → auto-claim
            // next → report). It is intentionally NOT done on the recycle branch,
            // because recycleAgent hard-restarts the pane (drops context) and a task
            // claimed into it would be interrupted by the restart.
            autoClaimNext(teamName: teamName, agentName: agentName)
            return
        }
        recycleAgent(teamName: teamName, agentName: agentName, force: false)
    }

    /// Continuous work-stealing: when an agent finishes a task (and is not being
    /// recycled), atomically claim the next task from the team's UNASSIGNED pool
    /// and push it to that agent. Returns silently when the pool is empty or all
    /// remaining tasks have unmet dependencies.
    ///
    /// Scope & safety: this only ever consumes tasks with `assignee == nil`.
    /// Directed `delegate`/`fan-out` workflows create tasks already ASSIGNED to a
    /// specific agent, so the unassigned pool is empty there and this is a no-op —
    /// it never steals work from, or interferes with, leader-controlled dispatch.
    /// It activates exactly for the work-pool pattern (`task create` unassigned),
    /// turning "leader broadcasts `tm-agent claim` every wave" into "idle agents
    /// drain the pool on their own".
    ///
    /// Duplicate-named caveat: the push routes by agent NAME via `notifyTaskCreated`
    /// → `selectAgent` round-robin. For the common case of uniquely-named agents
    /// this targets the exact pane that just freed up. When several panes share a
    /// name, round-robin may push to a sibling pane; correct per-pane addressing
    /// needs the panel_id field tracked as the Tier-3 BUG-2 fix.
    private func autoClaimNext(teamName: String, agentName: String) {
        guard let claimed = TeamDataStore.shared.claimTask(teamName: teamName, agentName: agentName) else {
            return  // empty pool or all deps unmet — nothing to pull
        }
        #if DEBUG
        dlog("[autoClaimNext] team=\(teamName) agent=\(agentName) claimed task=\(claimed.id.prefix(8)) title=\(claimed.title.prefix(40))")
        #endif
        // Push via the auto-locating sender: it makes exactly one selectAgent
        // (round-robin) decision and resolves the owning tabManager itself through
        // AppDelegate.locateSurface, so it reaches the pane even for multi-window
        // teams without a second, possibly-divergent agent lookup.
        let instruction = formatTaskAssignmentInstruction(task: claimed)
        let pushed = sendToAgentAutoLocate(teamName: teamName, agentName: agentName, text: instruction)
        if !pushed {
            // Delivery failed (pane gone / migrating) — release the task so another
            // idle agent (or a manual claim) can pick it up instead of it sitting
            // assigned-but-undelivered.
            _ = TeamDataStore.shared.reassignTask(teamName: teamName, taskId: claimed.id, assignee: nil)
            #if DEBUG
            dlog("[autoClaimNext] push FAILED task=\(claimed.id.prefix(8)) — returned to pool team=\(teamName) agent=\(agentName)")
            #endif
        }
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
            let leaderEndpoint: [String: Any] = switch team.leaderEndpoint {
            case .local:
                ["kind": "local"]
            case let .peer(hostKey):
                ["kind": "peer", "host_key": hostKey]
            }
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
                        // Mission Control: separate boolean rather than a new
                        // agent_state value — tm-agent hard-matches
                        // agent_state == "idle" for delegation eligibility, so
                        // the state machine's values stay stable.
                        "waiting_input": agentIsWaitingInput(agent),
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
                "leader_panel_id": team.leaderPanelId.uuidString,
                "leader_endpoint": leaderEndpoint,
                "leader_ready": team.leaderReady,
                "leader_failure": team.leaderFailureDescription as Any? ?? NSNull(),
            ] as [String: Any]
        }
    }

    private func daemonPayload() -> [String: Any] {
        let teamData = listTeams()
        // Tasks live in TeamDataStore — that is where `tm-agent`, the socket
        // handlers and the agents themselves write, and what `team.task.list`
        // and `team.status` read back. This used to read the orchestrator's own
        // `taskBoards`, which nothing on those paths writes, so every view fed
        // by `fleetState` — the review board above all — showed an empty task
        // list while work was being created, assigned and finished.
        //
        // `taskBoards` is still consulted for anything recorded through the
        // orchestrator directly, and duplicates are dropped by id.
        let teamTasks = teamData.flatMap { team -> [[String: Any]] in
            guard let teamName = team["team_name"] as? String else { return [] }
            var seen = Set<String>()
            let stored = TeamDataStore.shared.listTasks(teamName: teamName)
            return (stored + listTasks(teamName: teamName)).compactMap { task in
                guard seen.insert(task.id).inserted else { return nil }
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

    /// Mission Control: "waiting for input" signal — the agent pane has an
    /// unread terminal notification (permission prompt, completed-turn bell,
    /// OSC 9/777). Notification `surfaceId`s share the bonsplit panel-id
    /// space (`TabManager.focusedSurfaceId(for:)` returns
    /// `focusedPanelId(for:)`), so the member's `panelId` addresses its
    /// pane's notifications directly. Headless agents (no pane) are never
    /// waiting on UI input.
    private func agentIsWaitingInput(_ agent: AgentMember) -> Bool {
        guard let panelId = agent.panelId else { return false }
        return TerminalNotificationStore.shared.hasUnreadNotification(
            forTabId: agent.workspaceId, surfaceId: panelId
        )
    }

    /// Mission Control aggregator — one call returns everything the mission
    /// dashboard preset renders: teams (with per-agent state / waiting_input /
    /// heartbeats), the full task board, the attention inbox, and the derived
    /// approval queue (`review_ready` tasks; worktree-backed ones carry their
    /// worktree fields for the future diff/approve card). Served via the v2
    /// `fleet.state` socket method and mirrored at the daemon's `/api/fleet`.
    /// Watch drift history is deliberately NOT aggregated here — it lives in
    /// the Rust daemon (`watch.board`), and blocking on a daemon round-trip
    /// inside an app-socket handler would violate the socket threading policy.
    func fleetState() -> [String: Any] {
        var payload = daemonPayload()
        payload["schema"] = 1
        let approvals = (payload["tasks"] as? [[String: Any]] ?? []).filter {
            ($0["status"] as? String) == "review_ready"
        }
        payload["approvals"] = approvals
        // x-kit panel runs (XK-EVENTS-v1) — instance-global, mirrored from the
        // daemon's xk_run bus into TeamDataStore. Carried on fleet.state so both
        // the WKWebView dashboard and the HTTP dashboard (/api/fleet proxy) get
        // it through one path.
        payload["panel_runs"] = TeamDataStore.shared.xkPanelRunsSnapshot()
        return payload
    }

    private func syncTeamStateToDaemon() {
        let payload = daemonPayload()
        DispatchQueue.global(qos: .utility).async {
            self.daemon.syncTeams(payload)
        }
        // Restore Fleet Layer 2: keep the data store's name→uuid map current
        // so board snapshots land under the right team identity on disk.
        TeamDataStore.shared.updateBoardUuids(
            teams.values.reduce(into: [String: String]()) { acc, t in
                if let uuid = t.teamUuid?.nilIfBlank { acc[t.id] = uuid }
            }
        )
        // Restore Fleet Layer 1: every daemon sync is also a signal that team
        // state changed — refresh the on-disk live snapshots (debounced,
        // hash-deduped) so a crash never loses more than the debounce window.
        scheduleLiveTeamSnapshots()
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
                    "waiting_input": agentIsWaitingInput(agent),
                    "heartbeat_age_seconds": heartbeatAgeSeconds(teamName: team.id, agentName: agent.name) as Any? ?? NSNull(),
                    "last_heartbeat_summary": heartbeat?.summary as Any? ?? NSNull(),
                    "heartbeat_is_stale": heartbeat.map(isHeartbeatStale) ?? false,
                    "workspace_id": agent.workspaceId.uuidString,
                ]
                info["completed_task_count"] = agent.completedTaskCount
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

        // D3-A P2 (b): release any pending claude-sid watcher slots so
        // FSEventStream(s) for this team's workdirs tear down promptly.
        for agent in team.agents where agent.cli == "claude" {
            let workDir = agent.worktreePath ?? agent.originalAgentWorkDir ?? team.workingDirectory
            ClaudeSessionWatcher.shared.unregisterPendingClaudePane(
                teamName: name,
                agentName: agent.name,
                workDir: workDir
            )
        }
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
    /// The **leader** pane resumes via `--resume <leader.session_id>` (wired
    /// through `createTeam`'s `resumeSessionId` parameter) and each claude
    /// agent resumes via `--resume <sid>` (wired through
    /// `agentResumeSessionIds` → `addAgentPaneToWorkspace`). Sids whose
    /// transcript jsonl no longer exists are dropped (fresh start) rather than
    /// letting the CLI error out at spawn — see the validity guard below.
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
        typealias AgentTuple = (name: String, cli: String, model: String, agentType: String, color: String, instructions: String, customInstructions: String)
        let agentTuples: [AgentTuple] = agentsArr.map { a in
            (
                name: (a["name"] as? String) ?? "agent",
                cli: (a["cli"] as? String) ?? "claude",
                model: (a["model"] as? String) ?? "sonnet",
                agentType: (a["agent_type"] as? String) ?? ((a["name"] as? String) ?? "agent"),
                color: (a["color"] as? String) ?? "blue",
                instructions: (a["instructions"] as? String) ?? "",
                // Resume archives already store the fully composed instructions
                // (effective-prompt marker present), so re-applying custom
                // instructions here would double-append. Always empty on resume.
                customInstructions: ""
            )
        }

        // Phase 2 (D3-A): per-agent Claude session IDs captured at archive
        // time via FSEventStream-based sid discovery, stored in
        // AgentMember.claudeSessionId (NOT parentSessionId — that's the
        // term-mesh routing UUID). Passed into createTeam so each claude
        // agent CLI starts with `--resume <sid>` and re-attaches to its
        // previous transcript. Codex/kiro/gemini agents currently ignore
        // this; resume support for them is a follow-up.
        // `--resume` validity guard: a sid whose transcript jsonl is gone
        // would make the claude CLI error out at spawn. The leader always ran
        // in the team workdir; workers share it when worktreeMode == "off".
        // Worktree-isolated workers can't be verified here (their transcripts
        // live under each worktree's encoded dir), so their sids pass through
        // and degrade at the CLI level in the worst case.
        let sharedTranscriptDir = ClaudeSessionWatcher.encodedProjectDir(workDir: workingDirectory)
        func transcriptExists(_ sid: String) -> Bool {
            FileManager.default.fileExists(atPath: "\(sharedTranscriptDir)/\(sid).jsonl")
        }

        var agentResumeMap: [String: String] = [:]
        for a in agentsArr {
            guard let name = a["name"] as? String,
                  let sid = a["session_id"] as? String,
                  !sid.isEmpty else { continue }
            if archivedWorktreeMode == "off" && !transcriptExists(sid) {
                Logger.team.info("[pane-resume] dropping stale sid for agent '\(name, privacy: .public)' — transcript missing, starting fresh")
                continue
            }
            agentResumeMap[name] = sid
        }

        // Fresh leader routing UUID for the new team (regenerated each create).
        let freshLeaderSessionId = UUID().uuidString

        // `leaderSessionId` from the archive is the REAL claude session id
        // (discovered from ~/.claude/projects/ at archive time). Passing it
        // as `--resume` re-attaches claude to its prior transcript.
        let leaderClaudeSid: String? = {
            guard !leaderSessionId.isEmpty else { return nil }
            guard transcriptExists(leaderSessionId) else {
                Logger.team.info("[pane-resume] dropping stale leader sid — transcript missing, starting fresh")
                return nil
            }
            return leaderSessionId
        }()

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
                // Same-run destroy → resume: lift the snapshot retirement so
                // the revived team persists live snapshots again.
                teamLiveSnapshotGate.revive(uuid: uuid)
                // Restore Fleet Layer 2: bring back the persisted task board
                // (in_progress tasks are normalized to assigned inside).
                TeamDataStore.shared.loadBoard(teamName: teamName, teamUuid: uuid)
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
                        // Store as claudeSessionId (the real Claude sid).
                        // parentSessionId stays as the term-mesh routing UUID.
                        m.claudeSessionId = sid
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
                claudeSessionId: nil,
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
            leaderCli: "claude",
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
        let dir = ClaudeSessionWatcher.encodedProjectDir(workDir: workingDirectory)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir),
              let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (sid: String, mtime: Date)?
        for item in items {
            guard item.hasSuffix(".jsonl") else { continue }
            let sid = String(item.dropLast(6))
            guard ClaudeSessionWatcher.isValidSid(sid) else { continue }
            let path = "\(dir)/\(item)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime {
                best = (sid, mtime)
            }
        }
        return best?.sid
    }

    /// D3-A: callback installed by `ClaudeSessionWatcher.bindIfNeeded()`
    /// when the first claude pane is spawned. Stamps the captured Claude sid
    /// onto the matching `AgentMember.claudeSessionId` and syncs daemon state.
    fileprivate func applyClaudeSessionId(teamName: String, agentName: String, sid: String) {
        guard var team = teams[teamName] else { return }
        guard let idx = team.agents.firstIndex(where: { $0.name == agentName }) else { return }
        if team.agents[idx].claudeSessionId == sid { return }
        team.agents[idx].claudeSessionId = sid
        team.agents[idx].claudeSessionIdCapturedAt = Date()
        teams[teamName] = team
        syncTeamStateToDaemon()
        #if DEBUG
        dlog("[claude.sid.captured] team=\(teamName) agent=\(agentName) sid=\(sid)")
        #endif
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
                if let sid = Self.resolvedAgentSessionId(
                    a, leaderSid: leaderSid, teamWorkingDirectory: team.workingDirectory
                ) {
                    row["session_id"] = sid
                }
                if !a.instructions.isEmpty {
                    row["instructions"] = a.instructions
                }
                return row
            },
        ]
        // D3-A: include the headless team_uuid so the backend can round-trip
        // a resumed team to the same archive on next destroy. Empty/nil is
        // accepted by the daemon's grace-mode parser, so we send the field
        // whenever it's known.
        if let uuid = team.teamUuid, !uuid.isEmpty {
            payload["team_uuid"] = uuid
        }
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
        // Retire the uuid BEFORE dispatching the archive write: any live
        // snapshot still queued behind us on `panePersistQueue` re-checks the
        // gate and skips, so a snapshot can never recreate the live dir after
        // the archive cleared it (ghost team in the crash-recovery picker).
        if let uuid = team.teamUuid?.nilIfBlank {
            teamLiveSnapshotGate.retire(uuid: uuid)
        }
        // Both archive and live-snapshot writes go through the same SERIAL
        // queue so their daemon RPCs can never reorder relative to each other.
        if synchronous {
            panePersistQueue.sync(execute: work)
        } else {
            panePersistQueue.async(execute: work)
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

    // ────────────────────────────────────────────────────────────────────────
    // Restore Fleet Layer 1 — live team snapshots
    //
    // `team.archive_pane` only runs at destroy/quit, so a crash used to lose
    // the team entirely. These snapshots write the same archive layout to the
    // daemon continuously (debounced, hash-deduped) with `live: true`, so the
    // last consistent team state is always on disk under
    // `~/.term-mesh/headless/<team_uuid>/`. See
    // docs/design/restore-fleet-session-persistence.md §3.1.
    // ────────────────────────────────────────────────────────────────────────

    /// Serial queue for ALL pane-persist daemon RPCs (live snapshots AND
    /// destroy/quit archives). Serializing them guarantees an archive can
    /// never be overtaken by an earlier-enqueued snapshot write.
    private let panePersistQueue = DispatchQueue(
        label: "com.termmesh.team.pane-persist", qos: .utility
    )
    private var liveSnapshotDebounce: DispatchWorkItem?
    private static let liveSnapshotDebounceInterval: TimeInterval = 1.0

    /// Debounce entry point — cheap to call on every team mutation (hooked in
    /// `syncTeamStateToDaemon`, which all mutation paths already funnel
    /// through).
    private func scheduleLiveTeamSnapshots() {
        liveSnapshotDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.snapshotLivePaneTeams()
        }
        liveSnapshotDebounce = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.liveSnapshotDebounceInterval, execute: item
        )
    }

    /// Snapshot every live pane-mode team whose persisted payload changed.
    /// Payload build (including the `~/.claude/projects` sid scan) runs on the
    /// main actor — same as the destroy-time archive path — and only the
    /// daemon RPC is shipped to the serial persist queue.
    private func snapshotLivePaneTeams() {
        let appVersion =
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let appSocketPath = SocketControlSettings.socketPath()
        for team in teams.values {
            // Mirror the archive skip rule: headless teams are persisted by
            // the daemon itself.
            let isHeadless = !team.agents.isEmpty && team.agents.allSatisfy { $0.panelId == nil }
            if isHeadless { continue }
            // Fresh pane teams carry a stable uuid since D3-A P1-A; teams
            // without one predate that and are skipped (they still archive at
            // destroy/quit via grace mode).
            guard let uuid = team.teamUuid?.nilIfBlank else { continue }
            let payload = Self.buildLiveSnapshotParams(
                team: team, appVersion: appVersion, appSocketPath: appSocketPath
            )
            guard let hash = Self.stableParamsHash(payload) else { continue }
            guard teamLiveSnapshotGate.shouldWrite(uuid: uuid, hash: hash) else { continue }
            panePersistQueue.async {
                // Re-check on the persist queue: a destroy may have retired
                // the uuid between the gate pass above and this write.
                guard teamLiveSnapshotGate.isWritable(uuid: uuid) else { return }
                let raw = TermMeshDaemon.shared.rpcCallRaw(
                    method: "team.snapshot_pane", params: payload
                )
                if let raw, let data = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errMsg = obj["error"] as? String {
                    Logger.team.warning("[snapshot_pane] daemon error: \(errMsg, privacy: .public)")
                }
            }
        }
    }

    /// `team.snapshot_pane` params. Superset of the `team.archive_pane`
    /// payload: adds `layout_workspace_title`, `app_socket_path` (instance
    /// isolation for restore candidates) and per-agent
    /// `session_id_captured_at` / `parked` / `auto_recycle_every` /
    /// `completed_task_count`.
    private static func buildLiveSnapshotParams(
        team: Team, appVersion: String, appSocketPath: String
    ) -> [String: Any] {
        let leaderSid = discoverClaudeSessionId(workingDirectory: team.workingDirectory) ?? ""
        var payload: [String: Any] = [
            "team_uuid": team.teamUuid ?? "",
            "team_name": team.id,
            "leader_session_id": leaderSid,
            "leader_mode": team.leaderMode,
            "leader_model": team.leaderModel,
            "working_directory": team.workingDirectory,
            "termmesh_app_version": appVersion,
            "layout_workspace_title": team.id,
            "app_socket_path": appSocketPath,
            "agents": team.agents.map { a -> [String: Any] in
                var row: [String: Any] = [
                    "name": a.name,
                    "cli": a.cli,
                    "model": a.model,
                    "agent_type": a.agentType,
                    "color": a.color,
                ]
                if let sid = resolvedAgentSessionId(
                    a, leaderSid: leaderSid, teamWorkingDirectory: team.workingDirectory
                ) {
                    row["session_id"] = sid
                }
                if let capturedAt = a.claudeSessionIdCapturedAt {
                    row["session_id_captured_at"] = Int(capturedAt.timeIntervalSince1970)
                }
                if !a.instructions.isEmpty {
                    row["instructions"] = a.instructions
                }
                if TeamDataStore.shared.isAgentParked(teamName: team.id, agentName: a.name) {
                    row["parked"] = true
                }
                if let every = a.autoRecycleEvery {
                    row["auto_recycle_every"] = every
                }
                if a.completedTaskCount > 0 {
                    row["completed_task_count"] = a.completedTaskCount
                }
                return row
            },
        ]
        // Keep the requested host placement in the live snapshot. The remote
        // bootstrap layer can attach its pane reference later without ever
        // guessing that a peer leader belongs to this Mac.
        payload["leader_endpoint"] = switch team.leaderEndpoint {
        case .local:
            ["kind": "local"]
        case let .peer(hostKey):
            ["kind": "peer", "host_key": hostKey]
        }
        if let root = team.gitRepoRoot?.nilIfBlank
            ?? TermMeshDaemon.shared.findGitRoot(from: team.workingDirectory) {
            payload["git_root"] = root
        }
        if let wtName = team.sharedWorktreeName,
           let wtPath = team.sharedWorktreePath,
           let wtBranch = team.sharedWorktreeBranch,
           !wtName.isEmpty {
            payload["worktree_mode"] = team.worktreeMode
            payload["worktree_path"] = wtPath
            payload["worktree_branch"] = wtBranch
        }
        return payload
    }

    /// Per-agent claude session id resolution shared by destroy-time archives
    /// and live snapshots — D3-A priority:
    ///   1. `claudeSessionId` captured at pane spawn by the FSEventStream
    ///      watcher (authoritative 1-to-1 mapping, works even when agents
    ///      share the team workdir).
    ///   2. `discoverClaudeSessionId(worktreePath)` fallback — only safe when
    ///      the agent has its own worktree distinct from the team workdir,
    ///      since mtime-based discovery in a shared dir returns the same
    ///      jsonl for every agent.
    ///   3. nil → daemon marks the team `no_sessions` rather than silently
    ///      corrupting on resume.
    /// Always rejects the leader sid as a collision guard (catches the
    /// freshly-created-worktree edge case where claude has not yet written a
    /// transcript and discovery falls through).
    private static func resolvedAgentSessionId(
        _ a: AgentMember, leaderSid: String, teamWorkingDirectory: String
    ) -> String? {
        if let captured = a.claudeSessionId?.nilIfBlank, captured != leaderSid {
            return captured
        }
        guard let wt = a.worktreePath, !wt.isEmpty, wt != teamWorkingDirectory,
              let sid = discoverClaudeSessionId(workingDirectory: wt),
              !sid.isEmpty, sid != leaderSid else { return nil }
        return sid
    }

    /// Deterministic hash of an RPC params dictionary (sorted-keys JSON), used
    /// to skip snapshot writes when nothing changed. nil when the payload is
    /// not JSON-encodable (never expected — all values are plist types).
    private static func stableParamsHash(_ params: [String: Any]) -> Int? {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(
                  withJSONObject: params, options: [.sortedKeys]
              ) else { return nil }
        return data.hashValue
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
            parts.append("--model '\(Self.resolveClaudeModelArg(model))'")
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

    /// Map term-mesh tier names to the exact `--model` argument Claude CLI expects.
    /// "opus" and legacy "opus-1m" both map to claude-opus-4-8[1m].
    static func resolveClaudeModelArg(_ model: String) -> String {
        switch model {
        case "opus", "opus-1m": return "claude-opus-4-8[1m]"
        default:                return model
        }
    }

    /// Map short model names (used internally) to kiro-cli model identifiers.
    private static func kiroModelName(_ shortName: String) -> String {
        switch shortName.lowercased() {
        case "opus":   return "claude-opus-4.8"
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

    static func colorEmoji(_ color: String) -> String {
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
    func writeResult(teamName: String, agentName: String, content: String, resultPath: String? = nil) -> Bool {
        let dir = Self.resultDirectory(teamName: teamName)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(agentName).result.json")
        var payload: [String: Any] = [
            "agent": agentName,
            "team": teamName,
            "content": content,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let rp = resultPath, !rp.isEmpty {
            payload["result_path"] = rp
        }
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
        // Leader-as-watch-target: the leader lives in `leaderPanelId`, outside the
        // `agents[]` array. Resolve it explicitly so `tm-agent read leader` and a
        // worker-less watch (`--target leader` or the all-target fallback) can
        // capture the leader's own pane. Only adopted leaders are readable (they
        // own a GUI pane); a purely headless leader has no pane to find here.
        if agentName == "leader" {
            // Adopted leaders carry an explicit workspace id; create-mode leaders
            // leave it nil but their pane still lives in one of the open tabs.
            if let wsId = team.leaderWorkspaceId,
               let ws = tabManager.tabs.first(where: { $0.id == wsId }),
               let panel = ws.terminalPanel(for: team.leaderPanelId) {
                return panel
            }
            for ws in tabManager.tabs {
                if let panel = ws.terminalPanel(for: team.leaderPanelId) { return panel }
            }
            return nil
        }
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
        createdBy: String = "leader",
        worktreePolicy: String? = nil
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
            worktreePolicy: worktreePolicy?.nilIfBlank,
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
        progressNote: String? = nil,
        worktreePolicy: String? = nil,
        worktreePath: String? = nil,
        worktreeBranch: String? = nil,
        worktreeParent: String? = nil,
        worktreeCreated: Bool? = nil,
        worktreeReused: Bool? = nil,
        worktreeInit: String? = nil,
        worktreeFinishedAt: Date? = nil,
        worktreeFinishMode: String? = nil,
        worktreeRemoved: Bool? = nil
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
        if let worktreePolicy { tasks[idx].worktreePolicy = worktreePolicy.nilIfBlank }
        if let worktreePath { tasks[idx].worktreePath = worktreePath.nilIfBlank }
        if let worktreeBranch { tasks[idx].worktreeBranch = worktreeBranch.nilIfBlank }
        if let worktreeParent { tasks[idx].worktreeParent = worktreeParent.nilIfBlank }
        if let worktreeCreated { tasks[idx].worktreeCreated = worktreeCreated }
        if let worktreeReused { tasks[idx].worktreeReused = worktreeReused }
        if let worktreeInit { tasks[idx].worktreeInit = worktreeInit.nilIfBlank }
        if let worktreeFinishedAt { tasks[idx].worktreeFinishedAt = worktreeFinishedAt }
        if let worktreeFinishMode { tasks[idx].worktreeFinishMode = worktreeFinishMode.nilIfBlank }
        if let worktreeRemoved { tasks[idx].worktreeRemoved = worktreeRemoved }
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
            case "completed", "failed", "abandoned", "cancelled":
                // Phase E Wave 1: "cancelled" terminates the task identically
                // to completed/failed/abandoned so the `activeTask` filter
                // drops it and the sidebar's active_task_id clears in the
                // same tick. syncTeamStateToDaemon() below re-publishes
                // agent_state for downstream consumers.
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
            "worktree_policy": task.worktreePolicy as Any? ?? NSNull(),
            "worktree_path": task.worktreePath as Any? ?? NSNull(),
            "worktree_branch": task.worktreeBranch as Any? ?? NSNull(),
            "worktree_parent": task.worktreeParent as Any? ?? NSNull(),
            "worktree_created": task.worktreeCreated as Any? ?? NSNull(),
            "worktree_reused": task.worktreeReused as Any? ?? NSNull(),
            "worktree_init": task.worktreeInit as Any? ?? NSNull(),
            "worktree_finish_mode": task.worktreeFinishMode as Any? ?? NSNull(),
            "worktree_removed": task.worktreeRemoved as Any? ?? NSNull(),
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
        if let worktreeFinishedAt = task.worktreeFinishedAt {
            dict["worktree_finished_at"] = ISO8601DateFormatter().string(from: worktreeFinishedAt)
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

    // ────────────────────────────────────────────────────────────────────────
    // Restore Fleet Layer 3 — crash-recovery detection + one-click restore
    //
    // Live snapshots (Layer 1) leave `~/.term-mesh/headless/<uuid>/` behind
    // when the app crashes. At launch we ask the daemon for those snapshots
    // (`headless.list_live_pane`), filter out teams that are already live in
    // this process, and surface the rest as restorable fleets — a sidebar
    // banner in `ask` mode, automatic restore in `always` mode.
    // ────────────────────────────────────────────────────────────────────────

    /// A crash-recoverable team found via `headless.list_live_pane`.
    struct RestorableFleet: Identifiable {
        var id: String { teamUuid }
        let teamUuid: String
        let teamName: String
        let agentCount: Int
        let lastSnapshotAt: Date?
        let workingDirectory: String
        let hasAnySession: Bool
    }

    /// Published for the sidebar banner (`SidebarFleetRestoreBanner`).
    @Published private(set) var restorableFleets: [RestorableFleet] = []
    /// Uuids the user dismissed this run — excluded from future detects.
    private var dismissedFleetUuids: Set<String> = []
    /// Restore re-entrancy guard.
    private var restoreInFlightUuids: Set<String> = []

    /// Scan for crash-recoverable live snapshots and publish them. In
    /// `always` mode each candidate immediately posts
    /// `.restoreFleetRequested` (handled where a `TabManager` is in scope).
    func detectRestorableFleets(attempt: Int = 0) {
        guard FleetRestoreMode.current != .never else { return }
        // The parse fix below is the real fix; testing shows a freshly-spawned
        // daemon is ready by launch+1.5s (restore succeeds on attempt 0). This
        // short retry is defense-in-depth only — for a cold or loaded daemon
        // that might briefly report an empty scan — and stops on the first
        // non-empty result, so the normal path runs exactly once.
        let maxAttempts = 3
        let params: [String: Any] = [
            "limit": 20,
            "app_socket_path": SocketControlSettings.socketPath(),
        ]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let raw = self.daemon.rpcCallRaw(method: "headless.list_live_pane", params: params)
            // `rpcCallRaw` already unwraps the JSON-RPC `result`, so `raw` is the
            // ListLivePaneResult payload itself (`{scanned, teams, ...}`). Parse
            // `teams` directly — the old `result.teams` double-unwrap always
            // yielded nil, so rows stayed 0 and restore was silently skipped on
            // every launch (not a daemon race — a client parse bug).
            var rows: [[String: Any]] = []
            if let raw, let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let teams = obj["teams"] as? [[String: Any]] {
                rows = teams
            }
            #if DEBUG
            // An empty scan from an RPC/parse failure is otherwise
            // indistinguishable from a legitimately empty result — the blind
            // spot that hid the double-unwrap bug. Surface the empty/nil path.
            if rows.isEmpty { dlog("restore.detect empty rawNil=\(raw == nil) attempt=\(attempt)") }
            #endif
            DispatchQueue.main.async {
                let liveUuids = Set(self.teams.values.compactMap { $0.teamUuid })
                let fleets: [RestorableFleet] = rows.compactMap { row in
                    guard let uuid = row["team_uuid"] as? String,
                          let name = row["team_name"] as? String,
                          !liveUuids.contains(uuid),
                          !self.dismissedFleetUuids.contains(uuid) else { return nil }
                    let ts = (row["last_snapshot_at"] as? Double) ?? 0
                    return RestorableFleet(
                        teamUuid: uuid,
                        teamName: name,
                        agentCount: ((row["agents"] as? [[String: Any]]) ?? []).count,
                        lastSnapshotAt: ts > 0 ? Date(timeIntervalSince1970: ts) : nil,
                        workingDirectory: (row["working_directory"] as? String) ?? "",
                        hasAnySession: (row["has_any_session"] as? Bool) ?? false
                    )
                }
                self.restorableFleets = fleets
                if fleets.isEmpty {
                    if attempt + 1 < maxAttempts {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.detectRestorableFleets(attempt: attempt + 1)
                        }
                    }
                    return
                }
                Logger.team.info("[restore-fleet] detected \(fleets.count) restorable fleet(s)")
                if FleetRestoreMode.current == .always {
                    for fleet in fleets {
                        NotificationCenter.default.post(
                            name: .restoreFleetRequested,
                            object: nil,
                            userInfo: ["team_uuid": fleet.teamUuid]
                        )
                    }
                }
            }
        }
    }

    /// Restore one fleet: `team.resume_pane` (which also resolves live
    /// snapshot dirs) → `adoptResumedPaneTeam` (workspace + panes +
    /// per-agent `--resume` + board reload). Mirrors the manual resume
    /// picker's flow (`TeamCreationView.invokeResume`).
    func restoreFleet(
        teamUuid: String,
        tabManager: TabManager,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        guard !restoreInFlightUuids.contains(teamUuid) else {
            completion?(false, "restore already in flight")
            return
        }
        restoreInFlightUuids.insert(teamUuid)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let raw = self.daemon.rpcCallRaw(
                method: "team.resume_pane", params: ["team_uuid": teamUuid]
            )
            var resultDict: [String: Any]?
            var errMsg: String?
            if let raw, let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let e = obj["error"] as? String {
                    errMsg = e
                } else if let r = obj["result"] as? [String: Any] {
                    resultDict = r
                } else {
                    resultDict = obj
                }
            } else {
                errMsg = "daemon did not respond"
            }
            DispatchQueue.main.async {
                self.restoreInFlightUuids.remove(teamUuid)
                if let errMsg {
                    Logger.team.warning("[restore-fleet] resume_pane failed uuid=\(teamUuid, privacy: .public): \(errMsg, privacy: .public)")
                    completion?(false, errMsg)
                    return
                }
                guard let resultDict,
                      let team = self.adoptResumedPaneTeam(result: resultDict, tabManager: tabManager)
                else {
                    Logger.team.warning("[restore-fleet] adopt failed uuid=\(teamUuid, privacy: .public)")
                    completion?(false, "adopt failed")
                    return
                }
                self.restorableFleets.removeAll { $0.teamUuid == teamUuid }
                Logger.team.info("[restore-fleet] restored team '\(team.id, privacy: .public)' (\(team.agents.count) agents)")
                completion?(true, nil)
            }
        }
    }

    /// Hide a fleet from the banner for the rest of this app run. The
    /// snapshot stays on disk (stale-snapshot GC handles eventual cleanup).
    func dismissRestorableFleet(teamUuid: String) {
        dismissedFleetUuids.insert(teamUuid)
        restorableFleets.removeAll { $0.teamUuid == teamUuid }
    }

    private func agentRuntimeState(teamName: String, agentName: String) -> String {
        // Phase 2: parked is daemon-authoritative — overrides task-derived state
        // because the subprocess is not live regardless of task board entry.
        if TeamDataStore.shared.isAgentParked(teamName: teamName, agentName: agentName) {
            return "parked"
        }
        // A pane that is printing is working, whatever the board says. A task
        // stays `assigned` from hand-off until the agent files a result, so on
        // the board alone an agent halfway through the work and an agent that
        // never started are the same thing — and the board showed both as
        // idle while the pane beside it scrolled.
        let paneIsWorking = teams[teamName]?
            .agents.first { $0.name == agentName }?
            .panelId
            .map { AutoReplyPoller.shared.isPaneActive(panelId: $0) } ?? false
        guard let task = activeTask(for: teamName, agentName: agentName) else {
            return paneIsWorking ? "running" : "idle"
        }
        // Phase E Wave 1: an assigned/queued task that has gone stale past the
        // threshold surfaces as `assigned_stale` so the sidebar can render an
        // amber/⏳ indicator. Daemon may also push the same label via an
        // anomaly event — both paths converge on this string. Fallback to
        // legacy switch keeps existing callers compatible.
        if (task.status == "assigned" || task.status == "queued") && isTaskStale(task) {
            return "assigned_stale"
        }
        switch task.status {
        case "blocked":
            return "blocked"
        case "review_ready":
            return "review_ready"
        case "failed":
            return "error"
        case "queued", "assigned":
            return paneIsWorking ? "running" : "idle"
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
        // Phase E Wave 1: "cancelled" joins the terminal set so it drops out of
        // `activeTask` derivation in the same tick as the status flip.
        ["completed", "failed", "abandoned", "cancelled"].contains(status)
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

/// Restore Fleet Layer 3 — launch-time behavior when crash-recoverable live
/// team snapshots are found. Stored in UserDefaults key "fleetRestoreMode"
/// ("ask" | "always" | "never"); missing/unknown values fall back to `.ask`.
enum FleetRestoreMode: String {
    case ask
    case always
    case never

    static var current: FleetRestoreMode {
        let raw = UserDefaults.standard.string(forKey: "fleetRestoreMode") ?? "ask"
        return FleetRestoreMode(rawValue: raw) ?? .ask
    }
}

extension Notification.Name {
    /// Posted with userInfo `{"team_uuid": String}` to request a fleet
    /// restore. Handled in `TermMeshApp` (where the active `TabManager` is in
    /// scope). Posted by the sidebar banner's Restore button and, in
    /// `FleetRestoreMode.always`, by `detectRestorableFleets` itself.
    static let restoreFleetRequested = Notification.Name("term-mesh.restoreFleetRequested")
}

/// Shared gate instance. File-scope (not a static on the @MainActor class) so
/// it can be touched from both the main actor and `panePersistQueue` without
/// actor-isolation friction; the class is internally locked.
private let teamLiveSnapshotGate = LiveSnapshotGate()

/// Restore Fleet Layer 1 — write gate for live team snapshots.
///
/// Two jobs, both keyed by `team_uuid`:
/// 1. **Dedup** — remembers the last written payload hash so unchanged teams
///    don't re-write their snapshot on every debounce tick.
/// 2. **Retirement** — once a destroy/quit archive is initiated for a uuid,
///    all further live-snapshot writes for it are refused until the team is
///    resumed again. Combined with the serial `panePersistQueue`, this makes
///    "snapshot recreates the live dir after the archive cleared it"
///    impossible.
///
/// Thread-safety: called from the main actor (gate check at schedule time)
/// and from `panePersistQueue` (re-check before the RPC), hence the lock.
private final class LiveSnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastWrittenHashes: [String: Int] = [:]
    private var retired: Set<String> = []

    /// Returns true when the payload changed AND the uuid isn't retired;
    /// records the hash as written.
    func shouldWrite(uuid: String, hash: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if retired.contains(uuid) { return false }
        if lastWrittenHashes[uuid] == hash { return false }
        lastWrittenHashes[uuid] = hash
        return true
    }

    /// Cheap re-check on the persist queue right before the RPC.
    func isWritable(uuid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !retired.contains(uuid)
    }

    /// Destroy/quit archive initiated — block further snapshots for this uuid.
    func retire(uuid: String) {
        lock.lock()
        defer { lock.unlock() }
        retired.insert(uuid)
        lastWrittenHashes[uuid] = nil
    }

    /// Team resumed in the same app run — allow snapshots again (hash reset so
    /// the first post-resume snapshot always writes).
    func revive(uuid: String) {
        lock.lock()
        defer { lock.unlock() }
        retired.remove(uuid)
        lastWrittenHashes[uuid] = nil
    }
}

// MARK: - ClaudeSessionWatcher (D3-A)
//
// Watches `~/.claude/projects/<encoded-workdir>/` per active workdir and
// attributes each newly created `<sid>.jsonl` to the most recently spawned
// (LIFO) claude pane registered for that workdir. The Claude CLI creates its
// transcript file shortly after spawn, so this lets us back-fill the real
// session id onto `AgentMember.claudeSessionId` without polling.
//
// Race handling: caller (`addAgentPaneToWorkspace`) is invoked serially from
// the `createTeam` loop on the main actor, so registrations land in spawn
// order. A 5-minute pending-entry TTL drops stale registrations whose Claude
// process never produced a transcript (e.g. CLI launch error).

@MainActor
final class ClaudeSessionWatcher {
    static let shared = ClaudeSessionWatcher()

    private struct Pending {
        let teamName: String
        let agentName: String
        let registeredAt: Date
    }

    private struct WatchState {
        var stream: FSEventStreamRef?
        var pending: [Pending] = []
        var knownSids: Set<String> = []
    }

    private var states: [String: WatchState] = [:]
    private var bound = false

    static func encodedProjectDir(workDir: String) -> String {
        let encoded = workDir.replacingOccurrences(of: "/", with: "-")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/projects/\(encoded)"
    }

    /// claude session ids are RFC4122 UUIDs (8-4-4-4-12 = 36 chars, 4 dashes).
    static func isValidSid(_ s: String) -> Bool {
        return s.count == 36 && s.filter({ $0 == "-" }).count == 4
    }

    /// Wire the resolve callback into TeamOrchestrator. Idempotent — only
    /// the first call installs the closure.
    func bindIfNeeded() {
        guard !bound else { return }
        bound = true
    }

    /// Register an agent pane that just spawned `claude` and is awaiting its
    /// real session id. The next new `<sid>.jsonl` appearing in this workdir
    /// is attributed to the most recently registered pending pane (LIFO),
    /// matching the spec for "가장 최근 spawn agent에 sid 귀속".
    func registerPendingClaudePane(teamName: String, agentName: String, workDir: String) {
        let dir = Self.encodedProjectDir(workDir: workDir)
        // Make sure the dir exists so FSEvents has something to watch.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var state = states[dir] ?? WatchState()
        if state.knownSids.isEmpty,
           let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for item in items where item.hasSuffix(".jsonl") {
                let sid = String(item.dropLast(6))
                if Self.isValidSid(sid) { state.knownSids.insert(sid) }
            }
        }
        state.pending.append(Pending(teamName: teamName, agentName: agentName, registeredAt: Date()))
        if state.stream == nil {
            state.stream = makeStream(forDir: dir)
        }
        states[dir] = state

        #if DEBUG
        dlog("[claude.sid.watch] register team=\(teamName) agent=\(agentName) dir=\(dir) pending=\(state.pending.count) known=\(state.knownSids.count)")
        #endif

        // D3-A P2 (a): safety net — if Claude never writes a transcript (CLI
        // launch error, user kills pane before first response, etc.) the
        // pending entry would otherwise linger because TTL drains only on
        // scan(). Force a sweep at 5 min so the watcher tears down cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self else { return }
            self.expirePendingIfStillRegistered(dir: dir, teamName: teamName, agentName: agentName)
        }
    }

    /// D3-A P2 (b): called from pane teardown (detachAgent / destroyTeam) so
    /// a normally-closed pane releases its pending slot immediately rather
    /// than waiting for the 5-min safety net. Idempotent.
    func unregisterPendingClaudePane(teamName: String, agentName: String, workDir: String) {
        let dir = Self.encodedProjectDir(workDir: workDir)
        guard var state = states[dir] else { return }
        let before = state.pending.count
        state.pending.removeAll { $0.teamName == teamName && $0.agentName == agentName }
        let removed = before - state.pending.count
        states[dir] = state
        #if DEBUG
        if removed > 0 {
            dlog("[claude.sid.watch] unregister team=\(teamName) agent=\(agentName) dir=\(dir) removed=\(removed) remaining=\(state.pending.count)")
        }
        #endif
        if state.pending.isEmpty {
            tearDown(dir: dir)
        }
    }

    private func expirePendingIfStillRegistered(dir: String, teamName: String, agentName: String) {
        guard var state = states[dir] else { return }
        let before = state.pending.count
        state.pending.removeAll { $0.teamName == teamName && $0.agentName == agentName }
        let removed = before - state.pending.count
        guard removed > 0 else { return }
        states[dir] = state
        #if DEBUG
        dlog("[claude.sid.watch] expire team=\(teamName) agent=\(agentName) dir=\(dir) (5min safety-net)")
        #endif
        if state.pending.isEmpty {
            tearDown(dir: dir)
        }
    }

    private func makeStream(forDir dir: String) -> FSEventStreamRef? {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // We don't decode the per-event payload — FSEvents coalesces and we
        // scan every active dir on each fire. Cheap (<= a handful of dirs).
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            DispatchQueue.main.async {
                ClaudeSessionWatcher.shared.scanAll()
            }
        }
        let paths = [dir] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // 100ms coalescing
            flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        return stream
    }

    private func scanAll() {
        for dir in Array(states.keys) {
            scan(dir: dir)
        }
    }

    private func scan(dir: String) {
        guard var state = states[dir] else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        var resolved: [(team: String, agent: String, sid: String)] = []
        // Drop pending registrations older than 5 minutes — the Claude
        // process clearly didn't make it to first-response.
        let cutoff = Date().addingTimeInterval(-300)
        state.pending.removeAll { $0.registeredAt < cutoff }

        // D3-A P1-B: `contentsOfDirectory` returns items in unspecified order,
        // so when FSEvents coalesces multiple .jsonl creations into one batch,
        // iterating raw would cross-wire sids onto the wrong agents. Build
        // (sid, mtime) tuples first, then sort newest-first so the newest
        // transcript pairs with the newest pending registration (LIFO).
        let fm = FileManager.default
        let candidates: [(sid: String, mtime: Date)] = items.compactMap { item in
            guard item.hasSuffix(".jsonl") else { return nil }
            let sid = String(item.dropLast(6))
            guard Self.isValidSid(sid) else { return nil }
            let path = "\(dir)/\(item)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (sid, mtime)
        }
        for c in candidates.sorted(by: { $0.mtime > $1.mtime }) {
            guard !state.knownSids.contains(c.sid) else { continue }
            state.knownSids.insert(c.sid)
            guard let target = state.pending.popLast() else {
                #if DEBUG
                dlog("[claude.sid.watch] new sid=\(c.sid) dir=\(dir) but no pending agent — drop")
                #endif
                continue
            }
            resolved.append((target.teamName, target.agentName, c.sid))
        }
        states[dir] = state
        for r in resolved {
            TeamOrchestrator.shared.applyClaudeSessionId(teamName: r.team, agentName: r.agent, sid: r.sid)
        }
        if state.pending.isEmpty {
            tearDown(dir: dir)
        }
    }

    private func tearDown(dir: String) {
        guard let state = states.removeValue(forKey: dir), let stream = state.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        #if DEBUG
        dlog("[claude.sid.watch] teardown dir=\(dir)")
        #endif
    }
}
