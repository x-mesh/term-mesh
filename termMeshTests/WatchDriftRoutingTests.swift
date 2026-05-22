import XCTest
import Foundation

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Tests for watch_drift.post RPC routing and schema consistency.
/// Catches regression bugs from Phase 5 (drift visibility) implementation.
final class WatchDriftRoutingTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        // Register a test team in TeamDataStore
        TeamDataStore.shared.registerTeam("test-team-drift", agentNames: ["executor", "reviewer"])
    }

    override func tearDown() {
        super.tearDown()
        // Clean up test team
        TeamDataStore.shared.unregisterTeam("test-team-drift")
    }

    // MARK: - Test 1: Schema Consistency (drift_type parameter)

    /// Verifies that team.watch_drift.post accepts drift_type (daemon convention, not drift_kind).
    /// Regression test for bug: daemon sends drift_type, handler was reading drift_kind.
    func testWatchDriftPostAcceptsDriftTypeParameter() {
        let params: [String: Any] = [
            "team_name": "test-team-drift",
            "target": "watch-test",
            "drift_type": "execution",  // daemon sends "drift_type", not "drift_kind"
            "severity": "high",
            "finding": "Test finding",
            "spec_clause": "test-clause",
            "check_id": "check-001"
        ]

        // Call the handler (synchronous)
        let controller = TerminalController()
        let result = controller.v2TeamWatchDriftPost(params: params)

        // Should succeed, not return "Missing drift_type" or "Missing drift_kind"
        switch result {
        case .ok(let payload):
            XCTAssertTrue(payload["posted"] as? Bool == true, "Should successfully post drift")
            XCTAssertEqual(payload["check_id"] as? String, "check-001")
        case .err(let code, let message, _):
            XCTFail("Handler should accept drift_type parameter, got error: \(code) - \(message)")
        }
    }

    /// Verifies that drift_type value is preserved in inbox items (not lost or renamed).
    func testWatchDriftInboxItemPreservesDriftType() {
        // Post a drift with drift_type="direction"
        let posted = TeamDataStore.shared.postWatchDrift(
            teamName: "test-team-drift",
            checkId: "check-002",
            target: "watch-test-2",
            driftKind: "direction",
            severity: "medium",
            finding: "Direction drift finding",
            specClause: "test-clause-2"
        )
        XCTAssertTrue(posted, "Should post drift successfully")

        // Retrieve inbox items
        let items = TeamDataStore.shared.inboxItems(teamName: "test-team-drift")

        // Find watch_drift item
        let driftItems = items.filter { ($0["kind"] as? String) == "watch_drift" }
        XCTAssertEqual(driftItems.count, 1, "Should have exactly one watch_drift item")

        let driftItem = driftItems.first!
        // Verify drift_type key exists and has correct value (not "drift_kind")
        let driftType = driftItem["drift_type"] as? String
        XCTAssertEqual(driftType, "direction", "Inbox item should have 'drift_type' key with correct value")

        // Verify other fields
        XCTAssertEqual(driftItem["check_id"] as? String, "check-002")
        XCTAssertEqual(driftItem["severity"] as? String, "medium")
        XCTAssertEqual(driftItem["target"] as? String, "watch-test-2")
    }

    // MARK: - Test 2: Routing Consistency (procesV2Command → dispatchTeamDataCommandDirect)

    /// Verifies that team.watch_drift.post is correctly routed and returns ok response, not "Unknown team command".
    /// Regression test for bug: case was in dead switch, unreachable from actual routing path.
    func testWatchDriftPostRoutingSucceeds() {
        let params: [String: Any] = [
            "team_name": "test-team-drift",
            "target": "routing-test",
            "drift_type": "execution",
            "severity": "low",
            "finding": "Routing test finding",
            "spec_clause": "routing-clause",
            "check_id": "check-routing-001"
        ]

        let controller = TerminalController()
        let result = controller.v2TeamWatchDriftPost(params: params)

        // Should NOT return "Unknown team command" error
        switch result {
        case .ok(let payload):
            XCTAssertTrue(payload["posted"] as? Bool == true)
            XCTAssertEqual(payload["team_name"] as? String, "test-team-drift")
        case .err(let code, _, _):
            XCTFail("Routing failed with error code: \(code). Should not be 'unknown_method'")
        }

        // Verify inbox item was actually created
        let items = TeamDataStore.shared.inboxItems(teamName: "test-team-drift")
        let found = items.contains {
            ($0["kind"] as? String) == "watch_drift" &&
            ($0["check_id"] as? String) == "check-routing-001"
        }
        XCTAssertTrue(found, "Inbox should contain the posted watch_drift item")
    }

    // MARK: - Test 3: Deduplication (same check_id should not duplicate)

    /// Verifies that posting the same check_id twice results in one inbox item (upsert, not append).
    /// Prevents duplicate entries when scheduler retries a check.
    func testWatchDriftDeduplicationByCheckId() {
        let checkId = "check-dedup-001"

        // First post
        let posted1 = TeamDataStore.shared.postWatchDrift(
            teamName: "test-team-drift",
            checkId: checkId,
            target: "dedup-test",
            driftKind: "execution",
            severity: "high",
            finding: "First finding",
            specClause: "clause-1"
        )
        XCTAssertTrue(posted1)

        var items = TeamDataStore.shared.inboxItems(teamName: "test-team-drift")
        let countAfterFirst = items.filter { ($0["check_id"] as? String) == checkId }.count
        XCTAssertEqual(countAfterFirst, 1, "Should have 1 item after first post")

        // Second post with same check_id (simulates scheduler retry)
        let posted2 = TeamDataStore.shared.postWatchDrift(
            teamName: "test-team-drift",
            checkId: checkId,
            target: "dedup-test",
            driftKind: "execution",
            severity: "high",
            finding: "Updated finding",  // different content
            specClause: "clause-1"
        )
        XCTAssertTrue(posted2)

        items = TeamDataStore.shared.inboxItems(teamName: "test-team-drift")
        let countAfterSecond = items.filter { ($0["check_id"] as? String) == checkId }.count
        XCTAssertEqual(countAfterSecond, 1, "Should still have 1 item after second post (upsert, not append)")

        // Verify the item has updated finding
        if let updatedItem = items.first(where: { ($0["check_id"] as? String) == checkId }) {
            XCTAssertEqual(updatedItem["finding"] as? String, "Updated finding", "Item should be updated, not duplicated")
        }
    }

    // MARK: - Test 4: Watch Drift Item Priority and Summary Format

    /// Verifies that watch_drift items have correct priority (2) and summary format.
    func testWatchDriftItemFormatting() {
        let posted = TeamDataStore.shared.postWatchDrift(
            teamName: "test-team-drift",
            checkId: "check-format-001",
            target: "format-test",
            driftKind: "direction",
            severity: "medium",
            finding: "Test finding for format verification that is somewhat long",
            specClause: "format-clause"
        )
        XCTAssertTrue(posted)

        let items = TeamDataStore.shared.inboxItems(teamName: "test-team-drift")
        guard let driftItem = items.first(where: { ($0["kind"] as? String) == "watch_drift" }) else {
            XCTFail("No watch_drift item found")
            return
        }

        // Verify priority
        XCTAssertEqual(driftItem["priority"] as? Int, 2, "Watch drift should have priority 2")

        // Verify summary format: [watch:drift_kind/severity] finding_preview
        let summary = driftItem["summary"] as? String
        XCTAssertTrue(summary?.contains("[watch:direction/medium]") ?? false,
                     "Summary should start with [watch:kind/severity]")
        XCTAssertTrue(summary?.contains("Test finding") ?? false,
                     "Summary should include finding text")
    }

    // MARK: - Test 5: Error Handling

    /// Verifies that missing required parameters are properly rejected.
    func testWatchDriftPostValidatesRequiredParams() {
        let controller = TerminalController()

        // Missing team_name
        var params: [String: Any] = [
            "drift_type": "execution",
            "severity": "high",
            "finding": "Test",
            "spec_clause": "clause",
            "check_id": "check-1"
        ]
        var result = controller.v2TeamWatchDriftPost(params: params)
        if case .err(let code, _, _) = result {
            XCTAssertEqual(code, "invalid_params")
        } else {
            XCTFail("Should reject missing team_name")
        }

        // Missing drift_type
        params = [
            "team_name": "test-team-drift",
            "target": "test",
            "severity": "high",
            "finding": "Test",
            "spec_clause": "clause",
            "check_id": "check-1"
        ]
        result = controller.v2TeamWatchDriftPost(params: params)
        if case .err(let code, _, _) = result {
            XCTAssertEqual(code, "invalid_params")
        } else {
            XCTFail("Should reject missing drift_type")
        }
    }
}
