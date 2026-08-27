import AppKit
import Darwin
import UserNotifications
import WebKit
import os

// MARK: - Process Tree Snapshot

/// Discovers process descendants through targeted libproc child queries, with
/// a Darwin process-table snapshot retained as a coverage-preserving fallback.
enum ProcessTreeSnapshot {
    typealias ParentPair = (pid: Int32, parentPID: Int32)

    /// Walk descendants from a targeted child lookup. Unlike a process-table
    /// snapshot, this scales with this app's own tree rather than every process
    /// on the machine. A child can disappear between the parent and child
    /// lookups. Because libproc cannot distinguish that exit from a query error,
    /// any failed lookup invalidates the targeted snapshot so callers can use
    /// the coverage-preserving full-table fallback.
    nonisolated static func descendantPIDs(
        of rootPID: Int32,
        childrenOf: (Int32) -> [Int32]?
    ) -> Set<Int32>? {
        var pending = [rootPID]
        var nextIndex = 0
        var visited = Set([rootPID])
        var descendants: Set<Int32> = []

        while nextIndex < pending.count {
            let parentPID = pending[nextIndex]
            nextIndex += 1
            guard let children = childrenOf(parentPID) else { return nil }
            for pid in children where pid > 0 && visited.insert(pid).inserted {
                descendants.insert(pid)
                pending.append(pid)
            }
        }
        return descendants
    }

    /// Query only one process's direct children through libproc. The function
    /// returns a PID count (not a byte count). Retry when the buffer fills so a
    /// burst of new children cannot silently truncate monitoring coverage.
    nonisolated static func childPIDs(
        of parentPID: Int32,
        initialCapacity: Int = 16,
        maximumCapacity: Int = 4_096
    ) -> [Int32]? {
        var capacity = max(1, min(initialCapacity, maximumCapacity))
        while capacity <= maximumCapacity {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let result = buffer.withUnsafeMutableBytes { bytes in
                proc_listchildpids(parentPID, bytes.baseAddress, Int32(bytes.count))
            }
            guard result >= 0 else { return nil }
            let count = Int(result)
            guard count <= buffer.count else { return nil }
            if count < buffer.count {
                return Array(buffer[..<count]).filter { $0 > 0 }
            }
            guard capacity < maximumCapacity else { return nil }
            capacity = min(capacity * 2, maximumCapacity)
        }
        return nil
    }

    nonisolated static func currentDescendantPIDs(of rootPID: Int32) -> Set<Int32>? {
        descendantPIDs(of: rootPID) { childPIDs(of: $0) }
    }

    nonisolated static func descendantPIDs(
        of rootPID: Int32,
        in processes: [ParentPair]
    ) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for process in processes where process.pid > 0 && process.pid != rootPID {
            children[process.parentPID, default: []].append(process.pid)
        }

        var pending = children[rootPID] ?? []
        var nextIndex = 0
        var descendants: Set<Int32> = []
        while nextIndex < pending.count {
            let pid = pending[nextIndex]
            nextIndex += 1
            guard descendants.insert(pid).inserted else { continue }
            pending.append(contentsOf: children[pid] ?? [])
        }
        return descendants
    }

    /// Returns nil if the kernel snapshot cannot be obtained. Callers retain
    /// their last known PID set instead of treating a failure as an empty tree.
    nonisolated static func currentParentPairs(maxAttempts: Int = 3) -> [ParentPair]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]

        for _ in 0..<maxAttempts {
            var requiredBytes = 0
            guard sysctl(&mib, u_int(mib.count), nil, &requiredBytes, nil, 0) == 0 else {
                return nil
            }

            // Processes can appear between the size query and the read. Leave
            // headroom and retry if the process table still outgrows it.
            let stride = MemoryLayout<kinfo_proc>.stride
            let capacity = max(1, requiredBytes / stride + 32)
            var entries = Array(repeating: kinfo_proc(), count: capacity)
            var actualBytes = entries.count * stride
            let result = entries.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &actualBytes, nil, 0)
            }
            if result == 0 {
                let count = min(entries.count, actualBytes / stride)
                return entries.prefix(count).map {
                    (pid: $0.kp_proc.p_pid, parentPID: $0.kp_eproc.e_ppid)
                }
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }
}

// MARK: - Dashboard Preset

enum DashboardPreset: String {
    case overview, teamOps, devOps, cost, mission
}

// MARK: - Agent Timeline

struct AgentTimelineEntry {
    let agentName: String
    let status: String  // idle, working, blocked, done
    let taskTitle: String?
    let startTime: Date
    var endTime: Date?
}

// MARK: - Agent Performance

struct AgentPerformance {
    let agentName: String
    var completedTasks: Int
    var totalDurationSecs: Double
    var avgDurationSecs: Double
    var fixAttempts: Int
    var tokensUsed: Int64
}

/// Panel event logs are append-only and usually unchanged between dashboard ticks.
/// Keep disk I/O and JSON parsing off the main actor, and reuse the parsed tail
/// until either the file size or modification time changes.
private final class PanelEventLogCache: @unchecked Sendable {
    static let shared = PanelEventLogCache()

    private struct Entry {
        let size: UInt64
        let modifiedAt: Date
        let events: [[String: Any]]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func events(path: String, limit: Int) -> [[String: Any]] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else { return [] }

        lock.lock()
        if let cached = entries[path], cached.size == size, cached.modifiedAt == modifiedAt {
            lock.unlock()
            return cached.events
        }
        lock.unlock()

        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)
        var events: [[String: Any]] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var event: [String: Any] = ["type": object["type"] as? String ?? "event"]
            if let seq = object["seq"] as? NSNumber { event["seq"] = seq.intValue }
            if let at = object["at"] as? String { event["at"] = at }
            if let model = object["model"] as? String { event["model"] = model }
            if let phase = object["phase"] as? String { event["phase"] = phase }
            if let text = object["text"] as? String { event["text"] = String(text.prefix(2000)) }
            if let bytes = object["bytes"] as? NSNumber { event["bytes"] = bytes.intValue }
            if let code = object["code"] as? NSNumber { event["code"] = code.intValue }
            if let ok = object["ok"] as? Bool { event["ok"] = ok }
            if let error = object["error"] as? String { event["error"] = String(error.prefix(200)) }
            events.append(event)
        }

        lock.lock()
        if entries.count >= 64, entries[path] == nil {
            entries.removeValue(forKey: entries.keys.first ?? path)
        }
        entries[path] = Entry(size: size, modifiedAt: modifiedAt, events: events)
        lock.unlock()
        return events
    }
}

/// Manages the term-mesh monitoring dashboard in a separate window.
///
/// Watch criteria: each terminal tab's **project root** (detected by .git, Cargo.toml, etc.)
/// is watched for file events. This maps 1:1 with the blue grouped sessions in the sidebar.
@MainActor
final class DashboardController: NSObject, WKNavigationDelegate {
    static let shared = DashboardController()

    /// Injected daemon service (defaults to singleton for backward compatibility).
    var daemon: any DaemonService = TermMeshDaemon.shared
    /// Injected notification service (defaults to singleton for backward compatibility).
    var notifications: any NotificationService = TerminalNotificationStore.shared

    private var window: NSWindow?
    private var webView: WKWebView?
    private var uiTimer: Timer?
    private var uiFetchInFlight = false
    private var uiFetchGeneration = 0
    private var trackingTimer: Timer?
    private var trackingSyncInFlight = false
    private var alertPollInFlight = false
    private var trackedPIDs: Set<Int32> = []
    private var messageHandler: DashboardMessageHandler?

    /// Project roots currently being watched — keyed by tab ID to avoid duplicates.
    private var watchedProjects: [UUID: String] = [:]
    private struct ProjectRootCacheEntry {
        let root: String
        let resolvedAt: Date
        let foundProjectMarker: Bool
    }
    private var projectRootCache: [String: ProjectRootCacheEntry] = [:]
    private let projectRootCacheTTL: TimeInterval = 60
    private let negativeProjectRootCacheTTL: TimeInterval = 3
    private struct FleetPayloadCacheEntry {
        let payload: [String: Any]
        let createdAt: Date
    }
    private var fleetPayloadCache: FleetPayloadCacheEntry?
    private let fleetPayloadCacheTTL: TimeInterval = 3

    /// PIDs that we've already sent a notification for (avoid spamming).
    private var notifiedAlertPIDs: Set<Int32> = []

    private let iso8601Formatter = ISO8601DateFormatter()
    /// Whether we've requested notification permission.
    private var notificationPermissionRequested = false

    // MARK: - Preset Mode State

    fileprivate var currentPreset: DashboardPreset = .overview
    /// When true, auto-focus is suppressed because the user manually selected a preset.
    fileprivate var userOverride: Bool = false

    // MARK: - Agent Timeline & Performance

    private var agentTimeline: [AgentTimelineEntry] = []
    /// Last known agent statuses keyed by agent name, used to detect status changes.
    private var lastAgentStatuses: [String: String] = [:]
    private var agentPerformanceCache: [String: AgentPerformance] = [:]

    /// Reference to the tab manager (set from AppDelegate.configure)
    weak var tabManager: TabManager? {
        didSet { startTracking() }
    }

    deinit {
        trackingTimer?.invalidate()
        uiTimer?.invalidate()
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

    /// Stop background tracking and clean up resources.
    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        trackingSyncInFlight = false
        projectRootCache.removeAll()
        fleetPayloadCache = nil
        notifiedAlertPIDs.removeAll()
        let daemon = self.daemon
        let paths = Set(watchedProjects.values)
        watchedProjects.removeAll()
        for path in paths {
            DispatchQueue.global(qos: .utility).async {
                daemon.unwatchPath(path)
            }
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
        // Keep handler as a property to prevent deallocation
        self.messageHandler = DashboardMessageHandler(controller: self)
        if let handler = self.messageHandler {
            config.userContentController.add(handler, name: "stopProcess")
            config.userContentController.add(handler, name: "resumeProcess")
            config.userContentController.add(handler, name: "setAutoStop")
            config.userContentController.add(handler, name: "teamTaskAction")
            config.userContentController.add(handler, name: "teamTaskCreate")
            config.userContentController.add(handler, name: "switchPreset")
            config.userContentController.add(handler, name: "focusAgentPane")
            config.userContentController.add(handler, name: "approveTask")
            config.userContentController.add(handler, name: "rejectTask")
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv

        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "dashboard") {
            let htmlURL = URL(fileURLWithPath: htmlPath)
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            let devPath = "/Users/jinwoo/work/project/term-mesh/Resources/dashboard/index.html"
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
        win.title = "Term-Mesh Dashboard"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        win.delegate = self
        self.window = win

        startUIPolling()
    }

    func toggleDashboard() {
        if window?.isVisible == true {
            closeDashboard()
        } else {
            showDashboard()
        }
    }

    func closeDashboard() {
        stopUIPolling()
        window?.close()
        window = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        messageHandler = nil
    }

    // MARK: - UI Polling (only when dashboard window is open)

    private func startUIPolling() {
        stopUIPolling()
        let generation = uiFetchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  generation == self.uiFetchGeneration,
                  self.window?.isVisible == true else { return }
            self.fetchAndPush()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchAndPush()
        }
    }

    private func stopUIPolling() {
        uiTimer?.invalidate()
        uiTimer = nil
        uiFetchGeneration &+= 1
        uiFetchInFlight = false
    }

    // MARK: - Tracking (always-on)

    private func syncTrackingState() {
        guard !trackingSyncInFlight else { return }
        trackingSyncInFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descendants = Self.discoverDescendantPIDs()
            DispatchQueue.main.async {
                guard let self else { return }
                self.trackingSyncInFlight = false
                if let descendants {
                    self.reconcileTrackedPIDs(descendants)
                }
                let projectRoots = self.resolveProjectRoots()
                self.watchTabProjects(projectRoots: projectRoots)
                self.syncSessionsToDaemon(projectRoots: projectRoots)
                self.syncTeamsToDaemon()
                // Budget Guard notifications are safety-critical and cannot wait
                // behind the dashboard's long, serial multi-RPC refresh.
                self.pollAlerts()
                self.deliverPendingInputs()
            }
        }
    }

    /// Push current session list to daemon so HTTP dashboard can show the session picker.
    /// All tabs are synced regardless of watch safety — this is metadata for the session picker.
    private func syncSessionsToDaemon(projectRoots: [UUID: String]) {
        guard let tabManager else { return }

        let notificationStore = self.notifications
        var sessions: [[String: Any]] = []
        for workspace in tabManager.tabs {
            let cwd = workspace.currentDirectory
            guard !cwd.isEmpty else { continue }

            let projectRoot = projectRoots[workspace.id] ?? cwd

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
            self.daemon.syncSessions(sessions)
        }
    }

    private func syncTeamsToDaemon() {
        // Keep the daemon sync authoritative. UI refreshes between these
        // three-second ticks reuse this payload instead of rebuilding it.
        let fleet = currentFleetPayload(forceRefresh: true)
        let payload = teamPayload(from: fleet)
        recordAgentTimeline(from: payload)
        computeAgentPerformance(from: payload)
        DispatchQueue.global(qos: .utility).async {
            self.daemon.syncTeams(payload)
        }
    }

    // MARK: - Agent Timeline Recording

    private func recordAgentTimeline(from payload: [String: Any]) {
        guard let teams = payload["teams"] as? [[String: Any]] else { return }
        let now = Date()
        for team in teams {
            guard let agents = team["agents"] as? [[String: Any]] else { continue }
            for agent in agents {
                guard let name = agent["name"] as? String else { continue }
                let status = agent["agent_state"] as? String ?? "idle"
                let taskTitle = agent["active_task_title"] as? String

                let lastStatus = lastAgentStatuses[name]
                if lastStatus != status {
                    // Close the previous entry for this agent
                    if let idx = agentTimeline.lastIndex(where: { $0.agentName == name && $0.endTime == nil }) {
                        agentTimeline[idx].endTime = now
                    }
                    // Open a new entry
                    agentTimeline.append(AgentTimelineEntry(
                        agentName: name,
                        status: status,
                        taskTitle: taskTitle,
                        startTime: now,
                        endTime: nil
                    ))
                    lastAgentStatuses[name] = status

                    // Cap at 100 entries
                    if agentTimeline.count > 100 {
                        agentTimeline.removeFirst(agentTimeline.count - 100)
                    }
                }
            }
        }
    }

    // MARK: - Agent Performance Computation

    private func computeAgentPerformance(from payload: [String: Any]) {
        guard let tasks = payload["tasks"] as? [[String: Any]] else { return }
        var stats: [String: AgentPerformance] = [:]

        for task in tasks {
            guard let assignee = task["assignee"] as? String, !assignee.isEmpty else { continue }
            let status = task["status"] as? String ?? ""

            if stats[assignee] == nil {
                stats[assignee] = AgentPerformance(
                    agentName: assignee,
                    completedTasks: 0,
                    totalDurationSecs: 0,
                    avgDurationSecs: 0,
                    fixAttempts: 0,
                    tokensUsed: -1  // -1 signals N/A (no per-agent token tracking available)
                )
            }

            if status == "completed" {
                stats[assignee]?.completedTasks += 1
                if let startedAt = task["started_at"] as? String,
                   let completedAt = task["completed_at"] as? String {
                    let fmt = iso8601Formatter
                    if let start = fmt.date(from: startedAt), let end = fmt.date(from: completedAt) {
                        let duration = end.timeIntervalSince(start)
                        stats[assignee]?.totalDurationSecs += duration
                    }
                }
            }

            // fix_attempts: use reassignment_count from task data as proxy
            if let fixes = task["reassignment_count"] as? Int {
                stats[assignee]?.fixAttempts += fixes
            }
            // tokens_used: not directly in task data; default 0
        }

        // Compute averages
        for key in stats.keys {
            guard var perf = stats[key], perf.completedTasks > 0 else { continue }
            perf.avgDurationSecs = perf.totalDurationSecs / Double(perf.completedTasks)
            stats[key] = perf
        }

        agentPerformanceCache = stats
    }

    // MARK: - Budget Guard Alerts

    /// Request notification permission (called once).
    private func requestNotificationPermission() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Logger.app.error("notification permission error: \(error, privacy: .public)")
            } else {
                Logger.app.info("notification permission: \(granted ? "granted" : "denied", privacy: .public)")
            }
        }
    }

    /// Poll monitor snapshot for alerts and send native notifications for new SIGSTOP events.
    private func pollAlerts() {
        guard !alertPollInFlight else { return }
        alertPollInFlight = true
        requestNotificationPermission()

        DispatchQueue.global(qos: .utility).async { [weak self, daemon = self.daemon] in
            let alerts: [[String: Any]]? = daemon.rpcCallRaw(method: "monitor.snapshot", params: [:])
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["alerts"] as? [[String: Any]] }

            DispatchQueue.main.async {
                guard let self else { return }
                self.alertPollInFlight = false
                if let alerts {
                    self.processAlerts(alerts)
                }
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
            Logger.app.info("Budget Guard notification: \(name, privacy: .public) (PID \(pid, privacy: .public)) stopped for \(kind, privacy: .public) threshold")
        }

        // Clean up notified PIDs for processes no longer in alerts
        let alertPIDs = Set(alerts.compactMap { ($0["pid"] as? Int).map { Int32($0) } })
        notifiedAlertPIDs = notifiedAlertPIDs.intersection(alertPIDs)
    }

    // MARK: - Pending Input Delivery (PTY injection)

    /// Poll the daemon for pending inputs and deliver them to the appropriate terminal panels.
    private func deliverPendingInputs() {
        guard let tabManager else { return }
        DispatchQueue.global(qos: .utility).async { [weak self, daemon = self.daemon] in
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
                        // Use sendIMEText for atomic text+Enter delivery:
                        // - PRESS+RELEASE pairs prevent key state ambiguity in TUI apps
                        // - Synchronous Return after text eliminates GCD timing races
                        let trimmed = text.replacingOccurrences(of: "[\\r\\n]+$", with: "", options: .regularExpression)
                        guard !trimmed.isEmpty else { continue }
                        panel.sendIMEText(trimmed, withReturn: true)
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
    private nonisolated static func discoverDescendantPIDs() -> Set<Int32>? {
        let appPID = ProcessInfo.processInfo.processIdentifier
        if let descendants = ProcessTreeSnapshot.currentDescendantPIDs(of: appPID) {
            return descendants
        }
        // libproc lookup failure is rare, but retaining the former full-table
        // implementation as a fallback avoids losing Budget Guard coverage.
        guard let processes = ProcessTreeSnapshot.currentParentPairs() else { return nil }
        return ProcessTreeSnapshot.descendantPIDs(of: appPID, in: processes)
    }

    /// Reconcile tracked PIDs with discovered descendants. Must be called on @MainActor.
    private func reconcileTrackedPIDs(_ allDescendants: Set<Int32>) {
        let daemon = self.daemon

        let newPIDs = allDescendants.subtracting(trackedPIDs)
        for pid in newPIDs {
            trackedPIDs.insert(pid)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard daemon.trackPID(pid) else {
                    // The daemon declined, so drop the optimistic record and
                    // let the next pass re-send it. Keeping it would make one
                    // refusal permanent: this set is the only thing deciding
                    // what gets sent, and a pid already in it never is again.
                    Task { @MainActor in self?.trackedPIDs.remove(pid) }
                    return
                }
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
    private func watchTabProjects(projectRoots: [UUID: String]) {
        var currentTabProjects: [UUID: String] = [:]

        for (tabID, projectRoot) in projectRoots {
            // Normalize and skip dangerous/broad paths. TermMeshDaemon repeats
            // this validation at the client boundary and term-meshd enforces it
            // again at the socket boundary.
            guard let safeProjectRoot = TermMeshDaemon.safeWatchPath(projectRoot) else { continue }

            currentTabProjects[tabID] = safeProjectRoot
        }

        let daemon = self.daemon

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

    /// Resolve each tab's project root once per tracking cycle. Results are cached
    /// briefly so stable tabs do not repeatedly traverse the same directory tree.
    private func resolveProjectRoots(now: Date = Date()) -> [UUID: String] {
        guard let tabManager else {
            projectRootCache.removeAll()
            return [:]
        }

        var roots: [UUID: String] = [:]
        var activeDirectories: Set<String> = []

        for workspace in tabManager.tabs {
            let cwd = workspace.currentDirectory
            guard !cwd.isEmpty else { continue }
            activeDirectories.insert(cwd)

            if let cached = projectRootCache[cwd],
               now.timeIntervalSince(cached.resolvedAt) < (
                   cached.foundProjectMarker ? projectRootCacheTTL : negativeProjectRootCacheTTL
               ) {
                roots[workspace.id] = cached.root
                continue
            }

            let detectedRoot = findProjectRoot(from: cwd)
            let root = detectedRoot ?? cwd
            projectRootCache[cwd] = ProjectRootCacheEntry(
                root: root,
                resolvedAt: now,
                foundProjectMarker: detectedRoot != nil
            )
            roots[workspace.id] = root
        }

        projectRootCache = projectRootCache.filter { activeDirectories.contains($0.key) }
        return roots
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

    // MARK: - Data Push (WKWebView only)

    private func fetchAndPush() {
        guard let webView, !uiFetchInFlight else { return }
        uiFetchInFlight = true
        let generation = uiFetchGeneration
        let fleetSnapshot = currentFleetPayload()

        DispatchQueue.global(qos: .utility).async {
            let daemon = self.daemon
            let monitorData = daemon.rpcCallRaw(method: "monitor.snapshot", params: [:])
            let monitorAlerts: [[String: Any]]? = monitorData.flatMap { raw in
                guard let data = raw.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return json["alerts"] as? [[String: Any]]
            }
            let watcherData = daemon.rpcCallRaw(method: "watcher.snapshot", params: [:])
            let sessionData = daemon.rpcCallRaw(method: "session.list", params: [:])
            let usageData = daemon.rpcCallRaw(method: "usage.snapshot", params: [:])
            let agentsData = daemon.rpcCallRaw(method: "agent.list", params: ["include_terminated": false])
            let tasksData = daemon.rpcCallRaw(method: "task.list", params: [:] as [String: Any])
            var fleet = fleetSnapshot
            if var runs = fleet["panel_runs"] as? [[String: Any]] {
                for index in runs.indices {
                    if let path = runs[index]["log_path"] as? String, !path.isEmpty {
                        runs[index]["events"] = PanelEventLogCache.shared.events(path: path, limit: 40)
                    }
                }
                fleet["panel_runs"] = runs
            }

            // Mission Control: drift-watch status + recent board rows per
            // watched team ({team_id: {enabled, healthy, …, recent[]}}).
            var watchMap: [String: Any] = [:]
            if let statusRaw = daemon.rpcCallRaw(method: "watch.status", params: [:]),
               let statusData = statusRaw.data(using: .utf8),
               let statusObj = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
               let statusResult = statusObj["result"] as? [String: Any],
               let watches = statusResult["watches"] as? [[String: Any]] {
                for st in watches.prefix(6) {
                    guard let teamId = st["team_id"] as? String else { continue }
                    var entry = st
                    if let boardRaw = daemon.rpcCallRaw(
                        method: "watch.board",
                        params: ["team_id": teamId, "limit": 10]
                    ),
                       let boardData = boardRaw.data(using: .utf8),
                       let boardObj = try? JSONSerialization.jsonObject(with: boardData) as? [String: Any],
                       let boardResult = boardObj["result"] as? [String: Any] {
                        entry["recent"] = boardResult["rows"] ?? []
                        entry["drift_count"] = boardResult["drift_count"] ?? 0
                    }
                    watchMap[teamId] = entry
                }
            }

            DispatchQueue.main.async {
                guard generation == self.uiFetchGeneration, webView === self.webView else { return }
                self.uiFetchInFlight = false
                if let monitorAlerts {
                    self.requestNotificationPermission()
                    self.processAlerts(monitorAlerts)
                }
                let teamPayload = self.teamPayload(from: fleet)
                let teamData = teamPayload["teams"] as? [[String: Any]] ?? []
                let teamTasks = teamPayload["tasks"] as? [[String: Any]] ?? []
                let teamAttention = teamPayload["attention"] as? [[String: Any]] ?? []
                let instanceMeta = teamPayload["instance"] as? [String: Any] ?? [:]

                if let json = monitorData {
                    webView.evaluateJavaScript("updateMonitor(\(json));") { _, error in
                        if let error { Logger.app.error("dashboard monitor error: \(error, privacy: .public)") }
                    }
                }
                if let json = watcherData {
                    webView.evaluateJavaScript("updateHeatmap(\(json));") { _, error in
                        if let error { Logger.app.error("dashboard heatmap error: \(error, privacy: .public)") }
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
                if let teamsJson = Self.dashboardJSONString(teamData) {
                    webView.evaluateJavaScript("if(window.updateTeamAgents)updateTeamAgents(\(teamsJson));") { _, _ in }
                }
                if let attentionJson = Self.dashboardJSONString(teamAttention) {
                    webView.evaluateJavaScript("if(window.updateTeamAttention)updateTeamAttention(\(attentionJson));") { _, _ in }
                }
                if let tasksJson = Self.dashboardJSONString(teamTasks) {
                    webView.evaluateJavaScript("if(window.updateTeamTasks)updateTeamTasks(\(tasksJson));") { _, _ in }
                }

                // Task flow DAG data
                let taskFlowPayload: [[String: Any]] = teamTasks.compactMap { task in
                    guard let id = task["id"] as? String else { return nil }
                    return [
                        "id": id,
                        "title": task["title"] as? String ?? "",
                        "status": task["status"] as? String ?? "assigned",
                        "assignee": task["assignee"] as? String ?? "",
                        "dependsOn": task["depends_on"] as? [String] ?? [],
                    ]
                }
                if let flowJson = Self.dashboardJSONString(taskFlowPayload) {
                    webView.evaluateJavaScript("if(window.updateTaskFlow)updateTaskFlow(\(flowJson));") { _, _ in }
                }

                if let instanceJson = Self.dashboardJSONString(instanceMeta) {
                    webView.evaluateJavaScript("if(window.updateInstanceStatus)updateInstanceStatus(\(instanceJson));") { _, _ in }
                }

                // Agent timeline
                let timelinePayload = self.agentTimeline.map { entry -> [String: Any] in
                    var dict: [String: Any] = [
                        "agentName": entry.agentName,
                        "status": entry.status,
                        "startTime": Int(entry.startTime.timeIntervalSince1970 * 1000),
                    ]
                    if let title = entry.taskTitle { dict["taskTitle"] = title }
                    if let end = entry.endTime { dict["endTime"] = Int(end.timeIntervalSince1970 * 1000) }
                    return dict
                }
                if let timelineJson = Self.dashboardJSONString(timelinePayload) {
                    webView.evaluateJavaScript("if(window.updateTimeline)updateTimeline(\(timelineJson));") { _, _ in }
                }

                // Agent performance
                let perfPayload = Array(self.agentPerformanceCache.values).map { p -> [String: Any] in
                    [
                        "agentName": p.agentName,
                        "completedTasks": p.completedTasks,
                        "totalDurationSecs": p.totalDurationSecs,
                        "avgDurationSecs": p.avgDurationSecs,
                        "fixAttempts": p.fixAttempts,
                        "tokensUsed": p.tokensUsed,
                    ]
                }
                if let perfJson = Self.dashboardJSONString(perfPayload) {
                    webView.evaluateJavaScript("if(window.updatePerformance)updatePerformance(\(perfJson));") { _, _ in }
                }

                // Mission Control: fleet aggregate (teams × agents × tasks ×
                // attention × approvals + panel_runs) + daemon watch enrichment.
                fleet["watch"] = watchMap
                if let fleetJson = Self.dashboardJSONString(fleet) {
                    webView.evaluateJavaScript("if(window.updateFleet)updateFleet(\(fleetJson));") { _, _ in }
                }

                // Context-based auto-focus (skip if user manually selected a preset)
                if !self.userOverride {
                    let hasTeams = !teamData.isEmpty
                    let hasAttention = !teamAttention.isEmpty
                    let focusTarget: String
                    if hasAttention {
                        focusTarget = "attention"
                    } else if hasTeams {
                        focusTarget = "teamOps"
                    } else {
                        focusTarget = "overview"
                    }
                    if let focusJson = Self.dashboardJSONString(focusTarget) {
                        webView.evaluateJavaScript("if(window.setAutoFocus)setAutoFocus(\(focusJson));") { _, _ in }
                    }
                }
            }
        }
    }

    private static func dashboardJSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private func pushInstanceStatus() {
        guard let webView else { return }
        let instanceMeta = currentFleetPayload()["instance"] as? [String: Any] ?? [:]
        guard let instanceJson = Self.dashboardJSONString(instanceMeta) else { return }
        webView.evaluateJavaScript("if(window.updateInstanceStatus)updateInstanceStatus(\(instanceJson));") { _, _ in }
    }

    /// Mission Control Review Queue — deliver the `team.task.approve`/
    /// `team.task.reject` result back to the dashboard. `raw` is already a
    /// single-line JSON string from `v2Ok`/`v2Error` (id-less since these are
    /// called in-process, not over the socket), so it can be interpolated
    /// directly as a JS object literal — same technique `fetchAndPush`
    /// already uses for daemon RPC results.
    fileprivate func pushApprovalResult(_ raw: String) {
        invalidateTeamPayloadCache()
        guard let webView else { return }
        webView.evaluateJavaScript("if(window.onFleetApprovalResult)onFleetApprovalResult(\(raw));") { _, error in
            if let error { Logger.app.error("dashboard approval result push error: \(error, privacy: .public)") }
        }
        fetchAndPush()
    }

    private func currentFleetPayload(forceRefresh: Bool = false) -> [String: Any] {
        let now = Date()
        if !forceRefresh,
           let cached = fleetPayloadCache,
           now.timeIntervalSince(cached.createdAt) < fleetPayloadCacheTTL {
            return cached.payload
        }
        let payload = TeamOrchestrator.shared.fleetState()
        fleetPayloadCache = FleetPayloadCacheEntry(payload: payload, createdAt: now)
        return payload
    }

    private func teamPayload(from fleet: [String: Any]) -> [String: Any] {
        [
            "teams": fleet["teams"] ?? [],
            "tasks": fleet["tasks"] ?? [],
            "attention": fleet["attention"] ?? [],
            "instance": fleet["instance"] ?? [:],
        ]
    }

    private func invalidateTeamPayloadCache() {
        fleetPayloadCache = nil
    }

    fileprivate func handleTeamTaskAction(teamName: String, taskId: String, action: String, note: String?) {
        switch action {
        case "start":
            _ = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: "in_progress"
            )
            if let tabManager {
                _ = TeamOrchestrator.shared.dispatchTaskToAssignee(
                    teamName: teamName,
                    taskId: taskId,
                    tabManager: tabManager
                )
            }
        case "block":
            _ = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: "blocked",
                blockedReason: note
            )
        case "review":
            _ = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: "review_ready",
                reviewSummary: note
            )
        case "done":
            _ = TeamOrchestrator.shared.updateTask(
                teamName: teamName,
                taskId: taskId,
                status: "completed",
                result: note
            )
        case "reassign":
            _ = TeamOrchestrator.shared.reassignTask(
                teamName: teamName,
                taskId: taskId,
                assignee: note
            )
            if let tabManager {
                _ = TeamOrchestrator.shared.dispatchTaskToAssignee(
                    teamName: teamName,
                    taskId: taskId,
                    tabManager: tabManager
                )
            }
        case "unblock":
            _ = TeamOrchestrator.shared.unblockTask(
                teamName: teamName,
                taskId: taskId
            )
            if let tabManager {
                _ = TeamOrchestrator.shared.dispatchTaskToAssignee(
                    teamName: teamName,
                    taskId: taskId,
                    tabManager: tabManager
                )
            }
        default:
            return
        }
        invalidateTeamPayloadCache()
        fetchAndPush()
    }

    fileprivate func handleTeamTaskCreate(teamName: String, title: String, assignee: String?) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        _ = TeamOrchestrator.shared.createTask(
            teamName: teamName,
            title: trimmedTitle,
            assignee: assignee,
            priority: 2,
            createdBy: "dashboard"
        )
        invalidateTeamPayloadCache()
        fetchAndPush()
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
        guard let daemon = controller?.daemon else { return }
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
        case "teamTaskAction":
            guard
                let body = message.body as? [String: Any],
                let teamName = body["team_name"] as? String,
                let taskId = body["task_id"] as? String,
                let action = body["action"] as? String
            else { return }
            let note = body["note"] as? String
            Task { @MainActor in
                self.controller?.handleTeamTaskAction(teamName: teamName, taskId: taskId, action: action, note: note)
            }
        case "teamTaskCreate":
            guard
                let body = message.body as? [String: Any],
                let teamName = body["team_name"] as? String,
                let title = body["title"] as? String
            else { return }
            let assignee = body["assignee"] as? String
            Task { @MainActor in
                self.controller?.handleTeamTaskCreate(teamName: teamName, title: title, assignee: assignee)
            }
        case "switchPreset":
            guard let presetStr = message.body as? String,
                  let preset = DashboardPreset(rawValue: presetStr) else { return }
            Task { @MainActor in
                self.controller?.currentPreset = preset
                self.controller?.userOverride = true
            }
        case "focusAgentPane":
            // Mission Control deep link: matrix row click → jump to the
            // agent's pane. User-initiated (a click in the dashboard), so
            // mutating in-app focus is within the socket focus policy. Only
            // available in the WKWebView dashboard — the HTTP dashboard has
            // no message handler and hides the affordance.
            guard let dict = message.body as? [String: Any],
                  let workspaceStr = dict["workspace_id"] as? String,
                  let tabId = UUID(uuidString: workspaceStr) else { return }
            let panelId = (dict["panel_id"] as? String).flatMap(UUID.init(uuidString:))
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                self.controller?.tabManager?.focusTabFromNotification(tabId, surfaceId: panelId)
            }
        case "approveTask":
            // Mission Control Review Queue — Approve. Runs the same
            // git-kit-backed flow as `tm-agent task finish-worktree`
            // (TerminalController.asyncTeamTaskApprove); WKWebView-only,
            // since the subprocess runs in this app process.
            guard let dict = message.body as? [String: Any],
                  let teamName = dict["team_name"] as? String,
                  let taskId = dict["task_id"] as? String else { return }
            Task { @MainActor in
                let raw = await TerminalController.shared.asyncTeamTaskApprove(
                    params: ["team_name": teamName, "task_id": taskId], id: nil
                )
                self.controller?.pushApprovalResult(raw)
            }
        case "rejectTask":
            guard let dict = message.body as? [String: Any],
                  let teamName = dict["team_name"] as? String,
                  let taskId = dict["task_id"] as? String else { return }
            var params: [String: Any] = ["team_name": teamName, "task_id": taskId]
            if let reason = dict["reason"] as? String { params["reason"] = reason }
            if let reassignTo = dict["reassign_to"] as? String { params["reassign_to"] = reassignTo }
            Task { @MainActor in
                let raw = await TerminalController.shared.asyncTeamTaskReject(params: params, id: nil)
                self.controller?.pushApprovalResult(raw)
            }
        default:
            break
        }
    }
}

// MARK: - NSWindowDelegate

extension DashboardController: NSWindowDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushInstanceStatus()
        fetchAndPush()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            stopUIPolling()
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil
            window = nil
        }
    }
}
