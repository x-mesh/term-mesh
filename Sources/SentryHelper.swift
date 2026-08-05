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
            dlog("layout.census window=\(windowState) active=\(census["app_active"] ?? "?") views=\(census["views"] ?? "-") constraints=\(census["constraints"] ?? "-") hosting=\(census["hosting_views"] ?? "-") top_hosts=\(census["top_hosts"] ?? "-")")
        }
        #endif
    }

    /// Constraint/subview census across every visible window — bounded, iterative DFS.
    ///
    /// Deliberately not keyWindow/mainWindow: both are nil while the app is in the
    /// background, which is when these hangs are sampled. See the type doc.
    private static func computeCensus() -> [String: Any] {
        let allWindows = NSApp.windows
        let windows = allWindows.filter { $0.isVisible && $0.contentView != nil }
        guard !windows.isEmpty else {
            // Now distinguishable from the old blind "none": if the app really has no
            // visible window, windows_total says so.
            return [
                "window": "none",
                "app_active": NSApp.isActive,
                "windows_total": allWindows.count,
            ]
        }

        var constraintCount = 0
        var viewCount = 0
        var hostingCount = 0
        var maxDepth = 0
        var budget = 20_000  // node cap, shared across windows, to keep the walk cheap
        // Descendants are attributed to the outermost hosting view above them, so the
        // biggest SwiftUI subtree is identifiable by name rather than by guesswork.
        var hostSubtree: [String: Int] = [:]

        for window in windows {
            if budget <= 0 { break }
            guard let root = window.contentView else { continue }
            var stack: [(view: NSView, depth: Int, host: String?)] = [(root, 0, nil)]
            while let node = stack.popLast() {
                if budget <= 0 { break }
                budget -= 1
                viewCount += 1
                constraintCount += node.view.constraints.count
                if node.depth > maxDepth { maxDepth = node.depth }

                var host = node.host
                let cls = String(describing: type(of: node.view))
                if cls.contains("HostingView") || cls.contains("PlatformViewHost") {
                    hostingCount += 1
                    if host == nil { host = shortHostName(cls) }
                }
                if let host { hostSubtree[host, default: 0] += 1 }

                for sub in node.view.subviews {
                    stack.append((sub, node.depth + 1, host))
                }
            }
        }

        let topHosts = hostSubtree
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        return [
            "window": "\(windows.count) visible",
            "app_active": NSApp.isActive,
            "windows_total": allWindows.count,
            "constraints": constraintCount,
            "views": viewCount,
            "hosting_views": hostingCount,
            "max_depth": maxDepth,
            "truncated": budget <= 0,
            "top_hosts": topHosts.isEmpty ? "none" : topHosts,
        ]
    }

    /// SwiftUI spells a hosting view as `NSHostingView<ModifiedContent<…>>`, hundreds of
    /// characters of nested generics. The head carries the identity; keep that and drop
    /// the rest so the context value stays small enough to be worth reading.
    private static func shortHostName(_ cls: String) -> String {
        let head = cls.prefix(60)
        return head.count < cls.count ? head + "…" : String(head)
    }

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
