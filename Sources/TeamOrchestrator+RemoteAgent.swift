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
        var spawnedSurface = false
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
                spawnedSurface = chosen != nil
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
            remoteSurfaceSpawned: spawnedSurface,
            hostKey: hostKey
        )
        guard adoptAgentMember(member, teamName: teamName) else {
            throw RemoteAgentError.duplicateName(agentName)
        }
        // Remembered on success rather than on typing, so a path that turned
        // out to be wrong is not the one offered next time.
        RemoteProjectPaths.shared.remember(
            host: hostKey,
            localRoot: team.workingDirectory,
            path: workingDirectory
        )
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

    /// Stop what this agent left running on the other machine, then close its
    /// pane.
    ///
    /// Detaching closes the local pane, which is the whole story for a local
    /// agent — the process lives in that pane and dies with it. A remote pane
    /// is a window onto a process on another machine, so closing it reaches
    /// nothing: the CLI kept running on the peer, still holding a session,
    /// still occupying the surface, and the next agent added to that host
    /// quietly landed in the abandoned one's shell.
    ///
    /// The keystrokes have to outlive the window they travel through, which is
    /// why this owns the close rather than racing it. Then the surface, but
    /// only one this side asked the host to make — a shell the operator
    /// published is theirs, and we merely borrowed it.
    @MainActor
    func releaseRemoteAgent(_ agent: AgentMember, closing workspace: Workspace?) {
        let hostSockPath = agent.hostKey
            .flatMap { key in RemoteHostStore.shared.sortedHosts.first { $0.id == key } }
            .map(\.activeSockPath)
            .flatMap { $0.isEmpty ? nil : $0 }
        let panelId = agent.panelId
        let panel = panelId.flatMap { id -> TerminalPanel? in
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: id),
                  let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId })
            else { return nil }
            return ws.terminalPanel(for: id)
        }

        if let panel {
            TerminalController.shared.sendNamedKeyWithRetry(on: panel.surface, keyName: "ctrl-c") { _, _ in }
        }
        let surfaceID = agent.remoteSurfaceSpawned ? agent.remoteSurfaceID : nil
        let quit = Self.quitCommand(cli: agent.cli)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let panel {
                // Its own word for quitting, typed. Ctrl+C and Ctrl+D both
                // reach the remote pane and both are ignored there — measured,
                // twice — because an agent CLI treats them as editing keys,
                // not as the door.
                // Text and Return separately, with room between them. The
                // inline form puts 5ms between the two, which is generous for
                // a local PTY and nothing at all for a pane whose composer is
                // on another machine: the Return arrives before the word does
                // and submits an empty prompt. Measured — `/exit` typed this
                // way ends the CLI, the same string sent inline does not.
                _ = panel.surface.sendIMEText(quit, withReturn: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    TerminalController.shared.sendNamedKeyWithRetry(
                        on: panel.surface, keyName: "return"
                    ) { _, _ in }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                if let workspace, let panelId {
                    _ = workspace.closePanel(panelId, force: true)
                }
                guard let surfaceID, let hostSockPath else { return }
                Task.detached {
                    guard let conn = try? await PeerRelaySession.connect(hostSockPath: hostSockPath) else { return }
                    try? await conn.session.requestClosePane(paneID: surfaceID)
                    await conn.cancel()
                }
            }
        }
    }

    /// Create a team from composed rows, wherever they run.
    ///
    /// The one place that turns `TeamAgentRow`s into a live team, because the
    /// two callers that need it — the New Agent Team sheet and New Project —
    /// would otherwise each carry their own copy of the same three subtleties:
    /// composing the runbook instructions, holding remote members out of
    /// `createTeam`, and attaching them once the workspace and team exist.
    /// The first duplicate of this cost a workspace per project earlier today.
    @discardableResult
    func createTeam(
        named teamName: String,
        rows: [TeamAgentRow],
        workingDirectory: String,
        leaderMode: String,
        leaderModel: String = "sonnet",
        worktreeMode: String = "off",
        executionMode: String = "pane",
        resumeSessionId: String? = nil,
        pairMode: String = "none",
        pairModel: String = "",
        pairSpec: String = "",
        tabManager: TabManager
    ) -> Team? {
        // A remote pane is a peer surface pulled into this workspace, so it
        // needs the workspace and the team to already exist. Spawning these
        // locally and moving them would start each CLI on the wrong machine
        // and then close it.
        let remoteRows = rows.filter { $0.hostKey != nil }
        let localTuples = rows.filter { $0.hostKey == nil }.map { row in
            let customInstructions = row.customInstructions == row.preset.instructions
                ? ""
                : row.customInstructions
            let effectiveInstructions = AgentRunbookService.shared.composeInstructions(
                roleName: row.preset.name,
                presetInstructions: row.preset.instructions,
                customInstructions: customInstructions,
                workingDirectory: workingDirectory,
                mode: .digest
            )
            return (
                name: row.preset.name,
                cli: row.preset.cli,
                model: row.preset.model,
                agentType: row.preset.name,
                color: row.preset.color,
                // The custom instructions are composed into `instructions`
                // above; passing them again would append the same spec twice.
                instructions: effectiveInstructions,
                customInstructions: ""
            )
        }

        guard let team = createTeam(
            name: teamName,
            agents: localTuples,
            workingDirectory: workingDirectory,
            leaderSessionId: UUID().uuidString,
            leaderMode: leaderMode,
            leaderModel: leaderModel,
            pairMode: pairMode,
            pairModel: pairModel,
            pairSpec: pairSpec,
            resumeSessionId: resumeSessionId,
            worktreeMode: worktreeMode,
            executionMode: executionMode,
            tabManager: tabManager
        ) else { return nil }

        for row in remoteRows {
            guard let hostKey = row.hostKey else { continue }
            let directory = row.hostDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                do {
                    _ = try await self.attachRemoteAgent(
                        teamName: team.id,
                        agentName: row.preset.name,
                        hostKey: hostKey,
                        // Its own path when one was given; the team's
                        // otherwise, which is right when both machines lay the
                        // project out the same way and visibly wrong when not.
                        workingDirectory: directory.isEmpty ? workingDirectory : directory,
                        agentType: row.preset.name,
                        model: row.preset.model,
                        cli: row.preset.cli
                    )
                } catch {
                    RemoteWorkLog.info(
                        "Could not start \(row.preset.name) on \(hostKey): \(error)"
                    )
                }
            }
        }
        return team
    }

    /// Say that work on this host has stopped, because the host has.
    ///
    /// An unreachable machine leaves its tasks looking exactly like tasks
    /// nobody has got to yet: `assigned`, no reason, no end. The agent reads
    /// `idle` too, which is worse than wrong — idle means available. Someone
    /// looking at the board sees a healthy team with one task that never
    /// moves, and nothing anywhere connects that to the machine having gone
    /// away.
    ///
    /// Blocking is not a guess about the work. The agent may well have
    /// finished; the point is that this side can no longer find out, and a
    /// task that cannot be observed is not in progress in any useful sense.
    /// Reconnecting is what resolves it, and the reason says so.
    @MainActor
    func markRemoteAgentsUnreachable(hostKey: String, reason: String) {
        for team in teams.values {
            let names = Set(team.agents.filter { $0.hostKey == hostKey }.map(\.name))
            guard !names.isEmpty else { continue }
            for task in TeamDataStore.shared.listTasks(teamName: team.id)
            where names.contains(task.assignee ?? "") && Self.unfinishedStatuses.contains(task.status) {
                _ = TeamDataStore.shared.updateTask(
                    teamName: team.id,
                    taskId: task.id,
                    status: "blocked",
                    blockedReason: "\(hostKey) \(reason) — reconnect the host to pick this up again"
                )
            }
        }
    }

    /// Statuses that mean the work has not reached an end. A task already
    /// finished or already blocked is left alone: the first is history and the
    /// second already says something more specific than this would.
    private static let unfinishedStatuses: Set<String> = [
        "pending", "queued", "assigned", "in_progress", "reassigned",
    ]

    /// Tell every agent running on a peer to quit, because this app is.
    ///
    /// A local agent dies with the app: its process lives in a pane, and the
    /// pane goes when the process hosting it does. An agent on another machine
    /// does not — it keeps running, holding its session, with nobody left who
    /// knows it exists. Teams do not survive a restart, so nothing would ever
    /// come back for it, and the next agent added to that host would find the
    /// surface occupied by a ghost. Every restart would leave one more.
    ///
    /// Returns whether anything was asked to quit, so the caller knows whether
    /// it is worth delaying the quit at all.
    @MainActor
    @discardableResult
    func releaseAllRemoteAgentsForQuit() -> Bool {
        let remote = teams.values.flatMap(\.agents).filter { $0.hostKey != nil }
        guard !remote.isEmpty else { return false }
        for agent in remote {
            guard let panelId = agent.panelId,
                  let located = AppDelegate.shared?.locateSurface(surfaceId: panelId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let panel = workspace.terminalPanel(for: panelId) else { continue }
            _ = panel.surface.sendIMEText(Self.quitCommand(cli: agent.cli), withReturn: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitReturnGap) {
                TerminalController.shared.sendNamedKeyWithRetry(
                    on: panel.surface, keyName: "return"
                ) { _, _ in }
            }
        }
        return true
    }

    /// Room for the quit command to reach the far machine before the Return
    /// chasing it. Same reason as every other remote send, on a shorter fuse
    /// because a quit is waiting on it.
    static let quitReturnGap: TimeInterval = 1.0

    /// How long the app will wait for those quits before leaving anyway. A
    /// tidy exit is worth a second or two; it is not worth a quit that hangs
    /// because a peer stopped answering.
    static let quitGrace: TimeInterval = 2.5

    /// How to ask a CLI to quit.
    ///
    /// Typed rather than signalled: Ctrl+C and Ctrl+D both arrive at the pane
    /// and neither ends an agent CLI, which reads them as editing keys —
    /// measured on a live remote pane, twice, before believing it.
    ///
    /// Every CLI term-mesh runs spells it `/exit` today. This takes the CLI
    /// name so the day one of them does not, the answer has a place to live
    /// rather than a literal needing to be found.
    static func quitCommand(cli: String) -> String { "/exit" }

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
        // `mkdir -p` before `cd`, because a project on another machine has
        // usually not been made there yet. Without it `cd` failed, the `&&`
        // short-circuited, and the CLI never started — leaving a pane that
        // looked attached and was a dead shell, with the reason one scroll up.
        // Idempotent, so an existing directory costs nothing.
        let enter = "mkdir -p '\(quotedDir)' && cd '\(quotedDir)'"
        switch cli {
        case "codex":
            return "\(enter) && codex --model \(model)"
        default:
            return "\(enter) && claude --model \(model) --dangerously-skip-permissions"
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
