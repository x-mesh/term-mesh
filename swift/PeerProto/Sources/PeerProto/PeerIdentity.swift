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

    /// In-memory cache for `defaultPeerID()`. `SecItemCopyMatching` is a
    /// synchronous IPC to securityd — seconds-slow on unsigned dev
    /// builds awaiting keychain authorization — and the peer ID gets
    /// evaluated as a handshake default argument, sometimes on the main
    /// actor. Cache after the first load so only one call ever pays;
    /// `warmUp()` lets the app pay it off-main at startup.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedID: Data?

    public static func loadOrCreate() throws -> Data {
        try loadOrCreate(service: service, account: account)
    }

    public static func regenerate() throws -> Data {
        cacheLock.lock()
        cachedID = nil
        cacheLock.unlock()
        return try regenerate(service: service, account: account)
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
        let id = (try? loadOrCreate()) ?? ((try? makeRandomID()) ?? Data(count: byteCount))
        cachedID = id
        return id
    }

    /// Prime the keychain-backed cache off the critical path (call from
    /// a background queue during app startup).
    public static func warmUp() {
        _ = defaultPeerID()
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

    static func regenerate(service: String, account: String) throws -> Data {
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
    }

    private static func load(service: String, account: String) throws -> Data? {
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
        guard data.count == byteCount else {
            throw PeerIdentityError.invalidStoredLength(data.count)
        }
        return data
    }

    private static func save(_ data: Data, service: String, account: String) throws {
        guard data.count == byteCount else {
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
