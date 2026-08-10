import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case korean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Setting"
        case .english: return "English"
        case .korean: return "Korean"
        }
    }

    /// The language's own name for its own speakers.
    ///
    /// Shown verbatim, never translated: someone who picked a language they
    /// cannot read has to be able to find their way back, and "영어" is no help
    /// to a reader of English. `.system` has no endonym — it follows whatever
    /// macOS chose, so it is labelled in the current UI language.
    var endonym: String? {
        switch self {
        case .system: return nil
        case .english: return "English"
        case .korean: return "한국어"
        }
    }

    /// The catalog language this mode pins, or nil for `.system`, which
    /// negotiates one from macOS instead.
    var languageCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .korean: return "ko"
        }
    }

    /// Every language the app ships a catalog for. Derived from the cases so
    /// adding a language is one edit here, not a second hardcoded set.
    static var supportedLanguageCodes: Set<String> {
        Set(allCases.compactMap(\.languageCode))
    }
}

enum LanguageSettings {
    static let languageModeKey = "appLanguage"
    static let defaultMode: AppLanguage = .system

    static func mode(for rawValue: String?) -> AppLanguage {
        guard let rawValue, let mode = AppLanguage(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    @discardableResult
    static func resolvedMode(defaults: UserDefaults = .standard) -> AppLanguage {
        let stored = defaults.string(forKey: languageModeKey)
        let resolved = mode(for: stored)
        if stored != resolved.rawValue {
            defaults.set(resolved.rawValue, forKey: languageModeKey)
        }
        return resolved
    }

    /// The locale to publish as `\.locale`, choosing a language without
    /// discarding the rest of the user's regional setup.
    ///
    /// Language and region are configured separately in System Settings —
    /// 한국어 with region United States and a 12-hour clock is a normal setup.
    /// Rebuilding the locale from a bare language identifier (`Locale("ko-KR")`)
    /// silently drops the region, calendar and hour cycle, so dates and numbers
    /// would start formatting for a place the user does not live in. Instead we
    /// keep `systemLocale` and only graft the chosen language onto it.
    static func locale(
        for rawValue: String?,
        preferredLanguages: [String] = Locale.preferredLanguages,
        systemLocale: Locale = .autoupdatingCurrent,
        fallbackLanguageCode: String = "en"
    ) -> Locale {
        let languageCode = mode(for: rawValue).languageCode
            ?? negotiatedLanguageCode(from: preferredLanguages)
            ?? fallbackLanguageCode
        return systemLocale.withLanguageCode(languageCode)
    }

    /// The first of macOS's preferred languages the app actually has a catalog
    /// for — the same negotiation `Bundle` performs, made explicit so the
    /// result can be grafted onto the system locale.
    private static func negotiatedLanguageCode(from preferredLanguages: [String]) -> String? {
        for identifier in preferredLanguages {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier,
                  AppLanguage.supportedLanguageCodes.contains(code) else { continue }
            return code
        }
        return nil
    }

    /// The locale currently in effect for the app, honoring the override.
    static func currentLocale(defaults: UserDefaults = .standard) -> Locale {
        locale(for: defaults.string(forKey: languageModeKey))
    }

    /// The `.lproj` bundle matching `locale`, or nil when the app ships no
    /// catalog for that language.
    ///
    /// Returning nil rather than `Bundle.main` matters: the source language
    /// (`en`) has no `.lproj` of its own, and `Bundle.main.localizedString`
    /// resolves against the *system*-negotiated localization. Falling back to
    /// it would hand a Korean string back to someone who explicitly picked
    /// English while macOS is set to Korean — the very override this exists to
    /// honor.
    static func bundle(for locale: Locale) -> Bundle? {
        guard let languageCode = locale.language.languageCode?.identifier,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    /// Resolves a catalog key for AppKit surfaces.
    ///
    /// `NSMenuItem`, `NSStatusItem` tooltips and other AppKit views never see
    /// the SwiftUI `\.locale` environment, so `termMeshLanguage()` cannot reach
    /// them. Without this they render `Bundle.main`'s system-negotiated
    /// language and ignore the in-app override entirely, which is how the same
    /// command ends up Korean in one surface and English in another.
    ///
    /// SwiftUI code should keep using `Text`/`LocalizedStringKey` under
    /// `termMeshLanguage()` instead of calling this.
    static func localized(_ key: String, defaults: UserDefaults = .standard) -> String {
        guard let bundle = bundle(for: currentLocale(defaults: defaults)) else {
            // No catalog for this language, so the key already is the
            // source-language string.
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Calls `handler` whenever the effective app language changes.
    ///
    /// AppKit menus are built once and mutated in place, so they need an
    /// explicit signal to re-title themselves; SwiftUI views get this for free
    /// through `@AppStorage`.
    static func observeChanges(
        on center: NotificationCenter = .default,
        defaults: UserDefaults = .standard,
        handler: @escaping () -> Void
    ) -> NSObjectProtocol {
        var lastIdentifier = currentLocale(defaults: defaults).identifier
        return center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            let identifier = currentLocale(defaults: defaults).identifier
            guard identifier != lastIdentifier else { return }
            lastIdentifier = identifier
            handler()
        }
    }
}

private struct AppLanguageEnvironmentModifier: ViewModifier {
    @AppStorage(LanguageSettings.languageModeKey)
    private var languageMode = LanguageSettings.defaultMode.rawValue

    func body(content: Content) -> some View {
        content.environment(\.locale, LanguageSettings.locale(for: languageMode))
    }
}

extension Locale {
    /// This locale with its language replaced, preserving region, calendar,
    /// hour cycle and every other component.
    func withLanguageCode(_ code: String) -> Locale {
        guard language.languageCode?.identifier != code else { return self }
        var components = Locale.Components(locale: self)
        components.languageComponents.languageCode = Locale.LanguageCode(code)
        // Clear the outgoing language's script: Hangul is not a script for
        // English, and keeping it would produce `en-Kore-KR` for the bundle to
        // negotiate. ICU infers the right one for the incoming language.
        components.languageComponents.script = nil
        return Locale(components: components)
    }
}

extension View {
    /// Applies the app's language override while keeping "System Setting"
    /// tied to macOS's current locale. Each AppKit-hosted SwiftUI root uses
    /// this modifier because those windows do not inherit the WindowGroup
    /// environment.
    func termMeshLanguage() -> some View {
        modifier(AppLanguageEnvironmentModifier())
    }
}

/// Maps a search query in the display language back to the English terms the
/// settings keyword lists are written in.
///
/// Reads the compiled catalog for the active language and looks it up in
/// reverse: any entry whose translated value contains the query contributes its
/// English key. That keeps one keyword list per row instead of one per
/// language, and means a new translation makes its row searchable for free.
enum SettingsSearchIndex {
    private static var tableCache: [String: [String: String]] = [:]

    /// The catalog for `locale`, keyed by source string. Empty for the source
    /// language, which ships no `.lproj` — its keys already are English.
    static func table(for locale: Locale) -> [String: String] {
        let key = locale.language.languageCode?.identifier ?? locale.identifier
        if let cached = tableCache[key] { return cached }
        guard let bundle = LanguageSettings.bundle(for: locale),
              let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let table = NSDictionary(contentsOf: url) as? [String: String] else {
            tableCache[key] = [:]
            return [:]
        }
        tableCache[key] = table
        return table
    }

    static func englishTerms(matching query: String, locale: Locale) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        return table(for: locale)
            .filter { $0.value.lowercased().contains(needle) }
            .map { $0.key.lowercased() }
    }
}

/// Wraps a SwiftUI view that an `NSHostingView` owns directly.
///
/// A hosting view roots a fresh SwiftUI environment: nothing above it in the
/// AppKit view tree can inject `\.locale`, so overlays mounted this way (the
/// find bar, the IME input bar, the paste shelf, the command palette) ignored
/// the language override and rendered in whatever language macOS negotiated.
/// This is a named type rather than an inline modifier so the hosting views can
/// keep declaring their concrete `NSHostingView<…>` element type.
struct TermMeshHostedRoot<Content: View>: View {
    private let content: Content

    init(_ content: Content) {
        self.content = content
    }

    var body: some View {
        content.termMeshLanguage()
    }
}

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
        TerminalOverrideLocation.url(forFileName: overrideFileName)
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

/// Paste Shelf stores captured text as plaintext JSON under Application Support
/// and keeps it for `PasteShelfStore.unpinnedLifetime`. Terminal copies routinely
/// contain tokens and keys, so capture is opt-out-able without losing the image
/// path (⌘⇧V still imports a copied image and pinned items are untouched).
enum PasteShelfCaptureSettings {
    static let captureTextKey = "pasteShelf.captureCopiedText"
    static let defaultCaptureText = true

    static func captureTextEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: captureTextKey) == nil {
            return defaultCaptureText
        }
        return defaults.bool(forKey: captureTextKey)
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
