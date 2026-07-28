import SwiftUI

@MainActor
struct ReviewBoardPanelView: View {
    @ObservedObject var viewModel: ReviewBoardViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if viewModel.tasks.isEmpty && viewModel.pendingMergeQueue.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("reviewBoard.panel")
        .accessibilityElement(children: .contain)
        .onAppear { viewModel.refresh() }
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
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Tasks")
            ForEach(viewModel.tasks) { task in
                taskRow(task)
            }
        }
    }

    private func taskRow(_ task: ReviewBoardTask) -> some View {
        let isSelected = viewModel.selectedTask?.id == task.id
        let parts = ReviewBoardText.splitDirective(task.title)
        return Button {
            viewModel.selectTask(id: task.id)
        } label: {
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
                    if viewModel.isWorking(task) {
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
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            viewModel.revealPane(for: task)
        })
        .accessibilityLabel("\(task.title), \(task.status), priority \(task.priority)")
        .accessibilityIdentifier("reviewBoard.task.\(task.id)")
    }

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
}
