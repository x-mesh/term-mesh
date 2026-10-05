import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerKeepAwakePolicyTests: XCTestCase {
    func test_nothingConnectedNeverPreventsSleep() {
        for mode in PeerKeepAwakeMode.allCases {
            XCTAssertFalse(
                PeerKeepAwakePolicy.preventsSleep(mode: mode, onACPower: true, connectedHosts: 0, attachedPeers: 0),
                "\(mode) must let an idle Mac sleep"
            )
        }
    }

    func test_eitherSideOfAConnectionCounts() {
        XCTAssertTrue(PeerKeepAwakePolicy.preventsSleep(mode: .always, onACPower: true, connectedHosts: 1, attachedPeers: 0))
        XCTAssertTrue(PeerKeepAwakePolicy.preventsSleep(mode: .always, onACPower: true, connectedHosts: 0, attachedPeers: 1))
    }

    func test_onPowerAdapterLetsABatteryMacSleep() {
        XCTAssertTrue(PeerKeepAwakePolicy.preventsSleep(mode: .onPowerAdapter, onACPower: true, connectedHosts: 1, attachedPeers: 0))
        XCTAssertFalse(PeerKeepAwakePolicy.preventsSleep(mode: .onPowerAdapter, onACPower: false, connectedHosts: 1, attachedPeers: 0))
        XCTAssertTrue(PeerKeepAwakePolicy.preventsSleep(mode: .always, onACPower: false, connectedHosts: 1, attachedPeers: 0))
    }

    func test_neverIsOff() {
        XCTAssertFalse(PeerKeepAwakePolicy.preventsSleep(mode: .never, onACPower: true, connectedHosts: 3, attachedPeers: 2))
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
