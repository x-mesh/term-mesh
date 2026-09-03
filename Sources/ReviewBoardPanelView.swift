import SwiftUI

@MainActor
struct ReviewBoardPanelView: View {
    @ObservedObject var viewModel: ReviewBoardViewModel
    let onClose: () -> Void

    /// The reason typed into the reject box. Held here rather than in the view
    /// model because it is a half-finished sentence, not board state — losing
    /// it when the panel closes is correct.
    @State private var rejectReason = ""
    @State private var isRejecting = false

    /// Folded state for the two settings sections below the work.
    ///
    /// `@AppStorage`, not `@State` seeded from defaults: the board is mounted
    /// once per window, and a `@State` seed is read only when a view identity
    /// first appears. Two open windows would drift apart and never resync,
    /// with the last writer deciding what a third window sees.
    ///
    /// The defaults differ on purpose. Delegation is what someone sets before
    /// handing out the first task, so a Project that has never been configured
    /// must not hide it. Auto Pilot starts folded — see its own header, which
    /// keeps the boundary sentence visible either way.
    @AppStorage(ReviewBoardSettings.delegationExpandedKey)
    private var delegationExpanded = true
    @AppStorage(ReviewBoardSettings.autoPilotExpandedKey)
    private var autoPilotExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.tasks.isEmpty && viewModel.pendingMergeQueue.isEmpty {
                        emptyState
                    } else {
                        // Above the tasks: the queue is what gates work
                        // actually landing, so it should not need scrolling
                        // past a long task list to find.
                        if !viewModel.pendingMergeQueue.isEmpty {
                            mergeQueueList
                        }
                        if !viewModel.tasks.isEmpty {
                            taskList
                        }
                        if let task = viewModel.selectedTask {
                            taskDetails(task)
                        }
                    }
                    // Settings live below the work, and this one stays visible
                    // on an empty board on purpose: it is what you set before
                    // handing out the first task, and an idle roster is a state
                    // with no rows by definition.
                    //
                    // The level and the evidence for it are one section, not
                    // two. "Delegated" is a claim; "4 workers, none working" is
                    // whether it is happening, and separating them put the
                    // reason to change a setting on a different card from the
                    // setting.
                    delegationSection
                    // Last: it is a setting and a log, not the work. It should
                    // be findable, not in the way of the row someone opened the
                    // board to read.
                    autoPilotSection
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("reviewBoard.panel")
        .accessibilityElement(children: .contain)
        .onAppear {
            viewModel.refresh()
            viewModel.reloadAutoPilotJournals()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist.checked")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text("Review Board")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh Review Board")
            .accessibilityLabel("Refresh Review Board")

            Button(action: onClose) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Close Review Board")
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close Review Board")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusPills(viewModel.statusBadges(for: nil))
            Text("Nothing assigned yet")
                .font(.system(size: 13, weight: .medium))
            // What it used to say — "Task board data has not reported review
            // work yet" — described the plumbing and left the reader to guess
            // whether something was broken. Nothing is: the board shows work
            // that has been handed to someone, and on a new project nobody has
            // been handed anything. Say where the rows come from.
            Text("Rows appear here when the leader gives an agent a task. "
                 + "Ask it in the leader pane, or run `tm-agent delegate` yourself.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("No review tasks yet")
    }

    private var mergeQueueList: some View {
        let items = viewModel.pendingMergeQueue
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Merge Queue (\(items.count))")
            ForEach(items) { item in
                mergeQueueRow(item)
            }
        }
        .accessibilityIdentifier("reviewBoard.mergeQueue")
    }

    private func mergeQueueRow(_ item: ReviewBoardMergeQueueItem) -> some View {
        // Selecting the queue entry selects the task it gates — the entry
        // carries no detail of its own worth a second detail pane.
        Button {
            viewModel.selectTask(id: item.taskDisplayID)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: item.isFailed ? "arrow.triangle.merge" : "clock")
                        .foregroundColor(item.isFailed ? .red : .secondary)
                        .accessibilityHidden(true)
                    Text(ReviewBoardText.splitDirective(
                        viewModel.taskTitle(forMergeQueueItem: item)
                    ).rest)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(item.isFailed ? .red : .secondary)
                }
                if let lastError = item.lastError {
                    Text(lastError)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text("approved by \(item.approvedBy)")
                    // The fix's own finish time. This was the raw ISO stamp,
                    // which answers "when" only after the reader does timezone
                    // arithmetic in their head.
                    if let approvedAt = item.approvedAt.flatMap(ReviewBoardText.clockTime) {
                        Text("·")
                        Text(approvedAt)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 4)
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        item.isFailed ? Color.red.opacity(0.5) : Color(nsColor: .separatorColor),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Merge queue entry, \(item.status), approved by \(item.approvedBy)")
        .accessibilityIdentifier("reviewBoard.mergeQueue.\(item.id)")
    }

    private var taskList: some View {
        // Read once, not once per row. `selectedTask` searches the task list,
        // so asking each row whether it is the selected one made drawing the
        // list O(N²) — and every row also asked `isWorking`, which walked every
        // team's agents. Both are settled here and handed down as values.
        let selectedID = viewModel.selectedTask?.id
        let working = viewModel.workingAssignees
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Tasks")
            ForEach(viewModel.tasks) { task in
                ReviewBoardTaskRow(
                    task: task,
                    isSelected: selectedID == task.id,
                    isWorking: task.assignee.map(working.contains) ?? false,
                    onSelect: { viewModel.selectTask(id: task.id) },
                    onReveal: { viewModel.revealPane(for: task) }
                )
                .equatable()
            }
        }
    }

/// One task card, isolated behind `Equatable`.
///
/// The board republishes on every roster tick and on every task-board
/// revision, and with ten agents working that is often. Without this shell the
/// whole list re-evaluated each time — and each row's own body then re-read
/// `selectedTask` (a search) and `isWorking` (a walk of every team's agents),
/// so redrawing an N-task board cost O(N²) work for a change that usually
/// moved one row's status string.
private struct ReviewBoardTaskRow: View, Equatable {
    let task: ReviewBoardTask
    let isSelected: Bool
    let isWorking: Bool
    let onSelect: () -> Void
    let onReveal: () -> Void

    /// The closures are rebuilt by the parent on every pass and capture nothing
    /// that changes what this card draws, so comparing them would defeat the
    /// shell entirely.
    /// `nonisolated` because the panel is `@MainActor` and this type inherits
    /// that, while `Equatable` is not actor-isolated. Everything compared here
    /// is `Sendable`, so reading it off the main actor is safe — without this
    /// the conformance is a warning today and an error under Swift 6.
    nonisolated static func == (lhs: ReviewBoardTaskRow, rhs: ReviewBoardTaskRow) -> Bool {
        lhs.task == rhs.task
            && lhs.isSelected == rhs.isSelected
            && lhs.isWorking == rhs.isWorking
    }

    var body: some View {
        let parts = ReviewBoardText.splitDirective(task.title)
        return Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let directive = parts.directive {
                        // The constraint the agent was handed, kept as a mark
                        // so it stops being the headline of every card.
                        Text(directive)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundColor(.secondary)
                    }
                    Text(parts.rest)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    // "working" beats the board's own word when the agent's
                    // pane is printing: `assigned` is true but says nothing
                    // about whether anything is happening.
                    if isWorking {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                            Text("working")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                    } else {
                        Text(task.status.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(task.teamName)
                    if let assignee = task.assignee {
                        Text("·")
                        Text(assignee)
                    }
                    // When it finished, on the rows that have finished. A
                    // board with no time on it cannot answer "is this still
                    // moving?" — the question it exists to answer.
                    if let finished = task.finishedAt.flatMap(ReviewBoardText.clockTime) {
                        Text("·")
                        Text("done \(finished)")
                            .monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    Text("P\(task.priority)")
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        // One click picks the task, two go to it — the same pair of meanings
        // a file list has, so nothing has to be explained.
        .simultaneousGesture(TapGesture(count: 2).onEnded(onReveal))
        .accessibilityLabel("\(task.title), \(task.status), priority \(task.priority)")
        .accessibilityIdentifier("reviewBoard.task.\(task.id)")
    }
}
}

extension ReviewBoardPanelView {
    private func taskDetails(_ task: ReviewBoardTask) -> some View {
        let digest = viewModel.digest(for: task)
        return VStack(alignment: .leading, spacing: 12) {
            statusPills(viewModel.statusBadges(for: task))

            // The way across to where the work is actually happening. Only
            // offered when there is a local pane to go to — work on a peer is
            // real, but not something this window can show.
            if let assignee = task.assignee, viewModel.paneLocation(for: task) != nil {
                Button {
                    viewModel.revealPane(for: task)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right.to.line")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Show \(assignee)'s pane")
                            .font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reviewBoard.task.showPane")
                .help("Switch to the pane running this task")
            }
            // Directly under the badges, because it is the answer to the
            // question the badges raise. Buried among eight "not reported"
            // rows it read as though nothing had happened at all.
            if let reason = task.blockedReason, !reason.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    Text(reason)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(9)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Stopped because: \(reason)")
                .accessibilityIdentifier("reviewBoard.task.reason")
            }
            if let finished = task.finishedAt.flatMap(ReviewBoardText.clockTime) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text("Finished \(finished)")
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .accessibilityIdentifier("reviewBoard.task.finishedAt")
            }
            if task.status == "review_ready" {
                reviewSection(task)
            }
            // The instruction in full — directive and all. The row above shows
            // the constraint as a mark and drops it from the text; here the
            // instruction IS the task for work delegated from a pane, so it is
            // shown as the agent received it.
            if !task.title.isEmpty {
                Text(task.title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // What the agent reported comes first and in its own words. The
            // digest under it is a reading of the task for merge and CI facts,
            // which for work that ends in an answer rather than a pull request
            // finds nothing — so a finished task with its result stored still
            // said "nothing reported yet".
            let report = ReviewBoardAgentReport(result: task.result)
            // A result with no header is still a result. Work carried back
            // from a peer arrives as the agent's summary alone — the header it
            // reported with was consumed getting it here — and requiring one
            // to render anything left the board saying nothing was reported
            // while holding the answer.
            if report == nil,
               let plain = task.result?.trimmingCharacters(in: .whitespacesAndNewlines),
               !plain.isEmpty {
                Text(plain)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("reviewBoard.task.report")
            }
            if let report, !report.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let body = report.body {
                        Text(body)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(report.presentFields, id: \.title) { field in
                        factSection(field.title, systemImage: field.systemImage, text: field.text)
                    }
                }
                .accessibilityIdentifier("reviewBoard.task.report")
            }

            let facts = digest.presentFacts
            if facts.isEmpty {
                let showedSomething = (report.map { !$0.isEmpty } ?? false)
                    || (report == nil && !(task.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !showedSomething {
                    // Said once, plainly, instead of eight times in eight boxes.
                    Text("Nothing reported yet — the agent has not filed a result.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.secondary.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(facts, id: \.title) { fact in
                    factSection(fact.title, systemImage: fact.systemImage, text: fact.text)
                }
            }
        }
    }

    private func statusPills(_ statuses: [ReviewBoardStatus]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { statusPillItems(statuses) }
            VStack(alignment: .leading, spacing: 6) { statusPillItems(statuses) }
        }
    }

    private func statusPillItems(_ statuses: [ReviewBoardStatus]) -> some View {
        ForEach(statuses, id: \.self) { status in
            Label(status.title, systemImage: status.systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(status.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(Capsule())
                .accessibilityLabel(status.accessibilityLabel)
        }
    }

    private func factSection(_ title: String, systemImage: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(text)")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Delegation

    /// A folding header whose collapsed line carries the summary.
    ///
    /// Tabs were the other candidate and they hide the wrong half. The level
    /// is a claim ("delegate serial work") and the evidence is whether it is
    /// happening ("4 workers, none working"); a tab puts the reason to change
    /// a setting behind a control you have to find first. Folding keeps the
    /// verdict on the header instead, so collapsing costs nothing but height.
    private func foldHeader<Trailing: View>(
        _ title: String,
        isExpanded: Bool,
        summary: Text?,
        toggle: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    sectionTitle(title)
                    if !isExpanded, let summary {
                        summary
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
            trailing()
        }
    }

    /// The switch, the boundary it works inside, and what it has done —
    /// one section, because none of the three answers anything alone.
    @ViewBuilder
    private var delegationSection: some View {
        if viewModel.delegation != nil || viewModel.collaboration != nil {
            VStack(alignment: .leading, spacing: 8) {
                foldHeader(
                    "Delegation",
                    isExpanded: delegationExpanded,
                    summary: delegationSummary,
                    toggle: { delegationExpanded.toggle() }
                ) {
                    // Folding must never hide the only way out of a broken
                    // state, so the repair rides the header at every size.
                    if needsCollaborationRepair {
                        repairButton
                    } else if delegationExpanded, let panel = viewModel.delegation {
                        Text(panel.teamName)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // Outside the fold, next to the button that produces it.
                // Keeping the Repair button on the header while its only
                // report lived in the body meant a failed repair said nothing
                // at all: the spinner stopped, the state stayed broken, and
                // the reason was behind a disclosure.
                if let repairResult = collaborationRepairResult {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: repairResult.symbolName)
                            .accessibilityHidden(true)
                        Text(repairResult.message)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(repairResult.title + ". " + repairResult.message)
                    .accessibilityIdentifier("reviewBoard.repairMessage")
                }

                if delegationExpanded {
                    delegationControls
                    collaborationEvidence
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04))
            )
            .accessibilityIdentifier("reviewBoard.delegation")
        }
    }

    /// What the folded header has to say on one line.
    ///
    /// The verdict leads. At the board's default width the line truncates
    /// after roughly two clauses, and putting the level first meant the tail
    /// that got cut was "no dispatch" — the one clause that decides whether
    /// this section is worth opening.
    private var delegationSummary: Text? {
        let collaboration = viewModel.collaboration
        guard let panel = viewModel.delegation else {
            return collaboration.map { Text($0.shortState) }
        }
        var text = Text("")
        if let collaboration {
            text = Text(collaboration.shortState) + Text(" · ")
        }
        text = text + Text(panel.level.displayName)
            + Text(" · \(panel.workerCount) workers")
        return text
    }

    private var needsCollaborationRepair: Bool {
        guard let panel = viewModel.collaboration else { return false }
        return panel.state != .healthy && panel.workerCount > 0
    }

    private var collaborationRepairResult: (title: String, message: String, symbolName: String)? {
        switch viewModel.collaborationRepairOutcome {
        case .verified(let message):
            return ("Verified", message, "checkmark.circle.fill")
        case .failed(let message):
            return ("Failed", message, "exclamationmark.triangle.fill")
        case .idle, .running:
            return nil
        }
    }

    private var repairButton: some View {
        Button {
            Task { await viewModel.repairCollaboration() }
        } label: {
            if viewModel.collaborationRepairInFlight {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Repairing…")
                }
            } else {
                Text("Repair collaboration")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(viewModel.collaborationRepairInFlight)
        .help(collaborationRepairHelp)
        .accessibilityLabel(
            viewModel.collaborationRepairInFlight ? "Repairing collaboration" : "Repair collaboration"
        )
        .accessibilityHint(collaborationRepairHelp)
        .accessibilityIdentifier("reviewBoard.repairCollaboration")
    }

    private var collaborationRepairHelp: String {
        "Refreshes routes, preserves live processes, repairs dead panes, and verifies leader control."
    }

    /// How much of this Project the leader hands to workers.
    ///
    /// Same shape as Auto Pilot below, for the same reason: a control that
    /// changes what an agent does unattended has to state what it will do, not
    /// just offer a switch. So the level, the wave ceiling and the roster are
    /// all on screen together — "delegated" means nothing without knowing how
    /// many workers there are to delegate to.
    @ViewBuilder
    private var delegationControls: some View {
        if let panel = viewModel.delegation {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(
                    get: { panel.level },
                    set: { viewModel.setDelegationLevel($0) }
                )) {
                    ForEach(ProjectDelegationLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reviewBoard.delegationLevel")

                Text(panel.level.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let pending = panel.pending {
                    Text("Current: \(Text(panel.level.displayName)) · Next request: \(Text(pending.displayName))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("Max parallel workers")
                        .font(.system(size: 11))
                    Spacer(minLength: 8)
                    Stepper(
                        value: Binding(
                            get: { panel.options.maxParallelWorkers },
                            set: { viewModel.setMaxParallelWorkers($0) }
                        ),
                        in: ProjectExecutionOptions.workerBounds
                    ) {
                        Text("\(panel.options.maxParallelWorkers)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .accessibilityIdentifier("reviewBoard.maxParallelWorkers")
                }

                Toggle(isOn: Binding(
                    get: { panel.options.injectDirective },
                    set: { viewModel.setInjectDirective($0) }
                )) {
                    Text("State the floor each turn")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityIdentifier("reviewBoard.injectDirective")

                rosterText(panel)
                    .font(.system(size: 11))
                    .foregroundColor(panel.everyWorkerIdle ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("reviewBoard.workDistribution")
        }
    }

    /// Whether the level above is actually happening, as the turn log recorded
    /// it. Subordinate to the control on purpose: it is the reason to change
    /// the setting, not a second thing to configure.
    @ViewBuilder
    private var collaborationEvidence: some View {
        if let panel = viewModel.collaboration {
            VStack(alignment: .leading, spacing: 5) {
                Divider()
                    .padding(.vertical, 1)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: panel.symbolName)
                        .accessibilityHidden(true)
                    Text(panel.title)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(panel.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Three numbers on one line read as one fact, and they are
                // not: the roster is what exists now, the other two total a
                // bounded history. Separating them is what stops "no dispatch"
                // and "4 dispatches" from looking like a contradiction.
                Text("Roster now · \(panel.workerCount) workers")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("Recent history · \(panel.dispatchCount) dispatches · \(panel.completionCount) completed")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                if let lastActivity = panel.lastActivity {
                    Text(
                        "Newest record "
                            + (ReviewBoardText.clockTime(lastActivity) ?? lastActivity)
                    )
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityIdentifier("reviewBoard.collaboration")
        }
    }

    /// The roster, and whether any of it is doing anything.
    ///
    /// An idle roster is the symptom this whole control exists for — the
    /// leader working alone while workers sit there — so it is stated in
    /// words rather than left to be inferred from a count.
    ///
    /// Returns `Text`, not `String`: `Text(someString)` is the verbatim
    /// initializer and never reaches the string catalog, which is how the rest
    /// of this feature's UI stayed English in a Korean app.
    private func rosterText(_ panel: ReviewBoardViewModel.DelegationPanel) -> Text {
        guard panel.workerCount > 0 else {
            return Text("No workers on this Project yet, so every route is direct.")
        }
        if panel.everyWorkerIdle {
            return Text("\(panel.workerCount) workers, none working right now.")
        }
        return Text("\(panel.workerCount) workers · \(panel.workingCount) working, \(panel.idleCount) idle.")
    }

    /// All three together on purpose. A toggle on its own asks someone to arm
    /// unattended merging without telling them how far it can go, and a log on
    /// its own leaves "why is this still sitting here" unanswered.
    private var autoPilotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            foldHeader(
                "Auto Pilot",
                isExpanded: autoPilotExpanded,
                // The boundary, not just the state. This section folds by
                // default and its switch stays on the header, so wording the
                // summary "off" would have put arming unattended merging one
                // click away with the ceiling branch and the per-session cap
                // never on screen.
                summary: Text(boundarySentence),
                toggle: { autoPilotExpanded.toggle() }
            ) {
                // The switch stays reachable folded. Arming unattended merging
                // is the one thing here worth a click without reading first;
                // the boundary it works inside is one disclosure away.
                Toggle("", isOn: Binding(
                    get: { viewModel.autoPilot.isEnabled },
                    set: { viewModel.setAutoPilotEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Auto Pilot")
            }

            if autoPilotExpanded {
                // The same sentence the folded header truncates, in full.
                Text(boundarySentence)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !viewModel.autoPilotUndoPoints.isEmpty {
                    undoList
                }
                if let message = viewModel.undoMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !viewModel.autoPilotAudit.isEmpty {
                    auditList
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04))
        )
        .accessibilityIdentifier("reviewBoard.autoPilot")
    }

    private var boundarySentence: String {
        let policy = viewModel.autoPilot
        let limits = "Merges only into \(policy.ceilingBranch), never pushes, "
            + "at most \(policy.maxAutoMerges) merges per session."
        return policy.isEnabled
            ? limits
            : "Off. When on: \(limits.prefix(1).lowercased())\(limits.dropFirst())"
    }

    private var undoList: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Undo")
            // `id: \.sha` collided: a failed merge leaves the branch where it
            // was, so the next point records the same pre-merge sha.
            ForEach(viewModel.autoPilotUndoPoints.prefix(3)) { point in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(point.branch) → \(point.sha.prefix(8))")
                            .font(.system(size: 11, design: .monospaced))
                        Text("before merging \(point.taskID)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button("Put back") {
                        Task { await viewModel.undoAutoMerge(point) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.undoInFlight)
                    .help("Move \(point.branch) back to where it was before this merge")
                }
            }
        }
    }

    private var auditList: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Recent decisions")
            ForEach(viewModel.autoPilotAudit.prefix(6), id: \.atMS) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: entry.wasApproved
                          ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundColor(entry.wasApproved ? .green : .secondary)
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text(entry.reason)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Reviewing

    /// The decision, under everything that informs it.
    ///
    /// Only for `review_ready`: the coordinator refuses an approval for any
    /// other status, so offering the button elsewhere would be offering a
    /// click that returns an error.
    @ViewBuilder
    private func reviewSection(_ task: ReviewBoardTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let review = viewModel.review, review.taskID == task.rawID {
                if let patch = review.patch {
                    changedFiles(patch)
                    patchView(patch)
                }
                if let blocker = review.blocker {
                    // Why the buttons are not there. A board that simply omits
                    // them leaves the reader to guess whether the feature is
                    // missing or the task is.
                    Label(blocker, systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("reviewBoard.review.blocker")
                }
                if review.canAct { decisionControls() }
            } else if viewModel.actionInFlight {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the change…").font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            }
            if let error = viewModel.actionError {
                // The coordinator's own words: `snapshot evidence mismatch`
                // and `stale_fencing_token` are the two a reviewer has to be
                // able to tell apart.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reviewBoard.review.error")
            }
        }
        .task(id: task.rawID) { await viewModel.loadReview(for: task) }
    }

    @ViewBuilder
    private func changedFiles(_ patch: ReviewBoardEvidence.Patch) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle("\(patch.files.count) changed")
            ForEach(patch.files, id: \.path) { file in
                HStack(spacing: 6) {
                    Text(file.kind.prefix(1).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 11)
                        .foregroundColor(color(for: file.kind))
                    Text(file.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    Text("+\(file.add)").foregroundColor(.green)
                    Text("−\(file.del)").foregroundColor(.red)
                }
                .font(.system(size: 10).monospacedDigit())
            }
        }
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "added": return .green
        case "deleted": return .red
        case "renamed", "copied": return .orange
        default: return .secondary
        }
    }

    @ViewBuilder
    private func patchView(_ patch: ReviewBoardEvidence.Patch) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Its own scroll view with a fixed height: the panel is one long
            // ScrollView, and a patch dropped into it would push everything
            // else — including the buttons — off the bottom.
            ScrollView([.horizontal, .vertical]) {
                Text(patch.text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .accessibilityIdentifier("reviewBoard.review.patch")
            if patch.isTruncated {
                // The digest still covers the whole patch; only the display is
                // shortened. Saying so keeps "I read it" honest.
                Text("Shown up to \(ReviewBoardEvidence.displayByteLimit / 1024)KB — the digest covers all of it.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func decisionControls() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Approve") {
                    Task { await viewModel.approve() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reviewBoard.review.approve")

                Button(isRejecting ? "Cancel" : "Reject") {
                    isRejecting.toggle()
                    rejectReason = ""
                }
                .accessibilityIdentifier("reviewBoard.review.reject")

                Spacer(minLength: 0)
                if viewModel.actionInFlight { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 11))
            .disabled(viewModel.actionInFlight)

            if isRejecting {
                // The reason is required by the coordinator and is what the
                // next attempt is briefed with, so the button stays off until
                // there is one.
                TextField("Why it goes back", text: $rejectReason, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .lineLimit(2...4)
                Button("Send back") {
                    Task {
                        if await viewModel.reject(reason: rejectReason) {
                            isRejecting = false
                            rejectReason = ""
                        }
                    }
                }
                .font(.system(size: 11))
                .disabled(
                    viewModel.actionInFlight
                        || rejectReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("reviewBoard.review.rejectConfirm")
            }
        }
    }
}
