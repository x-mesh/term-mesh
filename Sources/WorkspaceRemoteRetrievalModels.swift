import Foundation

// Workspace remote retrieval keeps remote execution identity separate from
// the local workspace that happens to display it.

struct RetrievalID<Kind: Sendable>: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum RemoteSessionIDKind: Sendable {}
enum RemotePaneIDKind: Sendable {}
enum PaneBindingIDKind: Sendable {}
enum ProjectBindingIDKind: Sendable {}
enum CheckpointIDKind: Sendable {}
enum ChangesetIDKind: Sendable {}

typealias RemoteSessionID = RetrievalID<RemoteSessionIDKind>
typealias RemotePaneID = RetrievalID<RemotePaneIDKind>
typealias PaneBindingID = RetrievalID<PaneBindingIDKind>
typealias ProjectBindingID = RetrievalID<ProjectBindingIDKind>
typealias CheckpointID = RetrievalID<CheckpointIDKind>
typealias ChangesetID = RetrievalID<ChangesetIDKind>

enum RemotePaneLifetime: String, Codable, Sendable {
    case temporary
    case keepAlive
}

enum PaneBindingRole: String, Codable, Sendable {
    case owned
    case linked
}

enum WorkspaceRetrievalPresentation: String, Codable, CaseIterable, Sendable {
    case sidebar
    case drawer
    case inspector

    static let defaultPresentation: Self = .drawer
}

enum CheckpointBoundary: String, Codable, Sendable {
    case finishRun
    case checkpointNow
    case sessionTeardown
    case disconnectDraft
    case unbounded
}

enum IncomingChangesetState: String, Codable, Sendable {
    case incoming
    case validating
    case validated
    case unverified
    case applying
    case applied
    case discarded
    case failed
}

struct RemoteCheckpointRecord: Identifiable, Hashable, Codable, Sendable {
    let id: CheckpointID
    let paneID: RemotePaneID
    let revision: String
    let remoteRef: String
    let boundary: CheckpointBoundary
    let createdAt: Date
}

struct IncomingChangeset: Identifiable, Hashable, Codable, Sendable {
    let id: ChangesetID
    let paneID: RemotePaneID
    let projectBindingID: ProjectBindingID
    let baseRevision: String
    let checkpointRevision: String
    let localRef: String
    let boundary: CheckpointBoundary
    let changedPaths: [String]
    let diffSummary: String
    let createdAt: Date
    var state: IncomingChangesetState
    var failureMessage: String?
}

struct RemotePaneActivity: Identifiable, Hashable, Sendable {
    let id: UUID
    /// The pane this happened to, when it happened to one.
    ///
    /// Optional because the most useful events do not belong to a pane: a
    /// tunnel coming up, a reconnect giving up, a file copied to a peer. They
    /// also tend to happen BEFORE any pane exists, and requiring one here is
    /// what made them vanish from the drawer entirely.
    let paneID: RemotePaneID?
    let message: String
    let occurredAt: Date

    init(id: UUID = UUID(), paneID: RemotePaneID?, message: String, occurredAt: Date = Date()) {
        self.id = id
        self.paneID = paneID
        self.message = message
        self.occurredAt = occurredAt
    }
}

struct WorkspaceRemotePaneRecord: Identifiable, Hashable, Sendable {
    let id: RemotePaneID
    let panelID: UUID
    let sessionID: RemoteSessionID
    let hostLabel: String
    let sshTarget: String?
    let title: String
    let remoteRoot: String
    var lifetime: RemotePaneLifetime
    let bindingRole: PaneBindingRole
    var state: RemotePaneLifecycleState
    var hasUncollectedChanges: Bool
}

enum RemotePaneLifecycleState: String, Codable, Sendable {
    case creating
    case running
    case checkpointing
    case readyToClose
    case recoveryRequired
    case closed

    func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.creating, .running),
             (.creating, .recoveryRequired),
             (.running, .checkpointing),
             (.running, .readyToClose),
             (.running, .recoveryRequired),
             (.checkpointing, .running),
             (.checkpointing, .readyToClose),
             (.checkpointing, .recoveryRequired),
             (.readyToClose, .closed),
             (.recoveryRequired, .running),
             (.recoveryRequired, .checkpointing):
            return true
        default:
            return false
        }
    }
}

struct RemoteSessionIdentity: Hashable, Codable, Sendable {
    let id: RemoteSessionID
    let peerID: String
    let startedAt: Date

    init(id: RemoteSessionID = RemoteSessionID(), peerID: String, startedAt: Date = Date()) {
        self.id = id
        self.peerID = peerID
        self.startedAt = startedAt
    }
}

struct RemotePaneIdentity: Hashable, Codable, Sendable {
    let id: RemotePaneID
    let sessionID: RemoteSessionID
    let remoteSurfaceID: String
    var lifetime: RemotePaneLifetime
    var state: RemotePaneLifecycleState

    init(
        id: RemotePaneID = RemotePaneID(),
        sessionID: RemoteSessionID,
        remoteSurfaceID: String,
        lifetime: RemotePaneLifetime = .temporary,
        state: RemotePaneLifecycleState = .creating
    ) {
        self.id = id
        self.sessionID = sessionID
        self.remoteSurfaceID = remoteSurfaceID
        self.lifetime = lifetime
        self.state = state
    }
}

struct PaneBinding: Hashable, Codable, Sendable {
    let id: PaneBindingID
    let workspaceID: UUID
    let paneID: RemotePaneID
    let role: PaneBindingRole

    init(
        id: PaneBindingID = PaneBindingID(),
        workspaceID: UUID,
        paneID: RemotePaneID,
        role: PaneBindingRole
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.role = role
    }
}

struct ProjectBinding: Hashable, Codable, Sendable {
    let id: ProjectBindingID
    let workspaceID: UUID
    let peerID: String
    let localRoot: String
    let remoteRoot: String

    init(
        id: ProjectBindingID = ProjectBindingID(),
        workspaceID: UUID,
        peerID: String,
        localRoot: String,
        remoteRoot: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.peerID = peerID
        self.localRoot = localRoot
        self.remoteRoot = remoteRoot
    }
}

enum RemotePaneCloseAction: Equatable, Sendable {
    case terminateSession
    case detachBinding
    case requireCheckpoint
    case blockForRecovery
}

enum RemotePaneLinkDecision: Equatable, Sendable {
    case link
    case promoteToKeepAlive
}

enum RemotePaneSafetyPolicy {
    static func closeAction(
        lifetime: RemotePaneLifetime,
        bindingRole: PaneBindingRole,
        hasUncollectedChanges: Bool,
        state: RemotePaneLifecycleState
    ) -> RemotePaneCloseAction {
        if state == .recoveryRequired {
            return .blockForRecovery
        }
        if bindingRole == .linked || lifetime == .keepAlive {
            return .detachBinding
        }
        if hasUncollectedChanges {
            return .requireCheckpoint
        }
        return .terminateSession
    }

    static func linkDecision(
        lifetime: RemotePaneLifetime,
        sourceWorkspaceID: UUID,
        destinationWorkspaceID: UUID
    ) -> RemotePaneLinkDecision {
        guard sourceWorkspaceID != destinationWorkspaceID else {
            return .link
        }
        return lifetime == .temporary ? .promoteToKeepAlive : .link
    }
}
