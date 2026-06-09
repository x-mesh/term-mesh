import AppKit
import SwiftUI

// MARK: - Phase 2 Notifications

extension Notification.Name {
    /// Posted after a headless team is destroyed so any open TeamCreationView
    /// in "Resume from previous team" mode can refresh its candidate list.
    static let headlessTeamDestroyed = Notification.Name("term-mesh.headlessTeamDestroyed")
    /// Phase 2.5 — request opening the New Agent Team sheet pre-flipped to the
    /// "Resume from previous team" mode. Posted from the sidebar resumable
    /// footer. The sheet host reads the optional `mode` user-info key.
    static let openCreateTeamSheetInResumeMode = Notification.Name("term-mesh.openCreateTeamSheetInResumeMode")
}

// MARK: - Claude Session Discovery

/// A discovered Claude Code session for resume.
struct ClaudeSession: Identifiable, Hashable {
    let id: String       // UUID string
    let modified: Date
    let firstMessage: String
    let lastMessage: String  // last assistant response snippet

    var relativeTime: String {
        let elapsed = Date().timeIntervalSince(modified)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    /// Short display label for the picker row.
    var displayLabel: String {
        if firstMessage.isEmpty { return id.prefix(8).description }
        return firstMessage
    }

    /// Scan the Claude Code sessions directory for the given project path.
    /// `workingDirectory` must be provided by the caller (resolved on MainActor).
    static func listRecent(workingDirectory: String, limit: Int = 15) -> [ClaudeSession] {
        let rawEncoded = workingDirectory.replacingOccurrences(of: "/", with: "-")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.claude/projects/\(rawEncoded)"

        let fm = FileManager.default
        guard fm.fileExists(atPath: dir),
              let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var sessions: [ClaudeSession] = []
        for item in items {
            guard item.hasSuffix(".jsonl") else { continue }
            let sid = String(item.dropLast(6)) // remove .jsonl
            guard sid.count == 36, sid.filter({ $0 == "-" }).count == 4 else { continue }

            let fullPath = "\(dir)/\(item)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date else { continue }

            let (firstMsg, lastMsg) = extractMessages(path: fullPath)
            sessions.append(ClaudeSession(id: sid, modified: modified, firstMessage: firstMsg, lastMessage: lastMsg))
        }

        sessions.sort { $0.modified > $1.modified }
        return Array(sessions.prefix(limit))
    }

    /// Extract text content from a session JSONL message object.
    /// User messages: `message.content` is a string or `[{"type":"text","text":"..."}]`.
    /// Assistant messages: `message.content` is `[{"type":"text","text":"..."}]`.
    private static func extractText(from obj: [String: Any]) -> String {
        // Try message.content first (current format)
        if let message = obj["message"] as? [String: Any] {
            let content = message["content"]
            if let str = content as? String { return str }
            if let blocks = content as? [[String: Any]] {
                return blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: " ")
            }
        }
        // Fallback: top-level content
        return obj["content"] as? String ?? ""
    }

    /// Read first N lines from a file (reads only enough bytes, not the whole file).
    private static func readLines(path: String, maxLines: Int = 50) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { fh.closeFile() }
        // Read first ~64KB which is enough for 50 lines of typical JSONL
        let data = fh.readData(ofLength: 65536)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return Array(text.components(separatedBy: "\n").prefix(maxLines))
    }

    /// Read last N bytes of a file and return lines.
    private static func readTailLines(path: String, bytes: Int = 32768) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { fh.closeFile() }
        let fileSize = fh.seekToEndOfFile()
        let offset = fileSize > UInt64(bytes) ? fileSize - UInt64(bytes) : 0
        fh.seek(toFileOffset: offset)
        let data = fh.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }

    /// Check if a text looks like a real user message (not system/hook/command).
    private static func isRealUserMessage(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.contains("<system-reminder>") || t.contains("<command-name>")
            || t.contains("<local-command") { return false }
        return true
    }

    /// Extract the first user message and last assistant message from a session JSONL.
    /// Read the most recent assistant snippet from the leader's transcript
    /// jsonl. Returns nil when the file is unreadable or has no assistant
    /// messages. Used by the resume picker to surface where the conversation
    /// left off without re-spawning the leader.
    static func lastUserMessage(path: String) -> String? {
        let (_, last) = extractMessages(path: path)
        return last.isEmpty ? nil : last
    }

    private static func extractMessages(path: String) -> (first: String, last: String) {
        // First user message: scan first 50 lines
        var firstMsg = ""
        let headLines = readLines(path: path, maxLines: 50)
        for line in headLines {
            guard !line.isEmpty,
                  let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let msgType = obj["type"] as? String,
                  msgType == "user" else { continue }
            let text = extractText(from: obj)
            guard isRealUserMessage(text) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // For commit generator sessions, show a cleaner label
            if trimmed.hasPrefix("You are a commit message generator") {
                firstMsg = "[commit message]"
                break
            }
            firstMsg = String(trimmed.prefix(80)) + (trimmed.count > 80 ? "..." : "")
            break
        }

        // Last assistant message: scan tail
        var lastMsg = ""
        let tailLines = readTailLines(path: path)
        for line in tailLines.reversed() {
            guard !line.isEmpty,
                  let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  obj["type"] as? String == "assistant" else { continue }
            let text = extractText(from: obj)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            lastMsg = String(trimmed.prefix(80)) + (trimmed.count > 80 ? "..." : "")
            break
        }

        return (firstMsg, lastMsg)
    }
}

/// A row representing one agent slot in the team creation form.
struct TeamAgentRow: Identifiable, Equatable {
    let id = UUID()
    var preset: AgentRolePreset
    var customInstructions: String  // overrides preset instructions if non-empty
    var providerBadge: ProviderBadge = .none

    enum ProviderBadge: Equatable {
        case none
        case best(reason: String)
        case fallback(wanted: String)
    }
}

// MARK: - Phase 2 Resumable Team Models (headless.list_resumable result)

/// Lightweight model decoded from `headless.list_resumable` RPC.
struct ResumableTeam: Identifiable, Hashable {
    let teamUuid: String
    let teamName: String
    let createdAt: Int
    let destroyedAt: Int
    let workingDirectory: String
    let gitRoot: String?
    let gitBranchAtCreate: String?
    let gitBranchNow: String?
    let worktree: Worktree?
    let agents: [Agent]
    let validity: Validity
    let resumable: Bool
    let blockingReason: String?
    /// "headless" (daemon-managed subprocesses) or "pane" (GUI panes).
    /// Drives resume routing: pane archives use `team.resume_pane` instead of
    /// `headless.resume_team`. Defaults to "headless" for back-compat when the
    /// daemon predates this field.
    let mode: String
    /// Leader's claude session id (used by the picker preview to surface the
    /// last leader message; also informs resume routing). Empty / nil when no
    /// session was captured.
    let leaderSessionId: String?
    /// Last user/assistant message text from the leader's transcript jsonl,
    /// resolved lazily by the picker. nil until resolved or when the leader
    /// session file is unavailable.
    var leaderLastMessage: String? = nil

    var id: String { teamUuid }

    struct Worktree: Hashable {
        let mode: String
        let path: String
        let branch: String
        let exists: Bool
        let branchNow: String?
    }

    struct Agent: Hashable, Identifiable {
        let name: String
        let agentType: String
        let cli: String
        let model: String
        let color: String
        let hasSession: Bool
        let hasInstructions: Bool
        var id: String { name }
    }

    struct Validity: Hashable {
        let worktreeExists: Bool
        let branchMatches: Bool
        let runbookMatches: Bool
        let cliVersionMatches: Bool
        let allSessionsPresent: Bool
    }

    /// Human relative time for `destroyed_at`.
    var destroyedRelative: String {
        let elapsed = Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(destroyedAt)))
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    /// Reason a row should be presented as disabled (subset of validity).
    /// Returns nil when the row is selectable.
    var disabledReason: String? {
        if !validity.worktreeExists, let w = worktree {
            return "Worktree directory no longer exists: \(w.path)"
        }
        if mode != "pane" && !validity.allSessionsPresent {
            return "Cannot resume — agents have no session IDs (created before Phase 2)"
        }
        switch blockingReason {
        case "worktree_gone":
            return "Worktree directory no longer exists"
        case "no_sessions":
            if mode == "pane" {
                return "No resumable leader or agent session was captured"
            }
            return "No resumable sessions (created before Phase 2)"
        case "corrupt":
            return "Metadata is corrupt — cannot resume"
        default:
            return nil
        }
    }

    /// Branch drift summary used for ⚠ row and confirm dialog. Returns
    /// `(from, to)` only when `branch_matches == false`.
    var branchDrift: (from: String, to: String)? {
        guard !validity.branchMatches else { return nil }
        let from = gitBranchAtCreate ?? worktree?.branch ?? "?"
        let to = worktree?.branchNow ?? gitBranchNow ?? "?"
        return (from, to)
    }

    static func decode(_ dict: [String: Any]) -> ResumableTeam? {
        guard let uuid = dict["team_uuid"] as? String,
              let name = dict["team_name"] as? String,
              let created = dict["created_at"] as? Int,
              let destroyed = dict["destroyed_at"] as? Int,
              let wd = dict["working_directory"] as? String else { return nil }
        let validityRaw = dict["validity"] as? [String: Any] ?? [:]
        let validity = Validity(
            worktreeExists:     validityRaw["worktree_exists"] as? Bool ?? false,
            branchMatches:      validityRaw["branch_matches"] as? Bool ?? false,
            runbookMatches:     validityRaw["runbook_matches"] as? Bool ?? false,
            cliVersionMatches:  validityRaw["cli_version_matches"] as? Bool ?? false,
            allSessionsPresent: validityRaw["all_sessions_present"] as? Bool ?? false
        )
        var worktree: Worktree?
        if let wt = dict["worktree"] as? [String: Any] {
            worktree = Worktree(
                mode: wt["mode"] as? String ?? "",
                path: wt["path"] as? String ?? "",
                branch: wt["branch"] as? String ?? "",
                exists: wt["exists"] as? Bool ?? false,
                branchNow: wt["branch_now"] as? String
            )
        }
        let agentsRaw = dict["agents"] as? [[String: Any]] ?? []
        let agents: [Agent] = agentsRaw.compactMap { a in
            guard let aname = a["name"] as? String else { return nil }
            return Agent(
                name: aname,
                agentType: a["agent_type"] as? String ?? aname,
                cli: a["cli"] as? String ?? "claude",
                model: a["model"] as? String ?? "sonnet",
                color: a["color"] as? String ?? "gray",
                hasSession: a["has_session"] as? Bool ?? false,
                hasInstructions: a["has_instructions"] as? Bool ?? false
            )
        }
        return ResumableTeam(
            teamUuid: uuid,
            teamName: name,
            createdAt: created,
            destroyedAt: destroyed,
            workingDirectory: wd,
            gitRoot: dict["git_root"] as? String,
            gitBranchAtCreate: dict["git_branch_at_create"] as? String,
            gitBranchNow: dict["git_branch_now"] as? String,
            worktree: worktree,
            agents: agents,
            validity: validity,
            resumable: dict["resumable"] as? Bool ?? false,
            blockingReason: dict["blocking_reason"] as? String,
            mode: (dict["mode"] as? String) ?? "headless",
            leaderSessionId: (dict["leader_session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// Sheet for creating a new multi-agent team.
struct TeamCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presetManager = AgentRolePresetManager.shared
    @ObservedObject var savedTemplateManager = SavedTeamTemplateManager.shared
    @ObservedObject var teamTemplateManager = TeamTemplateManager.shared
    @ObservedObject var providerDetector = ProviderDetector.shared

    var onCreate: ((_ teamName: String, _ leaderMode: String, _ leaderModel: String, _ agents: [TeamAgentRow], _ worktreeMode: String, _ executionMode: String, _ resumeSessionId: String?, _ pairMode: String, _ pairModel: String, _ pairSpec: String, _ workingDirectory: String) -> Bool)?
    /// Phase 2: called after a successful `headless.resume_team` RPC.
    /// Receives the decoded result dictionary. Caller is responsible for
    /// registering the team in TeamOrchestrator and switching workspace cwd
    /// to the worktree path (or working_directory if no worktree).
    var onResume: ((_ result: [String: Any]) -> Void)?
    /// Phase 2.5 — initial creation mode. Defaults to "new". Pass "resume" to
    /// open directly into the Resume picker (used by the sidebar footer
    /// resumable counter).
    var initialMode: String = "new"
    var defaultWorkingDirectory: String = ""
    var defaultWorkingDirectorySource: WorkingDirectorySource = .currentPane

    init(
        onCreate: ((_ teamName: String, _ leaderMode: String, _ leaderModel: String, _ agents: [TeamAgentRow], _ worktreeMode: String, _ executionMode: String, _ resumeSessionId: String?, _ pairMode: String, _ pairModel: String, _ pairSpec: String, _ workingDirectory: String) -> Bool)? = nil,
        onResume: ((_ result: [String: Any]) -> Void)? = nil,
        initialMode: String = "new",
        defaultWorkingDirectory: String = "",
        defaultWorkingDirectorySource: WorkingDirectorySource = .currentPane
    ) {
        self.onCreate = onCreate
        self.onResume = onResume
        self.initialMode = initialMode
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.defaultWorkingDirectorySource = defaultWorkingDirectorySource
        _workingDirectory = State(initialValue: defaultWorkingDirectory)
        _workingDirectorySource = State(initialValue: defaultWorkingDirectorySource)
    }

    @AppStorage("teamDefaultLeaderMode") private var defaultLeaderMode = "claude"
    @AppStorage("teamDefaultModel") private var defaultModel = "sonnet"
    @AppStorage("teamDefaultLeaderModel") private var defaultLeaderModel = "sonnet"

    @State private var teamName = "my-team"
    @State private var leaderMode = "repl"  // "repl" or "claude"
    @State private var leaderModel = "sonnet"
    @State private var agents: [TeamAgentRow] = []
    @State private var showPresetEditor = false
    @State private var showSaveTemplate = false
    @State private var saveTemplateName = ""
    @State private var selectedWorkflowName: String?
    @State private var previewTemplate: TeamTemplate?
    @State private var hoveredAgentId: UUID?
    @State private var bulkModel = "sonnet"
    @State private var selectedSmartPresetId: String?
    @State private var hoveredSmartPresetId: String? = nil
    @State private var deletingSmartPresetId: String? = nil
    @State private var editingNewSmartPresetSlug: String? = nil
    @State private var newSmartPresetName: String = ""
    @FocusState private var isNewSmartPresetNameFocused: Bool
    @State private var worktreeMode = "off"  // "off", "shared", "isolated"
    @State private var executionMode = "pane"  // "pane" or "headless"
    @State private var showDaemonWarning = false
    @State private var resumeSession = false
    @State private var leaderPairMode: String = "none"
    @AppStorage("teamDefaultPairModel") private var leaderPairModel: String = ""
    @State private var leaderPairSpec: String = ""
    @State private var leaderPairAutoWatch: Bool = false
    @State private var leaderPairStance: String = "critic"
    @State private var recentSessions: [ClaudeSession] = []
    @State private var selectedSessionId: String?
    @State private var manualSessionId = ""
    @State private var runbookStatus = AgentRunbookService.shared.status()

    // MARK: - Phase 2 Resume state

    /// "new" (fresh team) or "resume" (rehydrate a previously-destroyed team).
    /// This is orthogonal to the per-leader `resumeSession` Claude-session toggle.
    @State private var creationMode: String = "new"
    /// "thisRepo" or "all" — toggles whether list_resumable filters by git_root.
    @State private var resumeFilter: String = "thisRepo"
    @State private var resumableTeams: [ResumableTeam] = []
    @State private var isLoadingResumable: Bool = false
    @State private var resumeLoadError: String?
    @State private var selectedResumeTeamId: String?
    @State private var expandedResumeAgentTeams: Set<String> = []
    @State private var pendingBranchDriftTeam: ResumableTeam?
    @State private var resumeInFlight: Bool = false
    @State private var resumeErrorMessage: String?

    // MARK: - Auto-recycle

    @AppStorage("termmesh.autoRecycle.globalDefault") private var globalAutoRecycleDefault: Int = 0
    /// 0 = disabled for this team.
    @State private var autoRecycleEvery: Int = 0
    /// Per-agent override: agentName → threshold (0 = use team default).
    @State private var perAgentOverrides: [String: Int] = [:]

    /// A team name is only truly duplicate if the entry exists AND its workspace
    /// tab is still open.  When the user closes a workspace tab manually the team
    /// dict entry becomes stale — allow reuse (createTeam auto-cleans it up).
    private var isTeamNameDuplicate: Bool {
        guard !teamName.isEmpty,
              let existing = TeamOrchestrator.shared.teams[teamName] else { return false }
        // Check all windows' tab managers via AppDelegate (avoids @EnvironmentObject
        // which can crash in .sheet contexts on macOS).
        return AppDelegate.shared?.tabManagerFor(tabId: existing.workspaceId) != nil
    }

    /// Models shown in the bulk picker — defaults to Claude models.
    private var bulkModels: [String] {
        AgentRolePreset.models(for: bulkCli)
    }
    @State private var bulkCli = "claude"

    @State private var workingDirectory: String = ""
    @State private var workingDirectorySource: WorkingDirectorySource = .currentPane
    @State private var workingDirectoryError: String? = nil
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            creationModeSelector
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                if creationMode == "resume" {
                    resumePanel
                        .padding(20)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        teamSettings
                        Divider().padding(.vertical, 2)
                        presetButtons
                        Divider().padding(.vertical, 2)
                        agentList
                        Divider().padding(.vertical, 2)
                        workflowButtons
                    }
                    .padding(20)
                }
            }
            Divider()
            footer
        }
        .frame(width: 880, height: 850)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            leaderMode = TeamTemplateManager.shared.resolveLeaderMode(fallback: defaultLeaderMode)
            leaderModel = defaultLeaderModel
            bulkModel = defaultModel
            worktreeMode = TermMeshDaemon.shared.worktreeEnabled ? "isolated" : "off"
            autoRecycleEvery = globalAutoRecycleDefault
            if agents.isEmpty {
                applyInitialPreset()
            }
            // leaderModel stored in AppStorage may not be valid for the resolved leaderMode
            // (e.g. "gpt-5.5" stored from a previous codex session, now reopened with claude).
            // Normalize legacy aliases first so "opus-1m" → "opus" before the contains check.
            let normalizedLeader = AgentRolePreset.normalizeModel(leaderModel, for: leaderMode)
            if normalizedLeader != leaderModel {
                leaderModel = normalizedLeader
            } else if !AgentRolePreset.models(for: leaderMode).contains(leaderModel) {
                leaderModel = AgentRolePreset.defaultModel(for: leaderMode)
            }
            validateWorkingDirectory()
            refreshRunbookStatus()
            // Phase 2.5 — honor caller's requested initial mode (sidebar
            // resumable footer opens us directly into resume picker).
            if initialMode == "resume" && creationMode != "resume" {
                creationMode = "resume"
                loadResumableTeams()
            }
        }
        .onChange(of: workingDirectory) { _ in
            validateWorkingDirectory()
            refreshRunbookStatus()
            // Clear session state tied to the previous cwd so createTeam cannot
            // submit (new cwd + stale sessionId) and produce wrong rehydration.
            recentSessions = []
            selectedSessionId = nil
            manualSessionId = ""
            // If resume toggle is on and the new path is valid, reload sessions.
            if resumeSession, workingDirectoryError == nil, !workingDirectory.isEmpty {
                let dir = workingDirectory
                Task.detached(priority: .userInitiated) {
                    let sessions = ClaudeSession.listRecent(workingDirectory: dir)
                    await MainActor.run { recentSessions = sessions }
                }
            }
        }
        // Phase 2: refresh the resume list when a destroy event arrives while
        // the sheet is open. We listen on the .headlessTeamDestroyed
        // notification (defined locally below); TeamOrchestrator posts it from
        // its destroy path. Cheap to re-call list_resumable.
        .onReceive(NotificationCenter.default.publisher(for: .headlessTeamDestroyed)) { _ in
            if creationMode == "resume" { loadResumableTeams() }
        }
        .sheet(isPresented: $showPresetEditor) {
            RolePresetEditorView()
        }
        .alert(
            "Branch has changed",
            isPresented: Binding(
                get: { pendingBranchDriftTeam != nil },
                set: { if !$0 { pendingBranchDriftTeam = nil } }
            ),
            presenting: pendingBranchDriftTeam
        ) { team in
            Button("Resume anyway", role: .destructive) {
                if let team = pendingBranchDriftTeam {
                    pendingBranchDriftTeam = nil
                    invokeResume(team: team, acceptBranchDrift: true)
                }
            }
            Button("Cancel", role: .cancel) { pendingBranchDriftTeam = nil }
        } message: { team in
            if let drift = team.branchDrift {
                Text("Branch has changed since this team was created (was \(drift.from), now \(drift.to)). Resume anyway on the current branch?")
            } else {
                Text("Branch has changed since this team was created. Resume anyway?")
            }
        }
        .sheet(item: $previewTemplate) { template in
            TeamTemplatePreviewPanel(
                template: template,
                providerDetector: providerDetector,
                onUse: {
                    applyTemplate(template)
                    previewTemplate = nil
                }
            )
        }
    }

    // MARK: - Phase 2 Creation Mode Selector

    private var creationModeSelector: some View {
        HStack(spacing: 20) {
            // Spec §6.1 asks for a radio group. We use SwiftUI Picker with
            // .segmented style for consistency with the codebase (no other
            // .radioGroup usage in Sources/). Functionally equivalent.
            Picker("", selection: $creationMode) {
                Text("New session").tag("new")
                Text("Resume from previous team").tag("resume")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .labelsHidden()
            .onChange(of: creationMode) { mode in
                if mode == "resume" {
                    loadResumableTeams()
                }
            }
            Spacer()
        }
    }

    // MARK: - Phase 2 Resume Panel

    @ViewBuilder
    private var resumePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Resumable Teams")
                    .font(.subheadline.bold())
                Spacer()
                Picker("", selection: $resumeFilter) {
                    Text("This repo").tag("thisRepo")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .labelsHidden()
                .onChange(of: resumeFilter) { _ in loadResumableTeams() }

                Button {
                    loadResumableTeams()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh list")
                .disabled(isLoadingResumable)
            }

            if isLoadingResumable {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if let err = resumeLoadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Failed to load resumable teams")
                        .font(.subheadline)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
            } else if resumableTeams.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(resumeFilter == "thisRepo"
                         ? "No resumable teams found for this repo."
                         : "No resumable teams found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Teams appear here after they are destroyed and within the retention window.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(resumableTeams) { team in
                        resumableRow(team)
                    }
                }
            }

            if let msg = resumeErrorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    @ViewBuilder
    private func resumableRow(_ team: ResumableTeam) -> some View {
        let isSelected = selectedResumeTeamId == team.teamUuid
        let disabledReason = team.disabledReason
        let isDisabled = disabledReason != nil
        let isExpanded = expandedResumeAgentTeams.contains(team.teamUuid)

        VStack(alignment: .leading, spacing: 6) {
            // Row 1: team name + mode badge + delete + agent count
            HStack(spacing: 6) {
                Text(team.teamName)
                    .font(.headline)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                // Mode badge: pane vs headless. Tooltip explains the distinction
                // so users understand why the icons differ.
                Image(systemName: team.mode == "pane" ? "rectangle.split.2x2" : "server.rack")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(team.mode == "pane"
                        ? "Pane-mode team — agents run in visible terminal panes"
                        : "Headless team — agents run as background subprocesses")
                Spacer()
                // On-demand archive delete. Auto GC sweeps anything older than
                // 7 days; this lets users drop archives they're done with.
                Button(action: { confirmDeleteArchive(team) }) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Delete this archived team (auto-deleted after 7 days)")
                .accessibilityLabel("Delete archive")
                Text("\(team.agents.count) agent\(team.agents.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }

            // Row 2: destroyed-relative + working directory
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("destroyed \(team.destroyedRelative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(shortenedHome(team.workingDirectory))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Row 2.5: leader session id + last leader message (when known).
            // Surfaces what conversation the picker would resume to so users
            // can pick the right team at a glance.
            if let sid = team.leaderSessionId, !sid.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.text.rectangle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("leader \(String(sid.prefix(8)))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .help(sid)
                    if let last = team.leaderLastMessage, !last.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\u{201C}\(last)\u{201D}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(last)
                    }
                }
            }

            // Row 3: worktree + branch indicator (when present)
            if let wt = team.worktree {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("worktree: \(wt.branch) @ \(shortenedHome(wt.path))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let drift = team.branchDrift {
                        Text("⚠ branch was \(drift.from) → now \(drift.to)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if team.validity.branchMatches {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .help("Branch matches creation state")
                    }
                }
            }

            // Optional warnings (runbook drift, CLI version drift) — non-blocking
            if !team.validity.runbookMatches {
                HStack(spacing: 4) {
                    Image(systemName: "book.closed")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Runbook has changed since creation — resume will use the original instructions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !team.validity.cliVersionMatches {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Claude CLI version differs from creation — resume may fail.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Disclosure: per-agent rows
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded },
                set: { open in
                    if open { expandedResumeAgentTeams.insert(team.teamUuid) }
                    else { expandedResumeAgentTeams.remove(team.teamUuid) }
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(team.agents) { agent in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(agentColor(agent.color))
                                .frame(width: 8, height: 8)
                            Text(agent.name)
                                .font(.caption)
                            Text("(\(agent.cli), \(agent.model))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            if agent.hasSession && agent.hasInstructions {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .help(agent.hasSession
                                          ? "Instructions missing"
                                          : "No session — cannot resume")
                            }
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Agents")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1)
        )
        .opacity(isDisabled ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDisabled else { return }
            selectedResumeTeamId = team.teamUuid
        }
        .help(disabledReason ?? "")
    }

    /// Replace a leading $HOME with `~` for display.
    private func shortenedHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Phase 2 Resume RPC

    private func loadResumableTeams() {
        isLoadingResumable = true
        resumeLoadError = nil
        let filterRoot: String? = (resumeFilter == "thisRepo") ? currentGitRoot() : nil
        var params: [String: Any] = ["limit": 50]
        if let root = filterRoot { params["git_root"] = root }

        DispatchQueue.global(qos: .userInitiated).async {
            let raw = TermMeshDaemon.shared.rpcCallRaw(
                method: "headless.list_resumable",
                params: params
            )
            var decoded: [ResumableTeam] = []
            var loadError: String?
            if let raw, let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errMsg = obj["error"] as? String {
                    loadError = errMsg
                } else if let result = obj["result"] as? [String: Any],
                          let teams = result["teams"] as? [[String: Any]] {
                    decoded = teams.compactMap { ResumableTeam.decode($0) }
                } else if let teams = obj["teams"] as? [[String: Any]] {
                    // Tolerate bare-result shape (no JSON-RPC envelope).
                    decoded = teams.compactMap { ResumableTeam.decode($0) }
                }
                // Resolve leader's last transcript message for the picker
                // preview. Reads `~/.claude/projects/<encoded-wd>/<sid>.jsonl`
                // tail — best-effort, leaves nil when unavailable.
                for i in decoded.indices {
                    guard let sid = decoded[i].leaderSessionId, !sid.isEmpty else { continue }
                    let wd = decoded[i].workingDirectory
                    let encoded = wd.replacingOccurrences(of: "/", with: "-")
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    let path = "\(home)/.claude/projects/\(encoded)/\(sid).jsonl"
                    if FileManager.default.fileExists(atPath: path),
                       let snippet = ClaudeSession.lastUserMessage(path: path), !snippet.isEmpty {
                        decoded[i].leaderLastMessage = snippet
                    }
                }
            } else if raw == nil {
                // Daemon not reachable or RPC timed out — surface as empty list
                // with a soft error so the panel does not break.
                loadError = "Daemon did not respond. Make sure term-meshd is running."
            }
            DispatchQueue.main.async {
                resumableTeams = decoded
                resumeLoadError = loadError
                isLoadingResumable = false
                // Drop selection if no longer in list
                if let sel = selectedResumeTeamId,
                   !decoded.contains(where: { $0.teamUuid == sel }) {
                    selectedResumeTeamId = nil
                }
            }
        }
    }

    /// Best-effort git root resolution for the current workspace cwd. Uses
    /// the daemon helper (no main-thread focus side effects) so we share the
    /// same realpath logic the daemon uses for list_resumable filtering.
    private func currentGitRoot() -> String? {
        return TermMeshDaemon.shared.findGitRoot(from: workingDirectory)
    }

    /// Confirm and delete an archived team via `team.delete_archive`. Refreshes
    /// the picker list on success. Auto-GC sweeps anything older than 7 days
    /// (`ARCHIVE_RETENTION_SECS` in the daemon), but this gives users on-demand
    /// control to drop archives they're done with.
    private func confirmDeleteArchive(_ team: ResumableTeam) {
        let alert = NSAlert()
        alert.messageText = "Delete archived team \"\(team.teamName)\"?"
        alert.informativeText = "The archive will be permanently removed. Sessions inside this archive will no longer be resumable. Auto-GC also removes archives older than 7 days."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.presentAsSheet { response in
            guard response == .alertFirstButtonReturn else { return }
            let params: [String: Any] = ["team_uuid": team.teamUuid]
            DispatchQueue.global(qos: .userInitiated).async {
                let raw = TermMeshDaemon.shared.rpcCallRaw(
                    method: "team.delete_archive",
                    params: params
                )
                DispatchQueue.main.async {
                    if let raw, raw.contains("\"error\"") {
                        resumeErrorMessage = "Failed to delete archive."
                    }
                    if selectedResumeTeamId == team.teamUuid {
                        selectedResumeTeamId = nil
                    }
                    loadResumableTeams()
                }
            }
        }
    }

    /// Invoke the appropriate resume RPC based on the team's archive mode.
    /// Headless archives go through `headless.resume_team` (daemon respawns the
    /// subprocesses). Pane-mode archives go through `team.resume_pane` (daemon
    /// returns metadata + session IDs and the app side creates the workspace
    /// and panes).
    ///
    /// On success, calls `onResume` with the decoded result dictionary and
    /// dismisses the sheet. On error, surfaces the message inline (panel stays
    /// open).
    private func invokeResume(team: ResumableTeam, acceptBranchDrift: Bool = false) {
        guard !resumeInFlight else { return }
        resumeInFlight = true
        resumeErrorMessage = nil

        let isPaneMode = team.mode == "pane"
        let method: String
        let params: [String: Any]
        if isPaneMode {
            method = "team.resume_pane"
            params = ["team_uuid": team.teamUuid]
        } else {
            method = "headless.resume_team"
            let leaderSessionId = UUID().uuidString
            params = [
                "team_uuid": team.teamUuid,
                "leader_session_id": leaderSessionId,
                "app_socket_path": SocketControlSettings.socketPath(),
                "accept_branch_drift": acceptBranchDrift,
            ]
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let raw = TermMeshDaemon.shared.rpcCallRaw(
                method: method,
                params: params
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
                    // Tolerate bare result
                    resultDict = obj
                }
            } else if raw == nil {
                errMsg = "Daemon did not respond. Make sure term-meshd is running."
            } else {
                errMsg = "Unexpected response from daemon."
            }
            DispatchQueue.main.async {
                resumeInFlight = false
                if let errMsg {
                    resumeErrorMessage = errMsg
                    return
                }
                if var resultDict {
                    // Tag the dict with mode so the receiving onResume handler
                    // can branch between headless (daemon already spawned the
                    // subprocesses) and pane (app must create workspace + panes).
                    resultDict["mode"] = isPaneMode ? "pane" : "headless"
                    onResume?(resultDict)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("New Agent Team")
                .font(.headline)
            Spacer()

            // Load saved template
            Menu {
                if savedTemplateManager.templates.isEmpty {
                    Text("No saved templates").foregroundStyle(.secondary)
                } else {
                    ForEach(savedTemplateManager.templates) { template in
                        Button(action: { loadTemplate(template) }) {
                            Text("\(template.name) (\(template.agents.count) agents)")
                        }
                    }
                    Divider()
                    Menu("Delete…") {
                        ForEach(savedTemplateManager.templates) { template in
                            Button(template.name, role: .destructive) {
                                savedTemplateManager.delete(template)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("Load")
                    if !savedTemplateManager.templates.isEmpty {
                        Text("(\(savedTemplateManager.templates.count))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Load saved team template")

            Button(action: { showPresetEditor = true }) {
                Label("Manage Presets", systemImage: "slider.horizontal.3")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .alert("Save Team Template", isPresented: $showSaveTemplate) {
            TextField("Template name", text: $saveTemplateName)
            Button("Save") { saveCurrentAsTemplate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the current team configuration for reuse.")
        }
    }

    // MARK: - Team Settings

    private var teamSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Text("Team Name")
                        .font(.subheadline.bold())
                    Spacer()
                    TextField("team name", text: $teamName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isTeamNameDuplicate ? Color.yellow : Color.clear, lineWidth: 2)
                        )
                }
                if isTeamNameDuplicate {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Team '\(teamName)' already exists")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isTeamNameDuplicate)

            workingDirectoryRow

            HStack {
                Text("Leader")
                    .font(.subheadline.bold())
                Spacer()
                if leaderMode != "repl" && !agents.isEmpty {
                    Button(action: applyLeaderCLIToAll) {
                        Label("Apply to All", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Change all agents' CLI to \(leaderMode.capitalized)")
                }
                Picker("", selection: Binding(
                    get: { leaderMode },
                    set: { newMode in
                        let oldMode = leaderMode
                        leaderMode = newMode
                        // Reset model to CLI default when switching CLI families
                        if newMode != "repl" && AgentRolePreset.models(for: oldMode) != AgentRolePreset.models(for: newMode) {
                            leaderModel = AgentRolePreset.defaultModel(for: newMode)
                        }
                        // Reset hidden pair state when switching to repl (no pair pane possible).
                        if newMode == "repl" {
                            leaderPairMode = "none"
                            leaderPairAutoWatch = false
                        }
                        persistSelectedSmartPresetOverride()
                    }
                )) {
                    Text("REPL (Manual)").tag("repl")
                    ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                        Text("\(cli.capitalized) (Auto)").tag(cli)
                    }
                }
                .fixedSize()

                if leaderMode != "repl" {
                    // Self-healing binding: if leaderModel isn't in the current CLI's
                    // model list (stale AppStorage, removed custom model, etc.), the
                    // get-side returns a valid fallback for this render and schedules
                    // a state correction so SwiftUI never paints a blank selection.
                    Picker("", selection: Binding(
                        get: {
                            let opts = AgentRolePreset.models(for: leaderMode)
                            let normalized = AgentRolePreset.normalizeModel(leaderModel, for: leaderMode)
                            if opts.contains(normalized) {
                                if normalized != leaderModel {
                                    DispatchQueue.main.async { leaderModel = normalized }
                                }
                                return normalized
                            }
                            let fallback = AgentRolePreset.defaultModel(for: leaderMode)
                            DispatchQueue.main.async { leaderModel = fallback }
                            return fallback
                        },
                        set: { leaderModel = $0 }
                    )) {
                        ForEach(AgentRolePreset.models(for: leaderMode), id: \.self) { m in
                            Text(AgentRolePreset.modelDisplayLabel(m, for: leaderMode)).tag(m)
                        }
                    }
                    .fixedSize()
                }
            }

            // Pair-programming companion: spawns a second pane next to the
            // leader running a companion CLI (may be the same CLI as the leader).
            // Disabled for REPL leaders (no CLI to pair with).
            if leaderMode != "repl" {
                HStack {
                    Text("Pair with")
                        .font(.subheadline.bold())
                    Spacer()
                    Picker("", selection: $leaderPairMode) {
                        Text("None").tag("none")
                        ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                            Text(cli.capitalized).tag(cli)
                        }
                    }
                    .fixedSize()

                    if leaderPairMode != "none" {
                        Picker("", selection: Binding(
                            get: {
                                let opts = AgentRolePreset.models(for: leaderPairMode)
                                if opts.contains(leaderPairModel) { return leaderPairModel }
                                let fallback = AgentRolePreset.defaultModel(for: leaderPairMode)
                                DispatchQueue.main.async { leaderPairModel = fallback }
                                return fallback
                            },
                            set: { leaderPairModel = $0 }
                        )) {
                            ForEach(AgentRolePreset.models(for: leaderPairMode), id: \.self) { m in
                                Text(AgentRolePreset.modelDisplayLabel(m, for: leaderPairMode)).tag(m)
                            }
                        }
                        .fixedSize()
                    }
                }

                if leaderPairMode != "none" && executionMode == "headless" {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Pair runs as a pane — headless mode will skip it")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .transition(.opacity)
                }

                if leaderPairMode != "none" && executionMode != "headless" {
                    // Pair mode: Pane only / Auto watch (PRD §Team Creation)
                    HStack {
                        Text("Pair mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $leaderPairAutoWatch) {
                            Text("Pane only").tag(false)
                            Text("Auto watch").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .onChange(of: leaderPairAutoWatch) { on in
                            // PRD: stance=pair by default when Auto watch is selected
                            if on { leaderPairStance = "pair" }
                        }
                    }

                    // Stance segmented (always shown when pair is active)
                    HStack {
                        Text("Stance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $leaderPairStance) {
                            Text("Critic").tag("critic")
                            Text("Advisor").tag("advisor")
                            Text("Pair").tag("pair")
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    // Spec (required for Auto watch)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(leaderPairAutoWatch ? "Watcher Spec (required)" : "Watcher Spec (optional)")
                            .font(.caption)
                            .foregroundStyle(leaderPairAutoWatch ? .primary : .secondary)
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $leaderPairSpec)
                                .font(.caption)
                                .frame(minHeight: 44, maxHeight: 80)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(leaderPairAutoWatch && leaderPairSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                ? Color.red.opacity(0.5)
                                                : Color.secondary.opacity(0.3))
                                )
                            if leaderPairSpec.isEmpty {
                                Text("e.g. Stay within current task scope. Flag --no-verify or scope creep.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    }

                    // Status / warning line
                    if leaderPairAutoWatch && leaderPairSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Spec required for Auto watch — add a spec or switch to Pane only")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .transition(.opacity)
                    } else if leaderPairAutoWatch {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.fill")
                                .foregroundStyle(.green)
                            Text("watch.on (target=all, stance=\(leaderPairStance)) will run after team creation")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                                .foregroundStyle(.secondary)
                            Text("Pair acts as a watcher · run `/watch review` in leader pane to start checks")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            // Resume session toggle (only for Claude leader)
            if leaderMode == "claude" {
                HStack {
                    Text("Resume Session")
                        .font(.subheadline.bold())
                    Spacer()
                    Toggle("", isOn: $resumeSession)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .onChange(of: resumeSession) { enabled in
                    if enabled && recentSessions.isEmpty {
                        let dir = workingDirectory
                        Task.detached(priority: .userInitiated) {
                            let sessions = ClaudeSession.listRecent(workingDirectory: dir)
                            await MainActor.run { recentSessions = sessions }
                        }
                    }
                    if !enabled {
                        selectedSessionId = nil
                        manualSessionId = ""
                    }
                }

                if resumeSession {
                    VStack(alignment: .leading, spacing: 8) {
                        if recentSessions.isEmpty {
                            Text("No recent sessions found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            // Session list
                            Picker("", selection: Binding(
                                get: { selectedSessionId ?? "" },
                                set: {
                                    selectedSessionId = $0.isEmpty ? nil : $0
                                    if !$0.isEmpty { manualSessionId = "" }
                                }
                            )) {
                                Text("Select a session...").tag("")
                                ForEach(recentSessions) { session in
                                    Text("\(session.relativeTime)  \(session.displayLabel)")
                                        .tag(session.id)
                                }
                            }
                            .labelsHidden()

                            // Detail view for selected session
                            if let sid = selectedSessionId,
                               let session = recentSessions.first(where: { $0.id == sid }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    if !session.firstMessage.isEmpty {
                                        HStack(alignment: .top, spacing: 4) {
                                            Text("Q:")
                                                .font(.caption.bold())
                                                .foregroundStyle(.blue)
                                            Text(session.firstMessage)
                                                .font(.caption)
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)
                                        }
                                    }
                                    if !session.lastMessage.isEmpty {
                                        HStack(alignment: .top, spacing: 4) {
                                            Text("A:")
                                                .font(.caption.bold())
                                                .foregroundStyle(.green)
                                            Text(session.lastMessage)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Text(sid)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                                .padding(8)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }

                        // Manual session ID input
                        Divider()
                        HStack(spacing: 6) {
                            Text("or")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Paste session ID...", text: $manualSessionId)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onChange(of: manualSessionId) { val in
                                    if !val.isEmpty { selectedSessionId = nil }
                                }
                        }
                    }
                    .padding(.leading, 4)
                }
            }

            HStack {
                Text("Execution")
                    .font(.subheadline.bold())
                Spacer()
                Picker("", selection: $executionMode) {
                    Text("Pane").tag("pane")
                    Text("Headless").tag("headless")
                }
                .pickerStyle(.segmented)
            }
            .onChange(of: executionMode) { _ in
                if executionMode == "headless" {
                    showDaemonWarning = !TermMeshDaemon.shared.daemonStatus().connected
                } else {
                    showDaemonWarning = worktreeMode != "off" && !TermMeshDaemon.shared.daemonStatus().connected
                }
            }

            if executionMode == "headless" {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.orange)
                    Text("Agents run as background subprocesses — no terminal panes")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .transition(.opacity)
            }

            HStack {
                Text("Worktree")
                    .font(.subheadline.bold())
                Spacer()
                Picker("", selection: $worktreeMode) {
                    Text("Off").tag("off")
                    Text("Shared").tag("shared")
                    Text("Isolated").tag("isolated")
                }
                .pickerStyle(.segmented)
            }
            .onChange(of: worktreeMode) { _ in
                showDaemonWarning = worktreeMode != "off" && !TermMeshDaemon.shared.daemonStatus().connected
            }

            if worktreeMode == "shared" {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.blue)
                    Text("All agents share one worktree: team/\(teamName)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .transition(.opacity)
            } else if worktreeMode == "isolated" {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.green)
                    Text("Each agent gets its own worktree branch")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .transition(.opacity)
            }

            if showDaemonWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(executionMode == "headless"
                         ? "term-meshd not running — headless mode requires the daemon"
                         : "term-meshd not running — worktrees require the daemon")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Divider()

            // Auto-recycle team default
            HStack {
                Text("Auto-recycle")
                    .font(.subheadline.bold())
                Spacer()
                Stepper(value: $autoRecycleEvery, in: 0...100, step: 1) {
                    Text(autoRecycleEvery == 0 ? "Off" : "Every \(autoRecycleEvery) tasks")
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 100, alignment: .trailing)
                }
                .labelsHidden()
            }
            Text(autoRecycleEvery == 0
                 ? "Agents are not automatically recycled."
                 : "Agents restart after every \(autoRecycleEvery) completed task\(autoRecycleEvery == 1 ? "" : "s") to discard transcript context.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if autoRecycleEvery > 0 && !agents.isEmpty {
                DisclosureGroup("Per-agent overrides") {
                    ForEach(agents) { agent in
                        HStack {
                            Text(agent.preset.name)
                                .font(.caption)
                                .frame(width: 120, alignment: .leading)
                            Spacer()
                            let binding = Binding(
                                get: { perAgentOverrides[agent.preset.name] ?? 0 },
                                set: { perAgentOverrides[agent.preset.name] = $0 == 0 ? nil : $0 }
                            )
                            Stepper(value: binding, in: 0...100, step: 1) {
                                Text(binding.wrappedValue == 0 ? "Team default" : "Every \(binding.wrappedValue)")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minWidth: 100, alignment: .trailing)
                            }
                            .labelsHidden()
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Agent List

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agents")
                    .font(.subheadline.bold())
                Spacer()

                // 3-mode cost toggle
                if !agents.isEmpty {
                    HStack(spacing: 4) {
                        Button(action: applyMaxCost) {
                            Label("최대 성능", systemImage: "diamond.fill")
                                .font(.caption)
                        }
                        .help("All agents → opus tier (highest cost, best quality)")
                        Button(action: applyBalanced) {
                            Label("균형", systemImage: "scale.3d")
                                .font(.caption)
                        }
                        .help("Restore per-role tiers from current Smart Preset (or sonnet for all if none active)")
                        Button(action: applyMinCost) {
                            Label("최소 비용", systemImage: "leaf.fill")
                                .font(.caption)
                        }
                        .help("All agents → haiku tier (lowest cost)")
                    }
                    .disabled(agents.isEmpty)
                }

                // Bulk model selector — only applies on explicit button click
                if !agents.isEmpty {
                    Button(action: applyModelToAll) {
                        Label("Apply to All", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Change all \(bulkCli) agents' model to \(bulkModel)")
                    Picker("", selection: Binding(
                        get: { bulkCli },
                        set: { newCli in
                            bulkCli = newCli
                            bulkModel = AgentRolePreset.defaultModel(for: newCli)
                        }
                    )) {
                        ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                            Text(cli).tag(cli)
                        }
                    }
                    .frame(width: 85)
                    // Self-healing binding mirrors the leader picker pattern so
                    // bulkModel can never be visually empty when bulkCli changes.
                    Picker("", selection: Binding(
                        get: {
                            let opts = bulkModels
                            if opts.contains(bulkModel) { return bulkModel }
                            let fallback = AgentRolePreset.defaultModel(for: bulkCli)
                            DispatchQueue.main.async { bulkModel = fallback }
                            return fallback
                        },
                        set: { bulkModel = $0 }
                    )) {
                        ForEach(bulkModels, id: \.self) { m in
                            Text(AgentRolePreset.modelDisplayLabel(m, for: bulkCli)).tag(m)
                        }
                    }
                    .frame(width: 130)
                }

                Text("\(agents.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }

            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                agentCard(index: index, agent: agent)
            }
            .onMove { source, destination in
                agents.move(fromOffsets: source, toOffset: destination)
                persistSelectedSmartPresetOverride()
            }

            Button(action: addAgent) {
                Label("Add Agent", systemImage: "plus.circle.fill")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
    }

    private func agentCard(index: Int, agent: TeamAgentRow) -> some View {
        let isCustomized = !agent.customInstructions.isEmpty &&
            agent.customInstructions != agent.preset.instructions
        let isHovered = hoveredAgentId == agent.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Drag handle
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)

                // Agent number badge
                Text("#\(index + 1)")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                // Color dot
                Circle()
                    .fill(agentColor(agent.preset.color))
                    .frame(width: 8, height: 8)

                // Role picker
                Picker("", selection: Binding(
                    get: { agent.preset.id },
                    set: { newId in
                        if let preset = presetManager.presets.first(where: { $0.id == newId }) {
                            agents[index].preset = preset
                            agents[index].customInstructions = ""
                            persistSelectedSmartPresetOverride()
                        }
                    }
                )) {
                    ForEach(presetManager.presets) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
                .frame(width: 120)

                // CLI picker
                Picker("", selection: Binding(
                    get: { agent.preset.cli },
                    set: { newCli in
                        let oldCli = agents[index].preset.cli
                        agents[index].preset.cli = newCli
                        agents[index].providerBadge = .none  // clear badge on manual change
                        // Reset model to CLI default when switching CLI families
                        if AgentRolePreset.models(for: oldCli) != AgentRolePreset.models(for: newCli) {
                            agents[index].preset.model = AgentRolePreset.defaultModel(for: newCli)
                        }
                        persistSelectedSmartPresetOverride()
                    }
                )) {
                    ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                        Text(cli).tag(cli)
                    }
                }
                .frame(width: 90)

                // Model picker — shows CLI-appropriate models.
                // Self-healing: when the agent's CLI flips (e.g. claude→codex), the
                // previously-stored model tier may no longer be valid for the new CLI.
                // Returning a fallback in get + scheduling a state correction keeps
                // the picker from rendering empty before onChange handlers re-sync.
                Picker("", selection: Binding(
                    get: {
                        let opts = AgentRolePreset.models(for: agent.preset.cli)
                        let normalized = AgentRolePreset.normalizeModel(agent.preset.model, for: agent.preset.cli)
                        if opts.contains(normalized) {
                            if normalized != agent.preset.model {
                                DispatchQueue.main.async {
                                    guard index < agents.count else { return }
                                    agents[index].preset.model = normalized
                                }
                            }
                            return normalized
                        }
                        let fallback = AgentRolePreset.defaultModel(for: agent.preset.cli)
                        DispatchQueue.main.async {
                            guard index < agents.count else { return }
                            agents[index].preset.model = fallback
                        }
                        return fallback
                    },
                    set: {
                        agents[index].preset.model = $0
                        persistSelectedSmartPresetOverride()
                    }
                )) {
                    ForEach(AgentRolePreset.models(for: agent.preset.cli), id: \.self) { m in
                        Text(AgentRolePreset.modelDisplayLabel(m, for: agent.preset.cli)).tag(m)
                    }
                }
                .frame(width: 130)

                // Provider badge
                switch agent.providerBadge {
                case .best(let reason):
                    HStack(spacing: 2) {
                        Text("\u{26A1}")
                            .font(.system(size: 9))
                        Text(reason)
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.1)))
                    .help("Optimal provider for this role")
                case .fallback(let wanted):
                    HStack(spacing: 2) {
                        Text("\u{21A9}")
                            .font(.system(size: 9))
                        Text("install \(wanted)")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.1)))
                    .help("Install \(wanted) CLI for optimal performance")
                case .none:
                    EmptyView()
                }

                runbookBadge(for: agent)

                Spacer()

                // Remove button
                Button(action: {
                    agents.remove(at: index)
                    persistSelectedSmartPresetOverride()
                }) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
                .disabled(agents.count <= 1)
            }

            // Custom instructions (collapsible)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        if (agent.customInstructions.isEmpty ? agent.preset.instructions : agent.customInstructions).isEmpty {
                            Text("Enter custom instructions…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: Binding(
                            get: {
                                agent.customInstructions.isEmpty
                                    ? agent.preset.instructions
                                    : agent.customInstructions
                            },
                            set: {
                                agents[index].customInstructions = $0
                                persistSelectedSmartPresetOverride()
                            }
                        ))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                    if isCustomized {
                        Button(action: {
                            agents[index].customInstructions = ""
                            persistSelectedSmartPresetOverride()
                        }) {
                            Label("Reset to default", systemImage: "arrow.counterclockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    // Watcher's custom instructions are the oversight spec — label
                    // it accordingly so users know what to paste here.
                    Text(agent.preset.name == "watcher" ? "Watcher Spec" : "Instructions")
                    if isCustomized {
                        Text("(customized)")
                            .foregroundStyle(.orange.opacity(0.8))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            resolvedPromptDisclosure(for: agent)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(isHovered ? 0.8 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? Color.secondary.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredAgentId = hovering ? agent.id : nil
            }
        }
    }

    // MARK: - Quick Presets (legacy, simple role-only)

    private var workflowButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workflow Presets")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 120), spacing: 6)
            ], spacing: 6) {
                ForEach(WorkflowPresetDefinition.builtIn, id: \.name) { preset in
                    Button(action: { showPreview(for: TemplateID(category: .workflow, slug: preset.id)) }) {
                        HStack(spacing: 6) {
                            Image(systemName: preset.icon)
                                .font(.caption)
                            Text(preset.name)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(selectedWorkflowName == preset.name ? .accentColor : .secondary.opacity(0.7))
                }
            }

            if let selectedWorkflow = WorkflowPresetDefinition.builtIn.first(where: { $0.name == selectedWorkflowName }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested leader mode: \(selectedWorkflow.leaderMode.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Default task templates: \(selectedWorkflow.taskTemplates.joined(separator: " · "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Review checkpoints: \(selectedWorkflow.reviewCheckpoints.joined(separator: " · "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
            }
        }
    }

    private var presetButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Smart Presets — provider-aware
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Smart Presets")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Provider detection status
                    HStack(spacing: 4) {
                        ForEach(ProviderDetector.allCLIs, id: \.self) { cli in
                            HStack(spacing: 2) {
                                Circle()
                                    .fill(providerDetector.isAvailable(cli) ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(cli.capitalized)
                                    .font(.system(size: 9))
                                    .foregroundStyle(providerDetector.isAvailable(cli) ? .primary : .tertiary)
                            }
                        }
                        Button(action: { providerDetector.scan() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help("Rescan installed providers")
                    }
                }

                // Show built-ins + truly-new user customs (parentBuiltInId == nil).
                // v3 "customize" copies (parentBuiltInId != nil) are NOT shown here to avoid duplicates.
                let smartTemplates = teamTemplateManager.templates.filter {
                    $0.id.category == .smart && ($0.origin == .builtIn || $0.parentBuiltInId == nil)
                }
                if smartTemplates.isEmpty {
                    addSmartPresetCard
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 250), spacing: 8)
                    ], spacing: 8) {
                        ForEach(smartTemplates) { template in
                            if case .smart(let basePreset) = template.payload {
                                smartPresetCard(basePreset, template: template)
                            }
                        }
                        addSmartPresetCard
                    }
                    .alert("Delete preset?", isPresented: Binding(
                        get: { deletingSmartPresetId != nil },
                        set: { if !$0 { deletingSmartPresetId = nil } }
                    )) {
                        Button("Cancel", role: .cancel) { deletingSmartPresetId = nil }
                        Button("Delete", role: .destructive) {
                            if let slug = deletingSmartPresetId {
                                let id = TemplateID(category: .smart, slug: slug)
                                try? teamTemplateManager.deleteCustom(id: id)
                                if selectedSmartPresetId == slug { selectedSmartPresetId = nil }
                            }
                            deletingSmartPresetId = nil
                        }
                    } message: {
                        if let slug = deletingSmartPresetId,
                           let name = teamTemplateManager.templates.first(where: { $0.id.slug == slug })?.name {
                            Text("Delete \"\(name)\"?")
                        }
                    }
                }
            }

            Divider().padding(.vertical, 2)

            // Simple presets (quick)
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Presets")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 100), spacing: 6)
                ], spacing: 6) {
                    ForEach(TeamPreset.builtIn, id: \.name) { preset in
                        Button(action: { showPreview(for: TemplateID(category: .quick, slug: preset.slug)) }) {
                            HStack(spacing: 4) {
                                Image(systemName: preset.icon)
                                    .font(.caption2)
                                Text(preset.name)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func smartPresetCard(_ preset: SmartTeamPreset, template: TeamTemplate) -> some View {
        let templateId = TemplateID(category: .smart, slug: preset.id)
        let isUserCustom = template.origin == .custom
        let displayPreset: SmartTeamPreset
        if case .smart(let overridePreset) = teamTemplateManager.effectivePayload(for: templateId) {
            displayPreset = overridePreset
        } else {
            displayPreset = preset
        }
        let resolved = displayPreset.resolve(with: providerDetector)
        let bestCount = resolved.filter { $0.status == .best }.count
        let fbCount = resolved.filter { if case .fallback = $0.status { return true }; return false }.count
        let isSelected = selectedSmartPresetId == preset.id
        let isOverridden = teamTemplateManager.isOverridden(templateId)
        let isHovered = hoveredSmartPresetId == preset.id
        let isEditingName = editingNewSmartPresetSlug == preset.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: displayPreset.icon)
                    .font(.subheadline)
                if isEditingName {
                    TextField("Preset name", text: $newSmartPresetName)
                        .font(.subheadline.bold())
                        .focused($isNewSmartPresetNameFocused)
                        .onSubmit {
                            commitNewPresetName(slug: preset.id)
                        }
                        .onChange(of: isNewSmartPresetNameFocused) { focused in
                            if !focused { commitNewPresetName(slug: preset.id) }
                        }
                } else {
                    Text(displayPreset.name)
                        .font(.subheadline.bold())
                }
                if isOverridden && !isUserCustom {
                    ModifiedPresetBadgeButton {
                        teamTemplateManager.resetOverride(for: templateId)
                        if selectedSmartPresetId == preset.id {
                            applySmartPreset(preset)
                        }
                    }
                }
                Spacer()
                if !isUserCustom && !isOverridden {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if resolved.count > 0 {
                    Text("\(resolved.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }

            Text(displayPreset.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Resolved agents preview
            HStack(spacing: 4) {
                ForEach(Array(resolved.enumerated()), id: \.offset) { _, agent in
                    HStack(spacing: 2) {
                        Text(agent.role)
                            .font(.system(size: 9, design: .monospaced))
                        if agent.status == .best {
                            Text("\u{26A1}")
                                .font(.system(size: 8))
                        } else if case .fallback = agent.status {
                            Text("\u{21A9}")
                                .font(.system(size: 8))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(badgeBackground(agent.status))
                    )
                }
            }

            // Status line
            if bestCount > 0 || fbCount > 0 {
                HStack(spacing: 8) {
                    if bestCount > 0 {
                        HStack(spacing: 2) {
                            Text("\u{26A1}")
                                .font(.system(size: 8))
                            Text("\(bestCount) optimal")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                        }
                    }
                    if fbCount > 0 {
                        HStack(spacing: 2) {
                            Text("\u{21A9}")
                                .font(.system(size: 8))
                            Text("\(fbCount) fallback")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditingName { applySmartPreset(displayPreset) }
        }
        .onHover { hovered in
            hoveredSmartPresetId = hovered ? preset.id : (hoveredSmartPresetId == preset.id ? nil : hoveredSmartPresetId)
        }
        .overlay(alignment: .topTrailing) {
            if isUserCustom && isHovered {
                Button(action: { deletingSmartPresetId = preset.id }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .accessibilityAddTraits(.isButton)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        )
    }

    private var addSmartPresetCard: some View {
        Button(action: {
            let newId = teamTemplateManager.createBlankSmartPreset(name: "")
            newSmartPresetName = ""
            editingNewSmartPresetSlug = newId.slug
            DispatchQueue.main.async { isNewSmartPresetNameFocused = true }
        }) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Add new")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary.opacity(0.4))
        )
    }

    private func commitNewPresetName(slug: String) {
        guard editingNewSmartPresetSlug == slug else { return }
        let trimmed = newSmartPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let id = TemplateID(category: .smart, slug: slug)
            try? teamTemplateManager.deleteCustom(id: id)
        } else {
            let id = TemplateID(category: .smart, slug: slug)
            if var template = teamTemplateManager.templates.first(where: { $0.id == id }),
               case .smart(var p) = template.payload {
                p.name = trimmed
                template.name = trimmed
                template.payload = .smart(p)
                try? teamTemplateManager.updateCustom(template)
            }
        }
        editingNewSmartPresetSlug = nil
        newSmartPresetName = ""
    }

    private func badgeBackground(_ status: ResolvedAgent.Status) -> Color {
        switch status {
        case .best: return Color.green.opacity(0.15)
        case .fallback: return Color.orange.opacity(0.15)
        case .normal: return Color.secondary.opacity(0.08)
        }
    }

    private struct ModifiedPresetBadgeButton: View {
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 3) {
                    Text("Modified")
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isHovered ? Color.orange : Color.orange.opacity(0.86))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(isHovered ? 0.18 : 0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reset this preset to its built-in defaults")
            .onHover { hovering in
                if hovering && !isHovered {
                    NSCursor.pointingHand.push()
                } else if !hovering && isHovered {
                    NSCursor.pop()
                }
                isHovered = hovering
            }
            .onDisappear {
                if isHovered {
                    NSCursor.pop()
                    isHovered = false
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if creationMode == "new" {
                Button(action: {
                    saveTemplateName = teamName
                    showSaveTemplate = true
                }) {
                    Label("Save as Template", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Save current configuration as template")
                .disabled(agents.isEmpty)
            }

            if let smartPresetId = selectedSmartPresetId,
               teamTemplateManager.isOverridden(TemplateID(category: .smart, slug: smartPresetId)) {
                Button(action: resetSelectedSmartPresetOverride) {
                    Label("Reset Preset", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Restore the selected preset to its built-in defaults")
            }

            Spacer()
            if creationMode == "new" {
                if executionMode == "headless" {
                    Label("Headless", systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.trailing, 4)
                }
                if worktreeMode != "off" {
                    Label(worktreeMode == "shared" ? "Shared Worktree" : "Isolated Worktrees",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(worktreeMode == "shared" ? .blue : .green)
                        .padding(.trailing, 4)
                }
            } else if resumeInFlight {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Resuming…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.trailing, 4)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            if creationMode == "resume" {
                Button("Resume Team") {
                    guard let id = selectedResumeTeamId,
                          let team = resumableTeams.first(where: { $0.teamUuid == id }) else { return }
                    if team.branchDrift != nil {
                        pendingBranchDriftTeam = team
                    } else {
                        invokeResume(team: team, acceptBranchDrift: false)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedResumeTeamId == nil || resumeInFlight)
            } else {
                Button(executionMode == "headless" ? "Create Headless Team" : "Create Team") { createTeam() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(teamName.isEmpty || agents.isEmpty || isTeamNameDuplicate || workingDirectoryError != nil
                              || (leaderPairAutoWatch && leaderMode != "repl" && leaderPairMode != "none" && executionMode != "headless"
                                  && leaderPairSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func addAgent() {
        let available = presetManager.presets
        var preset = available[agents.count % available.count]
        preset.model = defaultModel
        let row = TeamAgentRow(preset: preset, customInstructions: "")
        agents.append(row)
        persistSelectedSmartPresetOverride()
    }

    private func applyQuickPreset(count: Int) {
        let available = presetManager.presets
        agents = (0..<min(count, available.count)).map { i in
            var preset = available[i]
            preset.model = defaultModel
            return TeamAgentRow(preset: preset, customInstructions: "")
        }
    }

    private func applyInitialPreset() {
        let initialId = teamTemplateManager.pinnedId ?? teamTemplateManager.lastSelectedId
        if let initialId,
           initialId.category == .smart,
           let template = teamTemplateManager.template(for: initialId),
           teamTemplateManager.builtInTemplate(for: initialId) != nil {
            applyTemplate(template)
        } else {
            applyQuickPreset(count: 2)
        }
    }

    private func showPreview(for id: TemplateID) {
        previewTemplate = teamTemplateManager.template(for: id)
    }

    private func applyTemplate(_ template: TeamTemplate) {
        try? TeamTemplateManager.shared.setLastSelected(id: template.id)
        let payload = template.origin == .builtIn
            ? (teamTemplateManager.effectivePayload(for: template.id) ?? template.payload)
            : template.payload
        switch payload {
        case .smart(let preset):
            applySmartPreset(preset)
        case .workflow(let preset):
            applyWorkflowPreset(preset)
        case .quick(let preset):
            applyTeamPreset(preset)
        }
    }

    private func customizeTemplate(_ template: TeamTemplate) {
        _ = template
    }

    private func applySmartPreset(_ preset: SmartTeamPreset, useEffectivePayload: Bool = true) {
        let available = presetManager.presets
        let templateId = TemplateID(category: .smart, slug: preset.id)
        let effectivePreset: SmartTeamPreset
        if useEffectivePayload,
           case .smart(let overridePreset) = teamTemplateManager.effectivePayload(for: templateId) {
            effectivePreset = overridePreset
        } else {
            effectivePreset = preset
        }
        let resolved = effectivePreset.resolve(with: providerDetector)
        selectedSmartPresetId = effectivePreset.id
        selectedWorkflowName = nil
        leaderMode = effectivePreset.leaderMode
        if !AgentRolePreset.models(for: effectivePreset.leaderMode).contains(leaderModel) {
            leaderModel = AgentRolePreset.defaultModel(for: effectivePreset.leaderMode)
        }
        try? TeamTemplateManager.shared.setLastSelected(id: templateId)

        agents = resolved.compactMap { agent in
            guard var rolePreset = available.first(where: { $0.name == agent.role })
                    ?? available.first else { return nil as TeamAgentRow? }
            rolePreset.cli = agent.cli
            rolePreset.model = agent.model

            let badge: TeamAgentRow.ProviderBadge
            switch agent.status {
            case .best:
                badge = .best(reason: agent.reason)
            case .fallback(let wanted):
                badge = .fallback(wanted: wanted)
            case .normal:
                badge = .none
            }
            return TeamAgentRow(preset: rolePreset, customInstructions: "", providerBadge: badge)
        }

        if teamName == "my-team" || teamName.isEmpty {
            teamName = effectivePreset.id
        }
        syncBulkFromAgents()
    }

    private func applyTeamPreset(_ preset: TeamPreset) {
        let available = presetManager.presets
        selectedWorkflowName = nil
        selectedSmartPresetId = nil
        try? TeamTemplateManager.shared.setLastSelected(id: TemplateID(category: .quick, slug: preset.slug))
        agents = preset.roles.compactMap { roleName in
            guard var p = available.first(where: { $0.name == roleName })
                    ?? available.first else { return nil as TeamAgentRow? }
            p.cli = bulkCli
            p.model = bulkModel
            return TeamAgentRow(preset: p, customInstructions: "")
        }
    }

    private func applyWorkflowPreset(_ preset: WorkflowPresetDefinition) {
        let available = presetManager.presets
        selectedWorkflowName = preset.name
        selectedSmartPresetId = nil
        leaderMode = preset.leaderMode
        if !AgentRolePreset.models(for: leaderMode).contains(leaderModel) {
            leaderModel = AgentRolePreset.defaultModel(for: leaderMode)
        }
        try? TeamTemplateManager.shared.setLastSelected(id: TemplateID(category: .workflow, slug: preset.id))
        agents = preset.roles.compactMap { roleName in
            guard var p = available.first(where: { $0.name == roleName })
                    ?? available.first else { return nil as TeamAgentRow? }
            p.cli = bulkCli
            p.model = bulkModel
            return TeamAgentRow(preset: p, customInstructions: "")
        }
        if teamName == "my-team" || teamName.isEmpty {
            teamName = preset.id
        }
        syncBulkFromAgents()
    }

    private func saveCurrentAsTemplate() {
        guard !saveTemplateName.isEmpty, !agents.isEmpty else { return }
        let slots = agents.map { row in
            SavedTeamTemplate.AgentSlot(
                roleName: row.preset.name,
                cli: row.preset.cli,
                model: row.preset.model,
                customInstructions: row.customInstructions
            )
        }
        let template = SavedTeamTemplate(name: saveTemplateName, leaderMode: leaderMode, agents: slots)
        savedTemplateManager.add(template)
    }

    private func loadTemplate(_ template: SavedTeamTemplate) {
        teamName = template.name
        leaderMode = template.leaderMode
        if !AgentRolePreset.models(for: leaderMode).contains(leaderModel) {
            leaderModel = AgentRolePreset.defaultModel(for: leaderMode)
        }
        let available = presetManager.presets
        agents = template.agents.compactMap { slot in
            let preset = available.first(where: { $0.name == slot.roleName })
                ?? available.first
            guard var p = preset else { return nil as TeamAgentRow? }
            p.cli = slot.cli
            p.model = slot.model
            return TeamAgentRow(preset: p, customInstructions: slot.customInstructions)
        }
        syncBulkFromAgents()
    }

    private func applyLeaderCLIToAll() {
        guard leaderMode != "repl" else { return }
        for i in agents.indices {
            agents[i].preset.cli = leaderMode
        }
        persistSelectedSmartPresetOverride()
    }

    private func applyModelToAll() {
        for i in agents.indices {
            agents[i].preset.cli = bulkCli
            agents[i].preset.model = bulkModel
            agents[i].providerBadge = .none
        }
        persistSelectedSmartPresetOverride()
    }

    private func applyMaxCost() {
        for i in agents.indices {
            agents[i].preset.model = "opus"
            agents[i].providerBadge = .none
        }
        syncBulkFromAgents()
        persistSelectedSmartPresetOverride()
    }

    private func applyMinCost() {
        for i in agents.indices {
            agents[i].preset.model = "haiku"
            agents[i].providerBadge = .none
        }
        syncBulkFromAgents()
        persistSelectedSmartPresetOverride()
    }

    private func applyBalanced() {
        if let smartPresetId = selectedSmartPresetId,
           let template = teamTemplateManager.template(for: TemplateID(category: .smart, slug: smartPresetId)),
           case .smart(let smart) = template.payload {
            let templateId = TemplateID(category: .smart, slug: smartPresetId)
            let recommendations = Dictionary(
                smart.resolve(with: providerDetector).map { ($0.role, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            if template.origin == .builtIn {
                teamTemplateManager.resetOverride(for: templateId)
            }
            for i in agents.indices {
                let role = agents[i].preset.name
                if let recommended = recommendations[role] {
                    agents[i].preset.model = recommended.model
                    switch recommended.status {
                    case .best:
                        agents[i].providerBadge = .best(reason: recommended.reason)
                    case .fallback(let wanted):
                        agents[i].providerBadge = .fallback(wanted: wanted)
                    case .normal:
                        agents[i].providerBadge = .none
                    }
                } else if let roleDefault = presetManager.presets.first(where: { $0.name == role }) {
                    agents[i].preset.model = roleDefault.model
                    agents[i].providerBadge = .none
                } else {
                    agents[i].preset.model = AgentRolePreset.defaultModel(for: agents[i].preset.cli)
                    agents[i].providerBadge = .none
                }
            }
            syncBulkFromAgents()
            persistSelectedSmartPresetOverride()
        } else {
            for i in agents.indices {
                agents[i].preset.model = "sonnet"
                agents[i].providerBadge = .none
            }
            syncBulkFromAgents()
            persistSelectedSmartPresetOverride()
        }
    }

    private func resetSelectedSmartPresetOverride() {
        guard let smartPresetId = selectedSmartPresetId else { return }
        let templateId = TemplateID(category: .smart, slug: smartPresetId)
        TeamTemplateManager.shared.resetOverride(for: templateId)
        guard case .smart(let preset) = teamTemplateManager.builtInTemplate(for: templateId)?.payload else { return }
        applySmartPreset(preset)
    }

    private func persistSelectedSmartPresetOverride() {
        guard let smartPresetId = selectedSmartPresetId else { return }
        let templateId = TemplateID(category: .smart, slug: smartPresetId)
        // `template(for:)` searches the full list (builtIns + customs), so a
        // user-created custom preset is found here too. Branch on origin so its
        // inline agent/model/CLI/leaderMode edits route to updateCustom (which
        // saves immediately) instead of the builtIn-only saveOverride path —
        // saveOverride resolves its base via builtInTemplate(for:), which is nil
        // for a custom preset, so those edits were silently dropped.
        guard let template = teamTemplateManager.template(for: templateId) else { return }

        switch template.origin {
        case .custom:
            // Base on the custom's own current payload so description /
            // parentBuiltInId and other metadata survive; only the live
            // agents + leaderMode are overwritten.
            guard case .smart(var preset) = template.payload else { return }
            preset.leaderMode = leaderMode
            preset.agents = liveProviderPreferences()
            var updated = template
            updated.payload = .smart(preset)
            try? teamTemplateManager.updateCustom(updated)
        case .builtIn:
            guard let payload = currentSmartPresetPayload(for: smartPresetId) else { return }
            teamTemplateManager.saveOverride(
                for: templateId,
                payload: .smart(payload)
            )
        }
    }

    /// Map the live agent rows to the smart-preset `[ProviderPreference]` schema.
    /// Shared by the custom and builtIn persist branches.
    private func liveProviderPreferences() -> [ProviderPreference] {
        agents.map { row in
            ProviderPreference(
                role: row.preset.name,
                primaryCli: row.preset.cli,
                primaryModel: row.preset.model,
                fallbackCli: row.preset.cli,
                fallbackModel: row.preset.model,
                reason: "Inline edit"
            )
        }
    }

    private func currentSmartPresetPayload(for presetId: String) -> SmartTeamPreset? {
        guard case .smart(var preset) = teamTemplateManager.builtInTemplate(
            for: TemplateID(category: .smart, slug: presetId)
        )?.payload else { return nil }
        preset.leaderMode = leaderMode
        preset.agents = liveProviderPreferences()
        return preset
    }

    private func syncBulkFromAgents() {
        guard !agents.isEmpty else { return }
        let cliCounts = Dictionary(grouping: agents, by: { $0.preset.cli }).mapValues(\.count)
        let modelCounts = Dictionary(grouping: agents, by: { $0.preset.model }).mapValues(\.count)
        bulkCli = cliCounts.max(by: { $0.value < $1.value })?.key ?? bulkCli
        bulkModel = modelCounts.max(by: { $0.value < $1.value })?.key ?? bulkModel
    }

    private func refreshRunbookStatus() {
        runbookStatus = AgentRunbookService.shared.status(workingDirectory: workingDirectory)
    }

    private func runbookBadge(for agent: TeamAgentRow) -> some View {
        let hasCustom = !agent.customInstructions.isEmpty && agent.customInstructions != agent.preset.instructions
        let state = runbookStatus.role(agent.preset.name)?.sourceState ?? .missing
        let label = hasCustom ? "custom" : (state == .missing ? "preset" : "runbook")
        let color: Color = hasCustom ? .orange : (state == .missing ? .secondary : .green)
        return Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.1)))
            .help(hasCustom ? "Team-specific custom instructions" : (state == .missing ? "Using role preset instructions" : "Repo-local runbook will be included"))
    }

    private func resolvedPromptDisclosure(for agent: TeamAgentRow) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    runbookBadge(for: agent)
                    Text(runbookPreviewSummary(for: agent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        refreshRunbookStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh runbook status")
                }

                ScrollView {
                    Text(effectiveRunbookPrompt(for: agent))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .frame(height: 112)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                )
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Label("Resolved Prompt", systemImage: "doc.text.magnifyingglass")
                Text("Read-only")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func effectiveRunbookPrompt(for agent: TeamAgentRow) -> String {
        let customInstructions = agent.customInstructions == agent.preset.instructions
            ? ""
            : agent.customInstructions
        return AgentRunbookService.shared.composeInstructions(
            roleName: agent.preset.name,
            presetInstructions: agent.preset.instructions,
            customInstructions: customInstructions,
            workingDirectory: workingDirectory
        )
    }

    private func runbookPreviewSummary(for agent: TeamAgentRow) -> String {
        let hasCustom = !agent.customInstructions.isEmpty && agent.customInstructions != agent.preset.instructions
        let state = runbookStatus.role(agent.preset.name)?.sourceState ?? .missing
        if hasCustom && state != .missing {
            return "Role preset, repo runbook, and team custom instructions will be merged."
        }
        if hasCustom {
            return "Role preset and team custom instructions will be merged."
        }
        if state != .missing {
            return "Role preset and repo runbook will be merged."
        }
        return "Role preset only. No repo-local runbook exists for this role."
    }

    /// Resolve the current project's working directory from the key window's active tab.
    private func validateWorkingDirectory() {
        let path = TeamCreationRecentDirs.normalize(workingDirectory)
        guard !path.isEmpty else {
            workingDirectoryError = "Directory is required"
            return
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if !exists {
            workingDirectoryError = "Directory does not exist"
        } else if !isDir.boolValue {
            workingDirectoryError = "Path is not a directory"
        } else if !FileManager.default.isReadableFile(atPath: path) {
            workingDirectoryError = "Directory not readable"
        } else {
            workingDirectoryError = nil
        }
    }

    @ViewBuilder
    private var workingDirectoryRow: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Text("Directory")
                    .font(.subheadline.bold())
                Spacer()
                TextField("~/projects", text: Binding(
                    get: { TeamCreationRecentDirs.displayPath(workingDirectory) },
                    set: { workingDirectory = TeamCreationRecentDirs.normalize($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            workingDirectoryError != nil ? Color.red :
                            isDropTargeted ? Color.accentColor :
                            Color.clear,
                            lineWidth: (workingDirectoryError != nil || isDropTargeted) ? 1 : 0
                        )
                )
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    guard exists && isDir.boolValue else { return false }
                    workingDirectory = TeamCreationRecentDirs.normalize(url.path)
                    workingDirectorySource = .userPicked
                    validateWorkingDirectory()
                    return true
                } isTargeted: { targeted in
                    isDropTargeted = targeted
                }

                Button("Choose…") {
                    guard let win = NSApp.keyWindow else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if !workingDirectory.isEmpty {
                        panel.directoryURL = URL(fileURLWithPath: workingDirectory)
                    }
                    panel.beginSheetModal(for: win) { resp in
                        if resp == .OK, let url = panel.url {
                            workingDirectory = TeamCreationRecentDirs.normalize(url.path)
                            workingDirectorySource = .userPicked
                            validateWorkingDirectory()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                let recentDirs = TeamCreationRecentDirs.shared.current()
                Menu("▾") {
                    if recentDirs.isEmpty {
                        Text("No recent directories")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentDirs, id: \.self) { path in
                            Button(TeamCreationRecentDirs.displayPath(path)) {
                                workingDirectory = path
                                workingDirectorySource = .lastUsed
                                validateWorkingDirectory()
                            }
                        }
                        Divider()
                        Button("Clear Recent…", role: .destructive) {
                            TeamCreationRecentDirs.shared.clear()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Recent directories")
            }

            HStack(spacing: 4) {
                if workingDirectorySource == .appLaunch {
                    Text("⚠ source: \(workingDirectorySource.rawValue)")
                        .foregroundStyle(.orange)
                } else {
                    Text("source: \(workingDirectorySource.rawValue)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            if let err = workingDirectoryError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .foregroundStyle(.red)
                }
                .font(.caption)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: workingDirectoryError)
    }

    private func createTeam() {
        let sid: String? = if resumeSession {
            !manualSessionId.trimmingCharacters(in: .whitespaces).isEmpty
                ? manualSessionId.trimmingCharacters(in: .whitespaces)
                : selectedSessionId
        } else {
            nil
        }
        // Drop pair when execution mode is headless (pair is pane-only).
        // Same-CLI pair is allowed — user may want e.g. claude + claude with a different model.
        let effectivePair = executionMode == "headless" ? "none" : leaderPairMode
        let effectivePairSpec = effectivePair == "none" ? "" : leaderPairSpec
        let success = onCreate?(teamName, leaderMode, leaderModel, agents, worktreeMode, executionMode, sid, effectivePair, effectivePair == "none" ? "" : leaderPairModel, effectivePairSpec, workingDirectory) ?? false
        guard success else { return }
        TeamCreationRecentDirs.shared.promote(workingDirectory)
        defaultLeaderMode = leaderMode
        defaultLeaderModel = leaderModel
        if autoRecycleEvery > 0 {
            TeamOrchestrator.shared.setTeamDefaultAutoRecycle(teamName: teamName, every: autoRecycleEvery)
            for (agentName, threshold) in perAgentOverrides where threshold > 0 {
                TeamOrchestrator.shared.setAgentAutoRecycleByName(teamName: teamName, agentName: agentName, every: threshold)
            }
        }
        // Auto watch (PRD §Team Creation): enable watch.on after successful team creation.
        // Fires only when pair is active, spec is non-empty, and mode is pane (not headless).
        let specTrimmed = effectivePairSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        if leaderPairAutoWatch && effectivePair != "none" && !specTrimmed.isEmpty {
            let tName = teamName
            let pairCLI = leaderPairMode
            let pairModel = leaderPairModel.isEmpty ? AgentRolePreset.defaultModel(for: pairCLI) : leaderPairModel
            let stance = leaderPairStance
            let wd = workingDirectory
            let appSock = SocketControlSettings.socketPath()
            DispatchQueue.global(qos: .utility).async {
                var params: [String: Any] = [
                    "team_id": tName,
                    "cli": pairCLI,
                    "model": pairModel,
                    "stance": stance,
                    "working_directory": wd,
                    "spec": specTrimmed,
                ]
                if !appSock.isEmpty {
                    params["app_socket_path"] = appSock
                }
                _ = TermMeshDaemon.shared.rpcCallRaw(method: "watch.on", params: params)
            }
        }
        dismiss()
    }

    private func agentColor(_ name: String) -> Color {
        switch name {
        case "green":   return .green
        case "blue":    return .blue
        case "yellow":  return .yellow
        case "red":     return .red
        case "cyan":    return .cyan
        case "magenta": return .purple
        default:        return .gray
        }
    }
}

private struct TeamTemplatePreviewPanel: View {
    let template: TeamTemplate
    @ObservedObject var providerDetector: ProviderDetector
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: template.previewIcon)
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(template.name)
                            .font(.headline)
                        originBadge
                    }
                    Text(template.previewDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                previewRow(label: "Roles", value: template.previewRoles.joined(separator: ", "))
                previewRow(label: "Instructions excerpt", value: template.instructionsExcerpt)
                previewRow(label: "Best-model Fallback", value: template.hasBestModelFallback ? "Enabled" : "Disabled")
                previewRow(label: "Provider", value: "Claude API")
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Use this preset", action: onUse)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480, height: 340)
    }

    private var originBadge: some View {
        Text(template.origin == .builtIn ? "기본 제공" : "사용자 정의")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary.opacity(0.65)))
    }

    private func previewRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "None" : value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TeamTemplateEditorView: View {
    @ObservedObject private var manager = TeamTemplateManager.shared
    let templateId: TemplateID
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var draft: TeamTemplate?
    @State private var hoveredField: TeamTemplateField?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let draft {
                HStack {
                    Text("Customize")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                VStack(alignment: .leading, spacing: 12) {
                    editableField(.name, title: "Name", draft: draft) {
                        TextField("Preset name", text: nameBinding)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                    }
                    payloadFields(for: draft)
                }
                Divider()
                localOverrideInspector(for: draft)
                HStack {
                    Spacer()
                }
            } else {
                Text("Preset not found")
                    .font(.headline)
                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            draft = manager.template(for: templateId)
            DispatchQueue.main.async {
                nameFocused = true
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft?.name ?? "" },
            set: { draft?.name = $0 }
        )
    }

    @ViewBuilder
    private func payloadFields(for draft: TeamTemplate) -> some View {
        switch draft.payload {
        case .smart:
            editableField(.description, title: "Description", draft: draft) {
                TextField("Description", text: smartDescriptionBinding)
                    .textFieldStyle(.roundedBorder)
            }
            editableField(.leaderMode, title: "Leader Mode", draft: draft) {
                leaderModePicker
            }
            editableField(.agents, title: "Roles", draft: draft) {
                TextField("Roles", text: smartRolesBinding)
                    .textFieldStyle(.roundedBorder)
            }
        case .workflow:
            editableField(.leaderMode, title: "Leader Mode", draft: draft) {
                leaderModePicker
            }
            editableField(.roles, title: "Roles", draft: draft) {
                TextField("Roles", text: workflowRolesBinding)
                    .textFieldStyle(.roundedBorder)
            }
            editableField(.taskTemplates, title: "Task Templates", draft: draft) {
                TextField("Task Templates", text: workflowTaskTemplatesBinding)
                    .textFieldStyle(.roundedBorder)
            }
            editableField(.reviewCheckpoints, title: "Review Checkpoints", draft: draft) {
                TextField("Review Checkpoints", text: workflowReviewCheckpointsBinding)
                    .textFieldStyle(.roundedBorder)
            }
        case .quick:
            editableField(.roles, title: "Roles", draft: draft) {
                TextField("Roles", text: quickRolesBinding)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private func editableField<Content: View>(
        _ field: TeamTemplateField,
        title: String,
        draft: TeamTemplate,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let modified = modifiedFields(for: draft).contains(field)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(modified ? Color.blue : Color.clear)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if modified && hoveredField == field {
                    Button("↺") {
                        reset(field)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset this field to default")
                }
            }
            content()
        }
        .onHover { inside in
            hoveredField = inside ? field : nil
        }
    }

    private var leaderModePicker: some View {
        Picker("", selection: leaderModeBinding) {
            Text("REPL").tag("repl")
            Text("Claude").tag("claude")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private func localOverrideInspector(for draft: TeamTemplate) -> some View {
        let fields = modifiedFields(for: draft)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Local Customizations")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if fields.isEmpty {
                Text("No customizations yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fields, id: \.self) { field in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                        Text(field.displayName)
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modifiedFields(for template: TeamTemplate) -> [TeamTemplateField] {
        guard let parentId = template.parentBuiltInId,
              let parent = manager.builtInTemplate(for: parentId) else {
            return []
        }
        return template.modifiedFields(comparedTo: parent)
    }

    private func reset(_ field: TeamTemplateField) {
        try? manager.resetField(id: templateId, field: field)
        draft = manager.template(for: templateId)
    }

    private func updateDraft(_ mutate: (inout TeamTemplate) -> Void) {
        guard var updated = draft else { return }
        mutate(&updated)
        draft = updated
        try? manager.updateCustom(updated)
    }

    private var leaderModeBinding: Binding<String> {
        Binding(
            get: {
                switch draft?.payload {
                case .smart(let preset):
                    return preset.leaderMode
                case .workflow(let preset):
                    return preset.leaderMode
                default:
                    return "claude"
                }
            },
            set: { value in
                updateDraft { template in
                    switch template.payload {
                    case .smart(var preset):
                        preset.leaderMode = value
                        template.payload = .smart(preset)
                    case .workflow(var preset):
                        preset.leaderMode = value
                        template.payload = .workflow(preset)
                    default:
                        break
                    }
                }
            }
        )
    }

    private var smartDescriptionBinding: Binding<String> {
        Binding(
            get: {
                guard case .smart(let preset) = draft?.payload else { return "" }
                return preset.description
            },
            set: { value in
                updateDraft { template in
                    guard case .smart(var preset) = template.payload else { return }
                    preset.description = value
                    template.payload = .smart(preset)
                }
            }
        )
    }

    private var smartRolesBinding: Binding<String> {
        Binding(
            get: {
                guard case .smart(let preset) = draft?.payload else { return "" }
                return preset.agents.map(\.role).joined(separator: ", ")
            },
            set: { value in
                let roles = splitList(value)
                updateDraft { template in
                    guard case .smart(var preset) = template.payload else { return }
                    preset.agents = roles.enumerated().map { index, role in
                        var preference = index < preset.agents.count
                            ? preset.agents[index]
                            : ProviderPreference(
                                role: role,
                                primaryCli: "claude",
                                primaryModel: "sonnet",
                                fallbackCli: "claude",
                                fallbackModel: "sonnet",
                                reason: "Custom role"
                            )
                        preference.role = role
                        return preference
                    }
                    template.payload = .smart(preset)
                }
            }
        )
    }

    private var workflowRolesBinding: Binding<String> {
        listBinding(
            get: {
                guard case .workflow(let preset) = draft?.payload else { return [] }
                return preset.roles
            },
            set: { roles in
                updateDraft { template in
                    guard case .workflow(var preset) = template.payload else { return }
                    preset.roles = roles
                    template.payload = .workflow(preset)
                }
            }
        )
    }

    private var workflowTaskTemplatesBinding: Binding<String> {
        listBinding(
            get: {
                guard case .workflow(let preset) = draft?.payload else { return [] }
                return preset.taskTemplates
            },
            set: { values in
                updateDraft { template in
                    guard case .workflow(var preset) = template.payload else { return }
                    preset.taskTemplates = values
                    template.payload = .workflow(preset)
                }
            }
        )
    }

    private var workflowReviewCheckpointsBinding: Binding<String> {
        listBinding(
            get: {
                guard case .workflow(let preset) = draft?.payload else { return [] }
                return preset.reviewCheckpoints
            },
            set: { values in
                updateDraft { template in
                    guard case .workflow(var preset) = template.payload else { return }
                    preset.reviewCheckpoints = values
                    template.payload = .workflow(preset)
                }
            }
        )
    }

    private var quickRolesBinding: Binding<String> {
        listBinding(
            get: {
                guard case .quick(let preset) = draft?.payload else { return [] }
                return preset.roles
            },
            set: { roles in
                updateDraft { template in
                    guard case .quick(var preset) = template.payload else { return }
                    preset.roles = roles
                    template.payload = .quick(preset)
                }
            }
        )
    }

    private func listBinding(get: @escaping () -> [String], set: @escaping ([String]) -> Void) -> Binding<String> {
        Binding(
            get: { get().joined(separator: ", ") },
            set: { set(splitList($0)) }
        )
    }

    private func splitList(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension TeamTemplate {
    var previewIcon: String {
        switch payload {
        case .smart(let preset):
            return preset.icon
        case .workflow(let preset):
            return preset.icon
        case .quick(let preset):
            return preset.icon
        }
    }

    var previewDescription: String {
        switch payload {
        case .smart(let preset):
            return preset.description
        case .workflow(let preset):
            return preset.taskTemplates.joined(separator: " · ")
        case .quick(let preset):
            return preset.roles.joined(separator: " · ")
        }
    }

    var previewRoles: [String] {
        switch payload {
        case .smart(let preset):
            return preset.agents.map(\.role)
        case .workflow(let preset):
            return preset.roles
        case .quick(let preset):
            return preset.roles
        }
    }

    var instructionsExcerpt: String {
        switch payload {
        case .smart(let preset):
            return preset.agents.prefix(3).map { "\($0.role): \($0.reason)" }.joined(separator: " · ")
        case .workflow(let preset):
            return preset.reviewCheckpoints.joined(separator: " · ")
        case .quick(let preset):
            return "Uses the selected CLI and model for each role."
        }
    }

    var hasBestModelFallback: Bool {
        if case .smart = payload {
            return true
        }
        return false
    }

    func modifiedFields(comparedTo parent: TeamTemplate) -> [TeamTemplateField] {
        var fields: [TeamTemplateField] = []
        if name != parent.name {
            fields.append(.name)
        }
        switch (payload, parent.payload) {
        case (.smart(let current), .smart(let original)):
            if current.icon != original.icon { fields.append(.icon) }
            if current.description != original.description { fields.append(.description) }
            if current.leaderMode != original.leaderMode { fields.append(.leaderMode) }
            if current.agents != original.agents { fields.append(.agents) }
        case (.workflow(let current), .workflow(let original)):
            if current.icon != original.icon { fields.append(.icon) }
            if current.leaderMode != original.leaderMode { fields.append(.leaderMode) }
            if current.roles != original.roles { fields.append(.roles) }
            if current.taskTemplates != original.taskTemplates { fields.append(.taskTemplates) }
            if current.reviewCheckpoints != original.reviewCheckpoints { fields.append(.reviewCheckpoints) }
        case (.quick(let current), .quick(let original)):
            if current.icon != original.icon { fields.append(.icon) }
            if current.roles != original.roles { fields.append(.roles) }
        default:
            break
        }
        return fields
    }
}

private extension TeamTemplateField {
    var displayName: String {
        switch self {
        case .name:
            return "Name"
        case .icon:
            return "Icon"
        case .description:
            return "Description"
        case .leaderMode:
            return "Leader Mode"
        case .agents:
            return "Roles"
        case .roles:
            return "Roles"
        case .taskTemplates:
            return "Task Templates"
        case .reviewCheckpoints:
            return "Review Checkpoints"
        }
    }
}
