import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Creating a project across several machines is a filesystem transaction, and
/// 0.168 treated it as a sequence of independent errands: a machine that failed
/// left the machines before it set up, and pressing Create again named a whole
/// new set of checkouts beside the ones already there.
final class ProjectBootstrapTransactionRegression169Tests: XCTestCase {

    // MARK: - Undoing what a failed transaction already made

    /// The compensation reclaims exactly this transaction's worktrees and
    /// branches — the artifacts that carry its tag, which no other run can have
    /// written — and in reverse order.
    func testCleanupReclaimsThisTransactionsWorktreesAndBranches() throws {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/srv/work",
            projectName: "demo",
            agents: ["executor", "reviewer"],
            isolateAgents: true,
            instanceTag: "260730-a1b2"
        )

        let script = try XCTUnwrap(
            PeerProjectBootstrap.cleanupScript(for: plan, instanceTag: "260730-a1b2"))

        XCTAssertTrue(script.contains("worktree remove --force '/srv/work/demo-executor-260730-a1b2'"))
        XCTAssertTrue(script.contains("worktree remove --force '/srv/work/demo-reviewer-260730-a1b2'"))
        XCTAssertTrue(script.contains("branch -D 'agent/executor-260730-a1b2'"))
        XCTAssertTrue(script.contains("branch -D 'agent/reviewer-260730-a1b2'"))
        XCTAssertTrue(script.contains("worktree prune"))

        let executor = try XCTUnwrap(script.range(of: "demo-executor-260730-a1b2"))
        let reviewer = try XCTUnwrap(script.range(of: "demo-reviewer-260730-a1b2"))
        XCTAssertTrue(reviewer.lowerBound < executor.lowerBound,
                      "undone newest first, the way it was built")
    }

    /// The primary checkout is the one artifact that may have been there
    /// before this run. `script`'s own trap rolls it back when it is the step
    /// that fails; a cross-machine rollback must not guess.
    func testCleanupNeverRemovesThePrimaryCheckout() throws {
        let plan = PeerProjectBootstrap.plan(
            projectRoot: "/srv/work", projectName: "demo",
            agents: ["executor"], isolateAgents: true, instanceTag: "260730-a1b2")

        let script = try XCTUnwrap(
            PeerProjectBootstrap.cleanupScript(for: plan, instanceTag: "260730-a1b2"))

        XCTAssertFalse(script.contains("rm -rf -- '/srv/work/demo'"),
                       "a project folder that may predate this run is never deleted")
    }

    /// Nothing tagged, nothing owned: a plan whose checkouts this transaction
    /// did not name has no rollback at all, rather than one that reaches into
    /// somebody else's directories.
    func testCleanupRefusesUntaggedOrForeignPlans() {
        let untagged = PeerProjectBootstrap.plan(
            projectRoot: "/srv/work", projectName: "demo",
            agents: ["executor"], isolateAgents: true)
        XCTAssertNil(PeerProjectBootstrap.cleanupScript(for: untagged, instanceTag: "260730-a1b2"))

        let otherRun = PeerProjectBootstrap.plan(
            projectRoot: "/srv/work", projectName: "demo",
            agents: ["executor"], isolateAgents: true, instanceTag: "260730-ffff")
        XCTAssertNil(PeerProjectBootstrap.cleanupScript(for: otherRun, instanceTag: "260730-a1b2"),
                     "another transaction's checkouts are not this one's to remove")

        let shared = PeerProjectBootstrap.plan(
            projectRoot: "/srv/work", projectName: "demo",
            agents: ["executor"], isolateAgents: false, instanceTag: "260730-a1b2")
        XCTAssertNil(PeerProjectBootstrap.cleanupScript(for: shared, instanceTag: "260730-a1b2"),
                     "without isolation every agent is in the primary checkout")
    }

    // MARK: - A retry is the same transaction

    /// The orphan generator: `prepareCheckouts` minted a tag per *attempt*, so
    /// every retry named `demo-executor-<new tag>` while the previous
    /// directory and branch stayed behind with nothing that would adopt them.
    func testRetryingKeepsTheSameTagSoTheSameWorktreesAreReused() {
        let key = PeerProjectBootstrap.transactionKey(
            name: "demo", sourcePath: "/srv/work/demo")
        PeerProjectBootstrap.finishTransaction(key)
        defer { PeerProjectBootstrap.finishTransaction(key) }

        let first = PeerProjectBootstrap.instanceTag(forTransaction: key)
        let retry = PeerProjectBootstrap.instanceTag(forTransaction: key)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(
            PeerProjectBootstrap.plan(projectRoot: "/srv/work", projectName: "demo",
                                      agents: ["executor"], isolateAgents: true,
                                      instanceTag: first),
            PeerProjectBootstrap.plan(projectRoot: "/srv/work", projectName: "demo",
                                      agents: ["executor"], isolateAgents: true,
                                      instanceTag: retry),
            "a retry prepares the same paths, which the bootstrap script adopts"
        )
    }

    /// And a deliberate re-creation after success is a new transaction — the
    /// reason the tag is random in the first place is that a later project of
    /// the same name must not adopt this one's leftovers.
    func testANewCreationAfterSuccessGetsItsOwnTag() {
        let key = PeerProjectBootstrap.transactionKey(
            name: "demo", sourcePath: "/srv/work/demo")
        PeerProjectBootstrap.finishTransaction(key)
        defer { PeerProjectBootstrap.finishTransaction(key) }

        let first = PeerProjectBootstrap.instanceTag(forTransaction: key)
        PeerProjectBootstrap.finishTransaction(key)
        let second = PeerProjectBootstrap.instanceTag(forTransaction: key)

        XCTAssertNotEqual(first, second)
    }

    /// Two projects that merely share a name are two transactions.
    func testTransactionKeySeparatesProjectsBySourcePath() {
        XCTAssertNotEqual(
            PeerProjectBootstrap.transactionKey(name: "demo", sourcePath: "/srv/a/demo"),
            PeerProjectBootstrap.transactionKey(name: "demo", sourcePath: "/srv/b/demo")
        )
        XCTAssertEqual(
            PeerProjectBootstrap.transactionKey(name: " demo ", sourcePath: "/srv/a/demo/"),
            PeerProjectBootstrap.transactionKey(name: "demo", sourcePath: "/srv/a/demo")
        )
    }

    // MARK: - An existing folder is a promise about one machine

    /// With no repository URL, a non-source placement's whole preparation was
    /// `test -d <predicted path>`. Nothing copies the project and nothing
    /// checks that what is already there *is* the project, so a path that
    /// happens to exist starts agents in an unrelated directory.
    func testAnExistingFolderCannotBePlacedOnAnotherMachineWithoutARepository() {
        let source = PeerProjectBootstrap.Placement(
            hostKey: nil, projectPath: "/Users/x/work/demo",
            agentIndices: [0], includesLeader: true, isSource: true)
        let peer = PeerProjectBootstrap.Placement(
            hostKey: "ssh:root@builder", projectPath: "/srv/work/demo",
            agentIndices: [1], includesLeader: false, isSource: false)

        XCTAssertTrue(PeerProjectBootstrap.requiresRepositoryURL(
            placement: peer, sourceKind: .existingFolder, gitURL: ""))
        XCTAssertTrue(PeerProjectBootstrap.requiresRepositoryURL(
            placement: peer, sourceKind: .existingFolder, gitURL: "   "))

        // The machine the folder is actually on is exactly the one that needs
        // nothing: it already has the project.
        XCTAssertFalse(PeerProjectBootstrap.requiresRepositoryURL(
            placement: source, sourceKind: .existingFolder, gitURL: ""))
        // A URL is a way to reproduce it, so the placement becomes a clone.
        XCTAssertFalse(PeerProjectBootstrap.requiresRepositoryURL(
            placement: peer, sourceKind: .existingFolder,
            gitURL: "git@github.com:x/demo.git"))
        // A brand-new project has nothing to copy — each machine makes its own.
        XCTAssertFalse(PeerProjectBootstrap.requiresRepositoryURL(
            placement: peer, sourceKind: .empty, gitURL: ""))
    }

    /// The refusal has to say which machine, and what to do about it.
    func testTheRefusalNamesTheMachineAndTheWayOut() throws {
        let message = try XCTUnwrap(
            ProjectCreationFlow.CreationError
                .repositoryURLRequired(host: "jw-server", sourceHost: "This Mac")
                .errorDescription
        )

        XCTAssertTrue(message.contains("jw-server"))
        XCTAssertTrue(message.contains("This Mac"))
        XCTAssertTrue(message.contains("Repository URL"))
    }
}
