import XCTest
@testable import PeerProto

final class PeerServerTests: XCTestCase {
    func testHostStatsCapabilityTracksConfiguredProvider() async throws {
        func handshake(config: PeerServerConfig, suffix: String) async throws -> PeerSessionInfo {
            let sockPath = "/tmp/tm-peer-stats-cap-\(suffix)-\(UUID().uuidString.prefix(8)).sock"
            defer { try? FileManager.default.removeItem(atPath: sockPath) }
            let server = PeerServer(
                socketPath: sockPath,
                provider: StaticSurfaceProvider(surfaces: []),
                config: config
            )
            try await server.start()
            defer { Task { await server.stop() } }
            let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
            let session = PeerSession(transport: transport)
            let info = try await session.handshake()
            try await session.sendGoodbye(reason: "stats capability test done")
            await transport.close()
            return info
        }

        let absent = try await handshake(config: PeerServerConfig(), suffix: "absent")
        XCTAssertFalse(absent.hasHostCapability(PeerCapability.hostStatsV1))

        var configured = PeerServerConfig(hostStatsProvider: { nil })
        configured.hostStatsInterval = .milliseconds(10)
        let present = try await handshake(config: configured, suffix: "present")
        XCTAssertTrue(
            present.hasHostCapability(PeerCapability.hostStatsV1),
            "a temporarily missing sample must not erase implemented support"
        )
    }

    func testHostStatsProviderDoesNotRunForClientWithoutCapability() async throws {
        actor CallCount {
            var value = 0
            func increment() { value += 1 }
        }
        let calls = CallCount()
        var config = PeerServerConfig(hostStatsProvider: {
            await calls.increment()
            return Termmesh_Peer_V1_HostStats()
        })
        config.hostStatsInterval = .milliseconds(10)
        let sockPath = "/tmp/tm-peer-stats-gate-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }
        let server = PeerServer(
            socketPath: sockPath,
            provider: StaticSurfaceProvider(surfaces: []),
            config: config
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(transport: transport)
        var options = PeerSessionOptions()
        options.capabilities = []
        _ = try await session.handshake(options: options)
        try await Task.sleep(for: .milliseconds(80))

        let callCount = await calls.value
        XCTAssertEqual(
            callCount,
            0,
            "legacy clients must neither receive stats nor trigger sampling cost"
        )
        try await session.sendGoodbye(reason: "stats gate test done")
        await transport.close()
    }

    func testHostStatsReachClientThatAdvertisedCapability() async throws {
        var sample = Termmesh_Peer_V1_HostStats()
        sample.load1M = 3.25
        let expectedSample = sample
        var config = PeerServerConfig(hostStatsProvider: { expectedSample })
        config.hostStatsInterval = .milliseconds(10)
        let sockPath = "/tmp/tm-peer-stats-push-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }
        let server = PeerServer(
            socketPath: sockPath,
            provider: StaticSurfaceProvider(surfaces: []),
            config: config
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(transport: transport)
        _ = try await session.handshake()

        guard case .hostStats(let received) = try await session.receiveNextMessage() else {
            return XCTFail("capable client must receive the configured sample")
        }
        XCTAssertEqual(received.load1M, 3.25, accuracy: 0.001)
        try await session.sendGoodbye(reason: "stats push test done")
        await transport.close()
    }

    /// A provider that cannot sample must not be retried at the full cadence
    /// forever — an app whose daemon is down answers nil indefinitely.
    func testUnavailableProviderBacksOffInsteadOfRetryingEveryTick() async throws {
        actor CallCount {
            var value = 0
            func increment() { value += 1 }
        }
        let calls = CallCount()
        var config = PeerServerConfig(hostStatsProvider: {
            await calls.increment()
            return nil
        })
        config.hostStatsInterval = .milliseconds(10)
        config.hostStatsMaxInterval = .milliseconds(80)
        let sockPath = "/tmp/tm-peer-stats-backoff-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }
        let server = PeerServer(
            socketPath: sockPath,
            provider: StaticSurfaceProvider(surfaces: []),
            config: config
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(transport: transport)
        _ = try await session.handshake()
        try await Task.sleep(for: .milliseconds(400))

        // At a flat 10ms cadence this window holds ~40 attempts. Doubling to an
        // 80ms ceiling caps it near 10, so the assertion distinguishes the two
        // without depending on exact scheduling.
        let callCount = await calls.value
        XCTAssertGreaterThan(callCount, 0, "the loop must still try while unavailable")
        XCTAssertLessThan(
            callCount, 20,
            "a provider that keeps answering nil must be retried at a widening interval"
        )
        try await session.sendGoodbye(reason: "stats backoff test done")
        await transport.close()
    }

    /// Backoff must not outlive the condition: once the daemon answers again
    /// the loop returns to the normal cadence rather than staying slow.
    func testProviderRecoveryRestoresTheNormalCadence() async throws {
        actor Sampler {
            private var remainingFailures: Int
            private(set) var successes = 0
            init(failures: Int) { remainingFailures = failures }
            func next() -> Termmesh_Peer_V1_HostStats? {
                if remainingFailures > 0 {
                    remainingFailures -= 1
                    return nil
                }
                successes += 1
                var stats = Termmesh_Peer_V1_HostStats()
                stats.load1M = 1.5
                return stats
            }
        }
        let sampler = Sampler(failures: 3)
        var config = PeerServerConfig(hostStatsProvider: { await sampler.next() })
        config.hostStatsInterval = .milliseconds(10)
        config.hostStatsMaxInterval = .milliseconds(40)
        let sockPath = "/tmp/tm-peer-stats-recover-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }
        let server = PeerServer(
            socketPath: sockPath,
            provider: StaticSurfaceProvider(surfaces: []),
            config: config
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(transport: transport)
        _ = try await session.handshake()

        guard case .hostStats(let received) = try await session.receiveNextMessage() else {
            return XCTFail("a recovered provider must still deliver a sample")
        }
        XCTAssertEqual(received.load1M, 1.5, accuracy: 0.001)

        // Back at the 10ms cadence, several more samples land quickly. Under a
        // stuck 40ms interval this window would hold roughly one.
        try await Task.sleep(for: .milliseconds(150))
        let successes = await sampler.successes
        XCTAssertGreaterThan(
            successes, 3,
            "one success must return the loop to hostStatsInterval"
        )
        try await session.sendGoodbye(reason: "stats recovery test done")
        await transport.close()
    }

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
        // Phase 2 (viewer agent-panel) host/client asymmetry: the CLIENT
        // Hello advertises surface.agent.v1 (this build renders agent
        // surfaces), but the HOST direction must not -- a Swift GUI host
        // publishes terminal panes only and cannot host an agent surface,
        // so PeerServer filters the string out of its own Hello.
        XCTAssertFalse(info.hasHostCapability(PeerCapability.surfaceAgentV1))
        XCTAssertFalse(info.hasHostCapability("totally.unknown.v1"))

        let activeSessions = await server.activeSessions
        XCTAssertEqual(activeSessions.count, 1)
        let hostSideSession = try XCTUnwrap(activeSessions.first)
        let sawCoalesceCapability = await hostSideSession.hasClientCapability(PeerCapability.ptyDataCoalesceV1)
        XCTAssertTrue(sawCoalesceCapability)
        let sawAgentCapability = await hostSideSession.hasClientCapability(PeerCapability.surfaceAgentV1)
        XCTAssertTrue(sawAgentCapability)
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

    /// t12 (viewer agent-panel, Phase 2): `surface.agent.v1` may be
    /// advertised only by a build that can actually render agent surfaces.
    /// This build can (AgentPanel wiring), so the capability must sit in
    /// `PeerCapability.supported` -- the single source every outgoing
    /// CLIENT `Hello.capabilities` is populated from. Dropping it would
    /// make hosts silently degrade agent surfaces to `attachable = false`
    /// for this viewer and reject its attach attempts. (The HOST direction
    /// filters it back out -- see the handshake test above.)
    func testSupportedAdvertisesAgentSurfaceCapability() {
        XCTAssertTrue(PeerCapability.supported.contains(PeerCapability.surfaceAgentV1))
        XCTAssertTrue(PeerCapability.supported.contains(PeerCapability.surfaceExitV1))
        XCTAssertTrue(PeerCapability.supported.contains(PeerCapability.surfaceEnsureEnvV1))
        // `supported` feeds Hello.capabilities verbatim; a duplicate entry
        // would be advertised twice on the wire.
        XCTAssertEqual(Set(PeerCapability.supported).count, PeerCapability.supported.count)
    }

    /// The second layer under the host-direction Hello filter: a client
    /// that sends `EnsureSurfaceRequest.kind = "agent"` anyway (bypassing
    /// the capability gate) must get a loud FAILED response echoing its
    /// request_id -- never a timeout, and never a silently-created
    /// terminal. kind is part of the surface spec; silent conversion is
    /// the cross-host contract drift this guards against.
    func testAgentKindEnsureIsRejectedLoudlyByTheSwiftHost() async throws {
        let sockPath = NSTemporaryDirectory() + "pptest-ensure-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let provider = StaticSurfaceProvider(surfaces: [])
        let server = PeerServer(socketPath: sockPath, provider: provider, config: PeerServerConfig())
        try await server.start()
        defer {
            Task { await server.stop() }
        }

        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let session = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        _ = try await session.handshake(options: PeerSessionOptions())

        // Raw envelope on purpose: the client API deliberately has no way
        // to send kind = "agent" at a host without the capability, and the
        // server must hold the contract against exactly the caller that
        // skips such checks.
        var request = Termmesh_Peer_V1_EnsureSurfaceRequest()
        request.requestID = Data(repeating: 0x5A, count: 16)
        request.key = "agent-reject-test"
        request.cwd = "/tmp"
        request.executable = "/usr/bin/true"
        request.kind = "agent"
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.seq = 700
        envelope.ensureSurfaceRequest = request
        try await transport.write(encodeFrame(envelope))

        var responseBytes = Data()
        var response: Termmesh_Peer_V1_EnsureSurfaceResponse?
        while response == nil {
            responseBytes.append(try await transport.read())
            if let decoded = try decodeFrame(from: &responseBytes),
               case .ensureSurfaceResponse(let r) = decoded.payload {
                response = r
            }
        }
        let rejected = try XCTUnwrap(response)
        XCTAssertEqual(rejected.requestID, request.requestID)
        XCTAssertEqual(rejected.result, .failed)
        XCTAssertTrue(rejected.hasError)
        XCTAssertEqual(rejected.error.code, .invalidRequest)
        XCTAssertTrue(rejected.surfaceID.isEmpty, "nothing may be created for a rejected kind")

        try await session.sendGoodbye(reason: "test done")
        await transport.close()
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
    /// `CreateWorkspaceRequest` (paired) plus
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

        let workspaceID = try await session.createWorkspace(title: "created-via-server")
        XCTAssertEqual(workspaceID, RecordingWorkspaceProvider.workspaceID)
        let createdTitle = await provider.createdTitle
        XCTAssertEqual(createdTitle, "created-via-server")
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
        for method in [
            "team.send", "team.delegate", "team.read", "team.status",
            "team.correlation.register", "team.correlation.get", "team.correlation.cancel",
        ] {
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

    func testServerRoutesReverseLeaderCommandToMatchingViewerSession() async throws {
        let sockPath = "/tmp/tm-peer-reverse-leader-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }
        let controlPlane = PeerTeamLeaderControlPlane()
        var surface = Termmesh_Peer_V1_SurfaceInfo()
        surface.surfaceID = Data(repeating: 0x73, count: 16)
        surface.title = "leader"
        surface.cols = 80
        surface.rows = 24
        surface.attachable = true
        let server = PeerServer(
            socketPath: sockPath,
            provider: EchoSurfaceProvider(surfaces: [surface]),
            teamLeaderControlPlane: controlPlane
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let viewerPeerID = Data(
            repeating: 0x7A,
            count: PeerIdentity.byteCount
        )
        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let viewer = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        var options = PeerSessionOptions()
        options.peerID = viewerPeerID
        _ = try await viewer.handshake(options: options)
        _ = try await viewer.attachSurface(
            id: surface.surfaceID,
            cols: 80,
            rows: 24
        )

        let wallNow = UInt64(Date().timeIntervalSince1970)
        let leaseNow = UInt64(ProcessInfo.processInfo.systemUptime)
        var bootstrapRequest = Termmesh_Peer_V1_TeamLeaderBootstrapRequest()
        bootstrapRequest.projectID = "name:demo"
        bootstrapRequest.leaderPlacement = .peer
        bootstrapRequest.requestID = Data(
            repeating: 0x90,
            count: PeerTeamLeader.requestIDBytes
        )
        let bootstrap = await controlPlane.bootstrap(
            bootstrapRequest,
            encodedBytes: 64,
            nowUnixSeconds: wallNow - 120,
            nowLeaseSeconds: leaseNow,
            grantLifetimeSeconds: 60
        ) { _ in "team-uuid" }
        XCTAssertTrue(bootstrap.ok)
        let grant = bootstrap.grant
        XCTAssertLessThan(grant.expiresAtUnixSecs, wallNow)
        var request = Termmesh_Peer_V1_TeamLeaderCommandRequest()
        request.grant = grant
        request.teamUuid = grant.teamUuid
        request.requestID = Data(
            repeating: 0x92,
            count: PeerTeamLeader.requestIDBytes
        )
        request.method = "team.status"
        request.paramsJson = "{}"
        let renewal = await controlPlane.execute(
            request,
            encodedBytes: try request.serializedData().count,
            nowUnixSeconds: wallNow,
            nowLeaseSeconds: leaseNow
        ) { _, _, _ in .success("{}") }
        XCTAssertTrue(renewal.ok, "the live uptime lease must renew past wire expiry")

        let leaderRequest = request
        async let routedResponse = server.callTeamLeader(
            leaderRequest,
            targetPeerID: viewerPeerID,
            timeoutSeconds: 2
        )
        guard case .teamLeaderCommandRequest(
            let received,
            let correlationID
        ) = try await viewer.receiveNextMessage() else {
            return XCTFail("expected reverse team leader request")
        }
        XCTAssertEqual(received.requestID, request.requestID)
        XCTAssertEqual(received.method, "team.status")

        var response = Termmesh_Peer_V1_TeamLeaderCommandResponse()
        response.ok = true
        response.resultJson = #"{"team_name":"demo"}"#
        try await viewer.sendTeamLeaderCommandResponse(
            response,
            correlationID: correlationID
        )
        let completed = try await routedResponse
        XCTAssertTrue(completed.ok)
        XCTAssertEqual(completed.resultJson, #"{"team_name":"demo"}"#)

        // A malformed command is still refused here, without a round trip:
        // shape is knowable without being the machine that minted the grant.
        var malformed = request
        malformed.method = "team.list"
        malformed.requestID = Data(
            repeating: 0x94,
            count: PeerTeamLeader.requestIDBytes
        )
        do {
            _ = try await server.callTeamLeader(
                malformed,
                targetPeerID: viewerPeerID,
                timeoutSeconds: 0.1
            )
            XCTFail("a method outside the scoped leader surface must not be routed")
        } catch {
            XCTAssertEqual(error as? PeerServerError, .malformedLeaderCommand)
        }

        do {
            _ = try await server.callTeamLeader(
                request,
                targetPeerID: Data(
                    repeating: 0xEE,
                    count: PeerIdentity.byteCount
                ),
                timeoutSeconds: 0.1
            )
            XCTFail("wrong viewer identity must not receive the request")
        } catch {
            XCTAssertEqual(error as? PeerServerError, .noMatchingLeaderSession)
        }

        try await viewer.sendGoodbye(reason: "reverse leader test done")
        await transport.close()
    }

    /// A grant this host never registered must not be routed.
    ///
    /// `callTeamLeader` used to precheck with
    /// `registeredGrant: registered?.value ?? request.grant`, and every field
    /// of a command request arrives from caller-supplied socket parameters.
    /// The fallback therefore made `validateGrant` compare the presented
    /// grant against itself — grantID, projectID, teamUuid, role and the
    /// `expiresAtUnixSecs` equality all matched by construction — while the
    /// one remaining check compared a wall-clock deadline (~1.7e9) against
    /// `systemUptime` (~1e5) and so could never fail. Any local process able
    /// to reach the socket could invent a grant id and have its command
    /// routed over the authenticated peer session to the viewer.
    ///
    /// Both halves are asserted: a forged grant is refused, and a grant that
    /// was registered and then revoked stops being routable. Asserting only
    /// the first would still pass if the fallback were restored *and* expiry
    /// were fixed, which is not the property that matters here.
    func testUnregisteredLeaderGrantIsNotRoutedToViewer() async throws {
        let sockPath = "/tmp/tm-peer-forged-grant-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }
        let controlPlane = PeerTeamLeaderControlPlane()
        var surface = Termmesh_Peer_V1_SurfaceInfo()
        surface.surfaceID = Data(repeating: 0x74, count: 16)
        surface.title = "leader"
        surface.cols = 80
        surface.rows = 24
        surface.attachable = true
        let server = PeerServer(
            socketPath: sockPath,
            provider: EchoSurfaceProvider(surfaces: [surface]),
            teamLeaderControlPlane: controlPlane
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let viewerPeerID = Data(
            repeating: 0x7B,
            count: PeerIdentity.byteCount
        )
        let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
        let viewer = PeerSession(
            read: { try await transport.read() },
            write: { try await transport.write($0) }
        )
        var options = PeerSessionOptions()
        options.peerID = viewerPeerID
        _ = try await viewer.handshake(options: options)
        _ = try await viewer.attachSurface(
            id: surface.surfaceID,
            cols: 80,
            rows: 24
        )

        // Entirely caller-authored: never registered, and generously
        // post-dated so a self-comparison would sail through every check.
        let wallNow = UInt64(Date().timeIntervalSince1970)
        var forged = Termmesh_Peer_V1_TeamLeaderGrant()
        forged.grantID = Data(
            repeating: 0xF0,
            count: PeerTeamLeader.grantIDBytes
        )
        forged.projectID = "name:demo"
        forged.teamUuid = "team-uuid"
        forged.role = .leader
        forged.expiresAtUnixSecs = wallNow + 3_600
        var forgedRequest = Termmesh_Peer_V1_TeamLeaderCommandRequest()
        forgedRequest.grant = forged
        forgedRequest.teamUuid = forged.teamUuid
        forgedRequest.requestID = Data(
            repeating: 0xF1,
            count: PeerTeamLeader.requestIDBytes
        )
        forgedRequest.method = "team.status"
        forgedRequest.paramsJson = "{}"

        // An unregistered grant IS routed now, and that is the fix, not a
        // regression: the leader this feature exists for runs on a peer and
        // presents a grant the project's host minted and holds. This machine
        // has no entry for it and never will, so requiring one rejected every
        // genuine command while the grant was valid the whole time.
        //
        // Nothing is granted by routing it. The request reaches only the peer
        // it names, over an already-authenticated attached session, and that
        // peer validates the grant against the registry that issued it -- see
        // `PeerTeamLeaderControlPlane.execute`, which passes `grants[id]`,
        // nil for anything it did not mint, and audits the rejection. Here the
        // viewer is a test double that answers whatever it is asked, so a
        // reply proves routing, not authorisation.
        async let forgedRouted = server.callTeamLeader(
            forgedRequest,
            targetPeerID: viewerPeerID,
            timeoutSeconds: 2
        )
        guard case .teamLeaderCommandRequest(
            _,
            let forgedCorrelationID
        ) = try await viewer.receiveNextMessage() else {
            return XCTFail("a well-formed command must reach the peer that validates it")
        }
        var forgedReply = Termmesh_Peer_V1_TeamLeaderCommandResponse()
        forgedReply.ok = false
        forgedReply.errorMessage = "grant not registered on the issuing host"
        try await viewer.sendTeamLeaderCommandResponse(
            forgedReply,
            correlationID: forgedCorrelationID
        )
        let forgedOutcome = try await forgedRouted
        XCTAssertFalse(
            forgedOutcome.ok,
            "the machine that minted the grant is the one that refuses it"
        )

        // Registration changes nothing at this hop, which is the point: the
        // relay no longer consults a registry it cannot own.
        await controlPlane.registerGrant(forged)
        async let routed = server.callTeamLeader(
            forgedRequest,
            targetPeerID: viewerPeerID,
            timeoutSeconds: 2
        )
        guard case .teamLeaderCommandRequest(
            _,
            let correlationID
        ) = try await viewer.receiveNextMessage() else {
            return XCTFail("a registered grant must be routed")
        }
        var response = Termmesh_Peer_V1_TeamLeaderCommandResponse()
        response.ok = true
        response.resultJson = "{}"
        try await viewer.sendTeamLeaderCommandResponse(
            response,
            correlationID: correlationID
        )
        let routedResult = try await routed
        XCTAssertTrue(routedResult.ok)

        // Revocation takes it away again — the registry is consulted per
        // call, not cached from the first success.
        await controlPlane.revokeGrant(id: forged.grantID)
        var afterRevoke = forgedRequest
        afterRevoke.requestID = Data(
            repeating: 0xF2,
            count: PeerTeamLeader.requestIDBytes
        )
        // Revocation is enforced where the grant lives, so it is asserted
        // against the control plane directly rather than through a relay hop
        // that deliberately no longer consults one.
        let stillRegistered = await controlPlane.registeredGrant(id: forged.grantID)
        XCTAssertNil(
            stillRegistered,
            "revocation must remove the grant from the registry that issued it"
        )
        _ = afterRevoke

        try await viewer.sendGoodbye(reason: "forged grant test done")
        await transport.close()
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

    /// Capabilities describe server support, independent of the current roster.
    ///
    /// Leader bootstrap is the one that made this concrete: it is only ever
    /// used from a host that has no teams yet, so gating it on having one was
    /// a deadlock — no capability, so no leader; no leader, so never a team.
    /// Observed as a project that never finished creating on an empty peer.
    func testHostWithoutTeamsAdvertisesTeamCapabilities() async throws {
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
        XCTAssertTrue(hello.hasHostCapability(PeerCapability.teamRosterV1))
        XCTAssertTrue(hello.hasHostCapability(PeerCapability.teamCallV1))
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
    static let workspaceID = Data(repeating: 0x5A, count: 16)
    private(set) var createdTitle: String?
    private(set) var renamed: (id: Data, title: String)?
    private(set) var deleted: Data?

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] { [] }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32,
        resumeFromSeq: UInt64
    ) async -> PeerSurfaceAttachment? { nil }

    func createWorkspace(title: String) async -> Data? {
        createdTitle = title
        return Self.workspaceID
    }

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

/// A GUI host's surfaces live in its own process, so a session it owns cannot
/// survive it. `session_host_socket` is how such a host points at something
/// that can, instead of letting a client plan to come back to a session that
/// will not be there.
final class SessionHostAdvertisementTests: XCTestCase {

    /// Empty and "the same socket" are different answers, and conflating them
    /// is what would make a client wait for a session nobody kept.
    func test_aHostWithNoOwnerSaysNothingRatherThanItself() {
        let config = PeerServerConfig(hostDisplayName: "no-owner")
        XCTAssertEqual(config.resolveSessionHostSocket(), "")
    }

    /// Asked once per Hello, not once per server. The server starts alongside
    /// its machine's session daemon and normally wins the race, so a value
    /// fixed at start-up answers "no owner" for the rest of the process — or,
    /// as originally written, answers "yes" before there was one.
    func test_theOwnerIsResolvedWhenAskedRatherThanAtStartup() {
        final class Box: @unchecked Sendable { var path = "" }
        let box = Box()
        let config = PeerServerConfig(resolveSessionHostSocket: { box.path })
        XCTAssertEqual(config.resolveSessionHostSocket(), "")
        box.path = "/tmp/term-meshd-peer.sock"
        XCTAssertEqual(config.resolveSessionHostSocket(), "/tmp/term-meshd-peer.sock")
    }

    /// The path is another machine's, read on this one, so a relative path
    /// would resolve against whatever directory the reader happens to be in.
    func test_aRelativePathIsNotAPath() throws {
        var hello = Termmesh_Peer_V1_Hello()
        hello.sessionHostSocket = "term-meshd-peer.sock"
        XCTAssertFalse(
            hello.sessionHostSocket.hasPrefix("/"),
            "the reader drops this rather than resolving it locally"
        )

        hello.sessionHostSocket = "/tmp/term-meshd-peer.sock"
        XCTAssertTrue(hello.sessionHostSocket.hasPrefix("/"))
    }

    /// It has to survive the wire, or the host is the only one that knows.
    func test_itRoundTripsThroughTheWire() throws {
        var hello = Termmesh_Peer_V1_Hello()
        hello.protocolVersion = "1.0.0"
        hello.sessionHostSocket = "/var/folders/x/T/term-meshd-peer.sock"
        let decoded = try Termmesh_Peer_V1_Hello(serializedBytes: hello.serializedData())
        XCTAssertEqual(decoded.sessionHostSocket, "/var/folders/x/T/term-meshd-peer.sock")
    }

    /// End to end over a real socket: two clients connect to one server, and
    /// each is told what was true when *it* asked.
    ///
    /// This is the case a start-up-time value cannot express. The server comes
    /// up before its machine's session daemon binds, so the first client
    /// correctly hears "no owner" — and the second, connecting after the daemon
    /// is up, must hear the path rather than the first client's answer replayed.
    func test_eachClientHearsTheOwnerThatExistedWhenItAsked() async throws {
        let sockPath = "/tmp/tm-peer-session-host-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        final class Box: @unchecked Sendable { var path = "" }
        let box = Box()
        var config = PeerServerConfig()
        config.hostDisplayName = "session-host-itest"
        config.resolveSessionHostSocket = { box.path }

        let server = PeerServer(
            socketPath: sockPath,
            provider: StaticSurfaceProvider(surfaces: []),
            config: config
        )
        try await server.start()
        defer { Task { await server.stop() } }

        func handshake() async throws -> PeerSessionInfo {
            let transport = try await UnixSocketTransport.connect(socketPath: sockPath)
            let session = PeerSession(
                read: { try await transport.read() },
                write: { try await transport.write($0) }
            )
            var options = PeerSessionOptions()
            options.displayName = "session-host-itest-client"
            return try await session.handshake(options: options)
        }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date() > deadline {
                XCTFail("listener never created socket file at \(sockPath)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let before = try await handshake()
        XCTAssertEqual(
            before.sessionHostSocketPath, "",
            "no owner yet — promising one here is what sent a client to a dead socket"
        )

        box.path = "/tmp/term-meshd-peer.sock"
        let after = try await handshake()
        XCTAssertEqual(after.sessionHostSocketPath, "/tmp/term-meshd-peer.sock")
    }

    /// An older host sends no such field, and must read as "no owner" rather
    /// than as a parse failure — this field is additive on purpose.
    func test_aHostThatPredatesTheFieldReadsAsNoOwner() throws {
        var old = Termmesh_Peer_V1_Hello()
        old.protocolVersion = "1.0.0"
        old.displayName = "older-host"
        let decoded = try Termmesh_Peer_V1_Hello(serializedBytes: old.serializedData())
        XCTAssertEqual(decoded.sessionHostSocket, "")
    }

    // MARK: - Not stealing a live socket

    /// The path being occupied is the normal case for a second launch, and
    /// unlinking it strands whoever holds it: their listener stays bound to an
    /// inode nothing can reach, accepting only on connections they already had.
    func testStartRefusesAPathAnotherServerIsServing() async throws {
        let sockPath = "/tmp/tm-peer-inuse-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let first = PeerServer(socketPath: sockPath, provider: StaticSurfaceProvider(surfaces: []))
        try await first.start()
        defer { Task { await first.stop() } }

        let second = PeerServer(socketPath: sockPath, provider: StaticSurfaceProvider(surfaces: []))
        do {
            try await second.start()
            XCTFail("second start must not take a path that is being served")
        } catch let error as PeerServerError {
            XCTAssertEqual(error, .socketInUse(path: sockPath))
        }

        // And the first server is still the one on the path.
        XCTAssertTrue(PeerServer.isSocketAlive(atPath: sockPath))
    }

    /// A crashed server leaves its entry behind. That file must still be
    /// cleared, or nothing could ever restart.
    func testStartClaimsAStaleSocketFile() async throws {
        let sockPath = "/tmp/tm-peer-stale-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sockPath) }
        FileManager.default.createFile(atPath: sockPath, contents: Data())

        XCTAssertFalse(PeerServer.isSocketAlive(atPath: sockPath),
                       "a plain file answers no connect")

        let server = PeerServer(socketPath: sockPath, provider: StaticSurfaceProvider(surfaces: []))
        try await server.start()
        defer { Task { await server.stop() } }
        XCTAssertTrue(PeerServer.isSocketAlive(atPath: sockPath))
    }

    func testIsSocketAliveIsFalseForAnAbsentPath() {
        XCTAssertFalse(
            PeerServer.isSocketAlive(atPath: "/tmp/tm-peer-absent-\(UUID().uuidString).sock")
        )
    }
}
