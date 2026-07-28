import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class AutoPilotPolicyTests: XCTestCase {
    private func policy(
        enabled: Bool = true,
        ceiling: String = "develop",
        budget: Int = 10
    ) -> AutoPilotPolicy {
        AutoPilotPolicy(
            isEnabled: enabled,
            ceilingBranch: ceiling,
            protectedBranches: AutoPilotPolicy.defaultProtectedBranches,
            maxAutoMerges: budget
        )
    }

    private func candidate(
        target: String = "develop",
        head: String = "abc1234567890",
        evidence: AutoPilotCheckEvidence? = nil,
        wouldPush: Bool = false,
        merges: Int = 0
    ) -> AutoPilotCandidate {
        AutoPilotCandidate(
            taskID: "tsk_1",
            targetBranch: target,
            headSHA: head,
            checkEvidence: evidence ?? AutoPilotCheckEvidence(
                command: "xcodebuild test",
                passed: true,
                headSHA: head,
                recordedAtMS: 1_784_882_974_390
            ),
            wouldPush: wouldPush,
            autoMergesSoFar: merges
        )
    }

    func testAPassingCheckOnTheSameHeadMergesIntoTheCeiling() {
        XCTAssertEqual(policy().evaluate(candidate()), .proceed)
    }

    /// The case the evidence type exists for: an agent verified, then committed
    /// once more. `passed` is still true and means nothing about what would
    /// merge.
    func testACheckThatRanAgainstAnEarlierCommitIsNotEvidence() {
        let stale = AutoPilotCheckEvidence(
            command: "xcodebuild test",
            passed: true,
            headSHA: "0000000feedface",
            recordedAtMS: 1_784_882_974_390
        )
        let decision = policy().evaluate(candidate(head: "abc1234567890", evidence: stale))

        XCTAssertFalse(decision.isProceed)
        let reason = decision.reason ?? ""
        XCTAssertTrue(reason.contains("0000000f"), reason)
        XCTAssertTrue(reason.contains("abc12345"), reason)
    }

    /// Typing `main` into the ceiling field must not arm merges into it. The
    /// protected check therefore cannot be the one that reads `ceilingBranch`.
    func testAProtectedBranchIsRefusedEvenWhenItIsTheConfiguredCeiling() {
        for branch in ["main", "master", "trunk"] {
            let decision = policy(ceiling: branch).evaluate(candidate(target: branch))
            XCTAssertFalse(decision.isProceed, branch)
            XCTAssertEqual(decision.reason, "\(branch) is never merged automatically.")
        }
    }

    func testATaskTargetingSomethingOtherThanTheCeilingIsHandedBack() {
        let decision = policy().evaluate(candidate(target: "feat/other"))
        XCTAssertEqual(
            decision.reason,
            "Auto pilot merges into develop; this task targets feat/other."
        )
    }

    /// Local merges are undone with `git reset`. A pushed one is undone by
    /// asking everybody who pulled.
    func testAMergeThatWouldLeaveTheMachineIsRefused() {
        let decision = policy().evaluate(candidate(wouldPush: true))
        XCTAssertFalse(decision.isProceed)
        XCTAssertTrue(decision.reason?.contains("does not push") == true)
    }

    func testTheBudgetStopsARunawayBoard() {
        XCTAssertEqual(policy(budget: 3).evaluate(candidate(merges: 2)), .proceed)
        let spent = policy(budget: 3).evaluate(candidate(merges: 3))
        XCTAssertFalse(spent.isProceed)
        XCTAssertTrue(spent.reason?.contains("limit 3") == true, spent.reason ?? "")
    }

    func testNoEvidenceAndFailedEvidenceReadDifferently() {
        let none = policy().evaluate(
            AutoPilotCandidate(
                taskID: "t", targetBranch: "develop", headSHA: "abc",
                checkEvidence: nil, wouldPush: false, autoMergesSoFar: 0
            )
        )
        XCTAssertEqual(none.reason, "Nothing has verified this task's build or tests.")

        let failed = policy().evaluate(candidate(evidence: AutoPilotCheckEvidence(
            command: "cargo test", passed: false,
            headSHA: "abc1234567890", recordedAtMS: 0
        )))
        XCTAssertEqual(failed.reason, "The last check failed: cargo test")
    }

    func testAnOffPolicyAndAnUnrecordedTargetSayWhichItIs() {
        XCTAssertEqual(policy(enabled: false).evaluate(candidate()).reason, "Auto pilot is off.")
        XCTAssertEqual(
            policy().evaluate(candidate(target: "  ")).reason,
            "This task does not record where it would merge to."
        )
    }

    // MARK: - Settings round-trip

    func testAnEmptyOrMissingCeilingFallsBackRatherThanMergingIntoNothing() {
        let defaults = UserDefaults(suiteName: "autopilot.test.\(UUID().uuidString)")!
        XCTAssertEqual(AutoPilotPolicy.load(from: defaults).ceilingBranch, "develop")
        XCTAssertFalse(AutoPilotPolicy.load(from: defaults).isEnabled)

        defaults.set("   ", forKey: AutoPilotPolicy.ceilingBranchKey)
        XCTAssertEqual(AutoPilotPolicy.load(from: defaults).ceilingBranch, "develop")

        var saved = AutoPilotPolicy.default
        saved.isEnabled = true
        saved.ceilingBranch = "integration"
        saved.maxAutoMerges = 4
        saved.save(to: defaults)

        let loaded = AutoPilotPolicy.load(from: defaults)
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertEqual(loaded.ceilingBranch, "integration")
        XCTAssertEqual(loaded.maxAutoMerges, 4)
        // Protected branches are not user data — a saved policy cannot widen them.
        XCTAssertEqual(loaded.protectedBranches, AutoPilotPolicy.defaultProtectedBranches)
    }

    // MARK: - Undo

    func testTheUndoPointSurvivesARestartAndNamesTheCommandToRun() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-\(UUID().uuidString)/undo.json")
        let point = AutoPilotUndoPoint(
            branch: "develop",
            sha: "deadbeef1234",
            taskID: "tsk_1",
            repositoryPath: "/Users/me/some repo",
            recordedAtMS: 1_784_882_974_390
        )
        AutoPilotUndoLog(url: url).record(point)

        // A different instance: the app that most needs this has crashed.
        let reopened = AutoPilotUndoLog(url: url)
        XCTAssertEqual(reopened.latest(forTask: "tsk_1"), point)
        XCTAssertEqual(
            point.restoreCommand,
            "git -C '/Users/me/some repo' update-ref refs/heads/develop deadbeef1234"
        )
        XCTAssertNil(reopened.latest(forTask: "tsk_absent"))

        // Newest first, so "undo the last thing it did" reads off the front.
        var second = point
        second = AutoPilotUndoPoint(
            branch: "develop", sha: "cafe0000", taskID: "tsk_2",
            repositoryPath: "/Users/me/some repo", recordedAtMS: 1_784_882_999_999
        )
        reopened.record(second)
        XCTAssertEqual(AutoPilotUndoLog(url: url).points().map(\.taskID), ["tsk_2", "tsk_1"])
    }

    /// A path with a quote in it must not end the shell word.
    func testARepositoryPathCannotBreakOutOfTheRestoreCommand() {
        let point = AutoPilotUndoPoint(
            branch: "develop", sha: "abc", taskID: "t",
            repositoryPath: "/tmp/it's here; rm -rf /", recordedAtMS: 0
        )
        XCTAssertEqual(
            point.restoreCommand,
            "git -C '/tmp/it'\\''s here; rm -rf /' update-ref refs/heads/develop abc"
        )
    }
}
