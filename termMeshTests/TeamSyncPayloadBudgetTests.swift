import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class TeamSyncPayloadBudgetTests: XCTestCase {
    private let envelopeLimit = TermMeshDaemonProtocol.maxOperationEnvelopeBytes

    private func requestBytes(for payload: [String: Any]) throws -> Int {
        try JSONSerialization.data(withJSONObject: [
            "id": 1, "method": "team.sync", "params": payload
        ] as [String: Any]).count
    }

    private func task(
        id: String, status: String, updatedAt: String,
        result: String = String(repeating: "result-", count: 1024),
        reviewSummary: String = String(repeating: "review-", count: 512)
    ) -> [String: Any] {
        [
            "id": id, "title": "Task \(id)",
            "description": String(repeating: "description-", count: 512),
            "acceptance_criteria": [String(repeating: "acceptance-", count: 512)],
            "labels": [String(repeating: "label-", count: 100), "🙂"],
            "status": status, "priority": 2,
            "depends_on": [String(repeating: "dependency-", count: 100), "依存"],
            "assignee": "agent-0", "team_name": "team-0",
            "blocked_reason": status == "blocked" ? reviewSummary : NSNull(),
            "review_summary": reviewSummary, "result": result,
            "result_path": "/tmp/results/\(id).md",
            "worktree_path": "/worktrees/team-0/\(id)",
            "worktree_branch": "team/\(id)",
            "created_at": "2026-10-13T00:00:00Z",
            "updated_at": updatedAt, "last_progress_at": updatedAt,
            "is_stale": false, "needs_attention": status == "blocked",
        ]
    }

    private func roster(teamCount: Int = 3, agentsPerTeam: [Int] = [5, 5, 6]) -> [[String: Any]] {
        (0..<teamCount).map { teamIndex in
            [
                "team_name": "team-\(teamIndex)",
                "team_uuid": "uuid-\(teamIndex)",
                "workspace_id": "workspace-\(teamIndex)",
                "agents": (0..<agentsPerTeam[teamIndex]).map { agentIndex in
                    [
                        "id": "agent-id-\(teamIndex)-\(agentIndex)",
                        "name": "agent-\(teamIndex)-\(agentIndex)",
                        "cli": "claude",
                        "heartbeat_age_seconds": agentIndex,
                        "last_heartbeat_summary": "heartbeat-\(agentIndex)",
                        "heartbeat_is_stale": false,
                        "worktree_path": "/worktrees/team-\(teamIndex)/agent-\(agentIndex)",
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
    }

    private func attention(_ index: Int) -> [String: Any] {
        [
            "kind": "task", "priority": 5, "team_name": "team-0",
            "task_id": "attention-\(index)", "agent_name": "agent-0",
            "status": "blocked", "age_seconds": index, "is_stale": false,
            "stale_seconds": 0, "task_title": "Attention \(index)",
            "reason": String(repeating: "reason-", count: 512),
            "summary": String(repeating: "summary-", count: 512),
            "result": String(repeating: "result-", count: 1024),
            "review_summary": String(repeating: "review-", count: 512),
        ]
    }

    func testMeasuredHostShapePreservesRosterAndFitsEnvelope() throws {
        let reviews = (0..<30).map { task(id: "review-\($0)", status: "review_ready", updatedAt: String(format: "2026-10-13T00:00:%02dZ", $0)) }
        let assigned = (0..<4).map { task(id: "assigned-\($0)", status: "assigned", updatedAt: String(format: "2026-10-12T00:00:%02dZ", $0)) }
        let blocked = (0..<2).map { task(id: "blocked-\($0)", status: "blocked", updatedAt: String(format: "2026-10-11T00:00:%02dZ", $0)) }
        let completed = (0..<133).map { task(id: "completed-\($0)", status: "completed", updatedAt: String(format: "2026-09-%02dT00:00:00Z", ($0 % 28) + 1)) }
        let tasks = reviews + assigned + blocked + completed
        let instance: [String: Any] = ["team_count": 3, "socket_path": "/tmp/team-mesh.sock"]
        let raw = try requestBytes(for: ["teams": roster(), "tasks": tasks, "attention": [attention(0)], "instance": instance])
        print("measured raw team.sync fixture bytes: \(raw)")
        XCTAssertGreaterThan(raw, envelopeLimit)
        let payload = TeamOrchestrator.budgetTeamSyncPayload(teams: roster(), tasks: tasks, attention: [attention(0)], instance: instance)
        let bytes = try requestBytes(for: payload)
        print("measured budgeted team.sync fixture bytes: \(bytes)")
        XCTAssertLessThanOrEqual(bytes, envelopeLimit)
        let agents = (payload["teams"] as? [[String: Any]])?.flatMap { $0["agents"] as? [[String: Any]] ?? [] } ?? []
        XCTAssertEqual(agents.count, 16)
        XCTAssertTrue(agents.allSatisfy { ($0["worktree_path"] as? String)?.hasPrefix("/worktrees/") == true && $0["heartbeat_age_seconds"] != nil && $0["last_heartbeat_summary"] != nil })
        let sentTasks = try XCTUnwrap(payload["tasks"] as? [[String: Any]])
        XCTAssertTrue(sentTasks.allSatisfy { $0["result"] == nil && $0["description"] == nil && $0["acceptance_criteria"] == nil })
        let statuses = sentTasks.compactMap { $0["status"] as? String }
        if let firstAssigned = statuses.firstIndex(of: "assigned") {
            XCTAssertFalse(statuses[..<firstAssigned].contains("assigned"))
        }
        if let firstBlocked = statuses.firstIndex(of: "blocked") {
            XCTAssertFalse(statuses[..<firstBlocked].contains("assigned"))
        }
        let counters = try XCTUnwrap(payload["instance"] as? [String: Any])
        XCTAssertEqual(counters["omitted_review_ready_task_count"] as? Int, 0)
        XCTAssertEqual(counters["omitted_non_terminal_task_count"] as? Int, 0)
        XCTAssertEqual(counters["omitted_terminal_task_count"] as? Int, 133 - sentTasks.filter { $0["status"] as? String == "completed" }.count)
        XCTAssertGreaterThan(counters["truncated_free_text_field_count"] as? Int ?? 0, 0)
    }

    func testPriorityAndRecencyWithinGroupsAndCounters() throws {
        let tasks = [
            task(id: "review-old", status: "review_ready", updatedAt: "2026-10-13T00:00:01Z"),
            task(id: "review-new", status: "review_ready", updatedAt: "2026-10-13T00:00:03Z"),
            task(id: "blocked-old", status: "blocked", updatedAt: "2026-10-13T00:00:01Z"),
            task(id: "blocked-new", status: "blocked", updatedAt: "2026-10-13T00:00:02Z"),
            task(id: "assigned", status: "assigned", updatedAt: "2026-10-13T00:00:04Z"),
            task(id: "done", status: "completed", updatedAt: "2026-10-13T00:00:05Z"),
        ]
        let payload = TeamOrchestrator.budgetTeamSyncPayload(teams: roster(teamCount: 1, agentsPerTeam: [1]), tasks: tasks, attention: [], instance: [:])
        let ids = try XCTUnwrap(payload["tasks"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        XCTAssertEqual(Array(ids.prefix(5)), ["review-new", "review-old", "blocked-new", "blocked-old", "assigned"])
        let counters = try XCTUnwrap(payload["instance"] as? [String: Any])
        XCTAssertEqual(counters["omitted_terminal_task_count"] as? Int, 0)
        XCTAssertEqual(counters["omitted_non_terminal_task_count"] as? Int, 0)
        XCTAssertEqual(counters["omitted_review_ready_task_count"] as? Int, 0)
    }

    func testRosterOnlyOverflowKeepsRosterAndRejectsEnvelope() throws {
        let teams: [[String: Any]] = [["team_name": "oversized", "agents": (0..<700).map { index in ["id": "agent-\(index)", "name": "agent-\(index)", "worktree_path": "/worktrees/oversized/\(String(repeating: "x", count: 128))/\(index)"] as [String: Any] }]]
        let payload = TeamOrchestrator.budgetTeamSyncPayload(teams: teams, tasks: [task(id: "task", status: "assigned", updatedAt: "2026-10-13T00:00:00Z")], attention: [attention(0)], instance: [:])
        XCTAssertEqual((payload["tasks"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(((payload["teams"] as? [[String: Any]])?.first?["agents"] as? [[String: Any]])?.count, 700)
        XCTAssertEqual((payload["instance"] as? [String: Any])?["omitted_non_terminal_task_count"] as? Int, 1)
        XCTAssertEqual((payload["instance"] as? [String: Any])?["omitted_attention_count"] as? Int, 1)
        XCTAssertFalse(TermMeshDaemon.requestBodyFitsDaemonEnvelope(Data(repeating: 0, count: try requestBytes(for: payload))))
    }

    func testUTF8TruncationAndStringArraysRemainScalarSafe() throws {
        let limit = TeamOrchestrator.teamSyncFreeTextLimitBytes
        let ascii = String(repeating: "a", count: limit)
        XCTAssertEqual(TeamOrchestrator.truncateTeamSyncText(ascii), ascii)
        for scalar in ["é", "€", "🙂"] {
            let value = String(repeating: scalar, count: limit)
            let result = TeamOrchestrator.truncateTeamSyncText(value)
            XCTAssertLessThanOrEqual(result.utf8.count, limit)
            XCTAssertEqual(String(value.unicodeScalars.prefix(result.unicodeScalars.count)), result)
        }
        let payload = TeamOrchestrator.budgetTeamSyncPayload(teams: roster(teamCount: 1, agentsPerTeam: [1]), tasks: [task(id: "utf8", status: "assigned", updatedAt: "2026-10-13T00:00:00Z")], attention: [], instance: [:])
        let sent = try XCTUnwrap((payload["tasks"] as? [[String: Any]])?.first)
        XCTAssertTrue((sent["labels"] as? [String] ?? []).allSatisfy { String(data: Data($0.utf8), encoding: .utf8) == $0 })
        XCTAssertTrue((sent["depends_on"] as? [String] ?? []).allSatisfy { String(data: Data($0.utf8), encoding: .utf8) == $0 })
        XCTAssertTrue((sent["labels"] as? [String] ?? []).allSatisfy { $0.utf8.count <= TeamOrchestrator.teamSyncTaskTextLimitBytes })
        XCTAssertTrue((sent["depends_on"] as? [String] ?? []).allSatisfy { $0.utf8.count <= TeamOrchestrator.teamSyncTaskTextLimitBytes })
    }

    func testEnvelopeHelperMatchesDaemonBodyLimit() {
        XCTAssertTrue(TermMeshDaemon.requestBodyFitsDaemonEnvelope(Data(repeating: 0, count: envelopeLimit)))
        XCTAssertFalse(TermMeshDaemon.requestBodyFitsDaemonEnvelope(Data(repeating: 0, count: envelopeLimit + 1)))
    }

    func testBudgetIsPureAndKeepsFullInputTasks() throws {
        let sourceTasks = [task(id: "full", status: "completed", updatedAt: "2026-10-13T00:00:00Z")]
        let payload = TeamOrchestrator.budgetTeamSyncPayload(teams: roster(teamCount: 1, agentsPerTeam: [1]), tasks: sourceTasks, attention: [], instance: [:])
        XCTAssertNotNil(sourceTasks.first?["result"] as? String)
        XCTAssertNil((payload["tasks"] as? [[String: Any]])?.first?["result"])
        XCTAssertNotNil(sourceTasks.first?["result"] as? String)
    }

    func testLargeFixtureStaysWithinEnvelope() throws {
        let terminal = (0..<500).map { task(id: "terminal-\($0)", status: "completed", updatedAt: "2026-09-01T00:00:00Z") }
        let active = (0..<100).map { task(id: "active-\($0)", status: "assigned", updatedAt: "2026-10-13T00:00:00Z") }
        let payload = TeamOrchestrator.budgetTeamSyncPayload(teams: roster(teamCount: 1, agentsPerTeam: [1]), tasks: terminal + active, attention: (0..<500).map(attention), instance: [:])
        let bytes = try requestBytes(for: payload)
        print("large budgeted team.sync fixture bytes: \(bytes)")
        XCTAssertLessThanOrEqual(bytes, envelopeLimit)
    }
}
