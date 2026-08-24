import Foundation

/// Versioned, pure recommendation logic. It never dispatches work; callers
/// record its suggestion separately from the route a leader actually chose.
enum LeaderParticipationPolicy {
    static let version = "1"

    enum Participation: String, Codable, CaseIterable {
        case coordinator
        case balanced
        case handsOn = "hands_on"
    }

    enum Route: String, Codable { case direct, probe, parallel }

    enum Reason: String, Codable, CaseIterable {
        case unsupportedInput = "unsupported_input"
        case highRisk = "high_risk"
        case singleUnit = "single_unit"
        case parallelReady = "parallel_ready"
        case limitedCapacity = "limited_capacity"
    }

    struct Input: Equatable {
        var taskShape: String?
        var riskReasons: Set<String>
        var availableWorkers: Int?

        init(taskShape: String? = nil, riskReasons: Set<String> = [], availableWorkers: Int? = nil) {
            self.taskShape = taskShape
            self.riskReasons = riskReasons
            self.availableWorkers = availableWorkers
        }
    }

    struct Suggestion: Equatable {
        let participation: Participation
        let route: Route
        let reasons: [Reason]
        /// The only behavior a later canary is allowed to request. This is not
        /// an enforcement claim about arbitrary model edits or shell commands.
        let observableDispatchBounds: String
    }

    static func evaluate(_ input: Input) -> Suggestion {
        let shape = input.taskShape?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let workers = input.availableWorkers, workers >= 0 else {
            return .init(
                participation: .handsOn, route: .direct, reasons: [.unsupportedInput],
                observableDispatchBounds: "no required worker dispatch"
            )
        }
        if !input.riskReasons.isEmpty {
            return .init(
                participation: .balanced, route: .probe, reasons: [.highRisk],
                observableDispatchBounds: "at most one read-only probe"
            )
        }
        if workers >= 2, ["multi_unit", "cross_subsystem", "parallelizable"].contains(shape ?? "") {
            return .init(
                participation: .coordinator, route: .parallel, reasons: [.parallelReady],
                observableDispatchBounds: "two or three dependency-ready, ownership-disjoint tasks"
            )
        }
        if shape == "single_unit" || workers == 0 {
            return .init(
                participation: .handsOn, route: .direct, reasons: [.singleUnit],
                observableDispatchBounds: "no required worker dispatch"
            )
        }
        return .init(
            participation: .balanced, route: .probe, reasons: [.limitedCapacity],
            observableDispatchBounds: "at most one read-only probe"
        )
    }
}
