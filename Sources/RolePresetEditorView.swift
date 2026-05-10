import AppKit
import SwiftUI

/// Editor for managing agent role presets — create, edit, delete.
struct RolePresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presetManager = AgentRolePresetManager.shared

    @State private var selectedId: UUID?
    @State private var editingPreset: AgentRolePreset?
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: AgentRolePreset?
    @State private var runbookStatus = AgentRunbookService.shared.status()
    @State private var runbookMessage: String?

    // Models are now CLI-dependent — see AgentRolePreset.models(for:)
    private let colors = ["green", "blue", "yellow", "red", "cyan", "magenta"]

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 160, maxWidth: 200)
            detail
                .frame(minWidth: 320)
        }
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            selectedId = presetManager.presets.first?.id
            refreshRunbookStatus()
        }
        .alert("Delete Preset?", isPresented: $showDeleteConfirm, presenting: deleteTarget) { preset in
            Button("Delete", role: .destructive) {
                presetManager.delete(preset)
                if selectedId == preset.id {
                    selectedId = presetManager.presets.first?.id
                }
                editingPreset = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            Text("Delete \"\(preset.displayName)\"? This cannot be undone.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedId) {
                Section("Built-in") {
                    ForEach(presetManager.presets.filter(\.isBuiltIn)) { preset in
                        sidebarRow(preset)
                    }
                }
                Section("Custom") {
                    ForEach(presetManager.presets.filter { !$0.isBuiltIn }) { preset in
                        sidebarRow(preset)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button(action: addNewPreset) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add custom preset")

                Spacer()

                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(8)
        }
    }

    private func sidebarRow(_ preset: AgentRolePreset) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(colorForName(preset.color))
                .frame(width: 8, height: 8)
            Text(preset.displayName)
                .font(.subheadline)
            Spacer()
            if preset.isBuiltIn {
                Text("built-in")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(preset.id)
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let selected = presetManager.presets.first(where: { $0.id == selectedId }) {
                presetDetail(selected)
            } else {
                VStack {
                    Spacer()
                    Text("Select a preset")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func presetDetail(_ preset: AgentRolePreset) -> some View {
        let binding = Binding<AgentRolePreset>(
            get: {
                editingPreset?.id == preset.id ? editingPreset! : preset
            },
            set: { newValue in
                editingPreset = newValue
            }
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Role Preset")
                        .font(.headline)
                    Spacer()
                    if !preset.isBuiltIn {
                        Button(role: .destructive, action: {
                            deleteTarget = preset
                            showDeleteConfirm = true
                        }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                LabeledContent("Name") {
                    TextField("name", text: binding.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }

                LabeledContent("Display Name") {
                    TextField("display name", text: binding.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }

                HStack {
                    LabeledContent("CLI") {
                        Picker("", selection: binding.cli) {
                            ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                                Text(cli).tag(cli)
                            }
                        }
                        .frame(width: 90)
                    }

                    LabeledContent("Model") {
                        Picker("", selection: binding.model) {
                            ForEach(AgentRolePreset.models(for: binding.cli.wrappedValue), id: \.self) { m in
                                Text(AgentRolePreset.modelDisplayLabel(m, for: binding.cli.wrappedValue)).tag(m)
                            }
                        }
                        .frame(width: 140)
                    }

                    LabeledContent("Color") {
                        Picker("", selection: binding.color) {
                            ForEach(colors, id: \.self) { c in
                                HStack {
                                    Circle()
                                        .fill(colorForName(c))
                                        .frame(width: 8, height: 8)
                                    Text(c)
                                }
                                .tag(c)
                            }
                        }
                        .frame(width: 110)
                    }
                }

                runbookPanel(for: binding.wrappedValue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions")
                        .font(.subheadline.bold())
                    TextEditor(text: binding.instructions)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }

                if editingPreset != nil {
                    HStack {
                        Spacer()
                        Button("Revert") {
                            editingPreset = nil
                        }
                        .buttonStyle(.bordered)
                        Button("Save") {
                            if let edited = editingPreset {
                                presetManager.update(edited)
                                editingPreset = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(16)
        }
        .onChange(of: selectedId) { _ in
            editingPreset = nil
        }
    }

    // MARK: - Actions

    private func runbookPanel(for preset: AgentRolePreset) -> some View {
        let roleStatus = runbookStatus.role(preset.name)
        let state = roleStatus?.sourceState ?? .missing
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Runbook")
                    .font(.subheadline.bold())
                runbookBadge(state)
                Spacer()
                Button {
                    createRunbook(from: preset)
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state != .missing)

                Button {
                    openRunbook(for: preset)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open runbook folder")
            }

            Text(roleStatus?.sourcePath ?? "No project root found")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let runbookMessage {
                Text(runbookMessage)
                    .font(.caption)
                    .foregroundStyle(runbookMessage.contains("skipped") ? Color.orange : Color.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    private func runbookBadge(_ state: AgentRunbookFileState) -> some View {
        Text(state.displayName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(runbookColor(state))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(runbookColor(state).opacity(0.12)))
    }

    private func runbookColor(_ state: AgentRunbookFileState) -> Color {
        switch state {
        case .managed: return .green
        case .outdated: return .blue
        case .custom: return .orange
        case .missing: return .secondary
        }
    }

    private func refreshRunbookStatus() {
        runbookStatus = AgentRunbookService.shared.status()
    }

    private func createRunbook(from preset: AgentRolePreset) {
        let result = AgentRunbookService.shared.writeRunbookFromPreset(preset)
        runbookMessage = result.state == "written" ? "Runbook created." : result.message
        refreshRunbookStatus()
    }

    private func openRunbook(for preset: AgentRolePreset) {
        AgentRunbookService.shared.openRunbookFolder()
        if let path = runbookStatus.role(preset.name)?.sourcePath,
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    private func addNewPreset() {
        let preset = AgentRolePreset(
            name: "custom-\(presetManager.presets.count + 1)",
            displayName: "Custom Agent",
            model: "sonnet",
            color: "green",
            instructions: "Describe this agent's role and responsibilities...",
            isBuiltIn: false
        )
        presetManager.add(preset)
        selectedId = preset.id
    }

    private func colorForName(_ name: String) -> Color {
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
