import Foundation
import PeerProto
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class InstanceRoutingRegression169Tests: XCTestCase {
    private var teamName = ""
    private let store = TeamDataStore.shared

    override func setUp() {
        super.setUp()
        teamName = "instance-routing-\(UUID().uuidString)"
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

    func testExplicitInstanceRoutesCreateUpdateAndReassignToExactSibling() throws {
        let created = try XCTUnwrap(store.createTask(
            teamName: teamName,
            title: "route exact instance",
            assignee: "executor",
            assigneeInstanceId: "instance-b"
        ))
        XCTAssertEqual(created.assigneeInstanceId, "instance-b")

        let updated = try XCTUnwrap(store.updateTask(
            teamName: teamName,
            taskId: created.id,
            assignee: "executor",
            assigneeInstanceId: "instance-a"
        ))
        XCTAssertEqual(updated.assigneeInstanceId, "instance-a")

        let reassigned = try XCTUnwrap(store.reassignTask(
            teamName: teamName,
            taskId: created.id,
            assignee: "executor",
            assigneeInstanceId: "instance-b"
        ))
        XCTAssertEqual(reassigned.assigneeInstanceId, "instance-b")
    }

    func testMismatchedNameAndInstanceIsRejectedWithoutMutation() throws {
        XCTAssertNil(store.createTask(
            teamName: teamName,
            title: "reject create mismatch",
            assignee: "reviewer",
            assigneeInstanceId: "instance-a"
        ))

        let created = try XCTUnwrap(store.createTask(
            teamName: teamName,
            title: "reject mismatch",
            assignee: "reviewer",
            assigneeInstanceId: "instance-r"
        ))

        XCTAssertNil(store.updateTask(
            teamName: teamName,
            taskId: created.id,
            assignee: "reviewer",
            assigneeInstanceId: "instance-a"
        ))
        XCTAssertNil(store.reassignTask(
            teamName: teamName,
            taskId: created.id,
            assignee: "reviewer",
            assigneeInstanceId: "instance-b"
        ))

        let unchanged = try XCTUnwrap(store.getTask(teamName: teamName, taskId: created.id))
        XCTAssertEqual(unchanged.assignee, "reviewer")
        XCTAssertEqual(unchanged.assigneeInstanceId, "instance-r")
    }

    /// Naming a role is not naming an instance, and all three verbs read it the
    /// same way.
    ///
    /// `create` always auto-pinned the first of several agents answering to a
    /// name; `update` and `reassign` briefly did not, and refused instead. They
    /// answer nil that way and the sockets above them read nil as "Task not
    /// found", so an ordinary `tm-agent task update` reported a task plainly on
    /// the board as missing and the Review Queue's Reject button sent work back
    /// to nobody. Where the caller names a role, all three are lenient.
    func testNameOnlyIsLenientAcrossCreateUpdateAndReassign() throws {
        let autoPinned = try XCTUnwrap(store.createTask(
            teamName: teamName,
            title: "ambiguous create",
            assignee: "executor"
        ))
        XCTAssertEqual(autoPinned.assigneeInstanceId, "instance-a", "first match")

        let task = try XCTUnwrap(store.createTask(
            teamName: teamName,
            title: "unique create",
            assignee: "reviewer"
        ))
        XCTAssertEqual(task.assigneeInstanceId, "instance-r")

        let reassigned = try XCTUnwrap(
            store.reassignTask(teamName: teamName, taskId: task.id, assignee: "executor"),
            "a name on its own reassigns; refusing it broke rejecting a review"
        )
        XCTAssertEqual(reassigned.assigneeInstanceId, "instance-a")

        let updated = try XCTUnwrap(
            store.updateTask(teamName: teamName, taskId: task.id, assignee: "executor"),
            "a name on its own updates; refusing it answered not_found for a task that is there"
        )
        XCTAssertEqual(updated.assigneeInstanceId, "instance-a")

        XCTAssertEqual(
            store.getTask(teamName: teamName, taskId: task.id)?.assigneeInstanceId,
            "instance-a",
            "the mutation landed, on the first agent answering to that name"
        )
    }

    /// The lenient path must not be a way around the strict one.
    ///
    /// This is the half worth stating separately, because it is the half that
    /// would be quietly lost: leniency belongs to callers who named a *role*.
    /// A caller who named an instance made a claim about which agent this is,
    /// and a claim that does not hold is refused rather than rounded to a
    /// sibling — even on a task that a name-only call has already moved.
    func testLenientNameOnlyDoesNotWeakenExplicitInstanceChecking() throws {
        let task = try XCTUnwrap(store.createTask(
            teamName: teamName, title: "lenient then strict", assignee: "reviewer"
        ))
        // The lenient path, first — so what follows is checked against a task
        // that got here without ever naming an instance.
        _ = try XCTUnwrap(
            store.updateTask(teamName: teamName, taskId: task.id, assignee: "executor")
        )

        XCTAssertNil(
            store.updateTask(
                teamName: teamName, taskId: task.id,
                assignee: "executor", assigneeInstanceId: "instance-r"
            ),
            "instance-r is the reviewer; pairing it with executor is not a real agent"
        )
        XCTAssertNil(
            store.reassignTask(
                teamName: teamName, taskId: task.id,
                assignee: "reviewer", assigneeInstanceId: "instance-a"
            ),
            "naming an instance is a claim, and this one does not hold"
        )
        XCTAssertNil(
            store.updateTask(
                teamName: teamName, taskId: task.id,
                assignee: "executor", assigneeInstanceId: "instance-nope"
            ),
            "an instance nothing registers must not fall back to the first match"
        )

        XCTAssertEqual(
            store.getTask(teamName: teamName, taskId: task.id)?.assigneeInstanceId,
            "instance-a",
            "every refusal above left the task exactly where the lenient call put it"
        )
    }

    func testHostWithoutTeamsStillAdvertisesTeamCapabilities() async throws {
        let socketPath = "/tmp/tm-peer-empty-team-caps-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = PeerServer(socketPath: socketPath, provider: EmptyTeamProvider169())
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: socketPath) {
            if Date() > deadline {
                return XCTFail("peer socket was not created")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: socketPath)
        let session = PeerSession(transport: transport)
        let hello = try await session.handshake()
        XCTAssertTrue(hello.hasHostCapability(PeerCapability.teamRosterV1))
        XCTAssertTrue(hello.hasHostCapability(PeerCapability.teamCallV1))
        XCTAssertTrue(hello.hasHostCapability(PeerCapability.teamLeaderV1))
        await transport.close()
    }
}

private actor EmptyTeamProvider169: PeerSurfaceProvider {
    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] { [] }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? { nil }

    func listTeams() async -> [Termmesh_Peer_V1_Team] { [] }
}
