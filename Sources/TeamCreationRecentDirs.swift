import Foundation

enum WorkingDirectorySource: String, CaseIterable {
    case currentPane = "current pane"
    case workspace = "workspace"
    case lastUsed = "last used"
    case appLaunch = "app launch directory"  // ⚠ warning case
    case userPicked = "chosen"               // after Choose…/drop/Recent
}

final class TeamCreationRecentDirs {
    static let shared = TeamCreationRecentDirs()

    private let defaultsKey = "teamCreation.recentWorkingDirectories"
    private let maxCount = 10

    private init() {}

    func current() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    func promote(_ path: String) {
        let normalized = TeamCreationRecentDirs.normalize(path)
        guard !normalized.isEmpty else { return }
        var list = current().filter { $0 != normalized }
        list.insert(normalized, at: 0)
        if list.count > maxCount {
            list = Array(list.prefix(maxCount))
        }
        UserDefaults.standard.set(list, forKey: defaultsKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static func displayPath(_ absolute: String) -> String {
        (absolute as NSString).abbreviatingWithTildeInPath
    }

    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        var expanded = path
        if expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + expanded.dropFirst(1)
        } else if expanded == "~" {
            expanded = NSHomeDirectory()
        }
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        // Strip trailing slash (standardizedFileURL already does this for non-root)
        if url.path != "/" {
            var p = url.path
            while p.hasSuffix("/") { p.removeLast() }
            url = URL(fileURLWithPath: p)
        }
        return url.path
    }
}
