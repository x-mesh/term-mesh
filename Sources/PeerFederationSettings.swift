// Phase D-2B: persisted user preferences for peer federation.
//
// The toggle drives whether the app auto-starts the local peer server
// at launch (replacing the env-var-only path used before D-2B). The
// socket path and advertised name flow into both the autostart hook
// and the manual "Start Peer Server…" menu item, so changes show up
// immediately without restarting the app.

import Foundation

enum PeerFederationSettings {
    static let autoStartKey      = "peerFederationAutoStart"
    static let socketPathKey     = "peerFederationSocketPath"
    static let displayNameKey    = "peerFederationDisplayName"

    static let defaultSocketPath = "/tmp/termmesh-app-peer.sock"
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
}
