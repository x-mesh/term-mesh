import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class DelegateDedupP1Tests: XCTestCase {
    private let store = TeamDataStore.shared
    private var teamNames: [String] = []

    override func tearDown() {
        for teamName in teamNames {
            store.unregisterTeam(teamName)
        }
        teamNames.removeAll()
        super.tearDown()
    }

    private func registerTeam() -> String {
        let name = "delegate-dedup-\(UUID().uuidString)"
        store.registerTeam(name, agentNames: ["executor"])
        teamNames.append(name)
        return name
    }

    func testSameRequestIdCreatesExactlyOneTask() throws {
        let team = registerTeam()

        let first = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: "request-1"
        ))
        let retry = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work retry", assignee: "executor",
            requestId: "request-1"
        ))

        XCTAssertEqual(retry.id, first.id)
        XCTAssertEqual(store.listTasks(teamName: team).count, 1)
    }

    func testNilRequestIdPreservesNonDeduplicatedCreation() throws {
        let team = registerTeam()

        let first = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: nil
        ))
        let second = try XCTUnwrap(store.createTask(
            teamName: team, title: "delegate work", assignee: "executor",
            requestId: nil
        ))

        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(store.listTasks(teamName: team).count, 2)
    }

    func testSameRequestIdDoesNotDeduplicateAcrossTeams() throws {
        let firstTeam = registerTeam()
        let secondTeam = registerTeam()

        let first = try XCTUnwrap(store.createTask(
            teamName: firstTeam, title: "delegate work", assignee: "executor",
            requestId: "shared-request"
        ))
        let second = try XCTUnwrap(store.createTask(
            teamName: secondTeam, title: "delegate work", assignee: "executor",
            requestId: "shared-request"
        ))

        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(store.listTasks(teamName: firstTeam).count, 1)
        XCTAssertEqual(store.listTasks(teamName: secondTeam).count, 1)
    }
}
