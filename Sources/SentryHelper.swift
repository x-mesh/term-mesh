import AppKit
import QuartzCore
import Sentry
#if DEBUG
import Bonsplit  // dlog
#endif

/// Add a Sentry breadcrumb for user-action context in hang/crash reports.
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
    let crumb = Breadcrumb(level: .info, category: category)
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
}

/// Diagnostics for TERM-MESH-1D ("App Hanging: 5000 ms").
///
/// Hang samples land inside a layout pass with no in-app view identity in the stack,
/// so we cannot tell from the stack alone *which* host or *how many* constraints were
/// involved. This attaches that to the Sentry scope so the next AppHang event carries
/// it:
///   - `layout_census`: constraint/view/hosting-view counts across the visible windows,
///     refreshed on the main thread every 2s, plus the largest SwiftUI hosting subtrees
///     by name. Tests the "it accumulates over a long session" hypothesis directly.
///   - `layout_hang`: snapshot written by a background watchdog when the main thread
///     stops ticking (> 3s), before Sentry's 5s AppHang fires.
///
/// The first version of this census walked `NSApp.keyWindow ?? NSApp.mainWindow`, and
/// **both are nil whenever the app is not frontmost.** Every one of the 1654 events it
/// rode along on — 0.151.0 through 0.173.0, four months — therefore carried
/// `window: "none"` and nothing else: it never once counted anything. These hangs are
/// sampled while the app is in the background, which is exactly when that guard fails.
/// Walk every visible window instead, and record `app_active` so a future "none" can be
/// told apart from "the app really had no windows".
///
/// `last_measured_host` has the same shape of problem in reverse: only
/// `DraggableFolderNSView` calls `markHostMeasure`, so "none" means "not that one view",
/// not "no host was measured". SwiftUI's own `NSHostingView.layout` cannot be marked from
/// here — it is Apple's class — so the census names hosting views by their generic
/// parameter instead, which is what actually identifies the SwiftUI root inside.
///
/// Production-safe: bounded main-thread walk every 2s (no display link, microsecond
/// cost), one lightweight background timer. Never touches the view hierarchy off-main.
enum LayoutHangDiagnostics {
    private static let lock = NSLock()
    private static var lastCensus: [String: Any] = [:]
    private static var lastMainTickAt: CFTimeInterval = 0
    private static var lastMeasuredHost = "none"
    private static var stallReported = false
    #if DEBUG
    private static var lastLoggedWindowState = ""
    #endif

    private static var sampleTimer: DispatchSourceTimer?
    private static var watchdogTimer: DispatchSourceTimer?
    private static var screenObserver: NSObjectProtocol?
    /// Keyed by the owning `TabManager`. ContentView keeps the mounted set in
    /// view state, so it reports the count here whenever that set changes.
    private static var mountedWorkspaceCounts: [ObjectIdentifier: Int] = [:]

    /// Call once after `SentrySDK.start`, on the main thread.
    static func start() {
        guard sampleTimer == nil else { return }

        lock.lock(); lastMainTickAt = CACurrentMediaTime(); lock.unlock()

        // Main-thread sampler: refresh census + heartbeat every 2s.
        let sampler = DispatchSource.makeTimerSource(queue: .main)
        sampler.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        sampler.setEventHandler { sampleOnMain() }
        sampler.resume()
        sampleTimer = sampler

        // Background watchdog: detect a stalled main thread (likely inside a layout
        // pass) and enrich the Sentry scope before the AppHang event fires.
        let queue = DispatchQueue(label: "com.termmesh.layout-watchdog", qos: .utility)
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        watchdog.setEventHandler { checkStall() }
        watchdog.resume()
        watchdogTimer = watchdog

        // Every 1D event sampled so far starts in AppKit's display-reconfiguration
        // handler, so record when the screen set or scale changed.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            let summary = MainActor.assumeIsolated {
                LayoutCensusTally.screenSummary(
                    scales: NSScreen.screens.map(\.backingScaleFactor),
                    appActive: NSApp.isActive
                )
            }
            sentryBreadcrumb("screen.parameters.changed", category: "hang", data: summary)
        }
    }

    /// Called by ContentView whenever its mounted workspace set changes.
    static func noteMountedWorkspaceCount(_ count: Int, for tabManager: TabManager) {
        lock.lock(); mountedWorkspaceCounts[ObjectIdentifier(tabManager)] = count; lock.unlock()
    }

    /// Cheap hook for AppKit hosts that SwiftUI measures (called on the main thread
    /// from `intrinsicContentSize`). Records the most recently measured host so the
    /// watchdog can name it if the main thread freezes mid-measure.
    @inline(__always)
    static func markHostMeasure(_ label: @autoclosure () -> String) {
        let value = label()
        lock.lock(); lastMeasuredHost = value; lock.unlock()
    }

    // MARK: - Main thread

    private static func sampleOnMain() {
        let census = computeCensus()
        let now = CACurrentMediaTime()
        lock.lock()
        lastCensus = census
        lastMainTickAt = now
        stallReported = false
        let host = lastMeasuredHost
        lock.unlock()

        var ctx = census
        ctx["last_measured_host"] = host
        SentrySDK.configureScope { scope in
            scope.setContext(value: ctx, key: "layout_census")
        }

        #if DEBUG
        // Only when the window state flips. Logging every 2s sample would trip
        // DebugEventLog's rate breaker and swallow the lines worth reading.
        let windowState = String(describing: census["window"] ?? "none")
        if windowState != lastLoggedWindowState {
            lastLoggedWindowState = windowState
            dlog("layout.census window=\(windowState) active=\(census["app_active"] ?? "?") views=\(census["views"] ?? "-") constraints=\(census["constraints"] ?? "-") hosting=\(census["hosting_views"] ?? "-") top_hosts=\(census["top_hosts"] ?? "-") views_by_window=\(census["views_by_window"] ?? "-") hidden_subtree_views=\(census["hidden_subtree_views"] ?? "-") portal_views=\(census["portal_views"] ?? "-") portal_terminals=\(census["portal_terminals"] ?? "-")/\(census["portal_terminals_hidden"] ?? "-") workspaces=\(census["workspaces"] ?? "-")/\(census["mounted_workspaces"] ?? "-")")
        }
        #endif
    }

    /// Constraint/subview census across every visible window — bounded, iterative DFS.
    ///
    /// Deliberately not keyWindow/mainWindow: both are nil while the app is in the
    /// background, which is when these hangs are sampled. See the type doc.
    private static func computeCensus() -> [String: Any] {
        let startedAt = CACurrentMediaTime()
        let allWindows = NSApp.windows
        let windows = allWindows.filter { $0.isVisible && $0.contentView != nil }
        var census: [String: Any]
        if windows.isEmpty {
            // Now distinguishable from the old blind "none": if the app really has no
            // visible window, windows_total says so.
            census = [
                "window": "none",
                "app_active": NSApp.isActive,
                "windows_total": allWindows.count,
            ]
        } else {
            var tally = LayoutCensusTally()
            var budget = 20_000  // node cap, shared across windows, to keep the walk cheap
            for window in windows {
                guard let root = window.contentView else { continue }
                LayoutCensusTally.walk(
                    root: root,
                    windowKey: "\(window.windowNumber):\(String(describing: type(of: window)))",
                    budget: &budget,
                    into: &tally,
                    isTerminalHost: { $0 is GhosttySurfaceScrollView }
                )
                if budget <= 0 { break }
            }
            census = tally.contextFields()
            census["window"] = "\(windows.count) visible"
            census["app_active"] = NSApp.isActive
            census["windows_total"] = allWindows.count
            census["truncated"] = budget <= 0
        }

        // The sampler's timer fires on the main queue.
        let (portal, workspaceCounts) = MainActor.assumeIsolated {
            (TerminalWindowPortalRegistry.censusRoots(), collectWorkspaceCounts())
        }
        // Walked separately so the content-view fields stay comparable with events
        // from earlier releases, which never counted the portal.
        var portalTally = LayoutCensusTally()
        var portalBudget = 20_000
        for root in portal.roots {
            LayoutCensusTally.walk(
                root: root,
                windowKey: "portal",
                budget: &portalBudget,
                into: &portalTally,
                isTerminalHost: { $0 is GhosttySurfaceScrollView }
            )
            if portalBudget <= 0 { break }
        }
        census.merge(portalTally.portalFields(entries: portal.entries, truncated: portalBudget <= 0)) { _, new in new }
        census.merge(workspaceCounts.contextFields()) { _, new in new }
        // The census runs on the main thread every 2 s; this keeps its own cost visible.
        census["census_ms"] = (CACurrentMediaTime() - startedAt) * 1_000
        return census
    }

    @MainActor
    private static func collectWorkspaceCounts() -> LayoutCensusWorkspaceCounts {
        var counts = LayoutCensusWorkspaceCounts()
        guard let appDelegate = AppDelegate.shared else { return counts }
        let managers = appDelegate.mainWindowContexts.values.map(\.tabManager)
        let liveOwners = Set(managers.map { ObjectIdentifier($0) })
        lock.lock()
        mountedWorkspaceCounts = mountedWorkspaceCounts.filter { liveOwners.contains($0.key) }
        let mounted = mountedWorkspaceCounts
        lock.unlock()
        for manager in managers {
            counts.add(
                workspaces: manager.tabs.count,
                mountedWorkspaces: mounted[ObjectIdentifier(manager)] ?? 0,
                panes: manager.tabs.reduce(0) { $0 + $1.bonsplitController.allPaneIds.count },
                surfaces: manager.tabs.reduce(0) { $0 + $1.panels.count }
            )
        }
        return counts
    }

    #if DEBUG
    /// The census the main-thread sampler last produced. Readable off-main, so a
    /// socket query never waits on the thread whose layout it describes.
    static func latestCensusSnapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return lastCensus
    }
    #endif

    // MARK: - Background watchdog

    private static func checkStall() {
        let now = CACurrentMediaTime()
        lock.lock()
        let lastTick = lastMainTickAt
        let since = now - lastTick
        let alreadyReported = stallReported
        let census = lastCensus
        let host = lastMeasuredHost
        let isStalled = lastTick > 0 && since > 3 && !alreadyReported
        if isStalled { stallReported = true }
        lock.unlock()

        guard isStalled else { return }

        var ctx = census
        ctx["stall_seconds"] = String(format: "%.1f", since)
        ctx["last_measured_host"] = host
        // No census refresh here: the main thread is the thing that is stuck. These
        // counts are from the last sample before the stall, so `stall_seconds` doubles
        // as their age.
        SentrySDK.configureScope { scope in
            scope.setContext(value: ctx, key: "layout_hang")
        }

        let crumb = Breadcrumb(level: .warning, category: "hang")
        crumb.message = "main-thread stall \(String(format: "%.1f", since))s; last_host=\(host)"
        crumb.data = ctx
        SentrySDK.addBreadcrumb(crumb)
    }
}

/// Counts gathered by the census walk, kept apart from AppKit window enumeration so
/// the arithmetic can be tested on plain view trees.
struct LayoutCensusTally {
    var views = 0
    var constraints = 0
    var hostingViews = 0
    var maxDepth = 0
    /// Terminal hosts inside the walked windows, and those hidden themselves or by an
    /// ancestor. Hidden terminals still sit in the hierarchy AppKit lays out.
    var terminalHosts = 0
    var hiddenTerminalHosts = 0
    /// Every view at or below a hidden view. Tests whether the 1D trees are large
    /// because of content nobody can see.
    var hiddenSubtreeViews = 0
    var hostSubtree: [String: Int] = [:]
    /// Keyed by window number and class rather than the hosting view's name: the
    /// name is a 60-character prefix that every main window shares.
    var viewsByWindow: [String: Int] = [:]

    static func walk(
        root: NSView,
        windowKey: String,
        budget: inout Int,
        into tally: inout LayoutCensusTally,
        isTerminalHost: (NSView) -> Bool
    ) {
        var windowViews = 0
        defer { tally.viewsByWindow[windowKey, default: 0] += windowViews }
        var stack: [(view: NSView, depth: Int, host: String?, hidden: Bool)] = [(root, 0, nil, false)]
        while let node = stack.popLast() {
            if budget <= 0 { break }
            budget -= 1
            tally.views += 1
            windowViews += 1
            tally.constraints += node.view.constraints.count
            if node.depth > tally.maxDepth { tally.maxDepth = node.depth }

            let hidden = node.hidden || node.view.isHidden
            if hidden { tally.hiddenSubtreeViews += 1 }
            if isTerminalHost(node.view) {
                tally.terminalHosts += 1
                if hidden { tally.hiddenTerminalHosts += 1 }
            }

            var host = node.host
            // This runs on every node up to the budget. Building a demangled
            // Swift type name per node and then calling String.contains -
            // which resolves to Foundation's locale-aware search - was 44% of
            // this census in main-thread profiles. The raw class name matches
            // the same two markers, allocates nothing, and only the rare
            // hosting node pays for the readable name.
            let rawName = class_getName(type(of: node.view))
            if strstr(rawName, "HostingView") != nil
                || strstr(rawName, "PlatformViewHost") != nil {
                tally.hostingViews += 1
                if host == nil {
                    host = shortHostName(String(describing: type(of: node.view)))
                }
            }
            if let host { tally.hostSubtree[host, default: 0] += 1 }

            for sub in node.view.subviews {
                stack.append((sub, node.depth + 1, host, hidden))
            }
        }
    }

    func contextFields() -> [String: Any] {
        let topHosts = Self.topEntries(hostSubtree, limit: 3)
        let byWindow = Self.topEntries(viewsByWindow, limit: 5)
        return [
            "constraints": constraints,
            "views": views,
            "hosting_views": hostingViews,
            "max_depth": maxDepth,
            "top_hosts": topHosts.isEmpty ? "none" : topHosts,
            "views_by_window": byWindow.isEmpty ? "none" : byWindow,
            "hidden_subtree_views": hiddenSubtreeViews,
        ]
    }

    /// Fields for a walk of the terminal portal host views.
    func portalFields(entries: Int, truncated: Bool) -> [String: Any] {
        [
            "portal_entries": entries,
            "portal_views": views,
            "portal_constraints": constraints,
            "portal_hidden_subtree_views": hiddenSubtreeViews,
            "portal_terminals": terminalHosts,
            "portal_terminals_hidden": hiddenTerminalHosts,
            "portal_truncated": truncated,
        ]
    }

    /// Largest first, ties by key, so two samples of the same tree read the same.
    static func topEntries(_ counts: [String: Int], limit: Int) -> String {
        counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    static func screenSummary(scales: [CGFloat], appActive: Bool) -> [String: Any] {
        [
            "screens": scales.count,
            "scales": scales.map { String(format: "%.1f", Double($0)) }.joined(separator: ","),
            "app_active": appActive,
        ]
    }

    /// SwiftUI spells a hosting view as `NSHostingView<ModifiedContent<…>>`, hundreds of
    /// characters of nested generics. The head carries the identity; keep that and drop
    /// the rest so the context value stays small enough to be worth reading.
    static func shortHostName(_ cls: String) -> String {
        let head = cls.prefix(60)
        return head.count < cls.count ? head + "…" : String(head)
    }
}

/// Workspace and pane totals across every main window's `TabManager`.
struct LayoutCensusWorkspaceCounts {
    var workspaces = 0
    var mountedWorkspaces = 0
    var panes = 0
    var surfaces = 0

    mutating func add(workspaces: Int, mountedWorkspaces: Int, panes: Int, surfaces: Int) {
        self.workspaces += workspaces
        self.mountedWorkspaces += mountedWorkspaces
        self.panes += panes
        self.surfaces += surfaces
    }

    func contextFields() -> [String: Any] {
        [
            "workspaces": workspaces,
            "mounted_workspaces": mountedWorkspaces,
            "panes": panes,
            "surfaces": surfaces,
        ]
    }
}
