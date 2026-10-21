import XCTest
import Observation
import AppKit
import SwiftUI

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Reading a session without a terminal in it.
///
/// Measured before any of this was written: `claude --print` with plain pipes —
/// no PTY, no shell, no FIFO — takes turn after turn and keeps its context. So
/// the terminal was never load-bearing, and what is left to get right is the
/// parsing: turning the stream into things a view can draw as what they are.
@MainActor
final class AgentSessionTests: XCTestCase {
    private func recoveryFrame(full: Bool = true) -> AgentLiveFrame {
        AgentLiveFrame(full: full, baseRevision: 0, revision: 1, order: [], state: .init(
            generation: UUID(), entries: [], running: true, thinking: false,
            interruptible: true, streaming: [], summary: nil, model: "fixture", usage: nil))
    }

    private func recoveryPacket(_ payload: Data, begin: Bool = true, end: Bool = true) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "begin": begin, "end": end, "payload": payload.base64EncodedString()
        ])
        data.append(10)
        return data
    }

    func testLiveProjectionRosterFailureDoesNotDisableIdleWorker() {
        let viewer = AgentSession()
        viewer.prepareLivePresentation()
        XCTAssertTrue(viewer.acceptLivePresentation(recoveryFrame()))
        for (present, verified) in [(true, false), (false, false), (true, true)] {
            RemoteLiveProject.applyRosterAvailability(
                projectPresent: present, rosterVerified: verified, sessions: [viewer])
            XCTAssertTrue(viewer.isRunning, "roster failure/recovery must not require fresh agent output")
            XCTAssertTrue(viewer.canInterrupt)
        }
        RemoteLiveProject.applyRosterAvailability(
            projectPresent: false, rosterVerified: true, sessions: [viewer])
        XCTAssertFalse(viewer.isRunning, "confirmed Project removal still disables input")
        XCTAssertFalse(viewer.canInterrupt)
    }

    func testLiveProjectionRestartsAfterPartialLineAndFrame() async throws {
        for partialFrame in [false, true] {
            let received = expectation(description: "fresh snapshot after restart \(partialFrame)")
            let frame = recoveryFrame()
            let payload = try JSONEncoder().encode(frame)
            let packet = try recoveryPacket(payload)
            let decoder = AgentLiveDecoder(invalid: { XCTFail("old bytes corrupted the new stream") }) { result in
                XCTAssertTrue(result.full)
                XCTAssertEqual(result.state.generation, frame.state.generation)
                received.fulfill()
            }
            if partialFrame {
                decoder.consume(try recoveryPacket(payload.prefix(payload.count / 2), end: false))
            } else {
                decoder.consume(packet.prefix(packet.count / 2))
            }
            decoder.resetForRestart()
            decoder.consume(packet)
            await fulfillment(of: [received], timeout: 3)
            decoder.stop()
        }
    }

    func testLiveProjectionRestartRequiresFullSnapshot() async throws {
        let refused = expectation(description: "delta cannot bootstrap restarted stream")
        let decoder = AgentLiveDecoder(invalid: { refused.fulfill() }) { _ in
            XCTFail("delta was delivered before a full snapshot")
        }
        decoder.resetForRestart()
        decoder.consume(try recoveryPacket(JSONEncoder().encode(recoveryFrame(full: false))))
        await fulfillment(of: [refused], timeout: 3)
        decoder.stop()
    }

    func testLiveProjectionSnapshotsExistingHiddenTranscriptAndThenDeltas() async throws {
        let source = AgentSession()
        source.isVisible = false
        source.appendLocalNotice(String(repeating: "한글 transcript ", count: 6_000))
        let (subscription, stream) = source.subscribeLivePresentation()
        defer { source.unsubscribeLivePresentation(subscription) }
        let encoder = AgentLiveEncoder(stream)
        let viewer = AgentSession()
        viewer.prepareLivePresentation()
        let initial = expectation(description: "chunked initial snapshot")
        let changed = expectation(description: "hidden pane delta")
        let decoder = AgentLiveDecoder { frame in
            DispatchQueue.main.async {
                viewer.acceptLivePresentation(frame)
                if frame.full { initial.fulfill() } else { changed.fulfill() }
            }
        }
        defer { decoder.stop() }
        func deliverFrame() async throws {
            while let chunk = await encoder.next() {
                // Exercise arbitrary packet/UTF-8 boundaries in the transport.
                let middle = chunk.bytes.count / 2
                decoder.consume(chunk.bytes.prefix(middle))
                decoder.consume(chunk.bytes.suffix(chunk.bytes.count - middle))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: chunk.bytes) as? [String: Any])
                if object["end"] as? Bool == true { return }
            }
            XCTFail("stream ended before a complete frame")
        }
        try await deliverFrame()
        await fulfillment(of: [initial], timeout: 3)
        XCTAssertEqual(viewer.entries, source.entries)
        source.appendLocalNotice("after attach")
        try await deliverFrame()
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(viewer.entries, source.entries)
        XCTAssertEqual(viewer.entries.count, 2)
    }

    func testLiveProjectionRejectsGapAndFullSnapshotReplacesWithoutDuplication() {
        let viewer = AgentSession()
        viewer.prepareLivePresentation()
        let generation = UUID()
        let first = AgentSession.Entry.notice(id: UUID(), "first")
        let second = AgentSession.Entry.notice(id: UUID(), "second")
        func frame(_ entries: [AgentSession.Entry], full: Bool, base: UInt64, revision: UInt64) -> AgentLiveFrame {
            AgentLiveFrame(full: full, baseRevision: base, revision: revision,
                           order: entries.map(\.id), state: .init(
                            generation: generation, entries: entries, running: true, thinking: false,
                            interruptible: true, streaming: [], summary: nil, model: "test", usage: nil))
        }
        viewer.acceptLivePresentation(frame([first], full: true, base: 0, revision: 1))
        viewer.acceptLivePresentation(frame([second], full: false, base: 7, revision: 8))
        XCTAssertEqual(viewer.entries, [first])
        viewer.acceptLivePresentation(frame([first, second], full: true, base: 0, revision: 1))
        viewer.acceptLivePresentation(frame([first, second], full: true, base: 0, revision: 1))
        XCTAssertEqual(viewer.entries, [first, second])
        viewer.livePresentationDisconnected()
        XCTAssertFalse(viewer.isRunning)
        XCTAssertEqual(viewer.entries, [first, second])
    }

    func testLiveProjectionCoalescesPendingModelsWithoutDroppingDeliveredEntries() async throws {
        let pair = AsyncStream<AgentSession.LiveState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let generation = UUID()
        for index in 1...50 {
            pair.continuation.yield(.init(generation: generation,
                entries: [.notice(id: generation, "value \(index)")], running: true, thinking: false,
                interruptible: false, streaming: [], summary: nil, model: "", usage: nil))
        }
        pair.continuation.finish()
        let encoder = AgentLiveEncoder(pair.stream)
        let chunk = await encoder.next()
        let bytes = try XCTUnwrap(chunk?.bytes)
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(packet["payload"] as? String)))
        let frame = try JSONDecoder().decode(AgentLiveFrame.self, from: payload)
        XCTAssertEqual(frame.state.entries, [.notice(id: generation, "value 50")])
        let end = await encoder.next()
        XCTAssertNil(end)
    }

    func testChatTurnPreservesLineBreaksAndNormalizesCarriageReturns() {
        XCTAssertEqual(
            TerminalSurface.normalizedChatTurn("first\r\nsecond\rthird"),
            "first\nsecond\nthird"
        )
    }

    func testIsolatedWorktreeBranchUsesDurableInstanceIdentity() {
        let first = TeamOrchestrator.isolatedWorktreeBranch(
            teamName: "term-mesh", agentName: "executor",
            agentInstanceId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        let second = TeamOrchestrator.isolatedWorktreeBranch(
            teamName: "term-mesh", agentName: "executor",
            agentInstanceId: "11111111-2222-3333-4444-555555555555"
        )

        XCTAssertEqual(
            first, "team/term-mesh/executor/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            first,
            TeamOrchestrator.isolatedWorktreeBranch(
                teamName: "term-mesh", agentName: "executor",
                agentInstanceId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            )
        )
        XCTAssertEqual(
            TeamOrchestrator.isolatedWorktreeBranch(
                teamName: "Team / Demo", agentName: "executor/one",
                agentInstanceId: "INSTANCE / ONE"
            ),
            "team/team-demo/executor-one/instance-one"
        )
    }

    func testSharedWorktreeBranchUsesDisjointNamespace() {
        let shared = TeamOrchestrator.sharedWorktreeBranch(teamName: "My Team!")
        let isolated = TeamOrchestrator.isolatedWorktreeBranch(
            teamName: "My Team!", agentName: "executor", agentInstanceId: "instance-1"
        )

        XCTAssertEqual(shared, "team-shared/my-team")
        XCTAssertFalse(shared.hasPrefix(isolated + "/"))
        XCTAssertFalse(isolated.hasPrefix(shared + "/"))
    }

    func testIsolatedProvisioningRollsBackPartialSuccessAndStops() {
        var attempted: [String] = []
        var rolledBack: [String] = []
        let agents = [
            (name: "executor", instanceId: "one"),
            (name: "reviewer", instanceId: "two"),
            (name: "planner", instanceId: "three"),
        ]

        let result = TeamOrchestrator.provisionIsolatedWorktrees(
            teamName: "demo", agents: agents,
            create: { branch in
                attempted.append(branch)
                if branch.hasSuffix("/two") {
                    return .failure(.rpcError("conflict at /existing/path"))
                }
                return .success(WorktreeInfo(
                    name: "wt-\(branch)", path: "/tmp/\(branch)", branch: branch
                ))
            },
            rollback: { rolledBack.append($0.branch) }
        )

        guard case .failure(let failure) = result else {
            return XCTFail("partial provisioning unexpectedly succeeded")
        }
        XCTAssertEqual(failure.agentName, "reviewer")
        XCTAssertEqual(failure.agentInstanceId, "two")
        XCTAssertEqual(attempted, [
            "team/demo/executor/one",
            "team/demo/reviewer/two",
        ])
        XCTAssertEqual(rolledBack, ["team/demo/executor/one"])
    }

    func testUncommittedIsolatedWorktreesRollBackNewestFirst() {
        let provisioned: [WorktreeInfo?] = [
            WorktreeInfo(name: "wt-one", path: "/tmp/one", branch: "team/demo/executor/one"),
            WorktreeInfo(name: "wt-two", path: "/tmp/two", branch: "team/demo/reviewer/two"),
            nil,
            WorktreeInfo(name: "wt-three", path: "/tmp/three", branch: "team/demo/planner/three"),
        ]
        var rolledBack: [String] = []
        var logged: [(String, TeamOrchestrator.IsolatedWorktreeRollbackOutcome)] = []

        let retained = TeamOrchestrator.rollbackUnownedIsolatedWorktrees(
            provisioned: provisioned,
            rollback: { info in
                rolledBack.append(info.name)
                return true
            },
            log: { info, outcome in logged.append((info.name, outcome)) }
        )

        // A pane is not ownership until the complete roster commits, so every
        // provisioned checkout participates in rollback.
        XCTAssertEqual(rolledBack, ["wt-three", "wt-two", "wt-one"])
        XCTAssertTrue(retained.isEmpty)
        XCTAssertEqual(logged.map(\.0), ["wt-three", "wt-two", "wt-one"])
        XCTAssertEqual(logged.map(\.1), [.removed, .removed, .removed])
    }

    func testRetainedIsolatedWorktreeIsReportedInsteadOfForcedAway() {
        let dirty = WorktreeInfo(
            name: "wt-dirty", path: "/tmp/dirty", branch: "team/demo/executor/one"
        )
        let clean = WorktreeInfo(
            name: "wt-clean", path: "/tmp/clean", branch: "team/demo/reviewer/two"
        )
        var attempts: [String] = []
        var logged: [(String, TeamOrchestrator.IsolatedWorktreeRollbackOutcome)] = []

        let retained = TeamOrchestrator.rollbackUnownedIsolatedWorktrees(
            provisioned: [dirty, clean],
            // The daemon removes with `force: false`, so a checkout carrying
            // uncommitted work answers false rather than being deleted.
            rollback: { info in
                attempts.append(info.name)
                return info.name != "wt-dirty"
            },
            log: { info, outcome in logged.append((info.name, outcome)) }
        )

        XCTAssertEqual(attempts, ["wt-clean", "wt-dirty"])
        XCTAssertEqual(retained.map(\.name), ["wt-dirty"])
        XCTAssertEqual(logged.map(\.1), [.removed, .retained])
        // A refusal stops the sweep from lying about what is still on disk,
        // and never turns into a forced delete of the user's work.
        XCTAssertEqual(retained.first?.path, "/tmp/dirty")
    }

    func testNativeAgentPaneExposesContextClearingRestart() throws {
        let presentation = try XCTUnwrap(Workspace.agentRestartPresentation(
            panelType: .agent,
            agentName: "reviewer"
        ))

        XCTAssertEqual(presentation.help,
                       "Restart reviewer agent — clears conversation context")
        XCTAssertEqual(presentation.accessibilityLabel,
                       "Restart reviewer agent and clear conversation context")
        XCTAssertFalse(presentation.allowsSoftRestart)
    }

    func testTerminalAgentPaneRetainsOptionClickSoftRestart() throws {
        let presentation = try XCTUnwrap(Workspace.agentRestartPresentation(
            panelType: .terminal,
            agentName: "executor"
        ))

        XCTAssertTrue(presentation.help.contains("clears conversation context"))
        XCTAssertTrue(presentation.help.contains("⌥-click: soft restart"))
        XCTAssertTrue(presentation.allowsSoftRestart)
    }

    func testBrowserPaneDoesNotExposeAgentRestart() {
        XCTAssertNil(Workspace.agentRestartPresentation(
            panelType: .browser,
            agentName: "not-an-agent"
        ))
    }

    func testLeaderParallelPolicyRendersStableVersionAndDigest() {
        let first = LeaderParallelPolicy.renderedInstructions
        let second = LeaderParallelPolicy.renderedInstructions

        XCTAssertEqual(LeaderParallelPolicy.version, "15")
        XCTAssertEqual(LeaderParallelPolicy.activation, "request-boundary-enforced")
        XCTAssertEqual(first, second)
        XCTAssertEqual(LeaderParallelPolicy.digest.count, 64)
        XCTAssertTrue(LeaderParallelPolicy.digest.allSatisfy { $0.isHexDigit })
        XCTAssertTrue(first.contains("policy_version: 15"))
        XCTAssertTrue(first.contains("policy_digest: \(LeaderParallelPolicy.digest)"))
        XCTAssertTrue(first.contains("policy_activation: request-boundary-enforced"))
    }

    func testCodexLeaderTurnHooksUseVettedInlineLifecycleConfig() {
        let args = TeamOrchestrator.codexLeaderTurnHookArguments(
            path: "/Applications/term mesh/scripts/leader-turn-hook.sh"
        )
        XCTAssertTrue(args.contains("--dangerously-bypass-hook-trust"))
        XCTAssertTrue(args.contains("--enable"))
        XCTAssertTrue(args.contains("hooks"))
        XCTAssertTrue(args.contains { $0.contains("hooks.UserPromptSubmit") && $0.contains("--start") })
        XCTAssertTrue(args.contains { $0.contains("hooks.Stop") && $0.contains("--end") })
        XCTAssertTrue(args.contains { $0.contains("/Applications/term mesh/scripts/leader-turn-hook.sh") })
        XCTAssertTrue(TeamOrchestrator.supportsLeaderTurnMeasurement(cli: "claude"))
        XCTAssertTrue(TeamOrchestrator.supportsLeaderTurnMeasurement(cli: "codex"))
        XCTAssertFalse(TeamOrchestrator.supportsLeaderTurnMeasurement(cli: "kiro"))
    }

    func testLeaderParallelPolicyContainsEveryRequiredRoutingRule() {
        let policy = LeaderParallelPolicy.renderedInstructions

        [
            "team-aware-decomposition-default",
            "parallel-admission-gate",
            "structured-routing-decision",
            "turn-route-measurement",
            "dag-readiness",
            "unified-placement-pool",
            "same-checkout-isolation",
            "bounded-handoff",
            "leader-integration-lane",
            "actual-diff-review-gate",
            "review-only-fast-path",
            "cross-model-validation",
            "no-progress-recovery",
            "branch-merge-boundary",
            "isolated-checkout-ref-contract",
            "policy-parity",
            "timebox-convergence",
            "external-event-wait",
        ].forEach { XCTAssertTrue(policy.contains("[\($0)]"), "missing \($0)") }
        XCTAssertTrue(policy.contains("This policy is active."))
        XCTAssertTrue(policy.contains("start each non-trivial request by decomposing"))
        XCTAssertTrue(policy.contains("assign eligible units before doing that work in the leader lane"))
        XCTAssertTrue(policy.contains("Direct execution is the explicit exception"))
        XCTAssertTrue(policy.contains("constraint that prevented a useful parallel split"))
        XCTAssertTrue(policy.contains("--worktree always"))
        XCTAssertTrue(policy.contains("Tasks that share a checkout also name owned and forbidden paths"))
        XCTAssertTrue(policy.contains("when TEAM_CHECKOUT_MODE is isolated those lists are optional"))
        XCTAssertTrue(policy.contains("\"done\": \"observable completion criteria\""))
        XCTAssertTrue(policy.contains("Never copy files out of a task branch instead of merging it"))
        XCTAssertTrue(policy.contains("avoid turn-by-turn ping-pong"))
        XCTAssertTrue(policy.contains("\"route\": \"direct|probe|parallel|delegated\""))
        XCTAssertTrue(policy.contains("probe has exactly one read-only implementation task"))
        XCTAssertTrue(policy.contains("parallel has between two and the configured maximum of ten implementation tasks"))
        XCTAssertTrue(policy.contains("never manufacture work solely to occupy capacity"))
        XCTAssertTrue(policy.contains("tm-agent leader turn route --route"))
        XCTAssertTrue(policy.contains("--available-workers <count>"))
        XCTAssertTrue(policy.contains("always returns mandatory guidance"))
        XCTAssertTrue(policy.contains("does not intercept arbitrary"))
        XCTAssertTrue(policy.contains("wait --mode any --tasks"))
        XCTAssertTrue(policy.contains("at most one additional wait/collect"))
        XCTAssertTrue(policy.contains("After the actual diff is integrated"))
        XCTAssertTrue(policy.contains("bounded manifest-level triage"))
        XCTAssertTrue(policy.contains("same frozen target"))
        XCTAssertTrue(policy.contains("Do not enter tm-agent wait while useful leader-lane work remains"))
        XCTAssertTrue(policy.contains("Small single-domain reviews stay leader-direct"))
        XCTAssertTrue(policy.contains("\"validation_gates\""))
        XCTAssertTrue(policy.contains("security plus tester"))
        XCTAssertTrue(policy.contains("cross_model_independence_unavailable"))
        XCTAssertTrue(policy.contains("at most three primary files"))
        XCTAssertTrue(policy.contains("`review_ready` without that final reply is partial evidence"))
        XCTAssertTrue(policy.contains("no task-cancel primitive"))
    }

    func testLeaderParallelPolicyUsesOneCanonicalLaunchDirective() {
        let directive = LeaderParallelPolicy.launchDirective(promptFile: "/tmp/policy.md")

        XCTAssertTrue(directive.contains("/tmp/policy.md"))
        XCTAssertTrue(directive.contains("version \(LeaderParallelPolicy.version)"))
        XCTAssertTrue(directive.contains("digest \(LeaderParallelPolicy.digest)"))
        XCTAssertTrue(directive.contains("canonical Leader Adaptive Execution Policy"))
    }

    func testLeaderTurnHookSettingsContainOnlyTheSupportedBoundaries() throws {
        let data = try XCTUnwrap(
            TeamOrchestrator.leaderTurnHookSettingsJSON.data(using: .utf8)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "Stop"])
        for (event, mode) in [("UserPromptSubmit", "--start"), ("Stop", "--end")] {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let group = try XCTUnwrap(groups.first)
            let entries = try XCTUnwrap(group["hooks"] as? [[String: Any]])
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry["type"] as? String, "command")
            XCTAssertEqual(entry["timeout"] as? Int, 10)
            XCTAssertEqual(
                entry["command"] as? String,
                "\"$TERMMESH_LEADER_TURN_HOOK\" \(mode)"
            )
        }
    }

    func testLeaderTurnHookPathFindsDevelopmentAssetWhenNoBundleHookExists() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("leader-turn-hook-\(UUID().uuidString)", isDirectory: true)
        let hook = root.appendingPathComponent("scripts/leader-turn-hook.sh")
        try? FileManager.default.createDirectory(
            at: hook.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: hook.path, contents: Data("#!/bin/sh\n".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        defer { try? FileManager.default.removeItem(at: root) }

        // Test bundles may contain the installed app resource. Its precedence
        // is deliberate; when it is present the development checkout must not
        // replace the version that is actually executing.
        let resolved = TeamOrchestrator.leaderTurnHookPath(workingDirectory: root.path)
        XCTAssertNotNil(resolved)
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/leader-turn-hook.sh").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            XCTAssertEqual(resolved, bundled)
        } else {
            XCTAssertEqual(resolved, hook.path)
        }
    }

    /// Two same-named instances used to both write `<agent>-reply.md`,
    /// silently losing whichever one finished first.
    func testFileReportWritesPerInstanceAliasWhenInstanceIDIsKnown() {
        let team = "fileReport-test-\(UUID().uuidString.prefix(8))"
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".term-mesh/results", isDirectory: true)
            .appendingPathComponent(team, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        TeamOrchestrator.fileReport(teamName: team, agentName: "reviewer",
                                     agentInstanceId: "inst-1", taskId: nil, text: "first")
        TeamOrchestrator.fileReport(teamName: team, agentName: "reviewer",
                                     agentInstanceId: "inst-2", taskId: nil, text: "second")

        let first = try? String(contentsOf: dir.appendingPathComponent("reviewer-inst-1-reply.md"), encoding: .utf8)
        let second = try? String(contentsOf: dir.appendingPathComponent("reviewer-inst-2-reply.md"), encoding: .utf8)
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")

        let nameOnlyExists = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("reviewer-reply.md").path)
        XCTAssertFalse(nameOnlyExists,
                       "an instance-identified report must not also write the collidable name-only file")
    }

    /// The name-only file remains the legacy path for an agent with no
    /// instance ID to disambiguate — nothing else writes there to collide.
    func testFileReportFallsBackToNameOnlyWithoutAnInstanceID() {
        let team = "fileReport-test-\(UUID().uuidString.prefix(8))"
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".term-mesh/results", isDirectory: true)
            .appendingPathComponent(team, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        TeamOrchestrator.fileReport(teamName: team, agentName: "solo",
                                     taskId: "task-123", text: "legacy")

        let legacy = try? String(contentsOf: dir.appendingPathComponent("solo-reply.md"), encoding: .utf8)
        let task = try? String(contentsOf: dir.appendingPathComponent("task-123.md"), encoding: .utf8)
        XCTAssertEqual(legacy, "legacy")
        XCTAssertEqual(task, "legacy")
    }

    private func agentMember(name: String = "executor") -> TeamOrchestrator.AgentMember {
        TeamOrchestrator.AgentMember(
            id: "\(name)@identity-test",
            name: name,
            teamName: "identity-test",
            cli: "claude",
            launchCommand: "claude",
            model: "sonnet",
            agentType: "executor",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: nil,
            parentSessionId: nil,
            claudeSessionId: nil,
            claudeSessionIdCapturedAt: nil,
            createdAt: Date(),
            worktreeName: nil,
            worktreePath: nil,
            worktreeBranch: nil,
            remoteSurfaceID: nil,
            remoteSurfaceSpawned: false,
            hostKey: nil,
            originalSpawnCommand: nil,
            originalAgentWorkDir: nil,
            autoRecycleEvery: nil,
            completedTaskCount: 0
        )
    }

    /// A duplicate role is a valid pool. Runtime resources cannot use
    /// `role@team`: pane recreation changes panelId, while two live instances
    /// need distinct transport paths at the same time.
    func testDuplicateNameCandidatesReceiveDistinctNonEmptyInstanceIDs() {
        let first = agentMember()
        let duplicate = agentMember()

        XCTAssertEqual(first.name, duplicate.name)
        XCTAssertFalse(first.agentInstanceId.isEmpty)
        XCTAssertFalse(duplicate.agentInstanceId.isEmpty)
        XCTAssertNotEqual(first.agentInstanceId, duplicate.agentInstanceId)
        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertNotEqual(first.transportId, duplicate.transportId)
        XCTAssertNotEqual(
            AgentPipeTransport.fifoPath(agentId: first.transportId),
            AgentPipeTransport.fifoPath(agentId: duplicate.transportId)
        )
        XCTAssertNotNil(UUID(uuidString: first.agentInstanceId))
        XCTAssertNotNil(UUID(uuidString: duplicate.agentInstanceId))
    }

    func testRecycleKeepsInstanceIDButReattachGetsANewOne() {
        let original = agentMember()
        var recycled = agentMember()
        recycled.agentInstanceId = original.agentInstanceId // hard restart swap contract
        let reattached = agentMember() // detach removes the old member first

        XCTAssertEqual(recycled.agentInstanceId, original.agentInstanceId)
        XCTAssertNotEqual(reattached.agentInstanceId, original.agentInstanceId)
    }

    func testCheckoutContractUsesRefsWithoutRejectingIsolatedBranch() {
        let lines = TeamOrchestrator.checkoutContractLines(
            targetBranch: "feat/distributed-workspaces",
            checkoutBranch: "agent/reviewer-260729",
            checkoutPath: "/app/tm-projects/term-mesh-reviewer-260729"
        )
        let contract = lines.joined(separator: "\n")

        XCTAssertTrue(contract.contains("PROJECT_TARGET_REF: origin/feat/distributed-workspaces"))
        XCTAssertTrue(contract.contains("AGENT_CHECKOUT_BRANCH: agent/reviewer-260729"))
        XCTAssertTrue(contract.contains("Never block solely because"))
        XCTAssertTrue(contract.contains("inspect explicit refs directly"))
        XCTAssertTrue(contract.contains("Do not checkout, reset, merge, or rebase"))
    }

    func testCheckoutTopologyMakesLeaderAndPeerIsolationExplicit() {
        let workers: [(name: String, instance: String, branch: String?, path: String?)] = [
            ("executor", "instance-a", "team/t/executor/a", "/wt/a"),
            ("reviewer", "instance-b", "team/t/reviewer/b", "/wt/b"),
        ]
        let leader = TeamOrchestrator.checkoutTopologySection(
            worktreeMode: "isolated", leaderPath: "/repo",
            integrationTargetPath: "/repo", workers: workers
        )
        XCTAssertTrue(leader.contains("TEAM_CHECKOUT_MODE: isolated"))
        XCTAssertTrue(leader.contains("LEADER_CHECKOUT_PATH: /repo"))
        XCTAssertTrue(leader.contains("LEADER_CHECKOUT_ROLE: integration-owner"))
        XCTAssertTrue(leader.contains("branch=team/t/executor/a path=/wt/a"))
        XCTAssertTrue(leader.contains("owned and forbidden path lists are optional"))
        XCTAssertTrue(leader.contains("instead of duplicating code"))
        XCTAssertTrue(leader.contains("never copy files out of a task branch instead of merging it"))

        let worker = TeamOrchestrator.workerCheckoutTopologyLines(
            worktreeMode: "isolated", leaderPath: "/repo",
            integrationTargetPath: "/repo", targetInstance: "instance-a",
            workers: workers
        ).joined(separator: "\n")
        XCTAssertTrue(worker.contains("PEER_CHECKOUT: name=reviewer instance=instance-b"))
        XCTAssertFalse(worker.contains("PEER_CHECKOUT: name=executor instance=instance-a"))
        XCTAssertTrue(worker.contains("owned and forbidden path lists are optional"))
        XCTAssertTrue(worker.contains("instead of duplicating code"))
        XCTAssertTrue(TeamOrchestrator.checkoutTopologyRule(worktreeMode: "shared").contains("Serialize writes"))
        XCTAssertTrue(TeamOrchestrator.checkoutTopologyRule(worktreeMode: "off").contains("No managed worktree isolation"))
        XCTAssertTrue(TeamOrchestrator.checkoutTopologyRule(worktreeMode: "unknown").contains("is unknown"))
    }

    /// `worktreeMode` answers whether this team asked for LOCAL git
    /// worktrees, and `NewProjectView` records "off" for it whenever the
    /// roster has no local member — every all-peer project. Briefing off that
    /// flag told those leaders and their workers there was no isolation to
    /// work in. The recorded layout answers instead, and a team that predates
    /// the record keeps its old answer.
    func testEffectiveCheckoutModePrefersTheRecordedLayout() {
        func mode(_ checkout: String, _ worktree: String) -> String {
            TeamOrchestrator.effectiveCheckoutMode(
                checkoutMode: checkout, worktreeMode: worktree, hasPeerMembers: false
            )
        }
        // The all-peer project this exists for.
        XCTAssertEqual(mode("isolated", "off"), "isolated")
        XCTAssertEqual(mode("shared", "off"), "shared")
        // No record: a resumed headless team keeps answering from its flag,
        // which for it is accurate.
        XCTAssertEqual(mode("unknown", "isolated"), "isolated")
        // An all-local team records nothing, so "off" — the strictest rule —
        // still reaches the prompt through the flag that is accurate for it.
        XCTAssertEqual(mode("unknown", "off"), "off")
        XCTAssertEqual(mode("", "shared"), "shared")
        XCTAssertEqual(mode("   ", "isolated"), "isolated")
        // A peer team whose layout nobody recorded keeps hedging rather than
        // asserting "no isolation" from a flag that only describes local
        // worktrees.
        XCTAssertEqual(
            TeamOrchestrator.effectiveCheckoutMode(
                checkoutMode: "unknown", worktreeMode: "off", hasPeerMembers: true
            ),
            "unknown"
        )
        XCTAssertEqual(
            TeamOrchestrator.effectiveCheckoutMode(
                checkoutMode: "isolated", worktreeMode: "off", hasPeerMembers: true
            ),
            "isolated"
        )
        // Newlines trim like every neighbouring call does.
        XCTAssertEqual(mode("isolated\n", "off"), "isolated")
        XCTAssertEqual(mode("\n", "shared"), "shared")
        XCTAssertTrue(
            TeamOrchestrator.checkoutTopologyRule(worktreeMode: mode("off", "isolated"))
                .contains("No managed worktree isolation")
        )
    }

    func testRemoteClaudeLaunchUsesSSHAndKeepsRemoteDirectoryOutOfLocalProcess() {
        let launch = AgentSession.remoteClaudeLaunch(
            sshTarget: "root@jw-server",
            port: 2222,
            identityFile: "/tmp/key file",
            model: "sonnet",
            instructions: "review 'carefully'",
            workingDirectory: "/app/project with space",
            remoteEnvironment: [
                "TERMMESH_SOCKET": "/run/user/0/tm-peer.sock",
                "TERMMESH_AGENT_NAME": "executor",
            ]
        )

        XCTAssertEqual(launch.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(launch.arguments.prefix(4)),
                       ["-T", "-o", "BatchMode=yes", "-o"])
        XCTAssertTrue(launch.arguments.contains("2222"))
        XCTAssertTrue(launch.arguments.contains("/tmp/key file"))
        XCTAssertEqual(launch.arguments.dropLast().last, "root@jw-server")
        XCTAssertTrue(launch.arguments.last?.contains("mkdir -p '/app/project with space'") == true)
        XCTAssertTrue(launch.arguments.last?.contains("claude") == true)
        XCTAssertTrue(launch.arguments.last?.contains("--print") == true)
        XCTAssertTrue(launch.arguments.last?.contains("IS_SANDBOX=1") == true)
        XCTAssertTrue(launch.arguments.last?.contains(
            "TERMMESH_SOCKET=/run/user/0/tm-peer.sock"
        ) == true)
        XCTAssertTrue(launch.arguments.last?.contains(
            "TERMMESH_AGENT_NAME=executor"
        ) == true)
        XCTAssertTrue(launch.arguments.last?.contains(
            "$HOME/.local/bin:/opt/homebrew/bin"
        ) == true)
        XCTAssertTrue(launch.arguments.last?.contains("$HOME/.profile") == true)
        XCTAssertTrue(launch.arguments.last?.contains(
            "$HOME/.config/term-mesh/agent-env"
        ) == true)
        XCTAssertTrue(launch.arguments.last?.contains("present_keys") == true)
        XCTAssertTrue(launch.arguments.last?.contains(
            #"export SHELL="$term_mesh_login_shell""#
        ) == true)
        XCTAssertTrue(launch.arguments.last?.contains("review") == true)
        XCTAssertNotEqual(launch.workingDirectory, "/app/project with space")
    }

    func testEnvironmentEventUpdatesPaneWithoutCarryingValues() {
        let session = AgentSession()
        var reported: AgentEnvironmentSummary?
        session.onEnvironmentSummary = { reported = $0 }
        session.ingestForTesting(event([
            "type": "system",
            "subtype": "environment",
            "shell": "zsh",
            "login": true,
            "interactive": false,
            "profile_fallback": "loaded",
            "agent_env": "missing",
            "present_keys": ["AI_MESH_API_KEY", "UNRECOGNIZED_SECRET"],
        ]))

        XCTAssertEqual(session.environmentSummary?.shell, "zsh")
        XCTAssertEqual(session.environmentSummary?.profileFallback, "loaded")
        XCTAssertEqual(session.environmentSummary?.agentEnv, "missing")
        XCTAssertEqual(session.environmentSummary?.presentKeys, Set(["AI_MESH_API_KEY"]))
        XCTAssertEqual(reported, session.environmentSummary)
        XCTAssertFalse(session.environmentSummary?.liveActivityText.contains("UNRECOGNIZED") == true)
    }

    @MainActor
    func testEnvironmentPresenceOverlayAndComparisonClearCarryNoValues() {
        let overlay = RemoteAgentEnvironmentShell.presenceOverlay([
            "AI_MESH_API_KEY": "super-secret",
            "UNRELATED": "also-secret",
        ])
        XCTAssertEqual(overlay, ["AI_MESH_API_KEY": "present"])
        XCTAssertFalse(String(describing: overlay).contains("super-secret"))

        let leader = AgentEnvironmentSummary(
            shell: "zsh", profileFallback: "loaded", agentEnv: "loaded",
            presentKeys: ["AI_MESH_API_KEY"]
        )
        let native = AgentEnvironmentSummary(
            shell: "zsh", profileFallback: "loaded", agentEnv: "missing",
            presentKeys: []
        )
        AgentEnvironmentComparisonStore.recordLeader(leader, teamName: "reused-team")
        XCTAssertNotNil(AgentEnvironmentComparisonStore.mismatchForNative(native, teamName: "reused-team"))
        var observed: String?
        AgentEnvironmentComparisonStore.recordNative(
            native, teamName: "reused-team", id: UUID()
        ) { observed = $0 }
        XCTAssertNotNil(observed)
        AgentEnvironmentComparisonStore.clearLeader(teamName: "reused-team")
        XCTAssertNil(observed)
        XCTAssertNil(AgentEnvironmentComparisonStore.mismatchForNative(native, teamName: "reused-team"))
        let removedID = UUID()
        var removedUpdates = 0
        AgentEnvironmentComparisonStore.recordNative(
            native, teamName: "reused-team", id: removedID
        ) { _ in removedUpdates += 1 }
        AgentEnvironmentComparisonStore.removeNative(teamName: "reused-team", id: removedID)
        AgentEnvironmentComparisonStore.recordLeader(leader, teamName: "reused-team")
        XCTAssertEqual(removedUpdates, 1)
        AgentEnvironmentComparisonStore.reset(teamName: "reused-team")
    }

    func testRemoteBridgeLaunchDescribesSSHChildWithoutMovingLocalBridgeCwd() throws {
        let launch = AgentSession.remoteBridgeLaunch(
            cli: "codex",
            bridgePath: "/bundle/tm-agent-bridge.py",
            model: "gpt-5",
            sshTarget: "root@peer",
            port: nil,
            identityFile: nil,
            workingDirectory: "/remote/repo",
            remoteEnvironment: [
                "TERMMESH_SOCKET": "/tmp/peer.sock",
                "TERMMESH_AGENT_NAME": "reviewer",
            ],
            environment: [:]
        )

        XCTAssertEqual(launch.executable, "/usr/bin/env")
        XCTAssertEqual(launch.environment["TERMMESH_REMOTE_NATIVE_CWD"], "/remote/repo")
        let encoded = try XCTUnwrap(
            launch.environment["TERMMESH_REMOTE_NATIVE_SSH_ARGS"]?.data(using: .utf8)
        )
        let ssh = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String]
        )
        XCTAssertEqual(ssh.first, "/usr/bin/ssh")
        XCTAssertEqual(ssh.last, "root@peer")
        let envData = try XCTUnwrap(
            launch.environment["TERMMESH_REMOTE_NATIVE_ENV"]?.data(using: .utf8)
        )
        let remoteEnv = try XCTUnwrap(
            JSONSerialization.jsonObject(with: envData) as? [String: String]
        )
        XCTAssertEqual(remoteEnv["TERMMESH_SOCKET"], "/tmp/peer.sock")
        XCTAssertEqual(remoteEnv["TERMMESH_AGENT_NAME"], "reviewer")
        XCTAssertNotEqual(launch.workingDirectory, "/remote/repo")
    }

    func testRemoteLaunchUsesStagedEnvironmentPathWithoutBearerInSSHArguments() {
        let bearer = String(repeating: "ab", count: 32)
        let file = "/Users/peer/.cache/term-mesh/agent-env/agent-test.env"
        let forward = (
            remote: "/tmp/term-mesh-agent-route-test.sock",
            local: "/tmp/term-mesh-debug-test.sock"
        )
        let claude = AgentSession.remoteClaudeLaunch(
            sshTarget: "peer",
            port: nil,
            identityFile: nil,
            model: "sonnet",
            instructions: "",
            workingDirectory: "/remote/repo",
            remoteEnvironment: ["TERMMESH_LEADER_GRANT_ID": bearer],
            remoteEnvironmentFile: file,
            reverseUnixForward: forward
        )
        let claudeArguments = claude.arguments.joined(separator: " ")
        XCTAssertTrue(claudeArguments.contains(file))
        XCTAssertFalse(claudeArguments.contains(bearer))
        XCTAssertTrue(claudeArguments.contains("rm -f"))
        XCTAssertTrue(claudeArguments.contains("StreamLocalBindUnlink=yes"))
        XCTAssertTrue(claudeArguments.contains("\(forward.remote):\(forward.local)"))

        let bridge = AgentSession.remoteBridgeLaunch(
            cli: "codex",
            bridgePath: "/bundle/tm-agent-bridge",
            model: "gpt-5",
            sshTarget: "peer",
            port: nil,
            identityFile: nil,
            workingDirectory: "/remote/repo",
            remoteEnvironment: ["TERMMESH_LEADER_GRANT_ID": bearer],
            remoteEnvironmentFile: file,
            reverseUnixForward: forward,
            environment: [:]
        )
        XCTAssertEqual(bridge.environment["TERMMESH_REMOTE_NATIVE_ENV_FILE"], file)
        XCTAssertNil(bridge.environment["TERMMESH_REMOTE_NATIVE_ENV"])
        XCTAssertFalse(bridge.arguments.joined(separator: " ").contains(bearer))
        let sshData = try! XCTUnwrap(
            bridge.environment["TERMMESH_REMOTE_NATIVE_SSH_ARGS"]?.data(using: .utf8)
        )
        let ssh = try! XCTUnwrap(
            JSONSerialization.jsonObject(with: sshData) as? [String]
        )
        XCTAssertTrue(ssh.contains("\(forward.remote):\(forward.local)"))
    }

    private func session(_ lines: [String]) -> AgentSession {
        let s = AgentSession()
        for line in lines { s.ingestForTesting(line) }
        return s
    }

    private func event(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    // MARK: - Who spoke

    /// A leader's task and a person's question are identical on the wire —
    /// deliberately, so the agent cannot treat them differently. The label is
    /// this side's business, and it is the only thing the pane could not say
    /// before: every replay used to read as the same anonymous "sent".
    func testTheReceiptRemembersWhoSentIt() throws {
        let s = AgentSession()
        s.noteSenderForTesting(.person)
        s.ingestForTesting(event(["type": "user", "isReplay": true,
                                  "message": ["role": "user", "content": "what did you find?"]]))
        guard case .said(_, let speaker, let text) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a sent turn")
        }
        XCTAssertEqual(speaker, .person)
        XCTAssertEqual(text, "what did you find?")
    }

    /// Drawn from the replay, not from the send.
    ///
    /// The pane path had to assume delivery: it typed, pressed Return from
    /// another process, and hoped. Here the message comes back, so what appears
    /// on screen is what the agent confirmed receiving rather than what was
    /// hoped for.
    func testNothingIsDrawnUntilTheAgentConfirmsIt() {
        let s = AgentSession()
        s.noteSenderForTesting(.leader)
        XCTAssertTrue(s.entries.isEmpty, "a send is not yet an event")
    }

    // MARK: - Tool calls

    /// The pairing a terminal cannot make.
    ///
    /// On a screen a call and its result are two unrelated lines, minutes and a
    /// scroll apart. Here the result carries the id of the call it answers, so
    /// they are one row that can hold a spinner, then a verdict, then folded
    /// output.
    func testAResultLandsOnTheCallItAnswers() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "swift build"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "Compiling…", "is_error": false]]]]),
        ])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.headline, "swift build", "the field that says what it will do")
        XCTAssertEqual(call.result, "Compiling…")
        XCTAssertFalse(call.failed)
        XCTAssertFalse(call.isRunning)
        XCTAssertEqual(s.entries.count, 1, "a call and its result are one thing, not two")
    }

    func testACallWithNoResultYetIsStillRunning() throws {
        let s = session([event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t1", "name": "Read",
             "input": ["file_path": "/tmp/x.swift"]]]]])])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertTrue(call.isRunning)
        XCTAssertEqual(call.headline, "/tmp/x.swift")
    }

    func testAFailedToolSaysSo() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "false"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "exit 1", "is_error": true]]]]),
        ])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertTrue(call.failed)
    }

    /// A result for a call this session never saw must not attach itself to
    /// whichever call happens to be last.
    func testAnOrphanResultIsIgnoredRatherThanMisattributed() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "swift build"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "somebody-else",
                 "content": "nope", "is_error": true]]]]),
        ])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertTrue(call.isRunning)
        XCTAssertFalse(call.failed)
    }

    // MARK: - Streaming

    private func delta(_ index: Int, _ text: String, thinking: Bool = false) -> String {
        let key = thinking ? "thinking" : "text"
        return event(["type": "stream_event", "event": [
            "type": "content_block_delta", "index": index,
            "delta": ["type": "\(key)_delta", key: text]]])
    }

    private func blockStart(_ index: Int, _ type: String) -> String {
        event(["type": "stream_event", "event": [
            "type": "content_block_start", "index": index,
            "content_block": ["type": type]]])
    }

    private func blockStop(_ index: Int) -> String {
        event(["type": "stream_event",
               "event": ["type": "content_block_stop", "index": index]])
    }

    /// One row, grown. Not a row per fragment — measured on a real answer,
    /// codex sent 163 deltas for sixty words.
    func testDeltasBuildOneRowRatherThanMany() throws {
        let s = session([blockStart(0, "text"), delta(0, "Tange"),
                         delta(0, "rines "), delta(0, "are small."), blockStop(0)])
        XCTAssertEqual(s.entries.count, 1)
        guard case .answered(_, let text) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(text, "Tangerines are small.")
    }

    /// A message interleaves thinking and text, addressed by index. A delta
    /// that appended to whatever was last would put reasoning in the answer.
    func testADeltaFindsItsOwnRow() throws {
        let s = session([
            blockStart(0, "thinking"), blockStart(1, "text"),
            delta(1, "the answer"), delta(0, "the reasoning", thinking: true),
            blockStop(0), blockStop(1),
        ])
        XCTAssertEqual(s.entries.count, 2)
        guard case .thought(_, let thought) = s.entries[0],
              case .answered(_, let answer) = s.entries[1] else {
            return XCTFail("expected a thought then an answer")
        }
        XCTAssertEqual(thought, "the reasoning")
        XCTAssertEqual(answer, "the answer")
    }

    /// A delta whose type does not match its block is dropped rather than
    /// forced in — reasoning must not end up inside the answer.
    func testADeltaOfTheWrongKindIsDropped() throws {
        let s = session([blockStart(0, "thinking"), delta(0, "not reasoning")])
        guard case .thought(_, let body) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a thought")
        }
        XCTAssertEqual(body, "")
    }

    /// Under `--include-partial-messages` a message arrives twice: once as
    /// deltas, then whole. Both drawn is the same paragraph printed twice.
    func testAStreamedMessageIsNotDrawnAgainWhenItArrivesWhole() throws {
        let s = session([
            event(["type": "stream_event", "event": ["type": "message_start",
                                                     "message": ["role": "assistant"]]]),
            blockStart(0, "text"), delta(0, "hello"), blockStop(0),
            event(["type": "assistant", "message": ["content": [
                ["type": "text", "text": "hello"]]]]),
        ])
        XCTAssertEqual(s.entries.count, 1, "the whole copy is the same content")
    }

    /// And a message that was *not* streamed still draws — the bridge's CLIs
    /// stream, but a turn can end before a block ever opens.
    func testAMessageThatNeverStreamedIsStillDrawn() {
        let s = session([
            event(["type": "stream_event", "event": ["type": "message_start",
                                                     "message": ["role": "assistant"]]]),
            event(["type": "assistant", "message": ["content": [
                ["type": "text", "text": "hello"]]]]),
        ])
        XCTAssertEqual(s.entries.count, 1)
    }

    /// The caret is the only thing that says "still writing"; a terminal can
    /// only show characters arriving and leave the rest to be guessed.
    func testTheOpenRowIsMarkedWhileItIsWritten() throws {
        let s = session([blockStart(0, "text"), delta(0, "half a sen")])
        let id = try XCTUnwrap(s.entries.first).id
        XCTAssertTrue(s.streamingIds.contains(id))
        s.ingestForTesting(blockStop(0))
        XCTAssertFalse(s.streamingIds.contains(id))
    }

    /// kiro reports occupancy as a percentage and no token count at all, so
    /// there is nothing to divide. The reading is still real and the header
    /// still has a number to show.
    func testAStatedFractionIsAReadingWithoutAnyTokenCount() throws {
        let s = session([
            event(["type": "system", "subtype": "init", "model": "kiro-default"]),
            event(["type": "result", "stop_reason": "end_turn",
                   "context_fraction": 0.166722]),
        ])
        let usage = try XCTUnwrap(s.usage)
        XCTAssertNil(usage.contextTokens)
        XCTAssertEqual(try XCTUnwrap(usage.contextUsageFraction), 0.166722, accuracy: 1e-6)
    }
    /// A bridged CLI states the window it was given. Codex sends
    /// `modelContextWindow` with every usage update, and that beats a table
    /// this build shipped with: it cannot go stale, and it is right for a
    /// model nobody has added to one.
    func testStatedContextWindowBeatsTheModelTable() throws {
        let s = session([
            event(["type": "system", "subtype": "init", "model": "gpt-5.6-sol"]),
            event(["type": "result", "stop_reason": "end_turn",
                   "context_window": 258_400,
                   "usage": [
                       "input_tokens": 23_274,
                       "cache_read_input_tokens": 0,
                       "cache_creation_input_tokens": 0,
                       "output_tokens": 10,
                   ]]),
        ])
        let usage = try XCTUnwrap(s.usage)
        XCTAssertEqual(usage.contextTokens, 23_274)
        XCTAssertEqual(usage.contextWindow, 258_400)
        XCTAssertEqual(
            try XCTUnwrap(usage.contextUsageFraction),
            23_274.0 / 258_400.0,
            accuracy: 0.0001
        )
    }
    /// Occupancy is the whole prompt the model saw. Claude reads most of a
    /// long conversation out of the cache, so `input_tokens` alone reports
    /// single digits for a nearly full window — the pane header would have
    /// said 0% at 900k tokens.
    func testTurnUsageCountsCachedInputTowardContextOccupancy() throws {
        let s = session([
            event(["type": "system", "subtype": "init", "model": "claude-sonnet-4-5"]),
            event(["type": "result", "stop_reason": "end_turn", "usage": [
                "input_tokens": 12,
                "cache_read_input_tokens": 180_000,
                "cache_creation_input_tokens": 2_400,
                "output_tokens": 350,
            ]]),
        ])
        let usage = try XCTUnwrap(s.usage)
        XCTAssertEqual(usage.contextTokens, 182_412)
        XCTAssertEqual(usage.inputTokens, 12)
        XCTAssertEqual(usage.cacheReadTokens, 180_000)
        XCTAssertEqual(usage.outputTokens, 350)
        XCTAssertEqual(usage.model, "claude-sonnet-4-5")
    }

    /// A turn that reports nothing must not erase the last real reading: a
    /// window does not empty because one turn failed before the model saw
    /// anything.
    func testTurnWithoutUsageKeepsTheLastContextReading() throws {
        let s = session([
            event(["type": "system", "subtype": "init", "model": "claude-sonnet-4-5"]),
            event(["type": "result", "stop_reason": "end_turn", "usage": [
                "input_tokens": 5, "cache_read_input_tokens": 40_000,
            ]]),
            event(["type": "result", "is_error": true, "result": ""]),
        ])
        XCTAssertEqual(try XCTUnwrap(s.usage).contextTokens, 40_005)
    }
    /// Measured on kiro: five tool rows left spinning, because the bridge
    /// dropped the `toolCallId` its results carried and a row with no id can
    /// never be closed by one. The id is carried now — and a CLI that simply
    /// never reports a result is still possible, so the turn being over is
    /// taken as proof that nothing is still running.
    func testATurnEndingClosesToolRowsThatNeverReported() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Read",
                 "input": ["file_path": "/tmp/x"]]]]]),
            event(["type": "result", "stop_reason": "end_turn"]),
        ])
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertFalse(call.isRunning, "the turn is over; nothing is still running")
        XCTAssertFalse(call.failed, "and not reporting is not the same as failing")
    }

    /// A turn can end with a block still open — an error, a stop, a killed
    /// process. A caret left on says "still writing" forever.
    func testATurnEndingMidStreamStopsTheCaret() {
        let s = session([blockStart(0, "text"), delta(0, "cut off"),
                         event(["type": "result", "is_error": true, "result": ""])])
        XCTAssertTrue(s.streamingIds.isEmpty)
    }

    /// Streamed text is the turn's answer, so a CLI that sends no `result`
    /// text still reports what it said.
    func testStreamedTextCountsAsWhatWasSaid() throws {
        var final: String?
        let s = AgentSession()
        s.onTurnEnd = { text, _, _ in final = text }
        for line in [blockStart(0, "text"), delta(0, "streamed only"), blockStop(0),
                     event(["type": "result", "stop_reason": "end_turn"])] {
            s.ingestForTesting(line)
        }
        XCTAssertEqual(final, "streamed only")
    }

    /// The launch has to ask for deltas, or a turn appears all at once when it
    /// is already over.
    func testTheLaunchAsksForPartialMessages() {
        let launch = AgentSession.claudeLaunch(
            claudePath: "/usr/local/bin/claude", model: "haiku",
            instructions: "", extraArgs: [], workingDirectory: "/tmp")
        XCTAssertTrue(launch.arguments.contains("--include-partial-messages"))
    }

    func testNativeWorkerLaunchTurnsWorkerPluginsOff() throws {
        let launch = AgentSession.claudeLaunch(
            claudePath: "/usr/local/bin/claude", model: "haiku",
            instructions: "", extraArgs: ["--extra"], workingDirectory: "/tmp")
        let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--settings"))
        XCTAssertEqual(launch.arguments[index + 1], AgentSession.workerSettingsJSON)
        XCTAssertLessThan(index, try XCTUnwrap(launch.arguments.firstIndex(of: "--extra")),
                          "a profile's own arguments come last and can still override")
    }

    func testNativeLaunchKeepsInjectedTeamEnvironment() {
        let environment = [
            "HOME": "/Users/test",
            "PATH": "/bundle/bin:/usr/bin",
            "TERMMESH_TEAM": "ebpf",
            "TERMMESH_AGENT_NAME": "architect",
            "TERMMESH_WORKSPACE_ID": "workspace-id",
            "TERMMESH_SOCKET": "/tmp/term-mesh.sock",
        ]

        let claude = AgentSession.claudeLaunch(
            claudePath: "/usr/local/bin/claude", model: "sonnet",
            instructions: "", extraArgs: [], workingDirectory: "/tmp",
            environment: environment, loadsAccountEnvironment: true)
        let bridged = AgentSession.bridgeLaunch(
            cli: "codex", bridgePath: "/bundle/bridge", model: "gpt-5",
            workingDirectory: "/tmp", environment: environment,
            loadsAccountEnvironment: true)

        XCTAssertEqual(claude.environment, environment)
        XCTAssertEqual(bridged.environment, environment)
        XCTAssertTrue(claude.loadsAccountEnvironment)
        XCTAssertTrue(bridged.loadsAccountEnvironment)
    }

    func testLocalNativeLaunchLoadsAgentEnvWithoutPuttingSecretInArgv() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-agent-env-\(UUID().uuidString)")
        let config = root.appendingPathComponent(".config/term-mesh")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "AI_MESH_API_KEY=from-agent-env\n".write(
            to: config.appendingPathComponent("agent-env"),
            atomically: true, encoding: .utf8
        )

        let command = AgentSession.localAccountEnvironmentCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'key=%s explicit=%s' \"$AI_MESH_API_KEY\" \"$EXPLICIT_VALUE\""],
            protectedEnvironmentKeys: ["EXPLICIT_VALUE"]
        )
        XCTAssertFalse(command.contains("profile-secret"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "HOME": root.path,
            "ZDOTDIR": root.path,
            "SHELL": "/bin/zsh",
            "TERMMESH_LAUNCH_ENV_0": "profile-secret",
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains(#""agent_env":"loaded""#))
        XCTAssertTrue(text.hasSuffix("key=from-agent-env explicit=profile-secret"))
    }

    func testNativeTranscriptCanBeReadWithLineLimit() {
        let s = session([
            event(["type": "user", "isReplay": true,
                   "message": ["role": "user", "content": "first\nsecond"]]),
            event(["type": "assistant", "message": ["content": [
                ["type": "text", "text": "third\nfourth"]]]]),
        ])

        XCTAssertEqual(s.visibleTranscriptText(), "leader: first\nsecond\nthird\nfourth")
        XCTAssertEqual(s.visibleTranscriptText(lineLimit: 2), "third\nfourth")
    }

    // MARK: - The header is a value, not prose

    /// Measured on a real transcript: an answer was six lines, five of them
    /// this header. And the app was already parsing it to close the task — so
    /// it was shown raw *and* read structurally, and only one of those is
    /// necessary.
    func testTheHeaderLeavesTheProseAndBecomesAVerdict() throws {
        var ended: AgentSession.TurnEnd?
        let s = AgentSession()
        s.onTurnEnd = { _, end, _ in ended = end }
        s.ingestForTesting(event(["type": "assistant", "message": ["content": [
            ["type": "text", "text": """
                OK3

                STATUS: DONE
                FILES: none
                VERIFY: n/a
                NEXT: NONE
                FULL_REPORT: n/a
                """]]]]))
        s.ingestForTesting(event(["type": "result", "stop_reason": "end_turn"]))

        guard case .answered(_, let body) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(body, "OK3", "five of six lines were protocol")
        let verdict = try XCTUnwrap(ended?.verdict)
        XCTAssertEqual(verdict.status, "DONE")
        XCTAssertTrue(verdict.isDone)
    }

    /// Four "none"s in a row is worse than no detail at all.
    func testOnlyTheFieldsTheAgentFilledInAreWorthShowing() {
        let (_, v) = AgentSession.splitVerdict(from: """
            STATUS: DONE
            FILES: none
            VERIFY: swift build
            NEXT: NONE
            FULL_REPORT: n/a
            """)
        XCTAssertEqual(v?.details.map(\.0), ["VERIFY"])
    }

    /// An answer that was only a header leaves an empty row behind.
    func testAnAnswerThatWasOnlyAHeaderLeavesNoEmptyRow() {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "text", "text": "STATUS: DONE\nFILES: none"]]]]),
            event(["type": "result", "stop_reason": "end_turn"]),
        ])
        XCTAssertFalse(s.entries.contains { if case .answered = $0 { return true } else { return false } })
    }

    /// Prose with no header is left exactly as it is.
    func testAnAnswerWithNoHeaderIsUntouched() {
        let (body, v) = AgentSession.splitVerdict(from: "just some prose\nover two lines")
        XCTAssertEqual(body, "just some prose\nover two lines")
        XCTAssertNil(v)
    }

    // MARK: - An instruction is not its envelope

    /// Measured: sixteen lines, nine of them scaffold, the intent one line
    /// inside `[GOAL]`. The bubble was showing the envelope and burying the
    /// letter.
    func testTheGoalIsWhatTheBubbleShows() {
        let capsule = """
            [FINAL LINE — end your reply with this header, one field per line]
            STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>
            FILES: <changed paths or none>

            ## Task Capsule
            TASK_ID: cca01f9c
            TASK_TITLE: Reply with exactly: OK1.
            PROTOCOL: TM-PROTOCOL-v1
            OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus concise summary

            [GOAL]
            Reply with exactly: OK1. Nothing else, no tools.
            [/GOAL]
            """
        let read = AgentSession.read(instruction: capsule)
        XCTAssertEqual(read.headline, "Reply with exactly: OK1. Nothing else, no tools.")
        XCTAssertEqual(read.taskId, "cca01f9c")
        XCTAssertTrue(read.hasMore, "the envelope is still reachable")
        XCTAssertEqual(read.full, capsule)
    }

    /// A plain message has no envelope to fold, so nothing is hidden and no
    /// disclosure appears.
    func testAPlainMessageShowsWholeAndOffersNothingToUnfold() {
        let read = AgentSession.read(instruction: "have a look at the build")
        XCTAssertEqual(read.headline, "have a look at the build")
        XCTAssertFalse(read.hasMore)
        XCTAssertNil(read.taskId)
    }

    /// Without a capsule the protocol lines still go, and what a person wrote
    /// stays.
    func testProtocolLinesGoEvenWithoutAGoalBlock() {
        let read = AgentSession.read(instruction: """
            Reply with the word TANGO.

            [FINAL LINE — end your reply with this header, one field per line]
            STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>
            FULL_REPORT: <result file path or n/a>
            """)
        XCTAssertEqual(read.headline, "Reply with the word TANGO.")
    }

    /// The bug the screenshot caught.
    ///
    /// Filtering by line prefix alone ate two real lines out of a runbook
    /// digest — its `VERIFY:` and `OUTPUT:` rows, which say what the role must
    /// do — because those prefixes are also header keys. Only a capsule is
    /// folded now; anything else is shown exactly as sent.
    func testARunbookIsNotMistakenForAnEnvelope() {
        let digest = """
            ## Runbook Digest
            ROLE: explorer
            WHEN: The task asks where something is defined.
            VERIFY: Include the exact search command you used.
            OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT
            FULL: /repo/.agent-runbooks/explorer.md
            """
        let read = AgentSession.read(instruction: digest)
        XCTAssertEqual(read.headline, digest, "nothing the leader sent may vanish")
        XCTAssertFalse(read.hasMore)
    }

    // MARK: - What the review found

    /// A pipe read ends wherever the kernel handed the buffer over, which can
    /// be the middle of a multi-byte character. Decoding each chunk on arrival
    /// and dropping it when that fails loses the whole chunk — and if the line
    /// it lands in is `result`, the turn never ends at all.
    func testALineSplitMidCharacterStillArrivesWhole() throws {
        var ended: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { text, _, _ in ended.append(text) }
        let line = event(["type": "result", "stop_reason": "end_turn",
                          "result": "감귤류 재배의 역사는 길다"])
        var bytes = Array(Data((line + "\n").utf8))
        // Cut inside the first Korean character.
        let cut = bytes.firstIndex(of: 0xEA) ?? (bytes.count / 2)
        let head = Data(bytes[..<(cut + 1)])
        let tail = Data(bytes[(cut + 1)...])
        s.consumeForTesting(head)
        XCTAssertTrue(ended.isEmpty, "half a character is not a line")
        s.consumeForTesting(tail)
        XCTAssertEqual(ended, ["감귤류 재배의 역사는 길다"])
    }

    /// Several lines in one read, and a trailing partial that waits.
    func testWholeLinesArriveEvenWhenTheLastOneIsPartial() {
        let s = AgentSession()
        let a = event(["type": "assistant", "message": ["content": [["type": "text", "text": "one"]]]])
        let b = event(["type": "assistant", "message": ["content": [["type": "text", "text": "two"]]]])
        s.consumeForTesting(Data((a + "\n" + b + "\n" + "{\"partial").utf8))
        XCTAssertEqual(s.entries.count, 2)
    }

    /// A person typing in the composer opens a turn too. This used to be set
    /// only for leader writes, so a task arriving during a person's turn went
    /// straight into the same stdin and took the task correlation with it — the
    /// person's result would then close the leader's task.
    func testALeaderTaskWaitsBehindAPersonsTurn() throws {
        var answered: [String?] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, task in answered.append(task) }
        s.openTurnForTesting(from: .person)
        s.queueForTesting("TASK_ID: abc12345\ndo the thing")

        // The person's turn ends first, and it answers no task.
        s.ingestForTesting(event(["type": "result", "result": "person answer"]))
        XCTAssertEqual(answered, [nil], "a person's turn carries no task")
    }

    /// If the process dies mid-turn its task would sit `in_progress` forever
    /// and everything queued behind it would never be delivered.
    func testAProcessThatDiesMidTurnEndsTheTurn() {
        var reported: [(String, String?)] = []
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession()
        s.onTurnEnd = { text, _, task in reported.append((text, task)) }
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.openTurnForTesting(from: .leader, taskId: "e82188a0")
        s.finishForTesting(code: 1)

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.1, "e82188a0")
        // Nobody said it worked and the agent is not there to say: the task
        // is handed back as lost, not settled by this text.
        XCTAssertNil(AgentPipeCompletion.explicitStatus(in: reported.first!.0))
        XCTAssertEqual(lost.map(\.0), ["e82188a0"])
        XCTAssertEqual(lost.first?.1, .sessionEnded("the agent exited before an explicit STATUS"))
        XCTAssertNil(s.pendingTaskIdForTesting)
    }

    /// A worker that ended its turn without a verdict and then went away has
    /// no turn in flight to end, but its task still must not sit open.
    func testAnExitBetweenTurnsStillHandsBackThePendingTask() {
        var ends = 0
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, _ in ends += 1 }
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.openTurnForTesting(from: .leader, taskId: "between")
        s.ingestForTesting(event(["type": "result", "result": "running it in the background"]))
        XCTAssertEqual(ends, 1)

        s.finishForTesting(code: 0)

        XCTAssertEqual(ends, 1, "no turn was running, so none is ended")
        XCTAssertEqual(lost.map(\.0), ["between"])
        XCTAssertEqual(lost.first?.1, .sessionEnded("the agent exited before an explicit STATUS"))
    }

    /// Process termination and the last readability callback are independent.
    /// The result must be consumed before exit is classified, exactly once.
    func testNaturalExitDrainsTheFinalResultBeforeFinishing() async {
        var reported: [(String, String, Bool)] = []
        let s = AgentSession()
        s.onTurnEnd = { text, end, _ in
            reported.append((text, end.stop, end.failed))
        }
        s.openTurnForTesting(from: .leader, taskId: "drain-final-result")
        s.start(shortProcess(output: event([
            "type": "result", "stop_reason": "end_turn",
            "result": "the final frame survived",
        ])))

        let stopped = await waitUntil { !s.isRunning }
        XCTAssertTrue(stopped)
        XCTAssertEqual(reported.count, 1, "exit must not emit a second turn end")
        XCTAssertEqual(reported.first?.0, "the final frame survived")
        XCTAssertEqual(reported.first?.1, "end_turn")
        XCTAssertEqual(reported.first?.2, false)
    }

    /// Both natural finish and deliberate stop release `process`, so one model
    /// can start another process instead of remaining permanently stopped.
    func testFinishedAndStoppedSessionsCanRestart() async {
        var answers: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { text, _, _ in answers.append(text) }

        s.openTurnForTesting(from: .person)
        s.start(shortProcess(output: event([
            "type": "result", "stop_reason": "end_turn", "result": "first",
        ])))
        let firstStopped = await waitUntil { !s.isRunning }
        XCTAssertTrue(firstStopped)

        s.start(.init(
            executable: "/bin/sleep", arguments: ["30"],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))
        XCTAssertTrue(s.isRunning)
        s.stop()
        s.stop() // teardown is intentionally idempotent
        XCTAssertFalse(s.isRunning)

        // A synchronous launch error uses the same teardown and must not leave
        // the session's process guard occupied either.
        s.start(.init(
            executable: "/definitely/not/a/real/agent", arguments: [],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))
        XCTAssertFalse(s.isRunning)

        s.openTurnForTesting(from: .person)
        s.start(shortProcess(output: event([
            "type": "result", "stop_reason": "end_turn", "result": "second",
        ])))
        let secondStopped = await waitUntil { !s.isRunning }
        XCTAssertTrue(secondStopped)
        XCTAssertEqual(answers, ["first", "second"])
    }

    /// If a spawned process leaves a grandchild holding the write end of
    /// stdout open, natural EOF never arrives. A blocking tail read on
    /// termination would then wedge the stream queue, and a `stop()` that
    /// synchronously waits on that queue would freeze MainActor forever.
    func testStopDoesNotWaitForInheritedStdoutWriter() async {
        let s = AgentSession()
        s.start(.init(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' HUP; sleep 5 & exec /usr/bin/true"],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        ))

        // The owned process has exited; its descendant still owns stdout.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let began = Date()
        s.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
        XCTAssertFalse(s.isRunning)

        // Teardown stays idempotent and actor-visible restart is immediate.
        s.stop()
        s.openTurnForTesting(from: .person)
        s.start(shortProcess(output: event([
            "type": "result", "stop_reason": "end_turn", "result": "restarted",
        ])))
        let stopped = await waitUntil { !s.isRunning }
        XCTAssertTrue(stopped)
    }

    private func shortProcess(output: String) -> AgentSession.Launch {
        .init(
            executable: "/bin/echo", arguments: [output],
            workingDirectory: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// The bridge command the terminal path builds had neither.
    func testTheTerminalBridgeCarriesTheModelAndThePath() {
        let cmd = AgentPipeTransport.bridgeLaunchCommand(
            cli: "codex", fifoPath: "/tmp/p/x.stdin",
            model: TeamOrchestrator.bridgeModelArg(cli: "codex", model: "sonnet"),
            cliPath: "/opt/homebrew/bin/codex",
            bridgePath: "/repo/bridge.py", rendererPath: nil,
            workingDirectory: "/tmp")
        XCTAssertTrue(cmd.contains("gpt-5.6-sol"), "a tier is not a model codex knows")
        XCTAssertFalse(cmd.contains("sonnet"))
        XCTAssertTrue(cmd.contains("--exe"))
        XCTAssertTrue(cmd.contains("/opt/homebrew/bin/codex"))
    }

    /// `markDriven` had no counterpart, so a name kept its pipe registration
    /// after its pane was gone and a later terminal-hosted agent of the same
    /// name had every send routed to a FIFO that no longer existed.
    func testReleasingAnAgentUndoesItsRegistration() {
        let id = "reviewer@release-test"
        AgentPipeTransport.markDriven(agentId: id)
        XCTAssertTrue(AgentPipeTransport.isDriven(agentId: id))
        TeamOrchestrator.releaseTransport(agentId: id)
        XCTAssertFalse(AgentPipeTransport.isDriven(agentId: id))
    }

    // MARK: - A turn is one thing

    private var say: AgentSession.Entry { .said(id: UUID(), .leader, "do it") }
    private var think: AgentSession.Entry { .thought(id: UUID(), "hm") }
    private var toolRow: AgentSession.Entry {
        .tool(id: UUID(), .init(name: "Bash", headline: "ls"))
    }
    private var answer: AgentSession.Entry { .answered(id: UUID(), "done") }
    private var footer: AgentSession.Entry {
        .turnEnded(id: UUID(), .init(stop: "end_turn", failed: false, cost: nil,
                                     duration: nil, tokensIn: nil, tokensOut: nil))
    }

    /// At one gap for everything, a turn's five parts read as five unrelated
    /// rows. Tight inside a turn, open between them.
    func testATurnIsSpacedAsOneThing() {
        let inside = AgentSession.topGap(before: answer, after: think)
        let footerGap = AgentSession.topGap(before: footer, after: answer)
        let between = AgentSession.topGap(before: say, after: footer)

        XCTAssertLessThan(footerGap, inside, "a footer closes the answer above it")
        XCTAssertGreaterThan(between, inside, "a new turn needs room")
        // Reasoning and the tools it drives are one train of thought.
        XCTAssertLessThanOrEqual(AgentSession.topGap(before: toolRow, after: think), 4)
        XCTAssertLessThanOrEqual(AgentSession.topGap(before: toolRow, after: toolRow), 4)
    }

    /// A new instruction starts a turn wherever it lands, even mid-stream.
    func testAnInstructionAlwaysStartsATurn() {
        XCTAssertEqual(AgentSession.topGap(before: say, after: answer),
                       AgentSession.topGap(before: say, after: footer))
    }

    /// The view must not have to look at a row's neighbour, nor read identity
    /// through the enum, to lay a transcript out.
    ///
    /// Deriving either during layout is what let a `LazyVStack` placement pass
    /// re-enter itself and spin the main thread at 100% with the view graph
    /// never converging.
    func testRowsCarryTheirOwnIdentityAndSpacing() {
        let entries = [say, think, toolRow, answer, footer]
        let rows = AgentSession.rows(for: entries)

        XCTAssertEqual(rows.map(\.id), entries.map(\.id))
        // Each row's gap is the one the neighbour rule gives it, already applied.
        var previous: AgentSession.Entry?
        for (row, entry) in zip(rows, entries) {
            XCTAssertEqual(row.topGap, AgentSession.topGap(before: entry, after: previous))
            previous = entry
        }
        // The first row has no neighbour to depend on.
        XCTAssertEqual(rows.first?.topGap, AgentSession.topGap(before: say, after: nil))
        XCTAssertTrue(AgentSession.rows(for: []).isEmpty)
    }

    /// A thought immediately ahead of a tool run folds into it — that is the
    /// point of the fix — but the group's disclosure identity still pins to
    /// the first *tool*, not to the thought now sitting ahead of it in `rows`.
    func testTranscriptItemsGroupThreeConsecutiveToolsWithStableIdentity() {
        let firstID = UUID()
        let entries: [AgentSession.Entry] = [
            .thought(id: UUID(), "checking"),
            .tool(id: firstID, .init(name: "shell", headline: "rg foo", result: "")),
            .tool(id: UUID(), .init(name: "shell", headline: "sed -n 1,20p", result: "")),
            .tool(id: UUID(), .init(name: "read", headline: "AgentPanelView.swift", result: nil)),
            .answered(id: UUID(), "done"),
        ]

        let items = AgentSession.transcriptItems(for: AgentSession.rows(for: entries))

        XCTAssertEqual(items.count, 2)
        guard case .toolGroup(let group) = items[0] else {
            return XCTFail("the leading thought and three tools should become one group")
        }
        XCTAssertEqual(group.id, firstID)
        XCTAssertEqual(group.rows.count, 4)
        XCTAssertEqual(group.kindSummary, "shell 2 · read")
        XCTAssertTrue(group.isRunning)
        XCTAssertEqual(group.failureCount, 0)
    }

    /// Grouping now splits at prose, not at an interleaved thought: a run of
    /// three tools still becomes one group, and counts and failures still
    /// aggregate across it regardless of where a `thought` sits in the middle.
    func testTranscriptItemsKeepShortRunsInlineAndSplitAtProse() {
        let entries: [AgentSession.Entry] = [
            .answered(id: UUID(), "starting"),
            .tool(id: UUID(), .init(name: "shell", headline: "three", result: "")),
            .thought(id: UUID(), "next"),
            .tool(id: UUID(), .init(name: "edit", headline: "four", result: "")),
            .tool(id: UUID(), .init(name: "shell", headline: "five", result: "failed", failed: true)),
            .answered(id: UUID(), "done"),
        ]

        let items = AgentSession.transcriptItems(for: AgentSession.rows(for: entries))

        XCTAssertEqual(items.count, 3)
        guard case .row = items[0] else {
            return XCTFail("prose ahead of the run should remain its own row")
        }
        guard case .toolGroup(let group) = items[1] else {
            return XCTFail("the run of three tools should form its own group")
        }
        XCTAssertFalse(group.isRunning)
        XCTAssertEqual(group.failureCount, 1)
        XCTAssertEqual(group.kindSummary, "shell 2 · edit")
        guard case .row = items[2] else {
            return XCTFail("prose after the run should remain its own row")
        }
    }

    /// (a) A thought sandwiched directly between two tools is part of the same
    /// run; `kindSummary` ignoring it keeps the group's tool count honest.
    func testAThoughtBetweenTwoToolsJoinsTheGroup() {
        let entries: [AgentSession.Entry] = [
            .tool(id: UUID(), .init(name: "shell", headline: "one", result: "")),
            .thought(id: UUID(), "checking the result"),
            .tool(id: UUID(), .init(name: "shell", headline: "two", result: nil)),
        ]

        let items = AgentSession.transcriptItems(for: AgentSession.rows(for: entries))

        XCTAssertEqual(items.count, 1)
        guard case .toolGroup(let group) = items[0] else {
            return XCTFail("tool, thought, tool should become one group")
        }
        XCTAssertEqual(group.rows.count, 3)
        XCTAssertEqual(group.kindSummary, "shell 2")
    }

    /// (b) Two consecutive thoughts never touch a tool, so the run they
    /// buffer counts zero tools and must never become a group.
    func testTwoConsecutiveThoughtsNeverBecomeAGroup() {
        let entries: [AgentSession.Entry] = [
            .thought(id: UUID(), "first idea"),
            .thought(id: UUID(), "second idea"),
        ]

        let items = AgentSession.transcriptItems(for: AgentSession.rows(for: entries))

        XCTAssertEqual(items.count, 2)
        for item in items {
            guard case .row = item else {
                return XCTFail("a thought-only run must stay individual rows, got \(item)")
            }
        }
    }

    /// (c) A single tool below `minimumToolCount` stays inline even with
    /// prose on both sides.
    func testASingleToolBetweenProseStaysInline() {
        let entries: [AgentSession.Entry] = [
            .answered(id: UUID(), "before"),
            .tool(id: UUID(), .init(name: "shell", headline: "one", result: "")),
            .answered(id: UUID(), "after"),
        ]

        let items = AgentSession.transcriptItems(for: AgentSession.rows(for: entries))

        XCTAssertEqual(items.count, 3)
        for item in items {
            guard case .row = item else {
                return XCTFail("a single tool call must remain inline, got \(item)")
            }
        }
    }

    /// (d) A thought with no tool on either side of it is not "between
    /// tools" and must not be swallowed into a neighbouring group.
    func testALoneThoughtBetweenProseStaysIndependent() {
        let entries: [AgentSession.Entry] = [
            .answered(id: UUID(), "before"),
            .thought(id: UUID(), "just thinking"),
            .answered(id: UUID(), "after"),
        ]

        let items = AgentSession.transcriptItems(for: AgentSession.rows(for: entries))

        XCTAssertEqual(items.count, 3)
        guard case .row(let row) = items[1], case .thought = row.entry else {
            return XCTFail("a lone thought between prose should remain its own row")
        }
    }

    /// The panel uses a regular VStack to avoid SwiftUI's non-converging lazy
    /// placement path. Keep its mounted view tree bounded independently from
    /// the longer model transcript.
    func testDisplayedRowsKeepOnlyTheRecentBoundedWindow() {
        let entries = (0..<(AgentSession.maxRenderedEntries + 17)).map { index in
            AgentSession.Entry.said(id: UUID(), .leader, "instruction \(index)")
        }

        let display = AgentSession.displayRows(for: entries)

        XCTAssertEqual(display.omitted, 17)
        XCTAssertEqual(display.rows.count, AgentSession.maxRenderedEntries)
        XCTAssertEqual(display.rows.map(\.id),
                       Array(entries.suffix(AgentSession.maxRenderedEntries)).map(\.id))
        XCTAssertEqual(display.rows.first?.topGap,
                       AgentSession.topGap(before: entries[17], after: nil))
    }

    func testVisibleTranscriptSnapshotMatchesNativeRowsAndAppliesTailLimit() {
        let longThought = String(repeating: "x", count: 20) + String(repeating: "y", count: 120)
        let end = AgentSession.TurnEnd(
            stop: "end_turn",
            failed: false,
            cost: 0.25,
            duration: 1.2,
            tokensIn: 3,
            tokensOut: 5,
            completedAt: Date(timeIntervalSince1970: 0)
        )
        let rows = AgentSession.rows(for: [
            .said(id: UUID(), .leader, "inspect this"),
            .answered(id: UUID(), "alpha\nbeta"),
            .thought(id: UUID(), longThought),
            .tool(id: UUID(), .init(name: "Bash", headline: "swift test", result: "folded output")),
            .turnEnded(id: UUID(), end),
            .notice(id: UUID(), "connection restored"),
        ])

        let snapshot = AgentSession.visibleTranscriptText(rows: rows)
        XCTAssertTrue(snapshot.contains("leader: inspect this"))
        XCTAssertTrue(snapshot.contains("alpha\nbeta"), "streaming answers remain readable in full")
        XCTAssertFalse(snapshot.contains("✻"), "reasoning cannot reproduce the UI's two-line clamp off-screen")
        XCTAssertFalse(snapshot.contains(longThought))
        XCTAssertTrue(snapshot.contains("Bash swift test"))
        XCTAssertFalse(snapshot.contains("folded output"), "collapsed tool output is not user-visible")
        let turnFacts = AgentSession.turnFacts(end)
        XCTAssertTrue(snapshot.contains(turnFacts))
        XCTAssertTrue(snapshot.hasSuffix("! connection restored"))

        XCTAssertEqual(
            AgentSession.visibleTranscriptText(rows: rows, lineLimit: 2),
            "\(turnFacts)\n! connection restored"
        )
        XCTAssertEqual(AgentSession.visibleTranscriptText(rows: rows, lineLimit: 0), "")
    }

    func testVisibleTranscriptRedactsAndBoundsToolHeadlineBeforeKeepingItsTail() {
        let secret = "tail-secret-credential"
        let raw = "curl https://example.test\n" + String(repeating: "argument ", count: 40)
            + "--token \"\(secret) with spaces\""
        let rows = AgentSession.rows(for: [
            .tool(id: UUID(), .init(name: "Bash", headline: raw)),
        ])

        let projected = AgentSession.projectedToolHeadline(raw)
        XCTAssertLessThanOrEqual(projected.utf8.count, 160)
        XCTAssertFalse(projected.contains("\n"))
        XCTAssertTrue(projected.contains("[redacted]"))
        XCTAssertFalse(projected.contains(secret))

        let snapshot = AgentSession.visibleTranscriptText(rows: rows)
        XCTAssertFalse(snapshot.contains(secret), "middle-tail retention must happen only after redaction")
        XCTAssertLessThanOrEqual(snapshot.utf8.count, 165)
    }

    /// Measured against a live native pane: the tool row already read
    /// `Bash echo API_KEY=[redacted]` while the agent's own answer repeated the
    /// value verbatim on the next line, and a socket read carried it off the
    /// machine. Redaction belongs to the read, not to one row kind.
    func testVisibleTranscriptRedactsCredentialsInEveryRowKindNotOnlyTools() {
        let token = "sk-proj-FAKEFAKEFAKEFAKE1234"
        let rows = AgentSession.rows(for: [
            .said(id: UUID(), .leader, "run this: echo API_KEY=\(token)"),
            .tool(id: UUID(), .init(name: "Bash", headline: "echo API_KEY=\(token)")),
            .answered(id: UUID(), "the command printed:\nAPI_KEY=\(token)"),
            .notice(id: UUID(), "reconnected with token=\(token)"),
        ])

        let snapshot = AgentSession.visibleTranscriptText(rows: rows)
        XCTAssertFalse(snapshot.contains(token),
                       "no transcript row may carry a credential off-process")
        XCTAssertTrue(snapshot.contains("[redacted]"))
    }

    // MARK: - A pane that says nothing eventually says why

    /// Every failure that *ends* a launch already reports itself — a non-zero
    /// exit, a signal, a closed transport. The one with no reporter was the
    /// launch that neither fails nor starts: measured with a peer agent whose
    /// CLI was missing from the launch PATH but present to the readiness
    /// probe, the pane opened and waited forever with nothing to show.
    func testSilentRemoteLaunchEventuallyExplainsItself() {
        let s = AgentSession()
        s.startRemote(cli: "codex") { _ in }
        XCTAssertTrue(s.hasStartupWatchdogForTesting)

        s.fireStartupWatchdogForTesting()

        let text = AgentSession.visibleTranscriptText(rows: s.rows)
        XCTAssertTrue(text.contains("codex"), text)
        XCTAssertTrue(text.contains("PATH"), text)
        XCTAssertFalse(s.hasStartupWatchdogForTesting, "it fires once, not on a timer")
    }

    /// Anything at all in the transcript proves the launch got somewhere.
    func testAnyOutputCancelsTheSilenceAlarm() {
        let s = AgentSession()
        s.startRemote(cli: "codex") { _ in }
        s.ingestForTesting(event(["type": "assistant",
                                  "message": ["content": [["type": "text", "text": "hi"]]]]))

        XCTAssertFalse(s.hasStartupWatchdogForTesting)
        s.fireStartupWatchdogForTesting()
        let text = AgentSession.visibleTranscriptText(rows: s.rows)
        XCTAssertFalse(text.contains("no output from"), text)
    }

    /// Environment metadata is real stdout even though it intentionally draws no row.
    func testEnvironmentOutputCancelsTheSilenceAlarm() {
        let s = AgentSession()
        s.startRemote(cli: "claude") { _ in }
        s.ingestForTesting(event([
            "type": "system",
            "subtype": "environment",
            "shell": "zsh",
            "profile_fallback": "loaded",
            "agent_env": "missing",
            "present_keys": ["AI_MESH_API_KEY"],
        ]))

        XCTAssertNotNil(s.environmentSummary)
        XCTAssertFalse(s.hasStartupWatchdogForTesting)
        s.fireStartupWatchdogForTesting()
        let text = AgentSession.visibleTranscriptText(rows: s.rows)
        XCTAssertFalse(text.contains("no output from"), text)
    }

    /// A session that was stopped has already reported itself; a late alarm
    /// would be noise on top of an answer the user already has.
    func testStoppingCancelsTheSilenceAlarm() {
        let s = AgentSession()
        s.startRemote(cli: "codex") { _ in }
        s.stop()

        XCTAssertFalse(s.hasStartupWatchdogForTesting)
        s.fireStartupWatchdogForTesting()
        let text = AgentSession.visibleTranscriptText(rows: s.rows)
        XCTAssertFalse(text.contains("no output from"), text)
    }

    // MARK: - A running turn that stays quiet is warned, never killed

    func testExtendedProtocolSilenceWarnsWithoutCompletingTheTurn() throws {
        var completions = 0
        let s = AgentSession(extendedSilenceThreshold: 0.01)
        s.onTurnEnd = { _, _, _ in completions += 1 }
        s.startRemote(cli: "codex") { _ in }
        try s.send("run the long build", from: .person)

        XCTAssertTrue(s.hasExtendedSilenceWatchdogForTesting)
        s.fireExtendedSilenceWatchdogForTesting()

        XCTAssertTrue(s.hasExtendedSilence)
        XCTAssertTrue(s.isThinking)
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(completions, 0, "silence is not a completion or failure")
        s.stop()
    }

    func testProtocolActivityClearsAndRearmsExtendedSilenceWarning() throws {
        let s = AgentSession(extendedSilenceThreshold: 60)
        s.startRemote(cli: "codex") { _ in }
        try s.send("keep working", from: .person)
        s.fireExtendedSilenceWatchdogForTesting()
        XCTAssertTrue(s.hasExtendedSilence)

        s.ingestForTesting(event([
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "progress"]]],
        ]))

        XCTAssertFalse(s.hasExtendedSilence)
        XCTAssertTrue(s.hasExtendedSilenceWatchdogForTesting)
        s.stop()
    }

    func testReplacedExtendedSilenceWatchdogCannotFireEarly() throws {
        let s = AgentSession(extendedSilenceThreshold: 60)
        s.startRemote(cli: "codex") { _ in }
        try s.send("keep working", from: .person)

        s.replaceThenFirePreviousExtendedSilenceWatchdogForTesting()

        XCTAssertFalse(s.hasExtendedSilence)
        XCTAssertTrue(s.hasExtendedSilenceWatchdogForTesting)
        s.stop()
    }

    func testRawDiagnosticDoesNotPretendTheTurnMadeProtocolProgress() throws {
        let s = AgentSession(extendedSilenceThreshold: 60)
        s.startRemote(cli: "codex") { _ in }
        try s.send("keep working", from: .person)
        s.fireExtendedSilenceWatchdogForTesting()
        XCTAssertTrue(s.hasExtendedSilence)

        s.ingestForTesting("[bridge] unrelated diagnostic")

        XCTAssertTrue(s.hasExtendedSilence)
        XCTAssertFalse(s.hasExtendedSilenceWatchdogForTesting)
        s.stop()
    }

    func testResultAndStopClearExtendedSilenceState() throws {
        let resultSession = AgentSession(extendedSilenceThreshold: 60)
        resultSession.startRemote(cli: "codex") { _ in }
        try resultSession.send("finish", from: .person)
        resultSession.fireExtendedSilenceWatchdogForTesting()
        resultSession.ingestForTesting(event([
            "type": "result", "stop_reason": "end_turn", "result": "done",
        ]))
        XCTAssertFalse(resultSession.hasExtendedSilence)
        XCTAssertFalse(resultSession.hasExtendedSilenceWatchdogForTesting)

        let stoppedSession = AgentSession(extendedSilenceThreshold: 60)
        stoppedSession.startRemote(cli: "codex") { _ in }
        try stoppedSession.send("keep working", from: .person)
        stoppedSession.fireExtendedSilenceWatchdogForTesting()
        stoppedSession.stop()
        XCTAssertFalse(stoppedSession.hasExtendedSilence)
        XCTAssertFalse(stoppedSession.hasExtendedSilenceWatchdogForTesting)
    }

    /// Re-arming per event left a live 30-minute GCD timer behind for every
    /// streamed delta. Cancelling the work item does not take the timer with
    /// it, so a long turn accumulated thousands of them.
    func testStreamedProtocolEventsCostOneSilenceTimerNotOnePerEvent() throws {
        let s = AgentSession(extendedSilenceThreshold: 60)
        s.startRemote(cli: "codex") { _ in }
        try s.send("stream a long answer", from: .person)
        let armsAfterSend = s.extendedSilenceArmsForTesting
        XCTAssertEqual(armsAfterSend, 1)

        for chunk in 0..<50 {
            s.ingestForTesting(event([
                "type": "assistant",
                "message": ["content": [["type": "text", "text": "chunk \(chunk)"]]],
            ]))
        }

        XCTAssertEqual(
            s.extendedSilenceArmsForTesting, armsAfterSend,
            "activity moves the timestamp, it does not schedule another timer"
        )
        XCTAssertTrue(s.hasExtendedSilenceWatchdogForTesting)
        XCTAssertFalse(s.hasExtendedSilence)
        s.stop()
    }

    func testSilenceWatchdogThatWakesEarlyRearmsInsteadOfWarning() throws {
        let s = AgentSession(extendedSilenceThreshold: 60)
        s.startRemote(cli: "codex") { _ in }
        try s.send("keep working", from: .person)
        let armsBeforeWake = s.extendedSilenceArmsForTesting

        s.fireExtendedSilenceWatchdogEarlyForTesting()

        XCTAssertFalse(s.hasExtendedSilence, "the quiet window had not run out")
        XCTAssertTrue(s.hasExtendedSilenceWatchdogForTesting)
        XCTAssertEqual(
            s.extendedSilenceArmsForTesting, armsBeforeWake + 1,
            "an early wake re-arms for whatever is left of the window"
        )
        s.stop()
    }

    /// A PEM key spans lines, and a line-bounded pattern took only its header
    /// — the one part an attacker can retype. The body has to go with it.
    func testVisibleTranscriptRemovesMultiLinePrivateKeyBodies() {
        let body = """
            MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDfakekeyline0001
            aGVsbG90aGlzaXNub3RhcmVhbGtleWl0aXNhZml4dHVyZW9ubHl4eHh4eHh4eHh4
            c2Vjb25kbGluZW9mZmFrZWJhc2U2NGRhdGFmb3J0ZXN0aW5ncHVycG9zZXNvbmx5
            """
        let key = "-----BEGIN PRIVATE KEY-----\n\(body)\n-----END PRIVATE KEY-----"

        let rows = AgentSession.rows(for: [
            .said(id: UUID(), .leader, "install this key:\n\(key)"),
            .answered(id: UUID(), "wrote it out:\n\(key)\nfinished."),
            .notice(id: UUID(), "restored from \(key)"),
        ])

        let snapshot = AgentSession.visibleTranscriptText(rows: rows)
        for line in body.split(separator: "\n") {
            XCTAssertFalse(snapshot.contains(line),
                           "private key body survived redaction: \(line)")
        }
        XCTAssertFalse(snapshot.contains("-----END PRIVATE KEY-----"),
                       "the closing marker belongs to the key and must go with it")
        XCTAssertTrue(snapshot.contains("[redacted private key]"))
        // A complete block ends where the key ends, so text after it survives.
        XCTAssertTrue(snapshot.contains("finished."),
                      "a closed key must not consume the rest of its row")
    }

    /// A key cut off mid-transcript is still a key: with no closing marker to
    /// stop at, the rest of that row goes. The bound is the row — the entries
    /// after it are separate rows and must survive.
    func testVisibleTranscriptRemovesUnterminatedPrivateKeyToEndOfItsRow() {
        let tail = "c2Vjb25kbGluZW9mZmFrZWJhc2U2NGRhdGFmb3J0ZXN0aW5ncHVycG9zZXM"
        let truncated = "-----BEGIN OPENSSH PRIVATE KEY-----\nMIIEvQIBADANBgkq\n\(tail)"

        let rows = AgentSession.rows(for: [
            .answered(id: UUID(), "here it is:\n\(truncated)"),
            .answered(id: UUID(), "a later answer that must survive"),
        ])

        let snapshot = AgentSession.visibleTranscriptText(rows: rows)
        XCTAssertFalse(snapshot.contains(tail),
                       "an unterminated key must not leave its body behind")
        XCTAssertFalse(snapshot.contains("MIIEvQIBADANBgkq"))
        XCTAssertTrue(snapshot.contains("[redacted private key]"))
        XCTAssertTrue(snapshot.contains("a later answer that must survive"),
                      "redaction is bounded by the row it started in")
    }

    /// Answers are not tool headlines: they keep their line structure and are
    /// bounded by the transcript tail, never by the 160-byte row budget.
    func testAnswerRedactionKeepsAnswerShape() {
        let token = "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
        let body = String(repeating: "detail line\n", count: 20)
        let rows = AgentSession.rows(for: [
            .answered(id: UUID(), "start \(token)\n" + body + "end"),
        ])

        let snapshot = AgentSession.visibleTranscriptText(rows: rows)
        XCTAssertFalse(snapshot.contains(token))
        XCTAssertTrue(snapshot.contains("[redacted]"))
        XCTAssertTrue(snapshot.contains("detail line\ndetail line"),
                      "answers keep their line structure")
        XCTAssertTrue(snapshot.hasSuffix("end"))
        XCTAssertGreaterThan(snapshot.utf8.count, 160,
                             "the tool row's byte budget must not reach answers")
    }

    func testToolHeadlineRedactsPortableEnvironmentCredentialsAndProviderTokens() {
        let cases = [
            ("AWS_SECRET_ACCESS_KEY='aws-secret-value' run", "aws-secret-value"),
            ("AWS_SESSION_TOKEN=aws-session-value run", "aws-session-value"),
            ("DATABASE_URL=postgresql://dbuser:postgres-password@db.example/app run", "postgres-password"),
            ("connect ssh://user:standalone-uri-password@host", "standalone-uri-password"),
            ("use ghp_abcdefghijklmnopqrstuvwxyz1234567890", "ghp_abcdefghijklmnopqrstuvwxyz1234567890"),
            ("use github_pat_abcdefghijklmnopqrstuvwxyz_1234567890", "github_pat_abcdefghijklmnopqrstuvwxyz_1234567890"),
            ("use sk-proj-abcdefghijklmnopqrstuvwxyz1234567890", "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"),
            ("-----BEGIN PRIVATE KEY----- private-key-material -----END PRIVATE KEY-----", "private-key-material"),
        ]

        for (raw, secret) in cases {
            let projected = AgentSession.projectedToolHeadline(raw)
            XCTAssertFalse(projected.contains(secret), "credential leaked: \(secret)")
            XCTAssertTrue(projected.contains("[redacted"), "missing redaction marker for: \(raw)")
            XCTAssertLessThanOrEqual(projected.utf8.count, 160)
        }
    }

    func testTeamReadOutputRedactsCorrelationTokensButPreservesResponseText() {
        let correlation = "corr-token-123"
        let instance = "agent-instance-456"
        let input = """
        [REQUIRED CORRELATED REPLY for instance \(instance)]
        tm-agent reply --reply-to \(correlation) <<'TERMMESH_REPLY_EOF'
        user response text remains exactly here
        user response may discuss correlation_id=customer-visible without being routing metadata
        TERMMESH_REPLY_EOF
        [tm-agent-reply:\(correlation):\(instance)]
        """

        let sanitized = TerminalController.sanitizedTeamReadOutput(input)

        XCTAssertFalse(sanitized.contains(correlation))
        XCTAssertFalse(sanitized.contains(instance))
        XCTAssertTrue(sanitized.contains("tm-agent reply --reply-to [REDACTED]"))
        XCTAssertTrue(sanitized.contains("user response text remains exactly here"))
        XCTAssertTrue(sanitized.contains("correlation_id=customer-visible"))
        XCTAssertTrue(sanitized.contains("[tm-agent-reply:[REDACTED]]"))
    }

    func testTeamReadOutputRedactsSoftWrappedGeneratedCorrelationTokensWithoutDigestFalsePositive() {
        let token = String(repeating: "0123456789abcdef", count: 4)
        let unrelatedDigest = String(repeating: "fedcba9876543210", count: 4)
        let wrappedCommand = """
        tm-agent reply --
        reply-to 0123456789abcdef01234567
        89abcdef0123456789abcdef0123456789abcdef <<'TERMMESH_REPLY_EOF'
        response body stays visible
        """
        let wrappedMarker = """
        [tm-agent-reply:0123456789abcdef0123456789ab
        cdef0123456789abcdef0123456789abcdef:agent-instance-
        456]
        """
        let input = wrappedCommand + "\n" + wrappedMarker
            + "\nunrelated digest \(unrelatedDigest)"

        let sanitized = TerminalController.sanitizedTeamReadOutput(input)

        XCTAssertFalse(sanitized.contains(token))
        XCTAssertFalse(sanitized.contains("01234567\n89abcdef"), "no wrapped token suffix may survive")
        XCTAssertFalse(sanitized.contains("agent-instance-\n456"))
        XCTAssertTrue(sanitized.contains("tm-agent reply --\nreply-to [REDACTED]"))
        XCTAssertTrue(sanitized.contains("[tm-agent-reply:[REDACTED]]"))
        XCTAssertTrue(sanitized.contains("response body stays visible"))
        XCTAssertTrue(sanitized.contains(unrelatedDigest), "unscoped user digests must remain unchanged")
    }

    func testVisibleTranscriptHasAbsoluteLineAndByteBoundsWithoutALinesArgument() {
        let rows = AgentSession.rows(for: [
            .answered(id: UUID(), String(repeating: "1234567890\n", count: 8_000)),
        ])

        let snapshot = AgentSession.visibleTranscriptText(rows: rows)
        XCTAssertLessThanOrEqual(snapshot.split(separator: "\n").count, 500)
        XCTAssertLessThanOrEqual(snapshot.utf8.count, 64 * 1024)
    }

    func testVisibleTranscriptSnapshotIncludesStreamingChangesWhilePaneIsHidden() {
        let session = AgentSession()
        session.isVisible = false
        session.ingestForTesting(event([
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "latest hidden answer"]]],
        ]))

        XCTAssertTrue(session.rows.isEmpty, "hidden panes intentionally defer their UI projection")
        XCTAssertEqual(
            session.visibleTranscriptText(),
            "latest hidden answer",
            "tm-agent read must rebuild the same bounded projection without making the pane visible"
        )
    }

    // MARK: - Visibility gating
    //
    // Two experiments said the streaming cost is neither the transcript's width
    // (a 30x smaller row window moved nothing) nor the flush rate (30Hz to 10Hz
    // moved nothing). What is left is how many sessions are dirty in a frame —
    // SwiftUI coalesces mutations per frame and then walks every dirty subgraph.
    // Ten agents streaming behind one visible pane pay for ten.

    /// A hidden transcript does not publish. `entries` is the model and keeps
    /// filling; `rows` and `revision` are the projection nobody is reading.
    func testAHiddenSessionStopsPublishingItsTranscript() {
        let s = session([blockStart(0, "text"), delta(0, "one"), blockStop(0)])
        XCTAssertEqual(s.rows.count, 1)
        let revisionWhenHidden = s.revision

        s.isVisible = false
        s.ingestForTesting(blockStart(0, "text"))
        s.ingestForTesting(delta(0, "two"))
        s.ingestForTesting(blockStop(0))

        XCTAssertEqual(s.rows.count, 1, "the transcript must not move while nobody is looking")
        XCTAssertEqual(s.revision, revisionWhenHidden, "and must not announce")
        XCTAssertEqual(s.entries.count, 2, "but the model must still be there")
    }

    /// Coming back catches up in one announcement, not one per missed delta —
    /// the whole point is that the hidden pane cost nothing on the way.
    func testBecomingVisibleAgainPublishesEverythingThatArrivedWhileHidden() {
        let s = session([blockStart(0, "text"), delta(0, "one"), blockStop(0)])
        s.isVisible = false
        for index in 2...5 {
            s.ingestForTesting(blockStart(0, "text"))
            s.ingestForTesting(delta(0, "answer \(index)"))
            s.ingestForTesting(blockStop(0))
        }
        let revisionWhileHidden = s.revision

        s.isVisible = true

        XCTAssertEqual(s.rows.count, 5, "the transcript catches up")
        XCTAssertEqual(s.revision, revisionWhileHidden + 1, "in exactly one announcement")
        XCTAssertEqual(s.rows.map(\.id), s.entries.map(\.id))
    }

    /// Status is not the transcript. `isThinking` feeds `onBusyChanged` and so
    /// the off-main status RPC, which serves `tm-agent status` for readers that
    /// have no pane at all — gating status behind a pane's visibility would let
    /// a busy agent report idle to them. Only the transcript is deferred.
    func testAHiddenSessionStillReportsThatItIsStreaming() throws {
        let s = session([blockStart(0, "text"), delta(0, "half a sen")])
        s.isVisible = false
        s.ingestForTesting(blockStart(1, "text"))
        s.ingestForTesting(delta(1, "still writing"))

        XCTAssertFalse(s.streamingIds.isEmpty, "a hidden agent must still look busy")
        XCTAssertEqual(s.entries.count, 2)
    }

    /// Nothing is gated by default, so a wiring mistake in the view degrades to
    /// today's behaviour rather than to a pane that silently stops updating.
    func testASessionPublishesUntilSomeoneSaysItIsHidden() {
        let s = AgentSession()
        XCTAssertTrue(s.isVisible)
        s.ingestForTesting(blockStart(0, "text"))
        s.ingestForTesting(delta(0, "visible by default"))
        XCTAssertEqual(s.rows.count, 1)
    }

    /// The batch-rate override maps Hz to the flush interval and falls back to
    /// the shipped 30Hz when absent or nonsense. Unlike the row cap, nothing
    /// downstream is sized by this value, so the mapping is the whole contract.
    func testStreamBatchRateOverrideMapsToTheFlushInterval() {
        let key = "agentStreamBatchHz"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        XCTAssertEqual(AgentStreamDecoder.batchInterval, 1.0 / 30.0)
        UserDefaults.standard.set(10, forKey: key)
        XCTAssertEqual(AgentStreamDecoder.batchInterval, 1.0 / 10.0)
        UserDefaults.standard.set(-5, forKey: key)
        XCTAssertEqual(AgentStreamDecoder.batchInterval, 1.0 / 30.0)
    }

    /// Lowering the bound mid-stream must not read past the transcript.
    ///
    /// `publishEntries`'s incremental branch maps `rows[relative]` onto
    /// `entries[displayStart + relative]` and uses `rows.count` as the width of
    /// the window. That substitution only holds while the bound is fixed. Drop
    /// it from 300 to 10 with `rows` still 300 long and `displayStart` jumps to
    /// `entries.count - 10`, so the branch walks off the end of `entries` — a
    /// STAGING build with ten agents streaming died exactly here.
    func testLoweringTheRenderedBoundMidStreamStaysInsideTheTranscript() {
        let key = "agentMaxRenderedEntries"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // A transcript past the shipped bound, then one answer left open so the
        // next delta grows a row that is already there instead of adding one.
        var lines: [String] = []
        for index in 0..<(AgentSession.maxRenderedEntries + 20) {
            lines += [blockStart(0, "text"), delta(0, "answer \(index)"), blockStop(0)]
        }
        lines += [blockStart(0, "text"), delta(0, "the open one")]
        let s = session(lines)
        XCTAssertEqual(s.rows.count, 300, "the window starts at the shipped bound")

        UserDefaults.standard.set(10, forKey: key)

        // Growing the open answer takes the incremental branch, not a rebuild.
        s.ingestForTesting(delta(0, " and more of it"))

        XCTAssertEqual(s.rows.count, 10, "the window must follow the new bound")
        XCTAssertEqual(s.rows.map(\.id), Array(s.entries.suffix(10)).map(\.id),
                       "and must still be the tail of the transcript")
    }

    /// A streamed delta must announce itself once. The session used to publish
    /// both `entries` and `revision` for one mutation, and `AgentPanel`
    /// forwarded every announcement, so the transcript rebuilt itself twice per
    /// character that arrived. Under `@Observable` the guarantee is stated as a
    /// count: one transaction advances `revision` exactly once, and `entries`
    /// is outside observation entirely.
    func testAStreamedDeltaAnnouncesItselfOnce() {
        let s = session([blockStart(0, "text")])
        let revisionBefore = s.revision
        let rowsInvalidated = expectation(description: "rows invalidated once")
        withObservationTracking { _ = s.rows } onChange: { rowsInvalidated.fulfill() }

        s.ingestForTesting(delta(0, "half a sen"))

        wait(for: [rowsInvalidated], timeout: 1)
        XCTAssertEqual(s.revision, revisionBefore + 1, "one mutation, one announcement")
        // And the rows the view reads are already the new ones — they are
        // rebuilt before the announcement, not after it.
        XCTAssertEqual(s.rows.map(\.id), s.entries.map(\.id))
    }

    /// A delta must not wake the turn-state properties.
    ///
    /// `@Observable` invalidates on assignment, not on change, so the turn
    /// boundaries that assign `isThinking`/`isRunning`/`canInterrupt`
    /// unconditionally would wake every view reading them on every event. The
    /// guarded setters exist to stop that; this fails if one is bypassed.
    func testAStreamedDeltaLeavesTurnStateSilent() {
        let s = session([blockStart(0, "text")])
        let turnStateWoke = expectation(description: "turn state must stay silent")
        turnStateWoke.isInverted = true
        withObservationTracking {
            _ = s.isThinking
            _ = s.isRunning
            _ = s.canInterrupt
            _ = s.summary
        } onChange: { turnStateWoke.fulfill() }

        s.ingestForTesting(delta(0, "half a sen"))

        wait(for: [turnStateWoke], timeout: 0.2)
    }

    // MARK: - Stopping a turn

    /// Not a signal and not a restart. Measured: claude reads
    /// `control_request`/`interrupt` on the same stdin its turns arrive on,
    /// the turn ends in half a second, the process lives, and the next turn
    /// answers with its context intact.
    func testOnlyAMeasuredCliOffersToStopATurn() {
        let claude = AgentSession.claudeLaunch(
            claudePath: "/usr/local/bin/claude", model: "haiku",
            instructions: "", extraArgs: [], workingDirectory: "/tmp")
        XCTAssertTrue(claude.interruptible)

        // The bridged CLIs have their own cancel verbs and none of them have
        // been measured, so their panes do not offer a button that might do
        // something else.
        let bridged = AgentSession.bridgeLaunch(
            cli: "codex", bridgePath: "/repo/bridge.py", model: "gpt-5.5",
            workingDirectory: "/tmp")
        XCTAssertFalse(bridged.interruptible)
    }

    // MARK: - Which bridge runs

    /// The Python bridge and the Rust port take the same arguments and emit
    /// the same events, so a pane can be moved between them. What differs is
    /// only how each is started: a script is an argument to its interpreter, a
    /// compiled binary is the command itself.
    func testTheCompiledBridgeIsTheDefaultAndPythonIsTheWayBack() {
        XCTAssertTrue(AgentPipeTransport.prefersRustBridge(environment: [:]))
        XCTAssertTrue(AgentPipeTransport.prefersRustBridge(
            environment: ["TERMMESH_BRIDGE_IMPL": "rust"]))
        XCTAssertFalse(AgentPipeTransport.prefersRustBridge(
            environment: ["TERMMESH_BRIDGE_IMPL": "python"]))
        // Only the one word turns it back. A typo must not silently pick the
        // implementation nobody asked for.
        XCTAssertTrue(AgentPipeTransport.prefersRustBridge(
            environment: ["TERMMESH_BRIDGE_IMPL": "pyhton"]))
    }

    func testAScriptBridgeIsRunByItsInterpreterAndABinaryIsNot() {
        XCTAssertEqual(
            AgentPipeTransport.bridgeInterpreter(for: "/repo/scripts/spike/tm-agent-bridge.py"),
            ["python3"])
        XCTAssertEqual(
            AgentPipeTransport.bridgeInterpreter(for: "/app/Contents/Resources/bin/tm-agent-bridge"),
            [])
    }

    func testTheNativeLaunchDropsPython3ForTheCompiledBridge() {
        let script = AgentSession.bridgeLaunch(
            cli: "codex", bridgePath: "/repo/bridge.py", model: "",
            workingDirectory: "/tmp")
        XCTAssertEqual(script.arguments.first, "python3")
        XCTAssertEqual(script.arguments.dropFirst().first, "/repo/bridge.py")

        let binary = AgentSession.bridgeLaunch(
            cli: "codex", bridgePath: "/bundle/bin/tm-agent-bridge", model: "",
            workingDirectory: "/tmp")
        XCTAssertEqual(binary.arguments.first, "/bundle/bin/tm-agent-bridge")
        XCTAssertFalse(binary.arguments.contains("python3"))
    }

    func testNativePaneEnvironmentCarriesItsDurableInstance() {
        let workspaceId = UUID()
        let environment = TeamOrchestrator.buildAgentPaneEnv(
            teamName: "ebpf",
            agentName: "executor",
            agentType: "executor",
            agentCli: "claude",
            agentInstanceId: "instance-b",
            windowId: "window-id",
            workspaceId: workspaceId
        )

        XCTAssertEqual(environment["TERMMESH_TEAM"], "ebpf")
        XCTAssertEqual(environment["TERMMESH_AGENT_NAME"], "executor")
        XCTAssertEqual(environment["TERMMESH_AGENT_INSTANCE_ID"], "instance-b")
        XCTAssertEqual(environment["TERMMESH_WORKSPACE_ID"], workspaceId.uuidString)
        XCTAssertEqual(
            environment["PATH"]?.split(separator: ":").first.map(String.init),
            Bundle.main.resourcePath.map { "\($0)/bin" }
        )
        XCTAssertTrue(environment["PATH"]?.contains("/usr/bin") == true)
        // Skills run "$TERMMESH_APP_BIN/tm-agent" first; native panes only get
        // it from here.
        XCTAssertEqual(environment["TERMMESH_APP_BIN"], Bundle.main.resourcePath.map { "\($0)/bin" })
    }

    func testCLIProfileCannotReplaceAgentRoutingOrBundledCLI() {
        let required = [
            "PATH": "/bundle/bin:/usr/bin",
            "TERMMESH_TEAM": "real-team",
            "TERMMESH_AGENT_INSTANCE_ID": "real-instance",
            "CMUX_SOCKET": "/tmp/real.sock",
            "HOME": "/Users/original",
        ]
        let profile = [
            "PATH": "/stale/bin:/usr/bin",
            "TERMMESH_TEAM": "wrong-team",
            "TERMMESH_AGENT_INSTANCE_ID": "wrong-instance",
            "CMUX_SOCKET": "/tmp/wrong.sock",
            "HOME": "/Users/profile",
            "CUSTOM_API_HOST": "https://example.test",
        ]

        let environment = TeamOrchestrator.applyAgentProfileEnvironment(
            profile, to: required
        )

        XCTAssertEqual(environment["TERMMESH_TEAM"], "real-team")
        XCTAssertEqual(environment["TERMMESH_AGENT_INSTANCE_ID"], "real-instance")
        XCTAssertEqual(environment["CMUX_SOCKET"], "/tmp/real.sock")
        XCTAssertEqual(environment["HOME"], "/Users/profile")
        XCTAssertEqual(environment["CUSTOM_API_HOST"], "https://example.test")
        XCTAssertEqual(
            environment["PATH"]?.split(separator: ":").map(String.init),
            ["/bundle/bin", "/usr/bin", "/stale/bin"]
        )
    }

    func testTheTerminalLaunchLineDropsPython3ForTheCompiledBridge() {
        // The whole chain is quoted again for the shell, so this reads the
        // line for what it runs rather than for how it came out escaped.
        let script = AgentPipeTransport.bridgeLaunchCommand(
            cli: "codex", fifoPath: "/tmp/f", model: "",
            bridgePath: "/repo/bridge.py", rendererPath: nil,
            workingDirectory: "/tmp")
        XCTAssertTrue(script.contains("python3"))
        XCTAssertTrue(script.contains("/repo/bridge.py"))

        let binary = AgentPipeTransport.bridgeLaunchCommand(
            cli: "codex", fifoPath: "/tmp/f", model: "",
            bridgePath: "/bundle/bin/tm-agent-bridge", rendererPath: nil,
            workingDirectory: "/tmp")
        XCTAssertTrue(binary.contains("/bundle/bin/tm-agent-bridge"))
        // No renderer either, so nothing else could have put it there.
        XCTAssertFalse(binary.contains("python3"))
    }

    /// A turn stopped on purpose is not a failure, and should not be labelled
    /// with claude's own word for it, `error_during_execution`.
    func testAStoppedTurnReadsAsStoppedRatherThanFailed() {
        let s = session([event(["type": "result", "subtype": "error_during_execution",
                                "is_error": true, "result": ""])])
        guard case .turnEnded(_, let end) = try? XCTUnwrap(s.entries.last) else {
            return XCTFail("expected a turn end")
        }
        // Without a stop request it is exactly what claude called it.
        XCTAssertEqual(end.stop, "error_during_execution")
        XCTAssertTrue(end.failed)
    }

    // MARK: - Markdown

    /// The pane was showing `## Heading` and `**bold**` as literal characters,
    /// because agents write markdown whether or not anything renders it.
    func testBlocksComeApartTheWayTheyWereWritten() {
        let blocks = AgentMarkdown.blocks("""
            ## What I found

            The parser lives in `Foo.swift`.

            - first
            - second
            1. step one

            ```swift
            let x = 1
            ```
            """)
        guard case .heading(let level, let title) = blocks[0] else {
            return XCTFail("expected a heading, got \(blocks[0])")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(title, "What I found")
        XCTAssertEqual(blocks.count, 6)
        guard case .bullet(let marker, _) = blocks[2] else { return XCTFail("expected a bullet") }
        XCTAssertEqual(marker, "•")
        // An agent quoting "step 3" means 3, so the number it wrote survives.
        guard case .bullet(let ordinal, _) = blocks[4] else { return XCTFail("expected an ordinal") }
        XCTAssertEqual(ordinal, "1.")
        guard case .code(let language, let body) = blocks[5] else { return XCTFail("expected code") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(body, "let x = 1")
    }

    /// While a turn streams the closing fence has not arrived. Treating the
    /// opening line as a paragraph until it does makes the block flicker into
    /// existence.
    func testAnUnclosedFenceIsAlreadyCode() {
        let blocks = AgentMarkdown.blocks(#"here:\#n```json\#n{\#n  "a": 1"#)
        guard case .code(let language, let body) = blocks.last else {
            return XCTFail("expected code, got \(String(describing: blocks.last))")
        }
        XCTAssertEqual(language, "json")
        XCTAssertTrue(body.contains("\"a\""))
    }

    /// `#hashtag` and `#!/bin/sh` are not headings.
    func testAHashWithoutASpaceIsNotAHeading() {
        guard case .paragraph = AgentMarkdown.blocks("#!/bin/sh")[0] else {
            return XCTFail("expected a paragraph")
        }
    }

    func testTableBecomesOneQuietStructuredBlock() {
        let blocks = AgentMarkdown.blocks("""
            | Host | Status |
            | --- | --- |
            | Mac | Ready |
            | Linux | Offline |
            """)
        guard case .table(let headers, let rows) = try? XCTUnwrap(blocks.first) else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(headers, ["Host", "Status"])
        XCTAssertEqual(rows, [["Mac", "Ready"], ["Linux", "Offline"]])
    }

    /// A compact status report — this file's own stated use case — commonly
    /// writes a one-dash divider like `:-:`, not the 3-dash form every other
    /// test here uses. A 3-dash minimum silently dropped these tables to a
    /// literal-pipe paragraph.
    func testTableWithACompactDividerStillParses() {
        let blocks = AgentMarkdown.blocks("""
            |Host|Status|
            |:-:|:-:|
            |Mac|Ready|
            """)
        guard case .table(let headers, let rows) = try? XCTUnwrap(blocks.first) else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(headers, ["Host", "Status"])
        XCTAssertEqual(rows, [["Mac", "Ready"]])
    }

    /// An empty body cell — a blank trailing column mid-table — used to break
    /// the table there, dropping the rest of the lines to a literal-pipe
    /// paragraph. Only the header and divider still require every cell filled.
    func testTableRowWithAnEmptyCellStaysInTheTable() {
        let blocks = AgentMarkdown.blocks("""
            | Metric | A | B |
            | --- | --- | --- |
            | 행 간격 | 8 | 7 |
            | 지연 | 3 | |
            """)
        guard case .table(let headers, let rows) = try? XCTUnwrap(blocks.first) else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(headers, ["Metric", "A", "B"])
        XCTAssertEqual(rows, [["행 간격", "8", "7"], ["지연", "3", ""]])
    }

    /// Two ordinary pipe-shaped prose lines, with no divider, must stay prose.
    func testPipeShapedProseWithoutADividerIsNotATable() {
        let blocks = AgentMarkdown.blocks("""
            The path is home | work | notes and it is not a table.
            Same here: a | b | c, still just a sentence.
            """)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph = blocks[0] else {
            return XCTFail("expected a paragraph, got \(blocks[0])")
        }
    }

    /// In JSON the interesting strings are the keys, and a key is a string
    /// with a colon after it.
    func testJsonKeysReadDifferentlyFromValues() {
        let tokens = AgentMarkdown.tokenize("{\"name\": \"term-mesh\", \"n\": 42}",
                                            language: "json")
        XCTAssertTrue(tokens.contains { $0.0 == "\"name\"" && $0.1 == .key })
        XCTAssertTrue(tokens.contains { $0.0 == "\"term-mesh\"" && $0.1 == .string })
        XCTAssertTrue(tokens.contains { $0.0 == "42" && $0.1 == .number })
    }

    func testCommentsAndKeywordsAreFound() {
        let tokens = AgentMarkdown.tokenize("// note\nlet x = 1", language: "swift")
        XCTAssertTrue(tokens.contains { $0.0 == "// note" && $0.1 == .comment })
        XCTAssertTrue(tokens.contains { $0.0 == "let" && $0.1 == .keyword })
    }

    /// Guessing keywords for an unknown language colours the wrong words,
    /// which is worse than colouring none.
    func testAnUnknownLanguageGetsNoInventedKeywords() {
        let tokens = AgentMarkdown.tokenize("let x = \"hi\"", language: "brainfuck")
        XCTAssertFalse(tokens.contains { $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "\"hi\"" && $0.1 == .string })
    }

    /// Nothing may be dropped: highlighting is colour over the same characters.
    func testTokenizingLosesNothing() {
        for (code, lang) in [("let a = 1 // x", "swift"),
                             ("{\"k\": [1, 2]}", "json"),
                             ("echo $HOME # hi", "bash")] {
            let joined = AgentMarkdown.tokenize(code, language: lang).map(\.0).joined()
            XCTAssertEqual(joined, code, lang)
        }
    }

    // MARK: - Following the bottom

    /// A view that follows the bottom cannot key on `entries.count`.
    ///
    /// A streamed answer grows a row that is already there, so the count sits
    /// still while the text runs off the bottom of the pane — which is exactly
    /// what it did: auto-scroll only moved when a *new* row appeared.
    func testEveryMutationMovesTheRevision() {
        let s = AgentSession()
        s.ingestForTesting(blockStart(0, "text"))
        let afterStart = s.revision

        s.ingestForTesting(delta(0, "half a sen"))
        XCTAssertGreaterThan(s.revision, afterStart, "a delta changed the text")
        let afterDelta = s.revision
        XCTAssertEqual(s.entries.count, 1, "and did not change the count")

        s.ingestForTesting(delta(0, "tence"))
        XCTAssertGreaterThan(s.revision, afterDelta)
    }

    func testAParsedDeltaBatchPublishesOneTranscriptRevision() {
        let s = AgentSession()
        s.ingestForTesting(blockStart(0, "text"))
        let before = s.revision

        s.applyBatchForTesting([
            delta(0, "one "),
            delta(0, "two "),
            delta(0, "three"),
        ])

        XCTAssertEqual(s.revision, before + 1)
        guard case .answered(_, let text) = s.entries.last else {
            return XCTFail("missing streamed answer")
        }
        XCTAssertEqual(text, "one two three")
    }

    func testStreamDecoderKeepsSplitUTF8AndSeveralLines() {
        let decoder = AgentStreamDecoder(maxLineBytes: 1024)
        let text = "첫째\n둘째\n"
        let bytes = Array(text.utf8)
        let split = bytes.firstIndex { $0 >= 0x80 }! + 1

        XCTAssertTrue(decoder.consume(Data(bytes[..<split])).isEmpty)
        XCTAssertEqual(
            decoder.consume(Data(bytes[split...])),
            [.line("첫째"), .line("둘째")]
        )
    }

    /// A tool result closes a row without adding one, and that changes what is
    /// on screen too.
    func testAToolResultMovesTheRevision() {
        let s = session([event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t1", "name": "Bash",
             "input": ["command": "swift build"]]]]])])
        let before = s.revision
        s.ingestForTesting(event(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "done"]]]]))
        XCTAssertGreaterThan(s.revision, before)
        XCTAssertEqual(s.entries.count, 1)
    }

    // MARK: - The end of a turn

    func testTurnCompletionFactsLeadWithClockAndElapsedTime() {
        let end = AgentSession.TurnEnd(
            stop: "end_turn",
            failed: false,
            cost: 0.4096,
            duration: 23.4,
            tokensIn: 2,
            tokensOut: 8,
            completedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            AgentSession.turnFacts(end, timeZone: TimeZone(secondsFromGMT: 9 * 3_600)!),
            "09:00:00 (23s) · end_turn · $0.4096 · 2→8 tok"
        )
    }

    func testElapsedTimeStaysCompactAcrossTurnLengths() {
        XCTAssertEqual(AgentSession.elapsedText(2.7), "2.7s")
        XCTAssertEqual(AgentSession.elapsedText(23.4), "23s")
        XCTAssertEqual(AgentSession.elapsedText(134), "2m 14s")
        XCTAssertEqual(AgentSession.elapsedText(3_730), "1h 2m")
    }

    func testReportedDurationWinsAndLocalStartFillsMissingDuration() {
        let started = Date(timeIntervalSince1970: 100)
        let completed = Date(timeIntervalSince1970: 123)

        XCTAssertEqual(
            AgentSession.resolvedTurnDuration(
                reportedMilliseconds: 2_700,
                startedAt: started,
                completedAt: completed
            ) ?? -1,
            2.7,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AgentSession.resolvedTurnDuration(
                reportedMilliseconds: nil,
                startedAt: started,
                completedAt: completed
            ) ?? -1,
            23,
            accuracy: 0.001
        )
    }

    /// Stated, not inferred.
    ///
    /// The pane path decided a turn was over when the screen had been still for
    /// half a second — a timer standing in for a fact. The fact is in the
    /// stream, along with what the turn cost.
    func testATurnEndsWithItsOwnFacts() throws {
        var reported: (String, AgentSession.TurnEnd)?
        let s = AgentSession()
        s.onTurnEnd = { text, end, _ in reported = (text, end) }
        s.ingestForTesting(event([
            "type": "result", "stop_reason": "end_turn", "is_error": false,
            "result": "STATUS: DONE", "total_cost_usd": 0.4096,
            "duration_ms": 2700, "usage": ["input_tokens": 2, "output_tokens": 8],
        ]))
        let (final, end) = try XCTUnwrap(reported)
        XCTAssertEqual(final, "STATUS: DONE")
        XCTAssertEqual(end.stop, "end_turn")
        XCTAssertEqual(end.cost ?? 0, 0.4096, accuracy: 0.0001)
        XCTAssertEqual(end.duration ?? 0, 2.7, accuracy: 0.001)
        XCTAssertEqual(end.tokensOut, 8)
        XCTAssertFalse(end.failed)
    }

    func testAFailedTurnIsMarkedFailed() throws {
        let s = session([event(["type": "result", "subtype": "error",
                                "is_error": true, "result": "refused"])])
        guard case .notice(_, let detail) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected the failure reason before the footer")
        }
        XCTAssertEqual(detail, "refused")
        guard case .turnEnded(_, let end) = try XCTUnwrap(s.entries.last) else {
            return XCTFail("expected a turn end")
        }
        XCTAssertTrue(end.failed)
    }

    func testAFailedTurnReportsItsReasonToObservers() {
        var reported: (AgentSession.DiagnosticSeverity, String)?
        let s = AgentSession()
        s.onDiagnostic = { reported = ($0, $1) }
        s.ingestForTesting(event([
            "type": "result", "subtype": "error", "is_error": true,
            "stop_reason": "failed", "result": "Missing environment variable: AI_MESH_API_KEY",
        ]))

        XCTAssertEqual(reported?.0, .error)
        XCTAssertEqual(
            reported?.1,
            "Missing environment variable: AI_MESH_API_KEY\n"
                + "Set it in ~/.config/term-mesh/agent-env on the agent host, then restart this agent."
        )
    }

    func testFailedTurnDiagnosticsRedactCredentials() {
        var reported: String?
        let s = AgentSession()
        s.onDiagnostic = { _, detail in reported = detail }
        s.ingestForTesting(event([
            "type": "result", "is_error": true,
            "result": "request failed with API_KEY=do-not-log-this",
        ]))

        XCTAssertEqual(reported, "request failed with API_KEY=[redacted]")
    }

    func testStartupSilenceReportsAWarningToObservers() {
        var reported: (AgentSession.DiagnosticSeverity, String)?
        let s = AgentSession()
        s.onDiagnostic = { reported = ($0, $1) }
        s.startRemote(cli: "test-agent") { _ in }

        s.fireStartupWatchdogForTesting()

        XCTAssertEqual(reported?.0, .warning)
        XCTAssertTrue(reported?.1.contains("no output from the remote agent") == true)
        s.stop()
    }

    func testAFailedTurnShowsOnlyTheReasonAfterStreamedText() {
        let s = session([
            blockStart(0, "text"), delta(0, "partial answer"), blockStop(0),
            event(["type": "result", "subtype": "error", "is_error": true,
                   "stop_reason": "failed", "result": "partial answer\n\nprovider unavailable"]),
        ])

        let notices = s.entries.compactMap { entry -> String? in
            if case .notice(_, let text) = entry { return text }
            return nil
        }
        XCTAssertEqual(notices, ["provider unavailable"])
    }

    // MARK: - The session banner

    /// `system/init` arrives at the head of every turn, not once per session.
    /// Redrawing the banner each time buries the conversation in it.
    func testTheSessionIsAnnouncedOnce() {
        let init1 = event(["type": "system", "subtype": "init", "model": "claude-sonnet-5",
                           "tools": Array(repeating: "t", count: 63), "mcp_servers": ["a", "b"]])
        let s = session([init1, event(["type": "system", "subtype": "init",
                                       "model": "something-else", "tools": []])])
        XCTAssertEqual(s.summary, "claude-sonnet-5 · 63 tools · 2 mcp")
    }

    /// Twelve hook lines fire before an agent does anything. None of them is
    /// what a person is watching for.
    func testHookNoiseNeverReachesTheView() {
        let s = session([
            event(["type": "system", "subtype": "hook_started", "hook_name": "x"]),
            event(["type": "system", "subtype": "hook_response", "hook_name": "x"]),
            event(["type": "system", "subtype": "thinking_tokens", "count": 120]),
        ])
        XCTAssertTrue(s.entries.isEmpty)
    }

    /// A CLI may write a warning to stdout. Showing it beats swallowing it —
    /// the alternative is a pane that goes quiet for a reason nobody can see.
    func testALineThatIsNotAnEventIsStillShown() throws {
        let s = session(["npm warn: something"])
        guard case .notice(_, let text) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a notice")
        }
        XCTAssertEqual(text, "npm warn: something")
    }

    // MARK: - One instruction, one turn

    /// The behaviour this serialisation exists for, measured live.
    ///
    /// Five messages sent back to back arrived byte for byte — nothing was
    /// lost — and came out as **three** turns: claude queues whatever arrives
    /// mid-turn and joins it into the next one with a newline. For a person
    /// typing a follow-up that is right, and it is what Claude Code itself
    /// does. For the leader it is not: two delegated tasks merged into one turn
    /// produce one `result`, so the second task never gets its completion and
    /// the board waits on it forever.
    func testATurnCarriesTheTaskTheInstructionNamed() throws {
        let capsule = """
            ## Task Capsule
            TASK_ID: e82188a0
            [GOAL] do the thing [/GOAL]
            """
        XCTAssertEqual(AgentSession.taskId(in: capsule), "e82188a0")
        XCTAssertNil(AgentSession.taskId(in: "just have a look"))
        XCTAssertNil(AgentSession.taskId(in: "TASK_ID:"))
    }

    /// The correlation the screen path could never make. An answer on a screen
    /// has nothing tying it to a request, so that path guessed — and a reply
    /// was measured closing an unrelated blocked task.
    func testTheAnsweredTaskIsHandedToTheReply() throws {
        var answered: [String?] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, task in answered.append(task) }
        s.beginTurnForTesting(taskId: "e82188a0")
        s.ingestForTesting(event(["type": "result", "stop_reason": "end_turn",
                                  "result": "STATUS: DONE"]))
        XCTAssertEqual(answered, ["e82188a0"])
    }

    /// A turn without a verdict is not the worker's last word, so the task
    /// stays with it; an explicit STATUS is, and nothing after inherits it.
    func testATaskIsAnsweredUntilAnExplicitStatus() throws {
        var seen: [String?] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, task in seen.append(task) }
        s.beginTurnForTesting(taskId: "e82188a0")
        s.ingestForTesting(event(["type": "result", "result": "one"]))
        XCTAssertEqual(s.pendingTaskIdForTesting, "e82188a0")
        s.ingestForTesting(event(["type": "result", "result": "STATUS: DONE"]))
        XCTAssertNil(s.pendingTaskIdForTesting)
        s.ingestForTesting(event(["type": "result", "result": "three"]))
        XCTAssertEqual(seen, ["e82188a0", "e82188a0", nil])
    }

    /// Measured on claude: `result` is the turn's last message only, so a
    /// header written before a final tool call never reached the task board
    /// while the footer, which reads every message, showed it as the verdict.
    func testAHeaderInAnEarlierMessageOfTheTurnStillAnswersTheTask() throws {
        var finals: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { final, _, _ in finals.append(final) }
        s.beginTurnForTesting(taskId: "4fd11ee6")
        s.ingestForTesting(assistantSaid("STATUS: DONE\nFILES: none"))
        s.ingestForTesting(assistantSaid("Double-checked."))
        s.ingestForTesting(resultSaying("Double-checked."))
        XCTAssertNil(s.pendingTaskIdForTesting)
        XCTAssertEqual(finals, ["STATUS: DONE\nFILES: none\nDouble-checked."])
    }

    /// What the codex bridge emitted for the reviewer incident: each message
    /// its own block, but a `result` that glued them, putting `STATUS:` in the
    /// middle of a line. The blocks still say where the header starts.
    func testABridgedTurnWhoseResultGluedTheHeaderStillAnswersTheTask() throws {
        var finals: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { final, _, _ in finals.append(final) }
        s.beginTurnForTesting(taskId: "4fd11ee6")
        s.ingestForTesting(blockStart(0, "text"))
        s.ingestForTesting(delta(0, "Checking the workspace."))
        s.ingestForTesting(blockStop(0))
        s.ingestForTesting(event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "c1", "name": "shell",
             "input": ["command": "echo hi"]]]]]))
        s.ingestForTesting(event(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "c1", "content": "hi",
             "is_error": false]]]]))
        s.ingestForTesting(blockStart(0, "text"))
        s.ingestForTesting(delta(0, "STATUS: DONE\nFILES: none"))
        s.ingestForTesting(blockStop(0))
        s.ingestForTesting(resultSaying("Checking the workspace.STATUS: DONE\nFILES: none"))
        XCTAssertNil(s.pendingTaskIdForTesting)
        XCTAssertEqual(finals, ["Checking the workspace.\nSTATUS: DONE\nFILES: none"])
    }

    // MARK: - A task the worker finishes in a turn of its own

    private func assistantSaid(_ text: String) -> String {
        event(["type": "assistant", "message": ["content": [["type": "text", "text": text]]]])
    }

    private func resultSaying(_ text: String) -> String {
        event(["type": "result", "stop_reason": "end_turn", "result": text])
    }

    private func hook() -> String {
        event(["type": "system", "subtype": "hook_response", "hook_name": "Stop"])
    }

    /// The incident. The worker started a job longer than the tool timeout in
    /// the background and ended its turn without a verdict; when the job
    /// finished the CLI started a turn of its own — no write from this side —
    /// and that turn said STATUS: DONE. It must close the same task.
    func testAContinuationTheCLIStartsItselfAnswersThePendingTask() throws {
        var seen: [String?] = []
        var lost: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, task in seen.append(task) }
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }

        try s.send("TASK_ID: 7c1e0d2a\nrun the full suite", from: .leader)
        s.ingestForTesting(resultSaying("The suite is running in the background."))
        XCTAssertEqual(seen, ["7c1e0d2a"])
        XCTAssertEqual(s.pendingTaskIdForTesting, "7c1e0d2a")
        XCTAssertFalse(s.isTurnInFlightForTesting)

        s.ingestForTesting(assistantSaid("The background suite finished: all green."))
        XCTAssertTrue(s.isTurnInFlightForTesting, "the CLI's own turn is a turn")
        XCTAssertTrue(s.isThinking)
        s.ingestForTesting(resultSaying("STATUS: DONE\nFILES: none\nVERIFY: suite\nNEXT: NONE\nFULL_REPORT: n/a"))

        XCTAssertEqual(seen, ["7c1e0d2a", "7c1e0d2a"])
        XCTAssertNil(s.pendingTaskIdForTesting)
        s.stop()
        XCTAssertTrue(lost.isEmpty, "a settled task is not handed back")
    }

    /// A person's question, a leader message without TASK_ID, and a person
    /// joining a turn the CLI started all answer something else.
    func testOnlyTheDispatchOrTheCLIsOwnTurnAnswersThePendingTask() throws {
        var seen: [String?] = []
        var lost: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, task in seen.append(task) }
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        try s.send("TASK_ID: 5e5e5e5e\nbuild it", from: .leader)
        s.ingestForTesting(resultSaying("started"))

        try s.send("how is it going?", from: .person)
        s.ingestForTesting(resultSaying("STATUS: DONE"))
        try s.send("status check", from: .leader)
        s.ingestForTesting(resultSaying("STATUS: DONE"))
        s.ingestForTesting(assistantSaid("background job done"))
        try s.send("wait, one more thing", from: .person)
        s.ingestForTesting(resultSaying("STATUS: DONE"))

        XCTAssertEqual(seen, ["5e5e5e5e", nil, nil, nil])
        XCTAssertEqual(s.pendingTaskIdForTesting, "5e5e5e5e")
        XCTAssertTrue(lost.isEmpty)
        s.stop()
        XCTAssertEqual(lost, ["5e5e5e5e"])
    }

    func testAPaneRebuildNamesTheRebuildWhenItLosesThePendingTask() throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.startRemote { _ in }
        try s.send("TASK_ID: 9a9a9a9a\nbuild it", from: .leader)

        s.stopForPaneRebuild(after: "stream rewound")
        s.stop()

        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(lost.first?.0, "9a9a9a9a")
        XCTAssertTrue(lost.first?.1.reason.contains("rebuilt") ?? false)
        XCTAssertTrue(lost.first?.1.reason.contains("stream rewound") ?? false)
    }

    func testAPlainStopStillReportsAPlainStop() throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.startRemote { _ in }
        try s.send("TASK_ID: 8b8b8b8b\nbuild it", from: .leader)

        s.stop()

        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(lost.first?.1, .sessionEnded("the session was stopped before an explicit STATUS"))
    }

    private func doneReport(_ marker: String) -> String {
        "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: \(marker)"
    }

    private func turnEndedCount(_ s: AgentSession) -> Int {
        s.entries.filter { if case .turnEnded = $0 { return true }; return false }.count
    }

    private let replayLossReason = AgentSession.paneRebuildLossReason(cause: "disconnected")

    @discardableResult
    private func expectReplay(
        _ s: AgentSession,
        bytes: UInt64,
        _ carried: AgentSession.CarriedTaskCorrelation,
        lossReason: String? = nil
    ) -> Bool {
        s.expectReplayHistory(
            bytes: bytes, carried: carried,
            lossReason: lossReason ?? replayLossReason, deadline: 120
        )
    }

    /// A rebuilt pane replays the turn the retired pane already filed. Its
    /// DONE must not close the carried task or overwrite the reply file; the
    /// first result the retired pane never saw does both.
    func testAReplayedResultNeitherSettlesTheCarriedTaskNorReachesOnTurnEnd() async throws {
        var ended: [(String, String?)] = []
        var lost: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { text, _, taskId in ended.append((text, taskId)) }
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        let history = Data((resultSaying(doneReport("old")) + "\n").utf8)
        let fresh = Data((resultSaying(doneReport("new")) + "\n").utf8)

        expectReplay(s, bytes: UInt64(history.count), .init(taskId: "c0c0c0c0", turnWasInFlight: true))
        s.consume(history)
        let replayed = await waitUntil { self.turnEndedCount(s) == 1 }
        XCTAssertTrue(replayed, "the replayed turn still renders")
        XCTAssertTrue(ended.isEmpty, "a replayed turn must not reach onTurnEnd")
        XCTAssertEqual(s.pendingTaskIdForTesting, "c0c0c0c0", "the replayed DONE settled nothing")

        s.consume(fresh)
        let settled = await waitUntil { ended.count == 1 }
        XCTAssertTrue(settled)
        XCTAssertEqual(ended.first?.1, "c0c0c0c0")
        XCTAssertTrue(ended.first?.0.contains("new") ?? false)
        XCTAssertNil(s.pendingTaskIdForTesting)
        XCTAssertTrue(lost.isEmpty)
    }

    func testTheReplayBoundaryHoldsWhereverTheChunksSplit() async throws {
        let history = Data((assistantSaid("working") + "\n"
            + resultSaying(doneReport("old")) + "\n").utf8)
        let fresh = Data((resultSaying(doneReport("new")) + "\n").utf8)
        let wire = history + fresh
        for chunkSize in [7, history.count, history.count + 5, wire.count] {
            var ended: [String?] = []
            let s = AgentSession()
            s.onTurnEnd = { _, _, taskId in ended.append(taskId) }
            s.startRemote { _ in }
            expectReplay(s, bytes: UInt64(history.count), .init(taskId: "d1d1d1d1", turnWasInFlight: false))
            var offset = 0
            while offset < wire.count {
                let end = min(offset + chunkSize, wire.count)
                s.consume(wire.subdata(in: offset..<end))
                offset = end
            }
            let done = await waitUntil { self.turnEndedCount(s) == 2 }
            XCTAssertTrue(done, "chunk size \(chunkSize)")
            XCTAssertEqual(ended, ["d1d1d1d1"], "chunk size \(chunkSize)")
            XCTAssertNil(s.pendingTaskIdForTesting, "chunk size \(chunkSize)")
        }
    }

    func testNoReplayedBytesInstallsTheCarryBeforeTheFirstLine() async throws {
        var ended: [String?] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, taskId in ended.append(taskId) }
        s.startRemote { _ in }

        expectReplay(s, bytes: 0, .init(taskId: "e2e2e2e2", turnWasInFlight: false))
        XCTAssertEqual(s.pendingTaskIdForTesting, "e2e2e2e2")

        s.consume(Data((resultSaying(doneReport("first")) + "\n").utf8))
        let settled = await waitUntil { ended.count == 1 }
        XCTAssertTrue(settled)
        XCTAssertEqual(ended, ["e2e2e2e2"])
    }

    func testACarryingRebuildStopNeitherLosesTheTaskNorFilesItsId() throws {
        var ended: [String?] = []
        var lost: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { _, _, taskId in ended.append(taskId) }
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        try s.send("TASK_ID: f3f3f3f3\nbuild it", from: .leader)

        let carried = s.stopForPaneRebuild(after: "stream rewound", carry: true)

        XCTAssertEqual(carried, .init(taskId: "f3f3f3f3", turnWasInFlight: true))
        XCTAssertTrue(lost.isEmpty)
        XCTAssertEqual(ended, [nil], "the stopped turn ends without the carried task's id")
    }

    /// Only a turn that could answer the task carries as in flight; a person's
    /// turn running at the rebuild must not become a dispatch on the new pane.
    func testAPersonsTurnInFlightDoesNotCarryAsTheTasksTurn() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("TASK_ID: a4a4a4a4\nbuild it", from: .leader)
        s.ingestForTesting(resultSaying("in the background"))
        try s.send("how is it going?", from: .person)
        XCTAssertTrue(s.isTurnInFlightForTesting)

        let carried = s.stopForPaneRebuild(after: "stream rewound", carry: true)

        XCTAssertEqual(carried, .init(taskId: "a4a4a4a4", turnWasInFlight: false))
    }

    func testAbandoningACarryReportsTheRebuildLossOnce() throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.startRemote { _ in }
        expectReplay(s, bytes: 512, .init(taskId: "b5b5b5b5", turnWasInFlight: false))
        let reason = AgentSession.paneRebuildLossReason(cause: "stream rewound")

        s.abandonCarriedCorrelation(reason: reason)
        s.abandonCarriedCorrelation(reason: reason)
        s.stop()

        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(lost.first?.0, "b5b5b5b5")
        XCTAssertEqual(lost.first?.1, .sessionEnded(reason))
    }

    /// Rebuilt again before its replay ended: the carry moves on with its
    /// original boundary, and the stopped session reports nothing.
    func testARebuildDuringReplayRetakesTheUninstalledCarry() throws {
        var lost: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        let carry = AgentSession.CarriedTaskCorrelation(
            taskId: "c6c6c6c6", turnWasInFlight: true, replayBoundarySeq: 9_000
        )
        expectReplay(s, bytes: 512, carry)

        XCTAssertEqual(s.stopForPaneRebuild(after: "disconnected", carry: true), carry)
        XCTAssertTrue(lost.isEmpty)
    }

    func testStoppingDuringReplayLosesTheUninstalledCarryOnce() throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.startRemote { _ in }
        expectReplay(s, bytes: 512, .init(taskId: "d7d7d7d7", turnWasInFlight: false))

        s.stopForPaneRebuild(after: "disconnected")
        s.stop()

        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(lost.first?.1.reason,
                       AgentSession.paneRebuildLossReason(cause: "disconnected"))
    }

    func testExpectingReplayWithNoRemoteStreamTakesNothing() throws {
        var lost: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }

        XCTAssertFalse(expectReplay(s, bytes: 512, .init(taskId: "a8a8a8a8", turnWasInFlight: false)))
        XCTAssertFalse(s.isReplayingHistoryForTesting)
        s.startRemote { _ in }
        s.stop()

        XCTAssertNil(s.pendingTaskIdForTesting)
        XCTAssertTrue(lost.isEmpty, "a refused carry stays with the caller, which loses it once")
    }

    /// An abandoned carry ends the replay window too: a result after it is
    /// live, not history still being waited out.
    func testAbandoningACarryEndsTheReplayWindow() async throws {
        var ended: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { text, _, _ in ended.append(text) }
        s.startRemote { _ in }
        expectReplay(s, bytes: 1_000_000, .init(taskId: "b9b9b9b9", turnWasInFlight: false))

        s.abandonCarriedCorrelation(reason: replayLossReason)
        XCTAssertFalse(s.isReplayingHistoryForTesting)
        XCTAssertNil(s.replayDeadlineForTesting)
        s.consume(Data((resultSaying("live") + "\n").utf8))

        let reached = await waitUntil { ended == ["live"] }
        XCTAssertTrue(reached, "a closed window must not keep swallowing onTurnEnd")
    }

    func testTheReplayDeadlineLosesTheCarryAndEndsTheWindow() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        var ended: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.onTurnEnd = { text, _, _ in ended.append(text) }
        s.startRemote { _ in }
        expectReplay(s, bytes: 1_000_000, .init(taskId: "cacacaca", turnWasInFlight: false))

        try XCTUnwrap(s.replayDeadlineForTesting).perform()
        s.consume(Data((resultSaying("live") + "\n").utf8))

        let reached = await waitUntil { ended == ["live"] }
        XCTAssertTrue(reached)
        XCTAssertEqual(lost.map(\.0), ["cacacaca"])
        XCTAssertEqual(lost.first?.1, .sessionEnded(replayLossReason))
    }

    /// History the stream already took in when the deadline fires is still
    /// history: it renders, but its DONE does not reach onTurnEnd.
    func testAReplayedResultAppliedAfterTheDeadlineDoesNotReachOnTurnEnd() async throws {
        var lost: [String] = []
        var ended: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.onTurnEnd = { text, _, _ in ended.append(text) }
        s.startRemote { _ in }
        let history = Data((resultSaying(doneReport("old")) + "\n").utf8)
        expectReplay(s, bytes: UInt64(history.count) + 512, .init(taskId: "cdcd0000", turnWasInFlight: false))

        s.consume(history)
        try XCTUnwrap(s.replayDeadlineForTesting).perform()
        s.consume(Data((resultSaying("live") + "\n").utf8))

        let reached = await waitUntil { self.turnEndedCount(s) == 2 }
        XCTAssertTrue(reached, "both results render")
        XCTAssertEqual(ended, ["live"])
        XCTAssertEqual(lost, ["cdcd0000"])
    }

    func testACarryArmedWhileTheDeadlineDrainsTheQueueIsNotLost() async throws {
        var lost: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        expectReplay(s, bytes: 512, .init(taskId: "dbdb0000", turnWasInFlight: false))

        try XCTUnwrap(s.replayDeadlineForTesting).perform()
        expectReplay(s, bytes: 512, .init(taskId: "dbdb1111", turnWasInFlight: false))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(lost, ["dbdb0000"])
        XCTAssertTrue(s.isReplayingHistoryForTesting)
    }

    func testAReplayedResultDoesNotDeliverAQueuedInstruction() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.startRemote { sink.record($0) }
        let history = Data((assistantSaid("old") + "\n" + resultSaying("old") + "\n").utf8)
        expectReplay(s, bytes: UInt64(history.count) + 512, .init(taskId: "cece0000", turnWasInFlight: false))
        s.queueForTesting("TASK_ID: cece1111\nnext")

        s.consume(history)
        let replayed = await waitUntil { self.turnEndedCount(s) == 1 }
        XCTAssertTrue(replayed)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(sink.all.isEmpty, "a replayed result ended the retired pane's turn, not this one")
    }

    func testAQueuedInstructionIsDeliveredOnceWhenTheReplayWindowCloses() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.startRemote { sink.record($0) }
        let history = Data((assistantSaid("old") + "\n" + resultSaying("old") + "\n").utf8)
        expectReplay(s, bytes: UInt64(history.count), .init(taskId: "cfcf0000", turnWasInFlight: false))
        s.queueForTesting("TASK_ID: cfcf1111\nnext")

        s.consume(history)
        let delivered = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(delivered)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sink.all.count, 1)
        XCTAssertTrue(String(data: try XCTUnwrap(sink.all.first), encoding: .utf8)?
            .contains("cfcf1111") == true)
    }

    func testAZeroByteRebuildOverAnOpenWindowDeliversTheDeferredInstruction() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.startRemote { sink.record($0) }
        expectReplay(s, bytes: 512, .init(taskId: "d0d00000", turnWasInFlight: false))
        s.queueForTesting("TASK_ID: d0d01111\nnext")
        XCTAssertTrue(sink.all.isEmpty)

        expectReplay(s, bytes: 0, .init(taskId: "d0d00000", turnWasInFlight: false))
        let delivered = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertTrue(String(data: try XCTUnwrap(sink.all.first), encoding: .utf8)?
            .contains("d0d01111") == true)
    }

    func testStoppingDuringReplayEndsTheWindow() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        expectReplay(s, bytes: 512, .init(taskId: "cbcbcbcb", turnWasInFlight: false))
        XCTAssertTrue(s.isReplayingHistoryForTesting)

        s.stop()

        XCTAssertFalse(s.isReplayingHistoryForTesting)
        XCTAssertNil(s.replayDeadlineForTesting)
    }

    /// A second carry handed to a session still holding one: the first is
    /// lost, once and with its own reason, before the second takes its place.
    func testASecondCarryDisplacesTheUninstalledOneWithItsOwnReason() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        var ended: [String?] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.onTurnEnd = { _, _, taskId in ended.append(taskId) }
        s.startRemote { _ in }
        let firstReason = AgentSession.paneRebuildLossReason(cause: "stream rewound")
        expectReplay(s, bytes: 512, .init(taskId: "cccccccc", turnWasInFlight: false),
                     lossReason: firstReason)

        expectReplay(s, bytes: 0, .init(taskId: "cdcdcdcd", turnWasInFlight: false))

        XCTAssertEqual(lost.map(\.0), ["cccccccc"])
        XCTAssertEqual(lost.first?.1, .sessionEnded(firstReason))
        XCTAssertEqual(s.pendingTaskIdForTesting, "cdcdcdcd")
        s.consume(Data((resultSaying(doneReport("new")) + "\n").utf8))
        let settled = await waitUntil { ended == ["cdcdcdcd"] }
        XCTAssertTrue(settled)
        XCTAssertEqual(lost.count, 1)
    }

    /// A dispatch during the replay supersedes the carry, as any newer
    /// dispatch does, and the replayed result cannot settle the newer task.
    func testADispatchDuringReplaySupersedesTheCarry() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        var ended: [String?] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.onTurnEnd = { _, _, taskId in ended.append(taskId) }
        s.startRemote { _ in }
        let history = Data((resultSaying(doneReport("old")) + "\n").utf8)
        expectReplay(s, bytes: UInt64(history.count), .init(taskId: "cececece", turnWasInFlight: false))

        try s.send("TASK_ID: cfcfcfcf\nbuild it", from: .leader)
        XCTAssertEqual(lost.map(\.0), ["cececece"])
        XCTAssertEqual(lost.first?.1, .superseded(by: "cfcfcfcf"))

        s.consume(history)
        let replayed = await waitUntil { !s.isReplayingHistoryForTesting }
        XCTAssertTrue(replayed)
        XCTAssertEqual(s.pendingTaskIdForTesting, "cfcfcfcf", "neither the replay nor the boundary overwrote it")
        XCTAssertTrue(ended.isEmpty)

        s.consume(Data((resultSaying(doneReport("new")) + "\n").utf8))
        let settled = await waitUntil { ended == ["cfcfcfcf"] }
        XCTAssertTrue(settled)
        XCTAssertNil(s.pendingTaskIdForTesting)
        XCTAssertEqual(lost.count, 1)
    }

    func testRedispatchingTheCarriedTaskDuringReplayKeepsItWithoutALoss() async throws {
        var lost: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        let history = Data((resultSaying(doneReport("old")) + "\n").utf8)
        expectReplay(s, bytes: UInt64(history.count), .init(taskId: "dada0000", turnWasInFlight: false))

        try s.send("TASK_ID: dada0000\nbuild it again", from: .leader)
        s.consume(history)
        let closed = await waitUntil { !s.isReplayingHistoryForTesting }

        XCTAssertTrue(closed)
        XCTAssertTrue(lost.isEmpty)
        XCTAssertEqual(s.pendingTaskIdForTesting, "dada0000")
    }

    func testTheReplayDeadlineIsCancelledOnceTheCarryInstalls() async throws {
        var lost: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        let history = Data((assistantSaid("old") + "\n").utf8)
        expectReplay(s, bytes: UInt64(history.count), .init(taskId: "d0d0d0d0", turnWasInFlight: false))
        let deadline = try XCTUnwrap(s.replayDeadlineForTesting)

        s.consume(history)
        let installed = await waitUntil { s.pendingTaskIdForTesting == "d0d0d0d0" }
        XCTAssertTrue(installed)
        XCTAssertNil(s.replayDeadlineForTesting)
        XCTAssertTrue(deadline.isCancelled)
        deadline.perform()

        XCTAssertTrue(lost.isEmpty)
        XCTAssertEqual(s.pendingTaskIdForTesting, "d0d0d0d0")
    }

    /// A displaced window's deadline belongs to the carry it was armed for.
    func testAStaleReplayDeadlineDoesNotLoseTheCarryThatReplacedIt() throws {
        var lost: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        expectReplay(s, bytes: 512, .init(taskId: "d1d1d1d0", turnWasInFlight: false))
        let stale = try XCTUnwrap(s.replayDeadlineForTesting)
        expectReplay(s, bytes: 512, .init(taskId: "d2d2d2d2", turnWasInFlight: false))
        XCTAssertEqual(lost, ["d1d1d1d0"])

        stale.perform()

        XCTAssertEqual(lost, ["d1d1d1d0"])
        XCTAssertTrue(s.isReplayingHistoryForTesting)
    }

    /// The rebuild boundary is what the pane applied, not what it was handed:
    /// a line still waiting for its newline was never applied.
    func testAppliedRemoteBytesStopAtTheLastAppliedLine() async throws {
        let s = AgentSession()
        s.startRemote { _ in }
        let line = Data((assistantSaid("one") + "\n").utf8)

        s.consume(line + Data("{\"type\":\"assi".utf8))

        let applied = await waitUntil { s.appliedRemoteBytes == UInt64(line.count) }
        XCTAssertTrue(applied)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(s.appliedRemoteBytes, UInt64(line.count))
    }

    func testStartingRemoteAgainResetsAppliedRemoteBytes() async throws {
        let s = AgentSession()
        s.startRemote { _ in }
        let line = Data((assistantSaid("one") + "\n").utf8)
        s.consume(line)
        let applied = await waitUntil { s.appliedRemoteBytes == UInt64(line.count) }
        XCTAssertTrue(applied)

        s.stop()
        XCTAssertEqual(s.appliedRemoteBytes, UInt64(line.count), "a rebuild reads it after the stop")
        s.startRemote { _ in }

        XCTAssertEqual(s.appliedRemoteBytes, 0)
    }

    /// One instruction, one turn, one result still holds when the running
    /// turn is one the CLI started: a dispatch landing in it is queued, not
    /// merged into it.
    func testALeaderDispatchWaitsBehindATurnTheCLIStartedItself() async throws {
        let sink = RemoteSinkRecorder()
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        var dispositions: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.startRemote { sink.record($0) }
        try s.send("TASK_ID: aaaa1111\nfirst", from: .leader)
        s.ingestForTesting(resultSaying("in the background"))
        var delivered = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(delivered)

        s.ingestForTesting(assistantSaid("background finished"))
        try s.send("TASK_ID: bbbb2222\nsecond", from: .leader) { disposition in
            if case .queuedBehindTurn = disposition { dispositions.append("queued") }
        }
        XCTAssertEqual(dispositions, ["queued"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sink.all.count, 1, "the dispatch must not merge into the running turn")
        XCTAssertTrue(lost.isEmpty)

        s.ingestForTesting(resultSaying("still no verdict"))
        delivered = await waitUntil { sink.all.count == 2 }
        XCTAssertTrue(delivered)
        XCTAssertTrue(String(data: try XCTUnwrap(sink.all.last), encoding: .utf8)?
            .contains("bbbb2222") == true)
        XCTAssertEqual(lost.map(\.0), ["aaaa1111"])
        XCTAssertEqual(lost.first?.1, .superseded(by: "bbbb2222"))
        XCTAssertEqual(lost.first?.1.reason,
                       "superseded by dispatch of bbbb2222 before an explicit STATUS")
        XCTAssertEqual(s.pendingTaskIdForTesting, "bbbb2222")
    }

    func testRedispatchingTheSameTaskDoesNotSupersedeIt() {
        var lost: [String] = []
        let s = AgentSession()
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.openTurnForTesting(from: .leader, taskId: "same")
        s.ingestForTesting(resultSaying("started"))
        s.openTurnForTesting(from: .leader, taskId: "same")
        XCTAssertTrue(lost.isEmpty)
        XCTAssertEqual(s.pendingTaskIdForTesting, "same")
    }

    /// Hooks and token estimates arrive between turns. They are not the model
    /// generating, so they open no turn — a leader send behind a phantom turn
    /// would queue forever — and they are not activity on the task, or the
    /// deadline would never run out.
    func testIdleSystemEventsOpenNoTurnAndDoNotDeferTheDeadline() async throws {
        let sink = RemoteSinkRecorder()
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession(pendingTaskStatusDeadline: 0.3)
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.startRemote { sink.record($0) }
        try s.send("TASK_ID: 0ddba11\nwork", from: .leader)
        s.ingestForTesting(resultSaying("background"))

        let started = Date()
        while Date().timeIntervalSince(started) < 0.6 {
            s.ingestForTesting(hook())
            XCTAssertFalse(s.isTurnInFlightForTesting)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(lost.map(\.0), ["0ddba11"], "system events must not keep the deadline away")
        XCTAssertEqual(lost.first?.1, .noStatusDeadline(0.3))

        try s.send("anything else?", from: .leader)
        let written = await waitUntil { sink.all.count == 2 }
        XCTAssertTrue(written, "no phantom turn holds the leader back")
    }

    func testTheStatusDeadlineFiresOnceForAQuietUnsettledTask() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession(pendingTaskStatusDeadline: 0.05)
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.startRemote { _ in }
        try s.send("TASK_ID: quiet\nwork", from: .leader)
        s.ingestForTesting(resultSaying("background"))

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(lost.map(\.0), ["quiet"])
        XCTAssertEqual(lost.first?.1, .noStatusDeadline(0.05))
        XCTAssertEqual(s.pendingTaskIdForTesting, "quiet",
                       "a late explicit STATUS can still close it")
    }

    func testTheStatusDeadlineNeverFiresAfterAnExplicitStatus() async throws {
        var lost: [String] = []
        let s = AgentSession(pendingTaskStatusDeadline: 0.05)
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        try s.send("TASK_ID: stated\nwork", from: .leader)
        s.ingestForTesting(resultSaying("STATUS: BLOCKED\nNEXT: need a key"))

        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(lost.isEmpty)
        XCTAssertNil(s.pendingTaskIdForTesting)
    }

    /// A STATUS in a turn not tied to the task still settles nothing, but the
    /// block that follows says it was stated rather than claiming silence.
    func testAStatusStatedOutsideTheTaskIsNamedWhenTheDeadlineBlocksIt() async throws {
        for speaker in [AgentSession.Speaker.leader, .person] {
            var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
            let s = AgentSession(pendingTaskStatusDeadline: 0.05)
            s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
            s.startRemote { _ in }
            try s.send("TASK_ID: outside1\nwork", from: .leader)
            s.ingestForTesting(resultSaying("Running in the background."))
            try s.send("how is it going?", from: speaker)
            s.ingestForTesting(resultSaying("STATUS: DONE"))
            XCTAssertEqual(s.pendingTaskIdForTesting, "outside1", "\(speaker) turn settles nothing")

            let fired = await waitUntil { !lost.isEmpty }
            XCTAssertTrue(fired)
            XCTAssertEqual(lost.map(\.0), ["outside1"])
            XCTAssertEqual(lost.first?.1, .noStatusDeadline(0.05, statedOutsideTask: true))
            s.stop()
        }
        XCTAssertEqual(
            AgentSession.TaskCorrelationLoss.noStatusDeadline(10 * 60, statedOutsideTask: true).reason,
            "No explicit STATUS after 10 min without activity; a STATUS was stated in a turn not tied to this task (leader message without TASK_ID or person input)")
    }

    func testANewCorrelationForgetsAStatusStatedOutsideTheOldOne() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = AgentSession(pendingTaskStatusDeadline: 0.05)
        s.onTaskCorrelationLost = { task, loss in lost.append((task, loss)) }
        s.startRemote { _ in }
        try s.send("TASK_ID: outside1\nwork", from: .leader)
        s.ingestForTesting(resultSaying("Running in the background."))
        try s.send("how is it going?", from: .person)
        s.ingestForTesting(resultSaying("STATUS: DONE"))
        try s.send("TASK_ID: outside2\nnext", from: .leader)
        s.ingestForTesting(resultSaying("Running in the background."))

        let fired = await waitUntil { lost.count == 2 }
        XCTAssertTrue(fired)
        XCTAssertEqual(lost.map(\.0), ["outside1", "outside2"])
        XCTAssertEqual(lost.last?.1, .noStatusDeadline(0.05))
        s.stop()
    }

    // MARK: - The incident against a real task board

    /// Wired exactly as `TeamOrchestrator.wireNativeWorkerCompletion` wires a
    /// worker, minus `fileReport`, which writes under the real home directory.
    private func boardWiredSession(
        team: String, instance: String, deadline: TimeInterval = 10 * 60
    ) -> AgentSession {
        let s = AgentSession(pendingTaskStatusDeadline: deadline)
        s.onTurnEnd = { final, _, taskId in
            AutoReplyEmit.settleNativeTurn(
                teamName: team, agentName: "executor", agentInstanceId: instance,
                final: final, taskId: taskId, store: .shared)
        }
        s.onTaskCorrelationLost = { taskId, loss in
            AutoReplyEmit.blockUnsettledTask(
                teamName: team, agentName: "executor", agentInstanceId: instance,
                taskId: taskId, reason: loss.reason, store: .shared)
        }
        return s
    }

    private func boardTask(team: String, instance: String) throws -> TeamOrchestrator.TeamTask {
        let store = TeamDataStore.shared
        store.registerTeam(team, agents: [.init(name: "executor", instanceId: instance)])
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "long suite", assignee: "executor",
            assigneeInstanceId: instance))
        return try XCTUnwrap(store.updateTask(teamName: team, taskId: task.id, status: "in_progress"))
    }

    private let doneHeader = "STATUS: DONE\nFILES: none\nVERIFY: suite green\nNEXT: NONE\nFULL_REPORT: n/a"

    func testTheIncidentClosesTheSameTaskOnTheContinuationsVerdict() throws {
        let team = "incident-continuation-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        let s = boardWiredSession(team: team, instance: "inst-1")
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nrun the full suite", from: .leader)
        s.ingestForTesting(resultSaying("The suite runs past the tool timeout; it is in the background."))

        let waiting = try XCTUnwrap(store.getTask(teamName: team, taskId: task.id))
        XCTAssertEqual(waiting.status, "in_progress", "a turn without a verdict settles nothing")
        XCTAssertNil(waiting.result)
        XCTAssertEqual(store.getMessages(teamName: team, type: "progress").count, 1)
        XCTAssertNil(store.readResult(teamName: team, taskId: task.id, agentName: "executor"))

        s.ingestForTesting(assistantSaid("The background suite finished."))
        s.ingestForTesting(resultSaying(doneHeader))

        let done = try XCTUnwrap(store.getTask(teamName: team, taskId: task.id))
        XCTAssertEqual(done.status, "completed")
        XCTAssertEqual(done.assigneeInstanceId, "inst-1")
        XCTAssertNotNil(store.readResult(teamName: team, taskId: task.id, agentName: "executor"))
        s.stop()
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "completed",
                       "stopping after the verdict must not reopen or block it")
    }

    func testAWorkerThatNeverStatesAVerdictIsBlockedThenClosedByALateOne() async throws {
        let team = "incident-deadline-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        let s = boardWiredSession(team: team, instance: "inst-1", deadline: 0.05)
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nrun the full suite", from: .leader)
        s.ingestForTesting(resultSaying("Running in the background."))
        let blocked = await waitUntil {
            store.getTask(teamName: team, taskId: task.id)?.status == "blocked"
        }
        XCTAssertTrue(blocked, "never review_ready: nobody said NEEDS_REVIEW")
        XCTAssertTrue(store.getTask(teamName: team, taskId: task.id)?.blockedReason?
            .hasPrefix("No explicit STATUS") == true)

        s.ingestForTesting(assistantSaid("The background suite finished."))
        s.ingestForTesting(resultSaying(doneHeader))

        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "completed")
        s.stop()
    }

    private func continuationSession(
        team: String, instance: String, deadline: TimeInterval = 10 * 60,
        turnTaskIds: @escaping (String?) -> Void = { _ in },
        lost: @escaping (String) -> Void = { _ in }
    ) -> AgentSession {
        let s = AgentSession(pendingTaskStatusDeadline: deadline)
        s.onTurnEnd = { final, _, taskId in
            turnTaskIds(taskId)
            AutoReplyEmit.settleNativeTurn(
                teamName: team, agentName: "executor", agentInstanceId: instance,
                final: final, taskId: taskId, store: .shared)
        }
        s.onTaskCorrelationLost = { taskId, loss in
            lost(taskId)
            AutoReplyEmit.blockUnsettledTask(
                teamName: team, agentName: "executor", agentInstanceId: instance,
                taskId: taskId, reason: loss.reason, store: .shared)
        }
        return s
    }

    private func header(_ status: String) -> String {
        "STATUS: \(status)\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a"
    }

    func testAnExplicitBlockedTaskIsClosedByTheWorkersOwnLaterDone() throws {
        let team = "continue-blocked-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        var turnTaskIds: [String?] = []
        let s = continuationSession(team: team, instance: "inst-1", turnTaskIds: { turnTaskIds.append($0) })
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nrun the full suite", from: .leader)
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "blocked")

        s.ingestForTesting(assistantSaid("Retrying after the block."))
        s.ingestForTesting(resultSaying(header("DONE")))

        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "completed")
        XCTAssertEqual(turnTaskIds.compactMap { $0 }, [task.id, task.id])
        s.stop()
    }

    func testAReviewReadyTaskIsClosedByTheWorkersOwnLaterDone() throws {
        let team = "continue-review-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        let s = continuationSession(team: team, instance: "inst-1")
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nrun the full suite", from: .leader)
        s.ingestForTesting(resultSaying(header("NEEDS_REVIEW")))
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "review_ready")

        s.ingestForTesting(assistantSaid("Reviewed my own work."))
        s.ingestForTesting(resultSaying(header("DONE")))

        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "completed")
        s.stop()
    }

    func testAParkedTaskStaysParkedThroughAnotherBlockedAndIsStillClosedByDone() throws {
        let team = "continue-twice-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        let s = continuationSession(team: team, instance: "inst-1")
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        s.ingestForTesting(assistantSaid("Tried again."))
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "blocked")

        s.ingestForTesting(assistantSaid("Now it works."))
        s.ingestForTesting(resultSaying(header("DONE")))

        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "completed")
        s.stop()
    }

    func testAFinishedTaskIsNeverReopenedByALaterTurnOfTheWorker() throws {
        let team = "continue-finished-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        var turnTaskIds: [String?] = []
        let s = continuationSession(team: team, instance: "inst-1", turnTaskIds: { turnTaskIds.append($0) })
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        s.ingestForTesting(assistantSaid("Done now."))
        s.ingestForTesting(resultSaying(header("DONE")))
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "completed")

        s.ingestForTesting(assistantSaid("Unrelated chatter."))
        s.ingestForTesting(resultSaying(header("BLOCKED")))

        XCTAssertEqual(turnTaskIds, [task.id, task.id, nil],
                       "a turn after the verdict answers no task")
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "completed")
        s.stop()
    }

    func testAPlainLeaderOrPersonTurnNeverClosesAParkedTask() throws {
        for speaker in [AgentSession.Speaker.leader, .person] {
            let team = "continue-plain-\(UUID().uuidString)"
            let store = TeamDataStore.shared
            let task = try boardTask(team: team, instance: "inst-1")
            defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
            var turnTaskIds: [String?] = []
            let s = continuationSession(team: team, instance: "inst-1", turnTaskIds: { turnTaskIds.append($0) })
            s.startRemote { _ in }

            try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
            s.ingestForTesting(resultSaying(header("BLOCKED")))
            try s.send("how is it going?", from: speaker)
            s.ingestForTesting(resultSaying(header("DONE")))

            XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "blocked",
                           "\(speaker)")
            XCTAssertEqual(turnTaskIds.count, 2, "\(speaker)")
            XCTAssertNil(turnTaskIds.last ?? nil, "\(speaker)")
            s.stop()
        }
    }

    func testABackgroundDoneAfterAQuestionNeverClosesTheParkedTask() throws {
        for speaker in [AgentSession.Speaker.leader, .person] {
            let team = "continue-question-\(UUID().uuidString)"
            let store = TeamDataStore.shared
            let task = try boardTask(team: team, instance: "inst-1")
            defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
            var turnTaskIds: [String?] = []
            let s = continuationSession(team: team, instance: "inst-1", turnTaskIds: { turnTaskIds.append($0) })
            s.startRemote { _ in }

            try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
            s.ingestForTesting(resultSaying(header("BLOCKED")))
            try s.send("run the linter in the background", from: speaker)
            XCTAssertNil(s.parkedTaskIdForTesting, "\(speaker)")
            s.ingestForTesting(resultSaying("Started it in the background."))
            s.ingestForTesting(assistantSaid("The linter finished."))
            s.ingestForTesting(resultSaying(header("DONE")))

            XCTAssertEqual(turnTaskIds.count, 3, "\(speaker)")
            XCTAssertNil(turnTaskIds.last ?? nil, "\(speaker)")
            XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "blocked", "\(speaker)")
            s.stop()
        }
    }

    func testAPersonJoiningAContinuationTurnDropsTheParkedTask() throws {
        let team = "continue-join-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        var turnTaskIds: [String?] = []
        let s = continuationSession(team: team, instance: "inst-1", turnTaskIds: { turnTaskIds.append($0) })
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        s.ingestForTesting(assistantSaid("Working on something."))
        try s.send("also, what time is it?", from: .person)
        XCTAssertNil(s.parkedTaskIdForTesting)
        s.ingestForTesting(resultSaying(header("DONE")))

        XCTAssertNil(turnTaskIds.last ?? nil)
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "blocked")
        s.stop()
    }

    func testAReplayWindowDropsTheParkedTask() async throws {
        let team = "continue-replay-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        var turnTaskIds: [String?] = []
        let s = continuationSession(team: team, instance: "inst-1", turnTaskIds: { turnTaskIds.append($0) })
        s.startRemote { _ in }
        let history = Data((resultSaying(header("DONE")) + "\n").utf8)

        try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        XCTAssertEqual(s.parkedTaskIdForTesting, task.id)
        expectReplay(s, bytes: UInt64(history.count), .init(taskId: "c0c0c0c0", turnWasInFlight: false))
        XCTAssertNil(s.parkedTaskIdForTesting)
        s.consume(history)
        let replayed = await waitUntil { self.turnEndedCount(s) == 2 }

        XCTAssertTrue(replayed)
        XCTAssertEqual(turnTaskIds.count, 1, "the replayed DONE must not reach onTurnEnd")
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "blocked")
        s.stop()
    }

    func testANewTaskIdDispatchLetsGoOfTheParkedTask() throws {
        let team = "continue-newtask-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let first = try boardTask(team: team, instance: "inst-1")
        let second = try XCTUnwrap(store.createTask(
            teamName: team, title: "other", assignee: "executor", assigneeInstanceId: "inst-1"))
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        let s = continuationSession(team: team, instance: "inst-1")
        s.startRemote { _ in }

        try s.send("TASK_ID: \(first.id)\nwork", from: .leader)
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        try s.send("TASK_ID: \(second.id)\nother work", from: .leader)
        XCTAssertEqual(s.pendingTaskIdForTesting, second.id)
        XCTAssertNil(s.parkedTaskIdForTesting)
        s.ingestForTesting(resultSaying(header("DONE")))
        s.ingestForTesting(assistantSaid("Unrelated."))
        s.ingestForTesting(resultSaying(header("DONE")))

        XCTAssertEqual(store.getTask(teamName: team, taskId: second.id)?.status, "completed")
        XCTAssertEqual(store.getTask(teamName: team, taskId: first.id)?.status, "blocked")
        s.stop()
    }

    func testAParkedTaskIsNotBlockedAgainByTheStatusDeadline() async throws {
        let team = "continue-deadline-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        var lost: [String] = []
        let s = continuationSession(
            team: team, instance: "inst-1", deadline: 0.05, lost: { lost.append($0) })
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
        s.ingestForTesting(resultSaying("STATUS: BLOCKED\nNEXT: need a key\n\nthe key is missing"))
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(lost.isEmpty)
        let parked = try XCTUnwrap(store.getTask(teamName: team, taskId: task.id))
        XCTAssertEqual(parked.status, "blocked")
        XCTAssertFalse(parked.blockedReason?.hasPrefix("No explicit STATUS") == true)
        s.stop()
    }

    func testAVerdictlessTurnOnAParkedTaskTouchesNothing() throws {
        let team = "continue-silent-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        var turnTaskIds: [String?] = []
        let s = continuationSession(team: team, instance: "inst-1", turnTaskIds: { turnTaskIds.append($0) })
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        let progressBefore = store.getMessages(teamName: team, type: "progress").count
        s.ingestForTesting(assistantSaid("Thinking out loud."))
        s.ingestForTesting(resultSaying("Still looking at it."))

        XCTAssertEqual(turnTaskIds.count, 2)
        XCTAssertNil(turnTaskIds.last ?? nil)
        XCTAssertEqual(store.getMessages(teamName: team, type: "progress").count, progressBefore)
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "blocked")
        XCTAssertEqual(s.parkedTaskIdForTesting, task.id)
        s.stop()
    }

    func testStoppingTheSessionDropsTheParkedTask() throws {
        let team = "continue-stop-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        let s = continuationSession(team: team, instance: "inst-1")
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
        s.ingestForTesting(resultSaying(header("BLOCKED")))
        XCTAssertEqual(s.parkedTaskIdForTesting, task.id)
        s.stop()

        XCTAssertNil(s.parkedTaskIdForTesting)
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "blocked")
    }

    // MARK: - #817 the working directory travels with the turn

    private func frames(_ sink: RemoteSinkRecorder) throws -> [[String: Any]] {
        try sink.all.map { payload in
            XCTAssertEqual(payload.last, 0x0A)
            return try XCTUnwrap(try JSONSerialization.jsonObject(
                with: payload.dropLast()) as? [String: Any])
        }
    }

    private func frame(_ sink: RemoteSinkRecorder, _ index: Int) throws -> [String: Any] {
        let all = try frames(sink)
        return try XCTUnwrap(all.indices.contains(index) ? all[index] : nil,
                             "frame \(index) was never sent; the sink holds \(all.count)")
    }

    private func capsule(task: String, worktree: String?, goal: String = "do the thing") -> String {
        var lines = ["## Task Capsule", "TASK_ID: \(task)", "TASK_TITLE: t", "TASK_STATUS: assigned",
                     "PROTOCOL: TM-PROTOCOL-v1"]
        if let worktree {
            lines += ["WORKTREE_PATH: \(worktree)", "WORKTREE_BRANCH: tm/x/\(task)",
                      "WORKDIR_INSTRUCTION: Run commands from this worktree: cd \(worktree)"]
        }
        lines += ["", "[GOAL]", goal, "[/GOAL]"]
        return lines.joined(separator: "\n")
    }

    func testTheDefaultUserFrameCarriesNoWorkingDirectory() throws {
        let data = try AgentSession.encode(text: "hello")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: data.dropLast()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["type", "message"])
        let withCwd = try AgentSession.encode(text: "hello", cwd: "/work/a")
        let framed = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: withCwd.dropLast()) as? [String: Any])
        XCTAssertEqual(Set(framed.keys), ["type", "message", "cwd"])
        XCTAssertEqual(framed["cwd"] as? String, "/work/a")
        XCTAssertEqual((framed["message"] as? [String: Any])?["content"] as? String, "hello")
    }

    func testACodexSessionSendsTheTaskWorktreeAsTheTurnsCwd() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.workingDirectoryForTask = { ["aaaa1111": "/wt/a"][$0] }
        s.startRemote(cli: "codex") { sink.record($0) }

        try s.send(capsule(task: "aaaa1111", worktree: "/wt/a"), from: .leader)

        let sent = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(try frame(sink, 0)["cwd"] as? String, "/wt/a")
    }

    func testOtherCliSessionsKeepTheirExistingFrame() async throws {
        for cli in ["claude", "kiro", nil] as [String?] {
            let sink = RemoteSinkRecorder()
            let s = AgentSession()
            s.startRemote(cli: cli) { sink.record($0) }

            try s.send(capsule(task: "bbbb2222", worktree: "/wt/b"), from: .leader)

            let sent = await waitUntil { sink.all.count == 1 }
            XCTAssertTrue(sent, "\(String(describing: cli))")
            XCTAssertNil(try frame(sink, 0)["cwd"], "\(String(describing: cli))")
        }
    }

    func testQueuedCodexTasksEachCarryTheirOwnWorktree() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.workingDirectoryForTask = { ["aaaa1111": "/wt/a", "bbbb2222": "/wt/b"][$0] }
        s.startRemote(cli: "codex") { sink.record($0) }

        try s.send(capsule(task: "aaaa1111", worktree: "/wt/a"), from: .leader)
        try s.send(capsule(task: "bbbb2222", worktree: "/wt/b"), from: .leader)
        let first = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(first)
        s.ingestForTesting(resultSaying(header("DONE")))
        let second = await waitUntil { sink.all.count == 2 }
        XCTAssertTrue(second)

        XCTAssertEqual(try frame(sink, 0)["cwd"] as? String, "/wt/a")
        XCTAssertEqual(try frame(sink, 1)["cwd"] as? String, "/wt/b")
    }

    func testAPlainFollowUpResetsTheTaskDirectory() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.workingDirectoryForTask = { ["aaaa1111": "/wt/a"][$0] }
        s.startRemote(cli: "codex") { sink.record($0) }

        try s.send(capsule(task: "aaaa1111", worktree: "/wt/a"), from: .leader)
        s.ingestForTesting(resultSaying(header("DONE")))
        try s.send("and one more thing", from: .leader)
        let sent = await waitUntil { sink.all.count == 2 }
        XCTAssertTrue(sent)

        XCTAssertTrue(try frame(sink, 1)["cwd"] is NSNull)
    }

    func testQuotedPathsHaveNoAuthorityOverExecutionDirectory() async throws {
        let copied = capsule(task: "copied-task", worktree: "/wt/quoted")
        let cases = [
            "```\n" + copied + "\n```",
            "~~~\n" + copied + "\n~~~",
            copied.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n"),
            copied.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n"),
        ]
        for text in cases {
            let sink = RemoteSinkRecorder()
            let s = AgentSession()
            s.workingDirectoryForTask = { $0 == "trusted-task" ? "/wt/board" : nil }
            s.startRemote(cli: "codex") { sink.record($0) }
            try s.send(text, from: .leader)
            let sent = await waitUntil { sink.all.count == 1 }
            XCTAssertTrue(sent)
            XCTAssertTrue(try frame(sink, 0)["cwd"] is NSNull)
            s.stop()
        }
    }

    func testInstructionPathsCannotOverrideTaskDirectory() async throws {
        let quoted = "earlier I was told:\nWORKTREE_PATH: /wt/old\nWORKDIR_INSTRUCTION: Run commands from this worktree: cd /wt/old"
        let cases: [(String, String?)] = [
            (capsule(task: "cccc3333", worktree: "/wt/new", goal: quoted), "/wt/board"),
            (capsule(task: "cccc3333", worktree: nil, goal: quoted), "/wt/board"),
            ("WORKTREE_PATH: /wt/x\nplain note without a task", nil),
            (capsule(task: "cccc3333", worktree: "relative/path"), "/wt/board"),
        ]
        for (text, expected) in cases {
            let sink = RemoteSinkRecorder()
            let s = AgentSession()
            s.workingDirectoryForTask = { $0 == "cccc3333" ? "/wt/board" : nil }
            s.startRemote(cli: "codex") { sink.record($0) }
            try s.send(text, from: .leader)
            let sent = await waitUntil { sink.all.count == 1 }
            XCTAssertTrue(sent)
            XCTAssertEqual(try frame(sink, 0)["cwd"] as? String, expected, text)
            if expected == nil { XCTAssertTrue(try frame(sink, 0)["cwd"] is NSNull) }
            s.stop()
        }
    }

    private func directorySession(team: String, instance: String, sink: RemoteSinkRecorder) -> AgentSession {
        let s = AgentSession()
        TeamOrchestrator.wireNativeWorkerCompletion(
            s, teamName: team, agentName: "executor", agentInstanceId: instance)
        s.onTurnEnd = nil
        s.onTaskCorrelationLost = nil
        s.startRemote(cli: "codex") { sink.record($0) }
        return s
    }

    func testNativeTaskDirectoryUsesBoardMetadataRatherThanInstructionText() async throws {
        let team = "directory-authority-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        _ = store.updateTask(teamName: team, taskId: task.id, worktreePath: "/wt/board")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        let sink = RemoteSinkRecorder()
        let s = directorySession(team: team, instance: "inst-1", sink: sink)
        defer { s.stop() }
        try s.send(capsule(task: task.id, worktree: "/wt/untrusted-text"), from: .leader)
        let sent = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(try frame(sink, 0)["cwd"] as? String, "/wt/board")
    }

    func testNativeCodexUnboundAndWorktreeLessTurnsResetDirectory() async throws {
        let team = "directory-reset-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let first = try boardTask(team: team, instance: "inst-1")
        _ = store.updateTask(teamName: team, taskId: first.id, worktreePath: "/wt/first")
        let second = try XCTUnwrap(store.createTask(
            teamName: team, title: "no worktree", assignee: "executor", assigneeInstanceId: "inst-1"))
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        let sink = RemoteSinkRecorder()
        let s = directorySession(team: team, instance: "inst-1", sink: sink)
        defer { s.stop() }
        try s.send(capsule(task: first.id, worktree: "/wt/first"), from: .leader)
        s.ingestForTesting(resultSaying(header("DONE")))
        try s.send(capsule(task: second.id, worktree: nil), from: .leader)
        s.ingestForTesting(resultSaying(header("DONE")))
        try s.send("unrelated question", from: .leader)
        s.ingestForTesting(resultSaying(header("DONE")))
        try s.send(capsule(task: first.id, worktree: "/wt/untrusted-person"), from: .person)
        let sent = await waitUntil { sink.all.count == 4 }
        XCTAssertTrue(sent)
        XCTAssertEqual(try frame(sink, 0)["cwd"] as? String, "/wt/first")
        for index in 1...3 {
            XCTAssertTrue(try frame(sink, index)["cwd"] is NSNull, "turn \(index) must reset cwd")
        }
    }

    func testNativeTaskDirectoryRejectsWrongInstanceAndTerminalTasks() async throws {
        let team = "directory-identity-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-2")
        _ = store.updateTask(teamName: team, taskId: task.id, worktreePath: "/wt/other")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        for terminal in [false, true] {
            if terminal { _ = store.updateTask(teamName: team, taskId: task.id, status: "completed") }
            let sink = RemoteSinkRecorder()
            let s = directorySession(team: team, instance: terminal ? "inst-2" : "inst-1", sink: sink)
            try s.send(capsule(task: task.id, worktree: "/wt/other"), from: .leader)
            let sent = await waitUntil { sink.all.count == 1 }
            XCTAssertTrue(sent)
            XCTAssertTrue(try frame(sink, 0)["cwd"] is NSNull)
            s.stop()
        }
    }

    func testNativeReportRoutingDoesNotOverwriteReassignedOrCompletedTasks() throws {
        for reassigned in [true, false] {
            let team = "report-owner-\(UUID().uuidString)"
            let store = TeamDataStore.shared
            store.registerTeam(team, agents: [
                .init(name: "executor", instanceId: "inst-1"),
                .init(name: "executor", instanceId: "inst-2"),
            ])
            let task = try XCTUnwrap(store.createTask(
                teamName: team, title: "report ownership", assignee: "executor", assigneeInstanceId: "inst-1"))
            _ = store.updateTask(teamName: team, taskId: task.id, status: "in_progress")
            defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
            var reportTaskIds: [String?] = []
            let s = AgentSession()
            TeamOrchestrator.wireNativeWorkerCompletion(
                s, teamName: team, agentName: "executor", agentInstanceId: "inst-1",
                report: { taskId, _ in reportTaskIds.append(taskId) })
            s.startRemote { _ in }
            try s.send("TASK_ID: \(task.id)\nwork", from: .leader)
            s.ingestForTesting(resultSaying(header("BLOCKED")))
            if reassigned {
                let updated = try XCTUnwrap(store.updateTask(
                    teamName: team, taskId: task.id, assignee: "executor", assigneeInstanceId: "inst-2"))
                XCTAssertEqual(updated.assigneeInstanceId, "inst-2")
            } else {
                _ = store.updateTask(teamName: team, taskId: task.id, status: "completed")
            }
            s.ingestForTesting(assistantSaid("An old continuation finished."))
            s.ingestForTesting(resultSaying(header("DONE")))
            XCTAssertEqual(reportTaskIds, [task.id, nil], "stale reports must update only the worker alias")
            XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status,
                           reassigned ? "blocked" : "completed")
            s.stop()
        }
    }

    // MARK: - #818 tool failure health

    private let scriptFailure = "Script failed\nWall time 0.0 seconds\nScript error:\nSyntaxError: Invalid or unexpected token"

    private func toolUse(_ id: String, name: String = "Bash") -> String {
        event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": id, "name": name, "input": ["command": "run \(id)"]]]]])
    }

    private func toolResult(_ id: String, _ content: String, failed: Bool) -> String {
        event(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": failed]]]])
    }

    private func failTool(_ s: AgentSession, _ id: String, name: String = "Bash", body: String? = nil) {
        s.ingestForTesting(toolUse(id, name: name))
        s.ingestForTesting(toolResult(id, body ?? scriptFailure, failed: true))
    }

    private func passTool(_ s: AgentSession, _ id: String) {
        s.ingestForTesting(toolUse(id))
        s.ingestForTesting(toolResult(id, "ok", failed: false))
    }

    private func health(_ s: AgentSession) -> [String: Any] { s.toolFailureSummary }

    func testToolFailureSummaryCountsAConsecutiveStreakAndFlagsAttentionAtThree() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("fix it", from: .person)

        failTool(s, "f1")
        failTool(s, "f2", name: "exec")
        var summary = health(s)
        XCTAssertEqual(summary["total"] as? Int, 2)
        XCTAssertEqual(summary["turn_failures"] as? Int, 2)
        XCTAssertEqual(summary["consecutive"] as? Int, 2)
        XCTAssertEqual(summary["needs_attention"] as? Bool, false)

        failTool(s, "f3", name: "exec")
        summary = health(s)
        XCTAssertEqual(summary["total"] as? Int, 3)
        XCTAssertEqual(summary["consecutive"] as? Int, 3)
        XCTAssertEqual(summary["needs_attention"] as? Bool, true)
        XCTAssertEqual(summary["last_tool"] as? String, "exec")
        XCTAssertEqual(summary["last_error"] as? String, "SyntaxError: Invalid or unexpected token")
    }

    func testASelfStartedTurnKeepsItsFailuresAfterCompletion() {
        let s = AgentSession()
        s.startRemote { _ in }
        failTool(s, "self1")
        failTool(s, "self2")
        failTool(s, "self3")
        XCTAssertEqual(health(s)["consecutive"] as? Int, 3)
        s.ingestForTesting(event(["type": "result", "stop_reason": "end_turn", "is_error": false]))
        XCTAssertEqual(health(s)["turn_failures"] as? Int, 3)
        XCTAssertEqual(health(s)["consecutive"] as? Int, 3)
        XCTAssertEqual(health(s)["needs_attention"] as? Bool, true)
    }

    func testASelfStartedTurnDoesNotInheritThePreviousStreak() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("first turn", from: .person)
        failTool(s, "written1")
        failTool(s, "written2")
        s.ingestForTesting(event(["type": "result", "stop_reason": "end_turn", "is_error": false]))
        failTool(s, "self1")
        XCTAssertEqual(health(s)["total"] as? Int, 3)
        XCTAssertEqual(health(s)["turn_failures"] as? Int, 1)
        XCTAssertEqual(health(s)["consecutive"] as? Int, 1)
        XCTAssertEqual(health(s)["needs_attention"] as? Bool, false)
    }

    func testASuccessResetsTheStreakButNotTheTurnOrSessionCounts() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("fix it", from: .person)

        failTool(s, "f1")
        failTool(s, "f2")
        passTool(s, "ok1")
        failTool(s, "f3")

        let summary = health(s)
        XCTAssertEqual(summary["total"] as? Int, 3)
        XCTAssertEqual(summary["turn_failures"] as? Int, 3)
        XCTAssertEqual(summary["consecutive"] as? Int, 1)
        XCTAssertEqual(summary["needs_attention"] as? Bool, false)
    }

    func testANewTurnResetsTheTurnAndStreakCountsButKeepsTheSessionTotal() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("first", from: .person)
        failTool(s, "f1")
        failTool(s, "f2")
        failTool(s, "f3")
        s.ingestForTesting(resultSaying("giving up"))
        XCTAssertEqual(health(s)["turn_failures"] as? Int, 3, "the latest turn stays visible after it ends")

        try s.send("second", from: .person)

        let summary = health(s)
        XCTAssertEqual(summary["total"] as? Int, 3)
        XCTAssertEqual(summary["turn_failures"] as? Int, 0)
        XCTAssertEqual(summary["consecutive"] as? Int, 0)
        XCTAssertEqual(summary["needs_attention"] as? Bool, false)
    }

    func testARepeatedToolResultIsCountedOnce() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("fix it", from: .person)

        failTool(s, "dup")
        s.ingestForTesting(toolResult("dup", scriptFailure, failed: true))
        s.ingestForTesting(toolUse("dup"))
        s.ingestForTesting(toolResult("dup", scriptFailure, failed: true))

        XCTAssertEqual(health(s)["total"] as? Int, 1)
        XCTAssertEqual(health(s)["consecutive"] as? Int, 1)
    }

    func testACancelledToolIsNotAFailure() throws {
        let s = AgentSession()
        s.startRemote(interruptible: true) { _ in }
        try s.send("long job", from: .person)
        s.ingestForTesting(toolUse("c1"))

        s.interrupt()
        s.ingestForTesting(toolResult("c1", "interrupted by user", failed: true))

        XCTAssertEqual(health(s)["total"] as? Int, 0)
        XCTAssertEqual(health(s)["consecutive"] as? Int, 0)
        XCTAssertNil(health(s)["last_error"])
        XCTAssertNil(health(s)["last_tool"])

        s.ingestForTesting(resultSaying("stopped"))
        try s.send("again", from: .person)
        failTool(s, "real")
        XCTAssertEqual(health(s)["total"] as? Int, 1, "a genuine failure after the stop still counts")
    }

    func testFailureCountsSurviveTranscriptPruning() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("fix it", from: .person)
        failTool(s, "f1")
        failTool(s, "f2")

        for index in 0..<2_100 { s.appendLocalNotice("filler \(index)") }

        let summary = health(s)
        XCTAssertEqual(summary["total"] as? Int, 2)
        XCTAssertEqual(summary["consecutive"] as? Int, 2)
        XCTAssertEqual(summary["last_error"] as? String, "SyntaxError: Invalid or unexpected token")
    }

    func testReplayedFailuresAreNotCounted() async throws {
        let s = AgentSession()
        s.startRemote { _ in }
        let history = Data((toolUse("old") + "\n" + toolResult("old", scriptFailure, failed: true) + "\n"
            + resultSaying("earlier turn") + "\n").utf8)

        expectReplay(s, bytes: UInt64(history.count), .init(taskId: "c0c0c0c0", turnWasInFlight: false))
        s.consume(history)
        let replayed = await waitUntil { self.turnEndedCount(s) == 1 }

        XCTAssertTrue(replayed)
        XCTAssertEqual(health(s)["total"] as? Int, 0)

        try s.send("live", from: .person)
        failTool(s, "live1")
        XCTAssertEqual(health(s)["total"] as? Int, 1, "a live failure after the replay window still counts")
    }

    func testTheRealCodexWrapperShapeSummarizesTheScriptErrorNotTheOutputLabel() throws {
        let wrapper = "Script failed\nWall time 0.0 seconds\nOutput:\nScript error:\nSyntaxError: Invalid or unexpected token"
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("fix it", from: .person)

        failTool(s, "w1", name: "exec", body: wrapper)

        XCTAssertEqual(health(s)["last_error"] as? String, "SyntaxError: Invalid or unexpected token")
        let row = try XCTUnwrap(s.visibleTranscriptText().components(separatedBy: "\n").first {
            $0.hasPrefix("exec ")
        })
        XCTAssertTrue(row.hasSuffix("failed: SyntaxError: Invalid or unexpected token"), row)
    }

    func testAnOutputLineThatCarriesTextIsStillAUsefulErrorLine() {
        XCTAssertEqual(
            AgentSession.usefulErrorLine(in: "Output: permission denied\nexit 1"),
            "Output: permission denied")
        XCTAssertEqual(AgentSession.usefulErrorLine(in: "Output:\n\n"), "Output:")
    }

    func testTheLastToolNameIsBoundedAndRedactedButNormalNamesSurvive() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("fix it", from: .person)

        failTool(s, "n1", name: "exec")
        XCTAssertEqual(health(s)["last_tool"] as? String, "exec")

        failTool(s, "n2", name: "API_KEY=fixturesecret")
        let redacted = try XCTUnwrap(health(s)["last_tool"] as? String)
        XCTAssertFalse(redacted.contains("fixturesecret"), redacted)

        failTool(s, "n3", name: "tool_" + String(repeating: "z", count: 10_500))
        let bounded = try XCTUnwrap(health(s)["last_tool"] as? String)
        XCTAssertLessThanOrEqual(bounded.utf8.count, 200, "\(bounded.utf8.count)")
        XCTAssertTrue(bounded.hasPrefix("tool_"), bounded)

        let transcript = s.visibleTranscriptText()
        XCTAssertFalse(transcript.contains("fixturesecret"))
        XCTAssertFalse(transcript.contains(String(repeating: "z", count: 1_000)))
    }

    func testNothingFailedMeansNoLastFields() {
        let summary = AgentSession().toolFailureSummary
        XCTAssertEqual(summary["total"] as? Int, 0)
        XCTAssertEqual(summary["turn_failures"] as? Int, 0)
        XCTAssertEqual(summary["consecutive"] as? Int, 0)
        XCTAssertEqual(summary["needs_attention"] as? Bool, false)
        XCTAssertNil(summary["last_error"])
        XCTAssertNil(summary["last_tool"])
    }

    func testTheVisibleTranscriptShowsABoundedRedactedErrorOnAFailedToolRow() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("fix it", from: .person)
        let token = "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
        failTool(s, "f1", body: "Error: push rejected for \(token)\n" + String(repeating: "x", count: 5_000))

        let text = s.visibleTranscriptText()
        let row = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("Bash ") })

        XCTAssertTrue(row.contains("Error: push rejected"), row)
        XCTAssertFalse(row.contains(token), row)
        XCTAssertLessThan(row.utf8.count, 400, row)
    }

    func testARepeatedFailureWarningAppearsOnlyAtTheThresholdAndSuggestsRecovery() throws {
        let s = AgentSession()
        s.startRemote { _ in }
        try s.send("fix it", from: .person)
        failTool(s, "f1")
        failTool(s, "f2")
        XCTAssertFalse(s.visibleTranscriptText().contains("consecutive tool failures"))

        failTool(s, "f3")
        let text = s.visibleTranscriptText()
        let warning = try XCTUnwrap(text.components(separatedBy: "\n").first {
            $0.contains("consecutive tool failures")
        })

        XCTAssertTrue(warning.hasPrefix("! "), warning)
        XCTAssertTrue(warning.contains("3"), warning)
        XCTAssertTrue(warning.contains("SyntaxError: Invalid or unexpected token"), warning)
        XCTAssertTrue(warning.lowercased().contains("interrupt") || warning.lowercased().contains("restart"), warning)
        XCTAssertLessThan(warning.utf8.count, 600, warning)

        passTool(s, "ok")
        XCTAssertFalse(s.visibleTranscriptText().contains("consecutive tool failures"))
    }

    func testToolFailuresDoNotChangeATaskBoundTurnsStatedVerdict() throws {
        let team = "health-verdict-\(UUID().uuidString)"
        let store = TeamDataStore.shared
        let task = try boardTask(team: team, instance: "inst-1")
        defer { store.clearResults(teamName: team); store.unregisterTeam(team) }
        var ends: [AgentSession.TurnEnd] = []
        let s = AgentSession()
        s.onTurnEnd = { final, end, taskId in
            ends.append(end)
            AutoReplyEmit.settleNativeTurn(
                teamName: team, agentName: "executor", agentInstanceId: "inst-1",
                final: final, taskId: taskId, store: .shared)
        }
        s.startRemote { _ in }

        try s.send("TASK_ID: \(task.id)\nrun the suite", from: .leader)
        failTool(s, "f1")
        failTool(s, "f2")
        failTool(s, "f3")
        s.ingestForTesting(assistantSaid("All set.\n\nSTATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a"))
        s.ingestForTesting(event(["type": "result", "stop_reason": "end_turn"]))

        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(ends.last?.verdict?.status, "DONE")
        XCTAssertEqual(store.getTask(teamName: team, taskId: task.id)?.status, "completed")
        XCTAssertEqual(health(s)["needs_attention"] as? Bool, true)
        XCTAssertEqual(health(s)["consecutive"] as? Int, 3)
        s.stop()
    }

    func testTheStatusDeadlineNeverFiresWhileATurnIsRunning() async throws {
        var lost: [String] = []
        let s = AgentSession(pendingTaskStatusDeadline: 0.05)
        s.onTaskCorrelationLost = { task, _ in lost.append(task) }
        s.startRemote { _ in }
        try s.send("TASK_ID: busy\nwork", from: .leader)
        s.ingestForTesting(resultSaying("background"))
        s.ingestForTesting(assistantSaid("the job finished, checking the output"))

        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(lost.isEmpty)
        XCTAssertTrue(s.isTurnInFlightForTesting)
    }

    // MARK: - Background work holds the deadline, up to a cap

    private func backgroundTasksChanged(_ ids: [String]) -> String {
        event(["type": "system", "subtype": "background_tasks_changed",
               "tasks": ids.map { ["task_id": $0, "run_id": "run-\($0)",
                                   "task_type": "local_bash", "description": "npm test"] }])
    }

    private func backgroundStarted(_ id: String) -> String {
        event(["type": "system", "subtype": "task_started", "task_id": id, "is_backgrounded": true])
    }

    private func backgroundFinished(_ id: String) -> [String] {
        [
            event(["type": "system", "subtype": "task_updated", "task_id": id,
                   "patch": ["status": "completed"]]),
            event(["type": "system", "subtype": "task_notification", "task_id": id,
                   "status": "completed", "output_file": "/tmp/\(id).out", "summary": "done"]),
            backgroundTasksChanged([]),
        ]
    }

    /// Dispatch, background a job inside the turn, end the turn without a
    /// verdict — the measured shape of the incident.
    private func backgroundedWorker(
        deadline: TimeInterval, cap: TimeInterval,
        lost: @escaping (String, AgentSession.TaskCorrelationLoss) -> Void
    ) throws -> AgentSession {
        let s = AgentSession(pendingTaskStatusDeadline: deadline, pendingTaskStatusCap: cap)
        s.onTaskCorrelationLost = lost
        s.startRemote { _ in }
        try s.send("TASK_ID: bg000001\nrun the suite", from: .leader)
        s.ingestForTesting(backgroundTasksChanged(["bygdymlig"]))
        s.ingestForTesting(backgroundStarted("bygdymlig"))
        s.ingestForTesting(resultSaying("The suite is running in the background."))
        return s
    }

    func testRunningBackgroundWorkHoldsTheDeadline() async throws {
        var lost: [String] = []
        let s = try backgroundedWorker(deadline: 0.05, cap: 5) { task, _ in lost.append(task) }

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(lost.isEmpty, "the worker is still waiting on its own job")
        XCTAssertEqual(s.pendingTaskIdForTesting, "bg000001")
    }

    func testTheDeadlineCountsFromWhenBackgroundWorkFinished() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = try backgroundedWorker(deadline: 0.5, cap: 5) { task, loss in lost.append((task, loss)) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(lost.isEmpty)

        for line in backgroundFinished("bygdymlig") { s.ingestForTesting(line) }
        let emptied = Date()
        s.ingestForTesting(event(["type": "system", "subtype": "init", "model": "claude"]))
        s.ingestForTesting(event(["type": "system", "subtype": "status"]))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(lost.isEmpty, "not before a full deadline after the job finished")

        let fired = await waitUntil { !lost.isEmpty }
        XCTAssertTrue(fired)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(emptied), 0.49)
        XCTAssertEqual(lost.map(\.0), ["bg000001"])
        XCTAssertEqual(lost.first?.1, .noStatusDeadline(0.5))
    }

    /// A server started in the background never finishes, so the hold ends
    /// at the cap with its own reason.
    func testBackgroundWorkThatNeverEndsIsCappedWithItsOwnReason() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let started = Date()
        let s = try backgroundedWorker(deadline: 0.05, cap: 1) { task, loss in lost.append((task, loss)) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(lost.isEmpty)

        let fired = await waitUntil { !lost.isEmpty }
        XCTAssertTrue(fired)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.99)
        XCTAssertEqual(lost.map(\.0), ["bg000001"])
        XCTAssertEqual(lost.first?.1, .noStatusWithBackgroundWork(1))
        XCTAssertEqual(lost.first?.1.reason,
                       "No explicit STATUS after 1s while background work was still running")
        XCTAssertEqual(AgentSession.TaskCorrelationLoss.noStatusWithBackgroundWork(60 * 60).reason,
                       "No explicit STATUS after 60 min while background work was still running")
        XCTAssertEqual(AgentSession.TaskCorrelationLoss.noStatusDeadline(10 * 60).reason,
                       "No explicit STATUS after 10 min without activity")

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(s.pendingTaskIdForTesting, "bg000001", "a late explicit STATUS can still close it")
    }

    /// A job in several long background steps: each step's own turn proves
    /// the worker is still there, so the cap counts from the latest one.
    func testATurnOnTheTaskRestartsTheBackgroundCap() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = try backgroundedWorker(deadline: 0.05, cap: 1) { task, loss in lost.append((task, loss)) }
        try? await Task.sleep(nanoseconds: 500_000_000)

        let stepEnded = Date()
        s.ingestForTesting(assistantSaid("Step one finished; starting step two in the background."))
        s.ingestForTesting(resultSaying("Step two is running in the background."))
        try? await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertTrue(lost.isEmpty, "the cap must not count from the first wait")

        let fired = await waitUntil { !lost.isEmpty }
        XCTAssertTrue(fired)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(stepEnded), 0.99)
        XCTAssertEqual(lost.first?.1, .noStatusWithBackgroundWork(1))
        withExtendedLifetime(s) {}
    }

    func testANewDispatchOrAnExplicitStatusStillEndsTheHold() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = try backgroundedWorker(deadline: 0.05, cap: 0.3) { task, loss in lost.append((task, loss)) }

        try s.send("TASK_ID: bg000002\nnext thing", from: .leader)
        XCTAssertEqual(lost.map(\.0), ["bg000001"])
        XCTAssertEqual(lost.first?.1, .superseded(by: "bg000002"))
        s.ingestForTesting(resultSaying("STATUS: DONE"))
        XCTAssertNil(s.pendingTaskIdForTesting)

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(lost.count, 1, "nothing is left to time out")
    }

    func testAnEndedSessionForgetsItsBackgroundWork() async throws {
        var lost: [(String, AgentSession.TaskCorrelationLoss)] = []
        let s = try backgroundedWorker(deadline: 0.05, cap: 5) { task, loss in lost.append((task, loss)) }
        s.stop()
        XCTAssertEqual(lost.map(\.0), ["bg000001"])

        s.startRemote { _ in }
        try s.send("TASK_ID: bg000003\nagain", from: .leader)
        s.ingestForTesting(resultSaying("no verdict"))

        let fired = await waitUntil(timeout: 1) { lost.count == 2 }
        XCTAssertTrue(fired, "the old process's job list must not hold the new session's deadline")
        XCTAssertEqual(lost.last?.0, "bg000003")
        XCTAssertEqual(lost.last?.1, .noStatusDeadline(0.05))
    }

    // MARK: - The instruction the agent is given

    /// The block exists for one reason, and its own comment in the CLI says
    /// so: the pane path cannot detect completion, so the agent is told to
    /// announce it by running a shell command. Held natively the turn
    /// announces its own end and the task is closed before the agent could run
    /// anything — measured, it ran the command anyway and got `no_active_task`
    /// back, a guaranteed-failing tool call on every turn.
    func testTheShellCommandDemandIsDroppedForANativeAgent() {
        let instruction = """
            Write about 150 words on tangerines.

            [REQUIRED FINAL STEP — you MUST run this shell command before stopping]
            ```
            tm-agent reply 'STATUS: DONE|BLOCKED|NEEDS_REVIEW
            FILES: <changed paths or none>

            <concise summary body>'
            ```
            Without running this shell command the leader cannot detect completion — the task hangs and wait times out.

            ## Task Capsule
            TASK_ID: e82188a0
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(instruction)

        XCTAssertFalse(cleaned.contains("tm-agent reply"),
                       "the command cannot succeed and its failure is noise")
        XCTAssertFalse(cleaned.contains("cannot detect completion"),
                       "and it is not true here")
        // What the header is for still matters — the verdict is the agent's
        // and nothing else can supply it — so the block is replaced, not cut.
        XCTAssertTrue(cleaned.contains("STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>"))
        XCTAssertTrue(cleaned.contains("FULL_REPORT:"))
        // Not `DONE|BLOCKED|NEEDS_REVIEW`: measured, codex read the alternation
        // bar as a field separator and packed the whole header onto one line.
        XCTAssertFalse(cleaned.contains("DONE|BLOCKED"),
                       "a bar meaning \"pick one\" gets read as \"separator\"")
        // Everything around it survives, including the capsule that names the
        // task the reply will close.
        XCTAssertTrue(cleaned.contains("Write about 150 words on tangerines."))
        XCTAssertTrue(cleaned.contains("TASK_ID: e82188a0"))
    }

    /// The capsule closes by repeating the demand, and its wording — "not by
    /// printing the header in your reply" — is now the exact opposite of what
    /// this path wants, since printing it is the only thing that is read.
    func testTheClosingReminderGoesToo() {
        let instruction = """
            [REQUIRED FINAL STEP — you MUST run this shell command before stopping]
            ```
            tm-agent reply 'STATUS: DONE'
            ```
            Without running this shell command the leader cannot detect completion.

            ## Task Capsule
            TASK_ID: e82188a0

            [REMINDER] Finish by actually running the `tm-agent reply '...'` shell command shown at the top — not by printing the header in your reply.
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(instruction)
        XCTAssertFalse(cleaned.contains("[REMINDER]"))
        XCTAssertFalse(cleaned.contains("tm-agent reply"))
        XCTAssertTrue(cleaned.contains("TASK_ID: e82188a0"))
        XCTAssertTrue(cleaned.contains("STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>"))
    }

    /// The runbook says the same thing in prose, and it reaches the agent in
    /// its very first turn — before any task exists. Same falsehood, different
    /// shape.
    func testTheRunbookProseIsCorrectedToo() {
        let initPrompt = """
            You are a team agent named "explorer".

            CRITICAL: When tasks complete you MUST invoke `tm-agent reply '<5-line header plus result>'` as a shell command. Printing the header text in your response is NOT enough — the leader cannot detect completion and the team stalls.
            Respond with "Agent explorer ready." to confirm.
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(initPrompt)
        XCTAssertFalse(cleaned.contains("tm-agent reply"))
        XCTAssertFalse(cleaned.contains("cannot detect completion"))
        // The requirement is real even though the shell command is not.
        XCTAssertTrue(cleaned.contains("STATUS/FILES/VERIFY/NEXT/FULL_REPORT"))
        XCTAssertTrue(cleaned.contains("Respond with \"Agent explorer ready.\""),
                      "everything else in the prompt survives")
        XCTAssertTrue(cleaned.contains("You are a team agent"))
    }

    /// The digest mandates the command in three more places. An agent told both
    /// "run it" and "do not run it" will do both — which is how the failing
    /// call got measured in the first place.
    func testNoLineIsLeftMandatingTheCommand() {
        let digest = """
            ## Runbook Digest
            5. When done: `tm-agent reply '<full result>'` — this auto-reports and completes your active task.
            - Finish with one `tm-agent reply '<5-line header plus concise result>'`; it auto-reports and completes your active task.
            Begin every `tm-agent reply` body with this 5-line header (use n/a when not applicable):
            STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(digest)
        for line in cleaned.components(separatedBy: "\n") {
            XCTAssertFalse(line.contains("tm-agent reply"), "still mandated: \(line)")
        }
        // What the header is and where it goes survives.
        XCTAssertTrue(cleaned.contains("Begin every reply with this 5-line header"))
        XCTAssertTrue(cleaned.contains("STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>"))
        XCTAssertTrue(cleaned.contains("## Runbook Digest"))
    }

    /// The runbook prints the alternation too, in its own fenced example.
    /// Correcting only the delegate template left the runbook still teaching
    /// the bar that codex read as a field separator.
    func testTheRunbooksOwnAlternationIsSpelledOutToo() {
        let digest = """
            Begin every reply with this 5-line header:
            ```
            STATUS: DONE|BLOCKED|NEEDS_REVIEW
            FILES: <changed paths or "none">
            ```
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(digest)
        XCTAssertFalse(cleaned.contains("DONE|BLOCKED"))
        XCTAssertTrue(cleaned.contains("STATUS: <DONE, BLOCKED, or NEEDS_REVIEW>"))
    }

    /// The CLI has three copies of this block and they do not agree word for
    /// word, so it is read by shape. This is the `broadcast` wording.
    func testEveryWordingOfTheBlockIsRecognised() {
        let broadcast = """
            do the thing

            [REQUIRED FINAL STEP — every recipient MUST run this shell command before stopping]
            ```
            tm-agent reply 'STATUS: DONE'
            ```
            Without running this shell command the leader cannot detect completion.

            tail
            """
        let cleaned = TeamOrchestrator.withoutTerminalProtocol(broadcast)
        XCTAssertFalse(cleaned.contains("tm-agent reply"))
        XCTAssertTrue(cleaned.contains("do the thing"))
        XCTAssertTrue(cleaned.contains("tail"))
    }

    /// A plain instruction is untouched — most turns never carry the block.
    func testAnInstructionWithoutTheBlockIsUnchanged() {
        let plain = "have a look at the build and tell me what broke"
        XCTAssertEqual(TeamOrchestrator.withoutTerminalProtocol(plain), plain)
    }

    /// A truncated block is left alone rather than half-removed. Cutting from
    /// a marker to the end of the text would take the task capsule with it.
    func testAnUnterminatedBlockIsLeftAlone() {
        let broken = """
            do the thing

            [REQUIRED FINAL STEP — you MUST run this shell command before stopping]
            ```
            tm-agent reply 'STATUS: DONE
            """
        XCTAssertEqual(TeamOrchestrator.withoutTerminalProtocol(broken), broken)
    }

    // MARK: - Which colour an agent gets

    /// It was the slot, not the agent: `colorList[agents.count % 6]`. So
    /// `reviewer` was blue in one team and yellow in the next, which makes a
    /// colour something to re-learn per team rather than something to
    /// recognise.
    func testARoleKeepsItsColourAcrossTeams() {
        let first = TeamOrchestrator.agentColor(forRole: "reviewer", taken: [])
        let second = TeamOrchestrator.agentColor(forRole: "reviewer", taken: [])
        XCTAssertEqual(first, second)
        // And it does not depend on who else is in the team, only on what is
        // already taken.
        XCTAssertEqual(TeamOrchestrator.agentColor(forRole: "explorer", taken: []),
                       TeamOrchestrator.agentColor(forRole: "explorer", taken: []))
    }

    func testDifferentRolesGetDifferentColoursWhereTheyCan() {
        var taken: Set<String> = []
        var seen: [String] = []
        for role in ["explorer", "executor", "reviewer", "planner", "tester", "writer"] {
            let colour = TeamOrchestrator.agentColor(forRole: role, taken: taken)
            taken.insert(colour)
            seen.append(colour)
        }
        XCTAssertEqual(Set(seen).count, 6, "six roles, six colours: \(seen)")
    }

    /// Six colours and more roles than that, so a colour already in use steps
    /// to the next free one — stability across teams for the common case,
    /// never a duplicate within one.
    func testATakenColourStepsAside() {
        let alone = TeamOrchestrator.agentColor(forRole: "reviewer", taken: [])
        let crowded = TeamOrchestrator.agentColor(forRole: "reviewer", taken: [alone])
        XCTAssertNotEqual(crowded, alone)
    }

    // MARK: - Incremental agent pane placement

    func testFirstAgentSplitsToTheRightOfLeader() {
        let leader = UUID()
        let placement = TeamOrchestrator.nextAgentSplitPlacement(
            leaderPanelId: leader,
            candidates: []
        )

        XCTAssertEqual(placement.panelId, leader)
        XCTAssertEqual(placement.orientation.rawValue, "horizontal")
    }

    func testLateAgentSplitsLargestPaneAlongItsLongestAxis() {
        let smaller = UUID()
        let largest = UUID()
        let placement = TeamOrchestrator.nextAgentSplitPlacement(
            leaderPanelId: UUID(),
            candidates: [
                .init(panelId: smaller, width: 300, height: 300),
                .init(panelId: largest, width: 420, height: 700),
            ]
        )

        XCTAssertEqual(placement.panelId, largest)
        XCTAssertEqual(placement.orientation.rawValue, "vertical")
    }

    func testWideAgentPaneSplitsSideBySide() {
        let wide = UUID()
        let placement = TeamOrchestrator.nextAgentSplitPlacement(
            leaderPanelId: UUID(),
            candidates: [
                .init(panelId: wide, width: 700, height: 350),
            ]
        )

        XCTAssertEqual(placement.panelId, wide)
        XCTAssertEqual(placement.orientation.rawValue, "horizontal")
    }

    func testEqualAreaPlacementKeepsTeamOrderStable() {
        let first = UUID()
        let second = UUID()
        let placement = TeamOrchestrator.nextAgentSplitPlacement(
            leaderPanelId: UUID(),
            candidates: [
                .init(panelId: first, width: 400, height: 300),
                .init(panelId: second, width: 300, height: 400),
            ]
        )

        XCTAssertEqual(placement.panelId, first)
    }

    /// Deliberately not per CLI. Which provider is behind a pane is already
    /// said twice — the chip and the mascot — and spending the colour on it too
    /// would leave two agents of the same role indistinguishable, which is the
    /// thing you actually need to tell apart.
    func testTheColourIsTheRolesNotTheProviders() {
        // Same role, same colour — whatever CLI happens to be behind it, since
        // the CLI is not an input here at all.
        XCTAssertEqual(TeamOrchestrator.agentColor(forRole: "reviewer", taken: []),
                       TeamOrchestrator.agentColor(forRole: "reviewer", taken: []))
        // Two roles can hash to the same colour — six colours, more roles —
        // and that is what the taken set is for. Asserting they differ with an
        // empty set was asserting the absence of collisions, which is not a
        // property this has or needs; `reviewer` and `explorer` both land on
        // green.
        var taken: Set<String> = []
        let first = TeamOrchestrator.agentColor(forRole: "reviewer", taken: taken)
        taken.insert(first)
        XCTAssertNotEqual(TeamOrchestrator.agentColor(forRole: "explorer", taken: taken),
                          first, "within one team they must differ")
    }

    // MARK: - The mascots

    /// They only read as one family if they line up, and a stray space is the
    /// easiest thing in the world to leave in.
    func testEveryMascotIsThreeRowsOfTheSameWidth() {
        for cli in ["claude", "codex", "kiro", "cursor", "agy", "gemini", "unknown"] {
            let rows = AgentPanelView.mascot(for: cli)
            XCTAssertEqual(rows.count, 3, cli)
            for row in rows {
                XCTAssertEqual(row.count, 9, "\(cli): \(row)")
            }
        }
    }

    /// Each CLI gets its own; a repeat would defeat the whole point of drawing
    /// them.
    func testNoTwoCliShareAMascot() {
        let clis = ["claude", "codex", "kiro", "cursor", "agy", "gemini"]
        let drawn = Set(clis.map { AgentPanelView.mascot(for: $0).joined() })
        XCTAssertEqual(drawn.count, clis.count)
    }

    /// Issue #770: every width change during a window resize re-measured,
    /// re-selected and redrew the whole mounted transcript. Opt-in because it
    /// reports wall-clock cost rather than asserting a machine-dependent bound.
    func testTranscriptResizeLayoutCostBenchmark() throws {
        guard ProcessInfo.processInfo.environment["TERMMESH_TRANSCRIPT_RESIZE_BENCH"] == "1" else {
            throw XCTSkip("set TERMMESH_TRANSCRIPT_RESIZE_BENCH=1 to measure transcript resize cost")
        }
        let paragraph = String(
            repeating: "The transcript wraps this sentence differently at every pane width. ",
            count: 6
        )
        for visible in [true, false] {
            let panel = AgentPanel(
                agentName: "bench", teamName: "bench", workingDirectory: "/tmp/bench",
                cli: "claude", color: "green"
            )
            for index in 0..<320 {
                panel.session.ingestForTesting(event(["type": "user", "message": ["content": [
                    ["type": "text", "text": "question \(index)"]]]]))
                panel.session.ingestForTesting(event(["type": "assistant", "message": ["content": [
                    ["type": "text", "text": "\(index). \(paragraph)\n\n- `code` and **bold** \(paragraph)"]]]]))
            }
            let host = NSHostingView(rootView: AgentPanelView(
                panel: panel,
                isFocused: visible,
                isVisibleInUI: visible,
                appearance: PanelAppearance(
                    dividerColor: .secondary,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                onFocus: {}
            ))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            // Ends short of where it started, so the deferred width that lands
            // after the burst is a real re-wrap rather than a no-op.
            let widths = Array(stride(from: 794, through: 500, by: -6))
                + Array(stride(from: 506, through: 698, by: 6))
            func elapsedMs(since start: UInt64) -> Double {
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            // Spinning the run loop each step lets main-queue width updates
            // land inside the step that caused them, as they would between
            // frames of a real drag.
            func step() {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            step()
            var samples: [Double] = []
            for width in widths {
                let start = DispatchTime.now().uptimeNanoseconds
                window.setContentSize(NSSize(width: CGFloat(width), height: 900))
                step()
                samples.append(elapsedMs(since: start))
            }
            // A deferred width lands after the burst. Count only the time the
            // run loop overran its 10 ms slices, which is the work it did.
            var settleMs = 0.0
            for _ in 0..<40 {
                let start = DispatchTime.now().uptimeNanoseconds
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                settleMs += max(0, elapsedMs(since: start) - 10)
            }
            let finalStart = DispatchTime.now().uptimeNanoseconds
            step()
            settleMs += elapsedMs(since: finalStart)
            window.close()
            let sorted = samples.sorted()
            print(String(
                format: "TRANSCRIPT_RESIZE_BENCH visible=%@ rows=%d widths=%d burst_total_ms=%.1f median_ms=%.2f p90_ms=%.2f max_ms=%.2f heavy_steps=%d settle_ms=%.1f applied_width=%.0f",
                visible ? "true" : "false", panel.session.rows.count, widths.count,
                samples.reduce(0, +), sorted[sorted.count / 2],
                sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0,
                samples.filter { $0 > 20 }.count, settleMs,
                panel.session.debugTranscriptWidth
            ))
        }
    }

    /// A drag as the app sees it: a new width every frame, and when a frame
    /// runs long the next one waits for it rather than being skipped. The
    /// burst benchmark above steps with no wall-clock gaps, so it cannot see a
    /// policy that mistakes a slow frame for the user pausing.
    func testTranscriptRealtimeDragBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TERMMESH_TRANSCRIPT_RESIZE_BENCH"] == "1" else {
            throw XCTSkip("set TERMMESH_TRANSCRIPT_RESIZE_BENCH=1 to measure transcript resize cost")
        }
        // A real transcript re-wraps for longer than this one; scale the text
        // until a single re-wrap outlasts `TranscriptWidthPolicy.quietInterval`.
        let repeats = Int(environment["TERMMESH_TRANSCRIPT_RESIZE_BENCH_REPEAT"] ?? "") ?? 6
        let paragraph = String(
            repeating: "The transcript wraps this sentence differently at every pane width. ",
            count: repeats
        )
        let panel = AgentPanel(
            agentName: "bench", teamName: "bench", workingDirectory: "/tmp/bench",
            cli: "claude", color: "green"
        )
        for index in 0..<320 {
            panel.session.ingestForTesting(event(["type": "user", "message": ["content": [
                ["type": "text", "text": "question \(index)"]]]]))
            panel.session.ingestForTesting(event(["type": "assistant", "message": ["content": [
                ["type": "text", "text": "\(index). \(paragraph)\n\n- `code` and **bold** \(paragraph)"]]]]))
        }
        let host = NSHostingView(rootView: AgentPanelView(
            panel: panel, isFocused: true, isVisibleInUI: true,
            appearance: PanelAppearance(
                dividerColor: .secondary,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            onFocus: {}
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func elapsedMs(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func frame() {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        frame()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        frame()
        let pointerHeld = environment["TERMMESH_TRANSCRIPT_RESIZE_BENCH_POINTER"] != "0"
        var held = pointerHeld
        let isPointerHeld = TranscriptWidthPolicy.isPointerHeld
        TranscriptWidthPolicy.isPointerHeld = { held }
        defer { TranscriptWidthPolicy.isPointerHeld = isPointerHeld }
        let appliesBefore = panel.session.debugTranscriptWidthApplies
        let frameInterval = 1.0 / 60
        let widths = Array(stride(from: 794, through: 500, by: -6))
        var samples: [Double] = []
        let dragStart = DispatchTime.now().uptimeNanoseconds
        for width in widths {
            let start = DispatchTime.now().uptimeNanoseconds
            window.setContentSize(NSSize(width: CGFloat(width), height: 900))
            frame()
            let remaining = frameInterval - elapsedMs(since: start) / 1000
            RunLoop.main.run(until: Date().addingTimeInterval(max(0, remaining)))
            frame()
            samples.append(elapsedMs(since: start))
        }
        let dragMs = elapsedMs(since: dragStart)
        let appliesDuringDrag = panel.session.debugTranscriptWidthApplies - appliesBefore
        held = false
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(TranscriptWidthPolicy.quietInterval))
            frame()
        }
        let sorted = samples.sorted()
        print(String(
            format: "TRANSCRIPT_REALTIME_DRAG_BENCH pointer_held=%@ repeat=%d rows=%d frames=%d drag_ms=%.0f median_ms=%.1f p90_ms=%.1f max_ms=%.1f applies_during_drag=%d applies_total=%d final_width=%.0f",
            pointerHeld ? "true" : "false", repeats, panel.session.rows.count, widths.count, dragMs,
            sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0,
            appliesDuringDrag, panel.session.debugTranscriptWidthApplies - appliesBefore,
            panel.session.debugTranscriptWidth
        ))
    }

    /// The deferred width is the one that has to land: a burst that ended
    /// with the transcript still wrapped at a width from mid-drag would read
    /// as fast and be wrong.
    func testTranscriptTakesTheLastWidthOfABurstAndAHiddenPaneWaitsUntilShown() {
        let panel = AgentPanel(
            agentName: "resize", teamName: "resize", workingDirectory: "/tmp/resize",
            cli: "claude", color: "green"
        )
        panel.session.ingestForTesting(event(["type": "assistant", "message": ["content": [
            ["type": "text", "text": "a short answer that wraps"]]]]))
        func view(visible: Bool) -> AgentPanelView {
            AgentPanelView(
                panel: panel, isFocused: false, isVisibleInUI: visible,
                appearance: PanelAppearance(
                    dividerColor: .secondary,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                onFocus: {}
            )
        }
        let host = NSHostingView(rootView: view(visible: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        // The policy reads the real mouse; a button held during the run
        // would turn every change here into a deferred one.
        let isPointerHeld = TranscriptWidthPolicy.isPointerHeld
        TranscriptWidthPolicy.isPointerHeld = { false }
        defer {
            TranscriptWidthPolicy.isPointerHeld = isPointerHeld
            window.close()
        }
        func settle() {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(TranscriptWidthPolicy.quietInterval))
            }
            host.layoutSubtreeIfNeeded()
        }
        func resize(to width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
        }

        settle()
        let initial = panel.session.debugTranscriptWidth
        XCTAssertGreaterThan(initial, 0)

        for width in stride(from: 790, through: 600, by: -10) { resize(to: CGFloat(width)) }
        settle()
        XCTAssertEqual(panel.session.debugTranscriptWidth, initial - 200, accuracy: 0.5,
                       "the width the burst ended on must be applied once it pauses")

        host.rootView = view(visible: false)
        settle()
        resize(to: 700)
        settle()
        XCTAssertEqual(panel.session.debugTranscriptWidth, initial - 200, accuracy: 0.5,
                       "a hidden pane keeps its width")

        host.rootView = view(visible: true)
        settle()
        XCTAssertEqual(panel.session.debugTranscriptWidth, initial - 100, accuracy: 0.5,
                       "showing the pane applies the width it was given while hidden")
    }

    /// v0.272.0 still re-wrapped every frame of a real drag: one re-wrap ran
    /// past the quiet interval, so the frame after it looked like a pause.
    /// Here the drag pauses for several intervals with the button still down,
    /// which is what a slow frame looks like to the timer.
    func testTranscriptWaitsForThePointerToBeReleasedBeforeTakingADraggedWidth() {
        let panel = AgentPanel(
            agentName: "drag", teamName: "drag", workingDirectory: "/tmp/drag",
            cli: "claude", color: "green"
        )
        panel.session.ingestForTesting(event(["type": "assistant", "message": ["content": [
            ["type": "text", "text": "a short answer that wraps"]]]]))
        let host = NSHostingView(rootView: AgentPanelView(
            panel: panel, isFocused: false, isVisibleInUI: true,
            appearance: PanelAppearance(
                dividerColor: .secondary,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            onFocus: {}
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        var held = false
        let isPointerHeld = TranscriptWidthPolicy.isPointerHeld
        TranscriptWidthPolicy.isPointerHeld = { held }
        defer {
            TranscriptWidthPolicy.isPointerHeld = isPointerHeld
            window.close()
        }
        func settle() {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(TranscriptWidthPolicy.quietInterval))
            }
            host.layoutSubtreeIfNeeded()
        }

        settle()
        let initial = panel.session.debugTranscriptWidth
        XCTAssertGreaterThan(initial, 0)

        held = true
        for width in stride(from: 790, through: 600, by: -10) {
            window.setContentSize(NSSize(width: CGFloat(width), height: 600))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
        }
        settle()
        XCTAssertEqual(panel.session.debugTranscriptWidth, initial, accuracy: 0.5,
                       "a stall with the button down is not the drag ending")

        held = false
        settle()
        XCTAssertEqual(panel.session.debugTranscriptWidth, initial - 200, accuracy: 0.5,
                       "releasing the pointer applies the width the drag ended on")
    }

    func testTranscriptWidthAppliesOnceAQuietIntervalPassesAndHoldsWhileHidden() {
        let quiet = TranscriptWidthPolicy.quietInterval
        func decide(_ applied: CGFloat?, _ offered: CGFloat, visible: Bool = true,
                    since: TimeInterval, pointerHeld: Bool = false) -> TranscriptWidthPolicy.Decision {
            TranscriptWidthPolicy.decide(
                applied: applied, offered: offered, visible: visible, sinceLastChange: since,
                pointerHeld: pointerHeld
            )
        }

        XCTAssertEqual(decide(nil, 600, visible: false, since: 0), .apply,
                       "a pane built hidden still needs a first width")
        XCTAssertEqual(decide(600, 590, since: quiet), .apply,
                       "a single change after a pause is not delayed")
        XCTAssertEqual(decide(600, 590, since: quiet / 2), .applyWhenQuiet,
                       "a change inside a drag waits for the drag to pause")
        XCTAssertEqual(decide(600, 590, since: quiet * 4, pointerHeld: true), .applyWhenQuiet,
                       "a frame held up by the last re-wrap is not the drag pausing")
        XCTAssertEqual(decide(nil, 600, since: 0, pointerHeld: true), .apply,
                       "a pane built mid-drag still needs a first width")
        XCTAssertEqual(decide(600, 590, visible: false, since: 10), .hold,
                       "a hidden pane is not re-wrapped until it is shown")
        XCTAssertEqual(decide(600, 600, since: 0), .hold)
        XCTAssertEqual(decide(600, 0, since: 10), .hold,
                       "a zero width from a view being torn down is not a layout")
        XCTAssertEqual(TranscriptWidthPolicy.contentWidth(viewport: 600, scrollerStyle: .overlay), 600)
        XCTAssertLessThan(TranscriptWidthPolicy.contentWidth(viewport: 600, scrollerStyle: .legacy), 600,
                          "an always-shown scroll bar is not width the transcript can wrap into")
    }

    /// A peer title includes its host, and the header used to make that whole
    /// string horizontally fixed. SwiftUI then reported the title's ideal
    /// width instead of the pane proposal, so Bonsplit clipped the oversized
    /// view and every transcript row wrapped outside the visible pane.
    func testLongRemoteAgentNameDoesNotSetPaneMinimumWidth() {
        let panel = AgentPanel(
            agentName: "reviewer @jinwoo-macbook-pro-sub-with-a-deliberately-long-host-name",
            teamName: "layout-test",
            workingDirectory: "/tmp/layout-test",
            cli: "claude",
            color: "green"
        )
        panel.runtimeOwnership = .peerOwned(hostName: "jinwoo-macbook-pro-sub")
        let view = AgentPanelView(
            panel: panel,
            isFocused: false,
            isVisibleInUI: true,
            appearance: PanelAppearance(
                dividerColor: .secondary,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            onFocus: {}
        )
        let proposed = NSSize(width: 320, height: 480)
        let fitted = NSHostingController(rootView: view).sizeThatFits(in: proposed)

        XCTAssertLessThanOrEqual(
            fitted.width,
            proposed.width,
            "the native pane must wrap to Bonsplit's width, not its title's ideal width"
        )
    }

    // MARK: - Which CLIs a picker may offer

    private func withNativePanel(_ on: Bool, _ body: () -> Void) {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: AgentPipeTransport.enabledKey)
        let native = d.object(forKey: AgentPipeTransport.nativePanelKey)
        d.set(on, forKey: AgentPipeTransport.enabledKey)
        d.set(on, forKey: AgentPipeTransport.nativePanelKey)
        body()
        d.set(enabled, forKey: AgentPipeTransport.enabledKey)
        d.set(native, forKey: AgentPipeTransport.nativePanelKey)
    }

    /// Not a policy choice: cursor and agy have no interactive UI to host and
    /// no stdin to type into, so a terminal pane has nothing to run. Offering
    /// them there would be offering a pane that opens empty.
    func testTurnPerProcessClisAreOfferedOnlyWhereTheyCanRun() {
        withNativePanel(false) {
            XCTAssertFalse(AgentRolePreset.supportedCLIs.contains("cursor"))
            XCTAssertFalse(AgentRolePreset.supportedCLIs.contains("agy"))
            XCTAssertTrue(AgentRolePreset.supportedCLIs.contains("claude"))
        }
        withNativePanel(true) {
            XCTAssertTrue(AgentRolePreset.supportedCLIs.contains("cursor"))
            XCTAssertTrue(AgentRolePreset.supportedCLIs.contains("agy"))
        }
    }

    /// Settings lists a path for every CLI the app knows, so one can be set
    /// before the option that makes it selectable is turned on.
    func testEveryKnownCliCanHaveAPathSetForIt() {
        for cli in ["claude", "kiro", "codex", "gemini", "cursor", "agy"] {
            XCTAssertTrue(AgentRolePreset.knownCLIs.contains(cli), cli)
        }
    }

    /// Neither knows claude's tiers, and a name a CLI does not recognise is
    /// worse than none — measured on codex, which took `--model sonnet`,
    /// accepted the turn, and said nothing. Empty means the flag is not passed.
    func testATierNameIsDroppedRatherThanHandedToACliThatCannotReadIt() {
        for cli in ["cursor", "agy"] {
            XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: cli, model: "sonnet"), "", cli)
            XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: cli, model: "haiku"), "", cli)
            // A real model name is the user's own and passes through.
            XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: cli, model: "gpt-5"), "gpt-5", cli)
        }
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "cursor"), "")
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "agy"), "")
    }

    /// The Claude CLI resolves its own tiers, so passing one through is what
    /// keeps an agent on the current model. Rewriting `opus` to a pinned id
    /// held every agent on the previous Opus after Opus 5 shipped — and because
    /// the pin still launched, nothing surfaced it.
    func testAClaudeTierIsLeftForTheCliToResolve() {
        for tier in ["sonnet", "opus", "fable", "haiku"] {
            XCTAssertEqual(TeamOrchestrator.resolveClaudeModelArg(tier), tier)
            XCTAssertFalse(
                AgentRolePreset.models(for: "claude").firstIndex(of: tier) == nil,
                "\(tier) must be offered by the picker"
            )
        }
        // No pinned id anywhere in what the picker offers — a version written
        // down here is one that has to be edited on every model release.
        for model in AgentRolePreset.models(for: "claude") {
            XCTAssertFalse(model.hasPrefix("claude-"), model)
        }
        // Stored before the tier list settled. It asked for the 1M window, so
        // it upgrades to the 1M alias rather than to the bare tier — the two
        // are different models to the CLI.
        XCTAssertEqual(TeamOrchestrator.resolveClaudeModelArg("opus-1m"), "opus[1m]")
        XCTAssertEqual(AgentRolePreset.normalizeModel("opus-1m", for: "claude"), "opus[1m]")
    }

    /// `opus` and `opus[1m]` are separate entries in the CLI's alias list, and
    /// a bare tier gets the standard context window. Offering only the tiers
    /// left "Opus 5 (1M context)" — which the CLI's own picker lists —
    /// unreachable from an agent pane or from the leader.
    func testTheOneMillionContextAliasesAreOfferedAndPassedThrough() {
        let models = AgentRolePreset.models(for: "claude")
        for alias in ["sonnet[1m]", "opus[1m]", "fable[1m]"] {
            XCTAssertTrue(models.contains(alias), "\(alias) must be offered by the picker")
            // Passed to the CLI as itself; stripping the suffix silently
            // downgrades the window the user asked for.
            XCTAssertEqual(TeamOrchestrator.resolveClaudeModelArg(alias), alias)
            XCTAssertEqual(AgentRolePreset.normalizeModel(alias, for: "claude"), alias)
        }
        // haiku has no 1M form in the CLI's alias list.
        XCTAssertFalse(models.contains("haiku[1m]"))
        // The picker labels them apart from the plain tiers.
        XCTAssertEqual(
            AgentRolePreset.modelDisplayLabel("opus[1m]", for: "claude"),
            "Opus 5 (1M context)"
        )
        XCTAssertNotEqual(
            AgentRolePreset.modelDisplayLabel("opus[1m]", for: "claude"),
            AgentRolePreset.modelDisplayLabel("opus", for: "claude")
        )
    }

    /// Codex takes exact ids, so the list has to match its own catalog —
    /// including the two entries in that catalog it will not run from a
    /// `--model` flag.
    func testCodexIsOfferedOnlyModelsItStillRuns() {
        let models = AgentRolePreset.models(for: "codex")
        XCTAssertTrue(models.contains("gpt-5.6-sol"))
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "codex"), "gpt-5.6-sol")
        // `supported_in_api: false` and `visibility: hide` respectively.
        XCTAssertFalse(models.contains("gpt-5.3-codex-spark"))
        XCTAssertFalse(models.contains("codex-auto-review"))
        // Gone from the catalog entirely.
        for retired in ["gpt-5.3-codex", "gpt-5.2-codex", "gpt-5.2",
                        "gpt-5.1-codex-max", "gpt-5.1-codex-mini"] {
            XCTAssertFalse(models.contains(retired), retired)
        }
    }

    /// kiro takes exact ids, so a tier only reaches the right model if this
    /// side names it — there is no family for the CLI to resolve.
    func testAKiroTierNamesAModelKiroLists() {
        let listed = AgentRolePreset.models(for: "kiro")
        for id in ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4.5", "auto"] {
            XCTAssertTrue(listed.contains(id), id)
        }
        // fable is absent because kiro does not carry it — offering a tier the
        // CLI has no model for is a launch that fails at the flag.
        XCTAssertFalse(listed.contains("fable"))
    }

    /// cursor and agy spell the reasoning level into the id rather than taking
    /// a separate flag, so every entry has to name one.
    func testTheIdBasedCliesAreOfferedNamesTheyPublish() {
        let cursor = AgentRolePreset.models(for: "cursor")
        XCTAssertTrue(cursor.contains("claude-opus-5-thinking-high"))
        XCTAssertTrue(cursor.contains("claude-fable-5-thinking-high"))
        XCTAssertTrue(cursor.contains("auto"))
        // Neither was ever in cursor's list — `gpt-5-mini` and
        // `claude-4-sonnet-thinking` are the names it actually publishes.
        XCTAssertFalse(cursor.contains("gpt-5"))
        XCTAssertFalse(cursor.contains("sonnet-4-thinking"))

        let agy = AgentRolePreset.models(for: "agy")
        XCTAssertTrue(agy.contains("gemini-3.1-pro-high"))
        XCTAssertFalse(agy.isEmpty, "agy publishes a list now — empty hid it")

        // Both still default to not passing the flag at all, which is what was
        // measured working; the list is for picking, not for a default.
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "cursor"), "")
        XCTAssertEqual(AgentRolePreset.defaultModel(for: "agy"), "")
        // And a claude tier still never reaches either.
        for cli in ["cursor", "agy"] {
            XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: cli, model: "opus"), "", cli)
        }
    }

    // MARK: - The model a bridged CLI will take

    /// Team models are stored as claude's tiers, because that is what the
    /// picker offers for every CLI. Measured: codex took `--model sonnet`,
    /// accepted the turn, and ended it having said nothing — the empty-turn
    /// guard caught it, but the cause was here.
    func testATierNameIsTranslatedBeforeItReachesCodex() {
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "sonnet"),
                       "gpt-5.6-sol")
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "haiku"),
                       "gpt-5.6-sol")
        // A name the user typed themselves is theirs, not a tier to remap.
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "codex", model: "gpt-5.6-luna"),
                       "gpt-5.6-luna")
    }

    /// Kiro's picker offers the same tier names and its CLI takes them.
    func testACliThatTakesTierNamesIsLeftAlone() {
        XCTAssertEqual(TeamOrchestrator.bridgeModelArg(cli: "kiro", model: "sonnet"),
                       "sonnet")
    }

    // MARK: - The wire

    func testATurnGoesOutAsOneLineOfNdjson() throws {
        let data = try AgentSession.encode(text: "line one\nline two")
        XCTAssertEqual(data.last, 0x0A)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "user")
        // Newlines survive. The terminal path had to flatten instructions so a
        // TUI composer would not submit on the first one — an instruction
        // reshaped to survive its own delivery.
        XCTAssertEqual((obj["message"] as? [String: Any])?["content"] as? String,
                       "line one\nline two")
    }

    /// Nothing in the arguments assumes a terminal: no shell, no FIFO, no
    /// `exec` wrapper — the things the pipe transport needed only because its
    /// host was one.
    func testTheLaunchNeedsNoTerminal() {
        let launch = AgentSession.claudeLaunch(
            claudePath: "/usr/local/bin/claude", model: "sonnet",
            instructions: "be brief", extraArgs: [], workingDirectory: "/tmp"
        )
        XCTAssertEqual(launch.executable, "/usr/local/bin/claude")
        XCTAssertTrue(launch.arguments.contains("--replay-user-messages"),
                      "the receipt is what makes delivery verifiable")
        XCTAssertTrue(launch.arguments.contains("--input-format"))
        for shellish in ["mkfifo", "exec", "-c", "&&", "|"] {
            XCTAssertFalse(launch.arguments.contains(shellish),
                           "\(shellish) belongs to a terminal host")
        }
    }

    /// A long session is a memory leak with a scrollbar.
    func testTheTranscriptIsBounded() {
        let s = AgentSession()
        for i in 0..<2_100 {
            s.ingestForTesting(event(["type": "assistant",
                                      "message": ["content": [["type": "text", "text": "\(i)"]]]]))
        }
        XCTAssertLessThanOrEqual(s.entries.count, 2_000)
        guard case .answered(_, let last) = s.entries.last else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(last, "2099", "the newest must survive, not the oldest")
    }

    /// A late result does not land on somebody else's tool row.
    ///
    /// `openTools` holds absolute indices into `entries`, so trimming from the
    /// front moves every row an equal number of places earlier. A stale index
    /// still points *somewhere*, and `closeTool`'s only guard is that the row
    /// it finds is a tool — so when the rows are tools, as they are during a
    /// long run, the result is written into an unrelated call with nothing to
    /// reject it. Every row here is a tool for exactly that reason: it is what
    /// makes the mistake silent rather than caught.
    func testAToolResultDoesNotLandOnAnotherRowAfterATrim() throws {
        let s = AgentSession()
        s.ingestForTesting(event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t1", "name": "Read",
             "input": ["file_path": "/first"]]]]]))
        for i in 0..<2_100 {
            s.ingestForTesting(event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "later-\(i)", "name": "Read",
                 "input": ["file_path": "/later/\(i)"]]]]]))
        }
        s.ingestForTesting(event(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "t1 output"]]]]))

        XCTAssertLessThanOrEqual(s.entries.count, 2_000)
        let misplaced = s.entries.contains { entry in
            guard case .tool(_, let call) = entry else { return false }
            return call.result == "t1 output" && call.headline != "/first"
        }
        XCTAssertFalse(misplaced, "a trimmed-away call's result must not be written into another row")
    }

    // MARK: - A change is a diff

    private func change(_ tool: String, _ input: [String: Any]) -> AgentDiff.Change? {
        AgentDiff.change(tool: tool, input: input)
    }

    private func edit(_ old: String, _ new: String,
                      replaceAll: Bool = false) -> AgentDiff.Change? {
        change("Edit", ["file_path": "/repo/a.swift", "old_string": old,
                        "new_string": new, "replace_all": replaceAll])
    }

    private func texts(_ change: AgentDiff.Change) -> [String] {
        change.lines.compactMap { line in
            switch line {
            case .added(_, let text): return "+" + text
            case .removed(_, let text): return "-" + text
            case .context(_, _, let text): return " " + text
            case .gap, .site: return nil
            }
        }
    }

    func testAnEditCarriesBothSidesOfWhatItChanged() throws {
        let change = try XCTUnwrap(edit("one\ntwo\n", "one\nTWO\n"))

        XCTAssertEqual(change.path, "/repo/a.swift")
        XCTAssertEqual(change.kind, .edit)
        XCTAssertEqual(texts(change), [" one", "-two", "+TWO"])
    }

    /// Painting the whole of `old_string` red and the whole of `new_string`
    /// green is wrong in the ordinary case, not the rare one: it reports a
    /// five-line change where one line moved, and hands the reader the job of
    /// finding it.
    func testOnlyTheLinesThatMovedAreCounted() throws {
        let old = "a\nb\nc\nd\ne\n"
        let new = "a\nb\nCHANGED\nd\ne\n"

        let change = try XCTUnwrap(edit(old, new))

        XCTAssertEqual(change.added, 1)
        XCTAssertEqual(change.removed, 1)
    }

    func testAWriteIsAllAddition() throws {
        let change = try XCTUnwrap(
            self.change("Write", ["file_path": "/repo/new.swift",
                                  "content": "one\ntwo\nthree\n"]))

        XCTAssertEqual(change.added, 3)
        XCTAssertEqual(change.removed, 0)
        XCTAssertEqual(change.kind, .write(created: nil))
    }

    /// Nearly every file ends in a newline, and splitting on "\n" alone gives
    /// it one line more than it has.
    func testATrailingNewlineDoesNotGainAPhantomLine() throws {
        let change = try XCTUnwrap(
            self.change("Write", ["file_path": "/repo/a.swift", "content": "a\nb\n"]))

        XCTAssertEqual(change.added, 2)
    }

    func testCrlfDoesNotLeaveACarriageReturnInTheDiff() throws {
        let change = try XCTUnwrap(edit("a\r\nb\r\n", "a\r\nB\r\n"))

        XCTAssertEqual(texts(change), [" a", "-b", "+B"])
    }

    func testMultiEditIsOneRowWithEverySiteInIt() throws {
        let change = try XCTUnwrap(self.change("MultiEdit", [
            "file_path": "/repo/a.swift",
            "edits": [["old_string": "one\n", "new_string": "ONE\n"],
                      ["old_string": "two\n", "new_string": "TWO\n"]]]))

        XCTAssertEqual(change.kind, .multiEdit(sites: 2))
        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 2)
        XCTAssertTrue(change.lines.contains(.site(1)))
    }

    /// Once the per-call budget trips, walking a diff on the rest of the
    /// edits is what the budget forbids — but counting their raw sizes is
    /// not, so a bailout row must still add every edit still to come rather
    /// than stopping at the one that tripped it.
    func testMultiEditBailoutStillCountsEveryRemainingEdit() throws {
        let big = (0..<3000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let bigChanged = (0..<3000).map { "changed \($0)" }.joined(separator: "\n") + "\n"

        let change = try XCTUnwrap(self.change("MultiEdit", [
            "file_path": "/repo/a.swift",
            "edits": [["old_string": big, "new_string": bigChanged],
                      ["old_string": "two\n", "new_string": "TWO\n"]]]))

        XCTAssertEqual(change.kind, .multiEdit(sites: 2))
        XCTAssertEqual(change.added, 3001)
        XCTAssertEqual(change.removed, 3001)
        XCTAssertTrue(change.lines.isEmpty)
        XCTAssertGreaterThan(change.elided, 0)
    }

    /// Applied everywhere, any single line number is a fiction — and so is the
    /// total, which is the per-site count times a number nobody reported.
    func testReplaceAllRefusesToClaimALineNumber() throws {
        let change = try XCTUnwrap(edit("x\n", "y\n", replaceAll: true))

        XCTAssertTrue(change.everywhere)
        for line in change.lines {
            switch line {
            case .added(let new, _): XCTAssertNil(new)
            case .removed(let old, _): XCTAssertNil(old)
            case .context(let old, let new, _):
                XCTAssertNil(old)
                XCTAssertNil(new)
            case .gap, .site: break
            }
        }
    }

    func testAToolThatEditsNothingCarriesNoChange() {
        XCTAssertNil(change("Bash", ["command": "ls -l"]))
        XCTAssertNil(change("Read", ["file_path": "/repo/a.swift"]))
        XCTAssertNil(change("Grep", ["pattern": "foo", "path": "/repo"]))
    }

    func testAnEditThatChangedNothingIsNotDrawnAsADiff() {
        XCTAssertNil(edit("same\n", "same\n"))
    }

    /// The body is cut; the counts are not. A clipped diff that also under-
    /// reports its size is worse than no diff, because it looks complete.
    func testAHugeDiffIsCutButItsCountIsNot() throws {
        let content = (0..<5000).map { "line \($0)" }.joined(separator: "\n") + "\n"

        let change = try XCTUnwrap(
            self.change("Write", ["file_path": "/repo/big.txt", "content": content]))

        XCTAssertEqual(change.added, 5000)
        XCTAssertLessThanOrEqual(change.lines.count, AgentDiff.maxLines)
        XCTAssertEqual(change.lines.count + change.elided, 5000)
    }

    func testAVeryLongLineIsCutAtItsEnd() throws {
        let long = String(repeating: "x", count: 50_000)

        let change = try XCTUnwrap(
            self.change("Write", ["file_path": "/repo/min.js", "content": long + "\n"]))

        guard case .added(_, let text) = try XCTUnwrap(change.lines.first) else {
            return XCTFail("expected an added line")
        }
        XCTAssertEqual(text.count, AgentDiff.maxLineLength)
    }

    func testAUnifiedDiffFromTheBridgeKeepsItsLineNumbers() throws {
        let patch = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -241,3 +241,4 @@ func peerRow
         before
        -let label = host.name
        +let label = host.displayName
        +let badge = "●"
        """

        let change = try XCTUnwrap(self.change("edit", [
            "file_path": "/repo/Sources/Foo.swift", "kind": "update",
            "unified_diff": patch]))

        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 1)
        guard case .context(let old, let new, _) = try XCTUnwrap(change.lines.first) else {
            return XCTFail("expected the hunk to open on context")
        }
        XCTAssertEqual(old, 241)
        XCTAssertEqual(new, 241)
    }

    /// A hunk header is a claim by a subprocess, not a measurement. Reading it
    /// as one is how a printed number becomes an allocation.
    func testAHunkHeaderIsNotTrusted() throws {
        let patch = "@@ -1,99999999 +1,99999999 @@\n-a\n+b\n"

        let change = try XCTUnwrap(self.change("edit", [
            "file_path": "/repo/a.swift", "unified_diff": patch]))

        XCTAssertEqual(change.lines.count, 2)
        XCTAssertEqual(change.added, 1)
    }

    func testAUnifiedDiffWithoutAHunkHeaderIsRefused() {
        XCTAssertNil(change("edit", ["file_path": "/repo/a.swift",
                                     "unified_diff": "not a patch at all\n"]))
        XCTAssertNil(change("edit", ["file_path": "/repo/a.swift",
                                     "unified_diff": "+orphan line\n"]))
    }

    func testADeleteFromTheBridgeIsNamedAsOne() throws {
        let change = try XCTUnwrap(self.change("delete", [
            "file_path": "/repo/gone.swift", "kind": "delete",
            "unified_diff": "@@ -1,2 +0,0 @@\n-one\n-two\n"]))

        XCTAssertEqual(change.kind, .delete)
        XCTAssertEqual(change.removed, 2)
        XCTAssertEqual(change.added, 0)
    }

    /// The contract between the bridge and this side: the same edit described
    /// either way has to come out saying the same thing happened.
    func testTheBridgeShapeAndTheClaudeShapeAgree() throws {
        let claude = try XCTUnwrap(edit("one\ntwo\nthree\n", "one\nTWO\nthree\n"))
        let bridged = try XCTUnwrap(self.change("edit", [
            "file_path": "/repo/a.swift",
            "unified_diff": "@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"]))

        XCTAssertEqual(claude.added, bridged.added)
        XCTAssertEqual(claude.removed, bridged.removed)
        XCTAssertEqual(texts(claude), texts(bridged))
    }

    func testAPathIsShownRelativeToWhereTheAgentIsWorking() {
        XCTAssertEqual(AgentDiff.short("/repo/Sources/A.swift", relativeTo: "/repo"),
                       "Sources/A.swift")
        XCTAssertEqual(AgentDiff.short("/elsewhere/A.swift", relativeTo: "/repo"),
                       "/elsewhere/A.swift")
        XCTAssertEqual(AgentDiff.short("/repo/A.swift", relativeTo: ""), "/repo/A.swift")
    }

    /// The row exists as soon as the call does. Waiting for the result meant a
    /// long edit showed nothing at all while it was being made.
    func testADiffIsVisibleBeforeTheToolHasFinished() throws {
        let s = session([event(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t1", "name": "Edit",
             "input": ["file_path": "/repo/a.swift",
                       "old_string": "a\n", "new_string": "b\n"]]]]])])

        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool row")
        }
        XCTAssertTrue(call.isRunning)
        XCTAssertEqual(call.change?.added, 1)
        XCTAssertTrue(call.canExpand)
    }

    func testAWriteThatOverwroteSaysSo() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Write",
                 "input": ["file_path": "/repo/a.swift", "content": "one\n"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "The file /repo/a.swift has been updated successfully."]]]]),
        ])

        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool row")
        }
        XCTAssertEqual(call.change?.kind, .write(created: false))
    }

    func testAWriteThatCreatedSaysSo() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Write",
                 "input": ["file_path": "/repo/a.swift", "content": "one\n"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "File created successfully at: /repo/a.swift"]]]]),
        ])

        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool row")
        }
        XCTAssertEqual(call.change?.kind, .write(created: true))
    }

    /// A turn that ends with a call still open closes it with an empty result,
    /// and testing that alone took the disclosure control off rows holding a
    /// whole diff.
    func testAnEditRowStillOffersItsBodyWhenTheResultIsEmpty() throws {
        let s = session([
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Edit",
                 "input": ["file_path": "/repo/a.swift",
                           "old_string": "a\n", "new_string": "b\n"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": ""]]]]),
        ])

        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected a tool row")
        }
        XCTAssertFalse(call.isRunning)
        XCTAssertTrue(call.canExpand)
        XCTAssertNotNil(call.change)
    }

    func testACallWithNeitherDiffNorResultOffersNothing() {
        let call = AgentSession.ToolCall(name: "Bash", headline: "ls", result: "")

        XCTAssertFalse(call.canExpand)
    }

    // MARK: - A session over the peer wire
    //
    // A remote agent surface has no local Process: the peer daemon owns the
    // bridge, `PtyData` payloads arrive as raw bytes for `consume(_:)`, and
    // outgoing turns leave through the sink `startRemote` installed —
    // `PeerRelaySession.sendRemoteKeys` carries each line as `Input.keys`.

    /// The whole NDJSON vocabulary through the remote entry point: what the
    /// local pipe hands `apply`, the peer relay hands `consume(_:)`.
    /// `consume` decodes off-main and applies coalesced batches on the main
    /// queue, so the assertions wait for the batch to land — same contract
    /// the local pipe path has.
    func testARemoteSessionConsumesTheStreamAndEndsItsTurn() async throws {
        var ended: [(String, AgentSession.TurnEnd)] = []
        let s = AgentSession()
        s.onTurnEnd = { text, end, _ in ended.append((text, end)) }
        s.startRemote { _ in }
        XCTAssertTrue(s.isRunning, "a remote session runs without any Process")

        let wire = [
            event(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "cargo build"]]]]]),
            event(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1",
                 "content": "ok", "is_error": false]]]]),
            blockStart(0, "text"), delta(0, "answer over the wire"), blockStop(0),
            event(["type": "result", "stop_reason": "end_turn",
                   "result": "answer over the wire"]),
        ].map { $0 + "\n" }.joined()
        s.consume(Data(wire.utf8))

        let turnEnded = await waitUntil { ended.count == 1 }
        XCTAssertTrue(turnEnded, "the batched apply must reach the main actor")
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.0, "answer over the wire")
        guard case .tool(_, let call) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected the tool row")
        }
        XCTAssertEqual(call.result, "ok")
        XCTAssertTrue(s.entries.contains {
            if case .answered(_, let text) = $0 { return text == "answer over the wire" }
            return false
        })
    }

    /// The completion path a remote pane uses: no `.events` file and no
    /// polling tick — the turn's final text goes through `onTurnEnd`, and the
    /// same static header parser the file watcher uses reads the verdict.
    func testARemoteTurnEndFeedsTheStaticHeaderParserWithoutAnyFilePolling() async throws {
        var reported: String?
        let s = AgentSession()
        s.onTurnEnd = { text, _, _ in reported = text }
        s.startRemote { _ in }

        s.consume(Data((event([
            "type": "result", "stop_reason": "end_turn",
            "result": "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a",
        ]) + "\n").utf8))

        let turnEnded = await waitUntil { reported != nil }
        XCTAssertTrue(turnEnded)
        let header = AgentPipeCompletion.headerEvent(from: try XCTUnwrap(reported))
        XCTAssertEqual(header.status, "DONE")
    }

    /// The wire guarantees line boundaries only for lines under 64KiB; a
    /// bigger line arrives split mid-line across several `PtyData` chunks.
    /// The decoder must reassemble it into one event.
    func testAnOversizedLineSplitAcrossChunksIsReassembled() async throws {
        let s = AgentSession()
        s.startRemote { _ in }
        let big = String(repeating: "x", count: 100_000)
        let bytes = Data((event(["type": "assistant", "message": ["content": [
            ["type": "text", "text": big]]]]) + "\n").utf8)
        XCTAssertGreaterThan(bytes.count, 64 * 1024,
                             "the fixture must exceed the line-boundary guarantee")

        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 64 * 1024, bytes.count)
            s.consume(bytes.subdata(in: offset..<end))
            if end < bytes.count {
                // Trivially true while the pipeline is still decoding, but
                // a partial line can never produce an event however the
                // timing falls — the decoder holds it whole.
                XCTAssertTrue(s.entries.isEmpty, "half a line is not an event")
            }
            offset = end
        }

        let reassembled = await waitUntil { !s.entries.isEmpty }
        XCTAssertTrue(reassembled)
        guard case .answered(_, let text) = try XCTUnwrap(s.entries.first) else {
            return XCTFail("expected the reassembled answer")
        }
        XCTAssertEqual(text, big)
    }

    func testMissingAPIKeyFailureNamesTheRemoteAgentEnvRecoveryPath() {
        let detail = AgentSession.failureDetail(
            final: "AI_MESH_API_KEY is not set",
            alreadyShown: "",
            stop: "error"
        )
        XCTAssertEqual(
            detail,
            "AI_MESH_API_KEY is not set\n"
                + "Set it in ~/.config/term-mesh/agent-env on the agent host, then restart this agent."
        )
    }

    func testOrdinaryProviderFailureDoesNotInventAnEnvironmentFix() {
        XCTAssertEqual(
            AgentSession.failureDetail(
                final: "provider request timed out",
                alreadyShown: "",
                stop: "error"
            ),
            "provider request timed out"
        )
    }

    /// The bridge's stdout carries `[bridge] …` diagnostics between events,
    /// and a relay chunk can carry bytes that are not UTF-8 at all. Neither
    /// may derail the events around them.
    func testBridgeNoiseAndNonUtf8BytesDoNotDerailTheStream() async {
        let s = AgentSession()
        s.startRemote { _ in }
        var wire = Data("[bridge] codex handshake ok\n".utf8)
        wire.append(Data([0xFF, 0xFE, 0x80, 0x0A]))  // not UTF-8, then newline
        wire.append(Data((event(["type": "assistant", "message": ["content": [
            ["type": "text", "text": "still parsing"]]]]) + "\n").utf8))

        s.consume(wire)

        let landed = await waitUntil { s.entries.count >= 2 }
        XCTAssertTrue(landed, "the batch must reach the main actor")
        XCTAssertTrue(s.entries.contains {
            if case .notice(_, let text) = $0 { return text.contains("[bridge]") }
            return false
        }, "the diagnostic is shown as a notice")
        XCTAssertTrue(s.entries.contains {
            if case .answered(_, let text) = $0 { return text == "still parsing" }
            return false
        }, "the event after the garbage still lands")
    }

    /// A turn goes to the sink exactly as it would go to stdin: one NDJSON
    /// line, newline included — the relay carries it verbatim as `Input.keys`.
    func testASentTurnReachesTheSinkAsOneNdjsonLine() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.startRemote { sink.record($0) }

        try s.send("fix the build", from: .person)

        let delivered = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(delivered)
        let payload = try XCTUnwrap(sink.all.first)
        XCTAssertEqual(payload.last, 0x0A, "the newline travels with the line")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: payload.dropLast()) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "fix the build")
    }

    /// Interrupt travels the same wire: claude's `control_request` on the
    /// session's own stdin stream — remote only relocates the stdin.
    func testInterruptReachesTheSinkAsAControlRequest() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.startRemote(interruptible: true) { sink.record($0) }
        try s.send("long task", from: .person)  // opens the turn

        s.interrupt()

        let delivered = await waitUntil { sink.all.count == 2 }
        XCTAssertTrue(delivered)
        let payload = try XCTUnwrap(sink.all.last)
        XCTAssertEqual(payload.last, 0x0A)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: payload.dropLast()) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "control_request")
        XCTAssertEqual((object["request"] as? [String: Any])?["subtype"] as? String,
                       "interrupt")
    }

    /// Leader serialisation survives the move: a second task queued behind a
    /// remote turn is written to the sink only once the first turn's `result`
    /// arrives — one instruction, one turn, one result, same as local.
    func testAQueuedLeaderTurnDrainsThroughTheSinkAfterResult() async throws {
        let sink = RemoteSinkRecorder()
        let s = AgentSession()
        s.startRemote { sink.record($0) }

        try s.send("TASK_ID: aaaa1111\nfirst", from: .leader)
        try s.send("TASK_ID: bbbb2222\nsecond", from: .leader)

        var delivered = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(delivered, "the second turn must wait for the first result")
        XCTAssertEqual(sink.all.count, 1)

        s.consume(Data((event(["type": "result", "stop_reason": "end_turn",
                               "result": "first done"]) + "\n").utf8))

        delivered = await waitUntil { sink.all.count == 2 }
        XCTAssertTrue(delivered)
        let second = try XCTUnwrap(sink.all.last)
        XCTAssertTrue(String(data: second, encoding: .utf8)?
            .contains("bbbb2222") == true)
    }

    /// Stopping a remote session ends the turn in flight — its task must not
    /// sit `in_progress` for a pane that is gone — and resets the line
    /// decoder, so a session restarted on the same model does not glue a
    /// stale partial line onto the new stream. (A replay from seq 0 still
    /// requires a new `AgentSession`: `consume` is not idempotent.)
    func testStoppingARemoteSessionEndsTheTurnAndResetsTheDecoder() async throws {
        var stops: [String] = []
        let s = AgentSession()
        s.onTurnEnd = { _, end, _ in stops.append(end.stop) }
        s.startRemote { _ in }
        try s.send("do the thing", from: .person)
        // Half a line sits in the decoder when the session stops.
        s.consume(Data("{\"type\":\"assistant".utf8))

        s.stop()

        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(stops, ["session_stopped"])

        s.startRemote { _ in }
        XCTAssertTrue(s.isRunning, "a stopped remote session can start again")
        s.consume(Data((event(["type": "assistant", "message": ["content": [
            ["type": "text", "text": "fresh stream"]]]]) + "\n").utf8))
        let fresh = await waitUntil {
            s.entries.contains {
                if case .answered(_, let text) = $0 { return text == "fresh stream" }
                return false
            }
        }
        XCTAssertTrue(fresh, "the stale half-line must not corrupt the fresh stream")
    }

    func testSurfaceExitFinishesRemoteTurnAsFailureAndClearsRunningState() async throws {
        var completions: [(String, AgentSession.TurnEnd)] = []
        let s = AgentSession()
        s.onTurnEnd = { text, end, _ in completions.append((text, end)) }
        s.startRemote { _ in }
        try s.send("TASK_ID: deadbeef\nfinish the review", from: .leader)

        await s.finishRemoteSurfaceExited(exitCode: 0, signal: 15, reason: "signaled")

        XCTAssertFalse(s.isRunning)
        XCTAssertFalse(s.isThinking)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.1.stop, "process_exited")
        XCTAssertTrue(completions.first?.1.failed == true)
        XCTAssertTrue(s.entries.contains {
            if case .notice(_, let text) = $0 { return text.contains("signal 15") }
            return false
        })
    }

    func testSurfaceExitDrainsFinalResultBeforeTearingDownRemotePipeline() async throws {
        var completions: [(String, AgentSession.TurnEnd)] = []
        let s = AgentSession()
        s.onTurnEnd = { text, end, _ in completions.append((text, end)) }
        s.startRemote { _ in }
        try s.send("finish", from: .person)

        // Deliberately do not wait for the off-main decoder. The authoritative
        // exit arriving immediately after the final wire chunk must itself be
        // the drain barrier that preserves this result.
        s.consume(Data(event([
            "type": "result",
            "stop_reason": "end_turn",
            "result": "final answer",
        ]).utf8))
        await s.finishRemoteSurfaceExited(exitCode: 0, signal: 0, reason: "exited")

        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.0, "final answer")
        XCTAssertEqual(completions.first?.1.stop, "end_turn")
        XCTAssertFalse(completions.first?.1.failed == true,
                       "a decoded result must not be replaced by process_exited failure")
    }

    /// One session, one transport. A local start while the remote session is
    /// live would hand the decoders two interleaved streams; it is refused,
    /// and `canInterrupt` — which a local start would have overwritten — is
    /// the witness.
    func testASessionRefusesALocalStartWhileRemote() {
        let s = AgentSession()
        s.startRemote(interruptible: true) { _ in }

        s.start(.init(executable: "/bin/sleep", arguments: ["30"],
                      workingDirectory: NSTemporaryDirectory(),
                      environment: ProcessInfo.processInfo.environment))

        XCTAssertTrue(s.canInterrupt,
                      "the live remote session must not be displaced by a local start")
        s.stop()
        XCTAssertFalse(s.isRunning)
    }

    /// The panel forwards the remote start, and `close()` — the pane going
    /// away — still stops the session even though there is no process.
    func testAPanelCanStartItsSessionRemotelyAndCloseStopsIt() {
        let panel = AgentPanel(agentName: "reviewer", teamName: "wire-test",
                               workingDirectory: "/tmp", cli: "codex")
        panel.startRemote { _ in }
        XCTAssertTrue(panel.session.isRunning)

        panel.close()

        XCTAssertFalse(panel.session.isRunning)
    }

    // MARK: - Send receipts

    func testRemoteReceiptFiresWhenTheSinkWriteLands() async throws {
        let session = AgentSession()
        session.startRemote { _ in }
        let received = expectation(description: "receipt")
        var disposition: AgentSession.SendDisposition?
        _ = try session.send("ping", from: .leader) { d in
            disposition = d
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 2)
        guard case .remoteWritten = disposition else {
            return XCTFail("expected remoteWritten, got \(String(describing: disposition))")
        }
        session.stop()
    }

    func testRemoteReceiptReportsASinkFailure() async throws {
        struct SinkError: Error {}
        let session = AgentSession()
        session.startRemote { _ in throw SinkError() }
        let received = expectation(description: "receipt")
        var disposition: AgentSession.SendDisposition?
        _ = try session.send("ping", from: .leader) { d in
            disposition = d
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 2)
        guard case .remoteFailed = disposition else {
            return XCTFail("expected remoteFailed, got \(String(describing: disposition))")
        }
        session.stop()
    }

    func testTeardownBeforeTheWriteAnswersRemoteFailedInsteadOfSilence() async throws {
        let session = AgentSession()
        session.startRemote { _ in }
        let received = expectation(description: "receipt")
        var disposition: AgentSession.SendDisposition?
        _ = try session.send("ping", from: .leader) { d in
            disposition = d
            received.fulfill()
        }
        // The tail task cannot have run yet — it needs this main-actor turn to
        // yield first — so stopping now ends the session before the write, the
        // exact path that used to return without answering.
        session.stop()
        await fulfillment(of: [received], timeout: 2)
        guard case .remoteFailed = disposition else {
            return XCTFail("expected remoteFailed, got \(String(describing: disposition))")
        }
    }

    func testQueuedTurnAnswersImmediatelyRatherThanAfterTheRunningTurn() throws {
        let session = AgentSession()
        session.startRemote { _ in }
        _ = try session.send("first", from: .leader)
        var disposition: AgentSession.SendDisposition?
        _ = try session.send("second", from: .leader) { d in disposition = d }
        // The running turn could last minutes; the receipt must not wait on it.
        guard case .queuedBehindTurn = disposition else {
            return XCTFail("expected queuedBehindTurn, got \(String(describing: disposition))")
        }
        session.stop()
    }
}

/// Collects what a remote session wrote, across whatever executor the
/// delivery task ran on.
private final class RemoteSinkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [Data] = []

    func record(_ data: Data) {
        lock.lock()
        payloads.append(data)
        lock.unlock()
    }

    var all: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }
}

// MARK: - Environment diagnostic ordering

extension AgentSessionTests {
    /// The panel header's key list must describe the environment the child
    /// actually gets.
    ///
    /// `env K=V … claude` assignments are arguments to `env`, so they never
    /// exist in the shell that runs `diagnosticEvent`. Reporting from that shell
    /// alone showed every inline gateway key as absent on a pane that was
    /// receiving them — an indicator that accuses the environment loader of
    /// losing a value the child has, which is worse than no indicator at all.
    ///
    /// Moved out of `RemoteSinkRecorder`: a test function on a helper class is
    /// never discovered by XCTest, so this suite silently ran zero of these.
    @MainActor
    func testInlineEnvironmentIsVisibleToTheDiagnosticThatReportsIt() throws {
        let command = AgentSession.remoteCommand(
            executable: "claude",
            arguments: ["--print"],
            workingDirectory: "/work",
            environment: [
                "ANTHROPIC_BASE_URL": "https://gw.example",
                "ANTHROPIC_AUTH_TOKEN": "tok",
                "PATH": "/usr/bin",
            ]
        )
        let exportIndex = try XCTUnwrap(command.range(of: "export ANTHROPIC_AUTH_TOKEN="))
        let diagnosticIndex = try XCTUnwrap(command.range(of: "present_keys"))
        XCTAssertTrue(
            exportIndex.lowerBound < diagnosticIndex.lowerBound,
            "the diagnostic must run after the values it reports are in this shell"
        )
        // The `env` prefix stays the authority on what the child receives.
        XCTAssertTrue(command.contains("'ANTHROPIC_AUTH_TOKEN=tok'"))
        // PATH keeps its own dedicated export and must not be duplicated here.
        XCTAssertFalse(command.contains("export PATH=/usr/bin"))
    }

    /// The export runs after `loginPrelude`, so an explicit value keeps winning
    /// over the profile and `agent-env` — the priority the loader documents.
    @MainActor
    func testExplicitValuesAreExportedAfterTheProfileLoad() throws {
        let command = AgentSession.remoteCommand(
            executable: "claude",
            arguments: [],
            workingDirectory: "/work",
            environment: ["ANTHROPIC_AUTH_TOKEN": "explicit"]
        )
        let agentEnv = try XCTUnwrap(command.range(of: ".config/term-mesh/agent-env"))
        let export = try XCTUnwrap(command.range(of: "export ANTHROPIC_AUTH_TOKEN="))
        XCTAssertTrue(agentEnv.lowerBound < export.lowerBound)
    }

    /// The staged-file variant sources its values before the diagnostic already,
    /// and passes only PATH inline — so it must gain no second export.
    @MainActor
    func testTheStagedFileVariantIsUnchanged() throws {
        let command = AgentSession.remoteCommand(
            executable: "claude",
            arguments: [],
            workingDirectory: "/work",
            environment: ["ANTHROPIC_AUTH_TOKEN": "tok", "PATH": "/usr/bin"],
            environmentFile: "/tmp/staged.env"
        )
        XCTAssertFalse(
            command.contains("export ANTHROPIC_AUTH_TOKEN="),
            "the staged file is sourced before the diagnostic and needs no overlay"
        )
        // Asserted on intent, not the literal: the returned command wraps the
        // inner script in another quoting layer, so the file path's quotes
        // arrive escaped and a pre-escape literal can never match.
        let sourced = try XCTUnwrap(command.range(of: "set -a; . "))
        let diagnostic = try XCTUnwrap(command.range(of: "present_keys"))
        XCTAssertTrue(
            sourced.lowerBound < diagnostic.lowerBound,
            "the diagnostic must report values the staged file already loaded"
        )
        XCTAssertTrue(command.contains("/tmp/staged.env"))
    }

    /// `getent` is glibc-only. Asking only it made every macOS host fall through
    /// to `${SHELL:-/bin/sh}` — the launching process's shell, not the account's
    /// — silently loading the wrong profile set and voiding the documented
    /// "/etc/passwd is authoritative" contract.
    func testAccountShellResolutionAsksDarwinAsWellAsGlibc() {
        let resolve = RemoteAgentEnvironmentShell.accountLoginShellResolve
        XCTAssertTrue(resolve.contains("getent passwd"))
        XCTAssertTrue(
            resolve.contains("dscl . -read /Users/"),
            "macOS needs the directory service, which has no getent"
        )
        let getentIndex = resolve.range(of: "getent passwd")!
        let dsclIndex = resolve.range(of: "dscl")!
        XCTAssertTrue(
            getentIndex.lowerBound < dsclIndex.lowerBound,
            "dscl is the fallback, so a Linux peer keeps its existing answer"
        )
        XCTAssertFalse(
            resolve.contains("'"),
            "this text ships inside sh -c '…' and a single quote would end it"
        )
        XCTAssertTrue(resolve.contains("/bin/sh"), "an unusable shell still needs a floor")
    }

    // MARK: - Agent pane slash commands

    func testSlashCommandParserSplitsNameAndArgument() {
        let parsed = AgentSlashCommandParser.parse("/model opus")
        XCTAssertEqual(parsed?.name, "/model")
        XCTAssertEqual(parsed?.argument, "opus")
    }

    func testSlashCommandParserTrimsSurroundingWhitespaceAndCollapsesTheArgument() {
        let parsed = AgentSlashCommandParser.parse("  /model   opus sonnet  ")
        XCTAssertEqual(parsed?.name, "/model")
        XCTAssertEqual(parsed?.argument, "opus sonnet")
    }

    func testSlashCommandParserReturnsEmptyArgumentForABareCommand() {
        let parsed = AgentSlashCommandParser.parse("/cost")
        XCTAssertEqual(parsed?.name, "/cost")
        XCTAssertEqual(parsed?.argument, "")
    }

    func testSlashCommandParserReturnsNilForTextThatIsNotASlashCommand() {
        XCTAssertNil(AgentSlashCommandParser.parse("hello /model"))
        XCTAssertNil(AgentSlashCommandParser.parse(""))
    }

    /// The palette offers values, not just command names — a native pane wants
    /// a full model name and nobody should have to remember one per CLI. The
    /// values come from the same catalog the pickers use, and a command that
    /// takes no argument offers nothing so the popover stays out of the way.
    func testArgumentSuggestionsComeFromTheCLICatalog() {
        guard let model = AgentSlashCommands.command(named: "/model"),
              let effort = AgentSlashCommands.command(named: "/effort"),
              let cost = AgentSlashCommands.command(named: "/cost") else {
            return XCTFail("catalog is missing a command this test needs")
        }
        XCTAssertEqual(
            AgentSlashCommands.argumentSuggestions(for: model, cli: "codex"),
            AgentRolePreset.models(for: "codex")
        )
        XCTAssertEqual(
            AgentSlashCommands.argumentSuggestions(for: model, cli: "claude"),
            AgentRolePreset.models(for: "claude")
        )
        XCTAssertEqual(
            AgentSlashCommands.argumentSuggestions(for: effort, cli: "codex"),
            AgentRolePreset.efforts(for: "codex")
        )
        XCTAssertTrue(AgentSlashCommands.argumentSuggestions(for: cost, cli: "codex").isEmpty)
    }
    /// The catalog only lists what the app can actually perform — see
    /// `AgentSlashCommands`'s note on why `SlashCommands.builtinCommands`
    /// (the terminal-CLI list) is not reused here. `/compact` stands for that
    /// list: a real Claude Code command the app cannot perform, so it must not
    /// appear in this catalog just because a CLI somewhere accepts it.
    func testCatalogLookupIsCaseInsensitiveAndExcludesUnsupportedCommands() {
        XCTAssertEqual(AgentSlashCommands.command(named: "/model")?.name, "/model")
        XCTAssertEqual(AgentSlashCommands.command(named: "/MODEL")?.name, "/model")
        XCTAssertNotNil(AgentSlashCommands.command(named: "/effort"))
        XCTAssertNotNil(AgentSlashCommands.command(named: "/cost"))
        XCTAssertNotNil(AgentSlashCommands.command(named: "/help"))
        XCTAssertNil(AgentSlashCommands.command(named: "/compact"))
    }

    /// A `/xxx` the app does not implement must round-trip through the
    /// catalog lookup as unrecognized, exactly like an ordinary "not found"
    /// case — this is the fact `AgentPanelView.send()` relies on to fall
    /// through to `session.send`, so a person's own CLI slash command is
    /// never silently swallowed by the app instead of reaching the process.
    func testUnknownSlashCommandIsNotInTheCatalogSoItFallsThroughToPlainSend() {
        let parsed = AgentSlashCommandParser.parse("/doctor")
        XCTAssertNotNil(parsed, "still parses as a slash command...")
        XCTAssertNil(
            AgentSlashCommands.command(named: parsed!.name),
            "...but is not one the app executes, so the caller must send it as-is"
        )
    }

    func testSlashCommandMatchesFiltersByPrefixCaseInsensitively() {
        XCTAssertEqual(AgentSlashCommands.matches(prefix: "/m", for: "claude").map(\.name), ["/model"])
        XCTAssertEqual(AgentSlashCommands.matches(prefix: "/M", for: "claude").map(\.name), ["/model"])
        // A bare "/" lists what *this* CLI can run, not the whole catalog:
        // codex sees `/effort` too, claude does not.
        XCTAssertEqual(
            AgentSlashCommands.matches(prefix: "/", for: "codex").count,
            AgentSlashCommands.catalog.count
        )
        XCTAssertEqual(
            AgentSlashCommands.matches(prefix: "/", for: "claude").count,
            AgentSlashCommands.catalog.filter { $0.supports(cli: "claude") }.count
        )
        XCTAssertFalse(
            AgentSlashCommands.matches(prefix: "/", for: "claude").contains { $0.name == "/effort" }
        )
        XCTAssertTrue(AgentSlashCommands.matches(prefix: "/zzz", for: "claude").isEmpty)
    }

    /// `applicationsByCLI == nil` is the "every CLI, uniformly" case a
    /// `.localReport` command like `/help` uses. A `.profileField` command
    /// scoped to specific CLIs must both drop out of an unlisted CLI's
    /// popover and decline to execute if typed anyway — the two guarantees
    /// `AgentPanelView.send()` relies on `supports(cli:)` for.
    func testProfileFieldCommandScopedToOneCLIDropsOutOfAnotherClisPopoverAndSupportCheck() {
        let scoped = AgentSlashCommand(
            name: "/scoped", desc: "test-only",
            kind: .profileField(.model), applicationsByCLI: ["claude": .restart]
        )
        XCTAssertTrue(scoped.supports(cli: "claude"))
        XCTAssertFalse(scoped.supports(cli: "codex"))

        let unscoped = AgentSlashCommands.command(named: "/help")
        XCTAssertEqual(unscoped?.applicationsByCLI, nil)
        XCTAssertTrue(unscoped?.supports(cli: "anything") ?? false)
    }

    /// codex-cli 0.153.4's `TurnStartParams.model` is confirmed to apply to
    /// the next turn with no restart (see `AgentSlashFieldApplication`'s
    /// doc). Every other known CLI defaults to the restart path, since only
    /// codex has been checked against its own schema — a claim this test
    /// pins so a change to the default is a deliberate edit, not a silent
    /// drift.
    func testModelCommandAppliesAsNextTurnParameterOnlyOnCodex() {
        let model = AgentSlashCommands.command(named: "/model")
        XCTAssertEqual(model?.application(for: "codex"), .nextTurnParameter)
        XCTAssertEqual(model?.application(for: "claude"), .restart)
        XCTAssertEqual(model?.application(for: "gemini"), .restart)
        XCTAssertNil(model?.application(for: "some-unknown-cli"))
    }

    /// `/effort` reuses `/model`'s shape without touching `AgentPanelView`:
    /// one more `AgentSlashProfileField` case, applied through the same
    /// generic switch `/model` already goes through.
    func testApplyingAProfileFieldCommandSetsOnlyItsOwnField() {
        var profile = CliProfile(name: "test", family: "claude", executable: "/usr/bin/claude")
        XCTAssertTrue(AgentSlashCommands.apply(.model, argument: "opus", to: &profile))
        XCTAssertEqual(profile.modelOverride, "opus")
    }

    /// codex is the only CLI confirmed to take a reasoning effort at all, so an
    /// absent entry means unsupported — not "restart to apply it instead".
    /// Reading `.restart` here would send a pane through a context-losing
    /// restart that could not carry the value anyway.
    func testEffortCommandIsOfferedOnlyOnCodexAndOnlyAsANextTurnParameter() {
        let effort = AgentSlashCommands.command(named: "/effort")
        XCTAssertEqual(effort?.application(for: "codex"), .nextTurnParameter)
        XCTAssertNil(effort?.application(for: "claude"))
        XCTAssertFalse(effort?.supports(cli: "claude") ?? true)
        XCTAssertTrue(AgentSlashCommands.matches(prefix: "/eff", for: "codex").contains { $0.name == "/effort" })
        XCTAssertTrue(AgentSlashCommands.matches(prefix: "/eff", for: "claude").isEmpty)
    }

    /// `AgentPanelView.runHelpSlashCommand()` lists
    /// `AgentSlashCommands.catalog.filter { $0.supports(cli: panel.cli) }` —
    /// listing the full catalog regardless of pane CLI (the bug this pins)
    /// would print `/effort` for a claude pane, which the pane cannot run.
    func testHelpListsOnlyTheCommandsThisCLISupports() {
        let claudeHelp = AgentSlashCommands.catalog.filter { $0.supports(cli: "claude") }
        XCTAssertFalse(claudeHelp.contains { $0.name == "/effort" })
        XCTAssertTrue(claudeHelp.contains { $0.name == "/model" })
        XCTAssertTrue(claudeHelp.contains { $0.name == "/cost" })
        XCTAssertTrue(claudeHelp.contains { $0.name == "/help" })

        let codexHelp = AgentSlashCommands.catalog.filter { $0.supports(cli: "codex") }
        XCTAssertTrue(codexHelp.contains { $0.name == "/effort" })
        XCTAssertEqual(codexHelp.count, AgentSlashCommands.catalog.count)
    }

    /// Effort has no `CliProfile` field, so the restart path cannot carry it.
    /// `apply` says so rather than writing nothing and letting the caller
    /// restart a pane for a change that never happened.
    func testApplyingEffortToAProfileReportsThatItHasNoProfileField() {
        var profile = CliProfile(name: "test", family: "codex", executable: "/usr/bin/codex")
        XCTAssertFalse(AgentSlashCommands.apply(.effort, argument: "high", to: &profile))
        XCTAssertNil(profile.modelOverride)
    }

    /// The keys are codex `TurnStartParams`' own names, forwarded verbatim by
    /// the bridge's control frame. Renaming one here silently stops the
    /// override from reaching the CLI, so they are pinned.
    func testControlFrameKeysMatchTheCodexTurnStartParameterNames() {
        XCTAssertEqual(AgentSlashProfileField.model.controlFrameKey, "model")
        XCTAssertEqual(AgentSlashProfileField.effort.controlFrameKey, "effort")
    }
}
