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
    /// How much the remote-work path reports into Live Activity.
    @Published var logLevel: RemoteWorkLogLevel = .info {
        didSet {
            RemoteWorkLog.level = logLevel
            UserDefaults.standard.set(logLevel.rawValue, forKey: Self.logLevelKey)
        }
    }
    /// Describe what an action would do, and do nothing.
    ///
    /// These actions reach across a network and rewrite a Git worktree on
    /// another machine, and their preconditions are strict enough that a
    /// refusal is the common outcome. Being able to ask "what would this do,
    /// and would it even get past the guards" without committing to it is the
    /// difference between reading a plan and discovering it afterwards.
    @Published var dryRun: Bool = false {
        didSet { UserDefaults.standard.set(dryRun, forKey: Self.dryRunKey) }
    }

    private static let logLevelKey = "termmesh.remotework.logLevel"
    private static let dryRunKey = "termmesh.remotework.dryRun"
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
        // Wired here rather than when the drawer appears. Waiting for the
        // drawer meant nothing was collected until someone opened it, so the
        // first thing they saw after a tunnel dropped was an empty list — the
        // events they came to read had happened while nobody was listening.
        adoptLogSettings()
    }

    var incomingCount: Int {
        incoming.filter { ![.applied, .discarded].contains($0.state) }.count
    }

    var selectedPane: WorkspaceRemotePaneRecord? {
        panes.first { $0.id == selectedPaneID } ?? panes.first
    }

    /// The project pair the actions operate on.
    ///
    /// A project pair, not a pane: preparing a project and taking a checkpoint
    /// are about two folders, and the pane is only how one of them came to be
    /// known. Targeting a pane made the subject of the action impossible to
    /// state — "Prepare Project → shell 11" says nothing about which folders
    /// are involved.
    @Published var selectedBindingID: ProjectBindingID?

    var selectedBinding: ProjectBinding? {
        projectBindings.first { $0.id == selectedBindingID } ?? projectBindings.first
    }

    /// Where a remote pane's shell is RIGHT NOW, asked of the host that runs it.
    ///
    /// Not read from the terminal stream, which cannot answer: a shell reports
    /// its directory with OSC 7, and a terminal refuses one whose hostname is
    /// not local — otherwise any SSH session could tell your terminal where it
    /// is. A hosted pane always names its own host, so that report is dropped
    /// before anything here could see it.
    ///
    /// The host has the answer either way, since it reads the directory from
    /// the OS rather than from the shell, so this asks the host directly.
    var remoteDirectoryProvider: ((WorkspaceRemotePaneRecord) async -> String?)?

    /// The pane's directory without going out to the host: the value from the
    /// last time it was asked, or the spawn-time one. Callers that can await
    /// should prefer `refreshedDirectory(of:)`.
    func currentDirectory(of pane: WorkspaceRemotePaneRecord) -> String {
        let known = observedDirectories[pane.panelID] ?? pane.remoteRoot
        RemoteWorkLog.debug(
            "cwd cached panel=\(pane.panelID.uuidString.prefix(8)) value=\(known.isEmpty ? "<empty>" : known)"
        )
        return known
    }

    /// The pane's directory as the host reports it now, falling back to the
    /// cached value when the host cannot be reached — a binding sheet should
    /// open with a stale suggestion rather than an empty field.
    func refreshedDirectory(of pane: WorkspaceRemotePaneRecord) async -> String {
        guard let provider = remoteDirectoryProvider else {
            RemoteWorkLog.debug("cwd no host provider wired — using the cached value")
            return currentDirectory(of: pane)
        }
        let fresh = await provider(pane)
        RemoteWorkLog.debug(
            "cwd asked host panel=\(pane.panelID.uuidString.prefix(8)) got=\(fresh ?? "<none>") spawn=\(pane.remoteRoot.isEmpty ? "<empty>" : pane.remoteRoot)"
        )
        guard let fresh, fresh.hasPrefix("/") else { return currentDirectory(of: pane) }
        observedDirectories[pane.panelID] = fresh
        return fresh
    }

    /// Last directory each pane's host reported, so a second look is instant
    /// and a host that has gone away still yields its most recent answer.
    private var observedDirectories: [UUID: String] = [:]

    /// Whether the host's answer should land in a field that was seeded with
    /// `seed`.
    ///
    /// The comparison is against the seed and nothing else. Comparing against
    /// the pane's spawn directory instead looks equivalent and is not: once a
    /// directory has been remembered from an earlier look, the seed is that
    /// remembered one, the spawn test fails, and the answer just fetched from
    /// the host is thrown away — so a pane that has moved keeps suggesting
    /// where it used to be.
    ///
    /// A field holding anything else is what the user typed while the host was
    /// being asked, and that is their answer, not a placeholder to correct.
    static func shouldAdoptHostAnswer(field: String, seed: String) -> Bool {
        field == seed
    }

    /// Bind a folder pair by hand, naming the local folder and the remote one.
    ///
    /// Explicit rather than inferred: a pane's directory says where a shell is,
    /// not which project the user means to move between machines, and those
    /// differ the moment someone `cd`s into a subdirectory.
    @discardableResult
    func addBinding(peerID: String, localRoot: String, remoteRoot: String) -> ProjectBinding? {
        let local = localRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerID.isEmpty, local.hasPrefix("/"), remote.hasPrefix("/") else {
            errorMessage = "A project needs a peer and absolute local and remote paths."
            return nil
        }
        if let existing = projectBindings.first(where: { $0.peerID == peerID && $0.remoteRoot == remote }) {
            selectedBindingID = existing.id
            return existing
        }
        let binding = ProjectBinding(
            workspaceID: workspaceID, peerID: peerID, localRoot: local, remoteRoot: remote
        )
        projectBindings.append(binding)
        selectedBindingID = binding.id
        persistRecoveryState()
        return binding
    }

    /// Re-point an existing project at different folders.
    ///
    /// Keeps the id so anything already referring to this project — a
    /// checkpoint record, the current selection — still resolves. The peer's
    /// folder may already have been seeded from the OLD local repository, so a
    /// changed pair usually needs Prepare Project run again; that is a decision
    /// for the user, not something to do silently on their behalf.
    @discardableResult
    func updateBinding(
        id: ProjectBindingID,
        peerID: String,
        localRoot: String,
        remoteRoot: String
    ) -> Bool {
        let local = localRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerID.isEmpty, local.hasPrefix("/"), remote.hasPrefix("/") else {
            errorMessage = "A project needs a peer and absolute local and remote paths."
            return false
        }
        guard let index = projectBindings.firstIndex(where: { $0.id == id }) else { return false }
        let clash = projectBindings.contains {
            $0.id != id && $0.peerID == peerID && $0.remoteRoot == remote
        }
        guard !clash else {
            errorMessage = "\(peerID) already has a project bound to \(remote)."
            return false
        }
        projectBindings[index] = ProjectBinding(
            id: id, workspaceID: workspaceID, peerID: peerID, localRoot: local, remoteRoot: remote
        )
        persistRecoveryState()
        return true
    }

    func removeBinding(id: ProjectBindingID) {
        projectBindings.removeAll { $0.id == id }
        if selectedBindingID == id { selectedBindingID = projectBindings.first?.id }
        persistRecoveryState()
    }

    /// A pane on the same host as `binding`, when one is attached. Used only to
    /// hang activity and checkpoint state off something visible; the action
    /// itself needs no pane.
    func pane(for binding: ProjectBinding) -> WorkspaceRemotePaneRecord? {
        panes.first { $0.hostLabel == binding.peerID && $0.remoteRoot == binding.remoteRoot }
            ?? panes.first { $0.hostLabel == binding.peerID }
    }

    /// How the current target was arrived at, for the log and the header.
    ///
    /// The selection is sticky, not the focused pane — it is set when a pane
    /// registers or when one is picked, and otherwise falls through to whatever
    /// happens to be first. Actions that reach across a network should say
    /// which pane they mean and why, rather than leaving it to be inferred.
    var targetDescription: String {
        guard let binding = selectedBinding else { return "no project bound" }
        let how = selectedBindingID == nil
            ? "defaulted to the only/first of \(projectBindings.count)"
            : "explicitly selected"
        return "\(binding.peerID): \(binding.remoteRoot) ↔ \(binding.localRoot) (\(how))"
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
        recordActivity(paneID: pane.id, message: "Attached as a read-only remote activity view")
    }

    func removeBinding(panelID: UUID) {
        guard let pane = panes.first(where: { $0.panelID == panelID }) else { return }
        panes.removeAll { $0.panelID == panelID }
        // The pane is the only thing that could ever ask for its directory
        // again, so its remembered one would outlive every use of it.
        observedDirectories[panelID] = nil
        recordActivity(paneID: pane.id, message: "Removed from this Workspace")
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
        recordActivity(paneID: result.checkpoint.paneID, message: "Checkpoint fetched as Incoming changes")
    }

    func failCheckpoint(panelID: UUID, message: String) {
        errorMessage = message
        updatePane(panelID: panelID) { pane in pane.state = .recoveryRequired }
    }

    /// Restore the drawer's diagnostic settings and route the log into Live
    /// Activity for the currently selected pane.
    func adoptLogSettings() {
        if let raw = UserDefaults.standard.string(forKey: Self.logLevelKey),
           let restored = RemoteWorkLogLevel(rawValue: raw) {
            logLevel = restored
        }
        dryRun = UserDefaults.standard.bool(forKey: Self.dryRunKey)
        RemoteWorkLog.level = logLevel
        RemoteWorkLog.sink = { [weak self] message in
            guard let self else { return }
            // No pane is not a reason to drop the line. Connection events
            // arrive before the first remote pane exists, and dropping them
            // was why the drawer looked empty exactly when it mattered.
            self.recordActivity(paneID: self.selectedPane?.id ?? self.panes.first?.id, message: message)
        }
    }

    /// How many events the drawer keeps in memory.
    ///
    /// The list shows 200 and the file keeps everything, so holding more than
    /// this buys nothing and grows without bound in a session that stays
    /// connected for days.
    private static let activityLimit = 500

    func recordActivity(paneID: RemotePaneID?, message: String) {
        activity.insert(RemotePaneActivity(paneID: paneID, message: message), at: 0)
        if activity.count > Self.activityLimit {
            activity.removeLast(activity.count - Self.activityLimit)
        }
    }

    /// Empty the drawer so the next run reads on its own.
    ///
    /// The on-disk log is deliberately untouched: this clears a view, and a
    /// run someone wanted to keep is still behind Reveal Log.
    func clearActivity() {
        activity.removeAll()
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
