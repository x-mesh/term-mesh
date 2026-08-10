import Foundation

/// One validation contract for `EnsureSurfaceRequest.env`, shared by the
/// wire client and the app's saved-host editor/launch path.
public enum PeerEnsureEnvironment {
    public static let maximumCount = 64
    public static let maximumKeyUTF8Bytes = 128
    public static let maximumValueUTF8Bytes = 4_096
    public static let maximumTotalUTF8Bytes = 65_536

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case tooManyEntries(actual: Int)
        case invalidKey(String)
        case keyTooLong(String)
        case valueTooLong(key: String)
        case valueContainsNUL(key: String)
        case totalTooLarge(actual: Int)

        public var errorDescription: String? {
            switch self {
            case .tooManyEntries(let actual):
                return "Environment has \(actual) entries; at most \(maximumCount) are allowed."
            case .invalidKey(let key):
                return "Environment key '\(key)' must be an ASCII identifier (A-Z, a-z, 0-9, _)."
            case .keyTooLong(let key):
                return "Environment key '\(key)' exceeds \(maximumKeyUTF8Bytes) bytes."
            case .valueTooLong(let key):
                return "Environment value for '\(key)' exceeds \(maximumValueUTF8Bytes) bytes."
            case .valueContainsNUL(let key):
                return "Environment value for '\(key)' contains NUL."
            case .totalTooLarge(let actual):
                return "Environment uses \(actual) bytes; at most \(maximumTotalUTF8Bytes) are allowed."
            }
        }
    }

    public static func validate(_ environment: [String: String]) throws {
        guard environment.count <= maximumCount else {
            throw ValidationError.tooManyEntries(actual: environment.count)
        }
        var total = 0
        for (key, value) in environment {
            let keyBytes = Array(key.utf8)
            guard keyBytes.count <= maximumKeyUTF8Bytes else {
                throw ValidationError.keyTooLong(key)
            }
            let portable = !keyBytes.isEmpty && keyBytes.enumerated().allSatisfy { index, byte in
                byte == 0x5f
                    || (0x41...0x5a).contains(byte)
                    || (0x61...0x7a).contains(byte)
                    || (index > 0 && (0x30...0x39).contains(byte))
            }
            guard portable else { throw ValidationError.invalidKey(key) }
            guard value.utf8.count <= maximumValueUTF8Bytes else {
                throw ValidationError.valueTooLong(key: key)
            }
            guard !value.contains("\0") else {
                throw ValidationError.valueContainsNUL(key: key)
            }
            total += keyBytes.count + value.utf8.count
            guard total <= maximumTotalUTF8Bytes else {
                throw ValidationError.totalTooLarge(actual: total)
            }
        }
    }

    public static func validatedPairs(
        _ environment: [String: String]
    ) throws -> [(key: String, value: String)] {
        try validate(environment)
        return environment.sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }
}
