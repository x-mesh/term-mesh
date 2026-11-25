import SwiftUI
import Bonsplit

/// Chrome shared by the panels that sit beside bonsplit's pane cards — the
/// sidebar, the Review Board, the Remote Work drawer — so they read as cards on
/// the same window background rather than as flat system panels.
@MainActor
enum CardChromeColors {
    static func appearance(for theme: GhosttyTheme) -> BonsplitConfiguration.Appearance {
        Workspace.bonsplitAppearance(from: theme.backgroundColor)
    }

    static func windowBackground(for theme: GhosttyTheme) -> Color {
        Color(nsColor: BonsplitCardPalette.windowBackground(for: appearance(for: theme)))
    }

    static func card(for theme: GhosttyTheme) -> Color {
        Color(nsColor: BonsplitCardPalette.cardBackground(for: appearance(for: theme)))
    }

    static func border(for theme: GhosttyTheme) -> Color {
        Color(nsColor: BonsplitCardPalette.cardBorder(for: appearance(for: theme), isFocused: false))
    }

    /// The selected workspace card's gradient, reused as the accent for every
    /// selected tab so the selections read as one color.
    nonisolated static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.95, green: 0.45, blue: 0.55),
            Color(red: 0.55, green: 0.45, blue: 0.95),
            Color(red: 0.45, green: 0.55, blue: 0.95),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private struct CardPanelModifier: ViewModifier {
    @Environment(\.ghosttyTheme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: BonsplitCardMetrics.cornerRadius, style: .continuous)
        content
            .background(CardChromeColors.card(for: theme))
            .clipShape(shape)
            .overlay(shape.strokeBorder(CardChromeColors.border(for: theme), lineWidth: BonsplitCardMetrics.borderWidth))
    }
}

private struct CardWindowBackgroundModifier: ViewModifier {
    @Environment(\.ghosttyTheme) private var theme

    func body(content: Content) -> some View {
        content.background(CardChromeColors.windowBackground(for: theme))
    }
}

extension View {
    /// Fills, clips and outlines the view as a card, matching the pane cards.
    func cardPanel() -> some View {
        modifier(CardPanelModifier())
    }

    /// The window background the cards sit on.
    func cardWindowBackground() -> some View {
        modifier(CardWindowBackgroundModifier())
    }
}

struct UnderlineTabItem<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var accessibilityLabel: String?

    var id: Value { value }
}

/// Text tabs with a gradient underline on the selected one. Used where the
/// card chrome would otherwise stack the accent-filled system segmented control
/// on a white card.
private enum UnderlineTabStyle {
    static let spacing: CGFloat = 18
    static let tabHeight: CGFloat = 24
    static let underlineHeight: CGFloat = 2
    static let fontSize: CGFloat = 12
}

struct UnderlineTabPicker<Value: Hashable>: View {
    private typealias Style = UnderlineTabStyle

    let items: [UnderlineTabItem<Value>]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: Style.spacing) {
            ForEach(items) { item in
                let isSelected = item.value == selection
                Button {
                    if !isSelected { onSelect(item.value) }
                } label: {
                    Text(item.title)
                        .font(.system(size: Style.fontSize, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: Style.tabHeight)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Capsule()
                                    .fill(CardChromeColors.accentGradient)
                                    .frame(height: Style.underlineHeight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.accessibilityLabel ?? item.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
