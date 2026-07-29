import Bonsplit
import Foundation
import PeerProto

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
    struct PeerShellCleanupItem: Identifiable, Equatable {
        enum State: Equatable {
            case inUse
            case managedOrphan
            case missingDirectory
            case unclaimed
        }

        let id: Data
        let title: String
        let workingDirectory: String
        let isBusy: Bool
        let state: State

        var idLabel: String { id.prefix(4).map { String(format: "%02x", $0) }.joined() }
    }

    enum RemoteAgentError: Error, CustomStringConvertible {
        case teamNotFound(String)
        case hostNotFound(String)
        case hostNotConnected(String)
        case noAttachableSurface(String)
        case noFreshSurface(String)
        case workspaceGone
        case paneCreationFailed
        case duplicateName(String)
        case duplicateInstance(String)
        case cliUnavailable(String, String)
        case promptStagingFailed(String)
        case projectWorkspaceUnavailable(String)
        case partialShellClose(closed: Int, failed: Int, reason: String)

        var description: String {
            switch self {
            case .teamNotFound(let name): return "no team named \(name)"
            case .hostNotFound(let key): return "no host \(key)"
            case .hostNotConnected(let name): return "\(name) is not connected"
            case .noAttachableSurface(let name): return "\(name) has no free surface to attach"
            case .noFreshSurface(let name): return "\(name) could not create a fresh leader surface"
            case .workspaceGone: return "the team's workspace is gone"
            case .paneCreationFailed: return "could not open the remote pane"
            case .duplicateName(let name): return "the team already has an agent named \(name)"
            case .duplicateInstance(let id): return "the team already has agent instance \(id)"
            case .cliUnavailable(let cli, let host):
                return "\(cli) is not installed on \(host)"
            case .promptStagingFailed(let host):
                return "could not stage the leader prompt on \(host)"
            case .projectWorkspaceUnavailable(let host):
                return "could not prepare the project workspace on \(host)"
            case .partialShellClose(let closed, let failed, let reason):
                return "closed \(closed) shell(s); \(failed) refused — \(reason)"
            }
        }
    }

    private struct RemoteSurfacePlacement {
        let sourceID: Data
        let isDedicated: Bool
        /// A dedicated workspace's first shell is guaranteed to be clean, so
        /// the first project member can consume it directly. Later members
        /// split an existing project surface and stay in the same workspace.
        let useSourceDirectly: Bool
    }

    static func remoteProjectWorkspaceTitle(teamName: String) -> String {
        let singleLine = teamName
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Project · \(String(singleLine.prefix(72)))"
    }

    private func remoteSurfacePlacement(
        teamName: String,
        host: HostEntry,
        fallbackSourceID: Data?
    ) async throws -> RemoteSurfacePlacement? {
        guard let team = teams[teamName],
              team.usesDedicatedRemoteWorkspaces
        else {
            return fallbackSourceID.map {
                RemoteSurfacePlacement(
                    sourceID: $0,
                    isDedicated: false,
                    useSourceDirectly: false
                )
            }
        }
        guard !host.activeSockPath.isEmpty else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }

        let connection = try await PeerRelaySession.connect(hostSockPath: host.activeSockPath)
        guard connection.hostCapabilities.has(PeerCapability.workspaceLifecycleV1) else {
            await connection.cancel()
            return fallbackSourceID.map {
                RemoteSurfacePlacement(
                    sourceID: $0,
                    isDedicated: false,
                    useSourceDirectly: false
                )
            }
        }
        do {
            var workspaceID = team.remoteWorkspaceIDs[host.id]
            var createdWorkspace = false
            if workspaceID == nil {
                workspaceID = try await connection.session.createWorkspace(
                    title: Self.remoteProjectWorkspaceTitle(teamName: teamName)
                )
                createdWorkspace = true
                if let workspaceID {
                    recordRemoteWorkspaceID(
                        teamName: teamName,
                        hostKey: host.id,
                        workspaceID: workspaceID
                    )
                }
            }
            guard let workspaceID else {
                await connection.cancel()
                throw RemoteAgentError.projectWorkspaceUnavailable(host.displayName)
            }

            let managedIDs = Set(
                ManagedPeerSurfaceStore.shared.records(hostKey: host.id)
                    .filter { $0.teamName == teamName }
                    .compactMap(\.surfaceID)
            )
            var requestedSeed = false
            for _ in 0..<15 {
                let workspaces = try await connection.session.listWorkspaces()
                if let workspace = workspaces.first(where: { $0.workspaceID == workspaceID }),
                   let sourceID = peerPaneSummaries(workspace.hasLayout ? workspace.layout : nil)
                    .map(\.id)
                    .first {
                    let hasManagedProjectSurface = managedIDs.contains(sourceID)
                    await connection.cancel()
                    return RemoteSurfacePlacement(
                        sourceID: sourceID,
                        isDedicated: true,
                        useSourceDirectly: createdWorkspace || !hasManagedProjectSurface
                    )
                }
                if !requestedSeed {
                    try await connection.session.requestNewTab(workspaceID: workspaceID)
                    requestedSeed = true
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            await connection.cancel()
            throw RemoteAgentError.projectWorkspaceUnavailable(host.displayName)
        } catch {
            await connection.cancel()
            throw error
        }
    }

    func inspectPeerShells(
        host: HostEntry,
        workspaceID: Data? = nil
    ) async throws -> [PeerShellCleanupItem] {
        let workspaces = workspaceID.map { id in
            host.workspaces.filter { $0.id == id }
        } ?? host.workspaces
        let panes = Dictionary(
            workspaces.flatMap(\.panes).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let claimed = claimedRemoteSurfaceIDs(host: host)
        let managed = Dictionary(
            ManagedPeerSurfaceStore.shared.records(hostKey: host.id).compactMap { record in
                record.surfaceID.map { ($0, record) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var seenPaths = Set<String>()
        let indexedPaths = panes.values
            .compactMap(\.workingDirectoryPath)
            .filter { !$0.isEmpty && seenPaths.insert($0).inserted }
        var missingPaths = Set<String>()
        if let sshTarget = host.sshTarget, !sshTarget.isEmpty, !indexedPaths.isEmpty {
            let checks = indexedPaths.enumerated().map { index, path in
                "if [ ! -d \(Self.shellQuoted(path)) ]; "
                    + "then printf 'MISSING \(index)\\n'; fi"
            }
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: checks.joined(separator: "\n") + "\ntrue",
                timeoutSeconds: 20
            )
            for line in output.split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count == 2, fields[0] == "MISSING",
                      let index = Int(fields[1]), indexedPaths.indices.contains(index)
                else { continue }
                missingPaths.insert(indexedPaths[index])
            }
        }

        return panes.values.map { pane in
            let path = pane.workingDirectoryPath ?? ""
            let state: PeerShellCleanupItem.State
            if claimed.contains(pane.id) {
                state = .inUse
            } else if managed[pane.id] != nil {
                state = .managedOrphan
            } else if !path.isEmpty && missingPaths.contains(path) {
                state = .missingDirectory
            } else {
                state = .unclaimed
            }
            return PeerShellCleanupItem(
                id: pane.id,
                title: pane.title,
                workingDirectory: path,
                isBusy: pane.isBusy,
                state: state
            )
        }
        .sorted {
            if $0.state != $1.state {
                return cleanupStateOrder($0.state) < cleanupStateOrder($1.state)
            }
            return $0.workingDirectory.localizedStandardCompare($1.workingDirectory)
                == .orderedAscending
        }
    }

    func closePeerShells(host: HostEntry, surfaceIDs: Set<Data>) async throws -> Int {
        guard !host.activeSockPath.isEmpty else {
            throw RemoteAgentError.hostNotConnected(host.displayName)
        }
        let protected = claimedRemoteSurfaceIDs(host: host)
        let targets = surfaceIDs.subtracting(protected)
        guard !targets.isEmpty else { return 0 }

        // Prefer a connection the host has already granted. Opening one here
        // is what made this sweep unusable: the host allows a fixed number of
        // concurrent peer connections and every attached pane holds one, so a
        // host with enough leftover shells to be worth sweeping has no slot
        // left to grant, and the dial came back as an EOF mid-handshake.
        //
        // The donor must not be one of the shells being closed. Borrowing a
        // target's own session sends its own death down its own connection:
        // the host drops the PTY without telling the client, so the local pane
        // stays attached to a stream that will never produce another byte, and
        // the sweep counts it as a clean close.
        var borrowed = borrowedRelaySession(
            hostKey: host.paneHostSpec.hostKey, excluding: targets
        )
        var opened: PeerRelayConnection?
        var dialFailed = false
        defer { if let opened { Task { await opened.cancel() } } }

        // Dial only once the borrowed session is gone. That death is also what
        // frees the slot this path was avoiding, so the sweep can finish on its
        // own connection rather than failing every remaining target.
        func send(_ paneID: Data) async throws {
            if let session = borrowed {
                if try await session.requestClosePane(paneID) { return }
                borrowed = nil
            }
            if opened == nil {
                guard !dialFailed else {
                    throw RemoteAgentError.hostNotConnected(host.displayName)
                }
                do {
                    opened = try await PeerRelaySession.connect(
                        hostSockPath: host.activeSockPath
                    )
                } catch {
                    // Remember it: without this every remaining target pays for
                    // the same refused dial.
                    dialFailed = true
                    throw error
                }
            }
            try await opened?.session.requestClosePane(paneID: paneID)
        }
        return try await Self.sweepClose(targets: targets, send: send) { surfaceID in
            ManagedPeerSurfaceStore.shared.forget(hostKey: host.id, surfaceID: surfaceID)
        }
    }

    /// Attempt every target, count what actually closed, and report the
    /// shortfall as one error.
    ///
    /// One shell refusing to close must not strand the ones behind it. A sweep
    /// here is routinely dozens long, and aborting on the first failure left
    /// the caller no way to tell "nothing closed" from "most of them did" — so
    /// every target is attempted and the count comes with the failure.
    ///
    /// Split from `closePeerShells` because the counting is the part worth
    /// testing and the rest of that function is session lookup: which
    /// connection to borrow, when to dial. Those need a live host; this does
    /// not.
    static func sweepClose(
        targets: Set<Data>,
        send: (Data) async throws -> Void,
        onClosed: (Data) -> Void = { _ in }
    ) async throws -> Int {
        var closed = 0
        var firstFailure: Error?
        for surfaceID in targets {
            do {
                try await send(surfaceID)
                onClosed(surfaceID)
                closed += 1
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            throw RemoteAgentError.partialShellClose(
                closed: closed,
                failed: targets.count - closed,
                reason: String(describing: firstFailure)
            )
        }
        return closed
    }

    /// Every open pane whose shell runs on `hostKey`.
    ///
    /// Shared by the two callers that need to know which of the host's
    /// surfaces this app is currently holding — one to protect them, one to
    /// borrow a connection from them.
    private func peerPaneSessions(hostKey: PeerPaneHostKey) -> [PeerPaneSession] {
        guard let app = AppDelegate.shared else { return [] }
        var result: [PeerPaneSession] = []
        for context in app.mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values {
                    guard let terminal = panel as? TerminalPanel,
                          let session = terminal.peerPaneSession,
                          !session.isTorndown,
                          session.lease.key == hostKey
                    else { continue }
                    result.append(session)
                }
            }
        }
        return result
    }

    /// A live relay session on `hostKey`, to carry control requests that are
    /// about the host rather than about one pane. Control frames are
    /// fire-and-forget and carry their own pane id, so which pane's session
    /// delivers them does not matter — only that the host already granted it,
    /// and that it is not itself one of the panes being acted on.
    private func borrowedRelaySession(
        hostKey: PeerPaneHostKey,
        excluding targets: Set<Data>
    ) -> PeerRelaySession? {
        peerPaneSessions(hostKey: hostKey)
            .first { !targets.contains($0.originSurface.surfaceID) }?
            .relaySession
    }

    /// Surfaces on `host` that this app is already using, which a cleanup
    /// sweep must never close.
    ///
    /// Three kinds, equally in use: a team agent's surface, a team leader's,
    /// and — the one this originally missed — any remote pane the user simply
    /// has open. The cleanup sheet promises "tracked shells are protected",
    /// and a pane sitting on screen is the most visible kind of tracked there
    /// is; leaving it out bucketed it as `unclaimed`, which Select All then
    /// swept up.
    private func claimedRemoteSurfaceIDs(host: HostEntry) -> Set<Data> {
        let hostKey = host.id
        var result = Set(
            teams.values
                .flatMap(\.agents)
                .filter { $0.hostKey == hostKey }
                .compactMap(\.remoteSurfaceID)
        )
        for team in teams.values {
            guard team.leaderEndpoint == .peer(hostKey: hostKey),
                  let located = AppDelegate.shared?.locateSurface(surfaceId: team.leaderPanelId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let session = workspace.terminalPanel(for: team.leaderPanelId)?.peerPaneSession
            else { continue }
            result.insert(session.originSurface.surfaceID)
        }
        result.formUnion(
            peerPaneSessions(hostKey: host.paneHostSpec.hostKey)
                .map(\.originSurface.surfaceID)
        )
        return result
    }

    private func cleanupStateOrder(_ state: PeerShellCleanupItem.State) -> Int {
        switch state {
        case .managedOrphan: return 0
        case .missingDirectory: return 1
        case .unclaimed: return 2
        case .inUse: return 3
        }
    }

    /// Replace the inert local anchor with a pane whose process runs on
    /// `hostKey`. The remote process receives only an expiring scoped
    /// grant and its own daemon socket; the viewer's TERMMESH_SOCKET is never
    /// copied across the peer boundary.
    @MainActor
    func attachRemoteLeader(
        teamName: String,
        hostKey: String,
        workingDirectory: String,
        cli: String,
        model: String,
        systemPrompt: String? = nil
    ) async throws {
        guard let team = teams[teamName] else { throw RemoteAgentError.teamNotFound(teamName) }
        guard let teamUUID = team.teamUuid else { throw RemoteAgentError.teamNotFound(teamName) }
        guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }) else {
            throw RemoteAgentError.hostNotFound(hostKey)
        }
        guard host.isConnected else { throw RemoteAgentError.hostNotConnected(host.displayName) }
        let promptFile = systemPrompt.map { _ in
            "/tmp/term-mesh-leader-prompt-\(teamUUID).txt"
        }
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: team.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId }) else {
            throw RemoteAgentError.workspaceGone
        }

        let lease = try await PeerPaneHostRegistry.shared.acquire(host.paneHostSpec)
        let session: PeerPaneSession
        let spawnedSurfaceID: Data
        do {
            let surfaces = try await PeerPaneSession.listSurfaces(on: lease)
            // `attachable` only means another viewer may attach. It says
            // nothing about what the surface is running. Reusing one here can
            // paste the bootstrap grant into an already-running Claude pane,
            // where Claude answers the shell command as prose and the new
            // project silently inherits the old relay.
            //
            // Reserve a fresh shell exactly as remote agents do. Falling back
            // to an existing surface would recreate the credential leak this
            // path is preventing, so an old/full host must fail visibly.
            guard let placement = try await remoteSurfacePlacement(
                teamName: teamName,
                host: host,
                fallbackSourceID: surfaces.first?.surfaceID
            ) else {
                throw RemoteAgentError.noFreshSurface(host.displayName)
            }
            let chosen: Termmesh_Peer_V1_SurfaceInfo?
            if placement.useSourceDirectly {
                let refreshed = try await PeerPaneSession.listSurfaces(on: lease)
                chosen = refreshed.first { $0.surfaceID == placement.sourceID }
            } else {
                chosen = try await PeerPaneSession.spawnSurface(
                    on: lease,
                    splitting: placement.sourceID
                )
            }
            guard let chosen else {
                throw RemoteAgentError.noFreshSurface(host.displayName)
            }
            spawnedSurfaceID = chosen.surfaceID
            ManagedPeerSurfaceStore.shared.remember(
                hostKey: hostKey,
                surfaceID: chosen.surfaceID,
                teamName: teamName,
                role: "leader",
                workingDirectory: workingDirectory
            )
            session = try await PeerPaneSession.attach(
                lease: lease,
                surface: chosen,
                title: "Leader",
                spec: host.paneHostSpec
            )
        } catch {
            PeerPaneHostRegistry.shared.release(lease)
            throw error
        }
        PeerPaneHostRegistry.shared.release(lease)

        func abandonSpawnedLeader(panelID: UUID? = nil) async {
            if let panelID {
                _ = workspace.closePanel(panelID, force: true)
            } else {
                session.teardown()
            }
            await Self.closeManagedRemoteSurface(
                hostSockPath: host.activeSockPath,
                hostKey: hostKey,
                surfaceID: spawnedSurfaceID
            )
            if let promptFile {
                await Self.removeRemoteLeaderPrompt(host: host, promptFile: promptFile)
            }
        }

        do {
            try await Self.prepareRemoteLeader(
                cli: cli,
                host: host,
                systemPrompt: systemPrompt,
                promptFile: promptFile
            )
        } catch {
            await abandonSpawnedLeader()
            throw error
        }

        var bootstrap = Termmesh_Peer_V1_TeamLeaderBootstrapRequest()
        bootstrap.projectID = "name:\(teamName)"
        bootstrap.leaderPlacement = .peer
        var requestUUID = UUID().uuid
        bootstrap.requestID = withUnsafeBytes(of: &requestUUID) { Data($0) }
        let grantResponse = await PeerTeamLeaderControlPlane.shared.bootstrap(
            bootstrap,
            encodedBytes: (try? bootstrap.serializedData().count) ?? 513,
            audiencePeerID: PeerIdentity.defaultPeerID()
        ) { projectID in
            projectID == "name:\(teamName)" ? teamUUID : nil
        }
        guard grantResponse.ok else {
            await abandonSpawnedLeader()
            throw RemoteAgentError.paneCreationFailed
        }

        guard let panel = workspace.replaceTerminalPaneWithRemote(
            panelId: team.leaderPanelId,
            session: session
        ) else {
            await abandonSpawnedLeader()
            throw RemoteAgentError.paneCreationFailed
        }
        replaceLeaderAnchorPanel(teamName: teamName, panelID: panel.id)
        panel.surface.resetTerminal()

        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "👑 Leader (\(cli.capitalized)) @\(host.displayName)"
        )
        await Self.waitForRemoteShell(session: session)

        // Do not paste the bearer grant into the terminal's visible scrollback
        // or history. First disable echo and history without any secret, then
        // submit the export+exec line while echo is disabled. The grant is
        // already short-lived and remains only in the launched CLI process.
        let prepare = Self.remoteLeaderPrepareCommand()
        guard await sendRemoteLeaderStage(
            teamName: teamName,
            panelId: panel.id,
            workspaceId: workspace.id,
            text: prepare,
            tabManager: tabManager
        ) else {
            await abandonSpawnedLeader(panelID: panel.id)
            throw RemoteAgentError.paneCreationFailed
        }

        let command = Self.remoteLeaderCommand(
            cli: cli,
            model: model,
            teamName: teamName,
            workingDirectory: workingDirectory,
            grant: grantResponse.grant,
            systemPromptFile: promptFile,
            environment: PeerHostEnvironment.stored(forHostKey: host.id)
        )
        let launched = await sendRemoteLeaderStage(
            teamName: teamName,
            panelId: panel.id,
            workspaceId: workspace.id,
            text: command,
            tabManager: tabManager
        )
        if !launched {
            // Best-effort recovery for the only stage that can leave a shell
            // with echo disabled. This command carries no credential either.
            _ = sendToAgentByPanel(
                teamName: teamName,
                panelId: panel.id,
                workspaceId: workspace.id,
                text: "stty echo",
                tabManager: tabManager,
                withReturn: true
            )
            await abandonSpawnedLeader(panelID: panel.id)
            throw RemoteAgentError.paneCreationFailed
        }

        markLeaderPolicyState(teamName: teamName, state: "injected")

        // Publish the peer endpoint only after the remote pane accepts its
        // launch command. Until then the same pane remains visibly pending,
        // without creating or removing a transient split.
        replaceLeaderEndpoint(
            teamName: teamName,
            panelID: panel.id,
            endpoint: .peer(hostKey: hostKey)
        )
    }

    private static func closeManagedRemoteSurface(
        hostSockPath: String,
        hostKey: String,
        surfaceID: Data
    ) async {
        guard !hostSockPath.isEmpty,
              let connection = try? await PeerRelaySession.connect(hostSockPath: hostSockPath)
        else { return }
        do {
            try await connection.session.requestClosePane(paneID: surfaceID)
            ManagedPeerSurfaceStore.shared.forget(hostKey: hostKey, surfaceID: surfaceID)
        } catch {
            // Keep the record. The host row's shell manager can retry it after
            // a reconnect instead of losing the only ownership evidence.
        }
        await connection.cancel()
    }

    private static func ensureRemoteCLIAvailable(cli: String, host: HostEntry) async throws {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return }
        guard AgentRolePreset.knownCLIs.contains(cli) else {
            throw RemoteAgentError.cliUnavailable(cli, host.displayName)
        }
        let marker = "__TERMMESH_CLI_AVAILABLE__"
        let probe = RemoteShellPath.prologue
            + "command -v \(shellQuoted(cli)) >/dev/null 2>&1 "
            + "&& printf %s \(shellQuoted(marker))"
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: "exec \"${SHELL:-/bin/sh}\" -lc \(shellQuoted(probe))",
                timeoutSeconds: 15
            )
            guard output.contains(marker) else {
                throw RemoteAgentError.cliUnavailable(cli, host.displayName)
            }
        } catch {
            throw RemoteAgentError.cliUnavailable(cli, host.displayName)
        }
    }

    /// Probe the CLI and stage the long Claude prompt in one SSH round trip.
    ///
    /// Sending the prompt through the attached terminal splits it into several
    /// bracketed-paste transactions. Their boundary bytes then become literal
    /// shell input inside the quoted prompt. A mode-0600 file keeps the launch
    /// line short; the shell reads and removes it before starting Claude.
    private static func prepareRemoteLeader(
        cli: String,
        host: HostEntry,
        systemPrompt: String?,
        promptFile: String?
    ) async throws {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
            if systemPrompt != nil {
                throw RemoteAgentError.promptStagingFailed(host.displayName)
            }
            return try await ensureRemoteCLIAvailable(cli: cli, host: host)
        }
        guard AgentRolePreset.knownCLIs.contains(cli) else {
            throw RemoteAgentError.cliUnavailable(cli, host.displayName)
        }
        let marker = "__TERMMESH_LEADER_READY__"
        let missing = "__TERMMESH_LEADER_CLI_MISSING__"
        var script = RemoteShellPath.prologue
            + "if ! command -v \(shellQuoted(cli)) >/dev/null 2>&1; "
            + "then printf %s \(shellQuoted(missing)); exit 0; fi"
        if let systemPrompt, let promptFile {
            script += "; umask 077; printf %s \(shellQuoted(systemPrompt)) > \(shellQuoted(promptFile))"
        }
        script += "; printf %s \(shellQuoted(marker))"
        do {
            let output = try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                script: script,
                timeoutSeconds: 20
            )
            if output.contains(missing) {
                throw RemoteAgentError.cliUnavailable(cli, host.displayName)
            }
            guard output.contains(marker) else {
                throw RemoteAgentError.promptStagingFailed(host.displayName)
            }
        } catch let error as RemoteAgentError {
            throw error
        } catch {
            if systemPrompt == nil {
                throw RemoteAgentError.cliUnavailable(cli, host.displayName)
            }
            throw RemoteAgentError.promptStagingFailed(host.displayName)
        }
    }

    private static func removeRemoteLeaderPrompt(host: HostEntry, promptFile: String) async {
        guard let sshTarget = host.sshTarget, !sshTarget.isEmpty else { return }
        _ = try? await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile,
            script: "rm -f -- \(shellQuoted(promptFile))",
            timeoutSeconds: 10
        )
    }

    /// Send one remote-leader bootstrap line and wait until both its paste and
    /// delayed Return have completed. `sendToAgentByPanel` returns when the
    /// paste is merely queued; starting the grant-bearing line at that point
    /// concatenates it with the preceding `stty -echo` line on a peer pane.
    /// The shell then runs `stty -echoexport ...; exec ...`: the CLI launches,
    /// but none of the scoped leader environment reaches it.
    @MainActor
    private func sendRemoteLeaderStage(
        teamName: String,
        panelId: UUID,
        workspaceId: UUID,
        text: String,
        tabManager: TabManager
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (Bool) -> Void = { delivered in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: delivered)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
                finish(false)
            }
            _ = sendToAgentByPanel(
                teamName: teamName,
                panelId: panelId,
                workspaceId: workspaceId,
                text: text,
                tabManager: tabManager,
                withReturn: true,
                completion: finish
            )
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

        // Fail before opening either kind of pane. Otherwise a missing remote
        // executable leaves a dead native bridge or a terminal that looks like
        // an agent but only contains "command not found".
        try await Self.ensureRemoteCLIAvailable(cli: cli, host: host)

        // The project's checkout convention applies to late joiners too.
        // Creation gives every agent an instance-tagged worktree; this path
        // used to drop a later agent straight into whatever directory was
        // typed — which the sheet prefills with the project PRIMARY, i.e.
        // the leader's own checkout. Two writers, one working tree: the
        // collision the worktrees exist to prevent, back through the side
        // door. When the requested directory is one this project created,
        // carve the newcomer its own station beside it instead. Anything
        // not recorded as the project's stays exactly as typed.
        var workingDirectory = workingDirectory
        if let isolated = await Self.prepareLateAgentCheckout(
            team: team,
            host: host,
            hostKey: hostKey,
            agentName: agentName,
            requestedDirectory: workingDirectory
        ) {
            workingDirectory = isolated.path
            var locations = team.remoteProjectLocations
            locations.append(.init(hostKey: hostKey, path: isolated.path))
            recordRemoteProjectLocations(
                teamName: teamName,
                locations: locations.sorted { ($0.hostKey, $0.path) < ($1.hostKey, $1.path) }
            )
        }

        // Use the same incremental grid growth as local `add`/`attach`.
        let placement = nextAgentSplitPlacement(team: team, workspace: workspace)

        // The leader remains a terminal, but members follow Agent Panes.
        // An SSH-backed relay can carry the structured process stream straight
        // into a local AgentPanel; a legacy direct-socket peer has no process
        // channel, so it keeps the terminal relay path below.
        if AgentPipeTransport.canHoldNatively(cli: cli),
           let sshTarget = host.sshTarget, !sshTarget.isEmpty {
            return try attachRemoteNativeAgent(
                team: team,
                workspace: workspace,
                tabManager: tabManager,
                host: host,
                sshTarget: sshTarget,
                splitFrom: placement.panelId,
                orientation: placement.orientation,
                agentName: agentName,
                workingDirectory: workingDirectory,
                agentType: agentType,
                model: model,
                cli: cli
            )
        }

        let registry = PeerPaneHostRegistry.shared
        let lease = try await registry.acquire(host.paneHostSpec)
        let panel: TerminalPanel
        let attachedSurfaceID: Data
        var spawnedSurface = false
        var spawnedSurfaceID: Data?
        do {
            let surfaces = try await PeerPaneSession.listSurfaces(on: lease)
            // Ask for a shell of our own rather than taking one of the
            // host's published surfaces.
            //
            // An agent's first act is to type a launch command, which only
            // means anything at a shell prompt. Whether a listed surface is at
            // one cannot be known from the listing: `SurfaceInfo` says a
            // surface is attachable, not that it is idle, and attaching twice
            // is legal — so a shell running someone else's agent looks exactly
            // like a free one. Reusing it types `mkdir … && claude …` into
            // that agent's prompt, which answers in prose about how it cannot
            // run shell commands. The pane looks attached and nothing started.
            //
            // Tracking which surfaces our own agents hold only covers the ones
            // this app knows about, and the ones that cause this are the
            // others: a previous run, a crash, another machine's term-mesh.
            // Spawning is the only way to be sure, and abandoned surfaces are
            // reaped by the host, so asking for one costs nothing lasting.
            let taken = Set(
                teams.values
                    .flatMap(\.agents)
                    .filter { $0.hostKey == hostKey }
                    .compactMap(\.remoteSurfaceID)
            )
            let remotePlacement = try await remoteSurfacePlacement(
                teamName: teamName,
                host: host,
                fallbackSourceID: surfaces.first?.surfaceID
            )
            let usesDedicatedWorkspace = remotePlacement?.isDedicated == true

            // Legacy/generic teams retain the best-effort free-surface
            // fallback. New Project is stricter: taking an arbitrary host
            // surface would put the member back under relay/default, exactly
            // the mixing the dedicated workspace exists to prevent.
            var chosen = usesDedicatedWorkspace
                ? nil
                : surfaces.first { $0.attachable && !taken.contains($0.surfaceID) }
            if let remotePlacement {
                if remotePlacement.useSourceDirectly {
                    let refreshed = try await PeerPaneSession.listSurfaces(on: lease)
                    chosen = refreshed.first { $0.surfaceID == remotePlacement.sourceID }
                } else if let fresh = try await PeerPaneSession.spawnSurface(
                    on: lease,
                    splitting: remotePlacement.sourceID
                ) {
                    chosen = fresh
                }
            }
            if let chosen,
               usesDedicatedWorkspace || !surfaces.contains(where: { $0.surfaceID == chosen.surfaceID }) {
                spawnedSurface = true
                spawnedSurfaceID = chosen.surfaceID
                ManagedPeerSurfaceStore.shared.remember(
                    hostKey: hostKey,
                    surfaceID: chosen.surfaceID,
                    teamName: teamName,
                    role: agentName,
                    workingDirectory: workingDirectory
                )
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
                orientation: placement.orientation,
                focus: false,
                from: placement.panelId
            ) else {
                session.teardown()
                throw RemoteAgentError.paneCreationFailed
            }
            panel = opened
            attachedSurfaceID = chosen.surfaceID
            // The shell being attached to may have been left in a TUI's modes
            // by whoever had it last — mouse reporting especially, which turns
            // every movement over this pane into a command at the far prompt.
            opened.surface.resetTerminal()
        } catch {
            registry.release(lease)
            if let spawnedSurfaceID {
                await Self.closeManagedRemoteSurface(
                    hostSockPath: host.activeSockPath,
                    hostKey: hostKey,
                    surfaceID: spawnedSurfaceID
                )
            }
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
            hostKey: hostKey,
            originalAgentWorkDir: workingDirectory
        )
        guard adoptAgentMember(member, teamName: teamName) else {
            _ = workspace.closePanel(panel.id, force: true)
            if let spawnedSurfaceID {
                await Self.closeManagedRemoteSurface(
                    hostSockPath: host.activeSockPath,
                    hostKey: hostKey,
                    surfaceID: spawnedSurfaceID
                )
            }
            throw RemoteAgentError.duplicateInstance(member.agentInstanceId)
        }
        scheduleAgentGridEqualization(workspace: workspace)
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
            if let session = panel.peerPaneSession {
                await Self.waitForRemoteShell(session: session)
            }
            let command = Self.remoteAgentCommand(
                cli: cli,
                model: model,
                agentName: agentName,
                teamName: teamName,
                workingDirectory: workingDirectory,
                environment: PeerHostEnvironment.stored(forHostKey: hostKey)
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

    @MainActor
    private func attachRemoteNativeAgent(
        team: Team,
        workspace: Workspace,
        tabManager _: TabManager,
        host: HostEntry,
        sshTarget: String,
        splitFrom: UUID,
        orientation: SplitOrientation,
        agentName: String,
        workingDirectory: String,
        agentType: String,
        model: String,
        cli: String
    ) throws -> AgentMember {
        let agentInstanceId = UUID().uuidString
        let bridge = AgentPipeTransport.needsBridge(cli: cli)
            ? AgentPipeTransport.bridgePath(workingDirectory: workingDirectory)
            : nil
        if AgentPipeTransport.needsBridge(cli: cli), bridge == nil {
            throw RemoteAgentError.paneCreationFailed
        }

        let color = Self.agentColor(
            forRole: agentType,
            taken: Set(team.agents.map(\.color))
        )
        let instructions = AgentRunbookService.shared.composeInstructions(
            roleName: agentType,
            presetInstructions: "",
            customInstructions: nil,
            workingDirectory: workingDirectory,
            mode: .digest
        )
        // The host profile's variables underneath, term-mesh's own on top —
        // a profile must be able to add a proxy, not to impersonate the team.
        let remoteEnvironment = PeerHostEnvironment.stored(forHostKey: host.id)
            .merging(Self.remoteNativeAgentEnvironment(
                teamName: team.id,
                agentName: agentName,
                agentType: agentType,
                agentCli: cli,
                workspaceId: workspace.id,
                socketPath: host.remoteSockPath
            )) { _, internalValue in internalValue }
        guard let panel = workspace.newAgentSplit(
            from: splitFrom,
            orientation: orientation,
            agentName: agentName,
            teamName: team.id,
            workingDirectory: workingDirectory,
            cli: cli,
            color: color
        ) else {
            throw RemoteAgentError.paneCreationFailed
        }

        if let bridge {
            panel.start(
                remoteBridgedCli: cli,
                bridgePath: bridge,
                model: Self.bridgeModelArg(cli: cli, model: model),
                target: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                remoteEnvironment: remoteEnvironment
            )
            if !instructions.isEmpty {
                let briefing = Self.withoutTerminalProtocol(instructions)
                    + "\n\nThis is your standing brief, not a task. "
                    + "Do no work now: reply with exactly "
                    + "\"Agent \(agentName) ready.\" and wait."
                try? panel.session.send(briefing, from: .leader)
            }
        } else {
            panel.start(
                remoteClaudeAt: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                model: Self.resolveClaudeModelArg(model),
                instructions: instructions,
                remoteEnvironment: remoteEnvironment
            )
        }

        panel.session.onBusyChanged = { [teamName = team.id, agentName, agentInstanceId] busy in
            TeamDataStore.shared.setAgentBusy(
                teamName: teamName, agentName: agentName,
                agentInstanceId: agentInstanceId, busy: busy
            )
        }
        panel.session.onTurnEnd = { [teamName = team.id, agentName, agentInstanceId] final, _, taskId in
            Self.fileReport(
                teamName: teamName, agentName: agentName,
                taskId: taskId, text: final
            )
            guard let taskId else { return }
            AutoReplyEmit.emit(
                teamName: teamName,
                agentName: agentName,
                event: AgentPipeCompletion.headerEvent(from: final),
                preferredTaskId: taskId,
                agentInstanceId: agentInstanceId
            )
        }
        workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: "\(Self.colorEmoji(color)) \(agentName) @\(host.displayName)"
        )

        let member = AgentMember(
            id: "\(agentName)@\(team.id)",
            agentInstanceId: agentInstanceId,
            name: agentName,
            teamName: team.id,
            cli: cli,
            launchCommand: cli,
            model: model,
            agentType: agentType,
            color: color,
            instructions: instructions,
            workspaceId: workspace.id,
            panelId: panel.id,
            createdAt: Date(),
            hostKey: host.id,
            originalAgentWorkDir: workingDirectory
        )
        guard adoptAgentMember(member, teamName: team.id) else {
            _ = workspace.closePanel(panel.id, force: true)
            throw RemoteAgentError.duplicateInstance(member.agentInstanceId)
        }
        scheduleAgentGridEqualization(workspace: workspace)
        RemoteProjectPaths.shared.remember(
            host: host.id,
            localRoot: team.workingDirectory,
            path: workingDirectory
        )
        return member
    }

    private static func remoteNativeAgentEnvironment(
        teamName: String,
        agentName: String,
        agentType: String,
        agentCli: String,
        workspaceId: UUID,
        socketPath: String?
    ) -> [String: String] {
        var env: [String: String] = [
            "TERMMESH_TEAM_AGENT": "1",
            "CMUX_TEAM_AGENT": "1",
            "TERMMESH_TEAM_NAME": teamName,
            "CMUX_TEAM_NAME": teamName,
            "TERMMESH_TEAM": teamName,
            "CMUX_TEAM": teamName,
            "TERMMESH_CLI": agentCli,
            "TERMMESH_AGENT_NAME": agentName,
            "TERMMESH_AGENT_ROLE": agentType,
            "TERMMESH_WORKSPACE_ID": workspaceId.uuidString,
        ]
        if let socketPath, !socketPath.isEmpty {
            env["TERMMESH_SOCKET"] = socketPath
            env["CMUX_SOCKET"] = socketPath
        }
        if agentCli == "claude" {
            env["CLAUDECODE"] = "1"
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        }
        return env
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
    func releaseRemoteAgent(_ agent: AgentMember, closing workspace: Workspace?, teamName: String? = nil) {
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

        // A native remote member is an SSH child owned by AgentSession.
        // Closing the panel stops that process; there is no peer surface or
        // interactive CLI to unwind first.
        if let workspace, let panelId, workspace.agentPanel(for: panelId) != nil {
            _ = workspace.closePanel(panelId, force: true)
            reapDetachedAgentWorktree(agent, teamName: teamName)
            return
        }

        if let panel {
            TerminalController.shared.sendNamedKeyWithRetry(on: panel.surface, keyName: "ctrl-c") { _, _ in }
        }
        let surfaceID = agent.remoteSurfaceSpawned ? agent.remoteSurfaceID : nil
        let surfaceHostKey = agent.hostKey
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
                // Hand the shell back plain. The CLI restores these itself on
                // a clean exit, and this is for every other kind.
                panel?.surface.resetTerminal()
                if let workspace, let panelId {
                    _ = workspace.closePanel(panelId, force: true)
                }
                self.reapDetachedAgentWorktree(agent, teamName: teamName)
                guard let surfaceID, let hostSockPath, let surfaceHostKey else { return }
                Task { @MainActor in
                    await Self.closeManagedRemoteSurface(
                        hostSockPath: hostSockPath,
                        hostKey: surfaceHostKey,
                        surfaceID: surfaceID
                    )
                }
            }
        }
    }

    /// A late-added agent's own checkout, prepared on the host — or nil to
    /// use the requested directory exactly as given.
    ///
    /// Applies only when the requested directory is recorded as one of this
    /// project's (`remoteProjectLocations`) — a team without project records,
    /// or an explicitly custom path, keeps today's behavior. The primary is
    /// derived from the directory itself over ssh (`--git-common-dir`), so a
    /// recorded worktree path resolves to the same primary its siblings came
    /// from. The checkout uses the same instance-tag scheme as creation; the
    /// mem-mesh identity needs no re-pinning because `--local` git config is
    /// shared with every worktree of the repository. Best effort on purpose:
    /// any failure falls back to the requested directory, which is exactly
    /// what this path always did.
    static func prepareLateAgentCheckout(
        team: Team,
        host: HostEntry,
        hostKey: String,
        agentName: String,
        requestedDirectory: String
    ) async -> (path: String, branch: String)? {
        let requested = requestedDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty,
              let sshTarget = host.sshTarget, !sshTarget.isEmpty,
              team.remoteProjectLocations.contains(
                  Team.RemoteProjectLocation(hostKey: hostKey, path: requested)
              )
        else { return nil }

        let quoted = "'" + requested.replacingOccurrences(of: "'", with: "'\\''") + "'"
        guard let commonDir = try? await PeerHostReadinessChecker.runScript(
            sshTarget: sshTarget,
            port: host.sshPort,
            identityFile: host.identityFile,
            script: "git -C \(quoted) rev-parse --path-format=absolute --git-common-dir 2>/dev/null",
            timeoutSeconds: 30
        ).trimmingCharacters(in: .whitespacesAndNewlines),
              commonDir.hasSuffix("/.git")
        else { return nil }
        let primary = String(commonDir.dropLast("/.git".count))
        guard !primary.isEmpty, primary != "/" else { return nil }

        let plan = PeerProjectBootstrap.plan(
            projectRoot: (primary as NSString).deletingLastPathComponent,
            projectName: (primary as NSString).lastPathComponent,
            agents: [agentName],
            isolateAgents: true,
            instanceTag: PeerProjectBootstrap.makeInstanceTag()
        )
        guard let checkout = plan.agentCheckouts.first else { return nil }
        do {
            try await PeerProjectBootstrap.run(
                sshTarget: sshTarget,
                port: host.sshPort,
                identityFile: host.identityFile,
                plan: plan,
                gitURL: nil,
                sourceKind: .existingFolder,
                memMeshProjectID: nil,
                environment: PeerHostEnvironment.stored(forHostKey: hostKey)
            )
        } catch {
            RemoteWorkLog.info(
                "Could not carve a worktree for \(agentName) on \(host.displayName) — using \(requested): \(error)"
            )
            return nil
        }
        RemoteWorkLog.info(
            "\(agentName) joins in its own checkout on \(host.displayName): \(checkout.path) (\(checkout.branch))"
        )
        return (path: checkout.path, branch: checkout.branch)
    }

    /// A detached agent's instance-tagged checkout has no future occupant, so
    /// try to reclaim it. Gated twice: the path must be one this team created
    /// (recorded in `remoteProjectLocations` at creation), and the remote
    /// script itself refuses anything that is not a clean linked worktree —
    /// see `PeerProjectBootstrap.reapWorktreeScript`. Restart and recycle
    /// never come through here; only a true detach does.
    private func reapDetachedAgentWorktree(_ agent: AgentMember, teamName: String?) {
        guard let teamName,
              let hostKey = agent.hostKey,
              let workDir = agent.originalAgentWorkDir?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !workDir.isEmpty,
              let team = teams[teamName],
              team.remoteProjectLocations.contains(
                  Team.RemoteProjectLocation(hostKey: hostKey, path: workDir)
              ),
              let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
              let sshTarget = host.sshTarget, !sshTarget.isEmpty
        else { return }
        let port = host.sshPort
        let identityFile = host.identityFile
        Task.detached {
            await PeerProjectBootstrap.reapWorktree(
                sshTarget: sshTarget,
                port: port,
                identityFile: identityFile,
                path: workDir
            )
            await MainActor.run {
                RemoteWorkLog.info(
                    "Reaped \(agent.name)'s checkout on \(host.displayName) (kept if it held uncommitted work): \(workDir)"
                )
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
        leaderEndpoint: LeaderEndpoint = .local,
        leaderWorkingDirectory: String? = nil,
        worktreeMode: String = "off",
        executionMode: String = "pane",
        resumeSessionId: String? = nil,
        pairMode: String = "none",
        pairModel: String = "",
        pairSpec: String = "",
        projectSource: ProjectSource? = nil,
        tabManager: TabManager
    ) -> Team? {
        // Peer attachment is asynchronous. Record the requested endpoint from
        // the start, but keep `leaderReady` false until attach commits. This
        // avoids a visible local → remote identity change without presenting
        // an unattached peer leader as usable. No leader CLI is launched here.
        let initialLeaderEndpoint = Self.initialLeaderEndpoint(
            forRequestedEndpoint: leaderEndpoint
        )
        let launchLeaderLocally = Self.shouldLaunchLeaderLocally(
            forRequestedEndpoint: leaderEndpoint
        )
        // A remote pane is a peer surface pulled into this workspace, so it
        // needs the workspace and the team to already exist. Spawning these
        // locally and moving them would start each CLI on the wrong machine
        // and then close it.
        let remoteRows = rows.filter { $0.hostKey != nil }
        let remoteLeaderSystemPrompt: String?
        if case let .peer(hostKey) = leaderEndpoint {
            let remoteSocketPath = RemoteHostStore.shared.sortedHosts
                .first(where: { $0.id == hostKey })?
                .remoteSockPath ?? "inherited from TERMMESH_SOCKET"
            if leaderMode.lowercased() == "claude" {
                remoteLeaderSystemPrompt = Self.remoteLeaderClaudeSystemPrompt(
                    teamName: teamName,
                    rows: rows,
                    remoteWorkingDirectory: leaderWorkingDirectory ?? workingDirectory,
                    remoteSocketPath: remoteSocketPath
                )
            } else {
                // Non-Claude peer CLIs receive the same canonical payload via
                // a staged file plus `LeaderParallelPolicy.launchDirective`.
                // Do not copy routing rules into this launch path.
                remoteLeaderSystemPrompt = LeaderParallelPolicy.renderedInstructions
            }
        } else {
            remoteLeaderSystemPrompt = nil
        }
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

        guard var team = createTeam(
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
            leaderEndpoint: initialLeaderEndpoint,
            launchLeaderLocally: launchLeaderLocally,
            tabManager: tabManager
        ) else { return nil }

        if let projectSource {
            team.usesDedicatedRemoteWorkspaces = true
            configureDedicatedRemoteWorkspaces(teamName: team.id, enabled: true)
            var locations: Set<Team.RemoteProjectLocation> = []
            if let hostKey = projectSource.hostKey {
                locations.insert(.init(hostKey: hostKey, path: projectSource.projectPath))
            }
            for row in remoteRows {
                guard let hostKey = row.hostKey else { continue }
                let path = row.hostDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                locations.insert(.init(hostKey: hostKey, path: path))
            }
            if case let .peer(hostKey) = leaderEndpoint {
                let path = (leaderWorkingDirectory ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    locations.insert(.init(hostKey: hostKey, path: path))
                }
            }
            team.remoteProjectLocations = locations.sorted {
                ($0.hostKey, $0.path) < ($1.hostKey, $1.path)
            }
            recordRemoteProjectLocations(
                teamName: team.id,
                locations: team.remoteProjectLocations
            )
        }

        // One at a time. Choosing a surface reads which ones this app's agents
        // already hold, so two attaches running at once both look at a roster
        // that does not have the other in it yet, both pick the same free
        // shell, and both type their launch command into it — the commands
        // interleave character by character and neither CLI starts. Seen as
        // `--dangerously-skip-permissionsskip-permissions` and a `mkdir` that
        // the shell could not find.
        Task { @MainActor in
            if case let .peer(hostKey) = leaderEndpoint {
                do {
                    try await self.attachRemoteLeader(
                        teamName: team.id,
                        hostKey: hostKey,
                        workingDirectory: leaderWorkingDirectory ?? workingDirectory,
                        cli: leaderMode,
                        model: leaderModel,
                        systemPrompt: remoteLeaderSystemPrompt
                    )
                } catch {
                    let description = "Could not start remote leader on \(hostKey): \(error)"
                    RemoteWorkLog.info(description)
                    self.markRemoteLeaderFailed(
                        teamName: team.id,
                        description: description
                    )
                    self.markLeaderPolicyState(
                        teamName: team.id,
                        state: "failed",
                        failureDescription: description
                    )
                }
            }
            for row in remoteRows {
                guard let hostKey = row.hostKey else { continue }
                let directory = row.hostDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
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

    @MainActor
    func deleteProject(teamName: String, tabManager: TabManager) async throws {
        guard let team = teams[teamName] else {
            throw RemoteAgentError.teamNotFound(teamName)
        }

        let grouped = Dictionary(grouping: team.remoteProjectLocations, by: \.hostKey)
        var deletionJobs: [(host: HostEntry, script: String)] = []
        for (hostKey, locations) in grouped {
            guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey })
            else {
                throw RemoteAgentError.hostNotFound(hostKey)
            }
            guard host.isConnected, let sshTarget = host.sshTarget, !sshTarget.isEmpty else {
                throw RemoteAgentError.hostNotConnected(host.displayName)
            }
            let script = try PeerProjectBootstrap.deletionScript(paths: locations.map(\.path))
            deletionJobs.append((host, script))
        }

        let workspace = tabManager.tabs.first(where: { $0.id == team.workspaceId })
        var remoteSurfaces: [(socket: String, hostKey: String, surfaceID: Data)] = []
        if case let .peer(hostKey) = team.leaderEndpoint,
           let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
           let panel = workspace?.terminalPanel(for: team.leaderPanelId),
           let session = panel.peerPaneSession {
            TerminalController.shared.sendNamedKeyWithRetry(
                on: panel.surface, keyName: "ctrl-c"
            ) { _, _ in }
            remoteSurfaces.append((
                host.activeSockPath, hostKey, session.originSurface.surfaceID
            ))
        }

        for agent in team.agents {
            guard let panelID = agent.panelId else { continue }
            if workspace?.agentPanel(for: panelID) != nil {
                _ = workspace?.closePanel(panelID, force: true)
            } else if agent.remoteSurfaceSpawned,
                      let surfaceID = agent.remoteSurfaceID,
                      let hostKey = agent.hostKey,
                      let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }) {
                remoteSurfaces.append((host.activeSockPath, hostKey, surfaceID))
            }
        }

        for remote in remoteSurfaces where !remote.socket.isEmpty {
            let connection = try await PeerRelaySession.connect(hostSockPath: remote.socket)
            try await connection.session.requestClosePane(paneID: remote.surfaceID)
            await connection.cancel()
            ManagedPeerSurfaceStore.shared.forget(
                hostKey: remote.hostKey,
                surfaceID: remote.surfaceID
            )
        }

        // The project owns these peer workspaces. Removing the project should
        // remove their now-detached shell containers too; relay/default and
        // user-created workspaces are never included in this map.
        for (hostKey, workspaceID) in team.remoteWorkspaceIDs {
            guard let host = RemoteHostStore.shared.sortedHosts.first(where: { $0.id == hostKey }),
                  !host.activeSockPath.isEmpty
            else { continue }
            let connection = try await PeerRelaySession.connect(
                hostSockPath: host.activeSockPath
            )
            try await connection.session.deleteWorkspace(workspaceID: workspaceID)
            await connection.cancel()
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        for job in deletionJobs {
            guard let sshTarget = job.host.sshTarget else { continue }
            try await PeerHostReadinessChecker.runScript(
                sshTarget: sshTarget,
                port: job.host.sshPort,
                identityFile: job.host.identityFile,
                script: job.script,
                timeoutSeconds: 60
            )
        }
        for hostKey in grouped.keys {
            RemoteProjectPaths.shared.forget(
                host: hostKey,
                localRoot: team.workingDirectory
            )
        }

        _ = destroyTeam(name: teamName, tabManager: tabManager, archive: false)
    }

    /// Preserve the user's requested endpoint while the pane is connecting.
    /// Readiness, rather than pretending the endpoint is local, guards sends
    /// and exposes attach failure.
    static func initialLeaderEndpoint(
        forRequestedEndpoint endpoint: LeaderEndpoint
    ) -> LeaderEndpoint {
        endpoint
    }

    static func shouldLaunchLeaderLocally(
        forRequestedEndpoint endpoint: LeaderEndpoint
    ) -> Bool {
        if case .peer = endpoint { return false }
        return true
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
        var askedTerminalAgentToQuit = false
        for agent in remote {
            guard let panelId = agent.panelId,
                  let located = AppDelegate.shared?.locateSurface(surfaceId: panelId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let panel = workspace.terminalPanel(for: panelId) else { continue }
            askedTerminalAgentToQuit = true
            _ = panel.surface.sendIMEText(Self.quitCommand(cli: agent.cli), withReturn: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitReturnGap) {
                TerminalController.shared.sendNamedKeyWithRetry(
                    on: panel.surface, keyName: "return"
                ) { _, _ in }
            }
        }
        return askedTerminalAgentToQuit
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
        workingDirectory: String,
        systemPromptFile: String? = nil,
        environment: [String: String] = [:]
    ) -> String {
        let quotedDir = workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
        // `mkdir -p` before `cd`, because a project on another machine has
        // usually not been made there yet. Without it `cd` failed, the `&&`
        // short-circuited, and the CLI never started — leaving a pane that
        // looked attached and was a dead shell, with the reason one scroll up.
        // Idempotent, so an existing directory costs nothing.
        // The launch has to see the same PATH the probe did. Finding a CLI and
        // then starting a shell that cannot is the worst of both: the guard
        // passes and the pane dies with "command not found".
        let enter = RemoteShellPath.prologue
            + "mkdir -p '\(quotedDir)' && cd '\(quotedDir)'"
        // The host profile's variables, as an assignment prefix scoped to the
        // CLI itself (`K='v' claude …`). This is where a per-machine
        // IS_SANDBOX or proxy reaches a typed launch.
        let assignments = PeerHostEnvironment.inlineAssignments(environment)
        let envPrefix = assignments.isEmpty ? "" : assignments + " "
        switch cli {
        case "claude":
            guard let systemPromptFile else {
                return "\(enter) && \(envPrefix)claude --model \(model) --dangerously-skip-permissions"
            }
            let quotedFile = shellQuoted(systemPromptFile)
            return "\(enter) && TERMMESH_LEADER_PROMPT=$(cat \(quotedFile))"
                + " && rm -f \(quotedFile)"
                + " && \(envPrefix)claude --model \(model)"
                + " --system-prompt \"$TERMMESH_LEADER_PROMPT\""
                + " --dangerously-skip-permissions"
        case "codex", "kiro", "gemini":
            guard let systemPromptFile else {
                return "\(enter) && \(envPrefix)\(cli) --model \(model)"
            }
            let directive = LeaderParallelPolicy.launchDirective(promptFile: systemPromptFile)
            switch cli {
            case "kiro":
                return "\(enter) && \(envPrefix)kiro chat --model \(model) \(shellQuoted(directive))"
            default:
                return "\(enter) && \(envPrefix)\(cli) --model \(model) \(shellQuoted(directive))"
            }
        default:
            return "\(enter) && \(envPrefix)\(cli) --model \(model)"
        }
    }

    static func remoteLeaderCommand(
        cli: String,
        model: String,
        teamName: String,
        workingDirectory: String,
        grant: Termmesh_Peer_V1_TeamLeaderGrant,
        systemPromptFile: String? = nil,
        environment: [String: String] = [:]
    ) -> String {
        let hexGrant = grant.grantID.map { String(format: "%02x", $0) }.joined()
        let exports = [
            "TERMMESH_LEADER_GRANT_ID=\(shellQuoted(hexGrant))",
            "TERMMESH_LEADER_PROJECT_ID=\(shellQuoted(grant.projectID))",
            "TERMMESH_LEADER_TEAM_UUID=\(shellQuoted(grant.teamUuid))",
            "TERMMESH_LEADER_EXPIRES_AT=\(grant.expiresAtUnixSecs)",
            "TERMMESH_LEADER_PEER_ID=\(shellQuoted(PeerIdentity.hexString(PeerIdentity.defaultPeerID())))",
            "TERMMESH_TEAM=\(shellQuoted(teamName))",
        ].joined(separator: " ")
        let launch = remoteAgentCommand(
            cli: cli,
            model: model,
            agentName: "leader",
            teamName: teamName,
            workingDirectory: workingDirectory,
            systemPromptFile: systemPromptFile,
            environment: environment
        )
        // `export` applies to the final CLI, unlike a shell assignment prefix
        // before `mkdir`, which would have scoped the grant to that one setup
        // command only.
        // Replace the interactive shell after exporting. That drops the grant
        // as soon as the CLI exits instead of leaving it in a resumed shell.
        return "export \(exports); exec /bin/sh -lc \(shellQuoted(launch))"
    }

    /// Secret-free first stage for remote leader launch. The next command is
    /// sent only after this Return, while terminal echo and shell history are
    /// disabled, so the scoped bearer grant is not rendered or retained by the
    /// interactive shell.
    static func remoteLeaderPrepareCommand() -> String {
        "unset HISTFILE; stty -echo"
    }

    /// Wait until the relay has forwarded actual shell output before typing.
    ///
    /// `AutoReplyPoller` watches registered agent output, not transport
    /// readiness. A remote leader is not an agent member yet, so asking that
    /// poller kept every leader at its full 25-second timeout even though the
    /// relay had rendered its first frame almost immediately.
    @MainActor
    static func waitForRemoteShell(
        session: PeerPaneSession,
        timeout: TimeInterval = 3,
        settleDelay: TimeInterval = 0.5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = session.relaySession.ioSnapshot
            if (snapshot["bytes_enqueued"] as? UInt64 ?? 0) > 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(
            nanoseconds: UInt64(max(0, settleDelay) * 1_000_000_000)
        )
    }
}
