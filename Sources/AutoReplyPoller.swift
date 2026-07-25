import Foundation
import Bonsplit

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
// Threading (Phase 2): tick() runs on MainActor. It acquires SurfaceReadLeases
// (MainActor-only) then fans out the actual ghostty_surface_read_text calls to
// a private serial queue (pollQueue) so the main thread is never blocked by
// the read loop. PanelState (detector, lastScrollbackText) is only touched on
// MainActor. Leases keep surface pointers alive across the background hop; each
// is released immediately after its read. tickInFlight prevents overlapping tick
// batches when reads are slow. Results are revalidated on main before apply to
// guard against agent detach + surface reuse between read and apply.
//
// Disabled via `TERMMESH_AUTO_REPLY=off` (env or `UserDefaults`
// `termmesh.autoReply.enabled = false`).

@MainActor
final class AutoReplyPoller {
    static let shared = AutoReplyPoller()

    /// Polling cadence — matches Rust detector's tick interval. 500ms is the
    /// rust default's idle_debounce floor; we tick a bit faster so debounce
    /// + scrollback diff catch up promptly after the agent finishes printing.
    private let pollInterval: TimeInterval = 1.0
    // FIX 2: Cap lastScrollbackText to avoid unbounded memory growth on long-running agents.
    private static let lastScrollbackCapBytes = 2 * 1024 * 1024

    // FIX 1: Private serial queue so concurrent ticks can't interleave reads.
    private let pollQueue = DispatchQueue(label: "term-mesh.auto-reply.poll", qos: .userInitiated)
    // FIX 1: Skip a new tick while the previous batch's reads are still in flight.
    private var tickInFlight = false

    private var timer: DispatchSourceTimer?
    private var perPanel: [UUID: PanelState] = [:]
    private let enabled: Bool

    private final class PanelState {
        let detector = AutoReplyDetector()
        var lastScrollbackText: String = ""
        var lastFiredHash: UInt64?
        weak var panel: TerminalPanel?
        /// When this pane last printed anything.
        var lastOutputAt: Date?
        /// Whether a first-run prompt has already been answered here. Once
        /// only: a CLI asking twice is not a first run.
        var answeredStartupPrompt = false
        /// When stray mouse reports were last cleared here, so a pane whose
        /// scrollback still holds the old evidence is not reset every tick.
        var healedMouseModesAt: Date?
    }

    /// How recently a pane must have printed to count as working. The poll runs
    /// every 500ms and an agent thinking between tool calls goes quiet for a
    /// few seconds at a time, so this is deliberately longer than one tick.
    static let activityWindow: TimeInterval = 6

    /// Whether this pane has printed recently enough to call it busy.
    ///
    /// The task board cannot answer this: a task sits at `assigned` from the
    /// moment it is handed over until the agent files a result, so an agent
    /// halfway through the work and an agent that never started look exactly
    /// alike there. The pane is the one place the difference is visible, and
    /// this poller is already reading it every half second.
    func isPaneActive(panelId: UUID, now: Date = Date()) -> Bool {
        guard let last = perPanel[panelId]?.lastOutputAt else { return false }
        return now.timeIntervalSince(last) <= Self.activityWindow
    }

    /// Text a person has typed into this agent's composer and not sent.
    ///
    /// An agent pane is a terminal, and people use it — they ask the agent
    /// something directly, or start typing and stop. A capsule pasted on top
    /// of that lands *after* their words, and what gets submitted is the two
    /// mashed together: the person's half-thought and the leader's task, one
    /// garbled prompt. The agent answers something nobody asked, prints a
    /// header for it, and the task it was actually given never closes.
    ///
    /// Read from the snapshot this poller already holds, so asking costs
    /// nothing. Nil when the pane is not being watched or the composer is
    /// empty — and nil on a CLI whose composer this does not recognise, which
    /// is the safe way to be wrong.
    func composerDraft(panelId: UUID) -> String? {
        guard let text = perPanel[panelId]?.lastScrollbackText else { return nil }
        return Self.composerDraft(inPaneText: text)
    }

    /// Prompt markers agent CLIs put in front of their input line.
    private static let composerMarkers: [Character] = ["❯", "›", "»", ">"]

    static func composerDraft(inPaneText text: String) -> String? {
        // The last line that looks like a composer wins: the pane is redrawn
        // in place, so earlier ones are history.
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, composerMarkers.contains(first) else { continue }
            let draft = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            return draft.isEmpty ? nil : draft
        }
        return nil
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
        // FIX 1: skip-coalesce — don't start a new batch while one is in flight
        guard enabled, !tickInFlight else { return }
        tickInFlight = true

        let teams = TeamOrchestrator.shared.teams
        var aliveIds: Set<UUID> = []

        // WorkItem carries everything the background queue needs; all types are Sendable.
        struct WorkItem: @unchecked Sendable {
            let teamName: String
            let agentName: String
            let panelId: UUID
            let surfaceGeneration: UInt64  // FIX 3: captured at lease creation time
            let lease: SurfaceReadLease    // keeps surface alive across the background hop
            let prevText: String
        }
        var workItems: [WorkItem] = []

        for team in teams.values {
            for agent in team.agents {
                guard let panelId = agent.panelId else { continue }
                aliveIds.insert(panelId)

                // Resolve panel and acquire a read lease — both MainActor ops.
                guard let appDelegate = AppDelegate.shared,
                      let located = appDelegate.locateSurface(surfaceId: panelId),
                      let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                      let panel = workspace.panels[panelId] as? TerminalPanel,
                      let lease = panel.surface.beginReadLease() else { continue }

                let state = perPanel[panelId] ?? PanelState()
                state.panel = panel
                perPanel[panelId] = state

                workItems.append(WorkItem(
                    teamName: team.id,
                    agentName: agent.name,
                    panelId: panelId,
                    surfaceGeneration: lease.generation,  // FIX 3
                    lease: lease,
                    prevText: state.lastScrollbackText
                ))
            }
        }

        // GC: drop state for panels that no longer belong to any agent
        let stale = Set(perPanel.keys).subtracting(aliveIds)
        for id in stale {
            perPanel.removeValue(forKey: id)
        }

        guard !workItems.isEmpty else {
            tickInFlight = false  // nothing to dispatch — clear inline
            return
        }

        // FIX 1: use serial pollQueue (not .global) so concurrent ticks can't overlap.
        // Leases prevent surface free during reads; each is released immediately after read.
        pollQueue.async { [weak self] in
            struct ReadResult: @unchecked Sendable {
                let teamName: String
                let agentName: String
                let panelId: UUID
                let surfaceGeneration: UInt64  // FIX 3
                let snapshot: String?
                let delta: String
                let readAt: Date
            }

            let readAt = Date()
            var results: [ReadResult] = []

            for item in workItems {
                let snapshot = AutoReplyPoller.readScrollback(item.lease.surface)
                item.lease.release()  // unblocks any pending surface free immediately
                let delta: String
                if let snap = snapshot {
                    delta = AutoReplyPoller.computeDelta(previous: item.prevText, current: snap)
                } else {
                    delta = ""
                }
                results.append(ReadResult(
                    teamName: item.teamName,
                    agentName: item.agentName,
                    panelId: item.panelId,
                    surfaceGeneration: item.surfaceGeneration,  // FIX 3
                    snapshot: snapshot,
                    delta: delta,
                    readAt: readAt
                ))
            }

            // Apply detector updates back on MainActor.
            Task { @MainActor [weak self] in
                // FIX 1: clear tickInFlight on all exit paths via defer
                defer { self?.tickInFlight = false }
                guard let self else { return }

                for r in results {
                    // FIX 2: revalidate identity — agent/panel may have been detached
                    // between read and apply; surface may have been detached+reattached.
                    guard let team = TeamOrchestrator.shared.teams[r.teamName],
                          let agent = team.agents.first(where: { $0.name == r.agentName }),
                          agent.panelId == r.panelId else {
#if DEBUG
                        dlog("autoreply.dropped reason=agent_gone panelId=\(r.panelId.uuidString.prefix(8))")
#endif
                        continue
                    }
                    // FIX 3: generation guard — detach+reattach reuses panelId but bumps generation
                    guard let appDelegate = AppDelegate.shared,
                          let located = appDelegate.locateSurface(surfaceId: r.panelId),
                          let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                          let panel = workspace.panels[r.panelId] as? TerminalPanel,
                          panel.surface.attachGeneration == r.surfaceGeneration else {
#if DEBUG
                        dlog("autoreply.dropped reason=generation_mismatch panelId=\(r.panelId.uuidString.prefix(8))")
#endif
                        continue
                    }

                    self.applyResult(
                        panelId: r.panelId,
                        teamName: r.teamName,
                        agentName: r.agentName,
                        snapshot: r.snapshot,
                        delta: r.delta,
                        at: r.readAt
                    )
                }
            }
        }
    }

    /// Trim `s` to keep at most `byteLimit` UTF-8 bytes, snapping forward to the
    /// nearest UTF-8 character boundary so the result is always a valid String.
    ///
    /// Using `.suffix(byteLimit)` on a String uses CHARACTER count, which can
    /// retain >byteLimit bytes for multibyte text. This helper operates in the
    /// UTF-8 byte view, then walks forward past any UTF-8 continuation bytes
    /// (0b10xxxxxx) so the slice boundary always lands on a leading byte.
    ///
    /// Edge cases:
    /// - All-ASCII: identical to `.suffix(byteLimit)` — continuation walk is 0 steps.
    /// - All-multibyte (e.g. Korean): trim lands mid-codepoint → walk advances to
    ///   next leading byte; result is at most `byteLimit + 3` UTF-8 bytes (one
    ///   extra 3-byte scalar), which is negligible against a 2MB cap.
    /// - Empty string: returns "" immediately.
    nonisolated private static func trimToTailBytes(_ s: String, byteLimit: Int) -> String {
        let utf8 = s.utf8
        guard utf8.count > byteLimit else { return s }
        let dropBytes = utf8.count - byteLimit
        var idx = utf8.index(utf8.startIndex, offsetBy: dropBytes)
        // Walk forward past continuation bytes (0b10xxxxxx) to the next leading byte.
        while idx < utf8.endIndex, (utf8[idx] & 0b1100_0000) == 0b1000_0000 {
            idx = utf8.index(after: idx)
        }
        // Construct result from the UTF-8 sub-view. The loop above guarantees
        // `idx` is on a leading byte, so this slice is always valid UTF-8.
        return String(utf8[idx...]) ?? String(s.suffix(byteLimit))
    }

    /// Apply one background read result to the per-panel detector state.
    /// All PanelState mutations happen here, on MainActor.
    private func applyResult(panelId: UUID, teamName: String, agentName: String,
                              snapshot: String?, delta: String, at now: Date) {
        guard let state = perPanel[panelId] else { return }  // panel GC'd between read and apply
        let previousText = state.lastScrollbackText
        if let snap = snapshot {
            // FIX 2: keep only the tail so per-panel state stays bounded.
            // trimToTailBytes operates in UTF-8 byte space (not character count)
            // so the cap is a true byte bound, not a potentially-larger char bound.
            let trimmed = Self.trimToTailBytes(snap, byteLimit: Self.lastScrollbackCapBytes)
            // Any change on screen means the agent is doing something, and the
            // screen changing is not the same as text being appended: `delta`
            // carries only what was added at the end, which a CLI that redraws
            // in place — every agent TUI — leaves empty while its display moves
            // constantly. Comparing the whole snapshot is what actually tracks
            // whether a pane is alive.
            if trimmed != state.lastScrollbackText {
                state.lastOutputAt = now
            }
            state.lastScrollbackText = trimmed
            answerStartupPromptIfNeeded(panelId: panelId, state: state, text: trimmed, agentName: agentName)
            healStrayMouseReportsIfNeeded(state: state, text: trimmed, agentName: agentName, at: now)
        }
        // An empty delta is not the same as nothing happening. `computeDelta`
        // assumes append-only scrollback, and an agent TUI is the opposite: it
        // redraws its screen in place, so the new snapshot routinely contains
        // the old one as a *suffix* rather than a prefix, and the anchor search
        // then matches at the very end and returns "". The reply header was
        // being computed away before the detector ever saw it — the pane read
        // was right, the diff was wrong. When the screen changed but the diff
        // came back empty, feed the screen: the detector is line-anchored and
        // duplicate emits are already blocked by `lastFiredHash`.
        var feed = delta
        if feed.isEmpty, state.lastScrollbackText != previousText {
            feed = state.lastScrollbackText
        }
        if !feed.isEmpty, let data = feed.data(using: .utf8) {
            if let ev = state.detector.pushBytes(data, at: now) {
                tryEmit(panelId: panelId, state: state, event: ev,
                        teamName: teamName, agentName: agentName)
            }
        }
        if let ev = state.detector.tick(at: now) {
            tryEmit(panelId: panelId, state: state, event: ev,
                    teamName: teamName, agentName: agentName)
        }
    }

    // MARK: - Stray mouse reports

    /// Turn mouse reporting back off when the far end is visibly choking on it.
    ///
    /// An agent TUI asks this terminal to report mouse movement and asks it to
    /// stop when it exits. An agent that does not exit — a crash, a `kill -9`,
    /// a link dropped mid-run — never gets to ask, and the request stands. What
    /// is left is a plain shell on the far side and a terminal here that sends
    /// it `ESC [ < 35;47;44M` for every pixel the pointer crosses. The shell's
    /// line editor swallows the escape it does not know and keeps the digits,
    /// so a mouse dragged across the pane arrives over there as commands:
    /// `35: command not found`, once per sample, indefinitely.
    ///
    /// Detected rather than predicted. The lifecycle points term-mesh can see —
    /// attaching, releasing, losing a host — are already handled, and this is
    /// the case it cannot see: the pane is fine, the link is fine, the program
    /// that set the mode is gone. But the failure writes its own evidence into
    /// the scrollback this poller is reading anyway, so the condition itself is
    /// the trigger, and correcting it needs no theory about how the CLI died.
    private func healStrayMouseReportsIfNeeded(
        state: PanelState,
        text: String,
        agentName: String,
        at now: Date
    ) {
        // Only where these bytes are ours to take back: on a peer pane this
        // terminal holds the mode and the far shell merely suffers it. A local
        // pane's modes belong to a process on this machine.
        guard let panel = state.panel, panel.remoteHostKey != nil else { return }
        if let last = state.healedMouseModesAt,
           now.timeIntervalSince(last) < Self.mouseHealCooldown { return }
        // Only the bottom of the screen, because `readScrollback` returns the
        // whole history and the evidence stays in it long after the fact. Left
        // unbounded, a pane that once had this would be reset every window
        // forever — and the reset would eventually land on a *working* agent
        // that had relaunched in the same pane and legitimately asked for the
        // mouse. What makes the tail the right bound is that this failure only
        // happens at a live prompt: a running TUI paints over the bottom of the
        // screen, so its own display is what is found there instead.
        guard Self.showsStrayMouseReports(inPaneText: Self.screenBottom(of: text)) else { return }
        state.healedMouseModesAt = now
        panel.surface.resetTerminal()
        #if DEBUG
        dlog("autoreply.mouse_modes_reset agent=\(agentName)")
        #endif
    }

    /// The evidence stays on screen after the fix, so re-reading it must not
    /// re-fire forever. One clearing per window is enough for a mode that only
    /// gets set again by a program that also knows how to unset it.
    private static let mouseHealCooldown: TimeInterval = 30

    /// Whether this pane is showing mouse reports being run as commands.
    ///
    /// A shell reporting a *bare number* as an unknown command is the part that
    /// cannot be anything else: it says the reports are arriving as input, not
    /// merely appearing in output. Nothing fires without at least one, which is
    /// what keeps a terminal that legitimately wants the mouse from having it
    /// taken away.
    ///
    /// One alone is still a typo someone could plausibly make, so it needs
    /// corroboration, and the two shapes this failure takes supply it
    /// differently. Where the far shell reads each report as its own line the
    /// evidence is a run of rejected numbers; where a drag arrives faster than
    /// the prompt redraws, the reports run together on one line and the shell
    /// only rejects the first. So: several rejected numbers, or one plus the
    /// `<button>;<x>;<y>M` bodies behind it.
    ///
    /// English-only, and deliberately so: a shell in another language simply
    /// fails this test and keeps its mode, which is the safe way to be wrong
    /// about a pane that might be working.
    nonisolated static func showsStrayMouseReports(inPaneText text: String) -> Bool {
        var reportBodies = 0
        var rejectedNumbers = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            reportBodies += countMouseReportBodies(in: line)
            if line.contains("command not found"), mentionsBareNumberCommand(String(line)) {
                rejectedNumbers += 1
            }
        }
        if rejectedNumbers >= 2 { return true }
        return rejectedNumbers >= 1 && reportBodies >= 3
    }

    /// The last lines of a pane, roughly what is on screen now.
    nonisolated static func screenBottom(of text: String, lines: Int = 40) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else { return text }
        return all.suffix(lines).joined(separator: "\n")
    }

    /// `35;47;44M` — three unsigned numbers and a trailing M or m, not part of
    /// a longer number on either side.
    nonisolated private static func countMouseReportBodies(in line: Substring) -> Int {
        var count = 0
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            if i > 0, chars[i - 1].isNumber || chars[i - 1] == ";" { i += 1; continue }
            var j = i
            var fields = 0
            while j < chars.count {
                var digits = 0
                while j < chars.count, chars[j].isNumber { j += 1; digits += 1 }
                guard digits > 0, digits <= 4 else { break }
                fields += 1
                if j < chars.count, chars[j] == ";" { j += 1; continue }
                break
            }
            if fields == 3, j < chars.count, chars[j] == "M" || chars[j] == "m" {
                count += 1
                i = j + 1
            } else {
                i = max(j, i + 1)
            }
        }
        return count
    }

    /// Whether a "command not found" line names a number rather than a program.
    /// Covers both dialects: `bash: 35: command not found` and zsh's
    /// `zsh: command not found: 35`.
    nonisolated private static func mentionsBareNumberCommand(_ line: String) -> Bool {
        let fields = line.split(whereSeparator: { $0 == ":" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return fields.contains { field in
            !field.isEmpty && field.allSatisfy(\.isNumber)
        }
    }

    // MARK: - Startup prompts

    /// Answer a first-run question the CLI is holding the pane on.
    ///
    /// This poller is already reading every agent pane once a second, which
    /// makes it the one place that can see a prompt nobody is sitting in front
    /// of. Answered at most once per pane: if the CLI asks again, something
    /// other than a first run is going on and a person should look.
    private func answerStartupPromptIfNeeded(
        panelId: UUID,
        state: PanelState,
        text: String,
        agentName: String
    ) {
        guard !state.answeredStartupPrompt else { return }
        guard let prompt = AgentStartupPrompt.detect(in: text) else { return }
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: panelId),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let panel = workspace.terminalPanel(for: panelId) else { return }
        state.answeredStartupPrompt = true
        NSLog("[auto-reply] answered startup prompt agent=%@ prompt=%@",
              agentName, String(describing: prompt))
#if DEBUG
        dlog("startupPrompt.answered agent=\(agentName) panel=\(panelId.uuidString.prefix(8)) prompt=\(prompt)")
#endif
        // A key event, not text. The prompt is a TUI selection list waiting on
        // Return; writing a carriage return into the composer looks like
        // typing and does not commit it. This is the same retrying path the
        // socket's `surface.send_key` uses.
        TerminalController.shared.sendNamedKeyWithRetry(
            on: panel.surface,
            keyName: prompt.answerKey
        ) { delivered, reason in
            guard !delivered else { return }
            NSLog("[auto-reply] startup prompt answer not delivered: %@", reason)
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

    nonisolated private static func readScrollback(_ surface: ghostty_surface_t) -> String? {
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

    /// Number of characters to use as an anchor fingerprint when `previous` is
    /// a cap-trimmed tail (not a full prior snapshot). 256 chars ≈ 1–2 CLI
    /// output lines; enough to disambiguate vim/htop redraws while staying fast.
    private static let deltaAnchorCharCount = 256

    /// Return the suffix of `current` that wasn't in `previous`.
    ///
    /// Two cases:
    ///
    /// **Fast path** — `previous` is the untruncated prior snapshot and is still
    /// a prefix of `current` (the normal grow-only case). Returns the appended
    /// suffix directly.
    ///
    /// **Anchor path** — `previous` is the cap-trimmed tail stored by
    /// `applyResult` (after `lastScrollbackCapBytes` was hit). The prefix check
    /// fails because `previous` is a suffix, not a prefix. We instead take the
    /// last `deltaAnchorCharCount` chars of `previous` as a fingerprint, search
    /// for it backwards in `current`, and emit everything after that match.
    /// Falls back to full `current` only when the anchor isn't found — which
    /// means scrollback rotated past the anchor window or the terminal cleared
    /// (genuine fresh-snapshot case). The detector is line-anchored so
    /// re-feeding earlier lines resets it to Idle (idempotent; duplicate emits
    /// are blocked by `lastFiredHash`).
    nonisolated static func computeDelta(previous: String, current: String) -> String {
        if previous.isEmpty { return current }
        if current == previous { return "" }
        // Fast path: previous is a true prefix of current (no cap was hit).
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        // (A) Full-tail search: try `previous` itself as a backwards substring
        // match. This is the common case when `previous` is the 2MB cap-trimmed
        // tail and `current` = previous + new output. Even if the new output
        // contains the same 256-char anchor substring again (e.g. vim/htop
        // redraws that repeat the STATUS header), matching `previous` in full
        // finds the correct sync point rather than the duplicate anchor inside
        // the delta.
        //
        // Limitation: if the new output appends `previous` verbatim AGAIN
        // (rapid identical-tail repeats), `range(of:.backwards)` matches the
        // LAST occurrence → emits only the bytes after that. Bytes between the
        // first and second copy are dropped. This is an accepted trade-off:
        // identical-tail repetition in CLI output is extremely rare, and the
        // alternative (short-anchor matching) has a much higher false-positive
        // rate on vim/htop redraws.
        if let range = current.range(of: previous, options: .backwards) {
            return String(current[range.upperBound...])
        }
        // (B) Rotation fallback: `previous` is not found in `current` at all —
        // scrollback rotated entirely past `previous` (e.g. `clear` or a
        // long-running tool that scrolled the buffer). Use the last
        // `deltaAnchorCharCount` chars as a weak fingerprint to find a re-sync
        // point. Less precise than (A); only reached when (A) failed.
        let anchorLen = min(deltaAnchorCharCount, previous.count)
        let anchor = String(previous.suffix(anchorLen))
        if let range = current.range(of: anchor, options: .backwards) {
            return String(current[range.upperBound...])
        }
        // (C) No match at all: screen cleared or entirely new content. Treat
        // current as the fresh delta.
        return current
    }
}
