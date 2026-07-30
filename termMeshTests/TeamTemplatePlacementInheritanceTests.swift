import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Placement — which machine a team member runs on, and where on that
/// machine — has two moving parts covered here:
///
/// 1. `SavedTeamTemplate.AgentSlot.hostKey`/`hostDirectory` are optional
///    specifically so a template saved before mixed (multi-host) teams
///    existed still decodes (see the doc comment on those properties).
/// 2. `RemoteProjectPaths` is the "inherit what worked last time" half of
///    `TeamAgentComposer.defaultDirectory(forHost:excluding:)` — the part of
///    that lookup chain reachable without going through the SwiftUI view.
@MainActor
final class TeamTemplatePlacementInheritanceTests: XCTestCase {

    // MARK: - AgentSlot backward-compatible decoding

    /// A slot serialized before mixed teams existed has no host fields at
    /// all. Both are optional for exactly this reason, and Swift's
    /// synthesized `Decodable` treats a missing key on an Optional property
    /// as `decodeIfPresent` — this pins that down instead of trusting it.
    func testAgentSlotDecodesLegacyJSONWithoutHostFields() throws {
        let json = """
        {
            "roleName": "executor",
            "cli": "claude",
            "model": "sonnet",
            "customInstructions": ""
        }
        """
        let slot = try JSONDecoder().decode(SavedTeamTemplate.AgentSlot.self, from: Data(json.utf8))

        XCTAssertEqual(slot.roleName, "executor")
        XCTAssertNil(slot.hostKey, "a pre-mixed-team slot has no host — must decode as nil, not fail")
        XCTAssertNil(slot.hostDirectory)
    }

    /// The same, at the whole-template level: a template with several
    /// pre-mixed-team slots must decode entirely, every slot local (nil host).
    func testSavedTeamTemplateDecodesLegacyTemplateWithoutHostFields() throws {
        let json = """
        {
            "id": "8C2E6E5E-9E9E-4B3D-8B37-8B7C2D6A0000",
            "name": "Default",
            "leaderMode": "repl",
            "agents": [
                {"roleName": "executor", "cli": "claude", "model": "sonnet", "customInstructions": ""},
                {"roleName": "reviewer", "cli": "codex", "model": "opus", "customInstructions": "be terse"}
            ]
        }
        """
        let template = try JSONDecoder().decode(SavedTeamTemplate.self, from: Data(json.utf8))

        XCTAssertEqual(template.agents.count, 2)
        XCTAssertTrue(template.agents.allSatisfy { $0.hostKey == nil && $0.hostDirectory == nil })
    }

    /// Regression guard in the other direction: once a slot does carry a
    /// placement, it must round-trip exactly rather than being quietly
    /// dropped by some future hand-written Codable conformance.
    func testAgentSlotRoundTripsHostPlacementWhenPresent() throws {
        let slot = SavedTeamTemplate.AgentSlot(
            roleName: "builder", cli: "claude", model: "sonnet", customInstructions: "",
            hostKey: "jw-server", hostDirectory: "/root/build"
        )
        let data = try JSONEncoder().encode(slot)
        let decoded = try JSONDecoder().decode(SavedTeamTemplate.AgentSlot.self, from: data)

        XCTAssertEqual(decoded, slot)
        XCTAssertEqual(decoded.hostKey, "jw-server")
        XCTAssertEqual(decoded.hostDirectory, "/root/build")
    }

    // MARK: - RemoteProjectPaths (the "remembered" half of placement inheritance)

    /// `RemoteProjectPaths` is a `private init()` singleton over
    /// `UserDefaults.standard` with no reset/removal API, so these tests run
    /// against the live shared instance rather than an isolated one — a gap
    /// called out in the report rather than worked around with a production
    /// edit. UUID-namespaced host/root values keep this from colliding with
    /// any real remembered path, and the persisted key is restored in
    /// tearDown the same way `ReviewBoardVisibilityTests` already does for
    /// `UserDefaults.standard`.
    private static let remoteProjectPathsKey = "termmesh.remoteProjectPaths"
    private var savedRemoteProjectPaths: Any?

    override func setUp() {
        super.setUp()
        savedRemoteProjectPaths = UserDefaults.standard.object(forKey: Self.remoteProjectPathsKey)
    }

    override func tearDown() {
        if let savedRemoteProjectPaths {
            UserDefaults.standard.set(savedRemoteProjectPaths, forKey: Self.remoteProjectPathsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.remoteProjectPathsKey)
        }
        super.tearDown()
    }

    func testRemoteProjectPathsRemembersAndReturnsPathForHostAndRoot() {
        let host = "host-\(UUID().uuidString)"
        let localRoot = "/tmp/\(UUID().uuidString)"

        XCTAssertNil(RemoteProjectPaths.shared.path(host: host, localRoot: localRoot))

        RemoteProjectPaths.shared.remember(host: host, localRoot: localRoot, path: "/remote/proj")

        XCTAssertEqual(RemoteProjectPaths.shared.path(host: host, localRoot: localRoot), "/remote/proj")
    }

    /// Keyed by (host, localRoot) together — a path remembered for one
    /// project must not leak into the lookup for a different local checkout
    /// on the same host.
    func testRemoteProjectPathsIsScopedToHostAndLocalRootPairTogether() {
        let host = "host-\(UUID().uuidString)"
        let rootA = "/tmp/\(UUID().uuidString)"
        let rootB = "/tmp/\(UUID().uuidString)"

        RemoteProjectPaths.shared.remember(host: host, localRoot: rootA, path: "/remote/a")

        XCTAssertEqual(RemoteProjectPaths.shared.path(host: host, localRoot: rootA), "/remote/a")
        XCTAssertNil(RemoteProjectPaths.shared.path(host: host, localRoot: rootB))
    }

    /// `anyPath` is the last-resort fallback — any project this host has
    /// ever been given, so a brand new project at least lands in the right
    /// neighbourhood.
    func testRemoteProjectPathsAnyPathFallsBackToAnyRememberedProjectOnThatHost() {
        let host = "host-\(UUID().uuidString)"
        let localRoot = "/tmp/\(UUID().uuidString)"

        XCTAssertNil(RemoteProjectPaths.shared.anyPath(host: host))

        RemoteProjectPaths.shared.remember(host: host, localRoot: localRoot, path: "/remote/whatever")

        XCTAssertEqual(RemoteProjectPaths.shared.anyPath(host: host), "/remote/whatever")
    }

    /// Blank input is refused rather than remembered as an empty string,
    /// which would otherwise satisfy `path(host:localRoot:)`'s non-empty
    /// guard incorrectly on the next lookup.
    func testRemoteProjectPathsIgnoresBlankHostLocalRootOrPath() {
        let host = "host-\(UUID().uuidString)"
        let localRoot = "/tmp/\(UUID().uuidString)"

        RemoteProjectPaths.shared.remember(host: "", localRoot: localRoot, path: "/remote/x")
        RemoteProjectPaths.shared.remember(host: host, localRoot: "", path: "/remote/x")
        RemoteProjectPaths.shared.remember(host: host, localRoot: localRoot, path: "   ")

        XCTAssertNil(RemoteProjectPaths.shared.path(host: host, localRoot: localRoot))
    }
}
