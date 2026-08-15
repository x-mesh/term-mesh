import CryptoKit
import Foundation

/// The one policy source for leader routing. Every local or peer leader prompt
/// renderer consumes `renderedInstructions`; no renderer owns a fork of these
/// scheduling rules.
enum LeaderParallelPolicy {
    static let version = "9"
    static let activation = "runtime-enforced"

    /// Ordered rules are both the canonical policy and the digest input.  Do
    /// not reorder them: a changed order is a policy change and must produce a
    /// new digest for diagnostics and launch parity checks.
    static let rules: [(id: String, text: String)] = [
        (
            "adaptive-single-default",
            "Start each request with the leader as the default executor. The presence or idleness of workers is never by itself a reason to delegate, and small, same-file, or dependency-serial work stays with the leader."
        ),
        (
            "parallel-admission-gate",
            "Escalate to a parallel wave only when there are at least two dependency-ready subtasks that are independently verifiable, have disjoint file or subsystem ownership, and contain enough work to amortize dispatch, worktree, handoff, and merge cost. Record this positive evidence when delegating; do not require a justification for staying single."
        ),
        (
            "structured-routing-decision",
            "Classify execution as direct, probe, or parallel before dispatch. Direct has no worker tasks. Probe has exactly one read-only task with a 60-90 second budget. Parallel has two or three dependency-ready tasks. Every worker task names its worker, goal, owned and forbidden paths, dependencies, verification command, mutation flag, and time estimate."
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
          "reason": "positive evidence for escalation, or a short direct rationale",
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
