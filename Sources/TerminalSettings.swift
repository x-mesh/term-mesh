import AppKit
import Foundation

// MARK: - Terminal Settings Override

/// Manages a ghostty config override file for GUI-configured terminal settings
/// (font family, font size, theme). This file takes highest priority in the config chain:
///   terminal-settings.config (GUI) > terminal-theme.config (appearance) > ghostty config > defaults
enum TerminalSettingsOverride {
    static let fileName = "terminal-settings.config"

    static let fontFamilyKey = "terminalFontFamily"
    static let fontSizeKey = "terminalFontSize"
    static let themeLightKey = "terminalThemeLight"
    static let themeDarkKey = "terminalThemeDark"
    static let backgroundOpacityKey = "terminalBackgroundOpacity"
    static let cursorColorKey = "terminalCursorColor"
    static let cursorStyleKey = "terminalCursorStyle"
    static let scrollbackLimitKey = "terminalScrollbackLimit"
    static let unfocusedSplitOpacityKey = "terminalUnfocusedSplitOpacity"
    static let splitDividerColorKey = "terminalSplitDividerColor"

    static func overrideURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("term-mesh", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Write the override file from UserDefaults. Only non-empty values are written.
    static func write(defaults: UserDefaults = .standard) {
        guard let url = overrideURL() else { return }
        let fm = FileManager.default

        let fontFamily = defaults.string(forKey: fontFamilyKey) ?? ""
        let fontSize = defaults.double(forKey: fontSizeKey)
        let themeLight = defaults.string(forKey: themeLightKey) ?? ""
        let themeDark = defaults.string(forKey: themeDarkKey) ?? ""
        let bgOpacity = defaults.double(forKey: backgroundOpacityKey)
        let cursorColor = defaults.string(forKey: cursorColorKey) ?? ""
        let cursorStyle = defaults.string(forKey: cursorStyleKey) ?? ""
        let scrollback = defaults.integer(forKey: scrollbackLimitKey)
        let unfocusedOpacity = defaults.double(forKey: unfocusedSplitOpacityKey)
        let dividerColor = defaults.string(forKey: splitDividerColorKey) ?? ""

        var lines: [String] = ["# Term-Mesh terminal settings override (auto-generated)"]

        if !fontFamily.isEmpty {
            // font-family is a RepeatableString in ghostty — must clear first, then set
            lines.append("font-family = ")
            lines.append("font-family = \(fontFamily)")
        }
        if fontSize > 0 {
            lines.append("font-size = \(Int(fontSize))")
        }
        if !themeLight.isEmpty || !themeDark.isEmpty {
            let light = themeLight.isEmpty ? themeDark : themeLight
            let dark = themeDark.isEmpty ? themeLight : themeDark
            lines.append("theme = light:\(light),dark:\(dark)")
        }
        // background-opacity: requires CAMetalLayer.isOpaque=false in ghostty — not supported yet
        if !cursorColor.isEmpty {
            lines.append("cursor-color = \(cursorColor)")
        }
        if !cursorStyle.isEmpty {
            lines.append("cursor-style = \(cursorStyle)")
        }
        if scrollback > 0 {
            lines.append("scrollback-limit = \(scrollback)")
        }
        // unfocused-split-opacity is handled by GhosttyConfig (Swift-side).
        // Write to override file so GhosttyConfig.load() can read it.
        if unfocusedOpacity >= 0 {
            lines.append("unfocused-split-opacity = \(String(format: "%.2f", unfocusedOpacity))")
        }
        // split-divider-color: requires Bonsplit public API — not supported yet

        // If only the header line remains, there are no overrides — remove the file
        if lines.count <= 1 {
            try? fm.removeItem(at: url)
            return
        }

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove the override file entirely (reset to config defaults).
    static func remove() {
        guard let url = overrideURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether a GUI theme override is currently set.
    static func hasThemeOverride(defaults: UserDefaults = .standard) -> Bool {
        let light = defaults.string(forKey: themeLightKey) ?? ""
        let dark = defaults.string(forKey: themeDarkKey) ?? ""
        return !light.isEmpty || !dark.isEmpty
    }
}

// MARK: - Bundled Theme List

enum ThemeBrightness {
    case light
    case dark
}

enum TerminalThemeList {
    private static var cachedNames: [String]?
    private static var cachedLight: [String]?
    private static var cachedDark: [String]?

    /// Returns sorted list of bundled ghostty theme names.
    static func bundledThemeNames() -> [String] {
        if let cached = cachedNames { return cached }

        let names = loadThemeNames()
        cachedNames = names
        return names
    }

    /// Returns bundled theme names filtered by brightness.
    static func bundledThemeNames(for brightness: ThemeBrightness) -> [String] {
        switch brightness {
        case .light:
            if let cached = cachedLight { return cached }
        case .dark:
            if let cached = cachedDark { return cached }
        }

        classifyThemes()

        switch brightness {
        case .light: return cachedLight ?? []
        case .dark: return cachedDark ?? []
        }
    }

    private static func classifyThemes() {
        guard let dir = findThemesDirectory() else {
            cachedLight = []
            cachedDark = []
            return
        }

        var light: [String] = []
        var dark: [String] = []

        for name in bundledThemeNames() {
            let fileURL = dir.appendingPathComponent(name)
            let isLight = isLightTheme(at: fileURL)
            if isLight {
                light.append(name)
            } else {
                dark.append(name)
            }
        }

        cachedLight = light
        cachedDark = dark
    }

    /// Parses the theme file's background color and returns true if luminance > 0.5.
    private static func isLightTheme(at url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("background") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key == "background" else { continue }
            let hex = parts[1].trimmingCharacters(in: .whitespaces)
            return hexLuminance(hex) > 0.5
        }

        return false // no background line → assume dark
    }

    /// Computes perceived luminance (0–1) from a hex color string like "#0d1117".
    private static func hexLuminance(_ hex: String) -> Double {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let rgb = UInt32(h, radix: 16) else { return 0 }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    private static func findThemesDirectory() -> URL? {
        let bundle = Bundle.main
        let fm = FileManager.default

        // 1. App bundle: Contents/Resources/ghostty/themes (both Debug and Release)
        if let resourceURL = bundle.resourceURL {
            let bundledThemes = resourceURL.appendingPathComponent("ghostty/themes")
            if fm.fileExists(atPath: bundledThemes.path) {
                return bundledThemes
            }
        }

        // 2. XDG / system ghostty theme directories
        let homeDir = fm.homeDirectoryForCurrentUser
        let candidates = [
            homeDir.appendingPathComponent(".local/share/ghostty/themes"),
            homeDir.appendingPathComponent(".config/ghostty/themes"),
            URL(fileURLWithPath: "/usr/local/share/ghostty/themes"),
            URL(fileURLWithPath: "/usr/share/ghostty/themes"),
        ]
        for candidate in candidates {
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static func loadThemeNames() -> [String] {
        guard let dir = findThemesDirectory() else { return [] }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return contents
                .map { $0.lastPathComponent }
                .filter { !$0.hasPrefix(".") }
                .sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        } catch {
            return []
        }
    }
}

// MARK: - Monospace Font List

enum MonospaceFontList {
    private static var cachedFonts: (mono: [String], all: [String])?

    /// Returns monospace fonts first, then all other fonts. Ghostty accepts any font-family.
    static func list() -> [String] {
        if let cached = cachedFonts { return cached.mono + cached.all }

        let result = loadFonts()
        cachedFonts = result
        return result.mono + result.all
    }

    /// Returns just the monospace font count (for section divider placement).
    static var monospaceFontCount: Int {
        if let cached = cachedFonts { return cached.mono.count }
        let result = loadFonts()
        cachedFonts = result
        return result.mono.count
    }

    private static func loadFonts() -> (mono: [String], all: [String]) {
        let fontManager = NSFontManager.shared
        let allFamilies = fontManager.availableFontFamilies

        var mono: [String] = []
        var other: [String] = []

        for family in allFamilies {
            if isMonospace(family: family, fontManager: fontManager) {
                mono.append(family)
            } else {
                other.append(family)
            }
        }

        let sort: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (mono: mono.sorted(by: sort), all: other.sorted(by: sort))
    }

    private static func isMonospace(family: String, fontManager: NSFontManager) -> Bool {
        guard let members = fontManager.availableMembers(ofFontFamily: family) else { return false }

        // Check any member (not just first) — some families have mixed members
        for member in members.prefix(3) {
            guard member.count >= 1, let fontName = member[0] as? String,
                  let font = NSFont(name: fontName, size: 12) else { continue }

            if font.isFixedPitch { return true }
            if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }

            // Heuristic: compare width of 'i' and 'M' — monospace fonts have equal advances
            let advances = font.advancement(forGlyph: font.glyph(withName: "i"))
            let advanceM = font.advancement(forGlyph: font.glyph(withName: "M"))
            if advances.width > 0 && advanceM.width > 0 && abs(advances.width - advanceM.width) < 0.1 {
                return true
            }
        }
        return false
    }
}
