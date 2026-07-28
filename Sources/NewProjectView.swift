import SwiftUI

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
        _ leader: ProjectLeader
    ) async throws -> Void
    let onClose: () -> Void

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
    /// The machine this project lives on.
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
    @State private var showsCustomPath = false
    @State private var showsCustomPlacement = false
    /// Sample tag for the checkout-name hint; the real one is minted at
    /// creation time in `ProjectCreationFlow.prepareCheckouts`.
    @State private var previewInstanceTag = PeerProjectBootstrap.makeInstanceTag()
    @FocusState private var focusedField: Field?

    private enum Field {
        case repositoryURL
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
    @State private var leaderModel = AgentRolePreset.defaultModel(for: "claude")
    @State private var selectedTeamPresetId: TemplateID?
    @State private var appliedTeamSignature: TeamSignature?
    @State private var showingSavePreset = false
    @State private var showingManagePresets = false
    @State private var savePresetName = ""
    @State private var presetError: String?
    @State private var isCreating = false
    @State private var creationError: String?
    /// Where the leader runs: following this project's Default machine, or
    /// somewhere the user pointed it on purpose.
    ///
    /// Modeled as inheritance rather than a copied host key so "still
    /// following the default" and "coincidentally on the same machine" can
    /// never be confused with each other — the earlier design copied
    /// `runsOnHostKey` into a second field and the two silently drifted
    /// apart the moment either one changed alone.
    @State private var leaderPlacement: HostPlacement = .inherited

    /// A place something in this form runs: the project's Default machine,
    /// or an explicit override of it (`nil` inside `.explicit` means "This
    /// Mac", stated on purpose rather than left blank).
    enum HostPlacement: Hashable {
        case inherited
        case explicit(String?)
    }

    /// The leader's effective host, resolving `leaderPlacement` against the
    /// current Default machine. Read-only: set `leaderPlacement`, not this.
    private var leaderHostKey: String? {
        switch leaderPlacement {
        case .inherited: return runsOnHostKey
        case .explicit(let hostKey): return hostKey
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectFields
                    Divider()
                    teamPresetRow
                    leaderRow
                    TeamAgentComposer(
                        agents: $agents,
                        workingDirectory: trimmedDirectory,
                        onComposionChanged: {},
                        defaultModel: AgentRolePreset.defaultModel(for: "claude"),
                        supportsDefaultPlacement: true,
                        defaultHostKey: runsOnHostKey,
                        defaultHostDirectory: trimmedDirectory,
                        inheritedAgentIDs: inheritedAgentIDs,
                        showsPlacementControls: true,
                        onAgentPlacementChanged: { id, inheritsDefault in
                            if inheritsDefault {
                                inheritedAgentIDs.insert(id)
                            } else {
                                inheritedAgentIDs.remove(id)
                            }
                        }
                    )
                }
                .padding(20)
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
                        Button("Save as…") {
                            savePresetName = suggestedPresetName
                            showingSavePreset = true
                        }
                    }

                    Button {
                        toggleSelectedPresetPin()
                    } label: {
                        Image(systemName: selectedPresetIsPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedTeamPresetId == nil)
                    .help(selectedPresetIsPinned ? "Unpin this preset" : "Use this preset by default")

                    Button("Manage…") {
                        showingManagePresets = true
                    }
                    .buttonStyle(.borderless)
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
        if isTeamCustomized { return "Customized" }
        guard let selectedTeamPresetId else { return "Default · 1 Executor" }
        return teamTemplateManager.template(for: selectedTeamPresetId)?.name ?? "Customized"
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

    /// A single row: who leads, and where — folded together because showing
    /// this next to `Runs on` / `Agent = jw-server` as three separate answers
    /// read as three different opinions about where the project lives, when
    /// they were meant to be the same one until someone said otherwise.
    private var leaderRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Leader")
                    .font(.subheadline.bold())
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { leaderCli },
                        set: { newCli in
                            let old = leaderCli
                            leaderCli = newCli
                            if AgentRolePreset.models(for: old) != AgentRolePreset.models(for: newCli) {
                                leaderModel = AgentRolePreset.defaultModel(for: newCli)
                            }
                        }
                    )) {
                        ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                            Text(cli.capitalized).tag(cli)
                        }
                        Text("REPL (manual)").tag("repl")
                    }
                    .labelsHidden()
                    .fixedSize()

                    if leaderCli != "repl" {
                        Picker("", selection: Binding(
                            get: {
                                let options = AgentRolePreset.models(for: leaderCli)
                                let normalized = AgentRolePreset.normalizeModel(leaderModel, for: leaderCli)
                                guard options.contains(normalized) else {
                                    let fallback = AgentRolePreset.defaultModel(for: leaderCli)
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
                            ForEach(AgentRolePreset.models(for: leaderCli), id: \.self) { m in
                                Text(AgentRolePreset.modelDisplayLabel(m, for: leaderCli)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Text("a console you drive by hand — no model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if showsCustomPlacement {
                        Divider().frame(height: 16)

                        Picker("", selection: $leaderPlacement) {
                            Text(defaultPlacementLabel).tag(HostPlacement.inherited)
                            Text("This Mac").tag(HostPlacement.explicit(nil))
                            ForEach(selectablePeers, id: \.id) { host in
                                Text(host.isConnected ? host.displayName : "\(host.displayName) — offline")
                                    .tag(HostPlacement.explicit(host.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .accessibilityIdentifier("newProject.leaderHost")
                        .onChange(of: leaderPlacement) { _, placement in
                            guard case .explicit(let hostKey?) = placement,
                                  let host = selectablePeers.first(where: { $0.id == hostKey }),
                                  !host.isConnected else { return }
                            hostStore.connectSavedHost(host)
                        }
                        if let leaderHostKey,
                           let host = selectablePeers.first(where: { $0.id == leaderHostKey }),
                           !host.isConnected {
                            Label("connecting…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(defaultPlacementLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                    GridRow {
                        Text("Repository URL")
                        TextField("git@github.com:org/repo.git", text: $gitURL)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .repositoryURL)
                    }
                }

                GridRow {
                    Text("Name")
                    TextField("project-name", text: Binding(
                        get: { name },
                        set: { name = $0; nameEdited = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                }

                GridRow {
                    Text("Project machine")
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

                if sourceKind == .existingFolder || showsCustomPath {
                    GridRow {
                        Text(sourceKind == .existingFolder ? "Folder" : "Destination")
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
                            Text(trimmedDirectory.isEmpty ? "Choose a project machine and name" : trimmedDirectory)
                                .foregroundStyle(trimmedDirectory.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Customize…") {
                                showsCustomPath = true
                                focusedField = .directory
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                GridRow {
                    Text("Agent checkouts")
                    HStack(spacing: 8) {
                        Text(checkoutDescription)
                        if sourceKind == .existingFolder && gitURL.isEmpty {
                            Text("Git not detected; agents share this folder")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if isolateAgents {
                            Text(isolationHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button {
                showsCustomPlacement.toggle()
            } label: {
                Label(
                    showsCustomPlacement ? "Hide leader placement" : "Customize leader placement",
                    systemImage: showsCustomPlacement ? "chevron.down" : "chevron.right"
                )
                .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .onChange(of: gitURL) { _, value in
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
            showsCustomPath = kind == .existingFolder
            if kind == .empty {
                gitURL = ""
                name = ""
                focusedField = .name
            } else if kind == .clone {
                focusedField = .repositoryURL
            } else {
                gitURL = ""
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

    private var checkoutDescription: String {
        if sourceKind == .existingFolder && gitURL.isEmpty {
            return "Shared folder"
        }
        return isolateAgents ? "Git worktree per agent" : "Shared primary checkout"
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
        for i in agents.indices where inheritedAgentIDs.contains(agents[i].id) {
            agents[i].hostDirectory = runsOnHostKey == nil ? "" : directory
        }
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

    private var defaultPlacementLabel: String {
        guard let runsOnHostKey,
              let host = selectablePeers.first(where: { $0.id == runsOnHostKey }) else {
            return "Default · This Mac"
        }
        return "Default · \(host.displayName)"
    }

    /// What the isolation choice will actually produce, named.
    private var isolationHint: String {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: trimmedDirectory.isEmpty ? "…" : parentOf(trimmedDirectory),
            projectName: effectiveName.isEmpty ? "project" : effectiveName,
            agents: agents.map(\.preset.name),
            isolateAgents: true,
            // Illustrative only — creation mints its own tag. Stable across
            // body evaluations so the hint doesn't shimmer while typing.
            instanceTag: previewInstanceTag
        )
        guard let first = plan.agentCheckouts.first else { return "" }
        return "\(URL(fileURLWithPath: first.path).lastPathComponent) on \(first.branch)"
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
            agents[i].hostKey = runsOnHostKey
            agents[i].hostDirectory = runsOnHostKey == nil ? "" : trimmedDirectory
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
            for i in agents.indices where inheritedAgentIDs.contains(agents[i].id) {
                agents[i].hostKey = nil
                agents[i].hostDirectory = ""
            }
            directory = ""
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
        for i in agents.indices where inheritedAgentIDs.contains(agents[i].id) {
            agents[i].hostKey = hostKey
            agents[i].hostDirectory = directory
        }
    }

    private var footer: some View {
        HStack {
            Text(creationError ?? creationSummary)
                .font(.caption)
                .foregroundStyle(creationError == nil ? Color.secondary : Color.red)
                .lineLimit(creationError == nil ? 1 : 2)
                .fixedSize(horizontal: false, vertical: creationError != nil)
                .layoutPriority(1)
                .help(creationError ?? creationSummary)
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            Button("Create Project") {
                // A project living on another machine still needs somewhere
                // here for its window to open. The remote path is not that
                // place — nothing local would be able to enter it — so the
                // panes start at home and the members carry the real one.
                let localDirectory = runsOnHostKey == nil
                    ? trimmedDirectory
                    : FileManager.default.homeDirectoryForCurrentUser.path
                isCreating = true
                creationError = nil
                Task { @MainActor in
                    do {
                        if runsOnHostKey == nil {
                            let primaryOnly = PeerProjectBootstrap.plan(
                                projectRoot: parentOf(trimmedDirectory),
                                projectName: effectiveName,
                                agents: [],
                                isolateAgents: false
                            )
                            try await PeerProjectBootstrap.runLocal(
                                plan: primaryOnly,
                                gitURL: {
                                    let value = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                    return value.isEmpty ? nil : value
                                }(),
                                sourceKind: sourceKind,
                                memMeshProjectID: PeerProjectBootstrap.memMeshProjectID(
                                    for: effectiveName
                                )
                            )
                        }
                        try await onCreate(
                            effectiveName,
                            localDirectory,
                            agents,
                            ProjectSource(
                                hostKey: runsOnHostKey,
                                projectPath: trimmedDirectory,
                                gitURL: gitURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                isolateAgents: effectiveIsolation,
                                kind: sourceKind
                            ),
                            ProjectLeader(
                                mode: leaderCli,
                                model: leaderModel,
                                endpoint: leaderHostKey.map { .peer(hostKey: $0) } ?? .local
                            )
                        )
                        onClose()
                    } catch {
                        creationError = error.localizedDescription
                        isCreating = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                isCreating || !canCreate
                    || !placementHostsAreReady
            )
            .overlay {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var effectiveIsolation: Bool {
        isolateAgents && !(sourceKind == .existingFolder && gitURL.isEmpty)
    }

    private var canCreate: Bool {
        guard !trimmedDirectory.isEmpty, !effectiveName.isEmpty else { return false }
        if sourceKind == .clone {
            return !gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var creationSummary: String {
        let action: String
        switch sourceKind {
        case .clone: action = "Clone \(gitURL.isEmpty ? "repository" : gitURL)"
        case .existingFolder: action = "Use existing folder"
        case .empty: action = "Create empty Git project"
        }
        let machine = runsOnHostKey.flatMap { hostKey in
            selectablePeers.first(where: { $0.id == hostKey })?.displayName
        } ?? "This Mac"
        let checkout = effectiveIsolation
            ? "\(agents.count) agent worktree\(agents.count == 1 ? "" : "s")"
            : "shared checkout"
        return "\(action) → \(trimmedDirectory) on \(machine) · \(checkout) · \(agentPlacementSummary)"
    }

    private var agentPlacementSummary: String {
        let labels = agents.map { row -> String in
            guard let hostKey = row.hostKey else { return "This Mac" }
            return selectablePeers.first(where: { $0.id == hostKey })?.displayName ?? hostKey
        }
        let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        let ordered = counts.keys.sorted().map { "\($0) ×\(counts[$0] ?? 0)" }
        return "agents: " + ordered.joined(separator: ", ")
    }

    private var placementHostsAreReady: Bool {
        let remoteKeys = Set(
            [runsOnHostKey, leaderHostKey].compactMap { $0 }
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
        leaderModel = AgentRolePreset.defaultModel(for: "claude")
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
            let candidate = preset.leaderModel ?? AgentRolePreset.defaultModel(for: leaderCli)
            leaderModel = AgentRolePreset.models(for: leaderCli).contains(candidate)
                ? candidate
                : AgentRolePreset.defaultModel(for: leaderCli)
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
            resolved.hostKey = runsOnHostKey
            resolved.hostDirectory = runsOnHostKey == nil ? "" : trimmedDirectory
            return resolved
        }
        let ids = Set(agents.map(\.id))
        inheritedAgentIDs = ids
        knownAgentIDs = ids
    }

    private func saveCurrentTeamPreset() {
        let name = savePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preferences = agents.map { row in
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
        let id = teamTemplateManager.createSmartPreset(
            name: name,
            leaderMode: leaderCli,
            leaderModel: leaderCli == "repl" ? nil : leaderModel,
            agents: preferences
        )
        selectedTeamPresetId = id
        appliedTeamSignature = currentTeamSignature
        showingSavePreset = false
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
            leaderHostKey: leader.endpoint.hostKey
        )
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
            throw CreationError.teamCreationFailed
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
        leaderHostKey: String?
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
        // One name for every copy. Each placement's directory is the host's own
        // convention — deriving the id from it would give the same project a
        // different mem-mesh identity on each machine.
        let memMeshProjectID = PeerProjectBootstrap.memMeshProjectID(for: name)
        // One tag for the whole transaction: retrying a failed placement
        // reuses the same paths (idempotent), while a later re-creation of
        // the same project never adopts this run's leftovers.
        let instanceTag = PeerProjectBootstrap.makeInstanceTag()

        for placement in placements {
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
                        sourceKind: kind,
                        memMeshProjectID: memMeshProjectID
                    )
                } catch {
                    let detail = PeerProjectBootstrap.remoteFailureDescription(
                        error,
                        gitURL: gitURL.isEmpty ? nil : gitURL
                    )
                    RemoteWorkLog.info(
                        "Could not prepare \(name) on \(host.displayName): \(detail)"
                    )
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
                try await PeerProjectBootstrap.runLocal(
                    plan: primaryOnly,
                    gitURL: gitURL.isEmpty ? nil : gitURL,
                    sourceKind: kind,
                    memMeshProjectID: memMeshProjectID
                )
                localProjectPath = plan.primaryPath
            }

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
}
