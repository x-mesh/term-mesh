import AppKit
import QuartzCore
import Sentry

/// Add a Sentry breadcrumb for user-action context in hang/crash reports.
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
    let crumb = Breadcrumb(level: .info, category: category)
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
}

/// Diagnostics for TERM-MESH-1D ("App Hanging: 5000 ms").
///
/// The captured hang sample is a CoreAutoLayout `NSISEngine` simplex solve
/// (`expression_merge`) reached through `AppKitPlatformViewHost.intrinsicLayoutTraits`
/// — i.e. SwiftUI measuring an AppKit-hosted view drives a pathologically expensive
/// constraint solve. The raw stack has no in-app view identity, so we cannot tell
/// *which* host or *how many* constraints were involved.
///
/// This attaches that missing context to the Sentry scope so the next AppHang event
/// carries it:
///   - `layout_census`: constraint/view/hosting-view counts of the key window,
///     refreshed on the main thread every 2s. Tests the "constraints accumulate over
///     a long session" hypothesis directly.
///   - `layout_hang`: snapshot written by a background watchdog when the main thread
///     stops ticking (> 3s), before Sentry's 5s AppHang fires.
///
/// Production-safe: bounded main-thread walk every 2s (no display link, microsecond
/// cost), one lightweight background timer. Never touches the view hierarchy off-main.
enum LayoutHangDiagnostics {
    private static let lock = NSLock()
    private static var lastCensus: [String: Any] = [:]
    private static var lastMainTickAt: CFTimeInterval = 0
    private static var lastMeasuredHost = "none"
    private static var stallReported = false

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
    }

    /// Constraint/subview census of the key window — bounded, iterative DFS.
    private static func computeCensus() -> [String: Any] {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let root = window.contentView else {
            return ["window": "none"]
        }

        var constraintCount = 0
        var viewCount = 0
        var hostingCount = 0
        var maxDepth = 0
        var budget = 20_000  // node cap to keep the walk cheap on huge hierarchies

        var stack: [(NSView, Int)] = [(root, 0)]
        while let (view, depth) = stack.popLast() {
            if budget <= 0 { break }
            budget -= 1
            viewCount += 1
            constraintCount += view.constraints.count
            if depth > maxDepth { maxDepth = depth }
            let cls = String(describing: type(of: view))
            if cls.contains("HostingView") || cls.contains("PlatformViewHost") {
                hostingCount += 1
            }
            for sub in view.subviews { stack.append((sub, depth + 1)) }
        }

        return [
            "constraints": constraintCount,
            "views": viewCount,
            "hosting_views": hostingCount,
            "max_depth": maxDepth,
            "truncated": budget <= 0,
        ]
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
        SentrySDK.configureScope { scope in
            scope.setContext(value: ctx, key: "layout_hang")
        }

        let crumb = Breadcrumb(level: .warning, category: "hang")
        crumb.message = "main-thread stall \(String(format: "%.1f", since))s; last_host=\(host)"
        crumb.data = ctx
        SentrySDK.addBreadcrumb(crumb)
    }
}
