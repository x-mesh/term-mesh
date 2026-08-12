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
    /// Undo a creation that came up incomplete: the team, its workspace, and
    /// the checkouts it made on every peer.
    ///
    /// The default is deliberately a no-op rather than a required argument —
    /// the previews and tests that build this sheet have nothing to discard.
    var onDiscard: (_ name: String) async -> Void = { _ in }
    /// Local repositories the app already knows about. Their `origin` remotes
    /// become lightweight autocomplete suggestions; no home-directory scan is
    /// needed just to open this sheet.
    let repositoryDirectories: [String]
    /// Roots that may contain projects not currently open in term-mesh.
    /// Discovery is shallow, bounded and runs off-main.
    let repositorySearchRoots: [String]

    @State private var directory: String = ""
    /// A remote parent chosen through the directory browser. Clone/empty
    /// destinations keep following the project name inside this parent;
    /// directly typing an exact path still opts out through `folderEdited`.
    @State private var customDestinationParent: String?
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
    @State private var remoteDirectorySuggestions: [String] = []
    @State private var isLoadingRemoteDirectorySuggestions = false
    @State private var remoteDirectorySuggestionError: String?
    @State private var showsRemoteDirectoryBrowser = false
    @State private var remoteDirectoryBrowserPath = ""
    @State private var remoteDirectoryListing: RemoteDirectoryListing?
    @State private var isLoadingRemoteDirectoryBrowser = false
    @State private var remoteDirectoryBrowserError: String?
    @State private var agentEnvironmentInventory: PeerHostDoctor.BinaryInventory?
    @State private var isLoadingAgentEnvironment = false
    @State private var agentEnvironmentProbeFailed = false
    /// How many of `repositoryURLSuggestions` came from disk. The rest are
    /// from the account catalog. Kept as a count rather than a second list so
    /// matching and selection keep working on one array.
    @State private var localRepositoryCount = 0
    @State private var remoteRepositoryCount = 0
    @State private var repositoryScanTruncated = false
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
    @State private var showsFailureDetail = false
    @State private var isDiscarding = false
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
            let local = await Task.detached(priority: .utility) {
                RepositoryURLAutocomplete.loadOriginURLs(
                    from: directories,
                    searching: roots
                )
            }.value
            guard !Task.isCancelled else { return }
            // Show what is on disk immediately; the account catalog needs the
            // network and must not hold up a list that is already usable.
            repositoryURLSuggestions = local
            localRepositoryCount = local.count
            remoteRepositoryCount = 0
            repositoryScanTruncated = RepositoryURLAutocomplete.truncatedRepositoryScan
            isLoadingRepositorySuggestions = false

            let remote = await GitHubRepositoryCatalog.load()
            guard !Task.isCancelled, !remote.isEmpty else { return }
            // Anything already cloned stays under its local entry — the same
            // repository listed twice would be two identical rows.
            var seen = Set(local)
            let fresh = remote.filter { seen.insert($0).inserted }
            guard !fresh.isEmpty else { return }
            repositoryURLSuggestions = local + fresh
            remoteRepositoryCount = fresh.count
        }
        .task(id: branchLookupID) {
            await loadRepositoryBranches()
        }
        .task(id: remoteDirectoryAutocompleteID) {
            await loadRemoteDirectorySuggestions()
        }
        .task(id: selectedHostAgentEnvironmentID) {
            await loadSelectedHostAgentEnvironment()
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
            if creationError != nil, showsFailureDetail {
                bootFailureDetail
            }
            Toggle("Show launch commands", isOn: $showsBootCommands)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .accessibilityIdentifier("newProject.bootProgress")
    }

    /// What is known about the failure, opened by Troubleshoot.
    ///
    /// The actions themselves live in the sheet's one footer — a second row of
    /// buttons here meant two Retries and two default-action shortcuts.
    private var bootFailureDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(failedStepMessages, id: \.self) { message in
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Full log: \(RemoteWorkLog.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("A machine that cannot be reached at all shows up in Settings → Peer Hosts → Test.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .accessibilityIdentifier("newProject.failure.detail")
    }

    private var failedStepMessages: [String] {
        var messages = bootSteps
            .sorted(by: { $0.order < $1.order })
            .compactMap { step -> String? in
                guard case let .failed(message) = step.status else { return nil }
                return "\(step.title): \(message)"
            }
        // A failure with no step to pin it on still has to be readable.
        if messages.isEmpty, let creationError {
            messages = [creationError]
        }
        return messages
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
                        if selectedTeamPresetId != nil {
                            Button("Save changes") {
                                saveChangesToSelectedPreset()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Update \(teamPresetDisplayName) with the current team")
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
                        ForEach(placeableHosts, id: \.id) { host in
                            Text(host.isConnected ? host.versionedDisplayName : "\(host.displayName) — offline")
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
                                // Only swallow Tab when it has something to
                                // complete; otherwise it stays the key that
                                // moves to the next field.
                                .backport.onKeyPress(.tab) { _ in
                                    guard let completed = RepositoryBranchLookup.completion(
                                        for: gitBranch, in: repositoryBranches
                                    ) else { return .ignored }
                                    gitBranch = completed
                                    branchEdited = true
                                    return .handled
                                }

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
                            } else if !repositoryBranches.isEmpty {
                                branchPresenceCaption
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
                            ForEach(placeableHosts, id: \.id) { host in
                                Text(host.isConnected ? host.versionedDisplayName : "\(host.displayName) — offline")
                                    .tag(String?.some(host.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        if let runsOnHostKey,
                           let host = placeableHosts.first(where: { $0.id == runsOnHostKey }),
                           !host.isConnected {
                            Label("connecting…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if runsOnHostKey != nil {
                    GridRow {
                        Text("Agent environment")
                        selectedHostAgentEnvironmentSummary
                    }
                }

                if sourceKind == .existingFolder {
                    GridRow {
                        Text("Project folder")
                        directoryFieldControl
                    }
                } else {
                    GridRow {
                        Text("Destination")
                        directoryFieldControl
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
            customDestinationParent = nil
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

    private var directoryFieldControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TextField(folderPlaceholder, text: Binding(
                    get: { directory },
                    set: {
                        directory = RemoteDirectoryLookup.singleLine($0)
                        customDestinationParent = nil
                        folderEdited = true
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($focusedField, equals: .directory)
                .accessibilityLabel(sourceKind == .existingFolder ? "Project folder" : "Project destination")

                if runsOnHostKey == nil {
                    Button("Choose…", action: chooseFolder)
                } else {
                    Button("Browse…", action: presentRemoteDirectoryBrowser)
                        .popover(isPresented: $showsRemoteDirectoryBrowser, arrowEdge: .bottom) {
                            remoteDirectoryBrowser
                        }
                        .accessibilityIdentifier("newProject.remoteDirectoryBrowse")
                        .accessibilityLabel("Browse folders on \(machineLabel(runsOnHostKey))")
                }

                if sourceKind != .existingFolder, folderEdited {
                    Button("Use default") {
                        customDestinationParent = nil
                        folderEdited = false
                        applyDerivedDestination()
                    }
                }
            }

            if let runsOnHostKey, focusedField == .directory {
                remoteDirectoryAutocomplete(hostKey: runsOnHostKey)
            } else if sourceKind != .existingFolder, !folderEdited {
                Text(automaticDestinationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(automaticDestinationHelp)
            }
        }
    }

    @ViewBuilder
    private func remoteDirectoryAutocomplete(hostKey: String) -> some View {
        if isLoadingRemoteDirectorySuggestions {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<2, id: \.self) { _ in
                    Label("Remote folder", systemImage: "folder")
                        .font(.caption)
                        .redacted(reason: .placeholder)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .accessibilityLabel("Loading folders on \(machineLabel(hostKey))")
        } else if !remoteDirectorySuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Folders on \(machineLabel(hostKey))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)

                ForEach(remoteDirectorySuggestions, id: \.self) { path in
                    Button {
                        selectRemoteDirectorySuggestion(path)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .help(path)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Folder suggestions on \(machineLabel(hostKey))")
        } else if let remoteDirectorySuggestionError {
            Text(remoteDirectorySuggestionError)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }

    private var remoteDirectoryBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if let parent = remoteDirectoryListing?.parentPath {
                        remoteDirectoryBrowserPath = parent
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(remoteDirectoryListing?.parentPath == nil)
                .help("Parent folder")

                Text(remoteDirectoryListing?.path ?? remoteDirectoryBrowserPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(remoteDirectoryListing?.path ?? remoteDirectoryBrowserPath)
                Spacer(minLength: 0)
                Button {
                    Task { await loadRemoteDirectoryBrowser() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload folders")
            }
            .padding(12)

            Divider()

            Group {
                if isLoadingRemoteDirectoryBrowser {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<5, id: \.self) { _ in
                            Label("Remote folder name", systemImage: "folder")
                                .redacted(reason: .placeholder)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Loading remote folders")
                } else if let remoteDirectoryBrowserError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(remoteDirectoryBrowserError)
                            .foregroundStyle(.secondary)
                        Button("Retry folder list") {
                            Task { await loadRemoteDirectoryBrowser() }
                        }
                    }
                    .font(.caption)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let listing = remoteDirectoryListing, listing.directories.isEmpty {
                    ContentUnavailableView(
                        "No subfolders",
                        systemImage: "folder",
                        description: Text("Use this folder or go to its parent.")
                    )
                } else if let listing = remoteDirectoryListing {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(listing.directories, id: \.self) { path in
                                Button {
                                    remoteDirectoryBrowserPath = path
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text((path as NSString).lastPathComponent)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                                .help(path)
                            }
                        }
                    }
                }
            }
            .frame(height: 230)

            Divider()

            HStack {
                Text(sourceKind == .existingFolder
                    ? "Select the folder that already contains the project."
                    : "The project folder will be created inside this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Cancel") {
                    showsRemoteDirectoryBrowser = false
                }
                Button(sourceKind == .existingFolder ? "Use folder" : "Create project here") {
                    guard let path = remoteDirectoryListing?.path else { return }
                    useRemoteBrowserPath(path)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remoteDirectoryListing == nil || isLoadingRemoteDirectoryBrowser)
                .accessibilityIdentifier("newProject.remoteDirectoryUse")
            }
            .padding(12)
        }
        .frame(width: 440)
        .task(id: remoteDirectoryBrowserLookupID) {
            await loadRemoteDirectoryBrowser()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folders on \(machineLabel(runsOnHostKey))")
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

    private var remoteDirectoryAutocompleteID: String {
        guard let hostKey = runsOnHostKey,
              focusedField == .directory,
              !showsRemoteDirectoryBrowser else { return "" }
        return "\(hostKey)\u{0}\(directory)"
    }

    private var selectedHostAgentEnvironmentID: String {
        guard let hostKey = runsOnHostKey,
              let host = placeableHosts.first(where: { $0.id == hostKey }),
              let sshTarget = host.sshTarget,
              !sshTarget.isEmpty else { return "" }
        return [hostKey, sshTarget, host.sshPort.map(String.init) ?? "",
                host.identityFile ?? ""].joined(separator: "\u{0}")
    }

    @ViewBuilder
    private var selectedHostAgentEnvironmentSummary: some View {
        if isLoadingAgentEnvironment {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking shell and agent-env…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let inventory = agentEnvironmentInventory {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text(inventory.agentShell.map { "Agent shell: \($0)" }
                         ?? "Agent shell: account login shell")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    if inventory.agentEnvironmentFileExists == true {
                        Label("agent-env ready", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        Label("agent-env missing", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                let path = inventory.agentEnvironmentPath
                    ?? "~/.config/term-mesh/agent-env"
                Text("Put API keys in \(path). Change the shell with chsh; new Claude, Codex, Kiro, Cursor, and Agy agents use it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(agentEnvironmentProbeFailed
                     ? "Couldn’t inspect this host’s agent environment."
                     : "Remote agents use the account login shell.")
                    .font(.caption)
                    .foregroundStyle(agentEnvironmentProbeFailed ? Color.orange : Color.secondary)
                Text("Put API keys in ~/.config/term-mesh/agent-env. Change the shell with chsh; restart existing agents after changes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func loadSelectedHostAgentEnvironment() async {
        agentEnvironmentInventory = nil
        agentEnvironmentProbeFailed = false
        isLoadingAgentEnvironment = false
        let requestID = selectedHostAgentEnvironmentID
        guard !requestID.isEmpty,
              let hostKey = runsOnHostKey,
              let host = placeableHosts.first(where: { $0.id == hostKey }),
              let sshTarget = host.sshTarget else { return }
        isLoadingAgentEnvironment = true
        let inventory = await PeerHostDoctor.binaryInventory(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile
        )
        guard !Task.isCancelled, selectedHostAgentEnvironmentID == requestID else { return }
        agentEnvironmentInventory = inventory
        agentEnvironmentProbeFailed = inventory == nil
        isLoadingAgentEnvironment = false
    }

    private var remoteDirectoryBrowserLookupID: String {
        guard showsRemoteDirectoryBrowser, let hostKey = runsOnHostKey else { return "" }
        return "\(hostKey)\u{0}\(remoteDirectoryBrowserPath)"
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

    private func loadRemoteDirectorySuggestions() async {
        remoteDirectorySuggestions = []
        remoteDirectorySuggestionError = nil
        isLoadingRemoteDirectorySuggestions = false

        let requestID = remoteDirectoryAutocompleteID
        guard !requestID.isEmpty,
              let hostKey = runsOnHostKey,
              let host = placeableHosts.first(where: { $0.id == hostKey }) else { return }

        do {
            try await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, remoteDirectoryAutocompleteID == requestID else { return }
            isLoadingRemoteDirectorySuggestions = true
            let query = RemoteDirectoryLookup.completionQuery(for: directory)
            let listing = try await RemoteDirectoryLookup.load(host: host, path: query.parentPath)
            guard !Task.isCancelled, remoteDirectoryAutocompleteID == requestID else { return }
            remoteDirectorySuggestions = RemoteDirectoryLookup.matches(
                listing.directories,
                prefix: query.prefix,
                limit: 7
            )
        } catch is CancellationError {
            return
        } catch {
            guard remoteDirectoryAutocompleteID == requestID else { return }
            remoteDirectorySuggestionError = "Couldn’t load folders from \(host.displayName)."
        }
        isLoadingRemoteDirectorySuggestions = false
    }

    private func presentRemoteDirectoryBrowser() {
        guard runsOnHostKey != nil else { return }
        let query = RemoteDirectoryLookup.completionQuery(for: directory)
        let configuredRoot = runsOnHostKey.flatMap { hostKey in
            PeerHostProfileStore.shared.profiles
                .first(where: { $0.stableKey == hostKey })?
                .projectRootPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        remoteDirectoryBrowserPath = customDestinationParent
            ?? (query.parentPath.isEmpty ? nil : query.parentPath)
            ?? configuredRoot
            ?? "~"
        remoteDirectoryListing = nil
        remoteDirectoryBrowserError = nil
        showsRemoteDirectoryBrowser = true
    }

    private func loadRemoteDirectoryBrowser() async {
        let requestID = remoteDirectoryBrowserLookupID
        guard !requestID.isEmpty,
              let hostKey = runsOnHostKey,
              let host = placeableHosts.first(where: { $0.id == hostKey }) else { return }
        isLoadingRemoteDirectoryBrowser = true
        remoteDirectoryBrowserError = nil
        do {
            let listing = try await RemoteDirectoryLookup.load(
                host: host,
                path: remoteDirectoryBrowserPath
            )
            guard !Task.isCancelled, remoteDirectoryBrowserLookupID == requestID else { return }
            remoteDirectoryListing = listing
            remoteDirectoryBrowserPath = listing.path
        } catch is CancellationError {
            return
        } catch {
            guard remoteDirectoryBrowserLookupID == requestID else { return }
            remoteDirectoryListing = nil
            remoteDirectoryBrowserError = "Couldn’t read this folder. Check the host connection and permissions."
        }
        isLoadingRemoteDirectoryBrowser = false
    }

    private func selectRemoteDirectorySuggestion(_ path: String) {
        if sourceKind == .existingFolder {
            useRemoteFolder(path)
        } else {
            useRemoteDestinationParent(path)
        }
        focusedField = nil
    }

    private func useRemoteBrowserPath(_ path: String) {
        if sourceKind == .existingFolder {
            useRemoteFolder(path)
        } else {
            useRemoteDestinationParent(path)
        }
        showsRemoteDirectoryBrowser = false
        focusedField = nil
    }

    private func useRemoteFolder(_ path: String) {
        customDestinationParent = nil
        directory = RemoteDirectoryLookup.selectedPath(
            sourceKind: .existingFolder,
            folder: path,
            projectName: effectiveName
        )
        folderEdited = true
        if !nameEdited {
            name = (path as NSString).lastPathComponent
        }
    }

    private func useRemoteDestinationParent(_ path: String) {
        customDestinationParent = path
        folderEdited = true
        applyDerivedDestination()
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
            // Say where the entries came from. Calling them "repositories"
            // read as the account's whole list, when what was on offer was
            // whatever this machine had already cloned.
            var parts = ["\(localRepositoryCount) found locally"]
            if repositoryScanTruncated { parts[0] += " (scan limit reached)" }
            if remoteRepositoryCount > 0 {
                parts.append("\(remoteRepositoryCount) remote")
            }
            return "Recent · " + parts.joined(separator: ", ") + " · Type to search"
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
        guard sourceKind != .existingFolder else { return }
        let projectName = effectiveName.isEmpty ? Self.placeholderProjectName : effectiveName
        if let customDestinationParent {
            directory = RemoteDirectoryLookup.selectedPath(
                sourceKind: sourceKind,
                folder: customDestinationParent,
                projectName: projectName
            )
            syncInheritedAgentPlacements()
            return
        }
        guard !folderEdited else { return }
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

    private var automaticDestinationDescription: String {
        if runsOnHostKey == nil {
            return "Automatic · \(ProjectLocationSettings.localProjectsRoot)"
        }
        if let hostKey = runsOnHostKey,
           let configured = PeerHostProfileStore.shared.profiles
            .first(where: { $0.stableKey == hostKey })?
            .projectRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return "Automatic · \(configured)"
        }
        return "Automatic · Set a project root for this host"
    }

    private var automaticDestinationHelp: String {
        runsOnHostKey == nil
            ? "Change the default in Settings → Agent Teams → Projects Under."
            : "Change the default in this host's Projects Under setting."
    }

    /// Stands in for a project name that has not been given yet, so the
    /// predicted folder is a real path rather than the bare root.
    static let placeholderProjectName = "new-project"

    /// Peers whose current connection has finished authenticating the CLI
    /// metadata used by project and agent launch. Connected-but-pending rows
    /// stay out of the picker instead of exposing a choice creation rejects.
    private var selectablePeers: [HostEntry] {
        RemoteHostStore.selectableLaunchHosts(in: hostStore.sortedHosts)
    }

    /// Every saved machine the pickers offer — connected or not.
    ///
    /// Picking one starts its connection (`applyRunsOn`,
    /// `connectHostIfNeeded`), which is what the "— offline" row labels and
    /// the "connecting…" badge beside the leader picker are for. Feeding the
    /// pickers `selectablePeers` instead made all of that unreachable: a host
    /// had to be connected *already* to even appear, so placing work on an
    /// idle machine meant leaving the sheet, connecting it in the sidebar,
    /// and starting over. Readiness is still judged by `selectablePeers` —
    /// this widens what you may ask for, not what may launch.
    private var placeableHosts: [HostEntry] {
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
        return placeableHosts.first(where: { $0.id == hostKey })?.displayName ?? hostKey
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
              let host = placeableHosts.first(where: { $0.id == hostKey }),
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
        customDestinationParent = nil
        guard let hostKey else {
            directory = ""
            syncInheritedAgentPlacements()
            return
        }
        // Picking a machine is as good as saying "use that one", so the
        // connection is started here rather than left as a step to discover
        // at Create time when the agents fail to attach.
        if let host = placeableHosts.first(where: { $0.id == hostKey }), !host.isConnected {
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
        HStack(spacing: 12) {
            if showsCreationProgress {
                Text(creationError == nil
                    ? "Keep this window open while the project starts."
                    : "Review the failed step, then retry or change the settings.")
                    .font(.caption)
                    .foregroundStyle(creationError == nil ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
            } else {
                // A disabled button with no stated reason reads as a bug. When
                // placement is what blocks it, say so here rather than leaving
                // the summary to describe a run that cannot start.
                let blocker = creationError ?? placementBlockerMessage
                Text(blocker ?? creationSummary)
                    .font(.caption)
                    .foregroundStyle(
                        creationError != nil
                            ? Color.red
                            : (blocker != nil ? Color.orange : Color.secondary)
                    )
                    .lineLimit(blocker == nil ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: blocker != nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
                    .help(blocker ?? creationSummary)
            }
            HStack(spacing: 10) {
                if showsCreationProgress {
                    if creationError != nil {
                        Button(showsFailureDetail ? "Hide details" : "Troubleshoot") {
                            showsFailureDetail.toggle()
                        }
                        .accessibilityIdentifier("newProject.failure.troubleshoot")
                        Button("Back to settings") {
                            showsCreationProgress = false
                            creationError = nil
                            showsFailureDetail = false
                        }
                        .keyboardShortcut(.cancelAction)
                        // Closing onto a project whose leader never arrived is
                        // what left checkouts on peers that nothing would use,
                        // so it is a deliberate choice rather than the way out.
                        Button("Keep as is", action: onClose)
                            .accessibilityIdentifier("newProject.failure.keep")
                        Button("Retry project") {
                            startCreation()
                        }
                        .accessibilityIdentifier("newProject.failure.retry")
                        Button("Discard and close") {
                            Task { @MainActor in
                                isDiscarding = true
                                await onDiscard(effectiveName)
                                isDiscarding = false
                                onClose()
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isDiscarding)
                        .accessibilityIdentifier("newProject.failure.discard")
                    } else {
                        Button("Starting…") {}
                            .disabled(true)
                    }
                } else {
                    // Offered only while the machine is what blocks the run,
                    // and next to the sentence that says so.
                    if let retryTitle = placementRetryTitle {
                        Button(retryTitle) { runPlacementRetry() }
                            .accessibilityIdentifier("newProject.placementRetry")
                    }
                    Button("Cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                    Button(createActionLabel) {
                        startCreation()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        !canCreate || !placementHostsAreReady
                            || TeamAgentComposer.blocksRemoteTeamCreation(
                                agents: agents, hosts: hostStore.sortedHosts
                            )
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var effectiveIsolation: Bool {
        isolateAgents && !(sourceKind == .existingFolder && gitURL.isEmpty)
    }

    private func startCreation() {
        if let problem = PeerProjectBootstrap.repositoryURLProblem(gitURL) {
            creationError = problem
            RemoteWorkLog.error("Could not create \(effectiveName): \(problem)")
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
        // Retry runs through here again, so the previous attempt's red rows and
        // opened detail have to go with it — otherwise the second run reads as
        // the first one still failing.
        showsFailureDetail = false
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
                RemoteWorkLog.error("Could not create \(effectiveName): \(message)")
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
            placeableHosts.first(where: { $0.id == hostKey })?.displayName
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
        let allConnected = remoteKeys.allSatisfy { hostKey in
            selectablePeers.first(where: { $0.id == hostKey })?.isLaunchable == true
        }
        return allConnected && agentsMissingHostDirectory.isEmpty
    }

    /// Why the create button is off, when placement is the reason.
    private var placementBlockerMessage: String? {
        let missing = agentsMissingHostDirectory
        if !missing.isEmpty {
            let names = missing.map(\.preset.displayName).joined(separator: ", ")
            return missing.count == 1
                ? "\(names) runs on another machine but has no project folder yet."
                : "These agents run on another machine but have no project folder yet: \(names)."
        }
        let offline = Set([runsOnHostKey].compactMap { $0 } + agents.compactMap(\.hostKey))
            .filter { hostKey in
                selectablePeers.first(where: { $0.id == hostKey })?.isLaunchable != true
            }
        guard !offline.isEmpty else { return nil }
        let labels = offline.map { machineLabel($0) }.sorted().joined(separator: ", ")
        // Picking a machine starts connecting it, so while that is in flight
        // the honest answer is "wait a moment", not "this cannot launch" —
        // the latter reads as a dead end and sends people out of the sheet.
        let allStillConnecting = offline.allSatisfy { hostKey in
            placeableHosts.first(where: { $0.id == hostKey })?.connectionState == .connecting
        }
        if allStillConnecting {
            return "Connecting to \(labels)…"
        }
        // "Not ready" covers three different situations, and the button beside
        // it does a different thing in each. Saying which one it is turns a
        // verdict into something the person can act on.
        if offline.count == 1,
           let hostKey = offline.first,
           let host = placeableHosts.first(where: { $0.id == hostKey }) {
            switch host.connectionState {
            case .failed(let reason):
                return "\(labels) could not be reached — \(reason)"
            case .saved:
                return "\(labels) is not connected yet."
            case .connected:
                // Connected but not launchable: the PATH a remote CLI needs is
                // still unresolved, so starting now would launch with the
                // wrong search path (see `HostEntry.isLaunchable`).
                return "\(labels) is connected but still resolving where its tools live."
            case .connecting:
                break
            }
        }
        return offline.count == 1
            ? "\(labels) is not ready to launch remote tools."
            : "These machines are not ready to launch remote tools: \(labels)."
    }

    /// Whether the branch typed here is one the remote actually has.
    ///
    /// Worth saying before the run rather than after: a name with no branch
    /// behind it fails inside `git clone`, several seconds in, as a message
    /// from git — long after the sheet has closed on it.
    private enum BranchPresence { case unknown, exists, missing }

    private var branchPresence: BranchPresence {
        let branch = RepositoryBranchLookup.singleLine(gitBranch)
        // An empty field means "the default branch", which is always fine, and
        // an unlisted repository is a question this cannot answer.
        guard !branch.isEmpty, !isLoadingRepositoryBranches, !repositoryBranches.isEmpty else {
            return .unknown
        }
        return RepositoryBranchLookup.contains(branch, in: repositoryBranches) ? .exists : .missing
    }

    @ViewBuilder
    private var branchPresenceCaption: some View {
        switch branchPresence {
        case .exists:
            Label(
                "\(RepositoryBranchLookup.singleLine(gitBranch)) exists in this repository",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
        case .missing:
            Label(
                defaultRepositoryBranch.map {
                    "No branch named \(RepositoryBranchLookup.singleLine(gitBranch)) here — the clone will fail. Default: \($0)"
                } ?? "No branch named \(RepositoryBranchLookup.singleLine(gitBranch)) in this repository — the clone will fail",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            if let defaultRepositoryBranch {
                Text("\(repositoryBranches.count) branches · Default: \(defaultRepositoryBranch)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The machines this sheet is waiting on, and cannot start without.
    ///
    /// Excludes the ones already connecting: those need patience, not another
    /// attempt. A connected-but-not-launchable host is included on purpose —
    /// it is still resolving the PATH a remote CLI needs, and reconnecting is
    /// what settles it if that stalled.
    private var placementRetryHosts: [HostEntry] {
        let keys = Set([runsOnHostKey].compactMap { $0 } + agents.compactMap(\.hostKey))
        return keys.compactMap { key in placeableHosts.first(where: { $0.id == key }) }
            .filter { !$0.isLaunchable && $0.connectionState != .connecting }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Saying a machine is not ready and offering nothing to do about it is a
    /// dead end: this sheet has no other place to connect from, and leaving it
    /// to use the sidebar discards the form. The action is the same one the
    /// sidebar offers — reconnect — placed where the reason is stated.
    private var placementRetryTitle: String? {
        let hosts = placementRetryHosts
        guard let first = hosts.first else { return nil }
        if hosts.count > 1 { return "Reconnect machines" }
        if case .failed = first.connectionState { return "Retry \(first.displayName)" }
        return "Connect \(first.displayName)"
    }

    private func runPlacementRetry() {
        let store = RemoteHostStore.shared
        for host in placementRetryHosts {
            // A connected host can still be waiting for the authenticated CLI
            // directory handshake. Reusing connectSavedHost here is a no-op
            // because it intentionally rejects hosts that already have a
            // sidebar lease; reset the lease and start a real retry instead.
            _ = store.retryConnectingHost(host)
        }
    }

    /// Peer-bound agents whose project folder is still blank.
    ///
    /// A remote agent without a directory fails at creation — the host, not
    /// this app, decides where a checkout lives, and there is no local path to
    /// borrow. Refusing here turns that into a disabled button with a reason
    /// instead of a run that dies partway.
    private var agentsMissingHostDirectory: [TeamAgentRow] {
        agents.filter { agent in
            let hostKey = Self.resolvedAgentHostKey(
                mode: agentPlacementMode,
                leaderHostKey: runsOnHostKey,
                allAgentsHostKey: allAgentsHostKey,
                explicitHostKey: agent.hostKey,
                inheritsDefault: inheritedAgentIDs.contains(agent.id)
            )
            guard hostKey != nil else { return false }
            let resolved = agent.hostDirectory.isEmpty
                ? defaultAgentHostDirectory
                : agent.hostDirectory
            return resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
              var template = teamTemplateManager.template(for: selectedTeamPresetId) else { return }
        let sourcePayload = template.origin == .builtIn
            ? (teamTemplateManager.effectivePayload(for: selectedTeamPresetId) ?? template.payload)
            : template.payload
        guard case .smart(var preset) = sourcePayload else { return }
        preset.leaderMode = leaderCli
        preset.leaderModel = leaderCli == "repl" ? nil : leaderModel
        preset.agents = currentProviderPreferences
        preset.description = "\(agents.count) agent\(agents.count == 1 ? "" : "s")"
        let updatedPayload = TeamTemplatePayload.smart(preset)

        switch template.origin {
        case .custom:
            template.payload = updatedPayload
            do {
                try teamTemplateManager.updateCustom(template)
            } catch {
                presetError = error.localizedDescription
                return
            }
        case .builtIn:
            teamTemplateManager.saveOverride(
                for: selectedTeamPresetId,
                payload: updatedPayload
            )
        }

        appliedTeamSignature = currentTeamSignature
        showPresetSavedConfirmation("Saved to \(template.name)")
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
        customDestinationParent = nil
        directory = url.path
        folderEdited = true
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

struct RemoteDirectoryListing: Equatable {
    let path: String
    let parentPath: String?
    let directories: [String]
}

enum RemoteDirectoryLookup {
    struct CompletionQuery: Equatable {
        let parentPath: String
        let prefix: String
    }

    enum LookupError: LocalizedError {
        case missingSSHRoute
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingSSHRoute: "The selected host has no SSH route."
            case .invalidResponse: "The host returned an invalid folder list."
            }
        }
    }

    static func singleLine(_ raw: String) -> String {
        String(raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? "")
    }

    static func completionQuery(for rawPath: String) -> CompletionQuery {
        var path = singleLine(rawPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return CompletionQuery(parentPath: "~", prefix: "") }
        if path != "/", path.hasSuffix("/") {
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return CompletionQuery(parentPath: path, prefix: "")
        }
        if path == "/" || path == "~" {
            return CompletionQuery(parentPath: path, prefix: "")
        }
        let parent = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent
        return CompletionQuery(
            parentPath: parent.isEmpty ? (path.hasPrefix("/") ? "/" : "~") : parent,
            prefix: prefix
        )
    }

    static func matches(_ directories: [String], prefix: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let filtered = directories.lazy.filter { path in
            prefix.isEmpty
                || (path as NSString).lastPathComponent.range(
                    of: prefix,
                    options: [.anchored, .caseInsensitive]
                ) != nil
        }
        return Array(filtered.prefix(limit))
    }

    static func selectedPath(
        sourceKind: ProjectSourceKind,
        folder: String,
        projectName: String
    ) -> String {
        switch sourceKind {
        case .existingFolder:
            return folder
        case .clone, .empty:
            return (folder as NSString).appendingPathComponent(projectName)
        }
    }

    static func script(for rawPath: String) -> String {
        let path = singleLine(rawPath).trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = shellQuote(path.isEmpty ? "~" : path)
        return "p=\(quoted); "
            + "case \"$p\" in '~') p=\"$HOME\" ;; '~/'*) p=\"$HOME/${p#??}\" ;; esac; "
            + "cd \"$p\" || exit 44; "
            + "printf '%s\\0' \"$(pwd -P)\"; "
            // -L so a symlinked folder is listed as the folder it points at.
            // Hosts routinely reach a checkout through a link (/srv/app ->
            // /mnt/data/app), and without this the browser shows an empty
            // parent while `cd` into the same path works. Depth is still 1, so
            // there is no link cycle to walk; a dangling link fails the -type
            // test and drops out, which is what should happen to a path that
            // cannot be entered.
            + "find -L . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0"
    }

    static func parse(_ output: String) throws -> RemoteDirectoryListing {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard let rawBase = fields.first else { throw LookupError.invalidResponse }
        let base = (rawBase as NSString).standardizingPath
        guard base.hasPrefix("/"), !base.contains("\n") else { throw LookupError.invalidResponse }

        var seen = Set<String>()
        let directories = fields.dropFirst().compactMap { raw -> String? in
            let relative = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            guard !relative.isEmpty,
                  !relative.hasPrefix("."),
                  !relative.contains("/"),
                  !relative.contains("\n") else { return nil }
            let full = (base as NSString).appendingPathComponent(relative)
            return seen.insert(full).inserted ? full : nil
        }.sorted { lhs, rhs in
            (lhs as NSString).lastPathComponent.localizedStandardCompare(
                (rhs as NSString).lastPathComponent
            ) == .orderedAscending
        }
        let parent = base == "/" ? nil : (base as NSString).deletingLastPathComponent
        return RemoteDirectoryListing(path: base, parentPath: parent, directories: directories)
    }

    static func load(host: HostEntry, path: String) async throws -> RemoteDirectoryListing {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
            throw LookupError.missingSSHRoute
        }
        let output = try await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile,
            script: script(for: path),
            timeoutSeconds: 15
        )
        return try parse(output)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    /// The ceiling exists so a root pointed at a home directory cannot turn
    /// opening the sheet into an unbounded walk. It was 250, which a single
    /// ordinary work folder already exceeds — and it stopped silently, so the
    /// list simply ended with no sign that anything had been left out.
    /// `truncatedRepositoryScan` records when it bites.
    static private(set) var truncatedRepositoryScan = false

    static func discoverRepositories(
        under roots: [String],
        maximumDepth: Int = 4,
        maximumRepositories: Int = 2000
    ) -> [String] {
        truncatedRepositoryScan = false
        guard maximumDepth >= 0, maximumRepositories > 0 else { return [] }
        let fileManager = FileManager.default
        var queue = roots.map {
            (TeamCreationRecentDirs.normalize($0), 0)
        }
        var nextIndex = 0
        var visited = Set<String>()
        var repositories: [String] = []

        while nextIndex < queue.count {
            guard repositories.count < maximumRepositories else {
                truncatedRepositoryScan = true
                break
            }
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

/// Repositories the account can reach but this machine has not cloned.
///
/// The local scan can only offer what is already on disk, which makes the
/// first clone of anything the one case it cannot help with. This fills that
/// gap from the GitHub API.
///
/// Authentication is borrowed from `gh` rather than stored: the token is read
/// at call time and never written anywhere, so there is no credential for this
/// app to keep, rotate, or leak. Without `gh` the catalog is simply empty and
/// the local list stands on its own.
enum GitHubRepositoryCatalog {
    /// Long enough that opening the sheet repeatedly costs one request, short
    /// enough that a repository created this morning shows up this afternoon.
    static let cacheLifetime: TimeInterval = 6 * 60 * 60

    struct Cache: Codable {
        var fetchedAt: Date
        var sshURLs: [String]
    }

    private static var cacheURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".term-mesh", isDirectory: true)
            .appendingPathComponent("github-repos.json")
    }

    /// Cached SSH URLs, or nil when there is no usable cache.
    static func cached() -> [String]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              Date().timeIntervalSince(cache.fetchedAt) < cacheLifetime
        else { return nil }
        return cache.sshURLs
    }

    /// Every repository the token can see, newest first, as `git@` URLs so the
    /// list is directly comparable with what the local scan produces.
    ///
    /// Returns the cache when it is fresh. A failure of any kind — no `gh`, no
    /// network, a refused token — yields an empty list rather than an error:
    /// this is an additional convenience over the local scan, never a
    /// precondition for it.
    static func load(forceRefresh: Bool = false) async -> [String] {
        if !forceRefresh, let cached = cached() { return cached }
        guard let token = await ghToken() else { return [] }
        var urls: [String] = []
        var page = 1
        // A hard page ceiling: an account with thousands of repositories should
        // not turn opening this sheet into a dozen round trips.
        while page <= 10 {
            guard let batch = await fetchPage(page, token: token), !batch.isEmpty else { break }
            urls.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        guard !urls.isEmpty else { return [] }
        persist(urls)
        return urls
    }

    private static func persist(_ urls: [String]) {
        let cache = Cache(fetchedAt: Date(), sshURLs: urls)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
        // Owner-only: the list names private repositories. `.atomic` replaces
        // the file, so the mode is reapplied on every write rather than once
        // at creation.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: cacheURL.path
        )
    }

    private static func fetchPage(_ page: Int, token: String) async -> [String]? {
        var components = URLComponents(string: "https://api.github.com/user/repos")
        components?.queryItems = [
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return rows.compactMap { $0["ssh_url"] as? String }
    }

    /// `gh auth token`, or nil when gh is absent or logged out.
    private static func ghToken() async -> String? {
        guard let executable = ghExecutable() else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["auth", "token"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        }.value
    }

    /// A GUI app inherits a minimal PATH, so `gh` is looked for where its
    /// installers actually put it rather than trusted to be on the path.
    private static func ghExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/gh"),
            "/usr/bin/gh",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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

    /// Tab completion, shell-style: extend only as far as every candidate
    /// agrees.
    ///
    /// Completing to the first match would silently pick one of several
    /// equally valid branches, and picking the wrong branch is not a typo the
    /// person sees — it is a clone of the wrong code. Stopping at the common
    /// prefix leaves the choosing keystroke theirs.
    ///
    /// Prefix-matched (unlike the suggestion list, which is substring-matched)
    /// because that is what a completion key means everywhere else. Matching
    /// ignores case but the result keeps the branch's own spelling, so `MAIN`
    /// completes to `main`.
    static func completion(for rawQuery: String, in branches: [String]) -> String? {
        let query = singleLine(rawQuery)
        let candidates = branches.filter {
            $0.lowercased().hasPrefix(query.lowercased())
        }
        guard let first = candidates.first else { return nil }
        guard candidates.count > 1 else { return first == query ? nil : first }
        var shared = first
        for candidate in candidates.dropFirst() {
            shared = String(zip(shared, candidate).prefix { $0 == $1 }.map(\.0))
            if shared.isEmpty { return nil }
        }
        return shared.count > query.count ? shared : nil
    }

    /// Whether a branch this repository actually has was named.
    static func contains(_ rawBranch: String, in branches: [String]) -> Bool {
        let branch = singleLine(rawBranch)
        guard !branch.isEmpty else { return false }
        return branches.contains { $0.caseInsensitiveCompare(branch) == .orderedSame }
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
        /// An existing folder cannot be put on a second machine without a
        /// repository to reproduce it from. See
        /// `PeerProjectBootstrap.requiresRepositoryURL`.
        case repositoryURLRequired(host: String, sourceHost: String)
        /// The team exists and some of it came up, but not all. Thrown so the
        /// sheet stays on screen with the per-step detail rather than closing
        /// onto a project whose leader never arrived.
        case attachIncomplete(failures: [String])
        /// Nothing reported back within the budget. Distinct from a failure —
        /// the work may still be in flight on the peer, which is why the sheet
        /// offers to retry rather than only to clean up.
        case attachTimedOut(seconds: Int, pending: [String])
        /// Retry found the team from a previous attempt and could not get its
        /// leader up either. Distinct from the first failure: the checkouts are
        /// already there, so the next step is not to build them again.
        case leaderRepairFailed(detail: String?)
        /// The project is there and some of its members are not. Retry cannot
        /// put them back on its own: a failed agent's checkout is reclaimed
        /// when it fails, so re-attaching needs one made again — which is
        /// creation, not repair.
        case membersMissing(names: [String])

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
            case .repositoryURLRequired(let host, let sourceHost):
                """
                \(host) has no copy of this project and there is no Repository \
                URL to make one from. term-mesh will not start agents in a \
                folder it cannot verify is this project. Add the repository's \
                URL, or keep every agent on \(sourceHost).
                """
            case .attachIncomplete(let failures):
                failures.count == 1
                    ? failures[0]
                    : "\(failures.count) parts of the project did not start:\n"
                        + failures.map { "• \($0)" }.joined(separator: "\n")
            case .attachTimedOut(let seconds, let pending):
                "Nothing reported back within \(seconds)s. Still waiting on: "
                    + pending.joined(separator: ", ")
            case .membersMissing(let names):
                "This project is missing " + names.joined(separator: ", ")
                    + ". Discard and create it again to bring them back."
            case .leaderRepairFailed(let detail):
                detail.map { "Could not start the leader on retry: \($0)" }
                    ?? "Could not start the leader on retry."
            }
        }
    }

    /// How long the sheet waits for every peer attach to report.
    ///
    /// Above the leader's own attach deadline so a leader that times out is
    /// reported as *that*, with its host and reason, instead of being swallowed
    /// by a shorter outer budget that can only say "nothing came back".
    static let attachBudgetSeconds = 180

    /// Who has an attach to wait on, and what to call them if they never report.
    static func remoteParticipantLabels(
        leaderEndpoint: LeaderEndpoint,
        rows: [TeamAgentRow]
    ) -> [(stepID: String, label: String)] {
        var participants: [(stepID: String, label: String)] = []
        if case .peer = leaderEndpoint {
            participants.append((stepID: "leader", label: "leader"))
        }
        for row in rows where row.hostKey != nil {
            participants.append((
                stepID: "agent:\(row.id.uuidString)",
                label: row.preset.displayName
            ))
        }
        return participants
    }

    /// Wait to be told the attaches settled, or give up after `seconds`.
    ///
    /// `register` receives the "settled" closure to hold onto; calling it ends
    /// the wait. A flag decides which of the two arrivals wins, because a
    /// continuation resumed twice traps.
    ///
    /// Returns true when the budget ran out.
    @MainActor
    static func waitForSettle(
        seconds: Int,
        register: @MainActor (@escaping @MainActor () -> Void) -> Void
    ) async -> Bool {
        var finished = false
        return await withCheckedContinuation { continuation in
            register {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: false)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !finished else { return }
                finished = true
                continuation.resume(returning: true)
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
        // A name already in use usually means the project is open, not that
        // something failed. Creating one silently returned nil and the sheet
        // just closed, which reads as the button not working — so go to the
        // one that is there.
        //
        // Unless it is the wreckage of a previous attempt. Keeping the sheet up
        // on failure means a failed run leaves its team and workspace behind,
        // so `Retry project` arrives here and this used to select the
        // half-built workspace and report success — the recovery button closing
        // the sheet without recovering anything. `leaderReady` is the
        // difference: false while a requested peer leader is still connecting
        // or failed to launch.
        if let existing = TeamOrchestrator.shared.teams[name],
           let workspace = tabManager.tabs.first(where: { $0.id == existing.workspaceId }) {
            // A member the form asked for that never joined leaves the same
            // false success as a missing leader, and `leaderReady` says nothing
            // about it: an agent failure appends to the sheet's own list and
            // writes nothing to the team. Reported rather than repaired,
            // because re-attaching needs a checkout this one no longer has —
            // a failed agent's checkout is reclaimed at the point it fails.
            let joined = Set(existing.agents.map(\.name))
            let missing = rows
                .filter { $0.hostKey != nil && !joined.contains($0.preset.name) }
                .map(\.preset.name)
            guard missing.isEmpty else {
                tabManager.selectWorkspace(workspace)
                throw CreationError.membersMissing(names: missing)
            }
            guard existing.leaderReady else {
                // Repair rather than rebuild: the checkouts exist, and
                // `recoverRemoteLeaderIfNeeded` is documented as safe for an
                // initial attach that failed before a surface was recorded.
                tabManager.selectWorkspace(workspace)
                let repaired = await TeamOrchestrator.shared
                    .recoverRemoteLeaderIfNeeded(teamName: name)
                guard repaired else {
                    throw CreationError.leaderRepairFailed(
                        detail: TeamOrchestrator.shared.teams[name]?.leaderFailureDescription
                    )
                }
                return
            }
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

        // The outcome callback names an agent; the sheet's rows are keyed by
        // the row's id, so keep the way back.
        var stepIDsByAgentName: [String: String] = [:]
        for row in prepared.rows {
            stepIDsByAgentName[row.preset.name] = "agent:\(row.id.uuidString)"
        }
        let remoteParticipants = Self.remoteParticipantLabels(
            leaderEndpoint: leader.endpoint,
            rows: prepared.rows
        )

        var settleResume: (@MainActor () -> Void)?
        var hasSettled = false
        var failures: [String] = []
        var reported = Set<String>()

        let onAttach: (TeamOrchestrator.RemoteAttachOutcome) -> Void = { outcome in
            switch outcome {
            case .leaderAttached(let host):
                reported.insert("leader")
                progress(.completed(
                    id: "leader",
                    detail: "\(leader.mode.capitalized) started on \(hostDisplayName(host))"
                ))
            case .leaderFailed(_, let message):
                reported.insert("leader")
                failures.append(message)
                progress(.failed(id: "leader", message: message))
            case .agentAttached(let agentName, let host):
                guard let id = stepIDsByAgentName[agentName] else { break }
                reported.insert(id)
                progress(.completed(
                    id: id,
                    detail: "\(agentName) started on \(hostDisplayName(host))"
                ))
            case .agentFailed(let agentName, _, let message):
                failures.append(message)
                guard let id = stepIDsByAgentName[agentName] else { break }
                reported.insert(id)
                progress(.failed(id: id, message: message))
            case .settled:
                hasSettled = true
                settleResume?()
                settleResume = nil
            }
        }

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
            onRemoteAttach: onAttach,
            tabManager: tabManager
        ) != nil else {
            progress(.failed(id: "leader", message: "Could not create the project team."))
            throw CreationError.teamCreationFailed
        }

        // Local participants are running the moment the team exists; only the
        // peer ones have an attach to wait on, and `settled` covers those.
        if !remoteParticipants.isEmpty && !hasSettled {
            let timedOut = await Self.waitForSettle(seconds: attachBudgetSeconds) { resume in
                if hasSettled {
                    resume()
                } else {
                    settleResume = resume
                }
            }
            if timedOut {
                let pending = remoteParticipants.filter { !reported.contains($0.stepID) }
                for participant in pending {
                    progress(.failed(
                        id: participant.stepID,
                        message: "did not report back within \(attachBudgetSeconds)s"
                    ))
                }
                throw CreationError.attachTimedOut(
                    seconds: attachBudgetSeconds,
                    pending: pending.map(\.label)
                )
            }
        }

        // Anything that never reported is running locally, so it is up.
        if !reported.contains("leader") {
            progress(.completed(
                id: "leader",
                detail: "\(leader.mode.capitalized) launched on \(hostDisplayName(leader.endpoint.hostKey)) · \(leaderPath)"
            ))
        }
        for row in prepared.rows {
            let id = "agent:\(row.id.uuidString)"
            guard !reported.contains(id) else { continue }
            progress(.completed(
                id: id,
                detail: "\(row.preset.displayName) launch requested on \(hostDisplayName(row.hostKey))"
            ))
        }

        // The team is real either way — the sheet stays up so the failure can
        // be read and acted on, rather than closing onto a half-started project.
        guard failures.isEmpty else {
            throw CreationError.attachIncomplete(failures: failures)
        }
        // A project with agents in it is what the board is for, so making one
        // puts it up.
        ReviewBoardSettings.setVisible(true)
    }

    /// A machine this transaction has already finished with, and what it would
    /// take to undo it.
    ///
    /// The ssh coordinates are captured here rather than looked up again at
    /// rollback time: the host list can change while a creation is in flight,
    /// and an undo has to reach the machine the work was actually done on.
    struct CompletedPlacement {
        var hostKey: String?
        var sshTarget: String?
        var port: Int?
        var identityFile: String?
        var environment: [String: String]
        var plan: PeerProjectBootstrap.Plan
    }

    /// Undo the placements that succeeded, newest first.
    ///
    /// Returns whether every one of them was reclaimed. Best effort by design:
    /// the usual reason a placement failed is that a machine went away, and the
    /// machines before it may have gone with it — so a rollback that cannot
    /// reach a host says so instead of failing the failure.
    @MainActor
    private static func rollBack(
        _ completed: [CompletedPlacement],
        instanceTag: String,
        progress: @escaping @MainActor (ProjectCreationEvent) -> Void
    ) async -> Bool {
        let undoable = completed.filter {
            PeerProjectBootstrap.cleanupScript(for: $0.plan, instanceTag: instanceTag) != nil
        }
        guard !undoable.isEmpty else { return true }
        let stepID = "rollback:\(instanceTag)"
        progress(.started(ProjectBootStep(
            id: stepID,
            order: 9_000,
            title: "Undo prepared checkouts",
            detail: "\(undoable.count) machine(s)",
            command: nil,
            status: .running
        )))
        var stranded: [String] = []
        for placement in undoable.reversed() {
            let reclaimed: Bool
            if let sshTarget = placement.sshTarget {
                reclaimed = await PeerProjectBootstrap.cleanup(
                    sshTarget: sshTarget,
                    port: placement.port,
                    identityFile: placement.identityFile,
                    plan: placement.plan,
                    instanceTag: instanceTag,
                    environment: placement.environment
                )
            } else {
                reclaimed = await PeerProjectBootstrap.cleanupLocal(
                    plan: placement.plan,
                    instanceTag: instanceTag
                )
            }
            if !reclaimed {
                let host = hostDisplayName(placement.hostKey)
                stranded.append(host)
                RemoteWorkLog.info(
                    "Could not undo the prepared checkouts on \(host); "
                        + "a retry will reuse them (\(instanceTag))."
                )
            }
        }
        guard stranded.isEmpty else {
            progress(.failed(
                id: stepID,
                message: "Left in place on \(stranded.joined(separator: ", ")) — "
                    + "creating this project again will reuse them."
            ))
            return false
        }
        progress(.completed(id: stepID, detail: "\(undoable.count) machine(s) reclaimed"))
        return true
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
        // Nothing is created until every placement is known to be preparable.
        // A machine that cannot be given the project at all is a form mistake,
        // and finding it after two hosts are already set up means undoing them.
        for placement in placements where PeerProjectBootstrap.requiresRepositoryURL(
            placement: placement, sourceKind: source.kind, gitURL: gitURL
        ) {
            throw CreationError.repositoryURLRequired(
                host: hostDisplayName(placement.hostKey),
                sourceHost: hostDisplayName(source.hostKey)
            )
        }

        // One tag for the whole transaction, and the same one for every retry
        // of it: minting a fresh tag per attempt named a new set of checkouts
        // each time while the previous set stayed on disk. Cleared once the
        // creation succeeds, so a later re-creation of the same project never
        // adopts this run's leftovers.
        let transactionKey = PeerProjectBootstrap.transactionKey(
            name: name, sourcePath: source.projectPath
        )
        let instanceTag = PeerProjectBootstrap.instanceTag(forTransaction: transactionKey)

        // What each finished placement would take to undo, in the order it was
        // done. A placement's own script rolls back the step that failed; this
        // is for the ones that already succeeded when a later machine fails.
        var completed: [CompletedPlacement] = []

        do {
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
                          host.isLaunchable,
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
                    completed.append(CompletedPlacement(
                        hostKey: hostKey,
                        sshTarget: sshTarget,
                        port: host.sshPort,
                        identityFile: host.identityFile,
                        environment: PeerHostEnvironment.stored(forHostKey: hostKey),
                        plan: plan
                    ))
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
                    completed.append(CompletedPlacement(
                        hostKey: nil,
                        sshTarget: nil,
                        port: nil,
                        identityFile: nil,
                        environment: [:],
                        plan: plan
                    ))
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
        } catch {
            // Reverse order, so a machine is only undone after everything set
            // up after it has been. Whether it succeeded decides the tag: a
            // transaction reclaimed in full is over, and one that could not
            // reach a host keeps its tag so the retry resumes those same
            // checkouts instead of naming another set beside them.
            let reclaimed = await rollBack(
                completed,
                instanceTag: instanceTag,
                progress: progress
            )
            if reclaimed {
                PeerProjectBootstrap.finishTransaction(transactionKey)
            }
            throw error
        }

        PeerProjectBootstrap.finishTransaction(transactionKey)
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
