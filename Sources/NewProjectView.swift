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
    let onCreate: (_ name: String, _ localDirectory: String, _ rows: [TeamAgentRow]) -> Void
    let onClose: () -> Void

    @State private var directory: String = ""
    @State private var name: String = ""
    @State private var nameEdited = false
    @State private var agents: [TeamAgentRow] = []
    /// The machine this project lives on.
    ///
    /// Asked first because everything after it depends on the answer. A folder
    /// on this Mac is chosen with a file panel; a folder on another machine is
    /// a path typed against that machine's own conventions, and no panel here
    /// can browse it. Getting this backwards meant offering a local picker for
    /// a directory that was never going to be local.
    @State private var runsOnHostKey: String?

    @ObservedObject private var presetManager = AgentRolePresetManager.shared
    @ObservedObject private var hostStore = RemoteHostStore.shared

    private var trimmedDirectory: String {
        directory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
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
                    TeamAgentComposer(
                        agents: $agents,
                        workingDirectory: trimmedDirectory,
                        defaultModel: AgentRolePreset.defaultModel(for: "claude")
                    )
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 620)
        .onAppear(perform: seedFirstAgent)
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

    private var projectFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Runs on")
                HStack(spacing: 8) {
                    Picker("", selection: $runsOnHostKey) {
                        Text("This Mac").tag(String?.none)
                        ForEach(connectedPeers, id: \.id) { host in
                            Text(host.displayName).tag(String?.some(host.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    if connectedPeers.isEmpty {
                        Text("connect a peer to run a project elsewhere")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text(runsOnHostKey == nil ? "Folder" : "Folder on that machine")
                HStack(spacing: 6) {
                    TextField(folderPlaceholder, text: $directory)
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
            name = URL(fileURLWithPath: newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                .lastPathComponent
        }
        .onChange(of: runsOnHostKey) { _, newHost in
            applyRunsOn(newHost)
        }
    }

    private var connectedPeers: [HostEntry] {
        hostStore.sortedHosts.filter(\.isConnected)
    }

    private var folderPlaceholder: String {
        guard let runsOnHostKey,
              let profile = PeerHostProfileStore.shared.profiles
                .first(where: { $0.stableKey == runsOnHostKey }),
              let root = profile.projectRootPath, !root.isEmpty
        else { return runsOnHostKey == nil ? "~/work/project" : "/path/on/that/machine" }
        return (root as NSString).appendingPathComponent("project")
    }

    /// Move the whole form to the chosen machine.
    ///
    /// The folder starts from that machine's own convention rather than being
    /// cleared: a path someone can correct beats an empty field they have to
    /// go and look up. The agents follow, because a project running over there
    /// with its members here is not what anyone picked this for — and each row
    /// can still be moved back individually.
    private func applyRunsOn(_ hostKey: String?) {
        guard let hostKey else {
            for i in agents.indices {
                agents[i].hostKey = nil
                agents[i].hostDirectory = ""
            }
            directory = ""
            return
        }
        let leaf = effectiveName.isEmpty ? "project" : effectiveName
        let predicted = PeerHostProfileStore.shared.profiles
            .first { $0.stableKey == hostKey }?
            .predictedProjectPath(forProjectNamed: leaf)
        directory = predicted ?? RemoteProjectPaths.shared.anyPath(host: hostKey) ?? ""
        for i in agents.indices {
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
                onCreate(effectiveName, localDirectory, agents)
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedDirectory.isEmpty || effectiveName.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// One agent to begin with. An empty list would make Create produce the
    /// inert workspace this screen exists to stop producing, and the row is
    /// removable for anyone who genuinely wants the folder alone.
    private func seedFirstAgent() {
        guard agents.isEmpty, let preset = presetManager.presets.first(where: { $0.name == "executor" })
            ?? presetManager.presets.first else { return }
        agents = [TeamAgentRow(preset: preset, customInstructions: "")]
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
