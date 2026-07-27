import SwiftUI

/// Composing the members of a team: who they are, what they run on, and which
/// machine each one lives on.
///
/// Lifted out of the New Agent Team sheet so a project can be created with its
/// team in the same breath without a second implementation of this. There was
/// one, briefly, and it drifted immediately — it could only offer whole saved
/// templates and it opened a workspace the team creation then opened again.
/// One definition, two hosts for it.
///
/// The state it owns is the state that is only about composing: the rows, and
/// the bulk controls that write across them. Everything else — the working
/// directory it predicts remote paths from, and what to do when a change
/// should invalidate the caller's preset selection — is passed in, because
/// those belong to whoever is presenting this.
struct TeamAgentComposer: View {
    @Binding var agents: [TeamAgentRow]
    /// The project's directory here. Used to predict where the same project
    /// would sit on another machine.
    let workingDirectory: String
    /// Called when a row changes in a way that means the caller's chosen
    /// preset no longer describes what is on screen.
    var onComposionChanged: () -> Void = {}
    /// The model a newly added row starts on.
    var defaultModel: String = AgentRolePreset.defaultModel(for: "claude")
    /// The three cost modes, when the presenter has a preset to resolve them
    /// against. Re-applying a smart preset is the caller's knowledge, not
    /// this view's — nil hides the toggle rather than showing one that
    /// cannot answer.
    var onMaxCost: (() -> Void)?
    var onBalanced: (() -> Void)?
    var onMinCost: (() -> Void)?
    /// New Project has a transient default machine that members can inherit.
    /// Other callers leave this off and retain the original explicit host UI.
    var supportsDefaultPlacement = false
    var defaultHostKey: String?
    var defaultHostDirectory = ""
    var inheritedAgentIDs: Set<UUID> = []
    var showsPlacementControls = true
    var onAgentPlacementChanged: (_ agentID: UUID, _ inheritsDefault: Bool) -> Void = { _, _ in }

    @ObservedObject private var presetManager = AgentRolePresetManager.shared
    @ObservedObject private var hostStore = RemoteHostStore.shared

    @State private var runbookStatus = AgentRunbookService.shared.status()
    @State private var hoveredAgentId: UUID?
    @State private var bulkCli: String = "claude"
    @State private var bulkModel: String = AgentRolePreset.defaultModel(for: "claude")
    @State private var bulkHostKey: String?
    @State private var bulkHostDirectory: String = ""
    @State private var bulkUsesDefaultPlacement = true

    private static let defaultPlacementTag = "__term_mesh_default__"
    private static let localPlacementTag = "__term_mesh_local__"

    private var defaultMachineLabel: String {
        guard let defaultHostKey,
              let host = selectablePeers.first(where: { $0.id == defaultHostKey }) else {
            return "This Mac"
        }
        return host.displayName
    }

    /// Every machine that has been configured, connected or not.
    ///
    /// A peer that is merely idle is still a place to put a member; hiding it
    /// made the list shorter than the settings with nothing saying why.
    private var selectablePeers: [HostEntry] {
        hostStore.sortedHosts.filter { !($0.sshTarget ?? "").isEmpty }
    }

    var body: some View {
        agentList
            .onAppear {
                syncBulkFromAgents()
                refreshRunbookStatus()
            }
            // The rows are what these summarise, so they follow the rows
            // rather than whatever the caller remembered to call.
            .onChange(of: agents) { _, _ in syncBulkFromAgents() }
            .onChange(of: workingDirectory) { _, _ in refreshRunbookStatus() }
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agents")
                    .font(.subheadline.bold())
                Spacer()

                // 3-mode cost toggle
                if !agents.isEmpty,
                   let onMaxCost, let onBalanced, let onMinCost {
                    HStack(spacing: 4) {
                        Button(action: onMaxCost) {
                            Label("최대 성능", systemImage: "diamond.fill")
                                .font(.caption)
                        }
                        .help("All agents → opus tier (highest cost, best quality)")
                        Button(action: onBalanced) {
                            Label("균형", systemImage: "scale.3d")
                                .font(.caption)
                        }
                        .help("Restore per-role tiers from current Smart Preset (or sonnet for all if none active)")
                        Button(action: onMinCost) {
                            Label("최소 비용", systemImage: "leaf.fill")
                                .font(.caption)
                        }
                        .help("All agents → haiku tier (lowest cost)")
                    }
                    .disabled(agents.isEmpty)
                }

                Text("\(agents.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }

            // Keep the two bulk operations on their own line. Their previous
            // position beside the title pushed the machine controls beyond
            // the fixed-width New Project sheet, making them exist but
            // impossible to see or use.
            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
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
                        Button(action: applyModelToAll) {
                            Label("Apply to All", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Change all \(bulkCli) agents' model to \(bulkModel)")
                        Spacer()
                    }

                    if showsPlacementControls {
                        HStack(spacing: 8) {
                            Text("Runs on")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Picker("", selection: Binding(
                                get: {
                                    if supportsDefaultPlacement && bulkUsesDefaultPlacement {
                                        return Self.defaultPlacementTag
                                    }
                                    return bulkHostKey ?? Self.localPlacementTag
                                },
                                set: { selection in
                                    if selection == Self.defaultPlacementTag {
                                        bulkUsesDefaultPlacement = true
                                        bulkHostKey = defaultHostKey
                                        bulkHostDirectory = defaultHostDirectory
                                    } else {
                                        bulkUsesDefaultPlacement = false
                                        bulkHostKey = selection == Self.localPlacementTag ? nil : selection
                                        bulkHostDirectory = bulkHostKey
                                            .map { defaultDirectory(forHost: $0, excluding: -1) } ?? ""
                                        connectHostIfNeeded(bulkHostKey)
                                    }
                                }
                            )) {
                                if supportsDefaultPlacement {
                                    Text("Default · \(defaultMachineLabel)")
                                        .tag(Self.defaultPlacementTag)
                                }
                                Text("This Mac").tag(Self.localPlacementTag)
                                ForEach(selectablePeers, id: \.id) { host in
                                    Text(host.displayName).tag(host.id)
                                }
                            }
                            .frame(width: 180)
                            if bulkHostKey != nil && !bulkUsesDefaultPlacement {
                                TextField("Project folder", text: $bulkHostDirectory)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: applyHostToAll) {
                                Label("Apply to All", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Put every agent on this machine, at this path")
                        }
                        .accessibilityIdentifier("teamAgentComposer.bulkPlacement")
                    }
                }
            }

            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                agentCard(index: index, agent: agent)
            }
            .onMove { source, destination in
                agents.move(fromOffsets: source, toOffset: destination)
                onComposionChanged()
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
                    .fill(Self.agentColor(agent.preset.color))
                    .frame(width: 8, height: 8)

                // Role picker
                Picker("", selection: Binding(
                    get: { agent.preset.id },
                    set: { newId in
                        if let preset = presetManager.presets.first(where: { $0.id == newId }) {
                            agents[index].preset = preset
                            agents[index].customInstructions = ""
                            onComposionChanged()
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
                        onComposionChanged()
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
                        onComposionChanged()
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
                    onComposionChanged()
                }) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
                .disabled(agents.count <= 1)
            }

            if showsPlacementControls {
                agentPlacementRow(index: index, agent: agent)
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
                                onComposionChanged()
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
                            onComposionChanged()
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

    private func agentPlacementRow(index: Int, agent: TeamAgentRow) -> some View {
        HStack(spacing: 8) {
            Text("Runs on")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Picker("", selection: Binding(
                get: {
                    if supportsDefaultPlacement && inheritedAgentIDs.contains(agent.id) {
                        return Self.defaultPlacementTag
                    }
                    return agents[index].hostKey ?? Self.localPlacementTag
                },
                set: { selection in
                    if selection == Self.defaultPlacementTag {
                        agents[index].hostKey = defaultHostKey
                        agents[index].hostDirectory = defaultHostKey == nil ? "" : defaultHostDirectory
                        onAgentPlacementChanged(agent.id, true)
                    } else {
                        let newHost = selection == Self.localPlacementTag ? nil : selection
                        agents[index].hostKey = newHost
                        agents[index].hostDirectory = newHost
                            .map { defaultDirectory(forHost: $0, excluding: index) } ?? ""
                        connectHostIfNeeded(newHost)
                        onAgentPlacementChanged(agent.id, false)
                    }
                }
            )) {
                if supportsDefaultPlacement {
                    Text("Default · \(defaultMachineLabel)")
                        .tag(Self.defaultPlacementTag)
                }
                Text("This Mac").tag(Self.localPlacementTag)
                ForEach(selectablePeers, id: \.id) { host in
                    Text(host.isConnected ? host.displayName : "\(host.displayName) — offline")
                        .tag(host.id)
                }
            }
            .frame(width: 180)

            if agents[index].hostKey != nil
                && !(supportsDefaultPlacement && inheritedAgentIDs.contains(agent.id)) {
                TextField("Project folder on that machine", text: Binding(
                    get: { agents[index].hostDirectory },
                    set: {
                        agents[index].hostDirectory = $0
                        onAgentPlacementChanged(agent.id, false)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .help("Primary project folder; an isolated agent worktree is created beside it")
            } else {
                Text("Uses the project machine and destination")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 48)
        .accessibilityIdentifier("teamAgentComposer.agentPlacement.\(agent.id.uuidString)")
    }

    // MARK: - Quick Presets (legacy, simple role-only)


    private func applyModelToAll() {
        for i in agents.indices {
            agents[i].preset.cli = bulkCli
            agents[i].preset.model = bulkModel
            agents[i].providerBadge = .none
        }
        onComposionChanged()
    }




    private func applyHostToAll() {
        for i in agents.indices {
            if supportsDefaultPlacement && bulkUsesDefaultPlacement {
                agents[i].hostKey = defaultHostKey
                agents[i].hostDirectory = defaultHostKey == nil ? "" : defaultHostDirectory
                onAgentPlacementChanged(agents[i].id, true)
            } else {
                agents[i].hostKey = bulkHostKey
                agents[i].hostDirectory = bulkHostKey == nil
                    ? ""
                    : bulkHostDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                connectHostIfNeeded(bulkHostKey)
                onAgentPlacementChanged(agents[i].id, false)
            }
        }
    }

    private func connectHostIfNeeded(_ hostKey: String?) {
        guard let hostKey,
              let host = selectablePeers.first(where: { $0.id == hostKey }),
              !host.isConnected
        else { return }
        hostStore.connectSavedHost(host)
    }

    private func defaultDirectory(forHost hostKey: String, excluding index: Int) -> String {
        if let sibling = agents.enumerated().first(where: { offset, row in
            offset != index && row.hostKey == hostKey && !row.hostDirectory.isEmpty
        })?.element.hostDirectory {
            return sibling
        }
        // What worked last time this project ran on that machine. Being told
        // once is reasonable; being asked again every time is the same answer
        // typed forever.
        if let remembered = RemoteProjectPaths.shared.path(
            host: hostKey, localRoot: workingDirectory
        ) {
            return remembered
        }
        guard let host = selectablePeers.first(where: { $0.id == hostKey }) else { return "" }
        var roots = host.workspaces.flatMap(\.panes).compactMap(\.projectRootPath).filter { !$0.isEmpty }
        roots.append(contentsOf: host.teams.compactMap(\.projectRootPath).filter { !$0.isEmpty })
        let leaf = URL(fileURLWithPath: workingDirectory).lastPathComponent
        if let named = roots.first(where: { URL(fileURLWithPath: $0).lastPathComponent == leaf }) {
            return named
        }
        // Where the machine's own convention says it would go. Ahead of the
        // unrelated directories below because a prediction about this project
        // beats a fact about a different one — and it answers on the first
        // run, when there is nothing yet to remember or report.
        if let predicted = PeerHostProfileStore.shared.profiles
            .first(where: { $0.stableKey == hostKey })?
            .predictedProjectPath(forProjectNamed: leaf) {
            return predicted
        }
        // Failing everything specific, somewhere on the right machine — enough
        // to correct rather than compose from nothing.
        return roots.first ?? RemoteProjectPaths.shared.anyPath(host: hostKey) ?? ""
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

    /// Shared with the sheet that presents this: the same names have to draw
    /// the same colours on both sides, and two copies of a switch is how they
    /// stop doing that.
    static func agentColor(_ name: String) -> Color {
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

    private var bulkModels: [String] {
        AgentRolePreset.models(for: bulkCli)
    }

    private func addAgent() {
        let available = presetManager.presets
        var preset = available[agents.count % available.count]
        preset.model = defaultModel
        let row = TeamAgentRow(preset: preset, customInstructions: "")
        agents.append(row)
        onComposionChanged()
    }

    private func syncBulkFromAgents() {
        guard !agents.isEmpty else { return }
        let cliCounts = Dictionary(grouping: agents, by: { $0.preset.cli }).mapValues(\.count)
        let modelCounts = Dictionary(grouping: agents, by: { $0.preset.model }).mapValues(\.count)
        bulkCli = cliCounts.max(by: { $0.value < $1.value })?.key ?? bulkCli
        bulkModel = modelCounts.max(by: { $0.value < $1.value })?.key ?? bulkModel
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

    private func refreshRunbookStatus() {
        runbookStatus = AgentRunbookService.shared.status(workingDirectory: workingDirectory)
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

}
