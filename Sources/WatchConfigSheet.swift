import SwiftUI
import Foundation

// MARK: - WatchConfigSheet

/// Configure Watch sheet — P0-1 from watch-gui-prd.md.
///
/// Loads current watch state via `watch.status`, lets the user edit every
/// P0 field, shows a cost preview, and applies via `watch.on` / `watch.off`.
/// Trigger (team row context menu / sidebar button) is wired in Phase 2.
struct WatchConfigSheet: View {
    let teamName: String
    let workingDirectory: String
    /// When set, pre-selects "Specific agent" mode and fills this agent name.
    /// Used by P0-3 "Watch This Agent" from the agent row context menu.
    var prefillTarget: String? = nil
    var onDismiss: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var enabled = false
    @State private var targetMode: TargetMode = .all
    @State private var specificAgent = ""
    @State private var stance = "critic"
    @State private var specSource: SpecSource = .preset
    @State private var specPreset = "general"
    @State private var specPath = ""
    @State private var specInline = ""
    @State private var intervalSecs = 300
    @State private var customIntervalText = ""
    @State private var watcherCLI = "claude"
    @State private var watcherModel = "sonnet"

    @State private var statusInfo: WatchStatusInfo? = nil
    @State private var availablePresets: [String] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    enum TargetMode { case all, specific }
    enum SpecSource { case preset, path, inline }

    // MARK: - Computed helpers

    private var resolvedSpec: String {
        switch specSource {
        case .preset: return "@.xm/watch/specs/\(specPreset).md"
        case .path:   return specPath.hasPrefix("@") ? specPath : "@\(specPath)"
        case .inline: return specInline
        }
    }

    private var resolvedTarget: String? {
        targetMode == .specific && !specificAgent.isEmpty ? specificAgent : nil
    }

    private var workerCount: Int { statusInfo?.workers.count ?? 0 }

    private var specIsEmpty: Bool {
        switch specSource {
        case .preset: return specPreset.isEmpty
        case .path:   return specPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .inline: return specInline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private let intervalPresets: [(label: String, secs: Int)] = [
        ("5m", 300), ("10m", 600), ("30m", 1800), ("Custom", -1),
    ]

    private var isCustomInterval: Bool {
        !intervalPresets.contains { $0.secs == intervalSecs }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Configure Watch")
                        .font(.headline)
                    Text(teamName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onDismiss(); dismiss() }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Loading watch status…")
                    .padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Enabled
                        Toggle("Enabled", isOn: $enabled)
                            .toggleStyle(.switch)
                            .font(.subheadline.bold())

                        if enabled { enabledControls }

                        // Cost preview always visible when enabled
                        if enabled { costPreview }

                        // Status panel
                        if let info = statusInfo { statusPanel(info) }

                        if let err = errorMessage {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Footer
            HStack {
                if enabled && specIsEmpty {
                    Label("Spec required before enabling watch", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onDismiss(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Saving…" : "Apply") { applyChanges() }
                    .disabled(isSaving || (enabled && specIsEmpty))
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear {
            loadAvailablePresets()
            loadStatus()
            // P0-3: pre-fill specific agent when opened via "Watch This Agent"
            if let target = prefillTarget, !target.isEmpty {
                targetMode = .specific
                specificAgent = target
            }
        }
    }

    // MARK: - Enabled Controls

    @ViewBuilder private var enabledControls: some View {
        Divider()

        // Target
        VStack(alignment: .leading, spacing: 6) {
            Text("Target").font(.subheadline.bold())
            Picker("", selection: $targetMode) {
                Text("All workers").tag(TargetMode.all)
                Text("Specific agent").tag(TargetMode.specific)
            }
            .pickerStyle(.segmented)

            if targetMode == .specific {
                let agents = statusInfo?.workers ?? []
                if agents.isEmpty {
                    TextField("Agent name (e.g. executor)", text: $specificAgent)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Agent", selection: $specificAgent) {
                        ForEach(agents, id: \.self) { Text($0).tag($0) }
                    }
                    .onAppear {
                        if specificAgent.isEmpty, let first = agents.first {
                            specificAgent = first
                        }
                    }
                }
            }
        }

        // Stance
        VStack(alignment: .leading, spacing: 6) {
            Text("Stance").font(.subheadline.bold())
            Picker("", selection: $stance) {
                Text("Critic").tag("critic")
                Text("Advisor").tag("advisor")
                Text("Pair").tag("pair")
            }
            .pickerStyle(.segmented)
        }

        // Spec
        VStack(alignment: .leading, spacing: 6) {
            Text("Spec").font(.subheadline.bold())
            Picker("", selection: $specSource) {
                Text("Preset").tag(SpecSource.preset)
                Text("Path").tag(SpecSource.path)
                Text("Inline").tag(SpecSource.inline)
            }
            .pickerStyle(.segmented)

            switch specSource {
            case .preset:
                Picker("Preset", selection: $specPreset) {
                    ForEach(availablePresets, id: \.self) { p in
                        Text(p.capitalized).tag(p)
                    }
                }
                .labelsHidden()

            case .path:
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(.secondary).font(.system(.body, design: .monospaced))
                    TextField(".xm/watch/specs/my-spec.md", text: $specPath)
                        .textFieldStyle(.roundedBorder)
                }

            case .inline:
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $specInline)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 72, maxHeight: 120)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    if specInline.isEmpty {
                        Text("Describe what the watcher should look for…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }

        // Interval
        VStack(alignment: .leading, spacing: 6) {
            Text("Interval").font(.subheadline.bold())
            HStack(spacing: 8) {
                ForEach(intervalPresets, id: \.secs) { preset in
                    let isSelected = preset.secs > 0
                        ? intervalSecs == preset.secs
                        : isCustomInterval
                    Button(preset.label) {
                        if preset.secs > 0 {
                            intervalSecs = preset.secs
                            customIntervalText = ""
                        }
                    }
                    .buttonStyle(.bordered)
                    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .disabled(preset.secs < 0)
                }
            }
            if isCustomInterval {
                HStack {
                    Text("Seconds:").font(.caption).foregroundStyle(.secondary)
                    TextField("300", text: $customIntervalText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: customIntervalText) { v in
                            if let n = Int(v), n > 0 { intervalSecs = n }
                        }
                }
            }
        }

        // CLI + Model
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watcher CLI").font(.subheadline.bold())
                Picker("", selection: $watcherCLI) {
                    ForEach(AgentRolePreset.supportedCLIs, id: \.self) { cli in
                        Text(cli.capitalized).tag(cli)
                    }
                }
                .labelsHidden()
                .onChange(of: watcherCLI) { _ in
                    let def = AgentRolePreset.defaultModel(for: watcherCLI)
                    watcherModel = def
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model").font(.subheadline.bold())
                Picker("", selection: $watcherModel) {
                    ForEach(AgentRolePreset.models(for: watcherCLI), id: \.self) { m in
                        Text(AgentRolePreset.modelDisplayLabel(m, for: watcherCLI)).tag(m)
                    }
                }
                .labelsHidden()
            }
        }

        Divider()
    }

    // MARK: - Cost Preview (PRD §Configure Watch Sheet > Cost Preview)

    @ViewBuilder private var costPreview: some View {
        let mins = intervalSecs / 60
        let remSecs = intervalSecs % 60
        let intervalLabel = remSecs == 0 ? "\(mins)m" : "\(intervalSecs)s"

        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if targetMode == .all {
                    if workerCount > 0 {
                        Text("All workers: \(workerCount) bounded check\(workerCount == 1 ? "" : "s") every \(intervalLabel)")
                            .font(.caption.bold())
                    } else {
                        Text("All workers: worker count resolved on first tick")
                            .font(.caption.bold())
                    }
                    Text("Each check reads up to 200 recent lines and 16,000 chars.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Checks run sequentially; long teams may skip overlapping ticks.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let name = specificAgent.isEmpty ? "<agent>" : specificAgent
                    Text("\(name): 1 bounded check every \(intervalLabel)")
                        .font(.caption.bold())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        } label: {
            Label("Cost Preview", systemImage: "gauge.with.dots.needle.33percent")
                .font(.caption.bold())
        }
    }

    // MARK: - Status Panel (PRD §Status Panel)

    @ViewBuilder
    private func statusPanel(_ info: WatchStatusInfo) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                statusRow("Enabled", info.enabled ? "Yes" : "No")
                statusRow("Target", info.target.flatMap { $0.isEmpty || $0 == "all" ? nil : $0 } ?? "All workers")
                if !info.workers.isEmpty {
                    statusRow("Workers", info.workers.joined(separator: ", "))
                    statusRow("Worker count", "\(info.workers.count)")
                }
                statusRow("Stance", info.stance.capitalized)
                statusRow("Interval", "\(info.intervalSecs / 60)m")
                statusRow("Running", info.running ? "Yes" : "No")
                if let t = info.lastTick { statusRow("Last tick", relativeTime(t)) }
                if let t = info.nextTick { statusRow("Next tick", relativeTime(t)) }
                statusRow("Drift count", "\(info.driftCount)")
                if let e = info.lastError, !e.isEmpty {
                    statusRow("Last error", e, isError: true)
                }
                if let w = info.duplicateNameWarning {
                    statusRow("⚠ Workers", w, isWarning: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        } label: {
            Label("Current Status", systemImage: "eye")
                .font(.caption.bold())
        }
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ value: String, isError: Bool = false, isWarning: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(isError ? AnyShapeStyle(Color.red) : isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(isError ? AnyShapeStyle(Color.red) : isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                .gridColumnAlignment(.leading)
        }
    }

    private func relativeTime(_ unixSecs: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(unixSecs))
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: - Load

    private func loadAvailablePresets() {
        let specsDir = (workingDirectory as NSString).appendingPathComponent(".xm/watch/specs")
        let defaultPresets = ["executor", "reviewer", "security", "general"]
        var found: [String] = []
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: specsDir) {
            found = contents
                .filter { $0.hasSuffix(".md") }
                .map { ($0 as NSString).deletingPathExtension }
                .sorted()
        }
        let merged = found.isEmpty ? defaultPresets : found
        availablePresets = merged
        if !merged.contains(specPreset), let first = merged.first {
            specPreset = first
        }
    }

    private func loadStatus() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let params: [String: Any] = [
                "team_id": teamName,
                "working_directory": workingDirectory,
            ]
            let raw = TermMeshDaemon.shared.rpcCallRaw(method: "watch.status", params: params)
            let info = raw.flatMap { WatchStatusInfo(resultJSON: $0, teamId: teamName) }
            DispatchQueue.main.async {
                if let info { applyStatus(info) }
                isLoading = false
            }
        }
    }

    private func applyStatus(_ info: WatchStatusInfo) {
        statusInfo = info
        enabled = info.enabled
        stance = info.stance.isEmpty ? "critic" : info.stance
        intervalSecs = max(info.intervalSecs, 60)
        watcherCLI = info.cli.isEmpty ? "claude" : info.cli
        watcherModel = info.model.isEmpty ? AgentRolePreset.defaultModel(for: watcherCLI) : info.model

        let t = info.target ?? ""
        if !t.isEmpty && t != "all" {
            targetMode = .specific
            specificAgent = t
        } else {
            targetMode = .all
        }

        let s = info.spec
        if s.hasPrefix("@") {
            let path = String(s.dropFirst())
            if path.contains(".xm/watch/specs/") && path.hasSuffix(".md") {
                let base = (path as NSString).lastPathComponent
                let name = (base as NSString).deletingPathExtension
                specSource = .preset
                specPreset = name
            } else {
                specSource = .path
                specPath = path
            }
        } else if !s.isEmpty {
            specSource = .inline
            specInline = s
        }
    }

    // MARK: - Apply

    private func applyChanges() {
        isSaving = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let err = enabled ? callWatchOn() : callWatchOff()
            DispatchQueue.main.async {
                isSaving = false
                if let err {
                    errorMessage = err
                } else {
                    onDismiss()
                    dismiss()
                }
            }
        }
    }

    private func callWatchOn() -> String? {
        var params: [String: Any] = [
            "team_id": teamName,
            "cli": watcherCLI,
            "model": watcherModel,
            "stance": stance,
            "working_directory": workingDirectory,
            "interval_secs": intervalSecs,
            "spec": resolvedSpec,
        ]
        if let target = resolvedTarget {
            params["target"] = target
        }
        // Pass app socket so daemon can resolve GUI team workers via team.status.
        let appSock = SocketControlSettings.socketPath()
        if !appSock.isEmpty {
            params["app_socket_path"] = appSock
        }
        guard let raw = TermMeshDaemon.shared.rpcCallRaw(method: "watch.on", params: params) else {
            return "watch.on failed — daemon not reachable"
        }
        // surface any RPC-level error message
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errObj = json["error"],
           let errMsg = (errObj as? [String: Any])?["message"] as? String ?? errObj as? String {
            return errMsg
        }
        return nil
    }

    private func callWatchOff() -> String? {
        let params: [String: Any] = ["team_id": teamName]
        guard TermMeshDaemon.shared.rpcCallRaw(method: "watch.off", params: params) != nil else {
            return "watch.off failed — daemon not reachable"
        }
        return nil
    }
}

// MARK: - WatchStatusInfo

/// Parsed result of `watch.status`. Gracefully handles missing fields
/// (e.g. `workers` before R1 backend improvement).
struct WatchStatusInfo {
    let teamId: String
    let enabled: Bool
    let target: String?
    let workers: [String]
    let stance: String
    let spec: String
    let intervalSecs: Int
    let cli: String
    let model: String
    let running: Bool
    let driftCount: Int
    let lastTick: Int?
    let nextTick: Int?
    let lastError: String?
    /// R3: set when the workers list contained duplicates (deduped by daemon).
    let duplicateNameWarning: String?

    /// Parse from the JSON string returned by `rpcCallRaw("watch.status", ...)`.
    /// The result is `{"status":"ok","watch":{...}}` (single team) or
    /// `{"status":"ok","watches":[...]}` (all teams).
    init?(resultJSON: String, teamId: String) {
        guard let data = resultJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let obj: [String: Any]?
        if let watch = root["watch"] as? [String: Any] {
            obj = watch
        } else if let watches = root["watches"] as? [[String: Any]] {
            obj = watches.first { ($0["team_id"] as? String) == teamId }
        } else {
            return nil
        }
        guard let w = obj else { return nil }

        self.teamId       = teamId
        self.enabled      = w["enabled"] as? Bool ?? false
        self.target       = w["target"] as? String
        self.workers      = w["workers"] as? [String] ?? []   // R1: may be absent until daemon update
        self.stance       = w["stance"] as? String ?? "critic"
        self.spec         = w["spec"] as? String ?? ""
        self.intervalSecs = w["interval_secs"] as? Int ?? 300
        self.cli          = w["cli"] as? String ?? "claude"
        self.model        = w["model"] as? String ?? "sonnet"
        self.running      = (w["running"] ?? w["in_flight"]) as? Bool ?? false
        self.driftCount   = w["drift_count"] as? Int ?? 0
        self.lastTick              = w["last_tick"] as? Int
        self.nextTick              = w["next_tick"] as? Int
        self.lastError             = w["last_error"] as? String
        self.duplicateNameWarning  = w["duplicate_name_warning"] as? String
    }
}

// MARK: - Preview

#if DEBUG
struct WatchConfigSheet_Previews: PreviewProvider {
    static var previews: some View {
        WatchConfigSheet(
            teamName: "standard",
            workingDirectory: "/Users/jinwoo/work/project/term-mesh"
        )
        .frame(width: 480, height: 600)
    }
}
#endif
