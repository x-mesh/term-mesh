//  PeerHostProfile: a saved remote-host profile for the sidebar-first
//  peer UX — the persistent "SSH bookmark" a user manages like entries
//  in a typical SSH client. Persisted by PeerHostProfileStore; matched
//  to live connections via the same stable key RemoteHostStore uses
//  ("ssh:<target>").

import Foundation
import PeerProto

/// Codable app-side form of the daemon's restart policy. Keeping the wire
/// enum out of persistence makes profile JSON stable across protobuf changes.
enum PeerRunnerRestartPolicy: String, Codable, Sendable {
    case never
    case onDaemonRestart

    var wireValue: Termmesh_Peer_V1_EnsureSurfaceRestartPolicy {
        switch self {
        case .never: return .never
        case .onDaemonRestart: return .onDaemonRestart
        }
    }
}

/// Desired daemon-owned process. This is execution identity; a
/// `ProjectBinding` is deliberately absent because it only describes how
/// files are retrieved into a local workspace.
struct PeerRunnerSurfaceSpec: Codable, Equatable, Sendable {
    var key: String
    var cwd: String
    var executable: String
    var args: [String]
    var restartPolicy: PeerRunnerRestartPolicy

    init(
        key: String,
        cwd: String,
        executable: String,
        args: [String] = [],
        restartPolicy: PeerRunnerRestartPolicy = .onDaemonRestart
    ) {
        self.key = key
        self.cwd = cwd
        self.executable = executable
        self.args = args
        self.restartPolicy = restartPolicy
    }
}

/// Local presentation of an ensured surface. It changes where/how the exact
/// surface is shown, never which process the daemon reconciles.
struct PeerRunnerAttachment: Codable, Equatable, Sendable {
    var title: String
    var cols: UInt32
    var rows: UInt32
    var lifetime: RemotePaneLifetime

    init(
        title: String = "Runner",
        cols: UInt32 = 80,
        rows: UInt32 = 24,
        lifetime: RemotePaneLifetime = .temporary
    ) {
        self.title = title
        self.cols = cols
        self.rows = rows
        self.lifetime = lifetime
    }
}

struct PeerSavedRunnerProfile: Codable, Equatable, Sendable {
    var surface: PeerRunnerSurfaceSpec
    var attachment: PeerRunnerAttachment

    init(surface: PeerRunnerSurfaceSpec, attachment: PeerRunnerAttachment = .init()) {
        self.surface = surface
        self.attachment = attachment
    }
}

enum PeerSavedRunnerStage: String, Sendable {
    case probe
    case lease
    case ensure
    case attach
    case openPane = "open-pane"
    case ready
}

struct PeerSavedRunnerStatus: Equatable, Sendable {
    let stage: PeerSavedRunnerStage
    let machine: String
    let cwd: String
    let errorCode: String?
    let safeContext: String?
}

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
    /// Optional deterministic runner recipe. nil keeps this profile as a
    /// normal browse/picker-only peer host.
    var savedRunner: PeerSavedRunnerProfile?
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
        savedRunner: PeerSavedRunnerProfile? = nil,
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
        self.savedRunner = savedRunner
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
