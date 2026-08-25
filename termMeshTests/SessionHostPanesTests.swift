import XCTest
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A session the daemon owns outlives the app, which is the point of it — but
/// until something attaches, the machine holding the work is the one place you
/// cannot see it. A project placed on a peer looked exactly like that: the
/// leader's own machine showed a workspace and no team.
///
/// Mirroring the daemon's workspace does not solve it. The daemon places
/// ensured sessions as *tabs* in one pane, deliberately, and
/// `PeerWorkspaceMirror` renders a pane's active surface with no notion of a
/// tab strip — measured against a live daemon holding three sessions, the
/// mirror showed one. These tests cover the per-surface decision instead.
@MainActor
final class SessionHostPanesTests: XCTestCase {
    func test_hostAutoOpenFinalizesHalfSplitChainAsCanonicalProjectGrid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-project-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectPresentationLayoutStore(
            fileURL: directory.appendingPathComponent("layouts.json")
        )
        let workspace = Workspace(title: "host-project-layout")
        let leaderPanel = try XCTUnwrap(workspace.focusedPanelId)
        var agentPanels: [UUID] = []
        var splitFrom = leaderPanel
        for _ in 0..<3 {
            let panel = try XCTUnwrap(workspace.newTerminalSplit(
                from: splitFrom, orientation: .horizontal, focus: false
            )?.id)
            agentPanels.append(panel)
            splitFrom = panel
        }
        let surfaces = (0..<4).map { Data(repeating: UInt8(0x70 + $0), count: 16) }
        workspace.debugProjectLayoutSurfaceIDs = Dictionary(
            uniqueKeysWithValues: zip([leaderPanel] + agentPanels, surfaces)
        )
        var project = Termmesh_Peer_V1_Team()
        project.name = "hosted"
        project.projectID = "team:hosted"
        project.teamUuid = "hosted"
        project.leaderSurfaceID = surfaces[0]
        project.members = surfaces.dropFirst().enumerated().map { index, surfaceID in
            var member = Termmesh_Peer_V1_TeamMember()
            member.name = "agent-\(index)"
            member.surfaceID = surfaceID
            return member
        }

        XCTAssertEqual(
            SessionHostPanes.finalizeHostedProjectLayout(
                project: project, workspace: workspace,
                anchorPanelID: nil, layoutStore: store
            ),
            .rebuiltCanonical
        )
        let saved = try XCTUnwrap(store.snapshot(projectID: project.projectID))
        XCTAssertEqual(saved.surfaceIDs, Set(surfaces))
        guard case .split(let root) = workspace.bonsplitController.treeSnapshot() else {
            return XCTFail("expected canonical leader and agent split")
        }
        XCTAssertEqual(root.dividerPosition, 0.5, accuracy: 0.001)
        guard case .split = root.second else {
            return XCTFail("expected canonical agent subtree")
        }
    }

    func test_hostLayoutSignatureChangesWithRevisionOrSurfaceRoster() {
        var project = Termmesh_Peer_V1_Team()
        project.projectID = "team:hosted"
        project.presentationRevision = 3
        project.leaderSurfaceID = sid(1)
        var member = Termmesh_Peer_V1_TeamMember()
        member.surfaceID = sid(2)
        project.members = [member]
        let original = SessionHostPanes.hostedProjectLayoutSignature(project)

        project.presentationRevision = 4
        XCTAssertNotEqual(SessionHostPanes.hostedProjectLayoutSignature(project), original)
        project.presentationRevision = 3
        project.members[0].surfaceID = sid(3)
        XCTAssertNotEqual(SessionHostPanes.hostedProjectLayoutSignature(project), original)
    }

    func test_hostLayoutFinalizationIdentityChangesWhenWorkspaceIsRecreated() {
        var project = Termmesh_Peer_V1_Team()
        project.projectID = "team:hosted"
        project.presentationRevision = 3
        project.leaderSurfaceID = sid(1)
        let firstWorkspace = UUID()
        let replacementWorkspace = UUID()

        XCTAssertNotEqual(
            SessionHostPanes.hostedProjectLayoutFinalizationID(
                project: project, workspaceID: firstWorkspace
            ),
            SessionHostPanes.hostedProjectLayoutFinalizationID(
                project: project, workspaceID: replacementWorkspace
            ),
            "a replacement workspace must not inherit the old workspace's finalized state"
        )
    }

    func test_sessionHostStartupRetryOutlivesSlowSiblingDaemonStartup() {
        let total = RemoteHostStore.sessionHostStartupRetryDelays.reduce(0.0) { sum, delay in
            sum + Double(delay.components.seconds)
                + Double(delay.components.attoseconds) / 1_000_000_000_000_000_000
        }
        XCTAssertGreaterThanOrEqual(total, 30)
        XCTAssertLessThanOrEqual(total, 46)
    }

    func test_unansweredSessionOwnerRetriesInBackgroundWithoutReclassifyingTheGUI() {
        XCTAssertEqual(
            initialSessionOwnerRoute(
                ownsItsOwnSessions: false, advertisedSocket: ""
            ),
            .discoverInBackground,
            "workspace listing must continue while only the owner route retries"
        )
        XCTAssertEqual(
            initialSessionOwnerRoute(
                ownsItsOwnSessions: false, advertisedSocket: "/tmp/daemon-peer.sock"
            ),
            .resolved("/tmp/daemon-peer.sock")
        )
        XCTAssertEqual(
            initialSessionOwnerRoute(
                ownsItsOwnSessions: true, advertisedSocket: "/ignored.sock"
            ),
            .resolved(""),
            "a daemon serving directly owns its sessions on the current socket"
        )
    }

    func test_projectManifestRoutesEverySurfaceToItsDeclaredProject() {
        var team = Termmesh_Peer_V1_Team()
        team.name = "term-mesh"
        team.projectID = "team:term-mesh"
        team.workingDirectory = "/Users/jinwoo/work/tm-projects/term-mesh"
        team.leaderSurfaceID = sid(1)
        var member = Termmesh_Peer_V1_TeamMember()
        member.name = "executor"
        member.surfaceID = sid(2)
        team.members = [member]

        XCTAssertEqual(
            SessionHostPanes.projectNamesBySurfaceID(teams: [team]),
            [sid(1): "term-mesh", sid(2): "term-mesh"]
        )
        XCTAssertEqual(
            SessionHostPanes.projectClaimsBySurfaceID(teams: [team])[sid(1)]?.workingDirectory,
            "/Users/jinwoo/work/tm-projects/term-mesh"
        )
    }

    func test_workingDirectoryIsKeyedByDurableProjectIDNotDisplayName() {
        var stale = Termmesh_Peer_V1_Team()
        stale.name = "term-mesh"
        stale.projectID = "team:stale"
        stale.workingDirectory = "/tmp/stale"
        var current = stale
        current.projectID = "team:current"
        current.workingDirectory = "/tmp/current"

        current.leaderSurfaceID = sid(9)
        XCTAssertEqual(
            SessionHostPanes.projectClaimsBySurfaceID(
                teams: [stale, current], preferredProjectIDs: ["team:current"]
            )[sid(9)]?.workingDirectory,
            "/tmp/current"
        )
    }

    func test_newestRevisionOwnsTheDirectoryRegardlessOfRosterOrder() {
        var current = Termmesh_Peer_V1_Team()
        current.name = "term-mesh"
        current.projectID = "team:one"
        current.presentationRevision = 9
        current.workingDirectory = "/tmp/current"
        var stale = current
        stale.presentationRevision = 3
        stale.workingDirectory = "/tmp/stale"

        current.leaderSurfaceID = sid(10)
        stale.leaderSurfaceID = sid(10)
        XCTAssertEqual(
            SessionHostPanes.projectClaimsBySurfaceID(teams: [current, stale])[sid(10)]?
                .workingDirectory,
            "/tmp/current"
        )
    }

    func test_supersededViewerClosesWhenSameNamedProjectWinnerChanges() {
        XCTAssertEqual(
            SessionHostPanes.supersededShownSurfaceIDs(
                shown: [sid(1), sid(2), sid(3)],
                suppressed: [sid(1), sid(4)],
                currentlyClaimed: [sid(2), sid(3)]
            ),
            [sid(1)]
        )
    }

    func test_overlappingWinnerSurfaceIsNeverClosedAsSuperseded() {
        XCTAssertTrue(
            SessionHostPanes.supersededShownSurfaceIDs(
                shown: [sid(7)],
                suppressed: [sid(7)],
                currentlyClaimed: [sid(7)]
            ).isEmpty
        )
    }

    func test_incompleteTeamRosterCannotClaimAnUnrelatedSurface() {
        var stale = Termmesh_Peer_V1_Team()
        stale.name = "term-mesh"
        stale.agentNames = ["executor"]

        XCTAssertTrue(SessionHostPanes.projectNamesBySurfaceID(teams: [stale]).isEmpty)
    }

    func test_newerPresentationWinsWhenStaleManifestReferencesSameSurface() {
        let surface = sid(7)
        var stale = Termmesh_Peer_V1_Team()
        stale.name = "term-mesh"
        stale.projectID = "team:old"
        stale.presentationRevision = 2
        stale.leaderSurfaceID = surface
        var current = stale
        current.projectID = "team:current"
        current.presentationRevision = 6

        XCTAssertEqual(
            SessionHostPanes.projectClaimsBySurfaceID(teams: [stale, current])[surface],
            .init(
                projectID: "team:current", name: "term-mesh",
                revision: 6, ownedByRequester: false
            )
        )
    }

    func test_activeLocalProjectWinsOverNewerStalePresentation() {
        let surface = sid(8)
        var active = Termmesh_Peer_V1_Team()
        active.name = "term-mesh"
        active.projectID = "team:active"
        active.presentationRevision = 5
        active.leaderSurfaceID = surface
        var stale = active
        stale.projectID = "team:stale"
        stale.presentationRevision = 6

        XCTAssertEqual(
            SessionHostPanes.projectClaimsBySurfaceID(
                teams: [active, stale],
                preferredProjectIDs: ["team:active"]
            )[surface],
            .init(
                projectID: "team:active", name: "term-mesh",
                revision: 5, ownedByRequester: false
            )
        )
        XCTAssertFalse(
            SessionHostPanes.projectRoutingSnapshot(
                teams: [active, stale],
                preferredProjectIDs: ["team:active"]
            ).suppressedSurfaceIDs.contains(surface)
        )
    }

    func test_staleSameNamedProjectSurfacesAreSuppressedFromAutoOpen() {
        var active = Termmesh_Peer_V1_Team()
        active.name = "term-mesh"
        active.projectID = "team:active"
        active.presentationRevision = 5
        active.leaderSurfaceID = sid(1)
        var stale = active
        stale.projectID = "team:stale"
        stale.presentationRevision = 9
        stale.leaderSurfaceID = sid(2)
        var staleMember = Termmesh_Peer_V1_TeamMember()
        staleMember.surfaceID = sid(3)
        stale.members = [staleMember]

        let routing = SessionHostPanes.projectRoutingSnapshot(
            teams: [active, stale],
            preferredProjectIDs: ["team:active"]
        )
        XCTAssertEqual(routing.claims[sid(1)]?.projectID, "team:active")
        XCTAssertNil(routing.claims[sid(2)])
        XCTAssertEqual(routing.suppressedSurfaceIDs, [sid(2), sid(3)])
    }

    func test_twoExplicitSameNamedProjectIDsBothRemainRoutable() {
        var first = Termmesh_Peer_V1_Team()
        first.name = "term-mesh"
        first.projectID = "team:first"
        first.presentationRevision = 3
        first.leaderSurfaceID = sid(31)
        var second = first
        second.projectID = "team:second"
        second.presentationRevision = 8
        second.leaderSurfaceID = sid(32)

        let routing = SessionHostPanes.projectRoutingSnapshot(
            teams: [first, second],
            preferredProjectIDs: ["team:first", "team:second"]
        )

        XCTAssertEqual(routing.claims[sid(31)]?.projectID, "team:first")
        XCTAssertEqual(routing.claims[sid(32)]?.projectID, "team:second")
        XCTAssertTrue(routing.suppressedSurfaceIDs.isEmpty)
    }

    func test_requesterOwnedPresentationWinsOverNewerForeignRecord() {
        let surface = sid(9)
        var owned = Termmesh_Peer_V1_Team()
        owned.name = "term-mesh"
        owned.projectID = "team:owned"
        owned.presentationRevision = 3
        owned.presentationOwnedByRequester = true
        owned.leaderSurfaceID = surface
        var foreign = owned
        foreign.projectID = "team:foreign"
        foreign.presentationRevision = 99
        foreign.presentationOwnedByRequester = false

        XCTAssertEqual(
            SessionHostPanes.projectRoutingSnapshot(teams: [owned, foreign]).claims[surface],
            .init(
                projectID: "team:owned", name: "term-mesh",
                revision: 3, ownedByRequester: true
            )
        )
    }

    func test_differentNamedProjectsRemainAutoOpenCandidates() {
        var active = Termmesh_Peer_V1_Team()
        active.name = "term-mesh"
        active.projectID = "team:active"
        active.leaderSurfaceID = sid(1)
        var other = active
        other.name = "xm"
        other.projectID = "team:xm"
        other.leaderSurfaceID = sid(2)

        let routing = SessionHostPanes.projectRoutingSnapshot(
            teams: [active, other],
            preferredProjectIDs: ["team:active"]
        )
        XCTAssertEqual(routing.claims[sid(2)]?.projectID, "team:xm")
        XCTAssertTrue(routing.suppressedSurfaceIDs.isEmpty)
    }

    func test_ambiguousForeignSameNamedProjectsAreAllSuppressed() {
        var first = Termmesh_Peer_V1_Team()
        first.name = "term-mesh"
        first.projectID = "team:first"
        first.leaderSurfaceID = sid(1)
        var second = first
        second.projectID = "team:second"
        second.leaderSurfaceID = sid(2)

        let routing = SessionHostPanes.projectRoutingSnapshot(teams: [first, second])
        XCTAssertTrue(routing.claims.isEmpty)
        XCTAssertEqual(routing.suppressedSurfaceIDs, [sid(1), sid(2)])
    }

    func test_legacySameNamedProjectsAreSuppressedWithoutIdentityEvidence() {
        var stale = Termmesh_Peer_V1_Team()
        stale.name = "term-mesh"
        stale.projectID = "team:stale"
        stale.leaderSurfaceID = sid(1)
        var current = stale
        current.projectID = "team:current"
        current.leaderSurfaceID = sid(2)
        var member = Termmesh_Peer_V1_TeamMember()
        member.surfaceID = sid(3)
        current.members = [member]

        let routing = SessionHostPanes.projectRoutingSnapshot(teams: [stale, current])
        XCTAssertTrue(routing.claims.isEmpty)
        XCTAssertEqual(routing.suppressedSurfaceIDs, [sid(1), sid(2), sid(3)])
    }

    func test_newForeignProjectBeatsOlderFullerSameNamedProject() {
        var old = Termmesh_Peer_V1_Team()
        old.name = "term-mesh"
        old.projectID = "team:old"
        old.createdAtUnixSecs = 100
        old.leaderSurfaceID = sid(1)
        old.members = (2...6).map { value in
            var member = Termmesh_Peer_V1_TeamMember()
            member.surfaceID = sid(UInt8(value))
            return member
        }
        var current = Termmesh_Peer_V1_Team()
        current.name = "term-mesh"
        current.projectID = "team:current"
        current.createdAtUnixSecs = 200
        current.leaderSurfaceID = sid(9)
        var executor = Termmesh_Peer_V1_TeamMember()
        executor.surfaceID = sid(10)
        current.members = [executor]

        let routing = SessionHostPanes.projectRoutingSnapshot(teams: [old, current])
        XCTAssertEqual(routing.claims[sid(9)]?.projectID, "team:current")
        XCTAssertEqual(routing.claims[sid(10)]?.projectID, "team:current")
        XCTAssertTrue(routing.claims[sid(1)] == nil)
        XCTAssertEqual(routing.suppressedSurfaceIDs, Set((1...6).map { sid(UInt8($0)) }))
    }

    func test_unclaimedDaemonShellsAreNotProjectAutoOpenCandidates() {
        var claimed = Termmesh_Peer_V1_SurfaceInfo()
        claimed.surfaceID = sid(1)
        var unclaimed = Termmesh_Peer_V1_SurfaceInfo()
        unclaimed.surfaceID = sid(2)
        let claims: [Data: SessionHostPanes.ProjectClaim] = [
            claimed.surfaceID: .init(
                projectID: "team:active", name: "term-mesh",
                revision: 1, ownedByRequester: true
            )
        ]
        XCTAssertEqual(
            SessionHostPanes.projectSurfacesForAutoOpen(
                surfaces: [claimed, unclaimed],
                claims: claims,
                suppressedSurfaceIDs: []
            ).map(\.surfaceID),
            [claimed.surfaceID]
        )
    }

    func test_sameNamedDurableProjectsRouteToDifferentWorkspaces() {
        let first = UUID()
        let second = UUID()
        let declared = [
            SessionHostPanes.DeclaredProjectClaim(
                id: first, name: "term-mesh", projectID: "team:first"
            ),
            SessionHostPanes.DeclaredProjectClaim(
                id: second, name: "term-mesh", projectID: "team:second"
            ),
        ]

        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: "term-mesh",
                projectID: "team:first",
                declaredProjects: declared,
                hostSessionsWorkspaceID: nil
            ),
            .existingProject(first)
        )
        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: "term-mesh",
                projectID: "team:third",
                declaredProjects: declared,
                hostSessionsWorkspaceID: nil
            ),
            .newProject("term-mesh")
        )
    }

    func test_uniqueLegacyWorkspaceIsUpgradedToDurableProject() {
        let legacy = UUID()
        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: "term-mesh",
                projectID: "team:active",
                declaredProjects: [
                    .init(id: legacy, name: "term-mesh", projectID: nil)
                ],
                hostSessionsWorkspaceID: nil
            ),
            .existingProject(legacy)
        )
    }

    func test_ambiguousLegacyWorkspacesAreNeverGuessed() {
        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: "term-mesh",
                projectID: "team:active",
                declaredProjects: [
                    .init(id: UUID(), name: "term-mesh", projectID: nil),
                    .init(id: UUID(), name: "term-mesh", projectID: nil),
                ],
                hostSessionsWorkspaceID: nil
            ),
            .newProject("term-mesh")
        )
    }

    func test_sessionPlacementNeverFallsBackToTheSelectedUnrelatedWorkspace() {
        let xm = UUID()
        let termMesh = UUID()
        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: "term-mesh",
                declaredProjects: [(xm, "xm"), (termMesh, "term-mesh")],
                hostSessionsWorkspaceID: nil
            ),
            .existingProject(termMesh)
        )
        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: "term-mesh",
                declaredProjects: [(xm, "xm")],
                hostSessionsWorkspaceID: nil
            ),
            .newProject("term-mesh")
        )
    }

    func test_unclaimedDaemonSessionUsesDedicatedHostSessionsWorkspace() {
        let xm = UUID()
        let hostSessions = UUID()
        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: nil,
                declaredProjects: [(xm, "xm")],
                hostSessionsWorkspaceID: hostSessions
            ),
            .existingHostSessions(hostSessions)
        )
    }

    func test_teamHostSnapshotAcceptsOnlyTheCurrentRouteAndServingGeneration() {
        let ownerA = PeerPaneHostKey.ssh(
            target: "host", remoteSockPath: "/owner-a.sock", port: nil
        )
        let ownerB = PeerPaneHostKey.ssh(
            target: "host", remoteSockPath: "/owner-b.sock", port: nil
        )
        let pending = TeamHostReadiness.probing(ownerB)
        let stale = TeamHostCapabilitySnapshot(
            endpoint: ownerA, appVersion: "0.193.0",
            supportsPeerOwnedAgentHosting: true, supportsRemoteTeamRoute: true,
            looksLikeGUIPeerHost: false, redirectedFromServingEndpoint: true
        )
        XCTAssertEqual(acceptingTeamHostSnapshot(
            current: pending, expectedEndpoint: ownerB,
            servingPathMatches: true, snapshot: stale
        ), pending)

        let current = TeamHostCapabilitySnapshot(
            endpoint: ownerB, appVersion: "0.200.0",
            supportsPeerOwnedAgentHosting: true, supportsRemoteTeamRoute: true,
            looksLikeGUIPeerHost: false, redirectedFromServingEndpoint: true
        )
        XCTAssertEqual(acceptingTeamHostSnapshot(
            current: pending, expectedEndpoint: ownerB,
            servingPathMatches: false, snapshot: current
        ), pending, "a retired serving tunnel cannot publish metadata")
        XCTAssertEqual(acceptingTeamHostSnapshot(
            current: pending, expectedEndpoint: ownerB,
            servingPathMatches: true, snapshot: current
        ), .ready(current))
    }

    private func sid(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

    // MARK: - Project identity across a relaunch

    /// Sessions written before workspace IDs were persisted mint a fresh UUID
    /// for every restored workspace, so the UUID-keyed declaration cannot
    /// match. Reading the declaration alone therefore answered "no workspace
    /// owns this project" on every launch, and every launch created one more
    /// `[project]` workspace for the same project — 3 more per restart on a
    /// host with 3 teams.
    func test_aRestoredProjectWorkspaceIsRecognizedFromItsTitle() {
        let workspace = Workspace(title: "Terminal", workingDirectory: "/tmp")
        workspace.customTitle = "[term-mesh]"
        defer { WorkspaceProjectNames.shared.forget(workspaceId: workspace.id) }

        XCTAssertNil(
            WorkspaceProjectNames.shared.projectName(for: workspace.id),
            "a restored workspace starts with no declaration"
        )
        XCTAssertEqual(SessionHostPanes.declaredProjectName(for: workspace), "term-mesh")
    }

    /// The title is a fallback, not the source of truth: a workspace the user
    /// happened to name `[something]` must not outrank its own declaration.
    func test_anExplicitDeclarationOutranksTheTitle() {
        let workspace = Workspace(title: "Terminal", workingDirectory: "/tmp")
        workspace.customTitle = "[term-mesh]"
        defer { WorkspaceProjectNames.shared.forget(workspaceId: workspace.id) }
        WorkspaceProjectNames.shared.declare(workspaceId: workspace.id, projectName: "xm")

        XCTAssertEqual(SessionHostPanes.declaredProjectName(for: workspace), "xm")
    }

    func test_anOrdinaryTitleClaimsNoProject() {
        let titles: [String?] = [nil, "", "Terminal 1", "[]", "[ ]", "[unclosed", "unopened]"]
        for title in titles {
            XCTAssertNil(
                SessionHostPanes.projectName(fromWorkspaceTitle: title),
                "\(title ?? "<nil>") is not a project title"
            )
        }
        XCTAssertEqual(
            SessionHostPanes.projectName(fromWorkspaceTitle: "[h2-verify-fda00162]"),
            "h2-verify-fda00162"
        )
    }

    /// `TeamOrchestrator` titles a team workspace `[project] 3 headless`.
    /// Requiring the title to end in `]` left a resumed headless team
    /// unrecognized, so it kept getting a second workspace.
    func test_aTrailingCountStillNamesTheProject() {
        XCTAssertEqual(
            SessionHostPanes.projectName(fromWorkspaceTitle: "[term-mesh] 3 headless"),
            "term-mesh"
        )
        XCTAssertEqual(
            SessionHostPanes.projectName(fromWorkspaceTitle: "[term-mesh]"),
            "term-mesh"
        )
    }

    /// The title is a fallback for reading, never a claim worth keeping. The app
    /// itself titles a worktree workspace `[<branch>]` and a socket rename can
    /// produce any bracketed title, so persisting the recovery would let a
    /// presentation string permanently outrank `SidebarViews`' path inference
    /// with no way to revoke it short of closing the workspace.
    func test_theTitleFallbackNeverWritesADeclaration() {
        let workspace = Workspace(title: "Terminal", workingDirectory: "/tmp")
        workspace.customTitle = "[feat/some-branch]"
        defer { WorkspaceProjectNames.shared.forget(workspaceId: workspace.id) }

        XCTAssertEqual(
            SessionHostPanes.declaredProjectName(for: workspace), "feat/some-branch"
        )
        XCTAssertNil(
            WorkspaceProjectNames.shared.projectName(for: workspace.id),
            "reading a title must not declare the workspace"
        )
    }

    /// The invariant the whole change exists for, asserted end to end through
    /// the expression the routing actually evaluates: restored project
    /// workspaces carry no declaration, and must still resolve to themselves
    /// rather than to one more new workspace.
    func test_restoredProjectWorkspacesRouteToThemselvesNotToNewOnes() {
        let restored = Workspace(title: "Terminal", workingDirectory: "/tmp")
        restored.customTitle = "[term-mesh]"
        let unrelated = Workspace(title: "Terminal", workingDirectory: "/tmp")
        defer {
            WorkspaceProjectNames.shared.forget(workspaceId: restored.id)
            WorkspaceProjectNames.shared.forget(workspaceId: unrelated.id)
        }

        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: "term-mesh",
                declaredProjects: SessionHostPanes.declaredProjects(
                    in: [restored, unrelated]
                ),
                hostSessionsWorkspaceID: nil
            ),
            .existingProject(restored.id),
            "a second [term-mesh] workspace per launch is exactly the bug"
        )
    }

    /// A bracketed title is only a recovery hint. A worktree named like a
    /// project must not steal routing from that project's durable declaration,
    /// even when the worktree appears first in tab/window order.
    func test_anExplicitProjectOutranksAMatchingTitleAcrossWorkspaces() {
        let worktree = Workspace(title: "Terminal", workingDirectory: "/tmp/worktree")
        worktree.customTitle = "[term-mesh]"
        let project = Workspace(title: "Terminal", workingDirectory: "/tmp/project")
        project.customTitle = "[term-mesh]"
        defer {
            WorkspaceProjectNames.shared.forget(workspaceId: worktree.id)
            WorkspaceProjectNames.shared.forget(workspaceId: project.id)
        }
        WorkspaceProjectNames.shared.declare(
            workspaceId: project.id, projectName: "term-mesh"
        )

        XCTAssertEqual(
            SessionHostPanes.workspaceDestination(
                projectName: "term-mesh",
                declaredProjects: SessionHostPanes.declaredProjects(
                    in: [worktree, project]
                ),
                hostSessionsWorkspaceID: nil
            ),
            .existingProject(project.id)
        )
    }

    // MARK: - Which sessions get a pane

    /// Everything the daemon holds deserves a window here: it owns it, so it
    /// outlives this app, which is exactly what has nowhere else to be seen.
    func test_everyHeldSessionWithoutAPaneGetsOne() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [
                (sid(1), true, "terminal"), (sid(2), true, "terminal"), (sid(3), true, "terminal"),
            ],
            alreadyShown: []
        )
        XCTAssertEqual(wanted.terminal, [sid(1), sid(2), sid(3)])
        XCTAssertTrue(wanted.agent.isEmpty)
    }

    /// Idempotent by the *peer's* surface id. The local panel id is minted per
    /// attach, so comparing those would open a second pane for one session
    /// every time this runs.
    func test_aSessionAlreadyOnScreenIsNotOpenedTwice() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [(sid(1), true, "terminal"), (sid(2), true, "terminal")],
            alreadyShown: [sid(1)]
        )
        XCTAssertEqual(wanted.terminal, [sid(2)])
    }

    /// Attaching to an unattachable surface fails at the far end, and a
    /// failure per pass is a log full of one line.
    func test_anUnattachableSessionIsSkippedRatherThanAttempted() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [(sid(1), false, "terminal"), (sid(2), true, "terminal")],
            alreadyShown: []
        )
        XCTAssertEqual(wanted.terminal, [sid(2)])
    }

    func test_nothingHeldMeansNothingToOpen() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [], alreadyShown: [sid(1)]
        )
        XCTAssertTrue(wanted.terminal.isEmpty)
        XCTAssertTrue(wanted.agent.isEmpty)
    }

    // MARK: - Which renderer a session gets

    /// An agent surface opened as a terminal would spawn the relay helper
    /// into a pane and render raw NDJSON as if it were a shell — it must
    /// leave the terminal list entirely, and it must land in the agent
    /// list rather than being dropped: the daemon holding it is still the
    /// reason to show it.
    func test_anAgentSurfaceLeavesTheTerminalListAndLandsInTheAgentList() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [
                (sid(1), true, "terminal"),
                (sid(2), true, "agent"),
                (sid(3), true, "terminal"),
            ],
            alreadyShown: []
        )
        XCTAssertEqual(wanted.terminal, [sid(1), sid(3)])
        XCTAssertEqual(wanted.agent, [sid(2)])
    }

    /// The shown/attachable filters exist for the same reasons on both
    /// kinds: an agent pane already on screen must not be duplicated, and
    /// an unattachable agent surface fails at the far end just like a
    /// terminal one.
    func test_agentRoutingHonorsTheShownAndAttachableFilters() {
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [
                (sid(1), true, "agent"),
                (sid(2), false, "agent"),
                (sid(3), true, "agent"),
            ],
            alreadyShown: [sid(1)]
        )
        XCTAssertTrue(wanted.terminal.isEmpty)
        XCTAssertEqual(wanted.agent, [sid(3)])
    }

    /// Every pre-agent daemon sends "terminal" or nothing at all, and every
    /// unknown future type has always been opened as a terminal — only the
    /// exact string the daemon writes routes to an AgentPanel.
    func test_onlyTheExactAgentTypeStringRoutesToAgentPanes() {
        XCTAssertTrue(SessionHostPanes.isAgentSurfaceType("agent"))
        XCTAssertFalse(SessionHostPanes.isAgentSurfaceType("Agent"))
        XCTAssertFalse(SessionHostPanes.isAgentSurfaceType("terminal"))
        XCTAssertFalse(SessionHostPanes.isAgentSurfaceType(""))

        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [(sid(1), true, ""), (sid(2), true, "browser")],
            alreadyShown: []
        )
        XCTAssertEqual(wanted.terminal, [sid(1), sid(2)])
        XCTAssertTrue(wanted.agent.isEmpty)
    }

    // MARK: - Where "already shown" comes from

    /// The shown set is read off the panes, not remembered.
    ///
    /// It used to be a `Set` this type maintained, and each way it could drift
    /// from the screen was its own bug: closing an auto-opened pane left the id
    /// marked forever, because nothing ever called the release, so that session
    /// could never come back. A brief loss of the daemon cleared the whole set
    /// while the panes were still up, so the next pass opened a duplicate for
    /// every one. With no window at all there is nothing on screen, and the
    /// honest answer is the empty set rather than a remembered one.
    func test_nothingIsShownWhenThereIsNoWindow() {
        XCTAssertTrue(SessionHostPanes.shownSurfaceIDs().isEmpty)
    }

    /// Whatever the screen says, feeding it back in is what makes a second pass
    /// a no-op — the property the removed bookkeeping was there to provide.
    func test_whatIsOnScreenIsNotOpenedAgain() {
        let onScreen = SessionHostPanes.shownSurfaceIDs().union([sid(7)])
        XCTAssertEqual(
            SessionHostPanes.sessionsNeedingPanes(
                daemonSurfaces: [(sid(7), true, "terminal"), (sid(8), true, "terminal")],
                alreadyShown: onScreen
            ).terminal,
            [sid(8)]
        )
    }

    // MARK: - A closed pane stays closed

    /// Reading "already shown" off the screen is also what undoes a close: the
    /// daemon still holds the session, so the next pass finds it missing and
    /// opens it again. Measured on a live app before this existed — a pane
    /// closed at 23:02:15 was back at 23:02:25.
    func test_aClosedPaneIsNotReopenedByTheNextPass() {
        SessionHostPanes.forgetDismissalsForTests()
        defer { SessionHostPanes.forgetDismissalsForTests() }

        SessionHostPanes.noteClosedByUser(surfaceID: sid(4))
        XCTAssertEqual(
            SessionHostPanes.sessionsNeedingPanes(
                daemonSurfaces: [(sid(4), true, "terminal"), (sid(5), true, "terminal")],
                alreadyShown: SessionHostPanes.dismissedSurfaceIDsForTests
            ).terminal,
            [sid(5)]
        )
    }

    /// A dismissed agent pane stays closed through the same funnel — the
    /// panels-map reconciler records the dismissal, and this filter is
    /// where it takes effect.
    func test_aClosedAgentPaneIsNotReopenedByTheNextPass() {
        SessionHostPanes.forgetDismissalsForTests()
        defer { SessionHostPanes.forgetDismissalsForTests() }

        SessionHostPanes.noteClosedByUser(surfaceID: sid(4))
        let wanted = SessionHostPanes.sessionsNeedingPanes(
            daemonSurfaces: [(sid(4), true, "agent"), (sid(5), true, "agent")],
            alreadyShown: SessionHostPanes.dismissedSurfaceIDsForTests
        )
        XCTAssertEqual(wanted.agent, [sid(5)])
        XCTAssertTrue(wanted.terminal.isEmpty)
    }

    /// A dismissal is safe to remember where the old "shown" bookkeeping was
    /// not, because a close is its own owner — but only if the set cannot grow
    /// for the life of the process.
    func test_dismissalsAreDroppedOnceTheSessionIsGone() {
        SessionHostPanes.forgetDismissalsForTests()
        defer { SessionHostPanes.forgetDismissalsForTests() }

        SessionHostPanes.noteClosedByUser(surfaceID: sid(4))
        SessionHostPanes.noteClosedByUser(surfaceID: sid(5))
        XCTAssertEqual(SessionHostPanes.dismissedSurfaceIDsForTests.count, 2)

        SessionHostPanes.pruneDismissalsForTests(stillHeld: [sid(5)])
        XCTAssertEqual(SessionHostPanes.dismissedSurfaceIDsForTests, [sid(5)])
    }

    /// Panes that were never a session get no entry — a remote pane on another
    /// machine closes through the same funnel.
    func test_aPaneWithNoSurfaceIdIsNotRecorded() {
        SessionHostPanes.forgetDismissalsForTests()
        defer { SessionHostPanes.forgetDismissalsForTests() }

        SessionHostPanes.noteClosedByUser(surfaceID: Data())
        XCTAssertTrue(SessionHostPanes.dismissedSurfaceIDsForTests.isEmpty)
    }

    // MARK: - Agent-pane reopen governor (repair D)

    /// A rewind is one or two drops and must come back at once; a host
    /// that disconnects every fresh attach must not spin destroy/recreate
    /// as fast as the reconcile kicks land. Past the burst the kick is
    /// withheld and the reopen falls back to the poller's cadence.
    func test_aDropBurstDemotesTheReopenToPollerCadence() {
        SessionHostPanes.forgetAgentPaneDropsForTests()
        defer { SessionHostPanes.forgetAgentPaneDropsForTests() }

        let t0 = Date()
        for n in 0..<SessionHostPanes.agentReopenBurstLimit {
            XCTAssertTrue(
                SessionHostPanes.noteAgentPaneDropped(
                    surfaceID: sid(7), now: t0.addingTimeInterval(Double(n))
                ),
                "drop #\(n + 1) is still within the allowed burst"
            )
        }
        XCTAssertFalse(
            SessionHostPanes.noteAgentPaneDropped(
                surfaceID: sid(7),
                now: t0.addingTimeInterval(Double(SessionHostPanes.agentReopenBurstLimit))
            ),
            "one past the burst must be demoted"
        )
    }

    /// The demotion is per surface and per window: an unrelated surface
    /// keeps its immediate kick, and once the window has passed the same
    /// surface earns it back — the failure was then, not now.
    func test_theDemotionIsScopedToTheSurfaceAndTheWindow() {
        SessionHostPanes.forgetAgentPaneDropsForTests()
        defer { SessionHostPanes.forgetAgentPaneDropsForTests() }

        let t0 = Date()
        for n in 0...SessionHostPanes.agentReopenBurstLimit {
            _ = SessionHostPanes.noteAgentPaneDropped(
                surfaceID: sid(7), now: t0.addingTimeInterval(Double(n))
            )
        }
        XCTAssertTrue(
            SessionHostPanes.noteAgentPaneDropped(surfaceID: sid(8), now: t0),
            "another surface's first drop is not this surface's burst"
        )
        XCTAssertTrue(
            SessionHostPanes.noteAgentPaneDropped(
                surfaceID: sid(7),
                now: t0.addingTimeInterval(
                    SessionHostPanes.agentReopenWindow
                        + Double(SessionHostPanes.agentReopenBurstLimit) + 1
                )
            ),
            "a drop after the window has cleared starts a fresh burst"
        )
    }

    // MARK: - Whether to look at all

    /// Empty is a host saying it has no owner. Polling one is asking a
    /// question already answered.
    func test_aMachineWithNoSessionHostIsNotPolled() {
        XCTAssertFalse(SessionHostPanes.hasSessionHost(socketPath: ""))
    }

    /// A relative path would resolve against whatever directory this process
    /// happens to be in, which is not where the socket is.
    func test_aRelativePathIsNotASessionHost() {
        XCTAssertFalse(SessionHostPanes.hasSessionHost(socketPath: "term-meshd-peer.sock"))
        XCTAssertTrue(SessionHostPanes.hasSessionHost(socketPath: "/tmp/term-meshd-peer.sock"))
    }
}

extension SessionHostPanesTests {
    /// The app starts its daemon and its own peer server at about the same
    /// moment, and the daemon binds a little after being spawned. One attempt
    /// at server-start found nothing and returned silently, so sessions that
    /// had outlived the app stayed invisible until something asked again --
    /// and nothing did. Panes restored from the previous run made that look
    /// like it had worked.
    func test_startupWaitsLongEnoughForADaemonToBind() {
        let window = SessionHostPanes.startupSettleWindow
        XCTAssertGreaterThanOrEqual(
            window, .seconds(3),
            "a shorter window is the single-attempt bug with extra steps"
        )
        XCTAssertLessThanOrEqual(
            window, .seconds(30),
            "a machine with no daemon serving is ordinary, not something to wait on"
        )
    }

    /// The last attempt does not sleep after itself, so `attempts × interval`
    /// overstates the wait by one interval. Asserting the overstated number
    /// would let the real window shrink below the floor above without any test
    /// noticing.
    func test_theStatedWindowIsTheOneActuallyWaited() {
        XCTAssertEqual(
            SessionHostPanes.startupSettleWindow,
            SessionHostPanes.startupSettleInterval * (SessionHostPanes.startupSettleAttempts - 1)
        )
    }

    /// Sessions appear after startup — a peer-placed project creates one
    /// minutes or hours in — so a single pass at server-start covered the case
    /// this type exists for worst of all. Slow on purpose: a pass walks the
    /// window list and opens a connection.
    func test_itKeepsLookingAfterStartupRatherThanAskingOnce() {
        XCTAssertGreaterThanOrEqual(
            SessionHostPanes.pollInterval, .seconds(5),
            "a pass is not free; noticing a minutes-old session within a second buys nothing"
        )
        XCTAssertLessThanOrEqual(
            SessionHostPanes.pollInterval, .seconds(60),
            "longer than this and a session created now feels like it was dropped"
        )
    }

    func test_autoOpenPinOutlivesTheRelayAcceptWindowButStaysBounded() {
        XCTAssertGreaterThan(
            SessionHostPanes.autoOpenRealizationPinDuration,
            .seconds(10)
        )
        XCTAssertLessThanOrEqual(
            SessionHostPanes.autoOpenRealizationPinDuration,
            SessionHostPanes.pollInterval
        )
    }
}

/// The UI-independent decisions behind `Workspace.openRemoteAgentPane`:
/// what the pane is called and whether it offers a stop button. The pane
/// construction itself needs a live Bonsplit tree and a handshaken peer
/// session, so those paths are exercised by the routing tests above plus
/// the pure pieces here rather than by instantiating a workspace.
@MainActor
final class RemoteAgentPaneRoutingTests: XCTestCase {

    /// Five identical roles on five machines must stay tellable apart —
    /// the host rides in the title the same way the team path's
    /// "<name> @<host>" panes do.
    func test_paneTitleShowsRoleAndHost() {
        XCTAssertEqual(
            Workspace.remoteAgentPaneTitle(
                surfaceTitle: "reviewer", agentCli: "codex", hostLabel: "jw-server"
            ),
            "reviewer @jw-server"
        )
        XCTAssertEqual(
            Workspace.remoteAgentPaneTitle(
                surfaceTitle: "", agentCli: "codex", hostLabel: "jw-server"
            ),
            "codex @jw-server",
            "an untitled surface is named by its CLI, not left blank"
        )
        XCTAssertEqual(
            Workspace.remoteAgentPaneTitle(
                surfaceTitle: "reviewer", agentCli: "codex", hostLabel: ""
            ),
            "reviewer",
            "no host label, no dangling separator"
        )
    }

    /// Only claude is measured to take `control_request`/`interrupt` on
    /// its NDJSON stdin; a stop button on a bridged CLI would do nothing.
    func test_onlyClaudeOffersInterrupt() {
        XCTAssertTrue(Workspace.remoteAgentInterruptible(agentCli: "claude"))
        XCTAssertFalse(Workspace.remoteAgentInterruptible(agentCli: "codex"))
        XCTAssertFalse(Workspace.remoteAgentInterruptible(agentCli: "kiro"))
        XCTAssertFalse(Workspace.remoteAgentInterruptible(agentCli: ""))
    }
}

/// The viewer-side half of the `surface.agent.v1` gate. The daemon holds
/// the other half (listing demotion + attach rejection for clients that
/// did not advertise it); this half keeps the viewer from issuing the
/// agent path — attach or `EnsureSurfaceRequest.kind = "agent"` — against
/// a host whose Hello never advertised the capability at all.
final class RemoteHostAgentSurfaceGateTests: XCTestCase {

    func test_sessionOwnerConnectionDoesNotReplaceServingSocket() {
        XCTAssertTrue(
            RemoteHostStore.isAuxiliarySessionOwnerConnection(
                servingRemoteSocket: "/tmp/term-mesh-peer-501/peer.sock",
                sessionOwnerRemoteSocket: "/private/var/folders/x/T/term-meshd-peer.sock",
                configuredRemoteSocket: nil,
                incomingRemoteSocket: "/private/var/folders/x/T/term-meshd-peer.sock"
            )
        )
    }

    func test_sameSocketSpellingIsNotMisclassifiedAsSessionOwner() {
        XCTAssertFalse(
            RemoteHostStore.isAuxiliarySessionOwnerConnection(
                servingRemoteSocket: "/tmp/peer/../peer/peer.sock",
                sessionOwnerRemoteSocket: "/tmp/session-owner.sock",
                configuredRemoteSocket: nil,
                incomingRemoteSocket: "/tmp/peer/peer.sock"
            )
        )
    }

    func test_autoDetectedServingSocketCanMoveWithoutFirstConnectionWinningForever() {
        XCTAssertFalse(
            RemoteHostStore.isAuxiliarySessionOwnerConnection(
                servingRemoteSocket: "/tmp/old-serving.sock",
                sessionOwnerRemoteSocket: nil,
                configuredRemoteSocket: nil,
                incomingRemoteSocket: "/tmp/new-serving.sock"
            )
        )
    }

    func test_explicitProfileSocketRejectsAStaleDifferentConnection() {
        XCTAssertTrue(
            RemoteHostStore.isAuxiliarySessionOwnerConnection(
                servingRemoteSocket: "/tmp/configured-serving.sock",
                sessionOwnerRemoteSocket: nil,
                configuredRemoteSocket: "/tmp/configured-serving.sock",
                incomingRemoteSocket: "/tmp/stale-serving.sock"
            )
        )
    }

    /// A host that never advertised `surface.agent.v1` is an older daemon:
    /// the agent path must not be issued against it, and the terminal path
    /// stays exactly as it was.
    func test_aHostWithoutTheCapabilityDoesNotGetTheAgentPath() {
        XCTAssertFalse(RemoteHostStore.hostSupportsAgentSurfaces(PeerCapabilities()))
        XCTAssertFalse(
            RemoteHostStore.hostSupportsAgentSurfaces(
                PeerCapabilities([
                    PeerCapability.surfaceEnsureV1, PeerCapability.workspaceLifecycleV1,
                ])
            ),
            "other capabilities do not imply agent surfaces"
        )
    }

    func test_anAdvertisingHostPassesTheGate() {
        XCTAssertTrue(
            RemoteHostStore.hostSupportsAgentSurfaces(
                PeerCapabilities([PeerCapability.surfaceAgentV1])
            )
        )
        XCTAssertTrue(
            RemoteHostStore.hostSupportsAgentSurfaces(PeerCapabilities(PeerCapability.supported)),
            "this build's own advertised capability set passes its own gate"
        )
    }

    func test_peerOwnedFactoryRequiresAgentExitAndEnsureEnvironmentCapabilities() {
        let required = [
            PeerCapability.surfaceAgentV1,
            PeerCapability.surfaceExitV1,
            PeerCapability.surfaceEnsureEnvV1,
            PeerCapability.teamRouteFileV1,
        ]
        for missing in required {
            XCTAssertFalse(RemoteHostStore.hostSupportsPeerOwnedAgentFactory(
                PeerCapabilities(required.filter { $0 != missing })
            ), "missing \(missing)")
        }
        XCTAssertTrue(RemoteHostStore.hostSupportsPeerOwnedAgentFactory(
            PeerCapabilities(required)
        ))
    }

    func test_teamHostSnapshotSeparatelyPinsAuthoritativeLeaderLiveness() {
        let endpoint = PeerPaneHostKey.direct(sockPath: "/tmp/peer.sock")
        let without = RemoteHostStore.teamHostCapabilitySnapshot(
            endpoint: endpoint,
            capabilities: PeerCapabilities([PeerCapability.teamLeaderV1]),
            appVersion: "0.209.0",
            redirectedFromServingEndpoint: false
        )
        XCTAssertFalse(without.supportsAuthoritativeLeaderLiveness)

        let candidate = RemoteHostStore.teamHostCapabilitySnapshot(
            endpoint: endpoint,
            capabilities: PeerCapabilities([
                PeerCapability.teamLeaderV1, PeerCapability.surfaceForegroundV1,
            ]),
            appVersion: "0.213.0",
            redirectedFromServingEndpoint: false
        )
        XCTAssertTrue(candidate.supportsAuthoritativeLeaderLiveness)
    }

    // MARK: - Session-host redirect

    /// The exact set a Swift GUI peer host advertises: everything this build
    /// supports, minus the two `PeerServer` strips. If that filter ever
    /// changes, this is what should fail — the discriminator below is derived
    /// from it, not guessed alongside it.
    private static var guiHostCapabilities: PeerCapabilities {
        PeerCapabilities(PeerCapability.supported.filter {
            $0 != PeerCapability.surfaceAgentV1
                && $0 != PeerCapability.projectPresentationV1
        })
    }

    @MainActor
    func test_guiPeerHostIsDistinguishedFromADaemonPredatingAgentSurfaces() {
        XCTAssertTrue(
            TeamOrchestrator.looksLikeGUIPeerHost(Self.guiHostCapabilities),
            "a GUI host keeps the ensure-env/exit halves and drops only agent + presentation"
        )
        // A daemon old enough to predate peer-owned agents is missing the
        // whole group. Calling that a GUI host would tell its user to start a
        // daemon that is already running.
        let oldDaemon = PeerCapabilities([
            PeerCapability.ptyDataCoalesceV1,
            PeerCapability.replayRingV1,
            PeerCapability.surfaceEnsureV1,
            PeerCapability.workspaceLifecycleV1,
        ])
        XCTAssertFalse(TeamOrchestrator.looksLikeGUIPeerHost(oldDaemon))
        XCTAssertFalse(
            TeamOrchestrator.looksLikeGUIPeerHost(PeerCapabilities(PeerCapability.supported)),
            "a host that can own agents is never reported as unable to by design"
        )
    }

    @MainActor
    func test_guiHostBlockNamesStartingADaemonRatherThanUpdating() {
        let message = TeamOrchestrator.peerOwnedAgentFallbackMessage(
            .guiHostNoSessionOwner, cli: "codex", hostName: "mac-peer"
        )
        XCTAssertTrue(message.contains("Start its daemon"))
        XCTAssertTrue(
            message.contains("Updating term-mesh there will not change this"),
            "the old wording sent users to an update that cannot fix a GUI host"
        )
    }

    /// `sessionHostRemoteSockPath` defaults to `""` — *answered, no redirect* —
    /// because that is what almost every case here means. Pass `nil` for the
    /// window where the connection is live and the handshake is not.
    private func hostEntry(
        sshTarget: String? = "mac-peer",
        sessionHostRemoteSockPath: String? = ""
    ) -> HostEntry {
        var entry = HostEntry(
            id: "host",
            displayName: "mac-peer",
            connectionState: .connected,
            workspaces: [],
            activeSockPath: "/tmp/local-tunnel.sock",
            sshTarget: sshTarget,
            remoteSockPath: "/tmp/term-mesh-peer-501/peer.sock"
        )
        entry.sessionHostRemoteSockPath = sessionHostRemoteSockPath
        return entry
    }

    // MARK: - Review round 2: endpoint selection under an unresolved route

    /// `teamHostSpec` used to be non-optional and answered `paneHostSpec` while
    /// the route was unknown. That reads as "no redirect" — the GUI socket, the
    /// one endpoint that owns none of this team's surfaces — so every caller
    /// leased and ensured there for the window between a reconnect and its
    /// handshake. Optional is what forces each of them to say what it does
    /// instead.
    @MainActor
    func test_theTeamSpecIsAbsentRatherThanTheServingSocketWhileUnresolved() {
        let reconnecting = hostEntry(sessionHostRemoteSockPath: nil)
        XCTAssertNil(
            reconnecting.teamHostSpec,
            "an unknown route must not resolve to the serving endpoint"
        )
        XCTAssertThrowsError(try TeamOrchestrator.requireTeamHostSpec(reconnecting)) { error in
            guard case TeamOrchestrator.RemoteAgentError.hostNotConnected = error else {
                return XCTFail("unresolved must raise the retryable not-connected error, got \(error)")
            }
        }

        // Answered-as-none still yields a usable spec: that host owns its own
        // sessions, and team work belongs on the socket already open to it.
        let plain = hostEntry()
        XCTAssertEqual(plain.teamHostSpec?.hostKey, plain.paneHostSpec.hostKey)
        XCTAssertNoThrow(try TeamOrchestrator.requireTeamHostSpec(plain))
    }

    /// The sweep's protection set is what keeps a pane the user has on screen
    /// out of the `unclaimed` bucket that Select All closes. A redirected host
    /// has panes on *both* endpoints — ordinary terminals lease `paneHostSpec`,
    /// team agents lease the session owner — so asking either key alone loses
    /// one of the two groups.
    @MainActor
    func test_bothEndpointsAreProtectedFromTheShellSweepOnARedirectedHost() {
        let redirected = hostEntry(sessionHostRemoteSockPath: "/tmp/T/term-meshd-peer.sock")
        var keys: Set<PeerPaneHostKey> = [redirected.paneHostSpec.hostKey]
        if let teamKey = redirected.teamHostSpec?.hostKey { keys.insert(teamKey) }
        XCTAssertEqual(
            keys.count, 2,
            "a redirected host must contribute two distinct protection keys, not one"
        )
        XCTAssertTrue(keys.contains(redirected.paneHostSpec.hostKey))
        XCTAssertTrue(keys.contains(redirected.teamHostSpec!.hostKey))
    }

    /// An unresolved route must not reach the capability probe either: probing
    /// the serving socket there reports a capable machine as incapable, and the
    /// caller opens the SSH-owned fallback pane this path exists to avoid.
    @MainActor
    func test_theCapabilityProbeWaitsForTheRouteRatherThanProbingTheServingSocket() {
        let reconnecting = hostEntry(sessionHostRemoteSockPath: nil)
        XCTAssertFalse(reconnecting.teamRouteResolved)
        XCTAssertFalse(
            reconnecting.redirectsTeamWorkToSessionHost,
            "unresolved reads as no-redirect, which is why the probe needs its own gate"
        )
        XCTAssertNil(reconnecting.teamHostSpec)
    }

    /// The reconnect window. `connectionState` and `activeSockPath` are set
    /// synchronously when the sidebar lease is acquired
    /// (`RemoteHostStore.swift`), while the session-owner answer only lands
    /// after `fetchWorkspaces` completes. Between those two, a redirecting host
    /// reads as a plain one — and team work aimed at surfaces living on its
    /// daemon would be addressed to the GUI socket instead.
    @MainActor
    func test_teamWorkWaitsWhileTheRouteIsStillUnknownOnALiveConnection() {
        let reconnecting = hostEntry(sessionHostRemoteSockPath: nil)
        XCTAssertTrue(reconnecting.isConnected)
        XCTAssertFalse(reconnecting.activeSockPath.isEmpty)
        XCTAssertFalse(
            reconnecting.teamRouteResolved,
            "no handshake has answered yet"
        )
        XCTAssertTrue(
            TeamOrchestrator.liveTeamSockPath(for: reconnecting).isEmpty,
            "team RPCs must wait for the answer rather than fall back to the serving socket"
        )
        XCTAssertTrue(
            TeamOrchestrator.peerAgentCleanupEndpoint(
                host: reconnecting, servingSockPath: reconnecting.activeSockPath
            ).isUnresolved,
            "a tombstone must be kept and retried, never guessed onto the serving socket"
        )
    }

    /// Disconnect clears the route while daemon-owned panes and their lease can
    /// still be alive. The surfaces did not move, so the honest answer is "not
    /// addressable right now" — never the serving socket, which is what the
    /// cleared field would otherwise collapse to.
    @MainActor
    func test_disconnectLeavesTeamWorkUnaddressableRatherThanMisaddressed() {
        var host = hostEntry(sessionHostRemoteSockPath: "/tmp/T/term-meshd-peer.sock")
        XCTAssertTrue(host.redirectsTeamWorkToSessionHost)

        host.clearServingMetadata()
        host.activeSockPath = ""

        XCTAssertFalse(host.teamRouteResolved, "the route is forgotten, not answered as none")
        XCTAssertFalse(host.redirectsTeamWorkToSessionHost)
        XCTAssertTrue(TeamOrchestrator.liveTeamSockPath(for: host).isEmpty)
        XCTAssertTrue(
            TeamOrchestrator.peerAgentCleanupEndpoint(
                host: host, servingSockPath: "/tmp/stale.sock"
            ).isUnresolved
        )
    }

    /// A host with no entry at all is not the same as one whose answer is
    /// pending: nothing is coming, so the socket that served the tombstone is
    /// the only address it will ever have. Attempt it rather than stall.
    @MainActor
    func test_anUnknownHostIsAttemptedRatherThanTreatedAsPending() {
        let endpoint = TeamOrchestrator.peerAgentCleanupEndpoint(
            host: nil, servingSockPath: "/tmp/served.sock"
        )
        XCTAssertFalse(endpoint.isUnresolved)
        XCTAssertEqual(endpoint.describedTarget, "/tmp/served.sock")
    }

    func test_teamWorkFollowsTheAdvertisedSessionOwnerWhileMirroringDoesNot() {
        let redirected = hostEntry(sessionHostRemoteSockPath: "/tmp/T/term-meshd-peer.sock")
        XCTAssertEqual(
            redirected.teamHostSpec?.hostKey.remoteSockPath,
            "/tmp/T/term-meshd-peer.sock"
        )
        XCTAssertEqual(
            redirected.paneHostSpec.hostKey.remoteSockPath,
            "/tmp/term-mesh-peer-501/peer.sock",
            "the sidebar keeps mirroring the host's own surfaces"
        )
        XCTAssertTrue(redirected.redirectsTeamWorkToSessionHost)
    }

    /// Project discovery is team work too. Workspaces remain on the serving
    /// GUI, while ListTeams must follow the same owner as manifest upsert and
    /// delete or a persisted project becomes write-only after app restart.
    func test_projectManifestDiscoveryFollowsTheAdvertisedSessionOwner() {
        let redirected = hostEntry(sessionHostRemoteSockPath: "/tmp/T/term-meshd-peer.sock")
        XCTAssertNotEqual(
            redirected.paneHostSpec.hostKey,
            redirected.teamHostSpec?.hostKey
        )
        XCTAssertEqual(
            redirected.teamHostSpec?.hostKey.remoteSockPath,
            "/tmp/T/term-meshd-peer.sock",
            "manifest discovery must read the endpoint that stores the manifest"
        )
    }

    /// The production topology that regressed on mac-sub, kept as one
    /// mutation-sensitive contract rather than three independent facts. The
    /// serving GUI intentionally cannot own agents or manifests; its sibling
    /// daemon can. Durable creation is allowed only when discovery, readiness,
    /// and later team RPCs all name that sibling endpoint.
    @MainActor
    func test_macGUIProjectCreationUsesOneReadySessionOwnerForEveryDurableOperation() throws {
        var redirected = hostEntry(
            sessionHostRemoteSockPath: "/tmp/T/term-meshd-peer.sock"
        )
        let servingEndpoint = redirected.paneHostSpec.hostKey
        let ownerEndpoint = try XCTUnwrap(redirected.teamHostSpec?.hostKey)
        XCTAssertNotEqual(servingEndpoint, ownerEndpoint)
        XCTAssertEqual(
            ownerEndpoint.remoteSockPath, "/tmp/T/term-meshd-peer.sock"
        )

        redirected.teamHostReadiness = .ready(TeamHostCapabilitySnapshot(
            endpoint: ownerEndpoint,
            appVersion: "0.199.0",
            supportsPeerOwnedAgentHosting: true,
            supportsRemoteTeamRoute: true,
            looksLikeGUIPeerHost: false,
            redirectedFromServingEndpoint: true
        ))

        let snapshot = try XCTUnwrap(redirected.teamHostReadiness.snapshot)
        XCTAssertEqual(snapshot.endpoint, ownerEndpoint)
        XCTAssertNotEqual(snapshot.endpoint, servingEndpoint)
        XCTAssertTrue(snapshot.supportsDurableRemoteCreation)
        XCTAssertTrue(redirected.redirectsTeamWorkToSessionHost)
        XCTAssertEqual(
            try TeamOrchestrator.requireTeamHostSpec(redirected).hostKey,
            ownerEndpoint,
            "create, presentation discovery, attach, and delete must share one owner"
        )
    }

    /// Ensure succeeded on the session owner, the local attach then failed, and
    /// nothing holds a lease any more. The tombstone must still reach the
    /// endpoint that created the surface — sending `TerminateSurface` to the
    /// socket that merely served the handshake names a surface that endpoint
    /// never made, so the retry loops forever while the `tm-agent-bridge` it
    /// was meant to kill keeps running.
    @MainActor
    func test_orphanedAgentCleanupTargetsTheEndpointThatCreatedTheSurface() {
        let redirected = hostEntry(sessionHostRemoteSockPath: "/tmp/T/term-meshd-peer.sock")
        let endpoint = TeamOrchestrator.peerAgentCleanupEndpoint(
            host: redirected,
            servingSockPath: redirected.activeSockPath
        )
        XCTAssertTrue(
            endpoint.leasesSessionOwner,
            "a redirected host must lease its session owner rather than reuse the serving socket"
        )
        XCTAssertEqual(endpoint.describedTarget, "/tmp/T/term-meshd-peer.sock")
    }

    /// The direct path stays direct. A host that owns its own surfaces must not
    /// pay for a second tunnel to reach a socket that is already open, and an
    /// unknown host must still be attempted on whatever served it.
    @MainActor
    func test_cleanupOnAnUnredirectedOrUnknownHostKeepsTheServingSocket() {
        let plain = hostEntry()
        let direct = TeamOrchestrator.peerAgentCleanupEndpoint(
            host: plain, servingSockPath: plain.activeSockPath
        )
        XCTAssertFalse(direct.leasesSessionOwner)
        XCTAssertEqual(direct.describedTarget, plain.activeSockPath)

        let unknown = TeamOrchestrator.peerAgentCleanupEndpoint(
            host: nil, servingSockPath: "/tmp/served.sock"
        )
        XCTAssertFalse(unknown.leasesSessionOwner)
        XCTAssertEqual(unknown.describedTarget, "/tmp/served.sock")
    }

    /// The shell sweep reads `host.workspaces`, which the sidebar fetched over
    /// the serving socket — so it must keep addressing that socket even on a
    /// redirected host. Routing it to the session owner sent `ClosePane` for
    /// panes that endpoint never published, and the guard failed sooner still:
    /// the team tunnel does not exist until some pane leases it, so a connected
    /// GUI host reported itself disconnected before one shell was tried.
    @MainActor
    func test_theShellSweepEndpointIsNotTheTeamEndpointOnARedirectedHost() {
        let redirected = hostEntry(sessionHostRemoteSockPath: "/tmp/T/term-meshd-peer.sock")
        XCTAssertNotEqual(
            redirected.paneHostSpec.hostKey,
            redirected.teamHostSpec?.hostKey,
            "this test is meaningless unless the two endpoints really differ"
        )
        XCTAssertFalse(
            redirected.activeSockPath.isEmpty,
            "the sweep's guard reads this, and it is non-empty whenever the host is connected"
        )
        XCTAssertTrue(
            TeamOrchestrator.liveTeamSockPath(for: redirected).isEmpty,
            "with no pane holding the team lease there is no team socket — which is exactly "
                + "why the sweep must not gate on one"
        )
    }

    func test_teamWorkStaysPutWithoutASessionOwnerOrWithoutSSH() {
        let plain = hostEntry()
        XCTAssertEqual(plain.teamHostSpec?.hostKey, plain.paneHostSpec.hostKey)
        XCTAssertFalse(plain.redirectsTeamWorkToSessionHost)

        // A direct (non-SSH) host has no second path to tunnel to, so the
        // advertisement cannot be honoured and must not be half-applied.
        let direct = hostEntry(
            sshTarget: nil,
            sessionHostRemoteSockPath: "/tmp/T/term-meshd-peer.sock"
        )
        XCTAssertEqual(direct.teamHostSpec?.hostKey, direct.paneHostSpec.hostKey)
        XCTAssertFalse(direct.redirectsTeamWorkToSessionHost)
    }

    // MARK: - Review round 3: the endpoint that created the surface

    /// A surface does not move when the host's route does.
    ///
    /// Cleanup used to re-ask the host where team work goes *now*, which is a
    /// different question: after a later handshake moved the route, the new
    /// owner answers `notFound` for a surface it never created, and that reply
    /// is indistinguishable from a real confirmation — so the tombstone was
    /// dropped while the bridge kept running on the endpoint that had it.
    @MainActor
    func test_cleanupPrefersTheRecordedCreationEndpointOverTheHostsCurrentRoute() {
        let movedOn = hostEntry(sessionHostRemoteSockPath: "/tmp/OWNER-B/peer.sock")
        let endpoint = TeamOrchestrator.peerAgentCleanupEndpoint(
            host: movedOn,
            servingSockPath: movedOn.activeSockPath,
            owningRemoteSockPath: "/tmp/OWNER-A/peer.sock"
        )
        XCTAssertEqual(
            endpoint.describedTarget, "/tmp/OWNER-A/peer.sock",
            "the surface lives where it was ensured, not where team work goes now"
        )
        XCTAssertTrue(endpoint.leasesSessionOwner)
    }

    /// The recorded endpoint keeps the host row's auth parameters: only the
    /// remote socket is pinned. Rebuilding it from the path alone would drop
    /// the port/identity the tunnel needs.
    @MainActor
    func test_theRecordedEndpointKeepsTheHostsAuthParameters() {
        var host = hostEntry(sessionHostRemoteSockPath: "/tmp/OWNER-B/peer.sock")
        host.sshPort = 2222
        host.identityFile = "/keys/id_ed25519"
        let endpoint = TeamOrchestrator.peerAgentCleanupEndpoint(
            host: host,
            servingSockPath: host.activeSockPath,
            owningRemoteSockPath: "/tmp/OWNER-A/peer.sock"
        )
        guard case .sessionOwner(let spec) = endpoint,
              case .ssh(let target, let remote, let port, let identity) = spec
        else { return XCTFail("a recorded endpoint on an SSH host must be an SSH spec") }
        XCTAssertEqual(target, "mac-peer")
        XCTAssertEqual(remote, "/tmp/OWNER-A/peer.sock")
        XCTAssertEqual(port, 2222)
        XCTAssertEqual(identity, "/keys/id_ed25519")
    }

    /// A tombstone written by an earlier build carries no endpoint. It must keep
    /// resolving by host rather than being discarded — a dropped tombstone is a
    /// bridge that runs forever.
    @MainActor
    func test_aRecordWithoutARecordedEndpointStillResolvesByHost() {
        let host = hostEntry(sessionHostRemoteSockPath: "/tmp/OWNER/peer.sock")
        let endpoint = TeamOrchestrator.peerAgentCleanupEndpoint(
            host: host, servingSockPath: host.activeSockPath, owningRemoteSockPath: nil
        )
        XCTAssertEqual(endpoint.describedTarget, "/tmp/OWNER/peer.sock")
        // Empty is the same as absent: neither names an endpoint.
        XCTAssertEqual(
            TeamOrchestrator.peerAgentCleanupEndpoint(
                host: host, servingSockPath: host.activeSockPath, owningRemoteSockPath: ""
            ).describedTarget,
            "/tmp/OWNER/peer.sock"
        )
    }

    /// With a known creation endpoint but no host row, there is a specific
    /// address that is known to be right and no way to dial it yet. That waits
    /// — unlike the unknown-host case, where the serving socket is the only
    /// address there will ever be.
    @MainActor
    func test_aRecordedEndpointWithoutAHostRowWaitsRatherThanUsingTheServingSocket() {
        XCTAssertTrue(
            TeamOrchestrator.peerAgentCleanupEndpoint(
                host: nil,
                servingSockPath: "/tmp/serving.sock",
                owningRemoteSockPath: "/tmp/OWNER-A/peer.sock"
            ).isUnresolved
        )
        XCTAssertEqual(
            TeamOrchestrator.peerAgentCleanupEndpoint(
                host: nil, servingSockPath: "/tmp/serving.sock"
            ).describedTarget,
            "/tmp/serving.sock",
            "an unknown host with no recorded endpoint still attempts the serving socket"
        )
    }

    /// A new tunnel invalidates the team route exactly as it invalidates the CLI
    /// bin dirs.
    ///
    /// `clearAuthenticatedHostCLIBinDirs` clears only the three CLI fields;
    /// `clearServingMetadata` is what forgets the route. Calling the first alone
    /// on the reconnect path left `teamRouteResolved` true across the reconnect,
    /// so team work was addressed to the previous connection's session owner
    /// until the new handshake answered — the one state that must not be claimed
    /// on credit.
    @MainActor
    func test_reconnectForgetsTheTeamRouteRatherThanCarryingItOver() {
        var host = hostEntry(sessionHostRemoteSockPath: "/tmp/OWNER-A/peer.sock")
        XCTAssertTrue(host.teamRouteResolved)
        XCTAssertTrue(host.redirectsTeamWorkToSessionHost)

        // What the reconnect path does when the ephemeral socket changed.
        host.clearAuthenticatedHostCLIBinDirs()
        host.clearServingMetadata()
        host.activeSockPath = "/tmp/local-tunnel-2.sock"

        XCTAssertFalse(
            host.teamRouteResolved,
            "the route belonged to the connection that advertised it"
        )
        XCTAssertNil(host.teamHostSpec)
        XCTAssertTrue(TeamOrchestrator.liveTeamSockPath(for: host).isEmpty)
        XCTAssertTrue(
            TeamOrchestrator.peerAgentCleanupEndpoint(
                host: host, servingSockPath: host.activeSockPath
            ).isUnresolved,
            "the new handshake is coming; a tombstone waits for it"
        )
    }

    /// The CLI-bin-dirs clear on its own is not enough — this is the assertion
    /// that fails if the two clears are ever collapsed back into one call.
    @MainActor
    func test_clearingCLIBinDirsAloneDoesNotForgetTheTeamRoute() {
        var host = hostEntry(sessionHostRemoteSockPath: "/tmp/OWNER-A/peer.sock")
        host.clearAuthenticatedHostCLIBinDirs()
        XCTAssertTrue(
            host.teamRouteResolved,
            "these are two different facts; the reconnect path must clear both"
        )
    }

    /// The principal mid-session case: a member ensured on owner A, detached
    /// after the host's route moved to owner B.
    ///
    /// `releasePeerOwnedAgentSurface` reads what the member recorded at ensure
    /// time. Reading the host's current route here instead is what left the
    /// bridge alive on A while B's `notFound` retired the tombstone.
    @MainActor
    func test_aDetachedMemberIsTerminatedWhereItWasEnsured() {
        let movedOn = hostEntry(sessionHostRemoteSockPath: "/tmp/OWNER-B/peer.sock")
        let endpoint = TeamOrchestrator.peerAgentCleanupEndpoint(
            host: movedOn,
            servingSockPath: movedOn.activeSockPath,
            // What the member carries from its ensure.
            owningRemoteSockPath: "/tmp/OWNER-A/peer.sock"
        )
        XCTAssertEqual(endpoint.describedTarget, "/tmp/OWNER-A/peer.sock")
    }
}
