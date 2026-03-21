import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case auto

    var id: String { rawValue }

    static var visibleCases: [AppearanceMode] {
        [.system, .light, .dark]
    }

    var displayName: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .auto:
            return "Auto"
        }
    }
}

enum AppearanceSettings {
    static let appearanceModeKey = "appearanceMode"
    static let defaultMode: AppearanceMode = .system

    static func mode(for rawValue: String?) -> AppearanceMode {
        guard let rawValue, let mode = AppearanceMode(rawValue: rawValue) else {
            return defaultMode
        }
        if mode == .auto {
            return .system
        }
        return mode
    }

    @discardableResult
    static func resolvedMode(defaults: UserDefaults = .standard) -> AppearanceMode {
        let stored = defaults.string(forKey: appearanceModeKey)
        let resolved = mode(for: stored)
        if stored != resolved.rawValue {
            defaults.set(resolved.rawValue, forKey: appearanceModeKey)
        }
        return resolved
    }
}

// MARK: - Terminal Theme Override

/// Manages a ghostty config override file that sets terminal colors
/// based on the current appearance mode. For "system" mode, the effective
/// OS appearance is detected so the terminal always has appropriate colors.
enum TerminalThemeOverride {
    static let overrideFileName = "terminal-theme.config"

    static func overrideURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("term-mesh", isDirectory: true)
            .appendingPathComponent(overrideFileName)
    }

    /// Write (or remove) the theme override file based on the current appearance mode.
    /// When the user has selected a GUI theme in Settings, the hardcoded palettes are unnecessary
    /// because the named theme already provides colors — skip writing the override in that case.
    static func write(for rawMode: String) {
        let mode = AppearanceMode(rawValue: rawMode) ?? .system
        let fm = FileManager.default
        guard let url = overrideURL() else { return }

        // If the user picked a named theme via Settings GUI, the theme file handles colors.
        if TerminalSettingsOverride.hasThemeOverride() {
            try? fm.removeItem(at: url)
            return
        }

        let config: String
        switch mode {
        case .light:
            config = lightConfig
        case .dark:
            config = darkConfig
        case .system, .auto:
            config = effectiveSystemAppearanceIsDark() ? darkConfig : lightConfig
        }

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? config.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Returns true if the effective macOS system appearance is dark.
    private static func effectiveSystemAppearanceIsDark() -> Bool {
        guard let appearance = NSApp?.effectiveAppearance else { return true }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // GitHub Dark — deep, high-contrast dark theme
    static let darkConfig = """
    # Term-Mesh dark theme override (auto-generated)
    background = #0d1117
    foreground = #e6edf3
    cursor-color = #58a6ff
    selection-background = #264f78
    selection-foreground = #e6edf3
    palette = 0=#0d1117
    palette = 1=#ff7b72
    palette = 2=#3fb950
    palette = 3=#d29922
    palette = 4=#58a6ff
    palette = 5=#bc8cff
    palette = 6=#39d2c0
    palette = 7=#c9d1d9
    palette = 8=#484f58
    palette = 9=#ff7b72
    palette = 10=#3fb950
    palette = 11=#d29922
    palette = 12=#58a6ff
    palette = 13=#bc8cff
    palette = 14=#39d2c0
    palette = 15=#f0f6fc
    """

    // Xcode-style light theme — clean white with readable contrast
    static let lightConfig = """
    # Term-Mesh light theme override (auto-generated)
    background = #ffffff
    foreground = #1e1e1e
    cursor-color = #333333
    selection-background = #b4d5fe
    selection-foreground = #1e1e1e
    palette = 0=#000000
    palette = 1=#c41a16
    palette = 2=#007400
    palette = 3=#826b28
    palette = 4=#0000ff
    palette = 5=#a90d91
    palette = 6=#3e8a87
    palette = 7=#c0c0c0
    palette = 8=#808080
    palette = 9=#c41a16
    palette = 10=#007400
    palette = 11=#826b28
    palette = 12=#0000ff
    palette = 13=#a90d91
    palette = 14=#3e8a87
    palette = 15=#ffffff
    """
}

enum QuitWarningSettings {
    static let warnBeforeQuitKey = "warnBeforeQuitShortcut"
    static let defaultWarnBeforeQuit = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: warnBeforeQuitKey) == nil {
            return defaultWarnBeforeQuit
        }
        return defaults.bool(forKey: warnBeforeQuitKey)
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: warnBeforeQuitKey)
    }
}

enum CommandPaletteRenameSelectionSettings {
    static let selectAllOnFocusKey = "commandPalette.renameSelectAllOnFocus"
    static let defaultSelectAllOnFocus = true

    static func selectAllOnFocusEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: selectAllOnFocusKey) == nil {
            return defaultSelectAllOnFocus
        }
        return defaults.bool(forKey: selectAllOnFocusKey)
    }
}

enum ClaudeCodeIntegrationSettings {
    static let hooksEnabledKey = "claudeCodeHooksEnabled"
    static let defaultHooksEnabled = true

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }
}
