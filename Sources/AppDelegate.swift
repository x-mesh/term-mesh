import AppKit
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {
    static var shared: AppDelegate?

    func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        // On some macOS/Xcode setups, the app-under-test process doesn't get
        // `XCTestConfigurationFilePath`. Use a broader set of signals so UI tests
        // can reliably skip heavyweight startup work and bring up a window.
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCInjectBundle"] != nil { return true }
        if env["XCInjectBundleInto"] != nil { return true }
        if env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if env.keys.contains(where: { $0.hasPrefix("TERMMESH_UI_TEST_") || $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }

    final class MainWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let sidebarState: SidebarState
        let sidebarSelectionState: SidebarSelectionState
        weak var window: NSWindow?

        init(
            windowId: UUID,
            tabManager: TabManager,
            sidebarState: SidebarState,
            sidebarSelectionState: SidebarSelectionState,
            window: NSWindow?
        ) {
            self.windowId = windowId
            self.tabManager = tabManager
            self.sidebarState = sidebarState
            self.sidebarSelectionState = sidebarSelectionState
            self.window = window
        }
    }

    final class MainWindowController: NSWindowController, NSWindowDelegate {
        var onClose: (() -> Void)?

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }

    weak var tabManager: TabManager?
    /// Injected daemon service (defaults to singleton for backward compatibility).
    var daemon: any DaemonService = TermMeshDaemon.shared
    /// Injected config provider (defaults to singleton for backward compatibility).
    var configProvider: any GhosttyConfigProvider = GhosttyApp.shared
    /// Injected browser history service (defaults to singleton for backward compatibility).
    var browserHistory: any BrowserHistoryService = BrowserHistoryStore.shared
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?
    weak var fullscreenControlsViewModel: TitlebarControlsViewModel?
    weak var sidebarSelectionState: SidebarSelectionState?
    var workspaceObserver: NSObjectProtocol?
    var windowKeyObserver: NSObjectProtocol?
    var shortcutMonitor: Any?
    var shortcutDefaultsObserver: NSObjectProtocol?
    var splitButtonTooltipRefreshScheduled = false
    var ghosttyConfigObserver: NSObjectProtocol?
    var ghosttyGotoSplitLeftShortcut: StoredShortcut?
    var ghosttyGotoSplitRightShortcut: StoredShortcut?
    var ghosttyGotoSplitUpShortcut: StoredShortcut?
    var ghosttyGotoSplitDownShortcut: StoredShortcut?
    var browserAddressBarFocusedPanelId: UUID?
    var browserOmnibarRepeatStartWorkItem: DispatchWorkItem?
    var browserOmnibarRepeatTickWorkItem: DispatchWorkItem?
    var browserOmnibarRepeatKeyCode: UInt16?
    var browserOmnibarRepeatDelta: Int = 0
    var browserAddressBarFocusObserver: NSObjectProtocol?
    var browserAddressBarBlurObserver: NSObjectProtocol?
    let updateController = UpdateController()
    private lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(viewModel: updateViewModel)
    let windowDecorationsController = WindowDecorationsController()
    var menuBarExtraController: MenuBarExtraController?
    static let serviceErrorNoPath = NSString(string: "Could not load any folder path from the clipboard.")
    static let didInstallWindowKeyEquivalentSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.performKeyEquivalent(with:))
        let swizzledSelector = #selector(NSWindow.termMesh_performKeyEquivalent(with:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    static let didInstallWindowFirstResponderSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.makeFirstResponder(_:))
        let swizzledSelector = #selector(NSWindow.termMesh_makeFirstResponder(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    static let didInstallWindowSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.sendEvent(_:))
        let swizzledSelector = #selector(NSWindow.termMesh_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

#if DEBUG
    var didSetupJumpUnreadUITest = false
    var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
    var jumpUnreadFocusObserver: NSObjectProtocol?
    var didSetupGotoSplitUITest = false
    var gotoSplitUITestObservers: [NSObjectProtocol] = []
    var didSetupMultiWindowNotificationsUITest = false

    func childExitKeyboardProbePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] ?? env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"]) == "1",
              let path = (env["TERMMESH_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] ?? env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"]),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    func childExitKeyboardProbeHex(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }

    func writeChildExitKeyboardProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = childExitKeyboardProbePath() else { return }
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, by) in increments {
            let current = Int(payload[key] ?? "") ?? 0
            payload[key] = String(current + by)
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
#endif

    var mainWindowContexts: [ObjectIdentifier: MainWindowContext] = [:]
    var mainWindowControllers: [MainWindowController] = []
    var commandPaletteVisibilityByWindowId: [UUID: Bool] = [:]
    var commandPaletteSelectionByWindowId: [UUID: Int] = [:]
    var commandPaletteSnapshotByWindowId: [UUID: CommandPaletteDebugSnapshot] = [:]

    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

    override init() {
        super.init()
        Self.shared = self

        // Override process name to use branded "Term-Mesh" instead of the
        // lowercase executable name ("term-mesh DEV" / "term-mesh").
        // Must be set before SwiftUI creates the app menu.
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String {
            ProcessInfo.processInfo.processName = displayName
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

#if DEBUG
        // UI tests run on a shared VM user profile, so persisted shortcuts can drift and make
        // key-equivalent routing flaky. Force defaults for deterministic tests.
        if isRunningUnderXCTest {
            KeyboardShortcutSettings.resetAll()
        }
#endif

#if DEBUG
        writeUITestDiagnosticsIfNeeded(stage: "didFinishLaunching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeUITestDiagnosticsIfNeeded(stage: "after1s")
        }
#endif

        SentrySDK.start { options in
            options.dsn = "https://e82b8ec104bf1557bb560b17cc3829d5@o406458.ingest.us.sentry.io/4511020180963328"
            #if DEBUG
            options.environment = "development"
            options.debug = true
            #else
            options.environment = "production"
            options.debug = false
            #endif
            options.sendDefaultPii = true

            // Performance tracing (10% of transactions)
            options.tracesSampleRate = 0.1
            // App hang timeout (default is 2s, be explicit)
            options.appHangTimeoutInterval = 2.0
            // Attach stack traces to all events
            options.attachStacktrace = true
            // Capture failed HTTP requests
            options.enableCaptureFailedRequests = true
        }

        if !isRunningUnderXCTest {
            PostHogAnalytics.shared.startIfNeeded()
        }

        // UI tests frequently time out waiting for the main window if we do heavyweight
        // LaunchServices registration / single-instance enforcement synchronously at startup.
        // Skip these during XCTest (the app-under-test) so the window can appear quickly.
        if !isRunningUnderXCTest {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.registerLaunchServicesBundle()
                self.enforceSingleInstance()
                self.observeDuplicateLaunches()
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        // Disable macOS window state restoration. We manage our own session
        // restore via TabManager/SessionRestoreSettings. Without this, macOS
        // can recreate previously-open NSWindows on launch, producing ghost
        // duplicates that share the SwiftUI WindowGroup's tabManager.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        disableNativeTabbingShortcut()
        ensureApplicationIcon()
        if !isRunningUnderXCTest {
            configureUserNotifications()
            setupMenuBarExtra()
            // Sparkle updater is started lazily on first manual check. This avoids any
            // first-launch permission prompts and keeps term-mesh aligned with the update pill UI.
        }
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installMainWindowKeyObserver()
        refreshGhosttyGotoSplitShortcuts()
        installGhosttyConfigObserver()
        installWindowResponderSwizzles()
        installBrowserAddressBarFocusObservers()
        installShortcutMonitor()
        installShortcutDefaultsObserver()
        NSApp.servicesProvider = self

        // term-mesh: Start the background daemon
        if !isRunningUnderXCTest {
            daemon.startDaemon()
        }
#if DEBUG
        UpdateTestSupport.applyIfNeeded(to: updateController.viewModel)
        if (env["TERMMESH_UI_TEST_MODE"] ?? env["CMUX_UI_TEST_MODE"]) == "1" {
            let trigger = (env["TERMMESH_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"]) ?? "<nil>"
            let feed = (env["TERMMESH_UI_TEST_FEED_URL"] ?? env["CMUX_UI_TEST_FEED_URL"]) ?? "<nil>"
            UpdateLogStore.shared.append("ui test env: trigger=\(trigger) feed=\(feed)")
        }
        if (env["TERMMESH_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"]) == "1" {
            UpdateLogStore.shared.append("ui test trigger update check detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                let windowIds = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                UpdateLogStore.shared.append("ui test windows: count=\(NSApp.windows.count) ids=\(windowIds.joined(separator: ","))")
                if UpdateTestSupport.performMockFeedCheckIfNeeded(on: self.updateController.viewModel) {
                    return
                }
                self.checkForUpdates(nil)
            }
        }

        // In UI tests, `WindowGroup` occasionally fails to materialize a window quickly on the VM.
        // If there are no windows shortly after launch, force-create one so XCUITest can proceed.
        if isRunningUnderXCTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if NSApp.windows.isEmpty {
                    self.openNewMainWindow(nil)
                }
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                self.writeUITestDiagnosticsIfNeeded(stage: "afterForceWindow")
            }
        }
#endif
    }

#if DEBUG
    func writeUITestDiagnosticsIfNeeded(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = (env["TERMMESH_UI_TEST_DIAGNOSTICS_PATH"] ?? env["CMUX_UI_TEST_DIAGNOSTICS_PATH"]), !path.isEmpty else { return }

        var payload = loadUITestDiagnostics(at: path)
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

        let windows = NSApp.windows
        let ids = windows.map { $0.identifier?.rawValue ?? "" }.joined(separator: ",")
        let vis = windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")

        payload["stage"] = stage
        payload["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        payload["bundleId"] = Bundle.main.bundleIdentifier ?? ""
        payload["isRunningUnderXCTest"] = isRunningUnderXCTest ? "1" : "0"
        payload["windowsCount"] = String(windows.count)
        payload["windowIdentifiers"] = ids
        payload["windowVisibleFlags"] = vis

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func loadUITestDiagnostics(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
#endif

    // Prevent dock-click from creating a new SwiftUI WindowGroup window.
    // Instead, activate the existing main window. This prevents duplicate
    // windows that share the same @StateObject tabManager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            // Already have visible windows — just activate them
            return false
        }
        // No visible windows: show the most recent main window instead of
        // letting SwiftUI WindowGroup create a duplicate scene.
        if let window = mainWindowContexts.values.compactMap(\.window).first {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        // No existing window at all — allow the system to create one
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        sentryBreadcrumb("app.didBecomeActive", category: "lifecycle", data: [
            "tabCount": tabManager?.tabs.count ?? 0
        ])
        let env = ProcessInfo.processInfo.environment
        if !isRunningUnderXCTest(env) {
            PostHogAnalytics.shared.trackDailyActive(reason: "didBecomeActive")
        }

        guard let tabManager, let notificationStore else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    func applicationWillTerminate(_ notification: Notification) {
        tabManager?.saveSessionState()
        TerminalController.shared.stop()
        // Worktree auto-cleanup disabled — worktrees are managed explicitly via Worktree Manager
        daemon.stopDaemon()
        browserHistory.flushPendingSaves()
        PostHogAnalytics.shared.flush()
        notificationStore?.clearAll()
    }

    func configure(tabManager: TabManager, notificationStore: TerminalNotificationStore, sidebarState: SidebarState) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        DashboardController.shared.tabManager = tabManager
#if DEBUG
        setupJumpUnreadUITestIfNeeded()
        setupGotoSplitUITestIfNeeded()
        setupMultiWindowNotificationsUITestIfNeeded()

        // UI tests sometimes don't run SwiftUI `.onAppear` soon enough (or at all) on the VM.
        // The automation socket is a core testing primitive, so ensure it's started here when
        // we detect XCTest, even if the main view lifecycle is flaky.
        let env = ProcessInfo.processInfo.environment
        if isRunningUnderXCTest(env) {
            let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
                ?? SocketControlSettings.defaultMode.rawValue
            let userMode = SocketControlSettings.migrateMode(raw)
            let mode = SocketControlSettings.effectiveMode(userMode: userMode)
            if mode != .off {
                TerminalController.shared.start(
                    tabManager: tabManager,
                    socketPath: SocketControlSettings.socketPath(),
                    accessMode: mode
                )
            }
        }
#endif
    }

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState
    ) {
        let key = ObjectIdentifier(window)
        #if DEBUG
        let priorManagerToken = debugManagerToken(self.tabManager)
        #endif
        if let existing = mainWindowContexts[key] {
            existing.window = window
        } else {
            mainWindowContexts[key] = MainWindowContext(
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                window: window
            )
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let self, let closing = note.object as? NSWindow else { return }
                self.unregisterMainWindow(closing)
            }
        }
        commandPaletteVisibilityByWindowId[windowId] = false
        commandPaletteSelectionByWindowId[windowId] = 0
        commandPaletteSnapshotByWindowId[windowId] = .empty

#if DEBUG
        dlog(
            "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(priorManagerToken) \(debugShortcutRouteSnapshot())"
        )
#endif
        if window.isKeyWindow {
            setActiveMainWindow(window)
        }
    }

    struct MainWindowSummary {
        let windowId: UUID
        let isKeyWindow: Bool
        let isVisible: Bool
        let workspaceCount: Int
        let selectedWorkspaceId: UUID?
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        let contexts = Array(mainWindowContexts.values)
        return contexts.map { ctx in
            let window = ctx.window ?? windowForMainWindowId(ctx.windowId)
            return MainWindowSummary(
                windowId: ctx.windowId,
                isKeyWindow: window?.isKeyWindow ?? false,
                isVisible: window?.isVisible ?? false,
                workspaceCount: ctx.tabManager.tabs.count,
                selectedWorkspaceId: ctx.tabManager.selectedTabId
            )
        }
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.tabManager
    }

    func tabManagerFor(tabId: UUID) -> TabManager? {
        mainWindowContexts.values.first(where: { ctx in
            ctx.tabManager.tabs.contains(where: { $0.id == tabId })
        })?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId
    }

    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    func setCommandPaletteVisible(_ visible: Bool, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteVisibilityByWindowId[windowId] = visible
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func setCommandPaletteSelectionIndex(_ index: Int, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSelectionByWindowId[windowId] = max(0, index)
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        commandPaletteSelectionByWindowId[windowId] ?? 0
    }

    func setCommandPaletteSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSnapshotByWindowId[windowId] = snapshot
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        commandPaletteSnapshotByWindowId[windowId] ?? .empty
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
        window: NSWindow,
        responder: NSResponder?
    ) -> Bool {
        guard isCommandPaletteVisible(for: window) else { return false }
        guard let responder else { return false }
        guard !isCommandPaletteResponder(responder) else { return false }
        return isFocusStealingResponderWhileCommandPaletteVisible(responder)
    }

    func isCommandPaletteResponder(_ responder: NSResponder) -> Bool {
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let delegateView = textView.delegate as? NSView {
                return isInsideCommandPaletteOverlay(delegateView)
            }
            // SwiftUI can attach a non-view delegate to TextField editors.
            // When command palette is visible, its search/rename editor is the
            // only expected field editor inside the main window.
            return true
        }
        if let view = responder as? NSView {
            return isInsideCommandPaletteOverlay(view)
        }
        return false
    }

    func isFocusStealingResponderWhileCommandPaletteVisible(_ responder: NSResponder) -> Bool {
        if responder is GhosttyNSView || responder is WKWebView {
            return true
        }

        if let textView = responder as? NSTextView,
           !textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView {
            return isTerminalOrBrowserView(delegateView)
        }

        if let view = responder as? NSView {
            return isTerminalOrBrowserView(view)
        }

        return false
    }

    func isTerminalOrBrowserView(_ view: NSView) -> Bool {
        if view is GhosttyNSView || view is WKWebView {
            return true
        }
        var current: NSView? = view.superview
        while let candidate = current {
            if candidate is GhosttyNSView || candidate is WKWebView {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    func isInsideCommandPaletteOverlay(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                if ws.panels[surfaceId] != nil {
                    return (ctx.windowId, ws.id, ctx.tabManager)
                }
            }
        }
        return nil
    }

    func locateGhosttySurface(_ surface: ghostty_surface_t?) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        guard let surface else { return nil }
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                for (panelId, panel) in ws.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    if terminal.surface.surface == surface {
                        return (ctx.windowId, ws.id, panelId, ctx.tabManager)
                    }
                }
            }
        }
        return nil
    }

    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        if TerminalController.shouldSuppressSocketCommandActivation() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if TerminalController.socketCommandAllowsInAppFocusMutations() {
                window.orderFront(nil)
                setActiveMainWindow(window)
            }
            return true
        }
        bringToFront(window)
        return true
    }

    func closeMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        window.performClose(nil)
        return true
    }

    func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let ctx = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = ctx.window {
            return window
        }
        let expectedIdentifier = "term-mesh.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    func mainWindowId(for window: NSWindow) -> UUID? {
        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            return context.windowId
        }
        guard let rawIdentifier = window.identifier?.rawValue,
              rawIdentifier.hasPrefix("term-mesh.main.") else { return nil }
        let idPart = String(rawIdentifier.dropFirst("term-mesh.main.".count))
        return UUID(uuidString: idPart)
    }

    func activeCommandPaletteWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow,
           let windowId = mainWindowId(for: keyWindow),
           commandPaletteVisibilityByWindowId[windowId] == true {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           let windowId = mainWindowId(for: mainWindow),
           commandPaletteVisibilityByWindowId[windowId] == true {
            return mainWindow
        }
        if let visibleWindowId = commandPaletteVisibilityByWindowId.first(where: { $0.value })?.key {
            return windowForMainWindowId(visibleWindowId)
        }
        return nil
    }

    func contextForMainWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window, isMainTerminalWindow(window) else { return nil }
        return mainWindowContexts[ObjectIdentifier(window)]
    }

#if DEBUG
    func debugManagerToken(_ manager: TabManager?) -> String {
        guard let manager else { return "nil" }
        return String(describing: Unmanaged.passUnretained(manager).toOpaque())
    }

    func debugWindowToken(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let id = mainWindowId(for: window).map { String($0.uuidString.prefix(8)) } ?? "none"
        let ident = window.identifier?.rawValue ?? "nil"
        let shortIdent: String
        if ident.count > 120 {
            shortIdent = String(ident.prefix(120)) + "..."
        } else {
            shortIdent = ident
        }
        return "num=\(window.windowNumber) id=\(id) ident=\(shortIdent) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
    }

    func debugContextToken(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let hasWindow = (context.window != nil || windowForMainWindowId(context.windowId) != nil) ? 1 : 0
        return "id=\(String(context.windowId.uuidString.prefix(8))) mgr=\(debugManagerToken(context.tabManager)) tabs=\(context.tabManager.tabs.count) selected=\(selected) hasWindow=\(hasWindow)"
    }

    func debugShortcutRouteSnapshot(event: NSEvent? = nil) -> String {
        let activeManager = tabManager
        let activeWindowId = activeManager.flatMap { windowId(for: $0) }.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let selectedWorkspace = activeManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"

        let contexts = mainWindowContexts.values
            .map { context in
                let marker = (activeManager != nil && context.tabManager === activeManager) ? "*" : "-"
                let window = context.window ?? windowForMainWindowId(context.windowId)
                let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                return "\(marker)\(String(context.windowId.uuidString.prefix(8))){mgr=\(debugManagerToken(context.tabManager)),win=\(window?.windowNumber ?? -1),key=\((window?.isKeyWindow ?? false) ? 1 : 0),main=\((window?.isMainWindow ?? false) ? 1 : 0),tabs=\(context.tabManager.tabs.count),selected=\(selected)}"
            }
            .sorted()
            .joined(separator: ",")

        let eventWindowNumber = event.map { String($0.windowNumber) } ?? "nil"
        let eventWindow = event?.window
        return "eventWinNum=\(eventWindowNumber) eventWin={\(debugWindowToken(eventWindow))} keyWin={\(debugWindowToken(NSApp.keyWindow))} mainWin={\(debugWindowToken(NSApp.mainWindow))} activeMgr=\(debugManagerToken(activeManager)) activeWinId=\(activeWindowId) activeSelected=\(selectedWorkspace) contexts=[\(contexts)]"
    }
#endif

    func mainWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let window = event.window, isMainTerminalWindow(window) {
            return window
        }
        let eventWindowNumber = event.windowNumber
        if eventWindowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: eventWindowNumber),
           isMainTerminalWindow(numberedWindow) {
            return numberedWindow
        }
        if let keyWindow = NSApp.keyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return nil
    }

    /// Re-sync app-level active window pointers from the currently focused main terminal window.
    /// This keeps menu/shortcut actions window-scoped even if the cached `tabManager` drifts.
    @discardableResult
    func synchronizeActiveMainWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        let (context, source): (MainWindowContext?, String) = {
            if let preferredWindow,
               let context = contextForMainWindow(preferredWindow) {
                return (context, "preferredWindow")
            }
            if let context = contextForMainWindow(NSApp.keyWindow) {
                return (context, "keyWindow")
            }
            if let context = contextForMainWindow(NSApp.mainWindow) {
                return (context, "mainWindow")
            }
            if let activeManager = tabManager,
               let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
                return (activeContext, "activeManager")
            }
            return (mainWindowContexts.values.first, "firstContextFallback")
        }()

#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
        dlog(
            "shortcut.sync.pre source=\(source) preferred={\(debugWindowToken(preferredWindow))} chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        guard let context else { return tabManager }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }
#if DEBUG
        dlog(
            "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        return context.tabManager
    }

    func preferredMainWindowContextForShortcuts(event: NSEvent) -> MainWindowContext? {
        if let context = contextForMainWindow(event.window) {
            return context
        }
        if let context = contextForMainWindow(NSApp.keyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    func activateMainWindowContextForShortcutEvent(_ event: NSEvent) {
        let preferredWindow = mainWindowForShortcutEvent(event)
#if DEBUG
        dlog(
            "shortcut.activate.pre event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        _ = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
#if DEBUG
        dlog(
            "shortcut.activate.post event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
    }

    @discardableResult
    func toggleSidebarInActiveMainWindow() -> Bool {
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            if let window = activeContext.window ?? windowForMainWindowId(activeContext.windowId) {
                setActiveMainWindow(window)
            }
            activeContext.sidebarState.toggle()
            return true
        }
        if let keyContext = contextForMainWindow(NSApp.keyWindow) {
            if let window = keyContext.window ?? windowForMainWindowId(keyContext.windowId) {
                setActiveMainWindow(window)
            }
            keyContext.sidebarState.toggle()
            return true
        }
        if let mainContext = contextForMainWindow(NSApp.mainWindow) {
            if let window = mainContext.window ?? windowForMainWindowId(mainContext.windowId) {
                setActiveMainWindow(window)
            }
            mainContext.sidebarState.toggle()
            return true
        }
        if let fallbackContext = mainWindowContexts.values.first {
            if let window = fallbackContext.window ?? windowForMainWindowId(fallbackContext.windowId) {
                setActiveMainWindow(window)
            }
            fallbackContext.sidebarState.toggle()
            return true
        }
        if let sidebarState {
            sidebarState.toggle()
            return true
        }
        return false
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.sidebarState.isVisible
    }

    @objc func openNewMainWindow(_ sender: Any?) {
        _ = createMainWindow()
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .window, error: error)
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .workspace, error: error)
    }

    enum ServiceOpenTarget {
        case window
        case workspace
    }

    func openFromServicePasteboard(
        _ pasteboard: NSPasteboard,
        target: ServiceOpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let pathURLs = servicePathURLs(from: pasteboard)
        guard !pathURLs.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: pathURLs)
        guard !directories.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        for directory in directories {
            switch target {
            case .window:
                _ = createMainWindow(initialWorkingDirectory: directory)
            case .workspace:
                openWorkspaceFromService(workingDirectory: directory)
            }
        }
    }

    func servicePathURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let pathURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !pathURLs.isEmpty {
            return pathURLs
        }

        let filenamesType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                return urls
            }
        }

        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            return raw
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fileURL = URL(string: text), fileURL.isFileURL {
                        return fileURL
                    }
                    return URL(fileURLWithPath: text)
                }
        }

        return []
    }

    func openWorkspaceFromService(workingDirectory: String) {
        if let context = preferredMainWindowContextForServiceWorkspace(),
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
            _ = context.tabManager.addWorkspace(workingDirectory: workingDirectory)
            return
        }
        _ = createMainWindow(initialWorkingDirectory: workingDirectory)
    }

    func preferredMainWindowContextForServiceWorkspace() -> MainWindowContext? {
        if let keyWindow = NSApp.keyWindow,
           isMainTerminalWindow(keyWindow),
           let context = mainWindowContexts[ObjectIdentifier(keyWindow)] {
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           isMainTerminalWindow(mainWindow),
           let context = mainWindowContexts[ObjectIdentifier(mainWindow)] {
            return context
        }

        return mainWindowContexts.values.first
    }

    @discardableResult
    func createMainWindow(initialWorkingDirectory: String? = nil) -> UUID {
        let windowId = UUID()
        let existingCount = mainWindowContexts.count
        #if DEBUG
        dlog("mainWindow.CREATE windowId=\(windowId.uuidString.prefix(8)) existingWindows=\(existingCount) cwd=\(initialWorkingDirectory ?? "nil") caller=\(Thread.callStackSymbols.prefix(5).joined(separator: " → "))")
        #endif
        let tabManager = TabManager(initialWorkingDirectory: initialWorkingDirectory)
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let notificationStore = self.notificationStore ?? TerminalNotificationStore.shared

        let root = ContentView(updateViewModel: updateViewModel, windowId: windowId)
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)
            .withServices()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isMovable = true
        // Disable macOS state restoration for this window. Without this,
        // macOS may auto-recreate closed windows on next launch, producing
        // duplicates that share the SwiftUI WindowGroup's @StateObject tabManager.
        window.isRestorable = false
        window.center()
        window.contentView = NSHostingView(rootView: root)

        // Apply shared window styling (skip titlebar accessory for flush layout).
        applyWindowDecorations(to: window)

        // Keep a strong reference so the window isn't deallocated.
        let controller = MainWindowController(window: window)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.mainWindowControllers.removeAll(where: { $0 === controller })
        }
        window.delegate = controller
        mainWindowControllers.append(controller)

        registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )
        installFileDropOverlay(on: window, tabManager: tabManager)
        if TerminalController.shouldSuppressSocketCommandActivation() {
            window.orderFront(nil)
            if TerminalController.socketCommandAllowsInAppFocusMutations() {
                setActiveMainWindow(window)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            setActiveMainWindow(window)
            NSApp.activate(ignoringOtherApps: true)
        }
        return windowId
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.checkForUpdates()
    }

    @objc func applyUpdateIfAvailable(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.installUpdate()
    }

    @objc func attemptUpdate(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.attemptUpdate()
    }

    func setupMenuBarExtra() {
        let store = self.notificationStore ?? TerminalNotificationStore.shared
        menuBarExtraController = MenuBarExtraController(
            notificationStore: store,
            onShowNotifications: { [weak self] in
                self?.showNotificationsPopoverFromMenuBar()
            },
            onOpenNotification: { [weak self] notification in
                _ = self?.openNotification(
                    tabId: notification.tabId,
                    surfaceId: notification.surfaceId,
                    notificationId: notification.id
                )
            },
            onJumpToLatestUnread: { [weak self] in
                self?.jumpToLatestUnread()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(nil)
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferencesWindow()
            },
            onQuitApp: {
                NSApp.terminate(nil)
            }
        )
    }

    @objc func openPreferencesWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshMenuBarExtraForDebug() {
        menuBarExtraController?.refreshForDebugControls()
    }

    func showNotificationsPopoverFromMenuBar() {
        let context: MainWindowContext? = {
            if let keyWindow = NSApp.keyWindow,
               isMainTerminalWindow(keyWindow),
               let keyContext = mainWindowContexts[ObjectIdentifier(keyWindow)] {
                return keyContext
            }
            if let first = mainWindowContexts.values.first {
                return first
            }
            let windowId = createMainWindow()
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }()

        if let context,
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.titlebarAccessoryController.showNotificationsPopover(animated: false)
        }
    }

    #if DEBUG
    @objc func showUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {}))
    }

    @objc func showUpdatePillLongNightly(_ sender: Any?) {
        updateViewModel.debugOverrideText = "Update Available: 0.32.0-nightly+20260216.abc1234"
        updateViewModel.overrideState = .notFound(.init(acknowledgement: {}))
    }

    @objc func showUpdatePillLoading(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .checking(.init(cancel: {}))
    }

    @objc func hideUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .idle
    }

    @objc func clearUpdatePillOverride(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = nil
    }
#endif

    @objc func copyUpdateLogs(_ sender: Any?) {
        let logText = UpdateLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No update logs captured.\nLog file: \(UpdateLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(UpdateLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
    @objc func copyFocusLogs(_ sender: Any?) {
        let logText = FocusLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No focus logs captured.\nLog file: \(FocusLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(FocusLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

#if DEBUG
    let debugColorWorkspaceTitlePrefix = "Debug Color - "

    @objc func openDebugScrollbackTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let config = GhosttyConfig.load()
        let lineCount = min(max(config.scrollbackLimit * 2, 2000), 60000)
        let command = "for i in {1..\(lineCount)}; do printf \"scrollback %06d\\n\" $i; done\n"
        sendTextWhenReady(command, to: tab)
    }

    @objc func openDebugLoremTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let lineCount = 2000
        let base = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for index in 1...lineCount {
            lines.append(String(format: "%04d %@", index, base))
        }
        let payload = lines.joined(separator: "\n") + "\n"
        sendTextWhenReady(payload, to: tab)
    }

    @objc func openDebugColorComparisonWorkspaces(_ sender: Any?) {
        guard let tabManager else { return }

        let palette = WorkspaceTabColorSettings.palette()
        guard !palette.isEmpty else { return }

        var existingByTitle: [String: Workspace] = [:]
        for tab in tabManager.tabs {
            guard let title = tab.customTitle,
                  title.hasPrefix(debugColorWorkspaceTitlePrefix) else { continue }
            existingByTitle[title] = tab
        }

        for entry in palette {
            let title = "\(debugColorWorkspaceTitlePrefix)\(entry.name)"
            let targetTab: Workspace
            if let existing = existingByTitle[title] {
                targetTab = existing
            } else {
                targetTab = tabManager.addTab()
            }
            tabManager.setCustomTitle(tabId: targetTab.id, title: title)
            tabManager.setTabColor(tabId: targetTab.id, color: entry.hex)
        }
    }

    func sendTextWhenReady(_ text: String, to tab: Tab, attempt: Int = 0) {
        let maxAttempts = 60
        if let terminalPanel = tab.focusedTerminalPanel, terminalPanel.surface.surface != nil {
            terminalPanel.sendText(text)
            return
        }
        guard attempt < maxAttempts else {
            NSLog("Debug scrollback: surface not ready after \(maxAttempts) attempts")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendTextWhenReady(text, to: tab, attempt: attempt + 1)
        }
    }

    @objc func triggerSentryTestCrash(_ sender: Any?) {
        SentrySDK.crash()
    }
#endif

#if DEBUG
    func setupJumpUnreadUITestIfNeeded() {
        guard !didSetupJumpUnreadUITest else { return }
        didSetupJumpUnreadUITest = true
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_JUMP_UNREAD_SETUP"] ?? env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"]) == "1" else { return }
        guard let notificationStore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // In UI tests, the initial SwiftUI `WindowGroup` window can lag behind launch. Wait for a
                // registered main terminal window context so notifications can be routed back correctly.
                let deadline = Date().addingTimeInterval(8.0)
                @MainActor func waitForContext(_ completion: @escaping (MainWindowContext) -> Void) {
                    if let context = self.mainWindowContexts.values.first,
                       context.window != nil {
                        completion(context)
                        return
                    }
                    guard Date() < deadline else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        Task { @MainActor in
                            waitForContext(completion)
                        }
                    }
                }

                waitForContext { context in
                    let tabManager = context.tabManager
                    let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
                    let tab = tabManager.addTab()
                    guard let initialPanelId = tab.focusedPanelId else { return }

                    _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialPanelId, direction: .right)
                    guard let targetPanelId = tab.focusedPanelId else { return }
                    // Find another panel that's not the currently focused one
                    let otherPanelId = tab.panels.keys.first(where: { $0 != targetPanelId })
                    if let otherPanelId {
                        tab.focusPanel(otherPanelId)
                    }

                    // Avoid flakiness in the VM where focus can lag selection by a tick, which would
                    // cause notification suppression to incorrectly drop this UI-test notification.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    notificationStore.addNotification(
                        tabId: tab.id,
                        surfaceId: targetPanelId,
                        title: "JumpToUnread",
                        subtitle: "",
                        body: ""
                    )
                    AppFocusState.overrideIsFocused = prevOverride

                    self.writeJumpUnreadTestData([
                        "expectedTabId": tab.id.uuidString,
                        "expectedSurfaceId": targetPanelId.uuidString
                    ])

                    tabManager.selectTab(at: initialIndex)
                }
            }
        }
    }

    func recordJumpToUnreadFocus(tabId: UUID, surfaceId: UUID) {
        writeJumpUnreadTestData([
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId.uuidString
        ])
    }

    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard let path = (env["TERMMESH_UI_TEST_JUMP_UNREAD_PATH"] ?? env["CMUX_UI_TEST_JUMP_UNREAD_PATH"]), !path.isEmpty else { return }
        jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
        installJumpUnreadFocusObserverIfNeeded()
    }

    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = jumpUnreadFocusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        jumpUnreadFocusExpectation = nil
        recordJumpToUnreadFocus(tabId: tabId, surfaceId: surfaceId)
        if let jumpUnreadFocusObserver {
            NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
            self.jumpUnreadFocusObserver = nil
        }
    }

    func installJumpUnreadFocusObserverIfNeeded() {
        guard jumpUnreadFocusObserver == nil else { return }
        jumpUnreadFocusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self.recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
        }
    }

    func writeJumpUnreadTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = (env["TERMMESH_UI_TEST_JUMP_UNREAD_PATH"] ?? env["CMUX_UI_TEST_JUMP_UNREAD_PATH"]), !path.isEmpty else { return }
        var payload = loadJumpUnreadTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func loadJumpUnreadTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    func setupGotoSplitUITestIfNeeded() {
        guard !didSetupGotoSplitUITest else { return }
        didSetupGotoSplitUITest = true
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_GOTO_SPLIT_SETUP"] ?? env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"]) == "1" else { return }
        guard tabManager != nil else { return }

        let useGhosttyConfig = (env["TERMMESH_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] ?? env["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"]) == "1"

        if useGhosttyConfig {
            // Keep the test hermetic: ensure the app does not accidentally pass using a persisted
            // KeyboardShortcutSettings override instead of the Ghostty config-trigger path.
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusLeftKey)
        } else {
            // For this UI test we want a letter-based shortcut (Cmd+Ctrl+H) to drive pane navigation,
            // since arrow keys can't be recorded by the shortcut recorder.
            let shortcut = StoredShortcut(key: "h", command: true, shift: false, option: false, control: true)
            if let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: KeyboardShortcutSettings.focusLeftKey)
            }
        }

        installGotoSplitUITestFocusObserversIfNeeded()

        // On the VM, launching/initializing multiple windows can occasionally take longer than a
        // few seconds; keep the deadline generous so the test doesn't flake.
        let deadline = Date().addingTimeInterval(20.0)
        func hasMainTerminalWindow() -> Bool {
            NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "term-mesh.main" || raw.hasPrefix("term-mesh.main.")
            }
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeGotoSplitTestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard hasMainTerminalWindow() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }
            guard let tabManager = self.tabManager else { return }

            let tab = tabManager.addTab()
            guard let initialPanelId = tab.focusedPanelId else {
                self.writeGotoSplitTestData(["setupError": "Missing initial panel id"])
                return
            }

            let url = URL(string: "https://example.com")
            guard let browserPanelId = tabManager.newBrowserSplit(
                tabId: tab.id,
                fromPanelId: initialPanelId,
                orientation: .horizontal,
                url: url
            ) else {
                self.writeGotoSplitTestData(["setupError": "Failed to create browser split"])
                return
            }

            self.focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            runSetupWhenWindowReady()
        }
    }

    func focusWebViewForGotoSplitUITest(tab: Workspace, browserPanelId: UUID, attempt: Int = 0) {
        let maxAttempts = 120
        guard attempt < maxAttempts else {
            writeGotoSplitTestData([
                "webViewFocused": "false",
                "setupError": "Timed out waiting for WKWebView focus"
            ])
            return
        }

        guard let browserPanel = tab.browserPanel(for: browserPanelId) else {
            writeGotoSplitTestData([
                "webViewFocused": "false",
                "setupError": "Browser panel missing"
            ])
            return
        }

        // Select the browser surface and try to focus the WKWebView.
        tab.focusPanel(browserPanelId)

        if isWebViewFocused(browserPanel),
           let (browserPaneId, terminalPaneId) = paneIdsForGotoSplitUITest(
            tab: tab,
            browserPanelId: browserPanelId
           ) {
            writeGotoSplitTestData([
                "browserPanelId": browserPanelId.uuidString,
                "browserPaneId": browserPaneId.description,
                "terminalPaneId": terminalPaneId.description,
                "initialPaneCount": String(tab.bonsplitController.allPaneIds.count),
                "focusedPaneId": tab.bonsplitController.focusedPaneId?.description ?? "",
                "ghosttyGotoSplitLeftShortcut": ghosttyGotoSplitLeftShortcut?.displayString ?? "",
                "ghosttyGotoSplitRightShortcut": ghosttyGotoSplitRightShortcut?.displayString ?? "",
                "ghosttyGotoSplitUpShortcut": ghosttyGotoSplitUpShortcut?.displayString ?? "",
                "ghosttyGotoSplitDownShortcut": ghosttyGotoSplitDownShortcut?.displayString ?? "",
                "webViewFocused": "true"
            ])
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId, attempt: attempt + 1)
        }
    }

    func isWebViewFocused(_ panel: BrowserPanel) -> Bool {
        guard let window = panel.webView.window else { return false }
        guard let fr = window.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: panel.webView)
    }

    func paneIdsForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) -> (browser: PaneID, terminal: PaneID)? {
        let paneIds = tab.bonsplitController.allPaneIds
        guard paneIds.count >= 2 else { return nil }

        var browserPane: PaneID?
        var terminalPane: PaneID?
        for paneId in paneIds {
            guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = tab.panelIdFromSurfaceId(selected.id) else { continue }
            if panelId == browserPanelId {
                browserPane = paneId
            } else if terminalPane == nil {
                terminalPane = paneId
            }
        }

        guard let browserPane, let terminalPane else { return nil }
        return (browserPane, terminalPane)
    }

    func installGotoSplitUITestFocusObserversIfNeeded() {
        guard gotoSplitUITestObservers.isEmpty else { return }

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarFocus")
        })

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidExitAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarExit")
        })
    }

    func recordGotoSplitUITestWebViewFocus(panelId: UUID, key: String) {
        // Give the responder chain time to settle, retrying for slow environments (e.g. VM).
        recordGotoSplitUITestWebViewFocusRetry(panelId: panelId, key: key, attempt: 0)
    }

    func recordGotoSplitUITestWebViewFocusRetry(panelId: UUID, key: String, attempt: Int) {
        let delays: [Double] = [0.05, 0.1, 0.25, 0.5]
        let delay = attempt < delays.count ? delays[attempt] : delays.last!
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let tabManager, let tab = tabManager.selectedWorkspace,
                  let panel = tab.browserPanel(for: panelId) else { return }
            let focused = self.isWebViewFocused(panel)
            // If focus hasn't settled yet and we have retries left, try again.
            if !focused && key.contains("Exit") && attempt < delays.count - 1 {
                self.recordGotoSplitUITestWebViewFocusRetry(panelId: panelId, key: key, attempt: attempt + 1)
                return
            }
            self.writeGotoSplitTestData([
                key: focused ? "true" : "false",
                "\(key)PanelId": panelId.uuidString
            ])
        }
    }

    func recordGotoSplitMoveIfNeeded(direction: NavigationDirection) {
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_GOTO_SPLIT_SETUP"] ?? env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"]) == "1" else { return }
        guard let tabManager,
              let focusedPaneId = tabManager.selectedWorkspace?.bonsplitController.focusedPaneId else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        writeGotoSplitTestData([
            "lastMoveDirection": directionValue,
            "focusedPaneId": focusedPaneId.description
        ])
    }

    func recordGotoSplitSplitIfNeeded(direction: SplitDirection) {
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_GOTO_SPLIT_SETUP"] ?? env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"]) == "1" else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        writeGotoSplitTestData([
            "lastSplitDirection": directionValue,
            "paneCountAfterSplit": String(workspace.bonsplitController.allPaneIds.count),
            "focusedPaneId": workspace.bonsplitController.focusedPaneId?.description ?? ""
        ])
    }

    func writeGotoSplitTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = (env["TERMMESH_UI_TEST_GOTO_SPLIT_PATH"] ?? env["CMUX_UI_TEST_GOTO_SPLIT_PATH"]), !path.isEmpty else { return }
        var payload = loadGotoSplitTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func loadGotoSplitTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    func setupMultiWindowNotificationsUITestIfNeeded() {
        guard !didSetupMultiWindowNotificationsUITest else { return }
        didSetupMultiWindowNotificationsUITest = true

        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] ?? env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"]) == "1" else { return }
        guard let path = (env["TERMMESH_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] ?? env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"]), !path.isEmpty else { return }

        try? FileManager.default.removeItem(atPath: path)

        let deadline = Date().addingTimeInterval(8.0)
        func waitForContexts(minCount: Int, _ completion: @escaping () -> Void) {
            if mainWindowContexts.count >= minCount,
               mainWindowContexts.values.allSatisfy({ $0.window != nil }) {
                completion()
                return
            }
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                waitForContexts(minCount: minCount, completion)
            }
        }

        waitForContexts(minCount: 1) { [weak self] in
            guard let self else { return }
            guard let window1 = self.mainWindowContexts.values.first else { return }
            guard let tabId1 = window1.tabManager.selectedTabId ?? window1.tabManager.tabs.first?.id else { return }

            // Create a second main terminal window.
            self.openNewMainWindow(nil)

            waitForContexts(minCount: 2) { [weak self] in
                guard let self else { return }
                let contexts = Array(self.mainWindowContexts.values)
                guard let window2 = contexts.first(where: { $0.windowId != window1.windowId }) else { return }
                guard let tabId2 = window2.tabManager.selectedTabId ?? window2.tabManager.tabs.first?.id else { return }
                guard let store = self.notificationStore else { return }

                // Ensure the target window is currently showing the Notifications overlay,
                // so opening a notification must switch it back to the terminal UI.
                window2.sidebarSelectionState.selection = .notifications

                // Create notifications for both windows. Ensure W2 isn't suppressed just because it's focused.
                let prevOverride = AppFocusState.overrideIsFocused
                AppFocusState.overrideIsFocused = false
                store.addNotification(tabId: tabId2, surfaceId: nil, title: "W2", subtitle: "multiwindow", body: "")
                AppFocusState.overrideIsFocused = prevOverride

                // Insert after W2 so it becomes "latest unread" (first in list).
                store.addNotification(tabId: tabId1, surfaceId: nil, title: "W1", subtitle: "multiwindow", body: "")

                let notif1 = store.notifications.first(where: { $0.tabId == tabId1 && $0.title == "W1" })
                let notif2 = store.notifications.first(where: { $0.tabId == tabId2 && $0.title == "W2" })

                self.writeMultiWindowNotificationTestData([
                    "window1Id": window1.windowId.uuidString,
                    "window2Id": window2.windowId.uuidString,
                    "window2InitialSidebarSelection": "notifications",
                    "tabId1": tabId1.uuidString,
                    "tabId2": tabId2.uuidString,
                    "notifId1": notif1?.id.uuidString ?? "",
                    "notifId2": notif2?.id.uuidString ?? "",
                    "expectedLatestWindowId": window1.windowId.uuidString,
                    "expectedLatestTabId": tabId1.uuidString,
                ], at: path)
            }
        }
    }

    func writeMultiWindowNotificationTestData(_ updates: [String: String], at path: String) {
        var payload = loadMultiWindowNotificationTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func loadMultiWindowNotificationTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    func recordMultiWindowNotificationFocusIfNeeded(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        sidebarSelection: SidebarSelection
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = (env["TERMMESH_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] ?? env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"]), !path.isEmpty else { return }
        let sidebarSelectionString: String = {
            switch sidebarSelection {
            case .tabs: return "tabs"
            case .notifications: return "notifications"
            }
        }()
        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "focusedWindowId": windowId.uuidString,
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId?.uuidString ?? "",
            "focusedSidebarSelection": sidebarSelectionString,
        ], at: path)
    }
#endif

    func attachUpdateAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    func applyWindowDecorations(to window: NSWindow) {
        windowDecorationsController.apply(to: window)
    }

    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated, anchorView: anchorView)
    }

    func jumpToLatestUnread() {
        guard let notificationStore else { return }
#if DEBUG
        if termMeshEnv("UI_TEST_JUMP_UNREAD_SETUP") == "1" {
            writeJumpUnreadTestData([
                "jumpUnreadInvoked": "1",
                "jumpUnreadNotificationCount": String(notificationStore.notifications.count),
            ])
        }
#endif
        // Prefer the latest unread that we can actually open. In early startup (especially on the VM),
        // the window-context registry can lag behind model initialization, so fall back to whatever
        // tab manager currently owns the tab.
        for notification in notificationStore.notifications where !notification.isRead {
            if openNotification(tabId: notification.tabId, surfaceId: notification.surfaceId, notificationId: notification.id) {
                return
            }
        }
    }

    static func installWindowResponderSwizzlesForTesting() {
        _ = didInstallWindowKeyEquivalentSwizzle
        _ = didInstallWindowFirstResponderSwizzle
        _ = didInstallWindowSendEventSwizzle
    }

#if DEBUG
    static func setWindowFirstResponderGuardTesting(currentEvent: NSEvent?, hitView: NSView?) {
        termMeshFirstResponderGuardCurrentEventOverride = currentEvent
        termMeshFirstResponderGuardHitViewOverride = hitView
    }

    static func clearWindowFirstResponderGuardTesting() {
        termMeshFirstResponderGuardCurrentEventOverride = nil
        termMeshFirstResponderGuardHitViewOverride = nil
    }
#endif

    func installWindowResponderSwizzles() {
        _ = Self.didInstallWindowKeyEquivalentSwizzle
        _ = Self.didInstallWindowFirstResponderSwizzle
        _ = Self.didInstallWindowSendEventSwizzle
    }

    func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
#if DEBUG
                if (termMeshEnv("KEY_LATENCY_PROBE") == "1"
                    || UserDefaults.standard.bool(forKey: "termMeshKeyLatencyProbe")),
                   event.timestamp > 0 {
                    let delayMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
                    let delayText = String(format: "%.2f", delayMs)
                    dlog("key.latency path=appMonitor ms=\(delayText) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat ? 1 : 0)")
                }
                let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                dlog(
                    "monitor.keyDown: \(NSWindow.keyDescription(event)) fr=\(frType) addrBarId=\(self.browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil") \(self.debugShortcutRouteSnapshot(event: event))"
                )
                if let probeKind = self.developerToolsShortcutProbeKind(event: event) {
                    self.logDeveloperToolsShortcutSnapshot(phase: "monitor.pre.\(probeKind)", event: event)
                }
#endif
                if self.handleCustomShortcut(event: event) {
#if DEBUG
                    dlog("  → consumed by handleCustomShortcut")
                    DebugEventLog.shared.dump()
#endif
                    return nil // Consume the event
                }
#if DEBUG
                DebugEventLog.shared.dump()
#endif
                return event // Pass through
            }
            self.handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
            return event
        }
    }

    func installShortcutDefaultsObserver() {
        guard shortcutDefaultsObserver == nil else { return }
        shortcutDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSplitButtonTooltipRefreshAcrossWorkspaces()
        }
    }

    /// Coalesce shortcut-default changes and refresh on the next runloop turn to
    /// avoid mutating Bonsplit/SwiftUI-observed state during an active update pass.
    func scheduleSplitButtonTooltipRefreshAcrossWorkspaces() {
        guard !splitButtonTooltipRefreshScheduled else { return }
        splitButtonTooltipRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitButtonTooltipRefreshScheduled = false
            self.refreshSplitButtonTooltipsAcrossWorkspaces()
        }
    }

    func refreshSplitButtonTooltipsAcrossWorkspaces() {
        var refreshedManagers: Set<ObjectIdentifier> = []
        if let manager = tabManager {
            manager.refreshSplitButtonTooltips()
            refreshedManagers.insert(ObjectIdentifier(manager))
        }
        for context in mainWindowContexts.values {
            let manager = context.tabManager
            let identifier = ObjectIdentifier(manager)
            guard refreshedManagers.insert(identifier).inserted else { continue }
            manager.refreshSplitButtonTooltips()
        }
    }

    func installGhosttyConfigObserver() {
        guard ghosttyConfigObserver == nil else { return }
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshGhosttyGotoSplitShortcuts()
        }
    }

    func refreshGhosttyGotoSplitShortcuts() {
        guard let config = GhosttyApp.shared.config else {
            ghosttyGotoSplitLeftShortcut = nil
            ghosttyGotoSplitRightShortcut = nil
            ghosttyGotoSplitUpShortcut = nil
            ghosttyGotoSplitDownShortcut = nil
            return
        }

        ghosttyGotoSplitLeftShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:left", UInt("goto_split:left".utf8.count))
        )
        ghosttyGotoSplitRightShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:right", UInt("goto_split:right".utf8.count))
        )
        ghosttyGotoSplitUpShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:up", UInt("goto_split:up".utf8.count))
        )
        ghosttyGotoSplitDownShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:down", UInt("goto_split:down".utf8.count))
        )
    }

    func storedShortcutFromGhosttyTrigger(_ trigger: ghostty_input_trigger_s) -> StoredShortcut? {
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            switch trigger.key.physical {
            case GHOSTTY_KEY_ARROW_LEFT:
                key = "←"
            case GHOSTTY_KEY_ARROW_RIGHT:
                key = "→"
            case GHOSTTY_KEY_ARROW_UP:
                key = "↑"
            case GHOSTTY_KEY_ARROW_DOWN:
                key = "↓"
            case GHOSTTY_KEY_A: key = "a"
            case GHOSTTY_KEY_B: key = "b"
            case GHOSTTY_KEY_C: key = "c"
            case GHOSTTY_KEY_D: key = "d"
            case GHOSTTY_KEY_E: key = "e"
            case GHOSTTY_KEY_F: key = "f"
            case GHOSTTY_KEY_G: key = "g"
            case GHOSTTY_KEY_H: key = "h"
            case GHOSTTY_KEY_I: key = "i"
            case GHOSTTY_KEY_J: key = "j"
            case GHOSTTY_KEY_K: key = "k"
            case GHOSTTY_KEY_L: key = "l"
            case GHOSTTY_KEY_M: key = "m"
            case GHOSTTY_KEY_N: key = "n"
            case GHOSTTY_KEY_O: key = "o"
            case GHOSTTY_KEY_P: key = "p"
            case GHOSTTY_KEY_Q: key = "q"
            case GHOSTTY_KEY_R: key = "r"
            case GHOSTTY_KEY_S: key = "s"
            case GHOSTTY_KEY_T: key = "t"
            case GHOSTTY_KEY_U: key = "u"
            case GHOSTTY_KEY_V: key = "v"
            case GHOSTTY_KEY_W: key = "w"
            case GHOSTTY_KEY_X: key = "x"
            case GHOSTTY_KEY_Y: key = "y"
            case GHOSTTY_KEY_Z: key = "z"
            case GHOSTTY_KEY_DIGIT_0: key = "0"
            case GHOSTTY_KEY_DIGIT_1: key = "1"
            case GHOSTTY_KEY_DIGIT_2: key = "2"
            case GHOSTTY_KEY_DIGIT_3: key = "3"
            case GHOSTTY_KEY_DIGIT_4: key = "4"
            case GHOSTTY_KEY_DIGIT_5: key = "5"
            case GHOSTTY_KEY_DIGIT_6: key = "6"
            case GHOSTTY_KEY_DIGIT_7: key = "7"
            case GHOSTTY_KEY_DIGIT_8: key = "8"
            case GHOSTTY_KEY_DIGIT_9: key = "9"
            case GHOSTTY_KEY_BRACKET_LEFT: key = "["
            case GHOSTTY_KEY_BRACKET_RIGHT: key = "]"
            case GHOSTTY_KEY_MINUS: key = "-"
            case GHOSTTY_KEY_EQUAL: key = "="
            case GHOSTTY_KEY_COMMA: key = ","
            case GHOSTTY_KEY_PERIOD: key = "."
            case GHOSTTY_KEY_SLASH: key = "/"
            case GHOSTTY_KEY_SEMICOLON: key = ";"
            case GHOSTTY_KEY_QUOTE: key = "'"
            case GHOSTTY_KEY_BACKQUOTE: key = "`"
            case GHOSTTY_KEY_BACKSLASH: key = "\\"
            default:
                return nil
            }
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = String(Character(scalar)).lowercased()
        case GHOSTTY_TRIGGER_CATCH_ALL:
            return nil
        default:
            return nil
        }

        let mods = trigger.mods.rawValue
        let command = (mods & GHOSTTY_MODS_SUPER.rawValue) != 0
        let shift = (mods & GHOSTTY_MODS_SHIFT.rawValue) != 0
        let option = (mods & GHOSTTY_MODS_ALT.rawValue) != 0
        let control = (mods & GHOSTTY_MODS_CTRL.rawValue) != 0

        // Ignore bogus empty triggers.
        if key.isEmpty || (!command && !shift && !option && !control) {
            return nil
        }

        return StoredShortcut(key: key, command: command, shift: shift, option: option, control: control)
    }

    func handleQuitShortcutWarning() -> Bool {
        if !QuitWarningSettings.isEnabled() {
            NSApp.terminate(nil)
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Term-Mesh?"
        alert.informativeText = "This will close all windows and workspaces."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't warn again for Cmd+Q"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            QuitWarningSettings.setEnabled(false)
        }

        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
        return true
    }

    func promptRenameSelectedWorkspace() -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            NSSound.beep()
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a custom name for this workspace."
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = "Workspace name"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return true }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
        return true
    }

    func handleCustomShortcut(event: NSEvent) -> Bool {
        // `charactersIgnoringModifiers` can be nil for some synthetic NSEvents and certain special keys.
        // Most shortcuts below use keyCode fallbacks, so treat nil as "" rather than bailing out.
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let isControlOnly = hasControl && !hasCommand && !hasOption
        let controlDChar = chars == "d" || event.characters == "\u{04}"
        let isControlD = isControlOnly && (controlDChar || event.keyCode == 2)
#if DEBUG
        if isControlD {
            writeChildExitKeyboardProbe(
                [
                    "probeAppShortcutCharsHex": childExitKeyboardProbeHex(event.characters),
                    "probeAppShortcutCharsIgnoringHex": childExitKeyboardProbeHex(event.charactersIgnoringModifiers),
                    "probeAppShortcutKeyCode": String(event.keyCode),
                    "probeAppShortcutModsRaw": String(event.modifierFlags.rawValue),
                ],
                increments: ["probeAppShortcutCtrlDSeenCount": 1]
            )
        }
#endif

        // Don't steal shortcuts from close-confirmation alerts. Keep standard alert key
        // equivalents working and avoid surprising actions while the confirmation is up.
        let closeConfirmationPanel = NSApp.windows
            .compactMap { $0 as? NSPanel }
            .first { panel in
                guard panel.isVisible, let root = panel.contentView else { return false }
                return findStaticText(in: root, equals: "Close workspace?")
                    || findStaticText(in: root, equals: "Close tab?")
            }
        if let closeConfirmationPanel {
            // Special-case: Cmd+D should confirm destructive close on alerts.
            // XCUITest key events often hit the app-level local monitor first, so forward the key
            // equivalent to the alert panel explicitly.
            if flags == [.command], chars == "d",
               let root = closeConfirmationPanel.contentView,
               let closeButton = findButton(in: root, titled: "Close") {
                closeButton.performClick(nil)
                return true
            }
            return false
        }

        if NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil {
            return false
        }

        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])

        if let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
            flags: event.modifierFlags,
            chars: chars,
            keyCode: event.keyCode
        ),
           let paletteWindow = activeCommandPaletteWindow() {
            NotificationCenter.default.post(
                name: .commandPaletteMoveSelection,
                object: paletteWindow,
                userInfo: ["delta": delta]
            )
            return true
        }

        let isCommandP = normalizedFlags == [.command] && (chars == "p" || event.keyCode == 35)
        if isCommandP {
            let targetWindow = activeCommandPaletteWindow() ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: targetWindow)
            return true
        }

        let isCommandShiftP = normalizedFlags == [.command, .shift] && (chars == "p" || event.keyCode == 35)
        if isCommandShiftP {
            let targetWindow = activeCommandPaletteWindow() ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            NotificationCenter.default.post(name: .commandPaletteRequested, object: targetWindow)
            return true
        }

        if normalizedFlags == [.command], chars == "q" {
            return handleQuitShortcutWarning()
        }
        if normalizedFlags == [.command, .shift],
           (chars == "," || chars == "<" || event.keyCode == 43) {
            configProvider.reloadConfiguration(source: "shortcut.cmd_shift_comma")
            return true
        }

        // When the terminal has active IME composition (e.g. Korean, Japanese, Chinese
        // input), don't intercept key events — let them flow through to the input method.
        if let ghosttyView = termMeshOwningGhosttyView(for: NSApp.keyWindow?.firstResponder),
           ghosttyView.hasMarkedText() {
            return false
        }

        // When the notifications popover is open, Escape should dismiss it immediately.
        if flags.isEmpty, event.keyCode == 53, titlebarAccessoryController.dismissNotificationsPopoverIfShown() {
            return true
        }

        // When the notifications popover is showing an empty state, consume plain typing
        // so key presses do not leak through into the focused terminal.
        if flags.isDisjoint(with: [.command, .control, .option]),
           titlebarAccessoryController.isNotificationsPopoverShown(),
           (notificationStore?.notifications.isEmpty ?? false) {
            return true
        }

        // Route all shortcut handling through the window that actually produced
        // the event to avoid cross-window actions when app-global pointers are stale.
        activateMainWindowContextForShortcutEvent(event)

        // Keep keyboard routing deterministic after split close/reparent transitions:
        // before processing shortcuts, converge first responder with the focused terminal panel.
        if isControlD {
#if DEBUG
            let selected = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
            let focused = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
            let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("shortcut.ctrlD stage=preReconcile selected=\(selected) focused=\(focused) fr=\(frType)")
#endif
            tabManager?.reconcileFocusedPanelFromFirstResponderForKeyboard()
            #if DEBUG
            let frAfterType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("shortcut.ctrlD stage=postReconcile fr=\(frAfterType)")
            writeChildExitKeyboardProbe([:], increments: ["probeAppShortcutCtrlDPassedCount": 1])
            #endif
            // Ctrl+D belongs to the focused terminal surface; never treat it as an app shortcut.
            return false
        }

        // Guard against stale browserAddressBarFocusedPanelId after focus transitions
        // (e.g., split that doesn't properly blur the address bar). If the first responder
        // is a terminal surface, the address bar can't be focused.
        if browserAddressBarFocusedPanelId != nil,
           termMeshOwningGhosttyView(for: NSApp.keyWindow?.firstResponder) != nil {
#if DEBUG
            dlog("handleCustomShortcut: clearing stale browserAddressBarFocusedPanelId")
#endif
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
        }

        // Chrome-like omnibar navigation while holding Cmd+N / Ctrl+N / Cmd+P / Ctrl+P.
        if let delta = commandOmnibarSelectionDelta(flags: flags, chars: chars) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: event.keyCode, delta: delta)
            return true
        }

        if let delta = browserOmnibarSelectionDeltaForArrowNavigation(
            hasFocusedAddressBar: browserAddressBarFocusedPanelId != nil,
            flags: event.modifierFlags,
            keyCode: event.keyCode
        ) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            return true
        }

        // Let omnibar-local Emacs navigation (Cmd/Ctrl+N/P) win while the browser
        // address bar is focused. Without this, app-level Cmd+N can steal focus.
        if shouldBypassAppShortcutForFocusedBrowserAddressBar(flags: flags, chars: chars) {
            return false
        }

        // Primary UI shortcuts
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleSidebar)) {
            _ = toggleSidebarInActiveMainWindow()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newTab)) {
#if DEBUG
            dlog("shortcut.action name=newWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
            // Cmd+N semantics:
            // - If there are no main windows, create a new window.
            // - Otherwise, create a new workspace in the active window.
            if tabManager == nil || mainWindowContexts.isEmpty {
                openNewMainWindow(nil)
            } else {
                tabManager?.addTab()
            }
            return true
        }

        // New Window: Cmd+Shift+N
        // Handled here instead of relying on SwiftUI's CommandGroup menu item because
        // after a browser panel has been shown, SwiftUI's menu dispatch can silently
        // consume the key equivalent without firing the action closure.
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newWindow)) {
            openNewMainWindow(nil)
            return true
        }

        // Check Show Notifications shortcut
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showNotifications)) {
            toggleNotificationsPopover(animated: false, anchorView: fullscreenControlsViewModel?.notificationsAnchorView)
            return true
        }

        // Check Jump to Unread shortcut
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .jumpToUnread)) {
#if DEBUG
            if termMeshEnv("UI_TEST_JUMP_UNREAD_SETUP") == "1" {
                writeJumpUnreadTestData(["jumpUnreadShortcutHandled": "1"])
            }
#endif
            jumpToLatestUnread()
            return true
        }

        // Flash the currently focused panel so the user can visually confirm focus.
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .triggerFlash)) {
            tabManager?.triggerFocusFlash()
            return true
        }

        // Sequential pane navigation: Cmd+] / Cmd+[
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .focusNextPane)) {
            tabManager?.focusNextPane()
            return true
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .focusPrevPane)) {
            tabManager?.focusPrevPane()
            return true
        }

        // Surface navigation: Cmd+Shift+] / Cmd+Shift+[
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .nextSurface)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .prevSurface)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        // Workspace navigation: Cmd+Ctrl+] / Cmd+Ctrl+[
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .nextSidebarTab)) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "ws.shortcut dir=next repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectNextTab()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .prevSidebarTab)) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "ws.shortcut dir=prev repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectPreviousTab()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .renameWorkspace)) {
            _ = promptRenameSelectedWorkspace()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .closeWorkspace)) {
            tabManager?.closeCurrentWorkspaceWithConfirmation()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .closeWindow)) {
            guard let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return true
            }
            targetWindow.performClose(nil)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .renameTab)) {
            // Keep Cmd+R browser reload behavior when a browser panel is focused.
            if tabManager?.focusedBrowserPanel != nil {
                return false
            }
            let targetWindow = activeCommandPaletteWindow() ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            NotificationCenter.default.post(name: .commandPaletteRenameTabRequested, object: targetWindow)
            return true
        }

        // Numeric shortcuts for specific sidebar tabs: Cmd+1-9 (9 = last workspace)
        if flags == [.command],
           let manager = tabManager,
           let num = Int(chars),
           let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: num, workspaceCount: manager.tabs.count) {
#if DEBUG
            dlog(
                "shortcut.action name=workspaceDigit digit=\(num) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            manager.selectTab(at: targetIndex)
            return true
        }

        // Numeric shortcuts for surfaces within pane: Ctrl+1-9 (9 = last)
        if flags == [.control] {
            if let num = Int(chars), num >= 1 && num <= 9 {
                if num == 9 {
                    tabManager?.selectLastSurface()
                } else {
                    tabManager?.selectSurface(at: num - 1)
                }
                return true
            }
        }

        // Pane focus navigation (defaults to Cmd+Option+Arrow, but can be customized to letter/number keys).
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusLeft),
            arrowGlyph: "←",
            arrowKeyCode: 123
        ) || (ghosttyGotoSplitLeftShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "←", arrowKeyCode: 123) } ?? false) {
            tabManager?.movePaneFocus(direction: .left)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .left)
#endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusRight),
            arrowGlyph: "→",
            arrowKeyCode: 124
        ) || (ghosttyGotoSplitRightShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "→", arrowKeyCode: 124) } ?? false) {
            tabManager?.movePaneFocus(direction: .right)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .right)
#endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusUp),
            arrowGlyph: "↑",
            arrowKeyCode: 126
        ) || (ghosttyGotoSplitUpShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↑", arrowKeyCode: 126) } ?? false) {
            tabManager?.movePaneFocus(direction: .up)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .up)
#endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusDown),
            arrowGlyph: "↓",
            arrowKeyCode: 125
        ) || (ghosttyGotoSplitDownShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↓", arrowKeyCode: 125) } ?? false) {
            tabManager?.movePaneFocus(direction: .down)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .down)
#endif
            return true
        }

        // Split actions: Cmd+D / Cmd+Shift+D
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitRight)) {
#if DEBUG
            dlog("shortcut.action name=splitRight \(debugShortcutRouteSnapshot(event: event))")
#endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .right) {
                return true
            }
            _ = performSplitShortcut(direction: .right)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitDown)) {
#if DEBUG
            dlog("shortcut.action name=splitDown \(debugShortcutRouteSnapshot(event: event))")
#endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .down) {
                return true
            }
            _ = performSplitShortcut(direction: .down)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitBrowserRight)) {
            _ = performBrowserSplitShortcut(direction: .right)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitBrowserDown)) {
            _ = performBrowserSplitShortcut(direction: .down)
            return true
        }

        // Zoom pane: Cmd+Shift+Enter
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .zoomPane)) {
#if DEBUG
            dlog("shortcut.action name=zoomPane \(debugShortcutRouteSnapshot(event: event))")
#endif
            tabManager?.toggleFocusedPaneZoom()
            return true
        }

        // Surface navigation (legacy Ctrl+Tab support)
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        // New surface: Cmd+T
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newSurface)) {
            tabManager?.newSurface()
            return true
        }

        // Open browser: Cmd+Shift+L
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .openBrowser)) {
            if let panelId = tabManager?.openBrowser(insertAtEnd: true) {
                focusBrowserAddressBar(panelId: panelId)
            }
            return true
        }

        // Safari defaults:
        // - Option+Command+I => Show/Toggle Web Inspector
        // - Option+Command+C => Show JavaScript Console
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.pre", event: event)
#endif
            let didHandle = tabManager?.toggleDeveloperToolsFocusedBrowser() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "toggle.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.pre", event: event)
#endif
            let didHandle = tabManager?.showJavaScriptConsoleFocusedBrowser() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "console.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        // Focus browser address bar: Cmd+L
        if flags == [.command] && chars == "l" {
            if let focusedPanel = tabManager?.focusedBrowserPanel {
                focusBrowserAddressBar(in: focusedPanel)
                return true
            }

            if let browserAddressBarFocusedPanelId,
               focusBrowserAddressBar(panelId: browserAddressBarFocusedPanelId) {
                return true
            }

            if let panelId = tabManager?.openBrowser(insertAtEnd: true) {
                focusBrowserAddressBar(panelId: panelId)
                return true
            }
        }

        #if DEBUG
        logBrowserZoomShortcutTrace(stage: "probe", event: event, flags: flags, chars: chars)
        #endif
        let zoomAction = browserZoomShortcutAction(flags: flags, chars: chars, keyCode: event.keyCode)
        #if DEBUG
        logBrowserZoomShortcutTrace(stage: "match", event: event, flags: flags, chars: chars, action: zoomAction)
        #endif
        if let action = zoomAction, let manager = tabManager {
            let handled: Bool
            switch action {
            case .zoomIn:
                handled = manager.zoomInFocusedBrowser()
            case .zoomOut:
                handled = manager.zoomOutFocusedBrowser()
            case .reset:
                handled = manager.resetZoomFocusedBrowser()
            }
            #if DEBUG
            logBrowserZoomShortcutTrace(
                stage: "dispatch",
                event: event,
                flags: flags,
                chars: chars,
                action: action,
                handled: handled
            )
            #endif
            return handled
        }
        #if DEBUG
        if zoomAction != nil, tabManager == nil {
            logBrowserZoomShortcutTrace(
                stage: "dispatch.noManager",
                event: event,
                flags: flags,
                chars: chars,
                action: zoomAction,
                handled: false
            )
        }
        #endif

        return false
    }

    func shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: SplitDirection) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: focusedPanelId) else {
            return false
        }

        let hostedView = terminalPanel.hostedView
        let hostedSize = hostedView.bounds.size
        let hostedHiddenInHierarchy = hostedView.isHiddenOrHasHiddenAncestor
        let hostedAttachedToWindow = hostedView.window != nil
        let firstResponderIsWindow = NSApp.keyWindow?.firstResponder is NSWindow

        let shouldSuppress = shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
            firstResponderIsWindow: firstResponderIsWindow,
            hostedSize: hostedSize,
            hostedHiddenInHierarchy: hostedHiddenInHierarchy,
            hostedAttachedToWindow: hostedAttachedToWindow
        )
        guard shouldSuppress else { return false }

        tabManager.reconcileFocusedPanelFromFirstResponderForKeyboard()

#if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "split.shortcut suppressed dir=\(directionLabel) reason=transient_focus_state " +
            "fr=\(firstResponderType) hidden=\(hostedHiddenInHierarchy ? 1 : 0) " +
            "attached=\(hostedAttachedToWindow ? 1 : 0) " +
            "frame=\(String(format: "%.1fx%.1f", hostedSize.width, hostedSize.height))"
        )
#endif
        return true
    }

#if DEBUG
    func logBrowserZoomShortcutTrace(
        stage: String,
        event: NSEvent,
        flags: NSEvent.ModifierFlags,
        chars: String,
        action: BrowserZoomShortcutAction? = nil,
        handled: Bool? = nil
    ) {
        guard browserZoomShortcutTraceCandidate(flags: flags, chars: chars, keyCode: event.keyCode) else {
            return
        }

        let keyWindow = NSApp.keyWindow
        let firstResponderType = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let panel = tabManager?.focusedBrowserPanel
        let panelToken = panel.map { String($0.id.uuidString.prefix(8)) } ?? "nil"
        let panelZoom = panel?.webView.pageZoom ?? -1
        var line =
            "zoom.shortcut stage=\(stage) event=\(NSWindow.keyDescription(event)) " +
            "chars='\(chars)' flags=\(browserZoomShortcutTraceFlagsString(flags)) " +
            "action=\(browserZoomShortcutTraceActionString(action)) keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType) panel=\(panelToken) zoom=\(String(format: "%.3f", panelZoom)) " +
            "addrBarId=\(browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil")"
        if let handled {
            line += " handled=\(handled ? 1 : 0)"
        }
        dlog(line)
    }
#endif

    @discardableResult
    func focusBrowserAddressBar(panelId: UUID) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panel = workspace.browserPanel(for: panelId) else {
            return false
        }
        workspace.focusPanel(panel.id)
        focusBrowserAddressBar(in: panel)
        return true
    }

}


#if DEBUG
var termMeshFirstResponderGuardCurrentEventOverride: NSEvent?
var termMeshFirstResponderGuardHitViewOverride: NSView?
#endif

extension NSWindow {
    @objc func termMesh_makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // Block programmatic focus theft while IME is mid-composition (hasMarkedText).
        // This prevents background events (agent terminal completion, socket commands)
        // from stealing first responder during CJK/IME text input.
        if let currentIME = self.firstResponder as? IMETextView,
           currentIME.hasMarkedText(),
           responder !== currentIME {
#if DEBUG
            dlog(
                "focus.guard imeComposingBlocked responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        if AppDelegate.shared?.shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
            window: self,
            responder: responder
        ) == true {
#if DEBUG
            dlog(
                "focus.guard commandPaletteBlocked responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        if let responder,
           let webView = Self.termMeshOwningWebView(for: responder),
           !webView.allowsFirstResponderAcquisitionEffective {
            let currentEvent = Self.termMeshCurrentEvent(for: self)
            let pointerInitiatedFocus = Self.termMeshShouldAllowPointerInitiatedWebViewFocus(
                window: self,
                webView: webView,
                event: currentEvent
            )
            if pointerInitiatedFocus {
#if DEBUG
                dlog(
                    "focus.guard allowPointerFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
            } else {
#if DEBUG
                dlog(
                    "focus.guard blockedFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
                return false
            }
        }
#if DEBUG
        if let responder,
           let webView = Self.termMeshOwningWebView(for: responder) {
            dlog(
                "focus.guard allowFirstResponder responder=\(String(describing: type(of: responder))) " +
                "window=\(ObjectIdentifier(self)) " +
                "web=\(ObjectIdentifier(webView)) " +
                "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(webView.debugPointerFocusAllowanceDepth)"
            )
        }
#endif
        return termMesh_makeFirstResponder(responder)
    }

    @objc func termMesh_sendEvent(_ event: NSEvent) {
        guard shouldSuppressWindowMoveForFolderDrag(window: self, event: event),
              let contentView = self.contentView else {
            termMesh_sendEvent(event)
            return
        }

        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        let hitView = contentView.hitTest(contentPoint)
        let previousMovableState = isMovable
        if previousMovableState {
            isMovable = false
        }

        #if DEBUG
        let hitDesc = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        dlog("window.sendEvent.folderDown suppress=1 hit=\(hitDesc) wasMovable=\(previousMovableState)")
        #endif

        termMesh_sendEvent(event)

        if previousMovableState {
            isMovable = previousMovableState
        }

        #if DEBUG
        dlog("window.sendEvent.folderDown restore nowMovable=\(isMovable)")
        #endif
    }

    @objc func termMesh_performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let frType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog("performKeyEquiv: \(Self.keyDescription(event)) fr=\(frType)")
#endif

        // When the terminal surface is the first responder, prevent SwiftUI's
        // hosting view from consuming key events via performKeyEquivalent.
        // After a browser panel (WKWebView) has been in the responder chain,
        // SwiftUI's internal focus system can get into a broken state where it
        // intercepts key events in the content view hierarchy, returns true
        // (claiming consumption), but never actually fires the action closure.
        //
        // For non-Command keys: bypass the view hierarchy entirely and send
        // directly to the terminal so arrow keys, Ctrl+N/P, etc. reach keyDown.
        //
        // For Command keys: bypass the SwiftUI content view hierarchy and
        // dispatch directly to the main menu. No SwiftUI view should be handling
        // Command shortcuts when the terminal is focused — the local event monitor
        // (handleCustomShortcut) already handles app-level shortcuts, and anything
        // remaining should be menu items.
        let firstResponderGhosttyView = termMeshOwningGhosttyView(for: self.firstResponder)
        if let ghosttyView = firstResponderGhosttyView {
            // If the IME is composing, don't intercept key events — let them flow
            // through normal AppKit event dispatch so the input method can process them.
            if ghosttyView.hasMarkedText() {
                return termMesh_performKeyEquivalent(with: event)
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                let result = ghosttyView.performKeyEquivalent(with: event)
#if DEBUG
                dlog("  → ghostty direct: \(result)")
#endif
                return result
            }

            // Preserve Ghostty's terminal font-size shortcuts (Cmd +/−/0) when
            // the terminal is focused. Otherwise our browser menu shortcuts can
            // consume the event even when no browser panel is focused.
            if shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode
            ) {
                ghosttyView.keyDown(with: event)
#if DEBUG
                dlog("zoom.shortcut stage=window.ghosttyKeyDownDirect event=\(Self.keyDescription(event)) handled=1")
#endif
                return true
            }
        }

        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            dlog("  → consumed by handleBrowserSurfaceKeyEquivalent")
#endif
            return true
        }

        // When the terminal is focused, skip the full NSWindow.performKeyEquivalent
        // (which walks the SwiftUI content view hierarchy) and dispatch Command-key
        // events directly to the main menu. This avoids the broken SwiftUI focus path.
        if firstResponderGhosttyView != nil,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           let mainMenu = NSApp.mainMenu {
            let consumedByMenu = mainMenu.performKeyEquivalent(with: event)
#if DEBUG
            if browserZoomShortcutTraceCandidate(
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode
            ) {
                dlog(
                    "zoom.shortcut stage=window.mainMenuBypass event=\(Self.keyDescription(event)) " +
                    "consumed=\(consumedByMenu ? 1 : 0) fr=GhosttyNSView"
                )
            }
#endif
            if !consumedByMenu {
                // Fall through to the original performKeyEquivalent path below.
            } else {
#if DEBUG
                dlog("  → consumed by mainMenu (bypassed SwiftUI)")
#endif
                return true
            }
        }

        let result = termMesh_performKeyEquivalent(with: event)
#if DEBUG
        if result { dlog("  → consumed by original performKeyEquivalent") }
#endif
        return result
    }

    internal static func keyDescription(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars = event.charactersIgnoringModifiers ?? "?"
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
    }

    static func termMeshOwningWebView(for responder: NSResponder) -> TermMeshWebView? {
        if let webView = responder as? TermMeshWebView {
            return webView
        }

        if let view = responder as? NSView,
           let webView = termMeshOwningWebView(for: view) {
            return webView
        }

        if let textView = responder as? NSTextView,
           let delegateView = textView.delegate as? NSView,
           let webView = termMeshOwningWebView(for: delegateView) {
            return webView
        }

        var current = responder.nextResponder
        while let next = current {
            if let webView = next as? TermMeshWebView {
                return webView
            }
            if let view = next as? NSView,
               let webView = termMeshOwningWebView(for: view) {
                return webView
            }
            current = next.nextResponder
        }

        return nil
    }

    static func termMeshOwningWebView(for view: NSView) -> TermMeshWebView? {
        if let webView = view as? TermMeshWebView {
            return webView
        }

        var current: NSView? = view.superview
        while let candidate = current {
            if let webView = candidate as? TermMeshWebView {
                return webView
            }
            current = candidate.superview
        }

        return nil
    }

    static func termMeshCurrentEvent(for _: NSWindow) -> NSEvent? {
#if DEBUG
        if let override = termMeshFirstResponderGuardCurrentEventOverride {
            return override
        }
#endif
        return NSApp.currentEvent
    }

    static func termMeshHitViewForCurrentEvent(in window: NSWindow, event: NSEvent) -> NSView? {
#if DEBUG
        if let override = termMeshFirstResponderGuardHitViewOverride {
            return override
        }
#endif
        return window.contentView?.hitTest(event.locationInWindow)
    }

    static func termMeshShouldAllowPointerInitiatedWebViewFocus(
        window: NSWindow,
        webView: TermMeshWebView,
        event: NSEvent?
    ) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            break
        default:
            return false
        }

        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return false
        }
        if let eventWindow = event.window, eventWindow !== window {
            return false
        }

        guard let hitView = termMeshHitViewForCurrentEvent(in: window, event: event),
              let hitWebView = termMeshOwningWebView(for: hitView) else {
            return false
        }
        return hitWebView === webView
    }
}
