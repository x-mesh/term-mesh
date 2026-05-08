import XCTest
import Foundation

// UI runners can adjust wall clock time mid-test; use monotonic uptime for polling deadlines.
private func pollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

final class UpdatePillUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testUpdatePillShowsForAvailableUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["TERMMESH_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TERMMESH_UI_TEST_UPDATE_STATE"] = "available"
        app.launchEnvironment["TERMMESH_UI_TEST_UPDATE_VERSION"] = "9.9.9"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Update Available: 9.9.9")
        assertVisibleSize(pill)
        attachScreenshot(name: "update-available")
        // Element screenshots are flaky on the UTM VM (image creation fails intermittently).
        // Keep a stable attachment with element state instead.
        attachElementDebug(name: "update-available-pill", element: pill)
    }

    func testUpdatePillShowsForNoUpdateThenDismisses() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let timingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-ui-test-timing-\(UUID().uuidString).json")
        let app = XCUIApplication()
        app.launchEnvironment["TERMMESH_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TERMMESH_UI_TEST_UPDATE_STATE"] = "notFound"
        app.launchEnvironment["TERMMESH_UI_TEST_TIMING_PATH"] = timingPath.path
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "No Updates Available")
        assertVisibleSize(pill)
        attachScreenshot(name: "no-updates")
        attachElementDebug(name: "no-updates-pill", element: pill)

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: pill
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 7.0), .completed)

        let payload = loadTimingPayload(from: timingPath)
        let shownAt = payload["noUpdateShownAt"] ?? 0
        let hiddenAt = payload["noUpdateHiddenAt"] ?? 0
        XCTAssertGreaterThan(shownAt, 0)
        XCTAssertGreaterThan(hiddenAt, shownAt)
        XCTAssertGreaterThanOrEqual(hiddenAt - shownAt, 4.8)
    }

    func testCheckForUpdatesUsesMockFeedWithUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = launchAppWithMockFeed(mode: "available", version: "9.9.9")

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Update Available: 9.9.9")
        assertVisibleSize(pill)
        attachScreenshot(name: "mock-update-available")
    }

    func testCheckForUpdatesUsesMockFeedWithNoUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let timingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-ui-test-timing-\(UUID().uuidString).json")
        let app = launchAppWithMockFeed(mode: "none", version: "9.9.9", timingPath: timingPath)

        let pill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "No Updates Available")
        assertVisibleSize(pill)
        attachScreenshot(name: "mock-no-updates")
    }

    func testCheckForUpdatesShowsLoadingThenNoUpdateInSidebarFooter() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = launchAppWithMockFeed(
            mode: "none",
            version: "9.9.9",
            extraEnvironment: [
                "TERMMESH_UI_TEST_MOCK_FEED_DELAY_MS": "7000",
            ]
        )

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let checkingPill = pillButton(app: app, expectedLabel: "Checking for Updates…")
        XCTAssertTrue(checkingPill.waitForExistence(timeout: 6.0))
        assertVisibleSize(checkingPill)

        let noUpdatePill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(noUpdatePill.waitForExistence(timeout: 8.0))
        assertVisibleSize(noUpdatePill)
    }

    func testCheckingPillRemainsVisibleForMinimumDuration() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        // Use a 1500ms mock-feed delay so the .checking state is held long enough to measure.
        let app = launchAppWithMockFeed(
            mode: "none",
            version: "9.9.9",
            extraEnvironment: ["TERMMESH_UI_TEST_MOCK_FEED_DELAY_MS": "1500"]
        )

        let checkingPill = pillButton(app: app, expectedLabel: "Checking for Updates…")
        XCTAssertTrue(checkingPill.waitForExistence(timeout: 6.0))
        assertVisibleSize(checkingPill)

        // minimumCheckDisplayDuration is 2.0s; verify pill hasn't gone after 0.8s.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(checkingPill.exists, "Checking pill disappeared before 0.8s")

        // Then confirm it eventually resolves to the upToDate state.
        let resolvedPill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(resolvedPill.waitForExistence(timeout: 5.0))
        assertVisibleSize(resolvedPill)
        attachElementDebug(name: "checking-resolved-pill", element: resolvedPill)
    }

    func testUpToDatePillIsStillVisibleAtThreeSeconds() {
        // noUpdateDisplayDuration is 5.0s; pill must still be present at the 3s mark.
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["TERMMESH_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TERMMESH_UI_TEST_UPDATE_STATE"] = "notFound"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        assertVisibleSize(pill)
        attachElementDebug(name: "up-to-date-pill-initial", element: pill)

        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        XCTAssertTrue(pill.exists, "upToDate pill disappeared before 3s (noUpdateDisplayDuration=5.0)")

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: pill
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [gone], timeout: 5.0),
            .completed,
            "upToDate pill did not auto-fade within 8s total"
        )
    }

    func testErrorPillShowsRetryButton() throws {
        // Requires TERMMESH_UI_TEST_UPDATE_STATE="error" support in UpdateTestSupport.applyIfNeeded.
        // Add the "error" case to Sources/Update/UpdateTestSupport.swift to enable this test.
        throw XCTSkip("Needs 'error' case in UpdateTestSupport (Sources/Update/UpdateTestSupport.swift)")
    }

    private func pillButton(app: XCUIApplication, expectedLabel: String) -> XCUIElement {
        // On macOS, SwiftUI accessibility identifiers are not always reliably surfaced for titlebar-style
        // UI across OS/Xcode versions. Prefer the pill's accessibility label, but keep an identifier
        // fallback for local runs.
        return app.buttons[expectedLabel]
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func assertVisibleSize(_ element: XCUIElement, timeout: TimeInterval = 2.0) {
        let pollInterval: TimeInterval = 0.05
        var size = element.frame.size
        var exists = element.exists
        var hittable = element.isHittable

        let visible = pollUntil(timeout: timeout, pollInterval: pollInterval) {
            size = element.frame.size
            exists = element.exists
            hittable = element.isHittable
            return size.width > 20 && size.height > 10
        }
        if !visible {
            XCTFail(
                "Expected UpdatePill to have visible size, got \(size), exists=\(exists), hittable=\(hittable)"
            )
        }
    }

    private func attachScreenshot(name: String, screenshot: XCUIScreenshot = XCUIScreen.main.screenshot()) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachElementDebug(name: String, element: XCUIElement) {
        let payload = """
        label: \(element.label)
        exists: \(element.exists)
        hittable: \(element.isHittable)
        frame: \(element.frame)
        """
        let attachment = XCTAttachment(string: payload)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchAppWithMockFeed(
        mode: String,
        version: String,
        timingPath: URL? = nil,
        extraEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TERMMESH_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TERMMESH_UI_TEST_FEED_URL"] = "https://term-mesh.test/appcast.xml"
        app.launchEnvironment["TERMMESH_UI_TEST_FEED_MODE"] = mode
        app.launchEnvironment["TERMMESH_UI_TEST_UPDATE_VERSION"] = version
        app.launchEnvironment["TERMMESH_UI_TEST_TRIGGER_UPDATE_CHECK"] = "1"
        if let timingPath {
            app.launchEnvironment["TERMMESH_UI_TEST_TIMING_PATH"] = timingPath.path
        }
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        launchAndActivate(app)
        return app
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        app.launch()
        let activated = pollUntil(timeout: activateTimeout) {
            guard app.state != .runningForeground else {
                return true
            }
            app.activate()
            return app.state == .runningForeground
        }
        if !activated {
            app.activate()
        }
    }

    private func loadTimingPayload(from url: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else {
            return [:]
        }
        return object
    }
}

final class TitlebarShortcutHintsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTitlebarShortcutHintsAlignWithoutShiftingControls() {
        let baselineApp = launchApp(alwaysShowHints: false)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: baselineApp, timeout: 8.0))

        let baselineToggle = baselineApp.buttons["titlebarControl.toggleSidebar"]
        let baselineNotifications = baselineApp.buttons["titlebarControl.showNotifications"]
        let baselineNewTab = baselineApp.buttons["titlebarControl.newTab"]

        XCTAssertTrue(waitForElementVisible(baselineToggle, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(baselineNotifications, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(baselineNewTab, timeout: 6.0))

        let baselineToggleFrame = baselineToggle.frame
        let baselineNotificationsFrame = baselineNotifications.frame
        let baselineNewTabFrame = baselineNewTab.frame

        baselineApp.terminate()

        let hintedApp = launchApp(alwaysShowHints: true)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: hintedApp, timeout: 8.0))

        let hintedToggle = hintedApp.buttons["titlebarControl.toggleSidebar"]
        let hintedNotifications = hintedApp.buttons["titlebarControl.showNotifications"]
        let hintedNewTab = hintedApp.buttons["titlebarControl.newTab"]

        XCTAssertTrue(waitForElementVisible(hintedToggle, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(hintedNotifications, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(hintedNewTab, timeout: 6.0))

        let sidebarHint = hintedApp.staticTexts["titlebarShortcutHint.toggleSidebar"]
        let notificationsHint = hintedApp.staticTexts["titlebarShortcutHint.showNotifications"]
        let newTabHint = hintedApp.staticTexts["titlebarShortcutHint.newTab"]

        XCTAssertTrue(waitForElementVisible(sidebarHint, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(notificationsHint, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(newTabHint, timeout: 6.0))

        let hintedToggleFrame = hintedToggle.frame
        let hintedNotificationsFrame = hintedNotifications.frame
        let hintedNewTabFrame = hintedNewTab.frame

        XCTAssertEqual(hintedToggleFrame.minY, baselineToggleFrame.minY, accuracy: 1.0)
        XCTAssertEqual(hintedNotificationsFrame.minY, baselineNotificationsFrame.minY, accuracy: 1.0)
        XCTAssertEqual(hintedNewTabFrame.minY, baselineNewTabFrame.minY, accuracy: 1.0)

        let sidebarHintFrame = sidebarHint.frame
        let notificationsHintFrame = notificationsHint.frame
        let newTabHintFrame = newTabHint.frame

        XCTAssertEqual(sidebarHintFrame.minY, notificationsHintFrame.minY, accuracy: 1.0)
        XCTAssertEqual(notificationsHintFrame.minY, newTabHintFrame.minY, accuracy: 1.0)
        // Keep the sidebar hint lane to the right of the sidebar icon so it cannot clip into the traffic-light backdrop.
        XCTAssertGreaterThanOrEqual(sidebarHintFrame.minX, hintedToggleFrame.minX - 1.0)

        let sortedHintFrames = [sidebarHintFrame, notificationsHintFrame, newTabHintFrame]
            .sorted { $0.minX < $1.minX }
        for index in 1..<sortedHintFrames.count {
            let previousFrame = sortedHintFrames[index - 1]
            let currentFrame = sortedHintFrames[index]
            XCTAssertGreaterThanOrEqual(currentFrame.minX - previousFrame.maxX, 2.0)
        }
    }

    private func launchApp(alwaysShowHints: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TERMMESH_UI_TEST_MODE"] = "1"
        app.launchArguments += ["-shortcutHintAlwaysShow", alwaysShowHints ? "YES" : "NO"]
        app.launchArguments += ["-shortcutHintTitlebarXOffset", "4"]
        app.launchArguments += ["-shortcutHintTitlebarYOffset", "0"]
        app.launch()

        _ = pollUntil(timeout: 2.0) {
            guard app.state != .runningForeground else {
                return true
            }
            app.activate()
            return app.state == .runningForeground
        }

        return app
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func waitForElementVisible(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            if element.exists {
                let frame = element.frame
                if frame.width > 1, frame.height > 1 {
                    return true
                }
            }
            return false
        }
    }
}
