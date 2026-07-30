import XCTest
@testable import PeerProto

final class PeerServerTests: XCTestCase {
    func testWorkspaceRosterSubscriptionReceivesInitialAndChangedSnapshots() async throws {
        let sockPath = "/tmp/tm-peer-roster-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }
        let server = PeerServer(socketPath: sockPath, provider: StaticSurfaceProvider(surfaces: []))
        try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(transport: transport)
        let info = try await session.handshake()
        XCTAssertTrue(info.hasHostCapability(PeerCapability.workspaceListSubscribeV1))

        try await session.subscribeWorkspaceList()
        guard case .workspaceListChanged(let initial) = try await session.receiveNextMessage() else {
            return XCTFail("expected initial workspace roster snapshot")
        }
        XCTAssertTrue(initial.isEmpty)

        var workspace = Termmesh_Peer_V1_Workspace()
        workspace.workspaceID = Data(repeating: 0xC4, count: 16)
        workspace.title = "New Project"
        await server.broadcastWorkspaceListChanged([workspace])
        guard case .workspaceListChanged(let changed) = try await session.receiveNextMessage() else {
            return XCTFail("expected changed workspace roster snapshot")
        }
        XCTAssertEqual(changed.map(\.title), ["New Project"])
        try await session.sendGoodbye(reason: "roster test done")
        await transport.close()
    }

    /// End-to-end: Swift `PeerServer` accepts a Swift `PeerSession`
    /// client over a real Unix socket, completes the handshake, and
    /// answers ListSurfaces with the static set we seeded. Exercises
    /// the full Swift server path that will later back term-mesh.app's
    /// peer exposure.
    func testHandshakeAndListViaSwiftServer() async throws {
        let sockPath = "/tmp/tm-peer-swift-srv-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        var alpha = Termmesh_Peer_V1_SurfaceInfo()
        alpha.surfaceID = Data(repeating: 0xA1, count: 16)
        alpha.title = "alpha"
        alpha.cols = 80
        alpha.rows = 24
        alpha.attachable = true
        alpha.cwd = "/tmp"
        alpha.branch = "main"

        var bravo = Termmesh_Peer_V1_SurfaceInfo()
        bravo.surfaceID = Data(repeating: 0xB1, count: 16)
        bravo.title = "bravo"
        bravo.cols = 132
        bravo.rows = 43
        bravo.attachable = true

        let provider = StaticSurfaceProvider(surfaces: [alpha, bravo])
        var config = PeerServerConfig()
        config.hostDisplayName = "swift-itest-server"
        config.hostAppVersion = "c3c3.1"
        let server = PeerServer(socketPath: sockPath, provider: provider, config: config)
        try await server.start()
        defer {
            Task { await server.stop() }
        }

        // Wait briefly for the socket to be reported ready by the kernel.
        // (POSIX bind+listen is synchronous, so the file already exists; this
        // just races the NWConnection's connectability check.)
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline {
                XCTFail("listener never created socket file at \(sockPath)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )

        var options = PeerSessionOptions()
        options.displayName = "swift-itest-client"
        let info = try await session.handshake(options: options)
        XCTAssertEqual(info.hostDisplayName, "swift-itest-server")
        XCTAssertEqual(info.hostAppVersion, "c3c3.1")
        XCTAssertEqual(info.hostProtocolVersion, "1.0.0")

        // P3 capability plumbing: the host's real Hello.capabilities
        // (PeerCapability.supported) must reach the client intact, and
        // the client's own advertised capabilities (also
        // PeerCapability.supported, the PeerSessionOptions default) must
        // reach the host's PeerServerSession. Real round trip through
        // real actors over a real Unix socket -- not a mock.
        XCTAssertTrue(info.hasHostCapability(PeerCapability.ptyDataCoalesceV1))
        XCTAssertTrue(info.hasHostCapability(PeerCapability.replayRingV1))
        XCTAssertFalse(info.hasHostCapability("totally.unknown.v1"))

        let activeSessions = await server.activeSessions
        XCTAssertEqual(activeSessions.count, 1)
        let hostSideSession = try XCTUnwrap(activeSessions.first)
        let sawCoalesceCapability = await hostSideSession.hasClientCapability(PeerCapability.ptyDataCoalesceV1)
        XCTAssertTrue(sawCoalesceCapability)
        let sawUnknownCapability = await hostSideSession.hasClientCapability("totally.unknown.v1")
        XCTAssertFalse(sawUnknownCapability)

        let surfaces = try await session.listSurfaces()
        XCTAssertEqual(surfaces.count, 2)
        XCTAssertEqual(surfaces.map(\.title), ["alpha", "bravo"])
        XCTAssertEqual(surfaces[0].branch, "main")

        try await session.sendGoodbye(reason: "c3c3.1-itest done")
        await transport.close()
        await server.stop()
    }

    /// P3 capability plumbing, adversarial input: a client's
    /// `Hello.capabilities` is bug/attacker-controlled input arriving
    /// straight off the wire, so the handshake must complete normally no
    /// matter what's in it -- empty (legacy peer, must behave exactly as
    /// before P3), full of capability strings this build has never heard
    /// of (forward-compat), or an absurdly long list (a buggy or hostile
    /// peer). Mirrors the Rust-side
    /// `handshake_survives_adversarial_client_capabilities` integration
    /// test in `daemon/term-meshd/src/peer/server.rs`, but exercises the
    /// real Swift `PeerServer` instead.
    func testHandshakeSurvivesAdversarialClientCapabilities() async throws {
        let sockPath = "/tmp/tm-peer-swift-caps-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let provider = StaticSurfaceProvider(surfaces: [])
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        func handshake(withCapabilities capabilities: [String]) async throws -> PeerSessionInfo {
            let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
            let session = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            var options = PeerSessionOptions()
            options.capabilities = capabilities
            let info = try await session.handshake(options: options)
            try await session.sendGoodbye(reason: "adversarial-capabilities-itest done")
            await transport.close()
            return info
        }

        // Empty: today's/legacy fallback -- must behave exactly as before P3.
        _ = try await handshake(withCapabilities: [])

        // Unknown + duplicate + empty-string entries: forward-compat, never rejected.
        _ = try await handshake(withCapabilities: [
            "totally.unknown.v1", "totally.unknown.v1", "",
        ])

        // Thousands of entries: must not slow down, hang, or crash the handshake.
        let many = (0..<5000).map { "cap.\($0).v1" }
        _ = try await handshake(withCapabilities: many)

        await server.stop()
    }

    /// Static provider returns no attachment → server replies
    /// `AttachResult(accepted: false)` → PeerSession throws
    /// `attachRejected`.
    func testStaticProviderRejectsAttach() async throws {
        let sockPath = "/tmp/tm-peer-swift-srv-err-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = Data(repeating: 0x77, count: 16)
        info.title = "listed-but-not-attachable"
        info.cols = 80
        info.rows = 24

        let provider = StaticSurfaceProvider(surfaces: [info])
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()

        do {
            _ = try await session.attachSurface(
                id: info.surfaceID,
                mode: .coWrite,
                cols: 80,
                rows: 24
            )
            XCTFail("expected attachRejected for static provider")
        } catch PeerSessionError.attachRejected(let reason) {
            XCTAssertEqual(reason, "surface not found")
        } catch {
            XCTFail("wrong error: \(error)")
        }

        await transport.close()
        await server.stop()
    }

    /// End-to-end attach round trip through an `EchoSurfaceProvider`:
    /// client attaches, writes Input, receives the same bytes back as
    /// PtyData on the same surface. Exercises `PeerServerSession`'s
    /// attach handler, relay task, and Input routing.
    func testEchoAttachRoundTrip() async throws {
        let sockPath = "/tmp/tm-peer-swift-echo-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = Data(repeating: 0xE1, count: 16)
        info.title = "echo"
        info.cols = 80
        info.rows = 24
        info.attachable = true

        let provider = EchoSurfaceProvider(surfaces: [info])
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()

        let outcome = try await session.attachSurface(
            id: info.surfaceID,
            mode: .coWrite,
            cols: 80,
            rows: 24
        )
        XCTAssertEqual(outcome.surfaceID, info.surfaceID)

        let marker = "ECHO-VIA-SWIFT-SERVER"
        try await session.sendInput(
            surfaceID: info.surfaceID,
            keys: Data(marker.utf8)
        )

        var aggregated = Data()
        let sawMarker = try await Task {
            let hardDeadline = Date().addingTimeInterval(3)
            while Date() < hardDeadline {
                let msg = try await session.receiveNextMessage()
                switch msg {
                case .ptyData(_, _, let payload):
                    aggregated.append(payload)
                    if aggregated.range(of: Data(marker.utf8)) != nil {
                        return true
                    }
                case .goodbye, .error:
                    return false
                default:
                    continue
                }
            }
            return false
        }.value
        XCTAssertTrue(
            sawMarker,
            "never observed echo of MARKER; aggregated=\(String(data: aggregated, encoding: .utf8) ?? "")"
        )

        try await session.sendGoodbye(reason: "c3c3.2 done")
        await transport.close()
        await server.stop()
    }

    /// End-to-end: real `PeerServer` dispatch of
    /// `RenameWorkspaceRequest`/`DeleteWorkspaceRequest` (fire-and-forget,
    /// per peer.proto's "Workspace lifecycle" section) reaches the
    /// provider with the exact wire arguments, and `PeerServer
    /// .broadcastWorkspaceRemoved` — the API term-mesh.app's
    /// PeerHostCoordinator calls once `TabManager.closeWorkspace`
    /// actually tears a workspace down — decodes as `.workspaceRemoved`
    /// on the client. Regression guard for the Mac host gap where these
    /// two Envelope payloads fell through the `case (.ready, _): break`
    /// catch-all despite the host already advertising
    /// "workspace.lifecycle.v1" in its Hello.capabilities.
    func testWorkspaceLifecycleReachesProviderAndBroadcastsRemoval() async throws {
        let sockPath = "/tmp/tm-peer-swift-wslc-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let provider = RecordingWorkspaceProvider()
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()

        let workspaceID = Data(repeating: 0x5A, count: 16)
        try await session.renameWorkspace(workspaceID: workspaceID, title: "renamed-via-server")
        try await session.deleteWorkspace(workspaceID: workspaceID)

        // Both RPCs are fire-and-forget on the wire; poll the provider
        // (actor-isolated) instead of asserting on an ordered reply.
        let sawBoth = await Task {
            let hardDeadline = Date().addingTimeInterval(2)
            while Date() < hardDeadline {
                if await provider.renamed != nil, await provider.deleted != nil {
                    return true
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }.value
        XCTAssertTrue(sawBoth, "provider never observed both rename and delete calls")

        let renamed = await provider.renamed
        XCTAssertEqual(renamed?.id, workspaceID)
        XCTAssertEqual(renamed?.title, "renamed-via-server")
        let deleted = await provider.deleted
        XCTAssertEqual(deleted, workspaceID)

        // Mirrors PeerHostCoordinator's install*Bridge → broadcastWorkspaceRemoved
        // call once TabManager.closeWorkspace actually tears the workspace
        // down (real app code lives outside this package, so simulate the
        // call the app layer makes after a successful delete).
        await server.broadcastWorkspaceRemoved(workspaceID: workspaceID)

        let msg = try await session.receiveNextMessage()
        guard case .workspaceRemoved(let removedID) = msg else {
            XCTFail("expected .workspaceRemoved, got \(msg)")
            return
        }
        XCTAssertEqual(removedID, workspaceID)

        try await session.sendGoodbye(reason: "workspace-lifecycle itest done")
        await transport.close()
        await server.stop()
    }

    /// R6 (peer-relay-bulk-loss, capability gating + old-peer compat): a
    /// client that never advertised `replay.ring.v1` must have any
    /// `AttachSurface.resumeFromSeq` ignored by the host — the provider
    /// only ever sees 0, i.e. a fresh full-snapshot attach, exactly as
    /// before this field had meaning. A real old client never populates
    /// the field at all (wire default 0), which already degrades to a
    /// fresh attach for free; this test additionally covers the
    /// adversarial/defensive case of a stray nonzero value arriving from a
    /// peer that never declared the capability, so it can't slip through
    /// to a provider that would otherwise honor it. Mirrors the Rust
    /// `resume_is_ignored_without_the_capability` /
    /// `effective_resume_from_seq` coverage in
    /// `daemon/term-meshd/src/peer/connection.rs`'s `resume_tests` module,
    /// but exercises it through the real Swift `PeerServer.handleAttach`
    /// gate instead of a bare function.
    func testAttachResumeFromSeqIgnoredWithoutReplayRingCapability() async throws {
        let sockPath = "/tmp/tm-peer-swift-resume-gate-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = Data(repeating: 0xC6, count: 16)
        info.title = "resume-gate"
        info.cols = 80
        info.rows = 24
        info.attachable = true

        let provider = RecordingAttachProvider(surfaces: [info])
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        var options = PeerSessionOptions()
        options.capabilities = [] // old client: never advertised replay.ring.v1
        _ = try await session.handshake(options: options)

        let outcome = try await session.attachSurface(
            id: info.surfaceID,
            cols: 80,
            rows: 24,
            resumeFromSeq: 999 // stray/adversarial nonzero without the capability
        )
        XCTAssertEqual(outcome.surfaceID, info.surfaceID)
        XCTAssertEqual(outcome.initialByteSeq, 0)

        let recorded = await provider.lastResumeFromSeq
        XCTAssertEqual(recorded, 0, "provider must never see a resume request from a peer without replay.ring.v1")

        try await session.sendGoodbye(reason: "resume-gate itest done")
        await transport.close()
        await server.stop()
    }

    /// The allow-list is the security boundary of team.call.v1: everything
    /// on it acts inside a team the host already owns, and the refusal has
    /// to happen in the server, not in each provider.
    func testTeamCallRunsAllowedMethodAndRefusesTheRest() async throws {
        let sockPath = "/tmp/tm-peer-swift-call-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let provider = TeamCallProvider()
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake()

        let allowed = try await session.callTeam(
            method: "team.send",
            paramsJSON: #"{"agent":"explorer","text":"hi"}"#
        )
        XCTAssertTrue(allowed.ok)
        XCTAssertEqual(allowed.resultJson, #"{"sent":true}"#)
        let seen = await provider.lastCall
        XCTAssertEqual(seen?.method, "team.send")

        // Creating a team takes a working directory and spawns processes —
        // exactly what a peer must not be able to reach.
        let refused = try await session.callTeam(method: "team.create", paramsJSON: "{}")
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.errorCode, PeerTeamCall.ErrorCode.methodNotAllowed)
        // The provider must never even see a refused method.
        let afterRefusal = await provider.lastCall
        XCTAssertEqual(afterRefusal?.method, "team.send")
    }

    func testTeamCallAllowListExcludesLifecycleAndSpawn() {
        for method in [
            "team.create", "team.destroy", "team.attach", "team.detach",
            "team.add_agent", "team.restart", "headless.spawn",
        ] {
            XCTAssertFalse(
                PeerTeamCall.isAllowed(method),
                "\(method) must not be reachable from a peer"
            )
        }
        for method in ["team.send", "team.delegate", "team.read", "team.status"] {
            XCTAssertTrue(PeerTeamCall.isAllowed(method))
        }
    }

    /// Full `team.leader.v1` loopback over a real Unix socket.
    ///
    /// The control plane is injected once into the server and therefore
    /// survives client reconnects. Retrying the same delegate request after
    /// reconnect must return the cached response without creating a second
    /// task, pasting text twice, or submitting a second Return. The provider's
    /// focus/selection snapshot stands in for the app-layer state that this
    /// non-focus protocol is forbidden to mutate.
    func testTeamLeaderLocalAndPeerBootstrapReconnectDelegateIsIdempotentAndFocusNeutral() async throws {
        let sockPath = "/tmp/tm-peer-swift-leader-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let provider = TeamLeaderE2EProvider()
        let controlPlane = PeerTeamLeaderControlPlane()
        let server = PeerServer(
            socketPath: sockPath,
            provider: provider,
            teamLeaderControlPlane: controlPlane
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        func connect(
            peerID: Data = PeerIdentity.defaultPeerID()
        ) async throws -> (PeerSession, UnixSocketTransport) {
            let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
            let session = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            var options = PeerSessionOptions()
            options.peerID = peerID
            let hello = try await session.handshake(options: options)
            XCTAssertTrue(hello.hasHostCapability(PeerCapability.teamLeaderV1))
            return (session, transport)
        }

        let initialSnapshot = await provider.focusSelectionSnapshot()
        let (firstSession, firstTransport) = try await connect()

        let localBootstrap = try await firstSession.bootstrapTeamLeader(
            projectID: "name:demo",
            placement: .local,
            requestID: Data(repeating: 0x31, count: PeerTeamLeader.requestIDBytes)
        )
        XCTAssertTrue(localBootstrap.ok)
        XCTAssertEqual(localBootstrap.teamUuid, "team-uuid")
        XCTAssertEqual(localBootstrap.grant.role, .leader)

        let peerBootstrap = try await firstSession.bootstrapTeamLeader(
            projectID: "name:demo",
            placement: .peer,
            requestID: Data(repeating: 0x32, count: PeerTeamLeader.requestIDBytes)
        )
        XCTAssertTrue(peerBootstrap.ok)
        XCTAssertEqual(peerBootstrap.teamUuid, "team-uuid")

        // Lifecycle remains outside the generic peer surface even when this
        // connection also holds a scoped leader grant.
        let lifecycle = try await firstSession.callTeam(
            method: "team.create",
            paramsJSON: "{}"
        )
        XCTAssertFalse(lifecycle.ok)
        XCTAssertEqual(lifecycle.errorCode, PeerTeamCall.ErrorCode.methodNotAllowed)

        let delegateRequestID = Data(
            repeating: 0x41,
            count: PeerTeamLeader.requestIDBytes
        )
        let delegateParams = #"""
        {"agent_name":"executor","text":"inspect relay","submit_return":true,"team_name":"forged"}
        """#
        let firstDelegate = try await firstSession.callTeamLeader(
            grant: peerBootstrap.grant,
            teamUUID: peerBootstrap.teamUuid,
            requestID: delegateRequestID,
            method: "team.delegate",
            paramsJSON: delegateParams
        )
        XCTAssertTrue(firstDelegate.ok)
        XCTAssertFalse(firstDelegate.cached)

        // The same grant id with a peer-forged project must reach the server
        // and be rejected against the registered grant before dispatch.
        var forgedGrant = peerBootstrap.grant
        forgedGrant.projectID = "name:other"
        let denied = try await firstSession.callTeamLeader(
            grant: forgedGrant,
            teamUUID: peerBootstrap.teamUuid,
            requestID: Data(repeating: 0x42, count: PeerTeamLeader.requestIDBytes),
            method: "team.task.create",
            paramsJSON: #"{"title":"must-not-exist"}"#
        )
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(
            denied.errorCode,
            PeerTeamLeader.ValidationError.forgedProject.rawValue
        )

        // Bypass the client's matching preflight to prove the socket server
        // independently rejects an expired wire grant before provider dispatch.
        var expiredGrant = peerBootstrap.grant
        expiredGrant.expiresAtUnixSecs = 1
        var expiredRequest = Termmesh_Peer_V1_TeamLeaderCommandRequest()
        expiredRequest.grant = expiredGrant
        expiredRequest.teamUuid = expiredGrant.teamUuid
        expiredRequest.requestID = Data(
            repeating: 0x44,
            count: PeerTeamLeader.requestIDBytes
        )
        expiredRequest.method = "team.task.create"
        expiredRequest.paramsJson = #"{"title":"must-not-exist"}"#
        var expiredEnvelope = Termmesh_Peer_V1_Envelope()
        expiredEnvelope.seq = 900
        expiredEnvelope.teamLeaderCommandRequest = expiredRequest
        try await firstTransport.write(encodeFrame(expiredEnvelope))
        var expiredResponseBytes = Data()
        var expiredResponse: Termmesh_Peer_V1_TeamLeaderCommandResponse?
        while expiredResponse == nil {
            expiredResponseBytes.append(try await firstTransport.read())
            if let envelope = try decodeFrame(from: &expiredResponseBytes),
               case .teamLeaderCommandResponse(let response) = envelope.payload {
                expiredResponse = response
            }
        }
        XCTAssertFalse(expiredResponse?.ok ?? true)
        XCTAssertEqual(
            expiredResponse?.errorCode,
            PeerTeamLeader.ValidationError.expiredGrant.rawValue
        )

        try await firstSession.sendGoodbye(reason: "force reconnect")
        await firstTransport.close()

        let (reconnectedSession, reconnectedTransport) = try await connect()
        let replayedDelegate = try await reconnectedSession.callTeamLeader(
            grant: peerBootstrap.grant,
            teamUUID: peerBootstrap.teamUuid,
            requestID: delegateRequestID,
            method: "team.delegate",
            paramsJSON: delegateParams
        )
        XCTAssertTrue(replayedDelegate.ok)
        XCTAssertTrue(replayedDelegate.cached)
        XCTAssertEqual(replayedDelegate.resultJson, firstDelegate.resultJson)

        // A different authenticated install may know the grant bytes and
        // request id, but the bootstrap audience binding still rejects it.
        let (attackerSession, attackerTransport) = try await connect(
            peerID: Data(repeating: 0xEE, count: PeerIdentity.byteCount)
        )
        let hijack = try await attackerSession.callTeamLeader(
            grant: peerBootstrap.grant,
            teamUUID: peerBootstrap.teamUuid,
            requestID: delegateRequestID,
            method: "team.delegate",
            paramsJSON: delegateParams
        )
        XCTAssertFalse(hijack.ok)
        XCTAssertEqual(
            hijack.errorCode,
            PeerTeamLeader.ValidationError.wrongAudience.rawValue
        )
        try await attackerSession.sendGoodbye(reason: "hijack refused")
        await attackerTransport.close()

        let effects = await provider.delegateEffects()
        XCTAssertEqual(effects.dispatches, 1)
        XCTAssertEqual(effects.textPastes, 1)
        XCTAssertEqual(effects.returnSubmissions, 1)
        XCTAssertEqual(effects.lastTeamUUID, "team-uuid")
        let finalSnapshot = await provider.focusSelectionSnapshot()
        XCTAssertEqual(finalSnapshot, initialSnapshot)

        try await reconnectedSession.sendGoodbye(reason: "leader e2e done")
        await reconnectedTransport.close()
        await server.stop()
    }

    /// A Mac host is where a team leader usually sits, so its roster is the
    /// answer to "where does this project's leader run" — and it only exists
    /// on the wire, never in the layout tree.
    func testTeamRosterIsServedAndGatedByCapability() async throws {
        let sockPath = "/tmp/tm-peer-swift-teams-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let provider = TeamRosterProvider(teams: [("live-team", "/Users/x/work/demo")])
        let server = PeerServer(socketPath: sockPath, provider: provider)
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        let hello = try await session.handshake()
        XCTAssertTrue(
            hello.hasHostCapability(PeerCapability.teamRosterV1),
            "a host with teams must advertise the roster capability"
        )

        let teams = try await session.listTeams()
        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams[0].name, "live-team")
        XCTAssertEqual(teams[0].projectRoot, "/Users/x/work/demo")
    }

    /// A host with no teams must not advertise the capability, or a client
    /// would ask a question it cannot usefully answer.
    func testHostWithoutTeamsDoesNotAdvertiseRoster() async throws {
        let sockPath = "/tmp/tm-peer-swift-noteams-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let server = PeerServer(socketPath: sockPath, provider: TeamRosterProvider(teams: []))
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        let hello = try await session.handshake()
        XCTAssertFalse(hello.hasHostCapability(PeerCapability.teamRosterV1))
        XCTAssertFalse(hello.hasHostCapability(PeerCapability.teamCallV1))
    }

    /// Leader bootstrap must be offered by a host with no teams, because that
    /// is the only state it is ever used from.
    ///
    /// Gating it alongside the roster capabilities deadlocked the one flow it
    /// exists for: the client refused to bootstrap because the host advertised
    /// nothing, and the host had nothing to advertise because no leader had
    /// been bootstrapped. Observed as a project that never finished creating
    /// on a peer whose team list happened to be empty.
    func testHostWithoutTeamsStillAdvertisesLeaderBootstrap() async throws {
        let sockPath = "/tmp/tm-peer-swift-leadercap-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let server = PeerServer(socketPath: sockPath, provider: TeamRosterProvider(teams: []))
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline { return XCTFail("no socket") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        let hello = try await session.handshake()
        XCTAssertTrue(
            hello.hasHostCapability(PeerCapability.teamLeaderV1),
            "an empty host must still accept a leader, or no team can ever start there"
        )
    }
}

/// Test-only `PeerSurfaceProvider` that records the `resumeFromSeq` it was
/// called with, to prove `PeerServerSession.handleAttach`'s capability gate
/// (R6, peer-relay-bulk-loss) actually reaches the provider rather than
/// just being logically correct in isolation.
private actor RecordingAttachProvider: PeerSurfaceProvider {
    private let surfaces: [Termmesh_Peer_V1_SurfaceInfo]
    private(set) var lastResumeFromSeq: UInt64?

    init(surfaces: [Termmesh_Peer_V1_SurfaceInfo]) {
        self.surfaces = surfaces
    }

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] { surfaces }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? {
        lastResumeFromSeq = resumeFromSeq
        guard surfaces.contains(where: { $0.surfaceID == surfaceID }) else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: PtyTapChunk.self)
        continuation.finish()
        return PeerSurfaceAttachment(
            byteStream: stream,
            input: { _ in },
            workspaceMeta: nil,
            initialByteSeq: 0,
            detach: {}
        )
    }

}

/// Test-only `PeerSurfaceProvider` that records `renameWorkspace`/
/// `deleteWorkspace` calls instead of driving a real workspace tree —
/// stands in for `GhosttyPaneSurfaceProvider` (app-layer, not part of
/// this package) to prove `PeerServerSession.dispatch` actually invokes
/// the provider with the wire-decoded arguments.
private actor RecordingWorkspaceProvider: PeerSurfaceProvider {
    private(set) var renamed: (id: Data, title: String)?
    private(set) var deleted: Data?

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] { [] }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? { nil }

    func renameWorkspace(id workspaceID: Data, title: String) async -> Bool {
        renamed = (workspaceID, title)
        return true
    }

    func deleteWorkspace(id workspaceID: Data) async -> Bool {
        deleted = workspaceID
        return true
    }
}

private actor TeamRosterProvider: PeerSurfaceProvider {
    private let teams: [(String, String)]

    init(teams: [(String, String)]) { self.teams = teams }

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] { [] }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? { nil }

    func listTeams() async -> [Termmesh_Peer_V1_Team] {
        teams.map { name, root in
            var team = Termmesh_Peer_V1_Team()
            team.name = name
            team.projectRoot = root
            return team
        }
    }
}

private actor TeamCallProvider: PeerSurfaceProvider {
    private(set) var lastCall: (method: String, paramsJSON: String)?

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] { [] }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? { nil }

    func listTeams() async -> [Termmesh_Peer_V1_Team] {
        var team = Termmesh_Peer_V1_Team()
        team.name = "live-team"
        return [team]
    }

    func callTeamMethod(
        _ method: String,
        paramsJSON: String
    ) async -> Result<String, PeerTeamCallFailure>? {
        lastCall = (method, paramsJSON)
        return .success(#"{"sent":true}"#)
    }
}

private actor TeamLeaderE2EProvider: PeerSurfaceProvider {
    private let projectID = "name:demo"
    private let teamUUID = "team-uuid"
    private var selectedWorkspace = "workspace-before"
    private var focusedPane = "pane-before"
    private var dispatchCount = 0
    private var textPasteCount = 0
    private var returnSubmissionCount = 0
    private var lastScopedTeamUUID: String?

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] { [] }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? { nil }

    func listTeams() async -> [Termmesh_Peer_V1_Team] {
        var team = Termmesh_Peer_V1_Team()
        team.name = "demo"
        return [team]
    }

    func resolveTeamLeaderProject(_ projectID: String) async -> String? {
        projectID == self.projectID ? teamUUID : nil
    }

    func callScopedTeamLeaderMethod(
        _ method: String,
        paramsJSON: String,
        teamUUID: String
    ) async -> Result<String, PeerTeamCallFailure>? {
        dispatchCount += 1
        lastScopedTeamUUID = teamUUID
        guard teamUUID == self.teamUUID else {
            return .failure(PeerTeamCallFailure(
                code: "wrong_scope",
                message: "unexpected authoritative team"
            ))
        }
        guard method == "team.delegate",
              let data = paramsJSON.data(using: .utf8),
              let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              params["text"] as? String == "inspect relay",
              params["submit_return"] as? Bool == true else {
            return .failure(PeerTeamCallFailure(
                code: "invalid_delegate",
                message: "delegate must atomically paste and submit"
            ))
        }
        textPasteCount += 1
        returnSubmissionCount += 1
        return .success(
            #"{"task":{"id":"task-1"},"text_delivered":true,"return_submitted":true}"#
        )
    }

    func focusSelectionSnapshot() -> String {
        "\(selectedWorkspace)|\(focusedPane)"
    }

    func delegateEffects() -> (
        dispatches: Int,
        textPastes: Int,
        returnSubmissions: Int,
        lastTeamUUID: String?
    ) {
        (
            dispatchCount,
            textPasteCount,
            returnSubmissionCount,
            lastScopedTeamUUID
        )
    }
}
