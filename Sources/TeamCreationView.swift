import SwiftUI

/// A row representing one agent slot in the team creation form.
struct TeamAgentRow: Identifiable {
    let id = UUID()
    var preset: AgentRolePreset
    var customInstructions: String  // overrides preset instructions if non-empty
}

/// Sheet for creating a new multi-agent team.
struct TeamCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presetManager = AgentRolePresetManager.shared
    @ObservedObject var templateManager = TeamTemplateManager.shared

    var onCreate: ((_ teamName: String, _ leaderMode: String, _ agents: [TeamAgentRow]) -> Void)?

    @AppStorage("teamDefaultLeaderMode") private var defaultLeaderMode = "claude"
    @AppStorage("teamDefaultModel") private var defaultModel = "sonnet"

    @State private var teamName = "my-team"
    @State private var leaderMode = "repl"  // "repl" or "claude"
    @State private var agents: [TeamAgentRow] = []
    @State private var showPresetEditor = false
    @State private var showSaveTemplate = false
    @State private var saveTemplateName = ""

    private let models = ["sonnet", "opus", "haiku"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    teamSettings
                    agentList
                    presetButtons
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            leaderMode = defaultLeaderMode
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

            // Save current config as template
            Button(action: {
                saveTemplateName = teamName
                showSaveTemplate = true
            }) {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Save current configuration as template")
            .disabled(agents.isEmpty)

            // Load saved template
            if !templateManager.templates.isEmpty {
                Menu {
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
                } label: {
                    Label("Load", systemImage: "folder")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Load saved team template")
            }

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
            HStack {
                Text("Team Name")
                    .font(.subheadline.bold())
                Spacer()
                TextField("team name", text: $teamName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            HStack {
                Text("Leader")
                    .font(.subheadline.bold())
                Spacer()
                Picker("", selection: $leaderMode) {
                    Text("REPL (Manual)").tag("repl")
                    Text("Claude (Auto)").tag("claude")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Color dot
                Circle()
                    .fill(agentColor(agent.preset.color))
                    .frame(width: 10, height: 10)

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
                .frame(width: 130)

                // CLI picker
                Picker("", selection: Binding(
                    get: { agent.preset.cli },
                    set: { agents[index].preset.cli = $0 }
                )) {
                    ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                        Text(cli).tag(cli)
                    }
                }
                .frame(width: 75)

                // Model picker
                Picker("", selection: Binding(
                    get: { agent.preset.model },
                    set: { agents[index].preset.model = $0 }
                )) {
                    ForEach(models, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .frame(width: 90)

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
            DisclosureGroup("Instructions") {
                TextEditor(text: Binding(
                    get: {
                        agent.customInstructions.isEmpty
                            ? agent.preset.instructions
                            : agent.customInstructions
                    },
                    set: { agents[index].customInstructions = $0 }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - Quick Presets

    /// Named team preset: a display name + list of role names to compose.
    private struct TeamPreset {
        let name: String
        let icon: String
        let roles: [String]
    }

    private static let teamPresets: [TeamPreset] = [
        // --- Basic ---
        TeamPreset(name: "2 Agents", icon: "person.2", roles: ["explorer", "executor"]),
        TeamPreset(name: "3 Agents", icon: "person.3", roles: ["explorer", "executor", "reviewer"]),

        // --- Workflows ---
        TeamPreset(name: "Deep Search", icon: "magnifyingglass", roles: ["explorer", "researcher", "architect"]),
        TeamPreset(name: "Debug Squad", icon: "ladybug", roles: ["debugger", "tester", "explorer"]),
        TeamPreset(name: "Code Review", icon: "checkmark.seal", roles: ["reviewer", "security", "tester"]),
        TeamPreset(name: "Refactor", icon: "arrow.triangle.2.circlepath", roles: ["refactorer", "reviewer", "tester"]),
        TeamPreset(name: "Feature Build", icon: "hammer", roles: ["planner", "executor", "tester", "reviewer"]),
        TeamPreset(name: "Full Stack", icon: "rectangle.stack", roles: ["frontend", "backend", "tester", "reviewer"]),
        TeamPreset(name: "Ship It", icon: "shippingbox", roles: ["executor", "tester", "writer", "devops"]),
        TeamPreset(name: "Research", icon: "book", roles: ["researcher", "architect", "planner"]),
        TeamPreset(name: "Performance", icon: "gauge.high", roles: ["perf", "debugger", "tester"]),
        TeamPreset(name: "Security Audit", icon: "lock.shield", roles: ["security", "reviewer", "explorer"]),
        TeamPreset(name: "Full Team", icon: "person.3.sequence", roles: ["planner", "explorer", "executor", "reviewer", "tester"]),
    ]

    private var presetButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Team Presets")
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Team") { createTeam() }
                .keyboardShortcut(.defaultAction)
                .disabled(teamName.isEmpty || agents.isEmpty)
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

    private func applyTeamPreset(_ preset: TeamPreset) {
        let available = presetManager.presets
        agents = preset.roles.compactMap { roleName in
            if let match = available.first(where: { $0.name == roleName }) {
                return TeamAgentRow(preset: match, customInstructions: "")
            }
            // Fallback: use first available preset if role not found
            return available.first.map { TeamAgentRow(preset: $0, customInstructions: "") }
        }
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
    }

    private func createTeam() {
        onCreate?(teamName, leaderMode, agents)
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
