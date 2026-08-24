import Foundation

/// Additive persisted controls for a future opt-in canary. Fresh installs stay
/// in shadow mode with a zero-percent canary, so changing this type never
/// changes a leader's behavior by itself.
struct LeaderParticipationSettings: Equatable {
    enum Mode: String { case off, shadow, canary }
    enum Cohort: String { case staticPolicy = "static", shadow, canary, holdout }
    enum Resolution: Equatable { case staticPolicy(Cohort), shadow(Cohort), canary(Cohort) }

    static let modeKey = "leaderParticipation.mode"
    static let canaryPercentKey = "leaderParticipation.canaryPercent"
    static let killSwitchKey = "leaderParticipation.killSwitch"
    static let optInProjectsKey = "leaderParticipation.optInProjects"
    static let optInProjectsCSVKey = "leaderParticipation.optInProjectsCSV"

    var mode: Mode
    var canaryPercent: Int
    var killSwitch: Bool
    var optInProjects: Set<String>

    static let `default` = Self(mode: .shadow, canaryPercent: 0, killSwitch: false, optInProjects: [])

    struct Health: Equatable {
        var supportedTurns: Int
        var observedDays: Int
        var coverage: Double
        var linkage: Double
        var unknownRate: Double

        var passesPromotionGate: Bool {
            (supportedTurns >= 500 || observedDays >= 7)
                && coverage >= 0.95 && linkage >= 0.95 && unknownRate <= 0.02
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let mode = Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .shadow
        let percent = min(100, max(0, defaults.object(forKey: canaryPercentKey) as? Int ?? 0))
        let csvProjects = (defaults.string(forKey: optInProjectsCSVKey) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let projects = Set((defaults.stringArray(forKey: optInProjectsKey) ?? []) + csvProjects)
        return Self(mode: mode, canaryPercent: percent, killSwitch: defaults.bool(forKey: killSwitchKey), optInProjects: projects)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(min(100, max(0, canaryPercent)), forKey: Self.canaryPercentKey)
        defaults.set(killSwitch, forKey: Self.killSwitchKey)
        defaults.set(Array(optInProjects).sorted(), forKey: Self.optInProjectsKey)
        defaults.set(Array(optInProjects).sorted().joined(separator: ", "), forKey: Self.optInProjectsCSVKey)
    }

    /// Stable bucket assignment permits exact canary/holdout comparison without
    /// storing a new migration-backed assignment for every turn.
    static func cohort(projectID: String, sessionID: String, percent: Int) -> Cohort {
        let bounded = min(100, max(0, percent))
        guard bounded > 0 else { return .holdout }
        let bytes = Array((projectID + "|" + sessionID).utf8)
        let bucket = bytes.reduce(0) { ($0 &* 31 &+ Int($1)) % 100 }
        return bucket < bounded ? .canary : .holdout
    }

    func resolve(projectID: String, sessionID: String, supportedLeader: Bool, health: Health) -> Resolution {
        guard !killSwitch, supportedLeader else { return .staticPolicy(.staticPolicy) }
        switch mode {
        case .off: return .staticPolicy(.staticPolicy)
        case .shadow: return .shadow(.shadow)
        case .canary:
            guard optInProjects.contains(projectID), health.passesPromotionGate else { return .staticPolicy(.staticPolicy) }
            let assigned = Self.cohort(projectID: projectID, sessionID: sessionID, percent: canaryPercent)
            return assigned == .canary ? .canary(.canary) : .staticPolicy(.holdout)
        }
    }

    func controlPayload(
        projectID: String, sessionID: String, supportedLeader: Bool, health: Health
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "mode": mode.rawValue,
            "percent": min(100, max(0, canaryPercent)),
            "kill_switch": killSwitch,
            "supported": supportedLeader,
            "healthy": health.passesPromotionGate,
            "opt_in": optInProjects.contains(projectID),
            "project_id": projectID,
            "session_id": sessionID,
        ]
    }
}
