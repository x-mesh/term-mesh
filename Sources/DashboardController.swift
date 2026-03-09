import AppKit
import UserNotifications
import WebKit

/// Manages the term-mesh monitoring dashboard in a separate window.
///
/// Watch criteria: each terminal tab's **project root** (detected by .git, Cargo.toml, etc.)
/// is watched for file events. This maps 1:1 with the blue grouped sessions in the sidebar.
@MainActor
final class DashboardController: NSObject, WKNavigationDelegate {
    static let shared = DashboardController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var uiTimer: Timer?
    private var trackingTimer: Timer?
    private var trackedPIDs: Set<Int32> = []

    /// Project roots currently being watched — keyed by tab ID to avoid duplicates.
    private var watchedProjects: [UUID: String] = [:]

    /// PIDs that we've already sent a notification for (avoid spamming).
    private var notifiedAlertPIDs: Set<Int32> = []
    /// Whether we've requested notification permission.
    private var notificationPermissionRequested = false

    /// Reference to the tab manager (set from AppDelegate.configure)
    weak var tabManager: TabManager? {
        didSet { startTracking() }
    }

    // MARK: - Always-On Tracking

    /// Start background tracking — runs always, regardless of dashboard window.
    func startTracking() {
        guard trackingTimer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.syncTrackingState()
        }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.syncTrackingState()
        }
    }

    // MARK: - Dashboard Window

    func showDashboard() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Register native message handlers for process control
        let handler = DashboardMessageHandler(controller: self)
        config.userContentController.add(handler, name: "stopProcess")
        config.userContentController.add(handler, name: "resumeProcess")
        config.userContentController.add(handler, name: "setAutoStop")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv

        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "dashboard") {
            let htmlURL = URL(fileURLWithPath: htmlPath)
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            let devPath = "/Users/jinwoo/work/project/cmux/Resources/dashboard/index.html"
            if FileManager.default.fileExists(atPath: devPath) {
                let url = URL(fileURLWithPath: devPath)
                wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "term-mesh Dashboard"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        win.delegate = self
        self.window = win

        startUIPolling()
    }

    func closeDashboard() {
        stopUIPolling()
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: - UI Polling (only when dashboard window is open)

    private func startUIPolling() {
        stopUIPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchAndPush()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchAndPush()
        }
    }

    private func stopUIPolling() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    // MARK: - Tracking (always-on)

    private func syncTrackingState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descendants = Self.discoverDescendantPIDs()
            DispatchQueue.main.async {
                self?.reconcileTrackedPIDs(descendants)
                self?.watchTabProjects()
                self?.syncSessionsToDaemon()
                self?.pollAlerts()
                self?.deliverPendingInputs()
            }
        }
    }

    /// Push current session list to daemon so HTTP dashboard can show the session picker.
    /// All tabs are synced regardless of watch safety — this is metadata for the session picker.
    private func syncSessionsToDaemon() {
        guard let tabManager else { return }

        let notificationStore = TerminalNotificationStore.shared
        var sessions: [[String: Any]] = []
        for workspace in tabManager.tabs {
            let cwd = workspace.currentDirectory
            guard !cwd.isEmpty else { continue }

            let projectRoot = findProjectRoot(from: cwd) ?? cwd

            var session: [String: Any] = [
                "id": workspace.id.uuidString,
                "name": workspace.title,
                "project_path": projectRoot,
            ]
            if let branch = workspace.gitBranch?.branch {
                session["git_branch"] = branch
            }

            // Agent notification state
            let hasUnread = notificationStore.unreadCount(forTabId: workspace.id) > 0
            session["agent_state"] = hasUnread ? "waiting" : "idle"
            if let latest = notificationStore.latestNotification(forTabId: workspace.id), !latest.isRead {
                session["notification_title"] = latest.title
                session["notification_ts"] = Int(latest.createdAt.timeIntervalSince1970 * 1000)
            }

            sessions.append(session)
        }

        DispatchQueue.global(qos: .utility).async {
            TermMeshDaemon.shared.syncSessions(sessions)
        }
    }

    // MARK: - Budget Guard Alerts

    /// Request notification permission (called once).
    private func requestNotificationPermission() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("[term-mesh] notification permission error: \(error)")
            } else {
                print("[term-mesh] notification permission: \(granted ? "granted" : "denied")")
            }
        }
    }

    /// Poll monitor snapshot for alerts and send native notifications for new SIGSTOP events.
    private func pollAlerts() {
        requestNotificationPermission()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let daemon = TermMeshDaemon.shared
            guard let response = daemon.rpcCallRaw(method: "monitor.snapshot", params: [:]),
                  let data = response.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let alerts = json["alerts"] as? [[String: Any]] else { return }

            DispatchQueue.main.async {
                self?.processAlerts(alerts)
            }
        }
    }

    /// Process alerts from monitor snapshot and send notifications.
    private func processAlerts(_ alerts: [[String: Any]]) {
        for alert in alerts {
            guard let pid = alert["pid"] as? Int,
                  let action = alert["action"] as? String,
                  action == "stopped" else { continue }

            let pid32 = Int32(pid)
            guard !notifiedAlertPIDs.contains(pid32) else { continue }
            notifiedAlertPIDs.insert(pid32)

            let name = alert["name"] as? String ?? "unknown"
            let kind = alert["kind"] as? String ?? "resource"
            let value = alert["value"] as? Double ?? 0
            let threshold = alert["threshold"] as? Double ?? 0

            let content = UNMutableNotificationContent()
            content.title = "Budget Guard: Process Stopped"
            if kind == "cpu" {
                content.body = "\(name) (PID \(pid)) stopped — CPU \(String(format: "%.1f", value))% exceeded \(String(format: "%.0f", threshold))% threshold"
            } else {
                let valueMB = value / 1024 / 1024
                let threshMB = threshold / 1024 / 1024
                content.body = "\(name) (PID \(pid)) stopped — Memory \(String(format: "%.0f", valueMB))MB exceeded \(String(format: "%.0f", threshMB))MB threshold"
            }
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "budget-guard-\(pid)-\(kind)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
            print("[term-mesh] Budget Guard notification: \(name) (PID \(pid)) stopped for \(kind) threshold")
        }

        // Clean up notified PIDs for processes no longer in alerts
        let alertPIDs = Set(alerts.compactMap { ($0["pid"] as? Int).map { Int32($0) } })
        notifiedAlertPIDs = notifiedAlertPIDs.intersection(alertPIDs)
    }

    // MARK: - Pending Input Delivery (PTY injection)

    /// Poll the daemon for pending inputs and deliver them to the appropriate terminal panels.
    private func deliverPendingInputs() {
        guard let tabManager else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let daemon = TermMeshDaemon.shared
            guard let json = daemon.rpcCallRaw(method: "input.poll", params: [:] as [String: Any]),
                  let data = json.data(using: .utf8),
                  let inputs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return }
            guard !inputs.isEmpty else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                for input in inputs {
                    guard let sessionId = input["session_id"] as? String,
                          let text = input["text"] as? String else { continue }
                    if let panel = self.findTerminalPanel(agentSessionId: sessionId) {
                        // Send text via key events (same mechanism as TeamOrchestrator).
                        // Using sendInputText instead of sendText ensures text arrives
                        // through the same input channel as the Return key event.
                        let trimmed = text.replacingOccurrences(of: "[\\r\\n]+$", with: "", options: .regularExpression)
                        guard !trimmed.isEmpty else { continue }
                        panel.sendInputText(trimmed)
                        // Send Return after 0.3s delay to give TUIs (Claude Code,
                        // kiro-cli, etc.) time to process text before Enter.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            panel.sendSurfaceKeyPress(keycode: 36) // kVK_Return
                        }
                    }
                }
            }
        }
    }

    /// Find the TerminalPanel bound to a given agent session ID.
    private func findTerminalPanel(agentSessionId: String) -> TerminalPanel? {
        guard let tabManager else { return nil }
        for workspace in tabManager.tabs {
            for (_, panel) in workspace.panels {
                if let terminal = panel as? TerminalPanel,
                   terminal.agentSessionId == agentSessionId {
                    return terminal
                }
            }
        }
        return nil
    }

    // MARK: - Process Discovery

    /// Discover all descendant PIDs of this app. Safe to call from any thread (no shared state).
    private static func discoverDescendantPIDs() -> Set<Int32> {
        let appPID = ProcessInfo.processInfo.processIdentifier

        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "pid,ppid"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var children: [Int32: [Int32]] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            children[ppid, default: []].append(pid)
        }

        var queue: [Int32] = children[appPID] ?? []
        var allDescendants: Set<Int32> = []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard !allDescendants.contains(pid) else { continue }
            allDescendants.insert(pid)
            if let grandchildren = children[pid] {
                queue.append(contentsOf: grandchildren)
            }
        }

        return allDescendants
    }

    /// Reconcile tracked PIDs with discovered descendants. Must be called on @MainActor.
    private func reconcileTrackedPIDs(_ allDescendants: Set<Int32>) {
        let daemon = TermMeshDaemon.shared

        let newPIDs = allDescendants.subtracting(trackedPIDs)
        for pid in newPIDs {
            trackedPIDs.insert(pid)
            DispatchQueue.global(qos: .utility).async {
                daemon.trackPID(pid)
            }
        }

        let deadPIDs = trackedPIDs.subtracting(allDescendants)
        for pid in deadPIDs {
            trackedPIDs.remove(pid)
            DispatchQueue.global(qos: .utility).async {
                daemon.untrackPID(pid)
            }
        }
    }

    // MARK: - Project Watch (per terminal tab)

    /// Watch the **project root** of each terminal tab's working directory.
    /// Each tab = one watched project. If a tab's directory changes, the watch updates.
    private func watchTabProjects() {
        guard let tabManager else { return }

        var currentTabProjects: [UUID: String] = [:]

        for workspace in tabManager.tabs {
            let cwd = workspace.currentDirectory
            guard !cwd.isEmpty else { continue }

            // Find the project root from the tab's current directory
            let projectRoot = findProjectRoot(from: cwd) ?? cwd

            // Skip dangerous/broad paths
            guard isSafeToWatch(projectRoot) else { continue }

            currentTabProjects[workspace.id] = projectRoot
        }

        let daemon = TermMeshDaemon.shared

        // Watch new projects
        for (tabId, projectRoot) in currentTabProjects {
            if watchedProjects[tabId] != projectRoot {
                // If this tab was watching a different path, unwatch the old one
                if let oldPath = watchedProjects[tabId] {
                    // Only unwatch if no other tab is watching the same path
                    let otherTabsWatchingSame = watchedProjects
                        .filter { $0.key != tabId && $0.value == oldPath }
                        .count > 0
                    if !otherTabsWatchingSame {
                        DispatchQueue.global(qos: .utility).async {
                            daemon.unwatchPath(oldPath)
                        }
                    }
                }
                watchedProjects[tabId] = projectRoot
                DispatchQueue.global(qos: .utility).async {
                    daemon.watchPath(projectRoot)
                }
            }
        }

        // Unwatch closed tabs
        let closedTabIds = Set(watchedProjects.keys).subtracting(Set(currentTabProjects.keys))
        for tabId in closedTabIds {
            if let oldPath = watchedProjects.removeValue(forKey: tabId) {
                let otherTabsWatchingSame = watchedProjects.values.contains(oldPath)
                if !otherTabsWatchingSame {
                    DispatchQueue.global(qos: .utility).async {
                        daemon.unwatchPath(oldPath)
                    }
                }
            }
        }
    }

    /// Walk up from `directory` looking for project markers (.git, Cargo.toml, etc.)
    private func findProjectRoot(from directory: String) -> String? {
        let markers = [".git", "Package.swift", "Cargo.toml", "package.json", "go.mod",
                       "pyproject.toml", "Makefile", ".xcodeproj"]
        var current = directory
        let fm = FileManager.default

        while current != "/" && current != "" {
            for marker in markers {
                let path = (current as NSString).appendingPathComponent(marker)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir) {
                    return current
                }
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Reject paths that are too broad to watch recursively.
    private func isSafeToWatch(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dangerous = ["/", "/Users", "/tmp", "/var", "/private", home]
        return !dangerous.contains(path)
    }

    // MARK: - Data Push (WKWebView only)

    private func fetchAndPush() {
        guard let webView else { return }

        DispatchQueue.global(qos: .utility).async {
            let daemon = TermMeshDaemon.shared
            let monitorData = daemon.rpcCallRaw(method: "monitor.snapshot", params: [:])
            let watcherData = daemon.rpcCallRaw(method: "watcher.snapshot", params: [:])
            let sessionData = daemon.rpcCallRaw(method: "session.list", params: [:])
            let usageData = daemon.rpcCallRaw(method: "usage.snapshot", params: [:])
            let agentsData = daemon.rpcCallRaw(method: "agent.list", params: ["include_terminated": false])
            let tasksData = daemon.rpcCallRaw(method: "task.list", params: [:] as [String: Any])

            DispatchQueue.main.async {
                if let json = monitorData {
                    webView.evaluateJavaScript("updateMonitor(\(json));") { _, error in
                        if let error { print("[dashboard] monitor error: \(error)") }
                    }
                }
                if let json = watcherData {
                    webView.evaluateJavaScript("updateHeatmap(\(json));") { _, error in
                        if let error { print("[dashboard] heatmap error: \(error)") }
                    }
                }
                if let json = sessionData {
                    webView.evaluateJavaScript("if(window.updateAgentStatus)updateAgentStatus(\(json));") { _, _ in }
                }
                if let json = usageData {
                    webView.evaluateJavaScript("if(window.updateUsage)updateUsage(\(json));") { _, _ in }
                }
                if let json = agentsData {
                    webView.evaluateJavaScript("if(window.updateAgents)updateAgents(\(json));") { _, _ in }
                }
                if let json = tasksData {
                    webView.evaluateJavaScript("if(window.updateTasks)updateTasks(\(json));") { _, _ in }
                }
            }
        }
    }
}

// MARK: - WKWebView Message Handler

/// Handles messages from the dashboard WKWebView for process control.
/// Must be a separate class (non-@MainActor) to conform to WKScriptMessageHandler.
private class DashboardMessageHandler: NSObject, WKScriptMessageHandler {
    weak var controller: DashboardController?

    init(controller: DashboardController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let daemon = TermMeshDaemon.shared
        switch message.name {
        case "stopProcess":
            if let pid = message.body as? Int {
                DispatchQueue.global(qos: .utility).async {
                    let _ = daemon.stopProcess(pid: Int32(pid))
                }
            }
        case "resumeProcess":
            if let pid = message.body as? Int {
                DispatchQueue.global(qos: .utility).async {
                    let _ = daemon.resumeProcess(pid: Int32(pid))
                }
            }
        case "setAutoStop":
            if let enabled = message.body as? Bool {
                DispatchQueue.global(qos: .utility).async {
                    daemon.setAutoStop(enabled: enabled)
                }
            }
        default:
            break
        }
    }
}

// MARK: - NSWindowDelegate

extension DashboardController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            stopUIPolling()
            webView = nil
            window = nil
        }
    }
}
