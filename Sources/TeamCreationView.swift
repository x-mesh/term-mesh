import SwiftUI

/// A row representing one agent slot in the team creation form.
struct TeamAgentRow: Identifiable {
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

/// Sheet for creating a new multi-agent team.
struct TeamCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presetManager = AgentRolePresetManager.shared
    @ObservedObject var templateManager = TeamTemplateManager.shared
    @ObservedObject var providerDetector = ProviderDetector.shared

    var onCreate: ((_ teamName: String, _ leaderMode: String, _ leaderModel: String, _ agents: [TeamAgentRow], _ worktreeMode: String, _ executionMode: String) -> Void)?

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
    @State private var hoveredAgentId: UUID?
    @State private var bulkModel = "sonnet"
    @State private var selectedSmartPresetId: String?
    @State private var worktreeMode = "off"  // "off", "shared", "isolated"
    @State private var executionMode = "pane"  // "pane" or "headless"
    @State private var showDaemonWarning = false

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
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
            Divider()
            footer
        }
        .frame(width: 880, height: 850)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            leaderMode = defaultLeaderMode
            leaderModel = defaultLeaderModel
            bulkModel = defaultModel
            worktreeMode = TermMeshDaemon.shared.worktreeEnabled ? "isolated" : "off"
            if agents.isEmpty {
                applyQuickPreset(count: 2)
            }
        }
        .sheet(isPresented: $showPresetEditor) {
            RolePresetEditorView()
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
                if templateManager.templates.isEmpty {
                    Text("No saved templates").foregroundStyle(.secondary)
                } else {
                    ForEach(templateManager.templates) { template in
                        Button(action: { loadTemplate(template) }) {
                            Text("\(template.name) (\(template.agents.count) agents)")
                        }
                    }
                    Divider()
                    Menu("Delete…") {
                        ForEach(templateManager.templates) { template in
                            Button(template.name, role: .destructive) {
                                templateManager.delete(template)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("Load")
                    if !templateManager.templates.isEmpty {
                        Text("(\(templateManager.templates.count))")
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
                    }
                )) {
                    Text("REPL (Manual)").tag("repl")
                    ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                        Text("\(cli.capitalized) (Auto)").tag(cli)
                    }
                }
                .frame(width: 180)

                if leaderMode != "repl" {
                    Picker("", selection: $leaderModel) {
                        ForEach(AgentRolePreset.models(for: leaderMode), id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .frame(width: 130)
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
                .frame(width: 160)
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
                .frame(width: 240)
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
        }
    }

    // MARK: - Agent List

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agents")
                    .font(.subheadline.bold())
                Spacer()

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
                    Picker("", selection: $bulkModel) {
                        ForEach(bulkModels, id: \.self) { m in
                            Text(m).tag(m)
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
                    }
                )) {
                    ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                        Text(cli).tag(cli)
                    }
                }
                .frame(width: 90)

                // Model picker — shows CLI-appropriate models
                Picker("", selection: Binding(
                    get: { agent.preset.model },
                    set: { agents[index].preset.model = $0 }
                )) {
                    ForEach(AgentRolePreset.models(for: agent.preset.cli), id: \.self) { m in
                        Text(m).tag(m)
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

                Spacer()

                // Remove button
                Button(action: { agents.remove(at: index) }) {
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
                            set: { agents[index].customInstructions = $0 }
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
                    Text("Instructions")
                    if isCustomized {
                        Text("(customized)")
                            .foregroundStyle(.orange.opacity(0.8))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

    /// Named team preset: a display name + list of role names to compose.
    private struct TeamPreset {
        let name: String
        let icon: String
        let roles: [String]
    }

    private static let teamPresets: [TeamPreset] = [
        TeamPreset(name: "2 Agents", icon: "person.2", roles: ["explorer", "executor"]),
        TeamPreset(name: "3 Agents", icon: "person.3", roles: ["explorer", "executor", "reviewer"]),
        TeamPreset(name: "Debug Squad", icon: "ladybug", roles: ["debugger", "tester", "explorer"]),
        TeamPreset(name: "Deep Search", icon: "magnifyingglass", roles: ["explorer", "researcher", "architect"]),
        TeamPreset(name: "Ship It", icon: "shippingbox", roles: ["executor", "tester", "writer", "devops"]),
        TeamPreset(name: "Super Team", icon: "star.circle", roles: [
            "planner", "architect", "explorer",
            "executor", "frontend", "backend",
            "tester", "reviewer", "security", "writer"
        ]),
    ]

    private var workflowButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workflow Presets")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 120), spacing: 6)
            ], spacing: 6) {
                ForEach(WorkflowPresetDefinition.builtIn, id: \.name) { preset in
                    Button(action: { applyWorkflowPreset(preset) }) {
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

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 250), spacing: 8)
                ], spacing: 8) {
                    ForEach(SmartTeamPreset.builtIn) { preset in
                        smartPresetCard(preset)
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
                    ForEach(Self.teamPresets, id: \.name) { preset in
                        Button(action: { applyTeamPreset(preset) }) {
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

    private func smartPresetCard(_ preset: SmartTeamPreset) -> some View {
        let resolved = preset.resolve(with: providerDetector)
        let bestCount = resolved.filter { $0.status == .best }.count
        let fbCount = resolved.filter { if case .fallback = $0.status { return true }; return false }.count
        let isSelected = selectedSmartPresetId == preset.id

        return Button(action: { applySmartPreset(preset) }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: preset.icon)
                        .font(.subheadline)
                    Text(preset.name)
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(resolved.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }

                Text(preset.description)
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
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        )
    }

    private func badgeBackground(_ status: ResolvedAgent.Status) -> Color {
        switch status {
        case .best: return Color.green.opacity(0.15)
        case .fallback: return Color.orange.opacity(0.15)
        case .normal: return Color.secondary.opacity(0.08)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
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

            Spacer()
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
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(executionMode == "headless" ? "Create Headless Team" : "Create Team") { createTeam() }
                .keyboardShortcut(.defaultAction)
                .disabled(teamName.isEmpty || agents.isEmpty || isTeamNameDuplicate)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func addAgent() {
        let available = presetManager.presets
        var preset = available[agents.count % available.count]
        preset.model = defaultModel
        agents.append(TeamAgentRow(preset: preset, customInstructions: ""))
    }

    private func applyQuickPreset(count: Int) {
        let available = presetManager.presets
        agents = (0..<min(count, available.count)).map { i in
            var preset = available[i]
            preset.model = defaultModel
            return TeamAgentRow(preset: preset, customInstructions: "")
        }
    }

    private func applySmartPreset(_ preset: SmartTeamPreset) {
        let available = presetManager.presets
        let resolved = preset.resolve(with: providerDetector)
        selectedSmartPresetId = preset.id
        selectedWorkflowName = nil
        leaderMode = preset.leaderMode

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
            teamName = preset.id
        }
        syncBulkFromAgents()
    }

    private func applyTeamPreset(_ preset: TeamPreset) {
        let available = presetManager.presets
        selectedWorkflowName = nil
        selectedSmartPresetId = nil
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
        agents = preset.roles.compactMap { roleName in
            guard var p = available.first(where: { $0.name == roleName })
                    ?? available.first else { return nil as TeamAgentRow? }
            p.cli = bulkCli
            p.model = bulkModel
            return TeamAgentRow(preset: p, customInstructions: "")
        }
        if teamName == "my-team" || teamName.isEmpty {
            teamName = preset.name.lowercased().replacingOccurrences(of: " ", with: "-")
        }
        syncBulkFromAgents()
    }

    private func saveCurrentAsTemplate() {
        guard !saveTemplateName.isEmpty, !agents.isEmpty else { return }
        let slots = agents.map { row in
            TeamTemplate.AgentSlot(
                roleName: row.preset.name,
                cli: row.preset.cli,
                model: row.preset.model,
                customInstructions: row.customInstructions
            )
        }
        let template = TeamTemplate(name: saveTemplateName, leaderMode: leaderMode, agents: slots)
        templateManager.add(template)
    }

    private func loadTemplate(_ template: TeamTemplate) {
        teamName = template.name
        leaderMode = template.leaderMode
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
    }

    private func applyModelToAll() {
        for i in agents.indices {
            agents[i].preset.model = bulkModel
            agents[i].providerBadge = .none
        }
    }

    private func syncBulkFromAgents() {
        guard !agents.isEmpty else { return }
        let cliCounts = Dictionary(grouping: agents, by: { $0.preset.cli }).mapValues(\.count)
        let modelCounts = Dictionary(grouping: agents, by: { $0.preset.model }).mapValues(\.count)
        bulkCli = cliCounts.max(by: { $0.value < $1.value })?.key ?? bulkCli
        bulkModel = modelCounts.max(by: { $0.value < $1.value })?.key ?? bulkModel
    }

    private func createTeam() {
        defaultLeaderModel = leaderModel
        onCreate?(teamName, leaderMode, leaderModel, agents, worktreeMode, executionMode)
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
