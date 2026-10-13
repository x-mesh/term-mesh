import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

private actor TeamRosterTestClock {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func pendingCount(for duration: Duration) -> Int {
        waiters.count { $0.duration == duration }
    }

    func advanceNext(by duration: Duration) -> Bool {
        guard let index = waiters.firstIndex(where: { $0.duration == duration }) else { return false }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume()
        return true
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private actor TeamRosterFetchRecorder {
    private var entries: [(hostID: String, sockPath: String)] = []

    func record(hostID: String, sockPath: String) {
        entries.append((hostID, sockPath))
    }

    var count: Int { entries.count }
}

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
    private func waitForPending(
        _ duration: Duration, in clock: TeamRosterTestClock,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await clock.pendingCount(for: duration) > 0 { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(duration)", file: file, line: line)
    }

    private func waitForFetchCount(
        _ expected: Int, in recorder: TeamRosterFetchRecorder,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await recorder.count == expected { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(expected) roster fetches", file: file, line: line)
    }

    private func configureTeamRosterPolling(
        store: RemoteHostStore, hostID: String, sockPath: String
    ) -> (TeamRosterTestClock, TeamRosterFetchRecorder) {
        let clock = TeamRosterTestClock()
        let recorder = TeamRosterFetchRecorder()
        store.installTeamRosterPollFixture(hostID: hostID, sockPath: sockPath)
        store.configureTeamRosterPollingForTesting(
            sleeper: { duration in try await clock.sleep(for: duration) },
            refresh: { refreshedHostID, refreshedSockPath in
                await recorder.record(hostID: refreshedHostID, sockPath: refreshedSockPath)
                return []
            }
        )
        return (clock, recorder)
    }

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

    func testTeamRosterIdlePollFetchesAtSixtySecondIntervals() async {
        let store = RemoteHostStore.shared
        let hostID = "roster-poll-\(UUID())"
        let sockPath = "/tmp/rhr-poll-\(UUID()).sock"
        let (clock, recorder) = configureTeamRosterPolling(
            store: store, hostID: hostID, sockPath: sockPath
        )
        defer { store.removeTeamRosterPollFixture(hostID: hostID) }

        XCTAssertTrue(store.startTeamRosterUpdatesForTesting(hostID: hostID))
        await waitForPending(.milliseconds(200), in: clock)
        let startedRefresh = await clock.advanceNext(by: .milliseconds(200))
        XCTAssertTrue(startedRefresh)
        await waitForFetchCount(1, in: recorder)

        for expectedFetchCount in 2...4 {
            await waitForPending(.seconds(60), in: clock)
            let fifteenSecondWaits = await clock.pendingCount(for: .seconds(15))
            XCTAssertEqual(fifteenSecondWaits, 0)
            let advancedPoll = await clock.advanceNext(by: .seconds(60))
            XCTAssertTrue(advancedPoll)
            await waitForPending(.milliseconds(200), in: clock)
            let advancedRefresh = await clock.advanceNext(by: .milliseconds(200))
            XCTAssertTrue(advancedRefresh)
            await waitForFetchCount(expectedFetchCount, in: recorder)
        }
    }

    func testHostConnectedEventFetchesRosterBeforeIdlePoll() async {
        let store = RemoteHostStore.shared
        let hostID = "roster-connected-\(UUID())"
        let sockPath = "/tmp/rhr-connected-\(UUID()).sock"
        let (clock, recorder) = configureTeamRosterPolling(
            store: store, hostID: hostID, sockPath: sockPath
        )
        defer { store.removeTeamRosterPollFixture(hostID: hostID) }

        XCTAssertTrue(store.startTeamRosterUpdatesForTesting(hostID: hostID))
        await waitForPending(.milliseconds(200), in: clock)
        let idlePollWaits = await clock.pendingCount(for: .seconds(60))
        XCTAssertEqual(idlePollWaits, 1)
        let advancedRefresh = await clock.advanceNext(by: .milliseconds(200))
        XCTAssertTrue(advancedRefresh)
        await waitForFetchCount(1, in: recorder)
    }

    func testExplicitTeamRosterRefreshFetchesBeforeIdlePoll() async {
        let store = RemoteHostStore.shared
        let hostID = "roster-explicit-\(UUID())"
        let sockPath = "/tmp/rhr-explicit-\(UUID()).sock"
        let (clock, recorder) = configureTeamRosterPolling(
            store: store, hostID: hostID, sockPath: sockPath
        )
        defer { store.removeTeamRosterPollFixture(hostID: hostID) }

        store.refreshTeamRoster(forHostKey: hostID)
        await waitForPending(.milliseconds(200), in: clock)
        let idlePollWaits = await clock.pendingCount(for: .seconds(60))
        XCTAssertEqual(idlePollWaits, 0)
        let advancedRefresh = await clock.advanceNext(by: .milliseconds(200))
        XCTAssertTrue(advancedRefresh)
        await waitForFetchCount(1, in: recorder)
    }

    func testDisconnectCancelsTeamRosterPoll() async {
        let store = RemoteHostStore.shared
        let hostID = "roster-disconnect-\(UUID())"
        let sockPath = "/tmp/rhr-disconnect-\(UUID()).sock"
        let (clock, _) = configureTeamRosterPolling(
            store: store, hostID: hostID, sockPath: sockPath
        )
        defer { store.removeTeamRosterPollFixture(hostID: hostID) }

        XCTAssertTrue(store.startTeamRosterUpdatesForTesting(hostID: hostID))
        await waitForPending(.seconds(60), in: clock)
        guard let host = store.hosts[hostID] else {
            return XCTFail("fixture host missing")
        }
        _ = store.disconnectSavedHost(host)
        for _ in 0..<100 {
            let idlePollWaits = await clock.pendingCount(for: .seconds(60))
            let refreshWaits = await clock.pendingCount(for: .milliseconds(200))
            if idlePollWaits == 0, refreshWaits == 0 {
                return
            }
            await Task.yield()
        }
        XCTFail("disconnect left a team roster timer pending")
    }

    func testRedirectedDurableRosterLeaseReusesUntilSubscriptionStops() async {
        let store = RemoteHostStore.shared
        let registry = PeerPaneHostRegistry.shared
        let hostID = "roster-reuse-\(UUID())"
        let servingPath = "/tmp/rhr-serving-\(UUID()).sock"
        let spec = PeerPaneHostSpec.direct(sockPath: "/tmp/rhr-owner-\(UUID()).sock")
        let before = registry.teardownCountForTests
        store.installDurableRosterLeaseFixture(hostID: hostID, servingSockPath: servingPath)

        let acquiredFirst = await store.acquireDurableRosterLeaseForTesting(
            hostID: hostID, servingSockPath: servingPath, spec: spec
        )
        XCTAssertTrue(acquiredFirst)
        let first = registry.activeLease(forKey: spec.hostKey)
        let acquiredAgain = await store.acquireDurableRosterLeaseForTesting(
            hostID: hostID, servingSockPath: servingPath, spec: spec
        )
        XCTAssertTrue(acquiredAgain)
        XCTAssertTrue(registry.activeLease(forKey: spec.hostKey) === first)
        XCTAssertEqual(registry.teardownCountForTests, before)

        store.invalidateDurableRosterLeaseForTesting(hostID: hostID)
        XCTAssertNil(registry.activeLease(forKey: spec.hostKey))
        XCTAssertEqual(registry.teardownCountForTests, before + 1)
    }

    func testDurableRosterLeaseRouteReplacementAndInvalidationAreExact() async {
        let store = RemoteHostStore.shared
        let registry = PeerPaneHostRegistry.shared
        let hostID = "roster-replace-\(UUID())"
        let servingPath = "/tmp/rhr-serving-\(UUID()).sock"
        let old = PeerPaneHostSpec.direct(sockPath: "/tmp/rhr-old-\(UUID()).sock")
        let replacement = PeerPaneHostSpec.direct(sockPath: "/tmp/rhr-new-\(UUID()).sock")
        let before = registry.teardownCountForTests
        store.installDurableRosterLeaseFixture(hostID: hostID, servingSockPath: servingPath)

        let acquiredOld = await store.acquireDurableRosterLeaseForTesting(
            hostID: hostID, servingSockPath: servingPath, spec: old
        )
        XCTAssertTrue(acquiredOld)
        let acquiredReplacement = await store.acquireDurableRosterLeaseForTesting(
            hostID: hostID, servingSockPath: servingPath, spec: replacement
        )
        XCTAssertTrue(acquiredReplacement)
        XCTAssertNil(registry.activeLease(forKey: old.hostKey))
        XCTAssertNotNil(registry.activeLease(forKey: replacement.hostKey))
        XCTAssertEqual(registry.teardownCountForTests, before + 1)

        store.invalidateDurableRosterLeaseForTesting(hostID: hostID)
        store.invalidateDurableRosterLeaseForTesting(hostID: hostID)
        XCTAssertNil(registry.activeLease(forKey: replacement.hostKey))
        XCTAssertEqual(registry.teardownCountForTests, before + 2)
    }

    func testStaleDurableRosterLeaseAcquireIsReleased() async {
        let store = RemoteHostStore.shared
        let registry = PeerPaneHostRegistry.shared
        let hostID = "roster-stale-\(UUID())"
        let activePath = "/tmp/rhr-active-\(UUID()).sock"
        let stalePath = "/tmp/rhr-stale-\(UUID()).sock"
        let spec = PeerPaneHostSpec.direct(sockPath: "/tmp/rhr-owner-\(UUID()).sock")
        let before = registry.teardownCountForTests
        store.installDurableRosterLeaseFixture(hostID: hostID, servingSockPath: activePath)

        let acquired = await store.acquireDurableRosterLeaseForTesting(
            hostID: hostID, servingSockPath: stalePath, spec: spec
        )
        XCTAssertFalse(acquired)
        XCTAssertFalse(store.hasDurableRosterLeaseForTesting(hostID: hostID))
        XCTAssertNil(registry.activeLease(forKey: spec.hostKey))
        XCTAssertEqual(registry.teardownCountForTests, before + 1)
    }

    func testHandshakeFailureEvictsButListTeamsFailureCanPreserveDurableLease() async {
        let store = RemoteHostStore.shared
        let registry = PeerPaneHostRegistry.shared
        let hostID = "roster-failure-\(UUID())"
        let servingPath = "/tmp/rhr-serving-\(UUID()).sock"
        let spec = PeerPaneHostSpec.direct(sockPath: "/tmp/rhr-owner-\(UUID()).sock")
        let before = registry.teardownCountForTests
        store.installDurableRosterLeaseFixture(hostID: hostID, servingSockPath: servingPath)
        let acquiredFirst = await store.acquireDurableRosterLeaseForTesting(
            hostID: hostID, servingSockPath: servingPath, spec: spec
        )
        XCTAssertTrue(acquiredFirst)

        XCTAssertTrue(store.hasDurableRosterLeaseForTesting(hostID: hostID))
        XCTAssertEqual(registry.teardownCountForTests, before)
        store.invalidateDurableRosterLeaseForTesting(hostID: hostID)
        XCTAssertEqual(registry.teardownCountForTests, before + 1)
        let reacquired = await store.acquireDurableRosterLeaseForTesting(
            hostID: hostID, servingSockPath: servingPath, spec: spec
        )
        XCTAssertTrue(reacquired)
        store.setDebugRosterFailure(hostKey: hostID, reason: "ListTeams failed")
        XCTAssertTrue(store.hasDurableRosterLeaseForTesting(hostID: hostID))
        store.invalidateDurableRosterLeaseForTesting(hostID: hostID)
    }

    func testDirectHostDoesNotAllocateDurableRosterLease() async {
        let store = RemoteHostStore.shared
        let registry = PeerPaneHostRegistry.shared
        let hostID = "roster-direct-\(UUID())"
        let servingPath = "/tmp/rhr-serving-\(UUID()).sock"
        let spec = PeerPaneHostSpec.direct(sockPath: "/tmp/rhr-owner-\(UUID()).sock")
        store.installDurableRosterLeaseFixture(hostID: hostID, servingSockPath: servingPath)

        let acquired = await store.acquireDurableRosterLeaseForTesting(
            hostID: hostID, servingSockPath: servingPath, spec: spec, redirected: false
        )
        XCTAssertFalse(acquired)
        XCTAssertFalse(store.hasDurableRosterLeaseForTesting(hostID: hostID))
        XCTAssertNil(registry.activeLease(forKey: spec.hostKey))
    }
}
