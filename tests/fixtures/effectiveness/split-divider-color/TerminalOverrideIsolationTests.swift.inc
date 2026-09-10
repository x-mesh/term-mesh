
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

    func testExistingWorkspaceAppliesConfiguredColorAndResetImmediately() throws {
        let suite = "term-mesh.hidden-divider-live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = TabManager(initialWorkingDirectory: "/tmp", persistsSessionState: false)
        let workspace = try XCTUnwrap(manager.selectedWorkspace)

        defaults.set("#5A6370", forKey: TerminalSettingsOverride.splitDividerColorKey)
        var configured = GhosttyConfig()
        configured.parse(try XCTUnwrap(
            TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark)
        ).joined(separator: "\n"))
        workspace.applyGhosttyChrome(from: configured, reason: "hiddenAcceptance.configured")
        XCTAssertEqual(
            workspace.bonsplitController.configuration.appearance.chromeColors.borderHex,
            "#5A6370"
        )

        defaults.removeObject(forKey: TerminalSettingsOverride.splitDividerColorKey)
        var reset = GhosttyConfig()
        if let lines = TerminalSettingsOverride.configLines(defaults: defaults, mode: .dark) {
            reset.parse(lines.joined(separator: "\n"))
        }
        workspace.applyGhosttyChrome(from: reset, reason: "hiddenAcceptance.reset")
        XCTAssertNil(workspace.bonsplitController.configuration.appearance.chromeColors.borderHex)
    }
}
