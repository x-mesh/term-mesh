import XCTest
import Darwin
import AppKit
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerPaneSessionTests: XCTestCase {

    @MainActor
    func testAdoptedProjectCleanupOwnershipSeparatesOwnerFromViewer() {
        XCTAssertTrue(TeamOrchestrator.adoptedPresentationAllowsRemoteDestruction(
            presentationOwnedByRequester: true
        ))
        XCTAssertFalse(TeamOrchestrator.adoptedPresentationAllowsRemoteDestruction(
            presentationOwnedByRequester: false
        ))
        XCTAssertTrue(TeamOrchestrator.adoptedAgentOwnsRemoteCleanup(
            presentationOwnedByRequester: true,
            surfaceType: "agent"
        ))
        XCTAssertFalse(TeamOrchestrator.adoptedAgentOwnsRemoteCleanup(
            presentationOwnedByRequester: false,
            surfaceType: "agent"
        ))
        XCTAssertFalse(TeamOrchestrator.adoptedAgentOwnsRemoteCleanup(
            presentationOwnedByRequester: true,
            surfaceType: "terminal"
        ))
        XCTAssertTrue(TeamOrchestrator.shouldPersistProjectPresentationSnapshot(
            presentationOwnedByRequester: true
        ))
        XCTAssertFalse(TeamOrchestrator.shouldPersistProjectPresentationSnapshot(
            presentationOwnedByRequester: false
        ))
        let retryDelays = TeamOrchestrator.remoteProjectManifestRetryDelaysNanoseconds
        XCTAssertFalse(retryDelays.isEmpty)
        XCTAssertEqual(retryDelays, retryDelays.sorted())
        XCTAssertLessThanOrEqual(retryDelays.reduce(0, +), 30_000_000_000)
    }

    func testRemotePresentationIdentityIncludesHostAndProjectID() {
        XCTAssertTrue(TeamOrchestrator.remotePresentationIdentityMatches(
            localHostKey: "host-a",
            localProjectID: "name:mesh-test",
            remoteHostKey: "host-a",
            remoteProjectID: "name:mesh-test"
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationIdentityMatches(
            localHostKey: "host-a",
            localProjectID: "name:mesh-test",
            remoteHostKey: "host-b",
            remoteProjectID: "name:mesh-test"
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationIdentityMatches(
            localHostKey: "host-a",
            localProjectID: "project-one",
            remoteHostKey: "host-a",
            remoteProjectID: "project-two"
        ))
    }

    func testRemoteProjectPresentationIDUsesStableUUIDInsteadOfDisplayName() {
        XCTAssertEqual(
            TeamOrchestrator.remoteProjectPresentationID(teamUUID: "uuid-a"),
            "team:uuid-a"
        )
        XCTAssertNotEqual(
            TeamOrchestrator.remoteProjectPresentationID(teamUUID: "uuid-a"),
            TeamOrchestrator.remoteProjectPresentationID(teamUUID: "uuid-b")
        )
    }

    func testRemoteProjectManifestRetriesOnlyRecoverableHostState() {
        for code in [
            "persistence_failed",
            "leader_surface_missing",
            "member_surface_missing",
            "member_surface_mismatch",
        ] {
            XCTAssertTrue(TeamOrchestrator.remoteProjectManifestShouldRetry(errorCode: code))
        }
        for code in ["not_owner", "invalid_manifest", "invalid_member"] {
            XCTAssertFalse(TeamOrchestrator.remoteProjectManifestShouldRetry(errorCode: code))
        }
    }

    @MainActor
    func testRemotePresentationAttachNeedsConnectionButNotLaunchProvenance() {
        let leaderID = Data(repeating: 0x42, count: 16)
        XCTAssertTrue(TeamOrchestrator.remotePresentationCanAttach(
            leaderSurfaceID: leaderID,
            isConnected: true,
            activeSockPath: "/tmp/direct-peer.sock"
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationCanAttach(
            leaderSurfaceID: leaderID,
            isConnected: false,
            activeSockPath: "/tmp/direct-peer.sock"
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationCanAttach(
            leaderSurfaceID: Data(),
            isConnected: true,
            activeSockPath: "/tmp/direct-peer.sock"
        ))
        XCTAssertTrue(TeamOrchestrator.shouldOfferRemoteManifest(
            hasLocalTeam: false,
            localPresentationOwnedByRequester: false,
            localRevision: 0,
            remoteRevision: 1
        ))
        XCTAssertTrue(TeamOrchestrator.shouldOfferRemoteManifest(
            hasLocalTeam: true,
            localPresentationOwnedByRequester: false,
            localRevision: 1,
            remoteRevision: 2
        ))
        XCTAssertFalse(TeamOrchestrator.shouldOfferRemoteManifest(
            hasLocalTeam: true,
            localPresentationOwnedByRequester: false,
            localRevision: 2,
            remoteRevision: 2
        ))
        XCTAssertFalse(TeamOrchestrator.shouldOfferRemoteManifest(
            hasLocalTeam: true,
            localPresentationOwnedByRequester: true,
            localRevision: 0,
            remoteRevision: 2
        ))
    }

    @MainActor
    func testRemoteManifestRefusesPartialOrMultiHostTopology() {
        func member(hostKey: String?, surfaceByte: UInt8?) -> TeamOrchestrator.AgentMember {
            TeamOrchestrator.AgentMember(
                id: UUID().uuidString,
                name: "reviewer",
                teamName: "durable-demo",
                cli: "codex",
                launchCommand: "codex",
                model: "gpt-5",
                agentType: "reviewer",
                color: "green",
                instructions: "",
                workspaceId: UUID(),
                panelId: UUID(),
                createdAt: Date(),
                remoteSurfaceID: surfaceByte.map { Data(repeating: $0, count: 16) },
                remoteSurfaceSpawned: true,
                remoteAgentSurface: true,
                hostKey: hostKey
            )
        }

        let host = "ssh:root@jw-server"
        XCTAssertTrue(TeamOrchestrator.remoteManifestCoversEveryAgent(
            [member(hostKey: host, surfaceByte: 1)],
            hostKey: host
        ))
        XCTAssertFalse(TeamOrchestrator.remoteManifestCoversEveryAgent(
            [member(hostKey: "ssh:root@another-host", surfaceByte: 2)],
            hostKey: host
        ))
        XCTAssertFalse(TeamOrchestrator.remoteManifestCoversEveryAgent(
            [member(hostKey: host, surfaceByte: nil)],
            hostKey: host
        ))
    }

    @MainActor
    func testRemoteManifestSignatureIgnoresTelemetryButTracksTopology() {
        var team = TeamOrchestrator.Team(
            id: "durable-demo",
            leaderSessionId: "leader",
            leaderMode: "claude",
            leaderModel: "",
            leaderCli: "claude",
            leaderPanelId: UUID(),
            leaderEndpoint: .peer(hostKey: "host-a"),
            workingDirectory: "/srv/demo",
            workspaceId: UUID(),
            agents: [],
            createdAt: Date(),
            worktreeMode: "off",
            teamUuid: "uuid-demo"
        )
        let initial = TeamOrchestrator.remoteProjectManifestSignature(team, hostKey: "host-a")
        team.leaderReady = true
        team.leaderFailureDescription = "telemetry only"
        XCTAssertEqual(
            initial,
            TeamOrchestrator.remoteProjectManifestSignature(team, hostKey: "host-a")
        )
        team.gitRepoRoot = "/srv/demo-v2"
        XCTAssertNotEqual(
            initial,
            TeamOrchestrator.remoteProjectManifestSignature(team, hostKey: "host-a")
        )
    }

    @MainActor
    func testOwnedRelayReconnectBackoffRetriesImmediatelyThenCapsAtThirtySeconds() {
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 1), 0)
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 2), 2)
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 3), 4)
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 6), 30)
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 20), 30)
    }

    func testRelayPalettePrefixPreservesSourceTerminalDefaults() {
        let prefix = peerTerminalPalettePrefix(
            foreground: NSColor(
                srgbRed: CGFloat(0x12) / 255,
                green: CGFloat(0x34) / 255,
                blue: CGFloat(0x56) / 255,
                alpha: 1
            ),
            background: NSColor(
                srgbRed: CGFloat(0xAB) / 255,
                green: CGFloat(0xCD) / 255,
                blue: CGFloat(0xEF) / 255,
                alpha: 1
            )
        )

        XCTAssertEqual(
            prefix,
            Data("\u{1b}]10;rgb:1212/3434/5656\u{7}\u{1b}]11;rgb:abab/cdcd/efef\u{7}".utf8)
        )
    }

    // MARK: - Reconnect surface match (terminal panes only)

    private func surface(
        id: UInt8, title: String, type: String = "terminal", attachable: Bool = true
    ) -> Termmesh_Peer_V1_SurfaceInfo {
        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = Data(repeating: id, count: 16)
        info.title = title
        info.surfaceType = type
        info.attachable = attachable
        return info
    }

    @MainActor
    func testReconnectMatchPrefersSameSurfaceIdOverSameTitle() {
        let wanted = surface(id: 1, title: "build")
        let byTitle = surface(id: 2, title: "build")
        let match = PeerClientCoordinator.reconnectSurfaceMatch(
            surfaces: [byTitle, wanted], wanted: wanted
        )
        XCTAssertEqual(match?.surfaceID, wanted.surfaceID)
    }

    /// The realistic collision: the dead terminal's title also names an agent
    /// surface. Reconnect replaces a TERMINAL pane — attaching the agent would
    /// pick callback delivery only for `openRemotePane` to refuse it, tearing
    /// the fresh session down behind a "Reconnect Failed" alert.
    @MainActor
    func testReconnectTitleFallbackSkipsAgentSurfaces() {
        let wanted = surface(id: 1, title: "reviewer")
        let agent = surface(id: 2, title: "reviewer", type: "agent")
        let terminal = surface(id: 3, title: "reviewer")
        let match = PeerClientCoordinator.reconnectSurfaceMatch(
            surfaces: [agent, terminal], wanted: wanted
        )
        XCTAssertEqual(match?.surfaceID, terminal.surfaceID)
    }

    /// When the only candidates are agent surfaces the reconnect must say
    /// "Surface Gone" rather than attach-and-refuse.
    @MainActor
    func testReconnectMatchReturnsNilWhenOnlyAgentSurfacesRemain() {
        let wanted = surface(id: 1, title: "reviewer")
        let agentSameTitle = surface(id: 2, title: "reviewer", type: "agent")
        XCTAssertNil(
            PeerClientCoordinator.reconnectSurfaceMatch(
                surfaces: [agentSameTitle], wanted: wanted
            )
        )
    }

    @MainActor
    func testReconnectMatchSkipsUnattachableSurfaces() {
        let wanted = surface(id: 1, title: "build")
        let unattachable = surface(id: 1, title: "build", attachable: false)
        XCTAssertNil(
            PeerClientCoordinator.reconnectSurfaceMatch(
                surfaces: [unattachable], wanted: wanted
            )
        )
    }

    private final class RunnerMockHost: @unchecked Sendable {
        enum Failure: Error {
            case syscall(String, Int32)
            case unexpectedMessage(String)
            case timedOut(String)
        }

        let socketPath: String
        let surfaceID = Data(repeating: 0xA5, count: 16)
        private let lock = NSLock()
        private var listenerFD: Int32 = -1
        private var clientFDs: Set<Int32> = []
        private var attachedSurfaceIDs: [Data] = []
        /// Set when the listener starts, not when this object is built, and
        /// generous on purpose. Its job is to stop a wedged test hanging
        /// forever — not to assert how fast the machine is. At eight seconds
        /// from construction it was doing the latter: the XCTest host here is
        /// the whole term-mesh app, a passing run already spent ~6s of the
        /// budget, and on a loaded machine the host gave up mid-handshake and
        /// closed the listener, which the client then saw as ENOTCONN.
        private var deadline: Date = .distantFuture
        private static let listenerBudget: TimeInterval = 120

        init(socketPath: String) {
            self.socketPath = socketPath
        }

        func start() throws -> Task<Void, Error> {
            deadline = Date().addingTimeInterval(Self.listenerBudget)
            unlink(socketPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.syscall("socket", errno) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socketPath.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.count < capacity else {
                close(fd)
                throw Failure.syscall("socket path", ENAMETOOLONG)
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                    for (offset, byte) in path.enumerated() {
                        bytes[offset] = CChar(bitPattern: byte)
                    }
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else {
                let code = errno
                close(fd)
                throw Failure.syscall("bind", code)
            }
            guard listen(fd, 2) == 0 else {
                let code = errno
                close(fd)
                throw Failure.syscall("listen", code)
            }
            listenerFD = fd
            return Task.detached { [self] in
                defer {
                    finishListener(fd)
                }
                for launchIndex in 0..<2 {
                    try waitForEvent(fd: fd, event: Int16(POLLIN), operation: "accept")
                    let client = Darwin.accept(fd, nil, nil)
                    guard client >= 0 else { throw Failure.syscall("accept", errno) }
                    registerClient(client)
                    defer {
                        unregisterClient(client)
                        close(client)
                    }
                    try handle(client: client, launchIndex: launchIndex)
                }
            }
        }

        func stop() {
            lock.lock()
            let fd = listenerFD
            listenerFD = -1
            let clients = clientFDs
            lock.unlock()
            for client in clients {
                Darwin.shutdown(client, SHUT_RDWR)
            }
            if fd >= 0 {
                Darwin.shutdown(fd, SHUT_RDWR)
                close(fd)
            }
            unlink(socketPath)
        }

        private func finishListener(_ fd: Int32) {
            lock.lock()
            let ownsListener = listenerFD == fd
            if ownsListener { listenerFD = -1 }
            lock.unlock()
            if ownsListener { close(fd) }
            unlink(socketPath)
        }

        func attachedIDs() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return attachedSurfaceIDs
        }

        func remainingDeadlineNanoseconds() -> UInt64 {
            UInt64(max(deadline.timeIntervalSinceNow, 0) * 1_000_000_000)
        }

        private func registerClient(_ fd: Int32) {
            lock.lock()
            clientFDs.insert(fd)
            lock.unlock()
        }

        private func unregisterClient(_ fd: Int32) {
            lock.lock()
            clientFDs.remove(fd)
            lock.unlock()
        }

        private func waitForEvent(fd: Int32, event: Int16, operation: String) throws {
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw Failure.timedOut(operation) }
                var descriptor = pollfd(fd: fd, events: event, revents: 0)
                let timeoutMS = Int32(min(remaining * 1_000, Double(Int32.max)))
                let result = Darwin.poll(&descriptor, 1, timeoutMS)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else {
                    if result == 0 { throw Failure.timedOut(operation) }
                    throw Failure.syscall("poll \(operation)", errno)
                }
                guard descriptor.revents & event != 0 else {
                    throw Failure.syscall("poll \(operation)", ECONNRESET)
                }
                return
            }
        }

        private func handle(client: Int32, launchIndex: Int) throws {
            guard case .hello = try readEnvelope(client).payload else {
                throw Failure.unexpectedMessage("expected Hello")
            }
            var hello = Termmesh_Peer_V1_Hello()
            hello.protocolVersion = "1.0.0"
            hello.peerID = Data(repeating: 0x11, count: 16)
            hello.displayName = "runner-mock"
            hello.appVersion = "test"
            hello.capabilities = [PeerCapability.surfaceEnsureV1]
            try send(client) { $0.hello = hello }

            var challenge = Termmesh_Peer_V1_AuthChallenge()
            challenge.nonce = Data(repeating: 0x22, count: 32)
            challenge.supportedMethods = ["ssh-passthrough"]
            try send(client) { $0.authChallenge = challenge }
            guard case .auth = try readEnvelope(client).payload else {
                throw Failure.unexpectedMessage("expected Auth")
            }
            var authResult = Termmesh_Peer_V1_AuthResult()
            authResult.accepted = true
            authResult.sessionID = Data(repeating: UInt8(launchIndex + 1), count: 16)
            try send(client) { $0.authResult = authResult }

            guard case .ensureSurfaceRequest(let ensure) = try readEnvelope(client).payload else {
                throw Failure.unexpectedMessage("expected EnsureSurfaceRequest")
            }
            guard ensure.key == "runner:build:SECRET_KEY", ensure.cwd == "/app/runner" else {
                throw Failure.unexpectedMessage("unexpected runner spec")
            }
            var ensured = Termmesh_Peer_V1_EnsureSurfaceResponse()
            ensured.requestID = ensure.requestID
            ensured.result = launchIndex == 0 ? .created : .reused
            ensured.surfaceID = surfaceID
            ensured.instanceID = Data(repeating: 0xB6, count: 16)
            ensured.generation = 1
            ensured.pid = 4242
            ensured.specHash = Data(repeating: 0xC7, count: 32)
            try send(client) { $0.ensureSurfaceResponse = ensured }

            guard case .attachSurface(let attach) = try readEnvelope(client).payload else {
                throw Failure.unexpectedMessage("expected AttachSurface")
            }
            lock.lock()
            attachedSurfaceIDs.append(attach.surfaceID)
            lock.unlock()
            var attached = Termmesh_Peer_V1_AttachResult()
            attached.accepted = true
            attached.surfaceID = attach.surfaceID
            attached.grantedMode = attach.mode
            try send(client) { $0.attachResult = attached }
        }

        private func send(
            _ fd: Int32,
            configure: (inout Termmesh_Peer_V1_Envelope) -> Void
        ) throws {
            var envelope = Termmesh_Peer_V1_Envelope()
            configure(&envelope)
            try writeAll(fd, try encodeFrame(envelope))
        }

        private func readEnvelope(_ fd: Int32) throws -> Termmesh_Peer_V1_Envelope {
            var prefix = Data(count: 4)
            try readAll(fd, into: &prefix)
            let length = Int(prefix.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            })
            var payload = Data(count: length)
            try readAll(fd, into: &payload)
            var frame = prefix + payload
            guard let envelope = try decodeFrame(from: &frame) else {
                throw Failure.unexpectedMessage("incomplete frame")
            }
            return envelope
        }

        private func readAll(_ fd: Int32, into data: inout Data) throws {
            var offset = 0
            let totalCount = data.count
            while offset < totalCount {
                try waitForEvent(fd: fd, event: Int16(POLLIN), operation: "read")
                let count = data.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress! + offset, totalCount - offset)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.syscall("read", errno) }
                offset += count
            }
        }

        private func writeAll(_ fd: Int32, _ data: Data) throws {
            var offset = 0
            while offset < data.count {
                try waitForEvent(fd: fd, event: Int16(POLLOUT), operation: "write")
                let count = data.withUnsafeBytes {
                    Darwin.write(fd, $0.baseAddress! + offset, data.count - offset)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.syscall("write", errno) }
                offset += count
            }
        }
    }

    private func awaitHostCompletion(
        _ task: Task<Void, Error>,
        host: RunnerMockHost
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(nanoseconds: host.remainingDeadlineNanoseconds())
                throw RunnerMockHost.Failure.timedOut("host task")
            }
            defer { group.cancelAll() }
            do {
                _ = try await group.next()
            } catch {
                host.stop()
                task.cancel()
                throw error
            }
        }
    }

    // MARK: - Host key identity

    func test_hostKey_identityAndLabels() {
        let ssh = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/tm-peer.sock", port: nil, identityFile: nil)
        XCTAssertEqual(ssh.hostKey, .ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/tm-peer.sock", port: nil))
        XCTAssertEqual(ssh.hostKey.description, "ssh:root@jw-server:/run/user/0/tm-peer.sock")
        XCTAssertEqual(ssh.hostKey.shortLabel, "jw-server")
        XCTAssertEqual(ssh.hostKey.sshTarget, "root@jw-server")

        let direct = PeerPaneHostSpec.direct(sockPath: "/tmp/term-mesh-peer-501/peer.sock")
        XCTAssertEqual(direct.hostKey, .direct(sockPath: "/tmp/term-mesh-peer-501/peer.sock"))
        XCTAssertEqual(direct.hostKey.shortLabel, "peer.sock")
        XCTAssertNil(direct.hostKey.sshTarget)
    }

    func test_hostKey_sshDistinguishesRemoteSockPaths() {
        // One machine can host several daemons on different sockets —
        // pooling them onto one tunnel would connect a pane to the wrong
        // peer (cross-vendor panel finding, 2026-07-15). Same target +
        // same remote socket still pools.
        let a = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/a.sock", port: nil, identityFile: nil)
        let b = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/b.sock", port: nil, identityFile: nil)
        let a2 = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/a.sock", port: nil, identityFile: nil)
        XCTAssertNotEqual(a.hostKey, b.hostKey)
        XCTAssertEqual(a.hostKey, a2.hostKey)
    }

    // MARK: - Host accent determinism

    func test_hostAccent_isDeterministicPerHost() {
        let key = PeerPaneHostKey.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/tm-peer.sock", port: nil)
        XCTAssertEqual(PeerHostAccent.colors(for: key), PeerHostAccent.colors(for: key))
        XCTAssertEqual(
            PeerHostAccent.primaryColor(for: key),
            PeerHostAccent.primaryColor(for: key)
        )
    }

    // MARK: - Registry refcount (direct lease — no tunnel process)

    @MainActor
    func test_registry_refcountLifecycle() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-refcount.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        XCTAssertNil(registry.activeLease(forKey: key))

        let lease1 = try await registry.acquire(spec)
        XCTAssertTrue(registry.activeLease(forKey: key) === lease1)
        XCTAssertEqual(lease1.hostSockPath, sockPath)

        // Second acquire pools the same lease.
        let lease2 = try await registry.acquire(spec)
        XCTAssertTrue(lease1 === lease2)

        // First release keeps the lease alive (refcount 2 → 1)…
        registry.release(lease1)
        XCTAssertTrue(registry.activeLease(forKey: key) === lease1)

        // …retain bumps it back, so two releases are needed…
        registry.retain(lease1)
        registry.release(lease1)
        XCTAssertNotNil(registry.activeLease(forKey: key))

        // …and the final release removes it from the pool.
        registry.release(lease1)
        XCTAssertNil(registry.activeLease(forKey: key))
    }

    /// Disconnect retires the transport even while panes still hold refs.
    /// Their delayed teardown must not evict a replacement lease acquired by
    /// Reconnect for the same host key.
    @MainActor
    func test_registry_disconnectKeepsOldRefsButProtectsReplacementLease() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-disconnect.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        XCTAssertNil(registry.activeLease(forKey: key))
        let teardownsBefore = registry.teardownCountForTests

        let retired = try await registry.acquire(spec)
        registry.retain(retired) // sidebar + preserved pane
        XCTAssertEqual(registry.disconnectTransport(for: key), sockPath)
        XCTAssertNil(registry.activeLease(forKey: key))
        XCTAssertEqual(registry.teardownCountForTests, teardownsBefore + 1)

        let replacement = try await registry.acquire(spec)
        XCTAssertFalse(replacement === retired)
        XCTAssertTrue(registry.activeLease(forKey: key) === replacement)

        registry.release(retired)
        registry.release(retired)
        XCTAssertTrue(
            registry.activeLease(forKey: key) === replacement,
            "a retired pane lease must not remove the reconnect lease"
        )
        XCTAssertEqual(
            registry.teardownCountForTests,
            teardownsBefore + 1,
            "the retired transport must stop exactly once"
        )

        registry.release(replacement)
        XCTAssertNil(registry.activeLease(forKey: key))
        XCTAssertEqual(registry.teardownCountForTests, teardownsBefore + 2)
    }

    @MainActor
    func test_transportRecovery_coalescesStaleGenerationAndAllowsNextIncident() async {
        let recovery = PeerPaneTransportRecovery()
        var refreshCount = 0

        let first = await recovery.refresh(after: 0) { refreshCount += 1; return true }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(refreshCount, 1)

        // A sibling attached through generation 0 reports the same outage
        // after the first pane already refreshed it. It must join generation
        // 1 without restarting the replacement transport.
        let sibling = await recovery.refresh(after: 0) { refreshCount += 100; return true }
        XCTAssertEqual(sibling, 1)
        XCTAssertEqual(refreshCount, 1)

        // A later failure of generation 1 is a new incident and gets one new
        // refresh of its own.
        let next = await recovery.refresh(after: first) { refreshCount += 1; return true }
        XCTAssertEqual(next, 2)
        XCTAssertEqual(refreshCount, 2)
    }

    /// Pane, live mirror and sidebar roster all report the same pooled SSH
    /// generation when one tunnel stalls. Every consumer must join the first
    /// refresh; otherwise the second heartbeat kills the replacement tunnel.
    @MainActor
    func test_transportRecovery_coalescesPaneMirrorAndSidebarFailure() async {
        let recovery = PeerPaneTransportRecovery()
        var refreshCount = 0

        async let pane = recovery.refresh(after: 0) { refreshCount += 1; return true }
        async let mirror = recovery.refresh(after: 0) { refreshCount += 1; return true }
        async let sidebar = recovery.refresh(after: 0) { refreshCount += 1; return true }
        let generations = await [pane, mirror, sidebar]

        XCTAssertEqual(generations, [1, 1, 1])
        XCTAssertEqual(refreshCount, 1)
    }

    /// A consumer can attach after the generation counter advances but before
    /// that transport restart finishes. Reporting its failure with the current
    /// generation must join the in-flight restart, not start another one.
    @MainActor
    func test_transportRecovery_currentGenerationJoinsInFlightRefresh() async {
        let recovery = PeerPaneTransportRecovery()
        var refreshCount = 0
        var releaseRefresh: CheckedContinuation<Void, Never>?

        let firstTask = Task { @MainActor in
            await recovery.refresh(after: 0) {
                refreshCount += 1
                await withCheckedContinuation { releaseRefresh = $0 }
                return true
            }
        }
        while releaseRefresh == nil { await Task.yield() }

        let observedGeneration = recovery.generation
        let siblingTask = Task { @MainActor in
            await recovery.refresh(after: observedGeneration) { refreshCount += 100; return true }
        }
        await Task.yield()
        XCTAssertEqual(refreshCount, 1)

        releaseRefresh?.resume()
        let generations = await [firstTask.value, siblingTask.value]
        XCTAssertEqual(generations, [1, 1])
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func test_transportRecovery_failureKeepsGenerationRetryable() async {
        let recovery = PeerPaneTransportRecovery()
        var refreshCount = 0

        let failed = await recovery.refresh(after: 0) {
            refreshCount += 1
            return false
        }
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(recovery.generation, 0)

        let retried = await recovery.refresh(after: 0) {
            refreshCount += 1
            return true
        }
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(refreshCount, 2)
    }

    func test_transportRecovery_failedStoppedAndTimeoutAreNotSuccess() {
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(
                for: .failed(reason: "unreachable"), sawRestart: true, timedOut: false
            ),
            false
        )
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(
                for: .stopped, sawRestart: true, timedOut: false
            ),
            false
        )
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(
                for: .reconnecting(attempt: 1), sawRestart: true, timedOut: true
            ),
            false
        )
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(
                for: .up, sawRestart: true, timedOut: false
            ),
            true
        )
        XCTAssertNil(
            PeerPaneHostLease.recoveryResult(
                for: .reconnecting(attempt: 1), sawRestart: true, timedOut: false
            )
        )
        // The pre-restart `.up` the poll loop exists to reject: `forceReconnect`
        // has been called but the tunnel has not left `.up` yet, so nothing has
        // been observed that could count as a completed recovery. Without this
        // row, dropping `sawRestart` from the first guard keeps every other
        // assertion above green while this input silently flips nil -> true.
        XCTAssertNil(
            PeerPaneHostLease.recoveryResult(
                for: .up, sawRestart: false, timedOut: false
            )
        )
    }

    /// PR255 follow-up regression (logic-1, Medium): `forceReconnect` can report
    /// "scheduled" for a restart that was already in flight (see
    /// `PeerSSHTunnel.forceReconnect`'s `restartTask != nil` early return). If
    /// that restart finishes before the poller in `refreshTransport` takes its
    /// first read, the tunnel reads `.up` for the entire poll window and
    /// `sawRestart` never flips true. Timing out on that state must still count
    /// as recovered, not as a failure — misclassifying it leaves the generation
    /// un-bumped, so the next sibling failure report re-runs `forceReconnect`
    /// and kills the (already healthy) replacement tunnel.
    func test_recoveryResult_joinedInFlightRestartThatWasAlreadyUpCountsAsRecovered() {
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(for: .up, sawRestart: false, timedOut: true),
            true
        )
    }

    /// Drains queued main-actor work until `condition` holds.
    ///
    /// The cancellation tests below assert on a flag a *different* task sets,
    /// and awaiting the caller does not order that: `cancelWaiter` resumes the
    /// waiting caller BEFORE it calls `refresh.task.cancel()`, and cancelling
    /// the action task only schedules the sleeping `Task.sleep` to throw. So
    /// `await owner.value` can resolve one or more hops before the action's
    /// catch block runs. Asserting straight after the await is a coin flip —
    /// it is what made `test_transportRecovery_cancelledOwnerClearsSlotForRetry`
    /// fail on the mac-sub runner while passing under casual local reads.
    @MainActor
    private func waitFor(
        _ condition: () -> Bool,
        yields: Int = 1_000
    ) async -> Bool {
        for _ in 0..<yields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @MainActor
    func test_transportRecovery_cancelledOwnerClearsSlotForRetry() async {
        let recovery = PeerPaneTransportRecovery()
        var actionStarted = false
        var actionWasCancelled = false

        let owner = Task { @MainActor in
            await recovery.refresh(after: 0) {
                actionStarted = true
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return true
                } catch is CancellationError {
                    actionWasCancelled = true
                    return false
                } catch {
                    return false
                }
            }
        }
        while !actionStarted { await Task.yield() }
        owner.cancel()
        let cancelledGeneration = await owner.value
        XCTAssertEqual(cancelledGeneration, 0)
        let actionCancelled = await waitFor({ actionWasCancelled })
        XCTAssertTrue(
            actionCancelled,
            "owner cancellation must reach the in-flight refresh action"
        )

        let retried = await recovery.refresh(after: 0) { true }
        XCTAssertEqual(retried, 1)
    }

    @MainActor
    func test_transportRecovery_cancelledWaiterDoesNotCancelSharedOwner() async {
        let recovery = PeerPaneTransportRecovery()
        var releaseRefresh: CheckedContinuation<Void, Never>?

        let owner = Task { @MainActor in
            await recovery.refresh(after: 0) {
                await withCheckedContinuation { releaseRefresh = $0 }
                return true
            }
        }
        while releaseRefresh == nil { await Task.yield() }
        let waiter = Task { @MainActor in
            await recovery.refresh(after: 0) { XCTFail("waiter ran duplicate action"); return true }
        }
        await Task.yield()
        waiter.cancel()
        let cancelledGeneration = await waiter.value
        XCTAssertEqual(cancelledGeneration, 0)

        releaseRefresh?.resume()
        let recoveredGeneration = await owner.value
        XCTAssertEqual(recoveredGeneration, 1)
        XCTAssertEqual(recovery.generation, 1)
    }

    /// `cancel()` is wired into `PeerPaneHostLease.teardown()` so a pane closed
    /// mid-recovery releases every caller waiting on `refreshTransport()`
    /// instead of leaving them parked forever. The cancelled-owner and
    /// cancelled-waiter tests above only exercise `cancelWaiter()` via
    /// `Task.cancel()` on one caller; this drives `cancel()` itself, covering
    /// the owner, a joined waiter, that the shared refresh task is actually
    /// cancelled, that the slot is cleared for a fresh attempt, and that later
    /// recovery still works.
    @MainActor
    func test_transportRecovery_cancelResumesOwnerAndWaiterAndClearsSlotForRetry() async {
        let recovery = PeerPaneTransportRecovery()
        var actionStarted = false
        var actionWasCancelled = false

        let owner = Task { @MainActor in
            await recovery.refresh(after: 0) {
                actionStarted = true
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return true
                } catch is CancellationError {
                    actionWasCancelled = true
                    return false
                } catch {
                    return false
                }
            }
        }
        while !actionStarted { await Task.yield() }

        let waiter = Task { @MainActor in
            await recovery.refresh(after: 0) {
                XCTFail("waiter must not run a duplicate action")
                return true
            }
        }
        await Task.yield()

        let preCancelGeneration = recovery.generation
        recovery.cancel()

        let ownerResult = await owner.value
        let waiterResult = await waiter.value
        XCTAssertEqual(
            ownerResult, preCancelGeneration,
            "cancel() must resume the owner with the pre-cancel generation"
        )
        XCTAssertEqual(
            waiterResult, preCancelGeneration,
            "cancel() must resume every waiter with the pre-cancel generation"
        )
        XCTAssertEqual(recovery.generation, preCancelGeneration, "cancel() must not advance the generation")

        var retryCount = 0
        let retried = await recovery.refresh(after: preCancelGeneration) {
            retryCount += 1
            return true
        }
        XCTAssertEqual(
            retryCount, 1,
            "a later report must start a fresh refresh, not join the cancelled slot"
        )
        XCTAssertEqual(
            retried, preCancelGeneration + 1,
            "recovery after cancel() must still be able to advance the generation"
        )
        let actionCancelled = await waitFor({ actionWasCancelled })
        XCTAssertTrue(
            actionCancelled,
            "cancel() must cancel the shared in-flight refresh task"
        )
    }

    func test_forceReconnectDoesNotRearmStoppedTunnel() {
        let tunnel = PeerSSHTunnel(
            sshTarget: "example.invalid",
            remoteSockPath: "/tmp/peer.sock"
        )

        XCTAssertFalse(tunnel.forceReconnect(reason: "late failure"))
        XCTAssertEqual(tunnel.currentState, .stopped)
    }

    /// The case above only proves `forceReconnect` refuses a tunnel that was
    /// never started — `wantsRunning` is false there for the trivial reason
    /// that nothing ever set it. The regression the guard exists for is the
    /// armed-then-retired one named in its own source comment: "a late
    /// pane/mirror heartbeat must never re-arm a tunnel its lease retired."
    ///
    /// `retry()` arms the tunnel without touching the network: it sets
    /// `wantsRunning` and installs a restart task whose first attempt sleeps a
    /// second before it would ever call `spawnOnce()`, and `stop()` cancels
    /// that task well inside the second.
    func test_forceReconnectDoesNotRearmRetiredTunnel() {
        let tunnel = PeerSSHTunnel(
            sshTarget: "example.invalid",
            remoteSockPath: "/tmp/peer.sock"
        )

        tunnel.retry()
        XCTAssertTrue(
            tunnel.forceReconnect(reason: "live failure"),
            "an armed tunnel must accept a reconnect, otherwise the case below proves nothing"
        )

        tunnel.stop()

        XCTAssertFalse(
            tunnel.forceReconnect(reason: "late failure after stop"),
            "a heartbeat landing after stop() must not re-arm a retired tunnel"
        )
        // Idempotent: a retired tunnel stays retired however often it is asked.
        XCTAssertFalse(tunnel.forceReconnect(reason: "later failure after stop"))

        // `currentState` is deliberately not asserted here. `stop()` does emit
        // `.stopped` synchronously, but the restart task `retry()` armed can
        // still deliver its own queued `.down` afterwards, so the state read is
        // ordering-dependent in a way the return value is not.
    }

    /// Reattach-on-reconnect is for panes a person chose to disconnect. An
    /// accidental transport loss has recovery of its own, and reattaching it
    /// here too would rebuild the pane twice for one failure.
    @MainActor
    func test_reattachAfterHostReconnect_onlyForPanesADeliberateDisconnectKept() {
        let host = PeerPaneHostSpec.direct(sockPath: "/tmp/psp-unit-reattach.sock").hostKey
        let otherHost = PeerPaneHostSpec.direct(sockPath: "/tmp/psp-unit-other.sock").hostKey

        XCTAssertTrue(
            PeerClientCoordinator.shouldReattachAfterHostReconnect(
                leaseKey: host, reconnectedHost: host,
                hostTransportWasDisconnected: true, isTorndown: false
            )
        )
        XCTAssertFalse(
            PeerClientCoordinator.shouldReattachAfterHostReconnect(
                leaseKey: otherHost, reconnectedHost: host,
                hostTransportWasDisconnected: true, isTorndown: false
            ),
            "another host coming back says nothing about this pane"
        )
        XCTAssertFalse(
            PeerClientCoordinator.shouldReattachAfterHostReconnect(
                leaseKey: host, reconnectedHost: host,
                hostTransportWasDisconnected: false, isTorndown: false
            ),
            "an accidental drop already recovers on its own"
        )
        XCTAssertFalse(
            PeerClientCoordinator.shouldReattachAfterHostReconnect(
                leaseKey: host, reconnectedHost: host,
                hostTransportWasDisconnected: true, isTorndown: true
            ),
            "a torn-down pane has nothing to reattach"
        )
    }

    @MainActor
    func test_registry_concurrentFirstAcquireYieldsOneLease() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-race.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)

        async let a = registry.acquire(spec)
        async let b = registry.acquire(spec)
        let (leaseA, leaseB) = try await (a, b)
        XCTAssertTrue(leaseA === leaseB, "concurrent first-acquires must pool one lease")

        registry.release(leaseA)
        registry.release(leaseB)
        XCTAssertNil(registry.activeLease(forKey: spec.hostKey))
    }

    /// The coalesced start task is shared by every pane waiting on the host, so
    /// one pane's sidebar Cancel must not abort it — that would kill the other
    /// panes' connect too. It may only be cancelled by the last waiter.
    @MainActor
    func test_cancelPendingAcquire_refusesWhileAnotherPaneIsWaiting() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-shared-cancel.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        XCTAssertNil(registry.activeLease(forKey: key))

        var waitersAtCancel = 0
        var pendingSurvivedCancel = false

        // Queued in order on the main actor: both acquires park on the same
        // start task before the cancel runs.
        let paneA = Task { @MainActor in try await registry.acquire(spec) }
        let paneB = Task { @MainActor in try await registry.acquire(spec) }
        let sidebarCancel = Task { @MainActor in
            waitersAtCancel = registry.pendingWaiterCountForTests(for: key)
            registry.cancelPendingAcquire(for: key)
            pendingSurvivedCancel = registry.pendingWaiterCountForTests(for: key) > 0
        }

        _ = await sidebarCancel.value
        let leaseA = try await paneA.value
        let leaseB = try await paneB.value

        XCTAssertEqual(waitersAtCancel, 2, "both panes must be parked on one start task")
        XCTAssertTrue(pendingSurvivedCancel, "a shared start must survive one pane's cancel")
        XCTAssertTrue(leaseA === leaseB)
        XCTAssertNotNil(registry.activeLease(forKey: key), "the other pane must keep its lease")

        registry.release(leaseA)
        registry.release(leaseB)
        XCTAssertNil(registry.activeLease(forKey: key))
        XCTAssertEqual(registry.pendingWaiterCountForTests(for: key), 0, "waiter accounting must not leak")
    }

    /// A caller cancelled *after* the start task already produced a lease must
    /// not leave that lease unowned: `makeLease` has spawned the tunnel by then,
    /// and nothing else would ever stop it.
    @MainActor
    func test_registry_cancelledAcquireTearsDownInsteadOfOrphaning() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-cancel.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        XCTAssertNil(registry.activeLease(forKey: key))
        let teardownsBefore = registry.teardownCountForTests

        // The test holds the main actor until it awaits, so the cancel always
        // lands before `acquire` starts running.
        let acquisition = Task { @MainActor in try await registry.acquire(spec) }
        acquisition.cancel()

        do {
            _ = try await acquisition.value
            XCTFail("a cancelled acquire must not return a lease")
        } catch is CancellationError {
            // expected
        }

        XCTAssertNil(registry.activeLease(forKey: key), "cancelled acquire must leave the pool empty")
        XCTAssertEqual(
            registry.teardownCountForTests,
            teardownsBefore + 1,
            "the already-created lease must be torn down, not orphaned"
        )
    }

    @MainActor
    func test_savedRunnerRepeatedLaunchReusesExactEnsuredSurfaceID() async throws {
        // Attaching spawns term-mesh-peer-relay out of the app bundle, and the
        // Rust binaries are copied in by reload.sh / reloadp.sh / reloads.sh —
        // not by an Xcode build phase. A plain `xcodebuild test` therefore
        // produces a bundle without it and this test could never pass there; it
        // failed as an opaque ENOTCONN, because the mock host closed its
        // listener while the client was failing on the missing binary.
        let relay = Bundle.main.resourceURL?
            .appendingPathComponent("bin/term-mesh-peer-relay").path
        try XCTSkipUnless(
            relay.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false,
            "needs term-mesh-peer-relay in the app bundle — run through reload.sh, not a bare xcodebuild"
        )

        let socketPath = "/tmp/peer-runner-test-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = RunnerMockHost(socketPath: socketPath)
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }
        let surface = PeerRunnerSurfaceSpec(
            key: "runner:build:SECRET_KEY",
            cwd: "/app/runner",
            executable: "/SECRET_EXECUTABLE/bin/sh",
            args: ["-lc", "exec make test --token=SECRET_ARGUMENT"]
        )
        let attachment = PeerRunnerAttachment(title: "Build Runner", cols: 120, rows: 36)

        // The mock host runs in a detached Task nobody awaits, so when it
        // rejects a step it just closes the socket and the client reports
        // ENOTCONN — the same opaque symptom no matter what actually went
        // wrong. Report the host's own reason alongside the client's.
        func mockHostReason() async -> String {
            do {
                try await hostTask.value
                return "host finished without error"
            } catch {
                return String(describing: error)
            }
        }

        let first: (session: PeerPaneSession, outcome: PeerEnsureSurfaceOutcome)
        do {
            first = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: surface,
                attachment: attachment,
                hostSpec: hostSpec
            )
        } catch {
            XCTFail("first ensureAndAttach failed: \(error) — mock host: \(await mockHostReason())")
            return
        }
        defer { first.session.teardown() }
        let second = try await PeerPaneSession.ensureAndAttach(
            lease: lease,
            surfaceSpec: surface,
            attachment: attachment,
            hostSpec: hostSpec
        )
        defer { second.session.teardown() }

        XCTAssertEqual(first.outcome.result, .created)
        XCTAssertEqual(second.outcome.result, .reused)
        XCTAssertEqual(first.outcome.surfaceID, host.surfaceID)
        XCTAssertEqual(second.outcome.surfaceID, host.surfaceID)
        XCTAssertEqual(first.session.originSurface.surfaceID, host.surfaceID)
        XCTAssertEqual(second.session.originSurface.surfaceID, host.surfaceID)
        XCTAssertEqual(host.attachedIDs(), [host.surfaceID, host.surfaceID])
        for visible in [
            first.session.surfaceTitle,
            first.session.originSurface.title,
            first.session.connectionInfo.targetTitle,
            second.session.surfaceTitle,
            second.session.originSurface.title,
            second.session.connectionInfo.targetTitle,
        ] {
            XCTAssertFalse(visible.contains("SECRET_KEY"))
            XCTAssertFalse(visible.contains("SECRET_EXECUTABLE"))
            XCTAssertFalse(visible.contains("SECRET_ARGUMENT"))
        }

        try await awaitHostCompletion(hostTask, host: host)
    }

    func test_savedRunnerProfileKeepsExecutionIdentitySeparateFromProjectBinding() throws {
        let profile = PeerHostProfile(
            displayName: "jw-server",
            sshTarget: "root@jw-server",
            savedRunner: PeerSavedRunnerProfile(
                surface: PeerRunnerSurfaceSpec(
                    key: "runner:cargo",
                    cwd: "/app/runner",
                    executable: "/usr/bin/cargo",
                    args: ["test"]
                )
            )
        )

        let json = try JSONEncoder().encode(profile)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertTrue(text.contains("runner:cargo"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("projectBinding"))
    }

    func test_plainSavedHostRemainsPickerOnly() throws {
        let profile = PeerHostProfile(
            displayName: "ARM builder",
            sshTarget: "builder-arm",
            remoteSocket: "/run/user/1000/term-mesh.sock"
        )

        XCTAssertNil(profile.savedRunner)
        let restored = try JSONDecoder().decode(
            PeerHostProfile.self,
            from: JSONEncoder().encode(profile)
        )
        XCTAssertNil(restored.savedRunner)
        XCTAssertEqual(restored.effectiveDisplayName, "ARM builder")
    }

    @MainActor
    func test_savedRunnerFailureConversionDropsPeerProvidedSecrets() {
        let secretMarkers = [
            "SECRET_EXECUTABLE",
            "SECRET_ARGUMENT",
            "SECRET_SSH_STDERR",
            "SECRET_ERROR_CONTEXT",
        ]
        let untrustedContext = """
            executable=/SECRET_EXECUTABLE/bin/tool
            args=--token=SECRET_ARGUMENT
            ssh_stderr=SECRET_SSH_STDERR
            detail=SECRET_ERROR_CONTEXT
            """
        let converted = PeerClientCoordinator.safeRunnerError(
            RelayError.ensureRejected(
                code: "COMMAND_NOT_FOUND",
                stage: "ensure",
                safeContext: untrustedContext
            ),
            fallbackStage: .probe
        )
        let visibleStatus = PeerSavedRunnerStatus(
            stage: converted.stage,
            machine: "jw-server",
            cwd: "/app/runner",
            errorCode: converted.code,
            safeContext: converted.context
        )
        let visibleText = [
            visibleStatus.stage.rawValue,
            visibleStatus.machine,
            visibleStatus.cwd,
            visibleStatus.errorCode ?? "",
            visibleStatus.safeContext ?? "",
        ].joined(separator: "\n")

        XCTAssertEqual(visibleStatus.stage, .ensure)
        XCTAssertEqual(visibleStatus.machine, "jw-server")
        XCTAssertEqual(visibleStatus.cwd, "/app/runner")
        XCTAssertEqual(visibleStatus.errorCode, "COMMAND_NOT_FOUND")
        XCTAssertEqual(visibleStatus.safeContext, "The configured executable does not exist")
        for secret in secretMarkers {
            XCTAssertFalse(visibleText.contains(secret))
        }
    }

}

/// Force Disconnect must close a host's mirrors and relay windows before its
/// panes. While a live mirror owns the workspace,
/// `Workspace.mirrorForwardsLocalActions` converts every local close into a
/// forwardClose to the host and returns false, so a pane closed first does not
/// go away — the host never pushes a layout dropping the last surface in a
/// workspace, and exactly one pane survives the teardown. Closing mirrors first
/// flips that predicate off before any pane is asked to close.
@MainActor
final class RemoteHostForceDisconnectOrderTests: XCTestCase {

    private func connection(
        _ kind: PeerRelayConnectionInfo.Kind,
        title: String
    ) -> PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(NSObject()),
            kind: kind,
            hostSockPath: "/tmp/tm-peer-test.sock",
            hostDisplayName: "test-host",
            sshTarget: "root@test-host",
            sshPort: nil,
            identityFile: nil,
            remoteSockPath: "/run/user/0/tm-peer.sock",
            targetTitle: title,
            connectedAt: Date()
        )
    }

    func test_forceDisconnectOrder_putsPanesLast() {
        let rows = [
            connection(.pane, title: "pane-1"),
            connection(.workspace, title: "mirror"),
            connection(.pane, title: "pane-2"),
            connection(.console, title: "console"),
        ]

        let ordered = RemoteHostStore.forceDisconnectOrder(rows)

        XCTAssertEqual(ordered.map(\.targetTitle),
                       ["mirror", "console", "pane-1", "pane-2"])
    }

    /// The regression this guards: no pane may precede a non-pane, or that pane
    /// gets forwarded to the host instead of closed.
    func test_forceDisconnectOrder_noPaneBeforeANonPane() {
        let rows = [
            connection(.pane, title: "pane-1"),
            connection(.workspace, title: "mirror"),
        ]

        let ordered = RemoteHostStore.forceDisconnectOrder(rows)
        let firstPane = ordered.firstIndex { $0.kind == .pane }
        let lastNonPane = ordered.lastIndex { $0.kind != .pane }

        XCTAssertNotNil(firstPane)
        XCTAssertNotNil(lastNonPane)
        XCTAssertGreaterThan(firstPane!, lastNonPane!)
    }

    /// A force disconnect that silently dropped a row would leave that
    /// connection open with no remaining way to reach it.
    func test_forceDisconnectOrder_preservesEveryRow() {
        let rows = [
            connection(.pane, title: "pane-1"),
            connection(.workspace, title: "mirror"),
            connection(.pane, title: "pane-2"),
        ]

        let ordered = RemoteHostStore.forceDisconnectOrder(rows)

        XCTAssertEqual(ordered.count, rows.count)
        XCTAssertEqual(Set(ordered.map(\.targetTitle)),
                       Set(rows.map(\.targetTitle)))
    }

    /// activeConnections is already sorted by connectedAt; the close sequence
    /// should stay predictable within each group.
    func test_forceDisconnectOrder_isStableWithinEachGroup() {
        let rows = [
            connection(.workspace, title: "mirror-a"),
            connection(.pane, title: "pane-a"),
            connection(.workspace, title: "mirror-b"),
            connection(.pane, title: "pane-b"),
        ]

        let ordered = RemoteHostStore.forceDisconnectOrder(rows)

        XCTAssertEqual(ordered.map(\.targetTitle),
                       ["mirror-a", "mirror-b", "pane-a", "pane-b"])
    }

    func test_forceDisconnectOrder_handlesEmptyAndPaneOnlyInput() {
        XCTAssertTrue(RemoteHostStore.forceDisconnectOrder([]).isEmpty)

        let panesOnly = [
            connection(.pane, title: "pane-1"),
            connection(.pane, title: "pane-2"),
        ]
        XCTAssertEqual(
            RemoteHostStore.forceDisconnectOrder(panesOnly).map(\.targetTitle),
            ["pane-1", "pane-2"]
        )
    }

}

/// The leftover-shell sweep: what it counts, and what it reports when part
/// of the batch refuses to close.
final class PeerShellSweepTests: XCTestCase {

    private func ids(_ n: Int) -> Set<Data> {
        Set((0..<n).map { Data([UInt8($0)]) })
    }

    private struct Refused: Error {}

    @MainActor
    func test_every_target_closed_is_counted() async throws {
        var seen: [Data] = []
        let closed = try await TeamOrchestrator.sweepClose(
            targets: ids(5),
            send: { _ in },
            onClosed: { seen.append($0) }
        )
        XCTAssertEqual(closed, 5)
        XCTAssertEqual(seen.count, 5, "the completion runs once per closed shell, not per target")
    }

    /// One refusal must not strand the shells behind it — the whole point of
    /// the sweep. Before this, the first failure aborted the batch.
    @MainActor
    func test_one_refusal_does_not_strand_the_rest() async throws {
        let targets = ids(6)
        let doomed = targets.sorted { $0.lexicographicallyPrecedes($1) }[2]
        var attempted = 0
        var closedIDs: [Data] = []

        do {
            _ = try await TeamOrchestrator.sweepClose(
                targets: targets,
                send: { id in
                    attempted += 1
                    if id == doomed { throw Refused() }
                },
                onClosed: { closedIDs.append($0) }
            )
            XCTFail("a refusal must surface as an error")
        } catch let error as TeamOrchestrator.RemoteAgentError {
            guard case .partialShellClose(let closed, let failed, _) = error else {
                return XCTFail("expected partialShellClose, got \(error)")
            }
            XCTAssertEqual(closed, 5)
            XCTAssertEqual(failed, 1)
            XCTAssertEqual(closed + failed, targets.count, "every target is accounted for")
        }

        XCTAssertEqual(attempted, 6, "the sweep must not stop at the failure")
        XCTAssertFalse(closedIDs.contains(doomed), "a refused shell must not be marked closed")
    }

    /// "Nothing closed" and "most of them did" have to be distinguishable —
    /// the caller shows the count to the user.
    @MainActor
    func test_a_total_failure_reports_zero_closed() async throws {
        do {
            _ = try await TeamOrchestrator.sweepClose(
                targets: ids(4),
                send: { _ in throw Refused() }
            )
            XCTFail("expected an error")
        } catch let error as TeamOrchestrator.RemoteAgentError {
            guard case .partialShellClose(let closed, let failed, _) = error else {
                return XCTFail("expected partialShellClose, got \(error)")
            }
            XCTAssertEqual(closed, 0)
            XCTAssertEqual(failed, 4)
        }
    }

    /// Only the first failure is reported. A dozen identical refusals should
    /// not bury the one reason the user needs to read.
    @MainActor
    func test_the_first_failure_is_the_one_reported() async throws {
        struct First: Error {}
        struct Later: Error {}
        var call = 0
        do {
            _ = try await TeamOrchestrator.sweepClose(
                targets: ids(3),
                send: { _ in
                    call += 1
                    throw call == 1 ? First() : Later()
                }
            )
            XCTFail("expected an error")
        } catch let error as TeamOrchestrator.RemoteAgentError {
            guard case .partialShellClose(_, _, let reason) = error else {
                return XCTFail("expected partialShellClose, got \(error)")
            }
            XCTAssertTrue(reason.contains("First"), "got \(reason)")
        }
    }

    /// An empty batch is a no-op, not an error. `closePeerShells` reaches this
    /// when every selected shell turned out to be protected.
    @MainActor
    func test_an_empty_sweep_closes_nothing_and_does_not_throw() async throws {
        var sendCalled = false
        let closed = try await TeamOrchestrator.sweepClose(
            targets: [],
            send: { _ in sendCalled = true }
        )
        XCTAssertEqual(closed, 0)
        XCTAssertFalse(sendCalled)
    }
}

/// Project deletion must respect the host's last-pane invariant: a dedicated
/// workspace owns its terminal panes, while native agent surfaces sit outside
/// that tree and keep their explicit termination path.
final class ProjectRemoteSurfaceDeletionTests: XCTestCase {

    func test_dedicated_workspace_deletes_terminal_surface_with_workspace() {
        XCTAssertFalse(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: false,
                belongsToOwnedWorkspace: true
            )
        )
    }

    func test_peer_owned_agent_is_terminated_even_with_dedicated_workspace() {
        XCTAssertTrue(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: true,
                belongsToOwnedWorkspace: true
            )
        )
    }

    func test_terminal_surface_without_owned_workspace_keeps_close_path() {
        XCTAssertTrue(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: false,
                belongsToOwnedWorkspace: false
            )
        )
    }

    func test_workspace_ownership_includes_active_and_inactive_tabs_only() {
        let active = Data(repeating: 0x11, count: 16)
        let inactive = Data(repeating: 0x22, count: 16)
        let generic = Data(repeating: 0x33, count: 16)
        var activeTab = Termmesh_Peer_V1_PaneTab()
        activeTab.surfaceID = active
        var inactiveTab = Termmesh_Peer_V1_PaneTab()
        inactiveTab.surfaceID = inactive
        var pane = Termmesh_Peer_V1_WorkspacePane()
        pane.surfaceID = active
        pane.tabs = [activeTab, inactiveTab]
        var layout = Termmesh_Peer_V1_WorkspaceLayout()
        layout.pane = pane

        let owned = peerSurfaceIDs(layout)
        XCTAssertEqual(owned, [active, inactive])
        XCTAssertFalse(owned.contains(generic))
        XCTAssertTrue(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: false,
                belongsToOwnedWorkspace: owned.contains(generic)
            )
        )
        XCTAssertFalse(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: false,
                belongsToOwnedWorkspace: owned.contains(inactive)
            )
        )
    }
}

/// One PTY, two windows onto it — the size arbitration between a local pane
/// and an attached remote viewer.
final class RemoteViewerSizeArbitrationTests: XCTestCase {

    /// While both are on screen the smaller wins, so neither has to render a
    /// line wrapped for a width it does not have.
    ///
    /// The loser of this arbitration does not merely look wrong: its shell
    /// wraps at a column that is no longer the edge and keeps a cursor the
    /// screen does not show there, which is where the next keystroke lands.
    /// Margin, by contrast, loses nothing.
    func test_both_on_screen_takes_the_smaller_of_the_two() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 1200, h: 800),
            remote: (w: 900, h: 1000),
            localOnScreen: true,
            remoteTypedLast: nil,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 900, "the narrower width wins")
        XCTAssertEqual(size.h, 800, "each dimension is decided on its own")
    }

    /// A pane parked in an unselected workspace has nobody reading it, so
    /// there is no one to accommodate and the viewer gets what it asked for.
    func test_a_hidden_local_pane_yields_entirely_to_the_viewer() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 400, h: 300),
            remote: (w: 1600, h: 1200),
            localOnScreen: false,
            remoteTypedLast: nil,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 1600)
        XCTAssertEqual(size.h, 1200)
    }

    /// With no viewer attached the local pane is unconstrained — the previous
    /// arbitration must not linger and keep it small.
    func test_without_a_viewer_the_local_size_stands() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 1200, h: 800),
            remote: nil,
            localOnScreen: true,
            remoteTypedLast: nil,
            fallback: (w: 10, h: 10)
        )
        XCTAssertEqual(size.w, 1200)
        XCTAssertEqual(size.h, 800)
    }

    /// A viewer can attach before the local pane has ever been laid out; its
    /// size is the only real answer available then.
    func test_a_viewer_arriving_before_any_local_layout_is_used_as_is() {
        let size = TerminalSurface.resolvePixelSize(
            local: nil,
            remote: (w: 640, h: 480),
            localOnScreen: true,
            remoteTypedLast: nil,
            fallback: (w: 10, h: 10)
        )
        XCTAssertEqual(size.w, 640)
        XCTAssertEqual(size.h, 480)
    }

    /// The bug this rule exists for: a viewer maximized to full screen stayed
    /// pinned to the host pane's width, because asking for more room is what
    /// re-loses the min. Typing in the viewer is what breaks the deadlock.
    func test_a_typing_viewer_takes_the_grid_from_a_smaller_host_pane() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 600, h: 400),
            remote: (w: 2400, h: 1400),
            localOnScreen: true,
            remoteTypedLast: true,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 2400, "the viewer being typed into is the one being read")
        XCTAssertEqual(size.h, 1400)
    }

    /// And the same in reverse, so a viewer left open on another machine
    /// cannot hold the pane somebody is actually working in at its size.
    func test_a_typing_local_pane_takes_the_grid_back_from_the_viewer() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 2400, h: 1400),
            remote: (w: 600, h: 400),
            localOnScreen: true,
            remoteTypedLast: false,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 2400)
        XCTAssertEqual(size.h, 1400)
    }

    /// A hidden local pane already yields entirely; who typed last must not
    /// resurrect it as a constraint.
    func test_a_hidden_local_pane_yields_even_when_it_typed_last() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 400, h: 300),
            remote: (w: 1600, h: 1200),
            localOnScreen: false,
            remoteTypedLast: false,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 1600)
        XCTAssertEqual(size.h, 1200)
    }

    /// With no viewer attached there is nothing to arbitrate, whatever the
    /// last keystroke was.
    func test_without_a_viewer_the_local_size_stands_regardless_of_the_typist() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 1200, h: 800),
            remote: nil,
            localOnScreen: true,
            remoteTypedLast: true,
            fallback: (w: 10, h: 10)
        )
        XCTAssertEqual(size.w, 1200)
        XCTAssertEqual(size.h, 800)
    }
}

// ── t14: callback (agent) delivery ───────────────────────────────────

/// Exercises `PeerRelaySession`'s `.callback` PtyData delivery: arrival-order
/// preservation on the live path (owned and shared), the resume-transition
/// gate's exactly-once contract riding the same delivery path, the
/// defensive GridSnapshot drop, and the absence of every relay-only fixture
/// (listener socket, secret, helper handshake).
///
/// Sessions are built through the internal initializer around a scripted
/// `PeerSession(read:write:)` — the factories all require a live
/// handshake/attach round trip that a unit test has no host for.
final class PeerRelaySessionCallbackDeliveryTests: XCTestCase {

    private struct TimedOut: Error {}

    /// Collects callback deliveries. The pump invokes `onPtyData` off the
    /// main actor, so a lock box rather than test-local state.
    private final class ChunkCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            chunks.append(data)
            lock.unlock()
        }

        var all: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return chunks
        }

        var count: Int { all.count }

        /// Every delivered byte, in delivery order — chunk boundaries may
        /// legally differ between live chunks and an abort-flush batch, so
        /// content assertions compare the joined stream.
        var joined: String {
            String(decoding: all.reduce(Data(), +), as: UTF8.self)
        }
    }

    /// Scripted inbound side of a `PeerSession`: `push` hands the session's
    /// read closure one already-encoded frame, `finish` makes the next read
    /// throw (the transport died).
    private actor FrameFeed {
        struct EndOfScript: Error {}

        private var pending: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []
        private var finished = false

        func push(_ frame: Data) {
            if waiters.isEmpty {
                pending.append(frame)
            } else {
                waiters.removeFirst().resume(returning: frame)
            }
        }

        func finish() {
            finished = true
            let parked = waiters
            waiters = []
            for waiter in parked {
                waiter.resume(throwing: EndOfScript())
            }
        }

        func next() async throws -> Data {
            if !pending.isEmpty { return pending.removeFirst() }
            if finished { throw EndOfScript() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
    }

    private func ptyDataFrame(surfaceID: Data, byteSeq: UInt64, payload: Data) -> Data {
        var pty = Termmesh_Peer_V1_PtyData()
        pty.surfaceID = surfaceID
        pty.byteSeq = byteSeq
        pty.payload = payload
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.ptyData = pty
        return try! encodeFrame(envelope)
    }

    private func gridSnapshotFrame(surfaceID: Data, ansi: Data) -> Data {
        var snapshot = Termmesh_Peer_V1_GridSnapshot()
        snapshot.surfaceID = surfaceID
        snapshot.byteSeq = 0
        snapshot.altScreen = false
        snapshot.ansi = ansi
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.gridSnapshot = snapshot
        return try! encodeFrame(envelope)
    }

    private func surfaceExitedFrame(
        surfaceID: Data,
        exitCode: Int32,
        signal: Int32,
        reason: String
    ) -> Data {
        var exited = Termmesh_Peer_V1_SurfaceExited()
        exited.surfaceID = surfaceID
        exited.exitCode = exitCode
        exited.signal = signal
        exited.reason = reason
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.surfaceExited = exited
        return try! encodeFrame(envelope)
    }

    private func errorFrame(code: UInt32, message: String) -> Data {
        var peerError = Termmesh_Peer_V1_Error()
        peerError.code = code
        peerError.message = message
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.error = peerError
        return try! encodeFrame(envelope)
    }

    /// `ownsSession: false` on purpose: a scripted stream end must end the
    /// pump, not start the owned-path reconnect loop dialing a host that
    /// does not exist.
    @MainActor
    private func makeCallbackSession(
        feed: FrameFeed,
        surfaceID: Data,
        ptyStream: AsyncStream<PeerPtyChunk>? = nil
    ) -> PeerRelaySession {
        let session = PeerSession(
            read: { try await feed.next() },
            write: { _ in }
        )
        return PeerRelaySession(
            hostSockPath: "/nonexistent/term-mesh-callback-test.sock",
            hostDisplayName: "callback-test",
            relaySockPath: "",
            relaySecret: "",
            surfaceID: surfaceID,
            remoteCols: 80,
            remoteRows: 24,
            session: session,
            transport: nil,
            ownsSession: false,
            ptyStream: ptyStream,
            onSharedDetach: nil,
            attachInitialSeq: 0,
            hostSupportsReplayRing: true,
            ptyDelivery: .callback
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ message: String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if condition() { return }
        XCTFail(message, file: file, line: line)
        throw TimedOut()
    }

    @MainActor
    private func receivedBytes(_ relay: PeerRelaySession) -> UInt64 {
        relay.ioSnapshot["bytes_received"] as? UInt64 ?? 0
    }

    // (a) + (c): live chunks reach the callback in arrival order, and none
    // of the relay-only setup exists to gate them.
    @MainActor
    func testCallbackDeliveryPreservesArrivalOrderWithoutARelayHelper() async throws {
        let surfaceID = Data(repeating: 0xA7, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }

        // Relay-only setup must be inert: no socket path was allocated, no
        // listener is bound, and prepareListener neither throws (there is
        // no relay binary at "") nor binds anything.
        XCTAssertTrue(relay.relaySockPath.isEmpty)
        XCTAssertNoThrow(try relay.prepareListener())
        XCTAssertEqual(relay.listenerFileDescriptorForTesting, -1)

        // In relay mode start() would block in acceptRelay until a helper
        // dials in (and then time out). Callback mode must come up alone.
        try await relay.start()
        XCTAssertEqual(relay.listenerFileDescriptorForTesting, -1)

        var expected: [Data] = []
        var byteSeq: UInt64 = 0
        for index in 0..<50 {
            let payload = Data("{\"line\":\(index)}\n".utf8)
            expected.append(payload)
            await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: byteSeq, payload: payload))
            byteSeq += UInt64(payload.count)
        }

        try await waitUntil("expected 50 chunks, got \(received.count)") { received.count == 50 }
        XCTAssertEqual(received.all, expected, "chunks must arrive exactly once, in arrival order")

        await relay.stop()
        await feed.finish()
    }

    // Contract item: the callback owner must be swappable (the
    // recreated-AgentSession path). Chunks after a reassignment land on the
    // new consumer only.
    @MainActor
    func testCallbackOwnerSwapRedirectsSubsequentChunks() async throws {
        let surfaceID = Data(repeating: 0xA8, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let first = ChunkCollector()
        relay.onPtyData = { first.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("one".utf8)))
        try await waitUntil { first.count == 1 }

        let second = ChunkCollector()
        relay.onPtyData = { second.append($0) }
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 3, payload: Data("two".utf8)))

        try await waitUntil { second.count == 1 }
        XCTAssertEqual(first.joined, "one", "the retired consumer must not receive post-swap chunks")
        XCTAssertEqual(second.joined, "two")

        await relay.stop()
        await feed.finish()
    }

    // (b) abort side: bytes suppressed behind an open resume transition are
    // flushed to the callback in order — exactly once, nothing lost.
    @MainActor
    func testResumeAbortFlushesSuppressedBytesToCallbackInOrder() async throws {
        let surfaceID = Data(repeating: 0xA9, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("A".utf8)))
        try await waitUntil { received.joined == "A" }

        let transition = relay.beginResumeTransitionForTesting()
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 1, payload: Data("B".utf8)))
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 2, payload: Data("C".utf8)))

        // Wait until the pump has *processed* (counted) both suppressed
        // chunks, then confirm none of them rendered.
        try await waitUntil { self.receivedBytes(relay) == 3 }
        XCTAssertEqual(received.joined, "A", "bytes behind an open transition must be suppressed")

        await relay.abortResumeTransitionForTesting(transition)
        try await waitUntil { received.joined == "ABC" }

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 3, payload: Data("D".utf8)))
        try await waitUntil { received.joined == "ABCD" }
        XCTAssertEqual(received.joined, "ABCD", "abort flush must deliver exactly once, in order")

        await relay.stop()
        await feed.finish()
    }

    // (b) commit side: old-session bytes buffered across the boundary are
    // discarded (the replay re-carries them), and the replay itself is
    // delivered exactly once through the same callback path.
    @MainActor
    func testResumeCommitDiscardsOldBytesAndDeliversReplayOnce() async throws {
        let surfaceID = Data(repeating: 0xAA, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("A".utf8)))
        try await waitUntil { received.joined == "A" }

        let transition = relay.beginResumeTransitionForTesting()
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 1, payload: Data("B".utf8)))
        try await waitUntil { self.receivedBytes(relay) == 2 }
        XCTAssertTrue(relay.commitResumeTransitionForTesting(transition))

        // Old-session tail after the commit: suppressed until the swap, and
        // never rendered from the old stream — the replay re-carries it.
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 2, payload: Data("C".utf8)))
        try await waitUntil { self.receivedBytes(relay) == 3 }
        XCTAssertEqual(received.joined, "A", "old-session bytes past the boundary must not render")

        // The receive loop adopting the resumed session resets the wire-seq
        // space; the replay then re-carries everything after the boundary.
        relay.adoptCommittedResumeSessionForTesting()
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("BC".utf8)))
        try await waitUntil { received.joined == "ABC" }

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 2, payload: Data("D".utf8)))
        try await waitUntil { received.joined == "ABCD" }
        XCTAssertEqual(
            received.joined, "ABCD",
            "suppressed old bytes and their replay must not both render"
        )

        await relay.stop()
        await feed.finish()
    }

    // Repair C: host broadcast Lag on callback delivery must not advance
    // the heal anchor past the dropped bytes — an NDJSON consumer has no
    // repainting GridSnapshot to cover a hole. A gapped chunk opens a
    // capture at the last DELIVERED position and suppresses the post-gap
    // stream behind it; the heal ADOPTS that anchor, so the ring replay
    // re-carries the gap plus the suppressed bytes exactly once.
    @MainActor
    func testALaggedGapAnchorsTheHealAtTheLastDeliveredByte() async throws {
        let surfaceID = Data(repeating: 0xAD, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("A".utf8)))
        try await waitUntil { received.joined == "A" }

        // byte_seq jumps 1 → 5: the host's broadcast lagged and dropped
        // four bytes. The post-gap chunk must be captured, not delivered.
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 5, payload: Data("F".utf8)))
        try await waitUntil { self.receivedBytes(relay) == 2 }
        XCTAssertEqual(received.joined, "A",
                       "post-gap bytes must be suppressed until the heal resolves")

        // The heal joins the pump-opened capture: anchored at the end of
        // the last delivered chunk (wire seq 1), not past the gap (6).
        let transition = relay.beginResumeTransitionForTesting()
        XCTAssertEqual(transition.resumeWireSeq, 1,
                       "the heal must resume from the last delivered byte, not skip the gap")

        XCTAssertTrue(relay.commitResumeTransitionForTesting(transition))
        relay.adoptCommittedResumeSessionForTesting()

        // The resumed attach replays everything after the anchor — the
        // dropped bytes AND the suppressed post-gap chunk — exactly once.
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("bcdeF".utf8)))
        try await waitUntil { received.joined == "AbcdeF" }
        XCTAssertEqual(received.joined, "AbcdeF",
                       "the ring replay must fill the gap without duplicating delivered bytes")

        await relay.stop()
        await feed.finish()
    }

    // E4: a chunk emitted while `onPtyData` is unset is a DROP, not an
    // enqueue — otherwise received≈enqueued reads as healthy on a session
    // that rendered nothing.
    @MainActor
    func testConsumerlessChunksCountAsDroppedNotEnqueued() async throws {
        let surfaceID = Data(repeating: 0xAE, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        // Deliberately no onPtyData yet.
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("lost".utf8)))
        try await waitUntil { self.receivedBytes(relay) == 4 }
        XCTAssertEqual(relay.ioSnapshot["bytes_dropped"] as? UInt64, 4)
        XCTAssertEqual(relay.ioSnapshot["bytes_enqueued"] as? UInt64, 0,
                       "a consumer-less emit must never count as enqueued")

        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 4, payload: Data("kept".utf8)))
        try await waitUntil { received.joined == "kept" }
        XCTAssertEqual(relay.ioSnapshot["bytes_enqueued"] as? UInt64, 4)
        XCTAssertEqual(relay.ioSnapshot["bytes_dropped"] as? UInt64, 4,
                       "delivered bytes go back to the enqueued tally only")

        await relay.stop()
        await feed.finish()
    }

    // Shared (pre-demuxed ptyStream) path: same callback, same order, and
    // stream end tears the session down.
    @MainActor
    func testSharedPathDeliversToCallbackAndDisconnectsOnStreamEnd() async throws {
        let surfaceID = Data(repeating: 0xAB, count: 16)
        var continuation: AsyncStream<PeerPtyChunk>.Continuation!
        let stream = AsyncStream<PeerPtyChunk> { continuation = $0 }
        let relay = makeCallbackSession(
            feed: FrameFeed(),
            surfaceID: surfaceID,
            ptyStream: stream
        )
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        var disconnected = false
        relay.onDisconnect = { disconnected = true }
        try await relay.start()

        continuation.yield(PeerPtyChunk(byteSeq: 0, payload: Data("hello ".utf8)))
        continuation.yield(PeerPtyChunk(byteSeq: 6, payload: Data("world".utf8)))
        try await waitUntil { received.joined == "hello world" }
        XCTAssertEqual(received.count, 2, "shared-path chunks must arrive individually, in order")

        continuation.finish()
        try await waitUntil { disconnected }
    }

    // A host-confirmed process exit is terminal application state, not a
    // broken transport to heal. Workspace keeps the completed AgentPanel so
    // its final output and exit notice remain visible; onDisconnect would
    // otherwise immediately close it and start authoritative-missing recovery.
    @MainActor
    func testSurfaceExitFinishesWithoutInvokingDisconnectRecovery() async throws {
        let surfaceID = Data(repeating: 0xAF, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        var observedExit: (Int32, Int32, String)?
        var disconnected = false
        relay.onSurfaceExited = { observedExit = ($0, $1, $2) }
        relay.onDisconnect = { disconnected = true }
        try await relay.start()

        await feed.push(surfaceExitedFrame(
            surfaceID: surfaceID,
            exitCode: 23,
            signal: 0,
            reason: "bridge exited"
        ))
        try await waitUntil { observedExit != nil }

        XCTAssertEqual(observedExit?.0, 23)
        XCTAssertEqual(observedExit?.1, 0)
        XCTAssertEqual(observedExit?.2, "bridge exited")
        XCTAssertFalse(disconnected,
                       "authoritative surface exit must leave the completed agent pane visible")
    }

    // A host protocol error is connection-scoped and cannot safely be ignored:
    // expose it to the panel owner, then use the existing disconnect recovery
    // because the remote process may still be alive after the broken stream.
    @MainActor
    func testHostErrorIsVisibleAndInvokesDisconnectRecovery() async throws {
        let surfaceID = Data(repeating: 0xB0, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        var observedError = ""
        var disconnected = false
        relay.onError = { observedError = String(describing: $0) }
        relay.onDisconnect = { disconnected = true }
        try await relay.start()

        await feed.push(errorFrame(code: 8, message: "input queue overflow"))
        try await waitUntil { disconnected }

        XCTAssertTrue(observedError.contains("host error 8: input queue overflow"))
    }

    // Defensive contract: an agent surface never sends GridSnapshot, but if
    // one arrives its rendered-cell ANSI must not reach the NDJSON consumer
    // — while the wire-seq reset it implies still applies.
    @MainActor
    func testGridSnapshotIsDroppedButItsSeqResetStillApplies() async throws {
        let surfaceID = Data(repeating: 0xAC, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("A".utf8)))
        try await waitUntil { received.joined == "A" }

        await feed.push(gridSnapshotFrame(surfaceID: surfaceID, ansi: Data("JUNK-ANSI".utf8)))
        // Post-snapshot the wire seq restarts at 0; the next live chunk
        // must be delivered without a spurious gap heal (or JUNK bytes).
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("B".utf8)))

        try await waitUntil { received.joined == "AB" }
        XCTAssertEqual(received.joined, "AB", "snapshot ANSI must never reach the callback")

        await relay.stop()
        await feed.finish()
    }
}

// MARK: - Peer-owned agent surfaces (Phase 3, T3.1)

/// The third remote-agent factory: `ensure(kind: "agent")` against a peer
/// daemon that owns `tm-agent-bridge` itself.
///
/// What is pinned here is everything that is decided BEFORE any UI exists —
/// which factory a member gets, what the ensure request actually carries, and
/// how a surface that outlived its attach is taken back down. The pane itself
/// is `Workspace.openRemoteAgentPane`, tested with the rest of Phase 2.
final class PeerOwnedAgentSurfaceTests: XCTestCase {

    @MainActor
    func test_configuredRemoteAgentEnvironmentIncludesProfileAndLetsHostOverride() {
        let merged = TeamOrchestrator.configuredRemoteAgentEnvironment(
            profile: ["AI_MESH_API_KEY": "profile-secret", "PROFILE_ONLY": "yes"],
            explicitHost: ["AI_MESH_API_KEY": "host-secret", "HOST_ONLY": "yes"]
        )

        XCTAssertEqual(merged["AI_MESH_API_KEY"], "host-secret")
        XCTAssertEqual(merged["PROFILE_ONLY"], "yes")
        XCTAssertEqual(merged["HOST_ONLY"], "yes")
    }

    @MainActor
    func test_peerOwnedEnvironmentPrecedenceAndValidationAreDeterministic() throws {
        let merged = try TeamOrchestrator.peerOwnedAgentEnvironment(
            profile: ["SHARED": "profile", "PROFILE_ONLY": "yes"],
            explicitHost: ["SHARED": "host", "HOST_ONLY": "yes", "TERMMESH_TEAM": "spoof"],
            internalIdentity: ["TERMMESH_TEAM": "real", "INTERNAL_ONLY": "yes"]
        )
        XCTAssertEqual(merged["SHARED"], "host")
        XCTAssertEqual(merged["PROFILE_ONLY"], "yes")
        XCTAssertEqual(merged["HOST_ONLY"], "yes")
        XCTAssertEqual(merged["TERMMESH_TEAM"], "real")
        XCTAssertEqual(merged["INTERNAL_ONLY"], "yes")

        XCTAssertThrowsError(try TeamOrchestrator.peerOwnedAgentEnvironment(
            profile: ["유니코드": "TOP_SECRET_VALUE"],
            explicitHost: [:],
            internalIdentity: [:]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("ASCII identifier"))
            let message = TeamOrchestrator.peerOwnedAgentInvalidEnvironmentFallbackMessage(
                error as! PeerEnsureEnvironment.ValidationError,
                cli: "codex",
                hostName: "jw-server"
            )
            XCTAssertTrue(message.contains("active CLI profile"))
            XCTAssertTrue(message.contains("유니코드"))
            XCTAssertFalse(message.contains("TOP_SECRET_VALUE"),
                           "environment values must never be logged")
        }
    }

    // MARK: Factory selection matrix

    /// The whole routing table in one place.
    ///
    /// The two exclusions are the ones most likely to be "simplified" away
    /// later, so they are asserted rather than described: claude never takes
    /// the peer-owned path (`tm-agent-bridge --cli` has no claude value), and
    /// cursor/agy stay on the local bridge until their own change lands.
    @MainActor
    func test_factoryMatrix_capabilityTimesBridgeTimesCLI() {
        func route(
            _ cli: String,
            capability: Bool,
            bridgePath: String = "/usr/local/bin/tm-agent-bridge",
            sshTarget: String? = "root@jw-server"
        ) -> TeamOrchestrator.RemoteAgentFactory {
            TeamOrchestrator.remoteAgentFactory(
                cli: cli,
                hostAdvertisesAgentSurfaces: capability,
                peerBridgePath: bridgePath,
                sshTarget: sshTarget
            )
        }

        // Codex and Kiro prefer peer ownership, but an older host changes
        // ownership rather than the Native renderer the user selected.
        for cli in ["codex", "kiro"] {
            XCTAssertEqual(route(cli, capability: true), .peerOwnedAgent, cli)
            XCTAssertEqual(
                route(cli, capability: false), .localNativeBridge,
                "\(cli): a daemon without surface.agent.v1 must keep a Native pane over SSH"
            )
            XCTAssertEqual(
                route(cli, capability: true, bridgePath: ""), .localNativeBridge,
                "\(cli): no bridge on the host changes ownership, not rendering"
            )
            XCTAssertEqual(
                route(cli, capability: true, sshTarget: nil), .terminal,
                "\(cli): a host with no ssh target cannot be probed for paths"
            )
        }

        // Turn-per-process CLIs keep today's local bridge (R8).
        for cli in ["cursor", "agy"] {
            XCTAssertEqual(route(cli, capability: true), .localNativeBridge, cli)
            XCTAssertEqual(
                route(cli, capability: false), .localNativeBridge,
                "\(cli): unaffected by the host capability — nothing runs there"
            )
            XCTAssertEqual(
                route(cli, capability: true, sshTarget: nil), .terminal,
                "\(cli): the local bridge is an ssh child; without a target there is none"
            )
        }

        // Claude speaks NDJSON directly and already has an SSH-native path.
        XCTAssertEqual(route("claude", capability: true), .localNativeBridge)
        XCTAssertEqual(route("claude", capability: false), .localNativeBridge)
        // gemini: the bridge speaks it, but no native panel holds it today.
        XCTAssertEqual(route("gemini", capability: true), .terminal)
    }

    /// Turning native panes off must take every native route with it — the
    /// setting is the user saying "give me terminal panes".
    @MainActor
    func test_factoryMatrix_nativePanesOffCollapsesEverythingToTerminal() {
        let defaults = UserDefaults.standard
        let key = AgentPipeTransport.nativePanelKey
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        for cli in ["claude", "codex", "kiro", "cursor", "agy", "gemini"] {
            XCTAssertEqual(
                TeamOrchestrator.remoteAgentFactory(
                    cli: cli,
                    hostAdvertisesAgentSurfaces: true,
                    peerBridgePath: "/usr/local/bin/tm-agent-bridge",
                    sshTarget: "root@jw-server"
                ),
                .terminal,
                cli
            )
        }
    }

    /// The routing table in full, as literal data.
    ///
    /// The test above asserts the intentions; this one asserts that nothing
    /// else changed while they were being honoured. Native is a renderer
    /// contract: capability and bridge availability may only choose between
    /// peer-owned and SSH-owned Native processes.
    ///
    /// Columns are (ssh, capability, bridge) counted in binary, the same order
    /// for every row, so one row is one CLI's entire story.
    @MainActor
    func test_factoryMatrix_isTotalOverSSHCapabilityAndBridge() {
        let restore = Self.forceNativePanes(true)
        defer { restore() }

        typealias Factory = TeamOrchestrator.RemoteAgentFactory
        let T = Factory.terminal
        let P = Factory.peerOwnedAgent
        let L = Factory.localNativeBridge

        //                         no ssh          ssh
        //                     ---------------  ---------------
        //   (cap, bridge) →   00  01  10  11   00  01  10  11
        let table: [(String, [Factory])] = [
            // Claude has no peer-owned recipe, but its direct SSH stream is native.
            ("claude", [T, T, T, T, L, L, L, L]),
            ("gemini", [T, T, T, T, T, T, T, T]),
            // Peer ownership only in the last cell; every other SSH cell remains native.
            ("codex", [T, T, T, T, L, L, L, P]),
            ("kiro", [T, T, T, T, L, L, L, P]),
            // Unmoved (R8). The bridge these run is this Mac's, so the peer's
            // capability and the peer's bridge are both irrelevant to them.
            ("cursor", [T, T, T, T, L, L, L, L]),
            ("agy", [T, T, T, T, L, L, L, L]),
        ]

        for (cli, expected) in table {
            for index in 0..<8 {
                let ssh = index & 0b100 != 0
                let capability = index & 0b010 != 0
                let bridge = index & 0b001 != 0
                XCTAssertEqual(
                    TeamOrchestrator.remoteAgentFactory(
                        cli: cli,
                        hostAdvertisesAgentSurfaces: capability,
                        peerBridgePath: bridge ? "/usr/local/bin/tm-agent-bridge" : "",
                        sshTarget: ssh ? "root@jw-server" : nil
                    ),
                    expected[index],
                    "\(cli): ssh=\(ssh) capability=\(capability) bridge=\(bridge)"
                )
            }
        }
    }

    /// An empty ssh target is the same fact as a nil one — a host reached on a
    /// local socket cannot be probed for paths, so neither remote factory has
    /// anything to work with.
    @MainActor
    func test_factoryMatrix_anEmptySSHTargetCountsAsNoSSHTarget() {
        let restore = Self.forceNativePanes(true)
        defer { restore() }

        for cli in ["codex", "kiro", "cursor", "agy"] {
            XCTAssertEqual(
                TeamOrchestrator.remoteAgentFactory(
                    cli: cli,
                    hostAdvertisesAgentSurfaces: true,
                    peerBridgePath: "/usr/local/bin/tm-agent-bridge",
                    sshTarget: ""
                ),
                .terminal,
                cli
            )
        }
    }

    // MARK: Why a fallback happened

    /// The availability check must answer for the CLIs that could never use
    /// the peer-owned path WITHOUT reaching for the network — both because a
    /// handshake per claude member is pure latency, and because `notApplicable`
    /// and `blocked` mean opposite things to the caller: one is a fallback the
    /// user should be told about, the other is simply how that CLI runs.
    @MainActor
    func test_availability_separatesNothingWasLostFromSomethingWasLost() async {
        let restore = Self.forceNativePanes(true)
        defer { restore() }

        let bridged = TeamOrchestrator.RemoteAgentBinaries(
            cliPath: "/root/.local/bin/codex",
            bridgePath: "/usr/local/bin/tm-agent-bridge",
            cliAvailable: true
        )

        // Never had the path: no probe, no report.
        for cli in ["claude", "gemini", "cursor", "agy"] {
            let answer = await TeamOrchestrator.canUsePeerOwnedAgent(
                host: Self.agentHostEntry(),
                cli: cli,
                binaries: bridged
            )
            XCTAssertEqual(answer, .notApplicable, cli)
        }

        // Reached without ssh: same — there is no path to resolve, so this is
        // how the member runs rather than something it lost.
        let noSSH = await TeamOrchestrator.canUsePeerOwnedAgent(
            host: Self.agentHostEntry(sshTarget: nil),
            cli: "codex",
            binaries: bridged
        )
        XCTAssertEqual(noSSH, .notApplicable)

        // Had the path and lost it: each with its own repair.
        let noBridge = await TeamOrchestrator.canUsePeerOwnedAgent(
            host: Self.agentHostEntry(),
            cli: "codex",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/root/.local/bin/codex", bridgePath: "", cliAvailable: true
            )
        )
        XCTAssertEqual(noBridge, .blocked(.bridgeMissing))

        let noSocket = await TeamOrchestrator.canUsePeerOwnedAgent(
            host: Self.agentHostEntry(activeSockPath: ""),
            cli: "codex",
            binaries: bridged
        )
        XCTAssertEqual(
            noSocket, .blocked(.hostUnreachable),
            "with no socket the capability is unknown, which is not the same as absent"
        )
    }

    /// The line the user actually reads. Every reason must name the CLI, the
    /// host and the ownership fallback — and the two most easily confused repairs
    /// ("install it there" vs "update it there") must not read alike, because
    /// following the wrong one leaves the pane exactly as it was.
    @MainActor
    func test_fallbackMessage_namesTheCLITheHostAndOneRepair() {
        var seen: Set<String> = []
        for block in TeamOrchestrator.PeerOwnedAgentBlock.allCases {
            let message = TeamOrchestrator.peerOwnedAgentFallbackMessage(
                block, cli: "codex", hostName: "jw-server"
            )
            XCTAssertTrue(message.contains("codex"), "\(block): names the CLI")
            XCTAssertTrue(message.contains("jw-server"), "\(block): names the host")
            XCTAssertTrue(
                message.contains("SSH-owned native agent pane"),
                "\(block): says which native ownership route opened"
            )
            XCTAssertTrue(seen.insert(message).inserted, "\(block): reads like another reason")
        }

        XCTAssertTrue(
            TeamOrchestrator.peerOwnedAgentFallbackMessage(
                .bridgeMissing, cli: "codex", hostName: "jw-server"
            ).contains("Install term-mesh")
        )
        XCTAssertTrue(
            TeamOrchestrator.peerOwnedAgentFallbackMessage(
                .daemonTooOld, cli: "codex", hostName: "jw-server"
            ).contains("Restart or update term-mesh")
        )
        XCTAssertTrue(
            TeamOrchestrator.peerOwnedAgentFallbackMessage(
                .ensureRefused, cli: "codex", hostName: "jw-server"
            ).contains("Nothing was left running there"),
            "a refused ensure creates nothing on the peer, and saying so is what "
                + "stops someone going to look for a stray bridge"
        )
    }

    /// Project and team creation must disclose the same ownership downgrade
    /// the attach path will take. The warning is capability-driven and uses
    /// the serving version from the handshake, not a binary found on PATH.
    @MainActor
    func test_creationPreflight_namesServingVersionBeforeNativeOwnershipFallback() {
        let restore = Self.forceNativePanes(true)
        defer { restore() }

        var oldHost = Self.agentHostEntry()
        oldHost.displayName = "mac-sub"
        oldHost.servingAppVersion = "0.179.0"
        oldHost.supportsPeerOwnedAgentHosting = false
        oldHost.supportsRemoteTeamRoute = true

        func row(_ cli: String) -> TeamAgentRow {
            TeamAgentRow(
                preset: AgentRolePreset(
                    id: UUID(), name: cli, displayName: cli.capitalized,
                    cli: cli, model: "sonnet", color: "blue",
                    instructions: "", isBuiltIn: false
                ),
                customInstructions: "",
                hostKey: oldHost.id
            )
        }

        let notices = TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("codex"), row("kiro"), row("claude")],
            hosts: [oldHost]
        )
        XCTAssertEqual(notices.count, 1, "one host gets one preflight warning")
        XCTAssertEqual(notices[0].servingVersion, "v0.179.0")
        XCTAssertEqual(notices[0].clis, ["codex", "kiro"])
        XCTAssertTrue(notices[0].message.contains("mac-sub"))
        XCTAssertTrue(notices[0].message.contains("term-mesh v0.179.0"))
        XCTAssertTrue(notices[0].message.contains("through this Mac over SSH"))
        XCTAssertTrue(notices[0].message.contains("stop if this app quits"))

        oldHost.supportsRemoteTeamRoute = false
        let blocked = TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("codex"), row("claude")], hosts: [oldHost]
        )
        XCTAssertEqual(blocked.count, 1)
        XCTAssertFalse(blocked[0].blocksTeamMessaging)
        XCTAssertEqual(blocked[0].clis, ["codex"])
        XCTAssertTrue(blocked[0].message.contains("private SSH route"))
        XCTAssertFalse(
            TeamAgentComposer.blocksRemoteTeamCreation(
                agents: [row("codex")], hosts: [oldHost]
            ),
            "SSH-owned Native has its own scoped reverse control route"
        )

        oldHost.sshTarget = nil
        let noSSHRoute = TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("codex"), row("claude")], hosts: [oldHost]
        )
        XCTAssertEqual(noSSHRoute.count, 1)
        XCTAssertTrue(noSSHRoute[0].blocksTeamMessaging)
        XCTAssertEqual(noSSHRoute[0].clis, ["claude", "codex"])
        XCTAssertTrue(noSSHRoute[0].message.contains("tm-agent returns no_app"))
        XCTAssertTrue(noSSHRoute[0].message.contains("Update and restart"))

        oldHost.supportsPeerOwnedAgentHosting = true
        oldHost.supportsRemoteTeamRoute = true
        XCTAssertTrue(
            TeamAgentComposer.peerOwnedFallbackNotices(
                agents: [row("codex")], hosts: [oldHost]
            ).isEmpty,
            "a compatible serving daemon needs no warning"
        )
        XCTAssertTrue(
            TeamAgentComposer.peerOwnedFallbackNotices(
                agents: [row("claude")], hosts: [{
                    var host = oldHost
                    host.supportsPeerOwnedAgentHosting = false
                    return host
                }()]
            ).isEmpty,
            "Claude is SSH-owned by design, not because this host is stale"
        )
    }

    /// A remote worker reaches the owning team through the same scoped
    /// reverse route as a peer leader. Pointing TERMMESH_SOCKET at the remote
    /// daemon without these fields deterministically returns `no_app`.
    @MainActor
    func test_remoteNativeAgentEnvironmentCarriesScopedTeamRoute() {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 0xab, count: PeerTeamLeader.grantIDBytes)
        grant.projectID = "name:mesh-test"
        grant.teamUuid = "team-uuid"
        grant.role = .leader
        grant.expiresAtUnixSecs = 123_456

        let env = TeamOrchestrator.remoteNativeAgentEnvironment(
            teamName: "mesh-test",
            agentName: "executor",
            agentType: "executor",
            agentCli: "codex",
            workspaceId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            socketPath: "/tmp/remote-term-mesh.sock",
            routeGrant: grant
        )

        XCTAssertEqual(env["TERMMESH_SOCKET"], "/tmp/remote-term-mesh.sock")
        XCTAssertEqual(env["TERMMESH_TEAM_NAME"], "mesh-test")
        XCTAssertEqual(env["TERMMESH_AGENT_NAME"], "executor")
        XCTAssertEqual(env["TERMMESH_LEADER_GRANT_ID"], String(repeating: "ab", count: 32))
        XCTAssertEqual(env["TERMMESH_LEADER_PROJECT_ID"], "name:mesh-test")
        XCTAssertEqual(env["TERMMESH_LEADER_TEAM_UUID"], "team-uuid")
        XCTAssertEqual(env["TERMMESH_LEADER_EXPIRES_AT"], "123456")
        XCTAssertEqual(env["TERMMESH_LEADER_PEER_ID"]?.count, 32)
    }

    @MainActor
    func test_peerOwnedAgentEnvironmentPreservesDaemonControlSocket() {
        let env = TeamOrchestrator.remoteNativeAgentEnvironment(
            teamName: "mesh-test",
            agentName: "executor",
            agentType: "executor",
            agentCli: "codex",
            workspaceId: UUID(),
            socketPath: nil
        )

        XCTAssertNil(env["TERMMESH_SOCKET"])
        XCTAssertNil(env["CMUX_SOCKET"])
    }

    @MainActor
    func test_sshOwnedAgentUsesPrivateReverseControlSocket() {
        let first = TeamOrchestrator.sshOwnedAgentReverseForward(
            agentInstanceID: "A1B2-C3D4",
            localControlSocket: "/tmp/term-mesh-debug-route.sock"
        )
        let second = TeamOrchestrator.sshOwnedAgentReverseForward(
            agentInstanceID: "FFFF-EEEE",
            localControlSocket: "/tmp/term-mesh-debug-route.sock"
        )

        XCTAssertEqual(first.local, "/tmp/term-mesh-debug-route.sock")
        XCTAssertEqual(first.remote, "/tmp/term-mesh-agent-route-a1b2-c3d4.sock")
        XCTAssertNotEqual(first.remote, second.remote)
        XCTAssertLessThan(first.remote.utf8.count, 104)
    }

    @MainActor
    func test_agentRuntimeOwnershipExplainsTheActualLifetime() {
        let fallback = AgentRuntimeOwnership.sshOwned(hostName: "mac-sub")
        XCTAssertEqual(fallback.badgeTitle, "SSH-owned")
        XCTAssertFalse(fallback.isDurableAcrossViewerQuit)
        XCTAssertTrue(fallback.detail?.contains("Stops when term-mesh on this Mac quits") == true)

        let durable = AgentRuntimeOwnership.peerOwned(hostName: "mac-sub")
        XCTAssertEqual(durable.badgeTitle, "Host-owned")
        XCTAssertTrue(durable.isDurableAcrossViewerQuit)
        XCTAssertTrue(durable.detail?.contains("reattach after restart") == true)
    }

    // MARK: Fixtures

    /// Pin both transport defaults for the duration of a test. They live in
    /// `UserDefaults.standard`, which the whole test process shares, so a
    /// routing assertion that reads them implicitly is one unrelated test away
    /// from being about something else.
    @MainActor
    private static func forceNativePanes(_ enabled: Bool) -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = [AgentPipeTransport.enabledKey, AgentPipeTransport.nativePanelKey]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.set(enabled, forKey: key) }
        return {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// A connected ssh host, minus everything the availability check does not
    /// read. Nothing here reaches a network: the assertions using it all stop
    /// at a guard before the handshake.
    @MainActor
    private static func agentHostEntry(
        sshTarget: String? = "root@jw-server",
        activeSockPath: String = "/tmp/term-mesh-peer-501/jw-server.sock"
    ) -> HostEntry {
        HostEntry(
            id: "ssh:root@jw-server",
            displayName: "jw-server",
            connectionState: .connected,
            workspaces: [],
            activeSockPath: activeSockPath,
            sshTarget: sshTarget,
            remoteSockPath: "/run/user/0/tm-peer.sock"
        )
    }

    // MARK: Ensure recipe

    /// The daemon spawns `executable` + `args` verbatim, so this vector IS the
    /// contract. Three things in it are load-bearing rather than cosmetic and
    /// each has cost a debugging session somewhere:
    ///  - `executable` must be the PEER's bridge, never this Mac's;
    ///  - `--cli` must be present, because the daemon reads
    ///    `SurfaceInfo.agent_cli` back out of the args (there is no field);
    ///  - `--exe` must be absolute, because term-meshd runs under systemd's
    ///    PATH and would not find a `$HOME/.local/bin` CLI by name. It comes
    ///    from `execPath`, the binary the BRIDGE spawns, which for kiro is not
    ///    the file the role is named after.
    @MainActor
    func test_ensureSpec_carriesThePeersBridgeAndAnAbsoluteCLIPath() {
        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: "11111111-2222-3333-4444-555555555555",
            cli: "codex",
            workingDirectory: "/root/work/term-mesh",
            model: "gpt-5",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/root/.local/bin/codex",
                execPath: "/root/.local/bin/codex",
                bridgePath: "/usr/local/bin/tm-agent-bridge",
                cliAvailable: true
            )
        )

        XCTAssertEqual(spec.executable, "/usr/local/bin/tm-agent-bridge")
        XCTAssertEqual(spec.cwd, "/root/work/term-mesh")
        XCTAssertEqual(spec.kind, SessionHostPanes.agentSurfaceType)
        XCTAssertEqual(spec.restartPolicy, .never)
        XCTAssertEqual(
            Array(spec.args[0..<4]),
            ["--cli", "codex", "--cwd", "/root/work/term-mesh"]
        )
        XCTAssertTrue(spec.args.contains("--exe"))
        XCTAssertEqual(
            spec.args.last, "/root/.local/bin/codex",
            "--exe is what makes the CLI findable from a systemd PATH"
        )
        // The label the daemon will echo back as SurfaceInfo.agent_cli.
        let cliFlag = spec.args.firstIndex(of: "--cli").map { spec.args[$0 + 1] }
        XCTAssertEqual(cliFlag, "codex")
    }

    /// A CLI the probe could not resolve still gets a surface: the bridge
    /// falls back to a bare name, which is right more often than failing.
    @MainActor
    func test_ensureSpec_omitsExeWhenTheProbeResolvedNothing() {
        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: UUID().uuidString,
            cli: "kiro",
            workingDirectory: "/root/work",
            model: "sonnet",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "",
                bridgePath: "/usr/local/bin/tm-agent-bridge",
                cliAvailable: true
            )
        )
        XCTAssertFalse(spec.args.contains("--exe"))
        XCTAssertEqual(Array(spec.args[0..<2]), ["--cli", "kiro"])
    }

    /// Two members of one team must never share an ensure key: the daemon
    /// would answer REUSED and hand the second member the first one's bridge.
    /// The instance id is therefore never the part that gets trimmed.
    @MainActor
    func test_ensureKey_isUniquePerInstanceAndFitsTheProtocolLimit() {
        let instanceA = UUID().uuidString
        let instanceB = UUID().uuidString
        let keyA = TeamOrchestrator.peerAgentEnsureKey(teamName: "team", agentInstanceId: instanceA)
        let keyB = TeamOrchestrator.peerAgentEnsureKey(teamName: "team", agentInstanceId: instanceB)
        XCTAssertNotEqual(keyA, keyB)
        XCTAssertTrue(keyA.contains(instanceA))

        let absurdTeam = String(repeating: "가", count: 400)
        let long = TeamOrchestrator.peerAgentEnsureKey(
            teamName: absurdTeam, agentInstanceId: instanceA
        )
        XCTAssertLessThanOrEqual(
            long.utf8.count, 256,
            "the daemon rejects a key over 256 UTF-8 bytes outright"
        )
        XCTAssertTrue(
            long.contains(instanceA),
            "trimming must eat the team name, never the uniqueness"
        )
    }

    @MainActor
    func test_restartSpec_usesAFreshEnsureKeyWithoutChangingAgentIdentity() {
        let agentInstanceID = "11111111-2222-3333-4444-555555555555"
        let surfaceInstanceID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let binaries = TeamOrchestrator.RemoteAgentBinaries(
            execPath: "/usr/local/bin/codex",
            bridgePath: "/usr/local/bin/tm-agent-bridge",
            cliAvailable: true
        )
        let original = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: agentInstanceID,
            cli: "codex",
            workingDirectory: "/work",
            model: "gpt-5",
            binaries: binaries
        )
        let replacement = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: agentInstanceID,
            surfaceInstanceId: surfaceInstanceID,
            cli: "codex",
            workingDirectory: "/work",
            model: "gpt-5",
            binaries: binaries
        )

        XCTAssertNotEqual(original.key, replacement.key)
        XCTAssertEqual(
            replacement.key,
            TeamOrchestrator.peerAgentEnsureKey(
                teamName: "my-team", agentInstanceId: surfaceInstanceID
            )
        )
        XCTAssertEqual(original.args, replacement.args)
    }

    // MARK: Probe parsing

    /// A login shell prints its own greeting around the answer, and
    /// `command -v` also names shell functions and builtins — neither of
    /// which the daemon can spawn.
    @MainActor
    func test_probeParsing_takesAbsolutePathsOutOfLoginShellNoise() {
        let output = """
        Welcome to Ubuntu 24.04 LTS
        __TERMMESH_CLI_AVAILABLE__
        __TERMMESH_CLI_PATH__=/root/.local/bin/codex
        __TERMMESH_BRIDGE_PATH__=/usr/local/bin/tm-agent-bridge
        """
        let parsed = TeamOrchestrator.parseRemoteAgentBinaries(output)
        XCTAssertTrue(parsed.cliAvailable)
        XCTAssertEqual(parsed.cliPath, "/root/.local/bin/codex")
        XCTAssertEqual(parsed.bridgePath, "/usr/local/bin/tm-agent-bridge")

        let noBridge = TeamOrchestrator.parseRemoteAgentBinaries("""
        __TERMMESH_CLI_AVAILABLE__
        __TERMMESH_CLI_PATH__=/usr/bin/kiro-cli
        __TERMMESH_BRIDGE_PATH__=
        """)
        XCTAssertTrue(noBridge.cliAvailable)
        XCTAssertEqual(noBridge.bridgePath, "", "an absent bridge is data, not an error")

        let shellFunction = TeamOrchestrator.parseRemoteAgentBinaries("""
        __TERMMESH_CLI_AVAILABLE__
        __TERMMESH_CLI_PATH__=codex () { ... }
        __TERMMESH_BRIDGE_PATH__=
        """)
        XCTAssertTrue(
            shellFunction.cliAvailable,
            "the terminal path types a bare name, where a function works fine"
        )
        XCTAssertEqual(
            shellFunction.cliPath, "",
            "but --exe needs a path, and a function is not one"
        )

        let missing = TeamOrchestrator.parseRemoteAgentBinaries("""
        __TERMMESH_CLI_PATH__=
        __TERMMESH_BRIDGE_PATH__=/usr/local/bin/tm-agent-bridge
        """)
        XCTAssertFalse(missing.cliAvailable)
    }

    /// The probe has to survive `sh -c '…'` quoting, and it must search the
    /// same PATH the launcher does — a probe that looks elsewhere answers a
    /// different question than the one asked.
    @MainActor
    func test_probeScript_isSingleQuoteSafeAndAsksForBothBinaries() {
        let script = TeamOrchestrator.remoteAgentBinariesProbe(
            cli: "codex", hostBinDirs: ["/opt/tools/bin"]
        )
        XCTAssertTrue(script.contains("tm-agent-bridge"))
        XCTAssertTrue(script.contains("'codex'"))
        XCTAssertTrue(script.contains("/opt/tools/bin"))
        XCTAssertTrue(script.hasPrefix("export PATH="))
    }

    // MARK: Wire shape and teardown

    @MainActor
    func test_ensureAndAttach_sendsAgentKindAndTakesCallbackDelivery() async throws {
        let socketPath = "/tmp/peer-agent-test-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: "abcdef01-0000-0000-0000-000000000000",
            cli: "codex",
            workingDirectory: "/root/work/term-mesh",
            model: "sonnet",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/root/.local/bin/codex",
                execPath: "/root/.local/bin/codex",
                bridgePath: "/usr/local/bin/tm-agent-bridge",
                cliAvailable: true
            )
        )

        let ensured = try await PeerPaneSession.ensureAndAttach(
            lease: lease,
            surfaceSpec: spec,
            attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
            hostSpec: hostSpec,
            agentCli: "codex"
        )
        defer { ensured.session.teardown() }

        let request = try XCTUnwrap(host.ensureRequests().first)
        XCTAssertEqual(request.kind, "agent", "without this the daemon spawns a PTY")
        XCTAssertEqual(request.executable, "/usr/local/bin/tm-agent-bridge")
        XCTAssertEqual(request.cwd, "/root/work/term-mesh")
        // The model is translated per CLI by `bridgeModelArg` — what this
        // pins is the vector's shape and that nothing got dropped between
        // building the spec and putting it on the wire.
        XCTAssertEqual(
            request.args,
            ["--cli", "codex", "--cwd", "/root/work/term-mesh",
             "--model", TeamOrchestrator.bridgeModelArg(cli: "codex", model: "sonnet"),
             "--exe", "/root/.local/bin/codex"]
        )

        let surface = ensured.session.originSurface
        XCTAssertEqual(surface.surfaceType, SessionHostPanes.agentSurfaceType)
        XCTAssertEqual(
            surface.agentCli, "codex",
            "openRemoteAgentPane reads this to pick the renderer"
        )
        guard case .callback = ensured.session.relaySession.ptyDelivery else {
            return XCTFail("an agent surface must not be delivered through the relay helper")
        }
    }

    /// A daemon that never advertised `surface.agent.v1` must be refused
    /// locally — the caller needs a decision it can fall back from, not a
    /// wire error, and no surface may be created on the way to finding out.
    @MainActor
    func test_ensureAndAttach_refusesAgentKindOnAHostWithoutTheCapability() async throws {
        let socketPath = "/tmp/peer-agent-nocap-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [PeerCapability.surfaceEnsureV1]
        )
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            let ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: TeamOrchestrator.peerAgentSurfaceSpec(
                    teamName: "my-team",
                    agentInstanceId: UUID().uuidString,
                    cli: "codex",
                    workingDirectory: "/root/work",
                    model: "sonnet",
                    binaries: TeamOrchestrator.RemoteAgentBinaries(
                        cliPath: "/root/.local/bin/codex",
                        bridgePath: "/usr/local/bin/tm-agent-bridge",
                        cliAvailable: true
                    )
                ),
                attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
                hostSpec: hostSpec,
                agentCli: "codex"
            )
            ensured.session.teardown()
            XCTFail("an agent ensure must not be issued to a host without surface.agent.v1")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(PeerCapability.surfaceAgentV1),
                "the refusal must name the missing capability, got \(error)"
            )
        }
        XCTAssertTrue(
            host.ensureRequests().isEmpty,
            "nothing may be created on a host that cannot own it"
        )
        _ = hostTask
    }

    @MainActor
    func test_ensureAndAttachRejectsInvalidEnvironmentBeforeHostRequest() async throws {
        let socketPath = "/tmp/peer-agent-bad-env-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
            ]
        )
        let hostTask = try host.start()
        defer { host.stop() }
        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            _ = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: TeamOrchestrator.peerAgentSurfaceSpec(
                    teamName: "my-team",
                    agentInstanceId: UUID().uuidString,
                    cli: "codex",
                    workingDirectory: "/root/work",
                    model: "sonnet",
                    binaries: TeamOrchestrator.RemoteAgentBinaries(
                        cliPath: "/root/.local/bin/codex",
                        bridgePath: "/usr/local/bin/tm-agent-bridge",
                        cliAvailable: true
                    )
                ),
                attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
                hostSpec: hostSpec,
                agentCli: "codex",
                environment: ["유니코드": "invalid"]
            )
            XCTFail("invalid environment must be rejected locally")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ASCII identifier"))
        }
        XCTAssertTrue(host.ensureRequests().isEmpty)
        _ = hostTask
    }

    /// The cleanup verb. `requestClosePane` cannot do this job: an agent
    /// surface is deliberately never placed in the workspace tree, so a close
    /// by pane id finds nothing and reports success while the bridge keeps
    /// running on the peer.
    @MainActor
    func test_terminatePeerAgentSurface_addressesTheSurfaceRegistryDirectly() async throws {
        let socketPath = "/tmp/peer-agent-term-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        let hostTask = try host.start()
        defer { host.stop() }

        await TeamOrchestrator.terminatePeerAgentSurface(
            hostSockPath: socketPath,
            surfaceID: host.surfaceID
        )

        XCTAssertEqual(host.terminatedIDs(), [host.surfaceID])
        _ = hostTask
    }

    /// Best effort, both ways: an unreachable host and an empty id are
    /// no-ops rather than a second failure stacked on the one being unwound.
    @MainActor
    func test_terminatePeerAgentSurface_isANoOpWithNothingToTalkTo() async {
        await TeamOrchestrator.terminatePeerAgentSurface(
            hostSockPath: "", surfaceID: Data(repeating: 1, count: 16)
        )
        await TeamOrchestrator.terminatePeerAgentSurface(
            hostSockPath: "/tmp/does-not-exist-\(getpid()).sock",
            surfaceID: Data(repeating: 1, count: 16)
        )
    }

    // MARK: Compensation after a committed ensure

    /// The ensure is the point of no return on the host, and the attach can
    /// still fail after it. Without compensation that failure produced the
    /// worst object in the system: a `tm-agent-bridge` running on the peer
    /// whose surface id nobody kept — not in the workspace tree (agent
    /// surfaces are never placed there), not in `ManagedPeerSurfaceStore`, not
    /// in any roster, so reachable by no cleanup UI at all. The caller then
    /// fell through to the terminal path and started a SECOND CLI in the same
    /// checkout, while telling the user "nothing was left running there".
    @MainActor
    func test_ensureAndAttach_takesTheSurfaceBackDownWhenTheAttachFails() async throws {
        let socketPath = "/tmp/peer-agent-orphan-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        host.redirectsAttach = true
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            let ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: TeamOrchestrator.peerAgentSurfaceSpec(
                    teamName: "my-team",
                    agentInstanceId: UUID().uuidString,
                    cli: "codex",
                    workingDirectory: "/root/work",
                    model: "sonnet",
                    binaries: TeamOrchestrator.RemoteAgentBinaries(
                        cliPath: "/root/.local/bin/codex",
                        execPath: "/root/.local/bin/codex",
                        bridgePath: "/usr/local/bin/tm-agent-bridge",
                        cliAvailable: true
                    )
                ),
                attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
                hostSpec: hostSpec,
                agentCli: "codex"
            )
            ensured.session.teardown()
            XCTFail("a redirected attach must not be reported as a successful one")
        } catch {
            // The failure itself is expected; what it must not do is keep the
            // surface.
        }

        XCTAssertEqual(host.ensureRequests().count, 1, "the ensure did commit a child")
        XCTAssertEqual(
            host.terminatedIDs(), [host.surfaceID],
            "the failed attach must spend the ensured surface id on the way out — "
                + "it is the only thing that can ever name that bridge again"
        )
        _ = hostTask
    }

    /// The remote-agent caller cannot rely on the best-effort compensation
    /// RPC: the same disconnect that breaks attach can break terminate too.
    /// It must durably record the ensured id before unwinding so reconnect can
    /// retry until the host confirms TERMINATED/NOT_FOUND.
    @MainActor
    func test_ensureAndAttach_durablyQueuesAgentWhenPostEnsureCleanupFails() async throws {
        let suiteName = "PostEnsureAgentCleanup-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostKey = "ssh:root@peer:/run/user/1000/term-mesh.sock"
        var cleanupAttempts = 0
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            automaticRetryDelay: 60,
            hostSockPathProvider: { _ in "/tmp/unreachable-peer.sock" },
            terminator: { _, _, _ in
                cleanupAttempts += 1
                return false
            }
        )
        let socketPath = "/tmp/peer-agent-durable-cleanup-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        host.redirectsAttach = true
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            _ = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: TeamOrchestrator.peerAgentSurfaceSpec(
                    teamName: "my-team",
                    agentInstanceId: UUID().uuidString,
                    cli: "codex",
                    workingDirectory: "/root/work",
                    model: "sonnet",
                    binaries: TeamOrchestrator.RemoteAgentBinaries(
                        cliPath: "/root/.local/bin/codex",
                        execPath: "/root/.local/bin/codex",
                        bridgePath: "/usr/local/bin/tm-agent-bridge",
                        cliAvailable: true
                    )
                ),
                attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
                hostSpec: hostSpec,
                agentCli: "codex",
                onAgentPostEnsureFailure: { surfaceID in
                    TeamOrchestrator.enqueuePendingPeerAgentSurfaceCleanup(
                        hostKey: hostKey,
                        surfaceID: surfaceID,
                        cleanup: cleanup
                    )
                }
            )
            XCTFail("a redirected attach must fail")
        } catch {
            // Expected after ensure committed the remote child.
        }

        for _ in 0..<20 where cleanupAttempts == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(cleanupAttempts, 1, "the scheduler should try immediately")
        XCTAssertEqual(cleanup.pendingRecords.first?.surfaceID, host.surfaceID)
        XCTAssertTrue(
            host.terminatedIDs().isEmpty,
            "the caller-owned compensation must not race a second one-shot terminate"
        )
        let restored = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false
        )
        XCTAssertEqual(restored.pendingRecords.first?.hostKey, hostKey)
        XCTAssertEqual(restored.pendingRecords.first?.surfaceID, host.surfaceID)
        _ = hostTask
    }

    /// A saved *runner* surface is the opposite case and must survive the same
    /// failure: it is keyed to a profile the user re-launches, and reusing that
    /// exact surface is the contract
    /// (`test_savedRunnerRepeatedLaunchReusesExactEnsuredSurfaceID`).
    /// Terminating one because an attach blipped would throw away the session
    /// it exists to preserve.
    @MainActor
    func test_ensureAndAttach_leavesATerminalRunnerSurfaceAloneWhenTheAttachFails() async throws {
        let socketPath = "/tmp/peer-runner-orphan-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        host.redirectsAttach = true
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            let ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: PeerRunnerSurfaceSpec(
                    key: "runner/build",
                    cwd: "/root/work",
                    executable: "/bin/bash"
                ),
                attachment: PeerRunnerAttachment(title: "Runner", lifetime: .keepAlive),
                hostSpec: hostSpec
            )
            ensured.session.teardown()
            XCTFail("a redirected attach must not be reported as a successful one")
        } catch {
        }

        XCTAssertEqual(host.ensureRequests().count, 1)
        XCTAssertTrue(
            host.terminatedIDs().isEmpty,
            "a runner surface outlives its attach on purpose — that is what makes "
                + "re-launching a saved profile reuse the same session"
        )
        _ = hostTask
    }
}

// MARK: - Peer-owned agent lifecycle (Phase 3 repairs)

/// The paths that have to know a peer-owned agent from every other kind of
/// member, and what each of them gets wrong when it does not.
///
/// The trap they all share: a peer-owned agent is the first member to have
/// BOTH an `AgentPanel` on this Mac and a `remoteSurfaceID` on a peer. Every
/// pre-existing branch treated those as mutually exclusive.
final class PeerOwnedAgentLifecycleTests: XCTestCase {

    /// `--exe` names an executable, not a role. kiro is the one CLI where
    /// those differ: the role is `kiro`, the ACP server the bridge spawns is
    /// `kiro-cli` (`daemon/tm-agent-bridge/src/main.rs` defaults to it, and
    /// `defaultLaunchCommand` has said the same for as long as kiro has been
    /// supported). Resolving `kiro` and passing it as `--exe` overrode that
    /// correct default with a launcher that cannot speak ACP.
    @MainActor
    func test_bridgeExecutableName_isTheBinaryNotTheRole() {
        XCTAssertEqual(TeamOrchestrator.peerAgentExecutableName(cli: "kiro"), "kiro-cli")
        XCTAssertEqual(TeamOrchestrator.peerAgentExecutableName(cli: "codex"), "codex")
        XCTAssertEqual(TeamOrchestrator.peerAgentExecutableName(cli: "cursor"), "cursor")
    }

    /// The probe asks for both names because they have different consumers:
    /// the terminal path types the ROLE at a login shell, `--exe` needs the
    /// binary the bridge spawns.
    @MainActor
    func test_probeScript_asksForTheBridgesExecutableTooNotJustTheRole() {
        let kiro = TeamOrchestrator.remoteAgentBinariesProbe(cli: "kiro", hostBinDirs: [])
        XCTAssertTrue(kiro.contains("'kiro'"), "the terminal path still types the role name")
        XCTAssertTrue(
            kiro.contains("'kiro-cli'"),
            "and --exe still needs the binary tm-agent-bridge actually spawns"
        )
    }

    /// Two markers, two answers. A host where `kiro` is a wrapper and
    /// `kiro-cli` is the real server must not have the wrapper's path end up
    /// on the bridge's command line.
    @MainActor
    func test_probeParsing_keepsTheRolePathAndTheExecutablePathApart() {
        let parsed = TeamOrchestrator.parseRemoteAgentBinaries("""
        __TERMMESH_CLI_AVAILABLE__
        __TERMMESH_CLI_PATH__=/usr/local/bin/kiro
        __TERMMESH_EXE_PATH__=/root/.local/bin/kiro-cli
        __TERMMESH_BRIDGE_PATH__=/usr/local/bin/tm-agent-bridge
        """)
        XCTAssertEqual(parsed.cliPath, "/usr/local/bin/kiro")
        XCTAssertEqual(parsed.execPath, "/root/.local/bin/kiro-cli")
        XCTAssertEqual(parsed.bridgePath, "/usr/local/bin/tm-agent-bridge")

        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "team",
            agentInstanceId: UUID().uuidString,
            cli: "kiro",
            workingDirectory: "/root/work",
            model: "sonnet",
            binaries: parsed
        )
        XCTAssertEqual(
            spec.args.last, "/root/.local/bin/kiro-cli",
            "--exe must be the ACP server, never the launcher named after the role"
        )
    }

    /// An absent executable path is data: `--exe` is omitted and the bridge
    /// falls back to its own default, which for kiro is already `kiro-cli`.
    @MainActor
    func test_ensureSpec_stillOmitsExeWhenNoExecutableWasResolved() {
        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "team",
            agentInstanceId: UUID().uuidString,
            cli: "kiro",
            workingDirectory: "/root/work",
            model: "sonnet",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/usr/local/bin/kiro",
                execPath: "",
                bridgePath: "/usr/local/bin/tm-agent-bridge",
                cliAvailable: true
            )
        )
        XCTAssertFalse(
            spec.args.contains("--exe"),
            "the role's own path is not a substitute for the executable's"
        )
    }

    /// Which daemon holds a surface decides who can reopen its pane.
    /// `SessionHostPanes.reconcile()` lists this Mac's daemon socket and
    /// nothing else, so answering "yes, local" for a peer surface is what
    /// silently retired a team member on the first healthy stream rewind.
    @MainActor
    func test_isLocalSessionHost_separatesThisMacsDaemonFromEveryPeer() {
        XCTAssertFalse(
            Workspace.isLocalSessionHost(
                .ssh(
                    target: "root@jw-server",
                    remoteSockPath: "/run/user/0/tm-peer.sock",
                    port: nil,
                    identityFile: nil
                )
            ),
            "an ssh peer is never reopened by the local poller"
        )
        XCTAssertFalse(
            Workspace.isLocalSessionHost(.direct(sockPath: "/tmp/some-other-daemon.sock"))
        )
        XCTAssertFalse(
            Workspace.isLocalSessionHost(.direct(sockPath: "")),
            "an empty path matches nothing, including an unset daemon path"
        )
        let daemonPath = TermMeshDaemon.shared.daemonPeerSocketPath
        if !daemonPath.isEmpty {
            XCTAssertTrue(Workspace.isLocalSessionHost(.direct(sockPath: daemonPath)))
        }
    }

    /// A peer-owned hard restart must replace the pane inside its live peer
    /// workspace. If that workspace is gone, fail before spawning anything and
    /// keep the old surface addressable so the user does not lose the session.
    @MainActor
    func test_peerOwnedRestartRequiresLiveWorkspaceBeforeReplacement() async {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "peer-owned-recycle-\(UUID().uuidString.prefix(8))"
        defer { orchestrator.forgetTeamForTests(teamName) }

        let member = TeamOrchestrator.AgentMember(
            id: "reviewer@\(teamName)",
            name: "reviewer",
            teamName: teamName,
            cli: "codex",
            launchCommand: "codex",
            model: "sonnet",
            agentType: "reviewer",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: UUID(),
            createdAt: Date(),
            remoteSurfaceID: Data(repeating: 0x5A, count: 16),
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            hostKey: "ssh:root@jw-server",
            originalAgentWorkDir: "/root/work/term-mesh"
        )
        orchestrator.installTeamForTests(name: teamName, agents: [member])

        let outcome = await orchestrator.restartAgentPaneHard(
            teamName: teamName,
            agentName: "reviewer"
        )
        guard case .failure(let error) = outcome else {
            return XCTFail("a peer-owned agent without a live workspace must not be replaced")
        }
        XCTAssertEqual(error.code, "workspace_missing")
        XCTAssertEqual(
            orchestrator.teams[teamName]?.agents.first?.remoteSurfaceID,
            Data(repeating: 0x5A, count: 16),
            "the failure must leave the surface id in the roster — it is the last "
                + "thing that can address the bridge"
        )
    }

    /// A remote ensure can take long enough for another agent to be added or
    /// detached. Committing the old Team value would erase that newer change;
    /// the replacement must patch only the member it originally observed.
    @MainActor
    func test_peerOwnedRestartRosterCASPreservesConcurrentMembersAndRejectsStaleTarget() {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "peer-owned-restart-cas-\(UUID().uuidString.prefix(8))"
        defer { orchestrator.forgetTeamForTests(teamName) }

        let oldPanelID = UUID()
        let oldSurfaceID = Data(repeating: 0x41, count: 16)
        let replacementPanelID = UUID()
        let replacementSurfaceID = Data(repeating: 0x42, count: 16)
        let siblingSurfaceID = Data(repeating: 0x51, count: 16)
        let old = TeamOrchestrator.AgentMember(
            id: "reviewer@\(teamName)",
            agentInstanceId: "reviewer-instance",
            name: "reviewer",
            teamName: teamName,
            cli: "codex",
            launchCommand: "codex",
            model: "sonnet",
            agentType: "reviewer",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: oldPanelID,
            createdAt: Date(),
            remoteSurfaceID: oldSurfaceID,
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            hostKey: "ssh:root@peer"
        )
        let sibling = TeamOrchestrator.AgentMember(
            id: "tester@\(teamName)",
            agentInstanceId: "tester-instance",
            name: "tester",
            teamName: teamName,
            cli: "claude",
            launchCommand: "claude",
            model: "sonnet",
            agentType: "tester",
            color: "blue",
            instructions: "",
            workspaceId: old.workspaceId,
            panelId: UUID(),
            createdAt: Date(),
            remoteSurfaceID: siblingSurfaceID,
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            hostKey: "ssh:root@peer"
        )
        var replacement = old
        replacement.panelId = replacementPanelID
        replacement.remoteSurfaceID = replacementSurfaceID
        orchestrator.installTeamForTests(name: teamName, agents: [old, sibling])

        guard let current = orchestrator.teams[teamName],
              let updated = TeamOrchestrator.teamByReplacingPeerOwnedAgent(
                  current: current,
                  expected: old,
                  replacement: replacement
              ) else {
            return XCTFail("the live target should be replaceable")
        }
        XCTAssertEqual(updated.agents.count, 2)
        XCTAssertEqual(updated.agents[0].panelId, replacementPanelID)
        XCTAssertEqual(updated.agents[1].remoteSurfaceID, siblingSurfaceID)

        XCTAssertNil(TeamOrchestrator.teamByReplacingPeerOwnedAgent(
            current: updated,
            expected: old,
            replacement: replacement
        ), "a stale completion must not overwrite the already replaced member")
        let rolledBack = TeamOrchestrator.teamByReplacingPeerOwnedAgent(
            current: updated,
            expected: replacement,
            replacement: old
        )
        XCTAssertEqual(rolledBack?.agents[0].panelId, oldPanelID)
        XCTAssertEqual(rolledBack?.agents[1].remoteSurfaceID, siblingSurfaceID)
    }

    /// Detach/delete/destroy all funnel through this: a member whose bridge
    /// the peer owns gets the terminate, and nothing else does. A local native
    /// agent has no peer surface, and a borrowed (not spawned) surface belongs
    /// to the host's operator.
    @MainActor
    func test_releasePeerOwnedAgentSurface_onlyActsOnAPeerOwnedAgent() {
        let suiteName = "PeerOwnedAgentReleaseTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            hostSockPathProvider: { _ in nil },
            terminator: { _, _, _ in false }
        )
        func member(
            remoteAgentSurface: Bool,
            spawned: Bool = true,
            surfaceID: Data? = Data(repeating: 0x5A, count: 16),
            hostKey: String? = "ssh:root@jw-server"
        ) -> TeamOrchestrator.AgentMember {
            TeamOrchestrator.AgentMember(
                id: "reviewer@t",
                name: "reviewer",
                teamName: "t",
                cli: "codex",
                launchCommand: "codex",
                model: "sonnet",
                agentType: "reviewer",
                color: "green",
                instructions: "",
                workspaceId: UUID(),
                panelId: UUID(),
                createdAt: Date(),
                remoteSurfaceID: surfaceID,
                remoteSurfaceSpawned: spawned,
                remoteAgentSurface: remoteAgentSurface,
                hostKey: hostKey
            )
        }
        // No host is registered in a unit test, so every call is a no-op at
        // the store lookup — what is pinned here is that none of them trap or
        // reach a `Task` with a half-built target.
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: false), cleanup: cleanup
        )
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: true, spawned: false), cleanup: cleanup
        )
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: true, surfaceID: nil), cleanup: cleanup
        )
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: true, hostKey: nil), cleanup: cleanup
        )
        XCTAssertTrue(cleanup.pendingRecords.isEmpty)
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: true), cleanup: cleanup
        )
        XCTAssertEqual(cleanup.pendingRecords.count, 1)
    }

    @MainActor
    func testPendingPeerAgentCleanupPersistsUntilTerminationIsConfirmed() async {
        let suiteName = "PendingPeerAgentCleanupTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostKey = "ssh:root@peer:/run/user/1000/term-mesh.sock"
        let surfaceID = Data(repeating: 0x4A, count: 16)

        let first = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults, observeNotifications: false
        )
        first.enqueue(hostKey: hostKey, surfaceID: surfaceID)
        XCTAssertEqual(first.pendingRecords.count, 1)

        let restored = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults, observeNotifications: false
        )
        XCTAssertEqual(restored.pendingRecords.first?.surfaceID, surfaceID)

        await restored.retryPending(
            hostSockPath: { _ in "/tmp/peer.sock" },
            terminate: { _, _, _ in false }
        )
        XCTAssertEqual(
            restored.pendingRecords.count, 1,
            "a transport/RPC failure must retain the only durable cleanup handle"
        )

        await restored.retryPending(
            hostSockPath: { _ in "/tmp/peer.sock" },
            terminate: { _, _, _ in true }
        )
        XCTAssertTrue(restored.pendingRecords.isEmpty)
        let afterConfirmation = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults, observeNotifications: false
        )
        XCTAssertTrue(afterConfirmation.pendingRecords.isEmpty)
    }

    @MainActor
    func testPendingPeerAgentCleanupUsesConnectedSocketBeforeLaunchMetadataResolves() async {
        let suiteName = "PendingPeerAgentCleanupUnresolvedMetadata-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostKey = "ssh:root@peer"
        let socketPath = "/tmp/authenticated-peer.sock"
        let host = HostEntry(
            id: hostKey,
            displayName: "peer",
            connectionState: .connected,
            workspaces: [],
            activeSockPath: socketPath,
            sshTarget: "root@peer",
            remoteSockPath: "/run/user/0/term-mesh.sock"
        )
        XCTAssertFalse(host.isLaunchable, "the launch metadata fixture must remain unresolved")
        var attemptedSocket: String?
        var attemptedHostKey: String?
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            automaticRetryDelay: 60,
            hostSockPathProvider: { requestedHostKey in
                PendingPeerAgentSurfaceCleanupStore.connectedHostSockPath(
                    for: requestedHostKey,
                    in: [host]
                )
            },
            terminator: { resolvedHostKey, resolvedSocket, _ in
                attemptedHostKey = resolvedHostKey
                attemptedSocket = resolvedSocket
                return true
            }
        )

        cleanup.enqueue(hostKey: hostKey, surfaceID: Data(repeating: 0x31, count: 16))
        cleanup.scheduleRetry()
        for _ in 0..<20 where attemptedSocket == nil {
            await Task.yield()
        }

        XCTAssertEqual(attemptedSocket, socketPath)
        // The host key rides along so cleanup can resolve the endpoint that
        // actually created the surface. Without it a redirected host's
        // tombstone is sent to the socket that merely served the handshake.
        XCTAssertEqual(attemptedHostKey, hostKey)
        XCTAssertTrue(cleanup.pendingRecords.isEmpty, "confirmed termination removes the tombstone")
        XCTAssertNil(
            PendingPeerAgentSurfaceCleanupStore.connectedHostSockPath(
                for: hostKey,
                in: [HostEntry(
                    id: hostKey,
                    displayName: "peer",
                    connectionState: .saved,
                    workspaces: [],
                    activeSockPath: socketPath,
                    sshTarget: "root@peer",
                    remoteSockPath: "/run/user/0/term-mesh.sock"
                )]
            ),
            "a disconnected row must not reuse its stale socket"
        )
    }

    @MainActor
    func testPreMemberPeerAgentCleanupQueuesDurableSurfaceHandle() {
        let suiteName = "PreMemberPeerAgentCleanup-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            hostSockPathProvider: { _ in nil },
            terminator: { _, _, _ in false }
        )
        let surfaceID = Data(repeating: 0x52, count: 16)

        TeamOrchestrator.enqueuePendingPeerAgentSurfaceCleanup(
            hostKey: "ssh:root@peer:/run/user/1000/term-mesh.sock",
            surfaceID: surfaceID,
            cleanup: cleanup
        )

        XCTAssertEqual(cleanup.pendingRecords.first?.surfaceID, surfaceID)
        let restored = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false
        )
        XCTAssertEqual(restored.pendingRecords.first?.surfaceID, surfaceID)
    }

    @MainActor
    func testPendingPeerAgentCleanupAutomaticallyRetriesWithoutRelayNotification() async {
        let suiteName = "PendingPeerAgentCleanupAutoRetry-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var attempts = 0
        let store = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            automaticRetryDelay: 0.01,
            hostSockPathProvider: { _ in "/tmp/peer.sock" },
            terminator: { _, _, _ in
                attempts += 1
                return attempts >= 2
            }
        )
        store.enqueue(
            hostKey: "ssh:root@peer:/run/user/1000/term-mesh.sock",
            surfaceID: Data(repeating: 0x6B, count: 16)
        )
        store.scheduleRetry()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(attempts, 2)
        XCTAssertTrue(store.pendingRecords.isEmpty)
    }

    @MainActor
    func testPeerAgentRecoveryRetriesTransientFailuresAndStopsOnSuccess() async {
        var attempts = 0
        var delays: [TimeInterval] = []
        let result = await TeamOrchestrator.retryPeerAgentPaneRecovery(
            maxAttempts: 6,
            sleep: { delays.append($0) },
            attempt: {
                attempts += 1
                return attempts < 3 ? .transientFailure : .recovered
            }
        )
        XCTAssertEqual(result, .recovered)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, [1, 2])
    }

    @MainActor
    func testPeerAgentRecoveryDoesNotRetryAuthoritativeAbsence() async {
        var attempts = 0
        let result = await TeamOrchestrator.retryPeerAgentPaneRecovery(
            maxAttempts: 6,
            sleep: { _ in XCTFail("authoritative absence must not back off") },
            attempt: {
                attempts += 1
                return .authoritativeMissing
            }
        )
        XCTAssertEqual(result, .authoritativeMissing)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testPeerAgentRecoveryIsBoundedAndRetainsCoordinatorRequest() async {
        let coordinator = PeerAgentPaneRecoveryCoordinator(observeNotifications: false)
        let request = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: "t",
            agentInstanceID: "instance",
            closedPanelID: UUID(),
            surfaceID: Data(repeating: 0x33, count: 16)
        )
        coordinator.remember(request)
        var attempts = 0
        let result = await TeamOrchestrator.retryPeerAgentPaneRecovery(
            maxAttempts: 3,
            sleep: { _ in },
            attempt: {
                attempts += 1
                return .transientFailure
            }
        )
        XCTAssertEqual(result, .transientFailure)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(coordinator.pending, [request])
        coordinator.forget(request)
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    @MainActor
    func testPeerAgentRecoveryCoordinatorAutomaticallyRetriesWithoutRelayNotification() async {
        var retries = 0
        let coordinator = PeerAgentPaneRecoveryCoordinator(
            observeNotifications: false,
            automaticRetryDelay: 0.01,
            retryAction: { retries += 1 }
        )
        let request = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: "t",
            agentInstanceID: "instance",
            closedPanelID: UUID(),
            surfaceID: Data(repeating: 0x77, count: 16)
        )
        coordinator.remember(request)
        coordinator.scheduleRetryIfNeeded()
        try? await Task.sleep(nanoseconds: 45_000_000)
        XCTAssertGreaterThanOrEqual(retries, 2)
        coordinator.forget(request)
    }

    @MainActor
    func testPeerAgentRecoveryCoordinatorStaleCompletionKeepsNewerRequest() {
        let coordinator = PeerAgentPaneRecoveryCoordinator(observeNotifications: false)
        let stale = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: "t",
            agentInstanceID: "instance",
            closedPanelID: UUID(),
            surfaceID: Data(repeating: 0x10, count: 16)
        )
        let replacement = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: stale.teamName,
            agentInstanceID: stale.agentInstanceID,
            closedPanelID: UUID(),
            surfaceID: Data(repeating: 0x20, count: 16)
        )

        coordinator.remember(stale)
        coordinator.remember(replacement)
        coordinator.forget(stale)

        XCTAssertEqual(coordinator.pending, [replacement])
        coordinator.forget(replacement)
    }

    @MainActor
    func testPeerAgentRecoveryOwnershipRevalidationRejectsDetachedOrReplacedMember() {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "peer-recovery-owner-\(UUID().uuidString.prefix(8))"
        let surfaceID = Data(repeating: 0x61, count: 16)
        let member = TeamOrchestrator.AgentMember(
            id: "reviewer@\(teamName)",
            agentInstanceId: "durable-instance",
            name: "reviewer",
            teamName: teamName,
            cli: "codex",
            launchCommand: "codex",
            model: "sonnet",
            agentType: "reviewer",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: UUID(),
            createdAt: Date(),
            remoteSurfaceID: surfaceID,
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            hostKey: "ssh:root@peer",
            originalAgentWorkDir: "/root/work"
        )
        defer { orchestrator.forgetTeamForTests(teamName) }
        orchestrator.installTeamForTests(name: teamName, agents: [member])

        XCTAssertTrue(orchestrator.ownsPeerAgentSurface(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            surfaceID: surfaceID
        ))
        XCTAssertFalse(orchestrator.ownsPeerAgentSurface(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            surfaceID: Data(repeating: 0x62, count: 16)
        ))

        orchestrator.forgetTeamForTests(teamName)
        var teardownCount = 0
        XCTAssertFalse(orchestrator.validatePeerAgentRecoveryOwnership(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            surfaceID: surfaceID,
            onMismatch: { teardownCount += 1 }
        ))
        XCTAssertEqual(teardownCount, 1, "a stale attached session must be torn down")
    }

    /// The field the three cleanup paths read. Defaulting it to false is what
    /// keeps every pre-existing member — local, native, terminal-backed peer —
    /// on exactly the branch it had before.
    @MainActor
    func test_remoteAgentSurface_defaultsToFalseForEveryOtherKindOfMember() {
        let terminalBacked = TeamOrchestrator.AgentMember(
            id: "reviewer@t",
            name: "reviewer",
            teamName: "t",
            cli: "codex",
            launchCommand: "codex",
            model: "sonnet",
            agentType: "reviewer",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: UUID(),
            createdAt: Date(),
            remoteSurfaceID: Data(repeating: 0x5A, count: 16),
            remoteSurfaceSpawned: true,
            hostKey: "ssh:root@jw-server"
        )
        XCTAssertFalse(terminalBacked.remoteAgentSurface)
    }
}

/// A peer daemon that answers ensure / attach / terminate and records what it
/// was asked for. Deliberately generic where `RunnerMockHost` is scripted:
/// these tests care about the SHAPE of the requests, and one of them checks
/// that a request never arrives at all.
private final class AgentSurfaceMockHost: @unchecked Sendable {
    enum Failure: Error {
        case syscall(String, Int32)
        case unexpectedMessage(String)
        case timedOut(String)
    }

    let socketPath: String
    let surfaceID = Data(repeating: 0x5A, count: 16)
    /// Answer every attach with a DIFFERENT surface id, which is how a host
    /// redirects an attachment and what `PeerRelaySession.attach` refuses with
    /// `surfaceIDMismatch`. The cheapest way to reach the one window that
    /// matters: the ensure has committed a child on the host and the attach
    /// then fails.
    var redirectsAttach = false
    private let capabilities: [String]
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFDs: Set<Int32> = []
    private var ensures: [Termmesh_Peer_V1_EnsureSurfaceRequest] = []
    private var terminated: [Data] = []
    private var deadline: Date = .distantFuture
    private static let listenerBudget: TimeInterval = 60

    init(socketPath: String, capabilities: [String]) {
        self.socketPath = socketPath
        self.capabilities = capabilities
    }

    func ensureRequests() -> [Termmesh_Peer_V1_EnsureSurfaceRequest] {
        lock.lock(); defer { lock.unlock() }
        return ensures
    }

    func terminatedIDs() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    func start() throws -> Task<Void, Error> {
        deadline = Date().addingTimeInterval(Self.listenerBudget)
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.syscall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else {
            close(fd)
            throw Failure.syscall("socket path", ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                for (offset, byte) in path.enumerated() {
                    bytes[offset] = CChar(bitPattern: byte)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.syscall("bind", code)
        }
        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            throw Failure.syscall("listen", code)
        }
        listenerFD = fd
        return Task.detached { [self] in
            defer { finishListener(fd) }
            while true {
                do {
                    try waitForEvent(fd: fd, event: Int16(POLLIN), operation: "accept")
                } catch {
                    return
                }
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                register(client)
                defer {
                    unregister(client)
                    close(client)
                }
                // A closed connection is how every one of these ends; the
                // conversation itself is what the tests assert on.
                try? serve(client: client)
            }
        }
    }

    func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        let clients = clientFDs
        lock.unlock()
        for client in clients { Darwin.shutdown(client, SHUT_RDWR) }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
    }

    private func finishListener(_ fd: Int32) {
        lock.lock()
        let owns = listenerFD == fd
        if owns { listenerFD = -1 }
        lock.unlock()
        if owns { close(fd) }
        unlink(socketPath)
    }

    private func register(_ fd: Int32) {
        lock.lock(); clientFDs.insert(fd); lock.unlock()
    }

    private func unregister(_ fd: Int32) {
        lock.lock(); clientFDs.remove(fd); lock.unlock()
    }

    private func serve(client: Int32) throws {
        guard case .hello = try readEnvelope(client).payload else {
            throw Failure.unexpectedMessage("expected Hello")
        }
        var hello = Termmesh_Peer_V1_Hello()
        hello.protocolVersion = "1.0.0"
        hello.peerID = Data(repeating: 0x31, count: 16)
        hello.displayName = "agent-mock"
        hello.appVersion = "test"
        hello.capabilities = capabilities
        try send(client) { $0.hello = hello }

        var challenge = Termmesh_Peer_V1_AuthChallenge()
        challenge.nonce = Data(repeating: 0x42, count: 32)
        challenge.supportedMethods = ["ssh-passthrough"]
        try send(client) { $0.authChallenge = challenge }
        guard case .auth = try readEnvelope(client).payload else {
            throw Failure.unexpectedMessage("expected Auth")
        }
        var authResult = Termmesh_Peer_V1_AuthResult()
        authResult.accepted = true
        authResult.sessionID = Data(repeating: 0x51, count: 16)
        try send(client) { $0.authResult = authResult }

        while true {
            let envelope = try readEnvelope(client)
            switch envelope.payload {
            case .ensureSurfaceRequest(let request):
                lock.lock(); ensures.append(request); lock.unlock()
                var response = Termmesh_Peer_V1_EnsureSurfaceResponse()
                response.requestID = request.requestID
                response.result = .created
                response.surfaceID = surfaceID
                response.instanceID = Data(repeating: 0x62, count: 16)
                response.generation = 1
                response.pid = 2424
                response.specHash = Data(repeating: 0x73, count: 32)
                try send(client) { $0.ensureSurfaceResponse = response }
            case .attachSurface(let attach):
                var attached = Termmesh_Peer_V1_AttachResult()
                attached.accepted = true
                attached.surfaceID = redirectsAttach
                    ? Data(repeating: 0x11, count: 16)
                    : attach.surfaceID
                attached.grantedMode = attach.mode
                try send(client) { $0.attachResult = attached }
            case .terminateSurfaceRequest(let request):
                lock.lock(); terminated.append(request.surfaceID); lock.unlock()
                var response = Termmesh_Peer_V1_TerminateSurfaceResponse()
                response.requestID = request.requestID
                response.result = .terminated
                response.surfaceID = request.surfaceID
                try send(client) { $0.terminateSurfaceResponse = response }
            case .goodbye:
                return
            default:
                continue
            }
        }
    }

    private func waitForEvent(fd: Int32, event: Int16, operation: String) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure.timedOut(operation) }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let timeoutMS = Int32(min(remaining * 1_000, Double(Int32.max)))
            let result = Darwin.poll(&descriptor, 1, timeoutMS)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else {
                if result == 0 { throw Failure.timedOut(operation) }
                throw Failure.syscall("poll \(operation)", errno)
            }
            guard descriptor.revents & event != 0 else {
                throw Failure.syscall("poll \(operation)", ECONNRESET)
            }
            return
        }
    }

    private func send(
        _ fd: Int32,
        configure: (inout Termmesh_Peer_V1_Envelope) -> Void
    ) throws {
        var envelope = Termmesh_Peer_V1_Envelope()
        configure(&envelope)
        try writeAll(fd, try encodeFrame(envelope))
    }

    private func readEnvelope(_ fd: Int32) throws -> Termmesh_Peer_V1_Envelope {
        var prefix = Data(count: 4)
        try readAll(fd, into: &prefix)
        let length = Int(prefix.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        var payload = Data(count: length)
        try readAll(fd, into: &payload)
        var frame = prefix + payload
        guard let envelope = try decodeFrame(from: &frame) else {
            throw Failure.unexpectedMessage("incomplete frame")
        }
        return envelope
    }

    private func readAll(_ fd: Int32, into data: inout Data) throws {
        var offset = 0
        let totalCount = data.count
        while offset < totalCount {
            try waitForEvent(fd: fd, event: Int16(POLLIN), operation: "read")
            let count = data.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress! + offset, totalCount - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.syscall("read", errno) }
            offset += count
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try waitForEvent(fd: fd, event: Int16(POLLOUT), operation: "write")
            let count = data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress! + offset, data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.syscall("write", errno) }
            offset += count
        }
    }
}
