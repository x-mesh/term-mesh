import AppKit
import SwiftUI
import Bonsplit

/// Selection math for the Activity log rows. Kept separate from AppKit modifier
/// lookup so range/toggle behavior stays deterministic and unit-testable.
enum RetrievalActivitySelection {
    static func updating<ID: Hashable>(
        current: Set<ID>,
        clicked: ID,
        ordered: [ID],
        anchor: ID?,
        extendsRange: Bool,
        toggles: Bool
    ) -> (selected: Set<ID>, anchor: ID?) {
        if extendsRange,
           let anchor,
           let start = ordered.firstIndex(of: anchor),
           let end = ordered.firstIndex(of: clicked) {
            let range = Set(ordered[min(start, end)...max(start, end)])
            return (toggles ? current.union(range) : range, anchor)
        }
        if toggles {
            var next = current
            if !next.insert(clicked).inserted { next.remove(clicked) }
            return (next, clicked)
        }
        return ([clicked], clicked)
    }
}

/// Remote Work is mounted directly beside terminal surfaces. Use explicit
/// AppKit semantic colors rather than materials, which sample the terminal
/// underneath and can retain a dark tint after a light-mode appearance change.
private enum RetrievalChromePalette {
    static var panel: Color { Color(nsColor: .windowBackgroundColor) }
    static var elevated: Color { Color(nsColor: .controlBackgroundColor) }
    static var separator: Color { Color(nsColor: .separatorColor) }
}

struct WorkspaceRetrievalSidebarSection: View {
    let workspace: Workspace
    @ObservedObject private var store: WorkspaceRetrievalStore
    @Environment(TabManager.self) private var tabManager

    init(workspace: Workspace) {
        self.workspace = workspace
        self.store = workspace.retrievalStore
    }

    var body: some View {
        if store.visiblePresentations.contains(.sidebar), !store.panes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label("Remote Work", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.incomingCount > 0 {
                        Text("\(store.incomingCount)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .accessibilityLabel("\(store.incomingCount) incoming changesets")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 7)

                ForEach(store.panes) { pane in
                    Button {
                        store.selectedPaneID = pane.id
                        ActivityWindowController.shared.show(tab: .remoteWork)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: pane.state == .recoveryRequired
                                  ? "exclamationmark.triangle.fill"
                                  : "terminal")
                                .font(.system(size: 10))
                                .foregroundStyle(pane.state == .recoveryRequired ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pane.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Text("\(pane.hostLabel) · \(pane.bindingRole == .linked ? "Linked" : lifetimeLabel(pane.lifetime))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Circle()
                                .fill(pane.state == .running ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pane.title), \(pane.hostLabel), \(lifetimeLabel(pane.lifetime)), \(pane.state.rawValue)")
                    .contextMenu {
                        Button("Prepare Current Project") {
                            // Select this pane's project first: the action is
                            // about a folder pair, and the menu names a pane.
                            if let binding = store.projectBinding(for: pane) {
                                store.selectedBindingID = binding.id
                            }
                            Task { await workspace.seedRemoteProject() }
                        }
                        if pane.lifetime == .temporary {
                            Button("Keep Alive") {
                                workspace.promoteRemotePane(panelID: pane.panelID)
                            }
                        }
                        Menu("Link to Workspace") {
                            ForEach(tabManager.tabs.filter { $0.id != workspace.id }) { target in
                                Button(target.title) {
                                    Task { await workspace.linkRemotePane(panelID: pane.panelID, to: target) }
                                }
                            }
                        }
                        .disabled(tabManager.tabs.count < 2)
                        if pane.lifetime == .keepAlive || pane.bindingRole == .linked {
                            Button("Remove from Workspace") {
                                _ = workspace.closePanel(pane.panelID, force: true)
                            }
                        }
                        Divider()
                        Button("Terminate Remote Pane", role: .destructive) {
                            Task { await workspace.terminateRemotePane(panelID: pane.panelID) }
                        }
                    }
                }
            }
            .padding(.bottom, 6)
            .accessibilityIdentifier("retrieval.sidebar")
        }
    }

    private func lifetimeLabel(_ lifetime: RemotePaneLifetime) -> String {
        lifetime == .temporary ? "Temporary" : "Keep Alive"
    }
}

struct WorkspaceRetrievalChrome<Content: View>: View {
    let workspace: Workspace
    @ObservedObject private var store: WorkspaceRetrievalStore
    private let content: Content

    init(workspace: Workspace, @ViewBuilder content: () -> Content) {
        self.workspace = workspace
        self.store = workspace.retrievalStore
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let compactInspector = proxy.size.width < 900
                && store.visiblePresentations.contains(.inspector)
            let sideInspector = store.visiblePresentations.contains(.inspector)
                && !compactInspector
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if sideInspector, !store.panes.isEmpty {
                        RetrievalChangesInspector(workspace: workspace)
                            .frame(width: inspectorWidth(proxy.size.width))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if compactInspector, !store.panes.isEmpty {
                    RetrievalChangesInspector(workspace: workspace)
                        .frame(height: min(360, proxy.size.height * 0.55))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Checkpoints also run on their own (a finished run, a closing
                // session), so a failure can arrive with the Activity
                // window closed. It is the one thing that still claims space
                // here, and only while there is something to say.
                if let message = store.errorMessage, !store.panes.isEmpty {
                    RetrievalErrorBanner(message: message) {
                        store.errorMessage = nil
                    }
                    .padding(.horizontal, PaneGapSettings.current)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !store.panes.isEmpty {
                    HStack {
                        Spacer()
                        RetrievalPresentationBar(store: store)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.visiblePresentations)
            .animation(.easeOut(duration: 0.18), value: store.errorMessage)
            .cardWindowBackground()
            // Safety pin: if any chrome row ever refuses to compress again,
            // it must not inflate the VStack and re-center the terminal row
            // over the Review Board. Hold the chrome to its slot, top-leading,
            // so an oversized row overflows trailing while the panes stay put.
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
        }
        .sheet(isPresented: closeGateBinding) {
            if let panelID = store.pendingClosePanelID,
               let pane = store.pane(panelID: panelID) {
                RetrievalCloseGate(workspace: workspace, pane: pane)
                    .frame(minWidth: 520, minHeight: 260)
            }
        }
        .accessibilityIdentifier("retrieval.chrome")
    }

    private func inspectorWidth(_ width: CGFloat) -> CGFloat {
        min(380, max(300, width * 0.36))
    }

    private var closeGateBinding: Binding<Bool> {
        Binding(
            get: { store.pendingClosePanelID != nil },
            set: { isPresented in
                if !isPresented { store.cancelClose() }
            }
        )
    }
}

private struct RetrievalPresentationBar: View {
    @ObservedObject var store: WorkspaceRetrievalStore

    var body: some View {
        HStack(spacing: 2) {
            presentationButton(.sidebar, image: "sidebar.left")
            presentationButton(.inspector, image: "sidebar.right")
            Button {
                ActivityWindowController.shared.show(tab: .remoteWork)
            } label: {
                Image(systemName: "stethoscope")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Open Activity: checkpoints, incoming changes and the remote-work log")
            .accessibilityLabel("Open Activity")
            .accessibilityIdentifier("retrieval.openActivity")
        }
        .padding(3)
        .background(RetrievalChromePalette.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RetrievalChromePalette.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remote Work presentations")
    }

    private func presentationButton(_ presentation: WorkspaceRetrievalPresentation, image: String) -> some View {
        Button {
            store.togglePresentation(presentation)
        } label: {
            Image(systemName: image)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 24)
                .background(
                    store.visiblePresentations.contains(presentation)
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .help("Toggle \(presentation.rawValue.capitalized)")
        .accessibilityLabel("Toggle \(presentation.rawValue)")
        .accessibilityValue(store.visiblePresentations.contains(presentation) ? "Shown" : "Hidden")
    }
}

/// A failed remote-work action, shown where the workspace is.
struct RetrievalErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Open Activity") {
                ActivityWindowController.shared.show(tab: .logs)
            }
            .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("retrieval.errorBanner")
    }
}

private struct RetrievalChangesInspector: View {
    let workspace: Workspace
    @ObservedObject private var store: WorkspaceRetrievalStore
    @State private var showsUnverifiedApproval = false

    init(workspace: Workspace) {
        self.workspace = workspace
        self.store = workspace.retrievalStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes Inspector")
                        .font(.system(size: 13, weight: .semibold))
                    Text("REMOTE COPY · READ ONLY")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    store.visiblePresentations.remove(.inspector)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Changes Inspector")
            }
            .padding(14)

            Divider()

            if let changeset = store.selectedChangeset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        metadata(changeset)
                        if !changeset.diffSummary.isEmpty {
                            Text(changeset.diffSummary)
                                .font(.system(size: 10).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Changed files")
                                .font(.system(size: 11, weight: .semibold))
                            ForEach(changeset.changedPaths, id: \.self) { path in
                                Label(path, systemImage: "doc")
                                    .font(.system(size: 10).monospaced())
                                    .lineLimit(2)
                            }
                        }
                        if let failure = changeset.failureMessage {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(14)
                }

                Divider()
                HStack(spacing: 8) {
                    Button("Validate") {
                        Task { await workspace.validateChangeset(changeset.id) }
                    }
                    .disabled(changeset.state == .validating || changeset.state == .applying)
                    if changeset.state == .unverified {
                        Button("Approve Unverified") {
                            showsUnverifiedApproval = true
                        }
                    }
                    Button("Apply All") {
                        Task { await workspace.applyChangeset(changeset.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(changeset.state != .validated)
                    Spacer()
                    Button("Discard", role: .destructive) {
                        Task { await workspace.discardChangeset(changeset.id) }
                    }
                    .disabled(changeset.state == .applying || changeset.state == .applied)
                }
                .padding(12)
                .confirmationDialog(
                    "Apply without a build or test result?",
                    isPresented: $showsUnverifiedApproval,
                    titleVisibility: .visible
                ) {
                    Button("Approve Unverified Changes") {
                        _ = store.approveUnverifiedChangeset(changeset.id)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The Git patch passed structural checks only. Review the changed files before approving it.")
                }
            } else {
                ContentUnavailableView(
                    "No Incoming Changes",
                    systemImage: "tray",
                    description: Text("Create a durable checkpoint from a remote pane first.")
                )
            }
        }
        .cardPanel()
        // Beside or below the pane cards; the terminal area's own margin is the
        // gap on the side that faces them.
        .padding([.trailing, .bottom], PaneGapSettings.current)
        .padding(.top, BonsplitCardMetrics.outerTopMargin)
        .accessibilityIdentifier("retrieval.inspector")
    }

    private func metadata(_ changeset: IncomingChangeset) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            metadataRow("State", changeset.state.rawValue.capitalized)
            metadataRow("Base", String(changeset.baseRevision.prefix(10)))
            metadataRow("Checkpoint", String(changeset.checkpointRevision.prefix(10)))
            metadataRow("Boundary", changeset.boundary.rawValue)
            metadataRow("Scope", "Shared Session")
        }
        .font(.system(size: 10))
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

private struct RetrievalCloseGate: View {
    let workspace: Workspace
    let pane: WorkspaceRemotePaneRecord

    var body: some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Label("Remote work has not been collected", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                Text("Create a durable Git checkpoint before closing \(pane.title), or explicitly discard the remote work.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if pane.state == .recoveryRequired,
                   let message = workspace.retrievalStore.errorMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Keep Running") {
                        workspace.retrievalStore.cancelClose()
                    }
                    Spacer()
                    Button("Discard & Close", role: .destructive) {
                        workspace.retrievalStore.pendingClosePanelID = nil
                        _ = workspace.closePanel(pane.panelID, force: true)
                    }
                    Button("Checkpoint & Close") {
                        Task { await workspace.checkpointRemotePane(panelID: pane.panelID, closeAfterCheckpoint: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pane.state == .checkpointing)
                }
            }
            .padding(18)
            .frame(width: 430)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        }
        .accessibilityIdentifier("retrieval.closeGate")
    }
}

/// Bind a local folder to one on a peer.
///
/// Needed because the automatic binding only happens when a remote pane spawns
/// inside a project directory — a shell opened anywhere else never gets one,
/// and the remote path is captured at spawn and does not follow a later `cd`.
/// Without this the actions had no subject and simply refused.
struct ProjectBindingSheet: View {
    @ObservedObject var store: WorkspaceRetrievalStore
    @Binding var isPresented: Bool
    /// nil adds a project; a value edits that one.
    let editing: ProjectBinding?

    @State private var peerID: String = ""
    @State private var localRoot: String = ""
    @State private var remoteRoot: String = ""
    @State private var confirmingDelete = false

    /// Hosts with a pane attached — the only ones an action could reach.
    private var hosts: [String] {
        Array(Set(store.panes.map(\.hostLabel))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "Bind a Project" : "Edit Project")
                .font(.headline)
            Text("Prepare Project and Checkpoint act on a pair of folders — one here, one on a peer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Peer").font(.caption).foregroundStyle(.secondary)
                    if hosts.isEmpty {
                        Text("No peer is connected.").font(.caption).foregroundStyle(.orange)
                    } else {
                        Picker("", selection: $peerID) {
                            ForEach(hosts, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 260, alignment: .leading)
                    }
                }
                GridRow {
                    Text("On the peer").font(.caption).foregroundStyle(.secondary)
                    TextField("/absolute/path/on/peer", text: $remoteRoot)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 320)
                }
                GridRow {
                    Text("This Mac").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("/absolute/path/here", text: $localRoot)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 250)
                        Button("Choose…", action: chooseLocal).controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Prepare Project seeds the peer FROM this Mac, once.")
                Text("Checkpoint brings the peer's work BACK as a commit, for review under Incoming. It never writes your working tree.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("The local folder must be a Git repository: a checkpoint is a commit, fetched home for review.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let editing, pathsChanged(from: editing) {
                Label(
                    "The peer folder was seeded from the previous local repository. Run Prepare Project again after saving.",
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let editing {
                    Button("Remove", role: .destructive) { confirmingDelete = true }
                        .confirmationDialog(
                            "Remove this project binding?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible
                        ) {
                            Button("Remove", role: .destructive) {
                                store.removeBinding(id: editing.id)
                                RemoteWorkLog.info("Removed project \(editing.peerID): \(editing.remoteRoot)")
                                isPresented = false
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Nothing on either machine is deleted — only this pairing is forgotten.")
                        }
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                Button(editing == nil ? "Bind" : "Save") {
                    if let editing {
                        let ok = store.updateBinding(
                            id: editing.id, peerID: peerID, localRoot: localRoot, remoteRoot: remoteRoot
                        )
                        if ok {
                            RemoteWorkLog.info("Project now \(peerID): \(remoteRoot) ↔ \(localRoot)")
                            isPresented = false
                        }
                    } else {
                        store.addBinding(peerID: peerID, localRoot: localRoot, remoteRoot: remoteRoot)
                        RemoteWorkLog.info("Bound project \(peerID): \(remoteRoot) ↔ \(localRoot)")
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(peerID.isEmpty || !localRoot.hasPrefix("/") || !remoteRoot.hasPrefix("/"))
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            if let editing {
                peerID = editing.peerID
                localRoot = editing.localRoot
                remoteRoot = editing.remoteRoot
                return
            }
            // Default to the pane the user is looking at: its host, and where
            // its shell currently is. That is almost always the project being
            // bound, and typing an absolute remote path by hand is the step
            // most likely to be got wrong.
            let source = store.selectedPane ?? store.panes.first
            if peerID.isEmpty { peerID = source?.hostLabel ?? hosts.first ?? "" }
            guard remoteRoot.isEmpty, let source else { return }
            // Fill from what is already known first so the field is never
            // blank, then let the host's answer replace it. Asking costs a
            // round trip, and a sheet that opens empty and fills in later
            // reads as broken.
            let seed = store.currentDirectory(of: source)
            remoteRoot = seed
            Task {
                let fresh = await store.refreshedDirectory(of: source)
                if WorkspaceRetrievalStore.shouldAdoptHostAnswer(field: remoteRoot, seed: seed) {
                    remoteRoot = fresh
                }
            }
        }
    }

    private func pathsChanged(from binding: ProjectBinding) -> Bool {
        localRoot != binding.localRoot || remoteRoot != binding.remoteRoot
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { localRoot = url.path }
    }
}
