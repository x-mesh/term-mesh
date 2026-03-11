import Foundation
import os

extension Logger {
    /// Main app logger
    static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.termmesh", category: "app")
    /// Socket/terminal controller logger
    static let socket = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.termmesh", category: "socket")
    /// Daemon logger
    static let daemon = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.termmesh", category: "daemon")
    /// Team orchestrator logger
    static let team = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.termmesh", category: "team")
    /// UI logger
    static let ui = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.termmesh", category: "ui")
}
