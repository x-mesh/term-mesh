import Foundation

extension CLIPathSettings {

    // MARK: - Profile API

    static func profiles(for cli: String) -> [CliProfile] {
        CliProfileStore.shared.profiles(for: cli)
    }

    static func activeProfile(for cli: String) -> CliProfile? {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: "cliProfiles.active.\(cli)"),
              let id = UUID(uuidString: idString)
        else { return nil }
        return CliProfileStore.shared.profiles(for: cli).first { $0.id == id }
    }

    static func setActiveProfile(_ profile: CliProfile, for cli: String) {
        assert(profile.family == cli, "Profile family \(profile.family) != cli \(cli)")
        let defaults = UserDefaults.standard
        defaults.set(profile.id.uuidString, forKey: "cliProfiles.active.\(cli)")
        // dual-write: keep legacy key valid for older builds
        if !profile.executable.isEmpty {
            defaults.set(profile.executable, forKey: "cliPath.\(cli)")
        }
    }

    static func resolvedExecutable(for cli: String) -> String? {
        if let exe = activeProfile(for: cli)?.executable, !exe.isEmpty {
            return exe
        }
        let detected = autoDetect(cli: cli)
        return detected.isEmpty ? nil : detected
    }

    static func extraArgs(for cli: String) -> [String] {
        activeProfile(for: cli)?.extraArgs ?? []
    }

    static func env(for cli: String) -> [String: String] {
        activeProfile(for: cli)?.env ?? [:]
    }

    // MARK: - Recent paths (max 10)

    static func recent(for cli: String) -> [String] {
        let key = "cliProfiles.recent.\(cli)"
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    static func addRecent(_ path: String, for cli: String) {
        var list = recent(for: cli).filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        let key = "cliProfiles.recent.\(cli)"
        if let data = try? JSONEncoder().encode(list),
           let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
}
