import Foundation
import Bonsplit

/// Where a project lives on each other machine.
///
/// Two machines rarely lay a checkout out the same way, so the local path is
/// not an answer for the remote one and term-mesh has to be told. Being told
/// once is reasonable. Being told again every time a team is composed is the
/// same answer typed over and over — which is what the empty
/// `/path/on/that/machine` field was asking for, once per member, once per
/// team, forever.
///
/// So it is remembered: the first time an agent successfully starts on a peer,
/// the path it started in is kept against that machine and that project, and
/// every later form fills itself in. Wrong entries cost a correction in an
/// editable field, and the correction is what gets remembered next.
@MainActor
final class RemoteProjectPaths {
    static let shared = RemoteProjectPaths()

    private static let storageKey = "termmesh.remoteProjectPaths"

    /// (host, local project root) → path on that host.
    ///
    /// Keyed by the local root rather than by project name because two
    /// checkouts of the same repository are a normal thing to have, and they
    /// do not share a remote counterpart.
    private var paths: [String: String]

    private init() {
        paths = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    private func key(host: String, localRoot: String) -> String {
        "\(host)\u{0000}\(localRoot)"
    }

    /// What this project is called on that machine, if anyone has said.
    func path(host: String, localRoot: String) -> String? {
        let value = paths[key(host: host, localRoot: localRoot)]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Remember where an agent actually started. Called on success rather than
    /// on typing, so a path that turned out to be wrong is not the one offered
    /// next time.
    func remember(host: String, localRoot: String, path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !host.isEmpty, !localRoot.isEmpty else { return }
        paths[key(host: host, localRoot: localRoot)] = trimmed
        UserDefaults.standard.set(paths, forKey: Self.storageKey)
    }

    func forget(host: String, localRoot: String) {
        paths.removeValue(forKey: key(host: host, localRoot: localRoot))
        UserDefaults.standard.set(paths, forKey: Self.storageKey)
    }

    /// Any path known for this machine, whatever the project.
    ///
    /// A worse answer than the project-specific one and a better answer than
    /// an empty field: it at least lands in the right neighbourhood on the
    /// right machine, which is most of what a person needs to correct it.
    func anyPath(host: String) -> String? {
        let prefix = "\(host)\u{0000}"
        return paths.first { $0.key.hasPrefix(prefix) && !$0.value.isEmpty }?.value
    }
}

/// The checkouts a team created on other machines.
///
/// These directories are the team's to reclaim, and the only record of them
/// used to live in `Team.remoteProjectLocations` — in memory. Quit the app and
/// the list was gone, so "Delete Project" could no longer name what to remove
/// and a detached agent's checkout had nothing to match against. The
/// directories stayed on the peer forever, one per team composition, each with
/// its own build output.
///
/// Kept next to the other peer bookkeeping and keyed by team name, which is
/// what every caller already has.
@MainActor
final class RemoteProjectLocationStore {
    struct Record: Codable, Equatable {
        let teamName: String
        let hostKey: String
        let path: String
        /// Only paths created by term-mesh belong to Delete Project. Records
        /// written before this field existed decode as false: preserving an
        /// old checkout is safer than deleting a user's source repository.
        let owned: Bool

        init(teamName: String, hostKey: String, path: String, owned: Bool) {
            self.teamName = teamName
            self.hostKey = hostKey
            self.path = path
            self.owned = owned
        }

        private enum CodingKeys: String, CodingKey {
            case teamName, hostKey, path, owned
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            teamName = try values.decode(String.self, forKey: .teamName)
            hostKey = try values.decode(String.self, forKey: .hostKey)
            path = try values.decode(String.self, forKey: .path)
            owned = try values.decodeIfPresent(Bool.self, forKey: .owned) ?? false
        }
    }

    static let shared = RemoteProjectLocationStore()
    private static let storageKey = "termmesh.remoteProjectLocations"
    private var records: [Record]

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else {
            records = []
            return
        }
        records = decoded
    }

    /// Replace everything known for one team. Callers always hand over the
    /// complete list, so a removed entry must not linger.
    func replace(
        teamName: String,
        locations: [(hostKey: String, path: String, owned: Bool)]
    ) {
        records.removeAll { $0.teamName == teamName }
        records.append(contentsOf: locations.map {
            Record(
                teamName: teamName, hostKey: $0.hostKey, path: $0.path, owned: $0.owned
            )
        })
        persist()
    }

    func locations(teamName: String) -> [(hostKey: String, path: String, owned: Bool)] {
        records
            .filter { $0.teamName == teamName }
            .map { (hostKey: $0.hostKey, path: $0.path, owned: $0.owned) }
    }

    func forget(teamName: String) {
        let before = records.count
        records.removeAll { $0.teamName == teamName }
        if records.count != before { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Host-side shells created for remote leaders and terminal agents.
///
/// A peer surface survives a local viewer disappearing. Remembering the
/// surfaces we created lets a later app run distinguish its abandoned shells
/// from shells the operator opened themselves.
@MainActor
final class ManagedPeerSurfaceStore {
    struct Record: Codable, Identifiable, Equatable {
        let hostKey: String
        let surfaceIDBase64: String
        let teamName: String
        let role: String
        let workingDirectory: String
        let createdAt: Date
        var teamUUID: String? = nil
        var projectID: String? = nil

        var id: String { "\(hostKey)\u{0000}\(surfaceIDBase64)" }
        var surfaceID: Data? { Data(base64Encoded: surfaceIDBase64) }

        private enum CodingKeys: String, CodingKey {
            case hostKey, surfaceIDBase64, teamName, role, workingDirectory
            case createdAt, teamUUID, projectID
        }

        init(
            hostKey: String, surfaceIDBase64: String, teamName: String,
            role: String, workingDirectory: String, createdAt: Date,
            teamUUID: String? = nil, projectID: String? = nil
        ) {
            self.hostKey = hostKey
            self.surfaceIDBase64 = surfaceIDBase64
            self.teamName = teamName
            self.role = role
            self.workingDirectory = workingDirectory
            self.createdAt = createdAt
            self.teamUUID = teamUUID
            self.projectID = projectID
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            hostKey = try values.decode(String.self, forKey: .hostKey)
            surfaceIDBase64 = try values.decode(String.self, forKey: .surfaceIDBase64)
            teamName = try values.decode(String.self, forKey: .teamName)
            role = try values.decode(String.self, forKey: .role)
            workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
            createdAt = try values.decode(Date.self, forKey: .createdAt)
            teamUUID = try values.decodeIfPresent(String.self, forKey: .teamUUID)
            projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
        }
    }

    static let shared = ManagedPeerSurfaceStore()
    private static let storageKey = "termmesh.managedPeerSurfaces"
    private var records: [Record]

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else {
            records = []
            return
        }
        records = decoded
    }

    func remember(
        hostKey: String,
        surfaceID: Data,
        teamName: String,
        role: String,
        workingDirectory: String,
        teamUUID: String? = nil,
        projectID: String? = nil
    ) {
        let encoded = surfaceID.base64EncodedString()
        records.removeAll {
            $0.hostKey == hostKey && $0.surfaceIDBase64 == encoded
        }
        records.append(Record(
            hostKey: hostKey,
            surfaceIDBase64: encoded,
            teamName: teamName,
            role: role,
            workingDirectory: workingDirectory,
            createdAt: Date(),
            teamUUID: teamUUID,
            projectID: projectID
        ))
        persist()
    }

    func forget(hostKey: String, surfaceID: Data) {
        let encoded = surfaceID.base64EncodedString()
        records.removeAll {
            $0.hostKey == hostKey && $0.surfaceIDBase64 == encoded
        }
        persist()
    }

    func records(hostKey: String) -> [Record] {
        records.filter { $0.hostKey == hostKey }
    }

    func leaderRecord(hostKey: String, teamName: String) -> Record? {
        Self.leaderRecord(in: records, hostKey: hostKey, teamName: teamName)
    }

    static func leaderRecord(
        in records: [Record],
        hostKey: String,
        teamName: String
    ) -> Record? {
        records
            .filter {
                $0.hostKey == hostKey
                    && $0.teamName == teamName
                    && $0.role == "leader"
                    && $0.surfaceID != nil
            }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The team that spawned any of these surfaces, on any host. Surface IDs
    /// are host-minted UUIDs, so matching without the host key cannot collide
    /// in practice — and the caller (mirror team-home redirect) has a
    /// `PeerPaneHostKey`, not the store's string key, which this sidesteps.
    func teamName(forAnySurfaceID surfaceIDs: Set<Data>) -> String? {
        records.first { record in
            record.surfaceID.map(surfaceIDs.contains) == true
        }?.teamName
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - Durable Project viewer layout

/// The local viewer layout for one daemon-owned Project. Remote surface IDs
/// survive viewer restarts; Bonsplit pane/tab UUIDs do not, so only surface
/// IDs may cross this persistence boundary.
struct ProjectPresentationLayoutSnapshot: Codable, Equatable, Sendable {
    static let minimumDividerPosition = 0.1
    static let maximumDividerPosition = 0.9

    enum Orientation: String, Codable, Equatable, Sendable {
        case horizontal
        case vertical
    }

    struct Pane: Codable, Equatable, Sendable {
        let surfaceID: Data
    }

    indirect enum Node: Codable, Equatable, Sendable {
        case pane(Pane)
        case split(orientation: Orientation, dividerPosition: Double, first: Node, second: Node)

        private enum CodingKeys: String, CodingKey {
            case type, pane, orientation, dividerPosition, first, second
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "pane":
                self = .pane(try container.decode(Pane.self, forKey: .pane))
            case "split":
                self = .split(
                    orientation: try container.decode(Orientation.self, forKey: .orientation),
                    dividerPosition: try container.decode(Double.self, forKey: .dividerPosition),
                    first: try container.decode(Node.self, forKey: .first),
                    second: try container.decode(Node.self, forKey: .second)
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container, debugDescription: "unknown project layout node"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pane(let pane):
                try container.encode("pane", forKey: .type)
                try container.encode(pane, forKey: .pane)
            case .split(let orientation, let dividerPosition, let first, let second):
                try container.encode("split", forKey: .type)
                try container.encode(orientation, forKey: .orientation)
                try container.encode(dividerPosition, forKey: .dividerPosition)
                try container.encode(first, forKey: .first)
                try container.encode(second, forKey: .second)
            }
        }

        var surfaceIDs: [Data] {
            switch self {
            case .pane(let pane): return [pane.surfaceID]
            case .split(_, _, let first, let second):
                return first.surfaceIDs + second.surfaceIDs
            }
        }

        var hasValidGeometry: Bool {
            switch self {
            case .pane:
                return true
            case .split(_, let dividerPosition, let first, let second):
                return dividerPosition.isFinite
                    && (
                        ProjectPresentationLayoutSnapshot.minimumDividerPosition
                            ... ProjectPresentationLayoutSnapshot.maximumDividerPosition
                    ).contains(dividerPosition)
                    && first.hasValidGeometry
                    && second.hasValidGeometry
            }
        }
    }

    let version: Int
    let projectID: String
    let root: Node
    let focusedSurfaceID: Data?

    init(projectID: String, root: Node, focusedSurfaceID: Data?) {
        version = 2
        self.projectID = projectID
        self.root = root
        self.focusedSurfaceID = focusedSurfaceID
    }

    var surfaceIDs: Set<Data> { Set(root.surfaceIDs) }

    var isValid: Bool {
        let ids = root.surfaceIDs
        return version == 2
            && !projectID.isEmpty
            && !ids.isEmpty
            && ids.allSatisfy { !$0.isEmpty }
            && Set(ids).count == ids.count
            && root.hasValidGeometry
    }

    func canApply(to liveSurfaceIDs: Set<Data>) -> Bool {
        isValid && surfaceIDs == liveSurfaceIDs
    }

    static func capture(
        projectID: String,
        tree: ExternalTreeNode,
        surfaceIDByTabID: [String: Data],
        focusedSurfaceID: Data?
    ) -> Self? {
        func convert(_ node: ExternalTreeNode) -> Node? {
            switch node {
            case .pane(let pane):
                guard pane.tabs.count == 1,
                      let surfaceID = surfaceIDByTabID[pane.tabs[0].id] else { return nil }
                return .pane(Pane(surfaceID: surfaceID))
            case .split(let split):
                guard let first = convert(split.first), let second = convert(split.second) else {
                    return nil
                }
                return .split(
                    orientation: Orientation(rawValue: split.orientation) ?? .horizontal,
                    dividerPosition: split.dividerPosition,
                    first: first,
                    second: second
                )
            }
        }
        guard let root = convert(tree) else { return nil }
        let snapshot = Self(
            projectID: projectID, root: root, focusedSurfaceID: focusedSurfaceID
        )
        return snapshot.isValid ? snapshot : nil
    }
}

@MainActor
final class ProjectPresentationLayoutStore {
    private struct File: Codable, Sendable {
        let version: Int
        var records: [String: ProjectPresentationLayoutSnapshot]
    }

    static let shared = ProjectPresentationLayoutStore()
    private let fileURL: URL
    private var records: [String: ProjectPresentationLayoutSnapshot]
    private static let writeQueue = DispatchQueue(
        label: "com.termmesh.project-presentation-layouts", qos: .utility
    )

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        guard let data = try? Data(contentsOf: self.fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 2 else {
            records = [:]
            return
        }
        records = file.records.filter { $0.value.isValid && $0.key == $0.value.projectID }
    }

    func snapshot(projectID: String) -> ProjectPresentationLayoutSnapshot? {
        records[projectID]
    }

    func save(_ snapshot: ProjectPresentationLayoutSnapshot) {
        guard snapshot.isValid else { return }
        guard records[snapshot.projectID] != snapshot else { return }
        records[snapshot.projectID] = snapshot
        persist()
    }

    func remove(projectID: String) {
        guard records.removeValue(forKey: projectID) != nil else { return }
        persist()
    }

    #if DEBUG
    func waitForPendingWritesForTests() {
        Self.writeQueue.sync {}
    }
    #endif

    func flushPendingWritesForQuit() {
        Self.writeQueue.sync {}
    }

    private static func defaultFileURL() -> URL {
        let root: URL
        if let override = SessionRestoreSettings.stateDirectoryOverride() {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("term-mesh", isDirectory: true)
        }
        return root.appendingPathComponent("project-presentation-layouts-v2.json")
    }

    private func persist() {
        let fileURL = fileURL
        let file = File(version: 2, records: records)
        Self.writeQueue.async {
            guard let data = try? JSONEncoder().encode(file) else {
                RemoteWorkLog.errorOffMain("Could not encode Project pane layout")
                return
            }
            Self.write(data, to: fileURL)
        }
    }

    nonisolated private static func write(_ data: Data, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            RemoteWorkLog.warningOffMain("Could not save Project pane layout: \(error)")
        }
    }
}
