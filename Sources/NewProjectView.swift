import Foundation
import SwiftUI

struct ProjectBootStep: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case running
        case completed
        case failed(String)
    }

    let id: String
    let order: Int
    var title: String
    var detail: String
    var command: String?
    var status: Status
}

enum ProjectCreationEvent: Equatable {
    case planned(ProjectBootStep)
    case started(ProjectBootStep)
    case completed(id: String, detail: String?)
    case failed(id: String, message: String)
}

/// Starting a project: what it is, where it lives, and who works on it.
///
/// The New Agent Team sheet was doing this job because it was the only thing
/// that could compose a team, and most of it is wrong for the question.
/// "Resume from previous team" is a team's lifecycle, not a project's. Pair
/// mode, worktree isolation, execution mode and auto-recycle are knobs for a
/// team you are about to run, asked of someone who has not decided what they
/// are building yet. A project is made once and lived in; a team is made often
/// and thrown away.
///
/// So this asks the project's questions and hands the rest to the same
/// composer the team sheet uses. One definition of agent composition, two
/// places that present it — because the moment there are two, they drift, and
/// today they did.
struct NewProjectView: View {
    /// `localDirectory` is where the window opens here; `rows` already carry
    /// the machine and path each member actually works in.
    let onCreate: (
        _ name: String,
        _ localDirectory: String,
        _ rows: [TeamAgentRow],
        _ source: ProjectSource,
        _ leader: ProjectLeader,
        _ progress: @escaping @MainActor (ProjectCreationEvent) -> Void
    ) async throws -> Void
    let onClose: () -> Void
    /// Local repositories the app already knows about. Their `origin` remotes
    /// become lightweight autocomplete suggestions; no home-directory scan is
    /// needed just to open this sheet.
    let repositoryDirectories: [String]
    /// Roots that may contain projects not currently open in term-mesh.
    /// Discovery is shallow, bounded and runs off-main.
    let repositorySearchRoots: [String]

    @State private var directory: String = ""
    @State private var name: String = ""
    @State private var sourceKind: ProjectSourceKind = .clone
    @State private var nameEdited = false
    /// Whether the folder has been typed into directly, which stops the name
    /// from moving it.
    @State private var folderEdited = false
    /// Placement inheritance is transient form state. TeamAgentRow keeps the
    /// resolved host for the existing creation API.
    @State private var knownAgentIDs: Set<UUID> = []
    @State private var inheritedAgentIDs: Set<UUID> = []
    @State private var agents: [TeamAgentRow] = []
    /// The machine the leader and primary checkout live on.
    ///
    /// Asked first because everything after it depends on the answer. A folder
    /// on this Mac is chosen with a file panel; a folder on another machine is
    /// a path typed against that machine's own conventions, and no panel here
    /// can browse it. Getting this backwards meant offering a local picker for
    /// a directory that was never going to be local.
    @State private var runsOnHostKey: String?
    /// Where the project comes from. A folder that is already there, or a
    /// repository to clone onto that machine.
    @State private var gitURL: String = ""
    @State private var gitBranch: String = ""
    @State private var repositoryBranches: [String] = []
    @State private var defaultRepositoryBranch: String?
    @State private var isLoadingRepositoryBranches = false
    @State private var repositoryBranchError: String?
    @State private var branchEdited = false
    @State private var repositoryURLSuggestions: [String] = []
    @State private var isLoadingRepositorySuggestions = false
    @State private var showsTeamEditor = false
    @State private var showsAdvancedOptions = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case repositoryURL
        case repositoryBranch
        case name
        case directory
    }
    /// Whether each agent gets its own checkout.
    ///
    /// On by default because agents sharing one directory collide in every way
    /// that matters — one branch between them, one set of files, one
    /// dependency tree with several writers — and the collision is quiet until
    /// it is expensive.
    @State private var isolateAgents = true
    /// Who runs the project.
    ///
    /// An agent CLI, not the manual console. A project's leader is the thing
    /// that reads the work and decides who does what — that is the job of a
    /// model, and the REPL is a keyboard shortcut list for a person driving by
    /// hand. It stays on the menu for anyone who wants it and it is not what
    /// starting a project means.
    @State private var leaderCli = "claude"
    @State private var leaderModel = "opus"
    @State private var selectedTeamPresetId: TemplateID?
    @State private var appliedTeamSignature: TeamSignature?
    @State private var showingSavePreset = false
    @State private var showingManagePresets = false
    @State private var savePresetName = ""
    @State private var presetSaveConfirmation: String?
    @State private var presetError: String?
    @State private var creationError: String?
    @State private var showsCreationProgress = false
    @State private var creationStartedAt: Date?
    @State private var bootSteps: [ProjectBootStep] = []
    @State private var showsBootCommands = true
    @State private var agentPlacementMode: AgentPlacementMode = .sameAsLeader
    @State private var allAgentsHostKey: String?

    enum AgentPlacementMode: String, CaseIterable {
        case sameAsLeader
        case allOnOneMachine
        case perAgent

        var label: String {
            switch self {
            case .sameAsLeader: "Same as leader"
            case .allOnOneMachine: "All on one machine"
            case .perAgent: "Choose per agent"
            }
        }
    }

    @ObservedObject private var presetManager = AgentRolePresetManager.shared
    @ObservedObject private var teamTemplateManager = TeamTemplateManager.shared
    @ObservedObject private var providerDetector = ProviderDetector.shared
    @ObservedObject private var hostStore = RemoteHostStore.shared

    private struct TeamSignature: Equatable {
        struct Agent: Equatable {
            let role: String
            let cli: String
            let model: String
            let instructions: String
        }

        let leaderCli: String
        let leaderModel: String?
        let agents: [Agent]
    }

    private var trimmedDirectory: String {
        directory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        // Empty in, empty out. `URL(fileURLWithPath: "")` resolves against the
        // process directory and hands back "/" as its last component, which
        // then appends to a project root as nothing at all — the predicted
        // folder came out as the root itself, the name was read back off it,
        // and every agent checkout landed as a sibling of the root rather than
        // inside the project.
        guard !trimmedDirectory.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmedDirectory).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if showsCreationProgress {
                bootProgressView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        projectFields
                        Divider()
                        teamSummaryRow
                        if showsTeamEditor {
                            teamPresetRow
                            teamRuntimeRow
                            TeamAgentComposer(
                                agents: $agents,
                                workingDirectory: trimmedDirectory,
                                onComposionChanged: {},
                                defaultModel: AgentRolePreset.defaultModel(for: "claude"),
                                usesCompactRows: true,
                                supportsDefaultPlacement: true,
                                defaultHostKey: defaultAgentHostKey,
                                defaultHostDirectory: defaultAgentHostDirectory,
                                inheritedAgentIDs: inheritedAgentIDs,
                                showsPlacementControls: agentPlacementMode == .perAgent,
                                showsBulkPlacementControls: false,
                                onAgentPlacementChanged: { id, inheritsDefault in
                                    if inheritsDefault {
                                        inheritedAgentIDs.insert(id)
                                    } else {
                                        inheritedAgentIDs.remove(id)
                                    }
                                }
                            )
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 620)
        .onAppear {
            applyInitialTeamPreset()
            adoptProjectMachineForNewRows()
            applyDerivedDestination()
            focusedField = .repositoryURL
        }
        .task(id: repositoryDiscoveryID) {
            let directories = repositoryDirectories
            let roots = repositorySearchRoots
            isLoadingRepositorySuggestions = true
            let suggestions = await Task.detached(priority: .utility) {
                RepositoryURLAutocomplete.loadOriginURLs(
                    from: directories,
                    searching: roots
                )
            }.value
            guard !Task.isCancelled else { return }
            repositoryURLSuggestions = suggestions
            isLoadingRepositorySuggestions = false
        }
        .task(id: branchLookupID) {
            await loadRepositoryBranches()
        }
        .onChange(of: agents.map(\.id)) { _, _ in
            adoptProjectMachineForNewRows()
        }
        .sheet(isPresented: $showingSavePreset) {
            savePresetSheet
        }
        .sheet(isPresented: $showingManagePresets) {
            TeamPresetManagerSheet(
                manager: teamTemplateManager,
                selectedId: $selectedTeamPresetId,
                onDeleteSelected: {
                    appliedTeamSignature = nil
                }
            )
        }
        .alert("Preset could not be saved", isPresented: Binding(
            get: { presetError != nil },
            set: { if !$0 { presetError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presetError ?? "")
        }
        .accessibilityIdentifier("newProject.sheet")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(.tint)
            Text("New Project")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var bootProgressView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(creationError == nil ? "Starting \(effectiveName)" : "Could not start \(effectiveName)")
                        .font(.title3.weight(.semibold))
                    Text(bootProgressSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if creationError == nil, let creationStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsedText(from: creationStartedAt, to: context.date))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(bootSteps.sorted(by: { $0.order < $1.order })) { step in
                        bootStepRow(step)
                        if step.id != bootSteps.sorted(by: { $0.order < $1.order }).last?.id {
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }

            Divider()
            Toggle("Show launch commands", isOn: $showsBootCommands)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .accessibilityIdentifier("newProject.bootProgress")
    }

    private func bootStepRow(_ step: ProjectBootStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch step.status {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                case .running:
                    ProgressView()
                        .controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                Text(step.title)
                    .font(.subheadline.weight(step.status == .running ? .semibold : .regular))
                Text(stepDetail(step))
                    .font(.caption)
                    .foregroundStyle(stepFailure(step) == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                if showsBootCommands, let command = step.command, !command.isEmpty {
                    Text("› \(command)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(command)
                }
            }
            Spacer()
        }
        .padding(.vertical, 11)
    }

    private func stepDetail(_ step: ProjectBootStep) -> String {
        if let failure = stepFailure(step) { return failure }
        return step.detail
    }

    private func stepFailure(_ step: ProjectBootStep) -> String? {
        guard case .failed(let message) = step.status else { return nil }
        return message
    }

    private var bootProgressSummary: String {
        let completed = bootSteps.filter { $0.status == .completed }.count
        if creationError != nil {
            return "\(completed) of \(bootSteps.count) steps complete · Check the failed step below"
        }
        return "\(completed) of \(bootSteps.count) steps complete"
    }

    private static func elapsedText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return "\(seconds)s"
    }

    private var teamSummaryRow: some View {
        HStack(spacing: 10) {
            Text("Team")
                .font(.subheadline.bold())
                .frame(width: 120, alignment: .leading)
            Image(systemName: "person.3")
                .foregroundStyle(.secondary)
            Text(teamSummaryTitle)
                .lineLimit(1)
            Text(agentPlacementCompactSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(showsTeamEditor ? "Done" : "Change") {
                withAnimation(.easeOut(duration: 0.18)) {
                    showsTeamEditor.toggle()
                }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("newProject.teamEditorToggle")
        }
    }

    private var teamSummaryTitle: String {
        let leader = leaderCli == "repl"
            ? "Manual REPL"
            : "\(leaderCli.capitalized) \(AgentRolePreset.modelDisplayLabel(leaderModel, for: leaderCli))"
        let members = agents.count == 1
            ? "1 \(agents[0].preset.displayName)"
            : "\(agents.count) agents"
        return "\(teamPresetDisplayName) · \(leader) + \(members)"
    }

    private var teamPresetRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 12) {
            GridRow {
                Text("Team preset")
                    .font(.subheadline.bold())
                HStack(spacing: 8) {
                    Menu {
                        Button("Default · 1 Executor") {
                            applyDefaultTeam()
                        }
                        if !customSmartTemplates.isEmpty {
                            Section("My Presets") {
                                ForEach(customSmartTemplates) { template in
                                    Button(template.name) { applyTemplate(template) }
                                }
                            }
                        }
                        if !builtInSmartTemplates.isEmpty {
                            Section("Built-in") {
                                ForEach(builtInSmartTemplates) { template in
                                    Button(template.name) { applyTemplate(template) }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isTeamCustomized ? "slider.horizontal.3" : "person.3")
                            Text(teamPresetDisplayName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 190, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityIdentifier("newProject.teamPreset")

                    if isTeamCustomized {
                        if selectedTeamPresetIsCustom {
                            Button("Save changes") {
                                saveChangesToSelectedPreset()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("newProject.savePresetChanges")
                        } else {
                            Button("Save as new…") {
                                presentSavePresetSheet()
                            }
                            .accessibilityIdentifier("newProject.savePresetAsNew")
                        }

                        Label("Unsaved", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    } else if let presetSaveConfirmation {
                        Label(presetSaveConfirmation, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Menu {
                        Button("Save as new…") {
                            presentSavePresetSheet()
                        }
                        Button("Revert changes") {
                            revertCurrentTeamChanges()
                        }
                        .disabled(!isTeamCustomized)
                        Divider()
                        Button(selectedPresetIsPinned ? "Unpin preset" : "Use as default") {
                            toggleSelectedPresetPin()
                        }
                        .disabled(selectedTeamPresetId == nil)
                        Button("Manage presets…") {
                            showingManagePresets = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.borderless)
                    .help("More preset actions")
                }
            }
        }
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Team Preset")
                .font(.headline)
            TextField("Preset name", text: $savePresetName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("newProject.savePreset.name")
            Text("Saves the leader and ordered agent roles, CLIs, models, and instructions. Machine and folder choices stay project-specific.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { showingSavePreset = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveCurrentTeamPreset() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(savePresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var customSmartTemplates: [TeamTemplate] {
        teamTemplateManager.customTemplates.filter {
            if case .smart = $0.payload { return true }
            return false
        }
    }

    private var builtInSmartTemplates: [TeamTemplate] {
        teamTemplateManager.templates.filter {
            guard $0.origin == .builtIn else { return false }
            if case .smart = $0.payload { return true }
            return false
        }
    }

    private var currentTeamSignature: TeamSignature {
        TeamSignature(
            leaderCli: leaderCli,
            leaderModel: leaderCli == "repl"
                ? nil
                : AgentRolePreset.normalizeModel(leaderModel, for: leaderCli),
            agents: agents.map {
                TeamSignature.Agent(
                    role: $0.preset.name,
                    cli: $0.preset.cli,
                    model: AgentRolePreset.normalizeModel($0.preset.model, for: $0.preset.cli),
                    instructions: $0.customInstructions
                )
            }
        )
    }

    private var isTeamCustomized: Bool {
        guard let appliedTeamSignature else { return !agents.isEmpty }
        return appliedTeamSignature != currentTeamSignature
    }

    private var teamPresetDisplayName: String {
        if let selectedTeamPresetId,
           let name = teamTemplateManager.template(for: selectedTeamPresetId)?.name {
            return name
        }
        return isTeamCustomized ? "Customized" : "Default · 1 Executor"
    }

    private var selectedTeamPresetIsCustom: Bool {
        guard let selectedTeamPresetId else { return false }
        return teamTemplateManager.template(for: selectedTeamPresetId)?.origin == .custom
    }

    private var suggestedPresetName: String {
        let roles = agents.map(\.preset.displayName)
        if let first = roles.first, roles.allSatisfy({ $0 == first }) {
            return "\(first) \(roles.count)"
        }
        return "My Team \(agents.count)"
    }

    private var selectedPresetIsPinned: Bool {
        selectedTeamPresetId != nil && selectedTeamPresetId == teamTemplateManager.pinnedId
    }

    /// Leader and member placement are one runtime decision. Keeping them in a
    /// single row makes the relationship explicit and puts placement beside
    /// the agent list it controls instead of leaving it as a detached form
    /// section.
    private var teamRuntimeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("Leader")
                    .font(.subheadline.bold())
                    .frame(width: 120, alignment: .leading)

                Picker("", selection: Binding(
                    get: { leaderCli },
                    set: { newCli in
                        let old = leaderCli
                        leaderCli = newCli
                        if AgentRolePreset.models(for: old) != AgentRolePreset.models(for: newCli) {
                            leaderModel = Self.defaultLeaderModel(for: newCli)
                        }
                    }
                )) {
                    ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                        Text(cli.capitalized).tag(cli)
                    }
                    Text("REPL (manual)").tag("repl")
                }
                .labelsHidden()
                .frame(width: 118)

                if leaderCli != "repl" {
                    Picker("", selection: Binding(
                        get: {
                            let options = AgentRolePreset.models(for: leaderCli)
                            let normalized = AgentRolePreset.normalizeModel(leaderModel, for: leaderCli)
                            guard options.contains(normalized) else {
                                let fallback = Self.defaultLeaderModel(for: leaderCli)
                                DispatchQueue.main.async { leaderModel = fallback }
                                return fallback
                            }
                            if normalized != leaderModel {
                                DispatchQueue.main.async { leaderModel = normalized }
                            }
                            return normalized
                        },
                        set: { leaderModel = $0 }
                    )) {
                        ForEach(AgentRolePreset.models(for: leaderCli), id: \.self) { model in
                            Text(AgentRolePreset.modelDisplayLabel(model, for: leaderCli)).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 132)
                } else {
                    Text("Manual console")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 132, alignment: .leading)
                }

                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 4)

                Text("Agents run")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { agentPlacementMode },
                    set: { mode in
                        agentPlacementMode = mode
                        if mode == .allOnOneMachine {
                            allAgentsHostKey = runsOnHostKey
                        }
                        applyAgentPlacementMode()
                    }
                )) {
                    ForEach(AgentPlacementMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 165)
                .accessibilityIdentifier("newProject.agentPlacementMode")

                if agentPlacementMode == .allOnOneMachine {
                    Picker("", selection: $allAgentsHostKey) {
                        Text("This Mac").tag(String?.none)
                        ForEach(selectablePeers, id: \.id) { host in
                            Text(host.isConnected ? host.displayName : "\(host.displayName) — offline")
                                .tag(String?.some(host.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    .accessibilityIdentifier("newProject.allAgentsHost")
                    .onChange(of: allAgentsHostKey) { _, hostKey in
                        connectHostIfNeeded(hostKey)
                        applyAgentPlacementMode()
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Color.clear.frame(width: 390, height: 1)
                Text(agentPlacementDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private var projectFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Project source", selection: $sourceKind) {
                Text("Clone repository").tag(ProjectSourceKind.clone)
                Text("Existing folder").tag(ProjectSourceKind.existingFolder)
                Text("Empty project").tag(ProjectSourceKind.empty)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Project source")

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if sourceKind == .clone {
                    GridRow(alignment: .top) {
                        Text("Repository URL")
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(
                                "git@github.com:org/repo.git",
                                text: Binding(
                                    get: { gitURL },
                                    set: {
                                        gitURL = RepositoryURLAutocomplete.singleLine($0)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
                            .focused($focusedField, equals: .repositoryURL)
                            .accessibilityLabel("Repository URL")

                            if focusedField == .repositoryURL {
                                if isLoadingRepositorySuggestions {
                                    repositoryURLSuggestionLoading
                                } else if !matchingRepositoryURLSuggestions.isEmpty {
                                    repositoryURLSuggestionList
                                } else if shouldShowNoRepositoryMatches {
                                    Text("No saved repositories match “\(gitURL)”")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                }
                            }
                        }
                    }

                    GridRow(alignment: .top) {
                        Text("Branch")
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                TextField(
                                    defaultRepositoryBranch ?? "Default branch",
                                    text: Binding(
                                        get: { gitBranch },
                                        set: {
                                            gitBranch = RepositoryBranchLookup.singleLine($0)
                                            branchEdited = true
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1)
                                .focused($focusedField, equals: .repositoryBranch)
                                .accessibilityLabel("Repository branch")

                                Menu {
                                    ForEach(repositoryBranches, id: \.self) { branch in
                                        Button {
                                            selectRepositoryBranch(branch)
                                        } label: {
                                            if branch == gitBranch {
                                                Label(branch, systemImage: "checkmark")
                                            } else {
                                                Text(branch)
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down")
                                        .frame(width: 18, height: 18)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .disabled(repositoryBranches.isEmpty)
                                .accessibilityLabel("Choose repository branch")
                            }

                            if isLoadingRepositoryBranches {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading branches…")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else if focusedField == .repositoryBranch,
                                      !matchingRepositoryBranches.isEmpty {
                                repositoryBranchSuggestionList
                            } else if let repositoryBranchError {
                                Text(repositoryBranchError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let defaultRepositoryBranch,
                                      !repositoryBranches.isEmpty {
                                Text("\(repositoryBranches.count) branches · Default: \(defaultRepositoryBranch)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if sourceKind == .empty {
                    GridRow {
                        Text("Project name")
                        TextField("project-name", text: Binding(
                            get: { name },
                            set: { name = $0; nameEdited = true }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                    }
                }

                GridRow {
                    Text("Leader runs on")
                    HStack(spacing: 8) {
                        Picker("", selection: $runsOnHostKey) {
                            Text("This Mac").tag(String?.none)
                            ForEach(selectablePeers, id: \.id) { host in
                                Text(host.isConnected ? host.displayName : "\(host.displayName) — offline")
                                    .tag(String?.some(host.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        if let runsOnHostKey,
                           let host = selectablePeers.first(where: { $0.id == runsOnHostKey }),
                           !host.isConnected {
                            Label("connecting…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if sourceKind == .existingFolder {
                    GridRow {
                        Text("Project folder")
                        HStack(spacing: 6) {
                            TextField(folderPlaceholder, text: Binding(
                                get: { directory },
                                set: { directory = $0; folderEdited = true }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .directory)
                            if runsOnHostKey == nil {
                                Button("Choose…", action: chooseFolder)
                            }
                        }
                    }
                } else {
                    GridRow {
                        Text("Destination")
                        HStack(spacing: 8) {
                            Text(trimmedDirectory.isEmpty ? "Choose a leader machine and name" : trimmedDirectory)
                                .foregroundStyle(trimmedDirectory.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("Automatic")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsAdvancedOptions.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showsAdvancedOptions ? 90 : 0))
                    Text("Advanced options")
                        .font(.caption)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsAdvancedOptions ? "Hide advanced options" : "Show advanced options")

            if showsAdvancedOptions {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    if sourceKind == .clone {
                        GridRow {
                            Text("Project name")
                            TextField("project-name", text: Binding(
                                get: { name },
                                set: { name = $0; nameEdited = true }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .name)
                        }
                    }

                    if sourceKind != .existingFolder {
                        GridRow {
                            Text("Destination")
                            TextField(folderPlaceholder, text: Binding(
                                get: { directory },
                                set: { directory = $0; folderEdited = true }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .directory)
                        }
                    }

                    GridRow {
                        Text("Agent checkouts")
                        if sourceKind == .existingFolder && gitURL.isEmpty {
                            Text("Shared folder")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: $isolateAgents) {
                                Text("Git worktree per agent").tag(true)
                                Text("Shared primary checkout").tag(false)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: gitURL) { _, value in
            branchEdited = false
            gitBranch = ""
            repositoryBranches = []
            defaultRepositoryBranch = nil
            repositoryBranchError = nil
            // SwiftUI may call the TextField binding setter while installing
            // the control, which marks an untouched empty Name as edited.
            // An empty field still means "infer it"; only preserve a
            // non-empty name the user actually supplied.
            guard sourceKind == .clone,
                  Self.shouldInferProjectName(
                    currentName: name,
                    nameWasEdited: nameEdited
                  ),
                  let inferred = Self.projectName(fromRepositoryURL: value) else { return }
            name = inferred
            applyDerivedDestination()
        }
        .onChange(of: sourceKind) { _, kind in
            nameEdited = false
            folderEdited = false
            if kind == .empty {
                gitURL = ""
                gitBranch = ""
                name = ""
                focusedField = .name
            } else if kind == .clone {
                focusedField = .repositoryURL
            } else {
                gitURL = ""
                gitBranch = ""
                directory = ""
                focusedField = .directory
            }
            applyDerivedDestination()
        }
        .onChange(of: name) { _, _ in
            applyDerivedDestination()
        }
        .onChange(of: directory) { _, newValue in
            guard sourceKind == .existingFolder, !nameEdited else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            name = URL(fileURLWithPath: trimmed).lastPathComponent
        }
        .onChange(of: runsOnHostKey) { _, newHost in
            applyRunsOn(newHost)
            applyDerivedDestination()
        }
    }

    private var matchingRepositoryURLSuggestions: [String] {
        RepositoryURLAutocomplete.matches(
            repositoryURLSuggestions,
            query: gitURL,
            limit: 6
        )
    }

    private var repositoryDiscoveryID: String {
        (repositoryDirectories + ["|"] + repositorySearchRoots).joined(separator: "\n")
    }

    private var branchLookupID: String {
        sourceKind == .clone
            ? gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    private var matchingRepositoryBranches: [String] {
        RepositoryBranchLookup.matches(
            repositoryBranches,
            query: gitBranch,
            excluding: gitBranch,
            limit: 8
        )
    }

    private var repositoryBranchSuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matchingRepositoryBranches, id: \.self) { branch in
                Button {
                    selectRepositoryBranch(branch)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        Text(branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository branch suggestions")
    }

    private func selectRepositoryBranch(_ branch: String) {
        gitBranch = branch
        branchEdited = true
        focusedField = nil
    }

    private func loadRepositoryBranches() async {
        let repositoryURL = branchLookupID
        repositoryBranches = []
        defaultRepositoryBranch = nil
        repositoryBranchError = nil
        isLoadingRepositoryBranches = false

        guard sourceKind == .clone,
              PeerProjectBootstrap.repositoryURLProblem(repositoryURL) == nil else {
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isLoadingRepositoryBranches = true
            let result = try await RepositoryBranchLookup.load(from: repositoryURL)
            guard !Task.isCancelled, branchLookupID == repositoryURL else { return }
            repositoryBranches = result.branches
            defaultRepositoryBranch = result.defaultBranch
            if !branchEdited {
                gitBranch = result.defaultBranch ?? result.branches.first ?? ""
            }
        } catch is CancellationError {
            return
        } catch {
            guard branchLookupID == repositoryURL else { return }
            repositoryBranchError = "Couldn’t load branches. You can enter one manually."
        }
        isLoadingRepositoryBranches = false
    }

    private var repositoryURLMatchCount: Int {
        RepositoryURLAutocomplete.matchingCount(
            repositoryURLSuggestions,
            query: gitURL
        )
    }

    private var shouldShowNoRepositoryMatches: Bool {
        !gitURL.isEmpty
            && repositoryURLSuggestions.count > 0
            && repositoryURLMatchCount == 0
            && PeerProjectBootstrap.repositoryURLProblem(gitURL) != nil
    }

    private var repositoryURLSuggestionLoading: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Finding repositories…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var repositoryURLSuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(repositoryURLSuggestionHeader)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)

            ForEach(matchingRepositoryURLSuggestions, id: \.self) { suggestion in
                Button {
                    gitURL = suggestion
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        Text(suggestion)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .help(suggestion)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository URL suggestions")
    }

    private var repositoryURLSuggestionHeader: String {
        if gitURL.isEmpty {
            return "\(repositoryURLSuggestions.count) repositories · Type to search"
        }
        return "\(repositoryURLMatchCount) matching repositories"
    }

    static func projectName(fromRepositoryURL raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }
        let tail: String
        if let url = URL(string: trimmed), url.scheme != nil {
            guard let component = url.pathComponents.last,
                  component != "/" else { return nil }
            tail = component
        } else if let slash = trimmed.lastIndex(of: "/") {
            tail = String(trimmed[trimmed.index(after: slash)...])
        } else if let colon = trimmed.lastIndex(of: ":") {
            tail = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil
        }
        let decoded = tail.removingPercentEncoding ?? tail
        let name = decoded.hasSuffix(".git") ? String(decoded.dropLast(4)) : decoded
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func shouldInferProjectName(
        currentName: String,
        nameWasEdited: Bool
    ) -> Bool {
        !nameWasEdited
            || currentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyDerivedDestination() {
        guard sourceKind != .existingFolder, !folderEdited else { return }
        let projectName = effectiveName.isEmpty ? Self.placeholderProjectName : effectiveName
        let root: String
        if let hostKey = runsOnHostKey,
           let configured = PeerHostProfileStore.shared.profiles
            .first(where: { $0.stableKey == hostKey })?
            .projectRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            root = configured
        } else if runsOnHostKey == nil {
            root = ProjectLocationSettings.expandedLocalProjectsRoot()
        } else {
            root = ""
        }
        directory = root.isEmpty
            ? ""
            : (root as NSString).appendingPathComponent(projectName)
        syncInheritedAgentPlacements()
    }

    /// Stands in for a project name that has not been given yet, so the
    /// predicted folder is a real path rather than the bare root.
    static let placeholderProjectName = "new-project"

    /// Every machine that has been configured, connected or not.
    ///
    /// Filtering to the connected ones hid machines the person had already set
    /// up and meant to use — the list simply had fewer entries than the
    /// settings did, with nothing saying why. A peer that is merely idle is
    /// still the answer to "where does this project live"; connecting is
    /// something to do about it, not a reason to pretend it is not there.
    private var selectablePeers: [HostEntry] {
        hostStore.sortedHosts.filter { !($0.sshTarget ?? "").isEmpty }
    }

    private var defaultAgentHostKey: String? {
        switch agentPlacementMode {
        case .sameAsLeader, .perAgent:
            runsOnHostKey
        case .allOnOneMachine:
            allAgentsHostKey
        }
    }

    private var defaultAgentHostDirectory: String {
        projectDirectory(for: defaultAgentHostKey)
    }

    private func machineLabel(_ hostKey: String?) -> String {
        guard let hostKey else { return "This Mac" }
        return selectablePeers.first(where: { $0.id == hostKey })?.displayName ?? hostKey
    }

    private var agentPlacementCompactSummary: String {
        switch agentPlacementMode {
        case .sameAsLeader:
            return "agents follow leader"
        case .allOnOneMachine:
            return "all agents on \(machineLabel(allAgentsHostKey))"
        case .perAgent:
            let hosts = Set(agents.map(\.hostKey))
            if hosts.count == 1, let only = hosts.first {
                return "all agents on \(machineLabel(only))"
            }
            return "agents across \(hosts.count) machines"
        }
    }

    private var agentPlacementDetail: String {
        switch agentPlacementMode {
        case .sameAsLeader:
            return "Every agent follows the leader to \(machineLabel(runsOnHostKey))."
        case .allOnOneMachine:
            return "Every agent runs on \(machineLabel(allAgentsHostKey)); the leader stays on \(machineLabel(runsOnHostKey))."
        case .perAgent:
            return "Choose a machine in each agent row. Default follows the leader."
        }
    }

    static func resolvedAgentHostKey(
        mode: AgentPlacementMode,
        leaderHostKey: String?,
        allAgentsHostKey: String?,
        explicitHostKey: String?,
        inheritsDefault: Bool
    ) -> String? {
        switch mode {
        case .sameAsLeader:
            return leaderHostKey
        case .allOnOneMachine:
            return allAgentsHostKey
        case .perAgent:
            return inheritsDefault ? leaderHostKey : explicitHostKey
        }
    }

    private func projectDirectory(for hostKey: String?) -> String {
        guard let hostKey else { return "" }
        if hostKey == runsOnHostKey { return trimmedDirectory }
        let projectName = effectiveName.isEmpty ? Self.placeholderProjectName : effectiveName
        if let predicted = PeerHostProfileStore.shared.profiles
            .first(where: { $0.stableKey == hostKey })?
            .predictedProjectPath(forProjectNamed: projectName) {
            return predicted
        }
        if let remembered = RemoteProjectPaths.shared.path(
            host: hostKey,
            localRoot: trimmedDirectory
        ) {
            return remembered
        }
        return RemoteProjectPaths.shared.anyPath(host: hostKey) ?? ""
    }

    private func connectHostIfNeeded(_ hostKey: String?) {
        guard let hostKey,
              let host = selectablePeers.first(where: { $0.id == hostKey }),
              !host.isConnected else { return }
        hostStore.connectSavedHost(host)
    }

    private func applyAgentPlacementMode() {
        if agentPlacementMode != .perAgent {
            inheritedAgentIDs = Set(agents.map(\.id))
        }
        syncInheritedAgentPlacements()
    }

    private func syncInheritedAgentPlacements() {
        for index in agents.indices {
            let inheritsDefault = inheritedAgentIDs.contains(agents[index].id)
            if agentPlacementMode == .perAgent && !inheritsDefault { continue }
            let hostKey = Self.resolvedAgentHostKey(
                mode: agentPlacementMode,
                leaderHostKey: runsOnHostKey,
                allAgentsHostKey: allAgentsHostKey,
                explicitHostKey: agents[index].hostKey,
                inheritsDefault: inheritsDefault
            )
            agents[index].hostKey = hostKey
            agents[index].hostDirectory = projectDirectory(for: hostKey)
        }
    }

    private func parentOf(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private var folderPlaceholder: String {
        guard let runsOnHostKey,
              let profile = PeerHostProfileStore.shared.profiles
                .first(where: { $0.stableKey == runsOnHostKey }),
              let root = profile.projectRootPath, !root.isEmpty
        else { return runsOnHostKey == nil ? "~/work/project" : "/path/on/that/machine" }
        return (root as NSString).appendingPathComponent("project")
    }

    /// A member added after the machine was chosen belongs to the same
    /// machine.
    ///
    /// Adding one produced a row set to "Here" with no folder field at all —
    /// on a form whose every other answer said the project lives on a peer.
    /// The member was then created locally while its teammates worked on the
    /// far machine, which is a team that cannot see each other's files.
    ///
    /// Only rows that have just appeared, so someone who deliberately moves a
    /// member back to this Mac is not overruled on the next redraw. Nothing is
    /// counted as new when the list shrinks.
    private func adoptProjectMachineForNewRows() {
        let currentIDs = Set(agents.map(\.id))
        let newIDs = currentIDs.subtracting(knownAgentIDs)
        inheritedAgentIDs.formIntersection(currentIDs)
        for i in agents.indices where newIDs.contains(agents[i].id) {
            inheritedAgentIDs.insert(agents[i].id)
            let hostKey = defaultAgentHostKey
            agents[i].hostKey = hostKey
            agents[i].hostDirectory = projectDirectory(for: hostKey)
        }
        knownAgentIDs = currentIDs
    }

    /// Move the whole form to the chosen machine.
    ///
    /// The folder starts from that machine's own convention rather than being
    /// cleared: a path someone can correct beats an empty field they have to
    /// go and look up. The agents follow, because a project running over there
    /// with its members here is not what anyone picked this for — and each row
    /// can still be moved back individually.
    private func applyRunsOn(_ hostKey: String?) {
        folderEdited = false
        guard let hostKey else {
            directory = ""
            syncInheritedAgentPlacements()
            return
        }
        // Picking a machine is as good as saying "use that one", so the
        // connection is started here rather than left as a step to discover
        // at Create time when the agents fail to attach.
        if let host = selectablePeers.first(where: { $0.id == hostKey }), !host.isConnected {
            hostStore.connectSavedHost(host)
        }
        // The folder is a machine's project root plus this project's name, and
        // at this moment there is no name yet — nobody types one before saying
        // where the project goes. So a placeholder stands in and the folder
        // follows the name as it is typed, below.
        let leaf = effectiveName.isEmpty ? Self.placeholderProjectName : effectiveName
        let predicted = PeerHostProfileStore.shared.profiles
            .first { $0.stableKey == hostKey }?
            .predictedProjectPath(forProjectNamed: leaf)
        directory = predicted ?? RemoteProjectPaths.shared.anyPath(host: hostKey) ?? ""
        syncInheritedAgentPlacements()
    }

    private var footer: some View {
        HStack {
            if showsCreationProgress {
                Text(creationError == nil
                    ? "Keep this window open while the project starts."
                    : "Review the failed step, then retry or change the settings.")
                    .font(.caption)
                    .foregroundStyle(creationError == nil ? Color.secondary : Color.red)
            } else {
                Text(creationError ?? creationSummary)
                    .font(.caption)
                    .foregroundStyle(creationError == nil ? Color.secondary : Color.red)
                    .lineLimit(creationError == nil ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: creationError != nil)
                    .layoutPriority(1)
                    .help(creationError ?? creationSummary)
            }
            Spacer()
            if showsCreationProgress {
                if creationError != nil {
                    Button("Back to settings") {
                        showsCreationProgress = false
                        creationError = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Retry project") {
                        startCreation()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Starting…") {}
                        .disabled(true)
                }
            } else {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(createActionLabel) {
                    startCreation()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || !placementHostsAreReady)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var effectiveIsolation: Bool {
        isolateAgents && !(sourceKind == .existingFolder && gitURL.isEmpty)
    }

    private func startCreation() {
        if let problem = PeerProjectBootstrap.repositoryURLProblem(gitURL) {
            creationError = problem
            return
        }
        let localDirectory = runsOnHostKey == nil
            ? trimmedDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        let source = ProjectSource(
            hostKey: runsOnHostKey,
            projectPath: trimmedDirectory,
            gitURL: gitURL.trimmingCharacters(in: .whitespacesAndNewlines),
            gitBranch: gitBranch.trimmingCharacters(in: .whitespacesAndNewlines),
            isolateAgents: effectiveIsolation,
            kind: sourceKind
        )
        let leader = ProjectLeader(
            mode: leaderCli,
            model: leaderModel,
            endpoint: runsOnHostKey.map { .peer(hostKey: $0) } ?? .local
        )

        showsCreationProgress = true
        creationStartedAt = Date()
        creationError = nil
        bootSteps = plannedLaunchSteps(source: source, leader: leader)

        Task { @MainActor in
            do {
                try await onCreate(
                    effectiveName,
                    localDirectory,
                    agents,
                    source,
                    leader,
                    handleCreationEvent
                )
                onClose()
            } catch {
                let message = error.localizedDescription
                creationError = message
                failRunningBootStep(message: message)
            }
        }
    }

    private func plannedLaunchSteps(
        source: ProjectSource,
        leader: ProjectLeader
    ) -> [ProjectBootStep] {
        let leaderHost = machineLabel(leader.endpoint.hostKey)
        let leaderPath = source.projectPath
        var steps = [
            ProjectBootStep(
                id: "leader",
                order: 1_000,
                title: "Start leader",
                detail: "\(leader.mode.capitalized) · \(AgentRolePreset.modelDisplayLabel(leader.model, for: leader.mode)) · \(leaderHost) · \(leaderPath)",
                command: ProjectCreationFlow.launchCommandPreview(
                    cli: leader.mode,
                    model: leader.model,
                    directory: leaderPath
                ),
                status: .pending
            )
        ]
        steps += agents.enumerated().map { index, agent in
            let hostKey = Self.resolvedAgentHostKey(
                mode: agentPlacementMode,
                leaderHostKey: runsOnHostKey,
                allAgentsHostKey: allAgentsHostKey,
                explicitHostKey: agent.hostKey,
                inheritsDefault: inheritedAgentIDs.contains(agent.id)
            )
            let path = hostKey == nil
                ? (effectiveIsolation ? "Git worktree from \(trimmedDirectory)" : trimmedDirectory)
                : (agent.hostDirectory.isEmpty ? defaultAgentHostDirectory : agent.hostDirectory)
            let cli = agent.preset.cli.isEmpty ? "claude" : agent.preset.cli
            return ProjectBootStep(
                id: "agent:\(agent.id.uuidString)",
                order: 2_000 + index,
                title: "Start \(agent.preset.displayName)",
                detail: "\(cli.capitalized) · \(AgentRolePreset.modelDisplayLabel(agent.preset.model, for: cli)) · \(machineLabel(hostKey)) · \(path)",
                command: ProjectCreationFlow.launchCommandPreview(
                    cli: cli,
                    model: agent.preset.model,
                    directory: path
                ),
                status: .pending
            )
        }
        return steps
    }

    private func handleCreationEvent(_ event: ProjectCreationEvent) {
        bootSteps = Self.applying(event, to: bootSteps)
    }

    static func applying(
        _ event: ProjectCreationEvent,
        to steps: [ProjectBootStep]
    ) -> [ProjectBootStep] {
        var result = steps
        switch event {
        case .planned(let step):
            upsert(step, in: &result)
        case .started(var step):
            step.status = .running
            upsert(step, in: &result)
        case .completed(let id, let detail):
            if let index = result.firstIndex(where: { $0.id == id }) {
                result[index].status = .completed
                if let detail { result[index].detail = detail }
            }
        case .failed(let id, let message):
            if let index = result.firstIndex(where: { $0.id == id }) {
                result[index].status = .failed(message)
            }
        }
        return result.sorted(by: { $0.order < $1.order })
    }

    private static func upsert(_ step: ProjectBootStep, in steps: inout [ProjectBootStep]) {
        if let index = steps.firstIndex(where: { $0.id == step.id }) {
            steps[index] = step
        } else {
            steps.append(step)
        }
    }

    private func failRunningBootStep(message: String) {
        if let index = bootSteps.firstIndex(where: { $0.status == .running }) {
            bootSteps[index].status = .failed(message)
        }
    }

    private var canCreate: Bool {
        guard !trimmedDirectory.isEmpty, !effectiveName.isEmpty else { return false }
        if sourceKind == .clone {
            return !gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var createActionLabel: String {
        switch sourceKind {
        case .clone: "Clone Repository"
        case .existingFolder: "Open Project"
        case .empty: "Create Empty Project"
        }
    }

    private var creationSummary: String {
        var action: String
        switch sourceKind {
        case .clone:
            action = "Clone \(gitURL.isEmpty ? "repository" : gitURL)"
            if !gitBranch.isEmpty {
                action += " · \(gitBranch)"
            }
        case .existingFolder: action = "Use existing folder"
        case .empty: action = "Create empty Git project"
        }
        let machine = runsOnHostKey.flatMap { hostKey in
            selectablePeers.first(where: { $0.id == hostKey })?.displayName
        } ?? "This Mac"
        let checkout = effectiveIsolation
            ? "\(agents.count) agent worktree\(agents.count == 1 ? "" : "s")"
            : "shared checkout"
        return "\(action) → \(trimmedDirectory) · Leader: \(machine) · \(agentPlacementCompactSummary) · \(checkout)"
    }

    private var placementHostsAreReady: Bool {
        let remoteKeys = Set(
            [runsOnHostKey].compactMap { $0 }
                + agents.compactMap(\.hostKey)
        )
        return remoteKeys.allSatisfy { hostKey in
            selectablePeers.first(where: { $0.id == hostKey })?.isConnected == true
        }
    }

    private func applyInitialTeamPreset() {
        guard agents.isEmpty else { return }
        if let pinnedId = teamTemplateManager.pinnedId,
           pinnedId.category == .smart,
           let template = teamTemplateManager.template(for: pinnedId) {
            applyTemplate(template)
        }
        if agents.isEmpty { applyDefaultTeam() }
    }

    private func applyDefaultTeam() {
        guard var preset = presetManager.presets.first(where: { $0.name == "executor" })
            ?? presetManager.presets.first else { return }
        preset.cli = "claude"
        preset.model = AgentRolePreset.defaultModel(for: "claude")
        leaderCli = "claude"
        leaderModel = Self.defaultLeaderModel(for: "claude")
        selectedTeamPresetId = nil
        installPresetAgents([
            TeamAgentRow(preset: preset, customInstructions: "")
        ])
        appliedTeamSignature = currentTeamSignature
    }

    private func applyTemplate(_ template: TeamTemplate) {
        let payload = template.origin == .builtIn
            ? (teamTemplateManager.effectivePayload(for: template.id) ?? template.payload)
            : template.payload
        guard case .smart(let preset) = payload else { return }

        leaderCli = preset.leaderMode
        if leaderCli != "repl" {
            let candidate = preset.leaderModel ?? Self.defaultLeaderModel(for: leaderCli)
            leaderModel = AgentRolePreset.models(for: leaderCli).contains(candidate)
                ? candidate
                : Self.defaultLeaderModel(for: leaderCli)
        }

        let resolvedAgents = preset.usesExactResolution
            ? preset.resolveExactly()
            : preset.resolve(with: providerDetector)
        let rows = resolvedAgents.compactMap { resolved -> TeamAgentRow? in
            guard var role = presetManager.presets.first(where: { $0.name == resolved.role })
                    ?? presetManager.presets.first(where: { $0.name == "executor" })
                    ?? presetManager.presets.first else { return nil }
            role.cli = resolved.cli
            role.model = resolved.model
            let badge: TeamAgentRow.ProviderBadge
            switch resolved.status {
            case .normal:
                badge = .none
            case .best:
                badge = .best(reason: resolved.reason)
            case .fallback(let wanted):
                badge = .fallback(wanted: wanted)
            }
            return TeamAgentRow(
                preset: role,
                customInstructions: resolved.customInstructions,
                providerBadge: badge
            )
        }
        guard !rows.isEmpty else { return }
        selectedTeamPresetId = template.id
        try? teamTemplateManager.setLastSelected(id: template.id)
        installPresetAgents(rows)
        appliedTeamSignature = currentTeamSignature
    }

    private func installPresetAgents(_ rows: [TeamAgentRow]) {
        agents = rows.map { row in
            var resolved = row
            resolved.hostKey = defaultAgentHostKey
            resolved.hostDirectory = defaultAgentHostDirectory
            return resolved
        }
        let ids = Set(agents.map(\.id))
        inheritedAgentIDs = ids
        knownAgentIDs = ids
    }

    private func saveCurrentTeamPreset() {
        let name = savePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = teamTemplateManager.createSmartPreset(
            name: name,
            leaderMode: leaderCli,
            leaderModel: leaderCli == "repl" ? nil : leaderModel,
            agents: currentProviderPreferences
        )
        selectedTeamPresetId = id
        appliedTeamSignature = currentTeamSignature
        showingSavePreset = false
        showPresetSavedConfirmation("Saved")
    }

    private var currentProviderPreferences: [ProviderPreference] {
        agents.map { row in
            ProviderPreference(
                role: row.preset.name,
                primaryCli: row.preset.cli,
                primaryModel: row.preset.model,
                fallbackCli: row.preset.cli,
                fallbackModel: row.preset.model,
                reason: "",
                customInstructions: row.customInstructions.isEmpty ? nil : row.customInstructions
            )
        }
    }

    private func presentSavePresetSheet() {
        savePresetName = suggestedPresetName
        showingSavePreset = true
    }

    private func saveChangesToSelectedPreset() {
        guard let selectedTeamPresetId,
              var template = teamTemplateManager.template(for: selectedTeamPresetId),
              template.origin == .custom,
              case .smart(var preset) = template.payload else { return }
        preset.leaderMode = leaderCli
        preset.leaderModel = leaderCli == "repl" ? nil : leaderModel
        preset.agents = currentProviderPreferences
        preset.description = "\(agents.count) agent\(agents.count == 1 ? "" : "s")"
        template.payload = .smart(preset)
        do {
            try teamTemplateManager.updateCustom(template)
            appliedTeamSignature = currentTeamSignature
            showPresetSavedConfirmation("Saved")
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func revertCurrentTeamChanges() {
        if let selectedTeamPresetId,
           let template = teamTemplateManager.template(for: selectedTeamPresetId) {
            applyTemplate(template)
        } else {
            applyDefaultTeam()
        }
    }

    private func showPresetSavedConfirmation(_ message: String) {
        presetSaveConfirmation = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !isTeamCustomized {
                presetSaveConfirmation = nil
            }
        }
    }

    static func defaultLeaderModel(for cli: String) -> String {
        cli == "claude" ? "opus" : AgentRolePreset.defaultModel(for: cli)
    }

    private func toggleSelectedPresetPin() {
        guard let id = selectedTeamPresetId else { return }
        if teamTemplateManager.pinnedId == id {
            teamTemplateManager.unpin()
        } else {
            do {
                try teamTemplateManager.pin(id: id)
            } catch {
                presetError = error.localizedDescription
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for this project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url.path
        if sourceKind == .existingFolder {
            name = url.lastPathComponent
            Task {
                if let origin = await Self.localGitOrigin(at: url.path) {
                    gitURL = origin
                }
            }
        }
    }

    private static func localGitOrigin(at path: String) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "remote", "get-url", "origin"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }.value
    }
}

enum RepositoryURLAutocomplete {
    private static let skippedDirectoryNames: Set<String> = [
        ".build", ".cache", ".swiftpm", "DerivedData", "Library",
        "node_modules", "Pods", "vendor"
    ]

    static func singleLine(_ raw: String) -> String {
        guard raw.contains(where: \.isWhitespace) else { return raw }
        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.first(where: {
            PeerProjectBootstrap.repositoryURLProblem($0) == nil
        }) ?? parts.first ?? ""
    }

    static func matches(_ suggestions: [String], query rawQuery: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(suggestions.lazy.filter { suggestion in
            guard suggestion.caseInsensitiveCompare(query) != .orderedSame else { return false }
            return query.isEmpty || suggestion.localizedCaseInsensitiveContains(query)
        }.prefix(limit))
    }

    static func matchingCount(_ suggestions: [String], query rawQuery: String) -> Int {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return suggestions.reduce(into: 0) { count, suggestion in
            if query.isEmpty || suggestion.localizedCaseInsensitiveContains(query) {
                count += 1
            }
        }
    }

    static func discoverRepositories(
        under roots: [String],
        maximumDepth: Int = 4,
        maximumRepositories: Int = 250
    ) -> [String] {
        guard maximumDepth >= 0, maximumRepositories > 0 else { return [] }
        let fileManager = FileManager.default
        var queue = roots.map {
            (TeamCreationRecentDirs.normalize($0), 0)
        }
        var nextIndex = 0
        var visited = Set<String>()
        var repositories: [String] = []

        while nextIndex < queue.count, repositories.count < maximumRepositories {
            let (directory, depth) = queue[nextIndex]
            nextIndex += 1
            guard !directory.isEmpty, visited.insert(directory).inserted else { continue }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let gitMetadata = (directory as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitMetadata) {
                repositories.append(directory)
                continue
            }
            guard depth < maximumDepth else { continue }

            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: URL(fileURLWithPath: directory),
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                )
            } catch {
                continue
            }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                guard !name.hasPrefix("."), !skippedDirectoryNames.contains(name) else { continue }
                guard let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                queue.append((child.standardizedFileURL.path, depth + 1))
            }
        }
        return repositories
    }

    static func loadOriginURLs(
        from directories: [String],
        searching roots: [String] = []
    ) -> [String] {
        var seenDirectories = Set<String>()
        var seenURLs = Set<String>()
        var result: [String] = []

        let discoveredDirectories = discoverRepositories(under: roots)
        for rawDirectory in directories + discoveredDirectories {
            let directory = TeamCreationRecentDirs.normalize(rawDirectory)
            guard !directory.isEmpty, seenDirectories.insert(directory).inserted else { continue }

            if let repositoryURL = originURLFromConfig(in: directory),
               seenURLs.insert(repositoryURL).inserted {
                result.append(repositoryURL)
            }
        }
        return result
    }

    static func originURLFromConfig(in repository: String) -> String? {
        let fileManager = FileManager.default
        let gitMetadata = URL(fileURLWithPath: repository).appendingPathComponent(".git")
        let configURL: URL

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitMetadata.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            configURL = gitMetadata.appendingPathComponent("config")
        } else {
            guard let pointer = try? String(contentsOf: gitMetadata, encoding: .utf8),
                  let firstLine = pointer.split(whereSeparator: \.isNewline).first,
                  firstLine.lowercased().hasPrefix("gitdir:") else { return nil }
            let rawPath = firstLine.dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespaces)
            let gitDirectory = URL(
                fileURLWithPath: rawPath,
                relativeTo: gitMetadata.deletingLastPathComponent()
            ).standardizedFileURL
            let commonDirectory: URL
            let commonPointer = gitDirectory.appendingPathComponent("commondir")
            if let rawCommon = try? String(contentsOf: commonPointer, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !rawCommon.isEmpty {
                commonDirectory = URL(
                    fileURLWithPath: rawCommon,
                    relativeTo: gitDirectory
                ).standardizedFileURL
            } else {
                commonDirectory = gitDirectory
            }
            configURL = commonDirectory.appendingPathComponent("config")
        }

        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }
        var isOriginSection = false
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let normalized = line.lowercased()
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "'", with: "\"")
                isOriginSection = normalized == "[remote\"origin\"]"
                continue
            }
            guard isOriginSection, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "url" else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            let sanitized = sanitizedURL(value)
            return sanitized.isEmpty ? nil : sanitized
        }
        return nil
    }

    private static func sanitizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil else { return trimmed }
        components.user = nil
        components.password = nil
        return components.string ?? trimmed
    }
}

enum RepositoryBranchLookup {
    struct Result: Equatable {
        let defaultBranch: String?
        let branches: [String]
    }

    enum LookupError: Error {
        case failed
        case timedOut
    }

    static func singleLine(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    static func matches(
        _ branches: [String],
        query rawQuery: String,
        excluding selected: String? = nil,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(branches.lazy.filter { branch in
            if let selected,
               branch.caseInsensitiveCompare(selected) == .orderedSame {
                return false
            }
            return query.isEmpty || branch.localizedCaseInsensitiveContains(query)
        }.prefix(limit))
    }

    static func parse(_ output: String) -> Result {
        var defaultBranch: String?
        var branches = Set<String>()

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("ref: refs/heads/"),
               line.hasSuffix("\tHEAD") {
                defaultBranch = String(
                    line
                        .dropFirst("ref: refs/heads/".count)
                        .dropLast("\tHEAD".count)
                )
                continue
            }
            guard let range = line.range(of: "\trefs/heads/") else { continue }
            let branch = String(line[range.upperBound...])
            if !branch.isEmpty {
                branches.insert(branch)
            }
        }

        let sorted = branches.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let ordered: [String]
        if let defaultBranch,
           let index = sorted.firstIndex(of: defaultBranch) {
            var copy = sorted
            copy.remove(at: index)
            ordered = [defaultBranch] + copy
        } else {
            ordered = sorted
        }
        return Result(defaultBranch: defaultBranch, branches: ordered)
    }

    static func load(
        from repositoryURL: String,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> Result {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = [
                "ls-remote", "--symref", repositoryURL,
                "HEAD", "refs/heads/*"
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_SSH_COMMAND"] =
                "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
            process.environment = environment

            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let outputRead = Task.detached(priority: .utility) {
                output.fileHandleForReading.readDataToEndOfFile()
            }

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                _ = await outputRead.value
                throw LookupError.timedOut
            }
            guard process.terminationStatus == 0 else {
                _ = await outputRead.value
                throw LookupError.failed
            }
            let data = await outputRead.value
            let result = parse(String(data: data, encoding: .utf8) ?? "")
            guard !result.branches.isEmpty else {
                throw LookupError.failed
            }
            return result
        }.value
    }
}

private struct TeamPresetManagerSheet: View {
    @ObservedObject var manager: TeamTemplateManager
    @Binding var selectedId: TemplateID?
    let onDeleteSelected: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var smartTemplates: [TeamTemplate] {
        manager.templates.filter {
            if case .smart = $0.payload { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Team Presets")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            List {
                ForEach(smartTemplates) { template in
                    TeamPresetManagementRow(
                        template: template,
                        isPinned: manager.pinnedId == template.id,
                        onRename: { name in
                            try? manager.renameCustom(id: template.id, name: name)
                        },
                        onTogglePin: {
                            if manager.pinnedId == template.id {
                                manager.unpin()
                            } else {
                                try? manager.pin(id: template.id)
                            }
                        },
                        onDelete: template.origin == .custom ? {
                            if selectedId == template.id {
                                selectedId = nil
                                onDeleteSelected()
                            }
                            try? manager.deleteCustom(id: template.id)
                        } : nil
                    )
                }
            }
            .frame(minHeight: 280)
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }
}

private struct TeamPresetManagementRow: View {
    let template: TeamTemplate
    let isPinned: Bool
    let onRename: (String) -> Void
    let onTogglePin: () -> Void
    let onDelete: (() -> Void)?
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(
        template: TeamTemplate,
        isPinned: Bool,
        onRename: @escaping (String) -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: (() -> Void)?
    ) {
        self.template = template
        self.isPinned = isPinned
        self.onRename = onRename
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        _name = State(initialValue: template.name)
    }

    var body: some View {
        HStack(spacing: 8) {
            if template.origin == .custom {
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: isNameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(template.name)
                Text("Built-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .onDisappear { commitRename() }
    }

    private func commitRename() {
        guard template.origin == .custom else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = template.name
            return
        }
        name = trimmed
        if trimmed != template.name {
            onRename(trimmed)
        }
    }
}

/// Making the project the sheet describes.
///
/// This lived inside the sidebar's Projects header, which owned the sheet.
/// The titlebar's + opens the same sheet, and it is on screen exactly when the
/// sidebar is not — so the sheet moved to the app and the work it does had to
/// come with it, as something neither presenter owns.
enum ProjectCreationFlow {
    /// Every machine selected in the form, prepared before launching anyone.
    struct PreparedCheckouts {
        var rows: [TeamAgentRow]
        /// Primary checkout on this Mac, when either the source, leader or a
        /// member runs here. The local team engine builds its own worktrees
        /// from this root.
        var localProjectPath: String?
        /// Primary checkout on the leader's machine. nil tells a local leader
        /// to use `localProjectPath`; a remote leader always receives a path.
        var leaderProjectPath: String?
    }

    enum CreationError: LocalizedError {
        case teamCreationFailed
        case remoteHostUnavailable
        case remotePathMissing
        case remoteSetupFailed(host: String, detail: String)
        case invalidRepositoryURL(String)

        var errorDescription: String? {
            switch self {
            case .teamCreationFailed:
                "Could not create the project team."
            case .remoteHostUnavailable:
                "The selected remote machine is unavailable."
            case .remotePathMissing:
                "Enter a folder on the remote machine."
            case .remoteSetupFailed(let host, let detail):
                "Could not prepare \(host): \(detail)"
            case .invalidRepositoryURL(let problem):
                problem
            }
        }
    }

    /// The whole of what "Create" means: the checkouts, the team, the board.
    @MainActor
    static func create(
        name: String,
        directory: String,
        rows: [TeamAgentRow],
        source: ProjectSource,
        leader: ProjectLeader,
        progress: @escaping @MainActor (ProjectCreationEvent) -> Void = { _ in },
        tabManager: TabManager
    ) async throws {
        // A name already in use means the project is open, not that something
        // failed. Creating one silently returned nil and the sheet just
        // closed, which reads as the button not working — so go to the one
        // that is there.
        if let existing = TeamOrchestrator.shared.teams[name],
           let workspace = tabManager.tabs.first(where: { $0.id == existing.workspaceId }) {
            tabManager.selectWorkspace(workspace)
            return
        }
        // The checkouts have to exist before anyone is sent to work in them:
        // an agent whose directory is not there starts in a shell that failed
        // to `cd` and looks attached while being nothing of the kind.
        let prepared = try await prepareCheckouts(
            name: name,
            rows: rows,
            source: source,
            leaderHostKey: leader.endpoint.hostKey,
            progress: progress
        )
        let leaderPath = prepared.leaderProjectPath
            ?? prepared.localProjectPath
            ?? directory
        progress(.started(ProjectBootStep(
            id: "leader",
            order: 1_000,
            title: "Start leader",
            detail: "\(leader.mode.capitalized) · \(hostDisplayName(leader.endpoint.hostKey)) · \(leaderPath)",
            command: launchCommandPreview(
                cli: leader.mode,
                model: leader.model,
                directory: leaderPath
            ),
            status: .running
        )))
        for (index, row) in prepared.rows.enumerated() {
            let cli = row.preset.cli.isEmpty ? "claude" : row.preset.cli
            let path = row.hostDirectory.isEmpty
                ? (source.isolateAgents ? "Git worktree from \(prepared.localProjectPath ?? directory)" : (prepared.localProjectPath ?? directory))
                : row.hostDirectory
            progress(.started(ProjectBootStep(
                id: "agent:\(row.id.uuidString)",
                order: 2_000 + index,
                title: "Start \(row.preset.displayName)",
                detail: "\(cli.capitalized) · \(hostDisplayName(row.hostKey)) · \(path)",
                command: launchCommandPreview(
                    cli: cli,
                    model: row.preset.model,
                    directory: path
                ),
                status: .running
            )))
        }
        await Task.yield()
        guard TeamOrchestrator.shared.createTeam(
            named: name,
            rows: prepared.rows,
            workingDirectory: prepared.localProjectPath ?? directory,
            leaderMode: leader.mode,
            leaderModel: leader.model,
            leaderEndpoint: leader.endpoint,
            leaderWorkingDirectory: prepared.leaderProjectPath,
            worktreeMode: source.isolateAgents
                && prepared.rows.contains(where: { $0.hostKey == nil })
                ? "isolated"
                : "off",
            projectSource: source,
            tabManager: tabManager
        ) != nil else {
            progress(.failed(id: "leader", message: "Could not create the project team."))
            throw CreationError.teamCreationFailed
        }
        progress(.completed(
            id: "leader",
            detail: "\(leader.mode.capitalized) launched on \(hostDisplayName(leader.endpoint.hostKey)) · \(leaderPath)"
        ))
        for row in prepared.rows {
            progress(.completed(
                id: "agent:\(row.id.uuidString)",
                detail: "\(row.preset.displayName) launch requested on \(hostDisplayName(row.hostKey))"
            ))
        }
        // A project with agents in it is what the board is for, so making one
        // puts it up.
        ReviewBoardSettings.setVisible(true)
    }

    /// Prepare every machine selected in the form before launching anyone.
    ///
    /// Remote members receive the concrete worktree path made for them.
    /// Local members stay host=nil and let the existing local team engine
    /// create its worktrees from `localProjectPath`, avoiding a second,
    /// competing local worktree implementation.
    @MainActor
    static func prepareCheckouts(
        name: String,
        rows: [TeamAgentRow],
        source: ProjectSource,
        leaderHostKey: String?,
        progress: @escaping @MainActor (ProjectCreationEvent) -> Void = { _ in }
    ) async throws -> PreparedCheckouts {
        let placements = try PeerProjectBootstrap.placements(
            source: source,
            rows: rows,
            leaderHostKey: leaderHostKey,
            localProjectsRoot: ProjectLocationSettings.expandedLocalProjectsRoot()
        ) { hostKey in
            PeerHostProfileStore.shared.profiles
                .first(where: { $0.stableKey == hostKey })?
                .predictedProjectPath(
                    forProjectNamed: URL(fileURLWithPath: source.projectPath).lastPathComponent
                )
                ?? RemoteProjectPaths.shared.path(
                    host: hostKey, localRoot: source.projectPath
                )
        }

        var prepared = rows
        var localProjectPath: String?
        var leaderProjectPath: String?
        let gitURL = source.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defense for paths that did not come through the form's own check.
        if let problem = PeerProjectBootstrap.repositoryURLProblem(gitURL) {
            throw CreationError.invalidRepositoryURL(problem)
        }
        // One name for every copy. Each placement's directory is the host's own
        // convention — deriving the id from it would give the same project a
        // different mem-mesh identity on each machine.
        let memMeshProjectID = PeerProjectBootstrap.memMeshProjectID(for: name)
        // One tag for the whole transaction: retrying a failed placement
        // reuses the same paths (idempotent), while a later re-creation of
        // the same project never adopts this run's leftovers.
        let instanceTag = PeerProjectBootstrap.makeInstanceTag()

        for (placementIndex, placement) in placements.enumerated() {
            let placedRows = placement.agentIndices.map { rows[$0] }
            let plan = PeerProjectBootstrap.plan(
                projectRoot: (placement.projectPath as NSString).deletingLastPathComponent,
                projectName: (placement.projectPath as NSString).lastPathComponent,
                agents: placedRows.map(\.preset.name),
                isolateAgents: source.isolateAgents,
                instanceTag: instanceTag
            )
            let kind: ProjectSourceKind = placement.isSource
                ? source.kind
                : (gitURL.isEmpty ? source.kind : .clone)
            let stepID = checkoutStepID(
                hostKey: placement.hostKey,
                path: plan.primaryPath
            )
            let checkoutStep = ProjectBootStep(
                id: stepID,
                order: placementIndex,
                title: checkoutTitle(kind: kind),
                detail: "\(hostDisplayName(placement.hostKey)) · \(plan.primaryPath)",
                command: checkoutCommandPreview(
                    plan: plan,
                    gitURL: gitURL.isEmpty ? nil : gitURL,
                    gitBranch: source.gitBranch,
                    sourceKind: kind
                ),
                status: .running
            )
            progress(.started(checkoutStep))

            if let hostKey = placement.hostKey {
                guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
                      let sshTarget = host.sshTarget, !sshTarget.isEmpty
                else {
                    throw CreationError.remoteHostUnavailable
                }
                do {
                    try await PeerProjectBootstrap.run(
                        sshTarget: sshTarget,
                        port: host.sshPort,
                        identityFile: host.identityFile,
                        plan: plan,
                        gitURL: gitURL.isEmpty ? nil : gitURL,
                        gitBranch: source.gitBranch,
                        sourceKind: kind,
                        memMeshProjectID: memMeshProjectID,
                        environment: PeerHostEnvironment.stored(forHostKey: hostKey)
                    )
                } catch {
                    let detail = PeerProjectBootstrap.remoteFailureDescription(
                        error,
                        gitURL: gitURL.isEmpty ? nil : gitURL
                    )
                    RemoteWorkLog.info(
                        "Could not prepare \(name) on \(host.displayName): \(detail)"
                    )
                    progress(.failed(id: stepID, message: detail))
                    throw CreationError.remoteSetupFailed(
                        host: host.displayName,
                        detail: detail
                    )
                }
                for (offset, rowIndex) in placement.agentIndices.enumerated()
                    where offset < plan.agentCheckouts.count {
                    prepared[rowIndex].hostKey = hostKey
                    prepared[rowIndex].hostDirectory = plan.agentCheckouts[offset].path
                }
                RemoteProjectPaths.shared.remember(
                    host: hostKey,
                    localRoot: source.projectPath,
                    path: plan.primaryPath
                )
            } else {
                // Local team creation owns local member worktrees. This step
                // prepares only their shared primary checkout.
                let primaryOnly = PeerProjectBootstrap.Plan(
                    primaryPath: plan.primaryPath,
                    agentCheckouts: []
                )
                do {
                    try await PeerProjectBootstrap.runLocal(
                        plan: primaryOnly,
                        gitURL: gitURL.isEmpty ? nil : gitURL,
                        gitBranch: source.gitBranch,
                        sourceKind: kind,
                        memMeshProjectID: memMeshProjectID
                    )
                } catch {
                    progress(.failed(id: stepID, message: error.localizedDescription))
                    throw error
                }
                localProjectPath = plan.primaryPath
            }

            progress(.completed(
                id: stepID,
                detail: "\(hostDisplayName(placement.hostKey)) · \(plan.primaryPath)"
            ))

            if placement.includesLeader {
                leaderProjectPath = placement.hostKey == nil ? nil : plan.primaryPath
            }
        }

        return PreparedCheckouts(
            rows: prepared,
            localProjectPath: localProjectPath,
            leaderProjectPath: leaderProjectPath
        )
    }

    static func launchCommandPreview(
        cli: String,
        model: String,
        directory: String
    ) -> String {
        let cd = directory.hasPrefix("Git worktree")
            ? "cd <agent-worktree>"
            : "cd \(shellDisplayQuote(directory))"
        let executable = cli == "repl" ? "term-mesh leader" : cli
        let modelArgument = model.isEmpty || cli == "repl"
            ? ""
            : " --model \(shellDisplayQuote(model))"
        return "\(cd) && \(executable)\(modelArgument)"
    }

    private static func checkoutStepID(hostKey: String?, path: String) -> String {
        "checkout:\(hostKey ?? "local"):\(path)"
    }

    private static func checkoutTitle(kind: ProjectSourceKind) -> String {
        switch kind {
        case .clone: "Clone repository"
        case .existingFolder: "Verify project checkout"
        case .empty: "Create Git project"
        }
    }

    private static func checkoutCommandPreview(
        plan: PeerProjectBootstrap.Plan,
        gitURL: String?,
        gitBranch: String?,
        sourceKind: ProjectSourceKind
    ) -> String {
        let primary = shellDisplayQuote(plan.primaryPath)
        let base: String
        if let gitURL, !gitURL.isEmpty {
            let branch = gitBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let branchArgument = branch.isEmpty
                ? ""
                : " --branch \(shellDisplayQuote(branch))"
            base = "git clone\(branchArgument) \(shellDisplayQuote(sanitizedRepositoryURL(gitURL))) \(primary)"
        } else {
            switch sourceKind {
            case .clone:
                base = "git clone <repository> \(primary)"
            case .existingFolder:
                base = "test -d \(primary)"
            case .empty:
                base = "mkdir -p \(primary) && git -C \(primary) init"
            }
        }
        guard plan.agentCheckouts.contains(where: { $0.path != plan.primaryPath }) else {
            return base
        }
        return "\(base) && git -C \(primary) worktree add …"
    }

    static func sanitizedRepositoryURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              components.scheme != nil else { return raw }
        components.user = nil
        components.password = nil
        return components.string ?? raw
    }

    private static func shellDisplayQuote(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "'" }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    private static func hostDisplayName(_ hostKey: String?) -> String {
        guard let hostKey else { return "This Mac" }
        return RemoteHostStore.shared.sortedHosts
            .first(where: { $0.id == hostKey })?
            .displayName ?? hostKey
    }
}
