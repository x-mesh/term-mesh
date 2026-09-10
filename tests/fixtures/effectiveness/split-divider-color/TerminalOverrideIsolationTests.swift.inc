
@MainActor
final class HiddenSplitDividerBehaviorAcceptanceTests: XCTestCase {
    func testOverrideSerializationAndResetUseExistingSettingsBoundary() throws {
        let suite = "term-mesh.hidden-divider.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("#5A6370", forKey: TerminalSettingsOverride.splitDividerColorKey)
        let configured = try XCTUnwrap(
            TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark)
        )
        XCTAssertTrue(configured.contains("split-divider-color = #5A6370"))

        defaults.removeObject(forKey: TerminalSettingsOverride.splitDividerColorKey)
        let reset = TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark) ?? []
        XCTAssertFalse(reset.contains { $0.hasPrefix("split-divider-color =") })
    }

    func testParsedDividerColorReachesBonsplitAppearance() {
        var config = GhosttyConfig()
        config.parse("background = #272822\nsplit-divider-color = #5A6370")

        let appearance = Workspace.bonsplitAppearance(from: config)
        XCTAssertEqual(appearance.chromeColors.borderHex, "#5A6370")
    }
}
