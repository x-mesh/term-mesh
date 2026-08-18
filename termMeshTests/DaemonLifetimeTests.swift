import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A daemon that dies with its app cannot hold a session for anybody, which is
/// why quitting term-mesh on a peer ends a project placed there: the work
/// exists only inside that app's process tree.
///
/// The mechanism to decouple already existed — omit `TERMMESH_OWNER_PID` and
/// the daemon's `wait_for_owner_exit` waits forever — so what was missing was
/// deciding when to use it. These tests hold that decision still, because both
/// answers are wrong somewhere: a daemon that always survives is the leak
/// `TERMMESH_OWNER_PID` was added to stop, and one that never does cannot serve.
final class DaemonLifetimeTests: XCTestCase {

    /// Serving peers is the case where another machine may come back to a
    /// session, so it is the case that decouples.
    func test_aMachineServingPeersKeepsItsDaemon() {
        XCTAssertTrue(TermMeshDaemon.daemonShouldOutliveApp(peerServingEnabled: true))
    }

    /// With nobody to serve, a daemon outliving a crash or a forced reload is
    /// exactly the leak the owner-pid tie was added to prevent — not a feature.
    func test_aMachineServingNobodyKeepsTheOldContract() {
        XCTAssertFalse(TermMeshDaemon.daemonShouldOutliveApp(peerServingEnabled: false))
    }

    /// The decision must come from the argument alone. Reading the live setting
    /// inside would make it untestable and would couple the answer to whatever
    /// this machine happens to have configured while a test runs.
    func test_theDecisionIsAFunctionOfItsInputOnly() {
        for _ in 0..<3 {
            XCTAssertTrue(TermMeshDaemon.daemonShouldOutliveApp(peerServingEnabled: true))
            XCTAssertFalse(TermMeshDaemon.daemonShouldOutliveApp(peerServingEnabled: false))
        }
    }

    // MARK: - Adopting a daemon that is not this build

    /// Adoption trusts whatever answers the socket, which is what lets a
    /// session survive a quit — and what let a released app run for hours
    /// against a leftover Debug daemon from a test harness. Keep the
    /// adoption; refuse the silence.
    func test_adoptingADifferentVersionWarnsAndNamesBothSides() {
        let warning = TermMeshDaemon.adoptedDaemonVersionWarning(
            runningVersion: "0.185.2", appVersion: "0.188.0"
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("0.185.2"))
        XCTAssertTrue(warning!.contains("0.188.0"))
        XCTAssertTrue(
            warning!.contains("Quit every term-mesh"),
            "a single app quit does not replace a daemon built to outlive it"
        )
    }

    /// Silence is only correct when there is nothing to say. An unknown
    /// version is not evidence of a mismatch — a daemon too old to answer
    /// `daemon.status`, or one that dropped the call, must not be reported as
    /// the wrong build.
    func test_matchingOrUnknownVersionsProduceNoWarning() {
        XCTAssertNil(TermMeshDaemon.adoptedDaemonVersionWarning(
            runningVersion: "0.188.0", appVersion: "0.188.0"
        ))
        XCTAssertNil(TermMeshDaemon.adoptedDaemonVersionWarning(
            runningVersion: nil, appVersion: "0.188.0"
        ))
        XCTAssertNil(TermMeshDaemon.adoptedDaemonVersionWarning(
            runningVersion: "", appVersion: "0.188.0"
        ))
        XCTAssertNil(TermMeshDaemon.adoptedDaemonVersionWarning(
            runningVersion: "0.185.2", appVersion: nil
        ))
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
/// later. The first version made it unconditionally: the guard read
/// `daemonShouldOutliveApp(peerServingEnabled: true)`, which is `true` by
/// inspection, so every host advertised an owner whether or not it had one.
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
