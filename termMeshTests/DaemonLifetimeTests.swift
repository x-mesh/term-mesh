import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Runtime ownership and durable peer capability are independent of the GUI
/// peer-server Auto-start preference.
final class DaemonLifetimeTests: XCTestCase {

    /// The daemon serializes `UsageTickAgent` with serde's field names, so the
    /// two cache counters arrive as `cache_read_input_tokens` and
    /// `cache_creation_input_tokens`. Reading the Swift property spelling
    /// instead returned 0 for both without any decode error.
    func test_usageTickCacheCountersDecodeFromTheDaemonWireNames() {
        let now = Date()
        let parsed = TermMeshDaemon.parseUsageTickAgents(
            [[
                "name": "explorer",
                "input_tokens": NSNumber(value: 8200),
                "output_tokens": NSNumber(value: 1300),
                "cache_read_input_tokens": NSNumber(value: 22000),
                "cache_creation_input_tokens": NSNumber(value: 13000),
            ]],
            now: now
        )

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "explorer")
        XCTAssertEqual(parsed.first?.snapshot.inputTokens, 8200)
        XCTAssertEqual(parsed.first?.snapshot.outputTokens, 1300)
        XCTAssertEqual(parsed.first?.snapshot.cacheReadTokens, 22000)
        XCTAssertEqual(parsed.first?.snapshot.cacheCreationTokens, 13000)
    }

    /// The Swift property spelling is not a second accepted name. Keeping this
    /// explicit stops a future edit from "fixing" the mismatch by accepting
    /// both and hiding which side is actually wrong.
    func test_usageTickIgnoresTheSwiftPropertySpellingForCacheCounters() {
        let parsed = TermMeshDaemon.parseUsageTickAgents(
            [[
                "name": "explorer",
                "cache_read_tokens": NSNumber(value: 22000),
                "cache_creation_tokens": NSNumber(value: 13000),
            ]],
            now: Date()
        )

        XCTAssertEqual(parsed.first?.snapshot.cacheReadTokens, 0)
        XCTAssertEqual(parsed.first?.snapshot.cacheCreationTokens, 0)
    }

    func test_spawnEnvironmentAlwaysConfiguresOwnerAndBuildScopedPeerSocket() {
        let environment = TermMeshDaemon.daemonEnvironment(
            processEnvironment: ["UNCHANGED": "yes"],
            ownerPID: 1234,
            peerSocketPath: "/tmp/term-meshd-dev-tag-peer.sock"
        )
        XCTAssertEqual(environment["UNCHANGED"], "yes")
        XCTAssertEqual(environment["TERMMESH_OWNER_PID"], "1234")
        XCTAssertEqual(
            environment["TERMMESH_PEER_SOCKET"],
            "/tmp/term-meshd-dev-tag-peer.sock"
        )
    }

    // MARK: - Replacing a daemon that is not this build

    func test_aKnownVersionMismatchRequiresDaemonReplacement() {
        XCTAssertTrue(TermMeshDaemon.daemonRequiresUpgrade(
            runningVersion: "0.194.0", appVersion: "0.195.0"
        ))
        XCTAssertFalse(TermMeshDaemon.daemonRequiresUpgrade(
            runningVersion: "0.195.0", appVersion: "0.195.0"
        ))
    }

    func test_anUnknownVersionNeverDestroysLiveSessions() {
        XCTAssertFalse(TermMeshDaemon.daemonRequiresUpgrade(
            runningVersion: nil, appVersion: "0.195.0"
        ))
        XCTAssertFalse(TermMeshDaemon.daemonRequiresUpgrade(
            runningVersion: "0.194.0", appVersion: nil
        ))
        XCTAssertFalse(TermMeshDaemon.daemonRequiresUpgrade(
            runningVersion: "", appVersion: "0.195.0"
        ))
    }

    func test_automaticUpgradeRequiresAuthoritativeEmptySurfaceInventory() {
        XCTAssertEqual(
            TermMeshDaemon.automaticUpgradeDecision(
                requiresUpgrade: true, replacementReady: true, liveProjectSurfaces: 0
            ),
            .replace
        )
        XCTAssertEqual(
            TermMeshDaemon.automaticUpgradeDecision(
                requiresUpgrade: true, replacementReady: true, liveProjectSurfaces: 5
            ),
            .preserveLiveSurfaces(5)
        )
        XCTAssertEqual(
            TermMeshDaemon.automaticUpgradeDecision(
                requiresUpgrade: true, replacementReady: true, liveProjectSurfaces: nil
            ),
            .preserveUnknownInventory
        )
    }

    // MARK: - Subscribe-loop watchdog (the one observer of a dead daemon)

    /// Neither an adopted daemon (no Process handle) nor a spawned one (no
    /// termination handler) reports its own death; the subscribe reconnect
    /// loop is the only reliable observer. These pin when that observation
    /// may re-run `startDaemon` — and, just as deliberately, when it must not.
    func test_watchdogRespawnsOnlyAfterSustainedSilence() {
        XCTAssertFalse(TermMeshDaemon.watchdogShouldRespawn(
            consecutiveFailures: TermMeshDaemon.watchdogFailureThreshold - 1,
            runIntended: true, nowNanos: 0, lastRespawnNanos: nil
        ), "a daemon mid-restart is not a dead daemon")
        XCTAssertTrue(TermMeshDaemon.watchdogShouldRespawn(
            consecutiveFailures: TermMeshDaemon.watchdogFailureThreshold,
            runIntended: true, nowNanos: 0, lastRespawnNanos: nil
        ))
    }

    func test_watchdogRespectsADeliberateStop() {
        XCTAssertFalse(TermMeshDaemon.watchdogShouldRespawn(
            consecutiveFailures: 30, runIntended: false,
            nowNanos: 0, lastRespawnNanos: nil
        ), "a Settings stop must stay stopped, however long the socket is silent")
    }

    func test_watchdogDoesNotThrashACrashLoopingDaemon() {
        let interval = TermMeshDaemon.watchdogRespawnIntervalNanos
        XCTAssertFalse(TermMeshDaemon.watchdogShouldRespawn(
            consecutiveFailures: 9, runIntended: true,
            nowNanos: interval - 1, lastRespawnNanos: 0
        ), "inside the interval a failed respawn is not retried on every backoff tick")
        XCTAssertTrue(TermMeshDaemon.watchdogShouldRespawn(
            consecutiveFailures: 9, runIntended: true,
            nowNanos: interval, lastRespawnNanos: 0
        ))
    }
}

/// The daemon has always been able to serve the peer protocol — `main.rs`
/// starts `peer::serve` when `TERMMESH_PEER_SOCKET` names a path, which is how
/// a Linux peer works at all. On a Mac the app took that role and never set the
/// variable, so the one component that can own a session past a quit was the
/// one not serving the protocol that reaches sessions.
final class DaemonPeerSocketTests: XCTestCase {

    /// Derived from the JSON-RPC socket so a tagged build's isolation is
    /// inherited rather than re-earned. Two apps on one machine handing each
    /// other's daemons the same path is the failure this prevents.
    func test_aTaggedBuildKeepsItsIsolation() {
        XCTAssertEqual(
            TermMeshDaemon.daemonPeerSocketPath(forDaemonSocket: "/tmp/term-meshd-dev-projfix.sock"),
            "/tmp/term-meshd-dev-projfix-peer.sock"
        )
        XCTAssertEqual(
            TermMeshDaemon.daemonPeerSocketPath(forDaemonSocket: "/tmp/term-meshd-dev-other.sock"),
            "/tmp/term-meshd-dev-other-peer.sock"
        )
    }

    /// Distinct from the daemon's own JSON-RPC socket: they are different
    /// protocols, and binding one over the other loses whichever lost the race.
    func test_itNeverCollidesWithTheJSONRPCSocket() {
        for socket in ["/tmp/term-meshd.sock",
                       "/var/folders/x/T/term-meshd.sock",
                       "/tmp/term-meshd-dev-tag.sock"] {
            XCTAssertNotEqual(TermMeshDaemon.daemonPeerSocketPath(forDaemonSocket: socket), socket)
        }
    }

    /// A path without the suffix still yields one path, not a truncation.
    func test_aSocketPathWithoutTheSuffixStillDerives() {
        XCTAssertEqual(
            TermMeshDaemon.daemonPeerSocketPath(forDaemonSocket: "/tmp/term-meshd"),
            "/tmp/term-meshd-peer.sock"
        )
    }
}

/// Naming a session owner is a promise that a client can come back to a session
/// later. The answer must come from runtime readiness, not a preference.
final class SessionHostAdvertisementDecisionTests: XCTestCase {

    /// Advertise only what is actually there. Anything else sends a client to a
    /// socket that will refuse it.
    func test_anOwnerIsNamedOnlyWhileSomethingIsListening() {
        XCTAssertEqual(
            TermMeshDaemon.advertisedSessionHostSocket(
                peerSocketPath: "/tmp/term-meshd-peer.sock",
                isListening: { _ in true }
            ),
            "/tmp/term-meshd-peer.sock"
        )
        XCTAssertEqual(
            TermMeshDaemon.advertisedSessionHostSocket(
                peerSocketPath: "/tmp/term-meshd-peer.sock",
                isListening: { _ in false }
            ),
            ""
        )
    }

    /// The decision is about the daemon, not about this app's settings. An
    /// *adopted* daemon was started by an earlier run whose setting nobody here
    /// can read, so a settings-derived guard is wrong even when it is not a
    /// tautology.
    func test_theAnswerComesFromTheSocketRatherThanASetting() {
        var asked: [String] = []
        _ = TermMeshDaemon.advertisedSessionHostSocket(
            peerSocketPath: "/tmp/term-meshd-dev-tag-peer.sock",
            isListening: { asked.append($0); return false }
        )
        XCTAssertEqual(asked, ["/tmp/term-meshd-dev-tag-peer.sock"])
    }

    /// A socket file outlives an uncleanly killed daemon, so existence is not
    /// the question — `connect` is. Nothing listens on either of these.
    func test_aPathWithNothingBehindItIsNotAnOwner() {
        XCTAssertFalse(
            TermMeshDaemon.isListening(atUnixSocketPath: "/tmp/term-mesh-no-such-socket-\(UUID().uuidString).sock")
        )
        // A regular file exists and still has no listener; the old
        // file-existence check would have called this an owner.
        let regularFile = NSTemporaryDirectory() + "not-a-socket-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: regularFile, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: regularFile) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: regularFile))
        XCTAssertFalse(TermMeshDaemon.isListening(atUnixSocketPath: regularFile))
    }

    /// `sun_path` is a fixed 104-byte buffer, and the copy into it is `strcpy`:
    /// an over-long path would smash the stack rather than fail. Refuse it.
    func test_anOverlongPathIsRefusedRatherThanCopied() {
        XCTAssertFalse(TermMeshDaemon.isListening(atUnixSocketPath: "/" + String(repeating: "a", count: 200)))
        XCTAssertFalse(TermMeshDaemon.isListening(atUnixSocketPath: "term-meshd-peer.sock"))
    }

}
