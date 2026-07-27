import CryptoKit
import Foundation

/// The one policy source for a future leader-routing gate.
///
/// This type deliberately has no callers yet.  The current leader prompts keep
/// their existing behavior until the instance-aware routing gate is complete.
/// Every local or peer leader renderer must consume `renderedInstructions`,
/// rather than copying any rule below, when that gate is enabled.
enum LeaderParallelPolicy {
    static let version = "1"
    static let activation = "routing-gate-pending"

    /// Ordered rules are both the canonical policy and the digest input.  Do
    /// not reorder them: a changed order is a policy change and must produce a
    /// new digest for diagnostics and launch parity checks.
    static let rules: [(id: String, text: String)] = [
        (
            "parallel-default",
            "For substantive requests, inspect team status, idle workers, placement, and checkout metadata before work. Decompose independent work into a parallel wave; record a reason when delegation is safely skipped."
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
            "Allow concurrent read-only work in one checkout. For concurrent writes in the same checkout, require clear disjoint ownership; otherwise use an isolated worktree or run sequentially."
        ),
        (
            "branch-merge-boundary",
            "Do not create an extra worktree merely because checkouts differ. Give each write task a branch owner and serialize pushes to the same remote branch; make merge and push boundaries explicit."
        ),
        (
            "policy-parity",
            "Every local and peer leader renderer must expose this policy version and digest. If policy injection cannot be verified, report degraded or failed policy state instead of silently using an older policy."
        ),
        (
            "timebox-convergence",
            "Each parallel wave has configurable soft and hard deadlines. At the soft deadline report partial evidence and missing tasks. At the hard deadline converge only on completed evidence and explicitly cancel, split, or continue unfinished tasks; a timeout is never success."
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

    /// The only policy payload a leader prompt renderer may inject once the
    /// routing gate is ready.  Keeping the activation state in-band makes an
    /// accidental early wiring visible rather than silently enabling it.
    static var renderedInstructions: String {
        let renderedRules = rules.map { "- [\($0.id)] \($0.text)" }
            .joined(separator: "\n")
        return """
        ## Leader Parallel Routing Policy
        policy_version: \(version)
        policy_digest: \(digest)
        policy_activation: \(activation)

        This policy is defined but inactive until the instance-aware routing gate passes. Do not claim that these rules are enforced by the scheduler yet.

        \(renderedRules)
        """
    }
}
