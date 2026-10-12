import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class TermMeshSettingsObserverTests: XCTestCase {
    func testSnapshotReportsOnlyTrackedValueChanges() {
        let suiteName = "TermMeshSettingsObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = TermMeshUserDefaultsObserver.Snapshot.capture(defaults: defaults)
        defaults.set("dark", forKey: AppearanceSettings.appearanceModeKey)
        defaults.set("ignored", forKey: "unrelatedSetting")

        let changed = TermMeshUserDefaultsObserver.Snapshot.capture(defaults: defaults)
            .changedKeys(from: initial)
        XCTAssertEqual(changed, [AppearanceSettings.appearanceModeKey])

        let current = TermMeshUserDefaultsObserver.Snapshot.capture(defaults: defaults)
        XCTAssertTrue(current.changedKeys(from: current).isEmpty)
    }
}
