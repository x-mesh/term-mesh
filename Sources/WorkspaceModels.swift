import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CoreText

func termMeshSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    switch context {
    case GHOSTTY_SURFACE_CONTEXT_WINDOW:
        return "window"
    case GHOSTTY_SURFACE_CONTEXT_TAB:
        return "tab"
    case GHOSTTY_SURFACE_CONTEXT_SPLIT:
        return "split"
    default:
        return "unknown(\(context))"
    }
}

func termMeshCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    guard let quicklookFont = ghostty_surface_quicklook_font(surface) else {
        return nil
    }

    let ctFont = Unmanaged<CTFont>.fromOpaque(quicklookFont).takeRetainedValue()
    let points = Float(CTFontGetSize(ctFont))
    guard points > 0 else { return nil }
    return points
}

func termMeshInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> ghostty_surface_config_s {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    var config = inherited

    // Make runtime zoom inheritance explicit, even when Ghostty's
    // inherit-font-size config is disabled.
    let runtimePoints = termMeshCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.font_size = points
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.font_size)
    dlog(
        "zoom.inherit context=\(termMeshSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}

struct SidebarStatusEntry {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let timestamp: Date
}

/// Declaration order is display priority: a later case outranks an earlier one.
enum ProgramStatusState: Int {
    case idle
    case done
    case working
    case error
    case blocked

    var wireName: String {
        switch self {
        case .idle: return "idle"
        case .done: return "done"
        case .working: return "working"
        case .error: return "error"
        case .blocked: return "blocked"
        }
    }
}

/// Declaration order is priority among blocked surfaces.
enum ProgramStatusKind: Int {
    case auth
    case question
    case permission

    var wireName: String {
        switch self {
        case .auth: return "auth"
        case .question: return "question"
        case .permission: return "permission"
        }
    }
}

/// An agent's latest OSC 7501 report for one surface. `msg` and `title` are
/// deliberately not kept: they carry command text the sidebar must not show.
struct SurfaceProgramStatus: Equatable {
    let state: ProgramStatusState
    let kind: ProgramStatusKind?
    let app: String?
}

enum ProgramStatusReport: Equatable {
    case set(SurfaceProgramStatus)
    case clear
}

enum ProgramStatusReducer {
    enum Event {
        case report
        /// Ghostty sends this on every shell prompt mark, including the one the
        /// shell draws right after a reporting command returns, so it is not
        /// evidence that an agent's status ended.
        case promptStart
    }

    enum RawState {
        case idle, working, done, blocked, error, clear
    }

    static func report(
        event: Event,
        state: RawState,
        kind: ProgramStatusKind?,
        app: String?
    ) -> ProgramStatusReport? {
        if event == .promptStart { return nil }
        let resolved: ProgramStatusState
        switch state {
        case .clear: return .clear
        case .idle: resolved = .idle
        case .working: resolved = .working
        case .done: resolved = .done
        case .blocked: resolved = .blocked
        case .error: resolved = .error
        }
        let trimmedApp = app?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .set(SurfaceProgramStatus(
            state: resolved,
            kind: resolved == .blocked ? kind : nil,
            app: (trimmedApp?.isEmpty ?? true) ? nil : trimmedApp
        ))
    }

    /// Returns nil when the report changes nothing, so a repeated report (Claude
    /// sends `state=clear` three times on exit) does not invalidate observers.
    static func applying(
        _ report: ProgramStatusReport,
        surfaceId: UUID,
        to statuses: [UUID: SurfaceProgramStatus]
    ) -> [UUID: SurfaceProgramStatus]? {
        var next = statuses
        switch report {
        case .clear:
            guard next.removeValue(forKey: surfaceId) != nil else { return nil }
        case .set(let status):
            guard next[surfaceId] != status else { return nil }
            next[surfaceId] = status
        }
        return next
    }

    /// Statuses of surfaces that are no longer live are ignored even if a close
    /// path failed to remove them.
    static func dominant(
        _ statuses: [UUID: SurfaceProgramStatus],
        liveSurfaceIds: Set<UUID>
    ) -> SurfaceProgramStatus? {
        statuses
            .filter { liveSurfaceIds.contains($0.key) }
            .max { lhs, rhs in
                let l = (lhs.value.state.rawValue, lhs.value.kind?.rawValue ?? -1)
                let r = (rhs.value.state.rawValue, rhs.value.kind?.rawValue ?? -1)
                if l != r { return l < r }
                return lhs.key.uuidString > rhs.key.uuidString
            }?
            .value
    }
}

enum SidebarLogLevel: String {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState {
    let value: Double
    let label: String?
}

struct SidebarGitBranchState {
    let branch: String
    let isDirty: Bool
    var dirtyFileCount: Int?
}

// MARK: - Shell Integration Health

enum ShellIntegrationSignal: String {
    case reportPwd = "report_pwd"
    case reportTty = "report_tty"
    case reportGitBranch = "report_git_branch"
}

enum IntegrationStatus: String {
    case starting
    case healthy
    case stale
    case partial
    case notLoaded
    case agentMode

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .healthy: return "Healthy"
        case .stale: return "Stale"
        case .partial: return "Partial"
        case .notLoaded: return "Not Loaded"
        case .agentMode: return "Agent Mode"
        }
    }
}

struct ShellIntegrationHealth {
    let createdAt: Date
    var lastReportPwd: Date?
    var lastReportTty: Date?
    var lastReportGitBranch: Date?
    var reportPwdCount: Int = 0
    var reportTtyCount: Int = 0
    var reportGitBranchCount: Int = 0

    var status: IntegrationStatus {
        let age = Date().timeIntervalSince(createdAt)
        if age < 5.0 { return .starting }
        if reportPwdCount == 0 && reportTtyCount == 0 { return .notLoaded }
        if reportTtyCount > 0 && reportPwdCount == 0 { return .partial }
        if let lastPwd = lastReportPwd, Date().timeIntervalSince(lastPwd) > 300 { return .stale }
        return .healthy
    }

    mutating func record(_ signal: ShellIntegrationSignal) {
        let now = Date()
        switch signal {
        case .reportPwd:
            lastReportPwd = now
            reportPwdCount += 1
        case .reportTty:
            lastReportTty = now
            reportTtyCount += 1
        case .reportGitBranch:
            lastReportGitBranch = now
            reportGitBranchCount += 1
        }
    }
}

enum SidebarBranchOrdering {
    struct BranchEntry: Equatable {
        let name: String
        let isDirty: Bool
    }

    struct BranchDirectoryEntry: Equatable {
        let branch: String?
        let isDirty: Bool
        let directory: String?
    }

    struct BranchDirectoryDisplayLine: Equatable {
        let branch: String?
        let directory: String?
    }

    static func orderedPaneIds(tree: ExternalTreeNode) -> [String] {
        switch tree {
        case .pane(let pane):
            return [pane.id]
        case .split(let split):
            // Bonsplit split order matches visual order for both horizontal and vertical splits.
            return orderedPaneIds(tree: split.first) + orderedPaneIds(tree: split.second)
        }
    }

    static func orderedPanelIds(
        tree: ExternalTreeNode,
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []

        for paneId in orderedPaneIds(tree: tree) {
            for panelId in paneTabs[paneId] ?? [] {
                if seen.insert(panelId).inserted {
                    ordered.append(panelId)
                }
            }
        }

        for panelId in fallbackPanelIds {
            if seen.insert(panelId).inserted {
                ordered.append(panelId)
            }
        }

        return ordered
    }

    static func orderedUniqueBranches(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchEntry] {
        var orderedNames: [String] = []
        var branchDirty: [String: Bool] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelBranches[panelId] else { continue }
            let name = state.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            if branchDirty[name] == nil {
                orderedNames.append(name)
                branchDirty[name] = state.isDirty
            } else if state.isDirty {
                branchDirty[name] = true
            }
        }

        if orderedNames.isEmpty, let fallbackBranch {
            let name = fallbackBranch.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return [BranchEntry(name: name, isDirty: fallbackBranch.isDirty)]
            }
        }

        return orderedNames.map { name in
            BranchEntry(name: name, isDirty: branchDirty[name] ?? false)
        }
    }

    static func orderedUniqueBranchDirectoryEntries(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        panelDirectories: [UUID: String],
        defaultDirectory: String?,
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchDirectoryEntry] {
        struct EntryKey: Hashable {
            let directory: String?
            let branch: String?
        }

        struct MutableEntry {
            var branch: String?
            var isDirty: Bool
            var directory: String?
        }

        func normalized(_ text: String?) -> String? {
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func canonicalDirectoryKey(_ directory: String?) -> String? {
            guard let directory = normalized(directory) else { return nil }
            let expanded = NSString(string: directory).expandingTildeInPath
            let standardized = NSString(string: expanded).standardizingPath
            let cleaned = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        let normalizedFallbackBranch = normalized(fallbackBranch?.branch)
        let shouldUseFallbackBranchPerPanel = !orderedPanelIds.contains {
            normalized(panelBranches[$0]?.branch) != nil
        }
        let defaultBranchForPanels = shouldUseFallbackBranchPerPanel ? normalizedFallbackBranch : nil
        let defaultBranchDirty = shouldUseFallbackBranchPerPanel ? (fallbackBranch?.isDirty ?? false) : false

        var order: [EntryKey] = []
        var entries: [EntryKey: MutableEntry] = [:]

        for panelId in orderedPanelIds {
            let panelBranch = normalized(panelBranches[panelId]?.branch)
            let branch = panelBranch ?? defaultBranchForPanels
            let directory = normalized(panelDirectories[panelId] ?? defaultDirectory)
            guard branch != nil || directory != nil else { continue }

            let panelDirty = panelBranch != nil
                ? (panelBranches[panelId]?.isDirty ?? false)
                : defaultBranchDirty

            let key: EntryKey
            if let directoryKey = canonicalDirectoryKey(directory) {
                // Keep one line per directory and allow the latest branch state to overwrite.
                key = EntryKey(directory: directoryKey, branch: nil)
            } else {
                key = EntryKey(directory: nil, branch: branch)
            }

            guard key.directory != nil || key.branch != nil else { continue }

            if var existing = entries[key] {
                if key.directory != nil {
                    if let branch {
                        existing.branch = branch
                        existing.isDirty = panelDirty
                    } else if existing.branch == nil {
                        existing.isDirty = panelDirty
                    }
                    if let directory {
                        existing.directory = directory
                    }
                    entries[key] = existing
                } else if panelDirty {
                    existing.isDirty = true
                    entries[key] = existing
                }
            } else {
                order.append(key)
                entries[key] = MutableEntry(branch: branch, isDirty: panelDirty, directory: directory)
            }
        }

        if order.isEmpty {
            let fallbackDirectory = normalized(defaultDirectory)
            if normalizedFallbackBranch != nil || fallbackDirectory != nil {
                return [
                    BranchDirectoryEntry(
                        branch: normalizedFallbackBranch,
                        isDirty: fallbackBranch?.isDirty ?? false,
                        directory: fallbackDirectory
                    )
                ]
            }
        }

        return order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return BranchDirectoryEntry(
                branch: entry.branch,
                isDirty: entry.isDirty,
                directory: entry.directory
            )
        }
    }

    static func branchDirectoryDisplayLines(
        entries: [BranchDirectoryEntry],
        showGitBranch: Bool,
        homeDirectory: String
    ) -> [BranchDirectoryDisplayLine] {
        entries.compactMap { entry in
            let branch: String? = {
                guard showGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()
            let directory = shortenedSidebarPath(entry.directory, homeDirectory: homeDirectory)

            guard branch != nil || directory != nil else { return nil }
            return BranchDirectoryDisplayLine(branch: branch, directory: directory)
        }
    }

    static func shortenedSidebarPath(_ path: String?, homeDirectory: String) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == homeDirectory {
            return "~"
        }
        if trimmed.hasPrefix(homeDirectory + "/") {
            return "~" + trimmed.dropFirst(homeDirectory.count)
        }
        return trimmed
    }
}

struct ClosedBrowserPanelRestoreSnapshot {
    let workspaceId: UUID
    let url: URL?
    let originalPaneId: UUID
    let originalTabIndex: Int
    let fallbackSplitOrientation: SplitOrientation?
    let fallbackSplitInsertFirst: Bool
    let fallbackAnchorPaneId: UUID?
}
