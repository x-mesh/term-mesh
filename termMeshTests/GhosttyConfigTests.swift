import XCTest
import AppKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class GhosttyConfigTests: XCTestCase {
    private struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    func testResolveThemeNamePrefersLightEntryForPairedTheme() {
        let resolved = GhosttyConfig.resolveThemeName(
            from: "light:Builtin Solarized Light,dark:Builtin Solarized Dark",
            preferredColorScheme: .light
        )

        XCTAssertEqual(resolved, "Builtin Solarized Light")
    }

    func testResolveThemeNamePrefersDarkEntryForPairedTheme() {
        let resolved = GhosttyConfig.resolveThemeName(
            from: "light:Builtin Solarized Light,dark:Builtin Solarized Dark",
            preferredColorScheme: .dark
        )

        XCTAssertEqual(resolved, "Builtin Solarized Dark")
    }

    func testThemeNameCandidatesIncludeBuiltinAliasForms() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Light")
        XCTAssertEqual(candidates.first, "Builtin Solarized Light")
        XCTAssertTrue(candidates.contains("Solarized Light"))
        XCTAssertTrue(candidates.contains("iTerm2 Solarized Light"))
    }

    func testThemeNameCandidatesMapSolarizedDarkToITerm2Alias() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Dark")
        XCTAssertTrue(candidates.contains("Solarized Dark"))
        XCTAssertTrue(candidates.contains("iTerm2 Solarized Dark"))
    }

    func testThemeSearchPathsIncludeXDGDataDirsThemes() {
        let pathA = "/tmp/term-mesh-theme-a"
        let pathB = "/tmp/term-mesh-theme-b"
        let paths = GhosttyConfig.themeSearchPaths(
            forThemeName: "Solarized Light",
            environment: ["XDG_DATA_DIRS": "\(pathA):\(pathB)"],
            bundleResourceURL: nil
        )

        XCTAssertTrue(paths.contains("\(pathA)/ghostty/themes/Solarized Light"))
        XCTAssertTrue(paths.contains("\(pathB)/ghostty/themes/Solarized Light"))
    }

    func testLoadThemeResolvesPairedThemeValueByColorScheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-ghostty-theme-pair-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        background = #fdf6e3
        foreground = #657b83
        """.write(
            to: themesDir.appendingPathComponent("Light Theme"),
            atomically: true,
            encoding: .utf8
        )

        try """
        background = #002b36
        foreground = #93a1a1
        """.write(
            to: themesDir.appendingPathComponent("Dark Theme"),
            atomically: true,
            encoding: .utf8
        )

        var lightConfig = GhosttyConfig()
        lightConfig.loadTheme(
            "light:Light Theme,dark:Dark Theme",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil,
            preferredColorScheme: .light
        )
        XCTAssertEqual(rgb255(lightConfig.backgroundColor), RGB(red: 253, green: 246, blue: 227))

        var darkConfig = GhosttyConfig()
        darkConfig.loadTheme(
            "light:Light Theme,dark:Dark Theme",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil,
            preferredColorScheme: .dark
        )
        XCTAssertEqual(rgb255(darkConfig.backgroundColor), RGB(red: 0, green: 43, blue: 54))
    }

    func testLoadThemeResolvesBuiltinAliasFromGhosttyResourcesDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-ghostty-themes-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let themePath = themesDir.appendingPathComponent("Solarized Light")
        let themeContents = """
        background = #fdf6e3
        foreground = #657b83
        """
        try themeContents.write(to: themePath, atomically: true, encoding: .utf8)

        var config = GhosttyConfig()
        config.loadTheme(
            "Builtin Solarized Light",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil
        )

        XCTAssertEqual(rgb255(config.backgroundColor), RGB(red: 253, green: 246, blue: 227))
    }

    func testLegacyConfigFallbackUsesLegacyFileWhenConfigGhosttyIsEmpty() {
        XCTAssertTrue(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: 42
            )
        )
    }

    func testLegacyConfigFallbackSkipsWhenNewFileMissingOrLegacyEmpty() {
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: nil,
                legacyConfigFileSize: 42
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 10,
                legacyConfigFileSize: 42
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: 0
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: nil
            )
        )
    }

    func testDefaultBackgroundUpdateScopePrioritizesSurfaceOverAppAndUnscoped() {
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .unscoped,
                incomingScope: .app
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .app,
                incomingScope: .surface
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .surface
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .app
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .unscoped
            )
        )
    }

    func testClaudeCodeIntegrationDefaultsToEnabledWhenUnset() {
        let suiteName = "term-mesh.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
    }

    func testClaudeCodeIntegrationRespectsStoredPreference() {
        let suiteName = "term-mesh.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))

        defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertFalse(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
    }

    private func rgb255(_ color: NSColor) -> RGB {
        let srgb = color.usingColorSpace(.sRGB)!
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(
            red: Int(round(red * 255)),
            green: Int(round(green * 255)),
            blue: Int(round(blue * 255))
        )
    }
}

final class WorkspaceChromeThemeTests: XCTestCase {
    func testResolvedChromeColorsUsesLightGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#FDF6E3")
        XCTAssertNil(colors.borderHex)
    }

    func testResolvedChromeColorsUsesDarkGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertNil(colors.borderHex)
    }
}

final class WorkspaceAppearanceConfigResolutionTests: XCTestCase {
    func testAppearanceConfigCacheLoadsOnceAndUsesStoredRefresh() {
        let cache = WorkspaceAppearanceConfigCache()
        var loadCount = 0
        var initial = GhosttyConfig()
        initial.fontSize = 13

        XCTAssertEqual(cache.snapshot {
            loadCount += 1
            return initial
        }.fontSize, 13)
        XCTAssertEqual(cache.snapshot {
            loadCount += 1
            var unexpected = GhosttyConfig()
            unexpected.fontSize = 99
            return unexpected
        }.fontSize, 13)
        XCTAssertEqual(loadCount, 1)

        var refreshed = GhosttyConfig()
        refreshed.fontSize = 17
        cache.store(refreshed)

        XCTAssertEqual(cache.snapshot {
            XCTFail("Stored refresh should satisfy future state initializers")
            return GhosttyConfig()
        }.fontSize, 17)
    }

    func testResolvedAppearanceConfigPrefersGhosttyRuntimeBackgroundOverLoadedConfig() {
        guard let loadedBackground = NSColor(hex: "#112233"),
              let runtimeBackground = NSColor(hex: "#FDF6E3"),
              let loadedForeground = NSColor(hex: "#ABCDEF") else {
            XCTFail("Expected valid test colors")
            return
        }

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground
        loaded.foregroundColor = loadedForeground
        loaded.unfocusedSplitOpacity = 0.42

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground }
        )

        XCTAssertEqual(resolved.backgroundColor.hexString(), "#FDF6E3")
        XCTAssertEqual(resolved.foregroundColor.hexString(), "#ABCDEF")
        XCTAssertEqual(resolved.unfocusedSplitOpacity, 0.42, accuracy: 0.0001)
    }

    func testResolvedAppearanceConfigPrefersExplicitBackgroundOverride() {
        guard let loadedBackground = NSColor(hex: "#112233"),
              let runtimeBackground = NSColor(hex: "#FDF6E3"),
              let explicitOverride = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test colors")
            return
        }

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            backgroundOverride: explicitOverride,
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground }
        )

        XCTAssertEqual(resolved.backgroundColor.hexString(), "#272822")
    }
}

final class TitlebarGitSnapshotCacheTests: XCTestCase {
    private var cleanMain: TitlebarGitSnapshot {
        TitlebarGitSnapshot(branch: "main", isDirty: false, dirtyCount: 0, isWorktree: false)
    }

    func testRecentSnapshotIsReusedUntilTTLExpires() {
        let cache = TitlebarGitSnapshotCache(ttl: 2, negativeTTL: 10)
        var loadCount = 0
        var results: [TitlebarGitSnapshot] = []

        cache.resolve(directory: "/tmp/repo", now: 10, load: {
            loadCount += 1
            return cleanMain
        }, completion: { results.append($0) })
        cache.resolve(directory: "/tmp/repo/", now: 11.9, load: {
            loadCount += 1
            return TitlebarGitSnapshot(branch: "unexpected", isDirty: true, dirtyCount: 1, isWorktree: false)
        }, completion: { results.append($0) })

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(results, [cleanMain, cleanMain])

        let refreshed = TitlebarGitSnapshot(branch: "develop", isDirty: true, dirtyCount: 2, isWorktree: false)
        cache.resolve(directory: "/tmp/repo", now: 12.1, load: {
            loadCount += 1
            return refreshed
        }, completion: { results.append($0) })

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(results.last, refreshed)
    }

    func testNegativeSnapshotUsesLongerTTL() {
        let cache = TitlebarGitSnapshotCache(ttl: 2, negativeTTL: 10)
        let missing = TitlebarGitSnapshot(branch: "", isDirty: false, dirtyCount: 0, isWorktree: false)
        var loadCount = 0
        var results: [TitlebarGitSnapshot] = []

        cache.resolve(directory: "/tmp/not-a-repo", now: 10, load: {
            loadCount += 1
            return missing
        }, completion: { results.append($0) })
        cache.resolve(directory: "/tmp/not-a-repo", now: 19.9, load: {
            loadCount += 1
            return cleanMain
        }, completion: { results.append($0) })

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(results, [missing, missing])

        cache.resolve(directory: "/tmp/not-a-repo", now: 20.1, load: {
            loadCount += 1
            return cleanMain
        }, completion: { results.append($0) })

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(results.last, cleanMain)
    }

    func testConcurrentRequestsForSameDirectoryJoinInFlightLoad() {
        let cache = TitlebarGitSnapshotCache(ttl: 2, negativeTTL: 10)
        let firstLoadStarted = expectation(description: "first load started")
        let bothCompleted = expectation(description: "both requests completed")
        bothCompleted.expectedFulfillmentCount = 2
        let allowFirstLoadToFinish = DispatchSemaphore(value: 0)
        let lock = NSLock()
        let expected = cleanMain
        var loadCount = 0
        var results: [TitlebarGitSnapshot] = []

        DispatchQueue.global().async {
            cache.resolve(directory: "/tmp/repo", now: 10, load: {
                lock.lock()
                loadCount += 1
                lock.unlock()
                firstLoadStarted.fulfill()
                allowFirstLoadToFinish.wait()
                return expected
            }, completion: {
                lock.lock()
                results.append($0)
                lock.unlock()
                bothCompleted.fulfill()
            })
        }
        wait(for: [firstLoadStarted], timeout: 1)

        DispatchQueue.global().async {
            cache.resolve(directory: "/tmp/repo/", now: 10.1, load: {
                XCTFail("Joined request must not start a second load")
                return expected
            }, completion: {
                lock.lock()
                results.append($0)
                lock.unlock()
                bothCompleted.fulfill()
            })
        }
        allowFirstLoadToFinish.signal()
        wait(for: [bothCompleted], timeout: 1)

        lock.lock()
        let finalLoadCount = loadCount
        let finalResults = results
        lock.unlock()
        XCTAssertEqual(finalLoadCount, 1)
        XCTAssertEqual(finalResults, [expected, expected])
    }
}

final class NotificationBurstCoalescerTests: XCTestCase {
    func testSignalsInSameBurstFlushOnce() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "flush once")
        expectation.expectedFulfillmentCount = 1
        var flushCount = 0

        DispatchQueue.main.async {
            for _ in 0..<8 {
                coalescer.signal {
                    flushCount += 1
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(flushCount, 1)
    }

    func testLatestActionWinsWithinBurst() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "latest action flushed")
        var value = 0

        DispatchQueue.main.async {
            coalescer.signal {
                value = 1
            }
            coalescer.signal {
                value = 2
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(value, 2)
    }

    func testSignalsAcrossBurstsFlushMultipleTimes() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "flush twice")
        expectation.expectedFulfillmentCount = 2
        var flushCount = 0

        DispatchQueue.main.async {
            coalescer.signal {
                flushCount += 1
                expectation.fulfill()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                coalescer.signal {
                    flushCount += 1
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(flushCount, 2)
    }
}

final class GhosttyDefaultBackgroundNotificationDispatcherTests: XCTestCase {
    func testSignalCoalescesBurstToLatestBackground() {
        guard let dark = NSColor(hex: "#272822"),
              let light = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test colors")
            return
        }

        let expectation = expectation(description: "coalesced notification")
        expectation.expectedFulfillmentCount = 1
        var postedUserInfos: [[AnyHashable: Any]] = []

        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0.01,
            postNotification: { userInfo in
                postedUserInfos.append(userInfo)
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(backgroundColor: dark, opacity: 0.95, eventId: 1, source: "test.dark")
            dispatcher.signal(backgroundColor: light, opacity: 0.75, eventId: 2, source: "test.light")
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(postedUserInfos.count, 1)
        XCTAssertEqual(
            (postedUserInfos[0][GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString(),
            "#FDF6E3"
        )
        XCTAssertEqual(
            postedOpacity(from: postedUserInfos[0][GhosttyNotificationKey.backgroundOpacity]),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            (postedUserInfos[0][GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value,
            2
        )
        XCTAssertEqual(
            postedUserInfos[0][GhosttyNotificationKey.backgroundSource] as? String,
            "test.light"
        )
    }

    func testSignalAcrossSeparateBurstsPostsMultipleNotifications() {
        guard let dark = NSColor(hex: "#272822"),
              let light = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test colors")
            return
        }

        let expectation = expectation(description: "two notifications")
        expectation.expectedFulfillmentCount = 2
        var postedHexes: [String] = []

        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0.01,
            postNotification: { userInfo in
                let hex = (userInfo[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
                postedHexes.append(hex)
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(backgroundColor: dark, opacity: 1.0, eventId: 1, source: "test.dark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                dispatcher.signal(backgroundColor: light, opacity: 1.0, eventId: 2, source: "test.light")
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(postedHexes, ["#272822", "#FDF6E3"])
    }

    private func postedOpacity(from value: Any?) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        XCTFail("Expected background opacity payload")
        return -1
    }
}

final class RecentlyClosedBrowserStackTests: XCTestCase {
    func testPopReturnsEntriesInLIFOOrder() {
        var stack = RecentlyClosedBrowserStack(capacity: 20)
        stack.push(makeSnapshot(index: 1))
        stack.push(makeSnapshot(index: 2))
        stack.push(makeSnapshot(index: 3))

        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 2)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 1)
        XCTAssertNil(stack.pop())
    }

    func testPushDropsOldestEntriesWhenCapacityExceeded() {
        var stack = RecentlyClosedBrowserStack(capacity: 3)
        for index in 1...5 {
            stack.push(makeSnapshot(index: index))
        }

        XCTAssertEqual(stack.pop()?.originalTabIndex, 5)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 4)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertNil(stack.pop())
    }

    private func makeSnapshot(index: Int) -> ClosedBrowserPanelRestoreSnapshot {
        ClosedBrowserPanelRestoreSnapshot(
            workspaceId: UUID(),
            url: URL(string: "https://example.com/\(index)"),
            originalPaneId: UUID(),
            originalTabIndex: index,
            fallbackSplitOrientation: .horizontal,
            fallbackSplitInsertFirst: false,
            fallbackAnchorPaneId: UUID()
        )
    }
}

final class TabManagerNotificationOrderingSourceTests: XCTestCase {
    func testGhosttyDidSetTitleObserverDoesNotHopThroughTask() throws {
        let projectRoot = findProjectRoot()
        let tabManagerURL = projectRoot.appendingPathComponent("Sources/TabManager.swift")
        let source = try String(contentsOf: tabManagerURL, encoding: .utf8)

        guard let titleObserverStart = source.range(of: "forName: .ghosttyDidSetTitle"),
              let focusObserverStart = source.range(
                of: "forName: .ghosttyDidFocusSurface",
                range: titleObserverStart.upperBound..<source.endIndex
              ) else {
            XCTFail("Failed to locate TabManager notification observer block in Sources/TabManager.swift")
            return
        }

        let block = String(source[titleObserverStart.lowerBound..<focusObserverStart.lowerBound])
        XCTAssertFalse(
            block.contains("Task {"),
            """
            The .ghosttyDidSetTitle observer must update model state in the notification callback.
            Using Task can reorder updates and leave titlebar/toolbar one event behind.
            """
        )
        XCTAssertTrue(
            block.contains("MainActor.assumeIsolated"),
            "Expected .ghosttyDidSetTitle observer to run synchronously on MainActor."
        )
        XCTAssertTrue(
            block.contains("enqueuePanelTitleUpdate"),
            "Expected .ghosttyDidSetTitle observer to enqueue panel title updates."
        )
    }

    private func findProjectRoot() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

final class SocketControlSettingsTests: XCTestCase {
    func testMigrateModeSupportsExpandedSocketModes() {
        XCTAssertEqual(SocketControlSettings.migrateMode("off"), .off)
        XCTAssertEqual(SocketControlSettings.migrateMode("term-meshOnly"), .termMeshOnly)
        XCTAssertEqual(SocketControlSettings.migrateMode("automation"), .automation)
        XCTAssertEqual(SocketControlSettings.migrateMode("password"), .password)
        XCTAssertEqual(SocketControlSettings.migrateMode("allow-all"), .allowAll)

        // Legacy aliases
        XCTAssertEqual(SocketControlSettings.migrateMode("notifications"), .automation)
        XCTAssertEqual(SocketControlSettings.migrateMode("full"), .allowAll)
    }

    func testSocketModePermissions() {
        XCTAssertEqual(SocketControlMode.off.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.termMeshOnly.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.automation.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.password.socketFilePermissions, 0o600)
        // 0o600, not 0o666: group-write was removed so a same-group,
        // different-UID process cannot inject PTY commands through the socket.
        // The mode name is about who may CONNECT, not about file permissions.
        XCTAssertEqual(SocketControlMode.allowAll.socketFilePermissions, 0o600)
    }

    func testInvalidEnvSocketModeDoesNotOverrideUserMode() {
        XCTAssertNil(
            SocketControlSettings.envOverrideMode(
                environment: ["CMUX_SOCKET_MODE": "definitely-not-a-mode"]
            )
        )
        XCTAssertEqual(
            SocketControlSettings.effectiveMode(
                userMode: .password,
                environment: ["CMUX_SOCKET_MODE": "definitely-not-a-mode"]
            ),
            .password
        )
    }

    func testStableReleaseIgnoresAmbientSocketOverrideByDefault() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/term-mesh-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.termmesh.app",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/term-mesh.sock")
    }

    func testNightlyReleaseUsesDedicatedDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/term-mesh-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.termmesh.app.nightly",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/term-mesh-nightly.sock")
    }

    func testDebugBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/term-mesh-debug-my-tag.sock",
            ],
            bundleIdentifier: "com.termmesh.app.debug.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/term-mesh-debug-my-tag.sock")
    }

    func testStagingBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/term-mesh-staging-my-tag.sock",
            ],
            bundleIdentifier: "com.termmesh.app.staging.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/term-mesh-staging-my-tag.sock")
    }

    func testStableReleaseCanOptInToSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/term-mesh-debug-forced.sock",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.termmesh.app",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/term-mesh-debug-forced.sock")
    }

    func testDefaultSocketPathByChannel() {
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.termmesh.app", isDebugBuild: false),
            "/tmp/term-mesh.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.termmesh.app.nightly", isDebugBuild: false),
            "/tmp/term-mesh-nightly.sock"
        )
        // A tagged bundle gets its OWN socket. This asserted the untagged path
        // until tagged isolation was added to stop a tagged build from seizing
        // production's socket, and was never updated — it has been failing ever
        // since, unnoticed because a duplicate class name kept the other file's
        // (correct) expectations from running at all.
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.termmesh.app.debug.tag", isDebugBuild: false),
            "/tmp/term-mesh-debug-tag.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.termmesh.app.staging.tag", isDebugBuild: false),
            "/tmp/term-mesh-staging-tag.sock"
        )
    }

    /// The identifiers reload.sh actually builds.
    ///
    /// `--tag remote-work-log` becomes `com.termmesh.app.debug.remote.work.log`:
    /// a bundle identifier is dot-delimited, so `sanitize_bundle` turns every
    /// non-alphanumeric run into ".". The socket name reload.sh advertises in
    /// TERMMESH_SOCKET_PATH comes from `sanitize_path`, which uses "-" instead.
    /// These have to agree — a tagged bundle ignores that env override on
    /// purpose, so when they diverged the advertised socket simply did not
    /// exist and every CLI attaching by env failed. Only single-word tags
    /// happened to match, which is why it went unnoticed.
    func testTaggedSocketPathMatchesTheNameReloadAdvertises() {
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.termmesh.app.debug.remote.work.log", isDebugBuild: false),
            "/tmp/term-mesh-debug-remote-work-log.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.termmesh.app.staging.fix.blur.effect", isDebugBuild: false),
            "/tmp/term-mesh-staging-fix-blur-effect.sock"
        )
        // `--tag my_tag`: sanitize_bundle gives `my.tag`, sanitize_path gives
        // `my-tag`. Underscores never survive into an identifier, so both
        // sides still have to land on the same name.
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.termmesh.app.debug.my.tag", isDebugBuild: false),
            "/tmp/term-mesh-debug-my-tag.sock"
        )
        // A hand-written identifier keeps its hyphens as written.
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.termmesh.app.debug.fix-blur-effect", isDebugBuild: false),
            "/tmp/term-mesh-debug-fix-blur-effect.sock"
        )
        // An untagged debug bundle must still land on the untagged socket.
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.termmesh.app.debug", isDebugBuild: false),
            "/tmp/term-mesh-debug.sock"
        )
    }
}

final class PostHogAnalyticsPropertiesTests: XCTestCase {
    func testDailyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        XCTAssertEqual(properties["day_utc"] as? String, "2026-02-21")
        XCTAssertEqual(properties["reason"] as? String, "didBecomeActive")
        XCTAssertEqual(properties["app_version"] as? String, "0.31.0")
        XCTAssertEqual(properties["app_build"] as? String, "230")
    }

    func testSuperPropertiesIncludePlatformVersionAndBuild() {
        let properties = PostHogAnalytics.superProperties(
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        // "termmesh" is what PostHogAnalytics actually sends and has been
        // sending; "term-meshterm" is a rename pass that rewrote the test
        // and not the source. The dashboard dimension is the authority.
        XCTAssertEqual(properties["platform"] as? String, "termmesh")
        XCTAssertEqual(properties["app_version"] as? String, "0.31.0")
        XCTAssertEqual(properties["app_build"] as? String, "230")
    }

    func testPropertiesOmitVersionFieldsWhenUnavailable() {
        let superProperties = PostHogAnalytics.superProperties(infoDictionary: [:])
        XCTAssertEqual(superProperties["platform"] as? String, "termmesh")
        XCTAssertNil(superProperties["app_version"])
        XCTAssertNil(superProperties["app_build"])

        let dailyProperties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "activeTimer",
            infoDictionary: [:]
        )
        XCTAssertEqual(dailyProperties["day_utc"] as? String, "2026-02-21")
        XCTAssertEqual(dailyProperties["reason"] as? String, "activeTimer")
        XCTAssertNil(dailyProperties["app_version"])
        XCTAssertNil(dailyProperties["app_build"])
    }
}
