import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class DiagnosticsCaptureStoreTests: XCTestCase {
    private func baseline(
        verdict: PeerHostHealthVerdict,
        tmpRoot: String = "/"
    ) -> PeerHostHealthBaseline {
        switch verdict {
        case .healthy:
            return PeerHostHealthBaseline(
                serviceActive: true, daemonTmpRoot: tmpRoot, controlPathPresent: true,
                controlRPC: .available, peerPathPresent: true
            )
        case .unhealthy:
            return PeerHostHealthBaseline(
                serviceActive: true, daemonTmpRoot: tmpRoot,
                controlPath: "/tmp/term-meshd.sock", controlPathPresent: false,
                controlRPC: .unavailable, peerPathPresent: true
            )
        case .degraded:
            return PeerHostHealthBaseline(
                serviceActive: true, daemonTmpRoot: tmpRoot, controlPathPresent: true,
                controlRPC: .available, peerPathPresent: true, relayLagCount: 3
            )
        case .unknown:
            return PeerHostHealthBaseline(
                serviceActive: true, daemonTmpRoot: tmpRoot, controlPathPresent: true,
                controlRPC: .probeUnavailable, peerPathPresent: true
            )
        }
    }

    /// A healthy probe is the common case. Capturing it would fill the ring
    /// with nothing and evict the snapshots worth keeping.
    func test_healthyHostIsNotCaptured() {
        let store = DiagnosticsCaptureStore()
        store.recordUnhealthyHost(sshTarget: "root@h", health: baseline(verdict: .healthy))
        XCTAssertTrue(store.captures.isEmpty)
    }

    func test_unhealthyHostIsCapturedWithItsVerdict() {
        let store = DiagnosticsCaptureStore()
        store.recordUnhealthyHost(sshTarget: "root@h", health: baseline(verdict: .unhealthy))
        XCTAssertEqual(store.captures.count, 1)
        XCTAssertEqual(store.captures.first?.reason, "peer host unhealthy")
        XCTAssertEqual(store.captures.first?.snapshot.captureReason, "peer host unhealthy")
    }

    /// `degraded` and `unknown` are also worth freezing — "the probe could not
    /// run" is a finding, not an absence of one.
    func test_degradedAndUnknownAreAlsoCaptured() {
        let store = DiagnosticsCaptureStore()
        store.recordUnhealthyHost(sshTarget: "a", health: baseline(verdict: .degraded))
        store.recordUnhealthyHost(sshTarget: "b", health: baseline(verdict: .unknown))
        XCTAssertEqual(store.captures.count, 2)
    }

    /// A host that stays broken re-probes every time its editor opens. Without
    /// a floor those near-identical snapshots would evict the older, more
    /// interesting ones.
    func test_repeatedIdenticalFailuresAreThrottled() {
        let store = DiagnosticsCaptureStore()
        let start = Date()
        store.recordUnhealthyHost(sshTarget: "root@h", health: baseline(verdict: .unhealthy), now: start)
        store.recordUnhealthyHost(sshTarget: "root@h", health: baseline(verdict: .unhealthy), now: start.addingTimeInterval(5))
        XCTAssertEqual(store.captures.count, 1)
    }

    func test_theSameFailureIsCapturedAgainAfterTheInterval() {
        let store = DiagnosticsCaptureStore()
        let start = Date()
        store.recordUnhealthyHost(sshTarget: "root@h", health: baseline(verdict: .unhealthy), now: start)
        store.recordUnhealthyHost(
            sshTarget: "root@h",
            health: baseline(verdict: .unhealthy),
            now: start.addingTimeInterval(DiagnosticsCaptureStore.minimumInterval + 1)
        )
        XCTAssertEqual(store.captures.count, 2)
    }

    /// Throttling is per host and per verdict: a second host failing, or the
    /// same host failing differently, is new information.
    func test_throttlingIsScopedToTheHostAndVerdict() {
        let store = DiagnosticsCaptureStore()
        let start = Date()
        store.recordUnhealthyHost(sshTarget: "a", health: baseline(verdict: .unhealthy), now: start)
        store.recordUnhealthyHost(sshTarget: "b", health: baseline(verdict: .unhealthy), now: start)
        store.recordUnhealthyHost(sshTarget: "a", health: baseline(verdict: .degraded), now: start)
        XCTAssertEqual(store.captures.count, 3)
    }

    func test_newestFirstAndOldestEvicted() {
        let store = DiagnosticsCaptureStore()
        let start = Date()
        for index in 0..<(DiagnosticsCaptureStore.limit + 2) {
            store.recordUnhealthyHost(
                sshTarget: "host-\(index)",
                health: baseline(verdict: .unhealthy),
                now: start.addingTimeInterval(Double(index))
            )
        }
        XCTAssertEqual(store.captures.count, DiagnosticsCaptureStore.limit)
        // Newest first.
        XCTAssertGreaterThan(
            store.captures[0].capturedAt,
            store.captures[1].capturedAt
        )
    }
}

/// Attaching a measured baseline to the host it came from is the step that
/// turns a capture into something the triage rules can act on.
final class DiagnosticsSnapshotAttachTests: XCTestCase {
    private func host(id: String, ssh: String?) -> PeerHostSnapshot {
        PeerHostSnapshot(
            id: id, displayName: id, state: "connected", sshTarget: ssh,
            remoteSockPath: nil, activeSockPath: "", servingAppVersion: nil,
            workspaceCount: 0, teamCount: 0, isLaunchable: true,
            teamHostReadiness: "unresolved", failureReason: nil, healthBaseline: nil
        )
    }

    private var privateTmpBaseline: PeerHostHealthBaseline {
        PeerHostHealthBaseline(
            serviceActive: true,
            daemonTmpRoot: "/tmp/systemd-private-abc-term-meshd.service-xyz/tmp",
            controlPath: "/tmp/term-meshd.sock",
            controlPathPresent: false,
            controlRPC: .unavailable,
            peerPathPresent: true
        )
    }

    func test_baselineLandsOnTheMatchingHostOnly() {
        let snapshot = DiagnosticsSnapshot(peerHosts: [
            host(id: "a", ssh: "root@alpha"),
            host(id: "b", ssh: "root@beta"),
        ])
        let attached = snapshot.attaching(privateTmpBaseline, toHostMatching: "root@beta")
        XCTAssertNil(attached.peerHosts[0].healthBaseline)
        XCTAssertNotNil(attached.peerHosts[1].healthBaseline)
    }

    /// Guessing an owner would put a measurement on a host it was never taken
    /// against, which is worse than carrying no measurement at all.
    func test_noMatchingHostLeavesTheBaselineUnattached() {
        let snapshot = DiagnosticsSnapshot(peerHosts: [host(id: "a", ssh: "root@alpha")])
        let attached = snapshot.attaching(privateTmpBaseline, toHostMatching: "root@nobody")
        XCTAssertNil(attached.peerHosts[0].healthBaseline)
    }

    /// The payoff for the whole capture path: before attaching, the PrivateTmp
    /// rule has nothing to match on and stays silent — which is exactly the
    /// state the feature was in before captures existed. After attaching, the
    /// bundle recognises itself.
    func test_attachingIsWhatLetsThePrivateTmpRuleFire() {
        let snapshot = DiagnosticsSnapshot(peerHosts: [host(id: "a", ssh: "root@alpha")])
        XCTAssertNil(DiagnosticsTriage.firstKnownIssue(for: snapshot))

        let attached = snapshot.attaching(privateTmpBaseline, toHostMatching: "root@alpha")
        XCTAssertEqual(DiagnosticsTriage.firstKnownIssue(for: attached)?.1.number, 315)
    }
}

/// A frozen bundle has to announce itself. A reader who takes a capture from
/// twenty minutes ago as the current state draws conclusions about a machine
/// that has since moved on — the failure mode this feature was built to end.
@MainActor
final class DiagnosticsCaptureRenderingTests: XCTestCase {
    func test_frozenSnapshotSaysSoInTheBundle() {
        var snapshot = DiagnosticsSnapshot()
        snapshot.captureReason = "peer host unhealthy"
        let output = DiagnosticsReport.build(snapshot)
        XCTAssertTrue(output.contains("Captured automatically at the time of: peer host unhealthy"))
        XCTAssertTrue(output.contains("frozen snapshot"))
    }

    func test_liveSnapshotCarriesNoSuchClaim() {
        let output = DiagnosticsReport.build(DiagnosticsSnapshot())
        XCTAssertFalse(output.contains("frozen snapshot"))
        XCTAssertFalse(output.contains("Captured automatically"))
    }
}
