import SwiftUI

/// Start a project with the people who will work on it.
///
/// Opening a folder used to be the whole of it, and what came back was inert:
/// a workspace with nobody in it, every action that matters greyed out until
/// a team was made somewhere else. Delegating work, adding an agent on another
/// machine — both disabled, and nothing on screen saying "make a team first".
///
/// So the team is chosen here, where the project is. Asking for the folder,
/// the repository, the roles, the provider and the model every time would be a
/// tax on a decision that is the same nearly every time, which is what the
/// saved templates already exist to answer: one line by default, opened up
/// only when this project is the exception.
struct SidebarNewProjectSheet: View {
    let onCreate: (_ directory: String, _ template: SavedTeamTemplate?) -> Void
    let onClose: () -> Void

    @ObservedObject private var templates = SavedTeamTemplateManager.shared
    @State private var directory: String = ""
    @State private var templateID: UUID?
    @State private var isExpanded = false

    private var chosenTemplate: SavedTeamTemplate? {
        templates.templates.first { $0.id == templateID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 5) {
                Text("Folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    TextField("~/work/project", text: $directory)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseFolder)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Team")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Picker("", selection: $templateID) {
                    // A project with nobody in it is still a legitimate thing
                    // to want — it is just no longer the only thing on offer.
                    Text("Just the folder").tag(UUID?.none)
                    ForEach(templates.templates) { template in
                        Text(describe(template)).tag(UUID?.some(template.id))
                    }
                }
                .labelsHidden()
            }

            if let chosenTemplate {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(chosenTemplate.agents.enumerated()), id: \.offset) { _, slot in
                            HStack(spacing: 6) {
                                Text(slot.roleName)
                                    .font(.system(size: 11, weight: .medium))
                                Text("\(slot.cli) · \(slot.model)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Who that is")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Templates are edited in Team settings.")
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(0.8))
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(directory.trimmingCharacters(in: .whitespacesAndNewlines), chosenTemplate)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            // The first template is the default because a default is the point;
            // "Just the folder" is one selection away for anyone who wants the
            // old behaviour.
            if templateID == nil { templateID = templates.templates.first?.id }
        }
        .accessibilityIdentifier("sidebar.projects.new")
    }

    private func describe(_ template: SavedTeamTemplate) -> String {
        guard let first = template.agents.first else { return template.name }
        let rest = template.agents.count - 1
        let tail = rest > 0 ? " +\(rest)" : ""
        return "\(template.name) · \(first.roleName) (\(first.cli)/\(first.model))\(tail)"
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
