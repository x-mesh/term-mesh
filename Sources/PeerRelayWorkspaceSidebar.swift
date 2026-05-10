import SwiftUI
import AppKit
import PeerProto

struct PeerRelayWorkspaceSummary: Identifiable, Equatable {
    let id: Data
    let title: String
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
                ForEach(model.workspaces) { ws in
                    PeerWorkspaceRowView(
                        title: ws.title,
                        isSelected: model.selectedID == ws.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(ws) }
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
