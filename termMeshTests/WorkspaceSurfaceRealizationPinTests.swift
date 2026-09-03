import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A workspace created over the peer protocol is deliberately not selected, so
/// nothing mounts it, so `createSurface` — which needs a view inside a window —
/// never runs. `translateBonsplitNode` then drops the unrealized pane, and the
/// machine that asked for the workspace sees it as empty. That is what "could
/// not prepare the project workspace … waited 15 time(s) for a pane" was: the
/// pane existed the whole time and was never reportable.
///
/// The fix borrows the retention slot handoff already uses. These tests cover
/// the mounting arithmetic, because that is the part that decides whether the
/// pinned workspace is actually in the view tree — the surface creation itself
/// belongs to AppKit and is exercised by the peer e2e suites.
final class WorkspaceSurfaceRealizationPinTests: XCTestCase {

    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    // MARK: - The pin reaches the mounted set

    /// The default budget is two, which the selected workspace and one pinned
    /// workspace fill exactly. Without this, the pin is accepted and then
    /// truncated away, and nothing about the failure changes.
    func test_aPinnedWorkspaceIsMountedAlongsideTheSelectedOne() {
        let selected = id(1)
        let pinned = id(2)

        let mounted = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [selected],
            selected: selected,
            pinnedIds: [pinned],
            orderedTabIds: [selected, id(3), pinned, id(4)],
            isCycleHot: false,
            maxMounted: max(WorkspaceMountPolicy.maxMountedWorkspaces, 1 + 1)
        )

        XCTAssertTrue(mounted.contains(pinned), "a pin that never mounts realizes nothing")
        XCTAssertTrue(mounted.contains(selected), "pinning must not evict the workspace in use")
    }

    /// `ContentView` raises the ceiling to `selected + pins` rather than
    /// letting the fixed budget truncate. Two peers preparing a workspace at
    /// once is ordinary — a project places a leader on more than one host —
    /// and the second pin silently losing its mount would strand exactly one
    /// of them with no way to tell which.
    func test_severalPinsAreAllRetainedWhenTheBudgetIsRaisedForThem() {
        let selected = id(1)
        let pins: Set<UUID> = [id(2), id(3), id(4)]

        let mounted = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [selected],
            selected: selected,
            pinnedIds: pins,
            orderedTabIds: [selected] + pins.sorted { $0.uuidString < $1.uuidString },
            isCycleHot: false,
            maxMounted: max(WorkspaceMountPolicy.maxMountedWorkspaces, 1 + pins.count)
        )

        for pin in pins {
            XCTAssertTrue(mounted.contains(pin), "pin \(pin) was truncated out of the mounted set")
        }
        XCTAssertTrue(mounted.contains(selected))
    }

    /// The fixed budget is what applies if a caller forgets to raise it. Then
    /// the pin loses — which is the pre-fix behaviour, and the reason the
    /// ceiling is computed from the pin count instead of being a constant.
    func test_theFixedBudgetAloneCannotHoldSelectedPlusTwoPins() {
        let selected = id(1)
        let pins: Set<UUID> = [id(2), id(3)]

        let mounted = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [selected],
            selected: selected,
            pinnedIds: pins,
            orderedTabIds: [selected, id(2), id(3)],
            isCycleHot: false,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspaces
        )

        XCTAssertEqual(mounted.count, WorkspaceMountPolicy.maxMountedWorkspaces)
        XCTAssertTrue(mounted.contains(selected))
        XCTAssertLessThan(
            pins.filter(mounted.contains).count,
            pins.count,
            "if the fixed budget could hold every pin, raising the ceiling would be dead code"
        )
    }

    /// A pin on a workspace that has since been closed must not hold a slot
    /// that a live workspace needs; `nextMountedWorkspaceIds` filters against
    /// the roster it is given.
    func test_aPinOnAClosedWorkspaceIsDropped() {
        let selected = id(1)
        let closed = id(9)

        let mounted = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [selected],
            selected: selected,
            pinnedIds: [closed],
            orderedTabIds: [selected, id(2)],
            isCycleHot: false,
            maxMounted: max(WorkspaceMountPolicy.maxMountedWorkspaces, 1 + 1)
        )

        XCTAssertFalse(mounted.contains(closed))
        XCTAssertTrue(mounted.contains(selected))
    }

    @MainActor
    func test_independentPinOwnersCannotReleaseEachOthersMount() {
        let manager = TabManager(persistsSessionState: false)
        let workspaceID = manager.tabs[0].id
        manager.pinWorkspaceForSurfaceRealization(workspaceID)
        manager.pinWorkspaceForSurfaceRealization(workspaceID)

        manager.unpinWorkspaceForSurfaceRealization(workspaceID)
        XCTAssertTrue(manager.surfaceRealizationPins.contains(workspaceID))
        manager.unpinWorkspaceForSurfaceRealization(workspaceID)
        XCTAssertFalse(manager.surfaceRealizationPins.contains(workspaceID))
    }

    // MARK: - Timeout

    /// The pin is bounded because an unresolved one keeps an invisible
    /// workspace in the view tree for the rest of the session, paying SwiftUI
    /// update cost forever. It is bounded *generously* because the asking
    /// machine gives up after ~3s and releasing at that mark would strand the
    /// workspace unrealized for the retry that follows.
    @MainActor
    func test_thePinOutlivesTheAskingMachinesOwnPollBudget() {
        let callerBudget: TimeInterval = 15 * 0.2

        XCTAssertGreaterThan(
            GhosttyPaneSurfaceProvider.surfaceRealizationPinTimeout,
            callerBudget,
            "releasing before the caller stops polling wastes the mount entirely"
        )
        XCTAssertLessThanOrEqual(
            GhosttyPaneSurfaceProvider.surfaceRealizationPinTimeout,
            60,
            "an unbounded pin is a permanent mounted workspace nobody can see"
        )
    }

    /// Slow enough not to spin the main actor, fast enough that the caller's
    /// next poll finds the pane rather than timing out behind ours.
    @MainActor
    func test_thePollIntervalFitsInsideTheCallersRetryWindow() {
        XCTAssertLessThanOrEqual(
            GhosttyPaneSurfaceProvider.surfaceRealizationPollInterval,
            .milliseconds(200),
            "polling slower than the caller means it gives up while we are still asleep"
        )
        XCTAssertGreaterThanOrEqual(
            GhosttyPaneSurfaceProvider.surfaceRealizationPollInterval,
            .milliseconds(50)
        )
    }
}
