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
    ) -> Void
    let onClose: () -> Void

    @State private var directory: String = ""
    @State private var name: String = ""
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
                selectedId: $selectedTeamPresetId
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
        guard let appliedTeamSignature else { return false }
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

                    Divider().frame(height: 16)

                    Picker("", selection: $leaderPlacement) {
                        Text(defaultPlacementLabel).tag(HostPlacement.inherited)
                        Text("This Mac").tag(HostPlacement.explicit(nil))
                        ForEach(connectedPeers, id: \.id) { host in
                            Text(host.displayName).tag(HostPlacement.explicit(host.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityIdentifier("newProject.leaderHost")
                }
            }
        }
    }

    private var projectFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Default machine")
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
                    if selectablePeers.isEmpty {
                        Text("add a peer in Settings to run a project elsewhere")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let runsOnHostKey,
                              let host = selectablePeers.first(where: { $0.id == runsOnHostKey }),
                              !host.isConnected {
                        Label("connecting…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text(runsOnHostKey == nil ? "Folder" : "Folder on that machine")
                HStack(spacing: 6) {
                    TextField(
                        folderPlaceholder,
                        text: Binding(
                            get: { directory },
                            set: { directory = $0; folderEdited = true }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    // No panel for a remote path: this Mac cannot browse that
                    // machine's disk, and a picker that quietly shows the
                    // wrong filesystem is worse than none.
                    if runsOnHostKey == nil {
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            GridRow {
                Text("Clone from")
                TextField("git@github.com:org/repo.git — optional", text: $gitURL)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Isolation")
                HStack(spacing: 8) {
                    Picker("", selection: $isolateAgents) {
                        Text("Each agent gets its own checkout").tag(true)
                        Text("All agents share one").tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 260)
                    if isolateAgents {
                        Text(isolationHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text("Name")
                // Follows the folder until someone disagrees with it, then
                // stops following — a field that keeps overwriting what you
                // typed is worse than one that never guessed.
                TextField(
                    URL(fileURLWithPath: trimmedDirectory).lastPathComponent,
                    text: Binding(
                        get: { name },
                        set: { name = $0; nameEdited = true }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }
        }
        .onChange(of: directory) { _, newValue in
            guard !nameEdited else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let leaf = trimmed.isEmpty ? "" : URL(fileURLWithPath: trimmed).lastPathComponent
            name = leaf == Self.placeholderProjectName ? "" : leaf
        }
        .onChange(of: name) { _, newName in
            // Typing the name moves the folder with it, so `<root>/<name>` stays
            // true without anyone having to edit the path by hand. Stops the
            // moment the folder is edited directly — at that point the person
            // has said where it goes and the name is not entitled to argue.
            guard !folderEdited, !directory.isEmpty else { return }
            let typed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = (directory as NSString).deletingLastPathComponent
            guard !parent.isEmpty else { return }
            directory = (parent as NSString)
                .appendingPathComponent(typed.isEmpty ? Self.placeholderProjectName : typed)
            for i in agents.indices where inheritedAgentIDs.contains(agents[i].id) {
                agents[i].hostDirectory = directory
            }
        }
        .onChange(of: runsOnHostKey) { _, newHost in
            applyRunsOn(newHost)
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

    /// A remote leader is a live control endpoint, not a future SSH wish.
    /// Unlike the project location picker, this list intentionally excludes
    /// offline peers: selecting one must not create a local leader while the
    /// UI says it is remote.
    private var connectedPeers: [HostEntry] {
        selectablePeers.filter(\.isConnected)
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
            isolateAgents: true
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
            Text(
                runsOnHostKey == nil
                    ? "The team is created in this folder alongside the project."
                    : "The agents work on that machine; their panes open here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Create") {
                // A project living on another machine still needs somewhere
                // here for its window to open. The remote path is not that
                // place — nothing local would be able to enter it — so the
                // panes start at home and the members carry the real one.
                let localDirectory = runsOnHostKey == nil
                    ? trimmedDirectory
                    : FileManager.default.homeDirectoryForCurrentUser.path
                onCreate(
                    effectiveName,
                    localDirectory,
                    agents,
                    ProjectSource(
                        hostKey: runsOnHostKey,
                        projectPath: trimmedDirectory,
                        gitURL: gitURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        isolateAgents: isolateAgents
                    ),
                    ProjectLeader(
                        mode: leaderCli,
                        model: leaderModel,
                        endpoint: leaderHostKey.map { .peer(hostKey: $0) } ?? .local
                    )
                )
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedDirectory.isEmpty || effectiveName.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func applyInitialTeamPreset() {
        guard agents.isEmpty else { return }
        if let pinnedId = teamTemplateManager.pinnedId,
           pinnedId.category == .smart,
           let template = teamTemplateManager.template(for: pinnedId) {
            applyTemplate(template)
        } else {
            applyDefaultTeam()
        }
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

        let rows = preset.resolve(with: providerDetector).compactMap { resolved -> TeamAgentRow? in
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
    }
}

private struct TeamPresetManagerSheet: View {
    @ObservedObject var manager: TeamTemplateManager
    @Binding var selectedId: TemplateID?
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
                            if selectedId == template.id { selectedId = nil }
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
                    .onSubmit { onRename(name) }
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
    }
}
