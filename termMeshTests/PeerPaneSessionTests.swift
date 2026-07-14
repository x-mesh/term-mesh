import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerPaneSessionTests: XCTestCase {

    // MARK: - Host key identity

    func test_hostKey_identityAndLabels() {
        let ssh = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/tm-peer.sock")
        XCTAssertEqual(ssh.hostKey, .ssh(target: "root@jw-server"))
        XCTAssertEqual(ssh.hostKey.description, "ssh:root@jw-server")
        XCTAssertEqual(ssh.hostKey.shortLabel, "jw-server")
        XCTAssertEqual(ssh.hostKey.sshTarget, "root@jw-server")

        let direct = PeerPaneHostSpec.direct(sockPath: "/tmp/term-mesh-peer-501/peer.sock")
        XCTAssertEqual(direct.hostKey, .direct(sockPath: "/tmp/term-mesh-peer-501/peer.sock"))
        XCTAssertEqual(direct.hostKey.shortLabel, "peer.sock")
        XCTAssertNil(direct.hostKey.sshTarget)
    }

    func test_hostKey_sshPoolingIgnoresRemoteSockPath() {
        // Reconnects hand out fresh tunnel-local socket paths; the pool
        // identity must collapse them (same convention as
        // RemoteHostStore.stableKey).
        let a = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/a.sock")
        let b = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/b.sock")
        XCTAssertEqual(a.hostKey, b.hostKey)
    }

    // MARK: - Host accent determinism

    func test_hostAccent_isDeterministicPerHost() {
        let key = PeerPaneHostKey.ssh(target: "root@jw-server")
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
}
