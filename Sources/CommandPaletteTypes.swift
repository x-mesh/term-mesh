import Foundation
import AppKit
import SwiftUI

// MARK: - CommandPalette Types
// Extracted from ContentView.swift

enum CommandPaletteMode {
    case commands
    case renameInput(CommandPaletteRenameTarget)
    case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
}

enum CommandPaletteListScope: String {
    case commands
    case switcher
    /// Peer workspaces across every known host, opened as a live mirror.
    ///
    /// Deliberately mirror-only, not "everything reachable on a peer". A
    /// remote *surface* can also be pulled into the current workspace as a
    /// pane, but the two close differently: a mirror's pane close forwards
    /// upstream and ends the remote pane, while an adopted pane's close only
    /// detaches locally (gated by the uncollected-work sheet) and leaves the
    /// remote running. Listing both here would make Return mean two different
    /// things depending on which row is selected, so surfaces stay in the
    /// sidebar's "Open Surface as Pane…", where the choice is explicit.
    case peers
}

struct CommandPaletteRenameTarget: Equatable {
    enum Kind: Equatable {
        case workspace(workspaceId: UUID)
        case tab(workspaceId: UUID, panelId: UUID)
    }

    let kind: Kind
    let currentName: String

    var title: String {
        switch kind {
        case .workspace:
            return "Rename Workspace"
        case .tab:
            return "Rename Tab"
        }
    }

    var description: String {
        switch kind {
        case .workspace:
            return "Choose a custom workspace name."
        case .tab:
            return "Choose a custom tab name."
        }
    }

    var placeholder: String {
        switch kind {
        case .workspace:
            return "Workspace name"
        case .tab:
            return "Tab name"
        }
    }
}

struct CommandPaletteRestoreFocusTarget {
    let workspaceId: UUID
    let panelId: UUID
}

enum CommandPaletteInputFocusTarget {
    case search
    case rename
}

enum CommandPaletteTextSelectionBehavior {
    case caretAtEnd
    case selectAll
}

enum CommandPaletteTrailingLabelStyle {
    case shortcut
    case kind
}

struct CommandPaletteTrailingLabel {
    let text: String
    let style: CommandPaletteTrailingLabelStyle
}

/// Leading status glyph for a palette row.
///
/// Only rows that actually carry state get one — today that is the peer
/// scope, where a host is connecting / reachable / unreachable and the row's
/// meaning changes with it. Workspace and tab rows have no comparable state,
/// so they stay text-only rather than growing a decorative icon column.
///
/// Shapes and tints deliberately match `SidebarViews`' `hostStatusIcon`: the
/// same host reads the same way whether it is found in the sidebar or the
/// palette, which is the whole point of a shared vocabulary.
struct CommandPaletteLeadingIcon {
    enum Kind {
        /// SF Symbol name.
        case symbol(String)
        /// Indeterminate work in flight — a real spinner, not a static glyph.
        case progress
    }

    let kind: Kind
    let tint: Color?
    /// Tooltip, used to carry a failure reason that has no room in the row.
    let help: String?

    init(kind: Kind, tint: Color? = nil, help: String? = nil) {
        self.kind = kind
        self.tint = tint
        self.help = help
    }
}

struct CommandPaletteInputFocusPolicy {
    let focusTarget: CommandPaletteInputFocusTarget
    let selectionBehavior: CommandPaletteTextSelectionBehavior

    static let search = CommandPaletteInputFocusPolicy(
        focusTarget: .search,
        selectionBehavior: .caretAtEnd
    )
}

struct CommandPaletteCommand: Identifiable {
    let id: String
    let rank: Int
    let title: String
    let subtitle: String
    let shortcutHint: String?
    let keywords: [String]
    let dismissOnRun: Bool
    let action: () -> Void
    /// Declared last, defaulted, so the ~100 existing call sites that end at
    /// `action:` keep compiling untouched.
    var leadingIcon: CommandPaletteLeadingIcon? = nil
    /// Compact count shown just before the kind badge (e.g. "2p" for panes).
    /// The sidebar already abbreviates this way, so the palette does too
    /// rather than spelling out "2 panes" and eating the row.
    var trailingCount: String? = nil

    var searchableTexts: [String] {
        [title, subtitle] + keywords
    }
}

struct CommandPaletteUsageEntry: Codable {
    var useCount: Int
    var lastUsedAt: TimeInterval
}

struct CommandPaletteContextSnapshot {
    private var boolValues: [String: Bool] = [:]
    private var stringValues: [String: String] = [:]

    mutating func setBool(_ key: String, _ value: Bool) {
        boolValues[key] = value
    }

    mutating func setString(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else {
            stringValues.removeValue(forKey: key)
            return
        }
        stringValues[key] = value
    }

    func bool(_ key: String) -> Bool {
        boolValues[key] ?? false
    }

    func string(_ key: String) -> String? {
        stringValues[key]
    }
}

enum CommandPaletteContextKeys {
    static let hasWorkspace = "workspace.hasSelection"
    static let workspaceName = "workspace.name"
    static let workspaceHasCustomName = "workspace.hasCustomName"
    static let workspaceShouldPin = "workspace.shouldPin"

    static let hasFocusedPanel = "panel.hasFocus"
    static let panelName = "panel.name"
    static let panelIsBrowser = "panel.isBrowser"
    static let panelIsTerminal = "panel.isTerminal"
    static let panelHasCustomName = "panel.hasCustomName"
    static let panelShouldPin = "panel.shouldPin"
    static let panelHasUnread = "panel.hasUnread"

    static let updateHasAvailable = "update.hasAvailable"

    static func terminalOpenTargetAvailable(_ target: TerminalDirectoryOpenTarget) -> String {
        "terminal.openTarget.\(target.rawValue).available"
    }
}

struct CommandPaletteCommandContribution {
    let commandId: String
    let title: (CommandPaletteContextSnapshot) -> String
    let subtitle: (CommandPaletteContextSnapshot) -> String
    let shortcutHint: String?
    let keywords: [String]
    let dismissOnRun: Bool
    let when: (CommandPaletteContextSnapshot) -> Bool
    let enablement: (CommandPaletteContextSnapshot) -> Bool

    init(
        commandId: String,
        title: @escaping (CommandPaletteContextSnapshot) -> String,
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        shortcutHint: String? = nil,
        keywords: [String] = [],
        dismissOnRun: Bool = true,
        when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
        enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
    ) {
        self.commandId = commandId
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.when = when
        self.enablement = enablement
    }
}

struct CommandPaletteHandlerRegistry {
    private var handlers: [String: () -> Void] = [:]

    mutating func register(commandId: String, handler: @escaping () -> Void) {
        handlers[commandId] = handler
    }

    func handler(for commandId: String) -> (() -> Void)? {
        handlers[commandId]
    }
}

struct CommandPaletteSearchResult: Identifiable {
    let command: CommandPaletteCommand
    let score: Int
    let titleMatchIndices: Set<Int>

    var id: String { command.id }
}

struct CommandPaletteSwitcherWindowContext {
    let windowId: UUID
    let tabManager: TabManager
    let selectedWorkspaceId: UUID?
    let windowLabel: String?
}

