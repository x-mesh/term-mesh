import Foundation
import SwiftUI

// MARK: - BrowserHistoryService Protocol

/// Abstracts the public API of BrowserHistoryStore for testability and loose coupling.
protocol BrowserHistoryService: AnyObject {
    var entries: [BrowserHistoryStore.Entry] { get }

    func loadIfNeeded()
    func recordVisit(url: URL?, title: String?)
    func recordTypedNavigation(url: URL?)
    func suggestions(for input: String, limit: Int) -> [BrowserHistoryStore.Entry]
    func recentSuggestions(limit: Int) -> [BrowserHistoryStore.Entry]
    func clearHistory()
    func removeHistoryEntry(urlString: String) -> Bool
    func flushPendingSaves()
}

extension BrowserHistoryStore: BrowserHistoryService {}

// MARK: - SwiftUI Environment

struct BrowserHistoryServiceKey: EnvironmentKey {
    static let defaultValue: (any BrowserHistoryService)? = nil
}

extension EnvironmentValues {
    var browserHistoryService: (any BrowserHistoryService)? {
        get { self[BrowserHistoryServiceKey.self] }
        set { self[BrowserHistoryServiceKey.self] = newValue }
    }
}
