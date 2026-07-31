import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Not being able to ask is not the same as being told no.
///
/// `reattachRemoteLeaderIfNeeded` caught every transport failure and returned
/// the same `false` an authoritative absence returned, and
/// `recoverRemoteLeaderAfterRuntimeClose` read any `false` as permission to
/// bootstrap. So a brief tunnel, socket or list-RPC failure just after a relay
/// EOF — the moment those are most likely — minted a second grant and a second
/// surface beside a remote leader that was still running, and the team had two.
///
/// What is pinned here is the decision, not the RPC. The reattach flow needs a
/// peer host, a lease, a workspace and an `AppDelegate`, none of which a unit
/// test can stand up; but the choice it exists to make is a pure function over
/// "what did the roster say", and that is the part that was wrong. Production
/// calls exactly this function — the `catch` around `listSurfaces` sets the
/// roster to nil and hands it here — so pinning it pins the real path.
@MainActor
final class RemoteLeaderReattachTriStateTests: XCTestCase {

    private let stored = Data([0xCA, 0xFE, 0xBA, 0xBE])
    private let other = Data([0x01, 0x02, 0x03, 0x04])

    // MARK: - (a) A roster that could not be read never authorises a bootstrap

    /// The P1. `host.isConnected` is a cached reachability flag, not a promise
    /// that the list RPC succeeds, so a connected host whose `listSurfaces`
    /// throws lands here — and this is the case that used to be indistinguish-
    /// able from "the surface is gone".
    func testAThrownSurfaceListIsNotTreatedAsAMissingSurface() {
        let verdict = TeamOrchestrator.remoteLeaderRosterVerdict(
            rosterSurfaceIDs: nil,
            storedSurfaceID: stored
        )

        XCTAssertEqual(
            verdict,
            .temporarilyUnavailable,
            "a roster nobody could read says nothing about whether the surface is there"
        )
        XCTAssertEqual(
            verdict?.permitsReplacementBootstrap,
            false,
            "this is the gate recoverRemoteLeaderAfterRuntimeClose reads before "
                + "attachRemoteLeader; letting it through is the duplicate leader"
        )
    }

    /// The same must hold when the host is reachable enough to hand out a lease
    /// and still cannot answer — there is no partial roster to reason from, and
    /// a partial one must never be inferred.
    func testAnUnreadableRosterStaysUnreadableWhateverWasStored() {
        for surfaceID in [stored, other, Data()] {
            XCTAssertEqual(
                TeamOrchestrator.remoteLeaderRosterVerdict(
                    rosterSurfaceIDs: nil,
                    storedSurfaceID: surfaceID
                ),
                .temporarilyUnavailable
            )
        }
    }

    // MARK: - (b) A roster that WAS read still authorises a bootstrap

    /// The other half: fail-closed must not become fail-stuck. When the host
    /// answered and its own list does not carry the stored surface, the remote
    /// leader really is gone and a replacement is the repair.
    func testASurfaceAbsentFromAReadRosterIsConfirmedMissing() {
        let verdict = TeamOrchestrator.remoteLeaderRosterVerdict(
            rosterSurfaceIDs: [other],
            storedSurfaceID: stored
        )

        XCTAssertEqual(verdict, .confirmedMissing)
        XCTAssertEqual(
            verdict?.permitsReplacementBootstrap,
            true,
            "a host that restarted must still get its leader rebuilt"
        )
    }

    /// An empty roster is an answer too — the host reported no surfaces at all.
    func testAnEmptyRosterIsAnAnswerAndConfirmsTheSurfaceIsGone() {
        XCTAssertEqual(
            TeamOrchestrator.remoteLeaderRosterVerdict(
                rosterSurfaceIDs: [],
                storedSurfaceID: stored
            ),
            .confirmedMissing,
            "an empty list is the host saying it holds nothing, not a failed read"
        )
    }

    /// And when the surface is there, the flow carries on to attach rather than
    /// reaching a verdict at all.
    func testAPresentSurfaceYieldsNoVerdictSoTheAttachProceeds() {
        XCTAssertNil(
            TeamOrchestrator.remoteLeaderRosterVerdict(
                rosterSurfaceIDs: [other, stored],
                storedSurfaceID: stored
            ),
            "nil is what lets the attach run; any verdict here would skip it"
        )
    }

    // MARK: - The gate itself

    /// Spelled out rather than left implicit: exactly one state may mint a
    /// second grant. A fourth state added later defaults to refusing, which is
    /// the safe direction.
    func testOnlyAConfirmedAbsencePermitsASecondLeader() {
        XCTAssertTrue(RemoteLeaderReattachOutcome.confirmedMissing.permitsReplacementBootstrap)
        XCTAssertFalse(RemoteLeaderReattachOutcome.attached.permitsReplacementBootstrap)
        XCTAssertFalse(
            RemoteLeaderReattachOutcome.temporarilyUnavailable.permitsReplacementBootstrap
        )
    }

    // MARK: - The retry is bounded

    /// A peer that stays unreachable is not something the retry loop can fix,
    /// and it holds `remoteLeaderRecoveryInFlight` while it runs. Bounded, so
    /// the team comes back to a person — `recoverRemoteLeaderIfNeeded` is the
    /// manual retry that stays available afterwards.
    func testTheReattachRetryIsBoundedAndFinite() {
        let backoff = TeamOrchestrator.remoteLeaderReattachBackoffSeconds

        XCTAssertFalse(backoff.isEmpty, "an unreachable host must be retried at least once")
        XCTAssertTrue(
            backoff.allSatisfy { $0 > 0 },
            "a zero delay would spin the recovery lock rather than wait"
        )
        XCTAssertLessThanOrEqual(
            backoff.reduce(0, +),
            30,
            "the recovery interlock is held for this whole window; it cannot be long"
        )
    }
}
