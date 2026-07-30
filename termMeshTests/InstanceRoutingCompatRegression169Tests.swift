import Foundation
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// What instance routing may not cost.
///
/// Pinning a task to an exact agent instance is right, and it arrived with a
/// rule nobody asked for: a name the registry could not resolve to exactly one
/// live agent stopped assigning at all. Both callers answer `nil` that way, and
/// both sockets above them read `nil` as "Task not found" — so an ordinary
/// `tm-agent task update` reported a task that was plainly on the board as
/// missing, and the Review Queue's Reject button sent work back to nobody.
///
/// The pin stays. What comes back is the older contract underneath it: a name
/// on its own assigns, exactly as `createTask` has always let it.
final class InstanceRoutingCompatRegression169Tests: XCTestCase {
    private var teamName = ""
    private let store = TeamDataStore.shared

    override func setUp() {
        super.setUp()
        teamName = "instance-compat-\(UUID().uuidString)"
        store.registerTeam(teamName, agents: [
            .init(name: "executor", instanceId: "instance-a"),
            .init(name: "executor", instanceId: "instance-b"),
            .init(name: "reviewer", instanceId: "instance-r"),
        ])
    }

    override func tearDown() {
        store.unregisterTeam(teamName)
        super.tearDown()
    }

    private func task(assignedTo assignee: String? = "reviewer") throws -> String {
        try XCTUnwrap(store.createTask(
            teamName: teamName, title: "work", assignee: assignee
        )).id
    }

    // MARK: - A name the registry does not know still assigns

    /// Agents are named before they register — a role written into a plan, a
    /// peer whose pane has not reported yet. Refusing those turned every such
    /// update into `not_found`.
    func testUpdateAcceptsANameTheRegistryHasNeverSeen() throws {
        let id = try task()

        let updated = try XCTUnwrap(
            store.updateTask(teamName: teamName, taskId: id, assignee: "nobody-yet"),
            "an unregistered name must still assign, or the socket answers not_found"
        )

        XCTAssertEqual(updated.assignee, "nobody-yet")
        XCTAssertNil(updated.assigneeInstanceId, "there is no instance to pin to yet")
    }

    /// The Reject button has only a name to send work back to.
    func testReassignAcceptsANameTheRegistryHasNeverSeen() throws {
        let id = try task()

        let reassigned = try XCTUnwrap(
            store.reassignTask(teamName: teamName, taskId: id, assignee: "nobody-yet"),
            "rejecting a review must not fail silently on an unfamiliar name"
        )

        XCTAssertEqual(reassigned.assignee, "nobody-yet")
        XCTAssertNil(reassigned.assigneeInstanceId)
        XCTAssertEqual(reassigned.status, "assigned")
    }

    // MARK: - A duplicated name picks the first, and says so

    func testUpdateWithADuplicatedNamePinsTheFirstInstance() throws {
        let id = try task()

        let updated = try XCTUnwrap(
            store.updateTask(teamName: teamName, taskId: id, assignee: "executor")
        )

        XCTAssertEqual(updated.assignee, "executor")
        XCTAssertEqual(updated.assigneeInstanceId, "instance-a", "first match, as before")
    }

    func testReassignWithADuplicatedNamePinsTheFirstInstance() throws {
        let id = try task()

        let reassigned = try XCTUnwrap(
            store.reassignTask(teamName: teamName, taskId: id, assignee: "executor")
        )

        XCTAssertEqual(reassigned.assigneeInstanceId, "instance-a")
    }

    /// Choosing for the caller is fine; choosing silently is not. This is what
    /// the socket layer puts in its answer as `duplicate_name_warning`.
    func testADuplicatedNameIsReportedAsAChoiceThatWasMade() throws {
        let warning = try XCTUnwrap(
            store.duplicateNameWarning(teamName: teamName, assignee: "executor"),
            "two agents answer to this name; the caller has to be told which was used"
        )
        XCTAssertTrue(warning.contains("executor"))
        XCTAssertTrue(warning.contains("agent_instance_id"), "it has to say how to choose")
    }

    func testAUniqueNameIsNotReportedAsAmbiguous() {
        XCTAssertNil(store.duplicateNameWarning(teamName: teamName, assignee: "reviewer"))
        XCTAssertNil(store.duplicateNameWarning(teamName: teamName, assignee: "nobody-yet"))
        XCTAssertNil(store.duplicateNameWarning(teamName: teamName, assignee: nil))
        XCTAssertNil(store.duplicateNameWarning(teamName: teamName, assignee: "  "))
    }

    // MARK: - An explicit instance is still checked

    /// The looser name-only path must not become a way around the pin: naming
    /// an instance is a claim about which agent this is, and a claim that does
    /// not hold is refused rather than rounded to a sibling.
    func testAnExplicitInstanceThatDoesNotMatchTheNameIsStillRefused() throws {
        let id = try task()

        XCTAssertNil(
            store.updateTask(
                teamName: teamName, taskId: id,
                assignee: "executor", assigneeInstanceId: "instance-r"
            ),
            "instance-r is the reviewer; pairing it with executor is not a real agent"
        )
        XCTAssertNil(
            store.reassignTask(
                teamName: teamName, taskId: id,
                assignee: "executor", assigneeInstanceId: "instance-nope"
            ),
            "an instance nothing registers must not fall back to first match"
        )
    }

    func testAnExplicitInstanceStillRoutesToItsExactSibling() throws {
        let id = try task()

        let updated = try XCTUnwrap(store.updateTask(
            teamName: teamName, taskId: id,
            assignee: "executor", assigneeInstanceId: "instance-b"
        ))
        XCTAssertEqual(updated.assigneeInstanceId, "instance-b", "not the first match")

        let reassigned = try XCTUnwrap(store.reassignTask(
            teamName: teamName, taskId: id,
            assignee: "executor", assigneeInstanceId: "instance-a"
        ))
        XCTAssertEqual(reassigned.assigneeInstanceId, "instance-a")
    }

    /// Naming an instance without a name asserts who holds the task, and the
    /// store still refuses when that is somebody else. The socket turns this
    /// into `task_identity_mismatch` rather than `not_found`.
    func testAnInstanceOnlyUpdateStillHasToBeTheHolder() throws {
        let id = try task()
        _ = try XCTUnwrap(store.updateTask(
            teamName: teamName, taskId: id,
            assignee: "executor", assigneeInstanceId: "instance-b"
        ))

        XCTAssertNil(
            store.updateTask(
                teamName: teamName, taskId: id,
                status: "completed", assigneeInstanceId: "instance-a"
            ),
            "instance-a does not hold this task"
        )
        XCTAssertNotNil(
            store.updateTask(
                teamName: teamName, taskId: id,
                status: "completed", assigneeInstanceId: "instance-b"
            )
        )
    }

    // MARK: - The unique-name case is untouched

    func testAUniqueNameBehavesExactlyAsBefore() throws {
        let id = try task(assignedTo: nil)

        let updated = try XCTUnwrap(
            store.updateTask(teamName: teamName, taskId: id, assignee: "reviewer")
        )
        XCTAssertEqual(updated.assignee, "reviewer")
        XCTAssertEqual(updated.assigneeInstanceId, "instance-r")

        let reassigned = try XCTUnwrap(
            store.reassignTask(teamName: teamName, taskId: id, assignee: "reviewer")
        )
        XCTAssertEqual(reassigned.assigneeInstanceId, "instance-r")
    }

    /// Unassigning stays possible — `reassignTask(assignee: nil)` is how a task
    /// goes back into the pool.
    func testUnassigningStillReturnsATaskToTheQueue() throws {
        let id = try task()

        let reassigned = try XCTUnwrap(
            store.reassignTask(teamName: teamName, taskId: id, assignee: nil)
        )
        XCTAssertNil(reassigned.assignee)
        XCTAssertNil(reassigned.assigneeInstanceId)
        XCTAssertEqual(reassigned.status, "queued")
    }
}
