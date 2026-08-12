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
        XCTAssertEqual(try PeerIdentity.loadPreviousIDs(service: service, account: PeerIdentity.account), [first])
    }

    func testRepeatedDebugRegenerationRetainsBoundedOwnershipHistory() throws {
        let suite = "com.termmesh.peer-identity.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var expected: [Data] = []
        var current = try PeerIdentity.loadOrCreateDebugIdentity(defaults: defaults)

        for _ in 0..<(PeerIdentity.historyLimit + 2) {
            expected.insert(current, at: 0)
            expected = Array(expected.prefix(PeerIdentity.historyLimit))
            let regenerated = try PeerIdentity.regenerateDebugIdentity(defaults: defaults)
            current = regenerated.id
            XCTAssertEqual(regenerated.history, expected)
        }

        XCTAssertEqual(PeerIdentity.loadDebugHistory(defaults: defaults), expected)
    }

    func testPeerSessionOptionsDefaultUsesStablePeerID() {
        let options = PeerSessionOptions()

        XCTAssertEqual(options.peerID.count, PeerIdentity.byteCount)
        XCTAssertNotEqual(options.peerID, Data(count: PeerIdentity.byteCount))
        XCTAssertLessThanOrEqual(options.projectOwnerAliases.count, PeerIdentity.historyLimit)
    }

    // MARK: - Development identity storage

    func testDebugBundleUsesDefaultsInsteadOfEphemeralIdentity() {
        XCTAssertFalse(ephemeral(bundle: "com.termmesh.app.debug"))
        XCTAssertTrue(debugDefaults(bundle: "com.termmesh.app.debug"))
        XCTAssertTrue(debugDefaults(bundle: "com.termmesh.app.debug.distributed.workspaces"))
        XCTAssertNotEqual(
            PeerIdentity.debugDefaultsSuiteName(bundleIdentifier: "com.termmesh.app.debug.one"),
            PeerIdentity.debugDefaultsSuiteName(bundleIdentifier: "com.termmesh.app.debug.two")
        )
        XCTAssertEqual(
            PeerIdentity.debugDefaultsSuiteName(bundleIdentifier: "com.termmesh.app.debug.one"),
            PeerIdentity.debugDefaultsSuiteName(bundleIdentifier: "com.termmesh.app.debug.one")
        )
    }

    func testKeychainUsedForReleaseBundle() {
        XCTAssertFalse(ephemeral(bundle: "com.termmesh.app"))
        XCTAssertFalse(debugDefaults(bundle: "com.termmesh.app"))
        XCTAssertFalse(ephemeral(bundle: nil))
        XCTAssertFalse(debugDefaults(bundle: nil))
    }

    /// An `xcodebuild test` run launches the dev app without the env var
    /// `reload.sh` injects, and a keychain prompt there deadlocks startup.
    func testEphemeralUnderXCTestEvenForReleaseBundle() {
        XCTAssertTrue(ephemeral(bundle: "com.termmesh.app", isRunningTests: true))
        XCTAssertFalse(debugDefaults(bundle: "com.termmesh.app.debug", isRunningTests: true))
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
        XCTAssertFalse(debugDefaults(
            env: ["TERMMESH_PEER_IDENTITY_KEYCHAIN": "1"],
            bundle: "com.termmesh.app.debug",
            isRunningTests: true
        ))
    }

    func testDebugDefaultsIdentityPersists() throws {
        let suite = "com.termmesh.peer-identity.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = try PeerIdentity.loadOrCreateDebugIdentity(defaults: defaults)
        let second = try PeerIdentity.loadOrCreateDebugIdentity(defaults: defaults)

        XCTAssertEqual(first.count, PeerIdentity.byteCount)
        XCTAssertNotEqual(first, Data(count: PeerIdentity.byteCount))
        XCTAssertEqual(first, second)
    }

    func testDebugDefaultsIdentityRepairsInvalidStoredValue() throws {
        let suite = "com.termmesh.peer-identity.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1, 2, 3]), forKey: PeerIdentity.debugDefaultsKey)

        let repaired = try PeerIdentity.loadOrCreateDebugIdentity(defaults: defaults)

        XCTAssertEqual(repaired.count, PeerIdentity.byteCount)
        XCTAssertEqual(defaults.data(forKey: PeerIdentity.debugDefaultsKey), repaired)
    }

    private func ephemeral(
        env: [String: String] = [:],
        bundle: String?,
        isRunningTests: Bool = false
    ) -> Bool {
        PeerIdentity.usesEphemeralIdentity(
            environment: env,
            isRunningTests: isRunningTests
        )
    }

    private func debugDefaults(
        env: [String: String] = [:],
        bundle: String?,
        isRunningTests: Bool = false
    ) -> Bool {
        PeerIdentity.usesDebugDefaultsIdentity(
            environment: env,
            bundleIdentifier: bundle,
            isRunningTests: isRunningTests
        )
    }

    private func testServiceName() -> String {
        "com.termmesh.peer-identity.tests.\(UUID().uuidString)"
    }
}
