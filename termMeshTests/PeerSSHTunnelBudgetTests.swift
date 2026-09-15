import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The two timeouts that decide what a slow link looks like in the log.
///
/// Their order is the whole contract. When this side's deadline expires
/// first it kills ssh mid-handshake, before ssh has written a word, and the
/// failure reads `socketNeverAppeared(… ssh stderr: )` with an empty tail —
/// which is how the most common tunnel failure on a flaky link became the
/// only one that never said why. Letting ssh time out first makes it report
/// its own reason and exit, which the spawn path turns into a
/// `spawnFailed(exitReason)`.
///
/// Nothing in the type system enforces the ordering, and either constant is
/// an easy thing to "tune" back into a tie. Hence this test.
final class PeerSSHTunnelBudgetTests: XCTestCase {

    func test_forwardSocketDeadlineOutlivesSSHConnectTimeout() {
        XCTAssertLessThan(
            TimeInterval(PeerSSHTunnel.sshConnectTimeoutSeconds),
            PeerSSHTunnel.forwardSocketDeadlineSeconds,
            "ssh must exhaust its own connect budget FIRST, so it reports the "
                + "reason instead of being killed silently mid-handshake."
        )
    }

    func test_deadlineLeavesRoomForSSHToReportAndExit() {
        // A one-second gap would satisfy the ordering above and still lose the
        // race in practice: ssh has to notice the timeout, write to stderr,
        // and exit, and the poll that observes it only runs every 150 ms.
        // Require a margin wide enough that the reporting path actually wins.
        let margin = PeerSSHTunnel.forwardSocketDeadlineSeconds
            - TimeInterval(PeerSSHTunnel.sshConnectTimeoutSeconds)
        XCTAssertGreaterThanOrEqual(
            margin,
            2,
            "Leave ssh room to report and exit before this side gives up."
        )
    }

    func test_connectTimeoutIsBoundedAtAll() {
        // The regression this whole pair exists for: the tunnel's ssh had no
        // ConnectTimeout, so it waited out the system TCP timeout (tens of
        // seconds) while our deadline fired first, every time.
        XCTAssertGreaterThan(PeerSSHTunnel.sshConnectTimeoutSeconds, 0)
        XCTAssertLessThanOrEqual(
            PeerSSHTunnel.sshConnectTimeoutSeconds,
            30,
            "An unbounded-in-practice connect budget defeats the ordering."
        )
    }

    func test_reaperEscalatesSIGTERMThenSIGKILLAndOnlyReportsExitAfterSecondWait() {
        let lock = NSLock()
        var events: [String] = []
        var waits = 0
        let policy = PeerSSHTunnelReaperPolicy(
            isRunning: { _ in true },
            terminate: { _ in lock.lock(); events.append("term"); lock.unlock() },
            waitForExit: { _, timeout in
                lock.lock()
                waits += 1
                events.append("wait-\(Int(timeout))")
                let exited = waits == 2
                lock.unlock()
                return exited
            },
            kill: { _ in lock.lock(); events.append("kill"); lock.unlock() }
        )
        XCTAssertTrue(PeerSSHTunnel.reap(Process(), policy: policy))
        lock.lock()
        XCTAssertEqual(events, ["term", "wait-2", "kill", "wait-1"])
        lock.unlock()
    }

    func test_reaperFailureAfterSecondWaitReturnsFalseWithoutClaimingExit() {
        let lock = NSLock()
        var events: [String] = []
        let policy = PeerSSHTunnelReaperPolicy(
            isRunning: { _ in true },
            terminate: { _ in lock.lock(); events.append("term"); lock.unlock() },
            waitForExit: { _, _ in lock.lock(); events.append("wait"); lock.unlock(); return false },
            kill: { _ in lock.lock(); events.append("kill"); lock.unlock() }
        )
        XCTAssertFalse(PeerSSHTunnel.reap(Process(), policy: policy))
        lock.lock()
        XCTAssertEqual(events, ["term", "wait", "kill", "wait"])
        lock.unlock()
    }

    @MainActor
    func test_shutdownCoordinatorReturnsBeforeBlockedReapAndReusesOneTerminalTask() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reaps = 0
        var unlinks = 0
        var terminalStates: [PeerSSHTunnelState] = []
        let coordinator = PeerSSHTunnelShutdownCoordinator(
            reap: { _ in
                lock.lock(); reaps += 1; lock.unlock()
                started.signal()
                _ = release.wait(timeout: .now() + 2)
                return true
            },
            unlink: { _ in lock.lock(); unlinks += 1; lock.unlock() }
        )
        let startedAt = Date()
        let first = coordinator.begin(process: nil, localSockPath: "/tmp/test.sock") { state in
            lock.lock(); terminalStates.append(state); lock.unlock()
        }
        let second = coordinator.begin(process: nil, localSockPath: "/tmp/test.sock") { state in
            lock.lock(); terminalStates.append(state); lock.unlock()
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.1)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        lock.lock()
        XCTAssertEqual(reaps, 1)
        XCTAssertEqual(unlinks, 0, "socket must remain until reap confirms exit")
        XCTAssertTrue(terminalStates.isEmpty)
        lock.unlock()
        release.signal()
        _ = await first.value
        _ = await second.value
        lock.lock()
        XCTAssertEqual(reaps, 1)
        XCTAssertEqual(unlinks, 1)
        XCTAssertEqual(terminalStates, [.stopped])
        lock.unlock()
        XCTAssertTrue(coordinator.isTerminal)
    }

    func test_adoptLaunchedProcessAfterStopReapsAndReturnsFalse() async throws {
        let tunnel = PeerSSHTunnel(
            sshTarget: "tester@example.invalid",
            remoteSockPath: "/tmp/tm-test-remote.sock"
        )
        let shutdown = tunnel.stop()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        addTeardownBlock {
            if child.isRunning { child.terminate() }
        }
        try child.run()

        XCTAssertFalse(tunnel.adoptLaunchedProcess(child))
        // `adoptLaunchedProcess` reaps synchronously on the losing side, so
        // the child must already be gone by the time it returns.
        XCTAssertFalse(child.isRunning)
        await shutdown.value
    }

    func test_adoptLaunchedProcessBeforeStopIsReapedByStop() async throws {
        let tunnel = PeerSSHTunnel(
            sshTarget: "tester@example.invalid",
            remoteSockPath: "/tmp/tm-test-remote.sock"
        )

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        addTeardownBlock {
            if child.isRunning { child.terminate() }
        }
        try child.run()

        XCTAssertTrue(tunnel.adoptLaunchedProcess(child))
        await tunnel.stop().value
        XCTAssertFalse(child.isRunning)
    }
}
