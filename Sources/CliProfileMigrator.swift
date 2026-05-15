import Foundation

enum CliProfileMigrator {
    static let migratedKey = "cliProfiles.migrated"

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }

        for cli in ["claude", "kiro", "codex", "gemini"] {
            let legacyPath = defaults.string(forKey: "cliPath.\(cli)") ?? ""
            guard !legacyPath.isEmpty else { continue }

            let profile = CliProfile(
                name: "Default",
                family: cli,
                executable: legacyPath
            )
            CliProfileStore.shared.save(profile, for: cli)
            defaults.set(profile.id.uuidString, forKey: "cliProfiles.active.\(cli)")
        }

        defaults.set(true, forKey: migratedKey)
    }

    // Called when the user edits the legacy CLI path text field directly.
    static func upsertDefaultProfile(path: String, for cli: String, defaults: UserDefaults = .standard) {
        let existing = CliProfileStore.shared.profiles(for: cli).first { $0.name == "Default" }
        var profile = existing ?? CliProfile(name: "Default", family: cli, executable: path)
        profile.executable = path
        CliProfileStore.shared.save(profile, for: cli)
        defaults.set(profile.id.uuidString, forKey: "cliProfiles.active.\(cli)")
        defaults.set(path, forKey: "cliPath.\(cli)")
    }
}
