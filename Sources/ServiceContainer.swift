import Foundation
import SwiftUI

/// Centralized dependency injection container.
///
/// All service instances are created once and shared across the app.
/// Components receive services via SwiftUI Environment, constructor injection,
/// or property injection — never via `.shared` singletons.
///
/// Usage:
/// ```swift
/// // At app root:
/// let services = ServiceContainer.shared
/// ContentView()
///     .environment(\.configProvider, services.config)
///     .environment(\.daemonService, services.daemon)
///     .environment(\.notificationService, services.notifications)
///     .environment(\.browserHistoryService, services.browserHistory)
/// ```
@MainActor
final class ServiceContainer {
    static let shared = ServiceContainer()

    // MARK: - Services

    let config: any GhosttyConfigProvider
    let daemon: any DaemonService
    let notifications: TerminalNotificationStore
    let browserHistory: any BrowserHistoryService

    // MARK: - Init

    init(
        config: (any GhosttyConfigProvider)? = nil,
        daemon: (any DaemonService)? = nil,
        notifications: TerminalNotificationStore? = nil,
        browserHistory: (any BrowserHistoryService)? = nil
    ) {
        self.config = config ?? GhosttyApp.shared
        self.daemon = daemon ?? TermMeshDaemon.shared
        self.notifications = notifications ?? TerminalNotificationStore.shared
        self.browserHistory = browserHistory ?? BrowserHistoryStore.shared
    }
}

// MARK: - SwiftUI View Extension

extension View {
    /// Inject all services from a ServiceContainer into the SwiftUI environment.
    func withServices(_ container: ServiceContainer = .shared) -> some View {
        self
            .environment(\.configProvider, container.config)
            .environment(\.daemonService, container.daemon)
            .environment(\.notificationService, container.notifications)
            .environment(\.browserHistoryService, container.browserHistory)
    }
}
