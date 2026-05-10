import SwiftUI

struct AgentRunbookSettingsView: View {
    @State private var status: AgentRunbookStatus?
    @State private var workingDirectory = AgentRunbookService.shared.currentWorkingDirectory()
    @State private var isRunning = false
    @State private var commandMessage: String?
    @State private var showForceRepairConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryCard
            healthCard
            roleStatusCard
            SettingsCardNote("Runbooks are loaded from .agent-runbooks/<role>.md. Claude, Codex, and OpenCode files are generated projections.")
        }
        .onAppear {
            refreshStatus()
        }
        .confirmationDialog(
            "Force repair runbook projections?",
            isPresented: $showForceRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Force Repair", role: .destructive) {
                runCommand(["install", "--tool", "all", "--force"], label: "Force repair")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can overwrite custom runbook projection files.")
        }
    }

    private var summaryCard: some View {
        SettingsCard {
            SettingsCardRow(
                "Repository",
                subtitle: status?.projectRoot ?? workingDirectory
            ) {
                HStack(spacing: 8) {
                    if let status {
                        Text("\(status.managedSourceCount + status.customSourceCount)/\(status.roles.count)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        refreshStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunning)
                    .help("Refresh runbook status")
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                "Sources",
                subtitle: sourceSummary
            ) {
                HStack(spacing: 8) {
                    Button {
                        runCommand(["init"], label: "Initialize sources")
                    } label: {
                        Label("Init", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunning)

                    Button {
                        AgentRunbookService.shared.openRunbookFolder(workingDirectory: workingDirectory)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open runbook folder")
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                "Tool Projections",
                subtitle: projectionSummary
            ) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Claude") {
                            runCommand(["install", "--tool", "claude"], label: "Install Claude")
                        }
                        Button("Codex") {
                            runCommand(["install", "--tool", "codex"], label: "Install Codex")
                        }
                        Button("OpenCode") {
                            runCommand(["install", "--tool", "opencode"], label: "Install OpenCode")
                        }
                    } label: {
                        Label("Install", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunning)

                    Button {
                        runCommand(["install", "--tool", "all"], label: "Install all")
                    } label: {
                        Label("All", systemImage: "square.stack.3d.down.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunning)

                    Button {
                        showForceRepairConfirmation = true
                    } label: {
                        Image(systemName: "wrench.adjustable")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunning)
                    .help("Force repair projections")
                }
            }

            if let commandMessage {
                SettingsCardDivider()
                Text(commandMessage)
                    .font(.caption)
                    .foregroundStyle(commandMessage.contains("failed") ? Color.red : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var healthCard: some View {
        SettingsCard {
            SettingsCardRow(
                "Projection Drift",
                subtitle: driftSummary
            ) {
                Button {
                    runCommand(["install", "--tool", "all"], label: "Update projections")
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunning || (status?.outdatedProjectionCount ?? 0) == 0)
                .help("Regenerate managed projections from .agent-runbooks")
            }

            SettingsCardDivider()

            SettingsCardRow(
                "Runbook Lint",
                subtitle: lintSummary
            ) {
                if let status, status.lintIssueCount > 0 {
                    Text("\(status.lintIssueCount)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .help("No runbook lint issues")
                }
            }
        }
    }

    private var roleStatusCard: some View {
        SettingsCard {
            if let status {
                ForEach(Array(status.roles.enumerated()), id: \.element.role) { index, roleStatus in
                    if index > 0 {
                        SettingsCardDivider()
                    }
                    SettingsCardRow(
                        roleStatus.role,
                        subtitle: roleStatus.sourcePath
                    ) {
                        HStack(spacing: 8) {
                            stateBadge(roleStatus.sourceState)
                            if !roleStatus.lintIssues.isEmpty {
                                lintBadge(roleStatus.lintIssues.count)
                            }
                            ForEach(AgentRunbookTool.allCases) { tool in
                                if let projection = roleStatus.projection(for: tool) {
                                    compactToolBadge(tool: tool, state: projection.state)
                                }
                            }
                        }
                    }
                }
            } else {
                SettingsCardRow("Runbooks", subtitle: "Status not loaded") {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var sourceSummary: String {
        guard let status else { return "Status not loaded." }
        return "\(status.managedSourceCount) managed, \(status.customSourceCount) custom, \(status.missingSourceCount) missing."
    }

    private var projectionSummary: String {
        guard let status else { return "Status not loaded." }
        let projectionCount = status.roles.flatMap(\.projections).count
        let managed = status.roles.flatMap(\.projections).filter { $0.state == .managed }.count
        let custom = status.roles.flatMap(\.projections).filter { $0.state == .custom }.count
        let outdated = status.outdatedProjectionCount
        return "\(managed)/\(projectionCount) managed, \(custom) custom, \(outdated) outdated."
    }

    private var driftSummary: String {
        guard let status else { return "Status not loaded." }
        if status.outdatedProjectionCount == 0 {
            return "Managed projections match their source runbooks."
        }
        return "\(status.outdatedProjectionCount) managed projections need regeneration."
    }

    private var lintSummary: String {
        guard let status else { return "Status not loaded." }
        if status.lintIssueCount == 0 {
            return "Required sections are present in existing source runbooks."
        }
        return "\(status.lintIssueCount) issues across source runbooks."
    }

    private func refreshStatus() {
        workingDirectory = AgentRunbookService.shared.currentWorkingDirectory()
        status = AgentRunbookService.shared.status(workingDirectory: workingDirectory)
    }

    private func runCommand(_ args: [String], label: String) {
        guard !isRunning else { return }
        isRunning = true
        commandMessage = "\(label) running..."
        let workdir = workingDirectory
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AgentRunbookService.shared.runTMAgentRunbook(arguments: args, workingDirectory: workdir)
            }.value
            commandMessage = result.succeeded
                ? "\(label) complete."
                : "\(label) failed: \(String(result.displayOutput.prefix(240)))"
            isRunning = false
            refreshStatus()
        }
    }

    private func stateBadge(_ state: AgentRunbookFileState) -> some View {
        Text(state.displayName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(stateColor(state))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(stateColor(state).opacity(0.12))
            )
    }

    private func compactToolBadge(tool: AgentRunbookTool, state: AgentRunbookFileState) -> some View {
        Text(String(tool.displayName.prefix(1)))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(stateColor(state))
            .frame(width: 18, height: 18)
            .background(Circle().fill(stateColor(state).opacity(0.12)))
            .help("\(tool.displayName): \(state.displayName)")
    }

    private func lintBadge(_ count: Int) -> some View {
        Label("\(count)", systemImage: "exclamationmark.triangle")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
            .help("\(count) runbook lint issue\(count == 1 ? "" : "s")")
    }

    private func stateColor(_ state: AgentRunbookFileState) -> Color {
        switch state {
        case .managed: return .green
        case .outdated: return .blue
        case .custom: return .orange
        case .missing: return .secondary
        }
    }
}
