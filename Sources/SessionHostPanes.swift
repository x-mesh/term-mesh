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

    static func projectSurfacesForAutoOpen(
        surfaces: [Termmesh_Peer_V1_SurfaceInfo],
        claims: [Data: ProjectClaim],
        suppressedSurfaceIDs: Set<Data>
    ) -> [Termmesh_Peer_V1_SurfaceInfo] {
        surfaces.filter { surface in
            claims[surface.surfaceID] != nil
                && !suppressedSurfaceIDs.contains(surface.surfaceID)
        }
    }

    /// Project manifests are the only authoritative link between a daemon
    /// surface and the Project workspace that should display it. Names, cwd,
    /// and ensure keys are presentation details and can disagree.
    static func projectNamesBySurfaceID(
        teams: [Termmesh_Peer_V1_Team]
    ) -> [Data: String] {
        projectClaimsBySurfaceID(teams: teams).mapValues(\.name)
    }

    @discardableResult
    static func finalizeHostedProjectLayout(
        project: Termmesh_Peer_V1_Team,
        workspace: Workspace,
        anchorPanelID: UUID?,
        layoutStore: ProjectPresentationLayoutStore? = nil
    ) -> TeamOrchestrator.ProjectPresentationLayoutRestoreOutcome? {
        guard !project.projectID.isEmpty,
              let leaderPanelID = workspace.panelID(
                forPeerSurfaceID: project.leaderSurfaceID
              )
        else { return nil }
        let agentPanelIDs = project.members.compactMap { member in
            workspace.panelID(forPeerSurfaceID: member.surfaceID)
        }
        guard agentPanelIDs.count == project.members.count else { return nil }
        return TeamOrchestrator.shared.finalizeRestoredProjectLayout(
            projectID: project.projectID,
            workspace: workspace,
            anchorPanelID: anchorPanelID,
            leaderPanelID: leaderPanelID,
            agentPanelIDs: agentPanelIDs,
            restoreFocus: false,
            layoutStore: layoutStore
        )
    }

    static func hostedProjectLayoutSignature(_ project: Termmesh_Peer_V1_Team) -> String {
        let surfaces = ([project.leaderSurfaceID] + project.members.map(\.surfaceID))
            .map { $0.base64EncodedString() }
            .sorted()
            .joined(separator: ",")
        return "\(project.projectID)|\(project.presentationRevision)|\(surfaces)"
    }

    struct ProjectClaim: Equatable {
        let projectID: String
        let name: String
        let revision: UInt64
        let ownedByRequester: Bool
        let workingDirectory: String

        init(
            projectID: String,
            name: String,
            revision: UInt64,
            ownedByRequester: Bool,
            workingDirectory: String = ""
        ) {
            self.projectID = projectID
            self.name = name
            self.revision = revision
            self.ownedByRequester = ownedByRequester
            self.workingDirectory = workingDirectory
        }
    }

    struct ProjectRoutingSnapshot: Equatable {
        let claims: [Data: ProjectClaim]
        let suppressedSurfaceIDs: Set<Data>
    }

    /// A name is presentation copy, not identity. Stale manifests can retain
    /// a surface that a newer same-named project now owns, so choose the
    /// highest presentation revision per surface before routing it.
    static func projectClaimsBySurfaceID(
        teams: [Termmesh_Peer_V1_Team],
        preferredProjectIDs: Set<String> = []
    ) -> [Data: ProjectClaim] {
        projectRoutingSnapshot(
            teams: teams, preferredProjectIDs: preferredProjectIDs
        ).claims
    }

    /// When this app already owns one durable project identity, older
    /// same-named presentations are historical records, not additional
    /// projects to auto-open. Keep their surfaces out of both the selected
    /// project and Host Sessions; an explicit remote-project adoption can
    /// still open them by identity.
    static func projectRoutingSnapshot(
        teams: [Termmesh_Peer_V1_Team],
        preferredProjectIDs: Set<String> = []
    ) -> ProjectRoutingSnapshot {
        var claims: [Data: ProjectClaim] = [:]
        var suppressed = Set<Data>()
        let grouped = Dictionary(grouping: teams.filter { !$0.projectID.isEmpty }) {
            $0.name.lowercased()
        }
        var allowedProjectIDs = Set<String>()
        for candidates in grouped.values {
            if candidates.count == 1, let only = candidates.first {
                allowedProjectIDs.insert(only.projectID)
                continue
            }
            let explicitlyPreferred = candidates.filter {
                preferredProjectIDs.contains($0.projectID)
            }
            if !explicitlyPreferred.isEmpty {
                allowedProjectIDs.formUnion(explicitlyPreferred.map(\.projectID))
                continue
            }
            let requesterOwned = candidates.filter(\.presentationOwnedByRequester)
            if !requesterOwned.isEmpty {
                let winner = requesterOwned.max { lhs, rhs in
                    (lhs.presentationRevision, lhs.projectID)
                        < (rhs.presentationRevision, rhs.projectID)
                }
                if let winner { allowedProjectIDs.insert(winner.projectID) }
                continue
            }
            // Revisions are scoped to one project id and member count is not
            // recency: an old five-agent project must not beat the one-agent
            // project the user created a minute ago. New daemons preserve the
            // publisher's creation timestamp; legacy records read as zero and
            // fall through to the compatibility heuristics below.
            let newestCreatedAt = candidates.map(\.createdAtUnixSecs).max() ?? 0
            let newest = candidates.filter {
                newestCreatedAt > 0 && $0.createdAtUnixSecs == newestCreatedAt
            }
            if newest.count == 1, let winner = newest.first {
                allowedProjectIDs.insert(winner.projectID)
                continue
            }
            // Two persisted generations of one project can tie on live
            // member count while naming the same durable surface. That shared
            // surface is identity evidence: pick the newest presentation.
            // Same-named projects with disjoint surfaces remain ambiguous and
            // are suppressed below.
            let sharedSurfaceIDs = candidates
                .map { team in
                    Set(
                        [team.leaderSurfaceID]
                            + team.members.compactMap {
                                $0.surfaceID.isEmpty ? nil : $0.surfaceID
                            }
                    ).filter { !$0.isEmpty }
                }
                .dropFirst()
                .reduce(
                    candidates.first.map { team in
                        Set(
                            [team.leaderSurfaceID]
                                + team.members.compactMap {
                                    $0.surfaceID.isEmpty ? nil : $0.surfaceID
                                }
                        ).filter { !$0.isEmpty }
                    } ?? []
                ) { $0.intersection($1) }
            if !sharedSurfaceIDs.isEmpty,
               let winner = candidates.max(by: { lhs, rhs in
                   (lhs.presentationRevision, lhs.projectID)
                       < (rhs.presentationRevision, rhs.projectID)
               }) {
                allowedProjectIDs.insert(winner.projectID)
            }
        }
        let preferredNames = Set(teams.compactMap { team -> String? in
            guard team.presentationOwnedByRequester
                    || preferredProjectIDs.contains(team.projectID)
            else { return nil }
            return team.name.lowercased()
        })
        for team in teams where !team.name.isEmpty && !team.leaderSurfaceID.isEmpty {
            let candidate = ProjectClaim(
                projectID: team.projectID,
                name: team.name,
                revision: team.presentationRevision,
                ownedByRequester: team.presentationOwnedByRequester,
                workingDirectory: team.workingDirectory
            )
            let surfaceIDs = [team.leaderSurfaceID]
                + team.members.compactMap { $0.surfaceID.isEmpty ? nil : $0.surfaceID }
            if !team.projectID.isEmpty, !allowedProjectIDs.contains(team.projectID) {
                suppressed.formUnion(surfaceIDs)
                continue
            }
            if preferredNames.contains(team.name.lowercased()),
               !team.presentationOwnedByRequester,
               !preferredProjectIDs.contains(team.projectID) {
                suppressed.formUnion(surfaceIDs)
                continue
            }
            for surfaceID in surfaceIDs {
                if let current = claims[surfaceID] {
                    if current.ownedByRequester != candidate.ownedByRequester {
                        if current.ownedByRequester { continue }
                    } else {
                        let currentPreferred = preferredProjectIDs.contains(current.projectID)
                        let candidatePreferred = preferredProjectIDs.contains(candidate.projectID)
                        if currentPreferred != candidatePreferred {
                            if currentPreferred { continue }
                        } else if current.revision > candidate.revision
                            || (current.revision == candidate.revision
                                && current.projectID >= candidate.projectID) {
                            continue
                        }
                    }
                }
                claims[surfaceID] = candidate
            }
        }
        // A stale manifest may still mention the active project's leader. The
        // preferred claim wins that shared surface; suppression applies only
        // to surfaces no selected claim owns.
        suppressed.subtract(claims.keys)
        return ProjectRoutingSnapshot(
            claims: claims, suppressedSurfaceIDs: suppressed
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
        declaredProjectClaims(in: workspaces).map { ($0.id, $0.name) }
    }

    struct DeclaredProjectClaim: Equatable {
        let id: UUID
        let name: String
        let projectID: String?
    }

    static func declaredProjectClaims(in workspaces: [Workspace]) -> [DeclaredProjectClaim] {
        let declared = workspaces.compactMap { workspace in
            WorkspaceProjectNames.shared.projectName(for: workspace.id).map {
                DeclaredProjectClaim(
                    id: workspace.id,
                    name: $0,
                    projectID: WorkspaceProjectNames.shared.projectID(for: workspace.id)
                )
            }
        }
        let recovered = workspaces.compactMap { workspace -> DeclaredProjectClaim? in
            guard WorkspaceProjectNames.shared.projectName(for: workspace.id) == nil,
                  let name = projectName(fromWorkspaceTitle: workspace.customTitle)
            else { return nil }
            return DeclaredProjectClaim(id: workspace.id, name: name, projectID: nil)
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
        workspaceDestination(
            projectName: projectName,
            projectID: nil,
            declaredProjects: declaredProjects.map {
                DeclaredProjectClaim(id: $0.id, name: $0.name, projectID: nil)
            },
            hostSessionsWorkspaceID: hostSessionsWorkspaceID
        )
    }

    static func workspaceDestination(
        projectName: String?,
        projectID: String?,
        declaredProjects: [DeclaredProjectClaim],
        hostSessionsWorkspaceID: UUID?
    ) -> WorkspaceDestination {
        if let projectID, !projectID.isEmpty {
            if let existing = declaredProjects.first(where: { $0.projectID == projectID }) {
                return .existingProject(existing.id)
            }
            // Upgrade one legacy name-only declaration in place. This is the
            // host workspace the project already occupied before durable peer
            // project IDs existed. More than one is ambiguous and must not be
            // guessed at — keep those presentations separate instead.
            if let projectName {
                let legacyMatches = declaredProjects.filter {
                    $0.projectID == nil
                        && $0.name.caseInsensitiveCompare(projectName) == .orderedSame
                }
                if legacyMatches.count == 1, let legacy = legacyMatches.first {
                    return .existingProject(legacy.id)
                }
            }
            return projectName.map(WorkspaceDestination.newProject) ?? .newHostSessions
        }
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
        projectClaims: [Data: ProjectClaim],
        tabManager: TabManager
    ) {
        for (surfaceID, claim) in projectClaims {
            guard let source = tabManager.tabs.first(where: {
                $0.panelID(forPeerSurfaceID: surfaceID) != nil
            }),
            let panelID = source.panelID(forPeerSurfaceID: surfaceID),
            let sourcePane = source.paneId(forPanelId: panelID),
            let sourceIndex = source.indexInPane(forPanelId: panelID)
            else { continue }

            let destination = workspaceDestination(
                projectName: claim.name,
                projectID: claim.projectID.isEmpty ? nil : claim.projectID,
                declaredProjects: declaredProjectClaims(in: tabManager.tabs),
                hostSessionsWorkspaceID: nil
            )
            let existingTargetID: UUID? = if case .existingProject(let id) = destination {
                id
            } else {
                nil
            }
            let existingTarget = existingTargetID.flatMap { id in
                tabManager.tabs.first(where: { $0.id == id })
            }
            var targetAnchor: UUID?
            let target = existingTarget ?? {
                let created = tabManager.addWorkspace(
                    workingDirectory: claim.workingDirectory.isEmpty
                        ? nil : claim.workingDirectory,
                    select: false
                )
                targetAnchor = created.focusedPanelId
                WorkspaceProjectNames.shared.declare(
                    workspaceId: created.id,
                    projectName: claim.name,
                    projectID: claim.projectID.isEmpty ? nil : claim.projectID
                )
                created.customTitle = "[\(claim.name)]"
                created.title = "[\(claim.name)]"
                return created
            }()
            if !claim.projectID.isEmpty,
               WorkspaceProjectNames.shared.projectID(for: target.id) == nil {
                WorkspaceProjectNames.shared.declare(
                    workspaceId: target.id,
                    projectName: claim.name,
                    projectID: claim.projectID
                )
            }
            guard target.id != source.id else { continue }
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
    static func shownSurfaceIDs(in tabManagers: [TabManager]? = nil) -> Set<Data> {
        guard let app = AppDelegate.shared else { return [] }
        let managers = tabManagers ?? app.mainWindowContexts.values.map(\.tabManager)
        var shown: Set<Data> = []
        for manager in managers {
            for workspace in manager.tabs {
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

    /// Local viewers that belonged to an older same-named project generation.
    ///
    /// A daemon surface can stay live after its publishing app disappears, and
    /// so can its durable project manifest. When a newer project with the same
    /// display name becomes the routing winner, merely suppressing the old
    /// manifest from the next open pass is not enough: panes opened while it
    /// was the winner remain alive forever, each holding a relay helper pair.
    ///
    /// A surface claimed by the current winner is never superseded even when an
    /// older overlapping manifest also names it.
    static func supersededShownSurfaceIDs(
        shown: Set<Data>,
        suppressed: Set<Data>,
        currentlyClaimed: Set<Data>
    ) -> Set<Data> {
        shown.intersection(suppressed).subtracting(currentlyClaimed)
    }

    /// Close only this app's viewers for superseded local-daemon surfaces. The
    /// daemon-owned work and manifest remain intact and can still be adopted by
    /// exact project id. This is routing cleanup, not a user dismissal, so clear
    /// the dismissal marks installed by the ordinary close funnel afterwards.
    @discardableResult
    static func pruneSupersededLocalSessionHostPanes(
        suppressedSurfaceIDs: Set<Data>,
        currentlyClaimedSurfaceIDs: Set<Data>,
        in tabManagers: [TabManager]
    ) -> Int {
        let targets = supersededShownSurfaceIDs(
            shown: shownSurfaceIDs(in: tabManagers),
            suppressed: suppressedSurfaceIDs,
            currentlyClaimed: currentlyClaimedSurfaceIDs
        )
        guard !targets.isEmpty else { return 0 }

        var closed = 0
        for workspace in tabManagers.flatMap(\.tabs) {
            let panelIDs = workspace.panels.compactMap { panelID, panel -> UUID? in
                if let terminal = panel as? TerminalPanel,
                   let session = terminal.peerPaneSession,
                   Workspace.isLocalSessionHost(session.originSpec),
                   targets.contains(session.originSurface.surfaceID) {
                    return panelID
                }
                if let session = workspace.remoteAgentPaneSessions[panelID],
                   Workspace.isLocalSessionHost(session.originSpec),
                   targets.contains(session.originSurface.surfaceID) {
                    return panelID
                }
                return nil
            }
            for panelID in panelIDs where workspace.closePanel(panelID, force: true) {
                closed += 1
            }
        }
        dismissedSurfaceIDs.subtract(targets)
        return closed
    }

    /// Close only dead local-daemon mirrors after a successful roster read.
    /// A background workspace can miss the relay helper's accept window; its
    /// torn-down panel then stays visible while the next poll opens a fresh
    /// mirror for the same surface. Keeping those shells produced 65 panes in
    /// one saved workspace. Live and intentionally disconnected panes are not
    /// torn down and therefore stay untouched.
    @discardableResult
    static func pruneTornDownLocalSessionHostPanes(
        in tabManagers: [TabManager]
    ) -> Int {
        var closed = 0
        // Closing goes through the ordinary funnel, and that funnel records a
        // dismissal — it cannot tell this cleanup from someone closing the
        // pane on purpose. Leaving the mark in place inverts the whole point
        // of the pass: the surface is still alive on the daemon, so the next
        // poll must open a fresh mirror, and a remembered dismissal is exactly
        // what stops it for the rest of the process. Collect what we close and
        // clear it, the same way the superseded pass does.
        var reopenable = Set<Data>()
        for workspace in tabManagers.flatMap(\.tabs) {
            let dead = workspace.panels.compactMap { panelID, panel -> (UUID, Data)? in
                guard let terminal = panel as? TerminalPanel,
                      let session = terminal.peerPaneSession,
                      session.isTorndown,
                      Workspace.isLocalSessionHost(session.originSpec)
                else { return nil }
                return (panelID, session.originSurface.surfaceID)
            }
            for (panelID, surfaceID) in dead {
                if workspace.closePanel(panelID, force: true) {
                    closed += 1
                    reopenable.insert(surfaceID)
                }
            }
        }
        dismissedSurfaceIDs.subtract(reopenable)
        return closed
    }

    static func containsPeerBackedPane(_ workspace: Workspace) -> Bool {
        if !workspace.remoteAgentPaneSessions.isEmpty { return true }
        return workspace.panels.values.contains { panel in
            (panel as? TerminalPanel)?.peerPaneSession != nil
        }
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
    /// A hosted terminal's relay helper only starts after its workspace mounts.
    /// Fresh project workspaces are deliberately not selected, so keep their
    /// view alive through the relay's 10-second accept window.
    static let autoOpenRealizationPinDuration: Duration = .seconds(12)

    /// Only one pass at a time.
    ///
    /// A pass decides what is missing before it awaits its first attach, so two
    /// overlapping passes both see the same session as missing and both open a
    /// pane for it. Reading the shown set off live panes does not prevent this
    /// on its own — when both look, neither has opened anything yet.
    private static var reconcileInFlight = false

    private static var pollTask: Task<Void, Never>?
    private static var finalizedProjectLayoutSignatures: [String: String] = [:]
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
        guard let app = AppDelegate.shared, let tabManager = app.tabManager else { return 0 }

        let managers = allTabManagers(app: app, fallback: tabManager)
        let pruned = pruneTornDownLocalSessionHostPanes(in: managers)
        if pruned > 0 {
            RemoteWorkLog.info(
                "Removed \(pruned) dead hosted pane\(pruned == 1 ? "" : "s") before reconciling the live roster"
            )
        }
        let liveSurfaceIDs = Set(surfaces.map(\.surfaceID))
        // Only a live orchestrator team is an explicit preference. A workspace
        // that this reconciler auto-created is an observation of the previous
        // routing winner, not authority to keep that winner forever. Feeding
        // its declaration back here made the first stale same-named manifest
        // self-pin even after a fuller/newer project appeared.
        let activeTeamIDs = TeamOrchestrator.shared.teams.values.compactMap { team in
            team.teamUuid.map { "team:\($0)" }
        }
        let routing = projectRoutingSnapshot(
            teams: snapshot.teams,
            preferredProjectIDs: Set(activeTeamIDs)
        )
        let projectClaims = routing.claims
        let superseded = pruneSupersededLocalSessionHostPanes(
            suppressedSurfaceIDs: routing.suppressedSurfaceIDs,
            currentlyClaimedSurfaceIDs: Set(projectClaims.keys),
            in: managers
        )
        if superseded > 0 {
            RemoteWorkLog.info(
                "Closed \(superseded) superseded hosted pane\(superseded == 1 ? "" : "s")"
            )
        }
        for manager in managers {
            migrateShownProjectSurfaces(
                projectClaims: projectClaims,
                tabManager: manager
            )
        }

        pruneDismissals(stillHeld: liveSurfaceIDs)
        // Automatic session-host presentation is project-driven. Bare daemon
        // shells belong in the explicit Host Sessions browser; opening every
        // unclaimed surface on each poll creates panes the user never asked
        // for and repeatedly reopens them after their workspace closes.
        let displayableSurfaces = projectSurfacesForAutoOpen(
            surfaces: surfaces,
            claims: projectClaims,
            suppressedSurfaceIDs: routing.suppressedSurfaceIDs
        )
        let routed = sessionsNeedingPanes(
            daemonSurfaces: displayableSurfaces.map {
                (id: $0.surfaceID, attachable: $0.attachable, surfaceType: $0.surfaceType)
            },
            alreadyShown: shownSurfaceIDs(in: managers).union(dismissedSurfaceIDs)
        )
        let agentIDs = Set(routed.agent)
        let wanted = routed.terminal + routed.agent
        var opened = 0
        var autoCreatedAnchors: [UUID: UUID] = [:]
        var autoCreatedWorkspaceIDs = Set<UUID>()
        for surfaceID in wanted {
            guard let info = displayableSurfaces.first(where: { $0.surfaceID == surfaceID }) else { continue }
            let projectClaim = projectClaims[surfaceID]
            // Every window, not just the active one. `shownSurfaceIDs()` is
            // already window-global, and the repair pass above runs per manager
            // for the same reason: a `[project]` workspace living in a second
            // window was invisible here, so its project took the `.newProject`
            // branch and got a duplicate in the active window — and the repair
            // then found the pane's source already declared and left it. That
            // is this change's own proliferation, reached through a second
            // window rather than a relaunch.
            let destination = workspaceDestination(
                projectName: projectClaim?.name,
                projectID: projectClaim?.projectID,
                declaredProjects: declaredProjectClaims(
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
                        workingDirectory: projectClaim.flatMap { claim in
                            claim.workingDirectory.isEmpty ? nil : claim.workingDirectory
                        },
                        select: false
                    )
                    WorkspaceProjectNames.shared.declare(
                        workspaceId: created.id,
                        projectName: name,
                        projectID: projectClaim?.projectID
                    )
                    created.customTitle = "[\(name)]"
                    created.title = "[\(name)]"
                    if let anchor = created.focusedPanelId {
                        autoCreatedAnchors[created.id] = anchor
                    }
                    autoCreatedWorkspaceIDs.insert(created.id)
                    pinAutoOpenedWorkspace(created.id, on: tabManager)
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
                    pinAutoOpenedWorkspace(created.id, on: tabManager)
                    return created
                }()
            }
            if let projectClaim,
               WorkspaceProjectNames.shared.projectID(for: workspace.id) == nil {
                WorkspaceProjectNames.shared.declare(
                    workspaceId: workspace.id,
                    projectName: projectClaim.name,
                    projectID: projectClaim.projectID
                )
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
                let anchor = autoCreatedAnchors[workspace.id]
                let openedPane: Bool
                if agentIDs.contains(surfaceID) {
                    openedPane = workspace.openRemoteAgentPane(
                        session: session, focus: false
                    ) != nil
                } else if let anchor {
                    // A fresh workspace already has one local terminal. Replace
                    // that placeholder in place for the first hosted terminal;
                    // splitting and immediately closing the anchor made Bonsplit
                    // tear down the new relay pane again a few seconds later.
                    openedPane = workspace.replaceTerminalPaneWithRemote(
                        panelId: anchor, session: session
                    ) != nil
                    if openedPane { autoCreatedAnchors[workspace.id] = nil }
                } else {
                    openedPane = workspace.openRemotePane(
                        session: session, focus: false
                    ) != nil
                }
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
        let selectedProjectIDs = Set(projectClaims.values.map(\.projectID))
        finalizedProjectLayoutSignatures = finalizedProjectLayoutSignatures.filter {
            selectedProjectIDs.contains($0.key)
        }
        for project in snapshot.teams where selectedProjectIDs.contains(project.projectID) {
            let signature = hostedProjectLayoutSignature(project)
            guard finalizedProjectLayoutSignatures[project.projectID] != signature,
                  let workspace = managers.lazy.flatMap(\.tabs).first(where: {
                    WorkspaceProjectNames.shared.projectID(for: $0.id) == project.projectID
                  }),
                  finalizeHostedProjectLayout(
                    project: project,
                    workspace: workspace,
                    anchorPanelID: autoCreatedAnchors[workspace.id],
                    layoutStore: nil
                  ) != nil
            else { continue }
            finalizedProjectLayoutSignatures[project.projectID] = signature
        }
        if opened > 0 {
            RemoteWorkLog.info(
                "Showing \(opened) session\(opened == 1 ? "" : "s") this machine's daemon is holding"
            )
        }
        return opened
    }

    private static func pinAutoOpenedWorkspace(_ id: UUID, on tabManager: TabManager) {
        tabManager.pinWorkspaceForSurfaceRealization(id)
        Task { @MainActor [weak tabManager] in
            try? await Task.sleep(for: autoOpenRealizationPinDuration)
            tabManager?.unpinWorkspaceForSurfaceRealization(id)
        }
    }
}
