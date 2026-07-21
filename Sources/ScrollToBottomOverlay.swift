import SwiftUI
import AppKit

/// Small "jump to the newest output" affordance shown in the bottom-right of a
/// terminal pane while the viewport sits above the bottom.
///
/// Layering contract: this is mounted from `GhosttySurfaceScrollView` (the
/// AppKit portal layer), never from a SwiftUI panel container — portal-hosted
/// terminal surfaces render above SwiftUI panel overlays during split/workspace
/// churn. See `setScrollToBottomOverlay`.
///
/// Unlike `SurfaceSearchOverlay`, the hosting view is sized to the button
/// itself rather than the whole pane. The search bar needs full bounds because
/// it can be dragged between corners; this button has a fixed position, and
/// keeping the hosting view small means clicks outside it reach the terminal
/// without any `hitTest` override.
struct ScrollToBottomButton: View {
    /// Diameter of the button, and therefore of its hosting view.
    static let size: CGFloat = 26

    /// Gap between the button and the edges of the terminal content area.
    static let margin: CGFloat = 8

    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(isHovering ? 0.95 : 0.7))
                .frame(width: Self.size, height: Self.size)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(
                            Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .help("Scroll to bottom")
        .accessibilityLabel("Scroll to bottom")
    }
}
