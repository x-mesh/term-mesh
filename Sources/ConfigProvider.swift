import AppKit

/// Protocol abstracting GhosttyApp's configuration API for testability and decoupling.
protocol GhosttyConfigProvider: AnyObject {
    var defaultBackgroundColor: NSColor { get }
    var defaultBackgroundOpacity: Double { get }
    var backgroundLogEnabled: Bool { get }
    var isScrolling: Bool { get }

    func reloadConfiguration(soft: Bool, source: String)
    func openConfigurationInTextEdit()
    func logBackground(_ message: String)
}

extension GhosttyApp: GhosttyConfigProvider {}

extension GhosttyConfigProvider {
    func logBackgroundIfEnabled(_ message: @autoclosure () -> String) {
        guard backgroundLogEnabled else { return }
        logBackground(message())
    }
}
