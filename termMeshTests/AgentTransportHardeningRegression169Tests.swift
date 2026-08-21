import XCTest
import Foundation

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class AgentTransportHardeningRegression169Tests: XCTestCase {
    private final class LockedOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func append(_ value: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
            return values.count
        }

        var snapshot: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testCommittedFIFOlineFinishesAfterDeadlineInsteadOfLeavingTruncatedJSON() throws {
        var attempts: [AgentPipeTransport.WriteAttempt] = [
            .written(4), .wouldBlock, .written(6),
        ]
        let written = try AgentPipeTransport.writeWholeLine(
            byteCount: 10,
            timeout: 1,
            now: { 10 },
            pause: {},
            attempt: { _, _ in attempts.removeFirst() }
        )
        XCTAssertEqual(written, 10)
        XCTAssertTrue(attempts.isEmpty)
    }

    func testUncommittedFIFOlineMayFailAtDeadlineWithoutWritingBytes() {
        XCTAssertThrowsError(try AgentPipeTransport.writeWholeLine(
            byteCount: 10,
            timeout: 0,
            now: { 10 },
            pause: {},
            attempt: { _, _ in .wouldBlock }
        ))
    }

    func testFailedReservationClearsOnlyItsOwnTaskId() {
        let agentId = "expect-rollback-\(UUID().uuidString)"
        AgentPipeCompletion.shared.watch(
            agentId: agentId, teamName: "t", agentName: "executor")
        defer { AgentPipeCompletion.shared.forget(agentId: agentId) }

        let first = AgentPipeCompletion.shared.expect(
            agentId: agentId, instruction: "TASK_ID: T1")
        let second = AgentPipeCompletion.shared.expect(
            agentId: agentId, instruction: "TASK_ID: T2")

        AgentPipeCompletion.shared.cancelExpectation(agentId: agentId, token: first)
        XCTAssertEqual(
            AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId), "T2",
            "an older failed delivery must not clear a newer reservation")

        AgentPipeCompletion.shared.cancelExpectation(agentId: agentId, token: second)
        XCTAssertNil(AgentPipeCompletion.shared.pendingTaskIdForTesting(agentId: agentId))
    }

    func testSameAgentWriterOperationsStayFIFO() {
        let finished = expectation(description: "serial writer drained")
        let order = LockedOrder()
        let agentId = "writer-order-\(UUID().uuidString)"

        for value in 0..<3 {
            AgentPipeTransport.enqueueForTesting(agentId: agentId) {
                if order.append(value) == 3 { finished.fulfill() }
            }
        }

        wait(for: [finished], timeout: 1)
        XCTAssertEqual(order.snapshot, [0, 1, 2])
    }

    func testMarkdownPresentationPrecomputesInlineAndCodeAttributes() {
        let rendered = AgentMarkdownPresentation.prepare(
            "**ready**\n\n```swift\nlet value = 1\n```")
        XCTAssertEqual(rendered.source, "**ready**\n\n```swift\nlet value = 1\n```")
        XCTAssertEqual(rendered.blocks.count, 2)
        guard case .paragraph(let paragraph) = rendered.blocks[0],
              case .code(let language, let code) = rendered.blocks[1] else {
            return XCTFail("expected prepared paragraph and code blocks")
        }
        XCTAssertEqual(String(paragraph.characters), "ready")
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(String(code.characters), "let value = 1")
    }

    func testTeamSendAcknowledgedWriteStatesItsLimitedDeliveryScope() throws {
        let response = TerminalController.shared.teamSendDeliveryResponse(
            id: 17,
            dispatched: true,
            textDelivered: true,
            teamName: "review",
            agentName: "security",
            agentInstanceId: "instance-1",
            sendSequenceID: "sequence-1"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, true)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["sent"] as? Bool, true)
        XCTAssertEqual(result["text_delivered"] as? Bool, true)
        XCTAssertEqual(result["delivery_scope"] as? String, "transport_write")
        XCTAssertEqual(result["transport_dispatched"] as? Bool, true)
        XCTAssertEqual(result["send_sequence_id"] as? String, "sequence-1")
        XCTAssertNil(result["consumed"])
        XCTAssertNil(result["replied"])
    }

    func testTeamSendMissingWriteAckIsDeliveryFailureNotSuccess() throws {
        let response = TerminalController.shared.teamSendDeliveryResponse(
            id: 18,
            dispatched: true,
            textDelivered: false,
            teamName: "review",
            agentName: "security",
            agentInstanceId: "instance-1"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "delivery_failed")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["sent"] as? Bool, false)
        XCTAssertEqual(data["text_delivered"] as? Bool, false)
        XCTAssertEqual(data["delivery_scope"] as? String, "transport_write")
        XCTAssertEqual(data["transport_dispatched"] as? Bool, true)
    }

    func testNativeDeliveryScopeDistinguishesPeerFailureFromLocalWrite() {
        XCTAssertEqual(
            TerminalController.shared.nativeDeliveryScope(.remoteWritten),
            "peer_transport_write"
        )
        XCTAssertEqual(
            TerminalController.shared.nativeDeliveryScope(.remoteFailed("closed")),
            "peer_transport_failed"
        )
        XCTAssertEqual(
            TerminalController.shared.nativeDeliveryScope(.queuedBehindTurn),
            "queued_local"
        )
        XCTAssertEqual(
            TerminalController.shared.nativeDeliveryScope(.writtenLocal),
            "transport_write"
        )
    }

    func testSendDeadmanAppliesOnlyToTerminalPaste() {
        XCTAssertTrue(
            TerminalController.shared.sendDeadmanApplies(deliveredNatively: false)
        )
        XCTAssertFalse(
            TerminalController.shared.sendDeadmanApplies(deliveredNatively: true)
        )
    }

    func testDelegateMissingWriteAckIsDeliveryFailure() throws {
        let response = TerminalController.shared.teamDelegateDeliveryFailureResponse(
            id: 20,
            returnRequired: false,
            requestReplayed: false,
            agentInstanceId: "instance-1"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "delivery_failed")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["sent"] as? Bool, false)
        XCTAssertEqual(data["text_delivered"] as? Bool, false)
        XCTAssertEqual(data["return_required"] as? Bool, false)
        XCTAssertEqual(data["agent_instance_id"] as? String, "instance-1")
    }

    func testTeamSendAcknowledgementAnnouncesWhetherReturnIsRequired() throws {
        func result(returnRequired: Bool?) throws -> [String: Any] {
            let response = TerminalController.shared.teamSendDeliveryResponse(
                id: 19,
                dispatched: true,
                textDelivered: true,
                teamName: "review",
                agentName: "security",
                agentInstanceId: "instance-1",
                sendSequenceID: "sequence-2",
                returnRequired: returnRequired
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(object["result"] as? [String: Any])
        }
        XCTAssertEqual(try result(returnRequired: false)["return_required"] as? Bool, false)
        XCTAssertEqual(try result(returnRequired: true)["return_required"] as? Bool, true)
        XCTAssertNil(
            try result(returnRequired: nil)["return_required"],
            "a caller that does not state the transport keeps the legacy shape"
        )
    }

    func testNativeSendReleasesItsGateAtSendTimeWithoutAwaitingReturn() async {
        let key = "gate-native-release/\(UUID().uuidString)"
        let (_, gate) = await MainActor.run {
            TerminalController.enqueueSendGate(agentKey: key, sequenceAware: true)
        }
        // asyncTeamSend on a native target discards instead of markAwaitingReturn:
        // no team.send_key follows to claim this gate.
        await MainActor.run {
            TerminalController.discardSendGate(gate, agentKey: key)
        }
        let legacyFollowUpReturn = await MainActor.run {
            TerminalController.takeAcknowledgedSendGate(
                agentKey: key, sequenceID: gate.sequenceID
            )
        }
        XCTAssertNil(
            legacyFollowUpReturn,
            "a released native gate must not be claimable by a legacy follow-up Return"
        )
        let (predecessor, next) = await MainActor.run {
            TerminalController.enqueueSendGate(agentKey: key, sequenceAware: true)
        }
        XCTAssertNil(
            predecessor,
            "the next send must not queue behind a gate the native ack already released"
        )
        await MainActor.run {
            TerminalController.discardSendGate(next, agentKey: key)
        }
    }

    func testSlowAndFastSendKeysCompleteOnlyTheirOwnedGate() async {
        let key = "gate-test/\(UUID().uuidString)"
        let (_, slow) = await MainActor.run {
            TerminalController.enqueueSendGate(agentKey: key)
        }
        let (previous, fast) = await MainActor.run {
            TerminalController.enqueueSendGate(agentKey: key)
        }
        XCTAssertTrue(previous === slow)
        slow.markAwaitingReturn()
        fast.markAwaitingReturn()

        let completedFast = await MainActor.run {
            TerminalController.takeAcknowledgedSendGate(
                agentKey: key, sequenceID: fast.sequenceID
            )
        }
        XCTAssertTrue(completedFast === fast)

        // A delayed retry for fast must not consume the still-pending slow gate.
        let staleRetry = await MainActor.run {
            TerminalController.takeAcknowledgedSendGate(
                agentKey: key, sequenceID: fast.sequenceID
            )
        }
        XCTAssertNil(staleRetry)

        let completedSlow = await MainActor.run {
            TerminalController.takeAcknowledgedSendGate(
                agentKey: key, sequenceID: slow.sequenceID
            )
        }
        XCTAssertTrue(completedSlow === slow)
        await MainActor.run {
            TerminalController.discardSendGate(fast, agentKey: key)
            TerminalController.discardSendGate(slow, agentKey: key)
        }
    }

    func testWatchdogCleanupRemovesOnlyTheExpiredGateIdentity() async {
        let key = "gate-watchdog-test/\(UUID().uuidString)"
        let (_, expired) = await MainActor.run {
            TerminalController.enqueueSendGate(agentKey: key)
        }
        let (_, newer) = await MainActor.run {
            TerminalController.enqueueSendGate(agentKey: key)
        }
        newer.markAwaitingReturn()

        await MainActor.run {
            TerminalController.discardSendGate(expired, agentKey: key)
        }

        let tokenlessDelegateReturn = await MainActor.run {
            TerminalController.takeAcknowledgedSendGate(agentKey: key, sequenceID: nil)
        }
        XCTAssertNil(
            tokenlessDelegateReturn,
            "a tokenless delegate Return must not steal an unrelated send gate"
        )

        let completedNewer = await MainActor.run {
            TerminalController.takeAcknowledgedSendGate(
                agentKey: key, sequenceID: newer.sequenceID
            )
        }
        XCTAssertTrue(completedNewer === newer)
        await MainActor.run {
            TerminalController.discardSendGate(newer, agentKey: key)
        }
    }

    func testTokenlessReturnClaimsOnlyLegacyGateWithoutTouchingSequenceGate() async {
        let key = "gate-version-test/\(UUID().uuidString)"
        let (_, sequenceGate) = await MainActor.run {
            TerminalController.enqueueSendGate(agentKey: key, sequenceAware: true)
        }
        let (previous, legacyGate) = await MainActor.run {
            TerminalController.enqueueSendGate(agentKey: key, sequenceAware: false)
        }
        XCTAssertTrue(previous === sequenceGate, "protocol generations still share serialization order")
        sequenceGate.markAwaitingReturn()
        legacyGate.markAwaitingReturn()

        let claimedLegacy = await MainActor.run {
            TerminalController.takeAcknowledgedSendGate(agentKey: key, sequenceID: nil)
        }
        XCTAssertTrue(claimedLegacy === legacyGate)

        let claimedSequence = await MainActor.run {
            TerminalController.takeAcknowledgedSendGate(
                agentKey: key,
                sequenceID: sequenceGate.sequenceID
            )
        }
        XCTAssertTrue(claimedSequence === sequenceGate)
        await MainActor.run {
            TerminalController.discardSendGate(legacyGate, agentKey: key)
            TerminalController.discardSendGate(sequenceGate, agentKey: key)
        }
    }

    func testClaimedAwareAndLegacyGateRemainSerializationPredecessorsUntilCompletion() async {
        for sequenceAware in [true, false] {
            let key = "gate-claim-race-\(sequenceAware)-\(UUID().uuidString)"
            let (_, claimed) = await MainActor.run {
                TerminalController.enqueueSendGate(
                    agentKey: key,
                    sequenceAware: sequenceAware
                )
            }
            claimed.markAwaitingReturn()
            let ownershipClaim = await MainActor.run {
                TerminalController.takeAcknowledgedSendGate(
                    agentKey: key,
                    sequenceID: sequenceAware ? claimed.sequenceID : nil
                )
            }
            XCTAssertTrue(ownershipClaim === claimed)

            let (predecessor, next) = await MainActor.run {
                TerminalController.enqueueSendGate(
                    agentKey: key,
                    sequenceAware: !sequenceAware
                )
            }
            XCTAssertTrue(
                predecessor === claimed,
                "claim must not let the next paste overtake Return delivery"
            )

            await MainActor.run {
                TerminalController.discardSendGate(claimed, agentKey: key)
                TerminalController.discardSendGate(next, agentKey: key)
            }
        }
    }

    func testCorrelationMailboxSurvivesMoreThanMessageRetentionNoise() {
        let store = TeamDataStore.shared
        let team = "correlation-noise-\(UUID().uuidString)"
        let token = String(repeating: "a", count: 32)
        store.registerTeam(team, agents: [
            .init(name: "reviewer", instanceId: "instance-1"),
        ])
        defer { store.unregisterTeam(team) }

        XCTAssertTrue(store.registerCorrelation(
            teamName: team,
            token: token,
            expectedAgentName: "reviewer",
            expectedAgentInstanceId: "instance-1",
            expiresAt: Date().addingTimeInterval(60)
        ))
        guard case .completed = store.completeCorrelation(
            teamName: team,
            token: token,
            agentName: "reviewer",
            agentInstanceId: "instance-1",
            content: "durable reply"
        ) else { return XCTFail("owner could not complete mailbox") }
        for index in 0..<600 {
            XCTAssertNotNil(store.postMessage(
                teamName: team,
                from: "reviewer",
                to: "leader",
                content: "noise \(index)",
                type: "note"
            ))
        }
        guard case .ready(let reply) = store.correlation(
            teamName: team, token: token, consume: false
        ) else {
            return XCTFail("correlated reply was evicted by ordinary messages")
        }
        XCTAssertEqual(reply.content, "durable reply")
    }

    func testCorrelationMailboxRejectsWrongTokenIdentityAndDuplicate() {
        let store = TeamDataStore.shared
        let team = "correlation-identity-\(UUID().uuidString)"
        let token = String(repeating: "b", count: 32)
        store.registerTeam(team, agents: [
            .init(name: "reviewer", instanceId: "instance-1"),
            .init(name: "reviewer", instanceId: "instance-2"),
        ])
        defer { store.unregisterTeam(team) }
        XCTAssertTrue(store.registerCorrelation(
            teamName: team,
            token: token,
            expectedAgentName: "reviewer",
            expectedAgentInstanceId: "instance-1",
            expiresAt: Date().addingTimeInterval(60)
        ))

        XCTAssertEqual(store.completeCorrelation(
            teamName: team,
            token: String(repeating: "c", count: 32),
            agentName: "reviewer",
            agentInstanceId: "instance-1",
            content: "forged"
        ), .notFound)
        XCTAssertEqual(store.completeCorrelation(
            teamName: team,
            token: token,
            agentName: "reviewer",
            agentInstanceId: "instance-2",
            content: "sibling forged"
        ), .identityMismatch)
        guard case .completed = store.completeCorrelation(
            teamName: team,
            token: token,
            agentName: "reviewer",
            agentInstanceId: "instance-1",
            content: "owned"
        ) else { return XCTFail("owner could not complete mailbox") }
        XCTAssertEqual(store.completeCorrelation(
            teamName: team,
            token: token,
            agentName: "reviewer",
            agentInstanceId: "instance-1",
            content: "duplicate"
        ), .alreadyCompleted)
    }

    func testCorrelationMailboxExpiresAndConsumesAtomically() {
        let store = TeamDataStore.shared
        let team = "correlation-expiry-\(UUID().uuidString)"
        let expiredToken = String(repeating: "d", count: 32)
        let consumedToken = String(repeating: "e", count: 32)
        let now = Date(timeIntervalSince1970: 10_000)
        store.registerTeam(team, agents: [
            .init(name: "reviewer", instanceId: "instance-1"),
        ])
        defer { store.unregisterTeam(team) }

        XCTAssertTrue(store.registerCorrelation(
            teamName: team,
            token: expiredToken,
            expectedAgentName: "reviewer",
            expectedAgentInstanceId: "instance-1",
            expiresAt: now.addingTimeInterval(1),
            now: now
        ))
        XCTAssertEqual(store.correlation(
            teamName: team,
            token: expiredToken,
            consume: true,
            now: now.addingTimeInterval(2)
        ), .notFound)

        XCTAssertTrue(store.registerCorrelation(
            teamName: team,
            token: consumedToken,
            expectedAgentName: "reviewer",
            expectedAgentInstanceId: "instance-1",
            expiresAt: now.addingTimeInterval(10),
            now: now
        ))
        XCTAssertEqual(store.correlation(
            teamName: team, token: consumedToken, consume: true, now: now
        ), .pending, "polling must not consume a pending mailbox")
        guard case .completed = store.completeCorrelation(
            teamName: team,
            token: consumedToken,
            agentName: "reviewer",
            agentInstanceId: "instance-1",
            content: "once",
            now: now
        ) else { return XCTFail("completion failed") }
        guard case .ready = store.correlation(
            teamName: team, token: consumedToken, consume: true, now: now
        ) else { return XCTFail("ready result missing") }
        XCTAssertEqual(store.correlation(
            teamName: team, token: consumedToken, consume: true, now: now
        ), .notFound)
    }

    func testDurableLeaderRequestPreservesLongUnicodeAndIsIdempotent() {
        let store = TeamDataStore.shared
        let team = "leader-request-\(UUID().uuidString)"
        let requestId = "request-\(UUID().uuidString)"
        let content = String(repeating: "한글🙂/quoted `payload` ", count: 80)
        store.registerTeam(team, agentNames: [])
        store.updateBoardUuids([team: UUID().uuidString])
        defer { store.unregisterTeam(team) }

        guard case .created(let created, _) = store.enqueueLeaderRequest(
            teamName: team, content: content, requestId: requestId
        ) else { return XCTFail("request was not created") }
        XCTAssertEqual(created.content, content)
        XCTAssertEqual(created.contentBytes, content.lengthOfBytes(using: .utf8))
        XCTAssertEqual(created.contentSHA256, TeamDataStore.leaderRequestDigest(content))

        guard case .replayed(let replayed, _) = store.enqueueLeaderRequest(
            teamName: team, content: content, requestId: requestId
        ) else { return XCTFail("identical request_id was not replayed") }
        XCTAssertEqual(replayed.id, created.id)
        guard case .conflict = store.enqueueLeaderRequest(
            teamName: team, content: content + "different", requestId: requestId
        ) else { return XCTFail("different content reused request_id") }

        guard case .succeeded(let taken) = store.takeLeaderRequest(
            teamName: team, requestId: requestId
        ) else { return XCTFail("queued request was not claimed") }
        XCTAssertEqual(taken.content, content)
        XCTAssertEqual(taken.status, "claimed")
        guard case .invalidState("claimed") = store.takeLeaderRequest(
            teamName: team, requestId: requestId
        ) else { return XCTFail("a claimed request was claimable twice") }
        guard case .succeeded(let completed) = store.completeLeaderRequest(
            teamName: team, requestId: requestId
        ) else { return XCTFail("claimed request was not completed") }
        XCTAssertEqual(completed.status, "completed")
        guard case .invalidState("completed") = store.completeLeaderRequest(
            teamName: team, requestId: requestId
        ) else { return XCTFail("a completed request was completable twice") }
        guard case .replayed(let completedReplay, _) = store.enqueueLeaderRequest(
            teamName: team, content: content, requestId: requestId
        ) else { return XCTFail("completed request was not replayed") }
        XCTAssertEqual(completedReplay.status, "completed")
        XCTAssertEqual(store.listLeaderRequests(teamName: team)?.count, 0)
        XCTAssertEqual(store.listLeaderRequests(teamName: team, includeCompleted: true)?.count, 1)
    }

    func testDurableLeaderRequestRejectsUnsafeIdentifiersAndOversizedBodies() {
        let store = TeamDataStore.shared
        let team = "leader-request-bounds-\(UUID().uuidString)"
        store.registerTeam(team, agentNames: [])
        store.updateBoardUuids([team: UUID().uuidString])
        defer { store.unregisterTeam(team) }

        for requestId in ["line\nbreak", "한글", String(repeating: "x", count: 65)] {
            guard case .invalidRequest = store.enqueueLeaderRequest(
                teamName: team, content: "payload", requestId: requestId
            ) else { return XCTFail("unsafe request id was accepted: \(requestId)") }
        }
        guard case .invalidRequest = store.enqueueLeaderRequest(
            teamName: team,
            content: String(repeating: "x", count: 256 * 1024 + 1),
            requestId: "oversized"
        ) else { return XCTFail("oversized leader request was accepted") }
    }

    func testLeaderRequestCapabilityIsExactAndNeverPersisted() throws {
        let store = TeamDataStore.shared
        let sourceTeam = "leader-token-source-\(UUID().uuidString)"
        let teamUuid = UUID().uuidString
        store.registerTeam(sourceTeam, agentNames: [])
        store.updateBoardUuids([sourceTeam: teamUuid])
        defer { store.unregisterTeam(sourceTeam) }

        let token = store.prepareLeaderRequestToken(teamName: sourceTeam)
        XCTAssertFalse(store.isAuthorizedLeaderRequestToken(teamName: sourceTeam, token: nil))
        XCTAssertFalse(store.isAuthorizedLeaderRequestToken(teamName: sourceTeam, token: "wrong"))
        XCTAssertTrue(store.isAuthorizedLeaderRequestToken(teamName: sourceTeam, token: token))
        guard case .created(_, let persisted) = store.enqueueLeaderRequest(
            teamName: sourceTeam, content: "persist token", requestId: "token-restore"
        ) else { return XCTFail("request was not created") }
        XCTAssertTrue(persisted)

        let data = try Data(contentsOf: TeamDataStore.boardFileURL(teamUuid: teamUuid))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(token))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let board = try decoder.decode(TeamDataStore.PersistedBoard.self, from: data)
        XCTAssertNil(board.leaderRequestToken)
    }

    func testDurableLeaderRequestCannotCompleteBeforeClaim() {
        let store = TeamDataStore.shared
        let team = "leader-request-transition-\(UUID().uuidString)"
        let requestId = "request-\(UUID().uuidString)"
        store.registerTeam(team, agentNames: [])
        store.updateBoardUuids([team: UUID().uuidString])
        defer { store.unregisterTeam(team) }
        guard case .created = store.enqueueLeaderRequest(
            teamName: team, content: "queued", requestId: requestId
        ) else { return XCTFail("request was not created") }
        guard case .invalidState("queued") = store.completeLeaderRequest(
            teamName: team, requestId: requestId
        ) else { return XCTFail("queued request completed without a claim") }
    }

    func testDurableLeaderRequestIsOnDiskBeforeEnqueueReturns() throws {
        let store = TeamDataStore.shared
        let team = "leader-request-disk-\(UUID().uuidString)"
        let teamUuid = UUID().uuidString
        let requestId = "request-\(UUID().uuidString)"
        let content = String(repeating: "끝까지 보존🙂 `quoted` ", count: 96) + "UNIQUE-END-SENTINEL"
        store.registerTeam(team, agentNames: [])
        store.updateBoardUuids([team: teamUuid])
        defer { store.unregisterTeam(team) }

        guard case .created(let created, let persisted) = store.enqueueLeaderRequest(
            teamName: team, content: content, requestId: requestId
        ) else { return XCTFail("request was not created") }
        XCTAssertTrue(persisted)

        let data = try Data(contentsOf: TeamDataStore.boardFileURL(teamUuid: teamUuid))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let board = try decoder.decode(TeamDataStore.PersistedBoard.self, from: data)
        let stored = try XCTUnwrap(board.leaderRequests?.first { $0.id == requestId })
        XCTAssertEqual(stored.content, content)
        XCTAssertEqual(stored.contentBytes, created.contentBytes)
        XCTAssertEqual(stored.contentSHA256, created.contentSHA256)
    }

    func testCoordinationMetricsUseBoardTimestampsAndMeasureOverlap() throws {
        let store = TeamDataStore.shared
        let team = "metrics-\(UUID().uuidString)"
        let requestId = "request-\(UUID().uuidString)"
        store.registerTeam(team, agents: [
            .init(name: "executor", instanceId: "instance-1"),
            .init(name: "tester", instanceId: "instance-2"),
        ])
        store.updateBoardUuids([team: UUID().uuidString])
        defer { store.unregisterTeam(team) }

        guard case .created = store.enqueueLeaderRequest(
            teamName: team, content: "parallel work", requestId: requestId,
            now: Date().addingTimeInterval(-10)
        ) else { return XCTFail("request missing") }
        let first = try XCTUnwrap(store.createTask(
            teamName: team, title: "one", assignee: "executor",
            assigneeInstanceId: "instance-1"
        ))
        let second = try XCTUnwrap(store.createTask(
            teamName: team, title: "two", assignee: "tester",
            assigneeInstanceId: "instance-2"
        ))
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: first.id, status: "in_progress"))
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: second.id, status: "in_progress"))
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: first.id, status: "completed"))
        XCTAssertNotNil(store.updateTask(teamName: team, taskId: second.id, status: "completed"))
        guard case .succeeded = store.takeLeaderRequest(teamName: team, requestId: requestId) else {
            return XCTFail("metrics request was not claimed")
        }
        guard case .succeeded = store.completeLeaderRequest(teamName: team, requestId: requestId) else {
            return XCTFail("metrics request was not completed")
        }

        let metrics = try XCTUnwrap(store.coordinationMetrics(
            teamName: team, requestId: requestId
        ))
        XCTAssertEqual(metrics["source"] as? String, "board_timestamps")
        XCTAssertEqual(metrics["task_count"] as? Int, 2)
        XCTAssertEqual(metrics["completed_task_count"] as? Int, 2)
        XCTAssertGreaterThanOrEqual(metrics["overlap_seconds"] as? Double ?? -1, 0)
        XCTAssertNotNil(metrics["dispatch_latency_seconds"])
        XCTAssertNotNil(metrics["total_duration_seconds"])
    }
}
