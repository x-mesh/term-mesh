import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo
import Combine
import os

// MARK: - Tab Type Alias for Backwards Compatibility
// The old Tab class is replaced by Workspace
typealias Tab = Workspace

// MARK: - Session Restore

enum SessionRestoreMode: String, CaseIterable, Identifiable {
    case off
    case always

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Start fresh"
        case .always: return "Restore previous session"
        }
    }
}

enum SessionRestoreSettings {
    static let modeKey = "sessionRestoreMode"
    static let defaultMode: SessionRestoreMode = .always

    static func mode(defaults: UserDefaults = .standard) -> SessionRestoreMode {
        guard let raw = defaults.string(forKey: modeKey) else { return defaultMode }
        return SessionRestoreMode(rawValue: raw) ?? defaultMode
    }

    /// Fixed path shared across Debug and Release builds so session state persists
    /// regardless of bundle identifier (com.termmesh.app vs com.termmesh.app.debug).
    static var sessionFilePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.termmesh.app")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json").path
    }
}

struct SavedWorkspaceState: Codable {
    let title: String
    let customTitle: String?
    let directory: String
    let isPinned: Bool
    let customColor: String?
}

struct SavedSessionState: Codable {
    let version: Int
    let workspaces: [SavedWorkspaceState]
    let selectedIndex: Int?
}

enum NewWorkspacePlacement: String, CaseIterable, Identifiable {
    case top
    case afterCurrent
    case end

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top:
            return "Top"
        case .afterCurrent:
            return "After current"
        case .end:
            return "End"
        }
    }

    var description: String {
        switch self {
        case .top:
            return "Insert new workspaces at the top of the list."
        case .afterCurrent:
            return "Insert new workspaces directly after the active workspace."
        case .end:
            return "Append new workspaces to the bottom of the list."
        }
    }
}

enum WorkspaceAutoReorderSettings {
    static let key = "workspaceAutoReorderOnNotification"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarBranchLayoutSettings {
    static let key = "sidebarBranchVerticalLayout"
    static let defaultVerticalLayout = true

    static func usesVerticalLayout(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultVerticalLayout
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarActiveTabIndicatorStyle: String, CaseIterable, Identifiable {
    case leftRail
    case solidFill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftRail:
            return "Left Rail"
        case .solidFill:
            return "Solid Fill"
        }
    }
}

enum SidebarActiveTabIndicatorSettings {
    static let styleKey = "sidebarActiveTabIndicatorStyle"
    static let defaultStyle: SidebarActiveTabIndicatorStyle = .leftRail

    static func resolvedStyle(rawValue: String?) -> SidebarActiveTabIndicatorStyle {
        guard let rawValue else { return defaultStyle }
        if let style = SidebarActiveTabIndicatorStyle(rawValue: rawValue) {
            return style
        }

        // Legacy values from earlier iterations map to the closest modern option.
        switch rawValue {
        case "rail":
            return .leftRail
        case "border", "wash", "lift", "typography", "washRail", "blueWashColorRail":
            return .solidFill
        default:
            return defaultStyle
        }
    }

    static func current(defaults: UserDefaults = .standard) -> SidebarActiveTabIndicatorStyle {
        resolvedStyle(rawValue: defaults.string(forKey: styleKey))
    }
}

enum WorkspacePlacementSettings {
    static let placementKey = "newWorkspacePlacement"
    static let defaultPlacement: NewWorkspacePlacement = .afterCurrent

    static func current(defaults: UserDefaults = .standard) -> NewWorkspacePlacement {
        guard let raw = defaults.string(forKey: placementKey),
              let placement = NewWorkspacePlacement(rawValue: raw) else {
            return defaultPlacement
        }
        return placement
    }

    static func insertionIndex(
        placement: NewWorkspacePlacement,
        selectedIndex: Int?,
        selectedIsPinned: Bool,
        pinnedCount: Int,
        totalCount: Int
    ) -> Int {
        let clampedTotalCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedTotalCount))

        switch placement {
        case .top:
            // Keep pinned workspaces grouped at the top by inserting ahead of unpinned items.
            return clampedPinnedCount
        case .end:
            return clampedTotalCount
        case .afterCurrent:
            guard let selectedIndex, clampedTotalCount > 0 else {
                return clampedTotalCount
            }
            let clampedSelectedIndex = max(0, min(selectedIndex, clampedTotalCount - 1))
            if selectedIsPinned {
                return clampedPinnedCount
            }
            return min(clampedSelectedIndex + 1, clampedTotalCount)
        }
    }
}

struct WorkspaceTabColorEntry: Equatable, Identifiable {
    let name: String
    let hex: String

    var id: String { "\(name)-\(hex)" }
}

enum WorkspaceTabColorSettings {
    static let defaultOverridesKey = "workspaceTabColor.defaultOverrides"
    static let customColorsKey = "workspaceTabColor.customColors"
    static let maxCustomColors = 24

    private static let originalPRPalette: [WorkspaceTabColorEntry] = [
        WorkspaceTabColorEntry(name: "Red", hex: "#C0392B"),
        WorkspaceTabColorEntry(name: "Crimson", hex: "#922B21"),
        WorkspaceTabColorEntry(name: "Orange", hex: "#A04000"),
        WorkspaceTabColorEntry(name: "Amber", hex: "#7D6608"),
        WorkspaceTabColorEntry(name: "Olive", hex: "#4A5C18"),
        WorkspaceTabColorEntry(name: "Green", hex: "#196F3D"),
        WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B"),
        WorkspaceTabColorEntry(name: "Aqua", hex: "#0E6B8C"),
        WorkspaceTabColorEntry(name: "Blue", hex: "#1565C0"),
        WorkspaceTabColorEntry(name: "Navy", hex: "#1A5276"),
        WorkspaceTabColorEntry(name: "Indigo", hex: "#283593"),
        WorkspaceTabColorEntry(name: "Purple", hex: "#6A1B9A"),
        WorkspaceTabColorEntry(name: "Magenta", hex: "#AD1457"),
        WorkspaceTabColorEntry(name: "Rose", hex: "#880E4F"),
        WorkspaceTabColorEntry(name: "Brown", hex: "#7B3F00"),
        WorkspaceTabColorEntry(name: "Charcoal", hex: "#3E4B5E"),
    ]

    static var defaultPalette: [WorkspaceTabColorEntry] {
        originalPRPalette
    }

    static func palette(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        defaultPaletteWithOverrides(defaults: defaults) + customColorEntries(defaults: defaults)
    }

    static func defaultPaletteWithOverrides(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let palette = defaultPalette
        let overrides = defaultOverrideMap(defaults: defaults)
        return palette.map { entry in
            WorkspaceTabColorEntry(name: entry.name, hex: overrides[entry.name] ?? entry.hex)
        }
    }

    static func defaultColorHex(named name: String, defaults: UserDefaults = .standard) -> String {
        let palette = defaultPalette
        guard let entry = palette.first(where: { $0.name == name }) else {
            return palette.first?.hex ?? "#1565C0"
        }
        return defaultOverrideMap(defaults: defaults)[name] ?? entry.hex
    }

    static func setDefaultColor(named name: String, hex: String, defaults: UserDefaults = .standard) {
        let palette = defaultPalette
        guard let entry = palette.first(where: { $0.name == name }),
              let normalized = normalizedHex(hex) else { return }

        var overrides = defaultOverrideMap(defaults: defaults)
        if normalized == entry.hex {
            overrides.removeValue(forKey: name)
        } else {
            overrides[name] = normalized
        }
        saveDefaultOverrideMap(overrides, defaults: defaults)
    }

    static func customColors(defaults: UserDefaults = .standard) -> [String] {
        guard let raw = defaults.array(forKey: customColorsKey) as? [String] else { return [] }
        var result: [String] = []
        var seen: Set<String> = []
        for value in raw {
            guard let normalized = normalizedHex(value), seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count >= maxCustomColors { break }
        }
        return result
    }

    static func customColorEntries(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        customColors(defaults: defaults).enumerated().map { index, hex in
            WorkspaceTabColorEntry(name: "Custom \(index + 1)", hex: hex)
        }
    }

    @discardableResult
    static func addCustomColor(_ hex: String, defaults: UserDefaults = .standard) -> String? {
        guard let normalized = normalizedHex(hex) else { return nil }
        var colors = customColors(defaults: defaults)
        colors.removeAll { $0 == normalized }
        colors.insert(normalized, at: 0)
        setCustomColors(colors, defaults: defaults)
        return normalized
    }

    static func removeCustomColor(_ hex: String, defaults: UserDefaults = .standard) {
        guard let normalized = normalizedHex(hex) else { return }
        var colors = customColors(defaults: defaults)
        colors.removeAll { $0 == normalized }
        setCustomColors(colors, defaults: defaults)
    }

    static func setCustomColors(_ hexes: [String], defaults: UserDefaults = .standard) {
        var normalizedColors: [String] = []
        var seen: Set<String> = []
        for value in hexes {
            guard let normalized = normalizedHex(value), seen.insert(normalized).inserted else { continue }
            normalizedColors.append(normalized)
            if normalizedColors.count >= maxCustomColors { break }
        }

        if normalizedColors.isEmpty {
            defaults.removeObject(forKey: customColorsKey)
        } else {
            defaults.set(normalizedColors, forKey: customColorsKey)
        }
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultOverridesKey)
        defaults.removeObject(forKey: customColorsKey)
    }

    static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }

    static func displayColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> Color? {
        guard let color = displayNSColor(hex: hex, colorScheme: colorScheme, forceBright: forceBright) else {
            return nil
        }
        return Color(nsColor: color)
    }

    static func displayNSColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> NSColor? {
        guard let normalized = normalizedHex(hex),
              let baseColor = NSColor(hex: normalized) else {
            return nil
        }

        if forceBright || colorScheme == .dark {
            return brightenedForDarkAppearance(baseColor)
        }
        return baseColor
    }

    private static func defaultOverrideMap(defaults: UserDefaults) -> [String: String] {
        guard let raw = defaults.dictionary(forKey: defaultOverridesKey) as? [String: String] else { return [:] }
        let validNames = Set(defaultPalette.map(\.name))
        var normalized: [String: String] = [:]
        for (name, hex) in raw {
            guard validNames.contains(name),
                  let normalizedHex = normalizedHex(hex) else { continue }
            normalized[name] = normalizedHex
        }
        return normalized
    }

    private static func saveDefaultOverrideMap(_ map: [String: String], defaults: UserDefaults) {
        if map.isEmpty {
            defaults.removeObject(forKey: defaultOverridesKey)
        } else {
            defaults.set(map, forKey: defaultOverridesKey)
        }
    }

    private static func brightenedForDarkAppearance(_ color: NSColor) -> NSColor {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedBrightness = min(1, max(brightness, 0.62) + ((1 - brightness) * 0.28))
        // Preserve neutral grays when brightening to avoid introducing hue shifts.
        let boostedSaturation: CGFloat
        if saturation <= 0.08 {
            boostedSaturation = saturation
        } else {
            boostedSaturation = min(1, saturation + ((1 - saturation) * 0.12))
        }

        return NSColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }
}

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}

struct RecentlyClosedBrowserStack {
    private(set) var entries: [ClosedBrowserPanelRestoreSnapshot] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func push(_ snapshot: ClosedBrowserPanelRestoreSnapshot) {
        entries.append(snapshot)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func pop() -> ClosedBrowserPanelRestoreSnapshot? {
        entries.popLast()
    }
}

#if DEBUG
// Sample the actual IOSurface-backed terminal layer at vsync cadence so UI tests can reliably
// catch a single compositor-frame blank flash and any transient compositor scaling (stretched text).
//
// This is DEBUG-only and used only for UI tests; no polling or display-link loops exist in normal app runtime.
final class VsyncIOSurfaceTimelineState {
    struct Target {
        let label: String
        let sample: @MainActor () -> GhosttySurfaceScrollView.DebugFrameSample?
    }

    let frameCount: Int
    let closeFrame: Int
    let lock = NSLock()

    var framesWritten = 0
    var inFlight = false
    var finished = false

    var scheduledActions: [(frame: Int, action: () -> Void)] = []
    var nextActionIndex: Int = 0

    var targets: [Target] = []

    // Results
    var firstBlank: (label: String, frame: Int)?
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?
    var trace: [String] = []

    var link: CVDisplayLink?
    var continuation: CheckedContinuation<Void, Never>?

    init(frameCount: Int, closeFrame: Int) {
        self.frameCount = frameCount
        self.closeFrame = closeFrame
    }

    func tryBeginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func endCapture() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

func termMeshVsyncIOSurfaceTimelineCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    let st = Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).takeUnretainedValue()
    if !st.tryBeginCapture() { return kCVReturnSuccess }

    // Sample on the main thread. Using async (not sync) to avoid deadlock risk if the main
    // thread is ever blocked waiting on CVDisplayLink. The tryBeginCapture/endCapture gate
    // ensures at most one async block is in-flight at a time, so framesWritten stays consistent.
    // Note: async may skip a frame if the main thread is busy — acceptable for this debug utility.
    DispatchQueue.main.async {
        defer { st.endCapture() }
        guard st.framesWritten < st.frameCount else { return }

        while st.nextActionIndex < st.scheduledActions.count {
            let next = st.scheduledActions[st.nextActionIndex]
            if next.frame != st.framesWritten { break }
            st.nextActionIndex += 1
            next.action()
        }

        for t in st.targets {
            guard let s = t.sample() else { continue }

            let iosW = s.iosurfaceWidthPx
            let iosH = s.iosurfaceHeightPx
            let expW = s.expectedWidthPx
            let expH = s.expectedHeightPx
            let gravity = s.layerContentsGravity
            let hasDimensions = iosW > 0 && iosH > 0 && expW > 0 && expH > 0
            let dw = hasDimensions ? abs(iosW - expW) : 0
            let dh = hasDimensions ? abs(iosH - expH) : 0
            let hasSizeMismatch = hasDimensions && (dw > 2 || dh > 2)
            let stretchRisk = (gravity == CALayerContentsGravity.resize.rawValue)

            // Ignore setup/warmup frames before the close action. We only care about
            // regressions that happen at/after the close mutation.
            if st.firstBlank == nil, st.framesWritten >= st.closeFrame, s.isProbablyBlank {
                st.firstBlank = (label: t.label, frame: st.framesWritten)
            }

            if st.firstSizeMismatch == nil,
               st.framesWritten >= st.closeFrame,
               stretchRisk,
               hasSizeMismatch {
                st.firstSizeMismatch = (
                    label: t.label,
                    frame: st.framesWritten,
                    ios: "\(iosW)x\(iosH)",
                    expected: "\(expW)x\(expH)"
                )
            }

            if st.trace.count < 200 {
                st.trace.append("\(st.framesWritten):\(t.label):blank=\(s.isProbablyBlank ? 1 : 0):ios=\(iosW)x\(iosH):exp=\(expW)x\(expH):gravity=\(gravity):key=\(s.layerContentsKey)")
            }
        }

        st.framesWritten += 1

        // Stop/resume inside the async block so framesWritten is up to date.
        if st.framesWritten >= st.frameCount, let link = st.link {
            CVDisplayLinkStop(link)
            st.finish()
            Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
        }
    }

    return kCVReturnSuccess
}
#endif

