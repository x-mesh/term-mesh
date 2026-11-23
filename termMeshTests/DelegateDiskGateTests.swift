import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class DelegateDiskGateTests: XCTestCase {

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "DelegateDiskGateTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testMinimumDefaultsToFiveGBWhenUnset() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DelegateDiskGate.minimumFreeGB(defaults: defaults), 5)
    }

    /// `UserDefaults.integer` reads an unset key as 0, which here means "off";
    /// only an explicitly stored 0 may turn the gate off.
    func testStoredValuesAreReadAsIs() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: DelegateDiskGate.minimumFreeGBKey)
        XCTAssertEqual(DelegateDiskGate.minimumFreeGB(defaults: defaults), 0)
        defaults.set(20, forKey: DelegateDiskGate.minimumFreeGBKey)
        XCTAssertEqual(DelegateDiskGate.minimumFreeGB(defaults: defaults), 20)
        defaults.set(-3, forKey: DelegateDiskGate.minimumFreeGBKey)
        XCTAssertEqual(DelegateDiskGate.minimumFreeGB(defaults: defaults), 0)
    }

    func testRefusesOnlyBelowTheMinimum() {
        XCTAssertEqual(
            DelegateDiskGate.refusal(availableBytes: 4_999_999_999, minimumGB: 5),
            DelegateDiskGate.Refusal(availableBytes: 4_999_999_999, minimumBytes: 5_000_000_000)
        )
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: 5_000_000_000, minimumGB: 5))
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: 120_000_000_000, minimumGB: 5))
    }

    func testOffOrUnmeasuredNeverRefuses() {
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: 1, minimumGB: 0))
        XCTAssertNil(DelegateDiskGate.refusal(availableBytes: nil, minimumGB: 5))
    }

    func testMessageNamesTheDiskAndHowToReclaim() {
        let refusal = DelegateDiskGate.Refusal(availableBytes: 3_200_000_000, minimumBytes: 5_000_000_000)
        let local = DelegateDiskGate.message(agentName: "backend", hostName: nil, refusal: refusal)
        XCTAssertTrue(local.contains("'backend'"))
        XCTAssertTrue(local.contains("on this Mac"))
        XCTAssertTrue(local.contains("3.2GB free"))
        XCTAssertTrue(local.contains("5.0GB minimum"))
        XCTAssertTrue(local.contains("Settings › Worktrees"))

        let remote = DelegateDiskGate.message(agentName: "backend", hostName: "jw-server", refusal: refusal)
        XCTAssertTrue(remote.contains("on jw-server"))
        XCTAssertTrue(remote.contains("on that host"))
    }
}
