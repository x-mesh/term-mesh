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
            Text("No review tasks")
                .font(.system(size: 13, weight: .medium))
            Text("Task board data has not reported review work yet.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("No review tasks")
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
                    Text(viewModel.taskTitle(forMergeQueueItem: item))
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
                    if let approvedAt = item.approvedAt {
                        Text("·")
                        Text(approvedAt)
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
        return Button {
            viewModel.selectTask(id: task.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(task.status.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 6) {
                    Text(task.teamName)
                    if let assignee = task.assignee {
                        Text("·")
                        Text(assignee)
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
        .accessibilityLabel("\(task.title), \(task.status), priority \(task.priority)")
        .accessibilityIdentifier("reviewBoard.task.\(task.id)")
    }

    private func taskDetails(_ task: ReviewBoardTask) -> some View {
        let digest = viewModel.digest(for: task)
        return VStack(alignment: .leading, spacing: 12) {
            statusPills(viewModel.statusBadges(for: task))
            factSection("Attempt Lineage", systemImage: "point.3.connected.trianglepath.dotted", text: digest.attemptLineage)
            factSection("Ahead/Behind", systemImage: "arrow.left.arrow.right", text: digest.aheadBehind)
            factSection("Commit/Push", systemImage: "arrow.up.doc", text: digest.commitPush)
            factSection("Platform Checks", systemImage: "macwindow", text: digest.platformChecks)
            factSection("PR/Checks", systemImage: "checkmark.rectangle.stack", text: digest.pullRequestChecks)
            factSection("Overlapping Files", systemImage: "square.stack.3d.down.forward", text: digest.overlappingFiles)
            factSection("Rejection Reason", systemImage: "xmark.octagon", text: digest.rejectionReason)
            factSection("Merge Queue", systemImage: "arrow.triangle.merge", text: digest.mergeQueue)
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
