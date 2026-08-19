import Foundation

/// Which project a workspace belongs to, when it said so itself.
///
/// The sidebar works this out from the directories its panes report, which is
/// the right answer for a workspace someone opened in a checkout: nobody
/// declares anything, and the paths are the truth.
///
/// It is the wrong answer for a project that lives on another machine. Its
/// panes are here but its work is not — the leader sits in a home directory
/// because there is nothing local to sit in, and each member's pane is a peer
/// surface whose real directory is on the far side. Inferring from local paths
/// gets "nowhere in particular", so the project the person just named and
/// created appeared under Unassigned, with the sidebar saying "No projects
/// yet" directly above it.
///
/// Nor does the far side rescue it: members are deliberately given separate
/// checkouts, so their directories are `<project>-executor`, `<project>-architect`
/// — different folder names, which is exactly what the path rule reads as
/// different projects.
///
/// So a project created here records its own name. Declared beats inferred,
/// and inference stays in place for everything nobody declared.
@MainActor
final class WorkspaceProjectNames {
    static let shared = WorkspaceProjectNames()

    private static let storageKey = "termmesh.workspaceProjectNames"

    /// Workspace UUID string → project name.
    private var names: [String: String]

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func declare(workspaceId: UUID, projectName: String) {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        names[workspaceId.uuidString] = trimmed
        UserDefaults.standard.set(names, forKey: Self.storageKey)
    }

    func forget(workspaceId: UUID) {
        guard names.removeValue(forKey: workspaceId.uuidString) != nil else { return }
        UserDefaults.standard.set(names, forKey: Self.storageKey)
    }

    /// Drop every declaration outside `ids`.
    ///
    /// `forget` covers a workspace someone closes, which leaves out the ones
    /// that simply stop existing: team and peer-mirror workspaces are excluded
    /// from the saved session, and quitting the app ends them without a close.
    /// Their declarations named an ID no launch can produce again, so nothing
    /// ever removed them and the map kept every one this install had declared.
    ///
    /// Called once with the workspaces a restore produced. A team workspace
    /// created later this run declares itself as it is built, so pruning to the
    /// restored set cannot strand one that is still coming.
    func retain(ids: Set<UUID>) {
        let live = Set(ids.map(\.uuidString))
        let pruned = names.filter { live.contains($0.key) }
        guard pruned.count != names.count else { return }
        names = pruned
        UserDefaults.standard.set(names, forKey: Self.storageKey)
    }

    func projectName(for workspaceId: UUID) -> String? {
        names[workspaceId.uuidString]
    }

    /// The identity the sidebar groups by, built the same way the path rule
    /// builds it so a declared project and an inferred one with the same name
    /// land in one group rather than two.
    func identity(for workspaceId: UUID) -> PeerProjectIdentity? {
        guard let name = projectName(for: workspaceId) else { return nil }
        return PeerProjectIdentity(
            key: "name:\(name.lowercased())",
            label: name,
            isUnknown: false
        )
    }
}
