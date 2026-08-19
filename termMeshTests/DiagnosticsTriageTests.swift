import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The values here are the ones measured on the host that produced issue #315,
/// not invented shapes. A triage rule is only worth having if it fires on the
/// evidence that actually occurred.
final class DiagnosticsTriageTests: XCTestCase {
    /// Verbatim from `/proc/<pid>/mountinfo` on the affected host.
    private static let realPrivateTmpRoot =
        "/tmp/systemd-private-d6f07c3d018143c1b7e92c6f185f7c6c-term-meshd.service-J9vZyk/tmp"

    private func host(
        health: PeerHostHealthBaseline?,
        failure: String? = nil
    ) -> PeerHostSnapshot {
        PeerHostSnapshot(
            id: "h1",
            displayName: "builder",
            state: "connected",
            sshTarget: "root@203.0.113.10",
            remoteSockPath: nil,
            activeSockPath: "",
            servingAppVersion: "0.196.0",
            workspaceCount: 0,
            teamCount: 0,
            isLaunchable: true,
            teamHostReadiness: "ready",
            failureReason: failure,
            healthBaseline: health
        )
    }

    /// The shape as measured: service up, peer socket fine, control socket
    /// "missing" only because it lives in a mount namespace the prober cannot
    /// see.
    private func affectedBaseline() -> PeerHostHealthBaseline {
        PeerHostHealthBaseline(
            serviceActive: true,
            daemonTmpRoot: Self.realPrivateTmpRoot,
            controlPath: "/tmp/term-meshd.sock",
            controlPathPresent: false,
            controlRPC: .unavailable,
            peerPath: "/run/term-mesh/tm-peer.sock",
            peerPathPresent: true
        )
    }

    // MARK: - PrivateTmp

    func test_recognisesTheMeasuredPrivateTmpHost() {
        let snapshot = DiagnosticsSnapshot(peerHosts: [host(health: affectedBaseline())])
        let match = DiagnosticsTriage.firstKnownIssue(for: snapshot)
        XCTAssertEqual(match?.0.id, "peer.control-socket.privatetmp")
        XCTAssertEqual(match?.1.number, 315)
        XCTAssertTrue(match?.1.workaround.contains("TERMMESH_DAEMON_UNIX_PATH") == true)
    }

    /// PrivateTmp with the socket somewhere shared is a normal, healthy
    /// hardened install. Firing here would teach people to ignore the panel.
    func test_privateTmpAloneIsNotTheDefect() {
        var baseline = affectedBaseline()
        baseline.controlPath = "/run/term-mesh/term-meshd.sock"
        let snapshot = DiagnosticsSnapshot(peerHosts: [host(health: baseline)])
        XCTAssertTrue(DiagnosticsTriage.signatures(for: snapshot).isEmpty)
    }

    /// A socket under a shared `/tmp` that is genuinely absent is a real
    /// failure — but a different one, and pointing at #315 would send the
    /// reader down the wrong path.
    func test_missingSocketWithoutPrivateTmpIsNotThisIssue() {
        var baseline = affectedBaseline()
        baseline.daemonTmpRoot = "/"
        let snapshot = DiagnosticsSnapshot(peerHosts: [host(health: baseline)])
        XCTAssertTrue(DiagnosticsTriage.signatures(for: snapshot).isEmpty)
    }

    /// A host that reports the socket present is fine no matter what its
    /// `/tmp` looks like.
    func test_presentSocketIsNotTheDefect() {
        var baseline = affectedBaseline()
        baseline.controlPathPresent = true
        let snapshot = DiagnosticsSnapshot(peerHosts: [host(health: baseline)])
        XCTAssertTrue(DiagnosticsTriage.signatures(for: snapshot).isEmpty)
    }

    /// Hosts without a probe result cannot be judged, and guessing from the
    /// absence of evidence is how a report acquires a confident wrong answer.
    func test_hostWithoutABaselineIsNotJudged() {
        let snapshot = DiagnosticsSnapshot(peerHosts: [host(health: nil)])
        XCTAssertTrue(DiagnosticsTriage.signatures(for: snapshot).isEmpty)
    }

    func test_privateTmpDetectionNeedsBothMarkers() {
        XCTAssertTrue(DiagnosticsTriage.isPrivateTmp(Self.realPrivateTmpRoot))
        XCTAssertFalse(DiagnosticsTriage.isPrivateTmp("/"))
        XCTAssertFalse(DiagnosticsTriage.isPrivateTmp(""))
        // Another unit's private tmp is not this daemon's.
        XCTAssertFalse(
            DiagnosticsTriage.isPrivateTmp("/tmp/systemd-private-abc-nginx.service-xyz/tmp")
        )
    }

    // MARK: - Leader RPC collision

    func test_recognisesTheInflightCollisionFromTheActivityLog() {
        let snapshot = DiagnosticsSnapshot(
            activityTail: ["team.status failed: request_id already in flight"]
        )
        let match = DiagnosticsTriage.firstKnownIssue(for: snapshot)
        XCTAssertEqual(match?.0.id, "peer.leader-rpc.inflight-collision")
        XCTAssertEqual(match?.1.number, 314)
        XCTAssertTrue(match?.1.workaround.contains("TERMMESH_RPC_TIMEOUT") == true)
    }

    /// The same evidence reaches the bundle through three different fields
    /// depending on where it was observed; a rule that checked only one would
    /// miss two thirds of the cases.
    func test_theCollisionIsFoundInEveryTextSource() {
        let fromDaemonLog = DiagnosticsSnapshot(
            daemonLogTail: ["request_id already in flight"]
        )
        let fromFailureReason = DiagnosticsSnapshot(
            peerHosts: [host(health: nil, failure: "request_id already in flight")]
        )
        XCTAssertNotNil(DiagnosticsTriage.firstKnownIssue(for: fromDaemonLog))
        XCTAssertNotNil(DiagnosticsTriage.firstKnownIssue(for: fromFailureReason))
    }

    // MARK: - No match

    func test_anOrdinaryBundleMatchesNothing() {
        let snapshot = DiagnosticsSnapshot(
            peerHosts: [host(health: PeerHostHealthBaseline(
                serviceActive: true,
                daemonTmpRoot: "/",
                controlPathPresent: true,
                controlRPC: .available,
                peerPathPresent: true
            ))],
            activityTail: ["connected to host", "opened workspace"]
        )
        XCTAssertTrue(DiagnosticsTriage.signatures(for: snapshot).isEmpty)
        XCTAssertNil(DiagnosticsTriage.firstKnownIssue(for: snapshot))
    }
}

/// The signature has to reach the bundle, and reach it early enough to survive
/// the issue URL's head-first truncation.
@MainActor
final class DiagnosticsSignatureRenderingTests: XCTestCase {
    func test_matchedSignatureAppearsInTheBundleWithItsWorkaround() {
        let baseline = PeerHostHealthBaseline(
            serviceActive: true,
            daemonTmpRoot: "/tmp/systemd-private-abc-term-meshd.service-xyz/tmp",
            controlPath: "/tmp/term-meshd.sock",
            controlPathPresent: false,
            controlRPC: .unavailable,
            peerPathPresent: true
        )
        let snapshot = DiagnosticsSnapshot(peerHosts: [
            PeerHostSnapshot(
                id: "h", displayName: "builder", state: "connected", sshTarget: nil,
                remoteSockPath: nil, activeSockPath: "", servingAppVersion: nil,
                workspaceCount: 0, teamCount: 0, isLaunchable: true,
                teamHostReadiness: "unresolved", failureReason: nil, healthBaseline: baseline
            )
        ])
        let output = DiagnosticsReport.build(snapshot)
        XCTAssertTrue(output.contains("peer.control-socket.privatetmp"))
        XCTAssertTrue(output.contains("known issue: #315"))
        XCTAssertTrue(output.contains("TERMMESH_DAEMON_UNIX_PATH"))
    }

    /// "Checked, no match" and "never checked" look identical to a reader
    /// unless the bundle says which one it was.
    func test_noMatchIsStatedRatherThanLeftBlank() {
        let output = DiagnosticsReport.build(DiagnosticsSnapshot())
        XCTAssertTrue(output.contains("Signatures:"))
        XCTAssertTrue(output.contains("none matched"))
    }

    /// The URL budget truncates head-first, so a signature buried below the
    /// log tails would be the first thing dropped.
    func test_signaturesAppearBeforeTheLogSections() throws {
        let output = DiagnosticsReport.build(DiagnosticsSnapshot())
        let signatures = try XCTUnwrap(output.range(of: "Signatures:"))
        let logs = try XCTUnwrap(output.range(of: "Remote Work log"))
        XCTAssertLessThan(signatures.lowerBound, logs.lowerBound)
    }
}
