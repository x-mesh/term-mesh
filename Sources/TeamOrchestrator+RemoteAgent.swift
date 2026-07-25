import Foundation

// An agent that runs on another machine, in a pane you can watch.
//
// The coordinator can already place a whole project's work on whichever host
// happens to have it, which is the right answer when any machine will do. It
// is the wrong answer when a specific one is the point: tests want the Mac,
// a build may want the Linux box, and a team is often both at once — a leader
// here and one member over there.
//
// That is a property of the member, not of the team, so it is attached one
// agent at a time. The pane is local: a peer surface is attached into this
// workspace, so `panelId` still addresses it and everything keyed on that —
// delegating, reading the reply off the scrollback, revealing it — works
// without knowing the agent is somewhere else.

extension TeamOrchestrator {
    enum RemoteAgentError: Error, CustomStringConvertible {
        case teamNotFound(String)
        case hostNotFound(String)
        case hostNotConnected(String)
        case noAttachableSurface(String)
        case workspaceGone
        case paneCreationFailed
        case duplicateName(String)

        var description: String {
            switch self {
            case .teamNotFound(let name): return "no team named \(name)"
            case .hostNotFound(let key): return "no host \(key)"
            case .hostNotConnected(let name): return "\(name) is not connected"
            case .noAttachableSurface(let name): return "\(name) has no free surface to attach"
            case .workspaceGone: return "the team's workspace is gone"
            case .paneCreationFailed: return "could not open the remote pane"
            case .duplicateName(let name): return "the team already has an agent named \(name)"
            }
        }
    }

    /// Attach an agent to this team that runs on `hostKey`.
    ///
    /// The remote CLI is started by typing into the attached shell rather than
    /// spawned with an environment, because that is all an attached surface
    /// offers — the host published the shell, this side did not create it. So
    /// the agent gets no `TERMMESH_SOCKET` and cannot call `tm-agent` back
    /// here. It does not need to: the reply header it prints is read off the
    /// pane by the same poller that watches local agents, and that is what
    /// closes the task.
    @discardableResult
    func attachRemoteAgent(
        teamName: String,
        agentName: String,
        hostKey: String,
        workingDirectory: String,
        agentType: String = "executor",
        model: String = "sonnet",
        cli: String = "claude"
    ) async throws -> AgentMember {
        guard let team = teams[teamName] else { throw RemoteAgentError.teamNotFound(teamName) }
        if team.agents.contains(where: { $0.name == agentName }) {
            throw RemoteAgentError.duplicateName(agentName)
        }
        guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }) else {
            throw RemoteAgentError.hostNotFound(hostKey)
        }
        guard host.isConnected else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }) else {
            throw RemoteAgentError.workspaceGone
        }

        // Split off the last agent's pane, or the leader's — the same shape a
        // local `add` produces, so a mixed team does not look different from
        // one that happens to run entirely here.
        let splitFrom = team.agents.last?.panelId ?? team.leaderPanelId

        let registry = PeerPaneHostRegistry.shared
        let lease = try await registry.acquire(host.paneHostSpec)
        let panel: TerminalPanel
        let attachedSurfaceID: Data
        do {
            let surfaces = try await PeerPaneSession.listSurfaces(on: lease)
            // A host publishes a fixed roster of surfaces and each can be
            // attached once, so a second agent on the same machine finds
            // nothing free — usually the first one took the only shell. Ask
            // for another rather than refusing: a host that can run one agent
            // can run two, and the roster is a publishing detail, not a
            // statement about capacity.
            // Surfaces this app's agents already sit in. The host cannot tell
            // us — a second attach is legal, so a busy surface looks exactly
            // like a free one — but every one of them was attached from here.
            let taken = Set(
                teams.values
                    .flatMap(\.agents)
                    .filter { $0.hostKey == hostKey }
                    .compactMap(\.remoteSurfaceID)
            )
            var chosen = surfaces.first { $0.attachable && !taken.contains($0.surfaceID) }
            if chosen == nil, let source = surfaces.first?.surfaceID {
                chosen = try await PeerPaneSession.spawnSurface(on: lease, splitting: source)
            }
            guard let chosen else {
                registry.release(lease)
                throw RemoteAgentError.noAttachableSurface(host.displayName)
            }
            let session = try await PeerPaneSession.attach(
                lease: lease,
                surface: chosen,
                title: agentName,
                spec: host.paneHostSpec
            )
            registry.release(lease)
            guard let opened = workspace.openRemotePane(
                session: session,
                orientation: team.agents.isEmpty ? .horizontal : .vertical,
                focus: false,
                from: splitFrom
            ) else {
                session.teardown()
                throw RemoteAgentError.paneCreationFailed
            }
            panel = opened
            attachedSurfaceID = chosen.surfaceID
        } catch {
            registry.release(lease)
            throw error
        }

        let colorList = ["green", "blue", "yellow", "magenta", "cyan", "red"]
        let agentColor = colorList[team.agents.count % colorList.count]
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "\(Self.colorEmoji(agentColor)) \(agentName) @\(host.displayName)"
        )

        let member = AgentMember(
            id: "\(agentName)@\(teamName)",
            name: agentName,
            teamName: teamName,
            cli: cli,
            launchCommand: cli,
            model: model,
            agentType: agentType,
            color: agentColor,
            instructions: "",
            workspaceId: workspace.id,
            panelId: panel.id,
            createdAt: Date(),
            remoteSurfaceID: attachedSurfaceID,
            hostKey: hostKey
        )
        guard adoptAgentMember(member, teamName: teamName) else {
            throw RemoteAgentError.duplicateName(agentName)
        }
        AutoReplyPoller.shared.ensureRunning()

        // Start the CLI once the remote shell is actually reading. The same
        // race a local pane has, for the same reason: text that arrives while
        // a shell is still coming up lands in a buffer nobody submits.
        Task { @MainActor in
            await Self.waitForPaneToStart(panelId: panel.id)
            let command = Self.remoteAgentCommand(
                cli: cli,
                model: model,
                agentName: agentName,
                teamName: teamName,
                workingDirectory: workingDirectory
            )
            _ = self.sendToAgentByPanel(
                teamName: teamName,
                panelId: panel.id,
                workspaceId: workspace.id,
                text: command,
                tabManager: tabManager,
                withReturn: true,
                recordPendingReturnFor: agentName
            )
        }

        return member
    }

    /// The one line typed into the remote shell to become an agent.
    ///
    /// Deliberately bare: the binary is resolved by the remote PATH rather
    /// than a path captured here, because the two machines do not agree on
    /// where anything lives.
    static func remoteAgentCommand(
        cli: String,
        model: String,
        agentName: String,
        teamName: String,
        workingDirectory: String
    ) -> String {
        let quotedDir = workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
        switch cli {
        case "codex":
            return "cd '\(quotedDir)' && codex --model \(model)"
        default:
            return "cd '\(quotedDir)' && claude --model \(model) --dangerously-skip-permissions"
        }
    }

    /// Wait for a freshly attached pane to stop painting before typing into it.
    @MainActor
    static func waitForPaneToStart(panelId: UUID, timeout: TimeInterval = 25) async {
        AutoReplyPoller.shared.ensureRunning()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if AutoReplyPoller.shared.isPaneActive(panelId: panelId) { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
}
