import XCTest
import Darwin
import AppKit
import PeerProto
import Bonsplit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

private actor AsyncFlag {
    private var value = false

    func set() { value = true }
    func read() -> Bool { value }
}

final class PeerPaneSessionTests: XCTestCase {
    func testCollaborationRepairUsesLifecycleTimeoutWithoutChangingOrdinaryCommands() {
        XCTAssertEqual(
            TerminalController.teamCommandTimeoutSeconds(
                method: "team.repair_collaboration", agentCount: 4
            ),
            240
        )
        XCTAssertEqual(
            TerminalController.teamCommandTimeoutSeconds(
                method: "team.send", agentCount: 4
            ),
            6.5
        )
    }

    private func conflictRecord(
        name: String = "xm",
        projectID: String = "team:one",
        hostKey: String? = "ssh:mac-sub",
        path: String = "/work/xm",
        location: TeamOrchestrator.ProjectConflictLocation,
        leaderReady: Bool = true
    ) -> TeamOrchestrator.ProjectConflictRecord {
        .init(
            name: name,
            identity: .init(
                projectID: projectID, hostKey: hostKey, workingDirectory: path
            ),
            location: location, teamName: name, leaderReady: leaderReady,
            failureDescription: leaderReady ? nil : "leader failed"
        )
    }

    func testProjectNameConflictClassifiesExactLiveAndDetached() {
        let identity = TeamOrchestrator.ProjectCreationIdentity(
            projectID: "team:one", hostKey: "ssh:mac-sub",
            workingDirectory: "/work/xm"
        )
        let live = conflictRecord(
            location: .otherWindow(windowID: UUID(), workspaceID: UUID())
        )
        guard case .exactLive(let selected) = TeamOrchestrator.classifyProjectNameConflict(
            requestedName: " XM ", requestedIdentity: identity, candidates: [live]
        ) else { return XCTFail("exact live Project was not selected") }
        XCTAssertEqual(selected.identity.projectID, "team:one")

        let detached = conflictRecord(location: .detached(workspaceID: UUID()))
        guard case .exactDetached = TeamOrchestrator.classifyProjectNameConflict(
            requestedName: "xm", requestedIdentity: identity, candidates: [detached]
        ) else { return XCTFail("detached exact Project was not selected") }
    }

    func testProjectNameConflictClassifiesIncompleteExactAttempt() {
        let identity = TeamOrchestrator.ProjectCreationIdentity(
            projectID: "team:one", hostKey: nil, workingDirectory: "/work/xm"
        )
        let incomplete = conflictRecord(
            hostKey: nil, location: .currentWindow(windowID: nil, workspaceID: UUID()),
            leaderReady: false
        )
        guard case .incomplete = TeamOrchestrator.classifyProjectNameConflict(
            requestedName: "xm", requestedIdentity: identity, candidates: [incomplete]
        ) else { return XCTFail("failed exact attempt was not classified incomplete") }
    }

    func testProjectNameConflictRejectsSameNameDifferentIdentity() {
        let requested = TeamOrchestrator.ProjectCreationIdentity(
            projectID: "team:new", hostKey: "ssh:mac-sub",
            workingDirectory: "/work/xm"
        )
        let local = conflictRecord(
            location: .currentWindow(windowID: nil, workspaceID: UUID())
        )
        guard case .localNameCollision = TeamOrchestrator.classifyProjectNameConflict(
            requestedName: "xm", requestedIdentity: requested, candidates: [local]
        ) else { return XCTFail("local name collision was not reported") }

        let remote = conflictRecord(
            location: .remote(hostKey: "ssh:mac-sub", hostName: "mac-sub")
        )
        guard case .remoteNameCollision = TeamOrchestrator.classifyProjectNameConflict(
            requestedName: "xm", requestedIdentity: requested, candidates: [remote]
        ) else { return XCTFail("remote name collision was not reported") }
    }

    func testRemoteCollisionOffersDeletionOnlyForOwnedRemoteRecordsWithProjectID() {
        var remote = conflictRecord(
            location: .remote(hostKey: "ssh:mac-sub", hostName: "mac-sub")
        )
        XCTAssertFalse(remote.canDeleteOwnedRemoteRecord, "foreign records need host-side cleanup")
        XCTAssertTrue(remote.canOpenRemoteProject, "a remote manifest with an exact ID is adoptable")

        remote.presentationOwnedByRequester = true
        XCTAssertTrue(remote.canDeleteOwnedRemoteRecord)

        remote.leaderProcessActiveKnown = true
        remote.leaderReady = true
        XCTAssertFalse(remote.canDeleteOwnedRemoteRecord, "a running leader is live work, not a leftover")
        remote.leaderReady = false
        XCTAssertTrue(remote.canDeleteOwnedRemoteRecord, "a known-idle leader shell may be cleaned up")
        remote.leaderProcessActiveKnown = false

        remote.identity = .init(hostKey: "ssh:mac-sub", workingDirectory: "/work/xm")
        XCTAssertFalse(remote.canDeleteOwnedRemoteRecord, "deletion needs an exact Project ID")
        XCTAssertFalse(remote.canOpenRemoteProject, "opening needs an exact Project ID")

        var local = conflictRecord(location: .detached(workspaceID: UUID()))
        local.presentationOwnedByRequester = true
        XCTAssertFalse(local.canDeleteOwnedRemoteRecord, "local lifecycle uses normal teardown")
    }

    func testProjectNameConflictPrefersExactProjectOverDifferentIdentity() {
        let requested = TeamOrchestrator.ProjectCreationIdentity(
            projectID: "team:one", hostKey: "ssh:mac-sub",
            workingDirectory: "/work/xm"
        )
        let exact = conflictRecord(
            projectID: "team:one",
            location: .currentWindow(windowID: nil, workspaceID: UUID())
        )
        let duplicateRemote = conflictRecord(
            projectID: "team:two",
            location: .remote(hostKey: "ssh:mac-sub", hostName: "mac-sub")
        )

        guard case .exactLive(let selected) =
            TeamOrchestrator.classifyProjectNameConflict(
                requestedName: "xm", requestedIdentity: requested,
                candidates: [exact, duplicateRemote]
            )
        else {
            return XCTFail(
                "an exact Project was hidden behind a same-name remote record"
            )
        }
        XCTAssertEqual(selected.identity.projectID, "team:one")
    }

    // MARK: - Which owner a same-name collision reports
    //
    // `projectConflictRecords` builds candidates in a fixed order: local teams
    // first (their location is `.currentWindow`/`.otherWindow`/`.detached`,
    // never `.remote`, because it is decided by whether a local window shows
    // them — not by where the leader runs), then those teams' remote-checkout
    // aliases, which keep the local location, and only then remote manifests.
    // Picking "the first match" therefore reports a local record whenever one
    // exists, hiding a remote manifest that owns the same name — and remote is
    // the record with a detail view and the `canDeleteOwnedRemoteRecord`
    // cleanup, while a local Project is already visible in the sidebar.
    //
    // Reported from the field: creating a Project from an EXISTING folder on a
    // remote host was blocked as "A different local Project already uses this
    // name", with only "Use “eBPF 2”" offered, while the actual owner was a
    // leftover remote manifest the user could not see or delete.

    /// The requested identity a creation form actually builds: no project ID
    /// yet, host and path from the chosen source (`ProjectCreationFlow
    /// .projectIdentity`). Getting this wrong would make the test exercise the
    /// project-ID branch instead of the path branch.
    private func newProjectIdentity(
        hostKey: String? = "ssh:builder",
        path: String = "/app/term-mesh/eBPF"
    ) -> TeamOrchestrator.ProjectCreationIdentity {
        .init(hostKey: hostKey, workingDirectory: path)
    }

    func testProjectNameConflictOpensExactDetachedProjectAheadOfRemoteRecord() {
        // Candidate order as `projectConflictRecords` emits it.
        let localLeftover = conflictRecord(
            name: "eBPF", projectID: "team:local", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF",
            location: .detached(workspaceID: UUID())
        )
        let remoteLeftover = conflictRecord(
            name: "eBPF", projectID: "team:remote", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF",
            location: .remote(hostKey: "ssh:builder", hostName: "builder")
        )

        guard case .exactDetached(let selected) =
            TeamOrchestrator.classifyProjectNameConflict(
                requestedName: "eBPF",
                requestedIdentity: newProjectIdentity(),
                candidates: [localLeftover, remoteLeftover]
            )
        else {
            return XCTFail(
                "an exact detached Project was hidden behind a remote record"
            )
        }
        XCTAssertEqual(selected.identity.projectID, "team:local")
    }

    func testProjectNameConflictOpensExactDetachedProjectRegardlessOfCandidateOrder() {
        // `teams` is a dictionary, so local records arrive in an unspecified
        // order; the answer must not depend on it.
        let local = conflictRecord(
            name: "eBPF", projectID: "team:local", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF", location: .detached(workspaceID: UUID())
        )
        let remote = conflictRecord(
            name: "eBPF", projectID: "team:remote", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF",
            location: .remote(hostKey: "ssh:builder", hostName: "builder")
        )
        for candidates in [[local, remote], [remote, local]] {
            guard case .exactDetached(let selected) =
                TeamOrchestrator.classifyProjectNameConflict(
                    requestedName: "eBPF",
                    requestedIdentity: newProjectIdentity(),
                    candidates: candidates
                )
            else { return XCTFail("order changed the answer: \(candidates)") }
            XCTAssertEqual(selected.identity.projectID, "team:local")
        }
    }

    func testProjectNameConflictOpensExactProjectAheadOfRemoteLeftover() {
        // The Existing-folder shape: the requested host+path matches a real
        // Project exactly. A stale same-name record must not replace the only
        // action that continues that Project with a rename suggestion.
        let exact = conflictRecord(
            name: "eBPF", projectID: "team:exact", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF",
            location: .currentWindow(windowID: nil, workspaceID: UUID())
        )
        let localLeftover = conflictRecord(
            name: "eBPF", projectID: "team:other-local", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF-old",
            location: .detached(workspaceID: UUID())
        )
        let remoteLeftover = conflictRecord(
            name: "eBPF", projectID: "team:remote", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF",
            location: .remote(hostKey: "ssh:builder", hostName: "builder")
        )

        guard case .exactLive(let selected) =
            TeamOrchestrator.classifyProjectNameConflict(
                requestedName: "eBPF",
                requestedIdentity: newProjectIdentity(),
                candidates: [exact, localLeftover, remoteLeftover]
            )
        else {
            return XCTFail("the exact Project was hidden behind a remote leftover")
        }
        XCTAssertEqual(selected.identity.projectID, "team:exact")
    }

    func testProjectNameConflictTreatsOneProjectsTwoPresentationsAsOneOwner() {
        // A single Project routinely appears twice: its local presentation and
        // the manifest it published on the host it runs on. Same project ID,
        // so it is one owner and there is no collision — Open Existing is the
        // right answer, aimed at the local presentation.
        let workspace = UUID()
        let localPresentation = conflictRecord(
            name: "eBPF", projectID: "team:one", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF",
            location: .currentWindow(windowID: nil, workspaceID: workspace)
        )
        let ownManifest = conflictRecord(
            name: "eBPF", projectID: "team:one", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF",
            location: .remote(hostKey: "ssh:builder", hostName: "builder")
        )
        for candidates in [[localPresentation, ownManifest], [ownManifest, localPresentation]] {
            guard case .exactLive(let selected) =
                TeamOrchestrator.classifyProjectNameConflict(
                    requestedName: "eBPF",
                    requestedIdentity: newProjectIdentity(),
                    candidates: candidates
                )
            else {
                return XCTFail("a Project's own manifest was read as a rival owner")
            }
            // The local presentation, not the manifest: Open Existing and
            // Resume act on a window, and naming the manifest here would send
            // the user to the wrong one.
            guard case .currentWindow = selected.location else {
                return XCTFail("the manifest was chosen over the local presentation")
            }
        }
    }

    func testProjectNameConflictStaysLocalWhenNoRemoteOwnsTheName() {
        // The preference must not invent a remote owner. With only local
        // records the answer is unchanged, and the local branch is correct:
        // that Project is visible in the sidebar and has a normal teardown.
        let localA = conflictRecord(
            name: "eBPF", projectID: "team:a", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF-a", location: .detached(workspaceID: UUID())
        )
        let localB = conflictRecord(
            name: "eBPF", projectID: "team:b", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF-b",
            location: .otherWindow(windowID: UUID(), workspaceID: UUID())
        )
        guard case .localNameCollision = TeamOrchestrator.classifyProjectNameConflict(
            requestedName: "eBPF",
            requestedIdentity: newProjectIdentity(),
            candidates: [localA, localB]
        ) else { return XCTFail("an all-local collision must stay local") }
    }

    func testProjectNameConflictPrefersRemoteOnlyAmongActualCollisions() {
        // A remote record with a DIFFERENT name is not a collision at all and
        // must not be dragged in by the preference — the filter runs first.
        let localCollision = conflictRecord(
            name: "eBPF", projectID: "team:local", hostKey: "ssh:builder",
            path: "/app/term-mesh/eBPF-old", location: .detached(workspaceID: UUID())
        )
        let unrelatedRemote = conflictRecord(
            name: "something-else", projectID: "team:remote", hostKey: "ssh:builder",
            path: "/app/other",
            location: .remote(hostKey: "ssh:builder", hostName: "builder")
        )
        guard case .localNameCollision(let selected) =
            TeamOrchestrator.classifyProjectNameConflict(
                requestedName: "eBPF",
                requestedIdentity: newProjectIdentity(),
                candidates: [localCollision, unrelatedRemote]
            )
        else { return XCTFail("an unrelated remote name was treated as the owner") }
        XCTAssertEqual(selected.identity.projectID, "team:local")
    }

    func testProjectNameConflictUsesPathFallbackOnlyOnSameHost() {
        let local = TeamOrchestrator.ProjectCreationIdentity(
            hostKey: nil, workingDirectory: "/work/../work/xm"
        )
        let same = TeamOrchestrator.ProjectCreationIdentity(
            hostKey: nil, workingDirectory: "/work/xm"
        )
        XCTAssertTrue(TeamOrchestrator.projectCreationIdentitiesMatch(local, same))
        XCTAssertFalse(TeamOrchestrator.projectCreationIdentitiesMatch(
            .init(hostKey: "host-a", workingDirectory: "/work/xm"),
            .init(hostKey: "host-b", workingDirectory: "/work/xm")
        ))
    }

    func testProjectNameConflictIgnoresDifferentNames() {
        let result = TeamOrchestrator.classifyProjectNameConflict(
            requestedName: "new", requestedIdentity: .init(),
            candidates: [conflictRecord(location: .detached(workspaceID: UUID()))]
        )
        XCTAssertEqual(result, .none)
    }

    @MainActor
    func testProjectCreationReservationSerializesNormalizedNames() {
        let orchestrator = TeamOrchestrator.shared
        let first = orchestrator.beginProjectCreationReservation(
            name: " XM ", requestID: UUID()
        )
        XCTAssertNotNil(first)
        XCTAssertNil(orchestrator.beginProjectCreationReservation(name: "xm"))
        XCTAssertTrue(orchestrator.hasProjectCreationReservation(name: "xM"))
        if let first {
            XCTAssertTrue(orchestrator.releaseProjectCreationReservation(first))
            XCTAssertFalse(orchestrator.releaseProjectCreationReservation(first))
        }
        let next = orchestrator.beginProjectCreationReservation(name: "xm")
        XCTAssertNotNil(next)
        if let next {
            XCTAssertTrue(orchestrator.releaseProjectCreationReservation(next))
        }
    }

    @MainActor
    func testProjectCreationReservationRejectsWrongOwnerAndReleasesOnce() {
        let orchestrator = TeamOrchestrator.shared
        let owner = UUID()
        let reservation = orchestrator.beginProjectCreationReservation(
            name: "reservation-contract", requestID: owner
        )
        XCTAssertNotNil(reservation)
        guard let reservation else { return }

        let wrong = TeamOrchestrator.ProjectCreationReservation(
            normalizedName: reservation.normalizedName, requestID: UUID()
        )
        XCTAssertFalse(orchestrator.ownsProjectCreationReservation(wrong, teamName: "reservation-contract"))
        XCTAssertFalse(orchestrator.releaseProjectCreationReservation(wrong))
        XCTAssertTrue(orchestrator.ownsProjectCreationReservation(
            reservation, teamName: " RESERVATION-CONTRACT "
        ))
        XCTAssertTrue(orchestrator.releaseProjectCreationReservation(reservation))
        XCTAssertFalse(orchestrator.ownsProjectCreationReservation(
            reservation, teamName: "reservation-contract"
        ))
    }

    func testProjectCreationCollisionRunsNoPersistedStateReset() {
        var resetCount = 0

        XCTAssertFalse(TeamOrchestrator.resetProjectCreationStateIfAuthorized(
            hasNameConflict: true,
            ownsReservation: true,
            reset: { resetCount += 1 }
        ))
        XCTAssertFalse(TeamOrchestrator.resetProjectCreationStateIfAuthorized(
            hasNameConflict: false,
            ownsReservation: false,
            reset: { resetCount += 1 }
        ))
        XCTAssertEqual(resetCount, 0, "rejected creates must preserve existing state")

        XCTAssertTrue(TeamOrchestrator.resetProjectCreationStateIfAuthorized(
            hasNameConflict: false,
            ownsReservation: true,
            reset: { resetCount += 1 }
        ))
        XCTAssertEqual(resetCount, 1, "only the reservation owner may reset stale state")
    }

    func testProjectCreationSuccessHasTypedCreatedIdentity() {
        let workspaceID = UUID()
        let result = ProjectCreationFlow.CreationResult.created(
            teamName: "xm", workspaceID: workspaceID
        )
        XCTAssertEqual(
            result,
            .created(teamName: "xm", workspaceID: workspaceID)
        )
    }

    func testProjectIdentityFollowsSourceInsteadOfLeaderPlacement() {
        let localSource = ProjectSource(
            hostKey: nil, projectPath: "/work/local", gitURL: "",
            isolateAgents: false, kind: .existingFolder
        )
        XCTAssertEqual(
            ProjectCreationFlow.projectIdentity(
                source: localSource,
                leader: ProjectLeader(
                    mode: "codex", model: "gpt-5.6-sol",
                    endpoint: .peer(hostKey: "ssh:mac-sub")
                )
            ),
            .init(hostKey: nil, workingDirectory: "/work/local")
        )

        let remoteSource = ProjectSource(
            hostKey: "ssh:mac-sub", projectPath: "/work/remote", gitURL: "",
            isolateAgents: false, kind: .existingFolder
        )
        XCTAssertEqual(
            ProjectCreationFlow.projectIdentity(
                source: remoteSource,
                leader: ProjectLeader(mode: "repl", model: "", endpoint: .local)
            ),
            .init(hostKey: "ssh:mac-sub", workingDirectory: "/work/remote")
        )
    }

    func testProjectConflictCopyIdentifiesLocationAndExplicitIntent() {
        let otherWindow = conflictRecord(
            location: .otherWindow(windowID: UUID(), workspaceID: UUID())
        )
        XCTAssertTrue(ProjectCreationFlow.conflictDescription(
            .exactLive(otherWindow)
        ).contains("another window"))
        XCTAssertTrue(ProjectCreationFlow.conflictDescription(
            .exactLive(otherWindow)
        ).contains("Open Existing"))

        let detached = conflictRecord(location: .detached(workspaceID: UUID()))
        XCTAssertTrue(ProjectCreationFlow.conflictDescription(
            .exactDetached(detached)
        ).contains("without a window"))

        let remote = conflictRecord(
            location: .remote(hostKey: "ssh:mac-sub", hostName: "mac-sub")
        )
        XCTAssertTrue(ProjectCreationFlow.conflictDescription(
            .remoteNameCollision(remote)
        ).contains("mac-sub"))
        XCTAssertTrue(ProjectCreationFlow.conflictDescription(
            .remoteNameCollision(remote)
        ).contains("Open Existing"))
    }

    func testProjectConflictDebugLocationUsesProductionRecord() {
        let otherWindow = conflictRecord(
            location: .otherWindow(windowID: UUID(), workspaceID: UUID())
        )
        XCTAssertEqual(
            TerminalController.debugProjectConflictLocation(.exactLive(otherWindow)),
            "other_window"
        )
        let remote = conflictRecord(
            location: .remote(hostKey: "ssh:mac-sub", hostName: "mac-sub")
        )
        XCTAssertEqual(
            TerminalController.debugProjectConflictLocation(.remoteNameCollision(remote)),
            "remote:mac-sub"
        )
        XCTAssertEqual(
            TerminalController.debugProjectConflictAction(.remoteNameCollision(remote)),
            "open_existing"
        )
    }

    @MainActor
    func testIncompleteLocalProjectDoesNotReportResumeSuccessFromPaneExistence() async {
        // A missing team is the same safety boundary as a local team whose
        // leader is not ready: Resume must stay failed rather than close the
        // sheet based only on a pane lookup. The live-team branch is exercised
        // by the mac-sub Project E2E where the real workspace exists.
        let resumed = await TeamOrchestrator.shared.resumeIncompleteProjectSetup(
            teamName: "missing-incomplete-project"
        )
        XCTAssertFalse(resumed)
    }

    private func waitForLeaderGateWaiters(
        _ gate: RelayLeaderSessionGate,
        commands: Int,
        heals: Int
    ) async {
        for _ in 0..<1_000 {
            let counts = await gate.waitingCountsForTesting()
            if counts.commands == commands, counts.heals == heals { return }
            await Task.yield()
        }
        let counts = await gate.waitingCountsForTesting()
        XCTFail("gate waiters never reached commands=\(commands), heals=\(heals); got \(counts)")
    }

    func testLeaderSessionGateKeepsHealOutOfInflightCommand() async {
        let gate = RelayLeaderSessionGate()
        let commandAcquired = await gate.acquireCommand()
        XCTAssertTrue(commandAcquired)

        let healAcquired = AsyncFlag()
        let healTask = Task {
            guard await gate.acquireHeal() else { return }
            await healAcquired.set()
            await gate.releaseHeal()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let healedPrematurely = await healAcquired.read()
        XCTAssertFalse(healedPrematurely)

        await gate.releaseCommand()
        await healTask.value
        let healed = await healAcquired.read()
        XCTAssertTrue(healed)
    }

    func testLeaderSessionGateDoesNotParkNewCommandsBehindHealWaitingOnHungCommand() async {
        let gate = RelayLeaderSessionGate()
        let firstAcquired = await gate.acquireCommand()
        XCTAssertTrue(firstAcquired)

        let healTask = Task {
            guard await gate.acquireHeal() else { return }
            await gate.releaseHeal()
        }
        await waitForLeaderGateWaiters(gate, commands: 0, heals: 1)

        let secondAcquired = await gate.acquireCommand()
        XCTAssertTrue(secondAcquired)
        await gate.releaseCommand()
        await gate.releaseCommand()
        await healTask.value
    }

    func testLeaderSessionGateAllowsConcurrentCommands() async {
        let gate = RelayLeaderSessionGate()
        let firstAcquired = await gate.acquireCommand()
        XCTAssertTrue(firstAcquired)

        let secondCommand = Task { await gate.acquireCommand() }
        let acquired = await secondCommand.value
        XCTAssertTrue(acquired, "one slow leader command must not serialize the next")

        await gate.releaseCommand()
        await gate.releaseCommand()
    }

    func testLeaderSessionGateKeepsNewCommandOutOfHealSwap() async {
        let gate = RelayLeaderSessionGate()
        let healAcquired = await gate.acquireHeal()
        XCTAssertTrue(healAcquired)

        let commandAcquired = AsyncFlag()
        let commandTask = Task {
            guard await gate.acquireCommand() else { return }
            await commandAcquired.set()
            await gate.releaseCommand()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let commandRanPrematurely = await commandAcquired.read()
        XCTAssertFalse(commandRanPrematurely)

        await gate.releaseHeal()
        await commandTask.value
        let commandRan = await commandAcquired.read()
        XCTAssertTrue(commandRan)
    }

    func testLeaderSessionGateCancelledCommandWaiterDoesNotRunOrBlockHeal() async {
        let gate = RelayLeaderSessionGate()
        let initialHeal = await gate.acquireHeal()
        XCTAssertTrue(initialHeal)
        let commandResult = Task { await gate.acquireCommand() }
        await waitForLeaderGateWaiters(gate, commands: 1, heals: 0)
        commandResult.cancel()
        let cancelledCommand = await commandResult.value
        XCTAssertFalse(cancelledCommand)
        await gate.releaseHeal()
        let nextHeal = await gate.acquireHeal()
        XCTAssertTrue(nextHeal)
        await gate.releaseHeal()
    }

    func testLeaderSessionGateCancelledHealWaiterDoesNotBlockCommands() async {
        let gate = RelayLeaderSessionGate()
        let initialCommand = await gate.acquireCommand()
        XCTAssertTrue(initialCommand)
        let healResult = Task { await gate.acquireHeal() }
        await waitForLeaderGateWaiters(gate, commands: 0, heals: 1)
        healResult.cancel()
        let cancelledHeal = await healResult.value
        XCTAssertFalse(cancelledHeal)
        await gate.releaseCommand()
        let nextCommand = await gate.acquireCommand()
        XCTAssertTrue(nextCommand)
        await gate.releaseCommand()
    }

    @MainActor
    func testAdoptedProjectCleanupOwnershipSeparatesOwnerFromViewer() {
        XCTAssertTrue(TeamOrchestrator.adoptedPresentationAllowsRemoteDestruction(
            presentationOwnedByRequester: true
        ))
        XCTAssertFalse(TeamOrchestrator.adoptedPresentationAllowsRemoteDestruction(
            presentationOwnedByRequester: false
        ))
        XCTAssertTrue(TeamOrchestrator.adoptedAgentOwnsRemoteCleanup(
            presentationOwnedByRequester: true,
            surfaceType: "agent"
        ))
        XCTAssertFalse(TeamOrchestrator.adoptedAgentOwnsRemoteCleanup(
            presentationOwnedByRequester: false,
            surfaceType: "agent"
        ))
        XCTAssertFalse(TeamOrchestrator.adoptedAgentOwnsRemoteCleanup(
            presentationOwnedByRequester: true,
            surfaceType: "terminal"
        ))
        XCTAssertTrue(TeamOrchestrator.shouldPersistProjectPresentationSnapshot(
            presentationOwnedByRequester: true
        ))
        XCTAssertFalse(TeamOrchestrator.shouldPersistProjectPresentationSnapshot(
            presentationOwnedByRequester: false
        ))
        let retryDelays = TeamOrchestrator.remoteProjectManifestRetryDelaysNanoseconds
        XCTAssertFalse(retryDelays.isEmpty)
        XCTAssertEqual(retryDelays, retryDelays.sorted())
        XCTAssertLessThanOrEqual(retryDelays.reduce(0, +), 30_000_000_000)
    }

    func testRemotePresentationIdentityIncludesHostAndProjectID() {
        XCTAssertTrue(TeamOrchestrator.remotePresentationIdentityMatches(
            localHostKey: "host-a",
            localProjectID: "name:mesh-test",
            remoteHostKey: "host-a",
            remoteProjectID: "name:mesh-test"
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationIdentityMatches(
            localHostKey: "host-a",
            localProjectID: "name:mesh-test",
            remoteHostKey: "host-b",
            remoteProjectID: "name:mesh-test"
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationIdentityMatches(
            localHostKey: "host-a",
            localProjectID: "project-one",
            remoteHostKey: "host-a",
            remoteProjectID: "project-two"
        ))
    }

    func testOwnerTeamUsesTheSameProjectIDItPublishes() {
        XCTAssertEqual(
            TeamOrchestrator.effectiveRemotePresentationProjectID(
                storedProjectID: nil,
                teamUUID: "F62ADEC6-8149-4BA8-AA0F-86EB3C770A3E",
                teamName: "xm"
            ),
            "team:F62ADEC6-8149-4BA8-AA0F-86EB3C770A3E"
        )
        XCTAssertEqual(
            TeamOrchestrator.effectiveRemotePresentationProjectID(
                storedProjectID: "team:adopted",
                teamUUID: "ignored",
                teamName: "xm"
            ),
            "team:adopted"
        )
        XCTAssertEqual(
            TeamOrchestrator.effectiveRemotePresentationProjectID(
                storedProjectID: nil, teamUUID: nil, teamName: "legacy"
            ),
            "name:legacy"
        )
    }

    @MainActor
    func testSidebarDoesNotOfferOwnersOwnManifestAsDuplicate() {
        let teamUUID = "F62ADEC6-8149-4BA8-AA0F-86EB3C770A3E"
        let team = TeamOrchestrator.Team(
            id: "xm", leaderSessionId: "leader", leaderMode: "claude",
            leaderModel: "opus", leaderCli: "claude",
            leaderPanelId: UUID(), leaderEndpoint: .peer(hostKey: "ssh:mac-sub"),
            workingDirectory: "/work/xm", workspaceId: UUID(),
            agents: [], createdAt: Date(), worktreeMode: "off", teamUuid: teamUUID,
            ownsRemotePresentation: true
        )
        let same = RemoteTeamSummary(
            name: "xm", teamUUID: teamUUID, workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [],
            projectID: "team:\(teamUUID)", leaderSurfaceID: Data(repeating: 1, count: 16),
            presentationRevision: 5, presentationOwnedByRequester: true
        )
        let sameState = TeamOrchestrator.sidebarRemoteManifestState(
            localTeam: team, remote: same, hostKey: "ssh:mac-sub"
        )
        XCTAssertFalse(sameState.shouldOffer)
        XCTAssertTrue(sameState.isUpdate)

        let stale = RemoteTeamSummary(
            name: "xm", teamUUID: "old", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [], projectID: "team:old",
            leaderSurfaceID: Data(repeating: 2, count: 16),
            presentationRevision: 5, presentationOwnedByRequester: true
        )
        let staleState = TeamOrchestrator.sidebarRemoteManifestState(
            localTeam: team, remote: stale, hostKey: "ssh:mac-sub"
        )
        XCTAssertTrue(staleState.shouldOffer)
        XCTAssertFalse(staleState.isUpdate, "same display name is not an update identity")
    }

    /// A Mac peer serves workspaces from its GUI socket, which carries no
    /// project manifest, so the Host axis has to list the session owner's
    /// manifests itself or the machine that runs a Project shows no sign of it.
    @MainActor
    func testHostAxisOffersManifestsTheProjectAxisWouldOffer() {
        let adoptedUUID = "6D0BB300-6622-418F-97BC-AB81C92AF46B"
        let adopted = TeamOrchestrator.Team(
            id: "term-mesh2", leaderSessionId: "leader", leaderMode: "claude",
            leaderModel: "opus", leaderCli: "claude",
            leaderPanelId: UUID(), leaderEndpoint: .peer(hostKey: "ssh:mac-sub"),
            workingDirectory: "/Users/jinwoo", workspaceId: UUID(),
            agents: [], createdAt: Date(), worktreeMode: "off",
            teamUuid: adoptedUUID, ownsRemotePresentation: true
        )
        let alreadyAdopted = RemoteTeamSummary(
            name: "term-mesh2", teamUUID: adoptedUUID,
            workingDirectory: "/Users/jinwoo", projectRootPath: nil,
            agentNames: [], projectID: "team:\(adoptedUUID)",
            leaderSurfaceID: Data(repeating: 3, count: 16),
            presentationRevision: 5, presentationOwnedByRequester: true
        )
        let notAdopted = RemoteTeamSummary(
            name: "term-mesh3", teamUUID: "F5FCE2C8-8B07-42EA-AF87-2727DDAEC90F",
            workingDirectory: "/Users/jinwoo", projectRootPath: nil,
            agentNames: [], projectID: "team:F5FCE2C8-8B07-42EA-AF87-2727DDAEC90F",
            leaderSurfaceID: Data(repeating: 4, count: 16),
            presentationRevision: 1, presentationOwnedByRequester: true
        )
        // A manifest whose leader surface died is not attachable; the daemon
        // stops reporting it, and a stale copy must not become a dead row.
        let leaderless = RemoteTeamSummary(
            name: "term-mesh", teamUUID: "16890533-11D3-4FB9-B1F3-0C77E3341A6E",
            workingDirectory: "/Users/jinwoo", projectRootPath: nil,
            agentNames: [], projectID: "team:16890533-11D3-4FB9-B1F3-0C77E3341A6E",
            leaderSurfaceID: Data(),
            presentationRevision: 8, presentationOwnedByRequester: true
        )
        let teams = [alreadyAdopted, notAdopted, leaderless]
        let localTeams = ["term-mesh2": adopted]

        let offered = TeamOrchestrator.hostAxisOfferedManifests(
            isConnected: true, teams: teams, hostKey: "ssh:mac-sub",
            localTeamForName: { localTeams[$0] }
        )
        XCTAssertEqual(offered.map(\.name), ["term-mesh3"])

        XCTAssertTrue(
            TeamOrchestrator.hostAxisOfferedManifests(
                isConnected: false, teams: teams, hostKey: "ssh:mac-sub",
                localTeamForName: { localTeams[$0] }
            ).isEmpty,
            "a disconnected host cannot attach anything it last reported"
        )

        // Both production axes call this helper; pin deterministic ordering so
        // roster refreshes cannot visually shuffle the same project rows.
        let second = RemoteTeamSummary(
            name: "Alpha", teamUUID: "AAAAA2C8-8B07-42EA-AF87-2727DDAEC90F",
            workingDirectory: "/Users/jinwoo", projectRootPath: nil,
            agentNames: [], projectID: "team:alpha",
            leaderSurfaceID: Data(repeating: 5, count: 16),
            presentationRevision: 1, presentationOwnedByRequester: true
        )
        let sorted = TeamOrchestrator.hostAxisOfferedManifests(
            isConnected: true, teams: [notAdopted, second], hostKey: "ssh:mac-sub",
            localTeamForName: { localTeams[$0] }
        )
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "term-mesh3"])
    }

    func testKnownInactiveRemoteManifestIsNeitherOfferedNorAdoptable() {
        func manifest(
            name: String, active: Bool, activeKnown: Bool
        ) -> RemoteTeamSummary {
            RemoteTeamSummary(
                name: name, teamUUID: name, workingDirectory: "/work/\(name)",
                projectRootPath: nil, agentNames: [], projectID: "team:\(name)",
                leaderSurfaceID: Data(repeating: 0x44, count: 16),
                leaderProcessActive: active, leaderProcessActiveKnown: activeKnown
            )
        }

        let inactive = manifest(name: "inactive", active: false, activeKnown: true)
        let live = manifest(name: "live", active: true, activeKnown: true)
        let unknown = manifest(name: "unknown", active: false, activeKnown: false)

        XCTAssertFalse(TeamOrchestrator.remoteManifestLeaderIsAdoptable(inactive))
        XCTAssertTrue(TeamOrchestrator.remoteManifestLeaderIsAdoptable(live))
        XCTAssertTrue(
            TeamOrchestrator.remoteManifestLeaderIsAdoptable(unknown),
            "legacy/unknown state preserves the existing conservative offer policy"
        )
        XCTAssertEqual(
            TeamOrchestrator.hostAxisOfferedManifests(
                isConnected: true, teams: [unknown, inactive, live],
                hostKey: "ssh:mac-sub", localTeamForName: { _ in nil }
            ).map(\.name),
            ["live", "unknown"]
        )
    }

    func testRemoteManifestUIKeySeparatesHostsAndProjects() {
        let first = RemoteTeamSummary(
            name: "same-name", teamUUID: "one", workingDirectory: "/work",
            projectRootPath: nil, agentNames: [], projectID: "project-one"
        )
        let second = RemoteTeamSummary(
            name: "same-name", teamUUID: "two", workingDirectory: "/work",
            projectRootPath: nil, agentNames: [], projectID: "project-two"
        )
        XCTAssertNotEqual(
            TeamOrchestrator.sidebarRemoteManifestKey(hostID: "host-a", team: first),
            TeamOrchestrator.sidebarRemoteManifestKey(hostID: "host-b", team: first)
        )
        XCTAssertNotEqual(
            TeamOrchestrator.sidebarRemoteManifestKey(hostID: "host-a", team: first),
            TeamOrchestrator.sidebarRemoteManifestKey(hostID: "host-a", team: second)
        )
    }

    @MainActor
    func testAutomaticRestoreChoosesExactLatestOwnedLeaderRecord() {
        let oldID = Data(repeating: 0x11, count: 16)
        let currentID = Data(repeating: 0x22, count: 16)
        let record = ManagedPeerSurfaceStore.Record(
            hostKey: "ssh:mac-sub",
            surfaceIDBase64: currentID.base64EncodedString(),
            teamName: "term-mesh",
            role: "leader",
            workingDirectory: "/work/term-mesh",
            createdAt: Date()
        )
        let stale = RemoteTeamSummary(
            name: "term-mesh", teamUUID: "old", workingDirectory: "/old",
            projectRootPath: nil, agentNames: [], projectID: "team:old",
            leaderSurfaceID: oldID, presentationRevision: 99,
            presentationOwnedByRequester: true
        )
        let current = RemoteTeamSummary(
            name: "term-mesh", teamUUID: "current", workingDirectory: "/current",
            projectRootPath: nil, agentNames: [], projectID: "team:current",
            leaderSurfaceID: currentID, presentationRevision: 7,
            presentationOwnedByRequester: true
        )
        let foreign = RemoteTeamSummary(
            name: "term-mesh", teamUUID: "foreign", workingDirectory: "/foreign",
            projectRootPath: nil, agentNames: [], projectID: "team:foreign",
            leaderSurfaceID: currentID, presentationRevision: 100,
            presentationOwnedByRequester: false
        )

        XCTAssertEqual(
            TeamOrchestrator.automaticRemoteProjectRestoreCandidate(
                in: [stale, foreign, current], leaderRecord: record
            )?.projectID,
            "team:current"
        )
        XCTAssertNil(TeamOrchestrator.automaticRemoteProjectRestoreCandidate(
            in: [stale], leaderRecord: record
        ))
    }

    func testAutomaticRestoreWithoutLocalRecordRequiresOneOwnedIdentity() {
        let current = RemoteTeamSummary(
            name: "term-mesh", teamUUID: "current", workingDirectory: "/current",
            projectRootPath: nil, agentNames: [], projectID: "team:current",
            leaderSurfaceID: Data(repeating: 1, count: 16), presentationRevision: 7,
            presentationOwnedByRequester: true
        )
        let newerRevision = RemoteTeamSummary(
            name: "term-mesh", teamUUID: "current", workingDirectory: "/current",
            projectRootPath: nil, agentNames: [], projectID: "team:current",
            leaderSurfaceID: Data(repeating: 1, count: 16), presentationRevision: 8,
            presentationOwnedByRequester: true
        )
        XCTAssertEqual(
            TeamOrchestrator.automaticRemoteProjectRestoreCandidate(
                in: [current, newerRevision], leaderRecord: nil
            )?.presentationRevision,
            8
        )

        let ambiguous = RemoteTeamSummary(
            name: "term-mesh", teamUUID: "other", workingDirectory: "/other",
            projectRootPath: nil, agentNames: [], projectID: "team:other",
            leaderSurfaceID: Data(repeating: 2, count: 16), presentationRevision: 9,
            presentationOwnedByRequester: true
        )
        XCTAssertNil(TeamOrchestrator.automaticRemoteProjectRestoreCandidate(
            in: [current, ambiguous], leaderRecord: nil
        ))
    }

    func testAutomaticRemoteRepairPlaceholderRequiresExactOwnedKnownDeadManifest() {
        let leaderID = Data(repeating: 0x71, count: 16)
        let dead = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: ["executor"],
            projectID: "team:uuid", leaderSurfaceID: leaderID,
            presentationOwnedByRequester: true,
            leaderProcessActive: false, leaderProcessActiveKnown: true
        )
        XCTAssertEqual(
            TeamOrchestrator.automaticRemoteProjectRepairPlaceholderCandidate(
                in: [dead], leaderRecord: nil
            ), dead
        )

        let unknown = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [], projectID: "team:uuid",
            leaderSurfaceID: leaderID, presentationOwnedByRequester: true
        )
        let live = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [], projectID: "team:uuid",
            leaderSurfaceID: leaderID, presentationOwnedByRequester: true,
            leaderProcessActive: true, leaderProcessActiveKnown: true
        )
        XCTAssertNil(TeamOrchestrator.automaticRemoteProjectRepairPlaceholderCandidate(
            in: [unknown], leaderRecord: nil
        ))
        XCTAssertEqual(
            TeamOrchestrator.exactRemoteRepairPlaceholderCandidate(
                in: [live, dead], teamName: "xm",
                teamUUID: "uuid", projectID: "team:uuid"
            ),
            dead
        )
        XCTAssertNil(TeamOrchestrator.exactRemoteRepairPlaceholderCandidate(
            in: [dead, dead], teamName: "xm",
            teamUUID: "uuid", projectID: "team:uuid"
        ))
        var local = TeamOrchestrator.Team(
            id: "xm", leaderSessionId: "leader", leaderMode: "claude",
            leaderModel: "opus", leaderCli: "claude",
            leaderPanelId: UUID(),
            leaderEndpoint: .peer(hostKey: "ssh:mac-sub"),
            workingDirectory: "/work/xm", workspaceId: UUID(),
            agents: [], createdAt: Date(), worktreeMode: "off",
            teamUuid: "uuid", remotePresentationProjectID: "team:uuid"
        )
        XCTAssertTrue(TeamOrchestrator.exactRepairIdentityMatches(
            team: local, hostKey: "ssh:mac-sub",
            teamUUID: "uuid", projectID: "team:uuid"
        ))
        XCTAssertFalse(TeamOrchestrator.exactRepairIdentityMatches(
            team: local, hostKey: "ssh:other",
            teamUUID: "uuid", projectID: "team:uuid"
        ))
        XCTAssertEqual(
            TeamOrchestrator.exactRepairInput(params: ["team_name": "xm"]),
            .omitted
        )
        XCTAssertEqual(
            TeamOrchestrator.exactRepairInput(params: [
                "team_name": "xm", "host_key": 123,
            ]),
            .invalid
        )
        XCTAssertEqual(
            TeamOrchestrator.exactRepairInput(params: [
                "team_name": "xm", "host_key": "ssh:mac-sub",
                "team_uuid": "uuid", "project_id": "team:uuid",
            ]),
            .valid(.init(
                hostKey: "ssh:mac-sub", teamUUID: "uuid",
                projectID: "team:uuid"
            ))
        )
        local.teamUuid = "other"
        XCTAssertFalse(TeamOrchestrator.exactRepairIdentityMatches(
            team: local, hostKey: "ssh:mac-sub",
            teamUUID: "uuid", projectID: "team:uuid"
        ))
        XCTAssertNil(TeamOrchestrator.exactRemoteRepairPlaceholderCandidate(
            in: [unknown], teamName: "xm",
            teamUUID: "uuid", projectID: "team:uuid"
        ))
        XCTAssertNil(TeamOrchestrator.exactRemoteRepairPlaceholderCandidate(
            in: [dead], teamName: "xm",
            teamUUID: "wrong", projectID: "team:uuid"
        ))
        XCTAssertNil(TeamOrchestrator.automaticRemoteProjectRepairPlaceholderCandidate(
            in: [live], leaderRecord: nil
        ))
        XCTAssertNil(TeamOrchestrator.automaticRemoteProjectRepairPlaceholderCandidate(
            in: [dead, RemoteTeamSummary(
                name: "xm", teamUUID: "other", workingDirectory: "/other",
                projectRootPath: nil, agentNames: [], projectID: "team:other",
                leaderSurfaceID: Data(repeating: 0x72, count: 16),
                presentationOwnedByRequester: true,
                leaderProcessActiveKnown: true
            )], leaderRecord: nil
        ))
    }

    func testRemoteRepairPlaceholderPreservesDurableTopologyWithoutPanels() throws {
        let leaderID = Data(repeating: 0x73, count: 16)
        let workerID = Data(repeating: 0x74, count: 16)
        let delegation = ProjectDelegationState(
            configuredRaw: "parallel", effectiveRaw: "parallel", pendingRaw: ""
        )
        let remote = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: "/work/xm", agentNames: ["executor"],
            projectID: "team:uuid", leaderSurfaceID: leaderID,
            leaderCLI: "codex", leaderModel: "gpt-5.6-sol",
            members: [.init(
                name: "executor", agentInstanceID: "worker-instance",
                cli: "claude", model: "sonnet", agentType: "executor",
                color: "blue", workingDirectory: "/work/xm-agent",
                surfaceID: workerID, surfaceType: "agent"
            )],
            presentationRevision: 17, presentationOwnedByRequester: true,
            leaderProcessActive: false, leaderProcessActiveKnown: true,
            delegationState: delegation
        )

        let team = try XCTUnwrap(TeamOrchestrator.remoteProjectRepairPlaceholder(
            remote: remote, hostKey: "ssh:mac-sub"
        ))
        XCTAssertTrue(team.isRemoteRepairPlaceholder)
        XCTAssertTrue(team.ownsRemotePresentation)
        XCTAssertFalse(team.leaderReady)
        XCTAssertEqual(team.teamUuid, "uuid")
        XCTAssertEqual(team.remotePresentationProjectID, "team:uuid")
        XCTAssertEqual(team.remotePresentationHostKey, "ssh:mac-sub")
        XCTAssertEqual(team.remoteLeaderSurfaceID, leaderID)
        XCTAssertEqual(team.leaderCli, "codex")
        XCTAssertEqual(team.leaderModel, "gpt-5.6-sol")
        XCTAssertEqual(team.delegationState, delegation)
        XCTAssertEqual(team.agents.count, 1)
        XCTAssertEqual(team.agents[0].agentInstanceId, "worker-instance")
        XCTAssertEqual(team.agents[0].remoteSurfaceID, workerID)
        XCTAssertEqual(team.agents[0].hostKey, "ssh:mac-sub")
        XCTAssertNil(team.agents[0].panelId)
    }

    @MainActor
    func testInstallingRemoteRepairPlaceholderRegistersDurableRoutingState() throws {
        let teamName = "repair-placeholder-\(UUID().uuidString)"
        defer {
            TeamOrchestrator.shared.teams.removeValue(forKey: teamName)
            TeamDataStore.shared.unregisterTeam(teamName)
        }
        let remote = RemoteTeamSummary(
            name: teamName, teamUUID: "durable-team", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: ["executor"],
            projectID: "team:durable-team",
            leaderSurfaceID: Data(repeating: 0x75, count: 16),
            members: [.init(
                name: "executor", agentInstanceID: "durable-worker",
                cli: "claude", model: "sonnet", agentType: "executor",
                color: "blue", workingDirectory: "/work/xm",
                surfaceID: Data(repeating: 0x76, count: 16), surfaceType: "agent"
            )],
            presentationOwnedByRequester: true,
            leaderProcessActiveKnown: true,
            delegationState: .init(
                configuredRaw: "parallel", effectiveRaw: "parallel", pendingRaw: ""
            )
        )
        let placeholder = try XCTUnwrap(
            TeamOrchestrator.remoteProjectRepairPlaceholder(
                remote: remote, hostKey: "ssh:mac-sub"
            )
        )

        XCTAssertTrue(
            TeamOrchestrator.shared.installRemoteProjectRepairPlaceholder(placeholder)
        )
        XCTAssertEqual(
            TeamDataStore.shared.agentInstanceId(
                teamName: teamName, agentName: "executor"
            ),
            "durable-worker"
        )
        XCTAssertEqual(
            TeamDataStore.shared.projectDelegationState(teamName: teamName),
            remote.delegationState
        )
        XCTAssertFalse(
            TeamOrchestrator.shared.installRemoteProjectRepairPlaceholder(placeholder)
        )
    }

    func testAutomaticRestoreFailureKeyChangesWithSocketOrRevision() {
        let base = TeamOrchestrator.automaticProjectRestoreFailureKey(
            hostID: "host", activeSockPath: "/tmp/one.sock",
            projectID: "team:one", revision: 7
        )
        XCTAssertEqual(base, TeamOrchestrator.automaticProjectRestoreFailureKey(
            hostID: "host", activeSockPath: "/tmp/one.sock",
            projectID: "team:one", revision: 7
        ))
        XCTAssertNotEqual(base, TeamOrchestrator.automaticProjectRestoreFailureKey(
            hostID: "host", activeSockPath: "/tmp/two.sock",
            projectID: "team:one", revision: 7
        ))
        XCTAssertNotEqual(base, TeamOrchestrator.automaticProjectRestoreFailureKey(
            hostID: "host", activeSockPath: "/tmp/one.sock",
            projectID: "team:one", revision: 8
        ))
    }

    func testAutomaticRestoreRetriesWithBoundedBackoff() {
        XCTAssertEqual(
            TeamOrchestrator.automaticProjectRestoreRetryDelayNanoseconds(afterFailureCount: 1),
            1_000_000_000
        )
        XCTAssertEqual(
            TeamOrchestrator.automaticProjectRestoreRetryDelayNanoseconds(afterFailureCount: 2),
            2_000_000_000
        )
        XCTAssertEqual(
            TeamOrchestrator.automaticProjectRestoreRetryDelayNanoseconds(afterFailureCount: 3),
            4_000_000_000
        )
        XCTAssertNil(
            TeamOrchestrator.automaticProjectRestoreRetryDelayNanoseconds(afterFailureCount: 4)
        )
    }

    func testRemoteProjectPresentationIDUsesStableUUIDInsteadOfDisplayName() {
        XCTAssertEqual(
            TeamOrchestrator.remoteProjectPresentationID(teamUUID: "uuid-a"),
            "team:uuid-a"
        )
        XCTAssertNotEqual(
            TeamOrchestrator.remoteProjectPresentationID(teamUUID: "uuid-a"),
            TeamOrchestrator.remoteProjectPresentationID(teamUUID: "uuid-b")
        )
    }

    func testProjectLayoutCapturesSurfaceIDsAndDividerTree() throws {
        let leader = Data(repeating: 0x11, count: 16)
        let worker = Data(repeating: 0x22, count: 16)
        let leaderTab = UUID().uuidString
        let workerTab = UUID().uuidString
        let frame = PixelRect(x: 0, y: 0, width: 100, height: 100)
        let tree = ExternalTreeNode.split(ExternalSplitNode(
            id: UUID().uuidString,
            orientation: "horizontal",
            dividerPosition: 0.37,
            first: .pane(ExternalPaneNode(
                id: UUID().uuidString, frame: frame,
                tabs: [ExternalTab(id: leaderTab, title: "Leader")],
                selectedTabId: leaderTab
            )),
            second: .pane(ExternalPaneNode(
                id: UUID().uuidString, frame: frame,
                tabs: [ExternalTab(id: workerTab, title: "Worker")],
                selectedTabId: workerTab
            ))
        ))

        let snapshot = try XCTUnwrap(ProjectPresentationLayoutSnapshot.capture(
            projectID: "team:layout",
            tree: tree,
            surfaceIDByTabID: [leaderTab: leader, workerTab: worker],
            focusedSurfaceID: worker
        ))
        let roundTrip = try JSONDecoder().decode(
            ProjectPresentationLayoutSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(roundTrip, snapshot)
        XCTAssertEqual(roundTrip.surfaceIDs, [leader, worker])
        XCTAssertTrue(roundTrip.canApply(to: [leader, worker]))
        XCTAssertFalse(roundTrip.canApply(to: [leader]))
        guard case .split(let orientation, let divider, _, _) = roundTrip.root else {
            return XCTFail("expected split root")
        }
        XCTAssertEqual(orientation, .horizontal)
        XCTAssertEqual(divider, 0.37, accuracy: 0.0001)
    }

    func testProjectLayoutRejectsPartialAndMultiTabLeaves() {
        let first = Data([0x01])
        let second = Data([0x02])
        let duplicate = ProjectPresentationLayoutSnapshot(
            projectID: "team:duplicate",
            root: .split(
                orientation: .vertical, dividerPosition: 0.5,
                first: .pane(.init(surfaceID: first)),
                second: .pane(.init(surfaceID: first))
            ),
            focusedSurfaceID: first
        )
        XCTAssertFalse(duplicate.isValid)

        let badGeometry = ProjectPresentationLayoutSnapshot(
            projectID: "team:bad-geometry",
            root: .split(
                orientation: .horizontal, dividerPosition: 1.5,
                first: .pane(.init(surfaceID: first)),
                second: .pane(.init(surfaceID: second))
            ),
            focusedSurfaceID: first
        )
        XCTAssertFalse(badGeometry.isValid)
    }

    func testProjectLayoutDividerValidationMatchesRestoreRange() {
        let first = Data([0x01])
        let second = Data([0x02])
        let snapshot: (Double) -> ProjectPresentationLayoutSnapshot = { dividerPosition in
            ProjectPresentationLayoutSnapshot(
                projectID: "team:divider-boundary",
                root: .split(
                    orientation: .horizontal, dividerPosition: dividerPosition,
                    first: .pane(.init(surfaceID: first)),
                    second: .pane(.init(surfaceID: second))
                ),
                focusedSurfaceID: first
            )
        }

        XCTAssertFalse(snapshot(0).isValid)
        XCTAssertTrue(snapshot(0.1).isValid)
        XCTAssertTrue(snapshot(0.9).isValid)
        XCTAssertFalse(snapshot(1).isValid)
    }

    @MainActor
    func testCanonicalProjectFallbackBuildsLeaderAndAgentGrid() throws {
        let workspace = Workspace(title: "canonical-project-grid")
        let leader = try XCTUnwrap(workspace.focusedPanelId)
        var agents: [UUID] = []
        var splitFrom = leader
        for _ in 0..<4 {
            let panel = try XCTUnwrap(workspace.newTerminalSplit(
                from: splitFrom, orientation: .horizontal, focus: false
            )?.id)
            agents.append(panel)
            splitFrom = panel
        }

        XCTAssertTrue(workspace.applyCanonicalProjectPresentationGrid(
            leaderPanelID: leader, agentPanelIDs: agents,
            columnCount: 2, focusedSurfaceID: nil, restoreFocus: false
        ))
        guard case .split(let root) = workspace.bonsplitController.treeSnapshot(),
              case .pane = root.first,
              case .split(let agentColumns) = root.second,
              case .split(let firstColumn) = agentColumns.first,
              case .split(let secondColumn) = agentColumns.second
        else {
            return XCTFail("expected leader | 2x2 agent grid")
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 0.5, accuracy: 0.001)
        XCTAssertEqual(agentColumns.orientation, "horizontal")
        XCTAssertEqual(firstColumn.orientation, "vertical")
        XCTAssertEqual(secondColumn.orientation, "vertical")
    }

    @MainActor
    func testCanonicalProjectFallbackRestoresRequestedFocus() throws {
        let workspace = Workspace(title: "canonical-project-focus")
        let leader = try XCTUnwrap(workspace.focusedPanelId)
        let firstAgent = try XCTUnwrap(workspace.newTerminalSplit(
            from: leader, orientation: .horizontal, focus: false
        )?.id)
        let secondAgent = try XCTUnwrap(workspace.newTerminalSplit(
            from: firstAgent, orientation: .horizontal, focus: false
        )?.id)
        let leaderSurface = Data(repeating: 0x10, count: 16)
        let firstSurface = Data(repeating: 0x11, count: 16)
        let secondSurface = Data(repeating: 0x12, count: 16)
        workspace.debugProjectLayoutSurfaceIDs = [
            leader: leaderSurface, firstAgent: firstSurface, secondAgent: secondSurface,
        ]

        XCTAssertTrue(workspace.applyCanonicalProjectPresentationGrid(
            leaderPanelID: leader,
            agentPanelIDs: [firstAgent, secondAgent],
            columnCount: 1,
            focusedSurfaceID: secondSurface,
            restoreFocus: true
        ))
        XCTAssertEqual(workspace.focusedPanelId, secondAgent)
    }

    @MainActor
    func testCanonicalProjectFallbackSupportsLeaderOnlyProject() throws {
        let workspace = Workspace(title: "canonical-project-leader-only")
        let leader = try XCTUnwrap(workspace.focusedPanelId)
        let leaderSurface = Data(repeating: 0x13, count: 16)
        workspace.debugProjectLayoutSurfaceIDs = [leader: leaderSurface]

        XCTAssertTrue(workspace.applyCanonicalProjectPresentationGrid(
            leaderPanelID: leader,
            agentPanelIDs: [],
            columnCount: 1,
            focusedSurfaceID: leaderSurface,
            restoreFocus: true
        ))
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 1)
        XCTAssertEqual(workspace.focusedPanelId, leader)
    }

    @MainActor
    func testProjectRestoreRebuildsStaleRosterAfterCommitAndRestoresFocus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-restore-test-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectPresentationLayoutStore(
            fileURL: directory.appendingPathComponent("layouts.json")
        )
        let workspace = Workspace(title: "project-restore-stale-roster")
        let anchor = try XCTUnwrap(workspace.focusedPanelId)
        let leader = try XCTUnwrap(workspace.newTerminalSplit(
            from: anchor, orientation: .horizontal, focus: false
        )?.id)
        let firstAgent = try XCTUnwrap(workspace.newTerminalSplit(
            from: leader, orientation: .horizontal, focus: false
        )?.id)
        let secondAgent = try XCTUnwrap(workspace.newTerminalSplit(
            from: firstAgent, orientation: .horizontal, focus: false
        )?.id)
        let leaderSurface = Data(repeating: 0x20, count: 16)
        let firstSurface = Data(repeating: 0x21, count: 16)
        let secondSurface = Data(repeating: 0x22, count: 16)
        let retiredSurface = Data(repeating: 0x23, count: 16)
        workspace.debugProjectLayoutSurfaceIDs = [
            leader: leaderSurface, firstAgent: firstSurface, secondAgent: secondSurface,
        ]
        let projectID = "team:stale-roster"
        let stale = ProjectPresentationLayoutSnapshot(
            projectID: projectID,
            root: .split(
                orientation: .horizontal, dividerPosition: 0.4,
                first: .pane(.init(surfaceID: leaderSurface)),
                second: .split(
                    orientation: .vertical, dividerPosition: 0.6,
                    first: .pane(.init(surfaceID: firstSurface)),
                    second: .pane(.init(surfaceID: retiredSurface))
                )
            ),
            focusedSurfaceID: firstSurface
        )
        store.save(stale)

        let outcome = TeamOrchestrator.shared.finalizeRestoredProjectLayout(
            projectID: projectID,
            workspace: workspace,
            anchorPanelID: anchor,
            leaderPanelID: leader,
            agentPanelIDs: [firstAgent, secondAgent],
            restoreFocus: true,
            layoutStore: store
        )

        XCTAssertEqual(outcome, .rebuiltCanonical)
        let rebuilt = try XCTUnwrap(store.snapshot(projectID: projectID))
        XCTAssertEqual(rebuilt.surfaceIDs, [leaderSurface, firstSurface, secondSurface])
        XCTAssertEqual(rebuilt.focusedSurfaceID, firstSurface)
        XCTAssertNil(workspace.panels[anchor])
        XCTAssertEqual(workspace.focusedPanelId, firstAgent)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 3)
    }

    @MainActor
    func testExplicitProjectLayoutResetReplacesBrokenSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-layout-reset-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectPresentationLayoutStore(
            fileURL: directory.appendingPathComponent("layouts.json")
        )
        let workspace = Workspace(title: "explicit-layout-reset")
        let leader = try XCTUnwrap(workspace.focusedPanelId)
        var agents: [UUID] = []
        var splitFrom = leader
        for _ in 0..<4 {
            let panel = try XCTUnwrap(workspace.newTerminalSplit(
                from: splitFrom, orientation: .horizontal, focus: false
            )?.id)
            agents.append(panel)
            splitFrom = panel
        }
        let surfaces = (0..<5).map { Data(repeating: UInt8(0x40 + $0), count: 16) }
        workspace.debugProjectLayoutSurfaceIDs = Dictionary(
            uniqueKeysWithValues: zip([leader] + agents, surfaces)
        )
        let projectID = "team:explicit-reset"
        store.save(try XCTUnwrap(workspace.projectPresentationLayoutSnapshot(projectID: projectID)))

        XCTAssertTrue(TeamOrchestrator.shared.rebuildCanonicalProjectPresentationLayout(
            projectID: projectID,
            workspace: workspace,
            leaderPanelID: leader,
            agentPanelIDs: agents,
            focusedSurfaceID: surfaces[3],
            restoreFocus: true,
            layoutStore: store
        ))
        let reset = try XCTUnwrap(store.snapshot(projectID: projectID))
        XCTAssertEqual(reset.surfaceIDs, Set(surfaces))
        XCTAssertEqual(reset.focusedSurfaceID, surfaces[3])
        guard case .split(let root) = reset.root,
              case .pane = root.first,
              case .split(let agentColumns) = root.second
        else { return XCTFail("expected canonical leader | agent-grid topology") }
        XCTAssertEqual(root.orientation, .horizontal)
        XCTAssertEqual(agentColumns.orientation, .horizontal)
    }

    @MainActor
    func testCanonicalRebuildRefusesUnknownPanelWithoutMutatingTree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-layout-reset-refusal-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectPresentationLayoutStore(
            fileURL: directory.appendingPathComponent("layouts.json")
        )
        let workspace = Workspace(title: "explicit-layout-reset-refusal")
        let leader = try XCTUnwrap(workspace.focusedPanelId)
        let before = workspace.bonsplitController.treeSnapshot()

        XCTAssertFalse(TeamOrchestrator.shared.rebuildCanonicalProjectPresentationLayout(
            projectID: "team:refused-reset",
            workspace: workspace,
            leaderPanelID: leader,
            agentPanelIDs: [UUID()],
            focusedSurfaceID: nil,
            restoreFocus: true,
            layoutStore: store
        ))
        XCTAssertEqual(workspace.bonsplitController.treeSnapshot(), before)
        XCTAssertNil(store.snapshot(projectID: "team:refused-reset"))
    }

    @MainActor
    func testProjectRestoreKeepsStaleSnapshotWhenCanonicalCommitFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-restore-failure-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectPresentationLayoutStore(
            fileURL: directory.appendingPathComponent("layouts.json")
        )
        let workspace = Workspace(title: "project-restore-failure")
        let leader = try XCTUnwrap(workspace.focusedPanelId)
        let leaderSurface = Data(repeating: 0x30, count: 16)
        let retiredSurface = Data(repeating: 0x31, count: 16)
        workspace.debugProjectLayoutSurfaceIDs = [leader: leaderSurface]
        let projectID = "team:failed-rebuild"
        let stale = ProjectPresentationLayoutSnapshot(
            projectID: projectID,
            root: .split(
                orientation: .horizontal, dividerPosition: 0.5,
                first: .pane(.init(surfaceID: leaderSurface)),
                second: .pane(.init(surfaceID: retiredSurface))
            ),
            focusedSurfaceID: leaderSurface
        )
        store.save(stale)

        let outcome = TeamOrchestrator.shared.finalizeRestoredProjectLayout(
            projectID: projectID,
            workspace: workspace,
            anchorPanelID: nil,
            leaderPanelID: leader,
            agentPanelIDs: [UUID()],
            restoreFocus: true,
            layoutStore: store
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(store.snapshot(projectID: projectID), stale)
    }

    @MainActor
    func testProjectLayoutReordersLivePanelsAndRestoresNestedDividers() throws {
        let workspace = Workspace(title: "layout-test")
        let firstPanel = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: firstPanel, orientation: .vertical, focus: false
        )?.id)
        let thirdPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: secondPanel, orientation: .horizontal, focus: false
        )?.id)
        let a = Data(repeating: 0xa1, count: 16)
        let b = Data(repeating: 0xb2, count: 16)
        let c = Data(repeating: 0xc3, count: 16)
        workspace.debugProjectLayoutSurfaceIDs = [
            firstPanel: a, secondPanel: b, thirdPanel: c,
        ]
        let pane: (Data) -> ProjectPresentationLayoutSnapshot.Node = { surfaceID in
            .pane(.init(surfaceID: surfaceID))
        }
        let desired = ProjectPresentationLayoutSnapshot(
            projectID: "team:live-layout",
            root: .split(
                orientation: .horizontal, dividerPosition: 0.31,
                first: pane(c),
                second: .split(
                    orientation: .vertical, dividerPosition: 0.64,
                    first: pane(a), second: pane(b)
                )
            ),
            focusedSurfaceID: b
        )

        XCTAssertTrue(workspace.applyProjectPresentationLayout(desired, restoreFocus: true))
        let actual = try XCTUnwrap(workspace.projectPresentationLayoutSnapshot(
            projectID: desired.projectID
        ))
        XCTAssertEqual(actual.root.surfaceIDs, [c, a, b])
        XCTAssertEqual(actual.focusedSurfaceID, b)
        guard case .split(let rootOrientation, let rootDivider, _, let second) = actual.root,
              case .split(let nestedOrientation, let nestedDivider, _, _) = second else {
            return XCTFail("expected nested split tree")
        }
        XCTAssertEqual(rootOrientation, .horizontal)
        XCTAssertEqual(rootDivider, 0.31, accuracy: 0.01)
        XCTAssertEqual(nestedOrientation, .vertical)
        XCTAssertEqual(nestedDivider, 0.64, accuracy: 0.01)
    }

    @MainActor
    func testProjectLayoutMismatchDoesNotMutateLiveTree() throws {
        let workspace = Workspace(title: "layout-mismatch")
        let firstPanel = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: firstPanel, orientation: .horizontal, focus: false
        )?.id)
        let a = Data([0x01])
        let b = Data([0x02])
        workspace.debugProjectLayoutSurfaceIDs = [firstPanel: a, secondPanel: b]
        let before = workspace.bonsplitController.treeSnapshot()
        let stale = ProjectPresentationLayoutSnapshot(
            projectID: "team:stale",
            root: .pane(.init(surfaceID: a)),
            focusedSurfaceID: a
        )

        XCTAssertFalse(workspace.applyProjectPresentationLayout(stale, restoreFocus: false))
        XCTAssertEqual(workspace.bonsplitController.treeSnapshot(), before)
    }

    @MainActor
    func testAtomicExternalTreeRejectsDuplicateTabsWithoutMutation() throws {
        let workspace = Workspace(title: "atomic-layout")
        let firstPanel = try XCTUnwrap(workspace.focusedPanelId)
        _ = try XCTUnwrap(workspace.newTerminalSplit(
            from: firstPanel, orientation: .horizontal, focus: false
        ))
        let before = workspace.bonsplitController.treeSnapshot()
        let tabID = try XCTUnwrap(workspace.bonsplitController.allTabIds.first)
        let frame = PixelRect(x: 0, y: 0, width: 0, height: 0)
        let duplicate = ExternalTreeNode.split(ExternalSplitNode(
            id: UUID().uuidString, orientation: "horizontal", dividerPosition: 0.4,
            first: .pane(ExternalPaneNode(
                id: UUID().uuidString, frame: frame,
                tabs: [ExternalTab(id: tabID.uuid.uuidString, title: "A")],
                selectedTabId: tabID.uuid.uuidString
            )),
            second: .pane(ExternalPaneNode(
                id: UUID().uuidString, frame: frame,
                tabs: [ExternalTab(id: tabID.uuid.uuidString, title: "A")],
                selectedTabId: tabID.uuid.uuidString
            ))
        ))

        XCTAssertFalse(workspace.bonsplitController.applyExternalTreeAtomically(duplicate))
        XCTAssertEqual(workspace.bonsplitController.treeSnapshot(), before)
    }

    @MainActor
    func testProjectLayoutStoreRoundTripsAndIgnoresCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-layout-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("layouts.json")
        let surface = Data(repeating: 0x33, count: 16)
        let snapshot = ProjectPresentationLayoutSnapshot(
            projectID: "team:store",
            root: .pane(.init(surfaceID: surface)),
            focusedSurfaceID: surface
        )
        let store = ProjectPresentationLayoutStore(fileURL: file)
        store.save(snapshot)
        store.waitForPendingWritesForTests()
        XCTAssertEqual(
            ProjectPresentationLayoutStore(fileURL: file).snapshot(projectID: "team:store"),
            snapshot
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try Data("not-json".utf8).write(to: file)
        XCTAssertNil(
            ProjectPresentationLayoutStore(fileURL: file).snapshot(projectID: "team:store")
        )
    }

    func testRemoteProjectManifestRetriesOnlyRecoverableHostState() {
        for code in [
            "persistence_failed",
            "leader_surface_missing",
            "member_surface_missing",
            "member_surface_mismatch",
        ] {
            XCTAssertTrue(TeamOrchestrator.remoteProjectManifestShouldRetry(errorCode: code))
        }
        for code in ["not_owner", "invalid_manifest", "invalid_member"] {
            XCTAssertFalse(TeamOrchestrator.remoteProjectManifestShouldRetry(errorCode: code))
        }
    }

    @MainActor
    func testRemotePresentationAttachNeedsAResolvedRouteButNotAnExistingTunnel() {
        let leaderID = Data(repeating: 0x42, count: 16)
        XCTAssertTrue(TeamOrchestrator.remotePresentationCanAttach(
            leaderSurfaceID: leaderID,
            isConnected: true,
            hasResolvedTeamRoute: true
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationCanAttach(
            leaderSurfaceID: leaderID,
            isConnected: false,
            hasResolvedTeamRoute: true
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationCanAttach(
            leaderSurfaceID: Data(),
            isConnected: true,
            hasResolvedTeamRoute: true
        ))
        XCTAssertFalse(TeamOrchestrator.remotePresentationCanAttach(
            leaderSurfaceID: leaderID,
            isConnected: true,
            hasResolvedTeamRoute: false
        ))
        XCTAssertTrue(TeamOrchestrator.shouldOfferRemoteManifest(
            hasLocalTeam: false,
            localPresentationOwnedByRequester: false,
            localRevision: 0,
            remoteRevision: 1
        ))
        XCTAssertTrue(TeamOrchestrator.shouldOfferRemoteManifest(
            hasLocalTeam: true,
            localPresentationOwnedByRequester: false,
            localRevision: 1,
            remoteRevision: 2
        ))
        XCTAssertFalse(TeamOrchestrator.shouldOfferRemoteManifest(
            hasLocalTeam: true,
            localPresentationOwnedByRequester: false,
            localRevision: 2,
            remoteRevision: 2
        ))
        XCTAssertFalse(TeamOrchestrator.shouldOfferRemoteManifest(
            hasLocalTeam: true,
            localPresentationOwnedByRequester: true,
            localRevision: 0,
            remoteRevision: 2
        ))
    }

    @MainActor
    func testRemoteManifestRefusesPartialOrMultiHostTopology() {
        func member(hostKey: String?, surfaceByte: UInt8?) -> TeamOrchestrator.AgentMember {
            TeamOrchestrator.AgentMember(
                id: UUID().uuidString,
                name: "reviewer",
                teamName: "durable-demo",
                cli: "codex",
                launchCommand: "codex",
                model: "gpt-5",
                agentType: "reviewer",
                color: "green",
                instructions: "",
                workspaceId: UUID(),
                panelId: UUID(),
                createdAt: Date(),
                remoteSurfaceID: surfaceByte.map { Data(repeating: $0, count: 16) },
                remoteSurfaceSpawned: true,
                remoteAgentSurface: true,
                hostKey: hostKey
            )
        }

        let host = "ssh:root@jw-server"
        XCTAssertTrue(TeamOrchestrator.remoteManifestCoversEveryAgent(
            [member(hostKey: host, surfaceByte: 1)],
            hostKey: host
        ))
        XCTAssertFalse(TeamOrchestrator.remoteManifestCoversEveryAgent(
            [member(hostKey: "ssh:root@another-host", surfaceByte: 2)],
            hostKey: host
        ))
        XCTAssertFalse(TeamOrchestrator.remoteManifestCoversEveryAgent(
            [member(hostKey: host, surfaceByte: nil)],
            hostKey: host
        ))
    }

    // MARK: - Remote leader foreground confirmation

    /// Gate policy: `repl`/`adopted` never launch a CLI on the remote-leader
    /// attach path, so there is nothing for a foreground-busy signal to
    /// confirm — gating on it there would fail every attach in those modes.
    func testRemoteLeaderForegroundConfirmationIsSkippedForReplAndAdopted() {
        XCTAssertFalse(TeamOrchestrator.remoteLeaderNeedsForegroundConfirmation(leaderMode: "repl"))
        XCTAssertFalse(TeamOrchestrator.remoteLeaderNeedsForegroundConfirmation(leaderMode: "adopted"))
        XCTAssertTrue(TeamOrchestrator.remoteLeaderNeedsForegroundConfirmation(leaderMode: "claude"))
        XCTAssertTrue(TeamOrchestrator.remoteLeaderNeedsForegroundConfirmation(leaderMode: "codex"))
    }

    /// Regression for the bug this gate exists to close: a plain shell that
    /// never execs the requested CLI must not read as confirmed, even though
    /// its surface exists and is otherwise ordinary.
    func testRemoteLeaderSurfaceConfirmsForegroundOnlyWhenKnownAndBusy() {
        let surfaceID = Data(repeating: 0x7, count: 16)
        func surface(known: Bool, busy: Bool, id: Data = surfaceID) -> Termmesh_Peer_V1_SurfaceInfo {
            var info = Termmesh_Peer_V1_SurfaceInfo()
            info.surfaceID = id
            info.foregroundBusyKnown = known
            info.foregroundBusy = busy
            return info
        }
        XCTAssertTrue(TeamOrchestrator.remoteLeaderSurfaceConfirmsForeground(
            surfaces: [surface(known: true, busy: true)], surfaceID: surfaceID
        ))
        // A plain shell: the surface exists, but nothing claimed the
        // foreground — exactly the observed "plain shell accepted as leader"
        // symptom this gate closes.
        XCTAssertFalse(TeamOrchestrator.remoteLeaderSurfaceConfirmsForeground(
            surfaces: [surface(known: true, busy: false)], surfaceID: surfaceID
        ))
        // A host that cannot answer the question at all must read as "not
        // yet", never as a false confirmation.
        XCTAssertFalse(TeamOrchestrator.remoteLeaderSurfaceConfirmsForeground(
            surfaces: [surface(known: false, busy: false)], surfaceID: surfaceID
        ))
        XCTAssertFalse(TeamOrchestrator.remoteLeaderSurfaceConfirmsForeground(
            surfaces: [surface(known: true, busy: true, id: Data(repeating: 0x9, count: 16))],
            surfaceID: surfaceID
        ))
        XCTAssertFalse(TeamOrchestrator.remoteLeaderSurfaceConfirmsForeground(
            surfaces: [], surfaceID: surfaceID
        ))
    }

    @MainActor
    func testRemoteManifestSignatureIgnoresTelemetryButTracksTopology() {
        var team = TeamOrchestrator.Team(
            id: "durable-demo",
            leaderSessionId: "leader",
            leaderMode: "claude",
            leaderModel: "",
            leaderCli: "claude",
            leaderPanelId: UUID(),
            leaderEndpoint: .peer(hostKey: "host-a"),
            workingDirectory: "/srv/demo",
            workspaceId: UUID(),
            agents: [],
            createdAt: Date(),
            worktreeMode: "off",
            teamUuid: "uuid-demo"
        )
        let initial = TeamOrchestrator.remoteProjectManifestSignature(team, hostKey: "host-a")
        team.leaderReady = true
        team.leaderFailureDescription = "telemetry only"
        XCTAssertEqual(
            initial,
            TeamOrchestrator.remoteProjectManifestSignature(team, hostKey: "host-a")
        )
        team.gitRepoRoot = "/srv/demo-v2"
        XCTAssertNotEqual(
            initial,
            TeamOrchestrator.remoteProjectManifestSignature(team, hostKey: "host-a")
        )
    }

    @MainActor
    func testOwnedRelayReconnectBackoffRetriesImmediatelyThenCapsAtThirtySeconds() {
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 1), 0)
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 2), 2)
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 3), 4)
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 6), 30)
        XCTAssertEqual(PeerRelaySession.reconnectDelaySeconds(attempt: 20), 30)
    }

    func testRelayPalettePrefixPreservesSourceTerminalDefaults() {
        let prefix = peerTerminalPalettePrefix(
            foreground: NSColor(
                srgbRed: CGFloat(0x12) / 255,
                green: CGFloat(0x34) / 255,
                blue: CGFloat(0x56) / 255,
                alpha: 1
            ),
            background: NSColor(
                srgbRed: CGFloat(0xAB) / 255,
                green: CGFloat(0xCD) / 255,
                blue: CGFloat(0xEF) / 255,
                alpha: 1
            )
        )

        XCTAssertEqual(
            prefix,
            Data("\u{1b}]10;rgb:1212/3434/5656\u{7}\u{1b}]11;rgb:abab/cdcd/efef\u{7}".utf8)
        )
    }

    // MARK: - Reconnect surface match (terminal panes only)

    private func surface(
        id: UInt8, title: String, type: String = "terminal", attachable: Bool = true
    ) -> Termmesh_Peer_V1_SurfaceInfo {
        var info = Termmesh_Peer_V1_SurfaceInfo()
        info.surfaceID = Data(repeating: id, count: 16)
        info.title = title
        info.surfaceType = type
        info.attachable = attachable
        return info
    }

    @MainActor
    func testReconnectMatchPrefersSameSurfaceIdOverSameTitle() {
        let wanted = surface(id: 1, title: "build")
        let byTitle = surface(id: 2, title: "build")
        let match = PeerClientCoordinator.reconnectSurfaceMatch(
            surfaces: [byTitle, wanted], wanted: wanted
        )
        XCTAssertEqual(match?.surfaceID, wanted.surfaceID)
    }

    /// The realistic collision: the dead terminal's title also names an agent
    /// surface. Reconnect replaces a TERMINAL pane — attaching the agent would
    /// pick callback delivery only for `openRemotePane` to refuse it, tearing
    /// the fresh session down behind a "Reconnect Failed" alert.
    @MainActor
    func testReconnectTitleFallbackSkipsAgentSurfaces() {
        let wanted = surface(id: 1, title: "reviewer")
        let agent = surface(id: 2, title: "reviewer", type: "agent")
        let terminal = surface(id: 3, title: "reviewer")
        let match = PeerClientCoordinator.reconnectSurfaceMatch(
            surfaces: [agent, terminal], wanted: wanted
        )
        XCTAssertEqual(match?.surfaceID, terminal.surfaceID)
    }

    /// When the only candidates are agent surfaces the reconnect must say
    /// "Surface Gone" rather than attach-and-refuse.
    @MainActor
    func testReconnectMatchReturnsNilWhenOnlyAgentSurfacesRemain() {
        let wanted = surface(id: 1, title: "reviewer")
        let agentSameTitle = surface(id: 2, title: "reviewer", type: "agent")
        XCTAssertNil(
            PeerClientCoordinator.reconnectSurfaceMatch(
                surfaces: [agentSameTitle], wanted: wanted
            )
        )
    }

    @MainActor
    func testReconnectMatchSkipsUnattachableSurfaces() {
        let wanted = surface(id: 1, title: "build")
        let unattachable = surface(id: 1, title: "build", attachable: false)
        XCTAssertNil(
            PeerClientCoordinator.reconnectSurfaceMatch(
                surfaces: [unattachable], wanted: wanted
            )
        )
    }

    private final class RunnerMockHost: @unchecked Sendable {
        enum Failure: Error {
            case syscall(String, Int32)
            case unexpectedMessage(String)
            case timedOut(String)
        }

        let socketPath: String
        let surfaceID = Data(repeating: 0xA5, count: 16)
        private let lock = NSLock()
        private var listenerFD: Int32 = -1
        private var clientFDs: Set<Int32> = []
        private var attachedSurfaceIDs: [Data] = []
        /// Set when the listener starts, not when this object is built, and
        /// generous on purpose. Its job is to stop a wedged test hanging
        /// forever — not to assert how fast the machine is. At eight seconds
        /// from construction it was doing the latter: the XCTest host here is
        /// the whole term-mesh app, a passing run already spent ~6s of the
        /// budget, and on a loaded machine the host gave up mid-handshake and
        /// closed the listener, which the client then saw as ENOTCONN.
        private var deadline: Date = .distantFuture
        private static let listenerBudget: TimeInterval = 120

        init(socketPath: String) {
            self.socketPath = socketPath
        }

        func start() throws -> Task<Void, Error> {
            deadline = Date().addingTimeInterval(Self.listenerBudget)
            unlink(socketPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.syscall("socket", errno) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socketPath.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.count < capacity else {
                close(fd)
                throw Failure.syscall("socket path", ENAMETOOLONG)
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                    for (offset, byte) in path.enumerated() {
                        bytes[offset] = CChar(bitPattern: byte)
                    }
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else {
                let code = errno
                close(fd)
                throw Failure.syscall("bind", code)
            }
            guard listen(fd, 2) == 0 else {
                let code = errno
                close(fd)
                throw Failure.syscall("listen", code)
            }
            listenerFD = fd
            return Task.detached { [self] in
                defer {
                    finishListener(fd)
                }
                for launchIndex in 0..<2 {
                    try waitForEvent(fd: fd, event: Int16(POLLIN), operation: "accept")
                    let client = Darwin.accept(fd, nil, nil)
                    guard client >= 0 else { throw Failure.syscall("accept", errno) }
                    registerClient(client)
                    defer {
                        unregisterClient(client)
                        close(client)
                    }
                    try handle(client: client, launchIndex: launchIndex)
                }
            }
        }

        func stop() {
            lock.lock()
            let fd = listenerFD
            listenerFD = -1
            let clients = clientFDs
            lock.unlock()
            for client in clients {
                Darwin.shutdown(client, SHUT_RDWR)
            }
            if fd >= 0 {
                Darwin.shutdown(fd, SHUT_RDWR)
                close(fd)
            }
            unlink(socketPath)
        }

        private func finishListener(_ fd: Int32) {
            lock.lock()
            let ownsListener = listenerFD == fd
            if ownsListener { listenerFD = -1 }
            lock.unlock()
            if ownsListener { close(fd) }
            unlink(socketPath)
        }

        func attachedIDs() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return attachedSurfaceIDs
        }

        func remainingDeadlineNanoseconds() -> UInt64 {
            UInt64(max(deadline.timeIntervalSinceNow, 0) * 1_000_000_000)
        }

        private func registerClient(_ fd: Int32) {
            lock.lock()
            clientFDs.insert(fd)
            lock.unlock()
        }

        private func unregisterClient(_ fd: Int32) {
            lock.lock()
            clientFDs.remove(fd)
            lock.unlock()
        }

        private func waitForEvent(fd: Int32, event: Int16, operation: String) throws {
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw Failure.timedOut(operation) }
                var descriptor = pollfd(fd: fd, events: event, revents: 0)
                let timeoutMS = Int32(min(remaining * 1_000, Double(Int32.max)))
                let result = Darwin.poll(&descriptor, 1, timeoutMS)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else {
                    if result == 0 { throw Failure.timedOut(operation) }
                    throw Failure.syscall("poll \(operation)", errno)
                }
                guard descriptor.revents & event != 0 else {
                    throw Failure.syscall("poll \(operation)", ECONNRESET)
                }
                return
            }
        }

        private func handle(client: Int32, launchIndex: Int) throws {
            guard case .hello = try readEnvelope(client).payload else {
                throw Failure.unexpectedMessage("expected Hello")
            }
            var hello = Termmesh_Peer_V1_Hello()
            hello.protocolVersion = "1.0.0"
            hello.peerID = Data(repeating: 0x11, count: 16)
            hello.displayName = "runner-mock"
            hello.appVersion = "test"
            hello.capabilities = [PeerCapability.surfaceEnsureV1]
            try send(client) { $0.hello = hello }

            var challenge = Termmesh_Peer_V1_AuthChallenge()
            challenge.nonce = Data(repeating: 0x22, count: 32)
            challenge.supportedMethods = ["ssh-passthrough"]
            try send(client) { $0.authChallenge = challenge }
            guard case .auth = try readEnvelope(client).payload else {
                throw Failure.unexpectedMessage("expected Auth")
            }
            var authResult = Termmesh_Peer_V1_AuthResult()
            authResult.accepted = true
            authResult.sessionID = Data(repeating: UInt8(launchIndex + 1), count: 16)
            try send(client) { $0.authResult = authResult }

            guard case .ensureSurfaceRequest(let ensure) = try readEnvelope(client).payload else {
                throw Failure.unexpectedMessage("expected EnsureSurfaceRequest")
            }
            guard ensure.key == "runner:build:SECRET_KEY", ensure.cwd == "/app/runner" else {
                throw Failure.unexpectedMessage("unexpected runner spec")
            }
            var ensured = Termmesh_Peer_V1_EnsureSurfaceResponse()
            ensured.requestID = ensure.requestID
            ensured.result = launchIndex == 0 ? .created : .reused
            ensured.surfaceID = surfaceID
            ensured.instanceID = Data(repeating: 0xB6, count: 16)
            ensured.generation = 1
            ensured.pid = 4242
            ensured.specHash = Data(repeating: 0xC7, count: 32)
            try send(client) { $0.ensureSurfaceResponse = ensured }

            guard case .attachSurface(let attach) = try readEnvelope(client).payload else {
                throw Failure.unexpectedMessage("expected AttachSurface")
            }
            lock.lock()
            attachedSurfaceIDs.append(attach.surfaceID)
            lock.unlock()
            var attached = Termmesh_Peer_V1_AttachResult()
            attached.accepted = true
            attached.surfaceID = attach.surfaceID
            attached.grantedMode = attach.mode
            try send(client) { $0.attachResult = attached }
        }

        private func send(
            _ fd: Int32,
            configure: (inout Termmesh_Peer_V1_Envelope) -> Void
        ) throws {
            var envelope = Termmesh_Peer_V1_Envelope()
            configure(&envelope)
            try writeAll(fd, try encodeFrame(envelope))
        }

        private func readEnvelope(_ fd: Int32) throws -> Termmesh_Peer_V1_Envelope {
            var prefix = Data(count: 4)
            try readAll(fd, into: &prefix)
            let length = Int(prefix.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            })
            var payload = Data(count: length)
            try readAll(fd, into: &payload)
            var frame = prefix + payload
            guard let envelope = try decodeFrame(from: &frame) else {
                throw Failure.unexpectedMessage("incomplete frame")
            }
            return envelope
        }

        private func readAll(_ fd: Int32, into data: inout Data) throws {
            var offset = 0
            let totalCount = data.count
            while offset < totalCount {
                try waitForEvent(fd: fd, event: Int16(POLLIN), operation: "read")
                let count = data.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress! + offset, totalCount - offset)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.syscall("read", errno) }
                offset += count
            }
        }

        private func writeAll(_ fd: Int32, _ data: Data) throws {
            var offset = 0
            while offset < data.count {
                try waitForEvent(fd: fd, event: Int16(POLLOUT), operation: "write")
                let count = data.withUnsafeBytes {
                    Darwin.write(fd, $0.baseAddress! + offset, data.count - offset)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.syscall("write", errno) }
                offset += count
            }
        }
    }

    private func awaitHostCompletion(
        _ task: Task<Void, Error>,
        host: RunnerMockHost
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(nanoseconds: host.remainingDeadlineNanoseconds())
                throw RunnerMockHost.Failure.timedOut("host task")
            }
            defer { group.cancelAll() }
            do {
                _ = try await group.next()
            } catch {
                host.stop()
                task.cancel()
                throw error
            }
        }
    }

    // MARK: - Host key identity

    func test_hostKey_identityAndLabels() {
        let ssh = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/tm-peer.sock", port: nil, identityFile: nil)
        XCTAssertEqual(ssh.hostKey, .ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/tm-peer.sock", port: nil))
        XCTAssertEqual(ssh.hostKey.description, "ssh:root@jw-server:/run/user/0/tm-peer.sock")
        XCTAssertEqual(ssh.hostKey.shortLabel, "jw-server")
        XCTAssertEqual(ssh.hostKey.sshTarget, "root@jw-server")

        let direct = PeerPaneHostSpec.direct(sockPath: "/tmp/term-mesh-peer-501/peer.sock")
        XCTAssertEqual(direct.hostKey, .direct(sockPath: "/tmp/term-mesh-peer-501/peer.sock"))
        XCTAssertEqual(direct.hostKey.shortLabel, "peer.sock")
        XCTAssertNil(direct.hostKey.sshTarget)
    }

    func test_hostKey_sshDistinguishesRemoteSockPaths() {
        // One machine can host several daemons on different sockets —
        // pooling them onto one tunnel would connect a pane to the wrong
        // peer (cross-vendor panel finding, 2026-07-15). Same target +
        // same remote socket still pools.
        let a = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/a.sock", port: nil, identityFile: nil)
        let b = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/b.sock", port: nil, identityFile: nil)
        let a2 = PeerPaneHostSpec.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/a.sock", port: nil, identityFile: nil)
        XCTAssertNotEqual(a.hostKey, b.hostKey)
        XCTAssertEqual(a.hostKey, a2.hostKey)
    }

    // MARK: - Host accent determinism

    func test_hostAccent_isDeterministicPerHost() {
        let key = PeerPaneHostKey.ssh(target: "root@jw-server", remoteSockPath: "/run/user/0/tm-peer.sock", port: nil)
        XCTAssertEqual(PeerHostAccent.colors(for: key), PeerHostAccent.colors(for: key))
        XCTAssertEqual(
            PeerHostAccent.primaryColor(for: key),
            PeerHostAccent.primaryColor(for: key)
        )
    }

    // MARK: - Registry refcount (direct lease — no tunnel process)

    @MainActor
    func test_registry_refcountLifecycle() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-refcount.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        XCTAssertNil(registry.activeLease(forKey: key))

        let lease1 = try await registry.acquire(spec)
        XCTAssertTrue(registry.activeLease(forKey: key) === lease1)
        XCTAssertEqual(lease1.hostSockPath, sockPath)

        // Second acquire pools the same lease.
        let lease2 = try await registry.acquire(spec)
        XCTAssertTrue(lease1 === lease2)

        // First release keeps the lease alive (refcount 2 → 1)…
        registry.release(lease1)
        XCTAssertTrue(registry.activeLease(forKey: key) === lease1)

        // …retain bumps it back, so two releases are needed…
        registry.retain(lease1)
        registry.release(lease1)
        XCTAssertNotNil(registry.activeLease(forKey: key))

        // …and the final release removes it from the pool.
        registry.release(lease1)
        XCTAssertNil(registry.activeLease(forKey: key))
    }

    /// Disconnect retires the transport even while panes still hold refs.
    /// Their delayed teardown must not evict a replacement lease acquired by
    /// Reconnect for the same host key.
    @MainActor
    func test_registry_disconnectKeepsOldRefsButProtectsReplacementLease() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-disconnect.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        XCTAssertNil(registry.activeLease(forKey: key))
        let teardownsBefore = registry.teardownCountForTests

        let retired = try await registry.acquire(spec)
        registry.retain(retired) // sidebar + preserved pane
        XCTAssertEqual(registry.disconnectTransport(for: key), sockPath)
        XCTAssertNil(registry.activeLease(forKey: key))
        XCTAssertEqual(registry.teardownCountForTests, teardownsBefore + 1)

        let replacement = try await registry.acquire(spec)
        XCTAssertFalse(replacement === retired)
        XCTAssertTrue(registry.activeLease(forKey: key) === replacement)

        registry.release(retired)
        registry.release(retired)
        XCTAssertTrue(
            registry.activeLease(forKey: key) === replacement,
            "a retired pane lease must not remove the reconnect lease"
        )
        XCTAssertEqual(
            registry.teardownCountForTests,
            teardownsBefore + 1,
            "the retired transport must stop exactly once"
        )

        registry.release(replacement)
        XCTAssertNil(registry.activeLease(forKey: key))
        XCTAssertEqual(registry.teardownCountForTests, teardownsBefore + 2)
    }

    @MainActor
    func test_transportRecovery_coalescesStaleGenerationAndAllowsNextIncident() async {
        let recovery = PeerPaneTransportRecovery()
        var refreshCount = 0

        let first = await recovery.refresh(after: 0) { refreshCount += 1; return true }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(refreshCount, 1)

        // A sibling attached through generation 0 reports the same outage
        // after the first pane already refreshed it. It must join generation
        // 1 without restarting the replacement transport.
        let sibling = await recovery.refresh(after: 0) { refreshCount += 100; return true }
        XCTAssertEqual(sibling, 1)
        XCTAssertEqual(refreshCount, 1)

        // A later failure of generation 1 is a new incident and gets one new
        // refresh of its own.
        let next = await recovery.refresh(after: first) { refreshCount += 1; return true }
        XCTAssertEqual(next, 2)
        XCTAssertEqual(refreshCount, 2)
    }

    /// Pane, live mirror and sidebar roster all report the same pooled SSH
    /// generation when one tunnel stalls. Every consumer must join the first
    /// refresh; otherwise the second heartbeat kills the replacement tunnel.
    @MainActor
    func test_transportRecovery_coalescesPaneMirrorAndSidebarFailure() async {
        let recovery = PeerPaneTransportRecovery()
        var refreshCount = 0

        async let pane = recovery.refresh(after: 0) { refreshCount += 1; return true }
        async let mirror = recovery.refresh(after: 0) { refreshCount += 1; return true }
        async let sidebar = recovery.refresh(after: 0) { refreshCount += 1; return true }
        let generations = await [pane, mirror, sidebar]

        XCTAssertEqual(generations, [1, 1, 1])
        XCTAssertEqual(refreshCount, 1)
    }

    /// A consumer can attach after the generation counter advances but before
    /// that transport restart finishes. Reporting its failure with the current
    /// generation must join the in-flight restart, not start another one.
    @MainActor
    func test_transportRecovery_currentGenerationJoinsInFlightRefresh() async {
        let recovery = PeerPaneTransportRecovery()
        var refreshCount = 0
        var releaseRefresh: CheckedContinuation<Void, Never>?

        let firstTask = Task { @MainActor in
            await recovery.refresh(after: 0) {
                refreshCount += 1
                await withCheckedContinuation { releaseRefresh = $0 }
                return true
            }
        }
        while releaseRefresh == nil { await Task.yield() }

        let observedGeneration = recovery.generation
        let siblingTask = Task { @MainActor in
            await recovery.refresh(after: observedGeneration) { refreshCount += 100; return true }
        }
        await Task.yield()
        XCTAssertEqual(refreshCount, 1)

        releaseRefresh?.resume()
        let generations = await [firstTask.value, siblingTask.value]
        XCTAssertEqual(generations, [1, 1])
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func test_transportRecovery_failureKeepsGenerationRetryable() async {
        let recovery = PeerPaneTransportRecovery()
        var refreshCount = 0

        let failed = await recovery.refresh(after: 0) {
            refreshCount += 1
            return false
        }
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(recovery.generation, 0)

        let retried = await recovery.refresh(after: 0) {
            refreshCount += 1
            return true
        }
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(refreshCount, 2)
    }

    func test_transportRecovery_failedStoppedAndTimeoutAreNotSuccess() {
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(
                for: .failed(reason: "unreachable"), sawRestart: true, timedOut: false
            ),
            false
        )
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(
                for: .stopped, sawRestart: true, timedOut: false
            ),
            false
        )
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(
                for: .reconnecting(attempt: 1), sawRestart: true, timedOut: true
            ),
            false
        )
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(
                for: .up, sawRestart: true, timedOut: false
            ),
            true
        )
        XCTAssertNil(
            PeerPaneHostLease.recoveryResult(
                for: .reconnecting(attempt: 1), sawRestart: true, timedOut: false
            )
        )
        // The pre-restart `.up` the poll loop exists to reject: `forceReconnect`
        // has been called but the tunnel has not left `.up` yet, so nothing has
        // been observed that could count as a completed recovery. Without this
        // row, dropping `sawRestart` from the first guard keeps every other
        // assertion above green while this input silently flips nil -> true.
        XCTAssertNil(
            PeerPaneHostLease.recoveryResult(
                for: .up, sawRestart: false, timedOut: false
            )
        )
    }

    /// PR255 follow-up regression (logic-1, Medium): `forceReconnect` can report
    /// "scheduled" for a restart that was already in flight (see
    /// `PeerSSHTunnel.forceReconnect`'s `restartTask != nil` early return). If
    /// that restart finishes before the poller in `refreshTransport` takes its
    /// first read, the tunnel reads `.up` for the entire poll window and
    /// `sawRestart` never flips true. Timing out on that state must still count
    /// as recovered, not as a failure — misclassifying it leaves the generation
    /// un-bumped, so the next sibling failure report re-runs `forceReconnect`
    /// and kills the (already healthy) replacement tunnel.
    func test_recoveryResult_joinedInFlightRestartThatWasAlreadyUpCountsAsRecovered() {
        XCTAssertEqual(
            PeerPaneHostLease.recoveryResult(for: .up, sawRestart: false, timedOut: true),
            true
        )
    }

    /// Drains queued main-actor work until `condition` holds.
    ///
    /// The cancellation tests below assert on a flag a *different* task sets,
    /// and awaiting the caller does not order that: `cancelWaiter` resumes the
    /// waiting caller BEFORE it calls `refresh.task.cancel()`, and cancelling
    /// the action task only schedules the sleeping `Task.sleep` to throw. So
    /// `await owner.value` can resolve one or more hops before the action's
    /// catch block runs. Asserting straight after the await is a coin flip —
    /// it is what made `test_transportRecovery_cancelledOwnerClearsSlotForRetry`
    /// fail on the mac-sub runner while passing under casual local reads.
    @MainActor
    private func waitFor(
        _ condition: () -> Bool,
        yields: Int = 1_000
    ) async -> Bool {
        for _ in 0..<yields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @MainActor
    func test_transportRecovery_cancelledOwnerClearsSlotForRetry() async {
        let recovery = PeerPaneTransportRecovery()
        var actionStarted = false
        var actionWasCancelled = false

        let owner = Task { @MainActor in
            await recovery.refresh(after: 0) {
                actionStarted = true
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return true
                } catch is CancellationError {
                    actionWasCancelled = true
                    return false
                } catch {
                    return false
                }
            }
        }
        while !actionStarted { await Task.yield() }
        owner.cancel()
        let cancelledGeneration = await owner.value
        XCTAssertEqual(cancelledGeneration, 0)
        let actionCancelled = await waitFor({ actionWasCancelled })
        XCTAssertTrue(
            actionCancelled,
            "owner cancellation must reach the in-flight refresh action"
        )

        let retried = await recovery.refresh(after: 0) { true }
        XCTAssertEqual(retried, 1)
    }

    @MainActor
    func test_transportRecovery_cancelledWaiterDoesNotCancelSharedOwner() async {
        let recovery = PeerPaneTransportRecovery()
        var releaseRefresh: CheckedContinuation<Void, Never>?

        let owner = Task { @MainActor in
            await recovery.refresh(after: 0) {
                await withCheckedContinuation { releaseRefresh = $0 }
                return true
            }
        }
        while releaseRefresh == nil { await Task.yield() }
        let waiter = Task { @MainActor in
            await recovery.refresh(after: 0) { XCTFail("waiter ran duplicate action"); return true }
        }
        await Task.yield()
        waiter.cancel()
        let cancelledGeneration = await waiter.value
        XCTAssertEqual(cancelledGeneration, 0)

        releaseRefresh?.resume()
        let recoveredGeneration = await owner.value
        XCTAssertEqual(recoveredGeneration, 1)
        XCTAssertEqual(recovery.generation, 1)
    }

    /// `cancel()` is wired into `PeerPaneHostLease.teardown()` so a pane closed
    /// mid-recovery releases every caller waiting on `refreshTransport()`
    /// instead of leaving them parked forever. The cancelled-owner and
    /// cancelled-waiter tests above only exercise `cancelWaiter()` via
    /// `Task.cancel()` on one caller; this drives `cancel()` itself, covering
    /// the owner, a joined waiter, that the shared refresh task is actually
    /// cancelled, that the slot is cleared for a fresh attempt, and that later
    /// recovery still works.
    @MainActor
    func test_transportRecovery_cancelResumesOwnerAndWaiterAndClearsSlotForRetry() async {
        let recovery = PeerPaneTransportRecovery()
        var actionStarted = false
        var actionWasCancelled = false

        let owner = Task { @MainActor in
            await recovery.refresh(after: 0) {
                actionStarted = true
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return true
                } catch is CancellationError {
                    actionWasCancelled = true
                    return false
                } catch {
                    return false
                }
            }
        }
        while !actionStarted { await Task.yield() }

        let waiter = Task { @MainActor in
            await recovery.refresh(after: 0) {
                XCTFail("waiter must not run a duplicate action")
                return true
            }
        }
        await Task.yield()

        let preCancelGeneration = recovery.generation
        recovery.cancel()

        let ownerResult = await owner.value
        let waiterResult = await waiter.value
        XCTAssertEqual(
            ownerResult, preCancelGeneration,
            "cancel() must resume the owner with the pre-cancel generation"
        )
        XCTAssertEqual(
            waiterResult, preCancelGeneration,
            "cancel() must resume every waiter with the pre-cancel generation"
        )
        XCTAssertEqual(recovery.generation, preCancelGeneration, "cancel() must not advance the generation")

        var retryCount = 0
        let retried = await recovery.refresh(after: preCancelGeneration) {
            retryCount += 1
            return true
        }
        XCTAssertEqual(
            retryCount, 1,
            "a later report must start a fresh refresh, not join the cancelled slot"
        )
        XCTAssertEqual(
            retried, preCancelGeneration + 1,
            "recovery after cancel() must still be able to advance the generation"
        )
        let actionCancelled = await waitFor({ actionWasCancelled })
        XCTAssertTrue(
            actionCancelled,
            "cancel() must cancel the shared in-flight refresh task"
        )
    }

    func test_forceReconnectDoesNotRearmStoppedTunnel() {
        let tunnel = PeerSSHTunnel(
            sshTarget: "example.invalid",
            remoteSockPath: "/tmp/peer.sock"
        )

        XCTAssertFalse(tunnel.forceReconnect(reason: "late failure"))
        XCTAssertEqual(tunnel.currentState, .stopped)
    }

    /// The case above only proves `forceReconnect` refuses a tunnel that was
    /// never started — `wantsRunning` is false there for the trivial reason
    /// that nothing ever set it. The regression the guard exists for is the
    /// armed-then-retired one named in its own source comment: "a late
    /// pane/mirror heartbeat must never re-arm a tunnel its lease retired."
    ///
    /// `retry()` arms the tunnel without touching the network: it sets
    /// `wantsRunning` and installs a restart task whose first attempt sleeps a
    /// second before it would ever call `spawnOnce()`, and `stop()` cancels
    /// that task well inside the second.
    func test_forceReconnectDoesNotRearmRetiredTunnel() {
        let tunnel = PeerSSHTunnel(
            sshTarget: "example.invalid",
            remoteSockPath: "/tmp/peer.sock"
        )

        tunnel.retry()
        XCTAssertTrue(
            tunnel.forceReconnect(reason: "live failure"),
            "an armed tunnel must accept a reconnect, otherwise the case below proves nothing"
        )

        tunnel.stop()

        XCTAssertFalse(
            tunnel.forceReconnect(reason: "late failure after stop"),
            "a heartbeat landing after stop() must not re-arm a retired tunnel"
        )
        // Idempotent: a retired tunnel stays retired however often it is asked.
        XCTAssertFalse(tunnel.forceReconnect(reason: "later failure after stop"))

        // `currentState` is deliberately not asserted here. `stop()` does emit
        // `.stopped` synchronously, but the restart task `retry()` armed can
        // still deliver its own queued `.down` afterwards, so the state read is
        // ordering-dependent in a way the return value is not.
    }

    /// Reattach-on-reconnect is for panes a person chose to disconnect. An
    /// accidental transport loss has recovery of its own, and reattaching it
    /// here too would rebuild the pane twice for one failure.
    @MainActor
    func test_reattachAfterHostReconnect_onlyForPanesADeliberateDisconnectKept() {
        let host = PeerPaneHostSpec.direct(sockPath: "/tmp/psp-unit-reattach.sock").hostKey
        let otherHost = PeerPaneHostSpec.direct(sockPath: "/tmp/psp-unit-other.sock").hostKey

        XCTAssertTrue(
            PeerClientCoordinator.shouldReattachAfterHostReconnect(
                leaseKey: host, reconnectedHost: host,
                hostTransportWasDisconnected: true, isTorndown: false
            )
        )
        XCTAssertFalse(
            PeerClientCoordinator.shouldReattachAfterHostReconnect(
                leaseKey: otherHost, reconnectedHost: host,
                hostTransportWasDisconnected: true, isTorndown: false
            ),
            "another host coming back says nothing about this pane"
        )
        XCTAssertFalse(
            PeerClientCoordinator.shouldReattachAfterHostReconnect(
                leaseKey: host, reconnectedHost: host,
                hostTransportWasDisconnected: false, isTorndown: false
            ),
            "an accidental drop already recovers on its own"
        )
        XCTAssertFalse(
            PeerClientCoordinator.shouldReattachAfterHostReconnect(
                leaseKey: host, reconnectedHost: host,
                hostTransportWasDisconnected: true, isTorndown: true
            ),
            "a torn-down pane has nothing to reattach"
        )
    }

    func test_ownedSessionReconnectStopsWhenHostLeaseWasRetired() {
        XCTAssertTrue(PeerRelaySession.shouldReconnectOwnedSession(
            ownsSession: true, isTorndown: false,
            isCurrentSession: true, hostLeaseIsActive: true
        ))
        XCTAssertFalse(PeerRelaySession.shouldReconnectOwnedSession(
            ownsSession: true, isTorndown: false,
            isCurrentSession: true, hostLeaseIsActive: false
        ))
    }

    @MainActor
    func test_registry_concurrentFirstAcquireYieldsOneLease() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-race.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)

        async let a = registry.acquire(spec)
        async let b = registry.acquire(spec)
        let (leaseA, leaseB) = try await (a, b)
        XCTAssertTrue(leaseA === leaseB, "concurrent first-acquires must pool one lease")

        registry.release(leaseA)
        registry.release(leaseB)
        XCTAssertNil(registry.activeLease(forKey: spec.hostKey))
    }

    /// The coalesced start task is shared by every pane waiting on the host, so
    /// one pane's sidebar Cancel must not abort it — that would kill the other
    /// panes' connect too. It may only be cancelled by the last waiter.
    @MainActor
    func test_cancelPendingAcquire_refusesWhileAnotherPaneIsWaiting() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-shared-cancel.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        XCTAssertNil(registry.activeLease(forKey: key))

        var waitersAtCancel = 0
        var pendingSurvivedCancel = false

        // Queued in order on the main actor: both acquires park on the same
        // start task before the cancel runs.
        let paneA = Task { @MainActor in try await registry.acquire(spec) }
        let paneB = Task { @MainActor in try await registry.acquire(spec) }
        let sidebarCancel = Task { @MainActor in
            waitersAtCancel = registry.pendingWaiterCountForTests(for: key)
            registry.cancelPendingAcquire(for: key)
            pendingSurvivedCancel = registry.pendingWaiterCountForTests(for: key) > 0
        }

        _ = await sidebarCancel.value
        let leaseA = try await paneA.value
        let leaseB = try await paneB.value

        XCTAssertEqual(waitersAtCancel, 2, "both panes must be parked on one start task")
        XCTAssertTrue(pendingSurvivedCancel, "a shared start must survive one pane's cancel")
        XCTAssertTrue(leaseA === leaseB)
        XCTAssertNotNil(registry.activeLease(forKey: key), "the other pane must keep its lease")

        registry.release(leaseA)
        registry.release(leaseB)
        XCTAssertNil(registry.activeLease(forKey: key))
        XCTAssertEqual(registry.pendingWaiterCountForTests(for: key), 0, "waiter accounting must not leak")
    }

    /// A caller cancelled *after* the start task already produced a lease must
    /// not leave that lease unowned: `makeLease` has spawned the tunnel by then,
    /// and nothing else would ever stop it.
    @MainActor
    func test_registry_cancelledAcquireTearsDownInsteadOfOrphaning() async throws {
        let registry = PeerPaneHostRegistry.shared
        let sockPath = "/tmp/psp-unit-\(getpid())-cancel.sock"
        let spec = PeerPaneHostSpec.direct(sockPath: sockPath)
        let key = spec.hostKey
        XCTAssertNil(registry.activeLease(forKey: key))
        let teardownsBefore = registry.teardownCountForTests

        // The test holds the main actor until it awaits, so the cancel always
        // lands before `acquire` starts running.
        let acquisition = Task { @MainActor in try await registry.acquire(spec) }
        acquisition.cancel()

        do {
            _ = try await acquisition.value
            XCTFail("a cancelled acquire must not return a lease")
        } catch is CancellationError {
            // expected
        }

        XCTAssertNil(registry.activeLease(forKey: key), "cancelled acquire must leave the pool empty")
        XCTAssertEqual(
            registry.teardownCountForTests,
            teardownsBefore + 1,
            "the already-created lease must be torn down, not orphaned"
        )
    }

    @MainActor
    func test_savedRunnerRepeatedLaunchReusesExactEnsuredSurfaceID() async throws {
        // This is intentionally a bare-xcodebuild regression test. Debug apps
        // do not run reload.sh's binary-copy step, but they must still attach
        // terminal surfaces through a checkout or installed release helper.
        // The old bundle-only check skipped this test and hid project restore
        // failures behind an opaque noRelayBinary error.
        let relay = PeerRelaySession.findRelayBinary()
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: relay),
            "needs a checkout, bundled, or installed term-mesh-peer-relay"
        )

        let socketPath = "/tmp/peer-runner-test-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = RunnerMockHost(socketPath: socketPath)
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }
        let surface = PeerRunnerSurfaceSpec(
            key: "runner:build:SECRET_KEY",
            cwd: "/app/runner",
            executable: "/SECRET_EXECUTABLE/bin/sh",
            args: ["-lc", "exec make test --token=SECRET_ARGUMENT"]
        )
        let attachment = PeerRunnerAttachment(title: "Build Runner", cols: 120, rows: 36)

        // The mock host runs in a detached Task nobody awaits, so when it
        // rejects a step it just closes the socket and the client reports
        // ENOTCONN — the same opaque symptom no matter what actually went
        // wrong. Report the host's own reason alongside the client's.
        func mockHostReason() async -> String {
            do {
                try await hostTask.value
                return "host finished without error"
            } catch {
                return String(describing: error)
            }
        }

        let first: (session: PeerPaneSession, outcome: PeerEnsureSurfaceOutcome)
        do {
            first = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: surface,
                attachment: attachment,
                hostSpec: hostSpec
            )
        } catch {
            XCTFail("first ensureAndAttach failed: \(error) — mock host: \(await mockHostReason())")
            return
        }
        defer { first.session.teardown() }
        let second = try await PeerPaneSession.ensureAndAttach(
            lease: lease,
            surfaceSpec: surface,
            attachment: attachment,
            hostSpec: hostSpec
        )
        defer { second.session.teardown() }

        XCTAssertEqual(first.outcome.result, .created)
        XCTAssertEqual(second.outcome.result, .reused)
        XCTAssertEqual(first.outcome.surfaceID, host.surfaceID)
        XCTAssertEqual(second.outcome.surfaceID, host.surfaceID)
        XCTAssertEqual(first.session.originSurface.surfaceID, host.surfaceID)
        XCTAssertEqual(second.session.originSurface.surfaceID, host.surfaceID)
        XCTAssertEqual(host.attachedIDs(), [host.surfaceID, host.surfaceID])
        for visible in [
            first.session.surfaceTitle,
            first.session.originSurface.title,
            first.session.connectionInfo.targetTitle,
            second.session.surfaceTitle,
            second.session.originSurface.title,
            second.session.connectionInfo.targetTitle,
        ] {
            XCTAssertFalse(visible.contains("SECRET_KEY"))
            XCTAssertFalse(visible.contains("SECRET_EXECUTABLE"))
            XCTAssertFalse(visible.contains("SECRET_ARGUMENT"))
        }

        try await awaitHostCompletion(hostTask, host: host)
    }

    func test_bareDebugBuildCanFindCheckoutOrInstalledRelayHelper() {
        let candidates = PeerRelaySession.relayBinaryCandidates(
            bundlePath: "/DerivedData/Build/Products/Debug/term-mesh DEV.app",
            sourceFilePath: "/work/term-mesh/Sources/PeerRelaySession.swift",
            currentDirectoryPath: "/tmp/unrelated",
            installedAppPath: "/Applications/term-mesh.app"
        )

        XCTAssertEqual(
            candidates.prefix(2),
            [
                "/DerivedData/Build/Products/Debug/term-mesh DEV.app/Contents/Resources/bin/term-mesh-peer-relay",
                "/DerivedData/Build/Products/Debug/term-mesh DEV.app/Contents/MacOS/term-mesh-peer-relay",
            ]
        )
#if DEBUG
        XCTAssertTrue(candidates.contains(
            "/work/term-mesh/daemon/target/release/term-mesh-peer-relay"
        ))
        XCTAssertTrue(candidates.contains(
            "/Applications/term-mesh.app/Contents/Resources/bin/term-mesh-peer-relay"
        ))
        XCTAssertTrue(candidates.contains(
            "/tmp/unrelated/daemon/target/release/term-mesh-peer-relay"
        ))
#else
        // A release app must never execute a binary out of its launch
        // directory: every non-bundle candidate is a development shape.
        XCTAssertEqual(candidates.count, 2)
#endif
    }

    func test_savedRunnerProfileKeepsExecutionIdentitySeparateFromProjectBinding() throws {
        let profile = PeerHostProfile(
            displayName: "jw-server",
            sshTarget: "root@jw-server",
            savedRunner: PeerSavedRunnerProfile(
                surface: PeerRunnerSurfaceSpec(
                    key: "runner:cargo",
                    cwd: "/app/runner",
                    executable: "/usr/bin/cargo",
                    args: ["test"]
                )
            )
        )

        let json = try JSONEncoder().encode(profile)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertTrue(text.contains("runner:cargo"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("projectBinding"))
    }

    func test_plainSavedHostRemainsPickerOnly() throws {
        let profile = PeerHostProfile(
            displayName: "ARM builder",
            sshTarget: "builder-arm",
            remoteSocket: "/run/user/1000/term-mesh.sock"
        )

        XCTAssertNil(profile.savedRunner)
        let restored = try JSONDecoder().decode(
            PeerHostProfile.self,
            from: JSONEncoder().encode(profile)
        )
        XCTAssertNil(restored.savedRunner)
        XCTAssertEqual(restored.effectiveDisplayName, "ARM builder")
    }

    @MainActor
    func test_savedRunnerFailureConversionDropsPeerProvidedSecrets() {
        let secretMarkers = [
            "SECRET_EXECUTABLE",
            "SECRET_ARGUMENT",
            "SECRET_SSH_STDERR",
            "SECRET_ERROR_CONTEXT",
        ]
        let untrustedContext = """
            executable=/SECRET_EXECUTABLE/bin/tool
            args=--token=SECRET_ARGUMENT
            ssh_stderr=SECRET_SSH_STDERR
            detail=SECRET_ERROR_CONTEXT
            """
        let converted = PeerClientCoordinator.safeRunnerError(
            RelayError.ensureRejected(
                code: "COMMAND_NOT_FOUND",
                stage: "ensure",
                safeContext: untrustedContext
            ),
            fallbackStage: .probe
        )
        let visibleStatus = PeerSavedRunnerStatus(
            stage: converted.stage,
            machine: "jw-server",
            cwd: "/app/runner",
            errorCode: converted.code,
            safeContext: converted.context
        )
        let visibleText = [
            visibleStatus.stage.rawValue,
            visibleStatus.machine,
            visibleStatus.cwd,
            visibleStatus.errorCode ?? "",
            visibleStatus.safeContext ?? "",
        ].joined(separator: "\n")

        XCTAssertEqual(visibleStatus.stage, .ensure)
        XCTAssertEqual(visibleStatus.machine, "jw-server")
        XCTAssertEqual(visibleStatus.cwd, "/app/runner")
        XCTAssertEqual(visibleStatus.errorCode, "COMMAND_NOT_FOUND")
        XCTAssertEqual(visibleStatus.safeContext, "The configured executable does not exist")
        for secret in secretMarkers {
            XCTAssertFalse(visibleText.contains(secret))
        }
    }

}

/// Force Disconnect must close a host's mirrors and relay windows before its
/// panes. While a live mirror owns the workspace,
/// `Workspace.mirrorForwardsLocalActions` converts every local close into a
/// forwardClose to the host and returns false, so a pane closed first does not
/// go away — the host never pushes a layout dropping the last surface in a
/// workspace, and exactly one pane survives the teardown. Closing mirrors first
/// flips that predicate off before any pane is asked to close.
@MainActor
final class RemoteHostForceDisconnectOrderTests: XCTestCase {

    private func connection(
        _ kind: PeerRelayConnectionInfo.Kind,
        title: String
    ) -> PeerRelayConnectionInfo {
        PeerRelayConnectionInfo(
            id: ObjectIdentifier(NSObject()),
            kind: kind,
            hostSockPath: "/tmp/tm-peer-test.sock",
            hostDisplayName: "test-host",
            sshTarget: "root@test-host",
            sshPort: nil,
            identityFile: nil,
            remoteSockPath: "/run/user/0/tm-peer.sock",
            targetTitle: title,
            connectedAt: Date()
        )
    }

    func test_forceDisconnectOrder_putsPanesLast() {
        let rows = [
            connection(.pane, title: "pane-1"),
            connection(.workspace, title: "mirror"),
            connection(.pane, title: "pane-2"),
            connection(.console, title: "console"),
        ]

        let ordered = RemoteHostStore.forceDisconnectOrder(rows)

        XCTAssertEqual(ordered.map(\.targetTitle),
                       ["mirror", "console", "pane-1", "pane-2"])
    }

    /// The regression this guards: no pane may precede a non-pane, or that pane
    /// gets forwarded to the host instead of closed.
    func test_forceDisconnectOrder_noPaneBeforeANonPane() {
        let rows = [
            connection(.pane, title: "pane-1"),
            connection(.workspace, title: "mirror"),
        ]

        let ordered = RemoteHostStore.forceDisconnectOrder(rows)
        let firstPane = ordered.firstIndex { $0.kind == .pane }
        let lastNonPane = ordered.lastIndex { $0.kind != .pane }

        XCTAssertNotNil(firstPane)
        XCTAssertNotNil(lastNonPane)
        XCTAssertGreaterThan(firstPane!, lastNonPane!)
    }

    /// A force disconnect that silently dropped a row would leave that
    /// connection open with no remaining way to reach it.
    func test_forceDisconnectOrder_preservesEveryRow() {
        let rows = [
            connection(.pane, title: "pane-1"),
            connection(.workspace, title: "mirror"),
            connection(.pane, title: "pane-2"),
        ]

        let ordered = RemoteHostStore.forceDisconnectOrder(rows)

        XCTAssertEqual(ordered.count, rows.count)
        XCTAssertEqual(Set(ordered.map(\.targetTitle)),
                       Set(rows.map(\.targetTitle)))
    }

    /// activeConnections is already sorted by connectedAt; the close sequence
    /// should stay predictable within each group.
    func test_forceDisconnectOrder_isStableWithinEachGroup() {
        let rows = [
            connection(.workspace, title: "mirror-a"),
            connection(.pane, title: "pane-a"),
            connection(.workspace, title: "mirror-b"),
            connection(.pane, title: "pane-b"),
        ]

        let ordered = RemoteHostStore.forceDisconnectOrder(rows)

        XCTAssertEqual(ordered.map(\.targetTitle),
                       ["mirror-a", "mirror-b", "pane-a", "pane-b"])
    }

    func test_forceDisconnectOrder_handlesEmptyAndPaneOnlyInput() {
        XCTAssertTrue(RemoteHostStore.forceDisconnectOrder([]).isEmpty)

        let panesOnly = [
            connection(.pane, title: "pane-1"),
            connection(.pane, title: "pane-2"),
        ]
        XCTAssertEqual(
            RemoteHostStore.forceDisconnectOrder(panesOnly).map(\.targetTitle),
            ["pane-1", "pane-2"]
        )
    }

}

/// The leftover-shell sweep: what it counts, and what it reports when part
/// of the batch refuses to close.
final class PeerShellSweepTests: XCTestCase {

    private func ids(_ n: Int) -> Set<Data> {
        Set((0..<n).map { Data([UInt8($0)]) })
    }

    private struct Refused: Error {}

    @MainActor
    func test_every_target_closed_is_counted() async throws {
        var seen: [Data] = []
        let closed = try await TeamOrchestrator.sweepClose(
            targets: ids(5),
            send: { _ in },
            onClosed: { seen.append($0) }
        )
        XCTAssertEqual(closed, 5)
        XCTAssertEqual(seen.count, 5, "the completion runs once per closed shell, not per target")
    }

    /// One refusal must not strand the shells behind it — the whole point of
    /// the sweep. Before this, the first failure aborted the batch.
    @MainActor
    func test_one_refusal_does_not_strand_the_rest() async throws {
        let targets = ids(6)
        let doomed = targets.sorted { $0.lexicographicallyPrecedes($1) }[2]
        var attempted = 0
        var closedIDs: [Data] = []

        do {
            _ = try await TeamOrchestrator.sweepClose(
                targets: targets,
                send: { id in
                    attempted += 1
                    if id == doomed { throw Refused() }
                },
                onClosed: { closedIDs.append($0) }
            )
            XCTFail("a refusal must surface as an error")
        } catch let error as TeamOrchestrator.RemoteAgentError {
            guard case .partialShellClose(let closed, let failed, _) = error else {
                return XCTFail("expected partialShellClose, got \(error)")
            }
            XCTAssertEqual(closed, 5)
            XCTAssertEqual(failed, 1)
            XCTAssertEqual(closed + failed, targets.count, "every target is accounted for")
        }

        XCTAssertEqual(attempted, 6, "the sweep must not stop at the failure")
        XCTAssertFalse(closedIDs.contains(doomed), "a refused shell must not be marked closed")
    }

    /// "Nothing closed" and "most of them did" have to be distinguishable —
    /// the caller shows the count to the user.
    @MainActor
    func test_a_total_failure_reports_zero_closed() async throws {
        do {
            _ = try await TeamOrchestrator.sweepClose(
                targets: ids(4),
                send: { _ in throw Refused() }
            )
            XCTFail("expected an error")
        } catch let error as TeamOrchestrator.RemoteAgentError {
            guard case .partialShellClose(let closed, let failed, _) = error else {
                return XCTFail("expected partialShellClose, got \(error)")
            }
            XCTAssertEqual(closed, 0)
            XCTAssertEqual(failed, 4)
        }
    }

    /// Only the first failure is reported. A dozen identical refusals should
    /// not bury the one reason the user needs to read.
    @MainActor
    func test_the_first_failure_is_the_one_reported() async throws {
        struct First: Error {}
        struct Later: Error {}
        var call = 0
        do {
            _ = try await TeamOrchestrator.sweepClose(
                targets: ids(3),
                send: { _ in
                    call += 1
                    throw call == 1 ? First() : Later()
                }
            )
            XCTFail("expected an error")
        } catch let error as TeamOrchestrator.RemoteAgentError {
            guard case .partialShellClose(_, _, let reason) = error else {
                return XCTFail("expected partialShellClose, got \(error)")
            }
            XCTAssertTrue(reason.contains("First"), "got \(reason)")
        }
    }

    /// An empty batch is a no-op, not an error. `closePeerShells` reaches this
    /// when every selected shell turned out to be protected.
    @MainActor
    func test_an_empty_sweep_closes_nothing_and_does_not_throw() async throws {
        var sendCalled = false
        let closed = try await TeamOrchestrator.sweepClose(
            targets: [],
            send: { _ in sendCalled = true }
        )
        XCTAssertEqual(closed, 0)
        XCTAssertFalse(sendCalled)
    }

    func test_forceBypassesProtectionOnlyWhenExplicitlyEnabled() {
        let selected = ids(3)
        let protected = Set([Data([0x01])])
        XCTAssertEqual(
            TeamOrchestrator.peerShellTargets(
                selected: selected, protected: protected, force: false
            ),
            selected.subtracting(protected)
        )
        XCTAssertEqual(
            TeamOrchestrator.peerShellTargets(
                selected: selected, protected: protected, force: true
            ),
            selected
        )
    }

    func test_saturated_sweep_keeps_borrowing_after_first_dial_failure() {
        XCTAssertEqual(TeamOrchestrator.peerShellTerminateRoute(
            hasOpenedSession: false, dialFailed: false, hasBorrowedSession: true
        ), .dial)
        for _ in 0..<7 {
            XCTAssertEqual(TeamOrchestrator.peerShellTerminateRoute(
                hasOpenedSession: false, dialFailed: true, hasBorrowedSession: true
            ), .borrowed)
        }
        XCTAssertEqual(TeamOrchestrator.peerShellTerminateRoute(
            hasOpenedSession: false, dialFailed: true, hasBorrowedSession: false
        ), .unavailable)
    }

    @MainActor
    func test_force_uses_authoritative_termination_for_the_last_pane() async throws {
        var closeSent = false
        var confirmationRead = false
        let authoritative = try await TeamOrchestrator.closePeerShellConfirmed(
            surfaceID: Data(repeating: 0x41, count: 16),
            force: true,
            terminate: { .terminated },
            closePane: { closeSent = true },
            confirmRemoved: { confirmationRead = true; return false }
        )
        XCTAssertTrue(authoritative)
        XCTAssertFalse(closeSent)
        XCTAssertFalse(confirmationRead)
    }

    @MainActor
    func test_force_authoritative_notFound_is_idempotent_success() async throws {
        var closeSent = false
        var confirmationRead = false
        let authoritative = try await TeamOrchestrator.closePeerShellConfirmed(
            surfaceID: Data(repeating: 0x42, count: 16),
            force: true,
            terminate: { .notFound },
            closePane: { closeSent = true },
            confirmRemoved: { confirmationRead = true; return false }
        )
        XCTAssertTrue(authoritative)
        XCTAssertFalse(closeSent)
        XCTAssertFalse(confirmationRead)
    }

    @MainActor
    func test_older_host_close_with_roster_confirmation_is_cache_safe_success() async throws {
        var closeSent = false
        var confirmationRead = false
        let confirmed = try await TeamOrchestrator.closePeerShellConfirmed(
            surfaceID: Data(repeating: 0x45, count: 16),
            force: true,
            terminate: { throw PeerSessionError.capabilityNotNegotiated("surface.terminate.v1") },
            closePane: { closeSent = true },
            confirmRemoved: { confirmationRead = true; return true }
        )
        XCTAssertTrue(confirmed)
        XCTAssertTrue(closeSent)
        XCTAssertTrue(confirmationRead)
    }

    @MainActor
    func test_force_failed_termination_still_requires_roster_confirmation() async throws {
        var closeSent = false
        var confirmationRead = false
        do {
            try await TeamOrchestrator.closePeerShellConfirmed(
                surfaceID: Data(repeating: 0x44, count: 16),
                force: true,
                terminate: { .failed },
                closePane: { closeSent = true },
                confirmRemoved: { confirmationRead = true; return false }
            )
            XCTFail("borrowed termination must not count before roster confirmation")
        } catch {
            XCTAssertTrue(closeSent)
            XCTAssertTrue(confirmationRead)
        }
    }

    @MainActor
    func test_silent_close_noop_is_not_counted_as_cleanup_success() async throws {
        do {
            _ = try await TeamOrchestrator.sweepClose(
                targets: [Data(repeating: 0x43, count: 16)],
                send: { surfaceID in
                    _ = try await TeamOrchestrator.closePeerShellConfirmed(
                        surfaceID: surfaceID,
                        force: false,
                        terminate: { .notFound },
                        closePane: {},
                        confirmRemoved: { false }
                    )
                }
            )
            XCTFail("an unconfirmed close must not be reported as deleted")
        } catch let error as TeamOrchestrator.RemoteAgentError {
            guard case .partialShellClose(let closed, let failed, _) = error else {
                return XCTFail("expected partialShellClose, got \(error)")
            }
            XCTAssertEqual(closed, 0)
            XCTAssertEqual(failed, 1)
        }
    }

    func test_authoritative_absence_removes_exact_rows_and_recomputes_counts() {
        func pane(_ id: UInt8, tabs: Int, busy: Bool) -> RemotePaneSummary {
            RemotePaneSummary(
                id: Data([id]), title: "pane-\(id)",
                workingDirectoryPath: "/tmp", workingDirectoryName: "tmp",
                projectRootPath: nil, tabCount: tabs, columns: 80, rows: 24,
                isBusy: busy
            )
        }
        func workspace(_ id: UInt8, panes: [RemotePaneSummary]) -> WorkspaceSummary {
            WorkspaceSummary(
                id: Data([id]), title: "workspace-\(id)", hostSockPath: "/tmp/peer.sock",
                windowID: Data(), windowTitle: "", isDefault: false,
                paneCount: panes.count,
                surfaceCount: panes.reduce(0) { $0 + $1.tabCount },
                busyCount: panes.count(where: \.isBusy), panes: panes
            )
        }
        let multiTab = pane(1, tabs: 2, busy: true)
        let survivor = pane(2, tabs: 3, busy: false)
        let removed = pane(3, tabs: 1, busy: true)

        let result = RemoteHostStore.removingPeerShells(
            [multiTab.id, removed.id],
            from: [
                workspace(10, panes: [multiTab, survivor]),
                workspace(11, panes: [removed]),
            ]
        )

        XCTAssertEqual(
            result[0].panes.map(\.id), [multiTab.id, survivor.id],
            "an active tab disappearing must not hide its live sibling tabs"
        )
        XCTAssertEqual(result[0].paneCount, 2)
        XCTAssertEqual(result[0].surfaceCount, 5)
        XCTAssertEqual(result[0].busyCount, 1)
        XCTAssertTrue(result[1].panes.isEmpty)
        XCTAssertEqual(result[1].paneCount, 0)
        XCTAssertEqual(result[1].surfaceCount, 0)
        XCTAssertEqual(result[1].busyCount, 0)
        XCTAssertEqual(result[1].id, Data([11]), "empty named workspace must be preserved")
    }

    @MainActor
    func test_newer_live_mirror_roster_invalidates_cleanup_checkpoint() throws {
        let store = RemoteHostStore.shared
        let hostID = "cleanup-generation-\(UUID().uuidString)"
        let sockPath = "/tmp/cleanup-generation.sock"
        let surfaceID = Data(repeating: 0x51, count: 16)
        var pane = Termmesh_Peer_V1_WorkspacePane()
        pane.surfaceID = surfaceID
        pane.title = "newer"
        pane.tabs = []
        var layout = Termmesh_Peer_V1_WorkspaceLayout()
        layout.pane = pane
        let summaryPane = RemotePaneSummary(
            id: surfaceID, title: "old", workingDirectoryPath: "/tmp",
            workingDirectoryName: "tmp", projectRootPath: nil, tabCount: 1,
            columns: 80, rows: 24, isBusy: false
        )
        let workspaceID = Data(repeating: 0x52, count: 16)
        let workspace = WorkspaceSummary(
            id: workspaceID, title: "workspace", hostSockPath: sockPath,
            windowID: Data(), windowTitle: "", isDefault: false,
            paneCount: 1, surfaceCount: 1, busyCount: 0, panes: [summaryPane]
        )
        store.installPeerShellCleanupCacheForTesting(
            hostID: hostID, sockPath: sockPath, workspaces: [workspace]
        )
        defer { store.removePeerShellCleanupCacheForTesting(hostID: hostID) }
        let checkpoint = try XCTUnwrap(store.peerShellCleanupCheckpoint(
            hostID: hostID, expectedSockPath: sockPath
        ))

        store.recordLiveMirrorLayout(
            layout, hostKey: store.hosts[hostID]!.paneHostSpec.hostKey,
            workspaceIDs: [workspaceID]
        )

        XCTAssertFalse(store.removeAuthoritativelyAbsentPeerShells(
            [surfaceID], checkpoint: checkpoint
        ))
        XCTAssertEqual(store.hosts[hostID]?.workspaces[0].panes.first?.title, "newer")
    }

    @MainActor
    func test_forceCloseRemovesLocalViewerBeforeRemoteTermination() throws {
        let workspace = Workspace(title: "force-close-viewer")
        let panelID = try XCTUnwrap(workspace.focusedPanelId)
        let surfaceID = Data(repeating: 0x71, count: 16)
        workspace.debugProjectLayoutSurfaceIDs[panelID] = surfaceID

        XCTAssertEqual(TeamOrchestrator.closePeerSurfaceViewers(
            surfaceIDs: [surfaceID], workspaces: [workspace]
        ), 1)
        XCTAssertNil(workspace.panels[panelID])
    }

    func test_forceConfirmationCountsOnlyProtectedSelection() {
        let protected = TeamOrchestrator.PeerShellCleanupItem(
            id: Data([0x01]), title: "busy", workingDirectory: "/tmp",
            isBusy: true, state: .unclaimed
        )
        let safe = TeamOrchestrator.PeerShellCleanupItem(
            id: Data([0x02]), title: "orphan", workingDirectory: "/tmp",
            isBusy: false, state: .managedOrphan
        )
        XCTAssertEqual(TeamOrchestrator.protectedPeerShellCount(
            items: [protected, safe], selection: [protected.id, safe.id]
        ), 1)
    }
}

/// Project deletion must respect the host's last-pane invariant: a dedicated
/// workspace owns its terminal panes, while native agent surfaces sit outside
/// that tree and keep their explicit termination path.
final class ProjectRemoteSurfaceDeletionTests: XCTestCase {

    func test_dedicated_workspace_deletes_terminal_surface_with_workspace() {
        XCTAssertFalse(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: false,
                belongsToOwnedWorkspace: true
            )
        )
    }

    func test_peer_owned_agent_is_terminated_even_with_dedicated_workspace() {
        XCTAssertTrue(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: true,
                belongsToOwnedWorkspace: true
            )
        )
    }

    func test_terminal_surface_without_owned_workspace_keeps_close_path() {
        XCTAssertTrue(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: false,
                belongsToOwnedWorkspace: false
            )
        )
    }

    func test_workspace_ownership_includes_active_and_inactive_tabs_only() {
        let active = Data(repeating: 0x11, count: 16)
        let inactive = Data(repeating: 0x22, count: 16)
        let generic = Data(repeating: 0x33, count: 16)
        var activeTab = Termmesh_Peer_V1_PaneTab()
        activeTab.surfaceID = active
        var inactiveTab = Termmesh_Peer_V1_PaneTab()
        inactiveTab.surfaceID = inactive
        var pane = Termmesh_Peer_V1_WorkspacePane()
        pane.surfaceID = active
        pane.tabs = [activeTab, inactiveTab]
        var layout = Termmesh_Peer_V1_WorkspaceLayout()
        layout.pane = pane

        let owned = peerSurfaceIDs(layout)
        XCTAssertEqual(owned, [active, inactive])
        XCTAssertFalse(owned.contains(generic))
        XCTAssertTrue(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: false,
                belongsToOwnedWorkspace: owned.contains(generic)
            )
        )
        XCTAssertFalse(
            TeamOrchestrator.shouldDeleteRemoteSurfaceIndividually(
                isAgent: false,
                belongsToOwnedWorkspace: owned.contains(inactive)
            )
        )
    }

    private func rosterWorkspace(
        id: UInt8, title: String, surface: Data?
    ) -> Termmesh_Peer_V1_Workspace {
        var workspace = Termmesh_Peer_V1_Workspace()
        workspace.workspaceID = Data(repeating: id, count: 16)
        workspace.title = title
        if let surface {
            var pane = Termmesh_Peer_V1_WorkspacePane()
            pane.surfaceID = surface
            var layout = Termmesh_Peer_V1_WorkspaceLayout()
            layout.pane = pane
            workspace.layout = layout
        }
        return workspace
    }

    /// The adopted-viewer delete path: the manifest carries no workspace id,
    /// so deletion re-derives the dedicated workspace from the roster. A
    /// workspace qualifies only with BOTH the project title and one of the
    /// project's known surfaces — either alone deleted the wrong workspace
    /// (a recreated team's stale twin) or none at all (the observed leak:
    /// the daemon-owned leader survived every delete from an adopting viewer).
    func test_dedicated_workspace_resolves_by_title_and_known_surface() {
        let leader = Data(repeating: 0x0A, count: 16)
        let title = TeamOrchestrator.remoteProjectWorkspaceTitle(teamName: "demo")
        let stale = rosterWorkspace(
            id: 1, title: title, surface: Data(repeating: 0x0B, count: 16)
        )
        let dedicated = rosterWorkspace(id: 2, title: title, surface: leader)
        let unrelated = rosterWorkspace(id: 3, title: "notes", surface: leader)

        XCTAssertEqual(
            TeamOrchestrator.resolveDedicatedProjectWorkspaceID(
                workspaces: [unrelated, stale, dedicated],
                teamName: "demo",
                knownSurfaceIDs: [leader]
            ),
            dedicated.workspaceID,
            "the same-title stale twin and the same-surface unrelated workspace both lose"
        )
    }

    func test_dedicated_workspace_resolution_refuses_guesses() {
        let leader = Data(repeating: 0x0A, count: 16)
        let titled = rosterWorkspace(
            id: 1,
            title: TeamOrchestrator.remoteProjectWorkspaceTitle(teamName: "demo"),
            surface: nil
        )
        XCTAssertNil(
            TeamOrchestrator.resolveDedicatedProjectWorkspaceID(
                workspaces: [titled], teamName: "demo", knownSurfaceIDs: [leader]
            ),
            "a layout-less title match is not ownership"
        )
        XCTAssertNil(
            TeamOrchestrator.resolveDedicatedProjectWorkspaceID(
                workspaces: [titled], teamName: "demo", knownSurfaceIDs: []
            ),
            "with no known surfaces nothing can prove ownership"
        )
    }

    func test_layoutless_existing_workspaceStillDeletesThroughLifecycle() {
        let workspaceID = Data(repeating: 0x33, count: 16)
        let workspace = rosterWorkspace(id: 0x33, title: "project:demo", surface: nil)

        XCTAssertEqual(
            TeamOrchestrator.remoteWorkspaceSurfaceIDs(
                workspaces: [workspace], workspaceID: workspaceID
            ),
            [],
            "an existing layout-less workspace continues to DeleteWorkspace"
        )
        XCTAssertNil(
            TeamOrchestrator.remoteWorkspaceSurfaceIDs(
                workspaces: [], workspaceID: workspaceID
            ),
            "a missing workspace is distinct from an empty one"
        )
    }
}

/// Invariant harness over the peer-agent cleanup submachine — the first
/// class-level defense against the "distributed lifecycle state drifts from
/// reality" defect family, whose members were previously found one incident
/// at a time (tombstone enrichment race, wrong-owner notFound spends,
/// delete-time leaks).
///
/// Instead of pinning one reproduced interleaving, seeded runs drive random
/// interleavings of enqueue / mid-flight enrichment / retry passes / host
/// route movement against a model host, then assert the invariants that must
/// hold for EVERY ordering:
///
///  I-spend: a record that ever learned its true owning endpoint is never
///           spent by a wrong-endpoint "success" (a moved route's notFound is
///           indistinguishable from confirmation by protocol, so the ONLY
///           defense is the record) — its process must be dead once the store
///           lets go of it.
///  I-drain: once the route heals, every remaining record is spent and every
///           modeled process is dead — no immortal tombstone, no orphan.
///
/// A failing seed replays deterministically; put the seed in the failure
/// message of any new assertion added here.
final class PeerCleanupLifecycleInvariantTests: XCTestCase {

    /// Deterministic LCG so a failing scenario replays by seed alone.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @MainActor
    func test_everySeededInterleavingKeepsOwnerAwareTombstonesUntilTheProcessIsDead() async {
        for seed in UInt64(1)...50 {
            await runScenario(seed: seed)
        }
    }

    @MainActor
    private func runScenario(seed: UInt64) async {
        var rng = SeededRNG(state: seed)
        let suiteName = "LifecycleInv-\(seed)-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("seed \(seed): could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let hostKey = "ssh:model-host"
        let trueOwner = "/run/model/true-owner.sock"
        let wrongRoute = "/run/model/moved-route.sock"
        // The host's CURRENT route starts on the moved endpoint — the exact
        // condition that makes nil-owner fallback resolution dangerous.
        var currentRoute = wrongRoute

        var alive = Set<Data>()       // processes running on the model host
        var ownerKnown = Set<Data>()  // surfaces whose record carried the true owner

        let store = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            automaticRetryDelay: 3600,
            hostSockPathProvider: { _ in nil },
            terminator: { _, _, _, _ in false }
        )

        let surfaceCount = Int(rng.next() % 4) + 2
        let surfaces = (0..<surfaceCount).map { Data(repeating: UInt8($0 + 1), count: 16) }
        for surface in surfaces {
            alive.insert(surface)
            if rng.next() % 2 == 0 {
                // Recorded with the owner already known (post-ensure detach).
                store.enqueue(
                    hostKey: hostKey, surfaceID: surface,
                    owningRemoteSockPath: trueOwner
                )
                ownerKnown.insert(surface)
            } else {
                // Legacy shape: recorded before anyone knew the endpoint.
                store.enqueue(hostKey: hostKey, surfaceID: surface)
            }
        }

        // Model terminate semantics, inlined in each pass below: resolution
        // prefers the recorded owner, else the host's current route. Reaching
        // the true owner kills the process. Reaching anything else returns
        // notFound — which the wire contract defines as SUCCESS. Both answers
        // are `true`; that lie is the hazard the invariants guard.
        let passes = Int(rng.next() % 4) + 3
        for pass in 0..<passes {
            // The route heals partway through the scenario.
            if pass == passes - 2 { currentRoute = trueOwner }
            var enrichBudget = Int(rng.next() % 2) + (pass == 0 ? 1 : 0)
            var localRNG = SeededRNG(state: rng.next())
            await store.retryPending(
                hostSockPath: { _ in "/tmp/model-serving.sock" },
                terminate: { _, _, surfaceID, owner in
                    // Mid-flight enrichment: while THIS terminate is awaited,
                    // another caller learns the owner of a random pending
                    // record and enqueues it — the exact window of the race.
                    if enrichBudget > 0, localRNG.next() % 2 == 0 {
                        enrichBudget -= 1
                        let pending = store.pendingRecords
                        if !pending.isEmpty {
                            let pick = pending[Int(localRNG.next() % UInt64(pending.count))]
                            if let pickID = pick.surfaceID {
                                store.enqueue(
                                    hostKey: hostKey, surfaceID: pickID,
                                    owningRemoteSockPath: trueOwner
                                )
                                ownerKnown.insert(pickID)
                            }
                        }
                    }
                    let resolved = owner ?? currentRoute
                    if resolved == trueOwner {
                        alive.remove(surfaceID)
                    }
                    return true  // notFound and terminated are both "true"
                }
            )

            // I-spend: any record the store has let go of, whose owner was
            // ever known, must correspond to a dead process. A wrong-endpoint
            // success spending an owner-aware record shows up here.
            let stillRecorded = Set(store.pendingRecords.compactMap(\.surfaceID))
            for surface in ownerKnown where !stillRecorded.contains(surface) {
                XCTAssertFalse(
                    alive.contains(surface),
                    "seed \(seed) pass \(pass): an owner-aware tombstone was spent while its process still runs"
                )
            }
        }

        // I-drain: with the route healed, one more pass must spend everything
        // that remains and leave no modeled process behind.
        await store.retryPending(
            hostSockPath: { _ in "/tmp/model-serving.sock" },
            terminate: { _, _, surfaceID, owner in
                let resolved = owner ?? currentRoute
                if resolved == trueOwner { alive.remove(surfaceID) }
                return true
            }
        )
        XCTAssertTrue(
            store.pendingRecords.isEmpty,
            "seed \(seed): an immortal tombstone survived a healed route: \(store.pendingRecords)"
        )
        // Scoped to owner-aware surfaces on purpose. A legacy record that
        // never learned its endpoint has no defense against a moved route's
        // notFound lie — the wire contract makes the two answers identical,
        // which is WHY the owner field exists. The harness encodes the
        // contract's guarantee, not a utopia the protocol cannot deliver:
        // every surface whose record ever carried the true owner must be
        // dead once the store drains.
        XCTAssertTrue(
            alive.intersection(ownerKnown).isEmpty,
            "seed \(seed): owner-aware processes survived the drain: \(alive.intersection(ownerKnown).count)"
        )
    }
}

/// One PTY, two windows onto it — the size arbitration between a local pane
/// and an attached remote viewer.
final class RemoteViewerSizeArbitrationTests: XCTestCase {

    /// While both are on screen the smaller wins, so neither has to render a
    /// line wrapped for a width it does not have.
    ///
    /// The loser of this arbitration does not merely look wrong: its shell
    /// wraps at a column that is no longer the edge and keeps a cursor the
    /// screen does not show there, which is where the next keystroke lands.
    /// Margin, by contrast, loses nothing.
    func test_both_on_screen_takes_the_smaller_of_the_two() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 1200, h: 800),
            remote: (w: 900, h: 1000),
            localOnScreen: true,
            remoteTypedLast: nil,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 900, "the narrower width wins")
        XCTAssertEqual(size.h, 800, "each dimension is decided on its own")
    }

    /// A pane parked in an unselected workspace has nobody reading it, so
    /// there is no one to accommodate and the viewer gets what it asked for.
    func test_a_hidden_local_pane_yields_entirely_to_the_viewer() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 400, h: 300),
            remote: (w: 1600, h: 1200),
            localOnScreen: false,
            remoteTypedLast: nil,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 1600)
        XCTAssertEqual(size.h, 1200)
    }

    /// With no viewer attached the local pane is unconstrained — the previous
    /// arbitration must not linger and keep it small.
    func test_without_a_viewer_the_local_size_stands() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 1200, h: 800),
            remote: nil,
            localOnScreen: true,
            remoteTypedLast: nil,
            fallback: (w: 10, h: 10)
        )
        XCTAssertEqual(size.w, 1200)
        XCTAssertEqual(size.h, 800)
    }

    /// A viewer can attach before the local pane has ever been laid out; its
    /// size is the only real answer available then.
    func test_a_viewer_arriving_before_any_local_layout_is_used_as_is() {
        let size = TerminalSurface.resolvePixelSize(
            local: nil,
            remote: (w: 640, h: 480),
            localOnScreen: true,
            remoteTypedLast: nil,
            fallback: (w: 10, h: 10)
        )
        XCTAssertEqual(size.w, 640)
        XCTAssertEqual(size.h, 480)
    }

    /// The bug this rule exists for: a viewer maximized to full screen stayed
    /// pinned to the host pane's width, because asking for more room is what
    /// re-loses the min. Typing in the viewer is what breaks the deadlock.
    func test_a_typing_viewer_takes_the_grid_from_a_smaller_host_pane() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 600, h: 400),
            remote: (w: 2400, h: 1400),
            localOnScreen: true,
            remoteTypedLast: true,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 2400, "the viewer being typed into is the one being read")
        XCTAssertEqual(size.h, 1400)
    }

    /// And the same in reverse, so a viewer left open on another machine
    /// cannot hold the pane somebody is actually working in at its size.
    func test_a_typing_local_pane_takes_the_grid_back_from_the_viewer() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 2400, h: 1400),
            remote: (w: 600, h: 400),
            localOnScreen: true,
            remoteTypedLast: false,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 2400)
        XCTAssertEqual(size.h, 1400)
    }

    /// A hidden local pane already yields entirely; who typed last must not
    /// resurrect it as a constraint.
    func test_a_hidden_local_pane_yields_even_when_it_typed_last() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 400, h: 300),
            remote: (w: 1600, h: 1200),
            localOnScreen: false,
            remoteTypedLast: false,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(size.w, 1600)
        XCTAssertEqual(size.h, 1200)
    }

    /// With no viewer attached there is nothing to arbitrate, whatever the
    /// last keystroke was.
    func test_without_a_viewer_the_local_size_stands_regardless_of_the_typist() {
        let size = TerminalSurface.resolvePixelSize(
            local: (w: 1200, h: 800),
            remote: nil,
            localOnScreen: true,
            remoteTypedLast: true,
            fallback: (w: 10, h: 10)
        )
        XCTAssertEqual(size.w, 1200)
        XCTAssertEqual(size.h, 800)
    }

    /// A remote input preference was established while the host pane was not
    /// participating in size arbitration. Opening that workspace locally must
    /// return to the neutral shared-grid rule instead of stretching the host
    /// pane to the relay's stale dimensions. The stateful surface method is
    /// covered through the resolver inputs it establishes here.
    func test_showing_host_pane_after_remote_input_returns_to_shared_grid() {
        let preference = TerminalSurface.remoteTypistPreference(
            true,
            afterLocalVisibilityChangeTo: true
        )
        XCTAssertNil(preference, "showing the host invalidates a preference established while it was hidden")

        let staleRemotePreference = TerminalSurface.resolvePixelSize(
            local: (w: 1200, h: 800),
            remote: (w: 700, h: 1100),
            localOnScreen: false,
            remoteTypedLast: true,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(staleRemotePreference.w, 700)
        XCTAssertEqual(staleRemotePreference.h, 1100)

        let visibleSharedGrid = TerminalSurface.resolvePixelSize(
            local: (w: 1200, h: 800),
            remote: (w: 700, h: 1100),
            localOnScreen: true,
            remoteTypedLast: preference,
            fallback: (w: 0, h: 0)
        )
        XCTAssertEqual(visibleSharedGrid.w, 700)
        XCTAssertEqual(visibleSharedGrid.h, 800)
    }

    func test_hiding_host_pane_keeps_remote_input_preference() {
        XCTAssertEqual(
            TerminalSurface.remoteTypistPreference(
                true,
                afterLocalVisibilityChangeTo: false
            ),
            true
        )
    }
}

final class WorkspaceGeometryReconcilePolicyTests: XCTestCase {
    func test_geometry_only_reconcile_does_not_request_portal_reattach() {
        XCTAssertFalse(
            Workspace.coalescedViewReattachRequirement(
                pending: false,
                requested: false
            )
        )
    }

    func test_structural_reconcile_requests_portal_reattach() {
        XCTAssertTrue(
            Workspace.coalescedViewReattachRequirement(
                pending: false,
                requested: true
            )
        )
    }

    func test_structural_request_is_preserved_when_geometry_requests_coalesce() {
        XCTAssertTrue(
            Workspace.coalescedViewReattachRequirement(
                pending: true,
                requested: false
            )
        )
    }
}

// ── t14: callback (agent) delivery ───────────────────────────────────

/// Exercises `PeerRelaySession`'s `.callback` PtyData delivery: arrival-order
/// preservation on the live path (owned and shared), the resume-transition
/// gate's exactly-once contract riding the same delivery path, the
/// defensive GridSnapshot drop, and the absence of every relay-only fixture
/// (listener socket, secret, helper handshake).
///
/// Sessions are built through the internal initializer around a scripted
/// `PeerSession(read:write:)` — the factories all require a live
/// handshake/attach round trip that a unit test has no host for.
final class PeerRelaySessionCallbackDeliveryTests: XCTestCase {

    private struct TimedOut: Error {}

    /// Collects callback deliveries. The pump invokes `onPtyData` off the
    /// main actor, so a lock box rather than test-local state.
    private final class ChunkCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            chunks.append(data)
            lock.unlock()
        }

        var all: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return chunks
        }

        var count: Int { all.count }

        /// Every delivered byte, in delivery order — chunk boundaries may
        /// legally differ between live chunks and an abort-flush batch, so
        /// content assertions compare the joined stream.
        var joined: String {
            String(decoding: all.reduce(Data(), +), as: UTF8.self)
        }
    }

    /// Scripted inbound side of a `PeerSession`: `push` hands the session's
    /// read closure one already-encoded frame, `finish` makes the next read
    /// throw (the transport died).
    private actor FrameFeed {
        struct EndOfScript: Error {}

        private var pending: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []
        private var finished = false

        func push(_ frame: Data) {
            if waiters.isEmpty {
                pending.append(frame)
            } else {
                waiters.removeFirst().resume(returning: frame)
            }
        }

        func finish() {
            finished = true
            let parked = waiters
            waiters = []
            for waiter in parked {
                waiter.resume(throwing: EndOfScript())
            }
        }

        func next() async throws -> Data {
            if !pending.isEmpty { return pending.removeFirst() }
            if finished { throw EndOfScript() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
    }

    private func ptyDataFrame(surfaceID: Data, byteSeq: UInt64, payload: Data) -> Data {
        var pty = Termmesh_Peer_V1_PtyData()
        pty.surfaceID = surfaceID
        pty.byteSeq = byteSeq
        pty.payload = payload
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.ptyData = pty
        return try! encodeFrame(envelope)
    }

    private func gridSnapshotFrame(surfaceID: Data, ansi: Data) -> Data {
        var snapshot = Termmesh_Peer_V1_GridSnapshot()
        snapshot.surfaceID = surfaceID
        snapshot.byteSeq = 0
        snapshot.altScreen = false
        snapshot.ansi = ansi
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.gridSnapshot = snapshot
        return try! encodeFrame(envelope)
    }

    private func surfaceExitedFrame(
        surfaceID: Data,
        exitCode: Int32,
        signal: Int32,
        reason: String
    ) -> Data {
        var exited = Termmesh_Peer_V1_SurfaceExited()
        exited.surfaceID = surfaceID
        exited.exitCode = exitCode
        exited.signal = signal
        exited.reason = reason
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.surfaceExited = exited
        return try! encodeFrame(envelope)
    }

    private func errorFrame(code: UInt32, message: String) -> Data {
        var peerError = Termmesh_Peer_V1_Error()
        peerError.code = code
        peerError.message = message
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.error = peerError
        return try! encodeFrame(envelope)
    }

    /// `ownsSession: false` on purpose: a scripted stream end must end the
    /// pump, not start the owned-path reconnect loop dialing a host that
    /// does not exist.
    @MainActor
    private func makeCallbackSession(
        feed: FrameFeed,
        surfaceID: Data,
        ptyStream: AsyncStream<PeerPtyChunk>? = nil
    ) -> PeerRelaySession {
        let session = PeerSession(
            read: { try await feed.next() },
            write: { _ in }
        )
        return PeerRelaySession(
            hostSockPath: "/nonexistent/term-mesh-callback-test.sock",
            hostDisplayName: "callback-test",
            relaySockPath: "",
            relaySecret: "",
            surfaceID: surfaceID,
            remoteCols: 80,
            remoteRows: 24,
            session: session,
            transport: nil,
            ownsSession: false,
            ptyStream: ptyStream,
            onSharedDetach: nil,
            attachInitialSeq: 0,
            hostSupportsReplayRing: true,
            ptyDelivery: .callback
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ message: String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if condition() { return }
        XCTFail(message, file: file, line: line)
        throw TimedOut()
    }

    @MainActor
    private func receivedBytes(_ relay: PeerRelaySession) -> UInt64 {
        relay.ioSnapshot["bytes_received"] as? UInt64 ?? 0
    }

    // (a) + (c): live chunks reach the callback in arrival order, and none
    // of the relay-only setup exists to gate them.
    @MainActor
    func testCallbackDeliveryPreservesArrivalOrderWithoutARelayHelper() async throws {
        let surfaceID = Data(repeating: 0xA7, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }

        // Relay-only setup must be inert: no socket path was allocated, no
        // listener is bound, and prepareListener neither throws (there is
        // no relay binary at "") nor binds anything.
        XCTAssertTrue(relay.relaySockPath.isEmpty)
        XCTAssertNoThrow(try relay.prepareListener())
        XCTAssertEqual(relay.listenerFileDescriptorForTesting, -1)

        // In relay mode start() would block in acceptRelay until a helper
        // dials in (and then time out). Callback mode must come up alone.
        try await relay.start()
        XCTAssertEqual(relay.listenerFileDescriptorForTesting, -1)

        var expected: [Data] = []
        var byteSeq: UInt64 = 0
        for index in 0..<50 {
            let payload = Data("{\"line\":\(index)}\n".utf8)
            expected.append(payload)
            await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: byteSeq, payload: payload))
            byteSeq += UInt64(payload.count)
        }

        try await waitUntil("expected 50 chunks, got \(received.count)") { received.count == 50 }
        XCTAssertEqual(received.all, expected, "chunks must arrive exactly once, in arrival order")

        await relay.stop()
        await feed.finish()
    }

    // Contract item: the callback owner must be swappable (the
    // recreated-AgentSession path). Chunks after a reassignment land on the
    // new consumer only.
    @MainActor
    func testCallbackOwnerSwapRedirectsSubsequentChunks() async throws {
        let surfaceID = Data(repeating: 0xA8, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let first = ChunkCollector()
        relay.onPtyData = { first.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("one".utf8)))
        try await waitUntil { first.count == 1 }

        let second = ChunkCollector()
        relay.onPtyData = { second.append($0) }
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 3, payload: Data("two".utf8)))

        try await waitUntil { second.count == 1 }
        XCTAssertEqual(first.joined, "one", "the retired consumer must not receive post-swap chunks")
        XCTAssertEqual(second.joined, "two")

        await relay.stop()
        await feed.finish()
    }

    // (b) abort side: bytes suppressed behind an open resume transition are
    // flushed to the callback in order — exactly once, nothing lost.
    @MainActor
    func testResumeAbortFlushesSuppressedBytesToCallbackInOrder() async throws {
        let surfaceID = Data(repeating: 0xA9, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("A".utf8)))
        try await waitUntil { received.joined == "A" }

        let transition = relay.beginResumeTransitionForTesting()
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 1, payload: Data("B".utf8)))
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 2, payload: Data("C".utf8)))

        // Wait until the pump has *processed* (counted) both suppressed
        // chunks, then confirm none of them rendered.
        try await waitUntil { self.receivedBytes(relay) == 3 }
        XCTAssertEqual(received.joined, "A", "bytes behind an open transition must be suppressed")

        await relay.abortResumeTransitionForTesting(transition)
        try await waitUntil { received.joined == "ABC" }

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 3, payload: Data("D".utf8)))
        try await waitUntil { received.joined == "ABCD" }
        XCTAssertEqual(received.joined, "ABCD", "abort flush must deliver exactly once, in order")

        await relay.stop()
        await feed.finish()
    }

    // (b) commit side: old-session bytes buffered across the boundary are
    // discarded (the replay re-carries them), and the replay itself is
    // delivered exactly once through the same callback path.
    @MainActor
    func testResumeCommitDiscardsOldBytesAndDeliversReplayOnce() async throws {
        let surfaceID = Data(repeating: 0xAA, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("A".utf8)))
        try await waitUntil { received.joined == "A" }

        let transition = relay.beginResumeTransitionForTesting()
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 1, payload: Data("B".utf8)))
        try await waitUntil { self.receivedBytes(relay) == 2 }
        XCTAssertTrue(relay.commitResumeTransitionForTesting(transition))

        // Old-session tail after the commit: suppressed until the swap, and
        // never rendered from the old stream — the replay re-carries it.
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 2, payload: Data("C".utf8)))
        try await waitUntil { self.receivedBytes(relay) == 3 }
        XCTAssertEqual(received.joined, "A", "old-session bytes past the boundary must not render")

        // The receive loop adopting the resumed session resets the wire-seq
        // space; the replay then re-carries everything after the boundary.
        relay.adoptCommittedResumeSessionForTesting()
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("BC".utf8)))
        try await waitUntil { received.joined == "ABC" }

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 2, payload: Data("D".utf8)))
        try await waitUntil { received.joined == "ABCD" }
        XCTAssertEqual(
            received.joined, "ABCD",
            "suppressed old bytes and their replay must not both render"
        )

        await relay.stop()
        await feed.finish()
    }

    // Repair C: host broadcast Lag on callback delivery must not advance
    // the heal anchor past the dropped bytes — an NDJSON consumer has no
    // repainting GridSnapshot to cover a hole. A gapped chunk opens a
    // capture at the last DELIVERED position and suppresses the post-gap
    // stream behind it; the heal ADOPTS that anchor, so the ring replay
    // re-carries the gap plus the suppressed bytes exactly once.
    @MainActor
    func testALaggedGapAnchorsTheHealAtTheLastDeliveredByte() async throws {
        let surfaceID = Data(repeating: 0xAD, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("A".utf8)))
        try await waitUntil { received.joined == "A" }

        // byte_seq jumps 1 → 5: the host's broadcast lagged and dropped
        // four bytes. The post-gap chunk must be captured, not delivered.
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 5, payload: Data("F".utf8)))
        try await waitUntil { self.receivedBytes(relay) == 2 }
        XCTAssertEqual(received.joined, "A",
                       "post-gap bytes must be suppressed until the heal resolves")

        // The heal joins the pump-opened capture: anchored at the end of
        // the last delivered chunk (wire seq 1), not past the gap (6).
        let transition = relay.beginResumeTransitionForTesting()
        XCTAssertEqual(transition.resumeWireSeq, 1,
                       "the heal must resume from the last delivered byte, not skip the gap")

        XCTAssertTrue(relay.commitResumeTransitionForTesting(transition))
        relay.adoptCommittedResumeSessionForTesting()

        // The resumed attach replays everything after the anchor — the
        // dropped bytes AND the suppressed post-gap chunk — exactly once.
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("bcdeF".utf8)))
        try await waitUntil { received.joined == "AbcdeF" }
        XCTAssertEqual(received.joined, "AbcdeF",
                       "the ring replay must fill the gap without duplicating delivered bytes")

        await relay.stop()
        await feed.finish()
    }

    // E4: a chunk emitted while `onPtyData` is unset is a DROP, not an
    // enqueue — otherwise received≈enqueued reads as healthy on a session
    // that rendered nothing.
    @MainActor
    func testConsumerlessChunksCountAsDroppedNotEnqueued() async throws {
        let surfaceID = Data(repeating: 0xAE, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        // Deliberately no onPtyData yet.
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("lost".utf8)))
        try await waitUntil { self.receivedBytes(relay) == 4 }
        XCTAssertEqual(relay.ioSnapshot["bytes_dropped"] as? UInt64, 4)
        XCTAssertEqual(relay.ioSnapshot["bytes_enqueued"] as? UInt64, 0,
                       "a consumer-less emit must never count as enqueued")

        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 4, payload: Data("kept".utf8)))
        try await waitUntil { received.joined == "kept" }
        XCTAssertEqual(relay.ioSnapshot["bytes_enqueued"] as? UInt64, 4)
        XCTAssertEqual(relay.ioSnapshot["bytes_dropped"] as? UInt64, 4,
                       "delivered bytes go back to the enqueued tally only")

        await relay.stop()
        await feed.finish()
    }

    // Shared (pre-demuxed ptyStream) path: same callback, same order, and
    // stream end tears the session down.
    @MainActor
    func testSharedPathDeliversToCallbackAndDisconnectsOnStreamEnd() async throws {
        let surfaceID = Data(repeating: 0xAB, count: 16)
        var continuation: AsyncStream<PeerPtyChunk>.Continuation!
        let stream = AsyncStream<PeerPtyChunk> { continuation = $0 }
        let relay = makeCallbackSession(
            feed: FrameFeed(),
            surfaceID: surfaceID,
            ptyStream: stream
        )
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        var disconnected = false
        relay.onDisconnect = { disconnected = true }
        try await relay.start()

        continuation.yield(PeerPtyChunk(byteSeq: 0, payload: Data("hello ".utf8)))
        continuation.yield(PeerPtyChunk(byteSeq: 6, payload: Data("world".utf8)))
        try await waitUntil { received.joined == "hello world" }
        XCTAssertEqual(received.count, 2, "shared-path chunks must arrive individually, in order")

        continuation.finish()
        try await waitUntil { disconnected }
    }

    // A host-confirmed process exit is terminal application state, not a
    // broken transport to heal. Workspace keeps the completed AgentPanel so
    // its final output and exit notice remain visible; onDisconnect would
    // otherwise immediately close it and start authoritative-missing recovery.
    @MainActor
    func testSurfaceExitFinishesWithoutInvokingDisconnectRecovery() async throws {
        let surfaceID = Data(repeating: 0xAF, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        var observedExit: (Int32, Int32, String)?
        var disconnected = false
        relay.onSurfaceExited = { observedExit = ($0, $1, $2) }
        relay.onDisconnect = { disconnected = true }
        try await relay.start()

        await feed.push(surfaceExitedFrame(
            surfaceID: surfaceID,
            exitCode: 23,
            signal: 0,
            reason: "bridge exited"
        ))
        try await waitUntil { observedExit != nil }

        XCTAssertEqual(observedExit?.0, 23)
        XCTAssertEqual(observedExit?.1, 0)
        XCTAssertEqual(observedExit?.2, "bridge exited")
        XCTAssertFalse(disconnected,
                       "authoritative surface exit must leave the completed agent pane visible")
    }

    // A host protocol error is connection-scoped and cannot safely be ignored:
    // expose it to the panel owner, then use the existing disconnect recovery
    // because the remote process may still be alive after the broken stream.
    @MainActor
    func testHostErrorIsVisibleAndInvokesDisconnectRecovery() async throws {
        let surfaceID = Data(repeating: 0xB0, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        var observedError = ""
        var disconnected = false
        relay.onError = { observedError = String(describing: $0) }
        relay.onDisconnect = { disconnected = true }
        try await relay.start()

        await feed.push(errorFrame(code: 8, message: "input queue overflow"))
        try await waitUntil { disconnected }

        XCTAssertTrue(observedError.contains("host error 8: input queue overflow"))
    }

    // Defensive contract: an agent surface never sends GridSnapshot, but if
    // one arrives its rendered-cell ANSI must not reach the NDJSON consumer
    // — while the wire-seq reset it implies still applies.
    @MainActor
    func testGridSnapshotIsDroppedButItsSeqResetStillApplies() async throws {
        let surfaceID = Data(repeating: 0xAC, count: 16)
        let feed = FrameFeed()
        let relay = makeCallbackSession(feed: feed, surfaceID: surfaceID)
        let received = ChunkCollector()
        relay.onPtyData = { received.append($0) }
        try await relay.start()

        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("A".utf8)))
        try await waitUntil { received.joined == "A" }

        await feed.push(gridSnapshotFrame(surfaceID: surfaceID, ansi: Data("JUNK-ANSI".utf8)))
        // Post-snapshot the wire seq restarts at 0; the next live chunk
        // must be delivered without a spurious gap heal (or JUNK bytes).
        await feed.push(ptyDataFrame(surfaceID: surfaceID, byteSeq: 0, payload: Data("B".utf8)))

        try await waitUntil { received.joined == "AB" }
        XCTAssertEqual(received.joined, "AB", "snapshot ANSI must never reach the callback")

        await relay.stop()
        await feed.finish()
    }
}

// MARK: - Relay stall production logging

/// The gate behind the release-build stall lines. The DEBUG `dlog` edges
/// vanish from release builds, so this gate is the only thing standing
/// between "pane froze" and "every log is silent" — and the only thing
/// standing between a stall storm and a log flood.
final class RelayStallLogGateTests: XCTestCase {
    func testIgnoresJitterAndLogsTheFirstSustainedEpisode() {
        var gate = RelayStallLogGate(thresholdNanos: 100, minIntervalNanos: 1_000)
        XCTAssertFalse(gate.recordEpisode(durationNanos: 99, now: 0),
                       "below the threshold: neither counted nor logged")
        XCTAssertEqual(gate.episodeCount, 0,
                       "call sites time every operation — jitter in the totals would report ordinary traffic as stalls")
        XCTAssertEqual(gate.stalledNanosTotal, 0)
        XCTAssertTrue(gate.recordEpisode(durationNanos: 100, now: 10),
                      "the first sustained episode logs")
        XCTAssertEqual(gate.episodeCount, 1)
    }

    func testMinIntervalSuppressesAStormButNotForever() {
        var gate = RelayStallLogGate(thresholdNanos: 100, minIntervalNanos: 1_000)
        XCTAssertTrue(gate.recordEpisode(durationNanos: 500, now: 10))
        XCTAssertFalse(gate.recordEpisode(durationNanos: 500, now: 500),
                       "inside the interval: suppressed even though sustained")
        XCTAssertTrue(gate.recordEpisode(durationNanos: 500, now: 1_010),
                      "interval measured from the last EMITTED line, so the storm logs again")
        XCTAssertEqual(gate.episodeCount, 3)
        XCTAssertEqual(gate.stalledNanosTotal, 1_500,
                       "suppressed episodes still accumulate into the totals the next line reports")
    }

    func testSuppressedEpisodesDoNotAdvanceTheInterval() {
        var gate = RelayStallLogGate(thresholdNanos: 100, minIntervalNanos: 1_000)
        XCTAssertTrue(gate.recordEpisode(durationNanos: 200, now: 0))
        XCTAssertFalse(gate.recordEpisode(durationNanos: 200, now: 999))
        XCTAssertTrue(gate.recordEpisode(durationNanos: 200, now: 1_000),
                      "a suppressed episode must not push the next line further away")
    }

    /// The locked wrapper the host-side input closure uses: the verdict and
    /// the totals for the log line must come out of the same lock hold.
    func testGateBoxReportsTheTotalsTheLogLineNeeds() {
        let box = RelayStallLogGateBox(
            gate: RelayStallLogGate(thresholdNanos: 100, minIntervalNanos: 1_000)
        )
        let first = box.recordEpisode(durationNanos: 200, now: 0)
        XCTAssertTrue(first.shouldLog)
        XCTAssertEqual(first.episodeCount, 1)
        XCTAssertEqual(first.stalledNanosTotal, 200)
        let second = box.recordEpisode(durationNanos: 300, now: 10)
        XCTAssertFalse(second.shouldLog, "inside the interval")
        XCTAssertEqual(second.episodeCount, 2)
        XCTAssertEqual(second.stalledNanosTotal, 500)
    }
}

// MARK: - Peer-owned agent surfaces (Phase 3, T3.1)

/// The third remote-agent factory: `ensure(kind: "agent")` against a peer
/// daemon that owns `tm-agent-bridge` itself.
///
/// What is pinned here is everything that is decided BEFORE any UI exists —
/// which factory a member gets, what the ensure request actually carries, and
/// how a surface that outlived its attach is taken back down. The pane itself
/// is `Workspace.openRemoteAgentPane`, tested with the rest of Phase 2.
final class PeerOwnedAgentSurfaceTests: XCTestCase {

    /// The regression this exists for: the SSH-owned launch site assembled
    /// this merge by hand and left the profile layer out, so a remote pane
    /// started with the host's stored keys but without the active CLI
    /// profile's gateway settings. Authentication then failed against the
    /// wrong endpoint, far from the code that dropped them.
    @MainActor
    func test_remoteNativeLaunchEnvironmentCarriesTheActiveProfileLayer() throws {
        var askedForCLI: String?
        let merged = try TeamOrchestrator.remoteNativeAgentLaunchEnvironment(
            cli: "claude",
            hostKey: "host-1",
            internalIdentity: ["TERMMESH_TEAM": "real"],
            profileLookup: { cli in
                askedForCLI = cli
                return [
                    "ANTHROPIC_BASE_URL": "https://gateway.example",
                    "ANTHROPIC_AUTH_TOKEN": "profile-token",
                    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
                ]
            },
            hostLookup: { _ in ["AI_MESH_API_KEY": "host-key"] }
        )

        // The profile is consulted for the CLI actually being launched, not a
        // hardcoded one — a codex pane must not inherit claude's gateway.
        XCTAssertEqual(askedForCLI, "claude")
        XCTAssertEqual(merged["ANTHROPIC_BASE_URL"], "https://gateway.example")
        XCTAssertEqual(merged["ANTHROPIC_AUTH_TOKEN"], "profile-token")
        XCTAssertEqual(merged["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"], "1")
        // The host layer that kept working while the profile layer was missing
        // — its presence is what made the failure look partial rather than
        // structural.
        XCTAssertEqual(merged["AI_MESH_API_KEY"], "host-key")
    }

    /// Precedence has to survive the extraction: a host may override a
    /// profile, but neither may override term-mesh's own identity.
    @MainActor
    func test_remoteNativeLaunchEnvironmentKeepsLayerPrecedence() throws {
        let merged = try TeamOrchestrator.remoteNativeAgentLaunchEnvironment(
            cli: "claude",
            hostKey: "host-1",
            internalIdentity: ["TERMMESH_TEAM": "real"],
            profileLookup: { _ in ["SHARED": "profile", "TERMMESH_TEAM": "spoof"] },
            hostLookup: { _ in ["SHARED": "host", "TERMMESH_TEAM": "also-spoof"] }
        )
        XCTAssertEqual(merged["SHARED"], "host")
        XCTAssertEqual(merged["TERMMESH_TEAM"], "real")
    }

    /// Both ownership models must produce the same environment for the same
    /// inputs. They diverged once by being written out separately; this is the
    /// property that divergence broke.
    @MainActor
    func test_bothOwnershipModelsAgreeOnTheSameInputs() throws {
        let profile = ["ANTHROPIC_BASE_URL": "https://gateway.example"]
        let host = ["AI_MESH_API_KEY": "host-key"]
        let identity = ["TERMMESH_TEAM": "real"]

        let viaLaunchHelper = try TeamOrchestrator.remoteNativeAgentLaunchEnvironment(
            cli: "claude",
            hostKey: "host-1",
            internalIdentity: identity,
            profileLookup: { _ in profile },
            hostLookup: { _ in host }
        )
        let viaPeerHelper = try TeamOrchestrator.peerOwnedAgentEnvironment(
            profile: profile,
            explicitHost: host,
            internalIdentity: identity
        )
        XCTAssertEqual(viaLaunchHelper, viaPeerHelper)
    }

    @MainActor
    func test_configuredRemoteAgentEnvironmentIncludesProfileAndLetsHostOverride() {
        let merged = TeamOrchestrator.configuredRemoteAgentEnvironment(
            profile: ["AI_MESH_API_KEY": "profile-secret", "PROFILE_ONLY": "yes"],
            explicitHost: ["AI_MESH_API_KEY": "host-secret", "HOST_ONLY": "yes"]
        )

        XCTAssertEqual(merged["AI_MESH_API_KEY"], "host-secret")
        XCTAssertEqual(merged["PROFILE_ONLY"], "yes")
        XCTAssertEqual(merged["HOST_ONLY"], "yes")
    }

    @MainActor
    func test_peerOwnedEnvironmentPrecedenceAndValidationAreDeterministic() throws {
        let merged = try TeamOrchestrator.peerOwnedAgentEnvironment(
            profile: ["SHARED": "profile", "PROFILE_ONLY": "yes"],
            explicitHost: ["SHARED": "host", "HOST_ONLY": "yes", "TERMMESH_TEAM": "spoof"],
            internalIdentity: ["TERMMESH_TEAM": "real", "INTERNAL_ONLY": "yes"]
        )
        XCTAssertEqual(merged["SHARED"], "host")
        XCTAssertEqual(merged["PROFILE_ONLY"], "yes")
        XCTAssertEqual(merged["HOST_ONLY"], "yes")
        XCTAssertEqual(merged["TERMMESH_TEAM"], "real")
        XCTAssertEqual(merged["INTERNAL_ONLY"], "yes")

        XCTAssertThrowsError(try TeamOrchestrator.peerOwnedAgentEnvironment(
            profile: ["유니코드": "TOP_SECRET_VALUE"],
            explicitHost: [:],
            internalIdentity: [:]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("ASCII identifier"))
            let message = TeamOrchestrator.peerOwnedAgentInvalidEnvironmentFallbackMessage(
                error as! PeerEnsureEnvironment.ValidationError,
                cli: "codex",
                hostName: "jw-server"
            )
            XCTAssertTrue(message.contains("active CLI profile"))
            XCTAssertTrue(message.contains("유니코드"))
            XCTAssertFalse(message.contains("TOP_SECRET_VALUE"),
                           "environment values must never be logged")
        }
    }

    // MARK: Factory selection matrix

    /// The whole routing table in one place.
    ///
    /// Claude speaks stream-json directly from a daemon-owned agent surface;
    /// every other native CLI uses the bridge on that daemon.
    @MainActor
    func test_factoryMatrix_capabilityTimesBridgeTimesCLI() {
        func route(
            _ cli: String,
            capability: Bool,
            bridgePath: String = "/usr/local/bin/tm-agent-bridge",
            sshTarget: String? = "root@jw-server"
        ) -> TeamOrchestrator.RemoteAgentFactory {
            TeamOrchestrator.remoteAgentFactory(
                cli: cli,
                hostAdvertisesAgentSurfaces: capability,
                peerBridgePath: bridgePath,
                sshTarget: sshTarget
            )
        }

        // Codex and Kiro prefer peer ownership, but an older host changes
        // ownership rather than the Native renderer the user selected.
        for cli in ["codex", "kiro"] {
            XCTAssertEqual(route(cli, capability: true), .peerOwnedAgent, cli)
            XCTAssertEqual(
                route(cli, capability: false), .localNativeBridge,
                "\(cli): a daemon without surface.agent.v1 must keep a Native pane over SSH"
            )
            XCTAssertEqual(
                route(cli, capability: true, bridgePath: ""), .localNativeBridge,
                "\(cli): no bridge on the host changes ownership, not rendering"
            )
            XCTAssertEqual(
                route(cli, capability: true, sshTarget: nil), .terminal,
                "\(cli): a host with no ssh target cannot be probed for paths"
            )
        }

        // Turn-per-process CLIs can be owned by the peer bridge too.
        for cli in ["cursor", "agy"] {
            XCTAssertEqual(route(cli, capability: true), .peerOwnedAgent, cli)
            XCTAssertEqual(
                route(cli, capability: false), .localNativeBridge,
                "\(cli): an old daemon keeps the existing SSH-owned fallback"
            )
            XCTAssertEqual(
                route(cli, capability: true, sshTarget: nil), .terminal,
                "\(cli): the local bridge is an ssh child; without a target there is none"
            )
        }

        // Claude needs no bridge, only an agent-capable daemon.
        XCTAssertEqual(route("claude", capability: true), .peerOwnedAgent)
        XCTAssertEqual(route("claude", capability: false), .localNativeBridge)
        // gemini: the bridge speaks it, but no native panel holds it today.
        XCTAssertEqual(route("gemini", capability: true), .terminal)
    }

    /// Turning native panes off must take every native route with it — the
    /// setting is the user saying "give me terminal panes".
    @MainActor
    func test_factoryMatrix_nativePanesOffCollapsesEverythingToTerminal() {
        let defaults = UserDefaults.standard
        let key = AgentPipeTransport.nativePanelKey
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        for cli in ["claude", "codex", "kiro", "cursor", "agy", "gemini"] {
            XCTAssertEqual(
                TeamOrchestrator.remoteAgentFactory(
                    cli: cli,
                    hostAdvertisesAgentSurfaces: true,
                    peerBridgePath: "/usr/local/bin/tm-agent-bridge",
                    sshTarget: "root@jw-server"
                ),
                .terminal,
                cli
            )
        }
    }

    /// The routing table in full, as literal data.
    ///
    /// The test above asserts the intentions; this one asserts that nothing
    /// else changed while they were being honoured. Native is a renderer
    /// contract: capability and bridge availability may only choose between
    /// peer-owned and SSH-owned Native processes.
    ///
    /// Columns are (ssh, capability, bridge) counted in binary, the same order
    /// for every row, so one row is one CLI's entire story.
    @MainActor
    func test_factoryMatrix_isTotalOverSSHCapabilityAndBridge() {
        let restore = Self.forceNativePanes(true)
        defer { restore() }

        typealias Factory = TeamOrchestrator.RemoteAgentFactory
        let T = Factory.terminal
        let P = Factory.peerOwnedAgent
        let L = Factory.localNativeBridge

        //                         no ssh          ssh
        //                     ---------------  ---------------
        //   (cap, bridge) →   00  01  10  11   00  01  10  11
        let table: [(String, [Factory])] = [
            // Claude's direct stream-json recipe does not depend on the bridge.
            ("claude", [T, T, T, T, L, L, P, P]),
            ("gemini", [T, T, T, T, T, T, T, T]),
            // Peer ownership only in the last cell; every other SSH cell remains native.
            ("codex", [T, T, T, T, L, L, L, P]),
            ("kiro", [T, T, T, T, L, L, L, P]),
            ("cursor", [T, T, T, T, L, L, L, P]),
            ("agy", [T, T, T, T, L, L, L, P]),
        ]

        for (cli, expected) in table {
            for index in 0..<8 {
                let ssh = index & 0b100 != 0
                let capability = index & 0b010 != 0
                let bridge = index & 0b001 != 0
                XCTAssertEqual(
                    TeamOrchestrator.remoteAgentFactory(
                        cli: cli,
                        hostAdvertisesAgentSurfaces: capability,
                        peerBridgePath: bridge ? "/usr/local/bin/tm-agent-bridge" : "",
                        sshTarget: ssh ? "root@jw-server" : nil
                    ),
                    expected[index],
                    "\(cli): ssh=\(ssh) capability=\(capability) bridge=\(bridge)"
                )
            }
        }
    }

    /// An empty ssh target is the same fact as a nil one — a host reached on a
    /// local socket cannot be probed for paths, so neither remote factory has
    /// anything to work with.
    @MainActor
    func test_factoryMatrix_anEmptySSHTargetCountsAsNoSSHTarget() {
        let restore = Self.forceNativePanes(true)
        defer { restore() }

        for cli in ["codex", "kiro", "cursor", "agy"] {
            XCTAssertEqual(
                TeamOrchestrator.remoteAgentFactory(
                    cli: cli,
                    hostAdvertisesAgentSurfaces: true,
                    peerBridgePath: "/usr/local/bin/tm-agent-bridge",
                    sshTarget: ""
                ),
                .terminal,
                cli
            )
        }
    }

    // MARK: Why a fallback happened

    /// The availability check must answer for the CLIs that could never use
    /// the peer-owned path WITHOUT reaching for the network — both because a
    /// handshake per claude member is pure latency, and because `notApplicable`
    /// and `blocked` mean opposite things to the caller: one is a fallback the
    /// user should be told about, the other is simply how that CLI runs.
    @MainActor
    func test_availability_separatesNothingWasLostFromSomethingWasLost() async {
        let restore = Self.forceNativePanes(true)
        defer { restore() }

        let bridged = TeamOrchestrator.RemoteAgentBinaries(
            cliPath: "/root/.local/bin/codex",
            bridgePath: "/usr/local/bin/tm-agent-bridge",
            cliAvailable: true
        )

        // Never had the path: no probe, no report.
        for cli in ["gemini"] {
            let answer = await TeamOrchestrator.canUsePeerOwnedAgent(
                host: Self.agentHostEntry(),
                cli: cli,
                binaries: bridged
            )
            XCTAssertEqual(answer, .notApplicable, cli)
        }

        // Reached without ssh: same — there is no path to resolve, so this is
        // how the member runs rather than something it lost.
        let noSSH = await TeamOrchestrator.canUsePeerOwnedAgent(
            host: Self.agentHostEntry(sshTarget: nil),
            cli: "codex",
            binaries: bridged
        )
        XCTAssertEqual(noSSH, .notApplicable)

        // Had the path and lost it: each with its own repair.
        let noBridge = await TeamOrchestrator.canUsePeerOwnedAgent(
            host: Self.agentHostEntry(),
            cli: "codex",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/root/.local/bin/codex", bridgePath: "", cliAvailable: true
            )
        )
        XCTAssertEqual(noBridge, .blocked(.bridgeMissing))

        let noSocket = await TeamOrchestrator.canUsePeerOwnedAgent(
            host: Self.agentHostEntry(activeSockPath: ""),
            cli: "codex",
            binaries: bridged
        )
        XCTAssertEqual(
            noSocket, .blocked(.hostUnreachable),
            "with no socket the capability is unknown, which is not the same as absent"
        )
    }

    /// The line the user actually reads. Every reason must name the CLI, the
    /// host and the ownership fallback — and the two most easily confused repairs
    /// ("install it there" vs "update it there") must not read alike, because
    /// following the wrong one leaves the pane exactly as it was.
    @MainActor
    func test_fallbackMessage_namesTheCLITheHostAndOneRepair() {
        var seen: Set<String> = []
        for block in TeamOrchestrator.PeerOwnedAgentBlock.allCases {
            let message = TeamOrchestrator.peerOwnedAgentFallbackMessage(
                block, cli: "codex", hostName: "jw-server"
            )
            XCTAssertTrue(message.contains("codex"), "\(block): names the CLI")
            XCTAssertTrue(message.contains("jw-server"), "\(block): names the host")
            XCTAssertTrue(
                message.contains("SSH-owned native agent pane"),
                "\(block): says which native ownership route opened"
            )
            XCTAssertTrue(seen.insert(message).inserted, "\(block): reads like another reason")
        }

        XCTAssertTrue(
            TeamOrchestrator.peerOwnedAgentFallbackMessage(
                .bridgeMissing, cli: "codex", hostName: "jw-server"
            ).contains("Install term-mesh")
        )
        XCTAssertTrue(
            TeamOrchestrator.peerOwnedAgentFallbackMessage(
                .daemonTooOld, cli: "codex", hostName: "jw-server"
            ).contains("Restart or update term-mesh")
        )
        XCTAssertTrue(
            TeamOrchestrator.peerOwnedAgentFallbackMessage(
                .ensureRefused, cli: "codex", hostName: "jw-server"
            ).contains("Nothing was left running there"),
            "a refused ensure creates nothing on the peer, and saying so is what "
                + "stops someone going to look for a stray bridge"
        )
    }

    /// Project and team creation consume the team endpoint snapshot, never the
    /// serving endpoint's raw capability. This is the #279 regression matrix:
    /// a GUI serving socket may be incapable while its advertised daemon is
    /// fully capable.
    @MainActor
    func test_creationPreflight_namesServingVersionBeforeNativeOwnershipFallback() {
        let restore = Self.forceNativePanes(true)
        defer { restore() }

        var host = Self.agentHostEntry()
        host.displayName = "mac-sub"
        host.sessionHostRemoteSockPath = ""

        func row(_ cli: String) -> TeamAgentRow {
            TeamAgentRow(
                preset: AgentRolePreset(
                    id: UUID(), name: cli, displayName: cli.capitalized,
                    cli: cli, model: "sonnet", color: "blue",
                    instructions: "", isBuiltIn: false
                ),
                customInstructions: "",
                hostKey: host.id
            )
        }

        func snapshot(
            supportsOwned: Bool,
            supportsRoute: Bool = true,
            gui: Bool = false,
            redirected: Bool = false,
            version: String = "0.179.0"
        ) -> TeamHostCapabilitySnapshot {
            TeamHostCapabilitySnapshot(
                endpoint: host.teamHostSpec!.hostKey,
                appVersion: version,
                supportsPeerOwnedAgentHosting: supportsOwned,
                supportsRemoteTeamRoute: supportsRoute,
                looksLikeGUIPeerHost: gui,
                redirectedFromServingEndpoint: redirected
            )
        }

        host.teamHostReadiness = .ready(snapshot(supportsOwned: false))
        var notices = TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("codex"), row("kiro"), row("claude")],
            hosts: [host]
        )
        XCTAssertEqual(notices.count, 1, "one host gets one preflight warning")
        XCTAssertEqual(notices[0].teamHostVersion, "v0.179.0")
        XCTAssertEqual(notices[0].clis, ["claude", "codex", "kiro"])
        XCTAssertEqual(notices[0].reason, .daemonTooOld)
        XCTAssertTrue(notices[0].message.contains("Update and restart"))

        host.teamHostReadiness = .ready(snapshot(supportsOwned: false, supportsRoute: false))
        let blocked = TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("codex"), row("claude")], hosts: [host]
        )
        XCTAssertEqual(blocked.count, 1)
        XCTAssertFalse(blocked[0].blocksTeamMessaging)
        XCTAssertFalse(
            TeamAgentComposer.blocksRemoteTeamCreation(
                agents: [row("codex")], hosts: [host]
            ),
            "SSH-owned Native has its own scoped reverse control route"
        )

        host.sshTarget = nil
        let noSSHRoute = TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("codex"), row("claude")], hosts: [host]
        )
        XCTAssertEqual(noSSHRoute.count, 1)
        XCTAssertTrue(noSSHRoute[0].blocksTeamMessaging)
        XCTAssertTrue(noSSHRoute[0].message.contains("tm-agent returns no_app"))

        host.sshTarget = "root@jw-server"
        host.teamHostReadiness = .ready(snapshot(supportsOwned: true))
        XCTAssertTrue(
            TeamAgentComposer.peerOwnedFallbackNotices(
                agents: [row("codex")], hosts: [host]
            ).isEmpty,
            "a compatible team endpoint needs no warning"
        )

        host.teamHostReadiness = .ready(snapshot(
            supportsOwned: false, supportsRoute: false, gui: true, redirected: false
        ))
        notices = TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("claude")], hosts: [host]
        )
        XCTAssertEqual(notices.first?.reason, .guiHostNoSessionOwner)
        XCTAssertFalse(notices.first?.message.contains("Update and restart") == true)

        // The exact regression: the serving GUI says false, but team work is
        // redirected to a capable daemon. Only the daemon snapshot may decide.
        host.sessionHostRemoteSockPath = "/run/user/501/term-meshd.sock"
        host.teamHostReadiness = .ready(TeamHostCapabilitySnapshot(
            endpoint: host.teamHostSpec!.hostKey, appVersion: "0.193.0",
            supportsPeerOwnedAgentHosting: true, supportsRemoteTeamRoute: true,
            looksLikeGUIPeerHost: false, redirectedFromServingEndpoint: true
        ))
        XCTAssertTrue(TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("claude")], hosts: [host]
        ).isEmpty)
        XCTAssertFalse(TeamAgentComposer.blocksRemoteTeamCreation(
            agents: [row("claude")], hosts: [host], requiresDurableProject: true
        ))

        host.teamHostReadiness = .probing(host.teamHostSpec!.hostKey)
        XCTAssertEqual(TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("claude")], hosts: [host]
        ).first?.reason, .checkingTeamHost)
        XCTAssertTrue(TeamAgentComposer.blocksRemoteTeamCreation(
            agents: [row("claude")], hosts: [host], requiresDurableProject: true
        ))

        host.teamHostReadiness = .unreachable(host.teamHostSpec!.hostKey)
        XCTAssertEqual(TeamAgentComposer.peerOwnedFallbackNotices(
            agents: [row("claude")], hosts: [host]
        ).first?.reason, .teamHostUnreachable)
    }

    @MainActor
    func test_peerOwnedAvailabilityUsesTheSameTeamEndpointSnapshotAsPreflight() {
        let endpoint = PeerPaneHostKey.ssh(
            target: "root@host", remoteSockPath: "/run/term-mesh/peer.sock", port: nil
        )
        XCTAssertEqual(TeamOrchestrator.peerOwnedAvailability(from: .init(
            endpoint: endpoint, appVersion: "0.200.0",
            supportsPeerOwnedAgentHosting: true, supportsRemoteTeamRoute: true,
            looksLikeGUIPeerHost: false, redirectedFromServingEndpoint: true
        )), .available)
        XCTAssertEqual(TeamOrchestrator.peerOwnedAvailability(from: .init(
            endpoint: endpoint, appVersion: "0.190.0",
            supportsPeerOwnedAgentHosting: false, supportsRemoteTeamRoute: true,
            looksLikeGUIPeerHost: false, redirectedFromServingEndpoint: true
        )), .blocked(.daemonTooOld))
        XCTAssertEqual(TeamOrchestrator.peerOwnedAvailability(from: .init(
            endpoint: endpoint, appVersion: "0.190.0",
            supportsPeerOwnedAgentHosting: true, supportsRemoteTeamRoute: false,
            looksLikeGUIPeerHost: false, redirectedFromServingEndpoint: true
        )), .blocked(.daemonTooOld))
        XCTAssertEqual(TeamOrchestrator.peerOwnedAvailability(from: .init(
            endpoint: endpoint, appVersion: "0.200.0",
            supportsPeerOwnedAgentHosting: false, supportsRemoteTeamRoute: true,
            looksLikeGUIPeerHost: true, redirectedFromServingEndpoint: false
        )), .blocked(.guiHostNoSessionOwner))

        let staleRouteSnapshot = TeamHostCapabilitySnapshot(
            endpoint: endpoint, appVersion: "0.190.0",
            supportsPeerOwnedAgentHosting: true, supportsRemoteTeamRoute: false,
            looksLikeGUIPeerHost: false, redirectedFromServingEndpoint: true
        )
        XCTAssertTrue(TeamOrchestrator.teamRouteAllowsFactory(
            .peerOwnedAgent, liveAvailability: .available,
            cachedSnapshot: staleRouteSnapshot
        ), "the live team-endpoint handshake wins over stale preflight cache")
        XCTAssertTrue(TeamOrchestrator.teamRouteAllowsFactory(
            .localNativeBridge, liveAvailability: .blocked(.daemonTooOld),
            cachedSnapshot: staleRouteSnapshot
        ), "SSH-owned Native has its own private reverse route")
        XCTAssertFalse(TeamOrchestrator.teamRouteAllowsFactory(
            .terminal, liveAvailability: .notApplicable,
            cachedSnapshot: staleRouteSnapshot
        ))
    }

    @MainActor
    func test_teamHostLaunchWaitRequiresBothLaunchMetadataAndResolvedRoute() {
        var host = Self.agentHostEntry()
        XCTAssertFalse(TeamOrchestrator.teamHostCanLaunch(host))

        let provenance = PeerHostEndpointProvenance(
            sshTarget: "root@jw-server", port: nil, identityFile: nil,
            remoteSocket: "/run/user/0/tm-peer.sock"
        )
        host.configuredEndpoint = provenance
        _ = host.acceptAuthenticatedHostCLIBinDirs(["/usr/local/bin"], provenance: provenance)
        XCTAssertTrue(host.isLaunchable)
        XCTAssertFalse(TeamOrchestrator.teamHostCanLaunch(host))

        host.sessionHostRemoteSockPath = ""
        XCTAssertFalse(
            TeamOrchestrator.teamHostCanLaunch(host),
            "the route answer alone is not an endpoint capability proof"
        )
        let endpoint = host.teamHostSpec!.hostKey
        host.teamHostReadiness = .ready(TeamHostCapabilitySnapshot(
            endpoint: endpoint, appVersion: "0.200.0",
            supportsPeerOwnedAgentHosting: true, supportsRemoteTeamRoute: true,
            looksLikeGUIPeerHost: false, redirectedFromServingEndpoint: false
        ))
        XCTAssertTrue(TeamOrchestrator.teamHostCanLaunch(host))
    }

    /// A remote worker reaches the owning team through the same scoped
    /// reverse route as a peer leader. Pointing TERMMESH_SOCKET at the remote
    /// daemon without these fields deterministically returns `no_app`.
    @MainActor
    func test_remoteNativeAgentEnvironmentCarriesScopedTeamRoute() {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 0xab, count: PeerTeamLeader.grantIDBytes)
        grant.projectID = "name:mesh-test"
        grant.teamUuid = "team-uuid"
        grant.role = .leader
        grant.expiresAtUnixSecs = 123_456

        let env = TeamOrchestrator.remoteNativeAgentEnvironment(
            teamName: "mesh-test",
            agentName: "executor",
            agentType: "executor",
            agentCli: "codex",
            workspaceId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            socketPath: "/tmp/remote-term-mesh.sock",
            routeGrant: grant
        )

        XCTAssertEqual(env["TERMMESH_SOCKET"], "/tmp/remote-term-mesh.sock")
        XCTAssertEqual(env["TERMMESH_TEAM_NAME"], "mesh-test")
        XCTAssertEqual(env["TERMMESH_AGENT_NAME"], "executor")
        XCTAssertEqual(env["TERMMESH_LEADER_GRANT_ID"], String(repeating: "ab", count: 32))
        XCTAssertEqual(env["TERMMESH_LEADER_PROJECT_ID"], "name:mesh-test")
        XCTAssertEqual(env["TERMMESH_LEADER_TEAM_UUID"], "team-uuid")
        XCTAssertEqual(env["TERMMESH_LEADER_EXPIRES_AT"], "123456")
        XCTAssertEqual(env["TERMMESH_LEADER_PEER_ID"]?.count, 32)
    }

    @MainActor
    func test_peerOwnedAgentEnvironmentPreservesDaemonControlSocket() {
        let env = TeamOrchestrator.remoteNativeAgentEnvironment(
            teamName: "mesh-test",
            agentName: "executor",
            agentType: "executor",
            agentCli: "codex",
            workspaceId: UUID(),
            socketPath: nil
        )

        XCTAssertNil(env["TERMMESH_SOCKET"])
        XCTAssertNil(env["CMUX_SOCKET"])
    }

    @MainActor
    func test_sshOwnedAgentUsesPrivateReverseControlSocket() {
        let first = TeamOrchestrator.sshOwnedAgentReverseForward(
            agentInstanceID: "A1B2-C3D4",
            localControlSocket: "/tmp/term-mesh-debug-route.sock"
        )
        let second = TeamOrchestrator.sshOwnedAgentReverseForward(
            agentInstanceID: "FFFF-EEEE",
            localControlSocket: "/tmp/term-mesh-debug-route.sock"
        )

        XCTAssertEqual(first.local, "/tmp/term-mesh-debug-route.sock")
        XCTAssertEqual(first.remote, "/tmp/term-mesh-agent-route-a1b2-c3d4.sock")
        XCTAssertNotEqual(first.remote, second.remote)
        XCTAssertLessThan(first.remote.utf8.count, 104)
    }

    // MARK: - Transferable route file

    /// The environment names a path, and `tm-agent` reads the grant out of it
    /// on every invocation. That indirection is the whole fix: a second viewer
    /// adopting the project can replace the file, and cannot replace the
    /// environment of a process that is already running.
    @MainActor
    func test_remoteNativeAgentEnvironmentNamesTheTransferableRouteFile() {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 0xab, count: PeerTeamLeader.grantIDBytes)
        grant.projectID = "name:mesh-test"
        grant.teamUuid = "team-uuid"
        grant.expiresAtUnixSecs = 123_456

        let env = TeamOrchestrator.remoteNativeAgentEnvironment(
            teamName: "mesh-test",
            agentName: "executor",
            agentType: "executor",
            agentCli: "codex",
            workspaceId: UUID(),
            socketPath: nil,
            routeGrant: grant,
            routeFilePath: "/home/agent/.term-mesh/agent-routes/abc.json"
        )

        XCTAssertEqual(
            env[TeamOrchestrator.remoteTeamRouteFileEnvName],
            "/home/agent/.term-mesh/agent-routes/abc.json"
        )
        XCTAssertEqual(
            env["TERMMESH_LEADER_GRANT_ID"],
            String(repeating: "ab", count: 32),
            "the frozen variables stay as the fallback for an older worker"
        )
    }

    @MainActor
    func test_remoteLeaderRouteFileNameIsDeterministicAndDistinctFromWorkers() {
        let first = TeamOrchestrator.remoteLeaderRouteFileName(
            teamUUID: "05AC84AA-0000-0000-0000-000000000000"
        )
        let second = TeamOrchestrator.remoteLeaderRouteFileName(
            teamUUID: "05AC84AA-0000-0000-0000-000000000000"
        )
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("leader-05ac84aa"))
        XCTAssertNotEqual(
            first,
            TeamOrchestrator.remoteAgentRouteFileName(agentInstanceID: "worker-1")
        )
    }

    @MainActor
    func test_collaborationRecoveryPlanReplacesOnlyDeadWorkersWhenLeaderIsLive() {
        let workspaceID = UUID()
        let leaderID = Data(repeating: 0x01, count: 16)
        let liveID = Data(repeating: 0x02, count: 16)
        let deadID = Data(repeating: 0x03, count: 16)
        func agent(_ name: String, _ instance: String, _ surface: Data) -> TeamOrchestrator.AgentMember {
            TeamOrchestrator.AgentMember(
                id: "\(name)@aic", agentInstanceId: instance, name: name,
                teamName: "aic", cli: "codex", launchCommand: "codex",
                model: "gpt-5.6-sol", agentType: name, color: "blue",
                instructions: "", workspaceId: workspaceID, panelId: UUID(),
                createdAt: Date(), remoteSurfaceID: surface,
                remoteSurfaceSpawned: true, remoteAgentSurface: true,
                hostKey: "ssh:mac-sub"
            )
        }
        var leader = Termmesh_Peer_V1_SurfaceInfo()
        leader.surfaceID = leaderID
        leader.attachable = true
        leader.foregroundBusyKnown = true
        leader.foregroundBusy = true
        var live = Termmesh_Peer_V1_SurfaceInfo()
        live.surfaceID = liveID
        live.surfaceType = "agent"
        live.attachable = true
        var dead = Termmesh_Peer_V1_SurfaceInfo()
        dead.surfaceID = deadID
        dead.surfaceType = "agent"
        dead.attachable = false

        let plan = TeamOrchestrator.collaborationRecoveryPlan(
            leaderSurfaceID: leaderID,
            agents: [agent("executor", "live", liveID), agent("reviewer", "dead", deadID)],
            surfaces: [leader, live, dead]
        )
        XCTAssertTrue(plan.leaderLive)
        XCTAssertEqual(plan.liveAgentCount, 1)
        XCTAssertEqual(plan.deadAgentInstanceIDs, ["dead"])
    }

    /// The roster is remote input, so two rows can share a surface id — the
    /// protobuf default empty Data included. Building the lookup with
    /// `Dictionary(uniqueKeysWithValues:)` trapped on that and took the app
    /// down inside the recovery path it was supposed to run.
    func test_collaborationRecoveryPlanSurvivesDuplicateSurfaceIDs() {
        let workspaceID = UUID()
        let leaderID = Data(repeating: 0x01, count: 16)
        let sharedID = Data(repeating: 0x02, count: 16)
        func agent(_ name: String, _ instance: String, _ surface: Data) -> TeamOrchestrator.AgentMember {
            TeamOrchestrator.AgentMember(
                id: "\(name)@aic", agentInstanceId: instance, name: name,
                teamName: "aic", cli: "codex", launchCommand: "codex",
                model: "gpt-5.6-sol", agentType: name, color: "blue",
                instructions: "", workspaceId: workspaceID, panelId: UUID(),
                createdAt: Date(), remoteSurfaceID: surface,
                remoteSurfaceSpawned: true, remoteAgentSurface: true,
                hostKey: "ssh:mac-sub"
            )
        }
        var leader = Termmesh_Peer_V1_SurfaceInfo()
        leader.surfaceID = leaderID
        leader.attachable = true
        leader.foregroundBusyKnown = true
        leader.foregroundBusy = true
        var first = Termmesh_Peer_V1_SurfaceInfo()
        first.surfaceID = sharedID
        first.surfaceType = "agent"
        first.attachable = true
        var duplicate = Termmesh_Peer_V1_SurfaceInfo()
        duplicate.surfaceID = sharedID
        duplicate.surfaceType = "agent"
        duplicate.attachable = false
        var empty = Termmesh_Peer_V1_SurfaceInfo()
        empty.surfaceType = "agent"
        var alsoEmpty = Termmesh_Peer_V1_SurfaceInfo()
        alsoEmpty.surfaceType = "agent"

        let plan = TeamOrchestrator.collaborationRecoveryPlan(
            leaderSurfaceID: leaderID,
            agents: [agent("executor", "shared", sharedID)],
            surfaces: [leader, first, duplicate, empty, alsoEmpty]
        )
        // First row wins, so the attachable one still counts as live.
        XCTAssertTrue(plan.leaderLive)
        XCTAssertEqual(plan.liveAgentCount, 1)
        XCTAssertEqual(plan.deadAgentInstanceIDs, [])
    }

    @MainActor
    func test_collaborationRecoveryPlanWithholdsWorkerReplacementWhenLeaderIsDead() {
        var leader = Termmesh_Peer_V1_SurfaceInfo()
        leader.surfaceID = Data(repeating: 0x01, count: 16)
        leader.attachable = true
        leader.foregroundBusyKnown = true
        leader.foregroundBusy = false
        let plan = TeamOrchestrator.collaborationRecoveryPlan(
            leaderSurfaceID: leader.surfaceID, agents: [], surfaces: [leader]
        )
        XCTAssertFalse(plan.leaderLive)
    }

    func test_collaborationLeaderRepairKeepsAuthoritativelyLiveLeader() {
        let leaderID = Data(repeating: 0x41, count: 16)
        var surface = Termmesh_Peer_V1_SurfaceInfo()
        surface.surfaceID = leaderID
        surface.foregroundBusyKnown = true
        surface.foregroundBusy = true
        let remote = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [], projectID: "team:uuid",
            leaderSurfaceID: leaderID, leaderCLI: "codex",
            leaderModel: "gpt-5.6-sol", leaderProcessActive: true,
            leaderProcessActiveKnown: true
        )

        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderRepairDecision(
                remoteTeam: remote, surfaces: [surface]
            ),
            .keepExisting
        )
    }

    func test_collaborationLeaderRepairBootstrapsMissingOrInactiveLeader() {
        let leaderID = Data(repeating: 0x42, count: 16)
        var inactiveSurface = Termmesh_Peer_V1_SurfaceInfo()
        inactiveSurface.surfaceID = leaderID
        inactiveSurface.foregroundBusyKnown = true
        inactiveSurface.foregroundBusy = false
        let inactive = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [], projectID: "team:uuid",
            leaderSurfaceID: leaderID, leaderProcessActive: false,
            leaderProcessActiveKnown: true
        )

        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderRepairDecision(
                remoteTeam: inactive, surfaces: [inactiveSurface]
            ),
            .bootstrapReplacement
        )
        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderRepairDecision(
                remoteTeam: inactive, surfaces: []
            ),
            .bootstrapReplacement
        )
    }

    func test_collaborationLeaderRepairNeverBootstrapsUnknownRoster() {
        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderRepairDecision(
                remoteTeam: nil, surfaces: []
            ),
            .deferUntilAuthoritative
        )

        let leaderID = Data(repeating: 0x43, count: 16)
        var surface = Termmesh_Peer_V1_SurfaceInfo()
        surface.surfaceID = leaderID
        let unknown = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [], projectID: "team:uuid",
            leaderSurfaceID: leaderID
        )
        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderRepairDecision(
                remoteTeam: unknown, surfaces: [surface]
            ),
            .deferUntilAuthoritative
        )
    }

    func test_collaborationLeaderRepairRequiresOneExactRemoteProject() {
        let first = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [], projectID: "team:uuid"
        )
        let duplicate = RemoteTeamSummary(
            name: "xm copy", teamUUID: "uuid", workingDirectory: "/other",
            projectRootPath: nil, agentNames: [], projectID: "team:uuid"
        )
        XCTAssertNil(TeamOrchestrator.exactCollaborationRemoteTeam(
            in: [], teamUUID: "uuid", projectID: "team:uuid"
        ))
        XCTAssertEqual(
            TeamOrchestrator.exactCollaborationRemoteTeam(
                in: [first], teamUUID: "uuid", projectID: "team:uuid"
            ),
            first
        )
        XCTAssertNil(TeamOrchestrator.exactCollaborationRemoteTeam(
            in: [first, duplicate], teamUUID: "uuid", projectID: "team:uuid"
        ))
    }

    func test_collaborationLeaderRepairIgnoresStaleLocalRelayState() {
        let leaderID = Data(repeating: 0x44, count: 16)
        let missing = RemoteTeamSummary(
            name: "xm", teamUUID: "uuid", workingDirectory: "/work/xm",
            projectRootPath: nil, agentNames: [], projectID: "team:uuid",
            leaderSurfaceID: leaderID, leaderProcessActive: false,
            leaderProcessActiveKnown: true
        )
        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderRepairDecision(
                remoteTeam: missing, surfaces: [], localLeaderRelayStarted: true
            ),
            .bootstrapReplacement
        )
    }

    func test_collaborationLeaderLaunchMetadataUsesRosterAndLegacyFallback() {
        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderLaunchMetadata(
                remoteCLI: "codex", remoteModel: "gpt-5.6-sol"
            ),
            .init(cli: "codex", model: "gpt-5.6-sol")
        )
        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderLaunchMetadata(
                remoteCLI: "", remoteModel: ""
            ),
            .init(cli: "claude", model: "opus")
        )
        XCTAssertEqual(
            TeamOrchestrator.collaborationLeaderLaunchMetadata(
                remoteCLI: "adopted", remoteModel: ""
            ),
            .init(cli: "claude", model: "opus")
        )
    }

    func test_remoteTeamSummaryPreservesLeaderLaunchMetadata() {
        var proto = Termmesh_Peer_V1_Team()
        proto.name = "xm"
        proto.teamUuid = "uuid"
        proto.leaderCli = "codex"
        proto.leaderModel = "gpt-5.6-sol"
        let summary = RemoteHostStore.remoteTeamSummary(proto)
        XCTAssertEqual(summary.leaderCLI, "codex")
        XCTAssertEqual(summary.leaderModel, "gpt-5.6-sol")
    }

    func test_collaborationReplacementConfirmationUsesNewManagedSurfaceDuringManifestLag() {
        let staleManifestID = Data(repeating: 0x45, count: 16)
        let replacementID = Data(repeating: 0x46, count: 16)
        var replacement = Termmesh_Peer_V1_SurfaceInfo()
        replacement.surfaceID = replacementID
        replacement.attachable = true
        replacement.foregroundBusyKnown = true
        replacement.foregroundBusy = true

        let confirmed = TeamOrchestrator.confirmedReplacementLeaderSurfaceID(
                manifestLeaderSurfaceID: staleManifestID,
                managedLeaderSurfaceID: replacementID,
                surfaces: [replacement]
        )
        XCTAssertEqual(confirmed, replacementID)
        XCTAssertTrue(TeamOrchestrator.collaborationRecoveryPlan(
            leaderSurfaceID: confirmed, agents: [], surfaces: [replacement]
        ).leaderLive)
    }

    func test_collaborationReusesOnlyExactLiveManagedReplacement() {
        let manifestID = Data(repeating: 0x61, count: 16)
        let managedID = Data(repeating: 0x62, count: 16)
        let record = ManagedPeerSurfaceStore.Record(
            hostKey: "ssh:mac-sub",
            surfaceIDBase64: managedID.base64EncodedString(),
            teamName: "xm", role: "leader",
            workingDirectory: "/work/xm", createdAt: Date(),
            teamUUID: "uuid", projectID: "team:uuid"
        )
        var managed = Termmesh_Peer_V1_SurfaceInfo()
        managed.surfaceID = managedID
        managed.attachable = true
        managed.foregroundBusyKnown = true
        managed.foregroundBusy = true
        XCTAssertEqual(
            TeamOrchestrator.recoverableManagedLeaderSurfaceID(
                manifestLeaderSurfaceID: manifestID,
                managedRecords: [record], teamName: "xm", teamUUID: "uuid",
                projectID: "team:uuid", workingDirectory: "/work/xm",
                surfaces: [managed]
            ),
            managedID
        )
        XCTAssertNil(TeamOrchestrator.recoverableManagedLeaderSurfaceID(
            manifestLeaderSurfaceID: managedID,
            managedRecords: [record], teamName: "xm", teamUUID: "uuid",
            projectID: "team:uuid", workingDirectory: "/work/xm",
            surfaces: [managed]
        ))
        managed.foregroundBusy = false
        XCTAssertNil(TeamOrchestrator.recoverableManagedLeaderSurfaceID(
            manifestLeaderSurfaceID: manifestID,
            managedRecords: [record], teamName: "xm", teamUUID: "uuid",
            projectID: "team:uuid", workingDirectory: "/work/xm",
            surfaces: [managed]
        ))
        managed.foregroundBusy = true
        let otherID = Data(repeating: 0x63, count: 16)
        var other = Termmesh_Peer_V1_SurfaceInfo()
        other.surfaceID = otherID
        other.attachable = true
        other.foregroundBusyKnown = true
        other.foregroundBusy = true
        let otherRecord = ManagedPeerSurfaceStore.Record(
            hostKey: "ssh:mac-sub", surfaceIDBase64: otherID.base64EncodedString(),
            teamName: "xm", role: "leader", workingDirectory: "/work/xm",
            createdAt: Date(), teamUUID: "uuid", projectID: "team:uuid"
        )
        XCTAssertNil(TeamOrchestrator.recoverableManagedLeaderSurfaceID(
            manifestLeaderSurfaceID: manifestID,
            managedRecords: [record, otherRecord], teamName: "xm", teamUUID: "uuid",
            projectID: "team:uuid", workingDirectory: "/work/xm",
            surfaces: [managed, other]
        ))
    }

    @MainActor
    func test_managedLeaderRecordDecodesLegacyIdentityAsUnknown() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "hostKey": "ssh:mac-sub",
            "surfaceIDBase64": Data(repeating: 0x64, count: 16).base64EncodedString(),
            "teamName": "xm", "role": "leader",
            "workingDirectory": "/work/xm",
            "createdAt": 0.0,
        ])
        let record = try JSONDecoder().decode(
            ManagedPeerSurfaceStore.Record.self, from: data
        )
        XCTAssertNil(record.teamUUID)
        XCTAssertNil(record.projectID)
        var surface = Termmesh_Peer_V1_SurfaceInfo()
        surface.surfaceID = try XCTUnwrap(record.surfaceID)
        surface.attachable = true
        surface.foregroundBusyKnown = true
        surface.foregroundBusy = true
        XCTAssertNil(TeamOrchestrator.recoverableManagedLeaderSurfaceID(
            manifestLeaderSurfaceID: Data(repeating: 0x65, count: 16),
            managedRecords: [record], teamName: "xm", teamUUID: "uuid",
            projectID: "team:uuid", workingDirectory: "/work/xm",
            surfaces: [surface]
        ))
        XCTAssertEqual(TeamOrchestrator.legacyManagedLeaderCandidateSurfaceID(
            manifestLeaderSurfaceID: Data(repeating: 0x65, count: 16),
            managedRecords: [record], teamName: "xm",
            workingDirectory: "/work/xm", surfaces: [surface]
        ), record.surfaceID)
        let script = TeamOrchestrator.legacyManagedLeaderIdentityProofScript()
        XCTAssertFalse(script.contains("TERMMESH_SURFACE_ID="))
        XCTAssertFalse(script.contains("TERMMESH_LEADER_TEAM_UUID=uuid"))
        XCTAssertFalse(script.contains("TERMMESH_LEADER_GRANT_ID"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(
            TeamOrchestrator.legacyManagedLeaderIdentityProofInput(
                surfaceID: try XCTUnwrap(record.surfaceID), teamUUID: "uuid"
            )
        )
        try input.fileHandleForWriting.close()
        let result = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(result, "0", "the verifier must not match its own command")
    }

    @MainActor
    func test_collaborationControlSocketUsesMeasuredOrSiblingPathOnly() {
        var measured = PeerHostHealthBaseline()
        measured.controlPath = "/srv/term-mesh/control.sock"
        measured.controlPathPresent = true
        measured.peerPath = "/run/term-mesh/tm-peer.sock"
        measured.peerPathPresent = true
        XCTAssertEqual(
            TeamOrchestrator.collaborationControlSocketPath(
                peerSocketPath: "/run/term-mesh/tm-peer.sock", health: measured
            ),
            "/srv/term-mesh/control.sock"
        )
        measured.peerPath = "/run/term-mesh/other-peer.sock"
        XCTAssertEqual(
            TeamOrchestrator.collaborationControlSocketPath(
                peerSocketPath: "/run/term-mesh/tm-peer.sock", health: measured
            ),
            "/run/term-mesh/term-meshd.sock",
            "health from another daemon must not redirect verification"
        )
        XCTAssertEqual(
            TeamOrchestrator.collaborationControlSocketPath(
                peerSocketPath: "/private/tmp/term-meshd-peer.sock", health: nil
            ),
            "/private/tmp/term-meshd.sock"
        )
        XCTAssertEqual(
            TeamOrchestrator.collaborationControlSocketPath(
                peerSocketPath: "/run/term-mesh/tm-peer.sock", health: nil
            ),
            "/run/term-mesh/term-meshd.sock"
        )
        XCTAssertNil(
            TeamOrchestrator.collaborationControlSocketPath(
                peerSocketPath: "/tmp/unrelated.sock", health: nil
            )
        )
    }

    func test_collaborationPeerSocketUsesOnlyAuthenticatedTeamEndpoint() {
        XCTAssertEqual(
            TeamOrchestrator.collaborationPeerSocketPath(
                teamHostKey: .direct(sockPath: "/owner/term-meshd-peer.sock")
            ),
            "/owner/term-meshd-peer.sock"
        )
        XCTAssertEqual(
            TeamOrchestrator.collaborationPeerSocketPath(
                teamHostKey: .ssh(
                    target: "mac-sub",
                    remoteSockPath: "/var/folders/owner/term-meshd-peer.sock",
                    port: nil
                )
            ),
            "/var/folders/owner/term-meshd-peer.sock"
        )
        XCTAssertNil(TeamOrchestrator.collaborationPeerSocketPath(teamHostKey: nil))
        XCTAssertNil(TeamOrchestrator.collaborationPeerSocketPath(
            teamHostKey: .ssh(target: "mac-sub", remoteSockPath: "", port: nil)
        ))
    }

    @MainActor
    func test_collaborationRouteVerificationScriptUsesRouteFileWithoutBearer() {
        let script = TeamOrchestrator.remoteCollaborationRouteVerificationScript(
            teamName: "xm",
            teamUUID: "A70D3DBC-8167-4112-88DD-FFAEFF54DCC6",
            controlSocketPath: "/private/tmp/term-meshd.sock",
            hostBinDirs: ["/Applications/term-mesh.app/Contents/Resources/bin"]
        )
        XCTAssertTrue(script.contains("leader-a70d3dbc-8167-4112-88dd-ffaeff54dcc6.json"))
        XCTAssertTrue(script.contains("TERMMESH_LEADER_ROUTE_FILE="))
        XCTAssertTrue(script.contains("TERMMESH_RPC_TIMEOUT=20"))
        // `serviceAccountCommand` re-quotes the inner shell, so the exact
        // apostrophe spelling is intentionally not part of this contract.
        XCTAssertTrue(script.contains("--team"))
        XCTAssertTrue(script.contains("xm"))
        XCTAssertTrue(script.contains("status"))
        XCTAssertTrue(script.contains("__TERMMESH_COLLABORATION_ROUTE_RESULT__="))
        XCTAssertTrue(script.contains("__TERMMESH_COLLABORATION_ROUTE_EXIT__="))
        XCTAssertFalse(script.contains("grant_id_hex"), "the bearer stays in the route file")
    }

    @MainActor
    func test_collaborationRouteVerificationCanProbeStagedCandidateBeforeCommit() {
        let candidate =
            "/srv/agent/.term-mesh/agent-routes/.tx.42/leader-team-uuid.json.new"
        let script = TeamOrchestrator.remoteCollaborationRouteVerificationScript(
            teamName: "xm",
            teamUUID: "team-uuid",
            controlSocketPath: "/run/term-mesh/term-meshd.sock",
            hostBinDirs: [],
            routeFilePath: candidate
        )
        XCTAssertTrue(script.contains(candidate))
        XCTAssertFalse(
            script.contains("$HOME/.term-mesh/agent-routes/leader-team-uuid.json"),
            "candidate verification must not read or replace the canonical route"
        )
    }

    @MainActor
    func test_collaborationRouteVerificationParserRequiresExactProxiedTeam() throws {
        func output(team: String = "xm", proxied: Bool = true) throws -> String {
            let value: [String: Any] = [
                "ok": true,
                "remote_leader_proxy": proxied,
                "result": [
                    "team_name": team,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: value)
            return "noise\n" + TeamOrchestrator.collaborationRouteVerificationMarker
                + data.base64EncodedString() + "\n"
        }

        XCTAssertTrue(TeamOrchestrator.parseRemoteCollaborationRouteVerification(
            try output(), expectedTeamName: "xm"
        ))
        XCTAssertFalse(TeamOrchestrator.parseRemoteCollaborationRouteVerification(
            try output(team: "other"), expectedTeamName: "xm"
        ))
        XCTAssertFalse(TeamOrchestrator.parseRemoteCollaborationRouteVerification(
            try output(proxied: false), expectedTeamName: "xm"
        ))
        XCTAssertFalse(TeamOrchestrator.parseRemoteCollaborationRouteVerification(
            "not a marker", expectedTeamName: "xm"
        ))
    }

    @MainActor
    func test_collaborationRouteVerificationFailurePreservesExitAndBoundedDetail() {
        let detail = Data("peer leader command timed out".utf8).base64EncodedString()
        let output = TeamOrchestrator.collaborationRouteVerificationMarker + detail + "\n"
            + TeamOrchestrator.collaborationRouteVerificationExitMarker + "1\n"
        XCTAssertEqual(
            TeamOrchestrator.remoteCollaborationRouteVerificationFailure(output),
            "leader route exited 1: peer leader command timed out"
        )
    }

    @MainActor
    func test_collaborationRecoveryReportClaimsSuccessOnlyAfterRouteVerification() {
        let unverified = TeamOrchestrator.CollaborationRecoveryReport(
            routeRepaired: true, leaderLive: true, liveAgents: 4,
            replacedAgents: [], failedAgents: [],
            verificationFailure: "peer leader command timed out"
        )
        XCTAssertFalse(unverified.succeeded)
        XCTAssertTrue(unverified.message.contains("verification failed"))

        let rolledBack = TeamOrchestrator.CollaborationRecoveryReport(
            routeRepaired: false, leaderLive: true, liveAgents: 4,
            replacedAgents: [], failedAgents: [],
            verificationFailure: "wrong daemon"
        )
        XCTAssertFalse(rolledBack.succeeded)
        XCTAssertTrue(rolledBack.message.contains("rolled back"))

        let verified = TeamOrchestrator.CollaborationRecoveryReport(
            routeRepaired: true, routeVerified: true,
            leaderLive: true, liveAgents: 4,
            replacedAgents: [], failedAgents: []
        )
        XCTAssertTrue(verified.succeeded)
        XCTAssertTrue(verified.message.contains("Collaboration verified"))
    }

    @MainActor
    func test_remoteLeaderLaunchExportsRefreshableRouteAndScopedIdentity() {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 0xab, count: PeerTeamLeader.grantIDBytes)
        grant.projectID = "team:05AC84AA"
        grant.teamUuid = "05AC84AA"
        grant.expiresAtUnixSecs = 4_102_444_800
        let command = TeamOrchestrator.remoteLeaderCommand(
            cli: "codex", model: "", teamName: "aic",
            workingDirectory: "/tmp/aic", grant: grant,
            leaderRequestToken: "request-token",
            routeFilePath: "/srv/agent/.term-mesh/agent-routes/leader-05ac84aa.json",
            leaderSessionID: "leader-session"
        )
        XCTAssertTrue(command.contains("TERMMESH_LEADER_ROUTE_FILE"))
        XCTAssertTrue(command.contains("leader-05ac84aa.json"))
        XCTAssertTrue(command.contains("TERMMESH_LEADER_SESSION_ID"))
        XCTAssertTrue(command.contains("leader-session"))
    }

    @MainActor
    func test_remoteRouteFileEnvironmentIsOmittedWhenNothingWasStaged() {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 0xab, count: PeerTeamLeader.grantIDBytes)
        grant.projectID = "name:mesh-test"
        grant.teamUuid = "team-uuid"

        for staged in [nil, "", "relative/path.json", "$HOME/route.json"] as [String?] {
            let env = TeamOrchestrator.remoteNativeAgentEnvironment(
                teamName: "mesh-test",
                agentName: "executor",
                agentType: "executor",
                agentCli: "codex",
                workspaceId: UUID(),
                socketPath: nil,
                routeGrant: grant,
                routeFilePath: staged
            )
            XCTAssertNil(
                env[TeamOrchestrator.remoteTeamRouteFileEnvName],
                "\(staged ?? "nil") is not a path tm-agent can open"
            )
        }
    }

    /// The adopting app has the roster, not the launch, so the path has to be
    /// a pure function of the agent instance id — and sanitised, because an
    /// instance id must not be able to name a file of its choosing.
    @MainActor
    func test_remoteAgentRouteFileNameIsDeterministicAndSanitised() {
        XCTAssertEqual(
            TeamOrchestrator.remoteAgentRouteFileName(agentInstanceID: "A1B2-C3D4"),
            "a1b2-c3d4.json"
        )
        XCTAssertEqual(
            TeamOrchestrator.remoteAgentRouteFileName(agentInstanceID: "A1B2-C3D4"),
            TeamOrchestrator.remoteAgentRouteFileName(agentInstanceID: "a1b2-c3d4")
        )
        XCTAssertEqual(
            TeamOrchestrator.remoteAgentRouteFileName(
                agentInstanceID: "../../etc/pass wd;rm -rf /"
            ),
            "etcpasswdrm-rf.json",
            "no separator, no space, and no shell metacharacter survives"
        )
        let long = TeamOrchestrator.remoteAgentRouteFileName(
            agentInstanceID: String(repeating: "a", count: 200)
        )
        XCTAssertEqual(long.count, 48 + ".json".count)
    }

    /// Exactly the object `remote_leader_route_from_file` in tm_agent.rs
    /// parses. A renamed or retyped field here is a route the worker silently
    /// refuses, falling back to the dead environment grant.
    @MainActor
    func test_routeFilePayloadMatchesTheFieldsTmAgentParses() throws {
        var grant = Termmesh_Peer_V1_TeamLeaderGrant()
        grant.grantID = Data(repeating: 0xcd, count: PeerTeamLeader.grantIDBytes)
        grant.projectID = "name:mesh-test"
        grant.teamUuid = "team-uuid"
        grant.expiresAtUnixSecs = 4_102_444_800

        let payload = TeamOrchestrator.remoteAgentRouteFilePayload(grant)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        XCTAssertEqual(object["grant_id_hex"] as? String, String(repeating: "cd", count: 32))
        XCTAssertEqual(object["project_id"] as? String, "name:mesh-test")
        XCTAssertEqual(object["team_uuid"] as? String, "team-uuid")
        XCTAssertEqual(object["expires_at_unix_secs"] as? UInt64, 4_102_444_800)
        XCTAssertEqual((object["target_peer_id_hex"] as? String)?.count, 32)
    }

    /// A bearer in the remote command line would sit in `ps` output and in
    /// shell history on a machine this app does not own.
    @MainActor
    func test_routeStagingScriptCarriesNoSecretAndReplacesAtomically() {
        let script = TeamOrchestrator.remoteAgentRouteStagingScript(
            agentInstanceID: "A1B2-C3D4"
        )

        XCTAssertTrue(script.contains("cat > \"$tmp\""), "the grant arrives on stdin")
        XCTAssertTrue(script.contains("mv -f \"$tmp\" \"$path\""), "rename, never truncate")
        XCTAssertTrue(script.contains("chmod 600 \"$tmp\""))
        XCTAssertTrue(script.contains("chmod 700 \"$dir\""))
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains("a1b2-c3d4.json"))
        XCTAssertTrue(
            script.contains("/bin/sh -c "),
            "the service-account wrapper must force sh for csh or fish login accounts"
        )
        XCTAssertFalse(
            script.lowercased().contains("grant_id"),
            "no part of the grant may appear in the remote argv"
        )
    }

    @MainActor
    func test_adoptedRouteBatchStagesEverythingBeforeCommitAndRollsBackPartialMoves() {
        // The batch helper is remote I/O, but its security boundary is the
        // generated transaction: decode every route first, back up every live
        // file, then move, with an EXIT trap restoring partial commits. Keep
        // those ordering tokens pinned so a later simplification cannot return
        // to one-worker-at-a-time replacement.
        let body = TeamOrchestrator.adoptedRemoteAgentRouteTransactionScript()
        let decode = body.range(of: "base64 $flag >")
        XCTAssertNotNil(decode)
        XCTAssertFalse(body.contains("mv -f \"$p\" \"$dir/$n\""))
        XCTAssertTrue(body.contains("trap cleanup EXIT HUP INT TERM"))
        XCTAssertTrue(body.contains("$tx/$n.base"))
        XCTAssertTrue(body.contains("__TERMMESH_ROUTE_DIR__="))
    }

    @MainActor
    func test_adoptedRouteTransactionCommitsLeaderAndWorkersAsOneBatch() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-route-all-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", TeamOrchestrator.adoptedRemoteAgentRouteTransactionScript(),
        ]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(
            Data("leader-team.json\tbGVhZGVy\nworker.json\td29ya2Vy\n".utf8)
        )
        try input.fileHandleForWriting.close()
        let stagedOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let transaction = try XCTUnwrap(
            TeamOrchestrator.parseAdoptedRouteTransaction(stagedOutput)
        )
        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/bin/sh")
        commit.arguments = [
            "-c", try XCTUnwrap(TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transaction, commit: true
            )),
        ]
        commit.environment = process.environment
        try commit.run()
        commit.waitUntilExit()
        let directory = home.appendingPathComponent(".term-mesh/agent-routes")
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("leader-team.json")),
            "leader"
        )
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("worker.json")),
            "worker"
        )
    }

    @MainActor
    func test_adoptedRouteFinishTargetsTheValidatedTransactionDirectory() {
        let rollback = TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
            transaction: ".tx.1234", commit: false
        )
        let commit = TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
            transaction: ".tx.1234", commit: true
        )
        XCTAssertNotNil(rollback)
        XCTAssertTrue(rollback?.contains("tx=\"$dir/.tx.1234\"") == true)
        XCTAssertTrue(
            rollback?.contains("mv -f \"$tx/$n.old\" \"$dir/$n\"") == true
        )
        XCTAssertTrue(commit?.contains("mv -f \"$p\" \"$dir/$n\"") == true)
        XCTAssertTrue(commit?.contains("cmp -s \"$tx/$n.base\" \"$dir/$n\"") == true)
        XCTAssertTrue(commit?.contains("$tx/$n.installed") == true)
        XCTAssertTrue(commit?.contains("[ -f \"$tx/committed.done\" ] && exit 0") == true)
        XCTAssertTrue(commit?.contains("[ -d \"$tx\" ] || exit 67") == true)
        XCTAssertTrue(
            TeamOrchestrator.adoptedRemoteAgentRouteFinalizeScript(
                transaction: ".tx.1234"
            )?.contains(": > \"$tx.done\"; rm -rf \"$tx\"") == true
        )
        XCTAssertNil(
            TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: "../routes", commit: false
            )
        )
    }

    @MainActor
    func test_adoptedRouteMarkersRequireSafeTransactionAndAbsoluteDirectory() {
        let output = "noise\n__TERMMESH_ROUTE_TX__=.tx.42\n"
            + "__TERMMESH_ROUTE_DIR__=/srv/agent/.term-mesh/agent-routes\n"
        XCTAssertEqual(TeamOrchestrator.parseAdoptedRouteTransaction(output), ".tx.42")
        XCTAssertEqual(
            TeamOrchestrator.parseAdoptedRouteDirectory(output),
            "/srv/agent/.term-mesh/agent-routes"
        )
        XCTAssertNil(
            TeamOrchestrator.parseAdoptedRouteDirectory(
                "__TERMMESH_ROUTE_DIR__=relative/routes\n"
            )
        )
    }

    @MainActor
    func test_adoptedRouteTransactionCanRestoreThePreviousLiveRoute() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-route-tx-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".term-mesh/agent-routes")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let live = directory.appendingPathComponent("worker.json")
        try Data("old".utf8).write(to: live)

        let staged = Process()
        staged.executableURL = URL(fileURLWithPath: "/bin/sh")
        staged.arguments = ["-c", TeamOrchestrator.adoptedRemoteAgentRouteTransactionScript()]
        staged.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        staged.standardInput = input
        staged.standardOutput = output
        staged.standardError = Pipe()
        try staged.run()
        input.fileHandleForWriting.write(Data("worker.json\tdGVzdA==\n".utf8))
        try input.fileHandleForWriting.close()
        let stagedOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        staged.waitUntilExit()
        XCTAssertEqual(staged.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: live), Data("old".utf8))

        let transaction = try XCTUnwrap(
            TeamOrchestrator.parseAdoptedRouteTransaction(stagedOutput)
        )
        let rollback = Process()
        rollback.executableURL = URL(fileURLWithPath: "/bin/sh")
        rollback.arguments = [
            "-c",
            try XCTUnwrap(
                TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                    transaction: transaction, commit: false
                )
            ),
        ]
        rollback.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try rollback.run()
        rollback.waitUntilExit()
        XCTAssertEqual(rollback.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: live), Data("old".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(transaction).path
            )
        )
    }

    @MainActor
    func test_adoptedRouteCommitMovesPreparedBytesOnlyAtCommitTime() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-route-commit-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".term-mesh/agent-routes")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let live = directory.appendingPathComponent("worker.json")
        try Data("old".utf8).write(to: live)

        let staged = Process()
        staged.executableURL = URL(fileURLWithPath: "/bin/sh")
        staged.arguments = ["-c", TeamOrchestrator.adoptedRemoteAgentRouteTransactionScript()]
        staged.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        staged.standardInput = input
        staged.standardOutput = output
        staged.standardError = Pipe()
        try staged.run()
        input.fileHandleForWriting.write(Data("worker.json\tdGVzdA==\n".utf8))
        try input.fileHandleForWriting.close()
        let stagedOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        staged.waitUntilExit()
        XCTAssertEqual(staged.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: live), Data("old".utf8))

        let transaction = try XCTUnwrap(
            TeamOrchestrator.parseAdoptedRouteTransaction(stagedOutput)
        )
        let stagedCandidate = directory
            .appendingPathComponent(transaction)
            .appendingPathComponent("worker.json.new")
        XCTAssertEqual(try Data(contentsOf: stagedCandidate), Data("test".utf8))
        XCTAssertEqual(
            try Data(contentsOf: live), Data("old".utf8),
            "candidate verification must happen while the canonical route remains old"
        )
        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/bin/sh")
        commit.arguments = [
            "-c",
            try XCTUnwrap(
                TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                    transaction: transaction, commit: true
                )
            ),
        ]
        commit.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try commit.run()
        commit.waitUntilExit()
        XCTAssertEqual(commit.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: live), Data("test".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(transaction).path
            )
        )

        let retry = Process()
        retry.executableURL = URL(fileURLWithPath: "/bin/sh")
        retry.arguments = [
            "-c",
            try XCTUnwrap(
                TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                    transaction: transaction, commit: true
                )
            ),
        ]
        retry.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try retry.run()
        retry.waitUntilExit()
        XCTAssertEqual(retry.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: live), Data("test".utf8))

        let rollback = Process()
        rollback.executableURL = URL(fileURLWithPath: "/bin/sh")
        rollback.arguments = [
            "-c",
            try XCTUnwrap(TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transaction, commit: false
            )),
        ]
        rollback.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try rollback.run()
        rollback.waitUntilExit()
        XCTAssertEqual(rollback.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: live), Data("old".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(transaction).path
            )
        )
    }

    @MainActor
    func test_adoptedRouteFinalizeDiscardsRollbackStateAfterCommit() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-route-finalize-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".term-mesh/agent-routes")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let live = directory.appendingPathComponent("worker.json")
        try Data("old".utf8).write(to: live)

        let staged = Process()
        staged.executableURL = URL(fileURLWithPath: "/bin/sh")
        staged.arguments = ["-c", TeamOrchestrator.adoptedRemoteAgentRouteTransactionScript()]
        staged.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        staged.standardInput = input
        staged.standardOutput = output
        try staged.run()
        input.fileHandleForWriting.write(Data("worker.json\tdGVzdA==\n".utf8))
        try input.fileHandleForWriting.close()
        let stagedOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        staged.waitUntilExit()
        let transaction = try XCTUnwrap(
            TeamOrchestrator.parseAdoptedRouteTransaction(stagedOutput)
        )
        for script in [
            TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transaction, commit: true
            ),
            TeamOrchestrator.adoptedRemoteAgentRouteFinalizeScript(
                transaction: transaction
            ),
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", try XCTUnwrap(script)]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(try Data(contentsOf: live), Data("test".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(transaction).path
            )
        )
    }

    @MainActor
    func test_adoptedRouteCASRejectsStaleCommitAndRollbackCannotClobberNewerWriter() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-route-cas-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".term-mesh/agent-routes")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let live = directory.appendingPathComponent("worker.json")
        try Data("old".utf8).write(to: live)
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]

        func run(_ script: String, input: String? = nil) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            if let input {
                let pipe = Pipe()
                process.standardInput = pipe
                try process.run()
                pipe.fileHandleForWriting.write(Data(input.utf8))
                try pipe.fileHandleForWriting.close()
            } else {
                try process.run()
            }
            let text = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        func stage(_ bytes: String) throws -> String {
            let encoded = Data(bytes.utf8).base64EncodedString()
            let result = try run(
                TeamOrchestrator.adoptedRemoteAgentRouteTransactionScript(),
                input: "worker.json\t\(encoded)\n"
            )
            XCTAssertEqual(result.0, 0)
            return try XCTUnwrap(
                TeamOrchestrator.parseAdoptedRouteTransaction(result.1)
            )
        }

        let transactionA = try stage("candidate-a")
        let transactionB = try stage("candidate-b")
        let commitB = try run(try XCTUnwrap(
            TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transactionB, commit: true
            )
        ))
        XCTAssertEqual(commitB.0, 0)
        XCTAssertEqual(try Data(contentsOf: live), Data("candidate-b".utf8))
        let staleCommitA = try run(try XCTUnwrap(
            TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transactionA, commit: true
            )
        ))
        XCTAssertNotEqual(staleCommitA.0, 0)
        XCTAssertEqual(
            try Data(contentsOf: live), Data("candidate-b".utf8),
            "only one concurrent snapshot may replace the canonical route"
        )
        XCTAssertEqual(try run(try XCTUnwrap(
            TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transactionA, commit: false
            )
        )).0, 0)
        XCTAssertEqual(try run(try XCTUnwrap(
            TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transactionB, commit: false
            )
        )).0, 0)
        let transactionC = try stage("candidate-c")
        XCTAssertEqual(try run(try XCTUnwrap(
            TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transactionC, commit: true
            )
        )).0, 0)
        XCTAssertEqual(try Data(contentsOf: live), Data("candidate-c".utf8))
        try Data("later-writer".utf8).write(to: live)
        XCTAssertEqual(try run(try XCTUnwrap(
            TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                transaction: transactionC, commit: false
            )
        )).0, 0)
        XCTAssertEqual(
            try Data(contentsOf: live), Data("later-writer".utf8),
            "a stale rollback must not overwrite another transaction's installed bytes"
        )
    }

    @MainActor
    func test_adoptedRouteCommitMutexPublishesOneWholeBatch() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-route-race-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".term-mesh/agent-routes")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["leader.json", "worker.json"] {
            try Data("old".utf8).write(to: directory.appendingPathComponent(name))
        }
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]

        func stage(_ generation: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c", TeamOrchestrator.adoptedRemoteAgentRouteTransactionScript(),
            ]
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let leader = Data("\(generation)-leader".utf8).base64EncodedString()
            let worker = Data("\(generation)-worker".utf8).base64EncodedString()
            input.fileHandleForWriting.write(
                Data("leader.json\t\(leader)\nworker.json\t\(worker)\n".utf8)
            )
            try input.fileHandleForWriting.close()
            let text = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return try XCTUnwrap(TeamOrchestrator.parseAdoptedRouteTransaction(text))
        }

        let transactionA = try stage("a")
        let transactionB = try stage("b")
        let gate = home.appendingPathComponent("gate")
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)

        func commit(_ transaction: String, marker: String, other: String) throws -> Process {
            let body = try XCTUnwrap(
                TeamOrchestrator.adoptedRemoteAgentRouteFinishScript(
                    transaction: transaction, commit: true
                )
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "touch \(gate.appendingPathComponent(marker).path); "
                    + "while [ ! -f \(gate.appendingPathComponent(other).path) ]; do sleep 0.01; done; "
                    + body,
            ]
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            return process
        }

        let commitA = try commit(transactionA, marker: "a", other: "b")
        let commitB = try commit(transactionB, marker: "b", other: "a")
        commitA.waitUntilExit()
        commitB.waitUntilExit()
        XCTAssertEqual(
            [commitA.terminationStatus, commitB.terminationStatus].filter { $0 == 0 }.count,
            1,
            "the short commit mutex must choose exactly one batch winner"
        )
        let leader = try String(contentsOf: directory.appendingPathComponent("leader.json"))
        let worker = try String(contentsOf: directory.appendingPathComponent("worker.json"))
        XCTAssertTrue(
            (leader == "a-leader" && worker == "a-worker")
                || (leader == "b-leader" && worker == "b-worker"),
            "canonical routes must never contain a mixed transaction generation"
        )
    }

    @MainActor
    func test_stagedRoutePathIsReadOnlyFromAnAbsoluteMarkerLine() {
        XCTAssertEqual(
            TeamOrchestrator.parseRemoteAgentRouteFilePath(
                "some login noise\n__TERMMESH_ROUTE_FILE__=/home/a/.term-mesh/agent-routes/x.json\n"
            ),
            "/home/a/.term-mesh/agent-routes/x.json"
        )
        XCTAssertNil(
            TeamOrchestrator.parseRemoteAgentRouteFilePath("__TERMMESH_ROUTE_FILE__=\n"),
            "an empty path means $HOME never resolved"
        )
        XCTAssertNil(
            TeamOrchestrator.parseRemoteAgentRouteFilePath("__TERMMESH_ROUTE_FILE__=x.json\n"),
            "a relative path is not something the worker environment can name"
        )
        XCTAssertNil(TeamOrchestrator.parseRemoteAgentRouteFilePath("ok\n"))
    }

    /// Run the script the peer would run. This is the one check that proves
    /// the shell text itself — permissions, `$HOME` resolution, the echoed
    /// path, and that a second staging replaces the first in place.
    @MainActor
    func test_routeStagingScriptWritesAnOwnerOnlyFileAndReplacesItInPlace() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-mesh-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        func stage(_ grantByte: UInt8) throws -> String {
            var grant = Termmesh_Peer_V1_TeamLeaderGrant()
            grant.grantID = Data(repeating: grantByte, count: PeerTeamLeader.grantIDBytes)
            grant.projectID = "name:mesh-test"
            grant.teamUuid = "team-uuid"
            grant.expiresAtUnixSecs = 4_102_444_800

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                TeamOrchestrator.remoteAgentRouteStagingScript(agentInstanceID: "A1B2-C3D4"),
            ]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            input.fileHandleForWriting.write(TeamOrchestrator.remoteAgentRouteFilePayload(grant))
            try input.fileHandleForWriting.close()
            let text = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return try XCTUnwrap(TeamOrchestrator.parseRemoteAgentRouteFilePath(text))
        }

        let path = try stage(0xcd)
        XCTAssertEqual(path, home.path + "/.term-mesh/agent-routes/a1b2-c3d4.json")

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600,
            "tm-agent refuses any route file another account could have written"
        )
        let dirAttributes = try FileManager.default.attributesOfItem(
            atPath: home.path + "/.term-mesh/agent-routes"
        )
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.int16Value, 0o700)

        let first = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: path))
            ) as? [String: Any]
        )
        XCTAssertEqual(first["grant_id_hex"] as? String, String(repeating: "cd", count: 32))

        // What adoption does: same worker, same path, a grant the new viewer
        // owns. Nothing about the running process changes.
        let replaced = try stage(0x99)
        XCTAssertEqual(replaced, path, "the path must not move under a live worker")
        let second = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: path))
            ) as? [String: Any]
        )
        XCTAssertEqual(second["grant_id_hex"] as? String, String(repeating: "99", count: 32))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: home.path + "/.term-mesh/agent-routes"
            ),
            ["a1b2-c3d4.json"],
            "the staging temporary must not be left behind"
        )
    }

    @MainActor
    func test_agentRuntimeOwnershipExplainsTheActualLifetime() {
        let fallback = AgentRuntimeOwnership.sshOwned(hostName: "mac-sub")
        XCTAssertEqual(fallback.badgeTitle, "SSH-owned")
        XCTAssertFalse(fallback.isDurableAcrossViewerQuit)
        XCTAssertTrue(fallback.detail?.contains("Stops when term-mesh on this Mac quits") == true)

        let durable = AgentRuntimeOwnership.peerOwned(hostName: "mac-sub")
        XCTAssertEqual(durable.badgeTitle, "Host-owned")
        XCTAssertTrue(durable.isDurableAcrossViewerQuit)
        XCTAssertTrue(durable.detail?.contains("reattach after restart") == true)
    }

    // MARK: Fixtures

    /// Pin both transport defaults for the duration of a test. They live in
    /// `UserDefaults.standard`, which the whole test process shares, so a
    /// routing assertion that reads them implicitly is one unrelated test away
    /// from being about something else.
    @MainActor
    private static func forceNativePanes(_ enabled: Bool) -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = [AgentPipeTransport.enabledKey, AgentPipeTransport.nativePanelKey]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.set(enabled, forKey: key) }
        return {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// A connected ssh host, minus everything the availability check does not
    /// read. Nothing here reaches a network: the assertions using it all stop
    /// at a guard before the handshake.
    @MainActor
    private static func agentHostEntry(
        sshTarget: String? = "root@jw-server",
        activeSockPath: String = "/tmp/term-mesh-peer-501/jw-server.sock"
    ) -> HostEntry {
        HostEntry(
            id: "ssh:root@jw-server",
            displayName: "jw-server",
            connectionState: .connected,
            workspaces: [],
            activeSockPath: activeSockPath,
            sshTarget: sshTarget,
            remoteSockPath: "/run/user/0/tm-peer.sock"
        )
    }

    // MARK: Ensure recipe

    /// The daemon spawns `executable` + `args` verbatim, so this vector IS the
    /// contract. Three things in it are load-bearing rather than cosmetic and
    /// each has cost a debugging session somewhere:
    ///  - `executable` must be the PEER's bridge, never this Mac's;
    ///  - `--cli` must be present, because the daemon reads
    ///    `SurfaceInfo.agent_cli` back out of the args (there is no field);
    ///  - `--exe` must be absolute, because term-meshd runs under systemd's
    ///    PATH and would not find a `$HOME/.local/bin` CLI by name. It comes
    ///    from `execPath`, the binary the BRIDGE spawns, which for kiro is not
    ///    the file the role is named after.
    @MainActor
    func test_ensureSpec_carriesThePeersBridgeAndAnAbsoluteCLIPath() {
        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: "11111111-2222-3333-4444-555555555555",
            cli: "codex",
            workingDirectory: "/root/work/term-mesh",
            model: "gpt-5",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/root/.local/bin/codex",
                execPath: "/root/.local/bin/codex",
                bridgePath: "/usr/local/bin/tm-agent-bridge",
                cliAvailable: true
            )
        )

        XCTAssertEqual(spec.executable, "/usr/local/bin/tm-agent-bridge")
        XCTAssertEqual(spec.cwd, "/root/work/term-mesh")
        XCTAssertEqual(spec.kind, SessionHostPanes.agentSurfaceType)
        XCTAssertEqual(spec.restartPolicy, .never)
        XCTAssertEqual(
            Array(spec.args[0..<4]),
            ["--cli", "codex", "--cwd", "/root/work/term-mesh"]
        )
        XCTAssertTrue(spec.args.contains("--exe"))
        XCTAssertEqual(
            spec.args.last, "/root/.local/bin/codex",
            "--exe is what makes the CLI findable from a systemd PATH"
        )
        // The label the daemon will echo back as SurfaceInfo.agent_cli.
        let cliFlag = spec.args.firstIndex(of: "--cli").map { spec.args[$0 + 1] }
        XCTAssertEqual(cliFlag, "codex")
    }

    /// A CLI the probe could not resolve still gets a surface: the bridge
    /// falls back to a bare name, which is right more often than failing.
    @MainActor
    func test_ensureSpec_omitsExeWhenTheProbeResolvedNothing() {
        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: UUID().uuidString,
            cli: "kiro",
            workingDirectory: "/root/work",
            model: "sonnet",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "",
                bridgePath: "/usr/local/bin/tm-agent-bridge",
                cliAvailable: true
            )
        )
        XCTAssertFalse(spec.args.contains("--exe"))
        XCTAssertEqual(Array(spec.args[0..<2]), ["--cli", "kiro"])
    }

    /// Two members of one team must never share an ensure key: the daemon
    /// would answer REUSED and hand the second member the first one's bridge.
    /// The instance id is therefore never the part that gets trimmed.
    @MainActor
    func test_ensureKey_isUniquePerInstanceAndFitsTheProtocolLimit() {
        let instanceA = UUID().uuidString
        let instanceB = UUID().uuidString
        let keyA = TeamOrchestrator.peerAgentEnsureKey(teamName: "team", agentInstanceId: instanceA)
        let keyB = TeamOrchestrator.peerAgentEnsureKey(teamName: "team", agentInstanceId: instanceB)
        XCTAssertNotEqual(keyA, keyB)
        XCTAssertTrue(keyA.contains(instanceA))

        let absurdTeam = String(repeating: "가", count: 400)
        let long = TeamOrchestrator.peerAgentEnsureKey(
            teamName: absurdTeam, agentInstanceId: instanceA
        )
        XCTAssertLessThanOrEqual(
            long.utf8.count, 256,
            "the daemon rejects a key over 256 UTF-8 bytes outright"
        )
        XCTAssertTrue(
            long.contains(instanceA),
            "trimming must eat the team name, never the uniqueness"
        )
    }

    @MainActor
    func test_restartSpec_usesAFreshEnsureKeyWithoutChangingAgentIdentity() {
        let agentInstanceID = "11111111-2222-3333-4444-555555555555"
        let surfaceInstanceID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let binaries = TeamOrchestrator.RemoteAgentBinaries(
            execPath: "/usr/local/bin/codex",
            bridgePath: "/usr/local/bin/tm-agent-bridge",
            cliAvailable: true
        )
        let original = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: agentInstanceID,
            cli: "codex",
            workingDirectory: "/work",
            model: "gpt-5",
            binaries: binaries
        )
        let replacement = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: agentInstanceID,
            surfaceInstanceId: surfaceInstanceID,
            cli: "codex",
            workingDirectory: "/work",
            model: "gpt-5",
            binaries: binaries
        )

        XCTAssertNotEqual(original.key, replacement.key)
        XCTAssertEqual(
            replacement.key,
            TeamOrchestrator.peerAgentEnsureKey(
                teamName: "my-team", agentInstanceId: surfaceInstanceID
            )
        )
        XCTAssertEqual(original.args, replacement.args)
    }

    // MARK: Probe parsing

    /// A login shell prints its own greeting around the answer, and
    /// `command -v` also names shell functions and builtins — neither of
    /// which the daemon can spawn.
    @MainActor
    func test_probeParsing_takesAbsolutePathsOutOfLoginShellNoise() {
        let output = """
        Welcome to Ubuntu 24.04 LTS
        __TERMMESH_CLI_AVAILABLE__
        __TERMMESH_CLI_PATH__=/root/.local/bin/codex
        __TERMMESH_BRIDGE_PATH__=/usr/local/bin/tm-agent-bridge
        """
        let parsed = TeamOrchestrator.parseRemoteAgentBinaries(output)
        XCTAssertTrue(parsed.cliAvailable)
        XCTAssertEqual(parsed.cliPath, "/root/.local/bin/codex")
        XCTAssertEqual(parsed.bridgePath, "/usr/local/bin/tm-agent-bridge")

        let noBridge = TeamOrchestrator.parseRemoteAgentBinaries("""
        __TERMMESH_CLI_AVAILABLE__
        __TERMMESH_CLI_PATH__=/usr/bin/kiro-cli
        __TERMMESH_BRIDGE_PATH__=
        """)
        XCTAssertTrue(noBridge.cliAvailable)
        XCTAssertEqual(noBridge.bridgePath, "", "an absent bridge is data, not an error")

        let shellFunction = TeamOrchestrator.parseRemoteAgentBinaries("""
        __TERMMESH_CLI_AVAILABLE__
        __TERMMESH_CLI_PATH__=codex () { ... }
        __TERMMESH_BRIDGE_PATH__=
        """)
        XCTAssertTrue(
            shellFunction.cliAvailable,
            "the terminal path types a bare name, where a function works fine"
        )
        XCTAssertEqual(
            shellFunction.cliPath, "",
            "but --exe needs a path, and a function is not one"
        )

        let missing = TeamOrchestrator.parseRemoteAgentBinaries("""
        __TERMMESH_CLI_PATH__=
        __TERMMESH_BRIDGE_PATH__=/usr/local/bin/tm-agent-bridge
        """)
        XCTAssertFalse(missing.cliAvailable)
    }

    /// The probe has to survive `sh -c '…'` quoting, and it must search the
    /// same PATH the launcher does — a probe that looks elsewhere answers a
    /// different question than the one asked.
    @MainActor
    func test_probeScript_isSingleQuoteSafeAndAsksForBothBinaries() {
        let script = TeamOrchestrator.remoteAgentBinariesProbe(
            cli: "codex", hostBinDirs: ["/opt/tools/bin"]
        )
        XCTAssertTrue(script.contains("tm-agent-bridge"))
        XCTAssertTrue(script.contains("'codex'"))
        XCTAssertTrue(script.contains("/opt/tools/bin"))
        XCTAssertTrue(script.hasPrefix("export PATH="))
    }

    // MARK: Wire shape and teardown

    @MainActor
    func test_ensureAndAttach_sendsAgentKindAndTakesCallbackDelivery() async throws {
        let socketPath = "/tmp/peer-agent-test-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "my-team",
            agentInstanceId: "abcdef01-0000-0000-0000-000000000000",
            cli: "codex",
            workingDirectory: "/root/work/term-mesh",
            model: "sonnet",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/root/.local/bin/codex",
                execPath: "/root/.local/bin/codex",
                bridgePath: "/usr/local/bin/tm-agent-bridge",
                cliAvailable: true
            )
        )

        let ensured = try await PeerPaneSession.ensureAndAttach(
            lease: lease,
            surfaceSpec: spec,
            attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
            hostSpec: hostSpec,
            agentCli: "codex"
        )
        defer { ensured.session.teardown() }

        let request = try XCTUnwrap(host.ensureRequests().first)
        XCTAssertEqual(request.kind, "agent", "without this the daemon spawns a PTY")
        XCTAssertEqual(request.executable, "/usr/local/bin/tm-agent-bridge")
        XCTAssertEqual(request.cwd, "/root/work/term-mesh")
        // The model is translated per CLI by `bridgeModelArg` — what this
        // pins is the vector's shape and that nothing got dropped between
        // building the spec and putting it on the wire.
        XCTAssertEqual(
            request.args,
            ["--cli", "codex", "--cwd", "/root/work/term-mesh",
             "--model", TeamOrchestrator.bridgeModelArg(cli: "codex", model: "sonnet"),
             "--exe", "/root/.local/bin/codex"]
        )

        let surface = ensured.session.originSurface
        XCTAssertEqual(surface.surfaceType, SessionHostPanes.agentSurfaceType)
        XCTAssertEqual(
            surface.agentCli, "codex",
            "openRemoteAgentPane reads this to pick the renderer"
        )
        guard case .callback = ensured.session.relaySession.ptyDelivery else {
            return XCTFail("an agent surface must not be delivered through the relay helper")
        }
    }

    /// A daemon that never advertised `surface.agent.v1` must be refused
    /// locally — the caller needs a decision it can fall back from, not a
    /// wire error, and no surface may be created on the way to finding out.
    @MainActor
    func test_ensureAndAttach_refusesAgentKindOnAHostWithoutTheCapability() async throws {
        let socketPath = "/tmp/peer-agent-nocap-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [PeerCapability.surfaceEnsureV1]
        )
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            let ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: TeamOrchestrator.peerAgentSurfaceSpec(
                    teamName: "my-team",
                    agentInstanceId: UUID().uuidString,
                    cli: "codex",
                    workingDirectory: "/root/work",
                    model: "sonnet",
                    binaries: TeamOrchestrator.RemoteAgentBinaries(
                        cliPath: "/root/.local/bin/codex",
                        bridgePath: "/usr/local/bin/tm-agent-bridge",
                        cliAvailable: true
                    )
                ),
                attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
                hostSpec: hostSpec,
                agentCli: "codex"
            )
            ensured.session.teardown()
            XCTFail("an agent ensure must not be issued to a host without surface.agent.v1")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(PeerCapability.surfaceAgentV1),
                "the refusal must name the missing capability, got \(error)"
            )
        }
        XCTAssertTrue(
            host.ensureRequests().isEmpty,
            "nothing may be created on a host that cannot own it"
        )
        _ = hostTask
    }

    @MainActor
    func test_ensureAndAttachRejectsInvalidEnvironmentBeforeHostRequest() async throws {
        let socketPath = "/tmp/peer-agent-bad-env-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
            ]
        )
        let hostTask = try host.start()
        defer { host.stop() }
        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            _ = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: TeamOrchestrator.peerAgentSurfaceSpec(
                    teamName: "my-team",
                    agentInstanceId: UUID().uuidString,
                    cli: "codex",
                    workingDirectory: "/root/work",
                    model: "sonnet",
                    binaries: TeamOrchestrator.RemoteAgentBinaries(
                        cliPath: "/root/.local/bin/codex",
                        bridgePath: "/usr/local/bin/tm-agent-bridge",
                        cliAvailable: true
                    )
                ),
                attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
                hostSpec: hostSpec,
                agentCli: "codex",
                environment: ["유니코드": "invalid"]
            )
            XCTFail("invalid environment must be rejected locally")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ASCII identifier"))
        }
        XCTAssertTrue(host.ensureRequests().isEmpty)
        _ = hostTask
    }

    /// The cleanup verb. `requestClosePane` cannot do this job: an agent
    /// surface is deliberately never placed in the workspace tree, so a close
    /// by pane id finds nothing and reports success while the bridge keeps
    /// running on the peer.
    @MainActor
    func test_terminatePeerAgentSurface_addressesTheSurfaceRegistryDirectly() async throws {
        let socketPath = "/tmp/peer-agent-term-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        let hostTask = try host.start()
        defer { host.stop() }

        await TeamOrchestrator.terminatePeerAgentSurface(
            hostSockPath: socketPath,
            surfaceID: host.surfaceID
        )

        XCTAssertEqual(host.terminatedIDs(), [host.surfaceID])
        _ = hostTask
    }

    /// Best effort, both ways: an unreachable host and an empty id are
    /// no-ops rather than a second failure stacked on the one being unwound.
    @MainActor
    func test_terminatePeerAgentSurface_isANoOpWithNothingToTalkTo() async {
        await TeamOrchestrator.terminatePeerAgentSurface(
            hostSockPath: "", surfaceID: Data(repeating: 1, count: 16)
        )
        await TeamOrchestrator.terminatePeerAgentSurface(
            hostSockPath: "/tmp/does-not-exist-\(getpid()).sock",
            surfaceID: Data(repeating: 1, count: 16)
        )
    }

    @MainActor
    func test_failedLeaderCompensationTerminatesOwnerBeforeForgettingAndTeardown() async {
        let surfaceID = Data(repeating: 0x7a, count: 16)
        let owner = PeerPaneHostSpec.ssh(
            target: "mac-sub", remoteSockPath: "/owner/term-meshd-peer.sock",
            port: nil, identityFile: nil
        )
        var events: [String] = []
        await TeamOrchestrator.compensateFailedLeaderSurface(
            hostKey: "ssh:mac-sub", surfaceID: surfaceID, owningHostSpec: owner,
            terminate: { spec, actual in
                XCTAssertEqual(spec.hostKey.remoteSockPath, "/owner/term-meshd-peer.sock")
                XCTAssertEqual(actual, surfaceID)
                events.append("terminate")
                return true
            },
            forgetManaged: { _, actual in
                XCTAssertEqual(actual, surfaceID)
                events.append("forget")
            },
            enqueueCleanup: { _, _, _ in events.append("enqueue") },
            teardownLocal: { events.append("teardown") }
        )
        XCTAssertEqual(events, ["terminate", "forget", "teardown"])
    }

    @MainActor
    func test_failedLeaderCompensationPersistsOwnerTombstoneBeforeTeardown() async {
        let surfaceID = Data(repeating: 0x7b, count: 16)
        let owner = PeerPaneHostSpec.ssh(
            target: "mac-sub", remoteSockPath: "/owner/term-meshd-peer.sock",
            port: nil, identityFile: nil
        )
        var events: [String] = []
        var tombstone: (String, Data, String?)?
        await TeamOrchestrator.compensateFailedLeaderSurface(
            hostKey: "ssh:mac-sub", surfaceID: surfaceID, owningHostSpec: owner,
            terminate: { _, _ in events.append("terminate"); return false },
            forgetManaged: { _, _ in events.append("forget") },
            enqueueCleanup: { host, actual, endpoint in
                tombstone = (host, actual, endpoint)
                events.append("enqueue")
            },
            teardownLocal: { events.append("teardown") }
        )
        XCTAssertEqual(events, ["terminate", "enqueue", "teardown"])
        XCTAssertEqual(tombstone?.0, "ssh:mac-sub")
        XCTAssertEqual(tombstone?.1, surfaceID)
        XCTAssertEqual(tombstone?.2, "/owner/term-meshd-peer.sock")
        XCTAssertEqual(
            TeamOrchestrator.failedLeaderOwningSocketPath(
                .direct(sockPath: "/direct/term-meshd-peer.sock")
            ),
            "/direct/term-meshd-peer.sock"
        )
    }

    // MARK: Compensation after a committed ensure

    /// The ensure is the point of no return on the host, and the attach can
    /// still fail after it. Without compensation that failure produced the
    /// worst object in the system: a `tm-agent-bridge` running on the peer
    /// whose surface id nobody kept — not in the workspace tree (agent
    /// surfaces are never placed there), not in `ManagedPeerSurfaceStore`, not
    /// in any roster, so reachable by no cleanup UI at all. The caller then
    /// fell through to the terminal path and started a SECOND CLI in the same
    /// checkout, while telling the user "nothing was left running there".
    @MainActor
    func test_ensureAndAttach_takesTheSurfaceBackDownWhenTheAttachFails() async throws {
        let socketPath = "/tmp/peer-agent-orphan-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        host.redirectsAttach = true
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            let ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: TeamOrchestrator.peerAgentSurfaceSpec(
                    teamName: "my-team",
                    agentInstanceId: UUID().uuidString,
                    cli: "codex",
                    workingDirectory: "/root/work",
                    model: "sonnet",
                    binaries: TeamOrchestrator.RemoteAgentBinaries(
                        cliPath: "/root/.local/bin/codex",
                        execPath: "/root/.local/bin/codex",
                        bridgePath: "/usr/local/bin/tm-agent-bridge",
                        cliAvailable: true
                    )
                ),
                attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
                hostSpec: hostSpec,
                agentCli: "codex"
            )
            ensured.session.teardown()
            XCTFail("a redirected attach must not be reported as a successful one")
        } catch {
            // The failure itself is expected; what it must not do is keep the
            // surface.
        }

        XCTAssertEqual(host.ensureRequests().count, 1, "the ensure did commit a child")
        XCTAssertEqual(
            host.terminatedIDs(), [host.surfaceID],
            "the failed attach must spend the ensured surface id on the way out — "
                + "it is the only thing that can ever name that bridge again"
        )
        _ = hostTask
    }

    /// The remote-agent caller cannot rely on the best-effort compensation
    /// RPC: the same disconnect that breaks attach can break terminate too.
    /// It must durably record the ensured id before unwinding so reconnect can
    /// retry until the host confirms TERMINATED/NOT_FOUND.
    @MainActor
    func test_ensureAndAttach_durablyQueuesAgentWhenPostEnsureCleanupFails() async throws {
        let suiteName = "PostEnsureAgentCleanup-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostKey = "ssh:root@peer:/run/user/1000/term-mesh.sock"
        var cleanupAttempts = 0
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            automaticRetryDelay: 60,
            hostSockPathProvider: { _ in "/tmp/unreachable-peer.sock" },
            terminator: { _, _, _, _ in
                cleanupAttempts += 1
                return false
            }
        )
        let socketPath = "/tmp/peer-agent-durable-cleanup-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceAgentV1,
                PeerCapability.surfaceExitV1,
                PeerCapability.surfaceEnsureEnvV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        host.redirectsAttach = true
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            _ = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: TeamOrchestrator.peerAgentSurfaceSpec(
                    teamName: "my-team",
                    agentInstanceId: UUID().uuidString,
                    cli: "codex",
                    workingDirectory: "/root/work",
                    model: "sonnet",
                    binaries: TeamOrchestrator.RemoteAgentBinaries(
                        cliPath: "/root/.local/bin/codex",
                        execPath: "/root/.local/bin/codex",
                        bridgePath: "/usr/local/bin/tm-agent-bridge",
                        cliAvailable: true
                    )
                ),
                attachment: PeerRunnerAttachment(title: "reviewer", lifetime: .keepAlive),
                hostSpec: hostSpec,
                agentCli: "codex",
                onAgentPostEnsureFailure: { surfaceID in
                    TeamOrchestrator.enqueuePendingPeerAgentSurfaceCleanup(
                        hostKey: hostKey,
                        surfaceID: surfaceID,
                        cleanup: cleanup
                    )
                }
            )
            XCTFail("a redirected attach must fail")
        } catch {
            // Expected after ensure committed the remote child.
        }

        for _ in 0..<20 where cleanupAttempts == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(cleanupAttempts, 1, "the scheduler should try immediately")
        XCTAssertEqual(cleanup.pendingRecords.first?.surfaceID, host.surfaceID)
        XCTAssertTrue(
            host.terminatedIDs().isEmpty,
            "the caller-owned compensation must not race a second one-shot terminate"
        )
        let restored = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false
        )
        XCTAssertEqual(restored.pendingRecords.first?.hostKey, hostKey)
        XCTAssertEqual(restored.pendingRecords.first?.surfaceID, host.surfaceID)
        _ = hostTask
    }

    /// A saved *runner* surface is the opposite case and must survive the same
    /// failure: it is keyed to a profile the user re-launches, and reusing that
    /// exact surface is the contract
    /// (`test_savedRunnerRepeatedLaunchReusesExactEnsuredSurfaceID`).
    /// Terminating one because an attach blipped would throw away the session
    /// it exists to preserve.
    @MainActor
    func test_ensureAndAttach_leavesATerminalRunnerSurfaceAloneWhenTheAttachFails() async throws {
        let socketPath = "/tmp/peer-runner-orphan-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let host = AgentSurfaceMockHost(
            socketPath: socketPath,
            capabilities: [
                PeerCapability.surfaceEnsureV1,
                PeerCapability.surfaceTerminateV1,
            ]
        )
        host.redirectsAttach = true
        let hostTask = try host.start()
        defer { host.stop() }

        let hostSpec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let lease = try await PeerPaneHostRegistry.shared.acquire(hostSpec)
        defer { PeerPaneHostRegistry.shared.release(lease) }

        do {
            let ensured = try await PeerPaneSession.ensureAndAttach(
                lease: lease,
                surfaceSpec: PeerRunnerSurfaceSpec(
                    key: "runner/build",
                    cwd: "/root/work",
                    executable: "/bin/bash"
                ),
                attachment: PeerRunnerAttachment(title: "Runner", lifetime: .keepAlive),
                hostSpec: hostSpec
            )
            ensured.session.teardown()
            XCTFail("a redirected attach must not be reported as a successful one")
        } catch {
        }

        XCTAssertEqual(host.ensureRequests().count, 1)
        XCTAssertTrue(
            host.terminatedIDs().isEmpty,
            "a runner surface outlives its attach on purpose — that is what makes "
                + "re-launching a saved profile reuse the same session"
        )
        _ = hostTask
    }
}

// MARK: - Peer-owned agent lifecycle (Phase 3 repairs)

/// The paths that have to know a peer-owned agent from every other kind of
/// member, and what each of them gets wrong when it does not.
///
/// The trap they all share: a peer-owned agent is the first member to have
/// BOTH an `AgentPanel` on this Mac and a `remoteSurfaceID` on a peer. Every
/// pre-existing branch treated those as mutually exclusive.
final class PeerOwnedAgentLifecycleTests: XCTestCase {

    /// `--exe` names an executable, not a role. kiro is the one CLI where
    /// those differ: the role is `kiro`, the ACP server the bridge spawns is
    /// `kiro-cli` (`daemon/tm-agent-bridge/src/main.rs` defaults to it, and
    /// `defaultLaunchCommand` has said the same for as long as kiro has been
    /// supported). Resolving `kiro` and passing it as `--exe` overrode that
    /// correct default with a launcher that cannot speak ACP.
    @MainActor
    func test_bridgeExecutableName_isTheBinaryNotTheRole() {
        XCTAssertEqual(TeamOrchestrator.peerAgentExecutableName(cli: "kiro"), "kiro-cli")
        XCTAssertEqual(TeamOrchestrator.peerAgentExecutableName(cli: "codex"), "codex")
        XCTAssertEqual(TeamOrchestrator.peerAgentExecutableName(cli: "cursor"), "cursor")
    }

    /// The probe asks for both names because they have different consumers:
    /// the terminal path types the ROLE at a login shell, `--exe` needs the
    /// binary the bridge spawns.
    @MainActor
    func test_probeScript_asksForTheBridgesExecutableTooNotJustTheRole() {
        let kiro = TeamOrchestrator.remoteAgentBinariesProbe(cli: "kiro", hostBinDirs: [])
        XCTAssertTrue(kiro.contains("'kiro'"), "the terminal path still types the role name")
        XCTAssertTrue(
            kiro.contains("'kiro-cli'"),
            "and --exe still needs the binary tm-agent-bridge actually spawns"
        )
    }

    /// Two markers, two answers. A host where `kiro` is a wrapper and
    /// `kiro-cli` is the real server must not have the wrapper's path end up
    /// on the bridge's command line.
    @MainActor
    func test_probeParsing_keepsTheRolePathAndTheExecutablePathApart() {
        let parsed = TeamOrchestrator.parseRemoteAgentBinaries("""
        __TERMMESH_CLI_AVAILABLE__
        __TERMMESH_CLI_PATH__=/usr/local/bin/kiro
        __TERMMESH_EXE_PATH__=/root/.local/bin/kiro-cli
        __TERMMESH_BRIDGE_PATH__=/usr/local/bin/tm-agent-bridge
        """)
        XCTAssertEqual(parsed.cliPath, "/usr/local/bin/kiro")
        XCTAssertEqual(parsed.execPath, "/root/.local/bin/kiro-cli")
        XCTAssertEqual(parsed.bridgePath, "/usr/local/bin/tm-agent-bridge")

        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "team",
            agentInstanceId: UUID().uuidString,
            cli: "kiro",
            workingDirectory: "/root/work",
            model: "sonnet",
            binaries: parsed
        )
        XCTAssertEqual(
            spec.args.last, "/root/.local/bin/kiro-cli",
            "--exe must be the ACP server, never the launcher named after the role"
        )
    }

    /// An absent executable path is data: `--exe` is omitted and the bridge
    /// falls back to its own default, which for kiro is already `kiro-cli`.
    @MainActor
    func test_ensureSpec_stillOmitsExeWhenNoExecutableWasResolved() {
        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "team",
            agentInstanceId: UUID().uuidString,
            cli: "kiro",
            workingDirectory: "/root/work",
            model: "sonnet",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/usr/local/bin/kiro",
                execPath: "",
                bridgePath: "/usr/local/bin/tm-agent-bridge",
                cliAvailable: true
            )
        )
        XCTAssertFalse(
            spec.args.contains("--exe"),
            "the role's own path is not a substitute for the executable's"
        )
    }

    @MainActor
    func test_claudeEnsureSpecRunsDirectStreamJsonAndKeepsRendererMetadataOutOfArgv() {
        let spec = TeamOrchestrator.peerAgentSurfaceSpec(
            teamName: "team",
            agentInstanceId: "claude-instance",
            cli: "claude",
            workingDirectory: "/root/work",
            model: "opus",
            binaries: TeamOrchestrator.RemoteAgentBinaries(
                cliPath: "/root/.local/bin/claude",
                bridgePath: "",
                cliAvailable: true
            )
        )

        XCTAssertEqual(spec.executable, "/bin/sh")
        XCTAssertEqual(spec.kind, SessionHostPanes.agentSurfaceType)
        XCTAssertEqual(spec.args.prefix(2), ["-c", spec.args[1]])
        XCTAssertTrue(spec.args[1].contains("/root/.local/bin/claude"))
        XCTAssertTrue(spec.args[1].contains("--input-format"))
        XCTAssertTrue(spec.args[1].contains("stream-json"))
        XCTAssertTrue(spec.args[1].contains("--model"))
        XCTAssertTrue(spec.args[1].contains("opus"))
        XCTAssertEqual(Array(spec.args.suffix(2)), ["--cli", "claude"])
        XCTAssertFalse(
            spec.args[1].contains("--cli"),
            "renderer metadata must stay in shell positional args, not Claude's argv"
        )
    }

    /// Which daemon holds a surface decides who can reopen its pane.
    /// `SessionHostPanes.reconcile()` lists this Mac's daemon socket and
    /// nothing else, so answering "yes, local" for a peer surface is what
    /// silently retired a team member on the first healthy stream rewind.
    @MainActor
    func test_isLocalSessionHost_separatesThisMacsDaemonFromEveryPeer() {
        XCTAssertFalse(
            Workspace.isLocalSessionHost(
                .ssh(
                    target: "root@jw-server",
                    remoteSockPath: "/run/user/0/tm-peer.sock",
                    port: nil,
                    identityFile: nil
                )
            ),
            "an ssh peer is never reopened by the local poller"
        )
        XCTAssertFalse(
            Workspace.isLocalSessionHost(.direct(sockPath: "/tmp/some-other-daemon.sock"))
        )
        XCTAssertFalse(
            Workspace.isLocalSessionHost(.direct(sockPath: "")),
            "an empty path matches nothing, including an unset daemon path"
        )
        let daemonPath = TermMeshDaemon.shared.daemonPeerSocketPath
        if !daemonPath.isEmpty {
            XCTAssertTrue(Workspace.isLocalSessionHost(.direct(sockPath: daemonPath)))
        }
    }

    /// A peer-owned hard restart must replace the pane inside its live peer
    /// workspace. If that workspace is gone, fail before spawning anything and
    /// keep the old surface addressable so the user does not lose the session.
    @MainActor
    func test_peerOwnedRestartRequiresLiveWorkspaceBeforeReplacement() async {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "peer-owned-recycle-\(UUID().uuidString.prefix(8))"
        defer { orchestrator.forgetTeamForTests(teamName) }

        let member = TeamOrchestrator.AgentMember(
            id: "reviewer@\(teamName)",
            name: "reviewer",
            teamName: teamName,
            cli: "codex",
            launchCommand: "codex",
            model: "sonnet",
            agentType: "reviewer",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: UUID(),
            createdAt: Date(),
            remoteSurfaceID: Data(repeating: 0x5A, count: 16),
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            hostKey: "ssh:root@jw-server",
            originalAgentWorkDir: "/root/work/term-mesh"
        )
        orchestrator.installTeamForTests(name: teamName, agents: [member])

        let outcome = await orchestrator.restartAgentPaneHard(
            teamName: teamName,
            agentName: "reviewer"
        )
        guard case .failure(let error) = outcome else {
            return XCTFail("a peer-owned agent without a live workspace must not be replaced")
        }
        XCTAssertEqual(error.code, "workspace_missing")
        XCTAssertEqual(
            orchestrator.teams[teamName]?.agents.first?.remoteSurfaceID,
            Data(repeating: 0x5A, count: 16),
            "the failure must leave the surface id in the roster — it is the last "
                + "thing that can address the bridge"
        )
    }

    /// A remote ensure can take long enough for another agent to be added or
    /// detached. Committing the old Team value would erase that newer change;
    /// the replacement must patch only the member it originally observed.
    @MainActor
    func test_peerOwnedRestartRosterCASPreservesConcurrentMembersAndRejectsStaleTarget() {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "peer-owned-restart-cas-\(UUID().uuidString.prefix(8))"
        defer { orchestrator.forgetTeamForTests(teamName) }

        let oldPanelID = UUID()
        let oldSurfaceID = Data(repeating: 0x41, count: 16)
        let replacementPanelID = UUID()
        let replacementSurfaceID = Data(repeating: 0x42, count: 16)
        let siblingSurfaceID = Data(repeating: 0x51, count: 16)
        let old = TeamOrchestrator.AgentMember(
            id: "reviewer@\(teamName)",
            agentInstanceId: "reviewer-instance",
            name: "reviewer",
            teamName: teamName,
            cli: "codex",
            launchCommand: "codex",
            model: "sonnet",
            agentType: "reviewer",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: oldPanelID,
            createdAt: Date(),
            remoteSurfaceID: oldSurfaceID,
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            hostKey: "ssh:root@peer"
        )
        let sibling = TeamOrchestrator.AgentMember(
            id: "tester@\(teamName)",
            agentInstanceId: "tester-instance",
            name: "tester",
            teamName: teamName,
            cli: "claude",
            launchCommand: "claude",
            model: "sonnet",
            agentType: "tester",
            color: "blue",
            instructions: "",
            workspaceId: old.workspaceId,
            panelId: UUID(),
            createdAt: Date(),
            remoteSurfaceID: siblingSurfaceID,
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            hostKey: "ssh:root@peer"
        )
        var replacement = old
        replacement.panelId = replacementPanelID
        replacement.remoteSurfaceID = replacementSurfaceID
        orchestrator.installTeamForTests(name: teamName, agents: [old, sibling])

        guard let current = orchestrator.teams[teamName],
              let updated = TeamOrchestrator.teamByReplacingPeerOwnedAgent(
                  current: current,
                  expected: old,
                  replacement: replacement
              ) else {
            return XCTFail("the live target should be replaceable")
        }
        XCTAssertEqual(updated.agents.count, 2)
        XCTAssertEqual(updated.agents[0].panelId, replacementPanelID)
        XCTAssertEqual(updated.agents[1].remoteSurfaceID, siblingSurfaceID)

        XCTAssertNil(TeamOrchestrator.teamByReplacingPeerOwnedAgent(
            current: updated,
            expected: old,
            replacement: replacement
        ), "a stale completion must not overwrite the already replaced member")
        let rolledBack = TeamOrchestrator.teamByReplacingPeerOwnedAgent(
            current: updated,
            expected: replacement,
            replacement: old
        )
        XCTAssertEqual(rolledBack?.agents[0].panelId, oldPanelID)
        XCTAssertEqual(rolledBack?.agents[1].remoteSurfaceID, siblingSurfaceID)
    }

    @MainActor
    func testEndedPeerOwnedAgentRetirementRequiresExactSurfaceAndPreservesSiblings() {
        let teamName = "ended-peer-agent"
        let endedSurface = Data(repeating: 0x61, count: 16)
        let siblingSurface = Data(repeating: 0x62, count: 16)
        let workspaceID = UUID()
        let ended = TeamOrchestrator.AgentMember(
            id: "executor@\(teamName)", agentInstanceId: "executor-instance",
            name: "executor", teamName: teamName, cli: "claude",
            launchCommand: "claude", model: "sonnet", agentType: "executor",
            color: "green", instructions: "", workspaceId: workspaceID,
            panelId: UUID(), createdAt: Date(), remoteSurfaceID: endedSurface,
            remoteSurfaceSpawned: true, remoteAgentSurface: true, hostKey: "ssh:peer"
        )
        let sibling = TeamOrchestrator.AgentMember(
            id: "tester@\(teamName)", agentInstanceId: "tester-instance",
            name: "tester", teamName: teamName, cli: "codex",
            launchCommand: "codex", model: "gpt", agentType: "tester",
            color: "blue", instructions: "", workspaceId: workspaceID,
            panelId: UUID(), createdAt: Date(), remoteSurfaceID: siblingSurface,
            remoteSurfaceSpawned: true, remoteAgentSurface: true, hostKey: "ssh:peer"
        )
        let current = TeamOrchestrator.Team(
            id: teamName, leaderSessionId: UUID().uuidString, leaderMode: "adopted",
            leaderModel: "opus", leaderCli: "claude", leaderPanelId: UUID(),
            workingDirectory: "/tmp", workspaceId: workspaceID,
            agents: [ended, sibling], createdAt: Date(), gitRepoRoot: nil,
            worktreeMode: "off", ownsRemotePresentation: true
        )

        let result = TeamOrchestrator.teamByRetiringEndedPeerOwnedAgent(
            current: current, agentInstanceID: ended.agentInstanceId, surfaceID: endedSurface
        )
        XCTAssertEqual(result?.retired.agentInstanceId, ended.agentInstanceId)
        XCTAssertEqual(result?.team.agents.map(\.agentInstanceId), [sibling.agentInstanceId])
        XCTAssertNil(TeamOrchestrator.teamByRetiringEndedPeerOwnedAgent(
            current: current,
            agentInstanceID: ended.agentInstanceId,
            surfaceID: Data(repeating: 0x63, count: 16)
        ), "a stale surface-exit callback must not retire a replacement")
    }

    @MainActor
    func testEndedPeerOwnedAgentRetirementRunsOnlyInTheOwnerViewer() {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "ended-owner-guard-\(UUID().uuidString.prefix(8))"
        defer { orchestrator.forgetTeamForTests(teamName) }
        let surfaceID = Data(repeating: 0x71, count: 16)
        let workspace = Workspace(title: "owner-guard")
        let member = TeamOrchestrator.AgentMember(
            id: "executor@\(teamName)", agentInstanceId: "executor-instance",
            name: "executor", teamName: teamName, cli: "claude",
            launchCommand: "claude", model: "sonnet", agentType: "executor",
            color: "green", instructions: "", workspaceId: workspace.id,
            panelId: UUID(), createdAt: Date(), remoteSurfaceID: surfaceID,
            remoteSurfaceSpawned: true, remoteAgentSurface: true, hostKey: "ssh:peer"
        )

        orchestrator.installTeamForTests(name: teamName, agents: [member])
        orchestrator.retireEndedPeerOwnedAgent(
            panelID: member.panelId!, surfaceID: surfaceID, workspace: workspace
        )
        XCTAssertEqual(orchestrator.teams[teamName]?.agents.count, 1)

        orchestrator.forgetTeamForTests(teamName)
        orchestrator.installTeamForTests(
            name: teamName, agents: [member], ownsRemotePresentation: true
        )
        orchestrator.retireEndedPeerOwnedAgent(
            panelID: member.panelId!, surfaceID: surfaceID, workspace: workspace
        )
        XCTAssertEqual(orchestrator.teams[teamName]?.agents.count, 0)
    }

    /// The retry pass snapshots records, then awaits each terminate. In that
    /// window `enqueue` can enrich the live record with the exact owning
    /// endpoint the snapshot did not have — and the in-flight nil-owner
    /// attempt resolves by the host's current route, whose `notFound` reads
    /// as success. Spending the record by id alone would drop the enriched
    /// tombstone and orphan the bridge on the endpoint that has it.
    @MainActor
    func test_retrySpendsOnlyTheSnapshotItTerminated_notAnEnrichedRecord() async {
        let suiteName = "CleanupEnrichRace-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            automaticRetryDelay: 60,
            hostSockPathProvider: { _ in nil },
            terminator: { _, _, _, _ in false }
        )
        let surfaceID = Data(repeating: 0x5A, count: 16)
        cleanup.enqueue(hostKey: "ssh:host", surfaceID: surfaceID)

        await cleanup.retryPending(
            hostSockPath: { _ in "/tmp/serving.sock" },
            terminate: { _, _, _, owner in
                XCTAssertNil(owner, "the snapshot carried no owner")
                // The enrichment lands while this attempt is in flight.
                cleanup.enqueue(
                    hostKey: "ssh:host",
                    surfaceID: surfaceID,
                    owningRemoteSockPath: "/run/user/1000/real-owner.sock"
                )
                return true  // wrong-owner notFound — indistinguishable from success
            }
        )
        XCTAssertEqual(
            cleanup.pendingRecords.map(\.owningRemoteSockPath),
            ["/run/user/1000/real-owner.sock"],
            "the enriched tombstone must survive the stale success"
        )

        // The next pass, armed with the recorded owner, is the one that spends it.
        await cleanup.retryPending(
            hostSockPath: { _ in "/tmp/serving.sock" },
            terminate: { _, _, _, owner in
                XCTAssertEqual(owner, "/run/user/1000/real-owner.sock")
                return true
            }
        )
        XCTAssertTrue(cleanup.pendingRecords.isEmpty)
    }

    /// Detach/delete/destroy all funnel through this: a member whose bridge
    /// the peer owns gets the terminate, and nothing else does. A local native
    /// agent has no peer surface, and a borrowed (not spawned) surface belongs
    /// to the host's operator.
    @MainActor
    func test_releasePeerOwnedAgentSurface_onlyActsOnAPeerOwnedAgent() {
        let suiteName = "PeerOwnedAgentReleaseTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            hostSockPathProvider: { _ in nil },
            terminator: { _, _, _, _ in false }
        )
        func member(
            remoteAgentSurface: Bool,
            spawned: Bool = true,
            surfaceID: Data? = Data(repeating: 0x5A, count: 16),
            hostKey: String? = "ssh:root@jw-server"
        ) -> TeamOrchestrator.AgentMember {
            TeamOrchestrator.AgentMember(
                id: "reviewer@t",
                name: "reviewer",
                teamName: "t",
                cli: "codex",
                launchCommand: "codex",
                model: "sonnet",
                agentType: "reviewer",
                color: "green",
                instructions: "",
                workspaceId: UUID(),
                panelId: UUID(),
                createdAt: Date(),
                remoteSurfaceID: surfaceID,
                remoteSurfaceSpawned: spawned,
                remoteAgentSurface: remoteAgentSurface,
                hostKey: hostKey
            )
        }
        // No host is registered in a unit test, so every call is a no-op at
        // the store lookup — what is pinned here is that none of them trap or
        // reach a `Task` with a half-built target.
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: false), cleanup: cleanup
        )
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: true, spawned: false), cleanup: cleanup
        )
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: true, surfaceID: nil), cleanup: cleanup
        )
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: true, hostKey: nil), cleanup: cleanup
        )
        XCTAssertTrue(cleanup.pendingRecords.isEmpty)
        TeamOrchestrator.releasePeerOwnedAgentSurface(
            member(remoteAgentSurface: true), cleanup: cleanup
        )
        XCTAssertEqual(cleanup.pendingRecords.count, 1)
    }

    @MainActor
    func testPendingPeerAgentCleanupPersistsUntilTerminationIsConfirmed() async {
        let suiteName = "PendingPeerAgentCleanupTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostKey = "ssh:root@peer:/run/user/1000/term-mesh.sock"
        let surfaceID = Data(repeating: 0x4A, count: 16)

        let first = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults, observeNotifications: false
        )
        first.enqueue(hostKey: hostKey, surfaceID: surfaceID)
        XCTAssertEqual(first.pendingRecords.count, 1)

        let restored = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults, observeNotifications: false
        )
        XCTAssertEqual(restored.pendingRecords.first?.surfaceID, surfaceID)

        await restored.retryPending(
            hostSockPath: { _ in "/tmp/peer.sock" },
            terminate: { _, _, _, _ in false }
        )
        XCTAssertEqual(
            restored.pendingRecords.count, 1,
            "a transport/RPC failure must retain the only durable cleanup handle"
        )

        await restored.retryPending(
            hostSockPath: { _ in "/tmp/peer.sock" },
            terminate: { _, _, _, _ in true }
        )
        XCTAssertTrue(restored.pendingRecords.isEmpty)
        let afterConfirmation = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults, observeNotifications: false
        )
        XCTAssertTrue(afterConfirmation.pendingRecords.isEmpty)
    }

    @MainActor
    func testPendingPeerAgentCleanupUsesConnectedSocketBeforeLaunchMetadataResolves() async {
        let suiteName = "PendingPeerAgentCleanupUnresolvedMetadata-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostKey = "ssh:root@peer"
        let socketPath = "/tmp/authenticated-peer.sock"
        let host = HostEntry(
            id: hostKey,
            displayName: "peer",
            connectionState: .connected,
            workspaces: [],
            activeSockPath: socketPath,
            sshTarget: "root@peer",
            remoteSockPath: "/run/user/0/term-mesh.sock"
        )
        XCTAssertFalse(host.isLaunchable, "the launch metadata fixture must remain unresolved")
        var attemptedSocket: String?
        var attemptedHostKey: String?
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            automaticRetryDelay: 60,
            hostSockPathProvider: { requestedHostKey in
                PendingPeerAgentSurfaceCleanupStore.connectedHostSockPath(
                    for: requestedHostKey,
                    in: [host]
                )
            },
            terminator: { resolvedHostKey, resolvedSocket, _, _ in
                attemptedHostKey = resolvedHostKey
                attemptedSocket = resolvedSocket
                return true
            }
        )

        cleanup.enqueue(hostKey: hostKey, surfaceID: Data(repeating: 0x31, count: 16))
        cleanup.scheduleRetry()
        for _ in 0..<20 where attemptedSocket == nil {
            await Task.yield()
        }

        XCTAssertEqual(attemptedSocket, socketPath)
        // The host key rides along so cleanup can resolve the endpoint that
        // actually created the surface. Without it a redirected host's
        // tombstone is sent to the socket that merely served the handshake.
        XCTAssertEqual(attemptedHostKey, hostKey)
        XCTAssertTrue(cleanup.pendingRecords.isEmpty, "confirmed termination removes the tombstone")
        XCTAssertNil(
            PendingPeerAgentSurfaceCleanupStore.connectedHostSockPath(
                for: hostKey,
                in: [HostEntry(
                    id: hostKey,
                    displayName: "peer",
                    connectionState: .saved,
                    workspaces: [],
                    activeSockPath: socketPath,
                    sshTarget: "root@peer",
                    remoteSockPath: "/run/user/0/term-mesh.sock"
                )]
            ),
            "a disconnected row must not reuse its stale socket"
        )
    }

    @MainActor
    func testPreMemberPeerAgentCleanupQueuesDurableSurfaceHandle() {
        let suiteName = "PreMemberPeerAgentCleanup-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cleanup = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            hostSockPathProvider: { _ in nil },
            terminator: { _, _, _, _ in false }
        )
        let surfaceID = Data(repeating: 0x52, count: 16)

        TeamOrchestrator.enqueuePendingPeerAgentSurfaceCleanup(
            hostKey: "ssh:root@peer:/run/user/1000/term-mesh.sock",
            surfaceID: surfaceID,
            cleanup: cleanup
        )

        XCTAssertEqual(cleanup.pendingRecords.first?.surfaceID, surfaceID)
        let restored = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false
        )
        XCTAssertEqual(restored.pendingRecords.first?.surfaceID, surfaceID)
    }

    @MainActor
    func testPendingPeerAgentCleanupAutomaticallyRetriesWithoutRelayNotification() async {
        let suiteName = "PendingPeerAgentCleanupAutoRetry-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var attempts = 0
        let store = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults,
            observeNotifications: false,
            automaticRetryDelay: 0.01,
            hostSockPathProvider: { _ in "/tmp/peer.sock" },
            terminator: { _, _, _, _ in
                attempts += 1
                return attempts >= 2
            }
        )
        store.enqueue(
            hostKey: "ssh:root@peer:/run/user/1000/term-mesh.sock",
            surfaceID: Data(repeating: 0x6B, count: 16)
        )
        store.scheduleRetry()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(attempts, 2)
        XCTAssertTrue(store.pendingRecords.isEmpty)
    }

    @MainActor
    func testPeerAgentRecoveryRetriesTransientFailuresAndStopsOnSuccess() async {
        var attempts = 0
        var delays: [TimeInterval] = []
        let result = await TeamOrchestrator.retryPeerAgentPaneRecovery(
            maxAttempts: 6,
            sleep: { delays.append($0) },
            attempt: {
                attempts += 1
                return attempts < 3 ? .transientFailure : .recovered
            }
        )
        XCTAssertEqual(result, .recovered)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, [1, 2])
    }

    @MainActor
    func testPeerAgentRecoveryDoesNotRetryAuthoritativeAbsence() async {
        var attempts = 0
        let result = await TeamOrchestrator.retryPeerAgentPaneRecovery(
            maxAttempts: 6,
            sleep: { _ in XCTFail("authoritative absence must not back off") },
            attempt: {
                attempts += 1
                return .authoritativeMissing
            }
        )
        XCTAssertEqual(result, .authoritativeMissing)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testPeerAgentRecoveryIsBoundedAndRetainsCoordinatorRequest() async {
        let coordinator = PeerAgentPaneRecoveryCoordinator(observeNotifications: false)
        let request = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: "t",
            agentInstanceID: "instance",
            closedPanelID: UUID(),
            surfaceID: Data(repeating: 0x33, count: 16)
        )
        coordinator.remember(request)
        var attempts = 0
        let result = await TeamOrchestrator.retryPeerAgentPaneRecovery(
            maxAttempts: 3,
            sleep: { _ in },
            attempt: {
                attempts += 1
                return .transientFailure
            }
        )
        XCTAssertEqual(result, .transientFailure)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(coordinator.pending, [request])
        coordinator.forget(request)
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    @MainActor
    func testPeerAgentRecoveryCoordinatorAutomaticallyRetriesWithoutRelayNotification() async {
        var retries = 0
        let coordinator = PeerAgentPaneRecoveryCoordinator(
            observeNotifications: false,
            automaticRetryDelay: 0.01,
            retryAction: { retries += 1 }
        )
        let request = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: "t",
            agentInstanceID: "instance",
            closedPanelID: UUID(),
            surfaceID: Data(repeating: 0x77, count: 16)
        )
        coordinator.remember(request)
        coordinator.scheduleRetryIfNeeded()
        try? await Task.sleep(nanoseconds: 45_000_000)
        XCTAssertGreaterThanOrEqual(retries, 2)
        coordinator.forget(request)
    }

    @MainActor
    func testPeerAgentRecoveryCoordinatorStaleCompletionKeepsNewerRequest() {
        let coordinator = PeerAgentPaneRecoveryCoordinator(observeNotifications: false)
        let stale = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: "t",
            agentInstanceID: "instance",
            closedPanelID: UUID(),
            surfaceID: Data(repeating: 0x10, count: 16)
        )
        let replacement = PeerAgentPaneRecoveryCoordinator.Request(
            teamName: stale.teamName,
            agentInstanceID: stale.agentInstanceID,
            closedPanelID: UUID(),
            surfaceID: Data(repeating: 0x20, count: 16)
        )

        coordinator.remember(stale)
        coordinator.remember(replacement)
        coordinator.forget(stale)

        XCTAssertEqual(coordinator.pending, [replacement])
        coordinator.forget(replacement)
    }

    @MainActor
    func testPeerAgentRecoveryOwnershipRevalidationRejectsDetachedOrReplacedMember() {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "peer-recovery-owner-\(UUID().uuidString.prefix(8))"
        let surfaceID = Data(repeating: 0x61, count: 16)
        let member = TeamOrchestrator.AgentMember(
            id: "reviewer@\(teamName)",
            agentInstanceId: "durable-instance",
            name: "reviewer",
            teamName: teamName,
            cli: "codex",
            launchCommand: "codex",
            model: "sonnet",
            agentType: "reviewer",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: UUID(),
            createdAt: Date(),
            remoteSurfaceID: surfaceID,
            remoteSurfaceSpawned: true,
            remoteAgentSurface: true,
            hostKey: "ssh:root@peer",
            originalAgentWorkDir: "/root/work"
        )
        defer { orchestrator.forgetTeamForTests(teamName) }
        orchestrator.installTeamForTests(name: teamName, agents: [member])

        XCTAssertTrue(orchestrator.ownsPeerAgentSurface(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            surfaceID: surfaceID
        ))
        XCTAssertTrue(orchestrator.ownsPeerAgentSurface(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            surfaceID: surfaceID,
            panelID: member.panelId
        ))
        XCTAssertFalse(orchestrator.ownsPeerAgentSurface(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            surfaceID: surfaceID,
            panelID: UUID()
        ), "a callback from an older local pane must not own the replacement")
        XCTAssertFalse(orchestrator.ownsPeerAgentSurface(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            surfaceID: Data(repeating: 0x62, count: 16)
        ))

        orchestrator.forgetTeamForTests(teamName)
        var teardownCount = 0
        XCTAssertFalse(orchestrator.validatePeerAgentRecoveryOwnership(
            teamName: teamName,
            agentInstanceID: member.agentInstanceId,
            surfaceID: surfaceID,
            onMismatch: { teardownCount += 1 }
        ))
        XCTAssertEqual(teardownCount, 1, "a stale attached session must be torn down")
    }

    @MainActor
    func testPeerAgentMemberLookupRequiresPanelGenerationWhenSurfaceIsReused() {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "peer-member-generation-\(UUID().uuidString.prefix(8))"
        let surfaceID = Data(repeating: 0x72, count: 16)
        let currentPanelID = UUID()
        let member = TeamOrchestrator.AgentMember(
            id: "executor@\(teamName)", agentInstanceId: "executor-instance",
            name: "executor", teamName: teamName, cli: "codex",
            launchCommand: "codex", model: "sonnet", agentType: "executor",
            color: "green", instructions: "", workspaceId: UUID(),
            panelId: currentPanelID, createdAt: Date(), remoteSurfaceID: surfaceID,
            remoteSurfaceSpawned: true, remoteAgentSurface: true, hostKey: "ssh:peer"
        )
        defer { orchestrator.forgetTeamForTests(teamName) }
        orchestrator.installTeamForTests(name: teamName, agents: [member])

        XCTAssertNil(orchestrator.peerOwnedAgentMember(
            panelID: UUID(), surfaceID: surfaceID
        ))
        XCTAssertEqual(orchestrator.peerOwnedAgentMember(
            panelID: currentPanelID, surfaceID: surfaceID
        )?.agent.agentInstanceId, member.agentInstanceId)
    }

    @MainActor
    func testCollaborationPresentationStateNamesTheFirstBrokenInvariant() {
        typealias Probe = TeamOrchestrator.AgentPresentationProbe
        XCTAssertEqual(TeamOrchestrator.collaborationPresentationState(
            teamExists: true, workspaceExists: false,
            leaderPanelExists: false, leaderSessionReady: false,
            agents: [], requireLiveSessions: true
        ), .workspaceMissing)
        XCTAssertEqual(TeamOrchestrator.collaborationPresentationState(
            teamExists: true, workspaceExists: true,
            leaderPanelExists: true, leaderSessionReady: true,
            agents: [Probe(instanceID: "worker", panelPresent: true, sessionReady: false)],
            requireLiveSessions: true
        ), .agentSessionUnavailable("worker"))
        XCTAssertEqual(TeamOrchestrator.collaborationPresentationState(
            teamExists: true, workspaceExists: true,
            leaderPanelExists: true, leaderSessionReady: false,
            agents: [Probe(instanceID: "worker", panelPresent: true, sessionReady: false)],
            requireLiveSessions: false
        ), .ready, "Repair can refresh existing panels before their relays settle")
        XCTAssertEqual(TeamOrchestrator.collaborationPresentationState(
            teamExists: true, workspaceExists: true,
            leaderPanelExists: true, leaderSessionReady: true,
            agents: [Probe(instanceID: "dead", panelPresent: false, sessionReady: false)],
            requireLiveSessions: false,
            repairableMissingAgentIDs: ["dead"]
        ), .ready, "an authoritative dead worker can be respawned from its durable member")
    }

    @MainActor
    func testAdoptedReplacementRefusesAnUnreadyPresentation() {
        let orchestrator = TeamOrchestrator.shared
        let teamName = "replace-unready-\(UUID().uuidString.prefix(8))"
        defer { orchestrator.forgetTeamForTests(teamName) }
        orchestrator.installTeamForTests(name: teamName, agents: [])
        guard let replacement = orchestrator.teams[teamName] else {
            return XCTFail("team fixture missing")
        }

        let result = orchestrator.replaceAdoptedRemoteProject(
            replacement,
            expectedWorkspaceID: replacement.workspaceId,
            expectedRevision: 0,
            replacementPresentationReady: false
        )
        XCTAssertFalse(result.replaced)
        XCTAssertEqual(
            orchestrator.teams[teamName]?.leaderSessionId,
            replacement.leaderSessionId
        )
    }

    /// The field the three cleanup paths read. Defaulting it to false is what
    /// keeps every pre-existing member — local, native, terminal-backed peer —
    /// on exactly the branch it had before.
    @MainActor
    func test_remoteAgentSurface_defaultsToFalseForEveryOtherKindOfMember() {
        let terminalBacked = TeamOrchestrator.AgentMember(
            id: "reviewer@t",
            name: "reviewer",
            teamName: "t",
            cli: "codex",
            launchCommand: "codex",
            model: "sonnet",
            agentType: "reviewer",
            color: "green",
            instructions: "",
            workspaceId: UUID(),
            panelId: UUID(),
            createdAt: Date(),
            remoteSurfaceID: Data(repeating: 0x5A, count: 16),
            remoteSurfaceSpawned: true,
            hostKey: "ssh:root@jw-server"
        )
        XCTAssertFalse(terminalBacked.remoteAgentSurface)
    }
    /// A duplicate enqueue must enrich an ambiguous record rather than discard
    /// the better information.
    ///
    /// A nil endpoint resolves by the host's *current* route, which is the
    /// wrong-owner guess these records exist to prevent. Once some caller knows
    /// the exact creation endpoint, keeping the older nil would carry that
    /// ambiguity forever.
    @MainActor
    func testADuplicateEnqueueUpgradesAnAmbiguousEndpointButNeverDowngrades() {
        let suiteName = "termmesh.tests.cleanup.upgrade.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("no test defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults, observeNotifications: false
        )
        let hostKey = "ssh:root@peer:/run/user/1000/term-mesh.sock"
        let surfaceID = Data(repeating: 0x63, count: 16)

        store.enqueue(hostKey: hostKey, surfaceID: surfaceID)
        XCTAssertNil(store.pendingRecords.first?.owningRemoteSockPath)

        store.enqueue(
            hostKey: hostKey, surfaceID: surfaceID,
            owningRemoteSockPath: "/tmp/OWNER-A/peer.sock"
        )
        XCTAssertEqual(store.pendingRecords.count, 1, "still one surface, not two")
        XCTAssertEqual(
            store.pendingRecords.first?.owningRemoteSockPath,
            "/tmp/OWNER-A/peer.sock"
        )

        // An empty string names no endpoint and must not erase a known one.
        store.enqueue(hostKey: hostKey, surfaceID: surfaceID, owningRemoteSockPath: "")
        store.enqueue(hostKey: hostKey, surfaceID: surfaceID)
        XCTAssertEqual(
            store.pendingRecords.first?.owningRemoteSockPath,
            "/tmp/OWNER-A/peer.sock",
            "a known endpoint is never downgraded to nil"
        )

        // The upgrade is durable, not just in memory.
        let restored = PendingPeerAgentSurfaceCleanupStore(
            defaults: defaults, observeNotifications: false
        )
        XCTAssertEqual(
            restored.pendingRecords.first?.owningRemoteSockPath,
            "/tmp/OWNER-A/peer.sock"
        )
    }
}

/// A peer daemon that answers ensure / attach / terminate and records what it
/// was asked for. Deliberately generic where `RunnerMockHost` is scripted:
/// these tests care about the SHAPE of the requests, and one of them checks
/// that a request never arrives at all.
private final class AgentSurfaceMockHost: @unchecked Sendable {
    enum Failure: Error {
        case syscall(String, Int32)
        case unexpectedMessage(String)
        case timedOut(String)
    }

    let socketPath: String
    let surfaceID = Data(repeating: 0x5A, count: 16)
    /// Answer every attach with a DIFFERENT surface id, which is how a host
    /// redirects an attachment and what `PeerRelaySession.attach` refuses with
    /// `surfaceIDMismatch`. The cheapest way to reach the one window that
    /// matters: the ensure has committed a child on the host and the attach
    /// then fails.
    var redirectsAttach = false
    private let capabilities: [String]
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFDs: Set<Int32> = []
    private var ensures: [Termmesh_Peer_V1_EnsureSurfaceRequest] = []
    private var terminated: [Data] = []
    private var deadline: Date = .distantFuture
    private static let listenerBudget: TimeInterval = 60

    init(socketPath: String, capabilities: [String]) {
        self.socketPath = socketPath
        self.capabilities = capabilities
    }

    func ensureRequests() -> [Termmesh_Peer_V1_EnsureSurfaceRequest] {
        lock.lock(); defer { lock.unlock() }
        return ensures
    }

    func terminatedIDs() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    func start() throws -> Task<Void, Error> {
        deadline = Date().addingTimeInterval(Self.listenerBudget)
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.syscall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else {
            close(fd)
            throw Failure.syscall("socket path", ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                for (offset, byte) in path.enumerated() {
                    bytes[offset] = CChar(bitPattern: byte)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.syscall("bind", code)
        }
        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            throw Failure.syscall("listen", code)
        }
        listenerFD = fd
        return Task.detached { [self] in
            defer { finishListener(fd) }
            while true {
                do {
                    try waitForEvent(fd: fd, event: Int16(POLLIN), operation: "accept")
                } catch {
                    return
                }
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                register(client)
                defer {
                    unregister(client)
                    close(client)
                }
                // A closed connection is how every one of these ends; the
                // conversation itself is what the tests assert on.
                try? serve(client: client)
            }
        }
    }

    func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        let clients = clientFDs
        lock.unlock()
        for client in clients { Darwin.shutdown(client, SHUT_RDWR) }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
    }

    private func finishListener(_ fd: Int32) {
        lock.lock()
        let owns = listenerFD == fd
        if owns { listenerFD = -1 }
        lock.unlock()
        if owns { close(fd) }
        unlink(socketPath)
    }

    private func register(_ fd: Int32) {
        lock.lock(); clientFDs.insert(fd); lock.unlock()
    }

    private func unregister(_ fd: Int32) {
        lock.lock(); clientFDs.remove(fd); lock.unlock()
    }

    private func serve(client: Int32) throws {
        guard case .hello = try readEnvelope(client).payload else {
            throw Failure.unexpectedMessage("expected Hello")
        }
        var hello = Termmesh_Peer_V1_Hello()
        hello.protocolVersion = "1.0.0"
        hello.peerID = Data(repeating: 0x31, count: 16)
        hello.displayName = "agent-mock"
        hello.appVersion = "test"
        hello.capabilities = capabilities
        try send(client) { $0.hello = hello }

        var challenge = Termmesh_Peer_V1_AuthChallenge()
        challenge.nonce = Data(repeating: 0x42, count: 32)
        challenge.supportedMethods = ["ssh-passthrough"]
        try send(client) { $0.authChallenge = challenge }
        guard case .auth = try readEnvelope(client).payload else {
            throw Failure.unexpectedMessage("expected Auth")
        }
        var authResult = Termmesh_Peer_V1_AuthResult()
        authResult.accepted = true
        authResult.sessionID = Data(repeating: 0x51, count: 16)
        try send(client) { $0.authResult = authResult }

        while true {
            let envelope = try readEnvelope(client)
            switch envelope.payload {
            case .ensureSurfaceRequest(let request):
                lock.lock(); ensures.append(request); lock.unlock()
                var response = Termmesh_Peer_V1_EnsureSurfaceResponse()
                response.requestID = request.requestID
                response.result = .created
                response.surfaceID = surfaceID
                response.instanceID = Data(repeating: 0x62, count: 16)
                response.generation = 1
                response.pid = 2424
                response.specHash = Data(repeating: 0x73, count: 32)
                try send(client) { $0.ensureSurfaceResponse = response }
            case .attachSurface(let attach):
                var attached = Termmesh_Peer_V1_AttachResult()
                attached.accepted = true
                attached.surfaceID = redirectsAttach
                    ? Data(repeating: 0x11, count: 16)
                    : attach.surfaceID
                attached.grantedMode = attach.mode
                try send(client) { $0.attachResult = attached }
            case .terminateSurfaceRequest(let request):
                lock.lock(); terminated.append(request.surfaceID); lock.unlock()
                var response = Termmesh_Peer_V1_TerminateSurfaceResponse()
                response.requestID = request.requestID
                response.result = .terminated
                response.surfaceID = request.surfaceID
                try send(client) { $0.terminateSurfaceResponse = response }
            case .goodbye:
                return
            default:
                continue
            }
        }
    }

    private func waitForEvent(fd: Int32, event: Int16, operation: String) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure.timedOut(operation) }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let timeoutMS = Int32(min(remaining * 1_000, Double(Int32.max)))
            let result = Darwin.poll(&descriptor, 1, timeoutMS)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else {
                if result == 0 { throw Failure.timedOut(operation) }
                throw Failure.syscall("poll \(operation)", errno)
            }
            guard descriptor.revents & event != 0 else {
                throw Failure.syscall("poll \(operation)", ECONNRESET)
            }
            return
        }
    }

    private func send(
        _ fd: Int32,
        configure: (inout Termmesh_Peer_V1_Envelope) -> Void
    ) throws {
        var envelope = Termmesh_Peer_V1_Envelope()
        configure(&envelope)
        try writeAll(fd, try encodeFrame(envelope))
    }

    private func readEnvelope(_ fd: Int32) throws -> Termmesh_Peer_V1_Envelope {
        var prefix = Data(count: 4)
        try readAll(fd, into: &prefix)
        let length = Int(prefix.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        var payload = Data(count: length)
        try readAll(fd, into: &payload)
        var frame = prefix + payload
        guard let envelope = try decodeFrame(from: &frame) else {
            throw Failure.unexpectedMessage("incomplete frame")
        }
        return envelope
    }

    private func readAll(_ fd: Int32, into data: inout Data) throws {
        var offset = 0
        let totalCount = data.count
        while offset < totalCount {
            try waitForEvent(fd: fd, event: Int16(POLLIN), operation: "read")
            let count = data.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress! + offset, totalCount - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.syscall("read", errno) }
            offset += count
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try waitForEvent(fd: fd, event: Int16(POLLOUT), operation: "write")
            let count = data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress! + offset, data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.syscall("write", errno) }
            offset += count
        }
    }
}
