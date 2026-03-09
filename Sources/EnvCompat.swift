import Foundation

/// Reads environment variable with TERMMESH_* primary, CMUX_* fallback.
func termMeshEnv(_ key: String) -> String? {
    ProcessInfo.processInfo.environment["TERMMESH_\(key)"]
        ?? ProcessInfo.processInfo.environment["CMUX_\(key)"]
}
