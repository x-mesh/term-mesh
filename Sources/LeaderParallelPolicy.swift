import CryptoKit
import Foundation

/// The one policy source for leader routing. Every local or peer leader prompt
/// renderer consumes `renderedInstructions`; no renderer owns a fork of these
/// scheduling rules.
enum LeaderParallelPolicy {
    static let version = "1"
    static let activation = "runtime-enforced"

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

    /// The only policy payload leader prompt renderers may inject. Keeping the
    /// activation state in-band makes launch parity observable to the leader.
    static var renderedInstructions: String {
        let renderedRules = rules.map { "- [\($0.id)] \($0.text)" }
            .joined(separator: "\n")
        return """
        ## Leader Parallel Routing Policy
        policy_version: \(version)
        policy_digest: \(digest)
        policy_activation: \(activation)

        This policy is active. Treat these rules as the scheduling contract for local and peer workers; report a degraded policy state rather than silently bypassing them.

        \(renderedRules)
        """
    }

    /// The sole first-turn/file-read directive used by CLIs without a native
    /// system-prompt flag. Keeping the version and digest here lets every
    /// renderer prove that it consumed this policy source rather than a copy.
    static func launchDirective(promptFile: String) -> String {
        "Read \(promptFile) before doing any work. It contains your team-leader instructions and the canonical Leader Parallel Routing Policy (version \(version), digest \(digest)). Follow it for all team coordination."
    }
}
