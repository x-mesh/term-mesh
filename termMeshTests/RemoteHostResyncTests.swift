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
