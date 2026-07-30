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

    /// Preferred human label for a peer host in tab chips, workspace titles,
    /// and sidebar rows: the user's saved profile name when one exists for
    /// this host's SSH target (e.g. "builder"), else the host key's raw short
    /// label (advertised hostname / IP for SSH, socket basename for direct).
    ///
    /// This keeps the Workspaces section, tab titles, and the Peer Hosts
    /// section consistent — the Peer Hosts roster already resolves saved
    /// names via `effectiveDisplayName`, but tab/chip display historically
    /// showed the raw SSH target (an IP when the host advertises no name).
    /// Direct connections carry no profile (profiles are keyed by SSH target)
    /// so they correctly fall back to `shortLabel`.
    func displayLabel(for hostKey: PeerPaneHostKey) -> String {
        if let target = hostKey.sshTarget,
           let name = profile(forSSHTarget: target)?.displayName,
           !name.isEmpty {
            return name
        }
        return hostKey.shortLabel
    }

    /// Profiles that have an explicit process recipe. Plain saved hosts stay
    /// on the existing surface-picker path.
    var savedRunnerProfiles: [PeerHostProfile] {
        profiles.filter { $0.savedRunner != nil }
    }

    /// Insert or replace (by id) and persist. Also clears out any other
    /// profile that already claims the same non-empty `sshTarget` — e.g.
    /// the editor changed this profile's target onto one another saved
    /// profile already uses. Without this, `profile(forSSHTarget:)`
    /// (first-match) and the id-based edit here silently diverge, and
    /// the older duplicate keeps reappearing after the edit.
    func upsert(_ profile: PeerHostProfile) {
        profiles = Self.upserted(profiles, with: profile)
        persist()
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    /// Remove every profile pinned to `target`, not just one id. A single
    /// id-based delete only silences the profile the sidebar row happened
    /// to bind to (first-match lookup) — any leftover duplicate for the
    /// same target resurrects the row on the very next profile sync.
    /// No-op for an empty target (no stable identity to key on).
    func deleteAll(forSSHTarget target: String) {
        guard !target.isEmpty else { return }
        profiles = Self.removingAll(profiles, forSSHTarget: target)
        persist()
    }

    /// Pure step behind `upsert`, split out so the dedup-on-write
    /// behavior is unit-testable without the singleton's file I/O.
    /// `nonisolated` (the enclosing type is `@MainActor`) since this
    /// touches no shared state — plain value-type transforms callable
    /// synchronously from test code.
    nonisolated static func upserted(
        _ profiles: [PeerHostProfile], with profile: PeerHostProfile
    ) -> [PeerHostProfile] {
        var result = profiles
        var profile = profile
        if !profile.sshTarget.isEmpty {
            result.removeAll { $0.sshTarget == profile.sshTarget && $0.id != profile.id }
        }
        if let idx = result.firstIndex(where: { $0.id == profile.id }) {
            // An edited explicit socket is a new instruction. In particular,
            // non-empty → empty means "return to auto-detect", so retaining
            // the previous resolved cache would make Apply appear to ignore
            // the deletion. Clear for either deletion or replacement.
            if result[idx].remoteSocket != profile.remoteSocket {
                profile.lastResolvedSocket = nil
            }
            result[idx] = profile
        } else {
            result.append(profile)
        }
        return result
    }

    /// Pure step behind `deleteAll(forSSHTarget:)`. `nonisolated` for
    /// the same reason as `upserted`.
    nonisolated static func removingAll(
        _ profiles: [PeerHostProfile], forSSHTarget target: String
    ) -> [PeerHostProfile] {
        guard !target.isEmpty else { return profiles }
        return profiles.filter { $0.sshTarget != target }
    }

    /// Record a successful connect: bump `lastConnectedAt` and cache an
    /// auto-detected remote socket separately from the user's explicit
    /// `remoteSocket` field.
    /// No-op when no profile matches the target (ad-hoc connections).
    func recordConnection(sshTarget: String, resolvedSocket: String?) {
        guard let idx = profiles.firstIndex(where: { $0.sshTarget == sshTarget }) else { return }
        profiles[idx].lastConnectedAt = Date()
        if let resolvedSocket, !resolvedSocket.isEmpty, profiles[idx].remoteSocket.isEmpty {
            profiles[idx].lastResolvedSocket = resolvedSocket
        }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let bytes = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([PeerHostProfile].self, from: bytes)
        else { return }
        profiles = decoded
        dedupeBySSHTargetIfNeeded()
    }

    /// One-time migration merging profiles that share a saved SSH
    /// target — e.g. seeded twice by an older build, or produced by
    /// hand-editing the JSON file. Runs on every load but only persists
    /// when `dedupedBySSHTarget` actually found something to merge, so
    /// a clean store never rewrites itself.
    private func dedupeBySSHTargetIfNeeded() {
        guard let deduped = Self.dedupedBySSHTarget(profiles) else { return }
        profiles = deduped
        persist()
    }

    /// Pure merge step behind `dedupeBySSHTargetIfNeeded`, split out so
    /// it's unit-testable without the singleton's file I/O. Groups
    /// profiles by non-empty `sshTarget`; each group with more than one
    /// entry collapses to a single survivor, kept at the position of
    /// the group's first occurrence. Survivor priority:
    ///   1. most recent `lastConnectedAt` (nil sorts last)
    ///   2. non-empty `remoteSocket`
    ///   3. first entry in array order
    /// The survivor then backfills displayName/colorHex/symbolName/
    /// identityFile/sshPort from the other duplicates, but only into
    /// fields it doesn't already have — a populated survivor field
    /// always wins. `remoteSocket` is deliberately not backfilled: it
    /// tracks the survivor's own connection recency, not the group's.
    /// Entries with an empty `sshTarget` are left untouched (no stable
    /// identity to dedupe on). Returns nil when there is nothing to
    /// merge, so callers can skip persisting. `nonisolated` for the
    /// same reason as `upserted`.
    nonisolated static func dedupedBySSHTarget(_ profiles: [PeerHostProfile]) -> [PeerHostProfile]? {
        var indicesByTarget: [String: [Int]] = [:]
        for (idx, p) in profiles.enumerated() where !p.sshTarget.isEmpty {
            indicesByTarget[p.sshTarget, default: []].append(idx)
        }
        guard indicesByTarget.contains(where: { $0.value.count > 1 }) else { return nil }

        var survivorAtFirstIndex: [Int: PeerHostProfile] = [:]
        var dropIndices = Set<Int>()
        for indices in indicesByTarget.values where indices.count > 1 {
            let group = indices.map { profiles[$0] }
            var survivor = pickSurvivor(group)
            for candidate in group where candidate.id != survivor.id {
                survivor = backfill(survivor, from: candidate)
            }
            survivorAtFirstIndex[indices[0]] = survivor
            for idx in indices.dropFirst() { dropIndices.insert(idx) }
        }

        var result: [PeerHostProfile] = []
        result.reserveCapacity(profiles.count)
        for (idx, p) in profiles.enumerated() {
            if let survivor = survivorAtFirstIndex[idx] {
                result.append(survivor)
            } else if !dropIndices.contains(idx) {
                result.append(p)
            }
        }
        return result
    }

    /// Single-pass multi-key selection, replacing `best` only on a
    /// STRICT improvement — that's what makes tier 3 ("first entry in
    /// array order") fall out for free on a full tie, instead of
    /// needing its own branch.
    ///
    /// The previous implementation used `group.filter(...).max(by:
    /// lastConnectedAt <)`, which returns as soon as ANY profile in the
    /// group has a non-nil `lastConnectedAt` — so two dated duplicates
    /// with the exact same timestamp (or, less obviously, ANY group
    /// where more than one entry has a date) never fell through to the
    /// `remoteSocket` tier at all: `max(by:)` picks between them on
    /// date alone and returns immediately, regardless of ties.
    nonisolated private static func pickSurvivor(_ group: [PeerHostProfile]) -> PeerHostProfile {
        var best = group[0]
        for candidate in group.dropFirst() where isBetterSurvivor(candidate, than: best) {
            best = candidate
        }
        return best
    }

    /// `true` iff `candidate` should replace `current` under the
    /// documented tier order: (1) more recent `lastConnectedAt` (nil
    /// sorts last), (2) on a tie there, a non-empty `remoteSocket`,
    /// (3) on a further tie, keep `current` (earlier array order) —
    /// expressed here as "no more comparisons left, not better."
    nonisolated private static func isBetterSurvivor(
        _ candidate: PeerHostProfile, than current: PeerHostProfile
    ) -> Bool {
        switch (candidate.lastConnectedAt, current.lastConnectedAt) {
        case let (c?, b?) where c != b:
            return c > b
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            break // both nil, or an exact date tie — fall through to tier 2
        }
        return !candidate.remoteSocket.isEmpty && current.remoteSocket.isEmpty
    }

    nonisolated private static func backfill(
        _ survivor: PeerHostProfile, from other: PeerHostProfile
    ) -> PeerHostProfile {
        var merged = survivor
        if merged.displayName.isEmpty, !other.displayName.isEmpty {
            merged.displayName = other.displayName
        }
        if merged.colorHex == nil, let c = other.colorHex, !c.isEmpty {
            merged.colorHex = c
        }
        if merged.symbolName == nil, let s = other.symbolName, !s.isEmpty {
            merged.symbolName = s
        }
        if merged.identityFile == nil, let i = other.identityFile, !i.isEmpty {
            merged.identityFile = i
        }
        if merged.sshPort == nil, let port = other.sshPort {
            merged.sshPort = port
        }
        return merged
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
