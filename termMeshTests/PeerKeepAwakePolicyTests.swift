import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerKeepAwakePolicyTests: XCTestCase {
    private func decision(_ mode: PeerKeepAwakeMode, ac: Bool = true, connections: Int) -> PeerKeepAwakePolicy.Decision {
        PeerKeepAwakePolicy.decision(mode: mode, onACPower: ac, connections: connections)
    }

    func test_aConnectionHoldsTheMacAwakeWhenTheModeAllowsIt() {
        XCTAssertEqual(decision(.always, connections: 1), .hold)
        XCTAssertEqual(decision(.onPowerAdapter, connections: 2), .hold)
        XCTAssertEqual(decision(.always, ac: false, connections: 1), .hold)
    }

    func test_theLastConnectionEndingReleasesOnlyAfterTheGrace() {
        // A tunnel being rebuilt reads as zero connections for a few seconds.
        XCTAssertEqual(decision(.always, connections: 0), .releaseAfterGrace)
        XCTAssertEqual(decision(.onPowerAdapter, connections: 0), .releaseAfterGrace)
        XCTAssertGreaterThan(PeerKeepAwakePolicy.releaseGraceSeconds, 0)
    }

    func test_turningItOffOrGoingOnBatteryReleasesAtOnce() {
        XCTAssertEqual(decision(.never, connections: 3), .releaseNow)
        XCTAssertEqual(decision(.onPowerAdapter, ac: false, connections: 1), .releaseNow)
    }

    func test_aHostOnBatteryStaysOutOfAppNapWithoutPreciseTimers() {
        let onAC = PeerKeepAwakePolicy.latencyActivityOptions(onACPower: true)
        let onBattery = PeerKeepAwakePolicy.latencyActivityOptions(onACPower: false)
        XCTAssertTrue(onAC.contains(.latencyCritical))
        XCTAssertFalse(onBattery.contains(.latencyCritical))
        for options in [onAC, onBattery] {
            XCTAssertTrue(options.contains(.userInitiatedAllowingIdleSystemSleep))
            XCTAssertFalse(options.contains(.idleSystemSleepDisabled), "idle sleep belongs to the keep-awake mode")
            XCTAssertFalse(options.contains(.idleDisplaySleepDisabled))
        }
    }

    private func status(
        _ mode: PeerKeepAwakeMode,
        ac: Bool = true,
        connections: Int,
        holding: Bool
    ) -> PeerKeepAwakeStatus {
        PeerKeepAwakePolicy.status(mode: mode, onACPower: ac, connections: connections, isHolding: holding)
    }

    func test_statusReportsAHeldAssertionAsPreventingSleep() {
        XCTAssertEqual(status(.always, connections: 2, holding: true), .holding(connections: 2))
        XCTAssertEqual(status(.always, connections: 0, holding: true), .releasingSoon)
        XCTAssertTrue(PeerKeepAwakeStatus.holding(connections: 1).isPreventingSleep)
        XCTAssertTrue(PeerKeepAwakeStatus.releasingSoon.isPreventingSleep)
    }

    func test_anEnabledModeWithoutAnAssertionStillLetsTheMacSleep() {
        XCTAssertEqual(status(.always, connections: 0, holding: false), .noConnections)
        XCTAssertEqual(status(.onPowerAdapter, ac: false, connections: 2, holding: false), .onBattery)
        XCTAssertEqual(status(.never, connections: 2, holding: false), .off)
        XCTAssertEqual(status(.always, connections: 1, holding: false), .failed, "a connection with no assertion means IOKit refused it")
        for sleeping in [PeerKeepAwakeStatus.noConnections, .onBattery, .off, .failed] {
            XCTAssertFalse(sleeping.isPreventingSleep)
            XCTAssertNil(sleeping.detail)
        }
    }

    func test_anUnknownStoredModeFallsBackToTheDefault() {
        let key = PeerFederationSettings.keepAwakeKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("sometimes", forKey: key)
        XCTAssertEqual(PeerFederationSettings.keepAwakeMode, PeerFederationSettings.defaultKeepAwakeMode)
        UserDefaults.standard.set(PeerKeepAwakeMode.never.rawValue, forKey: key)
        XCTAssertEqual(PeerFederationSettings.keepAwakeMode, .never)
    }
}
