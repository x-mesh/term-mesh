import Foundation

/// Which tasks may start now, and why the rest may not.
///
/// The board has always stored `depends_on` and shown it on the row, but
/// nothing consulted it before handing work out — the graph was documentation.
/// This is what makes it a gate, which is also what lets a chain run without
/// anyone watching it: a task becomes ready the moment its last dependency
/// lands, on the same refresh that noticed.
///
/// Nothing here dispatches. It answers "may this start", and the existing
/// placement dispatcher does the sending — a stalled chain and a broken
/// dispatch are different bugs, and keeping the decision separate keeps them
/// telling apart.
enum AutoPilotDispatch {
    /// A dependency counts as satisfied only once it has actually landed.
    ///
    /// `review_ready` is deliberately not in here even though the agent is
    /// finished with it. A dependent task branches off the parent, and a
    /// parent still awaiting review has not merged — starting the child then
    /// gives it a tree without the code it depends on, which is the exact
    /// failure the graph exists to prevent.
    static let landedStatuses: Set<String> = ["completed", "approved", "merged", "done"]

    /// Statuses that are a dead end rather than a delay. A child of one of
    /// these will never become ready on its own.
    static let deadEndStatuses: Set<String> = [
        "failed", "blocked", "cancelled", "rejected", "quarantined", "suspect",
    ]

    /// Statuses that mean the task is waiting for someone to start it.
    /// Anything already running, finished or stopped is not a dispatch
    /// candidate — re-sending work in flight is how an agent gets the same
    /// task twice.
    static let waitingStatuses: Set<String> = ["pending", "queued", "ready", "unassigned"]

    struct Readiness: Equatable {
        /// Task ids that may be dispatched now.
        let ready: [String]
        /// Why each candidate that is not ready is not, keyed by task id.
        /// A stalled board should say what it is waiting for rather than
        /// looking idle.
        let waiting: [String: String]
        /// Candidates that will never become ready without a person: a
        /// dependency failed, was cancelled, or the graph loops.
        let needsAPerson: [String: String]
    }

    static func evaluate(_ tasks: [ReviewBoardTask]) -> Readiness {
        let byID = Dictionary(tasks.map { ($0.rawID, $0) }, uniquingKeysWith: { first, _ in first })
        var ready: [String] = []
        var waiting: [String: String] = [:]
        var needsAPerson: [String: String] = [:]

        for task in tasks where waitingStatuses.contains(task.status) {
            switch verdict(for: task, in: byID) {
            case .ready:
                ready.append(task.rawID)
            case .waiting(let reason):
                waiting[task.rawID] = reason
            case .stuck(let reason):
                needsAPerson[task.rawID] = reason
            }
        }
        return Readiness(ready: ready, waiting: waiting, needsAPerson: needsAPerson)
    }

    private enum Verdict {
        case ready
        case waiting(String)
        case stuck(String)
    }

    private static func verdict(
        for task: ReviewBoardTask, in byID: [String: ReviewBoardTask]
    ) -> Verdict {
        if let cycle = cycleReason(from: task, in: byID) { return .stuck(cycle) }

        var pending: [String] = []
        for dependencyID in task.dependsOn {
            guard let dependency = byID[dependencyID] else {
                // A dependency the board cannot see will never be observed to
                // finish, so waiting on it is waiting forever.
                return .stuck("Depends on \(dependencyID), which is not on this board.")
            }
            if landedStatuses.contains(dependency.status) { continue }
            if deadEndStatuses.contains(dependency.status) {
                return .stuck(
                    "\(dependency.title) is \(dependency.status); auto pilot does not reassign it."
                )
            }
            pending.append(dependency.title)
        }

        guard pending.isEmpty else {
            return .waiting(waitingReason(pending))
        }
        return .ready
    }

    private static func waitingReason(_ pending: [String]) -> String {
        pending.count == 1
            ? "Waiting on \(pending[0])."
            : "Waiting on \(pending.count) tasks: \(pending.joined(separator: ", "))."
    }

    /// Why this work may not be handed out yet, or `nil` when it may.
    ///
    /// The dispatch point sees raw coordinator rows rather than board tasks, so
    /// it asks with the dependency ids it has. Same rules, one implementation —
    /// a gate that disagrees with what the board displays is worse than no gate.
    static func blockingReason(
        dependsOn: [String], in tasks: [ReviewBoardTask]
    ) -> String? {
        guard !dependsOn.isEmpty else { return nil }
        let byID = Dictionary(tasks.map { ($0.rawID, $0) }, uniquingKeysWith: { first, _ in first })
        var pending: [String] = []
        for dependencyID in dependsOn {
            guard let dependency = byID[dependencyID] else {
                return "depends on \(dependencyID), which is not on this board"
            }
            if landedStatuses.contains(dependency.status) { continue }
            if deadEndStatuses.contains(dependency.status) {
                return "\(dependency.title) is \(dependency.status)"
            }
            pending.append(dependency.title)
        }
        guard pending.isEmpty else {
            return pending.count == 1
                ? "waiting on \(pending[0])"
                : "waiting on \(pending.count) tasks"
        }
        return nil
    }

    /// A loop leaves every task in it waiting on the others forever, and the
    /// board would show nothing but "waiting on" with no way in. Reported as
    /// needing a person, because breaking it means editing the graph.
    private static func cycleReason(
        from start: ReviewBoardTask, in byID: [String: ReviewBoardTask]
    ) -> String? {
        var seen: Set<String> = [start.rawID]
        var frontier = start.dependsOn
        while let next = frontier.popLast() {
            if next == start.rawID {
                return "This task's dependencies loop back to it; the graph needs editing."
            }
            guard seen.insert(next).inserted, let task = byID[next] else { continue }
            frontier.append(contentsOf: task.dependsOn)
        }
        return nil
    }
}
