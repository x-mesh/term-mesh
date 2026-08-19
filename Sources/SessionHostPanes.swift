import Foundation
import PeerProto

/// Shows this machine's daemon-held sessions in this machine's own window.
///
/// A session the daemon owns outlives the app, which is the point of it — but
/// until something here attaches to one, the machine holding the work is the
/// one place you cannot see it. A project placed on a peer looked exactly like
/// that: the leader's own machine showed a workspace and no team.
///
/// Not a workspace mirror. The daemon places ensured sessions as *tabs* in one
/// pane, deliberately — "deterministic placement rather than requiring a
/// client-side picker" — and `PeerWorkspaceMirror` renders a pane's active
/// surface and has no notion of a tab strip, so mirroring showed one session
/// no matter how many were running. Attaching per surface sidesteps that
/// without changing where the daemon puts them or what the protocol carries.
@MainActor
enum SessionHostPanes {

    /// The `SurfaceInfo.surface_type` value naming a daemon-owned agent
    /// surface: a non-PTY `tm-agent-bridge` child whose byte stream is
    /// NDJSON events, not a terminal grid. Single Swift home for the
    /// literal — the router below and `Workspace`'s pane factories must
    /// agree on it or a surface routes one way and renders another.
    static let agentSurfaceType = "agent"

    /// Exact match only. The daemon writes this string; anything else —
    /// including the empty string every pre-agent daemon sends — is a
    /// terminal, which is what every unknown type has always been opened
    /// as.
    static func isAgentSurfaceType(_ surfaceType: String) -> Bool {
        surfaceType == agentSurfaceType
    }

    /// Sessions the daemon holds that have no pane here yet, split by the
    /// renderer they need.
    ///
    /// "Held by the daemon" is the whole test. Anything it owns is a session
    /// that survives this app, which is exactly what deserves a window here;
    /// deciding by key or title would bind this to a naming scheme the app
    /// does not set and the host is free to change.
    ///
    /// Unattachable surfaces are skipped rather than attempted: attaching to
    /// one fails at the far end, and a failure per pass is a log full of the
    /// same line.
    ///
    /// An agent surface must never land in the terminal list: opened as a
    /// terminal it would spawn the relay helper into a pane and render raw
    /// NDJSON as if it were a shell. It gets its own list — the caller
    /// routes it to `Workspace.openRemoteAgentPane` — rather than being
    /// dropped, because the daemon holding it is still the reason to show
    /// it.
    static func sessionsNeedingPanes(
        daemonSurfaces: [(id: Data, attachable: Bool, surfaceType: String)],
        alreadyShown: Set<Data>
    ) -> (terminal: [Data], agent: [Data]) {
        let wanted = daemonSurfaces
            .filter { $0.attachable && !alreadyShown.contains($0.id) }
        return (
            terminal: wanted.filter { !isAgentSurfaceType($0.surfaceType) }.map(\.id),
            agent: wanted.filter { isAgentSurfaceType($0.surfaceType) }.map(\.id)
        )
    }

    /// Project manifests are the only authoritative link between a daemon
    /// surface and the Project workspace that should display it. Names, cwd,
    /// and ensure keys are presentation details and can disagree.
    static func projectNamesBySurfaceID(
        teams: [Termmesh_Peer_V1_Team]
    ) -> [Data: String] {
        var names: [Data: String] = [:]
        for team in teams where !team.name.isEmpty && !team.leaderSurfaceID.isEmpty {
            names[team.leaderSurfaceID] = team.name
            for member in team.members where !member.surfaceID.isEmpty {
                names[member.surfaceID] = team.name
            }
        }
        return names
    }

    static func projectWorkingDirectories(
        teams: [Termmesh_Peer_V1_Team]
    ) -> [String: String] {
        Dictionary(
            teams.filter { !$0.name.isEmpty }.map { ($0.name, $0.workingDirectory) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    enum WorkspaceDestination: Equatable {
        case existingProject(UUID)
        case newProject(String)
        case existingHostSessions(UUID)
        case newHostSessions
    }

    /// The bracketed prefix this file writes is the project identity that
    /// survives a restart even when the declaration does not.
    ///
    /// The prefix, not the whole title: `TeamOrchestrator` writes
    /// `[project] 3 headless`, so requiring the title to end in `]` left a
    /// resumed headless team unrecognized — the same proliferation this
    /// recovery exists to stop, reachable without a restart.
    static func projectName(fromWorkspaceTitle title: String?) -> String? {
        guard let title,
              title.hasPrefix("["),
              let close = title.firstIndex(of: "]")
        else { return nil }
        let name = String(title[title.index(after: title.startIndex)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The project a workspace belongs to, falling back to its title when a
    /// restore left no declaration behind.
    ///
    /// `WorkspaceProjectNames` is keyed by workspace UUID, and a session
    /// written before workspace IDs were persisted restores workspaces no
    /// declaration can name. Reading the declaration alone therefore reported
    /// "no workspace owns this project" on every launch, and each launch
    /// created one more `[project]` workspace for the same project.
    ///
    /// The fallback deliberately does not write the declaration back. A
    /// bracketed title is not proof of a project: `workspace.create` titles a
    /// worktree workspace `[<branch>]`, and a rename over the control socket
    /// produces any bracketed title at all. Persisting those would give a
    /// presentation string permanent authority over routing — `SidebarViews`
    /// honors a declaration over its own path inference, and nothing short of
    /// closing the workspace revokes one. Recomputed per pass instead, a title
    /// that stops matching stops counting.
    static func declaredProjectName(for workspace: Workspace) -> String? {
        WorkspaceProjectNames.shared.projectName(for: workspace.id)
            ?? projectName(fromWorkspaceTitle: workspace.customTitle)
    }

    /// Every window's workspaces, deduplicated.
    ///
    /// `AppDelegate.tabManager` is not always one of `mainWindowContexts`, so
    /// the fallback is appended rather than assumed present.
    static func allTabManagers(app: AppDelegate, fallback: TabManager) -> [TabManager] {
        var seen = Set<ObjectIdentifier>()
        return (app.mainWindowContexts.values.map(\.tabManager) + [fallback])
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// The project claims `workspaceDestination` chooses among.
    ///
    /// Named rather than inlined at the call site so a test can assert the
    /// decision this change exists to make — that restored `[project]`
    /// workspaces, which carry no declaration, still resolve to themselves.
    /// Inlined, reverting the recovery reinstated the proliferation bug without
    /// failing a single test.
    static func declaredProjects(in workspaces: [Workspace]) -> [(id: UUID, name: String)] {
        let declared = workspaces.compactMap { workspace in
            WorkspaceProjectNames.shared.projectName(for: workspace.id).map {
                (id: workspace.id, name: $0)
            }
        }
        let recovered = workspaces.compactMap { workspace -> (id: UUID, name: String)? in
            guard WorkspaceProjectNames.shared.projectName(for: workspace.id) == nil,
                  let name = projectName(fromWorkspaceTitle: workspace.customTitle)
            else { return nil }
            return (id: workspace.id, name: name)
        }
        // A title is only a recovery hint. If an unrelated worktree happens to
        // be named `[project]`, the durable declaration must win regardless of
        // tab or window order.
        return declared + recovered
    }

    /// Choose by declared project identity, never by the selected tab. The
    /// selected tab is merely what the user is looking at; treating it as the
    /// owner injected a term-mesh worker into an `xm` workspace.
    static func workspaceDestination(
        projectName: String?,
        declaredProjects: [(id: UUID, name: String)],
        hostSessionsWorkspaceID: UUID?
    ) -> WorkspaceDestination {
        if let projectName {
            if let existing = declaredProjects.first(where: {
                $0.name.caseInsensitiveCompare(projectName) == .orderedSame
            }) {
                return .existingProject(existing.id)
            }
            return .newProject(projectName)
        }
        if let hostSessionsWorkspaceID {
            return .existingHostSessions(hostSessionsWorkspaceID)
        }
        return .newHostSessions
    }

    /// Repair panes opened by older builds in whichever workspace happened to
    /// be selected. Run once per window because `shownSurfaceIDs()` is also
    /// window-global; limiting repair to the active window would leave a pane
    /// in another window permanently misplaced and suppress its correct reopen.
    private static func migrateShownProjectSurfaces(
        projectNames: [Data: String],
        projectDirectories: [String: String],
        tabManager: TabManager
    ) {
        for (surfaceID, projectName) in projectNames {
            guard let source = tabManager.tabs.first(where: {
                $0.panelID(forPeerSurfaceID: surfaceID) != nil
            }),
            let panelID = source.panelID(forPeerSurfaceID: surfaceID),
            let sourcePane = source.paneId(forPanelId: panelID),
            let sourceIndex = source.indexInPane(forPanelId: panelID)
            else { continue }

            let existingTargetID = declaredProjects(in: tabManager.tabs).first(where: {
                $0.name.caseInsensitiveCompare(projectName) == .orderedSame
            })?.id
            let existingTarget = existingTargetID.flatMap { id in
                tabManager.tabs.first(where: { $0.id == id })
            }
            guard existingTarget?.id != source.id else { continue }
            var targetAnchor: UUID?
            let target = existingTarget ?? {
                let created = tabManager.addWorkspace(
                    workingDirectory: projectDirectories[projectName], select: false
                )
                targetAnchor = created.focusedPanelId
                WorkspaceProjectNames.shared.declare(
                    workspaceId: created.id, projectName: projectName
                )
                created.customTitle = "[\(projectName)]"
                created.title = "[\(projectName)]"
                return created
            }()
            guard source.id != target.id,
                  let targetPane = target.bonsplitController.focusedPaneId
                    ?? target.bonsplitController.allPaneIds.first
            else {
                if existingTarget == nil { tabManager.closeWorkspace(target) }
                continue
            }
            guard let transfer = source.detachSurface(panelId: panelID) else {
                if existingTarget == nil { tabManager.closeWorkspace(target) }
                continue
            }
            if target.attachDetachedSurface(transfer, inPane: targetPane, focus: false) == nil {
                _ = source.attachDetachedSurface(
                    transfer, inPane: sourcePane, atIndex: sourceIndex, focus: false
                )
                if existingTarget == nil {
                    tabManager.closeWorkspace(target)
                }
            } else if let targetAnchor, target.panels.count > 1 {
                _ = target.closePanel(targetAnchor, force: true)
            }
        }
    }

    /// Whether this machine has a session owner worth looking at.
    ///
    /// The empty path is a host saying it has none — see
    /// `Hello.session_host_socket`. Polling one would be asking a question
    /// that has already been answered.
    static func hasSessionHost(socketPath: String) -> Bool {
        socketPath.hasPrefix("/")
    }

    /// Sessions already on screen, read from the panes themselves.
    ///
    /// This used to be a `Set` this type maintained, and every way that set
    /// could drift from the screen was a bug of its own. Closing an
    /// auto-opened pane left its id marked — nothing ever called the release —
    /// so that session could never come back. A momentarily unreachable daemon
    /// cleared the whole set while its panes were still up, so the next pass
    /// opened a second pane for every one of them.
    ///
    /// The panes are the answer to the question being asked. Reading them
    /// costs a walk of the window list and cannot disagree with what the user
    /// is looking at.
    ///
    /// Keyed by the *peer's* surface id, not the local panel id: the local one
    /// is minted per attach, so comparing those would open a duplicate pane
    /// every pass.
    static func shownSurfaceIDs() -> Set<Data> {
        guard let app = AppDelegate.shared else { return [] }
        var shown: Set<Data> = []
        for context in app.mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values {
                    guard let terminal = panel as? TerminalPanel,
                          let session = terminal.peerPaneSession,
                          !session.isTorndown
                    else { continue }
                    shown.insert(session.originSurface.surfaceID)
                }
                // Agent panes: an AgentPanel deliberately knows nothing
                // about transports, so its peer session lives in the
                // workspace's binding map rather than on the panel.
                for session in workspace.remoteAgentPaneSessions.values
                where !session.isTorndown {
                    shown.insert(session.originSurface.surfaceID)
                }
            }
        }
        return shown
    }

    /// Sessions whose pane someone closed, which must stay closed.
    ///
    /// Reading "already shown" off the screen is what makes the pass
    /// idempotent, and it is also what makes a close undone fifteen seconds
    /// later: the daemon still holds the session, so the next pass finds it
    /// missing and opens it again. Measured, not predicted — a pane closed at
    /// 23:02:15 was back at 23:02:25.
    ///
    /// A dismissal is safe to remember where the old "shown" bookkeeping was
    /// not, because it has an owner: a close puts an id in, and nothing else
    /// needs to take it out. Deliberately not persisted — a fresh run should
    /// show what the daemon is holding, which is the whole point of this type.
    private static var dismissedSurfaceIDs: Set<Data> = []

    static func noteClosedByUser(surfaceID: Data) {
        guard !surfaceID.isEmpty else { return }
        dismissedSurfaceIDs.insert(surfaceID)
    }

    /// Drop dismissals for sessions the daemon no longer holds, so the set
    /// cannot grow for the life of the process.
    ///
    /// The gap this leaves: daemon surface ids are derived from the caller's
    /// key, so a session terminated and re-created under the same key returns
    /// with the same id. Re-created between two passes, it inherits the earlier
    /// dismissal and stays hidden until the app restarts. Pruning on absence
    /// closes that whenever a pass sees the gap, which is the common case.
    private static func pruneDismissals(stillHeld: Set<Data>) {
        dismissedSurfaceIDs.formIntersection(stillHeld)
        // The reopen governor's history is bounded the same way, for the
        // same reason: a surface the daemon no longer holds can never be
        // reopened, so its drop record is dead weight.
        agentPaneDropHistory = agentPaneDropHistory.filter { stillHeld.contains($0.key) }
    }

    /// Test seam: this state is process-global, so a test that adds to it must
    /// be able to put it back.
    static func forgetDismissalsForTests() {
        dismissedSurfaceIDs.removeAll()
    }

    static var dismissedSurfaceIDsForTests: Set<Data> { dismissedSurfaceIDs }

    static func pruneDismissalsForTests(stillHeld: Set<Data>) {
        pruneDismissals(stillHeld: stillHeld)
    }

    // ── Agent-pane reopen governor ───────────────────────────────────
    //
    // `Workspace.dropRemoteAgentPane` closes the pane and kicks an
    // immediate `reconcile()` so a healthy rewind (stream restarted, fresh
    // AgentSession needed) comes back without waiting for the poller. A
    // host that accepts the attach and disconnects at once turns that
    // favor into a spin: drop → kick → reopen → drop, as fast as the round
    // trips land. The governor lets a burst through — rewinds ARE bursts
    // of one or two — and demotes anything past it to `pollInterval`
    // cadence, where the same reconcile still reopens the pane once the
    // host recovers.

    /// Immediate-kick drops allowed per surface within `agentReopenWindow`.
    static let agentReopenBurstLimit = 3
    /// How far back a drop still counts against the limit.
    static let agentReopenWindow: TimeInterval = 30
    private static var agentPaneDropHistory: [Data: [Date]] = [:]

    /// Record one dropped agent pane. Returns whether the caller may kick
    /// an immediate reconcile (true), or must leave the reopen to the
    /// poller's own cadence (false — the surface has been recreated
    /// `agentReopenBurstLimit` times within `agentReopenWindow` already).
    static func noteAgentPaneDropped(surfaceID: Data, now: Date = Date()) -> Bool {
        guard !surfaceID.isEmpty else { return true }
        var recent = (agentPaneDropHistory[surfaceID] ?? []).filter {
            now.timeIntervalSince($0) < agentReopenWindow
        }
        recent.append(now)
        agentPaneDropHistory[surfaceID] = recent
        return recent.count <= agentReopenBurstLimit
    }

    static func forgetAgentPaneDropsForTests() {
        agentPaneDropHistory.removeAll()
    }

    /// How long to keep looking for a session host that is still coming up.
    ///
    /// The app starts its daemon and its own peer server around the same
    /// moment, and the daemon binds its socket a little after being spawned.
    /// A single attempt at server-start therefore found nothing and returned
    /// silently — sessions that had outlived the app stayed invisible until
    /// something asked again, which nothing did. Restored panes from the
    /// previous run made that look like it had worked.
    static let startupSettleAttempts = 10
    static let startupSettleInterval: Duration = .milliseconds(500)

    /// What `reconcileWhenReady` will actually wait, which is one interval
    /// short of attempts × interval: the last attempt does not sleep after
    /// itself. Stated here so the test asserts the real number.
    static var startupSettleWindow: Duration {
        startupSettleInterval * (startupSettleAttempts - 1)
    }

    /// How often to look again while this machine is serving peers.
    ///
    /// Sessions appear after startup — that is what a session host is for, and
    /// every peer-placed project creates one minutes or hours in. A single
    /// pass at server-start showed whatever existed at launch and nothing
    /// after it, so the case this whole type exists for was the case it
    /// covered worst.
    ///
    /// Deliberately slow: a pass walks the window list and opens a connection
    /// to the daemon, and nothing about a session that has been running for a
    /// minute needs to be noticed in under one.
    static let pollInterval: Duration = .seconds(15)

    /// Only one pass at a time.
    ///
    /// A pass decides what is missing before it awaits its first attach, so two
    /// overlapping passes both see the same session as missing and both open a
    /// pane for it. Reading the shown set off live panes does not prevent this
    /// on its own — when both look, neither has opened anything yet.
    private static var reconcileInFlight = false

    private static var pollTask: Task<Void, Never>?
}

extension SessionHostPanes {

    /// Start looking, and keep looking while this machine serves peers.
    ///
    /// Idempotent: the peer server can be brought up more than once in a
    /// process, and a second poller would double every pass.
    static func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            await reconcileWhenReady()
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }
                await reconcile()
            }
        }
    }

    /// Stop when the peer server does — a poller outliving the thing it serves
    /// would keep opening panes for a machine that is no longer a host.
    static func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reconcile once the session host is listening *and* there is somewhere to
    /// put a pane.
    ///
    /// Waiting on the socket alone was not enough. At launch the peer server
    /// can be up before any window is, and the pass then found the sessions,
    /// had nowhere to show them, and gave up — with nothing scheduled to ask
    /// again. Both halves have to be there before the answer means anything.
    @discardableResult
    static func reconcileWhenReady() async -> Int {
        for attempt in 0..<startupSettleAttempts {
            let path = TermMeshDaemon.shared.daemonPeerSocketPath
            guard hasSessionHost(socketPath: path) else { return 0 }
            if TermMeshDaemon.isListening(atUnixSocketPath: path),
               AppDelegate.shared?.tabManager?.selectedWorkspace != nil {
                return await reconcile()
            }
            if attempt + 1 < startupSettleAttempts {
                try? await Task.sleep(for: startupSettleInterval)
            }
        }
        // Gave up on the fast path. Distinguishable from "nothing to show",
        // which is what a silent zero made it indistinguishable from. The
        // poller keeps asking after this, so it is a slow start and not a dead
        // end — say which.
        RemoteWorkLog.info(
            "This machine's session daemon is not serving yet, or there is no "
                + "window to show its sessions in; still checking"
        )
        return 0
    }

    /// Open a pane here for every daemon-held session that has none.
    ///
    /// Failures are per-session: one surface that cannot be attached must not
    /// stop the rest, because the reason is usually that particular session and
    /// not the daemon.
    @discardableResult
    static func reconcile() async -> Int {
        guard !reconcileInFlight else { return 0 }
        reconcileInFlight = true
        defer { reconcileInFlight = false }

        let socketPath = TermMeshDaemon.shared.daemonPeerSocketPath
        guard hasSessionHost(socketPath: socketPath) else { return 0 }
        // Nothing listening: the daemon is down or was never told to serve.
        // Leave the panes alone — they are the record of what is shown, and a
        // daemon that comes back reuses its surface ids, so a pane still up is
        // still that session.
        guard TermMeshDaemon.isListening(atUnixSocketPath: socketPath) else { return 0 }

        let spec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let registry = PeerPaneHostRegistry.shared
        let lease: PeerPaneHostLease
        do {
            lease = try await registry.acquire(spec)
        } catch {
            RemoteWorkLog.debug("session host unreachable at \(socketPath): \(error)")
            return 0
        }
        defer { registry.release(lease) }

        let snapshot: (
            surfaces: [Termmesh_Peer_V1_SurfaceInfo],
            teams: [Termmesh_Peer_V1_Team]
        )
        do {
            snapshot = try await PeerPaneSession.listSessionHostSnapshot(on: lease)
        } catch {
            RemoteWorkLog.debug("session host did not list its sessions: \(error)")
            return 0
        }
        let surfaces = snapshot.surfaces
        let projectNames = projectNamesBySurfaceID(teams: snapshot.teams)
        let projectDirectories = projectWorkingDirectories(teams: snapshot.teams)
        guard let app = AppDelegate.shared, let tabManager = app.tabManager else { return 0 }

        let managers = allTabManagers(app: app, fallback: tabManager)
        for manager in managers {
            migrateShownProjectSurfaces(
                projectNames: projectNames,
                projectDirectories: projectDirectories,
                tabManager: manager
            )
        }

        pruneDismissals(stillHeld: Set(surfaces.map(\.surfaceID)))
        let routed = sessionsNeedingPanes(
            daemonSurfaces: surfaces.map {
                (id: $0.surfaceID, attachable: $0.attachable, surfaceType: $0.surfaceType)
            },
            alreadyShown: shownSurfaceIDs().union(dismissedSurfaceIDs)
        )
        let agentIDs = Set(routed.agent)
        let wanted = routed.terminal + routed.agent
        guard !wanted.isEmpty else { return 0 }

        var opened = 0
        var autoCreatedAnchors: [UUID: UUID] = [:]
        var autoCreatedWorkspaceIDs = Set<UUID>()
        for surfaceID in wanted {
            guard let info = surfaces.first(where: { $0.surfaceID == surfaceID }) else { continue }
            let projectName = projectNames[surfaceID]
            // Every window, not just the active one. `shownSurfaceIDs()` is
            // already window-global, and the repair pass above runs per manager
            // for the same reason: a `[project]` workspace living in a second
            // window was invisible here, so its project took the `.newProject`
            // branch and got a duplicate in the active window — and the repair
            // then found the pane's source already declared and left it. That
            // is this change's own proliferation, reached through a second
            // window rather than a relaunch.
            let destination = workspaceDestination(
                projectName: projectName,
                declaredProjects: declaredProjects(
                    in: managers.flatMap(\.tabs)
                ),
                hostSessionsWorkspaceID: managers.lazy.compactMap { manager in
                    manager.tabs.first(where: { $0.customTitle == "Host Sessions" })?.id
                }.first
            )
            let workspace: Workspace
            switch destination {
            case .existingProject(let id), .existingHostSessions(let id):
                guard let existing = managers.lazy.compactMap({ manager in
                    manager.tabs.first(where: { $0.id == id })
                }).first else {
                    continue
                }
                workspace = existing
            case .newProject(let name):
                workspace = {
                    let created = tabManager.addWorkspace(
                        workingDirectory: projectDirectories[name],
                        select: false
                    )
                    WorkspaceProjectNames.shared.declare(
                        workspaceId: created.id, projectName: name
                    )
                    created.customTitle = "[\(name)]"
                    created.title = "[\(name)]"
                    if let anchor = created.focusedPanelId {
                        autoCreatedAnchors[created.id] = anchor
                    }
                    autoCreatedWorkspaceIDs.insert(created.id)
                    return created
                }()
            case .newHostSessions:
                // Unclaimed daemon sessions are host activity, not members of
                // the Project the user happens to be viewing. Keep them in one
                // stable workspace instead of contaminating `selectedWorkspace`.
                workspace = {
                    let created = tabManager.addWorkspace(select: false)
                    created.customTitle = "Host Sessions"
                    created.title = "Host Sessions"
                    if let anchor = created.focusedPanelId {
                        autoCreatedAnchors[created.id] = anchor
                    }
                    autoCreatedWorkspaceIDs.insert(created.id)
                    return created
                }()
            }
            do {
                let session = try await PeerPaneSession.attach(
                    lease: lease,
                    surface: info,
                    title: info.title.isEmpty ? info.workspaceName : info.title,
                    spec: spec
                )
                // Never steal focus: this runs on its own schedule, not
                // because anyone asked for a pane right now.
                //
                // An agent surface gets an AgentPanel, never a terminal:
                // its bytes are NDJSON events, and `openRemotePane`
                // refuses it by contract. The attach above already
                // selected callback delivery from the same surfaceType
                // (`PeerPaneSession.attach`), which is what
                // `openRemoteAgentPane` requires.
                let openedPane: Bool = agentIDs.contains(surfaceID)
                    ? workspace.openRemoteAgentPane(session: session, focus: false) != nil
                    : workspace.openRemotePane(session: session, focus: false) != nil
                guard openedPane else {
                    session.teardown()
                    if autoCreatedWorkspaceIDs.remove(workspace.id) != nil {
                        autoCreatedAnchors[workspace.id] = nil
                        tabManager.closeWorkspace(workspace)
                    }
                    continue
                }
                if let anchor = autoCreatedAnchors.removeValue(forKey: workspace.id),
                   workspace.panels.count > 1 {
                    _ = workspace.closePanel(anchor, force: true)
                }
                autoCreatedWorkspaceIDs.remove(workspace.id)
                opened += 1
            } catch {
                if autoCreatedWorkspaceIDs.remove(workspace.id) != nil {
                    autoCreatedAnchors[workspace.id] = nil
                    tabManager.closeWorkspace(workspace)
                }
                RemoteWorkLog.error(
                    "could not show session \(info.title.isEmpty ? "?" : info.title): \(error)"
                )
            }
        }
        if opened > 0 {
            RemoteWorkLog.info(
                "Showing \(opened) session\(opened == 1 ? "" : "s") this machine's daemon is holding"
            )
        }
        return opened
    }
}
