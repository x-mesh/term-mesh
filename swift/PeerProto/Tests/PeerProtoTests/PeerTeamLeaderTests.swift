import XCTest
@testable import PeerProto

final class PeerTeamLeaderTests: XCTestCase {
    func testBootstrapAcceptsOnlyBoundedIdentifiersPlacementAndRequestID() {
        var request = validRequest()
        XCTAssertSuccess(PeerTeamLeader.validateBootstrap(request, encodedBytes: 64))

        request.projectID = #"name:demo; rm -rf /"#
        XCTAssertFailure(
            PeerTeamLeader.validateBootstrap(request),
            equals: .invalidProject
        )

        request = validRequest()
        request.leaderPlacement = .unspecified
        XCTAssertFailure(
            PeerTeamLeader.validateBootstrap(request),
            equals: .invalidPlacement
        )

        request = validRequest()
        request.requestID = Data(repeating: 1, count: 15)
        XCTAssertFailure(
            PeerTeamLeader.validateBootstrap(request),
            equals: .invalidRequestID
        )

        XCTAssertFailure(
            PeerTeamLeader.validateBootstrap(
                validRequest(),
                encodedBytes: PeerTeamLeader.maxBootstrapPayloadBytes + 1
            ),
            equals: .payloadTooLarge
        )
    }

    func testBootstrapWireSchemaHasNoExecutableConfigurationFields() {
        XCTAssertEqual(
            Termmesh_Peer_V1_TeamLeaderBootstrapRequest.protoMessageName,
            "termmesh.peer.v1.TeamLeaderBootstrapRequest"
        )

        // Injection through one of the three strings is rejected by the same
        // validator the server calls before project lookup.
        for injected in [
            "/tmp/project",
            "name:demo\ncommand=/bin/sh",
            "name:demo --cli codex",
            "name:demo$HOME",
            "name:demo env=TOKEN",
        ] {
            var request = validRequest()
            request.projectID = injected
            XCTAssertFailure(
                PeerTeamLeader.validateBootstrap(request),
                equals: .invalidProject,
                "accepted executable-field injection: \(injected)"
            )
        }
    }

    func testGrantBindsProjectTeamRoleAndExpiry() {
        let registered = validGrant()
        XCTAssertSuccess(
            PeerTeamLeader.validateGrant(
                registered,
                registered: registered,
                expectedProjectID: "name:demo",
                expectedTeamUUID: "team-uuid",
                nowUnixSeconds: 99
            )
        )

        var forgedProject = registered
        forgedProject.projectID = "name:other"
        XCTAssertFailure(
            PeerTeamLeader.validateGrant(
                forgedProject,
                registered: registered,
                expectedProjectID: "name:demo",
                expectedTeamUUID: "team-uuid",
                nowUnixSeconds: 99
            ),
            equals: .forgedProject
        )

        var forgedTeam = registered
        forgedTeam.teamUuid = "other-team"
        XCTAssertFailure(
            PeerTeamLeader.validateGrant(
                forgedTeam,
                registered: registered,
                expectedProjectID: "name:demo",
                expectedTeamUUID: "team-uuid",
                nowUnixSeconds: 99
            ),
            equals: .forgedTeam
        )

        var wrongRole = registered
        wrongRole.role = .unspecified
        XCTAssertFailure(
            PeerTeamLeader.validateGrant(
                wrongRole,
                registered: registered,
                expectedProjectID: "name:demo",
                expectedTeamUUID: "team-uuid",
                nowUnixSeconds: 99
            ),
            equals: .invalidRole
        )

        XCTAssertFailure(
            PeerTeamLeader.validateGrant(
                registered,
                registered: registered,
                expectedProjectID: "name:demo",
                expectedTeamUUID: "team-uuid",
                nowUnixSeconds: 100
            ),
            equals: .expiredGrant
        )

        XCTAssertFailure(
            PeerTeamLeader.validateGrant(
                registered,
                registered: nil,
                expectedProjectID: "name:demo",
                expectedTeamUUID: "team-uuid",
                nowUnixSeconds: 99
            ),
            equals: .unknownGrant
        )
    }

    func testRequestIDReplayIsRejected() async {
        let guardRegistry = PeerTeamLeaderReplayGuard()
        let requestID = Data(repeating: 7, count: PeerTeamLeader.requestIDBytes)
        XCTAssertSuccess(await guardRegistry.consume(requestID))
        XCTAssertFailure(
            await guardRegistry.consume(requestID),
            equals: .replayedRequest
        )
    }

    func testGenericTeamCallStillRejectsLifecycle() {
        for method in [
            "team.create", "team.destroy", "team.attach", "team.detach",
            "team.add_agent", "team.restart",
        ] {
            XCTAssertFalse(PeerTeamCall.isAllowed(method))
        }
    }

    func testControlPlaneRejectsForgedScopeExpiryObserverOversizeAndBadRequestIDBeforeDispatch() async {
        let controlPlane = PeerTeamLeaderControlPlane()
        let registered = validGrant()
        await controlPlane.registerGrant(registered)
        let mutations = MutationCounter()

        var forgedProject = validCommand(grant: registered, requestByte: 1)
        forgedProject.grant.projectID = "name:other"
        var forgedTeam = validCommand(grant: registered, requestByte: 2)
        forgedTeam.teamUuid = "other-team"
        var expired = validCommand(grant: registered, requestByte: 3)
        expired.grant.expiresAtUnixSecs = 99
        var observer = validCommand(grant: registered, requestByte: 4)
        observer.grant.role = .observer
        var badRequestID = validCommand(grant: registered, requestByte: 5)
        badRequestID.requestID = Data(repeating: 5, count: 15)

        let cases: [
            (Termmesh_Peer_V1_TeamLeaderCommandRequest, Int, String)
        ] = [
            (forgedProject, 128, PeerTeamLeader.ValidationError.forgedProject.rawValue),
            (forgedTeam, 128, PeerTeamLeader.ValidationError.forgedTeam.rawValue),
            (expired, 128, PeerTeamLeader.ValidationError.expiredGrant.rawValue),
            (observer, 128, PeerTeamLeader.ValidationError.invalidRole.rawValue),
            (
                validCommand(grant: registered, requestByte: 6),
                PeerTeamLeader.maxCommandPayloadBytes + 1,
                PeerTeamLeader.ValidationError.payloadTooLarge.rawValue
            ),
            (badRequestID, 128, PeerTeamLeader.ValidationError.invalidRequestID.rawValue),
        ]

        for (request, encodedBytes, expectedError) in cases {
            let response = await controlPlane.execute(
                request,
                encodedBytes: encodedBytes,
                nowUnixSeconds: 99
            ) { _, _, _ in
                await mutations.increment()
                return .success(#"{"unexpected":true}"#)
            }
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorCode, expectedError)
        }
        let mutationCount = await mutations.value()
        let auditCount = await controlPlane.auditRecords().count
        XCTAssertEqual(mutationCount, 0)
        XCTAssertEqual(auditCount, cases.count)
    }

    func testConcurrentReplayReturnsCachedResultWithoutDuplicateMutationAndAuditsEveryAttempt() async {
        let controlPlane = PeerTeamLeaderControlPlane()
        let registered = validGrant()
        await controlPlane.registerGrant(registered)
        let request = validCommand(grant: registered, requestByte: 42)
        let mutations = MutationCounter()

        let responses = await withTaskGroup(
            of: Termmesh_Peer_V1_TeamLeaderCommandResponse.self,
            returning: [Termmesh_Peer_V1_TeamLeaderCommandResponse].self
        ) { group in
            for _ in 0..<40 {
                group.addTask {
                    await controlPlane.execute(
                        request,
                        encodedBytes: 256,
                        nowUnixSeconds: 99
                    ) { method, params, teamUUID in
                        await mutations.increment()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        return .success(
                            #"{"method":"\#(method)","team":"\#(teamUUID)","params":\#(params)}"#
                        )
                    }
                }
            }
            var values: [Termmesh_Peer_V1_TeamLeaderCommandResponse] = []
            for await response in group { values.append(response) }
            return values
        }

        XCTAssertEqual(responses.count, 40)
        XCTAssertTrue(responses.allSatisfy(\.ok))
        XCTAssertEqual(Set(responses.map(\.resultJson)).count, 1)
        XCTAssertEqual(responses.filter(\.cached).count, 39)
        let mutationCount = await mutations.value()
        XCTAssertEqual(mutationCount, 1)
        let audit = await controlPlane.auditRecords()
        XCTAssertEqual(audit.count, 40)
        XCTAssertEqual(audit.filter(\.replayed).count, 39)
    }

    func testControlPlaneForcesCommandAllowListAndJSONObjectBeforeDispatch() async {
        let controlPlane = PeerTeamLeaderControlPlane()
        let registered = validGrant()
        await controlPlane.registerGrant(registered)
        let mutations = MutationCounter()

        var lifecycle = validCommand(grant: registered, requestByte: 11)
        lifecycle.method = "team.create"
        let lifecycleResponse = await controlPlane.execute(
            lifecycle,
            encodedBytes: 128,
            nowUnixSeconds: 99
        ) { _, _, _ in
            await mutations.increment()
            return .success("{}")
        }
        XCTAssertEqual(
            lifecycleResponse.errorCode,
            PeerTeamLeader.ValidationError.invalidMethod.rawValue
        )

        var arrayParams = validCommand(grant: registered, requestByte: 12)
        arrayParams.paramsJson = "[]"
        let paramsResponse = await controlPlane.execute(
            arrayParams,
            encodedBytes: 128,
            nowUnixSeconds: 99
        ) { _, _, _ in
            await mutations.increment()
            return .success("{}")
        }
        XCTAssertEqual(
            paramsResponse.errorCode,
            PeerTeamLeader.ValidationError.invalidParams.rawValue
        )
        let mutationCount = await mutations.value()
        XCTAssertEqual(mutationCount, 0)
    }

    func testBootstrapAndGrantRegistriesAreTTLBounded() async {
        let controlPlane = PeerTeamLeaderControlPlane(
            maxBootstrapEntries: 2,
            maxGrantEntries: 2
        )
        func bootstrap(_ byte: UInt8, now: UInt64) async
            -> Termmesh_Peer_V1_TeamLeaderBootstrapResponse {
            var request = validRequest()
            request.requestID = Data(
                repeating: byte,
                count: PeerTeamLeader.requestIDBytes
            )
            return await controlPlane.bootstrap(
                request,
                encodedBytes: 64,
                nowUnixSeconds: now,
                grantLifetimeSeconds: 10
            ) { _ in "team-uuid" }
        }

        let firstBootstrap = await bootstrap(1, now: 10)
        let secondBootstrap = await bootstrap(2, now: 10)
        let thirdBootstrap = await bootstrap(3, now: 10)
        XCTAssertTrue(firstBootstrap.ok)
        XCTAssertTrue(secondBootstrap.ok)
        XCTAssertTrue(thirdBootstrap.ok)
        let evictedBootstrap = await bootstrap(1, now: 10)
        XCTAssertTrue(
            evictedBootstrap.ok,
            "oldest bootstrap id must be evicted at the configured cap"
        )
        let expiredBootstrap = await bootstrap(2, now: 21)
        XCTAssertTrue(
            expiredBootstrap.ok,
            "expired bootstrap ids must be purged"
        )

        var first = validGrant()
        first.grantID = Data(repeating: 1, count: PeerTeamLeader.grantIDBytes)
        first.expiresAtUnixSecs = 100
        var second = first
        second.grantID = Data(repeating: 2, count: PeerTeamLeader.grantIDBytes)
        var third = first
        third.grantID = Data(repeating: 3, count: PeerTeamLeader.grantIDBytes)
        await controlPlane.registerGrant(first)
        await controlPlane.registerGrant(second)
        await controlPlane.registerGrant(third)

        let evicted = await controlPlane.execute(
            validCommand(grant: first, requestByte: 71),
            encodedBytes: 128,
            nowUnixSeconds: 99
        ) { _, _, _ in .success("{}") }
        XCTAssertFalse(evicted.ok)
        XCTAssertEqual(
            evicted.errorCode,
            PeerTeamLeader.ValidationError.unknownGrant.rawValue
        )
    }

    func testActiveBootstrapGrantRenewsServerLeaseWithoutChangingWireExpiry() async {
        let controlPlane = PeerTeamLeaderControlPlane()
        let bootstrap = await controlPlane.bootstrap(
            validRequest(),
            encodedBytes: 64,
            nowUnixSeconds: 10,
            grantLifetimeSeconds: 10
        ) { _ in "team-uuid" }
        XCTAssertTrue(bootstrap.ok)
        XCTAssertEqual(bootstrap.grant.expiresAtUnixSecs, 20)

        let first = await controlPlane.execute(
            validCommand(grant: bootstrap.grant, requestByte: 81),
            encodedBytes: 128,
            nowUnixSeconds: 19
        ) { _, _, _ in .success("{}") }
        XCTAssertTrue(first.ok)

        let renewed = await controlPlane.execute(
            validCommand(grant: bootstrap.grant, requestByte: 82),
            encodedBytes: 128,
            nowUnixSeconds: 21
        ) { _, _, _ in .success("{}") }
        XCTAssertTrue(
            renewed.ok,
            "server lease renewal must accept the originally issued wire expiry"
        )

        var forgedExpiry = validCommand(grant: bootstrap.grant, requestByte: 83)
        forgedExpiry.grant.expiresAtUnixSecs = 31
        let forged = await controlPlane.execute(
            forgedExpiry,
            encodedBytes: 128,
            nowUnixSeconds: 21
        ) { _, _, _ in .success("{}") }
        XCTAssertFalse(forged.ok)
        XCTAssertEqual(
            forged.errorCode,
            PeerTeamLeader.ValidationError.expiredGrant.rawValue
        )

        let expired = await controlPlane.execute(
            validCommand(grant: bootstrap.grant, requestByte: 84),
            encodedBytes: 128,
            nowUnixSeconds: 32
        ) { _, _, _ in .success("{}") }
        XCTAssertFalse(expired.ok)
        XCTAssertEqual(
            expired.errorCode,
            PeerTeamLeader.ValidationError.unknownGrant.rawValue
        )
    }

    private func validRequest() -> Termmesh_Peer_V1_TeamLeaderBootstrapRequest {
        var request = Termmesh_Peer_V1_TeamLeaderBootstrapRequest()
        request.projectID = "name:demo"
        request.leaderPlacement = .peer
        request.requestID = Data(repeating: 1, count: PeerTeamLeader.requestIDBytes)
        return request
    }

    private func validGrant() -> Termmesh_Peer_V1_TeamLeaderGrant {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 2, count: PeerTeamLeader.grantIDBytes)
        grant.projectID = "name:demo"
        grant.teamUuid = "team-uuid"
        grant.role = .leader
        grant.expiresAtUnixSecs = 100
        return grant
    }

    private func validCommand(
        grant: Termmesh_Peer_V1_TeamLeaderGrant,
        requestByte: UInt8
    ) -> Termmesh_Peer_V1_TeamLeaderCommandRequest {
        var request = Termmesh_Peer_V1_TeamLeaderCommandRequest()
        request.grant = grant
        request.teamUuid = grant.teamUuid
        request.requestID = Data(
            repeating: requestByte,
            count: PeerTeamLeader.requestIDBytes
        )
        request.method = "team.task.create"
        request.paramsJson = #"{"title":"one"}"#
        return request
    }

    private func XCTAssertSuccess(
        _ result: Result<Void, PeerTeamLeader.ValidationError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("expected success, got \(error)", file: file, line: line)
        }
    }

    private func XCTAssertFailure(
        _ result: Result<Void, PeerTeamLeader.ValidationError>,
        equals expected: PeerTeamLeader.ValidationError,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let actual) = result else {
            return XCTFail("expected \(expected), got success. \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }
}

private actor MutationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
