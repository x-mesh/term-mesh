import Foundation

/// Represents a tab's metadata (read-only snapshot for library consumers)
/// The machine a tab's content runs on, when that is not this one. The tab
/// shows it as a chip in the host's color beside the title.
public struct TabHostBadge: Hashable, Codable, Sendable {
    public let label: String
    /// sRGB components, 0...1. Plain numbers rather than a color type so the
    /// badge stays `Codable` and survives a cross-process tab drag.
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(label: String, red: Double, green: Double, blue: Double) {
        self.label = label
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The host color made readable as small text. Host hues are chosen to
    /// read as fills; as 10-11pt text on a chip tinted with the same hue they
    /// fall to about 2:1 on a light background and 3-4:1 on a dark one.
    /// Halving them on light and mixing in white on dark keeps every host
    /// palette color above 5:1.
    public func labelRGB(onLightBackground: Bool) -> (red: Double, green: Double, blue: Double) {
        if onLightBackground {
            return (red * Self.lightKeep, green * Self.lightKeep, blue * Self.lightKeep)
        }
        func lift(_ value: Double) -> Double { value + (1 - value) * Self.darkWhiteMix }
        return (lift(red), lift(green), lift(blue))
    }

    private static let lightKeep = 0.5
    private static let darkWhiteMix = 0.35
}

public struct Tab: Identifiable, Hashable, Sendable {
    public let id: TabID
    public let title: String
    public let hasCustomTitle: Bool
    public let icon: String?
    /// Optional image data (PNG recommended) for the tab icon. When present, this takes precedence over `icon`.
    public let iconImageData: Data?
    /// Consumer-defined tab kind identifier (for example, "terminal" or "browser").
    public let kind: String?
    public let isDirty: Bool
    /// Whether the tab should show an "unread/activity" badge (library consumer-defined meaning).
    public let showsNotificationBadge: Bool
    /// Whether the tab should show an activity/loading indicator (e.g. spinning icon).
    public let isLoading: Bool
    /// Whether the tab is pinned in its pane.
    public let isPinned: Bool
    public let hostBadge: TabHostBadge?

    public init(
        id: TabID = TabID(),
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = nil,
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        hostBadge: TabHostBadge? = nil
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.icon = icon
        self.iconImageData = iconImageData
        self.kind = kind
        self.isDirty = isDirty
        self.showsNotificationBadge = showsNotificationBadge
        self.isLoading = isLoading
        self.isPinned = isPinned
        self.hostBadge = hostBadge
    }

    internal init(from tabItem: TabItem) {
        self.id = TabID(id: tabItem.id)
        self.title = tabItem.title
        self.hasCustomTitle = tabItem.hasCustomTitle
        self.icon = tabItem.icon
        self.iconImageData = tabItem.iconImageData
        self.kind = tabItem.kind
        self.isDirty = tabItem.isDirty
        self.showsNotificationBadge = tabItem.showsNotificationBadge
        self.isLoading = tabItem.isLoading
        self.isPinned = tabItem.isPinned
        self.hostBadge = tabItem.hostBadge
    }
}
