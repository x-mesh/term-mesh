import Foundation
import SwiftUI

/// Cargo settings that keep an agent worker's `target/` small.
///
/// Every worker worktree keeps its own `target/`, and the incremental cache is
/// a third to a half of it. Workers rarely rebuild the same worktree long
/// enough for that cache to pay off, so dropping it, and keeping only line
/// tables for debug info, trades a slower rebuild for much less disk.
///
/// Off by default: turning it on changes how every worker builds.
enum WorkerBuildEnvironment {
    static let enabledKey = "agentWorkers.smallCargoBuilds"

    static let values: [String: String] = [
        "CARGO_INCREMENTAL": "0",
        "CARGO_PROFILE_DEV_DEBUG": "line-tables-only",
        "CARGO_PROFILE_TEST_DEBUG": "line-tables-only",
    ]

    /// The variables to add, leaving out any the worker already inherits:
    /// a value someone set on purpose wins over this default.
    static func environment(enabled: Bool, inherited: [String: String]) -> [String: String] {
        guard enabled else { return [:] }
        return values.filter { inherited[$0.key] == nil }
    }

    static func current(
        defaults: UserDefaults = .standard,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment(enabled: defaults.bool(forKey: enabledKey), inherited: inherited)
    }

    /// Remote workers. This Mac cannot see the remote shell's environment, so
    /// nothing is filtered here; the CLI profile and the host's stored
    /// environment are layered on top and win instead.
    static func remote(defaults: UserDefaults = .standard) -> [String: String] {
        environment(enabled: defaults.bool(forKey: enabledKey), inherited: [:])
    }

    /// Headless workers: these defaults sit under the CLI profile's env, so a
    /// profile that sets the same variable keeps its value.
    static func headlessExtraEnv(
        profile: [String: String],
        build: [String: String] = current()
    ) -> [String: String] {
        build.merging(profile) { _, profileValue in profileValue }
    }

    /// GUI pane workers: added under the app-owned routing values, which they
    /// never share a key with. `applyAgentProfileEnvironment` then lets a CLI
    /// profile override them like any other ordinary value.
    static func paneEnvironment(
        required: [String: String],
        build: [String: String] = current()
    ) -> [String: String] {
        required.merging(build) { requiredValue, _ in requiredValue }
    }
}

/// The settings card for `WorkerBuildEnvironment`.
struct WorkerBuildSettingsSection: View {
    @AppStorage(WorkerBuildEnvironment.enabledKey) private var enabled = false
    @AppStorage(DelegateDiskGate.minimumFreeGBKey)
    private var minimumFreeGB = DelegateDiskGate.defaultMinimumFreeGB

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Worker Builds")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            SettingsCard {
                SettingsCardRow(
                    "Smaller Cargo Builds",
                    subtitle: "Agent workers build without the incremental cache and keep only line tables for debug info. Rebuilds take longer. A CLI profile that sets the same variable keeps its value."
                ) {
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsCardDivider()

                SettingsCardRow(
                    "Minimum Free Disk to Delegate",
                    subtitle: "A delegation is refused when the disk the worker builds on has less free space. The leader is told why and how to reclaim space. 0 turns this off."
                ) {
                    Stepper(value: $minimumFreeGB, in: 0...500) {
                        Text(verbatim: minimumFreeGB == 0
                            ? LanguageSettings.localized("Off")
                            : "\(minimumFreeGB) GB")
                            .monospacedDigit()
                    }
                }
            }

            Text("Sets `CARGO_INCREMENTAL=0`, `CARGO_PROFILE_DEV_DEBUG=line-tables-only` and `CARGO_PROFILE_TEST_DEBUG=line-tables-only` for agent workers started after the change. Remote workers get them too, unless that host's stored environment sets them. Leaders and your own terminals are not affected.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }
}
