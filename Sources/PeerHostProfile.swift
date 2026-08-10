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
    /// What the daemon spawns behind this key: `""` (the PTY that predates
    /// the field) or `SessionHostPanes.agentSurfaceType`, a non-PTY
    /// `tm-agent-bridge` child streaming NDJSON. Defaulted and optional in
    /// the decoder so profiles saved before the field still load — and so a
    /// saved runner keeps meaning "terminal" without having said so.
    var kind: String

    init(
        key: String,
        cwd: String,
        executable: String,
        args: [String] = [],
        restartPolicy: PeerRunnerRestartPolicy = .onDaemonRestart,
        kind: String = ""
    ) {
        self.key = key
        self.cwd = cwd
        self.executable = executable
        self.args = args
        self.restartPolicy = restartPolicy
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        cwd = try container.decode(String.self, forKey: .cwd)
        executable = try container.decode(String.self, forKey: .executable)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        restartPolicy = try container.decodeIfPresent(
            PeerRunnerRestartPolicy.self, forKey: .restartPolicy
        ) ?? .onDaemonRestart
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
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
    /// User-pinned remote peer socket path. Empty = auto-detect on connect
    /// (PeerSocketProber). Auto-detection results live in
    /// `lastResolvedSocket`, never in this editor-facing field.
    var remoteSocket: String
    /// Last successful auto-detection result. This is an implementation
    /// cache, not a user choice: clearing `remoteSocket` clears this too,
    /// forcing the next connection to probe again.
    var lastResolvedSocket: String?
    /// Explicit SSH port (`-p`). nil = ssh default / ssh-config.
    var sshPort: Int?
    /// Identity file (`-i`). nil = default keys / ssh-config.
    var identityFile: String?
    /// Sidebar tag color as a hex string (e.g. "#E06C75"). nil = default.
    var colorHex: String?
    /// SF Symbol shown for this host while connected. nil = "network".
    var symbolName: String?
    /// Where this machine keeps its projects, e.g. `/app/term-mesh-prj`.
    ///
    /// A project's directory over there is predictable when the machine has a
    /// convention: the root, then the project's own folder name. That is a
    /// guess, but it is the same guess a person makes, and it answers the
    /// question the first time — before there is anything to remember. Empty
    /// means this machine has no convention and the path has to come from
    /// somewhere else.
    var projectRootPath: String?
    /// Optional deterministic runner recipe. nil keeps this profile as a
    /// normal browse/picker-only peer host.
    var savedRunner: PeerSavedRunnerProfile?
    /// Environment variables for everything term-mesh runs on this machine —
    /// agent/leader launches (typed and native-ssh) and project bootstrap
    /// scripts. Per-host because that is what they describe: one box needs a
    /// proxy, another needs `IS_SANDBOX=1`, and neither belongs on the other.
    /// Optional so profiles saved before the field existed still decode.
    var environment: [String: String]?
    var lastConnectedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String = "",
        sshTarget: String,
        remoteSocket: String = "",
        lastResolvedSocket: String? = nil,
        sshPort: Int? = nil,
        identityFile: String? = nil,
        colorHex: String? = nil,
        symbolName: String? = nil,
        projectRootPath: String? = nil,
        savedRunner: PeerSavedRunnerProfile? = nil,
        environment: [String: String]? = nil,
        lastConnectedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.sshTarget = sshTarget
        self.remoteSocket = remoteSocket
        self.lastResolvedSocket = lastResolvedSocket
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.projectRootPath = projectRootPath
        self.savedRunner = savedRunner
        self.environment = environment
        self.lastConnectedAt = lastConnectedAt
        self.createdAt = createdAt
    }

    var effectiveDisplayName: String {
        displayName.isEmpty ? sshTarget : displayName
    }

    /// Socket to use for a connection without conflating explicit
    /// configuration with an auto-detection cache.
    var connectionSocket: String? {
        if !remoteSocket.isEmpty { return remoteSocket }
        guard let lastResolvedSocket, !lastResolvedSocket.isEmpty else { return nil }
        return lastResolvedSocket
    }

    /// Where a project with this folder name would live on this machine.
    ///
    /// Nil when the machine has no convention set — a predicted path is worth
    /// offering, an invented one is not.
    func predictedProjectPath(forProjectNamed name: String) -> String? {
        guard let root = projectRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty, !name.isEmpty else { return nil }
        return (root as NSString).appendingPathComponent(name)
    }

    /// Stable key aligning this profile with live sidebar entries —
    /// must stay in sync with RemoteHostStore's stableKey convention.
    var stableKey: String { "ssh:\(sshTarget)" }
}

/// Shared shaping of a peer host's environment variables for shell use.
/// Everything that runs on a peer goes through a shell at some point, so
/// there is exactly one quoting/validation story, here.
enum PeerHostEnvironment {
    /// Keys a POSIX shell accepts as assignments. Anything else is dropped
    /// rather than quoted into something surprising — a bad key is a typo,
    /// and typos should not become shell words.
    static func sanitized(_ environment: [String: String]) -> [(key: String, value: String)] {
        environment
            .filter { key, _ in
                guard let first = key.first,
                      first.isLetter || first == "_" else { return false }
                return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }

    /// `K1='v1' K2='v2'` — the prefix form that scopes the variables to the
    /// single command that follows. Empty when nothing (valid) is set.
    static func inlineAssignments(_ environment: [String: String]) -> String {
        sanitized(environment)
            .map { "\($0.key)='\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
    }

    /// The environment saved for a host, by the sidebar's stable key.
    @MainActor
    static func stored(forHostKey hostKey: String) -> [String: String] {
        PeerHostProfileStore.shared.profiles
            .first { $0.stableKey == hostKey }?
            .environment ?? [:]
    }
}
