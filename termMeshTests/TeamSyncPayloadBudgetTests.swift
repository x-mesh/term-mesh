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
        let request: [String: Any] = [
            "id": 1,
            "method": "team.sync",
            "params": payload,
        ]
        return try JSONSerialization.data(withJSONObject: request).count
    }

    func testUnboundedFixtureExceedsDaemonEnvelopeBeforeBudgeting() throws {
        let now = Date()
        let tasks = (0..<4).map { index in
            TeamOrchestrator.TeamTask(
                id: "terminal-\(index)",
                title: "terminal task \(index)",
                details: nil,
                acceptanceCriteria: [],
                labels: [],
                estimatedSize: nil,
                assignee: "agent-\(index)",
                assigneeInstanceId: "instance-\(index)",
                status: "completed",
                priority: index,
                dependsOn: [],
                parentTaskId: nil,
                childTaskIds: [],
                reassignmentCount: 0,
                supersededBy: nil,
                blockedReason: nil,
                reviewSummary: nil,
                createdBy: "leader",
                result: String(repeating: "r", count: 16 * 1024),
                resultPath: nil,
                worktreePolicy: nil,
                worktreePath: nil,
                worktreeBranch: nil,
                worktreeParent: nil,
                worktreeCreated: nil,
                worktreeReused: nil,
                worktreeInit: nil,
                worktreeFinishedAt: nil,
                worktreeFinishMode: nil,
                worktreeRemoved: nil,
                createdAt: now,
                updatedAt: now,
                startedAt: nil,
                completedAt: now,
                lastProgressAt: nil
            )
        }
        let payload: [String: Any] = [
            "teams": [["team_name": "fixture"]],
            "tasks": tasks.map { TeamOrchestrator.shared.taskDictionary($0) },
            "attention": [],
            "instance": [:]
        ]
        let bytes = try requestBytes(for: payload)
        print("unbudgeted team.sync fixture bytes: \(bytes)")
        XCTAssertGreaterThan(bytes, envelopeLimit)
    }

    func testBudgetPreservesActiveTasksAndWorktreePaths() throws {
        let now = Date()
        let task = { (id: String, status: String, result: String, updatedAt: Date) in
            TeamOrchestrator.TeamTask(
                id: id, title: id, details: nil, acceptanceCriteria: [], labels: [],
                estimatedSize: nil, assignee: "agent", assigneeInstanceId: "instance",
                status: status, priority: 1, dependsOn: [], parentTaskId: nil,
                childTaskIds: [], reassignmentCount: 0, supersededBy: nil,
                blockedReason: nil, reviewSummary: nil, createdBy: "leader",
                result: result, resultPath: nil, worktreePolicy: nil,
                worktreePath: "/tmp/\(id)", worktreeBranch: "branch-\(id)",
                worktreeParent: nil, worktreeCreated: true, worktreeReused: nil,
                worktreeInit: nil, worktreeFinishedAt: nil, worktreeFinishMode: nil,
                worktreeRemoved: nil, createdAt: now, updatedAt: updatedAt,
                startedAt: now, completedAt: status == "completed" ? now : nil,
                lastProgressAt: now
            )
        }
        let terminalTasks = (0..<40).map {
            TeamOrchestrator.shared.taskDictionary(
                task(
                    "terminal-\($0)", "completed", String(repeating: "🙂", count: 16 * 1024),
                    now.addingTimeInterval(-TimeInterval($0))
                )
            )
        }
        let activeTasks = [
            TeamOrchestrator.shared.taskDictionary(task("active-1", "in_progress", "active", now)),
            TeamOrchestrator.shared.taskDictionary(task("active-2", "blocked", "blocked", now)),
        ]
        let fullPayload: [String: Any] = [
            "teams": [[
                "team_name": "fixture",
                "agents": [[
                    "id": "agent-id", "name": "agent", "worktree_path": "/tmp/agent-worktree"
                ]]
            ]],
            "tasks": terminalTasks + activeTasks,
            "attention": [],
            "instance": ["team_count": 1]
        ]
        let fullBytes = try requestBytes(for: fullPayload)
        print("full fleet payload bytes: \(fullBytes)")
        XCTAssertEqual((fullPayload["tasks"] as? [[String: Any]])?.count, 42)
        XCTAssertGreaterThan(fullBytes, envelopeLimit)
        let payload = TeamOrchestrator.budgetTeamSyncPayload(
            teams: [[
                "team_name": "fixture",
                "agents": [[
                    "id": "agent-id", "name": "agent", "worktree_path": "/tmp/agent-worktree"
                ]]
            ]],
            tasks: terminalTasks + activeTasks,
            attention: [],
            instance: ["team_count": 1]
        )
        XCTAssertEqual((fullPayload["tasks"] as? [[String: Any]])?.count, 42)
        let bytes = try requestBytes(for: payload)
        print("budgeted team.sync fixture bytes: \(bytes)")
        XCTAssertLessThanOrEqual(bytes, 64 * 1024)
        let sentTasks = try XCTUnwrap(payload["tasks"] as? [[String: Any]])
        XCTAssertTrue(sentTasks.contains { $0["id"] as? String == "active-1" })
        XCTAssertTrue(sentTasks.contains { $0["id"] as? String == "active-2" })
        let firstTerminal = sentTasks.first { $0["status"] as? String == "completed" }
        XCTAssertEqual(firstTerminal?["id"] as? String, "terminal-0")
        let activeOne = sentTasks.first { $0["id"] as? String == "active-1" }
        XCTAssertEqual(activeOne?["worktree_path"] as? String, "/tmp/active-1")
        let sentAgent = try XCTUnwrap((payload["teams"] as? [[String: Any]])?.first?["agents"] as? [[String: Any]])
        XCTAssertEqual(sentAgent.first?["worktree_path"] as? String, "/tmp/agent-worktree")
        let sentTerminalCount = sentTasks.filter { $0["status"] as? String == "completed" }.count
        XCTAssertEqual(
            (payload["instance"] as? [String: Any])?["omitted_terminal_task_count"] as? Int,
            40 - sentTerminalCount
        )
        let truncated = (payload["instance"] as? [String: Any])?["truncated_free_text_field_count"] as? Int
        XCTAssertGreaterThan(truncated ?? 0, 0)
        let terminalResults = sentTasks.compactMap { $0["result"] as? String }
        XCTAssertFalse(terminalResults.isEmpty)
        XCTAssertTrue(terminalResults.allSatisfy {
            $0.utf8.count <= TeamOrchestrator.teamSyncFreeTextLimitBytes
                && String(data: Data($0.utf8), encoding: .utf8) != nil
        })
    }

    func testLargeTerminalAndAttentionFixtureStaysWithinEnvelope() throws {
        let now = Date()
        let terminalTasks = (0..<500).map { index in
            let task = TeamOrchestrator.TeamTask(
                id: "terminal-\(index)", title: "terminal-\(index)", details: nil,
                acceptanceCriteria: [], labels: [], estimatedSize: nil, assignee: "agent",
                assigneeInstanceId: "instance", status: "completed", priority: 1,
                dependsOn: [], parentTaskId: nil, childTaskIds: [], reassignmentCount: 0,
                supersededBy: nil, blockedReason: nil, reviewSummary: nil, createdBy: "leader",
                result: String(repeating: "result-\(index)-", count: 512), resultPath: nil,
                worktreePolicy: nil, worktreePath: "/tmp/terminal-\(index)",
                worktreeBranch: "branch-\(index)", worktreeParent: nil,
                worktreeCreated: true, worktreeReused: nil, worktreeInit: nil,
                worktreeFinishedAt: nil, worktreeFinishMode: nil, worktreeRemoved: nil,
                createdAt: now, updatedAt: now.addingTimeInterval(-TimeInterval(index)),
                startedAt: now, completedAt: now, lastProgressAt: now
            )
            return TeamOrchestrator.shared.taskDictionary(task)
        }
        let attention = (0..<500).map { index in
            [
                "kind": "task", "priority": 5, "team_name": "fixture",
                "task_id": "terminal-\(index)", "agent_name": "agent",
                "reason": String(repeating: "attention-\(index)-", count: 128),
                "summary": "attention \(index)", "task_title": "terminal-\(index)",
                "result": String(repeating: "attention-result-\(index)-", count: 128),
                "status": "completed"
            ] as [String: Any]
        }
        let payload = TeamOrchestrator.budgetTeamSyncPayload(
            teams: [["team_name": "fixture"]], tasks: terminalTasks,
            attention: attention, instance: ["team_count": 1]
        )
        let bytes = try requestBytes(for: payload)
        print("large budgeted team.sync fixture bytes: \(bytes)")
        XCTAssertLessThanOrEqual(bytes, envelopeLimit)
        XCTAssertGreaterThan(
            (payload["instance"] as? [String: Any])?["omitted_terminal_task_count"] as? Int ?? 0, 0
        )
        XCTAssertGreaterThan(
            (payload["instance"] as? [String: Any])?["omitted_attention_count"] as? Int ?? 0, 0
        )
    }
}
