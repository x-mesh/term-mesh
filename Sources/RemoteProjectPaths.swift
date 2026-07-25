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
