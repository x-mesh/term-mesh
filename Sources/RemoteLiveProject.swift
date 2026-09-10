import Foundation
import PeerProto

/// Views an existing GUI-owned team without adopting its control plane.
@MainActor
final class RemoteLiveProject {
    struct BoardContext {
        let workspaceID: UUID
        let teamName: String
        let teamUUID: String
        let projectID: String
        let liveWorkspaceID: Data
        let leaderSurfaceID: Data
        let presentationRevision: UInt64
        let delegationState: ProjectDelegationState
        let workerCount: Int
        let hostSpec: PeerPaneHostSpec
        fileprivate let viewerGeneration: UUID
    }

    enum DelegationError: LocalizedError {
        case unavailable, refused(String), invalidResponse, staleViewer
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The Project owner is unavailable."
            case .refused(let message): return message
            case .invalidResponse: return "The Project owner returned an invalid delegation state."
            case .staleViewer: return "This Project viewer is no longer current."
            }
        }
    }

    private static var viewers: [String: RemoteLiveProject] = [:]
    private static var boardContexts: [UUID: BoardContext] = [:]
    private static var opening: Set<String> = []
    private static var delegationRequests: [UUID: UInt64] = [:]
    private weak var workspace: Workspace?
    private weak var tabManager: TabManager?
    private let hostID: String
    private let projectID: String
    private let endpoint: PeerPaneHostKey
    private let workspaceID: UUID
    private let viewerGeneration = UUID()
    private var updating = false
    private var lastSurfaceIDs: Set<Data> = []

    #if DEBUG
    static func workspaceForTesting(projectID: String) -> Workspace? {
        viewers.values.first { $0.projectID == projectID }?.workspace
    }

    static func boardContextForTesting(projectID: String) -> BoardContext? {
        guard let workspace = workspaceForTesting(projectID: projectID) else { return nil }
        return boardContexts[workspace.id]
    }
    #endif

    static func boardContext(for workspaceID: UUID?) -> BoardContext? {
        workspaceID.flatMap { boardContexts[$0] }
    }

    static func detach(workspaceID: UUID) {
        boardContexts[workspaceID] = nil
        delegationRequests[workspaceID] = nil
        viewers = viewers.filter { $0.value.workspaceID != workspaceID }
    }

    static func setDelegationLevel(
        workspaceID: UUID, level: ProjectDelegationLevel
    ) async throws -> ProjectDelegationState {
        guard let context = boardContexts[workspaceID] else { throw DelegationError.staleViewer }
        let request = (delegationRequests[workspaceID] ?? 0) &+ 1
        delegationRequests[workspaceID] = request
        let lease: PeerPaneHostLease
        do {
            lease = try await PeerPaneHostRegistry.shared.acquire(context.hostSpec)
        } catch { throw DelegationError.unavailable }
        defer { PeerPaneHostRegistry.shared.release(lease) }
        let params: [String: Any] = [
            "team_name": context.teamName, "team_uuid": context.teamUUID,
            "project_id": context.projectID,
            "live_workspace_id": context.liveWorkspaceID.base64EncodedString(),
            "leader_surface_id": context.leaderSurfaceID.base64EncodedString(),
            "presentation_revision": context.presentationRevision,
            "level": level.rawValue,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let json = String(data: data, encoding: .utf8),
              let connection = try? await PeerRelaySession.connect(
                hostSockPath: lease.hostSockPath
              ) else { throw DelegationError.unavailable }
        defer { Task { await connection.cancel() } }
        let response: Termmesh_Peer_V1_TeamCallResponse
        do {
            response = try await connection.session.callTeam(
                method: "team.delegation.configure", paramsJSON: json
            )
        } catch { throw DelegationError.unavailable }
        guard response.ok else {
            throw DelegationError.refused(response.errorMessage)
        }
        guard let resultData = response.resultJson.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else { throw DelegationError.invalidResponse }
        guard ProjectDelegationLevel(rawValue: result["configured"] as? String ?? "") != nil,
              ProjectDelegationLevel(rawValue: result["effective"] as? String ?? "") != nil
        else { throw DelegationError.invalidResponse }
        guard delegationRequests[workspaceID] == request,
              let current = boardContexts[workspaceID],
              current.viewerGeneration == context.viewerGeneration,
              current.teamUUID == context.teamUUID, current.projectID == context.projectID,
              current.liveWorkspaceID == context.liveWorkspaceID,
              current.leaderSurfaceID == context.leaderSurfaceID
        else { throw DelegationError.staleViewer }
        // The mutation reply proves only that the owner accepted the write.
        // Re-read the exact Project on the same authenticated session so the
        // visible state still comes from the owner roster, without polling.
        let teams: [Termmesh_Peer_V1_Team]
        do {
            teams = try await connection.session.listTeams()
        } catch { throw DelegationError.unavailable }
        guard let wire = teams.first(where: {
            $0.name == context.teamName && $0.teamUuid == context.teamUUID
                && $0.projectID == context.projectID
                && $0.liveWorkspaceID == context.liveWorkspaceID
                && $0.leaderSurfaceID == context.leaderSurfaceID
                && $0.presentationRevision >= context.presentationRevision
        }) else { throw DelegationError.staleViewer }
        let authoritative = RemoteHostStore.remoteTeamSummary(wire).delegationState
        guard delegationRequests[workspaceID] == request,
              let refreshed = boardContexts[workspaceID],
              refreshed.viewerGeneration == context.viewerGeneration,
              refreshed.liveWorkspaceID == context.liveWorkspaceID,
              refreshed.leaderSurfaceID == context.leaderSurfaceID
        else { throw DelegationError.staleViewer }
        boardContexts[workspaceID] = BoardContext(
            workspaceID: workspaceID, teamName: context.teamName, teamUUID: context.teamUUID,
            projectID: context.projectID, liveWorkspaceID: context.liveWorkspaceID,
            leaderSurfaceID: context.leaderSurfaceID,
            presentationRevision: wire.presentationRevision,
            delegationState: authoritative, workerCount: wire.members.count,
            hostSpec: context.hostSpec, viewerGeneration: context.viewerGeneration
        )
        NotificationCenter.default.post(name: .reviewBoardSnapshotDidChange, object: nil)
        return authoritative
    }

    private func updateBoardContext(
        host: HostEntry, project: RemoteTeamSummary, allowIncarnationChange: Bool = false
    ) {
        if let current = Self.boardContexts[workspaceID],
           current.viewerGeneration == viewerGeneration {
            let sameIncarnation = current.liveWorkspaceID == project.liveWorkspaceID
                && current.leaderSurfaceID == project.leaderSurfaceID
            if !sameIncarnation && !allowIncarnationChange { return }
            if sameIncarnation && project.presentationRevision < current.presentationRevision {
                return
            }
        }
        Self.boardContexts[workspaceID] = BoardContext(
            workspaceID: workspaceID, teamName: project.name, teamUUID: project.teamUUID,
            projectID: project.projectID, liveWorkspaceID: project.liveWorkspaceID,
            leaderSurfaceID: project.leaderSurfaceID,
            presentationRevision: project.presentationRevision,
            delegationState: project.delegationState, workerCount: project.members.count,
            hostSpec: host.paneHostSpec, viewerGeneration: viewerGeneration
        )
    }

    private init(host: HostEntry, project: RemoteTeamSummary, workspace: Workspace, tabManager: TabManager) {
        hostID = host.id
        projectID = project.projectID
        endpoint = host.paneHostSpec.hostKey
        workspaceID = workspace.id
        self.workspace = workspace
        self.tabManager = tabManager
    }

    static func open(host: HostEntry, project: RemoteTeamSummary, tabManager: TabManager,
                     select: Bool) async -> Bool {
        guard project.isGUILive, project.rosterVerified, host.isConnected,
              project.sourceEndpoint == host.paneHostSpec.hostKey else { return false }
        let key = "\(host.paneHostSpec.hostKey)|\(project.projectID)"
        if let viewer = viewers[key], let workspace = viewer.workspace,
           let owner = viewer.tabManager, owner.tabs.contains(where: { $0 === workspace }) {
            let result = await viewer.update(host: host, project: project)
            if select {
                owner.selectWorkspace(workspace)
                ReviewBoardSettings.setVisible(true)
            }
            return result
        }
        guard opening.insert(key).inserted else { return false }
        defer { opening.remove(key) }
        let existing = PeerClientCoordinator.shared.mirroredWorkspace(
            forHostKey: host.paneHostSpec.hostKey, hostWorkspaceID: project.liveWorkspaceID
        )
        let owner = existing.flatMap { AppDelegate.shared?.tabManagerFor(tabId: $0.id) } ?? tabManager
        let workspace = existing ?? owner.addWorkspace(select: false)
        if let mirror = workspace.peerMirror {
            mirror.teardown()
            workspace.peerMirror = nil
        }
        let anchor = existing == nil ? workspace.focusedPanelId : nil
        let viewer = RemoteLiveProject(host: host, project: project, workspace: workspace, tabManager: owner)
        viewers[key] = viewer
        viewer.updateBoardContext(host: host, project: project)
        workspace.setCustomTitle("[\(project.name)] · \(host.displayName)")
        let result = await viewer.update(host: host, project: project)
        if let leader = workspace.panelID(forPeerSurfaceID: project.leaderSurfaceID) {
            TeamOrchestrator.shared.finalizeRestoredProjectLayout(
                projectID: "gui:\(key)", workspace: workspace,
                anchorPanelID: anchor, leaderPanelID: leader,
                agentPanelIDs: project.members.compactMap { workspace.panelID(forPeerSurfaceID: $0.surfaceID) },
                restoreFocus: false
            )
        }
        if select {
            owner.selectWorkspace(workspace)
            ReviewBoardSettings.setVisible(true)
        }
        return result
    }

    /// Source freshness is independent: a failed daemon poll cannot remove GUI panes.
    static func applyRosterAvailability(
        projectPresent: Bool, rosterVerified: Bool, sessions: [AgentSession]
    ) {
        // A failed roster read says nothing about an existing live attachment.
        // Its own transport callbacks remain responsible for disconnects.
        guard rosterVerified, !projectPresent else { return }
        for session in sessions { session.livePresentationDisconnected() }
    }

    static func refresh(host: HostEntry) {
        for project in host.teams where project.isGUILive && project.rosterVerified {
            if let mirror = PeerClientCoordinator.shared.mirroredWorkspace(
                forHostKey: host.paneHostSpec.hostKey, hostWorkspaceID: project.liveWorkspaceID
            ), let owner = AppDelegate.shared?.tabManagerFor(tabId: mirror.id) {
                Task { _ = await open(host: host, project: project, tabManager: owner, select: false) }
            }
        }
        for (key, viewer) in viewers {
            guard let workspace = viewer.workspace, let owner = viewer.tabManager,
                  owner.tabs.contains(where: { $0 === workspace }) else {
                detach(workspaceID: viewer.workspaceID)
                viewers.removeValue(forKey: key)
                continue
            }
            guard viewer.hostID == host.id else { continue }
            let project = host.teams.first(where: {
                $0.isGUILive && $0.projectID == viewer.projectID
            })
            applyRosterAvailability(
                projectPresent: project != nil, rosterVerified: host.guiRosterVerified,
                sessions: workspace.panels.values.compactMap { ($0 as? AgentPanel)?.session }
            )
            if let project, project.rosterVerified {
                Task { await viewer.update(host: host, project: project) }
            }
        }
    }

    @discardableResult
    private func update(host: HostEntry, project: RemoteTeamSummary) async -> Bool {
        guard let workspace, let owner = tabManager,
              owner.tabs.contains(where: { $0 === workspace }),
              host.paneHostSpec.hostKey == endpoint,
              host.isConnected, project.rosterVerified else { return false }
        updateBoardContext(host: host, project: project)
        guard !updating else { return true }
        updating = true
        defer { updating = false }
        let registry = PeerPaneHostRegistry.shared
        guard let lease = try? await registry.acquire(host.paneHostSpec) else { return false }
        defer { registry.release(lease) }
        guard let surfaces = try? await PeerPaneSession.listSurfaces(on: lease) else { return false }
        // A different GUI-owner incarnation is authoritative only after the
        // current peer proves its exact leader surface exists. This separates
        // a real owner restart from a late roster belonging to the retired app.
        guard surfaces.contains(where: {
            $0.surfaceID == project.leaderSurfaceID && $0.attachable
        }) else { return false }
        updateBoardContext(host: host, project: project, allowIncarnationChange: true)
        var wanted = [(project.leaderSurfaceID, "Leader")]
        wanted += project.members.map { ($0.surfaceID, $0.name) }
        let desiredIDs = Set(wanted.map(\.0).filter { !$0.isEmpty })
        for old in lastSurfaceIDs.subtracting(desiredIDs) {
            if let id = workspace.panelID(forPeerSurfaceID: old) {
                _ = workspace.closePanel(id, force: true)
            }
        }
        var complete = true
        for (surfaceID, title) in wanted {
            guard !surfaceID.isEmpty,
                  let surface = surfaces.first(where: { $0.surfaceID == surfaceID && $0.attachable }) else {
                complete = false
                continue
            }
            guard owner.tabs.contains(where: { $0 === workspace }) else { return false }
            if let id = workspace.panelID(forPeerSurfaceID: surfaceID) {
                let session = workspace.remoteAgentPaneSessions[id]
                if session == nil || (session?.isTorndown == false && session?.relayStartupState != .failed
                                      && session?.isRelayEnded == false) { continue }
            }
            let previous = workspace.panelID(forPeerSurfaceID: surfaceID)
            guard let session = try? await PeerPaneSession.attach(
                lease: lease, surface: surface, title: title, spec: host.paneHostSpec
            ) else { complete = false; continue }
            guard owner.tabs.contains(where: { $0 === workspace }) else {
                session.teardown()
                return false
            }
            let panelID: UUID?
            if surface.surfaceType == "agent" {
                let member = project.members.first { $0.surfaceID == surfaceID }
                panelID = workspace.openRemoteAgentPane(session: session, focus: false,
                    agentName: member?.name, color: member?.color ?? "")?.id
            } else {
                panelID = workspace.openRemotePane(session: session, focus: false, lifetime: .keepAlive)?.id
            }
            guard panelID != nil else { session.teardown(); complete = false; continue }
            if let previous { _ = workspace.closePanel(previous, force: true) }
        }
        lastSurfaceIDs = desiredIDs
        workspace.setCustomTitle("[\(project.name)] · \(host.displayName)"
            + (complete ? "" : " · some members unavailable"))
        if !complete {
            RemoteWorkLog.info("Project \(project.name) on \(host.displayName) has unavailable members; retrying on roster refresh")
        }
        return complete
    }
}

#if DEBUG
/// Deterministic socket E2E fixture. Real GUI provider, peer connections and
/// panes; in-memory echo agents avoid launching provider CLIs or spending tokens.
@MainActor
enum RemoteLiveProjectFixture {
    private static var source: Workspace?
    private static var server: PeerServer?
    private static var host: HostEntry?
    private static var project: RemoteTeamSummary?
    private static var teamName: String?
    private static var failure: String?
    private static var starting = false
    private static var cleaning = false
    private static var boardModel: ReviewBoardViewModel?
    private static var identityRefusal = false
    private static var savedBoardVisibility: Bool?

    static func command(_ params: [String: Any], tabManager: TabManager?) -> TerminalController.V2CallResult {
        guard let tabManager else { return .err(code: "not_found", message: "window missing", data: nil) }
        let action = params["action"] as? String ?? "status"
        if action == "start", !starting, source == nil {
            starting = true
            failure = nil
            savedBoardVisibility = ReviewBoardSettings.isVisible
            ReviewBoardSettings.setVisible(false)
            Task { @MainActor in
                defer { starting = false }
                let name = "live-fixture-\(UUID().uuidString.prefix(8))"
                let workspace = tabManager.addWorkspace(select: false)
                tabManager.pinWorkspaceForSurfaceRealization(workspace.id)
                source = workspace
                teamName = name
                guard let leader = workspace.focusedPanelId else { failure = "no leader"; return }
                var members: [TeamOrchestrator.AgentMember] = []
                for index in 0..<5 {
                    guard let panel = workspace.newAgentSplit(from: leader, orientation: .horizontal,
                        agentName: "worker-\(index)", teamName: name, workingDirectory: "/tmp",
                        cli: "claude", color: "green", focus: false) else {
                        failure = "no native panel"; return
                    }
                    let session = panel.session
                    session.startRemote(interruptible: true, cli: "claude", sink: { [weak session] bytes in
                        session?.consume(bytes)
                    })
                    session.appendLocalNotice("before attach worker-\(index)")
                    members.append(.init(id: "worker-\(index)@\(name)", name: "worker-\(index)",
                        teamName: name, cli: "claude", launchCommand: "", model: "fixture",
                        agentType: "executor", color: "green", instructions: "",
                        workspaceId: workspace.id, panelId: panel.id, createdAt: Date()))
                }
                TeamOrchestrator.shared.teams[name] = .init(id: name, leaderSessionId: UUID().uuidString,
                    leaderMode: "adopted", leaderModel: "fixture", leaderPanelId: leader,
                    workingDirectory: "/tmp", workspaceId: workspace.id, agents: members,
                    createdAt: Date(), worktreeMode: "off", teamUuid: UUID().uuidString)
                if let team = TeamOrchestrator.shared.teams[name] {
                    TeamDataStore.shared.registerTeam(
                        name, agents: team.agents.map {
                            .init(name: $0.name, instanceId: $0.agentInstanceId)
                        }, delegationState: team.delegationState
                    )
                }
                let path = "/tmp/tm-live-fixture-\(UUID().uuidString.prefix(8)).sock"
                let provider = GhosttyPaneSurfaceProvider()
                let listener = PeerServer(socketPath: path, provider: provider)
                server = listener
                do {
                    try await listener.start()
                    let connection = try await PeerRelaySession.connectAndList(hostSockPath: path)
                    let teams = try await connection.session.listTeams()
                    await connection.cancel()
                    guard let wire = teams.first(where: { $0.name == name }) else {
                        failure = "GUI project not listed"; return
                    }
                    var summary = RemoteHostStore.remoteTeamSummary(wire)
                    summary.isGUILive = true
                    summary.liveWorkspaceID = wire.liveWorkspaceID
                    summary.sourceEndpoint = .direct(sockPath: path)
                    project = summary
                    let entry = HostEntry(id: path, displayName: "Live fixture", connectionState: .connected,
                        workspaces: [], teams: [summary], activeSockPath: path)
                    host = entry
                    if !(await RemoteLiveProject.open(host: entry, project: summary,
                                                     tabManager: tabManager, select: true)) {
                        failure = "not all project surfaces attached"
                    }
                    let model = ReviewBoardViewModel()
                    model.setActiveTeamProvider { nil }
                    model.setRemoteContextProvider {
                        RemoteLiveProject.boardContext(for: tabManager.selectedTabId)
                    }
                    model.workspaceSelectionDidChange()
                    boardModel = model
                } catch { failure = String(describing: error) }
            }
        } else if action == "feed", let source {
            for panel in source.panels.values.compactMap({ $0 as? AgentPanel }) {
                panel.session.appendLocalNotice("after attach")
            }
        } else if action == "send", let project,
                  let viewer = RemoteLiveProject.workspaceForTesting(projectID: project.projectID),
                  let panel = viewer.panels.values.compactMap({ $0 as? AgentPanel }).first {
            _ = try? panel.session.send("remote-live-input", from: .person)
        } else if action == "reconnect", let project, let host,
                  let viewer = RemoteLiveProject.workspaceForTesting(projectID: project.projectID) {
            for session in viewer.remoteAgentPaneSessions.values { session.teardown() }
            RemoteLiveProject.refresh(host: host)
        } else if action == "reopen", let project, let host {
            Task { _ = await RemoteLiveProject.open(host: host, project: project, tabManager: tabManager, select: false) }
        } else if action == "delegation",
                  let raw = params["level"] as? String,
                  let level = ProjectDelegationLevel(rawValue: raw) {
            boardModel?.setDelegationLevel(level)
        } else if action == "refresh_manifest", let host {
            Task { @MainActor in
                do {
                    let connection = try await PeerRelaySession.connectAndList(
                        hostSockPath: host.activeSockPath
                    )
                    let teams = try await connection.session.listTeams()
                    await connection.cancel()
                    guard let name = teamName, let wire = teams.first(where: { $0.name == name })
                    else { failure = "refreshed GUI project missing"; return }
                    var summary = RemoteHostStore.remoteTeamSummary(wire)
                    summary.isGUILive = true
                    summary.liveWorkspaceID = wire.liveWorkspaceID
                    summary.sourceEndpoint = host.paneHostSpec.hostKey
                    project = summary
                    let refreshed = HostEntry(
                        id: host.id, displayName: host.displayName,
                        connectionState: .connected, workspaces: [], teams: [summary],
                        activeSockPath: host.activeSockPath
                    )
                    self.host = refreshed
                    _ = await RemoteLiveProject.open(
                        host: refreshed, project: summary, tabManager: tabManager, select: false
                    )
                    boardModel?.workspaceSelectionDidChange()
                } catch { failure = String(describing: error) }
            }
        } else if action == "invalid_identity", let context = project.flatMap({
            RemoteLiveProject.boardContextForTesting(projectID: $0.projectID)
        }) {
            Task {
                let lease = try? await PeerPaneHostRegistry.shared.acquire(context.hostSpec)
                guard let lease else { failure = "identity test connection failed"; return }
                defer { PeerPaneHostRegistry.shared.release(lease) }
                let connection = try? await PeerRelaySession.connect(hostSockPath: lease.hostSockPath)
                guard let connection else { failure = "identity test handshake failed"; return }
                defer { Task { await connection.cancel() } }
                let params: [String: Any] = [
                    "team_name": context.teamName, "team_uuid": "wrong",
                    "project_id": context.projectID,
                    "live_workspace_id": context.liveWorkspaceID.base64EncodedString(),
                    "leader_surface_id": context.leaderSurfaceID.base64EncodedString(),
                    "presentation_revision": context.presentationRevision,
                    "level": ProjectDelegationLevel.guarded.rawValue,
                ]
                let data = try? JSONSerialization.data(withJSONObject: params)
                let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let response = try? await connection.session.callTeam(
                    method: "team.delegation.configure", paramsJSON: json
                )
                identityRefusal = response?.ok == false && response?.errorCode == "identity_mismatch"
                if !identityRefusal { failure = "stale Project identity was accepted" }
            }
        } else if action == "cleanup" {
            cleaning = true
            let listener = server
            let oldSource = source
            let oldProject = project
            let oldTeamName = teamName
            Task { @MainActor in
                if let oldTeamName {
                    TeamOrchestrator.shared.teams.removeValue(forKey: oldTeamName)
                    TeamDataStore.shared.unregisterTeam(oldTeamName)
                }
                if let oldProject, let viewer = RemoteLiveProject.workspaceForTesting(
                    projectID: oldProject.projectID
                ) { tabManager.closeWorkspace(viewer) }
                if let oldSource {
                    tabManager.unpinWorkspaceForSurfaceRealization(oldSource.id)
                    tabManager.closeWorkspace(oldSource)
                }
                await listener?.stop()
                if let savedBoardVisibility {
                    ReviewBoardSettings.setVisible(savedBoardVisibility)
                }
                source = nil; server = nil; host = nil; project = nil; teamName = nil
                boardModel = nil; savedBoardVisibility = nil; cleaning = false
            }
        }
        let viewer = project.flatMap { RemoteLiveProject.workspaceForTesting(projectID: $0.projectID) }
        let board = project.flatMap { RemoteLiveProject.boardContextForTesting(projectID: $0.projectID) }
        let ownerDelegation = teamName.flatMap {
            TeamOrchestrator.shared.teams[$0]?.delegationState.effective.rawValue
        } ?? ""
        var matching = 0
        var echoes = 0
        if let source, let viewer {
            for panel in source.panels.values.compactMap({ $0 as? AgentPanel }) {
                let id = withUnsafeBytes(of: panel.id.uuid) { Data($0) }
                if let targetID = viewer.panelID(forPeerSurfaceID: id),
                   let target = viewer.panels[targetID] as? AgentPanel,
                   !panel.session.entries.isEmpty, panel.session.entries == target.session.entries {
                    matching += 1
                }
                echoes += panel.session.entries.filter {
                    if case .said(_, _, "remote-live-input") = $0 { return true }
                    return false
                }.count
            }
        }
        return .ok(["starting": starting, "cleaning": cleaning, "failure": failure ?? "",
                    "source_panels": source?.panels.count ?? 0,
                    "viewer_panels": viewer?.panels.count ?? 0,
                    "matching_transcripts": matching, "input_echoes": echoes,
                    "viewer_id": viewer?.id.uuidString ?? "",
                    "source_id": source?.id.uuidString ?? "",
                    "source_agent_ids": source?.panels.values.compactMap { ($0 as? AgentPanel)?.id.uuidString }.sorted() ?? [],
                    "viewer_agent_ids": viewer?.remoteAgentPaneSessions.keys.map(\.uuidString).sorted() ?? [],
                    "active_viewer_agents": viewer?.remoteAgentPaneSessions.keys.filter { viewer?.peerAgentPanelIsLive($0) == true }.count ?? 0,
                    "local_team_count": TeamOrchestrator.shared.teams.count,
                    "review_board_visible": ReviewBoardSettings.isVisible,
                    "board_team": board?.teamName ?? "",
                    "source_team": teamName ?? "",
                    "board_workspace": board?.workspaceID.uuidString ?? "",
                    "board_workers": board?.workerCount ?? 0,
                    "board_delegation": board?.delegationState.effective.rawValue ?? "",
                    "owner_delegation": ownerDelegation,
                    "panel_delegation": boardModel?.delegation?.level.rawValue ?? "",
                    "panel_remote": boardModel?.delegation?.isRemoteViewer ?? false,
                    "delegation_error": boardModel?.delegationError ?? "",
                    "identity_refusal": identityRefusal])
    }
}
#endif
