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

    /// The bundle whose peer socket keeps the unsuffixed path.
    ///
    /// Only the installed app gets it, because saved host profiles on OTHER
    /// machines already store this exact path in `remoteSocket`. Moving it
    /// would break every peer that has ever connected here.
    static let productionBundleIdentifier = "com.termmesh.app"

    /// Where this build serves its peer socket.
    ///
    /// **Scoped for every build except the installed one.** The path used to be
    /// `uid` and nothing else, so a Debug or `--tag` app served the same path
    /// as the installed app — and `PeerServer.start()` unlinks before binding,
    /// so whichever started LAST silently took it. The first one kept a
    /// listener bound to an unlinked inode: alive, reachable by nothing.
    ///
    /// That is not hypothetical. A `--tag` build launched at 10:50 rebound this
    /// path at 11:02 while the installed app had held it since 07:31; from then
    /// on a viewer's existing mirror talked to one app while every new attach
    /// reached the other, and a workspace mirrored as 2 of its 7 panes.
    ///
    /// Same fix as the terminal override files, and for the same reason: two
    /// builds of this app must not share a writable name.
    static var defaultSocketPath: String {
        socketPath(uid: getuid(), bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// Pure form of the rule above, so the production-keeps-the-path guarantee
    /// is testable without being the production bundle.
    static func socketPath(uid: uid_t, bundleIdentifier: String?) -> String {
        let base = "/tmp/term-mesh-peer-\(uid)"
        guard let bundleID = bundleIdentifier,
              bundleID != productionBundleIdentifier
        else {
            return "\(base)/peer.sock"
        }
        // A digest rather than the identifier itself: a sockaddr_un path is
        // capped near 104 bytes, and `com.termmesh.app.debug.<tag>` with a
        // descriptive tag can spend most of that on its own.
        return "\(base)-\(Self.shortDigest(bundleID))/peer.sock"
    }

    /// FNV-1a, 8 hex chars. Deterministic across launches, unlike
    /// `hashValue`, which Swift seeds randomly per process — a socket path
    /// that moved on every start would be worse than one that collides.
    static func shortDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }

    /// The path a non-production build must NOT keep serving, whatever its
    /// stored preference says.
    ///
    /// Scoping `defaultSocketPath` alone does not reach an existing install.
    /// `socketPath` prefers the stored value and falls back to the default only
    /// when there is none — and `SettingsView` declares
    /// `@AppStorage(socketPathKey) = defaultSocketPath`, so a build that ever
    /// wrote that field has the OLD shared path persisted. Such a build would
    /// go on serving it, and the collision this all exists to stop would
    /// survive the fix.
    ///
    /// So one value is treated as "never chosen deliberately": the shared path
    /// itself, seen by a build that is not production. Nobody types that on
    /// purpose in a Debug build — it is what the field was pre-filled with —
    /// and preferring the scoped default there costs nothing, because the one
    /// build entitled to that path still gets it.
    ///
    /// A genuinely custom path is left alone. That is the setting doing its
    /// job, and a person who names a path is answering for it.
    static func migratedSocketPath(
        stored: String,
        uid: uid_t,
        bundleIdentifier: String?
    ) -> String {
        let scoped = socketPath(uid: uid, bundleIdentifier: bundleIdentifier)
        guard !stored.isEmpty else { return scoped }
        let sharedPath = socketPath(uid: uid, bundleIdentifier: productionBundleIdentifier)
        if stored == sharedPath, scoped != sharedPath {
            return scoped
        }
        return stored
    }

    static var defaultDisplayName: String {
        ProcessInfo.processInfo.hostName
    }

    static var autoStart: Bool {
        UserDefaults.standard.bool(forKey: autoStartKey)
    }

    /// The path this build actually serves.
    ///
    /// Runs the stored value through `migratedSocketPath` rather than trusting
    /// it outright: an existing install can have the old shared path persisted
    /// from before that path was scoped, and honouring it would keep two builds
    /// fighting over one socket. See `migratedSocketPath`.
    static var socketPath: String {
        let stored = UserDefaults.standard.string(forKey: socketPathKey) ?? ""
        return migratedSocketPath(
            stored: stored,
            uid: getuid(),
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
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
    /// to a free local port. Off by default: the remote dashboard is
    /// typically unauthenticated (no `TERM_MESH_HTTP_PASSWORD`), and its
    /// routes include `/api/agents/spawn` / `/api/process/stop` — forwarding
    /// it onto the Mac's own loopback makes those reachable to any local
    /// process, or a webpage's `no-cors` POST, with no further action from
    /// the user. Loopback-only framing describes the network hop; it does
    /// not describe the local-process trust boundary this crosses, so the
    /// forward is opt-in. Skipped silently when no local port is free (the
    /// peer forward must not be taken down with it).
    static var forwardDashboard: Bool {
        UserDefaults.standard.object(forKey: forwardDashboardKey) as? Bool ?? false
    }

    static var remoteDashboardPort: Int {
        let v = UserDefaults.standard.integer(forKey: remoteDashboardPortKey)
        return (1...65535).contains(v) ? v : defaultRemoteDashboardPort
    }

    static var peerIDHex: String {
        // Keep the display path aligned with peer handshakes. Calling
        // loadOrCreate() directly bypasses TERMMESH_PEER_IDENTITY_EPHEMERAL
        // and can re-open the Keychain prompt in tagged builds.
        PeerIdentity.hexString(PeerIdentity.defaultPeerID())
    }

    // MARK: - Recent SSH hosts

    /// SSH target + remote socket path used by the most recent
    /// successful relay-workspace attach. Persisted across launches.
    /// LEGACY: the connect dialog and recent-hosts menu that consumed
    /// this list are gone (sidebar-first UX; saved profiles in
    /// PeerHostProfileStore replaced it, with a one-time migration on
    /// first load). Kept as the migration source and for downgrade
    /// compatibility — do not add new consumers.
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
