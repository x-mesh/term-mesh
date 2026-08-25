import CryptoKit
import Foundation

enum ProjectDelegationLevel: String, CaseIterable, Codable, Sendable {
    case leaderFirst
    case guarded
    case delegated

    var displayName: String {
        switch self {
        case .leaderFirst: return "Leader first"
        case .guarded: return "Guarded"
        case .delegated: return "Delegated"
        }
    }

    var detail: String {
        switch self {
        case .leaderFirst:
            return "The leader handles serial work and delegates only independent parallel units."
        case .guarded:
            return "Serial work stays with the leader; risk conditions add one read-only probe."
        case .delegated:
            return "Serial implementation goes to one worker; independent units still run in parallel."
        }
    }
}

struct ProjectDelegationState: Codable, Equatable, Sendable {
    var configured: ProjectDelegationLevel
    var effective: ProjectDelegationLevel
    var pending: ProjectDelegationLevel?

    static let `default` = Self(
        configured: .leaderFirst, effective: .leaderFirst, pending: nil
    )

    init(
        configured: ProjectDelegationLevel = .leaderFirst,
        effective: ProjectDelegationLevel = .leaderFirst,
        pending: ProjectDelegationLevel? = nil
    ) {
        self.configured = configured
        self.effective = effective
        self.pending = pending
    }

    init(
        configuredRaw: String?, effectiveRaw: String?, pendingRaw: String?
    ) {
        let configured = ProjectDelegationLevel(rawValue: configuredRaw ?? "") ?? .leaderFirst
        self.configured = configured
        self.effective = ProjectDelegationLevel(rawValue: effectiveRaw ?? "") ?? configured
        self.pending = ProjectDelegationLevel(rawValue: pendingRaw ?? "")
    }
}

enum ProjectTaskShape: String, CaseIterable, Codable, Sendable {
    case singleUnit = "single_unit"
    case multiUnit = "multi_unit"
    case crossSubsystem = "cross_subsystem"
    case parallelizable

    var supportsParallelWave: Bool { self != .singleUnit }
}

enum ProjectRoutingRisk: String, CaseIterable, Codable, Sendable {
    case crossSubsystem = "cross_subsystem"
    case protocolOrPersistence = "protocol_or_persistence"
    case irreversibleOrRelease = "irreversible_or_release"
    case unverifiedCoreAssumption = "unverified_core_assumption"
    case repeatedFailure = "repeated_failure"
}

enum ProjectRoutingRoute: String, Codable, Sendable {
    case direct
    case probe
    case delegated
    case parallel
}

struct ProjectRoutingDecision: Codable, Equatable, Sendable {
    let route: ProjectRoutingRoute
    let reasons: [String]
    let workerCount: Int

    static func decide(
        level: ProjectDelegationLevel,
        taskShape: ProjectTaskShape,
        risks: Set<ProjectRoutingRisk>,
        availableWorkers: Int
    ) -> Self {
        let workers = max(0, availableWorkers)
        guard workers > 0 else {
            return Self(route: .direct, reasons: ["no_available_workers"], workerCount: 0)
        }
        if taskShape.supportsParallelWave, workers >= 2 {
            return Self(
                route: .parallel, reasons: ["parallel_ready"],
                workerCount: min(3, workers)
            )
        }
        switch level {
        case .leaderFirst:
            return Self(
                route: .direct,
                reasons: [taskShape.supportsParallelWave ? "limited_capacity" : "leader_first"],
                workerCount: 0
            )
        case .guarded:
            guard !risks.isEmpty else {
                return Self(route: .direct, reasons: ["guard_not_required"], workerCount: 0)
            }
            return Self(
                route: .probe, reasons: risks.map(\.rawValue).sorted(), workerCount: 1
            )
        case .delegated:
            return Self(route: .delegated, reasons: ["delegated_serial_work"], workerCount: 1)
        }
    }
}

/// The one policy source for leader routing. Every local or peer leader prompt
/// renderer consumes `renderedInstructions`; no renderer owns a fork of these
/// scheduling rules.
enum LeaderParallelPolicy {
    static let version = "12"
    static let activation = "request-boundary-enforced"

    /// Ordered rules are both the canonical policy and the digest input.  Do
    /// not reorder them: a changed order is a policy change and must produce a
    /// new digest for diagnostics and launch parity checks.
    static let rules: [(id: String, text: String)] = [
        (
            "team-aware-decomposition-default",
            "When the Project roster has available workers, start each non-trivial request by decomposing it into independently completable units and assign eligible units before doing that work in the leader lane. Prefer a two- or three-worker parallel wave whenever at least two units are dependency-ready, independently verifiable, and ownership-disjoint. The leader owns coordination, integration, and any distinct unowned lane. Direct execution is the explicit exception for trivial, same-file, dependency-serial, or worker-ineligible work; record a concise reason. Never manufacture work solely to occupy an idle worker."
        ),
        (
            "parallel-admission-gate",
            "Admit a parallel wave when there are at least two dependency-ready subtasks that are independently verifiable, have disjoint file or subsystem ownership, and are large enough that dispatch and integration do not clearly dominate the work. Record this positive evidence when delegating. When choosing direct or probe despite an available roster, record the concrete constraint that prevented a useful parallel split."
        ),
        (
            "structured-routing-decision",
            "Classify execution as direct, probe, or parallel before dispatch. Direct has no worker tasks. Probe has exactly one read-only task with a 60-90 second budget. Parallel has two or three dependency-ready tasks. Every worker task names its worker, goal, owned and forbidden paths, dependencies, verification command, mutation flag, and time estimate."
        ),
        (
            "turn-route-measurement",
            "For every supported leader turn, before dispatch or direct implementation, submit exactly one classification with `tm-agent leader turn route --route <direct|probe|parallel> --task-shape <single_unit|multi_unit|cross_subsystem|parallelizable> --available-workers <count>` and repeat `--risk-reason <reason>` for each risk; add `--wave-id <id>` only when a wave exists. Read the JSON result. A non-null `directive` is an observable tm-agent dispatch contract for an explicitly opted-in healthy canary; follow its route and dispatch_bounds. A null directive leaves the static policy unchanged. This contract does not intercept or enforce arbitrary file edits, shell commands, or other leader tool calls. Route omission remains observable and non-blocking."
        ),
        (
            "dag-readiness",
            "Model dependencies as a DAG. Dispatch only ready tasks whose prerequisites completed. A failed or blocked prerequisite never releases a dependent task; replan, retry, or skip explicitly."
        ),
        (
            "unified-placement-pool",
            "Evaluate local and peer workers in one eligibility and ranking pool. Use host, transport, health, checkout identity, capability, and locality as placement metadata, not as separate manual queues."
        ),
        (
            "same-checkout-isolation",
            "Allow concurrent read-only work in one checkout. For concurrent writes, give every task explicit owned and forbidden paths and use task-scoped tm-agent delegate --worktree always --from <base> unless the writes are provably disjoint in the same checkout; if isolation is unavailable, block or run sequentially rather than silently sharing a checkout."
        ),
        (
            "bounded-handoff",
            "Use one dispatch, one independent work interval, and one result collection per parallel wave. Worker-to-worker communication is for blockers or ownership expansion only; avoid turn-by-turn ping-pong. The leader reviews and integrates completed worktrees serially, validating after each merge boundary and once across the integrated result."
        ),
        (
            "leader-integration-lane",
            "After dispatch, the leader remains active: prepare acceptance checks, inspect only unowned paths, stage integration order, and review completed evidence. Never edit a worker-owned path concurrently. Wait for named task IDs with tm-agent wait --mode any --tasks, process the first completed result, and perform at most one additional wait/collect for results still required to finish."
        ),
        (
            "actual-diff-review-gate",
            "For implementation requests, do not occupy validation roles in the implementation wave by default. After the actual diff is integrated, derive validation gates from changed behavior and trust boundaries: behavior or API regressions use tester; concurrency, persistence, protocol, cross-subsystem, or agent-prompt changes use reviewer; sockets, permissions, auth, shell execution, or external input use security plus tester; release-critical changes use tester plus reviewer. Small local diffs receive leader review and final verification directly. Dispatch at most two read-only validators in one wave. Give each validator one risk question, at most three primary files, and a 90-second target; split or let the leader cover broader diffs instead of duplicating a full review."
        ),
        (
            "review-only-fast-path",
            "For an explicit review-only request against an existing diff, do not complete a full leader review before dispatch. Perform bounded manifest-level triage only: freeze the target commit or diff, inspect changed paths and test locations, and identify separable risk lenses. When two independent trust boundaries exist, immediately dispatch up to two read-only validators against that same frozen target while the leader concurrently reviews the end-to-end contract and runs independent verification. Initial validator capsules contain a fixed lens and invariants rather than leader-discovered suspicions, preserving independent discovery. Do not enter tm-agent wait while useful leader-lane work remains; collect once after that work, and allow at most one targeted follow-up only for conflicting or insufficient evidence. Small single-domain reviews stay leader-direct."
        ),
        (
            "cross-model-validation",
            "For each validation gate, prefer a roster member whose CLI/provider differs from every implementation owner; otherwise prefer a different model, then an independent validation role. Route with agent_instance_id. If no independent provider or model exists, continue with the best role match and record cross_model_independence_unavailable instead of pretending cross-model review occurred."
        ),
        (
            "no-progress-recovery",
            "At a soft deadline, inspect the named task and one bounded transcript tail. Never reassign while the original worker is still running. If explicit recovery is necessary, preserve its task worktree, stop that worker with the supported restart path, then reassign once; otherwise converge on completed evidence at the hard deadline. The current CLI has no task-cancel primitive, so never claim cancellation unless a stop actually succeeded."
        ),
        (
            "branch-merge-boundary",
            "Do not create an extra worktree merely because checkouts differ. Give each write task a branch owner and serialize pushes to the same remote branch; make merge and push boundaries explicit."
        ),
        (
            "isolated-checkout-ref-contract",
            "An isolated worker branch is expected to differ from the project target branch. Never require branch-name equality and never block for that difference alone. For read-only work, fetch once when needed and inspect explicit base/target refs without checkout, reset, merge, or rebase. For write work, keep the assigned branch and request an explicit sync when its base is stale. A branch behind the target is equally expected; do not block on that alone, and treat a leader-directed base sync as the action to perform, not a precondition to verify with an ancestor or inclusion check."
        ),
        (
            "policy-parity",
            "Every local and peer leader renderer must expose this policy version and digest. If policy injection cannot be verified, report degraded or failed policy state instead of silently using an older policy."
        ),
        (
            "timebox-convergence",
            "Each parallel wave has configurable soft and hard deadlines. At the soft deadline report partial evidence and missing tasks. At the hard deadline converge only on completed evidence and explicitly cancel, split, or continue unfinished tasks; a timeout is never success."
        ),
        (
            "external-event-wait",
            "Events outside the team bus (CI runs, deploys, remote builds) cannot be awaited with team wait primitives. Before watching one, verify that the watched resource exists; absence after its explicit discovery window is a terminal finding to report, not a retry loop. Never start an unbounded watch or end a turn silently waiting on an external event. Either poll with an explicit attempt cap and report state plus the next action at the cap, or delegate a bounded watch to a worker whose deadline is shorter than the leader's tm-agent wait timeout and whose reply covers success, failure, absence, and timeout. If the leader wait expires first, report partial state; do not claim that the ended turn will resume automatically."
        ),
    ]

    static var canonicalSource: String {
        (["version=\(version)", "activation=\(activation)"]
            + rules.map { "\($0.id)=\($0.text)" })
            .joined(separator: "\n")
    }

    /// Lowercase SHA-256 of the canonical source, stable across launch paths.
    static var digest: String {
        SHA256.hash(data: Data(canonicalSource.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The only policy payload leader prompt renderers may inject. Keeping the
    /// activation state in-band makes launch parity observable to the leader.
    static var renderedInstructions: String {
        let renderedRules = rules.map { "- [\($0.id)] \($0.text)" }
            .joined(separator: "\n")
        return """
        ## Leader Adaptive Execution Policy
        policy_version: \(version)
        policy_digest: \(digest)
        policy_activation: \(activation)

        This policy is active. Treat these rules as the execution and scheduling contract for local and peer workers; report a degraded policy state rather than silently bypassing them.

        Before dispatch, form this machine-readable decision internally and retain it in the task/run log when that surface is available:
        ```json
        {
          "route": "direct|probe|parallel",
          "reason": "positive evidence for parallel work, or the concrete constraint requiring direct or probe",
          "tasks": [
            {
              "id": "stable-task-id",
              "worker": "project worker name",
              "goal": "self-contained outcome",
              "owned": ["path or subsystem"],
              "forbidden": ["path or subsystem"],
              "depends_on": [],
              "verify": "one concrete command",
              "mutates": true,
              "estimated_seconds": 300
            }
          ],
          "validation_gates": [
            {
              "role": "reviewer|tester|security",
              "reason": "risk evidence from the integrated diff",
              "preferred_provider": "different-from-implementer|any",
              "read_only": true,
              "owned": ["integrated diff or verification scope"],
              "verify": "one concrete command"
            }
          ]
        }
        ```
        Route invariants: direct has zero implementation tasks; probe has exactly one read-only implementation task (`mutates=false`) estimated at 60-90 seconds; parallel has two or three implementation tasks whose `depends_on` prerequisites are already satisfied. For implementation requests, `validation_gates` are a later wave derived from the integrated diff, never speculative implementation capacity. For explicit review-only requests, `review-only-fast-path` may start validators after bounded manifest triage against one frozen target while the leader works concurrently. Dispatch at most two gates once, collect once, and keep every gate read-only. A validator capsule covers one risk question and at most three primary files with a 90-second target. Require the normal final 5-field reply; `review_ready` without that final reply is partial evidence, not completion.

        \(renderedRules)
        """
    }

    /// The sole first-turn/file-read directive used by CLIs without a native
    /// system-prompt flag. Keeping the version and digest here lets every
    /// renderer prove that it consumed this policy source rather than a copy.
    static func launchDirective(promptFile: String) -> String {
        "Read \(promptFile) before doing any work. It contains your team-leader instructions and the canonical Leader Adaptive Execution Policy (version \(version), digest \(digest)). Follow it for all team coordination."
    }
}
