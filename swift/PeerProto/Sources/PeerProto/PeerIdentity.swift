import Foundation
import Security

public enum PeerIdentityError: Error, Equatable, CustomStringConvertible {
    case randomFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainAddFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case fileReadFailed(String)
    case fileWriteFailed(String)
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
        case .fileReadFailed(let message):
            return "peer identity file read failed: \(message)"
        case .fileWriteFailed(let message):
            return "peer identity file write failed: \(message)"
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
    static let identityFileName = "peer-identity-v1.json"

    private struct StoredIdentity: Codable {
        let version: Int
        var id: Data
        var history: [Data]
    }

    /// In-memory cache for `defaultPeerID()`. Existing installs make one
    /// legacy Keychain read while migrating; later loads use the identity
    /// file and avoid synchronous securityd IPC entirely.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedID: Data?
    nonisolated(unsafe) private static var cachedPreviousIDs: [Data]?

    public static func loadOrCreate() throws -> Data {
        try loadOrCreateFileIdentity().id
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
            let result = try regenerateFileIdentity()
            id = result.id
            cachedPreviousIDs = result.history
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
            ids = (try? loadOrCreateFileIdentity().history) ?? []
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

    /// Prime the file-backed cache off the critical path. Existing installs
    /// can perform a one-time legacy Keychain migration here.
    public static func warmUp() {
        _ = defaultPeerID()
        _ = previousPeerIDs()
    }

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadOrCreateFileIdentity() throws -> StoredIdentity {
        let loaded = try loadOrCreateFileIdentity(
            at: identityFileURL(),
            // A denied or unreadable legacy item must not leave migration
            // pending forever. Generate a new file identity instead, so the
            // next launch never repeats the authorization prompt.
            legacyIdentityLoader: { try load(service: service, account: account) },
            legacyHistoryLoader: { try loadPreviousIDs(service: service, account: account) }
        )
        return StoredIdentity(version: 1, id: loaded.id, history: loaded.history)
    }

    static func loadOrCreateFileIdentity(
        at fileURL: URL,
        legacyIdentityLoader: () throws -> Data?,
        legacyHistoryLoader: () throws -> [Data]
    ) throws -> (id: Data, history: [Data]) {
        // A malformed file must not trap the installation on a process-local
        // random ID forever. If it cannot be decoded, fall through to the same
        // migration/create path used when the file is absent; the atomic write
        // below replaces it only after a durable identity is ready.
        if let stored = try? readStoredIdentity(at: fileURL) {
            return (stored.id, stored.history)
        }

        // The Keychain fallback is intentionally reachable only when the file
        // is absent. Once this write succeeds, later app updates never ask
        // securityd to authorize the ad-hoc-signed binary again.
        let legacyID = try? legacyIdentityLoader()
        let id = try legacyID ?? makeRandomID()
        // If the current legacy item was unavailable, do not make a second
        // Keychain request for history. That could show another authorization
        // dialog even though the new file identity is already sufficient.
        let legacyHistory = legacyID == nil ? [] : ((try? legacyHistoryLoader()) ?? [])
        let history = try validatedHistory(legacyHistory)
        let stored = StoredIdentity(version: 1, id: id, history: history)
        try writeStoredIdentity(stored, to: fileURL)
        return (id, history)
    }

    private static func regenerateFileIdentity() throws -> StoredIdentity {
        var stored = try loadOrCreateFileIdentity()
        stored.history = updatedHistory(previous: stored.id, existing: stored.history)
        stored.id = try makeRandomID()
        try writeStoredIdentity(stored, to: identityFileURL())
        return stored
    }

    static func identityFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PeerIdentityError.fileReadFailed("Application Support directory unavailable")
        }
        return appSupport
            .appendingPathComponent("term-mesh", isDirectory: true)
            .appendingPathComponent(identityFileName)
    }

    private static func readStoredIdentity(at fileURL: URL) throws -> StoredIdentity? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try JSONDecoder().decode(StoredIdentity.self, from: data)
            guard stored.version == 1 else {
                throw PeerIdentityError.fileReadFailed("unsupported version \(stored.version)")
            }
            guard stored.id.count == byteCount else {
                throw PeerIdentityError.invalidStoredLength(stored.id.count)
            }
            return StoredIdentity(
                version: stored.version,
                id: stored.id,
                // History is advisory ownership context. Preserve a valid
                // current ID even if one old alias was damaged.
                history: Array(stored.history.filter { $0.count == byteCount }.prefix(historyLimit))
            )
        } catch let error as PeerIdentityError {
            throw error
        } catch {
            throw PeerIdentityError.fileReadFailed(error.localizedDescription)
        }
    }

    private static func writeStoredIdentity(_ stored: StoredIdentity, to fileURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw PeerIdentityError.fileWriteFailed(error.localizedDescription)
        }
    }

    private static func validatedHistory(_ ids: [Data]) throws -> [Data] {
        if let invalid = ids.first(where: { $0.count != byteCount }) {
            throw PeerIdentityError.invalidStoredLength(invalid.count)
        }
        return Array(ids.prefix(historyLimit))
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
