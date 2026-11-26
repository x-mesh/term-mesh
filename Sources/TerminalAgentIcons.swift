import AppKit

/// An agent CLI the daemon's `PaneTracker` reports running in a terminal pane.
enum TerminalAgentCLI: String, CaseIterable {
    case claude
    case codex
    case kiro
    case gemini
    case opencode
    case neovim
    case tmux
    case zellij
    case lazygit
    case k9s
    case systemMonitor = "system-monitor"
    case python
    case node

    var symbolName: String? {
        switch self {
        case .claude, .codex: return nil
        case .kiro: return "wand.and.stars"
        case .gemini: return "sparkles"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .neovim: return "pencil.and.outline"
        case .tmux: return "rectangle.split.2x1"
        case .zellij: return "rectangle.split.3x1"
        case .lazygit: return "arrow.triangle.branch"
        case .k9s: return "shippingbox"
        case .systemMonitor: return "chart.xyaxis.line"
        case .python: return "curlybraces"
        case .node: return "hexagon"
        }
    }

    /// The logo for the tab strip, which draws `iconImageData` in full color.
    var iconPNGData: Data? {
        switch self {
        case .claude: return Self.claudeIcon
        case .codex: return Self.codexIcon
        default: return nil
        }
    }

    private static let claudeIcon = pngData(named: "ClaudeLogo")
    private static let codexIcon = pngData(named: "CodexLogo")

    /// Renders the asset at a fixed size: the Codex logo is a vector asset,
    /// and the tab decodes whatever bytes it gets with `NSImage(data:)`.
    private static func pngData(named name: String, side: Int = 64) -> Data? {
        guard let image = NSImage(named: name),
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: side,
                  pixelsHigh: side,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Puts the logo of the agent CLI running in each local terminal pane on its
/// tab, and the terminal glyph back once the CLI exits.
@MainActor
final class TerminalAgentIconMonitor {
    static let shared = TerminalAgentIconMonitor()

    /// The daemon uses the same cadence. Keeping both at 250 ms bounds a
    /// foreground-app transition to roughly half a second without an event
    /// protocol or a versioned wire change.
    static let interval: TimeInterval = 0.25

    private var timer: Timer?
    private var pollInFlight = false
    private var lastSnapshot: [String: String]?
    private let queue = DispatchQueue(label: "term-mesh.terminal-agent-icons", qos: .utility)

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        queue.async {
            let panes = TermMeshDaemon.shared.paneAgents()
            DispatchQueue.main.async {
                self.pollInFlight = false
                // No answer (daemon not running, or older than `pane.agents`):
                // leave the icons as they are rather than clearing them.
                guard let panes, panes != self.lastSnapshot else { return }
                self.lastSnapshot = panes
                self.apply(panes)
            }
        }
    }

    private func apply(_ panes: [String: String]) {
        guard let app = AppDelegate.shared, let fallback = app.tabManager else { return }
        let agents = Self.agents(from: panes)
        for manager in SessionHostPanes.allTabManagers(app: app, fallback: fallback) {
            for workspace in manager.tabs {
                workspace.applyTerminalAgents(agents)
            }
        }
    }

    /// Daemon keys are `TERMMESH_PANEL_ID`, the panel's `uuidString`.
    nonisolated static func agents(from panes: [String: String]) -> [UUID: TerminalAgentCLI] {
        panes.reduce(into: [:]) { result, entry in
            guard let id = UUID(uuidString: entry.key),
                  let cli = TerminalAgentCLI(rawValue: entry.value) else { return }
            result[id] = cli
        }
    }
}
