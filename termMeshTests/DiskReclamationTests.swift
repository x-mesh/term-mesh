import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The settings card may only ever reclaim build caches. A `gc.sweep` without
/// a `categories` array reclaims every category, worktrees included, so the
/// request shape and the dry-run scope check are pinned here.
final class DiskReclamationTests: XCTestCase {

    func testSweepParamsAreScopedToBuildCaches() {
        for apply in [false, true] {
            let params = BuildCacheReclaim.sweepParams(apply: apply)
            XCTAssertEqual(params["categories"] as? [String], ["build_caches"])
            XCTAssertEqual(params["deep"] as? Bool, true)
            XCTAssertEqual(params["apply"] as? Bool, apply)
            XCTAssertNil(params["category"], "the socket key is the plural `categories`")
        }
        let status = BuildCacheReclaim.statusParams()
        XCTAssertEqual(status["categories"] as? [String], ["build_caches"])
        XCTAssertEqual(status["deep"] as? Bool, true)
        XCTAssertNil(status["apply"])
    }

    func testDryRunSplitsPendingAndSkipped() throws {
        let raw = """
        {"applied":false,"removed":0,"skipped":1,"reclaimed_bytes":0,"outcomes":[
          {"path":"/w/a/target","category":"build_caches","action":"would_remove","reason":"worktree_cargo_target","bytes":3000000000},
          {"path":"/w/b/target","category":"build_caches","action":"would_remove","reason":"worktree_cargo_target","bytes":1000000000},
          {"path":"/tmp/term-mesh-x","category":"build_caches","action":"skipped","reason":"owned_by_reload_script","bytes":5000000000}
        ]}
        """
        let result = try XCTUnwrap(BuildCacheReclaim.parseSweep(raw))
        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.pending.map(\.path), ["/w/a/target", "/w/b/target"])
        XCTAssertEqual(result.pendingBytes, 4_000_000_000)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(BuildCacheReclaim.isScopedToBuildCaches(result))
    }

    func testAPlanTouchingAnotherCategoryIsRejected() throws {
        let raw = """
        {"applied":false,"outcomes":[
          {"path":"/w/a/target","category":"build_caches","action":"would_remove","reason":"","bytes":1},
          {"path":"/w/a","category":"gitkit_worktrees","action":"would_remove","reason":"","bytes":1}
        ]}
        """
        let result = try XCTUnwrap(BuildCacheReclaim.parseSweep(raw))
        XCTAssertFalse(BuildCacheReclaim.isScopedToBuildCaches(result))
    }

    func testUnreadableSweepReplyIsNil() {
        XCTAssertNil(BuildCacheReclaim.parseSweep(nil))
        XCTAssertNil(BuildCacheReclaim.parseSweep("not json"))
        XCTAssertNil(BuildCacheReclaim.parseSweep("{\"applied\":true}"))
    }

    func testStatusParsesCategoriesAndLastSweep() throws {
        let raw = """
        {"categories":[
          {"category":"gitkit_worktrees","entry_count":26,"candidate_count":6,"total_bytes":20126283116,"reclaimable_bytes":13584153464,"auto":false,"note":null},
          {"category":"build_caches","entry_count":0,"candidate_count":0,"total_bytes":0,"reclaimable_bytes":0,"auto":false,"note":"pass deep=true to size build caches"}
        ],
        "last_sweep":{"at_ms":1795390641884,"mode":"periodic","reclaimed_bytes":2048,"removed":3},
        "reclaimable_bytes":13584153464,"state":"idle","total_bytes":20126283116}
        """
        let status = try XCTUnwrap(GcStatusSummary.parse(raw))
        let worktrees = try XCTUnwrap(status.category("gitkit_worktrees"))
        XCTAssertEqual(worktrees.entryCount, 26)
        XCTAssertEqual(worktrees.candidateCount, 6)
        XCTAssertEqual(worktrees.reclaimableBytes, 13_584_153_464)
        XCTAssertNotNil(status.category("build_caches"))
        let sweep = try XCTUnwrap(status.lastSweep)
        XCTAssertEqual(sweep.removed, 3)
        XCTAssertEqual(sweep.reclaimedBytes, 2048)
        XCTAssertEqual(sweep.at.timeIntervalSince1970, 1_795_390_641.884, accuracy: 0.001)
    }

    func testStatusWithoutLastSweep() throws {
        let status = try XCTUnwrap(GcStatusSummary.parse("{\"categories\":[],\"last_sweep\":null}"))
        XCTAssertNil(status.lastSweep)
        XCTAssertNil(GcStatusSummary.parse(nil))
    }

    func testLowDiskRule() {
        let gb: UInt64 = 1024 * 1024 * 1024
        XCTAssertFalse(DiskSpace.isLow(available: 0, total: 0), "an unmeasured disk is never low")
        XCTAssertTrue(DiskSpace.isLow(available: 4 * gb, total: 1000 * gb), "under 5 GiB is low")
        XCTAssertTrue(DiskSpace.isLow(available: 9 * gb, total: 100 * gb), "under 10% is low")
        XCTAssertFalse(DiskSpace.isLow(available: 110 * gb, total: 926 * gb))
    }

    /// Both limits are strict: exactly 5 GiB, or exactly 10% free, is not low.
    func testLowDiskBoundariesAreExclusive() {
        let gb: UInt64 = 1024 * 1024 * 1024
        XCTAssertFalse(DiskSpace.isLow(available: 5 * gb, total: 40 * gb))
        XCTAssertTrue(DiskSpace.isLow(available: 5 * gb - 1, total: 40 * gb))
        XCTAssertFalse(DiskSpace.isLow(available: 10 * gb, total: 100 * gb))
        XCTAssertTrue(DiskSpace.isLow(available: 10 * gb - 1, total: 100 * gb))
    }

    func testCapacityUsesDecimalUnits() {
        XCTAssertEqual(DiskSpace.capacity(500_000_000), "500MB")
        XCTAssertEqual(DiskSpace.capacity(13_584_153_464), "13.6GB")
        XCTAssertEqual(DiskSpace.capacity(2_500_000_000_000), "2.5TB")
    }
    /// A worktree base directory that does not exist yet is measured where it
    /// will be created: at its nearest existing ancestor.
    func testAMissingPathIsMeasuredAtItsNearestExistingAncestor() throws {
        let existing = FileManager.default.temporaryDirectory
        let missing = existing.appendingPathComponent("no-such-\(UUID().uuidString)/a/b").path
        let atAncestor = try XCTUnwrap(DiskSpace.volume(containing: existing.path))
        let atMissing = try XCTUnwrap(DiskSpace.volume(containing: missing))
        XCTAssertEqual(atMissing.volumePath, atAncestor.volumePath)
        XCTAssertGreaterThan(atMissing.total, 0)
        XCTAssertFalse(atMissing.volumePath.isEmpty)
    }

    /// Paths on one volume count once; the list is lowest free space first.
    func testBuildVolumesListsEachVolumeOnce() throws {
        let home = try XCTUnwrap(DiskSpace.homeVolume())
        let sameVolume = DiskSpace.buildVolumes(worktreeBaseDir: NSHomeDirectory() + "/.term-mesh/worktrees")
        XCTAssertEqual(sameVolume.map(\.volumePath), [home.volumePath])

        let volumes = DiskSpace.buildVolumes(worktreeBaseDir: "/Volumes")
        XCTAssertEqual(Set(volumes.map(\.volumePath)).count, volumes.count)
        XCTAssertEqual(volumes.map(\.available), volumes.map(\.available).sorted())
    }

    /// The sidebar warns about a volume that is low by share even when another
    /// volume has fewer free bytes but is not low.
    func testWarningVolumePrefersALowVolumeOverTheFewestFreeBytes() {
        let gib: UInt64 = 1 << 30
        let notLow = DiskSpace.Reading(available: 5 * gib, total: 40 * gib, volumePath: "/a")
        let lowByShare = DiskSpace.Reading(available: 9 * gib, total: 100 * gib, volumePath: "/b")
        XCTAssertFalse(notLow.isLow)
        XCTAssertTrue(lowByShare.isLow)
        XCTAssertEqual(DiskSpace.warningVolume([notLow, lowByShare]), lowByShare)

        let roomy = DiskSpace.Reading(available: 50 * gib, total: 100 * gib, volumePath: "/c")
        XCTAssertEqual(DiskSpace.warningVolume([notLow, roomy]), notLow)
        XCTAssertNil(DiskSpace.warningVolume([]))
    }
}
