import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ReviewBoardViewModelTests: XCTestCase {
    func testDelegatedDetailAndHelpDescribeConditionalOverlap() {
        XCTAssertTrue(ProjectDelegationLevel.delegated.overlapExplanation?.contains("opt-in overlap canary") == true)
        XCTAssertTrue(ProjectDelegationLevel.delegated.helpText.contains("does not validate ownership automatically"))
        XCTAssertEqual(ProjectDelegationLevel.allCases.count, 3)
    }

    /// x-kit panel runs are part of what the board's snapshot reads, so a run
    /// arriving has to publish like every other change. Without this the board
    /// saw new runs only because its timer rebuilt the whole snapshot.
    @MainActor
    func testPanelRunIngestPublishesABoardChange() {
        let store = TeamDataStore.shared
        let before = store.taskRevision
        store.ingestXkPanelRun(payload: [
            "v": 1,
            "run": "probe-\(UUID().uuidString)",
            "source": "test",
            "model": "m1",
            "state": "running",
        ])
        let settled = expectation(description: "revision bump reaches the main queue")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertGreaterThan(store.taskRevision, before)
    }

    @MainActor
    func testActiveTasksByAssigneeUsesNewestNonterminalTaskAndKeepsTieOrder() {
        func task(
            _ id: String, assignee: String, status: String, updatedAt: Date
        ) -> TeamOrchestrator.TeamTask {
            TeamOrchestrator.TeamTask(
                id: id, title: id, details: nil, acceptanceCriteria: [], labels: [],
                estimatedSize: nil, assignee: assignee, status: status, priority: 2,
                dependsOn: [], parentTaskId: nil, childTaskIds: [],
                reassignmentCount: 0, createdBy: "leader", result: nil,
                createdAt: updatedAt, updatedAt: updatedAt
            )
        }

        let oldest = Date(timeIntervalSince1970: 10)
        let newest = Date(timeIntervalSince1970: 20)
        let active = TeamOrchestrator.activeTasksByAssignee(in: [
            task("terminal", assignee: "alex", status: "completed", updatedAt: newest),
            task("first-tie", assignee: "alex", status: "assigned", updatedAt: newest),
            task("second-tie", assignee: "alex", status: "in_progress", updatedAt: newest),
            task("older", assignee: "blair", status: "assigned", updatedAt: oldest),
            task("newer", assignee: "blair", status: "review_ready", updatedAt: newest),
        ])

        XCTAssertEqual(active["alex"]?.id, "first-tie")
        XCTAssertEqual(active["blair"]?.id, "newer")
    }

    @MainActor
    func testRemoteCollaborationPublishesOnlyForTheActiveTeam() {
        XCTAssertTrue(ReviewBoardViewModel.shouldPublishRemoteCollaboration(
            fetchedTeam: "aic", activeTeam: "aic"
        ))
        XCTAssertFalse(ReviewBoardViewModel.shouldPublishRemoteCollaboration(
            fetchedTeam: "aic", activeTeam: "other"
        ))
    }

    @MainActor
    func testCollaborationRepairOutcomeUsesTheVerifiedReportBit() {
        XCTAssertEqual(
            ReviewBoardViewModel.collaborationRepairOutcome(
                succeeded: true, message: "Leader control verified."
            ),
            .verified("Leader control verified.")
        )
        XCTAssertEqual(
            ReviewBoardViewModel.collaborationRepairOutcome(
                succeeded: false, message: "Leader control timed out."
            ),
            .failed("Leader control timed out.")
        )
    }

    @MainActor
    func testCollaborationRepairPublishesOnlyForTheTeamThatWasRepaired() {
        XCTAssertTrue(ReviewBoardViewModel.shouldPublishCollaborationRepair(
            repairedTeam: "aic", activeTeam: "aic"
        ))
        XCTAssertFalse(ReviewBoardViewModel.shouldPublishCollaborationRepair(
            repairedTeam: "aic", activeTeam: "other"
        ))
        XCTAssertFalse(ReviewBoardViewModel.shouldPublishCollaborationRepair(
            repairedTeam: "aic", activeTeam: nil
        ))
    }

    @MainActor
    func testCollaborationRepairStartsOnlyOnceForAnActiveTeam() {
        XCTAssertTrue(ReviewBoardViewModel.shouldStartCollaborationRepair(
            isRunning: false, teamName: "aic"
        ))
        XCTAssertFalse(ReviewBoardViewModel.shouldStartCollaborationRepair(
            isRunning: true, teamName: "aic"
        ))
        XCTAssertFalse(ReviewBoardViewModel.shouldStartCollaborationRepair(
            isRunning: false, teamName: nil
        ))
    }

    @MainActor
    func testCollaborationPanelsDistinguishMeasuredStates() {
        func panel(_ state: LeaderTurnLog.CollaborationState) -> ReviewBoardViewModel.CollaborationPanel {
            ReviewBoardViewModel.collaborationPanel(summary: .init(
                state: state, routeCount: 1, dispatchCount: state == .healthy ? 2 : 0,
                completionCount: state == .healthy ? 1 : 0, workerCount: 3,
                unmetFloorCount: state == .leaderOnly ? 1 : 0,
                lastActivity: "2026-09-02T00:00:00Z",
                legacyRecordCount: state == .unmeasured ? 1 : 0
            ))
        }

        XCTAssertEqual(panel(.healthy).title, "Latest evidence: dispatched")
        XCTAssertEqual(panel(.leaderOnly).title, "Latest evidence: no dispatch")
        XCTAssertEqual(panel(.identityMismatch).title, "Identity mismatch")
        XCTAssertEqual(panel(.routeFailure).title, "Latest evidence: route failure")
        XCTAssertEqual(panel(.unmeasured).title, "Collaboration unmeasured")
        XCTAssertEqual(panel(.healthy).dispatchCount, 2)
        XCTAssertNotEqual(panel(.healthy).symbolName, panel(.leaderOnly).symbolName)
    }

    /// The headline judges the newest record; the counts total the window.
    /// A Project whose newest turn delegated nothing still shows the earlier
    /// dispatches, and the two must not read as one contradictory claim.
    @MainActor
    func testCollaborationHeadlineNamesItsScopeWhenCountsDisagree() {
        let panel = ReviewBoardViewModel.collaborationPanel(summary: .init(
            state: .leaderOnly, routeCount: 6, dispatchCount: 4,
            completionCount: 5, workerCount: 4, unmetFloorCount: 1,
            lastActivity: "2026-09-02T03:02:00Z", legacyRecordCount: 0
        ))
        XCTAssertTrue(panel.title.hasPrefix("Latest evidence:"), panel.title)
        XCTAssertTrue(panel.detail.contains("newest record"), panel.detail)
        // The window totals survive a leader-only headline.
        XCTAssertEqual(panel.dispatchCount, 4)
        XCTAssertEqual(panel.completionCount, 5)
    }

    /// The folded header has to state the level, the roster and the newest
    /// verdict on one line, or collapsing the section hides the reason to
    /// open it.
    @MainActor
    func testCollaborationPanelCarriesAShortStateForTheFoldedHeader() {
        func short(_ state: LeaderTurnLog.CollaborationState) -> String {
            ReviewBoardViewModel.collaborationPanel(summary: .init(
                state: state, routeCount: 1, dispatchCount: 0, completionCount: 0,
                workerCount: 3, unmetFloorCount: 0, lastActivity: nil,
                legacyRecordCount: 0
            )).shortState
        }
        let all = LeaderTurnLog.CollaborationState.allCases.map(short)
        XCTAssertEqual(Set(all).count, all.count, "short states must stay distinguishable")
        for phrase in all {
            XCTAssertFalse(phrase.isEmpty)
            XCTAssertLessThanOrEqual(phrase.count, 20, phrase)
        }
        XCTAssertEqual(short(.leaderOnly), "no dispatch")
    }

    /// A daemon restart kills every worker after dispatches were recorded, so
    /// the turn-log verdict stays `healthy`; the dead presentation still needs
    /// the Repair button.
    @MainActor
    func testRepairFollowsDeadWorkerPresentationEvenWhenEvidenceIsHealthy() {
        func shows(
            _ state: LeaderTurnLog.CollaborationState, workers: Int, dead: Bool
        ) -> Bool {
            ReviewBoardViewModel.shouldShowCollaborationRepair(
                state: state, workerCount: workers, workerRepairNeeded: dead
            )
        }
        XCTAssertTrue(shows(.healthy, workers: 5, dead: true))
        XCTAssertFalse(shows(.healthy, workers: 5, dead: false))
        XCTAssertTrue(shows(.leaderOnly, workers: 5, dead: false))
        XCTAssertFalse(shows(.leaderOnly, workers: 0, dead: true), "no roster, nothing to repair")
    }

    /// Measured on a peer daemon restart: the leader relay ends together with
    /// both workers. With the leader invariant evaluated first the dead workers
    /// were never reported, so the board reads worker state with the leader
    /// treated as present.
    @MainActor
    func testDeadWorkersAreReportedWhenTheLeaderDiedWithThem() {
        let dead = [
            TeamOrchestrator.AgentPresentationProbe(
                instanceID: "executor", panelPresent: true, sessionReady: false
            ),
        ]
        let withLeader = TeamOrchestrator.collaborationPresentationState(
            teamExists: true, workspaceExists: true,
            leaderPanelExists: true, leaderSessionReady: false,
            agents: dead, requireLiveSessions: true
        )
        XCTAssertFalse(ReviewBoardViewModel.presentationNeedsWorkerRepair(withLeader))

        let ignoringLeader = TeamOrchestrator.collaborationPresentationState(
            teamExists: true, workspaceExists: true,
            leaderPanelExists: true, leaderSessionReady: true,
            agents: dead, requireLiveSessions: true
        )
        XCTAssertTrue(ReviewBoardViewModel.presentationNeedsWorkerRepair(ignoringLeader))
    }

    @MainActor
    func testOnlyWorkerPresentationStatesRequestRepair() {
        let expected: [(TeamOrchestrator.CollaborationPresentationState, Bool)] = [
            (.ready, false),
            (.teamMissing, false),
            (.workspaceMissing, false),
            (.leaderPanelMissing, false),
            (.leaderSessionUnavailable, false),
            (.agentPanelMissing("executor"), true),
            (.agentSessionUnavailable("executor"), true),
        ]
        for (state, needsRepair) in expected {
            XCTAssertEqual(
                ReviewBoardViewModel.presentationNeedsWorkerRepair(state), needsRepair, "\(state)"
            )
        }
    }

    // MARK: - Dispatch grouping

    private func groupTask(
        id: String, title: String, assignee: String, at iso: String,
        wave: String? = nil, status: String = "completed", team: String = "aic"
    ) -> ReviewBoardTask {
        ReviewBoardTask(
            id: id, teamName: team, title: title, status: status,
            assignee: assignee, isStale: false, updatedAt: iso, waveID: wave
        )
    }

    /// A stated wave is the whole answer: one card, every agent inside it.
    func testAStatedWaveGroupsEveryAgentIntoOneDispatch() {
        let tasks = [
            groupTask(id: "1", title: "Check the round trip", assignee: "executor",
                      at: "2026-09-02T03:02:00Z", wave: "wave-1"),
            groupTask(id: "2", title: "Check the round trip", assignee: "architect",
                      at: "2026-09-02T03:02:04Z", wave: "wave-1"),
            groupTask(id: "3", title: "Check the round trip", assignee: "reviewer",
                      at: "2026-09-02T03:02:09Z", wave: "wave-1"),
        ]
        let groups = ReviewBoardTask.grouped(tasks)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.map(\.assignee), ["executor", "architect", "reviewer"])
        XCTAssertFalse(groups[0].isDerived)
        XCTAssertEqual(groups[0].uniformStatus, "completed")
    }

    /// The live board this came from: three rows at 12:02 and one at 11:49,
    /// and the 12:02 rows do not all share an instruction. Grouping by title
    /// alone would merge the two 11:49/12:02 rows that do; grouping by clock
    /// alone would merge two different instructions. Neither is acceptable, so
    /// without a wave id both pieces of evidence have to agree.
    func testWithoutAWaveTheFallbackNeedsBothTheInstructionAndTheClock() {
        let tasks = [
            groupTask(id: "1", title: "Report only these three things",
                      assignee: "executor", at: "2026-09-02T03:02:00Z"),
            groupTask(id: "2", title: "Report only these three things",
                      assignee: "architect", at: "2026-09-02T03:02:03Z"),
            groupTask(id: "3", title: "Report only these three lines",
                      assignee: "reviewer", at: "2026-09-02T03:02:05Z"),
            groupTask(id: "4", title: "Report only these three lines",
                      assignee: "reviewer", at: "2026-09-02T02:49:00Z"),
        ]
        let groups = ReviewBoardTask.grouped(tasks)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].members.map(\.id), ["1", "2"])
        XCTAssertEqual(groups[1].members.map(\.id), ["3"])
        // 13 minutes later is a second ask, not a straggler of the first.
        XCTAssertEqual(groups[2].members.map(\.id), ["4"])
        XCTAssertTrue(groups.allSatisfy(\.isDerived))
    }

    /// A guess is labelled as one. "3 agents" means something different when
    /// the wave was stated than when it was inferred from prose and a clock.
    func testDerivedGroupsAreMarkedAndStatedOnesAreNot() {
        let derived = ReviewBoardTask.grouped([
            groupTask(id: "1", title: "Same ask", assignee: "a", at: "2026-09-02T03:02:00Z"),
            groupTask(id: "2", title: "Same ask", assignee: "b", at: "2026-09-02T03:02:01Z"),
        ])
        XCTAssertEqual(derived.count, 1)
        XCTAssertTrue(derived[0].isDerived)
        XCTAssertFalse(derived[0].isSingle)

        let stated = ReviewBoardTask.grouped([
            groupTask(id: "1", title: "Same ask", assignee: "a",
                      at: "2026-09-02T03:02:00Z", wave: "w"),
            groupTask(id: "2", title: "Same ask", assignee: "b",
                      at: "2026-09-02T03:02:01Z", wave: "w"),
        ])
        XCTAssertFalse(stated[0].isDerived)
    }

    /// Two Projects can run the same instruction at the same moment. The
    /// fallback must not put them in one card.
    func testTheFallbackNeverGroupsAcrossProjects() {
        let groups = ReviewBoardTask.grouped([
            groupTask(id: "1", title: "Same ask", assignee: "a",
                      at: "2026-09-02T03:02:00Z", team: "aic"),
            groupTask(id: "2", title: "Same ask", assignee: "b",
                      at: "2026-09-02T03:02:01Z", team: "other"),
        ])
        XCTAssertEqual(groups.count, 2)
    }

    /// A task with no clock has no evidence of belonging to a wave, so it
    /// stands alone rather than joining one on its title.
    func testATaskWithNoTimestampStandsAlone() {
        let groups = ReviewBoardTask.grouped([
            groupTask(id: "1", title: "Same ask", assignee: "a", at: "2026-09-02T03:02:00Z"),
            ReviewBoardTask(id: "2", teamName: "aic", title: "Same ask",
                            status: "completed", assignee: "b", isStale: false),
        ])
        XCTAssertEqual(groups.count, 2)
    }

    /// Grouping reports what the members are doing without deciding how the
    /// board words it, and a group is as urgent as its most urgent member.
    func testGroupRollupKeepsMixedStatusesAndTheStrongestPriority() {
        let tasks = [
            ReviewBoardTask(id: "1", teamName: "aic", title: "t", status: "completed",
                            assignee: "a", priority: 2, isStale: false,
                            updatedAt: "2026-09-02T03:02:00Z", waveID: "w"),
            ReviewBoardTask(id: "2", teamName: "aic", title: "t", status: "failed",
                            assignee: "b", priority: 0, isStale: false,
                            updatedAt: "2026-09-02T03:02:01Z", waveID: "w"),
            ReviewBoardTask(id: "3", teamName: "aic", title: "t", status: "completed",
                            assignee: "c", priority: 2, isStale: false,
                            updatedAt: "2026-09-02T03:02:02Z", waveID: "w"),
        ]
        let group = ReviewBoardTask.grouped(tasks)[0]
        XCTAssertNil(group.uniformStatus)
        XCTAssertEqual(group.statusCounts.map(\.status), ["completed", "failed"])
        XCTAssertEqual(group.statusCounts.map(\.count), [2, 1])
        XCTAssertEqual(group.priority, 0)
        XCTAssertEqual(group.updatedAt, "2026-09-02T03:02:02Z")
    }

    /// A long instruction must not be grouped on its clipped display copy.
    ///
    /// `title` is scrubbed and clipped to 120 characters, and delegated
    /// instructions open with a shared preamble, so two different asks agree
    /// for the first 119 characters and then differ. Grouping reads
    /// `rawTitle` for exactly this case.
    func testTwoLongInstructionsSharingAPrefixAreNotOneDispatch() {
        // Short words on purpose: a 32-character run of word characters is
        // rewritten to `<token>` by the scrubber before the clip, which would
        // make the two display titles differ for the wrong reason.
        let preamble = Array(repeating: "read only check and report", count: 6)
            .joined(separator: " ")
        func longTask(_ id: String, tail: String, at iso: String) -> ReviewBoardTask {
            ReviewBoardTask(
                id: id, teamName: "aic", title: preamble + " " + tail,
                status: "completed", assignee: id, isStale: false, updatedAt: iso
            )
        }
        let tasks = [
            longTask("1", tail: "look at branch A", at: "2026-09-02T03:02:00Z"),
            longTask("2", tail: "look at branch B", at: "2026-09-02T03:02:10Z"),
        ]
        // The clipped copies are identical, so grouping on `title` would merge.
        XCTAssertEqual(tasks[0].title, tasks[1].title)
        XCTAssertNotEqual(tasks[0].rawTitle, tasks[1].rawTitle)
        XCTAssertEqual(ReviewBoardTask.grouped(tasks).count, 2)
    }

    /// The window bounds a group's whole span, not the gap to its nearest
    /// member.
    ///
    /// Four arrivals 110 seconds apart used to chain into one group spanning
    /// 5m30s, because each new task only had to be near *some* member. The
    /// contract is now the span itself, so a repeated instruction can never
    /// present minutes of separate asks as one dispatch.
    func testNoDerivedGroupSpansMoreThanTheWindow() {
        let window = ReviewBoardTask.derivedGroupWindow
        let stamps = [
            "2026-09-02T03:00:00Z", "2026-09-02T03:01:50Z",
            "2026-09-02T03:03:40Z", "2026-09-02T03:05:30Z",
        ]
        let tasks = stamps.enumerated().map { index, iso in
            groupTask(id: "\(index)", title: "Poll the host", assignee: "a", at: iso)
        }
        let groups = ReviewBoardTask.grouped(tasks)
        XCTAssertGreaterThan(groups.count, 1, "5m30s of arrivals is not one dispatch")
        for group in groups {
            let instants = group.members
                .compactMap { $0.updatedAt.flatMap(ReviewBoardText.date) }
            guard let first = instants.min(), let last = instants.max() else {
                return XCTFail("every member in this fixture has a timestamp")
            }
            XCTAssertLessThanOrEqual(last.timeIntervalSince(first), window)
        }
    }

    /// The same board data must produce the same cards however the view model
    /// sorted it, and it sorts by urgency rather than by time.
    func testGroupingIsIndependentOfInputOrder() {
        let stamps = [
            "2026-09-02T03:00:00Z", "2026-09-02T03:00:30Z",
            "2026-09-02T03:10:00Z", "2026-09-02T03:10:30Z",
        ]
        let tasks = stamps.enumerated().map { index, iso in
            groupTask(id: "\(index)", title: "Same ask", assignee: "a", at: iso)
        }
        let forward = ReviewBoardTask.grouped(tasks)
        let reversed = ReviewBoardTask.grouped(tasks.reversed())
        XCTAssertEqual(forward.count, 2)
        XCTAssertEqual(reversed.count, forward.count)
        XCTAssertEqual(
            Set(forward.map { Set($0.members.map(\.id)) }),
            Set(reversed.map { Set($0.members.map(\.id)) })
        )
    }

    /// The wave has to survive the producer, not just the model: both task
    /// serializers must keep emitting `wave_id`, and a coordinator row that
    /// carries none must not erase it on merge.
    func testWaveSurvivesTheProducerDictionaryAndTheCoordinatorMerge() {
        let decoded = ReviewBoardTask(dictionary: [
            "id": "t1", "title": "t", "team_name": "aic",
            "status": "completed", "wave_id": "wave-9",
        ])
        XCTAssertEqual(decoded?.waveID, "wave-9")

        let blank = ReviewBoardTask(dictionary: [
            "id": "t2", "title": "t", "team_name": "aic", "wave_id": "  ",
        ])
        XCTAssertNil(blank?.waveID, "a blank wave id groups nothing")

        let coordinator = ReviewBoardTask(
            id: "t1", teamName: "aic", title: "t", status: "placed", isStale: false
        )
        XCTAssertEqual(decoded?.merging(coordinator: coordinator).waveID, "wave-9")
    }

    @MainActor
    func testStatusBadgesCoverRequiredReviewStates() {
        let task = ReviewBoardTask(
            id: "1234567890abcdef",
            teamName: "ws",
            title: "Merge failed on fenced host",
            status: "failed",
            labels: ["fenced-zombie", "merge-failed"],
            isStale: true
        )
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [task],
            panelRuns: [],
            coordinatorOnline: false,
            memMeshAvailable: false,
            suspectHost: true,
            fencedZombie: true
        ))

        XCTAssertEqual(
            model.statusBadges(for: task),
            [.coordinatorOffline, .memMeshUnavailable, .suspectHost, .fencedZombie, .mergeFailed]
        )
    }

    /// A real queue entry replaces the guessing. The task below carries none
    /// of the hints the old path relied on — its status is not `failed` and
    /// it has no `merge-failed` label — so the badge can only come from the
    /// coordinator's own record.
    @MainActor
    func testMergeFailedBadgeComesFromTheQueueEntryNotTaskProse() throws {
        let task = ReviewBoardTask(
            id: "tsk_8d144b235ec342019a6d2bf39ef65296",
            teamName: "prj_819413b3",
            title: "Wire the merge queue",
            status: "queued_for_merge"
        )
        let entry = try XCTUnwrap(ReviewBoardMergeQueueItem(dictionary: [
            "queue_id": "mrq_2f1c4d5e6a7b8c9d0e1f2a3b4c5d6e7f",
            "task_id": "tsk_8d144b235ec342019a6d2bf39ef65296",
            "attempt_id": "att_9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d",
            "status": "failed",
            "approved_by": "reviewer",
            "approved_at_ms": 1_784_882_974_390,
            "last_error": "rebase conflict",
        ]))
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [task],
            panelRuns: [],
            mergeQueue: [entry],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertEqual(model.statusBadges(for: task), [.mergeFailed])
        XCTAssertEqual(model.pendingMergeQueue.map(\.id), [entry.id])
        XCTAssertEqual(model.taskTitle(forMergeQueueItem: entry), "Wire the merge queue")

        // The Merge Queue fact is the record, not a panel run or a keyword.
        let digest = model.digest(for: task)
        let mergeQueue = try XCTUnwrap(digest.mergeQueue)
        XCTAssertTrue(mergeQueue.contains("failed"), mergeQueue)
        XCTAssertTrue(mergeQueue.contains("reviewer"), mergeQueue)
        XCTAssertTrue(mergeQueue.contains("rebase conflict"), mergeQueue)

        // And it is the only thing known, so it is the only row drawn. Facts
        // with nothing to report used to render as "not reported" — eight of
        // them, burying the one line that had something to say.
        XCTAssertEqual(digest.presentFacts.map(\.title), ["Merge Queue"])
    }

    /// A task nobody has reported on yet draws no fact rows at all.
    @MainActor
    func testATaskWithNothingReportedHasNoFacts() {
        let task = ReviewBoardTask(
            id: "tsk_quiet",
            teamName: "x-backup",
            title: "이 저장소를 요약",
            status: "assigned"
        )
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [task],
            panelRuns: [],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertTrue(model.digest(for: task).presentFacts.isEmpty)
    }

    /// Merged and cancelled entries are history; the panel lists what still
    /// needs a person. Failures stay, because they need one most.
    @MainActor
    func testPendingMergeQueueDropsSettledEntriesButKeepsFailures() {
        func entry(_ queueID: String, _ status: String) -> ReviewBoardMergeQueueItem {
            ReviewBoardMergeQueueItem(dictionary: [
                "queue_id": queueID,
                "task_id": "tsk_\(queueID)",
                "status": status,
                "approved_by": "reviewer",
            ])!
        }
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [],
            panelRuns: [],
            mergeQueue: [
                entry("queued01", "queued"),
                entry("running1", "running"),
                entry("merged01", "merged"),
                entry("failed01", "failed"),
                entry("cancel01", "cancelled"),
            ],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertEqual(
            Set(model.pendingMergeQueue.map(\.taskRawID)),
            ["tsk_queued01", "tsk_running1", "tsk_failed01"]
        )
    }

    /// Without a queue entry the board still has to say something, and the
    /// old text-scanning path is what a locally-backed board falls back to.
    @MainActor
    func testWithoutAQueueEntryTheOldTaskProsePathStillApplies() {
        let task = ReviewBoardTask(
            id: "task-123",
            teamName: "ws",
            title: "Merge failed on host",
            status: "failed",
            labels: ["merge-failed"]
        )
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [task],
            panelRuns: [],
            mergeQueue: [],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertEqual(model.statusBadges(for: task), [.mergeFailed])
        // No entry and no panel run means nothing to say about the queue, and
        // nothing to say is now said by drawing no row rather than by a row
        // that says nothing.
        XCTAssertNil(model.digest(for: task).mergeQueue)
    }

    @MainActor
    func testReviewReadyAndBlockedTaskStates() {
        let blocked = ReviewBoardTask(id: "blocked", teamName: "ws", title: "Blocked", status: "blocked")
        let reviewReady = ReviewBoardTask(id: "ready", teamName: "ws", title: "Ready", status: "review_ready")
        let model = ReviewBoardViewModel(initialSnapshot: ReviewBoardSnapshot(
            tasks: [blocked, reviewReady],
            panelRuns: [],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        ))

        XCTAssertEqual(model.statusBadges(for: blocked), [.blocked])
        XCTAssertEqual(model.statusBadges(for: reviewReady), [.reviewReady])
    }

    @MainActor
    func testSnapshotRefreshPreservesValidSelectionAndDropsInvalidSelection() {
        let first = ReviewBoardTask(id: "first", teamName: "ws", title: "First", status: "queued")
        let second = ReviewBoardTask(id: "second", teamName: "ws", title: "Second", status: "review_ready")
        var snapshot = ReviewBoardSnapshot(
            tasks: [first, second],
            panelRuns: [],
            coordinatorOnline: true,
            memMeshAvailable: true,
            suspectHost: false,
            fencedZombie: false
        )
        let model = ReviewBoardViewModel(initialSnapshot: snapshot, selectedTaskID: "first") {
            snapshot
        }

        model.refresh()
        XCTAssertEqual(model.selectedTask?.id, "first")

        snapshot.tasks = [second]
        model.refresh()
        XCTAssertEqual(model.selectedTask?.id, "second")
    }

    func testTextRedactionHidesRawPathsAndTokens() {
        let text = ReviewBoardText.safeBody(
            "Report at /Users/jinwoo/work/project/term-mesh/Sources/App.swift token abcdefabcdefabcdefabcdefabcdefabcdef uuid 01234567-89ab-cdef-0123-456789abcdef"
        )

        XCTAssertFalse(text.contains("/Users/jinwoo"))
        XCTAssertFalse(text.contains("abcdefabcdefabcdefabcdefabcdefabcdef"))
        XCTAssertFalse(text.contains("01234567-89ab-cdef-0123-456789abcdef"))
        XCTAssertTrue(text.contains("…/App.swift"))
        XCTAssertTrue(text.contains("<token>"))
        XCTAssertTrue(text.contains("<uuid>"))
    }

    func testWidthPersistenceClampsBounds() {
        let defaults = UserDefaults(suiteName: "ReviewBoardViewModelTests.\(UUID().uuidString)")!
        ReviewBoardSettings.saveWidth(100, defaults: defaults)
        XCTAssertEqual(ReviewBoardSettings.loadWidth(defaults: defaults), ReviewBoardSettings.minimumWidth)

        ReviewBoardSettings.saveWidth(1_000, defaults: defaults)
        XCTAssertEqual(ReviewBoardSettings.loadWidth(defaults: defaults), ReviewBoardSettings.maximumWidth)
    }

    // MARK: - Approving from the board

    private func review(
        taskID: String = "tsk_1",
        approvable: Bool = true,
        blocker: String? = nil
    ) -> ReviewBoardReview {
        ReviewBoardReview(
            taskID: taskID,
            detail: ReviewBoardReviewDetail(
                status: approvable ? "review_ready" : "assigned",
                attemptID: approvable ? "att_1" : nil,
                fencingToken: approvable ? "fen_1" : nil,
                worktreePath: "/tmp/wt", hostID: nil, snapshot: nil,
                queueID: nil, queueStatus: nil, queueLastError: nil
            ),
            patch: ReviewBoardEvidence.Patch(
                baseSHA: "aaa", headSHA: "bbb", digest: "sha256:cafe",
                text: "diff", isTruncated: false,
                files: [.init(path: "a.swift", kind: "modified", add: 1, del: 0)]
            ),
            blocker: blocker
        )
    }

    private func task(_ id: String = "tsk_1", status: String = "review_ready") -> ReviewBoardTask {
        ReviewBoardTask(id: id, teamName: "ws", title: "Fix it", status: status)
    }

    /// The write path is injected the way the read path is, so a decision can
    /// be exercised without a coordinator socket.
    @MainActor
    func test_approving_calls_through_and_clears_what_was_read() async {
        var approved: [String] = []
        let model = ReviewBoardViewModel(
            initialSnapshot: ReviewBoardSnapshot(
                tasks: [task()], panelRuns: [], coordinatorOnline: true,
                memMeshAvailable: true, suspectHost: false, fencedZombie: false
            ),
            selectedTaskID: nil,
            snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in self.review() },
            approve: { approved.append($0.taskID) },
            reject: { _, _ in XCTFail("not this one") }
        ))

        await model.loadReview(for: task())
        XCTAssertEqual(model.review?.taskID, "tsk_1")
        XCTAssertTrue(model.review?.canAct == true)

        let landed = await model.approve()
        XCTAssertTrue(landed)
        XCTAssertEqual(approved, ["tsk_1"])
        // The task has moved on, so what was read no longer describes it —
        // leaving it would offer a second decision on a decided task.
        XCTAssertNil(model.review)
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.actionInFlight)
    }

    /// The coordinator's own words survive. `snapshot evidence mismatch` and
    /// `stale_fencing_token` are the two a reviewer has to tell apart, and
    /// "Approval failed" hides which happened.
    @MainActor
    func test_a_refusal_keeps_the_coordinators_wording_and_the_review() async {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in self.review() },
            approve: { _ in
                throw ReviewBoardCoordinatorError.jsonRPCError(
                    code: -32000, message: "snapshot evidence mismatch"
                )
            },
            reject: { _, _ in }
        ))

        await model.loadReview(for: task())
        let landed = await model.approve()

        XCTAssertFalse(landed)
        XCTAssertEqual(model.actionError, "snapshot evidence mismatch")
        XCTAssertNotNil(model.review, "a refused approval leaves the review to retry")
        XCTAssertFalse(model.actionInFlight)
    }

    /// A task the coordinator cannot act on still renders — with the reason.
    /// A board that just omits the buttons leaves the reader guessing whether
    /// the feature is missing or the task is.
    @MainActor
    func test_a_task_with_no_attempt_reports_why_rather_than_offering_a_button() async {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in
                self.review(approvable: false, blocker: "This task has no coordinator attempt")
            },
            approve: { _ in XCTFail("must not be reachable") },
            reject: { _, _ in }
        ))

        await model.loadReview(for: task())
        XCTAssertFalse(model.review?.canAct == true)
        XCTAssertEqual(model.review?.blocker, "This task has no coordinator attempt")

        // And acting anyway is refused by the model, not by the coordinator —
        // the reason shown is the one already read off the task.
        let landed = await model.approve()
        XCTAssertFalse(landed)
        XCTAssertEqual(model.actionError, "This task has no coordinator attempt")
        XCTAssertFalse(model.actionInFlight)
    }

    /// Reading a patch is a subprocess, not a property: the 2-second refresh
    /// tick must not re-run git for a task already in hand.
    @MainActor
    func test_a_task_already_read_is_not_read_again() async {
        var reads = 0
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in reads += 1; return self.review() },
            approve: { _ in }, reject: { _, _ in }
        ))

        await model.loadReview(for: task())
        await model.loadReview(for: task())
        XCTAssertEqual(reads, 1)

        await model.loadReview(for: task(), force: true)
        XCTAssertEqual(reads, 2, "an explicit re-read still works")

        // A different task is a different read.
        await model.loadReview(for: task("tsk_2"))
        XCTAssertEqual(reads, 3)
    }

    /// Rejecting needs a reason, and the model passes it through untouched —
    /// the client is what trims and refuses an empty one.
    @MainActor
    func test_rejecting_passes_the_reason_through() async {
        var sent: String?
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { _ in self.review() },
            approve: { _ in XCTFail("not this one") },
            reject: { _, reason in sent = reason }
        ))

        await model.loadReview(for: task())
        let landed = await model.reject(reason: "범위가 넘쳤다")

        XCTAssertTrue(landed)
        XCTAssertEqual(sent, "범위가 넘쳤다")
        XCTAssertNil(model.review)
    }

    /// The panel starts a read from `.task(id: task.rawID)`, which fires once
    /// per id. A read refused because another was still out therefore had
    /// nothing left to retrigger it, and the newly selected task sat with no
    /// review and no spinner until the selection moved twice.
    @MainActor
    func test_reading_another_task_supersedes_a_read_still_in_flight() async {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        var releaseFirst: CheckedContinuation<Void, Never>?
        model.setActions(ReviewBoardActions(
            review: { task in
                if task.rawID == "tsk_1" {
                    await withCheckedContinuation { releaseFirst = $0 }
                }
                return self.review(taskID: task.rawID)
            },
            approve: { _ in XCTFail("no decision here") },
            reject: { _, _ in XCTFail("no decision here") }
        ))

        async let firstRead: Void = model.loadReview(for: task("tsk_1"))
        // Let the first read reach its suspension point.
        for _ in 0..<1000 where releaseFirst == nil { await Task.yield() }
        XCTAssertNotNil(releaseFirst, "the first read should be parked at its continuation")

        // This is the whole point: it must not be refused.
        await model.loadReview(for: task("tsk_2"))
        XCTAssertEqual(model.review?.taskID, "tsk_2")

        releaseFirst?.resume()
        await firstRead
        XCTAssertEqual(
            model.review?.taskID, "tsk_2",
            "the superseded read must not land on top of the newer one"
        )
        XCTAssertFalse(model.actionInFlight)
    }

    /// What was read belongs to the task that was selected. Both the review and
    /// the "already read this one" marker go, or the next read is refused as
    /// redundant and the panel stays blank.
    @MainActor
    func test_selecting_a_different_task_drops_what_was_read() async {
        var reads = 0
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        model.setActions(ReviewBoardActions(
            review: { task in reads += 1; return self.review(taskID: task.rawID) },
            approve: { _ in }, reject: { _, _ in }
        ))

        await model.loadReview(for: task("tsk_1"))
        XCTAssertEqual(model.review?.taskID, "tsk_1")

        model.selectTask(id: "tsk_2")
        XCTAssertNil(model.review, "a stale review must not sit under a new header")

        // And coming back re-reads rather than being refused as already in hand.
        model.selectTask(id: "tsk_1")
        await model.loadReview(for: task("tsk_1"))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.review?.taskID, "tsk_1")
    }

    /// Nothing wired: the board says so instead of throwing an opaque error.
    @MainActor
    func test_an_unwired_board_reports_that_the_coordinator_is_off() async {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty }
        )
        await model.loadReview(for: task())
        XCTAssertFalse(model.review?.canAct == true)
        XCTAssertNotNil(model.review?.blocker)

        let landed = await model.approve()
        XCTAssertFalse(landed)
        XCTAssertEqual(model.actionError, model.review?.blocker)
    }


    // MARK: - Auto pilot from the board

    /// The toggle writes through to settings, because the runner reads the
    /// policy fresh on every sweep — a toggle that only moved a published
    /// property would look on and act off.
    @MainActor
    func test_the_toggle_writes_through_to_what_the_runner_reads() {
        let defaults = UserDefaults(suiteName: "board.autopilot.\(UUID().uuidString)")!
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil,
            snapshotProvider: { .empty }, defaults: defaults
        )

        XCTAssertFalse(model.autoPilot.isEnabled, "off until someone turns it on")

        model.setAutoPilotEnabled(true)
        XCTAssertTrue(model.autoPilot.isEnabled)
        XCTAssertTrue(AutoPilotPolicy.load(from: defaults).isEnabled)

        model.setAutoPilotCeiling("integration")
        XCTAssertEqual(AutoPilotPolicy.load(from: defaults).ceilingBranch, "integration")

        // An emptied field is a mistake, not a request to merge into nothing.
        model.setAutoPilotCeiling("   ")
        XCTAssertEqual(model.autoPilot.ceilingBranch, "develop")
        XCTAssertEqual(AutoPilotPolicy.load(from: defaults).ceilingBranch, "develop")
    }

    /// The board reads whatever the runner already wrote, so the log survives
    /// a restart — and holds are in it, since "why is this still sitting here"
    /// is the usual question.
    @MainActor
    func test_the_board_reads_back_what_auto_pilot_recorded() {
        let team = "ws-\(UUID().uuidString.prefix(8))"
        let audit = AutoPilotJournal<AutoPilotAudit>(teamName: team, kind: "audit")
        audit.record(AutoPilotAudit(
            taskID: "tsk_1", title: "Wire the queue", decision: "held",
            reason: "Nothing has verified this task's build or tests.",
            headSHA: "abc", checkCommand: nil, atMS: 1
        ))
        AutoPilotUndoLog(teamName: team).record(AutoPilotUndoPoint(
            branch: "develop", sha: "deadbeef", taskID: "tsk_1",
            repositoryPath: "/repo", recordedAtMS: 2
        ))
        defer {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".term-mesh/autopilot", isDirectory: true)
            try? FileManager.default.removeItem(at: base.appendingPathComponent("\(team)-audit.json"))
            try? FileManager.default.removeItem(at: base.appendingPathComponent("\(team)-undo.json"))
        }

        let snapshot = ReviewBoardSnapshot(
            tasks: [ReviewBoardTask(id: "tsk_1", teamName: team, title: "T", status: "review_ready")],
            panelRuns: [], coordinatorOnline: true, memMeshAvailable: true,
            suspectHost: false, fencedZombie: false
        )
        let model = ReviewBoardViewModel(
            initialSnapshot: snapshot, selectedTaskID: nil, snapshotProvider: { snapshot },
            defaults: UserDefaults(suiteName: "board.autopilot.\(UUID().uuidString)")!
        )
        model.reloadAutoPilotJournals()

        XCTAssertEqual(model.autoPilotAudit.count, 1)
        XCTAssertFalse(model.autoPilotAudit[0].wasApproved)
        XCTAssertEqual(model.autoPilotUndoPoints.map(\.sha), ["deadbeef"])
    }

    /// With no team there is no journal to read, and inventing one would show
    /// another project's decisions.
    @MainActor
    func test_an_empty_board_has_no_auto_pilot_history() {
        let model = ReviewBoardViewModel(
            initialSnapshot: .empty, selectedTaskID: nil, snapshotProvider: { .empty },
            defaults: UserDefaults(suiteName: "board.autopilot.\(UUID().uuidString)")!
        )
        model.reloadAutoPilotJournals()
        XCTAssertTrue(model.autoPilotAudit.isEmpty)
        XCTAssertTrue(model.autoPilotUndoPoints.isEmpty)
    }

    // MARK: - Overlap canary status

    /// `LanguageSettings.localized` negotiates the real macOS language when
    /// nothing overrides it, which would make an exact-string assertion
    /// depend on the host's System Settings. Forcing English through an
    /// isolated suite is deterministic because the app ships no `en.lproj`
    /// for its own source language — the catalog lookup always falls back to
    /// the key unchanged, regardless of the run host's locale.
    private func englishDefaults() -> UserDefaults {
        let suite = "overlap-canary-status.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(AppLanguage.english.rawValue, forKey: LanguageSettings.languageModeKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    func testOverlapCanaryStatusReasonOrderFollowsTheGateBeforeConsultingTheReading() {
        let english = englishDefaults()
        let ready = ReviewBoardViewModel.OverlapHealthReading.measured(
            supportedTurns: 500, observedDays: 8, coverage: 0.99, linkage: 0.99,
            unknownRate: 0.0, malformedLines: 0, passesGate: true, scope: .thisMac
        )

        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .leaderFirst, supportedLeader: true, killSwitch: false,
                reading: ready, defaults: english
            ).line,
            "Off · Work Distribution must be Delegated"
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .guarded, supportedLeader: true, killSwitch: false,
                reading: ready, defaults: english
            ).line,
            "Off · Work Distribution must be Delegated"
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: false, killSwitch: false,
                reading: ready, defaults: english
            ).line,
            "Off · Leader turns are not measured"
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: true,
                reading: ready, defaults: english
            ).line,
            "Off · All leader experiments are stopped"
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                mode: .off, reading: ready, defaults: english
            ).line,
            "Off · Leader Overlap is turned off"
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                mode: .shadow, reading: ready, defaults: english
            ).line,
            "Off · Leader Overlap is set to record only"
        )
        let checkingStatus = ReviewBoardViewModel.overlapCanaryStatus(
            level: .delegated, supportedLeader: true, killSwitch: false,
            reading: .checking, defaults: english
        )
        XCTAssertEqual(checkingStatus.line, "Checking · Measuring leader turn health")
        XCTAssertNil(checkingStatus.scopeCaption)

        let readyStatus = ReviewBoardViewModel.overlapCanaryStatus(
            level: .delegated, supportedLeader: true, killSwitch: false,
            reading: ready, defaults: english
        )
        XCTAssertEqual(
            readyStatus.line,
            "Ready · Applies to a turn only when the leader reports isolated, disjoint work"
        )
        XCTAssertEqual(readyStatus.scopeCaption, "Measured on this Mac across all Projects")
    }

    @MainActor
    func testOverlapCanaryStatusNotReportedAndUnavailableLines() {
        let english = englishDefaults()
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                reading: .notReported, defaults: english
            ).line,
            "Unknown · Remote does not report health"
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                reading: .unavailable("tm-agent not found on remote"), defaults: english
            ).line,
            "Unknown · Remote health unavailable: tm-agent not found on remote"
        )
    }

    /// The exact line the plan pins: the unmet volume part first, then the
    /// first failing ratio — coverage here — each against its own threshold.
    @MainActor
    func testOverlapCanaryStatusWaitingLineListsUnmetVolumeThenFirstFailingRatio() {
        let english = englishDefaults()
        let reading = ReviewBoardViewModel.OverlapHealthReading.measured(
            supportedTurns: 120, observedDays: 2, coverage: 0.93, linkage: 0.99,
            unknownRate: 0.0, malformedLines: 0, passesGate: false, scope: .thisMac
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                reading: reading, defaults: english
            ).line,
            "Waiting · 120/500 turns or 2/7 days · coverage 93% (needs 95%)"
        )
    }

    @MainActor
    func testOverlapCanaryStatusFloorRoundsPercentagesRatherThanRounding() {
        let english = englishDefaults()
        // Volume passes (500 supported turns) so only the failing ratio shows.
        // 0.9496 must print 94%, not round up to the passing 95% threshold.
        let reading = ReviewBoardViewModel.OverlapHealthReading.measured(
            supportedTurns: 500, observedDays: 8, coverage: 0.9496, linkage: 0.99,
            unknownRate: 0.0, malformedLines: 0, passesGate: false, scope: .thisMac
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                reading: reading, defaults: english
            ).line,
            "Waiting · coverage 94% (needs 95%)"
        )
    }

    /// The unknown rate is the one threshold stated as "or less", so flooring
    /// it contradicts the gate: 2.5% printed "2% (needs 2% or less)", a reason
    /// whose own numbers say it is already met.
    @MainActor
    func testOverlapCanaryStatusCeilsTheUnknownRateAgainstItsOrLessThreshold() {
        let english = englishDefaults()
        let reading = ReviewBoardViewModel.OverlapHealthReading.measured(
            supportedTurns: 500, observedDays: 8, coverage: 1, linkage: 1,
            unknownRate: 0.025, malformedLines: 0, passesGate: false, scope: .thisMac
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                reading: reading, defaults: english
            ).line,
            "Waiting · unknown routes 3% (needs 2% or less)"
        )
    }

    /// Malformed lines mean the count itself is suspect, so they outrank
    /// every ratio even when the volume and every ratio would otherwise pass.
    @MainActor
    func testOverlapCanaryStatusMalformedLinesOutrankEveryRatio() {
        let english = englishDefaults()
        let reading = ReviewBoardViewModel.OverlapHealthReading.measured(
            supportedTurns: 500, observedDays: 8, coverage: 1, linkage: 1,
            unknownRate: 0, malformedLines: 2, passesGate: false, scope: .thisMac
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                reading: reading, defaults: english
            ).line,
            "Waiting · 2 malformed log lines (needs 0)"
        )
    }

    /// A gate failure whose displayed parts all individually pass — a
    /// contradiction the formatter must never paper over by implying a reason
    /// that is not there.
    @MainActor
    func testOverlapCanaryStatusFallsBackWhenNoDisplayedPartFails() {
        let english = englishDefaults()
        let reading = ReviewBoardViewModel.OverlapHealthReading.measured(
            supportedTurns: 500, observedDays: 8, coverage: 1, linkage: 1,
            unknownRate: 0, malformedLines: 0, passesGate: false, scope: .thisMac
        )
        XCTAssertEqual(
            ReviewBoardViewModel.overlapCanaryStatus(
                level: .delegated, supportedLeader: true, killSwitch: false,
                reading: reading, defaults: english
            ).line,
            "Waiting · Health gate not passed"
        )
    }

    @MainActor
    func testOverlapCanaryStatusCaptionsNameTheScope() {
        let english = englishDefaults()
        let thisMac = ReviewBoardViewModel.overlapCanaryStatus(
            level: .delegated, supportedLeader: true, killSwitch: false,
            reading: .measured(
                supportedTurns: 500, observedDays: 8, coverage: 0.5, linkage: 0.99,
                unknownRate: 0, malformedLines: 0, passesGate: false, scope: .thisMac
            ),
            defaults: english
        )
        XCTAssertEqual(thisMac.scopeCaption, "Measured on this Mac across all Projects")

        let remote = ReviewBoardViewModel.overlapCanaryStatus(
            level: .delegated, supportedLeader: true, killSwitch: false,
            reading: .measured(
                supportedTurns: 500, observedDays: 8, coverage: 0.5, linkage: 0.99,
                unknownRate: 0, malformedLines: 0, passesGate: false, scope: .remoteProject("mac-sub")
            ),
            defaults: english
        )
        XCTAssertEqual(remote.scopeCaption, "Measured on mac-sub for this Project")
    }

    /// The checklist says what the single line cannot: how many conditions
    /// are left. Its verdict still comes from `overlapCanaryStatus`, so the
    /// headline and the rows can never disagree about whether it runs.
    @MainActor
    func testOverlapCanaryChecklistNamesEveryConditionAtOnce() {
        let english = englishDefaults()
        let ready = ReviewBoardViewModel.OverlapHealthReading.measured(
            supportedTurns: 500, observedDays: 8, coverage: 0.99, linkage: 0.99,
            unknownRate: 0, malformedLines: 0, passesGate: true, scope: .thisMac
        )

        let blocked = ReviewBoardViewModel.overlapCanaryChecklist(
            level: .leaderFirst, supportedLeader: false, killSwitch: true,
            mode: .shadow, reading: ready, defaults: english
        )
        XCTAssertEqual(blocked.headline, "Off · Work Distribution must be Delegated")
        XCTAssertEqual(
            blocked.items.map(\.label),
            ["Work Distribution", "Leader turn measurement", "Leader experiments",
             "Leader Participation", "Measurement"]
        )
        XCTAssertEqual(
            blocked.items.map(\.value),
            ["Leader first", "Not measured", "Stopped", "Record only", "Ready"]
        )
        XCTAssertEqual(
            blocked.items.map(\.state),
            [.blocked, .blocked, .blocked, .blocked, .met],
            "every unmet condition has to show, not just the first one"
        )

        let running = ReviewBoardViewModel.overlapCanaryChecklist(
            level: .delegated, supportedLeader: true, killSwitch: false,
            mode: .canary, reading: ready, defaults: english
        )
        XCTAssertTrue(running.headline.hasPrefix("Ready"))
        // The kill switch is debug-only now, so its row is present only while
        // something set it. A cleared switch drops the row instead of showing a
        // fourth "Running" line that no Settings control can explain.
        XCTAssertEqual(
            running.items.map(\.label),
            ["Work Distribution", "Leader turn measurement", "Leader Participation", "Measurement"]
        )
        XCTAssertEqual(running.items.map(\.state), [.met, .met, .met, .met])
        XCTAssertEqual(running.scopeCaption, "Measured on this Mac across all Projects")

        let waiting = ReviewBoardViewModel.overlapCanaryChecklist(
            level: .delegated, supportedLeader: true, killSwitch: false, mode: .canary,
            reading: .measured(
                supportedTurns: 120, observedDays: 2, coverage: 0.99, linkage: 0.99,
                unknownRate: 0, malformedLines: 0, passesGate: false, scope: .thisMac
            ),
            defaults: english
        )
        XCTAssertEqual(waiting.items.last?.value, "120/500 turns or 2/7 days")
        XCTAssertEqual(waiting.items.last?.state, .blocked)
    }

    /// Ready is never a second decision: it has to agree with the exact
    /// boolean `controlPayload` would carry for the corresponding scope,
    /// across every combination of the three "Off" inputs.
    @MainActor
    func testOverlapCanaryStatusReadyMatchesControlPayloadAcrossEveryGateCombination() {
        let english = englishDefaults()
        let passingHealth = LeaderParticipationSettings.Health(
            supportedTurns: 500, observedDays: 8, coverage: 0.99, linkage: 0.99, unknownRate: 0.0
        )
        let failingHealth = LeaderParticipationSettings.Health(
            supportedTurns: 0, observedDays: 0, coverage: 0, linkage: 0, unknownRate: 1
        )
        let settings = LeaderParticipationSettings.default

        for level in ProjectDelegationLevel.allCases {
            for supportedLeader in [true, false] {
                for killSwitch in [true, false] {
                    for health in [passingHealth, failingHealth] {
                        let delegationState = ProjectDelegationState(configured: level, effective: level)
                        var scopedSettings = settings
                        scopedSettings.killSwitch = killSwitch
                        // Overlap runs only in canary mode. The matrix below
                        // varies the other three inputs; `off` and `shadow` are
                        // pinned separately in the status-line test above.
                        scopedSettings.mode = .canary
                        let context = "level=\(level) supported=\(supportedLeader) " +
                            "kill=\(killSwitch) gatePasses=\(health.passesPromotionGate)"

                        let controlHostPayload = scopedSettings.controlPayload(
                            projectID: "p", sessionID: "s", supportedLeader: supportedLeader,
                            health: health, delegationState: delegationState, healthScope: .controlHost
                        )
                        let localReading = ReviewBoardViewModel.OverlapHealthReading.measured(
                            supportedTurns: health.supportedTurns, observedDays: health.observedDays,
                            coverage: health.coverage, linkage: health.linkage,
                            unknownRate: health.unknownRate, malformedLines: 0,
                            passesGate: health.passesPromotionGate, scope: .thisMac
                        )
                        let localReady = ReviewBoardViewModel.overlapCanaryStatus(
                            level: level, supportedLeader: supportedLeader, killSwitch: killSwitch,
                            mode: scopedSettings.mode, reading: localReading, defaults: english
                        ).line.hasPrefix("Ready")
                        XCTAssertEqual(
                            localReady, controlHostPayload["delegated_overlap_resolution"] as? Bool,
                            "local Ready must match controlHost resolution: \(context)"
                        )

                        let executionHostPayload = scopedSettings.controlPayload(
                            projectID: "p", sessionID: "s", supportedLeader: supportedLeader,
                            health: health, delegationState: delegationState, healthScope: .executionHost
                        )
                        let executionHostResolution =
                            executionHostPayload["delegated_overlap_resolution"] as? Bool ?? false
                        for remotePassesGate in [true, false] {
                            let peerReading = ReviewBoardViewModel.OverlapHealthReading.measured(
                                supportedTurns: 500, observedDays: 8, coverage: 0.99, linkage: 0.99,
                                unknownRate: 0.0, malformedLines: 0, passesGate: remotePassesGate,
                                scope: .remoteProject("mac-sub")
                            )
                            let peerReady = ReviewBoardViewModel.overlapCanaryStatus(
                                level: level, supportedLeader: supportedLeader, killSwitch: killSwitch,
                                mode: scopedSettings.mode, reading: peerReading, defaults: english
                            ).line.hasPrefix("Ready")
                            XCTAssertEqual(
                                peerReady, executionHostResolution && remotePassesGate,
                                "peer Ready must match executionHost resolution AND the remote gate: "
                                    + "\(context) remotePasses=\(remotePassesGate)"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Peer leader health over SSH

    @MainActor
    func testRemoteLeaderHealthScriptQuotesTheTMAgentAndProjectArguments() {
        let script = ReviewBoardViewModel.remoteLeaderHealthScript(tmAgent: "tm-agent", project: "a'b")
        let quotedAgent = TeamOrchestrator.shellQuoted("tm-agent")
        let quotedProject = TeamOrchestrator.shellQuoted("a'b")
        XCTAssertEqual(
            script,
            "out=$(\(quotedAgent) leader turn health --project \(quotedProject) --json 2>&1); "
                + "rc=$?; printf 'rc=%s\\n' \"$rc\"; printf '%s\\n' \"$out\""
        )
        XCTAssertTrue(script.contains("--project 'a'\\''b'"))
    }

    private func remoteHealthReportJSON(
        project: String = "p", supportedTurns: Int = 620, observedDays: Int = 9,
        coverage: Double = 0.99, linkage: Double = 0.97, unknownRate: Double = 0.01,
        malformedLines: Int = 0, passesPromotionGate: Bool = true
    ) -> String {
        """
        {
          "schema_version": 1,
          "project": "\(project)",
          "scope": "execution_host_project",
          "supported_turns": \(supportedTurns),
          "linked_turns": 600,
          "stated_turns": 610,
          "unstated_turns": 5,
          "observed_days": \(observedDays),
          "malformed_lines": \(malformedLines),
          "coverage": \(coverage),
          "linkage": \(linkage),
          "unknown_rate": \(unknownRate),
          "passes_promotion_gate": \(passesPromotionGate)
        }
        """
    }

    @MainActor
    func testParseRemoteLeaderHealthReportsAMeasuredReadingOnRcZero() {
        let output = "rc=0\n" + remoteHealthReportJSON()
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: output, project: "p", host: "mac-sub"),
            .measured(
                supportedTurns: 620, observedDays: 9, coverage: 0.99, linkage: 0.97,
                unknownRate: 0.01, malformedLines: 0, passesGate: true, scope: .remoteProject("mac-sub")
            )
        )
    }

    /// The exact stderr text clap prints on tm-agent 0.242.0 for an
    /// execution host that predates `leader turn health`, captured with
    /// `tm-agent leader turn bogus --project p --json` against the release
    /// binary (clap reports the same shape for any unrecognized subcommand).
    @MainActor
    func testParseRemoteLeaderHealthMapsTheExactOldTMAgentStderrTextToNotReported() {
        let output = "rc=2\n"
            + "error: unrecognized subcommand 'health'\n\n"
            + "Usage: tm-agent leader turn [OPTIONS] <COMMAND>\n\n"
            + "For more information, try '--help'.\n"
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: output, project: "p", host: "mac-sub"),
            .notReported
        )
    }

    /// rc 2 alone is not enough — only the exact clap message reads as "does
    /// not report health". Anything else at rc 2 falls to the generic line.
    @MainActor
    func testParseRemoteLeaderHealthMapsRcTwoWithoutTheClapMessageToGenericUnavailable() {
        let output = "rc=2\nsome other failure\n"
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: output, project: "p", host: "mac-sub"),
            .unavailable("remote tm-agent exited 2")
        )
    }

    @MainActor
    func testParseRemoteLeaderHealthMapsRc127ToTMAgentNotFound() {
        let output = "rc=127\n/bin/sh: tm-agent: command not found\n"
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: output, project: "p", host: "mac-sub"),
            .unavailable("tm-agent not found on remote")
        )
    }

    @MainActor
    func testParseRemoteLeaderHealthMapsAnyOtherRcToAGenericUnavailableReason() {
        let output = "rc=1\nsomething went wrong\n"
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: output, project: "p", host: "mac-sub"),
            .unavailable("remote tm-agent exited 1")
        )
    }

    @MainActor
    func testParseRemoteLeaderHealthMapsInvalidJSONToUnavailable() {
        let output = "rc=0\nnot json at all\n"
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: output, project: "p", host: "mac-sub"),
            .unavailable("invalid health response")
        )
    }

    @MainActor
    func testParseRemoteLeaderHealthMapsAnotherProjectsReportToUnavailable() {
        let output = "rc=0\n" + remoteHealthReportJSON(project: "other")
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: output, project: "p", host: "mac-sub"),
            .unavailable("invalid health response")
        )
    }

    @MainActor
    func testParseRemoteLeaderHealthMapsAMissingFieldToUnavailable() {
        // "coverage" is left out of an otherwise complete report.
        let json = """
        {
          "project": "p",
          "supported_turns": 620,
          "observed_days": 9,
          "malformed_lines": 0,
          "linkage": 0.97,
          "unknown_rate": 0.01,
          "passes_promotion_gate": true
        }
        """
        let output = "rc=0\n" + json
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: output, project: "p", host: "mac-sub"),
            .unavailable("invalid health response")
        )
    }

    @MainActor
    func testParseRemoteLeaderHealthMapsAMissingOrInvalidRcLineToInvalidResponse() {
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(output: "", project: "p", host: "mac-sub"),
            .unavailable("invalid response")
        )
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(
                output: remoteHealthReportJSON(), project: "p", host: "mac-sub"
            ),
            .unavailable("invalid response")
        )
        XCTAssertEqual(
            ReviewBoardViewModel.parseRemoteLeaderHealth(
                output: "rc=not-a-number\n{}", project: "p", host: "mac-sub"
            ),
            .unavailable("invalid response")
        )
    }

    @MainActor
    func testShouldFetchRemoteLeaderHealthWaits60SecondsAndIgnoresElapsedTimeWhileInFlight() {
        let lastAttempt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ReviewBoardViewModel.shouldFetchRemoteLeaderHealth(
            lastAttempt: lastAttempt, now: lastAttempt.addingTimeInterval(59), inFlight: false
        ))
        XCTAssertTrue(ReviewBoardViewModel.shouldFetchRemoteLeaderHealth(
            lastAttempt: lastAttempt, now: lastAttempt.addingTimeInterval(60), inFlight: false
        ))
        // A previous attempt's own failure never rewrites `lastAttempt`, so the
        // same 60 s rule keeps applying to the timestamp recorded when that
        // attempt started — this is only re-asserting the 59 s case against
        // that unchanged timestamp.
        XCTAssertFalse(ReviewBoardViewModel.shouldFetchRemoteLeaderHealth(
            lastAttempt: lastAttempt, now: lastAttempt.addingTimeInterval(59), inFlight: false
        ))
        XCTAssertFalse(ReviewBoardViewModel.shouldFetchRemoteLeaderHealth(
            lastAttempt: lastAttempt, now: lastAttempt.addingTimeInterval(3_600), inFlight: true
        ))
        XCTAssertTrue(ReviewBoardViewModel.shouldFetchRemoteLeaderHealth(
            lastAttempt: nil, now: Date(), inFlight: false
        ))
    }

    @MainActor
    func testOverlapCanaryStatusNotReportedAndUnavailableNeverReachReady() {
        let english = englishDefaults()
        let notReported = ReviewBoardViewModel.overlapCanaryStatus(
            level: .delegated, supportedLeader: true, killSwitch: false,
            reading: .notReported, defaults: english
        )
        XCTAssertFalse(notReported.line.hasPrefix("Ready"))
        let unavailable = ReviewBoardViewModel.overlapCanaryStatus(
            level: .delegated, supportedLeader: true, killSwitch: false,
            reading: .unavailable("remote tm-agent exited 1"), defaults: english
        )
        XCTAssertFalse(unavailable.line.hasPrefix("Ready"))
    }

    /// The peer reading alone decides Ready — this Mac's own turns.log never
    /// enters the picture, so a passing remote reading reaches Ready with a
    /// zero-turn local machine exactly as it would with a busy one.
    @MainActor
    func testOverlapCanaryStatusRemotePassingReadingReachesReadyRegardlessOfThisMacsTurns() {
        let english = englishDefaults()
        let reading = ReviewBoardViewModel.OverlapHealthReading.measured(
            supportedTurns: 500, observedDays: 8, coverage: 0.99, linkage: 0.99,
            unknownRate: 0.0, malformedLines: 0, passesGate: true, scope: .remoteProject("mac-sub")
        )
        let status = ReviewBoardViewModel.overlapCanaryStatus(
            level: .delegated, supportedLeader: true, killSwitch: false,
            reading: reading, defaults: english
        )
        XCTAssertTrue(status.line.hasPrefix("Ready"))
        XCTAssertEqual(status.scopeCaption, "Measured on mac-sub for this Project")
    }

}

final class ReviewBoardTaskMergeTests: XCTestCase {
    private func team(status: String, blockedReason: String? = nil) -> ReviewBoardTask {
        ReviewBoardTask(
            id: "c259ab1f",
            teamName: "x-backup",
            title: "이 저장소를 요약",
            status: status,
            assignee: "executor",
            blockedReason: blockedReason,
            updatedAt: "2026-07-24T13:00:00Z"
        )
    }

    private func coordinator(status: String, reason: String? = nil) -> ReviewBoardTask {
        ReviewBoardTask(
            id: "c259ab1f",
            teamName: "Unknown team",
            title: "이 저장소를 요약",
            status: status,
            assignee: "jw-server",
            blockedReason: reason,
            updatedAt: "2026-07-24T13:05:00Z"
        )
    }

    /// Execution is the team's to describe. The coordinator saying `placed`
    /// is what it knew before the agent had the work at all.
    func testExecutionStatusComesFromTheTeam() {
        let merged = team(status: "in_progress").merging(coordinator: coordinator(status: "placed"))
        XCTAssertEqual(merged.status, "in_progress")
    }

    /// Completion ends execution locally; the coordinator's review phase is
    /// the next state and must remain visible on the Review Board.
    func testCoordinatorReviewReadyAdvancesACompletedTeamTask() {
        let merged = team(status: "completed")
            .merging(coordinator: coordinator(status: "review_ready"))
        XCTAssertEqual(merged.status, "review_ready")
    }

    /// A stale coordinator update must not erase a local stop that still needs
    /// attention.
    func testCoordinatorReviewReadyDoesNotOverwriteALocalBlock() {
        let merged = team(status: "blocked", blockedReason: "build failed")
            .merging(coordinator: coordinator(status: "review_ready"))
        XCTAssertEqual(merged.status, "blocked")
        XCTAssertEqual(merged.blockedReason, "build failed")
    }

    /// Review and merge are phases the team vocabulary cannot express, so
    /// when the coordinator reports one it is saying something new.
    func testMergePhaseComesFromTheCoordinator() {
        for phase in ["queued_for_merge", "approved", "merged", "quarantined", "suspect"] {
            let merged = team(status: "completed").merging(coordinator: coordinator(status: phase))
            XCTAssertEqual(merged.status, phase, "\(phase) should win over a team status")
        }
    }

    /// Facts either side holds alone are filled in, not dropped — the whole
    /// point of one id was that the two accounts describe the same work.
    func testEachSideFillsTheOthersGaps() {
        let merged = team(status: "blocked")
            .merging(coordinator: coordinator(status: "suspect", reason: "no team is running in x-backup"))

        XCTAssertEqual(merged.blockedReason, "no team is running in x-backup")
        XCTAssertEqual(merged.assignee, "executor", "the agent holding it beats the host it runs on")
        XCTAssertEqual(merged.teamName, "x-backup")
        XCTAssertEqual(merged.updatedAt, "2026-07-24T13:05:00Z", "the later of the two")
    }

    /// A reason the team already recorded is not overwritten by the
    /// coordinator's.
    func testTheTeamsOwnReasonWins() {
        let merged = team(status: "blocked", blockedReason: "build failed")
            .merging(coordinator: coordinator(status: "suspect", reason: "heartbeat stale"))
        XCTAssertEqual(merged.blockedReason, "build failed")
    }

    /// Merging rebuilds a task out of two already-parsed ones, so it is the
    /// one place where the raw reply could be quietly replaced by the scrubbed
    /// copy — which is what auto pilot reads its VERIFY command out of.
    func testMergingKeepsTheRawReplyRatherThanTheScrubbedCopy() {
        let reply = """
        STATUS: DONE
        FILES: a.swift
        VERIFY: /Users/agent/bin/check.sh
        NEXT: NONE
        FULL_REPORT: n/a
        """
        let local = ReviewBoardTask(
            id: "c259ab1f", teamName: "x-backup", title: "T", status: "completed",
            result: reply
        )
        let merged = local.merging(
            coordinator: ReviewBoardTask(
                id: "c259ab1f", teamName: "Unknown team", title: "T", status: "review_ready"
            )
        )
        XCTAssertEqual(merged.rawResult, reply)
        XCTAssertTrue(
            merged.result?.contains("…/check.sh") == true,
            "the display copy stays scrubbed: \(merged.result ?? "nil")"
        )
    }

    /// The merge target and the diff base are both git refs. `safeLabel`
    /// rewrites a long enough word run to `<token>`, so the shown parent is not
    /// a branch anyone can merge into.
    func testTheRecordedParentSurvivesTheScrubberThatTheShownOneDoesNot() {
        let branch = "feat/distributed-workspaces-review-followups"
        let task = ReviewBoardTask(
            id: "c259ab1f", teamName: "x-backup", title: "T", status: "review_ready",
            worktreeParent: branch
        )
        XCTAssertEqual(task.rawWorktreeParent, branch)
        XCTAssertTrue(
            task.worktreeParent?.contains("<token>") == true,
            "the display copy is expected to be scrubbed: \(task.worktreeParent ?? "nil")"
        )
    }

    /// Merging rebuilds the task from an already-scrubbed parent, so it has to
    /// carry the recorded one across rather than re-derive it.
    func testMergingKeepsTheRecordedParent() {
        let branch = "feat/distributed-workspaces-review-followups"
        let merged = ReviewBoardTask(
            id: "c259ab1f", teamName: "x-backup", title: "T", status: "completed",
            worktreeParent: branch
        ).merging(
            coordinator: ReviewBoardTask(
                id: "c259ab1f", teamName: "Unknown team", title: "T", status: "review_ready"
            )
        )
        XCTAssertEqual(merged.rawWorktreeParent, branch)
    }

    /// The raw copy follows whichever side's reply won, so the two never
    /// describe different replies.
    func testMergingTakesTheRawReplyFromTheSideWhoseResultWon() {
        let coordinatorReply = "STATUS: DONE\nVERIFY: /Users/agent/bin/peer.sh\nNEXT: NONE"
        let merged = ReviewBoardTask(
            id: "c259ab1f", teamName: "x-backup", title: "T", status: "completed"
        ).merging(
            coordinator: ReviewBoardTask(
                id: "c259ab1f", teamName: "Unknown team", title: "T", status: "review_ready",
                result: coordinatorReply
            )
        )
        XCTAssertEqual(merged.rawResult, coordinatorReply)
    }
}

final class ReviewBoardAgentReportTests: XCTestCase {
    func test_reads_the_five_fields_and_the_summary_under_them() {
        let report = ReviewBoardAgentReport(result: """
        STATUS: DONE
        FILES: none
        VERIFY: find . -maxdepth 1 -type f | wc -l
        NEXT: NONE
        FULL_REPORT: n/a

        저장소 최상위 파일은 9개입니다.
        ✻ Crunched for 6s
        """)
        XCTAssertEqual(report?.status, "DONE")
        XCTAssertEqual(report?.verify, "find . -maxdepth 1 -type f | wc -l")
        // `none`, `NONE` and `n/a` are the protocol saying "nothing here".
        XCTAssertNil(report?.files)
        XCTAssertNil(report?.next)
        XCTAssertNil(report?.fullReport)
        // The spinner line is the agent's decoration, not its answer.
        XCTAssertEqual(report?.body, "저장소 최상위 파일은 9개입니다.")
    }

    func test_no_header_means_no_report() {
        XCTAssertNil(ReviewBoardAgentReport(result: "just some output\n"))
        XCTAssertNil(ReviewBoardAgentReport(result: nil))
    }

    func test_a_report_of_only_chrome_is_empty_not_shown() {
        let report = ReviewBoardAgentReport(result: "STATUS: DONE\nFILES: none\nNEXT: NONE\n✻ Brewed for 6s\n")
        XCTAssertNotNil(report)
        XCTAssertTrue(report?.isEmpty == true, "nothing worth showing must not push out the empty-state line")
    }

    func test_no_summary_shows_nothing_rather_than_the_pane() {
        // The agent answered above the header, which is not captured, so there
        // is no summary. What follows the header is all terminal.
        let report = ReviewBoardAgentReport(result: """
        STATUS: DONE
        VERIFY: ls

        ✻ Cogitated for 9s

        ──────────────────────────── @executor ──
        ❯
        """)
        XCTAssertNil(report?.body, "a rule with an agent name in it is not a result")
        XCTAssertEqual(report?.verify, "ls")
    }

    func test_stops_at_the_pane_below_the_reply() {
        // What the poller captures runs to the bottom of the screen: the
        // status bar, a rule, the prompt. None of it is the agent's answer.
        let report = ReviewBoardAgentReport(result: """
        STATUS: DONE
        NEXT: NONE

        최상위 파일 개수는 9개.

        ✻ Crunched for 5s


        ◉ xhigh · /effort
        ──────────────────────────── @executor ──
        ❯
        jinwoo@host:~/work/project/x-backup (main)
        """)
        XCTAssertEqual(report?.body, "최상위 파일 개수는 9개.")
    }

    func test_an_asterisk_sentence_survives() {
        let report = ReviewBoardAgentReport(result: "STATUS: DONE\nNEXT: NONE\n\n* rebuilt the xcframework\n")
        XCTAssertEqual(report?.body, "* rebuilt the xcframework")
    }

    // MARK: - When a task finished

    /// Neither board writes a `completed_at`, so a terminal status is what
    /// turns the last `updated_at` into a finish. Reading it off a running
    /// task would label a heartbeat as a completion.
    func test_a_finish_time_belongs_only_to_a_task_that_finished() {
        func task(_ status: String) -> ReviewBoardTask {
            ReviewBoardTask(id: "t", teamName: "ws", title: "Fix the parser",
                            status: status, updatedAt: "2026-07-28T08:32:11Z")
        }
        for done in ["completed", "review_ready", "approved", "merged"] {
            XCTAssertEqual(task(done).finishedAt, "2026-07-28T08:32:11Z", done)
        }
        for running in ["queued", "assigned", "in_progress", "blocked", "failed"] {
            XCTAssertNil(task(running).finishedAt, running)
        }
        // Terminal but never stamped — nothing to show rather than a guess.
        XCTAssertNil(
            ReviewBoardTask(id: "t", teamName: "ws", title: "x", status: "completed").finishedAt
        )
    }

    /// Both stamp shapes reach this board: the coordinator's plain ISO-8601 and
    /// the team board's with fractional seconds. One parser dropped half of
    /// them, and a dropped stamp is a row with no time at all.
    func test_both_stamp_shapes_read_as_a_clock_time() {
        XCTAssertNotNil(ReviewBoardText.clockTime("2026-07-28T08:32:11Z"))
        XCTAssertNotNil(ReviewBoardText.clockTime("2026-07-28T08:32:11.482Z"))
        XCTAssertNil(ReviewBoardText.clockTime("whenever"))
        // A day other than today keeps its date — otherwise a week-old row
        // reads as if it just happened.
        let old = ReviewBoardText.clockTime("2020-01-02T03:04:05Z")
        XCTAssertEqual(old?.contains("1/2"), true, String(describing: old))
    }

    // MARK: - The directive a delegated title opens with

    /// The instruction is used verbatim as the title, so the constraint handed
    /// to the agent became the headline of the card and pushed the actual work
    /// out of the two lines a row has.
    func test_a_leading_directive_is_lifted_out_of_the_title() {
        let parts = ReviewBoardText.splitDirective("READ-ONLY 설계 검토. 파일 수정 절대 금지")
        XCTAssertEqual(parts.directive, "READ-ONLY")
        XCTAssertEqual(parts.rest, "설계 검토. 파일 수정 절대 금지")

        // Spelling and separator vary; the mark does not.
        XCTAssertEqual(ReviewBoardText.splitDirective("read only: check the plan").directive,
                       "READ ONLY")
        XCTAssertEqual(ReviewBoardText.splitDirective("READ-ONLY — audit").rest, "audit")

        // A title that merely starts with the same letters is not a directive.
        let plain = ReviewBoardText.splitDirective("Read-only mode is broken")
        XCTAssertEqual(plain.directive, "READ-ONLY")
        XCTAssertEqual(plain.rest, "mode is broken")

        // Nothing to lift.
        XCTAssertNil(ReviewBoardText.splitDirective("수정 작업. gk pull 로그").directive)
        XCTAssertEqual(ReviewBoardText.splitDirective("수정 작업. gk pull 로그").rest,
                       "수정 작업. gk pull 로그")
        // Directive with nothing behind it still has to say something.
        XCTAssertEqual(ReviewBoardText.splitDirective("READ-ONLY").rest, "READ-ONLY")
        XCTAssertNil(ReviewBoardText.splitDirective("READ-ONLY").directive)
    }

}
