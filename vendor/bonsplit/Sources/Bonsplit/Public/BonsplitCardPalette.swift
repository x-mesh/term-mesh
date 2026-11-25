import AppKit

/// Card chrome colors for hosts that draw their own cards next to bonsplit's
/// (for example a sidebar), so both read as one surface.
public enum BonsplitCardPalette {
    public static func windowBackground(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        TabBarColors.nsColorCardWindowBackground(for: appearance)
    }

    public static func cardBackground(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        TabBarColors.nsColorPaneBackground(for: appearance)
    }

    public static func cardBorder(
        for appearance: BonsplitConfiguration.Appearance,
        isFocused: Bool
    ) -> NSColor {
        TabBarColors.nsColorCardBorder(for: appearance, isFocused: isFocused)
    }
}
