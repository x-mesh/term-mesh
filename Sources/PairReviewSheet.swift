import SwiftUI

struct PairReviewTarget: Identifiable {
    let projectLabel: String
    let teamName: String
    let workingDirectory: String
    let leaderCLI: String
    let baseRef: String?
    var id: String { teamName }
}

/// A user-triggered, exactly-once review. It never enables or edits Watch.
struct PairReviewSheet: View {
    let target: PairReviewTarget
    var onDismiss: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var scope = "current-task"
    @State private var lens = "general"
    @State private var customInstructions = ""
    @State private var reviewerCLI = "codex"
    @State private var reviewerModel = AgentRolePreset.defaultModel(for: "codex")
    @State private var isStarting = false
    @State private var reviewID: String?
    @State private var run: PairReviewRunInfo?
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    private var isRunning: Bool { reviewID != nil && run?.status != "completed" && run?.status != "failed" }
    private var isBusy: Bool { isStarting || isRunning }
    private var instructions: String {
        if lens == "custom" { return customInstructions.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch lens {
        case "security": return "Find exploitable security, privacy, trust-boundary, secret-handling, and authorization defects. Report only evidence-backed findings."
        case "tests": return "Find missing or incorrect tests, untested failure paths, flaky assumptions, and behavior that the current verification cannot prove."
        default: return "Review correctness, regressions, scope adherence, and maintainability. Prioritize concrete defects over style preferences."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair Review").font(.headline)
                    Text(target.projectLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { close() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let run { resultPanel(run) } else { configuration }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(isStarting ? "Freezing snapshot…" : "Reviewing a frozen snapshot…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if run == nil {
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button("Run Pair Review") { startReview() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                        .disabled(isBusy || instructions.isEmpty)
                        .accessibilityIdentifier("pairReview.run")
                } else {
                    Button("Run Another Review") { reviewID = nil; run = nil; errorMessage = nil }
                        .disabled(isRunning)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 590)
        .onAppear { reviewerModel = AgentRolePreset.defaultModel(for: "codex") }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder private var configuration: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scope").font(.subheadline.bold())
                Picker("Scope", selection: $scope) {
                    Text("Current task").tag("current-task")
                    Text("Current changes").tag("current-changes")
                    Text("Branch diff").tag("branch-diff")
                }.labelsHidden().pickerStyle(.segmented)
                Text(scopeHelp).font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Lens").font(.subheadline.bold())
                Picker("Lens", selection: $lens) {
                    Text("General").tag("general")
                    Text("Security").tag("security")
                    Text("Tests").tag("tests")
                    Text("Custom").tag("custom")
                }.labelsHidden().pickerStyle(.segmented)
                if lens == "custom" {
                    TextEditor(text: $customInstructions)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 78)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                        .accessibilityLabel("Custom review instructions")
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reviewer").font(.subheadline.bold())
                    Text("Codex").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Read-only sandbox").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.subheadline.bold())
                    Picker("Reviewer model", selection: $reviewerModel) {
                        ForEach(AgentRolePreset.models(for: reviewerCLI), id: \.self) { model in
                            Text(AgentRolePreset.modelDisplayLabel(model, for: reviewerCLI)).tag(model)
                        }
                    }.labelsHidden()
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("One fresh, read-only review", systemImage: "checkmark.shield")
                        .font(.caption.bold())
                    Text("The selected scope is frozen when you run it. The reviewer is instructed not to edit, no changes are applied automatically, and continuous Watch stays unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
    }

    private var scopeHelp: String {
        switch scope {
        case "current-changes": return "Reviews the uncommitted diff captured when the review starts."
        case "branch-diff": return "Reviews the branch diff from \(target.baseRef ?? "develop") captured when the review starts."
        default: return "Reviews the leader’s last 200 terminal lines captured when the review starts."
        }
    }

    @ViewBuilder private func resultPanel(_ info: PairReviewRunInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(info.statusLabel, systemImage: info.statusIcon)
                    .font(.subheadline.bold())
                    .foregroundStyle(info.statusColor)
                Spacer()
                if let duration = info.durationMS { Text(String(format: "%.1fs", Double(duration) / 1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Text("\(info.cli.capitalized) · \(info.model) · \(info.scopeLabel) · \(info.lens.capitalized)")
                .font(.caption).foregroundStyle(.secondary)
            if let verdict = info.verdict {
                Text(verdict).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            if let error = info.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func startReview() {
        guard !isBusy else { return }
        isStarting = true
        errorMessage = nil
        var params: [String: Any] = [
            "team_id": target.teamName, "scope": scope, "lens": lens,
            "cli": reviewerCLI, "model": reviewerModel, "spec": instructions,
            "working_directory": target.workingDirectory, "reply_timeout_secs": 180,
        ]
        if let baseRef = target.baseRef { params["base_ref"] = baseRef }
        if let path = CLIPathSettings.resolvedPath(for: reviewerCLI) { params["cli_path"] = path }
        let appSocket = SocketControlSettings.socketPath()
        if !appSocket.isEmpty { params["app_socket_path"] = appSocket }
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = TermMeshDaemon.shared.rpcCallRaw(method: "pair.review.start", params: params)
            let result = raw.flatMap(PairReviewStartInfo.init)
            DispatchQueue.main.async {
                isStarting = false
                guard let result else { errorMessage = "Couldn’t start Pair Review. The daemon may be unavailable."; return }
                guard result.started, let id = result.reviewID else { errorMessage = result.reason ?? "Pair Review was rejected."; return }
                reviewID = id
                poll(id)
            }
        }
    }

    private func poll(_ id: String) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                let raw = await Task.detached { TermMeshDaemon.shared.rpcCallRaw(method: "pair.review.status", params: ["review_id": id]) }.value
                guard let info = raw.flatMap(PairReviewRunInfo.init) else { continue }
                await MainActor.run { run = info }
                if info.status != "running" { return }
            }
        }
    }

    private func close() { pollTask?.cancel(); onDismiss(); dismiss() }
}

private struct PairReviewStartInfo {
    let started: Bool; let reviewID: String?; let reason: String?
    init?(json: String) {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        started = value["started"] as? Bool ?? false; reviewID = value["review_id"] as? String; reason = value["reason"] as? String
    }
}

private struct PairReviewRunInfo {
    let status, scope, lens, cli, model: String
    let durationMS: Int?; let verdict, error: String?
    var scopeLabel: String { scope.split(separator: "-").map { $0.capitalized }.joined(separator: " ") }
    var statusLabel: String { status == "running" ? "Reviewing snapshot" : status == "completed" ? "Review complete" : "Review failed" }
    var statusIcon: String { status == "running" ? "hourglass" : status == "completed" ? "checkmark.circle.fill" : "xmark.octagon.fill" }
    var statusColor: Color { status == "running" ? .secondary : status == "completed" ? .green : .red }
    init?(json: String) {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let status = value["status"] as? String else { return nil }
        self.status = status; scope = value["scope"] as? String ?? "current-task"; lens = value["lens"] as? String ?? "general"
        cli = value["cli"] as? String ?? ""; model = value["model"] as? String ?? ""
        durationMS = value["duration_ms"] as? Int; verdict = value["verdict"] as? String; error = value["error"] as? String
    }
}
