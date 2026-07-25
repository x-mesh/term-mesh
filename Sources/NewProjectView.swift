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
    let onCreate: (_ name: String, _ directory: String, _ rows: [TeamAgentRow]) -> Void
    let onClose: () -> Void

    @State private var directory: String = ""
    @State private var name: String = ""
    @State private var nameEdited = false
    @State private var agents: [TeamAgentRow] = []
    /// Where the team runs. Only this machine for now: putting a team on a
    /// peer means asking that peer to start processes, which its allow-list
    /// refuses on purpose. The choice is shown rather than hidden so the
    /// answer to "can the leader live on the always-on box" is visible, and
    /// visibly not yet.
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
                Text("Folder")
                HStack(spacing: 6) {
                    TextField("~/work/project", text: $directory)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseFolder)
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
            GridRow {
                Text("Runs on")
                HStack(spacing: 8) {
                    Picker("", selection: $runsOnHostKey) {
                        Text("This Mac").tag(String?.none)
                        ForEach(hostStore.sortedHosts.filter(\.isConnected), id: \.id) { host in
                            Text(host.displayName).tag(String?.some(host.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(true)
                    Text("individual agents can still run elsewhere")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: directory) { _, newValue in
            guard !nameEdited else { return }
            name = URL(fileURLWithPath: newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                .lastPathComponent
        }
    }

    private var footer: some View {
        HStack {
            Text("The team is created in this folder alongside the project.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Create") {
                onCreate(effectiveName, trimmedDirectory, agents)
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
