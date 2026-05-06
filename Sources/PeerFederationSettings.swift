// Phase D-2B: persisted user preferences for peer federation.
//
// The toggle drives whether the app auto-starts the local peer server
// at launch (replacing the env-var-only path used before D-2B). The
// socket path and advertised name flow into both the autostart hook
// and the manual "Start Peer Server…" menu item, so changes show up
// immediately without restarting the app.

import Foundation
import Darwin

enum PeerFederationSettings {
    static let autoStartKey      = "peerFederationAutoStart"
    static let socketPathKey     = "peerFederationSocketPath"
    static let displayNameKey    = "peerFederationDisplayName"
    static let recentHostsKey    = "peerFederationRecentHosts"
    static let forceRedrawKey    = "peerFederationForceRedrawOnAttach"

    static var defaultSocketPath: String {
        let uid = getuid()
        return NSTemporaryDirectory()
            .appending("term-mesh-\(uid)")
            .appending("/peer.sock")
    }
    static var defaultDisplayName: String {
        ProcessInfo.processInfo.hostName
    }

    static var autoStart: Bool {
        UserDefaults.standard.bool(forKey: autoStartKey)
    }

    static var socketPath: String {
        let v = UserDefaults.standard.string(forKey: socketPathKey) ?? ""
        return v.isEmpty ? defaultSocketPath : v
    }

    static var displayName: String {
        let v = UserDefaults.standard.string(forKey: displayNameKey) ?? ""
        return v.isEmpty ? defaultDisplayName : v
    }

    /// Phase E-6: when on, the host injects Ctrl-L into the PTY at
    /// each peer attach so full-screen TUIs (vim, htop, less) repaint
    /// with full styling. Off by default — flicker is visible to the
    /// host's local viewer too.
    static var forceRedrawOnAttach: Bool {
        UserDefaults.standard.bool(forKey: forceRedrawKey)
    }

    // MARK: - Recent SSH hosts

    /// SSH target + remote socket path used by the most recent
    /// successful relay-workspace attach. Persisted across launches
    /// so the connect dialog can offer a "recent" picker.
    struct RecentHost: Codable, Equatable {
        var sshTarget: String
        var remoteSocket: String
    }

    private static let recentLimit = 8

    static func loadRecentHosts() -> [RecentHost] {
        guard let data = UserDefaults.standard.data(forKey: recentHostsKey) else { return [] }
        return (try? JSONDecoder().decode([RecentHost].self, from: data)) ?? []
    }

    /// Move (or insert) the entry to the front of the list, dropping
    /// any prior duplicate. Trim to `recentLimit`.
    static func rememberRecentHost(_ entry: RecentHost) {
        var hosts = loadRecentHosts()
        hosts.removeAll { $0 == entry }
        hosts.insert(entry, at: 0)
        if hosts.count > recentLimit {
            hosts = Array(hosts.prefix(recentLimit))
        }
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: recentHostsKey)
        }
    }

    static func forgetRecentHost(_ entry: RecentHost) {
        var hosts = loadRecentHosts()
        hosts.removeAll { $0 == entry }
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: recentHostsKey)
        }
    }
}
