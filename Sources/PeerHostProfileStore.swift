//  PeerHostProfileStore: persistence for saved remote-host profiles.
//  JSON file in Application Support (same directory convention as
//  CliProfileStore/cli-profiles.json) so profiles are shared across
//  DEV/STAGING/Release instances and easy to back up or hand-edit.
//
//  Unlike CliProfileStore's queue-synced accessor, this store is a
//  @MainActor ObservableObject: the sidebar subscribes live and every
//  caller is UI-driven, so main-actor confinement is both correct and
//  simpler.

import Foundation

@MainActor
final class PeerHostProfileStore: ObservableObject {
    static let shared = PeerHostProfileStore()

    @Published private(set) var profiles: [PeerHostProfile] = []

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("term-mesh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("peer-host-profiles.json")
    }

    private init() {
        load()
        migrateRecentHostsIfNeeded()
    }

    func profile(id: UUID?) -> PeerHostProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func profile(forSSHTarget target: String) -> PeerHostProfile? {
        profiles.first { $0.sshTarget == target }
    }

    /// Insert or replace (by id) and persist.
    func upsert(_ profile: PeerHostProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    /// Record a successful connect: bump `lastConnectedAt` and cache
    /// the resolved remote socket so the next connect skips the probe.
    /// No-op when no profile matches the target (ad-hoc connections).
    func recordConnection(sshTarget: String, resolvedSocket: String?) {
        guard let idx = profiles.firstIndex(where: { $0.sshTarget == sshTarget }) else { return }
        profiles[idx].lastConnectedAt = Date()
        if let resolvedSocket, !resolvedSocket.isEmpty, profiles[idx].remoteSocket.isEmpty {
            profiles[idx].remoteSocket = resolvedSocket
        }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let bytes = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([PeerHostProfile].self, from: bytes)
        else { return }
        profiles = decoded
    }

    private func persist() {
        guard let bytes = try? JSONEncoder().encode(profiles) else {
            NSLog("PeerHostProfileStore: encode failed")
            return
        }
        try? bytes.write(to: Self.storeURL, options: .atomic)
    }

    /// One-time promotion of the legacy RecentHost list (UserDefaults,
    /// max 8 entries) into saved profiles. The store file's existence
    /// is the completion flag — idempotent, no separate marker; a user
    /// who empties the store keeps an empty file, so migration never
    /// resurrects deleted hosts.
    private func migrateRecentHostsIfNeeded() {
        guard !FileManager.default.fileExists(atPath: Self.storeURL.path) else { return }
        let recents = PeerFederationSettings.loadRecentHosts()
        guard !recents.isEmpty else { return }
        profiles = recents.map {
            PeerHostProfile(sshTarget: $0.sshTarget, remoteSocket: $0.remoteSocket)
        }
        persist()
    }
}
