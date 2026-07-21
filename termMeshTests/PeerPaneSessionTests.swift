import XCTest
import Darwin
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerPaneSessionTests: XCTestCase {

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
