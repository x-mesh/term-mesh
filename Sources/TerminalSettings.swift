import AppKit
import Foundation

// MARK: - Override File Location

/// Where this build keeps its ghostty config override files.
///
/// **Scoped to the bundle identifier, and that is the entire point.** These
/// files are generated FROM UserDefaults, which macOS already separates per
/// bundle — but the files themselves used to sit at one fixed path that every
/// build wrote to. So a Debug build, whose own defaults are empty, would
/// regenerate the shared file from nothing and hand the installed app a
/// terminal configuration the user never chose. Launching the Debug app was
/// enough; `TermMeshApp.init()` writes on every start.
///
/// Observed: `unfocused-split-opacity = 0.00` in the shared file while
/// `com.termmesh.app`'s defaults still held the user's `1`. The setting was
/// never lost — the app was reading a file a different build had written.
///
/// A `--tag` build, a STAGING build and the installed app now each own their
/// copy, so running one can no longer reconfigure another.
enum TerminalOverrideLocation {
    /// The pre-isolation shared directory. Still read once, by the migration
    /// below, and otherwise dead.
    static func legacyDirectory(
        appSupport: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
    ) -> URL? {
        appSupport?.appendingPathComponent("term-mesh", isDirectory: true)
    }

    /// This build's own directory.
    ///
    /// Falls back to the legacy shared path when there is no bundle
    /// identifier — an XCTest host or a bare binary. Behaviour there is
    /// then exactly what it was before, which is the safe direction for a
    /// context that has no identity to isolate by.
    static func directory(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupport: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
    ) -> URL? {
        guard let legacy = legacyDirectory(appSupport: appSupport) else { return nil }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return legacy }
        return legacy.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static func url(forFileName fileName: String) -> URL? {
        directory()?.appendingPathComponent(fileName)
    }

    /// Every override file this module owns. Migration copies exactly these.
    static let managedFileNames = [
        TerminalSettingsOverride.fileName,
        TerminalThemeOverride.overrideFileName,
    ]

    /// Seeds a build's directory from the old shared one, once.
    ///
    /// Copy, not move, and only when the destination does not exist: the
    /// installed app and a Debug build migrate independently, and whichever
    /// runs first must not take the settings away from the other. The legacy
    /// file is deliberately left in place — an older build rolled back onto
    /// this machine still reads it, and nothing current does.
    ///
    /// A file that fails to copy is skipped rather than reported: the caller
    /// (`TermMeshApp.init()`) rewrites both files from UserDefaults moments
    /// later anyway, so a failed migration costs at most one appearance of
    /// the defaults, never a broken launch.
    static func migrateLegacyFilesIfNeeded(
        fileManager: FileManager = .default,
        legacy: URL? = legacyDirectory(),
        destination: URL? = directory()
    ) {
        guard let legacy, let destination, legacy != destination else { return }
        for name in managedFileNames {
            let source = legacy.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: target.path) else { continue }
            try? fileManager.createDirectory(
                at: destination, withIntermediateDirectories: true
            )
            try? fileManager.copyItem(at: source, to: target)
        }
    }
}

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
        TerminalOverrideLocation.url(forFileName: fileName)
    }

    /// Reads a key that uses a negative sentinel for "not set".
    ///
    /// `defaults.double(forKey:)` cannot express absence — it answers `0` for
    /// a key that was never written, which for an opacity is a legitimate
    /// value (fully transparent) rather than an obvious error. That collision
    /// is what let an empty Debug build write `unfocused-split-opacity = 0.00`
    /// into the shared override file and blank out the installed app's splits.
    /// Asking for the object first keeps "absent" and "zero" distinct.
    static func storedDouble(_ defaults: UserDefaults, forKey key: String) -> Double? {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue
    }

    /// The file's contents for a given defaults + appearance mode, or nil when
    /// nothing is overridden. Pure — no filesystem — so the "an unset key must
    /// not produce a line" rule is directly testable.
    static func configLines(defaults: UserDefaults, mode: AppearanceMode) -> [String]? {
        let fontFamily = defaults.string(forKey: fontFamilyKey) ?? ""
        let fontSize = defaults.double(forKey: fontSizeKey)
        let themeLight = defaults.string(forKey: themeLightKey) ?? ""
        let themeDark = defaults.string(forKey: themeDarkKey) ?? ""
        let cursorColor = defaults.string(forKey: cursorColorKey) ?? ""
        let cursorStyle = defaults.string(forKey: cursorStyleKey) ?? ""
        let scrollback = defaults.integer(forKey: scrollbackLimitKey)
        let unfocusedOpacity = storedDouble(defaults, forKey: unfocusedSplitOpacityKey)
        let splitDividerColor = defaults.string(forKey: splitDividerColorKey) ?? ""

        var lines: [String] = ["# Term-Mesh terminal settings override (auto-generated)"]

        if !fontFamily.isEmpty {
            // font-family is a RepeatableString in ghostty — must clear first, then set
            lines.append("font-family = ")
            lines.append("font-family = \(fontFamily)")
        }
        if fontSize > 0 {
            lines.append("font-size = \(Int(fontSize))")
        }
        if let theme = themeLine(light: themeLight, dark: themeDark, mode: mode) {
            lines.append(theme)
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
        //
        // `storedDouble` returning nil means the user never set this, which is
        // NOT the same as setting it to zero — see its doc comment. The
        // negative check keeps honouring the `-1` sentinel that @AppStorage
        // declares as its default, for defaults that already carry it.
        if let unfocusedOpacity, unfocusedOpacity >= 0 {
            lines.append("unfocused-split-opacity = \(String(format: "%.2f", unfocusedOpacity))")
        }
        if !splitDividerColor.isEmpty {
            lines.append("split-divider-color = \(splitDividerColor)")
        }

        // Only the header means nothing is overridden.
        return lines.count <= 1 ? nil : lines
    }

    /// Write the override file from UserDefaults. Only non-empty values are written.
    static func write(defaults: UserDefaults = .standard) {
        guard let url = overrideURL() else { return }
        let fm = FileManager.default

        guard let lines = configLines(
            defaults: defaults,
            mode: AppearanceSettings.resolvedMode(defaults: defaults)
        ) else {
            try? fm.removeItem(at: url)
            return
        }

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The `theme` line for a pair of named themes under an appearance mode.
    ///
    /// A `light:…,dark:…` pair hands ghostty both halves and lets it choose,
    /// and it chooses by the *system* appearance — not by the app's. So while
    /// the two disagree, which is the whole point of the Light/Dark setting,
    /// the terminal drew the wrong half: chrome dark, terminal light, on a Mac
    /// set to Light. `TerminalThemeOverride`, the one thing that could have
    /// forced it, deletes itself whenever a named theme exists, on the premise
    /// that the named theme "already provides colors" — true of the colors,
    /// false of the choice between them.
    ///
    /// So an explicit mode pins a single theme and leaves ghostty nothing to
    /// decide. Only `system` still hands over the pair, which is exactly when
    /// following the system appearance is what was asked for.
    static func themeLine(light: String, dark: String, mode: AppearanceMode) -> String? {
        guard !light.isEmpty || !dark.isEmpty else { return nil }
        let resolvedLight = light.isEmpty ? dark : light
        let resolvedDark = dark.isEmpty ? light : dark
        switch mode {
        case .light:
            return "theme = \(resolvedLight)"
        case .dark:
            return "theme = \(resolvedDark)"
        case .system, .auto:
            return "theme = light:\(resolvedLight),dark:\(resolvedDark)"
        }
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
