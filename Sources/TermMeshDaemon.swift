import Foundation
import Combine
import os
import Security

/// Client for communicating with the term-meshd Rust daemon over Unix socket.
/// Uses JSON-RPC 2.0 (line-delimited) protocol.
final class TermMeshDaemon: ObservableObject {
    static let shared = TermMeshDaemon()

    private var daemonProcess: Process?
    /// Whether a daemon is currently WANTED on this machine. `startDaemon`
    /// intends one; an explicit `stopDaemon` that actually proceeds does
    /// not. Read by the subscribe loop's watchdog, which must never respawn
    /// a daemon the user just stopped from Settings. Locked because start,
    /// stop, and the watchdog run on three different threads.
    private let intentLock = NSLock()
    private var daemonRunIntendedStorage = false
    var daemonRunIntended: Bool {
        get {
            intentLock.lock()
            defer { intentLock.unlock() }
            return daemonRunIntendedStorage
        }
        set {
            intentLock.lock()
            defer { intentLock.unlock() }
            daemonRunIntendedStorage = newValue
        }
    }
    private let queue = DispatchQueue(label: "term-mesh.daemon", qos: .utility)
    /// Telemetry reads that nothing waits on, kept off `queue`.
    ///
    /// `queue` is the daemon's control path — spawn, adopt, restart, stop — and
    /// it is serial. An RPC on it blocks for as long as the socket takes to
    /// answer, up to the receive timeout, so a periodic read landing there puts
    /// a recurring multi-second occupant in front of lifecycle work. The peer
    /// host stats push samples every couple of seconds, which is exactly that
    /// shape. Nothing sequences these reads against a spawn or a stop, so they
    /// do not belong in the same lane; concurrent is right for them, since each
    /// opens its own short-lived socket.
    private let telemetryQueue = DispatchQueue(
        label: "term-mesh.daemon.telemetry", qos: .utility, attributes: .concurrent
    )
    private var nextId: Int = 1
    /// Guards `nextId` alone.
    ///
    /// A lock rather than `queue.sync`: `rpcCall` runs both ON `queue` (from
    /// the lifecycle blocks) and off it, and a `sync` back onto a serial queue
    /// from within that queue deadlocks. The counter needs mutual exclusion,
    /// not the daemon's ordering.
    private let idLock = NSLock()

    // Cancellation token for the events.subscribe streaming Task.
    private var eventSubscriptionTask: Task<Void, Never>?

    /// Whether worktree sandboxing is enabled for new tabs.
    @Published var worktreeEnabled: Bool = false

    // MARK: - Dashboard Settings (UserDefaults)

    /// Whether the HTTP dashboard is enabled.
    static let dashboardEnabledKey = "termMeshDashboardEnabled"
    /// Whether to bind to localhost only (true) or 0.0.0.0 (false).
    static let dashboardLocalhostOnlyKey = "termMeshDashboardLocalhostOnly"
    /// Dashboard port.
    static let dashboardPortKey = "termMeshDashboardPort"
    /// Dashboard password (empty = no auth).
    static let dashboardPasswordKey = "termMeshDashboardPassword"

    var isDashboardEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.dashboardEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.dashboardEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardEnabledKey) }
    }

    var isLocalhostOnly: Bool {
        get {
            // Default to true (localhost only) for security — 0.0.0.0 requires explicit opt-in
            if UserDefaults.standard.object(forKey: Self.dashboardLocalhostOnlyKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.dashboardLocalhostOnlyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardLocalhostOnlyKey) }
    }

    var dashboardPort: Int {
        get {
            let port = UserDefaults.standard.integer(forKey: Self.dashboardPortKey)
            return port > 0 ? port : 9876
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dashboardPortKey) }
    }

    var dashboardPassword: String {
        get { Self.keychainLoadPassword() }
        set { Self.keychainSavePassword(newValue) }
    }

    // MARK: - Mobile Remote Control Settings (UserDefaults)
    // docs/mobile-remote-control.md §4.4. The listener is opt-in and loopback
    // only; the tailnet reaches it through Tailscale Serve. Process-environment
    // TERM_MESH_MOBILE_* values (reload.sh tags, E2E runners) override these.

    /// Whether the mobile remote-control listener is enabled. Default off.
    static let mobileEnabledKey = "termMeshMobileEnabled"
    /// Loopback port for the listener. Default 9877.
    static let mobilePortKey = "termMeshMobilePort"
    /// Auth mode: "tailscale" (default, fail closed) or "loopback" (dev only).
    static let mobileAuthKey = "termMeshMobileAuth"
    /// Comma-separated tailnet logins allowed in tailscale mode.
    static let mobileAllowedLoginsKey = "termMeshMobileAllowedLogins"
    static let defaultMobilePort = 9877

    var isMobileEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.mobileEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.mobileEnabledKey) }
    }

    var mobilePort: Int {
        get {
            let port = UserDefaults.standard.integer(forKey: Self.mobilePortKey)
            return (1...65535).contains(port) ? port : Self.defaultMobilePort
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.mobilePortKey) }
    }

    var mobileAuthMode: String {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.mobileAuthKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return raw == "loopback" ? "loopback" : "tailscale"
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.mobileAuthKey) }
    }

    var mobileAllowedLogins: String {
        get { UserDefaults.standard.string(forKey: Self.mobileAllowedLoginsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.mobileAllowedLoginsKey) }
    }

    /// Daemon environment for the mobile listener, or nil when it stays off.
    /// A tagged build without an explicit TERM_MESH_MOBILE_ADDR is left off so
    /// it can never take production's port; reload.sh supplies a tag port.
    func mobileListenerEnvironment(
        processEnv: [String: String],
        isTaggedBuild: Bool
    ) -> [String: String]? {
        let envEnabled = processEnv["TERM_MESH_MOBILE_ENABLED"]
            .map { $0 == "1" || $0.lowercased() == "true" }
        let enabled = envEnabled ?? isMobileEnabled
        guard enabled else { return nil }
        let addr: String
        if let explicit = processEnv["TERM_MESH_MOBILE_ADDR"], !explicit.isEmpty {
            addr = explicit
        } else if isTaggedBuild {
            NSLog("[TermMeshDaemon] mobile listener stays off: tagged build without TERM_MESH_MOBILE_ADDR")
            return nil
        } else {
            addr = "127.0.0.1:\(mobilePort)"
        }
        return [
            "TERM_MESH_MOBILE_ENABLED": "1",
            "TERM_MESH_MOBILE_ADDR": addr,
            "TERM_MESH_MOBILE_AUTH": processEnv["TERM_MESH_MOBILE_AUTH"] ?? mobileAuthMode,
            "TERM_MESH_MOBILE_ALLOWED_LOGINS": processEnv["TERM_MESH_MOBILE_ALLOWED_LOGINS"] ?? mobileAllowedLogins,
        ]
    }

    // MARK: - Keychain Helpers (Dashboard Password)

    private static let keychainService = "com.termmesh.dashboard"
    private static let keychainAccount = "dashboard-password"

    /// Load the dashboard password from Keychain.
    /// On first call, migrates any existing UserDefaults plaintext value to Keychain.
    private static func keychainLoadPassword() -> String {
        migratePasswordToKeychainIfNeeded()

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: kCFBooleanTrue!,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return ""
        }
        return password
    }

    /// Save the dashboard password to Keychain.
    /// Passing an empty string removes the Keychain item.
    private static func keychainSavePassword(_ password: String) {
        if password.isEmpty {
            keychainDeletePassword()
            return
        }
        guard let data = password.data(using: .utf8) else { return }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Delete the Keychain item for the dashboard password.
    private static func keychainDeletePassword() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-time migration: if a plaintext password exists in UserDefaults,
    /// move it to Keychain and remove it from UserDefaults.
    private static func migratePasswordToKeychainIfNeeded() {
        guard let existing = UserDefaults.standard.string(forKey: dashboardPasswordKey),
              !existing.isEmpty else { return }
        keychainSavePassword(existing)
        UserDefaults.standard.removeObject(forKey: dashboardPasswordKey)
    }

    // MARK: - Worktree Settings (UserDefaults)

    static let worktreeBaseDirKey = "termMeshWorktreeBaseDir"
    static let worktreeAutoCleanupKey = "termMeshWorktreeAutoCleanup"

    var worktreeBaseDir: String {
        get {
            let val = UserDefaults.standard.string(forKey: Self.worktreeBaseDirKey) ?? ""
            return val.isEmpty ? Self.defaultWorktreeBaseDir : val
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.worktreeBaseDirKey) }
    }

    var worktreeAutoCleanup: Bool {
        get { UserDefaults.standard.bool(forKey: Self.worktreeAutoCleanupKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.worktreeAutoCleanupKey) }
    }

    static var defaultWorktreeBaseDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.term-mesh/worktrees"
    }

    // MARK: - Socket Path

    var socketPath: String {
        // Tagged/isolated builds use explicit daemon socket path
        if let override_ = ProcessInfo.processInfo.environment["TERMMESH_DAEMON_UNIX_PATH"],
           !override_.isEmpty {
            return override_
        }
        // Fallback: derive tag from bundle id (com.termmesh.app.debug.<tag>)
        // so the daemon socket isolates correctly even without LSEnvironment.
        if let bid = Bundle.main.bundleIdentifier,
           bid.hasPrefix("com.termmesh.app.debug.") {
            let rawTag = String(bid.dropFirst("com.termmesh.app.debug.".count))
            let tag = rawTag.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if !tag.isEmpty {
                return "/tmp/term-meshd-dev-\(tag).sock"
            }
        }
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return (tmpDir as NSString).appendingPathComponent("term-meshd.sock")
    }

    /// Where this machine's daemon serves the peer protocol.
    ///
    /// The daemon has always been able to: `main.rs` starts `peer::serve` when
    /// `TERMMESH_PEER_SOCKET` names a path. On Linux that is how a peer works
    /// at all. On a Mac the app took that role and never set the variable, so
    /// the one component that can own a session past a quit was the one not
    /// serving the protocol that reaches sessions.
    ///
    /// Derived from the JSON-RPC socket rather than configured separately, so a
    /// tagged build's isolation is inherited instead of re-earned — two apps on
    /// one machine must not hand each other's daemons the same path.
    static func daemonPeerSocketPath(forDaemonSocket socketPath: String) -> String {
        let base = socketPath.hasSuffix(".sock")
            ? String(socketPath.dropLast(".sock".count))
            : socketPath
        return base + "-peer.sock"
    }

    var daemonPeerSocketPath: String {
        Self.daemonPeerSocketPath(forDaemonSocket: socketPath)
    }

    /// The path to advertise as this machine's session owner, or empty when it
    /// has none right now.
    ///
    /// Deciding this from settings does not work, and the first attempt proved
    /// it twice over. `daemonShouldOutliveApp(peerServingEnabled: true)` is
    /// `true` by inspection, so the guard advertised a session owner
    /// unconditionally; and even a guard reading the real setting would be
    /// wrong for an *adopted* daemon, which was started by an earlier run whose
    /// setting nobody here can see. Ask the socket instead — the answer is
    /// about the daemon, not about this app's preferences.
    static func advertisedSessionHostSocket(
        peerSocketPath: String,
        isListening: (String) -> Bool
    ) -> String {
        isListening(peerSocketPath) ? peerSocketPath : ""
    }

    var advertisedSessionHostSocket: String {
        Self.advertisedSessionHostSocket(
            peerSocketPath: daemonPeerSocketPath,
            isListening: Self.isListening(atUnixSocketPath:)
        )
    }

    /// Whether something is listening on a unix socket right now.
    ///
    /// A file at the path is not a daemon behind it: one killed uncleanly
    /// leaves its socket file, and pointing a client at that is the same broken
    /// promise as pointing it at nothing. `connect` is the only answer that
    /// tells the two apart, and against a local socket it costs microseconds.
    static func isListening(atUnixSocketPath path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var addr = sockaddr_un()
        // `sun_path` is a fixed 104-byte buffer; `strcpy` past it would smash
        // the stack rather than fail, so refuse the path instead.
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    // MARK: - Daemon Lifecycle

    /// Whether this machine's daemon should outlive the app that started it.
    ///
    /// A daemon that dies with its app cannot hold a session for anybody. That
    /// is the whole reason a project placed on a peer ends when someone quits
    /// term-mesh there: the work exists only inside that app's process tree.
    /// Serving peers is exactly the case where another machine may come back to
    /// a session, so it is the case that decouples.
    ///
    /// A machine that serves nobody keeps the old contract — owned, and gone on
    /// quit. `TERMMESH_OWNER_PID` was added so a crashed or force-reloaded app
    /// could not leave a daemon behind, and with no one to serve, surviving is
    /// exactly that leak rather than a feature.
    static func daemonShouldOutliveApp(peerServingEnabled: Bool) -> Bool {
        peerServingEnabled
    }

    /// A daemon from another app version must be replaced, even when it is
    /// holding peer sessions. Keeping it preserves processes at the cost of
    /// running the new app against an old protocol implementation forever.
    /// Unknown versions are not enough evidence to destroy live sessions.
    static func daemonRequiresUpgrade(
        runningVersion: String?,
        appVersion: String?
    ) -> Bool {
        guard let runningVersion, !runningVersion.isEmpty,
              let appVersion, !appVersion.isEmpty
        else { return false }
        return runningVersion != appVersion
    }

    /// Whether the subscribe loop's consecutive connect failures warrant
    /// re-running `startDaemon`. This loop is the one place that reliably
    /// observes "the daemon is gone": an adopted daemon has no Process
    /// handle and a spawned one has no termination handler, so without this
    /// the app watches its daemon die and does nothing (observed: 39
    /// daemon-less minutes after a brew upgrade adopted a daemon that was
    /// mid-shutdown). Three failures ≈ eight seconds of the 1s/2s/5s
    /// backoff — long enough not to mistake a daemon mid-restart for a dead
    /// one. The interval keeps a daemon that cannot come back (missing
    /// binary, crash loop) from being respawned every backoff tick.
    /// `startDaemon` itself is ping-gated, so a daemon that returned on its
    /// own is adopted, never doubled.
    static let watchdogFailureThreshold = 3
    static let watchdogRespawnIntervalNanos: UInt64 = 30 * 1_000_000_000

    /// Cap on the appended daemon log before it is truncated on the next
    /// spawn. Sized for weeks of ordinary output (a busy session writes a
    /// few MB) while bounding what an append-only file in /tmp can grow to.
    static let daemonLogMaxBytes: Int64 = 50 * 1024 * 1024

    static func watchdogShouldRespawn(
        consecutiveFailures: Int,
        runIntended: Bool,
        nowNanos: UInt64,
        lastRespawnNanos: UInt64?
    ) -> Bool {
        guard runIntended, consecutiveFailures >= watchdogFailureThreshold else { return false }
        guard let lastRespawnNanos else { return true }
        return nowNanos &- lastRespawnNanos >= watchdogRespawnIntervalNanos
    }

    /// This build's marketing version, or nil when the bundle has none.
    static var appMarketingVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Version of whatever daemon currently answers on the socket.
    ///
    /// Asks `daemon.status` rather than `ping`, which answers only `pong`.
    /// A daemon too old to carry the field, or one that does not answer,
    /// reports nil — treated as "unknown", never as a mismatch.
    func runningDaemonVersion() -> String? {
        guard let response = rpcCall(method: "daemon.status", params: [:]) as? [String: Any],
              let version = response["version"] as? String,
              !version.isEmpty
        else { return nil }
        return version
    }

    /// Spawn the term-meshd daemon process if not already running.
    func startDaemon() {
        startDaemon(assertIntent: true)
    }

    /// `assertIntent: false` is the watchdog's entry. Its decision to start
    /// was made earlier, off the control queue — by the time this block runs,
    /// the user may have pressed Stop in Settings. Re-check the intent HERE,
    /// on the control queue, and never rewrite it: an unconditional
    /// `daemonRunIntended = true` in this position is exactly how a queued
    /// watchdog start would resurrect a daemon the user just stopped.
    private func startDaemon(assertIntent: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if assertIntent {
                self.daemonRunIntended = true
            } else if !self.daemonRunIntended {
                Logger.daemon.info("watchdog start dropped — the daemon was deliberately stopped")
                return
            }

            // Already running (tracked process)?
            if let proc = self.daemonProcess, proc.isRunning { return }

            let outlivesApp = Self.daemonShouldOutliveApp(
                peerServingEnabled: PeerFederationSettings.autoStart
            )

            // Daemon from a previous app launch?
            if self.ping() {
                if outlivesApp {
                    let runningVersion = self.runningDaemonVersion()
                    let requiresUpgrade = Self.daemonRequiresUpgrade(
                        runningVersion: runningVersion,
                        appVersion: Self.appMarketingVersion
                    )
                    // The replacement must be proven launchable BEFORE the
                    // working daemon is destroyed. A bare Xcode build or an
                    // incomplete bundle carries no term-meshd; destroy-then-
                    // verify traded a live daemon — and every peer session it
                    // owned — for a "binary not found, skipping launch".
                    let replacementReady = requiresUpgrade
                        && self.daemonBinaryPath().map {
                            FileManager.default.isExecutableFile(atPath: $0)
                        } == true
                    if requiresUpgrade && !replacementReady {
                        Logger.daemon.error(
                            "daemon \(runningVersion ?? "unknown", privacy: .public) is older than this app, but no replacement binary is launchable — keeping the running daemon"
                        )
                        RemoteWorkLog.warningOffMain(
                            "This machine's daemon (\(runningVersion ?? "unknown")) is older than the app, but this build bundles no replacement — keeping the running daemon"
                        )
                    }
                    if replacementReady {
                        Logger.daemon.warning(
                            "replacing daemon version \(runningVersion ?? "unknown", privacy: .public) with bundled version \(Self.appMarketingVersion ?? "unknown", privacy: .public); live peer sessions will end"
                        )
                        RemoteWorkLog.warningOffMain(
                            "Updating this machine's daemon from \(runningVersion ?? "unknown") to \(Self.appMarketingVersion ?? "unknown"); live project sessions will end"
                        )
                        self.stopDaemon(force: true)
                        // stopDaemon withdraws run intent. This is a replacement,
                        // not a user stop, so keep the watchdog and spawn path live.
                        self.daemonRunIntended = true
                        Thread.sleep(forTimeInterval: 0.3)
                    } else {
                        // Adopt rather than restart when versions match, when
                        // the version is unknown, or when a stale daemon has
                        // no launchable replacement — neither uncertainty nor
                        // an impossible upgrade is a reason to destroy live
                        // peer sessions.
                        Logger.daemon.info(
                            "adopting the running daemon; settings changed since it started are not applied"
                        )
                        if runningVersion == nil {
                            Logger.daemon.error(
                                "adopted a daemon that did not answer the version probe — it may be shutting down"
                            )
                            RemoteWorkLog.infoOffMain(
                                "Adopted this machine's daemon without a version answer; if its sessions vanish shortly, it was already shutting down"
                            )
                        }
                        if let pid = self.getDaemonPeerPid() {
                            DispatchQueue.main.async {
                                TerminalController.shared.trustedDaemonPid = pid
                            }
                        }
                        return
                    }
                }
                // Restart it so current settings (dashboard enabled/port/bind)
                // are applied.
                Logger.daemon.info("daemon already running on socket — restarting with current settings")
                self.stopDaemon()
                // stopDaemon records "no daemon wanted"; this path stops only
                // to start again, so the intent stays on.
                self.daemonRunIntended = true
                // Brief pause so the socket file is fully released
                Thread.sleep(forTimeInterval: 0.3)
            }

            // The daemon probes and removes only a stale pathname whose inode
            // it observed. The app must not unlink here: a slow ping can be a
            // live daemon, and replacing its pathname creates split-brain.

            // Find the daemon binary next to the app bundle, or in the daemon build dir
            let binaryPath = self.daemonBinaryPath()
            guard let binaryPath, FileManager.default.fileExists(atPath: binaryPath) else {
                Logger.daemon.info("daemon binary not found, skipping launch")
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            var env = ProcessInfo.processInfo.environment
            // A GUI-owned daemon must not outlive the app after a crash,
            // forced reload, or SIGKILL. Standalone/headless launches omit
            // this variable and retain their independent lifecycle — and so
            // does a machine serving peers, whose sessions are the point.
            if !outlivesApp {
                env["TERMMESH_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            } else {
                // A daemon that outlives the app is the only component here that
                // can hold a session across a quit. Serving the peer protocol is
                // how anything reaches one — this app included, which attaches
                // to it exactly as it attaches to another machine's.
                env["TERMMESH_PEER_SOCKET"] = self.daemonPeerSocketPath
            }

            // Ensure Resources/bin is in PATH for daemon and all its child processes.
            // When launched from Finder/Spotlight, macOS provides a minimal PATH that
            // doesn't include the app's Resources/bin (where tm-agent, term-meshd live).
            // Pane mode handles this in TeamOrchestrator.swift, but the daemon needs it
            // for headless agent spawning.
            if let resourcePath = Bundle.main.resourcePath {
                let resourceBin = "\(resourcePath)/bin"
                let currentPath = env["PATH"] ?? ""
                if !currentPath.contains(resourceBin) {
                    env["PATH"] = "\(resourceBin):\(currentPath)"
                }
            }

            // Where the sync layer keeps THIS daemon's own secrets: its QUIC
            // TLS keypair and the project DEK. Nothing to do with reaching a
            // peer — that is ssh's job — only with keeping a stable identity
            // across restarts.
            //
            // The macOS Keychain backend needs a code-signing entitlement this
            // app does not carry, so asking for it fails provisioning outright
            // (`SYNC_BOOTSTRAP_KEYCHAIN`). Pointing at a directory selects the
            // file backend instead. Revisit when the app is signed with a
            // keychain entitlement.
            if env["TERMMESH_SYNC_KEYCHAIN_DIR"] == nil,
               let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let dir = support.appendingPathComponent("term-mesh/sync-keychain", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                env["TERMMESH_SYNC_KEYCHAIN_DIR"] = dir.path
            }

            // Dashboard settings
            // Tagged apps (parallel dev builds) disable HTTP to avoid port conflicts.
            let isTaggedBuild = termMeshEnv("TAG") != nil
            if !self.isDashboardEnabled || isTaggedBuild {
                env["TERM_MESH_HTTP_DISABLED"] = "1"
            } else {
                let host = self.isLocalhostOnly ? "127.0.0.1" : "0.0.0.0"
                env["TERM_MESH_HTTP_ADDR"] = "\(host):\(self.dashboardPort)"
            }

            // Dashboard password (Bearer token auth)
            let dashPwd = self.dashboardPassword
            if !dashPwd.isEmpty {
                env["TERM_MESH_HTTP_PASSWORD"] = dashPwd
            }

            // Mobile remote-control listener (opt-in, loopback only).
            if let mobileEnv = self.mobileListenerEnvironment(
                processEnv: ProcessInfo.processInfo.environment,
                isTaggedBuild: isTaggedBuild
            ) {
                env.merge(mobileEnv) { _, new in new }
            }

            process.environment = env

            // Log daemon stdout/stderr — isolated per tag
            let tag = termMeshEnv("TAG") ?? ""
            let logPath = tag.isEmpty ? "/tmp/term-meshd.log" : "/tmp/term-meshd-\(tag).log"
            // Append, never truncate: every launch used to REPLACE this file
            // (`createFile`), destroying exactly the evidence a "why was the
            // daemon down" investigation needs. O_NOFOLLOW because the name
            // is predictable in sticky /tmp — a pre-planted symlink must not
            // redirect daemon output into an arbitrary file (open fails and
            // the daemon logs to null instead). The size cap is what makes
            // append-forever safe: one bounded truncation at the cap beats
            // losing the log on every spawn, and beats filling /tmp.
            let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o644)
            let logHandle: FileHandle?
            if fd >= 0 {
                var info = stat()
                if fstat(fd, &info) == 0, info.st_size > Self.daemonLogMaxBytes {
                    ftruncate(fd, 0)
                }
                logHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            } else {
                Logger.daemon.error(
                    "could not open daemon log at \(logPath, privacy: .public) (errno \(errno, privacy: .public)) — daemon output goes to /dev/null"
                )
                logHandle = nil
            }
            process.standardOutput = logHandle ?? FileHandle.nullDevice
            process.standardError = logHandle ?? FileHandle.nullDevice

            do {
                try process.run()
                // Close our copy of the log fd — Process dup'd it internally
                try? logHandle?.close()
                self.daemonProcess = process
                let daemonPid = process.processIdentifier
                Logger.daemon.info("daemon started (pid: \(daemonPid, privacy: .public), binary: \(binaryPath, privacy: .public))")
                DispatchQueue.main.async {
                    TerminalController.shared.trustedDaemonPid = daemonPid
                }
            } catch {
                // The fd was never handed to a child; close it here or a
                // failing spawn (repeated by the watchdog) leaks one per try.
                try? logHandle?.close()
                Logger.daemon.error("failed to start daemon: \(error, privacy: .public)")
            }
        }
    }

    /// Stop the daemon process.
    /// Called from applicationWillTerminate — must complete quickly.
    func stopDaemon() {
        stopDaemon(force: false)
    }

    /// Stop the daemon bound to this app variant's exact socket. `force` is
    /// reserved for explicit restart/upgrade paths where continuing to run an
    /// old daemon is worse than ending the sessions it owns.
    private func stopDaemon(force: Bool) {
        // A daemon serving peers holds sessions another machine reattaches to.
        // Killing it here is precisely what made "quit term-mesh on the peer"
        // end the project, so this path declines to.
        if !force, Self.daemonShouldOutliveApp(peerServingEnabled: PeerFederationSettings.autoStart) {
            daemonProcess = nil
            Logger.daemon.info("leaving the daemon running; it holds sessions for other machines")
            return
        }
        // Only a stop that actually proceeds withdraws the intent — the
        // subscribe watchdog must not resurrect a daemon the user stopped,
        // and must keep resurrecting one the outlive policy declined to stop.
        daemonRunIntended = false

        // Case 1: We spawned the daemon — terminate directly
        if let proc = daemonProcess, proc.isRunning {
            let pid = proc.processIdentifier
            proc.terminate()
            daemonProcess = nil
            Logger.daemon.info("daemon stopped (tracked process)")
            Self.ensureTerminated(pid: pid)
        }

        // Case 2: Kill daemon listening on our socket (isolated — won't affect other instances).
        // Use lsof to find the PID bound to our specific socket path.
        let path = socketPath
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", path]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        let lsofDone = DispatchSemaphore(value: 0)
        lsof.terminationHandler = { _ in lsofDone.signal() }
        try? lsof.run()
        let lsofTimedOut = lsofDone.wait(timeout: .now() + 2.0) == .timedOut
        if lsofTimedOut { lsof.terminate() }
        // On timeout skip reading to avoid blocking on a stale pipe.
        let pidData = lsofTimedOut ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
        if let pidStr = String(data: pidData, encoding: .utf8) {
            for line in pidStr.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGTERM)
                    Logger.daemon.info("daemon killed (pid: \(pid, privacy: .public), socket: \(path, privacy: .public))")
                    Self.ensureTerminated(pid: pid)
                }
            }
        }

        // The daemon removes only the pathname inode it bound. Never unlink
        // from the app after a timeout: ownership may already have changed.
    }

    /// Poll `pid` after a SIGTERM and escalate to SIGKILL if it hasn't exited
    /// within ~1.5s. Guards against a daemon that ignores/hangs on SIGTERM
    /// (e.g. a runtime shutdown stuck on a non-terminating background task).
    /// Called from applicationWillTerminate, so the normal case — the process
    /// already gone — must return immediately without sleeping.
    private static func ensureTerminated(pid: Int32) {
        let pollIntervalUsec: useconds_t = 100_000  // 100ms
        let maxPolls = 15  // 15 * 100ms = 1.5s
        for _ in 0..<maxPolls {
            if kill(pid, 0) != 0 && errno == ESRCH { return }  // already gone
            usleep(pollIntervalUsec)
        }
        if kill(pid, 0) == 0 || errno != ESRCH {
            kill(pid, SIGKILL)
            Logger.daemon.warning("daemon did not exit after SIGTERM, sent SIGKILL (pid: \(pid, privacy: .public))")
        }
    }

    // MARK: - Restart

    /// Stop and re-start the daemon process.
    func restartDaemon(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            // Stop synchronously (fast — pkill + socket cleanup)
            // Use async + DispatchGroup to avoid deadlock when main is waiting on this queue
            let stopGroup = DispatchGroup()
            stopGroup.enter()
            DispatchQueue.main.async { [weak self] in
                self?.stopDaemon(force: true)
                stopGroup.leave()
            }
            stopGroup.wait()
            // Brief pause so the socket file is fully released
            Thread.sleep(forTimeInterval: 0.3)
            self.startDaemon()
            // Wait for the daemon to become responsive
            for _ in 0..<20 {
                if self.ping() { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Daemon Status

    struct DaemonStatus {
        let connected: Bool
        let pid: Int?
        let uptimeSecs: Int?
        let binaryPath: String?
        let binaryExists: Bool
        let socketPath: String
        let socketExists: Bool
        let logPath: String
        let logExists: Bool
        let appVariant: String       // "Release", "Debug", "Staging", "Nightly", "Debug (tag)"
        let bundleIdentifier: String
        let subsystems: [SubsystemStatus]
    }

    struct SubsystemStatus: Identifiable {
        let id: String   // key name
        let name: String  // display name
        let status: String  // "running", "disabled", "starting", etc.
        let detail: String?
    }

    /// Query the daemon for its full status.
    func daemonStatus() -> DaemonStatus {
        let fm = FileManager.default
        let binPath = daemonBinaryPath()
        let sockPath = socketPath
        let logPath = "/tmp/term-meshd.log"
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let variant = Self.resolveAppVariant()

        let base = { (connected: Bool, pid: Int?, uptime: Int?, subs: [SubsystemStatus]) in
            DaemonStatus(
                connected: connected, pid: pid, uptimeSecs: uptime,
                binaryPath: binPath, binaryExists: binPath != nil && fm.fileExists(atPath: binPath!),
                socketPath: sockPath, socketExists: fm.fileExists(atPath: sockPath),
                logPath: logPath, logExists: fm.fileExists(atPath: logPath),
                appVariant: variant, bundleIdentifier: bundleId,
                subsystems: subs
            )
        }

        guard let response = rpcCall(method: "daemon.status", params: [:]) as? [String: Any] else {
            return base(false, nil, nil, [])
        }

        let pid = (response["pid"] as? NSNumber)?.intValue
        let uptime = (response["uptime_secs"] as? NSNumber)?.intValue
        var subs: [SubsystemStatus] = []

        if let subsystems = response["subsystems"] as? [String: Any] {
            let order = [
                ("socket", "Unix Socket"),
                ("http", "HTTP Dashboard"),
                ("monitor", "Resource Monitor"),
                ("watcher", "File Watcher"),
                ("agents", "Agent Manager"),
            ]
            for (key, displayName) in order {
                guard let info = subsystems[key] as? [String: Any] else { continue }
                let status = info["status"] as? String ?? "unknown"
                var detail: String?
                if let addr = info["addr"] as? String { detail = addr }
                if let count = info["tracked_pids"] as? Int { detail = "\(count) tracked PIDs" }
                if let count = info["watched_paths"] as? Int { detail = "\(count) watched paths" }
                if let count = info["active_sessions"] as? Int { detail = "\(count) active sessions" }
                subs.append(SubsystemStatus(id: key, name: displayName, status: status, detail: detail))
            }
        }

        return base(true, pid, uptime, subs)
    }

    /// Determine the current app variant from bundle identifier and build config.
    static func resolveAppVariant() -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if bundleId == "com.termmesh.app.nightly" { return "Nightly" }
        if SocketControlSettings.isStagingBundleIdentifier(bundleId) { return "Staging" }
        if SocketControlSettings.isDebugLikeBundleIdentifier(bundleId) {
            // Tagged debug builds have bundle IDs like com.termmesh.app.debug.doctor-test
            let suffix = bundleId.replacingOccurrences(of: "com.termmesh.app.debug", with: "")
            if suffix.hasPrefix("."), suffix.count > 1 {
                return "Debug (\(String(suffix.dropFirst())))"
            }
            return "Debug"
        }
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    // MARK: - RPC Calls

    /// Create a worktree sandbox for the given repo path.
    /// Returns the worktree path on success, nil on failure.
    func createWorktree(repoPath: String, branch: String? = nil, baseBranch: String? = nil) -> WorktreeInfo? {
        var params: [String: Any] = ["repo_path": repoPath, "base_dir": worktreeBaseDir]
        if let branch { params["branch"] = branch }
        if let baseBranch { params["base_ref"] = baseBranch }
        guard let response = rpcCall(method: "worktree.create", params: params) else { return nil }
        return parseWorktreeInfo(response)
    }

    /// Create a worktree with detailed error reporting.
    func createWorktreeWithError(repoPath: String, branch: String? = nil, baseBranch: String? = nil) -> Result<WorktreeInfo, WorktreeCreateError> {
        // Check if CWD is inside a git repo (walk up to find .git)
        guard let gitRoot = findGitRoot(from: repoPath) else {
            return .failure(.notGitRepo)
        }

        // Check daemon connectivity
        guard ping() else {
            return .failure(.daemonNotConnected)
        }

        var params: [String: Any] = ["repo_path": gitRoot, "base_dir": worktreeBaseDir]
        if let branch { params["branch"] = branch }
        if let baseBranch { params["base_ref"] = baseBranch }
        switch rpcCallResult(method: "worktree.create", params: params) {
        case .success(let response):
            guard let info = parseWorktreeInfo(response) else {
                return .failure(.rpcError("Worktree creation returned an invalid response"))
            }
            return .success(info)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// List local branches for a repo.
    func listBranches(repoPath: String) -> [String] {
        let params: [String: Any] = ["repo_path": repoPath]
        guard let response = rpcCall(method: "worktree.list_branches", params: params),
              let array = response as? [String] else { return [] }
        return array
    }

    /// Walk up from `path` to find the nearest directory containing `.git`.
    func findGitRoot(from path: String) -> String? {
        var current = path
        guard !current.isEmpty, current.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        while current != "/" && !current.isEmpty {
            let gitDir = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }  // safety: no progress
            current = parent
        }
        return nil
    }

    /// Remove a worktree by name. Refuses if dirty unless `force` is true.
    func removeWorktree(repoPath: String, name: String, force: Bool = false) -> Bool {
        let params: [String: Any] = ["repo_path": repoPath, "name": name, "force": force]
        return rpcCall(method: "worktree.remove", params: params) != nil
    }

    /// Remove one untouched worktree created during a failed provisioning
    /// transaction and delete its just-created branch so the durable instance
    /// identity can be retried. The daemon still refuses dirty worktrees.
    func rollbackCreatedWorktree(repoPath: String, name: String) -> Bool {
        let params: [String: Any] = [
            "repo_path": repoPath,
            "name": name,
            "force": false,
            "delete_branch": true,
        ]
        return rpcCall(method: "worktree.remove", params: params) != nil
    }

    /// Remove a worktree only if it has no uncommitted changes.
    /// Returns a tuple: (success, errorMessage).
    func safeRemoveWorktree(repoPath: String, name: String) -> (Bool, String?) {
        let params: [String: Any] = ["repo_path": repoPath, "name": name]
        if rpcCall(method: "worktree.safe_remove", params: params) != nil {
            return (true, nil)
        }
        // On failure, check status to provide a meaningful message
        let st = worktreeStatus(repoPath: repoPath, name: name)
        if st.dirty {
            return (false, "Worktree has uncommitted changes.")
        }
        return (false, "Failed to remove worktree.")
    }

    /// Check worktree status (dirty / unpushed).
    struct WorktreeStatusResult {
        let dirty: Bool
        let unpushed: Bool
    }

    func worktreeStatus(repoPath: String, name: String) -> WorktreeStatusResult {
        let params: [String: Any] = ["repo_path": repoPath, "name": name]
        guard let response = rpcCall(method: "worktree.status", params: params),
              let dict = response as? [String: Any] else {
            return WorktreeStatusResult(dirty: false, unpushed: false)
        }
        return WorktreeStatusResult(
            dirty: dict["dirty"] as? Bool ?? false,
            unpushed: dict["unpushed"] as? Bool ?? false
        )
    }

    /// List all term-mesh worktrees for a repo.
    func listWorktrees(repoPath: String) -> [WorktreeInfo] {
        let params: [String: Any] = ["repo_path": repoPath]
        guard let response = rpcCall(method: "worktree.list", params: params),
              let array = response as? [[String: Any]] else { return [] }
        return array.compactMap { parseWorktreeInfo($0) }
    }

    // MARK: - Monitor (F-03/F-04)

    /// Track a process by PID for resource monitoring.
    /// Ask the daemon to watch `pid`. Returns whether it is watched.
    ///
    /// The daemon declines a pid it cannot read an identity for, so the
    /// caller must not record the request as satisfied on its own.
    func trackPID(_ pid: Int32) -> Bool {
        // `rpcCall` already hands back the `result` payload, the way
        // `stopProcess` below reads it. Unwrapping a second time returns nil
        // for every answer, which reads as "declined" for pids the daemon
        // actually tracked.
        guard let response = rpcCall(method: "monitor.track", params: ["pid": pid]) as? [String: Any] else {
            return false
        }
        // An older daemon answers without the field; it always tracked.
        return response["tracked"] as? Bool ?? true
    }

    /// Untrack a process.
    func untrackPID(_ pid: Int32) {
        let _ = rpcCall(method: "monitor.untrack", params: ["pid": pid])
    }

    // MARK: - Budget Guard (F-03/F-04)

    /// Send SIGSTOP to a process via the daemon.
    func stopProcess(pid: Int32) -> Bool {
        guard let response = rpcCall(method: "process.stop", params: ["pid": pid]) as? [String: Any] else { return false }
        return response["stopped"] as? Bool ?? false
    }

    /// Send SIGCONT to resume a stopped process via the daemon.
    func resumeProcess(pid: Int32) -> Bool {
        guard let response = rpcCall(method: "process.resume", params: ["pid": pid]) as? [String: Any] else { return false }
        return response["resumed"] as? Bool ?? false
    }

    /// Enable/disable auto-stop when budget thresholds are exceeded.
    func setAutoStop(enabled: Bool) {
        let _ = rpcCall(method: "budget.auto_stop", params: ["enabled": enabled])
    }

    // MARK: - Usage Tracking (JSONL-based API cost)

    /// Get API usage snapshot (parsed from Claude Code JSONL logs).
    func usageSnapshot() -> [String: Any]? {
        guard let response = rpcCall(method: "usage.snapshot", params: [:]) as? [String: Any] else { return nil }
        return response
    }

    /// Trigger an immediate usage scan.
    func usageScan() {
        let _ = rpcCall(method: "usage.scan", params: [:])
    }

    /// The resource monitor's latest system-wide sample, or nil when the
    /// daemon has not taken one yet (it answers `{}` until its first tick).
    ///
    /// The socket call is blocking, so it runs off the caller's thread.
    /// Callers suspend without pinning their actor — notably `PeerServer`,
    /// whose list/attach control plane must stay responsive while a telemetry
    /// sample is late or the daemon socket is unavailable.
    ///
    /// On `telemetryQueue`, NOT `queue`: this is polled every couple of
    /// seconds by the peer host stats loop, and `queue` is the serial lane that
    /// spawn/adopt/restart/stop run in. A read that can block until the receive
    /// timeout has no business ahead of those, and nothing here needs to be
    /// ordered against them.
    ///
    /// The timeout is deliberately short. A sample is worth having only while
    /// it is current — the next tick is seconds away, and the client treats a
    /// reading older than `staleAfter` as no reading at all — so waiting the
    /// default five seconds for one would produce a figure with no remaining
    /// value.
    func monitorSnapshot() async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            telemetryQueue.async { [weak self] in
                guard let self,
                      let response = self.rpcCall(
                          method: "monitor.snapshot", params: [:], timeout: 2
                      ) as? [String: Any],
                      !response.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: response)
            }
        }
    }

    // MARK: - Watcher (F-05)

    /// Normalize a file-watch target and reject paths whose recursive event
    /// volume would cover the whole machine or user account.
    static func safeWatchPath(
        _ path: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }

        let normalized = URL(fileURLWithPath: trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard normalized.hasPrefix("/") else { return nil }

        let normalizedHome = URL(fileURLWithPath: homeDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let dangerous = Set([
            "/", "/Users", "/tmp", "/private", "/private/tmp",
            "/var", "/private/var", normalizedHome,
        ])
        return dangerous.contains(normalized) ? nil : normalized
    }

    /// Start watching a directory for file events.
    func watchPath(_ path: String) {
        guard let safePath = Self.safeWatchPath(path) else {
            Logger.daemon.warning("refusing recursive watch of broad path: \(path, privacy: .public)")
            return
        }
        let _ = rpcCall(method: "watcher.watch", params: ["path": safePath])
    }

    /// Stop watching a directory.
    func unwatchPath(_ path: String) {
        let normalized = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let _ = rpcCall(method: "watcher.unwatch", params: ["path": normalized])
    }

    // MARK: - Sessions

    /// Sync terminal sessions with the daemon (for remote dashboard).
    func syncSessions(_ sessions: [[String: Any]]) {
        let _ = rpcCall(method: "session.sync", params: ["sessions": sessions])
    }

    /// Sync app-side team dashboard state with the daemon (for remote dashboard).
    func syncTeams(_ payload: [String: Any]) {
        let _ = rpcCall(method: "team.sync", params: payload)
    }

    // MARK: - Agent Sessions (F-06)

    /// Spawn N agent sessions with worktree sandboxes.
    func spawnAgents(repoPath: String, count: Int = 1, name: String? = nil, command: String? = nil) -> [AgentSessionInfo] {
        var params: [String: Any] = ["repo_path": repoPath, "count": count, "worktree_base_dir": worktreeBaseDir]
        if let name { params["name"] = name }
        if let command { params["command"] = command }
        // Worktree creation takes ~2s per agent; allow generous timeout
        let timeoutSec = max(10, count * 5)
        guard let response = rpcCall(method: "agent.spawn", params: params, timeout: timeoutSec) as? [[String: Any]] else { return [] }
        return response.compactMap { parseAgentSessionInfo($0) }
    }

    /// List agent sessions (active only by default).
    func listAgents(includeTerminated: Bool = false) -> [AgentSessionInfo] {
        let params: [String: Any] = ["include_terminated": includeTerminated]
        guard let response = rpcCall(method: "agent.list", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseAgentSessionInfo($0) }
    }

    /// Get a single agent session by ID.
    func getAgent(id: String) -> AgentSessionInfo? {
        guard let response = rpcCall(method: "agent.get", params: ["id": id]) as? [String: Any] else { return nil }
        return parseAgentSessionInfo(response)
    }

    /// Terminate an agent session (cleanup worktree + processes).
    func terminateAgent(id: String, force: Bool = false) -> Bool {
        let params: [String: Any] = ["id": id, "force": force]
        return rpcCall(method: "agent.terminate", params: params) != nil
    }

    /// Bind a UI panel to an agent session.
    func bindAgentPanel(sessionId: String, panelId: String) -> Bool {
        let params: [String: Any] = ["session_id": sessionId, "panel_id": panelId]
        return rpcCall(method: "agent.bind_panel", params: params) != nil
    }

    /// Unbind a UI panel from an agent session (session stays alive).
    func unbindAgentPanel(sessionId: String) -> Bool {
        let params: [String: Any] = ["session_id": sessionId]
        return rpcCall(method: "agent.unbind_panel", params: params) != nil
    }

    /// Register a PID with an agent session.
    func addAgentPid(sessionId: String, pid: Int32) -> Bool {
        let params: [String: Any] = ["session_id": sessionId, "pid": pid]
        return rpcCall(method: "agent.add_pid", params: params) != nil
    }

    // MARK: - Tasks (F-06)

    /// Create a new task.
    func createTask(title: String, description: String? = nil, priority: Int? = nil, createdBy: String? = nil, deps: [String]? = nil) -> TaskInfo? {
        var params: [String: Any] = ["title": title]
        if let description { params["description"] = description }
        if let priority { params["priority"] = priority }
        if let createdBy { params["created_by"] = createdBy }
        if let deps { params["deps"] = deps }
        guard let response = rpcCall(method: "task.create", params: params) as? [String: Any] else { return nil }
        return parseTaskInfo(response)
    }

    /// Get a task by ID.
    func getTask(id: String) -> TaskInfo? {
        guard let response = rpcCall(method: "task.get", params: ["id": id]) as? [String: Any] else { return nil }
        return parseTaskInfo(response)
    }

    /// List tasks with optional status/assignee filters.
    func listTasks(status: String? = nil, assignee: String? = nil) -> [TaskInfo] {
        var params: [String: Any] = [:]
        if let status { params["status"] = status }
        if let assignee { params["assignee"] = assignee }
        guard let response = rpcCall(method: "task.list", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseTaskInfo($0) }
    }

    /// Update a task (title, description, status, priority, assignee).
    func updateTask(id: String, title: String? = nil, description: String? = nil, status: String? = nil, priority: Int? = nil, assignee: String? = nil) -> TaskInfo? {
        var params: [String: Any] = ["id": id]
        if let title { params["title"] = title }
        if let description { params["description"] = description }
        if let status { params["status"] = status }
        if let priority { params["priority"] = priority }
        if let assignee { params["assignee"] = assignee }
        guard let response = rpcCall(method: "task.update", params: params) as? [String: Any] else { return nil }
        return parseTaskInfo(response)
    }

    /// Assign a task to an agent.
    func assignTask(taskId: String, agentId: String) -> TaskInfo? {
        let params: [String: Any] = ["task_id": taskId, "agent_id": agentId]
        guard let response = rpcCall(method: "task.assign", params: params) as? [String: Any] else { return nil }
        return parseTaskInfo(response)
    }

    /// Get task log entries.
    func taskLog(taskId: String, limit: Int? = nil) -> [TaskLogEntry] {
        var params: [String: Any] = ["task_id": taskId]
        if let limit { params["limit"] = limit }
        guard let response = rpcCall(method: "task.log", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseTaskLogEntry($0) }
    }

    // MARK: - Messages (F-06)

    /// Send a message to an agent.
    func sendMessage(toAgent: String, content: String, fromAgent: String? = nil) -> AgentMessageInfo? {
        var params: [String: Any] = ["to_agent": toAgent, "content": content]
        if let fromAgent { params["from_agent"] = fromAgent }
        guard let response = rpcCall(method: "message.send", params: params) as? [String: Any] else { return nil }
        return parseAgentMessageInfo(response)
    }

    /// List messages for an agent.
    func listMessages(agentId: String, unreadOnly: Bool = false, limit: Int? = nil) -> [AgentMessageInfo] {
        var params: [String: Any] = ["agent_id": agentId]
        if unreadOnly { params["unread_only"] = true }
        if let limit { params["limit"] = limit }
        guard let response = rpcCall(method: "message.list", params: params) as? [[String: Any]] else { return [] }
        return response.compactMap { parseAgentMessageInfo($0) }
    }

    /// Acknowledge (mark as read) messages by IDs.
    func ackMessages(messageIds: [Int64]) -> Int {
        let params: [String: Any] = ["message_ids": messageIds]
        guard let response = rpcCall(method: "message.ack", params: params) as? [String: Any] else { return 0 }
        return (response["acknowledged"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Input Queue (F-06)

    /// Enqueue text input for an agent's PTY.
    func enqueueInput(sessionId: String, text: String) -> Bool {
        let params: [String: Any] = ["session_id": sessionId, "text": text]
        return rpcCall(method: "input.enqueue", params: params) != nil
    }

    /// Poll all pending inputs (for Swift-side PTY injection).
    func pollInputs() -> [PendingInputInfo] {
        guard let response = rpcCall(method: "input.poll", params: [:]) as? [[String: Any]] else { return [] }
        return response.compactMap { parsePendingInputInfo($0) }
    }

    // MARK: - Private Parsers

    private func parseAgentSessionInfo(_ dict: [String: Any]) -> AgentSessionInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let repoPath = dict["repo_path"] as? String,
              let worktreeName = dict["worktree_name"] as? String,
              let worktreePath = dict["worktree_path"] as? String,
              let worktreeBranch = dict["worktree_branch"] as? String,
              let status = dict["status"] as? String else { return nil }
        return AgentSessionInfo(
            id: id,
            name: name,
            repoPath: repoPath,
            worktreeName: worktreeName,
            worktreePath: worktreePath,
            worktreeBranch: worktreeBranch,
            command: dict["command"] as? String,
            status: status,
            pid: (dict["pid"] as? NSNumber)?.int32Value,
            panelId: dict["panel_id"] as? String,
            createdAtMs: (dict["created_at_ms"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    private func parseTaskInfo(_ dict: [String: Any]) -> TaskInfo? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String,
              let status = dict["status"] as? String,
              let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.uint64Value,
              let updatedAtMs = (dict["updated_at_ms"] as? NSNumber)?.uint64Value else { return nil }
        return TaskInfo(
            id: id,
            title: title,
            description: dict["description"] as? String,
            status: status,
            priority: (dict["priority"] as? NSNumber)?.intValue ?? 0,
            assignee: dict["assignee"] as? String,
            createdBy: dict["created_by"] as? String,
            deps: dict["deps"] as? [String] ?? [],
            createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs
        )
    }

    private func parseTaskLogEntry(_ dict: [String: Any]) -> TaskLogEntry? {
        guard let id = (dict["id"] as? NSNumber)?.int64Value,
              let taskId = dict["task_id"] as? String,
              let message = dict["message"] as? String,
              let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.uint64Value else { return nil }
        return TaskLogEntry(
            id: id,
            taskId: taskId,
            agentId: dict["agent_id"] as? String,
            message: message,
            createdAtMs: createdAtMs
        )
    }

    private func parseAgentMessageInfo(_ dict: [String: Any]) -> AgentMessageInfo? {
        guard let id = (dict["id"] as? NSNumber)?.int64Value,
              let toAgent = dict["to_agent"] as? String,
              let content = dict["content"] as? String,
              let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.uint64Value else { return nil }
        return AgentMessageInfo(
            id: id,
            fromAgent: dict["from_agent"] as? String,
            toAgent: toAgent,
            content: content,
            read: (dict["read"] as? NSNumber)?.boolValue ?? false,
            createdAtMs: createdAtMs
        )
    }

    private func parsePendingInputInfo(_ dict: [String: Any]) -> PendingInputInfo? {
        guard let sessionId = dict["session_id"] as? String,
              let text = dict["text"] as? String,
              let createdAtMs = (dict["created_at_ms"] as? NSNumber)?.uint64Value else { return nil }
        return PendingInputInfo(
            sessionId: sessionId,
            text: text,
            createdAtMs: createdAtMs
        )
    }

    // MARK: - General

    /// Ping the daemon to check connectivity.
    func ping() -> Bool {
        guard let response = rpcCall(method: "ping", params: [:]) as? [String: Any],
              let status = response["status"] as? String,
              status == "pong" else { return false }
        return true
    }

    /// Connect to the daemon socket and retrieve its PID via LOCAL_PEERPID.
    /// Used to register an orphaned (reused) daemon as a trusted ancestor.
    private func getDaemonPeerPid() -> pid_t? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size)
        return pid > 0 ? pid : nil
    }

    // MARK: - Phase 2.5 — agent.usage_tick push handler

    /// Entry point for socket-notify `agent.usage_tick` events. The daemon is
    /// expected to coalesce per-agent usage at ~1Hz before emitting; the
    /// payload mirrors `AgentUsageSnapshot` shape:
    ///
    ///   { "team_name": "...", "agents": [
    ///     { "name": "explorer",
    ///       "input_tokens": 8200,
    ///       "output_tokens": 1300,
    ///       "cache_read_tokens": 22000,
    ///       "cache_creation_tokens": 13000 }
    ///   ] }
    ///
    /// Marshals onto the main thread and forwards to `TeamDataStore.updateUsage`.
    /// Safe to call from any thread. Backend wiring (socket-notify subscription)
    /// is intentionally left as a future addition — until then this method is
    /// callable from tests / debug bridges without breakage.
    func handleAgentUsageTick(payload: [String: Any]) {
        guard let teamName = payload["team_name"] as? String,
              let agentsRaw = payload["agents"] as? [[String: Any]] else {
            return
        }
        var parsed: [(name: String, snapshot: AgentUsageSnapshot)] = []
        let now = Date()
        for entry in agentsRaw {
            guard let name = entry["name"] as? String else { continue }
            let input = (entry["input_tokens"] as? NSNumber)?.uint64Value ?? 0
            let output = (entry["output_tokens"] as? NSNumber)?.uint64Value ?? 0
            let cacheRead = (entry["cache_read_tokens"] as? NSNumber)?.uint64Value ?? 0
            let cacheCreation = (entry["cache_creation_tokens"] as? NSNumber)?.uint64Value ?? 0
            parsed.append((
                name: name,
                snapshot: AgentUsageSnapshot(
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheCreationTokens: cacheCreation,
                    updatedAt: now
                )
            ))
        }
        DispatchQueue.main.async {
            TeamDataStore.shared.updateUsage(teamName: teamName, agents: parsed)
        }
    }

    // MARK: - Event Subscription (Phase 2.5)

    /// Open a long-lived streaming `events.subscribe` connection to the daemon and
    /// dispatch incoming events to their handlers.  Reconnects automatically with
    /// exponential backoff (1 s → 2 s → 5 s) on disconnect or daemon restart.
    /// Call once from AppDelegate after `startDaemon()`.  Safe to call multiple
    /// times — a running subscription is cancelled before the new one starts.
    func startEventSubscription() {
        eventSubscriptionTask?.cancel()
        eventSubscriptionTask = Task.detached(priority: .utility) { [weak self] in
            let backoffSequence = [1.0, 2.0, 5.0]
            var attempt = 0
            var lastWatchdogRespawn: UInt64?
            while !Task.isCancelled {
                guard let self else { return }
                let path = self.socketPath
                let id = self.nextRpcId()
                let request: [String: Any] = [
                    "id": id,
                    "method": "events.subscribe",
                    // xk_run is strictly opt-in on the daemon side — it is only
                    // delivered because we name it here (docs/xk-panel-phase2.md).
                    "params": ["kinds": ["agent_usage_tick", "xk_run"]],
                ]
                guard var jsonLine = try? JSONSerialization.data(withJSONObject: request),
                      !Task.isCancelled else { break }
                jsonLine.append(UInt8(ascii: "\n"))

                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    let delay = backoffSequence[min(attempt, backoffSequence.count - 1)]
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                    continue
                }

                var connectOK = false
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = path.utf8CString
                if pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) {
                    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                            for (i, b) in pathBytes.enumerated() { dest[i] = b }
                        }
                    }
                    connectOK = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                            Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                        }
                    }
                }

                guard connectOK else {
                    close(fd)
                    let delay = backoffSequence[min(attempt, backoffSequence.count - 1)]
                    attempt += 1
                    // This reconnect loop is the one place that reliably
                    // observes a dead daemon (adopted daemons have no Process
                    // handle; spawned ones have no termination handler), so
                    // it is also where recovery must start — see
                    // `watchdogShouldRespawn` for the thresholds.
                    if Self.watchdogShouldRespawn(
                        consecutiveFailures: attempt,
                        runIntended: self.daemonRunIntended,
                        nowNanos: DispatchTime.now().uptimeNanoseconds,
                        lastRespawnNanos: lastWatchdogRespawn
                    ) {
                        lastWatchdogRespawn = DispatchTime.now().uptimeNanoseconds
                        Logger.daemon.error(
                            "daemon socket unanswered after \(attempt, privacy: .public) subscribe attempts — re-running startDaemon"
                        )
                        RemoteWorkLog.warningOffMain(
                            "This machine's daemon stopped answering — restarting it"
                        )
                        self.startDaemon(assertIntent: false)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Connected — send the subscribe request.
                _ = jsonLine.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                attempt = 0  // reset backoff on successful connect

                // Read NDJSON lines until the connection drops or task is cancelled.
                var buf = Data(capacity: 65536)
                var readBuf = [UInt8](repeating: 0, count: 4096)
                var firstLine = true  // skip the ack line
                readLoop: while !Task.isCancelled {
                    let n = Darwin.read(fd, &readBuf, readBuf.count)
                    if n <= 0 { break }
                    buf.append(contentsOf: readBuf[0..<n])
                    // Process all complete lines (\n-terminated) from buf.
                    while let nlIdx = buf.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buf[buf.startIndex..<nlIdx]
                        buf = buf[(nlIdx + 1)...]
                        if firstLine { firstLine = false; continue }  // skip ack
                        guard !lineData.isEmpty,
                              let msg = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let kind = msg["kind"] as? String else { continue }
                        switch kind {
                        case "agent_usage_tick":
                            self.handleAgentUsageTick(payload: msg)
                        case "xk_run":
                            // XK-EVENTS-v1 panel-run telemetry → dashboard store.
                            // Thread-safe ingest; no main-thread hop needed here.
                            TeamDataStore.shared.ingestXkPanelRun(payload: msg)
                        case "keepalive":
                            break  // heartbeat — no action needed
                        default:
                            Logger.daemon.debug("events.subscribe unhandled kind: \(kind, privacy: .public)")
                        }
                    }
                }
                close(fd)
                if Task.isCancelled { break }
                // Brief pause before reconnect attempt.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Thread-safe RPC ID increment (called from multiple threads).
    private func nextRpcId() -> Int {
        idLock.lock()
        defer { idLock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    /// Raw RPC call that returns the result as a JSON string (for injecting into WKWebView).
    func rpcCallRaw(method: String, params: [String: Any]) -> String? {
        rpcCallRaw(method: method, params: params, timeout: 5)
    }

    func rpcCallRaw(method: String, params: [String: Any], timeout: Int) -> String? {
        guard let response = rpcCall(method: method, params: params, timeout: timeout) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Private

    private func rpcCall(method: String, params: [String: Any], timeout timeoutSec: Int = 5) -> Any? {
        switch rpcCallResult(method: method, params: params, timeout: timeoutSec) {
        case .success(let result):
            return result
        case .failure(let error):
            Logger.daemon.error("RPC error: \(error.description, privacy: .public)")
            return nil
        }
    }

    private func rpcCallResult(
        method: String,
        params: [String: Any],
        timeout timeoutSec: Int = 5
    ) -> Result<Any, WorktreeCreateError> {
        // Serialised by `idLock`, not by `queue`: this method is called from
        // `queue` and from arbitrary threads (telemetry, WebView, callers of
        // `monitorSnapshot()`), so the bare read-modify-write it used to do
        // here was a data race the moment any of those overlapped.
        let id = nextRpcId()

        let request: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              var jsonString = String(data: data, encoding: .utf8) else {
            return .failure(.rpcError("could not encode RPC request"))
        }
        jsonString += "\n"

        // Connect to Unix socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.daemonNotConnected) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .failure(.rpcError("daemon socket path is too long"))
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return .failure(.daemonNotConnected)
        }

        // Set timeout
        var timeout = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Send request
        let sent = jsonString.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
        guard sent > 0 else { return .failure(.rpcError("could not send daemon request")) }

        // Read response (line-delimited)
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(UInt8(ascii: "\n")) { break }
        }

        guard !responseData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return .failure(.rpcError("daemon returned no valid JSON response"))
        }

        if let error = json["error"] as? [String: Any] {
            let msg = (error["message"] as? String) ?? "unknown"
            return .failure(.rpcError(msg))
        }

        guard let result = json["result"], !(result is NSNull) else {
            return .failure(.rpcError("daemon returned an empty result"))
        }
        return .success(result)
    }

    private func daemonBinaryPath() -> String? {
        let fm = FileManager.default
        let projectDir = termMeshEnv("PROJECT_DIR") ?? ""
        let isTagged = termMeshEnv("TAG") != nil

        // Option 0: Explicit binary path override
        if let explicit = termMeshEnv("DAEMON_BINARY_PATH"),
           fm.fileExists(atPath: explicit) { return explicit }

        // Option 1: App bundle Resources/bin/ (tagged builds use their snapshot copy)
        if let resourcePath = Bundle.main.resourcePath {
            let resourceBinPath = (resourcePath as NSString).appendingPathComponent("bin/term-meshd")
            if fm.fileExists(atPath: resourceBinPath) {
                // Tagged builds always prefer bundle binary for isolation
                if isTagged { return resourceBinPath }
            }
        }

        // Option 2: Built in the daemon/ directory (untagged development — debug then release)
        for config in ["debug", "release"] {
            let path = projectDir + "/daemon/target/\(config)/term-meshd"
            if !path.hasPrefix("/daemon") && fm.fileExists(atPath: path) { return path }
        }

        // Option 3: App bundle fallback (release DMG layout, untagged)
        if let resourcePath = Bundle.main.resourcePath {
            let resourceBinPath = (resourcePath as NSString).appendingPathComponent("bin/term-meshd")
            if fm.fileExists(atPath: resourceBinPath) { return resourceBinPath }
        }

        // Option 4: Next to the app executable (legacy layout)
        if let bundlePath = Bundle.main.executablePath {
            let dir = (bundlePath as NSString).deletingLastPathComponent
            let bundledPath = (dir as NSString).appendingPathComponent("term-meshd")
            if fm.fileExists(atPath: bundledPath) { return bundledPath }
        }

        // Option 5: ~/bin/term-meshd (user install via make deploy)
        let homeBin = (NSHomeDirectory() as NSString).appendingPathComponent("bin/term-meshd")
        if fm.fileExists(atPath: homeBin) { return homeBin }

        // Option 6: Hardcoded project path (development fallback)
        for config in ["release", "debug"] {
            let path = "/Users/jinwoo/work/project/term-mesh/daemon/target/\(config)/term-meshd"
            if fm.fileExists(atPath: path) { return path }
        }

        return nil
    }

    private func parseWorktreeInfo(_ obj: Any?) -> WorktreeInfo? {
        guard let dict = obj as? [String: Any],
              let name = dict["name"] as? String,
              let path = dict["path"] as? String,
              let branch = dict["branch"] as? String else { return nil }
        return WorktreeInfo(name: name, path: path, branch: branch)
    }

    // MARK: - Worktree Cleanup

    /// Remove all stale worktrees (those not bound to any active agent session).
    /// Skips dirty worktrees (uncommitted changes). Returns (removed, skippedDirty).
    func cleanupStaleWorktrees(repoPath: String) -> (removed: Int, skippedDirty: Int) {
        let worktrees = listWorktrees(repoPath: repoPath)
        let activeAgents = listAgents(includeTerminated: false)
        let activePaths = Set(activeAgents.map { $0.worktreePath })

        var removed = 0
        var skippedDirty = 0
        for wt in worktrees {
            if !activePaths.contains(wt.path) {
                let st = worktreeStatus(repoPath: repoPath, name: wt.name)
                if st.dirty {
                    skippedDirty += 1
                    continue
                }
                if removeWorktree(repoPath: repoPath, name: wt.name) {
                    removed += 1
                }
            }
        }
        return (removed, skippedDirty)
    }

    /// Sweep every repository that owns a worktree under the managed base
    /// directory.
    ///
    /// `cleanupStaleWorktrees(repoPath:)` needs the primary repo, but at quit
    /// all we have is the base directory. Each worktree's `.git` file names
    /// its owner, so resolve owners first and sweep each one once.
    func cleanupAllStaleWorktrees() -> (removed: Int, skippedDirty: Int) {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: worktreeBaseDir)
        guard let repoDirs = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var owners = Set<String>()
        for repoDir in repoDirs {
            let worktrees = (try? fm.contentsOfDirectory(
                at: repoDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for worktree in worktrees {
                guard let owner = Self.primaryRepoPath(ofWorktreeAt: worktree) else { continue }
                owners.insert(owner)
            }
        }

        var removed = 0
        var skippedDirty = 0
        for owner in owners.sorted() {
            let result = cleanupStaleWorktrees(repoPath: owner)
            removed += result.removed
            skippedDirty += result.skippedDirty
        }
        return (removed, skippedDirty)
    }

    /// Resolve the repository a linked worktree belongs to.
    ///
    /// A linked worktree's `.git` is a file reading
    /// `gitdir: <main>/.git/worktrees/<name>`, so the primary working
    /// directory is three levels above that path.
    static func primaryRepoPath(ofWorktreeAt path: URL) -> String? {
        guard let contents = try? String(contentsOf: path.appendingPathComponent(".git"), encoding: .utf8)
        else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }
        let gitdir = String(trimmed.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitdir.isEmpty else { return nil }
        let root = URL(fileURLWithPath: gitdir)
            .deletingLastPathComponent()   // worktrees/<name> -> worktrees
            .deletingLastPathComponent()   // worktrees -> .git
            .deletingLastPathComponent()   // .git -> repo root
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return root.path
    }
}

// MARK: - Data Models

struct WorktreeInfo {
    let name: String
    let path: String
    let branch: String
}

enum WorktreeCreateError: Error, CustomStringConvertible {
    case daemonNotConnected
    case notGitRepo
    case rpcError(String)

    var description: String {
        switch self {
        case .daemonNotConnected: return "daemon is not connected"
        case .notGitRepo: return "working directory is not a Git repository"
        case .rpcError(let message): return message
        }
    }
}

struct AgentSessionInfo {
    let id: String
    let name: String
    let repoPath: String
    let worktreeName: String
    let worktreePath: String
    let worktreeBranch: String
    let command: String?
    let status: String  // "spawning", "running", "suspended", "terminated"
    let pid: Int32?
    let panelId: String?
    let createdAtMs: UInt64
}

struct TaskInfo {
    let id: String
    let title: String
    let description: String?
    let status: String  // "pending", "assigned", "in_progress", "completed", "failed", "cancelled"
    let priority: Int
    let assignee: String?
    let createdBy: String?
    let deps: [String]
    let createdAtMs: UInt64
    let updatedAtMs: UInt64
}

struct TaskLogEntry {
    let id: Int64
    let taskId: String
    let agentId: String?
    let message: String
    let createdAtMs: UInt64
}

struct AgentMessageInfo {
    let id: Int64
    let fromAgent: String?
    let toAgent: String
    let content: String
    let read: Bool
    let createdAtMs: UInt64
}

struct PendingInputInfo {
    let sessionId: String
    let text: String
    let createdAtMs: UInt64
}
