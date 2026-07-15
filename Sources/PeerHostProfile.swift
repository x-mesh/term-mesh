//  PeerHostProfile: a saved remote-host profile for the sidebar-first
//  peer UX — the persistent "SSH bookmark" a user manages like entries
//  in a typical SSH client. Persisted by PeerHostProfileStore; matched
//  to live connections via the same stable key RemoteHostStore uses
//  ("ssh:<target>").

import Foundation

struct PeerHostProfile: Codable, Identifiable, Equatable {
    var id: UUID
    /// User-facing name; empty falls back to `sshTarget`.
    var displayName: String
    /// `user@host` or an ssh-config alias. V1 profiles are SSH-only —
    /// direct-socket hosts remain ad-hoc sidebar entries.
    var sshTarget: String
    /// Remote peer socket path. Empty = auto-detect on connect
    /// (PeerSocketProber); the resolved path is cached back here.
    var remoteSocket: String
    /// Explicit SSH port (`-p`). nil = ssh default / ssh-config.
    var sshPort: Int?
    /// Identity file (`-i`). nil = default keys / ssh-config.
    var identityFile: String?
    /// Sidebar tag color as a hex string (e.g. "#E06C75"). nil = default.
    var colorHex: String?
    /// SF Symbol shown for this host while connected. nil = "network".
    var symbolName: String?
    var lastConnectedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String = "",
        sshTarget: String,
        remoteSocket: String = "",
        sshPort: Int? = nil,
        identityFile: String? = nil,
        colorHex: String? = nil,
        symbolName: String? = nil,
        lastConnectedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.sshTarget = sshTarget
        self.remoteSocket = remoteSocket
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.lastConnectedAt = lastConnectedAt
        self.createdAt = createdAt
    }

    var effectiveDisplayName: String {
        displayName.isEmpty ? sshTarget : displayName
    }

    /// Stable key aligning this profile with live sidebar entries —
    /// must stay in sync with RemoteHostStore's stableKey convention.
    var stableKey: String { "ssh:\(sshTarget)" }
}
