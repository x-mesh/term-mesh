import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Rendering is a pure function of the snapshot, which is the whole reason the
/// two are separate types — these assertions run against a synthesized host
/// instead of a live machine.
@MainActor
final class DiagnosticsReportTests: XCTestCase {
    private func host(
        id: String = "h1",
        name: String = "builder",
        state: String = "connected",
        ssh: String? = "root@203.0.113.10",
        version: String? = "0.196.0",
        failure: String? = nil,
        health: PeerHostHealthBaseline? = nil
    ) -> PeerHostSnapshot {
        PeerHostSnapshot(
            id: id,
            displayName: name,
            state: state,
            sshTarget: ssh,
            remoteSockPath: "/run/term-mesh/tm-peer.sock",
            activeSockPath: "/tmp/tm-peer-live.sock",
            servingAppVersion: version,
            workspaceCount: 2,
            teamCount: 1,
            isLaunchable: true,
            teamHostReadiness: "ready",
            failureReason: failure,
            healthBaseline: health
        )
    }

    private func render(_ hosts: [PeerHostSnapshot]) -> String {
        DiagnosticsReport.build(DiagnosticsSnapshot(peerHosts: hosts))
    }

    // MARK: - Health baseline is reported as measured, not as concluded

    /// The bundle carries the probe's own keys. A verdict states a conclusion
    /// about the host; the raw fields state what was measured, and the two come
    /// apart exactly when the probe is wrong — which is the case a bug report
    /// exists to show.
    func test_healthBaselineIsEmittedAsRawProbeKeys() {
        let baseline = PeerHostHealthBaseline(
            serviceActive: true,
            controlPath: "/tmp/term-meshd.sock",
            controlPathPresent: false,
            controlRPC: .unavailable,
            peerPath: "/run/term-mesh/tm-peer.sock",
            peerPathPresent: true,
            relayLagCount: 0,
            resumeHealCount: 0,
            protocolMismatchCount: 0
        )
        let output = render([host(health: baseline)])
        XCTAssertTrue(output.contains("health-service-active=1"))
        XCTAssertTrue(output.contains("health-control-path=/tmp/term-meshd.sock"))
        XCTAssertTrue(output.contains("health-control-present=0"))
        XCTAssertTrue(output.contains("health-control-rpc=0"))
        XCTAssertTrue(output.contains("health-peer-present=1"))
        XCTAssertTrue(output.contains("health-protocol-mismatch-5m=0"))
    }

    /// "The probe could not run" is a different claim from "the daemon did not
    /// answer". Flattening the first into the second is what made a healthy
    /// host read as broken, so the distinction has to survive into the bundle.
    func test_probeUnavailableIsReportedAsUnknownNotAsFailure() {
        let baseline = PeerHostHealthBaseline(controlRPC: .probeUnavailable)
        let output = render([host(health: baseline)])
        XCTAssertTrue(output.contains("health-control-rpc=unknown"))
        XCTAssertFalse(output.contains("health-control-rpc=0"))
    }

    func test_hostWithoutBaselineOmitsTheSection() {
        let output = render([host(health: nil)])
        XCTAssertFalse(output.contains("health baseline"))
        XCTAssertTrue(output.contains("Peer Hosts:"))
    }

    // MARK: - Peer host section

    func test_failedHostCarriesItsReason() {
        let output = render([host(state: "failed", failure: "ssh handshake refused")])
        XCTAssertTrue(output.contains("[failed]"))
        XCTAssertTrue(output.contains("ssh handshake refused"))
    }

    func test_unknownServingVersionIsStatedNotOmitted() {
        let output = render([host(version: nil)])
        XCTAssertTrue(output.contains("serving version: unknown"))
    }

    func test_noPeerHostsSaysSoExplicitly() {
        let output = render([])
        XCTAssertTrue(output.contains("(none configured)"))
    }

    // MARK: - Redactor seeding

    /// Seeding from the snapshot is what makes `<host-1>` mean "the first host
    /// in the peer list" rather than "whichever host a section happened to
    /// mention first".
    func test_hostAliasNumberingFollowsThePeerHostList() {
        let output = render([
            host(id: "a", name: "alpha", ssh: "root@203.0.113.10"),
            host(id: "b", name: "beta", ssh: "root@198.51.100.7"),
        ])
        XCTAssertTrue(output.contains("  <host-1> [connected]"))
        XCTAssertTrue(output.contains("  <host-2> [connected]"))
        XCTAssertFalse(output.contains("alpha"))
        XCTAssertFalse(output.contains("beta"))
        XCTAssertFalse(output.contains("203.0.113.10"))
        XCTAssertFalse(output.contains("198.51.100.7"))
    }

    func test_userDefinedPeerNameIsReplacedByItsHostAlias() {
        let snapshot = DiagnosticsSnapshot(
            peerHosts: [
                host(name: "Alice’s MacBook", ssh: "alice@builder.example.com"),
            ],
            context: .init(
                windowCount: 1,
                workspaces: [
                    .init(
                        title: "Alice’s MacBook workspace",
                        isSelected: true,
                        terminalPanels: 1,
                        browserPanels: 0,
                        agentPanels: 0,
                        remoteAgentPanes: 0
                    ),
                ]
            ),
            activityTail: ["Disconnected Alice’s MacBook"]
        )
        let output = DiagnosticsReport.build(snapshot)
        XCTAssertTrue(output.contains("  <host-1> [connected]"))
        XCTAssertTrue(output.contains("[redacted line containing <host-1>]"))
        XCTAssertFalse(output.contains("Alice"))
        XCTAssertFalse(output.contains("MacBook"))
        XCTAssertFalse(output.contains("builder.example.com"))
    }

    func test_shortPeerNameDoesNotCorruptWordsThatContainIt() {
        let snapshot = DiagnosticsSnapshot(
            peerHosts: [host(name: "ci", ssh: nil)],
            activityTail: ["specific decision for ci"]
        )
        let output = DiagnosticsReport.build(snapshot)
        XCTAssertTrue(output.contains("specific decision for ci"))
        XCTAssertFalse(output.contains("spe<host-1>fic"))
        XCTAssertFalse(output.contains("de<host-1>sion"))
    }

    func test_hostWithoutSSHTargetKeepsAliasOrder() {
        let output = render([
            host(id: "a", name: "local peer", ssh: nil),
            host(id: "b", name: "builder", ssh: "root@198.51.100.7"),
        ])
        XCTAssertTrue(output.contains("  <host-1> [connected]"))
        XCTAssertTrue(output.contains("  <host-2> [connected]"))
    }

    func test_displayNameContainingHostIsFullyRedacted() {
        let snapshot = DiagnosticsSnapshot(
            peerHosts: [
                host(
                    name: "builder.example.com Mac",
                    ssh: "alice@builder.example.com"
                ),
            ],
            activityTail: ["Connected builder.example.com Mac"]
        )
        let output = DiagnosticsReport.build(snapshot)
        XCTAssertTrue(output.contains("[redacted line containing <host-1>]"))
        XCTAssertFalse(output.contains("builder.example.com"))
        XCTAssertFalse(output.contains(" Mac"))
    }

    func test_duplicateAndEmptyDisplayNamesStillReserveOneAliasPerPeer() {
        let output = render([
            host(id: "a", name: "builder", ssh: nil),
            host(id: "b", name: "builder", ssh: "root@198.51.100.7"),
            host(id: "c", name: "", ssh: nil),
        ])
        XCTAssertTrue(output.contains("  <host-1> [connected]"))
        XCTAssertTrue(output.contains("  <host-2> [connected]"))
        XCTAssertTrue(output.contains("  <host-3> [connected]"))
    }

    func test_unicodeEquivalentPeerNameIsRedacted() {
        let decomposed = "Cafe\u{301} Mac"
        let precomposed = "Café Mac"
        let snapshot = DiagnosticsSnapshot(
            peerHosts: [host(name: precomposed, ssh: nil)],
            activityTail: ["Connected \(decomposed)"]
        )
        let output = DiagnosticsReport.build(snapshot)
        XCTAssertTrue(output.contains("[redacted line containing <host-1>]"))
        XCTAssertFalse(output.contains("Café"))
    }

    func test_aliasShapedDisplayNameDoesNotRewriteGeneratedAliases() {
        let output = render([
            host(id: "a", name: "<host-1>", ssh: nil),
            host(id: "b", name: "host-2", ssh: nil),
        ])
        XCTAssertTrue(output.contains("  <host-1> [connected]"))
        XCTAssertTrue(output.contains("  <host-2> [connected]"))
        XCTAssertFalse(output.contains("<host-2> [connected]\n  <host-2>"))
    }

    func test_hostnameComponentLabelRedactsTheWholeLineWithoutLeakingSuffix() {
        let snapshot = DiagnosticsSnapshot(
            peerHosts: [host(name: "builder", ssh: "dev@builder.corp.internal")],
            activityTail: ["Connected builder.corp.internal"]
        )
        let output = DiagnosticsReport.build(snapshot)
        XCTAssertTrue(output.contains("[redacted line containing <host-1>]"))
        XCTAssertFalse(output.contains("corp.internal"))
    }

    func test_unicodeEquivalentSSHHostIsRedacted() {
        let decomposed = "cafe\u{301}.example.com"
        let precomposed = "café.example.com"
        let output = render([
            host(name: "builder", ssh: "dev@\(decomposed)", failure: precomposed),
        ])
        XCTAssertFalse(output.contains("café.example.com"))
        XCTAssertTrue(output.contains("<host-1>"))
    }

    /// The bundle is redacted on the way out no matter which section produced
    /// the value — a peer host's ssh target is not special-cased.
    func test_bundleIsRedactedEndToEnd() {
        let output = render([host(ssh: "alice@203.0.113.10")])
        XCTAssertFalse(output.contains("alice"))
        XCTAssertFalse(output.contains("203.0.113.10"))
    }

    // MARK: - Context

    func test_contextReportsWindowAndWorkspaceShape() {
        let context = DiagnosticsContextSnapshot(
            windowCount: 2,
            workspaces: [
                .init(
                    title: "api",
                    isSelected: true,
                    terminalPanels: 3,
                    browserPanels: 1,
                    agentPanels: 2,
                    remoteAgentPanes: 1
                )
            ]
        )
        let output = DiagnosticsReport.build(DiagnosticsSnapshot(context: context))
        XCTAssertTrue(output.contains("windows: 2, workspaces: 1"))
        XCTAssertTrue(output.contains("* api: term=3 browser=1 agent=2 remoteAgent=1"))
    }
}

/// The tail reader exists because reading an 8 MB log to keep 40 lines of it
/// allocates megabytes for kilobytes of answer, on the main thread.
final class DiagnosticsLogTailTests: XCTestCase {
    private func writeTemp(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailtest-\(UUID().uuidString).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func test_returnsTheLastLinesInOrder() throws {
        let path = try writeTemp((1...10).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(
            DiagnosticsLogTail.tail(path: path, lines: 3),
            ["line 8", "line 9", "line 10"]
        )
    }

    func test_shortFileReturnsEverythingWithNoLostFirstLine() throws {
        let path = try writeTemp("only line")
        XCTAssertEqual(DiagnosticsLogTail.tail(path: path, lines: 10), ["only line"])
    }

    func test_missingFileIsEmptyNotACrash() {
        XCTAssertEqual(
            DiagnosticsLogTail.tail(path: "/nonexistent/term-mesh/nope.log", lines: 5),
            []
        )
    }

    func test_emptyPathIsEmpty() {
        XCTAssertEqual(DiagnosticsLogTail.tail(path: "", lines: 5), [])
    }

    /// A single line long enough to dominate the bundle is a dumped payload,
    /// not a message worth carrying whole.
    func test_overlongLineIsTruncatedWithAMarker() throws {
        let long = String(repeating: "x", count: DiagnosticsLogTail.maxLineLength + 50)
        let path = try writeTemp(long)
        let tail = DiagnosticsLogTail.tail(path: path, lines: 1)
        XCTAssertEqual(tail.count, 1)
        XCTAssertTrue(tail[0].hasSuffix("… (truncated)"))
        XCTAssertLessThan(tail[0].count, long.count)
    }

    /// The daemon logs through `tracing`, which colours its output, so the
    /// file holds real escape bytes. Carried into a bundle they reach a GitHub
    /// comment and an agent's prompt as `[0m` litter — and an escape sequence
    /// pasted into a terminal is not inert.
    func test_ansiColourCodesAreStrippedFromLogLines() throws {
        let coloured = "\u{1B}[2m2026-08-19T05:09:49Z\u{1B}[0m \u{1B}[32mDEBUG\u{1B}[0m team.sync: ok"
        let path = try writeTemp(coloured)
        XCTAssertEqual(
            DiagnosticsLogTail.tail(path: path, lines: 1),
            ["2026-08-19T05:09:49Z DEBUG team.sync: ok"]
        )
    }

    /// The exact shape observed in a real bundle: the reset sequence at the
    /// head of a wrapped line, which reached the agent as `[0m`.
    func test_leadingResetSequenceLeavesNoLitter() {
        XCTAssertEqual(
            DiagnosticsLogTail.stripped("\u{1B}[0m team.sync: Object {\"teams\": Number(1)}"),
            " team.sync: Object {\"teams\": Number(1)}"
        )
    }

    /// Tabs align log columns and stay; a bare BEL is noise and goes.
    func test_barControlBytesAreRemovedButTabsSurvive() {
        XCTAssertEqual(DiagnosticsLogTail.stripped("a\u{07}b\tc"), "ab\tc")
    }

    /// `ESC` followed by one character is a two-byte escape in its own right
    /// (`ESC c` is a full reset), so both bytes go. Costing one character of a
    /// log line is the right trade against leaving a live escape byte in text
    /// that gets pasted into a terminal.
    func test_twoByteEscapeIsConsumedWhole() {
        XCTAssertEqual(DiagnosticsLogTail.stripped("a\u{1B}cb"), "ab")
    }

    func test_ordinaryTextIsUntouched() {
        let line = "2026-08-19 INFO peer authenticated (ssh-passthrough)"
        XCTAssertEqual(DiagnosticsLogTail.stripped(line), line)
    }

    /// Seeking past the start lands mid-line; that fragment is dropped rather
    /// than reported as though the log contained a truncated entry.
    func test_partialFirstLineIsDroppedWhenSeeking() throws {
        let filler = String(repeating: "a", count: DiagnosticsLogTail.readBudgetBytes)
        let path = try writeTemp("\(filler)\nsecond\nthird")
        let tail = DiagnosticsLogTail.tail(path: path, lines: 10)
        XCTAssertEqual(tail, ["second", "third"])
    }
}
