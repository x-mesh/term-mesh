import Foundation

// Phase B4: GUI agent pane scrollback poller. Headless agents already get
// auto-reply via the Rust daemon's PTY reader (see auto_reply_emit.rs);
// this is the equivalent path for GUI agents, where ghostty owns the PTY
// and Swift never sees raw bytes — so we poll the rendered scrollback
// and diff against the last snapshot to feed only new content into the
// detector.
//
// Lifecycle: single app-wide DispatchSourceTimer. Started on first GUI
// agent appearing in any team; restarted when interval changes. Per-pane
// state (detector instance, last snapshot, last fired hash) is cleaned
// up when the panel disappears.
//
// Disabled via `TERMMESH_AUTO_REPLY=off` (env or `UserDefaults`
// `termmesh.autoReply.enabled = false`).

@MainActor
final class AutoReplyPoller {
    static let shared = AutoReplyPoller()

    /// Polling cadence — matches Rust detector's tick interval. 500ms is the
    /// rust default's idle_debounce floor; we tick a bit faster so debounce
    /// + scrollback diff catch up promptly after the agent finishes printing.
    private let pollInterval: TimeInterval = 0.4

    private var timer: DispatchSourceTimer?
    private var perPanel: [UUID: PanelState] = [:]
    private let enabled: Bool

    private final class PanelState {
        let detector = AutoReplyDetector()
        var lastScrollbackText: String = ""
        var lastFiredHash: UInt64?
        weak var panel: TerminalPanel?
    }

    private init() {
        self.enabled = Self.computeEnabled()
    }

    private static func computeEnabled() -> Bool {
        if let env = ProcessInfo.processInfo.environment["TERMMESH_AUTO_REPLY"] {
            let v = env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["off", "0", "false", "no"].contains(v) { return false }
        }
        if UserDefaults.standard.object(forKey: "termmesh.autoReply.enabled") != nil,
           UserDefaults.standard.bool(forKey: "termmesh.autoReply.enabled") == false {
            return false
        }
        return true
    }

    /// Idempotent. Safe to call on app start and again whenever team rosters change.
    func ensureRunning() {
        guard enabled, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        perPanel.removeAll()
    }

    /// Flush any pending capture for the panel and forget its state.
    /// Call when the agent is detached / pane closes.
    func forget(panelId: UUID) {
        guard let state = perPanel.removeValue(forKey: panelId) else { return }
        // Best-effort flush — if a header was mid-capture, commit it now
        if let ev = state.detector.flush() {
            tryEmit(panelId: panelId, state: state, event: ev)
        }
    }

    // MARK: - Tick

    private func tick() {
        guard enabled else { return }
        let teams = TeamOrchestrator.shared.teams
        var aliveIds: Set<UUID> = []

        for team in teams.values {
            for agent in team.agents {
                guard let panelId = agent.panelId else { continue }
                aliveIds.insert(panelId)
                pollAgent(teamName: team.id, agentName: agent.name, panelId: panelId)
            }
        }

        // GC: drop state for panels that no longer belong to any agent
        let stale = Set(perPanel.keys).subtracting(aliveIds)
        for id in stale {
            perPanel.removeValue(forKey: id)
        }
    }

    private func pollAgent(teamName: String, agentName: String, panelId: UUID) {
        // Resolve panel + surface
        guard let appDelegate = AppDelegate.shared,
              let located = appDelegate.locateSurface(surfaceId: panelId),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let panel = workspace.panels[panelId] as? TerminalPanel,
              let surface = panel.surface.surface else {
            return
        }

        let state = perPanel[panelId] ?? PanelState()
        state.panel = panel
        perPanel[panelId] = state

        // Read full scrollback
        let now = Date()
        guard let snapshot = Self.readScrollback(surface) else { return }

        // Diff: find common prefix vs last snapshot, push only the tail
        let delta = Self.computeDelta(previous: state.lastScrollbackText, current: snapshot)
        state.lastScrollbackText = snapshot

        if !delta.isEmpty {
            if let data = delta.data(using: .utf8) {
                if let ev = state.detector.pushBytes(data, at: now) {
                    tryEmit(panelId: panelId, state: state, event: ev,
                            teamName: teamName, agentName: agentName)
                }
            }
        }

        if let ev = state.detector.tick(at: now) {
            tryEmit(panelId: panelId, state: state, event: ev,
                    teamName: teamName, agentName: agentName)
        }
    }

    // MARK: - Emit

    private func tryEmit(panelId: UUID, state: PanelState, event: AutoReplyEvent,
                         teamName: String? = nil, agentName: String? = nil) {
        let hash = event.contentHash()
        if state.lastFiredHash == hash {
            return
        }
        state.lastFiredHash = hash

        // Resolve agent identity if not supplied (flush path)
        let (resolvedTeam, resolvedAgent): (String, String)
        if let t = teamName, let a = agentName {
            (resolvedTeam, resolvedAgent) = (t, a)
        } else {
            guard let pair = Self.resolveIdentity(panelId: panelId) else { return }
            (resolvedTeam, resolvedAgent) = pair
        }

        let updated = AutoReplyEmit.emit(
            teamName: resolvedTeam,
            agentName: resolvedAgent,
            event: event
        )
        NSLog("[auto-reply] gui emit team=%@ agent=%@ status=%@ task_updated=%d",
              resolvedTeam, resolvedAgent, event.status, updated ? 1 : 0)
        _ = updated
    }

    private static func resolveIdentity(panelId: UUID) -> (String, String)? {
        for team in TeamOrchestrator.shared.teams.values {
            if let agent = team.agents.first(where: { $0.panelId == panelId }) {
                return (team.id, agent.name)
            }
        }
        return nil
    }

    // MARK: - Scrollback reader

    private static func readScrollback(_ surface: ghostty_surface_t) -> String? {
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0, y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0, y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: true
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        let data = Data(bytes: ptr, count: Int(text.text_len))
        return String(data: data, encoding: .utf8)
    }

    /// Return the suffix of `current` that wasn't in `previous`. When
    /// scrollback rotates and the common prefix no longer matches, we
    /// fall back to returning the entire current text — the detector
    /// is line-anchored so re-feeding earlier lines just resets to Idle
    /// (idempotent for our purposes; new emit blocked by lastFiredHash).
    static func computeDelta(previous: String, current: String) -> String {
        if previous.isEmpty { return current }
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        // Scrollback rotated or screen was cleared
        return current
    }
}
