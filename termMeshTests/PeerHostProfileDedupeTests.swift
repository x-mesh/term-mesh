import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Exercises the pure helpers behind the 3-part fix for duplicate saved
/// SSH profiles (same `sshTarget` seeded more than once): startup
/// migration merge, full-target delete, and dedup-on-write. All three
/// are `nonisolated static func`s on the `@MainActor` PeerHostProfileStore
/// so they're callable synchronously here without touching the
/// singleton's file I/O.
final class PeerHostProfileDedupeTests: XCTestCase {

    // MARK: - Helpers

    private func profile(
        id: UUID = UUID(),
        sshTarget: String,
        displayName: String = "",
        remoteSocket: String = "",
        sshPort: Int? = nil,
        identityFile: String? = nil,
        colorHex: String? = nil,
        symbolName: String? = nil,
        lastConnectedAt: Date? = nil
    ) -> PeerHostProfile {
        PeerHostProfile(
            id: id,
            displayName: displayName,
            sshTarget: sshTarget,
            remoteSocket: remoteSocket,
            sshPort: sshPort,
            identityFile: identityFile,
            colorHex: colorHex,
            symbolName: symbolName,
            lastConnectedAt: lastConnectedAt,
            createdAt: Date()
        )
    }

    // MARK: - dedupedBySSHTarget: no-op proof

    /// A store with no duplicate targets must come back untouched (nil,
    /// so the caller skips persisting) — the migration must never
    /// rewrite a healthy file.
    func test_dedupedBySSHTarget_noDuplicates_returnsNilAndLeavesDataAlone() {
        let profiles = [
            profile(sshTarget: "host-a", remoteSocket: "sockA"),
            profile(sshTarget: "host-b"),
            profile(sshTarget: "host-c", displayName: "Charlie"),
        ]
        XCTAssertNil(PeerHostProfileStore.dedupedBySSHTarget(profiles))
    }

    /// Multiple profiles with an empty sshTarget look like a "duplicate
    /// group" if the empty string were treated as a normal key — they
    /// must instead be excluded entirely and left as-is.
    func test_dedupedBySSHTarget_emptySSHTargetEntriesAreExcluded() {
        let profiles = [
            profile(sshTarget: "", displayName: "Draft 1"),
            profile(sshTarget: "", displayName: "Draft 2"),
            profile(sshTarget: "host-a"),
        ]
        XCTAssertNil(PeerHostProfileStore.dedupedBySSHTarget(profiles))
    }

    // MARK: - Survivor priority

    func test_dedupedBySSHTarget_survivorIsMostRecentlyConnected() {
        let older = profile(
            sshTarget: "host-a", remoteSocket: "sockOlder",
            lastConnectedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = profile(
            sshTarget: "host-a", remoteSocket: "sockNewer",
            lastConnectedAt: Date(timeIntervalSince1970: 200)
        )
        let unrelated = profile(sshTarget: "host-b")

        guard let result = PeerHostProfileStore.dedupedBySSHTarget([older, newer, unrelated]) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, newer.id, "most recently connected duplicate must survive")
        XCTAssertEqual(result[0].remoteSocket, "sockNewer", "remoteSocket is not backfilled")
        XCTAssertEqual(result[1].sshTarget, "host-b")
    }

    func test_dedupedBySSHTarget_fallsBackToNonEmptyRemoteSocket_whenNeitherHasLastConnectedAt() {
        let noSocket = profile(sshTarget: "host-a", remoteSocket: "")
        let withSocket = profile(sshTarget: "host-a", remoteSocket: "sockB")

        guard let result = PeerHostProfileStore.dedupedBySSHTarget([noSocket, withSocket]) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, withSocket.id)
    }

    func test_dedupedBySSHTarget_fallsBackToFirstArrayOrder_whenNoTiebreakersApply() {
        let first = profile(sshTarget: "host-a")
        let second = profile(sshTarget: "host-a")

        guard let result = PeerHostProfileStore.dedupedBySSHTarget([first, second]) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, first.id)
    }

    /// Survivor keeps the position of the group's first occurrence so
    /// unrelated rows around it don't jump.
    func test_dedupedBySSHTarget_survivorKeepsFirstOccurrencePosition() {
        let a = profile(sshTarget: "host-x")
        let dup1 = profile(
            sshTarget: "host-a",
            lastConnectedAt: Date(timeIntervalSince1970: 100)
        )
        let b = profile(sshTarget: "host-y")
        let dup2 = profile(
            sshTarget: "host-a",
            lastConnectedAt: Date(timeIntervalSince1970: 200)
        )

        guard let result = PeerHostProfileStore.dedupedBySSHTarget([a, dup1, b, dup2]) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.map { $0.sshTarget }, ["host-x", "host-a", "host-y"])
        XCTAssertEqual(result[1].id, dup2.id, "dup2 wins on recency but sits at dup1's slot")
    }

    // MARK: - Field backfill merge

    func test_dedupedBySSHTarget_backfillsOnlyEmptySurvivorFields_neverOverwritesPopulated() {
        let survivorWinner = profile(
            id: UUID(),
            sshTarget: "host-a",
            displayName: "SurvivorName",
            remoteSocket: "sockSurvivor",
            sshPort: nil,
            identityFile: nil,
            colorHex: nil,
            symbolName: "keep.symbol",
            lastConnectedAt: Date(timeIntervalSince1970: 200)
        )
        let duplicate = profile(
            id: UUID(),
            sshTarget: "host-a",
            displayName: "OtherName",
            remoteSocket: "sockDuplicate",
            sshPort: 22,
            identityFile: "/a/id_rsa",
            colorHex: "#111111",
            symbolName: "other.symbol",
            lastConnectedAt: Date(timeIntervalSince1970: 100)
        )

        guard let result = PeerHostProfileStore.dedupedBySSHTarget([survivorWinner, duplicate]) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 1)
        let merged = result[0]
        XCTAssertEqual(merged.id, survivorWinner.id)
        // Populated survivor fields are never overwritten.
        XCTAssertEqual(merged.displayName, "SurvivorName")
        XCTAssertEqual(merged.symbolName, "keep.symbol")
        XCTAssertEqual(merged.remoteSocket, "sockSurvivor", "remoteSocket is deliberately not backfilled")
        // Empty survivor fields backfill from the duplicate.
        XCTAssertEqual(merged.colorHex, "#111111")
        XCTAssertEqual(merged.identityFile, "/a/id_rsa")
        XCTAssertEqual(merged.sshPort, 22)
    }

    func test_dedupedBySSHTarget_threeWayDuplicateMergesAllNonEmptyFields() {
        let winner = profile(
            sshTarget: "host-a", lastConnectedAt: Date(timeIntervalSince1970: 300)
        )
        let withColor = profile(
            sshTarget: "host-a", colorHex: "#ABCDEF",
            lastConnectedAt: Date(timeIntervalSince1970: 100)
        )
        let withPort = profile(
            sshTarget: "host-a", sshPort: 2222,
            lastConnectedAt: Date(timeIntervalSince1970: 200)
        )

        guard let result = PeerHostProfileStore.dedupedBySSHTarget([winner, withColor, withPort]) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, winner.id)
        XCTAssertEqual(result[0].colorHex, "#ABCDEF")
        XCTAssertEqual(result[0].sshPort, 2222)
    }

    // MARK: - removingAll(forSSHTarget:)

    func test_removingAll_dropsEveryProfileForTarget() {
        let a1 = profile(sshTarget: "host-a")
        let a2 = profile(sshTarget: "host-a")
        let b = profile(sshTarget: "host-b")

        let result = PeerHostProfileStore.removingAll([a1, a2, b], forSSHTarget: "host-a")
        XCTAssertEqual(result.map { $0.id }, [b.id])
    }

    func test_removingAll_emptyTargetIsNoOp() {
        let a = profile(sshTarget: "host-a")
        let blank = profile(sshTarget: "")

        let result = PeerHostProfileStore.removingAll([a, blank], forSSHTarget: "")
        XCTAssertEqual(result.map { $0.id }, [a.id, blank.id])
    }

    // MARK: - upserted(_:with:)

    /// Editing a profile's sshTarget onto one another saved profile
    /// already claims must drop that older duplicate, not leave both
    /// alive under the same target.
    func test_upserted_dropsOtherProfilesSharingTheNewTarget() {
        let existing = profile(sshTarget: "host-a", displayName: "Existing")
        let edited = profile(id: UUID(), sshTarget: "host-a", displayName: "Edited")

        let result = PeerHostProfileStore.upserted([existing], with: edited)
        XCTAssertEqual(result.map { $0.id }, [edited.id])
    }

    func test_upserted_replacesInPlaceByID() {
        let original = profile(sshTarget: "host-a", displayName: "Original")
        let renamed = profile(id: original.id, sshTarget: "host-a", displayName: "Renamed")
        let other = profile(sshTarget: "host-b")

        let result = PeerHostProfileStore.upserted([original, other], with: renamed)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].displayName, "Renamed")
        XCTAssertEqual(result[1].id, other.id)
    }

    func test_upserted_appendsNewProfile() {
        let existing = profile(sshTarget: "host-a")
        let brandNew = profile(sshTarget: "host-b")

        let result = PeerHostProfileStore.upserted([existing], with: brandNew)
        XCTAssertEqual(result.map { $0.id }, [existing.id, brandNew.id])
    }

    /// Draft profiles with an empty sshTarget (mid-creation, not yet
    /// pointed at a host) must never collide with each other.
    func test_upserted_emptySSHTargetNeverDedupes() {
        let draft1 = profile(sshTarget: "", displayName: "Draft 1")
        let draft2 = profile(sshTarget: "", displayName: "Draft 2")

        let result = PeerHostProfileStore.upserted([draft1], with: draft2)
        XCTAssertEqual(result.map { $0.id }, [draft1.id, draft2.id])
    }
}
