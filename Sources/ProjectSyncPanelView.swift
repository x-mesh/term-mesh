import SwiftUI

@MainActor
struct ProjectSyncPanelView: View {
    @StateObject private var viewModel: ProjectSyncViewModel

    init(viewModel: ProjectSyncViewModel? = nil) {
        let resolved = viewModel ?? ProjectSyncViewModel(
            client: ProjectSyncDaemonClient(daemon: TermMeshDaemon.shared)
        )
        _viewModel = StateObject(wrappedValue: resolved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            projectSection
            devicesSection
            operationSection
            conflictAndGCSection
            recoverySection
        }
        .accessibilityIdentifier("projectSync.panel")
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Project")
            SettingsCard {
                SettingsCardRow(verbatim: viewModel.snapshot.projectName, verbatimSubtitle: projectSubtitle) {
                    statusLabel(projectStatusText, systemImage: projectStatusImage, color: projectStatusColor)
                }
                if viewModel.snapshot.projectID == nil {
                    SettingsCardDivider()
                    SettingsCardNote("Project discovery is not exposed by the current daemon. Register a project before starting a manifest scan.")
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Devices")
            SettingsCard {
                if viewModel.snapshot.devices.isEmpty {
                    SettingsCardNote(unavailableText(.devices, fallback: "No approved devices are visible yet."))
                } else {
                    ForEach(Array(viewModel.snapshot.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { SettingsCardDivider() }
                        SettingsCardRow(verbatim: device.name, verbatimSubtitle: deviceSubtitle(device)) {
                            HStack(spacing: 8) {
                                statusLabel(
                                    device.status == .approved ? "Approved" : "Revoked",
                                    systemImage: device.status == .approved ? "checkmark.seal" : "xmark.seal",
                                    color: device.status == .approved ? .green : .secondary
                                )
                                if device.status == .approved {
                                    Button("Revoke…") {
                                        viewModel.reportUnavailable(.deviceRevocation)
                                    }
                                    .disabled(!viewModel.snapshot.capabilities.supports(.deviceRevocation))
                                    .accessibilityLabel("Revoke \(device.name)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var operationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Active Operation")
            SettingsCard {
                if let operation = viewModel.snapshot.activeOperation {
                    SettingsCardRow(verbatim: operationTitle(operation), verbatimSubtitle: operationSubtitle(operation)) {
                        operationActions(operation)
                    }
                } else {
                    SettingsCardRow("No active operation", subtitle: "Manifest scans run without changing app or pane focus.") {
                        Button("Scan Manifest") {
                            Task { await viewModel.startManifestScan() }
                        }
                        .disabled(!viewModel.canStartManifestScan)
                        .accessibilityIdentifier("projectSync.scan")
                    }
                }
                if let error = viewModel.errorMessage {
                    SettingsCardDivider()
                    SettingsCardNote(error)
                        .accessibilityIdentifier("projectSync.error")
                }
            }
        }
    }

    private var conflictAndGCSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Integrity")
            SettingsCard {
                SettingsCardRow(
                    "Conflicts",
                    verbatimSubtitle: viewModel.snapshot.conflicts.isEmpty
                        ? unavailableText(.conflicts, fallback: "No conflicts")
                        : viewModel.snapshot.conflicts.map(\.path).joined(separator: ", ")
                ) {
                    Text("\(viewModel.snapshot.conflicts.count)")
                        .foregroundColor(viewModel.snapshot.conflicts.isEmpty ? .secondary : .orange)
                        .monospacedDigit()
                        .accessibilityLabel("\(viewModel.snapshot.conflicts.count) conflicts")
                }
                SettingsCardDivider()
                SettingsCardRow("GC Root", verbatimSubtitle: gcSubtitle) {
                    statusLabel(
                        viewModel.snapshot.gcRoot == nil ? "Unavailable" : "Protected",
                        systemImage: viewModel.snapshot.gcRoot == nil ? "questionmark.circle" : "lock.shield",
                        color: .secondary
                    )
                }
            }
        }
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recovery")
            SettingsCard {
                SettingsCardNote("A recovery export can restore project access. Store it offline. Revoking a device cannot be undone from that device.")
                SettingsCardDivider()
                SettingsCardRow(
                    "User Presence",
                    subtitle: viewModel.userPresenceRequired
                        ? "Touch ID or the macOS password is required before secret export."
                        : "User presence is not required by the current fixture."
                ) {
                    statusLabel(
                        viewModel.userPresenceRequired ? "Required" : "Not required",
                        systemImage: viewModel.userPresenceRequired ? "touchid" : "person.crop.circle.badge.checkmark",
                        color: viewModel.userPresenceRequired ? .blue : .secondary
                    )
                    .accessibilityIdentifier("projectSync.userPresence")
                }
                SettingsCardDivider()
                SettingsCardRow(
                    "Recovery Export",
                    verbatimSubtitle: unavailableText(.recoveryExport, fallback: "Ready for protected export")
                ) {
                    Button("Export…") {
                        viewModel.reportUnavailable(.recoveryExport)
                    }
                    .disabled(!viewModel.snapshot.capabilities.supports(.recoveryExport))
                    .accessibilityIdentifier("projectSync.exportRecovery")
                }
            }
        }
    }

    @ViewBuilder
    private func operationActions(_ operation: ProjectSyncOperation) -> some View {
        HStack(spacing: 8) {
            statusLabel(operation.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                        systemImage: operationStateImage(operation.state),
                        color: operationStateColor(operation.state))
            if operation.state.isTerminal && operation.state != .succeeded {
                Button("Retry") { Task { await viewModel.retryActiveOperation() } }
                    .disabled(viewModel.action != .idle)
                    .accessibilityIdentifier("projectSync.retry")
            } else if !operation.state.isTerminal {
                Button("Cancel") { Task { await viewModel.cancelActiveOperation() } }
                    .disabled(viewModel.action != .idle || operation.state == .cancelRequested)
                    .accessibilityIdentifier("projectSync.cancel")
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 2)
    }

    private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(color)
    }

    private var projectSubtitle: String {
        guard let path = viewModel.snapshot.projectPath else { return "Project ID unavailable" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var projectStatusText: String { viewModel.snapshot.projectID == nil ? "Unavailable" : "Registered" }
    private var projectStatusImage: String { viewModel.snapshot.projectID == nil ? "questionmark.circle" : "checkmark.circle" }
    private var projectStatusColor: Color { viewModel.snapshot.projectID == nil ? .secondary : .green }

    private func deviceSubtitle(_ device: ProjectSyncDevice) -> String {
        let shortID = String(device.id.prefix(8))
        return device.lastSeen.map { "\(shortID) · Last seen \($0)" } ?? shortID
    }

    private func operationTitle(_ operation: ProjectSyncOperation) -> String {
        operation.kind == "manifest_scan" ? "Manifest Scan" : operation.kind
    }

    private func operationSubtitle(_ operation: ProjectSyncOperation) -> String {
        let shortID = String(operation.operationID.prefix(8))
        if let result = operation.result {
            return "Operation \(shortID) · \(result.entries) entries"
        }
        if let error = operation.errorCode {
            return "Operation \(shortID) · \(error)"
        }
        return "Operation \(shortID) · Progress is not reported by this daemon"
    }

    private var gcSubtitle: String {
        guard let root = viewModel.snapshot.gcRoot else {
            return unavailableText(.garbageCollection, fallback: "No protected root")
        }
        return "\(String(root.manifestID.prefix(8))) · \(root.retainedObjects) retained objects"
    }

    private func unavailableText(_ capability: ProjectSyncCapability, fallback: String) -> String {
        viewModel.snapshot.capabilities.supports(capability) ? fallback : "Unavailable from the current daemon"
    }

    private func operationStateImage(_ state: ProjectSyncOperationState) -> String {
        switch state {
        case .pending, .running: return "arrow.triangle.2.circlepath"
        case .cancelRequested: return "xmark.circle"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "slash.circle"
        case .interrupted: return "pause.circle"
        }
    }

    private func operationStateColor(_ state: ProjectSyncOperationState) -> Color {
        switch state {
        case .pending, .running: return .blue
        case .cancelRequested, .interrupted: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
