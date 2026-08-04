import AppKit
import SwiftUI

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8)  & 0xFF) / 255.0,
            blue:  Double( value        & 0xFF) / 255.0
        )
    }
}

func coloredCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 14, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

struct ShortcutHintPillBackground: View {
    var emphasis: Double = 1.0

    var body: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.30 * emphasis), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.22 * emphasis), radius: 2, x: 0, y: 1)
    }
}

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool = true

    func toggle() {
        isVisible.toggle()
    }
}

enum SidebarResizeInteraction {
    static let handleWidth: CGFloat = 6
    static let hitInset: CGFloat = 3

    static var hitWidthPerSide: CGFloat {
        hitInset + (handleWidth / 2)
    }
}

enum WorkspaceMountPolicy {
    // Keep inactive warm workspaces in SwiftUI's native-view display list. An exact zero
    // opacity lets SwiftUI prune and later re-add AppKit platform views on every switch.
    // This value is below an 8-bit alpha step, so it remains visually transparent while
    // preserving the already-mounted native hierarchy. Hit testing is disabled separately.
    static let inactiveWorkspaceOpacity = 0.0001
    // Keep the selected workspace and one recently used workspace mounted. The
    // inactive entry is hidden and input-disabled by ContentView, but retaining
    // its SwiftUI/Ghostty tree avoids rebuilding every surface on a quick return.
    static let maxMountedWorkspaces = 2
    // Workspace cycling uses the same bounded selected + recent pair.
    static let maxMountedWorkspacesDuringCycle = 2

    static func nextMountedWorkspaceIds(
        current: [UUID],
        selected: UUID?,
        pinnedIds: Set<UUID>,
        orderedTabIds: [UUID],
        isCycleHot: Bool,
        maxMounted: Int
    ) -> [UUID] {
        let existing = Set(orderedTabIds)
        let clampedMax = max(1, maxMounted)
        var ordered = current.filter { existing.contains($0) }

        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }

        if isCycleHot, let selected {
            let warmIds = cycleWarmIds(selected: selected, orderedTabIds: orderedTabIds)
            for id in warmIds.reversed() {
                ordered.removeAll { $0 == id }
                ordered.insert(id, at: 0)
            }
        }

        // Ensure pinned ids (retiring handoff workspaces) are always retained at highest priority.
        // This runs after warming to prevent neighbor warming from evicting the retiring workspace.
        let prioritizedPinnedIds = pinnedIds
            .filter { existing.contains($0) && $0 != selected }
            .sorted { lhs, rhs in
                let lhsIndex = orderedTabIds.firstIndex(of: lhs) ?? .max
                let rhsIndex = orderedTabIds.firstIndex(of: rhs) ?? .max
                return lhsIndex < rhsIndex
            }
        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }
        var pinnedInsertionIndex = (selected != nil) ? 1 : 0
        for pinnedId in prioritizedPinnedIds {
            ordered.removeAll { $0 == pinnedId }
            let insertionIndex = min(pinnedInsertionIndex, ordered.count)
            ordered.insert(pinnedId, at: insertionIndex)
            pinnedInsertionIndex += 1
        }

        if ordered.count > clampedMax {
            ordered.removeSubrange(clampedMax...)
        }

        return ordered
    }

    private static func cycleWarmIds(selected: UUID, orderedTabIds: [UUID]) -> [UUID] {
        guard orderedTabIds.contains(selected) else { return [selected] }
        // Keep warming focused to the selected workspace. Retiring/target workspaces are
        // pinned by handoff logic, so warming adjacent neighbors here just adds layout work.
        return [selected]
    }
}

enum WorkspaceHandoffPolicy {
    /// A warm pair of local, browser-free workspaces can switch in one visibility update.
    /// Browser and peer workspaces retain the overlap handoff because their AppKit/WebKit
    /// responders may not be ready when selection changes.
    static func canTransitionImmediately(
        oldSelectedId: UUID,
        newSelectedId: UUID,
        mountedIds: Set<UUID>,
        oldIsTerminalOnly: Bool,
        newIsTerminalOnly: Bool,
        newRendererReady: Bool,
        oldIsPeerMirror: Bool,
        newIsPeerMirror: Bool
    ) -> Bool {
        guard oldSelectedId != newSelectedId else { return false }
        guard mountedIds.contains(oldSelectedId), mountedIds.contains(newSelectedId) else {
            return false
        }
        guard oldIsTerminalOnly, newIsTerminalOnly, newRendererReady else { return false }
        guard !oldIsPeerMirror, !newIsPeerMirror else { return false }
        return true
    }

    /// Reorder workspace layers only while two workspaces intentionally overlap.
    /// A warm immediate switch has exactly one visible workspace, so changing the
    /// selected layer's priority only makes SwiftUI reparent AppKit platform views.
    static func visualPriority(
        isSelected: Bool,
        isRetiring: Bool,
        hasOverlap: Bool
    ) -> Int {
        guard hasOverlap else { return 0 }
        if isSelected { return 2 }
        if isRetiring { return 1 }
        return 0
    }
}
