import AppKit

enum FinderServicePathResolver {
    private static func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1 && canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }

    static func orderedUniqueDirectories(from pathURLs: [URL]) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for url in pathURLs {
            let standardized = url.standardizedFileURL
            let directoryURL = standardized.hasDirectoryPath ? standardized : standardized.deletingLastPathComponent()
            let path = canonicalDirectoryPath(directoryURL.path(percentEncoded: false))
            guard !path.isEmpty else { continue }
            if seen.insert(path).inserted {
                directories.append(path)
            }
        }

        return directories
    }
}

enum TerminalDirectoryOpenTarget: String, CaseIterable {
    case vscode
    case cursor
    case windsurf
    case antigravity
    case finder
    case terminal
    case iterm2
    case ghostty
    case warp
    case xcode
    case androidStudio
    case zed

    struct DetectionEnvironment {
        let homeDirectoryPath: String
        let fileExistsAtPath: (String) -> Bool

        static let live = DetectionEnvironment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExistsAtPath: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    static var commandPaletteShortcutTargets: [Self] {
        Array(allCases)
    }

    static func availableTargets(in environment: DetectionEnvironment = .live) -> Set<Self> {
        Set(commandPaletteShortcutTargets.filter { $0.isAvailable(in: environment) })
    }

    static let cachedLiveAvailableTargets: Set<Self> = availableTargets(in: .live)

    var commandPaletteCommandId: String {
        "palette.terminalOpenDirectory.\(rawValue)"
    }

    var commandPaletteTitle: String {
        switch self {
        case .vscode:
            return "Open Current Directory in VS Code"
        case .cursor:
            return "Open Current Directory in Cursor"
        case .windsurf:
            return "Open Current Directory in Windsurf"
        case .antigravity:
            return "Open Current Directory in Antigravity"
        case .finder:
            return "Open Current Directory in Finder"
        case .terminal:
            return "Open Current Directory in Terminal"
        case .iterm2:
            return "Open Current Directory in iTerm2"
        case .ghostty:
            return "Open Current Directory in Ghostty"
        case .warp:
            return "Open Current Directory in Warp"
        case .xcode:
            return "Open Current Directory in Xcode"
        case .androidStudio:
            return "Open Current Directory in Android Studio"
        case .zed:
            return "Open Current Directory in Zed"
        }
    }

    var commandPaletteKeywords: [String] {
        let common = ["terminal", "directory", "open", "ide"]
        switch self {
        case .vscode:
            return common + ["vs", "code", "visual", "studio"]
        case .cursor:
            return common + ["cursor"]
        case .windsurf:
            return common + ["windsurf"]
        case .antigravity:
            return common + ["antigravity"]
        case .finder:
            return common + ["finder", "file", "manager", "reveal"]
        case .terminal:
            return common + ["terminal", "shell"]
        case .iterm2:
            return common + ["iterm", "iterm2", "terminal", "shell"]
        case .ghostty:
            return common + ["ghostty", "terminal", "shell"]
        case .warp:
            return common + ["warp", "terminal", "shell"]
        case .xcode:
            return common + ["xcode", "apple"]
        case .androidStudio:
            return common + ["android", "studio"]
        case .zed:
            return common + ["zed"]
        }
    }

    func isAvailable(in environment: DetectionEnvironment = .live) -> Bool {
        applicationPath(in: environment) != nil
    }

    func applicationURL(in environment: DetectionEnvironment = .live) -> URL? {
        guard let path = applicationPath(in: environment) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func applicationPath(in environment: DetectionEnvironment) -> String? {
        for path in expandedCandidatePaths(in: environment) where environment.fileExistsAtPath(path) {
            return path
        }
        return nil
    }

    private func expandedCandidatePaths(in environment: DetectionEnvironment) -> [String] {
        let globalPrefix = "/Applications/"
        let userPrefix = "\(environment.homeDirectoryPath)/Applications/"
        var expanded: [String] = []

        for candidate in applicationBundlePathCandidates {
            expanded.append(candidate)
            if candidate.hasPrefix(globalPrefix) {
                let suffix = String(candidate.dropFirst(globalPrefix.count))
                expanded.append(userPrefix + suffix)
            }
        }

        return uniquePreservingOrder(expanded)
    }

    private var applicationBundlePathCandidates: [String] {
        switch self {
        case .vscode:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .cursor:
            return [
                "/Applications/Cursor.app",
                "/Applications/Cursor Preview.app",
                "/Applications/Cursor Nightly.app",
            ]
        case .windsurf:
            return ["/Applications/Windsurf.app"]
        case .antigravity:
            return ["/Applications/Antigravity.app"]
        case .finder:
            return ["/System/Library/CoreServices/Finder.app"]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .iterm2:
            return [
                "/Applications/iTerm.app",
                "/Applications/iTerm2.app",
            ]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .warp:
            return ["/Applications/Warp.app"]
        case .xcode:
            return ["/Applications/Xcode.app"]
        case .androidStudio:
            return ["/Applications/Android Studio.app"]
        case .zed:
            return [
                "/Applications/Zed.app",
                "/Applications/Zed Preview.app",
                "/Applications/Zed Nightly.app",
            ]
        }
    }

    private func uniquePreservingOrder(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var deduped: [String] = []
        for path in paths where seen.insert(path).inserted {
            deduped.append(path)
        }
        return deduped
    }
}

enum WorkspaceShortcutMapper {
    /// Maps Cmd+digit workspace shortcuts to a zero-based workspace index.
    /// Cmd+1...Cmd+8 target fixed indices; Cmd+9 always targets the last workspace.
    static func workspaceIndex(forCommandDigit digit: Int, workspaceCount: Int) -> Int? {
        guard workspaceCount > 0 else { return nil }
        guard (1...9).contains(digit) else { return nil }

        if digit == 9 {
            return workspaceCount - 1
        }

        let index = digit - 1
        return index < workspaceCount ? index : nil
    }

    /// Returns the primary Cmd+digit badge to display for a workspace row.
    /// Picks the lowest digit that maps to that row index.
    static func commandDigitForWorkspace(at index: Int, workspaceCount: Int) -> Int? {
        guard index >= 0 && index < workspaceCount else { return nil }
        for digit in 1...9 {
            if workspaceIndex(forCommandDigit: digit, workspaceCount: workspaceCount) == index {
                return digit
            }
        }
        return nil
    }
}

func browserOmnibarSelectionDeltaForCommandNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
    guard isCommandOrControlOnly else { return nil }
    if chars == "n" { return 1 }
    if chars == "p" { return -1 }
    return nil
}

func browserOmnibarSelectionDeltaForArrowNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    keyCode: UInt16
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [] else { return nil }
    switch keyCode {
    case 125: return 1
    case 126: return -1
    default: return nil
    }
}

func browserOmnibarNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

func browserOmnibarShouldSubmitOnReturn(flags: NSEvent.ModifierFlags) -> Bool {
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    return normalizedFlags == [] || normalizedFlags == [.shift]
}

func commandPaletteSelectionDeltaForKeyboardNavigation(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Int? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let normalizedChars = chars.lowercased()

    if normalizedFlags == [] {
        switch keyCode {
        case 125: return 1    // Down arrow
        case 126: return -1   // Up arrow
        default: break
        }
    }

    if normalizedFlags == [.control] {
        // Control modifiers can surface as either printable chars or ASCII control chars.
        if keyCode == 45 || normalizedChars == "n" || normalizedChars == "\u{0e}" { return 1 }    // Ctrl+N
        if keyCode == 35 || normalizedChars == "p" || normalizedChars == "\u{10}" { return -1 }   // Ctrl+P
        if keyCode == 38 || normalizedChars == "j" || normalizedChars == "\u{0a}" { return 1 }    // Ctrl+J
        if keyCode == 40 || normalizedChars == "k" || normalizedChars == "\u{0b}" { return -1 }   // Ctrl+K
    }

    return nil
}

enum BrowserZoomShortcutAction: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

struct CommandPaletteDebugResultRow {
    let commandId: String
    let title: String
    let shortcutHint: String?
    let trailingLabel: String?
    let score: Int
}

struct CommandPaletteDebugSnapshot {
    let query: String
    let mode: String
    let results: [CommandPaletteDebugResultRow]
    /// Whether the palette's search field holds SwiftUI focus. Every palette
    /// navigation key is an `onKeyPress` on that field, so a key sent while
    /// this is false reaches no handler at all — which is indistinguishable
    /// from a handled key that moved nothing unless it is reported.
    let searchFocused: Bool
    let renameFocused: Bool
    /// How many navigation keys reached the handler and were dropped because
    /// the result list was empty at that instant.
    let navigationIgnoredEmptyCount: Int

    static let empty = CommandPaletteDebugSnapshot(
        query: "",
        mode: "commands",
        results: [],
        searchFocused: false,
        renameFocused: false,
        navigationIgnoredEmptyCount: 0
    )
}

func browserZoomShortcutAction(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> BrowserZoomShortcutAction? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let key = chars.lowercased()
    let hasCommand = normalizedFlags.contains(.command)
    let hasOnlyCommandAndOptionalShift = hasCommand && normalizedFlags.isDisjoint(with: [.control, .option])

    guard hasOnlyCommandAndOptionalShift else { return nil }

    if key == "=" || key == "+" || keyCode == 24 || keyCode == 69 { // kVK_ANSI_Equal / kVK_ANSI_KeypadPlus
        return .zoomIn
    }

    if key == "-" || key == "_" || keyCode == 27 || keyCode == 78 { // kVK_ANSI_Minus / kVK_ANSI_KeypadMinus
        return .zoomOut
    }

    if key == "0" || keyCode == 29 || keyCode == 82 { // kVK_ANSI_0 / kVK_ANSI_Keypad0
        return .reset
    }

    return nil
}

func shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
    firstResponderIsWindow: Bool,
    hostedSize: CGSize,
    hostedHiddenInHierarchy: Bool,
    hostedAttachedToWindow: Bool
) -> Bool {
    guard firstResponderIsWindow else { return false }
    let tinyGeometry = hostedSize.width <= 1 || hostedSize.height <= 1
    return tinyGeometry || hostedHiddenInHierarchy || !hostedAttachedToWindow
}

func shouldRouteTerminalFontZoomShortcutToGhostty(
    firstResponderIsGhostty: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    guard firstResponderIsGhostty else { return false }
    return browserZoomShortcutAction(flags: flags, chars: chars, keyCode: keyCode) != nil
}

func termMeshOwningGhosttyView(for responder: NSResponder?) -> GhosttyNSView? {
    guard let responder else { return nil }
    if let ghosttyView = responder as? GhosttyNSView {
        return ghosttyView
    }

    if let view = responder as? NSView,
       let ghosttyView = termMeshOwningGhosttyView(for: view) {
        return ghosttyView
    }

    if let textView = responder as? NSTextView,
       let delegateView = textView.delegate as? NSView,
       let ghosttyView = termMeshOwningGhosttyView(for: delegateView) {
        return ghosttyView
    }

    var current = responder.nextResponder
    while let next = current {
        if let ghosttyView = next as? GhosttyNSView {
            return ghosttyView
        }
        if let view = next as? NSView,
           let ghosttyView = termMeshOwningGhosttyView(for: view) {
            return ghosttyView
        }
        current = next.nextResponder
    }

    return nil
}

private func termMeshOwningGhosttyView(for view: NSView) -> GhosttyNSView? {
    if let ghosttyView = view as? GhosttyNSView {
        return ghosttyView
    }

    var current: NSView? = view.superview
    while let candidate = current {
        if let ghosttyView = candidate as? GhosttyNSView {
            return ghosttyView
        }
        current = candidate.superview
    }

    return nil
}

#if DEBUG
func browserZoomShortcutTraceCandidate(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    guard normalizedFlags.contains(.command) else { return false }

    let key = chars.lowercased()
    if key == "=" || key == "+" || key == "-" || key == "_" || key == "0" {
        return true
    }
    switch keyCode {
    case 24, 27, 29, 69, 78, 82: // ANSI and keypad zoom keys
        return true
    default:
        return false
    }
}

func browserZoomShortcutTraceFlagsString(_ flags: NSEvent.ModifierFlags) -> String {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    var parts: [String] = []
    if normalizedFlags.contains(.command) { parts.append("Cmd") }
    if normalizedFlags.contains(.shift) { parts.append("Shift") }
    if normalizedFlags.contains(.option) { parts.append("Opt") }
    if normalizedFlags.contains(.control) { parts.append("Ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func browserZoomShortcutTraceActionString(_ action: BrowserZoomShortcutAction?) -> String {
    guard let action else { return "none" }
    switch action {
    case .zoomIn: return "zoomIn"
    case .zoomOut: return "zoomOut"
    case .reset: return "reset"
    }
}
#endif

func shouldSuppressWindowMoveForFolderDrag(hitView: NSView?) -> Bool {
    var candidate = hitView
    while let view = candidate {
        if view is DraggableFolderNSView {
            return true
        }
        candidate = view.superview
    }
    return false
}

func shouldSuppressWindowMoveForFolderDrag(window: NSWindow, event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown,
          window.isMovable,
          let contentView = window.contentView else {
        return false
    }

    let contentPoint = contentView.convert(event.locationInWindow, from: nil)
    let hitView = contentView.hitTest(contentPoint)
    return shouldSuppressWindowMoveForFolderDrag(hitView: hitView)
}
