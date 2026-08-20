import Foundation

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

        var id: String { "\(hostKey)\u{0000}\(surfaceIDBase64)" }
        var surfaceID: Data? { Data(base64Encoded: surfaceIDBase64) }
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
        workingDirectory: String
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
            createdAt: Date()
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
