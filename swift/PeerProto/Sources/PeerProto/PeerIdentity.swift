import Foundation
import Security

public enum PeerIdentityError: Error, Equatable, CustomStringConvertible {
    case randomFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainAddFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case invalidStoredLength(Int)

    public var description: String {
        switch self {
        case .randomFailed(let status):
            return "SecRandomCopyBytes failed: \(status)"
        case .keychainReadFailed(let status):
            return "SecItemCopyMatching failed: \(status)"
        case .keychainAddFailed(let status):
            return "SecItemAdd failed: \(status)"
        case .keychainDeleteFailed(let status):
            return "SecItemDelete failed: \(status)"
        case .invalidStoredLength(let length):
            return "stored peer id has invalid length: \(length)"
        }
    }
}

public enum PeerIdentity {
    public static let service = "com.termmesh.peer-identity"
    public static let account = "default"
    public static let byteCount = 16
    public static let historyLimit = 8
    static let debugDefaultsSuitePrefix = "com.termmesh.peer-identity.debug"
    static let debugDefaultsKey = "installation-id-v1"
    static let debugHistoryDefaultsKey = "installation-id-history-v1"
    static let historyAccountSuffix = ".history-v1"

    /// In-memory cache for `defaultPeerID()`. `SecItemCopyMatching` is a
    /// synchronous IPC to securityd — seconds-slow on unsigned dev
    /// builds awaiting keychain authorization — and the peer ID gets
    /// evaluated as a handshake default argument, sometimes on the main
    /// actor. Cache after the first load so only one call ever pays;
    /// `warmUp()` lets the app pay it off-main at startup.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedID: Data?
    nonisolated(unsafe) private static var cachedPreviousIDs: [Data]?

    public static func loadOrCreate() throws -> Data {
        try loadOrCreate(service: service, account: account)
    }

    public static func regenerate() throws -> Data {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let id: Data
        if usesEphemeralIdentity() {
            id = try makeRandomID()
            cachedPreviousIDs = []
        } else if usesDebugDefaultsIdentity() {
            let result = try regenerateDebugIdentity(defaults: debugDefaults())
            id = result.id
            cachedPreviousIDs = result.history
        } else {
            id = try regenerate(service: service, account: account)
            cachedPreviousIDs = try loadPreviousIDs(service: service, account: account)
        }
        cachedID = id
        return id
    }

    public static func defaultPeerID() -> Data {
        // The keychain load runs INSIDE the lock, not around it: two
        // threads entering SecItemCopyMatching concurrently (e.g. the
        // startup warm-up and a handshake's default argument) contend on
        // securityd's own mutex and stall for seconds on unsigned dev
        // builds. Serializing here means exactly one keychain call ever
        // happens; every later caller reads the cache.
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedID { return cachedID }
        if usesEphemeralIdentity() {
            let id = (try? makeRandomID()) ?? Data(count: byteCount)
            cachedID = id
            return id
        }
        if usesDebugDefaultsIdentity() {
            let id = (try? loadOrCreateDebugIdentity()) ?? ((try? makeRandomID()) ?? Data(count: byteCount))
            cachedID = id
            return id
        }
        let id = (try? loadOrCreate()) ?? ((try? makeRandomID()) ?? Data(count: byteCount))
        cachedID = id
        return id
    }

    public static func previousPeerIDs() -> [Data] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedPreviousIDs { return cachedPreviousIDs }
        let ids: [Data]
        if usesEphemeralIdentity() {
            ids = []
        } else if usesDebugDefaultsIdentity() {
            ids = loadDebugHistory(defaults: debugDefaults())
        } else {
            ids = (try? loadPreviousIDs(service: service, account: account)) ?? []
        }
        cachedPreviousIDs = ids
        return ids
    }

    /// Whether to use a process-lifetime random ID.
    ///
    /// Tests remain ephemeral so parallel test processes cannot accidentally
    /// share ownership. Debug apps use a separate UserDefaults-backed identity
    /// instead; that avoids keychain ACL prompts while surviving app relaunches.
    static func usesEphemeralIdentity(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isRunningTests: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        if environment["TERMMESH_PEER_IDENTITY_EPHEMERAL"] == "1" { return true }
        // Escape hatch for dev work that genuinely needs a stable peer ID
        // (verifying a peer recognizes this Mac across relaunches).
        if environment["TERMMESH_PEER_IDENTITY_KEYCHAIN"] == "1" { return false }
        return isRunningTests
    }

    static func usesDebugDefaultsIdentity(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isRunningTests: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        if environment["TERMMESH_PEER_IDENTITY_KEYCHAIN"] == "1" { return false }
        if usesEphemeralIdentity(environment: environment, isRunningTests: isRunningTests) {
            return false
        }
        // Release bundles are `com.termmesh.app`; every dev build carries a
        // `.debug` component, tagged ones appending the tag after it.
        return (bundleIdentifier ?? "").contains(".debug")
    }

    /// Prime the keychain-backed cache off the critical path (call from
    /// a background queue during app startup).
    public static func warmUp() {
        _ = defaultPeerID()
        _ = previousPeerIDs()
    }

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func loadOrCreate(service: String, account: String) throws -> Data {
        if let existing = try load(service: service, account: account) {
            return existing
        }
        let created = try makeRandomID()
        do {
            try save(created, service: service, account: account)
            return created
        } catch PeerIdentityError.keychainAddFailed(let status) where status == errSecDuplicateItem {
            if let existing = try load(service: service, account: account) {
                return existing
            }
            throw PeerIdentityError.keychainReadFailed(errSecItemNotFound)
        }
    }

    static func loadOrCreateDebugIdentity(defaults: UserDefaults = debugDefaults()) throws -> Data {
        if let existing = defaults.data(forKey: debugDefaultsKey) {
            if existing.count == byteCount { return existing }
            defaults.removeObject(forKey: debugDefaultsKey)
        }
        let created = try makeRandomID()
        defaults.set(created, forKey: debugDefaultsKey)
        return created
    }

    private static func debugDefaults() -> UserDefaults {
        UserDefaults(suiteName: debugDefaultsSuiteName()) ?? .standard
    }

    static func debugDefaultsSuiteName(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [debugDefaultsSuitePrefix, bundle?.isEmpty == false ? bundle : "unknown"]
            .compactMap { $0 }
            .joined(separator: ".")
    }

    static func regenerate(service: String, account: String) throws -> Data {
        let previous = try loadOrCreate(service: service, account: account)
        let history = try loadPreviousIDs(service: service, account: account)
        try savePreviousIDs(
            updatedHistory(previous: previous, existing: history),
            service: service,
            account: account
        )
        let id = try makeRandomID()
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeerIdentityError.keychainDeleteFailed(status)
        }
        try save(id, service: service, account: account)
        return id
    }

    static func deleteStoredIdentity(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeerIdentityError.keychainDeleteFailed(status)
        }
        let historyStatus = SecItemDelete(
            baseQuery(service: service, account: historyAccount(account)) as CFDictionary
        )
        guard historyStatus == errSecSuccess || historyStatus == errSecItemNotFound else {
            throw PeerIdentityError.keychainDeleteFailed(historyStatus)
        }
    }

    static func loadPreviousIDs(service: String, account: String) throws -> [Data] {
        guard let packed = try loadData(service: service, account: historyAccount(account)) else {
            return []
        }
        guard packed.count % byteCount == 0 else {
            throw PeerIdentityError.invalidStoredLength(packed.count)
        }
        return stride(from: 0, to: packed.count, by: byteCount).map {
            packed.subdata(in: $0..<($0 + byteCount))
        }.prefix(historyLimit).map { $0 }
    }

    static func loadDebugHistory(defaults: UserDefaults) -> [Data] {
        guard let stored = defaults.array(forKey: debugHistoryDefaultsKey) as? [Data] else { return [] }
        return Array(stored.filter { $0.count == byteCount }.prefix(historyLimit))
    }

    static func regenerateDebugIdentity(defaults: UserDefaults) throws -> (id: Data, history: [Data]) {
        let previous = try loadOrCreateDebugIdentity(defaults: defaults)
        let history = updatedHistory(previous: previous, existing: loadDebugHistory(defaults: defaults))
        let id = try makeRandomID()
        defaults.set(history, forKey: debugHistoryDefaultsKey)
        defaults.set(id, forKey: debugDefaultsKey)
        return (id, history)
    }

    private static func updatedHistory(previous: Data, existing: [Data]) -> [Data] {
        Array(([previous] + existing.filter { $0 != previous }).prefix(historyLimit))
    }

    private static func savePreviousIDs(_ ids: [Data], service: String, account: String) throws {
        let packed = ids.prefix(historyLimit).reduce(into: Data()) { $0.append($1) }
        let historyAccount = historyAccount(account)
        let status = SecItemDelete(baseQuery(service: service, account: historyAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeerIdentityError.keychainDeleteFailed(status)
        }
        if !packed.isEmpty {
            try save(packed, service: service, account: historyAccount, validatesIdentityLength: false)
        }
    }

    private static func historyAccount(_ account: String) -> String {
        account + historyAccountSuffix
    }

    private static func load(service: String, account: String) throws -> Data? {
        guard let data = try loadData(service: service, account: account) else { return nil }
        guard data.count == byteCount else {
            throw PeerIdentityError.invalidStoredLength(data.count)
        }
        return data
    }

    private static func loadData(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw PeerIdentityError.keychainReadFailed(status)
        }
        guard let data = result as? Data else {
            throw PeerIdentityError.invalidStoredLength(0)
        }
        return data
    }

    private static func save(
        _ data: Data,
        service: String,
        account: String,
        validatesIdentityLength: Bool = true
    ) throws {
        guard !validatesIdentityLength || data.count == byteCount else {
            throw PeerIdentityError.invalidStoredLength(data.count)
        }
        var item = baseQuery(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PeerIdentityError.keychainAddFailed(status)
        }
    }

    private static func makeRandomID() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PeerIdentityError.randomFailed(status)
        }
        return Data(bytes)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
