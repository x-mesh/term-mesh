import XCTest
@testable import PeerProto

final class PeerIdentityTests: XCTestCase {
    func testFileMigrationPreservesIdentityAndHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(PeerIdentity.identityFileName)
        let legacyID = Data(repeating: 0x11, count: PeerIdentity.byteCount)
        let legacyHistory = [
            Data(repeating: 0x22, count: PeerIdentity.byteCount),
            Data(repeating: 0x33, count: PeerIdentity.byteCount),
        ]

        let migrated = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: { legacyID },
            legacyHistoryLoader: { legacyHistory }
        )

        XCTAssertEqual(migrated.id, legacyID)
        XCTAssertEqual(migrated.history, legacyHistory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testExistingFileWinsWithoutConsultingKeychain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(PeerIdentity.identityFileName)
        let expected = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: { nil },
            legacyHistoryLoader: { [] }
        )

        let loaded = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: {
                XCTFail("existing file must bypass the Keychain identity loader")
                return nil
            },
            legacyHistoryLoader: {
                XCTFail("existing file must bypass the Keychain history loader")
                return []
            }
        )

        XCTAssertEqual(loaded.id, expected.id)
        XCTAssertEqual(loaded.history, expected.history)
    }

    func testNewFileIdentityIsStableAndOwnerOnly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(PeerIdentity.identityFileName)

        let first = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: { nil },
            legacyHistoryLoader: { [] }
        )
        let second = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: { nil },
            legacyHistoryLoader: { [] }
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id.count, PeerIdentity.byteCount)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDeniedLegacyMigrationStillCreatesStableFileIdentity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(PeerIdentity.identityFileName)
        var legacyLoadCount = 0

        func load() throws -> Data? {
            legacyLoadCount += 1
            throw PeerIdentityError.keychainReadFailed(errSecAuthFailed)
        }

        let first = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: { try load() },
            legacyHistoryLoader: {
                XCTFail("history must not be read after the legacy identity is unavailable")
                return []
            }
        )
        let second = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: { try load() },
            legacyHistoryLoader: { [] }
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(legacyLoadCount, 1)
    }

    func testCorruptFileRepairsFromLegacyIdentity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(PeerIdentity.identityFileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)
        let legacyID = Data(repeating: 0x44, count: PeerIdentity.byteCount)
        let legacyHistory = [Data(repeating: 0x55, count: PeerIdentity.byteCount)]

        let repaired = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: { legacyID },
            legacyHistoryLoader: { legacyHistory }
        )
        let reloaded = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: {
                XCTFail("repaired file must bypass the legacy identity loader")
                return nil
            },
            legacyHistoryLoader: {
                XCTFail("repaired file must bypass the legacy history loader")
                return []
            }
        )

        XCTAssertEqual(repaired.id, legacyID)
        XCTAssertEqual(repaired.history, legacyHistory)
        XCTAssertEqual(reloaded.id, legacyID)
        XCTAssertEqual(reloaded.history, legacyHistory)
    }

    func testInvalidHistoryKeepsValidCurrentIdentity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(PeerIdentity.identityFileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Data(repeating: 0x66, count: PeerIdentity.byteCount)
        let invalidHistory = Data([0x77]).base64EncodedString()
        let encodedID = id.base64EncodedString()
        try Data("{\"version\":1,\"id\":\"\(encodedID)\",\"history\":[\"\(invalidHistory)\"]}".utf8)
            .write(to: fileURL)

        let loaded = try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: {
                XCTFail("a valid current ID must not fall back to legacy storage")
                return nil
            },
            legacyHistoryLoader: { [] }
        )

        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.history, [])
    }

    func testReadFailureDoesNotOverwriteExistingPath() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(PeerIdentity.identityFileName)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: {
                XCTFail("I/O failure must not fall back to legacy storage")
                return nil
            },
            legacyHistoryLoader: { [] }
        )) { error in
            guard case PeerIdentityError.fileReadFailed = error else {
                return XCTFail("expected fileReadFailed, got \(error)")
            }
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testUnsupportedVersionIsNotDowngraded() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(PeerIdentity.identityFileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Data(repeating: 0x88, count: PeerIdentity.byteCount).base64EncodedString()
        let original = Data("{\"version\":2,\"id\":\"\(id)\",\"history\":[]}".utf8)
        try original.write(to: fileURL)

        XCTAssertThrowsError(try PeerIdentity.loadOrCreateFileIdentity(
            at: fileURL,
            legacyIdentityLoader: {
                XCTFail("unknown versions must not fall back to legacy storage")
                return nil
            },
            legacyHistoryLoader: { [] }
        ))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

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

    func testPersistentStorageUsedForReleaseBundle() {
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-identity-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
