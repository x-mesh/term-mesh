import XCTest
import PeerProto

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The summary is built once when a sample arrives and then only read, so
/// what it says is what the titlebar shows.
final class PeerHostStatsTests: XCTestCase {

    private func wire(
        load: Double = 1.0,
        load5: Double = 0,
        load15: Double = 0,
        memoryPercent: Float = 40,
        rx: UInt64 = 0,
        tx: UInt64 = 0,
        diskRead: UInt64 = 0,
        diskWrite: UInt64 = 0,
        diskTotal: UInt64 = 0,
        diskAvailable: UInt64 = 0
    ) -> Termmesh_Peer_V1_HostStats {
        var stats = Termmesh_Peer_V1_HostStats()
        stats.load1M = load
        stats.load5M = load5
        stats.load15M = load15
        stats.memoryPercent = memoryPercent
        stats.netRxBytesPerSec = rx
        stats.netTxBytesPerSec = tx
        stats.diskReadBytesPerSec = diskRead
        stats.diskWriteBytesPerSec = diskWrite
        stats.diskTotalBytes = diskTotal
        stats.diskAvailableBytes = diskAvailable
        return stats
    }

    private static let gigabyte: UInt64 = 1024 * 1024 * 1024

    /// A host that never reported capacity must not look full. Older peer
    /// builds send nothing at all, and warning about a machine we know
    /// nothing about is worse than staying quiet.
    func testUnreportedCapacityIsNeverLow() {
        let stats = PeerHostStats(wire())

        XCTAssertFalse(stats.isDiskLow)
        XCTAssertNil(stats.diskFreeText)
    }

    /// The absolute floor: a big disk with only a few gigabytes left still
    /// cannot take another checkout plus its build output.
    func testFewGigabytesLeftIsLowEvenOnALargeDisk() {
        let stats = PeerHostStats(wire(
            diskTotal: 2000 * Self.gigabyte,
            diskAvailable: 4 * Self.gigabyte
        ))

        XCTAssertTrue(stats.isDiskLow)
        XCTAssertEqual(stats.diskFreeText, "4.3GB free")
        XCTAssertEqual(stats.diskWarningText, "4.3GB free")
    }

    /// The proportional floor catches a small disk that is nearly full even
    /// though it clears the absolute one.
    func testUnderTenPercentIsLowEvenWithRoomToSpare() {
        let nearlyFull = PeerHostStats(wire(
            diskTotal: 100 * Self.gigabyte,
            diskAvailable: 9 * Self.gigabyte
        ))
        let comfortable = PeerHostStats(wire(
            diskTotal: 100 * Self.gigabyte,
            diskAvailable: 40 * Self.gigabyte
        ))

        XCTAssertTrue(nearlyFull.isDiskLow)
        XCTAssertFalse(comfortable.isDiskLow)
        XCTAssertNil(comfortable.diskWarningText)
    }

    func testSummaryLeadsWithAllThreeLoadAverages() {
        let summary = PeerHostStats(wire(load: 1.25, load5: 2.0, load15: 0.5)).summary

        // One decimal each: the second is noise at this refresh rate, and
        // the titlebar pays for every character. All three together are
        // what say whether the machine is climbing or settling.
        XCTAssertTrue(summary.hasPrefix("load 1.2 2.0 0.5"), "got \(summary)")
    }

    func testDiskAppearsWhenItIsDoingSomething() {
        let summary = PeerHostStats(wire(diskRead: 1_200_000, diskWrite: 340_000)).summary

        // Read/write, not arrows — those already mean "over the wire" in
        // the network group and would read as more traffic here.
        XCTAssertTrue(summary.contains("agent io 1.2M/340K"), "got \(summary)")
    }

    func testIdleHostShowsOnlyWhatIsHappening() {
        let groups = PeerHostStats(wire()).groups

        // Load and memory always mean something; zero-rate disk and
        // network are just noise taking up titlebar width.
        XCTAssertEqual(groups.count, 2, "got \(groups.map(\.text))")
    }

    /// The order is what a person reaches for first, and the priorities
    /// are the reverse of that — a narrow window sheds from the right.
    func testGroupsAreOrderedAndPrioritisedForNarrowWindows() {
        let groups = PeerHostStats(
            wire(load: 1, load5: 1, load15: 1, rx: 10, tx: 10, diskRead: 10, diskWrite: 10)
        ).groups

        XCTAssertEqual(groups.map { $0.text.prefix(3) }.map(String.init), ["loa", "mem", "net", "age"])
        XCTAssertEqual(groups.map(\.dropPriority), [0, -1, -2, -3])
    }

    func testSummaryOmitsNetworkWhenNothingIsMoving() {
        let summary = PeerHostStats(wire(rx: 0, tx: 0)).summary

        // An idle host would otherwise carry a permanent "↓0B ↑0B" that
        // never tells anyone anything.
        XCTAssertFalse(summary.contains("↓"), "got \(summary)")
        XCTAssertTrue(summary.contains("mem 40%"), "got \(summary)")
    }

    func testSummaryShowsNetworkWhenTrafficIsFlowing() {
        let summary = PeerHostStats(wire(rx: 2_100_000, tx: 1_000)).summary

        XCTAssertTrue(summary.contains("↓2.1M"), "got \(summary)")
        XCTAssertTrue(summary.contains("↑1K"), "got \(summary)")
    }

    /// Every rate has to fit a titlebar, so no unit is more than one
    /// character and no number more than four.
    ///
    /// Zero is absent from this table on purpose: a fully idle host omits
    /// the network entirely (see the test above), so there is no rendering
    /// of 0 B/s to pin down. Each case here pairs a non-zero rx with a zero
    /// tx, which is exactly the mixed state that still prints both.
    func testRatesStayShortAtEveryScale() {
        let cases: [(UInt64, String)] = [
            (1, "1B"),
            (999, "999B"),
            (1_000, "1K"),
            (999_999, "1000K"),
            (1_000_000, "1.0M"),
            (5_400_000_000, "5.4G"),
        ]
        for (bytes, expected) in cases {
            let summary = PeerHostStats(wire(rx: bytes, tx: 0)).summary
            XCTAssertTrue(
                summary.contains("↓\(expected)"),
                "\(bytes) B/s should render as \(expected), got \(summary)"
            )
        }
    }

    /// A number that stopped updating reads as a calm machine, which is the
    /// opposite of what a dead link means — so it expires instead.
    func testSampleGoesStaleRatherThanFreezing() {
        let old = PeerHostStats(
            wire(),
            receivedAt: Date().addingTimeInterval(-(PeerHostStats.staleAfter + 1))
        )
        let fresh = PeerHostStats(wire(), receivedAt: Date())

        XCTAssertTrue(old.isStale)
        XCTAssertFalse(fresh.isStale)
    }

    @MainActor
    func testStoreKeepsStatsPerHostAndForgetsOnRequest() {
        let store = PeerHostStatsStore.shared
        let hostA = PeerPaneHostKey.ssh(target: "a@host-a", remoteSockPath: "/run/a.sock", port: nil)
        let hostB = PeerPaneHostKey.ssh(target: "b@host-b", remoteSockPath: "/run/b.sock", port: nil)

        store.record(wire(load: 1.0), for: hostA)
        store.record(wire(load: 9.0), for: hostB)

        // Two machines are two facts; one must not overwrite the other.
        XCTAssertTrue(store.stats(for: hostA)?.summary.contains("load 1.0") == true)
        XCTAssertTrue(store.stats(for: hostB)?.summary.contains("load 9.0") == true)

        store.forget(hostA)
        XCTAssertNil(store.stats(for: hostA))
        XCTAssertNotNil(store.stats(for: hostB), "forgetting one host must not clear another")

        store.forget(hostB)
    }

    // MARK: - Publishing only on a visible change

    /// A host sitting at the same load still sends a sample every ~2s. The
    /// sidebar observes this store directly, so publishing each one re-evaluated
    /// its rows for numbers that had not moved — multiplied by the number of
    /// connected hosts.
    @MainActor
    func testRepeatedIdenticalSamplesDoNotPublish() {
        let store = PeerHostStatsStore.shared
        let host = PeerPaneHostKey.ssh(target: "a@quiet", remoteSockPath: "/run/q.sock", port: nil)
        defer { store.forget(host) }

        store.record(wire(load: 1.0), for: host)
        let afterFirst = store.generation
        store.record(wire(load: 1.0), for: host)
        store.record(wire(load: 1.0), for: host)

        XCTAssertEqual(store.generation, afterFirst,
                       "identical samples must not wake observers")
    }

    @MainActor
    func testChangedReadingPublishes() {
        let store = PeerHostStatsStore.shared
        let host = PeerPaneHostKey.ssh(target: "a@busy", remoteSockPath: "/run/b.sock", port: nil)
        defer { store.forget(host) }

        store.record(wire(load: 1.0), for: host)
        let afterFirst = store.generation
        store.record(wire(load: 2.0), for: host)

        XCTAssertNotEqual(store.generation, afterFirst)
    }

    /// Suppression must key on what is drawn, not on the whole value: the disk
    /// badge reads fields that never appear in `groups`.
    @MainActor
    func testDiskOnlyChangePublishes() {
        let store = PeerHostStatsStore.shared
        let host = PeerPaneHostKey.ssh(target: "a@disk", remoteSockPath: "/run/d.sock", port: nil)
        defer { store.forget(host) }

        store.record(wire(load: 1.0, diskTotal: 100_000_000_000, diskAvailable: 60_000_000_000), for: host)
        let afterFirst = store.generation
        store.record(wire(load: 1.0, diskTotal: 100_000_000_000, diskAvailable: 3_000_000_000), for: host)

        XCTAssertNotEqual(store.generation, afterFirst,
                          "the sidebar's low-disk badge depends on this")
    }

    /// `receivedAt` differs on every sample by construction, so an
    /// `Equatable`-based comparison would never suppress anything.
    func testRendersIdenticallyIgnoresArrivalTime() {
        let earlier = PeerHostStats(wire(load: 1.0), receivedAt: Date(timeIntervalSince1970: 1_000))
        let later = PeerHostStats(wire(load: 1.0), receivedAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertNotEqual(earlier, later, "the values themselves still differ by timestamp")
        XCTAssertTrue(PeerHostStats.rendersIdentically(earlier, later))
    }

    func testRendersIdenticallyIsFalseWithoutAPreviousSample() {
        let sample = PeerHostStats(wire(load: 1.0))
        XCTAssertFalse(PeerHostStats.rendersIdentically(nil, sample),
                       "a first sample has nothing to match and must publish")
    }

    // MARK: - Mac host: monitor.snapshot → HostStats

    /// Keys are the Rust `SystemSnapshot` field names verbatim. A rename there
    /// would surface as a figure silently reading zero, so this fixture is
    /// deliberately spelled out rather than generated.
    private func monitorSnapshotJSON() -> [String: Any] {
        [
            "load_avg": [1.5, 2.25, 3.0],
            "cpu_count": 10,
            "memory_percent": 42.5,
            "used_memory_bytes": 8_000_000_000,
            "total_memory_bytes": 16_000_000_000,
            "disk_read_bytes_per_sec": 1_024,
            "disk_write_bytes_per_sec": 2_048,
            "disk_total_bytes": 500_000_000_000,
            "disk_available_bytes": 120_000_000_000,
            "network_io": [
                ["name": "en0", "rx_rate": 1_000.0, "tx_rate": 500.0],
                ["name": "utun0", "rx_rate": 250.0, "tx_rate": 125.0],
            ],
        ]
    }

    func testMonitorSnapshotMapsEveryField() throws {
        let stats = try XCTUnwrap(LocalHostStatsSample.make(from: monitorSnapshotJSON()))
        XCTAssertEqual(stats.load1M, 1.5)
        XCTAssertEqual(stats.load5M, 2.25)
        XCTAssertEqual(stats.load15M, 3.0)
        XCTAssertEqual(stats.cpuCount, 10)
        XCTAssertEqual(stats.memoryPercent, 42.5)
        XCTAssertEqual(stats.memoryUsedBytes, 8_000_000_000)
        XCTAssertEqual(stats.memoryTotalBytes, 16_000_000_000)
        XCTAssertEqual(stats.diskReadBytesPerSec, 1_024)
        XCTAssertEqual(stats.diskWriteBytesPerSec, 2_048)
        XCTAssertEqual(stats.diskTotalBytes, 500_000_000_000)
        XCTAssertEqual(stats.diskAvailableBytes, 120_000_000_000)
    }

    /// The daemon sums across interfaces before sending; a Mac host that
    /// reported only `en0` would under-report every machine with a VPN up.
    func testNetworkRatesAreSummedAcrossInterfaces() throws {
        let stats = try XCTUnwrap(LocalHostStatsSample.make(from: monitorSnapshotJSON()))
        XCTAssertEqual(stats.netRxBytesPerSec, 1_250)
        XCTAssertEqual(stats.netTxBytesPerSec, 625)
    }

    /// An older daemon, or one that has not finished its first tick, can be
    /// missing keys. Zero is the honest answer for each — the client renders
    /// "not measured" from it and never a stale figure.
    func testMissingKeysBecomeZeroRatherThanFailing() throws {
        let stats = try XCTUnwrap(LocalHostStatsSample.make(from: ["cpu_count": 8]))
        XCTAssertEqual(stats.cpuCount, 8)
        XCTAssertEqual(stats.load1M, 0)
        XCTAssertEqual(stats.diskTotalBytes, 0, "zero total must read as unmeasured, not as a full disk")
        XCTAssertEqual(stats.netRxBytesPerSec, 0)
    }

    func testShortLoadAverageArrayIsIgnoredRatherThanCrashing() throws {
        let stats = try XCTUnwrap(LocalHostStatsSample.make(from: ["load_avg": [1.0]]))
        XCTAssertEqual(stats.load1M, 0)
        XCTAssertEqual(stats.load15M, 0)
    }

    /// A counter reset can hand back a negative delta; the wire field is
    /// unsigned, so clamping is what keeps it from wrapping to an enormous
    /// rate.
    func testNegativeRatesClampToZero() throws {
        let stats = try XCTUnwrap(LocalHostStatsSample.make(from: [
            "network_io": [["name": "en0", "rx_rate": -50.0, "tx_rate": -10.0]],
        ]))
        XCTAssertEqual(stats.netRxBytesPerSec, 0)
        XCTAssertEqual(stats.netTxBytesPerSec, 0)
    }

    /// The whole point of the mapping: what the daemon reports must come out
    /// the far end as the same rendered line a Linux peer would produce.
    func testMappedSampleRendersLikeAnyOtherHost() throws {
        let stats = try XCTUnwrap(LocalHostStatsSample.make(from: monitorSnapshotJSON()))
        let rendered = PeerHostStats(stats)
        XCTAssertTrue(rendered.summary.contains("load 1.5 2.2 3.0"), "got \(rendered.summary)")
        XCTAssertFalse(rendered.isDiskLow, "120GB of 500GB is not low")
    }
}
