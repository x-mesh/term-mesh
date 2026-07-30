import XCTest
@testable import PeerProto

final class PeerIdentityTests: XCTestCase {
    func testLoadOrCreateFirstCallCreates() throws {
        let service = testServiceName()
        defer { try? PeerIdentity.deleteStoredIdentity(service: service, account: PeerIdentity.account) }

        let id = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)

        XCTAssertEqual(id.count, PeerIdentity.byteCount)
        XCTAssertNotEqual(id, Data(count: PeerIdentity.byteCount))
    }

    func testLoadOrCreateIdempotent() throws {
        let service = testServiceName()
        defer { try? PeerIdentity.deleteStoredIdentity(service: service, account: PeerIdentity.account) }

        let first = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)
        let second = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)

        XCTAssertEqual(first, second)
    }

    func testRegenerateReplaces() throws {
        let service = testServiceName()
        defer { try? PeerIdentity.deleteStoredIdentity(service: service, account: PeerIdentity.account) }

        let first = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)
        let regenerated = try PeerIdentity.regenerate(service: service, account: PeerIdentity.account)
        let loaded = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)

        XCTAssertEqual(regenerated.count, PeerIdentity.byteCount)
        XCTAssertNotEqual(first, regenerated)
        XCTAssertEqual(regenerated, loaded)
    }

    func testPeerSessionOptionsDefaultUsesStablePeerID() {
        let options = PeerSessionOptions()

        XCTAssertEqual(options.peerID.count, PeerIdentity.byteCount)
        XCTAssertNotEqual(options.peerID, Data(count: PeerIdentity.byteCount))
    }

    // MARK: - Ephemeral identity gating

    func testEphemeralWhenBundleIsADevBuild() {
        XCTAssertTrue(ephemeral(bundle: "com.termmesh.app.debug"))
        XCTAssertTrue(ephemeral(bundle: "com.termmesh.app.debug.distributed.workspaces"))
    }

    func testKeychainUsedForReleaseBundle() {
        XCTAssertFalse(ephemeral(bundle: "com.termmesh.app"))
        XCTAssertFalse(ephemeral(bundle: nil))
    }

    /// An `xcodebuild test` run launches the dev app without the env var
    /// `reload.sh` injects, and a keychain prompt there deadlocks startup.
    func testEphemeralUnderXCTestEvenForReleaseBundle() {
        XCTAssertTrue(ephemeral(bundle: "com.termmesh.app", isRunningTests: true))
    }

    func testEnvironmentOverridesBothWays() {
        XCTAssertTrue(ephemeral(
            env: ["TERMMESH_PEER_IDENTITY_EPHEMERAL": "1"],
            bundle: "com.termmesh.app"
        ))
        // Opt back in when a dev loop needs a peer ID stable across launches.
        XCTAssertFalse(ephemeral(
            env: ["TERMMESH_PEER_IDENTITY_KEYCHAIN": "1"],
            bundle: "com.termmesh.app.debug",
            isRunningTests: true
        ))
    }

    private func ephemeral(
        env: [String: String] = [:],
        bundle: String?,
        isRunningTests: Bool = false
    ) -> Bool {
        PeerIdentity.usesEphemeralIdentity(
            environment: env,
            bundleIdentifier: bundle,
            isRunningTests: isRunningTests
        )
    }

    private func testServiceName() -> String {
        "com.termmesh.peer-identity.tests.\(UUID().uuidString)"
    }
}
