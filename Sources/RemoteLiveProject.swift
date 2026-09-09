import Foundation
import PeerProto

/// Views an existing GUI-owned team without adopting its control plane.
@MainActor
final class RemoteLiveProject {
    private static var viewers: [String: RemoteLiveProject] = [:]
    private static var opening: Set<String> = []
    private weak var workspace: Workspace?
    private weak var tabManager: TabManager?
    private let hostID: String
    private let projectID: String
    private let endpoint: PeerPaneHostKey
    private var updating = false
    private var lastSurfaceIDs: Set<Data> = []

    #if DEBUG
    static func workspaceForTesting(projectID: String) -> Workspace? {
        viewers.values.first { $0.projectID == projectID }?.workspace
    }
    #endif

    private init(host: HostEntry, project: RemoteTeamSummary, workspace: Workspace, tabManager: TabManager) {
        hostID = host.id
        projectID = project.projectID
        endpoint = host.paneHostSpec.hostKey
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
            if select { owner.selectWorkspace(workspace) }
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
        if select { owner.selectWorkspace(workspace) }
        return result
    }

    /// Source freshness is independent: a failed daemon poll cannot remove GUI panes.
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
                viewers.removeValue(forKey: key)
                continue
            }
            guard viewer.hostID == host.id else { continue }
            if let project = host.teams.first(where: {
                $0.isGUILive && $0.projectID == viewer.projectID
            }), project.rosterVerified {
                Task { await viewer.update(host: host, project: project) }
            } else {
                for panel in workspace.panels.values.compactMap({ $0 as? AgentPanel }) {
                    panel.session.livePresentationDisconnected()
                }
            }
        }
    }

    @discardableResult
    private func update(host: HostEntry, project: RemoteTeamSummary) async -> Bool {
        guard !updating, let workspace, let owner = tabManager,
              owner.tabs.contains(where: { $0 === workspace }),
              host.paneHostSpec.hostKey == endpoint,
              host.isConnected, project.rosterVerified else { return false }
        updating = true
        defer { updating = false }
        let registry = PeerPaneHostRegistry.shared
        guard let lease = try? await registry.acquire(host.paneHostSpec) else { return false }
        defer { registry.release(lease) }
        guard let surfaces = try? await PeerPaneSession.listSurfaces(on: lease) else { return false }
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

    static func command(_ params: [String: Any], tabManager: TabManager?) -> TerminalController.V2CallResult {
        guard let tabManager else { return .err(code: "not_found", message: "window missing", data: nil) }
        let action = params["action"] as? String ?? "status"
        if action == "start", !starting, source == nil {
            starting = true
            failure = nil
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
        } else if action == "cleanup" {
            if let teamName { TeamOrchestrator.shared.teams.removeValue(forKey: teamName) }
            if let project, let viewer = RemoteLiveProject.workspaceForTesting(projectID: project.projectID) {
                tabManager.closeWorkspace(viewer)
            }
            if let source {
                tabManager.unpinWorkspaceForSurfaceRealization(source.id)
                tabManager.closeWorkspace(source)
            }
            let listener = server
            Task { await listener?.stop() }
            source = nil; server = nil; host = nil; project = nil; teamName = nil
        }
        let viewer = project.flatMap { RemoteLiveProject.workspaceForTesting(projectID: $0.projectID) }
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
        return .ok(["starting": starting, "failure": failure ?? "",
                    "source_panels": source?.panels.count ?? 0,
                    "viewer_panels": viewer?.panels.count ?? 0,
                    "matching_transcripts": matching, "input_echoes": echoes,
                    "viewer_id": viewer?.id.uuidString ?? "",
                    "source_id": source?.id.uuidString ?? "",
                    "source_agent_ids": source?.panels.values.compactMap { ($0 as? AgentPanel)?.id.uuidString }.sorted() ?? [],
                    "viewer_agent_ids": viewer?.remoteAgentPaneSessions.keys.map(\.uuidString).sorted() ?? [],
                    "active_viewer_agents": viewer?.remoteAgentPaneSessions.keys.filter { viewer?.peerAgentPanelIsLive($0) == true }.count ?? 0,
                    "local_team_count": TeamOrchestrator.shared.teams.count])
    }
}
#endif
