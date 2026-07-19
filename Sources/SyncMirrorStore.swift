import Foundation
import SwiftUI

/// What a project binding's mirror is doing, for the Mirror tab to render.
///
/// Deliberately per-binding: a workspace can hold panes on several hosts, and
/// each one mirrors its own folder pair independently.
/// The folder pair a mirror keeps equal.
struct MirrorPaths: Codable, Equatable {
    var local: String
    var remote: String

    /// Whether a root is broad enough that mirroring it is probably a mistake.
    ///
    /// Sync propagates deletions, so pointing it at a home directory or a
    /// filesystem root risks far more than the project the user had in mind.
    /// The daemon's wipe guard is a backstop for the catastrophic case; this is
    /// the warning that comes before it.
    static func isBroadRoot(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        if components.count <= 1 { return true }                       // "/", "/root", "/tmp"
        if components.count == 2,
           ["Users", "home"].contains(String(components[0])) {
            return true                                               // "/Users/me", "/home/me"
        }
        return false
    }
}

enum SyncMirrorState: Equatable {
    case idle
    case provisioning
    case syncing
    case synced(at: Date, entries: UInt64)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .provisioning, .syncing: return true
        default: return false
        }
    }
}

@MainActor
final class SyncMirrorStore: ObservableObject {
    /// Mirror state keyed by the binding it belongs to.
    @Published private(set) var states: [ProjectBindingID: SyncMirrorState] = [:]

    /// The sync project id assigned to each binding, once provisioned.
    ///
    /// Persisted so a relaunch keeps mirroring the same project instead of
    /// provisioning a second one over the same folders — the daemon registry
    /// rejects a duplicate root path, so a fresh id per launch would break on
    /// the second run.
    @Published private(set) var projectIDs: [ProjectBindingID: String] = [:]

    /// Per-binding path overrides, so a mirror is not stuck with whatever
    /// directory the remote pane happened to open in.
    @Published private(set) var overrides: [ProjectBindingID: MirrorPaths] = [:]

    private static let projectIDDefaultsKey = "termmesh.sync.mirror.projectIDs"
    private static let overridesDefaultsKey = "termmesh.sync.mirror.paths"

    init() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.projectIDDefaultsKey) as? [String: String] {
            for (raw, projectID) in stored {
                guard let uuid = UUID(uuidString: raw) else { continue }
                projectIDs[ProjectBindingID(rawValue: uuid)] = projectID
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.overridesDefaultsKey),
           let stored = try? JSONDecoder().decode([String: MirrorPaths].self, from: data) {
            for (raw, paths) in stored {
                guard let uuid = UUID(uuidString: raw) else { continue }
                overrides[ProjectBindingID(rawValue: uuid)] = paths
            }
        }
    }

    /// The folders this binding actually mirrors: the user's override when set,
    /// otherwise what the pane bound.
    func paths(for binding: ProjectBinding) -> MirrorPaths {
        overrides[binding.id] ?? MirrorPaths(local: binding.localRoot, remote: binding.remoteRoot)
    }

    /// Re-point a mirror at different folders.
    ///
    /// Changing either side drops the provisioning record: a sync project is
    /// anchored to its local root, so a different folder is a different project
    /// and reusing the old id would sync the wrong tree.
    func setPaths(_ paths: MirrorPaths, for binding: ProjectBinding) {
        guard paths != self.paths(for: binding) else { return }
        overrides[binding.id] = paths
        projectIDs.removeValue(forKey: binding.id)
        states.removeValue(forKey: binding.id)
        persistProjectIDs()
        persistOverrides()
    }

    func state(for binding: ProjectBindingID) -> SyncMirrorState {
        states[binding] ?? .idle
    }

    func isProvisioned(_ binding: ProjectBindingID) -> Bool {
        projectIDs[binding] != nil
    }

    /// Mirror `binding` once: provision on the first run, then sync.
    ///
    /// `sshTarget` and `peerAddress` are separate because they answer different
    /// questions — ssh reaches the peer to drive its daemon, while the address
    /// is what THIS side dials for QUIC. They are usually the same host, but the
    /// ssh target may be an ssh-config alias that the transport cannot use.
    func mirror(
        binding: ProjectBinding,
        sshTarget: String,
        peerAddress: String,
        remoteToolPath: String,
        remoteSocketPath: String
    ) async {
        let effective = paths(for: binding)
        let existing = projectIDs[binding.id]
        states[binding.id] = existing == nil ? .provisioning : .syncing
        do {
            let result: SyncMirrorResult
            if let existing {
                result = try await SyncService.shared.syncNow(
                    projectID: existing,
                    peerSSHTarget: sshTarget,
                    remoteToolPath: remoteToolPath,
                    remoteSocketPath: remoteSocketPath
                )
            } else {
                // The daemon's own registration is the anchor when this app has
                // no record — a folder that is already registered keeps its id
                // for good, so adopt it rather than minting one that would be
                // rejected.
                let projectID = await SyncService.shared.localProjectID(for: effective.local)
                    ?? SyncService.randomHex(bytes: 32)

                // Already provisioned, just not by a run this app remembers —
                // resume at the sync. Provisioning again would be refused and
                // would leave the mirror unusable.
                if SyncService.isProvisioned(projectID: projectID) {
                    projectIDs[binding.id] = projectID
                    persistProjectIDs()
                    states[binding.id] = .syncing
                    result = try await SyncService.shared.syncNow(
                        projectID: projectID,
                        peerSSHTarget: sshTarget,
                        remoteToolPath: remoteToolPath,
                        remoteSocketPath: remoteSocketPath
                    )
                    states[binding.id] = .synced(at: Date(), entries: result.entries)
                    return
                }

                // Provision and record BEFORE syncing. Provisioning is not
                // idempotent — re-applying the same grants at the same roster
                // epoch is refused — so if a later step fails, the retry must
                // resume at the sync, never at the provisioning. Recording only
                // after a successful sync is what previously turned one
                // transfer error into a permanently unusable mirror.
                try await SyncService.shared.provision(
                    projectID: projectID,
                    localPath: effective.local,
                    peerSSHTarget: sshTarget,
                    peerAddress: peerAddress,
                    remotePath: effective.remote,
                    remoteToolPath: remoteToolPath,
                    remoteSocketPath: remoteSocketPath
                )
                projectIDs[binding.id] = projectID
                persistProjectIDs()
                states[binding.id] = .syncing
                result = try await SyncService.shared.syncNow(
                    projectID: projectID,
                    peerSSHTarget: sshTarget,
                    remoteToolPath: remoteToolPath,
                    remoteSocketPath: remoteSocketPath
                )
            }
            states[binding.id] = .synced(at: Date(), entries: result.entries)
        } catch {
            SyncService.logFailure("mirror failed: \(error.localizedDescription)")
            states[binding.id] = .failed(error.localizedDescription)
        }
    }

    /// Forget a binding's provisioning so the next mirror starts clean. Used
    /// when the daemon's state no longer matches ours (a wiped state dir, a
    /// project removed behind our back).
    func reset(binding: ProjectBindingID) {
        projectIDs.removeValue(forKey: binding)
        states.removeValue(forKey: binding)
        persistProjectIDs()
    }

    private func persistOverrides() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.overridesDefaultsKey)
        }
    }

    private func persistProjectIDs() {
        let raw = Dictionary(uniqueKeysWithValues: projectIDs.map { ($0.key.rawValue.uuidString, $0.value) })
        UserDefaults.standard.set(raw, forKey: Self.projectIDDefaultsKey)
    }
}
