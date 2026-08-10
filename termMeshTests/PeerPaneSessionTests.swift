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
