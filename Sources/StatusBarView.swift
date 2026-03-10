import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var tabManager: TabManager

    private var selectedWorkspace: Workspace? {
        tabManager.selectedWorkspace
    }

    private var panelCount: Int {
        selectedWorkspace?.panels.count ?? 0
    }

    private var workspaceTitle: String {
        guard let ws = selectedWorkspace else { return "" }
        if let custom = ws.customTitle, !custom.isEmpty { return custom }
        return ws.title
    }

    private var workspaceIndex: Int? {
        guard let ws = selectedWorkspace else { return nil }
        return tabManager.tabs.firstIndex(where: { $0.id == ws.id }).map { $0 + 1 }
    }

    private var shellName: String {
        guard let ws = selectedWorkspace,
              let panel = ws.focusedTerminalPanel else { return "" }
        let title = panel.title
        guard !title.isEmpty, title != "Terminal" else { return "" }
        // Surface title is typically "zsh", "bash", or a path — extract basename
        let base = (title as NSString).lastPathComponent
        return base.isEmpty ? title : base
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left side content
            HStack(spacing: 6) {
                if !shellName.isEmpty {
                    Text(shellName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if panelCount > 0 {
                    if !shellName.isEmpty {
                        separatorDot
                    }
                    Text("\(panelCount) \(panelCount == 1 ? "pane" : "panes")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 10)

            Spacer()

            // Right side: workspace name/index
            if !workspaceTitle.isEmpty {
                HStack(spacing: 4) {
                    if let idx = workspaceIndex {
                        Text("\(idx)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(workspaceTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.trailing, 10)
            }
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var separatorDot: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}
