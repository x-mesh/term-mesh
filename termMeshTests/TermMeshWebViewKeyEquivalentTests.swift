import XCTest
import AppKit
import SwiftUI
import WebKit
import SwiftUI
import Bonsplit
import ObjectiveC.runtime

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

private var termMeshUnitTestInspectorAssociationKey: UInt8 = 0
private var termMeshUnitTestInspectorOverrideInstalled = false

private extension TermMeshWebView {
    @objc func termMeshUnitTestInspector() -> NSObject? {
        objc_getAssociatedObject(self, &termMeshUnitTestInspectorAssociationKey) as? NSObject
    }
}

private extension WKWebView {
    func termMeshSetUnitTestInspector(_ inspector: NSObject?) {
        objc_setAssociatedObject(
            self,
            &termMeshUnitTestInspectorAssociationKey,
            inspector,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

private func installTermMeshUnitTestInspectorOverride() {
    guard !termMeshUnitTestInspectorOverrideInstalled else { return }

    guard let replacementMethod = class_getInstanceMethod(
        TermMeshWebView.self,
        #selector(TermMeshWebView.termMeshUnitTestInspector)
    ) else {
        fatalError("Unable to locate test inspector replacement method")
    }

    let added = class_addMethod(
        TermMeshWebView.self,
        NSSelectorFromString("_inspector"),
        method_getImplementation(replacementMethod),
        method_getTypeEncoding(replacementMethod)
    )
    guard added else {
        fatalError("Unable to install TermMeshWebView _inspector test override")
    }

    termMeshUnitTestInspectorOverrideInstalled = true
}

final class AppLaunchEnvironmentTests: XCTestCase {
    func testDetectsEverySupportedXCTestSignal() {
        let signals: [[String: String]] = [
            ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"],
            ["XCTestBundlePath": "/tmp/termMeshTests.xctest"],
            ["XCTestSessionIdentifier": "session"],
            ["XCInjectBundle": "/tmp/termMeshTests.xctest"],
            ["XCInjectBundleInto": "/tmp/term-mesh DEV.app"],
            ["DYLD_INSERT_LIBRARIES": "/tmp/libXCTestBundleInject.dylib"],
            ["TERMMESH_UI_TEST_ENABLED": "1"],
            ["CMUX_UI_TEST_ENABLED": "1"],
        ]

        for environment in signals {
            XCTAssertTrue(
                AppLaunchEnvironment.isRunningUnderXCTest(environment),
                "expected XCTest detection for \(environment.keys.sorted())"
            )
        }
    }

    func testNormalApplicationEnvironmentDoesNotDisableSessionRestore() {
        XCTAssertFalse(
            AppLaunchEnvironment.isRunningUnderXCTest([
                "HOME": "/Users/example",
                "TERM_PROGRAM": "ghostty",
                "DYLD_INSERT_LIBRARIES": "/tmp/libSomethingElse.dylib",
            ])
        )
    }
}

@MainActor
final class NativeWindowRestorationPolicyTests: XCTestCase {
    func testDisablePersistsBothNativeRestorationGuards() throws {
        let suiteName = "NativeWindowRestorationPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: NativeWindowRestorationPolicy.ignoreStateKey)
        defaults.set(true, forKey: NativeWindowRestorationPolicy.keepWindowsKey)

        NativeWindowRestorationPolicy.disable(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: NativeWindowRestorationPolicy.ignoreStateKey))
        XCTAssertFalse(defaults.bool(forKey: NativeWindowRestorationPolicy.keepWindowsKey))
    }

    func testAppDelegateRejectsSavingAndRestoringNativeWindowState() {
        let app = NSApplication.shared
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.applicationShouldSaveApplicationState(app))
        XCTAssertFalse(delegate.applicationShouldRestoreApplicationState(app))
        XCTAssertFalse(delegate.applicationShouldSaveSecureApplicationState(app))
        XCTAssertFalse(delegate.applicationShouldRestoreSecureApplicationState(app))
    }
}

final class LanguageSettingsTests: XCTestCase {
    func testInvalidStoredLanguageFallsBackToSystemAndRepairsDefaults() {
        let suiteName = "LanguageSettingsTests.Invalid.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unsupported", forKey: LanguageSettings.languageModeKey)

        XCTAssertEqual(LanguageSettings.resolvedMode(defaults: defaults), .system)
        XCTAssertEqual(
            defaults.string(forKey: LanguageSettings.languageModeKey),
            AppLanguage.system.rawValue
        )
    }

    func testExplicitLanguagesOverrideSystemPreference() {
        XCTAssertTrue(
            LanguageSettings.locale(
                for: AppLanguage.english.rawValue,
                preferredLanguages: ["ko-KR"]
            ).identifier.hasPrefix("en")
        )
        XCTAssertTrue(
            LanguageSettings.locale(
                for: AppLanguage.korean.rawValue,
                preferredLanguages: ["en-US"]
            ).identifier.hasPrefix("ko")
        )
    }

    func testSystemLanguageUsesMacOSPreferredLanguage() {
        let locale = LanguageSettings.locale(
            for: AppLanguage.system.rawValue,
            preferredLanguages: ["ja-JP", "ko-KR", "en-US"]
        )

        XCTAssertTrue(locale.identifier.hasPrefix("ko"))
    }

    func testSystemLanguageFallsBackToEnglishWhenNoPreferredLanguageIsSupported() {
        let locale = LanguageSettings.locale(
            for: AppLanguage.system.rawValue,
            preferredLanguages: ["ja-JP", "fr-FR"]
        )

        XCTAssertTrue(locale.identifier.hasPrefix("en"))
    }

    func testKoreanCatalogIsAvailableFromAppBundle() {
        XCTAssertEqual(
            String(
                localized: "Language",
                bundle: .main,
                locale: Locale(identifier: "ko")
            ),
            "언어"
        )
    }

    // MARK: - The chosen language must not drag the region with it

    func testSupportedLanguageCodesAreDerivedFromTheCases() {
        XCTAssertEqual(AppLanguage.supportedLanguageCodes, ["en", "ko"])
        XCTAssertNil(AppLanguage.system.languageCode)
    }

    /// Language and region are configured separately in System Settings, so
    /// 한국어 + United States is a real setup. Rebuilding the locale from the
    /// language identifier alone would silently move the user to Korea.
    func testSystemModeChoosesTheLanguageButKeepsTheRegion() {
        let locale = LanguageSettings.locale(
            for: AppLanguage.system.rawValue,
            preferredLanguages: ["ko-KR", "en-US"],
            systemLocale: Locale(identifier: "ko_US")
        )

        XCTAssertEqual(locale.language.languageCode?.identifier, "ko")
        XCTAssertEqual(locale.region?.identifier, "US")
    }

    func testExplicitLanguageKeepsTheSystemRegion() {
        let locale = LanguageSettings.locale(
            for: AppLanguage.english.rawValue,
            preferredLanguages: ["ko-KR"],
            systemLocale: Locale(identifier: "ko_KR")
        )

        XCTAssertEqual(locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(locale.region?.identifier, "KR")
    }

    func testUnsupportedSystemLanguageFallsBackToEnglishAndKeepsTheRegion() {
        let locale = LanguageSettings.locale(
            for: AppLanguage.system.rawValue,
            preferredLanguages: ["ja-JP", "fr-FR"],
            systemLocale: Locale(identifier: "ja_JP")
        )

        XCTAssertEqual(locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(locale.region?.identifier, "JP")
    }

    func testOverridingTheLanguagePreservesTheHourCycle() {
        var components = Locale.Components(identifier: "ko_KR")
        components.hourCycle = .oneToTwelve

        let locale = LanguageSettings.locale(
            for: AppLanguage.english.rawValue,
            preferredLanguages: ["ko-KR"],
            systemLocale: Locale(components: components)
        )

        XCTAssertEqual(locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(locale.hourCycle, .oneToTwelve)
    }

    /// Hangul is not a script for English: carrying `Kore` over would produce
    /// `en-Kore-KR` and hand the bundle a localization to negotiate that does
    /// not exist. Clearing it lets ICU infer the right script for the incoming
    /// language instead — reading `script` back yields `Latn`, not nil.
    func testGraftingALanguageDropsTheOutgoingScript() {
        let locale = Locale(identifier: "ko_Kore_KR").withLanguageCode("en")

        XCTAssertEqual(locale.language.languageCode?.identifier, "en")
        XCTAssertNotEqual(locale.language.script?.identifier, "Kore")
        XCTAssertFalse(locale.identifier.contains("Kore"))
        XCTAssertEqual(locale.region?.identifier, "KR")
    }

    func testGraftingTheSameLanguageIsIdentity() {
        let original = Locale(identifier: "ko_KR")
        XCTAssertEqual(original.withLanguageCode("ko"), original)
    }

    // MARK: - AppKit lookup

    private func isolatedDefaults(
        _ label: String,
        language: AppLanguage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UserDefaults? {
        let suiteName = "LanguageSettingsTests.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite", file: file, line: line)
            return nil
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(language.rawValue, forKey: LanguageSettings.languageModeKey)
        return defaults
    }

    func testAppKitLookupFollowsTheKoreanOverride() {
        guard let defaults = isolatedDefaults("Korean", language: .korean) else { return }

        XCTAssertEqual(LanguageSettings.localized("Show Notifications", defaults: defaults), "알림 보기")
        XCTAssertEqual(LanguageSettings.localized("Clear All", defaults: defaults), "모두 지우기")
    }

    /// The app ships no `en.lproj` (English is the source language), so an
    /// English override must fall through to the key itself. Resolving against
    /// `Bundle.main` instead would return the *system*-negotiated language and
    /// hand Korean text to someone who explicitly chose English.
    func testEnglishOverrideNeverFallsBackToTheSystemLanguage() {
        guard let defaults = isolatedDefaults("English", language: .english) else { return }

        XCTAssertNil(LanguageSettings.bundle(for: Locale(identifier: "en")))
        XCTAssertEqual(LanguageSettings.localized("Show Notifications", defaults: defaults), "Show Notifications")
        XCTAssertEqual(LanguageSettings.localized("Clear All", defaults: defaults), "Clear All")
    }

    func testUnknownKeyResolvesToItself() {
        guard let defaults = isolatedDefaults("Unknown", language: .korean) else { return }

        XCTAssertEqual(
            LanguageSettings.localized("A string that is not in the catalog", defaults: defaults),
            "A string that is not in the catalog"
        )
    }

    func testMenuBarStateHintFollowsTheOverride() {
        guard let defaults = isolatedDefaults("StateHint", language: .korean) else { return }
        defaults.set(AppLanguage.korean.rawValue, forKey: LanguageSettings.languageModeKey)
        UserDefaults.standard.set(AppLanguage.korean.rawValue, forKey: LanguageSettings.languageModeKey)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: LanguageSettings.languageModeKey)
        }

        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 0), "읽지 않은 알림 없음")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 1), "읽지 않은 알림 1개")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 7), "읽지 않은 알림 7개")
    }

    // MARK: - Language picker

    /// A user who lands in a language they cannot read has to be able to find
    /// their own, so language names are never translated.
    func testLanguagesAreListedUnderTheirOwnNames() {
        XCTAssertEqual(AppLanguage.english.endonym, "English")
        XCTAssertEqual(AppLanguage.korean.endonym, "한국어")
        // `.system` follows macOS, so it is labelled in the current UI language.
        XCTAssertNil(AppLanguage.system.endonym)
    }

    // MARK: - Searching in the display language

    /// Rows are tagged with English keywords. In Korean the user types 테마,
    /// which appears in none of them, so the query is mapped back through the
    /// catalog to the English terms.
    func testKoreanQueryMapsBackToEnglishKeywords() {
        let ko = Locale(identifier: "ko")

        let theme = SettingsSearchIndex.englishTerms(matching: "테마", locale: ko)
        XCTAssertTrue(theme.contains("theme"), "expected 'theme' among \(theme)")

        let notifications = SettingsSearchIndex.englishTerms(matching: "알림", locale: ko)
        XCTAssertTrue(notifications.contains("notifications"), "expected 'notifications' among \(notifications)")
    }

    func testQueryWithNoTranslationYieldsNoTerms() {
        XCTAssertTrue(
            SettingsSearchIndex.englishTerms(
                matching: "존재하지않는설정이름",
                locale: Locale(identifier: "ko")
            ).isEmpty
        )
    }

    /// English ships no `.lproj`, so there is nothing to reverse — English
    /// queries already match the keyword lists directly.
    func testSourceLanguageHasNoReverseTable() {
        XCTAssertTrue(SettingsSearchIndex.table(for: Locale(identifier: "en")).isEmpty)
    }

    func testMobileRemoteControlIsDiscoverableAsItsOwnNetworkSection() {
        XCTAssertTrue(SettingsSection.allCases.contains(.mobileRemoteControl))
        XCTAssertEqual(SettingsSection.mobileRemoteControl.category, .network)
        XCTAssertEqual(SettingsSection.mobileRemoteControl.title, "Mobile Remote Control")
        XCTAssertTrue(SettingsSection.mobileRemoteControl.searchKeywords.contains("tailscale"))
        XCTAssertTrue(SettingsSection.mobileRemoteControl.searchKeywords.contains("9877"))
    }

    // MARK: - Catalog keys must match the keys SwiftUI actually builds

    /// `Text("… \(value)")` does not key on the source text — SwiftUI rewrites
    /// each interpolation into a format specifier. A catalog entry written by
    /// hand with the wrong specifier compiles, ships, and silently never
    /// matches, which is how `%arg` left the settings-search message English.
    private func swiftUIKey(_ key: LocalizedStringKey) -> String? {
        Mirror(reflecting: key).children
            .first { $0.label == "key" }?
            .value as? String
    }

    func testInterpolatedSettingsSearchKeyMatchesTheCatalog() {
        let key = swiftUIKey("No settings match \"\(  "peer"  )\"")
        XCTAssertEqual(key, "No settings match \"%@\"")

        guard let key else { return }
        let localized = String(
            localized: String.LocalizationValue(key),
            bundle: .main,
            locale: Locale(identifier: "ko")
        )
        XCTAssertNotEqual(localized, key, "catalog has no ko entry for the key SwiftUI builds")
        XCTAssertTrue(localized.contains("%@"), "translated value dropped the format specifier")
    }

    /// Every format specifier must survive translation; a Korean value that
    /// loses one crashes `String(format:)` or prints a stray literal.
    func testFormattedMenuStringsKeepTheirSpecifiers() {
        guard let defaults = isolatedDefaults("Format", language: .korean) else { return }

        let brew = LanguageSettings.localized("Restart and Update term-mesh (%@ → %@)", defaults: defaults)
        XCTAssertEqual(brew.components(separatedBy: "%@").count - 1, 2)
        XCTAssertEqual(String(format: brew, "1.0.0", "1.1.0"), "term-mesh 재시작 후 업데이트(1.0.0 → 1.1.0)")

        let focus = LanguageSettings.localized("Focus a %@ agent pane to enable", defaults: defaults)
        XCTAssertEqual(focus.components(separatedBy: "%@").count - 1, 1)

        for key in ["%lld unread notification", "%lld unread notifications"] {
            let value = LanguageSettings.localized(key, defaults: defaults)
            XCTAssertTrue(value.contains("%lld"), "\(key) lost its %lld specifier")
        }
    }

    func testSettingsKoreanCopyUsesNativeUILabelsAndUserFacingTerms() {
        let ko = Locale(identifier: "ko")
        let expected: [String: String] = [
            "Save Copied Text to Paste Shelf": "클립보드 기록",
            "Reorder on Notification": "알림 오면 맨 위로",
            "Warn Before Quit": "종료할 때 확인",
            "Rename Selects Existing Name": "이름 바꿀 때 전체 선택",
            "Peer Federation": "다른 컴퓨터 연결",
            "Mobile Remote Control": "모바일 원격 제어",
            "Loopback (development)": "이 Mac만(개발용)",
            "Authentication": "인증 방식",
            "Allowed Logins": "허용 계정",
            "Model Override": "모델 지정",
            "Delete Worktree?": "워크트리를 삭제할까요?",
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                String(localized: String.LocalizationValue(key), bundle: .main, locale: ko),
                value,
                key
            )
        }
    }

    func testSettingsKoreanDescriptionsAvoidInternalTermsAndImperativeEndings() {
        let ko = Locale(identifier: "ko")
        let descriptionKeys = [
            "Controls access to the local Unix socket for programmatic control. Choose a mode that matches your threat model.",
            "Separates local workspaces from Peer Hosts and presents peer workspaces as mirror actions.",
            "Peer federation lets another term-mesh.app instance attach this Mac's terminal panes via SSH (workspace mirror with live layout sync). \"Enable peer server\" controls the running state right now; \"Auto-start at app launch\" persists across restarts.",
            "Project discovery is not exposed by the current daemon. Register a project before starting a manifest scan.",
            "Runbooks are loaded from .agent-runbooks/<role>.md. Claude, Codex, and OpenCode files are generated projections.",
        ]
        let banned = ["하세요", "활성화", "비활성화", "피어", "미러", "데몬", "pane", "프로젝션"]

        for key in descriptionKeys {
            let value = String(localized: String.LocalizationValue(key), bundle: .main, locale: ko)
            // Without this the test cannot fail for the regression it exists to catch:
            // a missing ko entry returns the English source, which carries none of the
            // Korean banned tokens and already ends with a period.
            XCTAssertNotEqual(value, key, "catalog has no ko entry for \(key)")
            for token in banned {
                XCTAssertFalse(value.contains(token), "\(key): \(value) contains \(token)")
            }
            XCTAssertTrue(value.hasSuffix("."), "description must end with a period: \(value)")
        }
    }

    /// An English imperative must stay an imperative in Korean.
    ///
    /// `regeneratePeerIdentity()` writes the new hex and a status string and nothing
    /// else — it never restarts a session. A declarative Korean rendering ("연결을 다시
    /// 시작합니다") reads as the app doing the work, so the user skips the manual step
    /// and leaves every active session bound to an invalidated ID.
    func testActionRequiredCopyStaysImperativeInKorean() {
        let ko = Locale(identifier: "ko")
        let keys = [
            "Existing peer pairings may stop working. Durable Project ownership is retained on this Mac. Restart active peer sessions after regenerating this ID.",
            "Regenerated. Restart active peer sessions.",
        ]

        for key in keys {
            let value = String(localized: String.LocalizationValue(key), bundle: .main, locale: ko)
            XCTAssertNotEqual(value, key, "catalog has no ko entry for \(key)")
            XCTAssertTrue(
                value.contains("다시 시작하세요"),
                "\(key) must ask the user to act, not report that the app did: \(value)"
            )
        }
    }
}

final class SidebarTeamRuntimeSnapshotTests: XCTestCase {
    private let baseline = SidebarTeamRuntimeSnapshot(
        teamName: "term-mesh",
        attentionCount: 0,
        agentStates: [
            .init(agentInstanceId: "leader-1", state: "idle"),
            .init(agentInstanceId: "reviewer-1", state: "running")
        ]
    )

    func testIdenticalSnapshotRemainsEqual() {
        XCTAssertEqual(
            baseline,
            SidebarTeamRuntimeSnapshot(
                teamName: "term-mesh",
                attentionCount: 0,
                agentStates: [
                    .init(agentInstanceId: "leader-1", state: "idle"),
                    .init(agentInstanceId: "reviewer-1", state: "running")
                ]
            )
        )
    }

    func testEveryRenderedTeamDimensionInvalidatesEquality() {
        let changes = [
            SidebarTeamRuntimeSnapshot(
                teamName: "renamed-team",
                attentionCount: baseline.attentionCount,
                agentStates: baseline.agentStates
            ),
            SidebarTeamRuntimeSnapshot(
                teamName: baseline.teamName,
                attentionCount: 1,
                agentStates: baseline.agentStates
            ),
            SidebarTeamRuntimeSnapshot(
                teamName: baseline.teamName,
                attentionCount: baseline.attentionCount,
                agentStates: [
                    .init(agentInstanceId: "leader-1", state: "blocked"),
                    .init(agentInstanceId: "reviewer-1", state: "running")
                ]
            ),
            SidebarTeamRuntimeSnapshot(
                teamName: baseline.teamName,
                attentionCount: baseline.attentionCount,
                agentStates: baseline.agentStates + [
                    .init(agentInstanceId: "executor-1", state: "idle")
                ]
            )
        ]

        for changed in changes {
            XCTAssertNotEqual(baseline, changed)
        }
    }

    func testStateLookupUsesInstanceIdentityAndDefaultsToIdle() {
        XCTAssertEqual(baseline.state(for: "reviewer-1"), "running")
        XCTAssertEqual(baseline.state(for: "missing-instance"), "idle")
    }
}

final class SplitShortcutTransientFocusGuardTests: XCTestCase {
    func testSuppressesWhenFirstResponderFallsBackAndHostedViewIsTiny() {
        XCTAssertTrue(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 79, height: 0),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }

    func testSuppressesWhenFirstResponderFallsBackAndHostedViewIsDetached() {
        XCTAssertTrue(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 1051.5, height: 1207),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: false
            )
        )
    }

    func testAllowsWhenFirstResponderFallsBackButGeometryIsHealthy() {
        XCTAssertFalse(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 1051.5, height: 1207),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }

    func testAllowsWhenFirstResponderIsTerminalEvenIfViewIsTiny() {
        XCTAssertFalse(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: false,
                hostedSize: CGSize(width: 79, height: 0),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }
}

final class PeerRelayWorkspaceShortcutActionTests: XCTestCase {
    func testCommandWClosesOnlyTheRemotePane() {
        XCTAssertEqual(
            peerRelayWorkspaceShortcutAction(
                characters: "w",
                keyCode: 13,
                modifiers: [.command]
            ),
            .closePane
        )
    }

    func testCommandShiftWClosesTheRelayWindow() {
        XCTAssertEqual(
            peerRelayWorkspaceShortcutAction(
                characters: "W",
                keyCode: 13,
                modifiers: [.command, .shift]
            ),
            .closeWindow
        )
    }

    func testCloseShortcutRequiresCommand() {
        XCTAssertNil(
            peerRelayWorkspaceShortcutAction(
                characters: "w",
                keyCode: 13,
                modifiers: [.shift]
            )
        )
    }
}

final class TermMeshWebViewKeyEquivalentTests: XCTestCase {
    func testIMEMessageRoutingRequiresCorrelatedReplies() {
        let one = GhosttySurfaceScrollView.imeCorrelatedRoutingHint(
            mention: "reviewer", targetCount: 1, isPing: false
        )
        let many = GhosttySurfaceScrollView.imeCorrelatedRoutingHint(
            mention: "all", targetCount: 2, isPing: false
        )
        let ping = GhosttySurfaceScrollView.imeCorrelatedRoutingHint(
            mention: "reviewer", targetCount: 1, isPing: true
        )

        for hint in [one, many, ping] {
            XCTAssertTrue(hint.contains("--expect-reply"))
            XCTAssertTrue(hint.contains("--reply-timeout 300"))
            XCTAssertTrue(hint.contains("--agent-instance-id"))
            XCTAssertTrue(hint.contains("Do not use plain `send`"))
            XCTAssertFalse(hint.contains("then check `tm-agent msg list`"))
        }
        XCTAssertTrue(one.contains("@reviewer"))
        XCTAssertTrue(many.contains("each target"))
        XCTAssertTrue(many.contains("concurrently"))
        XCTAssertTrue(many.contains("explicit timeouts"))
        XCTAssertTrue(ping.contains("Send the ping"))
    }
    private final class ActionSpy: NSObject {
        private(set) var invoked: Bool = false

        @objc func didInvoke(_ sender: Any?) {
            invoked = true
        }
    }

    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testCmdNRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "n", modifiers: [.command])

        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "n", modifiers: [.command], keyCode: 45) // kVK_ANSI_N
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdWRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "w", modifiers: [.command])

        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "w", modifiers: [.command], keyCode: 13) // kVK_ANSI_W
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdRRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "r", modifiers: [.command])

        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "r", modifiers: [.command], keyCode: 15) // kVK_ANSI_R
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    @MainActor
    func testCanBlockFirstResponderAcquisitionWhenPaneIsUnfocused() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = TermMeshWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(webView))

        _ = window.makeFirstResponder(nil)
        webView.allowsFirstResponderAcquisition = false
        XCTAssertFalse(webView.becomeFirstResponder())

        _ = window.makeFirstResponder(webView)
        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(firstResponderView === webView || firstResponderView.isDescendant(of: webView))
        }
    }

    @MainActor
    func testPointerFocusAllowanceCanTemporarilyOverrideBlockedFirstResponderAcquisition() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = TermMeshWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(webView.becomeFirstResponder(), "Expected focus to stay blocked by policy")

        webView.withPointerFocusAllowance {
            XCTAssertTrue(webView.becomeFirstResponder(), "Expected explicit pointer intent to bypass policy")
        }

        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(webView.becomeFirstResponder(), "Expected pointer allowance to be temporary")
    }

    @MainActor
    func testWindowFirstResponderGuardBlocksDescendantWhenPaneIsUnfocused() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = TermMeshWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(descendant))

        _ = window.makeFirstResponder(nil)
        webView.allowsFirstResponderAcquisition = false
        XCTAssertFalse(window.makeFirstResponder(descendant))

        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(firstResponderView === descendant || firstResponderView.isDescendant(of: webView))
        }
    }

    @MainActor
    func testWindowFirstResponderGuardAllowsDescendantDuringPointerFocusAllowance() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = TermMeshWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected blocked focus outside pointer allowance")

        _ = window.makeFirstResponder(nil)
        webView.withPointerFocusAllowance {
            XCTAssertTrue(window.makeFirstResponder(descendant), "Expected pointer allowance to bypass guard")
        }

        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected pointer allowance to remain temporary")
    }

    @MainActor
    func testWindowFirstResponderGuardAllowsPointerInitiatedClickFocusWhenPolicyIsBlocked() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = TermMeshWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer {
            AppDelegate.clearWindowFirstResponderGuardTesting()
            window.orderOut(nil)
        }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected blocked focus without pointer click context")

        let timestamp = ProcessInfo.processInfo.systemUptime
        let pointerDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        XCTAssertNotNil(pointerDownEvent)

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: descendant)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.makeFirstResponder(descendant), "Expected pointer click context to bypass blocked policy")

        AppDelegate.clearWindowFirstResponderGuardTesting()
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected pointer bypass to be limited to click context")
    }

    private func installMenu(spy: ActionSpy, key: String, modifiers: NSEvent.ModifierFlags) {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        let item = NSMenuItem(title: "Test Item", action: #selector(ActionSpy.didInvoke(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = spy
        fileMenu.addItem(item)

        mainMenu.addItem(fileItem)
        mainMenu.setSubmenu(fileMenu, for: fileItem)

        // Ensure NSApp exists and has a menu for performKeyEquivalent to consult.
        _ = NSApplication.shared
        NSApp.mainMenu = mainMenu
    }

    private func makeKeyDownEvent(key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

@MainActor
final class AppDelegateWindowContextRoutingTests: XCTestCase {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("term-mesh.main.\(id.uuidString)")
        return window
    }

    func testRegisterMainWindowDisablesNativeRestorationForSwiftUIWindow() {
        let app = AppDelegate()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        window.isRestorable = true
        defer { window.orderOut(nil) }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: TabManager(),
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        XCTAssertFalse(window.isRestorable)
    }

    func testLocateBonsplitTabResolvesPanelAndRejectsWrongSourcePane() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        let workspace = try XCTUnwrap(manager.tabs.first)
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let tabId = try XCTUnwrap(workspace.bonsplitController.tabs(inPane: paneId).first?.id)
        let panelId = try XCTUnwrap(workspace.panelIdFromSurfaceId(tabId))

        let located = try XCTUnwrap(
            app.locateBonsplitTab(tabId: tabId, sourcePaneId: paneId)
        )
        XCTAssertEqual(located.windowId, windowId)
        XCTAssertTrue(located.workspace === workspace)
        XCTAssertEqual(located.panelId, panelId)
        let provider = try XCTUnwrap(
            workspace.bonsplitController.externalTabDragItemProvider(for: tabId)
        )
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier("com.splittabbar.tabtransfer"),
            "A sidebar relay-pane drag must use Bonsplit's external-tab payload"
        )
        XCTAssertNil(
            workspace.bonsplitController.externalTabDragItemProvider(
                for: TabID(uuid: UUID())
            ),
            "An unknown tab must not produce a same-process drag payload"
        )
        XCTAssertNil(
            app.locateBonsplitTab(tabId: tabId, sourcePaneId: PaneID(id: UUID())),
            "A stale drag payload must not resolve after its source pane changed"
        )
    }

    func testExternalLocalPaneDropMovesExistingPanelBetweenWorkspaces() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        let source = try XCTUnwrap(manager.tabs.first)
        let destination = manager.addWorkspace(select: false)
        let sourcePane = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let sourceTab = try XCTUnwrap(source.bonsplitController.tabs(inPane: sourcePane).first)
        let panelId = try XCTUnwrap(source.panelIdFromSurfaceId(sourceTab.id))
        let panel = try XCTUnwrap(source.panels[panelId])
        let targetPane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)

        let handled = destination.bonsplitController.onExternalTabDrop?(
            .init(
                tabId: sourceTab.id,
                sourcePaneId: sourcePane,
                destination: .insert(targetPane: targetPane, targetIndex: 0)
            )
        )

        XCTAssertEqual(handled, true)
        XCTAssertNil(source.panels[panelId])
        XCTAssertTrue(destination.panels[panelId] === panel)
        XCTAssertEqual(
            destination.bonsplitController.tabs(inPane: targetPane).first.flatMap {
                destination.panelIdFromSurfaceId($0.id)
            },
            panelId
        )
        XCTAssertEqual((panel as? TerminalPanel)?.workspaceId, destination.id)
    }

    func testExternalLocalPaneDropCreatesRequestedSplit() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        let source = try XCTUnwrap(manager.tabs.first)
        let destination = manager.addWorkspace(select: false)
        let sourcePane = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let sourceTab = try XCTUnwrap(source.bonsplitController.tabs(inPane: sourcePane).first)
        let panelId = try XCTUnwrap(source.panelIdFromSurfaceId(sourceTab.id))
        let targetPane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let originalPaneCount = destination.bonsplitController.allPaneIds.count

        let handled = destination.bonsplitController.onExternalTabDrop?(
            .init(
                tabId: sourceTab.id,
                sourcePaneId: sourcePane,
                destination: .split(
                    targetPane: targetPane,
                    orientation: .horizontal,
                    insertFirst: false
                )
            )
        )

        XCTAssertEqual(handled, true)
        XCTAssertNil(source.panels[panelId])
        XCTAssertNotNil(destination.panels[panelId])
        XCTAssertEqual(
            destination.bonsplitController.allPaneIds.count,
            originalPaneCount + 1
        )
        let movedPane = try XCTUnwrap(destination.paneId(forPanelId: panelId))
        XCTAssertNotEqual(movedPane, targetPane)
    }

    func testExternalDropPayloadRecoversSameWorkspacePaneMove() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        let workspace = try XCTUnwrap(manager.tabs.first)
        let sourcePane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourceTab = try XCTUnwrap(workspace.bonsplitController.tabs(inPane: sourcePane).first)
        let panelId = try XCTUnwrap(workspace.panelIdFromSurfaceId(sourceTab.id))
        let targetPanel = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: panelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let targetPane = try XCTUnwrap(workspace.paneId(forPanelId: targetPanel.id))

        let handled = workspace.bonsplitController.onExternalTabDrop?(
            .init(
                tabId: sourceTab.id,
                sourcePaneId: sourcePane,
                destination: .insert(targetPane: targetPane, targetIndex: nil)
            )
        )

        XCTAssertEqual(handled, true)
        XCTAssertEqual(workspace.paneId(forPanelId: panelId), targetPane)
        XCTAssertNotNil(workspace.panels[panelId])
    }

    func testExternalDropPayloadKeepsSamePaneCenterDropAsNoop() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        let workspace = try XCTUnwrap(manager.tabs.first)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourceTab = try XCTUnwrap(workspace.bonsplitController.tabs(inPane: pane).first)
        let tabsBeforeDrop = workspace.bonsplitController.tabs(inPane: pane).map(\.id)

        let handled = workspace.bonsplitController.onExternalTabDrop?(
            .init(
                tabId: sourceTab.id,
                sourcePaneId: pane,
                destination: .insert(targetPane: pane, targetIndex: nil)
            )
        )

        XCTAssertEqual(handled, true)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: pane).map(\.id), tabsBeforeDrop)
    }

    func testExternalDropPayloadRecoversSameWorkspacePaneSplit() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        let workspace = try XCTUnwrap(manager.tabs.first)
        let sourcePane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourceTab = try XCTUnwrap(workspace.bonsplitController.tabs(inPane: sourcePane).first)
        let panelId = try XCTUnwrap(workspace.panelIdFromSurfaceId(sourceTab.id))
        let targetPanel = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: panelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let targetPane = try XCTUnwrap(workspace.paneId(forPanelId: targetPanel.id))
        let paneCount = workspace.bonsplitController.allPaneIds.count

        let handled = workspace.bonsplitController.onExternalTabDrop?(
            .init(
                tabId: sourceTab.id,
                sourcePaneId: sourcePane,
                destination: .split(
                    targetPane: targetPane,
                    orientation: .vertical,
                    insertFirst: true
                )
            )
        )

        XCTAssertEqual(handled, true)
        // The source pane had only the moved tab, so Bonsplit collapses it
        // while creating the requested destination split. Net pane count is
        // unchanged even though the panel has moved into a new pane.
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, paneCount)
        XCTAssertFalse(workspace.bonsplitController.allPaneIds.contains(sourcePane))
        XCTAssertNotEqual(workspace.paneId(forPanelId: panelId), sourcePane)
        XCTAssertNotEqual(workspace.paneId(forPanelId: panelId), targetPane)
        XCTAssertNotNil(workspace.panels[panelId])
    }

    func testExternalRemotePaneMaterializationCoversInsertSplitAndRollback() throws {
        _ = NSApplication.shared

        let insertWorkspace = Workspace()
        let insertPane = try XCTUnwrap(insertWorkspace.bonsplitController.allPaneIds.first)
        let inserted = try XCTUnwrap(
            insertWorkspace.materializeExternalRemotePane(
                command: "/usr/bin/true",
                environment: [:],
                destination: .insert(targetPane: insertPane, targetIndex: 0)
            )
        )
        XCTAssertEqual(inserted.finalPane, insertPane)
        XCTAssertEqual(
            insertWorkspace.bonsplitController.tabs(inPane: insertPane).first?.id,
            inserted.tabId
        )

        let splitWorkspace = Workspace()
        let splitPane = try XCTUnwrap(splitWorkspace.bonsplitController.allPaneIds.first)
        let originalPaneCount = splitWorkspace.bonsplitController.allPaneIds.count
        let split = try XCTUnwrap(
            splitWorkspace.materializeExternalRemotePane(
                command: "/usr/bin/true",
                environment: [:],
                destination: .split(
                    targetPane: splitPane,
                    orientation: .horizontal,
                    insertFirst: true
                )
            )
        )
        XCTAssertEqual(splitWorkspace.bonsplitController.allPaneIds.count, originalPaneCount + 1)
        XCTAssertNotEqual(split.finalPane, splitPane)
        XCTAssertTrue(
            splitWorkspace.bonsplitController.tabs(inPane: split.finalPane)
                .contains(where: { $0.id == split.tabId })
        )

        let rollbackWorkspace = Workspace()
        let rollbackPane = try XCTUnwrap(rollbackWorkspace.bonsplitController.allPaneIds.first)
        let originalPanelIds = Set(rollbackWorkspace.panels.keys)
        rollbackWorkspace.bonsplitController.configuration.allowSplits = false
        XCTAssertNil(
            rollbackWorkspace.materializeExternalRemotePane(
                command: "/usr/bin/true",
                environment: [:],
                destination: .split(
                    targetPane: rollbackPane,
                    orientation: .vertical,
                    insertFirst: false
                )
            )
        )
        XCTAssertEqual(Set(rollbackWorkspace.panels.keys), originalPanelIds)
    }

    func testExternalRemotePaneFinalizeRevalidatesDestinationAndOwnsTeardown() {
        var placementCount = 0
        var teardownCount = 0

        XCTAssertFalse(
            Workspace.finalizeExternalRemotePaneDrop(
                isDestinationWritable: false,
                place: {
                    placementCount += 1
                    return true
                },
                teardown: { teardownCount += 1 }
            )
        )
        XCTAssertEqual(placementCount, 0, "Mirror mode must reject before layout mutation")
        XCTAssertEqual(teardownCount, 1, "A rejected attached session must be torn down once")

        XCTAssertTrue(
            Workspace.finalizeExternalRemotePaneDrop(
                isDestinationWritable: true,
                place: {
                    placementCount += 1
                    return true
                },
                teardown: { teardownCount += 1 }
            )
        )
        XCTAssertEqual(placementCount, 1)
        XCTAssertEqual(teardownCount, 1, "Successful placement transfers session ownership")

        XCTAssertFalse(
            Workspace.finalizeExternalRemotePaneDrop(
                isDestinationWritable: true,
                place: {
                    placementCount += 1
                    return false
                },
                teardown: { teardownCount += 1 }
            )
        )
        XCTAssertEqual(placementCount, 2)
        XCTAssertEqual(teardownCount, 2, "Placement failure must tear down once")
    }

    func testSynchronizeActiveMainWindowContextPrefersProvidedWindowOverStaleActiveManager() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        windowB.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowB)
        XCTAssertTrue(app.tabManager === managerB)

        windowA.makeKeyAndOrderFront(nil)
        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(resolved === managerA, "Expected provided active window to win over stale active manager")
        XCTAssertTrue(app.tabManager === managerA)
    }

    func testSynchronizeActiveMainWindowContextFallsBackToActiveManagerWithoutFocusedWindow() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        // Seed active manager and clear focus windows to force fallback routing.
        windowA.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(app.tabManager === managerA)
        windowA.orderOut(nil)
        windowB.orderOut(nil)

        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: nil)
        XCTAssertTrue(resolved === managerA, "Expected fallback to preserve current active manager instead of arbitrary window")
        XCTAssertTrue(app.tabManager === managerA)
    }

    func testSynchronizeActiveMainWindowContextUsesRegisteredWindowEvenIfIdentifierMutates() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        // SwiftUI can replace the NSWindow identifier string at runtime.
        window.identifier = NSUserInterfaceItemIdentifier("SwiftUI.AppWindow.IdentifierChanged")

        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: window)
        XCTAssertTrue(resolved === manager, "Expected registered window object identity to win even if identifier string changed")
        XCTAssertTrue(app.tabManager === manager)
    }
}

final class FocusFlashPatternTests: XCTestCase {
    func testFocusFlashPatternMatchesTerminalDoublePulseShape() {
        XCTAssertEqual(FocusFlashPattern.values, [0, 1, 0, 1, 0])
        XCTAssertEqual(FocusFlashPattern.keyTimes, [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(FocusFlashPattern.duration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.curves, [.easeOut, .easeIn, .easeOut, .easeIn])
        XCTAssertEqual(FocusFlashPattern.ringInset, 6, accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.ringCornerRadius, 10, accuracy: 0.0001)
    }

    func testFocusFlashPatternSegmentsCoverFullDoublePulseTimeline() {
        let segments = FocusFlashPattern.segments
        XCTAssertEqual(segments.count, 4)

        XCTAssertEqual(segments[0].delay, 0.0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[0].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[0].curve, .easeOut)

        XCTAssertEqual(segments[1].delay, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].curve, .easeIn)

        XCTAssertEqual(segments[2].delay, 0.45, accuracy: 0.0001)
        XCTAssertEqual(segments[2].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[2].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[2].curve, .easeOut)

        XCTAssertEqual(segments[3].delay, 0.675, accuracy: 0.0001)
        XCTAssertEqual(segments[3].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[3].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[3].curve, .easeIn)
    }
}

@MainActor
final class TermMeshWebViewContextMenuTests: XCTestCase {
    private func makeRightMouseDownEvent() -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create rightMouseDown event")
        }
        return event
    }

    func testWillOpenMenuAddsOpenLinkInDefaultBrowserAndRoutesSelectionToDefaultBrowserOpener() {
        _ = NSApplication.shared
        let webView = TermMeshWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let openLinkItem = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLinkItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLinkItem)
        menu.addItem(NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: ""))

        var openedURL: URL?
        webView.contextMenuLinkURLProvider = { _, _, completion in
            completion(URL(string: "https://example.com/docs")!)
        }
        webView.contextMenuDefaultBrowserOpener = { url in
            openedURL = url
            return true
        }

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        guard let defaultBrowserItemIndex = menu.items.firstIndex(where: { $0.title == "Open Link in Default Browser" }) else {
            XCTFail("Expected Open Link in Default Browser item in context menu")
            return
        }
        guard let openLinkIndex = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }) else {
            XCTFail("Expected Open Link item in context menu")
            return
        }

        XCTAssertEqual(defaultBrowserItemIndex, openLinkIndex + 1)
        let defaultBrowserItem = menu.items[defaultBrowserItemIndex]
        XCTAssertTrue(defaultBrowserItem.target === webView)
        XCTAssertNotNil(defaultBrowserItem.action)

        let dispatched = NSApp.sendAction(
            defaultBrowserItem.action!,
            to: defaultBrowserItem.target,
            from: defaultBrowserItem
        )
        XCTAssertTrue(dispatched)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
    }

    func testWillOpenMenuSkipsDefaultBrowserItemWhenContextHasNoOpenLinkEntry() {
        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Back", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Forward", action: nil, keyEquivalent: ""))

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertFalse(menu.items.contains { $0.title == "Open Link in Default Browser" })
    }
}

final class BrowserDevToolsButtonDebugSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "BrowserDevToolsButtonDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testIconCatalogIncludesExpandedChoices() {
        XCTAssertGreaterThanOrEqual(BrowserDevToolsIconOption.allCases.count, 10)
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.terminal))
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.globe))
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.curlyBracesSquare))
    }

    func testIconOptionFallsBackToDefaultForUnknownRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("this.symbol.does.not.exist", forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)

        XCTAssertEqual(
            BrowserDevToolsButtonDebugSettings.iconOption(defaults: defaults),
            BrowserDevToolsButtonDebugSettings.defaultIcon
        )
    }

    func testColorOptionFallsBackToDefaultForUnknownRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("notAValidColor", forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)

        XCTAssertEqual(
            BrowserDevToolsButtonDebugSettings.colorOption(defaults: defaults),
            BrowserDevToolsButtonDebugSettings.defaultColor
        )
    }

    func testCopyPayloadUsesPersistedValues() {
        let defaults = makeIsolatedDefaults()
        defaults.set(BrowserDevToolsIconOption.scope.rawValue, forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)
        defaults.set(BrowserDevToolsIconColorOption.bonsplitActive.rawValue, forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)

        let payload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: defaults)
        XCTAssertTrue(payload.contains("browserDevToolsIconName=scope"))
        XCTAssertTrue(payload.contains("browserDevToolsIconColor=bonsplitActive"))
    }
}

final class BrowserThemeSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "BrowserThemeSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testDefaultsMatchConfiguredFallbacks() {
        let defaults = makeIsolatedDefaults()
        XCTAssertEqual(
            BrowserThemeSettings.mode(defaults: defaults),
            BrowserThemeSettings.defaultMode
        )
    }

    func testModeReadsPersistedValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(BrowserThemeMode.dark.rawValue, forKey: BrowserThemeSettings.modeKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults), .dark)

        defaults.set(BrowserThemeMode.light.rawValue, forKey: BrowserThemeSettings.modeKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults), .light)
    }

    func testModeMigratesLegacyForcedDarkModeFlag() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: BrowserThemeSettings.legacyForcedDarkModeEnabledKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults), .dark)
        XCTAssertEqual(defaults.string(forKey: BrowserThemeSettings.modeKey), BrowserThemeMode.dark.rawValue)

        let otherDefaults = makeIsolatedDefaults()
        otherDefaults.set(false, forKey: BrowserThemeSettings.legacyForcedDarkModeEnabledKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: otherDefaults), .system)
        XCTAssertEqual(otherDefaults.string(forKey: BrowserThemeSettings.modeKey), BrowserThemeMode.system.rawValue)
    }
}

final class BrowserPanelChromeBackgroundColorTests: XCTestCase {
    func testLightModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .light)
    }

    func testDarkModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .dark)
    }

    private func assertResolvedColorMatchesTheme(
        for colorScheme: ColorScheme,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.13, green: 0.29, blue: 0.47, alpha: 1.0)

        guard
            let actual = resolvedBrowserChromeBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB),
            let expected = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}

final class BrowserPanelOmnibarPillBackgroundColorTests: XCTestCase {
    func testLightModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .light, darkenMix: 0.04)
    }

    func testDarkModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .dark, darkenMix: 0.05)
    }

    private func assertResolvedColorMatchesExpectedBlend(
        for colorScheme: ColorScheme,
        darkenMix: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1.0)
        let expected = themeBackground.blended(withFraction: darkenMix, of: .black) ?? themeBackground

        guard
            let actual = resolvedBrowserOmnibarPillBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB),
            let expectedSRGB = expected.usingColorSpace(.sRGB),
            let themeSRGB = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expectedSRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expectedSRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expectedSRGB.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expectedSRGB.alphaComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertNotEqual(actual.redComponent, themeSRGB.redComponent, file: file, line: line)
    }
}

final class BrowserDeveloperToolsShortcutDefaultsTests: XCTestCase {
    func testSafariDefaultShortcutForToggleDeveloperTools() {
        let shortcut = KeyboardShortcutSettings.Action.toggleBrowserDeveloperTools.defaultShortcut
        XCTAssertEqual(shortcut.key, "i")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }

    func testSafariDefaultShortcutForShowJavaScriptConsole() {
        let shortcut = KeyboardShortcutSettings.Action.showBrowserJavaScriptConsole.defaultShortcut
        XCTAssertEqual(shortcut.key, "c")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }
}

final class WorkspaceRenameShortcutDefaultsTests: XCTestCase {
    func testNewProjectShortcutDefaultsToControlOptionCommandN() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.newProject.label, "New Project")
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.newProject.defaultsKey,
            "shortcut.newProject"
        )

        let shortcut = KeyboardShortcutSettings.Action.newProject.defaultShortcut
        XCTAssertEqual(shortcut.key, "n")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertTrue(shortcut.control)
    }

    @MainActor
    func testNewProjectShortcutMatchesPhysicalNKeyUnderKoreanInputSource() {
        _ = NSApplication.shared
        let app = AppDelegate()
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "ㅜ",
            charactersIgnoringModifiers: "ㅜ",
            isARepeat: false,
            keyCode: 45
        )

        XCTAssertNotNil(event)
        XCTAssertTrue(
            app.matchShortcut(
                event: event!,
                shortcut: KeyboardShortcutSettings.Action.newProject.defaultShortcut
            )
        )
    }

    func testRenameTabShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.label, "Rename Tab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.defaultsKey, "shortcut.renameTab")

        let shortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWindowShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.label, "Close Window")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.defaultsKey, "shortcut.closeWindow")

        let shortcut = KeyboardShortcutSettings.Action.closeWindow.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertTrue(shortcut.control)
    }

    func testRenameWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.label, "Rename Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.defaultsKey, "shortcut.renameWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testRenameWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testCloseWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.label, "Close Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.defaultsKey, "shortcut.closeWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testNextPreviousWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.label, "Next Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.label, "Previous Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.defaultsKey, "shortcut.nextSidebarTab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.defaultsKey, "shortcut.prevSidebarTab")

        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertEqual(nextShortcut.key, "]")
        XCTAssertTrue(nextShortcut.command)
        XCTAssertFalse(nextShortcut.shift)
        XCTAssertFalse(nextShortcut.option)
        XCTAssertTrue(nextShortcut.control)

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertEqual(prevShortcut.key, "[")
        XCTAssertTrue(prevShortcut.command)
        XCTAssertFalse(prevShortcut.shift)
        XCTAssertFalse(prevShortcut.option)
        XCTAssertTrue(prevShortcut.control)
    }

    func testNextPreviousWorkspaceShortcutsConvertToMenuShortcut() {
        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertNotNil(nextShortcut.keyEquivalent)
        XCTAssertEqual(nextShortcut.menuItemKeyEquivalent, "]")
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.control))

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertNotNil(prevShortcut.keyEquivalent)
        XCTAssertEqual(prevShortcut.menuItemKeyEquivalent, "[")
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.control))
    }

    func testMenuItemKeyEquivalentHandlesArrowAndTabKeys() {
        XCTAssertNotNil(StoredShortcut(key: "←", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "→", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↑", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↓", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertEqual(
            StoredShortcut(key: "\t", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent,
            "\t"
        )
    }

    func testShortcutDefaultsKeysRemainUnique() {
        let keys = KeyboardShortcutSettings.Action.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}

@MainActor
final class BrowserDeveloperToolsConfigurationTests: XCTestCase {
    func testBrowserPanelEnablesInspectableWebViewAndDeveloperExtras() {
        let panel = BrowserPanel(workspaceId: UUID())
        let developerExtras = panel.webView.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool
        XCTAssertEqual(developerExtras, true)

        if #available(macOS 13.3, *) {
            XCTAssertTrue(panel.webView.isInspectable)
        }
    }

    /// Browser chrome only mirrors the terminal background in dark mode; light
    /// mode deliberately stays on `windowBackgroundColor` (see `Light mode #258`).
    /// Both cases pin `NSApp.appearance` so the result does not depend on the
    /// system setting of whatever machine runs the suite.
    private func withAppearance(_ name: NSAppearance.Name, _ body: () -> Void) {
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        NSApp.appearance = NSAppearance(named: name)
        body()
    }

    private func postGhosttyBackground(_ color: NSColor, opacity: Double) {
        NotificationCenter.default.post(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: color,
                GhosttyNotificationKey.backgroundOpacity: opacity
            ]
        )
    }

    private func assertColor(
        _ actual: NSColor?,
        matches expected: NSColor,
        line: UInt = #line
    ) {
        guard let actual = actual?.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible under-page background colors", line: line)
            return
        }
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.005, line: line)
    }

    func testBrowserPanelRefreshesUnderPageBackgroundColorWhenGhosttyBackgroundChanges() {
        withAppearance(.darkAqua) {
            let panel = BrowserPanel(workspaceId: UUID())
            let updatedColor = NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0)
            let updatedOpacity = 0.57

            postGhosttyBackground(updatedColor, opacity: updatedOpacity)

            assertColor(
                panel.webView.underPageBackgroundColor,
                matches: updatedColor.withAlphaComponent(updatedOpacity)
            )
        }
    }

    func testBrowserPanelKeepsWindowBackgroundInLightModeWhenGhosttyBackgroundChanges() {
        withAppearance(.aqua) {
            let panel = BrowserPanel(workspaceId: UUID())

            postGhosttyBackground(
                NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0),
                opacity: 0.57
            )

            assertColor(
                panel.webView.underPageBackgroundColor,
                matches: NSColor.windowBackgroundColor
            )
        }
    }

    func testBrowserPanelStartsAsNewTabWithoutLoadingAboutBlank() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertEqual(panel.displayTitle, "New tab")
        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertTrue(panel.isShowingNewTabPage)
        XCTAssertNil(panel.webView.url)
        XCTAssertNil(panel.currentURL)
    }

    func testBrowserPanelLeavesNewTabPageStateWhenNavigationStarts() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertTrue(panel.isShowingNewTabPage)
        panel.navigate(to: URL(string: "https://example.com")!)
        XCTAssertFalse(panel.isShowingNewTabPage)
    }

    func testBrowserPanelThemeModeUpdatesWebViewAppearance() {
        let panel = BrowserPanel(workspaceId: UUID())

        panel.setBrowserThemeMode(.dark)
        XCTAssertEqual(panel.webView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        panel.setBrowserThemeMode(.light)
        XCTAssertEqual(panel.webView.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)

        panel.setBrowserThemeMode(.system)
        XCTAssertNil(panel.webView.appearance)
    }
}

@MainActor
final class BrowserJavaScriptDialogDelegateTests: XCTestCase {
    func testBrowserPanelUIDelegateImplementsJavaScriptDialogSelectors() {
        let panel = BrowserPanel(workspaceId: UUID())
        guard let uiDelegate = panel.webView.uiDelegate as? NSObject else {
            XCTFail("Expected BrowserPanel webView.uiDelegate to be an NSObject")
            return
        }

        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript alert handling"
        )
        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript confirm handling"
        )
        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript prompt handling"
        )
    }
}

@MainActor
final class BrowserDeveloperToolsVisibilityPersistenceTests: XCTestCase {
    private final class FakeInspector: NSObject {
        private(set) var showCount = 0
        private(set) var closeCount = 0
        private var visible = false

        @objc func isVisible() -> Bool {
            visible
        }

        @objc func show() {
            showCount += 1
            visible = true
        }

        @objc func close() {
            closeCount += 1
            visible = false
        }
    }

    override class func setUp() {
        super.setUp()
        installTermMeshUnitTestInspectorOverride()
    }

    private func makePanelWithInspector() -> (BrowserPanel, FakeInspector) {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector()
        panel.webView.termMeshSetUnitTestInspector(inspector)
        return (panel, inspector)
    }

    func testRestoreReopensInspectorAfterAttachWhenPreferredVisible() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate WebKit closing inspector during detach/reattach churn.
        inspector.close()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 1)

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 2)
    }

    func testSyncRespectsManualCloseAndPreventsUnexpectedRestore() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate user closing inspector before detach.
        inspector.close()
        panel.syncDeveloperToolsPreferenceFromInspector()

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
    }

    func testSyncCanPreserveVisibleIntentDuringDetachChurn() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate a transient close caused by view detach, not user intent.
        inspector.close()
        panel.syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: true)
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 2)
    }

    func testForcedRefreshAfterAttachKeepsVisibleInspectorState() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test")
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertEqual(inspector.showCount, 1)

        // The force-refresh request should be one-shot.
        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertEqual(inspector.showCount, 1)
    }

    func testRefreshRequestTracksPendingStateUntilRestoreRuns() {
        let (panel, _) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertFalse(panel.hasPendingDeveloperToolsRefreshAfterAttach())

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test")
        XCTAssertTrue(panel.hasPendingDeveloperToolsRefreshAfterAttach())

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertFalse(panel.hasPendingDeveloperToolsRefreshAfterAttach())
    }

    func testTransientHideAttachmentPreserveFollowsDeveloperToolsIntent() {
        let (panel, _) = makePanelWithInspector()

        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
        XCTAssertTrue(panel.hideDeveloperTools())
        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
    }

    func testWebViewDismantleSkipsDetachWhenDeveloperToolsIntentIsVisible() {
        let (panel, _) = makePanelWithInspector()
        XCTAssertTrue(panel.showDeveloperTools())

        let representable = WebViewRepresentable(
            panel: panel,
            shouldAttachWebView: true,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0
        )
        let coordinator = representable.makeCoordinator()
        coordinator.webView = panel.webView
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(panel.webView)

        WebViewRepresentable.dismantleNSView(host, coordinator: coordinator)

        XCTAssertTrue(panel.webView.superview === host)
    }

    func testWebViewDismantleDetachesWhenDeveloperToolsIntentIsHidden() {
        let (panel, _) = makePanelWithInspector()
        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())

        let representable = WebViewRepresentable(
            panel: panel,
            shouldAttachWebView: true,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0
        )
        let coordinator = representable.makeCoordinator()
        coordinator.webView = panel.webView
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(panel.webView)

        WebViewRepresentable.dismantleNSView(host, coordinator: coordinator)

        XCTAssertNil(panel.webView.superview)
    }
}

final class WorkspaceShortcutMapperTests: XCTestCase {
    func testCommandNineMapsToLastWorkspaceIndex() {
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 1), 0)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 4), 3)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 12), 11)
    }

    func testCommandDigitBadgesUseNineForLastWorkspaceWhenNeeded() {
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 0, workspaceCount: 12), 1)
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 7, workspaceCount: 12), 8)
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 11, workspaceCount: 12), 9)
        XCTAssertNil(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 8, workspaceCount: 12))
    }
}

final class BrowserOmnibarCommandNavigationTests: XCTestCase {
    func testArrowNavigationDeltaRequiresFocusedAddressBarAndNoModifierFlags() {
        XCTAssertNil(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: false,
                flags: [],
                keyCode: 126
            )
        )
        XCTAssertNil(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                keyCode: 126
            )
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [],
                keyCode: 126
            ),
            -1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [],
                keyCode: 125
            ),
            1
        )
    }

    func testArrowNavigationDeltaIgnoresCapsLockModifier() {
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.capsLock],
                keyCode: 126
            ),
            -1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.capsLock],
                keyCode: 125
            ),
            1
        )
    }

    func testCommandNavigationDeltaRequiresFocusedAddressBarAndCommandOrControlOnly() {
        XCTAssertNil(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: false,
                flags: [.command],
                chars: "n"
            )
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                chars: "n"
            ),
            1
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                chars: "p"
            ),
            -1
        )

        XCTAssertNil(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command, .shift],
                chars: "n"
            )
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control],
                chars: "p"
            ),
            -1
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control],
                chars: "n"
            ),
            1
        )
    }

    func testCommandNavigationDeltaIgnoresCapsLockModifier() {
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control, .capsLock],
                chars: "n"
            ),
            1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command, .capsLock],
                chars: "p"
            ),
            -1
        )
    }

    func testSubmitOnReturnIgnoresCapsLockModifier() {
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: []))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.shift]))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.capsLock]))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.shift, .capsLock]))
        XCTAssertFalse(browserOmnibarShouldSubmitOnReturn(flags: [.command, .capsLock]))
    }
}

final class BrowserZoomShortcutActionTests: XCTestCase {
    func testZoomInSupportsEqualsAndPlusVariants() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "=", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "+", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command, .shift], chars: "+", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "+", keyCode: 30),
            .zoomIn
        )
    }

    func testZoomOutSupportsMinusAndUnderscoreVariants() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "-", keyCode: 27),
            .zoomOut
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command, .shift], chars: "_", keyCode: 27),
            .zoomOut
        )
    }

    func testZoomRequiresCommandWithoutOptionOrControl() {
        XCTAssertNil(browserZoomShortcutAction(flags: [], chars: "=", keyCode: 24))
        XCTAssertNil(browserZoomShortcutAction(flags: [.command, .option], chars: "=", keyCode: 24))
        XCTAssertNil(browserZoomShortcutAction(flags: [.command, .control], chars: "-", keyCode: 27))
    }

    func testResetSupportsCommandZero() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "0", keyCode: 29),
            .reset
        )
    }
}

final class BrowserZoomShortcutRoutingPolicyTests: XCTestCase {
    func testRoutesWhenGhosttyIsFirstResponderAndShortcutIsZoom() {
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "=",
                keyCode: 24
            )
        )
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "-",
                keyCode: 27
            )
        )
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "0",
                keyCode: 29
            )
        )
    }

    func testDoesNotRouteWhenFirstResponderIsNotGhostty() {
        XCTAssertFalse(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: false,
                flags: [.command],
                chars: "=",
                keyCode: 24
            )
        )
    }

    func testDoesNotRouteForNonZoomShortcuts() {
        XCTAssertFalse(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
    }
}

final class GhosttyResponderResolutionTests: XCTestCase {
    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testResolvesGhosttyViewFromDescendantResponder() {
        let ghosttyView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let descendant = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        ghosttyView.addSubview(descendant)

        XCTAssertTrue(termMeshOwningGhosttyView(for: descendant) === ghosttyView)
    }

    func testResolvesGhosttyViewFromGhosttyResponder() {
        let ghosttyView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertTrue(termMeshOwningGhosttyView(for: ghosttyView) === ghosttyView)
    }

    func testReturnsNilForUnrelatedResponder() {
        let view = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(termMeshOwningGhosttyView(for: view))
    }
}

final class CommandPaletteKeyboardNavigationTests: XCTestCase {
    func testArrowKeysMoveSelectionWithoutModifiers() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [],
                chars: "",
                keyCode: 125
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [],
                chars: "",
                keyCode: 126
            ),
            -1
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.shift],
                chars: "",
                keyCode: 125
            )
        )
    }

    func testControlLetterNavigationSupportsPrintableAndControlChars() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "n",
                keyCode: 45
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0e}",
                keyCode: 45
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "p",
                keyCode: 35
            ),
            -1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{10}",
                keyCode: 35
            ),
            -1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "j",
                keyCode: 38
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0a}",
                keyCode: 38
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "k",
                keyCode: 40
            ),
            -1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0b}",
                keyCode: 40
            ),
            -1
        )
    }

    func testIgnoresUnsupportedModifiersAndKeys() {
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control, .shift],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "x",
                keyCode: 7
            )
        )
    }
}

final class CommandPaletteRenameSelectionSettingsTests: XCTestCase {
    private let suiteName = "term-mesh.tests.commandPaletteRenameSelection.\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDefaultsToSelectAllWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertTrue(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }

    func testReturnsFalseWhenStoredFalse() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
        XCTAssertFalse(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }

    func testReturnsTrueWhenStoredTrue() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
        XCTAssertTrue(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }
}

final class CommandPaletteSelectionScrollBehaviorTests: XCTestCase {
    func testFirstEntryPinsToTopAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.top)
    }

    func testLastEntryPinsToBottomAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 19,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.bottom)
    }

    func testMiddleEntryUsesNilAnchorForMinimalScroll() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 6,
            resultCount: 20
        )
        XCTAssertNil(anchor)
    }

    func testEmptyResultsProduceNoAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 0
        )
        XCTAssertNil(anchor)
    }
}

final class SidebarCommandHintPolicyTests: XCTestCase {
    func testCommandHintRequiresCommandOnlyModifier() {
        XCTAssertTrue(SidebarCommandHintPolicy.shouldShowHints(for: [.command]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: []))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .shift]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .option]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .control]))
    }

    func testCommandHintUsesIntentionalHoldDelay() {
        XCTAssertGreaterThanOrEqual(SidebarCommandHintPolicy.intentionalHoldDelay, 0.25)
    }

    func testCurrentWindowRequiresHostWindowToBeKeyAndMatchEventWindow() {
        XCTAssertTrue(
            SidebarCommandHintPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            SidebarCommandHintPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 7,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            SidebarCommandHintPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: false,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )
    }

    func testWindowScopedCommandHintsUseKeyWindowWhenNoEventWindowIsAvailable() {
        XCTAssertTrue(
            SidebarCommandHintPolicy.shouldShowHints(
                for: [.command],
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: nil,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            SidebarCommandHintPolicy.shouldShowHints(
                for: [.command],
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: nil,
                keyWindowNumber: 7
            )
        )
    }
}

final class ShortcutHintDebugSettingsTests: XCTestCase {
    func testClampKeepsValuesWithinSupportedRange() {
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(0.0), 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(4.0), 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(-100.0), ShortcutHintDebugSettings.offsetRange.lowerBound)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(100.0), ShortcutHintDebugSettings.offsetRange.upperBound)
    }

    func testDefaultOffsetsMatchCurrentBadgePlacements() {
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintX, 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintY, 0.0)
        XCTAssertFalse(ShortcutHintDebugSettings.defaultAlwaysShowHints)
    }
}

final class ShortcutHintLanePlannerTests: XCTestCase {
    func testAssignLanesKeepsSeparatedIntervalsOnSingleLane() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 28...40, 48...64]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 0, 0])
    }

    func testAssignLanesStacksOverlappingIntervalsIntoAdditionalLanes() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 22...38, 40...56]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 1, 2, 0])
    }
}

final class ShortcutHintHorizontalPlannerTests: XCTestCase {
    func testAssignRightEdgesResolvesOverlapWithMinimumSpacing() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 30...46]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 6)

        XCTAssertEqual(rightEdges.count, intervals.count)

        let adjustedIntervals = zip(intervals, rightEdges).map { interval, rightEdge in
            let width = interval.upperBound - interval.lowerBound
            return (rightEdge - width)...rightEdge
        }

        XCTAssertGreaterThanOrEqual(adjustedIntervals[1].lowerBound - adjustedIntervals[0].upperBound, 6)
        XCTAssertGreaterThanOrEqual(adjustedIntervals[2].lowerBound - adjustedIntervals[1].upperBound, 6)
    }

    func testAssignRightEdgesKeepsAlreadySeparatedIntervalsInPlace() {
        let intervals: [ClosedRange<CGFloat>] = [0...12, 20...32, 40...52]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 4)
        XCTAssertEqual(rightEdges, [12, 32, 52])
    }
}

final class WorkspacePlacementSettingsTests: XCTestCase {
    func testCurrentPlacementDefaultsToAfterCurrentWhenUnset() {
        let suiteName = "WorkspacePlacementSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testCurrentPlacementReadsStoredValidValueAndFallsBackForInvalid() {
        let suiteName = "WorkspacePlacementSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(NewWorkspacePlacement.top.rawValue, forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .top)

        defaults.set("nope", forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testInsertionIndexTopInsertsBeforeUnpinned() {
        let index = WorkspacePlacementSettings.insertionIndex(
            placement: .top,
            selectedIndex: 4,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 7
        )
        XCTAssertEqual(index, 2)
    }

    func testInsertionIndexAfterCurrentHandlesPinnedAndUnpinnedSelection() {
        let afterUnpinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 3,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterUnpinned, 4)

        let afterPinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 0,
            selectedIsPinned: true,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterPinned, 2)
    }

    func testInsertionIndexEndAndNoSelectionAppend() {
        let endIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .end,
            selectedIndex: 1,
            selectedIsPinned: false,
            pinnedCount: 1,
            totalCount: 5
        )
        XCTAssertEqual(endIndex, 5)

        let noSelectionIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: nil,
            selectedIsPinned: false,
            pinnedCount: 0,
            totalCount: 5
        )
        XCTAssertEqual(noSelectionIndex, 5)
    }
}

final class WorkspaceTabColorSettingsTests: XCTestCase {
    func testStandardPaletteIsComputedOnceUntilInvalidated() {
        WorkspaceTabColorSettings.invalidateStandardPaletteCache()
        let initialCount = WorkspaceTabColorSettings.standardPaletteComputationCount

        let first = WorkspaceTabColorSettings.palette()
        let second = WorkspaceTabColorSettings.palette()

        XCTAssertEqual(first, second)
        XCTAssertEqual(WorkspaceTabColorSettings.standardPaletteComputationCount, initialCount + 1)

        WorkspaceTabColorSettings.invalidateStandardPaletteCache()
        _ = WorkspaceTabColorSettings.palette()
        XCTAssertEqual(WorkspaceTabColorSettings.standardPaletteComputationCount, initialCount + 2)
    }

    func testNormalizedHexAcceptsAndNormalizesValidInput() {
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("#abc123"), "#ABC123")
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("  aBcDeF "), "#ABCDEF")
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#1234"))
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#GG1234"))
    }

    func testBuiltInPaletteMatchesOriginalPRPalette() {
        let suiteName = "WorkspaceTabColorSettingsTests.BuiltInPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let palette = WorkspaceTabColorSettings.defaultPaletteWithOverrides(defaults: defaults)
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(palette.first?.name, "Red")
        XCTAssertEqual(palette.first?.hex, "#C0392B")
        XCTAssertEqual(palette.last?.name, "Charcoal")
        XCTAssertFalse(palette.contains(where: { $0.name == "Gold" }))
    }

    func testDefaultOverrideRoundTripFallsBackWhenResetToBase() {
        let suiteName = "WorkspaceTabColorSettingsTests.DefaultOverride.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = WorkspaceTabColorSettings.defaultPalette[0]
        XCTAssertEqual(
            WorkspaceTabColorSettings.defaultColorHex(named: first.name, defaults: defaults),
            first.hex
        )

        WorkspaceTabColorSettings.setDefaultColor(named: first.name, hex: "#00aa33", defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.defaultColorHex(named: first.name, defaults: defaults),
            "#00AA33"
        )

        WorkspaceTabColorSettings.setDefaultColor(named: first.name, hex: first.hex, defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.defaultColorHex(named: first.name, defaults: defaults),
            first.hex
        )
    }

    func testAddCustomColorPersistsAndDeduplicatesByMostRecent() {
        let suiteName = "WorkspaceTabColorSettingsTests.CustomColors.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor(" #00aa33 ", defaults: defaults),
            "#00AA33"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#112233", defaults: defaults),
            "#112233"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#00AA33", defaults: defaults),
            "#00AA33"
        )
        XCTAssertNil(WorkspaceTabColorSettings.addCustomColor("nope", defaults: defaults))

        XCTAssertEqual(
            WorkspaceTabColorSettings.customColors(defaults: defaults),
            ["#00AA33", "#112233"]
        )
    }

    func testPaletteIncludesCustomEntriesAndResetClearsAll() {
        let suiteName = "WorkspaceTabColorSettingsTests.Reset.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = WorkspaceTabColorSettings.defaultPalette[0]
        WorkspaceTabColorSettings.setDefaultColor(named: first.name, hex: "#334455", defaults: defaults)
        _ = WorkspaceTabColorSettings.addCustomColor("#778899", defaults: defaults)

        let paletteBeforeReset = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(paletteBeforeReset.count, WorkspaceTabColorSettings.defaultPalette.count + 1)
        XCTAssertEqual(paletteBeforeReset[0].hex, "#334455")
        XCTAssertEqual(paletteBeforeReset.last?.name, "Custom 1")
        XCTAssertEqual(paletteBeforeReset.last?.hex, "#778899")

        WorkspaceTabColorSettings.reset(defaults: defaults)

        XCTAssertEqual(WorkspaceTabColorSettings.customColors(defaults: defaults), [])
        XCTAssertEqual(
            WorkspaceTabColorSettings.defaultColorHex(named: first.name, defaults: defaults),
            first.hex
        )
    }

    func testDisplayColorLightModeKeepsOriginalHex() {
        let originalHex = "#1A5276"
        let rendered = WorkspaceTabColorSettings.displayNSColor(
            hex: originalHex,
            colorScheme: .light
        )

        XCTAssertEqual(rendered?.hexString(), originalHex)
    }

    func testDisplayColorDarkModeBrightensColor() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }

    func testDisplayColorDarkModeKeepsGrayscaleNeutral() {
        let originalHex = "#808080"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ),
              let renderedSRGB = rendered.usingColorSpace(.sRGB) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertGreaterThan(rendered.luminance, base.luminance)
        XCTAssertLessThan(abs(renderedSRGB.redComponent - renderedSRGB.greenComponent), 0.003)
        XCTAssertLessThan(abs(renderedSRGB.greenComponent - renderedSRGB.blueComponent), 0.003)
    }

    func testDisplayColorForceBrightensInLightMode() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .light,
                  forceBright: true
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }
}

final class WorkspaceAutoReorderSettingsTests: XCTestCase {
    func testDefaultIsEnabled() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }

    func testDisabledWhenSetToFalse() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: WorkspaceAutoReorderSettings.key)
        XCTAssertFalse(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }

    func testEnabledWhenSetToTrue() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Enabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: WorkspaceAutoReorderSettings.key)
        XCTAssertTrue(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }
}

final class SidebarBranchLayoutSettingsTests: XCTestCase {
    func testDefaultUsesVerticalLayout() {
        let suiteName = "SidebarBranchLayoutSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "SidebarBranchLayoutSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: SidebarBranchLayoutSettings.key)
        XCTAssertFalse(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))

        defaults.set(true, forKey: SidebarBranchLayoutSettings.key)
        XCTAssertTrue(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))
    }
}

final class SidebarPresentationSettingsTests: XCTestCase {
    func testSeparatedSectionsAreEnabledByDefault() {
        let suiteName = "SidebarPresentationSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: SidebarPresentationSettings.separatedSectionsEnabledKey))
        XCTAssertTrue(SidebarPresentationSettings.usesSeparatedSections(defaults: defaults))
    }

    func testStoredPreferencePersistsAcrossDefaultsInstances() {
        let suiteName = "SidebarPresentationSettingsTests.Stored.\(UUID().uuidString)"
        guard let writer = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { writer.removePersistentDomain(forName: suiteName) }

        writer.set(true, forKey: SidebarPresentationSettings.separatedSectionsEnabledKey)
        guard let enabledReader = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to reopen isolated UserDefaults suite")
            return
        }
        XCTAssertTrue(SidebarPresentationSettings.usesSeparatedSections(defaults: enabledReader))

        writer.set(false, forKey: SidebarPresentationSettings.separatedSectionsEnabledKey)
        guard let disabledReader = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to reopen isolated UserDefaults suite")
            return
        }
        XCTAssertNotNil(disabledReader.object(forKey: SidebarPresentationSettings.separatedSectionsEnabledKey))
        XCTAssertFalse(SidebarPresentationSettings.usesSeparatedSections(defaults: disabledReader))
    }

    func testSeparatedPresentationExcludesPeerMirrorsFromLocalWorkspaces() {
        XCTAssertTrue(SidebarPresentationSettings.includesInLocalWorkspaces(
            isPeerMirror: false,
            separatedSectionsEnabled: true
        ))
        XCTAssertFalse(SidebarPresentationSettings.includesInLocalWorkspaces(
            isPeerMirror: true,
            separatedSectionsEnabled: true
        ))
    }

    func testLegacyPresentationKeepsPeerMirrorsInWorkspaceList() {
        XCTAssertTrue(SidebarPresentationSettings.includesInLocalWorkspaces(
            isPeerMirror: false,
            separatedSectionsEnabled: false
        ))
        XCTAssertTrue(SidebarPresentationSettings.includesInLocalWorkspaces(
            isPeerMirror: true,
            separatedSectionsEnabled: false
        ))
    }

    func testSeparatedInteractionScopeExcludesHiddenMirrorFromRangeAndContextTargets() {
        let localA = UUID()
        let peerMirror = UUID()
        let localB = UUID()
        let candidates = [
            (id: localA, isPeerMirror: false),
            (id: peerMirror, isPeerMirror: true),
            (id: localB, isPeerMirror: false),
        ]

        let visibleIDs = SidebarPresentationSettings.visibleLocalWorkspaceIDs(
            from: candidates,
            separatedSectionsEnabled: true
        )

        XCTAssertEqual(visibleIDs, [localA, localB])
        XCTAssertEqual(
            SidebarPresentationSettings.rangeSelectionIDs(
                anchorID: localA,
                targetID: localB,
                visibleWorkspaceIDs: visibleIDs
            ),
            [localA, localB]
        )
        XCTAssertEqual(
            SidebarPresentationSettings.contextTargetIDs(
                clickedID: localB,
                selectedIDs: [localA, peerMirror, localB],
                visibleWorkspaceIDs: visibleIDs
            ),
            [localA, localB]
        )
    }

    func testLegacyInteractionScopeRetainsMirror() {
        let localA = UUID()
        let peerMirror = UUID()
        let localB = UUID()
        let candidates = [
            (id: localA, isPeerMirror: false),
            (id: peerMirror, isPeerMirror: true),
            (id: localB, isPeerMirror: false),
        ]

        let visibleIDs = SidebarPresentationSettings.visibleLocalWorkspaceIDs(
            from: candidates,
            separatedSectionsEnabled: false
        )

        XCTAssertEqual(visibleIDs, [localA, peerMirror, localB])
        XCTAssertEqual(
            SidebarPresentationSettings.rangeSelectionIDs(
                anchorID: localA,
                targetID: localB,
                visibleWorkspaceIDs: visibleIDs
            ),
            [localA, peerMirror, localB]
        )
    }
}

final class SidebarAxisPickerTests: XCTestCase {
    func testEqualityDependsOnlyOnRenderedSelection() {
        let host = SidebarAxisPicker(selection: SidebarAxis.host.rawValue) { _ in }
        let sameHostWithDifferentAction = SidebarAxisPicker(selection: SidebarAxis.host.rawValue) { _ in
            XCTFail("Action identity must not affect rendering equality")
        }
        let project = SidebarAxisPicker(selection: SidebarAxis.project.rawValue) { _ in }

        XCTAssertEqual(host, sameHostWithDifferentAction)
        XCTAssertNotEqual(host, project)
    }
}

final class SidebarActiveTabIndicatorSettingsTests: XCTestCase {
    func testDefaultStyleWhenUnset() {
        let suiteName = "SidebarActiveTabIndicatorSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(
            SidebarActiveTabIndicatorSettings.current(defaults: defaults),
            SidebarActiveTabIndicatorSettings.defaultStyle
        )
    }

    func testStoredStyleParsesAndInvalidFallsBack() {
        let suiteName = "SidebarActiveTabIndicatorSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(SidebarActiveTabIndicatorStyle.leftRail.rawValue, forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(SidebarActiveTabIndicatorSettings.current(defaults: defaults), .leftRail)

        defaults.set("rail", forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(SidebarActiveTabIndicatorSettings.current(defaults: defaults), .leftRail)

        defaults.set("not-a-style", forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(
            SidebarActiveTabIndicatorSettings.current(defaults: defaults),
            SidebarActiveTabIndicatorSettings.defaultStyle
        )
    }
}

final class AppearanceSettingsTests: XCTestCase {
    func testResolvedModeDefaultsToSystemWhenUnset() {
        let suiteName = "AppearanceSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)

        let resolved = AppearanceSettings.resolvedMode(defaults: defaults)
        XCTAssertEqual(resolved, .system)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.system.rawValue)
    }
}

final class QuitWarningSettingsTests: XCTestCase {
    func testDefaultWarnBeforeQuitIsEnabledWhenUnset() {
        let suiteName = "QuitWarningSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: QuitWarningSettings.warnBeforeQuitKey)

        XCTAssertTrue(QuitWarningSettings.isEnabled(defaults: defaults))
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "QuitWarningSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertFalse(QuitWarningSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertTrue(QuitWarningSettings.isEnabled(defaults: defaults))
    }
}

// UpdateChannelSettingsTests removed — UpdateFeedResolver was deleted with Sparkle (8c666a29).

final class WorkspaceReorderTests: XCTestCase {
    @MainActor
    func testReorderWorkspaceMovesWorkspaceToRequestedIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
    }

    @MainActor
    func testReorderWorkspaceClampsOutOfRangeTargetIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: first.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    @MainActor
    func testReorderWorkspaceReturnsFalseForUnknownWorkspace() {
        let manager = TabManager()
        XCTAssertFalse(manager.reorderWorkspace(tabId: UUID(), toIndex: 0))
    }
}

@MainActor
final class TabManagerChildExitCloseTests: XCTestCase {
    func testChildExitPolicyPreservesRemoteRelayPanel() {
        XCTAssertTrue(
            TabManager.shouldPreservePanelAfterChildExit(isRemoteRelay: true)
        )
    }

    func testChildExitPolicyDoesNotPreserveOrdinaryTerminalPanel() {
        XCTAssertFalse(
            TabManager.shouldPreservePanelAfterChildExit(isRemoteRelay: false)
        )
    }

    func testChildExitOnLastPanelClosesSelectedWorkspaceAndKeepsIndexStable() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(tabId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id])
        XCTAssertEqual(
            manager.selectedTabId,
            third.id,
            "Expected selection to stay at the same index after deleting the selected workspace"
        )
    }

    func testChildExitOnLastPanelInLastWorkspaceSelectsPreviousWorkspace() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(tabId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id])
        XCTAssertEqual(
            manager.selectedTabId,
            first.id,
            "Expected previous workspace to be selected after closing the last-index workspace"
        )
    }

    func testChildExitOnNonLastPanelClosesOnlyPanel() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        guard let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        let panelCountBefore = workspace.panels.count
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: splitPanel.id)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs.first?.id, workspace.id)
        XCTAssertEqual(workspace.panels.count, panelCountBefore - 1)
        XCTAssertNotNil(workspace.panels[initialPanelId], "Expected sibling panel to remain")
    }
}

@MainActor
final class TabManagerPendingUnfocusPolicyTests: XCTestCase {
    func testDoesNotUnfocusWhenPendingTabIsCurrentlySelected() {
        let tabId = UUID()

        XCTAssertFalse(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: tabId,
                selectedTabId: tabId
            )
        )
    }

    func testUnfocusesWhenPendingTabIsNotSelected() {
        XCTAssertTrue(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: UUID(),
                selectedTabId: UUID()
            )
        )
        XCTAssertTrue(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: UUID(),
                selectedTabId: nil
            )
        )
    }
}

@MainActor
final class TabManagerSurfaceCreationTests: XCTestCase {
    func testNewSurfaceFocusesCreatedSurface() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }

        let beforePanels = Set(workspace.panels.keys)
        manager.newSurface()
        let afterPanels = Set(workspace.panels.keys)

        let createdPanels = afterPanels.subtracting(beforePanels)
        XCTAssertEqual(createdPanels.count, 1, "Expected one new surface for Cmd+T path")
        guard let createdPanelId = createdPanels.first else { return }

        XCTAssertEqual(
            workspace.focusedPanelId,
            createdPanelId,
            "Expected newly created surface to be focused"
        )
    }

    func testOpenBrowserInsertAtEndPlacesNewBrowserAtPaneEnd() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused workspace and pane")
            return
        }

        // Add one extra surface so we verify append-to-end rather than first insert behavior.
        _ = workspace.newTerminalSurface(inPane: paneId, focus: false)

        guard let browserPanelId = manager.openBrowser(insertAtEnd: true) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        let tabs = workspace.bonsplitController.tabs(inPane: paneId)
        guard let lastSurfaceId = tabs.last?.id else {
            XCTFail("Expected at least one surface in pane")
            return
        }

        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected Cmd+Shift+B/Cmd+L open path to append browser surface at end"
        )
        XCTAssertEqual(workspace.focusedPanelId, browserPanelId, "Expected opened browser surface to be focused")
    }
}

@MainActor
final class WorkspaceTerminalConfigInheritanceSelectionTests: XCTestCase {
    func testPrefersSelectedTerminalInTargetPaneOverFocusedTerminalElsewhere() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId) else {
            XCTFail("Expected workspace split setup to succeed")
            return
        }

        // Programmatic split focuses the new right panel by default.
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: leftPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftPanelId,
            "Expected inheritance to use the selected terminal in the target pane"
        )
    }

    func testFallsBackToAnotherTerminalInPaneWhenSelectedTabIsBrowser() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected workspace browser setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: paneId)
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected inheritance to fall back to a terminal in the pane when browser is selected"
        )
    }

    func testPreferredTerminalPanelWinsWhenProvided() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a terminal panel")
            return
        }

        let sourcePanel = workspace.terminalPanelForConfigInheritance(preferredPanelId: terminalPanelId)
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testPrefersLastFocusedTerminalWhenBrowserFocusedInDifferentPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: rightPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected inheritance to prefer last focused terminal when browser is focused in another pane"
        )
    }
}

@MainActor
final class TabManagerWorkspaceConfigInheritanceSourceTests: XCTestCase {
    func testUsesFocusedTerminalWhenTerminalIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused terminal")
            return
        }

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testFallsBackToTerminalWhenBrowserIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected selected workspace setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected new workspace inheritance source to resolve to the pane terminal when browser is focused"
        )
    }

    func testPrefersLastFocusedTerminalAcrossPanesWhenBrowserIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected workspace inheritance source to use last focused terminal across panes"
        )
    }
}

@MainActor
final class TabManagerReopenClosedBrowserFocusTests: XCTestCase {
    func testReopenFromDifferentWorkspaceFocusesReopenedBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/ws-switch")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFallsBackToCurrentWorkspaceAndFocusesBrowserWhenOriginalWorkspaceDeleted() {
        let manager = TabManager()
        guard let originalWorkspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/deleted-ws")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(originalWorkspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let currentWorkspace = manager.addWorkspace()
        manager.closeWorkspace(originalWorkspace)

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == originalWorkspace.id }))

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: currentWorkspace))
    }

    func testReopenCollapsedSplitFromDifferentWorkspaceFocusesBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let sourcePanelId = workspace1.focusedPanelId,
              let splitBrowserId = manager.newBrowserSplit(
                tabId: workspace1.id,
                fromPanelId: sourcePanelId,
                orientation: .horizontal,
                insertFirst: false,
                url: URL(string: "https://example.com/collapsed-split")
              ) else {
            XCTFail("Expected to create browser split")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(splitBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFromDifferentWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let preReopenPanelId = workspace1.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-cross-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace1.panels.keys)
        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace1, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace1.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertEqual(workspace1.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace1.panels[reopenedPanelId] is BrowserPanel)
    }

    func testReopenInSameWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let preReopenPanelId = workspace.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-same-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace.panels.keys)
        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(workspace.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace.panels[reopenedPanelId] is BrowserPanel)
    }

    private func isFocusedPanelBrowser(in workspace: Workspace) -> Bool {
        guard let focusedPanelId = workspace.focusedPanelId else { return false }
        return workspace.panels[focusedPanelId] is BrowserPanel
    }

    private func singleNewPanelId(in workspace: Workspace, comparedTo previousPanelIds: Set<UUID>) -> UUID? {
        let newPanelIds = Set(workspace.panels.keys).subtracting(previousPanelIds)
        guard newPanelIds.count == 1 else { return nil }
        return newPanelIds.first
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}

@MainActor
final class WorkspacePanelGitBranchTests: XCTestCase {
    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testBrowserSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(browserSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus browser split to preserve pre-split focus"
        )
    }

    func testTerminalSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let terminalSplitPanel = workspace.newTerminalSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected terminal split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(terminalSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus terminal split to preserve pre-split focus"
        )
    }

    func testBrowserSplitWithFocusFalseRecoversFromDelayedStaleSelection() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }
        guard let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected focused pane for initial panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }
        guard let splitPaneId = workspace.paneId(forPanelId: browserSplitPanel.id),
              let splitTabId = workspace.surfaceIdFromPanelId(browserSplitPanel.id),
              let splitTab = workspace.bonsplitController
              .tabs(inPane: splitPaneId)
              .first(where: { $0.id == splitTabId }) else {
            XCTFail("Expected split pane/tab mapping")
            return
        }

        // Simulate one delayed stale split-selection callback from bonsplit.
        DispatchQueue.main.async {
            workspace.splitTabBar(workspace.bonsplitController, didSelectTab: splitTab, inPane: splitPaneId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus split to reassert the pre-split focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.focusedPaneId,
            originalPaneId,
            "Expected focused pane to converge back to the pre-split pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            workspace.surfaceIdFromPanelId(originalFocusedPanelId),
            "Expected selected tab to converge back to the pre-split focused panel"
        )
    }

    func testBrowserSplitWithFocusFalseAllowsSubsequentExplicitFocusOnSplitPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        workspace.focusPanel(browserSplitPanel.id)

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            browserSplitPanel.id,
            "Expected explicit focus intent to keep the split panel focused"
        )
    }

    func testClosingFocusedSplitRestoresBranchForRemainingFocusedPanel() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)
        guard let secondPanel = workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/bugfix", isDirty: true)
        XCTAssertEqual(workspace.focusedPanelId, secondPanel.id, "Expected split panel to be focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/bugfix")
        XCTAssertEqual(workspace.gitBranch?.isDirty, true)

        XCTAssertTrue(workspace.closePanel(secondPanel.id, force: true), "Expected split panel close to succeed")
        XCTAssertEqual(workspace.focusedPanelId, firstPanelId, "Expected surviving panel to become focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "main")
        XCTAssertEqual(workspace.gitBranch?.isDirty, false)
    }

    func testSidebarGitBranchesFollowLeftToRightSplitOrder() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "main", isDirty: false)
        guard let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "feature/sidebar", isDirty: true)

        let ordered = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(ordered.map(\.branch), ["main", "feature/sidebar"])
        XCTAssertEqual(ordered.map(\.isDirty), [false, true])
    }

    func testSidebarOrderingUsesPaneOrderThenTabOrderWithBranchDeduping() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.newTerminalSplit(from: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.newTerminalSurface(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.newTerminalSurface(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for ordering test")
            return
        }

        XCTAssertTrue(workspace.reorderSurface(panelId: leftFirstPanelId, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: leftSecondPanel.id, toIndex: 1))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightFirstPanel.id, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightSecondPanel.id, toIndex: 1))

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "main", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightSecondPanel.id, branch: "feature/right", isDirty: false)

        XCTAssertEqual(
            workspace.sidebarOrderedPanelIds(),
            [leftFirstPanelId, leftSecondPanel.id, rightFirstPanel.id, rightSecondPanel.id]
        )

        let branches = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(branches.map(\.branch), ["main", "feature/left", "feature/right"])
        XCTAssertEqual(branches.map(\.isDirty), [true, false, false])
    }

    func testClosingPaneDropsBranchesFromClosedSide() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected left/right split panes")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "branch1", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "branch2", isDirty: false)

        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch1", "branch2"])
        XCTAssertTrue(workspace.bonsplitController.closePane(leftPaneId))
        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch2"])
    }
}

@MainActor
final class SidebarBranchOrderingTests: XCTestCase {

    func testWorkspaceCachesDominantRemoteHostKeyUntilPanelsOrFocusChange() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let secondPanel = workspace.newTerminalSurface(inPane: paneId, focus: false) else {
            XCTFail("Expected two local terminal panels")
            return
        }

        guard let initiallyFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected one of the terminal panels to be focused")
            return
        }
        let targetPanelId = initiallyFocusedPanelId == firstPanelId ? secondPanel.id : firstPanelId
        guard let targetTabId = workspace.surfaceIdFromPanelId(targetPanelId) else {
            XCTFail("Expected a Bonsplit tab for the focus target")
            return
        }

        XCTAssertNil(workspace.dominantRemoteHostKey)
        let initialComputationCount = workspace.dominantRemoteHostKeyComputationCount

        XCTAssertNil(workspace.dominantRemoteHostKey)
        XCTAssertEqual(
            workspace.dominantRemoteHostKeyComputationCount,
            initialComputationCount,
            "Selection-only sidebar renders must reuse the host-key snapshot"
        )

        workspace.applyTabSelection(tabId: targetTabId, inPane: paneId)
        XCTAssertEqual(workspace.focusedPanelId, targetPanelId)
        XCTAssertNil(workspace.dominantRemoteHostKey)
        XCTAssertEqual(
            workspace.dominantRemoteHostKeyComputationCount,
            initialComputationCount + 1,
            "Changing the focused panel must recompute the focus-preferred host"
        )

        let panelToRemove = targetPanelId == firstPanelId ? secondPanel.id : firstPanelId
        workspace.panels.removeValue(forKey: panelToRemove)
        XCTAssertNil(workspace.dominantRemoteHostKey)
        XCTAssertEqual(
            workspace.dominantRemoteHostKeyComputationCount,
            initialComputationCount + 2,
            "Changing panel membership must invalidate the fallback-host scan"
        )
    }

    func testWorkspaceCachesBranchDirectoryEntriesUntilAnInputChanges() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial panel")
            return
        }

        workspace.updatePanelDirectory(panelId: panelId, directory: "/repo/one")
        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)

        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(),
            [
                SidebarBranchOrdering.BranchDirectoryEntry(
                    branch: "main",
                    isDirty: false,
                    directory: "/repo/one"
                )
            ]
        )
        XCTAssertEqual(workspace.sidebarBranchDirectoryEntriesComputationCount, 1)

        _ = workspace.sidebarBranchDirectoryEntriesInDisplayOrder()
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesComputationCount,
            1,
            "Selection-only row reevaluations must reuse the workspace snapshot"
        )

        workspace.updatePanelDirectory(panelId: panelId, directory: "/repo/two")
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(),
            [
                SidebarBranchOrdering.BranchDirectoryEntry(
                    branch: "main",
                    isDirty: false,
                    directory: "/repo/two"
                )
            ]
        )
        XCTAssertEqual(workspace.sidebarBranchDirectoryEntriesComputationCount, 2)

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature", isDirty: true)
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(),
            [
                SidebarBranchOrdering.BranchDirectoryEntry(
                    branch: "feature",
                    isDirty: true,
                    directory: "/repo/two"
                )
            ]
        )
        XCTAssertEqual(workspace.sidebarBranchDirectoryEntriesComputationCount, 3)
    }

    func testWorkspaceCachesFormattedBranchDirectoryLines() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial panel")
            return
        }

        workspace.updatePanelDirectory(panelId: panelId, directory: "/repo/one")
        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: true)

        let expected = [
            SidebarBranchOrdering.BranchDirectoryDisplayLine(
                branch: "main*",
                directory: "/repo/one"
            )
        ]
        XCTAssertEqual(workspace.sidebarBranchDirectoryDisplayLines(showGitBranch: true), expected)
        XCTAssertEqual(workspace.sidebarBranchDirectoryDisplayLinesComputationCount, 1)

        XCTAssertEqual(workspace.sidebarBranchDirectoryDisplayLines(showGitBranch: true), expected)
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryDisplayLinesComputationCount,
            1,
            "Repeated row renders must reuse formatted branch/directory lines"
        )

        XCTAssertEqual(
            workspace.sidebarBranchDirectoryDisplayLines(showGitBranch: false),
            [SidebarBranchOrdering.BranchDirectoryDisplayLine(branch: nil, directory: "/repo/one")]
        )
        XCTAssertEqual(workspace.sidebarBranchDirectoryDisplayLinesComputationCount, 2)
    }

    func testReorderingTabsInvalidatesBranchDirectoryDisplayOrder() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let secondPanel = workspace.newTerminalSurface(inPane: paneId, focus: false) else {
            XCTFail("Expected two panels in one pane")
            return
        }

        workspace.updatePanelDirectory(panelId: firstPanelId, directory: "/repo/one")
        workspace.updatePanelDirectory(panelId: secondPanel.id, directory: "/repo/two")
        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "first", isDirty: false)
        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "second", isDirty: false)

        XCTAssertEqual(
            workspace.sidebarBranchDirectoryDisplayLines(showGitBranch: true).map(\.branch),
            ["first", "second"]
        )
        XCTAssertEqual(workspace.sidebarBranchDirectoryEntriesComputationCount, 1)

        XCTAssertTrue(workspace.reorderSurface(panelId: secondPanel.id, toIndex: 0))
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryDisplayLines(showGitBranch: true).map(\.branch),
            ["second", "first"]
        )
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesComputationCount,
            2,
            "A same-pane reorder must invalidate the display-order snapshot"
        )
    }

    func testOrderedUniqueBranchesDedupesByNameAndMergesDirtyState() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let branches = SidebarBranchOrdering.orderedUniqueBranches(
            orderedPanelIds: [first, second, third],
            panelBranches: [
                first: SidebarGitBranchState(branch: "main", isDirty: false),
                second: SidebarGitBranchState(branch: "feature", isDirty: false),
                third: SidebarGitBranchState(branch: "main", isDirty: true)
            ],
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: false)
        )

        XCTAssertEqual(
            branches,
            [
                SidebarBranchOrdering.BranchEntry(name: "main", isDirty: true),
                SidebarBranchOrdering.BranchEntry(name: "feature", isDirty: false)
            ]
        )
    }

    func testOrderedUniqueBranchesUsesFallbackWhenNoPanelBranchesExist() {
        let branches = SidebarBranchOrdering.orderedUniqueBranches(
            orderedPanelIds: [],
            panelBranches: [:],
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: true)
        )

        XCTAssertEqual(
            branches,
            [SidebarBranchOrdering.BranchEntry(name: "fallback", isDirty: true)]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesDedupesPairsAndMergesDirtyState() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let fifth = UUID()

        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [first, second, third, fourth, fifth],
            panelBranches: [
                first: SidebarGitBranchState(branch: "main", isDirty: false),
                second: SidebarGitBranchState(branch: "feature", isDirty: false),
                third: SidebarGitBranchState(branch: "main", isDirty: true),
                fourth: SidebarGitBranchState(branch: "main", isDirty: false)
            ],
            panelDirectories: [
                first: "/repo/a",
                second: "/repo/b",
                third: "/repo/a",
                fourth: "/repo/d",
                fifth: "/repo/e"
            ],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: false)
        )

        XCTAssertEqual(
            rows,
            [
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/a"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "feature", isDirty: false, directory: "/repo/b"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: false, directory: "/repo/d"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: nil, isDirty: false, directory: "/repo/e")
            ]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesUsesFallbackBranchWhenPanelBranchesMissing() {
        let first = UUID()
        let second = UUID()

        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [first, second],
            panelBranches: [:],
            panelDirectories: [
                first: "/repo/one",
                second: "/repo/two"
            ],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "main", isDirty: true)
        )

        XCTAssertEqual(
            rows,
            [
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/one"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/two")
            ]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesFallsBackWhenNoPanelsExist() {
        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [],
            panelBranches: [:],
            panelDirectories: [:],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "main", isDirty: false)
        )

        XCTAssertEqual(
            rows,
            [SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: false, directory: "/repo/default")]
        )
    }
}

@MainActor
final class BrowserPanelAddressBarFocusRequestTests: XCTestCase {
    func testRequestPersistsUntilAcknowledged() {
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        let requestId = panel.requestAddressBarFocus()
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, requestId)
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())

        panel.acknowledgeAddressBarFocusRequest(requestId)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        // Acknowledgement only clears the durable request; focus suppression follows
        // explicit blur state transitions.
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())
        panel.endSuppressWebViewFocusForAddressBar()
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testRequestCoalescesWhilePending() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, firstRequest)
    }

    func testStaleAcknowledgementDoesNotClearNewestRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(secondRequest)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
    }
}

final class SidebarDropPlannerTests: XCTestCase {
    func testNoIndicatorForNoOpEdges() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: first,
                tabIds: tabIds
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: nil,
                tabIds: tabIds
            )
        )
    }

    func testNoIndicatorWhenOnlyOneTabExists() {
        let only = UUID()
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: nil,
                tabIds: [only]
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: only,
                tabIds: [only]
            )
        )
    }

    func testIndicatorAppearsForRealMoveToEnd() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: second,
            targetTabId: nil,
            tabIds: tabIds
        )
        XCTAssertEqual(indicator?.tabId, nil)
        XCTAssertEqual(indicator?.edge, .bottom)
    }

    func testTargetIndexForMoveToEndFromMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let index = SidebarDropPlanner.targetIndex(
            draggedTabId: second,
            targetTabId: nil,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
            tabIds: tabIds
        )
        XCTAssertEqual(index, 2)
    }

    func testNoIndicatorForSelfDropInMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: second,
                targetTabId: second,
                tabIds: tabIds
            )
        )
    }

    func testPointerEdgeTopCanSuppressNoOpWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: second,
                tabIds: tabIds,
                pointerY: 2,
                targetHeight: 40
            )
        )
    }

    func testPointerEdgeBottomAllowsMoveWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: first,
            targetTabId: second,
            tabIds: tabIds,
            pointerY: 38,
            targetHeight: 40
        )
        XCTAssertEqual(indicator?.tabId, third)
        XCTAssertEqual(indicator?.edge, .top)
        XCTAssertEqual(
            SidebarDropPlanner.targetIndex(
                draggedTabId: first,
                targetTabId: second,
                indicator: indicator,
                tabIds: tabIds
            ),
            1
        )
    }

    func testEquivalentBoundaryInputsResolveToSingleCanonicalIndicator() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let fromBottomOfFirst = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: first,
            tabIds: tabIds,
            pointerY: 38,
            targetHeight: 40
        )
        let fromTopOfSecond = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: second,
            tabIds: tabIds,
            pointerY: 2,
            targetHeight: 40
        )

        XCTAssertEqual(fromBottomOfFirst?.tabId, second)
        XCTAssertEqual(fromBottomOfFirst?.edge, .top)
        XCTAssertEqual(fromTopOfSecond?.tabId, second)
        XCTAssertEqual(fromTopOfSecond?.edge, .top)
    }

    func testPointerEdgeBottomSuppressesNoOpWhenDraggingLastOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: second,
                tabIds: tabIds,
                pointerY: 38,
                targetHeight: 40
            )
        )
    }
}

@MainActor
final class SidebarActiveDragLifecycleTests: XCTestCase {
    func testAppResignClearsTheAppWideDragIdentity() async throws {
        let state = SidebarActiveDrag()
        let tabId = UUID()
        state.begin(tabId: tabId)
        XCTAssertEqual(state.tabId, tabId)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(state.tabId)
    }

    func testExplicitEndClearsIdentityAndAllowsANewDrag() {
        let state = SidebarActiveDrag()
        let first = UUID()
        let second = UUID()

        state.begin(tabId: first)
        state.end(reason: "test_cancel")
        XCTAssertNil(state.tabId)

        state.begin(tabId: second)
        XCTAssertEqual(state.tabId, second)
        state.end(reason: "test_cleanup")
    }
}

final class SidebarDragAutoScrollPlannerTests: XCTestCase {
    func testAutoScrollPlanTriggersNearTopAndBottomOnly() {
        let topPlan = SidebarDragAutoScrollPlanner.plan(distanceToTop: 4, distanceToBottom: 96, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(topPlan?.direction, .up)
        XCTAssertNotNil(topPlan)

        let bottomPlan = SidebarDragAutoScrollPlanner.plan(distanceToTop: 96, distanceToBottom: 4, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(bottomPlan?.direction, .down)
        XCTAssertNotNil(bottomPlan)

        XCTAssertNil(
            SidebarDragAutoScrollPlanner.plan(distanceToTop: 60, distanceToBottom: 60, edgeInset: 44, minStep: 2, maxStep: 12)
        )
    }

    func testAutoScrollPlanSpeedsUpCloserToEdge() {
        let nearTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: 1, distanceToBottom: 99, edgeInset: 44, minStep: 2, maxStep: 12)
        let midTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: 22, distanceToBottom: 78, edgeInset: 44, minStep: 2, maxStep: 12)

        XCTAssertNotNil(nearTop)
        XCTAssertNotNil(midTop)
        XCTAssertGreaterThan(nearTop?.pointsPerTick ?? 0, midTop?.pointsPerTick ?? 0)
    }

    func testAutoScrollPlanStillTriggersWhenPointerIsPastEdge() {
        let aboveTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: -500, distanceToBottom: 600, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(aboveTop?.direction, .up)
        XCTAssertEqual(aboveTop?.pointsPerTick, 12)

        let belowBottom = SidebarDragAutoScrollPlanner.plan(distanceToTop: 600, distanceToBottom: -500, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(belowBottom?.direction, .down)
        XCTAssertEqual(belowBottom?.pointsPerTick, 12)
    }
}

final class FinderServicePathResolverTests: XCTestCase {
    func testOrderedUniqueDirectoriesUsesParentForFilesAndDedupes() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/term-mesh-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/term-mesh-services/project/README.md", isDirectory: false),
            URL(fileURLWithPath: "/tmp/term-mesh-services/../term-mesh-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/term-mesh-services/other", isDirectory: true),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/term-mesh-services/project",
                "/tmp/term-mesh-services/other",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesFirstSeenOrder() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/term-mesh-services/b", isDirectory: true),
            URL(fileURLWithPath: "/tmp/term-mesh-services/a/file.txt", isDirectory: false),
            URL(fileURLWithPath: "/tmp/term-mesh-services/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/term-mesh-services/b/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/term-mesh-services/b",
                "/tmp/term-mesh-services/a",
            ]
        )
    }
}

final class TerminalDirectoryOpenTargetAvailabilityTests: XCTestCase {
    private func environment(
        existingPaths: Set<String>,
        homeDirectoryPath: String = "/Users/tester"
    ) -> TerminalDirectoryOpenTarget.DetectionEnvironment {
        TerminalDirectoryOpenTarget.DetectionEnvironment(
            homeDirectoryPath: homeDirectoryPath,
            fileExistsAtPath: { existingPaths.contains($0) }
        )
    }

    func testAvailableTargetsDetectSystemApplications() {
        let env = environment(
            existingPaths: [
                "/Applications/Visual Studio Code.app",
                "/System/Library/CoreServices/Finder.app",
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Zed Preview.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.vscode))
        XCTAssertTrue(availableTargets.contains(.finder))
        XCTAssertTrue(availableTargets.contains(.terminal))
        XCTAssertTrue(availableTargets.contains(.zed))
        XCTAssertFalse(availableTargets.contains(.cursor))
    }

    func testAvailableTargetsFallbackToUserApplications() {
        let env = environment(
            existingPaths: [
                "/Users/tester/Applications/Cursor.app",
                "/Users/tester/Applications/Warp.app",
                "/Users/tester/Applications/Android Studio.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.cursor))
        XCTAssertTrue(availableTargets.contains(.warp))
        XCTAssertTrue(availableTargets.contains(.androidStudio))
        XCTAssertFalse(availableTargets.contains(.vscode))
    }

    func testITerm2DetectsLegacyBundleName() {
        let env = environment(existingPaths: ["/Applications/iTerm.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.iterm2.isAvailable(in: env))
    }

    func testCommandPaletteShortcutsExcludeGenericIDEEntry() {
        let targets = TerminalDirectoryOpenTarget.commandPaletteShortcutTargets
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteTitle == "Open Current Directory in IDE" }))
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteCommandId == "palette.terminalOpenDirectory" }))
    }
}

final class BrowserSearchEngineTests: XCTestCase {
    func testGoogleSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.google.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testDuckDuckGoSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.duckduckgo.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "duckduckgo.com")
        XCTAssertEqual(url.path, "/")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testBingSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.bing.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.bing.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }
}

final class BrowserSearchSettingsTests: XCTestCase {
    func testCurrentSearchSuggestionsEnabledDefaultsToTrueWhenUnset() {
        let suiteName = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertTrue(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))
    }

    func testCurrentSearchSuggestionsEnabledHonorsExplicitValue() {
        let suiteName = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertFalse(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))

        defaults.set(true, forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertTrue(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))
    }
}

final class BrowserHistoryStoreTests: XCTestCase {
    func testRecordVisitDedupesAndSuggests() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL) }

        let u1 = try XCTUnwrap(URL(string: "https://example.com/foo"))
        let u2 = try XCTUnwrap(URL(string: "https://example.com/bar"))

        await MainActor.run {
            store.recordVisit(url: u1, title: "Example Foo")
            store.recordVisit(url: u2, title: "Example Bar")
            store.recordVisit(url: u1, title: "Example Foo Updated")
        }

        let suggestions = await MainActor.run { store.suggestions(for: "foo", limit: 10) }
        XCTAssertEqual(suggestions.first?.url, "https://example.com/foo")
        XCTAssertEqual(suggestions.first?.visitCount, 2)
        XCTAssertEqual(suggestions.first?.title, "Example Foo Updated")
    }

    /// The store loads off the main thread on purpose, so the first query can
    /// legitimately see nothing — `loadIfNeeded` says so in as many words, and
    /// the omnibar re-queries on every keystroke. What has to hold is that the
    /// persisted history does arrive and does produce the right suggestions.
    func testSuggestionsReturnPersistedHistoryOnceItHasLoaded() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let now = Date()
        let seededEntries = [
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://go.dev/",
                title: "The Go Programming Language",
                lastVisited: now,
                visitCount: 3
            ),
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: now.addingTimeInterval(-120),
                visitCount: 2
            ),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(seededEntries)
        try data.write(to: fileURL, options: [.atomic])

        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL) }
        // Kick the load, then wait for it rather than assuming it was synchronous.
        _ = await MainActor.run { store.suggestions(for: "go", limit: 10) }
        var suggestions: [BrowserHistoryStore.Entry] = []
        for _ in 0..<100 {
            suggestions = await MainActor.run { store.suggestions(for: "go", limit: 10) }
            if suggestions.count >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertGreaterThanOrEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.first?.url, "https://go.dev/")
        XCTAssertTrue(suggestions.contains(where: { $0.url == "https://www.google.com/" }))
    }
}

final class OmnibarStateMachineTests: XCTestCase {
    func testEscapeRevertsWhenEditingThenBlursOnSecondEscape() throws {
        var state = OmnibarState()

        var effects = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(effects.shouldSelectAll)

        effects = omnibarReduce(state: &state, event: .bufferChanged("exam"))
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.buffer, "exam")
        XCTAssertTrue(effects.shouldRefreshSuggestions)

        // Simulate an open popup.
        effects = omnibarReduce(
            state: &state,
            event: .suggestionsUpdated([.search(engineName: "Google", query: "exam")])
        )
        XCTAssertEqual(state.suggestions.count, 1)
        XCTAssertFalse(effects.shouldSelectAll)

        // First escape: revert + close popup + select-all.
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(state.suggestions.isEmpty)
        XCTAssertTrue(effects.shouldSelectAll)
        XCTAssertFalse(effects.shouldBlurToWebView)

        // Second escape: blur (since we're not editing and popup is closed).
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertTrue(effects.shouldBlurToWebView)
    }

    func testPanelURLChangeDoesNotClobberUserBufferWhileEditing() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://a.test/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("hello"))
        XCTAssertTrue(state.isUserEditing)

        _ = omnibarReduce(state: &state, event: .panelURLChanged(currentURLString: "https://b.test/"))
        XCTAssertEqual(state.currentURLString, "https://b.test/")
        XCTAssertEqual(state.buffer, "hello")
        XCTAssertTrue(state.isUserEditing)

        let effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://b.test/")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusLostRevertsUnlessSuppressed() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusLostPreserveBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed2"))
        _ = omnibarReduce(state: &state, event: .focusLostRevertBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "https://example.com/")
    }

    func testSuggestionsUpdateKeepsSelectionAcrossNonEmptyListRefresh() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let base: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(base))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 2))
        XCTAssertEqual(state.selectedSuggestionIndex, 2)

        // Simulate remote merge update for the same query while popup remains open.
        let merged: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
            .remoteSearchSuggestion("go fmt"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(merged))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected selection to remain stable while list stays open")
    }

    func testSuggestionsReopenResetsSelectionToFirstRow() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))
        XCTAssertEqual(state.selectedSuggestionIndex, 1)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([]))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 0, "Expected reopened popup to focus first row")
    }

    func testSuggestionsUpdatePrefersAutocompleteMatchWhenSelectionNotTracked() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "gm"),
            .history(url: "https://google.com/", title: "Google"),
            .history(url: "https://gmail.com/", title: "Gmail"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected autocomplete candidate to become selected without explicit index state.")
        XCTAssertEqual(state.selectedSuggestionID, rows[2].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[state.selectedSuggestionIndex]))
        XCTAssertEqual(state.suggestions[state.selectedSuggestionIndex].completion, "https://gmail.com/")
    }
}

final class OmnibarRemoteSuggestionMergeTests: XCTestCase {
    func testMergeRemoteSuggestionsInsertsBelowSearchAndDedupes() {
        let now = Date()
        let entries: [BrowserHistoryStore.Entry] = [
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://go.dev/",
                title: "The Go Programming Language",
                lastVisited: now,
                visitCount: 10
            ),
        ]

        let merged = buildOmnibarSuggestions(
            query: "go",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["go tutorial", "go.dev", "go json"],
            resolvedURL: nil,
            limit: 8
        )

        let completions = merged.compactMap { $0.completion }
        XCTAssertGreaterThanOrEqual(completions.count, 5)
        XCTAssertEqual(completions[0], "https://go.dev/")
        XCTAssertEqual(completions[1], "go")

        let remoteCompletions = Array(completions.dropFirst(2))
        XCTAssertEqual(Set(remoteCompletions), Set(["go tutorial", "go.dev", "go json"]))
        XCTAssertEqual(remoteCompletions.count, 3)
    }

    func testStaleRemoteSuggestionsKeptForNearbyEdits() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "go t",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json", "golang tips"],
            limit: 8
        )

        XCTAssertEqual(stale, ["go tutorial", "go json", "golang tips"])
    }

    func testStaleRemoteSuggestionsTrimAndRespectLimit() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "gooo",
            previousRemoteQuery: "goo",
            previousRemoteSuggestions: [" go tutorial ", "", "go json", "   ", "go fmt"],
            limit: 2
        )

        XCTAssertEqual(stale, ["go tutorial", "go json"])
    }

    func testStaleRemoteSuggestionsDroppedForUnrelatedQuery() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "python",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json"],
            limit: 8
        )

        XCTAssertTrue(stale.isEmpty)
    }
}

final class OmnibarSuggestionRankingTests: XCTestCase {
    private var fixedNow: Date {
        Date(timeIntervalSinceReferenceDate: 10_000_000)
    }

    func testSingleCharacterQueryPromotesAutocompletionMatchToFirstRow() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "n",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["search google for n", "news"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertNotEqual(results.map(\.completion).first, "n")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "n", suggestion: $0) } ?? false)
    }

    func testGmAutocompleteCandidateIsFirstOnExactQueryMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["gmail", "gmail.com", "google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        let inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: "gm",
            suggestions: results,
            isFocused: true,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )
        XCTAssertNotNil(inlineCompletion)
    }

    func testAutocompletionCandidateWinsOverRemoteAndSearchRowsForTwoLetterQuery() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://gmail.com/",
                    title: "Gmail",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com", "Google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
    }

    func testSuggestionSelectionPrefersAutocompletionCandidateAfterSuggestionsUpdate() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        var state = OmnibarState()
        let _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: ""))
        let _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))
        let _ = omnibarReduce(state: &state, event: .suggestionsUpdated(results))

        XCTAssertEqual(state.selectedSuggestionIndex, 0)
        XCTAssertEqual(state.selectedSuggestionID, results[0].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[0]))
    }

    func testTwoCharQueryWithRemoteSuggestionsStillPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "ne",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["netflix", "new york times", "newegg"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // The autocompletable history entry (news.ycombinator.com) should be first despite remote results.
        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "ne", suggestion: $0) } ?? false)

        // Remote suggestions should still appear in the results (two-char queries include them).
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions to be present for two-char query")
    }

    func testGmQueryWithRemoteSuggestionsAndOpenTabPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://google.com/maps",
                    title: "Google Maps",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["gmail login", "gm stock price", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // Gmail should be first (autocompletable + typed history).
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        // Verify remote suggestions are present alongside history/tab matches.
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions in results")
        let hasSearch = results.contains {
            if case .search = $0.kind { return true }
            return false
        }
        XCTAssertTrue(hasSearch, "Expected search row in results")
    }

    func testHistorySuggestionDisplaysTitleAndUrlOnSingleLine() {
        let row = OmnibarSuggestion.history(
            url: "https://www.example.com/path?q=1",
            title: "Example Domain"
        )
        XCTAssertEqual(row.listText, "Example Domain — example.com/path?q=1")
        XCTAssertFalse(row.listText.contains("\n"))
    }

    func testPublishedBufferTextUsesTypedPrefixWhenInlineSuffixIsSelected() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: inline.displayText,
            inlineCompletion: inline,
            selectionRange: inline.suffixRange,
            hasMarkedText: false
        )

        XCTAssertEqual(published, "l")
    }

    func testPublishedBufferTextKeepsUserTypedValueWhenDisplayDiffersFromInlineText() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: "la",
            inlineCompletion: inline,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )

        XCTAssertEqual(published, "la")
    }

    func testInlineCompletionRenderIgnoresStaleTypedPrefixMismatch() {
        let staleInline = OmnibarInlineCompletion(
            typedText: "g",
            displayText: "github.com",
            acceptedText: "https://github.com/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: staleInline
        )

        XCTAssertNil(active)
    }

    func testInlineCompletionRenderKeepsMatchingTypedPrefix() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: inline
        )

        XCTAssertEqual(active, inline)
    }

    func testInlineCompletionSkipsTitleMatchWhoseURLDoesNotStartWithTypedText() {
        // History entry: visited google.com/search?q=localhost:3000 with title
        // "localhost:3000 - Google Search". Typing "l" should NOT inline-complete
        // to "google.com/..." because that replaces the typed "l" with "g".
        let suggestions: [OmnibarSuggestion] = [
            .history(
                url: "https://www.google.com/search?q=localhost:3000",
                title: "localhost:3000 - Google Search"
            ),
        ]

        let result = omnibarInlineCompletionForDisplay(
            typedText: "l",
            suggestions: suggestions,
            isFocused: true,
            selectionRange: NSRange(location: 1, length: 0),
            hasMarkedText: false
        )

        XCTAssertNil(result, "Should not inline-complete when display text does not start with typed prefix")
    }
}

@MainActor
final class NotificationDockBadgeTests: XCTestCase {
    func testDockBadgeLabelEnabledAndCounted() {
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 1, isEnabled: true), "1")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 42, isEnabled: true), "42")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 100, isEnabled: true), "99+")
    }

    func testDockBadgeLabelHiddenWhenDisabledOrZero() {
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true))
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 5, isEnabled: false))
    }

    func testDockBadgeLabelShowsRunTagEvenWithoutUnread() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true, runTag: "verify-tag"),
            "verify-tag"
        )
    }

    func testDockBadgeLabelCombinesRunTagAndUnreadCount() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 7, isEnabled: true, runTag: "verify"),
            "verify:7"
        )
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 120, isEnabled: true, runTag: "verify"),
            "verify:99+"
        )
    }

    func testNotificationBadgePreferenceDefaultsToEnabled() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(false, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertFalse(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(true, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))
    }
}


final class MenuBarBadgeLabelFormatterTests: XCTestCase {
    func testBadgeLabelFormatting() {
        XCTAssertNil(MenuBarBadgeLabelFormatter.badgeText(for: 0))
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 1), "1")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 9), "9")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 10), "9+")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 47), "9+")
    }
}

final class NotificationMenuSnapshotBuilderTests: XCTestCase {
    func testSnapshotCountsUnreadAndLimitsRecentItems() {
        let notifications = (0..<8).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: nil,
                title: "N\(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: index.isMultiple(of: 2)
            )
        }

        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            maxInlineNotificationItems: 3
        )

        XCTAssertEqual(snapshot.unreadCount, 4)
        XCTAssertTrue(snapshot.hasNotifications)
        XCTAssertTrue(snapshot.hasUnreadNotifications)
        XCTAssertEqual(snapshot.recentNotifications.count, 3)
        XCTAssertEqual(snapshot.recentNotifications.map(\.id), Array(notifications.prefix(3)).map(\.id))
    }

    /// Pin the language rather than read the machine's: these are the English
    /// strings, and on a Korean-language Mac the unpinned version asserted them
    /// against 읽지 않은 알림 없음 and failed for a working app.
    func testStateHintTitleHandlesSingularPluralAndZero() throws {
        let suite = "state-hint-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppLanguage.english.rawValue, forKey: LanguageSettings.languageModeKey)

        XCTAssertEqual(
            NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 0, defaults: defaults),
            "No unread notifications"
        )
        XCTAssertEqual(
            NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 1, defaults: defaults),
            "1 unread notification"
        )
        XCTAssertEqual(
            NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 2, defaults: defaults),
            "2 unread notifications"
        )
    }

    /// The Korean side of the same call, for the same reason: a machine set to
    /// English must still be able to prove the Korean strings are reached.
    func testStateHintTitleUsesTheChosenLanguage() throws {
        let suite = "state-hint-ko-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppLanguage.korean.rawValue, forKey: LanguageSettings.languageModeKey)

        let zero = NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 0, defaults: defaults)
        let two = NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 2, defaults: defaults)
        XCTAssertFalse(zero.isEmpty)
        XCTAssertFalse(two.isEmpty)
        XCTAssertNotEqual(zero, two)
        XCTAssertTrue(two.contains("2"), "the count belongs in the localized string too")
    }
}

final class AboutPanelLinkTests: XCTestCase {
    /// These builds are released from x-mesh/term-mesh. The About panel used to
    /// link commits into manaflow-ai/term-mesh, which is upstream of the
    /// Ghostty fork — a hash from here need not exist there at all.
    func testLinksPointAtTheRepositoryThatShipsThisApp() {
        XCTAssertEqual(
            AboutPanelView.commitURL(hash: "abc1234")?.absoluteString,
            "https://github.com/x-mesh/term-mesh/commit/abc1234"
        )
        XCTAssertEqual(
            AboutPanelView.releaseNotesURL(version: "0.182.0")?.absoluteString,
            "https://github.com/x-mesh/term-mesh/releases/tag/v0.182.0"
        )
    }

    /// `CFBundleShortVersionString` is `0.182.0` while the tag is `v0.182.0`.
    func testReleaseNotesTagTakesTheVersionAsGivenOrAddsThePrefix() {
        XCTAssertEqual(
            AboutPanelView.releaseNotesURL(version: "v1.0.0")?.absoluteString,
            "https://github.com/x-mesh/term-mesh/releases/tag/v1.0.0"
        )
        XCTAssertEqual(
            AboutPanelView.releaseNotesURL(version: " 0.9.1 ")?.absoluteString,
            "https://github.com/x-mesh/term-mesh/releases/tag/v0.9.1"
        )
        XCTAssertNil(AboutPanelView.releaseNotesURL(version: "  "))
        XCTAssertNil(AboutPanelView.commitURL(hash: ""))
    }
}

final class MenuBarBuildHintFormatterTests: XCTestCase {
    func testReleaseBuildShowsNoHint() {
        XCTAssertNil(MenuBarBuildHintFormatter.menuTitle(appName: "term-mesh DEV menubar-extra", isDebugBuild: false))
    }

    func testDebugBuildWithTagShowsTag() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "term-mesh DEV menubar-extra", isDebugBuild: true),
            "Build Tag: menubar-extra"
        )
    }

    func testDebugBuildWithoutTagShowsUntagged() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "term-mesh DEV", isDebugBuild: true),
            "Build: DEV (untagged)"
        )
    }
}

final class MenuBarNotificationLineFormatterTests: XCTestCase {
    func testPlainTitleContainsUnreadDotBodyAndTab() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: "workspace-1")
        XCTAssertTrue(line.hasPrefix("● Build finished"))
        XCTAssertTrue(line.contains("All checks passed"))
        XCTAssertTrue(line.contains("workspace-1"))
    }

    func testPlainTitleFallsBackToSubtitleWhenBodyEmpty() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Deploy",
            subtitle: "staging",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: true
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: nil)
        XCTAssertTrue(line.hasPrefix("  Deploy"))
        XCTAssertTrue(line.contains("staging"))
    }

    func testMenuTitleWrapsAndTruncatesToThreeLines() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Extremely long notification title for wrapping behavior validation",
            subtitle: "",
            body: Array(repeating: "this body should wrap and eventually truncate", count: 8).joined(separator: " "),
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "workspace-with-a-very-long-name",
            maxWidth: 120,
            maxLines: 3
        )

        XCTAssertLessThanOrEqual(title.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testMenuTitlePreservesShortTextWithoutEllipsis() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Done",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "w1",
            maxWidth: 320,
            maxLines: 3
        )

        XCTAssertFalse(title.hasSuffix("…"))
    }
}


final class MenuBarIconDebugSettingsTests: XCTestCase {
    func testDisplayedUnreadCountUsesPreviewOverrideWhenEnabled() {
        let suiteName = "MenuBarIconDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MenuBarIconDebugSettings.previewEnabledKey)
        defaults.set(7, forKey: MenuBarIconDebugSettings.previewCountKey)

        XCTAssertEqual(MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: 2, defaults: defaults), 7)
    }

    func testBadgeRenderConfigClampsInvalidValues() {
        let suiteName = "MenuBarIconDebugSettingsTests.Clamp.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-100, forKey: MenuBarIconDebugSettings.badgeRectXKey)
        defaults.set(200, forKey: MenuBarIconDebugSettings.badgeRectYKey)
        defaults.set(-100, forKey: MenuBarIconDebugSettings.singleDigitFontSizeKey)
        defaults.set(100, forKey: MenuBarIconDebugSettings.multiDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.badgeRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(config.badgeRect.origin.y, 20, accuracy: 0.001)
        XCTAssertEqual(config.singleDigitFontSize, 6, accuracy: 0.001)
        XCTAssertEqual(config.multiDigitXAdjust, 4, accuracy: 0.001)
    }

    func testBadgeRenderConfigUsesLegacySingleDigitXAdjustWhenNewKeyMissing() {
        let suiteName = "MenuBarIconDebugSettingsTests.LegacyX.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(2.5, forKey: MenuBarIconDebugSettings.legacySingleDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.singleDigitXAdjust, 2.5, accuracy: 0.001)
    }
}

@MainActor

final class MenuBarIconRendererTests: XCTestCase {
    func testImageWidthDoesNotShiftWhenBadgeAppears() {
        let noBadge = MenuBarIconRenderer.makeImage(unreadCount: 0)
        let withBadge = MenuBarIconRenderer.makeImage(unreadCount: 2)

        XCTAssertEqual(noBadge.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(withBadge.size.width, 18, accuracy: 0.001)
    }
}

final class WorkspaceMountPolicyTests: XCTestCase {
    func testInactiveWorkspaceOpacityKeepsNativeHierarchyWithoutVisiblePixelContribution() {
        XCTAssertGreaterThan(WorkspaceMountPolicy.inactiveWorkspaceOpacity, 0)
        XCTAssertLessThan(WorkspaceMountPolicy.inactiveWorkspaceOpacity, 0.5 / 255.0)
    }

    func testDefaultPolicyKeepsSelectedAndRecentWorkspace() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspaces
        )

        XCTAssertEqual(next, [b, a])
    }

    func testSelectedWorkspaceMovesToFrontAndMountCountIsBounded() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b, c],
            selected: c,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [c, a])
    }

    func testMissingWorkspacesArePruned() {
        let a = UUID()
        let b = UUID()

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [b, a],
            selected: nil,
            pinnedIds: [],
            orderedTabIds: [a],
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [a])
    }

    func testSelectedWorkspaceIsInsertedWhenAbsentFromCurrentCache() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [b, a])
    }

    func testMaxMountedIsClampedToAtLeastOne() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b],
            selected: nil,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 0
        )

        XCTAssertEqual(next, [a])
    }

    func testCycleHotModeKeepsSelectedAndRecentWhenNoPinnedHandoff() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let orderedTabIds: [UUID] = [a, b, c, d]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: c,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
        )

        XCTAssertEqual(next, [c, a])
    }

    func testCycleHotModeRespectsMaxMountedLimit() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b, c],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: 2
        )

        XCTAssertEqual(next, [b, a])
    }

    func testPinnedIdsAreRetainedAcrossReconcile() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: c,
            pinnedIds: [a],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [c, a])
    }

    func testCycleHotModeKeepsRetiringWorkspaceWhenPinned() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [a],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
        )

        XCTAssertEqual(next, [b, a])
    }
}

final class WorkspaceHandoffPolicyTests: XCTestCase {
    func testWarmLocalBrowserFreePairTransitionsImmediately() {
        let old = UUID()
        let new = UUID()

        XCTAssertTrue(WorkspaceHandoffPolicy.canTransitionImmediately(
            oldSelectedId: old,
            newSelectedId: new,
            mountedIds: [old, new],
            oldIsTerminalOnly: true,
            newIsTerminalOnly: true,
            newRendererReady: true,
            oldIsPeerMirror: false,
            newIsPeerMirror: false
        ))
    }

    func testColdTargetRetainsOverlapHandoff() {
        let old = UUID()
        let new = UUID()

        XCTAssertFalse(WorkspaceHandoffPolicy.canTransitionImmediately(
            oldSelectedId: old,
            newSelectedId: new,
            mountedIds: [old],
            oldIsTerminalOnly: true,
            newIsTerminalOnly: true,
            newRendererReady: true,
            oldIsPeerMirror: false,
            newIsPeerMirror: false
        ))
    }

    func testBrowserAndPeerWorkspacesRetainOverlapHandoff() {
        let old = UUID()
        let new = UUID()
        let mounted: Set<UUID> = [old, new]

        XCTAssertFalse(WorkspaceHandoffPolicy.canTransitionImmediately(
            oldSelectedId: old,
            newSelectedId: new,
            mountedIds: mounted,
            oldIsTerminalOnly: false,
            newIsTerminalOnly: true,
            newRendererReady: true,
            oldIsPeerMirror: false,
            newIsPeerMirror: false
        ))
        XCTAssertFalse(WorkspaceHandoffPolicy.canTransitionImmediately(
            oldSelectedId: old,
            newSelectedId: new,
            mountedIds: mounted,
            oldIsTerminalOnly: true,
            newIsTerminalOnly: true,
            newRendererReady: true,
            oldIsPeerMirror: false,
            newIsPeerMirror: true
        ))
    }

    func testUnrealizedWarmTargetRetainsOverlapHandoff() {
        let old = UUID()
        let new = UUID()

        XCTAssertFalse(WorkspaceHandoffPolicy.canTransitionImmediately(
            oldSelectedId: old,
            newSelectedId: new,
            mountedIds: [old, new],
            oldIsTerminalOnly: true,
            newIsTerminalOnly: true,
            newRendererReady: false,
            oldIsPeerMirror: false,
            newIsPeerMirror: false
        ))
    }

    func testWarmImmediateSwitchKeepsStableVisualPriority() {
        XCTAssertEqual(WorkspaceHandoffPolicy.visualPriority(
            isSelected: true,
            isRetiring: false,
            hasOverlap: false
        ), 0)
        XCTAssertEqual(WorkspaceHandoffPolicy.visualPriority(
            isSelected: false,
            isRetiring: false,
            hasOverlap: false
        ), 0)
    }

    func testOverlapHandoffPrioritizesSelectedAboveRetiring() {
        XCTAssertEqual(WorkspaceHandoffPolicy.visualPriority(
            isSelected: true,
            isRetiring: false,
            hasOverlap: true
        ), 2)
        XCTAssertEqual(WorkspaceHandoffPolicy.visualPriority(
            isSelected: false,
            isRetiring: true,
            hasOverlap: true
        ), 1)
        XCTAssertEqual(WorkspaceHandoffPolicy.visualPriority(
            isSelected: false,
            isRetiring: false,
            hasOverlap: true
        ), 0)
    }
}

@MainActor
final class WindowTerminalHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    func testHostViewPassesThroughWhenNoTerminalSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        XCTAssertNil(host.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testHostViewReturnsSubviewWhenSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let child = CapturingView(frame: NSRect(x: 20, y: 15, width: 40, height: 30))
        host.addSubview(child)

        XCTAssertTrue(host.hitTest(NSPoint(x: 25, y: 20)) === child)
        XCTAssertNil(host.hitTest(NSPoint(x: 150, y: 100)))
    }

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Host view must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        XCTAssertTrue(host.hitTest(contentPointInHost) === child)
    }
}

@MainActor
final class WindowBrowserHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowBrowserHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Browser host must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        XCTAssertTrue(host.hitTest(contentPointInHost) === child)
    }
}

@MainActor
final class WindowDragHandleHitTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class HostContainerView: NSView {}
    private final class PassiveHostContainerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            return super.hitTest(point) ?? self
        }
    }

    func testDragHandleCapturesHitWhenNoSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle),
            "Empty titlebar space should drag the window"
        )
    }

    func testDragHandleYieldsWhenSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let folderIconHost = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        container.addSubview(folderIconHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle),
            "Interactive titlebar controls should receive the mouse event"
        )
        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle))
    }

    func testDragHandleIgnoresHiddenSiblingWhenResolvingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let hidden = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        hidden.isHidden = true
        container.addSubview(hidden)

        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle))
    }

    func testDragHandleDoesNotCaptureOutsideBounds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertFalse(windowDragHandleShouldCaptureHit(NSPoint(x: 240, y: 18), in: dragHandle))
    }

    func testPassiveHostingTopHitClassification() {
        XCTAssertTrue(windowDragHandleShouldTreatTopHitAsPassiveHost(HostContainerView(frame: .zero)))
        XCTAssertFalse(windowDragHandleShouldTreatTopHitAsPassiveHost(NSButton(frame: .zero)))
    }

    func testDragHandleIgnoresPassiveHostSiblingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        container.addSubview(passiveHost)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle),
            "Passive host wrappers should not block titlebar drag capture"
        )
    }

    func testDragHandleRespectsInteractiveChildInsidePassiveHost() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        let folderControl = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        passiveHost.addSubview(folderControl)
        container.addSubview(passiveHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle),
            "Interactive controls inside passive host wrappers should still receive hits"
        )
    }
}

@MainActor
final class DraggableFolderHitTests: XCTestCase {
    func testFolderHitTestReturnsContainerWhenInsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        guard let hit = folderView.hitTest(NSPoint(x: 8, y: 8)) else {
            XCTFail("Expected folder icon to capture inside hit")
            return
        }
        XCTAssertTrue(hit === folderView)
    }

    func testFolderHitTestReturnsNilOutsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        XCTAssertNil(folderView.hitTest(NSPoint(x: 20, y: 8)))
    }

    func testFolderIconDisablesWindowMoveBehavior() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertFalse(folderView.mouseDownCanMoveWindow)
    }
}

@MainActor
final class TitlebarLeadingInsetPassthroughViewTests: XCTestCase {
    func testLeadingInsetViewDoesNotParticipateInHitTesting() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 10)))
    }

    func testLeadingInsetViewCannotMoveWindowViaMouseDown() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }
}

@MainActor
final class FolderWindowMoveSuppressionTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func testSuppressionDisablesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = temporarilyDisableWindowDragging(window: window)

        XCTAssertEqual(previous, true)
        XCTAssertFalse(window.isMovable)
    }

    func testSuppressionPreservesAlreadyImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = temporarilyDisableWindowDragging(window: window)

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    func testRestoreAppliesPreviousMovableState() {
        let window = makeWindow()
        window.isMovable = false

        restoreWindowDragging(window: window, previousMovableState: true)
        XCTAssertTrue(window.isMovable)

        restoreWindowDragging(window: window, previousMovableState: false)
        XCTAssertFalse(window.isMovable)
    }

    func testWindowDragSuppressionDepthLifecycle() {
        let window = makeWindow()
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testWindowDragSuppressionIsReferenceCounted() {
        let window = makeWindow()
        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testTemporaryWindowMovableEnableRestoresImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    func testTemporaryWindowMovableEnablePreservesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, true)
        XCTAssertTrue(window.isMovable)
    }
}

@MainActor
final class WindowMoveSuppressionHitPathTests: XCTestCase {
    private func makeWindowWithContentView() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        return (window, contentView)
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func testSuppressionHitPathRecognizesFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: folderView))
    }

    func testSuppressionHitPathRecognizesDescendantOfFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        let child = NSView(frame: .zero)
        folderView.addSubview(child)
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: child))
    }

    func testSuppressionHitPathIgnoresUnrelatedViews() {
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: NSView(frame: .zero)))
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: nil))
    }

    func testSuppressionEventPathRecognizesFolderHitInsideWindow() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        contentView.addSubview(folderView)

        let event = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 14, y: 14), window: window)

        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(window: window, event: event))
    }

    func testSuppressionEventPathRejectsNonFolderAndNonMouseDownEvents() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let plainView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        contentView.addSubview(plainView)

        let down = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: down))

        let dragged = makeMouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: dragged))
    }
}

@MainActor
final class GhosttySurfaceOverlayTests: XCTestCase {
    func testInactiveOverlayVisibilityTracksRequestedState() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        )

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: true)
        var state = hostedView.debugInactiveOverlayState()
        XCTAssertFalse(state.isHidden)
        XCTAssertEqual(state.alpha, 0.35, accuracy: 0.01)

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: false)
        state = hostedView.debugInactiveOverlayState()
        XCTAssertTrue(state.isHidden)
    }

    func testWindowResignKeyClearsFocusedTerminalFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        )
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        hostedView.moveFocus()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to be first responder before window blur"
        )

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Window blur should force terminal surface to resign first responder"
        )
    }

    func testSearchOverlayMountsAndUnmountsWithSearchState() {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        XCTAssertFalse(hostedView.debugHasSearchOverlay())

        let searchState = TerminalSurface.SearchState(needle: "example")
        hostedView.setSearchOverlay(searchState: searchState)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        hostedView.setSearchOverlay(searchState: nil)
        XCTAssertFalse(hostedView.debugHasSearchOverlay())
    }

    func testSearchOverlayMountDoesNotRetainTerminalSurface() {
        weak var weakSurface: TerminalSurface?

        let hostedView: GhosttySurfaceScrollView = {
            let surface = TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil,
                workingDirectory: nil
            )
            weakSurface = surface
            let hostedView = surface.hostedView
            hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "retain-check"))
            return hostedView
        }()

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())
        XCTAssertNil(weakSurface, "Mounted search overlay must not retain TerminalSurface")
    }

    func testSearchOverlaySurvivesPortalRebindDuringSplitLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorA = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 140))
        let anchorB = NSView(frame: NSRect(x: 220, y: 20, width: 180, height: 140))
        contentView.addSubview(anchorA)
        contentView.addSubview(anchorB)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "split"))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorA, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorB, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Split-like anchor churn should not unmount terminal search overlay"
        )
    }

    func testSearchOverlaySurvivesPortalVisibilityToggleDuringWorkspaceSwitchLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 220, height: 160))
        contentView.addSubview(anchor)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "workspace"))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: false)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Workspace-switch-like visibility toggles should not unmount terminal search overlay"
        )
    }
}

@MainActor
final class TerminalWindowPortalLifecycleTests: XCTestCase {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        _ = portal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Portal host must remain above content view so portal-hosted terminals stay visible"
        )
    }

    func testRegistryPrunesPortalWhenWindowCloses() {
        let baseline = TerminalWindowPortalRegistry.debugPortalCount()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        _ = TerminalWindowPortalRegistry.viewAtWindowPoint(NSPoint(x: 1, y: 1), in: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline + 1)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline)
    }

    func testPruneDeadEntriesDetachesAnchorlessHostedView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hosted1 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )

        var anchor1: NSView? = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor1!)
        portal.bind(hostedView: hosted1, to: anchor1!, visibleInUI: true)

        anchor1?.removeFromSuperview()
        anchor1 = nil

        let hosted2 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )
        let anchor2 = NSView(frame: NSRect(x: 180, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor2)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        XCTAssertEqual(portal.debugEntryCount(), 1, "Only the live anchored hosted view should remain tracked")
        XCTAssertEqual(portal.debugHostedSubviewCount(), 1, "Stale anchorless hosted views should be detached from hostView")
    }

    func testTerminalViewAtWindowPointResolvesPortalHostedSurface() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 50, width: 200, height: 120))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let center = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let windowPoint = anchor.convert(center, to: nil)
        XCTAssertNotNil(
            portal.terminalViewAtWindowPoint(windowPoint),
            "Portal hit-testing should resolve the terminal view for Finder file drops"
        )
    }

    func testVisibilityTransitionAtSamePriorityPreservesHostedViewOrder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Latest bind should be top-most before visibility transition"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: false)
        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Visibility-only updates should preserve the established portal z-order"
        )
    }

    func testPriorityIncreaseBringsHostedViewToFrontWithoutVisibilityToggle() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 1)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true, zPriority: 2)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Higher-priority terminal should initially be top-most"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 2)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Promoting z-priority should bring an already-visible terminal to front"
        )
    }

    func testHiddenPortalDefersRevealUntilFrameHasUsableSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let portal = WindowTerminalPortal(window: window)
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 280, height: 220))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        XCTAssertFalse(hosted.isHidden, "Healthy geometry should be visible")

        // Collapse to a tiny frame first.
        anchor.frame = NSRect(x: 160.5, y: 1037.0, width: 79.0, height: 0.0)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(hosted.isHidden, "Tiny geometry should hide the portal-hosted terminal")

        // Then restore to a non-zero but still too-small frame. It should remain hidden.
        anchor.frame = NSRect(x: 160.9, y: 1026.5, width: 93.6, height: 10.3)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(
            hosted.isHidden,
            "Portal should defer reveal until geometry reaches a usable size"
        )

        // Once the frame is large enough again, reveal should resume.
        anchor.frame = NSRect(x: 40, y: 40, width: 180, height: 40)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertFalse(hosted.isHidden, "Portal should unhide after geometry is usable")
    }
}

@MainActor
final class BrowserWindowPortalLifecycleTests: XCTestCase {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowBrowserPortal(window: window)
        _ = portal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Browser portal host must remain above content view so portal-hosted web views stay visible"
        )
    }

    func testAnchorRebindKeepsWebViewInStablePortalSuperview() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        let anchor2 = NSView(frame: NSRect(x: 240, y: 40, width: 180, height: 120))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        let firstSuperview = webView.superview

        XCTAssertNotNil(firstSuperview)
        XCTAssertTrue(firstSuperview is WindowBrowserSlotView)

        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        XCTAssertTrue(webView.superview === firstSuperview, "Anchor moves should not reparent the web view")

        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor2)
        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected browser slot + host views")
            return
        }
        let expectedFrame = host.convert(anchor2.bounds, from: anchor2)
        XCTAssertEqual(slot.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, expectedFrame.size.width, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, expectedFrame.size.height, accuracy: 0.5)
    }

    func testPortalClampsWebViewFrameToHostBoundsWhenAnchorOverflowsSidebar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        // Simulate a transient oversized anchor rect during split churn.
        let anchor = NSView(frame: NSRect(x: 120, y: 20, width: 260, height: 150))
        contentView.addSubview(anchor)

        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected web view slot")
            return
        }

        XCTAssertFalse(slot.isHidden, "Partially visible browser anchor should stay visible")
        XCTAssertEqual(slot.frame.origin.x, 120, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 20, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 150, accuracy: 0.5)
    }

    func testPortalSyncNormalizesOutOfBoundsWebFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 20, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        // Reproduce observed drift from logs where WebKit shifts/expands frame beyond slot bounds.
        webView.frame = NSRect(x: 0, y: 250, width: slot.bounds.width, height: slot.bounds.height)
        XCTAssertGreaterThan(webView.frame.maxY, slot.bounds.maxY)

        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertEqual(webView.frame.origin.x, slot.bounds.origin.x, accuracy: 0.5)
        XCTAssertEqual(webView.frame.origin.y, slot.bounds.origin.y, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.width, slot.bounds.size.width, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.height, slot.bounds.size.height, accuracy: 0.5)
    }

    func testPortalHostBoundsBecomeReadyAfterBindingInFrameDrivenHierarchy() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected portal slot + host views")
            return
        }
        XCTAssertGreaterThan(host.bounds.width, 1, "Portal host width should be ready for clipping/sync")
        XCTAssertGreaterThan(host.bounds.height, 1, "Portal host height should be ready for clipping/sync")
    }

    func testRegistryDetachRemovesPortalHostedWebView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = TermMeshWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        XCTAssertNotNil(webView.superview)

        BrowserWindowPortalRegistry.detach(webView: webView)
        XCTAssertNil(webView.superview)
    }
}

final class BrowserLinkOpenSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BrowserLinkOpenSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTerminalLinksDefaultToCmuxBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowser(defaults: defaults))
    }

    func testTerminalLinksPreferenceUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionDefaultsToCmuxBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInTermMeshBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInTermMeshBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.interceptTerminalOpenCommandInTermMeshBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInTermMeshBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInTermMeshBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionFallsBackToLegacyLinkToggleWhenUnset() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.interceptTerminalOpenCommandInTermMeshBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInTermMeshBrowser(defaults: defaults))
    }

    func testSettingsInitialOpenCommandInterceptionValueFallsBackToLegacyLinkToggleWhenUnset() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInTermMeshBrowserValue(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInTermMeshBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInTermMeshBrowserValue(defaults: defaults))
    }
}

final class TerminalOpenURLTargetResolutionTests: XCTestCase {
    func testResolvesHTTPSAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https://example.com/path?q=1"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/path")
        default:
            XCTFail("Expected web URL to route to embedded browser")
        }
    }

    func testResolvesBareDomainAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("example.com/docs"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/docs")
        default:
            XCTFail("Expected bare domain to be normalized as an HTTPS browser URL")
        }
    }

    func testResolvesFileSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("file:///tmp/term-mesh.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/term-mesh.txt")
        default:
            XCTFail("Expected file URL to open externally")
        }
    }

    func testResolvesAbsolutePathAsExternalFileURL() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("/tmp/term-mesh-path.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/term-mesh-path.txt")
        default:
            XCTFail("Expected absolute file path to open externally")
        }
    }

    func testResolvesNonWebSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("mailto:test@example.com"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "mailto")
        default:
            XCTFail("Expected non-web scheme to open externally")
        }
    }

    func testResolvesHostlessHTTPSAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https:///tmp/term-mesh.txt"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNil(url.host)
            XCTAssertEqual(url.path, "/tmp/term-mesh.txt")
        default:
            XCTFail("Expected hostless HTTPS URL to open externally")
        }
    }
}

final class BrowserExternalNavigationSchemeTests: XCTestCase {
    func testCustomAppSchemesOpenExternally() throws {
        let discord = try XCTUnwrap(URL(string: "discord://login/one-time?token=abc"))
        let slack = try XCTUnwrap(URL(string: "slack://open"))
        let zoom = try XCTUnwrap(URL(string: "zoommtg://zoom.us/join"))
        let mailto = try XCTUnwrap(URL(string: "mailto:test@example.com"))

        XCTAssertTrue(browserShouldOpenURLExternally(discord))
        XCTAssertTrue(browserShouldOpenURLExternally(slack))
        XCTAssertTrue(browserShouldOpenURLExternally(zoom))
        XCTAssertTrue(browserShouldOpenURLExternally(mailto))
    }

    func testEmbeddedBrowserSchemesStayInWebView() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com"))
        let http = try XCTUnwrap(URL(string: "http://example.com"))
        let about = try XCTUnwrap(URL(string: "about:blank"))
        let data = try XCTUnwrap(URL(string: "data:text/plain,hello"))
        let blob = try XCTUnwrap(URL(string: "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"))
        let javascript = try XCTUnwrap(URL(string: "javascript:void(0)"))
        let webkitInternal = try XCTUnwrap(URL(string: "applewebdata://local/page"))

        XCTAssertFalse(browserShouldOpenURLExternally(https))
        XCTAssertFalse(browserShouldOpenURLExternally(http))
        XCTAssertFalse(browserShouldOpenURLExternally(about))
        XCTAssertFalse(browserShouldOpenURLExternally(data))
        XCTAssertFalse(browserShouldOpenURLExternally(blob))
        XCTAssertFalse(browserShouldOpenURLExternally(javascript))
        XCTAssertFalse(browserShouldOpenURLExternally(webkitInternal))
    }
}

final class BrowserHostWhitelistTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BrowserHostWhitelistTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEmptyWhitelistAllowsAll() {
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
    }

    func testExactMatch() {
        defaults.set("localhost\n127.0.0.1", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testExactMatchIsCaseInsensitive() {
        defaults.set("LocalHost", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("LOCALHOST", defaults: defaults))
    }

    func testWildcardSuffix() {
        defaults.set("*.localtest.me", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("app.localtest.me", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("sub.app.localtest.me", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localtest.me", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testWildcardIsCaseInsensitive() {
        defaults.set("*.Example.COM", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("sub.example.com", defaults: defaults))
    }

    func testBlankLinesAndWhitespaceIgnored() {
        defaults.set("  localhost  \n\n  127.0.0.1  \n", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testMixedExactAndWildcard() {
        defaults.set("localhost\n127.0.0.1\n*.local.dev", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("app.local.dev", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("github.com", defaults: defaults))
    }

    func testDefaultWhitelistIsEmpty() {
        let patterns = BrowserLinkOpenSettings.hostWhitelist(defaults: defaults)
        XCTAssertTrue(patterns.isEmpty)
    }

    func testWildcardRequiresDotBoundary() {
        defaults.set("*.example.com", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("badexample.com", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com.evil", defaults: defaults))
    }

    func testWhitelistNormalizesSchemesPortsAndTrailingDots() {
        defaults.set("https://LOCALHOST:3000/path\n*.Example.COM:443", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost.", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("api.example.com", defaults: defaults))
    }

    func testInvalidWhitelistEntriesDoNotImplicitlyAllowAll() {
        defaults.set("http://\n*.\n", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testUnicodeWhitelistEntryMatchesPunycodeHost() {
        defaults.set("b\u{00FC}cher.example", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("xn--bcher-kva.example", defaults: defaults))
    }
}

final class TerminalControllerSidebarDedupeTests: XCTestCase {
    func testShouldReplaceStatusEntryReturnsFalseForUnchangedPayload() {
        let current = SidebarStatusEntry(
            key: "agent",
            value: "idle",
            icon: "bolt",
            color: "#ffffff",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        XCTAssertFalse(
            TerminalController.shouldReplaceStatusEntry(
                current: current,
                key: "agent",
                value: "idle",
                icon: "bolt",
                color: "#ffffff"
            )
        )
    }

    func testShouldReplaceStatusEntryReturnsTrueWhenValueChanges() {
        let current = SidebarStatusEntry(
            key: "agent",
            value: "idle",
            icon: "bolt",
            color: "#ffffff",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        XCTAssertTrue(
            TerminalController.shouldReplaceStatusEntry(
                current: current,
                key: "agent",
                value: "running",
                icon: "bolt",
                color: "#ffffff"
            )
        )
    }

    func testShouldReplaceProgressReturnsFalseForUnchangedPayload() {
        XCTAssertFalse(
            TerminalController.shouldReplaceProgress(
                current: SidebarProgressState(value: 0.42, label: "indexing"),
                value: 0.42,
                label: "indexing"
            )
        )
    }

    func testShouldReplaceGitBranchReturnsFalseForUnchangedPayload() {
        XCTAssertFalse(
            TerminalController.shouldReplaceGitBranch(
                current: SidebarGitBranchState(branch: "main", isDirty: true),
                branch: "main",
                isDirty: true
            )
        )
    }

    func testShouldReplacePortsIgnoresOrderAndDuplicates() {
        XCTAssertFalse(
            TerminalController.shouldReplacePorts(
                current: [9229, 3000],
                next: [3000, 9229, 3000]
            )
        )
        XCTAssertTrue(
            TerminalController.shouldReplacePorts(
                current: [9229, 3000],
                next: [3000]
            )
        )
    }

    func testExplicitSocketScopeParsesValidUUIDTabAndPanel() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(
            options: [
                "tab": workspaceId.uuidString,
                "panel": panelId.uuidString
            ]
        )
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeAcceptsSurfaceAlias() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(
            options: [
                "tab": workspaceId.uuidString,
                "surface": panelId.uuidString
            ]
        )
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeRejectsMissingOrInvalidValues() {
        XCTAssertNil(TerminalController.explicitSocketScope(options: [:]))
        XCTAssertNil(TerminalController.explicitSocketScope(options: ["tab": "workspace:1", "panel": UUID().uuidString]))
        XCTAssertNil(TerminalController.explicitSocketScope(options: ["tab": UUID().uuidString, "panel": "surface:1"]))
    }

    func testNormalizeReportedDirectoryTrimsWhitespace() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("   /Users/jinwoo/term-mesh/project   "),
            "/Users/jinwoo/term-mesh/project"
        )
    }

    func testNormalizeReportedDirectoryResolvesFileURL() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("file:///Users/jinwoo/term-mesh/project"),
            "/Users/jinwoo/term-mesh/project"
        )
    }

    func testNormalizeReportedDirectoryLeavesInvalidURLTrimmed() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("  file://bad host  "),
            "file://bad host"
        )
    }
}

@MainActor
final class SidebarNotificationSummaryTests: XCTestCase {
    func testSummariesCountUnreadAndPreferLatestUnreadText() {
        let workspace = UUID()
        let notifications = [
            notification(workspace: workspace, title: "Newest read", body: "", isRead: true),
            notification(workspace: workspace, title: "Unread title", body: "  Unread body  ", isRead: false),
            notification(workspace: workspace, title: "Older unread", body: "", isRead: false),
        ]

        let summary = TerminalNotificationStore.makeSidebarSummaries(from: notifications)[workspace]

        XCTAssertEqual(summary?.unreadCount, 2)
        XCTAssertEqual(summary?.displayText, "Unread body")
    }

    func testSummariesUseLatestReadTextAndIgnoreWhitespaceOnlyText() {
        let workspace = UUID()
        let emptyWorkspace = UUID()
        let notifications = [
            notification(workspace: workspace, title: "Latest title", body: "", isRead: true),
            notification(workspace: workspace, title: "Older title", body: "Older body", isRead: true),
            notification(workspace: emptyWorkspace, title: "  ", body: "  ", isRead: false),
        ]

        let summaries = TerminalNotificationStore.makeSidebarSummaries(from: notifications)

        XCTAssertEqual(summaries[workspace]?.unreadCount, 0)
        XCTAssertEqual(summaries[workspace]?.displayText, "Latest title")
        XCTAssertEqual(summaries[emptyWorkspace]?.unreadCount, 1)
        XCTAssertNil(summaries[emptyWorkspace]?.displayText)
    }

    private func notification(
        workspace: UUID,
        title: String,
        body: String,
        isRead: Bool
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: workspace,
            surfaceId: nil,
            title: title,
            subtitle: "",
            body: body,
            createdAt: Date(),
            isRead: isRead
        )
    }
}

final class TerminalControllerRemoteAgentAddTests: XCTestCase {
    private let hosts = [
        (key: "ssh:root@jw-server", displayName: "Build Server", sshTarget: Optional("root@jw-server"))
    ]

    func testHostResolutionAcceptsKeyDisplayNameFullTargetAndHostname() {
        for input in ["ssh:root@jw-server", "build server", "root@jw-server", "jw-server"] {
            XCTAssertEqual(
                TerminalController.remoteAgentHostKey(for: input, candidates: hosts),
                "ssh:root@jw-server"
            )
        }
    }

    func testHostResolutionRejectsUnknownName() {
        XCTAssertNil(TerminalController.remoteAgentHostKey(for: "other", candidates: hosts))
    }

    func testUnknownHostErrorListsUsableConnectedKeys() {
        XCTAssertEqual(
            TerminalController.remoteAgentHostNotFoundMessage(
                input: "other",
                connectedKeys: ["ssh:root@jw-server", "ssh:builder@mac-mini"]
            ),
            "no connected host named other; connected host keys: "
                + "ssh:root@jw-server, ssh:builder@mac-mini"
        )
    }

    func testRemoteAgentResponseUsesActualCheckoutAndReportsReuse() {
        let isolated = TerminalController.remoteAgentResponseWorkingDirectory(
            requested: "/app/tm-projects/term-mesh-reviewer-260729-c741",
            memberWorkingDirectory: "/app/tm-projects/term-mesh-fixer-260729-b4c7"
        )
        XCTAssertEqual(isolated.directory, "/app/tm-projects/term-mesh-fixer-260729-b4c7")
        XCTAssertFalse(isolated.reused)

        let reused = TerminalController.remoteAgentResponseWorkingDirectory(
            requested: "/app/tm-projects/term-mesh-reviewer-260729-c741",
            memberWorkingDirectory: nil
        )
        XCTAssertEqual(reused.directory, "/app/tm-projects/term-mesh-reviewer-260729-c741")
        XCTAssertTrue(reused.reused)
    }
}

final class TerminalControllerSocketTextChunkTests: XCTestCase {
    func testQueuedTextForNamedKeyMapsControlKeys() {
        XCTAssertEqual(TerminalController.queuedTextForNamedKey("ctrl-d"), "\u{04}")
        XCTAssertEqual(TerminalController.queuedTextForNamedKey("EOF"), "\u{04}")
        XCTAssertEqual(TerminalController.queuedTextForNamedKey("ctrl-a"), "\u{01}")
        XCTAssertEqual(TerminalController.queuedTextForNamedKey("return"), "\r")
        XCTAssertNil(TerminalController.queuedTextForNamedKey("left"))
    }

    func testSocketTextChunksReturnsSingleChunkForPlainText() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("echo hello"),
            [.text("echo hello")]
        )
    }

    func testSocketTextChunksSplitsControlScalars() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("abc\rdef\tghi"),
            [
                .text("abc"),
                .control("\r".unicodeScalars.first!),
                .text("def"),
                .control("\t".unicodeScalars.first!),
                .text("ghi")
            ]
        )
    }

    func testSocketTextChunksDoesNotEmitEmptyTextChunksAroundConsecutiveControls() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("\r\n\t"),
            [
                .control("\r".unicodeScalars.first!),
                .control("\n".unicodeScalars.first!),
                .control("\t".unicodeScalars.first!)
            ]
        )
    }
}

/// Which named theme ghostty is handed, and who decides between light and dark.
///
/// A `light:…,dark:…` pair lets ghostty choose, and it chooses by the *system*
/// appearance. So on a Mac set to Light with term-mesh set to Dark — the exact
/// case the Light/Dark setting exists for — the chrome went dark and the
/// terminal stayed light. `TerminalThemeOverride` deletes itself whenever a
/// named theme exists, so nothing was left to force the choice.
final class TerminalThemeLineTests: XCTestCase {

    func testAnExplicitDarkModePinsTheDarkThemeRatherThanHandingOverThePair() {
        XCTAssertEqual(
            TerminalSettingsOverride.themeLine(light: "Light Owl", dark: "Mathias", mode: .dark),
            "theme = Mathias"
        )
    }

    func testAnExplicitLightModePinsTheLightTheme() {
        XCTAssertEqual(
            TerminalSettingsOverride.themeLine(light: "Light Owl", dark: "Mathias", mode: .light),
            "theme = Light Owl"
        )
    }

    /// System mode is the one case where deferring to the system is the ask.
    func testSystemModeStillHandsOverBothHalves() {
        XCTAssertEqual(
            TerminalSettingsOverride.themeLine(light: "Light Owl", dark: "Mathias", mode: .system),
            "theme = light:Light Owl,dark:Mathias"
        )
        XCTAssertEqual(
            TerminalSettingsOverride.themeLine(light: "Light Owl", dark: "Mathias", mode: .auto),
            "theme = light:Light Owl,dark:Mathias"
        )
    }

    /// Setting only one half means that theme in every mode, not a half-empty pair.
    func testOneHalfSetIsUsedForBothModes() {
        XCTAssertEqual(
            TerminalSettingsOverride.themeLine(light: "", dark: "Mathias", mode: .light),
            "theme = Mathias"
        )
        XCTAssertEqual(
            TerminalSettingsOverride.themeLine(light: "Light Owl", dark: "", mode: .dark),
            "theme = Light Owl"
        )
        XCTAssertEqual(
            TerminalSettingsOverride.themeLine(light: "", dark: "Mathias", mode: .system),
            "theme = light:Mathias,dark:Mathias"
        )
    }

    /// No named theme means no line at all — the hardcoded palettes in
    /// `TerminalThemeOverride` take over, which is what its deletion branch assumes.
    func testNoNamedThemeWritesNoThemeLine() {
        XCTAssertNil(TerminalSettingsOverride.themeLine(light: "", dark: "", mode: .dark))
        XCTAssertNil(TerminalSettingsOverride.themeLine(light: "", dark: "", mode: .system))
    }
}
