import SwiftUI
import AppKit
import PeerProto

struct PeerRelayWorkspaceSummary: Identifiable, Equatable {
    let id: Data
    let title: String
    /// Owning host window id; empty for legacy single-window hosts.
    var windowID: Data = Data()
    /// Owning host window label (title bar text) for section grouping.
    var windowTitle: String = ""
}

@MainActor
final class PeerRelayWorkspaceSidebarModel: ObservableObject {
    @Published var workspaces: [PeerRelayWorkspaceSummary] = []
    @Published var selectedID: Data?

    var onSelect: ((PeerRelayWorkspaceSummary) -> Void)?

    func select(_ workspace: PeerRelayWorkspaceSummary) {
        onSelect?(workspace)
    }
}

struct PeerRelayWorkspaceSidebarView: View {
    @ObservedObject var model: PeerRelayWorkspaceSidebarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workspaces")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if model.workspaces.isEmpty {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            } else {
                let windowGroups = groupWorkspacesByWindow(
                    model.workspaces,
                    windowID: { $0.windowID },
                    windowTitle: { $0.windowTitle }
                )
                // Section by host window only when the host reports more than
                // one; otherwise keep the original flat list.
                if windowGroups.count > 1 {
                    ForEach(windowGroups, id: \.windowID) { group in
                        Text(peerWindowLabel(title: group.windowTitle, id: group.windowID))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color.secondary.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 1)
                        ForEach(group.items) { ws in
                            PeerWorkspaceRowView(
                                title: ws.title,
                                isSelected: model.selectedID == ws.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(ws) }
                        }
                    }
                } else {
                    ForEach(model.workspaces) { ws in
                        PeerWorkspaceRowView(
                            title: ws.title,
                            isSelected: model.selectedID == ws.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(ws) }
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }
}

private struct PeerWorkspaceRowView: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
    }
}
