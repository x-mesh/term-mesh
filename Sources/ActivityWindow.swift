import AppKit
import SwiftUI

/// One window for what is read after the fact rather than watched: the
/// remote-work log, the peer connections, the checkpoint and incoming-change
/// lists of the selected workspace, and the app's diagnostics. It used to be a drawer under every workspace with a
/// remote pane, open by default, spending 220pt of terminal on lines that are
/// mostly connection probes.
@MainActor
final class ActivityWindowController: NSWindowController {
    static let shared = ActivityWindowController()

    enum Tab: String, CaseIterable {
        case logs = "Logs"
        case connections = "Connections"
        case remoteWork = "Remote Work"
        case diagnostics = "Diagnostics"

        /// The name the debug socket uses.
        var key: String {
            switch self {
            case .logs: "logs"
            case .connections: "connections"
            case .remoteWork: "remote_work"
            case .diagnostics: "diagnostics"
            }
        }

        init?(key: String) {
            guard let tab = Self.allCases.first(where: { $0.key == key }) else { return nil }
            self = tab
        }
    }

    private let model = ActivityWindowModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Activity"
        window.identifier = NSUserInterfaceItemIdentifier("term-mesh.activity")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 320)
        window.center()
        window.setFrameAutosaveName("term-mesh.activity")
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ActivityWindowView(model: model))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens the window on `tab`, or on the tab it last showed. Returns what
    /// it now shows, for the debug socket.
    @discardableResult
    func show(tab: Tab? = nil) -> [String: Any] {
        if let tab { model.selectedTab = tab }
        model.adoptSelectedWorkspace()
        window?.makeKeyAndOrderFront(nil)
        return [
            "visible": window?.isVisible ?? false,
            "tab": model.selectedTab.key,
            "workspace_id": model.workspaceID?.uuidString ?? NSNull(),
            "log_lines": RemoteWorkLogBuffer.shared.entries.count,
        ]
    }
}

@MainActor
final class ActivityWindowModel: ObservableObject {
    @Published var selectedTab: ActivityWindowController.Tab = .logs
    /// The workspace the Remote Work tab acts on: the one selected in the
    /// main window when Activity was last brought up. Held weakly so an
    /// open Activity window never keeps a closed workspace alive.
    @Published private(set) var workspaceID: UUID?
    private(set) weak var workspace: Workspace?

    func adoptSelectedWorkspace() {
        let selected = AppDelegate.shared?.tabManager?.selectedWorkspace
        workspace = selected
        workspaceID = selected?.id
    }
}

private struct ActivityWindowView: View {
    @ObservedObject var model: ActivityWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                UnderlineTabPicker(
                    items: ActivityWindowController.Tab.allCases.map {
                        UnderlineTabItem(value: $0, title: $0.rawValue)
                    },
                    selection: model.selectedTab,
                    onSelect: { model.selectedTab = $0 }
                )
                .accessibilityLabel("Activity")
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            Divider()

            switch model.selectedTab {
            case .logs:
                ActivityLogView()
            case .connections:
                ActivityConnectionsView()
                    .onAppear { PeerConnectionsController.shared.activate() }
                    .onDisappear { PeerConnectionsController.shared.deactivate() }
            case .diagnostics:
                ActivityDiagnosticsView()
            case .remoteWork:
                if let workspace = model.workspace {
                    ActivityRemoteWorkView(workspace: workspace)
                        .id(workspace.id)
                } else {
                    ActivityEmptyState(text: "No workspace is selected.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The main window changes its selection without telling this one.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow)?.identifier?.rawValue == "term-mesh.activity" else { return }
            model.adoptSelectedWorkspace()
            // Reopening the window does not re-run the tab's `onAppear`.
            if model.selectedTab == .connections { PeerConnectionsController.shared.activate() }
        }
        .accessibilityIdentifier("activity.window")
    }
}

private struct ActivityEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Logs

private enum ActivityLogFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case problems = "Warnings & Errors"

    var id: String { rawValue }
}

/// The remote-work log of the whole app, newest first.
private struct ActivityLogView: View {
    @ObservedObject private var buffer = RemoteWorkLogBuffer.shared
    @State private var filter: ActivityLogFilter = .all
    @State private var query = ""
    @State private var level = RemoteWorkLog.level
    @State private var selectedIDs = Set<UInt64>()
    @State private var selectionAnchor: UInt64?

    /// Rows laid out at once. The buffer holds 2000 and the file keeps
    /// everything; past this a filter or the file is the better tool.
    private static let visibleLimit = 500

    private var matching: [RemoteWorkLogEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return buffer.entries.reversed().filter { entry in
            (filter == .all || entry.severity != .info)
                && (needle.isEmpty || entry.message.localizedCaseInsensitiveContains(needle))
        }
    }

    var body: some View {
        let entries = matching
        let visible = Array(entries.prefix(Self.visibleLimit))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $filter) {
                    ForEach(ActivityLogFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("activity.logs.filter")
                TextField("Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("activity.logs.query")
                Text(entries.count > visible.count
                     ? "\(visible.count) of \(entries.count)"
                     : "\(entries.count) line(s)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $level) {
                    ForEach(RemoteWorkLogLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 84)
                .help("How much the remote-work path reports here. The log file keeps everything.")
                .onChange(of: level) { WorkspaceRetrievalStore.setLogLevel($0) }
                Button("Copy Selected") {
                    copy(entries.filter { selectedIDs.contains($0.id) })
                }
                .controlSize(.small)
                .disabled(selectedIDs.isEmpty)
                .help("Click rows to select them; use Command-click or Shift-click for multiple rows.")
                .accessibilityIdentifier("activity.logs.copySelected")
                Button("Copy All") { copy(entries) }
                    .controlSize(.small)
                    .disabled(entries.isEmpty)
                    .accessibilityIdentifier("activity.logs.copyAll")
                // Clears what is on screen, not the file behind Reveal Log.
                Button("Clear") {
                    buffer.clear()
                    selectedIDs.removeAll()
                    selectionAnchor = nil
                }
                .controlSize(.small)
                .disabled(buffer.entries.isEmpty)
                .help("Clear the lines shown here. The log file keeps them.")
                .accessibilityIdentifier("activity.logs.clear")
                Button("Reveal Log") {
                    NSWorkspace.shared.selectFile(RemoteWorkLog.path, inFileViewerRootedAtPath: "")
                }
                .controlSize(.small)
                .help(RemoteWorkLog.path)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()

            if visible.isEmpty {
                ActivityEmptyState(
                    text: buffer.entries.isEmpty ? "Nothing logged yet." : "No line matches."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { entry in
                            row(entry, ordered: visible)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: buffer.entries.first?.id) { _ in
            // Lines leave the buffer from the old end; drop what left with them.
            let live = Set(buffer.entries.map(\.id))
            selectedIDs.formIntersection(live)
            if let selectionAnchor, !live.contains(selectionAnchor) {
                self.selectionAnchor = nil
            }
        }
        .accessibilityIdentifier("activity.logs")
    }

    // Rows are buttons, not selectable text: dragging across a selectable
    // `Text` this long pinned the main thread (#321).
    private func row(_ entry: RemoteWorkLogEntry, ordered: [RemoteWorkLogEntry]) -> some View {
        Button {
            let modifiers = NSEvent.modifierFlags
            let update = RetrievalActivitySelection.updating(
                current: selectedIDs,
                clicked: entry.id,
                ordered: ordered.map(\.id),
                anchor: selectionAnchor,
                extendsRange: modifiers.contains(.shift),
                toggles: modifiers.contains(.command)
            )
            selectedIDs = update.selected
            selectionAnchor = update.anchor
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.icon(for: entry.severity))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.color(for: entry.severity))
                    .accessibilityLabel(entry.severity.rawValue.capitalized)
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.color(for: entry.severity))
                    .fixedSize(horizontal: false, vertical: true)
                if entry.repeatCount > 1 {
                    Text("×\(entry.repeatCount)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                selectedIDs.contains(entry.id) ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Line") { copy([entry]) }
        }
        .accessibilityAddTraits(selectedIDs.contains(entry.id) ? .isSelected : [])
    }

    /// Oldest first, the order a log is read in.
    private func copy(_ entries: [RemoteWorkLogEntry]) {
        let text = entries.reversed().map { entry in
            let stamp = entry.date.formatted(date: .omitted, time: .standard)
            let repeats = entry.repeatCount > 1 ? " ×\(entry.repeatCount)" : ""
            return "\(stamp)  [\(entry.severity.rawValue.uppercased())] \(entry.message)\(repeats)"
        }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func icon(for severity: RemoteWorkLogSeverity) -> String {
        switch severity {
        case .info: "circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private static func color(for severity: RemoteWorkLogSeverity) -> Color {
        switch severity {
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}

// MARK: - Connections

/// The AppKit tables `PeerConnectionsController` owns.
private struct ActivityConnectionsView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        let content = PeerConnectionsController.shared.contentView
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Diagnostics

/// The diagnostics bundle a bug report would carry, readable without
/// starting a report: the live state, or one frozen when a host looked
/// unhealthy.
private struct ActivityDiagnosticsView: View {
    @StateObject private var model = BugReportModel()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Show", selection: $model.selectedCaptureID) {
                    Text("Current state").tag(UUID?.none)
                    ForEach(model.captures) { capture in
                        Text("\(capture.reason) — \(Self.relative.localizedString(for: capture.capturedAt, relativeTo: Date()))")
                            .tag(UUID?.some(capture.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
                .help("The live state, or a snapshot frozen when a host looked unhealthy.")
                .accessibilityIdentifier("activity.diagnostics.capture")
                Button("Refresh") { model.refresh() }
                    .controlSize(.small)
                    .accessibilityIdentifier("activity.diagnostics.refresh")
                if model.isAwaitingDaemon {
                    ProgressView().controlSize(.small)
                    Text("waiting for the daemon…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.bundle, forType: .string)
                }
                .controlSize(.small)
                .disabled(model.bundle.isEmpty)
                .accessibilityIdentifier("activity.diagnostics.copy")
                Button("Report an Issue…") { BugReportWindowController.shared.show() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()

            if model.knownSignature?.knownIssue != nil {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                    Text("This state matches a known issue. Report an Issue shows the answer.")
                        .font(.system(size: 11))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.12))
                Divider()
            }

            ScrollView {
                // Not selectable: dragging inside a selectable `Text` this
                // long re-enumerates the whole document on every mouse-moved
                // event (#321). Copy hands over all of it.
                Text(model.bundle)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear { model.refresh() }
        .accessibilityIdentifier("activity.diagnostics")
    }
}

// MARK: - Remote Work

/// Project folder pairs, checkpoints and incoming changes of one workspace.
private struct ActivityRemoteWorkView: View {
    let workspace: Workspace
    @ObservedObject private var store: WorkspaceRetrievalStore
    @State private var isEditingProject = false
    @State private var editingBinding: ProjectBinding?

    init(workspace: Workspace) {
        self.workspace = workspace
        self.store = workspace.retrievalStore
    }

    var body: some View {
        VStack(spacing: 0) {
            // The controls sum to more than a narrow window offers; an HStack
            // alone refuses to compress, so fall back to a horizontal scroll.
            ViewThatFits(in: .horizontal) {
                toolbar
                ScrollView(.horizontal, showsIndicators: false) { toolbar }
            }
            .frame(height: 38)
            .sheet(isPresented: $isEditingProject) {
                ProjectBindingSheet(
                    store: store,
                    isPresented: $isEditingProject,
                    editing: editingBinding
                )
            }
            Divider()

            if let message = store.errorMessage {
                RetrievalErrorBanner(message: message) { store.errorMessage = nil }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Incoming", count: store.incomingCount) { incoming }
                    section("Checkpoints", count: store.checkpoints.count) { checkpoints }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("activity.remoteWork")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(workspace.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .help("The workspace selected when Activity was opened.")

            // Which folder pair the buttons act on, on screen rather than
            // implied by whichever pane registered last.
            if store.projectBindings.isEmpty {
                Text("No project bound")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: Binding(
                    get: { store.selectedBinding?.id },
                    set: { store.selectedBindingID = $0 }
                )) {
                    ForEach(store.projectBindings, id: \.id) { binding in
                        Text("\(binding.peerID): \(binding.remoteRoot)").tag(Optional(binding.id))
                    }
                }
                .frame(maxWidth: 280)
                .help("The project folder pair these actions act on.")
                .accessibilityIdentifier("retrieval.target")
            }
            Button {
                editingBinding = nil
                isEditingProject = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Bind a local folder to a folder on a peer.")
            .accessibilityIdentifier("retrieval.addProject")
            if let selected = store.selectedBinding {
                Button {
                    editingBinding = selected
                    isEditingProject = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Change or remove this project's folders.")
                .accessibilityIdentifier("retrieval.editProject")
            }

            Spacer()

            Toggle("Dry run", isOn: $store.dryRun)
                .toggleStyle(.checkbox)
                .help("Report what each action would do, without doing it.")
                .accessibilityIdentifier("retrieval.dryRun")
            Button("Prepare Project") {
                Task { await workspace.seedRemoteProject() }
            }
            .disabled(store.selectedBinding == nil)
            Button("Checkpoint Now") {
                Task { await workspace.checkpointProject() }
            }
            .disabled(store.selectedBinding == nil)
            .accessibilityIdentifier("retrieval.checkpointNow")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func section<Content: View>(
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) \(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private var incoming: some View {
        if store.incoming.isEmpty {
            Text("No changes fetched from a peer yet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(store.incoming) { changeset in
                        Button {
                            store.selectedChangesetID = changeset.id
                            store.visiblePresentations.insert(.inspector)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(String(changeset.checkpointRevision.prefix(10)))
                                    .font(.system(size: 11, weight: .semibold).monospaced())
                                Text("\(changeset.changedPaths.count) files · \(changeset.state.rawValue)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 180, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .help("Show these changes in the workspace's Changes Inspector.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var checkpoints: some View {
        if store.checkpoints.isEmpty {
            Text("No checkpoint taken yet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.checkpoints) { checkpoint in
                    HStack {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(.secondary)
                        Text(String(checkpoint.revision.prefix(12)))
                            .font(.system(size: 11).monospaced())
                        Text(checkpoint.boundary.rawValue)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(checkpoint.createdAt.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
