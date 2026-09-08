import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Covers the manual resync control.
///
/// Project state has no push channel: `ListTeams` is request/response, and the
/// roster the host does push carries workspaces alone. Work done on the host
/// itself — `tm-agent` over ssh, a manifest another installation rewrote — is
/// therefore invisible until this app asks again, and the sidebar had no way
/// to make it ask. These tests fix the two things that control depends on:
/// which hosts it may act on, and whether the sidebar can see it working.
@MainActor
final class RemoteHostResyncTests: XCTestCase {
    private func makeHost(
        id: String = "ssh:root@jw-server",
        connectionState: HostConnectionState = .connected,
        activeSockPath: String = "/tmp/active.sock"
    ) -> HostEntry {
        HostEntry(
            id: id,
            displayName: "jw-server",
            connectionState: connectionState,
            workspaces: [],
            activeSockPath: activeSockPath,
            sshTarget: "root@jw-server",
            remoteSockPath: "/run/term-mesh/tm-peer.sock"
        )
    }

    /// A host this app is not talking to has nothing to re-read, and the
    /// control must say that rather than start work that cannot land.
    func testResyncRefusesAHostThatIsNotConnected() {
        let store = RemoteHostStore.shared
        for state in [
            HostConnectionState.saved,
            .connecting,
            .failed("stopped responding")
        ] {
            let host = makeHost(id: "ssh:not-connected-\(state)", connectionState: state)
            XCTAssertFalse(
                store.resyncConnectedHost(host),
                "a \(state) host has no live endpoint to re-read"
            )
        }
    }

    /// The store keys every fetch by host id and reads the socket from its own
    /// entry, so a host it has never seen must be refused instead of resolved
    /// from the caller's stale copy.
    func testResyncRefusesAHostTheStoreDoesNotHold() {
        let store = RemoteHostStore.shared
        let stranger = makeHost(id: "ssh:never-registered-host")
        XCTAssertNil(
            store.hosts[stranger.id],
            "precondition: the store must not already know this host"
        )
        XCTAssertFalse(
            store.resyncConnectedHost(stranger),
            "a host absent from the store has no socket the fetch could use"
        )
    }

    /// The sidebar row is `Equatable` over `HostEntry`, so in-flight state has
    /// to travel on the entry. Held anywhere else the row is never asked to
    /// redraw and the control reads as dead while its work runs.
    /// Reconnect retires the pooled transport even while a pane still holds
    /// it, so the connect that follows cannot reuse a dead tunnel. Releasing
    /// only the sidebar's ref used to leave that lease pooled.
    @MainActor
    func testReconnectRetiresAPooledLeaseAPaneStillHolds() async throws {
        let store = RemoteHostStore.shared
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/rhr-unit-\(getpid())-reconnect.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        let teardownsBefore = registry.teardownCountForTests

        // A pane's ref, which the store never releases.
        let pane = try await registry.acquire(spec)
        // No SSH target: the spec resolves to the direct socket, and the
        // connect that reconnect would schedule has nothing to dial.
        let host = HostEntry(
            id: "direct:\(sockPath)",
            displayName: "local",
            connectionState: .connected,
            workspaces: [],
            activeSockPath: sockPath,
            sshTarget: nil,
            remoteSockPath: nil
        )

        let outcome = store.reconnectHost(host)
        XCTAssertTrue(outcome.transportReplaced, "the pooled lease is retired")
        XCTAssertEqual(outcome.previousSockPath, sockPath)
        XCTAssertFalse(outcome.started, "no SSH target — nothing to reconnect through")
        XCTAssertNil(registry.activeLease(forKey: key))
        XCTAssertEqual(registry.teardownCountForTests, teardownsBefore + 1)

        // The pane's late release must not revive anything.
        registry.release(pane)
        XCTAssertNil(registry.activeLease(forKey: key))
        XCTAssertEqual(registry.teardownCountForTests, teardownsBefore + 1)
    }

    /// With nothing pooled there is nothing to replace, and the outcome says
    /// so instead of claiming a fresh tunnel.
    @MainActor
    func testReconnectWithoutAPooledLeaseReportsNothingReplaced() {
        let store = RemoteHostStore.shared
        let host = HostEntry(
            id: "direct:rhr-none-\(getpid())",
            displayName: "local",
            connectionState: .saved,
            workspaces: [],
            activeSockPath: "/tmp/rhr-unit-\(getpid())-none.sock",
            sshTarget: nil,
            remoteSockPath: nil
        )
        let outcome = store.reconnectHost(host)
        XCTAssertFalse(outcome.transportReplaced)
        XCTAssertNil(outcome.previousSockPath)
        XCTAssertEqual(outcome.panesPreserved, 0)
        XCTAssertFalse(outcome.started)
        XCTAssertEqual(store.retryConnectingHost(host), outcome.started)
    }

    func testRefreshFlagTravelsOnTheEntryTheSidebarCompares() {
        var idle = makeHost()
        var running = idle
        running.isRefreshing = true

        XCTAssertFalse(idle.isRefreshing, "a fresh entry is not refreshing")
        XCTAssertNotEqual(
            idle, running,
            "the flag must change equality, or the sidebar row never redraws"
        )

        idle.isRefreshing = true
        XCTAssertEqual(idle, running, "equal entries stay equal once both are set")
    }
}
