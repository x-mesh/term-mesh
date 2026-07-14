// Phase D-2B: persisted user preferences for peer federation.
//
// The toggle drives whether the app auto-starts the local peer server
// at launch (replacing the env-var-only path used before D-2B). The
// socket path and advertised name flow into both the autostart hook
// and the manual "Start Peer Server…" menu item, so changes show up
// immediately without restarting the app.

import Foundation
import Darwin
import PeerProto

enum PeerFederationSettings {
    static let autoStartKey      = "peerFederationAutoStart"
    static let socketPathKey     = "peerFederationSocketPath"
    static let displayNameKey    = "peerFederationDisplayName"
    static let recentHostsKey    = "peerFederationRecentHosts"
    static let forceRedrawKey    = "peerFederationForceRedrawOnAttach"
    static let forwardDashboardKey = "peerFederationForwardDashboard"
    static let remoteDashboardPortKey = "peerFederationRemoteDashboardPort"

    static var defaultSocketPath: String {
        let uid = getuid()
        return "/tmp/term-mesh-peer-\(uid)/peer.sock"
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

    /// The remote host's HTTP dashboard port. `term-meshd` binds it to
    /// 127.0.0.1:9876 by default, so it is unreachable from off-box —
    /// the SSH tunnel is what makes it viewable here.
    static let defaultRemoteDashboardPort = 9876

    /// When on, the peer SSH tunnel also forwards the remote dashboard
    /// to a free local port. On by default: the forward is loopback-only
    /// on both ends and rides the tunnel that peer already opens, so it
    /// costs no extra exposure. Skipped silently when no local port is
    /// free (the peer forward must not be taken down with it).
    static var forwardDashboard: Bool {
        UserDefaults.standard.object(forKey: forwardDashboardKey) as? Bool ?? true
    }

    static var remoteDashboardPort: Int {
        let v = UserDefaults.standard.integer(forKey: remoteDashboardPortKey)
        return (1...65535).contains(v) ? v : defaultRemoteDashboardPort
    }

    static var peerIDHex: String {
        (try? PeerIdentity.loadOrCreate()).map(PeerIdentity.hexString) ?? "unavailable"
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
