import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The override files are generated FROM UserDefaults, which macOS separates
/// per bundle — but the files used to sit at one shared path every build wrote
/// to. A Debug build with empty defaults regenerated that file from nothing and
/// handed the installed app a terminal configuration nobody chose.
///
/// Two independent faults produced the same symptom, and both are covered here:
/// the shared location, and `double(forKey:)` answering `0` for a key that was
/// never written.
final class TerminalOverrideIsolationTests: XCTestCase {

    private var scratch: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("term-mesh-override-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defaultsSuite = "term-mesh.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        defaults.removePersistentDomain(forName: defaultsSuite)
        try super.tearDownWithError()
    }

    // MARK: - Directory scoping

    func test_directory_isScopedByBundleIdentifier() {
        let dir = TerminalOverrideLocation.directory(
            bundleIdentifier: "com.termmesh.app", appSupport: scratch
        )
        XCTAssertEqual(dir?.path, scratch.appendingPathComponent("term-mesh/com.termmesh.app").path)
    }

    /// The whole point: two builds must not resolve to the same file.
    func test_directory_differsBetweenBuilds() {
        let release = TerminalOverrideLocation.directory(
            bundleIdentifier: "com.termmesh.app", appSupport: scratch
        )
        let debug = TerminalOverrideLocation.directory(
            bundleIdentifier: "com.termmesh.app.debug", appSupport: scratch
        )
        XCTAssertNotNil(release)
        XCTAssertNotEqual(release, debug)
    }

    /// No bundle identifier (XCTest host, bare binary) has no identity to
    /// isolate by, so it keeps the pre-isolation path — behaviour unchanged
    /// is the safe direction there.
    func test_directory_withoutBundleIdentifier_fallsBackToLegacyPath() {
        let legacy = TerminalOverrideLocation.legacyDirectory(appSupport: scratch)
        XCTAssertEqual(
            TerminalOverrideLocation.directory(bundleIdentifier: nil, appSupport: scratch),
            legacy
        )
        XCTAssertEqual(
            TerminalOverrideLocation.directory(bundleIdentifier: "", appSupport: scratch),
            legacy
        )
    }

    // MARK: - Migration

    func test_migrate_seedsBuildDirectoryFromLegacy() throws {
        let legacy = scratch.appendingPathComponent("legacy")
        let destination = scratch.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let name = TerminalSettingsOverride.fileName
        try "unfocused-split-opacity = 1.00\n"
            .write(to: legacy.appendingPathComponent(name), atomically: true, encoding: .utf8)

        TerminalOverrideLocation.migrateLegacyFilesIfNeeded(
            legacy: legacy, destination: destination
        )

        let migrated = try String(contentsOf: destination.appendingPathComponent(name), encoding: .utf8)
        XCTAssertEqual(migrated, "unfocused-split-opacity = 1.00\n")
    }

    /// Copy, not move — whichever build runs first must not take the settings
    /// away from the other, so the source has to survive.
    func test_migrate_leavesLegacyFileInPlace() throws {
        let legacy = scratch.appendingPathComponent("legacy")
        let destination = scratch.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let source = legacy.appendingPathComponent(TerminalThemeOverride.overrideFileName)
        try "background = #ffffff\n".write(to: source, atomically: true, encoding: .utf8)

        TerminalOverrideLocation.migrateLegacyFilesIfNeeded(
            legacy: legacy, destination: destination
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// A build that already has its own file has already diverged on purpose;
    /// migration must never reach back and overwrite that.
    func test_migrate_doesNotOverwriteExistingDestination() throws {
        let legacy = scratch.appendingPathComponent("legacy")
        let destination = scratch.appendingPathComponent("build")
        let fm = FileManager.default
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = TerminalSettingsOverride.fileName
        try "from-legacy\n".write(to: legacy.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try "mine\n".write(to: destination.appendingPathComponent(name), atomically: true, encoding: .utf8)

        TerminalOverrideLocation.migrateLegacyFilesIfNeeded(
            legacy: legacy, destination: destination
        )

        let kept = try String(contentsOf: destination.appendingPathComponent(name), encoding: .utf8)
        XCTAssertEqual(kept, "mine\n")
    }

    /// The no-bundle-identifier fallback makes these two the same directory.
    /// Copying a file onto itself would throw; the guard must skip instead.
    func test_migrate_isNoOpWhenLegacyAndDestinationMatch() throws {
        let shared = scratch.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let url = shared.appendingPathComponent(TerminalSettingsOverride.fileName)
        try "kept\n".write(to: url, atomically: true, encoding: .utf8)

        TerminalOverrideLocation.migrateLegacyFilesIfNeeded(legacy: shared, destination: shared)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "kept\n")
    }

    // MARK: - Unset vs zero

    /// The regression itself. An empty defaults domain — which is exactly what
    /// a freshly built Debug app has — must produce no opacity line at all.
    /// It used to emit `unfocused-split-opacity = 0.00`, because
    /// `double(forKey:)` answers 0 for an absent key and 0 passed the `>= 0`
    /// check as a legitimate value.
    func test_configLines_unsetOpacityProducesNoLine() {
        let lines = TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark)
        XCTAssertNil(
            lines,
            "empty defaults must override nothing; got \(lines ?? [])"
        )
    }

    func test_configLines_setOpacityIsWritten() throws {
        defaults.set(1.0, forKey: TerminalSettingsOverride.unfocusedSplitOpacityKey)
        let lines = try XCTUnwrap(TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark))
        XCTAssertTrue(lines.contains("unfocused-split-opacity = 1.00"), "got \(lines)")
    }

    func test_configLines_setSplitDividerColorIsWritten() throws {
        defaults.set("#5A6370", forKey: TerminalSettingsOverride.splitDividerColorKey)
        let lines = try XCTUnwrap(TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark))
        XCTAssertTrue(lines.contains("split-divider-color = #5A6370"), "got \(lines)")
    }

    /// `-1` is the sentinel @AppStorage declares as its default for this key,
    /// so a domain carrying it explicitly means "not set" just as absence does.
    func test_configLines_negativeSentinelProducesNoLine() {
        defaults.set(-1.0, forKey: TerminalSettingsOverride.unfocusedSplitOpacityKey)
        XCTAssertNil(TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark))
    }

    /// Absence is not zero, but a zero the user actually stored is still their
    /// choice — this is what distinguishes the fix from simply banning 0.
    func test_configLines_explicitZeroIsStillHonoured() throws {
        defaults.set(0.0, forKey: TerminalSettingsOverride.unfocusedSplitOpacityKey)
        let lines = try XCTUnwrap(TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark))
        XCTAssertTrue(lines.contains("unfocused-split-opacity = 0.00"), "got \(lines)")
    }

    func test_storedDouble_distinguishesAbsentFromZero() {
        let key = TerminalSettingsOverride.unfocusedSplitOpacityKey
        XCTAssertNil(TerminalSettingsOverride.storedDouble(defaults, forKey: key))
        defaults.set(0.0, forKey: key)
        XCTAssertEqual(TerminalSettingsOverride.storedDouble(defaults, forKey: key), 0.0)
    }

    /// A key set through the Int overload must still read back — @AppStorage
    /// writes a Double, but a value like 1 can round-trip through the plist as
    /// an integer, and an `as? Double` cast on the raw object would drop it.
    func test_storedDouble_readsIntegerBackedValue() {
        let key = TerminalSettingsOverride.unfocusedSplitOpacityKey
        defaults.set(1, forKey: key)
        XCTAssertEqual(TerminalSettingsOverride.storedDouble(defaults, forKey: key), 1.0)
    }

    /// Other keys keep their own emptiness rules; this guards against a future
    /// edit generalising the opacity fix into something that drops them.
    func test_configLines_unrelatedKeysStillWrite() throws {
        defaults.set(16.0, forKey: TerminalSettingsOverride.fontSizeKey)
        defaults.set(50_000, forKey: TerminalSettingsOverride.scrollbackLimitKey)
        let lines = try XCTUnwrap(TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark))
        XCTAssertTrue(lines.contains("font-size = 16"), "got \(lines)")
        XCTAssertTrue(lines.contains("scrollback-limit = 50000"), "got \(lines)")
    }
}
