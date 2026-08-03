import SwiftUI

/// Main container view that renders the entire split tree (internal implementation)
struct SplitViewContainer<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let appearance: BonsplitConfiguration.Appearance
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    var enableAnimations: Bool = true
    var animationDuration: Double = 0.15

    var body: some View {
        splitNodeContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TabBarColors.paneBackground(for: appearance))
            .focusable()
            .focusEffectDisabled()
            .background {
                // Observe the container without making GeometryReader the sizing parent of
                // the entire split/AppKit subtree. As a background it receives the resolved
                // size, so terminal hosting views no longer get remeasured through an extra
                // GeometryReader layout on every workspace visibility change.
                GeometryReader { geometry in
                    Color.clear
                        .onChange(of: geometry.size) { _, _ in
                            updateContainerFrame(geometry: geometry)
                        }
                        .onAppear {
                            updateContainerFrame(geometry: geometry)
                        }
                }
            }
    }

    private func updateContainerFrame(geometry: GeometryProxy) {
        controller.containerFrame = geometry.frame(in: .global)
        onGeometryChange?(false)  // Container resize is not a drag
    }

    @ViewBuilder
    private var splitNodeContent: some View {
        let nodeToRender = controller.zoomedNode ?? controller.rootNode
        SplitNodeView(
            node: nodeToRender,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            appearance: appearance,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle,
            onGeometryChange: onGeometryChange,
            enableAnimations: enableAnimations,
            animationDuration: animationDuration
        )
    }
}
