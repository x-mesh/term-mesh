import Foundation
import Security
import os

enum SocketControlMode: String, CaseIterable, Identifiable {
    case off
    case termMeshOnly
    case automation
    case password
    /// Full open access (all local users/processes) with no ancestry or password gate.
    case allowAll

    var id: String { rawValue }

    static var uiCases: [SocketControlMode] { [.off, .termMeshOnly, .automation, .password, .allowAll] }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .termMeshOnly:
            return "Term-Mesh processes only"
        case .automation:
            return "Automation mode"
        case .password:
            return "Password mode"
        case .allowAll:
            return "Full open access"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Disable the local control socket."
        case .termMeshOnly:
            return "Only processes started inside term-mesh terminals can send commands."
        case .automation:
            return "Allow external local automation clients from this macOS user (no ancestry check)."
        case .password:
            return "Require socket authentication with a password stored in your keychain."
        case .allowAll:
            return "Allow any local process and user to connect with no auth. Unsafe."
        }
    }

    var socketFilePermissions: UInt16 {
        switch self {
        case .allowAll:
            // 0o600: owner-only — group-write removed to prevent same-group,
            // different-UID processes from injecting PTY commands via the socket.
            return 0o600
        case .off, .termMeshOnly, .automation, .password:
            return 0o600
        }
    }

    var requiresPasswordAuth: Bool {
        self == .password
    }
}

enum SocketControlPasswordStore {
    static let service = "com.termmesh.app.socket-control"
    static let account = "local-socket-password"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func configuredPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let envPassword = environment[SocketControlSettings.socketPasswordEnvKey] ?? environment[SocketControlSettings.socketPasswordEnvKeyLegacy], !envPassword.isEmpty {
            return envPassword
        }
        return try? loadPassword()
    }

    static func hasConfiguredPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let configured = configuredPassword(environment: environment) else { return false }
        return !configured.isEmpty
    }

    static func verify(
        password candidate: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let expected = configuredPassword(environment: environment), !expected.isEmpty else {
            return false
        }
        // Constant-time comparison to prevent timing side-channel attacks
        let expectedBytes = Array(expected.utf8)
        let candidateBytes = Array(candidate.utf8)
        guard expectedBytes.count == candidateBytes.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(expectedBytes, candidateBytes) {
            result |= a ^ b
        }
        return result == 0
    }

    static func loadPassword() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func savePassword(_ password: String) throws {
        let normalized = password.trimmingCharacters(in: .newlines)
        if normalized.isEmpty {
            try clearPassword()
            return
        }

        let data = Data(normalized.utf8)
        var lookup = baseQuery
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var existing: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, &existing)
        switch lookupStatus {
        case errSecSuccess:
            let attrsToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrsToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
            }
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(lookupStatus))
        }
    }

    static func clearPassword() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

struct SocketControlSettings {
    static let appStorageKey = "socketControlMode"
    static let legacyEnabledKey = "socketControlEnabled"
    static let allowSocketPathOverrideKey = "TERMMESH_ALLOW_SOCKET_OVERRIDE"
    static let allowSocketPathOverrideKeyLegacy = "CMUX_ALLOW_SOCKET_OVERRIDE"
    static let socketPasswordEnvKey = "TERMMESH_SOCKET_PASSWORD"
    static let socketPasswordEnvKeyLegacy = "CMUX_SOCKET_PASSWORD"

    // MARK: - allowAll Auto-Expiry

    /// Duration after which allowAll mode automatically reverts to termMeshOnly.
    /// This limits the exposure window if a developer accidentally leaves the app
    /// running in allowAll mode (e.g. after a test session).
    static let allowAllExpiryInterval: TimeInterval = 3600 // 1 hour

    private static let allowAllLock = NSLock()
    /// Timestamp when allowAll mode was first entered in this process lifetime.
    /// Reset to nil when mode leaves allowAll.
    private static var allowAllActivatedAt: Date? = nil
    /// Pending work item that fires after allowAllExpiryInterval to enforce auto-downgrade.
    /// Cancellable so that an explicit mode change before expiry stops the timer.
    private static var allowAllExpiryWorkItem: DispatchWorkItem? = nil

    private static let logger = Logger(subsystem: "com.termmesh.app", category: "socket-security")

    /// Emit a one-time security warning when allowAll mode activates.
    /// Prints to stderr (visible in terminal) and os_log (visible in Console.app).
    static func logAllowAllSecurityWarning() {
        let msg = "[term-mesh security] allowAll socket mode active — the control socket " +
            "accepts connections from any process in the owner group. " +
            "Commands include keystroke injection, terminal read, and browser JS eval. " +
            "Mode reverts automatically after \(Int(allowAllExpiryInterval / 60)) minutes. " +
            "Disable via Settings → Socket Control or TERMMESH_SOCKET_MODE=termMeshOnly."
        fputs(msg + "\n", stderr)
        logger.warning("\(msg, privacy: .public)")
    }

    /// Log when allowAll mode expires and downgrades automatically.
    static func logAllowAllExpiry() {
        let msg = "[term-mesh security] allowAll socket mode expired after " +
            "\(Int(allowAllExpiryInterval / 60)) minutes — reverted to termMeshOnly."
        fputs(msg + "\n", stderr)
        logger.notice("\(msg, privacy: .public)")
    }

    private static func normalizeMode(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func parseMode(_ raw: String) -> SocketControlMode? {
        switch normalizeMode(raw) {
        case "off":
            return .off
        case "termmeshonly":
            return .termMeshOnly
        case "automation":
            return .automation
        case "password":
            return .password
        case "allowall", "openaccess", "fullopenaccess":
            return .allowAll
        // Legacy values from the old socket mode model.
        case "notifications":
            return .automation
        case "full":
            return .allowAll
        default:
            return nil
        }
    }

    /// Map persisted values to the current enum values.
    static func migrateMode(_ raw: String) -> SocketControlMode {
        parseMode(raw) ?? defaultMode
    }

    static var defaultMode: SocketControlMode {
        return .termMeshOnly
    }

    private static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild
    ) -> String {
        let fallback = defaultSocketPath(bundleIdentifier: bundleIdentifier, isDebugBuild: isDebugBuild)

        guard let override = environment["TERMMESH_SOCKET_PATH"] ?? environment["CMUX_SOCKET_PATH"], !override.isEmpty else {
            return fallback
        }

        if shouldHonorSocketPathOverride(
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            isDebugBuild: isDebugBuild
        ) {
            return override
        }

        return fallback
    }

    static func defaultSocketPath(bundleIdentifier: String?, isDebugBuild: Bool) -> String {
        if bundleIdentifier == "com.termmesh.app.nightly" {
            return "/tmp/term-mesh-nightly.sock"
        }
        if isDebugLikeBundleIdentifier(bundleIdentifier) || isDebugBuild {
            return "/tmp/term-mesh-debug.sock"
        }
        if isStagingBundleIdentifier(bundleIdentifier) {
            return "/tmp/term-mesh-staging.sock"
        }
        return "/tmp/term-mesh.sock"
    }

    static func shouldHonorSocketPathOverride(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool
    ) -> Bool {
        if isTruthy(environment[allowSocketPathOverrideKey] ?? environment[allowSocketPathOverrideKeyLegacy]) {
            return true
        }
        if isDebugLikeBundleIdentifier(bundleIdentifier) || isStagingBundleIdentifier(bundleIdentifier) {
            return true
        }
        return isDebugBuild
    }

    static func isDebugLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.termmesh.app.debug"
            || bundleIdentifier.hasPrefix("com.termmesh.app.debug.")
    }

    static func isStagingBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.termmesh.app.staging"
            || bundleIdentifier.hasPrefix("com.termmesh.app.staging.")
    }

    static func isTruthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static func envOverrideEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        guard let raw = environment["TERMMESH_SOCKET_ENABLE"] ?? environment["CMUX_SOCKET_ENABLE"], !raw.isEmpty else {
            return nil
        }

        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    static func envOverrideMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SocketControlMode? {
        guard let raw = environment["TERMMESH_SOCKET_MODE"] ?? environment["CMUX_SOCKET_MODE"], !raw.isEmpty else {
            return nil
        }
        return parseMode(raw)
    }

    static func effectiveMode(
        userMode: SocketControlMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SocketControlMode {
        let resolved: SocketControlMode
        if let overrideEnabled = envOverrideEnabled(environment: environment) {
            if !overrideEnabled {
                resolved = .off
            } else if let overrideMode = envOverrideMode(environment: environment) {
                resolved = overrideMode
            } else {
                resolved = userMode == .off ? .termMeshOnly : userMode
            }
        } else if let overrideMode = envOverrideMode(environment: environment) {
            resolved = overrideMode
        } else {
            resolved = userMode
        }

        return applyAllowAllPolicy(resolved)
    }

    /// Apply allowAll-specific security policy:
    /// - On first entry to allowAll, record activation time, emit a security warning, and
    ///   schedule a DispatchWorkItem that fires after allowAllExpiryInterval. The work item
    ///   writes termMeshOnly to UserDefaults, which triggers the @AppStorage binding →
    ///   onChange(of: socketControlMode) → updateSocketController() chain — actually
    ///   restarting the socket with the downgraded mode regardless of whether effectiveMode()
    ///   is ever called again.
    /// - If the mode exits allowAll before expiry, cancel the pending work item.
    /// - Defensive time check on each effectiveMode() call catches any edge cases where
    ///   the work item was cancelled or the env var overrides UserDefaults.
    private static func applyAllowAllPolicy(_ mode: SocketControlMode) -> SocketControlMode {
        allowAllLock.lock()
        defer { allowAllLock.unlock() }

        guard mode == .allowAll else {
            // Exiting allowAll — cancel pending expiry timer and clear state.
            allowAllExpiryWorkItem?.cancel()
            allowAllExpiryWorkItem = nil
            allowAllActivatedAt = nil
            return mode
        }

        let now = Date()

        // Defensive check: time-based expiry in case work item was cancelled externally.
        if let activatedAt = allowAllActivatedAt {
            if now.timeIntervalSince(activatedAt) >= allowAllExpiryInterval {
                allowAllExpiryWorkItem?.cancel()
                allowAllExpiryWorkItem = nil
                allowAllActivatedAt = nil
                DispatchQueue.global(qos: .background).async { logAllowAllExpiry() }
                return .termMeshOnly
            }
            // Timer already scheduled; still within the expiry window.
            return .allowAll
        }

        // First activation — record timestamp, warn, and schedule the hard expiry timer.
        allowAllActivatedAt = now

        // The work item runs on the main queue after allowAllExpiryInterval.
        // Writing to UserDefaults triggers @AppStorage(appStorageKey) bindings in
        // TermMeshApp/SettingsView, which calls updateSocketController() and actually
        // restarts the socket in termMeshOnly mode — no polling required.
        let workItem = DispatchWorkItem {
            logAllowAllExpiry()
            UserDefaults.standard.set(SocketControlMode.termMeshOnly.rawValue, forKey: appStorageKey)
        }
        allowAllExpiryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + allowAllExpiryInterval, execute: workItem)

        DispatchQueue.global(qos: .background).async { logAllowAllSecurityWarning() }
        return .allowAll
    }
}

// MARK: - Socket health

/// Health of the app's Unix control socket listener (`/tmp/term-mesh.sock`).
///
/// The socket can be in three observable states. `halfDead` is the failure mode
/// behind the "Connection refused while the app is running" incident: the
/// `serverSocket` fd is still held but `acceptLoop()` has exited, so no incoming
/// connection is ever serviced.
enum SocketHealth: Equatable {
    /// Listening and the accept loop is servicing connections.
    case healthy
    /// Socket fd is held but the accept loop has died — needs recovery.
    case halfDead
    /// Not listening (stopped or never started).
    case stopped

    var shortLabel: String {
        switch self {
        case .healthy: return "Socket OK"
        case .halfDead: return "Socket stalled"
        case .stopped: return "Socket off"
        }
    }
}

/// Observable socket-health state for SwiftUI.
///
/// Updates are **pushed at transition points only** (end of `start()`, `stop()`,
/// and the `acceptLoop()` exit path) — there is no polling, per the socket
/// telemetry threading policy. UI binds to `@Published health` and reacts to
/// changes; `update(_:)` is a no-op when the value is unchanged.
@MainActor
final class SocketStatusModel: ObservableObject {
    static let shared = SocketStatusModel()

    @Published private(set) var health: SocketHealth = .stopped

    private init() {}

    /// Push a new health value. No-ops when unchanged so SwiftUI doesn't churn.
    func update(_ newHealth: SocketHealth) {
        guard health != newHealth else { return }
        health = newHealth
    }
}
