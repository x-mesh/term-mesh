import Foundation
import AppKit
import Combine
import Network

/// Phase 1: detect whether term-mesh was installed via the `x-mesh/tap/term-mesh` cask
/// and, if so, periodically check whether a newer cask version is available.
/// No UI yet — exposes an ObservableObject so Phase 2 can bind to it.

enum BrewSelfUpdateState: Equatable {
    case unsupported                                    // brew binary not found, or term-mesh not installed via cask
    case idle
    case checking
    case upToDate
    case outdated(installed: String, latest: String)
    case downloading(installed: String, latest: String, message: String)
    case readyToInstall(installed: String, latest: String)
    case error(message: String)
}

struct BrewOutdatedInfo: Equatable, Sendable {
    let installed: String
    let latest: String
}

struct BrewRunError: Error, CustomStringConvertible, Sendable {
    let message: String
    var description: String { message }
}

@MainActor
final class BrewSelfUpdateViewModel: ObservableObject {
    @Published private(set) var state: BrewSelfUpdateState = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastTapRefreshAt: Date?
    @Published private(set) var brewBinaryPath: String?
    @Published private(set) var caskToken: String = "term-mesh"

    /// True for any state that reflects "an update has been detected" (outdated, downloading, ready).
    var hasPendingUpdate: Bool {
        switch state {
        case .outdated, .downloading, .readyToInstall: return true
        default: return false
        }
    }

    var isOutdated: Bool {
        if case .outdated = state { return true }
        return false
    }

    var isReadyToInstall: Bool {
        if case .readyToInstall = state { return true }
        return false
    }

    var outdatedInfo: BrewOutdatedInfo? {
        switch state {
        case let .outdated(installed, latest),
             let .readyToInstall(installed, latest):
            return BrewOutdatedInfo(installed: installed, latest: latest)
        case let .downloading(installed, latest, _):
            return BrewOutdatedInfo(installed: installed, latest: latest)
        default:
            return nil
        }
    }

    fileprivate func update(state: BrewSelfUpdateState) { self.state = state }
    fileprivate func update(brewBinaryPath: String?) { self.brewBinaryPath = brewBinaryPath }
    fileprivate func recordCheck(at date: Date) { self.lastCheckedAt = date }
    fileprivate func recordTapRefresh(at date: Date) { self.lastTapRefreshAt = date }
}

@MainActor
final class BrewSelfUpdater {
    nonisolated static let defaultCaskToken = "term-mesh"
    nonisolated static let defaultOutdatedInterval: TimeInterval = 30 * 60      // 30 min
    nonisolated static let defaultRefreshInterval: TimeInterval = 6 * 60 * 60   // 6 h
    nonisolated static let initialDelay: TimeInterval = 60                       // 60 s after start

    enum Defaults {
        static let enabled = "BrewSelfUpdateEnabled"
        static let outdatedInterval = "BrewSelfUpdateOutdatedInterval"
        static let refreshInterval = "BrewSelfUpdateRefreshInterval"
    }

    let viewModel: BrewSelfUpdateViewModel
    private let caskToken: String
    private let timerQueue = DispatchQueue(label: "term-mesh.brew-self-update.timer", qos: .utility)
    private var outdatedTimer: DispatchSourceTimer?
    private var refreshTimer: DispatchSourceTimer?
    private var startWorkItem: DispatchWorkItem?
    private var isRunningCheck = false
    private var isRunningRefresh = false
    private var isRunningFetch = false
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true
    /// Cached brew binary path captured once at init; reused on background tasks
    /// so we don't have to hop back to the main actor before spawning a process.
    private let cachedBrewPath: String?

    init(caskToken: String = BrewSelfUpdater.defaultCaskToken,
         viewModel: BrewSelfUpdateViewModel? = nil) {
        self.caskToken = caskToken
        self.viewModel = viewModel ?? BrewSelfUpdateViewModel()
        let path = Self.locateBrewBinary()
        self.cachedBrewPath = path
        self.viewModel.update(brewBinaryPath: path)
        UserDefaults.standard.register(defaults: [
            Defaults.enabled: true,
            Defaults.outdatedInterval: Self.defaultOutdatedInterval,
            Defaults.refreshInterval: Self.defaultRefreshInterval,
        ])
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        pathMonitor.start(queue: timerQueue)
    }

    deinit {
        outdatedTimer?.cancel()
        refreshTimer?.cancel()
        pathMonitor.cancel()
    }

    /// Start periodic polling. Safe to call multiple times.
    func start() {
        guard UserDefaults.standard.bool(forKey: Defaults.enabled) else {
            UpdateLogStore.shared.append("brew self-update disabled by user defaults")
            viewModel.update(state: .unsupported)
            return
        }
        guard cachedBrewPath != nil else {
            UpdateLogStore.shared.append("brew self-update: brew binary not found")
            viewModel.update(state: .unsupported)
            return
        }
        guard isInstalledViaCask() else {
            UpdateLogStore.shared.append("brew self-update: term-mesh cask not installed")
            viewModel.update(state: .unsupported)
            return
        }
        scheduleInitialCheck()
        scheduleOutdatedTimer()
        scheduleRefreshTimer()
    }

    /// Force an outdated check immediately. Used by Phase 2's "Check now" button.
    func checkNow() { runOutdatedCheck() }

    /// Force a tap refresh (`brew update`) followed by an outdated check.
    func refreshNow() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runTapRefresh()
            await MainActor.run { self.runOutdatedCheck() }
        }
    }

    /// True only when the running app bundle lives under `/Applications/` —
    /// prevents wrecking a DerivedData / DEV install with a `brew upgrade`.
    var isApplicationsInstall: Bool { Self.isApplicationsInstall }

    nonisolated static var isApplicationsInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
    }

    /// True if all preconditions for a one-click upgrade are satisfied:
    /// running from /Applications, brew + cask installed, and a fetched
    /// update is waiting in the cache.
    var canTriggerRestartAndUpgrade: Bool {
        guard isApplicationsInstall else { return false }
        guard cachedBrewPath != nil else { return false }
        if case .readyToInstall = viewModel.state { return true }
        return false
    }

    /// Confirm with the user, spawn the helper detached, and quit the app.
    /// The helper waits for the process to exit, runs `brew upgrade --cask --force`,
    /// and relaunches the new bundle.
    @discardableResult
    func triggerInstallAndRestart() -> Bool {
        guard canTriggerRestartAndUpgrade else {
            UpdateLogStore.shared.append("brew self-update: triggerInstall blocked — preconditions unmet")
            return false
        }
        guard case let .readyToInstall(installed, latest) = viewModel.state else { return false }
        guard let helper = Self.bundledHelperPath() else {
            UpdateLogStore.shared.append("brew self-update: helper script missing from bundle")
            viewModel.update(state: .error(message: "Update helper not found in app bundle."))
            return false
        }
        guard let brew = cachedBrewPath else { return false }

        let alert = NSAlert()
        alert.messageText = "Update term-mesh from \(installed) to \(latest)?"
        alert.informativeText = "term-mesh will quit, install the update via Homebrew, and relaunch automatically."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart and Update")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            UpdateLogStore.shared.append("brew self-update: user cancelled restart-and-update")
            return false
        }

        let appPath = Bundle.main.bundlePath
        UpdateLogStore.shared.append("brew self-update: spawning helper to upgrade \(installed) → \(latest)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper, brew, caskToken, appPath]
        // Detach by giving the child a fresh stdio + no pipes back to us.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            UpdateLogStore.shared.append("brew self-update: helper spawn failed — \(error.localizedDescription)")
            viewModel.update(state: .error(message: "Failed to launch update helper: \(error.localizedDescription)"))
            return false
        }

        // Give the helper a moment to start its `pgrep` wait loop before we exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
        return true
    }

    /// Locate the bundled helper script, falling back to a DEBUG-time
    /// repo-relative path so debug builds without the script bundled
    /// still work for development.
    nonisolated static func bundledHelperPath() -> String? {
        if let url = Bundle.main.url(forResource: "brew-upgrade-helper", withExtension: "sh"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        return nil
    }

    // MARK: - Scheduling

    private func scheduleInitialCheck() {
        startWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.runOutdatedCheck() }
        startWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.initialDelay, execute: item)
    }

    private func scheduleOutdatedTimer() {
        outdatedTimer?.cancel()
        let interval = max(60, UserDefaults.standard.double(forKey: Defaults.outdatedInterval))
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.runOutdatedCheck() }
        }
        outdatedTimer = timer
        timer.resume()
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.cancel()
        let interval = max(60 * 60, UserDefaults.standard.double(forKey: Defaults.refreshInterval))
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            Task.detached(priority: .utility) { await self?.runTapRefresh() }
        }
        refreshTimer = timer
        timer.resume()
    }

    // MARK: - Commands

    private func runOutdatedCheck() {
        guard !isRunningCheck else { return }
        guard let brew = cachedBrewPath else { return }
        let cask = caskToken
        isRunningCheck = true
        viewModel.update(state: .checking)
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.runBrewOutdated(brew: brew, cask: cask)
            await self?.applyOutdatedResult(result)
        }
    }

    private func applyOutdatedResult(_ result: Result<BrewOutdatedInfo?, BrewRunError>) {
        isRunningCheck = false
        viewModel.recordCheck(at: Date())
        switch result {
        case .success(let info):
            if let info {
                // Skip re-fetch if the version we already prepared matches.
                if case let .readyToInstall(_, latest) = viewModel.state, latest == info.latest {
                    UpdateLogStore.shared.append("brew self-update: still ready to install \(info.latest)")
                    return
                }
                if case let .downloading(_, latest, _) = viewModel.state, latest == info.latest {
                    return
                }
                viewModel.update(state: .outdated(installed: info.installed, latest: info.latest))
                UpdateLogStore.shared.append("brew self-update: outdated installed=\(info.installed) latest=\(info.latest)")
                triggerFetchIfNeeded(info: info)
            } else {
                viewModel.update(state: .upToDate)
                UpdateLogStore.shared.append("brew self-update: up-to-date")
            }
        case .failure(let err):
            // Don't clobber readyToInstall on a transient outdated-check failure.
            if case .readyToInstall = viewModel.state {
                UpdateLogStore.shared.append("brew self-update: outdated check failed but keeping readyToInstall — \(err.message)")
                return
            }
            viewModel.update(state: .error(message: err.message))
            UpdateLogStore.shared.append("brew self-update: outdated check failed — \(err.message)")
        }
    }

    // MARK: - Fetch

    private func triggerFetchIfNeeded(info: BrewOutdatedInfo) {
        guard !isRunningFetch else { return }
        guard isOnline else {
            UpdateLogStore.shared.append("brew self-update: skipping fetch — offline")
            return
        }
        guard let brew = cachedBrewPath else { return }
        isRunningFetch = true
        viewModel.update(state: .downloading(installed: info.installed, latest: info.latest, message: "Downloading update…"))
        UpdateLogStore.shared.append("brew self-update: fetching cask \(caskToken) for \(info.latest)")
        let cask = caskToken
        let started = Date()
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.runBrewFetch(brew: brew, cask: cask)
            await self?.applyFetchResult(result, info: info, startedAt: started)
        }
    }

    private func applyFetchResult(_ result: Result<Void, BrewRunError>,
                                  info: BrewOutdatedInfo,
                                  startedAt: Date) {
        isRunningFetch = false
        let duration = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
        switch result {
        case .success:
            viewModel.update(state: .readyToInstall(installed: info.installed, latest: info.latest))
            UpdateLogStore.shared.append("brew self-update: fetch ok \(info.latest) in \(duration)s — ready to install")
        case .failure(let err):
            viewModel.update(state: .error(message: err.message))
            UpdateLogStore.shared.append("brew self-update: fetch failed in \(duration)s — \(err.message)")
        }
    }

    private func runTapRefresh() async {
        if isRunningRefresh { return }
        isRunningRefresh = true
        defer { isRunningRefresh = false }
        guard let brew = cachedBrewPath else { return }
        let online = isOnline
        guard online else {
            UpdateLogStore.shared.append("brew self-update: skipping `brew update` — offline")
            return
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            UpdateLogStore.shared.append("brew self-update: skipping `brew update` — Low Power Mode")
            return
        }
        let started = Date()
        let result = await Task.detached(priority: .utility) {
            Self.runBrewUpdate(brew: brew)
        }.value
        UpdateLogStore.shared.append("brew self-update: `brew update` \(result) duration=\(String(format: "%.1f", -started.timeIntervalSinceNow))s")
        viewModel.recordTapRefresh(at: Date())
    }

    // MARK: - Detection

    private func isInstalledViaCask() -> Bool {
        Self.caskroomPath(for: caskToken) != nil
    }

    private static func caskroomPath(for token: String) -> URL? {
        let candidates = [
            "/opt/homebrew/Caskroom/\(token)",
            "/usr/local/Caskroom/\(token)",
        ]
        for path in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func locateBrewBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Process runners

    /// Runs `brew outdated --cask --json=v2 <token>` and parses the result.
    /// Returns nil if the cask is up to date, an info struct if outdated.
    fileprivate nonisolated static func runBrewOutdated(brew: String, cask: String) -> Result<BrewOutdatedInfo?, BrewRunError> {
        let result = runProcess(executable: brew,
                                arguments: ["outdated", "--cask", "--json=v2", cask],
                                timeout: 30)
        switch result {
        case .failure(let err):
            return .failure(err)
        case .success(let output):
            guard let data = output.data(using: String.Encoding.utf8) else {
                return .failure(BrewRunError(message: "non-utf8 output"))
            }
            do {
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let casks = root["casks"] as? [[String: Any]] else {
                    return .failure(BrewRunError(message: "unexpected json structure"))
                }
                guard let entry = casks.first(where: { ($0["name"] as? String) == cask }) else {
                    return .success(nil)
                }
                let installed: String = {
                    if let arr = entry["installed_versions"] as? [String], let last = arr.last { return last }
                    if let s = entry["installed_version"] as? String { return s }
                    return "unknown"
                }()
                let latest = (entry["current_version"] as? String) ?? "unknown"
                return .success(BrewOutdatedInfo(installed: installed, latest: latest))
            } catch {
                return .failure(BrewRunError(message: "json parse: \(error.localizedDescription)"))
            }
        }
    }

    /// Runs `brew update`. Returns a status string suitable for logging.
    fileprivate nonisolated static func runBrewUpdate(brew: String) -> String {
        switch runProcess(executable: brew, arguments: ["update"], timeout: 180) {
        case .success: return "exit=0"
        case .failure(let err): return err.message
        }
    }

    /// Runs `brew fetch --cask <token>` to populate the cache without installing.
    /// Safe to call while the app is running.
    fileprivate nonisolated static func runBrewFetch(brew: String, cask: String) -> Result<Void, BrewRunError> {
        switch runProcess(executable: brew, arguments: ["fetch", "--cask", cask], timeout: 600) {
        case .success: return .success(())
        case .failure(let err): return .failure(err)
        }
    }

    /// Wraps Process with stdout capture and a hard timeout.
    private nonisolated static func runProcess(executable: String,
                                               arguments: [String],
                                               timeout: TimeInterval) -> Result<String, BrewRunError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Keep the parent env but force noninteractive defaults so brew never prompts.
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_COLOR"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure(BrewRunError(message: "spawn: \(error.localizedDescription)"))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                return .failure(BrewRunError(message: "timed out after \(Int(timeout))s"))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stdout = String(data: stdoutData, encoding: String.Encoding.utf8) ?? ""
        let stderr = String(data: stderrData, encoding: String.Encoding.utf8) ?? ""

        if process.terminationStatus != 0 {
            let snippet = stderr.isEmpty ? stdout : stderr
            let trimmed = snippet.split(separator: "\n").prefix(3).joined(separator: " ")
            return .failure(BrewRunError(message: "exit=\(process.terminationStatus) \(trimmed)"))
        }
        return .success(stdout)
    }
}
