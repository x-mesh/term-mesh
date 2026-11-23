import AppKit
import SwiftUI

/// Free-space rule shared by the peer badge and the local sidebar warning, so
/// both call a disk "low" at the same point.
enum DiskSpace {
    static let lowAbsoluteBytes: UInt64 = 5 * 1024 * 1024 * 1024
    static let lowFraction = 0.10

    /// A volume that reports no capacity is never "low": a warning for a disk
    /// we cannot measure is worse than silence.
    static func isLow(available: UInt64, total: UInt64) -> Bool {
        guard total > 0 else { return false }
        if available < lowAbsoluteBytes { return true }
        return Double(available) / Double(total) < lowFraction
    }

    /// Absolute capacity, in the units people use for disks (GB, not GiB).
    static func capacity(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        switch value {
        case 0..<1_000_000_000: return String(format: "%.0fMB", value / 1_000_000)
        case 1_000_000_000..<1_000_000_000_000: return String(format: "%.1fGB", value / 1_000_000_000)
        default: return String(format: "%.1fTB", value / 1_000_000_000_000)
        }
    }

    struct Reading: Equatable {
        let available: UInt64
        let total: UInt64
        /// The volume's display name, such as "Macintosh HD".
        var name: String = ""
        /// Identifies the volume, so two paths on one volume count once.
        var volumePath: String = ""
        var isLow: Bool { DiskSpace.isLow(available: available, total: total) }
    }

    /// The volume that holds `path`. A path that does not exist yet, such as a
    /// worktree base directory created on first use, is measured at its
    /// nearest existing ancestor, which is the volume it will be created on.
    /// `volumeAvailableCapacityKey` excludes purgeable space, the same figure
    /// `df` and `reload.sh`'s free-space check see.
    static func volume(containing path: String) -> Reading? {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeNameKey,
            .volumeURLKey,
        ]),
              let available = values.volumeAvailableCapacity,
              let total = values.volumeTotalCapacity,
              available >= 0, total > 0 else {
            return nil
        }
        return Reading(
            available: UInt64(available),
            total: UInt64(total),
            name: values.volumeName ?? "",
            volumePath: values.volume?.path ?? ""
        )
    }

    /// The home volume, where git-kit worktrees, agent state and build caches
    /// live.
    static func homeVolume() -> Reading? {
        volume(containing: NSHomeDirectory())
    }

    /// Every volume agent builds fill: the home volume, plus the worktree base
    /// directory's volume when it is a different one. Lowest free space first.
    static func buildVolumes(worktreeBaseDir: String) -> [Reading] {
        var readings: [Reading] = []
        for reading in [homeVolume(), volume(containing: worktreeBaseDir)].compactMap({ $0 })
            where !readings.contains(where: { $0.volumePath == reading.volumePath }) {
            readings.append(reading)
        }
        return readings.sorted { $0.available < $1.available }
    }

    /// The volume the sidebar warns about: the first low one, else the one
    /// with the least free space. Low is partly a share of the volume's size,
    /// so the volume with the fewest free bytes is not always the low one.
    static func warningVolume(_ readings: [Reading]) -> Reading? {
        readings.first(where: \.isLow) ?? readings.first
    }
}

/// What `gc.status` reports, decoded for the settings card.
struct GcStatusSummary: Equatable {
    struct Category: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let entryCount: Int
        let candidateCount: Int
        let totalBytes: UInt64
        let reclaimableBytes: UInt64
    }

    struct LastSweep: Equatable {
        let at: Date
        let reclaimedBytes: UInt64
        let removed: Int
    }

    let categories: [Category]
    let lastSweep: LastSweep?

    func category(_ name: String) -> Category? {
        categories.first { $0.name == name }
    }

    static func parse(_ raw: String?) -> GcStatusSummary? {
        guard let object = decodeObject(raw),
              let rows = object["categories"] as? [[String: Any]] else {
            return nil
        }
        let categories = rows.compactMap { row -> Category? in
            guard let name = row["category"] as? String else { return nil }
            return Category(
                name: name,
                entryCount: int(row["entry_count"]),
                candidateCount: int(row["candidate_count"]),
                totalBytes: uint64(row["total_bytes"]),
                reclaimableBytes: uint64(row["reclaimable_bytes"])
            )
        }
        var lastSweep: LastSweep?
        if let sweep = object["last_sweep"] as? [String: Any],
           let atMs = (sweep["at_ms"] as? NSNumber)?.doubleValue {
            lastSweep = LastSweep(
                at: Date(timeIntervalSince1970: atMs / 1000),
                reclaimedBytes: uint64(sweep["reclaimed_bytes"]),
                removed: int(sweep["removed"])
            )
        }
        return GcStatusSummary(categories: categories, lastSweep: lastSweep)
    }
}

/// Reclaiming build caches through `gc.sweep`, and nothing else.
///
/// The socket takes a `categories` array; a missing or empty one means every
/// category, worktrees included. Every request is built here so the scope
/// cannot drift, and `isScopedToBuildCaches` re-checks the dry-run before the
/// app sends the applying request.
enum BuildCacheReclaim {
    static let category = "build_caches"

    static func statusParams() -> [String: Any] {
        ["categories": [category], "deep": true]
    }

    static func sweepParams(apply: Bool) -> [String: Any] {
        ["categories": [category], "deep": true, "apply": apply]
    }

    struct Outcome: Equatable {
        let path: String
        let category: String
        let action: String
        let reason: String
        let bytes: UInt64
    }

    struct SweepResult: Equatable {
        let applied: Bool
        let removed: Int
        let reclaimedBytes: UInt64
        let outcomes: [Outcome]

        var pending: [Outcome] { outcomes.filter { $0.action == "would_remove" } }
        var skipped: [Outcome] { outcomes.filter { $0.action == "skipped" } }
        var pendingBytes: UInt64 { pending.reduce(0) { $0 + $1.bytes } }
    }

    static func parseSweep(_ raw: String?) -> SweepResult? {
        guard let object = decodeObject(raw),
              let rows = object["outcomes"] as? [[String: Any]] else {
            return nil
        }
        let outcomes = rows.compactMap { row -> Outcome? in
            guard let path = row["path"] as? String,
                  let category = row["category"] as? String,
                  let action = row["action"] as? String else {
                return nil
            }
            return Outcome(
                path: path,
                category: category,
                action: action,
                reason: row["reason"] as? String ?? "",
                bytes: uint64(row["bytes"])
            )
        }
        return SweepResult(
            applied: object["applied"] as? Bool ?? false,
            removed: int(object["removed"]),
            reclaimedBytes: uint64(object["reclaimed_bytes"]),
            outcomes: outcomes
        )
    }

    static func isScopedToBuildCaches(_ result: SweepResult) -> Bool {
        result.outcomes.allSatisfy { $0.category == category }
    }
}

private func decodeObject(_ raw: String?) -> [String: Any]? {
    guard let raw, let data = raw.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func int(_ value: Any?) -> Int {
    (value as? NSNumber)?.intValue ?? 0
}

private func uint64(_ value: Any?) -> UInt64 {
    (value as? NSNumber)?.uint64Value ?? 0
}

// MARK: - Settings card

/// Disk usage on this Mac and what `tm-agent gc` can reclaim, with a reclaim
/// action for build caches only. Worktrees keep their own two-step delete in
/// the list below this card.
struct DiskUsageSection: View {
    private enum Phase: Equatable {
        case idle
        case loading
        case scanningBuildCaches
        case previewing
        case reclaiming
    }

    let worktreeBaseDir: String

    @State private var volumes: [DiskSpace.Reading] = []
    @State private var status: GcStatusSummary?
    @State private var buildCaches: GcStatusSummary.Category?
    @State private var phase: Phase = .idle
    @State private var preview: BuildCacheReclaim.SweepResult?
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Disk Usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(phase == .loading ? LocalizedStringKey("Scanning…") : LocalizedStringKey("Refresh")) {
                    Task { await refresh() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(phase != .idle)
            }
            .padding(.horizontal, 2)

            SettingsCard {
                if volumes.isEmpty {
                    SettingsCardRow("Free Space") {
                        Text("Unknown")
                            .foregroundColor(.secondary)
                    }
                }
                ForEach(Array(volumes.enumerated()), id: \.element.volumePath) { index, disk in
                    if index > 0 { SettingsCardDivider() }
                    SettingsCardRow("Free Space", verbatimSubtitle: disk.name.isEmpty ? nil : disk.name) {
                        Text(verbatim: freeSpaceText(disk))
                            .font(.system(size: 12, weight: disk.isLow ? .semibold : .regular))
                            .foregroundColor(disk.isLow ? .orange : .secondary)
                    }
                }

                SettingsCardDivider()

                SettingsCardRow(
                    "Build Caches",
                    verbatimSubtitle: buildCacheSubtitle
                ) {
                    HStack(spacing: 8) {
                        if phase == .scanningBuildCaches || phase == .previewing || phase == .reclaiming {
                            ProgressView().controlSize(.small)
                        }
                        Button(buildCaches == nil ? LocalizedStringKey("Measure") : LocalizedStringKey("Re-measure")) {
                            Task { await scanBuildCaches() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(phase != .idle)

                        Button("Reclaim…") {
                            Task { await previewReclaim() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(phase != .idle || (buildCaches?.candidateCount ?? 0) == 0)
                    }
                }

                ForEach(otherCategories) { category in
                    SettingsCardDivider()
                    GcCategoryRow(category: category)
                }

                if let sweep = status?.lastSweep {
                    SettingsCardDivider()
                    SettingsCardRow("Last Cleanup", verbatimSubtitle: lastSweepText(sweep)) {
                        EmptyView()
                    }
                }
            }

            Text("Only build caches are reclaimed here. They are rebuilt on the next build. Only worktrees that a term-mesh session or task points at are protected; a worktree you build in by hand is not. Reclaim the other categories with `tm-agent gc sweep`.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)

            if let message {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 2)
            }
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 2)
            }
        }
        .confirmationDialog(
            "Reclaim Build Caches?",
            isPresented: Binding(
                get: { preview != nil },
                set: { if !$0 { preview = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let preview {
                Button(
                    String(
                        format: LanguageSettings.localized("Remove %lld (%@)"),
                        locale: LanguageSettings.currentLocale(),
                        preview.pending.count,
                        DiskSpace.capacity(preview.pendingBytes)
                    ),
                    role: .destructive
                ) {
                    Task { await applyReclaim() }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let preview {
                Text(verbatim: previewMessage(preview))
            }
        }
        .task { await refresh() }
    }

    private var otherCategories: [GcStatusSummary.Category] {
        (status?.categories ?? []).filter {
            $0.name != BuildCacheReclaim.category && $0.totalBytes > 0
        }
    }

    private var buildCacheSubtitle: String {
        guard let buildCaches else {
            return LanguageSettings.localized("Not measured yet. Measuring walks every worktree and can take a while.")
        }
        return String(
            format: LanguageSettings.localized("%@ total · %@ reclaimable in %lld items"),
            locale: LanguageSettings.currentLocale(),
            DiskSpace.capacity(buildCaches.totalBytes),
            DiskSpace.capacity(buildCaches.reclaimableBytes),
            buildCaches.candidateCount
        )
    }

    private func freeSpaceText(_ disk: DiskSpace.Reading) -> String {
        String(
            format: LanguageSettings.localized("%@ free of %@"),
            locale: LanguageSettings.currentLocale(),
            DiskSpace.capacity(disk.available),
            DiskSpace.capacity(disk.total)
        )
    }

    private func lastSweepText(_ sweep: GcStatusSummary.LastSweep) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LanguageSettings.currentLocale()
        return String(
            format: LanguageSettings.localized("%@ · removed %lld, reclaimed %@"),
            locale: LanguageSettings.currentLocale(),
            formatter.localizedString(for: sweep.at, relativeTo: Date()),
            sweep.removed,
            DiskSpace.capacity(sweep.reclaimedBytes)
        )
    }

    private func previewMessage(_ preview: BuildCacheReclaim.SweepResult) -> String {
        let listed = preview.pending.prefix(5).map { "• \($0.path)" }
        var lines = listed
        if preview.pending.count > listed.count {
            lines.append(
                String(
                    format: LanguageSettings.localized("and %lld more"),
                    locale: LanguageSettings.currentLocale(),
                    preview.pending.count - listed.count
                )
            )
        }
        lines.append("")
        lines.append(LanguageSettings.localized("A build running in one of these folders will fail."))
        if !preview.skipped.isEmpty {
            lines.append("")
            lines.append(
                String(
                    format: LanguageSettings.localized("%lld are kept: used by a term-mesh session or task, or owned by a build script."),
                    locale: LanguageSettings.currentLocale(),
                    preview.skipped.count
                )
            )
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Daemon calls

    /// The daemon socket blocks for up to its timeout; never call it on main.
    private static func call(_ method: String, _ params: [String: Any], timeout: Int) async -> String? {
        await Task.detached(priority: .userInitiated) {
            TermMeshDaemon.shared.rpcCallRaw(method: method, params: params, timeout: timeout)
        }.value
    }

    private static func readVolumes(worktreeBaseDir: String) async -> [DiskSpace.Reading] {
        await Task.detached(priority: .userInitiated) {
            DiskSpace.buildVolumes(worktreeBaseDir: worktreeBaseDir)
        }.value
    }

    @MainActor
    private func refresh() async {
        phase = .loading
        errorMessage = nil
        volumes = await Self.readVolumes(worktreeBaseDir: worktreeBaseDir)
        let raw = await Self.call("gc.status", [:], timeout: 30)
        if let parsed = GcStatusSummary.parse(raw) {
            status = parsed
        } else {
            errorMessage = LanguageSettings.localized("The daemon did not answer. It may not be running, or the scan is still in progress — refresh again in a moment.")
        }
        phase = .idle
    }

    @MainActor
    private func scanBuildCaches() async {
        phase = .scanningBuildCaches
        errorMessage = nil
        let raw = await Self.call("gc.status", BuildCacheReclaim.statusParams(), timeout: 120)
        if let category = GcStatusSummary.parse(raw)?.category(BuildCacheReclaim.category) {
            buildCaches = category
        } else {
            errorMessage = LanguageSettings.localized("The daemon did not answer. It may not be running, or the scan is still in progress — refresh again in a moment.")
        }
        phase = .idle
    }

    @MainActor
    private func previewReclaim() async {
        phase = .previewing
        errorMessage = nil
        message = nil
        let raw = await Self.call("gc.sweep", BuildCacheReclaim.sweepParams(apply: false), timeout: 120)
        phase = .idle
        guard let result = BuildCacheReclaim.parseSweep(raw) else {
            errorMessage = LanguageSettings.localized("The daemon did not answer. It may not be running, or the scan is still in progress — refresh again in a moment.")
            return
        }
        guard BuildCacheReclaim.isScopedToBuildCaches(result) else {
            errorMessage = LanguageSettings.localized("The cleanup plan included more than build caches, so nothing was removed.")
            return
        }
        guard !result.pending.isEmpty else {
            message = LanguageSettings.localized("Nothing to reclaim: every build cache is used by a term-mesh session or task, or owned by a build script.")
            return
        }
        preview = result
    }

    @MainActor
    private func applyReclaim() async {
        preview = nil
        phase = .reclaiming
        let raw = await Self.call("gc.sweep", BuildCacheReclaim.sweepParams(apply: true), timeout: 300)
        phase = .idle
        var failure: String?
        if let result = BuildCacheReclaim.parseSweep(raw) {
            message = String(
                format: LanguageSettings.localized("Removed %lld build caches and reclaimed %@."),
                locale: LanguageSettings.currentLocale(),
                result.removed,
                DiskSpace.capacity(result.reclaimedBytes)
            )
        } else {
            failure = LanguageSettings.localized("Cleanup did not report back. It may still be running — refresh to see the result.")
        }
        await refresh()
        await scanBuildCaches()
        // Both refreshes clear the error line; the cleanup's own failure is the one to keep.
        if let failure { errorMessage = failure }
    }
}

private struct GcCategoryRow: View {
    let category: GcStatusSummary.Category

    var body: some View {
        if let title = Self.title(for: category.name) {
            SettingsCardRow(title, verbatimSubtitle: subtitle) { EmptyView() }
        } else {
            SettingsCardRow(verbatim: category.name, verbatimSubtitle: subtitle) { EmptyView() }
        }
    }

    private var subtitle: String {
        if category.candidateCount == 0 {
            return DiskSpace.capacity(category.totalBytes)
        }
        return String(
            format: LanguageSettings.localized("%@ total · %@ reclaimable in %lld items"),
            locale: LanguageSettings.currentLocale(),
            DiskSpace.capacity(category.totalBytes),
            DiskSpace.capacity(category.reclaimableBytes),
            category.candidateCount
        )
    }

    static func title(for name: String) -> LocalizedStringKey? {
        switch name {
        case "daemon_worktrees": return "Daemon Worktrees"
        case "gitkit_worktrees": return "git-kit Worktrees"
        case "project_checkouts": return "Agent Project Checkouts"
        case "team_results": return "Team Results"
        case "team_boards": return "Team Task Boards"
        case "headless_archives": return "Headless Archives"
        case "worktree_meta": return "Stale Worktree Registrations"
        case "logs": return "Logs"
        default: return nil
        }
    }
}

// MARK: - Sidebar warning

/// Appears only while a volume agent builds fill is low (the home volume, or
/// the worktree base directory's), and opens the disk card.
/// Reads the volume locally on a timer; `gc.status` walks every worktree and
/// is too expensive to poll.
struct SidebarLowDiskFooter: View {
    @State private var reading: DiskSpace.Reading?

    private static let interval: Duration = .seconds(60)

    var body: some View {
        // A container that exists while empty: `.task` on an empty `Group`
        // never starts, so the warning could never appear.
        VStack(spacing: 0) {
            if let reading, reading.isLow {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(
                        verbatim: String(
                            format: LanguageSettings.localized("Low disk · %@ free"),
                            locale: LanguageSettings.currentLocale(),
                            DiskSpace.capacity(reading.available)
                        )
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
                    Spacer(minLength: 4)
                    Button("Reclaim") {
                        // The app has no SwiftUI `Settings` scene, so nothing
                        // answers `showSettingsWindow:`; open the window the
                        // way the ⌘, menu item does.
                        SettingsWindowController.shared.show()
                        NSApp.activate(ignoringOtherApps: true)
                        // Post after the window exists, or a settings view
                        // created by `show()` misses the navigation.
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .settingsNavigateToSection,
                                object: nil,
                                userInfo: [SettingsNavigationUserInfoKey.section: SettingsSection.worktrees.rawValue]
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
                    .help("Open Settings > Worktrees to reclaim build caches")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .task {
            while !Task.isCancelled {
                let worktreeBaseDir = TermMeshDaemon.shared.worktreeBaseDir
                let next = await Task.detached(priority: .utility) {
                    DiskSpace.warningVolume(DiskSpace.buildVolumes(worktreeBaseDir: worktreeBaseDir))
                }.value
                if next != reading { reading = next }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }
}
