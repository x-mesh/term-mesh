import XCTest
import Foundation

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Tests for watch_drift.post RPC routing and schema consistency.
/// Catches regression bugs from Phase 5 (drift visibility) implementation.
///
/// This file was never listed in `project.pbxproj`, so it had never been
/// compiled and none of it had ever run. Registering it surfaced two things:
///
/// 1. Every case here called `TerminalController()`, but that type is a
///    `@MainActor` singleton with `private init()`
///    (`Sources/TerminalController.swift:136`) — the only handle is
///    `TerminalController.shared`.
/// 2. The handler it wants, `v2TeamWatchDriftPost`, is `private`
///    (`Sources/TerminalController.swift:5666`), and `@testable import` raises
///    `internal` to public — it does **not** reach `private`. So no test can
///    call it, whatever instance it holds.
///
/// The store-level cases below need neither and are therefore live: they cover
/// the half of the regression that is observable through `TeamDataStore` — the
/// inbox item's `drift_type` key, the check-id upsert, and the summary format.
/// The three handler-level cases (parameter name, routing, parameter
/// validation) live in `WatchDriftHandlerRoutingTests` at the bottom, compiled
/// only under `TERMMESH_TESTABLE_V2_HANDLERS`, because they cannot compile
/// until `v2TeamWatchDriftPost` is `internal`. They are kept verbatim so
/// dropping `private` and defining that flag is all it takes to run them.
final class WatchDriftRoutingTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        // Register a test team in TeamDataStore
        TeamDataStore.shared.registerTeam("test-team-drift", agentNames: ["executor", "reviewer"])
    }

    override func tearDown() {
        super.tearDown()
        // Clean up test team. `unregisterTeam` also drops this team's
        // `watchDrifts`, which is what keeps the per-item counts below exact
        // when the whole suite runs in one process.
        TeamDataStore.shared.unregisterTeam("test-team-drift")
    }

    // MARK: - Test 1: Schema Consistency (drift_type parameter)

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

    // MARK: - Test 2: Deduplication (same check_id should not duplicate)

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

    // MARK: - Test 3: Watch Drift Item Priority and Summary Format

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

    // MARK: - Test 4: An unregistered team is refused

    /// The handler cases below assert `invalid_params` for a missing
    /// `team_name`; the store's own half of that contract — a team it does not
    /// know is refused rather than silently accumulating drift — is reachable
    /// here, so it is checked here.
    func testWatchDriftPostRefusesUnknownTeam() {
        let posted = TeamDataStore.shared.postWatchDrift(
            teamName: "team-that-was-never-registered",
            checkId: "check-unknown-001",
            target: "unknown-test",
            driftKind: "execution",
            severity: "high",
            finding: "Should not be stored",
            specClause: "clause"
        )
        XCTAssertFalse(posted, "An unregistered team must not accept a drift post")
        XCTAssertTrue(
            TeamDataStore.shared.inboxItems(teamName: "team-that-was-never-registered").isEmpty,
            "Nothing may be stored for a team the store does not know"
        )
    }
}

// The handler-level cases. `v2TeamWatchDriftPost` is `private`, so these do not
// compile as things stand — see the note on `WatchDriftRoutingTests`. Enabling
// them is two edits, both outside this file and neither made here:
//
//   1. `Sources/TerminalController.swift:5666`
//      `private func v2TeamWatchDriftPost` → `func v2TeamWatchDriftPost`
//      (internal is all `@testable import` needs; nothing outside the module
//      gains access).
//   2. Add `TERMMESH_TESTABLE_V2_HANDLERS` to the test target's
//      `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
//
// Kept compiling-ready rather than deleted: these three are the only cases that
// cover the parameter name the daemon actually sends, the routing entry that was
// once dead, and the handler's own validation. Two changes were needed to make
// them buildable at all and both are made below: `TerminalController.shared`
// instead of `TerminalController()`, and a cast of `V2CallResult.ok`'s payload,
// whose associated value is `Any` and cannot be subscripted directly.
#if TERMMESH_TESTABLE_V2_HANDLERS
final class WatchDriftHandlerRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TeamDataStore.shared.registerTeam("test-team-drift", agentNames: ["executor", "reviewer"])
    }

    override func tearDown() {
        super.tearDown()
        TeamDataStore.shared.unregisterTeam("test-team-drift")
    }

    /// Verifies that team.watch_drift.post accepts drift_type (daemon convention, not drift_kind).
    /// Regression test for bug: daemon sends drift_type, handler was reading drift_kind.
    @MainActor
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

        // Call the handler (synchronous). `shared` because the initializer is
        // private — the type is a singleton.
        let controller = TerminalController.shared
        let result = controller.v2TeamWatchDriftPost(params: params)

        // Should succeed, not return "Missing drift_type" or "Missing drift_kind"
        switch result {
        case .ok(let payload):
            let fields = payload as? [String: Any]
            XCTAssertNotNil(fields, "ok payload should be a dictionary")
            XCTAssertTrue(fields?["posted"] as? Bool == true, "Should successfully post drift")
            XCTAssertEqual(fields?["check_id"] as? String, "check-001")
        case .err(let code, let message, _):
            XCTFail("Handler should accept drift_type parameter, got error: \(code) - \(message)")
        }
    }

    /// Verifies that team.watch_drift.post is correctly routed and returns ok response, not "Unknown team command".
    /// Regression test for bug: case was in dead switch, unreachable from actual routing path.
    @MainActor
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

        let controller = TerminalController.shared
        let result = controller.v2TeamWatchDriftPost(params: params)

        // Should NOT return "Unknown team command" error
        switch result {
        case .ok(let payload):
            let fields = payload as? [String: Any]
            XCTAssertTrue(fields?["posted"] as? Bool == true)
            XCTAssertEqual(fields?["team_name"] as? String, "test-team-drift")
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

    /// Verifies that missing required parameters are properly rejected.
    @MainActor
    func testWatchDriftPostValidatesRequiredParams() {
        let controller = TerminalController.shared

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
#endif
