import Foundation

@MainActor
final class WorkspaceRetrievalStore: ObservableObject {
    @Published private(set) var panes: [WorkspaceRemotePaneRecord] = []
    @Published private(set) var projectBindings: [ProjectBinding] = []
    @Published private(set) var checkpoints: [RemoteCheckpointRecord] = []
    @Published private(set) var incoming: [IncomingChangeset] = []
    @Published private(set) var activity: [RemotePaneActivity] = []
    @Published var selectedPaneID: RemotePaneID?
    @Published var selectedChangesetID: ChangesetID?
    @Published var pendingClosePanelID: UUID?
    @Published var errorMessage: String?
    @Published var visiblePresentations: Set<WorkspaceRetrievalPresentation> {
        didSet { persistPresentations() }
    }

    let workspaceID: UUID
    private let defaults: UserDefaults
    private let presentationKey: String
    private let recoveryKey: String

    private struct RecoveryState: Codable {
        var projectBindings: [ProjectBinding]
        var checkpoints: [RemoteCheckpointRecord]
        var incoming: [IncomingChangeset]
    }

    init(workspaceID: UUID, defaults: UserDefaults = .standard) {
        self.workspaceID = workspaceID
        self.defaults = defaults
        self.presentationKey = "workspace.retrieval.presentations.\(workspaceID.uuidString)"
        self.recoveryKey = "workspace.retrieval.recovery.\(workspaceID.uuidString)"
        let stored = defaults.stringArray(forKey: presentationKey) ?? []
        let restored = Set(stored.compactMap(WorkspaceRetrievalPresentation.init(rawValue:)))
        self.visiblePresentations = restored.isEmpty ? [.sidebar, .drawer] : restored
        if let data = defaults.data(forKey: recoveryKey),
           let recovery = try? JSONDecoder().decode(RecoveryState.self, from: data) {
            self.projectBindings = recovery.projectBindings
            self.checkpoints = recovery.checkpoints
            self.incoming = recovery.incoming
            self.selectedChangesetID = recovery.incoming.first(where: {
                ![.applied, .discarded].contains($0.state)
            })?.id
        }
    }

    var incomingCount: Int {
        incoming.filter { ![.applied, .discarded].contains($0.state) }.count
    }

    var selectedPane: WorkspaceRemotePaneRecord? {
        panes.first { $0.id == selectedPaneID } ?? panes.first
    }

    var selectedChangeset: IncomingChangeset? {
        incoming.first { $0.id == selectedChangesetID } ?? incoming.first
    }

    func registerPane(_ pane: WorkspaceRemotePaneRecord, localOrigin: String) {
        panes.removeAll { $0.panelID == pane.panelID }
        panes.append(pane)
        selectedPaneID = pane.id
        if !pane.remoteRoot.isEmpty,
           !projectBindings.contains(where: { $0.peerID == pane.hostLabel && $0.remoteRoot == pane.remoteRoot }) {
            projectBindings.append(ProjectBinding(
                workspaceID: workspaceID,
                peerID: pane.hostLabel,
                localRoot: localOrigin,
                remoteRoot: pane.remoteRoot
            ))
            persistRecoveryState()
        }
        activity.insert(RemotePaneActivity(
            paneID: pane.id,
            message: "Attached as a read-only remote activity view"
        ), at: 0)
    }

    func removeBinding(panelID: UUID) {
        guard let pane = panes.first(where: { $0.panelID == panelID }) else { return }
        panes.removeAll { $0.panelID == panelID }
        activity.insert(RemotePaneActivity(paneID: pane.id, message: "Removed from this Workspace"), at: 0)
        if selectedPaneID == pane.id { selectedPaneID = panes.first?.id }
        pendingClosePanelID = nil
    }

    func pane(panelID: UUID) -> WorkspaceRemotePaneRecord? {
        panes.first { $0.panelID == panelID }
    }

    func projectBinding(for pane: WorkspaceRemotePaneRecord) -> ProjectBinding? {
        projectBindings.first { $0.peerID == pane.hostLabel && $0.remoteRoot == pane.remoteRoot }
    }

    func requestClose(panelID: UUID) {
        pendingClosePanelID = panelID
        if let pane = pane(panelID: panelID) { selectedPaneID = pane.id }
    }

    func cancelClose() {
        pendingClosePanelID = nil
    }

    func promote(panelID: UUID) {
        updatePane(panelID: panelID) { pane in
            pane.lifetime = .keepAlive
        }
        pendingClosePanelID = nil
    }

    func beginCheckpoint(panelID: UUID) {
        errorMessage = nil
        updatePane(panelID: panelID) { pane in pane.state = .checkpointing }
    }

    func completeCheckpoint(panelID: UUID, result: RemoteGitCheckpointResult) {
        checkpoints.insert(result.checkpoint, at: 0)
        incoming.insert(result.changeset, at: 0)
        persistRecoveryState()
        selectedChangesetID = result.changeset.id
        updatePane(panelID: panelID) { pane in
            pane.state = .readyToClose
            pane.hasUncollectedChanges = false
        }
        activity.insert(RemotePaneActivity(
            paneID: result.checkpoint.paneID,
            message: "Checkpoint fetched as Incoming changes"
        ), at: 0)
    }

    func failCheckpoint(panelID: UUID, message: String) {
        errorMessage = message
        updatePane(panelID: panelID) { pane in pane.state = .recoveryRequired }
    }

    func recordActivity(paneID: RemotePaneID, message: String) {
        activity.insert(RemotePaneActivity(paneID: paneID, message: message), at: 0)
    }

    func setChangesetState(_ id: ChangesetID, state: IncomingChangesetState, error: String? = nil) {
        guard let index = incoming.firstIndex(where: { $0.id == id }) else { return }
        incoming[index].state = state
        incoming[index].failureMessage = error
        errorMessage = error
        persistRecoveryState()
    }

    @discardableResult
    func approveUnverifiedChangeset(_ id: ChangesetID) -> Bool {
        guard let index = incoming.firstIndex(where: { $0.id == id }),
              incoming[index].state == .unverified else { return false }
        incoming[index].state = .validated
        incoming[index].failureMessage = nil
        persistRecoveryState()
        return true
    }

    func togglePresentation(_ presentation: WorkspaceRetrievalPresentation) {
        if visiblePresentations.contains(presentation) {
            visiblePresentations.remove(presentation)
        } else {
            visiblePresentations.insert(presentation)
        }
    }

    private func updatePane(panelID: UUID, mutation: (inout WorkspaceRemotePaneRecord) -> Void) {
        guard let index = panes.firstIndex(where: { $0.panelID == panelID }) else { return }
        mutation(&panes[index])
    }

    private func persistPresentations() {
        defaults.set(visiblePresentations.map(\.rawValue).sorted(), forKey: presentationKey)
    }

    private func persistRecoveryState() {
        let state = RecoveryState(
            projectBindings: projectBindings,
            checkpoints: checkpoints,
            incoming: incoming
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: recoveryKey)
    }
}
